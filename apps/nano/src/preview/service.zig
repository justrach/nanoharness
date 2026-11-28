//! Zig CLI/daemon host for local preview discovery and the port-7331 proxy
//! (`crates/engine`'s replacement for `crates/preview`).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const catalog = @import("catalog.zig");
const discovery = @import("discovery.zig");
const proxy_mod = @import("proxy.zig");

pub const max_servers: usize = 24;
const scan_interval_ms: i64 = 2_000;
const bind_retry_ms: i64 = 2_000;
const poll_step_ms: i64 = 50;

pub const LocalServer = struct {
    port: u16,
    url: []const u8,
    name: []const u8,
    folder: ?[]const u8,
};

fn isLoopbackOrUnspecified(a: catalog.Address) bool {
    if (!a.v6) {
        if (a.ip[0] == 127) return true;
        return std.mem.eql(u8, a.ip[0..4], &.{ 0, 0, 0, 0 });
    }
    var all_zero = true;
    for (a.ip) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    if (all_zero) return true;
    for (a.ip[0..15]) |b| if (b != 0) return false;
    return a.ip[15] == 1;
}

fn isUnspecified(a: catalog.Address) bool {
    const n: usize = if (a.v6) 16 else 4;
    for (a.ip[0..n]) |b| if (b != 0) return false;
    return true;
}

fn probeAddress(a: catalog.Address) catalog.Address {
    if (a.v6 and !isUnspecified(a)) return .loopback6(a.port);
    return .loopback4(a.port);
}

fn baseFolderName(path: []const u8) ?[]const u8 {
    const t = std.mem.trimEnd(u8, path, "/\\");
    if (t.len == 0) return null;
    const base = std.fs.path.basename(t);
    return if (base.len == 0) null else base;
}

/// Pure selection/formatting over already-discovered listeners and HTTP probe results.
pub fn selectLocalServers(
    a: Allocator,
    listeners: []const catalog.Listener,
    self_pid: u32,
    ignore_pid: u32,
    probe_fn: *const fn (ctx: ?*anyopaque, addr: catalog.Address) bool,
    probe_ctx: ?*anyopaque,
) ![]LocalServer {
    var seen_ports: std.AutoHashMapUnmanaged(u16, void) = .empty;
    var candidates: std.ArrayList(catalog.Listener) = .empty;
    for (listeners) |l| {
        if (l.pid == self_pid or (ignore_pid != 0 and l.pid == ignore_pid)) continue;
        if (l.isTestRun()) continue;
        if (!isLoopbackOrUnspecified(l.address)) continue;
        const gop = try seen_ports.getOrPut(a, l.address.port);
        if (!gop.found_existing) try candidates.append(a, l);
    }
    var servers: std.ArrayList(LocalServer) = .empty;
    for (candidates.items) |l| {
        const probe = probeAddress(l.address);
        if (!probe_fn(probe_ctx, probe)) continue;
        try servers.append(a, .{
            .port = l.address.port,
            .url = try std.fmt.allocPrint(a, "http://localhost:{d}", .{l.address.port}),
            .name = try a.dupe(u8, catalog.framework(l.args).name),
            .folder = if (baseFolderName(l.cwd)) |f| try a.dupe(u8, f) else null,
        });
    }
    std.mem.sort(LocalServer, servers.items, {}, struct {
        fn less(_: void, x: LocalServer, y: LocalServer) bool {
            return x.port < y.port;
        }
    }.less);
    if (servers.items.len > max_servers) servers.items.len = max_servers;
    return try a.dupe(LocalServer, servers.items);
}

pub fn writeLocalServersJson(servers: []const LocalServer, w: *Io.Writer) !void {
    try w.writeByte('[');
    for (servers, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"port\":{d},\"url\":{f},\"name\":{f},\"folder\":{f}}}", .{
            s.port, json.fmt(s.url, .{}), json.fmt(s.name, .{}), json.fmt(s.folder, .{}),
        });
    }
    try w.writeAll("]\n");
}

/// Scans native loopback listeners once and writes a `LocalServer[]` JSON line to `out`.
pub fn runServersScan(gpa: Allocator, io: Io, ignore_pid: u32, out: *Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const sys = discovery.Sys.native();
    const raw = discovery.listeners(a, io, sys);

    var seen_ports: std.AutoHashMapUnmanaged(u16, void) = .empty;
    var candidates: std.ArrayList(catalog.Listener) = .empty;
    for (raw) |l| {
        if (l.pid == sys.self_pid or (ignore_pid != 0 and l.pid == ignore_pid)) continue;
        if (l.isTestRun()) continue;
        if (!isLoopbackOrUnspecified(l.address)) continue;
        const gop = try seen_ports.getOrPut(a, l.address.port);
        if (!gop.found_existing) try candidates.append(a, l);
    }

    const hits = try a.alloc(bool, candidates.items.len);
    const Ctx = struct { io: Io, list: []const catalog.Listener, out: []bool, i: usize };
    var start: usize = 0;
    while (start < candidates.items.len) : (start += 12) {
        const end = @min(start + 12, candidates.items.len);
        var threads: [12]?std.Thread = @splat(null);
        for (start..end) |k| {
            const addr = probeAddress(candidates.items[k].address);
            threads[k - start] = std.Thread.spawn(.{}, struct {
                fn run(pio: Io, paddr: catalog.Address, res: *bool) void {
                    res.* = discovery.isHttp(pio, paddr);
                }
            }.run, .{ io, addr, &hits[k] }) catch blk: {
                hits[k] = discovery.isHttp(io, addr);
                break :blk null;
            };
        }
        for (threads[0 .. end - start]) |t| if (t) |th| th.join();
    }
    _ = Ctx;

    var servers: std.ArrayList(LocalServer) = .empty;
    for (candidates.items, 0..) |l, i| {
        if (!hits[i]) continue;
        try servers.append(a, .{
            .port = l.address.port,
            .url = try std.fmt.allocPrint(a, "http://localhost:{d}", .{l.address.port}),
            .name = try a.dupe(u8, catalog.framework(l.args).name),
            .folder = if (baseFolderName(l.cwd)) |f| try a.dupe(u8, f) else null,
        });
    }
    std.mem.sort(LocalServer, servers.items, {}, struct {
        fn less(_: void, x: LocalServer, y: LocalServer) bool {
            return x.port < y.port;
        }
    }.less);
    if (servers.items.len > max_servers) servers.items.len = max_servers;

    try writeLocalServersJson(servers.items, out);
    try out.flush();
}

const DaemonState = struct {
    gpa: Allocator,
    io: Io,
    sys: discovery.Sys,
    cat: *catalog.Catalog,
    proxy: proxy_mod.Proxy,
    memory: catalog.ProbeMemory = .{},
    port: u16,
    stop_flag: std.atomic.Value(bool) = .init(false),
    dirty: std.atomic.Value(bool) = .init(true),
    projects_lock: Io.Mutex = .init,
    project_cwds: [][]u8 = &.{},

    fn stopping(d: *DaemonState) bool {
        return d.stop_flag.load(.acquire);
    }

    fn pause(d: *DaemonState, ms: i64, wake_on_dirty: bool) bool {
        var left = ms;
        while (left > 0) {
            if (d.stopping()) return false;
            if (wake_on_dirty and d.dirty.load(.acquire)) return true;
            const step = @min(left, poll_step_ms);
            Io.sleep(d.io, .fromMilliseconds(step), .awake) catch return false;
            left -= step;
        }
        return !d.stopping();
    }

    fn setProjects(d: *DaemonState, raw_cwds: []const []const u8) !void {
        const next = try d.gpa.alloc([]u8, raw_cwds.len);
        var built: usize = 0;
        errdefer {
            for (next[0..built]) |s| d.gpa.free(s);
            d.gpa.free(next);
        }
        for (raw_cwds) |s| {
            next[built] = try d.gpa.dupe(u8, s);
            built += 1;
        }
        d.projects_lock.lockUncancelable(d.io);
        const old = d.project_cwds;
        d.project_cwds = next;
        d.projects_lock.unlock(d.io);
        for (old) |s| d.gpa.free(s);
        if (old.len > 0) d.gpa.free(old);
        d.dirty.store(true, .release);
    }

    fn bindLoop(d: *DaemonState) void {
        while (!d.stopping()) {
            if (d.proxy.bind(d.port)) |bound| {
                d.cat.setProxyStatus(bound, null);
                d.dirty.store(true, .release);
                d.proxy.start() catch {};
                return;
            } else |e| {
                var buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Local previews could not listen on port 7331: {s}", .{bindErrorText(e)}) catch "Local previews could not listen on port 7331";
                d.cat.setProxyStatus(catalog.proxy_port_default, msg);
                d.dirty.store(true, .release);
            }
            if (!d.pause(bind_retry_ms, false)) return;
        }
    }

    fn scanOnce(d: *DaemonState) !?i64 {
        var arena = std.heap.ArenaAllocator.init(d.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var raw_roots: std.ArrayList([]const u8) = .empty;
        d.projects_lock.lockUncancelable(d.io);
        for (d.project_cwds) |cwd| raw_roots.append(a, a.dupe(u8, cwd) catch continue) catch {};
        d.projects_lock.unlock(d.io);

        var roots: std.ArrayList([]const u8) = .empty;
        for (raw_roots.items) |r| {
            const canon = d.sys.canonicalize(d.sys.ctx, a, d.io, r) orelse a.dupe(u8, r) catch continue;
            var dup = false;
            for (roots.items) |x| if (std.mem.eql(u8, x, canon)) {
                dup = true;
            };
            if (!dup) try roots.append(a, canon);
        }
        std.mem.sort([]const u8, roots.items, {}, struct {
            fn f(_: void, x: []const u8, y: []const u8) bool {
                return catalog.pathComponents(x) > catalog.pathComponents(y);
            }
        }.f);

        var candidates: std.ArrayList(catalog.Observation) = .empty;
        if (roots.items.len > 0) {
            const pport = d.cat.proxyPort();
            for (discovery.listeners(a, d.io, d.sys)) |l| {
                if (l.address.port == catalog.proxy_port_default or l.address.port == pport) continue;
                if (l.pid == d.sys.self_pid) continue;
                for (roots.items) |root| {
                    if (l.belongsTo(root)) {
                        try candidates.append(a, .{ .root = root, .listener = l });
                        break;
                    }
                }
            }
        }
        const plans = try a.alloc(catalog.ProbeMemory.Plan, candidates.items.len);
        const settling_until = d.memory.plan(d.gpa, candidates.items, discovery.nowMs(d.io), plans);
        var servers: std.ArrayList(catalog.Observation) = .empty;
        var to_probe: std.ArrayList(usize) = .empty;
        for (plans, 0..) |p, i| switch (p) {
            .known => try servers.append(a, candidates.items[i]),
            .probe => try to_probe.append(a, i),
            .skip => {},
        };

        const results = try a.alloc(bool, to_probe.items.len);
        var start: usize = 0;
        while (start < to_probe.items.len) : (start += 12) {
            const end = @min(start + 12, to_probe.items.len);
            var threads: [12]?std.Thread = @splat(null);
            for (start..end) |k| {
                const addr = candidates.items[to_probe.items[k]].listener.address;
                threads[k - start] = std.Thread.spawn(.{}, struct {
                    fn run(pio: Io, paddr: catalog.Address, res: *bool) void {
                        res.* = discovery.isHttp(pio, paddr);
                    }
                }.run, .{ d.io, addr, &results[k] }) catch blk: {
                    results[k] = discovery.isHttp(d.io, addr);
                    break :blk null;
                };
            }
            for (threads[0 .. end - start]) |t| if (t) |th| th.join();
        }
        const now = discovery.nowMs(d.io);
        for (to_probe.items, 0..) |ci, k| {
            const l = candidates.items[ci].listener;
            try d.memory.record(d.gpa, l, results[k], now);
            if (results[k]) try servers.append(a, candidates.items[ci]);
        }
        try d.cat.replaceLocal(servers.items);
        return settling_until;
    }

    fn snapshotLine(d: *DaemonState) ![]u8 {
        d.cat.lock();
        defer d.cat.unlock();
        var aw: Io.Writer.Allocating = .init(d.gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"services\":[");
        for (d.cat.published, 0..) |s, i| {
            if (i > 0) try w.writeByte(',');
            try s.writeJson(w);
        }
        try w.print("],\"proxyPort\":{d},\"error\":{f}}}\n", .{ d.cat.proxy_port, json.fmt(d.cat.err, .{}) });
        return aw.toOwnedSlice();
    }

    fn stdinLoop(d: *DaemonState, in_file: Io.File) void {
        defer d.stop_flag.store(true, .release);
        var rbuf: [16384]u8 = undefined;
        var reader = in_file.readerStreaming(d.io, &rbuf);
        var line_buf: Io.Writer.Allocating = .init(d.gpa);
        defer line_buf.deinit();
        while (!d.stopping()) {
            line_buf.clearRetainingCapacity();
            const streamed = reader.interface.streamDelimiter(&line_buf.writer, '\n') catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => break,
                error.WriteFailed => return,
            };
            _ = streamed;
            _ = reader.interface.takeByte() catch {};
            const raw = std.mem.trim(u8, line_buf.written(), " \t\r");
            if (raw.len == 0) continue;
            var arena = std.heap.ArenaAllocator.init(d.gpa);
            defer arena.deinit();
            const parsed = json.parseFromSliceLeaky(json.Value, arena.allocator(), raw, .{}) catch continue;
            if (parsed != .object) continue;
            const op = parsed.object.get("op") orelse continue;
            if (op != .string or !std.mem.eql(u8, op.string, "projects")) continue;
            const cwds_val = parsed.object.get("cwds") orelse continue;
            if (cwds_val != .array) continue;
            var list: std.ArrayList([]const u8) = .empty;
            for (cwds_val.array.items) |item| {
                if (item == .string and item.string.len > 0) list.append(arena.allocator(), item.string) catch {};
            }
            d.setProjects(list.items) catch {};
        }
    }
};

fn bindErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.AddressInUse => "Address already in use",
        error.AccessDenied => "Permission denied",
        error.AddressUnavailable => "Can't assign requested address",
        else => @errorName(e),
    };
}

/// Runs the long-lived preview discovery + proxy daemon.
/// Stdin receives `{"op":"projects","cwds":["..."]}` JSON lines; EOF exits cleanly.
/// Stdout emits `{"services":[...],"proxyPort":7331,"error":null}` JSON lines on change.
pub fn runDaemon(
    gpa: Allocator,
    io: Io,
    port: u16,
    catalog_file: ?[]const u8,
    device_id: []const u8,
    device_name: []const u8,
) !void {
    const cat = try catalog.Catalog.open(gpa, io, catalog_file, device_id, device_name);
    defer cat.deinit();

    var state: DaemonState = .{
        .gpa = gpa,
        .io = io,
        .sys = .native(),
        .cat = cat,
        .proxy = .{ .gpa = gpa, .io = io, .catalog = cat, .verify = proxy_mod.nativeVerify() },
        .port = port,
    };
    defer {
        state.stop_flag.store(true, .release);
        state.proxy.stop();
        state.memory.deinit(gpa);
        for (state.project_cwds) |s| gpa.free(s);
        if (state.project_cwds.len > 0) gpa.free(state.project_cwds);
    }

    const bind_thread = try std.Thread.spawn(.{}, DaemonState.bindLoop, .{&state});
    defer bind_thread.join();

    const stdin_thread = try std.Thread.spawn(.{}, DaemonState.stdinLoop, .{ &state, Io.File.stdin() });
    defer {
        // Stdin closes on parent EOF; thread exits naturally. On early break, detach if still blocked.
        stdin_thread.detach();
    }

    var out_buf: [65536]u8 = undefined;
    var out_writer = Io.File.stdout().writerStreaming(io, &out_buf);
    var last_line: []u8 = &.{};
    defer if (last_line.len > 0) gpa.free(last_line);

    while (!state.stopping()) {
        state.dirty.store(false, .release);
        const settling_until = state.scanOnce() catch null;
        const line = state.snapshotLine() catch continue;
        if (!std.mem.eql(u8, line, last_line)) {
            if (last_line.len > 0) gpa.free(last_line);
            last_line = line;
            out_writer.interface.writeAll(line) catch break;
            out_writer.interface.flush() catch break;
        } else {
            gpa.free(line);
        }
        var wait_ms = scan_interval_ms;
        if (settling_until) |until| {
            const rem = @max(@as(i64, 100), until - discovery.nowMs(io));
            wait_ms = @min(wait_ms, rem);
        }
        if (!state.pause(wait_ms, true)) break;
    }
    state.stop_flag.store(true, .release);
    state.proxy.stop();
}

const testing = std.testing;

test "preview service: selectLocalServers filters self/ignore/non-loopback, dedups ports, and sorts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args_vite = [_][]const u8{ "node", "vite", "--port", "5173" };
    const args_next = [_][]const u8{ "node", "next", "dev" };
    const args_other = [_][]const u8{ "python3", "-m", "http.server" };
    const listeners = [_]catalog.Listener{
        .{ .pid = 10, .cwd = "/w/self", .args = &args_other, .started_at = 1, .address = .loopback4(9000) },
        .{ .pid = 20, .cwd = "/w/ignored", .args = &args_other, .started_at = 1, .address = .loopback4(9001) },
        .{ .pid = 30, .cwd = "/w/public", .args = &args_other, .started_at = 1, .address = .{ .ip = .{ 10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .port = 9002 } },
        .{ .pid = 40, .cwd = "/w/web", .args = &args_vite, .started_at = 1, .address = .loopback6(5173) },
        .{ .pid = 40, .cwd = "/w/web", .args = &args_vite, .started_at = 1, .address = .loopback4(5173) },
        .{ .pid = 50, .cwd = "/w/docs/", .args = &args_next, .started_at = 1, .address = .{ .port = 3000 } },
        .{ .pid = 60, .cwd = "/w/closed", .args = &args_other, .started_at = 1, .address = .loopback4(4000) },
    };

    const probe = struct {
        fn f(_: ?*anyopaque, addr: catalog.Address) bool {
            return addr.port != 4000;
        }
    }.f;

    const picked = try selectLocalServers(a, &listeners, 10, 20, probe, null);
    try testing.expectEqual(@as(usize, 2), picked.len);
    try testing.expectEqual(@as(u16, 3000), picked[0].port);
    try testing.expectEqualStrings("http://localhost:3000", picked[0].url);
    try testing.expectEqualStrings("Next.js", picked[0].name);
    try testing.expectEqualStrings("docs", picked[0].folder.?);

    try testing.expectEqual(@as(u16, 5173), picked[1].port);
    try testing.expectEqualStrings("Vite", picked[1].name);
    try testing.expectEqualStrings("web", picked[1].folder.?);

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeLocalServersJson(picked, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"url\":\"http://localhost:5173\"") != null);
}
