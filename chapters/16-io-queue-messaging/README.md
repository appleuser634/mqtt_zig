# 第16章: Io.Queueによるメッセージング

## 学習目標

- 直接送信モデルのロック競合問題を理解する
- `std.Io.Queue(T)` の API と動作原理を習得する
- プロデューサー・コンシューマーパターンを MQTT ブローカーに適用できる
- バックプレッシャーによるスロークライアント対策を実装できる
- メモリバウンドなキューによる OOM 防止を理解する

---

## 現在の問題: 直接送信モデルのロック競合

第10章・第15章のブローカーでは、PUBLISH メッセージの配信時に
送信先クライアントの TCP ストリームに直接書き込んでいた。

```zig
// 問題のあるコード: PUBLISH ハンドラ内
for (subscribers) |sub| {
    // 送信先の stream に直接 write
    // → 複数パブリッシャーが同時に同じサブスクライバーに送信すると
    //    データが混在する（interleave）可能性がある
    sub.connection.sendPublish(topic, payload, qos) catch {};
}
```

### 問題点の整理

| 問題 | 説明 |
|------|------|
| データ混在 | 複数スレッドが同じ stream に同時書き込みすると、パケットが壊れる |
| ロック競合 | stream ごとに Mutex を追加すると、高頻度 PUBLISH でボトルネックになる |
| スロークライアント | 書き込みがブロックすると、パブリッシャー側のスレッドも停止する |
| メモリ無制限 | バッファリングなしでは OOM の危険があり、ありでは上限がない |

---

## 解決策: per-client メッセージキュー

各クライアント接続に専用のメッセージキューを持たせる。
パブリッシュハンドラはキューにメッセージを投入するだけで、
実際の TCP 送信はクライアント専用のライタータスクが行う。

```
                        ┌──────────────────┐
  PUBLISH ハンドラ ────>│  Io.Queue(Message) │───> ライタータスク ───> TCP stream
  （プロデューサー）      │  固定サイズバッファ   │    （コンシューマー）
                        └──────────────────┘
```

この設計により:
- **データ混在なし**: stream への書き込みは1つのタスクのみ
- **ロック不要**: Queue が内部で同期を行う
- **バックプレッシャー**: キューが満杯になるとプロデューサーがブロック
- **メモリバウンド**: 固定サイズバッファで OOM を防止

---

## std.Io.Queue(T) の API

### 初期化

```zig
const Message = struct {
    topic: []const u8,
    payload: []const u8,
    qos: u2,
};

// 固定サイズバッファを確保（128 メッセージ分）
var buffer: [128]Message = undefined;

// バッファを渡して Queue を初期化
var queue: std.Io.Queue(Message) = .init(&buffer);
```

`init` に渡すバッファのサイズがキューの最大容量を決定する。
動的メモリ確保は一切行わないため、OOM の心配がない。

### プロデューサー側: putOne

```zig
// メッセージをキューに投入
// キューが満杯の場合、空きができるまでブロック（バックプレッシャー）
try queue.putOne(io, .{
    .topic = topic,
    .payload = payload,
    .qos = qos,
});
```

`putOne` はキューに空きがない場合、コンシューマーが取り出すまで待機する。
これが自動バックプレッシャーの仕組みである。

### コンシューマー側: getOne

```zig
// キューからメッセージを取り出す
// キューが空の場合、メッセージが到着するまでブロック
const message = queue.getOne(io) catch |err| {
    switch (err) {
        error.Canceled => return, // キューがクローズされた
        else => return err,
    }
};
```

`getOne` はキューが空の場合、プロデューサーが投入するまで待機する。
キューがクローズされると `error.Canceled` を返す。

### キャンセル不可能な取り出し: getOneUncancelable

```zig
// シャットダウン時に残りのメッセージをドレインする
while (true) {
    const message = queue.getOneUncancelable(io) orelse break;
    try flushMessage(stream, message);
}
```

`getOneUncancelable` はキャンセルシグナルを無視してメッセージを取り出す。
キューが空の場合は `null` を返す。シャットダウン時のドレイン処理に最適である。

### クローズ

```zig
// キューをクローズする
// getOne でブロック中のタスクに error.Canceled を返す
queue.close(io);
```

---

## MessageQueue 構造体の設計

`Io.Queue(T)` を MQTT ブローカー向けにラップした構造体を定義する。

```zig
const std = @import("std");

pub const OutboundMessage = struct {
    topic_buf: [256]u8,
    topic_len: u16,
    payload_buf: [4096]u8,
    payload_len: u16,
    qos: u2,

    /// トピック文字列を取得
    pub fn topic(self: *const OutboundMessage) []const u8 {
        return self.topic_buf[0..self.topic_len];
    }

    /// ペイロードを取得
    pub fn payload(self: *const OutboundMessage) []const u8 {
        return self.payload_buf[0..self.payload_len];
    }

    /// 値をコピーして OutboundMessage を作成
    pub fn from(topic_src: []const u8, payload_src: []const u8, qos: u2) OutboundMessage {
        var msg: OutboundMessage = undefined;
        msg.qos = qos;

        const t_len: u16 = @intCast(@min(topic_src.len, 256));
        @memcpy(msg.topic_buf[0..t_len], topic_src[0..t_len]);
        msg.topic_len = t_len;

        const p_len: u16 = @intCast(@min(payload_src.len, 4096));
        @memcpy(msg.payload_buf[0..p_len], payload_src[0..p_len]);
        msg.payload_len = p_len;

        return msg;
    }
};

pub const MessageQueue = struct {
    buffer: [64]OutboundMessage,
    queue: std.Io.Queue(OutboundMessage),

    pub fn init(self: *MessageQueue) void {
        self.buffer = undefined;
        self.queue = .init(&self.buffer);
    }

    /// メッセージを投入（キュー満杯時はバックプレッシャー）
    pub fn enqueue(self: *MessageQueue, io: anytype, msg: OutboundMessage) !void {
        try self.queue.putOne(io, msg);
    }

    /// メッセージを取り出す（キュー空時はブロック）
    pub fn dequeue(self: *MessageQueue, io: anytype) !OutboundMessage {
        return try self.queue.getOne(io);
    }

    /// 残りメッセージをドレイン（シャットダウン用）
    pub fn drainRemaining(self: *MessageQueue, io: anytype) ?OutboundMessage {
        return self.queue.getOneUncancelable(io);
    }

    /// キューをクローズ
    pub fn close(self: *MessageQueue, io: anytype) void {
        self.queue.close(io);
    }
};
```

### 設計の特徴

- **固定サイズバッファ**: `OutboundMessage` はトピック 256 バイト、ペイロード 4096 バイトの
  固定サイズ構造体。動的メモリ確保を完全に排除している
- **値コピー**: `from()` でデータをコピーするため、元の PUBLISH パケットのライフタイムに依存しない
- **64 メッセージバッファ**: 1クライアントあたり最大64メッセージをバッファリング

---

## ConnectionHandler への統合

各クライアント接続に MessageQueue を持たせ、リーダーとライターを分離する。

```zig
const net = std.Io.net;

const ClientConnection = struct {
    stream: net.Stream,
    client_id: [64]u8,
    client_id_len: u8,
    message_queue: MessageQueue,

    /// リーダータスク: クライアントからパケットを受信して処理
    pub fn readerTask(self: *ClientConnection, broker: *Broker, io: anytype) void {
        var read_buf: [4096]u8 = undefined;
        var reader = self.stream.reader(io, &read_buf);

        while (true) {
            var byte_buf: [1]u8 = undefined;
            reader.interface.readSliceAll(&byte_buf) catch break;
            const first_byte = byte_buf[0];
            const packet_type: u4 = @intCast(first_byte >> 4);
            switch (packet_type) {
                3 => broker.routePublish(self, first_byte, io) catch break,
                14 => break, // DISCONNECT
                else => break,
            }
        }
        // リーダー終了 → キューをクローズしてライターも停止させる
        self.message_queue.close(io);
    }

    /// ライタータスク: キューからメッセージを取り出して TCP 送信
    pub fn writerTask(self: *ClientConnection, io: anytype) void {
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);

        while (true) {
            const msg = self.message_queue.dequeue(io) catch |err| {
                switch (err) {
                    error.Canceled => break, // キューがクローズされた
                    else => break,
                }
            };
            writer.interface.writeAll(msg.topic()) catch break;
            writer.interface.writeAll(msg.payload()) catch break;
            writer.interface.flush() catch break;
        }
    }
};

const Broker = struct {
    pub fn routePublish(_: *Broker, _: *ClientConnection, _: u8, _: anytype) !void {}
};
```

---

## PUBLISH ルーティングの全体フロー

```zig
fn routePublish(self: *Broker, packet: PublishPacket, io: anytype) !void {
    // サブスクライバー検索
    var buf: [128]*ClientConnection = undefined;
    const count = self.findSubscribers(packet.topic, &buf);

    // 各サブスクライバーのキューにメッセージを投入
    const msg = OutboundMessage.from(packet.topic, packet.payload, packet.qos);
    for (buf[0..count]) |sub| {
        sub.message_queue.enqueue(io, msg) catch {
            // スロークライアント対策: キューが満杯なら切断
            sub.message_queue.close(io);
        };
    }
}
```

### バックプレッシャーの動作

```
正常時:    パブリッシャー → putOne() → [Queue: ■■■□□□□□] → getOne() → TCP
           即座に返る

満杯時:    パブリッシャー → putOne() → [Queue: ■■■■■■■■] → getOne() → TCP (遅い)
           ブロック!        キュー満杯

`putOne` がブロック → パブリッシャーの速度が自動抑制される
```

実運用ではキュー投入にタイムアウトを設け、超過したら切断する戦略も有効である。

---

## Cancelable エラーについて

`Io.Queue` の `getOne` と `putOne` は、キューがクローズされると
`error.Canceled` を返す。これは Zig 0.16 の Io 系 API に共通するパターンである。

```zig
const msg = queue.getOne(io) catch |err| {
    switch (err) {
        error.Canceled => {
            // キューがクローズされた（正常なシャットダウン）
            std.log.info("キューがクローズされました", .{});
            return;
        },
        else => {
            // その他のエラー（I/O エラーなど）
            std.log.err("予期しないエラー: {}", .{err});
            return err;
        },
    }
};
```

`getOneUncancelable` はキャンセルシグナルを無視するため、
シャットダウン時の最終ドレインに使用する。

---

## まとめ

- 直接送信モデルではデータ混在・ロック競合・スロークライアント問題が発生する
- `std.Io.Queue(T)` は固定サイズバッファによるプロデューサー・コンシューマーキューを提供する
- `putOne` / `getOne` はバックプレッシャーを自動的に実現する
- `close` によりブロック中の `getOne` に `error.Canceled` を通知できる
- `getOneUncancelable` はシャットダウン時のドレイン処理に使用する
- 1クライアント = 1リーダータスク + 1ライタータスク + 1キューの構成が安全かつ効率的

次章では、`std.atomic.Value` と `std.Io.Event` を使ったグレースフルシャットダウンの実装を学ぶ。
