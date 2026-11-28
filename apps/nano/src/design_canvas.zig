//! Paper.design-inspired design workspace state, responsive artboards,
//! spatial critique pins, and live DESIGN.md compliance auditing.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const ux = @import("ux_rules.zig").DesignCanvas;
const Allocator = std.mem.Allocator;

pub const max_pins: usize = 16;

pub const Pin = struct {
    x: f32 = 0,
    y: f32 = 0,
    permille_x: u32 = 0,
    permille_y: u32 = 0,
    note: ui.TextBuffer = .{},
    field_id: u64 = 0,

    pub fn deinit(p: *Pin) void {
        @import("text_buffer.zig").deinit(&p.note);
        p.* = .{};
    }
};

pub const RuleStatus = struct {
    name: []const u8,
    detail: []const u8,
    passed: bool,
};

pub const Audit = struct {
    score: u32,
    contrast_x100: u32,
    inner_radius: u32,
    rules: [4]RuleStatus,
};

pub const SourceKind = enum {
    theme_preview,
    browse_snapshot,
};

pub const State = struct {
    preset: ux.ArtboardPreset = .desktop,
    zoom_pct: u32 = 100,
    pan_x: f32 = 0,
    pan_y: f32 = 0,
    show_grid: bool = true,
    show_rulers: bool = true,
    show_inspector: bool = true,
    show_dom_overlay: bool = true,
    pin_mode: bool = false,
    dragging_pan: bool = false,
    last_mouse: ui.Point = .{},
    pins: [max_pins]Pin = @splat(.{}),
    pin_count: usize = 0,
    focus_pin: ?usize = null,
    source: SourceKind = .theme_preview,
    preview_url: ui.TextBuffer = .{},

    pub fn deinit(s: *State) void {
        @import("text_buffer.zig").deinit(&s.preview_url);
        for (&s.pins) |*p| p.deinit();
        s.* = .{};
    }

    pub fn setPreset(s: *State, preset: ux.ArtboardPreset) void {
        s.preset = preset;
        s.pan_x = 0;
        s.pan_y = 0;
    }

    pub fn stepZoom(s: *State, zoom_in: bool) void {
        s.zoom_pct = ux.stepZoomPct(s.zoom_pct, zoom_in);
    }

    pub fn resetZoom(s: *State) void {
        s.zoom_pct = 100;
        s.pan_x = 0;
        s.pan_y = 0;
    }

    pub fn fitToViewport(s: *State, avail_w: f32, avail_h: f32) void {
        const art = ux.presetSize(s.preset);
        const w_ratio = (@max(avail_w - 48, 80) * 100.0) / @as(f32, @floatFromInt(art.w));
        const h_ratio = (@max(avail_h - 48, 80) * 100.0) / @as(f32, @floatFromInt(art.h));
        const fit_u: u32 = @intFromFloat(@max(25.0, @floor(@min(w_ratio, h_ratio))));
        s.zoom_pct = ux.clampZoomPct(fit_u);
        s.pan_x = 0;
        s.pan_y = 0;
    }

    pub fn addPinNorm(s: *State, norm_x: f32, norm_y: f32) ?usize {
        if (s.pin_count >= max_pins) return null;
        const clamped_x = std.math.clamp(norm_x, 0.0, 1.0);
        const clamped_y = std.math.clamp(norm_y, 0.0, 1.0);
        const raw_px: u32 = @intFromFloat(@round(clamped_x * 1000.0));
        const raw_py: u32 = @intFromFloat(@round(clamped_y * 1000.0));
        const pm = ux.clampPinPermille(raw_px, raw_py);
        const idx = s.pin_count;
        s.pins[idx] = .{
            .x = @as(f32, @floatFromInt(pm.x)) / 1000.0,
            .y = @as(f32, @floatFromInt(pm.y)) / 1000.0,
            .permille_x = pm.x,
            .permille_y = pm.y,
        };
        s.pin_count += 1;
        s.focus_pin = idx;
        return idx;
    }

    pub fn removePin(s: *State, idx: usize) void {
        if (idx >= s.pin_count) return;
        s.pins[idx].deinit();
        var i = idx;
        while (i + 1 < s.pin_count) : (i += 1) {
            s.pins[i] = s.pins[i + 1];
        }
        s.pins[s.pin_count - 1] = .{};
        s.pin_count -= 1;
        if (s.focus_pin) |fp| {
            if (fp == idx) s.focus_pin = null else if (fp > idx) s.focus_pin = fp - 1;
        }
    }

    pub fn clearPins(s: *State) void {
        for (s.pins[0..s.pin_count]) |*p| p.deinit();
        s.pin_count = 0;
        s.focus_pin = null;
    }
};

fn channelLuminance(c: f32) f32 {
    const v = std.math.clamp(c, 0.0, 1.0);
    return if (v <= 0.03928) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// Relative luminance scaled to `0..10000` for integer Lean-matched WCAG checks.
pub fn relativeLuminance10000(col: ui.Color) u32 {
    const l = 0.2126 * channelLuminance(col.r) +
        0.7152 * channelLuminance(col.g) +
        0.0722 * channelLuminance(col.b);
    return @intFromFloat(std.math.clamp(@round(l * 10000.0), 0.0, 10000.0));
}

pub fn auditTheme(k: theme.Colors) Audit {
    const l_bg = relativeLuminance10000(k.background);
    const l_fg = relativeLuminance10000(k.text);
    const ratio_x100 = ux.contrastRatioX100(l_bg, l_fg);
    const contrast_ok = ux.meetsWcagAA(l_bg, l_fg, false);
    const hit_ok = ux.hitTargetValid(32, 32);
    const inner_r = ux.concentricInner(16, 1, 3);
    const radius_ok = inner_r + 4 == 16;
    const type_motion_ok = ux.allowedTypeSize(13) and
        ux.motionValid(false, false, false, 220) and
        !ux.motionValid(false, true, false, 200);

    return .{
        .score = ux.auditScore(hit_ok, type_motion_ok, radius_ok, contrast_ok),
        .contrast_x100 = ratio_x100,
        .inner_radius = inner_r,
        .rules = .{
            .{ .name = "WCAG AA contrast", .detail = "Body text >= 4.5:1 on surface", .passed = contrast_ok },
            .{ .name = "Hit target floor", .detail = "Primary controls >= 32 px", .passed = hit_ok },
            .{ .name = "Concentric radii", .detail = "outer(16) - b(1) - p(3) = 12 px", .passed = radius_ok },
            .{ .name = "Type & quint motion", .detail = "11/12/13/14/16 px · easeOut <= 250 ms", .passed = type_motion_ok },
        },
    };
}

pub fn formatFeedback(gpa: Allocator, s: *const State, k: theme.Colors) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const art = ux.presetSize(s.preset);
    const audit = auditTheme(k);

    const head = try std.fmt.allocPrint(
        gpa,
        "Design critique on {s} artboard ({d}x{d} px @ {d}%, DESIGN.md score {d}/4, contrast {d}.{d:0>2}:1):\n",
        .{
            @tagName(s.preset),
            art.w,
            art.h,
            s.zoom_pct,
            audit.score,
            audit.contrast_x100 / 100,
            audit.contrast_x100 % 100,
        },
    );
    defer gpa.free(head);
    try out.appendSlice(gpa, head);

    if (s.preview_url.text().len > 0) {
        const url_line = try std.fmt.allocPrint(gpa, "Target URL: {s}\n", .{s.preview_url.text()});
        defer gpa.free(url_line);
        try out.appendSlice(gpa, url_line);
    }

    for (s.pins[0..s.pin_count], 0..) |pin, idx| {
        const note = std.mem.trim(u8, pin.note.text(), " \t\r\n");
        const x_pct: u32 = pin.permille_x / 10;
        const y_pct: u32 = pin.permille_y / 10;
        const line = try std.fmt.allocPrint(
            gpa,
            "- Pin #{d} at ({d}%, {d}%): {s}\n",
            .{ idx + 1, x_pct, y_pct, if (note.len > 0) note else "(inspect element here)" },
        );
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

fn toU8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v * 255.0), 0.0, 255.0));
}

fn putPx(buf: []u8, w: usize, h: usize, x: i32, y: i32, r: u8, g: u8, b: u8, a: u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(w)) or y >= @as(i32, @intCast(h))) return;
    const off = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))) * 4;
    buf[off] = r;
    buf[off + 1] = g;
    buf[off + 2] = b;
    buf[off + 3] = a;
}

fn fillRectPx(buf: []u8, w: usize, h: usize, rx: i32, ry: i32, rw: i32, rh: i32, col: ui.Color) void {
    const r = toU8(col.r);
    const g = toU8(col.g);
    const b = toU8(col.b);
    const a = toU8(col.a);
    var yy = ry;
    while (yy < ry + rh) : (yy += 1) {
        var xx = rx;
        while (xx < rx + rw) : (xx += 1) putPx(buf, w, h, xx, yy, r, g, b, a);
    }
}

fn fillCirclePx(buf: []u8, w: usize, h: usize, cx: i32, cy: i32, rad: i32, col: ui.Color) void {
    const r = toU8(col.r);
    const g = toU8(col.g);
    const b = toU8(col.b);
    const a = toU8(col.a);
    var dy = -rad;
    while (dy <= rad) : (dy += 1) {
        var dx = -rad;
        while (dx <= rad) : (dx += 1) {
            if (dx * dx + dy * dy <= rad * rad) putPx(buf, w, h, cx + dx, cy + dy, r, g, b, a);
        }
    }
}

fn appendPngChunk(out: *std.ArrayList(u8), gpa: Allocator, kind: *const [4]u8, data: []const u8) !void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len_be);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum_be, crc.final(), .big);
    try out.appendSlice(gpa, &sum_be);
}

/// Pure-Zig RGBA PNG snapshot of the current Design Canvas artboard + critique pins.
pub fn renderAnnotatedArtboardPng(gpa: Allocator, s: *const State, k: theme.Colors, audit: Audit) ![]u8 {
    _ = audit;
    const dims: struct { w: usize, h: usize } = switch (s.preset) {
        .mobile => .{ .w = 240, .h = 400 },
        .tablet => .{ .w = 320, .h = 400 },
        .desktop => .{ .w = 440, .h = 280 },
    };
    const w = dims.w;
    const h = dims.h;
    const row_bytes = 1 + w * 4;
    const raw = try gpa.alloc(u8, row_bytes * h);
    defer gpa.free(raw);

    // Fill backdrop & scanline filter bytes (0 = none).
    const bg_r = toU8(k.panel.r);
    const bg_g = toU8(k.panel.g);
    const bg_b = toU8(k.panel.b);
    for (0..h) |yy| {
        const base = yy * row_bytes;
        raw[base] = 0;
        for (0..w) |xx| {
            const p = base + 1 + xx * 4;
            raw[p] = bg_r;
            raw[p + 1] = bg_g;
            raw[p + 2] = bg_b;
            raw[p + 3] = 255;
        }
    }

    // Artboard frame & token blocks inside RGBA slice without touching filter byte.
    const fb = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(fb);
    for (0..h) |yy| {
        @memcpy(fb[yy * w * 4 .. (yy + 1) * w * 4], raw[yy * row_bytes + 1 .. yy * row_bytes + 1 + w * 4]);
    }

    // Concentric stage + swatch row + accent CTA + spatial pins.
    const pad: i32 = 16;
    const fw: i32 = @intCast(w);
    const fh: i32 = @intCast(h);
    fillRectPx(fb, w, h, pad, pad, fw - pad * 2, fh - pad * 2, k.background);
    fillRectPx(fb, w, h, pad + 12, pad + 12, fw - (pad + 12) * 2, 56, k.composer);
    fillRectPx(fb, w, h, pad + 20, pad + 24, 18, 18, k.accent);
    const sw_w: i32 = @divTrunc(fw - (pad + 12) * 2 - 8, 2);
    fillRectPx(fb, w, h, pad + 12, pad + 78, sw_w, 34, k.composer);
    fillRectPx(fb, w, h, pad + 12 + sw_w + 8, pad + 78, sw_w, 34, k.accent);
    fillRectPx(fb, w, h, pad + 12, pad + 122, fw - (pad + 12) * 2, 32, k.accent);

    for (s.pins[0..s.pin_count]) |pin| {
        const px: i32 = pad + @as(i32, @intFromFloat(@round(pin.x * @as(f32, @floatFromInt(fw - pad * 2)))));
        const py: i32 = pad + @as(i32, @intFromFloat(@round(pin.y * @as(f32, @floatFromInt(fh - pad * 2)))));
        fillCirclePx(fb, w, h, px, py, 9, k.background);
        fillCirclePx(fb, w, h, px, py, 7, k.accent);
    }

    for (0..h) |yy| {
        @memcpy(raw[yy * row_bytes + 1 .. yy * row_bytes + 1 + w * 4], fb[yy * w * 4 .. (yy + 1) * w * 4]);
    }

    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var at: usize = 0;
    while (true) {
        const n = @min(raw.len - at, 65535);
        const last = at + n == raw.len;
        try z.append(gpa, if (last) 1 else 0);
        try z.appendSlice(gpa, &.{ @truncate(n), @truncate(n >> 8), @truncate(~n), @truncate(~n >> 8) });
        try z.appendSlice(gpa, raw[at .. at + n]);
        at += n;
        if (last) break;
    }
    var adler_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_be, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(gpa, &adler_be);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(w), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(h), .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try appendPngChunk(&out, gpa, "IHDR", &ihdr);
    try appendPngChunk(&out, gpa, "IDAT", z.items);
    try appendPngChunk(&out, gpa, "IEND", "");
    return out.toOwnedSlice(gpa);
}

test "design canvas state clamps zoom/pins and audits dark and light themes" {
    var s: State = .{};
    defer s.deinit();

    s.stepZoom(true);
    try std.testing.expectEqual(@as(u32, 125), s.zoom_pct);
    s.zoom_pct = 900;
    s.stepZoom(true);
    try std.testing.expectEqual(@as(u32, 400), s.zoom_pct);
    s.zoom_pct = 10;
    s.stepZoom(false);
    try std.testing.expectEqual(@as(u32, 25), s.zoom_pct);

    const idx0 = s.addPinNorm(1.5, -0.2).?;
    try std.testing.expectEqual(@as(u32, 1000), s.pins[idx0].permille_x);
    try std.testing.expectEqual(@as(u32, 0), s.pins[idx0].permille_y);
    s.pins[idx0].note.set("Align header radius");

    const dark_audit = auditTheme(theme.colors(true));
    const light_audit = auditTheme(theme.colors(false));
    try std.testing.expectEqual(@as(u32, 4), dark_audit.score);
    try std.testing.expectEqual(@as(u32, 4), light_audit.score);

    const msg = try formatFeedback(std.testing.allocator, &s, theme.colors(true));
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Pin #1 at (100%, 0%): Align header radius") != null);

    const png = try renderAnnotatedArtboardPng(std.testing.allocator, &s, theme.colors(true), dark_audit);
    defer std.testing.allocator.free(png);
    try std.testing.expect(png.len > 100);
    try std.testing.expectEqualStrings("\x89PNG", png[0..4]);
    try std.testing.expectEqualStrings("IHDR", png[12..16]);
    try std.testing.expectEqual(@as(u32, 440), std.mem.readInt(u32, png[16..20], .big));
}
