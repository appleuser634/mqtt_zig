const std = @import("std");

// ── MQTT v3.1.1 共有型定義 ──────────────────────────────────

/// QoS レベル (MQTT 3.1.1 Section 4.3)
pub const QoS = enum(u2) {
    at_most_once = 0, // QoS 0: 最大1回配信（fire and forget）
    at_least_once = 1, // QoS 1: 最低1回配信（PUBACK で確認）
    exactly_once = 2, // QoS 2: 正確に1回配信（4ステップ）

    pub fn fromInt(val: u2) QoS {
        return @enumFromInt(val);
    }
};

/// MQTT パケットタイプ (MQTT 3.1.1 Section 2.2.1)
pub const PacketType = enum(u4) {
    reserved = 0,
    connect = 1, // C→S: 接続要求
    connack = 2, // S→C: 接続応答
    publish = 3, // 双方向: メッセージ送信
    puback = 4, // 双方向: QoS 1 確認応答
    pubrec = 5, // 双方向: QoS 2 受信確認
    pubrel = 6, // 双方向: QoS 2 解放
    pubcomp = 7, // 双方向: QoS 2 完了
    subscribe = 8, // C→S: トピック購読要求
    suback = 9, // S→C: 購読応答
    unsubscribe = 10, // C→S: 購読解除要求
    unsuback = 11, // S→C: 購読解除応答
    pingreq = 12, // C→S: キープアライブ要求
    pingresp = 13, // S→C: キープアライブ応答
    disconnect = 14, // C→S: 切断通知
    reserved2 = 15,
};

/// CONNACK リターンコード (MQTT 3.1.1 Section 3.2.2.3)
pub const ConnectReturnCode = enum(u8) {
    accepted = 0, // 接続受け入れ
    unacceptable_protocol = 1, // プロトコルバージョン不正
    identifier_rejected = 2, // クライアントID不正
    server_unavailable = 3, // サーバー利用不可
    bad_credentials = 4, // 認証情報不正
    not_authorized = 5, // 認可されていない
    _,
};

/// SUBACK リターンコード (MQTT 3.1.1 Section 3.9.3)
pub const SubackReturnCode = enum(u8) {
    success_qos0 = 0x00,
    success_qos1 = 0x01,
    success_qos2 = 0x02,
    failure = 0x80,
    _,
};

/// MQTT v3.1.1 プロトコル定数
pub const PROTOCOL_NAME = "MQTT";
pub const PROTOCOL_LEVEL: u8 = 4; // MQTT 3.1.1
pub const DEFAULT_PORT: u16 = 1883;
pub const MAX_REMAINING_LENGTH: u32 = 268_435_455; // 256 MB
pub const MAX_PACKET_ID: u16 = 65_535;
pub const MAX_TOPIC_LENGTH: u16 = 65_535;

/// Connect フラグのビット位置
pub const ConnectFlags = packed struct(u8) {
    reserved: u1 = 0, // bit 0: 予約（常に0）
    clean_session: bool = true, // bit 1: クリーンセッション
    will_flag: bool = false, // bit 2: Will フラグ
    will_qos: u2 = 0, // bits 3-4: Will QoS
    will_retain: bool = false, // bit 5: Will Retain
    password_flag: bool = false, // bit 6: パスワードフラグ
    username_flag: bool = false, // bit 7: ユーザー名フラグ
};

/// Allocator の短縮エイリアス
pub const Allocator = std.mem.Allocator;

test "QoS fromInt" {
    try std.testing.expectEqual(QoS.at_most_once, QoS.fromInt(0));
    try std.testing.expectEqual(QoS.at_least_once, QoS.fromInt(1));
    try std.testing.expectEqual(QoS.exactly_once, QoS.fromInt(2));
}

test "ConnectFlags packed layout" {
    const flags = ConnectFlags{ .clean_session = true, .username_flag = true, .password_flag = true };
    const byte: u8 = @bitCast(flags);
    try std.testing.expectEqual(0xC2, byte);
}
