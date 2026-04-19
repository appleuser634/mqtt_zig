const std = @import("std");
const types = @import("mqtt_types");
const topic_mod = @import("mqtt_topic");

const Allocator = types.Allocator;
const QoS = types.QoS;

/// サブスクリプション情報
pub const Subscription = struct {
    filter: []const u8,
    qos: QoS,
};

/// クライアントセッション
pub const Session = struct {
    client_id: []const u8,
    subscriptions: std.array_list.AlignedManaged(Subscription, null),
    clean_session: bool,
    connected: bool = false,

    pub fn init(allocator: Allocator, client_id: []const u8, clean_session: bool) !Session {
        return .{
            .client_id = try allocator.dupe(u8, client_id),
            .subscriptions = .init(allocator),
            .clean_session = clean_session,
        };
    }

    pub fn deinit(self: *Session, allocator: Allocator) void {
        for (self.subscriptions.items) |sub| {
            allocator.free(sub.filter);
        }
        self.subscriptions.deinit();
        allocator.free(self.client_id);
    }

    pub fn addSubscription(self: *Session, allocator: Allocator, filter: []const u8, qos: QoS) !void {
        for (self.subscriptions.items) |*sub| {
            if (std.mem.eql(u8, sub.filter, filter)) {
                sub.qos = qos;
                return;
            }
        }
        try self.subscriptions.append(.{
            .filter = try allocator.dupe(u8, filter),
            .qos = qos,
        });
    }

    pub fn removeSubscription(self: *Session, allocator: Allocator, filter: []const u8) bool {
        for (self.subscriptions.items, 0..) |sub, i| {
            if (std.mem.eql(u8, sub.filter, filter)) {
                allocator.free(sub.filter);
                _ = self.subscriptions.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn matchesTopic(self: *const Session, topic_name: []const u8) ?QoS {
        var max_qos: ?QoS = null;
        for (self.subscriptions.items) |sub| {
            if (topic_mod.topicMatchesFilter(topic_name, sub.filter)) {
                if (max_qos == null or @intFromEnum(sub.qos) > @intFromEnum(max_qos.?)) {
                    max_qos = sub.qos;
                }
            }
        }
        return max_qos;
    }
};

/// セッションマネージャ: 全クライアントセッションをスレッドセーフに管理
/// Zig 0.16: std.Io.RwLock で読み取り並行性を最適化
/// （サブスクリプション検索は読み取り頻度が高く、書き込み頻度が低い）
pub const SessionManager = struct {
    sessions: std.StringHashMap(Session),
    allocator: Allocator,
    io: std.Io,
    rwlock: std.Io.RwLock = .init,

    pub fn init(allocator: Allocator, io: std.Io) SessionManager {
        return .{
            .sessions = std.StringHashMap(Session).init(allocator),
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            var session = entry.value_ptr;
            session.deinit(self.allocator);
        }
        self.sessions.deinit();
    }

    /// CONNECT 時のセッション処理（排他ロック: 書き込み）
    pub fn handleConnect(self: *SessionManager, client_id: []const u8, clean_session: bool) !struct { session_present: bool } {
        self.rwlock.lockUncancelable(self.io);
        defer self.rwlock.unlock(self.io);

        if (self.sessions.getPtr(client_id)) |existing| {
            if (clean_session) {
                // remove を先に実行（キーは existing.client_id が参照しているため deinit の前に行う）
                var old_session = existing.*;
                _ = self.sessions.remove(client_id);
                old_session.deinit(self.allocator);
                var new_session = try Session.init(self.allocator, client_id, true);
                new_session.connected = true;
                try self.sessions.put(new_session.client_id, new_session);
                return .{ .session_present = false };
            } else {
                existing.connected = true;
                return .{ .session_present = true };
            }
        } else {
            var new_session = try Session.init(self.allocator, client_id, clean_session);
            new_session.connected = true;
            try self.sessions.put(new_session.client_id, new_session);
            return .{ .session_present = false };
        }
    }

    /// 切断処理（排他ロック: 書き込み）
    pub fn handleDisconnect(self: *SessionManager, client_id: []const u8) void {
        self.rwlock.lockUncancelable(self.io);
        defer self.rwlock.unlock(self.io);

        if (self.sessions.getPtr(client_id)) |session| {
            session.connected = false;
            if (session.clean_session) {
                var old_session = session.*;
                _ = self.sessions.remove(client_id);
                old_session.deinit(self.allocator);
            }
        }
    }

    /// サブスクリプション追加（排他ロック: 書き込み）
    pub fn addSubscription(self: *SessionManager, client_id: []const u8, filter: []const u8, qos: QoS) !void {
        self.rwlock.lockUncancelable(self.io);
        defer self.rwlock.unlock(self.io);

        if (self.sessions.getPtr(client_id)) |session| {
            try session.addSubscription(self.allocator, filter, qos);
        }
    }

    /// サブスクリプション削除（排他ロック: 書き込み）
    pub fn removeSubscription(self: *SessionManager, client_id: []const u8, filter: []const u8) bool {
        self.rwlock.lockUncancelable(self.io);
        defer self.rwlock.unlock(self.io);

        if (self.sessions.getPtr(client_id)) |session| {
            return session.removeSubscription(self.allocator, filter);
        }
        return false;
    }

    pub const MatchResult = struct {
        client_id: []const u8,
        qos: QoS,
    };

    /// マッチするセッション検索（共有ロック: 読み取り）
    /// RwLock により複数スレッドが同時に検索可能 → PUBLISH 時のスループット向上
    pub fn findMatchingSessions(self: *SessionManager, allocator: Allocator, topic_name: []const u8) ![]MatchResult {
        self.rwlock.lockSharedUncancelable(self.io);
        defer self.rwlock.unlockShared(self.io);

        var results = std.array_list.AlignedManaged(MatchResult, null).init(allocator);
        errdefer results.deinit();

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr;
            if (session.connected) {
                if (session.matchesTopic(topic_name)) |qos| {
                    try results.append(.{
                        .client_id = session.client_id,
                        .qos = qos,
                    });
                }
            }
        }

        return results.toOwnedSlice();
    }

    /// 改善版: スタック上の固定バッファにマッチ結果を書き込む（ゼロアロケーション）
    pub fn findMatchingSessionsStack(self: *SessionManager, topic_name: []const u8, buf: []MatchResult) []MatchResult {
        self.rwlock.lockSharedUncancelable(self.io);
        defer self.rwlock.unlockShared(self.io);

        var count: usize = 0;
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (count >= buf.len) break;
            const session = entry.value_ptr;
            if (session.connected) {
                if (session.matchesTopic(topic_name)) |qos| {
                    buf[count] = .{
                        .client_id = session.client_id,
                        .qos = qos,
                    };
                    count += 1;
                }
            }
        }
        return buf[0..count];
    }
};
