//! Frames on the display's beat (macOS, iOS): what scrolling gathers between
//! refreshes, how fast to ask the display link to run, and a log of when
//! frames ran (`NANOUI_FRAME_LOG=FILE`) to check a real scroll's pace.
const std = @import("std");
const builtin = @import("builtin");

/// How long the link keeps running after the last scroll event: a
/// trackpad's events come unevenly, and a link started cold misses a beat.
pub const linger: f64 = 0.15;

/// Scrolling gathered since the last frame: every event's delta, applied
/// at once by the next frame on the display link.
pub const Scroll = struct {
    dy: f32 = 0,
    until: f64 = 0,

    pub fn add(s: *Scroll, dy: f32, now: f64) void {
        s.dy += dy;
        s.until = now + linger;
    }

    /// What the frame applies: all of it, once.
    pub fn take(s: *Scroll) f32 {
        const d = s.dy;
        s.dy = 0;
        return d;
    }

    /// Still scrolling: keep the link running.
    pub fn active(s: Scroll, now: f64) bool {
        return now < s.until;
    }
};

/// `CAFrameRateRange`.
pub const Range = extern struct { minimum: f32, maximum: f32, preferred: f32 };

/// The pace to ask the link for: `fps` frames a second (a slow, steady
/// change), or, with 0, the screen's fastest (a ProMotion display's 120),
/// down to half of it when the system needs to save power. While a scroll
/// moves (`scrolling`) the floor is the screen's fastest too: a scroll at
/// half rate is the judder it was meant to avoid. 0 for a screen that
/// doesn't say leaves the system's default.
pub fn range(fps: f32, screen_max: f32, scrolling: bool) Range {
    if (fps > 0) return .{ .minimum = fps, .maximum = fps, .preferred = fps };
    if (screen_max <= 0) return .{ .minimum = 0, .maximum = 0, .preferred = 0 };
    return .{ .minimum = if (scrolling) screen_max else screen_max / 2, .maximum = screen_max, .preferred = screen_max };
}

/// Whether `frameIn` is due within ~1.5 display refreshes, so the display
/// link stays active instead of pausing and paying cold-start latency.
pub fn keepLinkForFrameIn(seconds: ?f32, refresh_s: f64) bool {
    const s = seconds orelse return false;
    return @as(f64, s) <= @max(refresh_s, 1.0 / 240.0) * 1.5;
}

/// The link's real interval, from its own target timestamps: a display the
/// system has throttled to 60 Hz is a 60 Hz one, whatever its maximum. The
/// shortest of the last four intervals: a missed tick lengthens one, a
/// change of rate all of them. A gap longer than 1/20 s (a paused link) is
/// not an interval.
pub const PeriodMeter = struct {
    last_target: f64 = 0,
    seen: [4]f64 = .{ 0, 0, 0, 0 },
    n: u8 = 0,
    i: u8 = 0,

    pub fn observe(m: *PeriodMeter, target: f64) void {
        if (m.last_target > 0) {
            const d = target - m.last_target;
            if (d > 1.0 / 250.0 and d < 1.0 / 20.0) {
                m.seen[m.i] = d;
                m.i = (m.i + 1) % 4;
                m.n = @min(4, m.n + 1);
            }
        }
        m.last_target = target;
    }

    /// The interval, or `fallback` before the link has ticked twice.
    pub fn period(m: PeriodMeter, fallback: f64) f64 {
        if (m.n == 0) return fallback;
        var p = m.seen[0];
        for (m.seen[1..m.n]) |d| p = @min(p, d);
        return p;
    }
};

/// What the display link's tick has to go on (`metalDisplayLinkNeedsUpdate`).
pub const TickIn = struct {
    full_pending: bool = false,
    frame_in_due: bool = false,
    /// `Glide.wants`: a scroll has a new position for this refresh.
    glide_wants: bool = false,
    animating: bool = false,
    geometry_changed: bool = false,
    retained_ready: bool = false,
    pending_sync: bool = false,
    time_driven: bool = false,
    drawable: bool = true,
};

pub const Tick = enum {
    /// Nothing to draw: let the pacing decide whether the link pauses.
    idle,
    /// Something to draw but nowhere to draw it (a window gone from the
    /// screen): the scroll lands at once and the pacing decides.
    no_drawable,
    /// Present the last scene again.
    retained,
    /// Build and present a frame.
    frame,
};

/// What the link's tick does.
pub fn tick(in: TickIn) Tick {
    const wanted = in.full_pending or in.frame_in_due or in.glide_wants or in.animating or in.geometry_changed;
    if (!wanted and !in.retained_ready and !in.pending_sync and !in.time_driven) return .idle;
    if (!in.drawable) return .no_drawable;
    if (!wanted and (in.retained_ready or (!in.pending_sync and in.time_driven))) return .retained;
    return .frame;
}

/// What keeps the link running after a frame (`Surface.updatePacing`).
pub const KeepIn = struct {
    resize_stepping: bool = false,
    animating: bool = false,
    hot_changed: bool = false,
    pointer_down: bool = false,
    /// A view reading the wheel itself scrolled within `linger`.
    wheel_view: bool = false,
    /// `Glide.active`.
    glide_active: bool = false,
    frame_in_soon: bool = false,
};

pub fn keepRunning(in: KeepIn) bool {
    return in.resize_stepping or in.animating or in.hot_changed or in.pointer_down or in.wheel_view or in.glide_active or in.frame_in_soon;
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// When each frame ran, one time in seconds a line, to the file
/// `NANOUI_FRAME_LOG` names: a scroll's intervals can be read afterwards.
pub const FrameLog = struct {
    file: ?std.Io.File = null,

    pub fn open() FrameLog {
        if (builtin.os.tag == .windows) return .{};
        const path = getenv("NANOUI_FRAME_LOG") orelse return .{};
        const io = std.Io.Threaded.global_single_threaded.io();
        const f = std.Io.Dir.cwd().createFile(io, std.mem.span(path), .{}) catch return .{};
        return .{ .file = f };
    }

    pub fn note(l: *FrameLog, now: f64) void {
        const f = l.file orelse return;
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d:.6}\n", .{now}) catch return;
        f.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), line) catch {};
    }

    pub fn close(l: *FrameLog) void {
        if (l.file) |f| f.close(std.Io.Threaded.global_single_threaded.io());
        l.file = null;
    }
};

test "scrolling between refreshes adds up, is applied once, and keeps the link a while" {
    var s: Scroll = .{};
    s.add(3, 10.0);
    s.add(-1, 10.004);
    s.add(4.5, 10.007);
    try std.testing.expect(s.active(10.1));
    try std.testing.expectEqual(@as(f32, 6.5), s.take());
    try std.testing.expectEqual(@as(f32, 0), s.take());
    try std.testing.expect(!s.active(10.007 + linger + 0.001));
}

test "the link asks for the screen's fastest, or a steady pace" {
    try std.testing.expectEqual(Range{ .minimum = 60, .maximum = 120, .preferred = 120 }, range(0, 120, false));
    try std.testing.expectEqual(Range{ .minimum = 2, .maximum = 2, .preferred = 2 }, range(2, 120, false));
    try std.testing.expectEqual(Range{ .minimum = 0, .maximum = 0, .preferred = 0 }, range(0, 0, false));
}

test "a scroll holds the screen's full rate, and the normal range returns after it" {
    const Glide = @import("scroll_glide.zig").Glide;
    var g: Glide = .{};
    const refresh = 1.0 / 120.0;
    var t: f64 = 1;
    for (0..30) |i| {
        g.event(.{ .dy = -4, .t = t - refresh, .phase = if (i == 0) .began else .changed });
        _ = g.beat(.{ .target = t + refresh, .now = t, .period = refresh }, .{});
        try std.testing.expectEqual(Range{ .minimum = 120, .maximum = 120, .preferred = 120 }, range(0, 120, g.active(t)));
        t += refresh;
    }
    const lift = t - refresh;
    g.event(.{ .dy = 0, .t = lift, .phase = .ended });
    // Through the linger the floor stays; then the normal range, and idle.
    var released: ?f64 = null;
    for (0..60) |_| {
        const b: @import("scroll_glide.zig").Beat = .{ .target = t + refresh, .now = t, .period = refresh };
        if (g.wants(b, .{})) _ = g.beat(b, .{});
        if (released == null and !g.active(t)) released = t;
        t += refresh;
    }
    try std.testing.expect(released.? - lift <= @import("scroll_glide.zig").linger + refresh);
    try std.testing.expectEqual(Range{ .minimum = 60, .maximum = 120, .preferred = 120 }, range(0, 120, g.active(t)));
    // A steady pace (a 24 fps clock) is not lifted by it.
    try std.testing.expectEqual(Range{ .minimum = 24, .maximum = 24, .preferred = 24 }, range(24, 120, true));
}

test "the link's period is read off its own ticks: 120 Hz, throttled to 60, a missed tick" {
    var m: PeriodMeter = .{};
    try std.testing.expectEqual(@as(f64, 1.0 / 120.0), m.period(1.0 / 120.0));
    var t: f64 = 1;
    for (0..8) |_| {
        m.observe(t);
        t += 1.0 / 120.0;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 120.0), m.period(1.0 / 120.0), 1e-9);
    // One missed tick doesn't halve it.
    t += 1.0 / 120.0;
    m.observe(t);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 120.0), m.period(1.0 / 120.0), 1e-9);
    // The system throttles the screen to 60 Hz: four ticks and it is 1/60,
    // though the screen's maximum (the old fallback) still says 1/120.
    for (0..5) |_| {
        t += 1.0 / 60.0;
        m.observe(t);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 60.0), m.period(1.0 / 120.0), 1e-9);
    // A pause is not an interval.
    t += 2;
    m.observe(t);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 60.0), m.period(1.0 / 120.0), 1e-9);
}

test "the link's tick: idle, retained, a frame, or no drawable" {
    try std.testing.expectEqual(Tick.idle, tick(.{}));
    try std.testing.expectEqual(Tick.frame, tick(.{ .glide_wants = true }));
    try std.testing.expectEqual(Tick.no_drawable, tick(.{ .glide_wants = true, .drawable = false }));
    try std.testing.expectEqual(Tick.retained, tick(.{ .retained_ready = true }));
    try std.testing.expectEqual(Tick.retained, tick(.{ .time_driven = true }));
    try std.testing.expectEqual(Tick.frame, tick(.{ .time_driven = true, .pending_sync = true }));
    try std.testing.expectEqual(Tick.frame, tick(.{ .full_pending = true, .retained_ready = true }));
}

/// A refresh of a synthetic display link around a `Glide`, through the same
/// decisions the macOS surface makes: the events routed (`scroll_glide.route`),
/// the tick (`tick`), the link kept running or let pause (`keepRunning`).
const LinkSim = struct {
    const sg = @import("scroll_glide.zig");
    g: sg.Glide = .{},
    running: bool = false,
    frames: usize = 0,
    quiet_since: ?f64 = null,

    fn send(l: *LinkSim, e: sg.Event, box: bool) void {
        switch (sg.route(e.dy, e.phase, box, false, l.g.active(e.t))) {
            .glide => {
                l.g.event(e);
                l.running = true;
            },
            .wheel_view, .none => {},
        }
    }

    fn refresh(l: *LinkSim, now: f64, period: f64) void {
        if (!l.running) return;
        const b: sg.Beat = .{ .target = now + period, .now = now, .period = period };
        switch (tick(.{ .glide_wants = l.g.wants(b, .{}) })) {
            .frame => {
                _ = l.g.beat(b, .{});
                l.frames += 1;
            },
            .no_drawable => _ = l.g.flush(),
            .idle, .retained => {},
        }
        l.running = keepRunning(.{ .glide_active = l.g.active(now) });
        if (!l.running and l.quiet_since == null) l.quiet_since = now;
    }
};

test "the link goes quiet after a scroll ends, and resting-finger events don't wake it" {
    const refresh = 1.0 / 120.0;
    const linger_s = @import("scroll_glide.zig").linger;
    for ([_]bool{ false, true }) |stationary| {
        var l: LinkSim = .{};
        var t: f64 = 1;
        for (0..40) |i| {
            l.send(.{ .dy = -5, .t = t - 0.003, .phase = if (i == 0) .began else .changed }, true);
            l.refresh(t, refresh);
            t += refresh;
        }
        const last = t - refresh - 0.003;
        // The finger rests on the pad: the system may keep sending
        // zero-delta stationary events, one a refresh, for a whole second.
        for (0..120) |_| {
            if (stationary) l.send(.{ .dy = 0, .t = t - 0.003, .phase = .changed }, false);
            l.refresh(t, refresh);
            t += refresh;
        }
        try std.testing.expect(!l.running);
        try std.testing.expect(l.quiet_since.? - last <= linger_s + 2 * refresh);
        try std.testing.expect(!l.g.active(t));
    }
}

test "a link with no drawable lands the scroll at once and is let pause" {
    const sg = @import("scroll_glide.zig");
    var g: sg.Glide = .{};
    g.event(.{ .dy = -5, .t = 1, .phase = .began });
    const b: sg.Beat = .{ .target = 1.02, .now = 1.01, .period = 1.0 / 120.0 };
    try std.testing.expectEqual(Tick.no_drawable, tick(.{ .glide_wants = g.wants(b, .{}), .drawable = false }));
    try std.testing.expectEqual(@as(f64, -5), g.flush().dy);
    try std.testing.expect(!g.wants(b, .{}));
    try std.testing.expect(!keepRunning(.{ .glide_active = g.active(1.2) }));
}

test "keepLinkForFrameIn keeps link running for immediate frames and pauses for idle waits" {
    try std.testing.expect(keepLinkForFrameIn(0, 1.0 / 120.0));
    try std.testing.expect(keepLinkForFrameIn(1.0 / 120.0, 1.0 / 120.0));
    try std.testing.expect(keepLinkForFrameIn(1.0 / 60.0, 1.0 / 60.0));
    try std.testing.expect(!keepLinkForFrameIn(1.0 / 24.0, 1.0 / 120.0));
    try std.testing.expect(!keepLinkForFrameIn(0.5, 1.0 / 120.0));
    try std.testing.expect(!keepLinkForFrameIn(null, 1.0 / 120.0));
}
