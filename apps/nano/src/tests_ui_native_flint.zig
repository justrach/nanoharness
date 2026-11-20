//! Settings › Agents › Native Flint managed server + unified-memory UI tests
//! (macOS Apple Silicon only; synthetic payloads, no real weights or engine).
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const agents_view = @import("view_settings_agents.zig");
const testing = std.testing;

const mock_harnesses =
    \\[{"id":"graff","name":"graff","installed":true,"canInstall":false,"enabled":true,"supportsSteering":true,"steeringMode":"step-boundary","reasoningLevels":["medium","high"]}]
;

const status_stopped_128gb =
    \\{"platformSupported":true,"ramSupported":true,"ramTier":"optimal","totalRamGb":128,"minRamGb":32,"recommendedContext":65536,"maxContext":131072,"estimatedFootprintGb":37,"binaryAvailable":true,"checkpointDir":"/Users/demo/models/flint-int4","checkpointValid":true,"state":"stopped","context":65536}
;

const status_running_128gb =
    \\{"platformSupported":true,"ramSupported":true,"ramTier":"optimal","totalRamGb":128,"minRamGb":32,"recommendedContext":65536,"maxContext":131072,"estimatedFootprintGb":37,"binaryAvailable":true,"checkpointDir":"/Users/demo/models/flint-int4","checkpointValid":true,"state":"running","context":65536,"endpointUrl":"http://127.0.0.1:41234/v1/chat/completions"}
;

const status_low_ram_16gb =
    \\{"platformSupported":true,"ramSupported":false,"ramTier":"insufficient_ram","totalRamGb":16,"minRamGb":32,"recommendedContext":0,"maxContext":0,"estimatedFootprintGb":25,"binaryAvailable":true,"checkpointDir":"/Users/demo/models/flint-int4","checkpointValid":true,"state":"stopped","context":0}
;

const status_tight_32gb =
    \\{"platformSupported":true,"ramSupported":true,"ramTier":"tight","totalRamGb":32,"minRamGb":32,"recommendedContext":8192,"maxContext":16384,"estimatedFootprintGb":25,"binaryAvailable":true,"checkpointDir":"/Users/demo/models/flint-int4","checkpointValid":true,"state":"stopped","context":8192}
;

fn openSettingsAgents(a: *App, t: *ui.Tester, dark: bool, status_json: []const u8) !void {
    @import("theme.zig").registerFonts();
    a.* = .init(testing.allocator, testing.io, 1);
    a.dark = dark;
    a.view.settings_open = true;
    a.settings.setSection(.harnesses);
    const h = try std.json.parseFromSlice(std.json.Value, testing.allocator, mock_harnesses, .{});
    defer h.deinit();
    agents_view.setList(a, h.value);
    const st = try std.json.parseFromSlice(std.json.Value, testing.allocator, status_json, .{});
    defer st.deinit();
    agents_view.setFlintStatus(a, st.value);
    try t.init(testing.allocator, .init(a, @import("view.zig").view), .{ .width = 1120, .height = 920, .dark = dark });
    t.settle(1);
}

fn snap(t: *ui.Tester, name: []const u8) void {
    const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
    t.screenshot(path) catch {};
}

test "Native Flint card shows RAM headroom, context pills, and running route on macOS" {
    if (comptime builtin.os.tag != .macos) return;
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try openSettingsAgents(&a, &t, false, status_stopped_128gb);
    defer {
        t.deinit();
        a.deinit();
    }
    try testing.expect(t.hasText("Native Flint"));
    try testing.expect(t.hasText("Off"));
    try testing.expect(t.containsText("128 GB unified memory"));
    try testing.expect(t.hasText("64K"));
    try testing.expect(t.hasText("128K"));
    try testing.expect(t.hasText("Choose weights folder…"));
    snap(&t, "native-flint-stopped-light");

    // Picking another context updates the live RAM estimate.
    try t.clickText("32K");
    t.settle(1);
    try testing.expect(t.containsText("~31 GB estimated for 32K context"));

    // Simulate running state.
    const running = try std.json.parseFromSlice(std.json.Value, testing.allocator, status_running_128gb, .{});
    defer running.deinit();
    agents_view.setFlintStatus(&a, running.value);
    t.settle(1);
    try testing.expect(t.hasText("Running"));
    try testing.expect(t.containsText("Active in Graff as nanoattention/flint"));
    snap(&t, "native-flint-running-light");
}

test "Native Flint card blocks low-RAM Macs and caps 32 GB Macs cleanly" {
    if (comptime builtin.os.tag != .macos) return;
    {
        var a: App = undefined;
        var t: ui.Tester = undefined;
        try openSettingsAgents(&a, &t, false, status_low_ram_16gb);
        defer {
            t.deinit();
            a.deinit();
        }
        try testing.expect(t.hasText("Needs 32 GB RAM"));
        try testing.expect(t.containsText("16 GB unified memory"));
        try testing.expect(!t.hasText("64K"));
        snap(&t, "native-flint-lowram-light");
    }
    {
        var a: App = undefined;
        var t: ui.Tester = undefined;
        try openSettingsAgents(&a, &t, true, status_tight_32gb);
        defer {
            t.deinit();
            a.deinit();
        }
        try testing.expect(t.containsText("Tight fit on 32 GB Macs"));
        // Clicking a capped preset (32K on a 32 GB Mac) must not select it.
        try t.clickText("32K");
        t.settle(1);
        try testing.expect(t.containsText("~25 GB estimated for 8K context"));
        snap(&t, "native-flint-tight-dark");
    }
}
