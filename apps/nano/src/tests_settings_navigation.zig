//! Synthetic settings discovery and interaction checks; no account/host access.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const view = @import("view_settings.zig");
const Section = @import("settings.zig").Section;

fn snap(h: *Harness, name: []const u8) !void {
    if (std.c.getenv("NANO_SETTINGS_SNAP_DIR")) |path| {
        var buf: [1024]u8 = undefined;
        try h.t.screenshot(try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(path), name }));
    }
}

test "settings navigation finds GitHub links and toggles the saved preference from its label" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        view.open(&h.a);
        h.t.settle(0.2);
        h.t.typeText("GitHub links");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("1 section"));
        try testing.expect(h.t.hasText("Where GitHub PR and issue links open"));
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, "Where GitHub PR and issue links open")) {
                const text_column = h.t.ctx.nodes.items[node.parent];
                const result_row = h.t.ctx.nodes.items[text_column.parent];
                try testing.expect(result_row.rect.h < 110);
            },
            else => {},
        };
        try snap(&h, if (dark) "search-dark" else "search-light");
        try h.t.clickText("Links & browsing");
        h.t.settle(0.2);
        try testing.expectEqual(Section.browsing, h.a.settings.section);
        try testing.expectEqual(@as(usize, 0), h.a.view.settings_search.text().len);
        try testing.expect(h.t.hasText("Settings / General"));
        try testing.expect(h.t.hasText("Open GitHub links in Harness"));
        try testing.expect(h.a.settings.get(.open_github_links_in_harness));
        try snap(&h, if (dark) "browsing-dark" else "browsing-light");
        try h.t.clickText("Open GitHub links in Harness");
        h.t.settle(0.1);
        try testing.expect(!h.a.settings.get(.open_github_links_in_harness));
        try h.t.clickText("Open GitHub links in Harness");
        h.t.settle(0.1);
        try testing.expect(h.a.settings.get(.open_github_links_in_harness));
        try h.t.clickText("Find a setting");
        h.t.typeText("privacy telemetry");
        h.t.settle(0.1);
        try testing.expect(h.t.hasText("Sounds, alerts and anonymous performance sharing"));
        try h.t.clickText("Notifications");
        h.t.settle(0.2);
        try testing.expectEqual(Section.notifications, h.a.settings.section);
    }
}

test "settings audit clicks the visible GitHub switch and its padded target" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.setSection(.browsing);
    view.open(&h.a);
    h.t.settle(0.2);
    const row = for (h.t.ctx.nodes.items) |node| {
        const text = switch (node.content) {
            .text => |v| v.str,
            else => continue,
        };
        if (!std.mem.eql(u8, text, "Open GitHub links in Harness")) continue;
        break h.t.ctx.nodes.items[h.t.ctx.nodes.items[node.parent].parent].rect;
    } else return error.MissingGitHubLinksRow;
    const x = row.x + row.w - 40;
    const y = row.y + row.h / 2;
    try testing.expect(h.a.settings.get(.open_github_links_in_harness));
    h.t.click(x, y);
    try testing.expect(!h.a.settings.get(.open_github_links_in_harness));
    h.t.click(x, y - 14);
    try testing.expect(h.a.settings.get(.open_github_links_in_harness));
}

test "settings audit fixed workspace mode keys reject capture and override stale custom bindings" {
    const shortcuts = @import("shortcuts.zig");
    const ui = @import("nanoui").ui;
    const sidebar = for (shortcuts.all, 0..) |sc, ix| {
        if (std.mem.eql(u8, sc.key, "toggleSidebar")) break ix;
    } else return error.MissingToggleSidebarShortcut;

    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    h.a.settings.setSection(.shortcuts);
    view.open(&h.a);
    h.t.settle(0.2);
    const cycle: ui.Shortcut = .{ .key = 'm', .cmd = true, .shift = true };
    const design: ui.Shortcut = .{ .key = 'd', .cmd = true, .alt = true };
    for ([_]ui.Shortcut{ cycle, design }) |chord| {
        h.a.view.recording = sidebar;
        _ = h.t.shortcut(chord);
        try testing.expectEqualStrings(shortcuts.all[sidebar].default, h.a.settings.combo(shortcuts.all[sidebar]));
        try testing.expect(std.mem.indexOf(u8, h.a.view.shortcut_notice.items, "fixed window shortcut") != null);
    }

    // A profile saved by the previous build can already have the bad binding.
    h.a.settings.setCombo(shortcuts.all[sidebar], "mod-shift-m");
    view.close(&h.a);
    h.t.settle(0.2);
    const was_open = h.a.view.sidebar_open;
    _ = h.t.shortcut(cycle);
    try testing.expectEqual(was_open, h.a.view.sidebar_open);
    try testing.expectEqual(.developer, h.a.settings.uiMode());
}

test "settings navigation keeps search and Back reachable on short windows and recovers from no matches" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    view.open(&h.a);
    h.t.resize(900, 520);
    h.t.settle(0.2);
    const search = h.t.findText("Search settings") orelse return error.MissingSearch;
    const back = h.t.findText("Back") orelse return error.MissingBack;
    try testing.expect(search.y >= 0 and search.y + search.h <= 520);
    try testing.expect(back.y >= 0 and back.y + back.h <= 520);
    h.t.typeText("zzzzzzzz");
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("No matching settings"));
    try testing.expect(h.t.hasText("Try links, updates, privacy or text size."));
    try h.t.clickText("Clear");
    h.t.settle(0.1);
    try testing.expectEqual(@as(usize, 0), h.a.view.settings_search.text().len);
    h.t.typeText("hourly updates");
    h.t.settle(0.1);
    try testing.expect(h.t.hasText("Connected computers and app updates"));
    try snap(&h, "compact-search");
    try h.t.clickText("Devices");
    h.t.settle(0.1);
    try testing.expectEqual(Section.devices, h.a.settings.section);
    try testing.expect(h.t.hasText("Settings / Devices and data"));
    try h.t.clickText("Back");
    h.t.settle(0.1);
    try testing.expect(!h.a.view.settings_open);
}

test "zen settings shows esc hints and closes on Escape or Close pill" {
    const ui = @import("nanoui").ui;
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    view.open(&h.a);
    h.t.settle(0.2);

    try testing.expect(h.t.hasText("Back to chats"));
    try testing.expect(h.t.hasText("Close"));
    try testing.expect(h.t.hasText("esc"));

    // Escape closes Settings even while Search settings has focus.
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(0.2);
    try testing.expect(!h.a.view.settings_open);

    // Reopen and verify clicking the page-header Close [esc] pill also exits Settings.
    view.open(&h.a);
    h.t.settle(0.2);
    try testing.expect(h.a.view.settings_open);
    try h.t.clickText("Close");
    h.t.settle(0.2);
    try testing.expect(!h.a.view.settings_open);
}
