//! Chat-owned inspection of bytes already loaded through the jailed host cache.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const images = @import("app_attachment_images.zig");
const annotate = @import("image_annotate.zig");
const attachments = @import("app_attachments.zig");

pub fn open(a: *App, chat_id: ?[]const u8, image: *images.Image) void {
    const chat = chat_id orelse return;
    if (image.status != .ready or image.bytes.items.len == 0) return;
    const owner = a.gpa.dupe(u8, chat) catch return;
    close(a);
    const cache = &a.attachments.images;
    cache.preview = image;
    cache.preview_chat = owner;
    cache.zoom = 1;
    cache.center = .{ .x = 0.5, .y = 0.5 };
    cache.inspection = .{};
    cache.annotate.reset();
    cache.copy_status = .none;
    cache.copy_until = 0;
    a.redraw();
}

pub fn close(a: *App) void {
    const cache = &a.attachments.images;
    cache.preview = null;
    if (cache.preview_chat) |chat| a.gpa.free(chat);
    cache.preview_chat = null;
    cache.drag = null;
    cache.focus_scope = .{};
    cache.annotate.reset();
    cache.copy_status = .none;
    cache.copy_until = 0;
    a.redraw();
}

pub fn visible(a: *const App) bool {
    const cache = &a.attachments.images;
    const chat = cache.preview_chat orelse return false;
    if (cache.preview == null or !@import("app_question.zig").ownsActivePane(a)) return false;
    return std.mem.eql(u8, chat, a.selected.?);
}

/// A hidden/background inspector never eats another pane's Escape or typing.
pub fn keys(c: *ui.Context, a: *App) bool {
    if (!visible(a)) return false;
    if (!a.attachments.images.annotate.hasFocus(c.focus)) {
        a.attachments.images.focus_scope.keys(c);
    }
    if (c.shortcut(.{ .key = ui.Shortcut.escape }) or c.input.key == .escape) {
        c.input.key = null;
        dismiss(c, a);
    }
    return true;
}

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, bounds: ?ui.Rect) void {
    if (!visible(a)) return;
    const r = bounds orelse return;
    const cache = &a.attachments.images;
    const image = cache.preview orelse return;
    cache.focus_scope.begin(c);
    ui.key(c, "chat-image-preview");
    const card = ui.div(c).fixed().offset(r.x + 8, r.y + 8).size(@max(1, r.w - 16), @max(1, r.h - 16)).column().p(12).gap(10).rounded(8).bg(k.background).border(k.accent.alpha(0.4)).borderW(1).clip().control().layer(6);
    defer card.end();
    {
        const row = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer row.end();
        ui.text(c, "Image preview", .{ .size = 12, .weight = .semibold, .color = k.text });
        ui.spacer(c);
        if (cache.focus_scope.button(c, k, "Close preview")) {
            dismiss(c, a);
            return;
        }
    }
    {
        const row = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer row.end();
        if (cache.focus_scope.button(c, k, "Zoom out")) cache.zoom = @max(1, cache.zoom / 1.5);
        if (cache.focus_scope.button(c, k, "Zoom in")) cache.zoom = @min(4, cache.zoom * 1.5);
        if (cache.focus_scope.button(c, k, "Fit")) {
            cache.zoom = 1;
            cache.center = .{ .x = 0.5, .y = 0.5 };
        }
        if (cache.focus_scope.button(c, k, "Copy image")) {
            if (c.clipboard.write_image(c.clipboard.ctx, image.bytes.items)) {
                cache.copy_status = .copied;
                cache.copy_until = c.time + 2.0;
                c.frameIn(2.0);
            } else {
                cache.copy_status = .failed;
                cache.copy_until = c.time + 3.0;
                c.frameIn(3.0);
            }
        }
        if (annotateButton(c, k, "Annotate", cache.annotate.active)) {
            cache.annotate.active = !cache.annotate.active;
            cache.drag = null;
            a.redraw();
        }
        if (cache.copy_status != .none) {
            if (c.time >= cache.copy_until) {
                cache.copy_status = .none;
            } else {
                const msg = if (cache.copy_status == .copied) "Copied" else "Copy failed";
                const color = if (cache.copy_status == .copied) k.accent else k.danger;
                ui.text(c, msg, .{ .size = 10.5, .weight = .medium, .color = color });
            }
        }
        ui.text(c, c.print("{d:.0}%", .{cache.zoom * 100}), .{ .size = 10.5, .color = k.muted });
    }
    const hint = if (cache.annotate.active)
        "Click image to drop callout pins · Click a pin to edit its note · Esc to close"
    else
        "Scroll or pinch to zoom · Drag to inspect · Esc to close";
    ui.text(c, hint, .{ .size = 10.5, .color = k.muted });

    const annotating = cache.annotate.active;
    // Keep the annotation stage height steady from 0 pins through 8 pins so
    // dropping pin #1 never shifts or shrinks the image under the user's cursor.
    const pin_list_h: f32 = if (annotating) 92 else 0;
    const pin_footer_h: f32 = if (annotating) 36 else 0;
    const area = ui.div(c).column().wFull().grow().h(0).center().clip().control().wheel();
    defer area.end();
    const key = c.print("inspect:{s}:{s}:{x}", .{ image.device, image.path, image.content_hash });
    const natural = ui.imageSize(c, key, image.bytes.items) orelse return;
    const fit = @min(@max(1, r.w - 42) / natural.w, @max(1, r.h - 148 - pin_list_h - pin_footer_h) / natural.h);
    const w = @max(1, natural.w * fit);
    const h = @max(1, natural.h * fit);
    const viewport = c.rects.get(c.node(area.index).id) orelse r;
    const pic_rect: ui.Rect = .{
        .x = viewport.x + (viewport.w - w) / 2,
        .y = viewport.y + (viewport.h - h) / 2,
        .w = w,
        .h = h,
    };
    const part = if (cache.annotate.active) blk: {
        cache.drag = null;
        const inv = 1 / cache.zoom;
        const half = inv * 0.5;
        cache.inspection = .{ .inverse = inv, .center = cache.center };
        break :blk [4]f32{ cache.center.x - half, cache.center.y - half, cache.center.x + half, cache.center.y + half };
    } else @import("image_inspection.zig").update(c, cache, area.hovered(), pic_rect);

    {
        ui.key(c, "preview-stage");
        const stage = ui.div(c).row().size(w, h).clip().control();
        defer stage.end();
        _ = ui.image(c, .{
            .key = key,
            .source = .{ .encoded = image.bytes.items },
            .box = .{ .w = w, .h = h },
            .part = part,
        });
        if (cache.annotate.active) {
            const stage_rect = c.rects.get(c.node(stage.index).id) orelse pic_rect;
            if (stage.clicked()) {
                // Clicking an existing pin focuses its note instead of stacking a duplicate pin.
                const hit_pin: ?usize = blk_hit: {
                    for (cache.annotate.pins[0..cache.annotate.count], 0..) |pin, idx| {
                        const pos = annotate.imageToScreen(.{ .x = pin.x, .y = pin.y }, stage_rect, part) orelse continue;
                        const dx = (c.input.mouse.x - stage_rect.x) - pos.x;
                        const dy = (c.input.mouse.y - stage_rect.y) - pos.y;
                        if (dx * dx + dy * dy <= 14 * 14) break :blk_hit idx;
                    }
                    break :blk_hit null;
                };
                if (hit_pin) |idx| {
                    cache.annotate.focus_pin = idx;
                    a.redraw();
                } else if (annotate.screenToImage(c.input.mouse, stage_rect, part)) |pt| {
                    _ = cache.annotate.addPin(pt.x, pt.y);
                    a.redraw();
                }
            }
            const on_accent = k.onAccent();
            for (cache.annotate.pins[0..cache.annotate.count], 0..) |pin, idx| {
                const pos = annotate.imageToScreen(.{ .x = pin.x, .y = pin.y }, stage_rect, part) orelse continue;
                ui.key(c, c.print("pin-marker-{d}", .{idx}));
                const badge = ui.div(c).absolute()
                    .offset(std.math.clamp(pos.x - 11, 0, @max(0, w - 22)), std.math.clamp(pos.y - 11, 0, @max(0, h - 22)))
                    .size(22, 22).center().roundedFull().bg(k.accent).border(k.background).borderW(1.5);
                ui.text(c, c.print("{d}", .{idx + 1}), .{ .size = 10.5, .weight = .semibold, .color = on_accent });
                badge.end();
            }
        }
    }

    if (annotating) {
        if (cache.annotate.count > 0) {
            drawPinNotes(c, a, k, &cache.annotate, pin_list_h);
        } else {
            const empty = ui.div(c).row().wFull().h(pin_list_h).center().rounded(6)
                .bg(k.ink(if (k.dark) 0.04 else 0.03)).border(k.border).borderW(1);
            ui.text(c, "Click anywhere on the image to place a numbered callout pin.", .{ .size = 11, .color = k.muted });
            empty.end();
        }
        const footer = ui.div(c).row().wFull().h(28).gap(6).itemsCenter();
        defer footer.end();
        const count_label = if (cache.annotate.count == 0)
            "No pins yet"
        else
            c.print("{d} {s}", .{ cache.annotate.count, if (cache.annotate.count == 1) "pin" else "pins" });
        ui.text(c, count_label, .{ .size = 10.5, .color = k.muted });
        ui.spacer(c);
        if (cache.annotate.count > 0) {
            if (annotateButton(c, k, "Undo", false)) {
                cache.annotate.undo();
                a.redraw();
            }
            if (annotateButton(c, k, "Clear", false)) {
                cache.annotate.clearPins();
                a.redraw();
            }
            if (annotateButton(c, k, c.print("Send feedback ({d})", .{cache.annotate.count}), true)) {
                sendFeedback(c, a, image);
                return;
            }
        }
    }
}

fn drawPinNotes(c: *ui.Context, a: *App, k: theme.Colors, state: *annotate.State, panel_h: f32) void {
    const list = ui.div(c).column().wFull().h(panel_h).gap(6).scrollY();
    defer list.end();
    const on_accent = k.onAccent();
    var remove_idx: ?usize = null;
    for (state.pins[0..state.count], 0..) |*pin, idx| {
        ui.key(c, c.print("pin-row-{d}", .{idx}));
        const row = ui.div(c).row().wFull().h(28).gap(6).itemsCenter();
        defer row.end();

        const num = ui.div(c).row().size(20, 20).center().roundedFull().bg(k.accent);
        ui.text(c, c.print("{d}", .{idx + 1}), .{ .size = 10, .weight = .semibold, .color = on_accent });
        num.end();

        const px: u32 = @intFromFloat(@round(pin.x * 100));
        const py: u32 = @intFromFloat(@round(pin.y * 100));
        ui.text(c, c.print("({d}%, {d}%)", .{ px, py }), .{ .size = 10.5, .color = k.muted });

        const field_box = ui.div(c).row().grow().w(0).h(26).px(8).itemsCenter().rounded(6)
            .bg(k.ink(if (k.dark) 0.06 else 0.045)).border(k.border).borderW(1);
        ui.key(c, c.print("pin-note-{d}", .{idx}));
        const fid = c.peekId(null);
        pin.field_id = fid;
        if (state.focus_pin) |fp| if (fp == idx) {
            c.focus = fid;
            c.changed = true;
            state.focus_pin = null;
        };
        _ = ui.textField(c, &pin.note, .{
            .placeholder = "Note for this callout…",
            .placeholder_color = k.faint,
            .width = .fill,
            .bare = true,
            .size = 11.5,
            .line_height = 18,
        });
        field_box.end();

        ui.key(c, c.print("pin-del-{d}", .{idx}));
        const del = ui.div(c).row().size(22, 22).center().rounded(5).hover(k.hover).control();
        ui.text(c, "×", .{ .size = 12, .color = k.muted });
        if (del.clicked()) remove_idx = idx;
        del.end();
    }
    if (remove_idx) |idx| {
        state.removePin(idx);
        a.redraw();
    }
}

fn annotateButton(c: *ui.Context, k: theme.Colors, label: []const u8, accent: bool) bool {
    ui.key(c, label);
    var b = ui.div(c).row().h(26).px(8).itemsCenter().rounded(5).control();
    b = if (accent) b.bg(k.accent) else b.bg(k.hover);
    defer b.end();
    const clicked = @import("control_behavior.zig").activateIndex(c, b.index, k, label, true, false);
    ui.text(c, label, .{ .size = 10.5, .weight = if (accent) .medium else .regular, .color = if (accent) k.onAccent() else k.text });
    return clicked or b.clicked();
}

fn sendFeedback(c: *ui.Context, a: *App, image: *images.Image) void {
    const cache = &a.attachments.images;
    const formatted = annotate.formatFeedback(a.gpa, image.path, cache.annotate.pins[0..cache.annotate.count]) catch return;
    defer a.gpa.free(formatted);
    attachments.attachExisting(a, image.path) catch {};
    const current = std.mem.trim(u8, a.composer.text(), " \t\r\n");
    if (current.len == 0) {
        a.composer.set(formatted);
    } else {
        const joined = std.fmt.allocPrint(a.gpa, "{s}\n\n{s}", .{ current, formatted }) catch return;
        defer a.gpa.free(joined);
        a.composer.set(joined);
    }
    a.view.focus_composer = true;
    dismiss(c, a);
}

fn dismiss(c: *ui.Context, a: *App) void {
    a.attachments.images.focus_scope.restore(c);
    close(a);
}
