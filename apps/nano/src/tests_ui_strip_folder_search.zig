//! Explicit folder changes after splitting, on made-up data.
const std = @import("std");
const ui = @import("nanoui").ui;
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const strip = @import("view_tab_strip.zig");

pub fn openFolderMenu(h: *Harness) !void {
    const pane = h.a.tabs.layout().?.focus;
    const name = strip.folder(&h.a, .{ .chat = pane }).?.name;
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, name) and node.rect.y < h.a.view.chrome.y and node.rect.x >= right_pane_x) {
            h.t.click(node.rect.x + node.rect.w / 2, node.rect.y + node.rect.h / 2);
            h.t.settle(1);
            return;
        },
        else => {},
    };
    return error.MissingFolderChip;
}

test "release folder menu: clicking the folder chip opens a focused searchable menu under its slot" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try openFolderMenu(&h);
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    try testing.expectEqual(@as(usize, 1), h.a.view.strip.target.chat);
    const anchor = h.a.view.strip.anchor orelse return error.MissingFolderAnchor;
    try testing.expect(anchor.y >= @import("panel_chrome.zig").header_height and anchor.y + anchor.h <= h.a.view.chrome.y);
    try testing.expect(h.t.hasText("Search folders…"));
    h.t.typeText("field notes");
    h.t.settle(1);
    try testing.expectEqualStrings("field notes", h.a.view.strip.query.text());
    try testing.expectEqual(@as(usize, 3), h.a.view.strip.rows);
    try testing.expectEqual(@as(usize, 0), h.a.view.strip.cursor);
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
}

test "release folder menu: text-field Enter confirms the filtered project and returns focus" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try openFolderMenu(&h);
    h.t.typeText("field notes");
    h.t.settle(1);
    h.t.key(.enter);
    h.t.settle(1);
    if (std.c.getenv("NANO_FOLDER_ENTER_SNAPSHOT")) |path| try h.t.screenshot(std.mem.span(path));
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    try testing.expectEqualStrings("", h.a.composer.text());
}

test "release folder menu: text-field Enter activates the current row and both actions in either menu" {
    for ([_]bool{ false, true }) |footer| {
        for (0..3) |index| {
            var h: Harness = undefined;
            try h.init(true);
            defer h.deinit();
            h.a.newTab();
            strip.open(&h.a, .folder, .{ .chat = 0 }, .{ .x = 350, .y = if (footer) 700 else 5, .w = 100, .h = 32 });
            h.a.view.strip.footer_folder = footer;
            h.t.settle(2);
            for (0..index) |_| h.press(.{ .key = ui.Shortcut.down });
            h.t.key(.enter);
            h.t.settle(1);
            try testing.expect(h.a.view.strip.menu == null);
            if (index == 0) {
                try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
                try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
            } else if (index == (if (footer) @as(usize, 2) else 1)) {
                try testing.expect(h.a.new_no_project);
                try testing.expect(h.a.newChatSpace() == null);
                try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
            } else {
                try testing.expect(!h.a.view.open_chooser.open);
                try testing.expect(h.a.view.project_setup.open);
            }
        }
    }
}

test "release folder menu: Escape accepts the inherited folder and returns typing to the composer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try openFolderMenu(&h);
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    h.press(.{ .key = ui.Shortcut.escape });
    h.t.typeText("A synthetic new-panel prompt");
    h.t.settle(1);
    try testing.expectEqualStrings("A synthetic new-panel prompt", h.a.composer.text());
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqual(@as(usize, 2), strip.chatCount(&h.a));
}

test "release folder menu: one Cmd W closes the panel Cmd D made even while search has focus" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try openFolderMenu(&h);
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    h.press(.{ .key = 'w', .cmd = true });
    try testing.expectEqual(@as(usize, 1), strip.chatCount(&h.a));
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expect(h.a.view.strip.pending_folder == null);
}

test "release folder menu: pane navigation dismisses search and preserves each composer's typing" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.composer.set("Original draft");
    h.t.settle(1);
    h.press(.{ .key = 'd', .cmd = true });
    try openFolderMenu(&h);
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    h.t.typeText("field");
    h.press(.{ .key = '[', .cmd = true });
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.t.typeText("!");
    try testing.expectEqualStrings("Original draft!", h.a.composer.text());
    h.press(.{ .key = ']', .cmd = true });
    h.t.typeText("Right draft");
    try testing.expectEqualStrings("Right draft", h.a.composer.text());
    try testing.expectEqualStrings("field", h.a.view.strip.query.text());
}

test "release folder menu: Cmd L accepts the inherited folder and focuses its composer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try openFolderMenu(&h);
    try testing.expect(h.a.view.strip.menu == .folder);
    const right_pane_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect((h.a.view.strip.anchor orelse return error.MissingFolderAnchor).x >= right_pane_x);
    const search_field = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    try testing.expect(search_field.x >= right_pane_x);
    h.press(.{ .key = 'l', .cmd = true });
    h.t.typeText("Type directly");
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqualStrings("Type directly", h.a.composer.text());
}

test "release folder menu: no matches retains both actions and never selects projectless accidentally" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try openFolderMenu(&h);
    h.t.typeText("no such synthetic folder");
    h.t.settle(1);
    try testing.expect(h.t.hasText("No folders match"));
    try testing.expect(h.t.hasText("Don't work in a project"));
    try testing.expect(h.t.hasText("New project…"));
    try testing.expectEqual(@as(usize, 2), h.a.view.strip.rows);
    try testing.expectEqual(@as(usize, 1), h.a.view.strip.cursor);
    try testing.expect(!h.a.new_no_project);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
}

test "release folder menu: no folders means a split goes straight to typing" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[]", .{});
    defer parsed.deinit();
    try h.a.spaces.replace(parsed.value);
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expect(h.a.view.strip.pending_folder == null);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
}

test "release footer project menu: shared search is280px above its trigger with New project first" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.a.view.space_anchor = .{ .x = 350, .y = 740, .w = 100, .h = 20 };
    h.a.view.space_menu = true;
    h.t.settle(2);
    try testing.expect(!h.a.view.space_menu);
    try testing.expect(h.a.view.strip.footer_folder);
    try testing.expect(h.t.hasText("Search projects…"));
    const create = h.t.findText("New project…") orelse return error.MissingCreate;
    const none = h.t.findText("Don't work in a project") orelse return error.MissingProjectless;
    try testing.expect(create.y < none.y and none.y + none.h < 740);
    var wide_card = false;
    for (h.t.ctx.nodes.items) |node| {
        if (node.rect.w == 280 and node.style.radius == 12 and node.rect.y + node.rect.h <= 740) wide_card = true;
    }
    try testing.expect(wide_card);
    // Other-device project headers remain visible in the sidebar; only
    // the open project menu must exclude those destinations.
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, "remote-project")) {
            try testing.expect(node.rect.x < h.a.view.sidebar_width);
        },
        else => {},
    };
    h.t.typeText("no matching project");
    h.t.settle(1);
    try testing.expect(h.t.hasText("No projects match."));
    try testing.expectEqual(@as(usize, 0), h.a.view.strip.cursor);
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    try testing.expect(!h.a.new_no_project);
}

test "release folder menu: only seven folders scroll while search and actions stay visible" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var rows: std.json.Array = .init(alloc);
    for (0..20) |ix| {
        const text = try std.fmt.allocPrint(alloc,
            \\{{"id":"p{d}","deviceId":"local","path":"/synthetic/folder-{d}"}}
        , .{ ix, ix });
        try rows.append(try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}));
    }
    try h.a.spaces.replace(.{ .array = rows });
    h.press(.{ .key = 'd', .cmd = true });
    try openFolderMenu(&h);
    const list = h.t.ctx.rects.get(h.a.view.strip.search_scroll) orelse return error.MissingFolderScroller;
    try testing.expectApproxEqAbs(@as(f32, 224), list.h, 0.1);
    const actions = h.t.findText("Don't work in a project") orelse return error.MissingPersistentAction;
    try testing.expect(actions.y >= list.y + list.h);
    h.t.typeText("folder-17");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.view.strip.rows);
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expectEqualStrings("p17", h.a.newChatSpace().?.id);
}

test "multi-pane project picker anchors to active tab rather than another pane footer" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    // Create 3 panes side by side: pane 0 (left), pane 1 (middle), pane 2 (right draft).
    h.a.splitPane(.horizontal);
    h.a.splitPane(.horizontal);
    h.t.settle(2);
    // Focus pane 2 (rightmost draft) so its footer sets space_anchor in the lower-right.
    strip.focus(&h.a, .{ .chat = 2 });
    h.t.settle(2);
    const right_footer = h.a.view.space_anchor orelse return error.MissingRightFooter;
    const mid_x = h.a.view.chrome.x + h.a.view.chrome.chat_width * 0.5;
    try testing.expect(right_footer.x >= mid_x);

    // Focus pane 0 (leftmost tab, existing chat) and invoke project picker via keyboard.
    strip.focus(&h.a, .{ .chat = 0 });
    h.t.settle(2);
    // Stale footer anchor from pane 2 must not survive switching to pane 0.
    try testing.expect(h.a.view.space_anchor == null);
    strip.toggleProjectPicker(&h.a);
    h.t.settle(2);
    try testing.expect(h.a.view.strip.menu == .folder);
    try testing.expect(!h.a.view.strip.footer_folder);
    const left_anchor = h.a.view.strip.anchor orelse return error.MissingLeftAnchor;
    try testing.expect(left_anchor.x < mid_x);
    try testing.expect(left_anchor.y < 60);
    const left_search = h.t.findText("Search folders…") orelse return error.MissingLeftSearch;
    try testing.expect(left_search.x < mid_x);
    try testing.expect(left_search.y < 120);
    h.press(.{ .key = ui.Shortcut.escape });

    // Even when pane 0 is a draft (which also has a footer chip), keyboard project picker
    // in a multi-pane layout anchors to pane 0's active tab strip control, not lower-right.
    h.a.select(null, null);
    h.t.settle(2);
    strip.toggleProjectPicker(&h.a);
    h.t.settle(2);
    try testing.expect(h.a.view.strip.menu == .folder);
    try testing.expect(!h.a.view.strip.footer_folder);
    const draft_left_search = h.t.findText("Search folders…") orelse return error.MissingDraftLeftSearch;
    try testing.expect(draft_left_search.x < mid_x);
    try testing.expect(draft_left_search.y < 120);
    h.press(.{ .key = ui.Shortcut.escape });

    // Switching to pane 2 (rightmost) anchors the keyboard picker near the right tab.
    strip.focus(&h.a, .{ .chat = 2 });
    h.t.settle(2);
    strip.toggleProjectPicker(&h.a);
    h.t.settle(2);
    const right_search = h.t.findText("Search folders…") orelse return error.MissingRightSearch;
    try testing.expect(right_search.x >= mid_x);
    try testing.expect(right_search.y < 120);
}

test "project picker opens a different project in a new workspace without replacing the split session" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.applyUiMode(.developer);
    const projects = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[ {"id":"local-project","deviceId":"local","path":"/synthetic/fieldnotes"},
        \\  {"id":"other-project","deviceId":"local","path":"/synthetic/workshop"},
        \\  {"id":"remote-project","deviceId":"remote","path":"/synthetic/remote-project"} ]
    , .{});
    defer projects.deinit();
    try h.a.spaces.replace(projects.value);
    h.a.splitOpening(.horizontal, "b");
    strip.focus(&h.a, .{ .chat = 0 });
    h.a.composer.set("Keep the Alpha reply draft");
    h.t.settle(2);
    const source = h.a.tabs.active;
    const count = h.a.tabs.items.items.len;

    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expect(h.a.view.strip.menu == .folder);
    h.t.typeText("fieldnotes");
    h.t.settle(1);
    h.t.key(.enter);
    h.t.settle(2);
    try testing.expectEqual(count, h.a.tabs.items.items.len);
    try testing.expectEqualStrings("a", h.a.selected.?);

    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expect(h.a.view.strip.menu == .folder);
    h.t.typeText("workshop");
    h.t.settle(1);
    h.t.key(.enter);
    h.t.settle(2);
    if (std.c.getenv("NANO_PROJECT_SWITCH_SNAPSHOT")) |path| try h.t.screenshot(std.mem.span(path));

    try testing.expectEqual(count + 1, h.a.tabs.items.items.len);
    try testing.expectEqual(source + 1, h.a.tabs.active);
    try testing.expect(h.a.tabs.layout() == null and h.a.selected == null);
    try testing.expectEqualStrings("other-project", h.a.newChatSpace().?.id);
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.a.showTab(source);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqualStrings("Keep the Alpha reply draft", h.a.composer.text());
    try testing.expectEqualStrings("local-project", h.a.findChat("a").?.space_id.?);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expectEqualStrings("b", h.a.tabs.layout().?.panes.items[1].?);
}

test "project picker #42: dismisses on outside clicks including top strip, micro-drag, and right-click, and toggles with Cmd+Shift+P" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    // Existing chat: Cmd+Shift+P opens the top-anchored project picker (`footer_folder == false`).
    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expectEqual(strip.Menu.folder, h.a.view.strip.menu.?);
    try testing.expect(!h.a.view.strip.footer_folder);

    // Clicking inside the search field and typing keeps the picker open.
    const search_rect = h.t.findText("Search folders…") orelse return error.MissingFolderSearch;
    h.t.click(search_rect.x + 12, search_rect.y + search_rect.h / 2);
    h.t.settle(1);
    try testing.expectEqual(strip.Menu.folder, h.a.view.strip.menu.?);
    h.t.typeText("field");
    h.t.settle(1);
    try testing.expectEqualStrings("field", h.a.view.strip.query.text());
    try testing.expectEqual(strip.Menu.folder, h.a.view.strip.menu.?);

    // Pressing Cmd+Shift+P again while search has focus dismisses the picker and returns focus.
    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);

    // Clicking outside in the top header strip (y < 42) must dismiss the picker.
    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expectEqual(strip.Menu.folder, h.a.view.strip.menu.?);
    h.t.click(760, 20);
    h.t.settle(1);
    if (std.c.getenv("NANO_PICKER_DISMISS_SNAPSHOT")) |path| try h.t.screenshot(std.mem.span(path));
    try testing.expect(h.a.view.strip.menu == null);

    // Clicking outside with slight pointer drift (trackpad micro-drag) must dismiss the picker.
    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expectEqual(strip.Menu.folder, h.a.view.strip.menu.?);
    h.t.drag(820, 420, 832, 425);
    h.t.settle(1);
    try testing.expect(h.a.view.strip.menu == null);

    // Right-clicking outside the picker must also dismiss it.
    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expectEqual(strip.Menu.folder, h.a.view.strip.menu.?);
    h.t.secondaryClick(820, 420);
    h.t.settle(1);
    try testing.expect(h.a.view.strip.menu == null);

    // Sidebar project picker (`filter_menu`) dismisses on Cmd+Shift+P instead of stacking two pickers.
    @import("view_sidebar_menus.zig").openProjects(&h.a);
    h.t.settle(1);
    try testing.expect(h.a.view.filter_menu);
    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expect(!h.a.view.filter_menu);
    try testing.expect(h.a.view.strip.menu == null);

    // Draft footer-anchored project picker (`footer_folder == true`) also toggles with Cmd+Shift+P,
    // dismisses on outside click, and still lets project rows be selected normally.
    h.a.newTab();
    h.t.settle(2);
    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expectEqual(strip.Menu.folder, h.a.view.strip.menu.?);
    try testing.expect(h.a.view.strip.footer_folder);
    h.t.drag(820, 300, 830, 304);
    h.t.settle(1);
    try testing.expect(h.a.view.strip.menu == null);

    h.press(.{ .key = 'p', .cmd = true, .shift = true });
    try testing.expectEqual(strip.Menu.folder, h.a.view.strip.menu.?);
    try h.t.clickText("fieldnotes");
    h.t.settle(1);
    try testing.expect(h.a.view.strip.menu == null);
    try testing.expectEqualStrings("local-project", h.a.newChatSpace().?.id);
}

// ----- #15: the picker opens beside the project control it changes -----

const tabs = @import("tabs.zig");
const chrome = @import("panel_chrome.zig");
const folder_search = @import("strip_folder_search.zig");

/// A pane's slot in the lane above the panes, left to right in pane order.
fn slotRect(h: *Harness, pane: usize) !ui.Rect {
    var rects: [tabs.max_panes + 2]ui.Rect = undefined;
    var n: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        if (@abs(node.rect.h - chrome.tab_height) > 0.1 or node.style.radius != 6) continue;
        if (node.rect.y >= chrome.header_height + chrome.tab_height or node.rect.w < 20) continue;
        if (n == rects.len) return error.TooManySlots;
        rects[n] = node.rect;
        n += 1;
    }
    std.mem.sort(ui.Rect, rects[0..n], {}, struct {
        fn before(_: void, a: ui.Rect, b: ui.Rect) bool {
            return a.x < b.x;
        }
    }.before);
    if (pane >= n) return error.MissingSlot;
    return rects[pane];
}

/// The folder chip inside a slot: the last of its 14pt chips.
fn slotFolderChip(h: *Harness, pane: usize) !ui.Rect {
    const slot = try slotRect(h, pane);
    var found: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |node| {
        const r = node.rect;
        if (@abs(r.h - 14) > 0.1 or node.style.radius != 3 or r.w < 8) continue;
        if (r.x < slot.x or r.x + r.w > slot.x + slot.w + 0.5 or r.y < slot.y or r.y + r.h > slot.y + slot.h + 0.5) continue;
        if (found == null or r.x > found.?.x) found = r;
    }
    return found orelse error.MissingSlotFolder;
}

/// A pane's 28pt header in full screen, in pane order.
fn fsHeader(h: *Harness, pane: usize) !ui.Rect {
    var ix: usize = 0;
    for (h.t.ctx.nodes.items) |node| {
        if (@abs(node.rect.h - chrome.fs_pane_header_h) > 0.1 or node.rect.w < 100 or !node.style.clip) continue;
        if (ix == pane) return node.rect;
        ix += 1;
    }
    return error.MissingFullScreenHeader;
}

/// The project's name in a full-screen pane header.
fn headerProject(h: *Harness, header: ui.Rect, name: []const u8) !ui.Rect {
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (std.mem.eql(u8, text.str, name) and node.rect.y >= header.y and node.rect.y + node.rect.h <= header.y + header.h and node.rect.x >= header.x and node.rect.x < header.x + header.w) return node.rect,
        else => {},
    };
    return error.MissingHeaderProject;
}

/// The open picker's card, from what was drawn rather than from its anchor.
fn pickerCard(h: *Harness) !ui.Rect {
    try testing.expectEqual(strip.Menu.folder, h.a.view.strip.menu orelse return error.PickerClosed);
    const want: f32 = if (h.a.view.strip.footer_folder) 280 else folder_search.menu_width;
    for (h.t.ctx.nodes.items) |node| if (node.style.radius == 12 and @abs(node.rect.w - want) < 0.1 and node.rect.h > 60) return node.rect;
    return error.MissingPickerCard;
}

fn apart(a0: f32, a1: f32, b0: f32, b1: f32) f32 {
    return @max(0, @max(b0 - a1, a0 - b1));
}

fn expectBeside(h: *Harness, control: ui.Rect) !void {
    const card = try pickerCard(h);
    const dx = apart(card.x, card.x + card.w, control.x, control.x + control.w);
    const dy = apart(card.y, card.y + card.h, control.y, control.y + control.h);
    if (dx > 12 or dy > 12) {
        std.debug.print("picker card x={d:.0} y={d:.0} w={d:.0} h={d:.0}; project control x={d:.0} y={d:.0} w={d:.0} h={d:.0}; apart {d:.0} across, {d:.0} down\n", .{ card.x, card.y, card.w, card.h, control.x, control.y, control.w, control.h, dx, dy });
        return error.PickerFarFromItsControl;
    }
}

fn snap(h: *Harness, name: []const u8) void {
    const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
    h.t.screenshot(path) catch {};
}

fn center(r: ui.Rect) struct { f32, f32 } {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

fn clickRect(h: *Harness, r: ui.Rect) void {
    const x, const y = center(r);
    h.t.click(x, y);
    h.t.settle(1);
}

/// Hovering a narrow slot shows its buttons and moves its chips over, so the
/// chip is found again under the pointer before the press.
fn clickFolderChip(h: *Harness, pane: usize) !void {
    const x, const y = center(try slotRect(h, pane));
    h.t.moveTo(x, y);
    h.t.settle(1);
    clickRect(h, try slotFolderChip(h, pane));
}

/// `n` panes; pane 0 the existing chat, the rest drafts.
fn splitInto(h: *Harness, axis: tabs.Axis, n: usize) void {
    for (1..n) |_| h.a.splitPane(axis);
    h.t.settle(2);
}

const picker_chord: ui.Shortcut = .{ .key = 'p', .cmd = true, .shift = true };

test "project picker #15: folder chip click opens beside that pane's chip in both axes up to eight panes" {
    for ([_]tabs.Axis{ .horizontal, .vertical }) |axis| for ([_]usize{ 2, 3, 4, 5, 8 }) |n| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        splitInto(&h, axis, n);
        for (0..n) |pane| {
            // From the far end, so a stale anchor would be the other pane's.
            strip.focus(&h.a, .{ .chat = if (pane == 0) n - 1 else 0 });
            h.t.settle(2);
            try clickFolderChip(&h, pane);
            try testing.expectEqual(pane, h.a.view.strip.target.chat);
            try expectBeside(&h, try slotFolderChip(&h, pane));
            h.press(.{ .key = ui.Shortcut.escape });
            // Already focused.
            try clickFolderChip(&h, pane);
            try expectBeside(&h, try slotFolderChip(&h, pane));
            h.press(.{ .key = ui.Shortcut.escape });
        }
    };
}

test "project picker #15: keyboard opens beside the active pane's own chip in both axes up to eight panes" {
    for ([_]tabs.Axis{ .horizontal, .vertical }) |axis| for ([_]usize{ 2, 3, 4, 5, 8 }) |n| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        splitInto(&h, axis, n);
        for (0..n) |step| {
            const pane = if (step % 2 == 0) step / 2 else n - 1 - step / 2;
            strip.focus(&h.a, .{ .chat = pane });
            h.t.settle(2);
            h.press(picker_chord);
            try testing.expectEqual(pane, h.a.view.strip.target.chat);
            try expectBeside(&h, try slotFolderChip(&h, pane));
            h.press(.{ .key = ui.Shortcut.escape });
        }
    };
}

test "project picker #15: draft beside a draft, its footer chip opens in its own pane" {
    for ([_]tabs.Axis{ .horizontal, .vertical }) |axis| for ([_]usize{ 2, 3, 4 }) |n| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.newTab();
        splitInto(&h, axis, n);
        for (0..n) |step| {
            const pane = if (step % 2 == 0) step / 2 else n - 1 - step / 2;
            strip.focus(&h.a, .{ .chat = pane });
            h.t.settle(2);
            const chrome_rect = h.a.view.chrome;
            const s = h.a.tabs.layout().?;
            try testing.expectEqual(pane, s.focus);
            // Only the focused pane draws a footer, so only it writes the anchor.
            const control = h.a.view.space_anchor orelse return error.MissingFooterChip;
            const total: f32 = if (axis == .horizontal) chrome_rect.chat_width else chrome_rect.height;
            const at = if (axis == .horizontal) control.x - chrome_rect.x else control.y - chrome_rect.y;
            const slice = total / @as(f32, @floatFromInt(n));
            try testing.expect(at >= slice * @as(f32, @floatFromInt(pane)) - 8 and at <= slice * @as(f32, @floatFromInt(pane + 1)) + 8);
            clickRect(&h, control);
            try testing.expect(h.a.view.strip.footer_folder);
            try testing.expectEqual(pane, h.a.view.strip.target.chat);
            try expectBeside(&h, control);
            h.press(.{ .key = ui.Shortcut.escape });
        }
    };
}

test "project picker #15: a pane whose tab has no folder chip opens beside its own tab" {
    // A chat that has not synced has no project yet, so no chip to change.
    for ([_]tabs.Axis{ .horizontal, .vertical }) |axis| for ([_]usize{ 2, 3, 4 }) |n| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        splitInto(&h, axis, n);
        strip.focus(&h.a, .{ .chat = n - 1 });
        h.t.settle(2);
        h.a.openChat("not-synced", null);
        h.t.settle(2);
        for ([_]usize{ 0, n - 1 }) |pane| {
            strip.focus(&h.a, .{ .chat = pane });
            h.t.settle(2);
            h.press(picker_chord);
            try expectBeside(&h, try slotRect(&h, pane));
            h.press(.{ .key = ui.Shortcut.escape });
        }
        // An open picker follows its tab, and a full-screen header.
        strip.focus(&h.a, .{ .chat = n - 1 });
        h.t.settle(2);
        h.press(picker_chord);
        errdefer std.debug.print("axis={t} n={d}\n", .{ axis, n });
        for ([_]f32{ 1800, 1000 }) |w| {
            h.t.resize(w, 720);
            h.t.settle(2);
            try expectBeside(&h, try slotRect(&h, n - 1));
        }
        h.press(.{ .key = ui.Shortcut.escape });
        h.a.setFullScreen(true);
        h.t.settle(2);
        h.press(picker_chord);
        try expectBeside(&h, try fsHeader(&h, n - 1));
    };
}

test "project picker #15: beside the pane it changes while a Files or host tab is active" {
    const Beside = enum { files, host };
    for (std.enums.values(Beside)) |panel| for ([_]usize{ 2, 1, 3 }) |n| for ([_]bool{ false, true }) |draft| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.t.resize(1700, 780);
        if (draft) h.a.newTab();
        splitInto(&h, .horizontal, n);
        switch (panel) {
            .files => h.a.panels.files_open = true,
            .host => h.a.panels.host_open = true,
        }
        strip.focus(&h.a, .{ .chat = 0 });
        strip.focus(&h.a, if (panel == .files) .files else .host);
        // A slot first drawn in one frame is measured for the next.
        h.t.frame();
        h.t.settle(2);
        try testing.expect(strip.active(&h.a) != .chat);
        h.press(picker_chord);
        errdefer std.debug.print("panel={t} n={d} draft={}\n", .{ panel, n, draft });
        if (panel == .files and n == 2 and !draft) snap(&h, "picker-files-tab-active");
        try expectBeside(&h, try slotFolderChip(&h, 0));
        // It changes pane 0's project, so that is the folder it checks.
        try testing.expect(strip.same(h.a.view.strip.target, .{ .chat = 0 }));
        h.press(.{ .key = ui.Shortcut.escape });
    };
}

test "project picker #15: resizing the window keeps an open picker beside its control" {
    for ([_]tabs.Axis{ .horizontal, .vertical }) |axis| for ([_]usize{ 1, 2 }) |pane| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        splitInto(&h, axis, 3);
        strip.focus(&h.a, .{ .chat = pane });
        h.t.settle(2);
        h.press(picker_chord);
        try expectBeside(&h, try slotFolderChip(&h, pane));
        for ([_]f32{ 1600, 1000 }) |w| {
            h.t.resize(w, 720);
            h.t.settle(2);
            try expectBeside(&h, try slotFolderChip(&h, pane));
        }
    };
}

test "project picker #15: resizing the window keeps a footer picker above its chip" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.newTab();
    h.t.settle(2);
    h.press(picker_chord);
    try testing.expect(h.a.view.strip.footer_folder);
    for ([_][2]f32{ .{ 1200, 780 }, .{ 1500, 600 }, .{ 2200, 900 }, .{ 1000, 700 } }) |size| {
        h.t.resize(size[0], size[1]);
        h.t.settle(2);
        if (size[0] == 1500) snap(&h, "picker-footer-resized");
        const chip = h.a.view.space_anchor orelse return error.MissingFooterChip;
        const card = try pickerCard(&h);
        errdefer std.debug.print("window {d:.0}x{d:.0}: picker card x={d:.0} y={d:.0} w={d:.0} h={d:.0}; chip x={d:.0} y={d:.0}\n", .{ size[0], size[1], card.x, card.y, card.w, card.h, chip.x, chip.y });
        try expectBeside(&h, chip);
        try testing.expect(card.y + card.h <= chip.y);
    }
}

test "project picker #15: zoomed pane, the keyboard picker opens beside that pane's chip" {
    for ([_]usize{ 2, 3 }) |n| for (0..n) |pane| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        splitInto(&h, .horizontal, n);
        strip.focus(&h.a, .{ .chat = pane });
        strip.queue(&h.a, .{ .zoom = .{ .chat = pane } });
        h.t.settle(2);
        try testing.expect(h.a.tabs.layout().?.zoomed);
        h.press(picker_chord);
        try expectBeside(&h, try slotFolderChip(&h, pane));
    };
}

test "project picker #15: full screen draft pill, click and keyboard, opens beside its own pane's pill" {
    for ([_]tabs.Axis{ .horizontal, .vertical }) |axis| for ([_]usize{ 2, 3 }) |n| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.newTab();
        splitInto(&h, axis, n);
        h.a.setFullScreen(true);
        h.t.settle(2);
        for (0..n) |pane| for ([_]bool{ true, false }) |click| {
            strip.focus(&h.a, .{ .chat = if (click and pane == 0) n - 1 else if (click) 0 else pane });
            h.t.settle(2);
            const header = try fsHeader(&h, pane);
            if (click) {
                clickRect(&h, .{ .x = header.x + 20, .y = header.y + 4, .w = 20, .h = 20 });
            } else h.press(picker_chord);
            try testing.expectEqual(pane, h.a.view.strip.target.chat);
            try expectBeside(&h, .{ .x = header.x, .y = header.y, .w = 90, .h = header.h });
            h.press(.{ .key = ui.Shortcut.escape });
        };
    };
}

test "project picker #15: full screen existing chat, the keyboard picker opens beside its own project" {
    for ([_]bool{ false, true }) |zoomed| for ([_]tabs.Axis{ .horizontal, .vertical }) |axis| for ([_]usize{ 2, 3 }) |n| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        splitInto(&h, axis, n);
        // The existing chat in the last pane, drafts in the others.
        strip.focus(&h.a, .{ .chat = 0 });
        h.a.select(null, null);
        strip.focus(&h.a, .{ .chat = n - 1 });
        h.a.openChat("b", null);
        if (zoomed) strip.queue(&h.a, .{ .zoom = .{ .chat = n - 1 } });
        h.a.setFullScreen(true);
        h.t.settle(2);
        try testing.expectEqualStrings("b", h.a.selected.?);
        try testing.expectEqual(n - 1, h.a.tabs.layout().?.focus);
        h.press(picker_chord);
        errdefer std.debug.print("zoomed={} axis={t} n={d}\n", .{ zoomed, axis, n });
        if (!zoomed and axis == .horizontal and n == 2) snap(&h, "picker-full-screen-chat");
        const header = try fsHeader(&h, if (zoomed) 0 else n - 1);
        try testing.expect(strip.same(h.a.view.strip.target, .{ .chat = n - 1 }));
        try expectBeside(&h, try headerProject(&h, header, "remote-project"));
        // An open picker follows its chip.
        h.t.resize(1500, 700);
        h.t.settle(2);
        try expectBeside(&h, try headerProject(&h, try fsHeader(&h, if (zoomed) 0 else n - 1), "remote-project"));
        // The header is not a toggle: pressing it closes the picker.
        const resized = try fsHeader(&h, if (zoomed) 0 else n - 1);
        h.t.click(resized.x + 40, resized.y + resized.h / 2);
        h.t.settle(1);
        try testing.expect(h.a.view.strip.menu == null);
        // Nothing stale is left for a windowed draft in the same pane.
        h.a.select(null, null);
        h.a.setFullScreen(false);
        h.t.settle(2);
        h.press(picker_chord);
        try expectBeside(&h, try slotFolderChip(&h, n - 1));
    };
}

test "project picker #15: full screen, beside the pane it changes while Files is active" {
    for ([_]bool{ false, true }) |draft| for ([_]usize{ 1, 2 }) |n| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.t.resize(1700, 780);
        if (draft) h.a.newTab();
        splitInto(&h, .horizontal, n);
        h.a.panels.files_open = true;
        h.a.setFullScreen(true);
        strip.focus(&h.a, .{ .chat = n - 1 });
        if (n == 2 and !draft) h.a.openChat("b", null);
        strip.focus(&h.a, .files);
        h.t.frame();
        h.t.settle(2);
        try testing.expect(strip.active(&h.a) == .files);
        h.press(picker_chord);
        errdefer std.debug.print("draft={} n={d}\n", .{ draft, n });
        const header = try fsHeader(&h, n - 1);
        try expectBeside(&h, if (draft) ui.Rect{ .x = header.x, .y = header.y, .w = 90, .h = header.h } else try headerProject(&h, header, if (n == 2) "remote-project" else "fieldnotes"));
        try testing.expect(strip.same(h.a.view.strip.target, .{ .chat = n - 1 }));
    };
}

test "project picker #15: zoomed Files tab, the keyboard picker opens beside the focused chat's chip" {
    for ([_]usize{ 1, 2, 3 }) |n| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        splitInto(&h, .horizontal, n);
        h.a.panels.files_open = true;
        strip.focus(&h.a, .{ .chat = n - 1 });
        strip.queue(&h.a, .{ .zoom = .files });
        h.t.frame();
        h.t.settle(2);
        try testing.expect(strip.same(h.a.view.strip.expanded.?, .files));
        h.press(picker_chord);
        errdefer std.debug.print("n={d}\n", .{n});
        try expectBeside(&h, try slotFolderChip(&h, n - 1));
        try testing.expect(strip.same(h.a.view.strip.target, .{ .chat = n - 1 }));
    }
}

test "project picker #15: after Cmd+W closes a Files tab it opens for the focused pane, not the first" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.t.resize(1700, 780);
    splitInto(&h, .horizontal, 3);
    h.a.panels.files_open = true;
    strip.focus(&h.a, .{ .chat = 2 });
    strip.focus(&h.a, .files);
    h.t.frame();
    h.t.settle(2);
    h.press(.{ .key = 'w', .cmd = true });
    try testing.expect(!h.a.panels.files_open);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.focus);
    h.press(picker_chord);
    try expectBeside(&h, try slotFolderChip(&h, 2));
    try testing.expect(strip.same(h.a.view.strip.target, .{ .chat = 2 }));
}

/// The project chips in a narrow draft's footer (one: a crushed chip moves
/// to the second row rather than being drawn twice).
fn footerProjects(h: *Harness, out: *[2]ui.Rect) []ui.Rect {
    var n: usize = 0;
    for (h.t.ctx.nodes.items) |node| switch (node.content) {
        .text => |text| if (n < 2 and std.mem.eql(u8, text.str, "fieldnotes") and node.rect.x >= h.a.view.sidebar_width and node.rect.y > h.t.ctx.size.h - 75) {
            out[n] = node.rect;
            n += 1;
        },
        else => {},
    };
    return out[0..n];
}

test "project picker #15: a narrow draft has the picker above the project chip that opened it, also after a resize" {
    const Via = enum { keyboard, chip };
    var seen: std.EnumArray(Via, usize) = .initFill(0);
    for ([_]@import("motion_rules.zig").UiMode{ .zen, .developer }) |mode| for ([_]usize{ 1, 2, 3 }) |n| for (std.enums.values(Via)) |via| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        h.a.settings.applyUiMode(mode);
        // The narrowest window there is.
        const width: f32 = if (n == 3) 1000 else 760;
        h.a.view.sidebar_open = n == 1;
        h.a.newTab();
        splitInto(&h, .horizontal, n);
        strip.focus(&h.a, .{ .chat = 0 });
        h.t.resize(width, 780);
        h.t.settle(2);
        errdefer std.debug.print("mode={t} n={d} via={t}\n", .{ mode, n, via });
        var buf: [2]ui.Rect = undefined;
        const before = footerProjects(&h, &buf);
        try testing.expect(before.len <= 1);
        // In a split, the keyboard's picker is the strip's.
        if (via == .keyboard and n > 1) continue;
        if (before.len < 1) continue;
        seen.getPtr(via).* += 1;
        switch (via) {
            .keyboard => h.press(picker_chord),
            .chip => clickRect(&h, before[0]),
        }
        try testing.expect(h.a.view.strip.footer_folder);
        for ([_]f32{ 780, 660, 900 }) |height| {
            h.t.resize(width, height);
            h.t.settle(2);
            if (mode == .zen and n == 2 and via == .chip and height == 660) snap(&h, "picker-narrow-draft");
            const now = footerProjects(&h, &buf);
            if (now.len != before.len) return error.FooterChanged;
            const chip = now[0];
            const card = try pickerCard(&h);
            errdefer std.debug.print("height={d}: card y={d:.0} h={d:.0}, chip y={d:.0}\n", .{ height, card.y, card.h, chip.y });
            try expectBeside(&h, chip);
            try testing.expect(card.y + card.h <= chip.y);
        }
    };
    for (seen.values) |cases| try testing.expect(cases > 0);
}
