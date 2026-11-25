//! Platform caption geometry and Windows custom-frame controls.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const App = @import("app.zig").App;

pub fn leadingFor(os: std.Target.Os.Tag) f32 {
    return if (os == .macos) 88 else 8;
}
pub fn trailingFor(os: std.Target.Os.Tag) f32 {
    return if (os == .windows) 46 * 3 else 0;
}
pub const leading = leadingFor(builtin.os.tag);
pub const trailing = trailingFor(builtin.os.tag);
pub const Action = enum { minimize, maximize, close };

extern "user32" fn IsZoomed(hwnd: ?*anyopaque) callconv(.winapi) i32;

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime builtin.os.tag != .windows) return;
    const zoomed = if (a.window) |w| IsZoomed(w.hwnd) != 0 else false;
    if (buttons(c, k, zoomed)) |action| if (a.window) |w| switch (action) {
        .minimize => w.minimize(),
        .maximize => w.zoom(),
        .close => w.close(),
    };
}

/// Kept callable offscreen on every host: tests exercise the actual caption
/// hit targets, including HTMAXBUTTON for Windows 11 Snap Layouts.
pub fn buttons(c: *ui.Context, k: theme.Colors, zoomed: bool) ?Action {
    const lane = ui.div(c).fixed().offset(c.size.w - trailingFor(.windows), 0)
        .size(trailingFor(.windows), 38).row().layer(10);
    defer lane.end();
    var clicked: ?Action = null;
    inline for (.{ Action.minimize, Action.maximize, Action.close }) |action| {
        ui.key(c, @tagName(action));
        const button = ui.div(c).row().size(46, 38).center().control()
            .hover(if (action == .close) ui.Color.hex(0xc42b1c) else k.hover);
        c.node(button.index).style.window_maximize = action == .maximize;
        defer button.end();
        const ink = if (action == .close and button.hovered()) ui.Color.hex(0xffffff) else k.text;
        switch (action) {
            .minimize => {
                const cv = ui.canvas(c, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } });
                cv.line(.{ .x = 1, .y = 6 }, .{ .x = 11, .y = 6 }, .{ .width = 1, .color = ink });
            },
            .maximize => {
                const cv = ui.canvas(c, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } });
                if (zoomed) {
                    // Back window: exposed top-right L-bracket only so interiors stay transparent on hover.
                    cv.polyline(&.{
                        .{ .x = 3.5, .y = 3.5 },
                        .{ .x = 3.5, .y = 1.5 },
                        .{ .x = 10.5, .y = 1.5 },
                        .{ .x = 10.5, .y = 8.5 },
                        .{ .x = 8.5, .y = 8.5 },
                    }, .{ .width = 1, .color = ink });
                    // Front window outline.
                    cv.polyline(&.{
                        .{ .x = 1.5, .y = 3.5 },
                        .{ .x = 8.5, .y = 3.5 },
                        .{ .x = 8.5, .y = 10.5 },
                        .{ .x = 1.5, .y = 10.5 },
                        .{ .x = 1.5, .y = 3.5 },
                    }, .{ .width = 1, .color = ink });
                } else {
                    cv.polyline(&.{
                        .{ .x = 1.5, .y = 1.5 },
                        .{ .x = 10.5, .y = 1.5 },
                        .{ .x = 10.5, .y = 10.5 },
                        .{ .x = 1.5, .y = 10.5 },
                        .{ .x = 1.5, .y = 1.5 },
                    }, .{ .width = 1, .color = ink });
                }
            },
            .close => @import("icons.zig").icon(c, .close, 12, ink, 0),
        }
        if (button.clicked()) clicked = action;
    }
    return clicked;
}

fn countSegmentInstances(instances: anytype) usize {
    var count: usize = 0;
    for (instances) |inst| {
        if (inst.kind == 6.0) count += 1;
    }
    return count;
}

fn pixelAt(px: anytype, x: usize, y: usize) [4]u8 {
    const i = (y * px.width + x) * 4;
    return px.bytes[i..][0..4].*;
}

test "Windows caption buttons occupy the trailing lane and emit window actions" {
    const Fixture = struct {
        action: ?Action = null,
        zoomed: bool = false,
        colors: theme.Colors,
        fn view(f: *@This(), c: *ui.Context) void {
            ui.div(c).sizeFull().bg(f.colors.shell).end();
            if (buttons(c, f.colors, f.zoomed)) |action| f.action = action;
        }
    };
    @import("theme.zig").registerFonts();
    var f: Fixture = .{ .colors = theme.colors(true) };
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&f, Fixture.view), .{ .width = 760, .height = 480 });
    defer t.deinit();
    t.settle(0.1);
    try std.testing.expectEqual(@as(usize, 5), countSegmentInstances(t.instances.items));
    try std.testing.expectEqual(.maximize, t.ctx.framePartAt(.{ .x = 691, .y = 19 }, true));

    // Hover maximize (unzoomed): interior center keeps the hover background instead of k.shell.
    t.moveTo(691, 19);
    {
        const px = try t.render(std.testing.allocator);
        defer px.deinit(std.testing.allocator);
        const s: usize = @intFromFloat(t.scale);
        const bg_px = pixelAt(px, 10 * s, 19 * s);
        const hover_px = pixelAt(px, (691 - 15) * s, 19 * s);
        const center_px = pixelAt(px, 691 * s, 19 * s);
        try std.testing.expect(!std.mem.eql(u8, &hover_px, &bg_px));
        for (hover_px, center_px) |a, b| try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 1);
    }

    inline for (.{ Action.minimize, Action.maximize, Action.close }, 0..) |action, i| {
        t.click(760 - 138 + 23 + @as(f32, @floatFromInt(i)) * 46, 19);
        try std.testing.expectEqual(action, f.action.?);
        f.action = null;
    }
    f.zoomed = true;
    t.settle(0.1);
    try std.testing.expectEqual(@as(usize, 9), countSegmentInstances(t.instances.items));

    // Hover restore (zoomed): front window interior center stays transparent over the hover fill.
    t.moveTo(691, 19);
    {
        const px = try t.render(std.testing.allocator);
        defer px.deinit(std.testing.allocator);
        const s: usize = @intFromFloat(t.scale);
        const hover_px = pixelAt(px, (691 - 15) * s, 19 * s);
        const center_px = pixelAt(px, 690 * s, 20 * s);
        for (hover_px, center_px) |a, b| try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 1);
    }

    if (std.c.getenv("HARNESS_CHROME_SNAP_PATH")) |raw_path| {
        try snapCaptionPreview(std.mem.span(raw_path));
    }
    try std.testing.expectEqual(@as(f32, 88), leadingFor(.macos));
    try std.testing.expectEqual(@as(f32, 8), leadingFor(.windows));
    try std.testing.expectEqual(@as(f32, 8), leadingFor(.linux));
    try std.testing.expectEqual(@as(f32, 0), trailingFor(.macos));
    try std.testing.expectEqual(@as(f32, 138), trailingFor(.windows));
}

fn snapCaptionPreview(path: []const u8) !void {
    const gpa = std.testing.allocator;
    const Preview = struct {
        zoomed: bool = false,
        colors: theme.Colors,
        fn view(p: *@This(), c: *ui.Context) void {
            const top = ui.div(c).sizeFull().bg(p.colors.shell);
            defer top.end();
            ui.text(c, if (p.zoomed) "Restore hover (zoomed)" else "Maximize hover (normal)", .{ .size = 11, .color = p.colors.muted });
            _ = buttons(c, p.colors, p.zoomed);
        }
    };
    var p: Preview = .{ .colors = theme.colors(true) };
    var dark = theme.ui(true);
    dark.background = p.colors.shell;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&p, Preview.view), .{ .width = 280, .height = 50, .scale = 3, .theme = dark });
    defer t.deinit();

    // Hover `.maximize` in unzoomed mode (`buttons` places buttons at [w-138 .. w]).
    p.zoomed = false;
    t.moveTo(280 - 138 + 46 + 23, 19);
    const top_px = try t.render(gpa);
    defer top_px.deinit(gpa);

    p.zoomed = true;
    t.moveTo(280 - 138 + 46 + 23, 19);
    const bot_px = try t.render(gpa);
    defer bot_px.deinit(gpa);

    const combined = try gpa.alloc(u8, top_px.bytes.len + bot_px.bytes.len);
    defer gpa.free(combined);
    @memcpy(combined[0..top_px.bytes.len], top_px.bytes);
    @memcpy(combined[top_px.bytes.len..], bot_px.bytes);
    try ui.png.writePng(gpa, std.testing.io, path, .{
        .bytes = combined,
        .width = top_px.width,
        .height = top_px.height + bot_px.height,
    });
}
