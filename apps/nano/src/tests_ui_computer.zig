//! Settings › Accounts Cloud Computer card synthetic UI regressions & capture.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const view = @import("view_settings.zig");
const Section = @import("settings.zig").Section;
const accounts_view = @import("view_settings_accounts.zig");
const computer = @import("app_computer.zig");

const scene_usage =
    \\{"snapshot":{"accounts":[],"warnings":[]},
    \\ "codegraffUsage":{"email":"alice@example.test","tier":"pro","credits_micro_usd":25000000,"spend_30d_micro_usd":0,"requests_30d":0,"key_budget_monthly_micro_usd":null,"key_spend_monthly_micro_usd":0,"key_budget_resets_at":""},
    \\ "codegraffJobs":{"jobs":[]},
    \\ "graffLogins":[]}
;

const running_complimentary =
    \\{"enabled":true,"onSale":1,"freeSlots":0,"totalSlots":1,"priceMonthlyUsd":50,"spec":{"cpu":4,"memoryGiB":8,"diskGiB":60},"offer":{"state":"provisioned","slot":1,"machineId":"mch_synthetic000000000000000000000000000000","paidThrough":1798133213,"complimentary":true},"live":{"phase":"running","machineId":"mch_synthetic000000000000000000000000000000","deviceName":"Cloud computer"},"manageUrl":"https://codegraff.com/dashboard/sandboxes#computer","billingUrl":"https://codegraff.com/dashboard/billing"}
;

const attaching_offer =
    \\{"enabled":true,"onSale":1,"freeSlots":0,"totalSlots":1,"priceMonthlyUsd":50,"spec":{"cpu":4,"memoryGiB":8,"diskGiB":60},"offer":{"state":"provisioned","slot":1,"machineId":"mch_synthetic000000000000000000000000000000","complimentary":false},"live":{"phase":"attaching","machineId":"mch_synthetic000000000000000000000000000000","deviceName":"Cloud computer"},"manageUrl":"https://codegraff.com/dashboard/sandboxes#computer","billingUrl":"https://codegraff.com/dashboard/billing"}
;

fn snap(h: *Harness, filename: []const u8) !void {
    const dir = std.c.getenv("NANO_COMPUTER_SNAP_DIR") orelse return;
    var path: [1024]u8 = undefined;
    try h.t.screenshot(try std.fmt.bufPrint(&path, "{s}/{s}.png", .{ std.mem.span(dir), filename }));
}

test "cloud computer settings card renders complimentary running state, attaches, and surfaces errors" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    accounts_view.scene_accounts = scene_usage;
    defer accounts_view.scene_accounts = null;

    view.open(&h.a);
    h.a.settings.setSection(.agents);
    h.t.settle(0.2);
    try testing.expectEqual(Section.agents, h.a.settings.section);

    // 1. Owned complimentary running Cloud Computer: accurate status, no Start or billing buttons, stops polling.
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, running_complimentary, .{});
        defer parsed.deinit();
        computer.apply(&h.a, parsed.value);
    }
    h.t.settle(0.2);
    try testing.expect(h.t.containsText("Running · Complimentary · 4 vCPU · 8 GiB RAM · 60 GiB disk"));
    try testing.expect(h.t.hasText("Open dashboard"));
    try testing.expect(!h.t.hasText("Start"));
    try testing.expect(!h.t.hasText("Manage billing"));
    try testing.expect(h.a.cloud_computer.next_read == null);
    try snap(&h, "after-cloud-computer-card");

    // 2. Attaching phase shows progress copy and schedules polling.
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, attaching_offer, .{});
        defer parsed.deinit();
        computer.apply(&h.a, parsed.value);
    }
    h.t.settle(0.2);
    try testing.expect(h.t.containsText("Installing Harness… · 4 vCPU · 8 GiB RAM · 60 GiB disk"));
    try testing.expect(h.a.cloud_computer.next_read != null);

    // 3. Error fallback while signed into CodeGraff surfaces actionable controls instead of hiding the card.
    h.a.cloud_computer.deinit();
    computer.setErr(&h.a, "Cloud computer request failed (403).");
    h.t.settle(0.2);
    try testing.expect(h.t.containsText("Cloud computer request failed (403)."));
    try testing.expect(h.t.hasText("Open dashboard"));
}
