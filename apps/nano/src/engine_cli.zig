//! `harness-engine`'s command line besides `headless`: which command was
//! asked for, Harness's data folder, the engine's instance lock, and the
//! one-shot commands `status`, `sync`, `login` and `logout`. Ported from the
//! Rust CLI (`apps/harness/src/main.rs`, `auth_cli.rs`, `paths.rs`,
//! `crates/engine/src/instance_lock.rs`); `daemon` is in engine_daemon.zig.
//!
//! The one-shot commands work on the files a running engine owns
//! (`session.json`), so `login` and `logout` take the same exclusive lock the
//! engine holds for its lifetime and refuse while an engine runs.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const auth_host = @import("auth_host.zig");
const ws = @import("ws.zig");
const io_deadline = @import("io_deadline.zig");

pub const DaemonAction = enum { install, uninstall, start, stop, restart, status };

pub const Command = union(enum) {
    /// Serve the engine on the local socket until stopped.
    headless,
    version,
    help,
    /// Workspace mode, optional auth, and whether an engine is running.
    status,
    /// The running engine's per-room sync state.
    sync,
    login,
    logout,
    /// The MCP server on stdin/stdout.
    mcp,
    /// Install a newer release for this install (`harness update`).
    update,
    daemon: DaemonAction,
};

pub const ParseError = error{ UnknownCommand, MissingDaemonAction, UnknownDaemonAction, UnexpectedArgument };

pub const usage =
    \\Usage: harness-engine [COMMAND]
    \\
    \\Commands:
    \\  headless   Run the engine without a UI (the default)
    \\             `--opt-in AGENT` and HARNESS_OPTED_IN enable off-by-default agents
    \\  login      Sign in and enable sync on the next engine start
    \\  logout     Remove the saved session; the next start is local-only
    \\  status     Show workspace mode, optional auth, and engine status
    \\  sync       Show the running engine's sync state
    \\  mcp        Serve the Harness MCP server on stdin/stdout
    \\  update     Install a newer release for this install
    \\  daemon     install | uninstall | start | stop | restart | status
    \\  version    Print the version
    \\
;

/// The command in `args` (without the program name). No arguments runs the
/// engine, as `harness-engine` is the engine executable; anything unknown is
/// an error rather than a silent engine start.
pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .headless;
    const sub = args[0];
    const rest = args[1..];
    const simple = [_]struct { []const u8, Command }{
        .{ "headless", .headless }, .{ "status", .status },   .{ "sync", .sync },
        .{ "login", .login },       .{ "logout", .logout },   .{ "mcp", .mcp },
        .{ "update", .update },     .{ "version", .version }, .{ "--version", .version },
        .{ "-V", .version },        .{ "help", .help },       .{ "--help", .help },
        .{ "-h", .help },
    };
    for (simple) |entry| {
        if (std.mem.eql(u8, sub, entry[0])) {
            if (rest.len != 0 and entry[1] != .help) return error.UnexpectedArgument;
            return entry[1];
        }
    }
    if (std.mem.eql(u8, sub, "daemon")) {
        if (rest.len == 0) return error.MissingDaemonAction;
        const action = std.meta.stringToEnum(DaemonAction, rest[0]) orelse return error.UnknownDaemonAction;
        if (rest.len > 1) return error.UnexpectedArgument;
        return .{ .daemon = action };
    }
    return error.UnknownCommand;
}

// ---------------------------------------------------------------------------
// The data folder
// ---------------------------------------------------------------------------

/// Where Harness keeps its data, in order of preference (`paths.rs`):
/// `HARNESS_DATA_DIR`, `DATA_DIR`, then the platform default with its legacy
/// name after it (picked only when it exists and the first doesn't).
pub fn dataDirCandidates(gpa: Allocator, env: *const Map, windows: bool) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    for ([_][]const u8{ "HARNESS_DATA_DIR", "DATA_DIR" }) |key| {
        if (env.get(key)) |dir| if (dir.len > 0) {
            try out.append(gpa, try gpa.dupe(u8, dir));
            return out.toOwnedSlice(gpa);
        };
    }
    if (windows) {
        const local: ?[]u8 = if (env.get("LOCALAPPDATA")) |l| (if (l.len > 0) try gpa.dupe(u8, l) else null) else null;
        const base = local orelse if (env.get("USERPROFILE")) |u|
            (if (u.len > 0) try std.fs.path.join(gpa, &.{ u, "AppData", "Local" }) else return error.NoDataDir)
        else
            return error.NoDataDir;
        defer gpa.free(base);
        try out.append(gpa, try std.fs.path.join(gpa, &.{ base, "Harness" }));
        try out.append(gpa, try std.fs.path.join(gpa, &.{ base, "Harnesser" }));
    } else {
        const home = env.get("HOME") orelse return error.NoDataDir;
        if (home.len == 0) return error.NoDataDir;
        try out.append(gpa, try std.fs.path.join(gpa, &.{ home, ".harness" }));
        try out.append(gpa, try std.fs.path.join(gpa, &.{ home, ".harnesser" }));
    }
    return out.toOwnedSlice(gpa);
}

/// The data folder (owned): the first candidate that exists, else the first.
pub fn resolveDataDir(gpa: Allocator, io: Io, env: *const Map) ![]u8 {
    return resolveDataDirFor(gpa, io, env, builtin.os.tag == .windows);
}

/// `resolveDataDir` for the given platform, so a test on any OS can check the
/// Windows answer.
pub fn resolveDataDirFor(gpa: Allocator, io: Io, env: *const Map, windows: bool) ![]u8 {
    const list = try dataDirCandidates(gpa, env, windows);
    defer gpa.free(list);
    var chosen: usize = 0;
    for (list, 0..) |p, i| {
        if (Io.Dir.cwd().access(io, p, .{})) |_| {
            chosen = i;
            break;
        } else |_| {}
    }
    for (list, 0..) |p, i| if (i != chosen) gpa.free(p);
    return list[chosen];
}

// ---------------------------------------------------------------------------
// The instance lock: `{data_dir}/engine.lock`
// ---------------------------------------------------------------------------

pub const lock_name = "engine.lock";
/// Windows locks the file's bytes, so the pid goes beside it (as Rust does).
pub const windows_pid_name = "engine.lock.pid";

/// The exclusive lock one engine holds on its data folder for its lifetime.
/// The kernel drops it when the process ends, however it ends. Compatible
/// with the Rust engine's `flock`, so neither starts over the other.
pub const InstanceLock = struct {
    file: Io.File,

    pub fn acquire(gpa: Allocator, io: Io, data_dir: []const u8) !InstanceLock {
        const path = try std.fs.path.join(gpa, &.{ data_dir, lock_name });
        defer gpa.free(path);
        // A second or so for an engine that is just exiting (`StopEngine`).
        var retries: u32 = 40;
        const file = while (true) {
            break Io.Dir.cwd().createFile(io, path, .{
                .read = true,
                .truncate = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |err| switch (err) {
                error.WouldBlock => {
                    if (retries == 0) return error.AlreadyRunning;
                    retries -= 1;
                    Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
                    continue;
                },
                else => |e| return e,
            };
        };
        var buf: [32]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&buf, "{d}\n", .{currentPid()}) catch unreachable;
        if (comptime builtin.os.tag == .windows) {
            const pid_path = try std.fs.path.join(gpa, &.{ data_dir, windows_pid_name });
            defer gpa.free(pid_path);
            Io.Dir.cwd().writeFile(io, .{ .sub_path = pid_path, .data = pid_text }) catch {};
        } else {
            file.setLength(io, 0) catch {};
            file.writePositionalAll(io, pid_text, 0) catch {};
        }
        return .{ .file = file };
    }

    pub fn release(self: *InstanceLock, io: Io) void {
        self.file.close(io);
        self.* = undefined;
    }
};

pub const Holder = union(enum) {
    none,
    /// Held, by this pid (0 when the file doesn't say).
    pid: i64,
};

/// Whether an engine holds `data_dir`'s lock, without taking it.
pub fn lockHolder(gpa: Allocator, io: Io, data_dir: []const u8) Holder {
    const path = std.fs.path.join(gpa, &.{ data_dir, lock_name }) catch return .none;
    defer gpa.free(path);
    const probe = Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => {
            const pid_file = if (comptime builtin.os.tag == .windows) windows_pid_name else lock_name;
            const pid_path = std.fs.path.join(gpa, &.{ data_dir, pid_file }) catch return .{ .pid = 0 };
            defer gpa.free(pid_path);
            const raw = Io.Dir.cwd().readFileAlloc(io, pid_path, gpa, .limited(64)) catch return .{ .pid = 0 };
            defer gpa.free(raw);
            const pid = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch 0;
            return .{ .pid = pid };
        },
        // No folder, say: nothing can be running on it.
        else => return .none,
    };
    probe.close(io);
    return .none;
}

/// The holder's pid as the Rust engine prints it: `unknown` when the lock
/// file doesn't name one.
pub fn holderPid(buf: *[24]u8, h: Holder) []const u8 {
    return switch (h) {
        .pid => |p| if (p > 0) (std.fmt.bufPrint(buf, "{d}", .{p}) catch "unknown") else "unknown",
        .none => "unknown",
    };
}

/// `InstanceLock::acquire`'s contention error, in the Rust engine's words.
pub fn alreadyRunningText(buf: []u8, data_dir: []const u8, h: Holder) []const u8 {
    var pid_buf: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "another Harness engine is already running on {s} (pid {s}); stop it or use a different data dir (HARNESS_DATA_DIR)", .{ data_dir, holderPid(&pid_buf, h) }) catch
        "another Harness engine is already running; stop it or use a different data dir (HARNESS_DATA_DIR)";
}

/// The engine's start-up lock: the data folder is created, then locked.
/// Either failing stops the engine (`create_dir_all(data_dir)?` and
/// `InstanceLock::acquire(data_dir)?`): it never runs without the lock.
pub fn lockEngineDataDir(gpa: Allocator, io: Io, data_dir: []const u8, msg_buf: []u8) union(enum) { ok: InstanceLock, err: []const u8 } {
    Io.Dir.cwd().createDirPath(io, data_dir) catch |e|
        return .{ .err = std.fmt.bufPrint(msg_buf, "cannot create the data directory {s}: {t}", .{ data_dir, e }) catch "cannot create the data directory" };
    const lock = InstanceLock.acquire(gpa, io, data_dir) catch |e| switch (e) {
        error.AlreadyRunning => return .{ .err = alreadyRunningText(msg_buf, data_dir, lockHolder(gpa, io, data_dir)) },
        else => return .{ .err = std.fmt.bufPrint(msg_buf, "cannot lock the data directory {s}: {t}", .{ data_dir, e }) catch "cannot lock the data directory" },
    };
    return .{ .ok = lock };
}

/// The engine's start-up lock, or the engine stops with the reason.
pub fn lockEngineOrExit(gpa: Allocator, io: Io, data_dir: []const u8) InstanceLock {
    var buf: [1024]u8 = undefined;
    return switch (lockEngineDataDir(gpa, io, data_dir, &buf)) {
        .ok => |l| l,
        .err => |m| fatalStart(io, "{s}", .{m}),
    };
}

/// The engine can't start: the reason on stderr, exit 1.
pub fn fatalStart(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var ew = Io.File.stderr().writerStreaming(io, &buf);
    ew.interface.print("harness-engine: " ++ fmt ++ "\n", args) catch {};
    ew.interface.flush() catch {};
    std.process.exit(1);
}

/// Errors go to stderr, as the Rust CLI's do (`err` when a test captures it).
pub fn printErr(c: Context, comptime fmt: []const u8, args: anytype) !void {
    if (c.err) |w| {
        try w.print(fmt, args);
        try w.flush();
        return;
    }
    var buf: [1024]u8 = undefined;
    var ew = Io.File.stderr().writerStreaming(c.io, &buf);
    try ew.interface.print(fmt, args);
    try ew.interface.flush();
}

fn currentPid() i64 {
    if (comptime builtin.os.tag == .windows) {
        const w = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
        };
        return w.GetCurrentProcessId();
    }
    return std.c.getpid();
}

// ---------------------------------------------------------------------------
// Auth configuration, shared with `headless`
// ---------------------------------------------------------------------------

/// The auth settings an engine start reads from its environment
/// (`engine_config_from_env` in Rust).
pub const AuthEnv = struct {
    /// `HARNESS_AUTH_DISABLED=1`: no CodeGraff at all.
    disabled: bool,
    /// `HARNESS_EDGE_TOKEN`: accepted only with explicit loopback local auth.
    edge_token: ?[]const u8,
    local_edge_auth: bool = false,
    edge_url: []const u8,
    /// Empty `HARNESS_CODEGRAFF_CLIENT_ID` is development mode, as in Rust.
    client_id: []const u8,
    api_base: []const u8,
    gateway: []const u8,

    pub fn from(env: *const Map) AuthEnv {
        const disabled = if (env.get("HARNESS_AUTH_DISABLED")) |v|
            (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true"))
        else
            false;
        const token = if (env.get("HARNESS_EDGE_TOKEN")) |t| (if (t.len > 0) t else null) else null;
        const edge = if (env.get("HARNESS_EDGE_URL")) |u| (if (std.mem.trim(u8, u, " ").len > 0) u else auth_host.default_edge_url) else auth_host.default_edge_url;
        return .{
            .disabled = disabled,
            .local_edge_auth = std.mem.eql(u8, env.get("HARNESS_LOCAL_EDGE_AUTH") orelse "", "1"),
            .edge_token = token,
            .edge_url = edge,
            .client_id = std.mem.trim(u8, env.get("HARNESS_CODEGRAFF_CLIENT_ID") orelse auth_host.default_codegraff_client_id, " \t"),
            .api_base = env.get("HARNESS_CODEGRAFF_API_BASE") orelse auth_host.default_codegraff_api_base,
            .gateway = env.get("HARNESS_CODEGRAFF_GATEWAY") orelse auth_host.default_codegraff_gateway,
        };
    }

    /// Real CodeGraff sign-in, rather than development or no auth.
    pub fn codegraffEnabled(c: AuthEnv) bool {
        return !c.disabled and !c.local_edge_auth and c.edge_token == null and c.client_id.len > 0;
    }
};

pub const Scope = enum {
    local,
    development,
    synced,

    pub fn name(s: Scope) []const u8 {
        return switch (s) {
            .local => "local",
            .development => "development",
            .synced => "synced",
        };
    }

    pub fn parse(text: []const u8) ?Scope {
        return std.meta.stringToEnum(Scope, text);
    }
};

/// The scope an engine start selects (`Engine::initial_workspace_scope`):
/// development without CodeGraff (a dev bearer, an empty client id, or auth
/// turned off); synced with a saved, org-scoped session; local otherwise.
pub fn startScope(cfg: AuthEnv, session_loaded: bool) Scope {
    if (!cfg.codegraffEnabled()) return .development;
    return if (session_loaded) .synced else .local;
}

/// Configures `auth` from `cfg` and loads the saved session, as `headless`
/// does (engine_main.zig); returns `startScope`.
pub fn loadAuth(auth: *auth_host.AuthManager, io: Io, cfg: AuthEnv, data_dir: []const u8) !Scope {
    if (cfg.codegraffEnabled()) {
        try auth.configureCodegraff(cfg.edge_url, cfg.client_id, cfg.api_base, data_dir);
        try auth.setCodegraffGateway(cfg.gateway);
        return startScope(cfg, auth.loadPersistedSession(io));
    }
    // No session to sign in to, but the folder is still the place a stale
    // session file would be cleared from.
    try auth.configureCodegraff(cfg.edge_url, null, cfg.api_base, data_dir);
    return startScope(cfg, false);
}

test "start scope: development without CodeGraff, synced only with a saved session" {
    var env = Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(Scope.local, startScope(AuthEnv.from(&env), false));
    try testing.expectEqual(Scope.synced, startScope(AuthEnv.from(&env), true));
    try env.put("HARNESS_CODEGRAFF_CLIENT_ID", "");
    try testing.expectEqual(Scope.development, startScope(AuthEnv.from(&env), true));
    _ = env.swapRemove("HARNESS_CODEGRAFF_CLIENT_ID");
    try env.put("HARNESS_AUTH_DISABLED", "1");
    try testing.expectEqual(Scope.development, startScope(AuthEnv.from(&env), false));
    _ = env.swapRemove("HARNESS_AUTH_DISABLED");
    try env.put("HARNESS_EDGE_TOKEN", "synthetic-bearer");
    try testing.expectEqual(Scope.development, startScope(AuthEnv.from(&env), false));
}

pub const AccountStatus = struct {
    mode: []const u8,
    /// Owned.
    auth: []u8,
    healthy: bool,
};

/// `account_status` in `auth_cli.rs`: what `status` says about the account.
/// Local-only and signed out is a healthy state.
pub fn accountStatus(gpa: Allocator, scope: Scope, phase: auth_host.AuthPhase, email: []const u8, org: ?[]const u8) !AccountStatus {
    return switch (scope) {
        .local => .{ .mode = "local only", .healthy = true, .auth = switch (phase) {
            .signed_out => try gpa.dupe(u8, "signed out (optional in local-only mode)"),
            .needs_organization => try std.fmt.allocPrint(gpa, "signed in as {s}; finish workspace setup to enable sync", .{email}),
            .signed_in => try std.fmt.allocPrint(gpa, "signed in as {s}; sync is ready after restart", .{email}),
        } },
        .development => .{ .mode = "development", .healthy = true, .auth = try gpa.dupe(u8, "dev mode (bearer = user id)") },
        .synced => switch (phase) {
            .signed_in => .{ .mode = "synced", .healthy = true, .auth = if (org) |o|
                try std.fmt.allocPrint(gpa, "signed in as {s} (workspace {s})", .{ email, o })
            else
                try std.fmt.allocPrint(gpa, "signed in as {s}", .{email}) },
            .needs_organization => .{ .mode = "synced", .healthy = false, .auth = try std.fmt.allocPrint(gpa, "signed in as {s} but no workspace selected — run `harness-engine login`", .{email}) },
            .signed_out => .{ .mode = "synced", .healthy = false, .auth = try gpa.dupe(u8, "saved session is no longer valid — run `harness-engine login`") },
        },
    };
}

/// OAuth codes and refresh tokens travel over TLS only; plain HTTP is for a
/// development edge on a numeric loopback address (`validate_secure_url`).
pub const isSecureUrl = auth_host.isSecureUrl;

// ---------------------------------------------------------------------------
// One RPC to the running engine
// ---------------------------------------------------------------------------

pub const Reply = union(enum) {
    /// The `ok` value, as JSON (owned).
    ok: []u8,
    /// The `err` text (owned).
    err: []u8,

    pub fn deinit(r: Reply, gpa: Allocator) void {
        switch (r) {
            inline else => |s| gpa.free(s),
        }
    }
};

/// Calls `method` on the engine at `127.0.0.1:port` and waits at most
/// `timeout_ms` for its reply. `error.NoEngine` when nothing answers.
pub fn rpcCall(gpa: Allocator, io: Io, port: u16, method: []const u8, params_json: []const u8, timeout_ms: u32) !Reply {
    return rpcCallWithBearer(gpa, io, port, null, method, params_json, timeout_ms);
}

pub fn rpcCallWithBearer(gpa: Allocator, io: Io, port: u16, bearer: ?[]const u8, method: []const u8, params_json: []const u8, timeout_ms: u32) !Reply {
    // A loopback connect is answered at once (accepted or refused); the
    // handshake runs under the call's deadline, so an engine that accepts
    // and never upgrades can't hang the command.
    const addr = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return error.NoEngine;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return error.NoEngine;
    const upgraded = if (comptime builtin.os.tag == .windows) blk: {
        const outcome = io_deadline.run(io, timeout_ms, null, ws.Client.upgradeWithBearer, .{ gpa, io, stream, port, "/", bearer }) catch {
            // No task was scheduled, so ownership of the connected stream
            // has not transferred to upgradeWithBearer.
            stream.close(io);
            return error.NoEngine;
        };
        switch (outcome) {
            .finished => |result| break :blk result,
            .timed_out => |result| {
                if (result) |late| late.deinit(gpa) else |_| {}
                return error.Timeout;
            },
            .canceled => |result| {
                if (result) |late| late.deinit(gpa) else |_| {}
                return error.NoEngine;
            },
        }
    } else blk: {
        var hs_dog: auth_host.SocketWatchdog = .{ .io = io, .stream = stream, .ms = timeout_ms };
        hs_dog.arm();
        const result = ws.Client.upgradeWithBearer(gpa, io, stream, port, "/", bearer);
        if (hs_dog.disarm()) {
            if (result) |late| late.deinit(gpa) else |_| {}
            return error.Timeout;
        }
        break :blk result;
    };
    const client = upgraded catch return error.NoEngine;
    defer client.deinit(gpa);

    if (comptime builtin.os.tag == .windows) {
        const outcome = io_deadline.run(io, timeout_ms, null, rpcExchange, .{ gpa, client, method, params_json }) catch return error.NoEngine;
        return switch (outcome) {
            .finished => |result| result catch error.NoEngine,
            .timed_out => |result| blk: {
                if (result) |reply| reply.deinit(gpa) else |_| {}
                break :blk error.Timeout;
            },
            .canceled => |result| blk: {
                if (result) |reply| reply.deinit(gpa) else |_| {}
                break :blk error.NoEngine;
            },
        };
    }

    const Watchdog = struct {
        done: std.atomic.Value(bool) = .init(false),
        fired: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This(), c: *ws.Client, wio: Io, ms: u32) void {
            var waited: u32 = 0;
            while (waited < ms) : (waited += 10) {
                if (self.done.load(.acquire)) return;
                Io.sleep(wio, .fromMilliseconds(10), .awake) catch return;
            }
            self.fired.store(true, .release);
            c.shutdown();
        }
    };
    var dog: Watchdog = .{};
    const thread = std.Thread.spawn(.{}, Watchdog.run, .{ &dog, client, io, timeout_ms }) catch return error.NoEngine;
    defer {
        dog.done.store(true, .release);
        thread.join();
    }
    const result = rpcExchange(gpa, client, method, params_json);
    if (dog.fired.load(.acquire)) {
        if (result) |reply| reply.deinit(gpa) else |_| {}
        return error.Timeout;
    }
    return result catch error.NoEngine;
}

fn rpcExchange(gpa: Allocator, client: *ws.Client, method: []const u8, params_json: []const u8) !Reply {
    const req = try std.fmt.allocPrint(gpa, "{{\"id\":1,\"method\":{f},\"params\":{s}}}", .{ json.fmt(method, .{}), params_json });
    defer gpa.free(req);
    client.sendText(req) catch return error.NoEngine;

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    while (true) {
        const op = client.readMessage(gpa, &msg) catch return error.NoEngine;
        if (op != .text) continue;
        var lines = std.mem.splitScalar(u8, msg.items, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
            var parsed = json.parseFromSlice(json.Value, gpa, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const id = obj.get("id") orelse continue;
            if (id != .integer or id.integer != 1) continue;
            if (obj.get("ok")) |v| return .{ .ok = try json.Stringify.valueAlloc(gpa, v, .{}) };
            if (obj.get("item")) |v| return .{ .ok = try json.Stringify.valueAlloc(gpa, v, .{}) };
            if (obj.get("err")) |v| return .{ .err = if (v == .string) try gpa.dupe(u8, v.string) else try json.Stringify.valueAlloc(gpa, v, .{}) };
        }
    }
}

fn ipcListening(io: Io, port: u16) bool {
    const addr = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return false;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

// ---------------------------------------------------------------------------
// The commands
// ---------------------------------------------------------------------------

pub const Context = struct {
    gpa: Allocator,
    io: Io,
    env: *const Map,
    port: u16,
    out: *Io.Writer,
    /// Lines typed at the terminal, for `login`.
    in: *Io.Reader,
    interactive: bool,
    /// Where errors go; null: this process's stderr.
    err: ?*Io.Writer = null,
};

/// Whether `path` is a git checkout (`.git` is a folder, or a file for a
/// linked worktree), for the engine's default project.
pub fn gitDetected(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer dir.close(io);
    _ = dir.statFile(io, ".git", .{}) catch return false;
    return true;
}

pub const LiveAuth = struct {
    phase: auth_host.AuthPhase,
    email: []u8,
    org_id: ?[]u8,

    pub fn deinit(self: *LiveAuth, gpa: Allocator) void {
        gpa.free(self.email);
        if (self.org_id) |o| gpa.free(o);
    }
};

fn parseUserOrg(gpa: Allocator, obj: json.ObjectMap, phase: auth_host.AuthPhase, keep_org: bool) !?LiveAuth {
    const user_val = obj.get("user") orelse return null;
    if (user_val != .object) return null;
    const email_val = user_val.object.get("email") orelse return null;
    if (email_val != .string) return null;
    const org: ?[]const u8 = if (keep_org) blk: {
        const ov = obj.get("orgId") orelse break :blk null;
        break :blk if (ov == .string and ov.string.len > 0) ov.string else null;
    } else null;
    const email = try gpa.dupe(u8, email_val.string);
    errdefer gpa.free(email);
    return .{
        .phase = phase,
        .email = email,
        .org_id = if (org) |o| try gpa.dupe(u8, o) else null,
    };
}

/// Parses an `AuthStatus` stream item (`signedOut`, `needsOrganization`, `signedIn`).
pub fn parseAuthStatusValue(gpa: Allocator, v: json.Value) !?LiveAuth {
    if (v != .object) return null;
    const obj = v.object;
    const state_val = obj.get("state") orelse return null;
    if (state_val != .string) return null;
    const state = state_val.string;
    if (std.mem.eql(u8, state, "signedOut")) {
        return .{ .phase = .signed_out, .email = try gpa.dupe(u8, ""), .org_id = null };
    }
    if (std.mem.eql(u8, state, "needsOrganization")) {
        return try parseUserOrg(gpa, obj, .needs_organization, false);
    }
    if (std.mem.eql(u8, state, "signedIn")) {
        return try parseUserOrg(gpa, obj, .signed_in, true);
    }
    return null;
}

fn isValidSandboxToken(tok: []const u8) bool {
    const prefix = "cg_lt_";
    if (!std.mem.startsWith(u8, tok, prefix)) return false;
    const hex = tok[prefix.len..];
    if (hex.len != 48) return false;
    for (hex) |b| if (!std.ascii.isHex(b)) return false;
    return true;
}

/// Extracts a sandbox lease token (`cg_lt_` + 48 hex chars) from `{token_path}` content:
/// JSON `{"apiKey": ...}` / `{"token": ...}`, or raw text (`read_sandbox_token` in `auth.rs`).
pub fn parseSandboxTokenAlloc(gpa: Allocator, raw: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return if (isValidSandboxToken(trimmed)) try gpa.dupe(u8, trimmed) else null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const tok_val = parsed.value.object.get("apiKey") orelse parsed.value.object.get("token") orelse return null;
    if (tok_val != .string) return null;
    return if (isValidSandboxToken(tok_val.string)) try gpa.dupe(u8, tok_val.string) else null;
}

fn fetchSandboxAuth(gpa: Allocator, io: Io, edge_url: []const u8, token_path: []const u8) !?LiveAuth {
    const raw = Io.Dir.cwd().readFileAlloc(io, token_path, gpa, .limited(4096)) catch return null;
    defer gpa.free(raw);
    const token = (try parseSandboxTokenAlloc(gpa, raw)) orelse return null;
    defer gpa.free(token);
    const base = std.mem.trimEnd(u8, edge_url, "/");
    const url = try std.fmt.allocPrint(gpa, "{s}/auth/sandbox", .{base});
    defer gpa.free(url);
    const req_body = try std.fmt.allocPrint(gpa, "{{\"token\":{f}}}", .{json.fmt(token, .{})});
    defer gpa.free(req_body);
    var reply = auth_host.AuthManager.edgeRequestTimed(null, gpa, io, "POST", url, null, &.{}, req_body, 5000) catch return null;
    defer reply.deinit(gpa);
    if (reply.status < 200 or reply.status >= 300) return null;
    var parsed = json.parseFromSlice(json.Value, gpa, reply.body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const has_org = if (obj.get("orgId")) |ov| (ov == .string and ov.string.len > 0) else false;
    return try parseUserOrg(gpa, obj, if (has_org) .signed_in else .needs_organization, has_org);
}

/// `harness-engine status`; the exit code (1 when the account needs attention).
pub fn status(c: Context) !u8 {
    const data_dir = try resolveDataDir(c.gpa, c.io, c.env);
    defer c.gpa.free(data_dir);
    const cfg = AuthEnv.from(c.env);

    const ipc_token = ws.resolveIpcToken(c.gpa, c.io, c.env.get("HARNESS_IPC_TOKEN"), data_dir, c.port, false);
    defer if (ipc_token) |t| c.gpa.free(t);

    // A running engine's scope and auth state are authoritative over local session files
    // (critical on sandboxes and Cloud Computers where auth comes from a lease token).
    var live_scope: ?Scope = null;
    if (rpcCallWithBearer(c.gpa, c.io, c.port, ipc_token, "EngineInfo", "{}", 1500)) |reply| {
        defer reply.deinit(c.gpa);
        if (reply == .ok) if (json.parseFromSlice(json.Value, c.gpa, reply.ok, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) if (parsed.value.object.get("workspaceScope")) |s| {
                if (s == .string) if (Scope.parse(s.string)) |live| {
                    live_scope = live;
                };
            };
        } else |_| {};
    } else |_| {}

    var live_auth: ?LiveAuth = null;
    defer if (live_auth) |*la| la.deinit(c.gpa);
    if (rpcCallWithBearer(c.gpa, c.io, c.port, ipc_token, "AuthStatus", "{}", 1500)) |reply| {
        defer reply.deinit(c.gpa);
        if (reply == .ok) if (json.parseFromSlice(json.Value, c.gpa, reply.ok, .{})) |parsed| {
            defer parsed.deinit();
            live_auth = parseAuthStatusValue(c.gpa, parsed.value) catch null;
        } else |_| {};
    } else |_| {}

    const sandbox_token_file: ?[]const u8 = if (c.env.get("HARNESS_SANDBOX_TOKEN_FILE")) |p| blk: {
        const t = std.mem.trim(u8, p, " \t\r\n");
        break :blk if (t.len > 0) t else null;
    } else null;

    var auth = try auth_host.AuthManager.init(c.gpa);
    defer auth.deinit();
    var sandbox_auth: ?LiveAuth = null;
    defer if (sandbox_auth) |*sa| sa.deinit(c.gpa);

    var scope: Scope = undefined;
    var phase: auth_host.AuthPhase = undefined;
    var email: []const u8 = undefined;
    var org_id: ?[]const u8 = null;

    if (live_auth) |la| {
        phase = la.phase;
        email = la.email;
        org_id = la.org_id;
        scope = live_scope orelse (if (!cfg.codegraffEnabled()) .development else if (la.phase == .signed_in) .synced else .local);
    } else if (cfg.codegraffEnabled() and sandbox_token_file != null) {
        sandbox_auth = try fetchSandboxAuth(c.gpa, c.io, cfg.edge_url, sandbox_token_file.?);
        if (sandbox_auth) |sa| {
            phase = sa.phase;
            email = sa.email;
            org_id = sa.org_id;
            scope = live_scope orelse if (sa.phase == .signed_in) .synced else .local;
        } else {
            phase = .signed_out;
            email = "";
            org_id = null;
            scope = live_scope orelse .local;
        }
    } else {
        const loaded_scope = try loadAuth(&auth, c.io, cfg, data_dir);
        scope = live_scope orelse loaded_scope;
        phase = auth.phase;
        email = auth.email;
        org_id = auth.org_id;
    }

    const account = try accountStatus(c.gpa, scope, phase, email, org_id);
    defer c.gpa.free(account.auth);
    try c.out.print("Data dir: {s}\nEdge:     {s}\nMode:     {s}\nAuth:     {s}\n", .{ data_dir, cfg.edge_url, account.mode, account.auth });
    switch (lockHolder(c.gpa, c.io, data_dir)) {
        .none => try c.out.writeAll("Engine:   not running\n"),
        .pid => |pid| if (pid > 0)
            try c.out.print("Engine:   running (pid {d})\n", .{pid})
        else
            try c.out.writeAll("Engine:   running (pid unknown)\n"),
    }
    try c.out.print("IPC:      {s} 127.0.0.1:{d}\n", .{ if (ipcListening(c.io, c.port)) "listening on" else "not listening on", c.port });
    try c.out.flush();
    return if (account.healthy) 0 else 1;
}

/// `harness-engine sync`: the running engine's per-room sync state.
pub fn sync(c: Context) !u8 {
    const data_dir = resolveDataDir(c.gpa, c.io, c.env) catch null;
    defer if (data_dir) |d| c.gpa.free(d);
    const ipc_token = ws.resolveIpcToken(c.gpa, c.io, c.env.get("HARNESS_IPC_TOKEN"), data_dir, c.port, false);
    defer if (ipc_token) |t| c.gpa.free(t);
    const reply = rpcCallWithBearer(c.gpa, c.io, c.port, ipc_token, "SyncStatus", "{}", 5000) catch |err| {
        try c.out.print("harness-engine: no engine listening on 127.0.0.1:{d} ({t}) — is Harness running?\n", .{ c.port, err });
        try c.out.flush();
        return 1;
    };
    defer reply.deinit(c.gpa);
    switch (reply) {
        .err => |e| {
            try c.out.print("harness-engine: SyncStatus failed: {s}\n", .{e});
            try c.out.flush();
            return 1;
        },
        .ok => |body| {
            var parsed = try json.parseFromSlice(json.Value, c.gpa, body, .{});
            defer parsed.deinit();
            try formatSyncStatus(c.out, parsed.value);
            try c.out.flush();
            return 0;
        },
    }
}

fn int(v: ?json.Value) i64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn connectedMark(room: json.ObjectMap) []const u8 {
    const c = room.get("connected") orelse return "DISCONNECTED ·";
    return if (c == .bool and c.bool) "connected ·" else "DISCONNECTED ·";
}

const Age = struct {
    now: i64,
    ms: i64,
    pub fn format(a: Age, w: *Io.Writer) Io.Writer.Error!void {
        if (a.ms <= 0) return w.writeAll("never");
        const s = @divTrunc(@max(a.now - a.ms, 0), 1000);
        if (s >= 3600) return w.print("{d}h{d}m ago", .{ @divTrunc(s, 3600), @divTrunc(@mod(s, 3600), 60) });
        if (s >= 60) return w.print("{d}m{d}s ago", .{ @divTrunc(s, 60), @mod(s, 60) });
        return w.print("{d}s ago", .{s});
    }
};

/// `sync_cli`'s readout, from a `SyncStatus` reply.
pub fn formatSyncStatus(w: *Io.Writer, status_val: json.Value) !void {
    if (status_val != .object) return error.BadReply;
    const st = status_val.object;
    const now = int(st.get("nowMs"));
    const device = if (st.get("deviceId")) |d| (if (d == .string) d.string else "?") else "?";
    try w.print("Device:    {s}\n", .{device});
    try w.writeAll("Workspace: ");
    if (st.get("workspace")) |room_v| if (room_v == .object) {
        const room = room_v.object;
        const rejected = int(room.get("rejected"));
        try w.print("{s} pushed {f} · acked {f} · rejoins {d} probes {d} resyncs {d} drops {d}", .{
            connectedMark(room),
            Age{ .now = now, .ms = int(room.get("lastPushedMs")) },
            Age{ .now = now, .ms = int(room.get("lastAckMs")) },
            int(room.get("rejoins")),
            int(room.get("probes")),
            int(room.get("fullResyncs")),
            int(room.get("disconnects")),
        });
        if (rejected > 0) try w.print(" REJECTED {d}", .{rejected});
        try w.writeAll("\n");
    } else try w.writeAll("no room (dialing or edge-less)\n") else try w.writeAll("no room (dialing or edge-less)\n");
    const chats: []const json.Value = if (st.get("chats")) |cv| (if (cv == .array) cv.array.items else &.{}) else &.{};
    if (chats.len == 0) try w.writeAll("Chats:     none open\n");
    for (chats) |chat_v| {
        if (chat_v != .object) continue;
        const chat = chat_v.object;
        const id = if (chat.get("chatId")) |v| (if (v == .string) v.string else "?") else "?";
        try w.print("Chat {s}: ", .{id[0..@min(id.len, 8)]});
        const room_v = chat.get("room") orelse json.Value.null;
        if (room_v != .object) {
            try w.writeAll("no room (dialing or edge-less)\n");
            continue;
        }
        const room = room_v.object;
        const resets = int(room.get("serverResets"));
        const rejected = int(room.get("rejected"));
        try w.print("{s} cursor {d}/{d} · pending {d} · rows {d} ({d}KB) · rejoins {d} drops {d}", .{
            connectedMark(room),
            int(room.get("cursor")),
            int(room.get("headSeq")),
            int(room.get("pendingPushes")),
            int(room.get("rowCount")),
            @divTrunc(int(room.get("rowBytes")), 1024),
            int(room.get("rejoins")),
            int(room.get("disconnects")),
        });
        if (resets > 0) try w.print(" RESETS {d}", .{resets});
        if (rejected > 0) try w.print(" REJECTED {d}", .{rejected});
        try w.writeAll("\n");
    }
}

fn lockForChange(c: Context, data_dir: []const u8, verb: []const u8) !?InstanceLock {
    return InstanceLock.acquire(c.gpa, c.io, data_dir) catch |err| switch (err) {
        error.AlreadyRunning => {
            var buf: [1024]u8 = undefined;
            try c.out.flush();
            try printErr(
                c,
                "harness-engine: {s}\n" ++
                    "Cannot {s} while an engine is running — stop it first (`harness-engine daemon stop`, or quit the Harness app), or use the running app instead.\n",
                .{ alreadyRunningText(&buf, data_dir, lockHolder(c.gpa, c.io, data_dir)), verb },
            );
            return null;
        },
        else => |e| return e,
    };
}

/// `harness-engine logout`: removes the saved session; the next engine start
/// is local-only.
pub fn logout(c: Context) !u8 {
    const data_dir = try resolveDataDir(c.gpa, c.io, c.env);
    defer c.gpa.free(data_dir);
    try Io.Dir.cwd().createDirPath(c.io, data_dir);
    var lock = (try lockForChange(c, data_dir, "sign out")) orelse return 1;
    defer lock.release(c.io);
    const cfg = AuthEnv.from(c.env);
    var auth = try auth_host.AuthManager.init(c.gpa);
    defer auth.deinit();
    _ = try loadAuth(&auth, c.io, cfg, data_dir);
    if (!cfg.codegraffEnabled()) {
        auth.signOutWithIo(c.io);
        try c.out.writeAll("Auth is in dev mode — cleared any stale saved session.\nThe next engine start will remain in development mode.\n");
        try c.out.flush();
        return 0;
    }
    if (auth.phase == .signed_out and auth.refresh_token == null) {
        auth.signOutWithIo(c.io);
        try c.out.writeAll("No valid saved session; cleared any stale session file.\n");
    } else {
        const email = try c.gpa.dupe(u8, if (auth.email.len > 0) auth.email else "<unknown>");
        defer c.gpa.free(email);
        auth.signOutWithIo(c.io);
        const path = try std.fs.path.join(c.gpa, &.{ data_dir, "session.json" });
        defer c.gpa.free(path);
        try c.out.print("Signed out {s} — removed {s}.\n", .{ email, path });
    }
    try c.out.writeAll("The next engine start will use the local-only workspace.\n");
    try c.out.flush();
    return 0;
}

fn startSignIn(c: Context, auth: *auth_host.AuthManager, cfg: AuthEnv) !void {
    const callback = try std.fmt.allocPrint(c.gpa, "{s}/auth/cli/callback", .{std.mem.trimEnd(u8, cfg.edge_url, "/")});
    defer c.gpa.free(callback);
    const url = try auth.startBrowserSignIn(c.io, callback);
    defer c.gpa.free(url);
    try c.out.print("Sign in to Harness:\n\n  {s}\n\nThen paste the code shown in the browser here and press enter.\n", .{url});
    try c.out.flush();
}

fn readLine(c: Context) ?[]const u8 {
    while (true) {
        const line = (c.in.takeDelimiter('\n') catch return null) orelse return null;
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) return t;
    }
}

const Org = struct { id: []const u8, name: []const u8 };

/// Org-less session (`run_org_onboarding`): no workspaces yet, ask for a name
/// and create one; one, join it; several, pick one. False when none was chosen.
fn chooseWorkspace(c: Context, auth: *auth_host.AuthManager, cfg: AuthEnv) !bool {
    _ = cfg;
    const listed = auth.listOrgsJson(c.io) catch |err| {
        try c.out.print("Could not list workspaces ({s}) \u{2014} create or select one from the Harness UI to continue.\n", .{auth.errorText(err)});
        return false;
    };
    defer c.gpa.free(listed);
    var parsed = try json.parseFromSlice(json.Value, c.gpa, listed, .{});
    defer parsed.deinit();
    var orgs: std.ArrayList(Org) = .empty;
    defer orgs.deinit(c.gpa);
    for (parsed.value.object.get("orgs").?.array.items) |it| {
        try orgs.append(c.gpa, .{ .id = it.object.get("organizationId").?.string, .name = it.object.get("name").?.string });
    }
    switch (orgs.items.len) {
        0 => {
            try c.out.writeAll("No workspaces yet \u{2014} name your new workspace and press enter:\n");
            while (true) {
                try c.out.flush();
                const name = readLine(c) orelse return false;
                const created = auth.createOrg(c.io, name) catch |err| {
                    try c.out.print("Creating workspace failed: {s}\n", .{auth.errorText(err)});
                    continue;
                };
                c.gpa.free(created);
                return auth.phase == .signed_in;
            }
        },
        1 => {
            try c.out.print("Joining workspace \"{s}\"\u{2026}\n", .{orgs.items[0].name});
            try c.out.flush();
            auth.selectOrg(c.io, orgs.items[0].id) catch |err| {
                try c.out.print("Joining workspace failed: {s}\n", .{auth.errorText(err)});
                return false;
            };
            return auth.phase == .signed_in;
        },
        else => {
            try c.out.writeAll("\nYour workspaces:\n");
            for (orgs.items, 1..) |o, i| try c.out.print("  {d}. {s}\n", .{ i, o.name });
            try c.out.print("Pick a workspace [1-{d}]:\n", .{orgs.items.len});
            while (true) {
                try c.out.flush();
                const line = readLine(c) orelse return false;
                const n = std.fmt.parseInt(usize, line, 10) catch 0;
                if (n < 1 or n > orgs.items.len) {
                    try c.out.print("Pick a workspace [1-{d}]:\n", .{orgs.items.len});
                    continue;
                }
                auth.selectOrg(c.io, orgs.items[n - 1].id) catch |err| {
                    try c.out.print("Joining workspace failed: {s}\n", .{auth.errorText(err)});
                    continue;
                };
                return auth.phase == .signed_in;
            }
        },
    }
}

/// `harness-engine login`: the paste-code sign-in (and workspace choice),
/// saved to `session.json` for the next engine start.
pub fn login(c: Context) !u8 {
    const data_dir = try resolveDataDir(c.gpa, c.io, c.env);
    defer c.gpa.free(data_dir);
    try Io.Dir.cwd().createDirPath(c.io, data_dir);
    var lock = (try lockForChange(c, data_dir, "sign in")) orelse return 1;
    defer lock.release(c.io);
    const cfg = AuthEnv.from(c.env);
    var auth = try auth_host.AuthManager.init(c.gpa);
    defer auth.deinit();
    _ = try loadAuth(&auth, c.io, cfg, data_dir);
    if (!cfg.codegraffEnabled()) {
        try c.out.writeAll("Auth is in dev mode (no CodeGraff client id) — there is nothing to sign in to.\n");
        try c.out.flush();
        return 0;
    }
    if (auth.phase == .signed_in) {
        try c.out.print("Already signed in as {s}", .{auth.email});
        if (auth.org_id) |o| try c.out.print(" (workspace {s})", .{o});
        try c.out.writeAll(".\nRun `harness-engine logout` first to switch accounts.\nThe next engine start will use the synced workspace.\n");
        try c.out.flush();
        return 0;
    }
    if (!c.interactive) {
        try c.out.writeAll("harness-engine: login needs an interactive terminal\n");
        try c.out.flush();
        return 1;
    }
    for ([_][2][]const u8{ .{ "Harness edge", cfg.edge_url }, .{ "CodeGraff OAuth", cfg.api_base } }) |pair| {
        if (!isSecureUrl(pair[1])) {
            try c.out.print("harness-engine: {s} URL must use https (or http on a numeric loopback address): {s}\n", .{ pair[0], pair[1] });
            try c.out.flush();
            return 1;
        }
    }
    if (auth.phase == .signed_out) {
        try startSignIn(c, &auth, cfg);
        while (true) {
            const pasted = readLine(c) orelse {
                try c.out.writeAll("Sign-in did not complete.\n");
                try c.out.flush();
                return 1;
            };
            if (auth.completeSignIn(c.io, pasted)) |_| {
                // Only a real exchange leaves a refresh token behind.
                if (auth.refresh_token != null) break;
                try c.out.writeAll("Sign-in failed: the edge returned no session\n");
            } else |err| {
                try c.out.print("Sign-in failed: {s}\n", .{auth.errorText(err)});
            }
            // A code is single-use: offer a fresh sign-in after a failure.
            if (auth.pending_state == null) try startSignIn(c, &auth, cfg);
            try c.out.flush();
        }
    }
    if (auth.phase == .needs_organization) {
        try c.out.print("Signed in as {s}.\n", .{auth.email});
        if (!try chooseWorkspace(c, &auth, cfg)) {
            try c.out.writeAll("Sign-in did not complete: no workspace selected.\n");
            try c.out.flush();
            return 1;
        }
    }
    try c.out.print("\nSigned in as {s}", .{auth.email});
    if (auth.org_id) |o| try c.out.print(" (workspace {s})", .{o});
    try c.out.writeAll(".\nSync is ready. Start or restart Harness to open the synced workspace; existing local sessions will stay local.\n");
    try c.out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse: every Rust CLI command, nothing unknown starts an engine" {
    try testing.expectEqual(Command.headless, try parse(&.{}));
    try testing.expectEqual(Command.headless, try parse(&.{"headless"}));
    try testing.expectEqual(Command.login, try parse(&.{"login"}));
    try testing.expectEqual(Command.logout, try parse(&.{"logout"}));
    try testing.expectEqual(Command.status, try parse(&.{"status"}));
    try testing.expectEqual(Command.sync, try parse(&.{"sync"}));
    try testing.expectEqual(Command.mcp, try parse(&.{"mcp"}));
    try testing.expectEqual(Command.version, try parse(&.{"--version"}));
    try testing.expectEqual(Command{ .daemon = .install }, try parse(&.{ "daemon", "install" }));
    try testing.expectEqual(Command{ .daemon = .restart }, try parse(&.{ "daemon", "restart" }));
    try testing.expectError(error.MissingDaemonAction, parse(&.{"daemon"}));
    try testing.expectError(error.UnknownDaemonAction, parse(&.{ "daemon", "reload" }));
    try testing.expectError(error.UnknownCommand, parse(&.{"bogus"}));
    try testing.expectError(error.UnexpectedArgument, parse(&.{ "login", "extra" }));
}

test "data folder: override, then ~/.harness before the legacy name" {
    var env = Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/synthetic");
    {
        const got = try dataDirCandidates(testing.allocator, &env, false);
        defer {
            for (got) |p| testing.allocator.free(p);
            testing.allocator.free(got);
        }
        try testing.expectEqual(@as(usize, 2), got.len);
        try testing.expectEqualStrings("/home/synthetic" ++ std.fs.path.sep_str ++ ".harness", got[0]);
        try testing.expectEqualStrings("/home/synthetic" ++ std.fs.path.sep_str ++ ".harnesser", got[1]);
    }
    try env.put("LOCALAPPDATA", "C:/Synthetic/Local");
    {
        const got = try dataDirCandidates(testing.allocator, &env, true);
        defer {
            for (got) |p| testing.allocator.free(p);
            testing.allocator.free(got);
        }
        try testing.expectEqualStrings("C:/Synthetic/Local" ++ std.fs.path.sep_str ++ "Harness", got[0]);
    }
    try env.put("HARNESS_DATA_DIR", "/tmp/synthetic-data");
    {
        const got = try dataDirCandidates(testing.allocator, &env, false);
        defer {
            for (got) |p| testing.allocator.free(p);
            testing.allocator.free(got);
        }
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqualStrings("/tmp/synthetic-data", got[0]);
    }
}

test "data folder: DATA_DIR is the older override when HARNESS_DATA_DIR is unset" {
    var env = Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/synthetic");
    try env.put("DATA_DIR", "/tmp/legacy-data");
    {
        const got = try dataDirCandidates(testing.allocator, &env, false);
        defer {
            for (got) |p| testing.allocator.free(p);
            testing.allocator.free(got);
        }
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqualStrings("/tmp/legacy-data", got[0]);
    }
    try env.put("HARNESS_DATA_DIR", "/tmp/harness-data");
    {
        const got = try dataDirCandidates(testing.allocator, &env, false);
        defer {
            for (got) |p| testing.allocator.free(p);
            testing.allocator.free(got);
        }
        try testing.expectEqualStrings("/tmp/harness-data", got[0]);
    }
}

const TmpDir = struct {
    buf: [128]u8 = undefined,
    path: []const u8 = "",

    fn make(self: *TmpDir, tag: []const u8) ![]const u8 {
        var rnd: [6]u8 = undefined;
        testing.io.random(&rnd);
        self.path = try std.fmt.bufPrint(&self.buf, "/tmp/nano-engine-cli-{s}-{x}", .{ tag, rnd });
        try Io.Dir.cwd().createDirPath(testing.io, self.path);
        return self.path;
    }

    fn remove(self: *TmpDir) void {
        Io.Dir.cwd().deleteTree(testing.io, self.path) catch {};
    }
};

fn syntheticEnv(data_dir: []const u8) !Map {
    var env = Map.init(testing.allocator);
    errdefer env.deinit();
    try env.put("HARNESS_DATA_DIR", data_dir);
    try env.put("HOME", "/nonexistent-synthetic-home");
    return env;
}

const Captured = struct {
    out: Io.Writer.Allocating,
    err: Io.Writer.Allocating,
    in: Io.Reader,

    fn init(input: []const u8) Captured {
        return .{ .out = .init(testing.allocator), .err = .init(testing.allocator), .in = .fixed(input) };
    }

    fn ctx(self: *Captured, env: *const Map, port: u16, interactive: bool) Context {
        return .{ .gpa = testing.allocator, .io = testing.io, .env = env, .port = port, .out = &self.out.writer, .in = &self.in, .interactive = interactive, .err = &self.err.writer };
    }

    fn text(self: *Captured) []const u8 {
        return self.out.written();
    }

    fn errText(self: *Captured) []const u8 {
        return self.err.written();
    }

    fn deinit(self: *Captured) void {
        self.out.deinit();
        self.err.deinit();
    }
};

test "instance lock: one engine per data folder, released when it ends" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp: TmpDir = .{};
    const dir = try tmp.make("lock");
    defer tmp.remove();
    try testing.expectEqual(Holder.none, lockHolder(testing.allocator, testing.io, dir));
    var first = try InstanceLock.acquire(testing.allocator, testing.io, dir);
    try testing.expectEqual(Holder{ .pid = std.c.getpid() }, lockHolder(testing.allocator, testing.io, dir));
    try testing.expectError(error.AlreadyRunning, InstanceLock.acquire(testing.allocator, testing.io, dir));
    first.release(testing.io);
    try testing.expectEqual(Holder.none, lockHolder(testing.allocator, testing.io, dir));
    var again = try InstanceLock.acquire(testing.allocator, testing.io, dir);
    again.release(testing.io);
}

test "login and logout refuse while an engine holds the folder" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp: TmpDir = .{};
    const dir = try tmp.make("busy");
    defer tmp.remove();
    var env = try syntheticEnv(dir);
    defer env.deinit();
    var engine = try InstanceLock.acquire(testing.allocator, testing.io, dir);
    defer engine.release(testing.io);
    for ([_]*const fn (Context) anyerror!u8{ login, logout }, [_][]const u8{ "sign in", "sign out" }) |cmd, verb| {
        var cap: Captured = .init("");
        defer cap.deinit();
        try testing.expectEqual(@as(u8, 1), try cmd(cap.ctx(&env, 1, true)));
        try testing.expect(std.mem.indexOf(u8, cap.errText(), "while an engine is running") != null);
        try testing.expect(std.mem.indexOf(u8, cap.errText(), verb) != null);
    }
}

test "login needs a terminal; development mode has nothing to sign in to" {
    var tmp: TmpDir = .{};
    const dir = try tmp.make("tty");
    defer tmp.remove();
    var env = try syntheticEnv(dir);
    defer env.deinit();
    {
        var cap: Captured = .init("");
        defer cap.deinit();
        try testing.expectEqual(@as(u8, 1), try login(cap.ctx(&env, 1, false)));
        try testing.expect(std.mem.indexOf(u8, cap.text(), "interactive terminal") != null);
    }
    try env.put("HARNESS_EDGE_TOKEN", "synthetic-dev-bearer");
    {
        var cap: Captured = .init("");
        defer cap.deinit();
        try testing.expectEqual(@as(u8, 0), try login(cap.ctx(&env, 1, true)));
        try testing.expect(std.mem.indexOf(u8, cap.text(), "dev mode") != null);
    }
}

/// An edge on loopback: answers each request with the canned JSON for its
/// path, and records the paths it saw.
const FakeEdge = struct {
    server: Io.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Set when `run` has returned.
    exited: Io.Event = .unset,
    seen: [8][64]u8 = undefined,
    seen_len: [8]usize = @splat(0),
    seen_count: usize = 0,
    routes: []const [2][]const u8,

    fn start(self: *FakeEdge) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *FakeEdge) void {
        defer self.exited.set(testing.io);
        while (!self.stop.load(.acquire)) {
            var stream = self.server.accept(testing.io) catch return;
            defer stream.close(testing.io);
            if (self.stop.load(.acquire)) return;
            self.serveOne(&stream) catch {};
        }
    }

    fn serveOne(self: *FakeEdge, stream: *Io.net.Stream) !void {
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var rd = Io.net.Stream.Reader.init(stream.*, testing.io, &rbuf);
        var wr = Io.net.Stream.Writer.init(stream.*, testing.io, &wbuf);
        const r = &rd.interface;
        const request_line = try r.takeDelimiterInclusive('\n');
        var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
        _ = parts.next();
        const target = parts.next() orelse return;
        var path_copy: [64]u8 = undefined;
        const path_len = @min(target.len, path_copy.len);
        @memcpy(path_copy[0..path_len], target[0..path_len]);
        var content_length: usize = 0;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            const t = std.mem.trim(u8, line, "\r\n");
            if (t.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(t, "content-length:")) {
                content_length = std.fmt.parseInt(usize, std.mem.trim(u8, t["content-length:".len..], " "), 10) catch 0;
            }
        }
        if (content_length > 0) _ = try r.take(content_length);
        const path = path_copy[0..path_len];
        if (self.seen_count < self.seen.len) {
            @memcpy(self.seen[self.seen_count][0..path.len], path);
            self.seen_len[self.seen_count] = path.len;
            self.seen_count += 1;
        }
        var body: []const u8 = "{}";
        var code: []const u8 = "404 Not Found";
        for (self.routes) |route| if (std.mem.eql(u8, route[0], path)) {
            body = route[1];
            code = "200 OK";
        };
        try wr.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ code, body.len, body });
        try wr.interface.flush();
    }

    fn shutdown(self: *FakeEdge) void {
        self.stop.store(true, .release);
        if (self.thread) |t| @import("test_server_stop.zig").stopAcceptLoop(testing.io, self.port, &self.exited, t);
        self.server.deinit(testing.io);
    }
};

fn syntheticJwt(gpa: Allocator, payload: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const buf = try gpa.alloc(u8, enc.calcSize(payload.len));
    defer gpa.free(buf);
    _ = enc.encode(buf, payload);
    return std.fmt.allocPrint(gpa, "eyJhbGciOiJub25lIn0.{s}.sig", .{buf});
}

test "login: the pasted code is exchanged, a workspace joined, and the session saved; logout removes it" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp: TmpDir = .{};
    const dir = try tmp.make("login");
    defer tmp.remove();

    const jwt = try syntheticJwt(gpa, "{\"sub\":\"u-1\",\"iat\":1000,\"exp\":4000}");
    defer gpa.free(jwt);
    const exchange = try std.fmt.allocPrint(gpa, "{{\"accessToken\":\"{s}\",\"refreshToken\":\"refresh-synthetic-1\",\"user\":{{\"id\":\"u-1\",\"email\":\"ada@example.com\"}}}}", .{jwt});
    defer gpa.free(exchange);
    const jwt_b = try syntheticJwt(gpa, "{\"sub\":\"u-1\",\"iat\":1000,\"exp\":4000,\"org_id\":\"org-b\"}");
    defer gpa.free(jwt_b);
    const refreshed = try std.fmt.allocPrint(gpa, "{{\"accessToken\":\"{s}\",\"refreshToken\":\"refresh-synthetic-2\"}}", .{jwt_b});
    defer gpa.free(refreshed);
    const routes = [_][2][]const u8{
        .{ "/auth/exchange", exchange },
        .{ "/auth/orgs", "{\"orgs\":[{\"id\":\"om-a\",\"organizationId\":\"org-a\",\"name\":\"Alpha\"},{\"id\":\"om-b\",\"organizationId\":\"org-b\",\"name\":\"Beta\"}]}" },
        .{ "/auth/refresh", refreshed },
    };
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var edge: FakeEdge = .{ .server = try addr.listen(testing.io, .{ .reuse_address = true }), .port = 0, .routes = &routes };
    edge.port = edge.server.socket.address.getPort();
    try edge.start();
    defer edge.shutdown();

    var env = try syntheticEnv(dir);
    defer env.deinit();
    var edge_url_buf: [64]u8 = undefined;
    try env.put("HARNESS_EDGE_URL", try std.fmt.bufPrint(&edge_url_buf, "http://127.0.0.1:{d}", .{edge.port}));
    try env.put("HARNESS_CODEGRAFF_API_BASE", "https://oauth.example.invalid");
    try env.put("HARNESS_CODEGRAFF_CLIENT_ID", "cg_client_synthetic");

    // A code whose state isn't the one this sign-in printed is refused, and
    // the command ends when the terminal does.
    var first: Captured = .init("wrong.code\n");
    defer first.deinit();
    try testing.expectEqual(@as(u8, 1), try login(first.ctx(&env, 1, true)));
    try testing.expect(std.mem.indexOf(u8, first.text(), "Sign-in failed: invalid or expired sign-in code") != null);
    try testing.expect(std.mem.indexOf(u8, first.text(), "Sign-in did not complete") != null);
    try testing.expect(std.mem.indexOf(u8, first.text(), "redirect_uri=http%3A%2F%2F127.0.0.1") != null);

    // The state is random per run, so drive the command's own steps: paste
    // the printed state's code, then pick the second workspace.
    var auth = try auth_host.AuthManager.init(gpa);
    defer auth.deinit();
    _ = try loadAuth(&auth, testing.io, AuthEnv.from(&env), dir);
    var cap: Captured = .init("");
    defer cap.deinit();
    const c = cap.ctx(&env, 1, true);
    try startSignIn(c, &auth, AuthEnv.from(&env));
    const printed = cap.text();
    const at = std.mem.indexOf(u8, printed, "&state=") orelse return error.NoState;
    const rest = printed[at + "&state=".len ..];
    const state = rest[0 .. std.mem.indexOfScalar(u8, rest, '&') orelse rest.len];
    const pasted = try std.fmt.allocPrint(gpa, "{s}.synthetic-code", .{state});
    defer gpa.free(pasted);
    try auth.completeSignIn(testing.io, pasted);
    try testing.expectEqual(auth_host.AuthPhase.needs_organization, auth.phase);
    var pick: Captured = .init("9\n2\n");
    defer pick.deinit();
    try testing.expect(try chooseWorkspace(pick.ctx(&env, 1, true), &auth, AuthEnv.from(&env)));
    try testing.expect(std.mem.indexOf(u8, pick.text(), "2. Beta") != null);
    try testing.expectEqualStrings("org-b", auth.org_id.?);

    const session_path = try std.fs.path.join(gpa, &.{ dir, "session.json" });
    defer gpa.free(session_path);
    const saved = try Io.Dir.cwd().readFileAlloc(testing.io, session_path, gpa, .limited(4096));
    defer gpa.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"refreshToken\":\"refresh-synthetic-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"orgId\":\"org-b\"") != null);

    // The saved session now makes `login` a no-op and `status` synced.
    var again: Captured = .init("");
    defer again.deinit();
    try testing.expectEqual(@as(u8, 0), try login(again.ctx(&env, 1, true)));
    try testing.expect(std.mem.indexOf(u8, again.text(), "Already signed in as ada@example.com (workspace org-b)") != null);

    var out: Captured = .init("");
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0), try logout(out.ctx(&env, 1, true)));
    try testing.expect(std.mem.indexOf(u8, out.text(), "Signed out ada@example.com") != null);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, session_path, .{}));
}

test "account status: local-only signed out is healthy, a broken synced session isn't" {
    const gpa = testing.allocator;
    const cases = [_]struct { Scope, auth_host.AuthPhase, ?[]const u8, []const u8, []const u8, bool }{
        .{ .local, .signed_out, null, "local only", "signed out (optional in local-only mode)", true },
        .{ .local, .signed_in, "org-1", "local only", "signed in as u@example.com; sync is ready after restart", true },
        .{ .development, .signed_in, null, "development", "dev mode (bearer = user id)", true },
        .{ .synced, .signed_in, "org-1", "synced", "signed in as u@example.com (workspace org-1)", true },
        .{ .synced, .needs_organization, null, "synced", "signed in as u@example.com but no workspace selected — run `harness-engine login`", false },
        .{ .synced, .signed_out, null, "synced", "saved session is no longer valid — run `harness-engine login`", false },
    };
    for (cases) |cs| {
        const got = try accountStatus(gpa, cs[0], cs[1], "u@example.com", cs[2]);
        defer gpa.free(got.auth);
        try testing.expectEqualStrings(cs[3], got.mode);
        try testing.expectEqualStrings(cs[4], got.auth);
        try testing.expectEqual(cs[5], got.healthy);
    }
}

test "only TLS, or plain HTTP on a numeric loopback address, carries sign-in" {
    try testing.expect(isSecureUrl("https://edge.example.com"));
    try testing.expect(isSecureUrl("http://127.0.0.1:8787"));
    try testing.expect(isSecureUrl("http://[::1]:8787"));
    try testing.expect(!isSecureUrl("http://edge.example.com"));
    try testing.expect(!isSecureUrl("http://localhost.example.com"));
    try testing.expect(!isSecureUrl("ftp://127.0.0.1"));
}

test "status with no engine: local-only, not running, not listening" {
    var tmp: TmpDir = .{};
    const dir = try tmp.make("status");
    defer tmp.remove();
    var env = try syntheticEnv(dir);
    defer env.deinit();
    // A port nothing listens on: bind one, then let it go.
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var probe = try addr.listen(testing.io, .{ .reuse_address = true });
    const port = probe.socket.address.getPort();
    probe.deinit(testing.io);
    var cap: Captured = .init("");
    defer cap.deinit();
    try testing.expectEqual(@as(u8, 0), try status(cap.ctx(&env, port, false)));
    const text = cap.text();
    try testing.expect(std.mem.indexOf(u8, text, "Mode:     local only\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Engine:   not running\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not listening on 127.0.0.1:") != null);
    // And `sync` says so instead of hanging.
    var sync_cap: Captured = .init("");
    defer sync_cap.deinit();
    try testing.expectEqual(@as(u8, 1), try sync(sync_cap.ctx(&env, port, false)));
    try testing.expect(std.mem.indexOf(u8, sync_cap.text(), "no engine listening") != null);
}

test "sync readout matches the Rust CLI's lines" {
    const body =
        \\{"deviceId":"dev-1","nowMs":100000,
        \\ "workspace":{"connected":true,"lastPushedMs":95000,"lastAckMs":0,"rejoins":1,"probes":2,"fullResyncs":0,"disconnects":3,"rejected":4},
        \\ "chats":[{"chatId":"abcdef0123456789","room":{"connected":false,"cursor":5,"headSeq":7,"pendingPushes":1,"rowCount":9,"rowBytes":4096,"rejoins":0,"disconnects":1,"serverResets":2,"rejected":0}},
        \\          {"chatId":"short","room":null}]}
    ;
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try formatSyncStatus(&out.writer, parsed.value);
    try testing.expectEqualStrings(
        "Device:    dev-1\n" ++
            "Workspace: connected · pushed 5s ago · acked never · rejoins 1 probes 2 resyncs 0 drops 3 REJECTED 4\n" ++
            "Chat abcdef01: DISCONNECTED · cursor 5/7 · pending 1 · rows 9 (4KB) · rejoins 0 drops 1 RESETS 2\n" ++
            "Chat short: no room (dialing or edge-less)\n",
        out.written(),
    );
}

test "fix-sec 15: the engine never runs unlocked, and an unnamed holder is `unknown`" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp: TmpDir = .{};
    const dir = try tmp.make("fixsec15");
    defer tmp.remove();
    // A data folder that can't be created (its parent is a file) stops the engine.
    const file_path = try std.fs.path.join(testing.allocator, &.{ dir, "a-file" });
    defer testing.allocator.free(file_path);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file_path, .data = "x" });
    const under_file = try std.fs.path.join(testing.allocator, &.{ file_path, "data" });
    defer testing.allocator.free(under_file);
    var buf: [1024]u8 = undefined;
    const blocked = lockEngineDataDir(testing.allocator, testing.io, under_file, &buf);
    try testing.expect(std.mem.startsWith(u8, blocked.err, "cannot create the data directory "));

    // A held lock whose file names no pid reads `pid unknown`, never `pid 0`.
    const data = try std.fs.path.join(testing.allocator, &.{ dir, "data" });
    defer testing.allocator.free(data);
    var first = switch (lockEngineDataDir(testing.allocator, testing.io, data, &buf)) {
        .ok => |l| l,
        .err => |m| {
            std.debug.print("{s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
    defer first.release(testing.io);
    try first.file.setLength(testing.io, 0);
    const second = lockEngineDataDir(testing.allocator, testing.io, data, &buf);
    try testing.expect(std.mem.indexOf(u8, second.err, "(pid unknown)") != null);
    var pid_buf: [24]u8 = undefined;
    try testing.expectEqualStrings("unknown", holderPid(&pid_buf, .{ .pid = 0 }));
    try testing.expectEqualStrings("4242", holderPid(&pid_buf, .{ .pid = 4242 }));
}

test "fix-sec 18: lock errors go to stderr, not stdout" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp: TmpDir = .{};
    const dir = try tmp.make("fixsec18");
    defer tmp.remove();
    var env = try syntheticEnv(dir);
    defer env.deinit();
    var engine = try InstanceLock.acquire(testing.allocator, testing.io, dir);
    defer engine.release(testing.io);
    var cap: Captured = .init("");
    defer cap.deinit();
    try testing.expectEqual(@as(u8, 1), try logout(cap.ctx(&env, 1, true)));
    try testing.expect(std.mem.indexOf(u8, cap.errText(), "another Harness engine is already running") != null);
    try testing.expect(std.mem.indexOf(u8, cap.text(), "already running") == null);
}

test "fix-sec 18: an engine that accepts and never upgrades can't hang a command" {
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    // Never accepted: the kernel completes the connect, nobody answers.
    const started = Io.Clock.awake.now(testing.io);
    try testing.expectError(error.Timeout, rpcCall(testing.allocator, testing.io, server.socket.address.getPort(), "EngineInfo", "{}", 300));
    try testing.expect(started.durationTo(Io.Clock.awake.now(testing.io)).toMilliseconds() < 5_000);
}

test "fix-sec 18: the default project is a git checkout only when it is one" {
    var tmp: TmpDir = .{};
    const dir = try tmp.make("fixsec18git");
    defer tmp.remove();
    try testing.expect(!gitDetected(testing.io, dir));
    const git = try std.fs.path.join(testing.allocator, &.{ dir, ".git" });
    defer testing.allocator.free(git);
    try Io.Dir.cwd().createDirPath(testing.io, git);
    try testing.expect(gitDetected(testing.io, dir));
    try testing.expect(!gitDetected(testing.io, "/nonexistent-synthetic-project"));
}

test "engine_cli: `update` is a command, as `harness update` was" {
    try std.testing.expectEqual(Command.update, try parse(&.{"update"}));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "update", "now" }));
    try std.testing.expect(std.mem.indexOf(u8, usage, "  update ") != null);
}

test "parseAuthStatusValue parses signedIn, needsOrganization, signedOut, and malformed inputs" {
    const gpa = testing.allocator;
    const cases = [_]struct {
        body: []const u8,
        expected: ?struct { phase: auth_host.AuthPhase, email: []const u8, org: ?[]const u8 },
    }{
        .{
            .body = "{\"state\":\"signedIn\",\"user\":{\"id\":\"u-2\",\"email\":\"cloud@example.test\"},\"orgId\":\"user-2\"}",
            .expected = .{ .phase = .signed_in, .email = "cloud@example.test", .org = "user-2" },
        },
        .{
            .body = "{\"state\":\"signedIn\",\"user\":{\"id\":\"u-2\",\"email\":\"cloud@example.test\"}}",
            .expected = .{ .phase = .signed_in, .email = "cloud@example.test", .org = null },
        },
        .{
            .body = "{\"state\":\"needsOrganization\",\"user\":{\"id\":\"u-2\",\"email\":\"org@example.test\"}}",
            .expected = .{ .phase = .needs_organization, .email = "org@example.test", .org = null },
        },
        .{
            .body = "{\"state\":\"signedOut\"}",
            .expected = .{ .phase = .signed_out, .email = "", .org = null },
        },
        .{ .body = "{\"state\":\"signedIn\"}", .expected = null },
        .{ .body = "[]", .expected = null },
    };
    for (cases) |c| {
        var parsed = try json.parseFromSlice(json.Value, gpa, c.body, .{});
        defer parsed.deinit();
        var got = try parseAuthStatusValue(gpa, parsed.value);
        if (got) |*g| {
            defer g.deinit(gpa);
            const exp = c.expected.?;
            try testing.expectEqual(exp.phase, g.phase);
            try testing.expectEqualStrings(exp.email, g.email);
            if (exp.org) |eo| {
                try testing.expectEqualStrings(eo, g.org_id.?);
            } else {
                try testing.expect(g.org_id == null);
            }
        } else {
            try testing.expect(c.expected == null);
        }
    }
}

test "parseSandboxTokenAlloc accepts JSON apiKey, JSON token, or raw cg_lt_ token and rejects malformed" {
    const gpa = testing.allocator;
    const tok = "cg_lt_a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4";
    const valid = [_][]const u8{
        "{\"apiKey\":\"" ++ tok ++ "\"}",
        "  {\"token\":\"" ++ tok ++ "\"} \n",
        " \t" ++ tok ++ "\n",
    };
    for (valid) |raw| {
        const got = (try parseSandboxTokenAlloc(gpa, raw)).?;
        defer gpa.free(got);
        try testing.expectEqualStrings(tok, got);
    }
    const short_tok = "cg_lt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const bad_hex = "cg_lt_gggggggggggggggggggggggggggggggggggggggggggggggg";
    for ([_][]const u8{ "", "{}", "{\"apiKey\":123}", "\"" ++ tok ++ "\"", short_tok, bad_hex, "{\"apiKey\":\"" ++ bad_hex ++ "\"}" }) |raw| {
        try testing.expect((try parseSandboxTokenAlloc(gpa, raw)) == null);
    }
}

test "status resolves HARNESS_SANDBOX_TOKEN_FILE via /auth/sandbox and ignores stale session.json" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp: TmpDir = .{};
    const dir = try tmp.make("sandbox-status");
    defer tmp.remove();

    // Plant a stale session.json to prove sandbox_token_file takes precedence.
    const stale_path = try std.fs.path.join(gpa, &.{ dir, "session.json" });
    defer gpa.free(stale_path);
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = stale_path,
        .data = "{\"refreshToken\":\"harness_rt_stale\",\"user\":{\"id\":\"old\",\"email\":\"stale@example.invalid\"},\"orgId\":\"old-org\"}",
    });

    const tok_path = try std.fs.path.join(gpa, &.{ dir, "access.json" });
    defer gpa.free(tok_path);
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = tok_path,
        .data = "{\"apiKey\":\"cg_lt_0123456789abcdef0123456789abcdef0123456789abcdef\"}",
    });

    const routes = [_][2][]const u8{
        .{ "/auth/sandbox", "{\"accessToken\":\"jwt\",\"user\":{\"id\":\"u-2\",\"email\":\"cloud@example.test\"},\"orgId\":\"user-2\"}" },
    };
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var edge: FakeEdge = .{ .server = try addr.listen(testing.io, .{ .reuse_address = true }), .port = 0, .routes = &routes };
    edge.port = edge.server.socket.address.getPort();
    try edge.start();
    defer edge.shutdown();

    const dead = try addr.listen(testing.io, .{ .reuse_address = true });
    const dead_port = dead.socket.address.getPort();
    var dead_mut = dead;
    dead_mut.deinit(testing.io);

    var env = try syntheticEnv(dir);
    defer env.deinit();
    var edge_url_buf: [64]u8 = undefined;
    try env.put("HARNESS_EDGE_URL", try std.fmt.bufPrint(&edge_url_buf, "http://127.0.0.1:{d}", .{edge.port}));
    try env.put("HARNESS_CODEGRAFF_CLIENT_ID", "cg_client_synthetic");
    try env.put("HARNESS_SANDBOX_TOKEN_FILE", tok_path);

    var cap: Captured = .init("");
    defer cap.deinit();
    try testing.expectEqual(@as(u8, 0), try status(cap.ctx(&env, dead_port, false)));
    const text = cap.text();
    try testing.expect(std.mem.indexOf(u8, text, "Mode:     synced\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Auth:     signed in as cloud@example.test (workspace user-2)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "stale@example.invalid") == null);
    try testing.expectEqual(@as(usize, 1), edge.seen_count);
    try testing.expectEqualStrings("/auth/sandbox", edge.seen[0][0..edge.seen_len[0]]);
}

const FakeRpc = struct {
    server: Io.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    exited: Io.Event = .unset,

    fn start(self: *FakeRpc) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *FakeRpc) void {
        defer self.exited.set(testing.io);
        while (!self.stop.load(.acquire)) {
            var stream = self.server.accept(testing.io) catch return;
            defer stream.close(testing.io);
            if (self.stop.load(.acquire)) return;
            self.serveOne(&stream) catch {};
        }
    }

    fn noPing(_: void, _: []const u8) void {}

    fn writeServerTextFrame(w: *Io.Writer, payload: []const u8) !void {
        var hdr: [4]u8 = undefined;
        hdr[0] = 0x81;
        if (payload.len < 126) {
            hdr[1] = @intCast(payload.len);
            try w.writeAll(hdr[0..2]);
        } else {
            hdr[1] = 126;
            std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
            try w.writeAll(hdr[0..4]);
        }
        try w.writeAll(payload);
    }

    fn serveOne(self: *FakeRpc, stream: *Io.net.Stream) !void {
        _ = self;
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var rd = Io.net.Stream.Reader.init(stream.*, testing.io, &rbuf);
        var wr = Io.net.Stream.Writer.init(stream.*, testing.io, &wbuf);
        const r = &rd.interface;
        const w = &wr.interface;
        const first = try r.takeDelimiterInclusive('\n');
        if (std.mem.indexOf(u8, first, "HTTP/") == null) return;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            if (line.len <= 2) break;
        }
        try w.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n");
        try w.flush();

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(testing.allocator);
        _ = try ws.readMessageFrom(testing.allocator, r, &msg, {}, noPing);
        var parsed = try json.parseFromSlice(json.Value, testing.allocator, msg.items, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const method_val = parsed.value.object.get("method") orelse return;
        if (method_val != .string) return;
        const reply = if (std.mem.eql(u8, method_val.string, "EngineInfo"))
            "{\"id\":1,\"ok\":{\"deviceId\":\"dev-cloud\",\"workspaceScope\":\"synced\"}}"
        else if (std.mem.eql(u8, method_val.string, "AuthStatus"))
            "{\"id\":1,\"item\":{\"state\":\"signedIn\",\"user\":{\"id\":\"u-2\",\"email\":\"live@example.test\"},\"orgId\":\"user-2\"}}"
        else
            "{\"id\":1,\"err\":\"unknown\"}";
        try writeServerTextFrame(w, reply);
        try w.flush();
    }

    fn shutdown(self: *FakeRpc) void {
        self.stop.store(true, .release);
        if (self.thread) |t| @import("test_server_stop.zig").stopAcceptLoop(testing.io, self.port, &self.exited, t);
        self.server.deinit(testing.io);
    }
};

test "status prefers running engine EngineInfo and AuthStatus IPC without session.json" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp: TmpDir = .{};
    const dir = try tmp.make("live-ipc-status");
    defer tmp.remove();

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var rpc: FakeRpc = .{ .server = try addr.listen(testing.io, .{ .reuse_address = true }), .port = 0 };
    rpc.port = rpc.server.socket.address.getPort();
    try rpc.start();
    defer rpc.shutdown();

    var env = try syntheticEnv(dir);
    defer env.deinit();
    try env.put("HARNESS_CODEGRAFF_CLIENT_ID", "cg_client_synthetic");

    var cap: Captured = .init("");
    defer cap.deinit();
    try testing.expectEqual(@as(u8, 0), try status(cap.ctx(&env, rpc.port, false)));
    const text = cap.text();
    try testing.expect(std.mem.indexOf(u8, text, "Mode:     synced\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Auth:     signed in as live@example.test (workspace user-2)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "IPC:      listening on 127.0.0.1:") != null);
}
