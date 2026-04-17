const std = @import("std");
const types = @import("mqtt_types");
const codec = @import("mqtt_codec");

const Allocator = types.Allocator;
const net = std.Io.net;

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

    /// バイト列を送信
    pub fn send(self: *Transport, data: []const u8) !void {
        var writer_buffer: [8192]u8 = undefined;
        var writer = self.stream.writer(self.io, &writer_buffer);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }

    /// 固定ヘッダを読み取り、残りのデータを含む完全なパケットを返す
    pub const ReadResult = struct {
        header: codec.FixedHeader,
        data: []u8,
    };

    pub fn readPacket(self: *Transport) !ReadResult {
        var reader_buffer: [8192]u8 = undefined;
        var reader = self.stream.reader(self.io, &reader_buffer);

        // 固定ヘッダの最初のバイトを読む
        var header_buf: [5]u8 = undefined;
        reader.interface.readSliceAll(header_buf[0..1]) catch |err| switch (err) {
            error.EndOfStream => return error.ConnectionClosed,
            else => return err,
        };

        // Remaining Length を読む (最大4バイト)
        var rl_len: usize = 0;
        while (rl_len < 4) {
            try reader.interface.readSliceAll(header_buf[1 + rl_len ..][0..1]);
            rl_len += 1;
            if (header_buf[rl_len] & 0x80 == 0) break;
        }

        const header = try codec.decodeFixedHeader(header_buf[0 .. 1 + rl_len]);

        // Remaining bytes を読む
        const data = try self.allocator.alloc(u8, header.remaining_length);
        errdefer self.allocator.free(data);
        try reader.interface.readSliceAll(data);

        return .{
            .header = header,
            .data = data,
        };
    }
};
