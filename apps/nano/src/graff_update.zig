//! Keep `~/.harness/bin/graff` on Codegraff's latest stable release on a
//! 10-minute wall-clock schedule, and surface lifecycle notices
//! (`GraffNotice::Updating` / `GraffNotice::Updated` / `GraffNotice::Available`)
//! to the UI update bubble and What's New overlay card.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const view_updates = @import("view_updates.zig");

const latest_redirect_url = "https://github.com/justrach/codegraff/releases/latest";
const latest_api_url = "https://api.github.com/repos/justrach/codegraff/releases/latest";
const user_agent = "harness-graff-updater";

/// Periodic background check interval (10 minutes), matching GPUI's cadence.
pub const check_interval_ms: i64 = 10 * 60 * 1000;
/// Fast backoff after a first transient failure before escalating to 2 minutes.
pub const fast_retry_delay_ms: i64 = 30 * 1000;
/// Short backoff after a repeated transient failure before returning to
/// the 10-minute schedule.
pub const retry_delay_ms: i64 = 2 * 60 * 1000;

/// Pure backoff policy for Codegraff update failures: keep auto-updates retrying
/// silently on transient errors, and only fall back to the manual `Available`
/// prompt on repeated failures or explicit user/disabled-auto-update checks.
pub fn failureNoticeKind(auto_update: bool, manual: bool, prior_failures: u8) view_updates.GraffKind {
    if (!auto_update or manual or prior_failures >= 2) return .available;
    return .none;
}

/// UI-thread wall-clock schedule, surviving macOS sleep and clock adjustments.
pub const Schedule = struct {
    due_ms: ?i64 = null,
    in_flight: bool = false,
    failures: u8 = 0,

    pub fn due(s: *const Schedule, now_ms: i64) bool {
        const deadline = s.due_ms orelse return true;
        return now_ms >= deadline or deadline -| now_ms > check_interval_ms;
    }

    pub fn begin(s: *Schedule, now_ms: i64, manual: bool) bool {
        if (s.in_flight or (!manual and !s.due(now_ms))) return false;
        s.in_flight = true;
        return true;
    }

    pub fn complete(s: *Schedule, now_ms: i64, ok: bool) void {
        s.in_flight = false;
        s.failures = if (ok) 0 else @min(s.failures +| 1, 3);
        const delay: i64 = if (ok)
            check_interval_ms
        else if (s.failures == 1)
            fast_retry_delay_ms
        else if (s.failures == 2)
            retry_delay_ms
        else
            check_interval_ms;
        s.due_ms = now_ms +| delay;
    }

    /// Wake at least once a minute to notice sleep and wall-clock changes.
    pub fn delaySeconds(s: *const Schedule, now_ms: i64) f32 {
        if (s.in_flight) return 60;
        if (s.due(now_ms)) return 1;
        return @floatFromInt(@min(60, @max(1, @divFloor(s.due_ms.? -| now_ms, 1000))));
    }
};

pub fn start(a: *App) void {
    if (a.offscreen or builtin.os.tag != .macos) return;
    if (a.env) |env| {
        if (env.get("HARNESS_DEV_GRAFF_NOTICE")) |range| {
            if (std.mem.indexOf(u8, range, "..")) |sep| {
                const from = range[0..sep];
                const to = range[sep + 2 ..];
                if (to.len > 0) {
                    const home = env.get("HOME") orelse "";
                    var out_bytes: ?[]u8 = null;
                    defer if (out_bytes) |b| a.gpa.free(b);
                    if (home.len > 0) {
                        if (std.fmt.allocPrint(a.gpa, "{s}/.harness/bin/graff", .{home})) |managed| {
                            defer a.gpa.free(managed);
                            out_bytes = versionOutput(a.gpa, a.io, managed);
                        } else |_| {}
                    }
                    a.updates.publishGraff(.updated, if (from.len > 0) from else null, std.mem.trimStart(u8, to, "v"), out_bytes);
                    a.redraw();
                }
            }
        }
    }
    _ = check(a, true, false);
}

/// Called from `view_updates.tick(a)` to run the 10-minute wall-clock check.
pub fn startIfDue(a: *App) bool {
    return check(a, false, false);
}

/// Trigger an immediate check (e.g. from Check for updates).
pub fn checkNow(a: *App) void {
    _ = check(a, true, false);
}

/// User clicked "Update" on a Codegraff notice.
pub fn startManual(a: *App) void {
    _ = check(a, true, true);
}

fn check(a: *App, manual: bool, force_install: bool) bool {
    if (a.offscreen or builtin.os.tag != .macos) return false;
    if (a.env) |env| {
        if (env.get("GRAFF_EXECUTABLE")) |v| if (v.len > 0) return false;
    }
    const home = if (a.env) |env| env.get("HOME") orelse return false else return false;
    const prior_failures = a.updates.graff_schedule.failures;
    if (!a.updates.graff_schedule.begin(a.nowMs(), manual)) return false;

    const auto_update = force_install or (if (a.env) |env| !off(env.get("HARNESS_GRAFF_AUTO_UPDATE")) else true);
    const job = a.gpa.create(Job) catch {
        a.updates.graff_schedule.complete(a.nowMs(), false);
        return false;
    };
    const dismissed = a.settings.text("graffNoticeDismissed");
    job.* = .{
        .app = a,
        .home = a.gpa.dupe(u8, home) catch {
            a.gpa.destroy(job);
            a.updates.graff_schedule.complete(a.nowMs(), false);
            return false;
        },
        .dismissed = if (dismissed) |d| (a.gpa.dupe(u8, d) catch null) else null,
        .auto_update = auto_update,
        .manual = force_install,
        .prior_failures = prior_failures,
    };
    const t = std.Thread.spawn(.{}, workerMain, .{job}) catch {
        job.deinit(a.gpa);
        a.updates.graff_schedule.complete(a.nowMs(), false);
        return false;
    };
    t.detach();
    return true;
}

const Job = struct {
    app: *App,
    home: []u8,
    dismissed: ?[]u8,
    auto_update: bool,
    manual: bool,
    prior_failures: u8,

    fn deinit(self: *Job, gpa: std.mem.Allocator) void {
        gpa.free(self.home);
        if (self.dismissed) |d| gpa.free(d);
        gpa.destroy(self);
    }
};

const UiUpdate = struct {
    app: *App,
    done: bool,
    ok: bool,
    publish: bool,
    kind: view_updates.GraffKind = .none,
    from: ?[]u8 = null,
    to: ?[]u8 = null,
    version_out: ?[]u8 = null,

    fn deinit(self: *UiUpdate) void {
        const gpa = self.app.gpa;
        if (self.from) |f| gpa.free(f);
        if (self.to) |t| gpa.free(t);
        if (self.version_out) |v| gpa.free(v);
        gpa.destroy(self);
    }
};

fn applyOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const msg: *UiUpdate = @ptrCast(@alignCast(ctx.?));
    defer msg.deinit();
    const a = msg.app;
    if (msg.publish) {
        if (msg.kind == .none) {
            a.updates.clearGraff();
        } else if (msg.to) |to| {
            a.updates.publishGraff(msg.kind, msg.from, to, msg.version_out);
        }
    }
    if (msg.done) {
        a.updates.graff_schedule.complete(a.nowMs(), msg.ok);
        a.updates.graff_updating_manual = false;
    }
    a.redraw();
}

fn postUi(
    a: *App,
    done: bool,
    ok: bool,
    publish: bool,
    kind: view_updates.GraffKind,
    from: ?[]const u8,
    to: ?[]const u8,
    version_out: ?[]const u8,
) void {
    const msg = a.gpa.create(UiUpdate) catch return;
    msg.* = .{
        .app = a,
        .done = done,
        .ok = ok,
        .publish = publish,
        .kind = kind,
        .from = if (from) |f| (a.gpa.dupe(u8, f) catch null) else null,
        .to = if (to) |t| (a.gpa.dupe(u8, t) catch null) else null,
        .version_out = if (version_out) |v| (a.gpa.dupe(u8, v) catch null) else null,
    };
    if (!nanoui.App.onMain(msg, applyOnMain)) {
        msg.deinit();
    }
}

fn off(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "no");
}

fn workerMain(job: *Job) void {
    const a = job.app;
    defer job.deinit(a.gpa);

    const managed = std.fmt.allocPrint(a.gpa, "{s}/.harness/bin/graff", .{job.home}) catch {
        postUi(a, true, false, false, .none, null, null, null);
        return;
    };
    defer a.gpa.free(managed);

    const out_bytes = versionOutput(a.gpa, a.io, managed);
    defer if (out_bytes) |b| a.gpa.free(b);
    const current = if (out_bytes) |b| dotted(a.gpa, b) else null;
    defer if (current) |c| a.gpa.free(c);

    const tag = latestTag(a.gpa, a.io);
    defer if (tag) |t| a.gpa.free(t);

    if (tag) |t| {
        const bare_tag = std.mem.trimStart(u8, t, "v");
        const is_newer = if (current) |cur| newer(t, cur) else true;
        if (is_newer) {
            if (!job.auto_update) {
                postUi(a, true, true, true, .available, current, bare_tag, null);
                return;
            }
            postUi(a, false, true, true, .updating, current, bare_tag, null);
            if (downloadAndSwap(a.gpa, a.io, job.home, managed, t)) {
                const new_out = versionOutput(a.gpa, a.io, managed);
                defer if (new_out) |b| a.gpa.free(b);
                std.log.info("harness-nano: graff {s} -> {s}", .{ current orelse "none", t });
                postUi(a, true, true, true, .updated, current, bare_tag, new_out);
                return;
            }
            // Retry transient auto-update failures quietly before surfacing a
            // manual Update card so brief glitches do not drop auto-update UX.
            const next_kind = failureNoticeKind(job.auto_update, job.manual, job.prior_failures);
            postUi(
                a,
                true,
                false,
                true,
                next_kind,
                if (next_kind == .available) current else null,
                if (next_kind == .available) bare_tag else null,
                null,
            );
            return;
        }
    }

    // If the managed copy on disk is already newer than the last version the
    // user dismissed in Nano (for example after a background swap by the
    // engine or CLI), surface its "What's new" highlights until dismissed.
    if (current) |cur| {
        const should_show = if (job.dismissed) |d| newer(cur, d) else false;
        if (should_show) {
            postUi(a, true, tag != null, true, .updated, job.dismissed, cur, out_bytes);
            return;
        }
    }
    postUi(a, true, tag != null, false, .none, null, null, null);
}

pub fn macosAssetName(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .aarch64 => "graff-aarch64-macos.tar.gz",
        .x86_64 => "graff-x86_64-macos.tar.gz",
        else => null,
    };
}

/// Extract the release tag from GitHub's `/releases/latest` redirect target
/// (`https://github.com/justrach/codegraff/releases/tag/v0.302.74.75`).
pub fn tagFromRedirectUrl(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const marker = "/releases/tag/";
    const idx = std.mem.lastIndexOf(u8, trimmed, marker) orelse return null;
    var rest = trimmed[idx + marker.len ..];
    if (std.mem.indexOfAny(u8, rest, "?#/")) |cut| rest = rest[0..cut];
    return if (rest.len > 0) rest else null;
}

/// Parse `tag_name` from a GitHub Releases API JSON response (tolerates
/// arbitrary JSON whitespace and escaping).
pub fn tagFromReleaseJson(gpa: std.mem.Allocator, body: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get("tag_name") orelse return null;
    if (val != .string or val.string.len == 0) return null;
    return gpa.dupe(u8, val.string) catch null;
}

/// Verify `actual_hex` against a `SHA256SUMS` file for `asset_name`.
pub fn verifySha256Sums(sums_text: []const u8, asset_name: []const u8, actual_hex: []const u8) bool {
    var lines = std.mem.splitScalar(u8, sums_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 66) continue;
        const hash = line[0..64];
        const rest = std.mem.trimStart(u8, line[64..], " \t*");
        if (std.mem.eql(u8, rest, asset_name)) {
            return std.ascii.eqlIgnoreCase(hash, actual_hex);
        }
    }
    return false;
}

fn sha256FileHex(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[64]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024)) catch return null;
    defer gpa.free(data);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn extractAndSwapArchive(
    gpa: std.mem.Allocator,
    io: std.Io,
    asset: []const u8,
    tar_path: []const u8,
    sums_bytes: ?[]const u8,
    stage_dir: []const u8,
    managed_path: []const u8,
) bool {
    const sums = sums_bytes orelse {
        std.log.warn("harness-nano: graff {s} SHA256SUMS missing; refusing unverified update", .{asset});
        return false;
    };
    const actual = sha256FileHex(gpa, io, tar_path) orelse {
        std.log.warn("harness-nano: graff update checksum read failed for {s}", .{tar_path});
        return false;
    };
    if (!verifySha256Sums(sums, asset, &actual)) {
        std.log.warn("harness-nano: graff {s} SHA256SUMS verification failed", .{asset});
        return false;
    }

    std.Io.Dir.cwd().deleteTree(io, stage_dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, stage_dir) catch |err| {
        std.log.warn("harness-nano: graff update stage mkdir failed ({s}): {t}", .{ stage_dir, err });
        return false;
    };
    defer std.Io.Dir.cwd().deleteTree(io, stage_dir) catch {};

    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/tar", "-xzf", tar_path, "-C", stage_dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.warn("harness-nano: graff update tar spawn failed: {t}", .{err});
        return false;
    };
    const term = child.wait(io) catch |err| {
        std.log.warn("harness-nano: graff update tar wait failed: {t}", .{err});
        return false;
    };
    if (term != .exited or term.exited != 0) {
        std.log.warn("harness-nano: graff update tar failed for {s}", .{asset});
        return false;
    }

    const extracted = findGraffForAsset(gpa, io, stage_dir, asset) orelse {
        std.log.warn("harness-nano: graff binary missing from {s}", .{asset});
        return false;
    };
    defer gpa.free(extracted);

    // Ensure executable permissions before probing and atomic swap.
    var chmod_child = std.process.spawn(io, .{
        .argv = &.{ "/bin/chmod", "755", extracted },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.warn("harness-nano: graff update chmod spawn failed: {t}", .{err});
        return false;
    };
    const chmod_term = chmod_child.wait(io) catch |err| {
        std.log.warn("harness-nano: graff update chmod wait failed: {t}", .{err});
        return false;
    };
    if (chmod_term != .exited or chmod_term.exited != 0) {
        std.log.warn("harness-nano: graff update chmod failed for {s}", .{extracted});
        return false;
    }

    const probed = versionOutput(gpa, io, extracted) orelse {
        std.log.warn("harness-nano: unpacked graff --version failed ({s})", .{extracted});
        return false;
    };
    defer gpa.free(probed);
    const ver = dotted(gpa, probed) orelse {
        std.log.warn("harness-nano: unpacked graff reported invalid version", .{});
        return false;
    };
    gpa.free(ver);

    // Atomic rename directly over managed path (no delete-before-rename window;
    // any running `graff acp` keeps its unlinked inode).
    std.Io.Dir.cwd().rename(extracted, std.Io.Dir.cwd(), managed_path, io) catch |err| {
        std.log.warn("harness-nano: graff atomic swap into {s} failed: {t}", .{ managed_path, err });
        return false;
    };
    return true;
}

fn downloadAndSwap(gpa: std.mem.Allocator, io: std.Io, home: []const u8, managed: []const u8, tag: []const u8) bool {
    const asset = macosAssetName(builtin.cpu.arch) orelse return false;
    const bin_dir = std.fmt.allocPrint(gpa, "{s}/.harness/bin", .{home}) catch return false;
    defer gpa.free(bin_dir);
    std.Io.Dir.cwd().createDirPath(io, bin_dir) catch return false;

    const url = std.fmt.allocPrint(gpa, "https://github.com/justrach/codegraff/releases/download/{s}/{s}", .{ tag, asset }) catch return false;
    defer gpa.free(url);
    const sums_url = std.fmt.allocPrint(gpa, "https://github.com/justrach/codegraff/releases/download/{s}/SHA256SUMS", .{tag}) catch return false;
    defer gpa.free(sums_url);

    const tar = std.fmt.allocPrint(gpa, "{s}/.graff-update.tar.gz", .{bin_dir}) catch return false;
    defer gpa.free(tar);
    defer std.Io.Dir.cwd().deleteFile(io, tar) catch {};

    const sums_path = std.fmt.allocPrint(gpa, "{s}/.graff-update.SHA256SUMS", .{bin_dir}) catch return false;
    defer gpa.free(sums_path);
    defer std.Io.Dir.cwd().deleteFile(io, sums_path) catch {};

    if (!curlDownload(io, url, tar)) {
        std.log.warn("harness-nano: graff {s} download failed", .{tag});
        return false;
    }
    if (!curlDownload(io, sums_url, sums_path)) {
        std.log.warn("harness-nano: graff {s} SHA256SUMS unavailable; refusing unverified update", .{tag});
        return false;
    }
    const sums_bytes = std.Io.Dir.cwd().readFileAlloc(io, sums_path, gpa, .limited(256 * 1024)) catch return false;
    defer gpa.free(sums_bytes);

    const stage = std.fmt.allocPrint(gpa, "{s}/.graff-update-stage", .{bin_dir}) catch return false;
    defer gpa.free(stage);
    return extractAndSwapArchive(gpa, io, asset, tar, sums_bytes, stage, managed);
}

fn findGraffForAsset(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, asset: []const u8) ?[]u8 {
    const stem = if (std.mem.endsWith(u8, asset, ".tar.gz"))
        asset[0 .. asset.len - ".tar.gz".len]
    else
        asset;
    if (std.fmt.allocPrint(gpa, "{s}/{s}/graff", .{ dir, stem })) |nested| {
        if (std.Io.Dir.cwd().access(io, nested, .{})) |_| return nested else |_| gpa.free(nested);
    } else |_| {}
    if (std.fmt.allocPrint(gpa, "{s}/graff", .{dir})) |flat| {
        if (std.Io.Dir.cwd().access(io, flat, .{})) |_| return flat else |_| gpa.free(flat);
    } else |_| {}
    return findGraff(gpa, io, dir);
}

fn findGraff(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    const list = std.fmt.allocPrint(gpa, "{s}/.list", .{dir}) catch return null;
    defer gpa.free(list);
    const file = std.Io.Dir.cwd().createFile(io, list, .{}) catch return null;
    defer std.Io.Dir.cwd().deleteFile(io, list) catch {};
    var file_open = true;
    defer if (file_open) file.close(io);
    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/find", dir, "-type", "f", "-name", "graff" },
        .stdin = .ignore,
        .stdout = .{ .file = file },
        .stderr = .ignore,
    }) catch return null;
    file.close(io);
    file_open = false;
    const term = child.wait(io) catch return null;
    if (term != .exited or term.exited != 0) return null;
    const out_bytes = std.Io.Dir.cwd().readFileAlloc(io, list, gpa, .limited(4096)) catch return null;
    defer gpa.free(out_bytes);
    const line_end = std.mem.indexOfScalar(u8, out_bytes, '\n') orelse out_bytes.len;
    const path = std.mem.trim(u8, out_bytes[0..line_end], " \t\r");
    if (path.len == 0) return null;
    return gpa.dupe(u8, path) catch null;
}

fn curlDownload(io: std.Io, url: []const u8, dest_path: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{
            "/usr/bin/curl",
            "-fsSL",
            "--retry",
            "2",
            "--retry-delay",
            "2",
            "--retry-connrefused",
            "--max-time",
            "120",
            "-A",
            user_agent,
            "-o",
            dest_path,
            url,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

fn runCapture(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, max_bytes: usize) ?[]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_bytes),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        gpa.free(res.stdout);
        return null;
    }
    return res.stdout;
}

fn latestTag(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (builtin.os.tag != .macos) return null;
    // Prefer GitHub's web redirect (/releases/latest -> /releases/tag/<tag>)
    // so 10-minute polling never trips the 60 req/hr unauthenticated API limit.
    if (runCapture(gpa, io, &.{
        "/usr/bin/curl",
        "-fsSIL",
        "--max-time",
        "20",
        "-A",
        user_agent,
        "-o",
        "/dev/null",
        "-w",
        "%{url_effective}",
        latest_redirect_url,
    }, 4096)) |effective| {
        defer gpa.free(effective);
        if (tagFromRedirectUrl(effective)) |tag| {
            return gpa.dupe(u8, tag) catch null;
        }
    }
    // Fallback to the GitHub Releases API with a proper User-Agent + JSON parse.
    if (runCapture(gpa, io, &.{
        "/usr/bin/curl",
        "-fsSL",
        "--max-time",
        "20",
        "-A",
        user_agent,
        "-H",
        "Accept: application/vnd.github+json",
        latest_api_url,
    }, 512 * 1024)) |body| {
        defer gpa.free(body);
        return tagFromReleaseJson(gpa, body);
    }
    return null;
}

fn versionOutput(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return runCapture(gpa, io, &.{ path, "--version" }, 64 * 1024);
}

pub fn dotted(gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |word| {
        const bare = std.mem.trimStart(u8, word, "v");
        const cut = std.mem.indexOfScalar(u8, bare, '-') orelse bare.len;
        const ver = bare[0..cut];
        var parts: u8 = 0;
        var ok = ver.len > 0;
        for (ver) |ch| {
            if (ch == '.') parts += 1 else if (ch < '0' or ch > '9') ok = false;
        }
        if (ok and parts >= 2) return gpa.dupe(u8, ver) catch null;
    }
    return null;
}

pub fn newer(tag: []const u8, current: []const u8) bool {
    const left = std.mem.trimStart(u8, tag, "v");
    var a = std.mem.splitScalar(u8, left, '.');
    var b = std.mem.splitScalar(u8, std.mem.trimStart(u8, current, "v"), '.');
    while (true) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return false;
        const xn = if (x) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        const yn = if (y) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        if (xn != yn) return xn > yn;
    }
}

test "a release is newer only past the installed dotted version" {
    try std.testing.expect(newer("v0.0.302.25", "0.0.302.24"));
    try std.testing.expect(!newer("0.0.302.24", "0.0.302.24"));
    try std.testing.expect(!newer("0.0.302.4", "0.0.302.24"));
    const got = dotted(std.testing.allocator, "graff 0.0.302.24\n") orelse return error.NoVersion;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("0.0.302.24", got);
}

test "graff auto-update schedule polls every 10 minutes and steps backoff 30s -> 2m -> 10m" {
    const testing = std.testing;
    var s: Schedule = .{};
    const t0: i64 = 1_700_000_000_000;
    try testing.expect(s.due(t0));
    try testing.expect(s.begin(t0, false));
    try testing.expect(!s.begin(t0 + 1000, false)); // coalesced while in flight

    // Successful check schedules next check in exactly 10 minutes.
    s.complete(t0 + 500, true);
    try testing.expect(!s.due(t0 + 500 + check_interval_ms - 1));
    try testing.expect(s.due(t0 + 500 + check_interval_ms));

    // Failure 1 -> 30s quick retry; failure 2 -> 2m; failure 3 -> 10m; recovery resets to 0.
    const t1 = t0 + 1000 + check_interval_ms;
    try testing.expect(s.begin(t0 + 500 + check_interval_ms, false));
    s.complete(t1, false);
    try testing.expectEqual(@as(u8, 1), s.failures);
    try testing.expect(!s.due(t1 + fast_retry_delay_ms - 1));
    try testing.expect(s.due(t1 + fast_retry_delay_ms));

    const t2 = t1 + fast_retry_delay_ms + 250;
    try testing.expect(s.begin(t1 + fast_retry_delay_ms, false));
    s.complete(t2, false);
    try testing.expectEqual(@as(u8, 2), s.failures);
    try testing.expect(!s.due(t2 + retry_delay_ms - 1));
    try testing.expect(s.due(t2 + retry_delay_ms));

    const t3 = t2 + retry_delay_ms + 250;
    try testing.expect(s.begin(t2 + retry_delay_ms, false));
    s.complete(t3, false);
    try testing.expectEqual(@as(u8, 3), s.failures);
    try testing.expect(!s.due(t3 + check_interval_ms - 1));
    try testing.expect(s.due(t3 + check_interval_ms));

    try testing.expect(s.begin(t3 + check_interval_ms, false));
    s.complete(t3 + check_interval_ms + 100, true);
    try testing.expectEqual(@as(u8, 0), s.failures);
}

test "graff auto-update retries silently before falling back to manual Available notice" {
    const testing = std.testing;
    const ui = nanoui.ui;
    @import("theme.zig").registerFonts();

    try testing.expectEqual(view_updates.GraffKind.none, failureNoticeKind(true, false, 0));
    try testing.expectEqual(view_updates.GraffKind.none, failureNoticeKind(true, false, 1));
    try testing.expectEqual(view_updates.GraffKind.available, failureNoticeKind(true, false, 2));
    try testing.expectEqual(view_updates.GraffKind.available, failureNoticeKind(true, true, 0));
    try testing.expectEqual(view_updates.GraffKind.available, failureNoticeKind(false, false, 0));

    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = false;
    a.settings.setText("uiMode", "classic");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1120, .height = 760, .dark = false });
    defer t.deinit();

    // Old behavior showed an intrusive manual "Update available" prompt on the first failure.
    a.updates.publishGraff(.available, "0.302.74.80", "0.302.74.81", null);
    t.settle(1);
    try testing.expect(t.containsText("Codegraff engine update available"));
    try testing.expect(t.containsText("Update"));
    if (std.c.getenv("NANO_GRAFF_AUTO_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/before-graff-manual.png", .{std.mem.span(dir)})) |p| t.screenshot(p) catch {} else |_| {}
    }

    // Transient auto-update failure now clears silently so background retry completes without prompting.
    a.updates.publishGraff(.updating, "0.302.74.80", "0.302.74.81", null);
    t.settle(1);
    a.updates.clearGraff();
    t.settle(1);
    try testing.expect(!t.containsText("Codegraff engine update available"));
    try testing.expect(!a.updates.graff_card_open);

    const version_out =
        \\graff 0.302.74.81
        \\
        \\What's new
        \\──────────
        \\0.302.74.81
        \\  • Retry transient background downloads quietly before falling back to manual Update.
    ;
    a.updates.publishGraff(.updated, "0.302.74.80", "0.302.74.81", version_out);
    t.settle(1);
    try testing.expect(t.containsText("Codegraff engine updated"));
    if (std.c.getenv("NANO_GRAFF_AUTO_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/after-graff-updated.png", .{std.mem.span(dir)})) |p| t.screenshot(p) catch {} else |_| {}
    }
}

test "graff extractAndSwapArchive verifies checksum, unpacks, validates --version, and swaps atomically" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    const gpa = testing.allocator;

    const root = "/tmp/harness-graff-swap-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/pkg/graff-aarch64-macos");

    const managed = root ++ "/graff";
    const new_bin = root ++ "/pkg/graff-aarch64-macos/graff";
    const tar_path = root ++ "/graff-aarch64-macos.tar.gz";
    const stage_dir = root ++ "/stage";

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = managed,
        .data = "#!/bin/sh\necho 'graff 0.302.74.80'\n",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = new_bin,
        .data = "#!/bin/sh\necho 'graff 0.302.74.81'\n",
    });
    var chmod_child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/chmod", "755", managed, new_bin },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try chmod_child.wait(io);

    var tar_child = try std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/tar", "-czf", tar_path, "-C", root ++ "/pkg", "graff-aarch64-macos" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const tar_term = try tar_child.wait(io);
    try testing.expect(tar_term == .exited and tar_term.exited == 0);

    // Missing SHA256SUMS must fail closed and leave the existing binary untouched.
    try testing.expect(!extractAndSwapArchive(gpa, io, "graff-aarch64-macos.tar.gz", tar_path, null, stage_dir, managed));
    const missing_out = versionOutput(gpa, io, managed) orelse return error.MissingOldVersion;
    defer gpa.free(missing_out);
    try testing.expect(std.mem.indexOf(u8, missing_out, "0.302.74.80") != null);

    // Mismatched SHA256SUMS must leave existing managed binary untouched.
    const bad_sums = "0000000000000000000000000000000000000000000000000000000000000000  graff-aarch64-macos.tar.gz\n";
    try testing.expect(!extractAndSwapArchive(gpa, io, "graff-aarch64-macos.tar.gz", tar_path, bad_sums, stage_dir, managed));
    const before_out = versionOutput(gpa, io, managed) orelse return error.MissingOldVersion;
    defer gpa.free(before_out);
    try testing.expect(std.mem.indexOf(u8, before_out, "0.302.74.80") != null);

    // Matching SHA256SUMS swaps in the verified binary atomically.
    const actual_hex = sha256FileHex(gpa, io, tar_path) orelse return error.MissingSha;
    const good_sums = try std.fmt.allocPrint(gpa, "{s}  graff-aarch64-macos.tar.gz\n", .{&actual_hex});
    defer gpa.free(good_sums);
    try testing.expect(extractAndSwapArchive(gpa, io, "graff-aarch64-macos.tar.gz", tar_path, good_sums, stage_dir, managed));
    const after_out = versionOutput(gpa, io, managed) orelse return error.MissingNewVersion;
    defer gpa.free(after_out);
    try testing.expect(std.mem.indexOf(u8, after_out, "0.302.74.81") != null);
}

test "graff latest tag parser handles redirect URLs, pretty JSON, and SHA256SUMS" {
    const testing = std.testing;
    try testing.expectEqualStrings(
        "v0.302.74.75",
        tagFromRedirectUrl("https://github.com/justrach/codegraff/releases/tag/v0.302.74.75\n").?,
    );
    try testing.expectEqualStrings(
        "v0.302.74.75",
        tagFromRedirectUrl("https://github.com/justrach/codegraff/releases/tag/v0.302.74.75?ref=1").?,
    );
    try testing.expect(tagFromRedirectUrl("https://github.com/justrach/codegraff/releases") == null);

    const pretty = "{ \"tag_name\": \"v0.302.74.75\", \"draft\": false }";
    const parsed = tagFromReleaseJson(testing.allocator, pretty) orelse return error.MissingTag;
    defer testing.allocator.free(parsed);
    try testing.expectEqualStrings("v0.302.74.75", parsed);

    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const sums = digest ++ "  graff-aarch64-macos.tar.gz\n";
    try testing.expect(verifySha256Sums(sums, "graff-aarch64-macos.tar.gz", digest));
    try testing.expect(!verifySha256Sums(sums, "graff-x86_64-macos.tar.gz", digest));
}

test "graff auto-update notice surfaces sidebar pill and What's New bubble" {
    const testing = std.testing;
    const ui = nanoui.ui;
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.dark = false;
    a.settings.setText("uiMode", "classic");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1120, .height = 760, .dark = false });
    defer t.deinit();
    t.settle(1);
    try testing.expect(!t.containsText("Codegraff v0.302.74.75"));
    if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/graff-update-before.png", .{std.mem.span(dir)})) |p| t.screenshot(p) catch {} else |_| {}
    }

    const version_out =
        \\graff 0.302.74.75
        \\
        \\What's new
        \\──────────
        \\0.302.74.75
        \\  • Add Native Flint (nanoattention/flint) local provider and ACP saw_text safeguard.
        \\  • Add GPT-6.2 Sol/Astra, non-blocking model refresh (/refresh), and ultrafast tier.
    ;
    a.updates.publishGraff(.updated, "0.302.74.74", "0.302.74.75", version_out);
    t.settle(1);
    try testing.expect(t.containsText("Codegraff v0.302.74.75"));
    try testing.expect(t.containsText("WHAT'S NEW"));
    try testing.expect(t.containsText("Got it"));
    if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/graff-update-after.png", .{std.mem.span(dir)})) |p| t.screenshot(p) catch {} else |_| {}
    }

    try t.clickText("Got it");
    t.settle(1);
    try testing.expect(!t.containsText("WHAT'S NEW"));
}
