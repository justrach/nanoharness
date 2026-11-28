//! Current desktop navigation/composer contracts, with made-up state only.
//! Import from tests.zig; the orchestrator owns running the shared build.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const sidebar = @import("view_sidebar.zig");
const composer = @import("view_composer.zig");
const draft = @import("view_newchat.zig");
const menus = @import("view_sidebar_menus.zig");
const write = @import("view_write.zig");
const settings = @import("settings.zig");
const testing = std.testing;

test {
    _ = @import("tests_ui_sidebar_fade.zig");
}

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
            \\[{"id":"synthetic-project","deviceId":"synthetic-device","path":"/work/synthetic-notes","gitDetected":false}]
        , .{});
        defer spaces.deinit();
        try h.a.spaces.replace(spaces.value);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-chat","deviceId":"synthetic-device","title":"Synthetic navigation conversation","spaceId":"synthetic-project","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
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

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

fn disclosureArrow(t: *ui.Tester, label: []const u8) !ui.Rect {
    const text = textNode(t, label) orelse return error.NoDisclosureLabel;
    const parent = t.ctx.node(text).parent;
    for (t.ctx.nodes.items) |node| {
        if (node.parent == parent and node.rect.w == 12 and node.rect.h == 12) return node.rect;
    }
    return error.NoDisclosureArrow;
}

test "sidebar disclosure arrows stay aligned through hover collapse and Cmd+B" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[ {"id":"pin","deviceId":"synthetic-device","title":"Pinned example","spaceId":"synthetic-project","archived":false},
        \\  {"id":"live","deviceId":"synthetic-device","title":"Active example","spaceId":"synthetic-project","archived":false},
        \\  {"id":"archive","deviceId":"synthetic-device","title":"Archived example","spaceId":"synthetic-project","archived":true} ]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.settings.setPins(&.{"pin"});
    h.a.settings.set(.sidebar_show_archived, true);
    h.a.settings.setText("sidebarOrganization", "by_project");
    h.a.view.archived_open = true;
    h.t.settle(1);
    h.snap("sidebar-disclosure-alignment");
    const pinned = try disclosureArrow(&h.t, "Pinned");
    const project = try disclosureArrow(&h.t, "synthetic-notes");
    const archived = try disclosureArrow(&h.t, "Archived");
    try testing.expectApproxEqAbs(sidebar.widthOf(&h.a) - 31, project.x, 0.01);
    try testing.expectApproxEqAbs(pinned.x, project.x, 0.01);
    try testing.expectApproxEqAbs(pinned.x, archived.x, 0.01);

    h.t.moveTo(project.x + 6, project.y + 6);
    h.t.settle(1);
    try testing.expectApproxEqAbs(project.x, (try disclosureArrow(&h.t, "synthetic-notes")).x, 0.01);
    h.snap("sidebar-disclosure-hover");
    h.t.click(project.x + 6, project.y + 6);
    h.t.settle(1);
    try testing.expectApproxEqAbs(project.x, (try disclosureArrow(&h.t, "synthetic-notes (1)")).x, 0.01);
    h.t.click(project.x + 6, project.y + 6);
    h.t.settle(1);

    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    h.t.settle(1);
    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    h.t.settle(1);
    try testing.expectApproxEqAbs(project.x, (try disclosureArrow(&h.t, "synthetic-notes")).x, 0.01);
    try testing.expectApproxEqAbs(project.x, (try disclosureArrow(&h.t, "Pinned")).x, 0.01);
    try testing.expectApproxEqAbs(project.x, (try disclosureArrow(&h.t, "Archived")).x, 0.01);
}

test "retention 194 open workspace rows use each chat harness mark" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[ {"id":"claude","title":"Claude pane","archived":false,"config":{"harness":"claude-code"}},
        \\  {"id":"codex","title":"Codex pane","archived":false,"config":{"harness":"codex"}},
        \\  {"id":"unknown","title":"Future pane","archived":false,"config":{"harness":"future-agent"}} ]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.openChat("claude", null);
    try h.a.tabs.isolateWorkspace();
    h.a.addChatTab(false);
    h.a.openChat("codex", null);
    h.a.addChatTab(false);
    h.a.openChat("unknown", null);
    h.t.settle(1);
    h.snap("retention-194-mixed-harness");
    inline for (.{ .{ "Claude pane", "claude-mark" }, .{ "Codex pane", "openai-mark" }, .{ "Future pane", "graff-mark" } }) |pair| {
        var found = false;
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |text| if (std.mem.eql(u8, text.str, pair[0]) and node.rect.x < sidebar.widthOf(&h.a) and node.rect.y < 210) {
                for (h.t.ctx.nodes.items) |mark| switch (mark.content) {
                    .image => |image| if (@abs(mark.rect.y + mark.rect.h / 2 - node.rect.y - node.rect.h / 2) < 3 and mark.rect.x < node.rect.x) {
                        if (image.source == .encoded and std.mem.eql(u8, image.source.encoded, @import("icons_svg").get(pair[1]))) found = true;
                    },
                    else => {},
                };
            },
            else => {},
        };
        try testing.expect(found);
    }
    // Harness identity does not replace the ordinary list's independent dot.
    var status_dot = false;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.w == 6 and node.rect.h == 6 and node.rect.x < 30 and node.rect.y > 220 and node.style.background != null) status_dot = true;
    }
    try testing.expect(status_dot);
}

fn textNode(t: *ui.Tester, label: []const u8) ?u32 {
    for (t.ctx.nodes.items, 0..) |node, i| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, label)) return @intCast(i),
        else => {},
    };
    return null;
}

test "draft target controls keep four points around the computer and project" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const code = textNode(&h.t, "Code") orelse return error.NoModeChip;
    const mode = h.t.ctx.node(h.t.ctx.node(code).parent).rect;
    const strip = @import("view_tab_strip.zig");
    var buf: [160]u8 = undefined;
    const label = try std.fmt.bufPrint(&buf, "Run on: {s}", .{strip.deviceLabel(&h.a, strip.device(&h.a, strip.active(&h.a)))});
    const node = textNode(&h.t, label) orelse return error.NoComputerChip;
    const computer = h.t.ctx.node(h.t.ctx.node(node).parent).rect;
    const project = h.a.view.space_anchor orelse return error.NoProjectChip;
    try testing.expectApproxEqAbs(@as(f32, 4), computer.x - mode.x - mode.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 4), project.x - computer.x - computer.w, 0.01);
}

test "desktop parity composer alignment matches the reference and compact width budget" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.dictation.probed.store(1, .release);
    // The shell keeps 235 points outside this pane (sidebar + inset panel chrome).
    h.t.resize(607, 440);
    h.t.settle(1);
    const pill = h.a.view.composer_anchor orelse return error.NoComposer;
    const field = for (h.t.ctx.nodes.items) |node| {
        if (node.id == h.a.view.composer_id) break node.rect.inset(node.style.padding);
    } else return error.NoComposerField;
    try testing.expectApproxEqAbs(@as(f32, 340), pill.w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 49), pill.h, 0.01);
    // Measure the writing area, not the outer hitbox that includes the chip gutters.
    try testing.expectApproxEqAbs(@as(f32, 75), field.x - pill.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 212), field.w, 0.01);
    var controls: [3]ui.Rect = undefined;
    var n: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 28 and r.h == 28 and r.x > pill.x and r.x < pill.x + pill.w and r.y > pill.y and r.y < pill.y + pill.h) {
            if (n >= controls.len) return error.ExtraComposerControl;
            controls[n] = r;
            n += 1;
        }
    }
    try testing.expectEqual(controls.len, n);
    try testing.expectApproxEqAbs(@as(f32, 9), controls[0].x - pill.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2), controls[1].x - controls[0].x - controls[0].w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 9), pill.x + pill.w - controls[2].x - controls[2].w, 0.01);
    for (controls) |r| try testing.expectApproxEqAbs(pill.y + pill.h / 2, r.y + r.h / 2, 0.01);
    const model = h.a.view.chip_anchor orelse return error.NoModelChip;
    const code = textNode(&h.t, "Code") orelse return error.NoModeChip;
    const mode = h.t.ctx.node(h.t.ctx.node(code).parent).rect;
    const project = h.a.view.space_anchor orelse return error.NoProjectChip;
    try testing.expectApproxEqAbs(@as(f32, 10), model.x - pill.x, 0.01);
    try testing.expectApproxEqAbs(pill.y + pill.h + 8, model.y, 0.01);
    try testing.expectApproxEqAbs(model.y + 12, mode.y + mode.h / 2, 0.01);
    // Too narrow for its words, the project chip is drawn once, centred in
    // the targets' own row under the first (24 + 2 gap + 22 / 2).
    try testing.expectApproxEqAbs(model.y + 37, project.y + project.h / 2, 0.01);
    const last = textNode(&h.t, "Tour this project") orelse return error.NoStarter;
    const chip = h.t.ctx.node(h.t.ctx.node(last).parent).rect;
    try testing.expectApproxEqAbs(@as(f32, 24), pill.y - chip.y - chip.h, 0.01);
    h.snap("alignment-reference-width");

    // GPUI's compact_capacity is the measured field less eight points.
    // Six fewer pane points cross its 200-point compact minimum even empty.
    h.t.resize(601, 440);
    h.t.settle(1);
    try testing.expect(h.a.view.composer_expanded);
    try testing.expect(h.a.view.composer_anchor.?.h >= composer.expanded_min);
}

test "desktop parity sidebar history is the footer's last control and has a 350ms tooltip" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var controls: [1]ui.Rect = undefined;
    var count: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 26 and r.h == 26 and r.y >= 736 and r.x < sidebar.widthOf(&h.a)) {
            if (count >= controls.len) return error.ExtraFooterControl;
            controls[count] = r;
            count += 1;
        }
    }
    // The title row's "New session" is the only "+"; none repeats it here.
    try testing.expectEqual(@as(usize, 1), count);
    h.t.moveTo(controls[0].x + 13, controls[0].y + 13);
    h.t.advance(0.3);
    try testing.expect(h.t.tooltipText() == null);
    h.t.advance(0.06);
    try testing.expectEqualStrings("Chat history", h.t.tooltipText() orelse return error.MissingHistoryTooltip);
}

test "desktop parity drafts and conversations share the compact dock and maximum width" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        try testing.expect(h.a.selected == null);
        const fresh = h.a.view.composer_anchor orelse return error.NoDraftComposer;
        try testing.expectApproxEqAbs(@as(f32, 49), fresh.h, 1);
        try testing.expectApproxEqAbs(@as(f32, 736), fresh.w, 1);
        try testing.expect(fresh.y > 600);
        try testing.expect(!h.t.hasText("Working in"));
        const starter = h.t.findText("Build something new") orelse return error.NoStarter;
        try testing.expect(starter.y + starter.h <= fresh.y);
        h.snap(if (dark) "desktop-draft-dark" else "desktop-draft-light");
        h.a.openChatInTab("synthetic-chat");
        h.t.settle(1);
        const established = h.a.view.composer_anchor orelse return error.NoSessionComposer;
        try testing.expectApproxEqAbs(fresh.x, established.x, 1);
        try testing.expectApproxEqAbs(fresh.w, established.w, 1);
        try testing.expectApproxEqAbs(fresh.y + fresh.h, established.y + established.h, 1);
        try testing.expect(!h.t.hasText("Build something new"));
    }
}

test "desktop parity starter keeps suggestions, focuses input, and targets a fresh folder" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try testing.expect(h.t.hasText("Tour this project"));
    try h.t.clickText("Build something new");
    h.t.settle(0.3);
    try testing.expect(h.a.new_no_project);
    try testing.expect(h.a.newChatSpace() == null);
    try testing.expect(std.mem.endsWith(u8, h.a.composer.text(), "My idea: "));
    try testing.expect(h.t.hasText("Build something new"));
    try testing.expect(!h.t.hasText("Tour this project"));
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    try testing.expect(h.a.view.composer_anchor.?.h >= composer.expanded_min);
    h.snap("desktop-starter-expanded");
}

test "sidebar avatar keeps signed-in identity in its tooltip and menu" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.account.scope = .synced;
    h.a.account.user = .{
        .name = try testing.allocator.dupe(u8, "Synthetic User"),
        .email = try testing.allocator.dupe(u8, "synthetic@example.invalid"),
    };
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Synthetic User"));
    // Footer whitespace is not a second click target.
    h.t.click(76, 758);
    try testing.expect(!h.a.view.account_menu);
    const avatar = h.a.view.account_anchor orelse return error.NoAvatar;
    h.t.moveTo(avatar.x + avatar.w / 2, avatar.y + avatar.h / 2);
    h.t.advance(0.5);
    try testing.expect(h.t.hasText("Account menu: Synthetic User"));
    h.t.click(avatar.x + avatar.w / 2, avatar.y + avatar.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.account_menu);
    try testing.expect(h.t.hasText("synthetic@example.invalid"));
}

test "desktop parity sidebar starts with project filter and exposes only current menu fields" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try testing.expectEqual(@as(f32, 224), sidebar.widthOf(&h.a));
    const filter = h.t.findText("All projects") orelse return error.NoProjectFilter;
    try testing.expect(filter.y < 80);
    try testing.expect(!h.t.hasText("Tabs · 1"));
    // Footer whitespace must not open the avatar's account menu.
    h.t.click(76, 758);
    try testing.expect(!h.a.view.account_menu);
    menus.openView(&h.a);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Organize"));
    try testing.expect(h.t.hasText("Sort"));
    try testing.expect(h.t.hasText("Last activity"));
    try testing.expect(h.t.hasText("All"));
    const last_act = h.t.findText("Last activity").?;
    h.t.moveTo(last_act.x + 4, last_act.y + last_act.h / 2);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("1d"));
    try testing.expect(h.t.hasText("3d"));
    try testing.expect(h.t.hasText("7d"));
    try testing.expect(h.t.hasText("30d"));
    try h.t.clickText("7d");
    h.t.settle(0.3);
    try testing.expectEqual(settings.LastActivity.d7, h.a.settings.lastActivity());
    // Completed (unseen ✓) and pinned sessions older than 7d must be filtered out.
    const now = std.Io.Clock.Timestamp.now(testing.io, .real).raw.toMilliseconds();
    const old_ms = now - 14 * 24 * 60 * 60 * 1000;
    const recent_ms = now - 2 * 60 * 60 * 1000;
    const aged = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"recent-chat","deviceId":"synthetic-device","title":"Recent item","spaceId":"synthetic-project","archived":false},
        \\ {"id":"old-completed","deviceId":"synthetic-device","title":"Old completed","spaceId":"synthetic-project","archived":false},
        \\ {"id":"old-pinned","deviceId":"synthetic-device","title":"Old pinned","spaceId":"synthetic-project","archived":false}]
    , .{});
    defer aged.deinit();
    try h.a.chats.replace(aged.value);
    h.a.chats.items[0].last_message_ms = recent_ms;
    h.a.chats.items[1].last_message_ms = old_ms;
    h.a.chats.items[2].last_message_ms = old_ms;
    h.a.settings.setPins(&.{"old-pinned"});
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Recent item"));
    try testing.expect(!h.t.hasText("Old completed"));
    try testing.expect(!h.t.hasText("Old pinned"));
    try h.t.clickText("Last activity");
    h.a.settings.setText("sidebarLastActivity", "all");
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Compact"));
    try testing.expect(h.t.hasText("Archived"));
    try testing.expect(!h.t.hasText("Show"));
    try testing.expect(!h.t.hasText("Agent icon"));
    try h.t.clickText("Compact");
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Agent icon"));
    try testing.expect(h.t.hasText("Last updated"));
    try testing.expect(h.t.hasText("Project name"));
    try h.t.clickText("Last updated");
    h.t.settle(0.3);
    try testing.expect(!h.a.settings.get(.sidebar_show_updated));
    try testing.expect(h.a.view.more_menu);
    h.snap("desktop-sidebar-display-menu");
}

test "desktop parity Write has a top toolbar and saves the same draft back to the dock" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.composer.set("Synthetic draft");
    write.open(&h.a);
    h.t.settle(0.3);
    try testing.expect(h.t.hasText("Edit message"));
    try testing.expect(h.t.hasText("Send now"));
    try testing.expect(h.t.hasText("Save"));
    try testing.expect(!h.t.hasText("Done"));
    const save = h.t.findText("Save") orelse return error.NoSave;
    const edit = h.t.findText("Edit message") orelse return error.NoEditLabel;
    const edit_node = textNode(&h.t, "Edit message") orelse return error.NoEditLabel;
    const label_node = h.t.ctx.node(edit_node).parent;
    const toolbar_node = h.t.ctx.node(label_node).parent;
    const bar = h.t.ctx.node(toolbar_node).rect;
    var divider: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        if (node.parent == toolbar_node and node.rect.h == 1) divider = node.rect;
    }
    const rule = divider orelse return error.NoToolbarDivider;
    try testing.expectApproxEqAbs(bar.x, rule.x, 0.01);
    try testing.expectApproxEqAbs(bar.w, rule.w, 0.01);
    try testing.expectApproxEqAbs(bar.y + write.toolbar_h - 1, rule.y, 0.01);
    try testing.expectApproxEqAbs(edit.y, save.y, 2);
    try testing.expect(save.y < 140);
    h.snap("desktop-write-toolbar");
    try h.t.clickText("Save");
    h.t.settle(0.3);
    try testing.expect(!h.a.view.write_open);
    try testing.expectEqualStrings("Synthetic draft", h.a.composer.text());
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
}

test "desktop parity Write Escape saves the draft and restores persistent starters" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.composer.set("Synthetic keyboard round trip");
    _ = h.t.shortcut(write.toggle);
    h.t.settle(0.3);
    try testing.expect(h.a.view.write_open);
    try testing.expect(h.t.hasText("Save"));
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(0.3);
    try testing.expect(!h.a.view.write_open);
    try testing.expect(h.t.hasText("Build something new"));
    try testing.expectEqualStrings("Synthetic keyboard round trip", h.a.composer.text());
    h.snap("desktop-write-keyboard-roundtrip");
}

test "clicking the composer expand button opens Write even on an attachment-only draft with empty text" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try @import("app_attachments.zig").stage(&h.a, "image.png", "synthetic-png-bytes");
    h.t.settle(0.3);
    try testing.expectEqual(@as(usize, 0), h.a.composer.text().len);
    var expand_rect: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.w == 28 and node.rect.h == 28 and node.rect.y > 680 and node.rect.x > 300 and node.rect.x < 500) {
            expand_rect = node.rect;
        }
    }
    const r = expand_rect orelse return error.NoExpandButton;
    h.t.click(r.x + r.w / 2, r.y + r.h / 2);
    h.t.settle(0.3);
    try testing.expect(h.a.view.write_open);
    try testing.expect(h.t.hasText("Edit message"));
}

test "sidebar single-line content is vertically centered inside its box" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-chat","deviceId":"synthetic-device","title":"Box title","spaceId":"synthetic-project","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        const sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"chatId":"synthetic-chat","status":"awaitingInput"}]
        , .{});
        defer sessions.deinit();
        try h.a.sessions.replace(sessions.value);
        h.a.sessions.items[0].updated_ms = h.a.nowMs();
        for ([_]@import("motion_rules.zig").UiMode{ .developer, .zen }) |mode| {
            h.a.settings.applyUiMode(mode);
            h.a.settings.set(.sidebar_compact, true);
            h.a.settings.setText("sidebarOrganization", "inOneList");
            for ([_]bool{ true, false }) |context| {
                h.a.settings.set(.sidebar_show_harness, context);
                h.a.settings.set(.sidebar_show_project_icon, context);
                h.a.settings.set(.sidebar_show_project_label, context);
                h.a.settings.set(.sidebar_show_branch, context);
                h.a.settings.set(.sidebar_show_updated, context);
                for ([_]bool{ true, false }) |waiting| {
                    h.a.sessions.items[0].status = if (waiting) .awaiting_input else .idle;
                    h.t.moveTo(1100, 100);
                    h.t.settle(0.2);
                    for ([_]bool{ false, true }) |hovered| {
                        const title = textNode(&h.t, "Box title") orelse return error.NoSessionTitle;
                        const text = h.t.ctx.node(title).rect;
                        var parent = h.t.ctx.node(title).parent;
                        while (parent != 0 and h.t.ctx.node(parent).style.radius != 7 and h.t.ctx.node(parent).style.radius != 8) {
                            parent = h.t.ctx.node(parent).parent;
                        }
                        if (parent == 0) return error.NoSessionBox;
                        const row = h.t.ctx.node(parent).rect;
                        if (hovered) {
                            h.t.moveTo(row.x + 4, row.y + row.h / 2);
                            h.t.settle(0.2);
                            const hovered_title = textNode(&h.t, "Box title") orelse return error.NoHoveredTitle;
                            const ht = h.t.ctx.node(hovered_title).rect;
                            try testing.expectApproxEqAbs(row.y + row.h / 2, ht.y + ht.h / 2, 0.51);
                        } else {
                            if (mode == .developer and context and waiting) h.snap(if (dark) "sidebar-centering-dark" else "sidebar-centering-light");
                            try testing.expectApproxEqAbs(row.y + row.h / 2, text.y + text.h / 2, 0.51);
                        }
                    }
                }
            }
        }
    }
}

test "desktop parity layout rules cover narrow wrapping, reserved context, and Write gutters" {
    const widths = [_]f32{ 100, 100, 100 };
    try testing.expectEqual(@as(usize, 2), draft.chipRowEnd(&widths, 0, 206));
    try testing.expectEqual(@as(usize, 1), draft.chipRowEnd(&widths, 0, 205));
    try testing.expectEqual(@as(usize, 1), draft.chipRowEnd(&widths, 0, 0));
    try testing.expectEqual(@as(f32, 30), sidebar.contextHeight(false, false, false, false));
    for (1..16) |mask| try testing.expectEqual(@as(f32, 38), sidebar.contextHeight(mask & 1 != 0, mask & 2 != 0, mask & 4 != 0, mask & 8 != 0));
    try testing.expectEqual(@as(usize, 5), menus.viewItemCount(true));
    try testing.expectEqual(@as(usize, 10), menus.viewItemCount(false));
    try testing.expect(settings.LastActivity.d1.matches(1_000_000, 1_000_000 + 23 * 60 * 60 * 1000));
    try testing.expect(!settings.LastActivity.d1.matches(1_000_000, 1_000_000 + 25 * 60 * 60 * 1000));
    try testing.expect(settings.LastActivity.d7.matches(1_000_000, 1_000_000 + 6 * 24 * 60 * 60 * 1000));
    try testing.expect(!settings.LastActivity.d7.matches(1_000_000, 1_000_000 + 8 * 24 * 60 * 60 * 1000));
    try testing.expect(settings.LastActivity.all.matches(1_000_000, 1_000_000 + 365 * 24 * 60 * 60 * 1000));
    try testing.expectEqual(menus.Choice.archived, menus.displayRows(true)[0]);
    try testing.expectEqual(@as(f32, 380), write.pageWidth(420));
    try testing.expectEqual(@as(f32, 400), write.pageWidth(480));
    try testing.expectEqual(@as(f32, 720), write.pageWidth(1600));
}

test "desktop parity settings default to project groups and clamp saved sidebar widths" {
    var s: settings.Store = .{ .gpa = testing.allocator, .io = testing.io };
    defer s.deinit();
    try testing.expectEqual(settings.Organization.by_project, s.organization());
    try testing.expectEqual(@as(f32, 224), s.sidebarWidth());
    s.setNumber("sidebarWidth", 10);
    try testing.expectEqual(@as(f32, 224), s.sidebarWidth());
    s.setNumber("sidebarWidth", 900);
    try testing.expectEqual(@as(f32, 400), s.sidebarWidth());
    s.setNumber("sidebarWidth", 300);
    try testing.expectEqual(@as(f32, 300), s.sidebarWidth());
    try testing.expectEqualStrings("General", settings.Section.appearance.group());
    try testing.expectEqualStrings("Agents", settings.Section.agents.group());
    try testing.expectEqualStrings("Devices and data", settings.Section.archived.group());
}

test "desktop parity project navigation reuses its workspace and keeps peer conversations" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-project","deviceId":"synthetic-device","path":"/work/notes","gitDetected":false},
        \\ {"id":"other-project","deviceId":"synthetic-device","path":"/work/other","gitDetected":false}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"first","deviceId":"synthetic-device","title":"First conversation","spaceId":"synthetic-project","archived":false},
        \\ {"id":"second","deviceId":"synthetic-device","title":"Second conversation","spaceId":"synthetic-project","archived":false},
        \\ {"id":"other","deviceId":"synthetic-device","title":"Other project conversation","spaceId":"other-project","archived":false}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.openChat("first", "synthetic-project");
    const palette = @import("view_palette.zig");
    palette.activate(&h.a, .{ .chat = "other" });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expect(h.a.tabs.layout() != null);
    try testing.expectEqualStrings("other", h.a.selected.?);
    h.t.settle(1);
    const project_group = h.t.findText("notes") orelse return error.NoProjectGroup;
    var other_workspace_row = false;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.startsWith(u8, text.str, "Other project") and node.rect.x < sidebar.widthOf(&h.a) and node.rect.y < project_group.y) {
            other_workspace_row = true;
        },
        else => {},
    };
    try testing.expect(other_workspace_row);
    palette.activate(&h.a, .{ .chat = "second" });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
    try testing.expectEqualStrings("second", h.a.selected.?);
    const split = h.a.tabs.layout().?;
    try testing.expectEqual(@as(usize, 2), split.groups[split.focus].count());
    palette.activate(&h.a, .{ .chat = "first" });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);
    try testing.expectEqualStrings("first", h.a.selected.?);
}

test "retention 794 New workspace remains distinct from the pane New tab action" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChat("synthetic-chat", "synthetic-project");
    try h.a.tabs.isolateWorkspace();
    h.t.settle(1);
    const workspaces = h.a.tabs.items.items.len;
    const old_layout = h.a.tabs.layout().?;
    const old_tabs = old_layout.groups[0].items.items.ptr;
    const old_panes = old_layout.panes.items.len;
    // The pane menu's New tab asks for a destination in the existing panel.
    const strip = @import("view_tab_strip.zig");
    strip.newTab(&h.a, .{ .chat = old_layout.focus });
    h.t.settle(1);
    try testing.expect(h.a.view.open_chooser.open);
    try testing.expectEqual(@import("app_open_chooser.zig").Intent.new_tab, h.a.view.open_chooser.intent);
    try testing.expectEqual(workspaces, h.a.tabs.items.items.len);
    @import("app_open_chooser.zig").close(&h.a);
    h.t.settle(1);
    // The sidebar title row's "+" ("New session") makes a workspace; the
    // footer no longer repeats it.
    var create: ?ui.Rect = null;
    for (h.t.ctx.a11y_items.items) |item| {
        const r = h.t.ctx.nodes.items[item.node_index].rect;
        if (std.mem.eql(u8, item.label, "New session") and r.x < sidebar.widthOf(&h.a)) create = r;
    }
    const button = create orelse return error.NoWorkspaceCreate;
    h.t.moveTo(button.x + button.w / 2, button.y + button.h / 2);
    h.t.advance(0.4);
    try testing.expectEqualStrings("New session", h.t.tooltipText() orelse return error.NoWorkspaceTooltip);
    h.snap("retention-794-new-workspace-label");
    h.t.click(button.x + button.w / 2, button.y + button.h / 2);
    h.t.settle(1);
    try testing.expectEqual(workspaces + 1, h.a.tabs.items.items.len);
    try testing.expectEqual(old_panes, h.a.tabs.splits.items[0].?.panes.items.len);
    try testing.expect(h.a.tabs.splits.items[0].?.groups[0].items.items.ptr == old_tabs);
    try testing.expect(!h.a.view.open_chooser.open);
}

test "desktop parity sidebar exposes independent drafts and restores their prompts" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChat("synthetic-chat", "synthetic-project");
    try h.a.tabs.isolateWorkspace();
    h.a.addChatTab(false);
    h.a.composer.set("First workspace draft");
    h.a.newWorkspaceSession();
    h.a.composer.set("Second workspace draft");
    h.t.settle(1);
    try testing.expect(h.t.hasText("New session"));
    try h.t.clickText("New session");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.active);
    try testing.expectEqualStrings("First workspace draft", h.a.composer.text());
}

test "draft computer selection remains available in the titlebar" {
    for ([_]bool{ false, true }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        h.a.select(null, "synthetic-project");
        h.t.settle(1);
        const computer = h.a.view.strip.device_anchor orelse return error.NoComputerChip;
        try testing.expect(computer.y < 38);
        const project = h.a.view.space_anchor orelse return error.NoProjectChip;
        try testing.expect(project.y > 38);
    }
}

test "desktop parity account menu shows one identity line and an avatar-only footer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try testing.expect(!h.t.hasText("Local only"));
    h.a.view.account_menu = true;
    h.t.settle(1);
    try testing.expect(h.t.hasText("Stored on this device"));
    try testing.expect(!h.t.hasText("Local only"));
    const identity = h.t.findText("Stored on this device") orelse return error.NoIdentity;
    const sign_in = h.t.findText("Sign in with Codegraff") orelse return error.NoSignIn;
    try testing.expect(identity.y < sign_in.y);
    const sign_in_node = textNode(&h.t, "Sign in with Codegraff") orelse return error.NoSignIn;
    const label = h.t.ctx.node(sign_in_node).parent;
    const row = h.t.ctx.node(h.t.ctx.node(label).parent).rect;
    // GPUI menu_row_base uses five points above and below its 13-point text.
    try testing.expectApproxEqAbs(@as(f32, 31), row.h, 0.1);
}

test "desktop parity projectless drafts retain a footer computer picker" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.pickDraftDevice("synthetic-projectless-device");
    h.t.settle(1);
    try testing.expect(h.a.newChatSpace() == null);
    var label_buf: [160]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buf, "Run on: {s}", .{@import("view_tab_strip.zig").deviceLabel(&h.a, h.a.draftDevice())});
    var footer: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, label) and node.rect.y > 38) {
            footer = node.rect;
        },
        else => {},
    };
    const computer = footer orelse return error.NoComputerChip;
    h.t.click(computer.x + computer.w / 2, computer.y + computer.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.strip.menu == .device);
    try testing.expect(h.a.view.strip.device_anchor.?.y > 38);
    try testing.expect(h.t.hasText("No project"));
}

/// A draft in a project with git: the footer's full set of controls.
fn gitDraft(h: *Harness) !void {
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-git","deviceId":"synthetic-device","name":"synthetic","path":"/work/synthetic","gitDetected":true}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    if (h.a.space) |old| h.a.gpa.free(old);
    h.a.space = try h.a.gpa.dupe(u8, "synthetic-git");
    h.a.new_ref = try h.a.gpa.dupe(u8, "main");
    h.a.select(null, null);
    h.t.settle(1);
    // Anchors are the frame before's: one more so they are this layout's.
    h.t.frame();
}

/// The draft's target chips moved to their own row under the footer's
/// first when they had no room for their words.
fn targetRowControls(h: *Harness, out: []ui.Rect) ![]ui.Rect {
    const model = h.a.view.chip_anchor orelse return error.NoModelChip;
    const pill = h.a.view.composer_anchor orelse return error.NoComposer;
    var n: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.h != 20 or r.w <= 0 or r.x < pill.x or r.y < model.y + 24 or r.y + r.h > model.y + 50) continue;
        if (n >= out.len) return error.ExtraFooterControl;
        out[n] = r;
        n += 1;
    }
    return out[0..n];
}

/// The footer's controls after the model chip: every 20-point box in its
/// 24-point row.
fn footerControls(h: *Harness, out: []ui.Rect) ![]ui.Rect {
    const model = h.a.view.chip_anchor orelse return error.NoModelChip;
    var n: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.h != 20 or r.w <= 0 or r.y < model.y or r.y + r.h > model.y + 24 or r.x < model.x + model.w) continue;
        if (n >= out.len) return error.ExtraFooterControl;
        out[n] = r;
        n += 1;
    }
    return out[0..n];
}

test "draft footer controls end inside the composer in split panes" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try gitDraft(&h);
    var buf: [8]ui.Rect = undefined;

    // Unsplit there is room: every control keeps its words.
    for ([_][]const u8{ "Code", "synthetic", "New worktree", "From main" }) |label| try testing.expect(h.t.hasText(label));
    try testing.expectEqual(@as(usize, 5), (try footerControls(&h, &buf)).len);

    h.a.splitPane(.horizontal);
    // A fresh sibling intentionally resets Git picks. Choose its own base
    // before checking the full footer's responsive geometry.
    try testing.expect(h.a.new_ref == null);
    h.a.new_ref = try h.a.gpa.dupe(u8, "main");
    h.t.settle(1);
    for ([_]f32{ 1440, 1200, 1000, 900 }) |window_w| {
        h.t.resize(window_w, 780);
        h.t.settle(1);
        if (window_w == 1200) h.snap("draft-footer-split-pane");
        const pill = h.a.view.composer_anchor orelse return error.NoComposer;
        const controls = try footerControls(&h, &buf);
        var row2_buf: [4]ui.Rect = undefined;
        const targets = try targetRowControls(&h, &row2_buf);
        // Mode, computer, project, checkout and ref, across the two rows:
        // none left out or drawn twice, none past the row's 10-point inset,
        // each whole or its 28-point glyph.
        try testing.expectEqual(@as(usize, 5), controls.len + targets.len);
        for (targets) |r| try testing.expect(r.x + r.w <= pill.x + pill.w - 10 + 0.01);
        for (controls, 0..) |r, i| {
            try testing.expect(r.x + r.w <= pill.x + pill.w - 10 + 0.01);
            try testing.expect(r.w >= 28);
            if (i > 0) try testing.expectApproxEqAbs(@as(f32, 4), r.x - controls[i - 1].x - controls[i - 1].w, 0.01);
        }
        // The ref is the last to give up its words.
        if (window_w >= 1000) try testing.expect(h.t.hasText("From main"));
    }

    // 900 points wide: the checkout is a glyph that still opens its menu,
    // and says what it is.
    try testing.expect(!h.t.hasText("New worktree"));
    const checkout = h.a.view.checkout_anchor orelse return error.NoCheckoutChip;
    try testing.expectApproxEqAbs(@as(f32, 28), checkout.w, 0.01);
    h.t.moveTo(checkout.x + checkout.w / 2, checkout.y + checkout.h / 2);
    h.t.advance(0.56);
    try testing.expectEqualStrings("New worktree", h.t.tooltipText() orelse return error.NoTooltip);
    h.t.click(checkout.x + checkout.w / 2, checkout.y + checkout.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.checkout_menu);
    try testing.expect(h.t.hasText("Current checkout"));
}

test "zen mode flattens sidebar and footer hierarchy while developer mode restores full controls" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try gitDraft(&h);

    // Developer mode exposes git checkout/branch chips in the draft footer.
    try testing.expectEqual(@import("motion_rules.zig").UiMode.developer, h.a.settings.uiMode());
    try testing.expect(h.t.hasText("New worktree"));
    try testing.expect(h.t.hasText("From main"));

    // Switching to Zen mode flattens the sidebar to a single list and hides git plumbing in the footer.
    h.a.settings.applyUiMode(.zen);
    h.a.settings.setNumber("sidebarWidth", 256);
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
    try testing.expectEqual(settings.Organization.in_one_list, h.a.settings.organization());
    try testing.expect(!h.t.hasText("New worktree"));
    try testing.expect(!h.t.hasText("From main"));

    // Toggling UI mode returns to Developer mode and restores the full hierarchy.
    h.a.settings.toggleUiMode();
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.developer, h.a.settings.uiMode());
    try testing.expectEqual(settings.Organization.by_project, h.a.settings.organization());
    try testing.expect(h.t.hasText("New worktree"));
    try testing.expect(h.t.hasText("From main"));

    // 1-click sidebar footer pill switches straight from Dev -> Zen and Zen -> Dev.
    const dev_pill = textNode(&h.t, "Dev") orelse return error.NoSidebarModePill;
    const pill_rect = h.t.ctx.node(h.t.ctx.node(dev_pill).parent).rect;
    h.t.click(pill_rect.x + pill_rect.w / 2, pill_rect.y + pill_rect.h / 2);
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
    try testing.expect(h.t.hasText("Sign in"));
    try testing.expect(h.t.hasText("New chat"));
    try testing.expect(!h.t.hasText("New worktree"));
    const zen_pill = textNode(&h.t, "Zen") orelse return error.NoZenFooterModePill;
    const zen_rect = h.t.ctx.node(h.t.ctx.node(zen_pill).parent).rect;
    h.t.click(zen_rect.x + zen_rect.w / 2, zen_rect.y + zen_rect.h / 2);
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.developer, h.a.settings.uiMode());
    h.a.settings.toggleUiMode();
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());

    // Cmd+Shift+M toggles back to Developer mode in one shortcut, and again back to Zen.
    try testing.expect(h.t.shortcut(.{ .key = 'm', .cmd = true, .shift = true }));
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.developer, h.a.settings.uiMode());
    try testing.expect(h.t.hasText("New worktree"));
    try testing.expect(h.t.shortcut(.{ .key = 'm', .cmd = true, .shift = true }));
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());

    // Individual moving parts can be turned on and off independently while keeping Zen's flat list and mode.
    h.a.settings.toggleMovingPart(.git_checkout_chrome);
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
    try testing.expect(h.a.settings.hierarchyProfile().shows_git_checkout_chrome);
    try testing.expect(h.a.settings.hierarchyProfile().flat_session_list);
    try testing.expect(h.t.hasText("New worktree"));
    h.a.settings.toggleMovingPart(.git_checkout_chrome);
    h.t.settle(0.3);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.zen, h.a.settings.uiMode());
    try testing.expect(!h.a.settings.hierarchyProfile().shows_git_checkout_chrome);
    try testing.expect(!h.t.hasText("New worktree"));

    // Command palette preserves 5 idle actions and surfaces mode/part switches when queried.
    const pal = @import("palette.zig");
    try testing.expectEqual(@as(usize, 5), pal.actionsFor("", true).len);
    try testing.expect(pal.actionsFor("zen", true).len >= 1);
    try testing.expect(pal.actionsFor("rail", true).len >= 1);
}

test "zeron sidebar layout, titlebar back/forward navigation, and smooth disclosure collapse" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    h.a.settings.setNumber("sidebarWidth", 256);
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"proj-h","deviceId":"synthetic-device","name":"Harness","path":"/work/harness","gitDetected":true},
        \\ {"id":"proj-m","deviceId":"synthetic-device","name":"Mail","path":"/work/mail","gitDetected":true}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    const now = std.Io.Clock.Timestamp.now(testing.io, .real).raw.toMilliseconds();
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"c-init","deviceId":"synthetic-device","title":"Initial Greeting Session","config":{"harness":"claude-code"},"spaceId":"proj-h","archived":false},
        \\ {"id":"c-casual","deviceId":"synthetic-device","title":"Casual Greeting Session","config":{"harness":"codex"},"spaceId":"proj-m","archived":false},
        \\ {"id":"c-arch","deviceId":"synthetic-device","title":"hey there","config":{"harness":"claude-code"},"spaceId":"proj-m","archived":true}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.chats.items[0].last_message_ms = now;
    h.a.chats.items[1].last_message_ms = now - 23 * 60 * 60 * 1000;
    h.a.chats.items[2].last_message_ms = now - 23 * 60 * 60 * 1000;
    h.t.settle(1);

    // Titlebar hosts right-aligned [⋯] at y < 38, and filterRow is a compact pill ("All projects").
    const more = h.a.view.more_anchor orelse return error.MissingMoreButton;
    try testing.expect(more.y < 38);
    try testing.expect(more.x > 180);
    const filter = h.a.view.filter_anchor orelse return error.MissingFilterPill;
    try testing.expect(filter.w >= 90 and filter.w <= 200);
    try testing.expect(h.t.hasText("All projects"));
    try testing.expect(h.t.hasText("New chat"));
    try testing.expect(h.t.hasText("Search"));
    try testing.expect(h.t.hasText("Pull requests"));
    try testing.expect(h.t.hasText("Activity"));
    try testing.expect(h.t.hasText("Archived"));
    try testing.expect(h.t.hasText("Star on GitHub"));
    try testing.expect(h.t.hasText("Sign in"));
    try testing.expect(!h.t.hasText("Local"));

    // Navigate Home -> c-init -> c-casual, then verify [←] and [→] history navigation.
    try testing.expect(!h.a.canGoBack());
    h.a.openChatInTab("c-init");
    h.t.settle(0.4);
    try testing.expect(h.a.canGoBack());
    try testing.expect(!h.a.canGoForward());
    h.snap("desktop-zeron-sidebar");

    // Zen mode omits Developer mode's protruding folder-tab cap and frames
    // both the sidebar and right workspace panel as symmetric rounded-12 inset cards.
    try testing.expect(@import("view_tab_strip.zig").rendering.selectedBounds(&h.a) == null);
    var zen_left_card = false;
    var zen_right_card = false;
    for (h.t.ctx.nodes.items) |n| {
        if (n.style.radius == 12 and @abs(n.rect.y - 42) < 0.5) {
            if (n.rect.x < 256 and n.rect.w > 200 and n.rect.h > 400) zen_left_card = true;
            if (n.rect.x >= 256 and n.rect.w > 400 and n.rect.h > 400) zen_right_card = true;
        }
    }
    try testing.expect(zen_left_card and zen_right_card);

    // Selected chat appears in the topbar session pill as well as the sidebar.
    var topbar_pill = false;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (n.rect.y < 42 and std.mem.eql(u8, tx.str, "Initial Greeting Session")) {
            topbar_pill = true;
            break;
        },
        else => {},
    };
    try testing.expect(topbar_pill);

    h.a.goBack();
    h.t.settle(0.4);
    try testing.expect(h.a.selected == null);
    try testing.expect(h.a.canGoForward());
    h.a.goForward();
    h.t.settle(0.4);
    try testing.expectEqualStrings("c-init", h.a.selected.?);

    // Smooth 0.18s disclosure collapse & expand on "Activity".
    const hasCasualInSidebar = struct {
        fn check(t: *ui.Tester) bool {
            for (t.ctx.nodes.items) |n| switch (n.content) {
                .text => |tx| if (n.rect.x < 256 and std.mem.startsWith(u8, tx.str, "Casual Greeting")) return true,
                else => {},
            };
            return false;
        }
    }.check;
    try testing.expect(hasCasualInSidebar(&h.t));
    try h.t.clickText("Activity");
    h.t.advance(0.06);
    try testing.expect(!h.a.view.sessions_open);
    // Mid-collapse: disclosure tween is active and still revealing partial rows.
    const sess_tw = h.a.view.disclosures.get("sessions") orelse return error.MissingSessionsTween;
    try testing.expect(sess_tw.animating(h.t.ctx.time, false));
    h.t.settle(1);
    try testing.expect(!hasCasualInSidebar(&h.t));
    try testing.expect(h.t.hasText("Activity (2)"));
    try h.t.clickText("Activity (2)");
    h.t.settle(1);
    try testing.expect(hasCasualInSidebar(&h.t));

    // Opening Settings in Zen mode frames both Settings nav and page as symmetric rounded-12 cards
    // at y == 42 while keeping the active session pill clickable in the 42pt top bar.
    @import("view_settings.zig").open(&h.a);
    h.t.settle(0.4);
    var settings_top_tab = false;
    var settings_chat_left_card = false;
    var settings_chat_right_card = false;
    for (h.t.ctx.nodes.items) |n| {
        if (n.style.radius == 12 and @abs(n.rect.y - 42) < 0.5 and n.rect.h > 400) {
            if (n.rect.x < 256 and n.rect.w > 200) settings_chat_left_card = true;
            if (n.rect.x >= 256 and n.rect.w > 400) settings_chat_right_card = true;
        }
        switch (n.content) {
            .text => |tx| if (n.rect.y < 42 and n.rect.x >= 256 and std.mem.eql(u8, tx.str, "Initial Greeting Session")) {
                settings_top_tab = true;
            },
            else => {},
        }
    }
    try testing.expect(settings_top_tab);
    try testing.expect(settings_chat_left_card and settings_chat_right_card);

    // Pure luminance invariant: Zen cards stay strictly lighter than the shell across dark×frosted combinations.
    const panel_chrome = @import("view_panel_chrome.zig");
    const surfaces = @import("surface_palette.zig");
    for ([_]bool{ false, true }) |is_dark| {
        const base = theme.builtin(is_dark);
        for ([_]bool{ false, true }) |is_frosted| {
            const k = surfaces.apply(base, is_frosted);
            const page = panel_chrome.zenPageBg(k);
            const sh = k.shell.alpha(1);
            try testing.expect(theme.contrast(page, .{}) > theme.contrast(sh, .{}));
            if (!is_frosted) {
                const side_bg = panel_chrome.zenSidebarBg(k);
                try testing.expect(theme.contrast(side_bg, .{}) > theme.contrast(sh, .{}));
            }
        }
    }
}

test "top-right unified updates pill opens the 340pt popover and dispatches Update & Update all" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-device","name":"Synthetic Mac Studio","online":true}]
    , .{});
    defer devs.deinit();
    try h.a.devices.replace(devs.value);
    if (h.a.device_id) |old| h.a.gpa.free(old);
    h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");

    const updates = @import("agent_updates.zig");
    try updates.setTestStatuses(&h.a, "synthetic-device", true,
        \\[{"harness":"claude-code","installedVersion":"2.1.319","latestVersion":"2.1.322","phase":"available","canApply":true},
        \\ {"harness":"pi","installedVersion":"1.5.0","latestVersion":"1.5.2","phase":"available","canApply":true},
        \\ {"harness":"opencode","installedVersion":"1.0.2-R2040.1","latestVersion":"1.4.15-R8339.1","phase":"available","canApply":true}]
    );
    h.t.settle(1);
    h.t.frame();

    // No Home bottom island anymore; unified updates pill sits in top-right titlebar.
    try testing.expect(!h.t.hasText("3 agent updates \u{00b7} Synthetic Mac Studio"));
    const btn_rect = h.a.view.updates_anchor orelse return error.MissingTopbarUpdatesButton;
    try testing.expect(btn_rect.y < 38);
    try testing.expect(btn_rect.x > 700);
    h.snap("desktop-updates-button");

    // Click top-right pill to open the 340pt anchored popover.
    h.t.click(btn_rect.x + btn_rect.w / 2, btn_rect.y + btn_rect.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.updates_popover);
    try testing.expect(h.t.hasText("Update all"));
    try testing.expect(h.t.hasText("Claude Code"));
    try testing.expect(h.t.hasText("2.1.319 \u{2192} 2.1.322"));
    try testing.expect(h.t.hasText("Pi"));
    try testing.expect(h.t.hasText("OpenCode"));
    h.snap("desktop-updates-popover");

    // Clicking a single [Update] button dispatches ApplyHarnessUpdate for Claude Code.
    try h.t.clickText("Update");
    h.t.settle(0.3);
    const single = h.a.agent_updates.last_action orelse return error.MissingDispatchedUpdateAction;
    try testing.expectEqualStrings("ApplyHarnessUpdate", single.method);
    try testing.expectEqualStrings("claude-code", single.harness);

    // Clicking [Update all] dispatches updates across all updatable rows (reaching opencode).
    try h.t.clickText("Update all");
    h.t.settle(0.3);
    const batch = h.a.agent_updates.last_action orelse return error.MissingDispatchedBatchAction;
    try testing.expectEqualStrings("ApplyHarnessUpdate", batch.method);
    try testing.expectEqualStrings("opencode", batch.harness);

    // 4+ updates inside the popover wrap in a scroll container with overlay scrollbar and 18pt bottom fade.
    try updates.setTestStatuses(&h.a, "synthetic-device", true,
        \\[{"harness":"claude-code","installedVersion":"2.1.319","latestVersion":"2.1.322","phase":"available","canApply":true},
        \\ {"harness":"codex","installedVersion":"0.168.0","latestVersion":"0.169.0","phase":"available","canApply":true},
        \\ {"harness":"pi","installedVersion":"1.5.0","latestVersion":"1.5.2","phase":"available","canApply":true},
        \\ {"harness":"opencode","installedVersion":"1.0.2","latestVersion":"1.4.15","phase":"available","canApply":true}]
    );
    h.t.settle(0.4);
    h.t.frame();
    try testing.expect(h.a.view.updates_popover);
    var has_scroll_fade_list = false;
    for (h.t.ctx.nodes.items) |n| {
        if (n.style.scroll and n.style.scroll_edge_fade == 18 and n.style.scrollbar == .overlay) {
            has_scroll_fade_list = true;
            break;
        }
    }
    try testing.expect(has_scroll_fade_list);
}

test "unified updates Skip persists per version token and reappears only when a newer version arrives" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-device","name":"Synthetic Mac Studio","online":true}]
    , .{});
    defer devs.deinit();
    try h.a.devices.replace(devs.value);
    if (h.a.device_id) |old| h.a.gpa.free(old);
    h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");

    const updates = @import("agent_updates.zig");
    const avail =
        \\[{"harness":"claude-code","installedVersion":"2.1.319","latestVersion":"2.1.322","phase":"available","canApply":true}]
    ;
    try updates.setTestStatuses(&h.a, "synthetic-device", true, avail);
    h.t.settle(1);
    h.t.frame();
    const btn_rect = h.a.view.updates_anchor orelse return error.MissingTopbarUpdatesButton;
    h.t.click(btn_rect.x + btn_rect.w / 2, btn_rect.y + btn_rect.h / 2);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Skip"));

    try h.t.clickText("Skip");
    h.t.settle(1);
    try testing.expect(h.a.settings.isUpdateSkipped("agent:synthetic-device:claude-code", "2.1.322"));
    try testing.expect(h.a.view.updates_anchor == null);
    try testing.expect(!h.a.view.updates_popover);

    // Re-receiving the same version keeps it hidden.
    try updates.setTestStatuses(&h.a, "synthetic-device", true, avail);
    h.t.settle(1);
    try testing.expect(h.a.view.updates_anchor == null);

    // Receiving a newer version brings the topbar updates pill back.
    try updates.setTestStatuses(&h.a, "synthetic-device", true,
        \\[{"harness":"claude-code","installedVersion":"2.1.322","latestVersion":"2.1.330","phase":"available","canApply":true}]
    );
    h.t.settle(1);
    h.t.frame();
    try testing.expect(h.a.view.updates_anchor != null);
}

test "topbar updates pill disappears automatically once agent or engine updates finish" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-device","name":"Synthetic Mac Studio","online":true}]
    , .{});
    defer devs.deinit();
    try h.a.devices.replace(devs.value);
    if (h.a.device_id) |old| h.a.gpa.free(old);
    h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");

    const updates = @import("agent_updates.zig");
    const vu = @import("view_updates.zig");

    // 1. Available agent update renders the topbar updates pill.
    try updates.setTestStatuses(&h.a, "synthetic-device", true,
        \\[{"harness":"claude-code","installedVersion":"2.1.319","latestVersion":"2.1.322","phase":"available","canApply":true}]
    );
    h.t.settle(1);
    h.t.frame();
    try testing.expectEqual(@as(usize, 1), vu.topbarUpdatesCount(&h.a));
    try testing.expect(h.a.view.updates_anchor != null);

    // 2. Once the agent finishes updating (`phase: "updated"`), the topbar pill goes away automatically.
    try updates.setTestStatuses(&h.a, "synthetic-device", true,
        \\[{"harness":"claude-code","installedVersion":"2.1.322","latestVersion":"2.1.322","phase":"updated","canApply":false}]
    );
    h.t.settle(1);
    h.t.frame();
    h.snap("completed-update-pill");
    try testing.expectEqual(@as(usize, 0), vu.topbarUpdatesCount(&h.a));
    try testing.expectEqual(@as(f32, 0), vu.topbarUpdatesWidth(&h.a));
    try testing.expect(h.a.view.updates_anchor == null);
    try testing.expect(!h.a.view.updates_popover);

    // 3. A completed Codegraff engine update (`graff_kind == .updated`) also stays out of the topbar pill,
    //    while a staged desktop app update awaiting Restart (matching installed version) still stays actionable.
    const to = "0.302.99.0";
    @memcpy(h.a.updates.graff_to[0..to.len], to);
    h.a.updates.graff_to_len = to.len;
    h.a.updates.graff_kind = .updated;
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 0), vu.topbarUpdatesCount(&h.a));

    const app_ver = "99.0.0";
    @memcpy(h.a.release.latest[0..app_ver.len], app_ver);
    h.a.release.latest_len = app_ver.len;
    h.a.updates.setAppInstalled(app_ver);
    h.t.settle(1);
    h.t.frame();
    try testing.expectEqual(@as(usize, 1), vu.topbarUpdatesCount(&h.a));
    try testing.expect(h.a.view.updates_anchor != null);
}

test "failed Codex Xcode license update shows diagnostic, Copy command, and local-only Open Terminal (#125)" {
    const updates = @import("agent_updates.zig");
    const vu = @import("view_updates.zig");

    // 1. Local Mac: surfaces Xcode license explanation, Copy command, Open Terminal, and Retry.
    {
        var h: Harness = undefined;
        try h.init(false);
        defer h.deinit();
        h.a.settings.applyUiMode(.zen);
        const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-device","name":"Synthetic MacBook","online":true}]
        , .{});
        defer devs.deinit();
        try h.a.devices.replace(devs.value);
        if (h.a.device_id) |old| h.a.gpa.free(old);
        h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");

        try updates.setTestStatuses(&h.a, "synthetic-device", true,
            \\[{"harness":"codex","installedVersion":"0.171.0","latestVersion":"0.172.0","phase":"failed","canApply":true,"error":{"kind":"install","message":"Error: Agreeing to the Xcode/iOS license requires admin privileges, please run \"sudo xcodebuild -license\" and then retry this command."}}]
        );
        h.t.settle(1);
        h.t.frame();
        const btn = h.a.view.updates_anchor orelse return error.MissingTopbarUpdatesButton;
        h.t.click(btn.x + btn.w / 2, btn.y + btn.h / 2);
        h.t.settle(0.4);
        h.t.frame();
        try testing.expect(h.a.view.updates_popover);
        try testing.expect(h.t.hasText("Homebrew can\u{2019}t update Codex until you accept the Xcode license."));
        try testing.expect(h.t.hasText("Copy command"));
        try testing.expect(h.t.hasText("Open Terminal"));
        try testing.expect(h.t.hasText("Retry"));
        try testing.expect(h.t.hasText("Skip"));

        try h.t.clickText("Copy command");
        h.t.settle(0.2);
        try testing.expectEqualStrings(vu.xcode_license_cmd, h.t.clipboard.items);

        try h.t.clickText("Open Terminal");
        h.t.settle(0.2);
        try testing.expectEqual(@as(u32, 1), h.a.updates.test_opened_terminal_count);
        try testing.expect(h.a.agent_updates.last_action == null);

        try h.t.clickText("Retry");
        h.t.settle(0.2);
        const retry = h.a.agent_updates.last_action orelse return error.MissingRetryAction;
        try testing.expectEqualStrings("ApplyHarnessUpdate", retry.method);
        try testing.expectEqualStrings("codex", retry.harness);
    }

    // 2. Remote Mac: shows remote device recovery instruction and omits Open Terminal.
    {
        var h: Harness = undefined;
        try h.init(false);
        defer h.deinit();
        h.a.settings.applyUiMode(.zen);
        const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-device","name":"Local MacBook","online":true},{"id":"remote-mac","name":"Build Mini","online":true}]
        , .{});
        defer devs.deinit();
        try h.a.devices.replace(devs.value);
        if (h.a.device_id) |old| h.a.gpa.free(old);
        h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");

        try updates.setTestStatuses(&h.a, "remote-mac", true,
            \\[{"harness":"codex","installedVersion":"0.171.0","latestVersion":"0.172.0","phase":"failed","canApply":true,"error":{"kind":"install","message":"Error: please run sudo xcodebuild -license"}}]
        );
        h.t.settle(1);
        h.t.frame();
        const btn = h.a.view.updates_anchor orelse return error.MissingTopbarUpdatesButton;
        h.t.click(btn.x + btn.w / 2, btn.y + btn.h / 2);
        h.t.settle(0.4);
        h.t.frame();
        try testing.expect(h.t.hasText("Homebrew can\u{2019}t update Codex until you accept the Xcode license."));
        try testing.expect(h.t.hasText("Run sudo xcodebuild -license on Build Mini, review and accept the license, then retry."));
        try testing.expect(h.t.hasText("Copy command"));
        try testing.expect(!h.t.hasText("Open Terminal"));
        try testing.expect(h.t.hasText("Retry"));
    }

    // 3. Generic unrecognized failure: shows wrapped diagnostic alongside Retry and Skip.
    {
        var h: Harness = undefined;
        try h.init(false);
        defer h.deinit();
        h.a.settings.applyUiMode(.zen);
        const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-device","name":"Local MacBook","online":true}]
        , .{});
        defer devs.deinit();
        try h.a.devices.replace(devs.value);
        if (h.a.device_id) |old| h.a.gpa.free(old);
        h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");

        try updates.setTestStatuses(&h.a, "synthetic-device", true,
            \\[{"harness":"codex","installedVersion":"0.171.0","latestVersion":"0.172.0","phase":"failed","canApply":true,"error":{"kind":"install","message":"Error: SHA256 checksum mismatch for codex bottle"}}]
        );
        h.t.settle(1);
        h.t.frame();
        const btn = h.a.view.updates_anchor orelse return error.MissingTopbarUpdatesButton;
        h.t.click(btn.x + btn.w / 2, btn.y + btn.h / 2);
        h.t.settle(0.4);
        h.t.frame();
        try testing.expect(h.t.hasText("Error: SHA256 checksum mismatch for codex bottle"));
        try testing.expect(!h.t.hasText("Open Terminal"));
        try testing.expect(!h.t.hasText("Copy command"));
        try testing.expect(h.t.hasText("Retry"));
        try testing.expect(h.t.hasText("Skip"));
    }
}

test "an update failure that only mentions Xcode and a LICENSE file keeps its own diagnostic (#125)" {
    const updates = @import("agent_updates.zig");
    const vu = @import("view_updates.zig");
    const unrelated = "npm error EACCES: permission denied, unlink '/opt/demo/node_modules/xcode/LICENSE'";

    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    const devs = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-device","name":"Local MacBook","online":true}]
    , .{});
    defer devs.deinit();
    try h.a.devices.replace(devs.value);
    if (h.a.device_id) |old| h.a.gpa.free(old);
    h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-device");

    try updates.setTestStatuses(&h.a, "synthetic-device", true,
        \\[{"harness":"codex","installedVersion":"0.171.0","latestVersion":"0.172.0","phase":"failed","canApply":true,"error":{"kind":"install","message":"npm error EACCES: permission denied, unlink '/opt/demo/node_modules/xcode/LICENSE'"}}]
    );
    h.t.settle(1);
    h.t.frame();
    const btn = h.a.view.updates_anchor orelse return error.MissingTopbarUpdatesButton;
    h.t.click(btn.x + btn.w / 2, btn.y + btn.h / 2);
    h.t.settle(0.4);
    h.t.frame();
    if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/update-failure-unrelated.png", .{std.mem.span(dir)});
        h.t.screenshot(path) catch {};
    }
    try testing.expect(h.t.hasText(unrelated));
    try testing.expect(!h.t.hasText("Copy command"));
    try testing.expect(!h.t.hasText("Open Terminal"));
    try testing.expect(h.t.hasText("Retry"));
    try testing.expect(h.t.hasText("Skip"));

    try testing.expect(!vu.isXcodeLicenseBlocker(null));
    try testing.expect(!vu.isXcodeLicenseBlocker(unrelated));
    try testing.expect(!vu.isXcodeLicenseBlocker("license changed\nnpm error gyp: No Xcode or CLT version detected!"));
    for ([_][]const u8{
        "Error: You have not agreed to the Xcode license. Run `sudo xcodebuild -license` and retry.",
        "You have not agreed to the Xcode license agreements.",
        "Agreeing to the Xcode/iOS license requires admin privileges",
        "The Xcode license has not been accepted",
        "  sudo xcodebuild -license accept",
    }) |msg| try testing.expect(vu.isXcodeLicenseBlocker(msg));
}

test "sidebar star banner, right-click menu, bottom account row, and compact model account popover" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    h.t.settle(1);

    // Right-click on the Star on GitHub banner opens its context menu and copies codegraff URL.
    const star_txt = h.t.findText("Star on GitHub") orelse return error.MissingStarBanner;
    h.t.secondaryClick(star_txt.x + 12, star_txt.y + star_txt.h / 2);
    h.t.settle(0.4);
    try testing.expect(h.a.view.star_menu);
    try testing.expect(h.t.hasText("Open in browser"));
    try testing.expect(h.t.hasText("Copy link"));
    try h.t.clickText("Copy link");
    h.t.settle(0.4);
    try testing.expectEqualStrings(sidebar.star_github_url, h.t.clipboard.items);
    try testing.expect(!h.a.view.star_menu);

    // Left-clicking Star on GitHub records the codegraff URL and persists dismissal.
    try h.t.clickText("Star on GitHub");
    h.t.settle(0.4);
    try testing.expectEqualStrings("https://github.com/justrach/codegraff", h.a.view.last_opened_url.?);
    try testing.expect(h.a.settings.get(.star_banner_dismissed));
    try testing.expect(!h.t.hasText("Star on GitHub"));

    // Reset star banner and verify close button dismisses without opening URL.
    h.a.settings.set(.star_banner_dismissed, false);
    h.a.gpa.free(h.a.view.last_opened_url.?);
    h.a.view.last_opened_url = null;
    h.t.settle(0.4);
    const sr = h.t.findText("Star on GitHub") orelse return error.MissingStarBanner;
    var close_rect: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .image => if (@abs((n.rect.y + n.rect.h / 2) - (sr.y + sr.h / 2)) < 8 and n.rect.x < 256) {
            if (close_rect == null or n.rect.x > close_rect.?.x) close_rect = n.rect;
        },
        else => {},
    };
    const cr = close_rect orelse return error.MissingStarClose;
    h.t.click(cr.x + cr.w / 2, cr.y + cr.h / 2);
    h.t.settle(0.4);
    try testing.expect(h.a.settings.get(.star_banner_dismissed));
    try testing.expect(h.a.view.last_opened_url == null);
    try testing.expect(!h.t.hasText("Star on GitHub"));

    // Clicking Sign in in bottom sidebar account row opens Settings directly on the Account section
    // with symmetric rounded-12 Settings cards at y == 42, single Back to chats + esc hints, and no duplicate Back button.
    try h.t.clickText("Sign in");
    h.t.settle(0.4);
    try testing.expect(h.a.view.settings_open);
    try testing.expectEqual(settings.Section.account, h.a.settings.section);
    try testing.expect(h.t.hasText("Harness Account"));
    try testing.expect(h.t.hasText("Yours when you sign in"));
    try testing.expect(h.t.hasText("Back to chats"));
    const side_w = h.a.settings.sidebarWidth();
    var settings_left_card = false;
    var settings_right_card = false;
    var duplicate_back_row = false;
    var topbar_nav_control = false;
    var esc_badge_count: usize = 0;
    for (h.t.ctx.nodes.items) |n| {
        if (n.style.radius == 12 and @abs(n.rect.y - 42) < 0.5 and n.rect.h > 400) {
            if (n.rect.x < side_w and n.rect.w > side_w - 20) settings_left_card = true;
            if (n.rect.x >= side_w and n.rect.w > 400) settings_right_card = true;
        }
        switch (n.content) {
            .text => |tx| {
                if (std.mem.eql(u8, tx.str, "Back")) duplicate_back_row = true;
                if (std.mem.eql(u8, tx.str, "esc")) esc_badge_count += 1;
            },
            else => {},
        }
        if (n.rect.y < 38 and n.rect.x < side_w and n.rect.w == 24 and n.rect.h == 24 and n.style.control) {
            topbar_nav_control = true;
        }
    }
    try testing.expect(settings_left_card and settings_right_card);
    try testing.expect(!duplicate_back_row);
    try testing.expect(!topbar_nav_control);
    // One way out of Settings, Back to chats with its esc hint; no second Close pill.
    try testing.expectEqual(@as(usize, 1), esc_badge_count);

    // Pressing Escape exits Zen Settings cleanly; reopening and clicking "Back to chats" also exits.
    _ = h.t.shortcut(.{ .key = @import("nanoui").ui.Shortcut.escape });
    h.t.settle(0.4);
    try testing.expect(!h.a.view.settings_open);
    try h.t.clickText("Sign in");
    h.t.settle(0.4);
    try testing.expect(h.a.view.settings_open);

    // Click the single "Back to chats" row to close Settings while remaining in the draft workspace.
    try h.t.clickText("Back to chats");
    h.t.settle(0.4);
    try testing.expect(!h.a.view.settings_open);

    // Test compact composer model+account+slider popover with per-model brand accent color.
    h.a.setHarness("codex");
    const mfor = try h.a.gpa.dupe(u8, "codex");
    h.a.retireSlice(h.a.models_for);
    h.a.models_for = mfor;
    const mjson = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"openai/gpt-6.1-sol","label":"GPT-6.1-Sol","context":1048576,"maker":"openai","billing":"plan","reasoningLevels":["low","medium","high","xhigh"],"defaultReasoningLevel":"high"}]
    , .{});
    defer mjson.deinit();
    try h.a.models.replace(mjson.value);
    h.a.setModel("openai/gpt-6.1-sol");
    const accts = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"accounts":[{"id":"acct-1","harness":"codex","email":"alex@example.com","active":true,"switchable":true},{"id":"acct-2","harness":"codex","email":"team@example.com","active":false,"switchable":true}]}
    , .{});
    defer accts.deinit();
    @import("view_settings_accounts.zig").setSnapshot(&h.a, accts.value);
    h.t.settle(0.4);
    h.a.togglePickerCompact();
    h.t.settle(0.4);
    try testing.expect(h.a.view.model_picker.track != null);
    const tr = h.a.view.model_picker.track.?;
    var has_blue_rail = false;
    var has_capsule_thumb = false;
    var slider_textures: usize = 0;
    for (h.t.ctx.nodes.items) |n| {
        if (n.content == .texture and n.rect.y >= tr.y - 2 and n.rect.y <= tr.y + tr.h + 2) {
            slider_textures += 1;
        }
        if (n.rect.h == 28 and n.rect.w > 40) {
            if (n.style.background) |bg| {
                if (bg.b > bg.r + 0.2) has_blue_rail = true;
            }
        }
        if (n.rect.w == 44 and n.rect.h == 32) {
            has_capsule_thumb = true;
        }
    }
    try testing.expectEqual(@as(usize, 0), slider_textures);
    try testing.expect(has_blue_rail);
    try testing.expect(has_capsule_thumb);
    try testing.expect(h.t.hasText("Account"));
    try testing.expect(h.t.hasText("alex@example.com"));
    try testing.expect(h.t.hasText("REASONING"));
    try h.t.clickText("Account");
    h.t.settle(0.4);
    try testing.expect(h.a.view.model_picker.account_submenu);
    try testing.expect(h.t.hasText("Add account"));

    // Close picker and open a chat panel: unscrolled Zen chat panel must not paint topFade strips.
    h.a.togglePickerCompact();
    h.a.openChatInTab("synthetic-chat");
    h.t.settle(0.4);
    var top_fade_strips: usize = 0;
    for (h.t.ctx.nodes.items) |n| {
        if (n.rect.x >= side_w and n.rect.y >= 42 and n.rect.y < 70 and n.rect.h == 1 and n.rect.w > 200) {
            if (n.style.background != null) top_fade_strips += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), top_fade_strips);
}

test "modelEffortColor uses Harness per-model brand colors across dark and light modes" {
    const picker = @import("view_picker.zig");
    const dark_k = theme.colors(true);
    const light_k = theme.colors(false);

    const gpt: @import("workspace.zig").Model = .{ .id = "openai/gpt-6.1-sol", .label = "GPT-6.1-Sol", .maker = "openai" };
    try testing.expectEqual(@as(u24, 0x66b5ff), picker.colorToHex(picker.modelEffortColor(gpt, "codex", dark_k)));
    try testing.expectEqual(@as(u24, 0x2563eb), picker.colorToHex(picker.modelEffortColor(gpt, "codex", light_k)));

    const claude: @import("workspace.zig").Model = .{ .id = "anthropic/claude-opus-5.5", .label = "Claude Opus 5.5", .maker = "anthropic" };
    try testing.expectEqual(@as(u24, 0xd97757), picker.colorToHex(picker.modelEffortColor(claude, "claude-code", dark_k)));
    try testing.expectEqual(@as(u24, 0xd97757), picker.colorToHex(picker.modelEffortColor(claude, "claude-code", light_k)));

    const unknown: @import("workspace.zig").Model = .{ .id = "custom/model", .label = "Custom Model" };
    try testing.expectEqual(picker.colorToHex(dark_k.accent), picker.colorToHex(picker.modelEffortColor(unknown, "custom", dark_k)));
}

test "desktop 3-pane horizontal split contains tool rows, question chips, and session footer within each pane" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.t.resize(1280, 780);
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"proj-split","deviceId":"synthetic-device","name":"harness","path":"/work/harness","gitDetected":true}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"split-a","deviceId":"synthetic-device","title":"Left Split Pane","spaceId":"proj-split","cwd":"/work/.graff/worktrees/s1","branch":"feat/split-a","archived":false},
        \\ {"id":"split-b","deviceId":"synthetic-device","title":"Center Split Pane","spaceId":"proj-split","cwd":"/work/.graff/worktrees/s2","branch":"feat/split-b","archived":false},
        \\ {"id":"split-c","deviceId":"synthetic-device","title":"Right Split Pane","spaceId":"proj-split","cwd":"/work/.graff/worktrees/s3","branch":"feat/split-c","archived":false}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);

    h.a.openChatInTab("split-a");
    h.a.splitPane(.horizontal);
    h.a.tabs.setCurrent("split-b");
    h.a.select("split-b", "proj-split");
    h.a.splitPane(.horizontal);
    h.a.tabs.setCurrent("split-c");
    h.a.select("split-c", "proj-split");
    h.a.focusPane(1);
    h.t.settle(1);

    const doc_b = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"e1","role":"assistant","status":"complete","parts":[
        \\  {"id":"t1","kind":"tool","resolved":true,"call":{"kind":"shell","command":"git status --short"}},
        \\  {"id":"t2","kind":"tool","resolved":true,"call":{"kind":"editFile","path":"apps/nano/src/view_question.zig"}},
        \\  {"id":"m1","kind":"text","text":"Checking where `main`, the branches and the worktrees stand before changing anything."},
        \\  {"id":"q1","kind":"input","resolved":false,"questions":[{"id":"q-main","header":"Cleanup","question":"This worktree is now on `main`, level with `origin/main` (b3727a7), which cleanup mode should run?","options":["Prune clean throwaway worktrees","Keep all worktrees"]}]}
        \\]}]}
    , .{});
    defer doc_b.deinit();
    try h.a.transcript.apply(doc_b.value);
    h.t.settle(1);
    h.t.frame();
    h.snap("desktop-3pane-split-fixed");

    // The transcript chip stays in the center pane; the active question in
    // this narrow split gets a separate window-bounded answer card.
    const q_label = h.t.findText("Question") orelse return error.MissingQuestionChip;
    const layout_s = h.a.tabs.layout() orelse return error.MissingSplitLayout;
    try testing.expectEqual(@as(usize, 3), layout_s.panes.items.len);
    const pane_each = h.a.view.chrome.chat_width / 3;
    const center_right = sidebar.widthOf(&h.a) + h.a.view.chrome.leading + pane_each * 2;
    try testing.expect(q_label.x + q_label.w < center_right);
    try testing.expect(@import("view_question.zig").expanded(&h.t.ctx, &h.a));
    try testing.expect(h.t.hasText("Cancel question"));
    var question_text_found = false;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.startsWith(u8, tx.str, "This worktree is now")) {
            question_text_found = true;
            try testing.expect(node.rect.x >= 0 and node.rect.x + node.rect.w <= h.t.ctx.size.w + 1);
        },
        else => {},
    };
    try testing.expect(question_text_found);
}

test "session footer renders account usage ring alongside context ring, opens account switcher popover, and optimistically switches accounts" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"c-usage","deviceId":"synthetic-device","title":"Account usage footer session","spaceId":"synthetic-project","archived":false,"config":{"harness":"claude-code","model":"anthropic/claude-opus-5.5"}}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);

    h.a.openChatInTab("c-usage");
    const doc = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"u1","role":"user","status":"complete","parts":[{"id":"p1","kind":"text","text":"Check footer rings"}]}],
        \\ "contextUsage":{"tokens":46000,"window":200000}}
    , .{});
    defer doc.deinit();
    try h.a.transcript.apply(doc.value);
    h.t.settle(1);

    // Without usageWindows, only #context-usage renders.
    try testing.expect(h.t.hasText("23%"));
    try testing.expect(h.a.view.account_usage.anchor == null);

    const accts = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"accounts":[
        \\  {"id":"acct-primary","harness":"claude-code","email":"alex@example.com","planLabel":"Max 20x","active":true,"switchable":true,
        \\   "usageWindows":[{"label":"5h","usedFraction":0.38,"resetsAt":"2026-11-15T14:00:00Z"},{"label":"7d","usedFraction":0.21,"resetsAt":"2026-11-20T00:00:00Z"}]},
        \\  {"id":"acct-backup","harness":"claude-code","email":"studio@example.com","planLabel":"Pro","active":false,"switchable":true,
        \\   "usageWindows":[{"label":"5h","usedFraction":0.86,"resetsAt":"2026-11-15T16:00:00Z"}]}
        \\]}
    , .{});
    defer accts.deinit();
    @import("view_settings_accounts.zig").setSnapshot(&h.a, accts.value);
    h.t.settle(1);
    h.t.frame();

    // Both rings sit side by side (#account-usage to the left of #context-usage) with zero idle wake timer.
    try testing.expect(h.t.hasText("38%"));
    try testing.expect(h.t.hasText("23%"));
    try testing.expect(h.a.tick(h.t.ctx.time) == null);
    h.t.ctx.input.window_active = false;
    h.t.frame();
    try testing.expect(h.t.ctx.frame_in == null);
    h.t.ctx.input.window_active = true;
    h.t.frame();
    const acct_anchor = h.a.view.account_usage.anchor orelse return error.NoAccountUsageAnchor;
    const ctx_anchor = h.a.view.context.anchor orelse return error.NoContextUsageAnchor;
    try testing.expect(acct_anchor.x + acct_anchor.w <= ctx_anchor.x + 0.01);

    // Provide a mock scene reply for ActivateAgentAccount before clicking.
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"ActivateAgentAccount":{"ok":true}}
    , .{});
    h.a.engine.state = .connected;

    // Click #account-usage -> opens #account-usage-menu upward above the footer ring.
    h.t.click(acct_anchor.x + acct_anchor.w / 2, acct_anchor.y + acct_anchor.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.account_usage.open);
    for ([_][]const u8{ "Claude Code accounts", "alex@example.com", "Max 20x", "In use", "5h", "7d", "studio@example.com", "Pro", "86%" }) |needle| {
        try testing.expect(h.t.hasText(needle));
    }
    const card = h.a.view.account_usage.card orelse return error.NoAccountUsageCard;
    try testing.expect(card.y + card.h <= acct_anchor.y + 0.01);

    // Clicking the inactive switchable account optimistically switches and sends ActivateAgentAccount.
    try h.t.clickText("studio@example.com");
    h.t.settle(1);
    try testing.expect(h.t.hasText("86%"));
    var sent_activate = false;
    for (h.a.engine.sent.items) |frame| {
        if (std.mem.indexOf(u8, frame, "ActivateAgentAccount") != null and std.mem.indexOf(u8, frame, "acct-backup") != null) {
            sent_activate = true;
            break;
        }
    }
    try testing.expect(sent_activate);

    // Pressing Escape dismisses the popover cleanly.
    _ = h.t.shortcut(.{ .key = ui.Shortcut.escape });
    h.t.settle(1);
    try testing.expect(!h.a.view.account_usage.open);

    // Clicking #context-usage pins the context card immediately without waiting for hover delay.
    h.t.click(ctx_anchor.x + ctx_anchor.w / 2, ctx_anchor.y + ctx_anchor.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.context.open);
    try testing.expect(h.a.view.context.pinned);
    try testing.expect(h.t.hasText("Context"));
}

test "zen topbar right-aligns a lone chat caption while two tabs and settings stay flush with the right rounded-12 card" {
    const rendering = @import("view_tab_strip.zig").rendering;
    const Find = struct {
        fn rightCard(ctx: *ui.Context, side_w: f32) ?ui.Rect {
            for (ctx.nodes.items) |n| {
                if (n.style.radius == 12 and @abs(n.rect.y - 42) < 0.5 and n.rect.x >= side_w and n.rect.w > 400 and n.rect.h > 400) {
                    return n.rect;
                }
            }
            return null;
        }
        /// The first title-bar pill in node order: the lone chat caption, or the strip's leftmost tab.
        fn firstPill(ctx: *ui.Context) ?ui.Rect {
            for (ctx.nodes.items) |n| {
                if (n.rect.y < 38 and @abs(n.rect.h - 28) < 0.5 and n.style.radius == 7 and n.style.control) {
                    return n.rect;
                }
            }
            return null;
        }
        /// Where #225 ends a lone windowed Zen caption: beside the device picker and the
        /// trailing controls (the anchor of `tests_ui_tab_strip.zig`'s single-chat test).
        fn captionEnd(a: *const App, ctx: *ui.Context) f32 {
            const utilities = @import("view_tab_strip.zig").rendering.utilityWidth(a);
            return ctx.size.w - @import("window_chrome.zig").trailing - utilities - 10 - @import("panel_chrome.zig").device_room - 12;
        }
    };

    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    // Two synthetic devices show the device picker the caption ends beside, and a
    // second conversation in the same project lets the strip hold two tabs later.
    const devices = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-device","name":"Synthetic studio"},{"id":"synthetic-remote","name":"Synthetic build box"}]
    , .{});
    defer devices.deinit();
    try h.a.devices.replace(devices.value);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic-chat","deviceId":"synthetic-device","title":"Synthetic navigation conversation","spaceId":"synthetic-project","archived":false},
        \\ {"id":"synthetic-second","deviceId":"synthetic-device","title":"Synthetic follow-up conversation","spaceId":"synthetic-project","archived":false}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.settings.applyUiMode(.zen);
    h.a.openChatInTab("synthetic-chat");
    h.t.settle(1);

    // Default sidebarWidth (224), one chat: the lone windowed caption ends beside the
    // device picker and trailing controls (#225) and still clears [⋯] and the traffic lights.
    try testing.expect(rendering.usesWindowedChatCaption(&h.a));
    {
        const pill = Find.firstPill(&h.t.ctx) orelse return error.MissingActivePill;
        const more = h.a.view.more_anchor orelse return error.MissingMoreAnchor;
        try testing.expectApproxEqAbs(Find.captionEnd(&h.a, &h.t.ctx), pill.x + pill.w, 1);
        try testing.expect(more.x + more.w + 12 <= pill.x);
        try testing.expect(pill.x >= @import("window_chrome.zig").leading);
    }

    // Wider sidebar (300), one chat: the right card follows (303) but the caption keeps its right-hand anchor.
    h.a.settings.setNumber("sidebarWidth", 300);
    h.t.settle(0.5);
    try testing.expect(rendering.usesWindowedChatCaption(&h.a));
    {
        const card = Find.rightCard(&h.t.ctx, h.a.view.sidebar_width) orelse return error.MissingRightCard;
        const pill = Find.firstPill(&h.t.ctx) orelse return error.MissingActivePill;
        const more = h.a.view.more_anchor orelse return error.MissingMoreAnchor;
        try testing.expectApproxEqAbs(@as(f32, 303), card.x, 0.5);
        try testing.expectApproxEqAbs(Find.captionEnd(&h.a, &h.t.ctx), pill.x + pill.w, 1);
        try testing.expect(more.x + more.w + 12 <= pill.x);
    }

    // Settings open: no lone caption; the pill is flush with the Zen Settings right rounded-12 card.
    try h.t.clickText("Sign in");
    h.t.settle(0.4);
    try testing.expect(h.a.view.settings_open);
    try testing.expect(!rendering.usesWindowedChatCaption(&h.a));
    {
        const card = Find.rightCard(&h.t.ctx, h.a.view.sidebar_width) orelse return error.MissingRightCard;
        const pill = Find.firstPill(&h.t.ctx) orelse return error.MissingActivePill;
        try testing.expectApproxEqAbs(@as(f32, 303), card.x, 0.5);
        try testing.expectApproxEqAbs(card.x, pill.x, 0.5);
    }

    // Back in chats with a second tab: no lone caption; the strip's first tab is flush with the right card (303).
    try h.t.clickText("Back to chats");
    h.t.settle(0.4);
    h.a.openChatInTab("synthetic-second");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 2), rendering.singleSpec(&h.a).n);
    try testing.expect(!rendering.usesWindowedChatCaption(&h.a));
    {
        const card = Find.rightCard(&h.t.ctx, h.a.view.sidebar_width) orelse return error.MissingRightCard;
        const pill = Find.firstPill(&h.t.ctx) orelse return error.MissingActivePill;
        try testing.expectApproxEqAbs(@as(f32, 303), card.x, 0.5);
        try testing.expectApproxEqAbs(card.x, pill.x, 0.5);
    }

    // Two tabs at the default sidebarWidth (224): the first tab follows the card back to 227 and clears [⋯].
    h.a.settings.setNumber("sidebarWidth", 224);
    h.t.settle(0.5);
    {
        const card = Find.rightCard(&h.t.ctx, h.a.view.sidebar_width) orelse return error.MissingRightCard;
        const pill = Find.firstPill(&h.t.ctx) orelse return error.MissingActivePill;
        const more = h.a.view.more_anchor orelse return error.MissingMoreAnchor;
        try testing.expectApproxEqAbs(@as(f32, 227), card.x, 0.5);
        try testing.expectApproxEqAbs(card.x, pill.x, 0.5);
        try testing.expect(more.x + more.w + 12 <= pill.x);
    }

    // Two tabs, sidebar collapsed: the strip starts after the traffic lights, toggle, history, and mode controls.
    _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    h.t.settle(0.5);
    try testing.expect(h.a.view.sidebar_width < 0.5);
    try testing.expect(!rendering.usesWindowedChatCaption(&h.a));
    {
        const pill = Find.firstPill(&h.t.ctx) orelse return error.MissingActivePill;
        const min_x = @import("window_chrome.zig").leading + 24 + 56 + 14;
        try testing.expect(pill.x >= min_x - 0.5);
    }
}
