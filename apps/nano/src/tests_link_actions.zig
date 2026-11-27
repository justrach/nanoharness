//! #348: link actions are available on styled text and literal tool output.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const url = "https://example.invalid/synthetic?q=1";

fn load(h: *Harness, tool: bool) !void {
    h.a.settings.set(.transcript_compact_mode, false);
    const json = if (tool)
        \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"run","kind":"tool","resolved":true,"call":{"kind":"exec","command":"echo synthetic"},"output":"https://example.invalid/synthetic?q=1"}]}]}
    else
        \\{"reset":[{"id":"reply","role":"assistant","parts":[{"id":"text","kind":"text","text":"`https://example.invalid/synthetic?q=1`"}]}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(0.3);
    if (tool) {
        try h.t.clickText("Ran 1 command");
        h.t.settle(1);
        try h.t.clickText("Run");
        h.t.settle(1);
    }
}

fn rightClickLink(h: *Harness) !void {
    const rect = h.t.findText(url) orelse return error.MissingSyntheticLink;
    // richText's layout box fills the column; click the URL glyphs, not
    // the whitespace after its destination.
    h.t.rightClick(rect.x + 8, rect.y + rect.h / 2);
    h.t.settle(0.2);
}

test "link actions 348 inline-code and tool-output context menus copy exact destinations" {
    for ([_]bool{ false, true }) |tool| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try load(&h, tool);
        try rightClickLink(&h);
        try testing.expect(h.t.hasText("Open in Harness"));
        try testing.expect(h.t.hasText("Open in browser"));
        try h.t.clickText("Copy link");
        h.t.settle(0.2);
        try testing.expectEqualStrings(url, h.t.clipboard.items);
    }
}

test "link actions 348 internal open retains the conversation and a hidden source dismisses its menu" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try load(&h, false);
    try rightClickLink(&h);
    try h.t.clickText("Open in Harness");
    h.t.settle(0.2);
    try testing.expectEqualStrings("a", h.a.panels.tabs.items[0].browser.?.parent);
    try testing.expectEqualStrings(url, h.a.panels.tabs.items[0].browser.?.url);
    h.a.panels.host_open = false;
    h.t.settle(0.2);
    try rightClickLink(&h);
    h.a.openChat("b", null);
    h.t.settle(0.2);
    try testing.expect(!h.t.hasText("Open in browser"));
    try testing.expect(!h.t.hasText("Copy link"));
}

test "transcript link return focuses the prompt after closing the in-app page" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try load(&h, false);
    try rightClickLink(&h);
    try h.t.clickText("Open in Harness");
    h.t.settle(0.2);
    try testing.expect(h.a.panels.host_open);
    try testing.expect(h.a.view.strip.focused == .host);
    try testing.expect(h.t.ctx.focus != h.a.view.composer_id);

    h.press(.{ .key = 'w', .cmd = true });
    try testing.expect(!h.a.panels.host_open);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.t.typeText("Follow-up");
    try testing.expectEqualStrings("Follow-up", h.a.composer.text());
}

test "transcript link return focuses the prompt after using the external browser" {
    const browser = @import("app_browser.zig");
    const saved = browser.open_external_url;
    defer browser.open_external_url = saved;
    browser.open_external_url = struct {
        fn open(destination: []const u8) bool {
            return std.mem.eql(u8, destination, url);
        }
    }.open;
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try load(&h, false);
    try rightClickLink(&h);
    try testing.expect(h.t.ctx.focus != h.a.view.composer_id);
    try h.t.clickText("Open in browser");
    h.t.ctx.input.window_active = false;
    h.t.ctx.window_focused = false;
    h.t.settle(0.2);
    h.t.ctx.input.window_active = true;
    h.t.ctx.window_focused = true;
    h.t.settle(0.2);

    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.t.typeText("Follow-up");
    try testing.expectEqualStrings("Follow-up", h.a.composer.text());
}

test "transcript link return does not redirect focus from another chat" {
    const browser = @import("app_browser.zig");
    const saved = browser.open_external_url;
    defer browser.open_external_url = saved;
    browser.open_external_url = struct {
        fn open(destination: []const u8) bool {
            return std.mem.eql(u8, destination, url);
        }
    }.open;
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    browser.openInternalLink(&h.a, "a", url);
    h.t.settle(0.2);
    h.a.splitOpening(.horizontal, "b");
    h.t.settle(0.2);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expect(browser.linkOwner(&h.a, "a", url) != null);
    h.t.ctx.focus = 0;

    browser.openExternalLink(&h.a, "a", url);
    h.t.settle(0.2);
    try testing.expectEqual(@as(u64, 0), h.t.ctx.focus);
    h.a.view.strip.focused = .host;
    @import("app_panels.zig").closeTab(&h.a, 0);
    h.t.settle(0.2);
    try testing.expectEqual(@as(u64, 0), h.t.ctx.focus);
    try testing.expectEqualStrings("b", h.a.selected.?);
}

test "link actions 348 browser action validates its source and keyboard Copy never navigates" {
    const browser = @import("app_browser.zig");
    const Opener = struct {
        var count: usize = 0;
        fn open(destination: []const u8) bool {
            testing.expectEqualStrings(url, destination) catch return false;
            count += 1;
            return true;
        }
    };
    const saved = browser.open_external_url;
    browser.open_external_url = Opener.open;
    defer browser.open_external_url = saved;
    Opener.count = 0;
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try load(&h, false);
    try rightClickLink(&h);
    try h.t.clickText("Open in browser");
    h.t.settle(0.2);
    try testing.expectEqual(@as(usize, 1), Opener.count);
    try rightClickLink(&h);
    h.press(.{ .key = @import("nanoui").ui.Shortcut.down });
    h.press(.{ .key = @import("nanoui").ui.Shortcut.down });
    h.press(.{ .key = @import("nanoui").ui.Shortcut.enter });
    try testing.expectEqualStrings(url, h.t.clipboard.items);
    try testing.expectEqual(@as(usize, 1), Opener.count);
    try testing.expect(h.a.panels.tabs.items.len == 0);
    h.a.openChat("b", null);
    browser.openExternalLink(&h.a, "a", url);
    browser.openExternalLink(&h.a, "b", "javascript:synthetic()");
    try testing.expectEqual(@as(usize, 1), Opener.count);
}
