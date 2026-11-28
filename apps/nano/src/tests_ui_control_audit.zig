//! Controls that say what they do, once: every visible control acts as its
//! label says, the same action has one name and one place, and nothing is
//! drawn live that does nothing. Driven headlessly on made-up chats,
//! projects and computers (the shared tab-strip fixture).
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const shortcuts = @import("shortcuts.zig");
const strip = @import("view_tab_strip.zig");
const palette = @import("view_palette.zig");
const pal = @import("palette.zig");
const custom: ui.Shortcut = .{ .key = 'y', .cmd = true, .alt = true };
const mac = @import("builtin").os.tag == .macos;
const none = std.math.maxInt(u32);

fn bind(h: *Harness, key: []const u8, combo: []const u8) !void {
    for (shortcuts.all) |entry| if (entry.slot == null and std.mem.eql(u8, entry.key, key)) {
        h.a.settings.setCombo(entry, combo);
        return;
    };
    return error.ShortcutNotFound;
}

fn center(r: ui.Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

/// The tooltip shown after resting on `r` past every delay the app uses.
fn tipAt(h: *Harness, r: ui.Rect) ?[]const u8 {
    h.t.moveTo(1, 700);
    h.t.advance(0.1);
    const p = center(r);
    h.t.moveTo(p[0], p[1]);
    h.t.advance(0.7);
    return h.t.tooltipText();
}

/// The first accessible button whose name starts with `prefix`.
fn button(h: *Harness, prefix: []const u8) ?ui.A11yItem {
    for (h.t.ctx.a11y_items.items) |item| if (std.mem.startsWith(u8, item.label, prefix)) return item;
    return null;
}

fn rectOf(h: *Harness, item: ui.A11yItem) ui.Rect {
    return h.t.ctx.nodes.items[item.node_index].rect;
}

fn isIcon(node: anytype, comptime name: []const u8) bool {
    return switch (node.content) {
        .image => |im| im.source == .encoded and std.mem.eql(u8, im.source.encoded, @import("icons_svg").get(name)),
        else => false,
    };
}

/// Icons `name` drawn under the node at `root` (or anywhere, `none`).
fn iconsUnder(h: *Harness, root: u32, comptime name: []const u8) usize {
    var n: usize = 0;
    for (h.t.ctx.nodes.items, 0..) |node, i| {
        if (!isIcon(node, name)) continue;
        if (root == none) {
            n += 1;
            continue;
        }
        var at: u32 = @intCast(i);
        while (at != none) : (at = h.t.ctx.nodes.items[at].parent) if (at == root) {
            n += 1;
            break;
        };
    }
    return n;
}

/// The nearest ancestor of icon `name` sized `w`×`h`, below `min_y`.
fn iconBox(h: *Harness, comptime name: []const u8, w: f32, hh: f32, min_y: f32) ?u32 {
    var found: ?u32 = null;
    for (h.t.ctx.nodes.items, 0..) |node, i| {
        if (!isIcon(node, name)) continue;
        var at: u32 = @intCast(i);
        while (at != none) : (at = h.t.ctx.nodes.items[at].parent) {
            const box = h.t.ctx.nodes.items[at];
            if (box.rect.w == w and box.rect.h == hh and box.rect.y >= min_y) {
                found = at;
                break;
            }
        }
    }
    return found;
}

fn addRun(h: *Harness) !void {
    try h.a.actions.runs.append(testing.allocator, .{
        .name = try testing.allocator.dupe(u8, "Synthetic build"),
        .log = .{ .gpa = testing.allocator, .palette = h.a.ansi },
    });
}

// ---- Chrome and shortcuts ----

test "control audit: Cmd J toggles the terminal and action-runs dock, as its button and palette row do" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try addRun(&h);
    h.press(.{ .key = 'j', .cmd = true });
    try testing.expect(h.a.actions.dock_open);
    try testing.expect(!h.a.panels.host_open);
    h.press(.{ .key = 'j', .cmd = true });
    try testing.expect(!h.a.actions.dock_open);
    // The palette's "Toggle terminal" is the same action.
    palette.activate(&h.a, .toggle_terminal);
    h.t.settle(1);
    try testing.expect(h.a.actions.dock_open);
    try testing.expect(!h.a.panels.host_open);
}

test "control audit: with no runs the dock button is disabled and Cmd J says why instead of lighting up" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.developer);
    h.t.settle(1);
    const dock = button(&h, "Toggle terminal") orelse return error.MissingDockButton;
    try testing.expect(!dock.enabled);
    const tip = tipAt(&h, rectOf(&h, dock)) orelse return error.MissingDockTooltip;
    try testing.expect(std.mem.indexOf(u8, tip, "No terminal or action runs") != null);
    h.press(.{ .key = 'j', .cmd = true });
    try testing.expect(!h.a.actions.dock_open);
    try testing.expect(!h.a.panels.host_open);
    try testing.expect(h.a.noticeText() != null);
    // With a run it is a live toggle again.
    try addRun(&h);
    h.t.settle(1);
    const live = button(&h, "Toggle terminal") orelse return error.MissingDockButton;
    try testing.expect(live.enabled);
}

test "control audit: the title bar's open-tabs control names what it opens and is not the Chat history clock" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.t.settle(1);
    const tabs = button(&h, "Open tabs") orelse return error.MissingOpenTabsControl;
    try testing.expectEqualStrings("Open tabs", tipAt(&h, rectOf(&h, tabs)) orelse return error.MissingTooltip);
    try testing.expectEqual(@as(usize, 0), iconsUnder(&h, tabs.node_index, "clock-circle"));
}

test "control audit: Move panel up points up" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.vertical);
    h.t.settle(1);
    strip.open(&h.a, .panel, .{ .chat = 1 }, .{ .x = 600, .y = 400, .w = 80, .h = 20 });
    h.t.settle(1);
    var row: ?u32 = null;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |t| if (std.mem.startsWith(u8, t.str, "Move pan") and std.mem.endsWith(u8, t.str, " up")) {
            row = node.parent;
        },
        else => {},
    };
    const r = row orelse return error.MissingMoveUpRow;
    try testing.expectEqual(@as(usize, 1), iconsUnder(&h, r, "alt-arrow-up"));
    try testing.expectEqual(@as(usize, 0), iconsUnder(&h, r, "alt-arrow-down"));
}

test "control audit: the mode pill and Design Canvas button describe what a click does now" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.a.settings.applyUiMode(.design);
    @import("app_panels.zig").openDesignCanvas(&h.a);
    h.t.settle(1);
    for (h.t.ctx.a11y_items.items) |item| try testing.expect(std.mem.indexOf(u8, item.label, "Zen / Developer") == null);
    _ = button(&h, "Switch to Zen mode") orelse return error.MissingModePill;
    _ = button(&h, "Close Design Canvas") orelse return error.MissingCanvasClose;
    try testing.expect(button(&h, "Open Design Canvas") == null);
    @import("app_panels.zig").closeDesignCanvas(&h.a);
    h.t.settle(1);
    _ = button(&h, "Open Design Canvas") orelse return error.MissingCanvasOpen;
    h.a.settings.applyUiMode(.zen);
    h.t.settle(1);
    _ = button(&h, "Switch to Developer mode") orelse return error.MissingModePill;
}

test "control audit: the side panel, files panel, command palette and pane zoom keep one name" {
    try testing.expectEqualStrings("Toggle side panel", pal.Entry.label(.toggle_side_panel).?);
    try testing.expectEqualStrings("Toggle files panel", pal.Entry.label(.toggle_files).?);
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.developer);
    h.t.settle(1);
    _ = button(&h, "Toggle files panel") orelse return error.MissingFilesToggle;
    try testing.expect(button(&h, "Toggle file explorer") == null);
    // The tab overview's palette button.
    @import("view_tab_overview.zig").open(&h.a);
    h.t.settle(1);
    const k = h.t.findText(if (mac) "\u{2318}K" else "Ctrl+K") orelse return error.MissingPaletteButton;
    const tip = tipAt(&h, k) orelse return error.MissingPaletteTooltip;
    try testing.expect(std.mem.startsWith(u8, tip, "Command palette"));
    @import("view_tab_overview.zig").close(&h.a);
    // The pane menu's zoom row.
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    strip.open(&h.a, .panel, .{ .chat = 0 }, .{ .x = 400, .y = 400, .w = 80, .h = 20 });
    h.t.settle(1);
    try testing.expect(h.t.hasText("Zoom pane"));
    try testing.expect(!h.t.hasText("Expand panel"));
}

test "control audit: the tab overview shows the user's split binding and the platform's keys" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try bind(&h, "splitTerminal", "mod-alt-y");
    @import("view_tab_overview.zig").open(&h.a);
    h.t.settle(1);
    try testing.expect(h.t.hasText(if (mac) "⌥⌘Y" else "Ctrl+Alt+Y"));
    try testing.expect(!h.t.hasText("⌘D"));
    try testing.expect(!h.t.hasText("⌘Del"));
}

// ---- Sidebar and palette ----

test "control audit: Developer sidebar has one new-session plus, in its title row" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.developer);
    h.a.view.sidebar_open = true;
    h.t.settle(1);
    const sidebar_w = @import("view_sidebar.zig").widthOf(&h.a);
    var footer_controls: usize = 0;
    var last: ui.Rect = .{};
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 26 and r.h == 26 and r.y >= 736 and r.x < sidebar_w) {
            footer_controls += 1;
            last = r;
        }
    }
    try testing.expectEqual(@as(usize, 1), footer_controls);
    try testing.expectEqualStrings("Chat history", tipAt(&h, last) orelse return error.MissingHistoryTooltip);
    _ = button(&h, "New session") orelse return error.MissingTitlebarPlus;
}

test "control audit: the palette offers one Design command, with one key" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const list = try palette.entries(&h.a, testing.allocator, "design");
    defer testing.allocator.free(list);
    var design: usize = 0;
    for (list) |e| if (e.label()) |l| {
        if (std.mem.indexOf(u8, l, "Design") != null) design += 1;
    };
    try testing.expectEqual(@as(usize, 1), design);
}

test "control audit: Zen's palette leaves out the filter toggle it can't show" {
    for ([_]@import("motion_rules.zig").UiMode{ .zen, .developer }) |mode| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.settings.applyUiMode(mode);
        const list = try palette.entries(&h.a, testing.allocator, "filters");
        defer testing.allocator.free(list);
        var listed = false;
        for (list) |e| if (e == .toggle_part and e.toggle_part == .multi_axis_filters) {
            listed = true;
        };
        try testing.expectEqual(mode != .zen, listed);
    }
}

test "control audit: Zen's New chat hint shows the rebindable new-session key" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    h.a.view.sidebar_open = true;
    try bind(&h, "newSession", "mod-alt-y");
    h.t.settle(1);
    try testing.expect(h.t.hasText("New chat"));
    try testing.expect(h.t.hasText(if (mac) "⌥⌘Y" else "Ctrl+Alt+Y"));
    try testing.expect(!h.t.hasText(if (mac) "⌘N" else "Ctrl+N"));
}

test "control audit: Zen's account row tooltip says a click opens settings" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    h.a.view.sidebar_open = true;
    h.t.settle(1);
    const r = h.a.view.account_anchor orelse return error.MissingAccountRow;
    const tip = tipAt(&h, r) orelse return error.MissingAccountTooltip;
    try testing.expect(std.mem.indexOf(u8, tip, "click for card") == null);
    try testing.expect(std.mem.indexOf(u8, tip, "click for settings") != null);
    h.t.click(center(r)[0], center(r)[1]);
    h.t.settle(1);
    try testing.expect(h.a.view.settings_open);
}

test "control audit: New project from the palette and Shift Cmd N opens the project form, not the destination sheet" {
    for ([_]bool{ false, true }) |from_palette| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        const tabs = h.a.tabs.items.items.len;
        if (from_palette) {
            palette.activate(&h.a, .new_project);
            h.t.settle(1);
        } else h.press(.{ .key = 'n', .cmd = true, .shift = true });
        try testing.expect(h.a.view.project_setup.open);
        try testing.expect(!h.a.view.open_chooser.open);
        try testing.expect(!h.t.hasText("Open a project"));
        try testing.expectEqual(tabs, h.a.tabs.items.items.len);
    }
}

// ---- Composer ----

fn sendButton(h: *Harness) ?@TypeOf(h.t.ctx.nodes.items[0]) {
    const i = iconBox(h, "arrow-up", 28, 28, 300) orelse return null;
    return h.t.ctx.nodes.items[i];
}

test "control audit: Send is dimmed with nothing to send or no engine, and a send while disconnected says so" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.engine.state = .connected;
    h.a.view.focus_composer = true;
    h.t.settle(1);
    try testing.expect((sendButton(&h) orelse return error.MissingSend).style.opacity < 0.5);
    h.a.composer.set("Synthetic message");
    h.t.settle(1);
    try testing.expect((sendButton(&h) orelse return error.MissingSend).style.opacity > 0.8);
    h.a.engine.state = .disconnected;
    h.t.settle(1);
    const send = sendButton(&h) orelse return error.MissingSend;
    try testing.expect(send.style.opacity < 0.5);
    h.a.clearNotice();
    h.t.click(center(send.rect)[0], center(send.rect)[1]);
    h.t.settle(1);
    const notice = h.a.noticeText() orelse return error.SilentSend;
    try testing.expect(std.mem.indexOf(u8, notice, "engine") != null);
    try testing.expectEqualStrings("Synthetic message", h.a.composer.text());
}

test "control audit: the queue row has no drag handle" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"q0","text":"Synthetic queued message"},{"id":"q1","text":"Another synthetic message"}]
    , .{});
    defer parsed.deinit();
    try h.a.queue.replace(parsed.value);
    h.t.settle(1);
    // (The Steer/Queue chip uses the same glyph; only the queue rows count.)
    for ([_][]const u8{ "Synthetic queued message", "Another synthetic message" }) |text| {
        const row = h.t.findText(text) orelse return error.MissingQueueRow;
        for (h.t.ctx.nodes.items) |node| if (isIcon(node, "queue-drag-handle")) {
            try testing.expect(node.rect.y + node.rect.h < row.y - 4 or node.rect.y > row.y + row.h + 4);
        };
    }
}

test "control audit: a plain Chat draft's model picker has no Starred or agent tabs" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.new_chat_mode = true;
    h.t.settle(1);
    h.a.picker = .model;
    @import("view_picker.zig").opened(&h.a);
    h.t.settle(1);
    try testing.expect(!h.a.view.model_picker.starred);
    try testing.expect(!h.t.hasText("Starred"));
    try testing.expect(!h.t.containsText("Ctrl+Tab agents"));
    // A coding draft keeps them.
    h.a.picker = .none;
    h.a.new_chat_mode = false;
    h.t.settle(1);
    h.a.picker = .model;
    @import("view_picker.zig").opened(&h.a);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Starred"));
}

test "control audit: a narrow new-chat footer draws the Project chip once" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.a.newTab();
    h.a.splitPane(.horizontal);
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    var width: f32 = 360;
    var second_row = false;
    while (width <= 1600) : (width += 20) {
        h.t.resize(width, 780);
        h.t.settle(1);
        // Row one holds the Chat | Code switch; a second row only the targets.
        var mode_y: ?f32 = null;
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |t| if (node.rect.y > 560 and std.mem.eql(u8, t.str, "Code")) {
                mode_y = node.rect.y + node.rect.h / 2;
            },
            else => {},
        };
        var projects: usize = 0;
        for (h.t.ctx.nodes.items) |node| if (node.rect.y > 560 and isIcon(node, "folder")) {
            projects += 1;
            if (mode_y) |y| if (node.rect.y > y + 8) {
                second_row = true;
            };
        };
        try testing.expect(projects <= 1);
    }
    try testing.expect(second_row);
}

test "control audit: /stop is offered only while a run is active" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.completion.commands_done = true;
    const completion = @import("composer_completion.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tok = @import("completion_rules.zig").token("/stop", 5).?;
    const offered = struct {
        fn f(rows: []const completion.Entry) bool {
            for (rows) |e| if (e.action) |act| if (act == .stop) return true;
            return false;
        }
    }.f;
    try testing.expect(!offered(try completion.entries(&h.a, arena.allocator(), tok)));
    const sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"a","status":"working","updatedAt":"2099-01-01T00:00:00Z"}]
    , .{});
    defer sessions.deinit();
    try h.a.sessions.replace(sessions.value);
    try testing.expect(offered(try completion.entries(&h.a, arena.allocator(), tok)));
}

test "control audit: the paperclip and microphone say what they do" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.dictation.probed.store(1, .release);
    h.a.view.focus_composer = true;
    h.t.settle(1);
    const clip = button(&h, "Attach") orelse return error.MissingAttachButton;
    try testing.expect(std.mem.indexOf(u8, tipAt(&h, rectOf(&h, clip)) orelse "", "Attach") != null);
    const mic = iconBox(&h, "microphone", 28, 28, 300) orelse return error.MissingMic;
    try testing.expectEqualStrings("Dictate", tipAt(&h, h.t.ctx.nodes.items[mic].rect) orelse return error.MissingMicTooltip);
}

// ---- Side panels ----

test "control audit: the empty Session pull requests pane has one repository button" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    @import("app_git.zig").open(&h.a, .github);
    h.t.settle(1);
    try testing.expect(h.t.hasText("No session-linked pull requests"));
    try testing.expect(h.t.hasText("Browse repository"));
    try testing.expect(!h.t.hasText("Repository"));
}

test "control audit: the diffs toolbar's discard and fold icons are named" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const panels = @import("app_panels.zig");
    panels.addDiffsTab(&h.a);
    var d: panels.Diff = .{ .arena = .init(testing.allocator), .additions = 1, .deletions = 1 };
    d.files = try @import("diff.zig").parse(d.arena.allocator(),
        \\diff --git a/src/synthetic.rs b/src/synthetic.rs
        \\--- a/src/synthetic.rs
        \\+++ b/src/synthetic.rs
        \\@@ -1,2 +1,2 @@
        \\ fn parse() {
        \\-    old();
        \\+    new();
        \\
    );
    if (h.a.panels.diff) |*old| old.arena.deinit();
    h.a.panels.diff = d;
    h.a.panels.diff_loading = false;
    h.t.settle(1);
    const trash = button(&h, "Undo all changes") orelse return error.MissingDiscardName;
    try testing.expectEqual(@as(usize, 1), iconsUnder(&h, trash.node_index, "trash-bin-minimalistic"));
    try testing.expectEqualStrings("Undo all changes", tipAt(&h, rectOf(&h, trash)) orelse return error.MissingDiscardTooltip);
    const fold = button(&h, "Collapse all files") orelse return error.MissingFoldName;
    try testing.expectEqualStrings("Collapse all files", tipAt(&h, rectOf(&h, fold)) orelse return error.MissingFoldTooltip);
}

test "control audit: Design canvas zoom buttons are not arrows" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.design);
    @import("app_panels.zig").openDesignCanvas(&h.a);
    h.t.settle(1);
    const out = button(&h, "Zoom out") orelse return error.MissingZoomOut;
    const in = button(&h, "Zoom in") orelse return error.MissingZoomIn;
    try testing.expectEqual(@as(usize, 0), iconsUnder(&h, out.node_index, "alt-arrow-left"));
    try testing.expectEqual(@as(usize, 0), iconsUnder(&h, in.node_index, "alt-arrow-right"));
    try testing.expectEqual(@as(usize, 1), iconsUnder(&h, in.node_index, "plus"));
}

test "control audit: a generated visual button with no handler is not drawn as a live button" {
    const clock = @import("visual_luau.zig").TestClock.init();
    defer clock.deinit();
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"vis-inert","role":"assistant","status":"complete","parts":[
        \\ {"id":"v-inert","kind":"visual","title":"Synthetic controls","script":"return function() return ui.row { ui.button { label = \"Inert action\" }, ui.button { label = \"Live action\", onClick = function() end } } end"}]}]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(1);
    var inert: ?bool = null;
    var live: ?bool = null;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |t| {
            const is_inert = std.mem.eql(u8, t.str, "Inert action");
            if (!is_inert and !std.mem.eql(u8, t.str, "Live action")) continue;
            var at = node.parent;
            while (at != none) : (at = h.t.ctx.nodes.items[at].parent) {
                const box = h.t.ctx.nodes.items[at];
                if (box.style.min_height == 38) {
                    if (is_inert) inert = box.style.control else live = box.style.control;
                    break;
                }
            }
        },
        else => {},
    };
    try testing.expectEqual(@as(?bool, true), live);
    try testing.expectEqual(@as(?bool, false), inert);
}
