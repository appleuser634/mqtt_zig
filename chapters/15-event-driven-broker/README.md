# 第15章: イベント駆動ブローカー

## 学習目標

- Thread-per-connection モデルとイベント駆動モデルの違いを理解する
- `io.async()` を使った非ブロッキング接続受け入れを実装できる
- `std.Io.Group` を使ったファンアウト配信を実装できる
- Io バックエンド（Threaded / Evented）の切り替え方法を理解する
- `io.async` と `io.concurrent` の使い分けを判断できる

---

## Thread-per-connection の限界

第10章で実装した Thread-per-connection モデルは教育目的には優れているが、
本番運用では深刻なスケーラビリティ問題がある。

```
Thread-per-connection:
  クライアント 100 台  → OS スレッド 100 本（スタック 8MB × 100 = 800MB）
  クライアント 1,000 台 → OS スレッド 1,000 本（スタック 8GB、コンテキストスイッチ多発）
  クライアント 10,000 台 → OS の限界を超える

イベント駆動:
  クライアント 100 台   → 1 イベントループ + ワーカースレッド数本
  クライアント 1,000 台  → 同上（カーネルが接続を多重化）
  クライアント 10,000 台 → 同上（io_uring / kqueue が効率的に処理）
```

| 指標 | Thread-per-connection | イベント駆動 |
|------|----------------------|-------------|
| メモリ使用量 | O(N) スレッドスタック | O(N) 接続状態のみ |
| コンテキストスイッチ | O(N) | O(1) イベントループ |
| 最大接続数 | ~数千 | ~数万〜数十万 |
| 実装の複雑さ | 低い | 中程度 |
| デバッグ | 容易 | やや困難 |

---

## Zig 0.16 の Io モデル

Zig 0.16 では `std.Io` がランタイムの非同期基盤を提供する。
これにより、同じコードがスレッドプールベース（Threaded）でも
カーネルイベント駆動（Evented）でも動作する。

### バックエンドの種類

| バックエンド | 内部実装 | 対応 OS |
|------------|---------|---------|
| `std.Io.Threaded` | スレッドプール | 全 OS（クロスプラットフォーム） |
| `std.Io.Evented` | io_uring / kqueue | Linux / macOS / BSD |

### バックエンドの選択

バックエンドの切り替えは初期化コードの1行を変えるだけで済む。
ビジネスロジックは一切変更不要である。

```zig
const std = @import("std");

// スレッドプールバックエンド（クロスプラットフォーム）
pub fn mainThreaded(init: std.process.Init) !void {
    var io = init.io; // init.io は Threaded バックエンド
    try runBroker(io, init.gpa);
}

// io_uring / kqueue バックエンド（高性能）
pub fn mainEvented(init: std.process.Init) !void {
    // Evented バックエンドを明示的に初期化
    var evented: std.Io.Evented = .init;
    defer evented.deinit();
    try runBroker(&evented, init.gpa);
}

// ビジネスロジックはバックエンドに依存しない
fn runBroker(io: anytype, gpa: std.mem.Allocator) !void {
    // 同じコードが Threaded でも Evented でも動く
    _ = io;
    _ = gpa;
}
```

---

## io.async によるノンブロッキング accept

従来の accept ループはブロッキングであった。
`io.async()` を使うと、accept を非同期に発行し、
新しい接続が来るまで他のタスクを実行できる。

### 従来のブロッキング accept

```zig
// 第10章のコード: ブロッキング
while (true) {
    const conn = try server.accept(io);            // ← ブロック
    const thread = try std.Thread.spawn(.{}, handleConnection, .{self, conn});
    thread.detach();
}
```

### io.async を使った非同期 accept

```zig
const net = std.Io.net;

fn runAcceptLoop(self: *MqttBroker, io: anytype) !void {
    const address = net.IpAddress.parse("0.0.0.0", 1883) catch return error.AddressParseFailed;
    var server = try net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("イベント駆動ブローカー起動: ポート 1883", .{});

    while (!self.stop_requested.load(.acquire)) {
        // accept を非同期に発行
        const conn = try server.accept(io);

        // 接続ハンドラを非同期タスクとして起動
        // io.async はタスクをイベントループに登録し、即座に返る
        const future = io.async(handleClient, .{ self, conn, io });
        _ = future; // fire-and-forget: 個別の await は不要
    }
}
```

`io.async()` の戻り値は future である。`future.await(io)` を呼ぶと
タスクの完了を待てるが、fire-and-forget パターンでは await しなくてもよい。

---

## io.async vs io.concurrent

Zig 0.16 では2種類の非同期プリミティブが提供される。
用途に応じて使い分ける必要がある。

| API | 用途 | スケジューリング |
|-----|------|----------------|
| `io.async(fn, args)` | I/O バウンド処理 | イベントループ内で協調スケジュール |
| `io.concurrent(fn, args)` | CPU バウンド処理 | 別スレッドで並列実行 |

### 使い分けの指針

```zig
// I/O バウンド: ネットワーク読み書き、ファイル操作
// → io.async を使う
const read_future = io.async(readPacket, .{ stream, buffer });

// CPU バウンド: 暗号化、圧縮、大量データの変換
// → io.concurrent を使う（別スレッドで実行される）
const hash_future = io.concurrent(computeHash, .{payload}) catch |err| {
    std.log.err("concurrent タスク生成失敗: {}", .{err});
    return err;
};

// 両方とも .await(io) で結果を取得
const packet = read_future.await(io);
const hash = hash_future.await(io);
```

MQTT ブローカーでは、ほとんどの処理が I/O バウンド（TCP 読み書き）であるため、
`io.async` を主に使用する。パスワードのハッシュ計算のような CPU 集約処理にのみ
`io.concurrent` を使う。

---

## std.Io.Group によるファンアウト配信

PUBLISH メッセージを複数のサブスクライバーに同時配信する場合、
`std.Io.Group` を使うと全配信を並行して発行し、全完了を待機できる。

### Group の基本パターン

```zig
fn fanOutPublish(
    io: anytype,
    subscribers: []const SubscriberInfo,
    topic: []const u8,
    payload: []const u8,
) !void {
    var group: std.Io.Group = .init;

    // 各サブスクライバーへの配信を並行タスクとして登録
    for (subscribers) |sub| {
        group.async(io, sendToSubscriber, .{ sub, topic, payload, io });
    }

    // 全タスクの完了を待機
    // いずれかがエラーを返した場合、group.await もエラーを返す
    try group.await(io);
}

fn sendToSubscriber(
    sub: SubscriberInfo,
    topic: []const u8,
    payload: []const u8,
    io: anytype,
) !void {
    const effective_qos = @min(sub.max_qos, sub.publish_qos);
    const packet = encodePublish(topic, payload, effective_qos);
    var write_buf: [4096]u8 = undefined;
    var writer = sub.stream.writer(io, &write_buf);
    try writer.interface.writeAll(packet);
    try writer.interface.flush();
}
```

### 従来のコードとの比較

```zig
// 従来: 逐次配信（第10章）
// サブスクライバー N 人 → 合計 N 回の write を直列実行
for (subscribers) |sub| {
    sub.connection.sendPublish(topic, payload, qos) catch |err| {
        std.log.warn("転送エラー: {}", .{err});
    };
}

// イベント駆動: 並行配信（本章）
// サブスクライバー N 人 → N 回の write を並行発行
// Evented バックエンドなら io_uring に一括サブミットされる
var group: std.Io.Group = .init;
for (subscribers) |sub| {
    group.async(io, sendToSubscriber, .{ sub, topic, payload, io });
}
try group.await(io);
```

ファンアウト配信は MQTT ブローカーのホットパスであり、
Group による並行化の効果が最も大きい箇所である。

---

## イベント駆動ブローカーの骨格

```zig
const std = @import("std");
const net = std.Io.net;

const EventDrivenBroker = struct {
    gpa: std.mem.Allocator,
    session_manager: *SessionManager,
    retain_store: *RetainStore,
    stop_requested: std.atomic.Value(bool),

    pub fn run(self: *EventDrivenBroker, io: anytype) !void {
        const address = net.IpAddress.parse("0.0.0.0", 1883) catch return error.AddressParseFailed;
        var server = try net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        defer server.deinit(io);

        while (!self.stop_requested.load(.acquire)) {
            const conn = try server.accept(io);
            // 接続ハンドラを非同期タスクとして起動（fire-and-forget）
            _ = io.async(handleClient, .{ self, conn.stream, io });
        }
    }

    fn handleClient(self: *EventDrivenBroker, stream: net.Stream, io: anytype) void {
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);

        while (!self.stop_requested.load(.acquire)) {
            var byte_buf: [1]u8 = undefined;
            reader.interface.readSliceAll(&byte_buf) catch break;
            const first_byte = byte_buf[0];
            const packet_type: u4 = @intCast(first_byte >> 4);

            switch (packet_type) {
                3 => self.handlePublish(stream, first_byte, io) catch break,
                12 => {
                    var write_buf: [4096]u8 = undefined;
                    var writer = stream.writer(io, &write_buf);
                    writer.interface.writeAll(&.{ 0xD0, 0x00 }) catch break;
                    writer.interface.flush() catch break;
                },
                14 => break, // DISCONNECT
                else => break,
            }
        }
    }

    fn handlePublish(self: *EventDrivenBroker, _: net.Stream, _: u8, io: anytype) !void {
        // サブスクライバー検索 → Group でファンアウト配信
        var buf: [128]SubscriberInfo = undefined;
        const count = self.session_manager.getSubscribers("topic", &buf);

        var group: std.Io.Group = .init;
        for (buf[0..count]) |sub| {
            group.async(io, sendToSubscriber, .{ sub, "topic", "payload" });
        }
        try group.await(io);
    }

    fn sendToSubscriber(_: SubscriberInfo, _: []const u8, _: []const u8) void {}
};

const SubscriberInfo = struct { stream: net.Stream, max_qos: u2, publish_qos: u2 };
const SessionManager = struct {
    pub fn getSubscribers(_: *SessionManager, _: []const u8, _: []SubscriberInfo) usize { return 0; }
};
const RetainStore = struct {};
```

---

## パフォーマンス特性の比較

### メモリ使用量

```
Thread-per-connection (1,000 接続):
  スレッドスタック:   8 MB × 1,000 = 8,000 MB
  接続状態:          ~1 KB × 1,000 =     1 MB
  合計:                              ~8,001 MB

イベント駆動 (1,000 接続):
  ワーカースレッド:   8 MB × 4     =    32 MB
  接続状態:          ~1 KB × 1,000 =     1 MB
  イベント管理:      ~64 B × 1,000 =   0.06 MB
  合計:                              ~   33 MB
```

### システムコール削減（Evented バックエンド）

io_uring を使用する Evented バックエンドでは、複数の I/O 操作を
1回の `io_uring_enter` システムコールにバッチ送信できる。

```
Thread-per-connection (10 サブスクライバーにファンアウト):
  write() × 10 = システムコール 10 回

Evented + Io.Group (10 サブスクライバーにファンアウト):
  io_uring_enter() × 1 = システムコール 1 回（10 件の SQE を一括送信）
```

---

## まとめ

- Thread-per-connection は実装が容易だが、数千接続でスケーラビリティの壁がある
- Zig 0.16 の `std.Io` は Threaded と Evented の2つのバックエンドを透過的に切り替えられる
- `io.async()` は I/O バウンド処理に、`io.concurrent()` は CPU バウンド処理に使う
- `std.Io.Group` を使えば、ファンアウト配信を並行発行して全完了を一括待機できる
- バックエンドの変更はエントリポイントの初期化のみで、ビジネスロジックは不変

次章では、`std.Io.Queue(T)` を使ったメッセージキューイングによるバックプレッシャー制御を学ぶ。
