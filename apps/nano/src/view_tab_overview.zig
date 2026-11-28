//! Browse-style visual session overview grid (⇧⌘\, matching TabOverview.swift):
//! shows every open workspace tab, split pane, and panel tab as a scannable card
//! with filter search, live conversation preview, keyboard grid navigation,
//! quick Split (⌘D) and Close (⌘⌫) actions, and seamless handoff to ⌘K.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const pal = @import("palette.zig");
const workspace = @import("workspace.zig");
const view_palette = @import("view_palette.zig");
const view_tab_strip_render = @import("view_tab_strip_render.zig");
const tip = @import("view_tooltip.zig");
const App = @import("app.zig").App;
const S = ui.Shortcut;

const phi: f32 = 1.618;

pub const State = struct {
    open: bool = false,
    query: ui.TextBuffer = .{},
    selected: usize = 0,
    focus: bool = false,
    scroll_id: u64 = 0,
    reveal: bool = false,
    cols: usize = 3,

    pub fn deinit(s: *State) void {
        @import("text_buffer.zig").deinit(&s.query);
    }
};

pub const Target = union(enum) {
    pane: usize,
    pane_tab: struct { pane: usize, tab: usize },
    workspace: usize,
};

pub const Item = struct {
    target: Target,
    active: bool,
    closable: bool,
    chat_id: ?[]const u8,
    title: []const u8,
    project: []const u8,
    branch: ?[]const u8,
    device: []const u8,
    panes_n: usize,
    kind_label: []const u8,
};

pub fn toggle(a: *App) void {
    if (a.view.tab_overview.open) close(a) else open(a);
}

pub fn open(a: *App) void {
    a.view.palette.open = false;
    @import("view.zig").closeTransientPopovers(a);
    a.view.fs_top_peek = false;
    const s = &a.view.tab_overview;
    s.open = true;
    s.query.clear();
    s.selected = 0;
    s.focus = true;
    s.reveal = false;
    a.redraw();
}

pub fn close(a: *App) void {
    const s = &a.view.tab_overview;
    if (!s.open) return;
    s.open = false;
    a.view.focus_composer = true;
    a.redraw();
}

fn queryOf(c: *ui.Context, a: *const App) []const u8 {
    const buf = c.alloc().alloc(u8, 512) catch return "";
    return pal.foldBuf(buf, std.mem.trim(u8, a.view.tab_overview.query.text(), " \t\n\r"));
}

fn appendIfMatches(
    a: *const App,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Item),
    query: []const u8,
    target: Target,
    active: bool,
    closable: bool,
    chat_id: ?[]const u8,
    ws_ix: ?usize,
    panes_n: usize,
    kind_label: []const u8,
) !void {
    const ch = if (chat_id) |cid| a.findChat(cid) else null;
    const title = if (ch) |chat| view_palette.firstLine(chat.title orelse "Untitled session") else "New tab";
    const proj_id: ?[]const u8 = if (ch) |chat| chat.space_id else if (ws_ix) |wi| a.workspaceProject(wi) else null;
    const project: []const u8 = if (a.findSpace(proj_id)) |sp| sp.name else if (proj_id == null and ch != null) "No project" else "";
    const branch: ?[]const u8 = if (ch) |chat| if (chat.branch) |b| blk: {
        const trimmed = std.mem.trim(u8, b, " ");
        break :blk if (trimmed.len > 0) trimmed else null;
    } else null else null;
    const device: []const u8 = if (ch) |chat| view_palette.deviceOrEmpty(a, chat.device_id) else "";
    var buf: [1024]u8 = undefined;
    const hay = std.fmt.bufPrint(&buf, "{s} {s} {s} {s} {s}", .{ title, project, branch orelse "", device, kind_label }) catch title;
    if (!pal.matchesQuery(query, hay)) return;
    try out.append(gpa, .{
        .target = target,
        .active = active,
        .closable = closable,
        .chat_id = chat_id,
        .title = title,
        .project = project,
        .branch = branch,
        .device = device,
        .panes_n = panes_n,
        .kind_label = kind_label,
    });
}

pub fn items(a: *const App, gpa: std.mem.Allocator, query: []const u8) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    errdefer out.deinit(gpa);

    if (a.tabs.layout()) |s| {
        if (s.panes.items.len > 1) {
            for (0..s.panes.items.len) |ix| {
                const cid = if (ix == s.focus) a.tabs.current() else s.panes.items[ix];
                try appendIfMatches(a, gpa, &out, query, .{ .pane = ix }, ix == s.focus, true, cid, null, 1, "Split Pane");
            }
        } else {
            const cid = view_tab_strip_render.workspaceChatId(a, a.tabs.active);
            try appendIfMatches(a, gpa, &out, query, .{ .workspace = a.tabs.active }, true, a.tabs.items.items.len > 1, cid, a.tabs.active, 1, "Open Tab");
        }
        const group = &s.groups[s.focus];
        if (group.items.items.len > 1) {
            for (group.items.items, 0..) |pt, pt_ix| {
                if (pt_ix == group.active) continue;
                try appendIfMatches(a, gpa, &out, query, .{ .pane_tab = .{ .pane = s.focus, .tab = pt_ix } }, false, true, pt.chat, null, 1, "Panel Tab");
            }
        }
    } else {
        const cid = view_tab_strip_render.workspaceChatId(a, a.tabs.active);
        try appendIfMatches(a, gpa, &out, query, .{ .workspace = a.tabs.active }, true, a.tabs.items.items.len > 1, cid, a.tabs.active, 1, "Open Tab");
    }

    for (0..a.tabs.items.items.len) |ws| {
        if (ws == a.tabs.active) continue;
        const cid = view_tab_strip_render.workspaceChatId(a, ws);
        const panes_n: usize = if (ws < a.tabs.splits.items.len) (if (a.tabs.splits.items[ws]) |s| s.panes.items.len else 1) else 1;
        try appendIfMatches(a, gpa, &out, query, .{ .workspace = ws }, false, true, cid, ws, panes_n, if (panes_n > 1) "Split Workspace" else "Open Tab");
    }

    return out.toOwnedSlice(gpa);
}

fn activateItem(a: *App, item: Item) void {
    close(a);
    switch (item.target) {
        .pane => |ix| a.focusPane(ix),
        .pane_tab => |pt| {
            if (a.tabs.layout()) |s| if (s.focus != pt.pane) a.focusPane(pt.pane);
            a.showPaneTab(pt.tab);
        },
        .workspace => |ws| {
            a.view.settings_open = false;
            a.showTab(ws);
        },
    }
}

fn splitItem(a: *App, item: Item) void {
    var buf: [256]u8 = undefined;
    const own: ?[]const u8 = if (item.chat_id) |cid| blk: {
        const copy = buf[0..@min(cid.len, buf.len)];
        @memcpy(copy, cid[0..copy.len]);
        break :blk copy;
    } else null;
    close(a);
    switch (item.target) {
        .pane => |ix| a.focusPane(ix),
        else => if (own) |id| a.splitOpening(.horizontal, id) else a.splitPane(.horizontal),
    }
}

fn closeItem(a: *App, item: Item) void {
    if (!item.closable) return;
    switch (item.target) {
        .pane => |ix| {
            a.focusPane(ix);
            a.closePanel();
        },
        .pane_tab => |pt| {
            var buf: [256]u8 = undefined;
            const own: ?[]const u8 = if (item.chat_id) |cid| blk: {
                const copy = buf[0..@min(cid.len, buf.len)];
                @memcpy(copy, cid[0..copy.len]);
                break :blk copy;
            } else null;
            if (a.tabs.closeBackgroundPaneTab(pt.pane, pt.tab)) {
                if (own) |id| a.archiveClosed(id, a.settings.get(.archive_sessions_on_close));
            }
        },
        .workspace => |ws| a.closeTabArchiving(ws),
    }
    a.redraw();
}

pub fn keys(c: *ui.Context, a: *App) void {
    const s = &a.view.tab_overview;
    if (!s.open) return;
    if (c.shortcut(.{ .key = S.escape })) return close(a);

    const right = c.shortcut(.{ .key = S.right }) or c.shortcut(.{ .key = S.tab }) or c.shortcut(.{ .ctrl = true, .key = 'n' });
    const left = !right and (c.shortcut(.{ .key = S.left }) or c.shortcut(.{ .shift = true, .key = S.tab }) or c.shortcut(.{ .ctrl = true, .key = 'p' }));
    const down = !right and !left and c.shortcut(.{ .key = S.down });
    const up = !right and !left and !down and c.shortcut(.{ .key = S.up });
    const enter = c.shortcut(.{ .key = S.enter });
    // The user's Split binding, as the hints show it.
    const split_key = @import("view.zig").boundShortcut(c, a, "splitTerminal");
    const close_key = c.shortcut(S.native(.{ .cmd = true, .key = S.backspace }));
    if (!right and !left and !down and !up and !enter and !split_key and !close_key) return;

    const list = items(a, c.alloc(), queryOf(c, a)) catch return;
    if (list.len == 0) return;
    s.selected = @min(s.selected, list.len - 1);

    if (right) {
        s.selected = (s.selected + 1) % list.len;
        s.reveal = true;
        return a.redraw();
    }
    if (left) {
        s.selected = (s.selected + list.len - 1) % list.len;
        s.reveal = true;
        return a.redraw();
    }
    const cols = @max(@as(usize, 1), s.cols);
    if (down) {
        s.selected = @min(s.selected + cols, list.len - 1);
        s.reveal = true;
        return a.redraw();
    }
    if (up) {
        s.selected = s.selected -| cols;
        s.reveal = true;
        return a.redraw();
    }

    const active = list[s.selected];
    if (split_key) return splitItem(a, active);
    if (close_key) {
        closeItem(a, active);
        const after = items(a, c.alloc(), queryOf(c, a)) catch &.{};
        s.selected = @min(s.selected, after.len -| 1);
        return;
    }
    if (enter) activateItem(a, active);
}

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.tab_overview;
    if (!s.open) return;

    const query = queryOf(c, a);
    const list = items(a, c.alloc(), query) catch return;
    s.selected = @min(s.selected, list.len -| 1);
    const split_hint = splitHint(c, a);
    var palette_buf: [32]u8 = undefined;
    const palette_hint = @import("shortcuts.zig").chordBadge(&palette_buf, @import("shortcuts.zig").command_palette);

    const scrim_color = if (a.view.full_screen or k.dark) ui.Color.black.alpha(0.80) else k.background.alpha(0.86);
    ui.key(c, "tab-overview-scrim");
    const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(8).bg(scrim_color).column().itemsCenter();
    defer scrim.end();

    const avail_w = @max(@as(f32, 260), @min(@as(f32, 1120), c.size.w - 56));
    const cols: usize = if (list.len <= 3)
        @max(@as(usize, 1), @min(@max(@as(usize, 1), list.len), @as(usize, @intFromFloat(@max(1, @floor((avail_w + 16) / 300))))))
    else
        std.math.clamp(@as(usize, @intFromFloat(@max(1, @floor((avail_w + 16) / 276)))), 1, 4);
    s.cols = cols;
    const card_w = @max(@as(f32, 200), @floor((avail_w - @as(f32, @floatFromInt(cols -| 1)) * 16) / @as(f32, @floatFromInt(cols))));

    var any_surface_hovered = false;
    var action_type: enum { none, activate, split, close, open_palette, new_session, done } = .none;
    var action_item: ?Item = null;

    {
        const top_bar = ui.div(c).row().w(avail_w).pt(28).pb(16).gap(12).itemsCenter();
        defer top_bar.end();
        if (top_bar.hovered()) any_surface_hovered = true;

        {
            const brand = ui.div(c).row().gap(8).itemsCenter();
            defer brand.end();
            icons.icon(c, .widget, 18, k.muted, 0);
            ui.text(c, "Open Sessions", .{ .size = 16, .line_height = 22, .weight = .semibold, .color = k.text });
            const badge = ui.div(c).h(20).px(8).center().rounded(10).bg(k.ink(if (k.dark) 0.08 else 0.06));
            defer badge.end();
            const badge_label = if (query.len > 0) c.print("{d} shown", .{list.len}) else c.print("{d} open", .{list.len});
            ui.text(c, badge_label, .{ .size = 11, .line_height = 14, .weight = theme.ui_medium_weight, .color = k.muted });
        }
        ui.spacer(c);

        {
            const search_w = @min(@as(f32, 280), @max(140, avail_w * 0.32));
            const search_box = ui.div(c).row().w(search_w).h(32).px(10).gap(8).itemsCenter().rounded(10).bg(k.composer).border(k.border).borderW(1);
            defer search_box.end();
            icons.icon(c, .@"palette-search", 14, k.muted, 0);
            {
                const field_wrap = ui.div(c).row().grow().w(0).itemsCenter();
                defer field_wrap.end();
                ui.key(c, "tab-overview-search");
                const at = c.nodes.items.len;
                const res = ui.textField(c, &s.query, .{ .placeholder = "Filter open sessions…", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 13, .line_height = 20 });
                const id = c.node(@intCast(at)).id;
                if (s.focus or c.focus != id) {
                    c.focus = id;
                    c.changed = true;
                    s.focus = false;
                }
                if (res.changed) s.selected = 0;
                if (res.submitted and list.len > 0) {
                    action_type = .activate;
                    action_item = list[@min(s.selected, list.len - 1)];
                }
            }
            if (s.query.text().len > 0) {
                ui.key(c, "tab-overview-search-clear");
                const clear = ui.div(c).size(18, 18).center().rounded(9).bg(k.ink(0.08)).hover(k.hover).control();
                defer clear.end();
                icons.icon(c, .close, 10, k.muted, 0);
                if (clear.clicked()) {
                    s.query.clear();
                    s.selected = 0;
                    s.focus = true;
                    a.redraw();
                }
            }
        }

        {
            ui.key(c, "tab-overview-new-session");
            const new_btn = ui.div(c).row().h(30).px(11).gap(5).itemsCenter().rounded(8).bg(k.accent).hover(k.accent.alpha(0.9)).control();
            defer new_btn.end();
            icons.icon(c, .plus, 12, k.onAccent(), 0);
            ui.text(c, "New Session", .{ .size = 12, .line_height = 16, .weight = theme.ui_medium_weight, .color = k.onAccent() });
            if (new_btn.clicked()) action_type = .new_session;
        }
        {
            ui.key(c, "tab-overview-palette-switch");
            const pal_btn = tip.on(
                ui.div(c).row().h(30).px(10).center().rounded(8).bg(k.composer).border(k.border).borderW(1).hover(k.hover).control(),
                k,
                .{ .text = c.print("Command palette ({s})", .{palette_hint}), .look = .tab },
            );
            defer pal_btn.end();
            ui.text(c, palette_hint, .{ .size = 12, .line_height = 16, .weight = theme.ui_medium_weight, .color = k.text.alpha(0.85) });
            if (pal_btn.clicked()) action_type = .open_palette;
        }
        {
            ui.key(c, "tab-overview-done");
            const done_btn = ui.div(c).row().h(30).px(11).center().rounded(8).bg(k.composer).border(k.border).borderW(1).hover(k.hover).control();
            defer done_btn.end();
            ui.text(c, "Done", .{ .size = 12, .line_height = 16, .weight = theme.ui_medium_weight, .color = k.text });
            if (done_btn.clicked()) action_type = .done;
        }
    }

    {
        const scroll_h = @max(@as(f32, 220), c.size.h - 140);
        var style: ui.Style = .{
            .width = .{ .px = avail_w },
            .height = .fill,
            .max_height = scroll_h,
            .direction = .column,
            .gap = 16,
        };
        if (@hasField(ui.Style, "scrollbar")) style.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
        const at = c.nodes.items.len;
        ui.scroll(c, style);
        defer ui.end(c);
        const id = c.node(@intCast(at)).id;
        s.scroll_id = id;

        if (list.len == 0) {
            const empty = ui.div(c).column().w(avail_w).py(56).gap(8).itemsCenter().center();
            defer empty.end();
            if (empty.hovered()) any_surface_hovered = true;
            icons.icon(c, .widget, 28, k.muted.alpha(0.6), 0);
            ui.text(c, "No open sessions match", .{ .size = 14, .line_height = 20, .weight = .medium, .color = k.text });
            ui.text(c, "Clear your filter or open a new session to see it here.", .{ .size = 12, .line_height = 18, .color = k.muted });
        } else {
            var r_start: usize = 0;
            while (r_start < list.len) : (r_start += cols) {
                const r_end = @min(list.len, r_start + cols);
                const row_box = ui.div(c).row().w(avail_w).gap(16);
                defer row_box.end();
                for (list[r_start..r_end], r_start..) |item, ix| {
                    ui.key(c, c.print("overview-card-{d}", .{ix}));
                    const is_sel = ix == s.selected;
                    const border_c = if (is_sel) k.accent else k.border;
                    const base_card = ui.div(c).column().w(card_w).h(196).rounded(14).bg(k.composer).border(border_c).borderW(if (is_sel) 2 else 1).clip().control();
                    const card = if (is_sel) kit.shadowLg(base_card) else base_card;
                    defer card.end();

                    const hot = card.hovered();
                    if (hot) {
                        any_surface_hovered = true;
                        c.cursor_hand = true;
                        if (!c.keyboard_hides_hover and s.selected != ix) {
                            s.selected = ix;
                            c.changed = true;
                        }
                    }

                    const st_val = if (item.chat_id) |cid| workspace.statusOf(a.sessions.items, cid) else .idle;
                    const running = st_val == .working or st_val == .awaiting_input;
                    const ch = if (item.chat_id) |cid| a.findChat(cid) else null;

                    var child_hit: enum { none, split, close } = .none;
                    {
                        const hdr = ui.div(c).row().wFull().h(36).px(12).gap(6).itemsCenter();
                        defer hdr.end();
                        const dot_c = if (running or item.active) k.accent else k.muted.alpha(0.55);
                        ui.div(c).size(6, 6).rounded(3).bg(dot_c).end();
                        {
                            const tw = ui.div(c).row().grow().w(0).clip();
                            defer tw.end();
                            const title_room = @max(40, card_w - 24 - 12 - (if (item.active) @as(f32, 46) else 0) - (if (hot or is_sel) @as(f32, 52) else 0));
                            kit.ellipsisText(c, item.title, .{ .size = 13, .line_height = 18, .weight = .semibold, .color = k.text }, title_room);
                        }
                        if (item.active) {
                            const pill = ui.div(c).h(18).px(6).center().rounded(9).bg(k.accent_wash);
                            defer pill.end();
                            ui.text(c, "Active", .{ .size = 10, .line_height = 14, .weight = .semibold, .color = k.accent });
                        }
                        if (hot or is_sel) {
                            const btns = ui.div(c).row().gap(4).itemsCenter();
                            defer btns.end();
                            {
                                ui.key(c, "overview-card-split");
                                const sb = tip.on(ui.div(c).size(22, 22).center().rounded(11).bg(k.ink(0.06)).hover(k.hover).control(), k, .{ .text = c.print("Split right ({s})", .{split_hint}) });
                                defer sb.end();
                                icons.icon(c, .@"split-columns", 11, k.text.alpha(0.82), 0);
                                if (sb.clicked()) child_hit = .split;
                            }
                            if (item.closable) {
                                ui.key(c, "overview-card-close");
                                const cb = tip.on(ui.div(c).size(22, 22).center().rounded(11).bg(k.ink(0.06)).hover(k.hover).control(), k, .{ .text = c.print("Close ({s})", .{close_hint}) });
                                defer cb.end();
                                icons.icon(c, .close, 10, k.muted, 0);
                                if (cb.clicked()) child_hit = .close;
                            }
                        }
                    }

                    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border.alpha(0.55) }, .none, null);

                    {
                        const body = ui.div(c).column().wFull().grow().h(0).p(12).gap(8).clip();
                        defer body.end();
                        {
                            const meta = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
                            defer meta.end();
                            if (item.project.len > 0) metaChip(c, k, .folder, item.project);
                            if (item.branch) |br| metaChip(c, k, .@"git-branch", br);
                            if (item.device.len > 0) metaChip(c, k, .monitor, item.device);
                            if (item.panes_n > 1) metaChip(c, k, .widget, c.print("{d} panes", .{item.panes_n}));
                            ui.spacer(c);
                            if (ch) |chat| {
                                var tb: [24]u8 = undefined;
                                ui.text(c, rules.relativeTime(&tb, a.nowMs(), chat.timeMs()), .{ .size = 10.5, .line_height = 14, .color = k.muted });
                            }
                        }
                        {
                            const preview_w = @max(60, card_w - 24);
                            const excerpt = ui.div(c).column().wFull().grow().h(0).gap(5).clip();
                            defer excerpt.end();
                            var drew = false;
                            if (item.chat_id) |cid| {
                                if (view_palette.transcriptForChat(a, cid)) |tr_ptr| {
                                    const entries = tr_ptr.entries.items;
                                    const start = entries.len -| 3;
                                    for (entries[start..]) |*te| {
                                        if (te.role == .system) continue;
                                        const snip = view_palette.firstTextPart(te) orelse continue;
                                        drew = true;
                                        const row_line = ui.div(c).row().wFull().gap(5).itemsCenter();
                                        defer row_line.end();
                                        ui.text(c, if (te.role == .user) "You" else "Graff", .{ .size = 10.5, .line_height = 15, .weight = .medium, .color = if (te.role == .user) k.accent else k.muted });
                                        kit.ellipsisText(c, view_palette.firstLine(snip), .{ .size = 11.5, .line_height = 16, .color = k.text.alpha(0.85) }, @max(40, preview_w - 42));
                                    }
                                }
                            }
                            if (!drew) {
                                const fallback = if (ch) |chat| blk: {
                                    const prev = std.mem.trim(u8, chat.preview orelse "", " \t\n\r");
                                    break :blk if (prev.len > 0) view_palette.firstLine(prev) else "Active workspace session";
                                } else "Blank workspace draft ready to prompt";
                                kit.ellipsisText(c, fallback, .{ .size = 12, .line_height = 17, .color = k.muted }, preview_w);
                            }
                        }
                    }

                    switch (child_hit) {
                        .split => {
                            action_type = .split;
                            action_item = item;
                        },
                        .close => {
                            action_type = .close;
                            action_item = item;
                        },
                        .none => if (card.clicked()) {
                            action_type = .activate;
                            action_item = item;
                        },
                    }
                    if (is_sel and s.reveal) revealCard(c, id, card);
                }
            }
        }
        s.reveal = false;
    }

    {
        const foot = ui.div(c).row().w(avail_w).h(34).px(8).gap(14).justifyCenter().itemsCenter();
        defer foot.end();
        if (foot.hovered()) any_surface_hovered = true;
        overviewHint(c, k, "← → ↑ ↓", "Navigate");
        overviewHint(c, k, "↵", "Open");
        overviewHint(c, k, split_hint, "Split");
        overviewHint(c, k, close_hint, "Close");
        overviewHint(c, k, "Esc", "Done");
    }

    if (action_type == .none and !any_surface_hovered and scrim.clicked()) {
        return close(a);
    }

    switch (action_type) {
        .none => {},
        .activate => if (action_item) |item| activateItem(a, item),
        .split => if (action_item) |item| splitItem(a, item),
        .close => if (action_item) |item| {
            closeItem(a, item);
            const after = items(a, c.alloc(), queryOf(c, a)) catch &.{};
            s.selected = @min(s.selected, after.len -| 1);
        },
        .new_session => {
            close(a);
            a.newTab();
        },
        .open_palette => {
            close(a);
            view_palette.toggle(a, .preserve_tabs);
        },
        .done => close(a),
    }
}

fn metaChip(c: *ui.Context, k: theme.Colors, glyph: icons.Name, label: []const u8) void {
    const ch = ui.div(c).row().h(18).px(6).gap(4).itemsCenter().rounded(5).bg(k.ink(if (k.dark) 0.06 else 0.04));
    defer ch.end();
    icons.icon(c, glyph, 10, k.muted, 0);
    kit.ellipsisText(c, label, .{ .size = 10.5, .line_height = 14, .color = k.muted }, 96);
}

/// The overview's own fixed keys, as this platform writes them.
const close_hint = if (builtin.os.tag == .macos) "⌘⌫" else "Ctrl+Backspace";

/// Split follows the user's `splitTerminal` binding, as the palette's hint does.
fn splitHint(c: *ui.Context, a: *const App) []const u8 {
    const buf = c.alloc().alloc(u8, 48) catch return "";
    return @import("shortcuts.zig").platformBadge(buf, view_palette.comboFor(a, "splitTerminal"));
}

fn overviewHint(c: *ui.Context, k: theme.Colors, key: []const u8, label: []const u8) void {
    const r = ui.div(c).row().gap(5).itemsCenter();
    defer r.end();
    kit.kbdHint(c, k, key);
    ui.text(c, label, .{ .size = 10.5, .line_height = 14, .color = k.muted });
}

fn revealCard(c: *ui.Context, scroll_id: u64, d: ui.Div) void {
    const box = c.rects.get(scroll_id) orelse return;
    const r = c.rects.get(c.node(d.index).id) orelse return;
    const now = c.scroll.get(scroll_id) orelse 0;
    var to = now;
    if (r.y < box.y) to = now - (box.y - r.y) else if (r.y + r.h > box.y + box.h) to = now + (r.y + r.h - box.y - box.h);
    if (to != now) c.scroll.put(c.gpa, scroll_id, @max(0, to)) catch {};
}
