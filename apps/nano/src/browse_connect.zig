//! Client for `justrach/browse` Connected Apps (`v1-p256-sig`):
//! loopback-only authenticated MCP + live screenshot viewport over P-256 ECDSA.
//! Zero telemetry, zero Origin headers, and strict `127.0.0.1` binding.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const ux = @import("ux_rules.zig").BrowseConnect;
const Allocator = std.mem.Allocator;

pub const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub const release_url = "https://github.com/justrach/browse/releases/latest";

pub const StyleNode = struct {
    tag: [24]u8 = @splat(0),
    tag_len: usize = 0,
    font_size_px: u32 = 13,
    radius_px: u32 = 8,
    w: u32 = 0,
    h: u32 = 0,
    hit_ok: bool = true,

    pub fn tagSlice(self: *const StyleNode) []const u8 {
        return self.tag[0..self.tag_len];
    }
};

pub const Discovery = struct {
    port: u16,
    browse_key_b64: []u8,
    browse_key_raw: [Ecdsa.PublicKey.uncompressed_sec1_encoded_length]u8,
    pid: u32 = 0,

    pub fn deinit(d: *Discovery, gpa: Allocator) void {
        gpa.free(d.browse_key_b64);
        d.* = .{
            .port = 0,
            .browse_key_b64 = &.{},
            .browse_key_raw = @splat(0),
            .pid = 0,
        };
    }
};

pub const PairInfo = struct {
    client_id: []u8 = &.{},
    code_display: [7]u8 = "000 000".*,
    nonce_hex: [32]u8 = @splat('0'),
    expires_in: u32 = 120,

    pub fn deinit(p: *PairInfo, gpa: Allocator) void {
        if (p.client_id.len > 0) gpa.free(p.client_id);
        p.* = .{};
    }
};

pub const HttpReply = struct {
    status: u16,
    body: []u8,
    sig_b64: ?[]u8 = null,

    pub fn deinit(r: *HttpReply, gpa: Allocator) void {
        gpa.free(r.body);
        if (r.sig_b64) |s| gpa.free(s);
    }
};

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.atomic.Mutex = .unlocked,
    state: ux.ConnState = .waiting_browse_launch,
    installed: bool = false,
    discovery: ?Discovery = null,
    keypair: Ecdsa.KeyPair,
    pair: PairInfo = .{},
    current_url: []u8 = &.{},
    page_title: []u8 = &.{},
    screenshot_png: []u8 = &.{},
    screenshot_seq: u64 = 0,
    last_frame_ms: i64 = 0,
    inspect_nodes: [8]StyleNode = @splat(.{}),
    inspect_count: usize = 0,
    can_back: bool = false,
    can_forward: bool = false,
    last_error: []u8 = &.{},
    session_id: [64]u8 = @splat(0),
    session_len: usize = 0,
    dirty: bool = false,
    busy: bool = false,
    last_poll_ms: i64 = 0,
    shutdown: std.atomic.Value(bool) = .init(false),
    in_flight: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, io: std.Io) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .keypair = Ecdsa.KeyPair.generate(io),
        };
    }

    pub fn deinit(self: *Client) void {
        self.shutdown.store(true, .release);
        while (self.in_flight.load(.acquire)) std.Thread.yield() catch {};
        if (self.discovery) |*d| d.deinit(self.gpa);
        self.pair.deinit(self.gpa);
        if (self.current_url.len > 0) self.gpa.free(self.current_url);
        if (self.page_title.len > 0) self.gpa.free(self.page_title);
        if (self.screenshot_png.len > 0) self.gpa.free(self.screenshot_png);
        if (self.last_error.len > 0) self.gpa.free(self.last_error);
        self.* = undefined;
    }

    pub const AsyncOp = enum { probe, pair, poll_pair, open_url, refresh, back, forward, reload, show, click_at, scroll, type_text, press_key, inspect_styles };

    pub fn spawnOp(self: *Client, op: AsyncOp, url_or_empty: []const u8, x: i32, y: i32) void {
        if (self.shutdown.load(.acquire)) return;
        if (self.in_flight.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        const owned = if (url_or_empty.len > 0) (self.gpa.dupe(u8, url_or_empty) catch {
            self.in_flight.store(false, .release);
            return;
        }) else null;
        const thread = std.Thread.spawn(.{}, workerRun, .{ self, op, owned, x, y }) catch {
            if (owned) |u| self.gpa.free(u);
            self.in_flight.store(false, .release);
            return;
        };
        thread.detach();
    }

    fn workerRun(self: *Client, op: AsyncOp, url_owned: ?[]u8, x: i32, y: i32) void {
        defer {
            if (url_owned) |u| self.gpa.free(u);
            self.in_flight.store(false, .release);
        }
        if (self.shutdown.load(.acquire)) return;
        switch (op) {
            .probe => {
                _ = self.probeDiscovery();
                self.acquire();
                self.dirty = true;
                self.release();
            },
            .pair => {
                self.beginPair() catch |err| {
                    self.acquire();
                    self.setError(@errorName(err));
                    self.release();
                };
            },
            .poll_pair => {
                _ = self.pollPairStatus() catch {};
            },
            .open_url => {
                if (url_owned) |u| {
                    if (self.status() != .connected) _ = self.probeDiscovery();
                    if (self.status() == .connected) {
                        self.openUrlAndCapture(u) catch |err| {
                            self.acquire();
                            self.setError(@errorName(err));
                            self.release();
                        };
                    } else {
                        self.acquire();
                        if (self.current_url.len > 0) self.gpa.free(self.current_url);
                        self.current_url = self.gpa.dupe(u8, u) catch &.{};
                        self.dirty = true;
                        self.release();
                    }
                }
            },
            .refresh => self.refreshScreenshot() catch {},
            .back => {
                if (self.callTool("back", "{}")) |res| {
                    self.gpa.free(res);
                    self.refreshScreenshot() catch {};
                } else |_| {}
            },
            .forward => {
                if (self.callTool("forward", "{}")) |res| {
                    self.gpa.free(res);
                    self.refreshScreenshot() catch {};
                } else |_| {}
            },
            .reload => {
                if (self.callTool("reload", "{}")) |res| {
                    self.gpa.free(res);
                    self.refreshScreenshot() catch {};
                } else |_| {}
            },
            .show => {
                if (self.callTool("show", "{}")) |res| self.gpa.free(res) else |_| {}
            },
            .click_at => {
                var buf: [64]u8 = undefined;
                const args = std.fmt.bufPrint(&buf, "{{\"x\":{d},\"y\":{d}}}", .{ x, y }) catch return;
                if (self.callTool("click_at", args)) |res| {
                    self.gpa.free(res);
                    self.refreshScreenshot() catch {};
                } else |_| {}
            },
            .scroll => {
                var buf: [64]u8 = undefined;
                const args = std.fmt.bufPrint(&buf, "{{\"dx\":{d},\"dy\":{d}}}", .{ x, y }) catch return;
                if (self.callTool("scroll", args)) |res| {
                    self.gpa.free(res);
                    self.refreshScreenshot() catch {};
                } else |_| {}
            },
            .type_text => {
                if (url_owned) |txt| self.typeText(txt) catch {};
            },
            .press_key => {
                if (url_owned) |key_name| self.pressKey(key_name) catch {};
            },
            .inspect_styles => {
                self.refreshDomStyles() catch {};
            },
        }
    }

    pub fn setSession(self: *Client, chat_id: ?[]const u8) void {
        self.acquire();
        defer self.release();
        const prefix = "harness-";
        const cid = chat_id orelse "default";
        const slice = std.fmt.bufPrint(&self.session_id, "{s}{s}", .{ prefix, cid }) catch blk: {
            const avail = self.session_id.len - prefix.len;
            @memcpy(self.session_id[0..prefix.len], prefix);
            @memcpy(self.session_id[prefix.len..], cid[0..avail]);
            break :blk self.session_id[0..];
        };
        self.session_len = slice.len;
    }

    pub fn acquire(self: *Client) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }

    pub fn release(self: *Client) void {
        self.mutex.unlock();
    }

    pub fn status(self: *Client) ux.ConnState {
        self.acquire();
        defer self.release();
        return self.state;
    }

    pub fn lastFrameMs(self: *Client) i64 {
        self.acquire();
        defer self.release();
        return self.last_frame_ms;
    }

    pub fn inFlight(self: *const Client) bool {
        return self.in_flight.load(.acquire);
    }

    pub fn inspectCopy(self: *Client, out: *[8]StyleNode) usize {
        self.acquire();
        defer self.release();
        const n = @min(self.inspect_count, 8);
        @memcpy(out[0..n], self.inspect_nodes[0..n]);
        return n;
    }

    pub fn snapshotCopy(self: *Client, allocator: Allocator) ?struct { png: []u8, seq: u64, title: []u8, url: []u8 } {
        self.acquire();
        defer self.release();
        if (self.screenshot_png.len == 0) return null;
        const png = allocator.dupe(u8, self.screenshot_png) catch return null;
        const title = allocator.dupe(u8, self.page_title) catch {
            allocator.free(png);
            return null;
        };
        const url = allocator.dupe(u8, self.current_url) catch {
            allocator.free(png);
            allocator.free(title);
            return null;
        };
        return .{ .png = png, .seq = self.screenshot_seq, .title = title, .url = url };
    }

    fn setError(self: *Client, msg: []const u8) void {
        if (self.last_error.len > 0) self.gpa.free(self.last_error);
        self.last_error = self.gpa.dupe(u8, msg) catch &.{};
        self.dirty = true;
    }

    /// Detect `browse.app` and read `~/Library/Application Support/browse/Agent/connect.json`.
    pub fn probeDiscovery(self: *Client) ux.ConnState {
        if (comptime builtin.os.tag != .macos) {
            self.acquire();
            defer self.release();
            self.state = .needs_browse_install;
            return self.state;
        }
        const installed = isBrowseInstalled(self.gpa, self.io);
        const disc = readConnectJson(self.gpa, self.io) catch null;

        self.acquire();
        defer self.release();
        self.installed = installed;
        if (disc) |d| {
            const same = if (self.discovery) |old| old.port == d.port and std.mem.eql(u8, old.browse_key_b64, d.browse_key_b64) else false;
            if (!same) {
                if (self.discovery) |*old| old.deinit(self.gpa);
                self.discovery = d;
                if (self.state != .pairing_pending and self.state != .connected) {
                    self.state = .discovered;
                }
            } else {
                var dup = d;
                dup.deinit(self.gpa);
            }
        } else {
            if (self.discovery) |*old| old.deinit(self.gpa);
            self.discovery = null;
            self.state = if (installed) .waiting_browse_launch else .needs_browse_install;
        }
        return self.state;
    }

    pub fn beginPair(self: *Client) !void {
        const has_disc = blk: {
            self.acquire();
            defer self.release();
            break :blk self.discovery != null;
        };
        const st = if (has_disc) self.status() else self.probeDiscovery();
        if (st != .discovered and st != .token_expired and st != .pair_denied) return;

        var nonce_raw: [16]u8 = undefined;
        self.io.random(&nonce_raw);
        var nonce_hex: [32]u8 = undefined;
        hexLower(&nonce_raw, &nonce_hex);

        const pub_raw = self.keypair.public_key.toUncompressedSec1();
        var client_key_b64_buf: [128]u8 = undefined;
        const client_key_b64 = std.base64.standard.Encoder.encode(&client_key_b64_buf, &pub_raw);

        const disc = blk: {
            self.acquire();
            defer self.release();
            const d = self.discovery orelse return error.NotDiscovered;
            break :blk .{ .port = d.port, .browse_raw = d.browse_key_raw };
        };

        const body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"client_key\":\"{s}\",\"name\":\"Harness\",\"nonce\":\"{s}\",\"protocol\":[\"v1-p256-sig\"]}}",
            .{ client_key_b64, nonce_hex },
        );
        defer self.gpa.free(body);

        var reply = try postLoopback(self.gpa, self.io, disc.port, "/pair", &.{}, body);
        defer reply.deinit(self.gpa);
        if (reply.status != 200) {
            self.acquire();
            defer self.release();
            self.setError("Pair request rejected by browse.");
            return error.PairRejected;
        }

        const parsed = try json.parseFromSlice(json.Value, self.gpa, reply.body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const client_id_v = parsed.value.object.get("client_id") orelse return error.InvalidResponse;
        if (client_id_v != .string) return error.InvalidResponse;
        const expires_v = parsed.value.object.get("expires_in");
        const exp: u32 = if (expires_v) |e| (if (e == .integer and e.integer > 0) @intCast(e.integer) else 120) else 120;

        const code = computePairingCode(disc.browse_raw, pub_raw, nonce_raw);
        var formatted: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&formatted, "{d:0>3} {d:0>3}", .{ code / 1000, code % 1000 }) catch unreachable;

        self.acquire();
        defer self.release();
        self.pair.deinit(self.gpa);
        self.pair = .{
            .client_id = try self.gpa.dupe(u8, client_id_v.string),
            .code_display = formatted,
            .nonce_hex = nonce_hex,
            .expires_in = exp,
        };
        self.state = .pairing_pending;
        self.dirty = true;
    }

    pub fn pollPairStatus(self: *Client) !ux.ConnState {
        const ctx = blk: {
            self.acquire();
            defer self.release();
            if (self.state != .pairing_pending) return self.state;
            const d = self.discovery orelse return .waiting_browse_launch;
            const cid = try self.gpa.dupe(u8, self.pair.client_id);
            break :blk .{ .port = d.port, .browse_raw = d.browse_key_raw, .client_id = cid };
        };
        defer self.gpa.free(ctx.client_id);

        const body = try std.fmt.allocPrint(self.gpa, "{{\"client_id\":\"{s}\"}}", .{ctx.client_id});
        defer self.gpa.free(body);

        var reply = try self.signedPost(ctx.port, ctx.browse_raw, "/pair/status", ctx.client_id, body);
        defer reply.deinit(self.gpa);

        if (reply.status == 404 or reply.status == 410) {
            self.acquire();
            defer self.release();
            self.state = ux.nextConnState(self.state, .token_timed_out);
            self.dirty = true;
            return self.state;
        }
        if (reply.status != 200) return self.status();

        const parsed = try json.parseFromSlice(json.Value, self.gpa, reply.body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return self.status();
        const st_v = parsed.value.object.get("status") orelse return self.status();
        if (st_v != .string) return self.status();

        self.acquire();
        defer self.release();
        if (std.mem.eql(u8, st_v.string, "approved")) {
            self.state = ux.nextConnState(self.state, .user_approved);
            self.dirty = true;
        } else if (std.mem.eql(u8, st_v.string, "denied")) {
            self.state = ux.nextConnState(self.state, .user_denied);
            self.dirty = true;
        } else if (std.mem.eql(u8, st_v.string, "expired")) {
            self.state = ux.nextConnState(self.state, .token_timed_out);
            self.dirty = true;
        }
        return self.state;
    }

    pub fn callTool(self: *Client, tool_name: []const u8, args_json: []const u8) ![]u8 {
        const ctx = blk: {
            self.acquire();
            defer self.release();
            if (!ux.mcpCallsPermitted(self.state)) return error.NotConnected;
            const d = self.discovery orelse return error.NotDiscovered;
            const cid = try self.gpa.dupe(u8, self.pair.client_id);
            const sess = try self.gpa.dupe(u8, if (self.session_len > 0) self.session_id[0..self.session_len] else "harness-default");
            break :blk .{ .port = d.port, .browse_raw = d.browse_key_raw, .client_id = cid, .session = sess };
        };
        defer self.gpa.free(ctx.client_id);
        defer self.gpa.free(ctx.session);

        const rpc_body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s},\"_meta\":{{\"browse/session\":\"{s}\"}}}}}}",
            .{ tool_name, args_json, ctx.session },
        );
        defer self.gpa.free(rpc_body);

        var reply = try self.signedPost(ctx.port, ctx.browse_raw, "/mcp", ctx.client_id, rpc_body);
        errdefer reply.deinit(self.gpa);
        if (reply.status == 401 or reply.status == 403) {
            self.acquire();
            self.state = ux.nextConnState(self.state, .revoked);
            self.dirty = true;
            self.release();
            return error.AuthRevoked;
        }
        const owned = reply.body;
        if (reply.sig_b64) |s| self.gpa.free(s);
        return owned;
    }

    pub fn openUrlAndCapture(self: *Client, url: []const u8) !void {
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(self.gpa);
        try jsonStringEscape(&escaped, self.gpa, url);
        const args = try std.fmt.allocPrint(self.gpa, "{{\"url\":{s}}}", .{escaped.items});
        defer self.gpa.free(args);

        const res = try self.callTool("open", args);
        self.gpa.free(res);
        self.acquire();
        if (self.current_url.len > 0) self.gpa.free(self.current_url);
        self.current_url = try self.gpa.dupe(u8, url);
        self.release();
        try self.refreshScreenshot();
    }

    pub fn refreshScreenshot(self: *Client) !void {
        const res = try self.callTool("screenshot", "{}");
        defer self.gpa.free(res);
        const decoded = decodeMcpImagePng(self.gpa, res) orelse return;
        const ts_ms = std.Io.Clock.Timestamp.now(self.io, .real).raw.toMilliseconds();
        self.acquire();
        defer self.release();
        if (self.screenshot_png.len > 0) self.gpa.free(self.screenshot_png);
        self.screenshot_png = decoded;
        self.screenshot_seq +%= 1;
        self.last_frame_ms = ts_ms;
        self.dirty = true;
    }

    pub fn typeText(self: *Client, txt: []const u8) !void {
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(self.gpa);
        try jsonStringEscape(&escaped, self.gpa, txt);
        const args = try std.fmt.allocPrint(self.gpa, "{{\"text\":{s}}}", .{escaped.items});
        defer self.gpa.free(args);
        const res = try self.callTool("type", args);
        self.gpa.free(res);
        self.refreshScreenshot() catch {};
    }

    pub fn pressKey(self: *Client, key: []const u8) !void {
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(self.gpa);
        try jsonStringEscape(&escaped, self.gpa, key);
        const args = try std.fmt.allocPrint(self.gpa, "{{\"key\":{s}}}", .{escaped.items});
        defer self.gpa.free(args);
        const res = try self.callTool("press_key", args);
        self.gpa.free(res);
        self.refreshScreenshot() catch {};
    }

    pub fn refreshDomStyles(self: *Client) !void {
        const script =
            "Array.from(document.querySelectorAll('button,a,input,h1,h2,section,.card')).slice(0,8).map(el=>{const cs=getComputedStyle(el);const r=el.getBoundingClientRect();return{tag:el.tagName.toLowerCase(),fontSize:parseInt(cs.fontSize)||13,borderRadius:parseInt(cs.borderRadius)||0,w:Math.round(r.width),h:Math.round(r.height)};})";
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(self.gpa);
        try jsonStringEscape(&escaped, self.gpa, script);
        const args = try std.fmt.allocPrint(self.gpa, "{{\"script\":{s}}}", .{escaped.items});
        defer self.gpa.free(args);
        const res = try self.callTool("evaluate_js", args);
        defer self.gpa.free(res);
        var parsed_nodes: [8]StyleNode = @splat(.{});
        const count = parseStyleNodesJson(self.gpa, res, &parsed_nodes);
        self.acquire();
        defer self.release();
        @memcpy(self.inspect_nodes[0..count], parsed_nodes[0..count]);
        self.inspect_count = count;
        self.dirty = true;
    }

    fn signedPost(
        self: *Client,
        port: u16,
        browse_key_raw: [Ecdsa.PublicKey.uncompressed_sec1_encoded_length]u8,
        path: []const u8,
        client_id: []const u8,
        body: []const u8,
    ) !HttpReply {
        var nonce_raw: [16]u8 = undefined;
        self.io.random(&nonce_raw);
        var nonce_hex: [32]u8 = undefined;
        hexLower(&nonce_raw, &nonce_hex);

        const ts_ms = std.Io.Clock.Timestamp.now(self.io, .real).raw.toMilliseconds();
        var ts_buf: [32]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts_ms});

        var body_digest: [32]u8 = undefined;
        Sha256.hash(body, &body_digest, .{});
        var body_hex: [64]u8 = undefined;
        hexLower(&body_digest, &body_hex);

        const canonical = try canonicalSignString(self.gpa, path, &body_hex, ts_str, &nonce_hex, client_id);
        defer self.gpa.free(canonical);

        const sig = try self.keypair.sign(canonical, null);
        var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
        const der = sig.toDer(&der_buf);
        var sig_b64_buf: [160]u8 = undefined;
        const sig_b64 = std.base64.standard.Encoder.encode(&sig_b64_buf, der);

        const hdrs = [_]HeaderPair{
            .{ .name = "X-Client-Id", .value = client_id },
            .{ .name = "X-Timestamp", .value = ts_str },
            .{ .name = "X-Nonce", .value = &nonce_hex },
            .{ .name = "X-Signature", .value = sig_b64 },
        };

        var reply = try postLoopback(self.gpa, self.io, port, path, &hdrs, body);
        errdefer reply.deinit(self.gpa);

        if (reply.sig_b64) |srv_sig| {
            try verifyResponseSignature(self.gpa, browse_key_raw, reply.body, &nonce_hex, srv_sig);
        }
        return reply;
    }
};

pub const HeaderPair = struct { name: []const u8, value: []const u8 };

pub fn canonicalSignString(
    gpa: Allocator,
    path: []const u8,
    body_sha256_hex: []const u8,
    timestamp_ms: []const u8,
    nonce_hex: []const u8,
    client_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "POST|{s}|{s}|{s}|{s}|{s}",
        .{ path, body_sha256_hex, timestamp_ms, nonce_hex, client_id },
    );
}

pub fn computePairingCode(
    browse_key_raw: [65]u8,
    client_key_raw: [65]u8,
    nonce_raw: [16]u8,
) u32 {
    var h = Sha256.init(.{});
    h.update(&browse_key_raw);
    h.update(&client_key_raw);
    h.update(&nonce_raw);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const be32 = std.mem.readInt(u32, digest[0..4], .big);
    return ux.pairingCode(be32);
}

pub fn verifyResponseSignature(
    gpa: Allocator,
    browse_key_raw: [65]u8,
    resp_body: []const u8,
    req_nonce_hex: []const u8,
    resp_sig_b64: []const u8,
) !void {
    const pk = try Ecdsa.PublicKey.fromSec1(&browse_key_raw);
    const der_len = try std.base64.standard.Decoder.calcSizeForSlice(resp_sig_b64);
    const der = try gpa.alloc(u8, der_len);
    defer gpa.free(der);
    try std.base64.standard.Decoder.decode(der, resp_sig_b64);
    const sig = try Ecdsa.Signature.fromDer(der);

    var digest: [32]u8 = undefined;
    Sha256.hash(resp_body, &digest, .{});
    var hex: [64]u8 = undefined;
    hexLower(&digest, &hex);

    const msg = try std.fmt.allocPrint(gpa, "{s}|{s}", .{ hex, req_nonce_hex });
    defer gpa.free(msg);
    try sig.verify(msg, pk);
}

pub fn hexLower(src: []const u8, dst: []u8) void {
    const digits = "0123456789abcdef";
    for (src, 0..) |b, i| {
        dst[i * 2] = digits[b >> 4];
        dst[i * 2 + 1] = digits[b & 0x0F];
    }
}

pub fn parseConnectJson(gpa: Allocator, data: []const u8) !Discovery {
    const parsed = try json.parseFromSlice(json.Value, gpa, data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConnectJson;
    const obj = parsed.value.object;
    const port_v = obj.get("port") orelse return error.InvalidConnectJson;
    if (port_v != .integer or port_v.integer <= 0 or port_v.integer > 65535) return error.InvalidConnectJson;
    const key_v = obj.get("browse_key") orelse return error.InvalidConnectJson;
    if (key_v != .string) return error.InvalidConnectJson;

    const raw_len = try std.base64.standard.Decoder.calcSizeForSlice(key_v.string);
    if (raw_len != Ecdsa.PublicKey.uncompressed_sec1_encoded_length) return error.InvalidBrowseKeyLength;
    var raw: [Ecdsa.PublicKey.uncompressed_sec1_encoded_length]u8 = undefined;
    try std.base64.standard.Decoder.decode(&raw, key_v.string);
    _ = try Ecdsa.PublicKey.fromSec1(&raw);

    const pid_val: u32 = if (obj.get("pid")) |pv| (if (pv == .integer and pv.integer > 0) @intCast(pv.integer) else 0) else 0;
    return .{
        .port = @intCast(port_v.integer),
        .browse_key_b64 = try gpa.dupe(u8, key_v.string),
        .browse_key_raw = raw,
        .pid = pid_val,
    };
}

pub fn readConnectJson(gpa: Allocator, io: std.Io) !Discovery {
    if (comptime builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    const path = try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/browse/Agent/connect.json", .{std.mem.span(home)});
    defer gpa.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024));
    defer gpa.free(data);
    return parseConnectJson(gpa, data);
}

pub fn isBrowseInstalled(gpa: Allocator, io: std.Io) bool {
    if (comptime builtin.os.tag != .macos) return false;
    std.Io.Dir.accessAbsolute(io, "/Applications/browse.app", .{}) catch {
        const home = std.c.getenv("HOME") orelse return false;
        const user_app = std.fmt.allocPrint(gpa, "{s}/Applications/browse.app", .{std.mem.span(home)}) catch return false;
        defer gpa.free(user_app);
        std.Io.Dir.accessAbsolute(io, user_app, .{}) catch return false;
        return true;
    };
    return true;
}

pub fn launchBrowseApp(io: std.Io) void {
    if (comptime builtin.os.tag != .macos) return;
    _ = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/open", "-a", "browse" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {};
}

fn postLoopback(
    gpa: Allocator,
    io: std.Io,
    port: u16,
    path: []const u8,
    extra_headers: []const HeaderPair,
    body: []const u8,
) !HttpReply {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rbuf: [8192]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);

    // Explicitly NO `Origin` header (`Nano.BrowseConnect.origin_header_always_rejected`).
    try writer.interface.print(
        "POST {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n",
        .{ path, port, body.len },
    );
    for (extra_headers) |h| {
        try writer.interface.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try writer.interface.writeAll("\r\n");
    if (body.len > 0) try writer.interface.writeAll(body);
    try writer.interface.flush();

    const status_line = try reader.interface.takeDelimiterInclusive('\n');
    var status_code: u16 = 500;
    var it = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = it.next();
    if (it.next()) |s| status_code = std.fmt.parseInt(u16, s, 10) catch 500;

    var content_len: usize = 0;
    var sig_b64: ?[]u8 = null;
    errdefer if (sig_b64) |s| gpa.free(s);

    while (true) {
        const line = try reader.interface.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const val = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_len = std.fmt.parseInt(usize, val, 10) catch 0;
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "x-signature:")) {
            const val = std.mem.trim(u8, trimmed["x-signature:".len..], " \t");
            if (sig_b64) |old| gpa.free(old);
            sig_b64 = try gpa.dupe(u8, val);
        }
    }

    const capped = @min(content_len, 16 * 1024 * 1024);
    const out_body = try gpa.alloc(u8, capped);
    errdefer gpa.free(out_body);
    if (capped > 0) try reader.interface.readSliceAll(out_body);

    return .{ .status = status_code, .body = out_body, .sig_b64 = sig_b64 };
}

fn decodeMcpImagePng(gpa: Allocator, mcp_json: []const u8) ?[]u8 {
    const parsed = json.parseFromSlice(json.Value, gpa, mcp_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const content = result.object.get("content") orelse return null;
    if (content != .array) return null;
    for (content.array.items) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "image")) continue;
        const data_v = item.object.get("data") orelse continue;
        if (data_v != .string) continue;
        const raw_len = std.base64.standard.Decoder.calcSizeForSlice(data_v.string) catch continue;
        const buf = gpa.alloc(u8, raw_len) catch return null;
        std.base64.standard.Decoder.decode(buf, data_v.string) catch {
            gpa.free(buf);
            continue;
        };
        return buf;
    }
    return null;
}

fn jsonStringEscape(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

pub fn parseStyleNodesJson(gpa: Allocator, mcp_json: []const u8, out: *[8]StyleNode) usize {
    const outer = json.parseFromSlice(json.Value, gpa, mcp_json, .{}) catch return 0;
    defer outer.deinit();
    if (outer.value != .object) return 0;
    const result = outer.value.object.get("result") orelse return 0;
    if (result != .object) return 0;
    const content = result.object.get("content") orelse return 0;
    if (content != .array) return 0;
    for (content.array.items) |item| {
        if (item != .object) continue;
        const tp = item.object.get("type") orelse continue;
        if (tp != .string or !std.mem.eql(u8, tp.string, "text")) continue;
        const txt = item.object.get("text") orelse continue;
        if (txt != .string) continue;
        const arr_parsed = json.parseFromSlice(json.Value, gpa, txt.string, .{}) catch continue;
        defer arr_parsed.deinit();
        if (arr_parsed.value != .array) continue;
        var count: usize = 0;
        for (arr_parsed.value.array.items) |elem| {
            if (count >= 8) break;
            if (elem != .object) continue;
            const o = elem.object;
            var node: StyleNode = .{};
            if (o.get("tag")) |tv| if (tv == .string) {
                const n = @min(tv.string.len, node.tag.len);
                @memcpy(node.tag[0..n], tv.string[0..n]);
                node.tag_len = n;
            };
            if (o.get("fontSize")) |fv| if (fv == .integer and fv.integer > 0) {
                node.font_size_px = @intCast(fv.integer);
            };
            if (o.get("borderRadius")) |rv| if (rv == .integer and rv.integer >= 0) {
                node.radius_px = @intCast(rv.integer);
            };
            if (o.get("w")) |wv| if (wv == .integer and wv.integer >= 0) {
                node.w = @intCast(wv.integer);
            };
            if (o.get("h")) |hv| if (hv == .integer and hv.integer >= 0) {
                node.h = @intCast(hv.integer);
            };
            node.hit_ok = (node.w == 0 and node.h == 0) or (node.w >= 32 and node.h >= 32);
            out[count] = node;
            count += 1;
        }
        return count;
    }
    return 0;
}

test "browse Connected Apps P-256 X9.63 key, DER sign+verify, 6-digit code, and routing" {
    try std.testing.expectEqual(ux.BrowserRoute.local_saved_view, ux.routeUrl("graff-view://html/abc"));
    try std.testing.expectEqual(ux.BrowserRoute.external_browse, ux.routeUrl("https://github.com/justrach/browse"));
    try std.testing.expectEqual(ux.BrowserRoute.external_browse, ux.routeUrl("http://localhost:3000"));

    const client_seed: [Ecdsa.KeyPair.seed_length]u8 = @splat(0x11);
    const browse_seed: [Ecdsa.KeyPair.seed_length]u8 = @splat(0x22);
    const client_kp = try Ecdsa.KeyPair.generateDeterministic(client_seed);
    const browse_kp = try Ecdsa.KeyPair.generateDeterministic(browse_seed);

    const client_x963 = client_kp.public_key.toUncompressedSec1();
    const browse_x963 = browse_kp.public_key.toUncompressedSec1();
    try std.testing.expectEqual(@as(usize, 65), client_x963.len);
    try std.testing.expectEqual(@as(u8, 0x04), client_x963[0]);

    var browse_b64_buf: [128]u8 = undefined;
    const browse_b64 = std.base64.standard.Encoder.encode(&browse_b64_buf, &browse_x963);
    const json_blob = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"protocol\":[\"v1-p256-sig\"],\"port\":57232,\"browse_key\":\"{s}\",\"pid\":4242}}",
        .{browse_b64},
    );
    defer std.testing.allocator.free(json_blob);

    var disc = try parseConnectJson(std.testing.allocator, json_blob);
    defer disc.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 57232), disc.port);
    try std.testing.expectEqual(@as(u32, 4242), disc.pid);
    try std.testing.expectEqualSlices(u8, &browse_x963, &disc.browse_key_raw);

    // 6-digit code determinism & bound < 1_000_000.
    const nonce: [16]u8 = @splat(0xab);
    const c1 = computePairingCode(browse_x963, client_x963, nonce);
    const c2 = computePairingCode(browse_x963, client_x963, nonce);
    try std.testing.expectEqual(c1, c2);
    try std.testing.expect(c1 < 1_000_000);

    // Canonical request string & response signature verification round-trip.
    const zero_hex: [64]u8 = @splat('0');
    const aa_hex: [32]u8 = @splat('a');
    const canon = try canonicalSignString(std.testing.allocator, "/mcp", &zero_hex, "1700000000000", &aa_hex, "client-1");
    defer std.testing.allocator.free(canon);
    try std.testing.expect(std.mem.startsWith(u8, canon, "POST|/mcp|"));

    const resp_body = "{\"ok\":true}";
    var r_dig: [32]u8 = undefined;
    Sha256.hash(resp_body, &r_dig, .{});
    var r_hex: [64]u8 = undefined;
    hexLower(&r_dig, &r_hex);
    const srv_msg = try std.fmt.allocPrint(std.testing.allocator, "{s}|{s}", .{ r_hex, aa_hex });
    defer std.testing.allocator.free(srv_msg);

    const srv_sig = try browse_kp.sign(srv_msg, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = srv_sig.toDer(&der_buf);
    var srv_b64_buf: [160]u8 = undefined;
    const srv_b64 = std.base64.standard.Encoder.encode(&srv_b64_buf, der);

    try verifyResponseSignature(std.testing.allocator, browse_x963, resp_body, &aa_hex, srv_b64);
    try std.testing.expectError(
        error.SignatureVerificationFailed,
        verifyResponseSignature(std.testing.allocator, browse_x963, "{\"ok\":false}", &aa_hex, srv_b64),
    );
}

const MockBrowseServer = struct {
    server: std.Io.net.Server,
    port: u16,
    browse_kp: Ecdsa.KeyPair,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    exited: std.Io.Event = .unset,
    saw_origin_header: bool = false,
    saw_sig_header: bool = false,
    saw_open: bool = false,
    saw_type: bool = false,
    saw_press_key: bool = false,
    revoke_next: bool = false,

    fn start(self: *MockBrowseServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *MockBrowseServer) void {
        defer self.exited.set(std.testing.io);
        while (!self.stop.load(.acquire)) {
            var stream = self.server.accept(std.testing.io) catch return;
            defer stream.close(std.testing.io);
            if (self.stop.load(.acquire)) return;
            self.serveOne(&stream) catch {};
        }
    }

    fn serveOne(self: *MockBrowseServer, stream: *std.Io.net.Stream) !void {
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var rd = std.Io.net.Stream.Reader.init(stream.*, std.testing.io, &rbuf);
        var wr = std.Io.net.Stream.Writer.init(stream.*, std.testing.io, &wbuf);
        const r = &rd.interface;

        const req_line = try r.takeDelimiterInclusive('\n');
        var parts = std.mem.tokenizeScalar(u8, req_line, ' ');
        _ = parts.next();
        const path = parts.next() orelse "/";
        var path_buf: [64]u8 = undefined;
        const plen = @min(path.len, path_buf.len);
        @memcpy(path_buf[0..plen], path[0..plen]);
        const target = path_buf[0..plen];

        var content_len: usize = 0;
        var req_nonce: [64]u8 = @splat(0);
        var req_nonce_len: usize = 0;

        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "origin:")) self.saw_origin_header = true;
            if (std.ascii.startsWithIgnoreCase(trimmed, "x-signature:")) self.saw_sig_header = true;
            if (std.ascii.startsWithIgnoreCase(trimmed, "x-nonce:")) {
                const val = std.mem.trim(u8, trimmed["x-nonce:".len..], " \t");
                req_nonce_len = @min(val.len, req_nonce.len);
                @memcpy(req_nonce[0..req_nonce_len], val[0..req_nonce_len]);
            }
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                content_len = std.fmt.parseInt(usize, std.mem.trim(u8, trimmed["content-length:".len..], " \t"), 10) catch 0;
            }
        }

        const req_body = if (content_len > 0) try r.take(content_len) else "";

        var status_line: []const u8 = "200 OK";
        var resp_body: []const u8 = "{\"ok\":true}";

        if (std.mem.eql(u8, target, "/pair")) {
            resp_body = "{\"client_id\":\"mock-client-1\",\"expires_in\":120}";
        } else if (std.mem.eql(u8, target, "/pair/status")) {
            resp_body = "{\"status\":\"approved\"}";
        } else if (std.mem.eql(u8, target, "/mcp")) {
            if (self.revoke_next) {
                status_line = "401 Unauthorized";
                resp_body = "{\"error\":\"revoked\"}";
            } else if (std.mem.indexOf(u8, req_body, "\"name\":\"open\"") != null) {
                self.saw_open = true;
                resp_body = "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"opened\"}]}}";
            } else if (std.mem.indexOf(u8, req_body, "\"name\":\"screenshot\"") != null) {
                // Valid 1x1 PNG header bytes encoded in base64: iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
                resp_body = "{\"result\":{\"content\":[{\"type\":\"image\",\"data\":\"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==\"}]}}";
            } else if (std.mem.indexOf(u8, req_body, "\"name\":\"type\"") != null) {
                self.saw_type = true;
                resp_body = "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"typed\"}]}}";
            } else if (std.mem.indexOf(u8, req_body, "\"name\":\"press_key\"") != null) {
                self.saw_press_key = true;
                resp_body = "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"pressed\"}]}}";
            } else if (std.mem.indexOf(u8, req_body, "\"name\":\"evaluate_js\"") != null) {
                resp_body = "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[{\\\"tag\\\":\\\"button\\\",\\\"fontSize\\\":14,\\\"borderRadius\\\":8,\\\"w\\\":120,\\\"h\\\":36},{\\\"tag\\\":\\\"a\\\",\\\"fontSize\\\":12,\\\"borderRadius\\\":4,\\\"w\\\":40,\\\"h\\\":20}]\"}]}}";
            }
        }

        // Sign response with browse server private key over {sha256(body)}|{nonce}
        if (req_nonce_len > 0) {
            var r_dig: [32]u8 = undefined;
            Sha256.hash(resp_body, &r_dig, .{});
            var r_hex: [64]u8 = undefined;
            hexLower(&r_dig, &r_hex);
            const msg = try std.fmt.allocPrint(std.testing.allocator, "{s}|{s}", .{ r_hex, req_nonce[0..req_nonce_len] });
            defer std.testing.allocator.free(msg);
            const sig = try self.browse_kp.sign(msg, null);
            var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
            const der = sig.toDer(&der_buf);
            var b64_buf: [160]u8 = undefined;
            const sig_b64 = std.base64.standard.Encoder.encode(&b64_buf, der);
            try wr.interface.print(
                "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nX-Signature: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ status_line, sig_b64, resp_body.len, resp_body },
            );
        } else {
            try wr.interface.print(
                "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ status_line, resp_body.len, resp_body },
            );
        }
        try wr.interface.flush();
    }

    fn shutdown(self: *MockBrowseServer) void {
        self.stop.store(true, .release);
        if (self.thread) |t| @import("test_server_stop.zig").stopAcceptLoop(std.testing.io, self.port, &self.exited, t);
        self.server.deinit(std.testing.io);
    }
};

test "browse Connected Apps localhost mock server P-256 pair, MCP screenshot, keystroke, DOM sync, and 401 revocation" {
    const browse_seed: [Ecdsa.KeyPair.seed_length]u8 = @splat(0x42);
    const browse_kp = try Ecdsa.KeyPair.generateDeterministic(browse_seed);
    const browse_x963 = browse_kp.public_key.toUncompressedSec1();
    var browse_b64_buf: [128]u8 = undefined;
    const browse_b64 = std.base64.standard.Encoder.encode(&browse_b64_buf, &browse_x963);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var mock: MockBrowseServer = .{
        .server = try addr.listen(std.testing.io, .{ .reuse_address = true }),
        .port = 0,
        .browse_kp = browse_kp,
    };
    mock.port = mock.server.socket.address.getPort();
    try mock.start();
    defer mock.shutdown();

    var client = Client.init(std.testing.allocator, std.testing.io);
    defer client.deinit();
    client.setSession("synthetic-sess");

    const disc_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"protocol\":[\"v1-p256-sig\"],\"port\":{d},\"browse_key\":\"{s}\",\"pid\":999}}",
        .{ mock.port, browse_b64 },
    );
    defer std.testing.allocator.free(disc_json);
    client.discovery = try parseConnectJson(std.testing.allocator, disc_json);
    client.state = .discovered;

    try client.beginPair();
    try std.testing.expectEqual(ux.ConnState.pairing_pending, client.status());
    try std.testing.expectEqualStrings("mock-client-1", client.pair.client_id);

    const next_st = try client.pollPairStatus();
    try std.testing.expectEqual(ux.ConnState.connected, next_st);
    try std.testing.expect(mock.saw_sig_header);
    try std.testing.expect(!mock.saw_origin_header);

    try client.openUrlAndCapture("https://preview.acme.example/dashboard");
    try std.testing.expect(mock.saw_open);
    const snap = client.snapshotCopy(std.testing.allocator) orelse return error.MissingScreenshot;
    defer {
        std.testing.allocator.free(snap.png);
        std.testing.allocator.free(snap.title);
        std.testing.allocator.free(snap.url);
    }
    try std.testing.expectEqualStrings("\x89PNG", snap.png[0..4]);

    try client.typeText("hello browse");
    try client.pressKey("Enter");
    try std.testing.expect(mock.saw_type);
    try std.testing.expect(mock.saw_press_key);

    try client.refreshDomStyles();
    var nodes: [8]StyleNode = undefined;
    const ncount = client.inspectCopy(&nodes);
    try std.testing.expectEqual(@as(usize, 2), ncount);
    try std.testing.expectEqualStrings("button", nodes[0].tagSlice());
    try std.testing.expect(nodes[0].hit_ok);
    try std.testing.expect(!nodes[1].hit_ok);

    // 401 revocation cleanly moves client out of `.connected`.
    mock.revoke_next = true;
    try std.testing.expectError(error.AuthRevoked, client.refreshDomStyles());
    try std.testing.expectEqual(ux.ConnState.pair_denied, client.status());
    try std.testing.expect(!ux.mcpCallsPermitted(client.status()));
}
