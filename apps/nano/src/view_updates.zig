//! Desktop update surfaces for Harness and the managed Codegraff engine
//! (`crates/ui/src/shell/app_update.rs` and `crates/ui/src/shell.rs`
//! `render_graff_notice`):
//! - `#sidebar-graff-update-row` and `#sidebar-update-row` in the sidebar
//!   footer above the account avatar (bottom-left).
//! - `#titlebar-update` in the titlebar's left cluster when the sidebar is
//!   collapsed or in Settings.
//! - `#app-updated` and `#graff-notice` floating cards at the bottom-right.
//! - `olderEngineNotice` (`crates/ui/src/state.rs`) when attaching to an
//!   older background engine daemon.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const graff_update = @import("graff_update.zig");
const agent_updates = @import("agent_updates.zig");
const rules = @import("rules.zig");
const App = @import("app.zig").App;

pub const max_highlights = 4;

pub const GraffKind = enum {
    none,
    updating,
    updated,
    available,
};

pub const RestartPlace = enum {
    none,
    sidebar_row,
    titlebar,
};

// Worker-to-main handoff. The rest of the app-update UI state is main-owned.
const windows_update = @import("windows_update.zig");

const AppInstallResult = struct {
    windows_stage: ?windows_update.Token = null,
    installed: [32]u8 = undefined,
    installed_len: usize = 0,
    failure: [160]u8 = undefined,
    failure_len: usize = 0,
};

pub const State = struct {
    lock: std.atomic.Value(bool) = .init(false),
    dirty: bool = false,
    graff_kind: GraffKind = .none,
    graff_from: [32]u8 = undefined,
    graff_from_len: usize = 0,
    graff_to: [32]u8 = undefined,
    graff_to_len: usize = 0,
    graff_highlights: [max_highlights][160]u8 = undefined,
    graff_highlight_lens: [max_highlights]usize = @splat(0),
    graff_highlights_total: usize = 0,
    graff_card_open: bool = true,
    graff_updating_manual: bool = false,
    graff_schedule: graff_update.Schedule = .{},

    restart_dismissed: [32]u8 = undefined,
    restart_dismissed_len: usize = 0,
    titlebar_dismissed: [32]u8 = undefined,
    titlebar_dismissed_len: usize = 0,
    /// True in the desktop app and unit tests; false only in legacy GPUI
    /// parity scenes recorded against an unmanaged binary.
    desktop_update: bool = true,
    /// Only a production macOS bundle or a managed per-user Windows package may install.
    app_install_result: ?AppInstallResult = null,
    app_install_checked: bool = false,
    app_can_install: bool = false,
    windows_stage: ?windows_update.Token = null,
    windows_worker: ?std.Thread = null,
    windows_restart_pending: bool = false,
    windows_stop_request: ?u64 = null,
    windows_stop_deadline: i64 = 0,
    windows_apply_failed: bool = false,
    /// On macOS the bundle has already been replaced; on Windows it is staged.
    app_installed: [32]u8 = undefined,
    app_installed_len: usize = 0,
    app_downloading: bool = false,
    restart_after_verify: bool = false,
    test_relaunch_count: u32 = 0,
    test_relaunch_version: [32]u8 = undefined,
    test_relaunch_version_len: usize = 0,
    app_checking: bool = false,
    app_checked_ms: i64 = 0,
    app_failed: [160]u8 = undefined,
    app_failed_len: usize = 0,
    app_updated: [32]u8 = undefined,
    app_updated_len: usize = 0,
    app_updated_until: f64 = 0,
    test_opened_terminal_count: u32 = 0,

    pub fn setAppInstalled(s: *State, version: []const u8) void {
        s.app_installed_len = 0;
        if (version.len > s.app_installed.len) return;
        @memcpy(s.app_installed[0..version.len], version);
        s.app_installed_len = version.len;
    }

    pub fn appFailed(s: *const State) ?[]const u8 {
        return if (s.app_failed_len == 0) null else s.app_failed[0..s.app_failed_len];
    }

    pub fn setAppFailed(s: *State, msg: []const u8) void {
        const trimmed = std.mem.trim(u8, msg, " \t\r\n");
        const n = @min(trimmed.len, s.app_failed.len);
        @memcpy(s.app_failed[0..n], trimmed[0..n]);
        s.app_failed_len = n;
    }

    pub fn graffFrom(s: *const State) ?[]const u8 {
        return if (s.graff_from_len == 0) null else s.graff_from[0..s.graff_from_len];
    }

    pub fn graffTo(s: *const State) ?[]const u8 {
        return if (s.graff_to_len == 0) null else s.graff_to[0..s.graff_to_len];
    }

    pub fn restartDismissed(s: *const State) ?[]const u8 {
        return if (s.restart_dismissed_len == 0) null else s.restart_dismissed[0..s.restart_dismissed_len];
    }

    pub fn titlebarDismissed(s: *const State) ?[]const u8 {
        return if (s.titlebar_dismissed_len == 0) null else s.titlebar_dismissed[0..s.titlebar_dismissed_len];
    }

    fn acquire(s: *State) void {
        while (s.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(s: *State) void {
        s.lock.store(false, .release);
    }

    pub fn publishGraff(
        s: *State,
        kind: GraffKind,
        from: ?[]const u8,
        to: []const u8,
        version_output: ?[]const u8,
    ) void {
        s.acquire();
        defer s.release();
        s.graff_kind = kind;
        if (from) |f| {
            const n = @min(f.len, s.graff_from.len);
            @memcpy(s.graff_from[0..n], f[0..n]);
            s.graff_from_len = n;
        } else {
            s.graff_from_len = 0;
        }
        const tn = @min(to.len, s.graff_to.len);
        @memcpy(s.graff_to[0..tn], to[0..tn]);
        s.graff_to_len = tn;
        s.graff_highlight_lens = @splat(0);
        s.graff_highlights_total = if (version_output) |out|
            whatsNew(&s.graff_highlights, &s.graff_highlight_lens, out, from, to)
        else
            0;
        s.graff_card_open = kind == .updated or kind == .available;
        s.graff_updating_manual = false;
        s.dirty = true;
    }

    pub fn clearGraff(s: *State) void {
        s.acquire();
        defer s.release();
        s.graff_kind = .none;
        s.graff_from_len = 0;
        s.graff_to_len = 0;
        s.graff_highlight_lens = @splat(0);
        s.graff_highlights_total = 0;
        s.graff_card_open = false;
        s.graff_updating_manual = false;
        s.dirty = true;
    }
};

pub const EngineVersionAction = enum {
    up_to_date,
    replace_old_session,
    notify_only,
};

/// True when the connected engine is older than `app_ver`.
pub fn isOlderEngine(app_ver: []const u8, engine_ver: ?[]const u8) bool {
    const app_parts = parseStrictDotted(app_ver) orelse return false;
    if (engine_ver) |ev| {
        const eng_parts = parseStrictDotted(ev) orelse return false;
        return compareParts(eng_parts, app_parts) == .lt;
    }
    return true;
}

/// Pure decision rule proved in `Nano/FrameSchedule.lean`
/// (`decideEngineVersionAction`): when a live desktop session connects to an
/// older background `harness headless` process after an update, kill and
/// replace the old engine session once instead of showing a warning banner.
pub fn decideEngineVersionAction(
    app_ver: []const u8,
    engine_ver: ?[]const u8,
    live_session: bool,
    already_replaced: bool,
) EngineVersionAction {
    if (!isOlderEngine(app_ver, engine_ver)) return .up_to_date;
    if (live_session and !already_replaced) return .replace_old_session;
    return .notify_only;
}

/// Pure version comparison (`older_engine_notice` in `crates/ui/src/state.rs`).
pub fn olderEngineNotice(buf: []u8, app_ver: []const u8, engine_ver: ?[]const u8) ?[]const u8 {
    if (!isOlderEngine(app_ver, engine_ver)) return null;
    if (engine_ver) |ev| {
        return std.fmt.bufPrint(
            buf,
            "Harness {s} is connected to an engine that is still running {s}, so some changes won't apply yet. To update it, run `harness daemon stop`, then quit and reopen Harness. Chats that are running will stop.",
            .{ app_ver, ev },
        ) catch null;
    }
    return std.fmt.bufPrint(
        buf,
        "Harness {s} is connected to an engine that is still running an older version, so some changes won't apply yet. To update it, run `harness daemon stop`, then quit and reopen Harness. Chats that are running will stop.",
        .{app_ver},
    ) catch null;
}

const Parts = struct {
    nums: [6]u64 = @splat(0),
    len: usize = 0,
};

fn parseStrictDotted(raw: []const u8) ?Parts {
    const clean = std.mem.trim(u8, raw, " \t\r\n");
    const bare = std.mem.trimStart(u8, clean, "v");
    if (bare.len == 0) return null;
    var out: Parts = .{};
    var it = std.mem.splitScalar(u8, bare, '.');
    while (it.next()) |part| {
        if (part.len == 0 or out.len >= out.nums.len) return null;
        out.nums[out.len] = std.fmt.parseInt(u64, part, 10) catch return null;
        out.len += 1;
    }
    return if (out.len >= 3) out else null;
}

fn compareParts(a: Parts, b: Parts) std.math.Order {
    const n = @max(a.len, b.len);
    for (0..n) |i| {
        const x = if (i < a.len) a.nums[i] else 0;
        const y = if (i < b.len) b.nums[i] else 0;
        if (x != y) return std.math.order(x, y);
    }
    return .eq;
}

/// Extract "What's new" bullet lines from `graff --version` for releases in
/// `(from, to]` (or `== to` when `from` is null), matching
/// `crates/harness/src/graff_bundle.rs:whats_new`.
pub fn whatsNew(
    out_lines: *[max_highlights][160]u8,
    out_lens: *[max_highlights]usize,
    version_output: []const u8,
    from: ?[]const u8,
    to: []const u8,
) usize {
    const to_parts = parseStrictDotted(to) orelse return 0;
    const from_parts = if (from) |f| parseStrictDotted(f) else null;
    var total: usize = 0;
    var in_range = false;
    var lines = std.mem.splitScalar(u8, version_output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "•")) {
            const item = std.mem.trim(u8, trimmed["•".len..], " \t");
            if (in_range and item.len > 0) {
                if (total < max_highlights) {
                    const n = @min(item.len, out_lines[total].len);
                    @memcpy(out_lines[total][0..n], item[0..n]);
                    out_lens[total] = n;
                }
                total += 1;
            }
        } else if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and std.mem.indexOfAny(u8, std.mem.trim(u8, line, " \t"), " \t") == null) {
            if (parseStrictDotted(line)) |ver| {
                const le_to = compareParts(ver, to_parts) != .gt;
                const gt_from = if (from_parts) |fp| compareParts(ver, fp) == .gt else compareParts(ver, to_parts) == .eq;
                in_range = le_to and gt_from;
            }
        }
    }
    return total;
}

/// Pure placement rule (`restart_place` in `crates/ui/src/shell/app_update.rs`).
pub fn restartPlace(
    update_ver: ?[]const u8,
    sidebar_fits: bool,
    dismissed: ?[]const u8,
) RestartPlace {
    const ver = update_ver orelse return .none;
    if (dismissed) |d| if (std.mem.eql(u8, d, ver)) return .none;
    return if (sidebar_fits) .sidebar_row else .titlebar;
}

pub fn appUpdateVersion(a: *const App) ?[]const u8 {
    if (a.env) |env| {
        if (env.get("HARNESS_DEV_APP_UPDATE")) |v| if (std.mem.eql(u8, v, "1")) return "preview";
    }
    const latest = a.release.version() orelse return null;
    const current = @import("build_info").version;
    return if (graff_update.newer(latest, current)) latest else null;
}

/// Installed app update version ready to reopen into (`app_restart_version` in
/// `crates/ui/src/shell/app_update.rs`). Unstaged GitHub releases use the
/// titlebar indicator instead of crowding the sidebar footer.
pub fn appRestartVersion(a: *const App) ?[]const u8 {
    if (a.env) |env| {
        if (env.get("HARNESS_DEV_APP_UPDATE")) |v| if (std.mem.eql(u8, v, "1")) return "preview";
    }
    if (a.updates.app_downloading) return null;
    const latest = appUpdateVersion(a) orelse return null;
    return if (std.mem.eql(u8, a.updates.app_installed[0..a.updates.app_installed_len], latest)) latest else null;
}

pub fn sidebarFits(a: *const App) bool {
    return a.view.sidebar_open and !a.view.settings_open;
}

pub fn graffVisible(a: *const App) bool {
    const s = &a.updates;
    if (s.graff_kind == .none) return false;
    const to = s.graffTo() orelse return false;
    if (s.graff_kind == .updating) return true;
    if (a.settings.text("graffNoticeDismissed")) |d| {
        if (std.mem.eql(u8, d, to)) return false;
    }
    return true;
}

pub fn dismissGraff(a: *App) void {
    const to = a.updates.graffTo() orelse return;
    a.settings.setText("graffNoticeDismissed", to);
    a.updates.graff_card_open = false;
    a.redraw();
}

pub const UpdateAction = union(enum) {
    none,
    check,
    downloading,
    update: []const u8,
    restart: []const u8,
    retry: []const u8,
};

pub const UpdateSummary = struct {
    line: []const u8,
    action: UpdateAction,
};

/// Pure status line and button for Settings › Devices (`update_summary` in
/// `crates/ui/src/settings/devices.rs`).
pub fn updateSummary(buf: []u8, a: *const App, now_ms: i64) UpdateSummary {
    const latest = appUpdateVersion(a);
    if (!a.updates.desktop_update) {
        if (latest) |ver| {
            return .{
                .line = std.fmt.bufPrint(buf, "Update v{s} is available. Install the latest release to update.", .{ver}) catch "An update is available.",
                .action = .none,
            };
        }
        return .{
            .line = "This build doesn't update itself. Install the latest release to update.",
            .action = .none,
        };
    }
    const restart_ver = appRestartVersion(a);
    if (a.updates.app_checking and restart_ver == null and !a.updates.app_downloading) {
        return .{ .line = "Checking for updates…", .action = .none };
    }
    if (a.release.schedule.failures > 0 and restart_ver == null and !a.updates.app_downloading) {
        return .{ .line = "Couldn't check for updates. Will retry automatically; check your connection.", .action = .check };
    }
    if (a.updates.app_install_checked and !a.updates.app_can_install) {
        return .{
            .line = if (latest) |ver|
                std.fmt.bufPrint(buf, "v{s} is available. Update this installation manually; checks run hourly.", .{ver}) catch "Update available; install manually."
            else
                "Checks run hourly. This installation must be updated manually.",
            .action = if (a.updates.app_checking) .none else .check,
        };
    }
    if (restart_ver) |ver| {
        const line = if (a.updates.appFailed()) |failure| failure else if (builtin.os.tag == .windows)
            std.fmt.bufPrint(buf, "Harness v{s} is ready. Restart to update.", .{ver}) catch "Restart to update."
        else
            std.fmt.bufPrint(buf, "Harness v{s} is installed. Restart when you're ready to use it.", .{ver}) catch "Update installed. Restart when ready.";
        return .{ .line = line, .action = if (a.updates.windows_restart_pending) .none else .{ .restart = ver } };
    }
    if (a.updates.app_downloading) {
        const line = if (a.updates.restart_after_verify)
            "Checking and installing the latest update…"
        else if (latest) |ver|
            std.fmt.bufPrint(buf, "Downloading v{s}…", .{ver}) catch "Downloading update…"
        else
            "Downloading update…";
        return .{ .line = line, .action = .downloading };
    }
    if (a.updates.windows_apply_failed) {
        return .{
            .line = "Windows couldn't install the update. The previous version was kept. Close other Harness instances before retrying.",
            .action = if (latest) |ver| .{ .retry = ver } else .check,
        };
    }
    if (a.updates.appFailed()) |err| {
        if (latest) |ver| {
            return .{
                .line = std.fmt.bufPrint(buf, "Updating to v{s} failed: {s}", .{ ver, err }) catch "Update failed.",
                .action = .{ .retry = ver },
            };
        }
    }
    if (a.updates.app_checking) {
        return .{ .line = "Checking for updates…", .action = .none };
    }
    if (latest) |ver| {
        return .{
            .line = std.fmt.bufPrint(buf, "Harness v{s} is available.", .{ver}) catch "An update is available.",
            .action = .{ .update = ver },
        };
    }
    if (a.updates.appFailed()) |err| {
        return .{
            .line = std.fmt.bufPrint(buf, "Couldn't check for updates: {s}", .{err}) catch "Couldn't check for updates.",
            .action = .check,
        };
    }
    if (a.updates.app_checked_ms > 0) {
        var seen_buf: [32]u8 = undefined;
        const seen = @import("view_settings_devices.zig").lastSeen(&seen_buf, a.updates.app_checked_ms, now_ms);
        return .{
            .line = std.fmt.bufPrint(buf, "Up to date · checked {s}", .{seen}) catch "Up to date.",
            .action = .check,
        };
    }
    return .{ .line = "No release check completed yet.", .action = .check };
}

/// Call from App.tick, not a render/scroll callback. The real-clock deadline
/// survives sleep; minute wakeups also notice clock changes. Successful checks
/// install by default unless disabled; they never restart the app.
/// Returns seconds until another tick is needed, or null for fixtures/tests.
pub fn tick(a: *App) ?f32 {
    if (a.offscreen or builtin.is_test) return null;
    initialize(a);
    if (a.release.startIfDue()) {
        a.updates.app_checking = a.release.schedule.in_flight;
        a.redraw();
    }
    if (graff_update.startIfDue(a)) a.redraw();
    const now = a.nowMs();
    const app_delay = a.release.schedule.delaySeconds(now);
    const graff_delay = a.updates.graff_schedule.delaySeconds(now);
    return @min(app_delay, graff_delay);
}

pub fn checkForUpdates(a: *App) void {
    a.updates.app_failed_len = 0;
    if (!a.offscreen and !builtin.is_test) {
        initialize(a);
        a.release.start();
        a.updates.app_checking = a.release.schedule.in_flight;
        graff_update.checkNow(a);
    }
    a.redraw();
}

pub fn onReleaseChecked(a: *App) void {
    a.updates.app_checking = false;
    if (a.release.succeeded) {
        a.updates.app_checked_ms = a.nowMs();
        a.updates.app_failed_len = 0;
    } else {
        a.updates.setAppFailed("Release manifest unavailable. Try again when online.");
    }
    automaticallyInstall(a);
    a.redraw();
}

/// Only a fresh successful check may replace the verified running bundle.
/// Installation defaults on; the legacy restart preference is unrelated.
fn automaticallyInstall(a: *App) void {
    if (!a.settings.get(.automatically_install_updates) or !a.release.succeeded or a.updates.windows_restart_pending or a.updates.windows_apply_failed or
        a.release.schedule.in_flight or a.release.schedule.failures > 0 or
        appRestartVersion(a) != null or a.updates.app_downloading) return;
    if (a.env) |env| {
        if (env.get("HARNESS_AUTO_UPDATE")) |v| if (std.mem.eql(u8, v, "0")) return;
    }
    const ver = appUpdateVersion(a) orelse return;
    if (std.mem.eql(u8, ver, "preview")) return;
    initialize(a);
    if (!a.updates.app_can_install) return;
    startAppDownload(a, false);
}

pub fn triggerAppUpdate(a: *App, ver: []const u8) void {
    if (std.mem.eql(u8, ver, "preview")) return;
    initialize(a);
    if (!a.updates.app_can_install) {
        openExternalUrl("https://github.com/justrach/nanoharness/releases/latest");
        return;
    }
    if (a.updates.app_downloading or a.updates.windows_restart_pending) return;
    const latest = appUpdateVersion(a) orelse return;
    if (appRestartVersion(a)) |ready| {
        if (std.mem.eql(u8, ready, ver) and std.mem.eql(u8, latest, ver)) {
            startAppDownload(a, true);
            return;
        }
    }
    // A stale click must never restart into an older bundle. If the latest
    // target is already ready, wait for a click on that version's control.
    if (appRestartVersion(a) == null) startAppDownload(a, false);
}

fn startAppDownload(a: *App, restart_after_verify: bool) void {
    if (a.updates.app_downloading) return;
    a.updates.restart_after_verify = restart_after_verify;
    a.updates.app_downloading = true;
    a.updates.windows_apply_failed = false;
    a.updates.app_failed_len = 0;
    a.redraw();
    if (a.offscreen or builtin.is_test) return;
    var target = AppInstallResult{};
    if (comptime builtin.os.tag == .windows) {
        const ver = appUpdateVersion(a) orelse "";
        target.installed_len = @min(ver.len, target.installed.len);
        @memcpy(target.installed[0..target.installed_len], ver[0..target.installed_len]);
    }
    const t = std.Thread.spawn(.{}, appUpdateWorker, .{ a, target }) catch {
        a.updates.app_downloading = false;
        a.updates.restart_after_verify = false;
        a.updates.setAppFailed("couldn't start background installer");
        a.redraw();
        return;
    };
    if (comptime builtin.os.tag == .windows) {
        a.updates.windows_worker = t;
    } else t.detach();
}

/// Pure install identity. Never search /Applications, PATH or an engine
/// override: those can belong to a different install than the running app.
pub fn currentBundle(exe: []const u8, os: std.Target.Os.Tag) ?[]const u8 {
    if (os != .macos or !std.mem.startsWith(u8, exe, "/")) return null;
    const suffix = "/Contents/MacOS/harness-nano";
    if (!std.mem.endsWith(u8, exe, suffix)) return null;
    const bundle = exe[0 .. exe.len - suffix.len];
    return if (std.mem.endsWith(u8, bundle, ".app")) bundle else null;
}

pub fn updateCliFor(gpa: std.mem.Allocator, exe: []const u8, os: std.Target.Os.Tag) ?[]u8 {
    const bundle = currentBundle(exe, os) orelse return null;
    return std.fmt.allocPrint(gpa, "{s}/Contents/MacOS/harness", .{bundle}) catch null;
}

pub fn productionBundleId(id: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, id, " \t\r\n"), "harness.codegraff.app");
}

fn bundlePlistValue(gpa: std.mem.Allocator, io: std.Io, bundle: []const u8, key: []const u8) ?[]u8 {
    if (builtin.os.tag != .macos) return null;
    const plist = std.fmt.allocPrint(gpa, "{s}/Contents/Info.plist", .{bundle}) catch return null;
    defer gpa.free(plist);
    // Read binary and XML plists alike; fail closed for dev/standalone bundles.
    const r = std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/plutil", "-extract", key, "raw", "-o", "-", plist },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
    }) catch return null;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return switch (r.term) {
        .exited => |code| if (code == 0) gpa.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n")) catch null else null,
        else => null,
    };
}

fn productionBundle(gpa: std.mem.Allocator, io: std.Io, bundle: []const u8) bool {
    if (builtin.is_test) return false;
    const id = bundlePlistValue(gpa, io, bundle, "CFBundleIdentifier") orelse return false;
    defer gpa.free(id);
    return productionBundleId(id);
}

fn installedBundleVersion(gpa: std.mem.Allocator, io: std.Io, bundle: []const u8) ?[]u8 {
    if (!productionBundle(gpa, io, bundle)) return null;
    const ver = bundlePlistValue(gpa, io, bundle, "CFBundleShortVersionString") orelse return null;
    if (ver.len <= 32 and @import("updates_host.zig").versionNewer(ver, @import("build_info").version)) return ver;
    gpa.free(ver);
    return null;
}

fn findHarnessCli(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (builtin.os.tag != .macos or builtin.is_test) return null;
    const exe = std.process.executablePathAlloc(io, gpa) catch return null;
    defer gpa.free(exe);
    const bundle = currentBundle(exe, builtin.os.tag) orelse return null;
    if (!productionBundle(gpa, io, bundle)) return null;
    const cli = updateCliFor(gpa, exe, builtin.os.tag) orelse return null;
    std.Io.Dir.cwd().access(io, cli, .{}) catch {
        gpa.free(cli);
        return null;
    };
    return cli;
}

/// One install probe per session. Unsupported and source builds still check.
pub fn initialize(a: *App) void {
    if (a.updates.app_install_checked) return;
    a.updates.app_install_checked = true;
    if (a.offscreen or builtin.is_test) return;
    const path = if (comptime builtin.os.tag == .windows)
        windows_update.findInstall(a.gpa, a.io, a.env orelse return) catch return
    else
        findHarnessCli(a.gpa, a.io) orelse return;
    a.gpa.free(path);
    a.updates.app_can_install = true;
    if (comptime builtin.os.tag == .windows) {
        a.updates.windows_apply_failed = a.env.?.get(windows_update.failure_env) != null;
    }
}

pub fn cleanupWindowsUpdate(a: *App) void {
    if (a.updates.windows_worker) |worker| worker.join();
    const env = a.env orelse return;
    if (a.updates.windows_stage) |token| windows_update.discard(a.gpa, a.io, env, token);
    if (a.updates.app_install_result) |result| if (result.windows_stage) |token| {
        windows_update.discard(a.gpa, a.io, env, token);
    };
}

fn appUpdateWorker(a: *App, target: AppInstallResult) void {
    if (comptime builtin.os.tag == .windows) {
        var result = target;
        const env = a.env orelse return;
        result.windows_stage = windows_update.stage(a.gpa, a.io, env, target.installed[0..target.installed_len]) catch |err| {
            std.log.warn("Windows update staging: {t}", .{err});
            queueAppInstallResult(a, "", switch (err) {
                error.UnverifiedReleaseManifest, error.UnverifiedWindowsArchive => "Couldn't verify the Windows update. Check for updates and try again.",
                error.ReleaseChanged => "The release changed while checking. Check for updates and try again.",
                else => "Couldn't prepare the Windows update. Check your connection and disk space, then retry.",
            });
            return;
        };
        publishAppInstallResult(a, result);
        return;
    }
    const bin = findHarnessCli(a.gpa, a.io) orelse {
        queueAppInstallResult(a, "", "This installation cannot update itself. Install the latest release manually.");
        return;
    };
    defer a.gpa.free(bin);
    const res = std.process.run(a.gpa, a.io, .{
        .argv = &.{ bin, "update" },
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
    }) catch |err| {
        var ebuf: [96]u8 = undefined;
        queueAppInstallResult(a, "", std.fmt.bufPrint(&ebuf, "{t}", .{err}) catch "update command failed");
        return;
    };
    defer a.gpa.free(res.stdout);
    defer a.gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const outcome = classifyUpdateOutput(ok, res.stdout, res.stderr);
    const installed = if (outcome != .failed)
        installedBundleVersion(a.gpa, a.io, bin[0 .. bin.len - "/Contents/MacOS/harness".len])
    else
        null;
    defer if (installed) |ver| a.gpa.free(ver);
    const ready = confirmedAppVersion(outcome, installed, res.stdout);
    const failure = if (ready != null) "" else switch (outcome) {
        .installed => "Couldn't verify the installed Harness version. Try the update again.",
        .up_to_date => "The installer found no matching update. Check for updates and try again.",
        .failed => |line| line,
    };
    queueAppInstallResult(a, ready orelse "", failure);
}

fn queueAppInstallResult(a: *App, installed: []const u8, failure: []const u8) void {
    var result: AppInstallResult = .{};
    if (installed.len <= result.installed.len) {
        @memcpy(result.installed[0..installed.len], installed);
        result.installed_len = installed.len;
    }
    result.failure_len = @min(failure.len, result.failure.len);
    @memcpy(result.failure[0..result.failure_len], failure[0..result.failure_len]);
    publishAppInstallResult(a, result);
}

fn publishAppInstallResult(a: *App, result: AppInstallResult) void {
    a.updates.acquire();
    a.updates.app_install_result = result;
    a.updates.release();
    _ = nanoui.App.onMain(a, appUpdateDelivered);
}

pub const UpdateCommandOutcome = union(enum) {
    installed,
    up_to_date,
    failed: []const u8,
};

/// A no-op alone proves nothing: an already-swapped bundle is restartable
/// only when its independently read, newer version matches both CLI versions.
fn confirmedAppVersion(outcome: UpdateCommandOutcome, disk_version: ?[]const u8, stdout: []const u8) ?[]const u8 {
    const ver = disk_version orelse return null;
    switch (outcome) {
        .installed => return ver,
        .failed => return null,
        .up_to_date => {
            var buf: [160]u8 = undefined;
            const expected = std.fmt.bufPrint(&buf, "Harness {s} is up to date (latest: {s}).", .{ ver, ver }) catch return null;
            return if (std.mem.eql(u8, firstLine(stdout) orelse "", expected)) ver else null;
        },
    }
}

/// Pure classifier for `harness update` process output (ADR 0008). A no-op
/// is distinct from a bundle swap and never causes an automatic relaunch.
pub fn classifyUpdateOutput(exited_zero: bool, stdout: []const u8, stderr: []const u8) UpdateCommandOutcome {
    if (exited_zero and std.mem.indexOf(u8, stdout, "relaunch Harness to finish") != null) {
        return .installed;
    }
    if (exited_zero and std.mem.indexOf(u8, stdout, "is up to date") != null) {
        return .up_to_date;
    }
    const line = firstLine(stderr) orelse firstLine(stdout) orelse "update exited with an error";
    return .{ .failed = line };
}

fn firstLine(s: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len > 0) return t;
    }
    return null;
}

fn appUpdateDelivered(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    a.updates.acquire();
    const pending = a.updates.app_install_result;
    a.updates.app_install_result = null;
    a.updates.release();
    const restart = a.updates.restart_after_verify;
    a.updates.restart_after_verify = false;
    const result = pending orelse return;
    if (comptime builtin.os.tag == .windows) {
        if (a.updates.windows_worker) |worker| worker.join();
        a.updates.windows_worker = null;
        if (a.updates.windows_stage) |old| {
            if (a.env) |env| windows_update.discard(a.gpa, a.io, env, old);
        }
        a.updates.windows_stage = result.windows_stage;
    }
    a.updates.setAppInstalled(result.installed[0..result.installed_len]);
    a.updates.setAppFailed(result.failure[0..result.failure_len]);
    a.updates.app_downloading = false;
    // Applying an update is not permission to stop agents or close a window.
    // A separate, explicit Restart click starts a fresh manifest check, and
    // only that check's verified on-disk target may be relaunched.
    if (restart and result.installed_len > 0 and result.failure_len == 0) {
        const installed = result.installed[0..result.installed_len];
        const superseded = if (a.release.succeeded) (if (a.release.version()) |latest|
            @import("updates_host.zig").versionNewer(latest, installed)
        else
            false) else false;
        if (!superseded) restartIntoUpdate(a, installed);
    }
    a.redraw();
}

fn restartIntoUpdate(a: *App, target: []const u8) void {
    if (builtin.is_test) {
        a.updates.test_relaunch_count += 1;
        const n = @min(target.len, a.updates.test_relaunch_version.len);
        @memcpy(a.updates.test_relaunch_version[0..n], target[0..n]);
        a.updates.test_relaunch_version_len = n;
        return;
    }
    if (a.offscreen) return;
    if (comptime builtin.os.tag == .windows) {
        if (a.updates.windows_restart_pending) return;
        const editors = @import("app_file_editor.zig");
        if (editors.requestExit(a, .quit, .{ .ctx = a, .func = restartWindowsAfterEditors })) restartWindowsAfterEditors(a);
    } else if (builtin.os.tag == .macos) {
        const exe = std.process.executablePathAlloc(a.io, a.gpa) catch return;
        defer a.gpa.free(exe);
        const bundle = currentBundle(exe, builtin.os.tag) orelse return;
        const installed = installedBundleVersion(a.gpa, a.io, bundle);
        defer if (installed) |ver| a.gpa.free(ver);
        if (!std.mem.eql(u8, target, installed orelse "")) {
            a.updates.setAppInstalled("");
            a.updates.setAppFailed("The installed Harness version changed. Check for updates and try again.");
            a.redraw();
            return;
        }
        var pid_buf: [32]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()}) catch return;
        // Pass the bundle as an argument, never interpolate it into a shell.
        const cmd = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open -n \"$2\"";
        if (std.process.spawn(a.io, .{
            .argv = &.{ "/bin/sh", "-c", cmd, "harness-relaunch", pid, bundle },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        })) |child| {
            var c = child;
            _ = &c;
            a.flushRememberedTabs();
            @import("engine_start.zig").stopForUpdate(a);
            std.process.exit(0);
        } else |_| {
            a.updates.setAppFailed("Couldn't restart Harness. Quit and reopen it manually.");
            a.redraw();
        }
    } else {
        // No validated portable relaunch: never stop an engine or quit here.
        a.updates.setAppFailed("Quit and reopen Harness manually to use the update.");
        a.redraw();
    }
}

fn restartWindowsAfterEditors(ctx: *anyopaque) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    if (a.updates.windows_stage == null or appRestartVersion(a) == null or a.window == null) return;
    const env = a.env orelse return;
    const root = windows_update.findInstall(a.gpa, a.io, env) catch return windowsRestartFailed(a, "This Windows installation can no longer update itself.");
    defer a.gpa.free(root);
    const pid = windows_update.localEnginePid(a.gpa, a.io, env, root) catch return windowsRestartFailed(a, "Couldn't identify the bundled engine. Quit other Harness instances and retry.");
    if (pid) |local_pid| {
        a.updates.setAppFailed("");
        a.updates.windows_restart_pending = true;
        a.updates.windows_stop_request = a.engine.call("StopEngineForUpdate", .{ .pid = local_pid }, .of(App, a, windowsEngineStopped)) orelse
            return windowsRestartFailed(a, "Couldn't reach the local engine. Try again once it reconnects.");
        a.updates.windows_stop_deadline = a.nowMs() + 5000;
        nanoui.App.after(5000, a, windowsStopTimedOut);
        a.redraw();
    } else {
        startWindowsRestart(a, null);
    }
}

fn windowsStopTimedOut(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    const id = a.updates.windows_stop_request orelse return;
    if (a.nowMs() < a.updates.windows_stop_deadline) return;
    a.engine.cancel(id);
    windowsRestartFailed(a, "The engine didn't confirm shutdown. Try again once it reconnects.");
}

fn windowsEngineStopped(a: *App, id: u64, reply: @import("rpc.zig").Reply) void {
    if (a.updates.windows_stop_request != id) return;
    a.updates.windows_stop_request = null;
    a.updates.windows_restart_pending = false;
    if (reply != .ok or reply.ok != .object) return windowsRestartFailed(a, "The engine isn't ready to restart. Finish active work and close open terminals, then retry.");
    const pid = reply.ok.object.get("pid") orelse return windowsRestartFailed(a, "Couldn't verify the engine shutdown.");
    if (pid != .integer or pid.integer <= 1 or pid.integer > std.math.maxInt(u32)) return windowsRestartFailed(a, "Couldn't verify the engine shutdown.");
    startWindowsRestart(a, @intCast(pid.integer));
}

fn startWindowsRestart(a: *App, pid: ?u32) void {
    const env = a.env orelse return;
    const token = a.updates.windows_stage orelse return;
    const window = a.window orelse return;
    const root = windows_update.findInstall(a.gpa, a.io, env) catch return windowsRestartFailed(a, "This Windows installation can no longer update itself.");
    defer a.gpa.free(root);
    windows_update.startHelper(a.gpa, a.io, root, token, pid) catch return windowsRestartFailed(a, "Couldn't start the Windows update installer. Try again.");
    a.updates.windows_stage = null; // The helper now owns it.
    a.updates.windows_restart_pending = true;
    window.close();
}

fn windowsRestartFailed(a: *App, failure: []const u8) void {
    a.updates.windows_restart_pending = false;
    a.updates.windows_stop_request = null;
    a.updates.setAppFailed(failure);
    a.redraw();
}

pub fn openExternalUrl(url: []const u8) void {
    if (builtin.is_test) return;
    _ = nanoui.shell.openUrl(url);
}

pub const xcode_license_cmd = "sudo xcodebuild -license";

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

/// Phrases rather than loose words: `xcode` is also an npm package with a
/// LICENSE file. The engine's `contains_xcode_license_blocker`
/// (harness_updates.rs) matches the same ones.
const xcode_license_phrases = [_][]const u8{
    "xcodebuild -license",
    "xcode license",
    "xcode/ios license",
    "xcode and apple sdks license",
};

pub fn isXcodeLicenseBlocker(msg: ?[]const u8) bool {
    const text = msg orelse return false;
    for (xcode_license_phrases) |phrase| {
        if (containsAsciiIgnoreCase(text, phrase)) return true;
    }
    return false;
}

fn openTerminalApp(a: *App) void {
    if (builtin.is_test or a.offscreen) {
        a.updates.test_opened_terminal_count += 1;
        return;
    }
    if (builtin.os.tag == .macos) {
        // Open Terminal.app only; never execute `sudo` or auto-accept a license.
        if (std.process.spawn(a.io, .{
            .argv = &.{ "/usr/bin/open", "-a", "Terminal" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        })) |child| {
            var ch = child;
            _ = &ch;
        } else |_| {}
    }
}

/// Height contributed to the sidebar footer by any active update pills.
pub fn sidebarFooterExtraHeight(a: *const App) f32 {
    if (a.settings.uiMode() == .zen) return 0;
    var h: f32 = 0;
    if (graffVisible(a)) h += 34;
    if (restartPlace(appUpdateVersion(a), sidebarFits(a), a.updates.restartDismissed()) == .sidebar_row) h += 34;
    return h;
}

/// Bottom-left sidebar footer rows (`#sidebar-graff-update-row` and
/// `#sidebar-update-row`), rendered right above the account avatar row.
pub fn sidebarFooterRows(c: *ui.Context, a: *App, k: theme.Colors) void {
    a.updates.acquire();
    const was_dirty = a.updates.dirty;
    a.updates.dirty = false;
    a.updates.release();
    if (was_dirty) c.changed = true;

    if (a.settings.uiMode() == .zen) return;

    const show_graff = graffVisible(a);
    const update_ver = appUpdateVersion(a);
    const show_app = restartPlace(update_ver, sidebarFits(a), a.updates.restartDismissed()) == .sidebar_row;
    if (!show_graff and !show_app) return;

    const wrap = ui.div(c).column().wFull().pt(6).pb(2);
    defer wrap.end();
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    if (show_graff) {
        sidebarGraffRow(c, a, k);
    }
    if (show_app) {
        if (update_ver) |ver| sidebarAppUpdateRow(c, a, k, ver);
    }
}

fn sidebarGraffRow(c: *ui.Context, a: *App, k: theme.Colors) void {
    const to = a.updates.graffTo() orelse return;
    const kind = a.updates.graff_kind;
    const pad = ui.div(c).column().wFull().px(8).pt(4);
    defer pad.end();
    ui.key(c, "sidebar-graff-update-row");
    const row = ui.div(c).row().wFull().pl(8).pr(4).py(4).gap(8).itemsCenter().rounded(6)
        .bg(k.accent_wash).hover(k.accent.alpha(0.18)).border(k.accent.alpha(0.3)).borderW(1);
    defer row.end();
    {
        const label = switch (kind) {
            .updating => c.print("Updating Codegraff to v{s}…", .{to}),
            .updated => c.print("Codegraff v{s} · What's new", .{to}),
            .available => c.print("Update Codegraff to v{s}", .{to}),
            .none => "",
        };
        const hint = switch (kind) {
            .updating => "Codegraff is updating in the background; open chats keep their session.",
            .updated => "Codegraff engine updated. Click to view release highlights.",
            .available => "A newer Codegraff engine release is available.",
            .none => "",
        };
        ui.key(c, "sidebar-graff-update-open");
        const open_btn = tip.on(ui.div(c).row().grow().w(0).gap(6).itemsCenter(), k, .{ .text = hint, .delay = tip.quick });
        defer open_btn.end();
        icons.icon(c, .@"graff-mark", 13, k.accent, 0);
        const text_w = @import("view_sidebar.zig").widthOf(a) - 16 - 12 - 13 - 6 - 26;
        kit.ellipsisText(c, label, .{ .size = 11, .line_height = 15, .weight = .medium, .color = k.text }, @max(40, text_w));
        if (open_btn.clicked()) {
            a.updates.graff_card_open = !a.updates.graff_card_open;
            a.redraw();
        }
    }
    if (kind != .updating) {
        ui.key(c, "sidebar-graff-update-dismiss");
        const close_btn = tip.on(ui.div(c).row().size(18, 18).center().rounded(4).hover(k.ink(0.08)), k, .{
            .text = "Dismiss for this version",
            .delay = tip.quick,
        });
        defer close_btn.end();
        icons.icon(c, .close, 10, k.muted, 0);
        if (close_btn.clicked()) dismissGraff(a);
    }
}

fn sidebarAppUpdateRow(c: *ui.Context, a: *App, k: theme.Colors, ver: []const u8) void {
    const ready = appRestartVersion(a) != null;
    const pad = ui.div(c).column().wFull().px(8).pt(4);
    defer pad.end();
    ui.key(c, "sidebar-update-row");
    const row = ui.div(c).row().wFull().pl(8).pr(4).py(4).gap(8).itemsCenter().rounded(6)
        .bg(k.accent_wash).hover(k.accent.alpha(0.18)).border(k.accent.alpha(0.3)).borderW(1);
    defer row.end();
    {
        const failed = !ready and !a.updates.app_downloading and a.updates.appFailed() != null;
        const hint = if (ready)
            c.print("Harness v{s} is ready. Click to restart into it.", .{ver})
        else if (a.updates.restart_after_verify)
            "Checking and installing the latest release before restart."
        else if (failed)
            c.print("Updating to v{s} failed: {s}. Click to retry.", .{ ver, a.updates.appFailed().? })
        else
            c.print("Harness v{s} is available. {s}", .{ ver, if (a.updates.app_install_checked and !a.updates.app_can_install) "Click to view the release; install manually." else "Click to update." });
        const label = if (ready)
            "Restart to update"
        else if (a.updates.restart_after_verify)
            "Checking latest update…"
        else if (a.updates.app_downloading)
            c.print("Downloading v{s}…", .{ver})
        else if (a.updates.app_install_checked and !a.updates.app_can_install)
            "View release"
        else if (failed)
            "Retry update"
        else
            c.print("Update to v{s}", .{ver});
        ui.key(c, "sidebar-update-restart");
        const btn = tip.on(ui.div(c).row().grow().w(0).gap(6).itemsCenter(), k, .{ .text = hint, .delay = tip.quick });
        defer btn.end();
        icons.icon(c, .refresh, 13, k.accent, 0);
        const text_w = @import("view_sidebar.zig").widthOf(a) - 16 - 12 - 13 - 6 - 26;
        kit.ellipsisText(c, label, .{ .size = 11, .line_height = 15, .weight = .medium, .color = k.text }, @max(40, text_w));
        if (btn.clicked()) triggerAppUpdate(a, ver);
    }
    {
        ui.key(c, "sidebar-update-dismiss");
        const close_btn = tip.on(ui.div(c).row().size(18, 18).center().rounded(4).hover(k.ink(0.08)), k, .{
            .text = if (ready) "Not now: use the update when you reopen Harness" else "Dismiss for this version",
            .delay = tip.quick,
        });
        defer close_btn.end();
        icons.icon(c, .close, 10, k.muted, 0);
        if (close_btn.clicked()) {
            const n = @min(ver.len, a.updates.restart_dismissed.len);
            @memcpy(a.updates.restart_dismissed[0..n], ver[0..n]);
            a.updates.restart_dismissed_len = n;
            a.redraw();
        }
    }
}

pub fn titlebarVisible(a: *const App) bool {
    if (a.settings.uiMode() == .zen) return false;
    const ver = appUpdateVersion(a) orelse return false;
    if (appRestartVersion(a)) |rver| {
        if (restartPlace(rver, sidebarFits(a), a.updates.restartDismissed()) != .titlebar) return false;
    }
    if (a.updates.titlebarDismissed()) |d| if (std.mem.eql(u8, d, ver)) return false;
    return true;
}

/// The update button in the titlebar's left cluster when the sidebar is
/// collapsed (`render_update_control` in `crates/ui/src/shell/app_update.rs`).
pub fn titlebarControl(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!titlebarVisible(a)) return;
    const ver = appUpdateVersion(a).?;
    ui.div(c).w(4).end();
    ui.key(c, "titlebar-update");
    const ready = appRestartVersion(a) != null;
    const label = if (ready)
        c.print("v{s} is ready — click to restart now.", .{ver})
    else
        c.print("Harness v{s} is available. {s}", .{ ver, if (a.updates.app_install_checked and !a.updates.app_can_install) "Click to view the release; install manually." else "Click to update." });
    const b = tip.on(ui.div(c).row().size(24, 24).center().rounded(6).hover(k.hover).control(), k, .{ .text = label, .delay = tip.quick });
    defer b.end();
    icons.icon(c, .refresh, 15, k.accent, 0);
    if (ready) {
        ui.div(c).absolute().offset(24 - 3 - 6, 3).size(6, 6).roundedFull().bg(k.accent).end();
    }
    if (b.clicked()) triggerAppUpdate(a, ver);
}

/// Floating bottom-right card (`render_app_update_card` / `render_graff_notice`
/// in `crates/ui/src/shell.rs:9199, 10945`).
pub fn overlayCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.updates.app_updated_len > 0) {
        if (c.time >= a.updates.app_updated_until) {
            a.updates.app_updated_len = 0;
        } else {
            c.frameIn(@floatCast(a.updates.app_updated_until - c.time));
            return appUpdatedCard(c, a, k);
        }
    }
    if (!graffVisible(a) or !a.updates.graff_card_open) return;
    if (a.updates.graff_kind != .updated and a.updates.graff_kind != .available) return;
    graffNoticeCard(c, a, k);
}

pub const UnifiedKind = enum {
    app,
    engine,
    agent,
};

pub const UnifiedAction = union(enum) {
    none,
    app_update: []const u8,
    app_restart: []const u8,
    graff_update_now,
    graff_notes: []const u8,
    agent_rpc: struct {
        device_id: []const u8,
        method: []const u8,
        harness: []const u8,
    },
    open_settings,
    dismiss_done,
};

pub const UnifiedRow = struct {
    kind: UnifiedKind,
    id: []const u8,
    token: []const u8,
    title: []const u8,
    detail: []const u8,
    mark_id: []const u8,
    busy: bool = false,
    updated: bool = false,
    failed: bool = false,
    version_delta: ?[]const u8 = null,
    failure_headline: ?[]const u8 = null,
    failure_note: ?[]const u8 = null,
    xcode_license: bool = false,
    is_local: bool = false,
    skippable: bool = true,
    enabled: bool = true,
    action_label: ?[]const u8 = null,
    action: UnifiedAction = .none,

    pub fn isBatchUpdatable(r: UnifiedRow) bool {
        if (!r.enabled) return false;
        return switch (r.action) {
            .app_update, .graff_update_now => !r.failed,
            .agent_rpc => |rpc_act| std.mem.eql(u8, rpc_act.method, "ApplyHarnessUpdate") and !r.failed,
            else => false,
        };
    }
};

pub fn skipToken(alloc: std.mem.Allocator, st: agent_updates.Status) []const u8 {
    if (st.phase == .failed) {
        return std.fmt.allocPrint(alloc, "failed:{s}:{s}", .{
            st.latest_version orelse "",
            st.error_message orelse "",
        }) catch "failed";
    }
    return st.latest_version orelse st.installed_version orelse @tagName(st.phase);
}

fn deviceLabel(a: *const App, id: []const u8) []const u8 {
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, id)) return d.name;
    if (a.device_id) |me| if (std.mem.eql(u8, me, id)) return "This Mac";
    return id;
}

fn graffUpdateActionable(a: *const App) bool {
    return graffVisible(a) and (a.updates.graff_kind != .updated or a.updates.graff_updating_manual);
}

fn agentUpdateActionable(st: agent_updates.Status) bool {
    return st.showUpdateNotice() and st.phase != .updated;
}

pub fn collectUnifiedRows(a: *const App, alloc: std.mem.Allocator) []const UnifiedRow {
    var out: std.ArrayList(UnifiedRow) = .empty;

    // 1. Desktop app update (`app:harness`).
    if (appUpdateVersion(a)) |ver| {
        const dismissed = if (a.updates.restartDismissed()) |d| std.mem.eql(u8, d, ver) else false;
        const app_tok = if (a.updates.appFailed()) |err|
            (std.fmt.allocPrint(alloc, "failed:{s}:{s}", .{ ver, err }) catch ver)
        else
            ver;
        const skipped = !a.updates.app_downloading and appRestartVersion(a) == null and a.settings.isUpdateSkipped("app:harness", app_tok);
        if (!dismissed and !skipped) {
            const cur = @import("build_info").version;
            const ready = appRestartVersion(a) != null;
            const detail = if (ready)
                (std.fmt.allocPrint(alloc, "{s} \u{2192} {s} · Ready", .{ cur, ver }) catch "Ready to restart")
            else if (a.updates.app_downloading and a.updates.restart_after_verify)
                "Checking and installing the latest update…"
            else if (a.updates.app_downloading)
                (std.fmt.allocPrint(alloc, "Downloading v{s}…", .{ver}) catch "Downloading…")
            else if (a.updates.appFailed()) |err|
                err
            else
                (std.fmt.allocPrint(alloc, "{s} \u{2192} {s}", .{ cur, ver }) catch ver);

            out.append(alloc, .{
                .kind = .app,
                .id = "app:harness",
                .token = app_tok,
                .title = "Harness",
                .detail = detail,
                .mark_id = "graff",
                .busy = a.updates.app_downloading,
                .updated = ready,
                .failed = !ready and !a.updates.app_downloading and a.updates.appFailed() != null,
                .skippable = !a.updates.app_downloading,
                .enabled = !a.updates.app_downloading,
                .action_label = if (ready) "Restart" else if (a.updates.app_downloading) "Updating…" else if (a.updates.appFailed() != null) "Retry" else "Update",
                .action = if (ready) .{ .app_restart = ver } else if (a.updates.app_downloading) .none else .{ .app_update = ver },
            }) catch {};
        }
    }

    // 2. Managed Codegraff engine update (`engine:graff`).
    if (graffUpdateActionable(a)) {
        if (a.updates.graffTo()) |to| {
            const busy = a.updates.graff_kind == .updating or a.updates.graff_updating_manual;
            const skipped = !busy and a.settings.isUpdateSkipped("engine:graff", to);
            if (!skipped) {
                const detail = if (a.updates.graffFrom()) |from|
                    (std.fmt.allocPrint(alloc, "{s} \u{2192} {s}", .{ from, to }) catch to)
                else
                    (std.fmt.allocPrint(alloc, "v{s}", .{to}) catch to);
                out.append(alloc, .{
                    .kind = .engine,
                    .id = "engine:graff",
                    .token = to,
                    .title = "Codegraff",
                    .detail = detail,
                    .mark_id = "graff",
                    .busy = busy,
                    .updated = !busy and a.updates.graff_kind == .updated,
                    .skippable = !busy,
                    .enabled = !busy,
                    .action_label = if (busy) "Updating…" else if (a.updates.graff_kind == .updated) "Notes" else "Update",
                    .action = if (busy) .none else if (a.updates.graff_kind == .updated) .{ .graff_notes = to } else .graff_update_now,
                }) catch {};
            }
        }
    }

    // 3. CLI agent updates (`agent:<device>:<harness>`).
    var dev_with_notices: usize = 0;
    for (a.agent_updates.devices.items) |w| {
        var any_for_dev = false;
        for (w.statuses) |st| {
            if (!agentUpdateActionable(st)) continue;
            const row_id = std.fmt.allocPrint(alloc, "agent:{s}:{s}", .{ w.device_id, st.harness }) catch continue;
            const tok = skipToken(alloc, st);
            const active = st.phase.isActive();
            if (!active and a.settings.isUpdateSkipped(row_id, tok)) continue;
            any_for_dev = true;
            break;
        }
        if (any_for_dev) dev_with_notices += 1;
    }

    for (a.agent_updates.devices.items) |w| {
        const connected = w.online and w.connected;
        const dev_name = deviceLabel(a, w.device_id);
        const is_local = if (a.device_id) |me| std.mem.eql(u8, me, w.device_id) else false;
        for (w.statuses) |st| {
            if (!agentUpdateActionable(st)) continue;
            const row_id = std.fmt.allocPrint(alloc, "agent:{s}:{s}", .{ w.device_id, st.harness }) catch continue;
            const tok = skipToken(alloc, st);
            const active = st.phase.isActive();
            if (!active and a.settings.isUpdateSkipped(row_id, tok)) continue;

            const agent_title = agent_updates.agentName(st.harness);
            const version_delta: ?[]const u8 = if (st.installed_version != null and st.latest_version != null and !std.mem.eql(u8, st.installed_version.?, st.latest_version.?))
                (std.fmt.allocPrint(alloc, "{s} \u{2192} {s}", .{ st.installed_version.?, st.latest_version.? }) catch null)
            else
                null;
            const xcode_blocker = st.phase == .failed and isXcodeLicenseBlocker(st.error_message);
            const failure_headline: ?[]const u8 = if (xcode_blocker)
                (std.fmt.allocPrint(alloc, "Homebrew can\u{2019}t update {s} until you accept the Xcode license.", .{agent_title}) catch "Homebrew can\u{2019}t update until you accept the Xcode license.")
            else
                null;
            const failure_note: ?[]const u8 = if (st.phase != .failed)
                null
            else if (xcode_blocker)
                (if (is_local)
                    "Open Terminal, run sudo xcodebuild -license, review and accept the license, then retry."
                else
                    (std.fmt.allocPrint(alloc, "Run sudo xcodebuild -license on {s}, review and accept the license, then retry.", .{dev_name}) catch "Run sudo xcodebuild -license on that device, review and accept the license, then retry."))
            else
                st.error_message;

            const base_detail: []const u8 = if (st.phase == .failed) blk: {
                if (version_delta) |vd| break :blk vd;
                if (xcode_blocker) break :blk "Blocked by Xcode license";
                break :blk if (st.error_kind == .install) "Update failed" else "Couldn't check for updates";
            } else if (version_delta) |vd|
                vd
            else switch (st.phase) {
                .updated => if (st.latest_version orelse st.installed_version) |ver|
                    (std.fmt.allocPrint(alloc, "{s} \u{00b7} Updated", .{ver}) catch "Updated")
                else
                    "Updated",
                .waiting_for_idle => "Waiting for current run",
                .preparing => "Preparing update\u{2026}",
                .downloading => st.progress_message orelse "Downloading\u{2026}",
                .installing => "Installing\u{2026}",
                .verifying => "Verifying\u{2026}",
                .manual_action_required => "Check and update",
                else => if (st.latest_version) |lat|
                    (std.fmt.allocPrint(alloc, "v{s} available", .{lat}) catch "Update available")
                else
                    "Update available",
            };

            const detail = if (dev_with_notices > 1)
                (std.fmt.allocPrint(alloc, "{s} \u{00b7} {s}", .{ base_detail, dev_name }) catch base_detail)
            else
                base_detail;

            const action_label: ?[]const u8 = switch (st.phase) {
                .available => if (st.can_apply) "Update" else "Steps",
                .manual_action_required => if (st.can_apply) "Check and update" else null,
                .waiting_for_idle, .preparing, .downloading, .installing => "Cancel",
                .failed => if (st.can_apply and st.error_kind == .install) "Retry" else "Check",
                .updated => "Done",
                else => null,
            };

            const action: UnifiedAction = switch (st.phase) {
                .available => if (st.can_apply)
                    .{ .agent_rpc = .{ .device_id = w.device_id, .method = "ApplyHarnessUpdate", .harness = st.harness } }
                else
                    .open_settings,
                .manual_action_required => if (st.can_apply)
                    .{ .agent_rpc = .{ .device_id = w.device_id, .method = "ApplyHarnessUpdate", .harness = st.harness } }
                else
                    .none,
                .waiting_for_idle, .preparing, .downloading, .installing => .{ .agent_rpc = .{
                    .device_id = w.device_id,
                    .method = "CancelHarnessUpdate",
                    .harness = st.harness,
                } },
                .failed => .{ .agent_rpc = .{
                    .device_id = w.device_id,
                    .method = if (st.can_apply and st.error_kind == .install) "ApplyHarnessUpdate" else "CheckHarnessUpdates",
                    .harness = st.harness,
                } },
                .updated => .dismiss_done,
                else => .none,
            };

            const can_act = switch (action) {
                .agent_rpc => connected,
                .none => false,
                else => true,
            };

            out.append(alloc, .{
                .kind = .agent,
                .id = row_id,
                .token = tok,
                .title = agent_title,
                .detail = detail,
                .mark_id = st.harness,
                .busy = active,
                .updated = st.phase == .updated,
                .failed = st.phase == .failed,
                .version_delta = version_delta,
                .failure_headline = failure_headline,
                .failure_note = failure_note,
                .xcode_license = xcode_blocker,
                .is_local = is_local,
                .skippable = !active and st.phase != .updated,
                .enabled = can_act,
                .action_label = action_label,
                .action = action,
            }) catch {};
        }
    }

    return out.items;
}

pub fn topbarUpdatesCount(a: *const App) usize {
    var count: usize = 0;

    if (appUpdateVersion(a)) |ver| {
        const dismissed = if (a.updates.restartDismissed()) |d| std.mem.eql(u8, d, ver) else false;
        var tok_buf: [256]u8 = undefined;
        const app_tok = if (a.updates.appFailed()) |err|
            (std.fmt.bufPrint(&tok_buf, "failed:{s}:{s}", .{ ver, err }) catch ver)
        else
            ver;
        const skipped = !a.updates.app_downloading and appRestartVersion(a) == null and a.settings.isUpdateSkipped("app:harness", app_tok);
        if (!dismissed and !skipped) count += 1;
    }

    if (graffUpdateActionable(a)) {
        if (a.updates.graffTo()) |to| {
            const busy = a.updates.graff_kind == .updating or a.updates.graff_updating_manual;
            const skipped = !busy and a.settings.isUpdateSkipped("engine:graff", to);
            if (!skipped) count += 1;
        }
    }

    for (a.agent_updates.devices.items) |w| {
        for (w.statuses) |st| {
            if (!agentUpdateActionable(st)) continue;
            var id_buf: [192]u8 = undefined;
            const row_id = std.fmt.bufPrint(&id_buf, "agent:{s}:{s}", .{ w.device_id, st.harness }) catch continue;
            var tok_buf: [256]u8 = undefined;
            const tok = if (st.phase == .failed)
                (std.fmt.bufPrint(&tok_buf, "failed:{s}:{s}", .{
                    st.latest_version orelse "",
                    st.error_message orelse "",
                }) catch "failed")
            else
                (st.latest_version orelse st.installed_version orelse @tagName(st.phase));
            if (!st.phase.isActive() and a.settings.isUpdateSkipped(row_id, tok)) continue;
            count += 1;
        }
    }

    return count;
}

pub fn topbarUpdatesWidth(a: *const App) f32 {
    const n = topbarUpdatesCount(a);
    if (n == 0) return 0;
    const tiles: usize = @min(n, 3);
    const stack_w: f32 = 20 + @as(f32, @floatFromInt(tiles - 1)) * 15;
    return 5 + stack_w + 6 + 16 + 8;
}

pub const TrailingMetrics = struct { avail: u32, last_slot: u32 };

pub fn trailingMetrics(a: *const App) TrailingMetrics {
    return trailingMetricsFor(a, @import("window_chrome.zig").trailing);
}

pub fn trailingMetricsFor(a: *const App, caption_trailing: f32) TrailingMetrics {
    const avail_f = @max(0, a.view.chrome.width - caption_trailing);
    var last_f: f32 = avail_f;
    const strip = @import("view_tab_strip.zig");
    const chrome = @import("panel_chrome.zig");
    const github = @import("app_github_repository.zig");
    if (a.panels.files_open and a.view.chrome.files_width > 0) {
        last_f = @max(0, a.view.chrome.files_width - caption_trailing);
    } else if (a.tabs.layout()) |s| {
        const in_row = s.axis == .horizontal and !s.zoomed;
        const hp = if (strip.hasHost(a) and github.surface(a)) github.parentPane(a) else null;
        if (strip.hasHost(a) and hp == null and a.view.chrome.host_width > 0) {
            last_f = @max(0, a.view.chrome.host_width - caption_trailing);
        } else if (in_row and s.panes.items.len > 1) {
            const last_ix = s.panes.items.len - 1;
            if (strip.hasHost(a) and hp != null and hp.? == last_ix and a.view.chrome.host_width > 0) {
                last_f = @max(0, a.view.chrome.host_width - caption_trailing);
            } else {
                const span = chrome.paneSpanIn(a.view.chrome.chat_width, s.shares.items[last_ix], s.panes.items.len, true, chrome.zen_gutter);
                last_f = @max(0, span - caption_trailing);
            }
        } else if (strip.hasHost(a) and a.view.chrome.host_width > 0) {
            last_f = @max(0, a.view.chrome.host_width - caption_trailing);
        }
    } else if (strip.hasHost(a) and a.view.chrome.host_width > 0) {
        last_f = @max(0, a.view.chrome.host_width - caption_trailing);
    }
    return .{
        .avail = @intFromFloat(@round(@max(0, avail_f))),
        .last_slot = @intFromFloat(@round(@max(0, last_f))),
    };
}

pub fn topbarUpdatesButton(c: *ui.Context, a: *App, k: theme.Colors) void {
    a.updates.acquire();
    const was_dirty = a.updates.dirty;
    a.updates.dirty = false;
    a.updates.release();
    if (was_dirty) c.changed = true;

    const rows = collectUnifiedRows(a, c.alloc());
    if (rows.len == 0) {
        a.view.updates_anchor = null;
        a.view.updates_popover = false;
        return;
    }

    const tiles: usize = @min(rows.len, 3);
    const stack_w: f32 = 20 + @as(f32, @floatFromInt(tiles - 1)) * 15;
    var any_busy = false;
    var all_updated = true;
    for (rows) |r| {
        if (r.busy) any_busy = true;
        if (!r.updated) all_updated = false;
    }

    ui.key(c, "updates-button");
    const bg = if (a.view.updates_popover) k.hover else k.ink(if (k.dark) 0.085 else 0.055);
    const btn = tip.on(
        ui.div(c).row().h(28).pl(5).pr(8).gap(6).itemsCenter().roundedFull()
            .bg(bg).border(k.border).borderW(1).hover(k.hover).control(),
        k,
        .{ .text = if (rows.len == 1) "1 update" else c.print("{d} updates", .{rows.len}), .delay = tip.quick },
    );
    const clicked = btn.clicked();
    if (c.rects.get(c.node(btn.index).id)) |r| a.view.updates_anchor = r;
    {
        defer btn.end();
        {
            const stack = ui.div(c).row().size(stack_w, 20).itemsCenter();
            defer stack.end();
            var idx = tiles;
            while (idx > 0) {
                idx -= 1;
                const mark = icons.harnessMark(rows[idx].mark_id);
                const plate = ui.div(c).row().absolute().offset(@as(f32, @floatFromInt(idx)) * 15, 0)
                    .size(20, 20).center().roundedFull().bg(ui.Color.white)
                    .border(k.shell).borderW(1.5);
                defer plate.end();
                icons.icon(c, mark.name, 11, mark.brand orelse ui.Color.hex(0x18181b), 0);
            }
        }
        {
            const glyph = ui.div(c).row().size(16, 16).center();
            defer glyph.end();
            if (any_busy) {
                kit.snake(c, k);
            } else if (all_updated) {
                icons.icon(c, .check, 14, k.success, 0);
            } else {
                icons.icon(c, .@"download-minimalistic", 14, k.text.alpha(0.88), 0);
            }
        }
    }
    if (clicked) {
        const was_open = a.view.updates_popover;
        if (!was_open) @import("view.zig").closeTransientPopovers(a);
        a.view.updates_popover = !was_open;
        a.redraw();
    }
}

pub fn updatesPopover(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.view.updates_popover) return;
    const rows = collectUnifiedRows(a, c.alloc());
    if (rows.len == 0) {
        a.view.updates_popover = false;
        return;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
        a.view.updates_popover = false;
        c.changed = true;
        return;
    }
    {
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(5);
        defer back.end();
        if (back.clicked()) {
            a.view.updates_popover = false;
            return;
        }
    }

    const pop_w: f32 = 340;
    const anchor = a.view.updates_anchor orelse ui.Rect{ .x = c.size.w - 110, .y = 6, .w = 80, .h = 28 };
    const px = rules.snapToWindow(anchor.x + anchor.w - pop_w, pop_w, c.size.w, 8);
    const py = anchor.y + anchor.h + 8;

    ui.key(c, "updates-popover");
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(
        ui.div(c).fixed().offset(px, py).w(pop_w).layer(6).column().p(12).gap(8)
            .bg(k.composer).border(k.border).borderW(1).rounded(12),
    ));
    defer card.end();

    var updatable_count: usize = 0;
    for (rows) |row| if (row.isBatchUpdatable()) {
        updatable_count += 1;
    };

    if (updatable_count >= 2) {
        const top = ui.div(c).row().wFull().justifyEnd().itemsCenter();
        defer top.end();
        ui.key(c, "updates-update-all");
        const all_btn = ui.div(c).row().h(28).px(12).center().roundedFull()
            .bg(k.text).hover(k.text.alpha(0.86)).control();
        const all_clicked = all_btn.clicked();
        {
            defer all_btn.end();
            ui.text(c, "Update all", .{
                .size = 12,
                .line_height = 16,
                .weight = .medium,
                .color = k.shell,
            });
        }
        if (all_clicked) {
            for (rows) |row| {
                if (row.isBatchUpdatable()) triggerUnifiedAction(a, row);
            }
        }
    }

    var any_failed = false;
    for (rows) |row| {
        if (row.failed) any_failed = true;
    }
    if (rows.len > 3) {
        ui.key(c, "updates-popover-list");
        const list = ui.div(c).column().wFull().maxH(if (any_failed) 260 else 164).gap(8).scrollY()
            .scrollbar(.{ .overlay = k.faint.alpha(0.5) });
        c.node(list.index).style.scroll_edge_fade = 18;
        defer list.end();
        for (rows) |row| drawUnifiedRow(c, a, k, row);
    } else {
        for (rows) |row| drawUnifiedRow(c, a, k, row);
    }
}

fn drawUnifiedRow(c: *ui.Context, a: *App, k: theme.Colors, row: UnifiedRow) void {
    ui.key(c, c.print("updates-row-{s}", .{row.id}));
    const outer = ui.div(c).column().wFull().py(4).gap(6);
    defer outer.end();

    {
        const line = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer line.end();

        {
            const plate = ui.div(c).row().size(32, 32).center().rounded(8)
                .bg(ui.Color.white).border(ui.Color.black.alpha(0.08)).borderW(1);
            defer plate.end();
            const mark = icons.harnessMark(row.mark_id);
            icons.icon(c, mark.name, 18, mark.brand orelse ui.Color.hex(0x18181b), 0);
        }

        {
            const info = ui.div(c).column().grow().w(0).gap(2);
            defer info.end();
            kit.ellipsisText(c, row.title, .{
                .size = 13,
                .line_height = 17,
                .weight = .medium,
                .color = k.text,
            }, 136);
            kit.ellipsisText(c, row.detail, .{
                .size = 11.5,
                .line_height = 15,
                .color = if (row.failed) k.danger else k.muted,
            }, 152);
        }

        const ctrl = ui.div(c).row().gap(8).itemsCenter();
        defer ctrl.end();
        if (row.skippable) {
            ui.key(c, c.print("updates-skip-{s}", .{row.id}));
            const skip_btn = ui.div(c).row().h(26).px(6).center().roundedFull().hover(k.hover).control();
            const skip_hot = skip_btn.hovered();
            const skip_clicked = skip_btn.clicked();
            {
                defer skip_btn.end();
                ui.text(c, "Skip", .{
                    .size = 11.5,
                    .line_height = 15,
                    .color = if (skip_hot) k.text else k.muted,
                });
            }
            if (skip_clicked) skipUnifiedRow(a, row);
        }

        if (row.action_label) |lbl| {
            ui.key(c, c.print("updates-act-{s}", .{row.id}));
            var act_btn = ui.div(c).row().h(26).px(12).center().roundedFull()
                .bg(k.ink(if (k.dark) 0.08 else 0.06)).border(k.border.alpha(0.7)).borderW(1);
            act_btn = if (row.enabled) act_btn.hover(k.hover).control() else act_btn.opacity(0.45);
            const act_clicked = row.enabled and act_btn.clicked();
            {
                defer act_btn.end();
                ui.text(c, lbl, .{
                    .size = 11.5,
                    .line_height = 15,
                    .weight = .medium,
                    .color = k.text,
                });
            }
            if (act_clicked) triggerUnifiedAction(a, row);
        }
    }

    if (row.failed and (row.xcode_license or row.failure_note != null)) {
        const card = ui.div(c).column().wFull().p(8).gap(4).rounded(8)
            .bg(k.danger.alpha(if (k.dark) 0.14 else 0.07))
            .border(k.danger.alpha(if (k.dark) 0.30 else 0.20)).borderW(1);
        defer card.end();
        if (row.xcode_license) {
            if (row.failure_headline) |headline| {
                const hcol = ui.div(c).column().w(298);
                defer hcol.end();
                ui.text(c, headline, .{
                    .size = 11.5,
                    .line_height = 15,
                    .weight = .medium,
                    .color = k.danger,
                    .wrap = true,
                });
            }
            if (row.failure_note) |note| {
                const ncol = ui.div(c).column().w(298);
                defer ncol.end();
                ui.text(c, note, .{
                    .size = 11,
                    .line_height = 15,
                    .color = k.muted,
                    .wrap = true,
                });
            }
            const acts = ui.div(c).row().wFull().gap(6).pt(2).itemsCenter();
            defer acts.end();
            {
                ui.key(c, c.print("updates-copy-cmd-{s}", .{row.id}));
                const copy_btn = ui.div(c).row().h(24).px(10).center().roundedFull()
                    .bg(k.ink(if (k.dark) 0.09 else 0.06)).border(k.border.alpha(0.75)).borderW(1)
                    .hover(k.hover).control();
                const copy_clicked = copy_btn.clicked();
                {
                    defer copy_btn.end();
                    ui.text(c, "Copy command", .{
                        .size = 11,
                        .line_height = 14,
                        .weight = .medium,
                        .color = k.text,
                    });
                }
                if (copy_clicked) {
                    c.clipboard.write(c.clipboard.ctx, xcode_license_cmd);
                    a.setNotice("Copied sudo xcodebuild -license");
                }
            }
            if (row.is_local and (builtin.os.tag == .macos or builtin.is_test)) {
                ui.key(c, c.print("updates-open-term-{s}", .{row.id}));
                const term_btn = ui.div(c).row().h(24).px(10).center().roundedFull()
                    .bg(k.ink(if (k.dark) 0.09 else 0.06)).border(k.border.alpha(0.75)).borderW(1)
                    .hover(k.hover).control();
                const term_clicked = term_btn.clicked();
                {
                    defer term_btn.end();
                    ui.text(c, "Open Terminal", .{
                        .size = 11,
                        .line_height = 14,
                        .weight = .medium,
                        .color = k.text,
                    });
                }
                if (term_clicked) openTerminalApp(a);
            }
        } else if (row.failure_note) |msg| {
            const ecol = ui.div(c).column().w(298);
            defer ecol.end();
            ui.text(c, msg, .{
                .size = 11.5,
                .line_height = 15,
                .color = k.danger,
                .wrap = true,
            });
        }
    }
}

fn skipUnifiedRow(a: *App, row: UnifiedRow) void {
    a.settings.skipUpdate(row.id, row.token);
    switch (row.kind) {
        .app => {
            if (appUpdateVersion(a)) |ver| {
                const n = @min(ver.len, a.updates.restart_dismissed.len);
                @memcpy(a.updates.restart_dismissed[0..n], ver[0..n]);
                a.updates.restart_dismissed_len = n;
            }
        },
        .engine => dismissGraff(a),
        .agent => {},
    }
    a.redraw();
}

fn triggerUnifiedAction(a: *App, row: UnifiedRow) void {
    switch (row.action) {
        .none => {},
        .app_update => |ver| triggerAppUpdate(a, ver),
        .app_restart => |ver| triggerAppUpdate(a, ver),
        .graff_update_now => {
            a.updates.graff_updating_manual = true;
            graff_update.startManual(a);
            a.redraw();
        },
        .graff_notes => |ver| openExternalUrl(std.fmt.allocPrint(a.gpa, "https://github.com/justrach/codegraff/releases/tag/v{s}", .{ver}) catch "https://github.com/justrach/codegraff/releases"),
        .agent_rpc => |r| agent_updates.runAction(a, r.device_id, r.method, r.harness),
        .open_settings => {
            a.view.updates_popover = false;
            a.settings.setSection(.agents);
            @import("view_settings.zig").open(a);
        },
        .dismiss_done => skipUnifiedRow(a, row),
    }
}

fn appUpdatedCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const ver = a.updates.app_updated[0..a.updates.app_updated_len];
    const card_w: f32 = 340;
    const card_h: f32 = 126;
    ui.key(c, "app-updated");
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(@max(16, c.size.w - card_w - 16), @max(16, c.size.h - card_h - 16))
        .layer(5).column().w(card_w).p(14).gap(10).rounded(12).border(k.border).borderW(1).bg(k.composer.alpha(1))));
    defer card.end();
    {
        const hd = ui.div(c).row().gap(10).itemsCenter();
        defer hd.end();
        const badge = ui.div(c).row().size(30, 30).center().rounded(8).bg(k.accent_wash);
        defer badge.end();
        icons.icon(c, .check, 16, k.accent, 0);
        ui.text(c, c.print("Updated to v{s}", .{ver}), .{ .size = 13, .line_height = 18, .weight = .semibold, .color = k.text });
    }
    ui.text(c, "You're on the new version.", .{ .size = 11.5, .line_height = 16, .color = k.muted });
    {
        const btns = ui.div(c).row().wFull().justifyEnd().gap(6).itemsCenter();
        defer btns.end();
        ui.key(c, "app-updated-notes");
        const notes = ui.div(c).row().px(10).py(4).rounded(6).border(k.border).borderW(1).hover(k.hover);
        if (notes.clicked()) openExternalUrl(c.print("https://github.com/justrach/nanoharness/releases/tag/v{s}", .{ver}));
        ui.text(c, "Release notes", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.text });
        notes.end();

        ui.key(c, "app-updated-dismiss");
        const got_it = ui.div(c).row().px(10).py(4).rounded(6).border(k.solid).borderW(1).bg(k.solid);
        if (got_it.clicked()) {
            a.updates.app_updated_len = 0;
            a.redraw();
        }
        ui.text(c, "Got it", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.on_solid });
        got_it.end();
    }
}

fn graffNoticeCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.updates;
    const to = s.graffTo() orelse return;
    const from = s.graffFrom();
    const can_update = s.graff_kind == .available;
    const shown_count = @min(s.graff_highlights_total, max_highlights);
    const hidden = s.graff_highlights_total -| max_highlights;
    const card_w: f32 = 340;
    const text_col_w: f32 = card_w - 28 - 13;

    var est_h: f32 = 28 + 34 + 10 + 28 + 10 + 26;
    if (shown_count > 0) {
        est_h += 10 + 18;
        for (0..shown_count) |i| {
            const line = s.graff_highlights[i][0..s.graff_highlight_lens[i]];
            const w = c.text.width(line, .{ .size = 12 });
            const n_lines = @max(1.0, @ceil(w / @max(1.0, text_col_w - 8)));
            est_h += n_lines * 17 + 5;
        }
        if (hidden > 0) est_h += 18;
    }
    const note = if (can_update)
        "Installs in the background; open chats keep their current session."
    else if (from) |f|
        c.print("New chats use it. Open chats stay on v{s} until you start a new one.", .{f})
    else
        "New chats use it.";
    const note_lines = @max(1.0, @ceil(c.text.width(note, .{ .size = 11 }) / @max(1.0, card_w - 28 - 8)));
    est_h += (note_lines - 1.0) * 16;

    ui.key(c, "graff-notice");
    const card_id = c.peekId(null);
    const measured_h: ?f32 = if (c.rects.get(card_id)) |r| (if (r.h > 0 and r.h < 600) r.h else null) else null;
    if (measured_h == null) c.frameIn(0);
    const card_h = measured_h orelse est_h;
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(@max(16, c.size.w - card_w - 16), @max(16, c.size.h - card_h - 16))
        .layer(5).column().w(card_w).p(14).gap(10).rounded(12).border(k.border).borderW(1).bg(k.composer.alpha(1))));
    defer card.end();

    // Header: Codegraff mark tile, title, and version step.
    {
        const hd = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer hd.end();
        {
            const tile = ui.div(c).row().size(30, 30).center().rounded(8).bg(k.accent_wash);
            defer tile.end();
            icons.icon(c, .@"graff-mark", 16, k.accent, 0);
        }
        {
            const col = ui.div(c).column().grow().w(0).gap(3);
            defer col.end();
            const title = if (can_update) "Codegraff engine update available" else "Codegraff engine updated";
            ui.text(c, title, .{ .size = 13, .line_height = 17, .weight = .semibold, .color = k.text });
            const ver_row = ui.div(c).row().gap(5).itemsCenter();
            defer ver_row.end();
            if (from) |f| {
                ui.text(c, c.print("v{s}", .{f}), .{ .size = 11, .line_height = 15, .color = k.muted });
                icons.icon(c, .@"arrow-right", 11, k.faint, 0);
            } else if (can_update) {
                ui.text(c, "Not installed", .{ .size = 11, .line_height = 15, .color = k.muted });
                icons.icon(c, .@"arrow-right", 11, k.faint, 0);
            }
            const chip = ui.div(c).row().px(6).py(1).rounded(6).bg(k.accent_wash);
            defer chip.end();
            ui.text(c, c.print("v{s}", .{to}), .{ .size = 11, .line_height = 15, .weight = .semibold, .color = k.accent });
        }
    }

    // Body: WHAT'S NEW highlights from `graff --version`.
    if (shown_count > 0) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        ui.key(c, "graff-notice-highlights");
        const body = ui.div(c).column().wFull().gap(5);
        defer body.end();
        ui.text(c, "WHAT'S NEW", .{ .size = 10.5, .line_height = 14, .weight = .semibold, .color = k.faint });
        for (0..shown_count) |i| {
            const line = s.graff_highlights[i][0..s.graff_highlight_lens[i]];
            const item = ui.div(c).row().wFull().gap(8).itemsStart();
            defer item.end();
            {
                const dot_pad = ui.div(c).column().pt(6);
                defer dot_pad.end();
                kit.dot(c, 5, k.accent);
            }
            const tbox = ui.div(c).column().w(text_col_w);
            defer tbox.end();
            ui.text(c, line, .{ .size = 12, .line_height = 17, .wrap = true, .color = k.text });
        }
        if (hidden > 0) {
            const more = ui.div(c).row().pl(13);
            defer more.end();
            ui.text(c, c.print("+{d} more in the release notes", .{hidden}), .{ .size = 11, .line_height = 15, .color = k.muted });
        }
    }

    // Footnote: what happens to open chats.
    {
        const foot = ui.div(c).row().wFull().gap(6).itemsStart();
        defer foot.end();
        const ncol = ui.div(c).column().w(card_w - 28);
        defer ncol.end();
        ui.text(c, note, .{ .size = 11, .line_height = 16, .color = k.muted, .wrap = true });
    }

    // Action buttons.
    {
        const btns = ui.div(c).row().wFull().justifyEnd().gap(6).itemsCenter();
        defer btns.end();
        if (can_update) {
            ui.key(c, "graff-notice-update");
            const upd = ui.div(c).row().px(10).py(4).rounded(6).border(k.border).borderW(1).hover(k.hover);
            if (!s.graff_updating_manual and upd.clicked()) {
                s.graff_updating_manual = true;
                graff_update.startManual(a);
                a.redraw();
            }
            ui.text(c, if (s.graff_updating_manual) "Updating…" else "Update", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.accent });
            upd.end();
        }
        {
            ui.key(c, "graff-notice-whats-new");
            const notes = ui.div(c).row().px(10).py(4).rounded(6).border(k.border).borderW(1).hover(k.hover);
            if (notes.clicked()) openExternalUrl(c.print("https://github.com/justrach/codegraff/releases/tag/v{s}", .{to}));
            ui.text(c, "Release notes", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.text });
            notes.end();
        }
        {
            ui.key(c, "graff-notice-dismiss");
            const got_it = ui.div(c).row().px(10).py(4).rounded(6).border(k.solid).borderW(1).bg(k.solid);
            if (got_it.clicked()) dismissGraff(a);
            ui.text(c, "Got it", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.on_solid });
            got_it.end();
        }
    }
}

test "native updater resolves only the running bundle never a global CLI" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { exe: []const u8, cli: []const u8 }{
        .{ .exe = "/Applications/Harness.app/Contents/MacOS/harness-nano", .cli = "/Applications/Harness.app/Contents/MacOS/harness" },
        .{ .exe = "/Users/example/Applications/Harness.app/Contents/MacOS/harness-nano", .cli = "/Users/example/Applications/Harness.app/Contents/MacOS/harness" },
        .{ .exe = "/Volumes/Test's Disk/Harness.app/Contents/MacOS/harness-nano", .cli = "/Volumes/Test's Disk/Harness.app/Contents/MacOS/harness" },
    };
    for (cases) |case| {
        const cli = updateCliFor(gpa, case.exe, .macos) orelse return error.ExpectedSibling;
        defer gpa.free(cli);
        try std.testing.expectEqualStrings(case.cli, cli);
    }
    for ([_][]const u8{ "/work/zig-out/bin/harness-nano", "/usr/local/bin/harness-nano", "/tmp/not-a-bundle/Contents/MacOS/harness-nano" }) |exe| {
        try std.testing.expect(updateCliFor(gpa, exe, .macos) == null);
    }
    try std.testing.expect(updateCliFor(gpa, "/tmp/Harness.app/Contents/MacOS/harness-nano", .linux) == null);
    try std.testing.expect(updateCliFor(gpa, "C:\\Harness\\harness-nano.exe", .windows) == null);
    try std.testing.expect(currentBundle("/tmp/Harness.app/Contents/MacOS/harness-nano", .windows) == null);
}

test "native updater release completion with installation disabled never installs or uses restart preference" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    a.settings.set(.automatically_install_updates, false);
    a.settings.set(.restart_to_install_updates, true);
    a.updates.app_install_checked = true;
    a.updates.app_can_install = true;
    const ver = "99.0.0";
    @memcpy(a.release.latest[0..ver.len], ver);
    a.release.latest_len = ver.len;
    a.release.succeeded = true;
    onReleaseChecked(&a);
    try std.testing.expect(!a.updates.app_downloading);
    try std.testing.expect(appRestartVersion(&a) == null);
    try std.testing.expect(a.settings.get(.restart_to_install_updates));
    try std.testing.expect(a.updates.app_checked_ms > 0);
    var buf: [200]u8 = undefined;
    try std.testing.expect(updateSummary(&buf, &a, a.nowMs()).action == .update);
    a.updates.app_can_install = false;
    try std.testing.expect(updateSummary(&buf, &a, a.nowMs()).action == .check);
    a.release.schedule.failures = 1;
    try std.testing.expect(std.mem.startsWith(u8, updateSummary(&buf, &a, a.nowMs()).line, "Couldn't check"));
}

test "native updater default automatic installation requires fresh success and install capability" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    a.updates.app_install_checked = true;
    a.updates.app_can_install = true;
    const ver = "99.0.0";
    @memcpy(a.release.latest[0..ver.len], ver);
    a.release.latest_len = ver.len;
    try std.testing.expect(a.settings.get(.automatically_install_updates));
    a.settings.set(.restart_to_install_updates, false);
    onReleaseChecked(&a); // Offline, even with a cached newer manifest.
    try std.testing.expect(!a.updates.app_downloading);
    a.release.succeeded = true;
    a.release.schedule.failures = 1;
    automaticallyInstall(&a);
    try std.testing.expect(!a.updates.app_downloading);
    a.release.schedule.failures = 0;
    a.updates.app_can_install = false;
    onReleaseChecked(&a);
    try std.testing.expect(!a.updates.app_downloading);
    a.updates.app_can_install = true;
    onReleaseChecked(&a);
    try std.testing.expect(a.updates.app_downloading);
    try std.testing.expect(appRestartVersion(&a) == null); // Installation is not a restart.
    a.updates.app_downloading = false;
    a.updates.setAppInstalled(ver);
    onReleaseChecked(&a);
    try std.testing.expect(!a.updates.app_downloading); // Never reinstall a staged update.
    const newer = "99.0.1";
    @memcpy(a.release.latest[0..newer.len], newer);
    a.release.latest_len = newer.len;
    try std.testing.expect(appRestartVersion(&a) == null);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(newer, updateSummary(&buf, &a, a.nowMs()).action.update);
    triggerAppUpdate(&a, ver); // A click from the old frame must not restart into it.
    try std.testing.expect(a.updates.app_downloading);
    a.updates.app_downloading = false;
    onReleaseChecked(&a);
    try std.testing.expect(a.updates.app_downloading); // Automatic path also supersedes the previous install.
    a.updates.app_downloading = false;
    a.updates.setAppInstalled(newer);
    try std.testing.expectEqualStrings(newer, appRestartVersion(&a).?);
    try std.testing.expectEqualStrings(newer, updateSummary(&buf, &a, a.nowMs()).action.restart);
    a.updates.setAppInstalled("");
    a.settings.set(.automatically_install_updates, false);
    onReleaseChecked(&a);
    try std.testing.expect(!a.updates.app_downloading);
}

test "native updater rejects dev and standalone bundle identities" {
    try std.testing.expect(productionBundleId("harness.codegraff.app\n"));
    try std.testing.expect(!productionBundleId("harness.codegraff.app.dev"));
    try std.testing.expect(!productionBundleId("com.justrach.harness-nano"));
    try std.testing.expect(!productionBundleId(""));
}

test "olderEngineNotice reports only older engines" {
    var buf: [320]u8 = undefined;
    const n1 = olderEngineNotice(&buf, "0.2.170", "0.2.169") orelse return error.ExpectedNotice;
    try std.testing.expect(std.mem.indexOf(u8, n1, "0.2.169") != null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "0.2.99") != null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", null) != null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "0.2.170") == null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "0.2.171") == null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "0.3.0") == null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "custom") == null);
    try std.testing.expectEqual(
        EngineVersionAction.replace_old_session,
        decideEngineVersionAction("0.2.179", "0.2.178", true, false),
    );
    try std.testing.expectEqual(
        EngineVersionAction.notify_only,
        decideEngineVersionAction("0.2.179", "0.2.178", true, true),
    );
    try std.testing.expectEqual(
        EngineVersionAction.notify_only,
        decideEngineVersionAction("0.2.179", "0.2.178", false, false),
    );
    try std.testing.expectEqual(
        EngineVersionAction.up_to_date,
        decideEngineVersionAction("0.2.179", "0.2.179", true, false),
    );
}

test "whatsNew extracts bullets in range from graff --version" {
    const sample =
        \\graff 0.302.74.5
        \\
        \\What's new
        \\──────────
        \\0.302.74.5
        \\  • first highlight
        \\  • second highlight
        \\
        \\0.302.74.4
        \\  • older highlight
        \\
        \\0.302.74.3
        \\  • skipped highlight
    ;
    var lines: [max_highlights][160]u8 = undefined;
    var lens: [max_highlights]usize = @splat(0);
    const total = whatsNew(&lines, &lens, sample, "0.302.74.3", "0.302.74.5");
    try std.testing.expectEqual(@as(usize, 3), total);
    try std.testing.expectEqualStrings("first highlight", lines[0][0..lens[0]]);
    try std.testing.expectEqualStrings("second highlight", lines[1][0..lens[1]]);
    try std.testing.expectEqualStrings("older highlight", lines[2][0..lens[2]]);
}

test "restartPlace chooses sidebar row when open and titlebar when collapsed" {
    try std.testing.expectEqual(RestartPlace.none, restartPlace(null, true, null));
    try std.testing.expectEqual(RestartPlace.sidebar_row, restartPlace("0.2.175", true, null));
    try std.testing.expectEqual(RestartPlace.titlebar, restartPlace("0.2.175", false, null));
    try std.testing.expectEqual(RestartPlace.none, restartPlace("0.2.175", true, "0.2.175"));
}

test "native updater recovers a verified ahead-of-process bundle after a CLI no-op" {
    const same = "Harness 99.0.1 is up to date (latest: 99.0.1).\n";
    const withdrawn = "Harness 99.0.1 is up to date (latest: 99.0.0).\n";
    try std.testing.expectEqualStrings("99.0.1", confirmedAppVersion(.up_to_date, "99.0.1", same).?);
    try std.testing.expect(confirmedAppVersion(.up_to_date, "99.0.1", withdrawn) == null);
    try std.testing.expect(confirmedAppVersion(.up_to_date, null, same) == null);
    try std.testing.expect(confirmedAppVersion(.{ .failed = "download failed" }, "99.0.1", same) == null);
}

test "classifyUpdateOutput distinguishes an installed bundle from a no-op (ADR 0008)" {
    try std.testing.expectEqual(
        UpdateCommandOutcome.up_to_date,
        classifyUpdateOutput(true, "Harness 0.2.178 is up to date (latest: 0.2.178).\n", ""),
    );
    try std.testing.expectEqual(
        UpdateCommandOutcome.installed,
        classifyUpdateOutput(true, "downloading harness-0.2.178-macos-arm64-app.tar.gz…\nupdated /Applications/Harness.app — relaunch Harness to finish.\n", ""),
    );
    switch (classifyUpdateOutput(false, "", "network timeout\n")) {
        .failed => |msg| try std.testing.expectEqualStrings("network timeout", msg),
        else => return error.ExpectedFailure,
    }
    // Verify build_info.version tracks Cargo.toml and is never a stale 0.2.175 cache.
    try std.testing.expect(!std.mem.eql(u8, @import("build_info").version, "0.2.175"));
    try std.testing.expect(!std.mem.eql(u8, @import("build_info").version, "0.0.0"));
}

test "multi-surface updater never offers Restart before installed target matches feed (#85)" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    a.updates.app_install_checked = true;
    a.updates.app_can_install = true;

    const ver_b = "99.0.1";
    const ver_c = "99.0.2";
    @memcpy(a.release.latest[0..ver_b.len], ver_b);
    a.release.latest_len = ver_b.len;
    a.release.succeeded = true;

    // 1. Update available but not downloaded: every surface must offer Update, not Restart.
    var sum_buf: [256]u8 = undefined;
    try std.testing.expect(appRestartVersion(&a) == null);
    try std.testing.expectEqualStrings(ver_b, updateSummary(&sum_buf, &a, a.nowMs()).action.update);
    {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const rows = collectUnifiedRows(&a, arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqualStrings("Update", rows[0].action_label.?);
        try std.testing.expect(!rows[0].updated);
    }

    // 2. Downloading shows progress and never Restart.
    a.updates.app_downloading = true;
    try std.testing.expect(appRestartVersion(&a) == null);
    try std.testing.expect(updateSummary(&sum_buf, &a, a.nowMs()).action == .downloading);

    // 3. vB finished installing, then vC became latest: stale vB must NOT show Restart as vC.
    a.updates.app_downloading = false;
    a.updates.setAppInstalled(ver_b);
    try std.testing.expectEqualStrings(ver_b, appRestartVersion(&a).?);
    @memcpy(a.release.latest[0..ver_c.len], ver_c);
    a.release.latest_len = ver_c.len;
    try std.testing.expect(appRestartVersion(&a) == null);
    try std.testing.expectEqualStrings(ver_c, updateSummary(&sum_buf, &a, a.nowMs()).action.update);

    // 4. Download of vC fails: Retry is offered on unified rows & Settings, not Restart.
    a.updates.setAppFailed("checksum mismatch");
    try std.testing.expect(appRestartVersion(&a) == null);
    try std.testing.expectEqualStrings(ver_c, updateSummary(&sum_buf, &a, a.nowMs()).action.retry);
    {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const rows = collectUnifiedRows(&a, arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqualStrings("Retry", rows[0].action_label.?);
        try std.testing.expect(rows[0].failed);
    }

    // 5. vC succeeds: Restart is offered once with exact verified target vC.
    a.updates.setAppFailed("");
    a.updates.setAppInstalled(ver_c);
    try std.testing.expectEqualStrings(ver_c, appRestartVersion(&a).?);
    try std.testing.expectEqualStrings(ver_c, updateSummary(&sum_buf, &a, a.nowMs()).action.restart);
}

fn deliverTestAppInstall(a: *App, installed: []const u8, failure: []const u8) void {
    var result: AppInstallResult = .{};
    result.installed_len = @min(installed.len, result.installed.len);
    @memcpy(result.installed[0..result.installed_len], installed[0..result.installed_len]);
    result.failure_len = @min(failure.len, result.failure.len);
    @memcpy(result.failure[0..result.failure_len], failure[0..result.failure_len]);
    a.updates.acquire();
    a.updates.app_install_result = result;
    a.updates.release();
    appUpdateDelivered(@ptrCast(a));
}

test "restart refreshes the feed and relaunches only its verified current result" {
    const b = "99.0.1";
    const c = "99.0.2";
    const d = "99.0.3";
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    a.updates.app_install_checked = true;
    a.updates.app_can_install = true;
    a.release.succeeded = true;
    a.updates.setAppInstalled(b);
    @memcpy(a.release.latest[0..b.len], b);
    a.release.latest_len = b.len;

    triggerAppUpdate(&a, b);
    try std.testing.expect(a.updates.app_downloading);
    try std.testing.expect(a.updates.restart_after_verify);
    try std.testing.expectEqual(@as(u32, 0), a.updates.test_relaunch_count);

    // The feed changes after the Restart button was rendered. The worker's
    // fresh updater result is vC, so the single relaunch must use vC.
    @memcpy(a.release.latest[0..c.len], c);
    a.release.latest_len = c.len;
    deliverTestAppInstall(&a, c, "");
    try std.testing.expect(!a.updates.app_downloading);
    try std.testing.expect(!a.updates.restart_after_verify);
    try std.testing.expectEqual(@as(u32, 1), a.updates.test_relaunch_count);
    try std.testing.expectEqualStrings(c, a.updates.test_relaunch_version[0..a.updates.test_relaunch_version_len]);

    // A confirmed vB no-op remains restartable when the refreshed feed is
    // still vB; a failed refresh must leave the running app alone.
    var same: App = .init(std.testing.allocator, std.testing.io, 1);
    defer same.deinit();
    same.updates.app_install_checked = true;
    same.updates.app_can_install = true;
    same.release.succeeded = true;
    same.updates.setAppInstalled(b);
    @memcpy(same.release.latest[0..b.len], b);
    same.release.latest_len = b.len;
    triggerAppUpdate(&same, b);
    deliverTestAppInstall(&same, b, "");
    try std.testing.expectEqual(@as(u32, 1), same.updates.test_relaunch_count);
    try std.testing.expectEqualStrings(b, same.updates.test_relaunch_version[0..same.updates.test_relaunch_version_len]);

    var failed: App = .init(std.testing.allocator, std.testing.io, 1);
    defer failed.deinit();
    failed.updates.app_install_checked = true;
    failed.updates.app_can_install = true;
    failed.release.succeeded = true;
    failed.updates.setAppInstalled(b);
    @memcpy(failed.release.latest[0..b.len], b);
    failed.release.latest_len = b.len;
    triggerAppUpdate(&failed, b);
    deliverTestAppInstall(&failed, "", "synthetic download failure");
    try std.testing.expectEqual(@as(u32, 0), failed.updates.test_relaunch_count);
    try std.testing.expect(!failed.updates.restart_after_verify);
    try std.testing.expectEqualStrings("synthetic download failure", failed.updates.appFailed().?);

    // A normal update/Retry can never inherit permission to restart.
    var normal: App = .init(std.testing.allocator, std.testing.io, 1);
    defer normal.deinit();
    normal.updates.app_install_checked = true;
    normal.updates.app_can_install = true;
    normal.release.succeeded = true;
    @memcpy(normal.release.latest[0..c.len], c);
    normal.release.latest_len = c.len;
    triggerAppUpdate(&normal, c);
    try std.testing.expect(!normal.updates.restart_after_verify);
    deliverTestAppInstall(&normal, c, "");
    try std.testing.expectEqual(@as(u32, 0), normal.updates.test_relaunch_count);

    // If the UI already knows about a newer release than the worker verified,
    // keep the app open rather than relaunching into a superseded version.
    var superseded: App = .init(std.testing.allocator, std.testing.io, 1);
    defer superseded.deinit();
    superseded.updates.app_install_checked = true;
    superseded.updates.app_can_install = true;
    superseded.release.succeeded = true;
    superseded.updates.setAppInstalled(b);
    @memcpy(superseded.release.latest[0..b.len], b);
    superseded.release.latest_len = b.len;
    triggerAppUpdate(&superseded, b);
    @memcpy(superseded.release.latest[0..d.len], d);
    superseded.release.latest_len = d.len;
    deliverTestAppInstall(&superseded, c, "");
    try std.testing.expectEqual(@as(u32, 0), superseded.updates.test_relaunch_count);
}

test "unified agent update row exposes Cancel during installing" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    try agent_updates.setTestStatuses(&a, "synthetic-device", true,
        \\[{"harness":"claude-code","installedVersion":"2.1.319","latestVersion":"2.1.322","phase":"installing","canApply":true}]
    );
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = collectUnifiedRows(&a, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(.agent, rows[0].kind);
    try std.testing.expect(rows[0].busy);
    try std.testing.expectEqualStrings("Cancel", rows[0].action_label.?);
    try std.testing.expectEqualStrings("CancelHarnessUpdate", rows[0].action.agent_rpc.method);
    try std.testing.expectEqualStrings("claude-code", rows[0].action.agent_rpc.harness);
}
