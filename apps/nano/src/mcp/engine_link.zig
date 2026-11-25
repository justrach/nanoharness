//! The MCP server's link to the engine (`crates/mcp/src/harness.rs`, the
//! transport half): unary calls and scoped watch subscriptions over the
//! engine's RPC frames.
//!
//! `WsEngine` dials the engine's loopback WebSocket lazily on the first tool
//! call (so `initialize` answers before the engine is up), runs one reader
//! thread routing frames by id, and reconnects once when the socket closed
//! under a call.
//!
//! Errors come back as text in the Rust client's wording: `"{method}: {e}"`.
const std = @import("std");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ws = @import("../ws.zig");

/// A unary reply, or the error text the tools surface.
pub const Result = union(enum) {
    ok: json.Value,
    err: []const u8,
};

pub const Next = union(enum) {
    item: json.Value,
    /// The engine ended (or errored) the stream.
    ended,
    /// The deadline passed with nothing new.
    timeout,
};

pub const Subscription = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque, arena: Allocator, timeout_ms: i64) anyerror!Next,
        close: *const fn (ptr: *anyopaque) void,
    };

    /// The next item, waiting at most `timeout_ms`.
    pub fn next(s: Subscription, arena: Allocator, timeout_ms: i64) !Next {
        return s.vtable.next(s.ptr, arena, timeout_ms);
    }

    /// Drops the subscription; the engine-side watch is cancelled at once.
    pub fn close(s: Subscription) void {
        s.vtable.close(s.ptr);
    }
};

pub const Subscribed = union(enum) {
    sub: Subscription,
    err: []const u8,
};

pub const Engine = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        call: *const fn (ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Result,
        subscribe: *const fn (ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Subscribed,
    };

    pub fn call(e: Engine, arena: Allocator, method: []const u8, params_json: []const u8) !Result {
        return e.vtable.call(e.ptr, arena, method, params_json);
    }

    pub fn subscribe(e: Engine, arena: Allocator, method: []const u8, params_json: []const u8) !Subscribed {
        return e.vtable.subscribe(e.ptr, arena, method, params_json);
    }
};

/// First-item wait for a watch snapshot (`SNAPSHOT_TIMEOUT`).
pub const snapshot_timeout_ms: i64 = 15_000;

/// First item of a watch stream, then cancel it (`Harness::snapshot`).
pub fn snapshot(e: Engine, arena: Allocator, method: []const u8, params_json: []const u8) !Result {
    const sub = switch (try e.subscribe(arena, method, params_json)) {
        .sub => |s| s,
        .err => |m| return .{ .err = m },
    };
    defer sub.close();
    return switch (try sub.next(arena, snapshot_timeout_ms)) {
        .item => |v| .{ .ok = v },
        .ended => .{ .err = try std.fmt.allocPrint(arena, "{s}: stream ended before its first snapshot", .{method}) },
        .timeout => .{ .err = try std.fmt.allocPrint(arena, "{s}: no snapshot within {d}s", .{ method, @divTrunc(snapshot_timeout_ms, 1000) }) },
    };
}

/// The wire's error string as the Rust client words it (`wire_error` +
/// `RpcError` display): `unknown method: X` stays as sent, anything else is
/// `Failed(msg)` and displays as the message itself.
fn wireErr(arena: Allocator, method: []const u8, msg: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ method, msg });
}

// ---- WebSocket backend ---------------------------------------------------------

/// How long a unary call waits for its reply before failing.
pub const call_timeout_ms: i64 = 90_000;

pub const WsEngine = struct {
    gpa: Allocator,
    io: Io,
    port: u16,
    /// A unary call's deadline (`call_timeout_ms`; tests shorten it).
    call_timeout_ms: i64 = call_timeout_ms,
    /// Guards everything below. Never held across a socket write or a dial:
    /// the reader thread needs it to hand frames over.
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    conn: ?*Conn = null,
    /// A dial is under way (outside the lock); others wait for it.
    dialing: bool = false,
    closing: bool = false,
    /// Bumped on every dial; a slot from an older connection is dead.
    generation: u64 = 0,
    next_id: u64 = 1,
    slots: std.AutoHashMapUnmanaged(u64, *Slot) = .empty,
    /// Reader threads still running. Each is detached and counts itself
    /// out as it ends, so reconnects leave nothing behind.
    live_readers: usize = 0,
    data_dir: ?[]u8 = null,
    explicit_token: ?[]u8 = null,

    const Slot = struct {
        generation: u64,
        frames: std.ArrayList([]u8) = .empty,
        closed: bool = false,
    };

    /// One socket: its reader holds a reference until it ends, and each
    /// sender holds one while it writes, so the client outlives both.
    const Conn = struct {
        client: *ws.Client,
        generation: u64,
        refs: usize,
        dead: bool = false,
    };

    pub fn init(gpa: Allocator, io: Io, port: u16) WsEngine {
        return .{ .gpa = gpa, .io = io, .port = port };
    }

    pub fn setAuth(self: *WsEngine, data_dir: ?[]const u8, explicit_token: ?[]const u8) !void {
        const next_dir = if (data_dir) |d| try self.gpa.dupe(u8, d) else null;
        errdefer if (next_dir) |d| self.gpa.free(d);
        const next_tok = if (explicit_token) |t| try self.gpa.dupe(u8, t) else null;
        if (self.data_dir) |d| self.gpa.free(d);
        if (self.explicit_token) |t| self.gpa.free(t);
        self.data_dir = next_dir;
        self.explicit_token = next_tok;
    }

    /// Closes the socket and waits for its reader to end. No call may be
    /// in flight.
    pub fn deinit(self: *WsEngine) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        if (self.conn) |c| self.killLocked(c);
        while (self.live_readers > 0 or self.dialing) self.cond.waitUncancelable(self.io, &self.mutex);
        var it = self.slots.iterator();
        while (it.next()) |e| self.freeSlot(e.value_ptr.*);
        self.slots.deinit(self.gpa);
        if (self.data_dir) |d| self.gpa.free(d);
        if (self.explicit_token) |t| self.gpa.free(t);
        self.mutex.unlock(self.io);
    }

    pub fn engine(self: *WsEngine) Engine {
        return .{ .ptr = self, .vtable = &.{ .call = callFn, .subscribe = subscribeFn } };
    }

    /// Reader threads still running: at most one, whatever the reconnects.
    pub fn readerCount(self: *WsEngine) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.live_readers;
    }

    fn url(self: *WsEngine, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "ws://127.0.0.1:{d}", .{self.port}) catch "ws://127.0.0.1";
    }

    fn freeSlot(self: *WsEngine, slot: *Slot) void {
        for (slot.frames.items) |f| self.gpa.free(f);
        slot.frames.deinit(self.gpa);
        self.gpa.destroy(slot);
    }

    /// Marks `c` dead and wakes its reader; slots close as the reader ends.
    /// `mutex` held.
    fn killLocked(self: *WsEngine, c: *Conn) void {
        if (!c.dead) {
            c.dead = true;
            c.client.shutdown();
        }
        if (self.conn == c) self.conn = null;
    }

    /// Drops one reference. `mutex` held.
    fn releaseLocked(self: *WsEngine, c: *Conn) void {
        c.refs -= 1;
        if (c.refs > 0) return;
        c.client.deinit(self.gpa);
        self.gpa.destroy(c);
    }

    fn release(self: *WsEngine, c: *Conn) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.releaseLocked(c);
    }

    const Acquired = union(enum) { conn: *Conn, err: []const u8 };

    /// The live connection with a reference taken, dialing when there is
    /// none (outside the lock).
    fn acquire(self: *WsEngine, arena: Allocator) !Acquired {
        self.mutex.lockUncancelable(self.io);
        while (true) {
            if (self.closing) {
                self.mutex.unlock(self.io);
                return .{ .err = "engine link closed" };
            }
            if (self.conn) |c| {
                c.refs += 1;
                self.mutex.unlock(self.io);
                return .{ .conn = c };
            }
            if (!self.dialing) break;
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        self.dialing = true;
        self.mutex.unlock(self.io);

        const tok = ws.resolveIpcToken(self.gpa, self.io, self.explicit_token, self.data_dir, self.port, true);
        defer if (tok) |t| self.gpa.free(t);
        const dialed = ws.Client.connectWithBearer(self.gpa, self.io, self.port, "/", tok);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dialing = false;
        self.cond.broadcast(self.io);
        const client = dialed catch |err| {
            var buf: [64]u8 = undefined;
            return .{ .err = try std.fmt.allocPrint(arena, "no Harness engine listening at {s} (transport: {t}) — is Harness running?", .{ self.url(&buf), err }) };
        };
        if (self.closing) {
            client.deinit(self.gpa);
            return .{ .err = "engine link closed" };
        }
        const c = self.gpa.create(Conn) catch |err| {
            client.deinit(self.gpa);
            return err;
        };
        self.generation += 1;
        // The reader's reference and the caller's.
        c.* = .{ .client = client, .generation = self.generation, .refs = 2 };
        const t = std.Thread.spawn(.{}, readLoop, .{ self, c }) catch |err| {
            client.deinit(self.gpa);
            self.gpa.destroy(c);
            return .{ .err = try std.fmt.allocPrint(arena, "engine reader: {t}", .{err}) };
        };
        t.detach();
        self.live_readers += 1;
        self.conn = c;
        return .{ .conn = c };
    }

    fn readLoop(self: *WsEngine, c: *Conn) void {
        const gpa = self.gpa;
        var msg: std.ArrayList(u8) = .empty;
        while (true) {
            const op = c.client.readMessage(gpa, &msg) catch break;
            if (op != .text) continue;
            const id = frameId(msg.items) orelse continue;
            const copy = gpa.dupe(u8, msg.items) catch continue;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.slots.get(id)) |slot| {
                if (slot.generation == c.generation) {
                    slot.frames.append(gpa, copy) catch gpa.free(copy);
                    self.cond.broadcast(self.io);
                    continue;
                }
            }
            gpa.free(copy);
        }
        msg.deinit(gpa);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.killLocked(c);
        var it = self.slots.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.generation == c.generation) e.value_ptr.*.closed = true;
        }
        self.releaseLocked(c);
        self.live_readers -= 1;
        // Last: after this broadcast `deinit` may return and free `self`.
        self.cond.broadcast(self.io);
    }

    fn frameId(text: []const u8) ?u64 {
        // `{"id":N,...}`: the engine always writes the id first.
        const key = "\"id\":";
        const at = std.mem.indexOf(u8, text, key) orelse return null;
        var i = at + key.len;
        var n: u64 = 0;
        var digits: usize = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            n = n *% 10 +% (text[i] - '0');
            digits += 1;
        }
        return if (digits > 0) n else null;
    }

    const Opened = union(enum) { slot: struct { id: u64, slot: *Slot }, err: []const u8, closed };

    /// Registers a slot, then sends the call frame without the lock.
    fn open(self: *WsEngine, arena: Allocator, method: []const u8, params_json: []const u8) !Opened {
        const c = switch (try self.acquire(arena)) {
            .conn => |c| c,
            .err => |m| return .{ .err = m },
        };
        defer self.release(c);
        self.mutex.lockUncancelable(self.io);
        if (c.dead) {
            self.mutex.unlock(self.io);
            return .closed;
        }
        const id = self.next_id;
        self.next_id += 1;
        const slot = self.gpa.create(Slot) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        slot.* = .{ .generation = c.generation };
        self.slots.put(self.gpa, id, slot) catch |err| {
            self.gpa.destroy(slot);
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        const frame = try std.fmt.allocPrint(arena, "{{\"id\":{d},\"method\":{f},\"params\":{s}}}", .{ id, json.fmt(method, .{}), params_json });
        c.client.sendText(frame) catch {
            self.mutex.lockUncancelable(self.io);
            self.killLocked(c);
            self.mutex.unlock(self.io);
            self.drop(id, false);
            return .closed;
        };
        return .{ .slot = .{ .id = id, .slot = slot } };
    }

    fn drop(self: *WsEngine, id: u64, send_cancel: bool) void {
        self.mutex.lockUncancelable(self.io);
        const removed = self.slots.fetchRemove(id) orelse {
            self.mutex.unlock(self.io);
            return;
        };
        const slot = removed.value;
        // The cancel goes out on the slot's own connection, without the lock.
        const target: ?*Conn = if (send_cancel and !slot.closed) blk: {
            const c = self.conn orelse break :blk null;
            if (c.dead or c.generation != slot.generation) break :blk null;
            c.refs += 1;
            break :blk c;
        } else null;
        self.freeSlot(slot);
        self.mutex.unlock(self.io);
        if (target) |c| {
            defer self.release(c);
            var buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cancel\":true}}", .{id})) |frame| {
                c.client.sendText(frame) catch {};
            } else |_| {}
        }
    }

    const Taken = union(enum) { frame: []u8, closed, timeout };

    /// Waits for the next frame of `slot` until `deadline` (none: forever).
    fn take(self: *WsEngine, slot: *Slot, deadline: ?Io.Clock.Timestamp) Taken {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (slot.frames.items.len == 0 and !slot.closed) {
            if (deadline) |d| {
                self.cond.waitTimeout(self.io, &self.mutex, .{ .deadline = d }) catch return if (slot.frames.items.len > 0) .{ .frame = slot.frames.orderedRemove(0) } else if (slot.closed) .closed else .timeout;
            } else {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
        }
        if (slot.frames.items.len == 0) return .closed;
        return .{ .frame = slot.frames.orderedRemove(0) };
    }

    const Once = union(enum) { result: Result, closed };

    fn callOnce(self: *WsEngine, arena: Allocator, method: []const u8, params_json: []const u8) !Once {
        const opened = try self.open(arena, method, params_json);
        const o = switch (opened) {
            .slot => |s| s,
            .err => |m| return .{ .result = .{ .err = m } },
            .closed => return .closed,
        };
        defer self.drop(o.id, false);
        const deadline = Io.Clock.Timestamp.fromNow(self.io, .{ .raw = .fromMilliseconds(@max(0, self.call_timeout_ms)), .clock = .awake });
        while (true) {
            const raw = switch (self.take(o.slot, deadline)) {
                .frame => |f| f,
                .closed => return .closed,
                .timeout => return .{ .result = .{ .err = try std.fmt.allocPrint(arena, "{s}: no reply from the engine within {d}s", .{ method, @divTrunc(self.call_timeout_ms + 999, 1000) }) } },
            };
            defer self.gpa.free(raw);
            const frame = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .allocate = .alloc_always });
            if (frame != .object) continue;
            if (frame.object.get("err")) |e| {
                return .{ .result = .{ .err = try wireErr(arena, method, if (e == .string) e.string else "error") } };
            }
            if (frame.object.get("ok")) |v| return .{ .result = .{ .ok = v } };
            // A stream answered a unary call: its first item stands in.
            if (frame.object.get("item")) |v| return .{ .result = .{ .ok = v } };
        }
    }

    fn callFn(ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Result {
        const self: *WsEngine = @ptrCast(@alignCast(ptr));
        switch (try self.callOnce(arena, method, params_json)) {
            .result => |r| return r,
            .closed => {},
        }
        // Closed underneath: the engine restarted. Dial once more.
        switch (try self.callOnce(arena, method, params_json)) {
            .result => |r| return r,
            .closed => {},
        }
        return .{ .err = try std.fmt.allocPrint(arena, "{s}: connection closed", .{method}) };
    }

    const WsSub = struct {
        owner: *WsEngine,
        id: u64,
        slot: *Slot,
        method: []const u8,
    };

    fn subscribeFn(ptr: *anyopaque, arena: Allocator, method: []const u8, params_json: []const u8) anyerror!Subscribed {
        const self: *WsEngine = @ptrCast(@alignCast(ptr));
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            switch (try self.open(arena, method, params_json)) {
                .err => |m| return .{ .err = m },
                .closed => continue,
                .slot => |o| {
                    const s = try self.gpa.create(WsSub);
                    s.* = .{ .owner = self, .id = o.id, .slot = o.slot, .method = method };
                    return .{ .sub = .{ .ptr = s, .vtable = &.{ .next = subNext, .close = subClose } } };
                },
            }
        }
        return .{ .err = try std.fmt.allocPrint(arena, "{s}: connection closed", .{method}) };
    }

    fn subNext(ptr: *anyopaque, arena: Allocator, timeout_ms: i64) anyerror!Next {
        const s: *WsSub = @ptrCast(@alignCast(ptr));
        const io = s.owner.io;
        const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(@max(0, timeout_ms)), .clock = .awake });
        while (true) {
            const raw = switch (s.owner.take(s.slot, deadline)) {
                .frame => |f| f,
                .closed => return .ended,
                .timeout => return .timeout,
            };
            defer s.owner.gpa.free(raw);
            const frame = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .allocate = .alloc_always });
            if (frame != .object) continue;
            if (frame.object.get("item")) |v| return .{ .item = v };
            if (frame.object.get("err") != null) return .ended;
            if (frame.object.get("done")) |d| if (d == .bool and d.bool) return .ended;
            // `ok` opens a checked stream; keep reading.
        }
    }

    fn subClose(ptr: *anyopaque) void {
        const s: *WsSub = @ptrCast(@alignCast(ptr));
        const owner = s.owner;
        owner.drop(s.id, true);
        owner.gpa.destroy(s);
    }
};

const testing = std.testing;

test "mcp engine link: frame ids parse and an absent engine is reported like the Rust client" {
    try testing.expectEqual(@as(?u64, 42), WsEngine.frameId("{\"id\":42,\"ok\":{}}"));
    try testing.expectEqual(@as(?u64, null), WsEngine.frameId("{\"ok\":{}}"));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Port 1 on loopback: nothing listens there.
    var link = WsEngine.init(testing.allocator, testing.io, 1);
    defer link.deinit();
    const r = try link.engine().call(arena, "LocalDevice", "{}");
    try testing.expect(r == .err);
    try testing.expect(std.mem.startsWith(u8, r.err, "no Harness engine listening at ws://127.0.0.1:1 ("));
    try testing.expect(std.mem.endsWith(u8, r.err, ") — is Harness running?"));
}
