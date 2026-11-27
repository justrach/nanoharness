//! The GitHub panes' shape over synthetic pages: pull requests come before
//! the charts, one state means one colour role everywhere, every control
//! is a 32-point target, and empty or single pages offer no pagination.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const flow = @import("app_github_repository.zig");
const github = @import("view_github_repository.zig");
const display = @import("github_display.zig");
const kit = @import("view_kit.zig");
const cr = @import("change_requests.zig");
const theme = @import("theme.zig");

const repo: flow.Repository = .{ .key = "polish-demo", .host = "github.com", .owner = "acme-labs", .name = "fieldnotes", .url = "https://github.com/acme-labs/fieldnotes" };

const items = [_]flow.Item{
    .{ .number = 212, .title = "Index notes offline so search works on a plane", .url = "https://github.com/acme-labs/fieldnotes/pull/212", .state = "open", .author = "mira-tan", .updatedAt = "2026-11-26", .labels = &.{ "search", "performance" } },
    .{ .number = 211, .title = "Add dark mode to the capture sheet", .url = "https://github.com/acme-labs/fieldnotes/pull/211", .state = "open", .isDraft = true, .author = "jonas-berg", .updatedAt = "2026-11-26", .labels = &.{"design"} },
    .{ .number = 209, .title = "Fix a crash on emoji titles", .url = "https://github.com/acme-labs/fieldnotes/pull/209", .state = "merged", .author = "priya-n", .updatedAt = "2026-11-25", .labels = &.{"bug"} },
    .{ .number = 205, .title = "Experiment: sync over local network", .url = "https://github.com/acme-labs/fieldnotes/pull/205", .state = "closed", .author = "jonas-berg", .updatedAt = "2026-11-24" },
    .{ .number = 203, .title = "Tidy settings copy", .url = "https://github.com/acme-labs/fieldnotes/pull/203", .state = "open", .author = "mira-tan", .updatedAt = "2026-11-24", .labels = &.{"design"} },
    .{ .number = 199, .title = "Speed up tag autocomplete", .url = "https://github.com/acme-labs/fieldnotes/pull/199", .state = "merged", .author = "priya-n", .updatedAt = "2026-11-23" },
    .{ .number = 197, .title = "Document the import format", .url = "https://github.com/acme-labs/fieldnotes/pull/197", .state = "closed", .author = "sam-okafor", .updatedAt = "2026-11-22" },
};
const many: flow.Page = .{ .repository = repo, .kind = .pulls, .items = &items, .hasNextPage = true };
const single: flow.Page = .{ .repository = repo, .kind = .pulls, .items = items[0..2] };
const empty: flow.Page = .{ .repository = repo, .kind = .pulls };
fn detailPage(state: []const u8, draft: bool) flow.Page {
    return .{ .repository = repo, .kind = .pull, .detail = .{
        .number = 212,
        .title = "Index notes offline so search works on a plane",
        .url = "https://github.com/acme-labs/fieldnotes/pull/212",
        .state = state,
        .isDraft = draft,
        .author = "mira-tan",
        .createdAt = "2026-11-24",
        .updatedAt = "2026-11-26",
        .body = "Notes are indexed on disk so search keeps working offline.",
        .headRef = "feat/offline-search",
        .baseRef = "main",
        .additions = 342,
        .deletions = 57,
        .changedFiles = 6,
        .labels = &.{"search"},
    } };
}
const files_page: flow.Page = .{ .repository = repo, .kind = .files, .files = &.{
    .{ .filename = "src/search.zig", .status = "modified", .additions = 40, .deletions = 12 },
    .{ .filename = "src/index/offline.zig", .status = "added", .additions = 210, .deletions = 0 },
} };
const activity_page: flow.Page = .{ .repository = repo, .kind = .activity, .events = &.{
    .{ .id = "e1", .event = "commented", .author = "jonas-berg", .createdAt = "2026-11-25", .body = "Can the warm-up run on a low priority thread?" },
    .{ .id = "e2", .event = "committed", .author = "mira-tan", .createdAt = "2026-11-25", .commitSha = "9f3c2a17be40" },
    .{ .id = "e3", .event = "reviewed: approved", .author = "priya-n", .createdAt = "2026-11-26", .body = "Approved." },
} };

const Fixture = struct {
    a: App,
    t: ui.Tester,

    fn init(f: *Fixture, width: f32, height: f32, list: flow.Page, shown: ?flow.Page) !void {
        theme.registerFonts();
        f.a = .init(testing.allocator, testing.io, 1);
        errdefer f.a.deinit();
        f.a.offscreen = true;
        f.a.dark = true;
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[ {"id":"polish-chat","deviceId":"local","title":"Offline search","cwd":"/synthetic/fieldnotes","branch":"feat/offline-search","archived":false} ]
        , .{});
        defer chats.deinit();
        try f.a.chats.replace(chats.value);
        f.a.openChat("polish-chat", null);
        f.a.panels.github_repository.list = try snapshot(list);
        if (shown) |page| {
            f.a.panels.github_repository.details = try snapshot(kindDetail(page));
            f.a.panels.github_repository.number = 212;
            if (page.kind == .files or page.kind == .activity) f.a.panels.github_repository.content = try snapshot(page);
            f.a.panels.github_repository.kind = page.kind;
        }
        f.a.engine.state = .connected;
        try f.t.init(testing.allocator, .init(f, draw), .{ .width = width, .height = height, .dark = true });
        f.t.settle(0.1);
    }
    fn deinit(f: *Fixture) void {
        f.t.deinit();
        f.a.deinit();
    }
    fn draw(f: *Fixture, c: *ui.Context) void {
        _ = f.a.engine.pump();
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        github.view(c, &f.a, theme.colors(true));
    }
    fn node(f: *Fixture, label: []const u8) ?ui.Rect {
        for (f.t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, label)) return n.rect,
            else => {},
        };
        return null;
    }
    /// A chip's words in `label`: its text colour and its box's fill.
    fn chip(f: *Fixture, label: []const u8) ?struct { ink: ui.Color, fill: ?ui.Color } {
        for (f.t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, label)) {
                const box = f.t.ctx.node(n.parent);
                if (box.rect.h == kit.chip_h) return .{ .ink = tx.color, .fill = box.style.background };
            },
            else => {},
        };
        return null;
    }
    /// Every activatable control, with its box, is at least the target.
    fn targets(f: *Fixture) !usize {
        var checked: usize = 0;
        for (f.t.ctx.a11y_items.items) |item| switch (item.role) {
            .button, .tab, .radio_button => {
                const r = f.t.ctx.nodes.items[item.node_index].rect;
                if (r.h < kit.hit_target - 0.5 or r.w < kit.hit_target - 0.5) {
                    std.debug.print("under 32 points: {s} {d}x{d}\n", .{ item.label, r.w, r.h });
                    return error.SmallHitTarget;
                }
                checked += 1;
            },
            else => {},
        };
        return checked;
    }
};

/// The detail snapshot a section page belongs to.
fn kindDetail(page: flow.Page) flow.Page {
    return if (page.kind == .pull) page else detailPage("open", false);
}

fn snapshot(page: flow.Page) !flow.Snapshot {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, page, .{});
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return flow.Snapshot.parse(testing.allocator, parsed.value);
}

test "github list puts the first pull request near the pane top while the charts are folded" {
    var f: Fixture = undefined;
    try f.init(520, 900, many, null);
    defer f.deinit();
    try testing.expect(!f.a.settings.get(.github_charts_expanded));
    const first = f.node(items[0].title) orelse return error.MissingFirstRow;
    // Header (48), tabs and filter (44), the summary line (36), the row's own inset.
    try testing.expect(first.y <= 160);
    // The counts come first; a narrow pane cuts the "more" hint before them.
    try testing.expect(f.t.containsText("7 loaded · 2 open · 1 draft · 2 merged · 2 closed"));
    try testing.expect(!f.t.hasText("State split"));
    // Unfolding is remembered, and pushes the rows below the charts.
    try f.t.clickText("Show charts");
    f.t.settle(0.1);
    try testing.expect(f.a.settings.get(.github_charts_expanded));
    try testing.expect(f.t.hasText("State split"));
    try testing.expect((f.node(items[0].title) orelse return error.MissingFirstRow).y > 300);
    try f.t.clickText("Hide charts");
    f.t.settle(0.1);
    try testing.expect(!f.a.settings.get(.github_charts_expanded));
    try testing.expect((f.node(items[0].title) orelse return error.MissingFirstRow).y <= 160);
}

test "github state chips in the list, the detail header and the footer badge share one role per state" {
    const k = theme.colors(true);
    const cases = [_]struct { state: []const u8, draft: bool, label: []const u8, cr_state: ?cr.State }{
        .{ .state = "open", .draft = false, .label = "Open", .cr_state = .open },
        .{ .state = "open", .draft = true, .label = "Draft", .cr_state = null },
        .{ .state = "merged", .draft = false, .label = "Merged", .cr_state = .merged },
        .{ .state = "closed", .draft = false, .label = "Closed", .cr_state = .closed },
    };
    {
        var f: Fixture = undefined;
        try f.init(720, 1200, many, null);
        defer f.deinit();
        for (cases) |case| {
            const want = kit.chipColors(k, kit.roleTone(display.role(.pull, display.stateOf(case.state, case.draft))));
            const got = f.chip(case.label) orelse return error.MissingListChip;
            try testing.expectEqual(want.ink, got.ink);
            try testing.expectEqual(want.fill, got.fill.?);
        }
    }
    for (cases) |case| {
        var f: Fixture = undefined;
        try f.init(720, 900, many, detailPage(case.state, case.draft));
        defer f.deinit();
        const want = kit.chipColors(k, kit.roleTone(display.role(.pull, display.stateOf(case.state, case.draft))));
        const got = f.chip(case.label) orelse return error.MissingDetailChip;
        try testing.expectEqual(want.ink, got.ink);
        try testing.expectEqual(want.fill, got.fill.?);
        // The composer footer's badge and the session pane's chip, for the same state.
        if (case.cr_state) |st| {
            const summary: cr.Summary = .{ .provider = "github", .number = 212, .title = "t", .url = "https://github.com/acme-labs/fieldnotes/pull/212", .state = st, .base_ref = "main", .head_ref = "feat/offline-search" };
            const prs = @import("view_change_requests.zig");
            const role = display.role(.pull, display.stateOf(case.state, false));
            try testing.expectEqual(role, prs.badgeRole(summary, .own_branch));
            try testing.expectEqual(kit.roleColor(k, role), prs.badgeColor(k, summary, .own_branch));
        }
    }
}

test "github panes keep every control at the 32 point target" {
    const pages = [_]struct { list: flow.Page, shown: ?flow.Page }{
        .{ .list = many, .shown = null },
        .{ .list = empty, .shown = null },
        .{ .list = many, .shown = detailPage("open", false) },
        .{ .list = many, .shown = files_page },
        .{ .list = many, .shown = activity_page },
    };
    for ([_]f32{ 360, 720 }) |width| for (pages) |p| {
        var f: Fixture = undefined;
        try f.init(width, 1400, p.list, p.shown);
        defer f.deinit();
        try testing.expect(try f.targets() >= 3);
    };
}

test "github empty and single-page lists show no pagination; a list with more pages does" {
    inline for (.{ empty, single }) |page| {
        var f: Fixture = undefined;
        try f.init(520, 700, page, null);
        defer f.deinit();
        try testing.expect(!f.t.hasText("Previous"));
        try testing.expect(!f.t.hasText("Next"));
        try testing.expect(!f.t.hasText("Page 1"));
    }
    {
        var f: Fixture = undefined;
        try f.init(520, 700, empty, null);
        defer f.deinit();
        // One message; the All filter right above it is the way out, so the
        // empty state adds no button of its own.
        try testing.expect(f.t.hasText("No open pull requests"));
        try testing.expect(!f.t.hasText("Show all pull requests"));
        for (f.t.ctx.a11y_items.items) |item| if (item.role == .button) {
            const known = std.mem.eql(u8, item.label, "Session PRs") or std.mem.eql(u8, item.label, "Refresh");
            if (!known) std.debug.print("unexpected empty-state button: {s}\n", .{item.label});
            try testing.expect(known);
        };
    }
    {
        var f: Fixture = undefined;
        try f.init(520, 700, many, null);
        defer f.deinit();
        try testing.expect(f.t.hasText("Previous"));
        try testing.expect(f.t.hasText("Next"));
    }
}

test "github error shows one banner, one Refresh and the checkout's name, not a placeholder" {
    var f: Fixture = undefined;
    try f.init(520, 700, empty, null);
    defer f.deinit();
    f.a.panels.github_repository.list.?.arena.deinit();
    f.a.panels.github_repository.list = null;
    f.a.panels.github_repository.error_text = try testing.allocator.dupe(u8, "GitHub is unavailable on this session's host.");
    f.t.settle(0.1);
    try testing.expect(f.t.hasText("GitHub is unavailable on this session's host."));
    // One control refreshes: the header's. The banner only explains.
    try testing.expect(!f.t.hasText("Retry"));
    var refreshers: usize = 0;
    for (f.t.ctx.a11y_items.items) |item| {
        if (item.role == .button and (std.mem.eql(u8, item.label, "Refresh") or std.mem.eql(u8, item.label, "Retry"))) refreshers += 1;
    }
    try testing.expectEqual(@as(usize, 1), refreshers);
    try testing.expect(f.t.hasText("fieldnotes"));
    try testing.expect(!f.t.hasText("Repository GitHub"));
    try testing.expect(!f.t.containsText("No GitHub page is loaded"));
    try testing.expect(!f.t.containsText("Nothing is loaded yet"));
    // The tabs would only repeat the failed request.
    try testing.expect(!f.t.hasText("Issues"));
}

test "github activity timeline keeps every event in reach with a glyph rail, not one card per event" {
    var f: Fixture = undefined;
    try f.init(520, 1200, many, activity_page);
    defer f.deinit();
    f.t.settle(0.2);
    const first = f.node("jonas-berg · commented") orelse return error.MissingFirstEvent;
    const last = f.node("priya-n · reviewed: approved") orelse return error.MissingLastEvent;
    // Three short entries sit within a few lines of each other.
    try testing.expect(last.y > first.y);
    try testing.expect(last.y - first.y < 220);
    try testing.expect(f.t.hasText("Approved"));
    try testing.expect(f.t.hasText("9f3c2a1"));
}

/// The summary line as drawn: the text node that starts with the count.
fn summaryText(f: *Fixture) ?[]const u8 {
    for (f.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.startsWith(u8, tx.str, "7 loaded")) return tx.str,
        else => {},
    };
    return null;
}

test "github summary line never ends mid-word beside the charts toggle, folded or open" {
    for ([_]f32{ 300, 360, 420, 520, 640, 784 }) |width| for ([_]bool{ false, true }) |open| {
        var f: Fixture = undefined;
        try f.init(width, 900, many, null);
        defer f.deinit();
        if (open) {
            try f.t.clickText("Show charts");
            f.t.settle(0.1);
        }
        const line = summaryText(&f) orelse return error.MissingSummary;
        // Whole, or whole pieces then " · …": never "more on nex…".
        const whole = std.mem.endsWith(u8, line, "more on next page") or std.mem.endsWith(u8, line, " · …") or
            !std.mem.endsWith(u8, line, "…");
        if (!whole) std.debug.print("{d} px: \"{s}\"\n", .{ width, line });
        try testing.expect(whole);
        try testing.expect(std.mem.indexOf(u8, line, "more on nex") == null or std.mem.endsWith(u8, line, "more on next page"));
    };
}
