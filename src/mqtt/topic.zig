const std = @import("std");

// ── MQTT トピックフィルタとワイルドカードマッチング ──────────
// MQTT 3.1.1 Section 4.7

/// トピック名のバリデーション（パブリッシュ用: ワイルドカード不可）
pub fn isValidTopicName(name: []const u8) bool {
    if (name.len == 0 or name.len > 65535) return false;
    // ワイルドカード文字を含んではいけない
    for (name) |c| {
        if (c == '+' or c == '#') return false;
        if (c == 0) return false; // NULL 文字禁止
    }
    return true;
}

/// トピックフィルタのバリデーション（サブスクライブ用: ワイルドカード可）
pub fn isValidTopicFilter(filter: []const u8) bool {
    if (filter.len == 0 or filter.len > 65535) return false;

    var iter = TopicLevelIterator.init(filter);
    var level_count: usize = 0;
    while (iter.next()) |level| {
        level_count += 1;
        // '#' は最後のレベルかつ単独でなければならない
        if (std.mem.indexOfScalar(u8, level, '#')) |_| {
            if (level.len != 1) return false;
            if (iter.next() != null) return false; // '#' の後にレベルがあってはいけない
            return true;
        }
        // '+' は単独のレベルでなければならない
        if (std.mem.indexOfScalar(u8, level, '+')) |_| {
            if (level.len != 1) return false;
        }
        // NULL 文字禁止
        if (std.mem.indexOfScalar(u8, level, 0)) |_| return false;
    }
    return level_count > 0;
}

/// トピック名がトピックフィルタにマッチするか判定 (MQTT 3.1.1 Section 4.7.3)
pub fn topicMatchesFilter(topic: []const u8, filter: []const u8) bool {
    // $SYS トピックはワイルドカード '#' や '+' で始まるフィルタにマッチしない
    if (topic.len > 0 and topic[0] == '$') {
        if (filter.len > 0 and (filter[0] == '+' or filter[0] == '#')) {
            return false;
        }
    }

    var topic_iter = TopicLevelIterator.init(topic);
    var filter_iter = TopicLevelIterator.init(filter);

    while (true) {
        const filter_level = filter_iter.next();
        const topic_level = topic_iter.next();

        if (filter_level == null and topic_level == null) {
            return true; // 両方とも終了 → マッチ
        }

        if (filter_level) |fl| {
            // '#' は残りの全レベルにマッチ
            if (std.mem.eql(u8, fl, "#")) {
                return true;
            }

            if (topic_level) |tl| {
                // '+' は任意の1レベルにマッチ
                if (std.mem.eql(u8, fl, "+")) {
                    continue;
                }
                // 完全一致
                if (std.mem.eql(u8, fl, tl)) {
                    continue;
                }
                return false;
            } else {
                return false; // フィルタにまだレベルがあるがトピックが終了
            }
        } else {
            return false; // トピックにまだレベルがあるがフィルタが終了
        }
    }
}

/// トピックレベルイテレータ: '/' で分割
pub const TopicLevelIterator = struct {
    data: []const u8,
    pos: usize,
    done: bool,

    pub fn init(topic: []const u8) TopicLevelIterator {
        return .{
            .data = topic,
            .pos = 0,
            .done = false,
        };
    }

    pub fn next(self: *TopicLevelIterator) ?[]const u8 {
        if (self.done) return null;

        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '/') {
            self.pos += 1;
        }

        const level = self.data[start..self.pos];

        if (self.pos < self.data.len) {
            self.pos += 1; // '/' をスキップ
        } else {
            self.done = true;
        }

        return level;
    }
};

// ── テスト ──────────────────────────────────────────────────

test "isValidTopicName: basic" {
    try std.testing.expect(isValidTopicName("sensor/temp"));
    try std.testing.expect(isValidTopicName("a"));
    try std.testing.expect(isValidTopicName("/"));
    try std.testing.expect(isValidTopicName("a/b/c"));
    try std.testing.expect(!isValidTopicName(""));
    try std.testing.expect(!isValidTopicName("sensor/+/temp"));
    try std.testing.expect(!isValidTopicName("sensor/#"));
    try std.testing.expect(!isValidTopicName("sensor/+"));
}

test "isValidTopicFilter: basic" {
    try std.testing.expect(isValidTopicFilter("sensor/temp"));
    try std.testing.expect(isValidTopicFilter("#"));
    try std.testing.expect(isValidTopicFilter("+"));
    try std.testing.expect(isValidTopicFilter("sensor/+/temp"));
    try std.testing.expect(isValidTopicFilter("sensor/#"));
    try std.testing.expect(isValidTopicFilter("+/+/+"));
    try std.testing.expect(!isValidTopicFilter(""));
    try std.testing.expect(!isValidTopicFilter("sensor/temp#")); // '#' が単独でない
    try std.testing.expect(!isValidTopicFilter("sensor/#/temp")); // '#' の後にレベルがある
    try std.testing.expect(!isValidTopicFilter("sensor/te+mp")); // '+' が単独でない
}

test "topicMatchesFilter: exact match" {
    try std.testing.expect(topicMatchesFilter("sensor/temp", "sensor/temp"));
    try std.testing.expect(!topicMatchesFilter("sensor/temp", "sensor/humidity"));
    try std.testing.expect(!topicMatchesFilter("sensor/temp", "sensor"));
}

test "topicMatchesFilter: single-level wildcard (+)" {
    try std.testing.expect(topicMatchesFilter("sensor/temp", "sensor/+"));
    try std.testing.expect(topicMatchesFilter("sensor/humidity", "sensor/+"));
    try std.testing.expect(!topicMatchesFilter("sensor/a/b", "sensor/+"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "+/b/c"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "+/+/+"));
}

test "topicMatchesFilter: multi-level wildcard (#)" {
    try std.testing.expect(topicMatchesFilter("sensor/temp", "sensor/#"));
    try std.testing.expect(topicMatchesFilter("sensor/a/b/c", "sensor/#"));
    try std.testing.expect(topicMatchesFilter("sensor", "sensor/#"));
    try std.testing.expect(topicMatchesFilter("anything", "#"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "#"));
}

test "topicMatchesFilter: $SYS exclusion" {
    try std.testing.expect(!topicMatchesFilter("$SYS/info", "#"));
    try std.testing.expect(!topicMatchesFilter("$SYS/info", "+/info"));
    try std.testing.expect(topicMatchesFilter("$SYS/info", "$SYS/#"));
    try std.testing.expect(topicMatchesFilter("$SYS/info", "$SYS/info"));
}

test "topicMatchesFilter: edge cases" {
    // 空レベル
    try std.testing.expect(topicMatchesFilter("/finance", "/finance"));
    try std.testing.expect(topicMatchesFilter("/finance", "/+"));
    try std.testing.expect(topicMatchesFilter("/finance", "+/+"));
    // sport/# は sport 自体にもマッチ
    try std.testing.expect(topicMatchesFilter("sport", "sport/#"));
}

test "TopicLevelIterator" {
    var iter = TopicLevelIterator.init("a/b/c");
    try std.testing.expectEqualStrings("a", iter.next().?);
    try std.testing.expectEqualStrings("b", iter.next().?);
    try std.testing.expectEqualStrings("c", iter.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), iter.next());

    // 先頭スラッシュ
    var iter2 = TopicLevelIterator.init("/a");
    try std.testing.expectEqualStrings("", iter2.next().?);
    try std.testing.expectEqualStrings("a", iter2.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), iter2.next());
}
