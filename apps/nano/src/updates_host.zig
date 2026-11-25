//! This engine's own updates (`UpdateStatus`, `CheckForUpdates`,
//! `QueueUpdate`, `ApplyUpdate`): the Zig port of `crates/update` as the
//! engine's RPCs use it.
//!
//! How the binary was installed decides the path (`detect_install`): a
//! managed install (`~/.harness/app/<ver>` behind `current`) stages the
//! release tarball, verifies its manifest SHA-256, repoints `current` and
//! restarts; a macOS app bundle only reports (its UI installs); anything else
//! (source builds, copied binaries) is report-only and never checks. Managed
//! and app installs run a background release check: 20 s after start, then
//! hourly on the wall clock (1, 5, 15, 30 min after failures).
//!
//! Network, commands, the restart and the process list go through seams
//! (`Http`, `proc_seam.Runner`, `Restarter`, `Processes`) so tests answer from
//! made-up releases and never install or restart anything.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const proc = @import("proc_seam.zig");

pub const check_interval_ms: i64 = 60 * 60 * 1000;
pub const check_backoff_ms = [_]i64{ 60_000, 5 * 60_000, 15 * 60_000, 30 * 60_000 };
pub const check_initial_delay_ms: i64 = 20_000;
pub const idle_recheck_ms: i64 = 5 * 60_000;
pub const launchd_label = "harness.codegraff.app";
/// The executables a Zig release ships: the engine (what a managed install
/// runs from `current/`) and the app inside `Harness.app`. Never the Rust
/// `harness`.
pub const engine_bin = if (builtin.os.tag == .windows) "harness-engine.exe" else "harness-engine";
pub const app_bin = "harness-nano";

pub const github_latest = "https://github.com/justrach/nanoharness/releases/latest/download";

// ---------------------------------------------------------------- pure rules

/// Strictly-newer dotted-numeric compare; unparseable versions never count as newer.
pub fn versionNewer(latest: []const u8, current: []const u8) bool {
    var a: [16]u64 = undefined;
    var b: [16]u64 = undefined;
    const la = parts(latest, &a) orelse return false;
    const lb = parts(current, &b) orelse return false;
    return std.mem.order(u64, la, lb) == .gt;
}

fn parts(v: []const u8, out: *[16]u64) ?[]const u64 {
    const t = std.mem.trimStart(u8, std.mem.trim(u8, v, " \t\r\n"), "v");
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t, '.');
    while (it.next()) |p| {
        if (n == out.len) return null;
        out[n] = std.fmt.parseInt(u64, p, 10) catch return null;
        n += 1;
    }
    return if (n == 0) null else out[0..n];
}

/// A release version this engine will put in a URL, a folder name and the
/// `current` link: `[0-9A-Za-z.+-]+`, not only dots, at most 64 bytes.
/// Stricter than the Rust updater, which takes the feed's text as it is.
pub fn validVersion(v: []const u8) bool {
    if (v.len == 0 or v.len > 64) return false;
    var dots_only = true;
    for (v) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '+' or c == '-')) return false;
        if (c != '.') dots_only = false;
    }
    return !dots_only;
}

pub fn platformKey() struct { os: []const u8, arch: []const u8 } {
    const os: []const u8 = @tagName(builtin.os.tag);
    const arch: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => if (builtin.os.tag == .macos) "arm64" else "aarch64",
        else => @tagName(builtin.cpu.arch),
    };
    return .{ .os = os, .arch = arch };
}

/// `harness-<ver>-<os>-<arch>.tar.gz`.
pub fn headlessArtifactAlloc(gpa: Allocator, version: []const u8) ![]u8 {
    const k = platformKey();
    return std.fmt.allocPrint(gpa, "harness-{s}-{s}-{s}.tar.gz", .{ version, k.os, k.arch });
}

/// `harness-<ver>-macos-<arch>-app.tar.gz` (`mac_app_artifact`).
pub fn macAppArtifactAlloc(gpa: Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "harness-{s}-macos-{s}-app.tar.gz", .{ version, platformKey().arch });
}

/// Ed25519 public key baked into the app (`scripts/gen-release-key.py`, see
/// docs/adr/0009); pairs with the CI `RELEASE_MANIFEST_SIGNING_KEY` secret.
pub const release_verify_key: [32]u8 = .{
    0x81, 0x1b, 0x3c, 0x04, 0x21, 0x34, 0x1b, 0x27,
    0xdf, 0xbd, 0x46, 0xd0, 0x90, 0xc2, 0x99, 0x5d,
    0x7a, 0xe5, 0x70, 0x76, 0x16, 0x2c, 0xe7, 0x77,
    0x39, 0x0d, 0x12, 0xb2, 0xa5, 0xe5, 0xa8, 0xe1,
};

/// `version` plus each `file=sha256` line, sorted. The private key signs this.
pub fn manifestMessage(arena: Allocator, version: []const u8, files: ?json.ObjectMap) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(arena);
    try buf.appendSlice(arena, version);
    try buf.append(arena, '\n');
    if (files) |map| {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(arena);
        var it = map.iterator();
        while (it.next()) |e| try names.append(arena, e.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |name| {
            const meta = map.get(name) orelse continue;
            if (meta != .object) continue;
            const sha_v = meta.object.get("sha256") orelse continue;
            if (sha_v != .string) continue;
            try buf.appendSlice(arena, name);
            try buf.append(arena, '=');
            try buf.appendSlice(arena, sha_v.string);
            try buf.append(arena, '\n');
        }
    }
    return buf.toOwnedSlice(arena);
}

pub fn verifyManifestSig(message: []const u8, sig: []const u8, pubkey: [32]u8) bool {
    if (sig.len != 64) return false;
    const Ed = std.crypto.sign.Ed25519;
    const pk = Ed.PublicKey.fromBytes(pubkey) catch return false;
    var sig_bytes: [64]u8 = undefined;
    @memcpy(&sig_bytes, sig[0..64]);
    const signature = Ed.Signature.fromBytes(sig_bytes);
    signature.verify(message, pk) catch return false;
    return true;
}

pub fn autoUpdateFrom(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return true, " \t\r\n");
    var buf: [8]u8 = undefined;
    if (v.len > buf.len) return true;
    const low = std.ascii.lowerString(&buf, v);
    for ([_][]const u8{ "0", "false", "no", "off" }) |off| if (std.mem.eql(u8, low, off)) return false;
    return true;
}

pub fn supervisedBy(invocation_id: ?[]const u8, xpc_service: ?[]const u8) bool {
    if (invocation_id) |i| if (i.len > 0) return true;
    return if (xpc_service) |x| std.mem.eql(u8, x, launchd_label) else false;
}

pub fn nextCheckDelayMs(ok: bool, failures: u32) i64 {
    if (ok) return check_interval_ms;
    const step = @min(@as(usize, @max(failures, 1)) - 1, check_backoff_ms.len - 1);
    return check_backoff_ms[step];
}

/// Due on the wall clock; a due time more than an interval ahead means the clock went back.
pub fn checkDue(now_ms: i64, due_ms: i64) bool {
    return now_ms >= due_ms or due_ms - now_ms > check_interval_ms;
}

pub const InstallKind = enum { managed, mac_app, unmanaged };

pub const Install = struct {
    kind: InstallKind,
    /// `app_root` for managed installs, the bundle for app installs.
    path: []const u8 = "",

    pub fn checksReleases(self: Install) bool {
        return self.kind != .unmanaged;
    }
};

/// `detect_install_from`: `is_dev_bundle(bundle)` reads the bundle's identifier.
pub fn detectInstallFrom(exe: []const u8, home: ?[]const u8, os: std.Target.Os.Tag, buf: []u8, ctx: anytype, isDevBundle: fn (@TypeOf(ctx), []const u8) bool) Install {
    if (os != .linux and os != .macos) return .{ .kind = .unmanaged };
    if (home) |h| {
        const root = std.fmt.bufPrint(buf, "{s}/.harness/app", .{std.mem.trimEnd(u8, h, "/")}) catch return .{ .kind = .unmanaged };
        if (std.mem.startsWith(u8, exe, root) and (exe.len == root.len or exe[root.len] == '/')) return .{ .kind = .managed, .path = root };
    }
    var end: usize = exe.len;
    while (std.mem.lastIndexOfScalar(u8, exe[0..end], '/')) |slash| {
        const ancestor = exe[0..slash];
        if (std.mem.endsWith(u8, ancestor, ".app") and std.mem.startsWith(u8, exe[slash..], "/Contents/MacOS/")) {
            if (isDevBundle(ctx, ancestor)) return .{ .kind = .unmanaged };
            return .{ .kind = .mac_app, .path = ancestor };
        }
        end = slash;
    }
    return .{ .kind = .unmanaged };
}

/// Whether `entry` is a bundle `applyMacApp` moved aside from `bundle_name`:
/// `.{bundle_name}.old-` and the swap's 12 hex digits.
pub fn isReplacedBundle(entry: []const u8, bundle_name: []const u8) bool {
    var rest = entry;
    for ([_][]const u8{ ".", bundle_name, ".old-" }) |part| {
        if (!std.mem.startsWith(u8, rest, part)) return false;
        rest = rest[part.len..];
    }
    if (rest.len != 12) return false;
    for (rest) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Whether any of `executables` is inside a folder called `dir_name`. Replaced
/// bundles have random names, so the name alone decides: how the path up to it
/// is spelled (`/tmp` or `/private/tmp`) doesn't matter.
pub fn runsInside(executables: []const []const u8, dir_name: []const u8) bool {
    for (executables) |exe| {
        var it = std.mem.splitScalar(u8, std.fs.path.dirname(exe) orelse continue, '/');
        while (it.next()) |part| if (std.mem.eql(u8, part, dir_name)) return true;
    }
    return false;
}

/// The `CFBundleIdentifier` string of an XML Info.plist.
pub fn plistBundleId(text: []const u8) ?[]const u8 {
    const key = "<key>CFBundleIdentifier</key>";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const open = std.mem.indexOf(u8, rest, "<string>") orelse return null;
    const after = rest[open + "<string>".len ..];
    const close = std.mem.indexOf(u8, after, "</string>") orelse return null;
    return std.mem.trim(u8, after[0..close], " \t\r\n");
}

/// `HARNESS_RELEASES_URL` must be an https base URL without credentials, query or fragment.
pub fn validateReleaseOverride(gpa: Allocator, value: []const u8) union(enum) { ok: []u8, err: []const u8 } {
    const v = std.mem.trim(u8, value, " \t\r\n");
    const uri = std.Uri.parse(v) catch return .{ .err = "invalid update feed URL" };
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null) return .{ .err = "update feed must use HTTPS" };
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return .{ .err = "update feed must be a base URL without credentials, query, or fragment" };
    return .{ .ok = gpa.dupe(u8, std.mem.trimEnd(u8, v, "/")) catch return .{ .err = "out of memory" } };
}

// ---------------------------------------------------------------- seams

pub const HttpReply = struct { status: u16, body: []u8 };

/// What a download wrote: the final status, and the SHA-256 and size of the body.
pub const Download = struct { status: u16, sha256: [32]u8, size: u64 };

/// The largest release artifact and manifest this engine downloads.
pub const max_artifact_bytes: u64 = 1 << 30;
pub const max_manifest_bytes: u64 = 1 << 20;

pub const Http = struct {
    ctx: ?*anyopaque = null,
    get_fn: *const fn (ctx: ?*anyopaque, gpa: Allocator, url: []const u8) anyerror!HttpReply,
    /// Streams `url` into a new file at `dest`, at most `max_bytes`. Unset
    /// (made-up releases in tests): `get_fn`'s body is written instead.
    download_fn: ?*const fn (ctx: ?*anyopaque, gpa: Allocator, io: std.Io, url: []const u8, dest: []const u8, max_bytes: u64) anyerror!Download = null,

    pub fn get(self: Http, gpa: Allocator, url: []const u8) anyerror!HttpReply {
        return self.get_fn(self.ctx, gpa, url);
    }

    pub fn download(self: Http, gpa: Allocator, io: std.Io, url: []const u8, dest: []const u8, max_bytes: u64) anyerror!Download {
        if (self.download_fn) |f| return f(self.ctx, gpa, io, url, dest, max_bytes);
        const r = try self.get(gpa, url);
        defer gpa.free(r.body);
        if (r.body.len > max_bytes) return error.TooLarge;
        var out: Download = .{ .status = r.status, .sha256 = undefined, .size = r.body.len };
        std.crypto.hash.sha2.Sha256.hash(r.body, &out.sha256, .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = r.body });
        return out;
    }
};

pub const RestartKind = enum { service, reexec };

pub const Restarter = struct {
    ctx: ?*anyopaque = null,
    /// Called on a background thread after the reply has had time to flush.
    restart_fn: *const fn (ctx: ?*anyopaque, app_root: []const u8) void,
};

/// The executables running on this device, so an app bundle that was replaced
/// is never deleted under a process still running from it.
pub const Processes = struct {
    ctx: ?*anyopaque = null,
    /// Every running process's executable where it is on disk *now* (a process
    /// whose bundle was renamed is listed under the new name), in `arena`.
    /// Null: couldn't tell.
    executables_fn: *const fn (ctx: ?*anyopaque, arena: Allocator) Allocator.Error!?[]const []const u8,

    pub fn executables(self: Processes, arena: Allocator) Allocator.Error!?[]const []const u8 {
        return self.executables_fn(self.ctx, arena);
    }
};

// ---------------------------------------------------------------- state

pub const Phase = enum { idle, checking, downloading, waitingForIdle, restarting, failed };
pub const Mode = enum { managed, desktop, manual };

pub const Updater = struct {
    gpa: Allocator,
    io: ?std.Io,
    install: Install,
    automatic: bool,
    edge_url: []const u8,
    current_version: []const u8,
    /// `HARNESS_RELEASES_URL`, when set.
    releases_override: ?[]const u8 = null,
    /// Refuse ApplyUpdate unless the manifest carries a valid Ed25519 `sig`.
    /// Tests that predate signing set this false; production stays true.
    require_manifest_sig: bool = true,
    http: Http,
    runner: proc.Runner,
    restarter: Restarter,
    processes: Processes = .{ .executables_fn = runningExecutables },
    /// Nothing would be interrupted by a restart now (no live run, no open terminal).
    quiescent_ctx: ?*anyopaque = null,
    quiescent_fn: ?*const fn (ctx: ?*anyopaque) bool = null,

    mutex: std.Io.Mutex = .init,
    latest: ?[]u8 = null,
    available: bool = false,
    checked_at: ?i64 = null,
    err: ?[]u8 = null,
    phase: Phase = .idle,
    requested: bool = false,
    wake_seq: u64 = 0,
    shutting_down: bool = false,
    last_reply_err: ?[]u8 = null,

    pub fn deinit(self: *Updater) void {
        if (self.latest) |l| self.gpa.free(l);
        if (self.err) |e| self.gpa.free(e);
        if (self.last_reply_err) |e| self.gpa.free(e);
    }

    fn lock(self: *Updater) void {
        if (self.io) |io| self.mutex.lockUncancelable(io);
    }

    fn unlock(self: *Updater) void {
        if (self.io) |io| self.mutex.unlock(io);
    }

    pub fn mode(self: *const Updater) Mode {
        return switch (self.install.kind) {
            .managed => .managed,
            .mac_app => .desktop,
            .unmanaged => .manual,
        };
    }

    /// The `UpdateStatus` item (optional fields left out when unset).
    pub fn statusJson(self: *Updater, gpa: Allocator) ![]u8 {
        self.lock();
        defer self.unlock();
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\"currentVersion\":{f}", .{json.fmt(self.current_version, .{})});
        if (self.latest) |l| try w.print(",\"latestVersion\":{f}", .{json.fmt(l, .{})});
        try w.print(",\"updateAvailable\":{}", .{self.available});
        if (self.checked_at) |c| try w.print(",\"checkedAt\":{d}", .{c});
        if (self.err) |e| try w.print(",\"error\":{f}", .{json.fmt(e, .{})});
        try w.print(",\"host\":{{\"mode\":\"{s}\",\"automatic\":{},\"phase\":\"{s}\"}}}}", .{ @tagName(self.mode()), self.automatic, @tagName(self.phase) });
        return aw.toOwnedSlice();
    }

    fn setPhase(self: *Updater, p: Phase) void {
        self.lock();
        defer self.unlock();
        self.phase = p;
    }

    fn failWith(self: *Updater, msg: []u8) void {
        self.lock();
        defer self.unlock();
        if (self.err) |e| self.gpa.free(e);
        self.err = msg;
        self.phase = .failed;
    }

    pub fn checkNow(self: *Updater) void {
        self.lock();
        defer self.unlock();
        self.wake_seq +%= 1;
    }

    /// `QueueUpdate`: one managed-host update; coalesces, never bypasses the idle gate.
    pub fn queueUpdate(self: *Updater) ?[]const u8 {
        if (self.install.kind != .managed) return "this device cannot queue a remote update; update its desktop app or package locally";
        self.lock();
        defer self.unlock();
        if (self.shutting_down) return "the updater is shutting down";
        self.requested = true;
        self.wake_seq +%= 1;
        return null;
    }

    fn releaseBase(self: *const Updater, gpa: Allocator) ![]u8 {
        if (self.releases_override) |o| return gpa.dupe(u8, o);
        if (self.install.kind != .unmanaged) return gpa.dupe(u8, github_latest);
        return std.fmt.allocPrint(gpa, "{s}/releases", .{std.mem.trimEnd(u8, self.edge_url, "/")});
    }

    pub const Manifest = struct {
        version: []const u8,
        /// The artifact's `sha256`, when the manifest lists one.
        files: ?json.ObjectMap = null,
        /// Raw 64-byte Ed25519 signature over [`manifestMessage`].
        sig: ?[]const u8 = null,

        pub fn sha256For(self: Manifest, file: []const u8) ?[]const u8 {
            return sha256From(self.files orelse return null, file);
        }

        fn sha256From(files: json.ObjectMap, file: []const u8) ?[]const u8 {
            const meta = files.get(file) orelse return null;
            if (meta != .object) return null;
            const s = meta.object.get("sha256") orelse return null;
            return if (s == .string) s.string else null;
        }
    };

    fn decodeSig(arena: Allocator, raw: []const u8) ?[]const u8 {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len == 128) {
            const out = arena.alloc(u8, 64) catch return null;
            _ = std.fmt.hexToBytes(out, t) catch return null;
            return out;
        }
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const n = decoder.calcSizeForSlice(t) catch return null;
        if (n != 64) return null;
        const out = arena.alloc(u8, 64) catch return null;
        decoder.decode(out, t) catch return null;
        return out;
    }

    /// `manifest.json`, falling back to `latest.txt`. Error → message (arena).
    pub fn fetchLatest(self: *Updater, arena: Allocator) !union(enum) { ok: Manifest, err: []const u8 } {
        const base = try self.releaseBase(arena);
        const murl = try std.fmt.allocPrint(arena, "{s}/manifest.json", .{base});
        if (self.http.get(arena, murl)) |r| {
            if (r.status >= 200 and r.status < 300) {
                const v = json.parseFromSliceLeaky(json.Value, arena, r.body, .{}) catch
                    return .{ .err = "parsing manifest.json: invalid JSON" };
                const ver = if (v == .object) v.object.get("version") else null;
                if (ver == null or ver.? != .string) return .{ .err = "parsing manifest.json: missing field `version`" };
                const version = std.mem.trim(u8, ver.?.string, " \t\r\n");
                if (version.len == 0) return .{ .err = "manifest.json has an empty version" };
                if (!validVersion(version)) return .{ .err = try std.fmt.allocPrint(arena, "manifest.json names an invalid version: {f}", .{json.fmt(version, .{})}) };
                const files = v.object.get("files");
                const sig_field = v.object.get("sig");
                const sig = if (sig_field) |s| (if (s == .string) decodeSig(arena, s.string) else null) else null;
                return .{ .ok = .{
                    .version = version,
                    .files = if (files) |f| (if (f == .object) f.object else null) else null,
                    .sig = sig,
                } };
            }
        } else |_| {}
        const lurl = try std.fmt.allocPrint(arena, "{s}/latest.txt", .{base});
        const r = self.http.get(arena, lurl) catch |e|
            return .{ .err = try std.fmt.allocPrint(arena, "fetching latest.txt: {s}", .{@errorName(e)}) };
        if (r.status < 200 or r.status >= 300)
            return .{ .err = try std.fmt.allocPrint(arena, "fetching latest.txt: HTTP status {d}", .{r.status}) };
        const ver = std.mem.trim(u8, r.body, " \t\r\n");
        if (ver.len == 0) return .{ .err = "latest.txt is empty" };
        if (!validVersion(ver)) return .{ .err = try std.fmt.allocPrint(arena, "latest.txt names an invalid version: {f}", .{json.fmt(ver, .{})}) };
        return .{ .ok = .{ .version = ver } };
    }

    /// One check; false on failure (retry sooner). It first deletes the bundles
    /// earlier app updates replaced: the background checks start 20 s after
    /// launch and repeat, so one goes once the process it waited for quits.
    pub fn checkOnce(self: *Updater, now_ms: i64) !bool {
        if (self.install.kind == .mac_app) self.removeReplacedBundles(self.install.path);
        self.setPhase(.checking);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        switch (try self.fetchLatest(arena_state.allocator())) {
            .ok => |m| {
                const latest = try self.gpa.dupe(u8, m.version);
                self.lock();
                defer self.unlock();
                if (self.latest) |l| self.gpa.free(l);
                self.latest = latest;
                self.available = versionNewer(m.version, self.current_version);
                self.checked_at = now_ms;
                if (self.err) |e| self.gpa.free(e);
                self.err = null;
                self.phase = .idle;
                return true;
            },
            .err => |e| {
                self.failWith(try self.gpa.dupe(u8, e));
                return false;
            },
        }
    }

    /// Download `file` into `dest`: streamed to `dest.partial`, verified against
    /// the manifest's SHA-256, then renamed into place. A file the manifest
    /// gives no SHA-256 for is never installed (the Rust updater installs a
    /// managed release unverified then; `stage_mac_app` already refuses).
    fn download(self: *Updater, arena: Allocator, io: std.Io, m: Manifest, file: []const u8, dest: []const u8) !?[]const u8 {
        const expected_raw = m.sha256For(file) orelse
            return try std.fmt.allocPrint(arena, "the release has no SHA-256 for {s}; refusing to install it unverified", .{file});
        const expected = std.mem.trim(u8, expected_raw, " \t\r\n");
        const base = try self.releaseBase(arena);
        const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, file });
        const partial = try std.fmt.allocPrint(arena, "{s}.partial", .{dest});
        const got = self.http.download(arena, io, url, partial, max_artifact_bytes) catch |e| {
            std.Io.Dir.cwd().deleteFile(io, partial) catch {};
            return try std.fmt.allocPrint(arena, "downloading {s}: {s}", .{ url, downloadErrorText(e) });
        };
        if (got.status < 200 or got.status >= 300) {
            std.Io.Dir.cwd().deleteFile(io, partial) catch {};
            return try std.fmt.allocPrint(arena, "downloading {s}: HTTP status {d}", .{ url, got.status });
        }
        const actual = std.fmt.bytesToHex(got.sha256, .lower);
        if (!std.ascii.eqlIgnoreCase(&actual, expected)) {
            std.Io.Dir.cwd().deleteFile(io, partial) catch {};
            return try std.fmt.allocPrint(arena, "checksum mismatch for {s}: expected {s}, got {s}", .{ file, expected, &actual });
        }
        std.Io.Dir.rename(std.Io.Dir.cwd(), partial, std.Io.Dir.cwd(), dest, io) catch |e|
            return try std.fmt.allocPrint(arena, "moving {s} into place: {s}", .{ dest, @errorName(e) });
        return null;
    }

    /// Download and unpack the headless tarball into `app_root/<ver>` (idempotent).
    pub fn stageHeadless(self: *Updater, arena: Allocator, m: Manifest, app_root: []const u8) !?[]const u8 {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos)
            return try std.fmt.allocPrint(arena, "managed updates are not supported on {s}", .{@tagName(builtin.os.tag)});
        const io = self.io orelse return "updates need file access";
        const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ app_root, m.version });
        const dest_bin = try std.fmt.allocPrint(arena, "{s}/" ++ engine_bin, .{dest});
        if (exists(io, dest_bin)) return null;
        const file = try headlessArtifactAlloc(arena, m.version);
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const stage = try std.fmt.allocPrint(arena, "{s}/.stage-{s}-{x}", .{ app_root, m.version, rnd });
        std.Io.Dir.cwd().deleteTree(io, stage) catch {};
        std.Io.Dir.cwd().createDirPath(io, stage) catch |e|
            return try std.fmt.allocPrint(arena, "creating {s}: {s}", .{ stage, @errorName(e) });
        defer std.Io.Dir.cwd().deleteTree(io, stage) catch {};
        const tarball = try std.fmt.allocPrint(arena, "{s}/{s}", .{ stage, file });
        if (try self.download(arena, io, m, file, tarball)) |e| return e;
        const unpacked = try std.fmt.allocPrint(arena, "{s}/unpacked", .{stage});
        std.Io.Dir.cwd().createDirPath(io, unpacked) catch |e|
            return try std.fmt.allocPrint(arena, "creating {s}: {s}", .{ unpacked, @errorName(e) });
        var out = try self.runner.run(arena, .{ .argv = &.{ "tar", "-xzf", tarball, "-C", unpacked, "--strip-components=1" }, .timeout_ms = 10 * 60_000 });
        if (!out.ok()) {
            return try std.fmt.allocPrint(arena, "tar -xzf {s} -C {s} --strip-components=1 failed ({s}): {s}", .{
                tarball, unpacked, @tagName(out.term), std.mem.trim(u8, out.stderr, " \t\r\n"),
            });
        }
        const bin = try std.fmt.allocPrint(arena, "{s}/" ++ engine_bin, .{unpacked});
        if (!exists(io, bin)) return try std.fmt.allocPrint(arena, "tarball {s} did not contain a " ++ engine_bin ++ " binary", .{file});
        std.Io.Dir.rename(std.Io.Dir.cwd(), unpacked, std.Io.Dir.cwd(), dest, io) catch |e| {
            if (!exists(io, dest_bin)) return try std.fmt.allocPrint(arena, "moving {s} into place: {s}", .{ dest, @errorName(e) });
        };
        return null;
    }

    /// `stage_mac_app`: download and unpack the app tarball into
    /// `{data_dir}/updates/<ver>/Harness.app` (idempotent); the staged bundle's
    /// path in `arena`, or why not. The manifest must give the tarball's
    /// SHA-256: an app update is never installed unverified.
    pub fn stageMacApp(self: *Updater, arena: Allocator, m: Manifest, data_dir: []const u8) !union(enum) { ok: []const u8, err: []const u8 } {
        if (builtin.os.tag != .macos)
            return .{ .err = try std.fmt.allocPrint(arena, "macOS app updates are not supported on {s}", .{@tagName(builtin.os.tag)}) };
        const file = try macAppArtifactAlloc(arena, m.version);
        if (m.sha256For(file) == null)
            return .{ .err = try std.fmt.allocPrint(arena, "stable macOS update is missing the {s} checksum", .{file}) };
        if (!validVersion(m.version)) return .{ .err = "the release names an invalid version" };
        const io = self.io orelse return .{ .err = "updates need file access" };
        const dir = try std.fmt.allocPrint(arena, "{s}/updates/{s}", .{ data_dir, m.version });
        if (try stagedMacApp(arena, io, dir)) |staged| return .{ .ok = staged };
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        std.Io.Dir.cwd().createDirPath(io, dir) catch |e|
            return .{ .err = try std.fmt.allocPrint(arena, "creating {s}: {s}", .{ dir, @errorName(e) }) };
        const tarball = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, file });
        if (try self.download(arena, io, m, file, tarball)) |e| return .{ .err = e };
        var out = try self.runner.run(arena, .{ .argv = &.{ "tar", "-xzf", tarball, "-C", dir }, .timeout_ms = 10 * 60_000 });
        if (!out.ok()) {
            return .{ .err = try std.fmt.allocPrint(arena, "tar -xzf {s} -C {s} failed ({s}): {s}", .{
                tarball, dir, @tagName(out.term), std.mem.trim(u8, out.stderr, " \t\r\n"),
            }) };
        }
        std.Io.Dir.cwd().deleteFile(io, tarball) catch {};
        if (try stagedMacApp(arena, io, dir)) |staged| return .{ .ok = staged };
        return .{ .err = try std.fmt.allocPrint(arena, "app tarball {s} did not contain Harness.app", .{file}) };
    }

    fn stagedMacApp(arena: Allocator, io: std.Io, dir: []const u8) !?[]const u8 {
        for ([_][]const u8{ "Harness.app", "Harnesser.app" }) |name| {
            const bundle = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
            if (exists(io, try std.fmt.allocPrint(arena, "{s}/Contents/MacOS/" ++ app_bin, .{bundle}))) return bundle;
        }
        return null;
    }

    /// `apply_mac_app`: copy the staged bundle next to the installed one
    /// (`ditto`, metadata-preserving), then two renames; if the second fails
    /// the old bundle is put back. Null on success, else why.
    ///
    /// The replaced bundle stays beside it under its hidden `.old-` name: the
    /// app (and its engine) still run from it until they relaunch, and macOS
    /// can't look up the code of a process whose executable was deleted, so
    /// its Open panel service fails (#173). `removeReplacedBundles` deletes it.
    pub fn applyMacApp(self: *Updater, arena: Allocator, staged: []const u8, bundle: []const u8) !?[]const u8 {
        if (builtin.os.tag != .macos) return "macOS app updates are not supported on this platform";
        const io = self.io orelse return "updates need file access";
        const parent = std.fs.path.dirname(bundle) orelse return "app bundle has no parent directory";
        const name = std.fs.path.basename(bundle);
        self.removeReplacedBundles(bundle);
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const fresh = try std.fmt.allocPrint(arena, "{s}/.{s}.new-{x}", .{ parent, name, rnd });
        const old = try std.fmt.allocPrint(arena, "{s}/.{s}.old-{x}", .{ parent, name, rnd });
        std.Io.Dir.cwd().deleteTree(io, fresh) catch {};
        var out = try self.runner.run(arena, .{ .argv = &.{ "ditto", staged, fresh }, .timeout_ms = 10 * 60_000 });
        if (!out.ok()) {
            std.Io.Dir.cwd().deleteTree(io, fresh) catch {};
            return try std.fmt.allocPrint(arena, "ditto {s} {s} failed ({s}): {s}", .{ staged, fresh, @tagName(out.term), std.mem.trim(u8, out.stderr, " \t\r\n") });
        }
        std.Io.Dir.rename(std.Io.Dir.cwd(), bundle, std.Io.Dir.cwd(), old, io) catch |e| {
            std.Io.Dir.cwd().deleteTree(io, fresh) catch {};
            return try std.fmt.allocPrint(arena, "moving the current app aside: {s}", .{@errorName(e)});
        };
        std.Io.Dir.rename(std.Io.Dir.cwd(), fresh, std.Io.Dir.cwd(), bundle, io) catch |e| {
            std.Io.Dir.rename(std.Io.Dir.cwd(), old, std.Io.Dir.cwd(), bundle, io) catch {};
            std.Io.Dir.cwd().deleteTree(io, fresh) catch {};
            return try std.fmt.allocPrint(arena, "installing the new app bundle: {s}", .{@errorName(e)});
        };
        return null;
    }

    /// Delete the bundles earlier updates moved aside from `bundle` that no
    /// process runs from any more. Whatever can't be told or deleted stays
    /// for the next time; so does everything while `bundle` itself is missing
    /// (a swap cut short between its two renames).
    pub fn removeReplacedBundles(self: *Updater, bundle: []const u8) void {
        if (builtin.os.tag != .macos) return;
        const io = self.io orelse return;
        if (!exists(io, bundle)) return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parent_path = std.fs.path.dirname(bundle) orelse return;
        var parent = std.Io.Dir.cwd().openDir(io, parent_path, .{ .iterate = true }) catch return;
        defer parent.close(io);
        var replaced: std.ArrayList([]const u8) = .empty;
        var it = parent.iterate();
        while (it.next(io) catch return) |e| {
            if (e.kind != .directory or !isReplacedBundle(e.name, std.fs.path.basename(bundle))) continue;
            const name = arena.dupe(u8, e.name) catch return;
            replaced.append(arena, name) catch return;
        }
        if (replaced.items.len == 0) return;
        const executables = (self.processes.executables(arena) catch return) orelse return;
        for (replaced.items) |name| {
            if (!runsInside(executables, name)) parent.deleteTree(io, name) catch {};
        }
    }

    /// Atomically repoint `app_root/current` at `app_root/<ver>`.
    pub fn applyHeadless(self: *Updater, arena: Allocator, app_root: []const u8, version: []const u8) !?[]const u8 {
        const io = self.io orelse return "updates need file access";
        const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ app_root, version });
        if (!exists(io, try std.fmt.allocPrint(arena, "{s}/" ++ engine_bin, .{target})))
            return try std.fmt.allocPrint(arena, "{s} is not a staged install", .{target});
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const tmp = try std.fmt.allocPrint(arena, "{s}/.current-{x}", .{ app_root, rnd });
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        std.Io.Dir.cwd().symLink(io, target, tmp, .{ .is_directory = true }) catch |e|
            return try std.fmt.allocPrint(arena, "creating current symlink: {s}", .{@errorName(e)});
        const current = try std.fmt.allocPrint(arena, "{s}/current", .{app_root});
        std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), current, io) catch |e|
            return try std.fmt.allocPrint(arena, "swapping current symlink: {s}", .{@errorName(e)});
        return null;
    }

    pub const ApplyResult = union(enum) { version: []u8, err: []const u8 };

    /// `ApplyUpdate`: stage and apply the newest release on this device (managed only), then restart.
    pub fn apply(self: *Updater, reply_gpa: Allocator) !ApplyResult {
        if (self.install.kind != .managed)
            return .{ .err = "this install is not update-managed — the desktop app updates from its UI; source builds update via git" };
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const m = switch (try self.fetchLatest(arena)) {
            .ok => |m| m,
            .err => |e| return .{ .err = self.keepErr(e) },
        };
        if (try self.refuseUnsigned(arena, m)) |e| return .{ .err = self.keepErr(e) };
        if (!versionNewer(m.version, self.current_version))
            return .{ .err = self.keepErr(try std.fmt.allocPrint(arena, "already up to date ({s})", .{self.current_version})) };
        if (try self.stageHeadless(arena, m, self.install.path)) |e| return .{ .err = self.keepErr(e) };
        if (try self.applyHeadless(arena, self.install.path, m.version)) |e| return .{ .err = self.keepErr(e) };
        self.restarter.restart_fn(self.restarter.ctx, self.install.path);
        return .{ .version = try reply_gpa.dupe(u8, m.version) };
    }

    fn refuseUnsigned(self: *Updater, arena: Allocator, m: Manifest) !?[]const u8 {
        if (!self.require_manifest_sig) return null;
        const sig = m.sig orelse return try std.fmt.allocPrint(arena, "unsigned manifest; refusing to install", .{});
        const message = try manifestMessage(arena, m.version, m.files);
        if (!verifyManifestSig(message, sig, release_verify_key))
            return try std.fmt.allocPrint(arena, "manifest signature mismatch", .{});
        return null;
    }

    fn keepErr(self: *Updater, msg: []const u8) []const u8 {
        const copy = self.gpa.dupe(u8, msg) catch return "out of memory";
        if (self.last_reply_err) |old| self.gpa.free(old);
        self.last_reply_err = copy;
        return copy;
    }

    fn quiescentNow(self: *Updater) bool {
        const f = self.quiescent_fn orelse return true;
        return f(self.quiescent_ctx);
    }

    /// Stage while busy, install only once idle (managed installs, automatic or requested).
    pub fn autoApplyWhenIdle(self: *Updater, sleeper: anytype) !?[]u8 {
        if (self.install.kind != .managed) return try self.gpa.dupe(u8, "not a managed install");
        self.setPhase(.downloading);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const m = switch (try self.fetchLatest(arena)) {
            .ok => |m| m,
            .err => |e| return try self.gpa.dupe(u8, e),
        };
        {
            const latest = try self.gpa.dupe(u8, m.version);
            self.lock();
            if (self.latest) |l| self.gpa.free(l);
            self.latest = latest;
            self.available = versionNewer(m.version, self.current_version);
            self.unlock();
        }
        if (!versionNewer(m.version, self.current_version)) {
            self.lock();
            self.phase = .idle;
            self.requested = false;
            self.unlock();
            return null;
        }
        if (try self.refuseUnsigned(arena, m)) |e| return try self.gpa.dupe(u8, e);
        if (try self.stageHeadless(arena, m, self.install.path)) |e| return try self.gpa.dupe(u8, e);
        while (true) {
            self.setPhase(.waitingForIdle);
            while (!self.quiescentNow()) {
                if (!sleeper.sleep(idle_recheck_ms)) return null;
            }
            if (!sleeper.sleep(800)) return null;
            if (self.quiescentNow()) break;
        }
        if (try self.applyHeadless(arena, self.install.path, m.version)) |e| return try self.gpa.dupe(u8, e);
        self.lock();
        self.phase = .restarting;
        self.requested = false;
        self.unlock();
        self.restarter.restart_fn(self.restarter.ctx, self.install.path);
        return null;
    }
};

const libproc = if (builtin.os.tag == .macos) struct {
    const all_pids: u32 = 1;
    const path_max = 4096;
    extern "c" fn proc_listpids(kind: u32, typeinfo: u32, buffer: ?*anyopaque, buffersize: c_int) c_int;
    extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
} else struct {};

/// `Processes` from the kernel. `proc_pidpath` follows a running executable
/// through renames (`ps` prints the path it was launched with). A process that
/// ended meanwhile, or whose executable is already gone from disk, runs from
/// no bundle that is still there; any other failure means "couldn't tell".
fn runningExecutables(_: ?*anyopaque, arena: Allocator) Allocator.Error!?[]const []const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    const need = libproc.proc_listpids(libproc.all_pids, 0, null, 0);
    if (need <= 0) return null;
    // Room for processes that start between the two calls; a list that fills it may be cut short.
    const pids = try arena.alloc(c_int, @as(usize, @intCast(need)) / @sizeOf(c_int) + 256);
    const size: c_int = @intCast(pids.len * @sizeOf(c_int));
    const got = libproc.proc_listpids(libproc.all_pids, 0, pids.ptr, size);
    if (got <= 0 or got >= size) return null;
    var paths: std.ArrayList([]const u8) = .empty;
    for (pids[0 .. @as(usize, @intCast(got)) / @sizeOf(c_int)]) |pid| {
        if (pid <= 0) continue;
        var buf: [libproc.path_max]u8 = undefined;
        const n = libproc.proc_pidpath(pid, &buf, buf.len);
        if (n > 0) {
            try paths.append(arena, try arena.dupe(u8, buf[0..@intCast(n)]));
        } else switch (std.c.errno(@as(c_int, -1))) {
            .SRCH, .NOENT => {},
            else => return null,
        }
    }
    return paths.items;
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------- RPCs

pub const Reply = union(enum) { ok: []u8, failed: []const u8, bad_params: []const u8 };
pub const Method = enum { status, check, queue, apply };

threadlocal var target_err_buf: [256]u8 = undefined;

/// `targetDeviceId` names another device. The Rust engine forwards the call
/// over its device relay; this engine has no relay client yet, so it answers
/// as the Rust engine does when no relay link is available (`forward`).
pub fn targetProblem(params: json.Value, local_device: []const u8) ?[]const u8 {
    if (params != .object) return null;
    const t = params.object.get("targetDeviceId") orelse return null;
    if (t != .string) return "invalid type for `targetDeviceId`, expected a string";
    if (std.mem.eql(u8, t.string, local_device)) return null;
    return std.fmt.bufPrint(&target_err_buf, "cannot reach device {s}: remote routing unavailable (offline)", .{t.string}) catch
        "cannot reach device: remote routing unavailable (offline)";
}

pub fn handle(u: *Updater, reply_gpa: Allocator, method: Method) !Reply {
    switch (method) {
        .status => return .{ .ok = try u.statusJson(reply_gpa) },
        .check => {
            u.checkNow();
            return .{ .ok = try reply_gpa.dupe(u8, "{\"ok\":true}") };
        },
        .queue => {
            if (u.queueUpdate()) |e| return .{ .failed = e };
            return .{ .ok = try reply_gpa.dupe(u8, "{\"ok\":true,\"queued\":true}") };
        },
        .apply => switch (try u.apply(reply_gpa)) {
            .err => |e| return .{ .failed = e },
            .version => |v| {
                defer reply_gpa.free(v);
                return .{ .ok = try std.fmt.allocPrint(reply_gpa, "{{\"ok\":true,\"version\":{f}}}", .{json.fmt(v, .{})}) };
            },
        },
    }
}

// ---------------------------------------------------------------- the engine's wiring

/// The engine's updater, for one host at a time: set up by `forEngine`,
/// dropped by `releaseHost` when that host goes away.
const Engine = struct {
    updater: Updater,
    /// The host's I/O; null for a host without one (then nothing runs).
    io: ?std.Io,
    sys_runner: ?proc.SystemRunner,
    host: *anyopaque,
    started: bool = false,
};

var engine_state: ?Engine = null;

/// How long a release download may go without a byte before it fails (the
/// Rust updater's read timeout: an inactivity deadline, not a total cap).
pub const read_idle_ms: u32 = 30_000;
pub const max_redirects: u8 = 10;

/// `null` when following a redirect to `next` is fine, else why not: never
/// from HTTPS to plain HTTP, and at most `max_redirects` hops.
pub fn redirectProblem(seen_https: bool, hops: usize, next: []const u8) ?[]const u8 {
    if (hops >= max_redirects) return "too many update redirects";
    const uri = std.Uri.parse(next) catch return "invalid update redirect";
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return "invalid update redirect";
    return if (seen_https) "update redirect would downgrade HTTPS" else null;
}

fn downloadErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.Timeout => "no data for 30 s",
        error.TooLarge => "the file is larger than this engine downloads",
        error.RedirectDowngrade => "update redirect would downgrade HTTPS",
        error.TooManyRedirects => "too many update redirects",
        error.InvalidRedirect => "invalid update redirect",
        else => @errorName(e),
    };
}

/// Fails a stalled transfer: a helper thread watches a progress counter and,
/// when it hasn't moved for `idle_ms`, shuts the socket down.
const IdleWatchdog = struct {
    io: std.Io,
    handle: std.Io.net.Socket.Handle,
    idle_ms: u32,
    progress: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn arm(self: *IdleWatchdog) void {
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    fn run(self: *IdleWatchdog) void {
        var seen = self.progress.load(.acquire);
        var still_ms: u32 = 0;
        while (!self.done.load(.acquire)) {
            std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return;
            const now = self.progress.load(.acquire);
            if (now != seen) {
                seen = now;
                still_ms = 0;
                continue;
            }
            still_ms += 20;
            if (still_ms >= self.idle_ms) {
                self.fired.store(true, .release);
                @import("auth_host.zig").shutdownSocket(self.handle);
                return;
            }
        }
    }

    fn tick(self: *IdleWatchdog) void {
        _ = self.progress.fetchAdd(1, .acq_rel);
    }

    /// True when the deadline had passed.
    fn disarm(self: *IdleWatchdog) bool {
        self.done.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        return self.fired.load(.acquire);
    }
};

pub const FetchLimits = struct { idle_ms: u32 = read_idle_ms, max_bytes: u64 };

/// GET `url` into `sink`, following redirects (`redirectProblem`), with an
/// inactivity deadline and a byte cap; the body's SHA-256 goes to `hash`.
pub fn fetchInto(gpa: Allocator, io: std.Io, url: []const u8, limits: FetchLimits, sink: *std.Io.Writer, hash: *std.crypto.hash.sha2.Sha256) !Download {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var current = try gpa.dupe(u8, url);
    defer gpa.free(current);
    var seen_https = false;
    var hops: usize = 0;
    while (true) {
        const uri = std.Uri.parse(current) catch return error.InvalidRedirect;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) seen_https = true;
        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{ .user_agent = .{ .override = "harness-engine-zig" } },
        });
        defer req.deinit();
        var dog: IdleWatchdog = .{ .io = io, .handle = req.connection.?.stream_reader.stream.socket.handle, .idle_ms = limits.idle_ms };
        dog.arm();
        const step = fetchStep(gpa, &req, limits, sink, hash, &dog);
        const fired = dog.disarm();
        if (fired) return error.Timeout;
        switch (try step) {
            .done => |d| return d,
            .redirect => |next| {
                defer gpa.free(next);
                if (redirectProblem(seen_https, hops, next)) |why| {
                    return if (std.mem.eql(u8, why, "update redirect would downgrade HTTPS"))
                        error.RedirectDowngrade
                    else if (std.mem.eql(u8, why, "too many update redirects")) error.TooManyRedirects else error.InvalidRedirect;
                }
                hops += 1;
                gpa.free(current);
                current = try gpa.dupe(u8, next);
            },
        }
    }
}

const Step = union(enum) { done: Download, redirect: []u8 };

fn fetchStep(gpa: Allocator, req: *std.http.Client.Request, limits: FetchLimits, sink: *std.Io.Writer, hash: *std.crypto.hash.sha2.Sha256, dog: *IdleWatchdog) !Step {
    try req.sendBodiless();
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    dog.tick();
    const status: u16 = @backingInt(response.head.status);
    if (status >= 300 and status < 400) {
        if (response.head.location) |loc| return .{ .redirect = try absoluteLocation(gpa, req.uri, loc) };
    }
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    var buf: [64 * 1024]u8 = undefined;
    var size: u64 = 0;
    while (true) {
        const n = reader.readSliceShort(&buf) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        };
        if (n > 0) {
            size += n;
            if (size > limits.max_bytes) return error.TooLarge;
            hash.update(buf[0..n]);
            try sink.writeAll(buf[0..n]);
            dog.tick();
        }
        if (n < buf.len) break;
    }
    try sink.flush();
    var out: Download = .{ .status = status, .sha256 = undefined, .size = size };
    hash.final(&out.sha256);
    return .{ .done = out };
}

/// A `Location` as an absolute URL: absolute ones as they are, `/path` on the same origin.
fn absoluteLocation(gpa: Allocator, base: std.Uri, loc: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, loc, "://") != null) return gpa.dupe(u8, loc);
    if (!std.mem.startsWith(u8, loc, "/")) return error.InvalidRedirect;
    const host = switch (base.host orelse return error.InvalidRedirect) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    };
    if (base.port) |port| return std.fmt.allocPrint(gpa, "{s}://{s}:{d}{s}", .{ base.scheme, host, port, loc });
    return std.fmt.allocPrint(gpa, "{s}://{s}{s}", .{ base.scheme, host, loc });
}

fn engineIo(ctx: ?*anyopaque) std.Io {
    const io: *std.Io = @ptrCast(@alignCast(ctx.?));
    return io.*;
}

fn stdGet(ctx: ?*anyopaque, gpa: Allocator, url: []const u8) anyerror!HttpReply {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const got = try fetchInto(gpa, engineIo(ctx), url, .{ .max_bytes = max_manifest_bytes }, &aw.writer, &hash);
    return .{ .status = got.status, .body = try aw.toOwnedSlice() };
}

/// Streams the body to a new file at `dest` (never held in memory).
pub fn stdDownload(ctx: ?*anyopaque, gpa: Allocator, io: std.Io, url: []const u8, dest: []const u8, max_bytes: u64) anyerror!Download {
    _ = ctx;
    return downloadTo(gpa, io, url, dest, .{ .max_bytes = max_bytes });
}

pub fn downloadTo(gpa: Allocator, io: std.Io, url: []const u8, dest: []const u8, limits: FetchLimits) !Download {
    const file = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer file.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    return fetchInto(gpa, io, url, limits, &fw.interface, &hash);
}

/// `harness-engine update` (`update_cli.rs`): check the release feed and
/// install a newer release for this install: swap the app bundle (macOS app),
/// or stage and repoint `current` (managed). Prints Rust's lines, which the
/// app's update view reads ("is up to date", "relaunch Harness to finish").
/// Exit code: 0 done or up to date, 1 failed.
pub fn updateCommand(u: *Updater, arena: Allocator, data_dir: ?[]const u8, out: *std.Io.Writer, err_w: *std.Io.Writer) !u8 {
    return updateCommandOpts(u, arena, data_dir, false, out, err_w);
}

pub fn updateCommandOpts(u: *Updater, arena: Allocator, data_dir: ?[]const u8, check_only: bool, out: *std.Io.Writer, err_w: *std.Io.Writer) !u8 {
    const m = switch (try u.fetchLatest(arena)) {
        .ok => |m| m,
        .err => |e| {
            try err_w.print("error: {s}\n", .{e});
            return 1;
        },
    };
    if (!versionNewer(m.version, u.current_version)) {
        try out.print("Harness {s} is up to date (latest: {s}).\n", .{ u.current_version, m.version });
        return 0;
    }
    try out.print("Harness {s} \u{2192} {s} available\n", .{ u.current_version, m.version });
    if (check_only) return 1;
    switch (u.install.kind) {
        .mac_app => {
            try out.print("downloading {s}\u{2026}\n", .{try macAppArtifactAlloc(arena, m.version)});
            try out.flush();
            const dir = data_dir orelse {
                try err_w.writeAll("error: no data folder to stage the update in\n");
                return 1;
            };
            const staged = switch (try u.stageMacApp(arena, m, dir)) {
                .ok => |p| p,
                .err => |e| {
                    try err_w.print("error: {s}\n", .{e});
                    return 1;
                },
            };
            if (try u.applyMacApp(arena, staged, u.install.path)) |e| {
                try err_w.print("error: {s}\n", .{e});
                return 1;
            }
            try out.print("updated {s} \u{2014} relaunch Harness to finish.\n", .{u.install.path});
        },
        .managed => {
            try out.print("downloading {s}\u{2026}\n", .{try headlessArtifactAlloc(arena, m.version)});
            try out.flush();
            if (try u.stageHeadless(arena, m, u.install.path)) |e| {
                try err_w.print("error: {s}\n", .{e});
                return 1;
            }
            if (try u.applyHeadless(arena, u.install.path, m.version)) |e| {
                try err_w.print("error: {s}\n", .{e});
                return 1;
            }
            try out.print("installed {s}/{s} (current \u{2192} {s})\n", .{ u.install.path, m.version, m.version });
            try out.writeAll("note: restart the engine to finish (harness-engine daemon restart).\n");
        },
        .unmanaged => {
            try err_w.writeAll("error: this binary is not update-managed (source build or hand-copied).\n");
            return 1;
        },
    }
    return 0;
}

/// `updateCommand` for this process's own install: install detection from
/// the executable's path, the release feed from `edge_url` (or
/// `HARNESS_RELEASES_URL`), real downloads and processes.
pub fn runUpdateCommand(gpa: Allocator, io: std.Io, edge_url: []const u8, data_dir: ?[]const u8, out: *std.Io.Writer, err_w: *std.Io.Writer) !u8 {
    return runUpdateCli(gpa, io, edge_url, data_dir, false, out, err_w);
}

pub fn runUpdateCli(gpa: Allocator, io: std.Io, edge_url: []const u8, data_dir: ?[]const u8, check_only: bool, out: *std.Io.Writer, err_w: *std.Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var install: Install = .{ .kind = .unmanaged };
    var exe_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    if (std.process.executablePath(io, &exe_buf)) |n| {
        const found = detectInstallFrom(exe_buf[0..n], proc.getenv("HOME"), builtin.os.tag, &root_buf, io, isDevBundleAt);
        install = .{ .kind = found.kind, .path = try arena.dupe(u8, found.path) };
    } else |_| {}
    var override: ?[]const u8 = null;
    if (proc.getenv("HARNESS_RELEASES_URL")) |raw| if (std.mem.trim(u8, raw, " \t\r\n").len > 0) {
        switch (validateReleaseOverride(arena, raw)) {
            .ok => |o| override = o,
            .err => |e| {
                try err_w.print("error: HARNESS_RELEASES_URL: {s}\n", .{e});
                return 1;
            },
        }
    };
    var io_slot = io;
    var sys: proc.SystemRunner = .{ .io = io };
    var u: Updater = .{
        .gpa = gpa,
        .io = io,
        .install = install,
        .automatic = false,
        .edge_url = edge_url,
        .current_version = @import("build_info").version,
        .releases_override = override,
        .http = .{ .ctx = &io_slot, .get_fn = stdGet, .download_fn = stdDownload },
        .runner = sys.runner(),
        .restarter = .{ .restart_fn = noRestart },
    };
    defer u.deinit();
    return updateCommandOpts(&u, arena, data_dir, check_only, out, err_w);
}

fn restartService(io: std.Io) bool {
    var sys: proc.SystemRunner = .{ .io = io };
    const gpa = std.heap.smp_allocator;
    if (builtin.os.tag == .macos) {
        var id = sys.runner().run(gpa, .{ .argv = &.{ "id", "-u" }, .timeout_ms = 10_000 }) catch return false;
        defer id.deinit(gpa);
        const target = std.fmt.allocPrint(gpa, "gui/{s}/" ++ launchd_label, .{std.mem.trim(u8, id.stdout, " \t\r\n")}) catch return false;
        defer gpa.free(target);
        var out = sys.runner().run(gpa, .{ .argv = &.{ "launchctl", "kickstart", "-k", target }, .timeout_ms = 30_000 }) catch return false;
        defer out.deinit(gpa);
        return out.ok();
    }
    var out = sys.runner().run(gpa, .{ .argv = &.{ "systemctl", "--user", "restart", "harness.service" }, .timeout_ms = 30_000 }) catch return false;
    defer out.deinit(gpa);
    return out.ok();
}

/// Long-lived update daemon for the Rust engine (`harness update-daemon`).
/// Reads JSON command lines on stdin and emits `{"status":...}`, `{"reply":...}`,
/// and `{"reexec":"..."}` JSON lines on stdout.
pub fn runUpdateDaemon(gpa: Allocator, io: std.Io, edge_url: []const u8) !void {
    const DaemonCtx = struct {
        gpa: Allocator,
        io: std.Io,
        updater: Updater,
        io_slot: std.Io,
        sys_runner: proc.SystemRunner,
        quiescent: std.atomic.Value(bool) = .init(true),
        stop_flag: std.atomic.Value(bool) = .init(false),
        out_lock: std.Io.Mutex = .init,
        out_buf: [65536]u8 = undefined,
        out_writer: std.Io.File.Writer = undefined,
        last_status: []u8 = &.{},

        fn isQuiescent(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.quiescent.load(.acquire);
        }

        fn onRestart(ctx: ?*anyopaque, app_root: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const root_copy = self.gpa.dupe(u8, app_root) catch return;
            const th = std.Thread.spawn(.{}, emitReexecLater, .{ self, root_copy }) catch {
                self.gpa.free(root_copy);
                return;
            };
            th.detach();
        }

        fn emitReexecLater(self: *@This(), app_root: []u8) void {
            defer self.gpa.free(app_root);
            std.Io.sleep(self.io, .fromMilliseconds(800), .awake) catch return;
            if (self.stop_flag.load(.acquire)) return;
            if (supervisedBy(proc.getenv("INVOCATION_ID"), proc.getenv("XPC_SERVICE_NAME"))) {
                if (restartService(self.io)) return;
            }
            const exe = std.fmt.allocPrint(self.gpa, "{s}/current/" ++ engine_bin, .{app_root}) catch return;
            defer self.gpa.free(exe);
            self.out_lock.lockUncancelable(self.io);
            defer self.out_lock.unlock(self.io);
            self.out_writer.interface.print("{{\"reexec\":{f}}}\n", .{json.fmt(exe, .{})}) catch {};
            self.out_writer.interface.flush() catch {};
        }

        fn emitStatusIfChanged(self: *@This()) void {
            const st = self.updater.statusJson(self.gpa) catch return;
            self.out_lock.lockUncancelable(self.io);
            defer self.out_lock.unlock(self.io);
            if (std.mem.eql(u8, st, self.last_status)) {
                self.gpa.free(st);
                return;
            }
            if (self.last_status.len > 0) self.gpa.free(self.last_status);
            self.last_status = st;
            self.out_writer.interface.print("{{\"status\":{s}}}\n", .{st}) catch {};
            self.out_writer.interface.flush() catch {};
        }

        fn emitReplyOk(self: *@This(), id: i64, version: ?[]const u8) void {
            self.out_lock.lockUncancelable(self.io);
            defer self.out_lock.unlock(self.io);
            if (version) |v| {
                self.out_writer.interface.print("{{\"reply\":{d},\"ok\":true,\"version\":{f}}}\n", .{ id, json.fmt(v, .{}) }) catch {};
            } else {
                self.out_writer.interface.print("{{\"reply\":{d},\"ok\":true}}\n", .{id}) catch {};
            }
            self.out_writer.interface.flush() catch {};
        }

        fn emitReplyErr(self: *@This(), id: i64, err_msg: []const u8) void {
            self.out_lock.lockUncancelable(self.io);
            defer self.out_lock.unlock(self.io);
            self.out_writer.interface.print("{{\"reply\":{d},\"err\":{f}}}\n", .{ id, json.fmt(err_msg, .{}) }) catch {};
            self.out_writer.interface.flush() catch {};
        }

        fn nowMs(self: *const @This()) i64 {
            return @intCast(std.Io.Clock.real.now(self.io).toMilliseconds());
        }

        fn sleepUntil(self: *@This(), ms: i64, wake_on_check: bool) bool {
            self.updater.lock();
            const seq = self.updater.wake_seq;
            self.updater.unlock();
            var waited: i64 = 0;
            while (waited < ms) : (waited += 100) {
                if (self.stop_flag.load(.acquire)) return false;
                std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch return false;
                if (self.stop_flag.load(.acquire)) return false;
                if (wake_on_check) {
                    self.updater.lock();
                    const now_seq = self.updater.wake_seq;
                    self.updater.unlock();
                    if (now_seq != seq) return true;
                }
            }
            return !self.stop_flag.load(.acquire);
        }

        fn checkLoop(self: *@This()) void {
            const DaemonCtx = @This();
            const Sleeper = struct {
                d: *DaemonCtx,
                pub fn sleep(s: @This(), ms: i64) bool {
                    return s.d.sleepUntil(ms, false);
                }
            };
            if (!self.sleepUntil(check_initial_delay_ms, true)) return;
            var failures: u32 = 0;
            while (!self.stop_flag.load(.acquire)) {
                var ok = self.updater.checkOnce(self.nowMs()) catch false;
                self.emitStatusIfChanged();
                self.updater.lock();
                const go = ok and self.updater.available and (self.updater.automatic or self.updater.requested) and self.updater.install.kind == .managed;
                if (ok and !go) self.updater.requested = false;
                self.updater.unlock();
                if (go) {
                    if (self.updater.autoApplyWhenIdle(Sleeper{ .d = self }) catch null) |msg| {
                        self.updater.failWith(msg);
                        ok = false;
                    }
                    self.emitStatusIfChanged();
                }
                failures = if (ok) 0 else failures +| 1;
                const due = self.nowMs() + nextCheckDelayMs(ok, failures);
                self.updater.lock();
                const seq = self.updater.wake_seq;
                self.updater.unlock();
                while (!self.stop_flag.load(.acquire)) {
                    std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch return;
                    if (self.stop_flag.load(.acquire)) return;
                    if (checkDue(self.nowMs(), due)) break;
                    self.updater.lock();
                    const now_seq = self.updater.wake_seq;
                    self.updater.unlock();
                    if (now_seq != seq) break;
                }
            }
        }
    };

    var install: Install = .{ .kind = .unmanaged };
    var exe_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    if (std.process.executablePath(io, &exe_buf)) |n| {
        const found = detectInstallFrom(exe_buf[0..n], proc.getenv("HOME"), builtin.os.tag, &root_buf, io, isDevBundleAt);
        install = .{ .kind = found.kind, .path = try gpa.dupe(u8, found.path) };
    } else |_| {}
    defer if (install.path.len > 0) gpa.free(install.path);

    var override: ?[]u8 = null;
    if (proc.getenv("HARNESS_RELEASES_URL")) |raw| if (std.mem.trim(u8, raw, " \t\r\n").len > 0) {
        switch (validateReleaseOverride(gpa, raw)) {
            .ok => |o| override = o,
            .err => {},
        }
    };
    defer if (override) |o| gpa.free(o);

    const ctx = try gpa.create(DaemonCtx);
    defer {
        ctx.updater.deinit();
        if (ctx.last_status.len > 0) gpa.free(ctx.last_status);
        gpa.destroy(ctx);
    }
    ctx.* = .{
        .gpa = gpa,
        .io = io,
        .io_slot = io,
        .sys_runner = .{ .io = io },
        .updater = .{
            .gpa = gpa,
            .io = io,
            .install = install,
            .automatic = autoUpdateFrom(proc.getenv("HARNESS_AUTO_UPDATE")),
            .edge_url = edge_url,
            .current_version = @import("build_info").version,
            .releases_override = override,
            .http = .{ .ctx = null, .get_fn = stdGet, .download_fn = stdDownload },
            .runner = .{ .run_fn = noSpawn },
            .restarter = .{ .restart_fn = DaemonCtx.onRestart },
            .quiescent_fn = DaemonCtx.isQuiescent,
        },
    };
    ctx.out_writer = std.Io.File.stdout().writerStreaming(io, &ctx.out_buf);
    ctx.updater.http.ctx = &ctx.io_slot;
    ctx.updater.runner = ctx.sys_runner.runner();
    ctx.updater.quiescent_ctx = ctx;
    ctx.updater.restarter.ctx = ctx;

    ctx.emitStatusIfChanged();

    const should_run = install.checksReleases() or override != null or edge_url.len > 0;
    const check_thread = if (should_run) try std.Thread.spawn(.{}, DaemonCtx.checkLoop, .{ctx}) else null;
    defer {
        ctx.stop_flag.store(true, .release);
        ctx.updater.lock();
        ctx.updater.shutting_down = true;
        ctx.updater.wake_seq +%= 1;
        ctx.updater.unlock();
        if (check_thread) |th| th.join();
    }

    var rbuf: [16384]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &rbuf);
    var line_buf: std.Io.Writer.Allocating = .init(gpa);
    defer line_buf.deinit();
    while (true) {
        line_buf.clearRetainingCapacity();
        _ = reader.interface.streamDelimiter(&line_buf.writer, '\n') catch break;
        _ = reader.interface.takeByte() catch {};
        const raw = std.mem.trim(u8, line_buf.written(), " \t\r");
        if (raw.len == 0) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const parsed = json.parseFromSliceLeaky(json.Value, arena_state.allocator(), raw, .{}) catch continue;
        if (parsed != .object) continue;
        const op_val = parsed.object.get("op") orelse continue;
        if (op_val != .string) continue;
        const op = op_val.string;
        if (std.mem.eql(u8, op, "check")) {
            ctx.updater.checkNow();
        } else if (std.mem.eql(u8, op, "quiescent")) {
            if (parsed.object.get("value")) |v| if (v == .bool) {
                ctx.quiescent.store(v.bool, .release);
            };
        } else if (std.mem.eql(u8, op, "queue")) {
            const id: i64 = if (parsed.object.get("id")) |iv| (if (iv == .integer) iv.integer else 0) else 0;
            if (ctx.updater.queueUpdate()) |e| {
                ctx.emitReplyErr(id, e);
            } else {
                ctx.emitReplyOk(id, null);
                ctx.emitStatusIfChanged();
            }
        } else if (std.mem.eql(u8, op, "apply")) {
            const id: i64 = if (parsed.object.get("id")) |iv| (if (iv == .integer) iv.integer else 0) else 0;
            switch (ctx.updater.apply(arena_state.allocator()) catch |e| Updater.ApplyResult{ .err = @errorName(e) }) {
                .version => |v| {
                    ctx.emitReplyOk(id, v);
                    ctx.emitStatusIfChanged();
                },
                .err => |e| ctx.emitReplyErr(id, e),
            }
        }
    }
}

fn noRestart(_: ?*anyopaque, _: []const u8) void {}

/// The engine's updater for `host` (an `*EngineHost`), started once: the
/// release check thread runs for managed and app installs. Another host's
/// updater is replaced (its check thread, if any, must have ended).
pub fn forEngine(comptime Host: type, host: *Host) !*Updater {
    if (engine_state) |*e| {
        if (e.host == @as(*anyopaque, host)) return &e.updater;
        if (e.started) return error.UpdaterInUse;
        freeState();
    }
    const gpa = std.heap.smp_allocator;
    var install: Install = .{ .kind = .unmanaged };
    var exe_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    if (host.io) |io| {
        if (std.process.executablePath(io, &exe_buf)) |n| {
            const found = detectInstallFrom(exe_buf[0..n], proc.getenv("HOME"), builtin.os.tag, &root_buf, io, isDevBundleAt);
            install = .{ .kind = found.kind, .path = try gpa.dupe(u8, found.path) };
        } else |_| {}
    }
    var override: ?[]const u8 = null;
    if (proc.getenv("HARNESS_RELEASES_URL")) |raw| if (std.mem.trim(u8, raw, " \t\r\n").len > 0) {
        switch (validateReleaseOverride(gpa, raw)) {
            .ok => |o| override = o,
            .err => {},
        }
    };
    engine_state = .{
        .host = host,
        .io = host.io,
        .sys_runner = if (host.io) |io| .{ .io = io } else null,
        .updater = .{
            .gpa = gpa,
            .io = host.io,
            .install = install,
            .automatic = autoUpdateFrom(proc.getenv("HARNESS_AUTO_UPDATE")),
            .edge_url = try gpa.dupe(u8, host.auth.edge_url orelse ""),
            .current_version = @import("build_info").version,
            .releases_override = override,
            .http = .{ .get_fn = stdGet, .download_fn = stdDownload },
            .runner = .{ .run_fn = noSpawn },
            .restarter = .{ .restart_fn = Wiring(Host).restart },
            .quiescent_fn = Wiring(Host).quiescent,
        },
    };
    const e = &engine_state.?;
    e.updater.quiescent_ctx = host;
    e.updater.restarter.ctx = host;
    if (e.io != null) {
        e.updater.http.ctx = &e.io.?;
        e.updater.runner = e.sys_runner.?.runner();
    } else {
        // No I/O, no network: a check fails instead of reading an unset `Io`.
        e.updater.http = .{ .get_fn = noNetwork };
    }
    if (host.io != null and install.checksReleases()) {
        _ = host.bg_workers_active.fetchAdd(1, .acq_rel);
        if (std.Thread.spawn(.{}, Wiring(Host).loop, .{host})) |th| {
            th.detach();
            e.started = true;
        } else |_| {
            _ = host.bg_workers_active.fetchSub(1, .acq_rel);
        }
    }
    return &e.updater;
}

fn noNetwork(_: ?*anyopaque, _: Allocator, _: []const u8) anyerror!HttpReply {
    return error.NoNetworkIo;
}

fn freeState() void {
    if (engine_state) |*e| {
        e.updater.deinit();
        if (e.updater.install.path.len > 0) std.heap.smp_allocator.free(e.updater.install.path);
        std.heap.smp_allocator.free(e.updater.edge_url);
        if (e.updater.releases_override) |o| std.heap.smp_allocator.free(o);
    }
    engine_state = null;
}

/// `host` is going away (its background workers have ended): forget its
/// updater, so nothing keeps a pointer to it.
pub fn releaseHost(host: *anyopaque) void {
    const e = engine_state orelse return;
    if (e.host != host) return;
    freeState();
}

/// Whether the engine's updater is set up (the engine does it at start-up).
pub fn configured() bool {
    return engine_state != null;
}

/// The host the engine's updater reports to, if set up.
pub fn configuredHost() ?*anyopaque {
    return if (engine_state) |e| e.host else null;
}

/// Push the current `UpdateStatus` item to every subscriber of `host`.
pub fn publishStatus(comptime Host: type, host: *Host) void {
    Wiring(Host).publish(host);
}

/// Tests: forget the engine's updater (only when no check thread runs).
pub fn resetForTests() void {
    if (engine_state) |e| if (e.started) return;
    freeState();
}

fn noSpawn(_: ?*anyopaque, gpa: Allocator, _: proc.Request) Allocator.Error!proc.Output {
    return .{ .term = .spawn_failed, .stdout = try gpa.dupe(u8, ""), .stderr = try gpa.dupe(u8, "") };
}

fn isDevBundleAt(io: std.Io, bundle: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/Contents/Info.plist", .{bundle}) catch return false;
    var tbuf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tbuf);
    const text = std.Io.Dir.cwd().readFileAlloc(io, p, fba.allocator(), .limited(tbuf.len - 1)) catch return false;
    const id = plistBundleId(text) orelse return false;
    return std.mem.endsWith(u8, id, ".dev");
}

fn Wiring(comptime Host: type) type {
    return struct {
        fn stopped(host: *Host) bool {
            const io = host.io.?;
            host.mutex.lockUncancelable(io);
            defer host.mutex.unlock(io);
            return host.stop_requested;
        }

        fn quiescent(ctx: ?*anyopaque) bool {
            const host: *Host = @ptrCast(@alignCast(ctx.?));
            const io = host.io orelse return true;
            host.mutex.lockUncancelable(io);
            defer host.mutex.unlock(io);
            var docs = host.docs.iterator();
            while (docs.next()) |e| if (e.value_ptr.hasActiveWork()) return false;
            var terms = host.terminals.sessions.iterator();
            while (terms.next()) |t| if (!t.value_ptr.exited) return false;
            return true;
        }

        fn publish(host: *Host) void {
            const u = &engine_state.?.updater;
            const body = u.statusJson(host.gpa) catch return;
            defer host.gpa.free(body);
            const io = host.io.?;
            host.mutex.lockUncancelable(io);
            defer host.mutex.unlock(io);
            host.broadcastWatch(.update_status, null, body) catch {};
        }

        const Sleeper = struct {
            host: *Host,
            /// Sleep up to `ms`, waking early on `CheckForUpdates`; false once the engine stops.
            pub fn sleep(self: @This(), ms: i64) bool {
                return sleepUntil(self.host, ms, false);
            }
        };

        fn sleepUntil(host: *Host, ms: i64, wake_on_check: bool) bool {
            const u = &engine_state.?.updater;
            const io = host.io.?;
            u.lock();
            const seq = u.wake_seq;
            u.unlock();
            var waited: i64 = 0;
            while (waited < ms) : (waited += 250) {
                std.Io.sleep(io, .fromMilliseconds(250), .awake) catch return false;
                if (stopped(host)) return false;
                if (wake_on_check) {
                    u.lock();
                    const now_seq = u.wake_seq;
                    u.unlock();
                    if (now_seq != seq) return true;
                }
            }
            return true;
        }

        fn loop(host: *Host) void {
            defer _ = host.bg_workers_active.fetchSub(1, .acq_rel);
            const u = &engine_state.?.updater;
            if (!sleepUntil(host, check_initial_delay_ms, true)) return;
            var failures: u32 = 0;
            while (!stopped(host)) {
                var ok = u.checkOnce(host.nowMs()) catch false;
                publish(host);
                u.lock();
                const go = ok and u.available and (u.automatic or u.requested) and u.install.kind == .managed;
                if (ok and !go) u.requested = false;
                u.unlock();
                if (go) {
                    if (u.autoApplyWhenIdle(Sleeper{ .host = host }) catch null) |msg| {
                        u.failWith(msg);
                        ok = false;
                    }
                    publish(host);
                }
                failures = if (ok) 0 else failures +| 1;
                const due = host.nowMs() + nextCheckDelayMs(ok, failures);
                u.lock();
                const seq = u.wake_seq;
                u.unlock();
                while (true) {
                    std.Io.sleep(host.io.?, .fromMilliseconds(250), .awake) catch return;
                    if (stopped(host)) return;
                    if (checkDue(host.nowMs(), due)) break;
                    u.lock();
                    const now_seq = u.wake_seq;
                    u.unlock();
                    if (now_seq != seq) break;
                }
            }
        }

        /// After a short delay (the RPC reply flushes): restart the service, else re-exec.
        fn restart(ctx: ?*anyopaque, app_root: []const u8) void {
            const host: *Host = @ptrCast(@alignCast(ctx.?));
            const root = std.heap.smp_allocator.dupe(u8, app_root) catch return;
            const th = std.Thread.spawn(.{}, restartLater, .{ host, root }) catch {
                std.heap.smp_allocator.free(root);
                return;
            };
            th.detach();
        }

        fn restartLater(host: *Host, app_root: []u8) void {
            defer std.heap.smp_allocator.free(app_root);
            const io = host.io orelse return;
            std.Io.sleep(io, .fromMilliseconds(800), .awake) catch return;
            if (supervisedBy(proc.getenv("INVOCATION_ID"), proc.getenv("XPC_SERVICE_NAME"))) {
                if (restartService(io)) return;
            }
            reexec(host, io, app_root);
        }

        /// Replace this process with `app_root/current/harness-engine`, same arguments.
        fn reexec(host: *Host, io: std.Io, app_root: []const u8) void {
            {
                host.mutex.lockUncancelable(io);
                defer host.mutex.unlock(io);
                host.stop_requested = true;
            }
            const gpa = std.heap.smp_allocator;
            var argv: std.ArrayList([]const u8) = .empty;
            const exe = std.fmt.allocPrint(gpa, "{s}/current/" ++ engine_bin, .{app_root}) catch return;
            argv.append(gpa, exe) catch return;
            ownArgs(gpa, &argv);
            std.Io.sleep(io, .fromMilliseconds(400), .awake) catch {};
            const failed = std.process.replace(io, .{ .argv = argv.items });
            std.log.err("harness-engine: restarting into the updated release failed: {t}", .{failed});
        }

        fn ownArgs(gpa: Allocator, argv: *std.ArrayList([]const u8)) void {
            if (builtin.os.tag == .macos) {
                const C = struct {
                    extern "c" fn _NSGetArgc() *c_int;
                    extern "c" fn _NSGetArgv() *[*][*:0]u8;
                };
                const argc: usize = @intCast(C._NSGetArgc().*);
                const raw = C._NSGetArgv().*;
                var i: usize = 1;
                while (i < argc) : (i += 1) argv.append(gpa, std.mem.span(raw[i])) catch return;
            } else if (builtin.os.tag == .linux) {
                const io = (engine_state orelse return).io orelse return;
                const text = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/cmdline", gpa, .limited(1 << 20)) catch return;
                var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\x00"), 0);
                _ = it.next();
                while (it.next()) |a| argv.append(gpa, a) catch return;
            }
        }
    };
}

pub fn toOutcome(comptime Outcome: type, r: Reply) Outcome {
    return switch (r) {
        .ok => |body| .{ .unary_json = body },
        .bad_params => |m| .{ .err = .{ .bad_params = m } },
        .failed => |m| .{ .err = .{ .exec_error = m } },
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "updates: versions compare numerically and garbage never counts as newer" {
    try testing.expect(versionNewer("0.1.10", "0.1.9"));
    try testing.expect(versionNewer("v0.2.0", "0.1.99"));
    try testing.expect(versionNewer("0.1.1", "0.1"));
    try testing.expect(!versionNewer("0.1.9", "0.1.10"));
    try testing.expect(!versionNewer("0.1.9", "0.1.9"));
    try testing.expect(!versionNewer("garbage", "0.1.0"));
    try testing.expect(!versionNewer("", "0.1.0"));
}

test "updates: auto-update and supervision switches" {
    try testing.expect(autoUpdateFrom(null));
    try testing.expect(autoUpdateFrom("1"));
    try testing.expect(!autoUpdateFrom(" OFF "));
    try testing.expect(!autoUpdateFrom("no"));
    try testing.expect(supervisedBy("abc", null));
    try testing.expect(supervisedBy(null, launchd_label));
    try testing.expect(!supervisedBy("", "other"));
    try testing.expectEqual(check_interval_ms, nextCheckDelayMs(true, 0));
    try testing.expectEqual(@as(i64, 60_000), nextCheckDelayMs(false, 1));
    try testing.expectEqual(@as(i64, 30 * 60_000), nextCheckDelayMs(false, 9));
    try testing.expect(checkDue(10, 5));
    try testing.expect(!checkDue(10, 20));
    try testing.expect(checkDue(10, 10 + check_interval_ms + 1));
}

const NotDev = struct {
    fn f(_: void, _: []const u8) bool {
        return false;
    }
    fn dev(_: void, _: []const u8) bool {
        return true;
    }
};

test "updates: install detection" {
    var buf: [256]u8 = undefined;
    const managed = detectInstallFrom("/home/u/.harness/app/0.2.1/harness", "/home/u", .linux, &buf, {}, NotDev.f);
    try testing.expectEqual(InstallKind.managed, managed.kind);
    try testing.expectEqualStrings("/home/u/.harness/app", managed.path);
    const app = detectInstallFrom("/Applications/Harness.app/Contents/MacOS/harness", "/Users/u", .macos, &buf, {}, NotDev.f);
    try testing.expectEqual(InstallKind.mac_app, app.kind);
    try testing.expectEqualStrings("/Applications/Harness.app", app.path);
    try testing.expectEqual(InstallKind.unmanaged, detectInstallFrom("/Applications/Harness.app/Contents/MacOS/harness", null, .macos, &buf, {}, NotDev.dev).kind);
    try testing.expectEqual(InstallKind.unmanaged, detectInstallFrom("/src/zig-out/bin/harness-engine", "/Users/u", .macos, &buf, {}, NotDev.f).kind);
    try testing.expectEqual(InstallKind.unmanaged, detectInstallFrom("C:/Users/u/.harness/app/1/harness", "C:/Users/u", .windows, &buf, {}, NotDev.f).kind);
    try testing.expectEqualStrings("harness.codegraff.app.dev", plistBundleId("<dict><key>CFBundleIdentifier</key>\n  <string>harness.codegraff.app.dev</string></dict>").?);
}

test "updates: release feed override must be a plain https base" {
    const ok = validateReleaseOverride(testing.allocator, " https://releases.example/x/ ");
    defer testing.allocator.free(ok.ok);
    try testing.expectEqualStrings("https://releases.example/x", ok.ok);
    try testing.expectEqualStrings("update feed must use HTTPS", validateReleaseOverride(testing.allocator, "http://releases.example").err);
    try testing.expectEqualStrings("update feed must be a base URL without credentials, query, or fragment", validateReleaseOverride(testing.allocator, "https://releases.example/?a=1").err);
}

/// Made-up releases: url suffix → reply.
const FakeHttp = struct {
    const Route = struct { suffix: []const u8, status: u16, body: []const u8 };
    routes: []const Route,
    calls: usize = 0,

    fn http(self: *FakeHttp) Http {
        return .{ .ctx = self, .get_fn = get };
    }

    fn get(ctx: ?*anyopaque, gpa: Allocator, url: []const u8) anyerror!HttpReply {
        const self: *FakeHttp = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        for (self.routes) |r| {
            if (std.mem.endsWith(u8, url, r.suffix)) return .{ .status = r.status, .body = try gpa.dupe(u8, r.body) };
        }
        return .{ .status = 404, .body = try gpa.dupe(u8, "") };
    }
};

const FakeRestart = struct {
    count: usize = 0,
    fn restarter(self: *FakeRestart) Restarter {
        return .{ .ctx = self, .restart_fn = hit };
    }
    fn hit(ctx: ?*anyopaque, _: []const u8) void {
        const self: *FakeRestart = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
    }
};

fn testUpdater(kind: InstallKind, path: []const u8, http: Http, runner: proc.Runner, restart: Restarter, io: ?std.Io) Updater {
    return .{
        .gpa = testing.allocator,
        .io = io,
        .install = .{ .kind = kind, .path = path },
        .automatic = true,
        .edge_url = "https://edge.example",
        .current_version = "0.2.100",
        .http = http,
        .runner = runner,
        .restarter = restart,
        .require_manifest_sig = false,
        .processes = .{ .executables_fn = nothingRuns },
    };
}

fn nothingRuns(_: ?*anyopaque, _: Allocator) Allocator.Error!?[]const []const u8 {
    return &.{};
}

test "updates: UpdateStatus shapes for each install, and a check fills them in" {
    var fh: FakeHttp = .{ .routes = &.{.{ .suffix = "/releases/latest/download/manifest.json", .status = 200, .body = "{\"version\":\"0.2.101\",\"files\":{}}" }} };
    var fr: FakeRestart = .{};
    var noop = proc.FakeRunner.init(testing.allocator, &.{});
    defer noop.deinit();
    var manual = testUpdater(.unmanaged, "", fh.http(), noop.runner(), fr.restarter(), null);
    defer manual.deinit();
    const s0 = (try handle(&manual, testing.allocator, .status)).ok;
    defer testing.allocator.free(s0);
    try testing.expectEqualStrings("{\"currentVersion\":\"0.2.100\",\"updateAvailable\":false,\"host\":{\"mode\":\"manual\",\"automatic\":true,\"phase\":\"idle\"}}", s0);

    var app = testUpdater(.mac_app, "/Applications/Harness.app", fh.http(), noop.runner(), fr.restarter(), null);
    defer app.deinit();
    try testing.expect(try app.checkOnce(1_790_000_000_000));
    const s1 = (try handle(&app, testing.allocator, .status)).ok;
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("{\"currentVersion\":\"0.2.100\",\"latestVersion\":\"0.2.101\",\"updateAvailable\":true,\"checkedAt\":1790000000000,\"host\":{\"mode\":\"desktop\",\"automatic\":true,\"phase\":\"idle\"}}", s1);

    var down: FakeHttp = .{ .routes = &.{.{ .suffix = "/latest.txt", .status = 503, .body = "" }} };
    var failing = testUpdater(.mac_app, "/A.app", down.http(), noop.runner(), fr.restarter(), null);
    defer failing.deinit();
    try testing.expect(!(try failing.checkOnce(1)));
    const s2 = (try handle(&failing, testing.allocator, .status)).ok;
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("{\"currentVersion\":\"0.2.100\",\"updateAvailable\":false,\"error\":\"fetching latest.txt: HTTP status 503\",\"host\":{\"mode\":\"desktop\",\"automatic\":true,\"phase\":\"failed\"}}", s2);
}

test "updates: the feed falls back to latest.txt and refuses an empty version" {
    var fh: FakeHttp = .{ .routes = &.{.{ .suffix = "/releases/latest.txt", .status = 200, .body = " 0.3.0\n" }} };
    var fr: FakeRestart = .{};
    var noop = proc.FakeRunner.init(testing.allocator, &.{});
    defer noop.deinit();
    var u = testUpdater(.unmanaged, "", fh.http(), noop.runner(), fr.restarter(), null);
    defer u.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("0.3.0", (try u.fetchLatest(arena.allocator())).ok.version);
    var empty: FakeHttp = .{ .routes = &.{.{ .suffix = "/manifest.json", .status = 200, .body = "{\"version\":\" \"}" }} };
    u.http = empty.http();
    try testing.expectEqualStrings("manifest.json has an empty version", (try u.fetchLatest(arena.allocator())).err);
}

test "updates: QueueUpdate and ApplyUpdate refuse installs that aren't managed" {
    var fh: FakeHttp = .{ .routes = &.{} };
    var fr: FakeRestart = .{};
    var noop = proc.FakeRunner.init(testing.allocator, &.{});
    defer noop.deinit();
    var u = testUpdater(.mac_app, "/A.app", fh.http(), noop.runner(), fr.restarter(), null);
    defer u.deinit();
    try testing.expectEqualStrings("this device cannot queue a remote update; update its desktop app or package locally", (try handle(&u, testing.allocator, .queue)).failed);
    try testing.expectEqualStrings("this install is not update-managed — the desktop app updates from its UI; source builds update via git", (try handle(&u, testing.allocator, .apply)).failed);
    try testing.expectEqual(@as(usize, 0), fh.calls);
    const c = (try handle(&u, testing.allocator, .check)).ok;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("{\"ok\":true}", c);

    var m = testUpdater(.managed, "/nowhere", fh.http(), noop.runner(), fr.restarter(), null);
    defer m.deinit();
    const q = (try handle(&m, testing.allocator, .queue)).ok;
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("{\"ok\":true,\"queued\":true}", q);
    try testing.expect(m.requested);
    try testing.expect(m.automatic);
    m.shutting_down = true;
    try testing.expectEqualStrings("the updater is shutting down", (try handle(&m, testing.allocator, .queue)).failed);
}

const TarEffect = struct {
    fn unpack(_: ?*anyopaque, req: proc.Request) void {
        // argv: tar -xzf <tarball> -C <unpacked> --strip-components=1
        var buf: [1024]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/" ++ engine_bin, .{req.argv[4]}) catch return;
        std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = "#!/bin/sh\n" }) catch return;
    }
};

test "updates: ApplyUpdate stages the verified tarball, repoints current, and restarts" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const tarball = "made-up tarball bytes";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const artifact = try headlessArtifactAlloc(testing.allocator, "0.2.101");
    defer testing.allocator.free(artifact);
    const manifest = try std.fmt.allocPrint(testing.allocator, "{{\"version\":\"0.2.101\",\"files\":{{\"{s}\":{{\"sha256\":\"{s}\"}}}}}}", .{ artifact, &hex });
    defer testing.allocator.free(manifest);
    const suffix = try std.fmt.allocPrint(testing.allocator, "/{s}", .{artifact});
    defer testing.allocator.free(suffix);
    var fh: FakeHttp = .{ .routes = &.{
        .{ .suffix = "/manifest.json", .status = 200, .body = manifest },
        .{ .suffix = suffix, .status = 200, .body = tarball },
    } };
    var fr: FakeRestart = .{};
    var tar = proc.FakeRunner.init(testing.allocator, &.{.{ .prefix = "tar -xzf", .effect = TarEffect.unpack }});
    defer tar.deinit();
    var u = testUpdater(.managed, root, fh.http(), tar.runner(), fr.restarter(), testing.io);
    defer u.deinit();
    const r = (try handle(&u, testing.allocator, .apply)).ok;
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"ok\":true,\"version\":\"0.2.101\"}", r);
    try testing.expectEqual(@as(usize, 1), fr.count);
    var lbuf: [4096]u8 = undefined;
    const link = try tmp.dir.readLink(testing.io, "current", &lbuf);
    try testing.expect(std.mem.endsWith(u8, lbuf[0..link], "/0.2.101"));

    // Now current: up to date.
    u.current_version = "0.2.101";
    try testing.expectEqualStrings("already up to date (0.2.101)", (try handle(&u, testing.allocator, .apply)).failed);
}

test "updates: a checksum mismatch never installs" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const artifact = try headlessArtifactAlloc(testing.allocator, "0.2.101");
    defer testing.allocator.free(artifact);
    const manifest = try std.fmt.allocPrint(testing.allocator, "{{\"version\":\"0.2.101\",\"files\":{{\"{s}\":{{\"sha256\":\"{s}\"}}}}}}", .{ artifact, "0000000000000000000000000000000000000000000000000000000000000000" });
    defer testing.allocator.free(manifest);
    const suffix = try std.fmt.allocPrint(testing.allocator, "/{s}", .{artifact});
    defer testing.allocator.free(suffix);
    var fh: FakeHttp = .{ .routes = &.{
        .{ .suffix = "/manifest.json", .status = 200, .body = manifest },
        .{ .suffix = suffix, .status = 200, .body = "tampered" },
    } };
    var fr: FakeRestart = .{};
    var tar = proc.FakeRunner.init(testing.allocator, &.{.{ .prefix = "tar -xzf", .effect = TarEffect.unpack }});
    defer tar.deinit();
    var u = testUpdater(.managed, root, fh.http(), tar.runner(), fr.restarter(), testing.io);
    defer u.deinit();
    const msg = (try handle(&u, testing.allocator, .apply)).failed;
    try testing.expect(std.mem.startsWith(u8, msg, "checksum mismatch for harness-0.2.101-"));
    try testing.expectEqual(@as(usize, 0), fr.count);
    try testing.expectEqual(@as(usize, 0), tar.calls.items.len);
}

const NoSleep = struct {
    pub fn sleep(_: @This(), _: i64) bool {
        return true;
    }
};

test "updates: a queued update waits for idle, then applies and restarts" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const artifact = try headlessArtifactAlloc(testing.allocator, "0.2.102");
    defer testing.allocator.free(artifact);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("bytes", &digest, .{});
    const manifest = try std.fmt.allocPrint(testing.allocator, "{{\"version\":\"0.2.102\",\"files\":{{\"{s}\":{{\"sha256\":\"{s}\"}}}}}}", .{ artifact, &std.fmt.bytesToHex(digest, .lower) });
    defer testing.allocator.free(manifest);
    var fh: FakeHttp = .{ .routes = &.{
        .{ .suffix = "/manifest.json", .status = 200, .body = manifest },
        .{ .suffix = ".tar.gz", .status = 200, .body = "bytes" },
    } };
    var fr: FakeRestart = .{};
    var tar = proc.FakeRunner.init(testing.allocator, &.{.{ .prefix = "tar -xzf", .effect = TarEffect.unpack }});
    defer tar.deinit();
    var u = testUpdater(.managed, root, fh.http(), tar.runner(), fr.restarter(), testing.io);
    defer u.deinit();
    const Busy = struct {
        var probes: usize = 0;
        fn quiet(_: ?*anyopaque) bool {
            probes += 1;
            return probes > 2;
        }
    };
    u.quiescent_fn = Busy.quiet;
    u.requested = true;
    try testing.expect(try u.checkOnce(5));
    try testing.expectEqual(@as(?[]u8, null), try u.autoApplyWhenIdle(NoSleep{}));
    try testing.expect(Busy.probes >= 3);
    try testing.expectEqual(@as(usize, 1), fr.count);
    try testing.expectEqual(Phase.restarting, u.phase);
    try testing.expect(!u.requested);
}

test "updates: a target device this engine can't reach is refused" {
    const p = try json.parseFromSlice(json.Value, testing.allocator, "{\"targetDeviceId\":\"other\"}", .{});
    defer p.deinit();
    try testing.expectEqualStrings("cannot reach device other: remote routing unavailable (offline)", targetProblem(p.value, "dev-local").?);
    try testing.expectEqual(@as(?[]const u8, null), targetProblem(p.value, "other"));
    try testing.expectEqual(@as(?[]const u8, null), targetProblem(.{ .object = .empty }, "dev-local"));
}

test "fix-sec 6: a release version must be a plain version before it names a path" {
    try testing.expect(validVersion("0.2.101"));
    try testing.expect(validVersion("1.0.0-rc.1+build.5"));
    for ([_][]const u8{ "", ".", "..", "../../etc", "0.2/../../x", "0.2 1", "a;b", "0.2.1\x00" }) |v| try testing.expect(!validVersion(v));

    var noop = proc.FakeRunner.init(testing.allocator, &.{});
    defer noop.deinit();
    var fr: FakeRestart = .{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var bad_manifest: FakeHttp = .{ .routes = &.{.{ .suffix = "/manifest.json", .status = 200, .body = "{\"version\":\"../../../tmp/x\"}" }} };
    var u = testUpdater(.managed, "/nowhere", bad_manifest.http(), noop.runner(), fr.restarter(), null);
    defer u.deinit();
    try testing.expect(std.mem.startsWith(u8, (try u.fetchLatest(arena.allocator())).err, "manifest.json names an invalid version"));
    var bad_latest: FakeHttp = .{ .routes = &.{.{ .suffix = "/latest.txt", .status = 200, .body = "9.9.9/../../x\n" }} };
    u.http = bad_latest.http();
    try testing.expect(std.mem.startsWith(u8, (try u.fetchLatest(arena.allocator())).err, "latest.txt names an invalid version"));
}

test "fix-sec 6: a managed install never installs a tarball without a SHA-256" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    // The latest.txt fallback never has checksums.
    var fh: FakeHttp = .{ .routes = &.{
        .{ .suffix = "/latest.txt", .status = 200, .body = "0.2.101\n" },
        .{ .suffix = ".tar.gz", .status = 200, .body = "unverified bytes" },
    } };
    var fr: FakeRestart = .{};
    var tar = proc.FakeRunner.init(testing.allocator, &.{.{ .prefix = "tar -xzf", .effect = TarEffect.unpack }});
    defer tar.deinit();
    var u = testUpdater(.managed, root, fh.http(), tar.runner(), fr.restarter(), testing.io);
    defer u.deinit();
    const msg = (try handle(&u, testing.allocator, .apply)).failed;
    try testing.expect(std.mem.indexOf(u8, msg, "refusing to install it unverified") != null);
    try testing.expectEqual(@as(usize, 0), tar.calls.items.len);
    try testing.expectEqual(@as(usize, 0), fr.count);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "current", .{}));
}

/// A made-up release server on 127.0.0.1 for the real download path.
const ReleaseServer = struct {
    const Route = struct { path: []const u8, head: []const u8, body: []const u8 = "", stall: bool = false };
    server: std.Io.net.Server,
    routes: []const Route,
    stop: std.atomic.Value(bool) = .init(false),
    release: std.Io.Event = .unset,
    thread: ?std.Thread = null,

    fn start(self: *ReleaseServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *ReleaseServer) void {
        const io = testing.io;
        while (!self.stop.load(.acquire)) {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);
            if (self.stop.load(.acquire)) return;
            var rbuf: [4096]u8 = undefined;
            var rd = stream.reader(io, &rbuf);
            const line = rd.interface.takeDelimiterInclusive('\n') catch continue;
            var path_buf: [128]u8 = undefined;
            var toks = std.mem.tokenizeScalar(u8, line, ' ');
            _ = toks.next();
            const target = toks.next() orelse continue;
            const n = @min(target.len, path_buf.len);
            @memcpy(path_buf[0..n], target[0..n]);
            while (true) {
                const h = rd.interface.takeDelimiterInclusive('\n') catch break;
                if (std.mem.trim(u8, h, "\r\n").len == 0) break;
            }
            var wbuf: [4096]u8 = undefined;
            var wr = stream.writer(io, &wbuf);
            for (self.routes) |r| if (std.mem.eql(u8, r.path, path_buf[0..n])) {
                wr.interface.writeAll(r.head) catch break;
                wr.interface.writeAll(r.body) catch break;
                wr.interface.flush() catch break;
                if (r.stall) self.release.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }) catch {};
                break;
            };
        }
    }

    fn url(self: *ReleaseServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.server.socket.address.getPort(), path }) catch unreachable;
    }

    fn deinit(self: *ReleaseServer) void {
        self.stop.store(true, .release);
        self.release.set(testing.io);
        if (std.Io.net.IpAddress.parse("127.0.0.1", self.server.socket.address.getPort())) |addr| {
            if (addr.connect(testing.io, .{ .mode = .stream })) |c| c.close(testing.io) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        self.server.deinit(testing.io);
    }
};

test "fix-sec 7: downloads stream to a file, follow redirects, and stop at a cap or a stall" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const dest = try std.fs.path.join(gpa, &.{ root, "artifact.partial" });
    defer gpa.free(dest);
    const body_bytes = comptime blk: {
        const unit = "made-up release bytes ";
        var b: [unit.len * 64]u8 = undefined;
        for (0..64) |i| @memcpy(b[i * unit.len ..][0..unit.len], unit);
        break :blk b;
    };
    const body: []const u8 = &body_bytes;
    var len_buf: [128]u8 = undefined;
    const ok_head = try std.fmt.bufPrint(&len_buf, "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.len});
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv: ReleaseServer = .{ .server = try addr.listen(io, .{ .reuse_address = true }), .routes = &.{
        .{ .path = "/final", .head = ok_head, .body = body },
        .{ .path = "/hop", .head = "HTTP/1.1 302 Found\r\nlocation: /final\r\ncontent-length: 0\r\nconnection: close\r\n\r\n" },
        .{ .path = "/loop", .head = "HTTP/1.1 302 Found\r\nlocation: /loop\r\ncontent-length: 0\r\nconnection: close\r\n\r\n" },
        .{ .path = "/stall", .head = "HTTP/1.1 200 OK\r\ncontent-length: 1000\r\nconnection: close\r\n\r\n", .body = "partial", .stall = true },
    } };
    try srv.start();
    defer srv.deinit();
    var ubuf: [128]u8 = undefined;

    // Followed redirect; the body goes to the file with its SHA-256.
    const got = try downloadTo(gpa, io, srv.url(&ubuf, "/hop"), dest, .{ .max_bytes = 1 << 20 });
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqual(@as(u64, body.len), got.size);
    var want: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &want, .{});
    try testing.expectEqualSlices(u8, &want, &got.sha256);
    var fbuf: [4096]u8 = undefined;
    try testing.expectEqualStrings(body, try tmp.dir.readFile(io, "artifact.partial", &fbuf));

    // Over the cap.
    try testing.expectError(error.TooLarge, downloadTo(gpa, io, srv.url(&ubuf, "/final"), dest, .{ .max_bytes = 100 }));
    // A redirect loop ends.
    try testing.expectError(error.TooManyRedirects, downloadTo(gpa, io, srv.url(&ubuf, "/loop"), dest, .{ .max_bytes = 100 }));
    // A server that stops sending fails at the idle deadline, not never.
    const started = std.Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, downloadTo(gpa, io, srv.url(&ubuf, "/stall"), dest, .{ .max_bytes = 1 << 20, .idle_ms = 300 }));
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 5_000);

    // Never from HTTPS to plain HTTP.
    try testing.expectEqualStrings("update redirect would downgrade HTTPS", redirectProblem(true, 1, "http://127.0.0.1/x").?);
    try testing.expectEqual(@as(?[]const u8, null), redirectProblem(true, 1, "https://objects.example/x"));
    try testing.expectEqual(@as(?[]const u8, null), redirectProblem(false, 1, "http://127.0.0.1/x"));
    try testing.expectEqualStrings("too many update redirects", redirectProblem(false, max_redirects, "https://a.example/").?);
}

test "fix-sec 7: a managed update streams the real download into place" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const tarball = "made-up tarball bytes";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tarball, &digest, .{});
    const artifact = try headlessArtifactAlloc(gpa, "0.2.101");
    defer gpa.free(artifact);
    const manifest = try std.fmt.allocPrint(gpa, "{{\"version\":\"0.2.101\",\"files\":{{\"{s}\":{{\"sha256\":\"{s}\"}}}}}}", .{ artifact, &std.fmt.bytesToHex(digest, .lower) });
    defer gpa.free(manifest);
    const path = try std.fmt.allocPrint(gpa, "/{s}", .{artifact});
    defer gpa.free(path);
    var hbuf: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{tarball.len});
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv: ReleaseServer = .{ .server = try addr.listen(io, .{ .reuse_address = true }), .routes = &.{.{ .path = path, .head = head, .body = tarball }} };
    try srv.start();
    defer srv.deinit();
    var ubuf: [128]u8 = undefined;
    const base = srv.url(&ubuf, "");

    var fh: FakeHttp = .{ .routes = &.{.{ .suffix = "/manifest.json", .status = 200, .body = manifest }} };
    var http = fh.http();
    http.download_fn = stdDownload;
    var fr: FakeRestart = .{};
    var tar = proc.FakeRunner.init(gpa, &.{.{ .prefix = "tar -xzf", .effect = TarEffect.unpack }});
    defer tar.deinit();
    var u = testUpdater(.managed, root, http, tar.runner(), fr.restarter(), io);
    defer u.deinit();
    u.releases_override = base;
    const r = (try handle(&u, gpa, .apply)).ok;
    defer gpa.free(r);
    try testing.expectEqualStrings("{\"ok\":true,\"version\":\"0.2.101\"}", r);
    try testing.expectEqual(@as(usize, 1), fr.count);
}

const AppTarEffect = struct {
    fn unpack(_: ?*anyopaque, req: proc.Request) void {
        // argv: tar -xzf <tarball> -C <dir>
        var buf: [1024]u8 = undefined;
        const d = std.fmt.bufPrint(&buf, "{s}/Harness.app/Contents/MacOS", .{req.argv[4]}) catch return;
        std.Io.Dir.cwd().createDirPath(testing.io, d) catch return;
        var b2: [1024]u8 = undefined;
        const p = std.fmt.bufPrint(&b2, "{s}/" ++ app_bin, .{d}) catch return;
        std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = "#!/bin/sh\n" }) catch return;
    }
};

test "fix-sec 8: stage_mac_app requires the tarball's checksum and stages Harness.app" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(data_dir);
    const artifact = try macAppArtifactAlloc(gpa, "0.2.101");
    defer gpa.free(artifact);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("app bytes", &digest, .{});
    var fh: FakeHttp = .{ .routes = &.{.{ .suffix = "-app.tar.gz", .status = 200, .body = "app bytes" }} };
    var fr: FakeRestart = .{};
    var tar = proc.FakeRunner.init(gpa, &.{.{ .prefix = "tar -xzf", .effect = AppTarEffect.unpack }});
    defer tar.deinit();
    var u = testUpdater(.mac_app, "/Applications/Harness.app", fh.http(), tar.runner(), fr.restarter(), testing.io);
    defer u.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const unverified = try json.parseFromSliceLeaky(json.Value, a, "{\"files\":{}}", .{});
    const missing = try u.stageMacApp(a, .{ .version = "0.2.101", .files = unverified.object.get("files").?.object }, data_dir);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "stable macOS update is missing the {s} checksum", .{artifact}), missing.err);
    try testing.expectEqual(@as(usize, 0), fh.calls);

    const files_text = try std.fmt.allocPrint(a, "{{\"files\":{{\"{s}\":{{\"sha256\":\"{s}\"}}}}}}", .{ artifact, &std.fmt.bytesToHex(digest, .lower) });
    const verified = try json.parseFromSliceLeaky(json.Value, a, files_text, .{});
    const staged = try u.stageMacApp(a, .{ .version = "0.2.101", .files = verified.object.get("files").?.object }, data_dir);
    try testing.expect(std.mem.endsWith(u8, staged.ok, "/updates/0.2.101/Harness.app"));
    // Staged once: a second call reuses it.
    _ = try u.stageMacApp(a, .{ .version = "0.2.101", .files = verified.object.get("files").?.object }, data_dir);
    try testing.expectEqual(@as(usize, 1), tar.calls.items.len);
}

const DittoEffect = struct {
    // argv: ditto <staged> <fresh>: a copy carrying the staged marker.
    fn copy(_: ?*anyopaque, req: proc.Request) void {
        var buf: [1024]u8 = undefined;
        const d = std.fmt.bufPrint(&buf, "{s}/Contents/MacOS", .{req.argv[2]}) catch return;
        std.Io.Dir.cwd().createDirPath(testing.io, d) catch return;
        var b2: [1024]u8 = undefined;
        const p = std.fmt.bufPrint(&b2, "{s}/" ++ app_bin, .{d}) catch return;
        std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = "new release\n" }) catch return;
    }
};

test "updates: `harness-engine update` swaps a macOS app for the verified release and says to relaunch" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(base);
    try tmp.dir.createDirPath(testing.io, "Applications/Harness.app/Contents/MacOS");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Applications/Harness.app/Contents/MacOS/" ++ app_bin, .data = "old release\n" });
    try tmp.dir.createDirPath(testing.io, "data");
    const bundle = try std.fs.path.join(gpa, &.{ base, "Applications", "Harness.app" });
    defer gpa.free(bundle);
    const data_dir = try std.fs.path.join(gpa, &.{ base, "data" });
    defer gpa.free(data_dir);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("app bytes", &digest, .{});
    const artifact = try macAppArtifactAlloc(a, "0.2.101");
    const manifest = try std.fmt.allocPrint(a, "{{\"version\":\"0.2.101\",\"files\":{{\"{s}\":{{\"sha256\":\"{s}\"}}}}}}", .{ artifact, &std.fmt.bytesToHex(digest, .lower) });
    const routes = [_]FakeHttp.Route{
        .{ .suffix = "/manifest.json", .status = 200, .body = manifest },
        .{ .suffix = "-app.tar.gz", .status = 200, .body = "app bytes" },
    };
    var fh: FakeHttp = .{ .routes = &routes };
    var fr: FakeRestart = .{};
    var runner = proc.FakeRunner.init(gpa, &.{
        .{ .prefix = "tar -xzf", .effect = AppTarEffect.unpack },
        .{ .prefix = "ditto", .effect = DittoEffect.copy },
    });
    defer runner.deinit();
    var u = testUpdater(.mac_app, bundle, fh.http(), runner.runner(), fr.restarter(), testing.io);
    defer u.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(gpa);
    defer err_out.deinit();
    try testing.expectEqual(@as(u8, 0), try updateCommand(&u, a, data_dir, &out.writer, &err_out.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "relaunch Harness to finish.") != null);
    try testing.expectEqualStrings("", err_out.written());
    // The installed bundle is the new one, and no second app shows beside it.
    const now = try tmp.dir.readFileAlloc(testing.io, "Applications/Harness.app/Contents/MacOS/" ++ app_bin, a, .limited(64));
    try testing.expectEqualStrings("new release\n", now);
    var apps = try tmp.dir.openDir(testing.io, "Applications", .{ .iterate = true });
    defer apps.close(testing.io);
    var it = apps.iterate();
    var entries: usize = 0;
    while (try it.next(testing.io)) |e| if (e.name[0] != '.') {
        entries += 1;
    };
    try testing.expectEqual(@as(usize, 1), entries);
    // The app's update view reads these lines (`classifyUpdateOutput`).
    try testing.expectEqual(@import("view_updates.zig").UpdateCommandOutcome.installed, @import("view_updates.zig").classifyUpdateOutput(true, out.written(), err_out.written()));

    // Already current: says so, and the app reads it as up to date.
    u.current_version = "0.2.101";
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try updateCommand(&u, a, data_dir, &out.writer, &err_out.writer));
    try testing.expectEqualStrings("Harness 0.2.101 is up to date (latest: 0.2.101).\n", out.written());
    try testing.expectEqual(@import("view_updates.zig").UpdateCommandOutcome.up_to_date, @import("view_updates.zig").classifyUpdateOutput(true, out.written(), ""));
}

test "updates: a generated Ed25519 key signs and verifies a manifest message" {
    const Ed = std.crypto.sign.Ed25519;
    const kp = Ed.KeyPair.generate(testing.io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var files: json.ObjectMap = .empty;
    try files.put(arena.allocator(), "harness.bin", .{ .object = blk: {
        var o: json.ObjectMap = .empty;
        try o.put(arena.allocator(), "sha256", .{ .string = "abcd" });
        break :blk o;
    } });
    const msg = try manifestMessage(arena.allocator(), "0.2.300", files);
    const sig = try kp.sign(msg, null);
    try testing.expect(verifyManifestSig(msg, &sig.toBytes(), kp.public_key.toBytes()));
    var bad = sig.toBytes();
    bad[0] ^= 1;
    try testing.expect(!verifyManifestSig(msg, &bad, kp.public_key.toBytes()));
}

test "updates: ApplyUpdate refuses an unsigned manifest when signatures are required" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var fh: FakeHttp = .{ .routes = &.{.{ .suffix = "/manifest.json", .status = 200, .body = "{\"version\":\"0.2.101\",\"files\":{}}" }} };
    var fr: FakeRestart = .{};
    var noop = proc.FakeRunner.init(testing.allocator, &.{});
    defer noop.deinit();
    var u = testUpdater(.managed, "/nowhere", fh.http(), noop.runner(), fr.restarter(), null);
    defer u.deinit();
    u.require_manifest_sig = true;
    const msg = (try handle(&u, testing.allocator, .apply)).failed;
    try testing.expect(std.mem.indexOf(u8, msg, "unsigned manifest") != null);
    try testing.expectEqual(@as(usize, 0), fr.count);
}

test "updates: manifestMessage and verifyManifestSig match gen-release-key.py test vector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: json.ObjectMap = .empty;
    inline for (.{ .{ "b.zip", "2222" }, .{ "a.tar.gz", "1111" } }) |entry| {
        var obj: json.ObjectMap = .empty;
        try obj.put(a, "sha256", .{ .string = entry[1] });
        try files.put(a, entry[0], .{ .object = obj });
    }
    const msg = try manifestMessage(a, "0.2.237", files);
    try testing.expectEqualStrings("0.2.237\na.tar.gz=1111\nb.zip=2222\n", msg);

    var pubkey: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&pubkey, "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8");
    var sig: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &sig,
        "31682043ec7dc3bcf3db6e76618652e92d5b3120032be03d718e9e4f0554aeae" ++
            "0d7012143d917424c4744bc3a570dd49acbb8194307ee7b34db3723755b1b30f",
    );
    try testing.expect(verifyManifestSig(msg, &sig, pubkey));

    var bad_sig = sig;
    bad_sig[0] ^= 1;
    try testing.expect(!verifyManifestSig(msg, &bad_sig, pubkey));

    const alt_msg = try manifestMessage(a, "0.2.238", files);
    try testing.expect(!verifyManifestSig(alt_msg, &sig, pubkey));
}

/// A made-up `Applications/Harness.app` (an "old release") with made-up
/// releases to update it to, and the processes that "run" meanwhile.
const MacInstall = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    bundle: []const u8 = "",
    data_dir: []const u8 = "",
    routes: [2]FakeHttp.Route = undefined,
    http: FakeHttp = undefined,
    restart: FakeRestart = .{},
    runner: proc.FakeRunner = undefined,
    /// Executables of the running processes; null: they can't be listed.
    running: ?[]const []const u8 = &.{},
    u: Updater = undefined,

    const main_exe = "Contents/MacOS/" ++ app_bin;

    fn init(self: *MacInstall) !void {
        const gpa = testing.allocator;
        self.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(gpa) };
        const a = self.arena.allocator();
        const base = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        try self.tmp.dir.createDirPath(testing.io, "Applications/Harness.app/Contents/MacOS");
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "Applications/Harness.app/" ++ main_exe, .data = "old release\n" });
        try self.tmp.dir.createDirPath(testing.io, "data");
        self.bundle = try std.fs.path.join(a, &.{ base, "Applications", "Harness.app" });
        self.data_dir = try std.fs.path.join(a, &.{ base, "data" });
        self.http = .{ .routes = &.{} };
        self.runner = proc.FakeRunner.init(gpa, &.{
            .{ .prefix = "tar -xzf", .effect = AppTarEffect.unpack },
            .{ .prefix = "ditto", .effect = DittoEffect.copy },
        });
        self.u = testUpdater(.mac_app, self.bundle, self.http.http(), self.runner.runner(), self.restart.restarter(), testing.io);
        self.u.processes = .{ .ctx = self, .executables_fn = executables };
    }

    fn deinit(self: *MacInstall) void {
        self.u.deinit();
        self.runner.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn executables(ctx: ?*anyopaque, _: Allocator) Allocator.Error!?[]const []const u8 {
        const self: *MacInstall = @ptrCast(@alignCast(ctx.?));
        return self.running;
    }

    /// Put `version` on the release feed.
    fn publish(self: *MacInstall, version: []const u8) !void {
        const a = self.arena.allocator();
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("app bytes", &digest, .{});
        self.routes = .{
            .{ .suffix = "/manifest.json", .status = 200, .body = try std.fmt.allocPrint(a, "{{\"version\":\"{s}\",\"files\":{{\"{s}\":{{\"sha256\":\"{s}\"}}}}}}", .{ version, try macAppArtifactAlloc(a, version), &std.fmt.bytesToHex(digest, .lower) }) },
            .{ .suffix = "-app.tar.gz", .status = 200, .body = "app bytes" },
        };
        self.http.routes = &self.routes;
    }

    /// `harness update` to `version`.
    fn update(self: *MacInstall, version: []const u8) !void {
        try self.publish(version);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_out.deinit();
        try testing.expectEqual(@as(u8, 0), try updateCommand(&self.u, self.arena.allocator(), self.data_dir, &out.writer, &err_out.writer));
        try testing.expect(std.mem.indexOf(u8, out.written(), "relaunch Harness to finish.") != null);
        try testing.expectEqualStrings("", err_out.written());
    }

    /// The background release check every app install runs after it starts, then hourly.
    fn check(self: *MacInstall) !void {
        try testing.expect(try self.u.checkOnce(1_790_000_000_000));
    }

    /// The replaced bundles' folder names beside the installed app.
    fn replaced(self: *MacInstall) ![]const []const u8 {
        const a = self.arena.allocator();
        var apps = try self.tmp.dir.openDir(testing.io, "Applications", .{ .iterate = true });
        defer apps.close(testing.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = apps.iterate();
        while (try it.next(testing.io)) |e| {
            if (std.mem.startsWith(u8, e.name, ".Harness.app.old-")) try names.append(a, try a.dupe(u8, e.name));
        }
        return names.items;
    }

    /// A process launched from the bundle now called `name`, as the kernel lists it.
    fn processIn(self: *MacInstall, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "/Applications/{s}/" ++ main_exe, .{name});
    }

    fn contents(self: *MacInstall, name: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        return self.tmp.dir.readFileAlloc(testing.io, try std.fmt.allocPrint(a, "Applications/{s}/" ++ main_exe, .{name}), a, .limited(64));
    }

    fn has(self: *MacInstall, name: []const u8) !bool {
        const path = try std.fmt.allocPrint(self.arena.allocator(), "Applications/{s}", .{name});
        self.tmp.dir.access(testing.io, path, .{}) catch return false;
        return true;
    }
};

test "updates: #173 an applied macOS update keeps the bundle the running app was launched from" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var m: MacInstall = undefined;
    try m.init();
    defer m.deinit();
    try m.update("0.2.101");
    try testing.expectEqualStrings("new release\n", try m.contents("Harness.app"));
    const kept = try m.replaced();
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("old release\n", try m.contents(kept[0]));
}

test "updates: #173 a replaced bundle goes at the next check once nothing runs from it, and nothing else does" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var m: MacInstall = undefined;
    try m.init();
    defer m.deinit();
    const ours = ".Harness.app.old-0123456789ab";
    const others = [_][]const u8{
        ".Harness.app.old-mine",         ".Harness.app.old-0123456789abc", ".Harness.app.old-ABCDEF012345",
        ".Harness.app.new-0123456789ab", ".Other.app.old-0123456789ab",    "Harness.app.old-0123456789ab",
    };
    try m.tmp.dir.createDirPath(testing.io, "Applications/" ++ ours ++ "/Contents/MacOS");
    for (others) |name| try m.tmp.dir.createDirPath(testing.io, try std.fmt.allocPrint(m.arena.allocator(), "Applications/{s}", .{name}));
    // Another app, and the installed one, run; nothing from the replaced bundle does.
    m.running = &.{ "/Applications/Other.app/Contents/MacOS/other", "/Applications/Harness.app/" ++ MacInstall.main_exe };
    try m.publish("0.2.100");
    try m.check();
    try testing.expect(!try m.has(ours));
    for (others) |name| try testing.expect(try m.has(name));
    try testing.expectEqualStrings("old release\n", try m.contents("Harness.app"));
}

test "updates: #173 a replaced bundle stays while a process runs from it, through checks and another update" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var m: MacInstall = undefined;
    try m.init();
    defer m.deinit();
    try m.update("0.2.101");
    const first = try m.replaced();
    try testing.expectEqual(@as(usize, 1), first.len);
    // The app (or its engine) still runs from the bundle that was moved aside.
    m.running = &.{try m.processIn(first[0])};
    try m.check();
    try testing.expectEqualStrings("old release\n", try m.contents(first[0]));
    try m.update("0.2.102");
    try testing.expectEqualStrings("old release\n", try m.contents(first[0]));
    try testing.expectEqual(@as(usize, 2), (try m.replaced()).len);
    // It quit: the next check removes both.
    m.running = &.{};
    try m.check();
    try testing.expectEqual(@as(usize, 0), (try m.replaced()).len);
    try testing.expectEqualStrings("new release\n", try m.contents("Harness.app"));
}

test "updates: #173 the next update first removes replaced bundles nothing runs from" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var m: MacInstall = undefined;
    try m.init();
    defer m.deinit();
    try m.update("0.2.101");
    const first = try m.replaced();
    try testing.expectEqual(@as(usize, 1), first.len);
    try m.update("0.2.102");
    const second = try m.replaced();
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expect(!std.mem.eql(u8, first[0], second[0]));
}

test "updates: #173 replaced bundles stay when the processes can't be listed, or the app itself is missing" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var m: MacInstall = undefined;
    try m.init();
    defer m.deinit();
    try m.update("0.2.101");
    try testing.expectEqual(@as(usize, 1), (try m.replaced()).len);
    m.running = null;
    try m.check();
    try testing.expectEqual(@as(usize, 1), (try m.replaced()).len);
    // A swap cut short between its two renames: the aside copy is the only one.
    m.running = &.{};
    try m.tmp.dir.deleteTree(testing.io, "Applications/Harness.app");
    try m.check();
    try testing.expectEqual(@as(usize, 1), (try m.replaced()).len);
}

test "updates: #173 a failed swap still puts the installed bundle back" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var m: MacInstall = undefined;
    try m.init();
    defer m.deinit();
    // `ditto` claims success but writes nothing, so the second rename fails.
    m.runner.scripts = &.{.{ .prefix = "ditto" }};
    const why = try m.u.applyMacApp(m.arena.allocator(), "/nowhere/Harness.app", m.bundle);
    try testing.expectEqualStrings("installing the new app bundle: FileNotFound", why.?);
    try testing.expectEqualStrings("old release\n", try m.contents("Harness.app"));
    try testing.expectEqual(@as(usize, 0), (try m.replaced()).len);
}

test "updates: #173 the process list follows a running executable whose bundle was renamed" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const name = try std.fmt.allocPrint(a, "Synthetic-{s}.app", .{tmp.sub_path});
    const aside = try std.fmt.allocPrint(a, ".{s}.old-0123456789ab", .{name});
    const dir = try std.fs.path.join(a, &.{ base, name, "Contents", "MacOS" });
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    // A made-up app: a copy of this test program, waiting on its input.
    const exe = try std.fs.path.join(a, &.{ dir, app_bin });
    try std.Io.Dir.copyFileAbsolute(try std.process.executablePathAlloc(testing.io, a), exe, testing.io, .{});
    var child = try std.process.spawn(testing.io, .{ .argv = &.{ exe, "--listen=-" }, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(testing.io);
    try testing.expect(runsInside((try runningExecutables(null, a)).?, name));
    try tmp.dir.rename(name, tmp.dir, aside, testing.io);
    const running = (try runningExecutables(null, a)).?;
    try testing.expect(runsInside(running, aside));
    try testing.expect(!runsInside(running, name));
}
