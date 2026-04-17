const std = @import("std");
const types = @import("mqtt_types");
const Connection = @import("broker_connection");
const Session = @import("broker_session");
const Retain = @import("broker_retain");

const Allocator = types.Allocator;
const net = std.Io.net;

/// MQTT ブローカーサーバー
/// Zig 0.16: Graceful Shutdown 対応
pub const Server = struct {
    allocator: Allocator,
    io: std.Io,
    session_manager: Session.SessionManager,
    retain_store: Retain.RetainStore,
    connections: Connection.ConnectionMap,
    port: u16,

    // Graceful Shutdown: atomic フラグ + Event で安全に停止
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_event: std.Io.Event = .unset,

    pub fn init(allocator: Allocator, io: std.Io, port: u16) Server {
        return .{
            .allocator = allocator,
            .io = io,
            .session_manager = Session.SessionManager.init(allocator, io),
            .retain_store = Retain.RetainStore.init(allocator, io),
            .connections = Connection.ConnectionMap.init(allocator, io),
            .port = port,
        };
    }

    pub fn deinit(self: *Server) void {
        self.connections.deinit();
        self.retain_store.deinit();
        self.session_manager.deinit();
    }

    /// 安全な停止を要求（別スレッドから呼び出し可能）
    pub fn requestShutdown(self: *Server) void {
        self.stop_requested.store(true, .release);
        self.stop_event.set(self.io);
        std.log.info("Shutdown requested", .{});
    }

    /// TCP リスナーを開始し、接続を受け付ける
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
                // Graceful Shutdown 中の accept エラーは正常
                if (self.stop_requested.load(.acquire)) break;
                std.log.err("accept error: {s}", .{@errorName(err)});
                continue;
            };

            if (self.stop_requested.load(.acquire)) {
                stream.close(self.io);
                break;
            }

            const handler = self.allocator.create(Connection.ConnectionHandler) catch {
                stream.close(self.io);
                continue;
            };
            handler.* = .{
                .stream = stream,
                .io = self.io,
                .allocator = self.allocator,
                .session_manager = &self.session_manager,
                .retain_store = &self.retain_store,
                .connections = &self.connections,
            };

            const thread = std.Thread.spawn(.{}, Connection.ConnectionHandler.handle, .{handler}) catch {
                stream.close(self.io);
                self.allocator.destroy(handler);
                continue;
            };
            thread.detach();
        }

        std.log.info("Broker stopped accepting connections", .{});
    }
};
