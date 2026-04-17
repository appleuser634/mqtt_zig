# 第14章: 統合テスト

## 学習目標

- MQTT ブローカーの統合テスト手法を理解する
- Zig 0.16 の `std.Io.Threaded` をテスト内で活用できる
- `std.testing.allocator` によるメモリリーク検出を理解する
- ブローカーの起動、接続、パブリッシュ、検証の一連のフローをテストで自動化できる
- エッジケース（不正パケット、高速接続/切断）のテスト設計ができる

---

## テスト戦略

MQTT ブローカーのテストは3層で構成する。

| レベル | 対象 | 手法 |
|--------|------|------|
| ユニットテスト | 個別モジュール（パケットエンコード、トピックマッチング） | `test` ブロック |
| 統合テスト | ブローカー + クライアント間の通信 | テスト内でブローカーを起動 |
| 相互運用テスト | 外部ツール（mosquitto）との互換性 | シェルスクリプト |

---

## Zig 0.16 の std.testing

### 基本的なアサーション

```zig
const std = @import("std");
const testing = std.testing;

test "パケットID生成" {
    var gen = PacketIdGenerator.init();

    try testing.expectEqual(@as(u16, 1), gen.next());
    try testing.expectEqual(@as(u16, 2), gen.next());
    try testing.expectEqual(@as(u16, 3), gen.next());
}

test "トピックマッチング" {
    try testing.expect(topicMatches("sensor/temp", "sensor/temp"));
    try testing.expect(topicMatches("sensor/temp", "sensor/#"));
    try testing.expect(topicMatches("sensor/temp", "+/temp"));
    try testing.expect(!topicMatches("sensor/temp", "sensor/humidity"));
}
```

### std.testing.allocator: メモリリーク検出

`std.testing.allocator` はテスト終了時に全ての割り当てが解放されているかを検証する。リークがあればテストが失敗する。

```zig
test "セッション作成と破棄" {
    const allocator = std.testing.allocator;

    var sm = SessionManager.init(allocator);
    defer sm.deinit();

    const result = try sm.getOrCreate("client-01", true);
    try testing.expect(!result.session_existed);

    try sm.addSubscription("client-01", "sensor/#", 1);

    // 切断してクリーンアップ
    sm.disconnectClient("client-01", true);

    // test allocator がリークを自動検出
    // deinit で全メモリが解放されなければテスト失敗
}
```

---

## std.Io.Threaded: テスト内での Io ランタイム

テスト内でブローカーを起動するには、Io ランタイムが必要である。
`std.process.Init` はテストでは使えないため、`std.Io.Threaded` を直接構築する。

```zig
test "Io ランタイムの構築" {
    const allocator = std.testing.allocator;

    // テスト用の Io ランタイムを初期化
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    // io を使ってネットワーク操作やロック操作が可能
    _ = io;
}
```

`std.Io.Threaded` は、通常の `main` 関数で `init.io` が提供するものと同等の Io ランタイムを生成する。テスト環境ではこれが唯一の Io ランタイム取得方法である。

---

## 統合テストの実装

### テスト用ブローカーの起動

テスト内でブローカーをバックグラウンドスレッドとして起動する。

```zig
const TestBroker = struct {
    broker: *MqttBroker,
    thread: std.Thread,
    port: u16,
    allocator: std.mem.Allocator,
    io: *std.Io,

    fn start(allocator: std.mem.Allocator, io: *std.Io) !TestBroker {
        const broker = try allocator.create(MqttBroker);
        broker.* = MqttBroker.init(allocator);

        // ポート 0 を指定すると OS が空きポートを割り当てる
        const port: u16 = 0;

        const thread = try std.Thread.spawn(.{}, runBroker, .{
            broker, io, port,
        });

        // ブローカーの起動を待つ
        std.Io.Clock.Duration.sleep(.{
            .clock = .awake,
            .raw = .fromMilliseconds(100),
        }, io);

        return .{
            .broker = broker,
            .thread = thread,
            .port = broker.actual_port,
            .allocator = allocator,
            .io = io,
        };
    }

    fn stop(self: *TestBroker) void {
        self.broker.shutdown(self.io);
        self.thread.join();
        self.broker.deinit(self.io);
        self.allocator.destroy(self.broker);
    }

    fn runBroker(broker: *MqttBroker, io: *std.Io, port: u16) void {
        broker.run(io, port) catch |err| {
            std.log.err("テストブローカーエラー: {}", .{err});
        };
    }
};
```

### graceful shutdown の活用

テスト後に確実にブローカーを停止するために、graceful shutdown パターンを使う。

```zig
fn stop(self: *TestBroker) void {
    // atomic フラグで停止を通知
    self.broker.should_stop.store(true, .release);
    // Event でブロック中のスレッドを起こす
    self.broker.shutdown_event.set(self.io);
    // スレッドの完了を待つ
    self.thread.join();
    // リソースの解放
    self.broker.deinit(self.io);
    self.allocator.destroy(self.broker);
}
```

---

## 接続・パブリッシュ・受信の統合テスト

```zig
test "パブリッシュしたメッセージがサブスクライバーに届く" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    // ブローカー起動
    var broker = try TestBroker.start(allocator, io);
    defer broker.stop();

    // サブスクライバー接続
    const sub_address = std.Io.net.IpAddress.parse("127.0.0.1", broker.port);
    var sub_stream = try sub_address.connect(io, .{});
    defer sub_stream.close(io);

    var sub_read_buf: [4096]u8 = undefined;
    var sub_write_buf: [4096]u8 = undefined;
    var sub_reader = sub_stream.reader(io, &sub_read_buf);
    var sub_writer = sub_stream.writer(io, &sub_write_buf);

    try sendConnect(&sub_writer, "sub-client", .{ .clean_session = true });
    try sub_writer.interface.flush();
    const sub_connack = try receiveConnack(&sub_reader);
    try testing.expectEqual(ConnackCode.accepted, sub_connack.return_code);

    try sendSubscribe(&sub_writer, "test/topic", 0);
    try sub_writer.interface.flush();
    _ = try receiveSuback(&sub_reader);

    // パブリッシャー接続
    const pub_address = std.Io.net.IpAddress.parse("127.0.0.1", broker.port);
    var pub_stream = try pub_address.connect(io, .{});
    defer pub_stream.close(io);

    var pub_read_buf: [4096]u8 = undefined;
    var pub_write_buf: [4096]u8 = undefined;
    var pub_reader = pub_stream.reader(io, &pub_read_buf);
    var pub_writer = pub_stream.writer(io, &pub_write_buf);

    try sendConnect(&pub_writer, "pub-client", .{ .clean_session = true });
    try pub_writer.interface.flush();
    _ = try receiveConnack(&pub_reader);

    // メッセージ送信
    try sendPublish(&pub_writer, "test/topic", "hello mqtt", .{ .qos = 0 });
    try pub_writer.interface.flush();

    // サブスクライバー側で受信確認
    const received = try receivePublish(&sub_reader);
    try testing.expectEqualStrings("test/topic", received.topic);
    try testing.expectEqualStrings("hello mqtt", received.payload);
}
```

### Retained メッセージのテスト

```zig
test "Retained メッセージが新規サブスクライバーに届く" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var broker = try TestBroker.start(allocator, io);
    defer broker.stop();

    // パブリッシャーが retained メッセージを送信
    var pub_stream = try connectToBroker(io, broker.port, "pub-client");
    defer pub_stream.close(io);

    var pub_write_buf: [4096]u8 = undefined;
    var pub_writer = pub_stream.writer(io, &pub_write_buf);
    try sendPublish(&pub_writer, "status/device", "online", .{
        .qos = 0,
        .retain = true,
    });
    try pub_writer.interface.flush();

    // 少し待ってからサブスクライバーが接続
    std.Io.Clock.Duration.sleep(.{
        .clock = .awake,
        .raw = .fromMilliseconds(50),
    }, io);

    var sub_stream = try connectToBroker(io, broker.port, "sub-client");
    defer sub_stream.close(io);

    var sub_read_buf: [4096]u8 = undefined;
    var sub_write_buf: [4096]u8 = undefined;
    var sub_reader = sub_stream.reader(io, &sub_read_buf);
    var sub_writer = sub_stream.writer(io, &sub_write_buf);

    try sendSubscribe(&sub_writer, "status/device", 0);
    try sub_writer.interface.flush();
    _ = try receiveSuback(&sub_reader);

    // サブスクライブ直後に retained メッセージを受信するはず
    const received = try receivePublish(&sub_reader);
    try testing.expectEqualStrings("status/device", received.topic);
    try testing.expectEqualStrings("online", received.payload);
    try testing.expect(received.retain);
}
```

---

## エッジケースのテスト

### 不正パケットの処理

ブローカーは不正なパケットを受け取ってもクラッシュしてはならない。

```zig
test "不正なパケットで接続が切断される" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var broker = try TestBroker.start(allocator, io);
    defer broker.stop();

    const address = std.Io.net.IpAddress.parse("127.0.0.1", broker.port);
    var stream = try address.connect(io, .{});
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    // 不正なデータを送信（CONNECT なしで PUBLISH を送る）
    const garbage = [_]u8{ 0x30, 0x05, 0x00, 0x01, 'x', 'A', 'B' };
    try writer.interface.writeAll(&garbage);
    try writer.interface.flush();

    // ブローカーは接続を切断するはず
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var result_buf: [64]u8 = undefined;
    const n = reader.interface.readSliceAll(&result_buf) catch 0;
    try testing.expectEqual(@as(usize, 0), n);
}

test "CONNECT なしで SUBSCRIBE を送ると切断される" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var broker = try TestBroker.start(allocator, io);
    defer broker.stop();

    const address = std.Io.net.IpAddress.parse("127.0.0.1", broker.port);
    var stream = try address.connect(io, .{});
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    // CONNECT を送らずに SUBSCRIBE を送信
    try sendSubscribe(&writer, "test/topic", 0);
    try writer.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var result_buf: [64]u8 = undefined;
    const n = reader.interface.readSliceAll(&result_buf) catch 0;
    try testing.expectEqual(@as(usize, 0), n);
}
```

### 高速接続・切断

```zig
test "高速な接続と切断を繰り返してもブローカーは安定動作する" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var broker = try TestBroker.start(allocator, io);
    defer broker.stop();

    // 100回の高速接続・切断
    for (0..100) |i| {
        var id_buf: [32]u8 = undefined;
        const client_id = std.fmt.bufPrint(&id_buf, "rapid-{d}", .{i}) catch unreachable;

        const address = std.Io.net.IpAddress.parse("127.0.0.1", broker.port);
        var stream = address.connect(io, .{}) catch continue;

        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        sendConnect(&writer, client_id, .{ .clean_session = true }) catch {
            stream.close(io);
            continue;
        };
        writer.interface.flush() catch {};

        // CONNACK を待たずに即切断
        stream.close(io);
    }

    // ブローカーがまだ動作していることを確認
    const verify_address = std.Io.net.IpAddress.parse("127.0.0.1", broker.port);
    var verify_stream = try verify_address.connect(io, .{});
    defer verify_stream.close(io);

    var vr_buf: [4096]u8 = undefined;
    var vw_buf: [4096]u8 = undefined;
    var verify_reader = verify_stream.reader(io, &vr_buf);
    var verify_writer = verify_stream.writer(io, &vw_buf);

    try sendConnect(&verify_writer, "verify-client", .{ .clean_session = true });
    try verify_writer.interface.flush();
    const connack = try receiveConnack(&verify_reader);
    try testing.expectEqual(ConnackCode.accepted, connack.return_code);
}
```

### クライアントテイクオーバーのテスト

```zig
test "同一 client_id の再接続で旧接続が切断される" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var broker = try TestBroker.start(allocator, io);
    defer broker.stop();

    // 最初の接続
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", broker.port);
    var stream1 = try addr.connect(io, .{});
    defer stream1.close(io);

    var w1_buf: [4096]u8 = undefined;
    var r1_buf: [4096]u8 = undefined;
    var writer1 = stream1.writer(io, &w1_buf);
    var reader1 = stream1.reader(io, &r1_buf);
    try sendConnect(&writer1, "takeover-client", .{ .clean_session = true });
    try writer1.interface.flush();
    _ = try receiveConnack(&reader1);

    // 同じ client_id で2つ目の接続
    var stream2 = try addr.connect(io, .{});
    defer stream2.close(io);

    var w2_buf: [4096]u8 = undefined;
    var r2_buf: [4096]u8 = undefined;
    var writer2 = stream2.writer(io, &w2_buf);
    var reader2 = stream2.reader(io, &r2_buf);
    try sendConnect(&writer2, "takeover-client", .{ .clean_session = true });
    try writer2.interface.flush();
    _ = try receiveConnack(&reader2);

    // stream1 は切断されているはず
    std.Io.Clock.Duration.sleep(.{
        .clock = .awake,
        .raw = .fromMilliseconds(100),
    }, io);
    var result_buf: [64]u8 = undefined;
    const n = reader1.interface.readSliceAll(&result_buf) catch 0;
    try testing.expectEqual(@as(usize, 0), n);
}
```

---

## mosquitto を使った相互運用テスト

外部の MQTT クライアントツールを使うことで、プロトコル実装の正しさを独立して検証できる。

### テストスクリプト

```bash
#!/bin/bash
# interop_test.sh

# ブローカーを起動
./zig-out/bin/mqtt-broker &
BROKER_PID=$!
sleep 1

# テスト1: 基本的な pub/sub
echo "=== テスト1: 基本 pub/sub ==="
mosquitto_sub -h 127.0.0.1 -t "test/topic" -C 1 &
SUB_PID=$!
sleep 0.5

mosquitto_pub -h 127.0.0.1 -t "test/topic" -m "hello"
wait $SUB_PID
echo "テスト1: OK"

# テスト2: ワイルドカード
echo "=== テスト2: ワイルドカード ==="
mosquitto_sub -h 127.0.0.1 -t "sensor/#" -C 1 &
SUB_PID=$!
sleep 0.5

mosquitto_pub -h 127.0.0.1 -t "sensor/temp" -m "25.3"
wait $SUB_PID
echo "テスト2: OK"

# テスト3: Retained メッセージ
echo "=== テスト3: Retained ==="
mosquitto_pub -h 127.0.0.1 -t "retained/test" -m "stored" -r
sleep 0.5
RESULT=$(mosquitto_sub -h 127.0.0.1 -t "retained/test" -C 1 -W 2)
if [ "$RESULT" = "stored" ]; then
    echo "テスト3: OK"
else
    echo "テスト3: FAIL (期待: stored, 実際: $RESULT)"
fi

# クリーンアップ
kill $BROKER_PID
echo "=== 全テスト完了 ==="
```

---

## テストの実行

```bash
# ユニットテスト + 統合テストを全て実行
zig build test

# 特定のテストファイルのみ実行
zig build test --filter "パブリッシュしたメッセージ"

# テスト中のログ出力を表示
zig build test 2>&1 | head -50
```

### テスト用の build.zig 設定

```zig
// build.zig に追加
const tests = b.addTest(.{
    .root_source_file = b.path("src/tests/integration_test.zig"),
    .target = target,
    .optimize = optimize,
});

const test_step = b.step("test", "統合テストを実行");
test_step.dependOn(&b.addRunArtifact(tests).step);
```

---

## テスト設計のガイドライン

### 良いテストの特徴

1. **独立性**: 各テストは他のテストの結果に依存しない
2. **再現性**: 何度実行しても同じ結果になる
3. **速度**: 統合テストでもタイムアウトは最小限にする
4. **明確さ**: テスト名から何をテストしているか分かる

### テスト内の Io ランタイム初期化パターン

全ての統合テストで共通のパターン:

```zig
test "テスト名" {
    // 1. アロケータの取得
    const allocator = std.testing.allocator;

    // 2. Io ランタイムの構築
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    // 3. テスト用ブローカーの起動
    var broker = try TestBroker.start(allocator, io);
    defer broker.stop();

    // 4. テストクライアントの接続
    const address = std.Io.net.IpAddress.parse("127.0.0.1", broker.port);
    var stream = try address.connect(io, .{});
    defer stream.close(io);

    // 5. reader/writer の生成
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    // 6. テスト本体
    // ...
}
```

### テストで検証すべき項目

```
接続:
  [ ] 正常な CONNECT / CONNACK
  [ ] 不正なプロトコルバージョンの拒否
  [ ] 空の client_id の処理
  [ ] クライアントテイクオーバー

パブリッシュ:
  [ ] QoS 0 の配信
  [ ] QoS 1 の配信と PUBACK
  [ ] Retained メッセージの保存と配信
  [ ] 空ペイロードによる Retained 削除

サブスクリプション:
  [ ] 完全一致トピック
  [ ] + ワイルドカード
  [ ] # ワイルドカード
  [ ] UNSUBSCRIBE 後のメッセージ非配信

セッション:
  [ ] Clean Session = true
  [ ] Clean Session = false（永続セッション）
  [ ] Will メッセージの発行

エッジケース:
  [ ] 不正なパケットフォーマット
  [ ] 高速接続・切断
  [ ] 大量の同時接続
  [ ] 極端に長いトピック名
  [ ] バイナリペイロード
```

---

## まとめ

- テスト内で `std.Io.Threaded.init(allocator, .{})` を使って Io ランタイムを構築する
- `std.testing.allocator` でメモリリークを自動検出できる
- ネットワーク接続は `std.Io.net.IpAddress.parse` + `connect(io, .{})` で行う
- reader/writer は `stream.reader(io, &buf)` / `stream.writer(io, &buf)` で生成する
- `std.atomic.Value(bool)` + `std.Io.Event` でテスト後の確実なブローカー停止を実現する
- エッジケーステストでブローカーの堅牢性を確認する
- mosquitto クライアントとの相互運用テストでプロトコル準拠を検証する

以上で本チュートリアルの全章が完了した。ここまで学んだ知識を活かして、MQTT ブローカーの実装を完成させてほしい。
