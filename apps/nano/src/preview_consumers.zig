//! Browser-consumer counts for graff's managed previews (codegraff #941).
//!
//! graff stops a background job that still listens on a port only when
//! `$HOME/.codegraff/preview-consumers.json` holds an explicit 0 for the
//! job's first listening port. A missing, negative or non-integer entry, or
//! an unreadable file, means "unknown" and keeps the job (graff's
//! `src/preview_consumers.zig` and `src/job_browser_guard.zig`). The in-app
//! browser is that consumer, so this app writes the file. The rule is here,
//! as a pure function of the old file and this process's tabs; the locked,
//! atomic file update is `preview_consumers_file.zig`; the contract both
//! sides run is `preview_consumers_vectors.json`.
//!
//! graff reads only the top-level port keys. Under `harness` each writer
//! process keeps its own counts, so a later one can retire them when that
//! process is gone:
//!
//!   {"3000":0,"5173":1,"harness":{"v":1,"writers":[{"pid":7,"start":9,
//!    "ports":{"5173":1},"held":[]}],"zeros":{"3000":1800000000000}}}
//!
//! A port is 0 only after a tab that showed it closed, or its writer quit
//! or died, and no live writer shows or holds it. A port handed to a browser
//! this app cannot see is held: never 0 while its holder lives, and unknown
//! after. Zeros expire after a day, so an old one does not apply to a later
//! server that happens to bind the same port.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const web = @import("browser_url.zig");

pub const rel_dir = ".codegraff";
pub const file_name = "preview-consumers.json";
pub const meta_key = "harness";
pub const version: i64 = 1;
pub const zero_ttl_ms: i64 = 24 * std.time.ms_per_hour;
/// Bounds the file well under graff's 64 KiB read limit. A writer past
/// `max_ports` stores no more counts and suppresses every zero while it lives.
pub const max_ports: usize = 64;
pub const max_zeros: usize = 128;

pub const Writer = struct {
    pid: i64,
    /// Process start identity; 0 when the platform gives none.
    start: u64 = 0,

    pub fn eql(a: Writer, b: Writer) bool {
        return a.pid == b.pid and a.start == b.start;
    }
};

/// Whether a recorded writer process still exists. Only `gone` retires it:
/// a writer that cannot be checked keeps its counts.
pub const Liveness = enum { alive, gone, unknown };
pub const Probe = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (?*anyopaque, Writer) Liveness,
};

/// What this process shows now: the URLs of its browser tabs, and the
/// loopback ports it handed to a browser it cannot see.
pub const Own = struct {
    tabs: []const []const u8 = &.{},
    held: []const u16 = &.{},
};

pub const Use = struct { port: u16, count: u32 };

const Section = struct {
    writer: Writer,
    ports: std.ArrayList(Use) = .empty,
    held: std.ArrayList(u16) = .empty,
    overflow: bool = false,
};
const Zero = struct { port: u16, since: i64 };
const State = struct {
    writers: std.ArrayList(Section) = .empty,
    zeros: std.ArrayList(Zero) = .empty,
};

pub const portOf = web.loopbackPort;

/// Per-port tab counts, ascending by port. Non-loopback tabs are skipped.
pub fn uses(gpa: Allocator, tabs: []const []const u8) ![]Use {
    var out: std.ArrayList(Use) = .empty;
    errdefer out.deinit(gpa);
    for (tabs) |url| {
        const port = portOf(url) orelse continue;
        const at = lowerBound(Use, out.items, port);
        if (at < out.items.len and out.items[at].port == port) {
            out.items[at].count += 1;
        } else try out.insert(gpa, at, .{ .port = port, .count = 1 });
    }
    return out.toOwnedSlice(gpa);
}

fn keyOf(comptime T: type, item: T) u16 {
    return if (T == u16) item else item.port;
}

fn lowerBound(comptime T: type, items: []const T, port: u16) usize {
    var i: usize = 0;
    while (i < items.len and keyOf(T, items[i]) < port) i += 1;
    return i;
}

fn has(comptime T: type, items: []const T, port: u16) bool {
    const at = lowerBound(T, items, port);
    return at < items.len and keyOf(T, items[at]) == port;
}

fn addPort(arena: Allocator, list: *std.ArrayList(u16), port: u16) !void {
    const at = lowerBound(u16, list.items, port);
    if (at < list.items.len and list.items[at] == port) return;
    try list.insert(arena, at, port);
}

fn setZero(arena: Allocator, st: *State, port: u16, now: i64) !void {
    const at = lowerBound(Zero, st.zeros.items, port);
    if (at < st.zeros.items.len and st.zeros.items[at].port == port) {
        st.zeros.items[at].since = now;
    } else try st.zeros.insert(arena, at, .{ .port = port, .since = now });
}

fn clearZero(st: *State, port: u16) void {
    const at = lowerBound(Zero, st.zeros.items, port);
    if (at < st.zeros.items.len and st.zeros.items[at].port == port) _ = st.zeros.orderedRemove(at);
}

/// A writer that quit or died shows nothing now: what it showed is 0, what
/// it held becomes unknown.
fn retire(arena: Allocator, st: *State, sec: Section, now: i64) !void {
    for (sec.ports.items) |u| if (!has(u16, sec.held.items, u.port)) try setZero(arena, st, u.port, now);
    for (sec.held.items) |port| clearZero(st, port);
}

fn int(v: ?json.Value) ?i64 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

fn portKey(key: []const u8) ?u16 {
    const port = std.fmt.parseInt(u16, key, 10) catch return null;
    return if (port == 0) null else port;
}

/// This file's own records. Anything else (a legacy flat file, a newer
/// version, garbage) is no evidence: it parses as no writers and no zeros.
fn parse(arena: Allocator, text: ?[]const u8) !State {
    var st: State = .{};
    const root = json.parseFromSliceLeaky(json.Value, arena, text orelse return st, .{}) catch return st;
    if (root != .object) return st;
    const meta = root.object.get(meta_key) orelse return st;
    if (meta != .object or int(meta.object.get("v")) != version) return st;
    if (meta.object.get("writers")) |writers| if (writers == .array) for (writers.array.items) |w| {
        if (w != .object) continue;
        const pid = int(w.object.get("pid")) orelse continue;
        const start = int(w.object.get("start")) orelse 0;
        var sec: Section = .{ .writer = .{ .pid = pid, .start = if (start > 0) @intCast(start) else 0 } };
        if (w.object.get("ports")) |ports| if (ports == .object) {
            var it = ports.object.iterator();
            while (it.next()) |e| {
                const port = portKey(e.key_ptr.*) orelse continue;
                const n = int(e.value_ptr.*) orelse continue;
                if (n <= 0 or has(Use, sec.ports.items, port)) continue;
                try sec.ports.insert(arena, lowerBound(Use, sec.ports.items, port), .{ .port = port, .count = @intCast(@min(n, std.math.maxInt(u32))) });
            }
        };
        if (w.object.get("held")) |held| if (held == .array) for (held.array.items) |p| {
            const n = int(p) orelse continue;
            if (n > 0 and n <= std.math.maxInt(u16)) try addPort(arena, &sec.held, @intCast(n));
        };
        if (w.object.get("overflow")) |o| sec.overflow = o == .bool and o.bool;
        try st.writers.append(arena, sec);
    };
    if (meta.object.get("zeros")) |zeros| if (zeros == .object) {
        var it = zeros.object.iterator();
        while (it.next()) |e| {
            const port = portKey(e.key_ptr.*) orelse continue;
            try setZero(arena, &st, port, int(e.value_ptr.*) orelse continue);
        }
    };
    return st;
}

/// The next file contents after this writer (`me`) reports what it shows
/// (`own`), or `null` own when it quits. Writers `probe` reports gone are
/// retired. Returns null when the file need not change.
pub fn next(arena: Allocator, old: ?[]const u8, me: Writer, own: ?Own, now: i64, probe: Probe) !?[]u8 {
    var st = try parse(arena, old);
    var mine: ?Section = null;
    var i: usize = 0;
    while (i < st.writers.items.len) {
        const w = st.writers.items[i];
        if (w.writer.eql(me)) {
            mine = w;
        } else if (probe.func(probe.ctx, w.writer) == .gone) {
            try retire(arena, &st, w, now);
        } else {
            i += 1;
            continue;
        }
        _ = st.writers.orderedRemove(i);
    }
    if (own) |o| {
        const shown = try uses(arena, o.tabs);
        var sec: Section = .{ .writer = me };
        if (mine) |m| for (m.held.items) |port| try addPort(arena, &sec.held, port);
        for (o.held) |port| if (port != 0) try addPort(arena, &sec.held, port);
        for (sec.held.items) |port| clearZero(&st, port);
        for (shown) |u| {
            clearZero(&st, u.port);
            if (sec.ports.items.len < max_ports) try sec.ports.append(arena, u) else sec.overflow = true;
        }
        if (mine) |m| for (m.ports.items) |u| {
            if (!has(Use, shown, u.port) and !has(u16, sec.held.items, u.port)) try setZero(arena, &st, u.port, now);
        };
        if (sec.ports.items.len > 0 or sec.held.items.len > 0 or sec.overflow) {
            var at: usize = 0;
            while (at < st.writers.items.len and order(st.writers.items[at].writer, me)) at += 1;
            try st.writers.insert(arena, at, sec);
        }
    } else if (mine) |m| try retire(arena, &st, m, now);
    expire(&st, now);
    if (old == null and st.writers.items.len == 0 and st.zeros.items.len == 0) return null;
    const text = try render(arena, &st);
    if (old) |o| if (std.mem.eql(u8, o, text)) return null;
    return text;
}

fn order(a: Writer, b: Writer) bool {
    return a.pid < b.pid or (a.pid == b.pid and a.start < b.start);
}

fn expire(st: *State, now: i64) void {
    var i: usize = 0;
    while (i < st.zeros.items.len) {
        if (now - st.zeros.items[i].since > zero_ttl_ms) _ = st.zeros.orderedRemove(i) else i += 1;
    }
    while (st.zeros.items.len > max_zeros) {
        var oldest: usize = 0;
        for (st.zeros.items, 0..) |z, ix| if (z.since < st.zeros.items[oldest].since) {
            oldest = ix;
        };
        _ = st.zeros.orderedRemove(oldest);
    }
}

/// What graff reads for `port`: the live tab total, an explicit 0, or
/// nothing (unknown).
fn total(st: *const State, port: u16) ?u64 {
    var sum: u64 = 0;
    var vouched = true;
    for (st.writers.items) |w| {
        for (w.ports.items) |u| if (u.port == port) {
            sum += u.count;
        };
        if (w.overflow or has(u16, w.held.items, port)) vouched = false;
    }
    if (sum > 0) return sum;
    return if (vouched and has(Zero, st.zeros.items, port)) 0 else null;
}

fn render(arena: Allocator, st: *const State) ![]u8 {
    var ports: std.ArrayList(u16) = .empty;
    for (st.writers.items) |w| for (w.ports.items) |u| try addPort(arena, &ports, u.port);
    for (st.zeros.items) |z| try addPort(arena, &ports, z.port);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeByte('{');
    for (ports.items) |port| if (total(st, port)) |n| try w.print("\"{d}\":{d},", .{ port, n });
    try w.print("\"{s}\":{{\"v\":{d},\"writers\":[", .{ meta_key, version });
    for (st.writers.items, 0..) |sec, ix| {
        if (ix > 0) try w.writeByte(',');
        try w.print("{{\"pid\":{d},\"start\":{d},\"ports\":{{", .{ sec.writer.pid, sec.writer.start });
        for (sec.ports.items, 0..) |u, jx| try w.print("{s}\"{d}\":{d}", .{ if (jx > 0) "," else "", u.port, u.count });
        try w.writeAll("},\"held\":[");
        for (sec.held.items, 0..) |port, jx| try w.print("{s}{d}", .{ if (jx > 0) "," else "", port });
        try w.writeByte(']');
        if (sec.overflow) try w.writeAll(",\"overflow\":true");
        try w.writeByte('}');
    }
    try w.writeAll("],\"zeros\":{");
    for (st.zeros.items, 0..) |z, ix| try w.print("{s}\"{d}\":{d}", .{ if (ix > 0) "," else "", z.port, z.since });
    try w.writeAll("}}}\n");
    return out.toOwnedSlice();
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const Fake = struct {
    names: [8][]const u8 = undefined,
    states: [8]Liveness = undefined,
    len: usize = 0,

    fn index(f: *Fake, name: []const u8) usize {
        for (f.names[0..f.len], 0..) |n, ix| if (std.mem.eql(u8, n, name)) return ix;
        f.names[f.len] = name;
        f.states[f.len] = .alive;
        f.len += 1;
        return f.len - 1;
    }

    fn writer(f: *Fake, name: []const u8) Writer {
        const ix = f.index(name);
        return .{ .pid = 100 + @as(i64, @intCast(ix)), .start = 1 + ix };
    }

    fn liveness(ctx: ?*anyopaque, w: Writer) Liveness {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        for (0..f.len) |ix| if (f.writer(f.names[ix]).eql(w)) return f.states[ix];
        return .unknown;
    }
};

fn numericKeys(arena: Allocator, text: ?[]const u8) !json.ObjectMap {
    var out: json.ObjectMap = .empty;
    const root = json.parseFromSliceLeaky(json.Value, arena, text orelse return out, .{}) catch return out;
    if (root != .object) return out;
    var it = root.object.iterator();
    while (it.next()) |e| if (portKey(e.key_ptr.*) != null) try out.put(arena, e.key_ptr.*, e.value_ptr.*);
    return out;
}

test "preview consumer loopback ports match the shared vectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const vectors = try json.parseFromSliceLeaky(json.Value, arena.allocator(), @embedFile("preview_consumers_vectors.json"), .{});
    for (vectors.object.get("port_of").?.array.items) |case| {
        const url = case.object.get("url").?.string;
        const expected: ?u16 = if (int(case.object.get("port"))) |p| @intCast(p) else null;
        if (portOf(url) != expected) std.debug.print("port_of vector failed: {s}\n", .{url});
        try testing.expectEqual(expected, portOf(url));
    }
}

test "preview consumer writer matches the shared vectors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vectors = try json.parseFromSliceLeaky(json.Value, arena, @embedFile("preview_consumers_vectors.json"), .{});
    try testing.expectEqual(zero_ttl_ms, int(vectors.object.get("semantics").?.object.get("zero_ttl_ms")).?);
    const cases = vectors.object.get("writer").?.array.items;
    try testing.expect(cases.len >= 10);
    for (cases) |case| {
        const name = case.object.get("name").?.string;
        errdefer std.debug.print("writer vector failed: {s}\n", .{name});
        var fake: Fake = .{};
        var file: ?[]const u8 = if (case.object.get("initial")) |t| t.string else null;
        var at: i64 = 1_800_000_000_000 - 1;
        for (case.object.get("steps").?.array.items) |step| {
            const s = step.object;
            at = int(s.get("at")) orelse at + 1;
            const who = if (s.get("writer")) |w| w.string else "a";
            const me = fake.writer(who);
            const event = if (s.get("event")) |e| e.string else "tabs";
            var written = false;
            if (std.mem.eql(u8, event, "crash")) {
                fake.states[fake.index(who)] = .gone;
            } else if (std.mem.eql(u8, event, "unknown")) {
                fake.states[fake.index(who)] = .unknown;
            } else {
                var tabs: std.ArrayList([]const u8) = .empty;
                if (s.get("tabs")) |list| for (list.array.items) |t| try tabs.append(arena, t.string);
                var held: std.ArrayList(u16) = .empty;
                if (s.get("hold")) |list| for (list.array.items) |p| try held.append(arena, @intCast(p.integer));
                const quit = std.mem.eql(u8, event, "quit");
                const own: ?Own = if (quit) null else .{ .tabs = tabs.items, .held = held.items };
                if (try next(arena, file, me, own, at, .{ .ctx = &fake, .func = Fake.liveness })) |text| {
                    file = text;
                    written = true;
                }
                if (quit) fake.states[fake.index(who)] = .gone;
            }
            try testing.expectEqual(if (s.get("written")) |w| w.bool else true, written);
            const got = try numericKeys(arena, file);
            const want = s.get("counts").?.object;
            try testing.expectEqual(want.count(), got.count());
            var it = want.iterator();
            while (it.next()) |e| try testing.expectEqual(e.value_ptr.integer, (got.get(e.key_ptr.*) orelse return error.MissingCount).integer);
            // graff's rule (its own runner checks the real reader): only an explicit 0 may stop.
            if (s.get("stop")) |stop| {
                var st = stop.object.iterator();
                while (st.next()) |e| {
                    const zero = if (got.get(e.key_ptr.*)) |v| v == .integer and v.integer == 0 else false;
                    try testing.expectEqual(e.value_ptr.bool, zero);
                }
            }
        }
    }
}

test "preview consumer reader vectors agree with the zero rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const vectors = try json.parseFromSliceLeaky(json.Value, arena.allocator(), @embedFile("preview_consumers_vectors.json"), .{});
    for (vectors.object.get("reader").?.array.items) |case| {
        const keys = try numericKeys(arena.allocator(), case.object.get("file").?.string);
        var buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "{d}", .{case.object.get("port").?.integer});
        const zero = if (keys.get(key)) |v| v == .integer and v.integer == 0 else false;
        try testing.expectEqual(case.object.get("stop").?.bool, zero);
    }
}

test "preview consumer files stay within graff's read limit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{};
    var tabs: std.ArrayList([]const u8) = .empty;
    for (1..400) |port| try tabs.append(arena, try std.fmt.allocPrint(arena, "http://localhost:{d}/", .{port}));
    var file: ?[]const u8 = null;
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    for (names) |name| file = (try next(arena, file, fake.writer(name), .{ .tabs = tabs.items }, 1, .{ .ctx = &fake, .func = Fake.liveness })) orelse file;
    try testing.expect(file.?.len < 64 * 1024);
    // Every writer overflowed: no port it could not store is ever written 0.
    for (names) |name| file = (try next(arena, file, fake.writer(name), .{}, 2, .{ .ctx = &fake, .func = Fake.liveness })) orelse file;
    try testing.expect(file.?.len < 64 * 1024);
    const keys = try numericKeys(arena, file);
    try testing.expectEqual(@as(usize, max_ports), keys.count());
    try testing.expect(keys.get("65") == null and keys.get("399") == null);
}
