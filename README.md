# MQTT Zig チュートリアル — Zigで学ぶMQTTプロトコル

MQTT v3.1.1 の Broker / Publisher / Subscriber を純粋な Zig で実装しながら、ネットワークプログラミングとバイナリプロトコルの基礎を学ぶ教育プロジェクトです。外部ライブラリは一切使用せず、Zig の標準ライブラリのみで構築します。

---

## クイックスタート

> **必須**: Zig 0.16 が必要です。0.16 では `std.Io` ベースの新しい I/O フレームワークが導入されており、本プロジェクトはこの API を前提としています。

```bash
# Broker を起動（ポート 1883）
zig build broker
./zig-out/bin/mqtt-broker

# 別ターミナルで Subscriber を起動
zig build sub
./zig-out/bin/mqtt-sub

# さらに別ターミナルで Publisher を起動
zig build pub
./zig-out/bin/mqtt-pub

# テストの実行
zig build test
```

---

## 学習パス

本チュートリアルは 6 部構成・全 18 章で、段階的に MQTT Broker を構築していきます。

### Part I — 基礎

プロトコルの概要と、Zig によるバイナリ処理・TCP 通信の基礎を学びます。

| 章 | タイトル | 学ぶこと |
|----|---------|---------|
| [01](chapters/01-mqtt-overview/) | MQTT 概要 | MQTT の歴史、用途、Pub/Sub モデル |
| [02](chapters/02-binary-protocol/) | バイナリプロトコル | 固定ヘッダー、Remaining Length、パケット構造 |
| [03](chapters/03-tcp-basics/) | TCP の基礎 | Zig の `std.Io.net`、ソケット、Stream の読み書き |

### Part II — コアパケット

MQTT 通信の中核となるパケットを実装します。

| 章 | タイトル | 学ぶこと |
|----|---------|---------|
| [04](chapters/04-connect-connack/) | CONNECT / CONNACK | 接続ハンドシェイク、バリデーション |
| [05](chapters/05-publish-flow/) | PUBLISH フロー | メッセージ発行、QoS 0 の実装 |
| [06](chapters/06-subscribe-unsubscribe/) | SUBSCRIBE / UNSUBSCRIBE | トピック購読と購読解除 |

### Part III — 高度な機能

QoS 制御やトピックのワイルドカードマッチングなど、高度な機能を追加します。

| 章 | タイトル | 学ぶこと |
|----|---------|---------|
| [07](chapters/07-topic-wildcards/) | トピックワイルドカード | `+` / `#` マッチング、トピックツリー |
| [08](chapters/08-qos-levels/) | QoS レベル | QoS 0/1 の実装、PUBACK |
| [09](chapters/09-keep-alive/) | Keep Alive | PINGREQ / PINGRESP、タイムアウト管理 |

### Part IV — Broker アーキテクチャ

本格的な Broker の設計と実装に取り組みます。

| 章 | タイトル | 学ぶこと |
|----|---------|---------|
| [10](chapters/10-broker-architecture/) | Broker アーキテクチャ | コンポーネント設計、接続管理 |
| [11](chapters/11-session-management/) | セッション管理 | Clean Session、セッション永続化 |
| [12](chapters/12-retained-will-messages/) | Retain / Will メッセージ | 保持メッセージ、遺言メッセージ |

### Part V — 統合と完成

複数クライアントの同時処理とテストを行い、プロジェクトを完成させます。

| 章 | タイトル | 学ぶこと |
|----|---------|---------|
| [13](chapters/13-multi-client/) | マルチクライアント | 複数接続の同時処理 |
| [14](chapters/14-integration-testing/) | 統合テスト | エンドツーエンドテスト、異常系テスト |

### Part VI — 発展編

`std.Io` を活用した高度な設計パターンとプロダクション品質の機能を実装します。

| 章 | タイトル | 学ぶこと |
|----|---------|---------|
| [15](chapters/15-event-driven-broker/) | イベント駆動ブローカー | `std.Io.Event` によるイベント駆動設計 |
| [16](chapters/16-io-queue-messaging/) | Io.Queue によるメッセージング | `std.Io.Queue(T)` によるスレッド間メッセージパッシング |
| [17](chapters/17-graceful-shutdown/) | Graceful Shutdown | シグナルハンドリング、安全な終了処理 |
| [18](chapters/18-zig-design-patterns/) | Zigらしい設計パターン | `std.process.Init`、Cancelable error、Future パターン |
| [19](chapters/19-benchmark-report/) | ベンチマークレポート | Debug vs ReleaseFast vs mosquitto 性能比較 |

---

## 章一覧

| 部 | 章 | タイトル |
|----|-----|---------|
| **第I部 基礎** | 1 | MQTT 概要 |
| | 2 | バイナリプロトコル |
| | 3 | TCP の基礎 |
| **第II部 コアパケット** | 4 | CONNECT / CONNACK |
| | 5 | PUBLISH フロー |
| | 6 | SUBSCRIBE / UNSUBSCRIBE |
| **第III部 高度な機能** | 7 | トピックワイルドカード |
| | 8 | QoS レベル |
| | 9 | Keep Alive |
| **第IV部 Broker アーキテクチャ** | 10 | Broker アーキテクチャ |
| | 11 | セッション管理 |
| | 12 | Retain / Will メッセージ |
| **第V部 統合と完成** | 13 | マルチクライアント |
| | 14 | 統合テスト |
| **第VI部 発展編** | 15 | イベント駆動ブローカー |
| | 16 | Io.Queue によるメッセージング |
| | 17 | Graceful Shutdown |
| | 18 | Zigらしい設計パターン |
| | 19 | ベンチマークレポート |

---

## コード例 — Zig 0.16 API

本プロジェクトのコードは Zig 0.16 の `std.Io` API を使用しています。以下に主要パターンを示します。

### エントリーポイント (Juicy Main)

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io();
    const addr = std.Io.net.IpAddress.parse(io, "127.0.0.1", 1883);
    _ = addr;
}
```

### Mutex / RwLock

```zig
var mutex = std.Io.Mutex{};
mutex.lockUncancelable(io);
defer mutex.unlock(io);

var rwlock = std.Io.RwLock{};
// 読み取りロック
rwlock.lockShared(io);
defer rwlock.unlockShared(io);
```

### Reader / Writer

```zig
// 0.16 では .interface はフィールド（メソッドではない）
const reader = stream.reader.interface;
const writer = stream.writer.interface;
```

### Sleep

```zig
std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io);
```

---

## ノート・付録

| ドキュメント | 内容 |
|------------|------|
| [用語集](notes/glossary.md) | MQTT / Zig / ネットワーキング用語集（約60語） |
| [前提条件](notes/prerequisites.md) | 環境構築と必要な知識 |
| [MQTT v3.1.1 仕様サマリー](notes/mqtt-v311-summary.md) | 全14パケットタイプのリファレンス |
| [デバッグガイド](notes/debugging-network.md) | ヘックスダンプ、netcat、Wireshark の使い方 |

---

## ビルドコマンド一覧

| コマンド | 説明 |
|---------|------|
| `zig build` | プロジェクト全体のビルド |
| `zig build broker` | Broker のビルドと実行 |
| `zig build pub` | Publisher のビルドと実行 |
| `zig build sub` | Subscriber のビルドと実行 |
| `zig build test` | 全テストの実行 |

---

## プロジェクト構成

```
mqtt_zig/
├── README.md               <- このファイル
├── build.zig               <- ビルド設定
├── src/                    <- ソースコード
├── chapters/               <- 各章の解説と演習
│   ├── 01-mqtt-overview/
│   ├── 02-binary-protocol/
│   ├── ...
│   ├── 14-integration-testing/
│   ├── 15-event-driven-broker/
│   ├── 16-io-queue-messaging/
│   ├── 17-graceful-shutdown/
│   └── 18-zig-design-patterns/
├── notes/                  <- 付録・リファレンス
│   ├── glossary.md
│   ├── prerequisites.md
│   ├── mqtt-v311-summary.md
│   └── debugging-network.md
└── assets/                 <- 図・ダイアグラム
    ├── mqtt-packet-format.mmd
    └── broker-architecture.mmd
```

---

## 対象バージョン

- **Zig**: 0.16
- **MQTT**: v3.1.1 (OASIS Standard)

---

## ライセンス

教育目的のプロジェクトです。
