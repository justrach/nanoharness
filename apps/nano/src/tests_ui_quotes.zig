//! "Add to chat": a selection in a reply quoted into the draft (#152).
//! Synthetic replies, the Tester's own clipboard, no windows.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

const action = "Add to chat";
const prompt = "How should I organize a reading list?";
const intro = "Here are two ways to organize your reading list.";
const option_a = "Option A: Group books by topic.";
const option_b = "Option B: Sort by how soon you plan to read each book.";
const reply = intro ++ "\\n\\n" ++ option_a ++ "\\n\\n" ++ option_b;
const draft = "How would this work for books without a date?";

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        try h.open(
            "{\"reset\":[{\"id\":\"u\",\"role\":\"user\",\"parts\":[{\"id\":\"p\",\"kind\":\"text\",\"text\":\"" ++ prompt ++ "\"}]}," ++
                "{\"id\":\"a\",\"role\":\"assistant\",\"status\":\"complete\",\"parts\":[{\"id\":\"p\",\"kind\":\"text\",\"text\":\"" ++ reply ++ "\"}]}]}",
            true,
        );
    }

    fn open(h: *Harness, frame: []const u8, offscreen: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = offscreen;
        h.a.dark = true;
        h.a.view.sidebar_open = false;
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"QueueCommand":{},"QueueMessage":{"id":"queued"},
            \\ "BeginQueuedMessageEdit":{"outcome":"acquired","leaseId":"lease","baseTextHash":"hash","text":"Synthetic queued message"},
            \\ "FinishQueuedMessageEdit":{"outcome":"committed"}}
        , .{});
        h.a.engine.state = .connected;
        h.a.device_id = try testing.allocator.dupe(u8, "fixture");
        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[ {"id":"reading","deviceId":"fixture","title":"Synthetic reading list","config":{"harness":"graff"}},
            \\  {"id":"garden","deviceId":"fixture","title":"Synthetic garden plan","config":{"harness":"graff"}} ]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("reading", null);
        try h.apply(frame);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 900, .height = 700, .dark = true });
        h.t.settle(1);
        // The scene answers sends only; what it leaves out is not the test's.
        h.a.clearNotice();
        h.t.settle(0.2);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn apply(h: *Harness, frame: []const u8) !void {
        var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer p.deinit();
        try h.a.transcript.apply(p.value);
    }

    fn pump(h: *Harness) void {
        for (0..20) |_| if (!h.a.engine.pump()) return;
    }

    fn snap(h: *Harness, name: []const u8) !void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
        try h.t.screenshot(path);
    }

    /// A text leaf of the transcript (not of the composer over it).
    fn node(h: *Harness, text: []const u8) ?u32 {
        for (h.t.ctx.nodes.items, 0..) |n, ix| {
            if (n.content != .text or !std.mem.eql(u8, n.content.text.str, text)) continue;
            if (h.inComposer(n.rect)) continue;
            return @intCast(ix);
        }
        return null;
    }

    fn inComposer(h: *Harness, r: ui.Rect) bool {
        const p = h.a.view.composer_anchor orelse return false;
        return r.x >= p.x and r.x + r.w <= p.x + p.w + 1 and r.y >= p.y and r.y + r.h <= p.y + p.h + 1;
    }

    /// A quote chip of the composer that shows `text`.
    fn chip(h: *Harness, text: []const u8) ?ui.Rect {
        for (h.t.ctx.nodes.items) |n| {
            if (n.content == .text and std.mem.eql(u8, n.content.text.str, text) and h.inComposer(n.rect)) return n.rect;
        }
        return null;
    }

    fn select(h: *Harness, text: []const u8, start: usize, end: usize) !void {
        const n = h.t.ctx.nodes.items[h.node(text) orelse return error.TextMissing];
        const st = n.content.text.style;
        const y = n.rect.y + h.t.ctx.text.lineHeight(st) / 2;
        h.t.drag(n.rect.x + h.t.ctx.text.width(text[0..start], st), y, n.rect.x + h.t.ctx.text.width(text[0..end], st), y);
        h.t.settle(0.2);
    }

    fn quote(h: *Harness, text: []const u8) !void {
        try h.select(text, 0, text.len);
        try h.t.clickText(action);
        h.t.settle(0.3);
    }

    fn clickChip(h: *Harness, text: []const u8) !void {
        const r = h.chip(text) orelse return error.ChipMissing;
        h.t.click(r.x + 4, r.y + r.h / 2);
        h.t.advance(1);
    }

    /// The remove button beside a chip.
    fn removeChip(h: *Harness, text: []const u8) !void {
        const r = h.chip(text) orelse return error.ChipMissing;
        for (h.t.ctx.a11y_items.items) |item| {
            if (!std.mem.eql(u8, item.label, "Remove quote")) continue;
            const b = h.t.ctx.rects.get(item.id) orelse continue;
            if (b.y > r.y + r.h or b.y + b.h < r.y) continue;
            h.t.click(b.x + b.w / 2, b.y + b.h / 2);
            h.t.settle(0.3);
            return;
        }
        return error.RemoveMissing;
    }

    fn scrollTo(h: *Harness, at: f32) !void {
        const box = h.a.view.jump_box;
        try h.t.ctx.scroll.put(testing.allocator, box, at);
        try h.t.ctx.scroll_follow.put(testing.allocator, box, false);
        h.t.advance(0.3);
    }

    fn offset(h: *Harness) f32 {
        return h.t.ctx.scroll.get(h.a.view.jump_box) orelse 0;
    }

    /// The passage is selected, its start in the transcript's viewport.
    fn expectHighlighted(h: *Harness, text: []const u8) !void {
        const view = h.t.ctx.rects.get(h.a.view.jump_box) orelse return error.TranscriptMissing;
        const start = h.t.ctx.selection.start_rect orelse return error.HighlightNotDrawn;
        try testing.expect(start.y >= view.y and start.y + start.h <= view.y + view.h);
        h.t.clipboard.clearRetainingCapacity();
        _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
        try testing.expectEqualStrings(text, h.t.clipboard.items);
    }

    fn expectUnsent(h: *Harness) !void {
        try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
        for (h.a.engine.sent.items) |frame| try testing.expect(std.mem.indexOf(u8, frame, "\"Queue") == null);
    }

    fn sentText(h: *Harness) ![]const u8 {
        if (h.a.pending_sends.items.len == 0) return error.NothingSent;
        return h.a.pending_sends.items[h.a.pending_sends.items.len - 1].part.text.items;
    }
};

test "quote selection Add to chat shows beside a selection inside one reply" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expect(!h.t.hasText(action));
    try h.select(option_b, 0, option_b.len);
    try h.snap("quote-selection");
    const r = h.t.findText(action) orelse return error.ActionMissing;
    const passage = h.t.ctx.nodes.items[h.node(option_b).?].rect;
    // Beside it: on neither side more than a line's distance from it.
    try testing.expect(r.y + r.h >= passage.y - 40 and r.y <= passage.y + passage.h + 40);
    try testing.expect(r.x >= passage.x - 8 and r.x + r.w <= passage.x + passage.w + 8);
    // Across paragraphs of the same reply too, dragged either way.
    const one = h.t.ctx.nodes.items[h.node(option_a).?].rect;
    const two = h.t.ctx.nodes.items[h.node(option_b).?].rect;
    h.t.drag(two.x + 120, two.y + two.h / 2, one.x + 20, one.y + one.h / 2);
    h.t.settle(0.2);
    try testing.expect(h.t.hasText(action));
    // A double click is a selection.
    h.t.doubleClick(one.x + 20, one.y + one.h / 2);
    h.t.settle(0.2);
    try testing.expect(h.t.hasText(action));
}

test "quote selection Add to chat moves with its passage and hides out of sight" {
    const frame = try history(20, "");
    defer testing.allocator.free(frame);
    var h: Harness = undefined;
    try h.open(frame, true);
    defer h.deinit();
    try h.scrollTo(600);
    const passage = "Synthetic answer 3 opens here.";
    const at = h.t.ctx.nodes.items[h.node(passage).?].rect;
    try h.scrollTo(h.offset() + at.y - 250);
    try h.select(passage, 0, passage.len);
    const view = h.t.ctx.rects.get(h.a.view.jump_box).?;
    var r = h.t.findText(action) orelse return error.ActionMissing;
    var p = h.t.ctx.nodes.items[h.node(passage).?].rect;
    const below = r.y - p.y;
    const was = p.y;
    // In the wheel's own frame, not one later.
    h.t.scroll(view.x + view.w / 2, view.y + view.h / 2, -60);
    r = h.t.findText(action) orelse return error.ActionMissing;
    p = h.t.ctx.nodes.items[h.node(passage).?].rect;
    try testing.expect(@abs(p.y - was) > 20);
    try testing.expectApproxEqAbs(below, r.y - p.y, 1);
    try h.scrollTo(h.offset() + 1500);
    try testing.expect(!h.t.hasText(action));
    // Out of sight it asks for no frames of its own.
    try testing.expect(!h.t.ctx.animating);
    try h.scrollTo(h.offset() - 1500);
    try testing.expect(h.t.hasText(action));
}

test "quote selection Add to chat stays away from prompts, mixed and empty selections" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // The check means something only where a reply's selection shows it.
    try h.select(option_a, 0, option_a.len);
    try testing.expect(h.t.hasText(action));
    try h.select(prompt, 4, 20);
    try testing.expect(h.t.ctx.selection.anchor != null);
    try testing.expect(!h.t.hasText(action));
    // From the prompt on into the reply.
    const from = h.t.ctx.nodes.items[h.node(prompt).?].rect;
    const to = h.t.ctx.nodes.items[h.node(option_a).?].rect;
    h.t.drag(from.x + 4, from.y + from.h / 2, to.x + 90, to.y + to.h / 2);
    h.t.settle(0.2);
    try testing.expect(h.t.ctx.selection.anchor != null);
    try testing.expect(!h.t.hasText(action));
    // A plain click selects nothing.
    h.t.click(to.x + 40, to.y + to.h / 2);
    h.t.settle(0.2);
    try testing.expect(!h.t.hasText(action));
    // Nor across two replies.
    try h.apply(
        \\{"upsert":[{"after":"a","entry":{"id":"b","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"A second synthetic reply."}]}}],"count":3}
    );
    h.t.settle(0.3);
    const next = h.t.ctx.nodes.items[h.node("A second synthetic reply.").?].rect;
    const last = h.t.ctx.nodes.items[h.node(option_b).?].rect;
    h.t.drag(last.x + 40, last.y + last.h / 2, next.x + 90, next.y + next.h / 2);
    h.t.settle(0.2);
    try testing.expect(h.t.ctx.selection.anchor != null);
    try testing.expect(!h.t.hasText(action));
}

test "quote selection Add to chat puts removable chips on the draft and sends nothing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.composer.set(draft);
    h.t.settle(0.2);
    try h.quote(option_b);
    try testing.expect(h.chip(option_b) != null);
    try testing.expect(!h.t.hasText(action));
    try testing.expectEqualStrings(draft, h.a.composer.text());
    try testing.expect(h.t.ctx.focus != 0 and h.t.ctx.focus == h.a.view.composer_id);
    try h.expectUnsent();
    // Part of a line, and a second quote beside the first.
    try h.select(option_a, 10, option_a.len);
    try h.t.clickText(action);
    h.t.settle(0.3);
    try testing.expect(h.chip(option_b) != null and h.chip(option_a[10..]) != null);
    try h.snap("quote-chips");
    // Typing goes on in the draft.
    h.t.typeText("!");
    h.t.settle(0.2);
    try testing.expect(std.mem.indexOfScalar(u8, h.a.composer.text(), '!') != null);
    try h.removeChip(option_b);
    try testing.expect(h.chip(option_b) == null and h.chip(option_a[10..]) != null);
    try testing.expect(h.t.ctx.focus == h.a.view.composer_id);
    try h.removeChip(option_a[10..]);
    try testing.expect(h.chip(option_a[10..]) == null);
    try h.expectUnsent();
}

fn history(n: usize, extra: []const u8) ![]u8 {
    var json: std.ArrayList(u8) = .empty;
    errdefer json.deinit(testing.allocator);
    try json.appendSlice(testing.allocator, "{\"reset\":[");
    for (0..n) |i| try json.print(testing.allocator,
        \\{{"id":"u{d}","role":"user","parts":[{{"id":"p","kind":"text","text":"Synthetic prompt {d}"}}]}},
        \\{{"id":"a{d}","role":"assistant","status":"complete","parts":[{{"id":"p","kind":"text","text":"Synthetic answer {d} opens here.\n\nThe repeated closing line.\n\nMore synthetic prose that gives the row some height.\n\nThe repeated closing line.\n\nAnd a last synthetic paragraph."}}]}},
    , .{ i, i, i, i });
    try json.appendSlice(testing.allocator, extra);
    try json.appendSlice(testing.allocator, "{\"id\":\"end\",\"role\":\"user\",\"parts\":[{\"id\":\"p\",\"kind\":\"text\",\"text\":\"Synthetic end\"}]}]}");
    return json.toOwnedSlice(testing.allocator);
}

test "quote selection chip scrolls back to an off-screen culled passage and highlights it" {
    // A live window culls the rows out of sight; a fixture draws them all.
    for ([_]bool{ true, false }) |offscreen| {
        const frame = try history(60, "");
        defer testing.allocator.free(frame);
        var h: Harness = undefined;
        try h.open(frame, offscreen);
        defer h.deinit();
        const passage = "Synthetic answer 3 opens here.";
        try h.scrollTo(0);
        // Row by row, as a reader does, so each is measured.
        while (h.node(passage) == null) try h.scrollTo(h.offset() + 300);
        const at = h.t.ctx.nodes.items[h.node(passage).?].rect;
        try h.scrollTo(h.offset() + at.y - 250);
        h.a.composer.set(draft);
        try h.quote(passage);
        // Far below, and far above, what it was taken from.
        for ([_]f32{ std.math.floatMax(f32), 0 }) |away| {
            try h.scrollTo(if (away == 0) 0 else h.t.ctx.scroll_max.get(h.a.view.jump_box).?);
            if (!offscreen and away != 0) try testing.expect(h.node(passage) == null);
            const before = h.offset();
            try h.clickChip(passage);
            try testing.expect(@abs(h.offset() - before) > 100);
            try h.expectHighlighted(passage);
            if (!offscreen and away != 0) try h.snap("quote-revealed");
            // It is a highlight: not something to add again.
            try testing.expect(!h.t.hasText(action));
            try testing.expectEqualStrings(draft, h.a.composer.text());
            try testing.expect(h.chip(passage) != null);
            try h.expectUnsent();
            try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
            // It settles there, and lets the reader scroll on.
            const settled = h.offset();
            h.t.advance(1);
            try testing.expectApproxEqAbs(settled, h.offset(), 0.5);
            const view = h.t.ctx.rects.get(h.a.view.jump_box).?;
            h.t.scroll(view.x + view.w / 2, view.y + view.h / 2, -200);
            h.t.advance(0.5);
            try testing.expect(@abs(h.offset() - settled) > 50);
        }
    }
}

test "quote selection chip highlights the occurrence it was taken from" {
    var h: Harness = undefined;
    const frame = try history(1, "");
    defer testing.allocator.free(frame);
    try h.open(frame, true);
    defer h.deinit();
    var rects: [2]ui.Rect = undefined;
    var n: usize = 0;
    for (h.t.ctx.nodes.items) |nd| if (nd.content == .text and std.mem.eql(u8, nd.content.text.str, "The repeated closing line.")) {
        rects[n] = nd.rect;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 2), n);
    h.t.drag(rects[1].x, rects[1].y + 10, rects[1].x + rects[1].w, rects[1].y + 10);
    h.t.settle(0.2);
    try h.t.clickText(action);
    h.t.settle(0.3);
    try h.clickChip("The repeated closing line.");
    try h.expectHighlighted("The repeated closing line.");
    // The second of the two, wherever the taller composer moved them.
    var seen: usize = 0;
    for (h.t.ctx.nodes.items) |nd| if (nd.content == .text and std.mem.eql(u8, nd.content.text.str, "The repeated closing line.") and !h.inComposer(nd.rect)) {
        if (seen == 1) try testing.expectApproxEqAbs(nd.rect.y, h.t.ctx.selection.start_rect.?.y, 4);
        seen += 1;
    };
    try testing.expectEqual(@as(usize, 2), seen);
}

test "quote selection chip finds a passage deep inside one long paragraph" {
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    for (0..120) |i| try long.print(testing.allocator, "Synthetic sentence {d:0>3} runs on inside the same paragraph. ", .{i});
    const text = std.mem.trim(u8, long.items, " ");
    const frame = try std.json.Stringify.valueAlloc(testing.allocator, .{ .reset = &.{.{ .id = "a", .role = "assistant", .status = "complete", .parts = &.{.{ .id = "p", .kind = "text", .text = text }} }} }, .{});
    defer testing.allocator.free(frame);
    var h: Harness = undefined;
    try h.open(frame, true);
    defer h.deinit();
    try h.scrollTo(0);
    const n = h.t.ctx.nodes.items[h.node(text) orelse return error.TextMissing];
    const line = n.content.text.lines[60];
    const lh = h.t.ctx.text.lineHeight(n.content.text.style);
    try h.scrollTo(lh * 55);
    const r = h.t.ctx.nodes.items[h.node(text).?].rect;
    const y = r.y + lh * 60.5;
    h.t.drag(r.x, y, r.x + h.t.ctx.text.width(text[line.start..line.end], n.content.text.style) - 2, y);
    h.t.settle(0.2);
    const passage = std.mem.trim(u8, text[line.start..line.end], " ");
    try h.t.clickText(action);
    h.t.settle(0.3);
    try h.scrollTo(0);
    try h.clickChip(passage);
    try h.expectHighlighted(passage);
}

test "quote selection chip opens a folded turn and follows its reply under a new turn" {
    var h: Harness = undefined;
    const passage = "Synthetic narration between two steps.";
    const streaming =
        \\{"reset":[{"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic work"}]},
        \\ {"id":"a","role":"assistant","status":"streaming","parts":[
        \\  {"id":"n","kind":"text","text":"Synthetic narration between two steps."},
        \\  {"id":"t","kind":"tool","resolved":true,"call":{"kind":"exec","command":"zig build test"}},
        \\  {"id":"f","kind":"text","text":"Synthetic final answer."}]}]}
    ;
    try h.open(streaming, true);
    defer h.deinit();
    h.a.settings.set(.transcript_compact_mode, true);
    h.t.settle(1);
    try h.quote(passage);
    // The turn finishes and folds its work; then another turn starts.
    try h.apply(
        \\{"reset":[{"id":"u","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic work"}]},
        \\ {"id":"a","role":"assistant","status":"complete","parts":[
        \\  {"id":"n","kind":"text","text":"Synthetic narration between two steps."},
        \\  {"id":"t","kind":"tool","resolved":true,"call":{"kind":"exec","command":"zig build test"}},
        \\  {"id":"f","kind":"text","text":"Synthetic final answer."}]},
        \\ {"id":"u2","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic next prompt"}]},
        \\ {"id":"a2","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Synthetic next answer."}]}]}
    );
    h.t.advance(1);
    try testing.expect(h.node(passage) == null);
    try h.clickChip(passage);
    try h.expectHighlighted(passage);
}

test "quote selection sends each quote as a blockquote ahead of the typed text" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.quote(option_b);
    const one = h.t.ctx.nodes.items[h.node(intro).?].rect;
    const two = h.t.ctx.nodes.items[h.node(option_a).?].rect;
    h.t.drag(one.x, one.y + one.h / 2, two.x + two.w, two.y + two.h / 2);
    h.t.settle(0.2);
    try h.t.clickText(action);
    h.t.settle(0.3);
    h.t.typeText(draft);
    h.t.settle(0.2);
    h.t.key(.enter);
    h.t.settle(0.2);
    try testing.expectEqualStrings("> " ++ option_b ++ "\n\n> " ++ intro ++ "\n> " ++ option_a ++ "\n\n" ++ draft, try h.sentText());
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expect(h.chip(option_b) == null);
    // Gone for the next message too.
    h.a.composer.set("Plain follow-up");
    h.a.send();
    try testing.expectEqualStrings("Plain follow-up", try h.sentText());
}

test "quote selection whose reply is gone still sends its text and its click does nothing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.composer.set(draft);
    try h.quote(option_b);
    try h.apply(
        \\{"reset":[{"id":"other","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"A replacement synthetic reply."}]}]}
    );
    h.t.settle(0.5);
    const before = h.offset();
    try h.clickChip(option_b);
    try testing.expectEqual(before, h.offset());
    try testing.expect(h.t.ctx.selection.anchor == null);
    try testing.expectEqualStrings(draft, h.a.composer.text());
    try h.expectUnsent();
    try testing.expect(h.chip(option_b) != null);
    h.a.send();
    try testing.expectEqualStrings("> " ++ option_b ++ "\n\n" ++ draft, try h.sentText());
}

test "quote selection follows its chat's draft through chats, tabs and panes" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.composer.set(draft);
    try h.quote(option_b);
    // Another chat in the same place.
    h.a.select("garden", null);
    h.t.settle(0.3);
    try testing.expect(h.chip(option_b) == null);
    h.a.composer.set("Garden draft");
    h.a.select("reading", null);
    h.t.settle(0.3);
    try testing.expect(h.chip(option_b) != null);
    try testing.expectEqualStrings(draft, h.a.composer.text());
    // Another tab: what it sends has no quote of this one's.
    h.a.openChatInTab("garden");
    h.t.settle(0.3);
    try testing.expect(h.chip(option_b) == null);
    h.a.send();
    try testing.expectEqualStrings("Garden draft", try h.sentText());
    h.a.openChatInTab("reading");
    h.t.settle(0.3);
    try testing.expect(h.chip(option_b) != null);
    // A split, with the new pane's draft shown and then this one's again.
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    try testing.expect(h.chip(option_b) == null);
    h.a.focusPane(0);
    h.t.settle(1);
    try testing.expect(h.chip(option_b) != null);
    try testing.expectEqualStrings(draft, h.a.composer.text());
}

test "quote selection leaves Copy, typing and the plain composer as they were" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const compact = h.a.view.composer_anchor.?;
    try h.select(option_b, 0, 8);
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(option_b[0..8], h.t.clipboard.items);
    try testing.expect(h.t.ctx.selection.anchor != null);
    // A press elsewhere in the text still clears it.
    const r = h.t.ctx.nodes.items[h.node(intro).?].rect;
    h.t.click(r.x + 30, r.y + r.h / 2);
    h.t.settle(0.2);
    h.t.clipboard.clearRetainingCapacity();
    _ = h.t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings("", h.t.clipboard.items);
    try testing.expect(!h.t.hasText(action));
    try testing.expectEqual(compact.h, h.a.view.composer_anchor.?.h);
    h.a.composer.set(draft);
    h.a.send();
    try testing.expectEqualStrings(draft, try h.sentText());
}

test "quote selection keeps slash commands at the message's start" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.quote(option_b);
    // The workspace's own command is not a message: the quote stays.
    h.a.composer.set("/zen");
    h.a.send();
    h.t.settle(0.3);
    try h.expectUnsent();
    try testing.expect(h.chip(option_b) != null);
    h.a.composer.set("/compact");
    h.a.send();
    try testing.expectEqualStrings("/compact\n\n> " ++ option_b, try h.sentText());
}

test "quote selection alone is a message" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.quote(option_b);
    h.t.key(.enter);
    h.t.settle(0.2);
    try testing.expectEqualStrings("> " ++ option_b, try h.sentText());
    try testing.expect(h.chip(option_b) == null);
}

test "quote selection works in a neighboring pane once it has focus" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.t.settle(1);
    h.a.select("garden", null);
    h.t.settle(0.5);
    // The reading chat is the peer now; its selection focuses its pane.
    try h.select(option_a, 0, 9);
    try testing.expectEqualStrings("reading", h.a.selected.?);
    try h.t.clickText(action);
    h.t.settle(0.3);
    h.a.send();
    try testing.expectEqualStrings("> " ++ option_a[0..9], try h.sentText());
    try testing.expectEqualStrings("reading", h.a.pending_sends.items[0].chat);
}

test "quote selection goes with a queued follow-up" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[{\"chatId\":\"reading\",\"status\":\"working\",\"updatedAt\":1000}]", .{});
    defer sessions.deinit();
    try h.a.sessions.replace(sessions.value);
    h.a.caps.queue = true;
    h.t.settle(0.3);
    try h.quote(option_b);
    h.a.composer.set(draft);
    h.a.sendFollowUp(.queue);
    h.t.settle(0.3);
    const frame = h.a.engine.sent.items[h.a.engine.sent.items.len - 1];
    var sent = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
    defer sent.deinit();
    try testing.expectEqualStrings("QueueMessage", sent.value.object.get("method").?.string);
    try testing.expectEqualStrings("> " ++ option_b ++ "\n\n" ++ draft, sent.value.object.get("params").?.object.get("text").?.string);
    try testing.expect(h.chip(option_b) == null);
}

test "quote selection waits while a queued message being edited has the composer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.composer.set(draft);
    try h.quote(option_b);
    h.a.caps.edit_lease = true;
    const queue = @import("app_queue.zig");
    queue.beginEdit(&h.a, "row");
    h.pump();
    h.t.settle(0.3);
    try testing.expectEqualStrings("Synthetic queued message", h.a.composer.text());
    try testing.expect(h.chip(option_b) == null);
    // Nor is there a draft to quote into.
    try h.select(option_a, 0, option_a.len);
    try testing.expect(h.t.ctx.selection.anchor != null);
    try testing.expect(!h.t.hasText(action));
    // What it saves has no quote of the draft's.
    queue.finishEdit(&h.a, .commit);
    const frame = h.a.engine.sent.items[h.a.engine.sent.items.len - 1];
    var sent = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
    defer sent.deinit();
    try testing.expectEqualStrings("Synthetic queued message", sent.value.object.get("params").?.object.get("text").?.string);
    h.pump();
    h.t.settle(0.3);
    try testing.expectEqualStrings(draft, h.a.composer.text());
    try testing.expect(h.chip(option_b) != null);
    h.a.send();
    try testing.expectEqualStrings("> " ++ option_b ++ "\n\n" ++ draft, try h.sentText());
}

test "quote selection offers a passage again once it is selected anew" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.quote(option_b);
    try h.clickChip(option_b);
    try h.expectHighlighted(option_b);
    try testing.expect(!h.t.hasText(action));
    try h.select(option_b, 0, option_b.len);
    try testing.expect(h.t.hasText(action));
    // Once is enough: it is the same passage.
    try h.t.clickText(action);
    h.t.settle(0.3);
    try testing.expectEqual(@as(usize, 1), @import("app_quotes.zig").count(&h.a));
}

test "quote selection shows its chips on the Write page, whose click goes back to the chat" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.composer.set(draft);
    try h.quote(option_b);
    @import("view_write.zig").open(&h.a);
    h.t.settle(0.5);
    const r = h.t.findText(option_b) orelse return error.ChipMissing;
    h.t.click(r.x + 4, r.y + r.h / 2);
    h.t.advance(1);
    try testing.expect(!h.a.view.write_open);
    try h.expectHighlighted(option_b);
    try testing.expectEqualStrings(draft, h.a.composer.text());
}

test "quote selection keeps a command picked from the completion menu at the message's start" {
    const completion = @import("composer_completion.zig");
    const cases = [_]struct { name: []const u8, path: ?[]const u8, text: []const u8, at: usize, first: bool }{
        .{ .name = "goal", .path = null, .text = "/goal write tests", .at = 0, .first = true },
        // A provider runs a skill as its command only from the start, too.
        .{ .name = "review", .path = "/synthetic/skills/review.md", .text = "$review this", .at = 0, .first = true },
        .{ .name = "review", .path = "/synthetic/skills/review.md", .text = "Compare $review", .at = 8, .first = false },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.quote(option_b);
        h.a.composer.set(case.text);
        completion.restore(&h.a, null);
        const stop = case.at + 1 + case.name.len;
        const link = try completion.canonical(testing.allocator, .{ .name = case.name, .description = "", .path = case.path });
        try h.a.completion.selected.append(testing.allocator, .{
            .start = case.at,
            .end = stop,
            .display = try testing.allocator.dupe(u8, case.text[case.at..stop]),
            .link = link,
        });
        const typed = try std.mem.concat(testing.allocator, u8, &.{ case.text[0..case.at], link, case.text[stop..] });
        defer testing.allocator.free(typed);
        const parts: [2][]const u8 = if (case.first) .{ typed, "> " ++ option_b } else .{ "> " ++ option_b, typed };
        const expected = try std.mem.join(testing.allocator, "\n\n", &parts);
        defer testing.allocator.free(expected);
        h.a.send();
        try testing.expectEqualStrings(expected, try h.sentText());
    }
}

const slid_passage = "Synthetic passage beside the slide.";

/// Replies of wrapping prose, the passage in the middle of them: in a reply
/// of its own, or (`steer`) in what a reply gained after a message sent
/// while it worked. `started` is that reply as the message arrived: taller
/// than the window, so that going to its start doesn't show what follows.
fn slideHistory(steer: bool, started: bool) ![]u8 {
    const sentence = "Made-up prose that fills a few lines of the column, so that its height depends on how wide the column is, and that a slide of the sidebar has to lay out again once it is over. ";
    const prose = sentence ++ sentence ++ sentence;
    var json: std.ArrayList(u8) = .empty;
    errdefer json.deinit(testing.allocator);
    try json.appendSlice(testing.allocator, "{\"reset\":[");
    for (0..50) |i| {
        if (i == 25) {
            try json.appendSlice(testing.allocator, "{\"id\":\"su\",\"role\":\"user\",\"parts\":[{\"id\":\"p\",\"kind\":\"text\",\"text\":\"Synthetic work\"}]},");
            try json.print(testing.allocator, "{{\"id\":\"sa\",\"role\":\"assistant\",\"status\":\"{s}\",\"parts\":[{{\"id\":\"n\",\"kind\":\"text\",\"text\":\"Synthetic narration.", .{if (started) "streaming" else "complete"});
            for (0..16) |_| try json.print(testing.allocator, "\\n\\n{s}", .{prose});
            try json.appendSlice(testing.allocator, "\"}");
            if (!started) try json.print(testing.allocator, ",{{\"id\":\"q\",\"kind\":\"text\",\"text\":\"{s}\\n\\n{s}\"}}", .{ slid_passage, prose });
            try json.appendSlice(testing.allocator, "]},");
            if (steer) try json.appendSlice(testing.allocator, "{\"id\":\"steer\",\"role\":\"user\",\"parts\":[{\"id\":\"p\",\"kind\":\"text\",\"text\":\"Synthetic steer\"}]},");
            if (started) break;
        }
        try json.print(testing.allocator,
            \\{{"id":"u{d}","role":"user","parts":[{{"id":"p","kind":"text","text":"Synthetic prompt {d}"}}]}},
            \\{{"id":"a{d}","role":"assistant","status":"complete","parts":[{{"id":"p","kind":"text","text":"Synthetic answer {d}. {s}"}}]}},
        , .{ i, i, i, i, prose });
    }
    _ = json.pop();
    try json.appendSlice(testing.allocator, "]}");
    return json.toOwnedSlice(testing.allocator);
}

test "quote selection chip goes to the real row while a slide's rows are measured out of sight" {
    for ([_]bool{ false, true }) |steer| {
        var h: Harness = undefined;
        {
            const frame = try slideHistory(steer, steer);
            defer testing.allocator.free(frame);
            try h.open(frame, true);
        }
        defer h.deinit();
        if (steer) {
            const frame = try slideHistory(true, false);
            defer testing.allocator.free(frame);
            try h.apply(frame);
            h.t.settle(0.5);
        }
        // Every row is drawn once, and has a height to stand in for it.
        h.a.composer.set(draft);
        const at = h.t.ctx.nodes.items[h.node(slid_passage) orelse return error.TextMissing].rect;
        if (steer) try testing.expect(h.t.findText("Synthetic steer").?.y < at.y);
        try h.scrollTo(h.offset() + at.y - 250);
        try h.quote(slid_passage);
        h.a.offscreen = false;
        try h.scrollTo(h.t.ctx.scroll_max.get(h.a.view.jump_box).?);
        try testing.expect(h.node(slid_passage) == null);
        _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
        try testing.expect(h.a.view.sidebar_tween != null);
        while (h.a.view.sidebar_tween != null) h.t.frame();
        // The chip is pressed, and let go of in a frame that has the passage
        // only as a row drawn for its height.
        const chip = h.chip(slid_passage) orelse return error.ChipMissing;
        h.t.down(chip.x + 4, chip.y + chip.h / 2);
        var frames: usize = 0;
        while (h.node(slid_passage) == null) : (frames += 1) {
            if (frames > 600) return error.NeverMeasured;
            h.t.frame();
        }
        try testing.expect(h.t.ctx.nodes.items[h.node(slid_passage).?].rect.y < -5e5);
        const before = h.offset();
        h.t.up();
        frames = 0;
        var shown: usize = 0;
        while (h.t.ctx.animating) : (frames += 1) {
            if (frames > 2000) return error.NeverRested;
            h.t.frame();
            const anchor = h.t.ctx.selection.anchor orelse continue;
            shown += 1;
            for (h.t.ctx.nodes.items) |n| {
                if (n.id == anchor.id) try testing.expect(n.rect.y > -5e5);
                // Wanted for real, it is not measured aside too.
                if (n.content == .text and n.rect.y < -5e5) try testing.expect(!std.mem.eql(u8, n.content.text.str, slid_passage));
            }
        }
        try testing.expect(shown > 0);
        try testing.expect(@abs(h.offset() - before) > 500);
        // Where the slide's measuring ends, the passage is still in view.
        try h.expectHighlighted(slid_passage);
        const real = h.t.ctx.nodes.items[h.node(slid_passage).?];
        try testing.expectEqual(real.id, h.t.ctx.selection.anchor.?.id);
        const view = h.t.ctx.rects.get(h.a.view.jump_box).?;
        try testing.expect(real.rect.y >= view.y and real.rect.y + real.rect.h <= view.y + view.h);
        try testing.expectEqualStrings(draft, h.a.composer.text());
        try h.expectUnsent();
    }
}
