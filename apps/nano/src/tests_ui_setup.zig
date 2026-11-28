//! First-run setup (view_setup.zig), driven headlessly as a person would:
//! Graff first and picked, Return through the questions, and the answers
//! landing on the new chat and Settings.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const setup = @import("view_setup.zig");
const S = ui.Shortcut;

const testing = std.testing;

const harnesses =
    \\[{"id":"graff","name":"graff","installed":true,"enabled":true,"reasoningLevels":["low","medium","high"]},
    \\ {"id":"claude-code","name":"Claude Code","installed":true,"enabled":false},
    \\ {"id":"codex","name":"Codex","installed":false,"enabled":false}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        h.a.new_harness = try testing.allocator.dupe(u8, "codex");
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, harnesses, .{});
        defer parsed.deinit();
        try h.a.harnesses.replace(parsed.value);
        h.a.view.setup_checked = true;
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn press(h: *Harness, s: S) void {
        _ = h.t.shortcut(s);
        h.t.settle(1);
    }
};

test "setup starts on Graff, picked and recommended, with the extras as this device has them" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    setup.open(&h.a, 0);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Start with Graff"));
    try testing.expect(h.t.hasText("Recommended"));
    try testing.expect(h.t.hasText("Optional, ready"));
    try testing.expect(h.t.hasText("Not installed on this computer"));
    try testing.expect(h.t.hasText("curl -fsSL https://chatgpt.com/codex/install.sh | sh"));
    try testing.expect(h.t.hasText("Copy"));
    try testing.expect(h.t.hasText("1 of 4"));
}

test "first-run setup with neither Claude Code nor ChatGPT CLI installed offers one-click install, copyable commands, and enables after install" {
    const missing =
        \\[{"id":"graff","name":"graff","installed":true,"enabled":true,"reasoningLevels":["low","medium","high"]},
        \\ {"id":"claude-code","name":"Claude Code","installed":false,"enabled":false,"canInstall":true},
        \\ {"id":"codex","name":"Codex","installed":false,"enabled":false,"canInstall":true}]
    ;
    const after_install =
        \\[{"id":"graff","name":"graff","installed":true,"enabled":true,"reasoningLevels":["low","medium","high"]},
        \\ {"id":"claude-code","name":"Claude Code","installed":true,"enabled":true,"canInstall":false},
        \\ {"id":"codex","name":"Codex","installed":false,"enabled":false,"canInstall":true}]
    ;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var p_missing = try std.json.parseFromSlice(std.json.Value, testing.allocator, missing, .{});
    defer p_missing.deinit();
    try h.a.harnesses.replace(p_missing.value);
    const scene_body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"GetAutonomy\":{{\"autonomy\":\"workspace\",\"chosen\":false}},\"ListModels\":{{\"models\":[]}},\"InstallHarness\":{s},\"CancelInstall\":{{}},\"SetHarnessEnabled\":{s}}}",
        .{ after_install, after_install },
    );
    defer testing.allocator.free(scene_body);
    if (h.a.engine.scene) |*sc| sc.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene_body, .{});
    h.a.engine.state = .connected;

    setup.open(&h.a, 0);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Set up your coding CLIs"));
    try testing.expect(h.t.hasText("Install both"));
    try testing.expect(h.t.hasText("Check again"));
    try testing.expect(h.t.hasText("curl -fsSL https://claude.ai/install.sh | bash"));

    try h.t.clickText("Copy");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Copied"));
    try testing.expectEqualStrings("curl -fsSL https://claude.ai/install.sh | bash", h.t.clipboard.items);

    try h.t.clickText("Install CLI");
    h.t.settle(1);
    var sent_install = false;
    for (h.a.engine.sent.items) |frame| {
        if (std.mem.indexOf(u8, frame, "\"InstallHarness\"") != null and
            std.mem.indexOf(u8, frame, "\"claude-code\"") != null)
            sent_install = true;
    }
    try testing.expect(sent_install);
    try testing.expect(h.a.view.setup.?.installing == null);
    try testing.expect(h.a.view.setup.?.extras_on[0]);
    try testing.expect(h.t.hasText("Optional, on"));

    // Hold the second install's queued reply before rendering to inspect the
    // in-flight spinner and Cancel button before the next frame pumps it.
    setup.installExtra(&h.a, 1);
    const held = try h.a.engine.queued.toOwnedSlice(testing.allocator);
    defer {
        for (held) |frame| testing.allocator.free(frame);
        testing.allocator.free(held);
    }
    h.t.settle(1);
    try testing.expectEqual(@as(?usize, 1), h.a.view.setup.?.installing);
    try testing.expect(h.t.hasText("Installing CLI on this computer…"));
    try testing.expect(h.t.hasText("Cancel"));

    try h.t.clickText("Cancel");
    h.t.settle(1);
    try testing.expect(h.a.view.setup.?.installing == null);
    var sent_cancel = false;
    for (h.a.engine.sent.items) |frame| {
        if (std.mem.indexOf(u8, frame, "\"CancelInstall\"") != null and
            std.mem.indexOf(u8, frame, "\"codex\"") != null)
            sent_cancel = true;
    }
    try testing.expect(sent_cancel);
}

test "Return walks the questions; Escape goes back; the answers land" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    setup.open(&h.a, 0);
    h.t.settle(1);
    h.press(.{ .key = S.enter });
    try testing.expect(h.t.hasText("How hard should it think?"));
    h.press(.{ .key = S.escape });
    try testing.expect(h.t.hasText("Start with Graff"));
    h.press(.{ .key = S.enter });
    h.press(.{ .key = S.enter });
    try testing.expect(h.t.hasText("How much can it do without asking?"));
    try testing.expect(h.t.hasText("Workspace"));
    h.press(.{ .key = S.left });
    try testing.expectEqual(setup.Autonomy.read_only, h.a.view.setup.?.autonomy);
    h.press(.{ .key = S.enter });
    try testing.expect(h.t.hasText("Ping you when it needs you?"));
    try h.t.clickText("No, I'll check in");
    h.t.settle(1);
    h.press(.{ .key = S.enter });
    try testing.expect(h.t.hasText("Your first agent is ready"));
    try testing.expect(h.t.hasText("Read only"));
    try h.t.clickText("Tour this project");
    h.t.settle(1);
    h.press(.{ .key = S.enter });
    try testing.expect(h.a.view.setup == null);
    try testing.expectEqualStrings("graff", h.a.new_harness);
    try testing.expect(!h.a.settings.get(.notifications_enabled));
    try testing.expect(std.mem.startsWith(u8, h.a.composer.text(), "Tour this project"));
}

test "Skip setup leaves the defaults alone" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    setup.open(&h.a, 1);
    h.t.settle(1);
    try h.t.clickText("Skip setup");
    h.t.settle(1);
    try testing.expect(h.a.view.setup == null);
    try testing.expectEqualStrings("codex", h.a.new_harness);
    try testing.expect(h.a.settings.get(.notifications_enabled));
}

test "onboarding renders as a dedicated opaque screen that hides and blocks the workspace below" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.dark = false;
    h.a.settings.setText("surface", "frosted");
    var chats_json = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"c1","deviceId":"local","title":"Cedar Notes","archived":false}]
    , .{});
    defer chats_json.deinit();
    try h.a.chats.replace(chats_json.value);
    h.a.openChat("c1", null);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Cedar Notes"));

    setup.open(&h.a, 0);
    h.t.settle(1);
    if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/setup-screen.png", .{std.mem.span(dir)})) |path| {
            h.t.screenshot(path) catch {};
        } else |_| {}
    }

    // Setup content is visible, while nothing from the workspace/sidebar/tab strip is mounted underneath.
    try testing.expect(h.t.hasText("Start with Graff"));
    try testing.expect(!h.t.hasText("Cedar Notes"));
    try testing.expect(!h.t.hasText("New session"));

    // Setup panes are fully opaque even when frosted glass is enabled.
    var saw_full_root = false;
    for (h.t.ctx.nodes.items) |node| {
        if (@abs(node.rect.w - 1200) < 0.5 and @abs(node.rect.h - 780) < 0.5 and node.style.background != null) {
            try testing.expectApproxEqAbs(@as(f32, 1.0), node.style.background.?.a, 0.001);
            saw_full_root = true;
        }
    }
    try testing.expect(saw_full_root);

    // Workspace shortcuts (e.g. Cmd+T) are blocked while onboarding is active.
    const tabs_before = h.a.tabs.items.items.len;
    h.press(.{ .key = 't', .cmd = true });
    try testing.expectEqual(tabs_before, h.a.tabs.items.items.len);
    try testing.expect(h.a.view.setup != null);

    // Skipping onboarding restores the workspace cleanly.
    try h.t.clickText("Skip setup");
    h.t.settle(1);
    try testing.expect(h.a.view.setup == null);
    try testing.expect(h.t.hasText("Cedar Notes"));
}

test "onboarding queries autonomy and Graff models once the engine connects after cold open" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.state = .disconnected;
    setup.open(&h.a, 0);
    h.t.settle(1);
    try testing.expect(!h.a.view.setup.?.engine_seeded);
    try testing.expectEqual(@as(usize, 0), h.a.engine.sent.items.len);

    // Engine finishes connecting while onboarding is already on screen.
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"GetAutonomy":{"autonomy":"read-only","chosen":true},"ListModels":{"models":[{"id":"graff-test","label":"Graff Test"}]}}
    , .{});
    h.a.engine.state = .connected;
    h.t.settle(2);
    while (h.a.engine.pump()) {}
    h.t.settle(1);
    try testing.expect(h.a.view.setup.?.engine_seeded);
    var saw_autonomy = false;
    var saw_models = false;
    for (h.a.engine.sent.items) |frame| {
        if (std.mem.indexOf(u8, frame, "\"GetAutonomy\"") != null) saw_autonomy = true;
        if (std.mem.indexOf(u8, frame, "\"ListModels\"") != null) saw_models = true;
    }
    try testing.expect(saw_autonomy);
    try testing.expect(saw_models);
    try testing.expectEqual(setup.Autonomy.read_only, h.a.view.setup.?.autonomy);
}

test "onboarding stays within narrow and short window bounds without clipping controls" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = false;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, harnesses, .{});
    defer parsed.deinit();
    try a.harnesses.replace(parsed.value);
    a.view.setup_checked = true;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 760, .height = 520, .dark = false });
    defer t.deinit();

    setup.open(&a, 0);
    t.settle(2);
    if (std.c.getenv("NANO_UX_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/after-setup-narrow.png", .{std.mem.span(dir)})) |path| {
            t.screenshot(path) catch {};
        } else |_| {}
    }

    try testing.expect(setup.layoutMetrics(760).stacked);
    try testing.expect(t.hasText("Skip setup"));
    try testing.expect(t.hasText("Next"));
    try testing.expect(t.hasText("Ready locally — sign in to CodeGraff anytime in Settings"));
    for (t.ctx.nodes.items) |node| {
        if (node.rect.w > 0 and node.rect.h > 0) {
            try testing.expect(node.rect.x + node.rect.w <= 760.5);
        }
    }
}

test "onboarding guards Next during active CLI install and supports arrow keys on notify and ready steps" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const missing =
        \\[{"id":"graff","name":"graff","installed":true,"enabled":true},
        \\ {"id":"claude-code","name":"Claude Code","installed":false,"enabled":false,"canInstall":true},
        \\ {"id":"codex","name":"Codex","installed":false,"enabled":false,"canInstall":true}]
    ;
    var p_missing = try std.json.parseFromSlice(std.json.Value, testing.allocator, missing, .{});
    defer p_missing.deinit();
    try h.a.harnesses.replace(p_missing.value);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"InstallHarness":{},"CancelInstall":{}}
    , .{});
    h.a.engine.state = .connected;

    setup.open(&h.a, 0);
    h.t.settle(1);
    setup.installExtra(&h.a, 0);
    const held = try h.a.engine.queued.toOwnedSlice(testing.allocator);
    defer {
        for (held) |frame| testing.allocator.free(frame);
        testing.allocator.free(held);
    }
    h.t.settle(1);
    h.press(.{ .key = S.enter });
    try testing.expectEqual(@as(usize, 0), h.a.view.setup.?.step);
    try testing.expect(h.t.hasText("Wait for the CLI install to finish, or click Cancel first."));

    // Escape cancels active CLI install rather than ignoring it.
    h.press(.{ .key = S.escape });
    try testing.expect(h.a.view.setup.?.installing == null);

    // Notify and ready steps respond to Left/Right arrows.
    h.a.view.setup.?.step = 3;
    h.t.settle(1);
    h.press(.{ .key = S.right });
    try testing.expect(!h.a.view.setup.?.notify);
    h.press(.{ .key = S.left });
    try testing.expect(h.a.view.setup.?.notify);

    h.a.view.setup.?.step = 4;
    h.t.settle(1);
    h.press(.{ .key = S.right });
    try testing.expectEqual(@as(?usize, 0), h.a.view.setup.?.starter);
    h.press(.{ .key = S.right });
    try testing.expectEqual(@as(?usize, 1), h.a.view.setup.?.starter);
}
