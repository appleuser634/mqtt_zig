const std = @import("std");
const types = @import("mqtt_types");
const codec = @import("mqtt_codec");
const pkt = @import("mqtt_packet");

const net = std.Io.net;
const Allocator = std.mem.Allocator;

// ── ベンチマーク用 軽量 MQTT クライアント ───────────────────
// fork なし・1接続で N メッセージを高速に送受信する

fn mqttConnect(io: std.Io, host: []const u8, port: u16, client_id: []const u8, allocator: Allocator) !net.Stream {
    const address = try net.IpAddress.parseIp4(host, port);
    const stream = try net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp });

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    const connect_pkt = pkt.ConnectPacket{ .client_id = client_id, .keep_alive = 300 };
    const encoded = try codec.encodeConnect(allocator, &connect_pkt);
    defer allocator.free(encoded);
    try writer.interface.writeAll(encoded);
    try writer.interface.flush();

    // CONNACK 読み取り
    var hdr: [4]u8 = undefined;
    try reader.interface.readSliceAll(&hdr);
    if (hdr[0] != 0x20 or hdr[3] != 0x00) return error.ConnectionRefused;

    return stream;
}

fn mqttSubscribe(stream: net.Stream, io: std.Io, topic: []const u8, allocator: Allocator) !void {
    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    const topics = [_]pkt.TopicFilter{.{ .filter = topic, .qos = .at_most_once }};
    const sub_pkt = pkt.SubscribePacket{ .packet_id = 1, .topics = &topics };
    const encoded = try codec.encodeSubscribe(allocator, &sub_pkt);
    defer allocator.free(encoded);
    try writer.interface.writeAll(encoded);
    try writer.interface.flush();

    // SUBACK
    var hdr: [5]u8 = undefined;
    try reader.interface.readSliceAll(hdr[0..2]);
    const rl = hdr[1];
    try reader.interface.readSliceAll(hdr[0..rl]);
}

fn mqttPublishRaw(writer: *std.Io.Writer, topic: []const u8, payload: []const u8) !void {
    // PUBLISH パケットを直接構築（アロケーションなし）
    const topic_len: u16 = @intCast(topic.len);
    const remaining: u32 = 2 + @as(u32, topic_len) + @as(u32, @intCast(payload.len));

    // Fixed header: type=3(PUBLISH), flags=0, QoS 0
    try writer.writeAll(&[_]u8{0x30});

    // Remaining length (1-4 bytes)
    var rl = remaining;
    while (true) {
        var b: u8 = @intCast(rl % 128);
        rl /= 128;
        if (rl > 0) b |= 0x80;
        try writer.writeAll(&[_]u8{b});
        if (rl == 0) break;
    }

    // Topic
    try writer.writeAll(&[_]u8{ @intCast(topic_len >> 8), @intCast(topic_len & 0xFF) });
    try writer.writeAll(topic);
    // Payload
    try writer.writeAll(payload);
}

fn mqttDisconnect(stream: net.Stream, io: std.Io) void {
    var write_buf: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(&[_]u8{ 0xE0, 0x00 }) catch {};
    writer.interface.flush() catch {};
    stream.close(io);
}

/// Zig 0.16: std.Io.Timestamp でナノ秒タイムスタンプを取得
var bench_io: std.Io = undefined;

fn timestampNs() i96 {
    const ts = std.Io.Timestamp.now(bench_io, .awake);
    return ts.nanoseconds;
}

// ── ベンチマークテスト ─────────────────────────────────────

fn benchThroughput(io: std.Io, host: []const u8, port: u16, msg_count: u32, allocator: Allocator) !void {
    // サブスクライバー接続
    const sub_stream = try mqttConnect(io, host, port, "bench-sub", allocator);
    try mqttSubscribe(sub_stream, io, "bench/tp", allocator);

    // パブリッシャー接続
    const pub_stream = try mqttConnect(io, host, port, "bench-pub", allocator);

    var pub_write_buf: [8192]u8 = undefined;
    var pub_writer = pub_stream.writer(io, &pub_write_buf);

    const payload = "benchmark-payload-64bytes-padding-for-realistic-message-size!!";

    // 送信計測
    const start = timestampNs();
    for (0..msg_count) |_| {
        try mqttPublishRaw(&pub_writer.interface, "bench/tp", payload);
    }
    try pub_writer.interface.flush();
    const pub_end = timestampNs();

    // 受信計測
    var sub_read_buf: [65536]u8 = undefined;
    var sub_reader = sub_stream.reader(io, &sub_read_buf);
    var received: u32 = 0;
    while (received < msg_count) {
        var hdr_buf: [5]u8 = undefined;
        try sub_reader.interface.readSliceAll(hdr_buf[0..1]);
        // Remaining length
        var rl_bytes: usize = 0;
        var remaining: u32 = 0;
        var multiplier: u32 = 1;
        while (rl_bytes < 4) {
            try sub_reader.interface.readSliceAll(hdr_buf[1 + rl_bytes ..][0..1]);
            remaining += @as(u32, hdr_buf[1 + rl_bytes] & 0x7F) * multiplier;
            rl_bytes += 1;
            if (hdr_buf[rl_bytes] & 0x80 == 0) break;
            multiplier *= 128;
        }
        // Skip payload
        var skip_buf: [4096]u8 = undefined;
        var left = remaining;
        while (left > 0) {
            const chunk = @min(left, skip_buf.len);
            try sub_reader.interface.readSliceAll(skip_buf[0..chunk]);
            left -= chunk;
        }
        received += 1;
    }
    const end = timestampNs();

    const pub_ms = @as(f64, @floatFromInt(pub_end - start)) / 1_000_000.0;
    const total_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
    const rate = @as(f64, @floatFromInt(msg_count)) / (total_ms / 1000.0);

    std.debug.print("  Publish:  {d:.1} ms ({d} msgs)\n", .{ pub_ms, msg_count });
    std.debug.print("  E2E:      {d:.1} ms ({d:.0} msg/s)\n", .{ total_ms, rate });

    mqttDisconnect(pub_stream, io);
    mqttDisconnect(sub_stream, io);
}

fn benchConnections(io: std.Io, host: []const u8, port: u16, count: u32, allocator: Allocator) !void {
    var streams = try allocator.alloc(net.Stream, count);
    defer allocator.free(streams);

    const start = timestampNs();
    for (0..count) |i| {
        var id_buf: [32]u8 = undefined;
        const cid = std.fmt.bufPrint(&id_buf, "bench-c{d}", .{i}) catch "bench-cx";
        streams[i] = mqttConnect(io, host, port, cid, allocator) catch |err| {
            std.debug.print("  Connection {d} failed: {s}\n", .{ i, @errorName(err) });
            // 失敗分を切り詰め
            streams = streams[0..i];
            break;
        };
    }
    const end = timestampNs();
    const ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
    const connected = streams.len;
    std.debug.print("  {d} connections in {d:.1} ms ({d:.0} conn/s)\n", .{
        connected,
        ms,
        @as(f64, @floatFromInt(connected)) / (ms / 1000.0),
    });

    for (streams) |s| mqttDisconnect(s, io);
}

fn benchFanout(io: std.Io, host: []const u8, port: u16, sub_count: u32, msg_count: u32, allocator: Allocator) !void {
    // サブスクライバー N 台
    var sub_streams = try allocator.alloc(net.Stream, sub_count);
    defer allocator.free(sub_streams);
    for (0..sub_count) |i| {
        var id_buf: [32]u8 = undefined;
        const cid = std.fmt.bufPrint(&id_buf, "bench-fo-s{d}", .{i}) catch "bench-fo-sx";
        sub_streams[i] = try mqttConnect(io, host, port, cid, allocator);
        try mqttSubscribe(sub_streams[i], io, "bench/fo", allocator);
    }

    // パブリッシャー 1 台
    const pub_stream = try mqttConnect(io, host, port, "bench-fo-pub", allocator);
    var pub_write_buf: [8192]u8 = undefined;
    var pub_writer = pub_stream.writer(io, &pub_write_buf);

    const start = timestampNs();
    for (0..msg_count) |_| {
        try mqttPublishRaw(&pub_writer.interface, "bench/fo", "fanout-msg");
    }
    try pub_writer.interface.flush();

    // 全サブスクライバーで msg_count メッセージ受信
    for (sub_streams) |ss| {
        var read_buf: [65536]u8 = undefined;
        var reader = ss.reader(io, &read_buf);
        for (0..msg_count) |_| {
            var hdr: [5]u8 = undefined;
            try reader.interface.readSliceAll(hdr[0..1]);
            var rl_bytes: usize = 0;
            var remaining: u32 = 0;
            var mult: u32 = 1;
            while (rl_bytes < 4) {
                try reader.interface.readSliceAll(hdr[1 + rl_bytes ..][0..1]);
                remaining += @as(u32, hdr[1 + rl_bytes] & 0x7F) * mult;
                rl_bytes += 1;
                if (hdr[rl_bytes] & 0x80 == 0) break;
                mult *= 128;
            }
            var skip: [4096]u8 = undefined;
            var left = remaining;
            while (left > 0) {
                const chunk = @min(left, skip.len);
                try reader.interface.readSliceAll(skip[0..chunk]);
                left -= chunk;
            }
        }
    }
    const end = timestampNs();

    const total_deliveries = sub_count * msg_count;
    const ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
    const rate = @as(f64, @floatFromInt(total_deliveries)) / (ms / 1000.0);
    std.debug.print("  {d} deliveries in {d:.1} ms ({d:.0} msg/s)\n", .{ total_deliveries, ms, rate });

    mqttDisconnect(pub_stream, io);
    for (sub_streams) |s| mqttDisconnect(s, io);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    bench_io = io;

    // 引数: mqtt-bench [host] [port]
    var iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = iter.skip();
    const host = iter.next() orelse "127.0.0.1";
    const port_str = iter.next() orelse "1883";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 1883;

    std.debug.print("\n=== MQTT Benchmark (target: {s}:{d}) ===\n\n", .{ host, port });

    std.debug.print("--- Test 1: 接続スループット (50 clients) ---\n", .{});
    benchConnections(io, host, port, 50, allocator) catch |err|
        std.debug.print("  FAILED: {s}\n", .{@errorName(err)});

    std.debug.print("\n--- Test 2: メッセージスループット (10000 msgs, QoS 0) ---\n", .{});
    benchThroughput(io, host, port, 10000, allocator) catch |err|
        std.debug.print("  FAILED: {s}\n", .{@errorName(err)});

    std.debug.print("\n--- Test 3: Fan-out (1 pub → 10 sub, 1000 msgs) ---\n", .{});
    benchFanout(io, host, port, 10, 1000, allocator) catch |err|
        std.debug.print("  FAILED: {s}\n", .{@errorName(err)});

    std.debug.print("\n--- Test 4: Fan-out (1 pub → 50 sub, 1000 msgs) ---\n", .{});
    benchFanout(io, host, port, 50, 1000, allocator) catch |err|
        std.debug.print("  FAILED: {s}\n", .{@errorName(err)});

    std.debug.print("\n=== Benchmark complete ===\n", .{});
}
