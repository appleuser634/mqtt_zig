const std = @import("std");
const types = @import("mqtt_types");
const codec = @import("mqtt_codec");
const pkt = @import("mqtt_packet");
const Transport = @import("mqtt_transport").Transport;

const Allocator = types.Allocator;
const QoS = types.QoS;
const ConnectFlags = types.ConnectFlags;

/// MQTT クライアントの接続オプション
pub const ConnectOptions = struct {
    client_id: []const u8 = "mqtt-zig-client",
    clean_session: bool = true,
    keep_alive: u16 = 60,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    will_topic: ?[]const u8 = null,
    will_message: ?[]const u8 = null,
    will_qos: QoS = .at_most_once,
    will_retain: bool = false,
};

/// MQTT v3.1.1 クライアント
pub const MqttClient = struct {
    transport: Transport,
    allocator: Allocator,
    next_packet_id: u16 = 1,

    /// ブローカーに接続
    pub fn connect(allocator: Allocator, io: std.Io, host: []const u8, port: u16, opts: ConnectOptions) !MqttClient {
        var transport = try Transport.connect(allocator, io, host, port);
        errdefer transport.close();

        var flags = ConnectFlags{
            .clean_session = opts.clean_session,
        };
        if (opts.username != null) flags.username_flag = true;
        if (opts.password != null) flags.password_flag = true;
        if (opts.will_topic != null) {
            flags.will_flag = true;
            flags.will_qos = @intFromEnum(opts.will_qos);
            flags.will_retain = opts.will_retain;
        }

        const connect_pkt = pkt.ConnectPacket{
            .client_id = opts.client_id,
            .flags = flags,
            .keep_alive = opts.keep_alive,
            .username = opts.username,
            .password = opts.password,
            .will_topic = opts.will_topic,
            .will_message = opts.will_message,
        };

        const encoded = try codec.encodeConnect(allocator, &connect_pkt);
        defer allocator.free(encoded);
        try transport.send(encoded);

        const result = try transport.readPacket();
        defer allocator.free(result.data);

        if (result.header.packet_type != .connack) return error.ProtocolError;
        const connack = try codec.decodeConnack(result.data);
        if (connack.return_code != .accepted) return error.ConnectionRefused;

        return .{
            .transport = transport,
            .allocator = allocator,
        };
    }

    /// メッセージをパブリッシュ
    pub fn publish(self: *MqttClient, topic: []const u8, payload: []const u8, qos: QoS, retain: bool) !void {
        var packet_id: ?u16 = null;
        if (qos != .at_most_once) {
            packet_id = self.nextPacketId();
        }

        const publish_pkt = pkt.PublishPacket{
            .topic = topic,
            .payload = payload,
            .qos = qos,
            .retain = retain,
            .packet_id = packet_id,
        };

        const encoded = try codec.encodePublish(self.allocator, &publish_pkt);
        defer self.allocator.free(encoded);
        try self.transport.send(encoded);

        if (qos == .at_least_once) {
            const result = try self.transport.readPacket();
            defer self.allocator.free(result.data);
            if (result.header.packet_type != .puback) return error.ProtocolError;
        }
    }

    /// トピックを購読
    pub fn subscribe(self: *MqttClient, topic_filters: []const pkt.TopicFilter) !void {
        const sub_pkt = pkt.SubscribePacket{
            .packet_id = self.nextPacketId(),
            .topics = topic_filters,
        };

        const encoded = try codec.encodeSubscribe(self.allocator, &sub_pkt);
        defer self.allocator.free(encoded);
        try self.transport.send(encoded);

        const result = try self.transport.readPacket();
        defer self.allocator.free(result.data);
        if (result.header.packet_type != .suback) return error.ProtocolError;
    }

    /// 受信パケットを1つ読み取る
    pub fn readMessage(self: *MqttClient) !ReceivedMessage {
        while (true) {
            const result = try self.transport.readPacket();

            switch (result.header.packet_type) {
                .publish => {
                    const pub_pkt = try codec.decodePublish(self.allocator, result.header.flags, result.data);
                    self.allocator.free(result.data);

                    if (pub_pkt.qos == .at_least_once) {
                        if (pub_pkt.packet_id) |pid| {
                            var buf: [4]u8 = undefined;
                            const puback_pkt = pkt.PubackPacket{ .packet_id = pid };
                            const puback = try codec.encodePuback(&buf, &puback_pkt);
                            try self.transport.send(puback);
                        }
                    }

                    return .{
                        .topic = pub_pkt.topic,
                        .payload = pub_pkt.payload,
                        .qos = pub_pkt.qos,
                        .retain = pub_pkt.retain,
                    };
                },
                else => {
                    self.allocator.free(result.data);
                    continue;
                },
            }
        }
    }

    /// 切断
    pub fn disconnect(self: *MqttClient) !void {
        var buf: [2]u8 = undefined;
        const data = try codec.encodeDisconnect(&buf);
        self.transport.send(data) catch {};
        self.transport.close();
    }

    fn nextPacketId(self: *MqttClient) u16 {
        const id = self.next_packet_id;
        self.next_packet_id = if (self.next_packet_id == types.MAX_PACKET_ID) 1 else self.next_packet_id + 1;
        return id;
    }
};

/// 受信メッセージ
pub const ReceivedMessage = struct {
    topic: []const u8,
    payload: []const u8,
    qos: QoS,
    retain: bool,

    pub fn deinit(self: *const ReceivedMessage, allocator: Allocator) void {
        allocator.free(self.topic);
        allocator.free(self.payload);
    }
};
