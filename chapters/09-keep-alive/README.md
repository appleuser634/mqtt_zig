# 第9章: キープアライブ

## 学習目標

- MQTT のキープアライブの目的と仕組みを理解する
- PINGREQ / PINGRESP パケットの構造を把握する
- サーバー側のタイムアウト検出（1.5倍ルール）を実装できる
- クライアント側の PINGREQ 送信タイミングを設計できる
- Zig 0.16 の `std.Io.Clock.Duration.sleep` API を活用できる

---

## キープアライブとは

TCP 接続は、データの送受信がなくても維持される。しかし、ネットワーク障害やクライアントの異常終了を検知するには、定期的な死活確認が必要になる。

MQTT では CONNECT パケット内の `keep_alive` フィールド（秒単位、u16）でこの間隔を指定する。

```
keep_alive = 60 の場合:
- クライアントは 60秒以内に何らかのパケットを送信する義務がある
- サーバーは 90秒（1.5倍）以内にパケットを受信しなければ切断する
```

`keep_alive = 0` の場合、キープアライブは無効となる。

---

## PINGREQ と PINGRESP

データを送信する必要がないときでも接続を維持するため、専用の軽量パケットが用意されている。

### PINGREQ（クライアント -> サーバー）

```
バイト1: 0xC0 (パケットタイプ=12, フラグ=0)
バイト2: 0x00 (残りの長さ=0)
```

### PINGRESP（サーバー -> クライアント）

```
バイト1: 0xD0 (パケットタイプ=13, フラグ=0)
バイト2: 0x00 (残りの長さ=0)
```

どちらも2バイトの固定長であり、ペイロードは持たない。

```zig
const PINGREQ_PACKET = [_]u8{ 0xC0, 0x00 };
const PINGRESP_PACKET = [_]u8{ 0xD0, 0x00 };
```

---

## サーバー側の実装

### タイムアウト検出

MQTT 仕様（3.1.2.10）では、サーバーはキープアライブ値の1.5倍の時間内にクライアントからパケットを受信しなければ、接続を切断しなければならないと定められている。

```zig
const Connection = struct {
    keep_alive_s: u16,
    last_packet_received: i64,
    // ...

    /// キープアライブのデッドラインを計算する（ナノ秒）
    fn keepAliveDeadlineNs(self: *const Connection) ?i64 {
        if (self.keep_alive_s == 0) return null; // 無効

        const timeout_ns: i64 = @as(i64, self.keep_alive_s) * std.time.ns_per_s * 3 / 2;
        return self.last_packet_received + timeout_ns;
    }

    /// パケット受信時に呼び出す
    fn updateLastReceived(self: *Connection) void {
        self.last_packet_received = std.time.nanoTimestamp();
    }

    /// タイムアウトしているかチェック
    fn isKeepAliveExpired(self: *const Connection) bool {
        const deadline = self.keepAliveDeadlineNs() orelse return false;
        return std.time.nanoTimestamp() > deadline;
    }
};
```

### PINGREQ の処理

サーバーが PINGREQ を受信したら、即座に PINGRESP を返す。Zig 0.16 では writer に `io` パラメータが必要である。

```zig
fn handlePingreq(self: *Connection, io: *std.Io) !void {
    self.updateLastReceived();

    var write_buf: [4096]u8 = undefined;
    var writer = self.stream.writer(io, &write_buf);
    try writer.interface.writeAll(&PINGRESP_PACKET);
    try writer.interface.flush();
}
```

### 接続ループへの統合

メインの読み取りループでは、定期的にキープアライブのタイムアウトをチェックする。

```zig
fn connectionLoop(self: *Connection, io: *std.Io) !void {
    var read_buf: [4096]u8 = undefined;
    var reader = self.stream.reader(io, &read_buf);

    while (true) {
        // キープアライブチェック
        if (self.isKeepAliveExpired()) {
            std.log.info("キープアライブタイムアウト: {s}", .{self.client_id});
            return; // 接続を閉じる
        }

        // ソケットからデータを読む
        var header_buf: [1]u8 = undefined;
        reader.interface.readSliceAll(&header_buf) catch |err| {
            if (err == error.EndOfStream) return;
            return err;
        };

        self.updateLastReceived();
        const packet_type: u4 = @intCast(header_buf[0] >> 4);

        switch (packet_type) {
            3 => try self.handlePublish(io, header_buf[0]),
            8 => try self.handleSubscribe(io),
            12 => try self.handlePingreq(io),
            14 => return, // DISCONNECT
            else => return error.UnsupportedPacketType,
        }
    }
}
```

---

## Zig 0.16 のスリープ API

Zig 0.16 では、スリープは `std.Io.Clock.Duration.sleep` を使用する。
これは Io ランタイムと統合されたスリープであり、`io` パラメータが必要になる。

### 基本的なスリープ

```zig
// 1秒スリープ
std.Io.Clock.Duration.sleep(.{
    .clock = .awake,
    .raw = .fromMilliseconds(1000),
}, io);

// 500ミリ秒スリープ
std.Io.Clock.Duration.sleep(.{
    .clock = .awake,
    .raw = .fromMilliseconds(500),
}, io);
```

### clock の種類

| clock | 説明 |
|-------|------|
| `.awake` | システムがスリープ中はカウントしない。一般用途に適する |
| `.boot` | システムのブート時刻からの経過。スリープ中もカウントする |

キープアライブのタイマーには `.awake` が適切である。

### タイムスタンプの取得

```zig
// 壁時計時間（エポックからのナノ秒）
const wall_ns = std.time.nanoTimestamp();

// ミリ秒単位の壁時計時間
const wall_ms = std.time.milliTimestamp();
```

---

## クライアント側の実装

クライアントは、`keep_alive` 期間内にパケットを送信しなかった場合、PINGREQ を送る。一般的には `keep_alive` の半分から3分の2の間隔で送信する。

```zig
const Client = struct {
    keep_alive_s: u16,
    last_packet_sent: i64,
    stream: anytype,

    /// 必要なら PINGREQ を送信する
    fn maybeSendPing(self: *Client, io: *std.Io) !void {
        if (self.keep_alive_s == 0) return;

        const now = std.time.nanoTimestamp();
        const interval_ns: i64 = @as(i64, self.keep_alive_s) * std.time.ns_per_s * 2 / 3;

        if (now - self.last_packet_sent > interval_ns) {
            var write_buf: [4096]u8 = undefined;
            var writer = self.stream.writer(io, &write_buf);
            try writer.interface.writeAll(&PINGREQ_PACKET);
            try writer.interface.flush();
            self.last_packet_sent = now;
        }
    }

    /// 任意のパケット送信時に呼ぶ
    fn markSent(self: *Client) void {
        self.last_packet_sent = std.time.nanoTimestamp();
    }
};
```

### PINGREQ 定期送信ループ

クライアント側では別のタスクとして PING 送信ループを回すことが一般的である。
Zig 0.16 の sleep API を使った実装例:

```zig
fn pingLoop(client: *Client, io: *std.Io, should_stop: *std.atomic.Value(bool)) void {
    while (!should_stop.load(.acquire)) {
        // keep_alive の半分の間隔でチェック
        const interval_ms: u64 = @as(u64, client.keep_alive_s) * 500;
        std.Io.Clock.Duration.sleep(.{
            .clock = .awake,
            .raw = .fromMilliseconds(interval_ms),
        }, io);

        client.maybeSendPing(io) catch |err| {
            std.log.err("PING 送信エラー: {}", .{err});
            return;
        };
    }
}
```

### PINGRESP の受信確認

クライアントは PINGREQ を送信した後、合理的な時間内に PINGRESP を受信することを期待する。
受信できなかった場合、接続が失われたと判断してよい。

```zig
fn handlePingresp(self: *Client) void {
    // PINGRESP を正常に受信
    self.last_pingresp_received = std.time.nanoTimestamp();
    std.log.debug("PINGRESP 受信", .{});
}

fn isPingrespOverdue(self: *const Client) bool {
    if (self.last_pingreq_sent == 0) return false;
    const elapsed = std.time.nanoTimestamp() - self.last_pingreq_sent;
    // PINGREQ 送信後5秒以内に PINGRESP がなければ異常とみなす
    return elapsed > 5 * std.time.ns_per_s;
}
```

---

## タイムアウト検出のパターン

Zig 0.16 では、タイムアウト検出に `std.atomic.Value(bool)` と sleep を組み合わせるパターンが有効である。

```zig
fn keepAliveMonitor(
    conn: *Connection,
    io: *std.Io,
    should_stop: *std.atomic.Value(bool),
) void {
    while (!should_stop.load(.acquire)) {
        std.Io.Clock.Duration.sleep(.{
            .clock = .awake,
            .raw = .fromMilliseconds(1000),
        }, io);

        if (conn.isKeepAliveExpired()) {
            std.log.info("キープアライブ超過を検出: {s}", .{conn.client_id});
            conn.forceClose();
            return;
        }
    }
}
```

---

## タイムアウト値の設計指針

| 用途 | 推奨 keep_alive | 理由 |
|------|----------------|------|
| モバイルアプリ | 30-60秒 | バッテリー消費とのバランス |
| サーバー間通信 | 10-30秒 | 素早い障害検知 |
| センサーデバイス | 60-300秒 | 低電力・低帯域 |
| LAN 内通信 | 10-20秒 | 高速な障害検知が可能 |

---

## エッジケース

### keep_alive = 0

キープアライブが無効の場合、サーバーはタイムアウト切断を行わない。TCP 自体のタイムアウトに依存する。

### パケット送受信がキープアライブを兼ねる

PUBLISH や SUBSCRIBE など、通常のパケット送受信もキープアライブのカウンタをリセットする。PINGREQ は他にパケットを送信する必要がないときだけ使えばよい。

### ネットワーク遅延の考慮

1.5倍ルールは、ネットワーク遅延を考慮したマージンである。クライアントが期限ぎりぎりに送信しても、ネットワーク遅延で到着が遅れる可能性がある。サーバー側では十分な余裕を持つべきである。

### 半開き接続の検出

TCP の半開き接続（一方が切断を認識していない状態）は、キープアライブなしでは検出できない。キープアライブを有効にすることで、このような異常を確実に検出できる。

---

## まとめ

- キープアライブは TCP 接続の死活監視を行う MQTT の重要な仕組みである
- PINGREQ/PINGRESP は2バイトの軽量パケットで、オーバーヘッドは最小限
- サーバーは `keep_alive * 1.5` のタイムアウトで切断判定を行う
- Zig 0.16 では `std.Io.Clock.Duration.sleep` で Io ランタイム統合のスリープを行う
- `std.atomic.Value(bool)` と sleep の組み合わせでタイムアウト監視ループを実装する

次章では、ブローカー全体のアーキテクチャ設計を学ぶ。
