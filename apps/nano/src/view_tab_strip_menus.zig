//! Panel menus live below their slot, including tabs hidden by a split.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const strip = @import("view_tab_strip.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const icons = @import("icons.zig");
const rules = @import("rules.zig");

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors) void {
    const menu = a.view.strip.menu orelse return;
    const anchor = (if (menu == .device) a.view.strip.device_anchor orelse a.view.strip.anchor else a.view.strip.anchor) orelse ui.Rect{ .x = a.view.sidebar_width + 16, .y = 5, .w = 100, .h = 32 };
    if (a.view.strip.focus_menu) {
        if (menu != .folder) c.focus = 0;
        a.view.strip.focus_menu = false;
    }
    a.view.strip.rows = 0;
    defer a.view.strip.activate = false;
    const target = a.view.strip.target;
    if (menu == .folder) return folderMenu(c, a, k, anchor);
    const width: f32 = @import("strip_folder_search.zig").menu_width;
    const x = rules.snapToWindow(anchor.x, width, c.size.w, 8);
    const est_h: f32 = if (menu == .device)
        @min(220, @as(f32, @floatFromInt(@max(1, 1 + a.devices.items.len))) * 34 + 12)
    else
        220;
    const y = if (c.size.h - (anchor.y + anchor.h) < est_h + 14 and anchor.y > est_h + 14)
        @max(8, anchor.y - est_h - 6)
    else
        @min(anchor.y + anchor.h + 4, @max(8, c.size.h - est_h));
    {
        const scrim_top = @import("motion_rules.zig").scrimTop(false, a.view.chrome.y);
        const scrim = ui.div(c).fixed().offset(0, scrim_top).size(c.size.w, @max(0, c.size.h - scrim_top)).layer(4);
        defer scrim.end();
        if (scrim.clicked()) {
            a.view.strip.menu = null;
            return;
        }
    }
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(width).maxH(@max(0, c.size.h - y - 8)).column().p(5).gap(2).bg(k.overlay.alpha(1)).border(k.border).borderW(1).rounded(12).layer(5).scrollY()));
    defer card.end();
    if (menu == .device) {
        const id = strip.device(a, target);
        const editable = target == .chat;
        if (!editable) {
            ui.text(c, strip.deviceLabel(a, id), .{ .size = 13, .color = k.text });
            ui.text(c, "A session's computer can't be changed.", .{ .size = 12, .color = k.muted, .wrap = true });
            return;
        }
        const local = a.device_id orelse "local";
        {
            const selected = if (id) |have| std.mem.eql(u8, have, local) else true;
            if (row(c, a, k, .monitor, @import("strip_device.zig").localLabel(), selected)) strip.queueDevice(a, target, local);
        }
        for (a.devices.items) |dev| {
            if (std.mem.eql(u8, local, dev.id)) continue;
            const selected = if (id) |have| std.mem.eql(u8, have, dev.id) else false;
            // This is a real execution target, even with no folders. Its ID
            // is parked with this draft and sent in CreateChat, never swapped
            // into the app's own machine identity or inferred from a folder.
            if (row(c, a, k, .monitor, strip.deviceLabel(a, dev.id), selected)) strip.queueDevice(a, target, dev.id);
        }
        return;
    }
    if (menu == .history) {
        const render = @import("view_tab_strip_render.zig");
        if (strip.count(a) <= 1) {
            const spec = render.singleSpec(a);
            for (0..spec.n) |ix| {
                const chat = render.singleItemChat(a, spec, ix);
                const title = if (chat) |id| (if (a.findChat(id)) |ch| @import("view_sidebar.zig").chatLabel(ch) else "Conversation") else "New tab";
                if (row(c, a, k, .@"chat-round-line", title, ix == spec.selected)) switch (spec.itemAt(ix)) {
                    .global => |ws| strip.queue(a, .{ .global_tab = ws }),
                    .panel => |pt| strip.queue(a, .{ .panel_tab = .{ .pane = pt.pane, .tab = pt.tab } }),
                };
            }
        } else {
            for (0..a.tabs.items.items.len) |ix| {
                const chat = render.workspaceChatId(a, ix);
                const title = if (chat) |id| (if (a.findChat(id)) |ch| @import("view_sidebar.zig").chatLabel(ch) else "Conversation") else "New tab";
                if (row(c, a, k, .@"chat-round-line", title, ix == a.tabs.active)) strip.queue(a, .{ .global_tab = ix });
            }
        }
        separator(c, k);
        if (row(c, a, k, .plus, "New tab", false)) strip.queue(a, .{ .new = strip.active(a) });
        return;
    }
    switch (target) {
        .chat => |pane| {
            if (a.settings.hierarchyProfile().shows_git_checkout_chrome) {
                const pane_chat_id = strip.chatId(a, pane);
                const pane_chat = if (pane_chat_id) |cid| a.findChat(cid) else null;
                const branch = if (pane_chat) |ch| ch.branch else null;
                const matches_diff = if (pane_chat_id) |cid|
                    (if (a.panels.chat) |pc| std.mem.eql(u8, pc, cid) else false)
                else
                    false;
                const diff_ptr = if (matches_diff) a.panels.diff else null;
                const diff_files: usize = if (diff_ptr) |d| d.files.len else 0;
                if (branch != null or diff_files > 0) {
                    const hdr = ui.div(c).row().wFull().px(8).py(5).gap(6).itemsCenter().clip();
                    if (branch) |br| {
                        icons.icon(c, .@"git-branch", 12, k.muted, 0);
                        kit.ellipsisText(c, br, .{ .size = 11.5, .weight = .medium, .color = k.text }, 118);
                    }
                    if (diff_files > 0) {
                        const d = diff_ptr.?;
                        ui.spacer(c);
                        ui.key(c, "panel-menu-diff-badge");
                        const badge = ui.div(c).row().h(20).px(6).center().rounded(5).bg(k.accent.alpha(0.14)).hover(k.accent.alpha(0.22)).control();
                        ui.text(c, c.print("{d}f +{d}/-{d}", .{ diff_files, d.additions, d.deletions }), .{ .size = 10.5, .weight = .medium, .color = k.accent });
                        if (badge.clicked()) {
                            const panels_mod = @import("app_panels.zig");
                            var found_diff = false;
                            for (a.panels.tabs.items, 0..) |tb, tix| if (tb.kind == .diffs) {
                                a.panels.host_open = true;
                                panels_mod.showTab(a, tix);
                                found_diff = true;
                                break;
                            };
                            if (!found_diff) panels_mod.addDiffsTab(a);
                            a.view.strip.menu = null;
                        }
                        badge.end();
                    }
                    hdr.end();
                    separator(c, k);
                }
            }
            if (a.tabs.layout()) |s| {
                if (pane >= s.panes.items.len) {
                    a.view.strip.menu = null;
                    return;
                }
                const group = &s.groups[pane];
                if (group.count() > 1) {
                    for (group.items.items, 0..) |tab, ix| {
                        const id = if (ix == group.active) strip.chatId(a, pane) else tab.chat;
                        const title = if (id) |chat| (if (a.findChat(chat)) |ch| @import("view_sidebar.zig").chatLabel(ch) else "Conversation") else "New tab";
                        if (row(c, a, k, .@"chat-round-line", title, ix == group.active)) strip.queue(a, .{ .panel_tab = .{ .pane = pane, .tab = ix } });
                    }
                    separator(c, k);
                }
            } else if (a.tabs.items.items.len > 1) {
                for (a.tabs.items.items, 0..) |id, ix| {
                    const title = if (id) |chat| (if (a.findChat(chat)) |ch| @import("view_sidebar.zig").chatLabel(ch) else "Conversation") else "New tab";
                    if (row(c, a, k, .@"chat-round-line", title, ix == a.tabs.active)) strip.queue(a, .{ .global_tab = ix });
                }
                separator(c, k);
            }
        },
        .host => {
            for (a.panels.tabs.items, 0..) |tab, ix| {
                if (tab.agent) |agent| if (!agent.belongsTo(a.selected)) continue;
                if (tab.browser) |browser| if (!browser.belongsTo(a.selected)) continue;
                const g_icon: icons.Name = switch (tab.kind) {
                    .browser => .globe,
                    .design_canvas => .@"palette-search",
                    else => .document,
                };
                if (row(c, a, k, g_icon, strip.hostTitle(a, tab), ix == a.panels.active)) strip.queue(a, .{ .host_tab = ix });
            }
            if (a.panels.active < a.panels.tabs.items.len) {
                if (row(c, a, k, .close, "Close tab", false)) strip.queue(a, .{ .close_host_tab = a.panels.active });
            }
            if (a.panels.tabs.items.len > 0) separator(c, k);
        },
        .files => {},
    }
    if (row(c, a, k, .plus, "New tab", false)) strip.queue(a, .{ .new = target });
    if (target == .chat) {
        if (row(c, a, k, .@"alt-arrow-right", "Split right", false)) strip.queue(a, .{ .split_right = target });
        if (row(c, a, k, .@"alt-arrow-down", "Split down", false)) strip.queue(a, .{ .split_down = target });
        if (a.tabs.layout()) |s| {
            const vertical = s.axis == .vertical;
            if (target.chat > 0) if (row(c, a, k, if (vertical) .@"alt-arrow-down" else .@"alt-arrow-left", if (vertical) "Move panel up" else "Move panel left", false)) strip.queue(a, .{ .move_left = target });
            if (target.chat + 1 < s.panes.items.len) if (row(c, a, k, if (vertical) .@"alt-arrow-down" else .@"alt-arrow-right", if (vertical) "Move panel down" else "Move panel right", false)) strip.queue(a, .{ .move_right = target });
        }
    }
    if (strip.count(a) > 1) {
        separator(c, k);
        if (row(c, a, k, .@"split-columns", if (a.view.strip.expanded != null) "Restore panels" else "Expand panel", false)) strip.queue(a, .{ .zoom = target });
        if (row(c, a, k, .close, "Close panel", false)) strip.queue(a, .{ .close = target });
    }
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, glyph: icons.Name, label: []const u8, selected: bool) bool {
    return rowImpl(c, a, k, glyph, label, selected, null);
}

fn folderRow(c: *ui.Context, a: *App, k: theme.Colors, glyph: icons.Name, label: []const u8, selected: bool, cursor_node: *?u32) bool {
    return rowImpl(c, a, k, glyph, label, selected, cursor_node);
}

fn rowImpl(c: *ui.Context, a: *App, k: theme.Colors, glyph: icons.Name, label: []const u8, selected: bool, cursor_node: ?*?u32) bool {
    const index = a.view.strip.rows;
    a.view.strip.rows += 1;
    var box = ui.div(c).row().wFull().h(32).px(8).gap(10).itemsCenter().rounded(7).control();
    if (cursor_node) |painted| {
        // Keyboard modality suppresses hover until a real pointer move.
        // Mouse and Enter must then share one pending row, not two fills.
        if (box.hovered() and a.view.strip.cursor != index) {
            if (painted.*) |previous| c.node(previous).style.background = null;
            a.view.strip.cursor = index;
            c.changed = true;
        }
        if (a.view.strip.cursor == index) {
            box = box.bg(k.selected);
            painted.* = box.index;
        }
    } else {
        box = box.hover(k.selected);
        if (a.view.strip.cursor == index) box = box.bg(k.selected);
    }
    defer box.end();
    icons.icon(c, glyph, 16, k.muted, 0);
    kit.ellipsisText(c, label, .{ .size = 13, .color = k.text }, if (a.view.strip.footer_folder) 216 else 170);
    ui.spacer(c);
    if (selected) icons.icon(c, .check, 12, k.muted, 0);
    return box.clicked() or (a.view.strip.activate and a.view.strip.cursor == index);
}
fn separator(c: *ui.Context, k: theme.Colors) void {
    ui.div(c).wFull().h(1).bg(k.border).end();
}

fn folderMenu(c: *ui.Context, a: *App, k: theme.Colors, opened_at: ui.Rect) void {
    const search = @import("strip_folder_search.zig");
    const state = &a.view.strip;
    // Only the focused draft draws a footer chip. Follow it while the window
    // resizes, as the tab strip's chip does.
    const anchor = if (state.footer_folder and strip.same(state.target, strip.pickerPanel(a))) a.view.space_anchor orelse opened_at else opened_at;
    const target = state.target;
    var cursor_node: ?u32 = null;
    const device = strip.device(a, target);
    var matches = search.indices(c.alloc(), a.spaces.items, device, state.query.text()) catch return;
    const footer = state.footer_folder;
    const width: f32 = if (footer) 280 else search.menu_width;
    const above = @max(0, anchor.y - 14);
    const below = @max(0, c.size.h - anchor.y - anchor.h - 14);
    const flip = footer and above < 180 and below > above;
    const budget = if (footer) @min(640, if (flip) below else above) else c.size.h - 16;
    const list_budget = if (footer) std.math.clamp(budget - 152, 0, search.list_height) else search.list_height;
    const height = @min(search.height(matches.len), budget);
    const x = rules.snapToWindow(anchor.x, width, c.size.w, 8);
    const y = rules.snapToWindow(if (footer and !flip) anchor.y - height - 4 else anchor.y + anchor.h + (if (footer) @as(f32, 4) else 0), height, c.size.h, 8);
    {
        const scrim_top = @import("motion_rules.zig").scrimTop(footer, a.view.chrome.y);
        const scrim = ui.div(c).fixed().offset(0, scrim_top).size(c.size.w, @max(0, c.size.h - scrim_top)).layer(4);
        defer scrim.end();
        const scrim_hit = scrim.interaction();
        const trigger = if (!footer) state.active_folder_anchor else null;
        if (scrim_hit.pressed or scrim_hit.right_pressed or scrim_hit.clicked or kit.pressedOutside(c, trigger)) {
            state.menu = null;
            c.focus = 0;
            a.view.focus_composer = true;
            return;
        }
    }
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(width).maxH(@max(32, budget)).column().p(5).gap(2).bg(k.overlay.alpha(1)).border(k.border).borderW(1).rounded(12).layer(5).clip()));
    defer card.end();
    {
        ui.key(c, "panel-menu-search");
        const field = ui.div(c).row().wFull().px(10).py(6).rounded(7).bg(k.ink(0.04));
        defer field.end();
        const field_id = c.peekId(null);
        if (state.search_focus) {
            c.focus = field_id;
            state.search_focus = false;
        }
        const result = ui.textField(c, &state.query, .{ .placeholder = if (footer) "Search projects…" else "Search folders…", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 13 });
        if (result.changed) {
            matches = search.indices(c.alloc(), a.spaces.items, device, state.query.text()) catch return;
            state.cursor = if (footer) 0 else search.afterEdit(matches.len);
            state.select_current = false;
            state.reveal = true;
            if (state.search_scroll != 0) c.scroll.put(c.gpa, state.search_scroll, 0) catch {};
        }
        // Plain Return arrives through NSTextInputClient as a field submission,
        // not a shortcut. Activate the same row and deferred action as a click.
        if (result.submitted) state.activate = true;
    }
    ui.div(c).h(4).wFull().end();
    const current = strip.folder(a, target);
    if (state.select_current) {
        state.select_current = false;
        state.cursor = if (footer and a.new_no_project) matches.len + 1 else 0;
        for (matches, 0..) |space, ix| if (current) |folder| {
            if (std.mem.eql(u8, folder.name, a.spaces.items[space].name)) {
                state.cursor = ix;
                break;
            }
        };
    }
    if (matches.len == 0) {
        const empty = ui.div(c).row().wFull().px(8).py(6);
        defer empty.end();
        ui.text(c, if (footer) (if (state.query.text().len == 0) "No projects on this device." else "No projects match.") else "No folders match", .{ .size = 12, .color = k.faint });
    }
    {
        ui.key(c, "panel-menu-list");
        const visible = @min(list_budget, @as(f32, @floatFromInt(matches.len)) * 32);
        const list = ui.div(c).column().wFull().h(visible).scrollY();
        defer list.end();
        state.search_scroll = c.node(list.index).id;
        if (state.reveal and state.cursor < matches.len) {
            const was = c.scroll.get(state.search_scroll) orelse 0;
            const top = @as(f32, @floatFromInt(state.cursor)) * 32;
            const next = if (top < was) top else if (top + 32 > was + visible) top + 32 - visible else was;
            if (next != was) {
                c.scroll.put(c.gpa, state.search_scroll, @max(0, next)) catch {};
                c.changed = true;
            }
        }
        state.reveal = false;
        for (matches) |ix| {
            const space = a.spaces.items[ix];
            const selected = if (current) |folder| std.mem.eql(u8, folder.name, space.name) else false;
            if (folderRow(c, a, k, if (selected) .check else .folder, space.name, false, &cursor_node)) strip.queue(a, .{ .folder = .{ .panel = target, .index = ix } });
        }
    }
    separator(c, k);
    if (footer) {
        if (folderRow(c, a, k, .plus, "New project…", false, &cursor_node)) strip.queue(a, .{ .add_folder = target });
        if (folderRow(c, a, k, .close, "Don't work in a project", a.new_no_project, &cursor_node)) strip.queue(a, .{ .folder = .{ .panel = target, .index = null } });
    } else {
        if (folderRow(c, a, k, .close, "Don't work in a project", false, &cursor_node)) strip.queue(a, .{ .folder = .{ .panel = target, .index = null } });
        if (folderRow(c, a, k, .plus, "New project…", false, &cursor_node)) strip.queue(a, .{ .add_folder = target });
    }
}
