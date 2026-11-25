//! Synthetic renderer regressions: actual equation image geometry, not a
//! Unicode formatter's output. Every case failed against the v187 renderer.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const testing = std.testing;
const md = @import("markdown.zig");
const pal: md.Palette = .{ .code = .hex(0xff0000), .code_bg = .hex(0x111111), .link = .hex(0x0000ff) };

test "native math boundaries retain source and protect currency code and unfinished input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "Energy $E=mc^2$ and \\(\\frac{a+b}{c}\\).";
    const in = md.parse(a, raw, pal)[0].paragraph;
    try testing.expectEqualStrings(raw, in.text);
    try testing.expectEqual(@as(usize, 2), in.maths.len);
    try testing.expectEqualStrings("\\frac{a+b}{c}", in.maths[1].source);
    for ([_][]const u8{ "Pay $5 and $10", "Pay $5.00 and $10.00", "$$$x$$$", "`$x_i$`", "\\(x_i", "$x_i", "$x_{a}_b", "$$x_{a}_b", "[literal $x$](https://example.com)" }) |source| {
        const text = md.parse(a, source, pal)[0].paragraph;
        try testing.expectEqual(@as(usize, 0), text.maths.len);
        if (source[0] != '`' and source[0] != '[') try testing.expectEqualStrings(source, text.text);
    }
    const price = md.parse(a, "Pay $5 ($x^2$)", pal)[0].paragraph;
    try testing.expectEqual(@as(usize, 1), price.maths.len);
    try testing.expectEqualStrings("x^2", price.maths[0].source);
    const display = "\\[\n\\begin{matrix}a&b\\\\c&d\\end{matrix}\n\\]";
    const block = md.parse(a, display, pal)[0].math;
    try testing.expectEqualStrings(display, block.text);
    try testing.expect(block.maths[0].display);
}

test "native math UI unsupported equations remain literal without losing backslashes" {
    theme.registerFonts();
    var f = Fixture{ .source = "$\\unsupported{x}$" };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{});
    defer t.deinit();
    t.settle(3);
    try testing.expect(t.hasText(f.source));
    for (t.ctx.nodes.items) |node| try testing.expect(node.content != .image);
}

test "native math UI mixed prose selection copies original equation source continuously" {
    theme.registerFonts();
    const source = "Before $\\frac{x_i}{y}$ after.";
    var a: @import("app.zig").App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.openChat("math", null);
    a.settings.set(.transcript_compact_mode, false);
    const data = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"m","role":"assistant","status":"complete","parts":[{"kind":"text","id":"p","text":"Before $\\frac{x_i}{y}$ after."}]}]}
    , .{});
    defer data.deinit();
    try a.transcript.apply(data.value);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1100, .height = 700 });
    defer t.deinit();
    t.settle(3);
    var id: u64 = 0;
    for (t.ctx.nodes.items) |node| if (node.content == .text and std.mem.eql(u8, node.content.text.str, source)) {
        id = node.id;
        break;
    };
    try testing.expect(id != 0);
    t.ctx.selection.anchor = .{ .id = id, .at = 0 };
    t.ctx.selection.focus = .{ .id = id, .at = source.len };
    t.ctx.selection.moved = true;
    t.frame();
    try testing.expectEqualStrings(source, t.ctx.selection.text.items);
    _ = t.shortcut(.{ .key = 'c', .cmd = true });
    try testing.expectEqualStrings(source, t.clipboard.items);
}

test "native math UI Unicode prose and long links wrap without escaping narrow paragraphs" {
    theme.registerFonts();
    var f = Fixture{ .source = "数学の文章は幅に合わせて折り返されます数学の文章は幅に合わせて折り返されます $\\alpha_i^2$ [averylongsyntheticlabelthatmustwrapacrosslines](https://example.com)." };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 250, .height = 650 });
    defer t.deinit();
    t.settle(4);
    for (t.ctx.nodes.items) |node| {
        if (node.content != .text and node.content != .image) continue;
        const r = t.ctx.rects.get(node.id) orelse continue;
        try testing.expect(r.x >= 19 and r.x + r.w <= 231);
    }
}

test "native math UI inline baseline and narrow wrapping keep equations inside paragraph" {
    theme.registerFonts();
    var f = Fixture{ .source = "Alpha $\\frac{x}{y}$ beta gamma delta epsilon $x_i^n$." };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 250, .height = 500 });
    defer t.deinit();
    t.settle(3);
    var first_image: ?ui.Rect = null;
    var first_prose: ?ui.Rect = null;
    for (t.ctx.nodes.items) |node| {
        const r = t.ctx.rects.get(node.id) orelse continue;
        if (node.content == .image) {
            try testing.expect(r.x >= 19 and r.x + r.w <= 231);
            if (first_image == null) first_image = r;
        }
        if (node.content == .text and std.mem.eql(u8, node.content.text.str, "Alpha ")) first_prose = r;
    }
    try testing.expect(first_image != null and first_prose != null);
    // The fraction rises above the prose but shares the line, not a separate block.
    try testing.expect(first_image.?.y < first_prose.?.y + first_prose.?.h);
    try testing.expect(first_image.?.y + first_image.?.h > first_prose.?.y);
}

const Fixture = struct {
    source: []const u8,
    owner: ?*@import("app.zig").App = null,
    copy_feedback: @import("view_kit.zig").CopyFeedback = .{},
    max_width: ?f32 = null,
    fn view(f: *Fixture, c: *ui.Context) void {
        const page = ui.div(c).column().wFull().p(20);
        if (f.max_width) |w| _ = page.maxW(w).clip();
        defer page.end();
        if (f.owner) |a| @import("view_markdown.zig").withLinks(c, theme.builtin(false), f.source, a, "math") else @import("view_markdown.zig").markdown(c, theme.builtin(false), f.source, &f.copy_feedback);
    }
};

fn geometry(source: []const u8, shot: ?[]const u8) !ui.Rect {
    theme.registerFonts();
    var f = Fixture{ .source = source };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 620, .height = 400 });
    defer t.deinit();
    t.settle(3);
    if (shot) |name| if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
        var buf: [2048]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
        try t.screenshot(path);
    };
    for (t.ctx.nodes.items) |node| {
        if (node.content == .image) return t.ctx.rects.get(node.id) orelse error.MissingEquationRect;
    }
    return error.NativeEquationMissing;
}

test "native math UI renders all supported LaTeX regression rows in a table" {
    theme.registerFonts();
    var f = Fixture{ .source =
        \\| Case | Formula |
        \\|---|---|
        \\| Boxed integral | \(\displaystyle\iint_T \boxed{u}\,g(u,v)\,du\,dv\) |
        \\| Binary spacing | $a\,+b$ |
        \\| Nested style | $\frac{\displaystyle\frac{u}{v}}{w}$ |
        \\| Operator placement | $\int\limits_{u}^{v}$ and $\sum\nolimits_{i}^{n}$ |
    };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 760, .height = 425 });
    defer t.deinit();
    t.settle(3);
    if (std.c.getenv("NANO_MATH_COVERAGE_SNAP")) |path| try t.screenshot(std.mem.span(path));
    var equations: usize = 0;
    for (t.ctx.nodes.items) |node| {
        if (node.content == .image) equations += 1;
    }
    try testing.expectEqual(@as(usize, 5), equations);
}

test "native math UI paragraph links beside equations still activate their destination" {
    theme.registerFonts();
    var a: @import("app.zig").App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.openChat("math", null);
    var f = Fixture{ .source = "Before $\\frac{x}{y}$ [docs](https://example.com/math) after.", .owner = &a };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 620 });
    defer t.deinit();
    t.settle(4);
    var label: ?ui.Rect = null;
    for (t.ctx.nodes.items) |node| if (node.content == .text and std.mem.startsWith(u8, node.content.text.str, "docs")) {
        label = t.ctx.rects.get(node.id);
        break;
    };
    try testing.expect(label != null);
    t.click(label.?.x + 8, label.?.y + label.?.h / 2);
    t.settle(1);
    try testing.expect(a.panels.pending_browser != null);
    try testing.expectEqualStrings("https://example.com/math", a.panels.pending_browser.?.url);
}

test "native math UI fraction has stacked numerator rule denominator geometry" {
    const frac = try geometry("$$\\frac{a+b}{c}$$", "math-fraction");
    const flat = try geometry("$$a+b/c$$", null);
    try testing.expect(frac.h > flat.h * 1.3);
}

test "native math UI scripts are positioned above and below a baseline" {
    const base = try geometry("$$x$$", null);
    const scripts = try geometry("$$x_i^{n+1}$$", "math-scripts");
    try testing.expect(scripts.h > base.h * 1.3);
    try testing.expect(scripts.w > base.w);
}

test "native math UI radicals enclose their stacked radicand" {
    const base = try geometry("$$\\frac{a}{b}$$", null);
    const root = try geometry("$$\\sqrt[3]{\\frac{a}{b}}$$", "math-root");
    try testing.expect(root.h > base.h);
    try testing.expect(root.w > base.w);
}

test "native math UI matrices retain rows and stretchy delimiters" {
    const one = try geometry("$$\\begin{bmatrix}a&b\\end{bmatrix}$$", null);
    const two = try geometry("$$\\begin{bmatrix}a&b\\\\c&d\\end{bmatrix}$$", "math-matrix");
    try testing.expect(two.h > one.h * 1.3);
}

test "native math UI underbrace annotation and display limits extend both sides" {
    const base = try geometry("$$a+b$$", null);
    const brace = try geometry("$$\\underbrace{a+b}_{n}$$", "math-underbrace");
    try testing.expect(brace.h > base.h * 1.3);
    const sum = try geometry("$$\\sum$$", null);
    const limits = try geometry("$$\\sum_{i=1}^{n}$$", "math-limits");
    try testing.expect(limits.h > sum.h * 1.3);
}

test "inline math prose and list boundaries stay within column on demand-driven frames (#2)" {
    theme.registerFonts();
    const cases = [_][]const u8{
        "The demonstration processor applies its transformation to the combined score q = a+b, **not each label independently**.",
        "The demonstration processor applies its transformation to the combined score \\(q=a+b\\), **not each label independently**.",
        "- The demonstration processor applies its transformation to the combined score q = a+b, **not each label independently**.",
        "- The demonstration processor applies its transformation to the combined score \\(q=a+b\\), **not each label independently**.",
    };
    for (cases) |source| {
        var f = Fixture{ .source = source, .max_width = 740 };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 1600, .height = 220 });
        defer t.deinit();
        var scheduled_frames: usize = 0;
        while (scheduled_frames < 8 and (t.ctx.animating or t.ctx.frame_in != null)) : (scheduled_frames += 1) t.frame();
        for (t.ctx.nodes.items) |node| {
            if (node.content != .text and node.content != .image) continue;
            if (node.content == .text and node.content.text.color.a == 0) continue;
            const r = t.ctx.rects.get(node.id) orelse continue;
            try testing.expect(r.x >= 19 and r.x + r.w <= 721);
        }
    }
}

test "inline math list prose reflows cleanly after shrinking container width (#2)" {
    theme.registerFonts();
    var f = Fixture{ .source = "- The demonstration processor applies its transformation to the combined score \\(q=a+b\\), **not each label independently**.", .max_width = 740 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 1600, .height = 260 });
    defer t.deinit();
    for (0..6) |_| t.frame();
    t.resize(420, 260);
    var scheduled_frames: usize = 0;
    while (scheduled_frames < 8 and (t.ctx.animating or t.ctx.frame_in != null)) : (scheduled_frames += 1) t.frame();
    for (t.ctx.nodes.items) |node| {
        if (node.content != .text and node.content != .image) continue;
        if (node.content == .text and node.content.text.color.a == 0) continue;
        const r = t.ctx.rects.get(node.id) orelse continue;
        try testing.expect(r.x >= 19 and r.x + r.w <= 401);
    }
}

test "rejected table math fallback wraps inside its cell without covering neighbor (#11)" {
    theme.registerFonts();
    var wide_buf: std.ArrayList(u8) = .empty;
    defer wide_buf.deinit(testing.allocator);
    try wide_buf.appendSlice(testing.allocator, "| Formula | Neighbor |\n|---|---|\n| $");
    try wide_buf.appendNTimes(testing.allocator, 'W', 420);
    try wide_buf.appendSlice(testing.allocator, "$ | SYNTHETIC_RIGHT |\n");

    var unsup_buf: std.ArrayList(u8) = .empty;
    defer unsup_buf.deinit(testing.allocator);
    try unsup_buf.appendSlice(testing.allocator, "| Formula | Neighbor |\n|---|---|\n| $\\unsupported{");
    for (0..72) |i| {
        if (i > 0) try unsup_buf.append(testing.allocator, '+');
        try unsup_buf.appendSlice(testing.allocator, "SYNTHETIC");
    }
    try unsup_buf.appendSlice(testing.allocator, "}$ | SYNTHETIC_RIGHT |\n");

    for ([_][]const u8{ wide_buf.items, unsup_buf.items }) |src| {
        var f = Fixture{ .source = src };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 520, .height = 600 });
        defer t.deinit();
        var scheduled_frames: usize = 0;
        while (scheduled_frames < 8 and (t.ctx.animating or t.ctx.frame_in != null)) : (scheduled_frames += 1) t.frame();
        const neighbor = t.findText("SYNTHETIC_RIGHT") orelse return error.MissingNeighborCell;
        var saw_fallback = false;
        for (t.ctx.nodes.items) |node| {
            if (node.content != .text) continue;
            if (node.content.text.color.a == 0) continue;
            const s = node.content.text.str;
            if (std.mem.indexOf(u8, s, "WWWW") == null and std.mem.indexOf(u8, s, "unsupported") == null and std.mem.indexOf(u8, s, "SYNTHETIC+") == null) continue;
            saw_fallback = true;
            const r = t.ctx.rects.get(node.id) orelse continue;
            try testing.expect(r.x + r.w <= neighbor.x - 10 + 0.5);
        }
        try testing.expect(saw_fallback);
    }
}

test "sibling display equations have distinct selection ids and copy independently (#893)" {
    theme.registerFonts();
    const src =
        \\First synthetic equation:
        \\
        \\$$\alpha + \beta = \gamma$$
        \\
        \\Middle synthetic prose.
        \\
        \\$$\sum_{k=1}^{n} k^2 = \frac{n(n+1)(2n+1)}{6}$$
        \\
        \\Final synthetic prose.
        \\
        \\$$E = m c^2 + p^2 c^2$$
    ;
    var f = Fixture{ .source = src };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 640, .height = 520 });
    defer t.deinit();
    var scheduled_frames: usize = 0;
    while (scheduled_frames < 8 and (t.ctx.animating or t.ctx.frame_in != null)) : (scheduled_frames += 1) t.frame();

    var eq_ids: [3]u64 = .{ 0, 0, 0 };
    var eq_rects: [3]ui.Rect = undefined;
    var found: usize = 0;
    for (t.ctx.nodes.items) |node| {
        if (node.content != .text) continue;
        if (node.content.text.color.a != 0) continue;
        const s = node.content.text.str;
        if (std.mem.indexOf(u8, s, "\\alpha") != null) {
            eq_ids[0] = node.id;
            eq_rects[0] = node.rect;
            found += 1;
        } else if (std.mem.indexOf(u8, s, "\\sum") != null) {
            eq_ids[1] = node.id;
            eq_rects[1] = node.rect;
            found += 1;
        } else if (std.mem.indexOf(u8, s, "m c^2") != null) {
            eq_ids[2] = node.id;
            eq_rects[2] = node.rect;
            found += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), found);

    // Select only the first display equation.
    const r0 = eq_rects[0];
    t.drag(r0.x + 2, r0.y + r0.h / 2, r0.x + r0.w - 2, r0.y + r0.h / 2);
    t.frame();
    if (std.c.getenv("NANO_MATH_SEL_SNAP")) |raw| {
        try t.screenshot(std.mem.span(raw));
    }

    try testing.expect(eq_ids[0] != eq_ids[1]);
    try testing.expect(eq_ids[1] != eq_ids[2]);
    try testing.expect(eq_ids[0] != eq_ids[2]);

    try testing.expect(std.mem.indexOf(u8, t.ctx.selection.text.items, "\\alpha") != null);
    try testing.expect(std.mem.indexOf(u8, t.ctx.selection.text.items, "\\sum") == null);
    try testing.expect(std.mem.indexOf(u8, t.ctx.selection.text.items, "m c^2") == null);

    // Select across all three equations and verify document order and source.
    const r2 = eq_rects[2];
    t.drag(r0.x + 2, r0.y + r0.h / 2, r2.x + r2.w - 2, r2.y + r2.h / 2);
    t.frame();
    const p0 = std.mem.indexOf(u8, t.ctx.selection.text.items, "\\alpha") orelse return error.MissingFirstEquation;
    const p1 = std.mem.indexOf(u8, t.ctx.selection.text.items, "\\sum") orelse return error.MissingSecondEquation;
    const p2 = std.mem.indexOf(u8, t.ctx.selection.text.items, "m c^2") orelse return error.MissingThirdEquation;
    try testing.expect(p0 < p1 and p1 < p2);
}

test "native math UI inline \\displaystyle renders at display sizing and copies original source (#91)" {
    theme.registerFonts();
    const source = "Value: $\\displaystyle \\frac{p+q}{r}$";
    var a: @import("app.zig").App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.openChat("math", null);
    a.settings.set(.transcript_compact_mode, false);
    const data = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"m","role":"assistant","status":"complete","parts":[{"kind":"text","id":"p","text":"Value: $\\displaystyle \\frac{p+q}{r}$"}]}]}
    , .{});
    defer data.deinit();
    try a.transcript.apply(data.value);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1100, .height = 700 });
    defer t.deinit();
    t.settle(3);
    if (std.c.getenv("NANO_MATH_STYLE_SNAP")) |raw| {
        try t.screenshot(std.mem.span(raw));
    }

    const math = @import("native_math.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const styled_eq = math.layout(arena.allocator(), "\\displaystyle \\frac{p+q}{r}", false, 15, .black) orelse return error.MissingStyledEquation;
    const display_eq = math.layout(arena.allocator(), "\\frac{p+q}{r}", true, 15, .black) orelse return error.MissingDisplayEquation;
    try testing.expectApproxEqAbs(display_eq.height, styled_eq.height, 0.01);

    const styled = try geometry("Value: $\\displaystyle \\frac{p+q}{r}$", null);
    const plain = try geometry("Value: $\\frac{p+q}{r}$", null);
    try testing.expect(styled.h > plain.h * 1.15);
    try testing.expectApproxEqAbs(styled_eq.height, styled.h, 0.25);

    var copy_id: u64 = 0;
    for (t.ctx.nodes.items) |node| {
        if (node.content == .text and std.mem.eql(u8, node.content.text.str, source)) {
            copy_id = node.id;
            break;
        }
    }
    try testing.expect(copy_id != 0);
    t.ctx.selection.anchor = .{ .id = copy_id, .at = 0 };
    t.ctx.selection.focus = .{ .id = copy_id, .at = source.len };
    t.ctx.selection.moved = true;
    t.frame();
    try testing.expectEqualStrings(source, t.ctx.selection.text.items);
}

test "native math parses multiple display equations on one source line (#154)" {
    theme.registerFonts();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{
        "\\[a^2\\] and \\[b^2\\]",
        "$$a^2$$ and $$b^2$$",
        "Example: \\[a^2\\] and \\[b^2\\]",
        "Example: $$a^2$$ and $$b^2$$",
    }) |src| {
        const blocks = md.parse(a, src, pal);
        try testing.expectEqual(@as(usize, 1), blocks.len);
        try testing.expect(blocks[0] == .paragraph);
        const p = blocks[0].paragraph;
        try testing.expectEqual(@as(usize, 2), p.maths.len);
        try testing.expectEqualStrings("a^2", p.maths[0].source);
        try testing.expect(p.maths[0].display);
        try testing.expectEqualStrings("b^2", p.maths[1].source);
        try testing.expect(p.maths[1].display);
        try testing.expect(std.mem.indexOf(u8, p.text, " and ") != null);
    }

    for ([_][]const u8{ "$$a^2$$", "\\[a^2\\]" }) |single| {
        const blocks = md.parse(a, single, pal);
        try testing.expectEqual(@as(usize, 1), blocks.len);
        try testing.expect(blocks[0] == .math);
        try testing.expectEqualStrings("a^2", blocks[0].math.maths[0].source);
        try testing.expect(blocks[0].math.maths[0].display);
    }

    const multiline = "\\[\n\\begin{matrix}a&b\\\\c&d\\end{matrix}\n\\]";
    const mblocks = md.parse(a, multiline, pal);
    try testing.expectEqual(@as(usize, 1), mblocks.len);
    try testing.expect(mblocks[0] == .math);
    try testing.expect(mblocks[0].math.maths[0].display);

    for ([_][]const u8{ "\\[a^2\\] and \\[b^2\\]", "$$a^2$$ and $$b^2$$" }) |src| {
        var f = Fixture{ .source = src };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 620, .height = 240 });
        defer t.deinit();
        t.settle(3);
        var images: usize = 0;
        for (t.ctx.nodes.items) |node| {
            if (node.content == .image) images += 1;
        }
        try testing.expectEqual(@as(usize, 2), images);
    }
}

test "native math recovers at later complete equation after unmatched opener (#153)" {
    theme.registerFonts();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{
        "Unfinished \\(draft; then $x^2$.",
        "Unfinished $$draft; then $x^2$.",
        "Unfinished \\[draft; then $x^2$.",
        "Unfinished $draft_1; then \\(x^2\\).",
    }) |src| {
        const p = md.parse(a, src, pal)[0].paragraph;
        try testing.expectEqual(@as(usize, 1), p.maths.len);
        try testing.expectEqualStrings("x^2", p.maths[0].source);
        try testing.expectEqualStrings(src, p.text);
    }

    for ([_][]const u8{
        "Unfinished \\(draft; then $x^2$ and **bold**.",
        "Unfinished $$draft; then **bold** and $x^2$.",
    }) |src| {
        const p = md.parse(a, src, pal)[0].paragraph;
        try testing.expectEqual(@as(usize, 1), p.maths.len);
        try testing.expectEqualStrings("x^2", p.maths[0].source);
        var saw_bold = false;
        for (p.spans) |sp| {
            if (sp.weight == .semibold and std.mem.eql(u8, p.text[sp.start..sp.end], "bold")) {
                saw_bold = true;
                break;
            }
        }
        try testing.expect(saw_bold);
    }

    for ([_][]const u8{
        "\\(x_i",
        "$$x_{a}_b",
        "$x_{a}_b",
        "Unfinished \\(draft",
        "Unfinished \\(draft; then `$x^2$`.",
    }) |incomplete| {
        const p = md.parse(a, incomplete, pal)[0].paragraph;
        try testing.expectEqual(@as(usize, 0), p.maths.len);
        if (std.mem.indexOfScalar(u8, incomplete, '`') == null) {
            try testing.expectEqualStrings(incomplete, p.text);
        }
    }

    var f = Fixture{ .source = "Unfinished \\(draft" };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 620, .height = 240 });
    defer t.deinit();
    t.settle(3);
    var before_images: usize = 0;
    for (t.ctx.nodes.items) |node| {
        if (node.content == .image) before_images += 1;
    }
    try testing.expectEqual(@as(usize, 0), before_images);
    try testing.expect(t.hasText("Unfinished \\(draft"));

    f.source = "Unfinished \\(draft; then $x^2$.";
    t.settle(3);
    var after_images: usize = 0;
    for (t.ctx.nodes.items) |node| {
        if (node.content == .image) after_images += 1;
    }
    try testing.expectEqual(@as(usize, 1), after_images);
}

test "native math prevents dollar price from stealing later inline equation opener (#155)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{
        "Pay $9, then ($x^2$).",
        "Pay $9.99, then ($x^2$).",
        "Pay $1,200, then [$x^2$].",
        "Pay $9, then \"$x^2$\".",
        "Pay $9 (not $10) for ($x^2$).",
    }) |src| {
        const p = md.parse(a, src, pal)[0].paragraph;
        try testing.expectEqual(@as(usize, 1), p.maths.len);
        try testing.expectEqualStrings("x^2", p.maths[0].source);
        try testing.expectEqualStrings(src, p.text);
    }

    const streaming = md.parse(a, "Pay $9, then ($x^2", pal)[0].paragraph;
    try testing.expectEqual(@as(usize, 0), streaming.maths.len);

    const code_price = md.parse(a, "`$9, then ($x^2$)`", pal)[0].paragraph;
    try testing.expectEqual(@as(usize, 0), code_price.maths.len);

    for ([_]struct { src: []const u8, eq: []const u8 }{
        .{ .src = "$5$", .eq = "5" },
        .{ .src = "$1, 2$", .eq = "1, 2" },
        .{ .src = "$2x + 3$", .eq = "2x + 3" },
        .{ .src = "$12.50 - 3$", .eq = "12.50 - 3" },
    }) |case| {
        const p = md.parse(a, case.src, pal)[0].paragraph;
        try testing.expectEqual(@as(usize, 1), p.maths.len);
        try testing.expectEqualStrings(case.eq, p.maths[0].source);
    }

    const numeric_then_math = md.parse(a, "$1 + 2$, then ($x^2$)", pal)[0].paragraph;
    try testing.expectEqual(@as(usize, 2), numeric_then_math.maths.len);
    try testing.expectEqualStrings("1 + 2", numeric_then_math.maths[0].source);
    try testing.expectEqualStrings("x^2", numeric_then_math.maths[1].source);
}

test "native math UI delimiter regressions render cleanly (#153 #154 #155)" {
    theme.registerFonts();
    var f = Fixture{ .source =
        \\**#153 Unmatched opener:** Unfinished \(draft; then $x^2$.
        \\
        \\Unfinished $$draft; then $x^2$.
        \\
        \\**#154 Same-line display:**
        \\
        \\\[a^2\] and \[b^2\]
        \\
        \\$$a^2$$ and $$b^2$$
        \\
        \\**#155 Currency before equation:** Pay $9, then ($x^2$).
    };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 560, .height = 410 });
    defer t.deinit();
    t.settle(3);
    if (std.c.getenv("NANO_MATH_DELIM_SNAP")) |raw| {
        try t.screenshot(std.mem.span(raw));
    }

    var equations: usize = 0;
    var saw_price = false;
    var saw_raw_eq = false;
    for (t.ctx.nodes.items) |node| {
        if (node.content == .image) equations += 1;
        if (node.content == .text and node.content.text.color.a != 0) {
            if (std.mem.indexOf(u8, node.content.text.str, "$9") != null) saw_price = true;
            if (std.mem.indexOf(u8, node.content.text.str, "x^2$") != null) saw_raw_eq = true;
        }
    }
    try testing.expectEqual(@as(usize, 7), equations);
    try testing.expect(saw_price);
    try testing.expect(!saw_raw_eq);
}
