# 第17章: Graceful Shutdown

## 学習目標

- 突然の終了がもたらす問題（メッセージ消失、Will 未送信）を理解する
- `std.atomic.Value(bool)` による停止フラグの安全な共有を実装できる
- `std.Io.Event` によるスレッド間通知を実装できる
- 段階的なシャットダウンシーケンスを設計・実装できる
- `Event.waitTimeout` による有限時間シャットダウンを実装できる

---

## 問題: 突然の終了

Ctrl+C や `kill` で MQTT ブローカーを停止すると、以下の問題が発生する。

| 問題 | 影響 |
|------|------|
| インフライトメッセージの消失 | QoS 1/2 のメッセージが配信途中で失われる |
| Will メッセージ未送信 | 異常切断したクライアントの Last Will が他のサブスクライバーに届かない |
| TCP 接続の未クリーンクローズ | クライアント側で TIME_WAIT が大量発生する |
| セッション状態の不整合 | persistent session のデータが中途半端な状態で残る |
| メッセージキューの未ドレイン | Io.Queue に残ったメッセージが配信されない |

---

## 解決策の全体設計

グレースフルシャットダウンは以下の3つのプリミティブで構成する。

### 1. std.atomic.Value(bool) - 停止フラグ

全タスクが参照する停止フラグ。アトミック操作により、
ロックなしで安全に読み書きできる。

```zig
const StopFlag = std.atomic.Value(bool);

// 初期化
var stop_requested = StopFlag.init(false);

// 書き込み（シャットダウン開始側）
stop_requested.store(true, .release);

// 読み取り（各タスクのループ内）
if (stop_requested.load(.acquire)) {
    // シャットダウン処理を開始
    break;
}
```

### メモリオーダリングの解説

| オーダリング | 用途 | 説明 |
|------------|------|------|
| `.release` | `store` 時 | このストアより前の書き込みが、他スレッドから見える |
| `.acquire` | `load` 時 | このロードより後の読み取りが、最新の値を見る |

`.release` と `.acquire` のペアにより、停止フラグが `true` になった時点で
シャットダウンに必要な全ての前処理（キューのクローズなど）が
他スレッドから確実に見えることが保証される。

### 2. std.Io.Event - ブロック中タスクの起動

`accept()` や `getOne()` でブロックしているタスクは、
停止フラグのポーリングだけでは即座に反応できない。
`Io.Event` を使うと、ブロック中のタスクを明示的に起動できる。

```zig
var stop_event: std.Io.Event = .unset;

stop_event.waitUncancelable(io);  // set() が呼ばれるまでブロック
stop_event.set(io);               // waitUncancelable 中の全タスクが起動
```

### 3. Event.waitTimeout - 有限時間待機

```zig
const result = stop_event.waitTimeout(io, .{ .duration = .fromMilliseconds(5000) });
if (result == null) {
    std.log.warn("タイムアウト。強制終了します", .{});
}
```

---

## シャットダウンシーケンス

以下の8ステップを順番に実行する。

```
Step 1: stop_requested = true（停止フラグセット）
    ↓
Step 2: stop_event.set()（ブロック中タスクを起動）
    ↓
Step 3: accept ループ停止（新規接続の拒否）
    ↓
Step 4: 全クライアントに DISCONNECT 送信
    ↓
Step 5: 未クリーン切断の Will メッセージ配信
    ↓
Step 6: Io.Queue のドレイン（残メッセージの配信）
    ↓
Step 7: 全 TCP ストリームのクローズ
    ↓
Step 8: セッション/リテインストアの deinit
```

---

## ShutdownManager の実装

```zig
const std = @import("std");

const ShutdownManager = struct {
    stop_requested: std.atomic.Value(bool),
    stop_event: std.Io.Event,
    shutdown_complete: std.Io.Event,

    pub fn init() ShutdownManager {
        return .{
            .stop_requested = std.atomic.Value(bool).init(false),
            .stop_event = .unset,
            .shutdown_complete = .unset,
        };
    }

    /// シャットダウンが要求されているかチェック
    pub fn isStopRequested(self: *const ShutdownManager) bool {
        return self.stop_requested.load(.acquire);
    }

    /// シャットダウンを要求する（シグナルハンドラ等から呼ばれる）
    pub fn requestShutdown(self: *ShutdownManager, io: anytype) void {
        // Step 1: 停止フラグをセット
        self.stop_requested.store(true, .release);

        // Step 2: ブロック中のタスクを起動
        self.stop_event.set(io);

        std.log.info("シャットダウンが要求されました", .{});
    }

    /// シャットダウン完了を待機（タイムアウト付き）
    pub fn waitForCompletion(self: *ShutdownManager, io: anytype) bool {
        const result = self.shutdown_complete.waitTimeout(io, .{
            .duration = .fromMilliseconds(10000),
        });

        return result != null;
    }

    /// シャットダウン完了を通知
    pub fn notifyComplete(self: *ShutdownManager, io: anytype) void {
        self.shutdown_complete.set(io);
    }
};
```

---

## Server への統合

```zig
const net = std.Io.net;

const Server = struct {
    gpa: std.mem.Allocator,
    shutdown: ShutdownManager,
    connections: ConnectionList,
    session_manager: *SessionManager,
    retain_store: *RetainStore,

    pub fn run(self: *Server, io: anytype) !void {
        const address = net.IpAddress.parse("0.0.0.0", 1883) catch return error.AddressParseFailed;
        var listener = try net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        defer listener.deinit(io);

        std.log.info("ブローカー起動: ポート 1883", .{});

        // accept ループ
        while (!self.shutdown.isStopRequested()) {
            const conn = listener.accept(io) catch |err| {
                if (self.shutdown.isStopRequested()) break;
                std.log.err("accept エラー: {}", .{err});
                continue;
            };

            _ = io.async(handleClient, .{ self, conn.stream, io });
        }

        // accept ループ終了後、シャットダウンシーケンスを実行
        try self.executeShutdownSequence(io);
    }

    fn executeShutdownSequence(self: *Server, io: anytype) !void {
        std.log.info("シャットダウンシーケンス開始", .{});

        // Step 3: 新規接続の受け入れ停止（accept ループ終了済み）
        std.log.info("[Step 3] 新規接続の受け入れを停止しました", .{});

        // Step 4: 全クライアントに DISCONNECT 通知
        std.log.info("[Step 4] クライアントへ DISCONNECT 送信中...", .{});
        self.sendDisconnectToAll(io);

        // Step 5: Will メッセージの配信
        std.log.info("[Step 5] Will メッセージ配信中...", .{});
        self.deliverWillMessages(io);

        // Step 6: メッセージキューのドレイン
        std.log.info("[Step 6] メッセージキューをドレイン中...", .{});
        self.drainAllQueues(io);

        // Step 7: TCP ストリームのクローズ
        std.log.info("[Step 7] TCP 接続をクローズ中...", .{});
        self.closeAllStreams(io);

        // Step 8: ストアの解放
        std.log.info("[Step 8] セッション/リテインストアを解放中...", .{});
        self.session_manager.deinit();
        self.retain_store.deinit();

        // 完了通知
        self.shutdown.notifyComplete(io);
        std.log.info("シャットダウン完了", .{});
    }

    // 以下、各ステップのヘルパー関数（抜粋）

    fn sendDisconnectToAll(self: *Server, io: anytype) void {
        var iter = self.connections.iterator();
        while (iter.next()) |conn| {
            var write_buf: [4096]u8 = undefined;
            var writer = conn.stream.writer(io, &write_buf);
            writer.interface.writeAll(&.{ 0xE0, 0x00 }) catch {};
            writer.interface.flush() catch {};
        }
    }

    fn deliverWillMessages(self: *Server, io: anytype) void {
        _ = io;
        var iter = self.connections.iterator();
        while (iter.next()) |conn| {
            if (conn.will_message) |will| {
                if (!conn.clean_disconnect) {
                    _ = will; // routeMessage で配信
                }
            }
        }
    }

    fn drainAllQueues(self: *Server, io: anytype) void {
        var iter = self.connections.iterator();
        while (iter.next()) |conn| {
            while (conn.message_queue.drainRemaining(io)) |msg| {
                _ = msg; // TCP stream に送信
            }
        }
    }

    fn closeAllStreams(self: *Server, io: anytype) void {
        var iter = self.connections.iterator();
        while (iter.next()) |conn| conn.stream.close(io);
        self.connections.clear();
    }

    fn handleClient(_: *Server, _: net.Stream, _: anytype) void {}
};
```

---

## 接続ハンドラでの停止チェック

各クライアントのリーダータスクは、パケット読み取りループ内で
停止フラグを確認する。

```zig
fn clientReaderLoop(self: *ClientConnection, shutdown: *const ShutdownManager, io: anytype) void {
    var read_buf: [4096]u8 = undefined;
    var reader = self.stream.reader(io, &read_buf);

    while (!shutdown.isStopRequested()) {
        var byte_buf: [1]u8 = undefined;
        reader.interface.readSliceAll(&byte_buf) catch |err| {
            if (err == error.EndOfStream) break;
            if (shutdown.isStopRequested()) break; // ソケットクローズによるエラー
            std.log.err("読み取りエラー: {}", .{err});
            break;
        };

        const first_byte = byte_buf[0];
        const packet_type: u4 = @intCast(first_byte >> 4);
        switch (packet_type) {
            14 => { self.clean_disconnect = true; break; }, // DISCONNECT
            else => {}, // 各パケット処理
        }
    }
}
```

---

## エントリポイント

```zig
pub fn main(init: std.process.Init) !void {
    var io = init.io;
    var server = Server{ .gpa = init.gpa, .shutdown = ShutdownManager.init(), /* ... */ };

    // シャットダウンハンドラを別タスクで起動
    _ = io.async(waitForShutdownSignal, .{ &server.shutdown, io });

    // メインの accept ループ
    try server.run(io);
}

fn waitForShutdownSignal(shutdown: *ShutdownManager, io: anytype) void {
    // OS シグナル受信を待機し、シャットダウンを要求する
    shutdown.stop_event.waitUncancelable(io);
    shutdown.requestShutdown(io);
}
```

---

## シャットダウンのテスト

```zig
test "シャットダウンフラグの初期状態" {
    var sm = ShutdownManager.init();
    try std.testing.expect(!sm.isStopRequested());
}

test "シャットダウン要求後のフラグ" {
    var sm = ShutdownManager.init();
    // アトミック操作のテスト（Io なしで直接操作）
    sm.stop_requested.store(true, .release);
    try std.testing.expect(sm.isStopRequested());
}
```

---

## まとめ

- `std.atomic.Value(bool)` はロックなしで安全な停止フラグを提供する
- `.release` / `.acquire` メモリオーダリングにより、フラグ変更の可視性が保証される
- `std.Io.Event` はブロック中のタスクを明示的に起動できる
- `Event.waitTimeout` により、シャットダウンが無限に待つことを防止する
- シャットダウンシーケンスは8ステップで段階的に実行する
- `getOneUncancelable` で `Io.Queue` の残メッセージをドレインできる
- 各タスクのメインループ内で停止フラグをチェックすることで、協調的に停止する

次章では、Zig 0.16 らしい設計パターンを総合的に学ぶ。
