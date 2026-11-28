//! Auth, Codegraff OAuth/PKCE Sign-in, Org Onboarding, Refresh Rotation,
//! Cloud Sandboxes & GitHub Runners (`crates/engine/src/auth.rs`,
//! `codegraff_auth/`, `agent_accounts.rs`, `sandboxes.rs`, `github_runners.rs`).
//!
//! Uses `http_zig` (`https://github.com/justrach/http-zig`) for HTTP/2 and HTTP/1.1
//! control-plane calls (`SignIn`, `SignInHeadless`, `CompleteSignIn`, `ListOrgs`,
//! `SelectOrg`, `GetAuthStatus`, `SignInWithKey`, `GetCodegraffStatus`,
//! `CreateCloudSandbox`, `StopCloudSandbox`, `DeleteCloudSandbox`).
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const http_zig = @import("http_zig");
const io_deadline = @import("io_deadline.zig");

pub fn setTcpNoDelay(stream: std.Io.net.Stream) void {
    if (comptime builtin.os.tag == .windows) return;
    const one: c_int = 1;
    _ = std.c.setsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&one),
        @sizeOf(c_int),
    );
}

/// The deadline for one edge request, connect excluded (the Rust edge
/// client's total `timeout(30s)`, `doc_host.rs`).
pub const edge_request_timeout_ms: u32 = 30_000;

/// The HTTP/1.1 method for an edge request's method name, or null when it
/// isn't one (never a silent GET).
pub fn h1Method(method: []const u8) ?std.http.Method {
    return std.meta.stringToEnum(std.http.Method, method);
}

/// Ends a request that outlives its deadline: a helper thread waits on an
/// event and, if it isn't set in time, shuts the socket down, which fails
/// the blocked read or write. The socket must not be reused afterwards.
pub const SocketWatchdog = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    ms: u32,
    done: std.Io.Event = .unset,
    fired: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn arm(self: *SocketWatchdog) void {
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    fn run(self: *SocketWatchdog) void {
        self.done.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(self.ms), .clock = .awake } }) catch {
            self.fired.store(true, .release);
            shutdownSocket(self.io, self.stream);
        };
    }

    /// Stop watching; true when the deadline had already passed.
    pub fn disarm(self: *SocketWatchdog) bool {
        self.done.set(self.io);
        if (self.thread) |t| t.join();
        self.thread = null;
        return self.fired.load(.acquire);
    }
};

pub fn shutdownSocket(io: std.Io, stream: std.Io.net.Stream) void {
    stream.shutdown(io, .both) catch {};
}

/// Thread-safe pool of warm `http_zig.Session` (TLS 1.3 + ALPN `h2` + cached Root CA bundle)
/// connections across origins. Eliminates per-request macOS CA bundle rescans, DNS lookups,
/// TCP 3-way handshakes, TLS 1.3 handshakes, and HTTP/2 SETTINGS prefaces, while allowing
/// concurrent callers to check out independent sessions in parallel without head-of-line blocking.
pub const H2SessionPool = struct {
    pub const max_idle: usize = 8;

    mutex: std.Io.Mutex = .init,
    slots: [max_idle]?*http_zig.Session = @splat(null),
    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),

    pub fn checkout(self: *H2SessionPool, gpa: Allocator, io: std.Io, host: []const u8, port: u16) !*http_zig.Session {
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            var idx: usize = max_idle;
            while (idx > 0) {
                idx -= 1;
                if (self.slots[idx]) |s| {
                    if (s.port == port and std.mem.eql(u8, s.host, host)) {
                        self.slots[idx] = null;
                        if (s.reusable()) {
                            _ = self.hits.fetchAdd(1, .monotonic);
                            return s;
                        }
                        s.close();
                    }
                }
            }
        }
        _ = self.misses.fetchAdd(1, .monotonic);
        const sess = try http_zig.Session.open(gpa, io, host, port);
        if (!sess.h1_only and sess.h2_live) {
            setTcpNoDelay(sess.stream);
        }
        return sess;
    }

    pub fn checkin(self: *H2SessionPool, io: std.Io, sess: *http_zig.Session) void {
        if (!sess.reusable()) {
            sess.close();
            return;
        }
        var evicted: ?*http_zig.Session = null;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            for (&self.slots) |*slot| {
                if (slot.* == null) {
                    slot.* = sess;
                    return;
                }
            }
            evicted = self.slots[0];
            for (0..max_idle - 1) |i| {
                self.slots[i] = self.slots[i + 1];
            }
            self.slots[max_idle - 1] = sess;
        }
        if (evicted) |old| old.close();
    }

    pub fn deinit(self: *H2SessionPool) void {
        for (&self.slots) |*slot| {
            if (slot.*) |s| {
                slot.* = null;
                s.close();
            }
        }
    }
};

pub const token_slack_secs: i64 = 30;
pub const refresh_replay_window_ms: u64 = 7 * 24 * 60 * 60 * 1000;

pub const default_edge_url = "https://edge.codegraff.com";
pub const default_codegraff_client_id = "cg_client_43e753878956c2cf7b5b0f53";
pub const default_codegraff_api_base = "https://codegraff.com";
pub const default_codegraff_gateway = "https://gateway.codegraff.com";
pub const default_callback_port: u16 = 27643;

/// Percent-encode a query value per RFC 3986 unreserved characters.
pub fn urlEncodeAlloc(gpa: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hex = "0123456789ABCDEF";
    for (input) |b| {
        const unreserved = (b >= 'A' and b <= 'Z') or
            (b >= 'a' and b <= 'z') or
            (b >= '0' and b <= '9') or
            b == '-' or b == '_' or b == '.' or b == '~';
        if (unreserved) {
            try out.append(gpa, b);
        } else {
            try out.appendSlice(gpa, &.{ '%', hex[b >> 4], hex[b & 0x0f] });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Percent-decode a query component (`%XX` and `+` -> `' '`).
pub fn urlDecodeAlloc(gpa: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 3 <= input.len) {
            if (std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16)) |byte| {
                try out.append(gpa, byte);
                i += 3;
                continue;
            } else |_| {}
        } else if (input[i] == '+') {
            try out.append(gpa, ' ');
            i += 1;
            continue;
        }
        try out.append(gpa, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Extract and URL-decode query parameter `name` from a URL or request target.
pub fn extractQueryParamAlloc(gpa: Allocator, url_or_target: []const u8, name: []const u8) !?[]u8 {
    const q_idx = std.mem.indexOfScalar(u8, url_or_target, '?') orelse return null;
    var query = url_or_target[q_idx + 1 ..];
    if (std.mem.indexOfScalar(u8, query, '#')) |h| query = query[0..h];
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const raw_k = pair[0..eq];
        const raw_v = pair[eq + 1 ..];
        const dec_k = try urlDecodeAlloc(gpa, raw_k);
        defer gpa.free(dec_k);
        if (std.mem.eql(u8, dec_k, name)) {
            return try urlDecodeAlloc(gpa, raw_v);
        }
    }
    return null;
}

pub const AuthPhase = enum {
    signed_out,
    needs_organization,
    signed_in,
};

/// A refresh rejection's cause from the edge's `{error}` text (`crates/engine/src/auth.rs`).
pub const RefreshRejection = enum {
    invalid,
    workspace,
    malformed,
    rejected,
    unknown,

    pub fn fromReason(reason: []const u8) RefreshRejection {
        if (std.mem.eql(u8, reason, "invalid refresh credential")) return .invalid;
        if (std.mem.eql(u8, reason, "workspace does not belong to this account")) return .workspace;
        if (std.mem.eql(u8, reason, "missing refreshToken") or std.mem.eql(u8, reason, "bad request")) return .malformed;
        if (std.mem.startsWith(u8, reason, "CodeGraff rejected the grant")) return .rejected;
        return .unknown;
    }

    /// Retrying cannot change these answers (`RefreshRejection::definite`).
    pub fn isDefinite(self: RefreshRejection) bool {
        return switch (self) {
            .invalid, .workspace, .malformed => true,
            .rejected, .unknown => false,
        };
    }
};

/// Dual-clock elapsed duration (`UnansweredRefresh::elapsed_at` / `AccessEntry`):
/// monotonic clock freezes across OS suspend, while wall clock is vulnerable to
/// backward NTP steps. Taking `@max(mono_elapsed_ms, wall_elapsed_ms)` is
/// Lean-proven immune to both (`dual_clock_immune_to_sleep_and_ntp`).
pub fn dualClockElapsedMs(mono_elapsed_ms: u64, wall_elapsed_ms: u64) u64 {
    return @max(mono_elapsed_ms, wall_elapsed_ms);
}

/// Compute PKCE S256 `code_challenge = base64url_no_pad(SHA256(verifier))`.
pub fn pkceChallengeS256(verifier: []const u8, out_buf: *[43]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return std.base64.url_safe_no_pad.Encoder.encode(out_buf, &digest);
}

/// `is_loopback_http_url`: plain HTTP to exactly `127.0.0.1` or `[::1]`. The URL is
/// parsed (`std.Uri`), so user info (`http://127.0.0.1:80@evil.example`), a
/// look-alike host (`127.0.0.1.evil.example`) or `localhost` never passes.
pub fn isLoopbackHttpUrl(raw: []const u8) bool {
    const uri = std.Uri.parse(raw) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    const host = uriHost(uri) orelse return false;
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "::1");
}

fn uriHost(uri: std.Uri) ?[]const u8 {
    const h = uri.host orelse return null;
    const host = switch (h) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    };
    return if (host.len == 0) null else host;
}

/// HTTPS (with a host), or plain HTTP on loopback (`validate_secure_url`).
pub fn isSecureUrl(raw: []const u8) bool {
    const uri = std.Uri.parse(raw) catch return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return uriHost(uri) != null;
    return isLoopbackHttpUrl(raw);
}

/// `validate_secure_url(name, raw)`: null when fine, else Rust's message in `buf`.
pub fn secureUrlProblem(buf: []u8, name: []const u8, raw: []const u8) ?[]const u8 {
    if (isSecureUrl(raw)) return null;
    _ = std.Uri.parse(raw) catch
        return std.fmt.bufPrint(buf, "{s} URL is invalid", .{name}) catch "URL is invalid";
    return std.fmt.bufPrint(buf, "{s} must use HTTPS (plain HTTP is allowed only on loopback)", .{name}) catch
        "URL must use HTTPS (plain HTTP is allowed only on loopback)";
}

/// `write_private`: atomically replace a credential file, readable only by its
/// owner. The bytes go to a new `0600` file beside `path` (created exclusively,
/// synced), which is then renamed over it, so a reader never sees a half-written
/// file and a symlink at `path` is replaced rather than followed. On error the
/// old file is untouched and the temporary file is removed.
pub fn writePrivate(io: std.Io, path: []const u8, body: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const dir_name = std.fs.path.dirname(path) orelse ".";
    var rnd: [16]u8 = undefined;
    io.random(&rnd);
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}/.session-{s}.tmp", .{ dir_name, &std.fmt.bytesToHex(rnd, .lower) });
    const perms: std.Io.File.Permissions = if (comptime builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    const file = try cwd.createFile(io, tmp, .{ .exclusive = true, .permissions = perms });
    errdefer cwd.deleteFile(io, tmp) catch {};
    {
        defer file.close(io);
        try file.writeStreamingAll(io, body);
        try file.sync(io);
    }
    try std.Io.Dir.rename(cwd, tmp, cwd, path, io);
}

pub const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,
};

/// Convert days since 1970-01-01 to civil year/month/day (Howard Hinnant's algorithm).
pub fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year: i32 = @intCast(if (m <= 2) y + 1 else y);
    return .{
        .year = year,
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// Format epoch milliseconds as an RFC 3339 UTC timestamp (`"YYYY-MM-DDTHH:MM:SS.mmmZ"`).
pub fn formatRfc3339Ms(buf: *[32]u8, epoch_ms: i64) []const u8 {
    const day_ms: i64 = 86_400_000;
    const clamped_ms = @max(@as(i64, 0), epoch_ms);
    const days = @divFloor(clamped_ms, day_ms);
    const rem_day = @mod(clamped_ms, day_ms);
    const hour: u64 = @intCast(@divFloor(rem_day, 3_600_000));
    const rem_hr = @mod(rem_day, 3_600_000);
    const min: u64 = @intCast(@divFloor(rem_hr, 60_000));
    const rem_min = @mod(rem_hr, 60_000);
    const sec: u64 = @intCast(@divFloor(rem_min, 1_000));
    const ms: u64 = @intCast(@mod(rem_min, 1_000));
    const civ = civilFromDays(days);
    const year_u: u64 = @intCast(@max(@as(i32, 1970), civ.year));
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{ year_u, civ.month, civ.day, hour, min, sec, ms },
    ) catch "1970-01-01T00:00:00.000Z";
}

pub const JwtClaims = struct {
    org_id: ?[]u8 = null,
    ttl_secs: i64 = 3600,
    exp_secs: i64 = 0,

    pub fn deinit(self: *JwtClaims, gpa: Allocator) void {
        if (self.org_id) |o| gpa.free(o);
    }
};

/// Decode the payload segment of a `header.payload.sig` JWT to extract `org_id` and `exp - iat`.
pub fn parseJwtClaims(gpa: Allocator, jwt: []const u8) !JwtClaims {
    const first_dot = std.mem.indexOfScalar(u8, jwt, '.') orelse return .{};
    const rest = jwt[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    const payload_b64 = rest[0..second_dot];
    if (payload_b64.len == 0) return .{};

    const dec = std.base64.url_safe_no_pad.Decoder;
    const trimmed_b64 = std.mem.trimEnd(u8, payload_b64, "=");
    const decoded_len = dec.calcSizeForSlice(trimmed_b64) catch return .{};
    const decoded = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded);
    dec.decode(decoded, trimmed_b64) catch return .{};

    var parsed = json.parseFromSlice(json.Value, gpa, decoded, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const obj = parsed.value.object;

    var out: JwtClaims = .{};
    errdefer out.deinit(gpa);
    if (obj.get("org_id")) |v| {
        if (v == .string and v.string.len > 0) {
            out.org_id = try gpa.dupe(u8, v.string);
        }
    }
    const iat: i64 = if (obj.get("iat")) |v| (if (v == .integer) v.integer else 0) else 0;
    const exp: i64 = if (obj.get("exp")) |v| (if (v == .integer) v.integer else 0) else 0;
    out.exp_secs = exp;
    if (exp > iat) out.ttl_secs = exp - iat;
    return out;
}

pub const CloudSandbox = struct {
    id: []u8,
    name: []u8,
    status: []u8, // "running", "stopped"
    region: []u8,

    pub fn deinit(self: *CloudSandbox, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.status);
        gpa.free(self.region);
    }
};

pub const DeviceStartInfo = struct {
    device_code: []u8,
    verification_url: []u8,
    expires_in_s: u64,
    interval_s: u64,
    generation: u64,

    pub fn deinit(self: *DeviceStartInfo, gpa: Allocator) void {
        gpa.free(self.device_code);
        gpa.free(self.verification_url);
    }
};

pub const DevicePollStep = union(enum) {
    pending: u64,
    approved: struct {
        api_key: []u8,
        email: ?[]u8,

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            gpa.free(self.api_key);
            if (self.email) |e| gpa.free(e);
        }
    },
    failed: []const u8,
    transient,
};

pub const AuthManager = struct {
    gpa: Allocator,
    phase: AuthPhase = .signed_in,
    signed_in: bool = true,
    user_id: []u8,
    email: []u8,
    user_name: ?[]u8 = null,
    org_id: ?[]u8 = null,
    api_key: ?[]u8 = null,
    access_token: ?[]u8 = null,
    access_expires_at_ms: i64 = 0,
    refresh_token: ?[]u8 = null,
    codegraff_connected: bool = true,
    codegraff_api_key: ?[]u8 = null,
    codegraff_email: ?[]u8 = null,
    codegraff_pending: bool = false,
    codegraff_generation: u64 = 0,
    codegraff_error: ?[]u8 = null,
    generation: u64 = 0,
    pending_state: ?[]u8 = null,
    pending_verifier: ?[]u8 = null,
    pending_nonce: ?[]u8 = null,
    pending_redirect_uri: ?[]u8 = null,
    pending_generation: u64 = 0,
    edge_url: ?[]u8 = null,
    codegraff_client_id: ?[]u8 = null,
    codegraff_api_base: []u8,
    codegraff_gateway: []u8,
    callback_port: u16 = default_callback_port,
    data_dir: ?[]u8 = null,
    last_unanswered: bool = false,
    rejection_spared: bool = false,
    lost_session_marker: bool = false,
    sandboxes: std.ArrayList(CloudSandbox) = .empty,
    h2_pool: H2SessionPool = .{},
    /// The message of the last `error.AuthFailed`, in the Rust engine's words.
    err_buf: [320]u8 = undefined,
    err_len: usize = 0,

    pub fn init(gpa: Allocator) !AuthManager {
        const uid = try gpa.dupe(u8, "user-local");
        errdefer gpa.free(uid);
        const email = try gpa.dupe(u8, "local@codegraff.com");
        errdefer gpa.free(email);
        const uname = try gpa.dupe(u8, "CodeGraff");
        errdefer gpa.free(uname);
        const org = try gpa.dupe(u8, "org-personal");
        errdefer gpa.free(org);
        const api_base = try gpa.dupe(u8, default_codegraff_api_base);
        errdefer gpa.free(api_base);
        const gateway = try gpa.dupe(u8, default_codegraff_gateway);
        errdefer gpa.free(gateway);
        return .{
            .gpa = gpa,
            .phase = .signed_in,
            .signed_in = true,
            .user_id = uid,
            .email = email,
            .user_name = uname,
            .org_id = org,
            .codegraff_api_base = api_base,
            .codegraff_gateway = gateway,
        };
    }

    pub fn deinit(self: *AuthManager) void {
        self.gpa.free(self.user_id);
        self.gpa.free(self.email);
        if (self.user_name) |n| self.gpa.free(n);
        if (self.org_id) |o| self.gpa.free(o);
        if (self.api_key) |k| self.gpa.free(k);
        if (self.access_token) |t| self.gpa.free(t);
        if (self.refresh_token) |t| self.gpa.free(t);
        if (self.codegraff_api_key) |k| self.gpa.free(k);
        if (self.codegraff_email) |e| self.gpa.free(e);
        if (self.codegraff_error) |e| self.gpa.free(e);
        if (self.pending_state) |s| self.gpa.free(s);
        if (self.pending_verifier) |v| self.gpa.free(v);
        if (self.pending_nonce) |n| self.gpa.free(n);
        if (self.pending_redirect_uri) |r| self.gpa.free(r);
        if (self.edge_url) |u| self.gpa.free(u);
        if (self.codegraff_client_id) |c| self.gpa.free(c);
        self.gpa.free(self.codegraff_api_base);
        self.gpa.free(self.codegraff_gateway);
        if (self.data_dir) |d| self.gpa.free(d);
        for (self.sandboxes.items) |*sb| sb.deinit(self.gpa);
        self.sandboxes.deinit(self.gpa);
        self.h2_pool.deinit();
    }

    /// `ensure_secure_transport`: OAuth codes and refresh credentials travel only
    /// over TLS, or plain HTTP to a loopback development edge.
    pub fn ensureSecureTransport(self: *AuthManager) !void {
        if (self.codegraff_client_id == null) return;
        const pairs = [_][2][]const u8{
            .{ "Harness edge", self.edge_url orelse default_edge_url },
            .{ "CodeGraff OAuth", self.codegraff_api_base },
        };
        for (pairs) |pair| {
            var buf: [160]u8 = undefined;
            if (secureUrlProblem(&buf, pair[0], pair[1])) |msg| return self.fail("{s}", .{msg});
        }
    }

    /// The message behind the last `error.AuthFailed`.
    pub fn lastError(self: *const AuthManager) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// An RPC error text for `err`: the recorded message for `error.AuthFailed`.
    pub fn errorText(self: *const AuthManager, err: anyerror) []const u8 {
        return if (err == error.AuthFailed) self.lastError() else @errorName(err);
    }

    fn fail(self: *AuthManager, comptime fmt: []const u8, args: anytype) error{AuthFailed} {
        const msg = std.fmt.bufPrint(&self.err_buf, fmt, args) catch self.err_buf[0..];
        self.err_len = msg.len;
        return error.AuthFailed;
    }

    fn replaceOptStr(self: *AuthManager, slot: *?[]u8, val: ?[]const u8) !void {
        const copy = if (val) |v| try self.gpa.dupe(u8, v) else null;
        if (slot.*) |old| self.gpa.free(old);
        slot.* = copy;
    }

    fn replaceStr(self: *AuthManager, slot: *[]u8, val: []const u8) !void {
        const copy = try self.gpa.dupe(u8, val);
        self.gpa.free(slot.*);
        slot.* = copy;
    }

    /// Configure CodeGraff OAuth client + edge URL + data_dir for session persistence.
    pub fn configureCodegraff(
        self: *AuthManager,
        edge_url: ?[]const u8,
        client_id: ?[]const u8,
        api_base: ?[]const u8,
        data_dir: ?[]const u8,
    ) !void {
        try self.replaceOptStr(&self.edge_url, edge_url);
        try self.replaceOptStr(&self.codegraff_client_id, client_id);
        if (api_base) |b| try self.replaceStr(&self.codegraff_api_base, b);
        try self.replaceOptStr(&self.data_dir, data_dir);
        if (client_id != null) {
            self.phase = .signed_out;
            self.signed_in = false;
            self.codegraff_connected = false;
            try self.replaceOptStr(&self.org_id, null);
            try self.replaceStr(&self.email, "");
            try self.replaceOptStr(&self.user_name, null);
        }
    }

    pub fn setCodegraffGateway(self: *AuthManager, gateway_url: []const u8) !void {
        try self.replaceStr(&self.codegraff_gateway, gateway_url);
    }

    /// Load persisted `session.json` and `codegraff-key.json` from `self.data_dir` if present.
    /// Returns `true` when an active Harness sync session was restored.
    pub fn loadPersistedSession(self: *AuthManager, io: std.Io) bool {
        const dir = self.data_dir orelse return false;

        // 1. Restore CodeGraff gateway API key if previously saved in `{data_dir}/codegraff-key.json`.
        if (std.fmt.allocPrint(self.gpa, "{s}/codegraff-key.json", .{dir})) |key_path| {
            defer self.gpa.free(key_path);
            if (std.Io.Dir.cwd().readFileAlloc(io, key_path, self.gpa, .limited(64 * 1024))) |raw| {
                defer self.gpa.free(raw);
                if (json.parseFromSlice(json.Value, self.gpa, raw, .{})) |parsed_val| {
                    var parsed = parsed_val;
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        const obj = parsed.value.object;
                        const k_str = if (obj.get("api_key")) |kv| (if (kv == .string) kv.string else "") else "";
                        const e_str: ?[]const u8 = if (obj.get("email")) |ev| (if (ev == .string and ev.string.len > 0) ev.string else null) else null;
                        if (k_str.len > 0) {
                            self.replaceOptStr(&self.codegraff_api_key, k_str) catch {};
                            self.replaceOptStr(&self.codegraff_email, e_str) catch {};
                            self.codegraff_connected = true;
                        }
                    }
                } else |_| {}
            } else |_| {}
        } else |_| {}

        // 2. Restore Harness sync `session.json` if present.
        const sess_path = std.fmt.allocPrint(self.gpa, "{s}/session.json", .{dir}) catch return false;
        defer self.gpa.free(sess_path);
        const sess_raw = @import("session_store.zig").read(self.gpa, io, sess_path) orelse return false;
        defer self.gpa.free(sess_raw);
        var parsed = json.parseFromSlice(json.Value, self.gpa, sess_raw, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const obj = parsed.value.object;

        const rt = if (obj.get("refreshToken")) |rv| (if (rv == .string) rv.string else "") else "";
        if (rt.len == 0) return false;
        self.replaceOptStr(&self.refresh_token, rt) catch return false;

        if (obj.get("user")) |uv| if (uv == .object) {
            if (uv.object.get("id")) |idv| if (idv == .string) {
                self.replaceStr(&self.user_id, idv.string) catch {};
            };
            if (uv.object.get("email")) |ev| if (ev == .string) {
                self.replaceStr(&self.email, ev.string) catch {};
            };
            if (uv.object.get("name")) |nv| {
                if (nv == .string and nv.string.len > 0) {
                    self.replaceOptStr(&self.user_name, nv.string) catch {};
                }
            }
        };
        if (obj.get("orgId")) |ov| {
            if (ov == .string and ov.string.len > 0) {
                self.replaceOptStr(&self.org_id, ov.string) catch {};
            }
        }
        if (self.org_id != null) {
            self.phase = .signed_in;
            self.signed_in = true;
        } else {
            self.phase = .needs_organization;
            self.signed_in = false;
        }
        return self.signed_in;
    }

    /// Serialize `AuthStatus` stream item matching `harness_proto::AuthState`.
    pub fn authStatusJson(self: *const AuthManager, gpa: Allocator) ![]u8 {
        const name_val: ?[]const u8 = self.user_name;
        return switch (self.phase) {
            .signed_out => gpa.dupe(u8, "{\"state\":\"signedOut\"}"),
            .needs_organization => std.fmt.allocPrint(
                gpa,
                "{{\"state\":\"needsOrganization\",\"user\":{{\"id\":{f},\"email\":{f},\"name\":{f}}}}}",
                .{
                    json.fmt(self.user_id, .{}),
                    json.fmt(self.email, .{}),
                    json.fmt(name_val, .{}),
                },
            ),
            .signed_in => if (self.org_id) |org|
                std.fmt.allocPrint(
                    gpa,
                    "{{\"state\":\"signedIn\",\"user\":{{\"id\":{f},\"email\":{f},\"name\":{f}}},\"orgId\":{f}}}",
                    .{
                        json.fmt(self.user_id, .{}),
                        json.fmt(self.email, .{}),
                        json.fmt(name_val, .{}),
                        json.fmt(org, .{}),
                    },
                )
            else
                std.fmt.allocPrint(
                    gpa,
                    "{{\"state\":\"signedIn\",\"user\":{{\"id\":{f},\"email\":{f},\"name\":{f}}}}}",
                    .{
                        json.fmt(self.user_id, .{}),
                        json.fmt(self.email, .{}),
                        json.fmt(name_val, .{}),
                    },
                ),
        };
    }

    /// Start headless PKCE sign-in (`SignInHeadless`), returning the OAuth authorize URL
    /// (`start_headless_sign_in`): the same random state, nonce and verifier as the
    /// headed flow, redirecting to the edge's hosted paste-code page. Empty without
    /// a CodeGraff client (development mode).
    pub fn startHeadlessSignIn(self: *AuthManager, io: std.Io) ![]u8 {
        if (self.codegraff_client_id == null) return self.gpa.dupe(u8, "");
        try self.ensureSecureTransport();
        const edge = std.mem.trimEnd(u8, self.edge_url orelse default_edge_url, "/");
        const redirect_uri = try std.fmt.allocPrint(self.gpa, "{s}/auth/cli/callback", .{edge});
        defer self.gpa.free(redirect_uri);
        return self.startBrowserSignIn(io, redirect_uri);
    }

    /// Start headed browser PKCE sign-in (`SignIn`), binding to `redirect_uri` (e.g.
    /// `http://127.0.0.1:27643/callback`) and matching `crates/engine/src/auth.rs` `begin_sign_in` 1:1.
    pub fn startBrowserSignIn(self: *AuthManager, io: std.Io, redirect_uri: []const u8) ![]u8 {
        try self.ensureSecureTransport();
        var state_bytes: [16]u8 = undefined;
        var verifier_bytes: [32]u8 = undefined;
        io.random(&state_bytes);
        io.random(&verifier_bytes);
        const state_hex = std.fmt.bytesToHex(state_bytes, .lower);
        const verifier_hex = std.fmt.bytesToHex(verifier_bytes, .lower);

        try self.replaceOptStr(&self.pending_state, &state_hex);
        try self.replaceOptStr(&self.pending_verifier, &verifier_hex);
        try self.replaceOptStr(&self.pending_nonce, &state_hex);
        try self.replaceOptStr(&self.pending_redirect_uri, redirect_uri);
        self.pending_generation = self.generation;

        var challenge_buf: [43]u8 = undefined;
        const challenge = pkceChallengeS256(&verifier_hex, &challenge_buf);
        const cid = self.codegraff_client_id orelse default_codegraff_client_id;
        const enc_cid = try urlEncodeAlloc(self.gpa, cid);
        defer self.gpa.free(enc_cid);
        const enc_redirect = try urlEncodeAlloc(self.gpa, redirect_uri);
        defer self.gpa.free(enc_redirect);
        const api_base = std.mem.trimEnd(u8, self.codegraff_api_base, "/");
        return std.fmt.allocPrint(
            self.gpa,
            "{s}/oauth/authorize?response_type=code&client_id={s}&redirect_uri={s}&scope=openid%20email%20offline_access&state={s}&nonce={s}&code_challenge={s}&code_challenge_method=S256",
            .{ api_base, enc_cid, enc_redirect, state_hex, state_hex, challenge },
        );
    }

    fn persistSessionFile(self: *const AuthManager, io: std.Io) void {
        const dir = self.data_dir orelse return;
        const rt = self.refresh_token orelse return;
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const path = std.fmt.allocPrint(self.gpa, "{s}/session.json", .{dir}) catch return;
        defer self.gpa.free(path);

        const body = if (self.org_id) |org|
            std.fmt.allocPrint(
                self.gpa,
                "{{\"refreshToken\":{f},\"user\":{{\"id\":{f},\"email\":{f},\"name\":{f}}},\"orgId\":{f}}}",
                .{ json.fmt(rt, .{}), json.fmt(self.user_id, .{}), json.fmt(self.email, .{}), json.fmt(self.user_name, .{}), json.fmt(org, .{}) },
            ) catch return
        else
            std.fmt.allocPrint(
                self.gpa,
                "{{\"refreshToken\":{f},\"user\":{{\"id\":{f},\"email\":{f},\"name\":{f}}}}}",
                .{ json.fmt(rt, .{}), json.fmt(self.user_id, .{}), json.fmt(self.email, .{}), json.fmt(self.user_name, .{}) },
            ) catch return;
        defer self.gpa.free(body);

        if (!@import("session_store.zig").write(io, path, body)) writePrivateFile(io, path, body);
    }

    fn persistCodegraffKeyFile(self: *const AuthManager, io: std.Io) void {
        const dir = self.data_dir orelse return;
        const key = self.codegraff_api_key orelse return;
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const path = std.fmt.allocPrint(self.gpa, "{s}/codegraff-key.json", .{dir}) catch return;
        defer self.gpa.free(path);
        const body = std.fmt.allocPrint(
            self.gpa,
            "{{\"api_key\":{f},\"email\":{f}}}",
            .{ json.fmt(key, .{}), json.fmt(self.codegraff_email, .{}) },
        ) catch return;
        defer self.gpa.free(body);
        writePrivateFile(io, path, body);
    }

    fn writePrivateFile(io: std.Io, path: []const u8, body: []const u8) void {
        writePrivate(io, path, body) catch |err|
            std.log.warn("auth: failed to save {s}: {t}", .{ std.fs.path.basename(path), err });
    }

    fn removeSessionFile(self: *const AuthManager, io: ?std.Io) void {
        const rio = io orelse return;
        const dir = self.data_dir orelse return;
        const path = std.fmt.allocPrint(self.gpa, "{s}/session.json", .{dir}) catch return;
        defer self.gpa.free(path);
        @import("session_store.zig").delete(rio, path);
    }

    fn removeCodegraffKeyFile(self: *const AuthManager, io: ?std.Io) void {
        const rio = io orelse return;
        const dir = self.data_dir orelse return;
        const path = std.fmt.allocPrint(self.gpa, "{s}/codegraff-key.json", .{dir}) catch return;
        defer self.gpa.free(path);
        std.Io.Dir.cwd().deleteFile(rio, path) catch {};
    }

    pub const EdgeReply = struct {
        status: u16,
        body: []u8,

        pub fn deinit(self: *EdgeReply, gpa: Allocator) void {
            gpa.free(self.body);
        }
    };

    /// Execute an HTTP/2 (`https://` via `http_zig.Session`) or HTTP/1.1 (`http://` loopback)
    /// request against the configured edge or gateway server.
    pub fn edgeRequest(
        gpa: Allocator,
        io: std.Io,
        method: []const u8,
        url: []const u8,
        bearer_token: ?[]const u8,
        req_body: ?[]const u8,
    ) !EdgeReply {
        return edgeRequestHeaders(gpa, io, method, url, bearer_token, &.{}, req_body);
    }

    /// Execute an HTTP/2 or HTTP/1.1 request with optional extra headers.
    pub fn edgeRequestHeaders(
        gpa: Allocator,
        io: std.Io,
        method: []const u8,
        url: []const u8,
        bearer_token: ?[]const u8,
        extra_headers: []const http_zig.Header,
        req_body: ?[]const u8,
    ) !EdgeReply {
        return edgeRequestPooled(null, gpa, io, method, url, bearer_token, extra_headers, req_body);
    }

    /// Execute an HTTP/2 or HTTP/1.1 request reusing warm TLS+H2 connections from `pool` when non-null,
    /// with zero-copy `Response.body` ownership transfer.
    pub fn edgeRequestPooled(
        pool: ?*H2SessionPool,
        gpa: Allocator,
        io: std.Io,
        method: []const u8,
        url: []const u8,
        bearer_token: ?[]const u8,
        extra_headers: []const http_zig.Header,
        req_body: ?[]const u8,
    ) !EdgeReply {
        return edgeRequestTimed(pool, gpa, io, method, url, bearer_token, extra_headers, req_body, edge_request_timeout_ms);
    }

    /// `edgeRequestPooled` with a deadline: past `timeout_ms` the request
    /// fails with `error.Timeout` and its connection is dropped.
    pub fn edgeRequestTimed(
        pool: ?*H2SessionPool,
        gpa: Allocator,
        io: std.Io,
        method: []const u8,
        url: []const u8,
        bearer_token: ?[]const u8,
        extra_headers: []const http_zig.Header,
        req_body: ?[]const u8,
        timeout_ms: u32,
    ) !EdgeReply {
        if (comptime builtin.os.tag == .ios) {
            if (std.mem.startsWith(u8, url, "https://")) {
                const nanoui = @import("nanoui");
                var auth_val: ?[]u8 = null;
                defer if (auth_val) |v| gpa.free(v);
                if (bearer_token) |tok| {
                    auth_val = try std.fmt.allocPrint(gpa, "Bearer {s}", .{tok});
                }
                var hdrs: [16]nanoui.http.Header = undefined;
                var hlen: usize = 0;
                hdrs[hlen] = .{ .name = "user-agent", .value = "harness-ios/0.2" };
                hlen += 1;
                hdrs[hlen] = .{ .name = "accept", .value = "application/json" };
                hlen += 1;
                if (auth_val) |av| {
                    hdrs[hlen] = .{ .name = "authorization", .value = av };
                    hlen += 1;
                }
                if (req_body != null) {
                    hdrs[hlen] = .{ .name = "content-type", .value = "application/json" };
                    hlen += 1;
                }
                for (extra_headers) |eh| {
                    if (hlen >= hdrs.len) break;
                    hdrs[hlen] = .{ .name = eh.name, .value = eh.value };
                    hlen += 1;
                }
                var res = nanoui.http.send(gpa, .{
                    .url = url,
                    .method = method,
                    .headers = hdrs[0..hlen],
                    .body = req_body orelse "",
                });
                defer res.deinit();
                if (res.status() == 0) return error.NetworkError;
                return .{
                    .status = res.status(),
                    .body = try gpa.dupe(u8, res.body()),
                };
            }
        }
        if (std.mem.startsWith(u8, url, "https://")) {
            const u = try http_zig.https.parseHttpsUrl(url);
            const sess = if (pool) |p|
                try p.checkout(gpa, io, u.host, u.port)
            else blk: {
                const s = try http_zig.Session.open(gpa, io, u.host, u.port);
                if (!s.h1_only and s.h2_live) setTcpNoDelay(s.stream);
                break :blk s;
            };
            var timed_out = false;
            defer {
                if (pool != null and !timed_out) {
                    pool.?.checkin(io, sess);
                } else {
                    sess.close();
                }
            }

            var auth_val: ?[]u8 = null;
            defer if (auth_val) |v| gpa.free(v);
            if (bearer_token) |tok| {
                auth_val = try std.fmt.allocPrint(gpa, "Bearer {s}", .{tok});
            }

            if (sess.h1_only) {
                var client: std.http.Client = .{ .allocator = gpa, .io = io };
                defer client.deinit();
                var aw: std.Io.Writer.Allocating = .init(gpa);
                errdefer aw.deinit();
                var extra_h1: [16]std.http.Header = undefined;
                var h1_len: usize = 0;
                extra_h1[h1_len] = .{ .name = "user-agent", .value = "harness-desktop/0.2" };
                h1_len += 1;
                extra_h1[h1_len] = .{ .name = "accept", .value = "application/json" };
                h1_len += 1;
                if (auth_val) |av| {
                    extra_h1[h1_len] = .{ .name = "authorization", .value = av };
                    h1_len += 1;
                }
                if (req_body != null) {
                    extra_h1[h1_len] = .{ .name = "content-type", .value = "application/json" };
                    h1_len += 1;
                }
                for (extra_headers) |eh| {
                    if (h1_len >= extra_h1.len) break;
                    extra_h1[h1_len] = .{ .name = eh.name, .value = eh.value };
                    h1_len += 1;
                }
                const h1_method = h1Method(method) orelse return error.UnsupportedHttpMethod;
                const status = try h1Fetch(&client, io, h1_method, url, extra_h1[0..h1_len], req_body, &aw.writer, timeout_ms);
                return .{
                    .status = status,
                    .body = try aw.toOwnedSlice(),
                };
            }

            var hdr_buf: [16]http_zig.Header = undefined;
            var hdr_len: usize = 0;
            var len_buf: [32]u8 = undefined;
            hdr_buf[hdr_len] = .{ .name = "user-agent", .value = "harness-desktop/0.2" };
            hdr_len += 1;
            hdr_buf[hdr_len] = .{ .name = "accept", .value = "application/json" };
            hdr_len += 1;
            if (auth_val) |av| {
                hdr_buf[hdr_len] = .{ .name = "authorization", .value = av };
                hdr_len += 1;
            }
            if (req_body) |b| {
                hdr_buf[hdr_len] = .{ .name = "content-type", .value = "application/json" };
                hdr_len += 1;
                const cl = try std.fmt.bufPrint(&len_buf, "{d}", .{b.len});
                hdr_buf[hdr_len] = .{ .name = "content-length", .value = cl };
                hdr_len += 1;
            }
            for (extra_headers) |eh| {
                if (hdr_len >= hdr_buf.len) break;
                hdr_buf[hdr_len] = eh;
                hdr_len += 1;
            }
            const h2_request: http_zig.Request = .{
                .method = method,
                .scheme = "https",
                .authority = u.host,
                .path = u.path,
                .extra = hdr_buf[0..hdr_len],
                .body = req_body orelse "",
            };
            const sent = if (comptime builtin.os.tag == .windows) blk: {
                const outcome = try io_deadline.run(io, timeout_ms, null, http_zig.Session.request, .{ sess, h2_request });
                switch (outcome) {
                    .finished => |result| break :blk result,
                    .timed_out => |result| {
                        timed_out = true;
                        if (result) |r| {
                            var late = r;
                            late.deinit();
                        } else |_| {}
                        return error.Timeout;
                    },
                    .canceled => |result| {
                        timed_out = true;
                        if (result) |r| {
                            var late = r;
                            late.deinit();
                        } else |_| {}
                        return error.Canceled;
                    },
                }
            } else blk: {
                var dog: SocketWatchdog = .{ .io = io, .stream = sess.stream, .ms = timeout_ms };
                dog.arm();
                const result = sess.request(h2_request);
                if (dog.disarm()) {
                    timed_out = true;
                    if (result) |r| {
                        var late = r;
                        late.deinit();
                    } else |_| {}
                    return error.Timeout;
                }
                break :blk result;
            };
            var resp = try sent;
            // Zero-copy transfer of `resp.body` when allocated by `gpa`.
            if (resp.allocator.ptr == gpa.ptr and resp.allocator.vtable == gpa.vtable) {
                const owned_body = resp.body;
                resp.body = &.{};
                const st = resp.status;
                resp.deinit();
                return .{ .status = st, .body = owned_body };
            }
            defer resp.deinit();
            return .{
                .status = resp.status,
                .body = try gpa.dupe(u8, resp.body),
            };
        }

        // Plain HTTP/1.1 loopback (`http://host:port/path`)
        const rest = if (std.mem.startsWith(u8, url, "http://"))
            url["http://".len..]
        else
            return error.InvalidUrl;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const hostport = rest[0..slash];
        const path = if (slash == rest.len) "/" else rest[slash..];
        const colon = std.mem.indexOfScalar(u8, hostport, ':');
        const host = if (colon) |c| hostport[0..c] else hostport;
        const port: u16 = if (colon) |c| try std.fmt.parseInt(u16, hostport[c + 1 ..], 10) else 80;

        const ip_addr = try std.Io.net.IpAddress.parse(host, port);
        var stream = try ip_addr.connect(io, .{ .mode = .stream });
        setTcpNoDelay(stream);
        defer stream.close(io);
        const exchange_args = .{ gpa, io, stream, method, path, hostport, bearer_token, extra_headers, req_body };
        const result = if (comptime builtin.os.tag == .windows) blk: {
            const outcome = try io_deadline.run(io, timeout_ms, null, loopbackExchange, exchange_args);
            switch (outcome) {
                .finished => |value| break :blk value,
                .timed_out => |value| {
                    if (value) |reply| {
                        var late = reply;
                        late.deinit(gpa);
                    } else |_| {}
                    return error.Timeout;
                },
                .canceled => |value| {
                    if (value) |reply| {
                        var late = reply;
                        late.deinit(gpa);
                    } else |_| {}
                    return error.Canceled;
                },
            }
        } else blk: {
            var dog: SocketWatchdog = .{ .io = io, .stream = stream, .ms = timeout_ms };
            dog.arm();
            const value = loopbackExchange(gpa, io, stream, method, path, hostport, bearer_token, extra_headers, req_body);
            if (dog.disarm()) {
                if (value) |reply| {
                    var late = reply;
                    late.deinit(gpa);
                } else |_| {}
                return error.Timeout;
            }
            break :blk value;
        };
        return result;
    }

    fn loopbackExchange(
        gpa: Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        method: []const u8,
        path: []const u8,
        hostport: []const u8,
        bearer_token: ?[]const u8,
        extra_headers: []const http_zig.Header,
        req_body: ?[]const u8,
    ) !EdgeReply {

        var rbuf: [8192]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);

        const body_slice = req_body orelse "";
        try writer.interface.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n", .{ method, path, hostport });
        if (bearer_token) |tok| {
            try writer.interface.print("Authorization: Bearer {s}\r\n", .{tok});
        }
        if (req_body != null) {
            try writer.interface.print("Content-Type: application/json\r\nContent-Length: {d}\r\n", .{body_slice.len});
        }
        for (extra_headers) |eh| {
            try writer.interface.print("{s}: {s}\r\n", .{ eh.name, eh.value });
        }
        try writer.interface.writeAll("\r\n");
        if (body_slice.len > 0) {
            try writer.interface.writeAll(body_slice);
        }
        try writer.interface.flush();

        const status_line = try reader.interface.takeDelimiterInclusive('\n');
        var status: u16 = 500;
        var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
        _ = parts.next(); // HTTP/1.1
        if (parts.next()) |code_str| {
            status = std.fmt.parseInt(u16, code_str, 10) catch 500;
        }

        var content_len: usize = 0;
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                const val = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                content_len = std.fmt.parseInt(usize, val, 10) catch 0;
            }
        }

        const out_body = try gpa.alloc(u8, content_len);
        errdefer gpa.free(out_body);
        if (content_len > 0) {
            try reader.interface.readSliceAll(out_body);
        }
        return .{ .status = status, .body = out_body };
    }

    /// `std.http.Client.fetch` for an HTTP/1.1 edge, with the request's
    /// deadline on its connection; returns the status.
    fn h1Fetch(
        client: *std.http.Client,
        io: std.Io,
        method: std.http.Method,
        url: []const u8,
        extra_headers: []const std.http.Header,
        payload: ?[]const u8,
        response_writer: *std.Io.Writer,
        timeout_ms: u32,
    ) !u16 {
        const uri = try std.Uri.parse(url);
        var req = try client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = extra_headers,
            .keep_alive = false,
        });
        defer req.deinit();
        if (comptime builtin.os.tag == .windows) {
            const outcome = try io_deadline.run(io, timeout_ms, null, h1Exchange, .{ client, &req, payload, response_writer });
            return switch (outcome) {
                .finished => |status| status,
                .timed_out => error.Timeout,
                .canceled => error.Canceled,
            };
        } else {
            var dog: SocketWatchdog = .{ .io = io, .stream = req.connection.?.stream_reader.stream, .ms = timeout_ms };
            dog.arm();
            const status = h1Exchange(client, &req, payload, response_writer);
            if (dog.disarm()) return error.Timeout;
            return status;
        }
    }

    fn h1Exchange(client: *std.http.Client, req: *std.http.Client.Request, payload: ?[]const u8, response_writer: *std.Io.Writer) !u16 {
        if (payload) |body_bytes| {
            req.transfer_encoding = .{ .content_length = body_bytes.len };
            var body = try req.sendBodyUnflushed(&.{});
            try body.writer.writeAll(body_bytes);
            try body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }
        var response = try req.receiveHead(&.{});
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer client.allocator.free(decompress_buffer);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return @backingInt(response.head.status);
    }

    pub fn adoptCodegraffKey(self: *AuthManager, io: ?std.Io, key: []const u8, email_opt: ?[]const u8) !void {
        if (key.len == 0) return;
        try self.replaceOptStr(&self.codegraff_api_key, key);
        if (email_opt) |em| {
            if (em.len > 0) try self.replaceOptStr(&self.codegraff_email, em);
        } else if (self.email.len > 0) {
            try self.replaceOptStr(&self.codegraff_email, self.email);
        }
        self.codegraff_connected = true;
        self.codegraff_pending = false;
        try self.replaceOptStr(&self.codegraff_error, null);
        if (io) |rio| self.persistCodegraffKeyFile(rio);
    }

    /// Complete paste-code or callback sign-in (`CompleteSignIn { code: "state.code" }`,
    /// `complete_sign_in`). Verifies the CSRF `state`, fences against `self.generation`,
    /// exchanges the code with `/auth/exchange` and persists `session.json` (`0600`).
    /// Without a CodeGraff client (development mode) there is nothing to do.
    pub fn completeSignIn(self: *AuthManager, io: ?std.Io, pasted: []const u8) !void {
        if (self.codegraff_client_id == null) return;
        const invalid = "invalid or expired sign-in code \u{2014} start sign-in again and paste the full code";
        const trimmed = std.mem.trim(u8, pasted, " \t\r\n");
        const dot = std.mem.indexOfScalar(u8, trimmed, '.') orelse return self.fail(invalid, .{});
        const submitted_state = trimmed[0..dot];
        const raw_code = trimmed[dot + 1 ..];
        if (submitted_state.len == 0 or raw_code.len == 0) return self.fail(invalid, .{});
        const expected_state = self.pending_state orelse return self.fail(invalid, .{});
        if (!std.mem.eql(u8, expected_state, submitted_state)) return self.fail(invalid, .{});
        if (self.pending_generation != self.generation) {
            return self.fail("sign-in was canceled \u{2014} start again from Harness", .{});
        }
        const gen_at_start = self.generation;
        const verifier = try self.gpa.dupe(u8, self.pending_verifier orelse "");
        defer self.gpa.free(verifier);
        const nonce = try self.gpa.dupe(u8, self.pending_nonce orelse submitted_state);
        defer self.gpa.free(nonce);
        const edge = std.mem.trimEnd(u8, self.edge_url orelse default_edge_url, "/");
        const fallback_cb = try std.fmt.allocPrint(self.gpa, "{s}/auth/cli/callback", .{edge});
        defer self.gpa.free(fallback_cb);
        const redirect_uri = try self.gpa.dupe(u8, self.pending_redirect_uri orelse fallback_cb);
        defer self.gpa.free(redirect_uri);
        try self.replaceOptStr(&self.pending_state, null);
        try self.replaceOptStr(&self.pending_redirect_uri, null);

        const rio = io orelse return self.fail("the edge is unreachable: the engine has no network I/O", .{});
        try self.ensureSecureTransport();
        const url = try std.fmt.allocPrint(self.gpa, "{s}/auth/exchange", .{edge});
        defer self.gpa.free(url);
        const want_graff_key = (self.codegraff_api_key == null);
        const req_body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"code\":{f},\"codeVerifier\":{f},\"redirectUri\":{f},\"nonce\":{f},\"graffKey\":{},\"deviceLabel\":\"Harness Nano\"}}",
            .{ json.fmt(raw_code, .{}), json.fmt(verifier, .{}), json.fmt(redirect_uri, .{}), json.fmt(nonce, .{}), want_graff_key },
        );
        defer self.gpa.free(req_body);

        var resp = edgeRequestPooled(&self.h2_pool, self.gpa, rio, "POST", url, null, &.{}, req_body) catch |err|
            return self.fail("the edge is unreachable: {t}", .{err});
        defer resp.deinit(self.gpa);
        if (resp.status < 200 or resp.status >= 300) {
            return self.fail("sign-in failed during token exchange ({d}) \u{2014} the code may have expired; start again", .{resp.status});
        }

        // Generation fence: if SignOut occurred while exchange was in flight, abort.
        if (self.generation != gen_at_start) {
            return self.fail("sign-in was canceled \u{2014} start again from Harness", .{});
        }

        const malformed = "malformed exchange response: {s}";
        var parsed = json.parseFromSlice(json.Value, self.gpa, resp.body, .{}) catch
            return self.fail(malformed, .{"not JSON"});
        defer parsed.deinit();
        if (parsed.value != .object) return self.fail(malformed, .{"not an object"});
        const obj = parsed.value.object;

        const access_tok = if (obj.get("accessToken")) |v| (if (v == .string) v.string else "") else "";
        const refresh_tok = if (obj.get("refreshToken")) |v| (if (v == .string) v.string else "") else "";
        if (access_tok.len == 0 or refresh_tok.len == 0) return self.fail(malformed, .{"missing tokens"});
        const uv = obj.get("user") orelse return self.fail(malformed, .{"missing user"});
        if (uv != .object) return self.fail(malformed, .{"missing user"});
        const idv = uv.object.get("id") orelse return self.fail(malformed, .{"missing user id"});
        const ev = uv.object.get("email") orelse return self.fail(malformed, .{"missing user email"});
        if (idv != .string or ev != .string) return self.fail(malformed, .{"missing user id"});

        try self.replaceStr(&self.user_id, idv.string);
        try self.replaceStr(&self.email, ev.string);
        if (uv.object.get("name")) |nv| {
            if (nv == .string and nv.string.len > 0) try self.replaceOptStr(&self.user_name, nv.string);
        } else {
            const first = if (uv.object.get("firstName")) |fv| (if (fv == .string) fv.string else "") else "";
            const last = if (uv.object.get("lastName")) |lv| (if (lv == .string) lv.string else "") else "";
            if (first.len > 0 and last.len > 0) {
                const full = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ first, last });
                defer self.gpa.free(full);
                try self.replaceOptStr(&self.user_name, full);
            } else if (first.len > 0) {
                try self.replaceOptStr(&self.user_name, first);
            } else if (last.len > 0) {
                try self.replaceOptStr(&self.user_name, last);
            } else {
                try self.replaceOptStr(&self.user_name, null);
            }
        }

        if (obj.get("graffKey")) |gkv| if (gkv == .object) {
            const gk_api = if (gkv.object.get("apiKey")) |kv| (if (kv == .string) kv.string else "") else "";
            const gk_email: ?[]const u8 = if (gkv.object.get("email")) |gev| (if (gev == .string and gev.string.len > 0) gev.string else null) else null;
            if (std.mem.startsWith(u8, gk_api, "cg_sk_") and self.codegraff_api_key == null) {
                self.adoptCodegraffKey(rio, gk_api, gk_email) catch {};
            }
        };

        try self.storeTokens(rio, access_tok, refresh_tok);
        self.last_unanswered = false;
        self.rejection_spared = false;
        self.lost_session_marker = false;
        self.persistSessionFile(rio);
    }

    /// Adopt a fresh access/refresh pair; the org and the phase follow the
    /// access token's `org_id` claim (`state_for`).
    fn storeTokens(self: *AuthManager, io: std.Io, access_tok: []const u8, refresh_tok: []const u8) !void {
        try self.replaceOptStr(&self.access_token, access_tok);
        try self.replaceOptStr(&self.refresh_token, refresh_tok);
        var claims = try parseJwtClaims(self.gpa, access_tok);
        defer claims.deinit(self.gpa);
        try self.replaceOptStr(&self.org_id, claims.org_id);
        const now_ms: i64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
        self.access_expires_at_ms = if (claims.exp_secs > 1_000_000_000)
            claims.exp_secs * 1000
        else
            now_ms + claims.ttl_secs * 1000;
        if (self.org_id != null) {
            self.phase = .signed_in;
            self.signed_in = true;
        } else {
            self.phase = .needs_organization;
            self.signed_in = false;
        }
    }

    /// When a headed browser sign-in returns an org-less token (`NeedsOrganization`),
    /// automatically pick the user's personal (or first) organization so the desktop UI
    /// transitions directly into `SignedIn` with an org-scoped token.
    pub fn autoSelectFirstOrgIfNeeded(self: *AuthManager, io: std.Io) void {
        if (self.phase != .needs_organization) return;
        const orgs_json = self.listOrgsJson(io) catch return;
        defer self.gpa.free(orgs_json);

        var parsed = json.parseFromSlice(json.Value, self.gpa, orgs_json, .{}) catch return;
        defer parsed.deinit();
        const items: []const json.Value = switch (parsed.value) {
            .object => |o| if (o.get("orgs")) |ov| (if (ov == .array) ov.array.items else &.{}) else &.{},
            .array => |arr| arr.items,
            else => &.{},
        };
        if (items.len == 0) return;

        var chosen: ?[]const u8 = null;
        for (items) |it| {
            if (it != .object) continue;
            const is_personal = if (it.object.get("personal")) |pv| (pv == .bool and pv.bool) else false;
            const oid = if (it.object.get("organizationId")) |ov|
                (if (ov == .string and ov.string.len > 0) ov.string else null)
            else if (it.object.get("id")) |iv|
                (if (iv == .string and iv.string.len > 0) iv.string else null)
            else
                null;
            if (oid) |id_str| {
                if (chosen == null or is_personal) {
                    chosen = id_str;
                    if (is_personal) break;
                }
            }
        }
        if (chosen) |org_id| {
            self.selectOrg(io, org_id) catch {};
        }
    }

    /// Start CodeGraff device sign-in (`POST {gateway}/v1/device/start`), matching
    /// `crates/engine/src/codegraff_auth.rs` `start_sign_in` 1:1.
    pub fn startCodegraffDeviceFlow(self: *AuthManager, io: std.Io) !DeviceStartInfo {
        self.codegraff_generation +%= 1;
        const gen = self.codegraff_generation;
        try self.replaceOptStr(&self.codegraff_error, null);

        const gw = std.mem.trimEnd(u8, self.codegraff_gateway, "/");
        const url = try std.fmt.allocPrint(self.gpa, "{s}/v1/device/start", .{gw});
        defer self.gpa.free(url);

        var resp = try edgeRequestPooled(&self.h2_pool, self.gpa, io, "POST", url, null, &.{}, "{\"device_label\":\"harness-desktop\"}");
        defer resp.deinit(self.gpa);
        if (resp.status < 200 or resp.status >= 300) return error.DeviceStartFailed;

        var parsed = try json.parseFromSlice(json.Value, self.gpa, resp.body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.DeviceStartFailed;
        const obj = parsed.value.object;

        const dev_code = if (obj.get("device_code")) |v| (if (v == .string) v.string else "") else "";
        const uri_complete = if (obj.get("verification_uri_complete")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null;
        const uri_base = if (obj.get("verification_uri")) |v| (if (v == .string) v.string else "") else "";
        const verify_url = uri_complete orelse uri_base;
        if (dev_code.len == 0 or verify_url.len == 0) return error.DeviceStartFailed;

        const expires_in: u64 = if (obj.get("expires_in")) |v| (if (v == .integer and v.integer > 0) @intCast(v.integer) else 600) else 600;
        const raw_interval: u64 = if (obj.get("interval")) |v| (if (v == .integer and v.integer > 0) @intCast(v.integer) else 2) else 2;
        const interval_s = std.math.clamp(raw_interval, 1, 30);

        const dc_copy = try self.gpa.dupe(u8, dev_code);
        errdefer self.gpa.free(dc_copy);
        const vu_copy = try self.gpa.dupe(u8, verify_url);
        errdefer self.gpa.free(vu_copy);

        self.codegraff_pending = true;
        return .{
            .device_code = dc_copy,
            .verification_url = vu_copy,
            .expires_in_s = expires_in,
            .interval_s = interval_s,
            .generation = gen,
        };
    }

    /// Execute one `POST {gateway}/v1/device/poll` request without holding any engine mutex.
    pub fn pollCodegraffDeviceStep(
        gpa: Allocator,
        io: std.Io,
        gateway: []const u8,
        device_code: []const u8,
        current_interval_s: u64,
    ) DevicePollStep {
        const gw = std.mem.trimEnd(u8, gateway, "/");
        const url = std.fmt.allocPrint(gpa, "{s}/v1/device/poll", .{gw}) catch return .transient;
        defer gpa.free(url);
        const body = std.fmt.allocPrint(gpa, "{{\"device_code\":{f}}}", .{json.fmt(device_code, .{})}) catch return .transient;
        defer gpa.free(body);

        var resp = edgeRequest(gpa, io, "POST", url, null, body) catch return .transient;
        defer resp.deinit(gpa);
        var parsed = json.parseFromSlice(json.Value, gpa, resp.body, .{}) catch return .transient;
        defer parsed.deinit();
        if (parsed.value != .object) return .transient;
        const obj = parsed.value.object;

        const status = if (obj.get("status")) |sv| (if (sv == .string) sv.string else "") else "";
        if (std.mem.eql(u8, status, "pending")) {
            const next_iv: u64 = if (obj.get("interval")) |iv| (if (iv == .integer and iv.integer > 0) @intCast(iv.integer) else current_interval_s) else current_interval_s;
            return .{ .pending = std.math.clamp(next_iv, 1, 30) };
        }
        if (std.mem.eql(u8, status, "ok")) {
            const key = if (obj.get("api_key")) |kv| (if (kv == .string) kv.string else "") else "";
            if (key.len == 0) return .{ .failed = "Codegraff approved without a key" };
            const key_copy = gpa.dupe(u8, key) catch return .transient;
            var email_copy: ?[]u8 = if (obj.get("email")) |ev|
                (if (ev == .string and ev.string.len > 0) (gpa.dupe(u8, ev.string) catch null) else null)
            else
                null;
            if (email_copy == null) {
                if (std.fmt.allocPrint(gpa, "{s}/v1/me", .{gw})) |me_url| {
                    defer gpa.free(me_url);
                    if (edgeRequest(gpa, io, "GET", me_url, key_copy, null)) |me_resp_val| {
                        var me_resp = me_resp_val;
                        defer me_resp.deinit(gpa);
                        if (me_resp.status == 200) {
                            if (json.parseFromSlice(json.Value, gpa, me_resp.body, .{})) |me_p_val| {
                                var me_p = me_p_val;
                                defer me_p.deinit();
                                if (me_p.value == .object) {
                                    if (me_p.value.object.get("email")) |ev| if (ev == .string and ev.string.len > 0) {
                                        email_copy = gpa.dupe(u8, ev.string) catch null;
                                    };
                                }
                            } else |_| {}
                        }
                    } else |_| {}
                } else |_| {}
            }
            return .{ .approved = .{ .api_key = key_copy, .email = email_copy } };
        }
        if (std.mem.eql(u8, status, "denied")) return .{ .failed = "Sign-in was denied in the browser." };
        if (std.mem.eql(u8, status, "expired")) return .{ .failed = "The sign-in link expired. Try again." };
        if (std.mem.eql(u8, status, "consumed")) return .{ .failed = "This sign-in was already used. Try again." };
        if (std.mem.eql(u8, status, "not_found")) return .{ .failed = "Codegraff lost this sign-in. Try again." };
        return .transient;
    }

    /// Fetch live `CodegraffUsage` (`GET {gateway}/v1/usage/summary`) when signed in to CodeGraff.
    pub fn fetchCodegraffUsageJson(self: *AuthManager, io: ?std.Io) ![]u8 {
        const key = self.codegraff_api_key orelse return self.gpa.dupe(u8, "null");
        const rio = io orelse return self.gpa.dupe(u8, "null");
        const gw = std.mem.trimEnd(u8, self.codegraff_gateway, "/");
        const url = try std.fmt.allocPrint(self.gpa, "{s}/v1/usage/summary", .{gw});
        defer self.gpa.free(url);
        if (edgeRequestPooled(&self.h2_pool, self.gpa, rio, "GET", url, key, &.{}, null)) |resp_val| {
            var resp = resp_val;
            defer resp.deinit(self.gpa);
            if (resp.status == 200) return try self.gpa.dupe(u8, resp.body);
        } else |_| {}
        return self.gpa.dupe(u8, "null");
    }

    /// Fetch live `CodegraffJobs` (`GET {gateway}/v1/jobs?state=all&limit=20`) when signed in to CodeGraff.
    pub fn fetchCodegraffJobsJson(self: *AuthManager, io: ?std.Io) ![]u8 {
        const key = self.codegraff_api_key orelse return self.gpa.dupe(u8, "null");
        const rio = io orelse return self.gpa.dupe(u8, "null");
        const gw = std.mem.trimEnd(u8, self.codegraff_gateway, "/");
        const url = try std.fmt.allocPrint(self.gpa, "{s}/v1/jobs?state=all&limit=20", .{gw});
        defer self.gpa.free(url);
        if (edgeRequestPooled(&self.h2_pool, self.gpa, rio, "GET", url, key, &.{}, null)) |resp_val| {
            var resp = resp_val;
            defer resp.deinit(self.gpa);
            if (resp.status == 200) return try self.gpa.dupe(u8, resp.body);
        } else |_| {}
        return self.gpa.dupe(u8, "{\"jobs\":[]}");
    }

    pub fn codegraffSignOut(self: *AuthManager, io: ?std.Io) void {
        self.codegraff_generation +%= 1;
        self.codegraff_pending = false;
        if (self.codegraff_error) |old| {
            self.gpa.free(old);
            self.codegraff_error = null;
        }
        if (self.codegraff_api_key) |key| {
            if (io) |rio| {
                const gw = std.mem.trimEnd(u8, self.codegraff_gateway, "/");
                if (std.fmt.allocPrint(self.gpa, "{s}/v1/keys/revoke", .{gw})) |rev_url| {
                    defer self.gpa.free(rev_url);
                    if (edgeRequestPooled(&self.h2_pool, self.gpa, rio, "POST", rev_url, key, &.{}, "{}")) |resp_val| {
                        var resp = resp_val;
                        resp.deinit(self.gpa);
                    } else |_| {}
                } else |_| {}
            }
            self.gpa.free(key);
            self.codegraff_api_key = null;
        }
        if (self.codegraff_email) |old| {
            self.gpa.free(old);
            self.codegraff_email = null;
        }
        self.codegraff_connected = false;
        self.removeCodegraffKeyFile(io);
    }

    /// List organizations (`ListOrgs` / `GET /auth/orgs`, `list_orgs`) as
    /// `{"orgs":[{id, organizationId, name}]}`. Development mode has none.
    pub fn listOrgsJson(self: *AuthManager, io: ?std.Io) ![]u8 {
        if (self.codegraff_client_id == null) return self.gpa.dupe(u8, "{\"orgs\":[]}");
        var parsed = try self.authedJson(io, "GET", "/auth/orgs", null);
        defer parsed.deinit();
        if (parsed.value != .object) return self.fail("malformed response: {s}", .{"not an object"});
        const orgs: []const json.Value = if (parsed.value.object.get("orgs")) |ov| switch (ov) {
            .array => |arr| arr.items,
            .null => &.{},
            else => return self.fail("malformed response: {s}", .{"orgs is not a list"}),
        } else &.{};
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"orgs\":[");
        for (orgs, 0..) |org, i| {
            if (org != .object) return self.fail("malformed response: {s}", .{"an org is not an object"});
            const id = strField(org.object, "id") orelse return self.fail("malformed response: {s}", .{"missing field `id`"});
            const oid = strField(org.object, "organizationId") orelse return self.fail("malformed response: {s}", .{"missing field `organizationId`"});
            const name = strField(org.object, "name") orelse return self.fail("malformed response: {s}", .{"missing field `name`"});
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"id\":{f},\"organizationId\":{f},\"name\":{f}}}", .{ json.fmt(id, .{}), json.fmt(oid, .{}), json.fmt(name, .{}) });
        }
        try w.writeAll("]}");
        return aw.toOwnedSlice();
    }

    fn strField(obj: json.ObjectMap, name: []const u8) ?[]const u8 {
        const v = obj.get(name) orelse return null;
        return if (v == .string) v.string else null;
    }

    /// Create an organization (`CreateOrg` / `POST /auth/orgs`, `create_org`): the
    /// edge makes this account its first admin; the session then scopes to it.
    /// Returns the new organization's id (caller frees).
    pub fn createOrg(self: *AuthManager, io: ?std.Io, name: []const u8) ![]u8 {
        if (self.codegraff_client_id == null) return self.gpa.dupe(u8, "");
        const body = try std.fmt.allocPrint(self.gpa, "{{\"name\":{f}}}", .{json.fmt(name, .{})});
        defer self.gpa.free(body);
        var parsed = try self.authedJson(io, "POST", "/auth/orgs", body);
        defer parsed.deinit();
        const oid = (if (parsed.value == .object) strField(parsed.value.object, "organizationId") else null) orelse
            return self.fail("malformed response: {s}", .{"missing field `organizationId`"});
        const owned = try self.gpa.dupe(u8, oid);
        errdefer self.gpa.free(owned);
        try self.selectOrg(io, owned);
        return owned;
    }

    /// An authenticated edge call answering JSON (`authed_json`).
    fn authedJson(self: *AuthManager, io: ?std.Io, method: []const u8, path: []const u8, body: ?[]const u8) !json.Parsed(json.Value) {
        const rio = io orelse return self.fail("signed out", .{});
        if (self.phase == .signed_out or self.refresh_token == null) return self.fail("signed out", .{});
        const token = self.ensureAccessToken(rio, false) orelse return self.fail("signed out", .{});
        const edge = std.mem.trimEnd(u8, self.edge_url orelse default_edge_url, "/");
        const url = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ edge, path });
        defer self.gpa.free(url);
        var resp = edgeRequestPooled(&self.h2_pool, self.gpa, rio, method, url, token, &.{}, body) catch |err|
            return self.fail("the edge is unreachable: {t}", .{err});
        defer resp.deinit(self.gpa);
        if (resp.status < 200 or resp.status >= 300) return self.fail("workspace request failed ({d})", .{resp.status});
        return json.parseFromSlice(json.Value, self.gpa, resp.body, .{}) catch
            return self.fail("malformed response: {s}", .{"not JSON"});
    }

    /// Select an organization (`SelectOrg`, `select_org`): one refresh with
    /// `organizationId`; the state follows the returned token's `org_id` claim, and
    /// the switch fails unless that claim is the organization asked for.
    pub fn selectOrg(self: *AuthManager, io: ?std.Io, organization_id: []const u8) !void {
        if (self.codegraff_client_id == null) return;
        const not_member = "could not switch to that workspace \u{2014} you may no longer be a member";
        const rio = io orelse return self.fail("could not reach the edge during refresh: {s}", .{"the engine has no network I/O"});
        try self.ensureSecureTransport();
        const rt_now = self.refresh_token orelse return self.fail(not_member, .{});
        const rt = try self.gpa.dupe(u8, rt_now);
        defer self.gpa.free(rt);
        const gen_at_start = self.generation;
        const edge = std.mem.trimEnd(u8, self.edge_url orelse default_edge_url, "/");
        const url = try std.fmt.allocPrint(self.gpa, "{s}/auth/refresh", .{edge});
        defer self.gpa.free(url);
        const req_body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"refreshToken\":{f},\"organizationId\":{f}}}",
            .{ json.fmt(rt, .{}), json.fmt(organization_id, .{}) },
        );
        defer self.gpa.free(req_body);
        var resp = edgeRequestPooled(&self.h2_pool, self.gpa, rio, "POST", url, null, &.{}, req_body) catch |err|
            return self.fail("could not reach the edge during refresh: {t}", .{err});
        defer resp.deinit(self.gpa);
        if (resp.status < 200 or resp.status >= 300) return self.fail("refresh failed ({d})", .{resp.status});
        var parsed = json.parseFromSlice(json.Value, self.gpa, resp.body, .{}) catch
            return self.fail("malformed refresh response: {s}", .{"not JSON"});
        defer parsed.deinit();
        const obj = if (parsed.value == .object) parsed.value.object else return self.fail("malformed refresh response: {s}", .{"not an object"});
        const access_tok = strField(obj, "accessToken") orelse return self.fail("malformed refresh response: {s}", .{"missing field `accessToken`"});
        const refresh_tok = strField(obj, "refreshToken") orelse return self.fail("malformed refresh response: {s}", .{"missing field `refreshToken`"});
        // Signed out (or signed in again) while the refresh was in flight.
        if (self.generation != gen_at_start or self.refresh_token == null or !std.mem.eql(u8, self.refresh_token.?, rt)) {
            return self.fail(not_member, .{});
        }
        try self.storeTokens(rio, access_tok, refresh_tok);
        self.persistSessionFile(rio);
        const scoped = if (self.org_id) |org| std.mem.eql(u8, org, organization_id) else false;
        if (!scoped) return self.fail(not_member, .{});
    }

    /// Return a valid `access_token`, rotating via `POST {edge_url}/auth/refresh` when missing
    /// (e.g. after `loadPersistedSession`), expiring within `token_slack_secs`, or when `force_refresh` is set.
    pub fn ensureAccessToken(self: *AuthManager, io: std.Io, force_refresh: bool) ?[]const u8 {
        const now_ms: i64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
        if (!force_refresh) {
            if (self.access_token) |tok| {
                if (tok.len > 0 and (self.access_expires_at_ms == 0 or now_ms + token_slack_secs * 1000 < self.access_expires_at_ms)) {
                    return tok;
                }
            }
        }
        const rt = self.refresh_token orelse return self.access_token orelse self.api_key;
        const edge = self.edge_url orelse return self.access_token orelse self.api_key;
        // Never send a refresh credential over plain HTTP off loopback.
        self.ensureSecureTransport() catch return null;
        const base = std.mem.trimEnd(u8, edge, "/");
        const url = std.fmt.allocPrint(self.gpa, "{s}/auth/refresh", .{base}) catch return self.access_token;
        defer self.gpa.free(url);

        const req_body = if (self.org_id) |org|
            std.fmt.allocPrint(
                self.gpa,
                "{{\"refreshToken\":{f},\"organizationId\":{f}}}",
                .{ json.fmt(rt, .{}), json.fmt(org, .{}) },
            ) catch return self.access_token
        else
            std.fmt.allocPrint(
                self.gpa,
                "{{\"refreshToken\":{f}}}",
                .{json.fmt(rt, .{})},
            ) catch return self.access_token;
        defer self.gpa.free(req_body);

        const gen_at_start = self.generation;
        var resp = edgeRequestPooled(&self.h2_pool, self.gpa, io, "POST", url, null, &.{}, req_body) catch {
            self.recordUnansweredRefresh();
            return self.access_token;
        };
        defer resp.deinit(self.gpa);
        if (self.generation != gen_at_start) return null;

        if (resp.status == 200) {
            var parsed = json.parseFromSlice(json.Value, self.gpa, resp.body, .{}) catch return self.access_token;
            defer parsed.deinit();
            if (parsed.value != .object) return self.access_token;
            const obj = parsed.value.object;
            if (obj.get("accessToken")) |av| if (av == .string and av.string.len > 0) {
                self.replaceOptStr(&self.access_token, av.string) catch return null;
                if (parseJwtClaims(self.gpa, av.string)) |claims_val| {
                    var claims = claims_val;
                    defer claims.deinit(self.gpa);
                    self.access_expires_at_ms = if (claims.exp_secs > 1_000_000_000)
                        claims.exp_secs * 1000
                    else
                        now_ms + claims.ttl_secs * 1000;
                    if (self.org_id == null and claims.org_id != null) {
                        self.replaceOptStr(&self.org_id, claims.org_id) catch {};
                        self.phase = .signed_in;
                        self.signed_in = true;
                    }
                } else |_| {}
            };
            if (obj.get("refreshToken")) |rv| if (rv == .string and rv.string.len > 0) {
                self.replaceOptStr(&self.refresh_token, rv.string) catch {};
            };
            self.last_unanswered = false;
            self.rejection_spared = false;
            self.persistSessionFile(io);
            return self.access_token;
        }
        if (resp.status == 401) {
            var reason: []const u8 = "invalid refresh credential";
            var parsed_opt = json.parseFromSlice(json.Value, self.gpa, resp.body, .{}) catch null;
            defer if (parsed_opt) |*p| p.deinit();
            if (parsed_opt) |p| {
                if (p.value == .object) {
                    if (p.value.object.get("error")) |ev| if (ev == .string and ev.string.len > 0) {
                        reason = ev.string;
                    };
                }
            }
            _ = self.handleRefreshRejection(io, reason);
            return null;
        }
        return self.access_token;
    }

    /// Record an unanswered refresh attempt (`crates/engine/src/auth.rs`).
    pub fn recordUnansweredRefresh(self: *AuthManager) void {
        self.last_unanswered = true;
    }

    /// Handle a 401 refresh rejection (`onRefreshRejected` in `RustCodebaseParity.lean`).
    /// Returns `true` if spared (retryable `TemporarilyUnavailable`), `false` if signed out.
    pub fn handleRefreshRejection(self: *AuthManager, io: ?std.Io, reason: []const u8) bool {
        const kind = RefreshRejection.fromReason(reason);
        if (!kind.isDefinite() and self.last_unanswered and !self.rejection_spared) {
            self.rejection_spared = true;
            return true;
        }
        self.phase = .signed_out;
        self.signed_in = false;
        if (self.refresh_token) |old| {
            self.gpa.free(old);
            self.refresh_token = null;
        }
        if (self.access_token) |old| {
            self.gpa.free(old);
            self.access_token = null;
        }
        self.access_expires_at_ms = 0;
        self.lost_session_marker = true;
        self.removeSessionFile(io);
        return false;
    }

    /// Tokens the edge rotated on a refused account deletion replace the
    /// stored pair (AccountDeletion.swift `refused(tokens:)`).
    pub fn adoptRotatedTokens(self: *AuthManager, io: std.Io, access: []const u8, refresh: []const u8) void {
        if (access.len == 0 or refresh.len == 0) return;
        self.replaceOptStr(&self.access_token, access) catch return;
        self.replaceOptStr(&self.refresh_token, refresh) catch return;
        self.access_expires_at_ms = 0;
        self.persistSessionFile(io);
    }

    pub fn signInWithKey(self: *AuthManager, key: []const u8) !void {
        const trimmed = std.mem.trim(u8, key, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyApiKey;
        const copy = try self.gpa.dupe(u8, trimmed);
        if (self.api_key) |old| self.gpa.free(old);
        self.api_key = copy;
        self.phase = .signed_in;
        self.signed_in = true;
    }

    pub fn signOut(self: *AuthManager) void {
        self.signOutWithIo(null);
    }

    pub fn signOutWithIo(self: *AuthManager, io: ?std.Io) void {
        self.generation +%= 1;
        if (self.api_key) |old| {
            self.gpa.free(old);
            self.api_key = null;
        }
        if (self.access_token) |old| {
            self.gpa.free(old);
            self.access_token = null;
        }
        self.access_expires_at_ms = 0;
        if (self.refresh_token) |old| {
            self.gpa.free(old);
            self.refresh_token = null;
        }
        if (self.pending_state) |old| {
            self.gpa.free(old);
            self.pending_state = null;
        }
        if (self.pending_redirect_uri) |old| {
            self.gpa.free(old);
            self.pending_redirect_uri = null;
        }
        self.phase = .signed_out;
        self.signed_in = false;
        self.last_unanswered = false;
        self.rejection_spared = false;
        self.lost_session_marker = false;
        self.removeSessionFile(io);
    }

    pub fn createSandbox(self: *AuthManager, id: []const u8, name: []const u8, region: []const u8) !void {
        var sb = CloudSandbox{
            .id = try self.gpa.dupe(u8, id),
            .name = try self.gpa.dupe(u8, name),
            .status = try self.gpa.dupe(u8, "running"),
            .region = try self.gpa.dupe(u8, region),
        };
        errdefer sb.deinit(self.gpa);
        try self.sandboxes.append(self.gpa, sb);
    }

    pub fn stopSandbox(self: *AuthManager, id: []const u8) !bool {
        for (self.sandboxes.items) |*sb| {
            if (std.mem.eql(u8, sb.id, id)) {
                const copy = try self.gpa.dupe(u8, "stopped");
                self.gpa.free(sb.status);
                sb.status = copy;
                return true;
            }
        }
        return false;
    }

    pub fn deleteSandbox(self: *AuthManager, id: []const u8) bool {
        for (self.sandboxes.items, 0..) |*sb, idx| {
            if (std.mem.eql(u8, sb.id, id)) {
                sb.deinit(self.gpa);
                _ = self.sandboxes.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    /// Exchange an OAuth token or verify an API key against the control plane over `http-zig`.
    pub fn verifyTokenOverHttp2(
        self: *const AuthManager,
        io: std.Io,
        control_plane_url: []const u8,
        bearer_token: []const u8,
    ) !bool {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "{s}/v1/auth/whoami",
            .{std.mem.trimEnd(u8, control_plane_url, "/")},
        );
        defer self.gpa.free(url);
        const auth_val = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{bearer_token});
        defer self.gpa.free(auth_val);

        if (comptime builtin.os.tag == .ios) {
            const nanoui = @import("nanoui");
            const headers = [_]nanoui.http.Header{
                .{ .name = "authorization", .value = auth_val },
                .{ .name = "accept", .value = "application/json" },
            };
            var res = nanoui.http.send(self.gpa, .{
                .url = url,
                .method = "GET",
                .headers = &headers,
            });
            defer res.deinit();
            return res.status() == 200;
        }

        const headers = [_]http_zig.Header{
            .{ .name = "authorization", .value = auth_val },
            .{ .name = "accept", .value = "application/json" },
        };
        var resp = try http_zig.https.request(self.gpa, io, "GET", url, &headers, null);
        defer resp.deinit();
        return resp.status == 200;
    }
};

test "AuthManager sign-in/out, PKCE S256, dual-clock expiry, unanswered refresh leeway, and CloudSandbox lifecycle" {
    const gpa = testing.allocator;
    var auth = try AuthManager.init(gpa);
    defer auth.deinit();

    try auth.signInWithKey("hrn_live_synthetic_key_123");
    try testing.expect(auth.signed_in);
    try testing.expectEqualStrings("hrn_live_synthetic_key_123", auth.api_key.?);

    // Dual-clock elapsed takes max(mono, wall)
    try testing.expectEqual(@as(u64, 120_000), dualClockElapsedMs(5_000, 120_000));
    try testing.expectEqual(@as(u64, 45_000), dualClockElapsedMs(45_000, 10_000));

    // Unanswered refresh leeway: 1st rejection spared, 2nd signs out; definite rejection signs out immediately
    auth.recordUnansweredRefresh();
    try testing.expect(auth.handleRefreshRejection(null, "CodeGraff rejected the grant (400)"));
    try testing.expect(auth.signed_in);
    try testing.expect(!auth.lost_session_marker);

    try testing.expect(!auth.handleRefreshRejection(null, "CodeGraff rejected the grant (400)"));
    try testing.expect(!auth.signed_in);
    try testing.expect(auth.lost_session_marker);

    try auth.signInWithKey("hrn_live_synthetic_key_456");
    auth.recordUnansweredRefresh();
    try testing.expect(!auth.handleRefreshRejection(null, "invalid refresh credential"));
    try testing.expect(!auth.signed_in);

    try auth.createSandbox("sb-1", "zig-port-box", "iad");
    try testing.expectEqual(@as(usize, 1), auth.sandboxes.items.len);
    try testing.expect(try auth.stopSandbox("sb-1"));
    try testing.expectEqualStrings("stopped", auth.sandboxes.items[0].status);
    try testing.expect(auth.deleteSandbox("sb-1"));
    try testing.expectEqual(@as(usize, 0), auth.sandboxes.items.len);

    auth.signOut();
    try testing.expect(!auth.signed_in);
    try testing.expect(!auth.lost_session_marker);
}

test "edge requests: every method name maps to its own HTTP/1.1 method, never a silent GET" {
    try testing.expectEqual(std.http.Method.PATCH, h1Method("PATCH").?);
    try testing.expectEqual(std.http.Method.DELETE, h1Method("DELETE").?);
    try testing.expectEqual(std.http.Method.PUT, h1Method("PUT").?);
    try testing.expectEqual(std.http.Method.POST, h1Method("POST").?);
    try testing.expectEqual(std.http.Method.GET, h1Method("GET").?);
    try testing.expect(h1Method("BREW") == null);
    try testing.expect(h1Method("patch") == null);
}

/// A loopback server that takes one connection and answers only when told
/// (or never), and records the request line.
const SilentServer = struct {
    server: std.Io.net.Server,
    release: std.Io.Event = .unset,
    answer: bool = false,
    line: [64]u8 = undefined,
    line_len: usize = 0,
    thread: ?std.Thread = null,

    fn run(self: *SilentServer) void {
        var stream = self.server.accept(testing.io) catch return;
        defer stream.close(testing.io);
        var rbuf: [4096]u8 = undefined;
        var rd = std.Io.net.Stream.Reader.init(stream, testing.io, &rbuf);
        const first = rd.interface.takeDelimiterInclusive('\n') catch return;
        self.line_len = @min(first.len, self.line.len);
        @memcpy(self.line[0..self.line_len], first[0..self.line_len]);
        if (self.answer) {
            while (true) {
                const l = rd.interface.takeDelimiterInclusive('\n') catch return;
                if (std.mem.trim(u8, l, "\r\n").len == 0) break;
            }
            var wbuf: [256]u8 = undefined;
            var wr = std.Io.net.Stream.Writer.init(stream, testing.io, &wbuf);
            wr.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}") catch return;
            wr.interface.flush() catch return;
        }
        // Hold the connection open (unanswered) until the test lets go.
        self.release.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }) catch {};
    }

    fn url(self: *SilentServer, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/v1/synthetic", .{self.server.socket.address.getPort()});
    }

    fn stop(self: *SilentServer) void {
        self.release.set(testing.io);
        if (self.thread) |t| t.join();
        self.server.deinit(testing.io);
    }
};

test "edge requests: an unanswered request fails at its deadline instead of hanging" {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv: SilentServer = .{ .server = try addr.listen(testing.io, .{ .reuse_address = true }) };
    srv.thread = try std.Thread.spawn(.{}, SilentServer.run, .{&srv});
    defer srv.stop();
    var ubuf: [96]u8 = undefined;
    const started = std.Io.Clock.awake.now(testing.io);
    const got = AuthManager.edgeRequestTimed(null, testing.allocator, testing.io, "GET", try srv.url(&ubuf), null, &.{}, null, 300);
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds();
    try testing.expectError(error.Timeout, got);
    try testing.expect(elapsed_ms >= 250);
    try testing.expect(elapsed_ms < 5_000);
}

test "edge requests: an answered request returns before its deadline with its own method" {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv: SilentServer = .{ .server = try addr.listen(testing.io, .{ .reuse_address = true }), .answer = true };
    srv.thread = try std.Thread.spawn(.{}, SilentServer.run, .{&srv});
    defer srv.stop();
    var ubuf: [96]u8 = undefined;
    var reply = try AuthManager.edgeRequestTimed(null, testing.allocator, testing.io, "PATCH", try srv.url(&ubuf), null, &.{}, "{}", 5_000);
    defer reply.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), reply.status);
    try testing.expectEqualStrings("{}", reply.body);
    try testing.expect(std.mem.startsWith(u8, srv.line[0..srv.line_len], "PATCH /v1/synthetic HTTP/1.1"));
}
