//! What the GitHub and source-control panes say and which colour role they
//! say it in, as plain functions: a pull request's or issue's state, the
//! loaded page's one-line summary, relative dates, paths cut in the middle,
//! which labels a row has room for, and how an activity event or a file's
//! status letter reads. The views only map a `Role` to the theme's colour.
const std = @import("std");
const rules = @import("rules.zig");

/// A pull request or an issue.
pub const Kind = enum { pull, issue };

/// The four states a reader tells apart.
pub const State = enum { open, draft, merged, closed };

/// The semantic theme role a state is drawn in (`theme.Colors` fields):
/// open `success`, merged `accent`, a closed pull request `danger`, and a
/// draft or a closed issue `muted`. One mapping for the repository list,
/// the detail header, the charts, the session pull requests and the
/// composer footer's badge.
pub const Role = enum { success, accent, danger, muted };

/// The provider's state words ("open", "closed", "merged") and the draft flag.
pub fn stateOf(state: []const u8, draft: bool) State {
    if (std.mem.eql(u8, state, "merged")) return .merged;
    if (std.mem.eql(u8, state, "closed")) return .closed;
    return if (draft) .draft else .open;
}

pub fn role(kind: Kind, state: State) Role {
    return switch (state) {
        .open => .success,
        .draft => .muted,
        .merged => .accent,
        // A pull request closed without merging was turned down; an issue
        // closed is done, so it recedes rather than alarms.
        .closed => if (kind == .pull) .danger else .muted,
    };
}

pub fn label(state: State) []const u8 {
    return switch (state) {
        .open => "Open",
        .draft => "Draft",
        .merged => "Merged",
        .closed => "Closed",
    };
}

/// How many of a loaded page's items are in each state.
pub const Counts = struct {
    loaded: usize = 0,
    open: usize = 0,
    draft: usize = 0,
    merged: usize = 0,
    closed: usize = 0,

    /// `items`: anything with `state` and `isDraft` (`app_github_repository.Item`).
    pub fn of(items: anytype) Counts {
        var n: Counts = .{ .loaded = items.len };
        for (items) |item| switch (stateOf(item.state, item.isDraft)) {
            .open => n.open += 1,
            .draft => n.draft += 1,
            .merged => n.merged += 1,
            .closed => n.closed += 1,
        };
        return n;
    }
};

/// The line above the list, honest that it counts only the loaded page:
/// "30 loaded · 3 open · 1 draft · 3 merged · 2 closed", then "· more on
/// next page" when the host has another (last, so a narrow pane cuts it
/// before the counts), and "Page 2 · " first past page one. States with no
/// items are left out. Empty for an empty page.
pub fn summaryLine(buf: []u8, n: Counts, page: usize, has_next: bool) []const u8 {
    return writeSummary(buf, n, page, has_next, 4, false);
}

/// `summaryLine` as it fits in `max_w` (as `measure.width` reads it),
/// never cut mid-word: whole when it fits; else without the "more on next
/// page" hint (pagination already says so); else with whole counts dropped
/// from the end, ending "· …"; at the narrowest, "N loaded" alone.
pub fn summaryFit(buf: []u8, n: Counts, page: usize, has_next: bool, max_w: f32, measure: anytype) []const u8 {
    const full = writeSummary(buf, n, page, has_next, 4, false);
    if (measure.width(full) <= max_w) return full;
    if (has_next) {
        const counts = writeSummary(buf, n, page, false, 4, false);
        if (measure.width(counts) <= max_w) return counts;
    }
    var keep: usize = 4;
    while (keep > 0) {
        keep -= 1;
        const cut = writeSummary(buf, n, page, false, keep, true);
        if (measure.width(cut) <= max_w) return cut;
    }
    return writeSummary(buf, n, page, false, 0, false);
}

/// The line with at most `max_parts` non-empty state counts, and " · …"
/// after them when `more` and any were left out.
fn writeSummary(buf: []u8, n: Counts, page: usize, has_next: bool, max_parts: usize, more: bool) []const u8 {
    if (n.loaded == 0) return "";
    var w: std.Io.Writer = .fixed(buf);
    if (page > 1) w.print("Page {d} · ", .{page}) catch return "";
    w.print("{d} loaded", .{n.loaded}) catch return "";
    const parts = [_]struct { usize, []const u8 }{ .{ n.open, "open" }, .{ n.draft, "draft" }, .{ n.merged, "merged" }, .{ n.closed, "closed" } };
    var shown: usize = 0;
    var left_out = false;
    for (parts) |p| if (p[0] > 0) {
        if (shown == max_parts) {
            left_out = true;
            continue;
        }
        w.print(" · {d} {s}", .{ p[0], p[1] }) catch return "";
        shown += 1;
    };
    if (more and left_out) w.writeAll(" · …") catch return "";
    if (has_next) w.writeAll(" · more on next page") catch return "";
    return w.buffered();
}

/// "just now", "5m ago", "2d ago", "3w ago" for an RFC 3339 time or a bare
/// date ("2026-11-24"); text it can't read comes back as its first ten bytes.
pub fn ago(buf: []u8, now_ms: i64, text: []const u8) []const u8 {
    const then = rules.parseTime(text) orelse blk: {
        if (text.len != 10) break :blk null;
        var day: [20]u8 = undefined;
        const full = std.fmt.bufPrint(&day, "{s}T00:00:00Z", .{text}) catch break :blk null;
        break :blk rules.parseTime(full);
    } orelse return text[0..@min(10, text.len)];
    var short: [16]u8 = undefined;
    const rel = rules.relativeTime(&short, now_ms, then);
    if (std.mem.eql(u8, rel, "now")) return "just now";
    return std.fmt.bufPrint(buf, "{s} ago", .{rel}) catch text[0..@min(10, text.len)];
}

/// `s` at most `max_w` wide as `measure.width` reads it, cut in the middle
/// so the file name stays whole: "src/cli…/rebuild_index.zig". A name too
/// long even for that keeps its end: "…long_name.zig". `buf` holds the
/// result and needs `s.len + 3` bytes; a shorter one returns `s`.
pub fn middleTruncate(buf: []u8, s: []const u8, max_w: f32, measure: anytype) []const u8 {
    if (measure.width(s) <= max_w or buf.len < s.len + 3) return s;
    const ellipsis = "…";
    const name_at = if (std.mem.lastIndexOfScalar(u8, s, '/')) |slash| slash else 0;
    const tail = s[name_at..];
    if (measure.width(join(buf, "", ellipsis, tail)) <= max_w) {
        // The longest head (on a character boundary) that still fits.
        var lo: usize = 0;
        var hi: usize = name_at;
        while (lo < hi) {
            var mid = lo + (hi - lo + 1) / 2;
            while (mid > lo and isContinuation(s, mid)) mid -= 1;
            if (mid == lo) break;
            if (measure.width(join(buf, s[0..mid], ellipsis, tail)) <= max_w) lo = mid else hi = mid - 1;
        }
        while (lo > 0 and isContinuation(s, lo)) lo -= 1;
        return join(buf, s[0..lo], ellipsis, tail);
    }
    // Keep the end of the name: the shortest suffix start that fits.
    var start: usize = name_at;
    while (start < s.len) : (start += 1) {
        if (isContinuation(s, start)) continue;
        if (measure.width(join(buf, "", ellipsis, s[start..])) <= max_w) break;
    }
    return join(buf, "", ellipsis, s[@min(start, s.len)..]);
}

fn isContinuation(s: []const u8, at: usize) bool {
    return at < s.len and (s[at] & 0xC0) == 0x80;
}

fn join(buf: []u8, head: []const u8, mid: []const u8, tail: []const u8) []const u8 {
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..][0..mid.len], mid);
    @memcpy(buf[head.len + mid.len ..][0..tail.len], tail);
    return buf[0 .. head.len + mid.len + tail.len];
}

/// How many of a row's label chips (`widths`, in order, `gap` apart) fit in
/// `room`; the rest are dropped, labels first, before the row's other words.
pub fn labelsThatFit(widths: []const f32, room: f32, gap: f32) usize {
    var used: f32 = 0;
    for (widths, 0..) |w, i| {
        const next = used + (if (i > 0) gap else 0) + w;
        if (next > room) return i;
        used = next;
    }
    return widths.len;
}

/// What an activity entry is, from the provider's event words
/// ("commented", "reviewed: approved", "committed", "labeled", …).
pub const Event = enum { comment, approved, changes_requested, review, commit, label, merge, close, reopen, other };

pub fn eventOf(words: []const u8) Event {
    const has = struct {
        fn f(h: []const u8, n: []const u8) bool {
            return std.mem.indexOf(u8, h, n) != null;
        }
    }.f;
    if (std.mem.startsWith(u8, words, "reviewed")) {
        if (has(words, "approved")) return .approved;
        if (has(words, "changes")) return .changes_requested;
        return .review;
    }
    if (std.mem.startsWith(u8, words, "commented")) return .comment;
    if (std.mem.startsWith(u8, words, "committed")) return .commit;
    if (std.mem.startsWith(u8, words, "labeled") or std.mem.startsWith(u8, words, "unlabeled")) return .label;
    if (std.mem.startsWith(u8, words, "merged")) return .merge;
    if (std.mem.startsWith(u8, words, "closed")) return .close;
    if (std.mem.startsWith(u8, words, "reopened")) return .reopen;
    return .other;
}

/// A review's verdict as a chip, else null: approved `success`, changes
/// requested `danger`.
pub fn reviewChip(e: Event) ?struct { text: []const u8, role: Role } {
    return switch (e) {
        .approved => .{ .text = "Approved", .role = .success },
        .changes_requested => .{ .text = "Changes requested", .role = .danger },
        else => null,
    };
}

/// A working-tree status letter's tone: added green, deleted red, changed
/// in the warning hue, untracked or unknown muted.
pub const FileTone = enum { added, deleted, changed, untracked };

pub fn fileTone(letter: []const u8) FileTone {
    const ch = if (letter.len > 0) letter[0] else ' ';
    return switch (ch) {
        'A' => .added,
        'D' => .deleted,
        'M', 'R', 'C', 'T', 'U' => .changed,
        else => .untracked,
    };
}

const testing = std.testing;

test "one state to role mapping: open, draft, merged and closed are told apart and agree across panes" {
    try testing.expectEqual(State.open, stateOf("open", false));
    try testing.expectEqual(State.draft, stateOf("open", true));
    try testing.expectEqual(State.merged, stateOf("merged", false));
    try testing.expectEqual(State.closed, stateOf("closed", false));
    // A closed draft is closed: the state word wins over the draft flag.
    try testing.expectEqual(State.closed, stateOf("closed", true));
    try testing.expectEqual(Role.success, role(.pull, .open));
    try testing.expectEqual(Role.muted, role(.pull, .draft));
    try testing.expectEqual(Role.accent, role(.pull, .merged));
    try testing.expectEqual(Role.danger, role(.pull, .closed));
    try testing.expectEqual(Role.success, role(.issue, .open));
    try testing.expectEqual(Role.muted, role(.issue, .closed));
    // Every pull request state has its own role.
    const all = [_]State{ .open, .draft, .merged, .closed };
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| try testing.expect(role(.pull, a) != role(.pull, b));
    try testing.expectEqualStrings("Merged", label(.merged));
    try testing.expectEqualStrings("Draft", label(.draft));
}

test "the summary line counts only the loaded page and says when more may exist" {
    const Item = struct { state: []const u8, isDraft: bool = false };
    const items = [_]Item{ .{ .state = "open" }, .{ .state = "open", .isDraft = true }, .{ .state = "merged" }, .{ .state = "merged" }, .{ .state = "closed" }, .{ .state = "open" } };
    const n = Counts.of(&items);
    try testing.expectEqual(Counts{ .loaded = 6, .open = 2, .draft = 1, .merged = 2, .closed = 1 }, n);
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("6 loaded · 2 open · 1 draft · 2 merged · 1 closed", summaryLine(&buf, n, 1, false));
    try testing.expectEqualStrings("6 loaded · 2 open · 1 draft · 2 merged · 1 closed · more on next page", summaryLine(&buf, n, 1, true));
    try testing.expectEqualStrings("Page 3 · 6 loaded · 2 open · 1 draft · 2 merged · 1 closed", summaryLine(&buf, n, 3, false));
    // Issues have no merged or draft items: those parts are left out.
    try testing.expectEqualStrings("4 loaded · 3 open · 1 closed", summaryLine(&buf, .{ .loaded = 4, .open = 3, .closed = 1 }, 1, false));
    try testing.expectEqualStrings("", summaryLine(&buf, .{}, 1, true));
}

test "the summary line fits whole or drops whole pieces, never a word" {
    const n: Counts = .{ .loaded = 8, .open = 2, .draft = 1, .merged = 3, .closed = 2 };
    var buf: [160]u8 = undefined;
    const full = "8 loaded · 2 open · 1 draft · 3 merged · 2 closed · more on next page";
    const counts = "8 loaded · 2 open · 1 draft · 3 merged · 2 closed";
    const w = Fixed.width;
    try testing.expectEqualStrings(full, summaryFit(&buf, n, 1, true, w(.{}, full), Fixed{}));
    // A width that cuts the hint mid-word ("… · more on nex…"): the hint goes whole.
    try testing.expectEqualStrings(counts, summaryFit(&buf, n, 1, true, w(.{}, full) - 6, Fixed{}));
    try testing.expectEqualStrings(counts, summaryFit(&buf, n, 1, true, w(.{}, counts), Fixed{}));
    // Narrower: whole counts leave from the end.
    try testing.expectEqualStrings("8 loaded · 2 open · 1 draft · 3 merged · …", summaryFit(&buf, n, 1, true, w(.{}, counts) - 1, Fixed{}));
    try testing.expectEqualStrings("8 loaded · 2 open · …", summaryFit(&buf, n, 1, false, 22, Fixed{}));
    try testing.expectEqualStrings("8 loaded", summaryFit(&buf, n, 1, false, 4, Fixed{}));
    // Every answer ends on a whole word or the ellipsis piece.
    var width: f32 = 4;
    while (width < 90) : (width += 1) {
        const got = summaryFit(&buf, n, 1, true, width, Fixed{});
        try testing.expect(std.mem.endsWith(u8, got, "loaded") or std.mem.endsWith(u8, got, "open") or std.mem.endsWith(u8, got, "draft") or
            std.mem.endsWith(u8, got, "merged") or std.mem.endsWith(u8, got, "closed") or std.mem.endsWith(u8, got, " · …") or std.mem.endsWith(u8, got, "next page"));
    }
}

test "relative dates read as the sidebar's, with ago" {
    var buf: [24]u8 = undefined;
    const now = rules.parseTime("2026-11-27T12:00:00Z").?;
    try testing.expectEqualStrings("just now", ago(&buf, now, "2026-11-27T11:59:30Z"));
    try testing.expectEqualStrings("5m ago", ago(&buf, now, "2026-11-27T11:55:00Z"));
    try testing.expectEqualStrings("3h ago", ago(&buf, now, "2026-11-27T09:00:00Z"));
    try testing.expectEqualStrings("2d ago", ago(&buf, now, "2026-11-25T10:00:00Z"));
    try testing.expectEqualStrings("2d ago", ago(&buf, now, "2026-11-25"));
    try testing.expectEqualStrings("2w ago", ago(&buf, now, "2026-11-13"));
    try testing.expectEqualStrings("yesterday", ago(&buf, now, "yesterday"));
    // A clock that runs behind the host never reads as the future.
    try testing.expectEqualStrings("just now", ago(&buf, now, "2026-11-28T00:00:00Z"));
}

const Fixed = struct {
    /// One unit per character, as a monospaced face measures.
    fn width(_: Fixed, s: []const u8) f32 {
        return @floatFromInt(std.unicode.utf8CountCodepoints(s) catch s.len);
    }
};

test "paths are cut in the middle so the file name stays visible" {
    var buf: [128]u8 = undefined;
    const path = "src/cli/commands/rebuild_index.zig";
    try testing.expectEqualStrings(path, middleTruncate(&buf, path, 80, Fixed{}));
    const cut = middleTruncate(&buf, path, 26, Fixed{});
    try testing.expectEqualStrings("src/cli…/rebuild_index.zig", cut);
    try testing.expect(Fixed.width(.{}, cut) <= 26);
    try testing.expect(std.mem.endsWith(u8, middleTruncate(&buf, path, 20, Fixed{}), "/rebuild_index.zig"));
    // No room for the whole name: its end survives.
    try testing.expectEqualStrings("…index.zig", middleTruncate(&buf, path, 10, Fixed{}));
    // No directory at all.
    try testing.expectEqualStrings("…_name.txt", middleTruncate(&buf, "a_really_long_name.txt", 10, Fixed{}));
    // Multi-byte characters are never split.
    const wide = middleTruncate(&buf, "dossiers/éééééé/notes.md", 16, Fixed{});
    try testing.expect(std.unicode.utf8ValidateSlice(wide));
    try testing.expect(std.mem.endsWith(u8, wide, "/notes.md"));
    // Too small a buffer leaves the text alone.
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings(path, middleTruncate(&tiny, path, 10, Fixed{}));
}

test "labels drop first, in order, when the row narrows" {
    const widths = [_]f32{ 48, 80, 60 };
    try testing.expectEqual(@as(usize, 3), labelsThatFit(&widths, 400, 4));
    try testing.expectEqual(@as(usize, 3), labelsThatFit(&widths, 48 + 4 + 80 + 4 + 60, 4));
    try testing.expectEqual(@as(usize, 2), labelsThatFit(&widths, 140, 4));
    try testing.expectEqual(@as(usize, 1), labelsThatFit(&widths, 100, 4));
    try testing.expectEqual(@as(usize, 0), labelsThatFit(&widths, 40, 4));
    try testing.expectEqual(@as(usize, 0), labelsThatFit(&.{}, 40, 4));
}

test "activity events and file status letters read by kind" {
    try testing.expectEqual(Event.comment, eventOf("commented"));
    try testing.expectEqual(Event.approved, eventOf("reviewed: approved"));
    try testing.expectEqual(Event.changes_requested, eventOf("reviewed: changes_requested"));
    try testing.expectEqual(Event.review, eventOf("reviewed"));
    try testing.expectEqual(Event.commit, eventOf("committed"));
    try testing.expectEqual(Event.label, eventOf("labeled"));
    try testing.expectEqual(Event.other, eventOf("assigned"));
    try testing.expectEqual(Role.success, reviewChip(.approved).?.role);
    try testing.expectEqual(Role.danger, reviewChip(.changes_requested).?.role);
    try testing.expect(reviewChip(.comment) == null);
    try testing.expectEqual(FileTone.added, fileTone("A"));
    try testing.expectEqual(FileTone.deleted, fileTone("D"));
    try testing.expectEqual(FileTone.changed, fileTone("M"));
    try testing.expectEqual(FileTone.untracked, fileTone("?"));
}
