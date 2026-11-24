//! Standalone native Zig CLI & launcher for Harness (`harness` executable).
//! Replaces `apps/harness` (Rust) while forwarding `headless` and `exo-acp` to
//! the sibling `harness-engine` binary, and serving `mcp`, `visual-check`,
//! `preview-servers`, `preview-daemon`, `update-daemon`, `status`, `sync`,
//! `login`, `logout`, `daemon`, and `update` natively in Zig.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const build_info = @import("build_info");
const engine_cli = @import("engine_cli.zig");
const engine_daemon = @import("engine_daemon.zig");
const mcp_server = @import("mcp_server.zig");
const updates_host = @import("updates_host.zig");
const visual_luau = @import("visual_luau.zig");
const preview_catalog = @import("preview/catalog.zig");
const preview_service = @import("preview/service.zig");

const default_ipc_port: u16 = 27664;
const default_edge_url = "https://edge.codegraff.com";

pub const usage =
    \\Harness — native workspace & multi-device controller for coding agents
    \\
    \\Usage: harness [OPTIONS] [FOLDER|URL]
    \\       harness <COMMAND>
    \\
    \\Commands:
    \\  headless         Run the engine without a UI
    \\  login            Sign in and enable sync on the next engine start
    \\  logout           Remove the saved session and return to local-only
    \\  status           Show workspace mode, optional auth, and engine status
    \\  sync             Show live sync state from the running engine
    \\  mcp              Serve the Harness MCP server on stdin/stdout
    \\  daemon           install | uninstall | start | stop | restart | status
    \\  update [--check] Check for or apply a release update
    \\  visual-check     Validate a Luau show_visual script on stdin
    \\  preview-servers  Scan local loopback HTTP dev servers as JSON
    \\  preview-daemon   Run the preview discovery + proxy daemon
    \\  update-daemon    Run the release check/update daemon
    \\  help             Show this help message
    \\
    \\Options:
    \\  -h, --help       Show this help message
    \\  -V, --version    Print version
    \\
;

pub const Action = union(enum) {
    version,
    help,
    headed: struct { open_arg: ?[]const u8 = null },
    engine: struct { subcmd: []const u8, rest: []const []const u8 },
    mcp,
    status,
    sync,
    login,
    logout,
    appshot,
    daemon: engine_cli.DaemonAction,
    update: struct { check: bool = false },
    visual_check,
    preview_servers: struct { ignore_pid: u32 = 0 },
    preview_daemon: struct {
        port: u16 = preview_catalog.proxy_port_default,
        catalog_file: ?[]const u8 = null,
        device_id: []const u8 = "local",
        device_name: []const u8 = "Harness",
    },
    update_daemon: struct { edge_url: ?[]const u8 = null },
};

pub const ParseOutcome = union(enum) {
    ok: Action,
    bad_arg: []const u8,
    missing_value: []const u8,
    missing_daemon_action,
    unknown_daemon_action: []const u8,
};

pub fn parseArgs(args: []const []const u8) ParseOutcome {
    if (args.len == 0) return .{ .ok = .{ .headed = .{} } };
    const first = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V") or std.mem.eql(u8, first, "version")) {
        if (rest.len > 0) return .{ .bad_arg = rest[0] };
        return .{ .ok = .version };
    }
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "help")) {
        return .{ .ok = .help };
    }
    if (std.mem.eql(u8, first, "headless") or std.mem.eql(u8, first, "exo-acp")) {
        return .{ .ok = .{ .engine = .{ .subcmd = first, .rest = rest } } };
    }
    if (std.mem.eql(u8, first, "mcp")) {
        if (rest.len > 0) return .{ .bad_arg = rest[0] };
        return .{ .ok = .mcp };
    }
    if (std.mem.eql(u8, first, "status")) {
        if (rest.len > 0) return .{ .bad_arg = rest[0] };
        return .{ .ok = .status };
    }
    if (std.mem.eql(u8, first, "sync")) {
        if (rest.len > 0) return .{ .bad_arg = rest[0] };
        return .{ .ok = .sync };
    }
    if (std.mem.eql(u8, first, "login")) {
        if (rest.len > 0) return .{ .bad_arg = rest[0] };
        return .{ .ok = .login };
    }
    if (std.mem.eql(u8, first, "logout")) {
        if (rest.len > 0) return .{ .bad_arg = rest[0] };
        return .{ .ok = .logout };
    }
    if (std.mem.eql(u8, first, "appshot")) {
        if (rest.len > 0) return .{ .bad_arg = rest[0] };
        return .{ .ok = .appshot };
    }
    if (std.mem.eql(u8, first, "visual-check")) {
        if (rest.len > 0) return .{ .bad_arg = rest[0] };
        return .{ .ok = .visual_check };
    }
    if (std.mem.eql(u8, first, "daemon")) {
        if (rest.len == 0) return .missing_daemon_action;
        const act = std.meta.stringToEnum(engine_cli.DaemonAction, rest[0]) orelse return .{ .unknown_daemon_action = rest[0] };
        if (rest.len > 1) return .{ .bad_arg = rest[1] };
        return .{ .ok = .{ .daemon = act } };
    }
    if (std.mem.eql(u8, first, "update")) {
        var check = false;
        for (rest) |arg| {
            if (std.mem.eql(u8, arg, "--check")) {
                check = true;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                return .{ .ok = .help };
            } else {
                return .{ .bad_arg = arg };
            }
        }
        return .{ .ok = .{ .update = .{ .check = check } } };
    }
    if (std.mem.eql(u8, first, "preview-servers")) {
        var ignore_pid: u32 = 0;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--ignore-pid")) {
                i += 1;
                if (i >= rest.len) return .{ .missing_value = "--ignore-pid" };
                ignore_pid = std.fmt.parseInt(u32, rest[i], 10) catch return .{ .bad_arg = rest[i] };
            } else {
                return .{ .bad_arg = rest[i] };
            }
        }
        return .{ .ok = .{ .preview_servers = .{ .ignore_pid = ignore_pid } } };
    }
    if (std.mem.eql(u8, first, "preview-daemon")) {
        var port: u16 = preview_catalog.proxy_port_default;
        var catalog_file: ?[]const u8 = null;
        var device_id: []const u8 = "local";
        var device_name: []const u8 = "Harness";
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const flag = rest[i];
            if (std.mem.eql(u8, flag, "--port")) {
                i += 1;
                if (i >= rest.len) return .{ .missing_value = flag };
                port = std.fmt.parseInt(u16, rest[i], 10) catch return .{ .bad_arg = rest[i] };
            } else if (std.mem.eql(u8, flag, "--catalog")) {
                i += 1;
                if (i >= rest.len) return .{ .missing_value = flag };
                catalog_file = rest[i];
            } else if (std.mem.eql(u8, flag, "--device-id")) {
                i += 1;
                if (i >= rest.len) return .{ .missing_value = flag };
                device_id = rest[i];
            } else if (std.mem.eql(u8, flag, "--device-name")) {
                i += 1;
                if (i >= rest.len) return .{ .missing_value = flag };
                device_name = rest[i];
            } else {
                return .{ .bad_arg = flag };
            }
        }
        return .{ .ok = .{ .preview_daemon = .{
            .port = port,
            .catalog_file = catalog_file,
            .device_id = device_id,
            .device_name = device_name,
        } } };
    }
    if (std.mem.eql(u8, first, "update-daemon")) {
        var edge_url: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--edge-url")) {
                i += 1;
                if (i >= rest.len) return .{ .missing_value = "--edge-url" };
                edge_url = rest[i];
            } else {
                return .{ .bad_arg = rest[i] };
            }
        }
        return .{ .ok = .{ .update_daemon = .{ .edge_url = edge_url } } };
    }
    if (first.len > 0 and first[0] == '-') return .{ .bad_arg = first };
    if (rest.len > 0) return .{ .bad_arg = rest[0] };
    return .{ .ok = .{ .headed = .{ .open_arg = first } } };
}

pub const WaitForExitParse = union(enum) {
    ok: struct { pid: ?u32, rest: []const []const u8 },
    missing_value: []const u8,
    bad_arg: []const u8,
};

pub fn stripWaitForExit(args: []const []const u8) WaitForExitParse {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--wait-for-exit")) {
        if (args.len < 2) return .{ .missing_value = "--wait-for-exit" };
        const pid = std.fmt.parseInt(u32, args[1], 10) catch return .{ .bad_arg = args[1] };
        return .{ .ok = .{ .pid = pid, .rest = args[2..] } };
    }
    return .{ .ok = .{ .pid = null, .rest = args } };
}

fn waitForExitProcess(arena: Allocator, io: Io, pid: u32) void {
    if (comptime builtin.os.tag != .windows) return;
    const w = struct {
        const SYNCHRONIZE: u32 = 0x0010_0000;
        extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
        extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn WaitForSingleObject(hHandle: *anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
        extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) i32;
    };
    if (pid != w.GetCurrentProcessId()) {
        if (w.OpenProcess(w.SYNCHRONIZE, 0, pid)) |proc_handle| {
            defer _ = w.CloseHandle(proc_handle);
            _ = w.WaitForSingleObject(proc_handle, 60_000);
        }
    }
    const self_exe = std.process.executablePathAlloc(io, arena) catch return;
    const dir = std.fs.path.dirname(self_exe) orelse return;
    for ([_][]const u8{ "harness.exe.old", "harness-nano.exe.old", "harness-engine.exe.old", "WebView2Loader.dll.old" }) |old_name| {
        const old_path = std.fs.path.join(arena, &.{ dir, old_name }) catch continue;
        Io.Dir.cwd().deleteFile(io, old_path) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.os.tag == .windows) attachParentConsole();
    const code = try run(init);
    if (code != 0) std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const all_args = try init.minimal.args.toSlice(arena);
    const args: []const []const u8 = if (all_args.len > 1) all_args[1..] else &.{};

    var out_buf: [65536]u8 = undefined;
    var err_buf: [8192]u8 = undefined;
    var stdout_w = Io.File.stdout().writerStreaming(io, &out_buf);
    var stderr_w = Io.File.stderr().writerStreaming(io, &err_buf);
    const out = &stdout_w.interface;
    const err_w = &stderr_w.interface;

    const wait_split = switch (stripWaitForExit(args)) {
        .ok => |v| v,
        .missing_value => |flag| {
            try err_w.print("error: a value is required for '{s}'\n", .{flag});
            try err_w.flush();
            return 2;
        },
        .bad_arg => |arg| {
            try err_w.print("error: unexpected argument '{s}'\n", .{arg});
            try err_w.flush();
            return 2;
        },
    };
    if (wait_split.pid) |pid| waitForExitProcess(arena, io, pid);

    const action: Action = switch (parseArgs(wait_split.rest)) {
        .ok => |a| a,
        .bad_arg => |arg| {
            try err_w.print("error: unexpected argument '{s}'\n", .{arg});
            try err_w.flush();
            return 2;
        },
        .missing_value => |flag| {
            try err_w.print("error: a value is required for '{s}'\n", .{flag});
            try err_w.flush();
            return 2;
        },
        .missing_daemon_action => {
            try err_w.writeAll("error: `harness daemon` requires an action: install | uninstall | start | stop | restart | status\n");
            try err_w.flush();
            return 2;
        },
        .unknown_daemon_action => |act| {
            try err_w.print("error: unknown daemon action '{s}'\n", .{act});
            try err_w.flush();
            return 2;
        },
    };

    switch (action) {
        .version => {
            try out.print("harness {s}\n", .{build_info.version});
            try out.flush();
            return 0;
        },
        .help => {
            try out.writeAll(usage);
            try out.flush();
            return 0;
        },
        .engine => |eng| return runEngineBinary(gpa, arena, io, env, eng.subcmd, eng.rest, err_w),
        .mcp => {
            mcp_server.serveStdio(gpa, io, env) catch |e| {
                try err_w.print("harness mcp: {t}\n", .{e});
                try err_w.flush();
                return 1;
            };
            return 0;
        },
        .status, .sync, .login, .logout => {
            var in_buf: [8192]u8 = undefined;
            var stdin_r = Io.File.stdin().readerStreaming(io, &in_buf);
            const ctx: engine_cli.Context = .{
                .gpa = gpa,
                .io = io,
                .env = env,
                .port = ipcPortFrom(env),
                .out = out,
                .in = &stdin_r.interface,
                .interactive = stdinIsTty(),
                .err = err_w,
            };
            return switch (action) {
                .status => try engine_cli.status(ctx),
                .sync => try engine_cli.sync(ctx),
                .login => try engine_cli.login(ctx),
                .logout => try engine_cli.logout(ctx),
                else => unreachable,
            };
        },
        .daemon => |da| {
            const data_dir = try engine_cli.resolveDataDir(gpa, io, env);
            defer gpa.free(data_dir);
            return try engine_daemon.main(gpa, io, env, data_dir, da, out);
        },
        .update => |upd| {
            const edge_url = edgeUrlFrom(env);
            const data_dir = engine_cli.resolveDataDir(gpa, io, env) catch null;
            defer if (data_dir) |d| gpa.free(d);
            const code = try updates_host.runUpdateCli(gpa, io, edge_url, data_dir, upd.check, out, err_w);
            try out.flush();
            try err_w.flush();
            return code;
        },
        .visual_check => return runVisualCheck(gpa, io, err_w),
        .preview_servers => |ps| {
            try preview_service.runServersScan(gpa, io, ps.ignore_pid, out);
            try out.flush();
            return 0;
        },
        .preview_daemon => |pd| {
            try preview_service.runDaemon(gpa, io, pd.port, pd.catalog_file, pd.device_id, pd.device_name);
            return 0;
        },
        .update_daemon => |ud| {
            try updates_host.runUpdateDaemon(gpa, io, ud.edge_url orelse edgeUrlFrom(env));
            return 0;
        },
        .appshot => return runAppshot(gpa, io, env, err_w),
        .headed => |h| return runHeaded(gpa, arena, io, env, h.open_arg, err_w),
    }
}

fn ipcPortFrom(env: *const Map) u16 {
    if (env.get("HARNESS_IPC_PORT")) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return std.fmt.parseInt(u16, trimmed, 10) catch default_ipc_port;
    }
    return default_ipc_port;
}

fn edgeUrlFrom(env: *const Map) []const u8 {
    if (env.get("HARNESS_EDGE_URL")) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len > 0) return t;
    }
    return default_edge_url;
}

fn stdinIsTty() bool {
    if (comptime builtin.os.tag == .windows) {
        const w = struct {
            const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
            extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
            extern "kernel32" fn GetConsoleMode(hConsoleHandle: *anyopaque, lpMode: *u32) callconv(.winapi) i32;
        };
        const h = w.GetStdHandle(w.STD_INPUT_HANDLE) orelse return false;
        const invalid: *anyopaque = @ptrFromInt(std.math.maxInt(usize));
        if (h == invalid) return false;
        var mode: u32 = 0;
        return w.GetConsoleMode(h, &mode) != 0;
    }
    return std.c.isatty(0) != 0;
}

fn stdoutIsTty() bool {
    if (comptime builtin.os.tag == .windows) {
        const w = struct {
            const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
            extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
            extern "kernel32" fn GetConsoleMode(hConsoleHandle: *anyopaque, lpMode: *u32) callconv(.winapi) i32;
        };
        const h = w.GetStdHandle(w.STD_OUTPUT_HANDLE) orelse return false;
        const invalid: *anyopaque = @ptrFromInt(std.math.maxInt(usize));
        if (h == invalid) return false;
        var mode: u32 = 0;
        return w.GetConsoleMode(h, &mode) != 0;
    }
    return std.c.isatty(1) != 0;
}

fn attachParentConsole() void {
    const w = struct {
        const ATTACH_PARENT_PROCESS: u32 = 0xFFFF_FFFF;
        const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
        const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
        const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
        extern "kernel32" fn AttachConsole(dwProcessId: u32) callconv(.winapi) i32;
        extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn SetStdHandle(nStdHandle: u32, hHandle: *anyopaque) callconv(.winapi) i32;
    };
    const invalid: *anyopaque = @ptrFromInt(std.math.maxInt(usize));
    const ids = [_]u32{ w.STD_INPUT_HANDLE, w.STD_OUTPUT_HANDLE, w.STD_ERROR_HANDLE };
    var saved: [3]?*anyopaque = undefined;
    for (ids, 0..) |id, i| saved[i] = w.GetStdHandle(id);
    if (w.AttachConsole(w.ATTACH_PARENT_PROCESS) != 0) {
        for (ids, saved) |id, h_opt| {
            if (h_opt) |h| {
                if (h != invalid) _ = w.SetStdHandle(id, h);
            }
        }
    }
}

fn runVisualCheck(gpa: Allocator, io: Io, err_w: *Io.Writer) !u8 {
    var in_buf: [16384]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &in_buf);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    _ = reader.interface.streamRemaining(&aw.writer) catch |err| {
        try err_w.print("harness visual-check: reading stdin failed: {t}\n", .{err});
        try err_w.flush();
        return 1;
    };
    if (visual_luau.check(gpa, aw.written())) |msg| {
        defer gpa.free(msg);
        try err_w.print("{s}\n", .{msg});
        try err_w.flush();
        return 1;
    }
    return 0;
}

fn packUnixSunPath(sock_path: []const u8, dest: *[108]u8) error{NameTooLong}!usize {
    if (sock_path.len >= dest.len) return error.NameTooLong;
    @memset(dest, 0);
    @memcpy(dest[0..sock_path.len], sock_path);
    return sock_path.len + 1;
}

fn runAppshot(gpa: Allocator, io: Io, env: *const Map, err_w: *Io.Writer) !u8 {
    if (comptime builtin.os.tag != .linux) {
        try err_w.writeAll("harness appshot: only supported on Linux\n");
        try err_w.flush();
        return 1;
    }
    const linux = std.os.linux;
    const data_dir = try engine_cli.resolveDataDir(gpa, io, env);
    defer gpa.free(data_dir);
    const sock_path = try std.fs.path.join(gpa, &.{ data_dir, "appshot.sock" });
    defer gpa.free(sock_path);
    var addr_un: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    const path_nul_len = packUnixSunPath(sock_path, &addr_un.path) catch |e| {
        try err_w.print("harness appshot: {s}: {t}\n", .{ sock_path, e });
        try err_w.flush();
        return 1;
    };
    const sock_rc = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    switch (linux.errno(sock_rc)) {
        .SUCCESS => {},
        else => |eno| {
            try err_w.print("bind appshot sender: {t}\n", .{eno});
            try err_w.flush();
            return 1;
        },
    }
    const fd: i32 = @intCast(sock_rc);
    defer _ = linux.close(fd);
    const payload = "capture";
    const addr_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path_nul_len);
    const send_rc = linux.sendto(fd, payload.ptr, payload.len, 0, @ptrCast(&addr_un), addr_len);
    switch (linux.errno(send_rc)) {
        .SUCCESS => return 0,
        else => |eno| {
            try err_w.print("no running headed Harness at {s}: {t}\n", .{ sock_path, eno });
            try err_w.flush();
            return 1;
        },
    }
}

fn fileExistsExecutable(gpa: Allocator, path: []const u8) bool {
    const z = gpa.dupeSentinel(u8, path, 0) catch return false;
    defer gpa.free(z);
    if (comptime builtin.os.tag == .windows) {
        const w = struct {
            extern "c" fn _access(p: [*:0]const u8, mode: c_int) c_int;
        };
        return w._access(z, 0) == 0;
    }
    return std.c.access(z, std.c.X_OK) == 0;
}

fn locateBinary(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: *const Map,
    env_key: []const u8,
    bin_name: []const u8,
    check_cargo_target: bool,
) !?[]const u8 {
    if (env.get(env_key)) |explicit| {
        const t = std.mem.trim(u8, explicit, " \t\r\n");
        if (t.len > 0 and fileExistsExecutable(gpa, t)) return try arena.dupe(u8, t);
    }
    if (std.process.executablePathAlloc(io, arena)) |self_exe| {
        if (std.fs.path.dirname(self_exe)) |dir| {
            const sibling = try std.fs.path.join(arena, &.{ dir, bin_name });
            if (fileExistsExecutable(gpa, sibling)) return sibling;
            if (check_cargo_target) {
                for ([_][]const u8{ "app-dev", "dist", "release", "debug" }) |profile| {
                    const dev4 = try std.fs.path.join(arena, &.{ dir, "..", "..", "..", "..", "target", profile, bin_name });
                    if (fileExistsExecutable(gpa, dev4)) return dev4;
                    const dev3 = try std.fs.path.join(arena, &.{ dir, "..", "..", "..", "target", profile, bin_name });
                    if (fileExistsExecutable(gpa, dev3)) return dev3;
                }
            }
        }
    } else |_| {}
    if (env.get("PATH")) |path| {
        const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
        var it = std.mem.tokenizeScalar(u8, path, sep);
        while (it.next()) |dir| {
            const cand = try std.fs.path.join(arena, &.{ dir, bin_name });
            if (fileExistsExecutable(gpa, cand)) return cand;
        }
    }
    return null;
}

fn runEngineBinary(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: *const Map,
    subcmd: []const u8,
    rest: []const []const u8,
    err_w: *Io.Writer,
) !u8 {
    const bin_name = if (builtin.os.tag == .windows) "harness-engine.exe" else "harness-engine";
    const engine_exe = try locateBinary(gpa, arena, io, env, "HARNESS_ENGINE_BIN", bin_name, true) orelse {
        try err_w.print("harness: could not locate `{s}`\n", .{bin_name});
        try err_w.flush();
        return 1;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, engine_exe);
    try argv.append(arena, subcmd);
    for (rest) |a| try argv.append(arena, a);

    if (comptime builtin.os.tag != .windows) {
        const failed = std.process.replace(io, .{ .argv = argv.items, .environ_map = env });
        try err_w.print("harness: failed to exec {s}: {t}\n", .{ engine_exe, failed });
        try err_w.flush();
        return 1;
    }

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = env,
        .create_no_window = true,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

fn encodeUriComponent(arena: Allocator, raw: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const hex = "0123456789ABCDEF";
    for (raw) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~') {
            try w.writeByte(b);
        } else {
            try w.writeByte('%');
            try w.writeByte(hex[b >> 4]);
            try w.writeByte(hex[b & 0x0F]);
        }
    }
    return try aw.toOwnedSlice();
}

fn resolveOpenRoute(gpa: Allocator, arena: Allocator, io: Io, env: *const Map, open_arg: ?[]const u8, from_terminal: bool) !?[]const u8 {
    if (open_arg) |arg| {
        if (std.mem.startsWith(u8, arg, "harness://")) return arg;
        const canon = try std.Io.Dir.cwd().realPathFileAlloc(io, arg, arena);
        const stat = std.Io.Dir.cwd().statFile(io, canon, .{}) catch null;
        const folder = if (stat != null and stat.?.kind == .directory)
            canon
        else
            std.fs.path.dirname(canon) orelse return error.NotADirectory;
        const enc = try encodeUriComponent(arena, folder);
        return try std.fmt.allocPrint(arena, "harness://open/folder?path={s}", .{enc});
    }
    if (!from_terminal) return null;
    const cwd = std.process.currentPathAlloc(io, arena) catch return null;
    if (std.fs.path.dirname(cwd) == null) return null;
    if (env.get("HOME")) |home_raw| {
        if (std.Io.Dir.cwd().realPathFileAlloc(io, home_raw, arena)) |home| {
            _ = gpa;
            if (std.mem.eql(u8, cwd, home)) return null;
        } else |_| {}
    }
    const enc = try encodeUriComponent(arena, cwd);
    return try std.fmt.allocPrint(arena, "harness://open/folder?path={s}", .{enc});
}

fn macBundleExists(io: Io, arena: Allocator, bundle_path: []const u8) bool {
    const nano = std.fs.path.join(arena, &.{ bundle_path, "Contents", "MacOS", "harness-nano" }) catch return false;
    _ = Io.Dir.cwd().statFile(io, nano, .{}) catch return false;
    return true;
}

fn runHeaded(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: *const Map,
    open_arg: ?[]const u8,
    err_w: *Io.Writer,
) !u8 {
    const from_term = stdinIsTty() or stdoutIsTty();
    const route = resolveOpenRoute(gpa, arena, io, env, open_arg, from_term) catch |e| {
        try err_w.print("harness: {s}: {t}\n", .{ open_arg orelse "", e });
        try err_w.flush();
        return 2;
    };

    const self_exe = std.process.executablePathAlloc(io, arena) catch null;

    if (comptime builtin.os.tag == .macos) {
        const no_handoff = if (env.get("HARNESS_NO_BUNDLE_HANDOFF")) |v| v.len > 0 else false;
        const explicit_nano = if (env.get("HARNESS_NANO_BIN")) |v| std.mem.trim(u8, v, " \t\r\n").len > 0 else false;
        if (!no_handoff and !explicit_nano) {
            // The bundle launches harness-nano directly. A CLI invocation,
            // including from a script without a TTY, must reopen that same app
            // through LaunchServices rather than spawning a second Dock app.
            var handoff_bundle = if (self_exe) |p| @import("mac_bundle.zig").ancestor(p) else null;
            if (handoff_bundle == null) {
                if (macBundleExists(io, arena, "/Applications/Harness.app")) {
                    handoff_bundle = "/Applications/Harness.app";
                } else if (env.get("HOME")) |home| {
                    const user_app = try std.fs.path.join(arena, &.{ home, "Applications", "Harness.app" });
                    if (macBundleExists(io, arena, user_app)) handoff_bundle = user_app;
                }
            }
            if (handoff_bundle) |bundle| {
                var open_argv: std.ArrayList([]const u8) = .empty;
                try open_argv.appendSlice(arena, &.{ "/usr/bin/open", "-a", bundle });
                if (route) |r| {
                    const env_arg = try std.fmt.allocPrint(arena, "HARNESS_OPEN_ROUTE={s}", .{r});
                    try open_argv.appendSlice(arena, &.{ "--env", env_arg, r });
                }
                var open_child = try std.process.spawn(io, .{
                    .argv = open_argv.items,
                    .stdin = .inherit,
                    .stdout = .inherit,
                    .stderr = .inherit,
                });
                const term = try open_child.wait(io);
                return switch (term) {
                    .exited => |code| code,
                    else => 1,
                };
            }
        }
    }

    const nano_name = if (builtin.os.tag == .windows) "harness-nano.exe" else "harness-nano";
    const nano_bin = try locateBinary(gpa, arena, io, env, "HARNESS_NANO_BIN", nano_name, false) orelse {
        try err_w.print("harness: could not locate `{s}`\n", .{nano_name});
        try err_w.flush();
        return 1;
    };

    var child_env = try env.clone(arena);
    if (self_exe) |exe| try child_env.put("HARNESS_NANO_ENGINE_BIN", exe);
    if (route) |r| try child_env.put("HARNESS_OPEN_ROUTE", r);

    var child = try std.process.spawn(io, .{
        .argv = &.{nano_bin},
        .environ_map = &child_env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

const testing = std.testing;

test "cli_main parses subcommands, flags, and unexpected arguments" {
    try testing.expectEqual(Action.version, parseArgs(&.{"--version"}).ok);
    try testing.expectEqual(Action.version, parseArgs(&.{"-V"}).ok);
    try testing.expectEqual(Action.help, parseArgs(&.{"--help"}).ok);
    try testing.expectEqual(Action.mcp, parseArgs(&.{"mcp"}).ok);
    try testing.expectEqual(Action.visual_check, parseArgs(&.{"visual-check"}).ok);

    const upd_check = parseArgs(&.{ "update", "--check" }).ok;
    try testing.expect(upd_check.update.check);

    const pd = parseArgs(&.{ "preview-daemon", "--port", "7331", "--device-id", "d1", "--device-name", "Mac", "--catalog", "/tmp/c.json" }).ok;
    try testing.expectEqual(@as(u16, 7331), pd.preview_daemon.port);
    try testing.expectEqualStrings("d1", pd.preview_daemon.device_id);
    try testing.expectEqualStrings("Mac", pd.preview_daemon.device_name);
    try testing.expectEqualStrings("/tmp/c.json", pd.preview_daemon.catalog_file.?);

    const bad = parseArgs(&.{"--invalid-startup-test-option"});
    try testing.expectEqualStrings("--invalid-startup-test-option", bad.bad_arg);

    const headed = parseArgs(&.{"/tmp/proj"}).ok;
    try testing.expectEqualStrings("/tmp/proj", headed.headed.open_arg.?);
}

test "cli_main packUnixSunPath enforces null-terminated 108-byte AF_UNIX bound" {
    var buf: [108]u8 = undefined;
    const len = try packUnixSunPath("/tmp/appshot.sock", &buf);
    try testing.expectEqual(@as(usize, "/tmp/appshot.sock".len + 1), len);
    try testing.expectEqualStrings("/tmp/appshot.sock", buf[0.."/tmp/appshot.sock".len]);
    try testing.expectEqual(@as(u8, 0), buf["/tmp/appshot.sock".len]);

    const max_ok: [107]u8 = @splat('a');
    try testing.expectEqual(@as(usize, 108), try packUnixSunPath(&max_ok, &buf));
    try testing.expectEqual(@as(u8, 0), buf[107]);

    const too_long: [108]u8 = @splat('a');
    try testing.expectError(error.NameTooLong, packUnixSunPath(&too_long, &buf));
}

test "cli_main stripWaitForExit accepts optional relaunch pid before subcommand" {
    const plain = stripWaitForExit(&.{"--version"}).ok;
    try testing.expect(plain.pid == null);
    try testing.expectEqual(@as(usize, 1), plain.rest.len);

    const waited = stripWaitForExit(&.{ "--wait-for-exit", "4242" }).ok;
    try testing.expectEqual(@as(?u32, 4242), waited.pid);
    try testing.expectEqual(@as(usize, 0), waited.rest.len);
    try testing.expect(parseArgs(waited.rest).ok.headed.open_arg == null);

    const with_sub = stripWaitForExit(&.{ "--wait-for-exit", "77", "update" }).ok;
    try testing.expectEqual(@as(?u32, 77), with_sub.pid);
    try testing.expect(!parseArgs(with_sub.rest).ok.update.check);

    try testing.expectEqualStrings("--wait-for-exit", stripWaitForExit(&.{"--wait-for-exit"}).missing_value);
    try testing.expectEqualStrings("not-a-pid", stripWaitForExit(&.{ "--wait-for-exit", "not-a-pid" }).bad_arg);
}
