# 第10章: ブローカーの全体設計

## 学習目標

- MQTT ブローカーの主要コンポーネントと Zig 0.16 のアーキテクチャを理解する
- `std.Io.Threaded` による Io ランタイムの初期化を把握する
- `std.process.Init`（Juicy Main パターン）でエントリポイントを設計できる
- `std.Io.RwLock` と `std.Io.Mutex` の使い分けを理解する
- Thread-per-connection モデルと graceful shutdown を実装できる
- server.zig, connection.zig, session.zig の責務分担を理解する

---

## アーキテクチャ概要

本プロジェクトのブローカーは以下の主要コンポーネントから構成される。

```
+-----------------------------------------------------+
|                    MqttBroker                        |
|                                                     |
|  +-----------+   +------------------+               |
|  |  Listener  |-->| ConnectionHandler | (per thread) |
|  +-----------+   +--------+---------+               |
|                           |                         |
|            +--------------+--------------+          |
|            v              v              v          |
|  +--------------+ +------------+ +-------------+    |
|  |SessionManager| |   Router   | | RetainStore  |    |
|  | (RwLock)     | | (RwLock)   | | (Mutex)      |    |
|  +--------------+ +------------+ +-------------+    |
|                                                     |
|  Graceful shutdown: atomic.Value(bool) + Io.Event   |
+-----------------------------------------------------+
```

| コンポーネント | ファイル | 責務 | 同期プリミティブ |
|-------------|---------|------|---------------|
| Listener | server.zig | TCP 接続の受け入れ | - |
| ConnectionHandler | connection.zig | 個別クライアントのパケット処理 | - |
| SessionManager | session.zig | セッションの作成・検索・破棄 | `Io.RwLock` |
| Router | router.zig | トピックマッチングとメッセージ転送 | `Io.RwLock` |
| RetainStore | retain.zig | Retained メッセージの保存と配信 | `Io.Mutex` |

---

## Juicy Main パターン: std.process.Init

Zig 0.16 では、`main` 関数のシグネチャが `std.process.Init` を受け取る形に変わった。
これにより、アロケータと Io ランタイムが標準的に提供される。

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // init.gpa: GeneralPurposeAllocator（プロセス標準のアロケータ）
    // init.io:  Io ランタイム（ネットワーク、スリープ等に必要）
    const allocator = init.gpa;
    const io = init.io;

    var broker = MqttBroker.init(allocator);
    defer broker.deinit();

    try broker.run(io, 1883);
}
```

### init.gpa と init.io の役割

| フィールド | 型 | 用途 |
|-----------|---|------|
| `init.gpa` | `std.mem.Allocator` | 汎用メモリアロケータ |
| `init.io` | `*std.Io` | Io ランタイム（ネット、スリープ、同期プリミティブ） |

Zig 0.16 の全ての I/O 操作は `io` パラメータを要求する。
ネットワーク接続、reader/writer の生成、Mutex のロック、スリープなど、あらゆる I/O 関連操作に `io` が必要である。

---

## std.Io.Threaded: Io ランタイムの初期化

テストや特殊な環境では、手動で Io ランタイムを構築する必要がある。

```zig
var threaded = std.Io.Threaded.init(allocator, .{});
const io = threaded.io();
```

`std.Io.Threaded` はスレッドプール付きの Io ランタイムを提供する。
通常の `main` 関数では `init.io` を使えばよいが、テスト内でブローカーを起動する場合などに `Threaded` を直接使う。

---

## server.zig: リスナー

サーバーはメインスレッドで TCP ソケットを listen し、新しい接続ごとにスレッドを生成する。
Zig 0.16 では、ネットワーク API に `io` パラメータが必要になる。

```zig
const MqttBroker = struct {
    allocator: std.mem.Allocator,
    session_manager: SessionManager,
    retain_store: RetainStore,
    should_stop: std.atomic.Value(bool),
    shutdown_event: std.Io.Event,

    pub fn init(allocator: std.mem.Allocator) MqttBroker {
        return .{
            .allocator = allocator,
            .session_manager = SessionManager.init(allocator),
            .retain_store = RetainStore.init(allocator),
            .should_stop = std.atomic.Value(bool).init(false),
            .shutdown_event = .unset,
        };
    }

    pub fn run(self: *MqttBroker, io: *std.Io, port: u16) !void {
        const address = std.Io.net.IpAddress.parse("0.0.0.0", port);
        var listener = try address.listen(io, .{
            .reuse_address = true,
        });
        defer listener.close(io);

        std.log.info("MQTT ブローカー起動: ポート {d}", .{port});

        while (!self.should_stop.load(.acquire)) {
            const conn = try listener.accept(io);
            // 接続ごとに新しいスレッドを生成
            const thread = try std.Thread.spawn(.{}, handleConnection, .{
                self, conn, io,
            });
            thread.detach();
        }
    }

    fn handleConnection(
        self: *MqttBroker,
        conn: anytype,
        io: *std.Io,
    ) void {
        var handler = ConnectionHandler.init(
            self.allocator,
            conn,
            &self.session_manager,
            &self.retain_store,
            io,
        );
        defer handler.deinit();
        handler.run() catch |err| {
            std.log.err("接続エラー: {}", .{err});
        };
    }
};
```

---

## connection.zig: 接続ハンドラ

各スレッドで1つのクライアント接続を担当する。reader/writer の生成に `io` が必要である。

```zig
const ConnectionHandler = struct {
    allocator: std.mem.Allocator,
    stream: anytype,
    session_manager: *SessionManager,
    retain_store: *RetainStore,
    io: *std.Io,
    client_id: ?[]const u8 = null,
    keep_alive_s: u16 = 0,
    last_received: i64 = 0,

    pub fn run(self: *ConnectionHandler) !void {
        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = self.stream.reader(self.io, &read_buf);
        var writer = self.stream.writer(self.io, &write_buf);

        // 最初のパケットは CONNECT でなければならない
        try self.handleConnect(&reader, &writer);

        // メインループ: パケットを読み続ける
        while (true) {
            if (self.isKeepAliveExpired()) {
                std.log.info("キープアライブ切れ: {s}", .{
                    self.client_id orelse "unknown",
                });
                return;
            }

            var header_buf: [1]u8 = undefined;
            reader.interface.readSliceAll(&header_buf) catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };

            self.last_received = std.time.nanoTimestamp();
            const packet_type: u4 = @intCast(header_buf[0] >> 4);

            switch (packet_type) {
                3 => try self.handlePublish(header_buf[0], &reader, &writer),
                8 => try self.handleSubscribe(&reader, &writer),
                10 => try self.handleUnsubscribe(&reader, &writer),
                12 => {
                    // PINGREQ -> PINGRESP
                    try writer.interface.writeAll(&PINGRESP_PACKET);
                    try writer.interface.flush();
                },
                14 => return, // DISCONNECT
                else => return error.UnsupportedPacketType,
            }
        }
    }
};
```

---

## 同期プリミティブの使い分け

Zig 0.16 では、同期プリミティブにも `io` パラメータが必要になる。

### std.Io.RwLock: 読み書きロック

SessionManager のように読み取りが頻繁で書き込みが稀な場合に使う。

```zig
// 定義
rwlock: std.Io.RwLock = .init,

// 読み取りロック（複数スレッドが同時に取得可能）
rwlock.lockSharedUncancelable(io);
defer rwlock.unlockShared(io);
// ... 読み取り操作 ...

// 書き込みロック（排他的: 他の読み取り/書き込みを全てブロック）
rwlock.lockUncancelable(io);
defer rwlock.unlock(io);
// ... 書き込み操作 ...
```

### std.Io.Mutex: 排他ロック

RetainStore のように読み書きの比率が同程度、または書き込みが頻繁な場合に使う。

```zig
// 定義
mutex: std.Io.Mutex = .init,

// ロック
mutex.lockUncancelable(io);
defer mutex.unlock(io);
// ... 排他操作 ...
```

### 使い分けの指針

| プリミティブ | 適用場面 | 本プロジェクトでの利用 |
|------------|---------|-------------------|
| `Io.RwLock` | 読み取り多、書き込み少 | SessionManager（購読者検索が頻繁） |
| `Io.Mutex` | 読み書き均等、または書き込み多 | RetainStore、接続リスト |

---

## Graceful Shutdown パターン

`std.atomic.Value(bool)` と `std.Io.Event` を組み合わせて、安全なシャットダウンを実現する。

```zig
const MqttBroker = struct {
    should_stop: std.atomic.Value(bool),
    shutdown_event: std.Io.Event,
    // ...

    pub fn shutdown(self: *MqttBroker, io: *std.Io) void {
        // 停止フラグをセット
        self.should_stop.store(true, .release);
        // イベントをシグナルして待機中のスレッドを起こす
        self.shutdown_event.set(io);
    }
};
```

### シャットダウンの流れ

```
1. 外部からシグナルを受信（Ctrl+C など）
2. should_stop.store(true, .release) で停止フラグをセット
3. shutdown_event.set(io) で待機中のスレッドを起こす
4. 各スレッドが should_stop をチェックして終了
5. メインスレッドで全リソースをクリーンアップ
```

### Event の基本操作

```zig
// 初期化
var event: std.Io.Event = .unset;

// シグナル送信（待機中のスレッドを起こす）
event.set(io);

// 待機（シグナルされるまでブロック）
event.waitUncancelable(io);
```

---

## Thread-per-connection モデル

### 設計思想

各クライアント接続に対して1つの OS スレッドを割り当てるモデルである。

```
メインスレッド (accept ループ)
   |
   +-- スレッド1: クライアントA の処理
   +-- スレッド2: クライアントB の処理
   +-- スレッド3: クライアントC の処理
   +-- ...
```

### 利点

- **実装がシンプル**: 各スレッドはブロッキング I/O を使える
- **デバッグしやすい**: スタックトレースが明確
- **Zig 0.16 との親和性**: `std.Thread.spawn` で直接生成

### 欠点

- **スケーラビリティ**: 数千接続で OS スレッドの限界に達する
- **メモリ使用量**: 各スレッドにスタック領域が必要（デフォルト数MB）

本プロジェクトは教育目的であるため、シンプルさを優先してこのモデルを採用している。

```zig
// 接続の受け入れとスレッド生成
const conn = try listener.accept(io);
const thread = try std.Thread.spawn(.{}, handleConnection, .{
    self, conn, io,
});
thread.detach();
```

---

## 共有状態のロック設計

### ロック保持時間の最小化

ロック中にブロッキング I/O を行うと、他のスレッドが全てブロックされる。
必要なデータだけコピーして即座にアンロックするのが鉄則である。

```zig
// 悪い例: ロック中にネットワーク I/O を行う
self.rwlock.lockSharedUncancelable(io);
defer self.rwlock.unlockShared(io);
try self.stream.writer(io, &buf).interface.writeAll(data); // 全スレッドがブロック

// 良い例: 必要なデータだけコピーして即座にアンロック
var subscribers_buf: [64]SubscriberInfo = undefined;
const count = blk: {
    self.rwlock.lockSharedUncancelable(io);
    defer self.rwlock.unlockShared(io);
    break :blk self.collectSubscribers(topic, &subscribers_buf);
};
// ロック外で I/O を行う
for (subscribers_buf[0..count]) |sub| {
    try sub.connection.sendPublish(io, topic, payload);
}
```

---

## コンポーネント間の相互作用

PUBLISH メッセージを受信してからサブスクライバーに配信するまでの流れ:

```
1. connection.zig: クライアントから PUBLISH パケットを受信・デコード
2. retain.zig:     Retain フラグが立っていれば RetainStore に保存 (Mutex)
3. session.zig:    SessionManager から購読者を検索 (RwLock 読み取り)
4. connection.zig: 各サブスクライバーの接続に PUBLISH を転送
```

```zig
fn handlePublish(
    self: *ConnectionHandler,
    io: *std.Io,
    first_byte: u8,
    reader: anytype,
    writer: anytype,
) !void {
    const packet = try self.decodePublish(first_byte, reader);

    // Retained メッセージの保存 (Mutex で保護)
    if (packet.retain) {
        try self.retain_store.store(io, packet.topic, packet.payload, packet.qos);
    }

    // サブスクライバーへの転送 (RwLock 読み取りで保護)
    var buf: [128]SubscriberInfo = undefined;
    const count = self.session_manager.getSubscribers(io, packet.topic, &buf);

    for (buf[0..count]) |sub| {
        const effective_qos = @min(packet.qos, sub.max_qos);
        sub.connection.sendPublish(io, packet.topic, packet.payload, effective_qos) catch |err| {
            std.log.warn("転送エラー: {}", .{err});
        };
    }

    // QoS 1 なら PUBACK を返す
    if (packet.qos >= 1) {
        try self.sendPuback(writer, packet.packet_id);
    }
}
```

---

## session.zig の概要

SessionManager は `Io.RwLock` で保護する。購読者検索（読み取り）が圧倒的に多いためである。

```zig
const SessionManager = struct {
    rwlock: std.Io.RwLock = .init,
    sessions: std.StringHashMap(*Session),
    allocator: std.mem.Allocator,

    /// 購読者の検索（読み取りロック）
    pub fn getSubscribers(
        self: *SessionManager,
        io: *std.Io,
        topic: []const u8,
        result_buf: []SubscriberInfo,
    ) usize {
        self.rwlock.lockSharedUncancelable(io);
        defer self.rwlock.unlockShared(io);
        // ... 検索処理 ...
    }

    /// セッションの作成（書き込みロック）
    pub fn getOrCreate(
        self: *SessionManager,
        io: *std.Io,
        client_id: []const u8,
        clean: bool,
    ) !*Session {
        self.rwlock.lockUncancelable(io);
        defer self.rwlock.unlock(io);
        // ... 作成処理 ...
    }
};
```

---

## まとめ

- Zig 0.16 の `std.process.Init`（Juicy Main）で `gpa` と `io` を受け取る
- `std.Io.Threaded` はテスト環境などで手動 Io ランタイム構築に使う
- `std.Io.RwLock` は読み取り頻度が高い SessionManager に、`std.Io.Mutex` は RetainStore に使う
- 全ての I/O 操作（ネットワーク、ロック、スリープ）に `io` パラメータが必要
- `std.atomic.Value(bool)` + `std.Io.Event` で graceful shutdown を実現する
- ロック保持時間を最小化し、ロック外で I/O を行うことが並行性能の鍵である

次章では、セッション管理の詳細な実装を学ぶ。
