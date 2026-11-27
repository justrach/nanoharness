//! A pull request's badge (change_requests.rs `pull_request_badge`): its
//! number in the badge's mono, washed in its state's tone (open success,
//! merged the accent, closed danger; muted when a shared branch's PR is
//! merged or closed, #357), hover deepening it, a click opening the PR,
//! and after 350 ms at rest its card (`ChangeRequestTooltip`). The session
//! footer's is the Composer surface, with the PR glyph; the Sidebar surface
//! is the command palette's results'. And the footer's
//! merge controls beside an open PR (pickers.rs `render_change_request_merge`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const cr = @import("change_requests.zig");
const merging = @import("app_change_requests.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;
const display = @import("github_display.zig");

const phi: f32 = 1.618;

/// `ChangeRequestBadgeSurface`.
pub const Surface = enum { sidebar, composer };

/// `ChangeRequestBadgeTone::color`, through the one state mapping the
/// repository list, detail header and charts use (`github_display.role`).
pub fn toneColor(k: theme.Colors, tone: cr.Tone) ui.Color {
    return kit.roleColor(k, toneRole(tone));
}

pub fn toneRole(tone: cr.Tone) display.Role {
    return display.role(.pull, switch (tone) {
        .open => .open,
        .merged => .merged,
        .closed => .closed,
    });
}

/// The badge's role: the tone's, or muted for a shared branch's settled PR
/// (`render_pull_request_badge`).
pub fn badgeRole(s: cr.Summary, p: cr.Provenance) display.Role {
    return if (p.mutes(s)) .muted else toneRole(cr.toneOf(s.state));
}

/// The badge's colour (`render_pull_request_badge`).
pub fn badgeColor(k: theme.Colors, s: cr.Summary, p: cr.Provenance) ui.Color {
    return kit.roleColor(k, badgeRole(s, p));
}

/// The badge; `interactive` false is the drag preview's
/// (`pull_request_badge_preview`): the same geometry, no hover, card or click.
pub fn badge(c: *ui.Context, k: theme.Colors, s: cr.Summary, p: cr.Provenance, surface: Surface, interactive: bool) void {
    badgeQuery(c, k, s, p, surface, interactive, "");
}

/// `badge` with a search's words washed in its number, as the command
/// palette's results show it (`pull_request_badge_with_query`).
pub fn badgeQuery(c: *ui.Context, k: theme.Colors, s: cr.Summary, p: cr.Provenance, surface: Surface, interactive: bool, query: []const u8) void {
    const m = cr.model(c.alloc(), s);
    const color = badgeColor(k, s, p);
    const composer = surface == .composer;
    var b = ui.div(c).row().h(if (composer) 20 else 16).gap(if (composer) 5 else 0).px(if (composer) 7 else 4)
        .itemsCenter().rounded(if (composer) 6 else 4);
    const hot = interactive and b.hovered();
    b = b.bg(color.alpha(if (hot) 0.16 else 0.08));
    if (interactive) {
        if (comptime @hasDecl(ui.Div, "tooltipWith")) {
            const card = c.alloc().create(Card) catch null;
            if (card) |x| {
                x.* = .{ .k = k, .m = m, .note = p.note(c.alloc(), s) };
                b = b.tooltipWith(@as(*const Card, x), Card.draw, .{
                    .delay = 0.35,
                    .background = k.composer,
                    .border = k.border_strong,
                    .padding = .xy(9, 7),
                    .radius = 6,
                    .max_width = 320,
                });
            }
        }
    }
    defer b.end();
    if (hot) c.cursor_hand = true;
    if (interactive and b.clicked()) _ = nanoui.shell.openUrl(s.url);
    if (composer) icons.icon(c, .@"pull-request", 11, color.alpha(0.85), 0);
    const size: f32 = if (composer) 11 else 10;
    const st: ui.TextStyle = .{ .size = size, .line_height = size * phi, .weight = .medium, .mono = true, .color = if (hot) color else color.alpha(0.85) };
    if (query.len > 0) return kit.highlightText(c, k, m.number, st, c.text.width(m.number, st) + 1, query);
    ui.text(c, m.number, st);
}

/// `ChangeRequestTooltip`: "PR #N · State" in the tone, the title in one
/// cut line, and for a shared branch where it was found.
const Card = struct {
    k: theme.Colors,
    m: cr.Model,
    note: ?[]const u8,

    fn draw(x: *const Card, c: *ui.Context) void {
        const col = ui.div(c).column().gap(3);
        defer col.end();
        const st: ui.TextStyle = .{ .size = 11, .line_height = 11 * phi };
        var head = st;
        head.weight = .medium;
        head.color = toneColor(x.k, x.m.tone);
        ui.text(c, c.print("PR {s} · {s}", .{ x.m.number, x.m.state_label }), head);
        var title = st;
        title.color = x.k.muted;
        kit.ellipsisText(c, x.m.title, title, 320 - 18);
        if (x.note) |n| {
            var note = st;
            note.color = x.k.muted.alpha(0.8);
            note.wrap = true;
            ui.text(c, n, note);
        }
    }
};

/// Where the merge controls sit: the composer footer's 20-point row keeps
/// its quiet chips; a pane uses the panes' 32-point buttons.
pub const MergeSurface = enum { footer, pane };

/// Merge, "Merge #N?" and Cancel, "Merging #N…", then the host's answer;
/// nothing for a PR that isn't open with no merge of it running or answered.
pub fn mergeControls(c: *ui.Context, a: *App, k: theme.Colors, chat: workspace.Chat, s: cr.Summary) void {
    mergeControlsIn(c, a, k, chat, s, .footer);
}

pub fn mergeControlsIn(c: *ui.Context, a: *App, k: theme.Colors, chat: workspace.Chat, s: cr.Summary, surface: MergeSurface) void {
    if (surface == .pane) return paneMergeControls(c, a, k, chat, s);
    const st = &a.change_requests;
    const busy = st.isBusy(chat.id);
    const status = st.statusFor(chat.id);
    const open = s.state == .open;
    if (!open and !busy and status == null) return;
    const armed = st.isArmed(chat.id, s.number);
    const cluster = ui.div(c).row().gap(2).itemsCenter();
    defer cluster.end();
    const small: ui.TextStyle = .{ .size = 11.5, .line_height = 11.5 * phi };
    if (busy) {
        var t = small;
        t.color = k.muted.alpha(0.7);
        const d = ui.div(c).row().px(6);
        defer d.end();
        ui.text(c, c.print("Merging #{d}…", .{s.number}), t);
    } else if (open and armed) {
        if (chip(c, k, c.print("Merge #{d}?", .{s.number}), k.success)) merging.merge(a, chat.id, s.number);
        if (chip(c, k, "Cancel", k.muted)) merging.cancel(a);
    } else if (open) {
        if (chip(c, k, "Merge", k.muted)) merging.arm(a, chat.id, s.number);
    }
    if (!busy) if (status) |v| {
        var t = small;
        t.color = if (v.merged) k.success else k.danger;
        const d = ui.div(c).row().px(6);
        defer d.end();
        kit.ellipsisText(c, v.message, t, 320 - 12);
    };
}

/// The pane's merge controls: Merge as a secondary button; once armed,
/// "Merge #N" with primary weight and Cancel beside it, 8 apart; the
/// host's answer under them with a glyph.
fn paneMergeControls(c: *ui.Context, a: *App, k: theme.Colors, chat: workspace.Chat, s: cr.Summary) void {
    const st = &a.change_requests;
    const busy = st.isBusy(chat.id);
    const status = st.statusFor(chat.id);
    const open = s.state == .open;
    if (!open and !busy and status == null) return;
    const armed = st.isArmed(chat.id, s.number);
    const cluster = ui.div(c).row().gap(8).itemsCenter();
    defer cluster.end();
    if (busy) {
        ui.text(c, c.print("Merging #{d}…", .{s.number}), .{ .size = kit.text_body, .color = k.muted });
    } else if (open and armed) {
        if (kit.actionButton(c, k, c.print("Merge #{d}", .{s.number}), .{ .kind = .primary, .key = "pane-merge-confirm" })) merging.merge(a, chat.id, s.number);
        if (kit.actionButton(c, k, "Cancel", .{ .key = "pane-merge-cancel" })) merging.cancel(a);
    } else if (open) {
        if (kit.actionButton(c, k, "Merge", .{ .key = "pane-merge" })) merging.arm(a, chat.id, s.number);
    }
    if (!busy) if (status) |v| {
        const tone: kit.Tone = if (v.merged) .success else .danger;
        icons.icon(c, if (v.merged) .check else .@"danger-triangle", 12, kit.chipColors(k, tone).ink, 0);
        kit.ellipsisText(c, v.message, .{ .size = kit.text_body, .color = kit.chipColors(k, tone).ink }, 320);
    };
}

/// A merge control: 20 tall, 12-point medium words at 0.75 of `color`,
/// full and on the hover wash under the pointer.
fn chip(c: *ui.Context, k: theme.Colors, text: []const u8, color: ui.Color) bool {
    const b = ui.div(c).row().h(20).px(7).itemsCenter().rounded(6).hover(k.hover);
    defer b.end();
    const hot = b.hovered();
    if (hot) c.cursor_hand = true;
    ui.text(c, text, .{ .size = 12, .line_height = 12 * phi, .weight = .medium, .color = if (hot) color else color.alpha(0.75) });
    return b.clicked();
}
