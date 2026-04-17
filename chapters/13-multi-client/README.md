# 第13章: 複数クライアントの統合

## 学習目標

- ブローカー・パブリッシャー・サブスクライバーを統合して動作させる
- 各実行バイナリで Juicy Main パターン（`std.process.Init`）を使用する
- メッセージルーティングの End-to-End フローを理解する
- 複数ターミナルでのデモ実行手順を習得する
- mosquitto クライアントとの相互運用テストを実施できる

---

## プロジェクト構成

本プロジェクトでは3つの実行可能バイナリを生成する。

```
mqtt_zig/
+-- build.zig
+-- src/
    +-- broker/
    |   +-- main.zig          # ブローカーのエントリポイント
    |   +-- server.zig        # TCP リスナー
    |   +-- connection.zig    # 接続ハンドラ
    |   +-- session.zig       # セッション管理
    |   +-- retain.zig        # Retained メッセージ
    |   +-- topic.zig         # トピックマッチング
    +-- publisher/
    |   +-- main.zig          # パブリッシャーのエントリポイント
    +-- subscriber/
        +-- main.zig          # サブスクライバーのエントリポイント
```

---

## build.zig の構成

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ブローカー
    const broker = b.addExecutable(.{
        .name = "mqtt-broker",
        .root_source_file = b.path("src/broker/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(broker);

    // パブリッシャー
    const publisher = b.addExecutable(.{
        .name = "mqtt-pub",
        .root_source_file = b.path("src/publisher/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(publisher);

    // サブスクライバー
    const subscriber = b.addExecutable(.{
        .name = "mqtt-sub",
        .root_source_file = b.path("src/subscriber/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(subscriber);

    // 個別ビルドステップ
    const broker_step = b.step("broker", "ブローカーをビルド");
    broker_step.dependOn(&broker.step);

    const pub_step = b.step("pub", "パブリッシャーをビルド");
    pub_step.dependOn(&publisher.step);

    const sub_step = b.step("sub", "サブスクライバーをビルド");
    sub_step.dependOn(&subscriber.step);
}
```

---

## Juicy Main: 全バイナリ共通のエントリポイント

Zig 0.16 では、3つの実行バイナリ全てで `std.process.Init` を受け取る Juicy Main パターンを使う。

### ブローカーの main.zig

```zig
const std = @import("std");
const MqttBroker = @import("server.zig").MqttBroker;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var broker = MqttBroker.init(allocator);
    defer broker.deinit(io);

    std.log.info("MQTT ブローカー起動: ポート 1883", .{});
    try broker.run(io, 1883);
}
```

### パブリッシャーの main.zig

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // ブローカーに接続
    const address = std.Io.net.IpAddress.parse("127.0.0.1", 1883);
    var stream = try address.connect(io, .{});
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    // CONNECT 送信
    try sendConnect(&writer, "mqtt-pub-client", .{
        .keep_alive = 30,
        .clean_session = true,
    });
    try writer.interface.flush();

    // CONNACK 受信
    const connack = try receiveConnack(&reader);
    if (connack.return_code != .accepted) {
        std.log.err("接続拒否: {}", .{connack.return_code});
        return;
    }
    std.log.info("CONNACK 受信: session_present={}", .{connack.session_present});

    // PUBLISH 送信
    // コマンドライン引数からトピックとメッセージを取得する想定
    const topic = "sensor/temp";
    const message = "25.3";

    try sendPublish(&writer, topic, message, .{
        .qos = 0,
        .retain = false,
    });
    try writer.interface.flush();
    std.log.info("PUBLISH 送信: topic={s}, payload={s}", .{ topic, message });

    // DISCONNECT 送信
    try writer.interface.writeAll(&[_]u8{ 0xE0, 0x00 });
    try writer.interface.flush();

    _ = allocator; // 将来的にコマンドライン解析で使用
}
```

### サブスクライバーの main.zig

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // ブローカーに接続
    const address = std.Io.net.IpAddress.parse("127.0.0.1", 1883);
    var stream = try address.connect(io, .{});
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    // CONNECT
    try sendConnect(&writer, "mqtt-sub-client", .{
        .keep_alive = 60,
        .clean_session = true,
    });
    try writer.interface.flush();
    _ = try receiveConnack(&reader);

    // SUBSCRIBE
    const topic_filter = "sensor/#";
    try sendSubscribe(&writer, topic_filter, 1);
    try writer.interface.flush();
    _ = try receiveSuback(&reader);
    std.log.info("サブスクライブ: {s}", .{topic_filter});

    std.log.info("メッセージ待受中... (Ctrl+C で終了)", .{});

    // メッセージ受信ループ
    while (true) {
        var header: [1]u8 = undefined;
        reader.interface.readSliceAll(&header) catch |err| {
            if (err == error.EndOfStream) return;
            return err;
        };

        const packet_type: u4 = @intCast(header[0] >> 4);

        switch (packet_type) {
            3 => { // PUBLISH
                const pub_msg = try decodePublish(header[0], &reader);
                std.log.info(
                    "受信: topic={s}, payload={s}, qos={d}",
                    .{ pub_msg.topic, pub_msg.payload, pub_msg.qos },
                );

                // QoS 1 なら PUBACK を返す
                if (pub_msg.qos >= 1) {
                    try sendPuback(&writer, pub_msg.packet_id);
                    try writer.interface.flush();
                }
            },
            13 => {}, // PINGRESP: 無視
            else => {
                std.log.warn("予期しないパケット: type={d}", .{packet_type});
            },
        }
    }

    _ = allocator;
}
```

---

## デモ実行手順

### ステップ1: ビルド

```bash
# 全バイナリをビルド
zig build

# または個別にビルド
zig build broker
zig build pub
zig build sub
```

### ステップ2: ブローカーを起動（ターミナル1）

```bash
$ ./zig-out/bin/mqtt-broker
info: MQTT ブローカー起動: ポート 1883
info: クライアント接続待ち...
```

### ステップ3: サブスクライバーを起動（ターミナル2）

```bash
$ ./zig-out/bin/mqtt-sub
info: CONNACK 受信: session_present=false
info: サブスクライブ: sensor/#
info: メッセージ待受中... (Ctrl+C で終了)
```

### ステップ4: パブリッシャーでメッセージ送信（ターミナル3）

```bash
$ ./zig-out/bin/mqtt-pub
info: CONNACK 受信: session_present=false
info: PUBLISH 送信: topic=sensor/temp, payload=25.3
```

### ステップ5: サブスクライバー側で受信を確認（ターミナル2）

```
info: 受信: topic=sensor/temp, payload=25.3, qos=0
```

---

## メッセージルーティングの End-to-End フロー

```
Publisher                    Broker                       Subscriber
   |                           |                              |
   |-- CONNECT --------------->|                              |
   |<-- CONNACK ---------------|                              |
   |                           |                              |
   |                           |<------------- CONNECT -------|
   |                           |------------- CONNACK ------->|
   |                           |<---------- SUBSCRIBE --------|
   |                           |------------ SUBACK --------->|
   |                           |                              |
   |-- PUBLISH --------------->|                              |
   |                           | (トピックマッチング)           |
   |                           |-- PUBLISH ------------------>|
   |                           |                              |
   |-- DISCONNECT ------------>|                              |
```

### ブローカー内部のルーティング処理

```zig
fn routeMessage(
    self: *Broker,
    io: *std.Io,
    source_client_id: []const u8,
    topic: []const u8,
    payload: []const u8,
    qos: u2,
    retain: bool,
) !void {
    // 1. Retained メッセージの処理 (Mutex)
    if (retain) {
        try self.retain_store.store(io, topic, payload, qos);
    }

    // 2. マッチするサブスクライバーを検索 (RwLock 読み取り)
    var subscribers_buf: [256]SubscriberInfo = undefined;
    const count = self.session_manager.getSubscribers(io, topic, &subscribers_buf);

    // 3. 各サブスクライバーに転送（ロック外）
    for (subscribers_buf[0..count]) |sub| {
        // 自分自身には送らない
        if (std.mem.eql(u8, sub.client_id, source_client_id)) continue;

        const effective_qos = @min(qos, sub.max_qos);
        sub.connection.sendPublish(
            io,
            topic,
            payload,
            effective_qos,
        ) catch |err| {
            std.log.warn("転送失敗 ({s}): {}", .{ sub.client_id, err });
        };
    }

    std.log.info(
        "ルーティング完了: topic={s}, 配信先={d}クライアント",
        .{ topic, count },
    );
}
```

---

## 複数サブスクライバーのテスト

ワイルドカードトピックの動作を確認するために、複数のサブスクライバーを起動する。

```bash
# ターミナル2: 全センサーデータを購読 (sensor/# にサブスクライブ)
./zig-out/bin/mqtt-sub

# ターミナル3: mosquitto_sub で温度データのみ購読
mosquitto_sub -h 127.0.0.1 -p 1883 -t "sensor/temp"

# ターミナル4: 湿度データを送信
mosquitto_pub -h 127.0.0.1 -p 1883 -t "sensor/humidity" -m "60%"
# -> ターミナル2 のみが受信する（sensor/# がマッチ）

# ターミナル5: 温度データを送信
mosquitto_pub -h 127.0.0.1 -p 1883 -t "sensor/temp" -m "25.3"
# -> ターミナル2 と ターミナル3 の両方が受信する
```

---

## mosquitto クライアントとの相互運用テスト

本ブローカーは MQTT v3.1.1 準拠であるため、mosquitto の公式クライアントツールでもテストできる。

### 基本テスト

```bash
# mosquitto_sub で購読
mosquitto_sub -h 127.0.0.1 -p 1883 -t "sensor/#" -v

# 別ターミナルで mosquitto_pub で発行
mosquitto_pub -h 127.0.0.1 -p 1883 -t "sensor/temp" -m "25.3"
```

### QoS 1 テスト

```bash
# QoS 1 で購読
mosquitto_sub -h 127.0.0.1 -p 1883 -t "qos/test" -q 1 -v

# QoS 1 で発行
mosquitto_pub -h 127.0.0.1 -p 1883 -t "qos/test" -m "reliable" -q 1
```

### Retained メッセージテスト

```bash
# retained メッセージを保存
mosquitto_pub -h 127.0.0.1 -p 1883 -t "status/device" -m "online" -r

# 後から購読すると、即座に retained メッセージを受信
mosquitto_sub -h 127.0.0.1 -p 1883 -t "status/device" -v -C 1
# 出力: status/device online
```

### Will メッセージテスト

```bash
# Will メッセージ付きで接続（Ctrl+C で強制切断）
mosquitto_sub -h 127.0.0.1 -p 1883 -t "test/#" \
  --will-topic "status/sub-client" \
  --will-payload "disconnected" \
  --will-qos 1

# 別ターミナルで Will メッセージを監視
mosquitto_sub -h 127.0.0.1 -p 1883 -t "status/#" -v

# 最初のターミナルで Ctrl+C -> Will メッセージが配信される
```

### 自作クライアントと mosquitto の混在テスト

```bash
# zig-out のサブスクライバーと mosquitto_pub を組み合わせる
./zig-out/bin/mqtt-sub &
mosquitto_pub -h 127.0.0.1 -p 1883 -t "sensor/temp" -m "from-mosquitto"

# mosquitto_sub と zig-out のパブリッシャーを組み合わせる
mosquitto_sub -h 127.0.0.1 -p 1883 -t "sensor/#" -v &
./zig-out/bin/mqtt-pub
```

相互運用テストは、プロトコル実装の正しさを検証する上で非常に有効である。
自作のクライアントとサードパーティのクライアントが問題なく通信できれば、MQTT 仕様に準拠していることの強い証拠となる。

---

## トラブルシューティング

### 接続できない場合

```bash
# ブローカーが起動しているか確認
lsof -i :1883

# ファイアウォールの確認（macOS）
sudo pfctl -sr | grep 1883
```

### メッセージが届かない場合

1. サブスクライバーの topic filter がパブリッシャーの topic に一致しているか確認
2. ブローカーのログで「ルーティング完了」メッセージを確認
3. QoS レベルが一致しているか確認

### mosquitto がインストールされていない場合

```bash
# macOS
brew install mosquitto

# Ubuntu/Debian
sudo apt install mosquitto-clients
```

---

## まとめ

- 全バイナリが `std.process.Init`（Juicy Main）で `gpa` と `io` を受け取る
- `std.Io.net.IpAddress.parse` でアドレスを解析し、`connect(io, .{})` で接続する
- reader/writer は `stream.reader(io, &buf)` / `stream.writer(io, &buf)` で生成する
- mosquitto クライアントとの混在テストでプロトコル準拠を検証できる
- ルーティング処理では RwLock と Mutex を適切に使い分けてロック競合を最小化する

次章では、統合テストの手法を学ぶ。
