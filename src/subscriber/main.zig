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

    // 複数サブスクライバーを同時起動できるよう、ユニークな client_id を生成
    // スタック変数のアドレスをシードとして利用（プロセスごとに異なる）
    var entropy: u32 = undefined;
    const seed_addr: usize = @intFromPtr(&entropy);
    var id_buf: [32]u8 = undefined;
    const client_id = std.fmt.bufPrint(&id_buf, "mqtt-sub-{x}", .{seed_addr}) catch "mqtt-sub-default";

    const client = try MqttClient.connect(init.gpa, init.io, host, port, ConnectOptions{
        .client_id = client_id,
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
