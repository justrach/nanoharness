//! macOS colour emoji rendering: verify RGB and internal detail survive
//! CoreText rasterization, BGRA colour atlas storage, and Metal sampling
//! in both light and dark themes across composer and Markdown table text.
const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const md = @import("view_markdown.zig");

const emoji_table =
    \\| Status | Note |
    \\| --- | --- |
    \\| ✅ Ready | **Bold** 😀 🚀 ❤️ |
    \\| ❌ Failed | Plain text |
;

fn probeView(a: *App, c: *ui.Context) void {
    const k = theme.colors(a.dark orelse false);
    const root = ui.div(c).column().sizeFull().p(16).gap(12).bg(k.background);
    defer root.end();
    ui.text(c, "Emoji probe: ✅ ❌ 😀 🚀 ❤️", .{ .size = 24, .line_height = 32, .color = k.text });
    _ = ui.textField(c, &a.composer, .{ .width = .fill, .size = 18, .line_height = 24, .color = k.text });
    const table_box = ui.div(c).column().w(420);
    defer table_box.end();
    md.markdown(c, k, emoji_table);
}

test "macOS colour emoji preserve RGB and internal detail in light and dark themes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    theme.registerFonts();
    for ([_]bool{ true, false }) |dark| {
        var a: App = .init(t.allocator, t.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = dark;
        a.composer.set("Composer: ✅ ❌ 😀 🚀 ❤️");

        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(&a, probeView), .{ .width = 520, .height = 260, .dark = dark });
        defer tester.deinit();
        tester.settle(0.2);

        var mono_glyphs: usize = 0;
        var color_glyphs: usize = 0;
        for (tester.instances.items) |inst| {
            if (inst.kind == 1) mono_glyphs += 1;
            if (inst.kind == 13) color_glyphs += 1;
        }
        try t.expect(mono_glyphs > 20);
        try t.expect(color_glyphs >= 10);

        if (std.c.getenv("NANO_EMOJI_SNAP_DIR")) |dir| {
            var buf: [1024]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/emoji-{s}.png", .{ std.mem.span(dir), if (dark) "dark" else "light" });
            try tester.screenshot(path);
        }

        const pixels = try tester.render(t.allocator);
        defer pixels.deinit(t.allocator);
        var chromatic: usize = 0;
        var green: usize = 0;
        var red: usize = 0;
        var yellow: usize = 0;
        var i: usize = 0;
        while (i + 3 < pixels.bytes.len) : (i += 4) {
            const b: i32 = pixels.bytes[i];
            const g: i32 = pixels.bytes[i + 1];
            const r: i32 = pixels.bytes[i + 2];
            const hi = @max(r, @max(g, b));
            const lo = @min(r, @min(g, b));
            if (hi - lo > 25) chromatic += 1;
            if (g > r + 25 and g > b + 25) green += 1;
            if (r > g + 25 and r > b + 25) red += 1;
            if (r > 160 and g > 120 and b + 30 < r) yellow += 1;
        }
        try t.expect(chromatic > 800);
        try t.expect(green > 150);
        try t.expect(red > 150);
        try t.expect(yellow > 150);
    }
}
