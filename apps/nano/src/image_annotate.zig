//! Click-to-annotate callout pins for the chat image preview inspector.
//! Keeps pin state strictly local to the open preview and emits structured
//! numbered feedback back into the owning chat's composer draft.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("nanoui").ui;
const attachments = @import("app_attachments.zig");

pub const max_pins = 8;

pub const Pin = struct {
    /// Normalized image coordinates in [0, 1].
    x: f32 = 0.5,
    y: f32 = 0.5,
    note: ui.TextBuffer = .{},
    field_id: u64 = 0,

    pub fn deinit(p: *Pin) void {
        p.note.deinit();
        p.* = .{};
    }
};

pub const State = struct {
    active: bool = false,
    pins: [max_pins]Pin = @splat(.{}),
    count: usize = 0,
    focus_pin: ?usize = null,

    pub fn reset(s: *State) void {
        for (s.pins[0..s.count]) |*p| p.deinit();
        s.count = 0;
        s.active = false;
        s.focus_pin = null;
    }

    pub fn deinit(s: *State) void {
        s.reset();
    }

    pub fn addPin(s: *State, x: f32, y: f32) ?usize {
        if (s.count >= max_pins) return null;
        const idx = s.count;
        s.pins[idx] = .{
            .x = std.math.clamp(x, 0, 1),
            .y = std.math.clamp(y, 0, 1),
        };
        s.count += 1;
        s.focus_pin = idx;
        return idx;
    }

    pub fn removePin(s: *State, idx: usize) void {
        if (idx >= s.count) return;
        s.pins[idx].deinit();
        var i = idx;
        while (i + 1 < s.count) : (i += 1) {
            s.pins[i] = s.pins[i + 1];
        }
        s.count -= 1;
        s.pins[s.count] = .{};
        if (s.focus_pin) |fp| {
            if (fp == idx) s.focus_pin = null else if (fp > idx) s.focus_pin = fp - 1;
        }
    }

    pub fn undo(s: *State) void {
        if (s.count > 0) s.removePin(s.count - 1);
    }

    pub fn clearPins(s: *State) void {
        for (s.pins[0..s.count]) |*p| p.deinit();
        s.count = 0;
        s.focus_pin = null;
    }

    pub fn hasFocus(s: *const State, focus_id: u64) bool {
        if (focus_id == 0) return false;
        for (s.pins[0..s.count]) |pin| {
            if (pin.field_id == focus_id) return true;
        }
        return false;
    }
};

/// Convert pointer coordinates inside `picture` to normalized image `(u, v)`
/// accounting for the visible zoom/pan crop `part = [u0, v0, u1, v1]`.
pub fn screenToImage(mouse: ui.Point, picture: ui.Rect, part: [4]f32) ?ui.Point {
    if (picture.w <= 0 or picture.h <= 0) return null;
    if (mouse.x < picture.x or mouse.x > picture.x + picture.w) return null;
    if (mouse.y < picture.y or mouse.y > picture.y + picture.h) return null;
    const rx = (mouse.x - picture.x) / picture.w;
    const ry = (mouse.y - picture.y) / picture.h;
    return .{
        .x = std.math.clamp(part[0] + rx * (part[2] - part[0]), 0, 1),
        .y = std.math.clamp(part[1] + ry * (part[3] - part[1]), 0, 1),
    };
}

/// Convert normalized image `(u, v)` to pixel offset relative to `picture`
/// (`0..picture.w`, `0..picture.h`), or null when panned outside `part`.
pub fn imageToScreen(pin: ui.Point, picture: ui.Rect, part: [4]f32) ?ui.Point {
    const span_x = part[2] - part[0];
    const span_y = part[3] - part[1];
    if (span_x <= 0 or span_y <= 0) return null;
    if (pin.x < part[0] or pin.x > part[2] or pin.y < part[1] or pin.y > part[3]) return null;
    return .{
        .x = (pin.x - part[0]) / span_x * picture.w,
        .y = (pin.y - part[1]) / span_y * picture.h,
    };
}

/// Format numbered callouts for insertion into the active chat's composer.
pub fn formatFeedback(gpa: Allocator, image_path: []const u8, pins: []const Pin) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("Image feedback on {s}:", .{attachments.displayName(image_path)});
    for (pins, 0..) |*pin, i| {
        const px: u32 = @intFromFloat(@round(std.math.clamp(pin.x, 0, 1) * 100));
        const py: u32 = @intFromFloat(@round(std.math.clamp(pin.y, 0, 1) * 100));
        const note = std.mem.trim(u8, pin.note.text(), " \t\r\n");
        if (note.len > 0) {
            try out.writer.print("\n{d}. ({d}%, {d}%): {s}", .{ i + 1, px, py, note });
        } else {
            try out.writer.print("\n{d}. ({d}%, {d}%): (marked area)", .{ i + 1, px, py });
        }
    }
    return try out.toOwnedSlice();
}

test "image annotation coordinate mapping round-trips under default and zoomed crops" {
    const t = std.testing;
    const rect: ui.Rect = .{ .x = 100, .y = 50, .w = 400, .h = 200 };
    const full = [4]f32{ 0, 0, 1, 1 };
    const p1 = screenToImage(.{ .x = 300, .y = 150 }, rect, full).?;
    try t.expectApproxEqAbs(@as(f32, 0.5), p1.x, 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.5), p1.y, 0.001);
    const s1 = imageToScreen(p1, rect, full).?;
    try t.expectApproxEqAbs(@as(f32, 200), s1.x, 0.01);
    try t.expectApproxEqAbs(@as(f32, 100), s1.y, 0.01);

    // Zoomed 2x crop centered at (0.5, 0.5) => [0.25, 0.25, 0.75, 0.75].
    const zoomed = [4]f32{ 0.25, 0.25, 0.75, 0.75 };
    const p2 = screenToImage(.{ .x = 200, .y = 100 }, rect, zoomed).?;
    try t.expectApproxEqAbs(@as(f32, 0.375), p2.x, 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.375), p2.y, 0.001);
    try t.expect(imageToScreen(.{ .x = 0.1, .y = 0.1 }, rect, zoomed) == null);
    try t.expect(screenToImage(.{ .x = 50, .y = 100 }, rect, full) == null);
}

test "image annotation state manages pins and formats numbered composer feedback" {
    const t = std.testing;
    var s: State = .{};
    defer s.deinit();
    const idx0 = s.addPin(0.42, 0.68).?;
    s.pins[idx0].note.set("Tighten spacing");
    _ = s.addPin(0.78, 0.24).?;
    const text = try formatFeedback(t.allocator, "/synthetic/workspace/mockup.png", s.pins[0..s.count]);
    defer t.allocator.free(text);
    try t.expectEqualStrings(
        "Image feedback on mockup.png:\n1. (42%, 68%): Tighten spacing\n2. (78%, 24%): (marked area)",
        text,
    );
    s.undo();
    try t.expectEqual(@as(usize, 1), s.count);
    s.clearPins();
    try t.expectEqual(@as(usize, 0), s.count);
}
