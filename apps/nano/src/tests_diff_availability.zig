//! #750: loading, unavailable and capture failures are not a clean diff.
//! Feed replies through the same request callback the live engine uses.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const panels = @import("app_panels.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, scene: []const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"plain-folder","deviceId":"fixture","cwd":"/synthetic/plain-folder","title":"Synthetic diff"}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("plain-folder", null);
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
        h.a.engine.state = .connected;
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(0.2);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
};

test "diff availability 750 plain-folder and transient failures stop loading without claiming clean" {
    for ([_]bool{ false, true }) |transient| {
        const message = if (transient) "Synthetic Git capture timed out" else "fatal: not a git repository (or any of the parent directories): .git";
        const scene = try std.json.Stringify.valueAlloc(testing.allocator, .{
            .GetCheckoutDiff = .{ .@"$err" = message },
        }, .{});
        defer testing.allocator.free(scene);
        var h: Harness = undefined;
        try h.init(scene);
        defer h.deinit();
        panels.addDiffsTab(&h.a);
        try testing.expect(h.a.panels.diff_loading);
        try testing.expect(h.a.engine.pump());
        h.t.settle(0.2);
        try testing.expect(!h.a.panels.diff_loading);
        try testing.expect(h.a.panels.diff == null);
        try testing.expect(h.t.hasText(if (transient) message else panels.not_git_notice));
        try testing.expect(!h.t.hasText("Preparing diff…"));
        try testing.expect(!h.t.hasText("No uncommitted changes"));
        if (transient) try testing.expect(!h.t.hasText(panels.not_git_notice));
    }
}

test "diff availability 750 retry recovers from capture failure to clean and changed snapshots" {
    var h: Harness = undefined;
    try h.init(
        \\{"GetCheckoutDiff":{"$seq":[
        \\ {"$err":"Synthetic Git capture timed out"},
        \\ {"checkoutId":"checkout","checksum":"clean","patch":""},
        \\ {"checkoutId":"checkout","checksum":"changed","patch":"diff --git a/example.md b/example.md\n--- a/example.md\n+++ b/example.md\n@@ -1 +1 @@\n-before\n+after\n","additions":1,"deletions":1}
        \\]}}
    );
    defer h.deinit();
    panels.addDiffsTab(&h.a);
    try testing.expect(h.a.engine.pump());
    try testing.expect(h.a.panels.diff_error != null);
    panels.fetchDiff(&h.a);
    try testing.expect(h.a.panels.diff_loading);
    try testing.expect(h.a.engine.pump());
    h.t.settle(0.2);
    try testing.expect(h.a.panels.diff_error == null);
    try testing.expect(!h.a.panels.diff_loading);
    try testing.expect(h.t.hasText("No uncommitted changes"));
    panels.fetchDiff(&h.a);
    try testing.expect(h.a.engine.pump());
    h.t.settle(0.2);
    try testing.expect(h.a.panels.diff_error == null);
    try testing.expectEqual(@as(usize, 1), h.a.panels.diff.?.files.len);
    try testing.expect(h.t.hasText("example.md"));
    try testing.expect(!h.t.hasText("Preparing diff…"));
    try testing.expect(!h.t.hasText(panels.not_git_notice));
}

test "local git diffs scroll long lines horizontally and keep a sticky header while scrolling" {
    var patch_buf: std.ArrayList(u8) = .empty;
    defer patch_buf.deinit(testing.allocator);
    try patch_buf.appendSlice(testing.allocator, "diff --git a/src/layout_engine.zig b/src/layout_engine.zig\n--- a/src/layout_engine.zig\n+++ b/src/layout_engine.zig\n@@ -1,4 +1,36 @@\n");
    try patch_buf.appendSlice(testing.allocator, "-const old_long_identifier = computeVeryLongSyntheticLayoutParameterNameForDiffScrollVerification(viewport_width, gutter_inset, trailing_margin);\n");
    try patch_buf.appendSlice(testing.allocator, "+const new_long_identifier = computeVeryLongSyntheticLayoutParameterNameForDiffScrollVerification(viewport_width, gutter_inset, trailing_margin, sticky_header_height);\n");
    for (0..34) |line_ix| {
        var lb: [128]u8 = undefined;
        const row = try std.fmt.bufPrint(&lb, "+    // synthetic diff context row {d} keeping the file tall enough to scroll past its header\n", .{line_ix});
        try patch_buf.appendSlice(testing.allocator, row);
    }
    const scene = try std.json.Stringify.valueAlloc(testing.allocator, .{
        .GetCheckoutDiff = .{
            .checkoutId = "checkout",
            .checksum = "long-lines",
            .patch = patch_buf.items,
            .additions = 35,
            .deletions = 1,
        },
    }, .{});
    defer testing.allocator.free(scene);

    var h: Harness = undefined;
    try h.init(scene);
    defer h.deinit();
    panels.addDiffsTab(&h.a);
    try testing.expect(h.a.engine.pump());
    h.t.settle(0.3);

    // Scroll vertically past the first file header so sticky header engages.
    const host_x = h.a.view.chrome.x + h.a.view.chrome.width - h.a.view.chrome.host_width * 0.5;
    h.t.scroll(host_x, 300, -180);
    h.t.settle(0.2);

    // 1. Wide diff file body must expose a horizontal scroll viewport (`scroll_x = true`) inside the host pane.
    const host_left = h.a.view.chrome.x + h.a.view.chrome.width - h.a.view.chrome.host_width;
    var diff_scroll_x: ?ui.Rect = null;
    var diff_scroll_id: u64 = 0;
    for (h.t.ctx.nodes.items) |node| {
        if (node.style.scroll_x and node.rect.x >= host_left - 2) {
            diff_scroll_x = node.rect;
            diff_scroll_id = node.id;
            break;
        }
    }
    const vp = diff_scroll_x orelse return error.MissingDiffHorizontalScroll;
    h.t.hscroll(vp.x + vp.w / 2, 300, -240);
    h.t.settle(0.1);
    if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/local-diff.png", .{std.mem.span(dir)})) |path| {
            h.t.screenshot(path) catch {};
        } else |_| {}
    }
    try testing.expect((h.t.ctx.scroll_x.get(diff_scroll_id) orelse 0) > 40);

    // 2. Even after scrolling down 180pt, the active file path remains visible in a sticky header near the top of the diff pane.
    var saw_sticky = false;
    for (h.t.ctx.nodes.items) |node| {
        if (node.content == .text and std.mem.eql(u8, node.content.text.str, "src/layout_engine.zig")) {
            if (node.rect.y >= 100 and node.rect.y <= 170) saw_sticky = true;
        }
    }
    try testing.expect(saw_sticky);
}
