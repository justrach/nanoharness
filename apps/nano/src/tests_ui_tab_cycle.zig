//! Synthetic regressions for browse-style ⌃Tab / ⌃⇧Tab visual TabCycleHUD
//! and the full-screen left-edge bezel sidebar reveal pill.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const chrome = @import("panel_chrome.zig");
const theme = @import("theme.zig");
const tab_cycle = @import("view_tab_cycle.zig");
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
            \\[{"id":"cedar","deviceId":"studio","title":"Cedar layout audit","spaceId":"fieldnotes","branch":"feat/hud","archived":false,"lastMessageAt":"2026-11-24T06:00:00Z"},
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
        \\ {"id":"m1","role":"user","parts":[{"kind":"text","text":"Cycle open tabs visually on Ctrl+Tab."}]},
        \\ {"id":"m2","role":"assistant","parts":[{"kind":"text","text":"Showing TabCycleHUD cards with live excerpts and left-edge fullscreen sidebar reveal."}]}
        \\]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
}

fn countCardRects(h: *Harness, y: f32, want_h: f32, border: ui.Color) usize {
    var n: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        if (@abs(node.style.radius - chrome.zen_radius) > 0.1) continue;
        if (@abs(node.rect.y - y) > 0.5 or @abs(node.rect.h - want_h) > 0.5) continue;
        if (node.style.border) |b| if (std.meta.eql(b, border)) {
            n += 1;
        };
    }
    return n;
}

test "⌃Tab and ⌃⇧Tab display browse-style TabCycleHUD, switch via card click, hide on Esc, and auto-dismiss" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChatInTab("rowan");
    h.a.openChatInTab("note");
    h.a.showTab(0);
    try seedTranscript(&h);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.tabs.items.items.len);

    // ⌃Tab advances to tab 1 (rowan) and reveals the centered TabCycleHUD.
    h.press(.{ .key = S.tab, .ctrl = true });
    try testing.expectEqualStrings("rowan", h.a.selected.?);
    try testing.expect(tab_cycle.isOpen(&h.a, h.t.time));
    try testing.expect(h.t.hasText("⌃Tab"));
    try testing.expect(h.t.hasText("Hide"));
    try testing.expect(h.t.hasText("Rowan palette review"));
    try testing.expect(h.t.hasText("Plain studio sketch"));
    h.snap("tab-cycle-hud-dark");

    // In full screen, ⌃⇧Tab moves back to tab 0 (cedar) and renders over #000000 chrome.
    h.a.setFullScreen(true);
    h.t.settle(1);
    h.press(.{ .key = S.tab, .ctrl = true, .shift = true });
    try testing.expectEqualStrings("cedar", h.a.selected.?);
    try testing.expect(tab_cycle.isOpen(&h.a, h.t.time));
    try testing.expect(h.t.containsText("Showing TabCycleHUD cards"));
    h.snap("tab-cycle-hud-fullscreen");

    // Clicking a card in the HUD switches straight to that tab and hides the HUD.
    try h.t.clickText("Plain studio sketch");
    h.t.settle(1);
    try testing.expectEqualStrings("note", h.a.selected.?);
    try testing.expect(!tab_cycle.isOpen(&h.a, h.t.time));

    // Escape hides an open HUD without changing selection.
    h.press(.{ .key = S.tab, .ctrl = true });
    try testing.expect(tab_cycle.isOpen(&h.a, h.t.time));
    h.press(.{ .key = S.escape });
    try testing.expect(!tab_cycle.isOpen(&h.a, h.t.time));

    // Advancing past duration_s auto-dismisses cleanly.
    h.press(.{ .key = S.tab, .ctrl = true });
    try testing.expect(tab_cycle.isOpen(&h.a, h.t.time));
    h.t.advance(@floatCast(tab_cycle.duration_s + 0.1));
    try testing.expect(!tab_cycle.isOpen(&h.a, h.t.time));
}

test "fullscreen left-edge bezel handle opens aligned ⌘B sidebar when clicked" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try seedTranscript(&h);
    h.a.setFullScreen(true);
    h.t.settle(1);
    try testing.expect(!h.a.view.sidebar_open);
    h.snap("fs-left-bezel-handle");

    // Click the vertical pill along the left edge (centered at x=5, y=390).
    h.t.click(5, 390);
    h.t.settle(1);
    try testing.expect(h.a.view.sidebar_open);
    try testing.expectEqual(@as(usize, 2), countCardRects(&h, chrome.fs_top_inset, 780 - chrome.fs_top_inset - chrome.zen_gutter, ui.Color.white.alpha(0.095)));
}
