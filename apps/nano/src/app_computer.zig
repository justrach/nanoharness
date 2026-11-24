//! Dedicated Node D Cloud Computer (`$50/mo` 4 vCPU · 8 GiB · 60 GiB persistent VM)
//! status and checkout orchestration, kept on `App` for Settings › Accounts.
const std = @import("std");
const nanoui = @import("nanoui");
const json = std.json;
const rpc = @import("rpc.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const poll_s: f64 = 5;

pub const Spec = struct {
    cpu: u64 = 4,
    memory_gib: u64 = 8,
    disk_gib: u64 = 60,
};

pub const Summary = struct {
    state: []const u8 = "",
    slot: u64 = 0,
    machine_id: ?[]const u8 = null,
    paid_through: ?i64 = null,
    retire_at: ?i64 = null,
    complimentary: bool = false,
};

pub const Live = struct {
    phase: []const u8 = "none",
    machine_id: ?[]const u8 = null,
    state: ?[]const u8 = null,
    device_name: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const Info = struct {
    enabled: bool = false,
    on_sale: u64 = 0,
    free_slots: u64 = 0,
    total_slots: u64 = 0,
    price_monthly_usd: u64 = 50,
    spec: Spec = .{},
    offer: ?Summary = null,
    live: Live = .{},
    manage_url: []const u8 = "https://codegraff.com/dashboard/sandboxes#computer",
    billing_url: []const u8 = "https://codegraff.com/dashboard/billing",
};

pub const Busy = enum { checkout, start };

pub const State = struct {
    info: ?Info = null,
    arena: ?std.heap.ArenaAllocator = null,
    call: ?u64 = null,
    action_call: ?u64 = null,
    busy: ?Busy = null,
    next_read: ?f64 = null,
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

    pub fn deinit(s: *State) void {
        if (s.arena) |*ar| ar.deinit();
        s.* = .{};
    }

    pub fn errText(s: *const State) ?[]const u8 {
        return if (s.err_len > 0) s.err_buf[0..s.err_len] else null;
    }
};

pub fn setErr(a: *App, msg: ?[]const u8) void {
    const s = &a.cloud_computer;
    if (msg) |m| {
        const len = @min(m.len, s.err_buf.len);
        @memcpy(s.err_buf[0..len], m[0..len]);
        s.err_len = len;
    } else {
        s.err_len = 0;
    }
}

fn str(o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn strDupe(ar: Allocator, o: json.ObjectMap, k: []const u8) !?[]const u8 {
    return if (str(o, k)) |s| try ar.dupe(u8, s) else null;
}

fn uint(o: json.ObjectMap, k: []const u8) ?u64 {
    const v = o.get(k) orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}

fn intOpt(o: json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return if (v == .integer) v.integer else null;
}

pub fn parse(ar: Allocator, v: json.Value) !?Info {
    if (v == .null) return null;
    if (v != .object) return error.BadComputer;
    const o = v.object;
    var out: Info = .{
        .enabled = if (o.get("enabled")) |e| (e == .bool and e.bool) else false,
        .on_sale = uint(o, "onSale") orelse 0,
        .free_slots = uint(o, "freeSlots") orelse 0,
        .total_slots = uint(o, "totalSlots") orelse 0,
        .price_monthly_usd = uint(o, "priceMonthlyUsd") orelse 50,
    };
    if (try strDupe(ar, o, "manageUrl")) |u| out.manage_url = u;
    if (try strDupe(ar, o, "billingUrl")) |u| out.billing_url = u;
    if (o.get("spec")) |sv| if (sv == .object) {
        out.spec = .{
            .cpu = uint(sv.object, "cpu") orelse 4,
            .memory_gib = uint(sv.object, "memoryGiB") orelse 8,
            .disk_gib = uint(sv.object, "diskGiB") orelse 60,
        };
    };
    if (o.get("offer")) |ov| if (ov == .object) {
        out.offer = .{
            .state = (try strDupe(ar, ov.object, "state")) orelse "",
            .slot = uint(ov.object, "slot") orelse 0,
            .machine_id = try strDupe(ar, ov.object, "machineId"),
            .paid_through = intOpt(ov.object, "paidThrough"),
            .retire_at = intOpt(ov.object, "retireAt"),
            .complimentary = if (ov.object.get("complimentary")) |cv| (cv == .bool and cv.bool) else false,
        };
    };
    if (o.get("live")) |lv| if (lv == .object) {
        out.live = .{
            .phase = (try strDupe(ar, lv.object, "phase")) orelse "none",
            .machine_id = try strDupe(ar, lv.object, "machineId"),
            .state = try strDupe(ar, lv.object, "state"),
            .device_name = try strDupe(ar, lv.object, "deviceName"),
            .message = try strDupe(ar, lv.object, "message"),
        };
    };
    return out;
}

pub fn shown(a: *const App) ?Info {
    const info = a.cloud_computer.info orelse return null;
    return if (info.enabled or info.offer != null) info else null;
}

pub fn needsRefresh(info: ?Info) bool {
    const i = info orelse return false;
    for ([_][]const u8{
        "provisioning",
        "starting",
        "attaching",
        "paid",
        "waiting_payment",
        "waiting_capacity",
        "resetting",
    }) |p| {
        if (std.mem.eql(u8, i.live.phase, p)) return true;
    }
    return false;
}

pub fn refresh(a: *App) void {
    if (!a.engine.up()) return;
    const s = &a.cloud_computer;
    s.next_read = null;
    s.call = a.engine.call("CodegraffComputer", rpc.empty, .of(App, a, onOffer));
}

pub fn startCheckout(a: *App) void {
    const s = &a.cloud_computer;
    if (s.busy != null) return;
    if (!a.engine.up()) {
        a.setNotice("Engine not connected");
        return;
    }
    s.busy = .checkout;
    s.action_call = a.engine.call("CodegraffComputerCheckout", rpc.empty, .of(App, a, onAction));
    a.redraw();
}

pub fn startComputer(a: *App) void {
    const s = &a.cloud_computer;
    if (s.busy != null) return;
    if (!a.engine.up()) {
        a.setNotice("Engine not connected");
        return;
    }
    s.busy = .start;
    s.action_call = a.engine.call("CodegraffComputerStart", rpc.empty, .of(App, a, onAction));
    a.redraw();
}

fn onOffer(a: *App, id: u64, r: rpc.Reply) void {
    const s = &a.cloud_computer;
    if (id != 0 and s.call != id) return;
    s.call = null;
    switch (r) {
        .ok => |v| apply(a, v),
        .err => |msg| {
            if (s.info == null) {
                const why = if (std.mem.eql(u8, msg, "not connected")) "Engine not connected" else msg;
                setErr(a, why);
            }
            schedule(a);
        },
        else => schedule(a),
    }
    a.redraw();
}

fn onAction(a: *App, id: u64, r: rpc.Reply) void {
    const s = &a.cloud_computer;
    if (id != 0 and s.action_call != id) return;
    const busy = s.busy;
    s.busy = null;
    s.action_call = null;
    switch (r) {
        .err => |msg| {
            const why = if (std.mem.eql(u8, msg, "not connected")) "Engine not connected" else msg;
            @import("view_settings_accounts.zig").setNotice(a, why);
            a.setNotice(why);
        },
        .ok => |v| {
            if (busy == .checkout and v == .object) {
                if (str(v.object, "url")) |url| if (url.len > 0) {
                    _ = nanoui.shell.openUrl(url);
                };
            }
            refresh(a);
        },
        else => {},
    }
    a.redraw();
}

pub fn apply(a: *App, v: json.Value) void {
    const s = &a.cloud_computer;
    var ar: std.heap.ArenaAllocator = .init(a.gpa);
    const got = parse(ar.allocator(), v) catch {
        ar.deinit();
        schedule(a);
        return;
    };
    if (s.arena) |*old| old.deinit();
    s.arena = ar;
    s.info = got;
    s.err_len = 0;
    schedule(a);
    a.redraw();
}

fn schedule(a: *App) void {
    const s = &a.cloud_computer;
    s.next_read = if (needsRefresh(s.info)) a.now + poll_s else null;
}

pub fn tick(a: *App, now: f64) ?f64 {
    const t = a.cloud_computer.next_read orelse return null;
    if (now < t) return t;
    a.cloud_computer.next_read = null;
    refresh(a);
    return a.cloud_computer.next_read;
}

const testing = std.testing;

test "cloud computer offer parses promo, owned, null, and schedules polling while provisioning" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();

    const promo = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"enabled":true,"onSale":1,"freeSlots":1,"totalSlots":1,"priceMonthlyUsd":50,"spec":{"cpu":4,"memoryGiB":8,"diskGiB":60},"offer":null,"live":{"phase":"none"},"manageUrl":"https://codegraff.com/dashboard/sandboxes#computer","billingUrl":"https://codegraff.com/dashboard/billing"}
    , .{});
    defer promo.deinit();
    apply(&a, promo.value);
    try testing.expect(shown(&a).?.free_slots == 1);
    try testing.expect(a.cloud_computer.next_read == null);

    const prov = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"enabled":true,"onSale":1,"freeSlots":0,"totalSlots":1,"priceMonthlyUsd":50,"spec":{"cpu":4,"memoryGiB":8,"diskGiB":60},"offer":{"state":"active","slot":1,"complimentary":true},"live":{"phase":"attaching","machineId":"m_1"}}
    , .{});
    defer prov.deinit();
    setErr(&a, "Temporary error");
    try testing.expectEqualStrings("Temporary error", a.cloud_computer.errText().?);
    apply(&a, prov.value);
    try testing.expect(shown(&a).?.offer != null);
    try testing.expect(shown(&a).?.offer.?.complimentary);
    try testing.expect(a.cloud_computer.errText() == null);
    try testing.expect(a.cloud_computer.next_read != null);

    for ([_][]const u8{ "provisioning", "starting", "attaching", "paid", "waiting_payment", "waiting_capacity", "resetting" }) |phase| {
        const poll_info: Info = .{ .enabled = true, .live = .{ .phase = phase } };
        try testing.expect(needsRefresh(poll_info));
    }

    const ready = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"enabled":true,"onSale":1,"freeSlots":0,"totalSlots":1,"priceMonthlyUsd":50,"spec":{"cpu":4,"memoryGiB":8,"diskGiB":60},"offer":{"state":"provisioned","slot":1},"live":{"phase":"running","machineId":"m_1","deviceName":"Node D"}}
    , .{});
    defer ready.deinit();
    apply(&a, ready.value);
    try testing.expect(a.cloud_computer.next_read == null);
    try testing.expect(!needsRefresh(.{ .enabled = true, .live = .{ .phase = "ready" } }));
    try testing.expect(!needsRefresh(.{ .enabled = true, .live = .{ .phase = "harness_error" } }));
    try testing.expectEqualStrings("Node D", shown(&a).?.live.device_name.?);

    const invalid = try json.parseFromSlice(json.Value, testing.allocator, "[1,2]", .{});
    defer invalid.deinit();
    apply(&a, invalid.value);
    try testing.expect(shown(&a).?.offer != null);
}
