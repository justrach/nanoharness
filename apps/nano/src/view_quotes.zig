//! Quoting a reply into the draft (#152), as it is seen: "Add to chat"
//! beside a selection in one reply, the composer's quote chips, and the way
//! back from a chip to its passage.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const quotes = @import("app_quotes.zig");
const tr = @import("transcript.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const selection_owner = @import("selection_owner.zig");

const none = std.math.maxInt(u32);
const action_label = "Add to chat";
const action_h: f32 = 28;
const action_gap: f32 = 4;
/// How long a chip's passage is kept where it was put, while the rows
/// around it are laid out and folded work opens.
const reveal_s: f64 = 0.5;

/// The text of a reply's part as drawn this frame: its nodes
/// `[first, end)`, in row `row` of the transcript.
const Span = struct { entry: []const u8, part: []const u8, row: u32, first: u32, end: u32 };

/// The open chat's replies as this frame draws them: what a selection can
/// be quoted from, and where a chip's passage is.
pub const Rows = struct {
    spans: std.ArrayList(Span) = .empty,
    row: u32 = 0,

    /// A reply's row starts. One split by a message sent while it worked
    /// is several: no passage runs across the message.
    pub fn next(r: *Rows) void {
        r.row += 1;
    }

    /// The part `[first, now)` drew.
    pub fn note(r: *Rows, c: *ui.Context, entry: []const u8, part: []const u8, start: usize) void {
        if (c.nodes.items.len == start) return;
        r.spans.append(c.alloc(), .{ .entry = entry, .part = part, .row = r.row, .first = @intCast(start), .end = @intCast(c.nodes.items.len) }) catch {};
    }

    fn at(r: *const Rows, node: u32) ?usize {
        for (r.spans.items, 0..) |s, i| if (node >= s.first and node < s.end) return i;
        return null;
    }
};

const Leaf = struct { node: u32, id: u64, str: []const u8, start: usize };

/// The selectable text of row `row` from span `from` on, a line per leaf as
/// Copy joins them.
const Passage = struct {
    leaves: std.ArrayList(Leaf) = .empty,
    text: std.ArrayList(u8) = .empty,

    fn init(c: *ui.Context, rows: *const Rows, from: usize) !Passage {
        var p: Passage = .{};
        const row = rows.spans.items[from].row;
        for (rows.spans.items[from..]) |s| {
            if (s.row != row) break;
            for (s.first..s.end) |i| {
                const str = leafText(c, @intCast(i)) orelse continue;
                if (p.leaves.items.len > 0) try p.text.append(c.alloc(), '\n');
                try p.leaves.append(c.alloc(), .{ .node = @intCast(i), .id = c.nodes.items[i].id, .str = str, .start = p.text.items.len });
                try p.text.appendSlice(c.alloc(), str);
            }
        }
        return p;
    }

    fn offset(p: *const Passage, node: u32, byte: usize) ?usize {
        for (p.leaves.items) |l| if (l.node == node) return l.start + @min(byte, l.str.len);
        return null;
    }

    const Place = struct { leaf: Leaf, byte: usize };

    /// Where the passage's byte `off` is drawn; at a join, the start of the
    /// next leaf or (`end`) the end of the one before.
    fn place(p: *const Passage, off: usize, end: bool) ?Place {
        for (p.leaves.items) |l| {
            const stop = l.start + l.str.len;
            if (off < l.start) return .{ .leaf = l, .byte = 0 };
            if (off < stop or (off == stop and end)) return .{ .leaf = l, .byte = off - l.start };
        }
        return null;
    }

    /// Where the passage's `nth` `text` is.
    fn find(p: *const Passage, text: []const u8, nth: usize) ?[2]usize {
        var from: usize = 0;
        var n: usize = 0;
        while (std.mem.indexOfPos(u8, p.text.items, from, text)) |at| : (n += 1) {
            if (n == nth) return .{ at, at + text.len };
            from = at + 1;
        }
        return null;
    }
};

/// Text a selection takes: selectable and no control's, as paint has it.
fn leafText(c: *const ui.Context, ix: u32) ?[]const u8 {
    const n = c.nodes.items[ix];
    if (n.content != .text or n.content.text.str.len == 0) return null;
    var selectable = false;
    var at = ix;
    while (at != none) {
        const up = c.nodes.items[at];
        if (up.style.control) return null;
        selectable = selectable or up.style.selectable;
        at = up.parent;
    }
    return if (selectable) n.content.text.str else null;
}

/// After the transcript's rows are drawn, in their column: a chip's passage
/// is brought into view, and a selection in one reply gets its action.
pub fn settle(c: *ui.Context, a: *App, k: theme.Colors, rows: *const Rows, t: *const tr.Transcript, box: u64) void {
    reveal(c, a, rows, t, box);
    action(c, a, k, rows, box);
}

// ---- "Add to chat"

const Pick = struct { text: []const u8, source: quotes.Source, lo: End, hi: End };
const End = struct { node: u32, byte: usize };

/// The selection as a quote: both its ends in the text of one reply.
fn picked(c: *ui.Context, a: *const App, rows: *const Rows, box: u64) ?Pick {
    const s = &c.selection;
    const anchor = s.anchor orelse return null;
    const focus = s.focus orelse return null;
    if (std.meta.eql(anchor, focus)) return null;
    if (a.quotes.shown != null) return null;
    if (quotes.owner(a) == null or (s.dragging and c.input.down)) return null;
    if (selection_owner.state(c).surface != box) return null;
    var lo: ?End = null;
    var hi: ?End = null;
    for (rows.spans.items) |span| for (span.first..span.end) |i| {
        const id = c.nodes.items[i].id;
        if (id == anchor.id) add(&lo, &hi, .{ .node = @intCast(i), .byte = anchor.at });
        if (id == focus.id) add(&lo, &hi, .{ .node = @intCast(i), .byte = focus.at });
    };
    const from = lo orelse return null;
    const to = hi orelse return null;
    const ix = rows.at(from.node).?;
    if (rows.spans.items[ix].row != rows.spans.items[rows.at(to.node).?].row) return null;
    const passage = Passage.init(c, rows, ix) catch return null;
    const start = passage.offset(from.node, from.byte) orelse return null;
    const end = passage.offset(to.node, to.byte) orelse return null;
    if (end <= start) return null;
    const raw = passage.text.items[start..end];
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    const at = start + (std.mem.trimStart(u8, raw, " \t\r\n").ptr - raw.ptr);
    var nth: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, passage.text.items, pos, text)) |x| : (pos = x + 1) {
        if (x >= at) break;
        nth += 1;
    }
    const span = rows.spans.items[ix];
    return .{ .text = text, .source = .{ .entry = span.entry, .part = span.part, .nth = nth }, .lo = from, .hi = to };
}

/// The ends as they are met, in reading order.
fn add(lo: *?End, hi: *?End, end: End) void {
    if (lo.* == null) {
        lo.* = end;
    } else if (lo.*.?.node == end.node and end.byte < lo.*.?.byte) {
        hi.* = lo.*;
        lo.* = end;
    } else hi.* = end;
}

/// Whether the selection is still the one a chip's click highlighted.
fn showing(c: *ui.Context, a: *const App) bool {
    const ids = a.quotes.shown orelse return false;
    const at = a.quotes.shown_at;
    const anchor = c.selection.anchor orelse return false;
    const focus = c.selection.focus orelse return false;
    return anchor.id == ids[0] and anchor.at == at[0] and focus.id == ids[1] and focus.at == at[1];
}

fn action(c: *ui.Context, a: *App, k: theme.Colors, rows: *const Rows, box: u64) void {
    if (!showing(c, a)) a.quotes.shown = null;
    if (c.selection.anchor == null) return;
    const pick = picked(c, a, rows, box) orelse return;
    const view = c.rects.get(box) orelse return;
    const parent = c.rects.get(c.nodes.items[c.stack.items[c.stack.items.len - 1]].id) orelse return;
    const lo = line(c, pick.lo) orelse return;
    const hi = line(c, pick.hi) orelse return;
    // Both were laid out before this frame's scroll.
    const moved = (c.scroll.get(box) orelse 0) - (c.scroll_seen.get(box) orelse (c.scroll.get(box) orelse 0));
    const top = view.y + moved;
    const bottom = view.y + view.h + moved;
    if (hi.y + hi.h <= top or lo.y >= bottom) return;
    const st = kit.style(c, 12, 16, .{ .weight = .medium, .color = k.text });
    const w = @ceil(c.text.width(action_label, st)) + 8 + 14 + 6 + 10 + 2;
    // Under its end, over its start where there is no room, and within the
    // viewport when both are out of it.
    const under = hi.y + hi.h + action_gap;
    const over = lo.y - action_gap - action_h;
    const y = if (under >= top and under + action_h <= bottom)
        under
    else if (over >= top and over + action_h <= bottom)
        over
    else
        std.math.clamp(under, top + 4, @max(top + 4, bottom - action_h - 4));
    const right = if (y == over) lo.x + w else hi.x;
    const x = std.math.clamp(right - w, parent.x, @max(parent.x, parent.x + parent.w - w));
    ui.key(c, "add-to-chat");
    const fill = if (k.frosted) theme.colors(k.dark).pill() else k.pill();
    const b = kit.shadowLg(ui.div(c).row().absolute().offset(x - parent.x, y - parent.y).size(w, action_h).pl(8).pr(10).gap(6).itemsCenter().rounded(8).border(k.border).borderW(1).control()).bg(fill);
    const clicked = @import("control_behavior.zig").activate(c, b, k, action_label, true, false);
    // Its press is not a press on the text under it: the selection stays.
    if (c.input.pressed and c.hot == c.node(b.index).id) {
        c.selection.pressed = false;
        c.selection.dragging = false;
        c.selection.moved = false;
    }
    icons.icon(c, .@"chat-round-line", 14, if (c.hot == c.node(b.index).id) k.text else k.muted, 0);
    ui.text(c, action_label, st);
    b.end();
    if (!clicked) return;
    quotes.add(a, pick.text, pick.source) catch {
        a.setNotice("Couldn't add the selection to the chat.");
    };
    c.selection.clear();
    a.view.focus_composer = true;
    c.changed = true;
}

/// The line of text `end` is on as last laid out, its x the end's.
fn line(c: *ui.Context, end: End) ?ui.Rect {
    const n = c.nodes.items[end.node];
    const r = c.rects.get(n.id) orelse return null;
    const tx = n.content.text;
    const lh = c.text.lineHeight(tx.style);
    const byte = @min(end.byte, tx.str.len);
    const lines = if (tx.spans.len > 0)
        c.text.wrapAttributed(tx.str, tx.style, tx.spans, r.w)
    else if (tx.style.wrap)
        c.text.wrap(tx.str, tx.style, r.w)
    else
        return .{ .x = r.x + c.text.width(tx.str[0..byte], tx.style), .y = r.y, .w = 0, .h = lh };
    for (lines, 0..) |l, i| {
        if (byte > l.end and i + 1 < lines.len) continue;
        const stop = std.math.clamp(byte, l.start, @max(l.start, l.end));
        return .{ .x = r.x + c.text.width(tx.str[l.start..stop], tx.style), .y = r.y + lh * @as(f32, @floatFromInt(i)), .w = 0, .h = lh };
    }
    return .{ .x = r.x, .y = r.y, .w = 0, .h = lh };
}

// ---- Back to the passage

/// Shows a chip's passage: its click.
fn show(c: *ui.Context, a: *App, item: *const quotes.Item) void {
    @import("view_write.zig").close(a);
    a.quotes.reveal = .{ .item = item.id, .started = c.time };
    a.view.focus_composer = true;
    c.changed = true;
    a.redraw();
}

/// Whether reply `entry` is to be drawn though it is off screen: a chip's
/// passage is in it.
pub fn wants(a: *const App, entry: []const u8) bool {
    const r = a.quotes.reveal orelse return false;
    const item = a.quotes.find(r.item) orelse return false;
    return item.active(a) and std.mem.eql(u8, item.entry, entry);
}

/// Whether folded `work` of reply `entry` is to be opened, once: a chip's
/// passage is in it.
pub fn opens(a: *App, entry: []const u8, work: []const tr.Part) bool {
    if (!wants(a, entry)) return false;
    const r = &a.quotes.reveal.?;
    if (r.opened) return false;
    const item = a.quotes.find(r.item).?;
    for (work) |p| if (std.mem.eql(u8, p.id, item.part)) {
        r.opened = true;
        return true;
    };
    return false;
}

fn reveal(c: *ui.Context, a: *App, rows: *const Rows, t: *const tr.Transcript, box: u64) void {
    const r = if (a.quotes.reveal) |*r| r else return;
    const item = a.quotes.find(r.item) orelse return done(a);
    const here = for (t.entries.items) |*e| {
        if (std.mem.eql(u8, e.id, item.entry)) break true;
    } else false;
    if (!item.active(a) or !here or c.time - r.started > reveal_s) return done(a);
    const seen = c.scroll_seen.get(box) orelse (c.scroll.get(box) orelse 0);
    const at = c.scroll.get(box) orelse seen;
    if (at != seen and r.frame != c.frame) return done(a);
    if (r.shown and (c.selection.anchor == null or c.selection.dragging)) return done(a);
    c.animationFrame();
    // From the part it was taken from; from the reply's start if that is
    // gone.
    const from = spanOf(rows, item.entry, item.part) orelse spanOf(rows, item.entry, null) orelse return;
    const passage = Passage.init(c, rows, from) catch return done(a);
    const found = passage.find(item.text, item.nth) orelse passage.find(item.text, 0);
    const lo = (if (found) |f| passage.place(f[0], false) else passage.place(0, false)) orelse return;
    const hi = (if (found) |f| passage.place(f[1], true) else null) orelse lo;
    if (found != null and !r.shown) highlight(c, a, box, lo, hi);
    r.shown = found != null;
    const view = c.rects.get(box) orelse return;
    const top = line(c, .{ .node = lo.leaf.node, .byte = lo.byte }) orelse return;
    const end = line(c, .{ .node = hi.leaf.node, .byte = hi.byte }) orelse return;
    const h = end.y + end.h - top.y;
    r.moves = r.moves or top.y < view.y + 28 or end.y + end.h > view.y + view.h - 8;
    if (!r.moves) return;
    // A third down, or as much of a long passage as fits.
    const margin = std.math.clamp((view.h - h) / 3, @min(28, view.h / 3), view.h / 3);
    const want = std.math.clamp(top.y - view.y + seen - margin, 0, c.scroll_max.get(box) orelse std.math.inf(f32));
    r.frame = c.frame;
    if (@abs(want - at) <= 0.5) return;
    // Where the reader was reading from no longer holds the transcript.
    a.view.stick_end = false;
    if (a.view.reply_anchors.getPtr(box)) |x| x.pending = false;
    if (a.view.rail.glide) |g| if (g.box == box) {
        a.view.rail.glide = null;
    };
    c.scroll.put(c.gpa, box, want) catch return;
    c.scroll_follow.put(c.gpa, box, false) catch {};
    // The rows there are drawn in this frame.
    c.changed = true;
}

fn done(a: *App) void {
    a.quotes.reveal = null;
}

fn spanOf(rows: *const Rows, entry: []const u8, part: ?[]const u8) ?usize {
    for (rows.spans.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.entry, entry) and (part == null or std.mem.eql(u8, s.part, part.?))) return i;
    }
    return null;
}

/// The passage as the window's selection, which the transcript keeps drawn.
fn highlight(c: *ui.Context, a: *App, box: u64, lo: Passage.Place, hi: Passage.Place) void {
    const s = &c.selection;
    s.clear();
    s.anchor = .{ .id = lo.leaf.id, .at = lo.byte };
    s.focus = .{ .id = hi.leaf.id, .at = hi.byte };
    s.pressed = false;
    s.dragging = false;
    s.moved = false;
    a.quotes.shown = .{ lo.leaf.id, hi.leaf.id };
    a.quotes.shown_at = .{ lo.byte, hi.byte };
    const state = selection_owner.state(c);
    state.surface = box;
    state.snapshot = 0;
    selection_owner.pin(c).* = .{};
    c.changed = true;
}

// ---- The composer's chips

/// The draft's quotes over its text, a line each.
pub fn strip(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    if (quotes.count(a) == 0) return;
    ui.key(c, "composer-quotes");
    const area = ui.div(c).column().wFull().maxH(148).px(16).pt(12).gap(6).itemsStart().scrollY().scrollbar(.{ .overlay = k.muted.alpha(0.45) });
    defer area.end();
    const st = kit.style(c, 12, 16, .{ .color = k.muted });
    const room = w - 32 - (8 + 12 + 6 + 4 + 20 + 4 + 2);
    for (a.quotes.items.items) |item| if (item.active(a)) {
        ui.key(c, c.print("quote-{d}", .{item.id}));
        const chip = ui.div(c).row().h(28).pr(4).gap(4).itemsCenter().rounded(8).border(k.border).borderW(1).bg(k.hover);
        defer chip.end();
        const text = @import("view_rail.zig").truncatePreview(c.alloc(), item.text, 240);
        {
            ui.key(c, "show");
            const body = ui.div(c).row().h(26).pl(8).gap(6).itemsCenter().rounded(7);
            defer body.end();
            if (@import("control_behavior.zig").activate(c, body, k, c.print("Show quoted passage: {s}", .{text}), true, false)) show(c, a, item);
            icons.icon(c, .@"chat-round-line", 12, k.muted, 0);
            kit.ellipsisText(c, text, if (c.hot == c.node(body.index).id) kit.style(c, 12, 16, .{ .color = k.text }) else st, room);
        }
        ui.key(c, "remove");
        if (kit.iconButton(c, k, .close, .{ .size = 20, .radius = 10, .icon = 10, .label = "Remove quote" })) {
            item.remove(a);
            c.changed = true;
        }
    };
}
