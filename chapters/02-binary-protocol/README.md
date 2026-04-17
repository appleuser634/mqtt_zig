# Chapter 02: バイナリプロトコルの基礎

## 学習目標

- MQTT 固定ヘッダの構造（パケットタイプ 4bit + フラグ 4bit + 残りの長さ）を理解する
- Remaining Length の可変長エンコーディングアルゴリズムを実装できる
- UTF-8 文字列の MQTT エンコーディング（2バイト長プレフィックス + データ）を理解する
- 本プロジェクトの `codec.zig` のエンコード/デコード関数を読み解く
- Zig のビット操作、スライス操作を活用する

---

## 固定ヘッダ（Fixed Header）

すべての MQTT パケットは**固定ヘッダ**で始まる。最小構成はわずか2バイトである。

```
Byte 1:  [パケットタイプ: 4bit][フラグ: 4bit]
Byte 2+: [Remaining Length: 1〜4バイトの可変長]
```

### 第1バイトの構造

```
Bit:  7  6  5  4  3  2  1  0
      |  Type   |   Flags   |
```

- **ビット 7-4**: パケットタイプ（1〜14）
- **ビット 3-0**: パケット固有のフラグ

### Hex ダンプ例: PINGREQ パケット

PINGREQ（タイプ=12, フラグ=0, 本文なし）は最も単純なパケットである:

```
C0 00
|  +-- Remaining Length = 0（本文なし）
+----- 0xC0 = 1100_0000 -> タイプ=12, フラグ=0
```

---

## codec.zig の固定ヘッダ実装

本プロジェクトでは `src/mqtt/codec.zig` に固定ヘッダのデコード/エンコード関数がある。

### FixedHeader 構造体

```zig
pub const FixedHeader = struct {
    packet_type: PacketType,
    flags: u4,
    remaining_length: u32,
    header_size: usize, // 固定ヘッダ全体のバイト数
};
```

### デコード

```zig
pub fn decodeFixedHeader(data: []const u8) !FixedHeader {
    if (data.len < 2) return CodecError.PacketTooShort;
    const first_byte = data[0];
    const type_val: u4 = @intCast(first_byte >> 4);    // 上位4ビット
    const flags: u4 = @intCast(first_byte & 0x0F);     // 下位4ビット

    const packet_type: PacketType = @enumFromInt(type_val);

    const rl = try decodeRemainingLength(data[1..]);
    return .{
        .packet_type = packet_type,
        .flags = flags,
        .remaining_length = rl.value,
        .header_size = 1 + rl.bytes_consumed,
    };
}
```

ポイント:
- `@intCast(first_byte >> 4)` で上位4ビットを `u4` に変換する
- `@enumFromInt(type_val)` で `u4` を `PacketType` 列挙型に変換する
- `header_size` を保持することで、可変ヘッダ+ペイロードの開始位置がわかる

### エンコード

```zig
pub fn encodeFixedHeader(
    buf: []u8,
    packet_type: PacketType,
    flags: u4,
    remaining_length: u32,
) ![]const u8 {
    if (buf.len < 5) return CodecError.PacketTooShort;
    buf[0] = (@as(u8, @intFromEnum(packet_type)) << 4) | @as(u8, flags);
    const rl = try encodeRemainingLength(buf[1..5], remaining_length);
    return buf[0 .. 1 + rl.len];
}
```

`@intFromEnum` で列挙型を整数に変換し、4ビット左シフトしてフラグと合成する。

---

## Remaining Length（残りの長さ）

固定ヘッダの第2バイト以降は、パケットの残りのバイト数を**可変長**で表す。
1バイトで 0〜127、2バイトで 128〜16383、最大4バイトで約256MBまで表現できる。

### エンコーディングルール

各バイトの**下位7ビット**がデータ、**最上位ビット（ビット7）**が継続フラグである。
継続フラグが 1 の場合、次のバイトも Remaining Length の一部である。

```
バイト値: [継続ビット: 1bit][値: 7bit]

例: 残り長 = 321 (0x141)
  バイト1: 0xC1 = 1_1000001  -> 継続=1, 値=65
  バイト2: 0x02 = 0_0000010  -> 継続=0, 値=2
  復元: 65 + 2 * 128 = 65 + 256 = 321
```

### 範囲一覧

| バイト数 | 最小値 | 最大値      | Hex ダンプ例          |
|---------|--------|------------|----------------------|
| 1       | 0      | 127        | `7F`                 |
| 2       | 128    | 16,383     | `80 01` 〜 `FF 7F`   |
| 3       | 16,384 | 2,097,151  | `80 80 01`           |
| 4       | 2,097,152 | 268,435,455 | `FF FF FF 7F`    |

### codec.zig のエンコード実装

```zig
pub fn encodeRemainingLength(buf: []u8, value: u32) ![]const u8 {
    if (value > types.MAX_REMAINING_LENGTH) return CodecError.InvalidRemainingLength;
    var x = value;
    var i: usize = 0;
    while (true) {
        var encoded_byte: u8 = @intCast(x % 128);
        x /= 128;
        if (x > 0) encoded_byte |= 0x80; // 継続ビットを立てる
        if (i >= buf.len) return CodecError.InvalidRemainingLength;
        buf[i] = encoded_byte;
        i += 1;
        if (x == 0) break;
    }
    return buf[0..i];
}
```

### codec.zig のデコード実装

```zig
pub const RemainingLengthResult = struct {
    value: u32,
    bytes_consumed: usize,
};

pub fn decodeRemainingLength(data: []const u8) !RemainingLengthResult {
    var multiplier: u32 = 1;
    var value: u32 = 0;
    var i: usize = 0;
    while (true) {
        if (i >= data.len) return CodecError.PacketTooShort;
        const encoded_byte = data[i];
        value += @as(u32, encoded_byte & 0x7F) * multiplier;
        if (multiplier > 128 * 128 * 128) return CodecError.InvalidRemainingLength;
        i += 1;
        if (encoded_byte & 0x80 == 0) break; // 継続ビットが0なら終了
        multiplier *= 128;
    }
    return .{ .value = value, .bytes_consumed = i };
}
```

戻り値の `bytes_consumed` により、Remaining Length の直後からペイロードを読める。

---

## UTF-8 文字列エンコーディング

MQTT では文字列を**2バイトのビッグエンディアン長プレフィックス + UTF-8 データ**で表す。

```
[長さ上位バイト][長さ下位バイト][UTF-8 データ...]
```

### Hex ダンプ例: 文字列 "MQTT"

```
00 04 4D 51 54 54
|  |  +------------ "MQTT" の ASCII/UTF-8 バイト列
+--+---------------- 長さ = 4 (ビッグエンディアン u16)
```

### Hex ダンプ例: トピック "sensor/temp"

```
00 0B 73 65 6E 73 6F 72 2F 74 65 6D 70
|  |  +-------------------------------- "sensor/temp" (11バイト)
+--+------------------------------------ 長さ = 11
```

### codec.zig の文字列エンコード

```zig
pub fn encodeString(buf: []u8, str: []const u8) ![]const u8 {
    const total = 2 + str.len;
    if (buf.len < total) return CodecError.PacketTooShort;
    buf[0] = @intCast((str.len >> 8) & 0xFF);  // 長さ上位バイト
    buf[1] = @intCast(str.len & 0xFF);          // 長さ下位バイト
    @memcpy(buf[2..][0..str.len], str);
    return buf[0..total];
}
```

### codec.zig の文字列デコード

```zig
pub const StringResult = struct {
    value: []const u8,
    bytes_consumed: usize,
};

pub fn decodeString(data: []const u8) !StringResult {
    if (data.len < 2) return CodecError.PacketTooShort;
    const len: u16 = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
    if (data.len < 2 + len) return CodecError.PacketTooShort;
    return .{
        .value = data[2..][0..len],
        .bytes_consumed = 2 + len,
    };
}
```

デコード結果は元のバッファへのスライスを返す。
メモリコピーが不要なため高効率であるが、元のバッファが解放されると無効になる点に注意。
永続化が必要な場合は `allocator.dupe(u8, result.value)` でコピーする。

---

## u16 のエンコード/デコード

Packet ID や Keep Alive など、2バイトの整数もビッグエンディアンで表現する。

```zig
pub fn encodeU16(buf: []u8, value: u16) ![]const u8 {
    if (buf.len < 2) return CodecError.PacketTooShort;
    buf[0] = @intCast((value >> 8) & 0xFF);
    buf[1] = @intCast(value & 0xFF);
    return buf[0..2];
}

pub fn decodeU16(data: []const u8) !u16 {
    if (data.len < 2) return CodecError.PacketTooShort;
    return (@as(u16, data[0]) << 8) | @as(u16, data[1]);
}
```

---

## 完全なパケット例: CONNECT

CONNECT パケット全体の hex ダンプ（クライアントID = "zig"）:

```
10 0F                     -- 固定ヘッダ: type=1(CONNECT), RL=15
00 04 4D 51 54 54         -- プロトコル名 "MQTT"
04                        -- プロトコルレベル 4 (v3.1.1)
02                        -- 接続フラグ: Clean Session=1
00 3C                     -- Keep Alive = 60秒
00 03 7A 69 67            -- クライアントID "zig"
```

このバイト列の構造は Chapter 04 で詳しく解説する。

---

## ManagedArrayList によるバイト列の動的構築

本プロジェクトの `codec.zig` では、パケットのエンコードに
`std.array_list.AlignedManaged(T, null)` を使用している。
これは Zig 0.16 で提供されるアロケータ内蔵の動的配列である。

```zig
/// Zig 0.16: managed ArrayList (allocator を保持)
fn ManagedArrayList(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}
```

使用例（CONNECT パケットのエンコード抜粋）:

```zig
pub fn encodeConnect(allocator: Allocator, pkt: *const ConnectPacket) ![]u8 {
    var list = ManagedArrayList(u8).init(allocator);
    errdefer list.deinit();

    // プロトコル名 "MQTT" を書き込み
    try appendString(&list, pkt.protocol_name);
    // プロトコルレベル
    try list.append(pkt.protocol_level);
    // 接続フラグ（packed struct を u8 にキャスト）
    try list.append(@bitCast(pkt.flags));
    // Keep Alive
    try list.append(@intCast((pkt.keep_alive >> 8) & 0xFF));
    try list.append(@intCast(pkt.keep_alive & 0xFF));

    // ... ペイロード追加 ...

    return result.toOwnedSlice();
}
```

`ManagedArrayList(u8)` はバイト列を段階的に構築するのに適している。
`toOwnedSlice()` で所有権を呼び出し元に移転し、不要になったら
`allocator.free(slice)` で解放する。

---

## テスト

codec.zig のテストは Remaining Length と文字列のラウンドトリップを検証する:

```zig
test "remaining length: encode and decode round-trip" {
    var buf: [4]u8 = undefined;

    // 0
    const r0 = try encodeRemainingLength(&buf, 0);
    try std.testing.expectEqualSlices(u8, &.{0x00}, r0);
    const d0 = try decodeRemainingLength(r0);
    try std.testing.expectEqual(@as(u32, 0), d0.value);

    // 127 (1バイト最大値)
    const r127 = try encodeRemainingLength(&buf, 127);
    try std.testing.expectEqualSlices(u8, &.{0x7F}, r127);

    // 128 (2バイト最小値)
    const r128 = try encodeRemainingLength(&buf, 128);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, r128);

    // 268435455 (4バイト最大値)
    const r_max = try encodeRemainingLength(&buf, 268_435_455);
    const d_max = try decodeRemainingLength(r_max);
    try std.testing.expectEqual(@as(u32, 268_435_455), d_max.value);
}

test "string: encode and decode round-trip" {
    var buf: [256]u8 = undefined;
    const encoded = try encodeString(&buf, "hello");
    try std.testing.expectEqual(@as(usize, 7), encoded.len);

    const decoded = try decodeString(encoded);
    try std.testing.expectEqualStrings("hello", decoded.value);
    try std.testing.expectEqual(@as(usize, 7), decoded.bytes_consumed);
}
```

テスト実行は以下のコマンドで行う:

```bash
zig build test
```

---

## エラー処理

codec.zig では専用のエラーセットを定義している:

```zig
pub const CodecError = error{
    InvalidRemainingLength,   // Remaining Length が不正
    InvalidPacketType,        // パケットタイプが不正
    InvalidProtocolName,      // プロトコル名が "MQTT" でない
    InvalidProtocolLevel,     // プロトコルレベルが 4 でない
    InvalidFlags,             // フラグ値が不正
    PacketTooShort,           // データが不足
    MalformedPacket,          // パケット構造が不正
    OutOfMemory,              // メモリ不足
    EndOfStream,              // ストリーム終端
};
```

Zig のエラーユニオン (`!`) により、全てのエンコード/デコード関数は
`CodecError` を明示的に返す。呼び出し元は `try` で伝播するか、
`catch` でハンドリングする。

---

## まとめ

- MQTT の固定ヘッダは**最小2バイト**で構成され、パケットタイプとフラグをビット操作で抽出する
- Remaining Length は**可変長エンコーディング**（継続ビット方式）で最大4バイト
- 文字列は**2バイト長プレフィックス + UTF-8 データ**で表現する
- 本プロジェクトの `codec.zig` はバッファベースの API でエンコード/デコードを行い、`ManagedArrayList` で動的なバイト列構築を実現している
- `@intCast`、`@bitCast`、`@enumFromInt` などの Zig のビルトイン関数がプロトコル実装に適している

次のチャプターでは、Zig 0.16 で TCP 接続を確立し、これらのバイト列を実際に送受信する方法を学ぶ。
