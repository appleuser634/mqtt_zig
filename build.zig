const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── 共有モジュール ──────────────────────────────────────
    const mqtt_types = b.createModule(.{
        .root_source_file = b.path("src/mqtt/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mqtt_topic = b.createModule(.{
        .root_source_file = b.path("src/mqtt/topic.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mqtt_packet = b.createModule(.{
        .root_source_file = b.path("src/mqtt/packet.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mqtt_types", .module = mqtt_types },
        },
    });
    const mqtt_codec = b.createModule(.{
        .root_source_file = b.path("src/mqtt/codec.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mqtt_types", .module = mqtt_types },
            .{ .name = "mqtt_packet", .module = mqtt_packet },
        },
    });
    const mqtt_transport = b.createModule(.{
        .root_source_file = b.path("src/client/transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mqtt_types", .module = mqtt_types },
            .{ .name = "mqtt_codec", .module = mqtt_codec },
            .{ .name = "mqtt_packet", .module = mqtt_packet },
        },
    });
    const mqtt_client = b.createModule(.{
        .root_source_file = b.path("src/client/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mqtt_types", .module = mqtt_types },
            .{ .name = "mqtt_codec", .module = mqtt_codec },
            .{ .name = "mqtt_packet", .module = mqtt_packet },
            .{ .name = "mqtt_transport", .module = mqtt_transport },
        },
    });
    const broker_session = b.createModule(.{
        .root_source_file = b.path("src/broker/session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mqtt_types", .module = mqtt_types },
            .{ .name = "mqtt_topic", .module = mqtt_topic },
        },
    });
    const broker_retain = b.createModule(.{
        .root_source_file = b.path("src/broker/retain.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mqtt_types", .module = mqtt_types },
            .{ .name = "mqtt_topic", .module = mqtt_topic },
        },
    });
    const broker_connection = b.createModule(.{
        .root_source_file = b.path("src/broker/connection.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mqtt_types", .module = mqtt_types },
            .{ .name = "mqtt_codec", .module = mqtt_codec },
            .{ .name = "mqtt_packet", .module = mqtt_packet },
            .{ .name = "broker_session", .module = broker_session },
            .{ .name = "broker_retain", .module = broker_retain },
        },
    });
    const broker_server = b.createModule(.{
        .root_source_file = b.path("src/broker/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mqtt_types", .module = mqtt_types },
            .{ .name = "broker_connection", .module = broker_connection },
            .{ .name = "broker_session", .module = broker_session },
            .{ .name = "broker_retain", .module = broker_retain },
        },
    });

    // ── ブローカー実行ファイル ───────────────────────────────
    const broker = b.addExecutable(.{
        .name = "mqtt-broker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/broker/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mqtt_types", .module = mqtt_types },
                .{ .name = "broker_server", .module = broker_server },
            },
        }),
    });
    b.installArtifact(broker);

    const run_broker = b.addRunArtifact(broker);
    if (b.args) |args| run_broker.addArgs(args);
    run_broker.has_side_effects = true;
    run_broker.stdio = .inherit;
    const broker_step = b.step("broker", "Run the MQTT broker");
    broker_step.dependOn(&run_broker.step);

    // ── パブリッシャー実行ファイル ───────────────────────────
    const publisher = b.addExecutable(.{
        .name = "mqtt-pub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/publisher/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mqtt_types", .module = mqtt_types },
                .{ .name = "mqtt_client", .module = mqtt_client },
            },
        }),
    });
    b.installArtifact(publisher);

    const run_pub = b.addRunArtifact(publisher);
    if (b.args) |args| run_pub.addArgs(args);
    run_pub.has_side_effects = true;
    run_pub.stdio = .inherit;
    const pub_step = b.step("pub", "Run the MQTT publisher");
    pub_step.dependOn(&run_pub.step);

    // ── サブスクライバー実行ファイル ─────────────────────────
    const subscriber = b.addExecutable(.{
        .name = "mqtt-sub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/subscriber/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mqtt_types", .module = mqtt_types },
                .{ .name = "mqtt_packet", .module = mqtt_packet },
                .{ .name = "mqtt_client", .module = mqtt_client },
            },
        }),
    });
    b.installArtifact(subscriber);

    const run_sub = b.addRunArtifact(subscriber);
    if (b.args) |args| run_sub.addArgs(args);
    run_sub.has_side_effects = true;
    run_sub.stdio = .inherit;
    const sub_step = b.step("sub", "Run the MQTT subscriber");
    sub_step.dependOn(&run_sub.step);

    // ── ベンチマーク実行ファイル ───────────────────────────
    const bench = b.addExecutable(.{
        .name = "mqtt-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mqtt_types", .module = mqtt_types },
                .{ .name = "mqtt_codec", .module = mqtt_codec },
                .{ .name = "mqtt_packet", .module = mqtt_packet },
            },
        }),
    });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    run_bench.has_side_effects = true;
    run_bench.stdio = .inherit;
    const bench_step = b.step("bench", "Run the MQTT benchmark");
    bench_step.dependOn(&run_bench.step);

    // ── テスト ──────────────────────────────────────────────
    const test_step = b.step("test", "Run unit tests");

    // types テスト (依存なし)
    const test_types = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mqtt/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_types).step);

    // codec テスト (types, packet に依存)
    const test_codec = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mqtt/codec.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mqtt_types", .module = mqtt_types },
                .{ .name = "mqtt_packet", .module = mqtt_packet },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_codec).step);

    // topic テスト (依存なし)
    const test_topic = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mqtt/topic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_topic).step);
}
