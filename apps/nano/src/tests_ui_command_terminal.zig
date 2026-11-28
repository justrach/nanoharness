//! Offscreen regression: a finished shell fence offers Review, runs only on
//! confirmation, and reopens the same PTY without sending input to chat.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;
const actions = @import("app_actions.zig");
const source = "printf 'Synthetic prompt: '; read reply";
const fence = "```sh\n" ++ source ++ "\n```\n\n```python\nprint(42)\n```";

const Fixture = struct {
    a: App,
    capability: bool = true,

    fn draw(f: *Fixture, c: *ui.Context) void {
        const k = @import("theme.zig").colors(false);
        c.theme = @import("theme.zig").ui(false);
        const col = ui.div(c).column().sizeFull().p(12).bg(k.shell);
        defer col.end();
        const markdown = @import("view_markdown.zig");
        if (f.capability) markdown.withCommandBlocks(c, k, fence, &f.a, "chat", null) else markdown.withLinks(c, k, fence, &f.a, "chat");
        @import("view_actions.zig").dock(c, &f.a, k);
        @import("view_actions.zig").overlays(c, &f.a, k);
    }
};

fn capture(t: *ui.Tester, name: []const u8) !void {
    const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
    var path: [4096]u8 = undefined;
    try t.screenshot(try std.fmt.bufPrint(&path, "{s}/{s}.png", .{ std.mem.span(dir), name }));
}

fn buttonCount(t: *ui.Tester, label: []const u8) usize {
    var n: usize = 0;
    for (t.ctx.a11y_items.items) |item| n += @intFromBool(std.mem.eql(u8, item.label, label));
    return n;
}

fn clickButton(t: *ui.Tester, label: []const u8) !void {
    for (t.ctx.a11y_items.items) |item| {
        if (!std.mem.eql(u8, item.label, label)) continue;
        const r = t.ctx.node(item.node_index).rect;
        t.click(r.x + r.w / 2, r.y + r.h / 2);
        t.settle(0.1);
        return;
    }
    return error.NoTerminalButton;
}

fn methodCount(a: *const App, method: []const u8) !usize {
    var total: usize = 0;
    for (a.engine.sent.items) |raw| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
        defer parsed.deinit();
        const m = parsed.value.object.get("method") orelse continue;
        total += @intFromBool(std.mem.eql(u8, m.string, method));
    }
    return total;
}

fn lastParams(a: *const App) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, a.engine.sent.items[a.engine.sent.items.len - 1], .{});
}

test "transcript command review, input, and reopening use the same local terminal" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    @import("theme.zig").registerFonts();
    var f: Fixture = .{ .a = .init(testing.allocator, testing.io, 1) };
    defer f.a.deinit();
    f.a.offscreen = true;
    f.a.device_id = try f.a.gpa.dupe(u8, "local");
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[ {"id":"chat","deviceId":"local","title":"Synthetic","cwd":"/synthetic/worktree"},
        \\  {"id":"other","deviceId":"remote","title":"Other","cwd":"/synthetic/other"} ]
    , .{});
    defer chats.deinit();
    try f.a.chats.replace(chats.value);
    f.a.openChat("chat", null);
    f.a.engine.scene = try std.json.parseFromSlice(std.json.Value, f.a.gpa,
        \\{"OpenLocalCommandTerminal":{"id":"synthetic-pty"},"SubscribeTerminal":{},"WriteTerminal":{},"CloseTerminal":{}}
    , .{});
    f.a.engine.state = .connected;

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.draw), .{ .width = 800, .height = 650, .dark = false });
    defer t.deinit();
    t.settle(0.25);
    try testing.expectEqual(@as(usize, 1), buttonCount(&t, "Review command to run"));
    f.capability = false;
    t.frame();
    try testing.expectEqual(@as(usize, 0), buttonCount(&t, "Review command to run"));
    try capture(&t, "command-terminal-before");
    f.capability = true;
    t.frame();
    try clickButton(&t, "Review command to run");
    try testing.expect(t.hasText("Review command"));
    try testing.expectEqual(@as(usize, 0), try methodCount(&f.a, "OpenLocalCommandTerminal"));
    try t.clickText("Cancel");
    try testing.expectEqual(@as(usize, 0), try methodCount(&f.a, "OpenLocalCommandTerminal"));

    try clickButton(&t, "Review command to run");
    try t.clickText("Run in terminal");
    try testing.expectEqual(@as(usize, 1), try methodCount(&f.a, "OpenLocalCommandTerminal"));
    {
        const parsed = try lastParams(&f.a);
        defer parsed.deinit();
        const params = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings("/synthetic/worktree", params.get("cwd").?.string);
        try testing.expectEqualStrings("sh", params.get("command").?.object.get("shell").?.string);
        try testing.expectEqualStrings(source, std.mem.trimEnd(u8, params.get("command").?.object.get("source").?.string, "\n"));
        try testing.expect(params.get("targetDeviceId") == null);
    }
    _ = f.a.engine.pump();
    const watch = f.a.actions.runs.items[0].watch orelse return error.NoTerminalSubscription;
    var frame_buf: [256]u8 = undefined;
    try f.a.engine.mux.dispatch(try std.fmt.bufPrint(&frame_buf, "{{\"id\":{d},\"item\":{{\"type\":\"data\",\"data\":\"U3ludGhldGljIHByb21wdDog\"}}}}", .{watch}));
    t.settle(0.1);
    try testing.expect(t.hasText("Synthetic prompt: "));
    try capture(&t, "command-terminal-after");
    t.typeText("reply\n");
    {
        const parsed = try lastParams(&f.a);
        defer parsed.deinit();
        try testing.expectEqualStrings("WriteTerminal", parsed.value.object.get("method").?.string);
        const params = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings("synthetic-pty", params.get("terminalId").?.string);
        try testing.expectEqualStrings("cmVwbHk=", params.get("data").?.string);
    }
    t.key(.enter);
    // The engine may handle concurrent RPCs out of order; hold Return until
    // the pending text write has been acknowledged.
    try testing.expectEqual(@as(usize, 1), try methodCount(&f.a, "WriteTerminal"));
    _ = f.a.engine.pump();
    try testing.expectEqual(@as(usize, 2), try methodCount(&f.a, "WriteTerminal"));
    {
        const parsed = try lastParams(&f.a);
        defer parsed.deinit();
        try testing.expectEqualStrings("DQ==", parsed.value.object.get("params").?.object.get("data").?.string);
    }
    try testing.expect(!t.hasText("reply"));
    f.a.actions.dock_open = false;
    t.frame();
    try clickButton(&t, "Open command terminal");
    try testing.expect(t.hasText("Synthetic prompt: "));
    try testing.expectEqual(@as(usize, 1), try methodCount(&f.a, "OpenLocalCommandTerminal"));
    try testing.expect(actions.commandCwd(&f.a, "other") == null);
    actions.closeRun(&f.a, 0);
    try testing.expectEqual(@as(usize, 1), try methodCount(&f.a, "CloseTerminal"));
}
