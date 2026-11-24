//! Painting for the unified lane; geometry and mutations live separately.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const chrome = @import("panel_chrome.zig");
const tabs = @import("tabs.zig");
const strip = @import("view_tab_strip.zig");
const tip = @import("view_tooltip.zig");
const caption = @import("window_chrome.zig");
const panel_chrome = @import("view_panel_chrome.zig");

const light_tab_shadow = [_]ui.Shadow{
    .{ .color = .{ .a = 0.08 }, .y = 1, .blur = 2.5 },
};
const dark_tab_shadow = [_]ui.Shadow{
    .{ .color = .{ .a = 0.30 }, .y = 1, .blur = 3.0 },
};

pub const TabVisual = struct {
    bg: ui.Color,
    border: ?ui.Color,
    shadows: []const ui.Shadow,
    fg: ui.Color,
    icon: ui.Color,
    weight: ui.Weight,
};

pub fn tabStyle(k: theme.Colors, active: bool, hovered: bool) TabVisual {
    if (active) {
        const bg = if (!k.dark)
            (if (k.frosted) ui.Color.white.alpha(0.86) else panel_chrome.zenPageBg(k))
        else
            (if (k.frosted) ui.Color.white.alpha(0.14) else @import("themes.zig").over(k.shell.alpha(1), k.text.alpha(0.12)));
        return .{
            .bg = bg,
            .border = k.ink(if (k.dark) 0.16 else 0.14),
            .shadows = if (k.dark) &dark_tab_shadow else &light_tab_shadow,
            .fg = k.text,
            .icon = k.text,
            .weight = .medium,
        };
    }
    return .{
        .bg = .transparent,
        .border = null,
        .shadows = &.{},
        .fg = if (hovered) k.text else k.muted,
        .icon = if (hovered) k.text else k.muted,
        .weight = .regular,
    };
}

fn applyTabBox(div: ui.Div, k: theme.Colors, vis: TabVisual, active: bool) ui.Div {
    var box = div.bg(vis.bg);
    if (vis.border) |b| box = box.border(b).borderW(1);
    if (vis.shadows.len > 0) box = box.shadows(vis.shadows);
    if (!active) box = box.hover(k.hover);
    return box;
}

pub const Layout = struct {
    targets: [tabs.max_panes + 2]strip.Panel = undefined,
    widths: [tabs.max_panes + 2]f32 = undefined,
    count: usize = 0,
    left: f32,
    right: f32 = 0,
    columns: bool = false,
    pane_row: bool = false,
};

pub fn showSidePanelToggle(a: *const App) bool {
    return !a.view.settings_open and (strip.hasHost(a) or a.panels.tabs.items.len > 0);
}

pub fn trailingModeButtonsWidth(a: *const App) f32 {
    if (a.view.settings_open) return 0;
    const vu = @import("view_updates.zig");
    const ux_m = @import("ux_rules.zig").UiMode3;
    const mode: ux_m.UiMode = switch (a.settings.uiMode()) {
        .zen => .zen,
        .developer => .developer,
        .design => .design,
    };
    const policy = ux_m.profileOf(mode);
    const tm = vu.trailingMetrics(a);
    const eff_cnt = ux_m.effectiveTrailingCount(mode, false, tm.avail, tm.last_slot);
    if (policy.shows_dev_trailing_toggles and eff_cnt >= 3) return 28 + 6 + 28;
    if (policy.shows_design_canvas_toggle and eff_cnt >= 2) return 28;
    return 0;
}

pub fn utilityWidth(a: *const App) f32 {
    const widths = [_]f32{
        if (@import("view_sandbox_strip.zig").toolbarVisible(a)) @import("view_sandbox_strip.zig").toolbar_width else 0,
        @import("view_updates.zig").topbarUpdatesWidth(a),
        trailingModeButtonsWidth(a),
        if (showSidePanelToggle(a)) 28 else 0,
    };
    var total: f32 = 0;
    for (widths) |w| if (w > 0) {
        total += w + (if (total > 0) @as(f32, 6) else 0);
    };
    return total;
}

fn trailingReserve(a: *const App) f32 {
    const width = utilityWidth(a);
    return if (width > 0) width + 10 else 0;
}

pub fn layout(c: *ui.Context, a: *const App) Layout {
    const left = @max(strip.leftInset(a), a.view.chrome.leading);
    if (a.view.settings_open or strip.count(a) <= 1) return .{ .left = left };
    const ws_gutter = chrome.zen_gutter;
    var targets: [tabs.max_panes + 2]strip.Panel = undefined;
    var widths: [tabs.max_panes + 2]f32 = undefined;
    var n: usize = 0;
    const split = a.tabs.layout();
    const github = @import("app_github_repository.zig");
    const child_parent = if (strip.hasHost(a) and github.surface(a)) github.parentPane(a) else null;
    for (0..strip.chatCount(a)) |ix| {
        // In the temporary focused layout keep its source and child tabs
        // together; the other panes return when the window has room again.
        if (a.view.chrome.compact_host and a.view.strip.expanded == null and child_parent != null and ix != child_parent.?) continue;
        targets[n] = .{ .chat = ix };
        widths[n] = if (split) |s| chrome.paneSpanIn(a.view.chrome.chat_width, s.shares.items[ix], s.panes.items.len, true, ws_gutter) else a.view.chrome.chat_width;
        n += 1;
        if (child_parent != null and child_parent.? == ix) {
            targets[n] = .host;
            widths[n] = a.view.chrome.host_width;
            n += 1;
        }
    }
    if (strip.hasHost(a) and child_parent == null) {
        targets[n] = .host;
        widths[n] = a.view.chrome.host_width;
        n += 1;
    }
    if (strip.hasFiles(a)) {
        targets[n] = .files;
        widths[n] = a.view.chrome.files_width;
        n += 1;
    }
    const right = caption.trailing + trailingReserve(a);
    const in_row = (if (split) |s| s.axis == .horizontal and !s.zoomed else true) and strip.layoutExpanded(a) == null;
    var aligned: [tabs.max_panes + 2]f32 = undefined;
    const columns = in_row and a.view.chrome.width <= c.size.w - a.view.chrome.x + 0.5 and
        chrome.columns(widths[0..n], a.view.chrome.leading, left, 8 + right, &aligned);
    return .{
        .targets = targets,
        .widths = widths,
        .count = n,
        .left = left,
        .right = right,
        .columns = columns,
        // Horizontal splits always have a pane row, even on wide windows.
        // Opening a utility must not move the pane headers between rows.
        .pane_row = in_row and (if (split) |s| s.panes.items.len > 1 else false),
    };
}

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, lane: Layout, pane_widths: *const [tabs.max_panes]?f32) void {
    if (a.view.settings_open) {
        if (a.settings.uiMode() == .zen) single(c, a, k, lane.left);
        return;
    }
    if (!strip.hasHost(a)) a.view.strip.host_tab_rect = null;
    if (lane.count == 0) return single(c, a, k, lane.left);
    const n = lane.count;
    const columns = lane.columns and !lane.pane_row;
    const left = lane.left;
    const ws_gutter = chrome.zen_gutter;
    var widths = lane.widths;
    for (lane.targets[0..n], 0..) |target, ix| {
        if (target == .chat) widths[ix] = pane_widths[target.chat] orelse widths[ix];
    }
    var aligned: [tabs.max_panes + 2]f32 = undefined;
    if (columns) _ = chrome.columns(widths[0..n], a.view.chrome.leading, left, 8 + lane.right, &aligned);
    const other_tabs: usize = if (a.tabs.items.items.len > 1) a.tabs.items.items.len - 1 else 0;
    const avail_bar = @max(0, c.size.w - a.view.sidebar_width - left - lane.right - 8 - 32);
    const max_other_budget = if (columns)
        @max(0, @min(aligned[0] * 0.55, aligned[0] - 180))
    else if (lane.pane_row)
        @max(0, avail_bar - 164)
    else
        avail_bar * 0.38;
    const other_shown: usize = if (other_tabs > 0 and max_other_budget >= 76) @min(other_tabs, @as(usize, @intFromFloat(@max(1, @floor(max_other_budget / 76))))) else 0;
    const other_pill_w: f32 = if (other_shown > 0) @min(128, @max(72, max_other_budget / @as(f32, @floatFromInt(other_shown)) - 4)) else 0;
    const other_reserve: f32 = if (other_shown > 0) @as(f32, @floatFromInt(other_shown)) * (other_pill_w + 4) else 0;
    if (lane.pane_row) {
        {
            ui.key(c, "instrument-strip");
            const row = ui.div(c).fixed().offset(a.view.chrome.x, chrome.header_height)
                .size(a.view.chrome.width, chrome.tab_height).row().gap(ws_gutter).itemsCenter().layer(2);
            defer row.end();
            for (lane.targets[0..n], widths[0..n], 0..) |target, width, ix| slot(c, a, k, target, ix, width);
        }
        ui.key(c, "instrument-workspaces");
        const ws_avail = @max(0, c.size.w - a.view.sidebar_width - left - lane.right - 8);
        const ws_n = a.tabs.items.items.len;
        const active_ws = a.tabs.active;
        const ws_win = singleWindow(ws_avail, ws_n, active_ws, 27);
        const actions = ui.div(c).fixed().offset(a.view.sidebar_width + left, 0)
            .size(ws_avail, chrome.tab_height + chrome.tab_top)
            .pt(chrome.top_pad).row().gap(3).itemsCenter().layer(2);
        defer actions.end();
        for (ws_win.win_start..ws_win.win_end) |ws| {
            if (ws == active_ws) {
                ui.key(c, c.print("top-workspace-tab-{d}", .{ws}));
                const vis = tabStyle(k, true, false);
                const split_lbl = c.print("Split · {d} panes", .{strip.chatCount(a)});
                const pill_w: f32 = if (ws_n == 1)
                    @min(ws_win.slot_w, @max(120, c.text.width(split_lbl, .{ .size = 11.5, .weight = vis.weight }) + 38))
                else
                    ws_win.slot_w;
                var current = ui.div(c).row().size(pill_w, 28).px(8).gap(6).itemsCenter().rounded(8).clip().control();
                current = applyTabBox(current, k, vis, true);
                defer current.end();
                icons.icon(c, .widget, 14, vis.icon, 0);
                kit.ellipsisText(c, split_lbl, .{ .size = 11.5, .line_height = 14, .weight = vis.weight, .color = vis.fg }, @max(0, pill_w - 36));
            } else {
                topWorkspacePill(c, a, k, ws, ws_win.slot_w);
            }
        }
        if (ws_win.hidden_count > 0) {
            ui.key(c, "split-workspace-overflow");
            var more = ui.div(c).row().size(overflow_pill_w, 28).center().rounded(8)
                .bg(k.ink(if (k.dark) 0.06 else 0.04)).hover(k.hover).control();
            more = tip.on(more, k, .{ .text = c.print("{d} more open tab{s}", .{ ws_win.hidden_count, if (ws_win.hidden_count == 1) "" else "s" }), .look = .tab });
            defer more.end();
            ui.text(c, c.print("+{d}", .{ws_win.hidden_count}), .{ .size = 11, .weight = .medium, .color = k.muted });
            if (more.clicked()) strip.open(a, .history, strip.active(a), c.rects.get(c.node(more.index).id));
        }
        if (ws_avail >= 27) newTab(c, a, k);
        return;
    }
    const shared = @min(chrome.slot_max, chrome.sharedSlotRoom(@max(0, c.size.w - a.view.sidebar_width - other_reserve - lane.right), left, 8, n));
    ui.key(c, "instrument-strip");
    const row = ui.div(c).fixed().offset(a.view.sidebar_width, 0).w(c.size.w - a.view.sidebar_width - lane.right).h(chrome.titlebar_height).pt(chrome.top_pad).pl(left).pr(8).row().gap(if (columns) ws_gutter else 4).itemsCenter().layer(2);
    defer row.end();
    for (lane.targets[0..n], 0..) |target, ix| {
        if (columns and ix == 0 and other_shown > 0) {
            ui.key(c, "instrument-col-0");
            const col0 = ui.div(c).row().size(aligned[0], chrome.tab_height).gap(4).itemsCenter();
            defer col0.end();
            slot(c, a, k, target, ix, @max(0, aligned[0] - other_reserve));
            otherWorkspaces(c, a, k, other_shown, other_pill_w);
        } else {
            slot(c, a, k, target, ix, @max(0, if (columns) aligned[ix] else shared));
        }
    }
    if (!columns) otherWorkspaces(c, a, k, other_shown, other_pill_w);
    newTab(c, a, k);
}

fn otherWorkspaces(c: *ui.Context, a: *App, k: theme.Colors, count: usize, width: f32) void {
    if (count == 0) return;
    var rendered: usize = 0;
    for (0..a.tabs.items.items.len) |ws| {
        if (ws == a.tabs.active) continue;
        topWorkspacePill(c, a, k, ws, width);
        rendered += 1;
        if (rendered == count) break;
    }
}

fn newTab(c: *ui.Context, a: *App, k: theme.Colors) void {
    ui.key(c, "instrument-new-tab");
    if (kit.iconButton(c, k, .plus, .{ .icon = 14, .label = "New tab" })) a.newTab();
}

fn chatNeedsInput(a: *const App, id: ?[]const u8) bool {
    return if (id) |chat| @import("app_question.zig").needsInput(a, chat) else false;
}

fn workspaceNeedsInput(a: *const App, ws: usize) bool {
    if (chatNeedsInput(a, workspaceChatId(a, ws))) return true;
    if (ws < a.tabs.splits.items.len) if (a.tabs.splits.items[ws]) |s| {
        for (s.panes.items) |id| if (chatNeedsInput(a, id)) return true;
        for (&s.groups) |*g| for (g.items.items) |tab| if (chatNeedsInput(a, tab.chat)) return true;
    };
    return false;
}

fn questionMark(c: *ui.Context, k: theme.Colors, pending: bool) bool {
    if (!pending) return false;
    ui.key(c, "tab-question-attention");
    const badge = ui.div(c).size(14, 14).center().rounded(5).bg(k.warning.alpha(0.15));
    defer badge.end();
    ui.text(c, "?", .{ .size = 11, .weight = .semibold, .color = k.warning });
    return true;
}

pub fn workspaceChatId(a: *const App, ws: usize) ?[]const u8 {
    const primary = if (ws == a.tabs.active) a.selected else a.tabs.items.items[ws];
    if (primary != null) return primary;
    if (ws < a.tabs.splits.items.len) if (a.tabs.splits.items[ws]) |s| {
        for (s.panes.items) |p| if (p) |cid| return cid;
        for (&s.groups) |*g| for (g.items.items) |pt| if (pt.chat) |cid| return cid;
    };
    return null;
}

fn workspacePaneCount(a: *const App, ws: usize) usize {
    if (ws < a.tabs.splits.items.len) if (a.tabs.splits.items[ws]) |s| return @max(1, s.panes.items.len);
    return 1;
}

fn topWorkspacePill(c: *ui.Context, a: *App, k: theme.Colors, ws: usize, pill_w: f32) void {
    ui.key(c, c.print("top-workspace-tab-{d}", .{ws}));
    const cid = workspaceChatId(a, ws);
    const ch = if (cid) |id| a.findChat(id) else null;
    const t_name = if (ch) |v| @import("view_sidebar.zig").chatLabel(v) else "New tab";
    const panes_n = workspacePaneCount(a, ws);
    var pill = ui.div(c).row().size(pill_w, 28).px(8).gap(6).itemsCenter().rounded(8).clip().control();
    pill = applyTabBox(pill, k, tabStyle(k, false, false), false);
    defer pill.end();
    const pill_hot = pill.hovered();
    const vis = tabStyle(k, false, pill_hot);
    const hover_rules = @import("ux_rules.zig").HoverStability;
    const pill_wu: u32 = @intFromFloat(@round(@max(0, pill_w)));
    const reserve_close = hover_rules.tabControlsReserve(pill_wu, false, true);
    const label_budget: f32 = @floatFromInt(hover_rules.tabLabelWidth(pill_wu, false, pill_hot, true) -| 16);
    if (!questionMark(c, k, workspaceNeedsInput(a, ws))) icons.icon(c, if (panes_n > 1) .widget else .@"chat-round-line", 13, vis.icon, 0);
    kit.ellipsisText(c, t_name, .{ .size = 11.5, .line_height = 14, .weight = vis.weight, .color = vis.fg }, label_budget);
    var closed = false;
    if (reserve_close > 0) {
        const spacer = ui.div(c).row().grow();
        spacer.end();
        const op: f32 = @as(f32, @floatFromInt(hover_rules.tabCloseGlyphOpacityPct(false, pill_hot, true))) / 100.0;
        const close_wrap = ui.div(c).row().size(16, 16).center().opacity(op);
        defer close_wrap.end();
        if (kit.iconButton(c, k, .close, .{ .size = 16, .radius = 4, .icon = 10, .tip = if (pill_hot) .{ .text = "Close tab" } else null }) and pill_hot) {
            closed = true;
            strip.queue(a, .{ .close_global_tab = ws });
        }
    }
    if (!closed and pill.clicked()) strip.queue(a, .{ .global_tab = ws });
}

fn slot(c: *ui.Context, a: *App, k: theme.Colors, target: strip.Panel, ix: usize, width: f32) void {
    if (target == .host and @import("app_github_repository.zig").surface(a)) {
        // A narrower centered cap leaves room for both outward shoulders
        // as the child tab flows into its wider reading surface.
        const lane = ui.div(c).row().size(width, chrome.tab_height).center();
        defer lane.end();
        slotBox(c, a, k, target, ix, @max(0, @min(chrome.slot_max, width - 2 * chrome.shoulder)), false);
        return;
    }
    if (target == .chat) {
        if (a.tabs.layout()) |s| {
            const pane = target.chat;
            const g = &s.groups[pane];
            const tab_n = g.count();
            if (tab_n > 1) {
                const inactive_n: f32 = @floatFromInt(tab_n - 1);
                const min_active_w: f32 = 148;
                const min_inactive_w: f32 = 72;
                if (width >= min_active_w + inactive_n * (min_inactive_w + 3)) {
                    ui.key(c, c.print("instrument-slot-group-{d}", .{ix}));
                    const group_row = ui.div(c).row().size(width, chrome.tab_height).gap(3).itemsCenter().clip();
                    defer group_row.end();
                    const group_hot = group_row.hovered();
                    const max_inactive = (width - min_active_w) / inactive_n - 3;
                    const inactive_w = @min(132, @min(max_inactive, @max(min_inactive_w, (width - 3 * inactive_n) * 0.34 / inactive_n)));
                    const active_w = @max(min_active_w, width - inactive_n * (inactive_w + 3));
                    for (0..tab_n) |t_ix| {
                        if (t_ix == g.active) {
                            slotBox(c, a, k, target, ix, active_w, group_hot);
                        } else {
                            inactiveTabPill(c, a, k, ix, pane, t_ix, g.items.items[t_ix].chat, inactive_w);
                        }
                    }
                    return;
                }
            }
        }
    }
    slotBox(c, a, k, target, ix, width, false);
}

fn inactiveTabPill(c: *ui.Context, a: *App, k: theme.Colors, slot_ix: usize, pane: usize, tab_ix: usize, chat_id: ?[]const u8, pill_w: f32) void {
    ui.key(c, c.print("instrument-slot-{d}-tab-{d}", .{ slot_ix, tab_ix }));
    const ch = if (chat_id) |cid| a.findChat(cid) else null;
    const t_name = if (ch) |v| @import("view_sidebar.zig").chatLabel(v) else "New tab";
    var pill = ui.div(c).row().size(pill_w, chrome.tab_height).px(7).gap(5).itemsCenter().rounded(6).clip().control();
    pill = applyTabBox(pill, k, tabStyle(k, false, false), false);
    defer pill.end();
    const pill_hot = pill.hovered();
    const vis = tabStyle(k, false, pill_hot);
    const hover_rules = @import("ux_rules.zig").HoverStability;
    const pill_wu: u32 = @intFromFloat(@round(@max(0, pill_w)));
    const reserve_close = hover_rules.tabControlsReserve(pill_wu, false, true);
    const label_budget: f32 = @floatFromInt(hover_rules.tabLabelWidth(pill_wu, false, pill_hot, true) -| 16);
    if (!questionMark(c, k, chatNeedsInput(a, chat_id))) icons.icon(c, .@"chat-round-line", 13, vis.icon, 0);
    kit.ellipsisText(c, t_name, .{ .size = 11.5, .line_height = 14, .weight = vis.weight, .color = vis.fg }, label_budget);
    var pill_closed = false;
    if (reserve_close > 0) {
        const spacer = ui.div(c).row().grow();
        spacer.end();
        const op: f32 = @as(f32, @floatFromInt(hover_rules.tabCloseGlyphOpacityPct(false, pill_hot, true))) / 100.0;
        const close_wrap = ui.div(c).row().size(16, 16).center().opacity(op);
        defer close_wrap.end();
        if (kit.iconButton(c, k, .close, .{ .size = 16, .radius = 4, .icon = 10, .tip = if (pill_hot) .{ .text = "Close tab" } else null }) and pill_hot) {
            pill_closed = true;
            strip.queue(a, .{ .close_panel_tab = .{ .pane = pane, .tab = tab_ix } });
        }
    }
    if (!pill_closed and pill.clicked()) {
        strip.queue(a, .{ .panel_tab = .{ .pane = pane, .tab = tab_ix } });
    }
}

fn slotBox(c: *ui.Context, a: *App, k: theme.Colors, target: strip.Panel, ix: usize, width: f32, group_hot: bool) void {
    ui.key(c, c.print("instrument-slot-{d}", .{ix}));
    const on = strip.same(strip.active(a), target);
    const name = strip.title(a, target);
    const github_child = target == .host and @import("app_github_repository.zig").surface(a);
    const computer = if (github_child) c.print("↳ {s}", .{@import("app_github_repository.zig").ownerTitle(a)}) else strip.deviceLabel(a, strip.device(a, target));
    const project = strip.folder(a, target);
    var box = ui.div(c).row().size(width, chrome.tab_height).pl(7).pr(4).gap(6).itemsCenter().rounded(6).clip().control();
    if (github_child and on) {
        box = box.bg(k.background);
    } else {
        box = applyTabBox(box, k, tabStyle(k, on, false), on);
    }
    if (github_child) {
        const measured = c.rects.get(c.node(box.index).id);
        if (!std.meta.eql(measured, a.view.strip.host_tab_rect)) {
            a.view.strip.host_tab_rect = measured;
            // The body is drawn before the strip. Give its contour the new
            // cap bounds after a resize instead of leaving a stale shoulder.
            c.animationFrame();
        }
    }
    defer box.end();
    if (strip.same(strip.active(a), target)) {
        if (c.rects.get(c.node(box.index).id)) |r| a.view.strip.active_tab_anchor = r;
    }
    const hot = box.hovered() or group_hot;
    const vis = tabStyle(k, on, hot);
    const show_controls = hot or c.focus == c.node(box.index).id;
    const menu_count = strip.tabCount(a, target);
    var handled = false;
    if (questionMark(c, k, if (target == .chat) chatNeedsInput(a, strip.chatId(a, target.chat)) else false)) {
        // The question remains dormant; this badge never requests focus.
    } else if (strip.attention(a, target, k)) |color| {
        const mark = ui.div(c).row().size(14, 14).center();
        defer mark.end();
        ui.div(c).size(7, 7).rounded(3.5).bg(color).end();
    } else icons.icon(c, strip.glyph(a, target), 14, if (github_child) k.accent else vis.icon, 0);
    {
        const text = ui.div(c).column().grow().w(0).clip();
        defer text.end();
        const room = @import("motion_rules.zig").slotTextRoom(width, show_controls, if (target == .chat) 1 else menu_count);
        kit.ellipsisText(c, name, .{ .size = 12, .line_height = 14, .weight = vis.weight, .color = vis.fg }, room);
        const meta = ui.div(c).row().h(14).wFull().gap(6).itemsCenter().clip();
        defer meta.end();
        const device_editable = target == .chat;
        const chip_st: ui.TextStyle = .{ .size = 10, .line_height = 12, .color = k.muted };
        const dev_text_w = c.text.width(computer, chip_st);
        const pick_text_w: ?f32 = if (project) |f| c.text.width(f.name, chip_st) else null;
        const pick_changeable = if (project) |f| f.changeable else false;
        const chips = @import("motion_rules.zig").slotChipWidths(room, dev_text_w, device_editable, pick_text_w, pick_changeable);
        if (chips.dev_w > 0) {
            const dev_glyph_only = chips.dev_text_max <= 0;
            ui.key(c, "slot-device");
            var dev = ui.div(c).row().w(chips.dev_w).h(14).gap(3).itemsCenter().rounded(3).clip();
            if (device_editable) dev = dev.px(3).hover(k.ink(0.10)).control();
            if (dev_glyph_only or dev_text_w > chips.dev_text_max) dev = tip.on(dev, k, .{ .text = computer, .look = .tab });
            defer dev.end();
            const dev_rect = c.rects.get(c.node(dev.index).id) orelse c.rects.get(c.node(box.index).id);
            if (device_editable and a.view.strip.menu == .device and strip.same(a.view.strip.target, target)) {
                if (dev_rect) |r| a.view.strip.device_anchor = r;
            }
            icons.icon(c, if (github_child) .@"split-columns" else .monitor, 10, k.muted, 0);
            if (!dev_glyph_only) {
                kit.ellipsisText(c, computer, chip_st, chips.dev_text_max);
            }
            if (device_editable) {
                if (!dev_glyph_only) icons.icon(c, .@"alt-arrow-down", 9, k.muted, 0);
                if (dev.clicked()) {
                    handled = true;
                    const state = &a.view.strip;
                    if (state.menu == .device and strip.same(state.target, target)) {
                        state.menu = null;
                    } else {
                        strip.queue(a, .{ .focus = target });
                        strip.open(a, .device, target, dev_rect);
                    }
                }
            }
        }
        if (project) |f| if (chips.pick_w > 0) {
            const pick_glyph_only = chips.pick_text_max <= 0;
            ui.key(c, "slot-folder");
            var pick = ui.div(c).row().w(chips.pick_w).h(14).gap(3).itemsCenter().rounded(3).clip();
            if (f.changeable) pick = pick.px(3).hover(k.ink(0.10)).control();
            if (pick_glyph_only or (pick_text_w orelse 0) > chips.pick_text_max) pick = tip.on(pick, k, .{ .text = f.name, .look = .tab });
            defer pick.end();
            const pick_rect = c.rects.get(c.node(pick.index).id) orelse c.rects.get(c.node(box.index).id);
            if (f.changeable and strip.same(strip.active(a), target)) {
                if (pick_rect) |r| a.view.strip.active_folder_anchor = r;
            }
            if (f.changeable and a.view.strip.menu == .folder and !a.view.strip.footer_folder and strip.same(a.view.strip.target, target)) {
                if (pick_rect) |r| a.view.strip.anchor = r;
            }
            icons.icon(c, .folder, 10, k.muted, 0);
            if (!pick_glyph_only) {
                kit.ellipsisText(c, f.name, chip_st, chips.pick_text_max);
            }
            if (f.changeable) {
                if (!pick_glyph_only) icons.icon(c, .@"alt-arrow-down", 9, k.muted, 0);
                strip.offerSplitFolder(c, a, target, c.rects.get(c.node(pick.index).id));
                if (pick.clicked()) {
                    handled = true;
                    const state = &a.view.strip;
                    if (state.menu == .folder and !state.footer_folder and strip.same(state.target, target)) {
                        state.menu = null;
                    } else {
                        // Focus is queued; the menu's rows read the target's draft.
                        strip.queue(a, .{ .focus = target });
                        strip.open(a, .folder, target, pick_rect);
                    }
                }
            }
        };
    }
    if (show_controls and width >= 220) {
        ui.key(c, "slot-add");
        if (kit.iconButton(c, k, .plus, .{ .size = 18, .radius = 4, .icon = 11, .tip = .{ .text = if (target == .chat) "New tab" else "New surface" } })) {
            handled = true;
            if (target == .chat) a.newTab() else strip.queue(a, .{ .new = target });
        }
    }
    if ((target != .chat and menu_count > 1) or show_controls) {
        ui.key(c, "slot-menu");
        const button = ui.div(c).row().h(18).minW(18).px(3).gap(2).center().rounded(4).hover(k.ink(0.10)).control();
        defer button.end();
        if (target != .chat and menu_count > 1) ui.text(c, c.print("{d}", .{menu_count}), .{ .size = 11, .color = k.muted });
        icons.icon(c, .@"alt-arrow-down", 11, k.muted, 0);
        if (button.clicked()) {
            handled = true;
            const state = &a.view.strip;
            if (state.menu == .panel and strip.same(state.target, target)) {
                state.menu = null;
            } else {
                strip.open(a, .panel, target, c.rects.get(c.node(button.index).id) orelse c.rects.get(c.node(box.index).id));
            }
        }
    }
    if (show_controls and width >= chrome.slot_room_for_close) {
        ui.key(c, "slot-close");
        if (kit.iconButton(c, k, .close, .{ .size = 18, .radius = 4, .icon = 11, .tip = .{ .text = "Close tab" } })) {
            handled = true;
            switch (target) {
                .chat => |pane| strip.queue(a, .{ .close_panel_tab = .{ .pane = pane, .tab = if (a.tabs.layout()) |s| s.groups[pane].active else 0 } }),
                .host => if (a.panels.active < a.panels.tabs.items.len) strip.queue(a, .{ .close_host_tab = a.panels.active }) else strip.queue(a, .{ .close = .host }),
                .files => strip.queue(a, .{ .close = .files }),
            }
        }
    }
    if (!handled and box.clicked()) strip.queue(a, .{ .focus = target });
    if (kit.secondaryClicked(box)) strip.open(a, .panel, target, c.rects.get(c.node(box.index).id));
}

fn showDevicePicker(a: *const App) bool {
    if (a.settings.uiMode() == .zen and a.devices.items.len <= 1) return false;
    return true;
}

pub const Selected = struct { left: f32, right: f32 };

pub const overflow_pill_w: f32 = 34;

/// Shared pure geometry for the single-panel tab window (`single` and `selectedBounds`).
pub const TabWindow = struct {
    slot_w: f32,
    win_start: usize,
    win_end: usize,
    hidden_count: usize,
    selected_left: f32,
    selected_right: f32,
};

pub fn singleWindow(available: f32, n: usize, selected: usize, add_room: f32) TabWindow {
    if (n == 0) return .{
        .slot_w = 0,
        .win_start = 0,
        .win_end = 0,
        .hidden_count = 0,
        .selected_left = 0,
        .selected_right = 0,
    };
    const gap: f32 = 3;
    const min_w: f32 = 112;
    const max_w: f32 = 240;
    const fit_budget = @max(0, available - add_room);
    const min_needed = @as(f32, @floatFromInt(n)) * min_w + @as(f32, @floatFromInt(n -| 1)) * gap;
    const overflowing = n > 1 and min_needed > fit_budget;
    const visible_budget = @max(0, fit_budget - (if (overflowing) overflow_pill_w + gap else 0));
    const visible_count: usize = if (!overflowing)
        n
    else
        @max(@as(usize, 1), @min(n, @as(usize, @intFromFloat(@floor((visible_budget + gap) / (min_w + gap))))));
    const clamped_sel = @min(selected, n - 1);
    const win_start: usize = if (clamped_sel < visible_count) 0 else @min(n - visible_count, clamped_sel + 1 - visible_count);
    const win_end: usize = @min(n, win_start + visible_count);
    const hidden_count: usize = n -| (win_end - win_start);
    const slot_w: f32 = if (visible_count == 1)
        @min(max_w, @max(48, @floor(visible_budget)))
    else
        std.math.clamp(
            @floor((visible_budget - @as(f32, @floatFromInt(visible_count - 1)) * gap) / @as(f32, @floatFromInt(visible_count))),
            min_w,
            max_w,
        );
    const rel_ix = clamped_sel -| win_start;
    const sel_left = @as(f32, @floatFromInt(rel_ix)) * (slot_w + gap);
    return .{
        .slot_w = slot_w,
        .win_start = win_start,
        .win_end = win_end,
        .hidden_count = hidden_count,
        .selected_left = sel_left,
        .selected_right = sel_left + slot_w,
    };
}

pub const SingleItem = union(enum) {
    global: usize,
    panel: struct { pane: usize, tab: usize },
};

pub const SingleSpec = struct {
    n: usize,
    selected: usize,
    active_ws: usize,
    pane: usize,
    group_len: usize,
    group_active: usize,

    pub fn itemAt(spec: SingleSpec, ix: usize) SingleItem {
        if (spec.group_len <= 1) return .{ .global = ix };
        if (ix < spec.active_ws) return .{ .global = ix };
        if (ix < spec.active_ws + spec.group_len) {
            return .{ .panel = .{ .pane = spec.pane, .tab = ix - spec.active_ws } };
        }
        return .{ .global = ix - (spec.group_len - 1) };
    }
};

pub fn singleSpec(a: *const App) SingleSpec {
    const ws_n = a.tabs.items.items.len;
    const active_ws = a.tabs.active;
    if (a.tabs.layout()) |s| {
        const g = &s.groups[s.focus];
        if (g.count() > 1) {
            return .{
                .n = ws_n + g.count() - 1,
                .selected = active_ws + g.active,
                .active_ws = active_ws,
                .pane = s.focus,
                .group_len = g.count(),
                .group_active = g.active,
            };
        }
    }
    return .{
        .n = ws_n,
        .selected = active_ws,
        .active_ws = active_ws,
        .pane = 0,
        .group_len = 0,
        .group_active = 0,
    };
}

pub fn singleItemChat(a: *const App, spec: SingleSpec, ix: usize) ?[]const u8 {
    return switch (spec.itemAt(ix)) {
        .global => |ws| workspaceChatId(a, ws),
        .panel => |pt| if (ix == spec.selected) a.selected else a.tabs.layout().?.groups[pt.pane].items.items[pt.tab].chat,
    };
}

pub fn selectedBounds(a: *const App) ?Selected {
    if (a.settings.uiMode() == .zen) return null;
    if (a.view.settings_open) return null;
    if (strip.count(a) != 1) return null;
    const spec = singleSpec(a);
    const n = spec.n;
    if (n == 0) return null;
    const selected = spec.selected;
    const left = @max(strip.leftInset(a), a.view.chrome.leading);
    const dev_room: f32 = if (showDevicePicker(a)) chrome.device_room else 0;
    const right_extra = trailingReserve(a);
    const available = @max(0, a.view.chrome.width - left - dev_room - caption.trailing - right_extra - 4);
    const win = singleWindow(available, n, selected, 27);
    const lane_offset = left - a.view.chrome.leading;
    const start = lane_offset + win.selected_left;
    const end = lane_offset + win.selected_right;
    return .{ .left = @max(0, start), .right = @min(a.view.chrome.width, end) };
}

fn zenTabStartX(a: *const App) f32 {
    const open_x = @max(a.settings.sidebarWidth() + chrome.zen_gutter / 2.0, caption.leading + 24 + 14);
    const updates: f32 = if (!a.view.settings_open and @import("view_updates.zig").titlebarVisible(a)) 26 else 0;
    const closed_x = caption.leading + 24 + (if (a.view.settings_open) @as(f32, 0) else 56) + updates + 14;
    const t = std.math.clamp(a.view.sidebar_width / @max(1, a.settings.sidebarWidth()), 0, 1);
    return closed_x + (open_x - closed_x) * t;
}

fn single(c: *ui.Context, a: *App, k: theme.Colors, left: f32) void {
    const zen = a.settings.uiMode() == .zen;
    const settings_open = a.view.settings_open;
    const show_dev = !settings_open and showDevicePicker(a);
    const dev_room: f32 = if (show_dev) chrome.device_room else 0;
    const right_extra = trailingReserve(a);
    const spec = singleSpec(a);
    const n = spec.n;
    const selected = spec.selected;
    const lane_x = if (zen) zenTabStartX(a) else a.view.sidebar_width + left;
    const available = if (zen)
        @max(0, c.size.w - lane_x - dev_room - caption.trailing - right_extra - 12)
    else
        @max(0, a.view.chrome.width - left - dev_room - caption.trailing - right_extra - 4);
    const show_add = !settings_open and (!zen or n > 1);
    const add_room: f32 = if (show_add) 27 else 0;
    const win = singleWindow(available, n, selected, add_room);
    const win_start = win.win_start;
    const win_end = win.win_end;
    const hidden_count = win.hidden_count;
    const slot_w = win.slot_w;
    if (zen and n == 1) {
        const only_chat = singleItemChat(a, spec, 0);
        if (only_chat == null) {
            if (show_dev) devicePicker(c, a, k);
            return;
        }
    }
    ui.key(c, "panel-tabs");
    const lane = ui.div(c).fixed().offset(lane_x, chrome.tab_top).size(available, chrome.tab_height + chrome.tab_top).clip().layer(2);
    defer lane.end();
    const row = ui.div(c).absolute().offset(0, 0).row().h(chrome.tab_height).gap(3).itemsCenter();
    defer row.end();
    for (win_start..win_end) |ix| {
        const item = spec.itemAt(ix);
        const chat = singleItemChat(a, spec, ix);
        const panes_n = switch (item) {
            .global => |ws| workspacePaneCount(a, ws),
            .panel => @as(usize, 1),
        };
        const ch = if (chat) |id| a.findChat(id) else null;
        const label = if (ch) |v| @import("view_sidebar.zig").chatLabel(v) else "New tab";
        const pill_w: f32 = if (zen and n == 1)
            @min(slot_w, @max(140, c.text.width(label, .{ .size = 12.5, .weight = .medium }) + 58))
        else
            slot_w;
        ui.key(c, c.print("panel-tab-{d}", .{ix}));
        const active = ix == selected;
        var cap = ui.div(c).row().size(pill_w, if (zen) @as(f32, 28) else 30).px(8).gap(6).itemsCenter().rounded(7).clip().control();
        cap = applyTabBox(cap, k, tabStyle(k, active, false), active);
        defer cap.end();
        if (active) {
            if (c.rects.get(c.node(cap.index).id)) |r| a.view.strip.active_tab_anchor = r;
        }
        const hot = cap.hovered();
        const vis = tabStyle(k, active, hot);
        const pending_question = switch (item) {
            .global => |ws| workspaceNeedsInput(a, ws),
            .panel => chatNeedsInput(a, chat),
        };
        const show_close = !settings_open and (hot or (n > 1 and active));
        const show_spacer = !show_close and !zen;
        const has_trailing = show_close or show_spacer;
        const show_monogram = !pending_question and zen and panes_n == 1 and ch != null;
        const lead_w: f32 = if (show_monogram) 16 else 14;
        const split_badge_text: ?[]const u8 = if (zen and panes_n > 1) c.print("{d}", .{panes_n}) else null;
        const split_badge_w: f32 = if (split_badge_text) |txt| @max(16, @ceil(c.text.width(txt, .{ .size = 10, .weight = .medium })) + 8) else 0;
        const trail_w: f32 = (if (split_badge_w > 0) 6 + split_badge_w else 0) + (if (has_trailing) @as(f32, 22) else 0);
        const label_w: f32 = @max(0, pill_w - (16 + lead_w + 6 + trail_w));
        if (!questionMark(c, k, pending_question)) {
            if (show_monogram) {
                @import("view_sidebar.zig").zenMonogram(c, a, k, ch.?, 16);
            } else {
                icons.icon(c, if (panes_n > 1) .widget else .@"chat-round-line", 14, vis.icon, 0);
            }
        }
        {
            const labels = ui.div(c).column().grow().w(0).clip();
            defer labels.end();
            if (zen) {
                kit.ellipsisText(c, label, .{ .size = 12.5, .line_height = 16, .weight = vis.weight, .color = vis.fg }, label_w);
            } else {
                kit.ellipsisText(c, label, .{ .size = 12, .line_height = 14, .weight = vis.weight, .color = vis.fg }, label_w);
                if (panes_n > 1) {
                    const meta = ui.div(c).row().gap(6).h(12).itemsCenter();
                    defer meta.end();
                    kit.ellipsisText(c, c.print("{d} split panes", .{panes_n}), .{ .size = 10, .line_height = 12, .color = k.muted }, label_w);
                } else if (ch) |chat_row| {
                    const meta = ui.div(c).row().gap(6).h(12).itemsCenter();
                    defer meta.end();
                    if (chat_row.branch) |branch| kit.ellipsisText(c, branch, .{ .size = 10, .line_height = 12, .color = k.muted }, @max(0, label_w * 0.45));
                    const mark = icons.harnessMark(chat_row.harness orelse "graff");
                    icons.icon(c, mark.name, 12, mark.brand orelse k.muted, 0);
                    kit.ellipsisText(c, chat_row.model orelse chat_row.harness orelse "Graff", .{ .size = 10, .line_height = 12, .color = k.muted }, @max(0, label_w * 0.5 - 15));
                }
            }
        }
        if (split_badge_text) |txt| {
            var badge = ui.div(c).row().size(split_badge_w, 16).center().rounded(4)
                .bg(k.ink(if (k.dark) (if (active) 0.12 else 0.08) else (if (active) 0.08 else 0.06)));
            badge = tip.on(badge, k, .{ .text = c.print("{d} split panes", .{panes_n}), .look = .tab });
            defer badge.end();
            ui.text(c, txt, .{ .size = 10, .line_height = 12, .weight = .medium, .color = if (active) k.text else k.muted });
        }
        var handled = false;
        if (show_close) {
            if (kit.iconButton(c, k, .close, .{ .size = 16, .radius = 4, .icon = 11, .tip = .{ .text = "Close tab" } })) {
                handled = true;
                switch (item) {
                    .panel => |pt| strip.queue(a, .{ .close_panel_tab = .{ .pane = pt.pane, .tab = pt.tab } }),
                    .global => |ws| strip.queue(a, .{ .close_global_tab = ws }),
                }
            }
        } else if (show_spacer) ui.div(c).size(16, 16).end();
        if (!handled and cap.clicked() and (settings_open or ix != selected)) {
            if (settings_open) @import("view_settings.zig").close(a);
            if (ix != selected) switch (item) {
                .panel => |pt| strip.queue(a, .{ .panel_tab = .{ .pane = pt.pane, .tab = pt.tab } }),
                .global => |ws| strip.queue(a, .{ .global_tab = ws }),
            };
        }
        if (kit.secondaryClicked(cap)) strip.open(a, .panel, .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 }, c.rects.get(c.node(cap.index).id));
    }
    if (hidden_count > 0) {
        ui.key(c, "panel-tabs-overflow");
        var more = ui.div(c).row().size(overflow_pill_w, if (zen) @as(f32, 28) else 26).center().rounded(if (zen) @as(f32, 7) else 6)
            .bg(k.ink(if (k.dark) 0.06 else 0.04)).hover(k.hover).control();
        more = @import("view_tooltip.zig").on(more, k, .{ .text = c.print("{d} more open tab{s}", .{ hidden_count, if (hidden_count == 1) "" else "s" }), .look = .tab });
        defer more.end();
        ui.text(c, c.print("+{d}", .{hidden_count}), .{ .size = 11, .weight = .medium, .color = k.muted });
        if (more.clicked()) strip.open(a, .history, .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 }, c.rects.get(c.node(more.index).id));
    }
    if (show_add) {
        ui.key(c, "panel-add-tab");
        if (kit.iconButton(c, k, .plus, .{ .icon = 14, .label = "New tab" })) a.newTab();
    }
    // Device is its own fixed trailing lane, never a tab's suffix.
    if (show_dev) devicePicker(c, a, k);
}

fn devicePicker(c: *ui.Context, a: *App, k: theme.Colors) void {
    const target = strip.active(a);
    const editable = target == .chat;
    const right_extra = trailingReserve(a);
    const lane = ui.div(c).fixed().offset(c.size.w - caption.trailing - right_extra - chrome.device_room - 12, chrome.tab_top).size(chrome.device_room, chrome.tab_height).pl(8).row().itemsCenter().justifyEnd().layer(3);
    defer lane.end();
    ui.key(c, "panel-device-trigger");
    var box = ui.div(c).row().h(18).px(if (editable) 4 else 0).gap(3).itemsCenter().rounded(4).clip();
    if (editable) box = box.hover(k.ink(0.10)).control();
    defer box.end();
    // Once a menu opens, retain the anchor of the control actually clicked
    // (the draft footer also offers this picker).
    if (editable and a.view.strip.menu != .device) {
        if (c.rects.get(c.node(box.index).id)) |r| a.view.strip.device_anchor = r;
    }
    icons.icon(c, .monitor, 10, k.muted, 0);
    kit.ellipsisText(c, strip.deviceLabel(a, strip.device(a, target)), .{ .size = 10, .line_height = 12, .color = k.muted }, chrome.device_room - 21 - (if (editable) @as(f32, 17) else 0));
    if (editable) {
        icons.icon(c, .@"alt-arrow-down", 9, k.muted, 0);
        if (box.clicked()) {
            const state = &a.view.strip;
            if (state.menu == .device and strip.same(state.target, target)) {
                state.menu = null;
            } else {
                strip.queue(a, .{ .focus = target });
                strip.open(a, .device, target, c.rects.get(c.node(box.index).id));
            }
        }
    }
}
