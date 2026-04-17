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
pub const ConnectionHandler = struct {
    stream: net.Stream,
    io: std.Io,
    allocator: Allocator,
    session_manager: *Session.SessionManager,
    retain_store: *Retain.RetainStore,
    client_id: ?[]const u8 = null,
    connections: *ConnectionMap,

    pub fn handle(self: *ConnectionHandler) void {
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
        // reader/writer をループの外で1回だけ作成し、バッファを保持する。
        // これにより buffered reader が先読みしたデータが次の readPacket でも有効になる。
        var read_buf: [8192]u8 = undefined;
        var reader = self.stream.reader(self.io, &read_buf);
        var write_buf: [8192]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buf);

        while (true) {
            const result = readPacket(&reader.interface, self.allocator) catch |err| switch (err) {
                error.ConnectionClosed, error.EndOfStream => return,
                else => return err,
            };
            defer self.allocator.free(result.data);

            self.dispatch(result.header, result.data, &writer.interface) catch |err| switch (err) {
                error.ConnectionClosed => return,
                else => return err,
            };
        }
    }

    const ReadResult = struct {
        header: codec.FixedHeader,
        data: []u8,
    };

    fn readPacket(r: *Reader, allocator: Allocator) !ReadResult {
        var header_buf: [5]u8 = undefined;
        r.readSliceAll(header_buf[0..1]) catch |err| switch (err) {
            error.EndOfStream => return error.ConnectionClosed,
            else => return err,
        };

        var rl_len: usize = 0;
        while (rl_len < 4) {
            try r.readSliceAll(header_buf[1 + rl_len ..][0..1]);
            rl_len += 1;
            if (header_buf[rl_len] & 0x80 == 0) break;
        }

        const header = try codec.decodeFixedHeader(header_buf[0 .. 1 + rl_len]);
        const data = try allocator.alloc(u8, header.remaining_length);
        errdefer allocator.free(data);
        try r.readSliceAll(data);

        return .{ .header = header, .data = data };
    }

    fn sendBytes(w: *Writer, data: []const u8) !void {
        try w.writeAll(data);
        try w.flush();
    }

    fn dispatch(self: *ConnectionHandler, header: codec.FixedHeader, data: []u8, w: *Writer) !void {
        switch (header.packet_type) {
            .connect => try self.handleConnect(data, w),
            .publish => try self.handlePublish(header.flags, data, w),
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

        const result = try self.session_manager.handleConnect(
            connect_pkt.client_id,
            connect_pkt.flags.clean_session,
        );

        self.client_id = try self.allocator.dupe(u8, connect_pkt.client_id);
        self.allocator.free(connect_pkt.client_id);
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

    fn handlePublish(self: *ConnectionHandler, flags: u4, data: []u8, w: *Writer) !void {
        const publish_pkt = try codec.decodePublish(self.allocator, flags, data);
        defer {
            self.allocator.free(publish_pkt.topic);
            self.allocator.free(publish_pkt.payload);
        }

        // QoS 1: PUBACK をパブリッシャーに返す
        if (publish_pkt.qos == .at_least_once) {
            if (publish_pkt.packet_id) |pid| {
                var buf: [4]u8 = undefined;
                const puback = pkt.PubackPacket{ .packet_id = pid };
                const encoded = try codec.encodePuback(&buf, &puback);
                try sendBytes(w, encoded);
            }
        }

        // Retained メッセージの処理
        if (publish_pkt.retain) {
            try self.retain_store.store(publish_pkt.topic, publish_pkt.payload, publish_pkt.qos);
        }

        // マッチするサブスクライバーにルーティング
        const matches = try self.session_manager.findMatchingSessions(self.allocator, publish_pkt.topic);
        defer self.allocator.free(matches);

        for (matches) |match| {
            if (self.client_id) |my_id| {
                if (std.mem.eql(u8, match.client_id, my_id)) continue;
            }

            const effective_qos_val = @min(@intFromEnum(match.qos), @intFromEnum(publish_pkt.qos));
            const effective_qos: QoS = @enumFromInt(effective_qos_val);

            // 対象サブスクライバーの接続を取得してフォワード
            if (self.connections.get(match.client_id)) |conn| {
                const fwd_pkt = pkt.PublishPacket{
                    .topic = publish_pkt.topic,
                    .payload = publish_pkt.payload,
                    .qos = effective_qos,
                    .retain = false,
                    .packet_id = if (effective_qos != .at_most_once) @as(?u16, 1) else null,
                };
                const encoded = codec.encodePublish(self.allocator, &fwd_pkt) catch continue;
                defer self.allocator.free(encoded);
                // 他クライアントへの送信: そのクライアントの stream に直接書く
                var fwd_write_buf: [8192]u8 = undefined;
                var fwd_writer = conn.stream.writer(conn.io, &fwd_write_buf);
                sendBytes(&fwd_writer.interface, encoded) catch continue;
            }
        }

        std.log.debug("PUBLISH: {s} -> {s}", .{ publish_pkt.topic, publish_pkt.payload });
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

                // Retained メッセージを送信
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

        // SUBACK 送信
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
