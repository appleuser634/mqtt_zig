const std = @import("std");
const MqttClient = @import("mqtt_client").MqttClient;
const ConnectOptions = @import("mqtt_client").ConnectOptions;
const TopicFilter = @import("mqtt_packet").TopicFilter;

/// Zig 0.16 "Juicy Main"
pub fn main(init: std.process.Init) !void {
    const host = "127.0.0.1";
    const port: u16 = 1883;
    const topic_filter = "#";
    const max_messages: u32 = 10;

    std.log.info("Connecting to {s}:{d}...", .{ host, port });

    var client = try MqttClient.connect(init.gpa, init.io, host, port, ConnectOptions{
        .client_id = "mqtt-zig-sub",
    });

    const filters = [_]TopicFilter{
        .{ .filter = topic_filter, .qos = .at_most_once },
    };
    try client.subscribe(&filters);
    std.log.info("Subscribed to '{s}'. Waiting for messages...", .{topic_filter});

    var received: u32 = 0;
    while (received < max_messages) {
        const msg = try client.readMessage();
        defer msg.deinit(init.gpa);

        std.log.info("[{s}] {s}", .{ msg.topic, msg.payload });
        received += 1;
    }

    try client.disconnect();
    std.log.info("Disconnected after {d} message(s).", .{received});
}
