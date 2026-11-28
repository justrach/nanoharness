//! Reload coverage for Nano's tab/split record. Synthetic chats only.
const std = @import("std");
const ui = @import("nanoui").ui;
const testing = std.testing;
const App = @import("app.zig").App;
const tabs = @import("tabs.zig");
const persistence = @import("app_tab_layout.zig");

fn chats(a: *App) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"a","deviceId":"d","title":"A","archived":false},
        \\ {"id":"b","deviceId":"d","title":"B","archived":false},
        \\ {"id":"c","deviceId":"d","title":"C","archived":false},
        \\ {"id":"d","deviceId":"d","title":"D","archived":false},
        \\ {"id":"e","deviceId":"d","title":"E","archived":false}]
    , .{});
    defer parsed.deinit();
    try a.chats.replace(parsed.value);
}

fn own(a: *App, text: []const u8) ![]u8 {
    return a.gpa.dupe(u8, text);
}

fn loadHistory(t: *@import("transcript.zig").Transcript, count: usize, streaming_last: bool) !void {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(testing.allocator);
    try json.appendSlice(testing.allocator, "{\"reset\":[");
    for (0..count) |i| {
        if (i > 0) try json.appendSlice(testing.allocator, ",");
        try json.print(testing.allocator,
            \\{{"id":"r{d}","role":"assistant","status":"{s}","parts":[{{"id":"p","kind":"text","text":"Synthetic reply {d}\\n\\nA long synthetic message keeps enough rows to exercise transcript restoration.\\n\\nAnother paragraph for a stable position."}}]}}
        , .{ i, if (streaming_last and i + 1 == count) "streaming" else "complete", i });
    }
    try json.appendSlice(testing.allocator, "]}");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json.items, .{});
    defer parsed.deinit();
    try t.apply(parsed.value);
}

const TranscriptFixture = struct {
    a: *App,
    box: u64 = 0,

    fn draw(f: *@This(), c: *ui.Context) void {
        f.a.markdown_cache.beginFrame();
        f.box = @import("view_transcript.zig").entries(
            c,
            f.a,
            @import("theme.zig").colors(true),
            &f.a.transcript,
            c.size.w,
            false,
            0,
        ).box;
    }
};

fn prepareChat(a: *App, id: []const u8) !void {
    try chats(a);
    a.selected = try own(a, id);
    a.tabs.items.items[0] = try own(a, id);
    a.tabs_ready = true;
}

fn findTextContaining(t: *ui.Tester, text: []const u8) ?@import("nanoui").ui.Rect {
    for (t.ctx.nodes.items) |node| switch (node.content) {
        .text => |drawn| if (std.mem.indexOf(u8, drawn.str, text) != null) return node.rect,
        .icon, .image, .texture, .hole, .canvas, .none => {},
    };
    return null;
}

test "split layout survives a reload with axis shares focus zoom and panel tabs" {
    var first: App = .init(testing.allocator, testing.io, 1);
    defer first.deinit();
    try chats(&first);
    first.tabs_ready = true;

    first.tabs.items.items[0] = try own(&first, "a");
    first.tabs.appendTab();
    first.tabs.items.items[1] = try own(&first, "e");
    first.tabs.active = 0;

    var split: tabs.Split = .{ .axis = .horizontal, .focus = 1, .zoomed = true };
    try split.panes.append(first.gpa, try own(&first, "b"));
    try split.panes.append(first.gpa, null);
    try split.panes.append(first.gpa, try own(&first, "c"));
    try split.shares.append(first.gpa, 0.4);
    try split.shares.append(first.gpa, 0.3);
    try split.shares.append(first.gpa, 0.3);
    for (0..3) |_| try split.drafts.append(first.gpa, null);
    try split.groups[0].items.append(first.gpa, .{});
    try split.groups[0].items.append(first.gpa, .{ .chat = try own(&first, "d") });
    first.tabs.splits.items[0] = split;
    first.seedTranscriptPosition("b", "b-row", -9, 190, false, false);
    first.seedTranscriptPosition("c", "c-row", 14, 310, false, false);

    first.rememberTabs();
    const body = first.settings.tabLayout() orelse return error.MissingLayout;

    var second: App = .init(testing.allocator, testing.io, 1);
    defer second.deinit();
    try chats(&second);
    second.settings.setTabLayout(body);
    second.restoreTabs();

    try testing.expectEqual(@as(usize, 2), second.tabs.items.items.len);
    try testing.expectEqual(@as(usize, 0), second.tabs.active);
    try testing.expectEqualStrings("a", second.tabs.current().?);
    try testing.expectEqualStrings("e", second.tabs.items.items[1].?);
    const restored = second.tabs.layout() orelse return error.MissingSplit;
    try testing.expect(restored.axis == .horizontal);
    try testing.expectEqual(@as(usize, 1), restored.focus);
    try testing.expect(restored.zoomed);
    try testing.expectEqual(@as(usize, 3), restored.panes.items.len);
    try testing.expectEqualStrings("b", restored.panes.items[0].?);
    try testing.expect(restored.panes.items[1] == null);
    try testing.expectEqualStrings("c", restored.panes.items[2].?);
    try testing.expectApproxEqAbs(@as(f32, 0.4), restored.shares.items[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.3), restored.shares.items[2], 1e-6);
    try testing.expectEqual(@as(usize, 2), restored.groups[0].items.items.len);
    try testing.expect(restored.groups[0].items.items[0].chat == null);
    try testing.expectEqualStrings("d", restored.groups[0].items.items[1].chat.?);
    try testing.expectEqualStrings("a", second.selected.?);
    const b_view = second.transcriptPosition("b") orelse return error.MissingPaneBViewport;
    const c_view = second.transcriptPosition("c") orelse return error.MissingPaneCViewport;
    try testing.expect(b_view.pending and c_view.pending);
    try testing.expectEqualStrings("b-row", b_view.entry.?);
    try testing.expectEqualStrings("c-row", c_view.entry.?);
    try testing.expectApproxEqAbs(@as(f32, -9), b_view.inset, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 14), c_view.inset, 0.01);
}

test "restored transcript anchor preserves the same reading position after layout reload" {
    @import("theme.zig").registerFonts();
    var first: App = .init(testing.allocator, testing.io, 1);
    defer first.deinit();
    try prepareChat(&first, "a");
    try loadHistory(&first.transcript, 48, false);
    var first_fixture: TranscriptFixture = .{ .a = &first };
    var first_ui: ui.Tester = undefined;
    try first_ui.init(testing.allocator, .init(&first_fixture, TranscriptFixture.draw), .{ .width = 670, .height = 410, .dark = true });
    defer first_ui.deinit();
    first_ui.settle(0.25);
    const box = @import("app.zig").transcriptScrollBox("a");
    const max = first_ui.ctx.scroll_max.get(box) orelse return error.MissingScrollRange;
    try testing.expect(max > 500);
    const saved_offset = max * 0.45;
    first_ui.ctx.scroll.put(testing.allocator, box, saved_offset) catch return error.OutOfMemory;
    first_ui.ctx.scroll_seen.put(testing.allocator, box, saved_offset) catch return error.OutOfMemory;
    first_ui.ctx.scroll_follow.put(testing.allocator, box, false) catch return error.OutOfMemory;
    first_ui.frame();
    first_ui.settle(0.1);
    const saved = first.transcriptPosition("a") orelse return error.MissingCapturedPosition;
    try testing.expect(!saved.at_end);
    const anchor = saved.entry orelse return error.MissingAnchor;
    const anchor_number = try std.fmt.parseInt(usize, anchor[1..], 10);
    const anchor_text = try std.fmt.allocPrint(testing.allocator, "Synthetic reply {d}", .{anchor_number});
    defer testing.allocator.free(anchor_text);
    const first_text = findTextContaining(&first_ui, anchor_text) orelse return error.AnchorNotVisibleBeforeSave;
    const first_view = first_ui.ctx.rects.get(box) orelse return error.MissingViewportBeforeSave;
    const saved_text_offset = first_text.y - first_view.y;
    first.rememberTabs();
    const layout = first.settings.tabLayout() orelse return error.MissingLayout;

    var second: App = .init(testing.allocator, testing.io, 1);
    defer second.deinit();
    try chats(&second);
    second.settings.setTabLayout(layout);
    try testing.expect(persistence.restore(&second));
    var second_fixture: TranscriptFixture = .{ .a = &second };
    var second_ui: ui.Tester = undefined;
    try second_ui.init(testing.allocator, .init(&second_fixture, TranscriptFixture.draw), .{ .width = 670, .height = 410, .dark = true });
    defer second_ui.deinit();
    try testing.expect(second.transcriptPosition("a").?.pending);
    try loadHistory(&second.transcript, 48, false);
    second_ui.advance(0.25);
    const restored = second.transcriptPosition("a") orelse return error.MissingRestoredPosition;
    try testing.expect(!restored.pending);
    try testing.expect(restored.restored);
    const second_text = findTextContaining(&second_ui, anchor_text) orelse return error.AnchorNotVisibleAfterRestore;
    const second_view = second_ui.ctx.rects.get(box) orelse return error.MissingViewportAfterRestore;
    try testing.expectApproxEqAbs(saved_text_offset, second_text.y - second_view.y, 8);
}

test "legacy transcript layout defaults to bottom and waits for async history" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try chats(&a);
    a.settings.setTabLayout("{\"version\":1,\"active\":0,\"tabs\":[{\"chat\":\"a\"}]}");
    try testing.expect(persistence.restore(&a));
    var fixture: TranscriptFixture = .{ .a = &a };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&fixture, TranscriptFixture.draw), .{ .width = 900, .height = 700, .dark = true });
    defer t.deinit();
    try testing.expect(a.transcriptPosition("a").?.pending);
    try loadHistory(&a.transcript, 36, true);
    t.settle(0.5);
    const box = @import("app.zig").transcriptScrollBox("a");
    const max = t.ctx.scroll_max.get(box) orelse return error.MissingScrollRange;
    const offset = t.ctx.scroll.get(box) orelse return error.MissingScrollOffset;
    try testing.expect(!a.transcriptPosition("a").?.pending);
    try testing.expect(t.ctx.scroll_follow.get(box).?);
    try testing.expectApproxEqAbs(max, offset, 1);
}

test "a malformed or absent Nano layout falls back without replacing tabs" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try chats(&a);
    try testing.expect(!persistence.restore(&a));
    try testing.expectEqual(@as(usize, 1), a.tabs.items.items.len);
    a.settings.setTabLayout("{\"version\":1,\"tabs\":[]}");
    try testing.expect(!persistence.restore(&a));
    try testing.expectEqual(@as(usize, 1), a.tabs.items.items.len);
}
