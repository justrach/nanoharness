//! Passages of a reply quoted into the draft under it (#152): what "Add to
//! chat" keeps, the way back to where each was taken from, and the text a
//! send carries. A draft's quotes are its chat's, as its attachments are,
//! and last as long as the window does.
const std = @import("std");
const App = @import("app.zig").App;
const requests = @import("requests.zig");
const Allocator = std.mem.Allocator;

/// Where a passage was read: the reply, the part of it the passage starts
/// in, and which of that part's equal passages it is. Not a place in the
/// layout, so it holds while the reply grows, folds or is laid out anew.
pub const Source = struct {
    entry: []const u8,
    part: []const u8,
    nth: usize = 0,
};

pub const Item = struct {
    id: u64,
    /// The chat whose draft it is on.
    owner: []u8,
    text: []u8,
    entry: []u8,
    part: []u8,
    nth: usize,
    removed: bool = false,

    fn destroy(item: *Item, gpa: Allocator) void {
        gpa.free(item.owner);
        gpa.free(item.text);
        gpa.free(item.entry);
        gpa.free(item.part);
        gpa.destroy(item);
    }

    pub fn active(item: *const Item, a: *const App) bool {
        const chat = owner(a) orelse return false;
        return !item.removed and std.mem.eql(u8, item.owner, chat);
    }

    pub fn remove(item: *Item, a: *App) void {
        item.removed = true;
        a.view.focus_composer = true;
        a.redraw();
    }
};

/// A chip's passage being brought into view (view_quotes.zig).
pub const Reveal = struct {
    item: u64 = 0,
    chat: []u8,
    entry: []u8,
    part: []u8,
    text: []u8,
    nth: usize,
    focus_composer: bool,
    started: f64,
    /// The folded work holding the passage was opened for it.
    opened: bool = false,
    /// The passage is highlighted.
    shown: bool = false,
    /// The passage was out of sight: the transcript moves to it.
    moves: bool = false,
    /// The frame that moved it last: another's move is the reader's.
    frame: u64 = 0,

    pub fn destroy(r: Reveal, gpa: Allocator) void {
        gpa.free(r.chat);
        gpa.free(r.entry);
        gpa.free(r.part);
        gpa.free(r.text);
    }
};

pub const State = struct {
    items: std.ArrayList(*Item) = .empty,
    next_id: u64 = 1,
    reveal: ?Reveal = null,
    /// The texts a reveal's highlight starts and ends in, and where in
    /// them: shown, not selected to quote again.
    shown: ?[2]u64 = null,
    shown_at: [2]usize = .{ 0, 0 },

    pub fn deinit(s: *State, gpa: Allocator) void {
        for (s.items.items) |item| item.destroy(gpa);
        s.items.deinit(gpa);
        if (s.reveal) |r| r.destroy(gpa);
        s.* = .{};
    }

    pub fn find(s: *const State, id: u64) ?*Item {
        for (s.items.items) |item| if (item.id == id and !item.removed) return item;
        return null;
    }
};

/// The chat whose draft the composer holds. None while a question or a
/// queued message being edited borrows it: the draft is set aside then,
/// and its quotes with it.
pub fn owner(a: *const App) ?[]const u8 {
    if (a.wizard != null or a.queue_edit != null) return null;
    return a.selected;
}

pub fn count(a: *const App) usize {
    var n: usize = 0;
    for (a.quotes.items.items) |item| if (item.active(a)) {
        n += 1;
    };
    return n;
}

/// Adds a passage to the draft. The same passage twice is one quote.
pub fn add(a: *App, text: []const u8, source: Source) !void {
    const chat = owner(a) orelse return;
    const body = std.mem.trim(u8, text, " \t\r\n");
    if (body.len == 0) return;
    for (a.quotes.items.items) |item| {
        if (item.active(a) and item.nth == source.nth and std.mem.eql(u8, item.text, body) and
            std.mem.eql(u8, item.entry, source.entry) and std.mem.eql(u8, item.part, source.part)) return;
    }
    const gpa = a.gpa;
    const item = try gpa.create(Item);
    errdefer gpa.destroy(item);
    const key = try gpa.dupe(u8, chat);
    errdefer gpa.free(key);
    const own = try gpa.dupe(u8, body);
    errdefer gpa.free(own);
    const entry = try gpa.dupe(u8, source.entry);
    errdefer gpa.free(entry);
    const part = try gpa.dupe(u8, source.part);
    errdefer gpa.free(part);
    item.* = .{ .id = a.quotes.next_id, .owner = key, .text = own, .entry = entry, .part = part, .nth = source.nth };
    try a.quotes.items.append(gpa, item);
    a.quotes.next_id += 1;
}

pub fn beginReveal(a: *App, chat: []const u8, source: Source, text: []const u8, focus_composer: bool, started: f64, item_id: u64) !void {
    if (a.quotes.reveal) |r| r.destroy(a.gpa);
    a.quotes.reveal = .{
        .item = item_id,
        .chat = try a.gpa.dupe(u8, chat),
        .entry = try a.gpa.dupe(u8, source.entry),
        .part = try a.gpa.dupe(u8, source.part),
        .text = try a.gpa.dupe(u8, text),
        .nth = source.nth,
        .focus_composer = focus_composer,
        .started = started,
    };
}

pub fn clear(a: *App) void {
    for (a.quotes.items.items) |item| if (item.active(a)) {
        item.removed = true;
    };
}

/// At a frame's start: the last frame's chips borrowed what was removed.
pub fn reap(a: *App) void {
    var i: usize = 0;
    while (i < a.quotes.items.items.len) {
        const item = a.quotes.items.items[i];
        if (item.removed) {
            _ = a.quotes.items.orderedRemove(i);
            item.destroy(a.gpa);
        } else i += 1;
    }
}

pub const PromptResult = struct {
    text: []u8,
    quotes: []requests.PromptQuote,

    pub fn deinit(result: PromptResult, gpa: Allocator) void {
        gpa.free(result.text);
        gpa.free(result.quotes);
    }
};

/// The draft's quotes as Markdown blockquotes ahead of `text`; null when it
/// has none. The references point to exact quote blocks in the resulting prompt.
pub fn promptWithQuotes(a: *App, text: []const u8) !?PromptResult {
    if (count(a) == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a.gpa);
    var refs: std.ArrayList(requests.PromptQuote) = .empty;
    errdefer refs.deinit(a.gpa);
    const command = isCommand(text);
    if (command) try out.appendSlice(a.gpa, text);
    for (a.quotes.items.items) |item| if (item.active(a)) {
        if (out.items.len > 0) try out.appendSlice(a.gpa, "\n\n");
        const start = out.items.len;
        try blockquote(a.gpa, &out, item.text);
        try refs.append(a.gpa, .{ .entry = item.entry, .part = item.part, .nth = item.nth, .text = item.text, .start = start, .end = out.items.len });
    };
    if (!command and text.len > 0) {
        try out.appendSlice(a.gpa, "\n\n");
        try out.appendSlice(a.gpa, text);
    }
    return .{ .text = try out.toOwnedSlice(a.gpa), .quotes = try refs.toOwnedSlice(a.gpa) };
}

pub fn prompt(a: *App, text: []const u8) !?[]u8 {
    const result = (try promptWithQuotes(a, text)) orelse return null;
    a.gpa.free(result.quotes);
    return result.text;
}

/// Remove only verified quote blocks, preserving the rest of the stored prompt.
pub fn displayText(gpa: Allocator, prompt_text: []const u8, refs: []const requests.PromptQuote) !?[]u8 {
    if (refs.len == 0) return try gpa.dupe(u8, prompt_text);
    var previous_end: usize = 0;
    for (refs, 0..) |ref, i| {
        if (ref.start > ref.end or ref.end > prompt_text.len or ref.start < previous_end or ref.entry.len == 0 or ref.part.len == 0 or ref.text.len == 0) return null;
        if (!std.unicode.utf8ValidateSlice(prompt_text[ref.start..ref.end])) return null;
        if (i > 0 and !std.mem.eql(u8, prompt_text[previous_end..ref.start], "\n\n")) return null;
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(gpa);
        try blockquote(gpa, &expected, ref.text);
        if (!std.mem.eql(u8, prompt_text[ref.start..ref.end], expected.items)) return null;
        previous_end = ref.end;
    }
    var start = refs[0].start;
    var end = refs[refs.len - 1].end;
    if (start >= 2 and std.mem.eql(u8, prompt_text[start - 2 .. start], "\n\n")) start -= 2;
    if (end + 2 <= prompt_text.len and std.mem.eql(u8, prompt_text[end .. end + 2], "\n\n")) end += 2;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, prompt_text[0..start]);
    try out.appendSlice(gpa, prompt_text[end..]);
    return try out.toOwnedSlice(gpa);
}

fn blockquote(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.append(gpa, '>');
        if (line.len > 0) {
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, line);
        }
    }
}

/// Whether `text` starts with a slash command (`/compact`,
/// `/plugin:review fix`), not with a path (`/usr/share`); or with a command
/// or skill picked from the completion menu, which is sent as its link.
pub fn isCommand(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "[/") or std.mem.startsWith(u8, text, "[$")) {
        const label = std.mem.indexOf(u8, text, "](") orelse return false;
        return std.mem.startsWith(u8, text[label + 2 ..], "harness-invoke:");
    }
    if (text.len < 2 or text[0] != '/' or !std.ascii.isAlphabetic(text[1])) return false;
    for (text[1..]) |ch| switch (ch) {
        ' ', '\t', '\r', '\n' => return true,
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ':', '.' => {},
        else => return false,
    };
    return true;
}

const testing = std.testing;

test "quote selection tells a slash command from a path" {
    for ([_][]const u8{ "/compact", "/review the last change", "/plugin:run", "/fix_it\nnow", "[/goal](harness-invoke:00) now", "[$a](harness-invoke:00)" }) |s| try testing.expect(isCommand(s));
    for ([_][]const u8{ "", "/", "/ no", "/usr/share is full", "plain", "//comment", "/50%", "see /compact", "[/tmp](https://example.test)", "[a](harness-invoke:00)", "[/x" }) |s| try testing.expect(!isCommand(s));
}

test "quote selection blockquotes every line, blank ones included" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try blockquote(testing.allocator, &out, "one\r\n\n  three ");
    try testing.expectEqualStrings("> one\n>\n>   three", out.items);
}

test "quote selection keeps one copy of a passage and frees removed ones" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    // No chat, no draft to quote into.
    try add(&a, "lost", .{ .entry = "e", .part = "p" });
    try testing.expectEqual(@as(usize, 0), count(&a));
    a.select("a", null);
    try add(&a, "  kept ", .{ .entry = "e", .part = "p" });
    try add(&a, "kept", .{ .entry = "e", .part = "p" });
    try add(&a, " \n ", .{ .entry = "e", .part = "p" });
    try testing.expectEqual(@as(usize, 1), count(&a));
    try add(&a, "kept", .{ .entry = "e", .part = "p", .nth = 1 });
    try testing.expectEqual(@as(usize, 2), count(&a));
    const text = (try prompt(&a, "why?")).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("> kept\n\n> kept\n\nwhy?", text);
    clear(&a);
    reap(&a);
    try testing.expectEqual(@as(usize, 0), a.quotes.items.items.len);
    try testing.expect((try prompt(&a, "why?")) == null);
}
