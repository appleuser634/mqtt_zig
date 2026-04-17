# 第8章: QoS配信保証

## 学習目標

- MQTT の QoS 0, QoS 1, QoS 2 の違いを理解する
- パケットIDの管理方法（atomic カウンタによる単調増加）を実装できる
- In-flight メッセージの追跡に HashMap を活用できる
- Zig 0.16 の `std.atomic.Value` を用いたスレッドセーフなカウンタを理解する

---

## QoS とは

MQTT では、メッセージ配信の信頼性を3段階で指定できる。
パブリッシャーがブローカーへ送る際の QoS と、ブローカーがサブスクライバーへ転送する際の QoS は独立して扱われる。

| レベル | 名称 | 配信保証 |
|--------|------|----------|
| QoS 0 | At most once | 最大1回。ロスの可能性あり |
| QoS 1 | At least once | 最低1回。重複の可能性あり |
| QoS 2 | Exactly once | 正確に1回。最も重い |

---

## QoS 0: At most once（火と忘れ）

QoS 0 は最もシンプルなフローである。PUBLISH パケットを送信したら、それで完了となる。
確認応答は一切行われない。

```
Publisher ──── PUBLISH (QoS 0) ────> Broker ──── PUBLISH (QoS 0) ────> Subscriber
```

パケットIDフィールドは QoS 0 では存在しない。

### 実装上のポイント

```zig
fn handlePublish(self: *Connection, io: *std.Io, packet: PublishPacket) !void {
    if (packet.qos == .at_most_once) {
        // QoS 0: 確認応答なし。即座にルーティングする
        try self.router.route(io, packet.topic, packet.payload, .at_most_once);
        return;
    }
    // QoS 1 以上の処理は後述
}
```

QoS 0 は IoT センサーの温度データなど、多少のロスが許容されるユースケースに適している。

---

## QoS 1: At least once

QoS 1 では、送信側は PUBLISH を送り、受信側は PUBACK で確認応答を返す。
PUBACK を受信するまで、送信側はメッセージを保持し、タイムアウト後に再送する。

```
Publisher                     Broker                      Subscriber
   |                            |                            |
   |── PUBLISH (QoS 1, id=1) ─>|                            |
   |                            |── PUBLISH (QoS 1, id=7) ─>|
   |                            |<── PUBACK (id=7) ──────────|
   |<── PUBACK (id=1) ─────────|                            |
```

重要な点として、パブリッシャーからブローカーへの packet_id と、ブローカーからサブスクライバーへの packet_id は別の値になる。

### パケットIDの管理

パケットIDは 1 から 65535 の範囲で単調増加させる。0 は使用しない。
Zig 0.16 の `std.atomic.Value` を使えば、複数スレッドから安全にIDを生成できる。

```zig
const PacketIdGenerator = struct {
    counter: std.atomic.Value(u16),

    pub fn init() PacketIdGenerator {
        return .{
            .counter = std.atomic.Value(u16).init(0),
        };
    }

    /// スレッドセーフにパケットIDを生成する
    /// CAS (Compare-And-Swap) ループにより競合時にリトライする
    pub fn next(self: *PacketIdGenerator) u16 {
        while (true) {
            const current = self.counter.load(.acquire);
            const new_val = if (current == 65535) 1 else current + 1;
            if (self.counter.cmpxchgWeak(
                current,
                new_val,
                .release,
                .monotonic,
            ) == null) {
                return new_val;
            }
            // 競合発生時はループしてリトライ
        }
    }
};
```

`cmpxchgWeak` は、`current` が実際の値と一致する場合のみ `new_val` を書き込む。
他スレッドが先に更新していた場合は `null` 以外を返すため、ループで再試行する。

### メモリオーダリングの選択

| オーダリング | 用途 |
|------------|------|
| `.acquire` | load 時: この読み取り以降の操作が先行しない |
| `.release` | store 時: この書き込み以前の操作が後続しない |
| `.monotonic` | 失敗時: 最小限の保証で十分 |

パケットID生成では厳密な順序保証は不要だが、値の一貫性は必要であるため、acquire/release を使う。

---

## In-flight メッセージの追跡

PUBACK を受け取るまでメッセージを保持するため、HashMap を使う。

```zig
const InFlightMessage = struct {
    topic: []const u8,
    payload: []const u8,
    sent_at: i64,
    retry_count: u8,
};

const InFlightMap = std.HashMap(
    u16,
    InFlightMessage,
    std.hash_map.AutoContext(u16),
    80,
);
```

### QoS 1 メッセージの送信と追跡

```zig
fn sendQos1(
    self: *Connection,
    io: *std.Io,
    topic: []const u8,
    payload: []const u8,
) !void {
    const packet_id = self.packet_id_gen.next();

    // In-flight マップに登録
    try self.in_flight.put(packet_id, .{
        .topic = topic,
        .payload = payload,
        .sent_at = std.time.milliTimestamp(),
        .retry_count = 0,
    });

    // PUBLISH パケットを送信
    try self.sendPublishPacket(io, topic, payload, packet_id, .at_least_once);
}

fn handlePuback(self: *Connection, packet_id: u16) void {
    // 確認応答を受信したので、in-flight マップから削除
    _ = self.in_flight.remove(packet_id);
}
```

### 再送ロジック

一定時間内に PUBACK が届かない場合、DUP フラグを立てて再送する。

```zig
const retry_timeout_ms: i64 = 5000; // 5秒

fn retryInFlightMessages(self: *Connection, io: *std.Io) !void {
    const now = std.time.milliTimestamp();
    var iter = self.in_flight.iterator();

    while (iter.next()) |entry| {
        const msg = entry.value_ptr;
        const elapsed = now - msg.sent_at;

        if (elapsed > retry_timeout_ms) {
            msg.retry_count += 1;
            msg.sent_at = now;
            // DUP=true で再送
            try self.sendPublishPacket(
                io,
                msg.topic,
                msg.payload,
                entry.key_ptr.*,
                .at_least_once,
            );
        }
    }
}
```

再送タイマーの実装には Zig 0.16 の sleep API を活用できる。

```zig
fn retryLoop(self: *Connection, io: *std.Io) !void {
    while (!self.should_stop.load(.acquire)) {
        std.Io.Clock.Duration.sleep(.{
            .clock = .awake,
            .raw = .fromMilliseconds(1000),
        }, io);
        try self.retryInFlightMessages(io);
    }
}
```

---

## QoS 2: Exactly once（概念説明）

QoS 2 は4ステップのハンドシェイクにより、正確に1回の配信を保証する。
本プロジェクトでは実装しないが、概念を理解しておくことは重要である。

```
Publisher                     Broker
   |                            |
   |── PUBLISH (QoS 2, id=1) ─>|
   |<── PUBREC  (id=1) ────────|   <- 受信確認
   |── PUBREL   (id=1) ───────>|   <- 解放要求
   |<── PUBCOMP (id=1) ────────|   <- 完了通知
```

各ステップの役割:

1. **PUBLISH**: パブリッシャーがメッセージを送信
2. **PUBREC** (Publish Received): ブローカーが受信を確認。この時点でメッセージを保存
3. **PUBREL** (Publish Release): パブリッシャーが解放を指示。ブローカーはサブスクライバーへ転送
4. **PUBCOMP** (Publish Complete): ブローカーが完了を通知。双方が状態をクリア

QoS 2 を実装しない理由は、オーバーヘッドが大きく、多くの IoT ユースケースでは QoS 1 で十分なためである。

---

## PUBACK パケットのエンコード/デコード

PUBACK は非常にシンプルな固定長パケットである。

```
バイト1: 0x40 (パケットタイプ=4, フラグ=0)
バイト2: 0x02 (残りの長さ=2)
バイト3-4: パケットID (u16 big-endian)
```

```zig
fn encodePuback(packet_id: u16) [4]u8 {
    return .{
        0x40,                          // PUBACK パケットタイプ
        0x02,                          // 残りの長さ
        @intCast(packet_id >> 8),      // パケットID上位バイト
        @intCast(packet_id & 0xFF),    // パケットID下位バイト
    };
}

fn decodePuback(data: []const u8) !u16 {
    if (data.len < 4) return error.IncompletePacket;
    if (data[0] != 0x40) return error.InvalidPacketType;
    return @as(u16, data[2]) << 8 | @as(u16, data[3]);
}
```

---

## サブスクリプションの QoS ダウングレード

サブスクライバーが QoS 1 でサブスクライブしていても、パブリッシャーが QoS 0 で送信した場合、ブローカーは QoS 0 で転送する。配信 QoS は両者の最小値になる。

```zig
fn effectiveQos(publish_qos: QoS, subscription_qos: QoS) QoS {
    return @enumFromInt(@min(
        @intFromEnum(publish_qos),
        @intFromEnum(subscription_qos),
    ));
}
```

このルールにより、パブリッシャーが意図しない高い QoS で配信されることを防ぐ。

---

## atomic パターンのまとめ

Zig 0.16 で利用可能な atomic 操作の一覧:

```zig
const AtomicU16 = std.atomic.Value(u16);

// 初期化
var counter = AtomicU16.init(0);

// 読み取り
const val = counter.load(.acquire);

// 書き込み
counter.store(42, .release);

// CAS (Compare-And-Swap)
// 成功時は null、失敗時は実際の値を返す
if (counter.cmpxchgWeak(expected, desired, .release, .monotonic)) |actual| {
    // 競合発生: actual が現在の値
} else {
    // 成功: expected -> desired に更新された
}

// fetchAdd / fetchSub も利用可能
const old = counter.fetchAdd(1, .monotonic);
```

---

## まとめ

| 項目 | QoS 0 | QoS 1 | QoS 2 |
|------|-------|-------|-------|
| 確認応答 | なし | PUBACK | 4-way ハンドシェイク |
| パケットID | なし | 必要 | 必要 |
| 重複配信 | なし | あり得る | なし |
| 実装複雑度 | 低 | 中 | 高 |

- `std.atomic.Value` で CAS ループによるスレッドセーフなID生成を実現する
- In-flight HashMap でタイムアウト再送を管理する
- QoS ダウングレードにより、配信 QoS は publish と subscription の最小値になる

次章では、接続を維持するためのキープアライブの仕組みを学ぶ。
