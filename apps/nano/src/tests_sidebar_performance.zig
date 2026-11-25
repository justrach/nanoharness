//! Production Cmd+B frames with synthetic grouped session histories.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const Sample = struct { nodes: usize, ms: f64 };
fn sample(groups: usize) !Sample {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = true;
    a.settings.setText("surface", "opaque");
    a.settings.setText("sidebarOrganization", "byProject");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var spaces: std.ArrayList(u8) = .empty;
    var chats: std.ArrayList(u8) = .empty;
    try spaces.appendSlice(alloc, "[");
    try chats.appendSlice(alloc, "[");
    for (0..groups) |i| {
        if (i > 0) {
            try spaces.appendSlice(alloc, ",");
            try chats.appendSlice(alloc, ",");
        }
        try spaces.print(alloc, "{{\"id\":\"project-{d}\",\"deviceId\":\"d\",\"path\":\"/synthetic/project-{d}\"}}", .{ i, i });
        try chats.print(alloc, "{{\"id\":\"chat-{d}\",\"deviceId\":\"d\",\"spaceId\":\"project-{d}\",\"title\":\"Synthetic session {d}\",\"archived\":false}}", .{ i, i, i });
    }
    try spaces.appendSlice(alloc, "]");
    try chats.appendSlice(alloc, "]");
    try a.spaces.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, spaces.items, .{}));
    try a.chats.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, chats.items, .{}));
    a.openChat("chat-0", null);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
    defer t.deinit();
    t.settle(0.4);
    var peak: usize = 0;
    var elapsed: i96 = 0;
    // Real shortcut dispatch, both opening and closing, not a fake width loop.
    for (0..2) |_| {
        _ = t.shortcut(.{ .key = 'b', .cmd = true });
        for (0..16) |_| {
            const start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
            t.advance(1.0 / 120.0);
            elapsed += std.Io.Clock.awake.now(testing.io).toNanoseconds() - start;
            peak = @max(peak, t.ctx.nodes.items.len);
        }
        t.advance(0.3);
    }
    try testing.expect(a.view.sidebar_open);
    try testing.expect(t.hasText("Synthetic session 0"));
    return .{ .nodes = peak, .ms = @as(f64, @floatFromInt(elapsed)) / 1e6 / 32 };
}

test "Cmd+B grouped sidebar frame work stays near the viewport" {
    @import("theme.zig").registerFonts();
    const small = try sample(8);
    const large = try sample(1024);
    std.debug.print("\nSynthetic Cmd+B: 8 projects={d:.2}ms/{d} nodes, 1024 projects={d:.2}ms/{d} nodes\n", .{ small.ms, small.nodes, large.ms, large.nodes });
    try testing.expect(large.nodes < small.nodes * 2);
    // Node growth is the viewport contract. Raw timing for 8 versus 1024
    // groups also includes legitimate O(N) indexing, so it is diagnostic,
    // not a constant-factor guarantee. Compare equal workloads below.
}

test "Cmd+B group indexing avoids the former repeated full-list scans" {
    const workspace = @import("workspace.zig");
    const Index = @import("sidebar_groups.zig").Index;
    const Item = struct { listed: bool = true, pinned: bool = false, row_h: f32 = 38, group_key: []const u8 };
    const n = 4096;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const chats = try alloc.alloc(workspace.Chat, n);
    const items = try alloc.alloc(Item, n);
    for (chats, items, 0..) |*chat, *item, i| {
        const key = try std.fmt.allocPrint(alloc, "project-{d}", .{i});
        chat.* = .{ .id = key, .title = null, .space_id = key, .archived = false, .preview = null, .harness = null, .model = null, .cwd = null };
        item.* = .{ .group_key = key };
    }
    var legacy_ns: i96 = std.math.maxInt(i96);
    var indexed_ns: i96 = std.math.maxInt(i96);
    // Best of three removes scheduler pauses, not actual algorithmic work.
    // Each trial checks the same 4096 memberships on both implementations.
    for (0..3) |_| {
        var matches: usize = 0;
        const start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        for (items) |group| for (chats) |chat| {
            if (std.mem.eql(u8, group.group_key, chat.space_id.?)) matches += 1;
        };
        legacy_ns = @min(legacy_ns, std.Io.Clock.awake.now(testing.io).toNanoseconds() - start);
        try testing.expectEqual(@as(usize, n), matches);
        var frame: std.heap.ArenaAllocator = .init(testing.allocator);
        defer frame.deinit();
        const indexed_start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        const index = try Index.build(frame.allocator(), chats, items);
        indexed_ns = @min(indexed_ns, std.Io.Clock.awake.now(testing.io).toNanoseconds() - indexed_start);
        try testing.expectEqual(@as(usize, n), index.groups.items.len);
        for (index.groups.items) |group| try testing.expectEqual(@as(usize, 1), group.count);
    }
    std.debug.print("\nSynthetic equal-work Cmd+B grouping: repeated scans={d}us, indexed={d}us\n", .{ @divTrunc(legacy_ns, 1000), @divTrunc(indexed_ns, 1000) });
    try testing.expect(indexed_ns * 2 < legacy_ns);
}

fn sampleZen(groups: usize) !Sample {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = false;
    a.settings.setText("surface", "opaque");
    a.settings.applyUiMode(.zen);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var spaces: std.ArrayList(u8) = .empty;
    var chats: std.ArrayList(u8) = .empty;
    try spaces.appendSlice(alloc, "[");
    try chats.appendSlice(alloc, "[");
    for (0..groups) |i| {
        if (i > 0) {
            try spaces.appendSlice(alloc, ",");
            try chats.appendSlice(alloc, ",");
        }
        const archived = i % 5 == 0 and i > 0;
        try spaces.print(alloc, "{{\"id\":\"project-{d}\",\"deviceId\":\"d\",\"name\":\"Proj {d}\",\"path\":\"/synthetic/project-{d}\"}}", .{ i, i, i });
        try chats.print(alloc, "{{\"id\":\"chat-{d}\",\"deviceId\":\"d\",\"spaceId\":\"project-{d}\",\"title\":\"Synthetic Zen Session {d} with a reasonably long title for ellipsis truncation\",\"archived\":{s}}}", .{ i, i, i, if (archived) "true" else "false" });
    }
    try spaces.appendSlice(alloc, "]");
    try chats.appendSlice(alloc, "]");
    try a.spaces.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, spaces.items, .{}));
    try a.chats.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, chats.items, .{}));
    a.openChat("chat-0", null);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = false });
    defer t.deinit();
    t.settle(0.4);
    var peak: usize = 0;
    var elapsed: i96 = 0;
    for (0..2) |_| {
        _ = t.shortcut(.{ .key = 'b', .cmd = true });
        for (0..16) |_| {
            const start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
            t.advance(1.0 / 120.0);
            elapsed += std.Io.Clock.awake.now(testing.io).toNanoseconds() - start;
            peak = @max(peak, t.ctx.nodes.items.len);
        }
        t.advance(0.3);
    }
    try testing.expect(a.view.sidebar_open);
    try testing.expect(t.hasText("Archived"));
    return .{ .nodes = peak, .ms = @as(f64, @floatFromInt(elapsed)) / 1e6 / 32 };
}

test "Cmd+B Zen sidebar frame work stays near the viewport" {
    @import("theme.zig").registerFonts();
    const small = try sampleZen(32);
    const large = try sampleZen(1024);
    std.debug.print("\nSynthetic Zen Cmd+B: 32 sessions={d:.2}ms/{d} nodes, 1024 sessions={d:.2}ms/{d} nodes\n", .{ small.ms, small.nodes, large.ms, large.nodes });
    try testing.expect(large.nodes < small.nodes * 2);
}

test "Cmd+B Zen row and footer indexing is at least 5x faster than repeated scans" {
    const sidebar = @import("view_sidebar.zig");
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.settings.applyUiMode(.zen);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var spaces: std.ArrayList(u8) = .empty;
    var chats: std.ArrayList(u8) = .empty;
    var sessions: std.ArrayList(u8) = .empty;
    try spaces.appendSlice(alloc, "[");
    try chats.appendSlice(alloc, "[");
    try sessions.appendSlice(alloc, "[");
    const n_spaces = 256;
    const n_chats = 1024;
    for (0..n_spaces) |i| {
        if (i > 0) try spaces.appendSlice(alloc, ",");
        try spaces.print(alloc, "{{\"id\":\"sp-{d}\",\"deviceId\":\"d\",\"name\":\"Space {d}\",\"path\":\"/synthetic/sp-{d}\"}}", .{ i, i, i });
    }
    var first_sess = true;
    for (0..n_chats) |i| {
        if (i > 0) try chats.appendSlice(alloc, ",");
        const sid = i % n_spaces;
        const archived = i % 5 == 0;
        try chats.print(alloc, "{{\"id\":\"ch-{d}\",\"deviceId\":\"d\",\"spaceId\":\"sp-{d}\",\"title\":\"Chat {d}\",\"archived\":{s}}}", .{ i, sid, i, if (archived) "true" else "false" });
        if (i % 4 == 0) {
            if (!first_sess) try sessions.appendSlice(alloc, ",");
            first_sess = false;
            try sessions.print(alloc, "{{\"chatId\":\"ch-{d}\",\"status\":\"running\",\"updatedAt\":\"2026-11-15T10:00:00Z\"}}", .{i});
        }
    }
    try spaces.appendSlice(alloc, "]");
    try chats.appendSlice(alloc, "]");
    try sessions.appendSlice(alloc, "]");
    try a.spaces.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, spaces.items, .{}));
    try a.chats.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, chats.items, .{}));
    try a.sessions.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, sessions.items, .{}));

    var legacy_ns: i96 = std.math.maxInt(i96);
    var indexed_ns: i96 = std.math.maxInt(i96);
    var want_archived: usize = 0;
    for (0..3) |_| {
        // Legacy path: full `listed` scan for `zenFooter` archived badge + repeated `listed` + 2x `rowMark` on visible rows.
        const legacy_start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        var arch_n: usize = 0;
        var vis_marks: usize = 0;
        for (a.chats.items, 0..) |ch, idx| {
            if (!sidebar.listed(&a, ch)) continue;
            if (ch.archived) arch_n += 1;
            if (idx < 32 and !ch.archived) {
                if (sidebar.rowMark(&a, ch) == .awaiting_input) vis_marks += 1;
                if (sidebar.rowMark(&a, ch) != .idle) vis_marks += 1;
            }
        }
        for (a.chats.items) |ch| if (ch.archived and sidebar.listed(&a, ch)) {
            arch_n +%= 1;
        };
        std.mem.doNotOptimizeAway(vis_marks);
        legacy_ns = @min(legacy_ns, std.Io.Clock.awake.now(testing.io).toNanoseconds() - legacy_start);
        want_archived = arch_n / 2;

        var frame: std.heap.ArenaAllocator = .init(testing.allocator);
        defer frame.deinit();
        const idx_start = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        const res = sidebar.zenIndexPass(&a, frame.allocator());
        indexed_ns = @min(indexed_ns, std.Io.Clock.awake.now(testing.io).toNanoseconds() - idx_start);
        try testing.expectEqual(want_archived, res.archived);
    }
    std.debug.print("\nSynthetic equal-work Zen Cmd+B indexing: legacy={d}us, indexed={d}us\n", .{ @divTrunc(legacy_ns, 1000), @divTrunc(indexed_ns, 1000) });
    try testing.expect(indexed_ns * 5 < legacy_ns);
}

// ---- Fullscreen Cmd+B ------------------------------------------------------

/// One Cmd+B direction, at 120 Hz simulated time, in CPU ms per frame
/// (build + layout + paint; GPU presentation is not measured here).
const Phase = struct {
    press_ms: f64 = 0,
    build_ms: f64 = 0,
    layout_ms: f64 = 0,
    paint_ms: f64 = 0,
    worst_ms: f64 = 0,
    settle_ms: f64 = 0,
    after_ms: f64 = 0,
    frames: usize = 0,
    after_frames: usize = 0,
    nodes: usize = 0,
    settle_nodes: usize = 0,
    passes: u32 = 0,

    fn tween(p: Phase) f64 {
        return p.build_ms + p.layout_ms + p.paint_ms;
    }
};

const Toggle = struct { first_open: Phase, first_close: Phase, open: Phase, close: Phase };

const Split = struct {
    full_screen: bool,
    panes: usize,
    width: f32 = 1728,
    height: f32 = 1117,
    turns: usize = 60,
    /// A live window culls the settled transcript too; a scene doesn't.
    live: bool = true,
};

const words = [_][]const u8{ "draft", "layout", "pane", "reader", "evidence", "column", "margin", "harbor", "cedar", "rowan", "sidebar", "review", "measure", "paragraph", "settle", "width", "because", "before", "after", "the", "a", "with", "keeps", "moves", "shows", "wraps", "quietly", "against", "every", "second" };

/// Made-up prose no two rows share: repeated text would be shaped once and
/// hide what a long real conversation costs.
fn prose(out: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random, n: usize) !void {
    for (0..n) |i| try out.print(alloc, "{s}{s}", .{ if (i > 0) " " else "", words[rng.uintLessThan(usize, words.len)] });
    try out.print(alloc, " {d}.", .{rng.int(u16)});
}

fn markdownReset(alloc: std.mem.Allocator, pane: usize, turns: usize) ![]const u8 {
    var prng: std.Random.DefaultPrng = .init(0x9e37 + pane);
    const rng = prng.random();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "{\"reset\":[");
    for (0..turns) |i| {
        if (i > 0) try out.appendSlice(alloc, ",");
        try out.print(alloc, "{{\"id\":\"u-{d}-{d}\",\"role\":\"user\",\"parts\":[{{\"id\":\"p\",\"kind\":\"text\",\"text\":\"", .{ pane, i });
        try prose(&out, alloc, rng, 18);
        try out.print(alloc, "\"}}]}},{{\"id\":\"a-{d}-{d}\",\"role\":\"assistant\",\"status\":\"complete\",\"parts\":[{{\"id\":\"p\",\"kind\":\"text\",\"text\":\"## Finding {d}\\n\\n", .{ pane, i, i });
        try prose(&out, alloc, rng, 60);
        for (0..3) |_| {
            try out.appendSlice(alloc, "\\n\\n- A **bold** point with `code` and ");
            try prose(&out, alloc, rng, 16);
        }
        try out.print(alloc, "\\n\\n```zig\\nconst pane = {d};\\nconst turn = {d};\\n```\\n\\n", .{ pane, i });
        try prose(&out, alloc, rng, 40);
        try out.appendSlice(alloc, "\"}]}");
    }
    try out.appendSlice(alloc, "]}");
    return out.items;
}

const Shell = struct {
    a: App,
    t: ui.Tester,

    /// The production shell over `s.panes` long Markdown chats, settled with
    /// the sidebar closed.
    fn init(h: *Shell, alloc: std.mem.Allocator, s: Split) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        errdefer h.a.deinit();
        h.a.offscreen = !s.live;
        h.a.dark = true;
        h.a.settings.setText("surface", "opaque");
        h.a.settings.setText("sidebarOrganization", "byProject");
        var spaces: std.ArrayList(u8) = .empty;
        var chats: std.ArrayList(u8) = .empty;
        try spaces.appendSlice(alloc, "[");
        try chats.appendSlice(alloc, "[");
        for (0..8) |i| try spaces.print(alloc, "{s}{{\"id\":\"project-{d}\",\"deviceId\":\"d\",\"path\":\"/synthetic/project-{d}\"}}", .{ if (i > 0) "," else "", i, i });
        for (0..48) |i| try chats.print(alloc, "{s}{{\"id\":\"chat-{d}\",\"deviceId\":\"d\",\"spaceId\":\"project-{d}\",\"title\":\"Synthetic session {d}\",\"archived\":false}}", .{ if (i > 0) "," else "", i, i % 8, i });
        try spaces.appendSlice(alloc, "]");
        try chats.appendSlice(alloc, "]");
        try h.a.spaces.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, spaces.items, .{}));
        try h.a.chats.replace(try std.json.parseFromSliceLeaky(std.json.Value, alloc, chats.items, .{}));
        h.a.openChat("chat-0", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = s.width, .height = s.height, .dark = true });
        errdefer h.t.deinit();
        h.t.dt = 1.0 / 120.0;
        h.t.settle(0.5);
        for (1..s.panes) |i| {
            h.a.splitPane(.horizontal);
            h.a.openChat(try std.fmt.allocPrint(alloc, "chat-{d}", .{i}), null);
            h.t.settle(0.5);
        }
        const focused = h.a.selected.?;
        for (0..s.panes) |i| {
            const id = try std.fmt.allocPrint(alloc, "chat-{d}", .{i});
            const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, try markdownReset(alloc, i, s.turns), .{});
            if (std.mem.eql(u8, id, focused)) {
                try h.a.transcript.apply(value);
            } else {
                const peer = h.a.peer(id) orelse return error.MissingPeer;
                try peer.transcript.apply(value);
            }
        }
        h.t.settle(1);
        if (s.full_screen) h.a.setFullScreen(true) else h.a.view.sidebar_open = false;
        // At rest, with every row's height known at this width.
        h.t.settle(20);
        try testing.expect(!h.t.ctx.animating);
        for (0..4) |_| h.t.frame();
        try testing.expectEqual(@as(f32, 0), h.a.view.sidebar_width);
    }

    fn deinit(h: *Shell) void {
        h.t.deinit();
        h.a.deinit();
    }

    /// The former slide end: a row culled at another width forgets that its
    /// height is only old, and remounts with every other one at once.
    fn forgetStale(h: *Shell) void {
        for (h.a.transcript.entries.items) |*e| e.measured_w = @max(0, e.measured_w);
        for (h.a.peers.items) |*p| for (p.transcript.entries.items) |*e| {
            e.measured_w = @max(0, e.measured_w);
        };
    }

    fn cost(h: *Shell) f64 {
        const st = h.t.ctx.stats;
        return st.build_ms + st.layout_ms + st.paint_ms;
    }

    /// Cmd+B through the real shortcut, then every frame to rest.
    fn toggle(h: *Shell, former: bool) !Phase {
        var p: Phase = .{};
        _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
        p.press_ms = h.cost();
        p.passes = h.t.ctx.stats.passes;
        while (true) {
            if (former) h.forgetStale();
            h.t.frame();
            const st = h.t.ctx.stats;
            const ms = h.cost();
            p.passes = @max(p.passes, st.passes);
            if (h.a.view.sidebar_tween == null) {
                p.settle_ms = ms;
                p.settle_nodes = st.nodes;
                break;
            }
            p.frames += 1;
            p.build_ms += st.build_ms;
            p.layout_ms += st.layout_ms;
            p.paint_ms += st.paint_ms;
            p.worst_ms = @max(p.worst_ms, ms);
            p.nodes = @max(p.nodes, st.nodes);
            if (p.frames > 200) return error.NeverSettled;
        }
        const n: f64 = @floatFromInt(@max(1, p.frames));
        p.build_ms /= n;
        p.layout_ms /= n;
        p.paint_ms /= n;
        // Whatever the slide left to do, until the window rests.
        while (h.t.ctx.animating) {
            h.t.frame();
            p.after_ms = @max(p.after_ms, h.cost());
            p.after_frames += 1;
            if (p.after_frames > 2000) return error.NeverRested;
        }
        for (0..4) |_| h.t.frame();
        return p;
    }
};

/// The best of `trials` toggles each way (a scheduler pause is not work),
/// beside the first, which also pays for text no frame has wrapped yet.
fn measure(s: Split, trials: usize, former: bool) !Toggle {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: Shell = undefined;
    try h.init(arena.allocator(), s);
    defer h.deinit();
    const first_open = try h.toggle(former);
    const first_close = try h.toggle(former);
    var best: Toggle = .{ .first_open = first_open, .first_close = first_close, .open = first_open, .close = first_close };
    for (1..trials) |_| {
        const open = try h.toggle(former);
        const close = try h.toggle(former);
        if (open.tween() < best.open.tween()) best.open = open;
        if (close.tween() < best.close.tween()) best.close = close;
        best.first_open.settle_ms = @min(best.first_open.settle_ms, open.settle_ms);
        best.first_close.settle_ms = @min(best.first_close.settle_ms, close.settle_ms);
    }
    return best;
}

fn printPhase(name: []const u8, dir: []const u8, p: Phase) void {
    std.debug.print("{s:<32} {s:<6} press {d:6.2} | tween {d:5.2} (b {d:5.2} l {d:5.2} p {d:5.2}) worst {d:6.2} x{d} | slide end {d:7.2} | after {d:6.2} x{d} | nodes {d}/{d} passes {d}\n", .{ name, dir, p.press_ms, p.tween(), p.build_ms, p.layout_ms, p.paint_ms, p.worst_ms, p.frames, p.settle_ms, p.after_ms, p.after_frames, p.nodes, p.settle_nodes, p.passes });
}

test "fullscreen Cmd+B measurement table" {
    if (std.c.getenv("NANO_CMDB_TABLE") == null) return error.SkipZigTest;
    const Config = struct { w: f32, h: f32, fs: bool };
    const configs = [_]Config{
        .{ .w = 1200, .h = 780, .fs = false },
        .{ .w = 1728, .h = 1117, .fs = false },
        .{ .w = 1728, .h = 1117, .fs = true },
    };
    std.debug.print("\n", .{});
    for ([_]usize{ 60, 240 }) |turns| for (1..4) |panes| for (configs) |cfg| {
        const r = try measure(.{ .full_screen = cfg.fs, .panes = panes, .width = cfg.w, .height = cfg.h, .turns = turns }, 1, false);
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "{d} turns {d}p {d}x{d} {s}", .{ turns, panes, @as(u32, @intFromFloat(cfg.w)), @as(u32, @intFromFloat(cfg.h)), if (cfg.fs) "full" else "win" });
        printPhase(name, "open", r.first_open);
        printPhase(name, "close", r.first_close);
    };
}

test "fullscreen Cmd+B frame work stays near windowed on the same content" {
    for (1..4) |panes| {
        const win = try measure(.{ .full_screen = false, .panes = panes, .turns = 24 }, 3, false);
        const full = try measure(.{ .full_screen = true, .panes = panes, .turns = 24 }, 3, false);
        std.debug.print("\nSynthetic Cmd+B {d} pane(s): windowed open={d:.2}ms close={d:.2}ms, fullscreen open={d:.2}ms close={d:.2}ms\n", .{ panes, win.open.tween(), win.close.tween(), full.open.tween(), full.close.tween() });
        try testing.expect(full.open.tween() < win.open.tween() * 2);
        try testing.expect(full.close.tween() < win.close.tween() * 2);
        try testing.expect(full.open.nodes < win.open.nodes * 2);
        try testing.expectEqual(win.open.frames, full.open.frames);
        try testing.expectEqual(win.close.frames, full.close.frames);
    }
}

test "fullscreen Cmd+B breaks split-pane text into lines once a slide" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (2..4) |panes| {
        var h: Shell = undefined;
        try h.init(arena.allocator(), .{ .full_screen = true, .panes = panes, .turns = 8 });
        defer h.deinit();
        const box = transcriptBox(h.a.selected.?);
        for (0..2) |_| {
            const column = struct {
                fn of(x: *Shell, id: u64) !f32 {
                    const box_rect = x.t.ctx.rects.get(id) orelse return error.MissingViewport;
                    for (x.t.ctx.nodes.items) |n| if (n.id == id) {
                        const body = x.t.ctx.node(n.first_child).rect;
                        // Narrowed early or widened late, never past its pane.
                        try testing.expect(body.w <= box_rect.w and body.x >= box_rect.x - 0.5);
                        return body.w;
                    };
                    return error.MissingColumn;
                }
            }.of;
            var last = try column(&h, box);
            const from = last;
            var changes: usize = 0;
            _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
            for (0..40) |_| {
                const now = try column(&h, box);
                if (@abs(now - last) > 1) changes += 1;
                last = now;
                h.t.frame();
            }
            std.debug.print("\nSynthetic Cmd+B column, {d} panes: {d:.0} to {d:.0} in {d} step(s)\n", .{ panes, from, last, changes });
            try testing.expect(@abs(last - from) > 8);
            try testing.expectEqual(@as(usize, 1), changes);
        }
    }
}

test "fullscreen Cmd+B slide end stays near the viewport in split panes" {
    for (2..4) |panes| {
        // Long enough that the text caches can't hold the whole history,
        // which is what the former path wraps again in one frame.
        const now = try measure(.{ .full_screen = true, .panes = panes, .turns = 240 }, 1, false);
        const former = try measure(.{ .full_screen = true, .panes = panes, .turns = 240 }, 1, true);
        for ([_][2]Phase{ .{ now.first_open, former.first_open }, .{ now.first_close, former.first_close } }) |p| {
            std.debug.print("\nSynthetic Cmd+B slide end, {d} panes: remount all={d:.2}ms/{d} nodes, now={d:.2}ms/{d} nodes\n", .{ panes, p[1].settle_ms, p[1].settle_nodes, p[0].settle_ms, p[0].settle_nodes });
            // The frame the slide ends on is one more frame, not the history.
            try testing.expect(p[0].settle_nodes < p[0].nodes * 3);
            // The same rows, remounted at once as before.
            try testing.expect(p[0].settle_ms * 5 < p[1].settle_ms);
        }
    }
}

fn transcriptBox(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5452_414e_5343_5250, id);
}

/// A paragraph in the middle of the focused pane, by its text.
fn readerLine(h: *Shell, box: u64) ![]const u8 {
    const view = h.t.ctx.rects.get(box) orelse return error.MissingViewport;
    for (h.t.ctx.nodes.items) |n| if (n.content == .text and n.content.text.str.len > 200 and
        n.rect.x >= view.x and n.rect.x + n.rect.w <= view.x + view.w and
        n.rect.y > view.y + view.h * 0.2 and n.rect.y < view.y + view.h * 0.8) return testing.allocator.dupe(u8, n.content.text.str);
    return error.NoVisibleParagraph;
}

fn lineY(h: *Shell, line: []const u8) !f32 {
    for (h.t.ctx.nodes.items) |n| if (n.content == .text and std.mem.eql(u8, n.content.text.str, line)) return n.rect.y;
    return error.ReaderLineGone;
}

test "Cmd+B rows measured after the slide never move what a scrolled-up reader sees" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: Shell = undefined;
    try h.init(arena.allocator(), .{ .full_screen = true, .panes = 2 });
    defer h.deinit();
    const box = transcriptBox(h.a.selected.?);
    const view = h.t.ctx.rects.get(box).?;
    h.t.scroll(view.x + view.w / 2, view.y + view.h / 2, 9_000);
    for (0..60) |_| h.t.frame();
    try testing.expectEqual(false, h.t.ctx.scroll_follow.get(box).?);

    const line = try readerLine(&h, box);
    defer testing.allocator.free(line);
    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    var y = try lineY(&h, line);
    while (h.a.view.sidebar_tween != null) {
        y = try lineY(&h, line);
        h.t.frame();
    }
    // The slide's last frame takes the exact column from the 8-point step
    // under it: the rows on screen may re-break, the history may not.
    const end = try lineY(&h, line);
    std.debug.print("\nSynthetic Cmd+B reader: last slide frame y={d:.1}, slide end y={d:.1}\n", .{ y, end });
    try testing.expectApproxEqAbs(y, end, 120);
    var frames: usize = 0;
    var probed: usize = 0;
    while (h.t.ctx.animating) : (frames += 1) {
        h.t.frame();
        try testing.expectApproxEqAbs(end, try lineY(&h, line), 1.5);
        // A row drawn only for its height is nobody's to select or Tab to.
        for (h.t.ctx.nodes.items) |n| {
            if (n.rect.y > -5e5) continue;
            probed += 1;
            try testing.expect(!h.t.ctx.selection.order.contains(n.id));
            try testing.expect(std.mem.indexOfScalar(u64, h.t.ctx.last_focusable_ids.items, n.id) == null);
        }
        if (frames > 2000) return error.NeverRested;
    }
    try testing.expect(probed > 0);
    // Rested: the scroll extent is the one every row mounted gives.
    const rested = h.t.ctx.scroll_max.get(box).?;
    h.a.offscreen = true;
    h.t.frame();
    h.t.frame();
    std.debug.print("Synthetic Cmd+B extent: rested={d:.1} full={d:.1} after {d} frames\n", .{ rested, h.t.ctx.scroll_max.get(box).?, frames });
    try testing.expectApproxEqAbs(h.t.ctx.scroll_max.get(box).?, rested, 16);
}

test "Cmd+B rows measured after the slide leave a chat at its end" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: Shell = undefined;
    try h.init(arena.allocator(), .{ .full_screen = true, .panes = 3 });
    defer h.deinit();
    for (0..2) |_| {
        _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
        var frames: usize = 0;
        while (h.a.view.sidebar_tween != null or h.t.ctx.animating) : (frames += 1) {
            h.t.frame();
            if (frames > 2000) return error.NeverRested;
            for (0..3) |i| {
                const box = transcriptBox(try std.fmt.allocPrint(arena.allocator(), "chat-{d}", .{i}));
                try testing.expectApproxEqAbs(h.t.ctx.scroll_max.get(box).?, h.t.ctx.scroll.get(box).?, 0.5);
            }
        }
    }
    // Toggled again before the rows of the last slide are all measured.
    for (0..3) |_| {
        _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
        while (h.a.view.sidebar_tween != null) h.t.frame();
        for (0..10) |_| h.t.frame();
        try testing.expect(h.t.ctx.animating);
    }
    while (h.t.ctx.animating) h.t.frame();
    const rested = h.t.ctx.scroll_max.get(transcriptBox(h.a.selected.?)).?;
    h.a.offscreen = true;
    for (0..3) |_| h.t.frame();
    try testing.expectApproxEqAbs(h.t.ctx.scroll_max.get(transcriptBox(h.a.selected.?)).?, rested, 16);
    h.a.offscreen = false;
    for (0..3) |_| h.t.frame();
    // An upward wheel inside the measuring releases the end as ever, and
    // the line under it moves by the wheel alone.
    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    while (h.a.view.sidebar_tween != null) h.t.frame();
    const box = transcriptBox(h.a.selected.?);
    const line = try readerLine(&h, box);
    defer testing.allocator.free(line);
    const view = h.t.ctx.rects.get(box).?;
    const from = try lineY(&h, line);
    h.t.scroll(view.x + view.w / 2, view.y + view.h / 2, 24);
    try testing.expectApproxEqAbs(from + 24, try lineY(&h, line), 1.5);
    try testing.expectEqual(false, h.t.ctx.scroll_follow.get(box).?);
    var frames: usize = 0;
    while (h.t.ctx.animating) : (frames += 1) {
        h.t.frame();
        try testing.expectApproxEqAbs(from + 24, try lineY(&h, line), 1.5);
        if (frames > 2000) return error.NeverRested;
    }
}

/// Scrolls up in pane `pane`, selects there (which takes its focus), and
/// says how far that moved the line; after it the line must stay.
fn selectInPane(alloc: std.mem.Allocator, pane: usize, slide: bool) !f32 {
    var h: Shell = undefined;
    try h.init(alloc, .{ .full_screen = true, .panes = 2 });
    defer h.deinit();
    const id = try std.fmt.allocPrint(alloc, "chat-{d}", .{pane});
    const box = transcriptBox(id);
    const view = h.t.ctx.rects.get(box).?;
    h.t.scroll(view.x + view.w / 2, view.y + view.h / 2, 9_000);
    for (0..60) |_| h.t.frame();
    if (slide) {
        _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
        while (h.a.view.sidebar_tween != null) h.t.frame();
        for (0..6) |_| h.t.frame();
        try testing.expect(h.t.ctx.animating);
    }
    const line = try readerLine(&h, box);
    defer testing.allocator.free(line);
    const r = h.t.findText(line).?;
    h.t.down(r.x + 3, r.y + 8);
    h.t.move(r.x + 120, r.y + 8);
    try testing.expectApproxEqAbs(r.y, try lineY(&h, line), 1.5);
    h.t.up();
    try testing.expectEqualStrings(id, h.a.selected.?);
    const y = try lineY(&h, line);
    var frames: usize = 0;
    while (h.t.ctx.animating) : (frames += 1) {
        h.t.frame();
        try testing.expectApproxEqAbs(y, try lineY(&h, line), 1.5);
        if (frames > 2000) return error.NeverRested;
    }
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    const copied = std.mem.trim(u8, h.t.clipboard.items, " ");
    try testing.expect(copied.len > 0);
    try testing.expect(std.mem.indexOf(u8, line, copied) != null);
    return y - r.y;
}

test "Cmd+B rows measured after the slide stay put under a selection in another pane" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Focusing a pane has its own small shift (its first row's padding); a
    // slide still being measured adds nothing to it.
    for (0..2) |pane| try testing.expectApproxEqAbs(
        try selectInPane(arena.allocator(), pane, false),
        try selectInPane(arena.allocator(), pane, true),
        1.5,
    );
}

fn sidebarEdge(h: *Shell) f32 {
    return @max(h.a.view.fs_left_peek_w, h.a.view.sidebar_width);
}

test "fullscreen Cmd+B docks a showing peek in place instead of sliding it in again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: Shell = undefined;
    try h.init(arena.allocator(), .{ .full_screen = true, .panes = 1, .turns = 4 });
    defer h.deinit();
    const full = h.a.settings.sidebarWidth();
    // Shown whole, and caught partway in.
    for ([_]usize{ 60, 8 }) |dwell| {
        h.t.moveTo(700, 500);
        for (0..120) |_| h.t.frame();
        h.t.moveTo(3, 500);
        while (!h.a.view.fs_left_peek) h.t.frame();
        for (0..dwell) |_| h.t.frame();
        const before = sidebarEdge(&h);
        try testing.expect(before > 20);
        const label_x = (h.t.findText("All projects") orelse return error.MissingPeek).x;
        _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
        var edge = sidebarEdge(&h);
        std.debug.print("\nSynthetic peek then Cmd+B: edge before={d:.1}, press frame={d:.1}\n", .{ before, edge });
        try testing.expect(edge >= before - 0.01);
        var canvas: f32 = 0;
        var frames: usize = 0;
        while (h.a.view.sidebar_tween != null) : (frames += 1) {
            // The sidebar never steps back, is drawn once, and the canvas
            // still slides out from under it on the same curve.
            try testing.expect(sidebarEdge(&h) >= edge - 0.01);
            edge = sidebarEdge(&h);
            try testing.expect(h.a.view.sidebar_width >= canvas);
            canvas = h.a.view.sidebar_width;
            var labels: usize = 0;
            for (h.t.ctx.nodes.items) |n| if (n.content == .text and std.mem.eql(u8, n.content.text.str, "All projects")) {
                labels += 1;
                try testing.expect(n.rect.x >= label_x - 1);
            };
            try testing.expectEqual(@as(usize, 1), labels);
            h.t.frame();
        }
        try testing.expectEqual(@as(usize, 24), frames);
        try testing.expectApproxEqAbs(full, h.a.view.sidebar_width, 0.01);
        try testing.expectEqual(@as(f32, 0), h.a.view.fs_left_peek_w);
        _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
        for (0..60) |_| h.t.frame();
    }
    // Reversed while docking: the sidebar slides away from where it is.
    h.t.moveTo(700, 500);
    for (0..120) |_| h.t.frame();
    h.t.moveTo(3, 500);
    while (!h.a.view.fs_left_peek) h.t.frame();
    for (0..60) |_| h.t.frame();
    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    for (0..6) |_| h.t.frame();
    var edge = sidebarEdge(&h);
    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    try testing.expect(edge - sidebarEdge(&h) < 40);
    for (0..60) |_| {
        edge = sidebarEdge(&h);
        h.t.frame();
        try testing.expect(sidebarEdge(&h) <= edge + 0.01);
        try testing.expect(edge - sidebarEdge(&h) < 40);
    }
    try testing.expectEqual(@as(f32, 0), sidebarEdge(&h));

    // Reduced motion snaps, with nothing left of the peek.
    h.t.ctx.reduced_motion = true;
    h.t.moveTo(700, 500);
    for (0..120) |_| h.t.frame();
    h.t.moveTo(3, 500);
    for (0..60) |_| h.t.frame();
    try testing.expect(h.a.view.fs_left_peek);
    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    try testing.expectApproxEqAbs(full, h.a.view.sidebar_width, 0.01);
    try testing.expectEqual(@as(f32, 0), h.a.view.fs_left_peek_w);
}
