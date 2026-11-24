//! Synthetic regressions for browse-style minimal black-canvas fullscreen
//! mode: pure #000000 frame surround, zero top bar, auto-collapsed sidebar,
//! split panes edge-to-edge on black, and complete ⌘K keyboard cockpit.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const chrome = @import("panel_chrome.zig");
const panel_chrome = @import("view_panel_chrome.zig");
const theme = @import("theme.zig");
const palette = @import("view_palette.zig");
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
            \\[{"id":"studio","name":"Studio Mac"}]
        );
        try replace(&h.a.spaces,
            \\[{"id":"fieldnotes","deviceId":"studio","path":"/synthetic/fieldnotes"},
            \\ {"id":"harbor","deviceId":"studio","path":"/synthetic/harbor"}]
        );
        try replace(&h.a.chats,
            \\[{"id":"cedar","deviceId":"studio","title":"Cedar layout audit","spaceId":"fieldnotes","archived":false,"lastMessageAt":"2026-11-24T01:00:00Z"},
            \\ {"id":"rowan","deviceId":"studio","title":"Rowan palette review","spaceId":"harbor","archived":false,"lastMessageAt":"2026-11-24T00:50:00Z"},
            \\ {"id":"birch","deviceId":"studio","title":"Birch sidebar pass","spaceId":"fieldnotes","archived":false,"lastMessageAt":"2026-11-24T00:40:00Z"}]
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

fn seedTranscript(h: *Harness) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[
        \\ {"id":"m1","role":"user","parts":[{"kind":"text","text":"Hide window chrome in full screen and switch everything through Cmd+K."}]},
        \\ {"id":"m2","role":"assistant","parts":[{"kind":"text","text":"Minimal full screen paints pure #000000 behind the card, removes the top tab strip, collapses the sidebar, and promotes open tabs plus screen controls into Cmd+K."}]}
        \\]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
}

fn replace(list: anytype, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try list.replace(parsed.value);
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

test "minimal fullscreen paints pure #000000 canvas, removes the top bar, and restores windowed chrome on exit" {
    for ([_]bool{ false, true }) |dark| {
        for ([_]bool{ false, true }) |frosted| {
            var h: Harness = undefined;
            try h.init(dark);
            defer h.deinit();
            h.a.settings.setText("surface", if (frosted) "frosted" else "opaque");
            h.a.openChatInTab("rowan");
            h.t.settle(1);

            // Windowed baseline shows top bar & sidebar toggle at y < 42.
            try testing.expect(!h.a.view.full_screen);
            try testing.expect(h.a.view.sidebar_open);
            try testing.expectEqual(@as(f32, chrome.header_height), h.a.view.chrome.y);
            try testing.expect(h.a.view.strip.active_tab_anchor != null);

            // Enter fullscreen: black surround, collapsed sidebar, 10pt top bezel handle + 28pt borderless pane header.
            h.a.setFullScreen(true);
            h.t.settle(1);
            try testing.expect(h.a.view.full_screen);
            try testing.expect(!h.a.view.sidebar_open);
            try testing.expectEqual(@as(f32, 0), h.a.view.sidebar_width);
            try testing.expectEqual(@as(f32, 0), h.t.ctx.title_bar_height);
            try testing.expectEqual(ui.Color.black, h.t.ctx.node(0).style.background.?);
            try testing.expectEqual(ui.Color.black, h.t.ctx.theme.background);
            try testing.expectEqual(@as(f32, chrome.fs_top_inset), h.a.view.chrome.y);
            try testing.expectEqual(@as(f32, 780 - chrome.fs_top_inset - chrome.zen_gutter), h.a.view.chrome.height);
            try testing.expect(h.a.view.strip.active_tab_anchor == null);
            try testing.expect(h.a.view.updates_anchor == null);
            try testing.expectEqual(@as(usize, 1), countCardRects(&h, chrome.fs_top_inset, 780 - chrome.fs_top_inset - chrome.zen_gutter, ui.Color.white.alpha(0.095)));
            // Cards keep their crisp light/dark fill rather than turning black.
            const k = theme.colors(dark);
            try testing.expect(!std.meta.eql(panel_chrome.zenPageBg(k), ui.Color.black));

            // Other open tab label ("Cedar") does not linger in a hidden top bar, while active session ("Rowan") sits in the 28pt strip.
            for (h.t.ctx.nodes.items) |node| {
                if (node.content == .text and node.rect.y < chrome.fs_handle_h) return error.TopTabBarRenderedInFullScreen;
                if (node.content == .text and std.mem.startsWith(u8, node.content.text.str, "Cedar") and node.rect.y < chrome.header_height) {
                    return error.TopTabBarRenderedInFullScreen;
                }
            }
            const strip_title = h.t.findText("Rowan palette review") orelse return error.MissingPaneHeaderTitle;
            try testing.expect(strip_title.y >= chrome.fs_handle_h and strip_title.y + strip_title.h <= chrome.fs_top_inset);

            // Exit fullscreen restores prior sidebar state and 42pt header geometry.
            h.a.setFullScreen(false);
            h.t.settle(1);
            try testing.expect(!h.a.view.full_screen);
            try testing.expect(h.a.view.sidebar_open);
            try testing.expectEqual(@as(f32, chrome.header_height), h.a.view.chrome.y);
            try testing.expect(h.a.view.strip.active_tab_anchor != null);
        }
    }
}

test "split panes sit in borderless 28pt black header strips at 38pt top inset in fullscreen" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.openChat("rowan", null);
    h.a.setFullScreen(true);
    h.t.settle(1);

    try testing.expectEqual(@as(f32, chrome.fs_top_inset), h.a.view.chrome.y);
    try testing.expectEqual(@as(f32, 780 - chrome.fs_top_inset - chrome.zen_gutter), h.a.view.chrome.height);
    try testing.expect(!h.t.hasText("Split · 2 panes"));

    var pane_cards: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        if (@abs(node.style.radius - chrome.zen_radius) < 0.1 and
            @abs(node.rect.y - chrome.fs_top_inset) < 0.5 and
            @abs(node.rect.h - (780 - chrome.fs_top_inset - chrome.zen_gutter)) < 0.5 and
            node.rect.w > 400 and node.rect.w < 700)
        {
            pane_cards += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), pane_cards);
    h.snap("browse-fs-split");
}

test "⌘K drives fullscreen entry, open tab switching, sidebar peeking, top handle peek, and fullscreen exit" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChatInTab("rowan");
    h.a.openChatInTab("cedar");
    try seedTranscript(&h);
    h.t.settle(1);
    try testing.expectEqualStrings("cedar", h.a.selected.?);
    h.snap("fullscreen-before");

    // Enter full screen via ⌘K.
    h.press(.{ .key = 'k', .cmd = true });
    try testing.expect(h.a.view.palette.open);
    h.t.typeText("full screen");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Enter full screen"));
    h.press(.{ .key = S.enter });
    try testing.expect(h.a.view.full_screen);
    try testing.expect(!h.a.view.sidebar_open);
    h.snap("fullscreen-after-clean");

    // Click top bezel pill handle to reveal the floating top tab bar, then Escape to tuck it away.
    try testing.expect(!h.a.view.fs_top_peek);
    h.t.click(600, 5);
    h.t.settle(1);
    try testing.expect(h.a.view.fs_top_peek);
    try testing.expect(h.t.hasText("Rowan palette review"));
    h.press(.{ .key = S.escape });
    try testing.expect(!h.a.view.fs_top_peek);
    try testing.expect(h.a.view.full_screen);

    // Open ⌘K in fullscreen: placeholder mentions open tabs, idle commands show Exit full screen / Toggle sidebar / Split pane right,
    // and Section 0 surfaces Rowan (the inactive open workspace tab).
    h.press(.{ .key = 'k', .cmd = true });
    try testing.expect(h.a.view.palette.open);
    try testing.expect(h.t.hasText("Search open tabs, commands and chats…"));
    try testing.expect(h.t.hasText("Exit full screen"));
    try testing.expect(h.t.hasText("Toggle sidebar"));
    try testing.expect(h.t.hasText("Split pane right"));
    try testing.expect(h.t.hasText("2 open"));
    h.snap("fullscreen-after-palette");
    // First item is the other open tab ("Rowan palette review"): Return switches cleanly without opening a duplicate tab.
    h.press(.{ .key = S.enter });
    try testing.expectEqualStrings("rowan", h.a.selected.?);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);

    // Toggle sidebar inside fullscreen via ⌘K: sidebar opens with its titlebar above y = 38pt aligned cleanly with the chat card.
    h.press(.{ .key = 'k', .cmd = true });
    h.t.typeText("toggle sidebar");
    h.t.settle(1);
    h.press(.{ .key = S.enter });
    try testing.expect(h.a.view.sidebar_open);
    try testing.expectEqual(@as(usize, 2), countCardRects(&h, chrome.fs_top_inset, 780 - chrome.fs_top_inset - chrome.zen_gutter, ui.Color.white.alpha(0.095)));
    h.snap("browse-fs-cmdb");

    // Exit full screen via ⌘K (Cmd+Ctrl+F shortcut also toggles cleanly in headless mode).
    h.press(.{ .key = 'k', .cmd = true });
    h.t.typeText("exit full");
    h.t.settle(1);
    h.press(.{ .key = S.enter });
    try testing.expect(!h.a.view.full_screen);
    try testing.expect(h.a.view.strip.active_tab_anchor != null);

    // Re-enter and exit via Ctrl+Cmd+F keybinding.
    h.press(.{ .key = 'f', .cmd = true, .ctrl = true });
    try testing.expect(h.a.view.full_screen);
    h.press(.{ .key = 'f', .cmd = true, .ctrl = true });
    try testing.expect(!h.a.view.full_screen);
}
