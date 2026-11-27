//! A refresh's glide applied to a real scroll box (`scroll.glideFrame`,
//! `scroll.glideLaidOut`), through the Tester: the paths the macOS surface's
//! link frames take, with synthetic trackpad events.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const sg = ui.scroll_glide;

const refresh: f64 = 1.0 / 120.0;

const Scene = struct {
    id: u64 = 0,
    rows: usize = 10,
    follow: bool = false,

    fn view(s: *Scene, c: *ui.Context) void {
        s.id = ui.scrollBox(c, .{ .width = .fill, .height = .{ .px = 100 }, .follow_end = s.follow }, "box");
        defer ui.end(c);
        for (0..s.rows) |i| {
            _ = c.open(.{ .width = .fill, .height = .{ .px = 30 } }, c.print("row{d}", .{i}));
            c.end();
        }
    }
};

/// The tick of refresh `k`: its own time and the presentation a refresh on.
fn beat(k: usize) sg.Beat {
    const now = 1 + @as(f64, @floatFromInt(k)) * refresh;
    return .{ .target = now + refresh, .now = now, .period = refresh };
}

/// A momentum delta that crosses the bottom, with a frame drawn between
/// its event and the link's refresh (which clears `input.scroll_phase`):
/// whether the box still gets its one bounded impact.
fn bottomImpact(carry_phase: bool) !f32 {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.settle(0.1);
    // 10 rows of 30 in 100: 200 to scroll. Near the bottom.
    try t.ctx.scroll.put(t.ctx.gpa, s.id, 190);
    t.ctx.input.mouse = .{ .x = 50, .y = 50 };
    t.frame();
    var g: sg.Glide = .{};
    // The event, as `scrollWheel` delivers it.
    t.ctx.input.precise = true;
    t.ctx.input.scroll_phase = .momentum;
    t.ctx.scroll_holding = false;
    g.event(.{ .dy = -30, .t = 1, .phase = .momentum });
    // A frame off the beat (a pointer move, say): the link's job is left.
    t.frame();
    try testing.expectEqual(ui.ScrollPhase.none, t.ctx.input.scroll_phase);
    if (carry_phase) {
        _ = ui.glideFrame(&t.ctx, &g, beat(1));
    } else {
        // Before: the delta alone, in whatever phase the input has now.
        t.ctx.applyScrollStep(@floatCast(g.beat(beat(1), t.ctx.glideRoom()).dy));
    }
    return @abs(t.ctx.overscroll.get(s.id) orelse 0);
}

test "a momentum delta keeps its phase across a frame drawn before its refresh: the bottom's impact still comes" {
    const before = try bottomImpact(false);
    const after = try bottomImpact(true);
    std.debug.print("\nmomentum across an off-beat frame: impact {d:.2} points without the phase carried, {d:.2} with\n", .{ before, after });
    try testing.expectEqual(@as(f32, 0), before);
    try testing.expect(after > 1);
}

test "content that shrinks under a lead: the box keeps no lead, a settle doesn't move it, the end isn't followed again" {
    var s: Scene = .{ .rows = 40, .follow = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.dt = 1.0 / 120.0;
    t.settle(0.2);
    t.ctx.input.mouse = .{ .x = 50, .y = 50 };
    t.frame();
    // 40 rows of 30 in 100: 1100 to scroll, following the end.
    try testing.expectEqual(@as(f32, 1100), t.ctx.scroll.get(s.id).?);
    var g: sg.Glide = .{};
    var k: usize = 0;
    // Up the content, 10 points a refresh; the last refresh has no event, so
    // it is extrapolated: a lead of a refresh's travel.
    while (k < 14) : (k += 1) {
        const b = beat(k);
        if (k < 13) g.event(.{ .dy = 10, .t = b.now - 0.003, .phase = if (k == 0) .began else .changed });
        const f = ui.glideFrame(&t.ctx, &g, b);
        t.frame();
        ui.glideLaidOut(&t.ctx, &g, f);
    }
    try testing.expect(g.shown > g.real);
    const before_shrink = t.ctx.scroll.get(s.id).?;
    // The content shrinks by more than the lead: 30 rows, 800 to scroll.
    s.rows = 30;
    {
        const b = beat(k);
        const f = ui.glideFrame(&t.ctx, &g, b);
        t.frame();
        ui.glideLaidOut(&t.ctx, &g, f);
        k += 1;
    }
    try testing.expect(before_shrink > 800);
    try testing.expectEqual(@as(f32, 800), t.ctx.scroll.get(s.id).?);
    // No lead is left to hold the next delta back: it moves the box at once.
    {
        const b = beat(k);
        g.event(.{ .dy = 10, .t = b.now - 0.003, .phase = .changed });
        const f = ui.glideFrame(&t.ctx, &g, b);
        t.frame();
        ui.glideLaidOut(&t.ctx, &g, f);
        k += 1;
    }
    try testing.expectApproxEqAbs(@as(f32, 790), t.ctx.scroll.get(s.id).?, 0.01);
    // The gesture stops: the settle moves nothing, and the end stays unfollowed.
    const rest = t.ctx.scroll.get(s.id).?;
    for (0..60) |_| {
        const b = beat(k);
        if (g.wants(b, t.ctx.glideRoom())) {
            const f = ui.glideFrame(&t.ctx, &g, b);
            t.frame();
            ui.glideLaidOut(&t.ctx, &g, f);
        }
        k += 1;
    }
    try testing.expect(t.ctx.scroll.get(s.id).? <= rest + 0.01);
    try testing.expect(t.ctx.scroll.get(s.id).? >= rest - 10 - 0.01);
    try testing.expectEqual(false, t.ctx.scroll_follow.get(s.id).?);
}
