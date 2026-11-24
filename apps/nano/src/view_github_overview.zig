//! Editorial analytics dashboard above the GitHub issue & PR list:
//! KPI strip, canvas State Split donut ring, clickable By Label / By Contributor
//! stacked bars, and Recent Activity date histogram — rendered strictly from
//! the loaded repository page with zero background polling or extra RPCs.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const flow = @import("app_github_repository.zig");
const behavior = @import("control_behavior.zig");
const icons = @import("icons.zig");

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

fn cardBg(k: theme.Colors) ui.Color {
    return k.ink(if (k.dark) 0.028 else 0.018);
}

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, width: f32, enabled: bool) void {
    if (page.items.len == 0) return;
    const stats = computeStats(c.alloc(), page);
    const s = &a.panels.github_repository;
    const has_filter = flow.hasClientFilter(s);

    // Narrow panes (<340px) or single-item pages stay a compact 1-row pill strip so
    // the first item title and metadata never get pushed off small viewports.
    if (width < 340 or page.items.len < 2) {
        drawCompactStrip(c, a, k, page, stats, width, has_filter, enabled);
        return;
    }

    const inner_w = @max(120, width - 28);
    drawKpiGrid(c, k, page, stats, inner_w);
    drawAnalyticsGrid(c, a, k, stats, inner_w, enabled);
    if (has_filter) drawFilterBanner(c, a, k, page, inner_w, enabled);
}

fn drawCompactStrip(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, stats: Stats, width: f32, has_filter: bool, enabled: bool) void {
    const inner_w = @max(80, width - 28);
    const strip = ui.div(c).row().wFull().px(10).py(6).gap(7).itemsCenter().rounded(8).bg(cardBg(k)).border(k.border).borderW(1).clip();
    defer strip.end();
    const dot_color = if (stats.open_total > 0 and stats.resolved == 0) k.warning else k.success;
    _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = dot_color }, .none, null);
    const word = if (stats.merged > 0) "merged" else "closed";
    const summary = c.print("{d}{s} shown · {d} open · {d} {s}", .{
        stats.total,
        if (page.hasNextPage) "+" else "",
        stats.open_total,
        stats.resolved,
        word,
    });
    const text_w = @max(24, inner_w - (if (has_filter) @as(f32, 82) else 32));
    kit.ellipsisText(c, summary, .{ .size = 11, .mono = true, .color = k.muted }, text_w);
    if (has_filter) {
        ui.spacer(c);
        if (miniClearButton(c, k, enabled)) flow.clearClientFilters(a);
    }
}

fn drawKpiGrid(c: *ui.Context, k: theme.Colors, page: flow.Page, stats: Stats, inner_w: f32) void {
    const is_pull = page.kind == .pulls;
    const cols: usize = if (inner_w >= 552) 4 else 2;
    const gap: f32 = 8;
    const card_w = @floor((inner_w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols)));

    const Metric = struct { label: []const u8, value: []const u8, sub: []const u8, color: ui.Color };
    const open_pct = if (stats.total > 0) (stats.open_total * 100) / stats.total else 0;
    const resolved_pct = if (stats.total > 0) (stats.resolved * 100) / stats.total else 0;
    const open_sub = if (stats.draft > 0) c.print("{d} draft · {d}%", .{ stats.draft, open_pct }) else c.print("{d}% of page", .{open_pct});
    const resolved_sub = if (is_pull and stats.merged > 0) c.print("{d} merged · {d} closed", .{ stats.merged, stats.closed }) else c.print("{d}% resolved", .{resolved_pct});
    const contrib_sub = if (stats.top_author.len > 0) c.print("top: {s} ({d})", .{ stats.top_author, stats.top_author_count }) else "no author";

    const cards = [4]Metric{
        .{
            .label = "On This Page",
            .value = c.print("{d}{s}", .{ stats.total, if (page.hasNextPage) "+" else "" }),
            .sub = c.print("Page {d} · latest #{d}", .{ page.page, stats.latest_number }),
            .color = k.text,
        },
        .{
            .label = "Open",
            .value = c.print("{d}", .{stats.open_total}),
            .sub = open_sub,
            .color = k.warning,
        },
        .{
            .label = if (is_pull) "Merged / Closed" else "Closed",
            .value = c.print("{d}", .{stats.resolved}),
            .sub = resolved_sub,
            .color = k.success,
        },
        .{
            .label = "Contributors",
            .value = c.print("{d}", .{stats.unique_authors}),
            .sub = contrib_sub,
            .color = k.accent,
        },
    };

    const grid = ui.div(c).column().wFull().gap(gap);
    defer grid.end();
    var idx: usize = 0;
    while (idx < 4) : (idx += cols) {
        const row = ui.div(c).row().wFull().gap(gap);
        defer row.end();
        for (0..cols) |col_i| {
            const m = cards[idx + col_i];
            const card = ui.div(c).column().w(card_w).p(11).gap(3).rounded(10).bg(cardBg(k)).border(k.border).borderW(1).clip();
            defer card.end();
            const room = @max(24, card_w - 22);
            kit.ellipsisText(c, m.label, .{ .size = 11, .color = k.muted }, room);
            kit.ellipsisText(c, m.value, .{ .size = 20, .line_height = 24, .weight = .bold, .tabular = true, .color = m.color }, room);
            kit.ellipsisText(c, m.sub, .{ .size = 10.5, .mono = true, .color = k.faint }, room);
        }
    }
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

fn drawStateCard(c: *ui.Context, a: *App, k: theme.Colors, stats: Stats, card_w: f32, enabled: bool) void {
    const s = &a.panels.github_repository;
    const room = @max(60, card_w - 24);
    const card = ui.div(c).column().w(card_w).p(12).gap(10).rounded(10).bg(cardBg(k)).border(k.border).borderW(1).clip();
    defer card.end();

    {
        const head = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
        defer head.end();
        kit.ellipsisText(c, "State Split", .{ .size = 12, .weight = .semibold, .color = k.text }, room - 42);
        ui.spacer(c);
        if (room >= 145) ui.text(c, "Click", .{ .size = 10.5, .color = k.faint });
    }

    // Donut ring gauge centered cleanly inside card width
    {
        const gauge_row = ui.div(c).row().wFull().justifyCenter();
        defer gauge_row.end();
        const box_size: f32 = 82;
        const wrap = ui.div(c).size(box_size, box_size).clip();
        defer wrap.end();
        const cv = ui.canvas(c, .{ .width = .{ .px = box_size }, .height = .{ .px = box_size } });
        const center: ui.Point = .{ .x = box_size / 2, .y = box_size / 2 };
        const stroke_r: f32 = 31;
        const stroke_w: f32 = 8.5;
        cv.ring(center, stroke_r + stroke_w / 2, stroke_w, k.ink(if (k.dark) 0.08 else 0.06));
        if (stats.total > 0) {
            const total_f: f32 = @floatFromInt(stats.total);
            var start_frac: f32 = 0;
            const slices = .{
                .{ stats.resolved, k.success },
                .{ stats.open, k.warning },
                .{ stats.draft, k.muted },
            };
            inline for (slices) |sl| {
                if (sl[0] > 0) {
                    const span: f32 = @as(f32, @floatFromInt(sl[0])) / total_f;
                    drawArcSlice(cv, c, center, stroke_r, stroke_w, start_frac, span, sl[1]);
                    start_frac += span;
                }
            }
        }
        const label_layer = ui.div(c).absolute().offset(0, 0).size(box_size, box_size).center().column();
        defer label_layer.end();
        const resolved_pct = if (stats.total > 0) (stats.resolved * 100) / stats.total else 0;
        ui.text(c, c.print("{d}%", .{resolved_pct}), .{ .size = 14, .weight = .bold, .tabular = true, .color = k.text });
        ui.text(c, "resolved", .{ .size = 9.5, .color = k.faint });
    }

    // Clickable legend items filtering locally without RPCs
    {
        const leg = ui.div(c).column().wFull().gap(4);
        defer leg.end();
        const LegendEntry = struct {
            chip: flow.StateChip,
            label: []const u8,
            a11y: []const u8,
            count: usize,
            color: ui.Color,
        };
        const entries = [_]LegendEntry{
            .{ .chip = .open, .label = "Open", .a11y = "Filter state: Open", .count = stats.open, .color = k.warning },
            .{ .chip = .merged, .label = "Merged", .a11y = "Filter state: Merged", .count = stats.merged, .color = k.accent },
            .{ .chip = .closed, .label = "Closed", .a11y = "Filter state: Closed", .count = stats.closed, .color = k.success },
            .{ .chip = .draft, .label = "Draft", .a11y = "Filter state: Draft", .count = stats.draft, .color = k.muted },
        };
        for (entries) |entry| {
            if (entry.count == 0) continue;
            ui.key(c, entry.a11y);
            const active = s.state_chip == entry.chip;
            const row_bg = if (active) entry.color.alpha(0.14) else ui.Color.transparent;
            const row = ui.div(c).row().wFull().px(6).py(3).gap(7).itemsCenter().rounded(6)
                .bg(row_bg)
                .border(if (active) entry.color.alpha(0.45) else ui.Color.transparent).borderW(1);
            if (enabled) _ = row.hover(k.hover).control();
            defer row.end();
            const activated = behavior.activate(c, row, k, entry.a11y, enabled, active);
            _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = entry.color }, .none, null);
            kit.ellipsisText(c, entry.label, .{ .size = 11.5, .color = if (active) k.text else k.muted }, @max(24, room - 54));
            ui.spacer(c);
            ui.text(c, c.print("{d}", .{entry.count}), .{ .size = 11.5, .mono = true, .weight = .semibold, .color = k.text });
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

fn drawGroupsCard(c: *ui.Context, a: *App, k: theme.Colors, stats: Stats, card_w: f32, enabled: bool) void {
    const s = &a.panels.github_repository;
    const room = @max(80, card_w - 24);
    const card = ui.div(c).column().w(card_w).p(12).gap(8).rounded(10).bg(cardBg(k)).border(k.border).borderW(1).clip();
    defer card.end();

    {
        const head = ui.div(c).row().wFull().gap(8).itemsCenter().clip();
        defer head.end();
        const title = if (stats.is_label_grouping) "By Label" else "By Contributor";
        kit.ellipsisText(c, title, .{ .size = 12, .weight = .semibold, .color = k.text }, @max(40, room - 74));
        ui.spacer(c);
        if (room >= 200) ui.text(c, "Click to filter", .{ .size = 10.5, .color = k.faint });
    }

    var max_total: usize = 1;
    for (stats.groups[0..stats.group_len]) |g| {
        if (g.total > max_total) max_total = g.total;
    }
    const label_w = @min(108.0, @max(54.0, @floor(room * 0.34)));
    const count_w: f32 = 44;
    const bar_w = @max(28.0, room - label_w - count_w - 20);

    const list = ui.div(c).column().wFull().gap(4);
    defer list.end();
    for (stats.groups[0..stats.group_len], 0..) |g, i| {
        ui.key(c, c.print("gh-group-{d}-{s}", .{ i, g.name }));
        const active = if (stats.is_label_grouping)
            (s.label_filter != null and std.mem.eql(u8, s.label_filter.?, g.name))
        else
            (s.author_filter != null and std.mem.eql(u8, s.author_filter.?, g.name));
        const a11y = c.print("Filter {s}: {s}", .{ if (stats.is_label_grouping) "label" else "author", g.name });
        const row = ui.div(c).row().wFull().px(4).py(4).gap(6).itemsCenter().rounded(6)
            .bg(if (active) k.accent.alpha(0.11) else ui.Color.transparent)
            .border(if (active) k.accent.alpha(0.42) else ui.Color.transparent).borderW(1).clip();
        if (enabled) _ = row.hover(k.hover).control();
        defer row.end();
        const activated = behavior.activate(c, row, k, a11y, enabled, active);

        const lbl_box = ui.div(c).row().w(label_w).clip();
        kit.ellipsisText(c, g.name, .{ .size = 11.5, .weight = if (active) .semibold else .medium, .color = if (active) k.accent else k.text }, label_w);
        lbl_box.end();

        const track = ui.div(c).row().w(bar_w).h(10).rounded(4).bg(k.ink(if (k.dark) 0.06 else 0.05)).clip();
        {
            defer track.end();
            const denom: f32 = @floatFromInt(max_total);
            const res_w = @floor(bar_w * @as(f32, @floatFromInt(g.resolved)) / denom);
            const open_w = @floor(bar_w * @as(f32, @floatFromInt(g.open)) / denom);
            if (g.resolved > 0) {
                _ = c.leaf(.{ .width = .{ .px = @max(3, res_w) }, .height = .fill, .radius = 3, .background = k.success }, .none, null);
            }
            if (g.open > 0) {
                _ = c.leaf(.{ .width = .{ .px = @max(3, open_w) }, .height = .fill, .radius = 3, .background = k.warning }, .none, null);
            }
        }

        const cnt_box = ui.div(c).row().w(count_w).justifyEnd().clip();
        kit.ellipsisText(c, c.print("{d}/{d}", .{ g.resolved, g.total }), .{ .size = 11, .mono = true, .color = k.muted }, count_w);
        cnt_box.end();

        if (activated) {
            if (stats.is_label_grouping) flow.toggleLabelFilter(a, g.name) else flow.toggleAuthorFilter(a, g.name);
        }
    }
}

fn drawDaysCard(c: *ui.Context, k: theme.Colors, stats: Stats, card_w: f32) void {
    const room = @max(80, card_w - 24);
    const card = ui.div(c).column().w(card_w).p(12).gap(10).rounded(10).bg(cardBg(k)).border(k.border).borderW(1).clip();
    defer card.end();

    {
        const head = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
        defer head.end();
        kit.ellipsisText(c, "Recent Activity", .{ .size = 12, .weight = .semibold, .color = k.text }, @max(40, room - 88));
        ui.spacer(c);
        if (room >= 165) {
            const leg = ui.div(c).row().gap(8).itemsCenter();
            defer leg.end();
            miniDotLabel(c, k, k.warning, "Open");
            miniDotLabel(c, k, k.success, "Closed");
        }
    }

    var max_day: usize = 1;
    for (stats.days[0..stats.day_len]) |d| {
        const top = @max(d.open, d.resolved);
        if (top > max_day) max_day = top;
    }

    const n = stats.day_len;
    const gap: f32 = 5;
    const col_w = @max(14, @floor((room - gap * @as(f32, @floatFromInt(n - 1))) / @as(f32, @floatFromInt(n))));
    const bar_w = std.math.clamp(@floor((col_w - 4) / 2), 4.0, 11.0);
    const max_bar_h: f32 = 72;

    const plot = ui.div(c).row().wFull().pt(4).gap(gap).itemsEnd().justifyCenter();
    defer plot.end();
    for (stats.days[0..n]) |d| {
        const col = ui.div(c).column().w(col_w).gap(5).itemsCenter().clip();
        defer col.end();
        {
            const bars = ui.div(c).row().w(col_w).h(max_bar_h).gap(2).justifyCenter().itemsEnd();
            defer bars.end();
            const denom: f32 = @floatFromInt(max_day);
            if (d.open > 0) {
                const h = @max(5, @round(max_bar_h * @as(f32, @floatFromInt(d.open)) / denom));
                _ = c.leaf(.{ .width = .{ .px = bar_w }, .height = .{ .px = h }, .radius = 2.5, .background = k.warning }, .none, null);
            }
            if (d.resolved > 0) {
                const h = @max(5, @round(max_bar_h * @as(f32, @floatFromInt(d.resolved)) / denom));
                _ = c.leaf(.{ .width = .{ .px = bar_w }, .height = .{ .px = h }, .radius = 2.5, .background = k.success }, .none, null);
            }
            if (d.open == 0 and d.resolved == 0) {
                _ = c.leaf(.{ .width = .{ .px = bar_w }, .height = .{ .px = 3 }, .radius = 1.5, .background = k.ink(0.08) }, .none, null);
            }
        }
        kit.ellipsisText(c, d.date[5..10], .{ .size = 9.5, .mono = true, .color = k.faint }, col_w);
    }
}

fn miniDotLabel(c: *ui.Context, k: theme.Colors, color: ui.Color, label: []const u8) void {
    const item = ui.div(c).row().gap(4).itemsCenter();
    defer item.end();
    _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = color }, .none, null);
    ui.text(c, label, .{ .size = 10, .color = k.muted });
}

fn drawFilterBanner(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, inner_w: f32, enabled: bool) void {
    const s = &a.panels.github_repository;
    var shown: usize = 0;
    for (page.items) |item| {
        if (flow.itemMatchesFilter(s, item)) shown += 1;
    }
    const bar = ui.div(c).row().wFull().px(10).py(6).gap(8).itemsCenter().rounded(8)
        .bg(k.accent.alpha(if (k.dark) 0.10 else 0.08))
        .border(k.accent.alpha(0.32)).borderW(1).clip();
    defer bar.end();

    icons.icon(c, .tuning, 12, k.accent, 0);
    const desc = describeFilter(c, s, shown, page.items.len);
    kit.ellipsisText(c, desc, .{ .size = 11.5, .color = k.text }, @max(40, inner_w - 118));
    ui.spacer(c);
    if (miniClearButton(c, k, enabled)) flow.clearClientFilters(a);
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

fn miniClearButton(c: *ui.Context, k: theme.Colors, enabled: bool) bool {
    ui.key(c, "clear-github-overview-filter");
    const b = ui.div(c).row().h(22).px(8).itemsCenter().rounded(6)
        .bg(k.ink(if (k.dark) 0.06 else 0.045)).border(k.border).borderW(1);
    if (enabled) _ = b.hover(k.hover).control();
    defer b.end();
    const activated = behavior.activate(c, b, k, "Clear filter", enabled, false);
    ui.text(c, "Clear filter", .{ .size = 11, .weight = .medium, .color = if (enabled) k.text else k.faint });
    return activated;
}
