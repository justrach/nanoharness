//! Browse-style visual ⌃Tab / ⌃⇧Tab tab cycle HUD (TabCycleHUD.swift):
//! appears briefly over the window when cycling workspaces or panel tabs,
//! showing a sliding window of up to 7 live preview cards with an active ring,
//! click-to-jump support, Escape dismissal, and clean timer auto-hide.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const workspace = @import("workspace.zig");
const view_palette = @import("view_palette.zig");
const view_tab_strip_render = @import("view_tab_strip_render.zig");
const App = @import("app.zig").App;

pub const duration_s: f64 = 1.15;
const max_visible: usize = 7;

pub const State = struct {
    until: f64 = 0,
    pane_mode: bool = false,
};

pub fn isOpen(a: *const App, now: f64) bool {
    return a.view.tab_cycle.until > now;
}

pub fn show(a: *App, now: f64, pane_mode: bool) void {
    a.view.tab_cycle = .{ .until = now + duration_s, .pane_mode = pane_mode };
    a.redraw();
}

pub fn hide(a: *App) void {
    if (a.view.tab_cycle.until == 0) return;
    a.view.tab_cycle.until = 0;
    a.redraw();
}

const CycleCard = struct {
    index: usize,
    active: bool,
    chat_id: ?[]const u8,
    ws_ix: ?usize,
    panes_n: usize,
    title: []const u8,
    project: []const u8,
    branch: ?[]const u8,
    device: []const u8,
};

fn buildCard(a: *const App, index: usize, active: bool, chat_id: ?[]const u8, ws_ix: ?usize, panes_n: usize) CycleCard {
    const ch = if (chat_id) |cid| a.findChat(cid) else null;
    const title = if (ch) |chat| view_palette.firstLine(chat.title orelse "Untitled session") else "New tab";
    const proj_id: ?[]const u8 = if (ch) |chat| chat.space_id else if (ws_ix) |wi| a.workspaceProject(wi) else null;
    const project: []const u8 = if (a.findSpace(proj_id)) |sp| sp.name else if (proj_id == null and ch != null) "No project" else "";
    const branch: ?[]const u8 = if (ch) |chat| if (chat.branch) |b| blk: {
        const trimmed = std.mem.trim(u8, b, " ");
        break :blk if (trimmed.len > 0) trimmed else null;
    } else null else null;
    const device: []const u8 = if (ch) |chat| view_palette.deviceOrEmpty(a, chat.device_id) else "";
    return .{
        .index = index,
        .active = active,
        .chat_id = chat_id,
        .ws_ix = ws_ix,
        .panes_n = panes_n,
        .title = title,
        .project = project,
        .branch = branch,
        .device = device,
    };
}

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const tc = &a.view.tab_cycle;
    if (tc.until == 0) return;
    if (c.time >= tc.until or a.view.palette.open or a.view.tab_overview.open or a.view.settings_open) {
        tc.until = 0;
        return;
    }
    const remaining = tc.until - c.time;
    c.frameIn(@floatCast(@max(0.05, remaining)));

    var cards_list: std.ArrayList(CycleCard) = .empty;
    var active_ix: usize = 0;

    if (tc.pane_mode) {
        const s = a.tabs.layout() orelse {
            tc.until = 0;
            return;
        };
        const group = &s.groups[s.focus];
        if (group.items.items.len < 2) {
            tc.until = 0;
            return;
        }
        active_ix = @min(group.active, group.items.items.len - 1);
        for (group.items.items, 0..) |pt, pt_ix| {
            cards_list.append(c.alloc(), buildCard(a, pt_ix, pt_ix == active_ix, pt.chat, null, 1)) catch break;
        }
    } else {
        const total = a.tabs.items.items.len;
        if (total < 2) {
            tc.until = 0;
            return;
        }
        active_ix = @min(a.tabs.active, total - 1);
        for (0..total) |ws| {
            const cid = view_tab_strip_render.workspaceChatId(a, ws);
            const panes_n: usize = if (ws < a.tabs.splits.items.len) (if (a.tabs.splits.items[ws]) |s| s.panes.items.len else 1) else 1;
            cards_list.append(c.alloc(), buildCard(a, ws, ws == active_ix, cid, ws, panes_n)) catch break;
        }
    }

    const cards = cards_list.items;
    if (cards.len < 2) {
        tc.until = 0;
        return;
    }

    const start = if (cards.len <= max_visible) 0 else @min(active_ix -| (max_visible / 2), cards.len - max_visible);
    const end = @min(cards.len, start + max_visible);
    const shown = cards[start..end];
    const hidden_before = start;
    const hidden_after = cards.len - end;
    const chosen = cards[active_ix];

    const dark = k.dark;
    const tray_bg: ui.Color = k.composer.alpha(0.97);
    const tray_border: ui.Color = if (dark) ui.Color.white.alpha(0.14) else k.border;

    ui.key(c, "tab-cycle-hud-layer");
    const layer = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).center().layer(7);
    defer layer.end();

    ui.key(c, "tab-cycle-hud");
    const tray = kit.shadowLg(ui.div(c).column().px(16).py(14).gap(12).rounded(16).bg(tray_bg).border(tray_border).borderW(1).itemsCenter());
    defer tray.end();

    var picked: ?usize = null;
    {
        const row_box = ui.div(c).row().gap(10).itemsCenter();
        defer row_box.end();
        if (hidden_before > 0) overflowBadge(c, k, c.print("\u{2039} {d}", .{hidden_before}));
        for (shown) |item| {
            ui.key(c, c.print("tab-cycle-card-{d}", .{item.index}));
            const card_bg: ui.Color = if (item.active) k.accent_wash else .transparent;
            const btn = ui.div(c).column().w(146).p(6).gap(6).rounded(11).bg(card_bg).hover(k.hover).control();
            defer btn.end();
            if (btn.hovered()) c.cursor_hand = true;

            const thumb_bg: ui.Color = if (dark) ui.Color.white.alpha(0.055) else ui.Color.black.alpha(0.035);
            const thumb_border: ui.Color = if (item.active) k.accent else if (dark) ui.Color.white.alpha(0.10) else ui.Color.black.alpha(0.08);
            const ch = if (item.chat_id) |cid| a.findChat(cid) else null;
            const st_val = if (item.chat_id) |cid| workspace.statusOf(a.sessions.items, cid) else .idle;
            const running = st_val == .working or st_val == .awaiting_input;

            {
                const thumb = ui.div(c).column().w(134).h(72).p(8).gap(5).rounded(8).bg(thumb_bg).border(thumb_border).borderW(if (item.active) 1.5 else 1).clip();
                defer thumb.end();
                {
                    const top = ui.div(c).row().wFull().gap(5).itemsCenter();
                    defer top.end();
                    const dot_c: ui.Color = if (running or item.active) k.accent else k.muted.alpha(0.6);
                    ui.div(c).size(5, 5).rounded(2.5).bg(dot_c).end();
                    if (item.project.len > 0) {
                        kit.ellipsisText(c, item.project, .{ .size = 10, .line_height = 13, .weight = theme.ui_medium_weight, .color = k.muted }, 104);
                    } else if (item.panes_n > 1) {
                        ui.text(c, c.print("{d} panes", .{item.panes_n}), .{ .size = 10, .line_height = 13, .color = k.muted });
                    }
                }
                const excerpt_w: f32 = 118;
                var drew = false;
                if (item.chat_id) |cid| {
                    if (view_palette.transcriptForChat(a, cid)) |tr_ptr| {
                        const entries = tr_ptr.entries.items;
                        const tail_start = entries.len -| 2;
                        for (entries[tail_start..]) |*te| {
                            if (te.role == .system) continue;
                            const snip = view_palette.firstTextPart(te) orelse continue;
                            drew = true;
                            kit.ellipsisText(c, view_palette.firstLine(snip), .{ .size = 10.5, .line_height = 14, .color = k.text.alpha(0.84) }, excerpt_w);
                        }
                    }
                }
                if (!drew) {
                    const fallback = if (ch) |chat| blk: {
                        const prev = std.mem.trim(u8, chat.preview orelse "", " \t\n\r");
                        break :blk if (prev.len > 0) view_palette.firstLine(prev) else "Active session";
                    } else "Draft session";
                    kit.ellipsisText(c, fallback, .{ .size = 10.5, .line_height = 14, .color = k.muted }, excerpt_w);
                }
            }

            kit.ellipsisText(c, item.title, .{
                .size = 11.5,
                .line_height = 15,
                .weight = if (item.active) .semibold else .medium,
                .color = if (item.active) k.text else k.text.alpha(0.86),
            }, 134);

            if (btn.clicked()) picked = item.index;
        }
        if (hidden_after > 0) overflowBadge(c, k, c.print("{d} \u{203a}", .{hidden_after}));
    }

    {
        const strip_w = @max(@as(f32, 360), @as(f32, @floatFromInt(shown.len)) * 146 + @as(f32, @floatFromInt(shown.len -| 1)) * 10);
        const title_w: f32 = if (shown.len <= 2) 150 else 210;
        const foot = ui.div(c).row().w(strip_w).gap(8).itemsCenter();
        defer foot.end();
        kit.ellipsisText(c, chosen.title, .{ .size = 12, .line_height = 16, .weight = .semibold, .color = k.text }, title_w);
        if (chosen.project.len > 0) {
            ui.text(c, "\u{00b7}", .{ .size = 11, .line_height = 15, .color = k.muted });
            kit.ellipsisText(c, chosen.project, .{ .size = 11, .line_height = 15, .color = k.muted }, 100);
        }
        if (chosen.branch) |br| if (strip_w >= 420) {
            ui.text(c, "\u{00b7}", .{ .size = 11, .line_height = 15, .color = k.muted });
            kit.ellipsisText(c, br, .{ .size = 11, .line_height = 15, .color = k.muted }, 100);
        };
        ui.spacer(c);
        kit.kbdHint(c, k, "⌃Tab");
        ui.text(c, "Next", .{ .size = 10.5, .line_height = 14, .color = k.muted });
        kit.kbdHint(c, k, "Esc");
        ui.text(c, "Hide", .{ .size = 10.5, .line_height = 14, .color = k.muted });
    }

    if (picked) |ix| {
        if (tc.pane_mode) a.showPaneTab(ix) else {
            a.view.settings_open = false;
            a.showTab(ix);
        }
        hide(a);
        return;
    }
    const inside_tray = if (c.rects.get(c.node(tray.index).id)) |r| r.contains(c.input.mouse) else true;
    if (c.input.pressed and !inside_tray) hide(a);
}

fn overflowBadge(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const b = ui.div(c).px(6).py(3).rounded(6).bg(k.ink(0.06)).center();
    defer b.end();
    ui.text(c, label, .{ .size = 11, .line_height = 14, .weight = .semibold, .color = k.muted });
}
