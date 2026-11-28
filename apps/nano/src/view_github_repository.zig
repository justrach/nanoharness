//! Repository-wide read-only GitHub browsing with native Markdown prose.
//! No webview, image loading or provider-supplied executable links.
//! Pull requests come first: a one-line count of the loaded page with its
//! charts folded away, then rows that scan (title, then state, number,
//! author and age on one quiet line). Colours come from `github_display`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const flow = @import("app_github_repository.zig");
const icons = @import("icons.zig");
const behavior = @import("control_behavior.zig");
const groups = @import("control_group.zig");
const display = @import("github_display.zig");

/// Panes narrower than this stack their header rows.
pub const compact_width: f32 = 420;
/// The pane's side inset; list rows sit 8 in and pad 8 more, so every
/// line of words starts at the same 16.
pub const inset: f32 = 16;

pub fn view(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.panels.github_repository;
    const ready = s.pending == null;
    // Own a bounded column: headers may be arbitrarily tall, but must never
    // push pagination below the viewport. Only the middle region scrolls.
    ui.key(c, "github-repository-content");
    const surface = ui.div(c).column().wFull().grow().h(0);
    defer surface.end();
    const parent = c.node(c.node(surface.index).parent);
    const bounds = c.rects.get(surface.id()) orelse c.rects.get(parent.id);
    const width = if (bounds) |r| r.w else c.size.w;
    const compact = width < compact_width;
    header(c, a, k, width, compact, ready);
    kit.hairline(c, k);
    var page = s.current();
    {
        const viewport = ui.div(c).column().wFull().grow().h(0).scrollY();
        defer viewport.end();
        if (s.error_text) |text| errorBanner(c, k, text);
        const in_list = s.kind == .pulls or s.kind == .issues;
        if (in_list) {
            // With nothing loaded and an error showing, the tabs would only
            // repeat the failed request: the header's Refresh is the remedy.
            if (page != null or s.error_text == null) {
                listControls(c, a, k, compact, ready);
                kit.hairline(c, k);
            }
        } else detailHeader(c, a, k, width, ready);
        page = s.current();
        const current = page orelse {
            if (!ready and in_list) return skeleton(c, k, width);
            if (!ready) return note(c, k, "Loading…");
            if (s.error_text == null) note(c, k, "Nothing is loaded yet. Refresh to load it.");
            return;
        };
        if (current.truncated) note(c, k, "Some content was clipped by the host's size limits. Open on GitHub for the full content.");
        switch (s.kind) {
            .pulls, .issues => list(c, a, k, current, width, ready and s.error_text == null),
            .pull, .issue => {
                const content = ui.div(c).column().wFull().px(inset).py(12).gap(8);
                defer content.end();
                summary(c, a, k, current);
            },
            .files => {
                const content = ui.div(c).column().wFull().px(inset).py(12).gap(8);
                defer content.end();
                files(c, a, k, current);
            },
            .activity => {
                const content = ui.div(c).column().wFull().px(inset).py(12);
                defer content.end();
                activity(c, a, k, current, width - 2 * inset);
            },
        }
    }
    if (page) |current| {
        if (showPagination(s.kind, current)) {
            kit.hairline(c, k);
            const footer = ui.div(c).row().wFull().h(48).px(inset).gap(8).itemsCenter();
            defer footer.end();
            if (kit.actionButton(c, k, "Previous", .{ .icon = .@"alt-arrow-left", .enabled = ready and current.page > 1 and s.error_text == null })) flow.turnPage(a, false);
            {
                const status = ui.div(c).row().grow().w(0).justifyCenter().itemsCenter();
                defer status.end();
                ui.text(c, if (!ready) "Loading…" else c.print("Page {d}", .{current.page}), .{ .size = kit.text_body, .tabular = true, .color = k.muted });
            }
            if (kit.actionButton(c, k, "Next", .{ .trailing = .@"alt-arrow-right", .enabled = ready and current.hasNextPage and s.error_text == null })) flow.turnPage(a, true);
        }
    }
}

/// Whether the footer divider and pagination controls should appear for
/// `kind` on `page`: only when there is another page to turn to.
pub fn showPagination(kind: flow.Kind, page: flow.Page) bool {
    return switch (kind) {
        .pull, .issue => false,
        .pulls, .issues, .files, .activity => page.page > 1 or page.hasNextPage,
    };
}

/// The repository's name as far as it is known: the loaded page's
/// owner/name, else the checkout's folder, never a placeholder.
pub fn repositoryTitle(c: *ui.Context, a: *const App) []const u8 {
    const s = &a.panels.github_repository;
    if (s.repository()) |r| return c.print("{s}/{s}", .{ r.owner, r.name });
    const id = s.owner orelse a.selected orelse return "Repository";
    const chat = a.findChat(id) orelse return "Repository";
    const basename = @import("view_chat_header.zig").pathBasename;
    if (chat.source) |src| if (src.repo_root.len > 0) return basename(src.repo_root);
    if (a.findSpace(chat.space_id)) |sp| if (sp.name.len > 0) return sp.name;
    if (chat.cwd) |cwd| if (cwd.len > 0) return basename(cwd);
    return "Repository";
}

/// The repository's name, then the way back to the session pull requests
/// and Refresh: one 48-point row (two lines in a narrow pane).
fn header(c: *ui.Context, a: *App, k: theme.Colors, width: f32, compact: bool, ready: bool) void {
    var bar = ui.div(c).wFull().px(inset).gap(8);
    bar = if (compact) bar.column().py(8) else bar.row().h(48).itemsCenter();
    defer bar.end();
    var repo_row = ui.div(c).row().h(24).gap(8).itemsCenter().clip();
    repo_row = if (compact) repo_row.wFull() else repo_row.grow().w(0);
    {
        defer repo_row.end();
        icons.icon(c, .folder, 14, k.muted, 0);
        const name = ui.div(c).column().grow().w(0).clip();
        defer name.end();
        const room = if (c.rects.get(name.id())) |r| r.w else @max(0, width - 260);
        if (c.rects.get(name.id()) == null) c.animationFrame();
        kit.ellipsisText(c, repositoryTitle(c, a), .{ .size = kit.text_title, .line_height = 18, .weight = .medium, .color = k.text }, room);
    }
    var actions = ui.div(c).row().gap(8).itemsCenter();
    if (compact) actions = actions.wFull().justifyEnd();
    defer actions.end();
    // Not a back arrow: within the pane, an arrow means one level up.
    if (kit.actionButton(c, k, "Session PRs", .{ .icon = .list, .tip = "Session pull requests" })) flow.hide(a);
    if (kit.actionButton(c, k, "Refresh", .{ .icon = .refresh, .enabled = ready })) flow.refresh(a);
}

/// Pull requests | Issues as tabs, Open / Closed / All as a segmented
/// choice beside them (under them in a narrow pane).
fn listControls(c: *ui.Context, a: *App, k: theme.Colors, compact: bool, ready: bool) void {
    const s = &a.panels.github_repository;
    // Tabs pad their words by 4, so the row starts 4 short of the inset.
    var row = ui.div(c).wFull().px(inset - 4).gap(8);
    row = if (compact) row.column().py(4) else row.row().h(44).itemsCenter();
    defer row.end();
    if (groups.choicesLook(c, k, "GitHub item type", &.{ "Pull requests", "Issues" }, if (s.list_kind == .pulls) 0 else 1, ready, .tab, .tabs)) |chosen|
        flow.list(a, if (chosen == 0) .pulls else .issues, s.filter);
    if (!compact) ui.spacer(c);
    const states = [_]flow.Filter{ .open, .closed, .all };
    const selected: usize = switch (s.filter) {
        .open => 0,
        .closed => 1,
        .all => 2,
    };
    if (groups.choices(c, k, "GitHub state filter", &.{ "Open", "Closed", "All" }, selected, ready, .radio_button)) |chosen|
        flow.list(a, s.list_kind, states[chosen]);
}

/// What went wrong, in one banner; the header's Refresh is its one remedy
/// (the same `flow.refresh` a Retry here would repeat).
fn errorBanner(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const colors = kit.chipColors(k, .warning);
    const wrap = ui.div(c).column().wFull().px(inset).pt(12);
    defer wrap.end();
    const box = ui.div(c).row().wFull().px(12).py(10).gap(8).rounded(kit.radius_card).bg(colors.fill);
    defer box.end();
    icons.icon(c, .@"danger-triangle", 14, colors.ink, 0);
    ui.text(c, text, .{ .size = kit.text_body, .line_height = 17, .wrap = true, .color = k.text });
}

/// Four rows' worth of placeholder bars while the first page loads, so the
/// list doesn't jump when it arrives.
fn skeleton(c: *ui.Context, k: theme.Colors, width: f32) void {
    ui.key(c, "github-list-skeleton");
    const box = ui.div(c).column().wFull().px(8).py(8);
    defer box.end();
    const inner = @max(80, width - 2 * inset);
    for (0..4) |i| {
        if (i > 0) separator(c, k);
        const row = ui.div(c).column().wFull().px(8).py(12).gap(8);
        defer row.end();
        const fractions = [_]f32{ 0.72, 0.56, 0.8, 0.64 };
        ui.div(c).w(@floor(inner * fractions[i])).h(12).rounded(kit.radius_control).bg(k.hover).end();
        ui.div(c).w(@floor(inner * 0.38)).h(10).rounded(5).bg(k.hover.alpha(k.hover.a * 0.6)).end();
    }
}

fn detailHeader(c: *ui.Context, a: *App, k: theme.Colors, width: f32, ready: bool) void {
    const s = &a.panels.github_repository;
    const pull = s.selected_kind == .pull;
    const kind: display.Kind = if (pull) .pull else .issue;
    {
        // A narrow pane puts Open on GitHub under the way back.
        var bar = ui.div(c).wFull().px(inset).pt(12).gap(8);
        bar = if (width < compact_width) bar.column().itemsStart() else bar.row().itemsCenter();
        defer bar.end();
        if (kit.actionButton(c, k, if (s.list_kind == .pulls) "Pull requests" else "Issues", .{ .kind = .quiet, .icon = .@"arrow-left", .enabled = ready, .key = "github-detail-back" })) flow.back(a);
        if (width >= compact_width) ui.spacer(c);
        if (kit.actionButton(c, k, "Open on GitHub", .{ .trailing = .@"arrow-up-right", .enabled = s.repository() != null and s.number != null })) {
            const url = flow.itemUrl(c.alloc(), s.repository().?, s.number.?, pull) catch return;
            _ = nanoui.shell.openUrl(url);
        }
    }
    if (s.details) |d| if (d.page.detail) |detail| {
        const box = ui.div(c).column().wFull().px(inset).pt(8).pb(4).gap(8);
        defer box.end();
        ui.text(c, detail.title, .{ .size = kit.text_title, .line_height = 19, .weight = .medium, .wrap = true, .color = k.text });
        {
            const meta = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer meta.end();
            const state = display.stateOf(detail.state, detail.isDraft);
            kit.statusChip(c, k, display.label(state), .{ .tone = kit.roleTone(display.role(kind, state)) });
            const when = ago(c, a, detail.createdAt);
            const words = c.print("#{d} · {s} · opened {s}", .{ detail.number, detail.author, when });
            // A wrapping text fills the rest of the row (nanoui sizes a
            // wrapped text in a zero-width flexible box line by line).
            ui.text(c, words, .{ .size = kit.text_body, .line_height = 16, .tabular = true, .wrap = true, .color = k.muted });
        }
        if (detail.headRef) |head| {
            const branch = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
            defer branch.end();
            icons.icon(c, .@"git-branch", 12, k.muted, 0);
            kit.ellipsisText(c, c.print("{s} → {s}", .{ head, detail.baseRef orelse "" }), .{ .size = kit.text_body, .line_height = 16, .mono = true, .color = k.muted }, @max(40, width - 2 * inset - 18));
        }
        if (detail.changedFiles) |count| {
            const stat = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
            defer stat.end();
            icons.icon(c, .@"file-code", 12, k.muted, 0);
            diffStat(c, k, count, detail.additions orelse 0, detail.deletions orelse 0);
        }
        if (detail.labels.len > 0) labelChips(c, k, detail.labels, width - 2 * inset);
    };
    {
        const tabs = ui.div(c).row().wFull().px(inset - 4).pt(4).gap(6).itemsCenter();
        defer tabs.end();
        const enabled = ready and s.details != null and s.error_text == null;
        const labels: []const []const u8 = if (pull) &.{ "Summary", "Code", "Activity" } else &.{ "Summary", "Activity" };
        const sections: []const flow.Kind = if (pull) &.{ s.selected_kind, .files, .activity } else &.{ s.selected_kind, .activity };
        const selected: usize = if (s.kind == .files) 1 else if (s.kind == .activity) labels.len - 1 else 0;
        if (groups.choicesLook(c, k, "GitHub detail section", labels, selected, enabled, .tab, .tabs)) |chosen| flow.section(a, sections[chosen]);
    }
    kit.hairline(c, k);
}

/// "6 files · +342 / −57": one line, the counts in tabular figures, the
/// additions and deletions in the diff's own hues.
fn diffStat(c: *ui.Context, k: theme.Colors, count: u64, adds: u64, dels: u64) void {
    const words = c.print("{d} files · +{d} / −{d}", .{ count, adds, dels });
    const plus = std.mem.indexOf(u8, words, "+") orelse 0;
    const minus = std.mem.indexOf(u8, words, "−") orelse words.len;
    const end_plus = std.mem.indexOfPos(u8, words, plus, " ") orelse words.len;
    const spans = c.alloc().alloc(ui.Span, 2) catch return;
    spans[0] = .{ .start = @intCast(plus), .end = @intCast(end_plus), .color = k.diff_add };
    spans[1] = .{ .start = @intCast(minus), .end = @intCast(words.len), .color = k.diff_del };
    ui.richText(c, words, spans, .{ .size = kit.text_body, .line_height = 16, .tabular = true, .color = k.muted });
}

/// As many label chips as fit in `room`, in order; the rest are dropped.
fn labelChips(c: *ui.Context, k: theme.Colors, labels: []const []const u8, room: f32) void {
    const shown = fittingLabels(c, labels, room);
    if (shown == 0) return;
    const row = ui.div(c).row().gap(4).itemsCenter();
    defer row.end();
    for (labels[0..shown]) |lbl| kit.statusChip(c, k, lbl, .{ .max_w = label_max_w });
}

const label_max_w: f32 = 96;

fn fittingLabels(c: *ui.Context, labels: []const []const u8, room: f32) usize {
    const n = @min(labels.len, 3);
    var widths: [3]f32 = undefined;
    for (labels[0..n], 0..) |lbl, i| widths[i] = kit.statusChipWidth(c, lbl, .{ .max_w = label_max_w });
    return display.labelsThatFit(widths[0..n], room, 4);
}

fn separator(c: *ui.Context, k: theme.Colors) void {
    const line = ui.div(c).row().wFull().px(8);
    defer line.end();
    kit.hairline(c, k);
}

fn list(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, width: f32, enabled: bool) void {
    const s = &a.panels.github_repository;
    const is_pull = s.list_kind == .pulls;
    const kind: display.Kind = if (is_pull) .pull else .issue;
    if (page.items.len == 0) return emptyList(c, a, k, page);
    {
        const top = ui.div(c).column().wFull().px(inset).pt(4);
        defer top.end();
        @import("view_github_overview.zig").draw(c, a, k, page, width - 2 * inset, enabled);
    }
    const rows = ui.div(c).column().wFull().px(8).pb(8);
    defer rows.end();
    const inner = @max(40, width - 2 * inset);
    var shown: usize = 0;
    for (page.items) |item| {
        if (!flow.itemMatchesFilter(s, item)) continue;
        if (shown > 0) separator(c, k);
        shown += 1;
        ui.key(c, c.print("github-{d}", .{item.number}));
        var row = ui.div(c).column().wFull().px(8).py(10).gap(6).rounded(kit.radius_control);
        if (enabled) row = kit.pressFeedback(row.hover(k.hover).control());
        defer row.end();
        const activated = behavior.activate(c, row, k, item.title, enabled, false);
        ui.text(c, item.title, .{ .size = kit.text_title, .line_height = 18, .weight = .medium, .color = k.text, .wrap = true });
        {
            const meta = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer meta.end();
            const state = display.stateOf(item.state, item.isDraft);
            const state_label = display.label(state);
            kit.statusChip(c, k, state_label, .{ .tone = kit.roleTone(display.role(kind, state)) });
            const when = ago(c, a, item.updatedAt);
            const words = c.print("#{d} · {s} · updated {s}", .{ item.number, item.author, when });
            const st: ui.TextStyle = .{ .size = kit.text_body, .line_height = 16, .tabular = true, .color = k.muted };
            const used = kit.statusChipWidth(c, state_label, .{}) + 8 + @ceil(c.text.width(words, st));
            // Labels go first when the row is narrow; the words keep the rest.
            const label_room = inner - used - 8;
            const n = fittingLabels(c, item.labels, label_room);
            // Long names wrap rather than lose the age at the end; with
            // labels beside them the words fit on the line by construction.
            var wrapped = st;
            wrapped.wrap = n == 0;
            ui.text(c, words, wrapped);
            if (n > 0) {
                ui.spacer(c);
                const chips = ui.div(c).row().gap(4).itemsCenter();
                defer chips.end();
                for (item.labels[0..n]) |lbl| kit.statusChip(c, k, lbl, .{ .max_w = label_max_w });
            }
        }
        if (activated) flow.openItem(a, item.number);
    }
    if (shown == 0) {
        const empty = ui.div(c).column().wFull().py(24).itemsCenter();
        defer empty.end();
        ui.text(c, "Nothing on this page matches the filter.", .{ .size = kit.text_body, .color = k.muted });
    }
}

/// One glyph and one line saying which list is empty; the filter and
/// pagination above and below are the ways out, so nothing repeats them.
fn emptyList(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
    const s = &a.panels.github_repository;
    const is_pull = s.list_kind == .pulls;
    const noun = if (is_pull) "pull requests" else "issues";
    const empty = ui.div(c).column().wFull().px(inset).py(40).gap(8).itemsCenter();
    defer empty.end();
    icons.icon(c, if (is_pull) .@"pull-request" else .@"chat-round-line", 20, k.muted, 0);
    const title = if (page.hasNextPage)
        c.print("No {s} on this page", .{noun})
    else switch (s.filter) {
        .open => c.print("No open {s}", .{noun}),
        .closed => c.print("No closed {s}", .{noun}),
        .all => c.print("No {s} yet", .{noun}),
    };
    ui.text(c, title, .{ .size = kit.text_title, .weight = .medium, .color = k.text });
}

fn summary(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
    const detail = page.detail orelse return;
    // Zeron's description hierarchy, rendered with our bounded native prose
    // renderer rather than a webview or provider-controlled HTML surface.
    const card = ui.div(c).column().wFull().border(k.border).borderW(1).rounded(kit.radius_card).clip();
    defer card.end();
    {
        const head = ui.div(c).row().wFull().h(32).px(12).gap(6).itemsCenter();
        defer head.end();
        icons.icon(c, .document, 12, k.muted, 0);
        ui.text(c, "Description", .{ .size = kit.text_caption, .weight = .medium, .color = k.muted });
    }
    kit.hairline(c, k);
    {
        const body = ui.div(c).column().wFull().p(inset).gap(12);
        defer body.end();
        if (std.mem.trim(u8, detail.body, " \t\r\n").len == 0) {
            ui.text(c, "No description provided.", .{ .size = kit.text_body, .color = k.muted, .wrap = true });
        } else @import("view_markdown.zig").githubMarkdown(c, k, detail.body, a);
    }
}

fn files(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
    const s = &a.panels.github_repository;
    if (page.files.len == 0) return ui.text(c, "No files on this page.", .{ .size = kit.text_body, .color = k.muted });
    ui.text(c, "Expand a file to review its changes.", .{ .size = kit.text_body, .color = k.muted, .wrap = true });
    for (page.files, 0..) |file, i| {
        ui.key(c, file.filename);
        const expanded = s.expanded_file == i;
        const card = ui.div(c).column().wFull().border(if (expanded) k.border_strong else k.border).borderW(1).rounded(kit.radius_card).clip();
        defer card.end();
        {
            var row = ui.div(c).column().wFull().px(12).py(8).gap(4).hover(k.hover).control();
            if (expanded) row = row.bg(k.selected);
            defer row.end();
            const activated = behavior.activate(c, row, k, file.filename, true, expanded);
            {
                const heading = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer heading.end();
                icons.icon(c, if (expanded) .@"alt-arrow-down" else .@"alt-arrow-right", 12, if (expanded) k.text else k.muted, 0);
                @import("file_icons.zig").icon(c, file.filename, false, k.dark, 14);
                const name = ui.div(c).column().grow().w(0);
                defer name.end();
                const room = if (c.rects.get(name.id())) |r| r.w else 0;
                if (c.rects.get(name.id()) == null) c.animationFrame();
                kit.ellipsisText(c, file.filename, .{ .size = kit.text_body, .line_height = 16, .mono = true, .weight = .medium, .color = k.text }, room);
            }
            {
                const stats = ui.div(c).row().pl(20).gap(6).itemsCenter();
                defer stats.end();
                kit.statusChip(c, k, file.status, .{ .tone = fileStatusTone(file.status) });
                const st: ui.TextStyle = .{ .size = kit.text_caption, .line_height = 14, .mono = true, .tabular = true, .weight = .medium };
                // A zero is noise: an added file has no deletions to count.
                if (file.additions > 0 or file.deletions == 0) ui.text(c, c.print("+{d}", .{file.additions}), withColor(st, k.diff_add));
                if (file.deletions > 0) ui.text(c, c.print("−{d}", .{file.deletions}), withColor(st, k.diff_del));
            }
            if (activated) s.expanded_file = if (expanded) null else i;
        }
        if (expanded) {
            kit.hairline(c, k);
            if (file.previousFilename != null or file.patchTruncated) {
                const notices = ui.div(c).column().wFull().px(12).py(8).gap(4);
                defer notices.end();
                if (file.previousFilename) |old| ui.text(c, c.print("Previously: {s}", .{old}), .{ .size = kit.text_caption, .mono = true, .wrap = true, .color = k.muted });
                if (file.patchTruncated) ui.text(c, "Patch incomplete; open on GitHub for the full diff.", .{ .size = kit.text_caption, .wrap = true, .color = kit.chipColors(k, .warning).ink });
            }
            const parsed = if (s.content) |snapshot| (if (i < snapshot.patches.len) snapshot.patches[i] else null) else null;
            if (parsed) |patch| {
                // Until this local card has a measured rect, use a conservative
                // width; never borrow a neighboring pane's global host width.
                const available = if (c.rects.get(card.id())) |r| r.w - 2 else 1;
                @import("view_github_diff.zig").draw(c, k, &patch, @max(1, available));
            } else {
                const fallback = ui.div(c).column().wFull().p(12).bg(k.code_bg);
                defer fallback.end();
                ui.text(c, file.patch orelse "Patch not supplied by GitHub (binary, large or omitted).", .{ .size = kit.text_caption, .mono = file.patch != null, .wrap = true, .color = k.muted });
            }
        }
    }
}

fn withColor(st: ui.TextStyle, color: ui.Color) ui.TextStyle {
    var out = st;
    out.color = color;
    return out;
}

fn fileStatusTone(status: []const u8) kit.Tone {
    if (std.mem.eql(u8, status, "added")) return .success;
    if (std.mem.eql(u8, status, "removed")) return .danger;
    if (std.mem.eql(u8, status, "renamed")) return .accent;
    return .neutral;
}

/// The timeline: a rail of small glyphs, one per event kind, joined by a
/// hairline; "author verb" and its age on one line; a comment's or a
/// review's words under it, unboxed.
fn activity(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, inner: f32) void {
    if (page.events.len == 0) {
        const empty = ui.div(c).column().wFull().py(24).itemsCenter();
        defer empty.end();
        ui.text(c, "No activity on this page.", .{ .size = kit.text_body, .color = k.muted });
        return;
    }
    for (page.events, 0..) |event, i| {
        // The hairline to the next glyph is as tall as this entry's words
        // were last laid out: it never sizes the row, so it can't grow it.
        const rail = c.state(Rail, c.print("github-rail-{s}-{d}", .{ event.id, i }));
        ui.key(c, c.print("{s}-{d}", .{ event.id, i }));
        const last = i + 1 == page.events.len;
        const kind = display.eventOf(event.event);
        const row = ui.div(c).row().wFull().gap(12).itemsStart();
        defer row.end();
        {
            const col = ui.div(c).column().w(24).itemsCenter();
            defer col.end();
            const dot = ui.div(c).size(24, 24).center().roundedFull().circular().bg(k.hover);
            icons.icon(c, eventIcon(kind), 12, eventColor(k, kind), 0);
            dot.end();
            if (!last and rail.h > 24) ui.div(c).w(1).h(rail.h - 24).bg(k.border).end();
        }
        // A definite width: wrapped words in a zero-width flexible box are
        // measured a word per line.
        const body = ui.div(c).column().w(@max(80, inner - 24 - 12)).pb(if (last) 0 else 16).gap(6);
        defer body.end();
        if (c.rects.get(body.id())) |r| {
            if (r.h != rail.h) {
                rail.h = r.h;
                c.animationFrame();
            }
        } else c.animationFrame();
        {
            const head = ui.div(c).row().wFull().h(24).gap(8).itemsCenter();
            defer head.end();
            const words = c.print("{s} · {s}", .{ event.author, event.event });
            const spans = c.alloc().alloc(ui.Span, 1) catch return;
            spans[0] = .{ .start = 0, .end = @intCast(event.author.len), .color = k.text, .weight = .medium };
            {
                const who = ui.div(c).row().grow().w(0).clip();
                defer who.end();
                ui.richText(c, words, spans, .{ .size = kit.text_body, .line_height = 16, .color = k.muted });
            }
            if (display.reviewChip(kind)) |chip| kit.statusChip(c, k, chip.text, .{ .tone = kit.roleTone(chip.role) });
            if (event.commitSha) |sha| kit.statusChip(c, k, sha[0..@min(7, sha.len)], .{ .mono = true });
            ui.text(c, ago(c, a, event.createdAt), .{ .size = kit.text_caption, .tabular = true, .color = k.muted });
        }
        if (event.body) |text| {
            const words = ui.div(c).column().wFull().gap(8);
            defer words.end();
            @import("view_markdown.zig").githubMarkdown(c, k, text, a);
        }
    }
}

const Rail = struct { h: f32 = 0 };

fn eventIcon(e: display.Event) icons.Name {
    return switch (e) {
        .comment => .@"chat-round-line",
        .approved => .check,
        .changes_requested, .review => .eye,
        .commit => .@"git-branch",
        .label => .tag,
        .merge => .@"pull-request",
        .close => .close,
        .reopen => .restart,
        .other => .@"clock-circle",
    };
}

fn eventColor(k: theme.Colors, e: display.Event) ui.Color {
    return switch (e) {
        .approved => k.success,
        .changes_requested => k.danger,
        .merge => k.accent,
        else => k.muted,
    };
}

/// "2d ago", in the frame's memory.
fn ago(c: *ui.Context, a: *const App, text: []const u8) []const u8 {
    const buf = c.alloc().alloc(u8, 24) catch return text;
    return display.ago(buf, a.nowMs(), text);
}

fn note(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const box = ui.div(c).row().wFull().px(inset).py(12);
    defer box.end();
    ui.text(c, text, .{ .size = kit.text_body, .color = k.muted, .wrap = true });
}
