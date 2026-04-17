const std = @import("std");
const types = @import("mqtt_types");
const topic_mod = @import("mqtt_topic");

const Allocator = types.Allocator;
const QoS = types.QoS;

/// 保持メッセージ
pub const RetainedMessage = struct {
    topic: []const u8,
    payload: []const u8,
    qos: QoS,
};

/// Retained メッセージストア
pub const RetainStore = struct {
    messages: std.StringHashMap(RetainedMessage),
    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: std.Io) RetainStore {
        return .{
            .messages = std.StringHashMap(RetainedMessage).init(allocator),
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *RetainStore) void {
        var iter = self.messages.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.topic);
            self.allocator.free(entry.value_ptr.payload);
        }
        self.messages.deinit();
    }

    pub fn store(self: *RetainStore, topic: []const u8, payload: []const u8, qos: QoS) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (payload.len == 0) {
            if (self.messages.fetchRemove(topic)) |kv| {
                self.allocator.free(kv.value.topic);
                self.allocator.free(kv.value.payload);
            }
            return;
        }

        if (self.messages.getPtr(topic)) |existing| {
            self.allocator.free(existing.payload);
            existing.payload = try self.allocator.dupe(u8, payload);
            existing.qos = qos;
            return;
        }

        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);
        const payload_copy = try self.allocator.dupe(u8, payload);

        try self.messages.put(topic_copy, .{
            .topic = topic_copy,
            .payload = payload_copy,
            .qos = qos,
        });
    }

    pub fn getMatching(self: *RetainStore, allocator: Allocator, filter: []const u8) ![]RetainedMessage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var results = std.array_list.AlignedManaged(RetainedMessage, null).init(allocator);
        errdefer results.deinit();

        var iter = self.messages.iterator();
        while (iter.next()) |entry| {
            if (topic_mod.topicMatchesFilter(entry.value_ptr.topic, filter)) {
                try results.append(.{
                    .topic = try allocator.dupe(u8, entry.value_ptr.topic),
                    .payload = try allocator.dupe(u8, entry.value_ptr.payload),
                    .qos = entry.value_ptr.qos,
                });
            }
        }

        return results.toOwnedSlice();
    }
};
