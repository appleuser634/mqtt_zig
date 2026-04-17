# Chapter 03: ZigでTCP通信

## 学習目標

- TCP の基本概念（コネクション指向、ストリーム型）を復習する
- Zig 0.16 の `std.Io.net` API でサーバとクライアントを実装できる
- `std.Io.Threaded` による I/O ランタイムの初期化を理解する
- `IpAddress.parse` / `IpAddress.listen` / `listener.accept` / `stream.close` の使い方を理解する
- `stream.reader(io, &buf)` / `stream.writer(io, &buf)` による I/O パターンを活用する
- 本プロジェクトの `transport.zig` の設計意図を把握する

---

## TCP の基本

TCP（Transmission Control Protocol）は**コネクション指向**のプロトコルである。
MQTT はこの TCP の上に構築されている。

TCP の特徴:
- **信頼性のある配信**: パケットの順序保証・再送制御
- **ストリーム型**: バイト列の境界がない（メッセージ境界は上位層で管理）
- **全二重通信**: 送受信を同時に行える

> MQTT がストリーム上で動作するため、固定ヘッダの Remaining Length を使って
> パケットの境界を判断する必要がある（Chapter 02 参照）。

---

## Zig 0.16 の Io ランタイム

Zig 0.16 では、ネットワーク I/O は `std.Io` ランタイムを通じて行う。
全ての I/O 操作に `io` パラメータを渡す点が従来の API と大きく異なる。

### Juicy Main パターン

本プロジェクトの Broker は以下のように `std.process.Init` からランタイムを受け取る:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;  // 汎用アロケータ
    const io = init.io;          // Io ランタイム
    const args = init.minimal.args; // コマンドライン引数

    // サーバ起動...
}
```

`init.gpa` は事前に初期化されたアロケータ、`init.io` は I/O ランタイムである。
これにより、明示的な初期化コードが不要になる。

### Io ランタイムの手動初期化

テストやライブラリでは、手動で I/O ランタイムを初期化することもできる:

```zig
var threaded = std.Io.Threaded.init(allocator, .{});
const io = threaded.io();
// io を使ってネットワーク操作を行う
```

---

## std.Io.net API

Zig 0.16 のネットワーク API は `std.Io.net` 名前空間にある。

### 名前空間の取得

```zig
const std = @import("std");
const net = std.Io.net;
```

### アドレスの解析

```zig
// IPv4 アドレスとポート番号を指定
const address = net.IpAddress.parse("127.0.0.1", 1883) catch |err| {
    std.debug.print("アドレス解析エラー: {}\n", .{err});
    return err;
};
```

ポート番号 1883 は MQTT の標準ポートである。
`IpAddress.parse` は `"0.0.0.0"` で全インターフェースにバインドすることもできる。

---

## サーバ側: listen / accept

### サーバの基本構造

```zig
const std = @import("std");
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const address = net.IpAddress.parse("0.0.0.0", 1883) catch
        return error.AddressParseFailed;

    // リスナーを作成（io パラメータが必須）
    var listener = try net.IpAddress.listen(&address, io, .{
        .reuse_address = true,
    });
    defer listener.deinit(io);

    std.log.info("MQTT Broker listening on :1883", .{});

    // クライアントの接続を受け入れるループ
    while (true) {
        // accept にも io パラメータが必須
        const stream = try listener.accept(io);

        std.log.info("クライアント接続を受け入れました", .{});

        // クライアントを処理
        handleClient(stream, io) catch |err| {
            std.log.err("クライアント処理エラー: {s}", .{@errorName(err)});
        };

        // ストリームを閉じる（io パラメータが必須）
        stream.close(io);
    }
}
```

### listen のオプション

`listen` に渡す構造体で以下を設定できる:

```zig
var listener = try net.IpAddress.listen(&address, io, .{
    .reuse_address = true,    // TIME_WAIT 中でも再バインド可能
});
```

### accept の戻り値

Zig 0.16 では `listener.accept(io)` は `net.Stream` を直接返す。
この stream で読み書きを行う。

---

## クライアント側: connect

```zig
fn connectToBroker(io: std.Io) !net.Stream {
    const address = net.IpAddress.parseIp4("127.0.0.1", 1883) catch
        return error.AddressParseFailed;
    const stream = try net.IpAddress.connect(&address, io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    return stream;
}
```

`IpAddress.connect` は TCP 接続を確立し、`net.Stream` を返す。
`io` パラメータにより、非同期 I/O ランタイムと統合される。

---

## ストリームの読み書き

Zig 0.16 では、stream の reader/writer はバッファと io を引数に取る。

### Reader の使い方

```zig
fn readFromStream(stream: net.Stream, io: std.Io) !void {
    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    // 1バイトを読む（readByte は存在しない）
    var byte_buf: [1]u8 = undefined;
    reader.interface.readSliceAll(&byte_buf) catch |err| switch (err) {
        error.EndOfStream => {
            std.log.info("接続が閉じられました", .{});
            return;
        },
        else => return err,
    };
    const first_byte = byte_buf[0];
    _ = first_byte;

    // 複数バイトを読む
    var data: [256]u8 = undefined;
    try reader.interface.readSliceAll(data[0..10]); // 10バイト読む
}
```

**重要なポイント:**
- `stream.reader(io, &read_buffer)` でリーダーを作成する。第2引数はバッファ
- `.interface` は**フィールド**であり、関数呼び出しではない
- `readByte()` は存在しない。代わりに `readSliceAll(buf[0..1])` を使う
- `readSliceAll` は指定したスライスが満たされるまでブロックする

### Writer の使い方

```zig
fn writeToStream(stream: net.Stream, io: std.Io) !void {
    var write_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    // データを書き込む
    try writer.interface.writeAll(&[_]u8{ 0xD0, 0x00 }); // PINGRESP

    // フラッシュして実際に送信する（重要!）
    try writer.interface.flush();
}
```

**重要なポイント:**
- `stream.writer(io, &write_buffer)` でライターを作成する
- `.interface` は**フィールド**であり、関数呼び出しではない
- `writeAll` 後に必ず `flush()` を呼ぶこと。呼ばないとデータが送信されない

---

## 本プロジェクトの transport.zig

本プロジェクトでは `src/client/transport.zig` に TCP 通信の抽象化層を設けている。

### Transport 構造体

```zig
pub const Transport = struct {
    stream: net.Stream,
    io: std.Io,
    allocator: Allocator,

    /// TCP 接続を確立
    pub fn connect(allocator: Allocator, io: std.Io, host: []const u8, port: u16) !Transport {
        const address = try net.IpAddress.parseIp4(host, port);
        const stream = try net.IpAddress.connect(&address, io, .{
            .mode = .stream,
            .protocol = .tcp,
        });
        return .{
            .stream = stream,
            .io = io,
            .allocator = allocator,
        };
    }

    /// 接続を閉じる
    pub fn close(self: *Transport) void {
        self.stream.close(self.io);
    }
};
```

### バイト列の送信

```zig
pub fn send(self: *Transport, data: []const u8) !void {
    var writer_buffer: [8192]u8 = undefined;
    var writer = self.stream.writer(self.io, &writer_buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}
```

### パケットの受信

```zig
pub fn readPacket(self: *Transport) !ReadResult {
    var reader_buffer: [8192]u8 = undefined;
    var reader = self.stream.reader(self.io, &reader_buffer);

    // 固定ヘッダの最初のバイトを読む
    var header_buf: [5]u8 = undefined;
    reader.interface.readSliceAll(header_buf[0..1]) catch |err| switch (err) {
        error.EndOfStream => return error.ConnectionClosed,
        else => return err,
    };

    // Remaining Length を読む (最大4バイト)
    var rl_len: usize = 0;
    while (rl_len < 4) {
        try reader.interface.readSliceAll(header_buf[1 + rl_len ..][0..1]);
        rl_len += 1;
        if (header_buf[rl_len] & 0x80 == 0) break;
    }

    const header = try codec.decodeFixedHeader(header_buf[0 .. 1 + rl_len]);

    // Remaining bytes を読む
    const data = try self.allocator.alloc(u8, header.remaining_length);
    errdefer self.allocator.free(data);
    try reader.interface.readSliceAll(data);

    return .{ .header = header, .data = data };
}
```

Transport は以下の役割を果たす:
- `io` と `stream` をまとめて保持し、引き回しを簡潔にする
- 固定ヘッダ + Remaining Length の読み取りロジックを共通化する
- `readSliceAll` を使い、TCP ストリームの断片化を意識せずに完全なパケットを受信する

---

## Broker のサーバ実装

`src/broker/server.zig` は `std.Io.net` を使った実際のサーバ実装である。

```zig
pub fn run(self: *Server) !void {
    const address = net.IpAddress.parse("0.0.0.0", self.port) catch
        return error.AddressParseFailed;

    var listener = try net.IpAddress.listen(&address, self.io, .{
        .reuse_address = true,
    });
    defer listener.deinit(self.io);

    std.log.info("MQTT Broker listening on port {d}", .{self.port});

    while (!self.stop_requested.load(.acquire)) {
        const stream = listener.accept(self.io) catch |err| {
            if (self.stop_requested.load(.acquire)) break;
            std.log.err("accept error: {s}", .{@errorName(err)});
            continue;
        };

        // 接続ハンドラを別スレッドで実行
        // ...
    }
}
```

注目点:
- `net.IpAddress.parse` でアドレスを作成し、`listen` に `&address` と `io` を渡す
- `listener.accept(io)` で接続を待ち受け、`stream` を取得する
- Graceful Shutdown のために `std.atomic.Value(bool)` を使用している

---

## エラーハンドリング

ネットワーク I/O では様々なエラーが発生しうる:

```zig
fn safeRead(stream: net.Stream, io: std.Io) void {
    var buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &buf);

    var byte_buf: [1]u8 = undefined;
    reader.interface.readSliceAll(&byte_buf) catch |err| {
        switch (err) {
            error.ConnectionResetByPeer => {
                std.log.info("接続がリセットされました", .{});
            },
            error.EndOfStream => {
                std.log.info("接続が閉じられました", .{});
            },
            else => {
                std.log.err("読み込みエラー: {s}", .{@errorName(err)});
            },
        }
        return;
    };
}
```

---

## Zig 0.16 の同期プリミティブ

マルチスレッドでの接続管理には、Zig 0.16 の同期プリミティブを使う:

### Mutex

```zig
var mutex: std.Io.Mutex = .init;

// ロック（キャンセル不可）
mutex.lockUncancelable(io);
defer mutex.unlock(io);

// クリティカルセクション
```

### RwLock

```zig
var rwlock: std.Io.RwLock = .init;

// 読み取りロック
rwlock.lockSharedUncancelable(io);
defer rwlock.unlockShared(io);

// 書き込みロック
rwlock.lockUncancelable(io);
defer rwlock.unlock(io);
```

### Event

```zig
var event: std.Io.Event = .unset;

// シグナルを送る
event.set(io);

// シグナルを待つ
event.waitUncancelable(io);
```

Broker の Graceful Shutdown ではこの Event が使われている（`server.zig` 参照）。

---

## API 対応表: 旧 API vs Zig 0.16

| 操作             | 旧 API (std.net)                    | Zig 0.16 (std.Io.net)                             |
|-----------------|-------------------------------------|----------------------------------------------------|
| アドレス解析     | `net.Address.parseIp4(host, port)`  | `net.IpAddress.parse(host, port)`                  |
| リッスン         | `address.listen(.{...})`            | `net.IpAddress.listen(&address, io, .{...})`       |
| 接続受付         | `server.accept()`                   | `listener.accept(io)`                              |
| 接続確立         | `net.tcpConnectToAddress(address)`  | `net.IpAddress.connect(&address, io, .{...})`      |
| ストリーム閉じる | `stream.close()`                    | `stream.close(io)`                                 |
| リーダー取得     | `stream.reader()`                   | `stream.reader(io, &buffer)`                       |
| ライター取得     | `stream.writer()`                   | `stream.writer(io, &buffer)`                       |
| 1バイト読み      | `reader.readByte()`                 | `reader.interface.readSliceAll(buf[0..1])`         |
| データ読み       | `reader.readAll(slice)`             | `reader.interface.readSliceAll(slice)`              |
| データ書き       | `writer.writeAll(data)`             | `writer.interface.writeAll(data)`                  |
| フラッシュ       | `bw.flush()`                        | `writer.interface.flush()`                         |

---

## まとめ

- Zig 0.16 では `std.Io.net` 名前空間でネットワーク操作を行う
- 全ての I/O 操作に `io` パラメータ（`std.Io` インスタンス）を渡す
- `stream.reader(io, &buffer)` / `stream.writer(io, &buffer)` でリーダー/ライターを作成し、`.interface` フィールド経由で読み書きする
- `readByte()` は存在しない。`readSliceAll(buf[0..1])` を使う
- `writer.interface.flush()` を忘れるとデータが送信されないので注意
- `transport.zig` は `io`、`stream`、`allocator` をまとめて保持し、MQTT パケットの送受信を簡潔にしている

次のチャプターでは、実際の CONNECT / CONNACK パケットの構造とエンコード・デコードを学ぶ。
