//! Settings › Usage: local tokens by model and runtime. This page never
//! calls provider APIs or syncs usage.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Phase = enum { idle, loading, ready, failed };
const sending: u64 = std.math.maxInt(u64);

pub const Row = struct {
    runtime: []const u8,
    model: []const u8,
    input: u64,
    output: u64,
};

pub const Page = struct {
    phase: Phase = .idle,
    call: ?u64 = null,
    arena: ?std.heap.ArenaAllocator = null,
    period_start: []const u8 = "",
    as_of: []const u8 = "",
    rows: []Row = &.{},
    partial: bool = false,
    show_all: bool = false,
    error_text: []const u8 = "",

    pub fn deinit(p: *Page, gpa: Allocator) void {
        _ = gpa;
        p.clear();
    }

    fn clear(p: *Page) void {
        if (p.arena) |*arena| arena.deinit();
        p.arena = null;
        p.rows = &.{};
        p.period_start = "";
        p.as_of = "";
        p.error_text = "";
        p.partial = false;
    }
};

fn parseNumber(value: ?json.Value) ?u64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .number_string => |n| std.fmt.parseInt(u64, n, 10) catch null,
        else => null,
    };
}

fn parse(a: *App, page: *Page, value: json.Value) bool {
    if (value != .object) return false;
    const obj = value.object;
    const rows_value = obj.get("rows") orelse return false;
    if (rows_value != .array) return false;
    page.clear();
    page.arena = .init(a.gpa);
    const allocator = page.arena.?.allocator();
    const rows = allocator.alloc(Row, rows_value.array.items.len) catch return false;
    var n: usize = 0;
    for (rows_value.array.items) |item| {
        if (item != .object) continue;
        const fields = item.object;
        const runtime = fields.get("runtime") orelse continue;
        const model = fields.get("model") orelse continue;
        if (runtime != .string or model != .string) continue;
        const input = parseNumber(fields.get("inputTokens")) orelse continue;
        const output = parseNumber(fields.get("outputTokens")) orelse continue;
        rows[n] = .{
            .runtime = allocator.dupe(u8, runtime.string) catch return false,
            .model = allocator.dupe(u8, model.string) catch return false,
            .input = input,
            .output = output,
        };
        n += 1;
    }
    page.rows = rows[0..n];
    std.mem.sort(Row, page.rows, {}, struct {
        fn lessThan(_: void, lhs: Row, rhs: Row) bool {
            return tokens(lhs) > tokens(rhs);
        }
    }.lessThan);
    if (obj.get("periodStart")) |v| {
        if (v == .string) page.period_start = allocator.dupe(u8, v.string) catch "";
    }
    if (obj.get("asOf")) |v| {
        if (v == .string) page.as_of = allocator.dupe(u8, v.string) catch "";
    }
    if (obj.get("partial")) |v| {
        if (v == .bool) page.partial = v.bool;
    }
    return true;
}

fn receive(a: *App, id: u64, reply: rpc.Reply) void {
    const page = &a.view.usage;
    if (page.call == null or (page.call.? != id and page.call.? != sending)) return;
    page.call = null;
    switch (reply) {
        .ok => |value| {
            if (parse(a, page, value)) {
                page.phase = .ready;
            } else {
                page.phase = .failed;
                page.error_text = "The engine returned an unreadable usage summary.";
            }
        },
        .err => {
            page.phase = .failed;
            page.error_text = "Couldn't read local usage. Try refreshing.";
        },
        else => return,
    }
    a.redraw();
}

pub fn load(a: *App, refresh: bool) void {
    const page = &a.view.usage;
    if (page.phase == .loading or (!refresh and page.phase != .idle)) return;
    if (!a.engine.up()) {
        page.phase = .failed;
        page.error_text = "Engine not connected.";
        return;
    }
    page.phase = .loading;
    page.error_text = "";
    page.call = sending;
    const req = requests.localTokenUsage();
    const id = a.engine.call(req.method, req.params, .of(App, a, receive));
    if (page.call == sending) {
        page.call = id;
        if (id == null) {
            page.phase = .failed;
            page.error_text = "Couldn't request local usage. Try refreshing.";
        }
    }
}

fn tokens(row: Row) u64 {
    return row.input +| row.output;
}

fn fraction(part: u64, all: u64) f64 {
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(all));
}

const max_models = 6;
const rollup_names = [_][]const u8{ "Other models", "Other Codex models", "Other AGY models" };
const Breakdown = struct {
    indices: [max_models]usize = undefined,
    len: usize = 0,
    rest: [rollup_names.len]u64 = @splat(0),
    total: u64 = 0,

    fn add(b: *Breakdown, index: usize) void {
        b.indices[b.len] = index;
        b.len += 1;
    }

    fn selected(b: *const Breakdown) []const usize {
        return b.indices[0..b.len];
    }
};

fn rollup(runtime: []const u8) usize {
    if (std.mem.eql(u8, runtime, "Codex")) return 1;
    if (std.mem.eql(u8, runtime, "AGY")) return 2;
    return 0;
}

// Rows are already ranked. Reserve a slot for the top Codex and AGY model
// when present, so a smaller runtime never disappears into "Other models".
fn breakdown(rows: []const Row) Breakdown {
    var out: Breakdown = .{};
    for ([_]usize{ 1, 2 }) |bucket| {
        for (rows, 0..) |row, i| {
            if (tokens(row) > 0 and rollup(row.runtime) == bucket) {
                out.add(i);
                break;
            }
        }
    }
    for (rows, 0..) |row, i| {
        if (out.len == max_models or tokens(row) == 0) break;
        if (std.mem.indexOfScalar(usize, out.selected(), i) == null) out.add(i);
    }
    std.mem.sort(usize, out.indices[0..out.len], {}, comptime std.sort.asc(usize));
    for (rows, 0..) |row, i| {
        out.total +|= tokens(row);
        if (std.mem.indexOfScalar(usize, out.selected(), i) == null) out.rest[rollup(row.runtime)] +|= tokens(row);
    }
    return out;
}

fn palette(k: theme.Colors) [max_models + rollup_names.len]ui.Color {
    const colors = [max_models + rollup_names.len]ui.Color{
        k.accent, k.ansi[4], k.ansi[5], k.success, k.danger, k.ansi[14], k.muted, k.ansi[3], k.text,
    };
    var adjusted = colors;
    for (&adjusted) |*color| {
        color.* = k.background.mix(color.*, color.a);
        for (0..10) |_| {
            if (theme.contrast(color.*, k.background) >= 3) break;
            color.* = color.mix(k.text, 0.15);
        }
    }
    return adjusted;
}

fn pie(c: *ui.Context, size: f32, shares: []const u64, all: u64, colors: []const ui.Color, background: ui.Color) void {
    const center: ui.Point = .{ .x = size / 2, .y = size / 2 };
    const radius = size / 2 - 2;
    const cv = ui.canvas(c, .{ .width = .{ .px = size }, .height = .{ .px = size } });
    const start: f64 = -std.math.pi / 2.0;
    var angle = start;
    for (shares, colors) |amount, color| {
        if (amount == 0) continue;
        const arc = std.math.tau * fraction(amount, all);
        const steps: usize = @intFromFloat(@max(1, @ceil(128 * arc / std.math.tau)));
        var prev: ui.Point = .{ .x = center.x + radius * @as(f32, @floatCast(@cos(angle))), .y = center.y + radius * @as(f32, @floatCast(@sin(angle))) };
        for (1..steps + 1) |step| {
            const theta = angle + arc * @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
            const next: ui.Point = .{ .x = center.x + radius * @as(f32, @floatCast(@cos(theta))), .y = center.y + radius * @as(f32, @floatCast(@sin(theta))) };
            cv.triangle(center, prev, next, color, 2);
            prev = next;
        }
        angle += arc;
    }
    // Separate substantial neighboring slices even in a monochrome theme.
    // Don't obscure a small slice with a separator wider than the slice.
    var previous = shares.len;
    for (shares, 0..) |amount, i| {
        if (amount > 0) previous = i;
    }
    angle = start;
    for (shares, 0..) |amount, i| {
        if (amount == 0) continue;
        if (previous != i and fraction(amount, all) >= 0.01 and fraction(shares[previous], all) >= 0.01) {
            const edge: ui.Point = .{ .x = center.x + radius * @as(f32, @floatCast(@cos(angle))), .y = center.y + radius * @as(f32, @floatCast(@sin(angle))) };
            cv.line(center, edge, .{ .width = 1, .color = background });
        }
        previous = i;
        angle += std.math.tau * fraction(amount, all);
    }
}

fn formatDate(c: *ui.Context, date: []const u8) ?[]const u8 {
    if (date.len < 10 or date[4] != '-' or date[7] != '-') return null;
    const year = std.fmt.parseInt(u16, date[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, date[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, date[8..10], 10) catch return null;
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (month == 0 or month > names.len or day == 0 or day > 31) return null;
    return c.print("{s} {d}, {d}", .{ names[month - 1], day, year });
}

fn dateRange(c: *ui.Context, page: *const Page) []const u8 {
    const start = formatDate(c, page.period_start) orelse return "This calendar month";
    const end = formatDate(c, page.as_of) orelse return "This calendar month";
    return c.print("{s} – {s}", .{ start, end });
}

fn percent(c: *ui.Context, n: u64, all: u64) []const u8 {
    const share = fraction(n, all) * 100;
    return if (n > 0 and share < 0.05) "<0.1%" else c.print("{d:.1}%", .{share});
}

fn legendRow(c: *ui.Context, k: theme.Colors, label: []const u8, amount: u64, all: u64, color: ui.Color, width: f32) void {
    const line = ui.div(c).row().w(width).itemsCenter().gap(8);
    defer line.end();
    const dot = ui.canvas(c, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } });
    dot.circle(.{ .x = 6, .y = 6 }, 4, color);
    var buf: [24]u8 = undefined;
    ui.text(c, c.print("{s} · {s} · {s}", .{ label, abbreviated(amount, &buf), percent(c, amount, all) }), set.st(c, 12, .{ .color = k.text, .wrap = true }));
}

fn chartView(c: *ui.Context, k: theme.Colors, page: *Page, chart: Breakdown) void {
    const side_by_side = set.inner_w >= 520;
    const size = @min(194, set.inner_w);
    const legend_width = if (side_by_side) set.inner_w - size - 24 else set.inner_w;
    const layout = if (side_by_side) ui.div(c).row().w(set.inner_w).gap(24).itemsCenter() else ui.div(c).column().w(set.inner_w).gap(16);
    defer layout.end();
    var shares: [max_models + rollup_names.len]u64 = @splat(0);
    for (chart.selected(), 0..) |i, slot| shares[slot] = tokens(page.rows[i]);
    for (chart.rest, 0..) |amount, i| shares[max_models + i] = amount;
    const colors = palette(k);
    pie(c, size, &shares, chart.total, &colors, k.background);
    const legend = ui.div(c).column().w(legend_width).gap(6);
    defer legend.end();
    ui.text(c, "Model (runtime) · Tokens · Share", set.st(c, 12, .{ .weight = .semibold, .color = k.muted }));
    for (chart.selected(), 0..) |i, slot| {
        const row = page.rows[i];
        legendRow(c, k, c.print("{s} ({s})", .{ row.model, row.runtime }), tokens(row), chart.total, colors[slot], legend_width);
    }
    for (chart.rest, rollup_names, 0..) |amount, label, i| {
        if (amount > 0) legendRow(c, k, label, amount, chart.total, colors[max_models + i], legend_width);
    }
}

fn abbreviated(n: u64, buffer: *[24]u8) []const u8 {
    if (n >= 1_000_000_000) return std.fmt.bufPrint(buffer, "{d:.2}B", .{@as(f64, @floatFromInt(n)) / 1_000_000_000.0}) catch "";
    if (n >= 1_000_000) return std.fmt.bufPrint(buffer, "{d:.1}M", .{@as(f64, @floatFromInt(n)) / 1_000_000.0}) catch "";
    if (n >= 1_000) return std.fmt.bufPrint(buffer, "{d:.1}K", .{@as(f64, @floatFromInt(n)) / 1_000.0}) catch "";
    return std.fmt.bufPrint(buffer, "{d}", .{n}) catch "";
}

pub fn pageView(c: *ui.Context, a: *App, k: theme.Colors) void {
    const page = &a.view.usage;
    load(a, false);
    set.header(c, k, "Usage", null);
    set.subtitle(c, k, "This device · Recorded input + output · Not billing. Usage is read from local runtime records; cache is included where the runtime reports it.", true);
    set.space(c, 12);
    {
        const toolbar = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer toolbar.end();
        ui.text(c, dateRange(c, page), set.st(c, 12, .{ .color = k.muted, .wrap = true }));
        ui.spacer(c);
        ui.key(c, "settings-usage-refresh");
        const refresh = kit.pressFeedback(ui.div(c).row().px(11).py(7).gap(6).rounded(8).border(k.border).borderW(1).hover(k.hover).control());
        _ = kit.focusRing(c, refresh, k.accent, 2);
        const refresh_hot = refresh.hovered();
        ui.text(c, if (page.phase == .loading) "Refreshing…" else "Refresh", set.st(c, 12, .{ .weight = .medium, .color = if (refresh_hot) k.text else k.muted }));
        if (refresh.clicked() and page.phase != .loading) load(a, true);
        refresh.end();
    }
    set.space(c, 15);
    switch (page.phase) {
        .idle, .loading => ui.text(c, "Reading this device’s local usage records…", set.st(c, 13, .{ .color = k.muted })),
        .failed => {
            const failure = ui.div(c).column().w(set.inner_w).gap(8);
            defer failure.end();
            ui.text(c, page.error_text, set.st(c, 13, .{ .color = k.warning, .wrap = true }));
            ui.text(c, "Check the local engine connection, then refresh.", set.st(c, 12, .{ .color = k.muted }));
        },
        .ready => {
            if (page.partial) {
                const warning = ui.div(c).column().w(set.inner_w);
                defer warning.end();
                ui.text(c, "Some local sources were unavailable or had unsupported records; totals may be partial.", set.st(c, 12, .{ .color = k.warning, .wrap = true }));
            }
            const chart = breakdown(page.rows);
            if (chart.total == 0) {
                ui.text(c, "No recorded model usage for this month yet.", set.st(c, 13, .{ .color = k.muted }));
                return;
            }
            if (page.partial) set.space(c, 12);
            var total_buf: [24]u8 = undefined;
            ui.text(c, "Recorded tokens by model", set.st(c, 16, .{ .weight = .semibold, .color = k.text }));
            ui.text(c, c.print("{s} tokens recorded", .{abbreviated(chart.total, &total_buf)}), set.st(c, 12, .{ .color = k.muted }));
            set.space(c, 12);
            chartView(c, k, page, chart);
            set.space(c, 16);
            ui.key(c, "settings-usage-details");
            const details = kit.pressFeedback(ui.div(c).row().px(11).py(7).rounded(8).border(k.border).borderW(1).hover(k.hover).control());
            _ = kit.focusRing(c, details, k.accent, 2);
            ui.text(c, if (page.show_all) "Hide input and output by model" else "Show input and output by model", set.st(c, 12, .{ .color = k.text }));
            if (details.clicked()) page.show_all = !page.show_all;
            details.end();
            if (!page.show_all) return;
            const list = ui.div(c).column().w(set.inner_w).gap(6);
            defer list.end();
            for (page.rows) |row| {
                var input_buf: [24]u8 = undefined;
                var output_buf: [24]u8 = undefined;
                ui.text(c, c.print("{s} ({s}) · Input {s} · Output {s} · {s}", .{
                    row.model,
                    row.runtime,
                    abbreviated(row.input, &input_buf),
                    abbreviated(row.output, &output_buf),
                    percent(c, tokens(row), chart.total),
                }), set.st(c, 12, .{ .color = k.text, .wrap = true }));
            }
        },
    }
}
