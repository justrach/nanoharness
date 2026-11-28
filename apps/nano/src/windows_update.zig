//! Update the per-user Windows package as a directory, never as a series of
//! running executable replacements. The helper is a copy of the current CLI,
//! outside both the running install and the verified payload.
const std = @import("std");
const builtin = @import("builtin");
const host = @import("updates_host.zig");
const build_info = @import("build_info");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;
const join = std.fs.path.join;
const Map = std.process.Environ.Map;
const launcher = "harness.exe";
const desktop = "harness-nano.exe";
const engine = "harness-engine.exe";
const install_name = "Codegraff Harness";
const stage_prefix = ".harness-update-";
const helper_name = "apply.exe";
const payload_name = "package";
pub const helper_flag = "--apply-windows-update";
pub const failure_env = "HARNESS_WINDOWS_UPDATE_FAILED";
pub const Token = [32]u8;

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.fs.path.isSep(x) and std.fs.path.isSep(y)) continue;
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn installPath(gpa: Allocator, env: *const Map) ![]u8 {
    const local = env.get("LOCALAPPDATA") orelse return error.NoLocalAppData;
    if (!std.fs.path.isAbsolute(local)) return error.NoLocalAppData;
    return join(gpa, &.{ local, "Programs", install_name });
}

fn packagePresent(gpa: Allocator, io: Io, root: []const u8) !void {
    for ([_][]const u8{ launcher, desktop, engine, "WebView2Loader.dll" }) |name| {
        const path = try join(gpa, &.{ root, name });
        defer gpa.free(path);
        const stat = try Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (stat.kind != .file or stat.size == 0) return error.IncompletePackage;
    }
    const path = try join(gpa, &.{ root, "harness-update.json" });
    defer gpa.free(path);
    const bytes = try Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
    defer gpa.free(bytes);
    const config = try std.json.parseFromSlice(struct { releases_url: []const u8 }, gpa, bytes, .{ .ignore_unknown_fields = true });
    defer config.deinit();
    if (!std.mem.eql(u8, config.value.releases_url, host.github_latest)) return error.UnmanagedInstall;
}

/// Only the shipped x64 per-user layout is supported. Never use a launcher
/// from PATH, a source checkout, or a configured engine override to update.
pub fn findInstall(gpa: Allocator, io: Io, env: *const Map) ![]u8 {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.UnsupportedPlatform;
    const root = try installPath(gpa, env);
    errdefer gpa.free(root);
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    const expected = try join(gpa, &.{ root, desktop });
    defer gpa.free(expected);
    if (!samePath(exe, expected)) return error.UnmanagedInstall;
    if (env.get("HARNESS_ENGINE_BIN") != null or env.get("HARNESS_NANO_NO_ENGINE_START") != null or env.get("HARNESS_NANO_BIN") != null) return error.UnmanagedInstall;
    if (env.get("HARNESS_NANO_ENGINE_BIN")) |override| {
        const cli = try join(gpa, &.{ root, launcher });
        defer gpa.free(cli);
        if (!samePath(cli, override)) return error.UnmanagedInstall;
    }
    const data = try @import("engine_cli.zig").resolveDataDir(gpa, io, env);
    defer gpa.free(data);
    if (!std.fs.path.isAbsolute(data) or samePath(data, root) or
        (data.len > root.len and std.fs.path.isSep(data[root.len]) and samePath(data[0..root.len], root))) return error.UnmanagedInstall;
    try packagePresent(gpa, io, root);
    return root;
}

fn stagePath(gpa: Allocator, root: []const u8, token: Token) ![]u8 {
    for (&token) |c| if (!std.ascii.isHex(c)) return error.InvalidStage;
    var name: [stage_prefix.len + @sizeOf(Token)]u8 = undefined;
    @memcpy(name[0..stage_prefix.len], stage_prefix);
    @memcpy(name[stage_prefix.len..], &token);
    return join(gpa, &.{ std.fs.path.dirname(root) orelse return error.InvalidStage, &name });
}

pub fn discard(gpa: Allocator, io: Io, env: *const Map, token: Token) void {
    const root = installPath(gpa, env) catch return;
    defer gpa.free(root);
    const work = stagePath(gpa, root, token) catch return;
    defer gpa.free(work);
    Dir.cwd().deleteTree(io, work) catch {};
}

fn noRestart(_: ?*anyopaque, _: []const u8) void {}

/// Download from the official feed, require a signature, verify the exact
/// Windows ZIP, and unpack only after verification. The live directory is
/// untouched until the user opts in to restart.
pub fn stage(gpa: Allocator, io: Io, env: *const Map, target: []const u8) !Token {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try findInstall(arena, io, env);
    var runner: @import("proc_seam.zig").SystemRunner = .{ .io = io };
    var http_io = io;
    var updater: host.Updater = .{
        .gpa = gpa,
        .io = io,
        .install = .{ .kind = .unmanaged },
        .automatic = false,
        .edge_url = "",
        .current_version = build_info.version,
        .releases_override = host.github_latest,
        .http = .{ .ctx = &http_io, .get_fn = host.stdGet, .download_fn = host.stdDownload },
        .runner = runner.runner(),
        .restarter = .{ .restart_fn = noRestart },
    };
    const manifest = switch (try updater.fetchLatest(arena)) {
        .ok => |m| m,
        .err => return error.ReleaseManifestUnavailable,
    };
    if (try updater.refuseUnsigned(arena, manifest) != null) return error.UnverifiedReleaseManifest;
    if (!std.mem.eql(u8, manifest.version, target) or !host.versionNewer(target, build_info.version)) return error.ReleaseChanged;

    var random: [16]u8 = undefined;
    io.random(&random);
    const token = std.fmt.bytesToHex(random, .lower);
    const dir = try stagePath(arena, root, token);
    try Dir.cwd().createDir(io, dir, .default_dir);
    errdefer Dir.cwd().deleteTree(io, dir) catch {};
    const zip_path = try join(arena, &.{ dir, "release.zip" });
    const asset = try std.fmt.allocPrint(arena, "harness-{s}-windows-x86_64.zip", .{target});
    if (try updater.download(arena, io, manifest, asset, zip_path) != null) return error.UnverifiedWindowsArchive;
    const payload = try join(arena, &.{ dir, payload_name });
    var dest = try Dir.cwd().createDirPathOpen(io, payload, .{});
    defer dest.close(io);
    {
        const file = try Dir.cwd().openFile(io, zip_path, .{});
        defer file.close(io);
        var buf: [16 * 1024]u8 = undefined;
        var reader = file.reader(io, &buf);
        try std.zip.extract(dest, &reader, .{ .allow_backslashes = true });
    }
    try packagePresent(arena, io, payload);
    try Dir.cwd().deleteFile(io, zip_path);
    const cli = try join(arena, &.{ root, launcher });
    const helper = try join(arena, &.{ dir, helper_name });
    const data = try Dir.cwd().readFileAlloc(io, cli, arena, .limited(32 << 20));
    try Dir.cwd().writeFile(io, .{ .sub_path = helper, .data = data });
    return token;
}

const win = struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn QueryFullProcessImageNameW(process: *anyopaque, flags: u32, buf: [*]u16, size: *u32) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) i32;
};

/// Open by PID but verify the actual image, not just the name in a PID file.
/// A missing PID is fine; an inaccessible or different process isn't.
fn openProcess(gpa: Allocator, pid: u32, expected: []const u8) !?*anyopaque {
    const handle = win.OpenProcess(0x0010_1000, 0, pid) orelse {
        if (win.GetLastError() == 87) return null; // ERROR_INVALID_PARAMETER: no such PID
        return error.CannotInspectProcess;
    };
    errdefer _ = win.CloseHandle(handle);
    var image: [32768]u16 = undefined;
    var len: u32 = image.len;
    if (win.QueryFullProcessImageNameW(handle, 0, &image, &len) == 0) return error.CannotInspectProcess;
    const path = try std.unicode.utf16LeToUtf8Alloc(gpa, image[0..len]);
    defer gpa.free(path);
    if (!samePath(path, expected)) return error.UnexpectedProcess;
    return handle;
}

/// A stale PID for an already exited engine does not require an RPC. A live
/// engine not belonging to this Windows package is never stopped here.
pub fn localEnginePid(gpa: Allocator, io: Io, env: *const Map, root: []const u8) !?u32 {
    const data = try @import("engine_cli.zig").resolveDataDir(gpa, io, env);
    defer gpa.free(data);
    const lock_path = try join(gpa, &.{ data, "engine.lock" });
    defer gpa.free(lock_path);
    // The engine leaves its PID sidecar behind on exit. A free lock takes
    // precedence over that stale PID, even if Windows has reused the PID.
    if (Dir.cwd().openFile(io, lock_path, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true })) |lock| {
        lock.close(io);
        return null;
    } else |err| switch (err) {
        error.FileNotFound => return null,
        error.WouldBlock => {},
        else => return err,
    }
    const pid_path = try join(gpa, &.{ data, "engine.lock.pid" });
    defer gpa.free(pid_path);
    const raw = try Dir.cwd().readFileAlloc(io, pid_path, gpa, .limited(64));
    defer gpa.free(raw);
    const pid = std.fmt.parseUnsigned(u32, std.mem.trim(u8, raw, " \r\n\t"), 10) catch return error.InvalidEnginePid;
    if (pid <= 1 or pid == win.GetCurrentProcessId()) return error.InvalidEnginePid;
    const path = try join(gpa, &.{ root, engine });
    defer gpa.free(path);
    const handle = try openProcess(gpa, pid, path) orelse return null;
    _ = win.CloseHandle(handle);
    return pid;
}

pub fn startHelper(gpa: Allocator, io: Io, root: []const u8, token: Token, engine_pid: ?u32) !void {
    const dir = try stagePath(gpa, root, token);
    defer gpa.free(dir);
    const helper = try join(gpa, &.{ dir, helper_name });
    defer gpa.free(helper);
    var parent_buf: [12]u8 = undefined;
    var engine_buf: [12]u8 = undefined;
    const child = try std.process.spawn(io, .{
        .argv = &.{ helper, helper_flag, &token, try std.fmt.bufPrint(&parent_buf, "{d}", .{win.GetCurrentProcessId()}), try std.fmt.bufPrint(&engine_buf, "{d}", .{engine_pid orelse 0}) },
        .cwd = .{ .path = dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    _ = win.CloseHandle(child.thread_handle);
    _ = win.CloseHandle(child.id.?);
}

fn waitForExit(gpa: Allocator, pid: u32, image: []const u8) !void {
    if (pid == 0) return;
    const handle = try openProcess(gpa, pid, image) orelse return;
    defer _ = win.CloseHandle(handle);
    if (win.WaitForSingleObject(handle, 30_000) != 0) return error.ProcessStillRunning;
}

fn move(gpa: Allocator, io: Io, from: []const u8, to: []const u8) !void {
    const src = try std.unicode.utf8ToUtf16LeAllocZ(gpa, from);
    defer gpa.free(src);
    const dst = try std.unicode.utf8ToUtf16LeAllocZ(gpa, to);
    defer gpa.free(dst);
    // The old launcher exits just after its child. Allow a short sharing
    // violation without forcibly terminating anyone.
    for (0..20) |_| {
        if (win.MoveFileExW(src, dst, 8) != 0) return;
        switch (win.GetLastError()) {
            5, 32, 33 => try Io.sleep(io, .fromMilliseconds(100), .awake),
            else => return error.MoveFailed,
        }
    }
    return error.InstallInUse;
}

fn replacePackage(gpa: Allocator, io: Io, root: []const u8, payload: []const u8, previous: []const u8, start: anytype) !void {
    try move(gpa, io, root, previous);
    move(gpa, io, payload, root) catch |err| {
        move(gpa, io, previous, root) catch return error.RollbackFailed;
        return err;
    };
    start.launch() catch |err| {
        move(gpa, io, root, payload) catch return error.RollbackFailed;
        move(gpa, io, previous, root) catch return error.RollbackFailed;
        return err;
    };
}

const Launch = struct {
    gpa: Allocator,
    io: Io,
    env: *const Map,
    path: []const u8,
    cwd: []const u8,

    fn launch(self: Launch) !void {
        try self.run(false);
    }

    fn run(self: Launch, failed: bool) !void {
        var child_env = try self.env.clone(self.gpa);
        defer child_env.deinit();
        _ = child_env.swapRemove("HARNESS_OPEN_ROUTE");
        _ = child_env.swapRemove(failure_env);
        if (failed) try child_env.put(failure_env, "1");
        const child = try std.process.spawn(self.io, .{
            .argv = &.{self.path},
            .environ_map = &child_env,
            .cwd = .{ .path = self.cwd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        });
        _ = win.CloseHandle(child.thread_handle);
        _ = win.CloseHandle(child.id.?);
    }
};

pub fn runHelper(gpa: Allocator, io: Io, env: *const Map, args: []const []const u8) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (args.len != 3 or args[0].len != @sizeOf(Token)) return error.InvalidStage;
    const token = args[0][0..@sizeOf(Token)].*;
    const parent = try std.fmt.parseUnsigned(u32, args[1], 10);
    const engine_pid = try std.fmt.parseUnsigned(u32, args[2], 10);
    if (parent <= 1 or parent == win.GetCurrentProcessId()) return error.InvalidStage;
    const root = try installPath(gpa, env);
    const work = try stagePath(gpa, root, token);
    const helper = try join(gpa, &.{ work, helper_name });
    const exe = try std.process.executablePathAlloc(io, gpa);
    if (!samePath(exe, helper)) return error.InvalidStage;
    const ui = try join(gpa, &.{ root, desktop });
    const engine_path = try join(gpa, &.{ root, engine });
    const cli = try join(gpa, &.{ root, launcher });
    const payload = try join(gpa, &.{ work, payload_name });
    const previous = try join(gpa, &.{ work, "previous" });
    const lock_path = try join(gpa, &.{ std.fs.path.dirname(root).?, ".harness-update.lock" });
    const start: Launch = .{ .gpa = gpa, .io = io, .env = env, .path = cli, .cwd = std.fs.path.dirname(root).? };
    try waitForExit(gpa, parent, ui);
    const lock = try Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
    defer lock.close(io);
    apply(gpa, io, root, payload, previous, engine_path, engine_pid, start) catch |err| {
        // Never start a partial package or remove the backup when recovery failed.
        if (err != error.RollbackFailed) try start.run(true);
        return err;
    };
    // Keep the old directory intact for recovery, including any extra files
    // the user put next to the executables. The live package is clean.
}

fn apply(gpa: Allocator, io: Io, root: []const u8, payload: []const u8, previous: []const u8, engine_path: []const u8, engine_pid: u32, start: Launch) !void {
    try waitForExit(gpa, engine_pid, engine_path);
    try packagePresent(gpa, io, root);
    try packagePresent(gpa, io, payload);
    const current = try std.process.run(gpa, io, .{ .argv = &.{ start.path, "--version" }, .create_no_window = true, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) });
    defer gpa.free(current.stdout);
    defer gpa.free(current.stderr);
    if (!current.term.success() or !std.mem.eql(u8, std.mem.trim(u8, current.stdout, " \r\n\t"), "harness " ++ build_info.version)) return error.InstallChanged;
    try replacePackage(gpa, io, root, payload, previous, start);
}

test "Windows update swaps the whole package and restores it when relaunch fails" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const names = [_][]const u8{ "live package", "next package", "previous package" };
    var paths: [3][]u8 = undefined;
    for (names, &paths) |name, *path| path.* = try join(gpa, &.{ base, name });
    defer for (paths) |path| gpa.free(path);
    for (names[0..2], [_][]const u8{ "old", "new" }) |name, version| {
        var dir = try temp.dir.createDirPathOpen(io, name, .{});
        defer dir.close(io);
        for ([_][]const u8{ launcher, desktop, engine }) |exe| try dir.writeFile(io, .{ .sub_path = exe, .data = version });
    }
    const Fake = struct {
        fail: bool,
        fn launch(self: @This()) !void {
            if (self.fail) return error.LaunchFailed;
        }
    };
    try std.testing.expectError(error.LaunchFailed, replacePackage(gpa, io, paths[0], paths[1], paths[2], Fake{ .fail = true }));
    try expectPackageVersion(temp.dir, names[0], "old");
    try expectPackageVersion(temp.dir, names[1], "new");
    // If the second rename fails, put the live directory back before relaunch.
    const missing = try join(gpa, &.{ base, "missing package" });
    defer gpa.free(missing);
    try std.testing.expectError(error.MoveFailed, replacePackage(gpa, io, paths[0], missing, paths[2], Fake{ .fail = false }));
    try expectPackageVersion(temp.dir, names[0], "old");
    try replacePackage(gpa, io, paths[0], paths[1], paths[2], Fake{ .fail = false });
    try expectPackageVersion(temp.dir, names[0], "new");
    try expectPackageVersion(temp.dir, names[2], "old");
}

fn expectPackageVersion(base: Dir, name: []const u8, version: []const u8) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var dir = try base.openDir(io, name, .{});
    defer dir.close(io);
    for ([_][]const u8{ launcher, desktop, engine }) |exe| {
        const bytes = try dir.readFileAlloc(io, exe, gpa, .limited(8));
        defer gpa.free(bytes);
        try std.testing.expectEqualStrings(version, bytes);
    }
}
