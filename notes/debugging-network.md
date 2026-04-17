# ネットワークデバッグガイド

MQTT Broker / クライアントの開発中に役立つデバッグ手法をまとめます。

> **対象**: Zig 0.16 (`std.Io` API)

---

## 1. std.debug.print によるヘックスダンプ

Zig の `std.debug.print` を使って、送受信バイト列を16進数で表示します。

### 基本的なヘックスダンプ関数

```zig
const std = @import("std");

/// バイト列を16進数でダンプする
pub fn hexDump(label: []const u8, data: []const u8) void {
    std.debug.print("=== {s} ({d} bytes) ===\n", .{ label, data.len });

    var offset: usize = 0;
    while (offset < data.len) {
        // オフセット表示
        std.debug.print("{x:0>4}: ", .{offset});

        // 16進数表示
        const end = @min(offset + 16, data.len);
        for (offset..end) |i| {
            std.debug.print("{x:0>2} ", .{data[i]});
        }
        // 16バイトに満たない場合のパディング
        for (0..(16 - (end - offset))) |_| {
            std.debug.print("   ", .{});
        }

        // ASCII 表示
        std.debug.print(" |", .{});
        for (offset..end) |i| {
            const c = data[i];
            if (c >= 0x20 and c <= 0x7E) {
                std.debug.print("{c}", .{c});
            } else {
                std.debug.print(".", .{});
            }
        }
        std.debug.print("|\n", .{});

        offset = end;
    }
    std.debug.print("\n", .{});
}
```

### 使い方

```zig
// Zig 0.16: reader/writer は .interface フィールドでアクセス
const reader = stream.reader.interface;
const writer = stream.writer.interface;

// 受信データのダンプ
const bytes_read = try reader.read(&buf);
hexDump("受信データ", buf[0..bytes_read]);

// 送信データのダンプ
hexDump("送信データ", packet_bytes);
try writer.writeAll(packet_bytes);
```

### 出力例

```
=== 受信データ (14 bytes) ===
0000: 10 0c 00 04 4d 51 54 54 04 02 00 3c 00 00  |....MQTT...<..|
```

---

## 2. MQTT パケットのプリティプリント

パケットタイプを判別して、人間が読みやすい形式で表示する関数です。

### パケットタイプの表示

```zig
/// MQTT パケットタイプ名を返す
fn packetTypeName(first_byte: u8) []const u8 {
    const packet_type = first_byte >> 4;
    return switch (packet_type) {
        1 => "CONNECT",
        2 => "CONNACK",
        3 => "PUBLISH",
        4 => "PUBACK",
        5 => "PUBREC",
        6 => "PUBREL",
        7 => "PUBCOMP",
        8 => "SUBSCRIBE",
        9 => "SUBACK",
        10 => "UNSUBSCRIBE",
        11 => "UNSUBACK",
        12 => "PINGREQ",
        13 => "PINGRESP",
        14 => "DISCONNECT",
        else => "UNKNOWN",
    };
}

/// MQTT パケットの概要を表示する
pub fn printPacketSummary(data: []const u8) void {
    if (data.len < 2) {
        std.debug.print("[MQTT] データが短すぎます ({d} bytes)\n", .{data.len});
        return;
    }

    const first_byte = data[0];
    const packet_type = first_byte >> 4;
    const flags = first_byte & 0x0F;

    std.debug.print("[MQTT] {s}", .{packetTypeName(first_byte)});

    // PUBLISH の場合、フラグを詳細表示
    if (packet_type == 3) {
        const dup = (flags >> 3) & 1;
        const qos = (flags >> 1) & 3;
        const retain = flags & 1;
        std.debug.print(" (DUP={d}, QoS={d}, RETAIN={d})", .{ dup, qos, retain });
    }

    std.debug.print(" | flags=0b{b:0>4} | total={d} bytes\n", .{ flags, data.len });
}
```

### CONNECT パケットの詳細表示

```zig
/// CONNECT パケットの内容を詳細表示する
pub fn printConnect(data: []const u8) void {
    if (data.len < 14) return;

    // 固定ヘッダーをスキップ（最低2バイト）
    var pos: usize = 2;

    // Protocol Name
    const proto_len = (@as(u16, data[pos]) << 8) | data[pos + 1];
    pos += 2;
    const proto_name = data[pos .. pos + proto_len];
    pos += proto_len;

    // Protocol Level
    const proto_level = data[pos];
    pos += 1;

    // Connect Flags
    const connect_flags = data[pos];
    pos += 1;

    // Keep Alive
    const keep_alive = (@as(u16, data[pos]) << 8) | data[pos + 1];
    pos += 2;

    // Client ID
    const client_id_len = (@as(u16, data[pos]) << 8) | data[pos + 1];
    pos += 2;
    const client_id = data[pos .. pos + client_id_len];

    std.debug.print(
        \\[CONNECT 詳細]
        \\  Protocol: {s} (level={d})
        \\  Flags: 0b{b:0>8}
        \\    Clean Session: {d}
        \\    Will Flag:     {d}
        \\    Will QoS:      {d}
        \\    Will Retain:   {d}
        \\    Username:      {d}
        \\    Password:      {d}
        \\  Keep Alive: {d}s
        \\  Client ID: "{s}"
        \\
    , .{
        proto_name,
        proto_level,
        connect_flags,
        (connect_flags >> 1) & 1,
        (connect_flags >> 2) & 1,
        (connect_flags >> 3) & 3,
        (connect_flags >> 5) & 1,
        (connect_flags >> 7) & 1,
        (connect_flags >> 6) & 1,
        keep_alive,
        client_id,
    });
}
```

---

## 3. netcat (nc) を使ったテスト

`netcat` は TCP 接続のテストに非常に便利なコマンドラインツールです。

### Broker の接続テスト

```bash
# Broker がポート 1883 でリッスンしているか確認
nc -zv localhost 1883
```

### 手動で MQTT CONNECT を送信

```bash
# CONNECT パケットをバイナリで送信
# (Client ID が空の最小 CONNECT パケット)
printf '\x10\x0c\x00\x04MQTT\x04\x02\x00\x3c\x00\x00' | nc localhost 1883 | xxd
```

各バイトの内訳:
```
\x10       — 固定ヘッダー (CONNECT, flags=0)
\x0c       — Remaining Length (12)
\x00\x04   — Protocol Name の長さ (4)
MQTT       — Protocol Name
\x04       — Protocol Level (v3.1.1)
\x02       — Connect Flags (Clean Session=1)
\x00\x3c   — Keep Alive (60秒)
\x00\x00   — Client ID の長さ (0 = 空)
```

### 期待される CONNACK 応答

```
\x20\x02\x00\x00
```
- `\x20` — CONNACK パケットタイプ
- `\x02` — Remaining Length (2)
- `\x00` — Session Present = 0
- `\x00` — Return Code = 0 (接続受理)

### TCP リスナーのモック

```bash
# ポート 1883 でリッスンし、受信データを16進数で表示
nc -l 1883 | xxd
```

これにより、クライアントが送信するバイト列を確認できます。

### 便利なワンライナー

```bash
# PINGREQ を送信して PINGRESP を確認
printf '\xc0\x00' | nc localhost 1883 | xxd

# DISCONNECT を送信
printf '\xe0\x00' | nc localhost 1883
```

---

## 4. Wireshark による MQTT パケット解析（オプション）

Wireshark は強力なパケットキャプチャツールで、MQTT のビルトインディセクタを備えています。

### インストール

```bash
# macOS
brew install --cask wireshark

# Ubuntu/Debian
sudo apt install wireshark
```

### MQTT パケットのキャプチャ手順

1. Wireshark を起動
2. ループバックインターフェース（`lo0` / `lo`）を選択してキャプチャ開始
3. 表示フィルタに `mqtt` と入力
4. Broker とクライアントを起動して通信を行う
5. パケットリストから MQTT パケットをクリックして詳細を確認

### 表示フィルタの例

| フィルタ | 用途 |
|----------|------|
| `mqtt` | すべての MQTT パケット |
| `mqtt.msgtype == 1` | CONNECT のみ |
| `mqtt.msgtype == 3` | PUBLISH のみ |
| `mqtt.topic contains "sensor"` | トピックに "sensor" を含むもの |
| `mqtt.qos == 1` | QoS 1 のパケットのみ |
| `tcp.port == 1883` | ポート 1883 の TCP トラフィック |

### Wireshark を使うメリット

- バイト列を自動的に MQTT パケットとして解釈・表示
- パケットの各フィールドをツリー形式で確認可能
- 通信フローをシーケンス図として可視化（統計 → フロー）
- 異常なパケットの検出に便利

---

## 5. Zig 0.16 ネットワークコードの典型パターン

### 基本的な TCP サーバー (std.Io)

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io();
    const address = std.Io.net.IpAddress.parse(io, "127.0.0.1", 1883);

    var server = try std.Io.net.StreamServer.init(.{
        .reuse_address = true,
    });
    defer server.deinit();

    try server.listen(address, io);

    while (true) {
        const connection = try server.accept(io);
        const reader = connection.stream.reader.interface;
        const writer = connection.stream.writer.interface;

        var buf: [1024]u8 = undefined;
        const n = try reader.read(&buf);
        hexDump("受信", buf[0..n]);
        try writer.writeAll(buf[0..n]);
    }
}
```

### Mutex による排他制御

```zig
var mutex = std.Io.Mutex{};

// ロック取得（キャンセル不可）
mutex.lockUncancelable(io);
defer mutex.unlock(io);

// クリティカルセクション
shared_data.update();
```

### Sleep によるタイミング制御

```zig
// 100ミリ秒待機
std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io);
```

---

## 6. デバッグのベストプラクティス

### 段階的テスト

1. **固定ヘッダーのみ** — PINGREQ / PINGRESP でまず接続を確認
2. **CONNECT / CONNACK** — 最小の CONNECT パケットから始める
3. **PUBLISH (QoS 0)** — 確認応答なしの最もシンプルなフロー
4. **SUBSCRIBE / SUBACK** — 購読フローを追加
5. **QoS 1** — PUBACK を追加
6. **複数クライアント** — 同時接続をテスト

### よくある問題と対処法

| 症状 | 原因の可能性 | 対処法 |
|------|------------|--------|
| 接続が即座に切れる | パケットフォーマット不正 | hexDump で送信バイトを確認 |
| CONNACK が返らない | Remaining Length の計算ミス | 可変長エンコーディングを再確認 |
| 文字化け | バイトオーダーの間違い | Big Endian で送信しているか確認 |
| Broker がハングする | 読み取りがブロックしている | Remaining Length 分だけ読む |
| Client ID 拒否 | 空の Client ID + Clean Session = 0 | Clean Session を 1 にするか Client ID を指定 |
| `.reader()` でコンパイルエラー | Zig 0.16 API の変更 | `.reader.interface` フィールドを使用する |

### ログレベルの制御

開発中はログを有効にし、完成後は無効にする簡単な仕組み:

```zig
const DEBUG = true;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG) {
        std.debug.print("[DEBUG] " ++ fmt ++ "\n", args);
    }
}
```

---

> **ヒント**: デバッグ用コードは本番ビルドで `if (DEBUG)` や `comptime` 分岐を使って除外できます。Zig のコンパイル時評価を活用しましょう。
