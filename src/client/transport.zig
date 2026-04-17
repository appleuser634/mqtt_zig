const std = @import("std");
const types = @import("mqtt_types");
const codec = @import("mqtt_codec");

const Allocator = types.Allocator;
const net = std.Io.net;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// TCP トランスポート層: MQTT パケットの読み書きを担当
pub const Transport = struct {
    stream: net.Stream,
    io: std.Io,
    allocator: Allocator,

    /// TCP 接続を確立
    pub fn connect(allocator: Allocator, io: std.Io, host: []const u8, port: u16) !Transport {
        const address = try net.IpAddress.parseIp4(host, port);
        const stream = try net.IpAddress.connect(&address, io, .{
            .mode = .stream,
            .protocol = .tcp,
        });
        return .{
            .stream = stream,
            .io = io,
            .allocator = allocator,
        };
    }

    /// 接続を閉じる
    pub fn close(self: *Transport) void {
        self.stream.close(self.io);
    }

    /// Writer を使って送信 (flush 込み)
    pub fn sendWith(w: *Writer, data: []const u8) !void {
        try w.writeAll(data);
        try w.flush();
    }

    /// Reader から1パケット読み取り
    pub const ReadResult = struct {
        header: codec.FixedHeader,
        data: []u8,
    };

    pub fn readPacketWith(r: *Reader, allocator: Allocator) !ReadResult {
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
};
