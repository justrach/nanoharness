//! The line above the GitHub issue & PR list that counts the loaded page,
//! and the charts it folds away (remembered, folded by default): a state
//! split ring, By label / By author bars that filter the page, and a
//! recent-activity histogram. All from the loaded page, with no polling or
//! extra RPCs; colours from `github_display`'s one state mapping.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const flow = @import("app_github_repository.zig");
const behavior = @import("control_behavior.zig");
const icons = @import("icons.zig");
const display = @import("github_display.zig");

const max_groups = 5;
const max_days = 7;

const GroupRow = struct {
    name: []const u8,
    total: usize = 0,
    open: usize = 0,
    resolved: usize = 0,
};

const DayBucket = struct {
    date: []const u8,
    open: usize = 0,
    resolved: usize = 0,
};

const Stats = struct {
    total: usize = 0,
    open: usize = 0,
    draft: usize = 0,
    merged: usize = 0,
    closed: usize = 0,
    resolved: usize = 0,
    open_total: usize = 0,
    latest_number: u64 = 0,
    unique_authors: usize = 0,
    top_author: []const u8 = "",
    top_author_count: usize = 0,
    is_label_grouping: bool = false,
    groups: [max_groups]GroupRow = undefined,
    group_len: usize = 0,
    days: [max_days]DayBucket = undefined,
    day_len: usize = 0,
};

fn isOpenItem(item: flow.Item) bool {
    return std.mem.eql(u8, item.state, "open");
}

fn isResolvedItem(item: flow.Item) bool {
    return std.mem.eql(u8, item.state, "closed") or std.mem.eql(u8, item.state, "merged");
}

fn computeStats(arena: std.mem.Allocator, page: flow.Page) Stats {
    var s: Stats = .{ .total = page.items.len };
    var labeled_items: usize = 0;

    var author_list: std.ArrayList(GroupRow) = .empty;
    var label_list: std.ArrayList(GroupRow) = .empty;
    var day_list: std.ArrayList(DayBucket) = .empty;

    for (page.items) |item| {
        if (item.number > s.latest_number) s.latest_number = item.number;
        const open_item = isOpenItem(item);
        const resolved_item = isResolvedItem(item);
        if (open_item and item.isDraft) {
            s.draft += 1;
        } else if (open_item) {
            s.open += 1;
        } else if (std.mem.eql(u8, item.state, "merged")) {
            s.merged += 1;
        } else if (std.mem.eql(u8, item.state, "closed")) {
            s.closed += 1;
        }

        if (item.author.len > 0) addGroup(&author_list, arena, item.author, open_item, resolved_item);
        if (item.labels.len > 0) {
            labeled_items += 1;
            for (item.labels) |lbl| {
                if (lbl.len > 0) addGroup(&label_list, arena, lbl, open_item, resolved_item);
            }
        }
        if (item.updatedAt.len >= 10) {
            addDay(&day_list, arena, item.updatedAt[0..10], open_item, resolved_item);
        }
    }
    s.resolved = s.closed + s.merged;
    s.open_total = s.open + s.draft;
    s.unique_authors = author_list.items.len;

    sortGroupsDesc(author_list.items);
    if (author_list.items.len > 0) {
        s.top_author = author_list.items[0].name;
        s.top_author_count = author_list.items[0].total;
    }

    s.is_label_grouping = labeled_items >= 2 and label_list.items.len > 0;
    const chosen = if (s.is_label_grouping) label_list.items else author_list.items;
    if (s.is_label_grouping) sortGroupsDesc(chosen);
    s.group_len = @min(max_groups, chosen.len);
    for (0..s.group_len) |i| s.groups[i] = chosen[i];

    // Most recent distinct days (sorted descending to take latest max_days, then ascending left-to-right).
    std.mem.sortUnstable(DayBucket, day_list.items, {}, struct {
        fn less(_: void, a: DayBucket, b: DayBucket) bool {
            return std.mem.order(u8, a.date, b.date) == .gt;
        }
    }.less);
    const keep_days = @min(max_days, day_list.items.len);
    for (0..keep_days) |i| s.days[i] = day_list.items[keep_days - 1 - i];
    s.day_len = keep_days;

    return s;
}

fn addGroup(list: *std.ArrayList(GroupRow), arena: std.mem.Allocator, name: []const u8, open_item: bool, resolved_item: bool) void {
    for (list.items) |*g| {
        if (std.mem.eql(u8, g.name, name)) {
            g.total += 1;
            if (open_item) g.open += 1 else if (resolved_item) g.resolved += 1;
            return;
        }
    }
    list.append(arena, .{
        .name = name,
        .total = 1,
        .open = if (open_item) 1 else 0,
        .resolved = if (resolved_item) 1 else 0,
    }) catch {};
}

fn addDay(list: *std.ArrayList(DayBucket), arena: std.mem.Allocator, day: []const u8, open_item: bool, resolved_item: bool) void {
    for (list.items) |*d| {
        if (std.mem.eql(u8, d.date, day)) {
            if (open_item) d.open += 1 else if (resolved_item) d.resolved += 1;
            return;
        }
    }
    list.append(arena, .{
        .date = day,
        .open = if (open_item) 1 else 0,
        .resolved = if (resolved_item) 1 else 0,
    }) catch {};
}

fn sortGroupsDesc(items: []GroupRow) void {
    std.mem.sortUnstable(GroupRow, items, {}, struct {
        fn less(_: void, a: GroupRow, b: GroupRow) bool {
            if (a.total != b.total) return a.total > b.total;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
}

/// The summary line and the charts toggle; the charts when unfolded; the
/// page filter's banner while one is set. `width` is the list's inner width.
pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, width: f32, enabled: bool) void {
    if (page.items.len == 0) return;
    const s = &a.panels.github_repository;
    const expanded = a.settings.get(.github_charts_expanded);
    {
        ui.key(c, "github-summary-line");
        const bar = ui.div(c).row().wFull().h(kit.hit_target).gap(8).itemsCenter();
        defer bar.end();
        const buf = c.alloc().alloc(u8, 192) catch return;
        const line = display.summaryLine(buf, display.Counts.of(page.items), page.page, page.hasNextPage);
        const toggle = if (expanded) "Hide charts" else "Show charts";
        const toggle_w = 12 + 12 + 6 + c.text.width(toggle, .{ .size = kit.text_body, .weight = .medium });
        kit.ellipsisText(c, line, .{ .size = kit.text_body, .line_height = 16, .tabular = true, .color = k.muted }, @max(40, width - toggle_w - 8));
        ui.spacer(c);
        if (kit.actionButton(c, k, toggle, .{ .kind = .quiet, .trailing = if (expanded) .@"alt-arrow-down" else .@"alt-arrow-right", .key = "github-charts-toggle" })) {
            a.settings.toggle(.github_charts_expanded);
            a.redraw();
        }
    }
    if (expanded) {
        const stats = computeStats(c.alloc(), page);
        const charts = ui.div(c).column().wFull().pt(4).pb(8).gap(8);
        defer charts.end();
        drawAnalyticsGrid(c, a, k, stats, width, enabled);
    }
    if (flow.hasClientFilter(s)) drawFilterBanner(c, a, k, page, width, enabled);
}

fn drawAnalyticsGrid(c: *ui.Context, a: *App, k: theme.Colors, stats: Stats, inner_w: f32, enabled: bool) void {
    const show_days = stats.day_len >= 2;
    const gap: f32 = 8;

    if (inner_w >= 720 and show_days) {
        const donut_w: f32 = 188;
        const rem = inner_w - donut_w - 2 * gap;
        const group_w = @floor(rem * 0.56);
        const day_w = @max(120, rem - group_w);
        const row = ui.div(c).row().wFull().gap(gap).itemsStretch();
        defer row.end();
        drawStateCard(c, a, k, stats, donut_w, enabled);
        drawGroupsCard(c, a, k, stats, group_w, enabled);
        drawDaysCard(c, k, stats, day_w);
    } else if (inner_w >= 540) {
        const donut_w: f32 = 184;
        const group_w = @max(140, inner_w - donut_w - gap);
        {
            const row = ui.div(c).row().wFull().gap(gap).itemsStretch();
            defer row.end();
            drawStateCard(c, a, k, stats, donut_w, enabled);
            drawGroupsCard(c, a, k, stats, group_w, enabled);
        }
        if (show_days) drawDaysCard(c, k, stats, inner_w);
    } else {
        drawStateCard(c, a, k, stats, inner_w, enabled);
        drawGroupsCard(c, a, k, stats, inner_w, enabled);
        if (show_days) drawDaysCard(c, k, stats, inner_w);
    }
}

fn card(c: *ui.Context, k: theme.Colors, w: f32) ui.Div {
    return ui.div(c).column().w(w).p(12).gap(8).rounded(kit.radius_card).border(k.border).borderW(1).clip();
}

fn cardTitle(c: *ui.Context, k: theme.Colors, text: []const u8, room: f32) void {
    kit.ellipsisText(c, text, .{ .size = kit.text_body, .line_height = 16, .weight = .medium, .color = k.text }, room);
}

fn stateColor(k: theme.Colors, kind: display.Kind, state: display.State) ui.Color {
    return kit.roleColor(k, display.role(kind, state));
}

fn drawStateCard(c: *ui.Context, a: *App, k: theme.Colors, stats: Stats, card_w: f32, enabled: bool) void {
    const s = &a.panels.github_repository;
    const kind: display.Kind = if (s.list_kind == .pulls) .pull else .issue;
    const room = @max(60, card_w - 24);
    const box = card(c, k, card_w);
    defer box.end();
    cardTitle(c, k, "State split", room);

    // The ring: one arc per state, in the list's colours.
    {
        const gauge_row = ui.div(c).row().wFull().justifyCenter();
        defer gauge_row.end();
        const box_size: f32 = 82;
        const wrap = ui.div(c).size(box_size, box_size).clip();
        defer wrap.end();
        const cv = ui.canvas(c, .{ .width = .{ .px = box_size }, .height = .{ .px = box_size } });
        const center: ui.Point = .{ .x = box_size / 2, .y = box_size / 2 };
        const stroke_r: f32 = 31;
        const stroke_w: f32 = 8;
        cv.ring(center, stroke_r + stroke_w / 2, stroke_w, k.hover);
        if (stats.total > 0) {
            const total_f: f32 = @floatFromInt(stats.total);
            var start_frac: f32 = 0;
            const slices = [_]struct { usize, display.State }{ .{ stats.merged, .merged }, .{ stats.closed, .closed }, .{ stats.open, .open }, .{ stats.draft, .draft } };
            for (slices) |sl| {
                if (sl[0] > 0) {
                    const span: f32 = @as(f32, @floatFromInt(sl[0])) / total_f;
                    drawArcSlice(cv, c, center, stroke_r, stroke_w, start_frac, span, stateColor(k, kind, sl[1]));
                    start_frac += span;
                }
            }
        }
        const label_layer = ui.div(c).absolute().offset(0, 0).size(box_size, box_size).center().column();
        defer label_layer.end();
        const resolved_pct = if (stats.total > 0) (stats.resolved * 100) / stats.total else 0;
        ui.text(c, c.print("{d}%", .{resolved_pct}), .{ .size = kit.text_title, .weight = .medium, .tabular = true, .color = k.text });
        ui.text(c, if (kind == .pull) "merged or closed" else "closed", .{ .size = kit.text_caption, .color = k.muted });
    }

    // Legend rows filter the loaded page without a request.
    {
        const leg = ui.div(c).column().wFull();
        defer leg.end();
        const LegendEntry = struct { chip: flow.StateChip, state: display.State, a11y: []const u8, count: usize };
        const entries = [_]LegendEntry{
            .{ .chip = .open, .state = .open, .a11y = "Filter state: Open", .count = stats.open },
            .{ .chip = .draft, .state = .draft, .a11y = "Filter state: Draft", .count = stats.draft },
            .{ .chip = .merged, .state = .merged, .a11y = "Filter state: Merged", .count = stats.merged },
            .{ .chip = .closed, .state = .closed, .a11y = "Filter state: Closed", .count = stats.closed },
        };
        for (entries) |entry| {
            if (entry.count == 0) continue;
            ui.key(c, entry.a11y);
            const active = s.state_chip == entry.chip;
            var row = ui.div(c).row().wFull().h(kit.hit_target).px(6).gap(8).itemsCenter().rounded(kit.radius_control);
            if (active) row = row.bg(k.selected);
            if (enabled) row = kit.pressFeedback(row.hover(k.hover).control());
            defer row.end();
            const activated = behavior.activate(c, row, k, entry.a11y, enabled, active);
            kit.dot(c, 8, stateColor(k, kind, entry.state));
            kit.ellipsisText(c, display.label(entry.state), .{ .size = kit.text_body, .color = if (active) k.text else k.muted }, @max(24, room - 54));
            ui.spacer(c);
            ui.text(c, c.print("{d}", .{entry.count}), .{ .size = kit.text_body, .tabular = true, .weight = .medium, .color = k.text });
            if (activated) flow.toggleStateChip(a, entry.chip);
        }
    }
}

fn drawArcSlice(cv: *ui.Canvas, c: *ui.Context, center: ui.Point, r: f32, width: f32, start_frac: f32, span_frac: f32, color: ui.Color) void {
    const f = std.math.clamp(span_frac, 0, 1);
    if (f <= 0) return;
    const steps: usize = @intFromFloat(@max(3, @ceil(64 * f)));
    const points = c.alloc().alloc(ui.Point, steps + 1) catch return;
    const a0 = -std.math.pi / 2.0 + std.math.tau * start_frac;
    const da = std.math.tau * f;
    for (points, 0..) |*p, i| {
        const angle = a0 + da * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        p.* = .{ .x = center.x + r * @cos(angle), .y = center.y + r * @sin(angle) };
    }
    cv.polyline(points, .{ .width = width, .color = color });
}

/// Open in the open state's colour; merged or closed as quiet ink, since
/// a group mixes both.
fn openColor(k: theme.Colors) ui.Color {
    return kit.roleColor(k, display.role(.pull, .open));
}

fn doneColor(k: theme.Colors) ui.Color {
    return k.muted.alpha(0.55);
}

fn legend(c: *ui.Context, k: theme.Colors) void {
    const leg = ui.div(c).row().gap(8).itemsCenter();
    defer leg.end();
    miniDotLabel(c, k, openColor(k), "Open");
    miniDotLabel(c, k, doneColor(k), "Done");
}

fn drawGroupsCard(c: *ui.Context, a: *App, k: theme.Colors, stats: Stats, card_w: f32, enabled: bool) void {
    const s = &a.panels.github_repository;
    const room = @max(80, card_w - 24);
    const box = card(c, k, card_w);
    defer box.end();

    {
        const head = ui.div(c).row().wFull().gap(8).itemsCenter().clip();
        defer head.end();
        cardTitle(c, k, if (stats.is_label_grouping) "By label" else "By author", @max(40, room - 96));
        ui.spacer(c);
        if (room >= 180) legend(c, k);
    }

    var max_total: usize = 1;
    for (stats.groups[0..stats.group_len]) |g| {
        if (g.total > max_total) max_total = g.total;
    }
    const label_w = @min(108.0, @max(54.0, @floor(room * 0.34)));
    const count_w: f32 = 28;
    const bar_w = @max(28.0, room - label_w - count_w - 28);

    const list = ui.div(c).column().wFull();
    defer list.end();
    for (stats.groups[0..stats.group_len], 0..) |g, i| {
        ui.key(c, c.print("gh-group-{d}-{s}", .{ i, g.name }));
        const active = if (stats.is_label_grouping)
            (s.label_filter != null and std.mem.eql(u8, s.label_filter.?, g.name))
        else
            (s.author_filter != null and std.mem.eql(u8, s.author_filter.?, g.name));
        const a11y = c.print("Filter {s}: {s}", .{ if (stats.is_label_grouping) "label" else "author", g.name });
        var row = ui.div(c).row().wFull().h(kit.hit_target).px(6).gap(8).itemsCenter().rounded(kit.radius_control).clip();
        if (active) row = row.bg(k.selected);
        if (enabled) row = kit.pressFeedback(row.hover(k.hover).control());
        defer row.end();
        const activated = behavior.activate(c, row, k, a11y, enabled, active);

        const lbl_box = ui.div(c).row().w(label_w).clip();
        kit.ellipsisText(c, g.name, .{ .size = kit.text_body, .weight = .medium, .color = if (active) k.text else k.muted }, label_w);
        lbl_box.end();

        const track = ui.div(c).row().w(bar_w).h(8).rounded(4).bg(k.hover).clip();
        {
            defer track.end();
            const denom: f32 = @floatFromInt(max_total);
            const open_w = @floor(bar_w * @as(f32, @floatFromInt(g.open)) / denom);
            const res_w = @floor(bar_w * @as(f32, @floatFromInt(g.resolved)) / denom);
            if (g.open > 0) _ = c.leaf(.{ .width = .{ .px = @max(3, open_w) }, .height = .fill, .background = openColor(k) }, .none, null);
            if (g.resolved > 0) _ = c.leaf(.{ .width = .{ .px = @max(3, res_w) }, .height = .fill, .background = doneColor(k) }, .none, null);
        }

        const cnt_box = ui.div(c).row().w(count_w).justifyEnd().clip();
        kit.ellipsisText(c, c.print("{d}", .{g.total}), .{ .size = kit.text_body, .tabular = true, .color = k.muted }, count_w);
        cnt_box.end();

        if (activated) {
            if (stats.is_label_grouping) flow.toggleLabelFilter(a, g.name) else flow.toggleAuthorFilter(a, g.name);
        }
    }
}

fn drawDaysCard(c: *ui.Context, k: theme.Colors, stats: Stats, card_w: f32) void {
    const room = @max(80, card_w - 24);
    const box = card(c, k, card_w);
    defer box.end();

    {
        const head = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
        defer head.end();
        cardTitle(c, k, "Recent activity", @max(40, room - 96));
        ui.spacer(c);
        if (room >= 180) legend(c, k);
    }

    var max_day: usize = 1;
    for (stats.days[0..stats.day_len]) |d| {
        const top = @max(d.open, d.resolved);
        if (top > max_day) max_day = top;
    }

    const n = stats.day_len;
    const gap: f32 = 4;
    const col_w = @max(14, @floor((room - gap * @as(f32, @floatFromInt(n - 1))) / @as(f32, @floatFromInt(n))));
    const bar_w = std.math.clamp(@floor((col_w - 4) / 2), 4.0, 10.0);
    const max_bar_h: f32 = 64;

    const plot = ui.div(c).row().wFull().pt(4).gap(gap).itemsEnd().justifyCenter();
    defer plot.end();
    for (stats.days[0..n]) |d| {
        const col = ui.div(c).column().w(col_w).gap(4).itemsCenter().clip();
        defer col.end();
        {
            const bars = ui.div(c).row().w(col_w).h(max_bar_h).gap(2).justifyCenter().itemsEnd();
            defer bars.end();
            const denom: f32 = @floatFromInt(max_day);
            if (d.open > 0) {
                const h = @max(4, @round(max_bar_h * @as(f32, @floatFromInt(d.open)) / denom));
                _ = c.leaf(.{ .width = .{ .px = bar_w }, .height = .{ .px = h }, .radius = 2, .background = openColor(k) }, .none, null);
            }
            if (d.resolved > 0) {
                const h = @max(4, @round(max_bar_h * @as(f32, @floatFromInt(d.resolved)) / denom));
                _ = c.leaf(.{ .width = .{ .px = bar_w }, .height = .{ .px = h }, .radius = 2, .background = doneColor(k) }, .none, null);
            }
            if (d.open == 0 and d.resolved == 0) {
                _ = c.leaf(.{ .width = .{ .px = bar_w }, .height = .{ .px = 2 }, .radius = 1, .background = k.hover }, .none, null);
            }
        }
        kit.ellipsisText(c, d.date[5..10], .{ .size = kit.text_caption, .tabular = true, .color = k.muted }, col_w);
    }
}

fn miniDotLabel(c: *ui.Context, k: theme.Colors, color: ui.Color, label: []const u8) void {
    const item = ui.div(c).row().gap(4).itemsCenter();
    defer item.end();
    kit.dot(c, 6, color);
    ui.text(c, label, .{ .size = kit.text_caption, .color = k.muted });
}

fn drawFilterBanner(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, inner_w: f32, enabled: bool) void {
    const s = &a.panels.github_repository;
    var shown: usize = 0;
    for (page.items) |item| {
        if (flow.itemMatchesFilter(s, item)) shown += 1;
    }
    const colors = kit.chipColors(k, .accent);
    const bar = ui.div(c).row().wFull().pl(12).pr(4).gap(8).itemsCenter().rounded(kit.radius_card).bg(colors.fill).clip();
    defer bar.end();

    icons.icon(c, .tuning, 12, colors.ink, 0);
    const desc = describeFilter(c, s, shown, page.items.len);
    kit.ellipsisText(c, desc, .{ .size = kit.text_body, .tabular = true, .color = k.text }, @max(40, inner_w - 128));
    ui.spacer(c);
    if (kit.actionButton(c, k, "Clear filter", .{ .kind = .quiet, .enabled = enabled, .key = "clear-github-overview-filter" })) flow.clearClientFilters(a);
}

fn describeFilter(c: *ui.Context, s: *const flow.State, shown: usize, total: usize) []const u8 {
    const state_part = switch (s.state_chip) {
        .all => "",
        .open => "state: open",
        .closed => "state: closed",
        .merged => "state: merged",
        .draft => "state: draft",
    };
    if (s.label_filter) |lbl| {
        return if (state_part.len > 0)
            c.print("Showing {d} of {d} ({s} · {s})", .{ shown, total, state_part, lbl })
        else
            c.print("Showing {d} of {d} (label: {s})", .{ shown, total, lbl });
    }
    if (s.author_filter) |au| {
        return if (state_part.len > 0)
            c.print("Showing {d} of {d} ({s} · @{s})", .{ shown, total, state_part, au })
        else
            c.print("Showing {d} of {d} (@{s})", .{ shown, total, au });
    }
    return c.print("Showing {d} of {d} ({s})", .{ shown, total, state_part });
}
