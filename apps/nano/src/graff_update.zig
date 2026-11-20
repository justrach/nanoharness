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
/// Short backoff after a single transient network failure before returning to
/// the 10-minute schedule.
pub const retry_delay_ms: i64 = 2 * 60 * 1000;

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
        const delay: i64 = if (!ok and s.failures == 1) retry_delay_ms else check_interval_ms;
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
        if (msg.to) |to| {
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
            // Swap failed: surface Available so the user can retry instead of
            // leaving an eternal "Updating…" pill.
            postUi(a, true, false, true, .available, current, bare_tag, null);
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

    if (!curlDownload(io, url, tar)) return false;
    if (curlDownload(io, sums_url, sums_path)) {
        const sums_bytes = std.Io.Dir.cwd().readFileAlloc(io, sums_path, gpa, .limited(256 * 1024)) catch return false;
        defer gpa.free(sums_bytes);
        const actual = sha256FileHex(gpa, io, tar) orelse return false;
        if (!verifySha256Sums(sums_bytes, asset, &actual)) {
            std.log.warn("harness-nano: graff {s} SHA256SUMS verification failed", .{tag});
            return false;
        }
    }

    const stage = std.fmt.allocPrint(gpa, "{s}/.graff-update-stage", .{bin_dir}) catch return false;
    defer gpa.free(stage);
    std.Io.Dir.cwd().deleteTree(io, stage) catch {};
    std.Io.Dir.cwd().createDirPath(io, stage) catch return false;
    defer std.Io.Dir.cwd().deleteTree(io, stage) catch {};

    var child = std.process.spawn(io, .{
        .argv = &.{ "tar", "-xzf", tar, "-C", stage },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    if (term != .exited or term.exited != 0) return false;

    const extracted = findGraff(gpa, io, stage) orelse return false;
    defer gpa.free(extracted);

    // Ensure executable permissions before atomic swap.
    var chmod_child = std.process.spawn(io, .{
        .argv = &.{ "chmod", "755", extracted },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const chmod_term = chmod_child.wait(io) catch return false;
    if (chmod_term != .exited or chmod_term.exited != 0) return false;

    // Atomic rename directly over managed path (no delete-before-rename window;
    // any running `graff acp` keeps its unlinked inode).
    std.Io.Dir.cwd().rename(extracted, std.Io.Dir.cwd(), managed, io) catch return false;
    return true;
}

fn findGraff(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    const list = std.fmt.allocPrint(gpa, "{s}/.list", .{dir}) catch return null;
    defer gpa.free(list);
    const file = std.Io.Dir.cwd().createFile(io, list, .{}) catch return null;
    var child = std.process.spawn(io, .{
        .argv = &.{ "find", dir, "-type", "f", "-name", "graff" },
        .stdin = .ignore,
        .stdout = .{ .file = file },
        .stderr = .ignore,
    }) catch return null;
    _ = child.wait(io) catch return null;
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
    var tmp_buf: [128]u8 = undefined;
    const seed = std.Io.Clock.real.now(io).nanoseconds;
    const out_path = std.fmt.bufPrint(&tmp_buf, "/tmp/harness-graff-upd-{d}.tmp", .{seed}) catch return null;
    const file = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch return null;
    defer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = file },
        .stderr = .ignore,
    }) catch return null;
    const term = child.wait(io) catch return null;
    if (term != .exited or term.exited != 0) return null;
    return std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .limited(max_bytes)) catch null;
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

test "graff auto-update schedule polls every 10 minutes and retries once after failure" {
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

    // Transient failure retries after 2 minutes, then returns to 10 minutes.
    try testing.expect(s.begin(t0 + 500 + check_interval_ms, false));
    const t1 = t0 + 1000 + check_interval_ms;
    s.complete(t1, false);
    try testing.expect(!s.due(t1 + retry_delay_ms - 1));
    try testing.expect(s.due(t1 + retry_delay_ms));

    try testing.expect(s.begin(t1 + retry_delay_ms, false));
    s.complete(t1 + retry_delay_ms + 500, false);
    try testing.expect(!s.due(t1 + retry_delay_ms + 500 + check_interval_ms - 1));
    try testing.expect(s.due(t1 + retry_delay_ms + 500 + check_interval_ms));
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
