//! A scroll's position on each display refresh, from the deltas the system
//! delivered (macOS). No display, no context: timestamped deltas with their
//! phases go in (`event`), a refresh goes in (`beat`: its presentation time,
//! the time the tick runs, and the link's interval), and what that refresh
//! moves comes out.
//!
//! Frames used to follow the events. A trackpad's events are not locked to
//! the display: on about one refresh in seven none has arrived, and the next
//! one brings two. Each event's delta was applied by the next frame, so that
//! refresh showed the last position again and the next moved twice as far.
//!
//! Rules:
//!
//! - Mid-gesture, each refresh moves one refresh's step at the recent
//!   velocity `v` (the events' pace over the last ~8 refreshes), but never
//!   behind the events' sum `real` and never more than one refresh's worth
//!   ahead of it: `clamp(shown + v * dt, real, real + v * period)`. A steady
//!   stream lands on `real` every refresh; a refresh with no event moves on
//!   by one step; the refresh that brings two events lands on `real` again.
//!   A second refresh without an event adds nothing. The part ahead of
//!   `real` (the lead) never crosses the box's edges (`Room`), so it can
//!   neither clamp nor start a rubber band nor reach a followed end.
//! - Nothing a settle does moves against the direction of travel. While the
//!   events catch up the position holds. When the gesture stops (no event
//!   for 2.5 refreshes with the finger down, a lift with no momentum after
//!   `lift_wait_beats`, momentum's end, a new touch, the linger) the lead is
//!   kept: `real` is brought up to what is shown. A trackpad's scroll is
//!   relative, so ending a fraction of a refresh's travel further than the
//!   deltas asked is invisible; a step back is not. The final position is
//!   the sum of the deltas to within that lead: one refresh's travel at the
//!   last pace for a dead stop, a fraction of a point for a fling that
//!   decays to rest.
//! - A delta against the direction of travel is a reversal: `real` is shown
//!   at once and the velocity starts over.
//! - A mouse wheel (not precise): each notch eases over `wheel_ease_s` with
//!   DESIGN.md's ease-out-quint, a notch during it restarting the ease from
//!   where it is toward the new total. Reduced motion jumps, as before.
//!
//! Event times and the refresh's `now` are the same clock (the media time
//! when each is handled); the presentation time is only for how far to move.
//!
//! A scroll's first event is shown on the first refresh after it, as the
//! old path's was: that path built the frame at once but had no drawable to
//! present until the link's next refresh, so aligning the build to the beat
//! adds no latency (`first event is shown on the first refresh after it`).
const std = @import("std");
/// DESIGN.md's motion curve (`motion/catalog.zig` `ease_out_quint`).
const ease_out_quint: @import("motion/easing.zig").Easing = .{ .bezier = .{ 0.22, 1, 0.36, 1 } };

/// How long a gesture without an event still holds the display's full
/// rate (as `pacing.linger`), and when an unfinished one settles.
pub const linger: f64 = 0.15;
/// After a lift, how long to wait for the system's momentum before
/// settling, in refreshes.
pub const lift_wait_beats: f64 = 4;
/// The velocity window, in refreshes.
pub const window_beats: f64 = 8;
/// How much of an extrapolated lead a refresh with new events keeps.
pub const lead_keep: f64 = 0.75;
/// Without an event for this many refreshes the gesture has stopped: no
/// frame is expected (`moving`), and the finger-down gesture settles.
pub const moving_beats: f64 = 2.5;
/// A wheel notch's ease (DESIGN.md: fast start, gentle landing, short).
pub const wheel_ease_s: f64 = 0.14;
/// Extrapolation stops this far short of an edge: reaching the end is the
/// events' to do (a transcript re-follows its end at `max - 1`).
pub const edge_margin: f64 = 2;

/// The system's phase for an event (NSEvent `phase` and `momentumPhase`;
/// a cancelled phase is its `ended`).
pub const Phase = enum { none, began, changed, ended, momentum, momentum_ended };

pub const Event = struct {
    /// The system's delta (positive: content moves down, toward the top).
    dy: f64,
    /// When it was handled (CACurrentMediaTime): `Beat.now`'s clock.
    t: f64,
    phase: Phase = .none,
    /// A trackpad's (or Magic Mouse's) precise deltas; false: a wheel's notches.
    precise: bool = true,
    reduce_motion: bool = false,
};

/// Where a scroll event goes (`surface_events.scrollWheel`): a scrolling
/// box's delta to the glide; a view that reads the wheel itself to its
/// summed path (`pacing.Scroll`); nowhere. A zero delta reaches the glide
/// only when it ends something (a lift, momentum's end): the system's
/// stationary events while a finger rests carry nothing, and letting them in
/// kept the link drawing at full rate for as long as they came.
pub const Route = enum { glide, wheel_view, none };

pub fn route(dy: f64, phase: Phase, box: bool, wheel_view: bool, glide_active: bool) Route {
    if (dy != 0 and box) return .glide;
    if (dy == 0 and glide_active and (phase == .ended or phase == .momentum_ended)) return .glide;
    if (wheel_view) return .wheel_view;
    return .none;
}

/// A display refresh, as the link's tick sees it.
pub const Beat = struct {
    /// When it will be presented (the link's target timestamp): how far to move.
    target: f64,
    /// When the tick runs (CACurrentMediaTime), the events' clock.
    now: f64,
    /// The link's interval (`pacing.PeriodMeter`).
    period: f64,
};

/// How far an extrapolated step may go in the box under the pointer
/// (`scroll.glideRoom`): `up` for positive deltas, `down` for negative ones.
pub const Room = struct {
    box: u64 = 0,
    up: f64 = std.math.inf(f64),
    down: f64 = std.math.inf(f64),

    /// A box at an edge, in a rubber band, or no box: nothing extrapolates.
    pub fn none(box: u64) Room {
        return .{ .box = box, .up = 0, .down = 0 };
    }
};

/// Why a refresh drew its scroll.
pub const Source = enum {
    none,
    /// New events were shown.
    event,
    /// No event came; the position was extrapolated.
    glide,
    /// A wheel notch's ease.
    wheel,
    /// The gesture ended and the events' part not yet shown was shown.
    settle,
};

pub const Step = struct {
    /// What this refresh applies, in the system's delta direction.
    dy: f64 = 0,
    source: Source = .none,
    /// The events it carries were momentum's: `applyScroll`'s one bounded
    /// impact at an edge reads the phase, which a frame in between cleared.
    momentum: bool = false,

    /// The refresh has something to draw for the scroll.
    pub fn draws(s: Step) bool {
        return s.source != .none;
    }
};

/// What a frame log records about the scroll (`Context.scroll_pace`).
pub const Report = struct {
    source: Source = .none,
    /// Refreshes on which a moving scroll drew nothing, since launch.
    skipped_total: u64 = 0,
    /// Refreshes drawn by extrapolation, since launch.
    glide_total: u64 = 0,
};

const Mode = enum { idle, precise, wheel };
const Sample = struct { t: f64, real: f64 };

fn sign(x: f64) f64 {
    return if (x > 0) 1 else if (x < 0) -1 else 0;
}

pub const Glide = struct {
    mode: Mode = .idle,
    /// The sum of the system's deltas this gesture (with any lead a settle
    /// kept), and what refreshes showed.
    real: f64 = 0,
    shown: f64 = 0,
    /// Delivered since the last refresh.
    fresh: f64 = 0,
    has_fresh: bool = false,
    /// When the last event was handled (`Beat.now`'s clock).
    last_event: f64 = 0,
    lifted: bool = false,
    ended: bool = false,
    /// The last event was momentum's.
    momentum: bool = false,
    period: f64 = 1.0 / 120.0,
    /// Velocity, points a second, as of the last refresh that showed events.
    v: f64 = 0,
    /// The direction of travel: the sign of the last delta shown.
    dir: f64 = 0,
    /// That refresh's presentation time.
    shown_real_at: f64 = 0,
    last_beat: f64 = 0,
    box: u64 = 0,
    samples: [6]Sample = undefined,
    count: u8 = 0,
    wheel_from: f64 = 0,
    wheel_start: f64 = 0,
    wheel_instant: bool = false,

    pub fn event(g: *Glide, e: Event) void {
        // The last gesture is over (its lead kept): this one starts afresh.
        if (!g.active(e.t)) g.reset();
        const kind: Mode = if (e.precise) .precise else .wheel;
        if (g.mode != kind) {
            // Idle, or another device took over: start its history afresh.
            if (g.mode == .precise) g.keepLead();
            g.mode = kind;
            g.restart();
        }
        switch (e.phase) {
            .began => {
                // A new touch (one that stops a fling, say) keeps what was shown.
                g.keepLead();
                g.restart();
            },
            .none, .changed, .momentum => {
                g.lifted = false;
                g.ended = false;
            },
            .ended => g.lifted = true,
            .momentum_ended => g.ended = true,
        }
        g.momentum = e.phase == .momentum or e.phase == .momentum_ended;
        g.real += e.dy;
        g.fresh += e.dy;
        g.has_fresh = true;
        g.last_event = e.t;
        if (kind == .wheel) g.wheel_instant = e.reduce_motion;
    }

    fn restart(g: *Glide) void {
        g.count = 0;
        g.v = 0;
        g.lifted = false;
        g.ended = false;
    }

    /// What was shown ahead of the events, in the direction of travel, is
    /// kept: `real` comes up to it (the events not yet shown still to add).
    /// A settle, a box the pointer left, an offset the layout moved.
    pub fn keepLead(g: *Glide) void {
        const base = g.real - g.fresh;
        if (g.dir != 0 and (g.shown - base) * g.dir > 0) g.real = g.shown + g.fresh;
    }

    /// The gesture has stopped at `now`: no more extrapolation.
    fn stopped(g: *const Glide, now: f64) bool {
        if (g.ended or now - g.last_event >= linger) return true;
        if (g.lifted) return now - g.last_event > lift_wait_beats * g.period;
        return !g.has_fresh and now - g.last_event > moving_beats * g.period;
    }

    /// A refresh: what it moves. Called once for each frame drawn; a
    /// refresh that draws nothing needn't call it (`wants`), as the rule
    /// depends on time, not on being called.
    pub fn beat(g: *Glide, b: Beat, room: Room) Step {
        if (b.period > 0) g.period = b.period;
        const t = b.target;
        if (g.mode == .idle) {
            g.has_fresh = false;
            g.fresh = 0;
            return .{};
        }
        // The pointer is over another box: what extrapolation showed early
        // stays with the box it moved, and isn't taken back from this one.
        if (room.box != g.box) {
            if (g.box != 0 and g.mode == .precise) g.keepLead();
            g.box = room.box;
        }
        const fresh = g.has_fresh;
        const reversed = fresh and g.mode == .precise and g.dir != 0 and g.fresh * g.dir < 0;
        if (reversed) {
            // Shown at once, and the old direction's velocity goes.
            g.count = 0;
            g.v = 0;
        }
        if (fresh and g.mode == .wheel) {
            // A notch: ease from what is on screen, as if it began a refresh ago.
            g.wheel_from = g.shown;
            g.wheel_start = if (g.last_beat > 0 and t - g.last_beat < 2 * g.period) g.last_beat else t - g.period;
        }
        const stop = g.mode == .precise and !reversed and g.stopped(b.now);
        if (stop) g.keepLead();
        const to = g.target(b, room, reversed or stop);
        const dy = to - g.shown;
        g.shown = to;
        if (fresh) {
            g.record(t);
            g.v = g.velocity();
            g.shown_real_at = t;
            if (g.fresh != 0) g.dir = sign(g.fresh);
            g.fresh = 0;
            g.has_fresh = false;
        }
        g.last_beat = t;
        const source: Source = if (fresh)
            (if (g.mode == .wheel) .wheel else .event)
        else if (dy == 0)
            .none
        else if (g.mode == .wheel)
            .wheel
        else if (to == g.real)
            .settle
        else
            .glide;
        const momentum = g.momentum and fresh;
        if (!g.active(b.now)) g.reset();
        return .{ .dy = dy, .source = source, .momentum = momentum };
    }

    fn target(g: *const Glide, b: Beat, room: Room, settled: bool) f64 {
        const t = b.target;
        if (g.mode == .wheel) {
            if (g.wheel_instant) return g.real;
            const p = (t - g.wheel_start) / wheel_ease_s;
            if (p >= 1) return g.real;
            const e: f64 = ease_out_quint.sample(@floatCast(std.math.clamp(p, 0, 1)))[0];
            return g.wheel_from + (g.real - g.wheel_from) * e;
        }
        // A reversal, or a stop (its lead already kept): the events' sum.
        if (settled) return g.real;
        var to = g.real;
        if (!g.lifted and g.v != 0 and g.v * g.dir > 0) {
            // A refresh's step at the recent pace, but never behind the
            // events and never more than a refresh's worth ahead of them.
            const step = g.v * std.math.clamp(t - g.last_beat, 0, g.period);
            const ahead = g.shown + step - g.real;
            const most = g.v * g.period;
            var lead = if (g.v > 0) std.math.clamp(ahead, 0, most) else std.math.clamp(ahead, most, 0);
            // While events keep coming the lead shrinks, so a velocity read a
            // little high can't creep up to the bound and stall there.
            if (g.has_fresh) lead *= lead_keep;
            // Only the extrapolated part is bounded: the events' own part
            // goes where the system sent it, rubber band included.
            const owed = g.real - g.shown;
            if (lead > 0) lead = @min(lead, @max(0, room.up - @max(owed, 0)));
            if (lead < 0) lead = -@min(-lead, @max(0, room.down + @min(owed, 0)));
            to += lead;
        }
        // Ahead of the events in the direction of travel: hold, don't step
        // back. (And rounding is not a step.)
        if ((to - g.shown) * g.dir < 0 or @abs(to - g.shown) < 1e-6) return g.shown;
        return to;
    }

    fn record(g: *Glide, t: f64) void {
        if (g.count == g.samples.len) {
            std.mem.copyForwards(Sample, g.samples[0 .. g.samples.len - 1], g.samples[1..]);
            g.count -= 1;
        }
        g.samples[g.count] = .{ .t = t, .real = g.real };
        g.count += 1;
    }

    fn velocity(g: *const Glide) f64 {
        if (g.count < 2) return 0;
        const last = g.samples[g.count - 1];
        const prev = g.samples[g.count - 2];
        if (last.t - prev.t < 1e-4) return 0;
        // Sparse events (a slow drag) are not a pace to extrapolate.
        if (last.t - prev.t > moving_beats * g.period) return 0;
        var old = prev;
        var i: usize = g.count - 2;
        while (i > 0) {
            i -= 1;
            if (last.t - g.samples[i].t > window_beats * g.period) break;
            old = g.samples[i];
        }
        return (last.real - old.real) / (last.t - old.t);
    }

    /// Whether the refresh `b` would move the scroll or show new events:
    /// the display link's tick draws when it does.
    pub fn wants(g: *const Glide, b: Beat, room: Room) bool {
        if (g.mode == .idle) return false;
        var copy = g.*;
        return copy.beat(b, room).draws();
    }

    /// The scroll is in motion at `now`: the next refresh is expected to
    /// show a new position. A refresh that shows none is a skipped one.
    pub fn moving(g: *const Glide, now: f64) bool {
        return switch (g.mode) {
            .idle => false,
            .wheel => g.shown != g.real,
            .precise => !g.ended and g.v != 0 and (g.has_fresh or now - g.last_event <= moving_beats * g.period),
        };
    }

    /// Still scrolling at `now`: hold the display link at full rate. A lead
    /// shown ahead of the events is not something still to show: a stopped
    /// gesture with one is over, whether or not a refresh was drawn to say so.
    pub fn active(g: *const Glide, now: f64) bool {
        if (g.mode == .idle) return false;
        if (g.has_fresh or now - g.last_event < linger) return true;
        return switch (g.mode) {
            .idle => false,
            .wheel => g.shown != g.real,
            .precise => if (g.dir == 0) g.shown != g.real else (g.real - g.shown) * g.dir > 0,
        };
    }

    /// Everything delivered, at once, keeping what was shown ahead (a
    /// hidden window, or a link with no drawable to draw into).
    pub fn flush(g: *Glide) Step {
        if (g.mode == .precise) g.keepLead();
        const dy = g.real - g.shown;
        const had = g.has_fresh;
        const momentum = g.momentum and had;
        g.reset();
        return .{ .dy = dy, .source = if (had) .event else if (dy != 0) .settle else .none, .momentum = momentum };
    }

    fn reset(g: *Glide) void {
        const p = g.period;
        g.* = .{ .period = p };
    }
};

// Tests: a synthetic display at 120 Hz and synthetic trackpad and wheel streams.

const testing = std.testing;
const old_rule = @import("pacing.zig").Scroll;
const hz: f64 = 120;
const refresh: f64 = 1.0 / hz;

/// The refresh presented at `t`: its tick runs a refresh earlier.
fn at(t: f64) Beat {
    return .{ .target = t, .now = t - refresh, .period = refresh };
}

/// One box, scrolled the way `scroll.applyScroll` scrolls one that isn't
/// held: `offset -= dy`, clamped to [0, max].
const Box = struct {
    offset: f64,
    max: f64,

    fn room(b: Box) Room {
        return .{ .box = 1, .up = @max(0, b.offset - edge_margin), .down = @max(0, b.max - b.offset - edge_margin) };
    }

    fn apply(b: *Box, dy: f64) void {
        b.offset = std.math.clamp(b.offset - dy, 0, b.max);
    }
};

/// A steady trackpad stream: one event a refresh, handled 3 ms before the
/// refresh's tick, except that every seventh is late and arrives with the
/// next one (the pattern frame logs show: no event on one refresh in seven,
/// two on the next). It stops dead after the last.
fn steadyStream(buf: []Event, dy: f64) []Event {
    for (buf, 0..) |*e, i| {
        const k: f64 = @floatFromInt(i);
        const late: f64 = if (i % 7 == 6) refresh else 0;
        e.* = .{ .dy = dy, .t = 1 + k * refresh - 0.003 + late, .phase = if (i == 0) .began else .changed };
    }
    return buf;
}

/// What each refresh shows, under the old rule (each refresh applies what
/// arrived since the last, `pacing.Scroll`) and under `Glide`.
const Run = struct {
    steps: [320]f64 = undefined,
    drawn: [320]bool = undefined,
    n: usize = 0,
    /// The refreshes the stream spans; after them, a quiet half second.
    end: usize = 0,
    sum: f64 = 0,
    box: Box = .{ .offset = 5000, .max = 10_000 },
    glide_extrapolated_past_edge: bool = false,
    /// The glide's pace at the end of the stream (points a refresh).
    last_pace: f64 = 0,

    fn push(r: *Run, dy: f64, drawn: bool) void {
        r.steps[r.n] = dy;
        r.drawn[r.n] = drawn;
        r.n += 1;
        r.sum += dy;
    }

    /// Refreshes `first..` with no frame (no new position).
    fn missing(r: *const Run, first: usize) usize {
        var m: usize = 0;
        for (r.drawn[first..r.end]) |d| m += @intFromBool(!d);
        return m;
    }

    /// Steps against `dir`, anywhere in the run (the stream's and the settle's).
    fn backward(r: *const Run, dir: f64) usize {
        var m: usize = 0;
        for (r.steps[0..r.n]) |s| m += @intFromBool(s * dir < 0);
        return m;
    }

    /// The steps' standard deviation, `first..last`.
    fn spread(r: *const Run, first: usize, last: usize) f64 {
        const n: f64 = @floatFromInt(last - first);
        var mean: f64 = 0;
        for (r.steps[first..last]) |s| mean += s / n;
        var v: f64 = 0;
        for (r.steps[first..last]) |s| v += (s - mean) * (s - mean) / n;
        return @sqrt(v);
    }

    /// The largest over the smallest step magnitude, `first..last`.
    fn unevenness(r: *const Run, first: usize, last: usize) f64 {
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = 0;
        for (r.steps[first..last]) |s| {
            lo = @min(lo, @abs(s));
            hi = @max(hi, @abs(s));
        }
        return if (lo == 0) std.math.inf(f64) else hi / lo;
    }
};

fn runOld(events: []const Event, beats: usize, start: f64) Run {
    var r: Run = .{};
    r.end = beats;
    var s: old_rule = .{};
    var next: usize = 0;
    for (0..beats + 60) |i| {
        const b = at(start + @as(f64, @floatFromInt(i)) * refresh);
        var fresh = false;
        while (next < events.len and events[next].t < b.now) : (next += 1) {
            s.add(@floatCast(events[next].dy), events[next].t);
            fresh = true;
        }
        const dy: f64 = s.take();
        r.box.apply(dy);
        r.push(dy, fresh);
    }
    return r;
}

fn runGlide(events: []const Event, beats: usize, start: f64, box: Box) Run {
    var r: Run = .{ .box = box };
    r.end = beats;
    var g: Glide = .{};
    var next: usize = 0;
    for (0..beats + 60) |i| {
        const b = at(start + @as(f64, @floatFromInt(i)) * refresh);
        while (next < events.len and events[next].t < b.now) : (next += 1) g.event(events[next]);
        if (i == beats - 1) r.last_pace = @abs(g.v) * refresh;
        const room = r.box.room();
        if (!g.wants(b, room)) {
            r.push(0, false);
            continue;
        }
        const step = g.beat(b, room);
        if (step.source == .glide) {
            const after = r.box.offset - step.dy;
            if (after < edge_margin - 1e-9 or after > r.box.max - edge_margin + 1e-9) r.glide_extrapolated_past_edge = true;
        }
        r.box.apply(step.dy);
        r.push(step.dy, true);
    }
    return r;
}

test "a scroll draws on every refresh while events miss one refresh in seven" {
    var buf: [140]Event = undefined;
    const events = steadyStream(&buf, -4);
    // The refreshes from the first event's to the last's.
    const beats = events.len + 1;
    const start = 1 + refresh;
    const old = runOld(events, beats, start);
    const new = runGlide(events, beats, start, .{ .offset = 5000, .max = 10_000 });
    const old_missing = old.missing(1);
    const new_missing = new.missing(1);
    std.debug.print("\nscroll pacing, synthetic 120 Hz stream: old rule {d}/{d} refreshes with no new position, glide {d}/{d}; steps max/min old {d:.2} glide {d:.2}\n", .{ old_missing, beats - 1, new_missing, beats - 1, old.unevenness(8, beats - 1), new.unevenness(8, beats - 1) });
    // The old rule misses about one refresh in seven; the glide none.
    try testing.expect(old_missing * 8 >= beats - 1);
    try testing.expectEqual(@as(usize, 0), new_missing);
    // Even steps: no repeated frame followed by a double step.
    try testing.expect(old.unevenness(8, beats - 1) == std.math.inf(f64));
    try testing.expect(new.unevenness(8, beats - 1) <= 1.05);
    try testing.expectEqual(@as(f64, -4 * 140), old.sum);
    // It stops dead: no step back, and it ends within one refresh's travel
    // (4 points) of the deltas' sum, on the far side.
    try testing.expectEqual(@as(usize, 0), new.backward(-1));
    std.debug.print("stopped dead: ended {d:.2} points past the deltas' sum, no step back\n", .{-4 * 140 - new.sum});
    try testing.expect(new.sum <= -4 * 140 and new.sum >= -4 * 140 - 4);
}

test "a 3000 pt/s stream that stops dead: the settle keeps the lead, never a step back" {
    // 25 points a refresh, every seventh event late; then nothing.
    var buf: [90]Event = undefined;
    const events = steadyStream(&buf, 25);
    const beats = events.len + 1;
    const new = runGlide(events, beats, 1 + refresh, .{ .offset = 9000, .max = 10_000 });
    const sum: f64 = 25 * 90;
    std.debug.print("\n3000 pt/s dead stop: ended {d:.2} points past the deltas' sum (last pace {d:.2} a refresh), steps against travel {d}\n", .{ new.sum - sum, new.last_pace, new.backward(1) });
    try testing.expectEqual(@as(usize, 0), new.backward(1));
    try testing.expect(new.sum >= sum);
    try testing.expect(new.sum - sum <= new.last_pace + 1e-9);
    try testing.expectEqual(@as(usize, 0), new.missing(1));
}

test "events jittered across the tick (0, 1 or 2 a refresh) are spread evenly" {
    // One event a refresh, each up to 40% of a refresh either side of the
    // tick: some refreshes get none, the next two, and runs of 0, 1, 2.
    var buf: [200]Event = undefined;
    var prng = std.Random.DefaultPrng.init(0x5c4011);
    const rand = prng.random();
    for (&buf, 0..) |*e, i| {
        const k: f64 = @floatFromInt(i);
        const jitter = (rand.float(f64) * 2 - 1) * 0.4 * refresh;
        e.* = .{ .dy = 3.5, .t = 1 + k * refresh + jitter, .phase = if (i == 0) .began else .changed };
    }
    const beats = buf.len + 1;
    const old = runOld(&buf, beats, 1 + refresh);
    const new = runGlide(&buf, beats, 1 + refresh, .{ .offset = 5000, .max = 10_000 });
    std.debug.print("\njittered stream: old rule {d}/{d} refreshes with no new position, glide {d}/{d}; step spread (sd, points) old {d:.2} glide {d:.2}\n", .{ old.missing(8), beats - 8, new.missing(8), beats - 8, old.spread(8, beats - 1), new.spread(8, beats - 1) });
    try testing.expect(old.missing(8) * 20 >= beats - 8);
    try testing.expectEqual(@as(usize, 0), new.missing(8));
    try testing.expectEqual(@as(f64, 3.5 * 200), old.sum);
    try testing.expectEqual(@as(usize, 0), new.backward(1));
    try testing.expect(new.sum >= 3.5 * 200 and new.sum - 3.5 * 200 <= new.last_pace + 1e-9);
    // At least twice as even as the old rule (a generous ratio).
    try testing.expect(new.spread(8, beats - 1) * 2 < old.spread(8, beats - 1));
}

test "the first event is shown on the first refresh after it" {
    var g: Glide = .{};
    g.event(.{ .dy = -6, .t = 1.0, .phase = .began });
    // The tick for the refresh presented at 1.0 + refresh runs at ~1.0.
    const s = g.beat(at(1.0 + 2 * refresh), .{});
    try testing.expectEqual(@as(f64, -6), s.dy);
    try testing.expectEqual(Source.event, s.source);
    // As the old rule: the same refresh.
    var o: old_rule = .{};
    o.add(-6, 1.0);
    try testing.expectEqual(@as(f32, -6), o.take());
}

test "extrapolation, and the lead a settle keeps, stay 2 points inside the content's edges" {
    var buf: [60]Event = undefined;
    // Toward the top (positive deltas), from 100 points down: the events
    // themselves reach the top; the glide never goes past them there.
    const events = steadyStream(&buf, 4);
    const new = runGlide(events, events.len + 1, 1 + refresh, .{ .offset = 100, .max = 10_000 });
    try testing.expect(!new.glide_extrapolated_past_edge);
    try testing.expectEqual(@as(f64, 0), new.box.offset);
    // And toward the bottom.
    const down = steadyStream(&buf, -4);
    const new_down = runGlide(down, down.len + 1, 1 + refresh, .{ .offset = 9900, .max = 10_000 });
    try testing.expect(!new_down.glide_extrapolated_past_edge);
    try testing.expectEqual(@as(f64, 10_000), new_down.box.offset);
    // A stop just short of the bottom: the kept lead ends 2 points inside it,
    // short of where a transcript follows its end again (`max - 1`).
    const short = steadyStream(&buf, -4);
    const new_short = runGlide(short, short.len + 1, 1 + refresh, .{ .offset = 10_000 - 4 * 60 - 3, .max = 10_000 });
    try testing.expect(!new_short.glide_extrapolated_past_edge);
    try testing.expect(new_short.box.offset <= 10_000 - edge_margin);
    try testing.expect(new_short.box.offset >= 10_000 - 3);
}

test "nothing moves after momentum ends; a fling that decays to rest ends within half a point of the sum" {
    var g: Glide = .{};
    var t: f64 = 1;
    var sum: f64 = 0;
    var shown: f64 = 0;
    // A finger's stroke, a lift, a decaying momentum, its end.
    var i: usize = 0;
    var dy: f64 = -8;
    while (i < 60) : (i += 1) {
        const phase: Phase = if (i == 0) .began else if (i < 20) .changed else if (i == 20) .ended else if (i < 59) .momentum else .momentum_ended;
        if (i >= 20) dy *= 0.93;
        // Skip one event in seven.
        if (i % 7 != 6 or i == 59) {
            g.event(.{ .dy = dy, .t = t - refresh - 0.003, .phase = phase });
            sum += dy;
        }
        const s = g.beat(at(t), .{});
        try testing.expect(s.dy <= 0);
        shown += s.dy;
        t += refresh;
    }
    try testing.expect(@abs(shown - sum) < 0.5);
    for (0..240) |_| {
        try testing.expect(!g.wants(at(t), .{}));
        const s = g.beat(at(t), .{});
        try testing.expectEqual(@as(f64, 0), s.dy);
        t += refresh;
    }
    try testing.expect(!g.active(t));
}

test "a direction reversal is shown within one refresh" {
    var g: Glide = .{};
    var t: f64 = 1;
    for (0..12) |i| {
        if (i != 9) g.event(.{ .dy = -6, .t = t - refresh - 0.003, .phase = if (i == 0) .began else .changed });
        _ = g.beat(at(t), .{});
        t += refresh;
    }
    // Refresh 9 had no event: it was extrapolated ahead of the events.
    const before = g.shown;
    g.event(.{ .dy = 5, .t = t - refresh - 0.003, .phase = .changed });
    const s = g.beat(at(t), .{});
    try testing.expect(s.dy > 0);
    try testing.expectEqual(g.real, g.shown);
    try testing.expect(g.shown > before);
    // And no extrapolation in the old direction afterwards.
    t += refresh;
    try testing.expect(g.beat(at(t), .{}).dy >= 0);
}

test "a resting finger stops drawing as the stop shows, with no step back, and a quiet link stays quiet" {
    var g: Glide = .{};
    var t: f64 = 1;
    for (0..20) |i| {
        g.event(.{ .dy = -5, .t = t - refresh - 0.003, .phase = if (i == 0) .began else .changed });
        _ = g.beat(at(t), .{});
        t += refresh;
    }
    var draws: usize = 0;
    var last_draw: f64 = 0;
    for (0..240) |_| {
        if (g.wants(at(t), .{})) {
            try testing.expect(g.beat(at(t), .{}).dy <= 0);
            draws += 1;
            last_draw = t;
        }
        t += refresh;
    }
    // One extrapolated refresh; the stop keeps it. No more.
    try testing.expect(draws <= 1);
    try testing.expect(last_draw - (1 + 19 * refresh) <= (moving_beats + 1) * refresh);
    try testing.expect(!g.active(t));
}

test "a touch that stops a fling keeps what was shown" {
    var g: Glide = .{};
    var t: f64 = 1;
    for (0..12) |i| {
        if (i != 11) g.event(.{ .dy = -20, .t = t - refresh - 0.003, .phase = if (i == 0) .began else .momentum });
        _ = g.beat(at(t), .{});
        t += refresh;
    }
    // Refresh 11 was extrapolated; then a finger lands (began, no delta).
    try testing.expect(g.shown < g.real);
    g.event(.{ .dy = 0, .t = t - refresh - 0.003, .phase = .began });
    for (0..30) |_| {
        try testing.expect(g.beat(at(t), .{}).dy <= 0);
        t += refresh;
    }
}

test "mouse wheel notches ease at the refresh rate and land on the exact sum" {
    for ([_]usize{ 1, 3 }) |notches| {
        var g: Glide = .{};
        var t: f64 = 1;
        var steps: [64]f64 = undefined;
        var n: usize = 0;
        var shown: f64 = 0;
        for (0..64) |i| {
            // Notches 40 ms apart, each 12 points (one line of 12).
            if (i % 5 == 0 and i / 5 < notches) g.event(.{ .dy = -12, .t = t - refresh - 0.001, .precise = false });
            const s = g.beat(at(t), .{});
            shown += s.dy;
            steps[n] = s.dy;
            n += 1;
            t += refresh;
        }
        const total = -12 * @as(f64, @floatFromInt(notches));
        try testing.expectEqual(total, shown);
        // Monotone: every step in the notch's direction or still.
        var moving_refreshes: usize = 0;
        for (steps[0..n]) |s| {
            try testing.expect(s <= 0);
            moving_refreshes += @intFromBool(s != 0);
        }
        // Spread over the ease's refreshes, not one 12-point jump each.
        try testing.expect(moving_refreshes >= notches * 8);
        // No refresh moves a whole notch.
        for (steps[0..n]) |s| try testing.expect(@abs(s) < 12);
    }
    // Reduced motion: one jump on the refresh after the notch.
    var g: Glide = .{};
    g.event(.{ .dy = -12, .t = 1, .precise = false, .reduce_motion = true });
    try testing.expectEqual(@as(f64, -12), g.beat(at(1 + 2 * refresh), .{}).dy);
    try testing.expectEqual(@as(f64, 0), g.beat(at(1 + 3 * refresh), .{}).dy);
}

test "a trackpad's deltas are not eased like a wheel's" {
    var g: Glide = .{};
    g.event(.{ .dy = -12, .t = 1, .phase = .began });
    try testing.expectEqual(@as(f64, -12), g.beat(at(1 + 2 * refresh), .{}).dy);
}

test "a hidden window's scroll is applied at once" {
    var g: Glide = .{};
    g.event(.{ .dy = -12, .t = 1, .precise = false });
    g.event(.{ .dy = -12, .t = 1.001, .precise = false });
    const s = g.flush();
    try testing.expectEqual(@as(f64, -24), s.dy);
    try testing.expect(!g.active(1.002));
}

test "a momentum delta is marked as momentum's when it is shown" {
    var g: Glide = .{};
    g.event(.{ .dy = -6, .t = 1, .phase = .momentum });
    try testing.expect(g.beat(at(1 + 2 * refresh), .{}).momentum);
    g.event(.{ .dy = -6, .t = 1 + refresh, .phase = .changed });
    try testing.expect(!g.beat(at(1 + 3 * refresh), .{}).momentum);
}

test "event times are read on the tick's clock, not the presentation time" {
    // An event handled just now is not "a refresh ago" because the frame
    // it goes into is presented two refreshes ahead.
    var g: Glide = .{};
    for (0..10) |i| {
        const k: f64 = @floatFromInt(i);
        g.event(.{ .dy = -4, .t = 1 + k * refresh, .phase = if (i == 0) .began else .changed });
        _ = g.beat(.{ .target = 1 + (k + 2) * refresh, .now = 1 + k * refresh + 0.001, .period = refresh }, .{});
    }
    // The next tick, no event yet: extrapolated, not settled as a stop,
    // though its target is 2.5 refreshes after the last event.
    const s = g.beat(.{ .target = 1 + 11.6 * refresh, .now = 1 + 10 * refresh + 0.001, .period = refresh }, .{});
    try testing.expectEqual(Source.glide, s.source);
    try testing.expect(g.moving(1 + 10 * refresh + 0.001));
}

test "zero-delta events reach the glide only when they end something" {
    try testing.expectEqual(Route.glide, route(-3, .changed, true, false, false));
    // A finger resting: stationary events with no delta go nowhere.
    try testing.expectEqual(Route.none, route(0, .changed, false, false, true));
    try testing.expectEqual(Route.none, route(0, .began, false, false, true));
    try testing.expectEqual(Route.none, route(0, .momentum, false, false, true));
    // A lift, momentum's end: they settle the scroll in progress.
    try testing.expectEqual(Route.glide, route(0, .ended, false, false, true));
    try testing.expectEqual(Route.glide, route(0, .momentum_ended, false, false, true));
    try testing.expectEqual(Route.none, route(0, .ended, false, false, false));
    // A view reading the wheel itself keeps its path.
    try testing.expectEqual(Route.wheel_view, route(-3, .changed, false, true, false));
}
