# Chapter 19: ベンチマークレポート

## 学習目標

- 教育用の素朴な実装 → 改善パターン → ReleaseFast の段階的な性能改善を定量的に理解する
- mosquitto（C 実装、20年以上の実績）との比較で Zig 実装の位置づけを把握する
- Debug ビルドと ReleaseFast ビルドの劇的な性能差を体感する
- ゼロアロケーション・ゼロコピー転送の効果を数値で確認する

---

## 計測環境

| 項目 | 値 |
|------|------|
| OS | macOS (Darwin 25.0.0, Apple Silicon) |
| mqtt-zig | Zig 0.16, std.Io.Threaded, thread-per-connection |
| mosquitto | 2.1.2 (C 実装, シングルスレッド epoll/kqueue) |
| ベンチマークツール | mqtt-bench（Zig 製、1接続で N メッセージ送受信） |
| ペイロード | 64 バイト固定 |

### 4 つのビルド構成

| 構成 | 説明 |
|------|------|
| **素朴 Debug** | 初期実装。fan-out で毎回 encodePublish + writer 作成 |
| **素朴 ReleaseFast** | 初期実装を `-Doptimize=ReleaseFast` でビルド |
| **改善 ReleaseFast** | ゼロアロケーション fan-out + writer キャッシュ + スタック固定バッファ |
| **mosquitto 2.1.2** | C 実装のリファレンスブローカー |

### ビルド方法

```bash
# Debug（デフォルト）
zig build

# ReleaseFast
zig build -Doptimize=ReleaseFast
```

`build.zig` で `b.standardOptimizeOption(.{})` を使用しているため、
**コード変更なし** で切り替え可能。

---

## 改善パターンの詳細

### 改善 1: ゼロアロケーション fan-out（PUBLISH 転送）

**素朴な実装（改善前）:**

```zig
// fan-out のたびに PUBLISH パケットを再エンコード（毎回アロケーション）
const fwd_pkt = pkt.PublishPacket{ .topic = ..., .payload = ... };
const encoded = codec.encodePublish(self.allocator, &fwd_pkt);  // alloc!
defer self.allocator.free(encoded);                              // free!
```

**改善後:**

```zig
// 元のパケットバイト列をそのまま転送（ゼロアロケーション）
var fwd_header: [5]u8 = undefined;
@memcpy(fwd_header[0..header_bytes.len], header_bytes);
fwd_header[0] &= 0xFE;  // retain フラグだけクリア
cw.interface.writeAll(fwd_header[0..header_bytes.len]);  // 固定ヘッダ
cw.interface.writeAll(data);                              // 元データそのまま
cw.interface.flush();
```

PUBLISH パケットの QoS 0 転送では、元のバイト列の retain フラグを落とすだけで
他のサブスクライバーにそのまま転送できる。エンコード/デコードの往復が不要になる。

### 改善 2: writer キャッシュ

**素朴な実装（改善前）:**

```zig
// fan-out のたびに新しい writer を作成
var fwd_write_buf: [8192]u8 = undefined;
var fwd_writer = conn.stream.writer(conn.io, &fwd_write_buf);  // 毎回作成
sendBytes(&fwd_writer.interface, encoded);
```

**改善後:**

```zig
// ConnectionHandler のフィールドに writer をキャッシュ
pub const ConnectionHandler = struct {
    cached_write_buf: [8192]u8 = undefined,
    cached_writer: ?net.Stream.Writer = null,
    // ...
};

// handle() で1回だけ初期化
self.cached_writer = self.stream.writer(self.io, &self.cached_write_buf);

// fan-out ではキャッシュを再利用
if (conn.cached_writer) |*cw| {
    cw.interface.writeAll(data);
    cw.interface.flush();
}
```

### 改善 3: スタック固定バッファによるマッチング

**素朴な実装（改善前）:**

```zig
// ヒープにアロケーションしてマッチ結果を返す
const matches = try self.session_manager.findMatchingSessions(
    self.allocator, publish_pkt.topic);  // alloc!
defer self.allocator.free(matches);      // free!
```

**改善後:**

```zig
// スタック上の固定バッファで受け取る（ゼロアロケーション）
var match_buf: [128]Session.SessionManager.MatchResult = undefined;
const matches = self.session_manager.findMatchingSessionsStack(
    topic, &match_buf);  // no alloc!
```

---

## 計測結果

### 接続スループット（50 クライアント同時接続）

| 構成 | 時間 | スループット | 改善率 |
|------|------|-------------|--------|
| 素朴 Debug | 32.3 ms | 1,546 conn/s | (基準) |
| 素朴 ReleaseFast | 15.2 ms | 3,281 conn/s | 2.1x |
| **改善 ReleaseFast** | **6.3 ms** | **7,885 conn/s** | **5.1x** |
| mosquitto 2.1.2 | 23.8 ms | 2,100 conn/s | — |

**改善 ReleaseFast は mosquitto の 3.8 倍。**

### メッセージスループット（1 pub → 1 sub, 10,000 メッセージ, QoS 0）

| 構成 | E2E 時間 | スループット | 改善率 |
|------|----------|-------------|--------|
| 素朴 Debug | 4,160 ms | 2,404 msg/s | (基準) |
| 素朴 ReleaseFast | 12.7 ms | 786,524 msg/s | 327x |
| **改善 ReleaseFast** | **16.4 ms** | **609,176 msg/s** | **253x** |
| mosquitto 2.1.2 | 23.2 ms | 431,400 msg/s | — |

**改善 ReleaseFast は mosquitto の 1.4 倍。**

> 注: 1:1 スループットでは素朴 ReleaseFast の方が速い。これは改善版の handlePublish が
> トピック名抽出やマッチング処理を追加しているため。1:1 では fan-out の恩恵が出ない。

### Fan-out（1 pub → 10 sub, 1,000 メッセージ）

| 構成 | 総配信数 | 時間 | スループット | 改善率 |
|------|---------|------|-------------|--------|
| 素朴 Debug | 10,000 | 1,878 ms | 5,325 msg/s | (基準) |
| 素朴 ReleaseFast | 10,000 | 16.6 ms | 602,331 msg/s | 113x |
| **改善 ReleaseFast** | **10,000** | **9.5 ms** | **1,055,938 msg/s** | **198x** |
| mosquitto 2.1.2 | 10,000 | 22.2 ms | 450,496 msg/s | — |

**改善 ReleaseFast は mosquitto の 2.3 倍。** ゼロアロケーション転送の効果が顕著。

### Fan-out 大規模（1 pub → 50 sub, 1,000 メッセージ）

| 構成 | 総配信数 | 時間 | スループット | 改善率 |
|------|---------|------|-------------|--------|
| 素朴 Debug | 50,000 | 8,639 ms | 5,788 msg/s | (基準) |
| 素朴 ReleaseFast | 50,000 | 83.7 ms | 597,283 msg/s | 103x |
| **改善 ReleaseFast** | **50,000** | **31.2 ms** | **1,601,493 msg/s** | **277x** |
| mosquitto 2.1.2 | 50,000 | 104.7 ms | 477,747 msg/s | — |

**改善 ReleaseFast は mosquitto の 3.4 倍。**
サブスクライバー数が増えるほど改善効果が拡大する（ゼロアロケーション転送が効く）。

### メモリ使用量（20 クライアント接続時）

| 構成 | RSS |
|------|-----|
| 素朴 Debug | 173.9 MB |
| 素朴 ReleaseFast | 3.7 MB |
| **改善 ReleaseFast** | **4.7 MB** |
| mosquitto 2.1.2 | 5.7 MB |

改善版はキャッシュ用バッファ（8KB/接続）を追加しているため若干増加するが、
mosquitto より依然として 18% 省メモリ。

### バイナリサイズ

| 構成 | サイズ | 備考 |
|------|--------|------|
| 素朴 Debug | 2,249 KB | デバッグ情報込み |
| 素朴 ReleaseFast | 439 KB | |
| **改善 ReleaseFast** | **438 KB** | 静的リンク、依存ゼロ |
| mosquitto 2.1.2 | 367 KB | libssl, libwebsockets に動的リンク |

---

## 総合比較（改善 ReleaseFast vs mosquitto）

| テスト | 改善 RF | mosquitto | 倍率 |
|--------|---------|-----------|------|
| 50 接続 | 7,885 conn/s | 2,100 conn/s | **3.8x** |
| 10K msg E2E | 609,176 msg/s | 431,400 msg/s | **1.4x** |
| Fan-out ×10 | 1,055,938 msg/s | 450,496 msg/s | **2.3x** |
| Fan-out ×50 | **1,601,493 msg/s** | 477,747 msg/s | **3.4x** |
| メモリ | 4.7 MB | 5.7 MB | **0.82x** |
| バイナリ | 438 KB | 367 KB | 1.2x |

---

## 改善効果サマリ（素朴 Debug → 改善 ReleaseFast）

| テスト | 素朴 Debug | 改善 RF | 改善倍率 |
|--------|-----------|---------|---------|
| 接続 | 1,546 conn/s | 7,885 conn/s | **5.1x** |
| 10K msg | 2,404 msg/s | 609,176 msg/s | **253x** |
| Fan-out ×10 | 5,325 msg/s | 1,055,938 msg/s | **198x** |
| Fan-out ×50 | 5,788 msg/s | 1,601,493 msg/s | **277x** |
| メモリ | 173.9 MB | 4.7 MB | **37x 削減** |

---

## 分析

### なぜ改善版が mosquitto を上回るのか

1. **ゼロアロケーション転送**: PUBLISH パケットのバイト列をそのまま転送。mosquitto も類似の最適化をしているが、Zig のバッファド I/O との組み合わせが効率的
2. **writer キャッシュ**: 各接続の writer を1回だけ作成し、fan-out で再利用。システムコールのバッファリング効果が最大化
3. **LLVM 最適化**: Zig は LLVM バックエンドで C と同等の最適化を適用。インライン展開、ループ展開、定数畳み込み
4. **スレッドモデルの利点**: thread-per-connection は接続数が少〜中の場合にコンテキストスイッチコストが低い。50 sub 程度では epoll のイベントループより有利

### mosquitto が上回るケース

- **数千〜数万接続**: thread-per-connection はスレッド数が増えるとコンテキストスイッチコストが支配的になる
- **長時間稼働**: mosquitto は20年以上の実績でメモリリークやエッジケースが磨かれている
- **プロトコル対応**: MQTT v5.0、WebSocket、TLS、永続化、ブリッジなど本番機能が充実

### Debug が遅い理由（再掲）

1. **DebugAllocator**: 全メモリ確保/解放をトラッキング。各アロケーションに数百バイトのメタデータ
2. **安全チェック**: 配列境界、整数オーバーフロー、未定義動作の検出が全て有効
3. **最適化なし**: インライン展開、定数畳み込みなどが行われない

---

## 改善パターンのメリット・デメリット

各改善パターンは性能を大幅に向上させる一方、可読性・安全性・機能面でトレードオフがある。
教育用コードでは「素朴な実装」を推奨し、プロファイリングでボトルネックが判明してから
段階的に適用することが重要である。

### 改善 1: ゼロアロケーション fan-out

**メリット:**

| 項目 | 効果 |
|------|------|
| アロケーション除去 | PUBLISH ごとの encodePublish + free が不要 |
| CPU 使用率低下 | エンコード・デコードの往復処理を完全にスキップ |
| GC プレッシャー低減 | アロケータのフラグメンテーションが発生しない |
| Fan-out スケーラビリティ | サブスクライバー数に対してアロケーション数が O(1) |

**デメリット:**

| 項目 | 影響 | 対策 |
|------|------|------|
| **QoS ダウングレード非対応** | 元パケットをそのまま転送するため、サブスクライバーの QoS がパブリッシャーの QoS より低い場合のダウングレードが行われない。QoS 0 のみ正しく動作する | QoS 1/2 では従来のフルデコード・再エンコードパスにフォールバックする分岐を追加する |
| **可読性の低下** | バイト列を直接操作するため、MQTT プロトコルの意味が見えにくい。`data[0..2]` がトピック長であることはコメントなしでは分からない | 定数やヘルパー関数で意味を付与する |
| **プロトコル拡張が困難** | MQTT v5.0 の Properties フィールドなどが追加された場合、生バイト転送では対応できない | v5.0 対応時にはフルデコードパスを使用する |
| **パケット検証のスキップ** | 不正なパケットをデコードせずに他のサブスクライバーに転送してしまう可能性がある。素朴な実装では decodePublish がバリデーション役を兼ねていた | 転送前に最低限のサニティチェック（トピック長の上限確認など）を追加する |

### 改善 2: writer キャッシュ

**メリット:**

| 項目 | 効果 |
|------|------|
| writer 初期化コスト除去 | stream.writer() の呼び出しが接続あたり1回のみ |
| バッファ再利用 | 8KB の書き込みバッファを接続の寿命中ずっと保持 |

**デメリット:**

| 項目 | 影響 | 対策 |
|------|------|------|
| **スレッド安全性の問題** | cached_writer は ConnectionHandler のフィールドであり、fan-out で他スレッドの handler の cached_writer に書き込む。複数の PUBLISH が同時に同じサブスクライバーに転送する場合、writer のバッファが競合する可能性がある | 本来は per-connection の送信 Mutex を追加すべき。現在のベンチマークでは 1 pub → N sub のためたまたま競合しないが、M pub → N sub で同じサブスクライバーに同時転送すると**データ破損**の危険がある |
| **メモリ使用量の増加** | 各接続に 8KB の書き込みバッファを常時保持。1000 接続で +8MB | 接続数が多い環境ではバッファサイズを縮小するか、オンデマンド作成に戻す |
| **接続切断時のレース** | サブスクライバーが切断した直後に cached_writer に書き込むと、クローズ済みソケットへの書き込みが発生する。素朴な実装では毎回 writer を作成するため、この問題は発生しにくい | ConnectionMap の get 時に connected フラグをチェックする。または送信エラーを catch して無視する（現在の `catch continue` で一応対応済み） |

### 改善 3: スタック固定バッファ

**メリット:**

| 項目 | 効果 |
|------|------|
| ヒープアロケーション除去 | findMatchingSessions のたびの alloc/free が不要 |
| キャッシュ効率 | スタック上のバッファは L1 キャッシュに載りやすい |

**デメリット:**

| 項目 | 影響 | 対策 |
|------|------|------|
| **サブスクライバー数の上限** | `var match_buf: [128]MatchResult` で 128 サブスクライバーが上限。129 以上のマッチがあると黙って切り捨てられ、一部のサブスクライバーにメッセージが届かない | バッファオーバーフロー時にヒープ版にフォールバックする。または上限を大きくする（MatchResult は 24 バイト程度なので 1024 でも 24KB） |
| **スタック使用量の増加** | 128 × 24 バイト ≈ 3KB のスタック消費。thread-per-connection で各スレッドのスタックを消費する | ほとんどのシステムでスレッドスタックは 8MB のためほぼ問題ない。ただし組み込み環境では注意 |

### 総合評価

| 改善パターン | 性能改善 | 安全性リスク | 可読性 | 本番適用 |
|-------------|---------|------------|--------|---------|
| ゼロアロケーション fan-out | ★★★★★ | ★★★☆☆ (QoS 0 限定) | ★★☆☆☆ | QoS 0 限定で適用可 |
| writer キャッシュ | ★★★★☆ | ★★☆☆☆ (競合リスク) | ★★★☆☆ | **送信 Mutex 追加が必須** |
| スタック固定バッファ | ★★★☆☆ | ★★★☆☆ (上限あり) | ★★★★☆ | フォールバック追加で適用可 |

> **教訓**: 性能最適化は常にトレードオフを伴う。本プロジェクトでは教育目的として
> 「素朴な実装」→「改善版」→「計測で効果を確認」→「デメリットを理解」の順序で
> 学ぶことを意図している。本番環境では改善パターンのデメリットを全て解決した上で
> 適用すべきである。

---

## ベンチマークの実行方法

```bash
# 3 者比較スクリプト
bash benchmark.sh

# 手動実行: 改善版 ReleaseFast
zig build -Doptimize=ReleaseFast
./zig-out/bin/mqtt-broker 1883 &
./zig-out/bin/mqtt-bench 127.0.0.1 1883

# mosquitto との相互運用テスト
mosquitto -p 1884 &
./zig-out/bin/mqtt-bench 127.0.0.1 1884
```

---

## まとめ

- **素朴な教育用実装でも** `-Doptimize=ReleaseFast` だけで mosquitto を上回る性能を達成
- **3 つの改善パターン**（ゼロアロケーション転送、writer キャッシュ、スタック固定バッファ）により fan-out で **mosquitto の 3.4 倍** を達成
- 改善は **connection.zig と session.zig の2ファイルのみ** で完結。build.zig やプロトコル層の変更は不要
- Zig の `-Doptimize=ReleaseFast` は C と同等の最適化を提供し、教育用コードをそのまま本番レベルの性能にできる
