//! Pointer submenu "safe triangle" (menu-aim): a pure geometry helper.
//! Always on for nested desktop menus; tests may flip `enabled`.
//!
//! The triangle's apex is the pointer; the other vertices are the submenu's
//! near top and bottom corners. While the pointer stays inside the triangle
//! built from its *previous* position and is moving toward the submenu, the
//! open submenu is held so a diagonal path does not steal it. After a short
//! idle, or when the pointer moves away, hover switching resumes.
//!
//! Self-contained for now. When nanoui grows a matching API
//! (github.com/justrach/nanoui), Nano can switch to it without changing
//! the hold policy below. Do not bump the vendored nanoui pin for this.
const std = @import("std");
const ui = @import("nanoui").ui;

pub const Point = ui.Point;
pub const Rect = ui.Rect;

/// How long a still pointer keeps the hold before normal hover wins.
pub const default_idle_s: f64 = 0.300;
/// Extra room around the triangle, in points.
pub const default_padding: f32 = 4;

pub const trail_cap: usize = 24;

/// Always on in the app. Tests set this false to exercise the old steal path.
pub var enabled: bool = true;
/// Tests, or `NANO_MENU_AIM_DEBUG=1`. Never a user-facing setting.
pub var debug: bool = false;

pub fn debugOn() bool {
    if (debug) return true;
    const v = std.c.getenv("NANO_MENU_AIM_DEBUG") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

pub fn resetHook() void {
    enabled = true;
    debug = false;
}

pub fn options() Options {
    return .{};
}

pub const Options = struct {
    padding: f32 = default_padding,
    idle_s: f64 = default_idle_s,
};

pub const Triangle = struct {
    apex: Point,
    a: Point,
    b: Point,
};

pub const Hold = enum { hold, release };

pub const Tracker = struct {
    current: ?Point = null,
    prev: ?Point = null,
    last_move_s: f64 = 0,
    trail: [trail_cap]Point = undefined,
    trail_len: u8 = 0,
    trail_i: u8 = 0,

    pub fn reset(t: *Tracker) void {
        t.* = .{};
    }

    pub fn note(t: *Tracker, p: Point, time: f64) void {
        if (t.current) |cur| {
            t.prev = cur;
            if (dist2(cur, p) > 0.25) {
                t.last_move_s = time;
                t.pushTrail(p);
            }
        } else {
            t.last_move_s = time;
            t.pushTrail(p);
        }
        t.current = p;
    }

    pub fn previous(t: *const Tracker) ?Point {
        return t.prev;
    }

    fn pushTrail(t: *Tracker, p: Point) void {
        t.trail[t.trail_i] = p;
        t.trail_i = @intCast((@as(usize, t.trail_i) + 1) % trail_cap);
        if (t.trail_len < trail_cap) t.trail_len += 1;
    }

    /// Oldest to newest, copied into `out`.
    pub fn copyTrail(t: *const Tracker, out: *[trail_cap]Point) []Point {
        const n: usize = t.trail_len;
        if (n == 0) return out[0..0];
        if (n < trail_cap) {
            @memcpy(out[0..n], t.trail[0..n]);
            return out[0..n];
        }
        const start: usize = t.trail_i;
        for (0..trail_cap) |i| out[i] = t.trail[(start + i) % trail_cap];
        return out[0..trail_cap];
    }
};

/// Apex at `cursor`, the other two vertices on the submenu's near edge.
pub fn fromCursor(cursor: Point, submenu: Rect) Triangle {
    const right = submenu.x + submenu.w * 0.5 >= cursor.x;
    const near_x = if (right) submenu.x else submenu.x + submenu.w;
    return .{
        .apex = cursor,
        .a = .{ .x = near_x, .y = submenu.y },
        .b = .{ .x = near_x, .y = submenu.y + submenu.h },
    };
}

pub fn area2(tri: Triangle) f32 {
    return @abs(orient(tri.apex, tri.a, tri.b));
}

pub fn degenerate(tri: Triangle) bool {
    return area2(tri) < 1e-3;
}

/// Point-in-triangle, including the boundary, with `padding` around the
/// edges. Degenerate triangles fall back to a padded segment (or point).
pub fn contains(tri: Triangle, p: Point, padding: f32) bool {
    if (strictContains(tri, p)) return true;
    const pad = @max(0, padding);
    if (pad == 0) return false;
    if (degenerate(tri)) {
        const d_ab = distToSegment(p, tri.a, tri.b);
        const d_ap = distToSegment(p, tri.apex, tri.a);
        const d_bp = distToSegment(p, tri.apex, tri.b);
        return @min(d_ab, @min(d_ap, d_bp)) <= pad;
    }
    return distToSegment(p, tri.apex, tri.a) <= pad or
        distToSegment(p, tri.a, tri.b) <= pad or
        distToSegment(p, tri.b, tri.apex) <= pad;
}

fn strictContains(tri: Triangle, p: Point) bool {
    if (degenerate(tri)) return false;
    const ab = orient(tri.apex, tri.a, p);
    const bc = orient(tri.a, tri.b, p);
    const ca = orient(tri.b, tri.apex, p);
    const has_neg = ab < 0 or bc < 0 or ca < 0;
    const has_pos = ab > 0 or bc > 0 or ca > 0;
    return !(has_neg and has_pos);
}

/// Whether the step from `prev` to `now` points at the submenu's near edge.
pub fn movingToward(prev: Point, now: Point, submenu: Rect) bool {
    if (!isMoving(prev, now)) return false;
    const dest = aimPoint(now, submenu);
    const vx = now.x - prev.x;
    const vy = now.y - prev.y;
    const dx = dest.x - now.x;
    const dy = dest.y - now.y;
    return vx * dx + vy * dy > 0;
}

pub fn isMoving(a: Point, b: Point) bool {
    return dist2(a, b) > 0.25;
}

/// Keep the open submenu (`hold`) or let hover switching resume (`release`).
///
/// The hold tests the current pointer against the triangle from the
/// *previous* sample, so the visual triangle (apex at the cursor) can
/// update every frame without the cursor being inside by definition.
pub fn decide(
    opts: Options,
    cursor: Point,
    prev: ?Point,
    now_s: f64,
    last_move_s: f64,
    submenu: Rect,
    inside_submenu: bool,
) Hold {
    if (inside_submenu) return .release;
    const apex = prev orelse return .release;
    const tri = fromCursor(apex, submenu);
    if (!contains(tri, cursor, opts.padding)) return .release;
    if (now_s - last_move_s >= opts.idle_s) return .release;
    if (isMoving(apex, cursor) and !movingToward(apex, cursor, submenu)) return .release;
    return .hold;
}

pub fn paintDebug(cv: *ui.Canvas, tri: Triangle, trail: []const Point, show_triangle: bool) void {
    const grey: ui.Color = .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 0.9 };
    if (show_triangle) {
        var outline = [_]Point{ tri.apex, tri.a, tri.b, tri.apex };
        cv.polyline(&outline, .{ .width = 1.25, .color = grey });
    }
    for (trail) |p| {
        const h: f32 = 3.5;
        var sq = [_]Point{
            .{ .x = p.x - h, .y = p.y - h },
            .{ .x = p.x + h, .y = p.y - h },
            .{ .x = p.x + h, .y = p.y + h },
            .{ .x = p.x - h, .y = p.y + h },
            .{ .x = p.x - h, .y = p.y - h },
        };
        cv.polyline(&sq, .{ .width = 1, .color = grey });
    }
}

fn aimPoint(cursor: Point, submenu: Rect) Point {
    const right = submenu.x + submenu.w * 0.5 >= cursor.x;
    const near_x = if (right) submenu.x else submenu.x + submenu.w;
    const y = std.math.clamp(cursor.y, submenu.y, submenu.y + submenu.h);
    return .{ .x = near_x, .y = y };
}

fn orient(a: Point, b: Point, c: Point) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

fn dist2(a: Point, b: Point) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return dx * dx + dy * dy;
}

fn distToSegment(p: Point, a: Point, b: Point) f32 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const len2 = vx * vx + vy * vy;
    if (len2 < 1e-12) return @sqrt(dist2(p, a));
    const t = std.math.clamp(((p.x - a.x) * vx + (p.y - a.y) * vy) / len2, 0, 1);
    return @sqrt(dist2(p, .{ .x = a.x + vx * t, .y = a.y + vy * t }));
}

const testing = std.testing;

const share_sub: Rect = .{ .x = 200, .y = 10, .w = 120, .h = 180 };
const aim_opts: Options = .{ .padding = 4, .idle_s = 0.300 };

test "menu-aim point in triangle includes the interior, vertices and padding" {
    const tri = fromCursor(.{ .x = 40, .y = 40 }, share_sub);
    try testing.expect(contains(tri, .{ .x = 40, .y = 40 }, 0));
    try testing.expect(contains(tri, .{ .x = 200, .y = 10 }, 0));
    try testing.expect(contains(tri, .{ .x = 200, .y = 190 }, 0));
    try testing.expect(contains(tri, .{ .x = 120, .y = 80 }, 0));
    try testing.expect(!contains(tri, .{ .x = 40, .y = 160 }, 0));
    try testing.expect(contains(tri, .{ .x = 36, .y = 40 }, 4));
    try testing.expect(!contains(tri, .{ .x = 20, .y = 40 }, 4));
}

test "menu-aim degenerate triangles reject the interior and keep a padded segment" {
    const flat: Triangle = .{
        .apex = .{ .x = 10, .y = 10 },
        .a = .{ .x = 20, .y = 10 },
        .b = .{ .x = 30, .y = 10 },
    };
    try testing.expect(degenerate(flat));
    try testing.expect(!contains(flat, .{ .x = 20, .y = 40 }, 0));
    try testing.expect(contains(flat, .{ .x = 20, .y = 12 }, 4));
    const point: Triangle = .{
        .apex = .{ .x = 5, .y = 5 },
        .a = .{ .x = 5, .y = 5 },
        .b = .{ .x = 5, .y = 5 },
    };
    try testing.expect(contains(point, .{ .x = 6, .y = 5 }, 2));
    try testing.expect(!contains(point, .{ .x = 20, .y = 5 }, 2));
}

test "menu-aim a submenu on either side of its parent uses the near edge" {
    const right = fromCursor(.{ .x = 40, .y = 50 }, share_sub);
    try testing.expectEqual(@as(f32, 200), right.a.x);
    try testing.expectEqual(@as(f32, 200), right.b.x);
    const left_sub: Rect = .{ .x = 10, .y = 10, .w = 80, .h = 100 };
    const left = fromCursor(.{ .x = 200, .y = 40 }, left_sub);
    try testing.expectEqual(@as(f32, 90), left.a.x);
    try testing.expectEqual(@as(f32, 90), left.b.x);
    try testing.expect(contains(left, .{ .x = 140, .y = 50 }, 0));
    try testing.expect(!contains(left, .{ .x = 200, .y = 120 }, 0));
}

test "menu-aim diagonal toward the submenu holds; a dive down or away releases" {
    const share: Point = .{ .x = 40, .y = 24 };
    const over_move_to: Point = .{ .x = 110, .y = 70 };
    const dive: Point = .{ .x = 42, .y = 90 };
    const away: Point = .{ .x = 20, .y = 40 };
    try testing.expectEqual(Hold.hold, decide(aim_opts, over_move_to, share, 1.0, 0.95, share_sub, false));
    try testing.expectEqual(Hold.release, decide(aim_opts, dive, share, 1.0, 0.95, share_sub, false));
    try testing.expectEqual(Hold.release, decide(aim_opts, away, share, 1.0, 0.95, share_sub, false));
    try testing.expectEqual(Hold.release, decide(aim_opts, over_move_to, share, 1.0, 0.95, share_sub, true));
}

test "menu-aim idling in the triangle falls through after the configured delay" {
    const share: Point = .{ .x = 40, .y = 24 };
    const over_move_to: Point = .{ .x = 110, .y = 70 };
    try testing.expectEqual(Hold.hold, decide(aim_opts, over_move_to, share, 1.00, 0.85, share_sub, false));
    try testing.expectEqual(Hold.release, decide(aim_opts, over_move_to, share, 1.20, 0.85, share_sub, false));
    const fast: Options = .{ .padding = 4, .idle_s = 0.050 };
    try testing.expectEqual(Hold.release, decide(fast, over_move_to, share, 1.00, 0.94, share_sub, false));
}

test "menu-aim the first sample and a missing previous point do not hold" {
    const cursor: Point = .{ .x = 110, .y = 70 };
    try testing.expectEqual(Hold.release, decide(aim_opts, cursor, null, 1.0, 1.0, share_sub, false));
}

test "menu-aim moving away from a left-hand submenu cancels the hold" {
    const left_sub: Rect = .{ .x = 10, .y = 10, .w = 80, .h = 100 };
    const from: Point = .{ .x = 160, .y = 50 };
    const toward: Point = .{ .x = 130, .y = 55 };
    const away: Point = .{ .x = 190, .y = 50 };
    try testing.expectEqual(Hold.hold, decide(aim_opts, toward, from, 1.0, 0.95, left_sub, false));
    try testing.expectEqual(Hold.release, decide(aim_opts, away, from, 1.0, 0.95, left_sub, false));
}

test "menu-aim is on unless a test flips the internal hook" {
    try testing.expect(enabled);
    try testing.expect(!debug);
    try testing.expect(!debugOn());
    enabled = false;
    debug = true;
    try testing.expect(!enabled);
    try testing.expect(debugOn());
    resetHook();
    try testing.expect(enabled);
    try testing.expect(!debug);
}

test "menu-aim the tracker records movement, idle time and a ring of trail points" {
    var t: Tracker = .{};
    t.note(.{ .x = 10, .y = 10 }, 0.10);
    t.note(.{ .x = 20, .y = 12 }, 0.12);
    t.note(.{ .x = 20.1, .y = 12.1 }, 0.40);
    try testing.expect(t.previous() != null);
    try testing.expect(t.last_move_s < 0.40);
    var buf: [trail_cap]Point = undefined;
    try testing.expect(t.copyTrail(&buf).len >= 1);
    t.reset();
    try testing.expect(t.previous() == null);
    try testing.expectEqual(@as(u8, 0), t.trail_len);
}
