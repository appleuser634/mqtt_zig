const std = @import("std");
const MqttClient = @import("mqtt_client").MqttClient;
const ConnectOptions = @import("mqtt_client").ConnectOptions;

/// Zig 0.16 "Juicy Main" — init.io / init.gpa を直接利用
pub fn main(init: std.process.Init) !void {
    const host = "127.0.0.1";
    const port: u16 = 1883;
    const topic = "test/topic";
    const message = "Hello from mqtt-zig!";
    const count: u32 = 5;

    std.log.info("Connecting to {s}:{d}...", .{ host, port });

    var entropy: u32 = undefined;
    const seed_addr: usize = @intFromPtr(&entropy);
    var id_buf: [32]u8 = undefined;
    const client_id = std.fmt.bufPrint(&id_buf, "mqtt-pub-{x}", .{seed_addr}) catch "mqtt-pub-default";

    const client = try MqttClient.connect(init.gpa, init.io, host, port, ConnectOptions{
        .client_id = client_id,
    });

    std.log.info("Connected. Publishing {d} message(s) to '{s}'...", .{ count, topic });

    for (0..count) |i| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} [{d}]", .{ message, i + 1 }) catch message;

        try client.publish(topic, msg, .at_most_once, false);
        std.log.info("Published: {s}", .{msg});

        // Zig 0.16: std.Io.Clock.Duration.sleep で非同期スリープ
        if (i + 1 < count) {
            std.Io.Clock.Duration.sleep(.{
                .clock = .awake,
                .raw = .fromMilliseconds(500),
            }, init.io) catch {};
        }
    }

    try client.disconnect();
    std.log.info("Disconnected.", .{});
}
