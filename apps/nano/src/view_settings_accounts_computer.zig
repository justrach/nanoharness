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
    const info = computer.shown(a) orelse return;
    set.space(c, 16);
    ui.text(c, "Cloud computer", st(c, 12, .{ .weight = .medium, .color = k.muted }));
    const cd = rows.card(c, k, 8);
    defer cd.end();
    const busy = a.cloud_computer.busy;

    if (info.offer) |offer| {
        const phase = info.live.phase;
        const is_ready = std.mem.eql(u8, phase, "ready");
        const is_prov = std.mem.eql(u8, phase, "provisioning") or std.mem.eql(u8, phase, "starting") or busy == .start;
        const can_start = !is_ready and !is_prov and !std.mem.eql(u8, offer.state, "canceling");

        const start_label = if (is_prov) "Starting…" else "Start";
        const manage_g: rows.Ghost = .{ .label = "Manage billing" };
        var actions_w: f32 = 12 + rows.ghostW(c, manage_g);
        if (can_start) actions_w += 8 + rows.primaryW(c, start_label);

        ui.key(c, "codegraff-cloud-computer-owned");
        const r = ui.div(c).row().wFull().px(20).py(12).gap(12).itemsCenter();
        defer r.end();
        const w = rows.rowInner() - actions_w;
        {
            const col = ui.div(c).column().w(@max(w, 120));
            defer col.end();
            const heading = info.live.device_name orelse "Cloud Computer";
            rows.title(c, k, heading, w);
            set.space(c, 3);
            const status_text = if (is_ready)
                "Ready"
            else if (std.mem.eql(u8, offer.state, "canceling"))
                "Canceling at period end"
            else if (is_prov)
                "Provisioning…"
            else
                "Stopped";
            const spec_line = c.print("{s} · {d} vCPU · {d} GiB RAM · {d} GiB disk", .{
                status_text, info.spec.cpu, info.spec.memory_gib, info.spec.disk_gib,
            });
            ui.text(c, spec_line, st(c, 11.5, .{ .wrap = true, .color = k.muted }));
        }
        ui.spacer(c);
        if (can_start) {
            if (rows.primary(c, k, start_label, busy != null)) computer.startComputer(a);
        }
        if (rows.ghost(c, k, manage_g)) _ = nanoui.shell.openUrl(info.billing_url);
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
