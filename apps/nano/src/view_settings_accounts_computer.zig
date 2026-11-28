//! Settings › Accounts card for the user's dedicated Node D Cloud Computer ($50/mo)
//! or checkout promo when slots are open.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const set = @import("view_settings.zig");
const rows = @import("view_settings_accounts_rows.zig");
const computer = @import("app_computer.zig");
const App = @import("app.zig").App;

const st = rows.st;

pub fn card(c: *ui.Context, a: *App, k: theme.Colors) void {
    const busy = a.cloud_computer.busy;
    const info = computer.shown(a) orelse {
        const err = a.cloud_computer.errText() orelse return;
        const signed_in = if (a.view.accounts.usage.get()) |u| u != null else false;
        if (!signed_in) return;
        set.space(c, 16);
        ui.text(c, "Cloud computer", st(c, 12, .{ .weight = .medium, .color = k.muted }));
        const cd = rows.card(c, k, 8);
        defer cd.end();
        ui.key(c, "codegraff-cloud-computer-error");
        const refresh_g: rows.Ghost = .{ .label = "Refresh" };
        const dash_g: rows.Ghost = .{ .label = "Open dashboard" };
        const actions_w: f32 = 12 + rows.ghostW(c, refresh_g) + 8 + rows.ghostW(c, dash_g);
        const r = ui.div(c).row().wFull().px(20).py(12).gap(12).itemsCenter();
        defer r.end();
        const w = rows.rowInner() - actions_w;
        {
            const col = ui.div(c).column().w(@max(w, 120));
            defer col.end();
            rows.title(c, k, "Cloud Computer", w);
            set.space(c, 3);
            ui.text(c, err, st(c, 11.5, .{ .wrap = true, .color = k.muted }));
        }
        ui.spacer(c);
        if (rows.ghost(c, k, refresh_g)) computer.refresh(a);
        if (rows.ghost(c, k, dash_g)) _ = nanoui.shell.openUrl("https://codegraff.com/dashboard/sandboxes#computer");
        return;
    };
    set.space(c, 16);
    ui.text(c, "Cloud computer", st(c, 12, .{ .weight = .medium, .color = k.muted }));
    const cd = rows.card(c, k, 8);
    defer cd.end();

    if (info.offer) |offer| {
        const phase = info.live.phase;
        const is_running = std.mem.eql(u8, phase, "running") or std.mem.eql(u8, phase, "ready");
        const is_attaching = std.mem.eql(u8, phase, "attaching");
        const is_prov = std.mem.eql(u8, phase, "provisioning") or
            std.mem.eql(u8, phase, "starting") or
            std.mem.eql(u8, phase, "waiting_payment") or
            std.mem.eql(u8, phase, "waiting_capacity") or
            std.mem.eql(u8, phase, "resetting") or
            busy == .start;
        const is_paid_unstarted = std.mem.eql(u8, phase, "paid");
        const is_paused = std.mem.eql(u8, phase, "paused");
        const is_error = std.mem.eql(u8, phase, "harness_error") or std.mem.eql(u8, phase, "error");
        const is_cancelling = std.mem.eql(u8, offer.state, "cancelling") or std.mem.eql(u8, offer.state, "canceling");
        const is_ended = std.mem.eql(u8, offer.state, "ended");
        const is_past_due = std.mem.eql(u8, offer.state, "past_due");
        const is_held = std.mem.eql(u8, offer.state, "held");
        const can_start = is_paid_unstarted and !is_ended and !is_held and busy != .start;

        const start_label = "Start";
        const ghost_label: []const u8 = if (is_held)
            "Finish paying"
        else if (offer.complimentary or is_error or is_attaching or is_prov)
            "Open dashboard"
        else
            "Manage billing";
        const ghost_url: []const u8 = if (is_held or offer.complimentary or is_error or is_attaching or is_prov)
            info.manage_url
        else
            info.billing_url;
        const manage_g: rows.Ghost = .{ .label = ghost_label };
        var actions_w: f32 = 12 + rows.ghostW(c, manage_g);
        if (can_start) actions_w += 8 + rows.primaryW(c, start_label);

        ui.key(c, "codegraff-cloud-computer-owned");
        const r = ui.div(c).row().wFull().px(20).py(12).gap(12).itemsCenter();
        defer r.end();
        const w = rows.rowInner() - actions_w;
        {
            const col = ui.div(c).column().w(@max(w, 120));
            defer col.end();
            const strip_view = @import("view_sandbox_strip.zig");
            const owner = strip_view.ownerForApp(c.alloc(), a);
            const heading = if (owner != null)
                strip_view.friendlyName(c.alloc(), owner, info.live.device_name, true, false, false)
            else
                info.live.device_name orelse "Cloud Computer";
            rows.title(c, k, heading, w);
            set.space(c, 3);
            const status_text: []const u8 = if (is_ended)
                "Ended"
            else if (is_held)
                "Checkout pending"
            else if (is_error)
                info.live.message orelse "Setup error"
            else if (is_running)
                (if (is_cancelling)
                    "Running · Cancelling at period end"
                else if (is_past_due)
                    "Running · Payment past due"
                else
                    "Running")
            else if (is_attaching)
                "Installing Harness…"
            else if (is_prov)
                "Provisioning…"
            else if (is_paid_unstarted)
                "Ready to start"
            else if (is_paused)
                "Paused"
            else if (is_cancelling)
                "Cancelling at period end"
            else if (is_past_due)
                "Payment past due"
            else
                "Active";
            const spec_line = if (offer.complimentary)
                c.print("{s} · Complimentary · {d} vCPU · {d} GiB RAM · {d} GiB disk", .{
                    status_text, info.spec.cpu, info.spec.memory_gib, info.spec.disk_gib,
                })
            else
                c.print("{s} · {d} vCPU · {d} GiB RAM · {d} GiB disk", .{
                    status_text, info.spec.cpu, info.spec.memory_gib, info.spec.disk_gib,
                });
            ui.text(c, spec_line, st(c, 11.5, .{ .wrap = true, .color = k.muted }));
        }
        ui.spacer(c);
        if (can_start) {
            if (rows.primary(c, k, start_label, busy != null)) computer.startComputer(a);
        }
        if (rows.ghost(c, k, manage_g)) _ = nanoui.shell.openUrl(ghost_url);
        return;
    }

    if (info.free_slots > 0) {
        const buy_label = if (busy == .checkout)
            "Opening checkout…"
        else
            c.print("Get Cloud Computer — ${d}/mo", .{info.price_monthly_usd});
        ui.key(c, "codegraff-cloud-computer-promo");
        const r = ui.div(c).row().wFull().px(20).py(12).gap(12).itemsCenter();
        defer r.end();
        const w = rows.rowInner() - 12 - rows.primaryW(c, buy_label);
        {
            const col = ui.div(c).column().w(@max(w, 120));
            defer col.end();
            rows.title(c, k, "Dedicated Cloud Computer", w);
            set.space(c, 3);
            const detail = c.print("${d}/mo · {d} vCPU, {d} GiB RAM, {d} GiB persistent disk · {d} slot(s) available", .{
                info.price_monthly_usd, info.spec.cpu, info.spec.memory_gib, info.spec.disk_gib, info.free_slots,
            });
            ui.text(c, detail, st(c, 11.5, .{ .wrap = true, .color = k.muted }));
        }
        ui.spacer(c);
        if (rows.primary(c, k, buy_label, busy != null)) computer.startCheckout(a);
        return;
    }

    ui.key(c, "codegraff-cloud-computer-soldout");
    const sold_g: rows.Ghost = .{ .label = "Details" };
    const r = ui.div(c).row().wFull().px(20).py(12).gap(12).itemsCenter();
    defer r.end();
    const w = rows.rowInner() - 12 - rows.ghostW(c, sold_g);
    {
        const col = ui.div(c).column().w(@max(w, 120));
        defer col.end();
        rows.title(c, k, "Cloud Computers — Sold out", w);
        set.space(c, 2);
        ui.text(c, "Dedicated persistent cloud computers are currently out of capacity.", st(c, 11.5, .{ .wrap = true, .color = k.muted }));
    }
    ui.spacer(c);
    if (rows.ghost(c, k, sold_g)) _ = nanoui.shell.openUrl(info.manage_url);
}
