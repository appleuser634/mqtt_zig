const std = @import("std");
const types = @import("mqtt_types");
const codec = @import("mqtt_codec");
const pkt = @import("mqtt_packet");
const Session = @import("broker_session");
const Retain = @import("broker_retain");

const Allocator = types.Allocator;
const QoS = types.QoS;
const SubackReturnCode = types.SubackReturnCode;
const net = std.Io.net;

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

fn ManagedArrayList(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}

/// クライアント接続ハンドラ
/// 改善ポイント:
///  - writer を ConnectionHandler にキャッシュし、fan-out で再利用
///  - PUBLISH の fan-out で生バイト列を直接転送（再エンコード不要、ゼロアロケーション）
///  - findMatchingSessions をスタック固定バッファで受け取り
pub const ConnectionHandler = struct {
    stream: net.Stream,
    io: std.Io,
    allocator: Allocator,
    session_manager: *Session.SessionManager,
    retain_store: *Retain.RetainStore,
    client_id: ?[]const u8 = null,
    connections: *ConnectionMap,

    // 改善: 各接続が持つキャッシュ済み writer (fan-out 送信用)
    cached_write_buf: [8192]u8 = undefined,
    cached_writer: ?net.Stream.Writer = null,

    pub fn handle(self: *ConnectionHandler) void {
        // writer キャッシュを初期化
        self.cached_writer = self.stream.writer(self.io, &self.cached_write_buf);

        self.run() catch |err| {
            std.log.debug("connection error: {s}", .{@errorName(err)});
        };
        if (self.client_id) |cid| {
            std.log.info("Client disconnected: {s}", .{cid});
            self.session_manager.handleDisconnect(cid);
            self.connections.remove(cid);
            self.allocator.free(cid);
        }
        self.stream.close(self.io);
        self.allocator.destroy(self);
    }

    fn run(self: *ConnectionHandler) !void {
        var read_buf: [8192]u8 = undefined;
        var reader = self.stream.reader(self.io, &read_buf);
        var write_buf: [8192]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buf);

        while (true) {
            // 改善: 固定ヘッダを含む生バイト列も保持し、fan-out で再利用
            var header_raw: [5]u8 = undefined;
            const raw_result = readPacketRaw(&reader.interface, self.allocator, &header_raw) catch |err| switch (err) {
                error.ConnectionClosed, error.EndOfStream => return,
                else => return err,
            };
            defer self.allocator.free(raw_result.data);

            self.dispatch(raw_result.header, raw_result.header_bytes, raw_result.data, &writer.interface) catch |err| switch (err) {
                error.ConnectionClosed => return,
                else => return err,
            };
        }
    }

    const RawReadResult = struct {
        header: codec.FixedHeader,
        header_bytes: []const u8, // 固定ヘッダの生バイト列
        data: []u8, // remaining length 分のデータ
    };

    /// 改善: 固定ヘッダの生バイト列も返す（fan-out でそのまま転送するため）
    fn readPacketRaw(r: *Reader, allocator: Allocator, header_store: *[5]u8) !RawReadResult {
        r.readSliceAll(header_store[0..1]) catch |err| switch (err) {
            error.EndOfStream => return error.ConnectionClosed,
            else => return err,
        };

        var rl_len: usize = 0;
        while (rl_len < 4) {
            try r.readSliceAll(header_store[1 + rl_len ..][0..1]);
            rl_len += 1;
            if (header_store[rl_len] & 0x80 == 0) break;
        }

        const header_size = 1 + rl_len;
        const header = try codec.decodeFixedHeader(header_store[0..header_size]);
        const data = try allocator.alloc(u8, header.remaining_length);
        errdefer allocator.free(data);
        try r.readSliceAll(data);

        return .{
            .header = header,
            .header_bytes = header_store[0..header_size],
            .data = data,
        };
    }

    fn sendBytes(w: *Writer, data: []const u8) !void {
        try w.writeAll(data);
        try w.flush();
    }

    fn dispatch(self: *ConnectionHandler, header: codec.FixedHeader, header_bytes: []const u8, data: []u8, w: *Writer) !void {
        switch (header.packet_type) {
            .connect => try self.handleConnect(data, w),
            .publish => try self.handlePublish(header.flags, header_bytes, data, w),
            .puback => {},
            .subscribe => try self.handleSubscribe(data, w),
            .unsubscribe => try self.handleUnsubscribe(data, w),
            .pingreq => try handlePingreq(w),
            .disconnect => return error.ConnectionClosed,
            else => {},
        }
    }

    fn handleConnect(self: *ConnectionHandler, data: []u8, w: *Writer) !void {
        const connect_pkt = try codec.decodeConnect(self.allocator, data);
        defer {
            if (connect_pkt.will_topic) |t| self.allocator.free(t);
            if (connect_pkt.will_message) |m| self.allocator.free(m);
            if (connect_pkt.username) |u| self.allocator.free(u);
            if (connect_pkt.password) |p| self.allocator.free(p);
        }

        if (connect_pkt.protocol_level != types.PROTOCOL_LEVEL) {
            var buf: [4]u8 = undefined;
            const connack = pkt.ConnackPacket{ .return_code = .unacceptable_protocol };
            const encoded = try codec.encodeConnack(&buf, &connack);
            try sendBytes(w, encoded);
            self.allocator.free(connect_pkt.client_id);
            return error.ConnectionClosed;
        }

        defer self.allocator.free(connect_pkt.client_id);

        var id_buf: [32]u8 = undefined;
        const actual_client_id: []const u8 = if (connect_pkt.client_id.len == 0)
            std.fmt.bufPrint(&id_buf, "auto-{x}", .{@intFromPtr(self)}) catch "auto-fallback"
        else
            connect_pkt.client_id;

        const result = try self.session_manager.handleConnect(
            actual_client_id,
            connect_pkt.flags.clean_session,
        );

        self.client_id = try self.allocator.dupe(u8, actual_client_id);
        self.connections.put(self.client_id.?, self);

        var buf: [4]u8 = undefined;
        const connack = pkt.ConnackPacket{
            .session_present = result.session_present,
            .return_code = .accepted,
        };
        const encoded = try codec.encodeConnack(&buf, &connack);
        try sendBytes(w, encoded);

        std.log.info("Client connected: {s}", .{self.client_id.?});
    }

    /// 改善版 PUBLISH ハンドラ:
    ///  1. QoS 0 の fan-out では元パケットのバイト列をそのまま転送（ゼロアロケーション）
    ///  2. 各接続のキャッシュ済み writer を使い、毎回の writer 作成を回避
    fn handlePublish(self: *ConnectionHandler, flags: u4, header_bytes: []const u8, data: []u8, w: *Writer) !void {
        // QoS 0 かつ retain=false の場合: デコード最小化、生バイト転送
        const qos_bits: u2 = @intCast((flags >> 1) & 0x03);
        const retain = (flags & 0x01) != 0;

        // Retained メッセージの場合はフルデコードが必要
        if (retain) {
            const publish_pkt = try codec.decodePublish(self.allocator, flags, data);
            defer {
                self.allocator.free(publish_pkt.topic);
                self.allocator.free(publish_pkt.payload);
            }
            try self.retain_store.store(publish_pkt.topic, publish_pkt.payload, publish_pkt.qos);
        }

        // QoS 1: PUBACK
        if (qos_bits == 1) {
            // トピック名の後に packet_id がある
            const topic_len: u16 = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
            const pid_offset = 2 + topic_len;
            if (pid_offset + 2 <= data.len) {
                const pid: u16 = (@as(u16, data[pid_offset]) << 8) | @as(u16, data[pid_offset + 1]);
                var buf: [4]u8 = undefined;
                const puback = pkt.PubackPacket{ .packet_id = pid };
                const encoded = try codec.encodePuback(&buf, &puback);
                try sendBytes(w, encoded);
            }
        }

        // トピック名を抽出（マッチングに必要）
        if (data.len < 2) return;
        const topic_len: u16 = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
        if (2 + topic_len > data.len) return;
        const topic = data[2..][0..topic_len];

        // 改善: スタック固定バッファでマッチング（アロケーションなし）
        var match_buf: [128]Session.SessionManager.MatchResult = undefined;
        const matches = self.session_manager.findMatchingSessionsStack(topic, &match_buf);

        // 改善: QoS 0 の場合、元のパケットバイト列をそのまま転送
        // retain フラグを落とした固定ヘッダを構築
        var fwd_header: [5]u8 = undefined;
        @memcpy(fwd_header[0..header_bytes.len], header_bytes);
        fwd_header[0] &= 0xFE; // retain = 0 にクリア

        for (matches) |match| {
            if (self.client_id) |my_id| {
                if (std.mem.eql(u8, match.client_id, my_id)) continue;
            }

            // 改善: キャッシュ済み writer を使って直接送信
            if (self.connections.get(match.client_id)) |conn| {
                if (conn.cached_writer) |*cw| {
                    // 固定ヘッダ + 元データをそのまま送信（ゼロアロケーション）
                    cw.interface.writeAll(fwd_header[0..header_bytes.len]) catch continue;
                    cw.interface.writeAll(data) catch continue;
                    cw.interface.flush() catch continue;
                }
            }
        }

        std.log.debug("PUBLISH: {s} -> {d} subscribers", .{ topic, matches.len });
    }

    fn handleSubscribe(self: *ConnectionHandler, data: []u8, w: *Writer) !void {
        const sub_pkt = try codec.decodeSubscribe(self.allocator, data);
        defer {
            for (sub_pkt.topics) |tf| self.allocator.free(tf.filter);
            self.allocator.free(sub_pkt.topics);
        }

        var return_codes = ManagedArrayList(SubackReturnCode).init(self.allocator);
        defer return_codes.deinit();

        for (sub_pkt.topics) |tf| {
            if (self.client_id) |cid| {
                try self.session_manager.addSubscription(cid, tf.filter, tf.qos);
                try return_codes.append(switch (tf.qos) {
                    .at_most_once => .success_qos0,
                    .at_least_once => .success_qos1,
                    .exactly_once => .success_qos2,
                });

                const retained = try self.retain_store.getMatching(self.allocator, tf.filter);
                defer {
                    for (retained) |rm| {
                        self.allocator.free(rm.topic);
                        self.allocator.free(rm.payload);
                    }
                    self.allocator.free(retained);
                }
                for (retained) |rm| {
                    const fwd = pkt.PublishPacket{
                        .topic = rm.topic,
                        .payload = rm.payload,
                        .qos = rm.qos,
                        .retain = true,
                        .packet_id = if (rm.qos != .at_most_once) @as(?u16, 1) else null,
                    };
                    const encoded = codec.encodePublish(self.allocator, &fwd) catch continue;
                    defer self.allocator.free(encoded);
                    sendBytes(w, encoded) catch continue;
                }

                std.log.info("Client {s} subscribed to: {s}", .{ cid, tf.filter });
            }
        }

        const suback = pkt.SubackPacket{
            .packet_id = sub_pkt.packet_id,
            .return_codes = return_codes.items,
        };
        const encoded = try codec.encodeSuback(self.allocator, &suback);
        defer self.allocator.free(encoded);
        try sendBytes(w, encoded);
    }

    fn handleUnsubscribe(self: *ConnectionHandler, data: []u8, w: *Writer) !void {
        const unsub_pkt = try codec.decodeUnsubscribe(self.allocator, data);
        defer {
            for (unsub_pkt.topics) |t| self.allocator.free(t);
            self.allocator.free(unsub_pkt.topics);
        }

        if (self.client_id) |cid| {
            for (unsub_pkt.topics) |t| {
                _ = self.session_manager.removeSubscription(cid, t);
            }
        }

        var buf: [4]u8 = undefined;
        const unsuback = pkt.UnsubackPacket{ .packet_id = unsub_pkt.packet_id };
        const encoded = try codec.encodeUnsuback(&buf, &unsuback);
        try sendBytes(w, encoded);
    }

    fn handlePingreq(w: *Writer) !void {
        var buf: [2]u8 = undefined;
        const encoded = try codec.encodePingresp(&buf);
        try sendBytes(w, encoded);
    }
};

/// 接続中クライアントのマップ
pub const ConnectionMap = struct {
    map: std.StringHashMap(*ConnectionHandler),
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: std.Io) ConnectionMap {
        return .{
            .map = std.StringHashMap(*ConnectionHandler).init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *ConnectionMap) void {
        self.map.deinit();
    }

    pub fn put(self: *ConnectionMap, client_id: []const u8, handler: *ConnectionHandler) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.map.put(client_id, handler) catch {};
    }

    pub fn get(self: *ConnectionMap, client_id: []const u8) ?*ConnectionHandler {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.map.get(client_id);
    }

    pub fn remove(self: *ConnectionMap, client_id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.map.remove(client_id);
    }
};
