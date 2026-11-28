//! Native Git/GitHub surfaces over existing host-owned engine services.
//! No plugin interpreter, local subprocesses, or automatic remote writes.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const git = @import("app_git.zig");
const panels = @import("app_panels.zig");
const prs = @import("app_change_requests.zig");
const cr = @import("change_requests.zig");
const display = @import("github_display.zig");

pub fn history(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.panels.git_workflow.open) return @import("view_git_workflow.zig").view(c, a, k);
    const s = &a.panels.history;
    {
        const bar = ui.div(c).row().wFull().h(48).px(16).gap(8).itemsCenter();
        defer bar.end();
        icons.icon(c, .@"git-branch", 14, k.muted, 0);
        const chat = if (a.selected) |id| a.findChat(id) else null;
        kit.ellipsisText(c, if (chat) |ch| ch.branch orelse "Checkout history" else "Git history", .{ .size = kit.text_body, .mono = true, .color = k.text }, @max(80, a.view.chrome.host_width - 300));
        ui.spacer(c);
        if (button(c, k, "Git changes", true)) @import("app_git_workflow.zig").show(a);
        if (button(c, k, "Diffs", true)) panels.addDiffsTab(a);
        if (button(c, k, "Refresh", s.pending == null)) git.load(a, 0);
    }
    rule(c, k);
    if (a.selected == null) return empty(c, k, "Open a project session to inspect its checkout.");
    if (s.error_text) |e| {
        const msg = ui.div(c).column().wFull().p(12).bg(k.warning.alpha(0.06));
        ui.text(c, e, .{ .size = 12, .wrap = true, .color = k.muted });
        msg.end();
    }
    const snapshot = s.snapshot orelse return empty(c, k, if (s.pending != null) "Loading Git history…" else "Git history is not loaded.");
    const page = snapshot.page;
    if (page.comparison) |comparison| {
        const note = ui.div(c).row().wFull().px(16).py(8);
        defer note.end();
        ui.text(c, c.print("{d} ahead · {d} behind {s} (local refs)", .{ comparison.ahead, comparison.behind, comparison.base }), .{ .size = kit.text_caption, .tabular = true, .color = k.muted });
    }
    if (page.commits.len == 0) return empty(c, k, "No commits yet.");
    {
        const list = ui.div(c).column().wFull().grow().h(0).px(12).scrollY();
        defer list.end();
        for (page.commits, 0..) |commit, i| {
            ui.key(c, commit.sha);
            const is_head = if (page.headSha) |head| std.mem.eql(u8, head, commit.sha) else false;
            // A chronological rail, not a branch graph. Endpoint flags
            // describe the full list, not just this visible page.
            const row = nanoui.kit.timelineItem(c, .{
                .height = 56,
                .first = i == 0 and s.cursor == 0,
                .last = i + 1 == page.commits.len and page.nextCursor == null,
                .color = if (is_head) k.accent else k.muted,
            });
            defer row.end();
            const body = ui.div(c).column().grow().w(0).gap(4).clip();
            defer body.end();
            kit.ellipsisText(c, commit.subject, .{ .size = kit.text_title, .line_height = 18, .weight = .medium, .color = k.text }, @max(80, a.view.chrome.host_width - 74));
            const meta = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
            defer meta.end();
            ui.text(c, commit.sha[0..@min(7, commit.sha.len)], .{ .size = kit.text_caption, .mono = true, .color = k.muted });
            const when = display.ago(c.alloc().alloc(u8, 24) catch continue, a.nowMs(), commit.authoredAt);
            kit.ellipsisText(c, c.print("{s} · {s}", .{ commit.authorName, when }), .{ .size = kit.text_caption, .tabular = true, .color = k.muted }, 180);
            if (is_head) tag(c, k, "HEAD", .accent);
            if (commit.parentShas.len > 1) tag(c, k, "Merge", .neutral);
            for (commit.refs, 0..) |ref, j| {
                if (j >= 2) break;
                tag(c, k, ref.label, .neutral);
            }
        }
    }
    rule(c, k);
    const footer = ui.div(c).row().wFull().h(48).px(16).gap(8).itemsCenter();
    defer footer.end();
    if (button(c, k, "Previous", s.cursor > 0 and s.pending == null)) git.load(a, git.previousCursor(s.cursor));
    ui.text(c, if (s.pending != null) "Loading…" else c.print("{d}–{d}", .{ s.cursor + 1, s.cursor + page.commits.len }), .{ .size = kit.text_body, .tabular = true, .color = k.muted });
    ui.spacer(c);
    if (button(c, k, "Next", page.nextCursor != null and s.pending == null)) git.load(a, page.nextCursor.?);
}

pub const PullRequest = struct { chat_id: []const u8, summary: cr.Summary, provenance: cr.Provenance };

/// Only sessions in the selected repository on the same host. A shared
/// branch contributes one PR, with the selected session preferred.
pub fn sessionPullRequests(a: *const App, allocator: std.mem.Allocator) ![]PullRequest {
    var result: std.ArrayList(PullRequest) = .empty;
    errdefer result.deinit(allocator);
    const id = a.panels.github_repository.owner orelse a.selected orelse return result.toOwnedSlice(allocator);
    const selected = a.findChat(id) orelse return result.toOwnedSlice(allocator);
    const source = selected.source orelse return result.toOwnedSlice(allocator);
    const selected_pr = prs.forChat(a, selected);
    if (selected_pr) |pr| try result.append(allocator, .{ .chat_id = id, .summary = pr[0], .provenance = pr[1] });
    for (a.chats.items) |chat| {
        if (chat.archived or chat.parent_chat_id != null or std.mem.eql(u8, chat.id, id)) continue;
        const other = chat.source orelse continue;
        if (!std.mem.eql(u8, source.repo_root, other.repo_root) or !std.mem.eql(u8, selected.device_id orelse "", chat.device_id orelse "")) continue;
        const pr = prs.forChat(a, chat) orelse continue;
        const duplicate = for (result.items) |existing| {
            if (std.mem.eql(u8, existing.summary.url, pr[0].url)) break true;
        } else false;
        if (!duplicate) try result.append(allocator, .{ .chat_id = chat.id, .summary = pr[0], .provenance = pr[1] });
    }
    return result.toOwnedSlice(allocator);
}

pub fn github(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.panels.github_repository.open) return @import("view_github_repository.zig").view(c, a, k);
    const items = sessionPullRequests(a, c.alloc()) catch return;
    {
        const title = ui.div(c).column().wFull().p(14).gap(5);
        defer title.end();
        {
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            ui.text(c, "Session pull requests", .{ .size = 15, .weight = .semibold, .color = k.text });
            ui.spacer(c);
            // The empty state has its own "Browse repository"; one is enough.
            if (items.len > 0 and button(c, k, "Repository", true)) @import("app_github_repository.zig").show(a);
        }
        ui.text(c, "Branches used by this repository’s sessions—not every PR on GitHub.", .{ .size = 11.5, .wrap = true, .color = k.muted });
    }
    rule(c, k);
    if (items.len == 0) {
        const box = ui.div(c).column().wFull().grow().p(24).gap(10).center();
        defer box.end();
        icons.icon(c, .@"pull-request", 24, k.muted, 0);
        ui.text(c, "No session-linked pull requests", .{ .size = 14, .weight = .semibold, .color = k.text, .wrap = true });
        ui.text(c, if (a.engine.state != .connected) "Connect to the host to discover session pull requests." else "This view only shows PRs linked to session branches. Browse Repository for all pull requests and issues; an empty list does not indicate a sign-in failure.", .{ .size = 12, .wrap = true, .color = k.muted });
        if (button(c, k, "Browse repository", a.selected != null)) @import("app_github_repository.zig").show(a);
        return;
    }
    const list = ui.div(c).column().wFull().grow().h(0).px(8).py(8).scrollY();
    defer list.end();
    for (items, 0..) |item, i| {
        const pr = item.summary;
        ui.key(c, pr.url);
        if (i > 0) {
            const line = ui.div(c).row().wFull().px(8);
            defer line.end();
            rule(c, k);
        }
        // The repository list's row: title first, then the state chip, the
        // number and the branches on one quiet line; actions under them.
        const row = ui.div(c).column().wFull().px(8).py(12).gap(8);
        defer row.end();
        const model = cr.model(c.alloc(), pr);
        const prs_view = @import("view_change_requests.zig");
        ui.text(c, model.title, .{ .size = kit.text_title, .line_height = 18, .weight = .medium, .wrap = true, .color = k.text });
        {
            const meta = ui.div(c).row().wFull().gap(8).itemsCenter().clip();
            defer meta.end();
            kit.statusChip(c, k, model.state_label, .{ .tone = kit.roleTone(prs_view.badgeRole(pr, item.provenance)) });
            ui.text(c, model.number, .{ .size = kit.text_body, .line_height = 16, .tabular = true, .color = k.muted });
            icons.icon(c, .@"git-branch", 12, k.muted, 0);
            kit.ellipsisText(c, c.print("{s} → {s}", .{ pr.head_ref, pr.base_ref }), .{ .size = kit.text_body, .line_height = 16, .mono = true, .color = k.muted }, @max(60, a.view.chrome.host_width - 200));
        }
        if (item.provenance.note(c.alloc(), pr)) |note| ui.text(c, note, .{ .size = kit.text_caption, .wrap = true, .color = k.muted });
        {
            const actions = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer actions.end();
            if (kit.actionButton(c, k, "Open on GitHub", .{ .trailing = .@"arrow-up-right" })) _ = nanoui.shell.openUrl(pr.url);
            const selected = if (a.selected) |id| std.mem.eql(u8, id, item.chat_id) else false;
            if (!selected) {
                if (kit.actionButton(c, k, "Open session", .{})) a.openChatInTab(item.chat_id);
            } else if (a.findChat(item.chat_id)) |chat| prs_view.mergeControlsIn(c, a, k, chat, pr, .pane);
        }
    }
}

/// The panes' secondary button (`view_kit.actionButton`).
fn button(c: *ui.Context, k: theme.Colors, label: []const u8, enabled: bool) bool {
    return kit.actionButton(c, k, label, .{ .enabled = enabled });
}
fn tag(c: *ui.Context, k: theme.Colors, label: []const u8, tone: kit.Tone) void {
    kit.statusChip(c, k, label, .{ .tone = tone, .max_w = 150 });
}
fn rule(c: *ui.Context, k: theme.Colors) void {
    ui.div(c).wFull().h(1).bg(k.border).end();
}
fn empty(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const box = ui.div(c).column().wFull().grow().p(24).center();
    defer box.end();
    ui.text(c, label, .{ .size = 12, .wrap = true, .color = k.muted });
}
