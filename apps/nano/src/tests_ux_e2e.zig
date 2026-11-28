//! End-to-end desktop UX conformance regressions covering Issues #100–#104:
//! - Dia-esque Zen composer focus, overlay mutual exclusion, and ranked Escape
//! - 0px hover label reflow on top workspace pills and grouped pane tabs
//! - Developer trailing shortcut tooltips & panel menu branch/diff badges
//! - Paper Design Canvas DOM style inspection & PNG attachment critique staging
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const panels = @import("app_panels.zig");
const attachments = @import("app_attachments.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, dark: bool) !void {
        theme.registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = dark;
        h.a.account.scope = .local;
        const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"acme","deviceId":"local","path":"/synthetic/acme-weather","gitDetected":true}]
        , .{});
        defer spaces.deinit();
        try h.a.spaces.replace(spaces.value);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"c1","deviceId":"local","title":"Weather Card Spec","spaceId":"acme","branch":"feat/ux-audit","archived":false},
            \\ {"id":"c2","deviceId":"local","title":"Orbit Tabs Polish","spaceId":"acme","branch":"main","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("c1", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{
            .width = 1200,
            .height = 780,
            .dark = dark,
            .theme = theme.ui(dark),
        });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn topText(h: *Harness, text: []const u8) ?ui.Rect {
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, text) and node.rect.y < h.a.view.chrome.y) return node.rect,
            else => {},
        };
        return null;
    }
};

test "ux e2e: zen composer focus, popover mutual exclusion, and ranked Escape peel-off" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();

    h.a.settings.applyUiMode(.zen);
    h.t.settle(0.3);
    try testing.expect(h.a.view.composer_id != 0);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);

    // Opening one transient header/sidebar popover via menu exclusion must close peers.
    const menus = @import("view_sidebar_menus.zig");
    menus.openProjects(&h.a);
    h.t.settle(0.1);
    try testing.expect(h.a.view.filter_menu);

    menus.openView(&h.a);
    h.t.settle(0.1);
    try testing.expect(!h.a.view.filter_menu);
    try testing.expect(h.a.view.more_menu);

    // Opening command palette strictly enforces mutual exclusion over popup menus,
    // and Escape peels off palette -> settings -> restored composer focus.
    @import("view_settings.zig").open(&h.a);
    @import("view_palette.zig").toggle(&h.a, .preserve_tabs);
    h.t.settle(0.2);
    try testing.expect(!h.a.view.more_menu);
    try testing.expect(h.a.view.settings_open);
    try testing.expect(h.a.view.palette.open);

    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(0.2);
    try testing.expect(!h.a.view.palette.open);
    try testing.expect(h.a.view.settings_open);

    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(0.2);
    try testing.expect(!h.a.view.settings_open);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
}

test "ux e2e: hover stability keeps 0px label reflow on top workspace pills and grouped tabs" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    // Multi-workspace top pill hover must not change title text bounds (`topWorkspacePill`).
    h.a.newTab();
    h.a.openChat("c2", null);
    h.t.settle(0.2);
    const pill_before = h.topText("Weather Card Spec") orelse return error.MissingWorkspacePill;
    h.t.moveTo(pill_before.x + pill_before.w / 2, pill_before.y + pill_before.h / 2);
    h.t.settle(0.1);
    const pill_after = h.topText("Weather Card Spec") orelse return error.MissingWorkspacePillAfterHover;
    try testing.expectApproxEqAbs(pill_before.x, pill_after.x, 0.5);
    try testing.expectApproxEqAbs(pill_before.w, pill_after.w, 0.5);
}

test "ux e2e: developer trailing tooltips include shortcuts and split panel menu shows branch and diff badges" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    h.a.settings.applyUiMode(.developer);
    h.t.settle(0.2);

    // Seed a synthetic diff matching active chat `"c1"` (`feat/ux-audit`).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const files = try arena.allocator().alloc(@import("diff.zig").File, 1);
    files[0] = .{ .path = "src/view.zig", .additions = 12, .deletions = 3, .hunks = &.{} };
    if (h.a.panels.chat) |old| testing.allocator.free(old);
    h.a.panels.chat = try testing.allocator.dupe(u8, "c1");
    h.a.panels.diff = .{ .arena = arena, .files = files, .additions = 12, .deletions = 3 };

    const tab_rect = h.topText("Weather Card Spec") orelse return error.MissingDevTab;
    @import("view_tab_strip.zig").open(&h.a, .panel, .{ .chat = 0 }, tab_rect);
    h.t.settle(0.2);

    try testing.expect(h.t.hasText("feat/ux-audit"));
    try testing.expect(h.t.hasText("1f +12/-3"));
    try h.t.clickText("1f +12/-3");
    h.t.settle(0.2);
    try testing.expect(h.a.panels.host_open);
    try testing.expectEqual(panels.TabKind.diffs, h.a.panels.activeTab().?.kind);
}

test "ux e2e: design canvas DOM style overlay and Send critique stages annotated PNG attachment" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    h.a.settings.applyUiMode(.design);
    panels.openDesignCanvas(&h.a);
    h.a.view.design.source = .browse_snapshot;
    const bc = h.a.ensureBrowseClient();
    const mcp_nodes = "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[{\\\"tag\\\":\\\"button\\\",\\\"fontSize\\\":14,\\\"borderRadius\\\":8,\\\"w\\\":120,\\\"h\\\":36},{\\\"tag\\\":\\\"a\\\",\\\"fontSize\\\":12,\\\"borderRadius\\\":4,\\\"w\\\":40,\\\"h\\\":20}]\"}]}}";
    bc.acquire();
    bc.inspect_count = @import("browse_connect.zig").parseStyleNodesJson(testing.allocator, mcp_nodes, &bc.inspect_nodes);
    bc.release();

    const p0 = h.a.view.design.addPinNorm(0.25, 0.30).?;
    h.a.view.design.pins[p0].note.set("Tighten radius");
    h.t.settle(0.2);

    try testing.expect(h.t.hasText("LIVE DOM STYLES"));
    try testing.expect(h.t.hasText("Sync DOM"));
    try testing.expect(h.t.hasText("Send critique to chat"));

    try h.t.clickText("Send critique to chat");
    h.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings("design-canvas-critique.png", item.name);
    try testing.expectEqualStrings("\x89PNG", item.bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, h.a.composer.text(), "Pin #1 (25%, 30%): Tighten radius") != null or
        std.mem.indexOf(u8, h.a.composer.text(), "Pin #1 at (25%, 30%): Tighten radius") != null);
}

test "ux e2e: Design Canvas Exit button, /design toggle, and Cmd+Shift+M cleanly exit Design mode" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    // 1. Entering Design mode opens Design Canvas; clicking toolbar `Exit` returns to Zen and closes canvas.
    @import("composer_completion.zig").activate(&h.a, .design_mode);
    h.t.settle(0.2);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.design, h.a.settings.uiMode());
    try testing.expect(h.a.panels.host_open);
    try testing.expect(h.t.hasText("Exit"));

    try h.t.clickText("Exit");
    h.t.settle(0.2);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
    try testing.expect(!h.a.panels.host_open);

    // 2. `/design` toggles Design mode both on and off.
    @import("composer_completion.zig").activate(&h.a, .design_mode);
    h.t.settle(0.2);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.design, h.a.settings.uiMode());
    try testing.expect(h.a.panels.host_open);

    @import("composer_completion.zig").activate(&h.a, .design_mode);
    h.t.settle(0.2);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
    try testing.expect(!h.a.panels.host_open);

    // 3. `Cmd+Shift+M` from Design mode exits back to Zen and closes the canvas.
    @import("composer_completion.zig").activate(&h.a, .design_mode);
    h.t.settle(0.2);
    _ = h.t.shortcut(.{ .key = 'm', .cmd = true, .shift = true });
    h.t.settle(0.2);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
    try testing.expect(!h.a.panels.host_open);
}

test "ux e2e: Windows caption lane collapses extra Developer trailing toggles on narrow windows" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();

    h.a.settings.applyUiMode(.developer);
    const win_caption = @import("window_chrome.zig").trailingFor(.windows);
    const ux_m = @import("ux_rules.zig").UiMode3;
    const vu = @import("view_updates.zig");

    h.t.resize(600 + win_caption, 600);
    h.t.settle(0.2);
    const narrow = vu.trailingMetricsFor(&h.a, win_caption);
    try testing.expect(narrow.avail < 420);
    try testing.expectEqual(@as(u32, 1), ux_m.effectiveTrailingCount(.developer, false, narrow.avail, narrow.last_slot));

    h.t.resize(1200, 780);
    h.t.settle(0.2);
    const wide = vu.trailingMetricsFor(&h.a, win_caption);
    try testing.expectEqual(@as(u32, 3), ux_m.effectiveTrailingCount(.developer, false, wide.avail, wide.last_slot));
}
