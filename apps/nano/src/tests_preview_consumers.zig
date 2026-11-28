//! codegraff #941: the in-app browser tells graff when a managed preview's
//! last tab closed, through `<home>/.codegraff/preview-consumers.json`.
//! Synthetic tabs, a temporary folder and fake process identities only.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const core = @import("preview_consumers.zig");
const file = @import("preview_consumers_file.zig");
const browser = @import("app_browser.zig");
const Harness = @import("tests_ui_tab_strip.zig").Harness;

const Tmp = struct {
    tmp: testing.TmpDir,
    dir: []u8,

    fn init() !Tmp {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(root);
        return .{ .tmp = tmp, .dir = try std.fs.path.join(testing.allocator, &.{ root, core.rel_dir }) };
    }

    fn deinit(t: *Tmp) void {
        testing.allocator.free(t.dir);
        t.tmp.cleanup();
    }

    fn path(t: *const Tmp, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ t.dir, core.file_name }) catch unreachable;
    }

    /// The file's port counts as graff reads them, as "port=n" pairs in key
    /// order, or null with no file.
    fn counts(t: *const Tmp, arena: std.mem.Allocator) !?[]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const text = Io.Dir.cwd().readFileAlloc(testing.io, t.path(&buf), arena, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        var out: std.ArrayList(u8) = .empty;
        var it = root.object.iterator();
        while (it.next()) |e| {
            _ = std.fmt.parseInt(u16, e.key_ptr.*, 10) catch continue;
            try out.print(arena, "{s}{s}={d}", .{ if (out.items.len > 0) " " else "", e.key_ptr.*, e.value_ptr.integer });
        }
        return out.items;
    }

    fn exists(t: *const Tmp, name: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ t.dir, name }) catch return false;
        _ = Io.Dir.cwd().statFile(testing.io, p, .{}) catch return false;
        return true;
    }
};

fn allAlive(_: ?*anyopaque, _: core.Writer) core.Liveness {
    return .alive;
}
const alive: core.Probe = .{ .func = allAlive };

fn expectCounts(t: *const Tmp, want: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try t.counts(arena.allocator());
    if (want) |w| try testing.expectEqualStrings(w, got orelse return error.NoConsumersFile) else try testing.expect(got == null);
}

fn harness(h: *Harness, t: *const Tmp) !void {
    try h.init(true);
    h.a.preview_consumers.enableAt(testing.allocator, try testing.allocator.dupe(u8, t.dir), .{ .pid = 4242, .start = 7 });
    h.a.preview_consumers.probe = alive;
}

fn openTab(h: *Harness, url: []const u8) void {
    browser.openInternalLink(&h.a, "a", url);
    h.t.settle(1);
}

fn closeTab(h: *Harness, i: usize) void {
    @import("app_panels.zig").closeTab(&h.a, i);
    h.t.settle(1);
}

test "preview consumers: open, open, close, close ends at an explicit zero" {
    if (comptime !file.supported) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    var h: Harness = undefined;
    try harness(&h, &t);
    defer h.deinit();

    openTab(&h, "http://localhost:5173/");
    try expectCounts(&t, "5173=1");
    openTab(&h, "http://localhost:5173/about");
    try expectCounts(&t, "5173=2");
    closeTab(&h, 0);
    try expectCounts(&t, "5173=1");
    closeTab(&h, 0);
    // An explicit 0, not a missing key: graff may now stop the preview.
    try expectCounts(&t, "5173=0");
}

test "preview consumers: a website tab writes nothing" {
    if (comptime !file.supported) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    var h: Harness = undefined;
    try harness(&h, &t);
    defer h.deinit();

    openTab(&h, "https://example.invalid/docs");
    closeTab(&h, 0);
    try expectCounts(&t, null);
    try testing.expect(!t.exists(""));
}

test "preview consumers: two previews are tracked independently" {
    if (comptime !file.supported) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    var h: Harness = undefined;
    try harness(&h, &t);
    defer h.deinit();

    openTab(&h, "http://localhost:5173/");
    openTab(&h, "http://127.0.0.1:3000/");
    try expectCounts(&t, "3000=1 5173=1");
    closeTab(&h, 1);
    try expectCounts(&t, "3000=0 5173=1");
}

test "preview consumers: a preview opened in the system browser is never zeroed" {
    if (comptime !file.supported) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    var h: Harness = undefined;
    try harness(&h, &t);
    defer h.deinit();
    const saved = browser.open_external_url;
    defer browser.open_external_url = saved;
    browser.open_external_url = struct {
        fn open(_: []const u8) bool {
            return true;
        }
    }.open;

    openTab(&h, "http://localhost:5173/");
    browser.openExternalLink(&h.a, "a", "http://localhost:5173/");
    closeTab(&h, 0);
    try expectCounts(&t, "");
}

test "preview consumers: quitting the app zeroes what it showed" {
    if (comptime !file.supported) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    {
        var h: Harness = undefined;
        try harness(&h, &t);
        defer h.deinit();
        openTab(&h, "http://localhost:5173/");
        try expectCounts(&t, "5173=1");
    }
    try expectCounts(&t, "5173=0");
}

/// A pid that existed and is gone: a child that has exited and been reaped.
fn deadPid() !i64 {
    var child = try std.process.spawn(testing.io, .{ .argv = &.{"/usr/bin/true"} });
    const pid: i64 = child.id.?;
    _ = try child.wait(testing.io);
    return pid;
}

test "preview consumers: startup retires a crashed writer and a reused pid" {
    if (comptime !file.supported) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    const me = file.self(testing.io);
    const crashed: core.Writer = .{ .pid = try deadPid(), .start = 11 };
    // Our own pid with another start time: an earlier process that died.
    const reused: core.Writer = .{ .pid = me.pid, .start = me.start +% 1 };
    const now = Io.Clock.real.now(testing.io).toMilliseconds();
    try testing.expect(try file.update(testing.allocator, testing.io, t.dir, crashed, .{ .tabs = &.{"http://localhost:5173/"} }, now, alive));
    try testing.expect(try file.update(testing.allocator, testing.io, t.dir, reused, .{ .tabs = &.{"http://localhost:3000/"} }, now, alive));
    try expectCounts(&t, "3000=1 5173=1");

    // The next start, with the real process checks.
    var sink: file.Sink = .{};
    defer sink.deinit(testing.allocator);
    sink.enableAt(testing.allocator, try testing.allocator.dupe(u8, t.dir), me);
    sink.sync(testing.allocator, testing.io, &.{});
    try expectCounts(&t, "3000=0 5173=0");
}

test "preview consumers: a live writer survives another's startup" {
    if (comptime !file.supported) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    const me = file.self(testing.io);
    const now = Io.Clock.real.now(testing.io).toMilliseconds();
    // This test process stands in for another app instance that is running.
    try testing.expect(try file.update(testing.allocator, testing.io, t.dir, me, .{ .tabs = &.{"http://localhost:5173/"} }, now, alive));
    var sink: file.Sink = .{};
    defer sink.deinit(testing.allocator);
    sink.enableAt(testing.allocator, try testing.allocator.dupe(u8, t.dir), .{ .pid = 4242, .start = 7 });
    sink.sync(testing.allocator, testing.io, &.{});
    try expectCounts(&t, "5173=1");
}

test "preview consumers: concurrent writers lose no count" {
    if (comptime !file.supported) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    const writers = 8;
    const Worker = struct {
        fn run(dir: []const u8, pid: i64, failed: *std.atomic.Value(bool)) void {
            const me: core.Writer = .{ .pid = pid, .start = 1 };
            for (0..25) |i| {
                const tabs: []const []const u8 = if (i % 2 == 0) &.{"http://localhost:5173/"} else &.{};
                _ = file.update(std.heap.page_allocator, testing.io, dir, me, .{ .tabs = tabs }, 1_800_000_000_000, alive) catch failed.store(true, .release);
            }
            _ = file.update(std.heap.page_allocator, testing.io, dir, me, .{ .tabs = &.{"http://localhost:5173/"} }, 1_800_000_000_000, alive) catch failed.store(true, .release);
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [writers]std.Thread = undefined;
    for (&threads, 0..) |*th, i| th.* = try std.Thread.spawn(.{}, Worker.run, .{ t.dir, 9000 + @as(i64, @intCast(i)), &failed });
    for (threads) |th| th.join();
    try testing.expect(!failed.load(.acquire));
    try expectCounts(&t, "5173=8");
}

test "preview consumers: the file is replaced whole, never rewritten in place" {
    if (comptime !file.supported) return error.SkipZigTest;
    var t = try Tmp.init();
    defer t.deinit();
    const me: core.Writer = .{ .pid = 77, .start = 1 };
    try testing.expect(try file.update(testing.allocator, testing.io, t.dir, me, .{ .tabs = &.{"http://localhost:5173/"} }, 1, alive));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/before.json", .{t.dir});
    const cwd = Io.Dir.cwd();
    try cwd.hardLink(t.path(&buf), cwd, link, testing.io, .{});
    const before = try cwd.readFileAlloc(testing.io, link, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(before);

    try testing.expect(try file.update(testing.allocator, testing.io, t.dir, me, .{}, 2, alive));
    // The old inode still holds the whole old file: the new one was renamed in.
    const kept = try cwd.readFileAlloc(testing.io, link, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(before, kept);
    try expectCounts(&t, "5173=0");
    try testing.expect(!t.exists("preview-consumers.json.77.tmp"));
    const st = try cwd.statFile(testing.io, t.path(&buf), .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}
