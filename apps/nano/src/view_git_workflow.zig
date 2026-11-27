//! Native staged/unstaged controls, with a separate explicit confirmation
//! before committing the index or publishing to an existing upstream.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const flow = @import("app_git_workflow.zig");
const display = @import("github_display.zig");

/// One height for every file row: a 32-point button and 2 above and below.
pub const row_h: f32 = 36;

pub fn view(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.panels.git_workflow;
    {
        const bar = ui.div(c).row().wFull().h(48).px(16).gap(8).itemsCenter();
        defer bar.end();
        ui.text(c, "Git changes", .{ .size = kit.text_title, .weight = .medium, .color = k.text });
        ui.spacer(c);
        if (kit.actionButton(c, k, "Git history", .{ .icon = .@"arrow-left", .enabled = s.pending == null })) {
            s.open = false;
            @import("app_git.zig").load(a, 0);
        }
        if (kit.actionButton(c, k, "Refresh", .{ .icon = .refresh, .enabled = s.pending == null })) flow.load(a);
    }
    kit.hairline(c, k);
    if (s.error_text) |text| note(c, k, text, true);
    if (s.notice) |text| note(c, k, text, false);
    const snap = s.snapshot orelse return note(c, k, if (s.pending != null) "Loading Git changes…" else "Open a project session, then refresh its Git changes.", false);
    const page = snap.page;
    {
        const heading = ui.div(c).column().wFull().px(16).pt(12).pb(4).gap(4);
        defer heading.end();
        ui.text(c, page.branch orelse "Detached HEAD", .{ .size = kit.text_body, .mono = true, .weight = .medium, .color = k.text, .wrap = true });
        if (page.blockedReason) |why| warnBox(c, k, why);
        if (page.upstream) |upstream| {
            ui.text(c, c.print("Upstream: {s}/{s}", .{ upstream.remote, upstream.branch }), .{ .size = kit.text_caption, .color = k.muted, .wrap = true });
        } else ui.text(c, "No push destination. Set an upstream in your terminal first.", .{ .size = kit.text_caption, .color = k.muted, .wrap = true });
        ui.text(c, "Only selected files are staged. Commit uses the index, not all working changes.", .{ .size = kit.text_caption, .color = k.muted, .wrap = true });
    }
    const enabled = flow.canAct(a) and s.confirm == null;
    {
        const list = ui.div(c).column().wFull().grow().h(0).px(16).scrollY();
        defer list.end();
        section(c, a, k, page, true, enabled);
        section(c, a, k, page, false, enabled);
    }
    kit.hairline(c, k);
    {
        const footer = ui.div(c).column().wFull().px(16).py(12).gap(8);
        defer footer.end();
        if (s.pending != null) {
            ui.text(c, if (s.action_kind != null) "Applying Git action…" else "Refreshing…", .{ .size = kit.text_body, .color = k.muted });
            ui.text(c, "Do not retry while the host is working.", .{ .size = kit.text_caption, .color = k.muted });
        } else if (s.confirm) |kind| {
            if (kind == .commit) {
                ui.text(c, c.print("Commit {d} staged file{s}?", .{ page.stagedCount(), if (page.stagedCount() == 1) "" else "s" }), .{ .size = kit.text_title, .weight = .medium, .color = k.text });
                ui.text(c, s.message.text(), .{ .size = kit.text_body, .color = k.text, .wrap = true });
                ui.text(c, "Git hooks and your configured author identity apply. Unstaged edits stay untouched.", .{ .size = kit.text_caption, .color = k.muted, .wrap = true });
            } else {
                const upstream = page.upstream orelse return;
                ui.text(c, c.print("Push {s} to {s}/{s}?", .{ page.branch orelse "", upstream.remote, upstream.branch }), .{ .size = kit.text_title, .weight = .medium, .color = k.text, .wrap = true });
                const sha = page.headSha orelse "";
                ui.text(c, c.print("Publish committed history through {s}. No force push; working files are not uploaded.", .{sha[0..@min(12, sha.len)]}), .{ .size = kit.text_caption, .color = k.muted, .wrap = true });
            }
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            if (kit.actionButton(c, k, if (kind == .commit) "Confirm commit" else "Confirm push", .{ .kind = .primary, .enabled = if (kind == .commit) flow.canCommit(a) else flow.canPush(a) })) flow.confirm(a);
            if (kit.actionButton(c, k, "Cancel", .{})) flow.cancel(a);
        } else {
            ui.text(c, "Commit message", .{ .size = kit.text_body, .weight = .medium, .color = k.muted });
            const box = ui.div(c).row().wFull().h(kit.hit_target).px(10).itemsCenter().border(k.border).borderW(1).rounded(kit.radius_control);
            {
                defer box.end();
                ui.key(c, "git-commit-message");
                _ = ui.textField(c, &s.message, .{ .placeholder = "Describe the staged changes", .placeholder_color = k.faint, .bare = true, .width = .fill, .size = kit.text_body });
            }
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            if (kit.actionButton(c, k, "Commit staged…", .{ .kind = .primary, .enabled = flow.canCommit(a) })) flow.arm(a, .commit);
            ui.spacer(c);
            if (kit.actionButton(c, k, "Push…", .{ .enabled = flow.canPush(a) })) flow.arm(a, .push);
        }
    }
}

fn section(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, staged: bool, enabled: bool) void {
    ui.key(c, if (staged) "staged-files" else "unstaged-files");
    var count: usize = 0;
    for (page.files) |file| if (if (staged) file.staged() else file.unstaged()) {
        count += 1;
    };
    const section_box = ui.div(c).column().wFull().pt(12).pb(4);
    defer section_box.end();
    {
        const head = ui.div(c).row().wFull().h(24).itemsCenter();
        defer head.end();
        ui.text(c, c.print("{s} ({d})", .{ if (staged) "Staged" else "Unstaged", count }), .{ .size = kit.text_body, .weight = .medium, .tabular = true, .color = k.muted });
    }
    if (count == 0) {
        const empty = ui.div(c).row().wFull().h(row_h).itemsCenter();
        defer empty.end();
        ui.text(c, if (staged) "Nothing staged." else "No unstaged changes.", .{ .size = kit.text_caption, .color = k.faint });
    }
    const st: ui.TextStyle = .{ .size = kit.text_body, .line_height = 16, .mono = true, .color = k.text };
    for (page.files) |file| {
        if (!(if (staged) file.staged() else file.unstaged())) continue;
        ui.key(c, file.path);
        const row = ui.div(c).row().wFull().h(row_h).gap(8).itemsCenter();
        defer row.end();
        const letter = if (staged) file.indexStatus else file.worktreeStatus;
        // The letter and the path share one line box, so they share a
        // baseline; the letter keeps a fixed column.
        {
            const cell = ui.div(c).row().w(12).itemsCenter();
            defer cell.end();
            var letter_st = st;
            letter_st.weight = .medium;
            letter_st.color = statusColor(k, letter);
            ui.text(c, letter, letter_st);
        }
        const name = ui.div(c).row().grow().w(0).itemsCenter().clip();
        {
            defer name.end();
            const room = if (c.rects.get(name.id())) |r| r.w else @max(80, a.view.chrome.host_width - 160);
            if (c.rects.get(name.id()) == null) c.animationFrame();
            const buf = c.alloc().alloc(u8, file.path.len + 3) catch continue;
            ui.text(c, display.middleTruncate(buf, file.path, room, Measure{ .c = c, .st = st }), st);
        }
        if (kit.actionButton(c, k, if (staged) "Unstage" else "Stage", .{ .kind = .quiet, .enabled = enabled })) flow.fileAction(a, file.path, !staged);
    }
}

/// `github_display.middleTruncate`'s ruler: the row's own face.
const Measure = struct {
    c: *ui.Context,
    st: ui.TextStyle,
    pub fn width(m: Measure, s: []const u8) f32 {
        return m.c.text.width(s, m.st);
    }
};

fn statusColor(k: theme.Colors, letter: []const u8) ui.Color {
    return switch (display.fileTone(letter)) {
        .added => k.diff_add,
        .deleted => k.diff_del,
        .changed => kit.chipColors(k, .warning).ink,
        .untracked => k.muted,
    };
}

fn note(c: *ui.Context, k: theme.Colors, text: []const u8, warning: bool) void {
    const wrap = ui.div(c).column().wFull().px(16).py(if (warning) 8 else 12);
    defer wrap.end();
    if (warning) warnBox(c, k, text) else ui.text(c, text, .{ .size = kit.text_body, .color = k.muted, .wrap = true });
}

/// A warning as a soft tint behind the darker hue, like a chip.
fn warnBox(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const colors = kit.chipColors(k, .warning);
    const box = ui.div(c).column().wFull().px(12).py(8).rounded(kit.radius_control).bg(colors.fill);
    defer box.end();
    ui.text(c, text, .{ .size = kit.text_body, .color = colors.ink, .wrap = true });
}
