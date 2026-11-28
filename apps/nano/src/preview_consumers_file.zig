//! The file side of `preview_consumers.zig` (codegraff #941). Each update
//! holds an exclusive lock on `preview-consumers.json.lock` while it reads
//! the file, computes the next contents and renames a temporary file over
//! it. graff reads without the lock and so only ever sees a whole file.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("preview_consumers.zig");

/// graff reads the file on macOS and Linux only (its listener probe uses
/// `lsof`); elsewhere nothing is written.
pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;
const retry_ms: i64 = 5 * std.time.ms_per_s;

/// One locked read-modify-write of `dir/preview-consumers.json`. Returns
/// whether the file changed. With no file and nothing to record, nothing
/// (not even the folder) is created.
pub fn update(gpa: Allocator, io: Io, dir: []const u8, me: core.Writer, own: ?core.Own, now_ms: i64, probe: ?core.Probe) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    const path = try std.fs.path.join(arena, &.{ dir, core.file_name });
    if (own) |o| if (o.held.len == 0 and !anyPort(o.tabs)) {
        _ = cwd.statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => {},
        };
    };
    if (own == null) _ = cwd.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => {},
    };
    try cwd.createDirPath(io, dir);
    const lock_path = try std.fmt.allocPrint(arena, "{s}.lock", .{path});
    var lock = try cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = private });
    defer lock.close(io);
    const old: ?[]const u8 = cwd.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => null,
        else => return err,
    };
    var native: Native = .{ .io = io };
    const text = try core.next(arena, old, me, own, now_ms, probe orelse .{ .ctx = &native, .func = Native.liveness }) orelse return false;
    const tmp = try std.fmt.allocPrint(arena, "{s}.{d}.tmp", .{ path, me.pid });
    cwd.writeFile(io, .{ .sub_path = tmp, .data = text, .flags = .{ .permissions = private } }) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
    cwd.rename(tmp, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
    return true;
}

fn same(a: []const core.Use, b: []const core.Use) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.port != y.port or x.count != y.count) return false;
    return true;
}

const private: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);

fn anyPort(tabs: []const []const u8) bool {
    for (tabs) |url| if (core.portOf(url) != null) return true;
    return false;
}

/// This process, as the file records it.
pub fn self(io: Io) core.Writer {
    if (comptime !supported) return .{ .pid = 0 };
    const pid: i64 = std.c.getpid();
    return .{ .pid = pid, .start = startOf(io, pid) };
}

/// The kernel's start time for `pid` (macOS µs since the epoch, Linux
/// clock ticks since boot); 0 when it cannot be read.
fn startOf(io: Io, pid: i64) u64 {
    if (pid <= 0 or pid > std.math.maxInt(i32)) return 0;
    switch (comptime builtin.os.tag) {
        .macos => {
            // `struct proc_bsdinfo` is 136 bytes; `pbi_start_tvsec` and
            // `pbi_start_tvusec` are its last two `uint64_t`s.
            var info: [136]u8 align(8) = undefined;
            if (darwin.proc_pidinfo(@intCast(pid), 3, 0, &info, info.len) != info.len) return 0;
            const sec = std.mem.readInt(u64, info[120..128], .little);
            const usec = std.mem.readInt(u64, info[128..136], .little);
            return sec *% std.time.us_per_s +% usec;
        },
        .linux => {
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return 0;
            var buf: [1024]u8 = undefined;
            const stat = Io.Dir.cwd().readFile(io, path, &buf) catch return 0;
            const stats = @import("preview/discovery.zig").parseLinuxStat(stat) orelse return 0;
            return stats.start_ticks;
        },
        else => return 0,
    }
}

const darwin = struct {
    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;
};

/// `kill(pid, 0)` failing with ESRCH is the only proof a writer is gone;
/// a live pid with a different start identity is a reused pid, so gone too.
/// Anything that cannot be checked keeps the writer.
pub const Native = struct {
    io: Io,

    pub fn liveness(ctx: ?*anyopaque, w: core.Writer) core.Liveness {
        if (comptime !supported) return .unknown;
        const n: *Native = @ptrCast(@alignCast(ctx.?));
        if (w.pid <= 0 or w.pid > std.math.maxInt(i32)) return .gone;
        if (std.c.kill(@intCast(w.pid), @fromBackingInt(@intCast(0))) != 0) {
            return if (std.c.errno(@as(c_int, -1)) == .SRCH) .gone else .unknown;
        }
        if (w.start == 0) return .alive;
        const now = startOf(n.io, w.pid);
        if (now == 0) return .alive;
        return if (now == w.start) .alive else .gone;
    }
};

/// The app's writer. `sync` is level-triggered: called every frame with
/// what the browser shows, it touches the file only when that changed (and
/// once at the first call, to retire writers that died). A failed write is
/// retried on a later frame.
pub const Sink = struct {
    dir: ?[]u8 = null,
    me: core.Writer = .{ .pid = 0 },
    /// Ports handed to a browser this app cannot see.
    held: std.ArrayList(u16) = .empty,
    last: []core.Use = &.{},
    last_held: usize = 0,
    synced: bool = false,
    retry_at_ms: i64 = 0,
    probe: ?core.Probe = null,

    /// `dir` is the folder graff reads: `$HOME/.codegraff`.
    pub fn enable(s: *Sink, gpa: Allocator, io: Io, home: []const u8) void {
        if (comptime !supported) return;
        if (home.len == 0) return;
        s.enableAt(gpa, std.fs.path.join(gpa, &.{ home, core.rel_dir }) catch return, self(io));
    }

    /// Takes ownership of `dir`.
    pub fn enableAt(s: *Sink, gpa: Allocator, dir: []u8, me: core.Writer) void {
        if (s.dir) |old| gpa.free(old);
        s.dir = dir;
        s.me = me;
    }

    pub fn hold(s: *Sink, gpa: Allocator, url: []const u8) void {
        if (s.dir == null) return;
        const port = core.portOf(url) orelse return;
        for (s.held.items) |p| if (p == port) return;
        s.held.append(gpa, port) catch {};
    }

    pub fn sync(s: *Sink, gpa: Allocator, io: Io, tabs: []const []const u8) void {
        const dir = s.dir orelse return;
        const shown = core.uses(gpa, tabs) catch return;
        if (s.synced and s.last_held == s.held.items.len and same(s.last, shown)) {
            gpa.free(shown);
            return;
        }
        const now = Io.Clock.real.now(io).toMilliseconds();
        if (now < s.retry_at_ms) return gpa.free(shown);
        _ = update(gpa, io, dir, s.me, .{ .tabs = tabs, .held = s.held.items }, now, s.probe) catch {
            s.retry_at_ms = now + retry_ms;
            return gpa.free(shown);
        };
        gpa.free(s.last);
        s.last = shown;
        s.last_held = s.held.items.len;
        s.synced = true;
    }

    /// The app is quitting: what it showed is now 0, what it held unknown.
    pub fn leave(s: *Sink, gpa: Allocator, io: Io) void {
        const dir = s.dir orelse return;
        if (!s.synced) return;
        _ = update(gpa, io, dir, s.me, null, Io.Clock.real.now(io).toMilliseconds(), s.probe) catch {};
        s.synced = false;
    }

    pub fn deinit(s: *Sink, gpa: Allocator) void {
        if (s.dir) |d| gpa.free(d);
        gpa.free(s.last);
        s.held.deinit(gpa);
        s.* = .{};
    }
};
