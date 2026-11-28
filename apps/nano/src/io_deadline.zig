//! Run blocking I/O with a fixed or idle deadline by canceling and joining
//! its Zig I/O task. Borrowed arguments must stay alive until `run` returns;
//! callers must dispose any owned result returned after the deadline.
const std = @import("std");
const Io = std.Io;

pub const Progress = struct {
    last_activity_ms: std.atomic.Value(i64),

    pub fn init(io: Io) Progress {
        return .{ .last_activity_ms = .init(Io.Clock.awake.now(io).toMilliseconds()) };
    }

    pub fn tick(self: *Progress, io: Io) void {
        self.last_activity_ms.store(Io.Clock.awake.now(io).toMilliseconds(), .release);
    }
};

fn idleDeadlineMs(last_activity_ms: i64, timeout_ms: u32) i64 {
    return last_activity_ms +| timeout_ms;
}

pub fn Outcome(comptime R: type) type {
    return union(enum) {
        finished: R,
        timed_out: R,
        canceled: R,
    };
}

/// Calls `op` on a cancellable concurrent task, then cancels and joins it on
/// deadline or caller cancellation. The deadline is fixed unless `progress`
/// is supplied, in which case each tick restarts the idle interval.
pub fn run(
    io: Io,
    timeout_ms: u32,
    progress: ?*Progress,
    comptime op: anytype,
    args: std.meta.ArgsTuple(@TypeOf(op)),
) Io.ConcurrentError!Outcome(@typeInfo(@TypeOf(op)).@"fn".return_type.?) {
    const R = @typeInfo(@TypeOf(op)).@"fn".return_type.?;
    const Worker = struct {
        const Context = struct { io: Io, done: *Io.Event, args: @TypeOf(args) };

        fn call(context: Context) R {
            defer context.done.set(context.io);
            return @call(.auto, op, context.args);
        }
    };

    const start_ms = Io.Clock.awake.now(io).toMilliseconds();
    const fixed_deadline_ms = start_ms +| timeout_ms;
    var done: Io.Event = .unset;
    var future = try Io.concurrent(io, Worker.call, .{.{ .io = io, .done = &done, .args = args }});
    var joined = false;
    defer {
        if (!joined) _ = future.cancel(io) catch {};
    }

    while (true) {
        if (@atomicLoad(Io.Event, &done, .acquire) == .is_set) {
            joined = true;
            return .{ .finished = future.await(io) };
        }
        const now_ms = Io.Clock.awake.now(io).toMilliseconds();
        const deadline_ms = if (progress) |p|
            idleDeadlineMs(p.last_activity_ms.load(.acquire), timeout_ms)
        else
            fixed_deadline_ms;
        if (now_ms >= deadline_ms) {
            joined = true;
            return .{ .timed_out = future.cancel(io) };
        }
        const wait_ms = deadline_ms - now_ms;
        done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => continue,
            error.Canceled => {
                joined = true;
                return .{ .canceled = future.cancel(io) };
            },
        };
    }
}

const testing = std.testing;

const SilentPeer = struct {
    server: Io.net.Server,
    release: Io.Event = .unset,
    thread: ?std.Thread = null,

    fn serve(self: *SilentPeer) void {
        var stream = self.server.accept(testing.io) catch return;
        defer stream.close(testing.io);
        self.release.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch {};
    }
};

fn blockedRead(io: Io, stream: *const Io.net.Stream) Io.net.Stream.Reader.Error!Io.net.Stream.ReadResult {
    var bytes: [1]u8 = undefined;
    var buffers: [1][]u8 = .{&bytes};
    return stream.readWithControl(io, &buffers, &.{});
}

fn returnValue(value: u32) anyerror!u32 {
    return value;
}

test "deadline run returns a completed operation" {
    const outcome = try run(testing.io, 1_000, null, returnValue, .{42});
    switch (outcome) {
        .finished => |result| try testing.expectEqual(@as(u32, 42), try result),
        .timed_out, .canceled => return error.ExpectedCompletion,
    }
}

test "idle deadline follows the latest progress timestamp" {
    try testing.expectEqual(@as(i64, 1_400), idleDeadlineMs(1_100, 300));
    try testing.expect(idleDeadlineMs(1_100, 300) > idleDeadlineMs(1_000, 300));
}

// The red 13687daf run was the caller-level WebSocket, HTTP, and update tests;
// this direct worker-cancellation regression was added after that run.
test "deadline cancels and joins a blocked socket task" {
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var peer: SilentPeer = .{ .server = try addr.listen(testing.io, .{ .reuse_address = true }) };
    peer.thread = try std.Thread.spawn(.{}, SilentPeer.serve, .{&peer});
    defer {
        peer.release.set(testing.io);
        const wake_addr = Io.net.IpAddress.parseIp4("127.0.0.1", peer.server.socket.address.getPort()) catch unreachable;
        if (wake_addr.connect(testing.io, .{ .mode = .stream })) |wake| {
            wake.close(testing.io);
        } else |_| {}
        if (peer.thread) |thread| thread.join();
        peer.server.deinit(testing.io);
    }

    const client_addr = try Io.net.IpAddress.parseIp4("127.0.0.1", peer.server.socket.address.getPort());
    const stream = try client_addr.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    const started = Io.Clock.awake.now(testing.io);
    const outcome = try run(testing.io, 2_000, null, blockedRead, .{ testing.io, &stream });
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(testing.io)).toMilliseconds();
    switch (outcome) {
        .timed_out => |result| try testing.expectError(error.Canceled, result),
        .finished => return error.ExpectedTimeout,
        .canceled => return error.UnexpectedCancellation,
    }
    try testing.expect(elapsed_ms < 4_000);
}
