//! Transcript card for a hosted CodeGraff artifact (`artifact.codegraff.com`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const kit = @import("view_kit.zig");
const icons = @import("icons.zig");
const theme = @import("theme.zig");
const tr = @import("transcript.zig");
const art = @import("artifact_url.zig");
const state = @import("app_artifacts.zig");

fn formatBadge(fmt: []const u8) []const u8 {
    if (std.mem.eql(u8, fmt, "html")) return "HTML";
    if (std.mem.eql(u8, fmt, "svg")) return "SVG";
    if (std.mem.eql(u8, fmt, "markdown")) return "Markdown";
    return "Artifact";
}

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part) void {
    const art_id = p.artifact_id;
    if (!art.isValidId(art_id)) return;
    const title = if (p.text.items.len > 0) p.text.items else "Interactive Artifact";
    const st = a.hosted_artifacts.entry(art_id);
    const vis = state.effectiveVisibility(a, art_id, p.artifact_visibility);
    const is_public = std.mem.eql(u8, vis, "public");
    const loading = if (st) |s| s.loading else false;
    const toggling = if (st) |s| s.toggling else false;
    const err_text = if (st) |s| s.err else null;

    var share_buf: [64]u8 = undefined;
    const share_url = if (is_public)
        (art.publicUrl(&share_buf, art_id) orelse p.artifact_url)
    else
        (art.canonicalUrl(&share_buf, art_id) orelse p.artifact_url);

    ui.key(c, c.print("hosted-artifact-{s}-{s}", .{ e.id, p.id }));
    const card = ui.div(c).column().wFull().minW(0).rounded(12).border(k.border).borderW(1).bg(k.card);
    defer card.end();

    {
        const row = ui.div(c).row().wFull().itemsCenter().justifyBetween().gap(10).px(16).py(12);
        defer row.end();
        {
            const left = ui.div(c).row().grow().minW(0).itemsCenter().gap(10);
            defer left.end();
            icons.icon(c, .@"file-code", 18, k.accent, 0);
            {
                const meta = ui.div(c).column().grow().minW(0).gap(2);
                defer meta.end();
                ui.text(c, title, kit.style(c, 13.5, 18, .{ .weight = .semibold, .color = k.text }));
                {
                    const pills = ui.div(c).row().itemsCenter().gap(6);
                    defer pills.end();
                    ui.text(c, formatBadge(p.artifact_format), kit.style(c, 11, 15, .{ .color = k.muted }));
                    ui.text(c, "·", kit.style(c, 11, 15, .{ .color = k.faint }));
                    ui.text(c, if (is_public) "Public" else "Private", kit.style(c, 11, 15, .{ .color = if (is_public) k.success else k.muted }));
                }
            }
        }
        {
            const actions = ui.div(c).row().itemsCenter().gap(6);
            defer actions.end();
            ui.key(c, c.print("art-open-{s}", .{art_id}));
            {
                var b = ui.div(c).row().px(10).py(5).rounded(7).bg(k.solid).itemsCenter().gap(5);
                b = if (loading) b.opacity(0.6) else b.hover(k.solid.alpha(0.88)).control();
                defer b.end();
                ui.text(c, if (loading) "Opening…" else "Open", kit.style(c, 12, 16, .{ .weight = .medium, .color = k.on_solid }));
                if (!loading and b.clicked()) {
                    state.open(a, a.selected orelse "", art_id, title);
                }
            }
            ui.key(c, c.print("art-vis-{s}", .{art_id}));
            {
                var vb = ui.div(c).row().px(9).py(5).rounded(7).border(k.border).borderW(1).itemsCenter();
                vb = if (toggling) vb.opacity(0.55) else vb.hover(k.ink(0.05)).control();
                defer vb.end();
                const vis_label = if (toggling) "Updating…" else if (is_public) "Make private" else "Share";
                ui.text(c, vis_label, kit.style(c, 11.5, 16, .{ .color = k.text }));
                if (!toggling and vb.clicked()) state.toggleVisibility(a, art_id, vis);
            }
            ui.key(c, c.print("art-copy-{s}-{s}", .{ e.id, art_id }));
            if (kit.copyButton(c, k, &a.view.copy_feedback, .{ .size = 26, .icon = 13, .tip = .{ .text = if (is_public) "Copy public link" else "Copy link" } })) {
                c.clipboard.write(c.clipboard.ctx, share_url);
            }
            ui.key(c, c.print("art-web-{s}", .{art_id}));
            if (kit.iconButton(c, k, .@"arrow-up-right", .{ .size = 26, .icon = 13, .tip = .{ .text = "Open on web" } })) {
                _ = @import("app_browser.zig").open_external_url(share_url);
            }
        }
    }
    if (err_text) |why| {
        const eb = ui.div(c).row().wFull().px(16).pb(10);
        defer eb.end();
        ui.text(c, why, kit.style(c, 11.5, 16, .{ .color = k.danger, .wrap = true }));
    }
}
