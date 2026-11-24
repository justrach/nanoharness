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

fn jumpRect(tester: *ui.Tester) !ui.Rect {
    for (tester.ctx.a11y_items.items) |item| {
        if (item.role == .button and item.enabled and std.mem.eql(u8, item.label, "Scroll to bottom"))
            return tester.ctx.node(item.node_index).rect;
    }
    return error.MissingJumpButton;
}

fn expectSameRect(expected: ui.Rect, actual: ui.Rect) !void {
    for ([_]f32{ expected.x, expected.y, expected.w, expected.h }, [_]f32{ actual.x, actual.y, actual.w, actual.h }) |want, got| {
        try t.expectApproxEqAbs(want, got, 0.01);
    }
}

fn clickJump(tester: *ui.Tester) !void {
    const r = try jumpRect(tester);
    tester.click(r.x + r.w / 2, r.y + r.h / 2);
    tester.settle(0.1);
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

test "composer dock puts the jump action below the input at every pane width" {
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
        const chip = try jumpRect(&tester);
        switch (width) {
            140 => try t.expect(tester.findText("Scroll to bottom") == null),
            520 => {
                const label = tester.findText("Scroll to bottom") orelse return error.MissingJumpLabel;
                try t.expect(label.x >= chip.x and label.x + label.w <= chip.x + chip.w + 0.5);
            },
            else => {},
        }
        const pill = a.view.composer_anchor orelse return error.MissingComposer;
        try t.expect(chip.x >= pill.x and chip.x + chip.w <= pill.x + pill.w + 0.5);
        try t.expect(chip.y >= pill.y + pill.h and chip.y + chip.h <= tester.size.h);
        try t.expectEqual(@as(f32, 20), chip.h);
        try clickJump(&tester);
        try t.expect(tester.ctx.scroll_follow.get(777) orelse false);
        try t.expectEqual(@as(f32, 0), a.view.jump_distance);
    }
}
test "composer dock keeps the narrow footer stable through a jump to bottom" {
    theme.registerFonts();
    var a: App = .init(t.allocator, t.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = false;
    const chats = try std.json.parseFromSlice(std.json.Value, t.allocator,
        \\[ {"id":"synthetic","deviceId":"d","title":"Example conversation","archived":false,"spaceId":"synthetic","config":{"harness":"graff","model":"Example model with a long display name","reasoning":"max"}} ]
    , .{});
    defer chats.deinit();
    try a.chats.replace(chats.value);
    a.openChat("synthetic", null);
    a.transcript.window = 200_000;
    a.transcript.tokens = 96_000;
    a.view.jump_box = 777;
    try t.expect(@import("view_composer.zig").followUpShown(&a));

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&a, view), .{ .width = 170, .height = 240 });
    defer tester.deinit();
    tester.advance(0.3);
    const rest = a.view.chip_anchor orelse return error.MissingModelChipAnchor;

    a.view.jump_distance = 800;
    tester.advance(0.3);
    const jump = try jumpRect(&tester);
    try t.expect(tester.findText("Scroll to bottom") == null);
    const x = jump.x + jump.w / 2;
    const y = jump.y + jump.h / 2;
    tester.moveTo(x, y);
    tester.down(x, y);
    // The model can change independently of the scroll position. Make its
    // chip visibly resize while held; the jump target must not follow it.
    const workspace = @import("workspace.zig");
    try t.expect(workspace.setChatConfig(&a.chats, "synthetic", "X", null, null, null));
    for (0..16) |_| {
        tester.frame();
        try expectSameRect(jump, try jumpRect(&tester));
    }
    const compact_model = a.view.chip_anchor orelse return error.MissingModelChipAnchor;
    try t.expect(compact_model.w < rest.w);
    try t.expect(workspace.setChatConfig(&a.chats, "synthetic", "Example model with a long display name", "max", null, null));
    for (0..16) |_| {
        tester.frame();
        try expectSameRect(jump, try jumpRect(&tester));
    }
    tester.up();
    try t.expect(tester.ctx.scroll_follow.get(777) orelse false);
    for (0..16) |_| {
        tester.frame();
        try t.expectError(error.MissingJumpButton, jumpRect(&tester));
        try expectSameRect(rest, a.view.chip_anchor orelse return error.MissingModelChipAnchor);
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
        const jump = try jumpRect(&tester);
        try t.expect(tray.y + tray.h + 7 <= pill.y);
        try t.expect(pill.y + pill.h <= jump.y and jump.y + jump.h <= 600);
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
        try clickJump(&tester);
        try t.expect(tester.ctx.scroll_follow.get(777) orelse false);
    };
}

fn findNoticeRect(tester: *const ui.Tester, needle: []const u8) ?ui.Rect {
    for (tester.ctx.nodes.items) |node| {
        if (node.content == .text and std.mem.eql(u8, node.content.text.str, needle)) return node.rect;
    }
    return null;
}

fn sendControlRect(tester: *const ui.Tester, pill: ui.Rect) ?ui.Rect {
    var best: ?ui.Rect = null;
    for (tester.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 28 and r.h == 28 and r.x >= pill.x + pill.w - 48 and
            r.y >= pill.y and r.y + r.h <= pill.y + pill.h)
        {
            best = r;
        }
    }
    return best;
}

fn attachControlRect(tester: *const ui.Tester, pill: ui.Rect) ?ui.Rect {
    for (tester.ctx.nodes.items) |node| {
        const r = node.rect;
        if (r.w == 28 and r.h == 28 and r.x >= pill.x and r.x <= pill.x + 24 and
            r.y >= pill.y and r.y + r.h <= pill.y + pill.h)
            return r;
    }
    return null;
}

fn rectsOverlap(a: ui.Rect, b: ui.Rect) bool {
    return a.x < b.x + b.w - 0.5 and b.x < a.x + a.w - 0.5 and
        a.y < b.y + b.h - 0.5 and b.y < a.y + a.h - 0.5;
}

test "composer long notice stays separate from the editable field across compact, expanded, narrow, Send and Stop states (#44)" {
    theme.registerFonts();
    const long_notice = "Couldn't attach the dropped file. Choose a readable, non-empty file up to 24 MB.";
    const Case = struct { width: usize, draft: []const u8, working: bool, snap_name: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .width = 640, .draft = "Example draft", .working = false, .snap_name = "compact-send" },
        .{ .width = 640, .draft = "", .working = true, .snap_name = "compact-stop" },
        .{ .width = 640, .draft = "Example draft", .working = true, .snap_name = "compact-working-draft" },
        .{ .width = 640, .draft = "Example draft\nSecond line", .working = false, .snap_name = "expanded" },
        .{ .width = 320, .draft = "Example draft", .working = false, .snap_name = "narrow-split" },
        .{ .width = 240, .draft = "Example draft", .working = true },
    };

    for (cases) |tc| {
        var a: App = .init(t.allocator, t.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = false;
        a.selected = try a.gpa.dupe(u8, "synthetic");
        a.view.strip.focused = .{ .chat = 0 };
        a.view.focus_composer = true;
        if (tc.working) {
            const sessions = try std.json.parseFromSlice(std.json.Value, t.allocator,
                \\[{"chatId":"synthetic","status":"working","updatedAt":"2099-01-01T00:00:00Z"}]
            , .{});
            defer sessions.deinit();
            try a.sessions.replace(sessions.value);
        }
        a.composer.set(tc.draft);
        a.setNotice(long_notice);

        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&a, view), .{
            .width = @floatFromInt(tc.width),
            .height = 220,
            .scale = 2,
            .dark = false,
            .theme = theme.ui(false),
        });
        defer tester.deinit();
        tester.settle(0.3);

        if (tc.snap_name) |name| {
            if (std.c.getenv("NANO_NOTICE_SNAP_DIR")) |dir| {
                var buf: [1024]u8 = undefined;
                const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
                try tester.screenshot(path);
            }
        }

        const pill = a.view.composer_anchor orelse return error.MissingComposer;
        const field = tester.ctx.rects.get(a.view.composer_id) orelse return error.MissingComposerField;
        const notice_rect = findNoticeRect(&tester, long_notice) orelse return error.MissingNoticeText;
        const send_btn = sendControlRect(&tester, pill) orelse return error.MissingSendOrStopButton;
        const attach_btn = attachControlRect(&tester, pill) orelse return error.MissingAttachButton;

        // Draft text must remain intact in storage.
        try t.expectEqualStrings(tc.draft, a.composer.text());
        // The editable field must keep a positive usable width (never crushed by the notice).
        const min_field_w: f32 = if (tc.width >= 640) 300 else 120;
        try t.expect(field.w >= min_field_w);
        try t.expect(field.h >= 20);
        // The notice must stay strictly inside the composer's horizontal width budget (wrapped, never clipped off right).
        try t.expect(notice_rect.x >= pill.x - 0.5);
        try t.expect(notice_rect.x + notice_rect.w <= pill.x + pill.w + 0.5);
        // The notice must not overlap the text field, attach button, or Send/Stop control.
        try t.expect(!rectsOverlap(notice_rect, field));
        try t.expect(!rectsOverlap(notice_rect, send_btn));
        try t.expect(!rectsOverlap(notice_rect, attach_btn));
        try t.expect(!rectsOverlap(field, send_btn));
        try t.expect(!rectsOverlap(field, attach_btn));
    }
}

test "composer notice appearance, update, and dismissal preserve draft text, focus, caret, selection, and undo (#44)" {
    theme.registerFonts();
    var a: App = .init(t.allocator, t.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = false;
    a.selected = try a.gpa.dupe(u8, "synthetic");
    a.view.strip.focused = .{ .chat = 0 };
    a.view.focus_composer = true;

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&a, view), .{
        .width = 640,
        .height = 220,
        .scale = 2,
        .dark = false,
        .theme = theme.ui(false),
    });
    defer tester.deinit();
    tester.settle(0.2);

    a.composer.set("Example");
    tester.settle(0.1);
    tester.textOps(&.{.{ .command = .move_line_end }});
    tester.textOps(&.{.{ .insert = " draft" }});
    tester.settle(0.1);
    const id_before = a.view.composer_id;
    try t.expect(id_before != 0);
    try t.expectEqual(id_before, tester.ctx.focus);
    // Select "draft" inside the field so we verify selection + caret survival.
    if (tester.ctx.edits.getPtr(id_before)) |e| {
        e.anchor = 8;
        e.caret = 13;
    }

    // Appearance of a long notice keeps the same field id, focus, draft, caret, and selection.
    a.setNotice("Couldn't attach the dropped file. Choose a readable, non-empty file up to 24 MB.");
    tester.settle(0.1);
    try t.expectEqual(id_before, a.view.composer_id);
    try t.expectEqual(id_before, tester.ctx.focus);
    try t.expectEqualStrings("Example draft", a.composer.text());
    const edit_during = tester.ctx.edits.get(id_before) orelse return error.MissingEditState;
    try t.expectEqual(@as(usize, 8), edit_during.anchor);
    try t.expectEqual(@as(usize, 13), edit_during.caret);

    // Updating the notice text keeps all editing state intact.
    a.setNotice("Only local files and images can be attached. Use Attach files to choose one.");
    tester.settle(0.1);
    try t.expectEqual(id_before, a.view.composer_id);
    try t.expectEqual(id_before, tester.ctx.focus);
    try t.expectEqualStrings("Example draft", a.composer.text());

    // Dismissing the notice via its close control keeps draft, focus, and undo history intact.
    const pill = a.view.composer_anchor orelse return error.MissingComposer;
    const dismiss_btn = for (tester.ctx.nodes.items) |node| {
        const r = node.rect;
        if (node.interactive and r.w == 18 and r.h == 18 and r.y + r.h <= pill.y) break r;
    } else return error.MissingNoticeDismissButton;
    tester.click(dismiss_btn.x + dismiss_btn.w / 2, dismiss_btn.y + dismiss_btn.h / 2);
    tester.settle(0.1);
    try t.expect(a.noticeText() == null);
    try t.expectEqual(id_before, a.view.composer_id);
    try t.expectEqual(id_before, tester.ctx.focus);
    try t.expectEqualStrings("Example draft", a.composer.text());
    tester.ctx.undo_op = .undo;
    tester.frame();
    tester.settle(0.1);
    try t.expectEqualStrings("Example", a.composer.text());
}

test "narrow split composer keeps Stop/Send unclipped and footer model + context ring inside bounds" {
    theme.registerFonts();
    for ([_]usize{ 160, 180, 200, 240 }) |width| {
        var a: App = .init(t.allocator, t.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = true;
        const spaces = try std.json.parseFromSlice(std.json.Value, t.allocator,
            \\[{"id":"p1","deviceId":"d","path":"/synthetic/fieldnotes","gitDetected":true}]
        , .{});
        defer spaces.deinit();
        try a.spaces.replace(spaces.value);
        const chats = try std.json.parseFromSlice(std.json.Value, t.allocator,
            \\[{"id":"synthetic","deviceId":"d","title":"Narrow Pane","archived":false,"spaceId":"p1","cwd":"/synthetic/fieldnotes","branch":"main","config":{"harness":"graff","model":"Gemini 4","reasoning":"max"}}]
        , .{});
        defer chats.deinit();
        try a.chats.replace(chats.value);
        const sessions = try std.json.parseFromSlice(std.json.Value, t.allocator,
            \\[{"chatId":"synthetic","status":"working","updatedAt":"2099-01-01T00:00:00Z"}]
        , .{});
        defer sessions.deinit();
        try a.sessions.replace(sessions.value);
        a.openChat("synthetic", null);
        a.transcript.window = 200_000;
        a.transcript.tokens = 96_000;
        // Simulate macOS dictation availability so Attach + Mic + Expand + Stop all contend for width.
        a.dictation.runtime = .{
            .codex = try a.gpa.dupe(u8, "/synthetic/codex"),
            .helper = try a.gpa.dupe(u8, "/synthetic/helper"),
        };
        a.dictation.probed.store(1, .release);

        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&a, view), .{
            .width = @floatFromInt(width),
            .height = 240,
            .scale = 2,
            .dark = true,
            .theme = theme.ui(true),
        });
        defer tester.deinit();
        tester.settle(0.5);

        if (width == 160) if (std.c.getenv("NANO_NARROW_SNAP_DIR")) |dir| {
            var buf: [1024]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/narrow-composer-footer.png", .{std.mem.span(dir)});
            try tester.screenshot(path);
        };

        const pill = a.view.composer_anchor orelse return error.MissingComposer;
        const stop_btn = sendControlRect(&tester, pill) orelse return error.MissingSendOrStopButton;
        // Stop/Send button must sit strictly inside the composer pill's right edge.
        try t.expect(stop_btn.x >= pill.x + 1.0);
        try t.expect(stop_btn.x + stop_btn.w <= pill.x + pill.w - 0.5);

        const chip_rect = a.view.chip_anchor orelse return error.MissingModelChipAnchor;
        const ctx_rect = a.view.context.anchor orelse return error.MissingContextAnchor;
        // Context ring pill and model chip must stay inside the composer width and never overlap.
        try t.expect(ctx_rect.x + ctx_rect.w <= pill.x + pill.w + 0.5);
        try t.expect(chip_rect.x + chip_rect.w <= ctx_rect.x + 0.5);

        // No text inside the footer row may overflow past its chip or the composer's right edge.
        const footer_top = pill.y + pill.h + 4;
        for (tester.ctx.nodes.items) |node| {
            if (node.content != .text or node.rect.y < footer_top) continue;
            try t.expect(node.rect.x + node.rect.w <= pill.x + pill.w + 0.5);
            if (node.rect.x >= chip_rect.x - 1 and node.rect.x < ctx_rect.x) {
                try t.expect(node.rect.x + node.rect.w <= chip_rect.x + chip_rect.w + 0.5);
            }
        }
    }
}

test "composer dock compact queue editing keeps message text visible and recovers from missing or conflict finish" {
    theme.registerFonts();
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
        \\{"BeginQueuedMessageEdit":{"outcome":"acquired","leaseId":"synthetic-lease","baseTextHash":"synthetic-hash","text":"Updated queued edit"},"FinishQueuedMessageEdit":{"outcome":"missing"}}
    , .{});
    a.engine.state = .connected;
    try queue(&a, 1);

    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&a, view), .{ .width = 360, .height = 480, .theme = theme.ui(false) });
    defer tester.deinit();
    tester.settle(0.5);

    a.queueBeginEdit("q0");
    _ = a.engine.pump();
    tester.settle(0.5);
    try t.expect(a.queue_edit != null);
    try t.expect(tester.containsText("Editing · Synthetic queued message 0"));

    // Terminal server finish states (`missing` / `conflict`) release `queue_edit` while preserving user text.
    a.composer.set("Locally preserved edit text");
    a.queueFinishEdit(.commit);
    _ = a.engine.pump();
    tester.settle(0.5);
    try t.expect(a.queue_edit == null);
    try t.expectEqualStrings("Locally preserved edit text", a.composer.text());
    try t.expectEqualStrings("The queued message was removed; your edit was kept locally", a.notice[0..a.notice_len]);
}
