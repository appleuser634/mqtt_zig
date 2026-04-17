# 第18章: Zigらしい設計パターン

## 学習目標

- Zig 0.16 の "Juicy Main" パターンを理解し活用できる
- RwLock と Mutex の使い分けを判断できる
- アロケータの適切な選択と管理ができる
- エラーハンドリングのベストプラクティスを適用できる
- build.zig のモジュール構成を設計できる
- comptime を活用したプロトコル定数の最適化ができる
- ホットパスでの不要なメモリ確保を回避できる

---

## "Juicy Main" パターン

Zig 0.16 では `std.process.Init` を受け取る `main` 関数が推奨される。
このパターンにより、ランタイムの初期化ボイラープレートが不要になる。

### Juicy Main パターン（0.16）

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;          // 汎用アロケータ（初期化済み）
    var io = init.io;              // Io インスタンス（初期化済み）
    const args = init.minimal.args; // プログラム引数
    try runServer(gpa, io, args);
}
```

| フィールド | 説明 |
|-----------|------|
| `init.gpa` | 汎用アロケータ（GPA、初期化済み） |
| `init.io` | デフォルトの Io バックエンド |
| `init.minimal.args` | プログラム引数 |

従来は `GeneralPurposeAllocator`, `Io.Threaded`, 引数パーサーを手動初期化し
`defer` で解放する必要があった。Juicy Main により全て不要になる。

---

## RwLock vs Mutex: 使い分け

Zig 0.16 では `std.Io.RwLock` が提供される。
読み取りが多く書き込みが少ないデータ構造には RwLock が適している。

### RwLock の基本 API

```zig
var lock: std.Io.RwLock = .init;

// 共有ロック（読み取り用、複数タスクが同時に取得可能）
{
    lock.lockShared(io);
    defer lock.unlockShared(io);
    // 読み取り操作
    const value = data.get(key);
    _ = value;
}

// 排他ロック（書き込み用、1タスクのみ取得可能）
{
    lock.lockExclusive(io);
    defer lock.unlockExclusive(io);
    // 書き込み操作
    try data.put(key, value);
}
```

### MQTT ブローカーでの適用判断

| データ構造 | 読み/書き比率 | 推奨 | 理由 |
|-----------|-------------|------|------|
| サブスクリプションマップ | 読み取り 95% / 書き込み 5% | **RwLock** | PUBLISH ルーティング時に頻繁に検索、SUBSCRIBE/UNSUBSCRIBE は稀 |
| 接続マップ | 読み取り 50% / 書き込み 50% | Mutex | 接続・切断が頻繁に発生 |
| リテインストア | 読み取り 80% / 書き込み 20% | **RwLock** | 新規 SUBSCRIBE 時に検索、PUBLISH retain は比較的稀 |
| パケット ID カウンタ | 書き込み 100% | Mutex | 常にインクリメント |

### 適用例: サブスクリプション検索の高速化

```zig
const SubscriptionStore = struct {
    lock: std.Io.RwLock,
    subscriptions: std.StringHashMap(SubscriptionList),

    /// PUBLISH ルーティング時: 共有ロックで並行検索
    pub fn findSubscribers(self: *SubscriptionStore, io: anytype, topic: []const u8, buf: []SubscriberInfo) usize {
        self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        return self.matchTopic(topic, buf);
    }

    /// SUBSCRIBE 時: 排他ロックで書き込み
    pub fn addSubscription(self: *SubscriptionStore, io: anytype) !void {
        self.lock.lockExclusive(io);
        defer self.lock.unlockExclusive(io);
        // サブスクリプションを追加
    }
};
```

---

## アロケータの規律

Zig のアロケータは用途に応じて使い分ける。
MQTT ブローカーでは以下の3種類を主に使用する。

### アロケータの選択指針

| アロケータ | 用途 | ライフタイム | 例 |
|-----------|------|------------|---|
| `std.heap.page_allocator` | 長寿命サーバーデータ | プロセス全体 | SessionManager, RetainStore |
| `std.heap.ArenaAllocator` | リクエスト単位の一時データ | 1パケット処理 | PUBLISH デコード時のバッファ |
| `init.gpa` | 汎用 | 可変 | ハッシュマップ、文字列複製 |

### ArenaAllocator によるリクエスト単位メモリ管理

```zig
fn handlePublish(self: *ConnectionHandler, first_byte: u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit(); // パケット処理完了時に一括解放
    const alloc = arena.allocator();

    const topic = try alloc.dupe(u8, raw_topic);
    const payload = try alloc.dupe(u8, raw_payload);
    try self.routePublish(topic, payload, first_byte);
    // arena.deinit() により全メモリが一括解放
}
```

### allocator.dupe による所有権移転

```zig
pub fn createSession(self: *SessionManager, client_id: []const u8) !*Session {
    const owned_id = try self.allocator.dupe(u8, client_id); // コピーを作成
    errdefer self.allocator.free(owned_id); // 以降のエラーで解放
    const session = try self.allocator.create(Session);
    session.* = .{ .client_id = owned_id, .subscriptions = std.StringHashMap(u2).init(self.allocator) };
    return session;
}
```

---

## エラーハンドリングパターン

### errdefer によるクリーンアップ

`errdefer` は関数がエラーを返した場合にのみ実行される。

```zig
const net = std.Io.net;

fn setupConnection(allocator: std.mem.Allocator, stream: net.Stream) !*Connection {
    const conn = try allocator.create(Connection);
    errdefer allocator.destroy(conn);         // 以降でエラー → conn を解放

    conn.recv_buffer = try allocator.alloc(u8, 65536);
    errdefer allocator.free(conn.recv_buffer); // 以降でエラー → バッファも解放

    conn.send_buffer = try allocator.alloc(u8, 65536);
    conn.stream = stream;
    return conn; // 正常リターン: errdefer は実行されない
}
```

### MQTT 固有のエラーセット

```zig
pub const MqttError = error{
    InvalidPacketType, MalformedPacket, ProtocolViolation,
    ClientIdTooLong, UnsupportedProtocolVersion, BadCredentials, NotAuthorized,
    SessionStoreFull, TooManySubscriptions, QueueFull,
};

fn toConnackCode(err: MqttError) u8 {
    return switch (err) {
        error.UnsupportedProtocolVersion => 0x01,
        error.ClientIdTooLong => 0x02,
        error.BadCredentials => 0x04,
        error.NotAuthorized => 0x05,
        else => 0x03,
    };
}
```

### catch/switch によるグレースフルデグラデーション

```zig
fn handleClientPacket(self: *Handler, packet_type: u4) void {
    self.processPacket(packet_type) catch |err| switch (err) {
        error.EndOfStream => std.log.info("クライアント切断: {s}", .{self.client_id}),
        error.ConnectionResetByPeer => std.log.warn("接続リセット: {s}", .{self.client_id}),
        error.MalformedPacket => std.log.warn("不正パケット: {s}", .{self.client_id}),
        else => std.log.err("内部エラー: {s}: {}", .{ self.client_id, err }),
    };
}
```

---

## build.zig のモジュール構成

Zig 0.16 ではモジュール境界が厳格化されており、
`@import` でディレクトリをまたぐ場合は `createModule` で
明示的にモジュールを定義する必要がある。

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 共通モジュールを定義
    const mqtt_module = b.createModule(.{
        .root_source_file = b.path("src/mqtt/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 各バイナリにモジュールをインポート
    const broker = b.addExecutable(.{
        .name = "mqtt-broker",
        .root_source_file = b.path("src/broker/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    broker.root_module.addImport("mqtt", mqtt_module);
    b.installArtifact(broker);
}
```

モジュール境界を意識した設計により、`@import("mqtt")` のように
名前付きインポートで依存関係が明確になる。
同一ディレクトリ内のファイルは `@import("server.zig")` で直接参照可能。

---

## comptime によるプロトコル定数

MQTT パケットタイプのルックアップテーブルや固定サイズパケットの
バリデーションを `comptime` で構築する。

### パケットタイプの comptime 列挙

```zig
const PacketType = enum(u4) {
    connect = 1, connack = 2, publish = 3, puback = 4,
    pubrec = 5, pubrel = 6, pubcomp = 7, subscribe = 8,
    suback = 9, unsubscribe = 10, unsuback = 11,
    pingreq = 12, pingresp = 13, disconnect = 14,

    pub fn fromByte(byte: u8) ?PacketType {
        const type_val: u4 = @intCast(byte >> 4);
        return std.meta.intToEnum(PacketType, type_val) catch null;
    }
};
```

### 固定サイズパケットの comptime 定義

```zig
const FixedPackets = struct {
    pub const connack_accepted = comptime blk: {
        var buf: [4]u8 = undefined;
        buf[0] = 0x20; buf[1] = 0x02; buf[2] = 0x00; buf[3] = 0x00;
        break :blk buf;
    };
    pub const pingresp = [2]u8{ 0xD0, 0x00 };
    pub const disconnect = [2]u8{ 0xE0, 0x00 };
};

// 使用例: バイナリにリテラルとして埋め込まれ、ランタイムコストゼロ
fn sendConnack(stream: net.Stream, io: anytype) !void {
    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(&FixedPackets.connack_accepted);
    try writer.interface.flush();
}
```

---

## パフォーマンスのヒント

### 1. 固定バッファの優先

```zig
// 悪い例: ヒープ確保
const topic = try allocator.alloc(u8, topic_len);
defer allocator.free(topic);

// 良い例: スタック上の固定バッファ（ヒープ確保なし）
var topic_buf: [256]u8 = undefined;
const topic = topic_buf[0..topic_len];
```

### 2. Buffered Writer による書き込みバッチ化

```zig
var write_buf: [4096]u8 = undefined;
var writer = stream.writer(io, &write_buf);
try writer.interface.writeAll(&[_]u8{0x30});
try writer.interface.writeAll(topic);
try writer.interface.writeAll(payload);
try writer.interface.flush(); // 1回の write システムコール
```

### 3. PUBLISH ルーティングでの確保回避

PUBLISH はブローカーのホットパスであり、メモリ確保をゼロにすることが性能の鍵。

```zig
fn routePublish(self: *Broker, topic: []const u8, payload: []const u8, qos: u2, io: anytype) !void {
    var sub_buf: [128]*ClientConnection = undefined; // スタック上（ヒープ確保なし）
    const count = self.subscription_store.findSubscribers(io, topic, &sub_buf);
    const msg = OutboundMessage.from(topic, payload, qos); // 固定サイズ構造体
    for (sub_buf[0..count]) |sub| {
        sub.message_queue.enqueue(io, msg) catch { sub.message_queue.close(io); };
    }
}
```

| 処理 | 動的確保あり | 固定バッファ | 改善 |
|------|------------|------------|------|
| PUBLISH デコード | ~200ns | ~20ns | 10倍 |
| サブスクライバー検索 | ~500ns | ~50ns | 10倍 |
| キュー投入 | ~300ns | ~30ns | 10倍 |

---

## まとめ

- Juicy Main (`std.process.Init`) で初期化ボイラープレートを排除する
- 読み取り頻度の高いデータ構造には `std.Io.RwLock` を使い、並行読み取りを許可する
- アロケータは用途に応じて使い分け、ホットパスでは固定バッファを優先する
- `errdefer` でエラーパスのリソースリークを確実に防ぐ
- `build.zig` の `createModule` でモジュール境界を明示し、依存関係を管理する
- `comptime` でプロトコル定数を定義し、ランタイムコストをゼロにする
- PUBLISH ルーティングのようなホットパスでは、メモリ確保をゼロに抑えることが最重要

これらのパターンを組み合わせることで、安全で高性能な MQTT ブローカーが実現できる。
