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
const computer = @import("app_computer.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;

const st = @import("view_settings_accounts_rows.zig").st;
const Allocator = std.mem.Allocator;

pub const SpriteMood = enum { running, starting, attention, paused };

/// First given name for personalizing sidebar & card computer titles (`owner_first_name`).
/// Falls back to capitalized local-part of email / `codegraff.who` when full name is absent.
pub fn ownerFirstName(
    arena: Allocator,
    user_name: ?[]const u8,
    user_email: ?[]const u8,
    codegraff_who: ?[]const u8,
) ?[]const u8 {
    if (user_name) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len > 0) {
            const end = std.mem.indexOfAny(u8, t, " \t\r\n") orelse t.len;
            const word = t[0..end];
            const out = arena.dupe(u8, word) catch return null;
            if (out.len > 0 and std.ascii.isLower(out[0])) out[0] = std.ascii.toUpper(out[0]);
            return out;
        }
    }
    for ([_]?[]const u8{ user_email, codegraff_who }) |cand| {
        const raw = cand orelse continue;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        const at = std.mem.indexOfScalar(u8, trimmed, '@') orelse trimmed.len;
        const local = trimmed[0..at];
        const end = std.mem.indexOfAny(u8, local, "._-+ \t\r\n") orelse local.len;
        const word = std.mem.trim(u8, local[0..end], " \t\r\n");
        if (word.len == 0) continue;
        const out = arena.dupe(u8, word) catch return null;
        if (out.len > 0 and std.ascii.isLower(out[0])) out[0] = std.ascii.toUpper(out[0]);
        return out;
    }
    return null;
}

pub fn ownerForApp(arena: Allocator, a: *const App) ?[]const u8 {
    const uname: ?[]const u8 = if (a.account.user) |u| u.name else null;
    const uemail: ?[]const u8 = if (a.account.user) |u| (if (u.email.len > 0) u.email else null) else null;
    return ownerFirstName(arena, uname, uemail, a.account.codegraff.who);
}

pub fn isGenericComputerName(name: []const u8) bool {
    const t = std.mem.trim(u8, name, " \t\r\n");
    for ([_][]const u8{
        "cloud computer",
        "cloud sandbox",
        "harness cloud",
        "codegraff cloud",
        "temporary sandbox",
    }) |generic| {
        if (std.ascii.eqlIgnoreCase(t, generic)) return true;
    }
    return false;
}

/// Friendly card name: keeps explicit non-generic custom names, otherwise formats
/// `"Name's computer"` / `"Name's sandbox"` (or `"Chris' computer"`).
pub fn friendlyName(
    arena: Allocator,
    owner: ?[]const u8,
    raw_name: ?[]const u8,
    is_dedicated: bool,
    is_temporary: bool,
    has_dedicated_sibling: bool,
) []const u8 {
    if (raw_name) |rn| {
        const t = std.mem.trim(u8, rn, " \t\r\n");
        if (t.len > 0 and !isGenericComputerName(t)) return t;
    }
    if (is_temporary) return "Temporary sandbox";
    if (owner) |o_raw| {
        const o = std.mem.trim(u8, o_raw, " \t\r\n");
        if (o.len > 0) {
            const poss = if (o[o.len - 1] == 's' or o[o.len - 1] == 'S') "'" else "'s";
            const noun = if (is_dedicated or !has_dedicated_sibling) "computer" else "sandbox";
            return std.fmt.allocPrint(arena, "{s}{s} {s}", .{ o, poss, noun }) catch (if (is_dedicated) "Cloud computer" else "Cloud sandbox");
        }
    }
    return if (is_dedicated) "Cloud computer" else "Cloud sandbox";
}

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

fn drawComputerSprite(c: *ui.Context, a: *const App, k: theme.Colors, mood: SpriteMood, tone: ui.Color, is_temporary: bool) void {
    const animate = !c.reduced_motion and c.input.window_active and a.view.sidebar_tween == null and (mood == .running or mood == .starting);
    if (animate) c.frameIn(1.0 / 12.0);
    const t: f32 = if (animate) @floatCast(c.time) else 0;
    const badge = ui.div(c).row().size(28, 28).center().rounded(8)
        .bg(tone.alpha(if (k.dark) 0.14 else 0.10))
        .border(tone.alpha(if (mood == .paused) 0.14 else 0.28)).borderW(1);
    defer badge.end();
    const cv = ui.canvas(c, .{ .width = .{ .px = 26 }, .height = .{ .px = 26 } });
    const frame_col = k.text.mix(tone, if (mood == .paused) 0.10 else 0.24).alpha(if (k.dark) 0.88 else 0.82);
    const bob: f32 = if (mood == .running and animate) @sin(t * 2.4) * 0.55 else 0;
    if (is_temporary) {
        const cloud_col = k.text.mix(tone, 0.35).alpha(if (k.dark) 0.78 else 0.72);
        cv.circle(.{ .x = 8.4, .y = 14.0 + bob }, 4.0, cloud_col);
        cv.circle(.{ .x = 13.0, .y = 10.6 + bob }, 4.9, cloud_col);
        cv.circle(.{ .x = 17.6, .y = 14.0 + bob }, 3.8, cloud_col);
        cv.rect(.{ .x = 7.4, .y = 14.0 + bob, .w = 11.2, .h = 4.0 }, cloud_col, 2.0);
        const dot_col = tone.mix(ui.Color.white, 0.35);
        for ([_]f32{ 9.2, 13.0, 16.8 }, 0..) |dx, idx| {
            const f: f32 = @floatFromInt(idx);
            const a_mul: f32 = if (animate) 0.45 + 0.5 * (0.5 + 0.5 * @sin(t * 4.2 - f * 1.1)) else 0.75;
            cv.circle(.{ .x = dx, .y = 14.3 + bob }, 1.15, dot_col.alpha(a_mul));
        }
        return;
    }
    const screen_bg = ui.Color.hex(0x14181f).mix(tone, if (mood == .paused) 0.08 else 0.22);
    cv.rect(.{ .x = 3.0, .y = 4.0 + bob, .w = 20.0, .h = 14.0 }, frame_col, 3.2);
    cv.rect(.{ .x = 4.6, .y = 5.6 + bob, .w = 16.8, .h = 10.6 }, screen_bg, 2.0);
    cv.rect(.{ .x = 11.2, .y = 18.0 + bob * 0.4, .w = 3.6, .h = 2.3 }, frame_col.alpha(0.75), 0.6);
    cv.rect(.{ .x = 8.2, .y = 20.1, .w = 9.6, .h = 2.0 }, frame_col.alpha(0.85), 1.0);
    cv.circle(.{ .x = 19.8, .y = 16.8 + bob }, 0.85, tone.alpha(if (mood == .paused) 0.35 else 0.95));
    const glow = tone.mix(ui.Color.white, 0.42);
    switch (mood) {
        .running => {
            const blinking = animate and @mod(t, 3.6) > 3.44;
            if (blinking) {
                cv.rect(.{ .x = 7.9, .y = 10.2 + bob, .w = 2.5, .h = 1.0 }, glow, 0.5);
                cv.rect(.{ .x = 15.6, .y = 10.2 + bob, .w = 2.5, .h = 1.0 }, glow, 0.5);
            } else {
                cv.rect(.{ .x = 8.0, .y = 8.6 + bob, .w = 2.3, .h = 3.2 }, glow, 1.1);
                cv.rect(.{ .x = 15.7, .y = 8.6 + bob, .w = 2.3, .h = 3.2 }, glow, 1.1);
            }
            cv.rect(.{ .x = 10.8, .y = 13.0 + bob, .w = 4.4, .h = 1.2 }, glow.alpha(0.85), 0.6);
            const phase = @mod(t * 0.9, 1.0);
            const spark_alpha: f32 = if (animate) @max(0.25, 0.92 - @abs(phase - 0.5) * 1.1) else 0.72;
            cv.circle(.{ .x = 22.3, .y = 3.8 - phase * 2.1 }, 1.15, glow.alpha(spark_alpha));
        },
        .starting => {
            for ([_]f32{ 7.6, 11.9, 16.2 }, 0..) |bx, idx| {
                const f: f32 = @floatFromInt(idx);
                const wave = if (animate) 0.5 + 0.5 * @sin(t * 4.8 - f * 1.1) else 0.5 + f * 0.15;
                const bh = 2.8 + 3.2 * wave;
                cv.rect(.{ .x = bx, .y = 14.0 + bob - bh, .w = 2.2, .h = bh }, glow.alpha(0.6 + 0.35 * wave), 1.0);
            }
        },
        .attention => {
            cv.rect(.{ .x = 12.2, .y = 7.5 + bob, .w = 1.6, .h = 4.2 }, glow, 0.8);
            cv.circle(.{ .x = 13.0, .y = 13.5 + bob }, 0.9, glow);
        },
        .paused => {
            const z_col = ui.Color.white.alpha(0.45);
            cv.rect(.{ .x = 7.8, .y = 10.4, .w = 2.8, .h = 1.1 }, z_col, 0.55);
            cv.rect(.{ .x = 15.4, .y = 10.4, .w = 2.8, .h = 1.1 }, z_col, 0.55);
        },
    }
}

const DedicatedMeta = struct {
    status: []const u8,
    detail: []const u8,
    tip_text: []const u8,
    mood: SpriteMood,
    tone: ui.Color,
    live: bool,
};

fn dedicatedComputerCard(a: *const App) ?computer.Info {
    const info = computer.shown(a) orelse return null;
    const offer = info.offer orelse return null;
    if (std.mem.eql(u8, offer.state, "ended")) return null;
    return info;
}

fn dedicatedMeta(c: *ui.Context, k: theme.Colors, info: computer.Info) DedicatedMeta {
    const offer = info.offer.?;
    const phase = info.live.phase;
    const is_error = std.mem.eql(u8, phase, "harness_error") or std.mem.eql(u8, phase, "error");
    const is_running = std.mem.eql(u8, phase, "running") or std.mem.eql(u8, phase, "ready");
    const is_attaching = std.mem.eql(u8, phase, "attaching");
    const is_prov = std.mem.eql(u8, phase, "provisioning") or
        std.mem.eql(u8, phase, "starting") or
        std.mem.eql(u8, phase, "waiting_payment") or
        std.mem.eql(u8, phase, "waiting_capacity") or
        std.mem.eql(u8, phase, "resetting");
    const is_held = std.mem.eql(u8, offer.state, "held");
    const is_paid = std.mem.eql(u8, phase, "paid");
    const is_paused = std.mem.eql(u8, phase, "paused");

    const status: []const u8 = if (is_error)
        "Needs attention"
    else if (is_running)
        "Running"
    else if (is_attaching)
        "Installing…"
    else if (is_prov)
        "Provisioning…"
    else if (is_held)
        "Checkout pending"
    else if (is_paid)
        "Ready to start"
    else if (is_paused)
        "Paused"
    else
        "Active";

    const mood: SpriteMood = if (is_error) .attention else if (is_running) .running else if (is_attaching or is_prov) .starting else .paused;
    const tone = switch (mood) {
        .running => k.success,
        .starting => k.accent,
        .attention => k.warning,
        .paused => k.muted,
    };
    const detail = if (info.spec.cpu > 0 and info.spec.memory_gib > 0 and std.mem.eql(u8, status, "Running"))
        c.print("Running · {d} vCPU, {d} GB", .{ info.spec.cpu, info.spec.memory_gib })
    else if (info.spec.cpu > 0 and info.spec.memory_gib > 0 and std.mem.eql(u8, status, "Paused"))
        c.print("Paused · {d} vCPU, {d} GB", .{ info.spec.cpu, info.spec.memory_gib })
    else
        status;
    const tip_text = if (info.spec.cpu > 0)
        c.print("{s} · {d} vCPU · {d} GiB RAM · {d} GiB disk — manage in Settings › Accounts", .{ status, info.spec.cpu, info.spec.memory_gib, info.spec.disk_gib })
    else
        c.print("{s} — manage in Settings › Accounts", .{status});
    return .{
        .status = status,
        .detail = detail,
        .tip_text = tip_text,
        .mood = mood,
        .tone = tone,
        .live = mood == .running or mood == .starting,
    };
}

fn sandboxMood(label: []const u8) SpriteMood {
    if (std.mem.eql(u8, label, "Running")) return .running;
    if (std.mem.eql(u8, label, "Needs attention")) return .attention;
    if (std.mem.eql(u8, label, "Starting…") or std.mem.eql(u8, label, "Pausing…")) return .starting;
    return .paused;
}

fn renderComputerCard(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    key: []const u8,
    heading: []const u8,
    subline: []const u8,
    hint: []const u8,
    mood: SpriteMood,
    tone: ui.Color,
    live: bool,
    is_temporary: bool,
    text_w: f32,
) void {
    ui.key(c, key);
    var r = tip.on(ui.div(c).row().wFull().h(52).px(8).py(7).rounded(10).gap(8).itemsCenter(), k, .{ .text = hint, .delay = tip.quick });
    r = r.bg(k.raised.mix(tone, if (k.dark) 0.055 else 0.035))
        .border(tone.alpha(if (live) 0.24 else 0.14)).borderW(1)
        .hover(k.raised.mix(k.text, 0.05));
    defer r.end();
    drawComputerSprite(c, a, k, mood, tone, is_temporary);
    {
        const col = ui.div(c).column().grow().w(0).gap(2);
        defer col.end();
        kit.ellipsisText(c, heading, .{ .size = 12.5, .line_height = 12.5 * 1.2, .weight = theme.ui_medium_weight, .color = k.text }, text_w);
        const sub = ui.div(c).row().gap(4).itemsCenter();
        defer sub.end();
        kit.dot(c, 4.5, tone);
        kit.ellipsisText(c, subline, .{ .size = 10.5, .line_height = 10.5 * 1.2, .color = k.muted }, @max(40, text_w - 8.5));
    }
    icons.icon(c, .@"alt-arrow-right", 12, k.faint, 0);
    if (r.clicked()) openCard(a);
}

/// Named cloud computers in the macOS sidebar (`render_cloud_sandbox_strip`).
pub fn computers(c: *ui.Context, a: *App, k: theme.Colors) void {
    const dedicated = dedicatedComputerCard(a);
    const sbs: []const sandboxes.Sandbox = if (state.shown(a)) |l| l.sandboxes else &.{};
    const has_dedicated = dedicated != null;
    const total = @as(usize, @intFromBool(has_dedicated)) + sbs.len;
    if (total == 0) return;

    const owner = ownerForApp(c.alloc(), a);
    const outer = ui.div(c).column().wFull();
    defer outer.end();
    {
        const rule_wrap = ui.div(c).wFull().px(10).pt(4);
        defer rule_wrap.end();
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border.alpha(if (k.dark) 0.55 else 0.7) }, .none, null);
    }
    if (total > 1) {
        const hd = ui.div(c).row().wFull().px(16).pt(7).itemsCenter().justifyBetween();
        defer hd.end();
        ui.text(c, "Computers", st(c, 10.5, .{ .weight = .medium, .color = k.muted }));
        ui.text(c, c.print("{d}", .{total}), st(c, 10.5, .{ .mono = true, .color = k.faint }));
    }
    const cards = ui.div(c).column().wFull().px(8).pt(6).pb(3).gap(5);
    defer cards.end();
    const text_w = @max(60, sidebar.widthOf(a) - 16 - 16 - 28 - 16 - 12);
    if (dedicated) |info| {
        const meta = dedicatedMeta(c, k, info);
        const key = if (info.live.machine_id orelse info.offer.?.machine_id) |mid| c.print("dedicated-computer-{s}", .{mid}) else "dedicated-computer";
        const heading = friendlyName(c.alloc(), owner, info.live.device_name, true, false, has_dedicated);
        renderComputerCard(c, a, k, key, heading, meta.detail, meta.tip_text, meta.mood, meta.tone, meta.live, false, text_w);
    }
    for (sbs) |sb| {
        const temp = sandboxes.isTemporary(sb);
        const custom: ?[]const u8 = for ([_]?[]const u8{ sb.name, sb.device_name }) |n| {
            if (n) |v| {
                const t = std.mem.trim(u8, v, " \t\n");
                if (t.len > 0) break t;
            }
        } else null;
        const heading = friendlyName(c.alloc(), owner, custom, false, temp, has_dedicated);
        const label = statusLabel(sb);
        const mood = sandboxMood(label);
        const tone = statusTone(label, k);
        const live = std.mem.eql(u8, sb.state, "running") or std.mem.eql(u8, sb.state, "starting");
        const line = if (live and sb.price_per_hour_micro_usd != null)
            c.print("{s} · {s}", .{ label, @import("runners.zig").formatRate(c.alloc(), sb.price_per_hour_micro_usd.?) catch "" })
        else
            label;
        const hint = c.print("{s} — manage in Settings › Accounts", .{line});
        renderComputerCard(c, a, k, c.print("cloud-computer-{s}", .{sb.id}), heading, line, hint, mood, tone, live, temp, text_w);
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

const testing = std.testing;

test "ownerFirstName extracts given name or capitalizes local email prefix" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    try testing.expectEqualStrings("Rach", ownerFirstName(ar, "Rach Pradhan", "rach@example.test", null).?);
    try testing.expectEqualStrings("Chris", ownerFirstName(ar, "chris", null, null).?);
    try testing.expectEqualStrings("Alice", ownerFirstName(ar, "   ", "alice.smith@example.test", null).?);
    try testing.expectEqualStrings("Bob", ownerFirstName(ar, null, null, "bob_dev@example.test").?);
    try testing.expect(ownerFirstName(ar, null, null, null) == null);
    try testing.expect(ownerFirstName(ar, " ", "@example.test", null) == null);
}

test "friendlyName personalizes generic computer names and preserves custom host names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    try testing.expectEqualStrings("Rach's computer", friendlyName(ar, "Rach", "Cloud computer", true, false, true));
    try testing.expectEqualStrings("Chris' computer", friendlyName(ar, "Chris", null, true, false, true));
    try testing.expectEqualStrings("Rach's computer", friendlyName(ar, "Rach", "Cloud sandbox", false, false, false));
    try testing.expectEqualStrings("Rach's sandbox", friendlyName(ar, "Rach", "Harness cloud", false, false, true));
    try testing.expectEqualStrings("rach-node-c", friendlyName(ar, "Rach", "rach-node-c", true, false, true));
    try testing.expectEqualStrings("Temporary sandbox", friendlyName(ar, "Rach", "Temporary sandbox", false, true, true));
    try testing.expectEqualStrings("Cloud computer", friendlyName(ar, null, null, true, false, true));
    try testing.expectEqualStrings("Cloud sandbox", friendlyName(ar, null, null, false, false, true));
}
