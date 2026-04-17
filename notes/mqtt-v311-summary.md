# MQTT v3.1.1 仕様サマリー

OASIS 標準 MQTT v3.1.1 の要点を凝縮したリファレンスです。
正式仕様: <https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html>

---

## 固定ヘッダー

すべての MQTT パケットは固定ヘッダーで始まります。

```
ビット    7  6  5  4    3     2  1    0
Byte 1: [パケットタイプ] [フラグ]
Byte 2+: [Remaining Length (可変長エンコーディング, 1〜4 バイト)]
```

### Remaining Length エンコーディング

各バイトの下位 7 ビットがデータ、最上位ビットが「続きがあるか」のフラグ。

| バイト数 | 最大値 |
|----------|--------|
| 1 | 127 |
| 2 | 16,383 |
| 3 | 2,097,151 |
| 4 | 268,435,455 (約256 MB) |

---

## 全14パケットタイプ

| 値 | パケット名 | 方向 | 固定ヘッダーフラグ (bit 3-0) | 説明 |
|----|-----------|------|------------------------------|------|
| 1 | CONNECT | C → S | `0000` (Reserved) | 接続要求 |
| 2 | CONNACK | S → C | `0000` (Reserved) | 接続応答 |
| 3 | PUBLISH | 双方向 | `DUP QoS QoS RETAIN` | メッセージ発行 |
| 4 | PUBACK | 双方向 | `0000` (Reserved) | QoS 1 確認応答 |
| 5 | PUBREC | 双方向 | `0000` (Reserved) | QoS 2 受信確認 |
| 6 | PUBREL | 双方向 | `0010` (Reserved) | QoS 2 リリース |
| 7 | PUBCOMP | 双方向 | `0000` (Reserved) | QoS 2 完了 |
| 8 | SUBSCRIBE | C → S | `0010` (Reserved) | 購読要求 |
| 9 | SUBACK | S → C | `0000` (Reserved) | 購読応答 |
| 10 | UNSUBSCRIBE | C → S | `0010` (Reserved) | 購読解除要求 |
| 11 | UNSUBACK | S → C | `0000` (Reserved) | 購読解除応答 |
| 12 | PINGREQ | C → S | `0000` (Reserved) | 生存確認要求 |
| 13 | PINGRESP | S → C | `0000` (Reserved) | 生存確認応答 |
| 14 | DISCONNECT | C → S | `0000` (Reserved) | 切断通知 |

> **C → S**: クライアントからサーバー、**S → C**: サーバーからクライアント

---

## 各パケットの詳細

### 1. CONNECT

**可変ヘッダー:**
| フィールド | サイズ | 説明 |
|-----------|--------|------|
| Protocol Name | 2 + 4 bytes | 長さ(2) + `MQTT`(4) |
| Protocol Level | 1 byte | `0x04` (v3.1.1) |
| Connect Flags | 1 byte | 下記参照 |
| Keep Alive | 2 bytes | 秒単位 |

**Connect Flags (ビットフィールド):**
```
bit 7: Username Flag
bit 6: Password Flag
bit 5: Will Retain
bit 4-3: Will QoS
bit 2: Will Flag
bit 1: Clean Session
bit 0: Reserved (0)
```

**ペイロード (順序固定):**
1. Client Identifier (必須)
2. Will Topic (Will Flag = 1 の場合)
3. Will Message (Will Flag = 1 の場合)
4. Username (Username Flag = 1 の場合)
5. Password (Password Flag = 1 の場合)

### 2. CONNACK

**可変ヘッダー:**
| フィールド | サイズ | 説明 |
|-----------|--------|------|
| Session Present | 1 byte | bit 0 のみ使用 |
| Return Code | 1 byte | 下記参照 |

**ペイロード:** なし

**CONNACK リターンコード:**
| 値 | 意味 |
|----|------|
| 0 | 接続受理 |
| 1 | 不正なプロトコルバージョン |
| 2 | クライアント識別子拒否 |
| 3 | サーバー利用不可 |
| 4 | 不正なユーザー名またはパスワード |
| 5 | 認証失敗 |

### 3. PUBLISH

**可変ヘッダー:**
| フィールド | サイズ | 説明 |
|-----------|--------|------|
| Topic Name | 2 + N bytes | UTF-8 エンコード文字列 |
| Packet Identifier | 2 bytes | QoS 1 または 2 の場合のみ |

**ペイロード:** 任意のバイト列（アプリケーションデータ）

**固定ヘッダーフラグ:**
- **DUP** (bit 3): 再送フラグ。QoS 0 では常に 0。
- **QoS** (bit 2-1): `00` = QoS 0, `01` = QoS 1, `10` = QoS 2
- **RETAIN** (bit 0): 保持フラグ

### 4. PUBACK

**可変ヘッダー:** Packet Identifier (2 bytes)
**ペイロード:** なし

### 5. PUBREC / 6. PUBREL / 7. PUBCOMP

**可変ヘッダー:** Packet Identifier (2 bytes)
**ペイロード:** なし

### 8. SUBSCRIBE

**可変ヘッダー:** Packet Identifier (2 bytes)

**ペイロード (1つ以上):**
| フィールド | サイズ | 説明 |
|-----------|--------|------|
| Topic Filter | 2 + N bytes | UTF-8 エンコードトピックフィルタ |
| Requested QoS | 1 byte | 0, 1, または 2 |

### 9. SUBACK

**可変ヘッダー:** Packet Identifier (2 bytes)

**ペイロード:** 各トピックフィルタに対するリターンコード (1 byte ずつ)

| 値 | 意味 |
|----|------|
| 0x00 | QoS 0 で許可 |
| 0x01 | QoS 1 で許可 |
| 0x02 | QoS 2 で許可 |
| 0x80 | 購読失敗 |

### 10. UNSUBSCRIBE

**可変ヘッダー:** Packet Identifier (2 bytes)
**ペイロード:** 1つ以上の Topic Filter (2 + N bytes ずつ)

### 11. UNSUBACK

**可変ヘッダー:** Packet Identifier (2 bytes)
**ペイロード:** なし

### 12. PINGREQ / 13. PINGRESP

**可変ヘッダー:** なし
**ペイロード:** なし

固定ヘッダーのみ（各 2 バイト）:
- PINGREQ: `0xC0 0x00`
- PINGRESP: `0xD0 0x00`

### 14. DISCONNECT

**可変ヘッダー:** なし
**ペイロード:** なし

固定ヘッダーのみ（2 バイト）: `0xE0 0x00`

---

## QoS メッセージフロー

### QoS 0 — At most once (最大1回)

```
Publisher          Broker          Subscriber
    |                |                |
    |--- PUBLISH --->|                |
    |   (QoS 0)      |--- PUBLISH -->|
    |                |   (QoS 0)      |
```

確認応答なし。送りっぱなし。

### QoS 1 — At least once (少なくとも1回)

```
Publisher          Broker          Subscriber
    |                |                |
    |--- PUBLISH --->|                |
    |   (QoS 1)      |--- PUBLISH -->|
    |                |   (QoS 1)      |
    |<-- PUBACK -----|                |
    |                |<-- PUBACK ----|
```

PUBACK を受信するまで再送する可能性がある。

### QoS 2 — Exactly once (正確に1回)

```
Publisher          Broker
    |                |
    |--- PUBLISH --->|
    |   (QoS 2)      |
    |<-- PUBREC -----|
    |--- PUBREL ---->|
    |<-- PUBCOMP ----|
```

4段階のハンドシェイクにより重複配信を防止する。

---

## トピックワイルドカードルール

### 単一レベルワイルドカード `+`

- トピックフィルタの任意の位置で使用可能
- 1つのトピックレベルに一致する
- 例: `sensor/+/temperature` は `sensor/room1/temperature` に一致、`sensor/room1/sub/temperature` には不一致

### 複数レベルワイルドカード `#`

- トピックフィルタの **末尾にのみ** 使用可能
- 0個以上のトピックレベルに一致する
- 例: `sensor/#` は `sensor`、`sensor/temp`、`sensor/room1/temperature` すべてに一致
- `#` 単独ですべてのトピックに一致

### トピック名の規則

- UTF-8 エンコード文字列
- 最低1文字以上
- `$` で始まるトピック（例: `$SYS/`）は `#` や `+` のワイルドカードに一致しない（システムトピック）
- `/` で始まるトピック名は有効（空のレベルが先頭にある）

---

## UTF-8 エンコード文字列フォーマット

MQTT で使われる文字列はすべて以下の形式です:

```
[長さ上位バイト] [長さ下位バイト] [UTF-8 文字列データ...]
```

- 長さフィールドは 2 バイト (Big Endian)
- 最大長は 65,535 バイト

---

> **参考**: 本サマリーは学習目的の要約です。実装の際は正式仕様を参照してください。
