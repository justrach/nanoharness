//! Agent-to-agent delivery rules:
//! - the peer-message envelope and its bounded relay depth
//!   (`crates/mcp/src/tools/peer_messages.rs`);
//! - the device-local relay ledger for mail that never enters a transcript
//!   (`tools/relay_ledger.rs`);
//! - graff's native peer inbox and the `graff` CLI it and bots go through
//!   (`tools/graff_peer.rs`, `tools/bots.rs`).
const std = @import("std");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const u = @import("util.zig");
const transcript = @import("transcript.zig");

// ---- envelope --------------------------------------------------------------------

const prefix = "[Message from Harness chat ";
const depth_marker = "Relay depth: ";
pub const max_depth: u32 = 4;
const guidance = ". Agent coordination, not a human request. Reply with Harness `send_message` " ++
    "only for an actionable question, blocker, or final requested result; " ++
    "otherwise do not reply. Do not send acknowledgements or progress updates.]";

pub const chain_limit_msg = "peer reply chain limit reached; do not acknowledge or retry. " ++
    "Report the result in your own chat or use an unmentioned room post. " ++
    "A new human request starts a new chain";

/// `rsplit_once`: split at the last occurrence.
fn rsplitOnce(text: []const u8, sep: []const u8) ?struct { []const u8, []const u8 } {
    const at = std.mem.lastIndexOf(u8, text, sep) orelse return null;
    return .{ text[0..at], text[at + sep.len ..] };
}

fn firstLine(text: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var line = text[0..nl];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}

/// Sender and depth from the fixed suffix, never the free-form title.
fn currentMetadata(header: []const u8) ?struct { sender: []const u8, depth: []const u8 } {
    if (!std.mem.endsWith(u8, header, guidance)) return null;
    const h = header[0 .. header.len - guidance.len];
    const ld = rsplitOnce(h, ". Relay depth: ") orelse return null;
    const ls = rsplitOnce(ld[0], ". Sender chat: ") orelse return null;
    return .{ .sender = ls[1], .depth = ld[1] };
}

/// The relay depth of the newest user message: 0 for a person's prompt.
pub fn inboundDepth(messages: []const transcript.Message) u32 {
    var k = messages.len;
    while (k > 0) {
        k -= 1;
        if (messages[k].isRole("user")) return relayDepth(messages[k].text.items);
    }
    return 0;
}

/// The depth to send at after receiving `depth`; null past the chain limit.
pub fn checkedNext(depth: u32) ?u32 {
    if (depth >= max_depth) return null;
    return depth + 1;
}

fn skipJsonWs(s: []const u8, idx: usize) usize {
    var i = idx;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            ' ', '\t', '\r', '\n' => {},
            else => break,
        }
    }
    return i;
}

fn skipJsonString(s: []const u8, start: usize) ?usize {
    if (start >= s.len or s[start] != '"') return null;
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') return i + 1;
    }
    return null;
}

fn skipJsonValue(s: []const u8, start: usize) ?usize {
    var i = skipJsonWs(s, start);
    if (i >= s.len) return null;
    switch (s[i]) {
        '"' => return skipJsonString(s, i),
        '{', '[' => {
            var depth: usize = 0;
            while (i < s.len) {
                if (s[i] == '"') {
                    i = skipJsonString(s, i) orelse return null;
                    continue;
                }
                if (s[i] == '{' or s[i] == '[') depth += 1 else if (s[i] == '}' or s[i] == ']') {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                }
                i += 1;
            }
            return null;
        },
        else => {
            while (i < s.len) : (i += 1) {
                switch (s[i]) {
                    ',', '}', ']', ' ', '\t', '\r', '\n' => return i,
                    else => {},
                }
            }
            return i;
        },
    }
}

fn roomDeliveryHop(text: []const u8) ?u32 {
    const open = "<!--harness-room ";
    const close = " -->";
    if (!std.mem.startsWith(u8, text, open)) return null;
    const rest = text[open.len..];
    const end = std.mem.indexOf(u8, rest, close) orelse return null;
    const tag = rest[0..end];
    var i = skipJsonWs(tag, 0);
    if (i >= tag.len or tag[i] != '{') return null;
    i += 1;
    var saw_hop: ?u32 = null;
    var from_user: ?bool = null;
    while (true) {
        i = skipJsonWs(tag, i);
        if (i >= tag.len or tag[i] == '}') break;
        if (tag[i] == ',') {
            i += 1;
            continue;
        }
        const key_end = skipJsonString(tag, i) orelse return null;
        const key = tag[i + 1 .. key_end - 1];
        i = skipJsonWs(tag, key_end);
        if (i >= tag.len or tag[i] != ':') return null;
        i = skipJsonWs(tag, i + 1);
        const val_end = skipJsonValue(tag, i) orelse return null;
        const raw_val = std.mem.trim(u8, tag[i..val_end], " \t\r\n");
        if (std.mem.eql(u8, key, "hop")) {
            saw_hop = std.fmt.parseInt(u32, raw_val, 10) catch null;
        } else if (std.mem.eql(u8, key, "from_user")) {
            if (std.mem.eql(u8, raw_val, "true")) from_user = true else if (std.mem.eql(u8, raw_val, "false")) from_user = false;
        }
        i = val_end;
    }
    if (saw_hop) |h| return h;
    if (from_user) |u_flag| return if (u_flag) 0 else 1;
    return null;
}

pub fn relayDepth(text: []const u8) u32 {
    if (roomDeliveryHop(text)) |h| return h;
    if (!std.mem.startsWith(u8, text, prefix)) return 0;
    const header = firstLine(text);
    const depth = if (currentMetadata(header)) |m|
        m.depth
    else if (std.mem.indexOf(u8, header, ". Reply to it") != null)
        // Legacy envelopes have no depth field, even if their title has one.
        return 1
    else if (rsplitOnce(header, depth_marker)) |parts|
        parts[1]
    else
        return 1;
    const slash = std.mem.indexOfScalar(u8, depth, '/') orelse return max_depth;
    return std.fmt.parseInt(u32, depth[0..slash], 10) catch max_depth;
}

pub fn fromSender(text: []const u8, origin: []const u8) bool {
    const header = firstLine(text);
    if (!std.mem.startsWith(u8, header, prefix)) return false;
    if (currentMetadata(header)) |m| return std.mem.eql(u8, m.sender, origin);
    const parts = rsplitOnce(header[prefix.len..], ". Reply to it") orelse return false;
    const label = parts[0];
    const sh = u.short(origin);
    if (std.mem.eql(u8, label, sh)) return true;
    var buf: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&buf, " ({s})", .{sh}) catch return false;
    return std.mem.endsWith(u8, label, suffix);
}

/// A person's prompt: neither a peer envelope nor a room delivery. `a`
/// holds the delivery tag while it is checked (an arena).
pub fn isHumanPrompt(a: Allocator, text: []const u8) bool {
    return !std.mem.startsWith(u8, text, prefix) and !isRoomDelivery(a, text);
}

/// `room_delivery::is_delivery`: opens with a well-formed delivery tag. The
/// tag is parsed into `a`, so a long room or member name still parses.
pub fn isRoomDelivery(a: Allocator, text: []const u8) bool {
    const open = "<!--harness-room ";
    const close = " -->";
    if (!std.mem.startsWith(u8, text, open)) return false;
    const rest = text[open.len..];
    const end = std.mem.indexOf(u8, rest, close) orelse return false;
    const tag = json.parseFromSliceLeaky(json.Value, a, rest[0..end], .{}) catch return false;
    // `RoomOrigin`'s required fields.
    return u.str(tag, "room_id") != null and u.str(tag, "room_name") != null and
        u.int(tag, "seq") != null and u.str(tag, "from_member") != null and
        u.str(tag, "member_kind") != null and u.boolean(tag, "from_user") != null;
}

/// The one-line envelope, then the body unchanged.
pub fn frame(a: Allocator, label: []const u8, origin: []const u8, depth: u32, text: []const u8) ![]u8 {
    // Titles may contain line breaks; keep the envelope on one line.
    var words: std.ArrayList(u8) = .empty;
    var idx: usize = 0;
    var in_word = false;
    while (idx < label.len) {
        const n = @min(std.unicode.utf8ByteSequenceLength(label[idx]) catch 1, label.len - idx);
        const cp = std.unicode.utf8Decode(label[idx .. idx + n]) catch label[idx];
        if (u.isUnicodeSpace(cp)) {
            in_word = false;
        } else {
            if (!in_word and words.items.len > 0) try words.append(a, ' ');
            in_word = true;
            try words.appendSlice(a, label[idx .. idx + n]);
        }
        idx += n;
    }
    return std.fmt.allocPrint(a, prefix ++ "{s}. Sender chat: {s}. Relay depth: {d}/{d}" ++ guidance ++ "\n\n{s}", .{ words.items, origin, depth, max_depth, text });
}

// ---- relay ledger -------------------------------------------------------------------

pub const entry_ttl_ms: i64 = 30 * 60 * 1000;

pub const RelayLedger = struct {
    io: Io,
    /// `~/.harness/peer-relay`; without a home the ledger cannot record.
    dir: ?[]const u8,

    fn path(self: RelayLedger, a: Allocator, chat_id: []const u8) !?[]u8 {
        const dir = self.dir orelse return null;
        const name = try a.alloc(u8, chat_id.len);
        for (chat_id, 0..) |c, k| {
            name[k] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
        }
        return try std.fmt.allocPrint(a, "{s}/{s}.json", .{ dir, name });
    }

    const Read = struct { depth: ?u32, at: i64 };

    fn read(self: RelayLedger, a: Allocator, file: []const u8) ?Read {
        const cwd = Io.Dir.cwd();
        const bytes = cwd.readFileAlloc(self.io, file, a, .limited(64 * 1024)) catch return null;
        if (json.parseFromSliceLeaky(json.Value, a, bytes, .{})) |v| {
            if (u.int(v, "depth")) |d| if (u.int(v, "atMs")) |at| if (d >= 0 and d <= std.math.maxInt(u32))
                return .{ .depth = @intCast(d), .at = at };
        } else |_| {}
        const st = cwd.statFile(self.io, file, .{}) catch return .{ .depth = null, .at = std.math.maxInt(i64) };
        return .{ .depth = null, .at = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms)) };
    }

    /// Note that `chat_id` was sent peer mail at `depth`; never lowers a
    /// depth already recorded. Error text when it could not be written.
    pub fn record(self: RelayLedger, a: Allocator, chat_id: []const u8, depth: u32, from: ?[]const u8, now_ms: i64) !?[]const u8 {
        const file = (try self.path(a, chat_id)) orelse return "no home directory for the relay ledger";
        const kept: u32 = if (self.read(a, file)) |r|
            (if (now_ms - r.at <= entry_ttl_ms) (r.depth orelse max_depth - 1) else 0)
        else
            0;
        var o = u.obj(a);
        try o.put("depth", u.i(@max(depth, kept)));
        try o.put("from", u.optS(from));
        try o.put("atMs", u.i(now_ms));
        const body = try u.stringify(a, o.value());
        const dir = std.fs.path.dirname(file).?;
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, dir) catch return try std.fmt.allocPrint(a, "could not create {s}", .{dir});
        var id_buf: [36]u8 = undefined;
        const tmp = try std.fmt.allocPrint(a, "{s}/.{s}.tmp", .{ dir, @import("../ids.zig").uuid(self.io, &id_buf) });
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = body }) catch return try std.fmt.allocPrint(a, "could not write {s}", .{tmp});
        cwd.rename(tmp, cwd, file, self.io) catch |err| {
            cwd.deleteFile(self.io, tmp) catch {};
            return try std.fmt.allocPrint(a, "{t}", .{err});
        };
        return null;
    }

    /// A person's peer-inbox send starts a new chain for the recipient.
    pub fn clear(self: RelayLedger, a: Allocator, chat_id: []const u8) void {
        const file = (self.path(a, chat_id) catch return) orelse return;
        Io.Dir.cwd().deleteFile(self.io, file) catch {};
    }

    /// The depth `chat_id` last received through the peer inbox: 0 with no
    /// entry, an expired one, or a person's prompt since (removed then). An
    /// unreadable entry counts as one hop below the cap.
    pub fn inbound(self: RelayLedger, a: Allocator, chat_id: []const u8, messages: []const transcript.Message, now_ms: i64) u32 {
        const file = (self.path(a, chat_id) catch return 0) orelse return 0;
        const r = self.read(a, file) orelse return 0;
        var prompted_since = false;
        for (messages) |m| {
            if (m.isRole("user") and m.created_at > r.at and isHumanPrompt(a, m.text.items)) prompted_since = true;
        }
        if (now_ms - r.at > entry_ttl_ms or prompted_since) {
            Io.Dir.cwd().deleteFile(self.io, file) catch {};
            return 0;
        }
        return r.depth orelse max_depth - 1;
    }
};

// ---- graff CLI -------------------------------------------------------------------------

/// `GRAFF_EXECUTABLE`, else the managed `~/.harness/bin/graff`, else `graff`.
pub fn graffExecutable(a: Allocator, io: Io, env_graff: ?[]const u8, home: ?[]const u8) ![]const u8 {
    if (env_graff) |g| if (g.len > 0) return g;
    if (home) |h| {
        const managed = try std.fmt.allocPrint(a, "{s}/.harness/bin/graff", .{h});
        if (Io.Dir.cwd().statFile(io, managed, .{})) |st| {
            if (st.kind == .file) return managed;
        } else |_| {}
    }
    return "graff";
}

pub const RunOutput = struct {
    ok: bool,
    term: []const u8,
    stdout: []const u8,
    stderr: []const u8,
};

pub const RunResult = union(enum) {
    out: RunOutput,
    /// Could not start, or the deadline passed (the child is killed).
    failed: []const u8,
};

/// Output kept from a CLI: past this the child is killed and the run fails.
pub const max_stdout_bytes: usize = 4 * 1024 * 1024;
pub const max_stderr_bytes: usize = 1024 * 1024;

/// Runs `argv` in `cwd` with `stdin_text` piped in, collecting its output.
/// The deadline covers everything, the stdin write included (it goes from a
/// thread of its own, so a child that never reads cannot block it); the
/// child is killed when the deadline passes or its output grows past the
/// caps.
pub fn runCli(a: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8, stdin_text: ?[]const u8, timeout_ms: i64) !RunResult {
    if (comptime !std.process.can_spawn) return .{ .failed = "this platform cannot run the graff CLI" };
    const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }).toDeadline(io);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .stdin = if (stdin_text != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return .{ .failed = try std.fmt.allocPrint(a, "could not run {s}: {t}", .{ argv[0], err }) };
    var feeder: ?std.Thread = null;
    // Kill first, so a feeder blocked on a child that stopped reading ends.
    defer {
        child.kill(io);
        if (feeder) |t| t.join();
    }
    if (stdin_text) |text| {
        if (child.stdin) |f| {
            child.stdin = null;
            const Feed = struct {
                fn run(fio: Io, file: Io.File, bytes: []const u8) void {
                    file.writeStreamingAll(fio, bytes) catch {};
                    file.close(fio);
                }
            };
            feeder = std.Thread.spawn(.{}, Feed.run, .{ io, f, text }) catch blk: {
                Feed.run(io, f, text);
                break :blk null;
            };
        }
    }
    var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(a, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, deadline)) |_| {
        if (mr.reader(0).buffered().len > max_stdout_bytes or mr.reader(1).buffered().len > max_stderr_bytes)
            return .{ .failed = try std.fmt.allocPrint(a, "{s} printed more than {d} MiB", .{ argv[0], max_stdout_bytes / (1024 * 1024) }) };
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return .{ .failed = "timeout" },
        else => return .{ .failed = try std.fmt.allocPrint(a, "{t}", .{err}) },
    }
    const term = child.wait(io) catch |err| return .{ .failed = try std.fmt.allocPrint(a, "{t}", .{err}) };
    const stdout = try mr.toOwnedSlice(0);
    const stderr = try mr.toOwnedSlice(1);
    return .{ .out = .{
        .ok = term.success(),
        .term = try std.fmt.allocPrint(a, "{f}", .{term}),
        .stdout = stdout,
        .stderr = stderr,
    } };
}

/// Posts one message into a graff session's peer inbox.
pub const PeerSend = struct {
    ptr: *anyopaque,
    send_fn: *const fn (ptr: *anyopaque, a: Allocator, from: []const u8, to: []const u8, text: []const u8) anyerror!SendResult,

    pub const SendResult = union(enum) { ok: []const u8, err: []const u8 };

    pub fn send(p: PeerSend, a: Allocator, from: []const u8, to: []const u8, text: []const u8) !SendResult {
        return p.send_fn(p.ptr, a, from, to, text);
    }
};

/// `graff peer send --as FROM --to TO --anyway`, the text on stdin.
pub const GraffPeer = struct {
    io: Io,
    graff: []const u8,
    const send_timeout_ms: i64 = 15_000;

    pub fn peerSend(self: *GraffPeer) PeerSend {
        return .{ .ptr = self, .send_fn = sendFn };
    }

    fn sendFn(ptr: *anyopaque, a: Allocator, from: []const u8, to: []const u8, text: []const u8) anyerror!PeerSend.SendResult {
        const self: *GraffPeer = @ptrCast(@alignCast(ptr));
        const argv = [_][]const u8{ self.graff, "peer", "send", "--as", from, "--to", to, "--anyway" };
        switch (try runCli(a, self.io, &argv, null, text, send_timeout_ms)) {
            .failed => |why| {
                if (std.mem.eql(u8, why, "timeout")) return .{ .err = "graff peer send timed out after 15s" };
                return .{ .err = why };
            },
            .out => |o| {
                const stdout = u.trim(o.stdout);
                if (!o.ok) {
                    const stderr = u.trim(o.stderr);
                    const reason = if (stderr.len > 0) stderr else if (stdout.len > 0) stdout else o.term;
                    return .{ .err = try std.fmt.allocPrint(a, "graff peer send failed: {s}", .{reason}) };
                }
                return .{ .ok = stdout };
            },
        }
    }
};

/// The graff session native peer mail reaches for a chat: a graff chat whose
/// running session is on this device, addressed by its ACP session id.
pub fn peerTarget(chat: json.Value, harness: []const u8, session: ?json.Value, local_device: []const u8) ?[]const u8 {
    if (@import("builtin").os.tag == .windows or !std.mem.eql(u8, harness, "graff")) return null;
    const sess = session orelse return null;
    if (!std.mem.eql(u8, u.str(sess, "deviceId") orelse "", local_device)) return null;
    if (!std.mem.eql(u8, u.str(chat, "deviceId") orelse "", local_device)) return null;
    // An empty id is the engine's "do not resume" tombstone.
    const id = u.str(chat, "harnessSessionId") orelse return null;
    return if (u.isBlank(id)) null else id;
}

// ---- tests ---------------------------------------------------------------------------

const testing = std.testing;

fn userMessages(a: Allocator, text: []const u8) ![]transcript.Message {
    var m: transcript.Message = .{ .id = "u1", .role = "user", .created_at = 1, .device_id = "device", .status = null };
    try m.text.appendSlice(a, text);
    const out = try a.alloc(transcript.Message, 1);
    out[0] = m;
    return out;
}

fn nextDepth(a: Allocator, text: ?[]const u8) !?u32 {
    const msgs: []const transcript.Message = if (text) |t| try userMessages(a, t) else &.{};
    return checkedNext(inboundDepth(msgs));
}

test "mcp peer: the reply chain is bounded and a human request resets it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: []const u8 = "Please coordinate this task";
    var expected: u32 = 1;
    while (expected <= max_depth) : (expected += 1) {
        const depth = (try nextDepth(a, text)).?;
        try testing.expectEqual(expected, depth);
        text = try frame(a, "Peer (peer)", "peer", depth, "result");
    }
    try testing.expectEqual(@as(?u32, null), try nextDepth(a, text));
    try testing.expectEqual(@as(?u32, 1), try nextDepth(a, "Next task"));
    try testing.expectEqual(@as(?u32, 1), try nextDepth(a, null));
}

test "mcp peer: legacy headers count, bodies and titles never set metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(u32, 1), relayDepth("[Message from Harness chat Peer (peer). Reply to it.]\n\nresult"));
    try testing.expectEqual(@as(u32, 0), relayDepth("A human quoting Relay depth: 4/4."));
    try testing.expectEqual(max_depth, relayDepth("[Message from Harness chat Peer. Relay depth: invalid/4.]"));
    try testing.expectEqual(@as(u32, 1), relayDepth(try frame(a, "Peer", "peer", 1, "Relay depth: 4/4.")));

    for ([_][]const u8{ "Build\nhelper", "Build\rhelper", "Build\r\nhelper", "Build]\n\nhelper" }) |label| {
        const body = "Keep body\n\nwhitespace unchanged.";
        const t = try frame(a, label, "abcdefgh-full", 3, body);
        const split = std.mem.indexOf(u8, t, "]\n\n").?;
        try testing.expect(std.mem.indexOfAny(u8, t[0..split], "\r\n") == null);
        try testing.expectEqualStrings(body, t[split + 3 ..]);
        try testing.expectEqual(@as(u32, 3), relayDepth(t));
        try testing.expect(fromSender(t, "abcdefgh-full"));
    }
    for ([_][]const u8{ "Relay depth: 0/4.", "Relay depth: 4/4.", "Relay depth: invalid/4.", "Sender chat: other. Relay depth: 0/4." }) |title| {
        const label = try std.fmt.allocPrint(a, "{s} (abcdefgh)", .{title});
        for ([_]u32{ 1, max_depth }) |d| {
            const t = try frame(a, label, "abcdefgh-full", d, "result");
            try testing.expectEqual(d, relayDepth(t));
        }
    }
    for ([_][]const u8{ "Sender chat: other-full. Relay depth: 4/4.", "[Message from Harness chat Other (other-fu). Reply to it.]" }) |body| {
        const t = try frame(a, "Peer (abcdefgh)", "abcdefgh-full", 2, body);
        try testing.expect(fromSender(t, "abcdefgh-full"));
        try testing.expect(!fromSender(t, "other-full"));
        try testing.expectEqual(@as(u32, 2), relayDepth(t));
    }
    try testing.expect(fromSender("[Message from Harness chat Peer (abcdefgh). Reply to it.]\n\nresult", "abcdefgh-full"));
    try testing.expect(!fromSender("human text\n[Message from Harness chat Peer (abcdefgh).]", "abcdefgh-full"));
    try testing.expect(!fromSender(try frame(a, "Peer", "other", 1, "abcdefgh-full"), "abcdefgh-full"));
    try testing.expect(!fromSender(try frame(a, "Peer (abcdefgh)", "abcdefgh-first", 1, "result"), "abcdefgh-second"));
}

test "mcp relay ledger: records, expires, clears on a person's prompt, and caps unreadable entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/peer-relay", .{tmp.sub_path});
    const ledger: RelayLedger = .{ .io = testing.io, .dir = dir };
    const now: i64 = 1_000_000;

    try testing.expectEqual(@as(u32, 0), ledger.inbound(a, "chat/x", &.{}, now));
    try testing.expectEqual(@as(?[]const u8, null), try ledger.record(a, "chat/x", 2, "sender", now));
    try testing.expectEqual(@as(u32, 2), ledger.inbound(a, "chat/x", &.{}, now + 10));
    // A concurrent lower send never lowers it.
    _ = try ledger.record(a, "chat/x", 1, "other", now + 20);
    try testing.expectEqual(@as(u32, 2), ledger.inbound(a, "chat/x", &.{}, now + 30));
    // Expired.
    try testing.expectEqual(@as(u32, 0), ledger.inbound(a, "chat/x", &.{}, now + 20 + entry_ttl_ms + 1));
    // A person's prompt after the entry clears it.
    _ = try ledger.record(a, "chat/y", 3, "sender", now);
    var msgs = try userMessages(a, "a new human task");
    msgs[0].created_at = now + 5;
    try testing.expectEqual(@as(u32, 0), ledger.inbound(a, "chat/y", msgs, now + 10));
    try testing.expectEqual(@as(u32, 0), ledger.inbound(a, "chat/y", &.{}, now + 11));
    // Unreadable: one hop below the cap, dated by its mtime.
    const bad = try std.fmt.allocPrint(a, "{s}/chat-z.json", .{dir});
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = bad, .data = "not json" });
    const mtime_now: i64 = @intCast(@divFloor(Io.Clock.real.now(testing.io).nanoseconds, std.time.ns_per_ms));
    try testing.expectEqual(max_depth - 1, ledger.inbound(a, "chat-z", &.{}, mtime_now));
    ledger.clear(a, "chat-z");
    try testing.expectEqual(@as(u32, 0), ledger.inbound(a, "chat-z", &.{}, mtime_now));
    // No home: nothing recorded, and it says why.
    const homeless: RelayLedger = .{ .io = testing.io, .dir = null };
    try testing.expectEqualStrings("no home directory for the relay ledger", (try homeless.record(a, "c", 1, null, now)).?);
}

test "mcp graff cli: output, failure text and the enforced timeout" {
    if (comptime !std.process.can_spawn) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const echo = try runCli(a, testing.io, &.{ "/bin/sh", "-c", "cat; echo done 1>&2" }, null, "piped body", 10_000);
    try testing.expect(echo.out.ok);
    try testing.expectEqualStrings("piped body", echo.out.stdout);
    try testing.expectEqualStrings("done\n", echo.out.stderr);

    var peer: GraffPeer = .{ .io = testing.io, .graff = "/bin/sh" };
    // `/bin/sh peer send …` fails: sh cannot open a script named `peer`.
    const failed = try peer.peerSend().send(a, "harness", "sess", "hi");
    try testing.expect(failed == .err);
    try testing.expect(std.mem.startsWith(u8, failed.err, "graff peer send failed: "));

    const slow = try runCli(a, testing.io, &.{ "/bin/sh", "-c", "sleep 5" }, null, null, 200);
    try testing.expectEqualStrings("timeout", slow.failed);
}

fn awakeMs() i64 {
    return @intCast(Io.Clock.awake.now(testing.io).toMilliseconds());
}

test "mcp graff cli: the deadline covers a stdin the child never reads, and too much output kills the child" {
    if (comptime !std.process.can_spawn) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1 MiB on stdin to a child that never reads it: far past a pipe's buffer.
    const big = try a.alloc(u8, 1024 * 1024);
    @memset(big, 'x');
    const t0 = awakeMs();
    const stuck = try runCli(a, testing.io, &.{ "/bin/sh", "-c", "sleep 5" }, null, big, 300);
    try testing.expect(stuck == .failed);
    try testing.expectEqualStrings("timeout", stuck.failed);
    try testing.expect(awakeMs() - t0 < 3000);
    // More than 4 MiB of output, then a child that would keep running.
    const t1 = awakeMs();
    const loud = try runCli(a, testing.io, &.{ "/bin/sh", "-c", "dd if=/dev/zero bs=1000000 count=5 2>/dev/null; sleep 5" }, null, null, 10_000);
    try testing.expect(loud == .failed);
    try testing.expectEqualStrings("/bin/sh printed more than 4 MiB", loud.failed);
    try testing.expect(awakeMs() - t1 < 3000);
}

test "mcp peer: a room delivery with a long room name is not a person's prompt and keeps the relay ledger" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long_name = try a.alloc(u8, 6000);
    @memset(long_name, 'r');
    const text = try @import("rooms.zig").deliveryText(a, "room_0123456789abcdef01234567", long_name, 4, "alpha", 1, "status");
    try testing.expect(isRoomDelivery(a, text));
    try testing.expect(!isHumanPrompt(a, text));
    // A ledger entry, then that delivery arriving later: the chain stands.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/peer-relay", .{tmp.sub_path});
    const ledger: RelayLedger = .{ .io = testing.io, .dir = dir };
    const now: i64 = 2_000_000;
    try testing.expectEqual(@as(?[]const u8, null), try ledger.record(a, "chat-r", 3, "sender", now));
    var msgs = try userMessages(a, text);
    msgs[0].created_at = now + 5;
    try testing.expectEqual(@as(u32, 3), ledger.inbound(a, "chat-r", msgs, now + 10));
    // A person's prompt does clear it.
    var human = try userMessages(a, "a new human task");
    human[0].created_at = now + 20;
    try testing.expectEqual(@as(u32, 0), ledger.inbound(a, "chat-r", human, now + 30));
}

test "mcp graff peer: only a working graff chat hosted on this device is addressable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const chat = try json.parseFromSliceLeaky(json.Value, a, "{\"id\":\"c\",\"deviceId\":\"here\",\"harnessSessionId\":\"sess-1\"}", .{});
    const session = try json.parseFromSliceLeaky(json.Value, a, "{\"chatId\":\"c\",\"deviceId\":\"here\",\"status\":\"working\"}", .{});
    try testing.expectEqualStrings("sess-1", peerTarget(chat, "graff", session, "here").?);
    try testing.expect(peerTarget(chat, "claude-code", session, "here") == null);
    try testing.expect(peerTarget(chat, "graff", session, "elsewhere") == null);
    try testing.expect(peerTarget(chat, "graff", null, "here") == null);
    const tomb = try json.parseFromSliceLeaky(json.Value, a, "{\"id\":\"c\",\"deviceId\":\"here\",\"harnessSessionId\":\" \"}", .{});
    try testing.expect(peerTarget(tomb, "graff", session, "here") == null);
}
