# 第11章: セッション管理

## 学習目標

- MQTT の Clean Session フラグの動作を理解する
- 永続的サブスクリプションの仕組みを把握する
- クライアントテイクオーバー（同一 client_id の再接続）を実装できる
- Zig 0.16 の `std.Io.RwLock` を用いた SessionManager を設計できる
- `errdefer` によるリソースリーク防止を理解する

---

## セッションとは

MQTT におけるセッションとは、ブローカーがクライアントごとに保持する状態の集合である。

セッションに含まれる情報:
- クライアントID
- サブスクリプション一覧（トピックフィルタと QoS）
- 未配信の QoS 1/2 メッセージ
- 接続状態（オンライン/オフライン）

---

## Clean Session フラグ

CONNECT パケットの Connect Flags 内にある Clean Session ビットは、セッションの扱いを決定する。

### clean_session = true（クリーンセッション）

```
クライアント接続時:
1. 既存のセッションがあれば破棄する
2. 新しい空のセッションを作成する

クライアント切断時:
1. セッションを完全に破棄する
```

一時的な接続に適している。再接続時にサブスクリプションの再登録が必要。

### clean_session = false（永続セッション）

```
クライアント接続時:
1. 既存のセッションがあればそれを再利用する
   -> CONNACK の Session Present フラグ = 1
2. なければ新規作成する
   -> CONNACK の Session Present フラグ = 0

クライアント切断時:
1. セッションを保持し続ける
2. サブスクリプションは維持される
```

再接続時にサブスクリプションが維持されるため、メッセージの取りこぼしを防げる。

---

## RwLock ベースの SessionManager

SessionManager はブローカー内で最もアクセス頻度が高い共有状態である。
メッセージルーティング時に毎回購読者を検索するため、読み取りが圧倒的に多い。
Zig 0.16 の `std.Io.RwLock` を使うことで、読み取り操作を並行に実行できる。

### データ構造

```zig
const Session = struct {
    client_id: []const u8,
    subscriptions: std.StringHashMap(u2), // topic_filter -> max_qos
    connected: bool,
    connection: ?*ConnectionHandler,
    clean_session: bool,
    will_message: ?WillMessage,

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        // サブスクリプションのキーを解放
        var iter = self.subscriptions.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.subscriptions.deinit();
        allocator.free(self.client_id);
    }
};

const SessionManager = struct {
    rwlock: std.Io.RwLock = .init,
    sessions: std.StringHashMap(*Session),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .sessions = std.StringHashMap(*Session).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionManager, io: *std.Io) void {
        self.rwlock.lockUncancelable(io);
        defer self.rwlock.unlock(io);

        var iter = self.sessions.valueIterator();
        while (iter.next()) |session_ptr| {
            session_ptr.*.deinit(self.allocator);
            self.allocator.destroy(session_ptr.*);
        }
        self.sessions.deinit();
    }
};
```

### RwLock の読み取りと書き込みの使い分け

```zig
// 読み取りロック: 複数スレッドが同時に取得可能
// -> 購読者検索、セッション情報参照
rwlock.lockSharedUncancelable(io);
defer rwlock.unlockShared(io);

// 書き込みロック: 排他的に取得
// -> セッション作成、削除、サブスクリプション変更
rwlock.lockUncancelable(io);
defer rwlock.unlock(io);
```

---

## getOrCreate: セッションの取得または作成

```zig
const GetOrCreateResult = struct {
    session: *Session,
    session_existed: bool,
};

pub fn getOrCreate(
    self: *SessionManager,
    io: *std.Io,
    client_id: []const u8,
    clean_session: bool,
) !GetOrCreateResult {
    // 書き込みロック（作成の可能性があるため）
    self.rwlock.lockUncancelable(io);
    defer self.rwlock.unlock(io);

    if (self.sessions.get(client_id)) |existing| {
        if (clean_session) {
            // 既存セッションをクリア
            existing.clearSubscriptions(self.allocator);
        }
        return .{ .session = existing, .session_existed = true };
    }

    // 新しいセッションを作成
    const session = try self.allocator.create(Session);
    errdefer self.allocator.destroy(session);

    const owned_id = try self.allocator.dupe(u8, client_id);
    errdefer self.allocator.free(owned_id);

    session.* = .{
        .client_id = owned_id,
        .subscriptions = std.StringHashMap(u2).init(self.allocator),
        .connected = false,
        .connection = null,
        .clean_session = clean_session,
        .will_message = null,
    };

    try self.sessions.put(owned_id, session);
    return .{ .session = session, .session_existed = false };
}
```

### CONNECT 処理での利用

```zig
fn handleConnect(self: *ConnectionHandler, io: *std.Io) !void {
    const connect = try self.decodeConnect();

    const result = try self.session_manager.getOrCreate(
        io,
        connect.client_id,
        connect.clean_session,
    );

    // CONNACK で Session Present を通知
    try self.sendConnack(io, .{
        .session_present = result.session_existed and !connect.clean_session,
        .return_code = .accepted,
    });

    self.client_id = connect.client_id;
}
```

---

## 購読者検索: 読み取りロック

メッセージルーティング時に呼ばれる。読み取りロックにより複数スレッドが同時に検索できる。

```zig
pub fn getSubscribers(
    self: *SessionManager,
    io: *std.Io,
    topic: []const u8,
    result_buf: []SubscriberInfo,
) usize {
    // 読み取りロック: 複数スレッドが並行して検索可能
    self.rwlock.lockSharedUncancelable(io);
    defer self.rwlock.unlockShared(io);

    var count: usize = 0;
    var iter = self.sessions.valueIterator();
    while (iter.next()) |session| {
        if (!session.*.connected) continue;
        if (session.*.subscriptions.get(topic)) |qos| {
            if (count < result_buf.len) {
                result_buf[count] = .{
                    .connection = session.*.connection.?,
                    .max_qos = qos,
                };
                count += 1;
            }
        }
    }
    return count;
}
```

### パフォーマンス効果

読み取りロックの利点は、複数のメッセージルーティングが同時に実行できることである。

```
スレッド1: PUBLISH 受信 -> getSubscribers (読み取りロック) -> 転送
スレッド2: PUBLISH 受信 -> getSubscribers (読み取りロック) -> 転送
スレッド3: PUBLISH 受信 -> getSubscribers (読み取りロック) -> 転送
   ^^ これらが全て同時に実行される

スレッド4: CONNECT 受信 -> getOrCreate (書き込みロック) -> 排他的
   ^^ 書き込み中はスレッド1-3もブロックされる
```

---

## errdefer によるリソースリーク防止

`errdefer` は、スコープがエラーで抜ける場合のみ実行されるクリーンアップである。
リソースを段階的に確保する際、途中でエラーが発生してもリークしない。

```zig
pub fn createSession(
    self: *SessionManager,
    client_id: []const u8,
) !*Session {
    // ステップ1: Session 構造体を確保
    const session = try self.allocator.create(Session);
    errdefer self.allocator.destroy(session);
    // ステップ2以降でエラーなら session を解放

    // ステップ2: client_id をコピー
    const owned_id = try self.allocator.dupe(u8, client_id);
    errdefer self.allocator.free(owned_id);
    // ステップ3以降でエラーなら owned_id を解放

    // ステップ3: HashMap に登録
    try self.sessions.put(owned_id, session);
    // ここでエラーなら owned_id と session の両方が解放される

    return session;
    // 成功時は errdefer は実行されない
}
```

`errdefer` は Zig のエラーハンドリングの核心的な機能であり、手動メモリ管理でもリソースリークを確実に防げる。

---

## クライアントテイクオーバー

同じ client_id で新しい接続が来た場合、既存の接続を切断して新しい接続に切り替える。
これは MQTT 仕様で定められた動作である。

```zig
pub fn connectClient(
    self: *SessionManager,
    io: *std.Io,
    client_id: []const u8,
    new_conn: *ConnectionHandler,
    clean_session: bool,
) !*Session {
    // 書き込みロック
    self.rwlock.lockUncancelable(io);
    defer self.rwlock.unlock(io);

    if (self.sessions.get(client_id)) |existing| {
        if (existing.connected) {
            // 既存の接続を強制切断（テイクオーバー）
            if (existing.connection) |old_conn| {
                std.log.info("クライアントテイクオーバー: {s}", .{client_id});
                old_conn.forceDisconnect();
            }
        }
        existing.connection = new_conn;
        existing.connected = true;

        if (clean_session) {
            existing.clearSubscriptions(self.allocator);
            existing.clean_session = true;
        }
        return existing;
    }

    // 新規セッション作成
    return try self.createNewSession(client_id, new_conn, clean_session);
}
```

### テイクオーバーの流れ

```
1. クライアントA が client_id="sensor-01" で接続中
2. クライアントB が同じ client_id="sensor-01" で接続を試みる
3. ブローカーはクライアントA の接続を強制切断
4. クライアントB のセッションとして登録
5. clean_session に応じてサブスクリプションを引き継ぐ or クリア
```

---

## サブスクリプションの管理

サブスクリプションの追加・削除は書き込みロックが必要である。

```zig
pub fn addSubscription(
    self: *SessionManager,
    io: *std.Io,
    client_id: []const u8,
    topic_filter: []const u8,
    max_qos: u2,
) !void {
    // 書き込みロック
    self.rwlock.lockUncancelable(io);
    defer self.rwlock.unlock(io);

    const session = self.sessions.get(client_id) orelse return error.SessionNotFound;

    // トピックフィルタを複製して保存
    const owned_filter = try self.allocator.dupe(u8, topic_filter);
    errdefer self.allocator.free(owned_filter);

    // 既存のエントリがあれば古いキーを解放
    if (session.subscriptions.fetchRemove(topic_filter)) |removed| {
        self.allocator.free(removed.key);
    }

    try session.subscriptions.put(owned_filter, max_qos);
}

pub fn removeSubscription(
    self: *SessionManager,
    io: *std.Io,
    client_id: []const u8,
    topic_filter: []const u8,
) !void {
    // 書き込みロック
    self.rwlock.lockUncancelable(io);
    defer self.rwlock.unlock(io);

    const session = self.sessions.get(client_id) orelse return error.SessionNotFound;

    if (session.subscriptions.fetchRemove(topic_filter)) |removed| {
        self.allocator.free(removed.key);
    }
}
```

---

## 切断時のセッション処理

```zig
pub fn disconnectClient(
    self: *SessionManager,
    io: *std.Io,
    client_id: []const u8,
    graceful: bool,
) void {
    // 書き込みロック
    self.rwlock.lockUncancelable(io);
    defer self.rwlock.unlock(io);

    const session = self.sessions.get(client_id) orelse return;

    session.connected = false;
    session.connection = null;

    if (session.clean_session) {
        // クリーンセッション: 完全に破棄
        _ = self.sessions.remove(client_id);
        session.deinit(self.allocator);
        self.allocator.destroy(session);
    }
    // 永続セッション: サブスクリプションを保持して残す

    if (!graceful) {
        // 非正常切断: Will メッセージを発行（第12章で詳述）
    }
}
```

---

## StringHashMap の活用

Zig の `std.StringHashMap` は `[]const u8` をキーとする HashMap である。
文字列のハッシュと比較を自動で行うため、MQTT のトピックフィルタやクライアントIDの管理に最適である。

```zig
// 初期化
var map = std.StringHashMap(u32).init(allocator);
defer map.deinit();

// 追加
try map.put("key", 42);

// 取得
if (map.get("key")) |value| {
    std.log.info("値: {d}", .{value});
}

// 削除（キーと値のペアを返す）
if (map.fetchRemove("key")) |entry| {
    // entry.key, entry.value が取得可能
}
```

注意: `put` に渡すキーのライフタイムは、HashMap のエントリが存在する間有効でなければならない。スタック上の一時文字列をキーにすると、ダングリングポインタになる。
必ず `allocator.dupe` でコピーしてからキーとして使うこと。

---

## まとめ

- Clean Session フラグにより、一時的/永続的セッションを使い分ける
- `std.Io.RwLock` で読み取りと書き込みを分離し、並行性能を向上させる
  - `lockSharedUncancelable(io)` / `unlockShared(io)` で読み取りロック
  - `lockUncancelable(io)` / `unlock(io)` で書き込みロック
- `errdefer` を活用して、段階的なリソース確保でもリークを防ぐ
- クライアントテイクオーバーで同一 client_id の排他制御を行う
- `StringHashMap` + `allocator.dupe` でトピックフィルタを安全に管理する

次章では、Retained メッセージと Will メッセージについて学ぶ。
