const std = @import("std");
const Server = @import("broker_server").Server;
const types = @import("mqtt_types");

/// Zig 0.16 "Juicy Main" パターン:
/// std.process.Init から事前初期化済みの allocator, io, args を受け取る
pub fn main(init: std.process.Init) !void {
    const port: u16 = parsePort(init);

    std.log.info("Starting MQTT Broker on port {d}...", .{port});

    var server = Server.init(init.gpa, init.io, port);
    defer server.deinit();
    server.run() catch |err| {
        std.log.err("Broker error: {s}", .{@errorName(err)});
        return err;
    };
}

/// コマンドライン引数からポート番号を取得
fn parsePort(init: std.process.Init) u16 {
    var iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = iter.skip(); // プログラム名スキップ
    if (iter.next()) |arg| {
        return std.fmt.parseInt(u16, arg, 10) catch types.DEFAULT_PORT;
    }
    return types.DEFAULT_PORT;
}
