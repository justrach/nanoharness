//! Synthetic production dock: queue, growing input and jump affordance share
//! geometry, without engine requests, clipboard access or a visible window.
const std = @import("std");
const t = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");

fn view(a: *App, c: *ui.Context) void {
    a.view.chrome.width = c.size.w;
    a.view.chrome.chat_width = c.size.w;
    const root = ui.div(c).column().sizeFull().justifyEnd();
    defer root.end();
    @import("view_composer.zig").docked(c, a, theme.colors(a.dark orelse false));
}

fn queue(a: *App, count: usize) !void {
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(a.gpa);
    try rows.appendSlice(a.gpa, "[");
    for (0..count) |i| {
        if (i > 0) try rows.appendSlice(a.gpa, ",");
        try rows.print(a.gpa, "{{\"id\":\"q{d}\",\"text\":\"Synthetic queued message {d}\"}}", .{ i, i });
    }
    try rows.appendSlice(a.gpa, "]");
    const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, rows.items, .{});
    defer parsed.deinit();
    try a.queue.replace(parsed.value);
}

fn attach(a: *App) !void {
    const Item = @import("app_attachments.zig").Item;
    const item = try a.gpa.create(Item);
    item.* = .{
        .app = a,
        .owner = try a.gpa.dupe(u8, "synthetic"),
        .name = try a.gpa.dupe(u8, "image.png"),
        .bytes = try a.gpa.dupe(u8, @embedFile("reply-image-fixture.png")),
        .target = null,
        .id = "00000000-0000-0000-0000-000000000001".*,
        .status = .ready,
    };
    try a.attachments.items.append(a.gpa, item);
}

fn parentOfText(tester: *ui.Tester, label: []const u8) !u32 {
    for (tester.ctx.nodes.items) |n| {
        if (n.content == .text and std.mem.eql(u8, n.content.text.str, label)) return n.parent;
    }
    return error.MissingDockText;
}

fn pillRect(tester: *ui.Tester) !ui.Rect {
    var found: ?ui.Rect = null;
    for (tester.ctx.nodes.items) |node| {
        const r = node.rect;
        if (node.style.border != null and r.w > 0 and r.h > 0 and
            (found == null or r.y + r.h > found.?.y + found.?.h))
            found = r;
    }
    return found orelse error.MissingComposer;
}

fn trayRect(tester: *ui.Tester, pill: ui.Rect) !ui.Rect {
    var found: ?ui.Rect = null;
    for (tester.ctx.nodes.items) |node| {
        const r = node.rect;
        if (node.style.border != null and r.w > 0 and r.h > 0 and r.y + r.h <= pill.y and
            (found == null or r.y + r.h > found.?.y + found.?.h))
            found = r;
    }
    return found orelse error.MissingQueueSurface;
}

fn snap(tester: *ui.Tester, width: usize, draft: usize, count: usize) !void {
    const dir = std.c.getenv("NANO_DOCK_SNAP_DIR") orelse return;
    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/dock-{d}-{d}-{d}.png", .{ std.mem.span(dir), width, draft, count });
    try tester.screenshot(path);
}

fn actionRect(tester: *ui.Tester, tray: ui.Rect, label: []const u8) !ui.Rect {
    // Find controls through their actual hover labels, not sibling order.
    var candidates: std.ArrayList(ui.Rect) = .empty;
    defer candidates.deinit(t.allocator);
    for (tester.ctx.nodes.items) |node| {
        const r = node.rect;
        if (node.interactive and r.w == 28 and r.h == 28 and
            r.x >= tray.x and r.x + r.w <= tray.x + tray.w and
            r.y >= tray.y and r.y + r.h <= tray.y + tray.h)
            try candidates.append(t.allocator, r);
    }
    for (candidates.items) |r| {
        tester.moveTo(r.x + r.w / 2, r.y + r.h / 2);
        tester.advance(0.4);
        if (tester.ctx.tooltip.shown) |shown| {
            if (std.mem.eql(u8, shown.text, label)) return r;
        }
    }
    std.debug.print("Queue action is not fully visible: {s}\n", .{label});
    return error.MissingVisibleQueueAction;
}

test "composer dock keeps priority queue actions visible in narrow panes" {
    theme.registerFonts();
    for ([_]usize{ 140, 160, 180, 200, 220, 240, 320, 520 }) |width| {
        var a: App = .init(t.allocator, t.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = false;
        a.selected = try a.gpa.dupe(u8, "synthetic");
        a.new_harness = try a.gpa.dupe(u8, "graff");
        a.view.strip.focused = .{ .chat = 0 };
        a.caps.actions = true;
        try queue(&a, 1);
        try t.expect(@import("app_queue.zig").rowCanSteer(&a, a.queue.items[0]));
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&a, view), .{ .width = @floatFromInt(width), .height = 480, .theme = theme.ui(false) });
        defer tester.deinit();
        tester.settle(0.5);
        try snap(&tester, width, 0, 1);
        const pill = a.view.composer_anchor orelse return error.MissingComposer;
        const tray = try trayRect(&tester, pill);
        const icons_only = @import("view_queue.zig").rowLayout(pill.w, 4).stacked;
        try t.expect(tray.w <= pill.w + 0.1);
        try t.expectApproxEqAbs(pill.x + pill.w / 2, tray.x + tray.w / 2, 0.1);
        try t.expect(tray.y + tray.h + 7 <= pill.y);
        if (icons_only)
            try t.expect(!tester.containsText("Synthetic queued message 0"))
        else
            try t.expectApproxEqAbs(pill.w, tray.w, 0.1);
        const actions = [_]ui.Rect{
            try actionRect(&tester, tray, "Edit"),
            try actionRect(&tester, tray, "Steer into active turn"),
            try actionRect(&tester, tray, "Remove"),
            try actionRect(&tester, tray, "Send now (interrupt)"),
        };
        if (icons_only) {
            var grid_left = actions[0].x;
            var grid_right = actions[0].x + actions[0].w;
            for (actions) |action| {
                grid_left = @min(grid_left, action.x);
                grid_right = @max(grid_right, action.x + action.w);
            }
            // Only the existing border, surface padding and row gutters
            // should surround the actual buttons, not stretched empty space.
            try t.expectApproxEqAbs(grid_right - grid_left + 26, tray.w, 0.1);
            for (actions) |action| {
                var left = action.x;
                var right = action.x + action.w;
                for (actions) |other| {
                    if (@abs(other.y - action.y) > 0.1) continue;
                    left = @min(left, other.x);
                    right = @max(right, other.x + other.w);
                }
                try t.expectApproxEqAbs(tray.x + tray.w / 2, (left + right) / 2, 0.1);
            }
        }
    }
}

test "composer dock wrapped queue controls dispatch their original actions" {
    theme.registerFonts();
    const cases = [_][2][]const u8{
        .{ "Edit", "BeginQueuedMessageEdit" },
        .{ "Steer into active turn", "SteerQueuedMessageNow" },
        .{ "Remove", "RemoveQueuedMessage" },
        .{ "Send now (interrupt)", "SendQueuedMessageNow" },
    };
    for ([_]usize{ 140, 200 }) |width| for (cases) |case| {
        var a: App = .init(t.allocator, t.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = false;
        a.selected = try a.gpa.dupe(u8, "synthetic");
        a.new_harness = try a.gpa.dupe(u8, "graff");
        a.view.strip.focused = .{ .chat = 0 };
        a.caps.actions = true;
        a.caps.edit_lease = true;
        a.engine.scene = try std.json.parseFromSlice(std.json.Value, a.gpa,
            \\{"BeginQueuedMessageEdit":{"outcome":"acquired","leaseId":"synthetic-lease","baseTextHash":"synthetic-hash","text":"Synthetic queued message 0"},"FinishQueuedMessageEdit":{"outcome":"cancelled"}}
        , .{});
        a.engine.state = .connected;
        try queue(&a, 1);
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&a, view), .{ .width = @floatFromInt(width), .height = 480, .theme = theme.ui(false) });
        defer tester.deinit();
        tester.settle(0.5);
        const pill = a.view.composer_anchor orelse return error.MissingComposer;
        const r = try actionRect(&tester, try trayRect(&tester, pill), case[0]);
        tester.click(r.x + r.w / 2, r.y + r.h / 2);
        var sent = false;
        for (a.engine.sent.items) |frame| {
            const parsed = try std.json.parseFromSlice(std.json.Value, a.gpa, frame, .{});
            defer parsed.deinit();
            const o = parsed.value.object;
            if (!std.mem.eql(u8, o.get("method").?.string, case[1])) continue;
            try t.expectEqualStrings("synthetic", o.get("params").?.object.get("chatId").?.string);
            try t.expectEqualStrings("q0", o.get("params").?.object.get("id").?.string);
            sent = true;
        }
        try t.expect(sent);
        if (std.mem.eql(u8, case[0], "Edit")) {
            _ = a.engine.pump();
            tester.settle(0.5);
            const tray = try trayRect(&tester, pill);
            _ = try actionRect(&tester, tray, "Save to queue");
            const cancel = try actionRect(&tester, tray, "Cancel");
            tester.click(cancel.x + cancel.w / 2, cancel.y + cancel.h / 2);
            _ = a.engine.pump();
            try t.expect(a.queue_edit == null);
        }
    };
}

test "composer dock jump label wraps within narrow panes and remains clickable" {
    theme.registerFonts();
    var a: App = .init(t.allocator, t.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = false;
    a.selected = try a.gpa.dupe(u8, "synthetic");
    a.view.strip.focused = .{ .chat = 0 };
    a.view.jump_box = 777;
    try queue(&a, 1);
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&a, view), .{ .width = 520, .height = 600 });
    defer tester.deinit();
    // Resize the same mounted dock down and back up, not just fresh views.
    for ([_]usize{ 520, 140, 160, 180, 200, 240, 320, 520 }) |width| {
        tester.size.w = @floatFromInt(width);
        a.view.jump_distance = 800;
        tester.ctx.scroll_follow.put(t.allocator, 777, false) catch unreachable;
        tester.settle(0.5);
        const label_index = blk: {
            for (tester.ctx.nodes.items, 0..) |n, i| {
                if (n.content == .text and std.mem.eql(u8, n.content.text.str, "Scroll to bottom")) break :blk @as(u32, @intCast(i));
            }
            return error.MissingJumpLabel;
        };
        const label = tester.ctx.node(label_index);
        var chip_index = label.parent;
        while (tester.ctx.node(chip_index).style.border == null) chip_index = tester.ctx.node(chip_index).parent;
        const chip = tester.ctx.node(chip_index).rect;
        const tray = try trayRect(&tester, try pillRect(&tester));
        const dir = std.c.getenv("NANO_JUMP_SNAP_DIR");
        if (dir != null and (width == 140 or width == 520)) {
            var buf: [1024]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/jump-{d}.png", .{ std.mem.span(dir.?), width });
            try tester.screenshot(path);
        }
        try t.expect(chip.x >= 16 and chip.x + chip.w <= tester.size.w - 16 + 0.5);
        try t.expect(label.rect.x >= chip.x and label.rect.x + label.rect.w <= chip.x + chip.w);
        try t.expect(label.rect.y >= chip.y and label.rect.y + label.rect.h <= chip.y + chip.h);
        try t.expect(chip.y >= 0 and chip.y + chip.h + 5 <= tray.y);
        if (width == 140) {
            try t.expect(label.content.text.lines.len > 1);
            try t.expect(chip.h > 30);
        } else if (width == 520) {
            try t.expectEqual(@as(f32, 18), label.rect.h);
            try t.expectEqual(@as(f32, 30), chip.h);
        }
        try tester.clickText("Scroll to bottom");
        try t.expect(tester.ctx.scroll_follow.get(777) orelse false);
        try t.expectEqual(@as(f32, 0), a.view.jump_distance);
    }
}
test "composer dock separates queue tray jump button and growing input" {
    theme.registerFonts();
    for ([_]usize{ 320, 520, 900 }) |width| for (0..3) |draft| for ([_]usize{ 1, 8 }) |count| {
        var a: App = .init(t.allocator, t.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = false;
        a.selected = try a.gpa.dupe(u8, "synthetic");
        a.view.strip.focused = .{ .chat = 0 };
        a.view.jump_box = 777;
        a.view.jump_distance = 800;
        try queue(&a, count);
        if (draft > 0) a.composer.set("Synthetic draft\nSecond line");
        if (draft == 2) try attach(&a);
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&a, view), .{ .width = @floatFromInt(width), .height = 600 });
        defer tester.deinit();
        tester.settle(0.5);
        try snap(&tester, width, draft, count);
        const pill = a.view.composer_anchor orelse return error.MissingComposer;
        const tray = try trayRect(&tester, pill);
        const jump = tester.ctx.node(try parentOfText(&tester, "Scroll to bottom")).rect;
        try t.expect(tray.y + tray.h + 7 <= pill.y);
        try t.expect(jump.y + jump.h + 5 <= tray.y);
        try t.expect(jump.y >= 0);
        try t.expect(pill.y + pill.h <= 600);
        if (count == 8) {
            const viewport = for (tester.ctx.nodes.items) |node| {
                if ((tester.ctx.scroll_max.get(node.id) orelse 0) > 0 and node.rect.y >= tray.y and node.rect.y + node.rect.h <= tray.y + tray.h) break node.rect;
            } else return error.MissingQueueScrollViewport;
            tester.moveTo(viewport.x + viewport.w / 2, viewport.y + viewport.h / 2);
            tester.scroll(viewport.x + viewport.w / 2, viewport.y + viewport.h / 2, -10000);
            tester.settle(0.2);
            const last = tester.findText("Synthetic queued message 7") orelse return error.MissingLastQueuedRow;
            try t.expect(last.y >= viewport.y and last.y + last.h <= viewport.y + viewport.h);
        }
        try tester.clickText("Scroll to bottom");
        try t.expect(tester.ctx.scroll_follow.get(777) orelse false);
    };
}
