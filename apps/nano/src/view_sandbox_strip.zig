//! The "Cloud sandbox running" strip (shell/cloud_sandbox_strip.rs). A
//! Codegraff cloud sandbox started from Harness keeps running, billed per
//! second, until it is turned off. While one runs the strip stays in the
//! sidebar's foot above the account badge, and in the settings sidebar
//! above Back: a live dot, what it costs or why it will pause, and a
//! one-click Turn off (a pause: memory and files are kept). Its label opens
//! Settings › Accounts, where the card lives. It reads the list the app
//! keeps (app_sandboxes.zig), so it is hidden when signed out, where the
//! feature is off, and when nothing runs.
//!
//! With the sidebar closed, the window toolbar reserves a slot for the
//! cloud status and Turn off without covering tabs or pane headers.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const sandboxes = @import("sandboxes.zig");
const state = @import("app_sandboxes.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;

const st = @import("view_settings_accounts_rows.zig").st;

/// Settings › Accounts (`open_settings(SettingsSection::Agents)`).
fn openCard(a: *App) void {
    @import("view_settings.zig").open(a);
    a.settings.setSection(.agents);
    a.redraw();
}

/// "Turn off", "Turn off all", or "Turning off…" while the pause is under way.
fn turnOffLabel(a: *const App, running: usize) []const u8 {
    if (a.cloud_sandboxes.turning_off > 0) return sandboxes.turn_off[1];
    return if (running == 1) sandboxes.turn_off[0] else "Turn off all";
}

/// Its width, for the room left beside it.
fn turnOffWidth(c: *ui.Context, label: []const u8) f32 {
    return 2 * 9 + c.text.width(label, .{ .size = 11, .weight = .medium });
}

/// The button (`cloud_turn_off_button`): pauses every one of `ids`; dimmed,
/// and in place, while it works.
fn turnOff(c: *ui.Context, a: *App, k: theme.Colors, ids: []const []const u8) void {
    const busy = a.cloud_sandboxes.turning_off > 0;
    // GPUI's px 8, py 3 and a 1-point border, which nanoui draws inside.
    var b = ui.div(c).row().px(9).py(4).rounded(6).border(k.border).borderW(1).bg(k.raised);
    b = if (busy) b.opacity(0.6) else b.hover(k.raised.mix(k.text, 0.06));
    b = tip.on(b, k, .{ .text = sandboxes.turn_off_hint, .delay = tip.quick });
    defer b.end();
    ui.text(c, turnOffLabel(a, ids.len), st(c, 11, .{ .weight = .medium, .color = k.text }));
    if (!busy and b.clicked()) state.turnOff(a, ids);
}

/// What runs, when anything does.
fn summary(c: *ui.Context, a: *App) ?sandboxes.Summary {
    const l = state.shown(a) orelse return null;
    return sandboxes.runningSummary(c.alloc(), l, a.nowMs()) catch null;
}

fn statusLabel(s: sandboxes.Sandbox) []const u8 {
    if (std.mem.eql(u8, s.state, "running")) {
        if (s.renew_error) |e| if (std.mem.trim(u8, e, " \t\n").len > 0) return "Needs attention";
        return "Running";
    }
    if (std.mem.eql(u8, s.state, "starting")) return "Starting…";
    if (std.mem.eql(u8, s.state, "stopping")) return "Pausing…";
    if (std.mem.eql(u8, s.state, "paused")) return "Paused";
    if (std.mem.eql(u8, s.state, "error")) return "Needs attention";
    return "Status unavailable";
}

fn statusTone(label: []const u8, k: theme.Colors) ui.Color {
    if (std.mem.eql(u8, label, "Running")) return k.success;
    if (std.mem.eql(u8, label, "Needs attention")) return k.warning;
    if (std.mem.eql(u8, label, "Starting…") or std.mem.eql(u8, label, "Pausing…")) return k.accent;
    return k.muted;
}

/// Named cloud computers in the macOS sidebar (`render_cloud_sandbox_strip`).
pub fn computers(c: *ui.Context, a: *App, k: theme.Colors) void {
    const l = state.shown(a) orelse return;
    if (!l.enabled or l.sandboxes.len == 0) return;
    const outer = ui.div(c).column().wFull();
    defer outer.end();
    if (l.sandboxes.len > 1) {
        const hd = ui.div(c).row().wFull().px(18).pt(8).itemsCenter().justifyBetween();
        defer hd.end();
        ui.text(c, "Computers", st(c, 10.5, .{ .color = k.muted }));
        ui.text(c, c.print("{d}", .{l.sandboxes.len}), st(c, 10.5, .{ .color = k.muted }));
    }
    const cards = ui.div(c).column().wFull().px(8).pt(8).pb(3).gap(5);
    defer cards.end();
    const text_w = sidebar.widthOf(a) - 16 - 20 - 18 - 18 - 13;
    for (l.sandboxes) |sb| {
        ui.key(c, c.print("cloud-computer-{s}", .{sb.id}));
        var r = ui.div(c).row().wFull().h(46).px(10).py(6).rounded(8).gap(9).itemsCenter().hover(k.ink(0.065));
        if (l.sandboxes.len == 1) r = r.bg(k.ink(0.025));
        defer r.end();
        icons.icon(c, if (sandboxes.isTemporary(sb)) .cloud else .monitor, 18, k.muted, 0);
        {
            const col = ui.div(c).column().grow().w(0).gap(1);
            defer col.end();
            kit.ellipsisText(c, sandboxes.title(sb), .{ .size = 12.5, .line_height = 12.5 * 1.2, .weight = theme.ui_medium_weight, .color = k.text }, text_w);
            const sub = ui.div(c).row().gap(5).itemsCenter();
            defer sub.end();
            const label = statusLabel(sb);
            kit.dot(c, 5, statusTone(label, k));
            const live = std.mem.eql(u8, sb.state, "running") or std.mem.eql(u8, sb.state, "starting");
            const line = if (live and sb.price_per_hour_micro_usd != null)
                c.print("{s} · {s}", .{ label, @import("runners.zig").formatRate(c.alloc(), sb.price_per_hour_micro_usd.?) catch "" })
            else
                label;
            kit.ellipsisText(c, line, .{ .size = 10.5, .line_height = 10.5 * 1.2, .color = k.muted }, text_w - 10);
        }
        icons.icon(c, .@"alt-arrow-right", 13, k.faint, 0);
        if (r.clicked()) openCard(a);
    }
}

/// The strip (`render_cloud_sandbox_strip`), 8 in from the sidebar's sides
/// and 4 below what's above it; `pb` under it.
pub fn strip(c: *ui.Context, a: *App, k: theme.Colors, pb: f32) void {
    const sum = summary(c, a) orelse return;
    const tone = if (sum.warning) k.warning else k.accent;
    const w: f32 = sidebar.width - 2 * 8;
    const pad = ui.div(c).column().wFull().px(8).pt(4).pb(pb);
    defer pad.end();
    ui.key(c, "cloud-sandbox-strip");
    // GPUI's px 8, py 4 and a 1-point border, which nanoui draws inside.
    const s = ui.div(c).row().w(w).px(9).py(5).gap(8).itemsCenter().rounded(6)
        .bg(if (sum.warning) k.warning.alpha(0.12) else k.accent_wash).border(tone.alpha(0.3)).borderW(1);
    defer s.end();
    const button_w: f32 = if (sum.running_ids.len > 0) 8 + turnOffWidth(c, turnOffLabel(a, sum.running_ids.len)) else 0;
    const text_w = w - 2 * 9 - button_w;
    {
        const open = tip.on(ui.div(c).column().grow().w(0).gap(1), k, .{
            .text = sandboxes.compactTooltip(c.alloc(), sum) catch "",
            .delay = tip.quick,
        });
        defer open.end();
        {
            const top = ui.div(c).row().gap(6).itemsCenter();
            defer top.end();
            kit.dot(c, 6, tone);
            kit.ellipsisText(c, sum.label, st(c, 11, .{ .weight = .medium, .color = k.text }), text_w - 12);
        }
        // One line at rest (the detail is in the tooltip); a problem gets
        // its own line.
        if (sum.warning) {
            const d = ui.div(c).row().pl(12).gap(6).itemsCenter();
            defer d.end();
            kit.ellipsisText(c, sum.detail, st(c, 10.5, .{ .color = k.warning }), text_w - 12);
            if (std.mem.indexOf(u8, sum.detail, "Out of credit") != null) {
                ui.key(c, "cloud-sandbox-add-credits");
                var ab = ui.div(c).row().px(5).py(1).rounded(4).hover(k.warning.alpha(0.18));
                defer ab.end();
                ui.text(c, "Add credits", st(c, 10.5, .{ .weight = .medium, .color = k.text }));
                if (ab.clicked()) {
                    _ = nanoui.shell.openUrl("https://codegraff.com/dashboard/billing");
                    return;
                }
            }
        }
        if (open.clicked()) openCard(a);
    }
    if (sum.running_ids.len > 0) turnOff(c, a, k, sum.running_ids);
}

pub const toolbar_width: f32 = 140;

pub fn toolbarVisible(a: *const App) bool {
    if (a.view.sidebar_open or a.view.settings_open) return false;
    const list = state.shown(a) orelse return false;
    for (list.sandboxes) |sb| if (sandboxes.live(sb)) return true;
    return false;
}

/// Inline window action, not a floating card. A stable width keeps adjacent
/// controls put while the button changes to “Turning off…”.
pub fn toolbar(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sum = summary(c, a) orelse return;
    const tone = if (sum.warning) k.warning else k.accent;
    ui.key(c, "cloud-sandbox-chip");
    const lane = ui.div(c).row().size(toolbar_width, 28).gap(4).itemsCenter().justifyEnd();
    defer lane.end();
    {
        // `compact_tooltip`: what runs and what it costs.
        const open = tip.on(ui.div(c).row().px(6).h(26).gap(4).itemsCenter().rounded(6).hover(k.hover).control(), k, .{
            .text = sandboxes.compactTooltip(c.alloc(), sum) catch "",
            .delay = tip.quick,
        });
        defer open.end();
        kit.dot(c, 6, tone);
        icons.icon(c, .cloud, 13, k.muted, 0);
        if (@import("control_behavior.zig").activate(c, open, k, "Manage cloud sandboxes", true, false)) openCard(a);
    }
    if (sum.running_ids.len > 0) turnOff(c, a, k, sum.running_ids);
}
