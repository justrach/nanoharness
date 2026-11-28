//! Passages of a reply quoted into the draft under it (#152): what "Add to
//! chat" keeps, the way back to where each was taken from, and the text a
//! send carries. A draft's quotes are its chat's, as its attachments are,
//! and last as long as the window does.
const std = @import("std");
const App = @import("app.zig").App;
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
    item: u64,
    started: f64,
    /// The folded work holding the passage was opened for it.
    opened: bool = false,
    /// The passage is highlighted.
    shown: bool = false,
    /// The passage was out of sight: the transcript moves to it.
    moves: bool = false,
    /// The frame that moved it last: another's move is the reader's.
    frame: u64 = 0,
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

/// The draft's quotes as Markdown blockquotes ahead of `text`; null when it
/// has none. A slash command keeps the message's start, where the agents
/// look for it, with the quotes under it.
pub fn prompt(a: *App, text: []const u8) !?[]u8 {
    if (count(a) == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a.gpa);
    const command = isCommand(text);
    if (command) try out.appendSlice(a.gpa, text);
    for (a.quotes.items.items) |item| if (item.active(a)) {
        if (out.items.len > 0) try out.appendSlice(a.gpa, "\n\n");
        try blockquote(a.gpa, &out, item.text);
    };
    if (!command and text.len > 0) {
        try out.appendSlice(a.gpa, "\n\n");
        try out.appendSlice(a.gpa, text);
    }
    return try out.toOwnedSlice(a.gpa);
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
