//! Compact multi-image gallery card for consecutive assistant reply pictures
//! (main stage + counter/prev/next header + thumbnail strip). Single images
//! keep rendering directly via `view_reply_images.zig`; matched Before/After
//! pairs keep rendering via `view_before_after.zig`.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const images = @import("app_attachment_images.zig");
const panel_chrome = @import("view_panel_chrome.zig");
const reply_images = @import("view_reply_images.zig");
const attachments = @import("app_attachments.zig");

pub const max_items = 16;

pub const Item = struct {
    path: []const u8,
    caption: []const u8,
};

pub const EntryState = struct {
    id: u64 = 0,
    index: usize = 0,
};

pub const State = struct {
    slots: [32]EntryState = @splat(.{}),
    count: usize = 0,
    next: usize = 0,

    pub fn entry(s: *State, id: u64) *EntryState {
        for (s.slots[0..s.count]) |*slot| {
            if (slot.id == id) return slot;
        }
        const ix = if (s.count < s.slots.len) blk: {
            const idx = s.count;
            s.count += 1;
            break :blk idx;
        } else blk: {
            const idx = s.next;
            s.next = (s.next + 1) % s.slots.len;
            break :blk idx;
        };
        s.slots[ix] = .{ .id = id };
        return &s.slots[ix];
    }
};

pub fn cardId(chat_id: ?[]const u8, owner_id: []const u8, first_id: []const u8, item_count: usize) u64 {
    var h = std.hash.Wyhash.init(0x47414c4c455259);
    for ([_][]const u8{ chat_id orelse "", owner_id, first_id }) |part| {
        h.update(std.mem.asBytes(&part.len));
        h.update(part);
    }
    h.update(std.mem.asBytes(&item_count));
    return h.final();
}

pub fn labelOf(item: Item) []const u8 {
    const trimmed = std.mem.trim(u8, item.caption, " \t\r\n");
    if (trimmed.len > 0) return trimmed;
    return attachments.displayName(item.path);
}

pub fn draw(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    chat_id: ?[]const u8,
    id: u64,
    items: []const Item,
    max_w: f32,
) void {
    if (items.len == 0) return;
    if (items.len == 1) {
        reply_images.draw(c, a, k, chat_id, items[0].path, items[0].caption, max_w);
        return;
    }

    const entry = a.view.gallery.entry(id);
    if (entry.index >= items.len) entry.index = items.len - 1;
    const active = items[entry.index];
    const card_w = @max(240, @min(max_w, 640));
    const chat = if (chat_id) |cid| a.findChat(cid) else null;
    const cwd = if (chat) |ch| ch.cwd else null;

    ui.key(c, c.print("reply-gallery-{x}", .{id}));
    const card = ui.div(c).column().w(card_w).p(12).gap(10).rounded(12)
        .bg(if (k.dark) k.ink(0.03) else ui.Color.white.alpha(0.62))
        .border(panel_chrome.zenEdge(k)).borderW(1).clip();
    defer card.end();

    // Header: caption on left, "1 of N" + Prev / Next controls on right.
    {
        const hdr = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer hdr.end();
        const title_box = ui.div(c).row().grow().w(0).clip();
        ui.text(c, labelOf(active), kit.style(c, 12.5, 17, .{ .weight = theme.ui_medium_weight, .color = k.text }));
        title_box.end();

        const pill = ui.div(c).row().h(22).px(7).itemsCenter().rounded(5)
            .bg(k.ink(if (k.dark) 0.06 else 0.045));
        ui.text(c, c.print("{d} of {d}", .{ entry.index + 1, items.len }), kit.style(c, 11, 15, .{ .color = k.muted }));
        pill.end();

        if (navButton(c, k, "gallery-prev", "Prev", "‹")) {
            entry.index = if (entry.index == 0) items.len - 1 else entry.index - 1;
            a.redraw();
        }
        if (navButton(c, k, "gallery-next", "Next", "›")) {
            entry.index = (entry.index + 1) % items.len;
            a.redraw();
        }
    }

    // Main stage for the selected image.
    {
        const frame = ui.div(c).column().wFull().p(4).rounded(8)
            .bg(k.shell.alpha(if (k.dark) 0.55 else 0.45))
            .border(panel_chrome.zenEdge(k)).borderW(1).center().clip().control();
        defer frame.end();
        const stage_w = if (c.rects.get(c.node(frame.index).id)) |r| @max(120, r.w - 8) else @max(120, card_w - 34);
        const resolved = reply_images.resolve(c.alloc(), cwd, active.path);
        const loaded = if (resolved) |p| images.get(a, chat_id, p) else null;
        if (loaded) |image| {
            if (image.status == .ready) {
                if (ui.image(c, .{
                    .key = c.print("gallery-stage:{s}:{s}:{x}", .{ image.device, image.path, image.content_hash }),
                    .source = .{ .encoded = image.bytes.items },
                    .max_width = stage_w,
                    .max_height = 360,
                    .scale = 1,
                    .radius = 6,
                })) {
                    const idx: u32 = @intCast(c.nodes.items.len - 1);
                    const activated = @import("preview_focus.zig").action(c, idx, k, c.print("Open image preview: {s}", .{labelOf(active)}));
                    if (activated or frame.clicked()) {
                        c.focus = c.node(idx).id;
                        @import("view_image_preview.zig").open(a, chat_id, image);
                    }
                } else {
                    stageFallback(c, k, active);
                }
            } else if (image.status == .loading) {
                const box = ui.div(c).row().wFull().h(160).center();
                ui.text(c, "Loading image…", kit.style(c, 12, 16, .{ .color = k.muted }));
                box.end();
            } else {
                stageFallback(c, k, active);
            }
        } else {
            stageFallback(c, k, active);
        }
    }

    // Thumbnail strip: compact tiles wrapped cleanly across rows to fit card_w.
    {
        const cols_f = @floor(@max(1, (card_w - 24 + 6) / 72.0));
        const per_row: usize = @max(1, @as(usize, @intFromFloat(cols_f)));
        const grid = ui.div(c).column().wFull().gap(6);
        defer grid.end();
        var row_start: usize = 0;
        while (row_start < items.len) : (row_start += per_row) {
            const row_end = @min(items.len, row_start + per_row);
            const strip = ui.div(c).row().wFull().gap(6).clip();
            defer strip.end();
            for (items[row_start..row_end], row_start..) |item, idx| {
                const selected = idx == entry.index;
                ui.key(c, c.print("gallery-thumb-{d}", .{idx}));
                var tile = ui.div(c).row().size(66, 46).p(3).center().rounded(7).clip().control();
                tile = if (selected)
                    tile.bg(k.accent_wash).border(k.accent).borderW(1.5)
                else
                    tile.bg(k.shell.alpha(if (k.dark) 0.55 else 0.45)).border(panel_chrome.zenEdge(k)).borderW(1).hover(k.hover);
                defer tile.end();

                const resolved = reply_images.resolve(c.alloc(), cwd, item.path);
                const loaded = if (resolved) |p| images.get(a, chat_id, p) else null;
                const drawn = if (loaded) |img| blk: {
                    const tb = images.tileBytes(img);
                    if (img.status == .ready and tb.len > 0) {
                        break :blk ui.image(c, .{
                            .key = c.print("gallery-tile:{s}:{s}:{x}:{d}", .{ img.device, img.path, img.content_hash, tb.len }),
                            .source = .{ .encoded = tb },
                            .max_width = 58,
                            .max_height = 38,
                            .scale = 1,
                            .radius = 4,
                        });
                    }
                    break :blk false;
                } else false;
                if (!drawn) {
                    ui.text(c, c.print("{d}", .{idx + 1}), kit.style(c, 11, 14, .{ .color = if (selected) k.accent else k.muted }));
                }
                if (tile.clicked()) {
                    entry.index = idx;
                    a.redraw();
                }
            }
        }
    }
}

fn navButton(c: *ui.Context, k: theme.Colors, id_key: []const u8, label: []const u8, glyph: []const u8) bool {
    ui.key(c, id_key);
    const btn = ui.div(c).row().h(22).px(7).itemsCenter().rounded(5)
        .bg(k.ink(if (k.dark) 0.06 else 0.045)).hover(k.hover).control();
    defer btn.end();
    const clicked = @import("control_behavior.zig").activateIndex(c, btn.index, k, label, true, false);
    ui.text(c, glyph, kit.style(c, 12, 15, .{ .weight = .semibold, .color = if (btn.hovered()) k.text else k.muted }));
    return clicked or btn.clicked();
}

fn stageFallback(c: *ui.Context, k: theme.Colors, item: Item) void {
    const box = ui.div(c).row().wFull().h(120).px(8).center();
    defer box.end();
    ui.text(c, c.print("Image unavailable{s}{s}", .{ if (item.caption.len > 0) ": " else "", item.caption }), kit.style(c, 12, 16, .{ .color = k.muted, .wrap = true }));
}

test "gallery state tracks selected index per card and label falls back to basename" {
    const t = std.testing;
    var s: State = .{};
    const id_a = cardId("chat-1", "entry-1", "p0", 3);
    const id_b = cardId("chat-1", "entry-2", "p0", 2);
    try t.expect(id_a != id_b);
    s.entry(id_a).index = 2;
    try t.expectEqual(@as(usize, 2), s.entry(id_a).index);
    try t.expectEqual(@as(usize, 0), s.entry(id_b).index);
    try t.expectEqualStrings("Direction A", labelOf(.{ .path = "/tmp/a.png", .caption = " Direction A " }));
    try t.expectEqualStrings("a.png", labelOf(.{ .path = "/tmp/a.png", .caption = "   " }));
}
