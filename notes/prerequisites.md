# 前提条件

本チュートリアルを始めるにあたって必要な環境と知識について説明します。

---

## 必要な環境

### Zig 0.16

本チュートリアルは **Zig 0.16** を対象としています。

Zig 0.16 では `std.Io` という新しい統合 I/O フレームワークが導入されました。すべてのネットワーク操作、並行処理、同期プリミティブがこの `std.Io` を通じて行われます。本チュートリアルのコードはすべて Zig 0.16 の `std.Io` API を前提としています。

主な変更点:
- **エントリーポイント**: `pub fn main(init: std.process.Init) !void` (Juicy Main)
- **I/O パラメータ**: ネットワーク操作や同期プリミティブは `io` パラメータを受け取る
- **Reader / Writer**: `.interface` はメソッドではなくフィールドとしてアクセス
- **Mutex / RwLock**: `std.Io.Mutex` / `std.Io.RwLock` を使用

#### インストール方法

**公式サイトからダウンロード:**

<https://ziglang.org/download/>

お使いの OS に合ったバイナリをダウンロードし、パスを通してください。

**macOS (Homebrew):**

```bash
brew install zig
```

**バージョン確認:**

```bash
zig version
# 出力例: 0.16.0
```

> **注意**: 本チュートリアルは **Zig 0.16 専用** です。Zig はバージョン間で破壊的変更が入るため、0.16 以外のバージョンではコードが動作しません。本書で使用する `std.Io` API は 0.16 で導入されたものです。

### テキストエディタ

Zig の構文ハイライトとエラー表示に対応したエディタを推奨します。

- **VS Code** + [Zig Language Server (ZLS)](https://github.com/zigtools/zls) — 最も広く使われている組み合わせ
- **Neovim** + ZLS
- **Emacs** + zig-mode

### ターミナル

コマンドライン操作が必要です。macOS の Terminal.app、Linux の端末エミュレータ、Windows の PowerShell やWSL が利用できます。

---

## 必要な知識

### プログラミングの基礎（必須）

以下の概念を理解していることを前提とします（言語は問いません）：

- 変数、関数、制御構文（if / for / while）
- 配列・リスト
- 構造体やクラスの概念
- ファイルの読み書き（概念レベル）

Zig の文法自体は各章で必要に応じて説明します。

### ネットワーキングの知識（不要）

**ネットワーキングの経験は不要です。** 第3章「TCP の基礎」で TCP ソケットプログラミングをゼロから学びます。

- TCP とは何か
- ソケットの概念
- クライアント / サーバーモデル

これらはすべてチュートリアル内で扱います。

### MQTT の知識（不要）

MQTT の知識も不要です。第1章で概要を、第2章以降でプロトコルの詳細を段階的に学びます。

---

## 参考リンク

### Zig 公式ドキュメント

| リソース | URL |
|----------|-----|
| Zig 公式サイト | <https://ziglang.org/> |
| Zig 言語リファレンス | <https://ziglang.org/documentation/0.16.0/> |
| Zig 標準ライブラリ API | <https://ziglang.org/documentation/0.16.0/std/> |
| Zig Learn (コミュニティ) | <https://ziglearn.org/> |
| Zig GitHub リポジトリ | <https://github.com/ziglang/zig> |

### MQTT 関連

| リソース | URL |
|----------|-----|
| MQTT v3.1.1 仕様書 (OASIS) | <https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html> |
| HiveMQ MQTT Essentials | <https://www.hivemq.com/mqtt-essentials/> |

### ツール

| ツール | 用途 |
|--------|------|
| `netcat` (`nc`) | TCP 接続テスト（第3章で使用） |
| Wireshark | パケットキャプチャ（オプション、[notes/debugging-network.md](./debugging-network.md) 参照） |
| MQTT Explorer | MQTT クライアント GUI（動作確認用） |

---

## 環境の動作確認

以下のコマンドで環境が正しく準備できているか確認できます。

```bash
# Zig のバージョン確認（0.16.x であること）
zig version

# プロジェクトのビルド確認（プロジェクトルートで実行）
zig build

# テスト実行
zig build test
```

すべてエラーなく完了すれば、チュートリアルを開始する準備は完了です。

---

> **次のステップ**: [第1章 — MQTT 概要](../chapters/01-mqtt-overview/) に進みましょう。
