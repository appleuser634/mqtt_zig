# 第12章: RetainedメッセージとWillメッセージ

## 学習目標

- Retained メッセージの保存・配信の仕組みを理解する
- 空ペイロードによる Retained メッセージの削除を実装できる
- Will メッセージの目的と非正常切断時の動作を理解する
- Zig 0.16 の `std.Io.Mutex` による RetainStore の保護を実装できる
- `allocator.dupe` によるメモリ所有権の管理を活用できる

---

## Retained メッセージとは

Retained メッセージは、トピックごとにブローカーが保持する「最後のメッセージ」である。新しいサブスクライバーが接続した際に、即座にそのトピックの最新値を受け取れる。

### ユースケース

- 温度センサーの最新値: サブスクライバーは接続直後に現在の温度を知りたい
- デバイスのオンライン状態: `devices/sensor-01/status` に "online" を retain で保持

### 動作の流れ

```
1. Publisher が PUBLISH (retain=1, topic="room/temp", payload="25.3") を送信
2. Broker が RetainStore にこのメッセージを保存
3. 通常のサブスクライバーにも PUBLISH を転送（retain=0 で）
4. 後から Subscriber が "room/temp" をサブスクライブ
5. Broker は即座に保存済みの retained メッセージを PUBLISH (retain=1) で送信
```

---

## RetainStore の実装

RetainStore は `std.Io.Mutex` で保護する。読み取りと書き込みの頻度が同程度であり、RwLock より Mutex の方が適切である。

### 基本構造

```zig
const RetainedMessage = struct {
    topic: []const u8,
    payload: []const u8,
    qos: u2,
};

const RetainStore = struct {
    mutex: std.Io.Mutex = .init,
    messages: std.StringHashMap(RetainedMessage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RetainStore {
        return .{
            .messages = std.StringHashMap(RetainedMessage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RetainStore, io: *std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var iter = self.messages.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.payload);
        }
        self.messages.deinit();
    }
};
```

### メッセージの保存

```zig
pub fn store(
    self: *RetainStore,
    io: *std.Io,
    topic: []const u8,
    payload: []const u8,
    qos: u2,
) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    // 空ペイロード = retained メッセージの削除
    if (payload.len == 0) {
        if (self.messages.fetchRemove(topic)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.payload);
        }
        return;
    }

    // 既存のメッセージがあれば古いデータを解放
    if (self.messages.fetchRemove(topic)) |removed| {
        self.allocator.free(removed.key);
        self.allocator.free(removed.value.payload);
    }

    // 新しいデータを複製して保存
    const owned_topic = try self.allocator.dupe(u8, topic);
    errdefer self.allocator.free(owned_topic);

    const owned_payload = try self.allocator.dupe(u8, payload);
    errdefer self.allocator.free(owned_payload);

    try self.messages.put(owned_topic, .{
        .topic = owned_topic,
        .payload = owned_payload,
        .qos = qos,
    });
}
```

### メッセージの取得

新しいサブスクリプション登録時に、マッチする Retained メッセージを返す。

```zig
pub fn getMatching(
    self: *RetainStore,
    io: *std.Io,
    topic_filter: []const u8,
    buf: []RetainedMessage,
) usize {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    var count: usize = 0;
    var iter = self.messages.iterator();

    while (iter.next()) |entry| {
        if (topicMatchesFilter(entry.key_ptr.*, topic_filter)) {
            if (count < buf.len) {
                buf[count] = entry.value_ptr.*;
                count += 1;
            }
        }
    }
    return count;
}
```

---

## 空ペイロードによる削除

MQTT 仕様では、retain フラグが立った PUBLISH で空のペイロードを送ると、そのトピックの Retained メッセージが削除される。

```zig
// クライアント側: retained メッセージを削除する
try client.publish(io, "room/temp", "", .{ .retain = true });
```

これはセンサーがオフラインになった際に、古い値を残さないために使われる。

### 削除の内部処理

```zig
// store() 内の該当部分
if (payload.len == 0) {
    if (self.messages.fetchRemove(topic)) |removed| {
        // 所有権を持つデータを確実に解放
        self.allocator.free(removed.key);
        self.allocator.free(removed.value.payload);
    }
    return;
}
```

`fetchRemove` は削除と同時にキーと値を返す。所有権を持つメモリを確実に解放するために、この戻り値を利用する。

---

## サブスクリプション時の Retained メッセージ配信

```zig
fn handleSubscribe(self: *ConnectionHandler, io: *std.Io) !void {
    const sub = try self.decodeSubscribe();

    for (sub.topic_filters) |filter| {
        // サブスクリプションを登録
        try self.session_manager.addSubscription(
            io,
            self.client_id.?,
            filter.topic,
            filter.max_qos,
        );

        // マッチする retained メッセージを配信
        var retained_buf: [32]RetainedMessage = undefined;
        const count = self.retain_store.getMatching(
            io,
            filter.topic,
            &retained_buf,
        );

        for (retained_buf[0..count]) |msg| {
            const effective_qos = @min(msg.qos, filter.max_qos);
            try self.sendPublish(io, msg.topic, msg.payload, effective_qos, .{
                .retain = true, // retained メッセージであることを示す
            });
        }
    }

    try self.sendSuback(io, sub.packet_id, sub.topic_filters);
}
```

---

## Will メッセージとは

Will メッセージは、クライアントが非正常切断した場合にブローカーが自動的にパブリッシュするメッセージである。CONNECT パケット内で事前に設定する。

### ユースケース

- デバイスの死活監視: `devices/sensor-01/status` に "offline" を Will メッセージとして設定
- アラート通知: 重要なクライアントの切断を他のクライアントに通知

### CONNECT パケットでの指定

```
Connect Flags:
  bit 2: Will Flag = 1
  bit 3-4: Will QoS = 0-2
  bit 5: Will Retain = 0 or 1

ペイロード（Will Flag=1 の場合）:
  - Will Topic (UTF-8 文字列)
  - Will Message (バイナリデータ)
```

```zig
const WillMessage = struct {
    topic: []const u8,
    payload: []const u8,
    qos: u2,
    retain: bool,
};

fn decodeWill(connect_flags: u8, reader: anytype) !?WillMessage {
    if (connect_flags & 0x04 == 0) return null; // Will Flag なし

    const will_qos: u2 = @intCast((connect_flags >> 3) & 0x03);
    const will_retain = (connect_flags & 0x20) != 0;
    const will_topic = try readUtf8String(reader);
    const will_payload = try readBinaryData(reader);

    return .{
        .topic = will_topic,
        .payload = will_payload,
        .qos = will_qos,
        .retain = will_retain,
    };
}
```

---

## Will メッセージの発行条件

Will メッセージは以下の場合に発行される:

1. **ネットワーク障害**: TCP 接続が異常切断された
2. **キープアライブ超過**: 1.5倍のタイムアウト以内にパケットが届かなかった
3. **プロトコルエラー**: 不正なパケットを受信した

Will メッセージが発行されない場合:

1. **正常な DISCONNECT**: クライアントが DISCONNECT パケットを送信して切断した

```zig
fn connectionClosed(
    self: *ConnectionHandler,
    io: *std.Io,
    reason: DisconnectReason,
) void {
    switch (reason) {
        .graceful_disconnect => {
            // DISCONNECT パケットを受信: Will メッセージは発行しない
            self.session_manager.disconnectClient(io, self.client_id.?, true);
        },
        .network_error, .keepalive_timeout, .protocol_error => {
            // 非正常切断: Will メッセージを発行
            if (self.session) |session| {
                if (session.will_message) |will| {
                    self.publishWill(io, will);
                }
            }
            self.session_manager.disconnectClient(io, self.client_id.?, false);
        },
    }
}
```

### Will メッセージの転送

```zig
fn publishWill(self: *ConnectionHandler, io: *std.Io, will: WillMessage) void {
    // Retained フラグが立っていれば保存
    if (will.retain) {
        self.retain_store.store(io, will.topic, will.payload, will.qos) catch {};
    }

    // サブスクライバーに転送
    var buf: [128]SubscriberInfo = undefined;
    const count = self.session_manager.getSubscribers(io, will.topic, &buf);
    for (buf[0..count]) |sub| {
        const effective_qos = @min(will.qos, sub.max_qos);
        sub.connection.sendPublish(
            io,
            will.topic,
            will.payload,
            effective_qos,
        ) catch {};
    }
}
```

---

## メモリ所有権と allocator.dupe

Zig では GC がないため、メモリの所有権を明確にする必要がある。

### 問題: ダングリングポインタ

```zig
// 悪い例: パケットバッファの一部を直接保存
fn badStore(self: *RetainStore, io: *std.Io, packet: *const Packet) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    // packet.payload はパケットバッファの一部を指している
    // パケット処理が終わるとバッファは解放される
    try self.messages.put(packet.topic, .{
        .payload = packet.payload, // ダングリングポインタ!
    });
}
```

### 解決: allocator.dupe でコピー

```zig
// 正しい例: データを複製して所有権を RetainStore に移す
fn goodStore(
    self: *RetainStore,
    io: *std.Io,
    topic: []const u8,
    payload: []const u8,
) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const owned_payload = try self.allocator.dupe(u8, payload);
    errdefer self.allocator.free(owned_payload);

    const owned_topic = try self.allocator.dupe(u8, topic);
    errdefer self.allocator.free(owned_topic);

    try self.messages.put(owned_topic, .{
        .topic = owned_topic,
        .payload = owned_payload,
    });
    // 所有権は RetainStore に移った
    // 解放は RetainStore.deinit() または上書き時に行う
}
```

`allocator.dupe(u8, slice)` は、スライスの内容を新しく確保したメモリにコピーする。戻り値のスライスはアロケータが所有するため、不要になったら `allocator.free` で解放する。

### 所有権の注意点

| パターン | 安全性 | 説明 |
|---------|-------|------|
| 直接参照 | 危険 | 元のバッファが解放されるとダングリング |
| `allocator.dupe` | 安全 | 独立したメモリに複製 |
| `errdefer` + `dupe` | 安全 | エラー時も確実に解放 |

---

## Retained + Will の組み合わせ

Will メッセージを retain 付きで設定すると、クライアントの死活状態を永続的に通知できる。

```
1. クライアント接続時:
   - Will: topic="status/sensor-01", payload="offline", retain=true
   - 接続後に publish: topic="status/sensor-01", payload="online", retain=true

2. 正常動作中:
   - "status/sensor-01" の retained 値は "online"

3. 非正常切断時:
   - Will メッセージが発行され、retained 値が "offline" に更新される
   - 新しいサブスクライバーは "offline" を受け取る
```

この パターンはデバイス管理において非常に強力である。サブスクライバーは接続するだけで、全デバイスの現在のステータスを即座に取得できる。

---

## Mutex と RwLock の選択基準（再確認）

RetainStore には `Io.Mutex` を使い、SessionManager には `Io.RwLock` を使う。
その理由を改めて整理する。

```zig
// RetainStore: Mutex を使用
// 理由: store（書き込み）と getMatching（読み取り）の頻度が同程度
// Retain メッセージはそもそも数が少なく、ロック競合が低い
mutex: std.Io.Mutex = .init,

// SessionManager: RwLock を使用
// 理由: getSubscribers（読み取り）が圧倒的に多い
// 全 PUBLISH メッセージで読み取りが発生するため、読み取り並行性が重要
rwlock: std.Io.RwLock = .init,
```

---

## まとめ

- Retained メッセージはトピックごとの「最新値」をブローカーに保持する仕組み
- 空ペイロードで retained メッセージを削除できる
- Will メッセージは非正常切断時のみ発行される遺言メッセージ
- RetainStore は `std.Io.Mutex` で保護する（`lockUncancelable(io)` / `unlock(io)`）
- `allocator.dupe` でデータをコピーし、所有権を明確に管理する
- `errdefer` と組み合わせることで、エラー時のリソースリークを防ぐ
- Retained + Will の組み合わせでデバイスの死活監視が実現できる

次章では、複数クライアントを統合した動作デモを構築する。
