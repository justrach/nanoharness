//! Project previews: persisted names, independent of ephemeral process and
//! listener observations (`crates/preview/src/catalog.rs`, the framework and
//! identity rules of `discovery.rs`, and `ProbeMemory` of `service.rs`).
//!
//! `previews.json` in the data directory keeps project and service ids and
//! hostname labels; observed pids and ports never go into it. The first
//! service of a project keeps the project's hostname, later ones get a
//! descriptive suffix, and a device-name collision gets a numeric one.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// `harness_proto::PREVIEW_PROXY_PORT`.
pub const proxy_port_default: u16 = 7331;
/// Observations taken per scan (`take(256)`).
pub const max_observations: usize = 256;

pub const Address = struct {
    v6: bool = false,
    /// IPv4 uses the first four bytes.
    ip: [16]u8 = @splat(0),
    port: u16,

    pub fn loopback4(port: u16) Address {
        var a: Address = .{ .port = port };
        a.ip[0] = 127;
        a.ip[3] = 1;
        return a;
    }

    pub fn loopback6(port: u16) Address {
        var a: Address = .{ .v6 = true, .port = port };
        a.ip[15] = 1;
        return a;
    }

    /// `SocketAddr` order: every V4 before every V6, then address, then port.
    pub fn order(a: Address, b: Address) std.math.Order {
        if (a.v6 != b.v6) return if (!a.v6) .lt else .gt;
        const n: usize = if (a.v6) 16 else 4;
        const o = std.mem.order(u8, a.ip[0..n], b.ip[0..n]);
        if (o != .eq) return o;
        return std.math.order(a.port, b.port);
    }

    pub fn eql(a: Address, b: Address) bool {
        return a.order(b) == .eq;
    }

    pub fn toIp(a: Address) Io.net.IpAddress {
        if (a.v6) return .{ .ip6 = .{ .bytes = a.ip, .port = a.port } };
        return .{ .ip4 = .{ .bytes = a.ip[0..4].*, .port = a.port } };
    }
};

/// One listening socket and the process that owns it (`discovery::Listener`).
pub const Listener = struct {
    pid: u32,
    parent: u32 = 1,
    cwd: []const u8,
    args: []const []const u8,
    started_at: u64,
    address: Address,
    harness_owned: bool = false,

    pub fn belongsTo(l: Listener, root: []const u8) bool {
        return pathStartsWith(l.cwd, root);
    }

    /// True when the listening process is a recognized test runner whose
    /// fixture server should never receive discovery `HEAD /` probes.
    pub fn isTestRun(l: Listener) bool {
        if (l.args.len == 0) return false;
        const cmd = baseName(l.args[0]);
        for ([_][]const u8{
            "pytest", "vitest",  "jest",    "mocha",      "ava",
            "rspec",  "phpunit", "cypress", "playwright", "bun-test",
            "tap",
        }) |runner| {
            if (std.ascii.eqlIgnoreCase(cmd, runner)) return true;
        }
        // Check `cargo test`, `go test`, `zig build test`, `python -m pytest|unittest`, `npm|pnpm|yarn|bun test`.
        for (l.args[1..], 1..) |arg, idx| {
            const b = baseName(arg);
            if (std.ascii.eqlIgnoreCase(b, "pytest") or std.ascii.eqlIgnoreCase(b, "vitest") or
                std.ascii.eqlIgnoreCase(b, "jest") or std.ascii.eqlIgnoreCase(b, "mocha") or
                std.ascii.eqlIgnoreCase(b, "unittest") or std.ascii.eqlIgnoreCase(b, "playwright"))
            {
                return true;
            }
            if (std.mem.eql(u8, arg, "test")) {
                if (idx == 1 and (std.ascii.eqlIgnoreCase(cmd, "cargo") or std.ascii.eqlIgnoreCase(cmd, "go") or
                    std.ascii.eqlIgnoreCase(cmd, "npm") or std.ascii.eqlIgnoreCase(cmd, "pnpm") or
                    std.ascii.eqlIgnoreCase(cmd, "yarn") or std.ascii.eqlIgnoreCase(cmd, "bun") or
                    std.ascii.eqlIgnoreCase(cmd, "deno")))
                {
                    return true;
                }
                if (idx == 2 and std.ascii.eqlIgnoreCase(cmd, "zig") and std.mem.eql(u8, l.args[1], "build")) {
                    return true;
                }
            }
        }
        return false;
    }

    fn baseName(path: []const u8) []const u8 {
        const trimmed = std.mem.trimEnd(u8, path, "/\\");
        const slash = std.mem.lastIndexOfAny(u8, trimmed, "/\\");
        const base = if (slash) |s| trimmed[s + 1 ..] else trimmed;
        if (std.ascii.endsWithIgnoreCase(base, ".exe")) return base[0 .. base.len - 4];
        return base;
    }

    fn dupe(l: Listener, a: Allocator) !Listener {
        const args = try a.alloc([]const u8, l.args.len);
        for (l.args, 0..) |arg, i| args[i] = try a.dupe(u8, arg);
        return .{
            .pid = l.pid,
            .parent = l.parent,
            .cwd = try a.dupe(u8, l.cwd),
            .args = args,
            .started_at = l.started_at,
            .address = l.address,
            .harness_owned = l.harness_owned,
        };
    }
};

/// `harness_proto::PreviewService`.
pub const Service = struct {
    id: []const u8,
    project_id: []const u8,
    project_name: []const u8,
    project_cwd: []const u8,
    device_id: []const u8,
    device_name: []const u8,
    hostname: []const u8,
    name: []const u8,
    port: u16,
    pid: u32,
    cwd: []const u8,
    started_at: u64,
    harness_owned: bool,

    pub fn writeJson(s: Service, w: *Io.Writer) Io.Writer.Error!void {
        try w.print(
            "{{\"id\":{f},\"projectId\":{f},\"projectName\":{f},\"projectCwd\":{f},\"deviceId\":{f},\"deviceName\":{f},\"hostname\":{f},\"name\":{f},\"port\":{d},\"pid\":{d},\"cwd\":{f},\"startedAt\":{d},\"harnessOwned\":{}}}",
            .{
                json.fmt(s.id, .{}),          json.fmt(s.project_id, .{}), json.fmt(s.project_name, .{}),
                json.fmt(s.project_cwd, .{}), json.fmt(s.device_id, .{}),  json.fmt(s.device_name, .{}),
                json.fmt(s.hostname, .{}),    json.fmt(s.name, .{}),       s.port,
                s.pid,                        json.fmt(s.cwd, .{}),        s.started_at,
                s.harness_owned,
            },
        );
    }
};

pub const LocalRoute = struct {
    service: Service,
    listener: Listener,
};

/// An observation that passed cwd association and an HTTP probe.
pub const Observation = struct {
    root: []const u8,
    listener: Listener,
};

// ---------------------------------------------------------------- pure rules

/// Lowercase ASCII alphanumerics joined by single dashes, at most 48 bytes.
pub fn slug(buf: *[64]u8, value: []const u8) []const u8 {
    var n: usize = 0;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            buf[n] = std.ascii.toLower(c);
            n += 1;
        } else if (n > 0 and buf[n - 1] != '-') {
            buf[n] = '-';
            n += 1;
        }
        if (n >= 48) break;
    }
    const t = std.mem.trim(u8, buf[0..n], "-");
    return if (t.len == 0) "project" else t;
}

/// Exactly `<label>.<label>.localhost`, each label a DNS label.
pub fn validHostname(host: []const u8) bool {
    var it = std.mem.splitScalar(u8, host, '.');
    var labels: [3][]const u8 = undefined;
    var count: usize = 0;
    while (it.next()) |l| {
        if (count == 3) return false;
        labels[count] = l;
        count += 1;
    }
    if (count != 3 or !std.mem.eql(u8, labels[2], "localhost")) return false;
    for (labels[0..2]) |s| {
        if (s.len == 0 or s.len > 63 or s[0] == '-' or s[s.len - 1] == '-') return false;
        for (s) |b| if (!(std.ascii.isLower(b) or std.ascii.isDigit(b) or b == '-')) return false;
    }
    return true;
}

/// `base`, or `base-2`, `base-3`, … whichever is free.
pub fn allocateLabel(a: Allocator, base_in: []const u8, used: *const std.StringHashMapUnmanaged(void)) ![]const u8 {
    const base = std.mem.trimEnd(u8, base_in[0..@min(base_in.len, 58)], "-");
    if (!used.contains(base)) return a.dupe(u8, base);
    var index: usize = 2;
    while (true) : (index += 1) {
        const label = try std.fmt.allocPrint(a, "{s}-{d}", .{ base[0..@min(base.len, 48)], index });
        if (!used.contains(label)) return label;
        a.free(label);
    }
}

/// `Path::file_name`: the last component, ignoring trailing slashes.
fn fileName(path: []const u8) ?[]const u8 {
    const t = std.mem.trimEnd(u8, path, "/");
    if (t.len == 0) return null;
    const name = if (std.mem.lastIndexOfScalar(u8, t, '/')) |i| t[i + 1 ..] else t;
    if (std.mem.eql(u8, name, "..") or std.mem.eql(u8, name, ".")) return null;
    return name;
}

/// `Path::file_stem`.
pub fn fileStem(path: []const u8) ?[]const u8 {
    const name = fileName(path) orelse return null;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    if (dot == 0) return name;
    return name[0..dot];
}

pub const Framework = struct { name: []const u8, rank: u8 };

/// A framework label without advertising arguments (which may hold
/// credentials); frontends rank above generic HTTP services.
pub fn framework(args: []const []const u8) Framework {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "vite", "Vite" }, .{ "next", "Next.js" }, .{ "astro", "Astro" }, .{ "miniflare", "Miniflare" },
    };
    var lower_buf: [1024]u8 = undefined;
    inline for (table) |entry| {
        const needle = entry[0];
        for (args) |arg| {
            const lower = std.ascii.lowerString(lower_buf[0..@min(arg.len, lower_buf.len)], arg[0..@min(arg.len, lower_buf.len)]);
            const stem_hit = if (fileStem(lower)) |s| std.mem.eql(u8, s, needle) else false;
            if (stem_hit or std.mem.indexOf(u8, lower, "/" ++ needle ++ "/") != null or
                std.mem.startsWith(u8, lower, needle ++ "-server"))
            {
                return .{ .name = entry[1], .rank = if (std.mem.eql(u8, needle, "miniflare")) 80 else 100 };
            }
        }
    }
    if (args.len > 0) {
        if (fileName(args[0])) |n| {
            if (std.mem.eql(u8, n, "node") or std.mem.eql(u8, n, "bun") or std.mem.eql(u8, n, "deno"))
                return .{ .name = "Node HTTP server", .rank = 50 };
        }
    }
    return .{ .name = "HTTP server", .rank = 40 };
}

fn parsesAsPort(s: []const u8) ?u16 {
    return std.fmt.parseInt(u16, s, 10) catch null;
}

/// Port flags are operational settings, never part of a service identity.
pub fn commandIdentity(a: Allocator, args: []const []const u8) ![]u8 {
    var python_http = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "http.server")) python_http = true;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var skip = false;
    var first = true;
    for (args) |arg| {
        if (skip) {
            skip = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--inspect-port")) {
            skip = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--port=") or std.mem.startsWith(u8, arg, "PORT=") or
            std.mem.startsWith(u8, arg, "--inspect-port=")) continue;
        if (python_http and parsesAsPort(arg) != null) continue;
        if (!first) try out.append(a, 0);
        first = false;
        try out.appendSlice(a, arg);
    }
    return out.toOwnedSlice(a);
}

/// "API" / "Docs" for a generic server whose script or folder says so.
pub fn serviceRole(l: Listener, framework_name: []const u8) []const u8 {
    if (!std.mem.eql(u8, framework_name, "HTTP server") and !std.mem.eql(u8, framework_name, "Node HTTP server"))
        return framework_name;
    var buf: [256]u8 = undefined;
    for (0..l.args.len + 1) |i| {
        const value = if (i < l.args.len) l.args[i] else l.cwd;
        const stem = fileStem(value) orelse "";
        if (stem.len > buf.len) continue;
        const lower = std.ascii.lowerString(buf[0..stem.len], stem);
        if (std.mem.eql(u8, lower, "api") or std.mem.eql(u8, lower, "api-server")) return "API";
        if (std.mem.eql(u8, lower, "docs") or std.mem.eql(u8, lower, "documentation")) return "Docs";
    }
    return framework_name;
}

/// `Path::starts_with`: whole components only (`/a/bc` is not under `/a/b`).
pub fn pathStartsWith(path: []const u8, root: []const u8) bool {
    var pi = std.mem.tokenizeScalar(u8, path, '/');
    var ri = std.mem.tokenizeScalar(u8, root, '/');
    if ((path.len > 0 and path[0] == '/') != (root.len > 0 and root[0] == '/')) return false;
    while (ri.next()) |rc| {
        if (std.mem.eql(u8, rc, ".")) continue;
        const pc = pi.next() orelse return false;
        if (!std.mem.eql(u8, pc, rc)) return false;
    }
    return true;
}

/// `PathBuf` order, component by component.
pub fn pathOrder(a: []const u8, b: []const u8) std.math.Order {
    const ar = a.len > 0 and a[0] == '/';
    const br = b.len > 0 and b[0] == '/';
    if (ar != br) return if (ar) .lt else .gt;
    var ai = std.mem.tokenizeScalar(u8, a, '/');
    var bi = std.mem.tokenizeScalar(u8, b, '/');
    while (true) {
        const ac = ai.next();
        const bc = bi.next();
        if (ac == null and bc == null) return .eq;
        if (ac == null) return .lt;
        if (bc == null) return .gt;
        const o = std.mem.order(u8, ac.?, bc.?);
        if (o != .eq) return o;
    }
}

pub fn pathComponents(path: []const u8) usize {
    var it = std.mem.tokenizeScalar(u8, path, '/');
    var n: usize = if (path.len > 0 and path[0] == '/') 1 else 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn isFrontend(name: []const u8) bool {
    return std.mem.eql(u8, name, "Vite") or std.mem.eql(u8, name, "Next.js") or std.mem.eql(u8, name, "Astro");
}

fn uuidV4(io: Io, out: *[36]u8) void {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(raw, .lower);
    _ = std.fmt.bufPrint(out, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
}

// ---------------------------------------------------------------- probe memory

/// A socket is probed until it answers HTTP once; that verdict holds while the
/// same process owns it. A silent one is retried with a capped backoff.
/// Sockets are never probed before staying up for `probe_settle_ms` so
/// short-lived test fixture servers are never hit with stray `HEAD /` probes.
pub const ProbeMemory = struct {
    pub const probe_settle_ms: i64 = 3_000;
    pub const initial_backoff_ms: i64 = 4_000;
    pub const max_backoff_ms: i64 = 60_000;

    const Key = struct { pid: u32, started_at: u64, address: Address };
    const Verdict = union(enum) { http, not_http: struct { retry_at: i64, backoff: i64 } };

    verdicts: std.ArrayList(struct { key: Key, verdict: Verdict }) = .empty,
    first_seen: std.ArrayList(struct { key: Key, seen_at: i64 }) = .empty,

    pub fn deinit(m: *ProbeMemory, gpa: Allocator) void {
        m.verdicts.deinit(gpa);
        m.first_seen.deinit(gpa);
    }

    fn keyOf(l: Listener) Key {
        return .{ .pid = l.pid, .started_at = l.started_at, .address = l.address };
    }

    fn keyEql(a: Key, b: Key) bool {
        return a.pid == b.pid and a.started_at == b.started_at and a.address.eql(b.address);
    }

    fn find(m: *ProbeMemory, k: Key) ?usize {
        for (m.verdicts.items, 0..) |v, i| {
            if (keyEql(v.key, k)) return i;
        }
        return null;
    }

    fn findSeen(m: *ProbeMemory, k: Key) ?usize {
        for (m.first_seen.items, 0..) |s, i| {
            if (keyEql(s.key, k)) return i;
        }
        return null;
    }

    pub const Plan = enum { known, probe, skip };

    /// Forget verdicts and settle timestamps for sockets no longer listed,
    /// then classify each candidate. Returns the earliest timestamp when a
    /// still-settling socket becomes eligible to probe.
    pub fn plan(m: *ProbeMemory, gpa: Allocator, candidates: []const Observation, now_ms: i64, out: []Plan) ?i64 {
        var i: usize = 0;
        while (i < m.verdicts.items.len) {
            const k = m.verdicts.items[i].key;
            var present = false;
            for (candidates) |c| {
                if (keyEql(keyOf(c.listener), k)) {
                    present = true;
                    break;
                }
            }
            if (present) i += 1 else _ = m.verdicts.swapRemove(i);
        }
        var si: usize = 0;
        while (si < m.first_seen.items.len) {
            const k = m.first_seen.items[si].key;
            var present = false;
            for (candidates) |c| {
                if (keyEql(keyOf(c.listener), k)) {
                    present = true;
                    break;
                }
            }
            if (present) si += 1 else _ = m.first_seen.swapRemove(si);
        }

        var settling_until: ?i64 = null;
        for (candidates, 0..) |c, idx| {
            if (c.listener.isTestRun()) {
                out[idx] = .skip;
                continue;
            }
            const k = keyOf(c.listener);
            if (m.find(k)) |vi| {
                out[idx] = switch (m.verdicts.items[vi].verdict) {
                    .http => .known,
                    .not_http => |n| if (n.retry_at > now_ms) .skip else .probe,
                };
                continue;
            }
            const seen_at = if (m.findSeen(k)) |fi| m.first_seen.items[fi].seen_at else blk: {
                m.first_seen.append(gpa, .{ .key = k, .seen_at = now_ms }) catch {};
                break :blk now_ms;
            };
            const ready_at = seen_at + probe_settle_ms;
            if (now_ms < ready_at) {
                out[idx] = .skip;
                settling_until = if (settling_until) |cur| @min(cur, ready_at) else ready_at;
            } else {
                out[idx] = .probe;
            }
        }
        return settling_until;
    }

    pub fn record(m: *ProbeMemory, gpa: Allocator, l: Listener, http: bool, now_ms: i64) !void {
        const k = keyOf(l);
        const existing = m.find(k);
        const verdict: Verdict = if (http) .http else blk: {
            const backoff: i64 = if (existing) |vi| switch (m.verdicts.items[vi].verdict) {
                .not_http => |n| @min(n.backoff * 2, max_backoff_ms),
                .http => initial_backoff_ms,
            } else initial_backoff_ms;
            break :blk .{ .not_http = .{ .retry_at = now_ms + backoff, .backoff = backoff } };
        };
        if (existing) |vi| {
            m.verdicts.items[vi].verdict = verdict;
        } else {
            try m.verdicts.append(gpa, .{ .key = k, .verdict = verdict });
        }
    }
};

// ---------------------------------------------------------------- catalog

const ServiceName = struct { id: []const u8, fingerprint: []const u8, label: []const u8 };
const ProjectName = struct {
    cwd: []const u8,
    id: []const u8,
    label: []const u8,
    services: std.ArrayList(ServiceName) = .empty,
};
const PeerLabel = struct { device: []const u8, label: []const u8 };

pub const Catalog = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    /// Null keeps names in memory only.
    file: ?[]u8,
    device_id: []u8,
    device_name: []u8,
    names_arena: std.heap.ArenaAllocator,
    device_label: []const u8,
    /// Kept as read so a rewrite doesn't drop them (remote peers, `set_remote`).
    peer_labels: std.ArrayList(PeerLabel) = .empty,
    projects: std.ArrayList(ProjectName) = .empty,
    routes_arena: std.heap.ArenaAllocator,
    routes: []LocalRoute = &.{},
    proxy_port: u16 = proxy_port_default,
    err: ?[]u8 = null,
    /// The published, sorted services and their JSON; `seq` moves when it changes.
    published: []Service = &.{},
    published_json: []u8 = &.{},
    seq: u64 = 0,

    pub const OpenError = error{InvalidRegistry} || Allocator.Error || Io.Dir.ReadFileAllocError;

    pub fn open(gpa: Allocator, io: Io, file: ?[]const u8, device_id: []const u8, device_name: []const u8) !*Catalog {
        const c = try gpa.create(Catalog);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .file = null,
            .device_id = &.{},
            .device_name = &.{},
            .names_arena = .init(gpa),
            .device_label = "",
            .routes_arena = .init(gpa),
        };
        errdefer c.deinit();
        c.device_id = try gpa.dupe(u8, device_id);
        c.device_name = try gpa.dupe(u8, device_name);
        if (file) |f| {
            c.file = try gpa.dupe(u8, f);
            if (Io.Dir.cwd().readFileAlloc(io, f, gpa, .limited(16 * 1024 * 1024))) |bytes| {
                defer gpa.free(bytes);
                c.loadNames(bytes) catch return error.InvalidRegistry;
            } else |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            }
        }
        if (c.device_label.len == 0) {
            var buf: [64]u8 = undefined;
            c.device_label = try c.names_arena.allocator().dupe(u8, slug(&buf, device_name));
        }
        try c.publish();
        c.seq = 0;
        return c;
    }

    pub fn deinit(c: *Catalog) void {
        const gpa = c.gpa;
        if (c.file) |f| gpa.free(f);
        gpa.free(c.device_id);
        gpa.free(c.device_name);
        if (c.err) |e| gpa.free(e);
        gpa.free(c.published_json);
        gpa.free(c.published);
        c.peer_labels.deinit(gpa);
        for (c.projects.items) |*p| p.services.deinit(gpa);
        c.projects.deinit(gpa);
        c.names_arena.deinit();
        c.routes_arena.deinit();
        gpa.destroy(c);
    }

    fn loadNames(c: *Catalog, bytes: []const u8) !void {
        const a = c.names_arena.allocator();
        const parsed = try json.parseFromSlice(json.Value, c.gpa, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRegistry;
        const root = parsed.value.object;
        const dl = root.get("device_label") orelse return error.InvalidRegistry;
        if (dl != .string) return error.InvalidRegistry;
        c.device_label = try a.dupe(u8, dl.string);
        if (root.get("peer_labels")) |pl| {
            if (pl != .object) return error.InvalidRegistry;
            var it = pl.object.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .string) return error.InvalidRegistry;
                try c.peer_labels.append(c.gpa, .{ .device = try a.dupe(u8, e.key_ptr.*), .label = try a.dupe(u8, e.value_ptr.string) });
            }
        }
        const projects = root.get("projects") orelse return error.InvalidRegistry;
        if (projects != .object) return error.InvalidRegistry;
        var it = projects.object.iterator();
        while (it.next()) |e| {
            const p = e.value_ptr.*;
            if (p != .object) return error.InvalidRegistry;
            const id = p.object.get("id") orelse return error.InvalidRegistry;
            const label = p.object.get("label") orelse return error.InvalidRegistry;
            const services = p.object.get("services") orelse return error.InvalidRegistry;
            if (id != .string or label != .string or services != .array) return error.InvalidRegistry;
            var project: ProjectName = .{ .cwd = try a.dupe(u8, e.key_ptr.*), .id = try a.dupe(u8, id.string), .label = try a.dupe(u8, label.string) };
            errdefer project.services.deinit(c.gpa);
            for (services.array.items) |s| {
                if (s != .object) return error.InvalidRegistry;
                const sid = s.object.get("id") orelse return error.InvalidRegistry;
                const fp = s.object.get("fingerprint") orelse return error.InvalidRegistry;
                const sl = s.object.get("label") orelse return error.InvalidRegistry;
                if (sid != .string or fp != .string or sl != .string) return error.InvalidRegistry;
                try project.services.append(c.gpa, .{ .id = try a.dupe(u8, sid.string), .fingerprint = try a.dupe(u8, fp.string), .label = try a.dupe(u8, sl.string) });
            }
            try c.projects.append(c.gpa, project);
        }
    }

    fn lessByCwd(_: void, a: ProjectName, b: ProjectName) bool {
        return std.mem.order(u8, a.cwd, b.cwd) == .lt;
    }

    /// `previews.json` as serde writes `Names` (snake_case, maps sorted).
    pub fn namesJson(c: *Catalog, gpa: Allocator) ![]u8 {
        var aw: Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\n  \"device_label\": {f},\n  \"peer_labels\": {{", .{json.fmt(c.device_label, .{})});
        for (c.peer_labels.items, 0..) |p, i| {
            try w.print("{s}\n    {f}: {f}", .{ if (i == 0) "" else ",", json.fmt(p.device, .{}), json.fmt(p.label, .{}) });
        }
        try w.writeAll(if (c.peer_labels.items.len == 0) "},\n  \"projects\": {" else "\n  },\n  \"projects\": {");
        std.mem.sort(ProjectName, c.projects.items, {}, lessByCwd);
        for (c.projects.items, 0..) |p, i| {
            try w.print("{s}\n    {f}: {{\n      \"id\": {f},\n      \"label\": {f},\n      \"services\": [", .{
                if (i == 0) "" else ",", json.fmt(p.cwd, .{}), json.fmt(p.id, .{}), json.fmt(p.label, .{}),
            });
            for (p.services.items, 0..) |s, j| {
                try w.print("{s}\n        {{\n          \"id\": {f},\n          \"fingerprint\": {f},\n          \"label\": {f}\n        }}", .{
                    if (j == 0) "" else ",", json.fmt(s.id, .{}), json.fmt(s.fingerprint, .{}), json.fmt(s.label, .{}),
                });
            }
            try w.writeAll(if (p.services.items.len == 0) "]\n    }" else "\n      ]\n    }");
        }
        try w.writeAll(if (c.projects.items.len == 0) "}\n}" else "\n  }\n}");
        return aw.toOwnedSlice();
    }

    fn persist(c: *Catalog) !void {
        const file = c.file orelse return;
        const bytes = try c.namesJson(c.gpa);
        defer c.gpa.free(bytes);
        if (std.fs.path.dirname(file)) |parent| try Io.Dir.cwd().createDirPath(c.io, parent);
        const pid: i64 = if (comptime @import("builtin").os.tag == .windows) 0 else std.c.getpid();
        const stem = if (std.mem.endsWith(u8, file, ".json")) file[0 .. file.len - 5] else file;
        const tmp = try std.fmt.allocPrint(c.gpa, "{s}.{d}.tmp", .{ stem, pid });
        defer c.gpa.free(tmp);
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = tmp, .data = bytes });
        try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), file, c.io);
    }

    pub fn lock(c: *Catalog) void {
        c.mutex.lockUncancelable(c.io);
    }

    pub fn unlock(c: *Catalog) void {
        c.mutex.unlock(c.io);
    }

    pub fn setProxyStatus(c: *Catalog, port: u16, err: ?[]const u8) void {
        c.lock();
        defer c.unlock();
        c.proxy_port = port;
        if (c.err) |e| c.gpa.free(e);
        c.err = if (err) |e| c.gpa.dupe(u8, e) catch null else null;
        c.publish() catch {};
    }

    pub fn proxyPort(c: *Catalog) u16 {
        c.lock();
        defer c.unlock();
        return c.proxy_port;
    }

    /// The local route a hostname names (a copy in `a`), when one is live.
    pub fn routeByHostname(c: *Catalog, a: Allocator, hostname: []const u8) !?LocalRoute {
        c.lock();
        defer c.unlock();
        for (c.routes) |r| {
            if (std.mem.eql(u8, r.service.hostname, hostname)) {
                return .{ .service = r.service, .listener = try r.listener.dupe(a) };
            }
        }
        return null;
    }

    pub fn hasHostname(c: *Catalog, hostname: []const u8) bool {
        c.lock();
        defer c.unlock();
        for (c.routes) |r| if (std.mem.eql(u8, r.service.hostname, hostname)) return true;
        return false;
    }

    fn lessService(_: void, a: Service, b: Service) bool {
        inline for (.{ "device_id", "project_cwd" }) |f| {
            const o = std.mem.order(u8, @field(a, f), @field(b, f));
            if (o != .eq) return o == .lt;
        }
        const af = !isFrontend(a.name);
        const bf = !isFrontend(b.name);
        if (af != bf) return !af;
        if (a.hostname.len != b.hostname.len) return a.hostname.len < b.hostname.len;
        return std.mem.order(u8, a.hostname, b.hostname) == .lt;
    }

    /// Caller holds the lock.
    fn publish(c: *Catalog) !void {
        const services = try c.gpa.alloc(Service, c.routes.len);
        errdefer c.gpa.free(services);
        for (c.routes, 0..) |r, i| services[i] = r.service;
        std.mem.sort(Service, services, {}, lessService);
        var aw: Io.Writer.Allocating = .init(c.gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeByte('[');
        for (services, 0..) |s, i| {
            if (i > 0) try w.writeByte(',');
            try s.writeJson(w);
        }
        try w.print("],{d},{f}", .{ c.proxy_port, json.fmt(c.err, .{}) });
        const next = try aw.toOwnedSlice();
        c.gpa.free(c.published);
        c.published = services;
        if (!std.mem.eql(u8, next, c.published_json)) c.seq += 1;
        c.gpa.free(c.published_json);
        c.published_json = next;
    }

    pub fn changeSeq(c: *Catalog) u64 {
        c.lock();
        defer c.unlock();
        return c.seq;
    }

    fn lessObservation(_: void, a: Observation, b: Observation) bool {
        const ro = pathOrder(a.root, b.root);
        if (ro != .eq) return ro == .lt;
        const ar = framework(a.listener.args).rank;
        const br = framework(b.listener.args).rank;
        if (ar != br) return ar > br;
        if (a.listener.harness_owned != b.listener.harness_owned) return a.listener.harness_owned;
        if (a.listener.started_at != b.listener.started_at) return a.listener.started_at < b.listener.started_at;
        if (a.listener.pid != b.listener.pid) return a.listener.pid < b.listener.pid;
        return a.listener.address.order(b.listener.address) == .lt;
    }

    fn projectIndex(c: *Catalog, cwd: []const u8) ?usize {
        for (c.projects.items, 0..) |p, i| if (std.mem.eql(u8, p.cwd, cwd)) return i;
        return null;
    }

    /// Input has already passed cwd association and an HTTP probe.
    pub fn replaceLocal(c: *Catalog, observations_in: []const Observation) !void {
        const gpa = c.gpa;
        const observations = try gpa.dupe(Observation, observations_in);
        defer gpa.free(observations);
        std.mem.sort(Observation, observations, {}, lessObservation);

        c.lock();
        defer c.unlock();
        const na = c.names_arena.allocator();
        var next_arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer next_arena.deinit();
        const ra = next_arena.allocator();

        var used: std.StringHashMapUnmanaged(void) = .empty;
        defer used.deinit(gpa);
        for (c.projects.items) |p| {
            try used.put(gpa, p.label, {});
            for (p.services.items) |s| try used.put(gpa, s.label, {});
        }
        var next: std.ArrayList(LocalRoute) = .empty;
        defer next.deinit(gpa);
        var changed_names = false;

        for (observations[0..@min(observations.len, max_observations)]) |ob| {
            const l = ob.listener;
            var seen = false;
            for (next.items) |r| {
                if (std.mem.eql(u8, r.service.project_cwd, ob.root) and r.listener.address.port == l.address.port) seen = true;
            }
            if (seen) continue;

            const pi = c.projectIndex(ob.root) orelse blk: {
                var sbuf: [64]u8 = undefined;
                const label = try allocateLabel(na, slug(&sbuf, fileName(ob.root) orelse "project"), &used);
                try used.put(gpa, label, {});
                var id: [36]u8 = undefined;
                uuidV4(c.io, &id);
                try c.projects.append(gpa, .{ .cwd = try na.dupe(u8, ob.root), .id = try na.dupe(u8, &id), .label = label });
                changed_names = true;
                break :blk c.projects.items.len - 1;
            };

            // sha256("{cwd}\0{identity}"), the identity without the port argument.
            var kept: std.ArrayList([]const u8) = .empty;
            defer kept.deinit(gpa);
            for (l.args) |arg| {
                const p = parsesAsPort(arg);
                if (p == null or p.? != l.address.port) try kept.append(gpa, arg);
            }
            const identity = try commandIdentity(gpa, kept.items);
            defer gpa.free(identity);
            var sha = std.crypto.hash.sha2.Sha256.init(.{});
            sha.update(l.cwd);
            sha.update("\x00");
            sha.update(identity);
            var digest: [32]u8 = undefined;
            sha.final(&digest);
            const fingerprint_hex = std.fmt.bytesToHex(digest, .lower);
            const fingerprint: []const u8 = &fingerprint_hex;

            var previous_id: ?[]const u8 = null;
            for (c.routes) |r| {
                if (r.listener.pid == l.pid and r.listener.started_at == l.started_at and r.listener.address.port == l.address.port) {
                    previous_id = r.service.id;
                    break;
                }
            }
            const project = &c.projects.items[pi];
            const taken = struct {
                fn f(routes: []const LocalRoute, id: []const u8) bool {
                    for (routes) |r| if (std.mem.eql(u8, r.service.id, id)) return true;
                    return false;
                }
            }.f;
            var existing: ?[]const u8 = null;
            for (project.services.items) |s| {
                if (std.mem.eql(u8, s.fingerprint, fingerprint) and previous_id != null and
                    std.mem.eql(u8, previous_id.?, s.id) and !taken(next.items, s.id))
                {
                    existing = s.id;
                    break;
                }
            }
            if (existing == null) {
                for (project.services.items) |s| {
                    if (std.mem.eql(u8, s.fingerprint, fingerprint) and !taken(next.items, s.id)) {
                        existing = s.id;
                        break;
                    }
                }
            }
            const fw = framework(l.args);
            const role = serviceRole(l, fw.name);
            const id = existing orelse blk: {
                const label = if (project.services.items.len == 0)
                    project.label
                else lbl: {
                    var sbuf: [64]u8 = undefined;
                    const base = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ project.label, slug(&sbuf, role) });
                    defer gpa.free(base);
                    break :lbl try allocateLabel(na, base, &used);
                };
                try used.put(gpa, label, {});
                var idbuf: [36]u8 = undefined;
                uuidV4(c.io, &idbuf);
                const new_id = try na.dupe(u8, &idbuf);
                try project.services.append(gpa, .{ .id = new_id, .fingerprint = try na.dupe(u8, fingerprint), .label = label });
                changed_names = true;
                break :blk new_id;
            };
            var service_label: []const u8 = "";
            for (project.services.items) |s| {
                if (std.mem.eql(u8, s.id, id)) service_label = s.label;
            }
            const listener = try l.dupe(ra);
            try next.append(gpa, .{
                .service = .{
                    .id = try ra.dupe(u8, id),
                    .project_id = try ra.dupe(u8, project.id),
                    .project_name = try ra.dupe(u8, fileName(ob.root) orelse ""),
                    .project_cwd = try ra.dupe(u8, ob.root),
                    .device_id = try ra.dupe(u8, c.device_id),
                    .device_name = try ra.dupe(u8, c.device_name),
                    .hostname = try std.fmt.allocPrint(ra, "{s}.{s}.localhost", .{ c.device_label, service_label }),
                    .name = try ra.dupe(u8, role),
                    .port = l.address.port,
                    .pid = l.pid,
                    .cwd = listener.cwd,
                    .started_at = l.started_at,
                    .harness_owned = l.harness_owned,
                },
                .listener = listener,
            });
        }
        if (changed_names) try c.persist();
        const routes = try ra.dupe(LocalRoute, next.items);
        c.routes_arena.deinit();
        c.routes_arena = next_arena;
        c.routes = routes;
        try c.publish();
    }

    /// The `PreviewSnapshot` one chat sees: services of `device` whose project
    /// is `cwd`, with this catalog's proxy port and error.
    pub fn viewJson(c: *Catalog, gpa: Allocator, device: []const u8, cwd: ?[]const u8, project_name: ?[]const u8, remote: bool) ![]u8 {
        c.lock();
        defer c.unlock();
        var aw: Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"services\":[");
        var n: usize = 0;
        for (c.published) |s| {
            if (!std.mem.eql(u8, s.device_id, device)) continue;
            const want = cwd orelse continue;
            if (pathOrder(want, s.project_cwd) != .eq) continue;
            if (n > 0) try w.writeByte(',');
            try s.writeJson(w);
            n += 1;
        }
        try w.print("],\"proxyPort\":{d},\"error\":{f},\"projectName\":{f},\"remote\":{}}}", .{
            c.proxy_port, json.fmt(c.err, .{}), json.fmt(project_name, .{}), remote,
        });
        return aw.toOwnedSlice();
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn server(port: u16, pid: u32, command: []const u8, buf: *[4][]const u8, port_buf: *[8]u8) Listener {
    buf.* = .{ "node", command, "--port", std.fmt.bufPrint(port_buf, "{d}", .{port}) catch unreachable };
    return .{ .pid = pid, .cwd = "/work/my-app", .args = buf, .started_at = pid, .address = .loopback4(port), .harness_owned = true };
}

fn tmpPath(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    return std.fs.path.join(testing.allocator, &.{ dir, name });
}

fn findHost(c: *Catalog, host: []const u8) ?Service {
    for (c.published) |s| if (std.mem.eql(u8, s.hostname, host)) return s;
    return null;
}

test "preview urls survive port changes, restarts and several services" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmpPath(&tmp, "previews.json");
    defer testing.allocator.free(file);
    var b1: [4][]const u8 = undefined;
    var b2: [4][]const u8 = undefined;
    var p1: [8]u8 = undefined;
    var p2: [8]u8 = undefined;

    var ids: [2][36]u8 = undefined;
    var hosts: [2][64]u8 = undefined;
    var host_lens: [2]usize = undefined;
    {
        const c = try Catalog.open(testing.allocator, testing.io, file, "device-id", "MacBook");
        defer c.deinit();
        try c.replaceLocal(&.{
            .{ .root = "/work/my-app", .listener = server(5173, 1, "vite", &b1, &p1) },
            .{ .root = "/work/my-app", .listener = server(3000, 2, "api.js", &b2, &p2) },
        });
        const vite = findHost(c, "macbook.my-app.localhost").?;
        try testing.expectEqual(@as(u16, 5173), vite.port);
        try testing.expectEqualStrings("Vite", vite.name);
        const api = findHost(c, "macbook.my-app-api.localhost").?;
        try testing.expectEqual(@as(u16, 3000), api.port);
        try testing.expectEqualStrings("API", api.name);
        for ([_]Service{ vite, api }, 0..) |s, i| {
            @memcpy(&ids[i], s.id[0..36]);
            @memcpy(hosts[i][0..s.hostname.len], s.hostname);
            host_lens[i] = s.hostname.len;
        }
        try c.replaceLocal(&.{});
        try testing.expectEqual(@as(usize, 0), c.published.len);
    }
    const c = try Catalog.open(testing.allocator, testing.io, file, "device-id", "Renamed computer");
    defer c.deinit();
    try c.replaceLocal(&.{
        .{ .root = "/work/my-app", .listener = server(5174, 3, "vite", &b1, &p1) },
        .{ .root = "/work/my-app", .listener = server(3001, 4, "api.js", &b2, &p2) },
    });
    for (0..2) |i| {
        var found = false;
        for (c.published) |s| {
            if (!std.mem.eql(u8, s.id, &ids[i])) continue;
            found = true;
            try testing.expectEqualStrings(hosts[i][0..host_lens[i]], s.hostname);
            try testing.expect(s.port == 5174 or s.port == 3001);
        }
        try testing.expect(found);
    }
}

test "preview hostnames cannot address arbitrary hosts" {
    for ([_][]const u8{ "localhost", "foo.localhost.evil.test", "a..localhost", "a.b.localhost:80", "a.b.localhost/path", "a.b.c.localhost", "-a.b.localhost", "A.b.localhost" }) |h| {
        try testing.expect(!validHostname(h));
    }
    try testing.expect(validHostname("macbook.my-app-api.localhost"));
}

test "preview slug, label allocation and framework labels" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("my-app", slug(&buf, "My App!"));
    try testing.expectEqualStrings("project", slug(&buf, "—"));
    try testing.expectEqualStrings("macbook-pro", slug(&buf, "MacBook Pro"));
    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(testing.allocator);
    try used.put(testing.allocator, "app", {});
    try used.put(testing.allocator, "app-2", {});
    const l = try allocateLabel(testing.allocator, "app", &used);
    defer testing.allocator.free(l);
    try testing.expectEqualStrings("app-3", l);
    try testing.expectEqualStrings("Vite", framework(&.{ "node", "/x/node_modules/.bin/vite" }).name);
    try testing.expectEqualStrings("Next.js", framework(&.{ "node", "/x/node_modules/next/dist/bin/next" }).name);
    try testing.expectEqual(@as(u8, 80), framework(&.{"miniflare"}).rank);
    try testing.expectEqualStrings("Node HTTP server", framework(&.{ "/usr/bin/node", "server.js" }).name);
    try testing.expectEqualStrings("HTTP server", framework(&.{ "python3", "-m", "http.server" }).name);
}

test "preview service identity ignores port configuration" {
    const a = testing.allocator;
    const x = try commandIdentity(a, &.{ "node", "api.js", "--port", "3000" });
    defer a.free(x);
    const y = try commandIdentity(a, &.{ "node", "api.js", "--port", "3001" });
    defer a.free(y);
    const z = try commandIdentity(a, &.{ "node", "docs.js" });
    defer a.free(z);
    try testing.expectEqualStrings(x, y);
    try testing.expect(!std.mem.eql(u8, x, z));
    const py = try commandIdentity(a, &.{ "python3", "-m", "http.server", "8000" });
    defer a.free(py);
    try testing.expectEqualStrings("python3\x00-m\x00http.server", py);
}

test "preview paths compare by component" {
    try testing.expect(pathStartsWith("/a/b/c", "/a/b"));
    try testing.expect(!pathStartsWith("/a/bc", "/a/b"));
    try testing.expect(pathOrder("/a/b", "/a-c") == .lt);
    try testing.expectEqual(@as(usize, 3), pathComponents("/a/b"));
}

test "a confirmed http server is never probed again; silent ones back off; new sockets settle first" {
    const a = testing.allocator;
    var m: ProbeMemory = .{};
    defer m.deinit(a);
    const l7: Listener = .{ .pid = 7, .cwd = "/work/app", .args = &.{"node"}, .started_at = 1000, .address = .loopback4(8081) };
    const obs = [_]Observation{.{ .root = "/work/app", .listener = l7 }};
    var out: [1]ProbeMemory.Plan = undefined;
    // First sight skips probing until probe_settle_ms has elapsed.
    const settle_at = m.plan(a, &obs, 0, &out);
    try testing.expectEqual(ProbeMemory.Plan.skip, out[0]);
    try testing.expectEqual(@as(?i64, ProbeMemory.probe_settle_ms), settle_at);
    _ = m.plan(a, &obs, ProbeMemory.probe_settle_ms - 1, &out);
    try testing.expectEqual(ProbeMemory.Plan.skip, out[0]);
    _ = m.plan(a, &obs, ProbeMemory.probe_settle_ms, &out);
    try testing.expectEqual(ProbeMemory.Plan.probe, out[0]);
    try m.record(a, l7, true, ProbeMemory.probe_settle_ms);
    for (1..1000) |cycle| {
        _ = m.plan(a, &obs, ProbeMemory.probe_settle_ms + 2000 * @as(i64, @intCast(cycle)), &out);
        try testing.expectEqual(ProbeMemory.Plan.known, out[0]);
    }
    var silent: ProbeMemory = .{};
    defer silent.deinit(a);
    try silent.record(a, l7, false, 0);
    _ = silent.plan(a, &obs, 2000, &out);
    try testing.expectEqual(ProbeMemory.Plan.skip, out[0]);
    _ = silent.plan(a, &obs, 5000, &out);
    try testing.expectEqual(ProbeMemory.Plan.probe, out[0]);
    try silent.record(a, l7, false, 5000);
    _ = silent.plan(a, &obs, 10_000, &out);
    try testing.expectEqual(ProbeMemory.Plan.skip, out[0]);
    // Another process on the same port carries no verdict over and settles afresh.
    var l8 = l7;
    l8.pid = 8;
    const obs8 = [_]Observation{.{ .root = "/work/app", .listener = l8 }};
    _ = silent.plan(a, &obs8, 10_000, &out);
    try testing.expectEqual(ProbeMemory.Plan.skip, out[0]);
    _ = silent.plan(a, &obs8, 10_000 + ProbeMemory.probe_settle_ms, &out);
    try testing.expectEqual(ProbeMemory.Plan.probe, out[0]);
    // Test runner fixtures are never probed, even after settling.
    const test_l: Listener = .{ .pid = 9, .cwd = "/work/app", .args = &.{ "cargo", "test", "--lib" }, .started_at = 1000, .address = .loopback4(8099) };
    try testing.expect(test_l.isTestRun());
    const obs_test = [_]Observation{.{ .root = "/work/app", .listener = test_l }};
    _ = silent.plan(a, &obs_test, 20_000, &out);
    try testing.expectEqual(ProbeMemory.Plan.skip, out[0]);
    _ = silent.plan(a, &obs_test, 30_000, &out);
    try testing.expectEqual(ProbeMemory.Plan.skip, out[0]);
    // Capped backoff: still retried once per max backoff.
    var capped: ProbeMemory = .{};
    defer capped.deinit(a);
    var now: i64 = 0;
    for (0..20) |_| {
        try capped.record(a, l7, false, now);
        now += ProbeMemory.max_backoff_ms;
    }
    _ = capped.plan(a, &obs, now, &out);
    try testing.expectEqual(ProbeMemory.Plan.probe, out[0]);
}

test "an invalid preview registry is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "previews.json", .data = "{\"device_label\":3}" });
    const file = try tmpPath(&tmp, "previews.json");
    defer testing.allocator.free(file);
    try testing.expectError(error.InvalidRegistry, Catalog.open(testing.allocator, testing.io, file, "d", "Mac"));
}
