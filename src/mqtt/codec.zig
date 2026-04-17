const std = @import("std");
const types = @import("mqtt_types");
const packet = @import("mqtt_packet");

const QoS = types.QoS;
const PacketType = types.PacketType;
const ConnectFlags = types.ConnectFlags;
const ConnectReturnCode = types.ConnectReturnCode;
const SubackReturnCode = types.SubackReturnCode;
const Allocator = types.Allocator;

/// Zig 0.16: managed ArrayList (allocator を保持)
fn ManagedArrayList(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}

const Packet = packet.Packet;
const ConnectPacket = packet.ConnectPacket;
const ConnackPacket = packet.ConnackPacket;
const PublishPacket = packet.PublishPacket;
const PubackPacket = packet.PubackPacket;
const SubscribePacket = packet.SubscribePacket;
const SubackPacket = packet.SubackPacket;
const UnsubscribePacket = packet.UnsubscribePacket;
const UnsubackPacket = packet.UnsubackPacket;
const TopicFilter = packet.TopicFilter;

// ── エラー定義 ──────────────────────────────────────────────

pub const CodecError = error{
    InvalidRemainingLength,
    InvalidPacketType,
    InvalidProtocolName,
    InvalidProtocolLevel,
    InvalidFlags,
    PacketTooShort,
    MalformedPacket,
    OutOfMemory,
    EndOfStream,
};

// ── Remaining Length エンコード/デコード ─────────────────────

/// Remaining Length をエンコードしてバッファに書き込む (MQTT 3.1.1 Section 2.2.3)
/// 可変長整数: 各バイトの下位7ビットがデータ、最上位ビットが継続フラグ
pub fn encodeRemainingLength(buf: []u8, value: u32) ![]const u8 {
    if (value > types.MAX_REMAINING_LENGTH) return CodecError.InvalidRemainingLength;
    var x = value;
    var i: usize = 0;
    while (true) {
        var encoded_byte: u8 = @intCast(x % 128);
        x /= 128;
        if (x > 0) encoded_byte |= 0x80;
        if (i >= buf.len) return CodecError.InvalidRemainingLength;
        buf[i] = encoded_byte;
        i += 1;
        if (x == 0) break;
    }
    return buf[0..i];
}

/// バイト列から Remaining Length をデコード
/// 戻り値: .value = デコードされた値, .bytes_consumed = 消費バイト数
pub const RemainingLengthResult = struct {
    value: u32,
    bytes_consumed: usize,
};

pub fn decodeRemainingLength(data: []const u8) !RemainingLengthResult {
    var multiplier: u32 = 1;
    var value: u32 = 0;
    var i: usize = 0;
    while (true) {
        if (i >= data.len) return CodecError.PacketTooShort;
        const encoded_byte = data[i];
        value += @as(u32, encoded_byte & 0x7F) * multiplier;
        if (multiplier > 128 * 128 * 128) return CodecError.InvalidRemainingLength;
        i += 1;
        if (encoded_byte & 0x80 == 0) break;
        multiplier *= 128;
    }
    return .{ .value = value, .bytes_consumed = i };
}

// ── UTF-8 文字列 エンコード/デコード ────────────────────────

/// MQTT UTF-8 文字列をバッファに書き込む (2バイト長プレフィックス + データ)
pub fn encodeString(buf: []u8, str: []const u8) ![]const u8 {
    const total = 2 + str.len;
    if (buf.len < total) return CodecError.PacketTooShort;
    buf[0] = @intCast((str.len >> 8) & 0xFF);
    buf[1] = @intCast(str.len & 0xFF);
    @memcpy(buf[2..][0..str.len], str);
    return buf[0..total];
}

/// MQTT UTF-8 文字列をデコード
pub const StringResult = struct {
    value: []const u8,
    bytes_consumed: usize,
};

pub fn decodeString(data: []const u8) !StringResult {
    if (data.len < 2) return CodecError.PacketTooShort;
    const len: u16 = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
    if (data.len < 2 + len) return CodecError.PacketTooShort;
    return .{
        .value = data[2..][0..len],
        .bytes_consumed = 2 + len,
    };
}

/// u16 をビッグエンディアンでエンコード
pub fn encodeU16(buf: []u8, value: u16) ![]const u8 {
    if (buf.len < 2) return CodecError.PacketTooShort;
    buf[0] = @intCast((value >> 8) & 0xFF);
    buf[1] = @intCast(value & 0xFF);
    return buf[0..2];
}

/// ビッグエンディアンの u16 をデコード
pub fn decodeU16(data: []const u8) !u16 {
    if (data.len < 2) return CodecError.PacketTooShort;
    return (@as(u16, data[0]) << 8) | @as(u16, data[1]);
}

// ── 固定ヘッダ ──────────────────────────────────────────────

/// 固定ヘッダの解析結果
pub const FixedHeader = struct {
    packet_type: PacketType,
    flags: u4,
    remaining_length: u32,
    header_size: usize, // 固定ヘッダ全体のバイト数
};

/// 固定ヘッダをデコード
pub fn decodeFixedHeader(data: []const u8) !FixedHeader {
    if (data.len < 2) return CodecError.PacketTooShort;
    const first_byte = data[0];
    const type_val: u4 = @intCast(first_byte >> 4);
    const flags: u4 = @intCast(first_byte & 0x0F);

    const packet_type: PacketType = @enumFromInt(type_val);

    const rl = try decodeRemainingLength(data[1..]);
    return .{
        .packet_type = packet_type,
        .flags = flags,
        .remaining_length = rl.value,
        .header_size = 1 + rl.bytes_consumed,
    };
}

/// 固定ヘッダをエンコード
pub fn encodeFixedHeader(buf: []u8, packet_type: PacketType, flags: u4, remaining_length: u32) ![]const u8 {
    if (buf.len < 5) return CodecError.PacketTooShort;
    buf[0] = (@as(u8, @intFromEnum(packet_type)) << 4) | @as(u8, flags);
    const rl = try encodeRemainingLength(buf[1..5], remaining_length);
    return buf[0 .. 1 + rl.len];
}

// ── CONNECT パケット ────────────────────────────────────────

/// CONNECT パケットをバイト列にエンコード
pub fn encodeConnect(allocator: Allocator, pkt: *const ConnectPacket) ![]u8 {
    var list = ManagedArrayList(u8).init(allocator);
    errdefer list.deinit();

    // Variable header
    // Protocol Name
    try appendString(&list, pkt.protocol_name);
    // Protocol Level
    try list.append(pkt.protocol_level);
    // Connect Flags
    try list.append(@bitCast(pkt.flags));
    // Keep Alive
    try list.append(@intCast((pkt.keep_alive >> 8) & 0xFF));
    try list.append(@intCast(pkt.keep_alive & 0xFF));

    // Payload
    try appendString(&list, pkt.client_id);
    if (pkt.flags.will_flag) {
        if (pkt.will_topic) |t| try appendString(&list, t);
        if (pkt.will_message) |m| try appendString(&list, m);
    }
    if (pkt.flags.username_flag) {
        if (pkt.username) |u| try appendString(&list, u);
    }
    if (pkt.flags.password_flag) {
        if (pkt.password) |p| try appendString(&list, p);
    }

    // Fixed header + variable header + payload
    var result = ManagedArrayList(u8).init(allocator);
    errdefer result.deinit();
    var hdr_buf: [5]u8 = undefined;
    const hdr = try encodeFixedHeader(&hdr_buf, .connect, 0, @intCast(list.items.len));
    try result.appendSlice(hdr);
    try result.appendSlice(list.items);
    list.deinit();

    return result.toOwnedSlice();
}

/// バイト列から CONNECT パケットをデコード (remaining_length バイト分のデータを受け取る)
pub fn decodeConnect(allocator: Allocator, data: []const u8) !ConnectPacket {
    var pos: usize = 0;

    // Protocol Name
    const proto = try decodeString(data[pos..]);
    pos += proto.bytes_consumed;

    // Protocol Level
    if (pos >= data.len) return CodecError.PacketTooShort;
    const level = data[pos];
    pos += 1;

    // Connect Flags
    if (pos >= data.len) return CodecError.PacketTooShort;
    const flags: ConnectFlags = @bitCast(data[pos]);
    pos += 1;

    // Keep Alive
    if (pos + 2 > data.len) return CodecError.PacketTooShort;
    const keep_alive = try decodeU16(data[pos..]);
    pos += 2;

    // Payload: Client ID
    const cid = try decodeString(data[pos..]);
    pos += cid.bytes_consumed;
    const client_id = try allocator.dupe(u8, cid.value);
    errdefer allocator.free(client_id);

    // Will Topic / Message
    var will_topic: ?[]const u8 = null;
    var will_message: ?[]const u8 = null;
    errdefer {
        if (will_topic) |t| allocator.free(t);
        if (will_message) |m| allocator.free(m);
    }
    if (flags.will_flag) {
        const wt = try decodeString(data[pos..]);
        pos += wt.bytes_consumed;
        will_topic = try allocator.dupe(u8, wt.value);

        const wm = try decodeString(data[pos..]);
        pos += wm.bytes_consumed;
        will_message = try allocator.dupe(u8, wm.value);
    }

    // Username
    var username: ?[]const u8 = null;
    errdefer if (username) |u| allocator.free(u);
    if (flags.username_flag) {
        const un = try decodeString(data[pos..]);
        pos += un.bytes_consumed;
        username = try allocator.dupe(u8, un.value);
    }

    // Password
    var password: ?[]const u8 = null;
    errdefer if (password) |p| allocator.free(p);
    if (flags.password_flag) {
        const pw = try decodeString(data[pos..]);
        pos += pw.bytes_consumed;
        password = try allocator.dupe(u8, pw.value);
    }

    return .{
        .protocol_name = proto.value,
        .protocol_level = level,
        .flags = flags,
        .keep_alive = keep_alive,
        .client_id = client_id,
        .will_topic = will_topic,
        .will_message = will_message,
        .username = username,
        .password = password,
    };
}

// ── CONNACK パケット ────────────────────────────────────────

pub fn encodeConnack(buf: []u8, pkt: *const ConnackPacket) ![]const u8 {
    // CONNACK は固定サイズ: 固定ヘッダ(2) + 可変ヘッダ(2) = 4バイト
    if (buf.len < 4) return CodecError.PacketTooShort;
    buf[0] = 0x20; // CONNACK type=2, flags=0
    buf[1] = 0x02; // remaining length = 2
    buf[2] = if (pkt.session_present) @as(u8, 0x01) else @as(u8, 0x00);
    buf[3] = @intFromEnum(pkt.return_code);
    return buf[0..4];
}

pub fn decodeConnack(data: []const u8) !ConnackPacket {
    if (data.len < 2) return CodecError.PacketTooShort;
    return .{
        .session_present = (data[0] & 0x01) != 0,
        .return_code = @enumFromInt(data[1]),
    };
}

// ── PUBLISH パケット ────────────────────────────────────────

pub fn encodePublish(allocator: Allocator, pkt: *const PublishPacket) ![]u8 {
    var list = ManagedArrayList(u8).init(allocator);
    errdefer list.deinit();

    // Variable header: topic name
    try appendString(&list, pkt.topic);

    // Packet ID (QoS > 0)
    if (pkt.qos != .at_most_once) {
        const pid = pkt.packet_id orelse return CodecError.MalformedPacket;
        try list.append(@intCast((pid >> 8) & 0xFF));
        try list.append(@intCast(pid & 0xFF));
    }

    // Payload
    try list.appendSlice(pkt.payload);

    // Fixed header
    var flags: u4 = 0;
    if (pkt.dup) flags |= 0x08;
    flags |= @as(u4, @intFromEnum(pkt.qos)) << 1;
    if (pkt.retain) flags |= 0x01;

    var result = ManagedArrayList(u8).init(allocator);
    errdefer result.deinit();
    var hdr_buf: [5]u8 = undefined;
    const hdr = try encodeFixedHeader(&hdr_buf, .publish, flags, @intCast(list.items.len));
    try result.appendSlice(hdr);
    try result.appendSlice(list.items);
    list.deinit();

    return result.toOwnedSlice();
}

pub fn decodePublish(allocator: Allocator, flags: u4, data: []const u8) !PublishPacket {
    const dup = (flags & 0x08) != 0;
    const qos = QoS.fromInt(@intCast((flags >> 1) & 0x03));
    const retain = (flags & 0x01) != 0;

    var pos: usize = 0;
    const topic_result = try decodeString(data[pos..]);
    pos += topic_result.bytes_consumed;
    const topic = try allocator.dupe(u8, topic_result.value);
    errdefer allocator.free(topic);

    var packet_id: ?u16 = null;
    if (qos != .at_most_once) {
        packet_id = try decodeU16(data[pos..]);
        pos += 2;
    }

    const payload = try allocator.dupe(u8, data[pos..]);

    return .{
        .dup = dup,
        .qos = qos,
        .retain = retain,
        .topic = topic,
        .packet_id = packet_id,
        .payload = payload,
    };
}

// ── PUBACK パケット ─────────────────────────────────────────

pub fn encodePuback(buf: []u8, pkt: *const PubackPacket) ![]const u8 {
    if (buf.len < 4) return CodecError.PacketTooShort;
    buf[0] = 0x40; // PUBACK type=4, flags=0
    buf[1] = 0x02; // remaining length = 2
    buf[2] = @intCast((pkt.packet_id >> 8) & 0xFF);
    buf[3] = @intCast(pkt.packet_id & 0xFF);
    return buf[0..4];
}

pub fn decodePuback(data: []const u8) !PubackPacket {
    if (data.len < 2) return CodecError.PacketTooShort;
    return .{ .packet_id = try decodeU16(data) };
}

// ── SUBSCRIBE パケット ──────────────────────────────────────

pub fn encodeSubscribe(allocator: Allocator, pkt: *const SubscribePacket) ![]u8 {
    var list = ManagedArrayList(u8).init(allocator);
    errdefer list.deinit();

    // Packet ID
    try list.append(@intCast((pkt.packet_id >> 8) & 0xFF));
    try list.append(@intCast(pkt.packet_id & 0xFF));

    // Topic Filters
    for (pkt.topics) |tf| {
        try appendString(&list, tf.filter);
        try list.append(@intFromEnum(tf.qos));
    }

    var result = ManagedArrayList(u8).init(allocator);
    errdefer result.deinit();
    var hdr_buf: [5]u8 = undefined;
    const hdr = try encodeFixedHeader(&hdr_buf, .subscribe, 0x02, @intCast(list.items.len));
    try result.appendSlice(hdr);
    try result.appendSlice(list.items);
    list.deinit();

    return result.toOwnedSlice();
}

pub fn decodeSubscribe(allocator: Allocator, data: []const u8) !SubscribePacket {
    if (data.len < 2) return CodecError.PacketTooShort;
    var pos: usize = 0;
    const packet_id = try decodeU16(data[pos..]);
    pos += 2;

    var topics = ManagedArrayList(TopicFilter).init(allocator);
    errdefer {
        for (topics.items) |tf| allocator.free(tf.filter);
        topics.deinit();
    }

    while (pos < data.len) {
        const filter_result = try decodeString(data[pos..]);
        pos += filter_result.bytes_consumed;
        if (pos >= data.len) return CodecError.PacketTooShort;
        const qos_byte = data[pos];
        pos += 1;
        const filter_copy = try allocator.dupe(u8, filter_result.value);
        try topics.append(.{
            .filter = filter_copy,
            .qos = QoS.fromInt(@intCast(qos_byte & 0x03)),
        });
    }

    return .{
        .packet_id = packet_id,
        .topics = try topics.toOwnedSlice(),
    };
}

// ── SUBACK パケット ─────────────────────────────────────────

pub fn encodeSuback(allocator: Allocator, pkt: *const SubackPacket) ![]u8 {
    const payload_len: u32 = @intCast(2 + pkt.return_codes.len);

    var result = ManagedArrayList(u8).init(allocator);
    errdefer result.deinit();

    var hdr_buf: [5]u8 = undefined;
    const hdr = try encodeFixedHeader(&hdr_buf, .suback, 0, payload_len);
    try result.appendSlice(hdr);

    // Packet ID
    try result.append(@intCast((pkt.packet_id >> 8) & 0xFF));
    try result.append(@intCast(pkt.packet_id & 0xFF));

    // Return Codes
    for (pkt.return_codes) |rc| {
        try result.append(@intFromEnum(rc));
    }

    return result.toOwnedSlice();
}

pub fn decodeSuback(allocator: Allocator, data: []const u8) !SubackPacket {
    if (data.len < 3) return CodecError.PacketTooShort;
    const packet_id = try decodeU16(data[0..]);
    const codes_data = data[2..];
    const return_codes = try allocator.alloc(SubackReturnCode, codes_data.len);
    for (codes_data, 0..) |byte, i| {
        return_codes[i] = @enumFromInt(byte);
    }
    return .{
        .packet_id = packet_id,
        .return_codes = return_codes,
    };
}

// ── UNSUBSCRIBE パケット ────────────────────────────────────

pub fn encodeUnsubscribe(allocator: Allocator, pkt: *const UnsubscribePacket) ![]u8 {
    var list = ManagedArrayList(u8).init(allocator);
    errdefer list.deinit();

    try list.append(@intCast((pkt.packet_id >> 8) & 0xFF));
    try list.append(@intCast(pkt.packet_id & 0xFF));

    for (pkt.topics) |t| {
        try appendString(&list, t);
    }

    var result = ManagedArrayList(u8).init(allocator);
    errdefer result.deinit();
    var hdr_buf: [5]u8 = undefined;
    const hdr = try encodeFixedHeader(&hdr_buf, .unsubscribe, 0x02, @intCast(list.items.len));
    try result.appendSlice(hdr);
    try result.appendSlice(list.items);
    list.deinit();

    return result.toOwnedSlice();
}

pub fn decodeUnsubscribe(allocator: Allocator, data: []const u8) !UnsubscribePacket {
    if (data.len < 2) return CodecError.PacketTooShort;
    var pos: usize = 0;
    const packet_id = try decodeU16(data[pos..]);
    pos += 2;

    var topics = ManagedArrayList([]const u8).init(allocator);
    errdefer {
        for (topics.items) |t| allocator.free(t);
        topics.deinit();
    }

    while (pos < data.len) {
        const s = try decodeString(data[pos..]);
        pos += s.bytes_consumed;
        try topics.append(try allocator.dupe(u8, s.value));
    }

    return .{
        .packet_id = packet_id,
        .topics = try topics.toOwnedSlice(),
    };
}

// ── UNSUBACK パケット ───────────────────────────────────────

pub fn encodeUnsuback(buf: []u8, pkt: *const UnsubackPacket) ![]const u8 {
    if (buf.len < 4) return CodecError.PacketTooShort;
    buf[0] = 0xB0; // UNSUBACK type=11, flags=0
    buf[1] = 0x02;
    buf[2] = @intCast((pkt.packet_id >> 8) & 0xFF);
    buf[3] = @intCast(pkt.packet_id & 0xFF);
    return buf[0..4];
}

// ── PINGREQ / PINGRESP / DISCONNECT ────────────────────────

pub fn encodePingreq(buf: []u8) ![]const u8 {
    if (buf.len < 2) return CodecError.PacketTooShort;
    buf[0] = 0xC0;
    buf[1] = 0x00;
    return buf[0..2];
}

pub fn encodePingresp(buf: []u8) ![]const u8 {
    if (buf.len < 2) return CodecError.PacketTooShort;
    buf[0] = 0xD0;
    buf[1] = 0x00;
    return buf[0..2];
}

pub fn encodeDisconnect(buf: []u8) ![]const u8 {
    if (buf.len < 2) return CodecError.PacketTooShort;
    buf[0] = 0xE0;
    buf[1] = 0x00;
    return buf[0..2];
}

// ── ヘルパー ────────────────────────────────────────────────

fn appendString(list: *ManagedArrayList(u8), str: []const u8) !void {
    try list.append(@intCast((str.len >> 8) & 0xFF));
    try list.append(@intCast(str.len & 0xFF));
    try list.appendSlice(str);
}

// ── テスト ──────────────────────────────────────────────────

test "remaining length: encode and decode round-trip" {
    var buf: [4]u8 = undefined;

    // 0
    const r0 = try encodeRemainingLength(&buf, 0);
    try std.testing.expectEqualSlices(u8, &.{0x00}, r0);
    const d0 = try decodeRemainingLength(r0);
    try std.testing.expectEqual(@as(u32, 0), d0.value);

    // 127 (1バイト最大値)
    const r127 = try encodeRemainingLength(&buf, 127);
    try std.testing.expectEqualSlices(u8, &.{0x7F}, r127);
    const d127 = try decodeRemainingLength(r127);
    try std.testing.expectEqual(@as(u32, 127), d127.value);

    // 128 (2バイト最小値)
    const r128 = try encodeRemainingLength(&buf, 128);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, r128);
    const d128 = try decodeRemainingLength(r128);
    try std.testing.expectEqual(@as(u32, 128), d128.value);

    // 16383 (2バイト最大値)
    const r16383 = try encodeRemainingLength(&buf, 16383);
    const d16383 = try decodeRemainingLength(r16383);
    try std.testing.expectEqual(@as(u32, 16383), d16383.value);

    // 268435455 (4バイト最大値)
    const r_max = try encodeRemainingLength(&buf, 268_435_455);
    const d_max = try decodeRemainingLength(r_max);
    try std.testing.expectEqual(@as(u32, 268_435_455), d_max.value);
}

test "string: encode and decode round-trip" {
    var buf: [256]u8 = undefined;
    const encoded = try encodeString(&buf, "hello");
    try std.testing.expectEqual(@as(usize, 7), encoded.len);
    try std.testing.expectEqual(@as(u8, 0x00), encoded[0]);
    try std.testing.expectEqual(@as(u8, 0x05), encoded[1]);

    const decoded = try decodeString(encoded);
    try std.testing.expectEqualStrings("hello", decoded.value);
    try std.testing.expectEqual(@as(usize, 7), decoded.bytes_consumed);
}

test "fixed header: encode and decode" {
    var buf: [5]u8 = undefined;
    const encoded = try encodeFixedHeader(&buf, .publish, 0x03, 300);
    const decoded = try decodeFixedHeader(encoded);
    try std.testing.expectEqual(PacketType.publish, decoded.packet_type);
    try std.testing.expectEqual(@as(u4, 0x03), decoded.flags);
    try std.testing.expectEqual(@as(u32, 300), decoded.remaining_length);
}

test "CONNACK: encode and decode" {
    var buf: [4]u8 = undefined;
    const pkt = ConnackPacket{ .session_present = true, .return_code = .accepted };
    const encoded = try encodeConnack(&buf, &pkt);
    try std.testing.expectEqual(@as(usize, 4), encoded.len);

    // data 部分 (remaining length 以降) でデコード
    const decoded = try decodeConnack(encoded[2..]);
    try std.testing.expectEqual(true, decoded.session_present);
    try std.testing.expectEqual(ConnectReturnCode.accepted, decoded.return_code);
}

test "CONNECT: encode and decode round-trip" {
    const allocator = std.testing.allocator;
    const pkt = ConnectPacket{
        .client_id = "test-client",
        .flags = .{
            .clean_session = true,
            .username_flag = true,
            .password_flag = true,
        },
        .keep_alive = 60,
        .username = "user",
        .password = "pass",
    };
    const encoded = try encodeConnect(allocator, &pkt);
    defer allocator.free(encoded);

    // 固定ヘッダをスキップしてデコード
    const header = try decodeFixedHeader(encoded);
    const data = encoded[header.header_size..];
    const decoded = try decodeConnect(allocator, data);
    defer {
        allocator.free(decoded.client_id);
        if (decoded.username) |u| allocator.free(u);
        if (decoded.password) |p| allocator.free(p);
    }

    try std.testing.expectEqualStrings("test-client", decoded.client_id);
    try std.testing.expectEqual(true, decoded.flags.clean_session);
    try std.testing.expectEqual(@as(u16, 60), decoded.keep_alive);
    try std.testing.expectEqualStrings("user", decoded.username.?);
    try std.testing.expectEqualStrings("pass", decoded.password.?);
}

test "PUBLISH: encode and decode round-trip" {
    const allocator = std.testing.allocator;
    const pkt = PublishPacket{
        .topic = "sensor/temp",
        .payload = "25.5",
        .qos = .at_least_once,
        .packet_id = 42,
        .retain = true,
    };
    const encoded = try encodePublish(allocator, &pkt);
    defer allocator.free(encoded);

    const header = try decodeFixedHeader(encoded);
    const data = encoded[header.header_size..];
    const decoded = try decodePublish(allocator, header.flags, data);
    defer {
        allocator.free(decoded.topic);
        allocator.free(decoded.payload);
    }

    try std.testing.expectEqualStrings("sensor/temp", decoded.topic);
    try std.testing.expectEqualStrings("25.5", decoded.payload);
    try std.testing.expectEqual(QoS.at_least_once, decoded.qos);
    try std.testing.expectEqual(@as(?u16, 42), decoded.packet_id);
    try std.testing.expectEqual(true, decoded.retain);
}

test "PUBACK: encode and decode" {
    var buf: [4]u8 = undefined;
    const pkt = PubackPacket{ .packet_id = 1234 };
    const encoded = try encodePuback(&buf, &pkt);
    const decoded = try decodePuback(encoded[2..]);
    try std.testing.expectEqual(@as(u16, 1234), decoded.packet_id);
}

test "SUBSCRIBE: encode and decode round-trip" {
    const allocator = std.testing.allocator;
    const topics = [_]TopicFilter{
        .{ .filter = "sensor/+/temp", .qos = .at_least_once },
        .{ .filter = "alert/#", .qos = .at_most_once },
    };
    const pkt = SubscribePacket{
        .packet_id = 100,
        .topics = &topics,
    };
    const encoded = try encodeSubscribe(allocator, &pkt);
    defer allocator.free(encoded);

    const header = try decodeFixedHeader(encoded);
    const data = encoded[header.header_size..];
    const decoded = try decodeSubscribe(allocator, data);
    defer {
        for (decoded.topics) |tf| allocator.free(tf.filter);
        allocator.free(decoded.topics);
    }

    try std.testing.expectEqual(@as(u16, 100), decoded.packet_id);
    try std.testing.expectEqual(@as(usize, 2), decoded.topics.len);
    try std.testing.expectEqualStrings("sensor/+/temp", decoded.topics[0].filter);
    try std.testing.expectEqual(QoS.at_least_once, decoded.topics[0].qos);
    try std.testing.expectEqualStrings("alert/#", decoded.topics[1].filter);
}

test "PINGREQ, PINGRESP, DISCONNECT encoding" {
    var buf: [2]u8 = undefined;

    const pingreq = try encodePingreq(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 0xC0, 0x00 }, pingreq);

    const pingresp = try encodePingresp(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 0xD0, 0x00 }, pingresp);

    const disconnect = try encodeDisconnect(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 0xE0, 0x00 }, disconnect);
}
