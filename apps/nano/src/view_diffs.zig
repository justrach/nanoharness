//! A checkout's diff, as the changes pane draws it (crates/ui/src/changes.rs):
//! the scope (working tree, branch, latest turn), discard and fold-all, a
//! summary ("3 Uncommitted changes  +12 −4"), then per file a header that
//! folds it, its notices, hunk headers, and lines with both numbers, a
//! marker and the code, tinted where added or removed.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const file_icons = @import("file_icons.zig");
const kit = @import("view_kit.zig");
const panels = @import("app_panels.zig");
const diff = @import("diff.zig");
const highlight = @import("highlight.zig");
const host_view = @import("view_host.zig");
const App = @import("app.zig").App;

pub fn diffs(c: *ui.Context, a: *App, k: theme.Colors) void {
    toolbar(c, a, k);
    const p = &a.panels;
    if (p.diff_error) |e| return centered(c, k, panels.friendlyDiffError(e));
    const d = p.diff orelse {
        if (p.diff_loading) return centered(c, k, "Preparing diff…");
        if (a.selected) |sel| if (a.findChat(sel)) |ch| if (ch.source_unavailable) {
            return centered(c, k, panels.not_git_notice);
        };
        return centered(c, k, "No diff yet");
    };
    summary(c, a, k, d);
    if (d.files.len == 0) return centered(c, k, switch (p.scope) {
        .workingTree => "No uncommitted changes",
        .branch => c.print("No changes vs {s}", .{p.base_ref}),
        .turn => "No changes this turn",
    });
    {
        const panel_w = if (a.view.chrome.host_width > 0) a.view.chrome.host_width else host_view.width;
        const viewport = ui.div(c).column().wFull().grow().h(0).clip();
        defer viewport.end();
        const scroll_at = c.nodes.items.len;
        ui.key(c, "diffs-scroll");
        ui.scroll(c, .{ .grow = 1, .width = .fill });
        const scroll_id = c.node(@intCast(scroll_at)).id;
        const scroll_y = c.scroll.get(scroll_id) orelse 0;
        var sticky_file: ?*const diff.File = null;
        var block_top: f32 = 0;
        for (d.files, 0..) |*f, i| {
            const sep_h: f32 = if (i > 0) 1 else 0;
            const folded = a.panels.folded.contains(f.path);
            const est_h = fileBlockHeight(f, folded, panel_w, c);
            if (!folded and scroll_y > block_top + sep_h + 2 and scroll_y < block_top + sep_h + est_h - 38) {
                sticky_file = f;
            }
            block_top += sep_h + est_h;
            ui.key(c, c.print("df-{s}", .{f.path}));
            fileBlock(c, a, k, f, i == 0, panel_w);
        }
        ui.end(c);
        if (sticky_file) |sf| {
            ui.key(c, "diffs-sticky-header");
            const pin = ui.div(c).absolute().offset(0, 0).wFull().layer(1).column();
            defer pin.end();
            fileHeader(c, a, k, sf, false, panel_w, true);
        }
    }
    if (p.scope == .workingTree and !d.truncated) reviewFooter(c, a, k);
}

/// GPUI's footer under a working-tree diff (`render_review_footer`): the
/// review is done. Undo asks first, as the toolbar's discard does, and
/// Keep changes closes the pane: the edits are on disk already.
pub const review_note = "Undo reverts every uncommitted file.";
pub const review_undo = "Undo all changes";

fn reviewFooter(c: *ui.Context, a: *App, k: theme.Colors) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    ui.key(c, "changes-review");
    const bar = ui.div(c).row().wFull().px(12).py(8).gap(8).itemsCenter();
    defer bar.end();
    {
        const note = ui.div(c).column().grow().w(0).clip();
        defer note.end();
        const panel_w = if (a.view.chrome.host_width > 0) a.view.chrome.host_width else host_view.width;
        kit.ellipsisText(c, review_note, .{ .size = 11, .color = k.muted }, @max(40, panel_w - 260));
    }
    {
        const undo = ui.div(c).row().px(12).py(6).rounded(8).hover(k.ink(0.06));
        defer undo.end();
        if (undo.clicked()) a.panels.discard_confirm = true;
        ui.text(c, review_undo, .{ .size = 13, .color = if (undo.hovered()) k.text else k.muted });
    }
    {
        var keep = ui.div(c).row().px(12).py(6).rounded(8).bg(k.solid);
        if (keep.hovered()) keep = keep.opacity(0.9);
        defer keep.end();
        if (keep.clicked()) a.panels.host_open = false;
        ui.text(c, "Keep changes", .{ .size = 13, .weight = .medium, .color = k.on_solid });
    }
}

fn toolbar(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.panels;
    const bar = ui.div(c).row().wFull().h(38).px(8).gap(4).itemsCenter().bg(k.ink(0.015));
    defer bar.end();
    {
        var dd = ui.div(c).row().h(24).px(8).gap(6).itemsCenter().rounded(6).bg(k.wash(0.05)).hover(k.wash(0.14));
        if (p.scope_menu) dd = dd.bg(k.wash(0.14));
        defer dd.end();
        if (dd.clicked()) p.scope_menu = !p.scope_menu;
        if (c.rects.get(c.node(dd.index).id)) |r| p.scope_anchor = r;
        ui.text(c, p.scope.label(), .{ .size = 12, .color = k.text });
        icons.icon(c, .@"alt-arrow-down", 12, k.muted, 0);
    }
    if (p.scope == .branch) {
        ui.text(c, "HEAD", .{ .size = 11.5, .mono = true, .color = k.muted });
        icons.icon(c, .@"arrow-right", 12, k.faint, 0);
        ui.text(c, p.base_ref, .{ .size = 11.5, .mono = true, .color = k.text });
    }
    ui.spacer(c);
    const clean = if (p.diff) |d| d.files.len == 0 or d.truncated else true;
    // The footer's "Undo all changes", as an icon: the same name.
    if (p.scope == .workingTree and kit.iconButton(c, k, .@"trash-bin-minimalistic", .{ .icon = 14, .disabled = clean, .tip = .{ .text = review_undo } }))
        p.discard_confirm = true;
    if (kit.iconButton(c, k, .@"fold-vertical", .{ .icon = 14, .tip = .{ .text = if (anyOpen(a)) "Collapse all files" else "Expand all files" } })) foldAll(a);
}

/// Whether any file of the diff is unfolded: the fold button collapses
/// them all, else expands them all.
fn anyOpen(a: *const App) bool {
    const d = a.panels.diff orelse return false;
    for (d.files) |f| if (!a.panels.folded.contains(f.path)) return true;
    return false;
}

fn foldAll(a: *App) void {
    const d = a.panels.diff orelse return;
    const any_open = anyOpen(a);
    for (d.files) |f| {
        if (a.panels.folded.contains(f.path) != any_open) panels.toggleFold(a, f.path);
    }
}

fn summary(c: *ui.Context, a: *App, k: theme.Colors, d: panels.Diff) void {
    const p = &a.panels;
    const strip = ui.div(c).row().wFull().h(38).px(16).gap(8).itemsCenter();
    defer strip.end();
    const n = d.files.len;
    const s = if (n == 1) "" else "s";
    ui.text(c, switch (p.scope) {
        .workingTree => c.print("{d} Uncommitted change{s}", .{ n, s }),
        .branch => c.print("{d} Changed file{s} vs {s}", .{ n, s, p.base_ref }),
        .turn => c.print("{d} Changed file{s} this turn", .{ n, s }),
    }, .{ .size = 12, .color = k.muted });
    ui.text(c, c.print("+{d}", .{d.additions}), .{ .size = 11, .mono = true, .color = k.diff_add });
    ui.text(c, c.print("−{d}", .{d.deletions}), .{ .size = 11, .mono = true, .color = k.diff_del });
    ui.spacer(c);
    if (d.truncated) {
        const chip = ui.div(c).row().px(6).py(2).rounded(4).bg(k.warning.alpha(0.08));
        defer chip.end();
        ui.text(c, "Partial snapshot", .{ .size = 10, .color = k.warning.alpha(0.75) });
    }
}

fn fileHeader(c: *ui.Context, a: *App, k: theme.Colors, f: *const diff.File, folded: bool, panel_w: f32, sticky: bool) void {
    const surface = if (sticky) k.composer else k.ink(0.025);
    const wrap = ui.div(c).column().wFull();
    defer wrap.end();
    {
        var h = ui.div(c).row().wFull().h(38).px(12).gap(8).itemsCenter().bg(surface).hover(k.ink(0.05)).control();
        if (sticky) h = h.rounded(6);
        defer h.end();
        if (h.clicked()) panels.toggleFold(a, f.path);
        icons.icon(c, if (folded) .@"alt-arrow-right" else .@"alt-arrow-down", 13, k.muted.alpha(0.7), 0);
        file_icons.icon(c, f.path, false, k.dark, 14);
        kit.fadeText(c, f.path, .{ .size = 12, .mono = true, .color = k.text.alpha(0.85) }, @max(60, panel_w - 180));
        if (f.binary) ui.text(c, "BIN", .{ .size = 10, .color = k.faint });
        ui.spacer(c);
        ui.text(c, c.print("+{d}", .{f.additions}), .{ .size = 11, .mono = true, .color = k.diff_add });
        ui.text(c, c.print("−{d}", .{f.deletions}), .{ .size = 11, .mono = true, .color = k.diff_del });
    }
    if (sticky) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
}

fn fileContentWidth(c: *ui.Context, f: *const diff.File, panel_w: f32) f32 {
    var widest: u32 = 1;
    var code_width: f32 = 0;
    var header_width: f32 = 0;
    for (f.hunks) |h| {
        header_width = @max(header_width, c.text.width(h.header, .{ .size = 11, .mono = true }) + 24);
        for (h.lines) |l| {
            widest = @max(widest, l.old orelse 0, l.new orelse 0);
            code_width = @max(code_width, c.text.width(l.text, .{ .size = 12, .mono = true }));
        }
    }
    const digits: f32 = @floatFromInt(std.fmt.count("{d}", .{widest}));
    const gutter = @max(36, digits * 6.6 + 14);
    return @max(panel_w, @max(header_width, code_width + 2 * gutter + 3 + 28 + 12 + 16));
}

fn fileBlockHeight(f: *const diff.File, folded: bool, panel_w: f32, c: *ui.Context) f32 {
    var h: f32 = 38;
    if (folded) return h;
    if (f.added) h += 24;
    if (f.deleted) h += 24;
    if (f.old_path != null) h += 24;
    if (f.mode != null) h += 24;
    if (f.binary) h += 24;
    for (f.hunks) |hunk| {
        h += 28 + @as(f32, @floatFromInt(hunk.lines.len)) * 21;
    }
    if (fileContentWidth(c, f, panel_w) > panel_w + 0.5) h += 8;
    return h;
}

fn fileBlock(c: *ui.Context, a: *App, k: theme.Colors, f: *const diff.File, first: bool, panel_w: f32) void {
    const folded = a.panels.folded.contains(f.path);
    if (!first) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.wash(0.04) }, .none, null);
    fileHeader(c, a, k, f, folded, panel_w, false);
    if (folded) return;
    if (f.added) notice(c, k, "New file");
    if (f.deleted) notice(c, k, "Deleted file");
    if (f.old_path) |old| notice(c, k, c.print("Renamed from {s}", .{old}));
    if (f.mode) |m| notice(c, k, c.print("Mode changed to {s}", .{m}));
    if (f.binary) notice(c, k, "Binary file — contents not shown");
    const content_w = fileContentWidth(c, f, panel_w);
    if (content_w > panel_w + 0.5) {
        _ = c.open(.{ .direction = .column, .width = .fill, .scroll_x = true, .padding = .{ .bottom = 8 } }, "diff-scroll-x");
        defer c.end();
        const inner = ui.div(c).column().w(content_w);
        defer inner.end();
        body(c, k, f);
    } else {
        body(c, k, f);
    }
}

/// A file's hunks: each header, then its lines with both numbers, the
/// marker and the code (`render_file_body`). An opened edit in the
/// transcript draws its diff with this too.
pub fn body(c: *ui.Context, k: theme.Colors, f: *const diff.File) void {
    const lang = host_view.langOf(f.path);
    var widest: u32 = 1;
    for (f.hunks) |h| for (h.lines) |l| {
        widest = @max(widest, l.old orelse 0, l.new orelse 0);
    };
    const digits: f32 = @floatFromInt(std.fmt.count("{d}", .{widest}));
    const gutter = @max(36, digits * 6.6 + 14);
    for (f.hunks) |h| {
        const hr = ui.div(c).row().wFull().h(28).px(12).itemsCenter().bg(k.accent.alpha(if (k.dark) 0.08 else 0.07));
        ui.text(c, h.header, .{ .size = 11, .mono = true, .color = k.faint });
        hr.end();
        var in_block: highlight.State = .{};
        for (h.lines) |l| line(c, k, l, gutter, lang, &in_block);
    }
}

fn line(c: *ui.Context, k: theme.Colors, l: diff.Line, gutter: f32, lang: []const u8, in_block: *highlight.State) void {
    const tint: ?ui.Color = switch (l.kind) {
        .add => k.diff_add,
        .del => k.diff_del,
        else => null,
    };
    var r = ui.div(c).row().wFull().h(21).itemsCenter();
    if (tint) |t| r = r.bg(t.alpha(0.055));
    defer r.end();
    _ = c.leaf(.{ .width = .{ .px = 3 }, .height = .{ .px = 21 }, .background = if (tint) |t| t.alpha(0.55) else null }, .none, null);
    const num = struct {
        fn n(cx: *ui.Context, w: f32, v: ?u32, color: ui.Color) void {
            const g = ui.div(cx).row().w(w).h(21).pr(8).justifyEnd().itemsCenter();
            defer g.end();
            if (v) |x| ui.text(cx, cx.print("{d}", .{x}), .{ .size = 11, .mono = true, .color = color });
        }
    }.n;
    const faint = k.faint.alpha(0.8);
    num(c, gutter, l.old, if (l.kind == .del) k.diff_del.alpha(0.9) else faint);
    num(c, gutter, l.new, if (l.kind == .add) k.diff_add.alpha(0.9) else faint);
    {
        const m = ui.div(c).row().w(28).h(21).center();
        defer m.end();
        const mark, const mc = switch (l.kind) {
            .add => .{ "+", k.diff_add },
            .del => .{ "−", k.diff_del },
            .context => .{ "·", k.faint.alpha(0.5) },
            .meta => .{ "", k.faint },
        };
        ui.text(c, mark, .{ .size = 12, .mono = true, .color = mc });
    }
    // One line each, cut at the pane's edge (wrapping is off by default).
    const code = ui.div(c).row().grow().w(0).h(21).pl(12).itemsCenter().clip();
    defer code.end();
    if (l.kind == .meta) return ui.text(c, l.text, .{ .size = 10.5, .italic = true, .color = k.faint });
    const pal = k.syntax;
    ui.richText(c, if (l.text.len == 0) " " else l.text, highlight.line(c.alloc(), l.text, lang, pal, in_block), kit.style(c, 12, 21, .{ .mono = true, .color = k.text }));
}

fn notice(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const r = ui.div(c).row().wFull().h(24).px(16).itemsCenter();
    defer r.end();
    ui.text(c, text, .{ .size = 11, .color = k.faint });
}

fn centered(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const box = ui.div(c).column().wFull().grow().center();
    defer box.end();
    ui.text(c, text, .{ .size = 12, .color = k.muted });
}

/// The scope's menu and the discard question, over the window.
pub fn overlays(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.panels;
    if (p.scope_menu) if (p.scope_anchor) |r| {
        {
            const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(4);
            defer back.end();
            if (back.clicked()) p.scope_menu = false;
        }
        const m = kit.shadowLg(ui.div(c).fixed().offset(r.x, r.y + r.h + 4).w(180).layer(5).column().p(4).gap(1)
            .bg(k.composer).border(k.border).borderW(1).rounded(10));
        defer m.end();
        for (std.enums.values(panels.Scope)) |s| {
            ui.key(c, @tagName(s));
            var row = ui.div(c).row().wFull().h(30).px(8).itemsCenter().rounded(7).hover(k.hover);
            if (s == p.scope) row = row.bg(k.selected);
            defer row.end();
            if (row.clicked()) panels.setScope(a, s);
            ui.text(c, s.label(), .{ .size = 13, .color = k.text });
        }
    };
    if (p.discard_confirm) {
        {
            const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(6).bg(.{ .a = 0.35 });
            defer scrim.end();
            if (scrim.clicked()) p.discard_confirm = false;
        }
        const w: f32 = 360;
        const d = kit.shadowLg(ui.div(c).fixed().offset((c.size.w - w) / 2, c.size.h * 0.32).w(w).layer(7).column().p(20).gap(8)
            .bg(k.composer).border(k.wash(0.10)).borderW(1).rounded(16));
        defer d.end();
        ui.text(c, "Discard working tree changes?", .{ .size = 15, .weight = .semibold, .color = k.text });
        ui.text(c, "Discard all uncommitted changes in this working tree? This can’t be undone.", kit.style(c, 13, 19, .{ .wrap = true, .color = k.muted }));
        const foot = ui.div(c).row().wFull().pt(8).gap(8).justifyEnd();
        defer foot.end();
        const q = @import("view_question.zig");
        if (q.button(c, k, "Cancel", false, true)) p.discard_confirm = false;
        var danger = ui.div(c).row().px(12).py(6).rounded(8).bg(k.danger);
        defer danger.end();
        if (danger.clicked()) panels.discard(a);
        ui.text(c, "Discard changes", .{ .size = 13, .weight = .medium, .color = .{ .r = 1, .g = 1, .b = 1 } });
    }
}
