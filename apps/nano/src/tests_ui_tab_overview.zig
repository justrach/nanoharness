//! Synthetic regressions for browse-style Visual Session Overview (⇧⌘\) and
//! tactile split divider grab pill, live ratio badge, and magnetic snap stops.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const S = ui.Shortcut;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, dark: bool) !void {
        theme.registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = dark;
        h.a.device_id = try testing.allocator.dupe(u8, "studio");
        try replace(&h.a.devices,
            \\[{"id":"studio","name":"Studio Mac"},{"id":"builder","name":"Build box"}]
        );
        try replace(&h.a.spaces,
            \\[{"id":"fieldnotes","deviceId":"studio","name":"fieldnotes","path":"/synthetic/fieldnotes","gitDetected":true},
            \\ {"id":"harbor","deviceId":"builder","name":"harbor","path":"/synthetic/harbor","gitDetected":true},
            \\ {"id":"sketches","deviceId":"studio","name":"sketches","path":"/synthetic/sketches","gitDetected":false}]
        );
        try replace(&h.a.chats,
            \\[{"id":"cedar","deviceId":"studio","title":"Cedar layout audit","spaceId":"fieldnotes","branch":"feat/overview","archived":false,"lastMessageAt":"2026-11-24T06:00:00Z"},
            \\ {"id":"rowan","deviceId":"builder","title":"Rowan palette review","spaceId":"harbor","branch":"main","preview":"Checking switcher grid spacing.","archived":false,"lastMessageAt":"2026-11-24T05:50:00Z"},
            \\ {"id":"note","deviceId":"studio","title":"Plain studio sketch","spaceId":"sketches","preview":"Quick spatial scratchpad.","archived":false,"lastMessageAt":"2026-11-24T05:40:00Z"}]
        );
        h.a.openChat("cedar", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = dark });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn press(h: *Harness, key: S) void {
        _ = h.t.shortcut(key);
        h.t.settle(1);
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

fn replace(list: anytype, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try list.replace(parsed.value);
}

fn seedTranscript(h: *Harness) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[
        \\ {"id":"m1","role":"user","parts":[{"kind":"text","text":"Audit split pane resizing and visual session switching."}]},
        \\ {"id":"m2","role":"assistant","parts":[{"kind":"text","text":"Hide window chrome in full screen, snap split dividers to 1/3 and 1/2, and preview all open tabs in ⇧⌘\\."}]}
        \\]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
}

test "⇧⌘\\ opens browse-style visual session overview grid, filters sessions, and activates or dismisses cleanly" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChatInTab("rowan");
    h.a.openChatInTab("note");
    h.a.showTab(0);
    try seedTranscript(&h);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.tabs.items.items.len);

    // Open Visual Tab Overview via ⇧⌘\.
    h.press(S.native(.{ .cmd = true, .shift = true, .key = '\\' }));
    try testing.expect(h.a.view.tab_overview.open);
    try testing.expect(h.t.hasText("Open Sessions"));
    try testing.expect(h.t.hasText("3 open"));
    try testing.expect(h.t.hasText("Cedar layout audit"));
    try testing.expect(h.t.hasText("Rowan palette review"));
    try testing.expect(h.t.hasText("Plain studio sketch"));
    try testing.expect(h.t.containsText("Hide window chrome in full screen"));
    h.snap("overview-grid-dark");

    // Escape closes overview cleanly.
    h.press(.{ .key = S.escape });
    try testing.expect(!h.a.view.tab_overview.open);

    // Fullscreen overview shows clean grid over pure #000000 backdrop and filters live.
    h.a.setFullScreen(true);
    h.t.settle(1);
    h.press(S.native(.{ .cmd = true, .shift = true, .key = '\\' }));
    try testing.expect(h.a.view.tab_overview.open);
    h.snap("overview-grid-fullscreen");

    h.t.typeText("rowan");
    h.t.settle(1);
    try testing.expect(h.t.hasText("1 shown"));
    try testing.expect(h.t.hasText("Rowan palette review"));
    try testing.expect(!h.t.hasText("Plain studio sketch"));

    h.press(.{ .key = S.enter });
    try testing.expect(!h.a.view.tab_overview.open);
    try testing.expectEqualStrings("rowan", h.a.selected.?);
}

test "tab overview enforces mutual exclusion with ⌘K, splits with ⌘D, and closes background tabs with ⌘Del" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChatInTab("rowan");
    h.a.openChatInTab("note");
    h.a.showTab(0);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.tabs.items.items.len);

    // Open via ⌘K -> "tab overview" command.
    h.press(S.native(.{ .cmd = true, .key = 'k' }));
    try testing.expect(h.a.view.palette.open);
    h.t.typeText("tab overview");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Tab overview"));
    h.press(.{ .key = S.enter });
    try testing.expect(!h.a.view.palette.open);
    try testing.expect(h.a.view.tab_overview.open);

    // Navigate right to Rowan and close it with ⌘⌫ while staying in overview.
    h.press(.{ .key = S.right });
    try testing.expectEqual(@as(usize, 1), h.a.view.tab_overview.selected);
    h.press(S.native(.{ .cmd = true, .key = S.backspace }));
    try testing.expect(h.a.view.tab_overview.open);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);

    // Clicking the header ⌘K button hands over cleanly from overview to palette.
    const pal_kbd = if (comptime builtin.os.tag == .macos) "\u{2318}K" else "Ctrl+K";
    try h.t.clickText(pal_kbd);
    h.t.settle(1);
    try testing.expect(!h.a.view.tab_overview.open);
    try testing.expect(h.a.view.palette.open);
    h.press(.{ .key = S.escape });

    // Re-open overview, select the inactive tab ("Plain studio sketch"), and split it with ⌘D.
    h.press(S.native(.{ .cmd = true, .shift = true, .key = '\\' }));
    h.press(.{ .key = S.right });
    h.press(S.native(.{ .cmd = true, .key = 'd' }));
    try testing.expect(!h.a.view.tab_overview.open);
    try testing.expect(h.a.tabs.layout() != null);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
}

test "split divider drag displays live ratio pill and snaps magnetically to 1/3 and 1/2 stops on release" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.openChat("rowan", null);
    h.a.setFullScreen(true);
    h.t.settle(1);

    // Drag center vertical divider (at x=600) leftward near the 1/3 magnetic stop.
    h.t.down(600, 390);
    h.t.move(404, 390);
    h.t.frame();
    try testing.expect(h.a.pane_drag != null);
    try testing.expect(h.t.containsText("% \u{00b7} "));
    if (h.t.findText("34% \u{00b7} 66%")) |pr| {
        try testing.expect(@abs((pr.x + pr.w / 2) - 404.0) < 20.0);
    }
    h.snap("split-divider-drag-pill");

    h.t.up();
    try testing.expect(h.a.pane_drag == null);
    const s = h.a.tabs.layout().?;
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), s.shares.items[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), s.shares.items[1], 1e-4);

    // Drag divider from 1/3 (center x=403) back near 50% and verify magnetic release snap to 0.5.
    const x1: f32 = 6 + (1188.0 - 6.0) * (1.0 / 3.0) + 3.0;
    h.t.down(x1, 390);
    h.t.move(592, 390);
    h.t.up();
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.shares.items[0], 1e-4);
}
