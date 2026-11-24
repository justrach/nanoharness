//! Repository-wide read-only GitHub browsing with native Markdown prose.
//! No webview, image loading or provider-supplied executable links.
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
    const compact = width < 420;
    {
        var bar = ui.div(c).wFull().px(14).py(8).gap(8);
        bar = if (compact) bar.column() else bar.row().itemsCenter();
        defer bar.end();
        const title = if (s.repository()) |r| c.print("{s}/{s}", .{ r.owner, r.name }) else "Repository GitHub";
        var repo_row = ui.div(c).row().h(22).gap(6).itemsCenter().clip();
        repo_row = if (compact) repo_row.wFull() else repo_row.grow().w(0);
        {
            defer repo_row.end();
            icons.icon(c, .folder, 13, k.muted, 0);
            const name = ui.div(c).column().grow().w(0).clip();
            defer name.end();
            const room = if (c.rects.get(name.id())) |r| r.w else @max(0, width - 220);
            if (c.rects.get(name.id()) == null) c.animationFrame();
            kit.ellipsisText(c, title, .{ .size = 12.5, .weight = .semibold, .color = k.text }, room);
        }
        var actions = ui.div(c).row().gap(6).itemsCenter();
        if (compact) actions = actions.wFull().justifyEnd();
        defer actions.end();
        if (actionButton(c, k, "Sessions", .list, null, true, false)) flow.hide(a);
        if (actionButton(c, k, "Refresh", .refresh, null, ready, false)) flow.refresh(a);
    }
    rule(c, k);
    var page = s.current();
    {
        const viewport = ui.div(c).column().wFull().grow().h(0).scrollY();
        defer viewport.end();
        if (s.error_text) |text| note(c, k, text, true);
        const in_list = s.kind == .pulls or s.kind == .issues;
        if (in_list) {
            {
                const controls = ui.div(c).column().wFull().px(14).py(10).gap(8).bg(k.ink(if (k.dark) 0.016 else 0.012));
                defer controls.end();
                {
                    const tabs = ui.div(c).row().wFull().gap(8).itemsCenter();
                    defer tabs.end();
                    if (groups.choices(c, k, "GitHub item type", &.{ "Pull requests", "Issues" }, if (s.list_kind == .pulls) 0 else 1, ready, .tab)) |chosen|
                        flow.list(a, if (chosen == 0) .pulls else .issues, s.filter);
                    if (!compact) {
                        ui.spacer(c);
                        scopePill(c, k);
                    }
                }
                {
                    var filters = ui.div(c).wFull().gap(8);
                    filters = if (compact) filters.column() else filters.row().itemsCenter();
                    defer filters.end();
                    const states = [_]flow.Filter{ .open, .closed, .all };
                    const selected: usize = switch (s.filter) {
                        .open => 0,
                        .closed => 1,
                        .all => 2,
                    };
                    if (groups.choices(c, k, "GitHub state filter", &.{ "Open", "Closed", "All" }, selected, ready, .radio_button)) |chosen|
                        flow.list(a, s.list_kind, states[chosen]);
                    if (compact) scopePill(c, k);
                }
            }
            rule(c, k);
        } else detailHeader(c, a, k, ready);
        page = s.current();
        const current = page orelse return note(c, k, if (!ready) "Loading from the repository's host…" else "No GitHub page is loaded. Refresh to retry.", false);
        if (current.truncated) note(c, k, "Some content was clipped by the host's size limits. Open on GitHub for the full content.", true);
        const content = ui.div(c).column().wFull().p(14).gap(10);
        defer content.end();
        switch (s.kind) {
            .pulls, .issues => list(c, a, k, current, width, ready and s.error_text == null),
            .pull, .issue => summary(c, a, k, current),
            .files => files(c, a, k, current),
            .activity => activity(c, a, k, current),
        }
    }
    if (page != null and s.kind != .pull and s.kind != .issue) {
        const current = page.?;
        rule(c, k);
        const footer = ui.div(c).row().wFull().h(44).px(14).gap(8).itemsCenter().bg(k.ink(if (k.dark) 0.016 else 0.012));
        defer footer.end();
        if (actionButton(c, k, "Previous", .@"alt-arrow-left", null, ready and current.page > 1 and s.error_text == null, false)) flow.turnPage(a, false);
        {
            const status = ui.div(c).row().grow().w(0).justifyCenter().itemsCenter();
            defer status.end();
            ui.text(c, if (!ready) "Loading…" else c.print("Page {d}", .{current.page}), .{ .size = 11.5, .weight = .medium, .color = k.muted });
        }
        if (actionButton(c, k, "Next", null, .@"alt-arrow-right", ready and current.hasNextPage and s.error_text == null, false)) flow.turnPage(a, true);
    }
}

fn scopePill(c: *ui.Context, k: theme.Colors) void {
    const pill = ui.div(c).row().px(8).py(3).gap(4).itemsCenter().rounded(999).bg(k.ink(if (k.dark) 0.04 else 0.035)).border(k.border).borderW(1);
    defer pill.end();
    icons.icon(c, .globe, 10, k.muted, 0);
    ui.text(c, "Repository-wide", .{ .size = 10.5, .color = k.muted });
}

fn detailHeader(c: *ui.Context, a: *App, k: theme.Colors, ready: bool) void {
    const s = &a.panels.github_repository;
    const hero = ui.div(c).column().wFull().bg(k.ink(if (k.dark) 0.018 else 0.014));
    {
        defer hero.end();
        {
            const bar = ui.div(c).row().wFull().px(14).pt(10).pb(6).gap(8).itemsCenter();
            defer bar.end();
            if (actionButton(c, k, if (s.list_kind == .pulls) "Back to PRs" else "Back to issues", .@"arrow-left", null, ready, false)) flow.back(a);
            ui.spacer(c);
            if (actionButton(c, k, "Open on GitHub", null, .@"arrow-up-right", s.repository() != null and s.number != null, false)) {
                const url = flow.itemUrl(c.alloc(), s.repository().?, s.number.?, s.selected_kind == .pull) catch return;
                _ = nanoui.shell.openUrl(url);
            }
        }
        if (s.details) |d| if (d.page.detail) |detail| {
            const box = ui.div(c).column().wFull().px(14).pt(4).pb(12).gap(8);
            defer box.end();
            {
                const top = ui.div(c).row().wFull().gap(6).itemsCenter();
                defer top.end();
                stateBadge(c, k, detail.number, detail.state, detail.isDraft, s.selected_kind == .pull);
                for (detail.labels[0..@min(2, detail.labels.len)]) |lbl| {
                    labelChip(c, k, lbl, 96);
                }
            }
            ui.text(c, detail.title, .{ .size = 17, .line_height = 23, .weight = .semibold, .wrap = true, .color = k.text });
            {
                const author_row = ui.div(c).row().wFull().gap(5).itemsCenter();
                defer author_row.end();
                icons.icon(c, .@"user-rounded", 12, k.faint, 0);
                ui.text(c, c.print("{s} · opened {s}", .{ detail.author, date(detail.createdAt) }), .{ .size = 11.5, .color = k.muted, .wrap = true });
            }
            if (detail.headRef != null or detail.changedFiles != null) {
                const meta = ui.div(c).column().wFull().gap(6);
                defer meta.end();
                if (detail.headRef) |head| {
                    const branch_pill = ui.div(c).row().px(8).py(3).gap(5).itemsCenter().rounded(6).bg(k.ink(if (k.dark) 0.045 else 0.04)).border(k.border).borderW(1);
                    defer branch_pill.end();
                    icons.icon(c, .@"git-branch", 11, k.accent.alpha(0.85), 0);
                    ui.text(c, c.print("{s} → {s}", .{ head, detail.baseRef orelse "" }), .{ .size = 11, .mono = true, .color = k.text.alpha(0.85), .wrap = true });
                }
                if (detail.changedFiles) |count| {
                    const adds = detail.additions orelse 0;
                    const dels = detail.deletions orelse 0;
                    const stat_pill = ui.div(c).row().px(8).py(3).gap(6).itemsCenter().rounded(6).bg(k.ink(if (k.dark) 0.035 else 0.03)).border(k.border).borderW(1);
                    defer stat_pill.end();
                    icons.icon(c, .@"file-code", 11, k.muted, 0);
                    ui.text(c, c.print("{d} files · +{d} / −{d}", .{ count, adds, dels }), .{ .size = 11, .mono = true, .color = k.muted, .wrap = true });
                    diffRatioBar(c, k, adds, dels);
                }
            }
        };
        {
            const tabs = ui.div(c).row().wFull().px(14).pb(10).gap(6).itemsCenter();
            defer tabs.end();
            const enabled = ready and s.details != null and s.error_text == null;
            const pull = s.selected_kind == .pull;
            const labels: []const []const u8 = if (pull) &.{ "Summary", "Code", "Activity" } else &.{ "Summary", "Activity" };
            const sections: []const flow.Kind = if (pull) &.{ s.selected_kind, .files, .activity } else &.{ s.selected_kind, .activity };
            const selected: usize = if (s.kind == .files) 1 else if (s.kind == .activity) labels.len - 1 else 0;
            if (groups.choices(c, k, "GitHub detail section", labels, selected, enabled, .tab)) |chosen| flow.section(a, sections[chosen]);
        }
    }
    rule(c, k);
}

fn list(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, width: f32, enabled: bool) void {
    const s = &a.panels.github_repository;
    const is_pull = s.list_kind == .pulls;
    const compact = width < 420;
    if (page.items.len == 0) {
        const empty = ui.div(c).column().wFull().p(28).gap(10).itemsCenter().rounded(12).bg(k.ink(if (k.dark) 0.02 else 0.015)).border(k.border).borderW(1);
        defer empty.end();
        const glyph_box = ui.div(c).size(40, 40).center().rounded(10).bg(k.ink(0.05)).border(k.border).borderW(1);
        icons.icon(c, if (is_pull) .@"pull-request" else .@"chat-round-line", 20, k.muted, 0);
        glyph_box.end();
        ui.text(c, "No matching items", .{ .size = 14, .weight = .semibold, .color = k.text });
        ui.text(c, if (page.hasNextPage) "No matches on this page. Try the next page or another filter." else "Try another state filter, or Refresh to check again.", .{ .size = 12, .color = k.muted, .wrap = true });
        return;
    }

    @import("view_github_overview.zig").draw(c, a, k, page, width, enabled);

    var shown: usize = 0;
    for (page.items) |item| {
        if (!flow.itemMatchesFilter(s, item)) continue;
        shown += 1;
        ui.key(c, c.print("github-{d}", .{item.number}));
        const card = ui.div(c).column().wFull().p(13).gap(7).bg(k.ink(if (k.dark) 0.028 else 0.018)).border(k.border).borderW(1).rounded(8);
        defer card.end();
        if (enabled) _ = card.hover(k.ink(if (k.dark) 0.055 else 0.042)).control();
        const activated = behavior.activate(c, card, k, item.title, enabled, false);
        {
            const top = ui.div(c).row().wFull().gap(6).itemsCenter();
            defer top.end();
            stateBadge(c, k, item.number, item.state, item.isDraft, is_pull);
            if (!compact and item.labels.len > 0) {
                for (item.labels[0..@min(2, item.labels.len)]) |lbl| {
                    labelChip(c, k, lbl, 84);
                }
            }
            ui.spacer(c);
            icons.icon(c, .@"alt-arrow-right", 12, k.faint, 0);
        }
        ui.text(c, item.title, .{ .size = 13.5, .line_height = 19, .weight = .semibold, .color = k.text, .wrap = true });
        {
            const meta = ui.div(c).row().wFull().gap(5).itemsCenter();
            defer meta.end();
            icons.icon(c, .@"user-rounded", 11, k.faint, 0);
            ui.text(c, c.print("{s} · updated {s}", .{ item.author, date(item.updatedAt) }), .{ .size = 11, .color = k.muted, .wrap = true });
        }
        if (activated) flow.openItem(a, item.number);
    }
    if (shown == 0) {
        const empty = ui.div(c).column().wFull().p(22).gap(8).itemsCenter().rounded(10).bg(k.ink(if (k.dark) 0.02 else 0.015)).border(k.border).borderW(1);
        defer empty.end();
        ui.text(c, "No items match the active chart filter", .{ .size = 13, .weight = .semibold, .color = k.text });
        if (actionButton(c, k, "Reset chart filters", null, null, enabled, false)) flow.clearClientFilters(a);
    }
}

fn summary(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
    const detail = page.detail orelse return;
    // Zeron's description hierarchy, rendered with our bounded native prose
    // renderer rather than a webview or provider-controlled HTML surface.
    const card = ui.div(c).column().wFull().bg(k.ink(if (k.dark) 0.02 else 0.012)).border(k.border).borderW(1).rounded(10).clip();
    defer card.end();
    {
        const header = ui.div(c).row().wFull().px(14).py(9).gap(6).itemsCenter().bg(k.ink(if (k.dark) 0.025 else 0.02));
        defer header.end();
        icons.icon(c, .document, 12, k.muted, 0);
        ui.text(c, "Description", .{ .size = 11.5, .weight = .semibold, .color = k.muted });
    }
    rule(c, k);
    {
        const body = ui.div(c).column().wFull().p(16).gap(12);
        defer body.end();
        if (std.mem.trim(u8, detail.body, " \t\r\n").len == 0) {
            ui.text(c, "No description provided.", .{ .size = 12, .color = k.muted, .wrap = true });
        } else @import("view_markdown.zig").githubMarkdown(c, k, detail.body, a);
    }
}

fn files(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
    const s = &a.panels.github_repository;
    ui.text(c, "Expand a file to review its changes.", .{ .size = 11.5, .color = k.muted, .wrap = true });
    if (page.files.len == 0) ui.text(c, "No files on this page.", .{ .size = 12, .color = k.muted });
    for (page.files, 0..) |file, i| {
        ui.key(c, file.filename);
        const expanded = s.expanded_file == i;
        const card = ui.div(c).column().wFull().border(if (expanded) k.accent.alpha(0.42) else k.border).borderW(1).rounded(10).clip();
        defer card.end();
        {
            const row = ui.div(c).column().wFull().px(12).py(10).gap(6).bg(if (expanded) k.accent.alpha(if (k.dark) 0.045 else 0.035) else k.ink(if (k.dark) 0.025 else 0.018)).hover(k.hover).control();
            defer row.end();
            const activated = behavior.activate(c, row, k, file.filename, true, expanded);
            {
                const heading = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer heading.end();
                icons.icon(c, if (expanded) .@"alt-arrow-down" else .@"alt-arrow-right", 12, if (expanded) k.accent else k.muted, 0);
                @import("file_icons.zig").icon(c, file.filename, false, k.dark, 15);
                const name = ui.div(c).column().grow().w(0);
                defer name.end();
                const room = if (c.rects.get(name.id())) |r| r.w else 0;
                if (c.rects.get(name.id()) == null) c.animationFrame();
                kit.ellipsisText(c, file.filename, .{ .size = 12, .mono = true, .weight = .medium, .color = k.text }, room);
            }
            {
                const stats = ui.div(c).row().pl(20).gap(6).itemsCenter();
                defer stats.end();
                const status_tone = fileStatusTone(k, file.status);
                {
                    const pill = ui.div(c).row().px(6).py(2).itemsCenter().rounded(5).bg(status_tone.alpha(0.11));
                    defer pill.end();
                    ui.text(c, file.status, .{ .size = 10.5, .weight = .medium, .color = status_tone });
                }
                {
                    const add = ui.div(c).row().px(6).py(2).itemsCenter().rounded(5).bg(k.diff_add.alpha(0.12));
                    defer add.end();
                    ui.text(c, c.print("+{d}", .{file.additions}), .{ .size = 10.5, .mono = true, .weight = .medium, .color = k.diff_add });
                }
                {
                    const del = ui.div(c).row().px(6).py(2).itemsCenter().rounded(5).bg(k.diff_del.alpha(0.12));
                    defer del.end();
                    ui.text(c, c.print("−{d}", .{file.deletions}), .{ .size = 10.5, .mono = true, .weight = .medium, .color = k.diff_del });
                }
            }
            if (activated) s.expanded_file = if (expanded) null else i;
        }
        if (expanded) {
            rule(c, k);
            if (file.previousFilename != null or file.patchTruncated) {
                const notices = ui.div(c).column().wFull().px(12).py(8).gap(5).bg(k.ink(0.018));
                defer notices.end();
                if (file.previousFilename) |old| ui.text(c, c.print("Previously: {s}", .{old}), .{ .size = 11, .mono = true, .wrap = true, .color = k.muted });
                if (file.patchTruncated) ui.text(c, "Patch incomplete; open on GitHub for the full diff.", .{ .size = 11, .wrap = true, .color = k.warning });
            }
            const parsed = if (s.content) |snapshot| (if (i < snapshot.patches.len) snapshot.patches[i] else null) else null;
            if (parsed) |patch| {
                // Until this local card has a measured rect, use a conservative
                // width; never borrow a neighboring pane's global host width.
                const available = if (c.rects.get(card.id())) |r| r.w - 2 else 1;
                @import("view_github_diff.zig").draw(c, k, &patch, @max(1, available));
            } else {
                const fallback = ui.div(c).column().wFull().p(12).bg(k.ink(0.015));
                defer fallback.end();
                ui.text(c, file.patch orelse "Patch not supplied by GitHub (binary, large or omitted).", .{ .size = 11, .mono = file.patch != null, .wrap = true, .color = k.muted });
            }
        }
    }
}

fn fileStatusTone(k: theme.Colors, status: []const u8) ui.Color {
    if (std.mem.eql(u8, status, "added")) return k.diff_add;
    if (std.mem.eql(u8, status, "removed")) return k.diff_del;
    if (std.mem.eql(u8, status, "renamed")) return k.accent;
    return k.muted;
}

fn activity(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
    if (page.events.len == 0) {
        const empty = ui.div(c).column().wFull().p(20).gap(6).itemsCenter().rounded(10).bg(k.ink(0.02)).border(k.border).borderW(1);
        defer empty.end();
        ui.text(c, "No activity on this page.", .{ .size = 12, .color = k.muted });
    }
    for (page.events, 0..) |event, i| {
        ui.key(c, c.print("{s}-{d}", .{ event.id, i }));
        // Activity bodies have variable length. Intrinsic card height keeps
        // them readable instead of clipping them to a guessed timeline height.
        const card = ui.div(c).column().wFull().bg(k.ink(if (k.dark) 0.02 else 0.012)).border(k.border).borderW(1).rounded(10).clip();
        defer card.end();
        {
            const header = ui.div(c).row().wFull().px(12).py(8).gap(6).itemsCenter().bg(k.ink(if (k.dark) 0.028 else 0.022));
            defer header.end();
            icons.icon(c, .@"user-rounded", 12, k.muted, 0);
            ui.text(c, c.print("{s} · {s}", .{ event.author, event.event }), .{ .size = 12, .weight = .semibold, .color = k.text });
            ui.spacer(c);
            if (event.commitSha) |sha| {
                const sha_pill = ui.div(c).row().px(6).py(2).itemsCenter().rounded(5).bg(k.ink(0.05)).border(k.border).borderW(1);
                defer sha_pill.end();
                ui.text(c, sha[0..@min(12, sha.len)], .{ .size = 10.5, .mono = true, .color = k.muted });
            }
            ui.text(c, date(event.createdAt), .{ .size = 10.5, .color = k.muted });
        }
        if (event.body) |text| {
            rule(c, k);
            const body = ui.div(c).column().wFull().px(14).py(12).gap(8);
            defer body.end();
            @import("view_markdown.zig").githubMarkdown(c, k, text, a);
        }
    }
}

fn stateBadge(c: *ui.Context, k: theme.Colors, number: u64, state: []const u8, draft: bool, is_pull: bool) void {
    const tone = if (draft) k.muted else if (std.mem.eql(u8, state, "open")) k.warning else if (std.mem.eql(u8, state, "closed")) k.success else k.accent;
    const badge = ui.div(c).row().px(8).py(3).gap(5).itemsCenter().rounded(999).bg(tone.alpha(0.12)).border(tone.alpha(0.28)).borderW(1);
    defer badge.end();
    icons.icon(c, if (is_pull) .@"pull-request" else .@"chat-round-line", 12, tone, 0);
    ui.text(c, c.print("#{d} · {s}{s}", .{ number, state, if (draft) " · draft" else "" }), .{ .size = 10.5, .weight = .semibold, .color = tone, .wrap = true });
}

fn labelChip(c: *ui.Context, k: theme.Colors, label: []const u8, max_w: f32) void {
    const chip = ui.div(c).row().px(6).py(2).itemsCenter().rounded(5).bg(k.ink(if (k.dark) 0.045 else 0.035)).border(k.border).borderW(1).clip();
    defer chip.end();
    kit.ellipsisText(c, label, .{ .size = 10, .color = k.muted }, max_w);
}

fn diffRatioBar(c: *ui.Context, k: theme.Colors, additions: u64, deletions: u64) void {
    const total = additions + deletions;
    if (total == 0) return;
    const bar_w: f32 = 40;
    const add_w = @max(@as(f32, if (additions > 0) 4 else 0), @floor(bar_w * @as(f32, @floatFromInt(additions)) / @as(f32, @floatFromInt(total))));
    const del_w = @max(@as(f32, if (deletions > 0) 4 else 0), bar_w - add_w);
    const bar = ui.div(c).row().w(bar_w).h(6).rounded(3).bg(k.ink(0.06)).clip();
    defer bar.end();
    if (additions > 0) _ = c.leaf(.{ .width = .{ .px = @min(bar_w, add_w) }, .height = .fill, .background = k.diff_add }, .none, null);
    if (deletions > 0) _ = c.leaf(.{ .width = .{ .px = @min(bar_w, del_w) }, .height = .fill, .background = k.diff_del }, .none, null);
}

fn date(text: []const u8) []const u8 {
    return text[0..@min(10, text.len)];
}

fn actionButton(c: *ui.Context, k: theme.Colors, label: []const u8, leading: ?icons.Name, trailing: ?icons.Name, enabled: bool, selected: bool) bool {
    ui.key(c, label);
    const fill = if (selected) k.selected else if (enabled) k.ink(if (k.dark) 0.035 else 0.025) else k.ink(0.015);
    const b = ui.div(c).row().h(26).px(9).gap(5).itemsCenter().rounded(7).bg(fill).border(if (enabled) k.border else k.border.alpha(0.5)).borderW(1);
    defer b.end();
    if (enabled) _ = b.hover(k.hover).control();
    const activated = behavior.activate(c, b, k, label, enabled, selected);
    const fg = if (enabled) k.text else k.faint;
    if (leading) |icon_name| icons.icon(c, icon_name, 12, if (enabled) k.muted else k.faint, 0);
    ui.text(c, label, .{ .size = 11.5, .weight = .medium, .color = fg });
    if (trailing) |icon_name| icons.icon(c, icon_name, 12, if (enabled) k.muted else k.faint, 0);
    return activated;
}

fn rule(c: *ui.Context, k: theme.Colors) void {
    ui.div(c).wFull().h(1).bg(k.border).end();
}

fn note(c: *ui.Context, k: theme.Colors, text: []const u8, warning: bool) void {
    const box = ui.div(c).row().wFull().px(14).py(10).gap(8).itemsCenter().bg(if (warning) k.warning.alpha(0.07) else .transparent);
    defer box.end();
    if (warning) icons.icon(c, .@"danger-triangle", 13, k.warning, 0);
    ui.text(c, text, .{ .size = 11.5, .color = if (warning) k.warning else k.muted, .wrap = true });
}
