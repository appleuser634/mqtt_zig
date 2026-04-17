# Chapter 07: トピックフィルタとワイルドカード

## 学習目標

- MQTT のトピック名（Topic Name）とトピックフィルタ（Topic Filter）の違いを理解する
- 単一レベルワイルドカード `+` の動作を把握する
- 複数レベルワイルドカード `#` の動作を把握する
- `$SYS` トピックの特別な扱いを理解する
- 本プロジェクトの `topic.zig` の実装を読み解く
- Zig の `std.testing` を活用したテスト手法を習得する

---

## トピック名 vs トピックフィルタ

### トピック名（Topic Name）

PUBLISH パケットで使われる。ワイルドカードを含んではならない。

```
sensor/temperature       -- 有効
factory/line1/status     -- 有効
sensor/+/data            -- 無効 (ワイルドカードは使えない)
```

### トピックフィルタ（Topic Filter）

SUBSCRIBE / UNSUBSCRIBE で使われる。ワイルドカードを含むことができる。

```
sensor/temperature       -- 完全一致
sensor/+/data            -- 単一レベルワイルドカード
sensor/#                 -- 複数レベルワイルドカード
```

### トピックのレベル構造

トピックは `/` で区切られた**レベル**で構成される:

```
sensor/temperature/celsius
  |        |         +-- レベル3
  |        +------------ レベル2
  +---------------------- レベル1
```

---

## 単一レベルワイルドカード: `+`

`+` は**ちょうど1つのレベル**にマッチする。

### マッチ例

| フィルタ             | トピック名               | マッチ? |
|---------------------|-------------------------|---------|
| `sensor/+/data`     | `sensor/temp/data`      | Yes     |
| `sensor/+/data`     | `sensor/humidity/data`  | Yes     |
| `sensor/+/data`     | `sensor/a/b/data`       | No      |
| `+/temperature`     | `sensor/temperature`    | Yes     |
| `+/+`               | `sensor/temperature`    | Yes     |
| `+`                 | `sensor`                | Yes     |
| `+`                 | `sensor/temperature`    | No      |

ポイント:
- `+` は**1つのレベル全体**を置換する
- 空のレベルにもマッチする（例: `+/+` は `/finance` にマッチ -- 先頭が空レベル）
- レベル区切り `/` を超えることはない

---

## 複数レベルワイルドカード: `#`

`#` は**0個以上のレベル**にマッチする。フィルタの**最後**にのみ使用できる。

### マッチ例

| フィルタ             | トピック名                   | マッチ? |
|---------------------|------------------------------|---------|
| `sensor/#`          | `sensor`                     | Yes     |
| `sensor/#`          | `sensor/temp`                | Yes     |
| `sensor/#`          | `sensor/temp/celsius`        | Yes     |
| `#`                 | `sensor/temp`                | Yes     |
| `#`                 | `any/topic/at/all`           | Yes     |
| `sensor/temp/#`     | `sensor/temp`                | Yes     |
| `sensor/temp/#`     | `sensor/temp/celsius`        | Yes     |
| `sensor/#/data`     | (無効なフィルタ)              | --      |

ポイント:
- `#` は**フィルタの末尾でなければならない**
- `#` の前には `/` が必要（ただし `#` 単体は例外）
- **0レベル**にもマッチする（`sensor/#` は `sensor` 自体にマッチ）

---

## `$SYS` トピックの特別扱い

`$` で始まるトピックは**システムトピック**であり、ワイルドカードフィルタからは除外される。

```
フィルタ "#" は "$SYS/broker/clients" にマッチしない
フィルタ "+/broker/clients" は "$SYS/broker/clients" にマッチしない
フィルタ "$SYS/#" は "$SYS/broker/clients" にマッチする
フィルタ "$SYS/broker/+" は "$SYS/broker/clients" にマッチする
```

理由: `#` や `+` が全てのシステムトピックにマッチすると、
クライアントが意図せず大量のシステムメッセージを受信してしまうため。

---

## topic.zig の実装

本プロジェクトの `src/mqtt/topic.zig` にトピック関連の全ロジックを実装している。

### トピック名のバリデーション

PUBLISH 用のトピック名にはワイルドカードを含んではならない:

```zig
pub fn isValidTopicName(name: []const u8) bool {
    if (name.len == 0 or name.len > 65535) return false;
    for (name) |c| {
        if (c == '+' or c == '#') return false;
        if (c == 0) return false; // NULL 文字禁止
    }
    return true;
}
```

### トピックフィルタのバリデーション

SUBSCRIBE 用のフィルタにはワイルドカードのルールがある:

```zig
pub fn isValidTopicFilter(filter: []const u8) bool {
    if (filter.len == 0 or filter.len > 65535) return false;

    var iter = TopicLevelIterator.init(filter);
    var level_count: usize = 0;
    while (iter.next()) |level| {
        level_count += 1;
        // '#' は最後のレベルかつ単独でなければならない
        if (std.mem.indexOfScalar(u8, level, '#')) |_| {
            if (level.len != 1) return false;
            if (iter.next() != null) return false;
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
```

バリデーションルール:
- `#` はフィルタ末尾のレベルにのみ出現可能で、そのレベルは `#` のみ
- `+` はレベル全体を占める必要がある（`sensor/te+mp` は不正）
- NULL 文字は禁止
- 空文字列は不正

---

## TopicLevelIterator

トピック文字列を `/` で分割するイテレータ:

```zig
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
```

Zig には組み込みのイテレータ構文がないが、
`next()` メソッドが `?T`（オプショナル型）を返す慣用パターンで
`while` ループと組み合わせて使う:

```zig
var iter = TopicLevelIterator.init("sensor/temp/celsius");
while (iter.next()) |level| {
    std.debug.print("レベル: {s}\n", .{level});
}
// 出力:
// レベル: sensor
// レベル: temp
// レベル: celsius
```

### 標準ライブラリとの比較

`std.mem.splitScalar` でも同様の分割が可能:

```zig
var it = std.mem.splitScalar(u8, "sensor/temp/celsius", '/');
while (it.next()) |level| {
    // ...
}
```

本プロジェクトでは `done` フラグを持つ独自イテレータを使うことで、
末尾の `/` やエッジケースの制御を明示的に行っている。

---

## topicMatchesFilter 関数

本プロジェクトの核心となるマッチングロジック:

```zig
pub fn topicMatchesFilter(topic: []const u8, filter: []const u8) bool {
    // $SYS チェック: ワイルドカードで始まるフィルタは $ トピックにマッチしない
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
            return true; // 両方とも終了 -> マッチ
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
                return false; // レベルが不一致
            } else {
                return false; // フィルタにまだレベルがあるがトピックが終了
            }
        } else {
            return false; // トピックにまだレベルがあるがフィルタが終了
        }
    }
}
```

### アルゴリズムの流れ

1. `$SYS` トピックの特別扱い: フィルタが `+` や `#` で始まる場合は即座に `false`
2. トピックとフィルタを同時にレベルごとに走査
3. フィルタレベルが `#` なら残り全てにマッチ -> `true`
4. フィルタレベルが `+` なら1レベルスキップ -> `continue`
5. フィルタレベルとトピックレベルが一致 -> `continue`
6. 両方とも `null`（同時に終了） -> `true`
7. それ以外 -> `false`

---

## テストケース

`topic.zig` には `std.testing` を使った網羅的なテストが含まれている:

### バリデーションテスト

```zig
test "isValidTopicName: basic" {
    try std.testing.expect(isValidTopicName("sensor/temp"));
    try std.testing.expect(isValidTopicName("a"));
    try std.testing.expect(isValidTopicName("/"));
    try std.testing.expect(isValidTopicName("a/b/c"));
    try std.testing.expect(!isValidTopicName(""));
    try std.testing.expect(!isValidTopicName("sensor/+/temp"));
    try std.testing.expect(!isValidTopicName("sensor/#"));
}

test "isValidTopicFilter: basic" {
    try std.testing.expect(isValidTopicFilter("sensor/temp"));
    try std.testing.expect(isValidTopicFilter("#"));
    try std.testing.expect(isValidTopicFilter("+"));
    try std.testing.expect(isValidTopicFilter("sensor/+/temp"));
    try std.testing.expect(isValidTopicFilter("sensor/#"));
    try std.testing.expect(!isValidTopicFilter(""));
    try std.testing.expect(!isValidTopicFilter("sensor/temp#"));
    try std.testing.expect(!isValidTopicFilter("sensor/#/temp"));
    try std.testing.expect(!isValidTopicFilter("sensor/te+mp"));
}
```

### 完全一致テスト

```zig
test "topicMatchesFilter: exact match" {
    try std.testing.expect(topicMatchesFilter("sensor/temp", "sensor/temp"));
    try std.testing.expect(!topicMatchesFilter("sensor/temp", "sensor/humidity"));
    try std.testing.expect(!topicMatchesFilter("sensor/temp", "sensor"));
}
```

### 単一レベルワイルドカードテスト

```zig
test "topicMatchesFilter: single-level wildcard (+)" {
    try std.testing.expect(topicMatchesFilter("sensor/temp", "sensor/+"));
    try std.testing.expect(topicMatchesFilter("sensor/humidity", "sensor/+"));
    try std.testing.expect(!topicMatchesFilter("sensor/a/b", "sensor/+"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "+/b/c"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "+/+/+"));
}
```

### 複数レベルワイルドカードテスト

```zig
test "topicMatchesFilter: multi-level wildcard (#)" {
    try std.testing.expect(topicMatchesFilter("sensor/temp", "sensor/#"));
    try std.testing.expect(topicMatchesFilter("sensor/a/b/c", "sensor/#"));
    try std.testing.expect(topicMatchesFilter("sensor", "sensor/#"));
    try std.testing.expect(topicMatchesFilter("anything", "#"));
    try std.testing.expect(topicMatchesFilter("a/b/c", "#"));
}
```

### $SYS 除外テスト

```zig
test "topicMatchesFilter: $SYS exclusion" {
    try std.testing.expect(!topicMatchesFilter("$SYS/info", "#"));
    try std.testing.expect(!topicMatchesFilter("$SYS/info", "+/info"));
    try std.testing.expect(topicMatchesFilter("$SYS/info", "$SYS/#"));
    try std.testing.expect(topicMatchesFilter("$SYS/info", "$SYS/info"));
}
```

### エッジケーステスト

```zig
test "topicMatchesFilter: edge cases" {
    // 空レベル
    try std.testing.expect(topicMatchesFilter("/finance", "/finance"));
    try std.testing.expect(topicMatchesFilter("/finance", "/+"));
    try std.testing.expect(topicMatchesFilter("/finance", "+/+"));
    // sensor/# は sensor 自体にもマッチ
    try std.testing.expect(topicMatchesFilter("sport", "sport/#"));
}
```

### イテレータのテスト

```zig
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
```

### テストの実行

```bash
zig build test
```

---

## std.testing の主要な関数

| 関数 | 説明 |
|------|------|
| `expect(ok)` | `ok` が `true` でなければテスト失敗 |
| `expectEqual(expected, actual)` | 値が一致しなければテスト失敗 |
| `expectEqualStrings(expected, actual)` | 文字列が一致しなければテスト失敗 |
| `expectEqualSlices(T, expected, actual)` | スライスが一致しなければテスト失敗 |
| `std.testing.allocator` | テスト用アロケータ（メモリリーク検出付き）|

`std.testing.expect` は `!void` を返すため、`try` と組み合わせて使う:

```zig
test "example" {
    try std.testing.expect(true);  // OK
    try std.testing.expect(false); // テスト失敗
}
```

---

## マッチングの計算量

- トピックのレベル数を N、フィルタのレベル数を M とすると、マッチングは **O(min(N, M))** で完了する
- `#` が出現した時点で即座に `true` を返せるため、最良ケースは O(1)
- Broker が多数のフィルタを持つ場合、全フィルタに対して線形にマッチングするため、フィルタ数 K に対して **O(K * N)** になる
- 大規模な Broker ではトライ木（Trie）を使って最適化することが多い

---

## Broker での使用例

PUBLISH 受信時に、全購読フィルタに対してマッチングを行う:

```zig
fn distributeMessage(
    topic: []const u8,
    payload: []const u8,
    subscriptions: *SubscriptionManager,
) void {
    var iter = subscriptions.subscriptions.iterator();
    while (iter.next()) |entry| {
        const filter = entry.key_ptr.*;
        if (topicMatchesFilter(topic, filter)) {
            // マッチしたフィルタの全購読者にメッセージを転送
            for (entry.value_ptr.items) |sub| {
                // sub.client_id に対して PUBLISH を送信
                _ = sub;
            }
        }
    }
}
```

`topicMatchesFilter` は純粋関数（副作用なし）であるため、
テストが容易でスレッドセーフである。

---

## まとめ

- **トピック名**は PUBLISH で使用し、ワイルドカードを含まない
- **トピックフィルタ**は SUBSCRIBE で使用し、`+`（単一レベル）と `#`（複数レベル）のワイルドカードを使える
- `$SYS` で始まるトピックは、先頭がワイルドカードのフィルタからは除外される
- `topicMatchesFilter` はレベルごとに逐次比較するシンプルなアルゴリズムで実装でき、計算量は O(min(N, M))
- `isValidTopicName` / `isValidTopicFilter` でバリデーションを行い、不正なトピックを事前に排除する
- `std.testing` で `expect` / `expectEqual` / `expectEqualStrings` を使い、テストケースを網羅的に記述する

これで MQTT v3.1.1 の主要な概念とパケット構造の学習は完了である。
ここまでの知識を組み合わせることで、Pure Zig 0.16 による
MQTT Broker / Client の実装を理解し、拡張できるようになる。
