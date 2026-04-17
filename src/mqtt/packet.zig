const std = @import("std");
const types = @import("mqtt_types");

const QoS = types.QoS;
const ConnectReturnCode = types.ConnectReturnCode;
const SubackReturnCode = types.SubackReturnCode;
const ConnectFlags = types.ConnectFlags;
const PacketType = types.PacketType;
const Allocator = types.Allocator;

// ── MQTT パケット構造体定義 ──────────────────────────────────

/// CONNECT パケット (MQTT 3.1.1 Section 3.1)
pub const ConnectPacket = struct {
    protocol_name: []const u8 = types.PROTOCOL_NAME,
    protocol_level: u8 = types.PROTOCOL_LEVEL,
    flags: ConnectFlags = .{},
    keep_alive: u16 = 60,
    client_id: []const u8,
    will_topic: ?[]const u8 = null,
    will_message: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

/// CONNACK パケット (MQTT 3.1.1 Section 3.2)
pub const ConnackPacket = struct {
    session_present: bool = false,
    return_code: ConnectReturnCode = .accepted,
};

/// PUBLISH パケット (MQTT 3.1.1 Section 3.3)
pub const PublishPacket = struct {
    dup: bool = false,
    qos: QoS = .at_most_once,
    retain: bool = false,
    topic: []const u8,
    packet_id: ?u16 = null,
    payload: []const u8,
};

/// PUBACK パケット (MQTT 3.1.1 Section 3.4)
pub const PubackPacket = struct {
    packet_id: u16,
};

/// サブスクリプション要素
pub const TopicFilter = struct {
    filter: []const u8,
    qos: QoS,
};

/// SUBSCRIBE パケット (MQTT 3.1.1 Section 3.8)
pub const SubscribePacket = struct {
    packet_id: u16,
    topics: []const TopicFilter,
};

/// SUBACK パケット (MQTT 3.1.1 Section 3.9)
pub const SubackPacket = struct {
    packet_id: u16,
    return_codes: []const SubackReturnCode,
};

/// UNSUBSCRIBE パケット (MQTT 3.1.1 Section 3.10)
pub const UnsubscribePacket = struct {
    packet_id: u16,
    topics: []const []const u8,
};

/// UNSUBACK パケット (MQTT 3.1.1 Section 3.11)
pub const UnsubackPacket = struct {
    packet_id: u16,
};

/// 全パケットの tagged union
pub const Packet = union(PacketType) {
    reserved: void,
    connect: ConnectPacket,
    connack: ConnackPacket,
    publish: PublishPacket,
    puback: PubackPacket,
    pubrec: PubackPacket,
    pubrel: PubackPacket,
    pubcomp: PubackPacket,
    subscribe: SubscribePacket,
    suback: SubackPacket,
    unsubscribe: UnsubscribePacket,
    unsuback: UnsubackPacket,
    pingreq: void,
    pingresp: void,
    disconnect: void,
    reserved2: void,

    pub fn packetType(self: Packet) PacketType {
        return self;
    }
};

/// パケットに関連付けられたアロケーションを解放
pub fn freePacket(allocator: Allocator, packet_val: *const Packet) void {
    switch (packet_val.*) {
        .connect => |p| {
            if (p.protocol_name.len > 0 and !std.mem.eql(u8, p.protocol_name, types.PROTOCOL_NAME)) {
                allocator.free(p.protocol_name);
            }
            allocator.free(p.client_id);
            if (p.will_topic) |t| allocator.free(t);
            if (p.will_message) |m| allocator.free(m);
            if (p.username) |u| allocator.free(u);
            if (p.password) |pw| allocator.free(pw);
        },
        .publish => |p| {
            allocator.free(p.topic);
            allocator.free(p.payload);
        },
        .subscribe => |p| {
            for (p.topics) |tf| {
                allocator.free(tf.filter);
            }
            allocator.free(p.topics);
        },
        .suback => |p| {
            allocator.free(p.return_codes);
        },
        .unsubscribe => |p| {
            for (p.topics) |t| {
                allocator.free(t);
            }
            allocator.free(p.topics);
        },
        else => {},
    }
}
