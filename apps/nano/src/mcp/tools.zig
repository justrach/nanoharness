//! The tool catalog and its dispatch (`crates/mcp/src/tools.rs`,
//! `crates/mcp/src/harness.rs` for resolution and turn waiting).
//!
//! Every tool composes engine reads and writes through `engine_link`; the
//! logic here is argument checking (with serde's wording), resolution (chat
//! by id/prefix/title, project by id/path/name, device by id/name), sender
//! attribution, the delivery choice the composer makes, and waiting.
const std = @import("std");
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const u = @import("util.zig");
const link = @import("engine_link.zig");
const transcript = @import("transcript.zig");
const peer = @import("peer.zig");
const ids = @import("../ids.zig");
pub const rooms = @import("rooms.zig");
pub const bots = @import("bots.zig");
const Value = json.Value;

/// The tool catalog, `protocol/mcp-tools.json` (the one shared copy): the
/// Rust server's tools, names, descriptions and input schemas, in its
/// order. `tools/list` serves it unchanged.
pub const catalog_json = @import("mcp_tools_json").json;

/// Default and ceiling for blocking waits.
const default_wait_ms: i64 = 600_000;
const max_wait_ms: i64 = 3_600_000;
/// A chat caller's timed-out wait ends its turn rather than waiting again.
pub const chat_wait_note = "The chat is still working. Its reply arrives in your chat as a " ++
    "[Message from Harness chat …] message, so end your turn now instead of waiting again.";
/// A session row older than this is not trusted to still be working.
const session_stale_ms: i64 = 45_000;
/// Gap between resubscribes when a watch stream ends.
const resubscribe_delay_ms: i64 = 300;

pub const archived_refusal = "chat is archived: archived chats take no peer messages. " ++
    "Do not retry; ask the person to restore the chat if it is needed again";

const harness_ids = [_][]const u8{ "claude-code", "codex", "cursor", "devin", "grok", "hermes", "graff", "pi", "opencode", "antigravity", "exo", "mock" };
/// `{:?}` of `HarnessId`: the variant name.
const harness_variants = [_][]const u8{ "ClaudeCode", "Codex", "Cursor", "Devin", "Grok", "Hermes", "Graff", "Pi", "Opencode", "Antigravity", "Exo", "Mock" };
const reasoning_levels = [_][]const u8{ "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "ultracode", "ultrathink" };
const sandbox_levels = [_][]const u8{ "read-only", "workspace-write", "danger-full-access" };

/// Which chat this server speaks for (`HARNESS_CHAT_ID`/`HARNESS_DEVICE_ID`);
/// unset when a person runs `harness mcp` from a terminal.
pub const Origin = struct {
    chat_id: ?[]const u8 = null,
    device_id: ?[]const u8 = null,
};

/// `Ok` is the tool's structured result; `err` is text the model reads
/// (`isError`), never a protocol error.
pub const Outcome = union(enum) {
    ok: Value,
    err: []const u8,
};

pub const Tools = struct {
    io: Io,
    engine: link.Engine,
    origin: Origin,
    peer: peer.PeerSend,
    relay: peer.RelayLedger,
    bots: bots.BotCli,
    /// Runs `git` for a room's project binding; null skips it (no binding).
    git: ?[]const u8 = "git",
    /// Tests pin the clock to the in-process engine's.
    fixed_now_ms: ?i64 = null,

    pub fn nowMs(self: *const Tools) i64 {
        if (self.fixed_now_ms) |n| return n;
        return @intCast(Io.Clock.real.now(self.io).toMilliseconds());
    }

    /// Monotonic millis for deadlines.
    pub fn nowMsReal(self: *const Tools) i64 {
        return @intCast(Io.Clock.awake.now(self.io).toMilliseconds());
    }

    pub fn fromChat(self: *const Tools) bool {
        return self.origin.chat_id != null;
    }

    /// `tools/list`: the catalog, without `show_image`/`show_visual` /
    /// `create_artifact`/`update_artifact` when there is no origin chat.
    pub fn list(self: *const Tools, a: Allocator) !Value {
        const all = try json.parseFromSliceLeaky(Value, a, catalog_json, .{});
        var out = u.arr(a);
        for (all.array.items) |t| {
            const name = u.str(t, "name").?;
            if (self.origin.chat_id == null and isChatOnlyTool(name)) continue;
            try out.append(t);
        }
        return .{ .array = out };
    }

    fn isChatOnlyTool(name: []const u8) bool {
        return std.mem.eql(u8, name, "show_image") or
            std.mem.eql(u8, name, "show_visual") or
            std.mem.eql(u8, name, "create_artifact") or
            std.mem.eql(u8, name, "update_artifact");
    }

    pub fn has(name: []const u8) bool {
        var buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "{{\"name\":\"{s}\",", .{name}) catch return false;
        return std.mem.indexOf(u8, catalog_json, needle) != null;
    }

    pub fn call(self: *Tools, a: Allocator, name: []const u8, args: Value) !Outcome {
        var c: Ctx = .{ .t = self, .a = a };
        const v = dispatch(&c, name, args) catch |err| switch (err) {
            error.ToolFailed => return .{ .err = c.msg },
            else => return err,
        };
        return .{ .ok = v };
    }
};

pub const Error = error{ToolFailed} || anyerror;

fn dispatch(c: *Ctx, name: []const u8, args: Value) !Value {
    const eq = std.mem.eql;
    if (eq(u8, name, "whoami")) return whoami(c);
    if (eq(u8, name, "list_devices")) return listDevices(c);
    if (eq(u8, name, "list_projects")) return listProjects(c);
    if (eq(u8, name, "list_harnesses")) return listHarnesses(c);
    if (eq(u8, name, "list_models")) return listModels(c, args);
    if (eq(u8, name, "list_chats")) return listChats(c, args);
    if (eq(u8, name, "get_chat")) return getChat(c, args);
    if (eq(u8, name, "create_chat")) return createChatTool(c, args);
    if (eq(u8, name, "read_chat")) return readChat(c, args);
    if (eq(u8, name, "send_message")) return sendMessage(c, args);
    if (eq(u8, name, "wait_for_turn")) return waitForTurnTool(c, args);
    if (eq(u8, name, "interrupt_chat")) return interruptChat(c, args);
    if (eq(u8, name, "respond_to_input")) return respondToInput(c, args);
    if (eq(u8, name, "dismiss_input")) return dismissInput(c, args);
    if (eq(u8, name, "rename_chat")) return renameChat(c, args);
    if (eq(u8, name, "archive_chat")) return archiveChat(c, args);
    if (eq(u8, name, "show_image")) return showImage(c, args);
    if (eq(u8, name, "show_visual")) return showVisual(c, args);
    if (eq(u8, name, "create_artifact")) return createArtifact(c, args);
    if (eq(u8, name, "update_artifact")) return updateArtifact(c, args);
    if (rooms.handles(name)) return rooms.call(c, name, args);
    if (bots.handles(name)) return bots.call(c, name, args);
    return c.fail("unknown tool: {s}", .{name});
}

// ---- call context -----------------------------------------------------------------

pub const Ctx = struct {
    t: *Tools,
    a: Allocator,
    msg: []const u8 = "",

    pub fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) Error {
        c.msg = try std.fmt.allocPrint(c.a, fmt, args);
        return error.ToolFailed;
    }

    pub fn failMsg(c: *Ctx, msg: []const u8) Error {
        c.msg = msg;
        return error.ToolFailed;
    }

    pub fn params(c: *Ctx, v: Value) ![]const u8 {
        return u.stringify(c.a, v);
    }

    /// Unary call; an engine error fails the tool with its text.
    pub fn call(c: *Ctx, method: []const u8, p: Value) !Value {
        return switch (try c.t.engine.call(c.a, method, try c.params(p))) {
            .ok => |v| v,
            .err => |m| c.failMsg(m),
        };
    }

    pub fn snapshot(c: *Ctx, method: []const u8, p: Value) !Value {
        return switch (try link.snapshot(c.t.engine, c.a, method, try c.params(p))) {
            .ok => |v| v,
            .err => |m| c.failMsg(m),
        };
    }

    fn snapshotArray(c: *Ctx, method: []const u8) ![]const Value {
        const v = try c.snapshot(method, u.obj(c.a).value());
        if (v != .array) return c.fail("{s}: unexpected shape", .{method});
        return v.array.items;
    }

    pub fn chats(c: *Ctx) ![]const Value {
        return c.snapshotArray("WatchChats");
    }
    pub fn spaces(c: *Ctx) ![]const Value {
        return c.snapshotArray("WatchSpaces");
    }
    pub fn sessions(c: *Ctx) ![]const Value {
        return c.snapshotArray("WatchSessions");
    }
    pub fn devices(c: *Ctx) ![]const Value {
        return c.snapshotArray("WatchDevices");
    }

    pub fn localDeviceId(c: *Ctx) ![]const u8 {
        const v = try c.call("LocalDevice", u.obj(c.a).value());
        return u.str(v, "deviceId") orelse c.failMsg("LocalDevice reply missing deviceId");
    }

    pub fn harnesses(c: *Ctx) ![]const Value {
        const v = try c.call("ListHarnesses", u.obj(c.a).value());
        if (v != .array) return c.failMsg("ListHarnesses: unexpected shape");
        return v.array.items;
    }

    pub fn models(c: *Ctx, harness: []const u8) ![]const Value {
        var p = u.obj(c.a);
        try p.put("harness", u.s(harness));
        const v = try c.call("ListModels", p.value());
        if (v != .array) return c.failMsg("ListModels: unexpected shape");
        return v.array.items;
    }

    /// The full transcript: attach, take the opening `reset` frame, detach.
    pub fn transcriptOf(c: *Ctx, chat_id: []const u8) ![]const Value {
        var p = u.obj(c.a);
        try p.put("chatId", u.s(chat_id));
        const sub = switch (try c.t.engine.subscribe(c.a, "WatchDocMessages", try c.params(p.value()))) {
            .sub => |s| s,
            .err => |m| return c.failMsg(m),
        };
        defer sub.close();
        const deadline = c.t.nowMsReal() + link.snapshot_timeout_ms;
        while (true) {
            const remaining = deadline - c.t.nowMsReal();
            if (remaining <= 0) return c.failMsg("WatchDocMessages: no transcript within 15s");
            switch (try sub.next(c.a, remaining)) {
                .item => |item| {
                    if (u.get(item, "reset")) |reset| {
                        if (reset != .array) return c.failMsg("WatchDocMessages: bad frame");
                        return reset.array.items;
                    }
                },
                .ended => return c.failMsg("WatchDocMessages: stream ended before the transcript arrived"),
                .timeout => return c.failMsg("WatchDocMessages: no transcript within 15s"),
            }
        }
    }

    pub fn mutate(c: *Ctx, p: Value) !Value {
        return c.call("Mutate", p);
    }

    /// Durable command into the chat doc; the host device drains it.
    pub fn queueCommand(c: *Ctx, chat_id: []const u8, command: Value) ![]const u8 {
        var p = u.obj(c.a);
        try p.put("chatId", u.s(chat_id));
        try p.put("command", command);
        const reply = try c.call("QueueCommand", p.value());
        return u.str(reply, "commandId") orelse "";
    }

    /// Queue-row send, promoted when the live turn ends.
    pub fn queueMessage(c: *Ctx, chat_id: []const u8, text: []const u8) ![]const u8 {
        var p = u.obj(c.a);
        try p.put("chatId", u.s(chat_id));
        try p.put("text", u.s(text));
        try p.put("holdForTurnEnd", u.b(true));
        try p.put("turnOrigin", u.s("peer"));
        try p.put("peerChatId", u.optS(c.t.origin.chat_id));
        const reply = try c.call("QueueMessage", p.value());
        return u.str(reply, "id") orelse "";
    }

    /// One call to the edge's agent-room routes through the engine. A room's
    /// refusal (`not_a_member`, `secret_detected`, …) comes back readable.
    pub fn roomRequest(c: *Ctx, method: []const u8, path: []const u8, query: []const [2][]const u8, body: ?Value) !Value {
        var p = u.obj(c.a);
        try p.put("method", u.s(method));
        try p.put("path", u.s(path));
        var q = u.arr(c.a);
        for (query) |pair| try q.append(try u.strArray(c.a, &pair));
        try p.put("query", .{ .array = q });
        try p.put("body", body orelse .null);
        const reply = try c.call("RoomRequest", p.value());
        const status: i64 = blk: {
            const sv = u.get(reply, "status") orelse break :blk 0;
            break :blk switch (sv) {
                .integer => |n| if (n >= 0) n else 0,
                else => 0,
            };
        };
        const rbody = u.field(reply, "body");
        if (status < 200 or status >= 300) {
            const code = u.str(rbody, "error") orelse "error";
            const message = u.str(rbody, "message") orelse code;
            if (std.mem.eql(u8, message, code)) return c.fail("room request failed ({d}): {s}", .{ status, code });
            return c.fail("room request failed ({d}): {s}: {s}", .{ status, code, message });
        }
        // Every room route answers an object; anything else is not a reply
        // the tools can read, and must not pass as an empty success.
        if (rbody != .object) return c.fail("room request failed ({d}): the room's reply is not a JSON object", .{status});
        return rbody;
    }

    pub fn resolveChat(c: *Ctx, key_raw: []const u8) !Value {
        const key = u.trim(key_raw);
        if (key.len == 0) return c.failMsg("chat is required");
        return resolveChatIn(c, try c.chats(), key);
    }

    pub fn resolveSpace(c: *Ctx, key: []const u8) !Value {
        return resolveSpaceIn(c, try c.spaces(), u.trim(key));
    }

    /// Device id or exact name; none means this engine's own device.
    pub fn resolveDeviceId(c: *Ctx, key_raw: ?[]const u8) ![]const u8 {
        const key = if (key_raw) |k| u.trim(k) else "";
        if (key.len == 0) return c.localDeviceId();
        const devs = try c.devices();
        for (devs) |d| if (std.mem.eql(u8, u.str(d, "id") orelse "", key)) return u.str(d, "id").?;
        var by_name: std.ArrayList(Value) = .empty;
        for (devs) |d| if (u.eqlIgnoreCase(u.str(d, "name") orelse "", key)) try by_name.append(c.a, d);
        if (by_name.items.len == 1) return u.str(by_name.items[0], "id") orelse "";
        const q = try u.debugQuote(c.a, key);
        if (by_name.items.len == 0) {
            var known: std.ArrayList(u8) = .empty;
            for (devs, 0..) |d, k| {
                if (k > 0) try known.appendSlice(c.a, ", ");
                try known.print(c.a, "{s} ({s})", .{ u.str(d, "name") orelse "", u.str(d, "id") orelse "" });
            }
            return c.fail("no device matches {s}; known: {s}", .{ q, known.items });
        }
        var list_ids: std.ArrayList(u8) = .empty;
        for (by_name.items, 0..) |d, k| {
            if (k > 0) try list_ids.appendSlice(c.a, ", ");
            try list_ids.appendSlice(c.a, u.str(d, "id") orelse "");
        }
        return c.fail("{d} devices are named {s}; use an id: {s}", .{ by_name.items.len, q, list_ids.items });
    }
};

// ---- resolution ---------------------------------------------------------------------

pub fn resolveChatIn(c: *Ctx, all: []const Value, key: []const u8) !Value {
    for (all) |ch| if (std.mem.eql(u8, u.str(ch, "id") orelse "", key)) return ch;
    var by_prefix: std.ArrayList(Value) = .empty;
    for (all) |ch| if (std.mem.startsWith(u8, u.str(ch, "id") orelse "", key)) try by_prefix.append(c.a, ch);
    if (by_prefix.items.len == 1) return by_prefix.items[0];
    var by_title: std.ArrayList(Value) = .empty;
    for (all) |ch| {
        if (u.str(ch, "title")) |t| if (u.eqlIgnoreCase(u.trim(t), key)) try by_title.append(c.a, ch);
    }
    if (by_title.items.len == 1) return by_title.items[0];
    const q = try u.debugQuote(c.a, key);
    if (by_prefix.items.len > 1) return c.fail("{d} chats start with {s}; be more specific: {s}", .{ by_prefix.items.len, q, try shortIds(c.a, by_prefix.items) });
    if (by_title.items.len > 1) return c.fail("{d} chats are titled {s}; use an id: {s}", .{ by_title.items.len, q, try shortIds(c.a, by_title.items) });
    return c.fail("no chat matches {s} (id, id prefix, or exact title); try list_chats", .{q});
}

fn shortIds(a: Allocator, items: []const Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |ch, k| {
        if (k > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, u.short(u.str(ch, "id") orelse ""));
    }
    return out.items;
}

fn trimEndSlashes(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "/\\");
}

/// `Space::display_name`: its name, else the folder's last component.
pub fn displayName(space: Value) []const u8 {
    if (u.str(space, "name")) |n| if (!u.isBlank(n)) return n;
    const path = u.str(space, "path") orelse "";
    const trimmed = trimEndSlashes(path);
    const at = std.mem.lastIndexOfAny(u8, trimmed, "/\\");
    const last = if (at) |k| trimmed[k + 1 ..] else trimmed;
    return if (last.len > 0) last else path;
}

pub fn resolveSpaceIn(c: *Ctx, all: []const Value, key: []const u8) !Value {
    if (key.len == 0) return c.failMsg("project is required");
    for (all) |sp| {
        if (std.mem.eql(u8, u.str(sp, "id") orelse "", key) or std.mem.eql(u8, u.str(sp, "path") orelse "", key)) return sp;
    }
    const normalized = trimEndSlashes(key);
    var by_name: std.ArrayList(Value) = .empty;
    for (all) |sp| if (u.eqlIgnoreCase(displayName(sp), normalized)) try by_name.append(c.a, sp);
    if (by_name.items.len == 1) return by_name.items[0];
    var by_suffix: std.ArrayList(Value) = .empty;
    for (all) |sp| {
        const path = trimEndSlashes(u.str(sp, "path") orelse "");
        if (std.mem.endsWith(u8, path, normalized) or std.mem.indexOf(u8, path, normalized) != null) try by_suffix.append(c.a, sp);
    }
    if (by_suffix.items.len == 1) return by_suffix.items[0];
    const candidates = if (by_name.items.len > 1) by_name.items else by_suffix.items;
    const q = try u.debugQuote(c.a, key);
    if (candidates.len > 1) {
        var listed: std.ArrayList(u8) = .empty;
        for (candidates, 0..) |sp, k| {
            if (k > 0) try listed.appendSlice(c.a, ", ");
            try listed.print(c.a, "{s} ({s})", .{ u.str(sp, "path") orelse "", u.str(sp, "id") orelse "" });
        }
        return c.fail("{d} projects match {s}; use an id: {s}", .{ candidates.len, q, listed.items });
    }
    return c.fail("no project matches {s} (id, path, or name); try list_projects", .{q});
}

fn findSpace(all: []const Value, id: ?[]const u8) ?Value {
    const want = id orelse return null;
    for (all) |sp| if (std.mem.eql(u8, u.str(sp, "id") orelse "", want)) return sp;
    return null;
}

pub fn ms(v: Value, key: []const u8) ?i64 {
    return u.parseRfc3339Ms(u.str(v, key) orelse return null);
}

/// The session row that speaks for `chat`: the host device's, else the
/// freshest one.
pub fn sessionFor(all: []const Value, chat: Value) ?Value {
    const chat_id = u.str(chat, "id") orelse "";
    const device = u.str(chat, "deviceId") orelse "";
    var best: ?Value = null;
    var best_at: i64 = std.math.minInt(i64);
    for (all) |s| {
        if (!std.mem.eql(u8, u.str(s, "chatId") orelse "", chat_id)) continue;
        if (std.mem.eql(u8, u.str(s, "deviceId") orelse "", device)) return s;
        const at = ms(s, "updatedAt") orelse 0;
        if (best == null or at >= best_at) {
            best = s;
            best_at = at;
        }
    }
    return best;
}

/// chrono's `DateTime<Utc>` serialization (`SecondsFormat::AutoSi`, `Z`):
/// whole seconds bare, else the fewest of 3, 6 or 9 fraction digits that
/// hold the time exactly.
pub fn timeValue(a: Allocator, v: Value, key: []const u8) !Value {
    const raw = u.str(v, key) orelse return .null;
    const at = u.parseRfc3339(raw) orelse return u.s(raw);
    var buf: [32]u8 = undefined;
    const secs = u.isoSecs(&buf, at.secs * 1000);
    const whole = secs[0 .. secs.len - 1];
    if (at.nanos == 0) return u.s(try a.dupe(u8, secs));
    if (at.nanos % 1_000_000 == 0) return u.s(try std.fmt.allocPrint(a, "{s}.{d:0>3}Z", .{ whole, at.nanos / 1_000_000 }));
    if (at.nanos % 1_000 == 0) return u.s(try std.fmt.allocPrint(a, "{s}.{d:0>6}Z", .{ whole, at.nanos / 1_000 }));
    return u.s(try std.fmt.allocPrint(a, "{s}.{d:0>9}Z", .{ whole, at.nanos }));
}

pub const Status = struct { label: []const u8, age_secs: ?i64 };

/// Live posture of one chat as the tools report it.
pub fn statusOf(session: ?Value, now_ms: i64) Status {
    const s = session orelse return .{ .label = "idle", .age_secs = null };
    const age_ms = now_ms - (ms(s, "updatedAt") orelse now_ms);
    const stale = age_ms > session_stale_ms;
    const st = u.str(s, "status") orelse "idle";
    const label = if (std.mem.eql(u8, st, "working"))
        (if (stale) "working (stale — host may be offline)" else "working")
    else
        st;
    return .{ .label = label, .age_secs = @max(0, @divTrunc(age_ms, 1000)) };
}

fn config(chat: Value) ?Value {
    const cfg = u.get(chat, "config") orelse return null;
    return if (cfg == .object) cfg else null;
}

pub fn chatHarness(chat: Value) ?[]const u8 {
    return u.str(config(chat) orelse return null, "harness");
}

pub fn projectValue(a: Allocator, space: ?Value) !Value {
    const sp = space orelse return .null;
    var o = u.obj(a);
    try o.put("id", u.field(sp, "id"));
    try o.put("name", u.s(displayName(sp)));
    try o.put("path", u.field(sp, "path"));
    return o.value();
}

pub fn summarizeChat(c: *Ctx, chat: Value, all_spaces: []const Value, all_sessions: []const Value) !u.Obj {
    const a = c.a;
    const space = findSpace(all_spaces, u.str(chat, "spaceId"));
    const st = statusOf(sessionFor(all_sessions, chat), c.t.nowMs());
    const cfg = config(chat);
    var o = u.obj(a);
    try o.put("id", u.field(chat, "id"));
    try o.put("title", u.field(chat, "title"));
    try o.put("project", try projectValue(a, space));
    try o.put("deviceId", u.field(chat, "deviceId"));
    try o.put("cwd", if (u.str(chat, "cwd")) |cw| u.s(cw) else if (space) |sp| u.field(sp, "path") else .null);
    try o.put("branch", u.field(chat, "branch"));
    try o.put("harness", if (cfg) |x| u.field(x, "harness") else .null);
    try o.put("model", if (cfg) |x| u.field(x, "model") else .null);
    try o.put("reasoning", if (cfg) |x| u.field(x, "reasoning") else .null);
    try o.put("archived", u.b(u.boolean(chat, "archived") orelse false));
    try o.put("parentChatId", u.field(chat, "parentChatId"));
    try o.put("status", u.s(st.label));
    try o.put("statusAgeSecs", if (st.age_secs) |n| u.i(n) else .null);
    try o.put("lastMessageAt", try timeValue(a, chat, "lastMessageAt"));
    try o.put("lastMessagePreview", u.field(chat, "lastMessagePreview"));
    try o.put("createdAt", try timeValue(a, chat, "createdAt"));
    return o;
}

// ---- harness rows ----------------------------------------------------------------------

pub fn harnessAvailable(h: Value) bool {
    return (u.boolean(h, "installed") orelse true) and (u.boolean(h, "enabled") orelse true);
}

pub fn steersMidTurn(h: Value) bool {
    return (u.boolean(h, "supportsSteering") orelse false) and
        std.mem.eql(u8, u.str(h, "steeringMode") orelse "turn-boundary", "step-boundary");
}

/// claude-code when offered here, else the first available non-mock harness.
pub fn defaultHarness(c: *Ctx, hs: []const Value) ![]const u8 {
    if (hs.len == 0) return "claude-code";
    for (hs) |h| if (std.mem.eql(u8, u.str(h, "id") orelse "", "claude-code") and harnessAvailable(h)) return "claude-code";
    for (hs) |h| {
        const id = u.str(h, "id") orelse continue;
        if (harnessAvailable(h) and !std.mem.eql(u8, id, "mock")) return id;
    }
    return c.failMsg("no harness is available on this device (see list_harnesses)");
}

fn findHarness(hs: []const Value, id: []const u8) ?Value {
    for (hs) |h| if (std.mem.eql(u8, u.str(h, "id") orelse "", id)) return h;
    return null;
}

/// `parse_enum`: the trimmed value must be one of `allowed`.
fn parseEnum(c: *Ctx, what: []const u8, raw: []const u8, allowed: []const []const u8) ![]const u8 {
    const t = u.trim(raw);
    for (allowed) |x| if (std.mem.eql(u8, x, t)) return x;
    return c.fail("unknown {s}: {s}", .{ what, try u.debugQuote(c.a, raw) });
}

fn harnessVariant(id: []const u8) []const u8 {
    for (harness_ids, 0..) |h, k| if (std.mem.eql(u8, h, id)) return harness_variants[k];
    return id;
}

// ---- argument checking (serde's wording) ---------------------------------------------------

pub const Kind = enum { string, opt_string, bool_default, opt_bool, opt_u64, usize_default, opt_usize, string_vec, answers };

pub const Field = struct {
    name: []const u8,
    kind: Kind,
    required: bool = false,
};

fn unexpected(a: Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .null => "null",
        .bool => |x| try std.fmt.allocPrint(a, "boolean `{}`", .{x}),
        .integer => |n| try std.fmt.allocPrint(a, "integer `{d}`", .{n}),
        .float => |x| if (x == @trunc(x) and @abs(x) < 1e16)
            try std.fmt.allocPrint(a, "floating point `{d}.0`", .{@as(i64, @intFromFloat(x))})
        else
            try std.fmt.allocPrint(a, "floating point `{d}`", .{x}),
        .number_string => |n| try std.fmt.allocPrint(a, "floating point `{s}`", .{n}),
        .string => |t| try std.fmt.allocPrint(a, "string {s}", .{try u.debugQuote(a, t)}),
        .array => "sequence",
        .object => "map",
    };
}

fn typeErr(c: *Ctx, v: Value, expected: []const u8) Error {
    return c.fail("invalid arguments: invalid type: {s}, expected {s}", .{ try unexpected(c.a, v), expected });
}

fn checkUnsigned(c: *Ctx, v: Value, expected: []const u8) !void {
    switch (v) {
        .integer => |n| if (n < 0) return c.fail("invalid arguments: invalid value: integer `{d}`, expected {s}", .{ n, expected }),
        else => return typeErr(c, v, expected),
    }
}

fn checkString(c: *Ctx, v: Value) !void {
    if (v != .string) return typeErr(c, v, "a string");
}

fn checkStringVec(c: *Ctx, v: Value) !void {
    if (v != .array) return typeErr(c, v, "a sequence");
    for (v.array.items) |x| try checkString(c, x);
}

/// `serde_json::from_value::<Struct>(args)` as the Rust tools call it:
/// fields checked in the order the caller sent them, then the first missing
/// required field; `deny_unknown` rejects anything else.
pub fn decode(c: *Ctx, args: Value, struct_name: []const u8, fields: []const Field, deny_unknown: bool) !void {
    if (args != .object) return c.fail("invalid arguments: invalid type: {s}, expected struct {s}", .{ try unexpected(c.a, args), struct_name });
    var it = args.object.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const v = e.value_ptr.*;
        const spec = for (fields) |f| {
            if (std.mem.eql(u8, f.name, key)) break f;
        } else {
            if (deny_unknown) {
                var expected: std.ArrayList(u8) = .empty;
                if (fields.len == 1) {
                    try expected.print(c.a, "`{s}`", .{fields[0].name});
                } else if (fields.len == 2) {
                    try expected.print(c.a, "`{s}` or `{s}`", .{ fields[0].name, fields[1].name });
                } else {
                    try expected.appendSlice(c.a, "one of ");
                    for (fields, 0..) |f, k| {
                        if (k > 0) try expected.appendSlice(c.a, ", ");
                        try expected.print(c.a, "`{s}`", .{f.name});
                    }
                }
                return c.fail("invalid arguments: unknown field `{s}`, expected {s}", .{ key, expected.items });
            }
            continue;
        };
        switch (spec.kind) {
            .string => try checkString(c, v),
            .opt_string => if (v != .null) try checkString(c, v),
            .bool_default => if (v != .bool) return typeErr(c, v, "a boolean"),
            .opt_bool => if (v != .null and v != .bool) return typeErr(c, v, "a boolean"),
            .opt_u64 => if (v != .null) try checkUnsigned(c, v, "u64"),
            .usize_default => try checkUnsigned(c, v, "usize"),
            .opt_usize => if (v != .null) try checkUnsigned(c, v, "usize"),
            .string_vec => try checkStringVec(c, v),
            .answers => {
                if (v != .array) return typeErr(c, v, "a sequence");
                for (v.array.items) |ans| {
                    if (ans != .object) return typeErr(c, ans, "struct AnswerArg");
                    var ait = ans.object.iterator();
                    while (ait.next()) |ae| {
                        if (std.mem.eql(u8, ae.key_ptr.*, "question_id")) try checkString(c, ae.value_ptr.*);
                        if (std.mem.eql(u8, ae.key_ptr.*, "labels")) try checkStringVec(c, ae.value_ptr.*);
                    }
                    if (ans.object.get("question_id") == null) return c.failMsg("invalid arguments: missing field `question_id`");
                    if (ans.object.get("labels") == null) return c.failMsg("invalid arguments: missing field `labels`");
                }
            },
        }
    }
    for (fields) |f| {
        if (f.required and args.object.get(f.name) == null) return c.fail("invalid arguments: missing field `{s}`", .{f.name});
    }
}

pub fn argStr(args: Value, key: []const u8) ?[]const u8 {
    return u.str(args, key);
}

pub fn argBool(args: Value, key: []const u8) ?bool {
    return u.boolean(args, key);
}

pub fn argUint(args: Value, key: []const u8) ?u64 {
    const v = u.get(args, key) orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

/// `Option<String>` trimmed and nonblank.
pub fn given(args: Value, key: []const u8) ?[]const u8 {
    const v = argStr(args, key) orelse return null;
    const t = u.trim(v);
    return if (t.len == 0) null else t;
}

const chat_fields = [_]Field{.{ .name = "chat", .kind = .string, .required = true }};

// ---- tools ---------------------------------------------------------------------------------

fn emptyObj(c: *Ctx) Value {
    return u.obj(c.a).value();
}

fn whoami(c: *Ctx) !Value {
    const a = c.a;
    const origin = c.t.origin;
    const local = try c.localDeviceId();
    const engine_info: Value = switch (try c.t.engine.call(a, "EngineInfo", "{}")) {
        .ok => |v| v,
        .err => .null,
    };
    const chat: Value = if (origin.chat_id) |id| blk: {
        var probe: Ctx = .{ .t = c.t, .a = a };
        const found = probe.resolveChat(id) catch |err| switch (err) {
            error.ToolFailed => {
                var o = u.obj(a);
                try o.put("id", u.s(id));
                break :blk o.value();
            },
            else => return err,
        };
        const sps = try c.spaces();
        const sss = try c.sessions();
        break :blk (try summarizeChat(c, found, sps, sss)).value();
    } else .null;
    var o = u.obj(a);
    try o.put("chat", chat);
    try o.put("originDeviceId", u.optS(origin.device_id));
    try o.put("localDeviceId", u.s(local));
    try o.put("workspaceScope", u.field(engine_info, "workspaceScope"));
    try o.put("note", u.s(if (origin.chat_id != null)
        "Messages you send are attributed to this chat; it cannot message itself."
    else
        "Not running inside a chat: messages are sent without attribution."));
    return o.value();
}

fn listDevices(c: *Ctx) !Value {
    const devs = try c.devices();
    const local = try c.localDeviceId();
    var out = u.arr(c.a);
    for (devs) |d| {
        var o = u.obj(c.a);
        try o.put("id", u.field(d, "id"));
        try o.put("name", u.field(d, "name"));
        try o.put("platform", u.field(d, "platform"));
        try o.put("local", u.b(std.mem.eql(u8, u.str(d, "id") orelse "", local)));
        try o.put("lastSeenAt", try timeValue(c.a, d, "lastSeenAt"));
        try o.put("version", u.field(d, "version"));
        try out.append(o.value());
    }
    var r = u.obj(c.a);
    try r.put("devices", .{ .array = out });
    return r.value();
}

fn listProjects(c: *Ctx) !Value {
    const sps = try c.spaces();
    const devs = try c.devices();
    var out = u.arr(c.a);
    for (sps) |sp| {
        const dev_id = u.str(sp, "deviceId") orelse "";
        var dev_name: Value = .null;
        for (devs) |d| if (std.mem.eql(u8, u.str(d, "id") orelse "", dev_id)) {
            dev_name = u.field(d, "name");
            break;
        };
        var o = u.obj(c.a);
        try o.put("id", u.field(sp, "id"));
        try o.put("name", u.s(displayName(sp)));
        try o.put("path", u.field(sp, "path"));
        try o.put("deviceId", u.field(sp, "deviceId"));
        try o.put("deviceName", dev_name);
        try o.put("git", u.b(u.boolean(sp, "gitDetected") orelse false));
        try out.append(o.value());
    }
    var r = u.obj(c.a);
    try r.put("projects", .{ .array = out });
    return r.value();
}

fn listHarnesses(c: *Ctx) !Value {
    const hs = try c.harnesses();
    var out = u.arr(c.a);
    for (hs) |h| {
        var o = u.obj(c.a);
        try o.put("id", u.field(h, "id"));
        try o.put("name", u.field(h, "name"));
        try o.put("available", u.b(harnessAvailable(h)));
        try o.put("installed", u.b(u.boolean(h, "installed") orelse true));
        try o.put("steersMidTurn", u.b(steersMidTurn(h)));
        try o.put("reasoningLevels", u.get(h, "reasoningLevels") orelse .{ .array = u.arr(c.a) });
        try out.append(o.value());
    }
    var r = u.obj(c.a);
    try r.put("harnesses", .{ .array = out });
    return r.value();
}

fn listModels(c: *Ctx, args: Value) !Value {
    try decode(c, args, "ListModelsArgs", &.{.{ .name = "harness", .kind = .string, .required = true }}, false);
    const harness = try parseEnum(c, "harness", argStr(args, "harness").?, &harness_ids);
    const ms_rows = try c.models(harness);
    var out = u.arr(c.a);
    for (ms_rows) |m| {
        var o = u.obj(c.a);
        try o.put("id", u.field(m, "id"));
        try o.put("label", u.field(m, "label"));
        try o.put("description", u.field(m, "description"));
        try o.put("reasoningLevels", u.get(m, "reasoningLevels") orelse .{ .array = u.arr(c.a) });
        try out.append(o.value());
    }
    var r = u.obj(c.a);
    try r.put("harness", u.s(harness));
    try r.put("models", .{ .array = out });
    return r.value();
}

fn activityMs(chat: Value) i64 {
    return ms(chat, "lastMessageAt") orelse ms(chat, "createdAt") orelse 0;
}

fn listChats(c: *Ctx, args: Value) !Value {
    try decode(c, args, "ListChatsArgs", &.{
        .{ .name = "project", .kind = .opt_string },
        .{ .name = "device", .kind = .opt_string },
        .{ .name = "include_archived", .kind = .bool_default },
        .{ .name = "parent", .kind = .opt_string },
        .{ .name = "limit", .kind = .opt_usize },
    }, false);
    var all: std.ArrayList(Value) = .empty;
    try all.appendSlice(c.a, try c.chats());
    const sps = try c.spaces();
    const sss = try c.sessions();
    if (given(args, "project")) |project| {
        const space = try c.resolveSpace(project);
        const sid = u.str(space, "id") orelse "";
        try retain(c.a, &all, struct {
            fn keep(ctx: []const u8, ch: Value) bool {
                return std.mem.eql(u8, u.str(ch, "spaceId") orelse "\x00", ctx);
            }
        }.keep, sid);
    }
    if (given(args, "device")) |device| {
        const dev = try c.resolveDeviceId(device);
        try retain(c.a, &all, struct {
            fn keep(ctx: []const u8, ch: Value) bool {
                return std.mem.eql(u8, u.str(ch, "deviceId") orelse "", ctx);
            }
        }.keep, dev);
    }
    if (!(argBool(args, "include_archived") orelse false)) {
        try retain(c.a, &all, struct {
            fn keep(_: []const u8, ch: Value) bool {
                return !(u.boolean(ch, "archived") orelse false);
            }
        }.keep, "");
    }
    if (given(args, "parent")) |parent_key| {
        const parent = try c.resolveChat(parent_key);
        try retain(c.a, &all, struct {
            fn keep(ctx: []const u8, ch: Value) bool {
                return std.mem.eql(u8, u.str(ch, "parentChatId") orelse "\x00", ctx);
            }
        }.keep, u.str(parent, "id") orelse "");
    }
    std.mem.sort(Value, all.items, {}, struct {
        fn lt(_: void, x: Value, y: Value) bool {
            return activityMs(x) > activityMs(y);
        }
    }.lt);
    // `sort_by` is stable; `std.mem.sort` is a stable insertion/block sort.
    const total = all.items.len;
    const limit = std.math.clamp(argUint(args, "limit") orelse 50, 1, 500);
    var out = u.arr(c.a);
    for (all.items[0..@min(total, limit)]) |ch| try out.append((try summarizeChat(c, ch, sps, sss)).value());
    var r = u.obj(c.a);
    try r.put("total", u.i(@intCast(total)));
    try r.put("chats", .{ .array = out });
    return r.value();
}

fn retain(a: Allocator, list: *std.ArrayList(Value), comptime keep: fn ([]const u8, Value) bool, ctx: []const u8) !void {
    _ = a;
    var w: usize = 0;
    for (list.items) |v| {
        if (keep(ctx, v)) {
            list.items[w] = v;
            w += 1;
        }
    }
    list.items.len = w;
}

fn getChat(c: *Ctx, args: Value) !Value {
    try decode(c, args, "ChatArgs", &chat_fields, false);
    const chat = try c.resolveChat(argStr(args, "chat").?);
    const sps = try c.spaces();
    const sss = try c.sessions();
    const entries = try c.transcriptOf(u.str(chat, "id") orelse "");
    const rendered = try transcript.render(c.a, entries, .{});
    var summary = try summarizeChat(c, chat, sps, sss);
    try summary.put("messageCount", u.i(@intCast(rendered.len)));
    try summary.put("pendingInput", transcript.lastPendingInput(rendered) orelse .null);
    try summary.put("lastMessage", if (rendered.len > 0) try rendered[rendered.len - 1].toValue(c.a) else .null);
    return summary.value();
}

pub const CreateChatArgs = struct {
    project: ?[]const u8 = null,
    device: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    harness: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    sandbox: ?[]const u8 = null,
    title: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    wait: bool = false,
    timeout_secs: ?u64 = null,
};

fn createChatTool(c: *Ctx, args: Value) !Value {
    try decode(c, args, "CreateChatArgs", &.{
        .{ .name = "project", .kind = .opt_string },
        .{ .name = "device", .kind = .opt_string },
        .{ .name = "parent", .kind = .opt_string },
        .{ .name = "harness", .kind = .opt_string },
        .{ .name = "model", .kind = .opt_string },
        .{ .name = "reasoning", .kind = .opt_string },
        .{ .name = "sandbox", .kind = .opt_string },
        .{ .name = "title", .kind = .opt_string },
        .{ .name = "branch", .kind = .opt_string },
        .{ .name = "cwd", .kind = .opt_string },
        .{ .name = "prompt", .kind = .opt_string },
        .{ .name = "wait", .kind = .bool_default },
        .{ .name = "timeout_secs", .kind = .opt_u64 },
    }, false);
    return createChat(c, .{
        .project = given(args, "project"),
        .device = given(args, "device"),
        .parent = given(args, "parent"),
        .harness = given(args, "harness"),
        .model = given(args, "model"),
        .reasoning = given(args, "reasoning"),
        .sandbox = given(args, "sandbox"),
        .title = given(args, "title"),
        .branch = given(args, "branch"),
        .cwd = given(args, "cwd"),
        .prompt = given(args, "prompt"),
        .wait = argBool(args, "wait") orelse false,
        .timeout_secs = argUint(args, "timeout_secs"),
    });
}

fn trimmedNonBlank(v: ?[]const u8) ?[]const u8 {
    const t = u.trim(v orelse return null);
    return if (t.len == 0) null else t;
}

pub fn newId(c: *Ctx) ![]const u8 {
    const buf = try c.a.create([36]u8);
    return ids.uuid(c.t.io, buf);
}

pub fn createChat(c: *Ctx, args: CreateChatArgs) !Value {
    const a = c.a;
    const hs = try c.harnesses();
    const harness: []const u8 = if (args.harness) |raw| blk: {
        const id = try parseEnum(c, "harness", raw, &harness_ids);
        if (findHarness(hs, id)) |info| {
            if (!harnessAvailable(info)) return c.fail("harness {s} is not available on this device (see list_harnesses)", .{raw});
        }
        break :blk id;
    } else try defaultHarness(c, hs);
    if (args.model) |model| {
        // A failed model listing is not a reason to refuse the chat.
        var probe: Ctx = .{ .t = c.t, .a = a };
        if (probe.models(harness)) |offered| {
            if (offered.len > 0) {
                const known = for (offered) |m| {
                    if (std.mem.eql(u8, u.str(m, "id") orelse "", model)) break true;
                } else false;
                if (!known) {
                    var listed: std.ArrayList(u8) = .empty;
                    for (offered, 0..) |m, k| {
                        if (k > 0) try listed.appendSlice(a, ", ");
                        try listed.appendSlice(a, u.str(m, "id") orelse "");
                    }
                    return c.fail("model {s} is not offered by {s}; available: {s}", .{ try u.debugQuote(a, model), harnessVariant(harness), listed.items });
                }
            }
        } else |err| if (err != error.ToolFailed) return err;
    }
    const reasoning: ?[]const u8 = if (args.reasoning) |raw| try parseEnum(c, "reasoning level", raw, &reasoning_levels) else null;
    const sandbox: []const u8 = if (args.sandbox) |raw| try parseEnum(c, "sandbox", raw, &sandbox_levels) else "workspace-write";
    var cfg = u.obj(a);
    try cfg.put("harness", u.s(harness));
    try cfg.put("model", u.optS(args.model));
    try cfg.put("reasoning", u.optS(reasoning));
    try cfg.put("modelOptions", emptyObj(c));
    try cfg.put("sandbox", u.s(sandbox));
    const config_v: Value = cfg.value();

    var space: ?Value = null;
    var device_id: []const u8 = undefined;
    if (args.project) |project| {
        space = try c.resolveSpace(project);
        device_id = u.str(space.?, "deviceId") orelse "";
    } else {
        device_id = try c.resolveDeviceId(args.device);
    }
    // The explicit parent, else the chat this server speaks for.
    const parent_chat_id: ?[]const u8 = if (trimmedNonBlank(args.parent)) |key|
        u.str(try c.resolveChat(key), "id")
    else
        c.t.origin.chat_id;

    const chat_id = try newId(c);
    var m = u.obj(a);
    try m.put("op", u.s("createChat"));
    try m.put("chatId", u.s(chat_id));
    try m.put("deviceId", u.s(device_id));
    try m.put("config", config_v);
    if (space) |sp| try m.put("spaceId", u.field(sp, "id"));
    if (parent_chat_id) |p| try m.put("parentChatId", u.s(p));
    if (trimmedNonBlank(args.branch)) |br| try m.put("branch", u.s(br));
    if (trimmedNonBlank(args.cwd)) |cw| try m.put("cwd", u.s(cw));
    _ = try c.mutate(m.value());
    if (trimmedNonBlank(args.title)) |title| {
        var r = u.obj(a);
        try r.put("op", u.s("renameChat"));
        try r.put("chatId", u.s(chat_id));
        try r.put("title", u.s(title));
        _ = try c.mutate(r.value());
    }

    var result = u.obj(a);
    try result.put("chatId", u.s(chat_id));
    try result.put("deviceId", u.s(device_id));
    try result.put("project", try projectValue(a, space));
    try result.put("harness", u.s(harness));
    try result.put("model", u.optS(args.model));
    try result.put("reasoning", u.optS(reasoning));
    try result.put("title", u.optS(args.title));
    try result.put("parentChatId", u.optS(parent_chat_id));
    if (args.prompt) |prompt| if (!u.isBlank(prompt)) {
        // The row may not have folded into WatchChats yet: build it locally.
        var chat = u.obj(a);
        try chat.put("id", u.s(chat_id));
        try chat.put("deviceId", u.s(device_id));
        try chat.put("title", u.optS(args.title));
        try chat.put("archived", u.b(false));
        try chat.put("cwd", u.optS(args.cwd));
        try chat.put("branch", u.optS(args.branch));
        try chat.put("config", config_v);
        try chat.put("parentChatId", u.optS(parent_chat_id));
        try chat.put("spaceId", if (space) |sp| u.field(sp, "id") else .null);
        const chat_v: Value = chat.value();
        try result.put("sent", try deliver(c, chat_v, space, hs, null, prompt, "run"));
        if (args.wait) {
            try result.put("turn", try awaitTurn(c, chat_v, null, true, waitLimit(c, args.timeout_secs), c.t.nowMs()));
        }
    };
    return result.value();
}

fn readChat(c: *Ctx, args: Value) !Value {
    try decode(c, args, "ReadChatArgs", &.{
        .{ .name = "chat", .kind = .string, .required = true },
        .{ .name = "limit", .kind = .opt_usize },
        .{ .name = "offset", .kind = .usize_default },
        .{ .name = "include_reasoning", .kind = .bool_default },
        .{ .name = "include_tools", .kind = .opt_bool },
    }, false);
    const chat = try c.resolveChat(argStr(args, "chat").?);
    const entries = try c.transcriptOf(u.str(chat, "id") orelse "");
    const rendered = try transcript.render(c.a, entries, .{
        .include_reasoning = argBool(args, "include_reasoning") orelse false,
        .include_tools = argBool(args, "include_tools") orelse true,
    });
    const total = rendered.len;
    const limit = std.math.clamp(argUint(args, "limit") orelse 40, 1, 500);
    const offset = argUint(args, "offset") orelse 0;
    const end = total -| offset;
    const start = end -| limit;
    var r = u.obj(c.a);
    try r.put("chatId", u.field(chat, "id"));
    try r.put("title", u.field(chat, "title"));
    try r.put("total", u.i(@intCast(total)));
    try r.put("returned", u.i(@intCast(end - start)));
    try r.put("olderRemaining", u.i(@intCast(start)));
    try r.put("newerSkipped", u.i(@intCast(total - end)));
    try r.put("pendingInput", transcript.lastPendingInput(rendered) orelse .null);
    try r.put("messages", try transcript.toValues(c.a, rendered[start..end]));
    return r.value();
}

fn sendMessage(c: *Ctx, args: Value) !Value {
    try decode(c, args, "SendArgs", &.{
        .{ .name = "chat", .kind = .string, .required = true },
        .{ .name = "text", .kind = .string, .required = true },
        .{ .name = "mode", .kind = .opt_string },
        .{ .name = "wait", .kind = .bool_default },
        .{ .name = "timeout_secs", .kind = .opt_u64 },
    }, false);
    const text = u.trim(argStr(args, "text").?);
    if (text.len == 0) return c.failMsg("text is empty");
    const chat = try c.resolveChat(argStr(args, "chat").?);
    const chat_id = u.str(chat, "id") orelse "";
    if (c.t.origin.chat_id) |o| if (std.mem.eql(u8, o, chat_id))
        return c.fail("refusing to send a message to your own chat ({s})", .{u.short(chat_id)});
    // Archived chats are out of the active collaboration set (#498).
    if ((u.boolean(chat, "archived") orelse false) and c.t.fromChat())
        return c.fail("no message was sent to chat {s}: {s}", .{ u.short(chat_id), archived_refusal });
    const sps = try c.spaces();
    const sss = try c.sessions();
    const hs = try c.harnesses();
    const space = findSpace(sps, u.str(chat, "spaceId"));
    const baseline = sessionFor(sss, chat);
    const mode = given(args, "mode") orelse "auto";
    const sent_at = c.t.nowMs();
    const body = try attribute(c, chat, text);
    if (c.t.origin.chat_id) |origin| {
        var p = u.obj(c.a);
        try p.put("chatId", u.s(chat_id));
        const queue = try c.snapshot("WatchQueue", p.value());
        const items = u.array(queue, "items") orelse return c.failMsg("WatchQueue: unexpected shape");
        for (items) |item| {
            if (u.str(item, "text")) |t| if (peer.fromSender(t, origin))
                return c.fail("your earlier message is still queued in chat {s}; no new message was sent. " ++
                    "Do not retry or send acknowledgements/progress; use an unmentioned room post " ++
                    "for progress and leave the pending question for the human", .{u.short(chat_id)});
        }
    }
    var r = u.obj(c.a);
    try r.put("chatId", u.s(chat_id));
    try r.put("title", u.field(chat, "title"));
    try r.put("sent", try deliver(c, chat, space, hs, baseline, body, mode));
    if (argBool(args, "wait") orelse false) {
        try r.put("turn", try awaitTurn(c, chat, baseline, true, waitLimit(c, argUint(args, "timeout_secs")), sent_at));
    }
    return r.value();
}

fn waitForTurnTool(c: *Ctx, args: Value) !Value {
    try decode(c, args, "WaitArgs", &.{
        .{ .name = "chat", .kind = .string, .required = true },
        .{ .name = "timeout_secs", .kind = .opt_u64 },
    }, false);
    const chat = try c.resolveChat(argStr(args, "chat").?);
    const turn = try awaitTurn(c, chat, null, false, waitLimit(c, argUint(args, "timeout_secs")), 0);
    var r = u.obj(c.a);
    try r.put("chatId", u.field(chat, "id"));
    try r.put("title", u.field(chat, "title"));
    try r.put("turn", turn);
    return r.value();
}

fn renameChat(c: *Ctx, args: Value) !Value {
    try decode(c, args, "RenameArgs", &.{
        .{ .name = "chat", .kind = .string, .required = true },
        .{ .name = "title", .kind = .string, .required = true },
    }, false);
    const title = u.trim(argStr(args, "title").?);
    if (title.len == 0) return c.failMsg("rename_chat needs a nonblank title");
    const chat = try c.resolveChat(argStr(args, "chat").?);
    var m = u.obj(c.a);
    try m.put("op", u.s("renameChat"));
    try m.put("chatId", u.field(chat, "id"));
    try m.put("title", u.s(title));
    _ = try c.mutate(m.value());
    var r = u.obj(c.a);
    try r.put("chatId", u.field(chat, "id"));
    try r.put("previousTitle", u.field(chat, "title"));
    try r.put("title", u.s(title));
    return r.value();
}

fn archiveChat(c: *Ctx, args: Value) !Value {
    try decode(c, args, "ArchiveArgs", &.{
        .{ .name = "chat", .kind = .string, .required = true },
        .{ .name = "archived", .kind = .opt_bool },
    }, false);
    const chat = try c.resolveChat(argStr(args, "chat").?);
    const archived = argBool(args, "archived") orelse true;
    var m = u.obj(c.a);
    try m.put("op", u.s("setChatArchived"));
    try m.put("chatId", u.field(chat, "id"));
    try m.put("archived", u.b(archived));
    _ = try c.mutate(m.value());
    var r = u.obj(c.a);
    try r.put("chatId", u.field(chat, "id"));
    try r.put("title", u.field(chat, "title"));
    try r.put("archived", u.b(archived));
    return r.value();
}

fn interruptChat(c: *Ctx, args: Value) !Value {
    try decode(c, args, "ChatArgs", &chat_fields, false);
    const chat = try c.resolveChat(argStr(args, "chat").?);
    var cmd = u.obj(c.a);
    try cmd.put("kind", u.s("interrupt"));
    const command_id = try c.queueCommand(u.str(chat, "id") orelse "", cmd.value());
    var r = u.obj(c.a);
    try r.put("chatId", u.field(chat, "id"));
    try r.put("commandId", u.s(command_id));
    return r.value();
}

const respond_fields = [_]Field{
    .{ .name = "chat", .kind = .string, .required = true },
    .{ .name = "request_id", .kind = .opt_string },
    .{ .name = "answers", .kind = .answers },
};

/// The given request id, else the chat's current pending question.
fn pendingRequestId(c: *Ctx, chat: Value, args: Value) ![]const u8 {
    if (given(args, "request_id")) |id| return id;
    const chat_id = u.str(chat, "id") orelse "";
    const rendered = try transcript.render(c.a, try c.transcriptOf(chat_id), .{});
    if (transcript.lastPendingInput(rendered)) |p| if (u.str(p, "requestId")) |id| return id;
    return c.fail("chat {s} has no pending question", .{u.short(chat_id)});
}

fn dismissInput(c: *Ctx, args: Value) !Value {
    try decode(c, args, "RespondArgs", &respond_fields, false);
    const chat = try c.resolveChat(argStr(args, "chat").?);
    if ((u.array(args, "answers") orelse u.none).len > 0) return c.failMsg("dismiss_input never accepts answers");
    const request_id = try pendingRequestId(c, chat, args);
    var cmd = u.obj(c.a);
    try cmd.put("kind", u.s("dismissInput"));
    try cmd.put("requestId", u.s(request_id));
    const command_id = try c.queueCommand(u.str(chat, "id") orelse "", cmd.value());
    var r = u.obj(c.a);
    try r.put("chatId", u.field(chat, "id"));
    try r.put("requestId", u.s(request_id));
    try r.put("commandId", u.s(command_id));
    return r.value();
}

fn isHumanApprovalQuestion(q: Value) bool {
    if (u.boolean(q, "requiresHumanUi") orelse false) return true;
    const id = u.str(q, "id") orelse "";
    if (std.mem.startsWith(u8, id, "permission:")) return true;
    const hdr = std.mem.trim(u8, u.str(q, "header") orelse "", " \t\r\n");
    const eq = std.ascii.eqlIgnoreCase;
    return eq(hdr, "approve tool") or eq(hdr, "approve command") or
        eq(hdr, "approve file change") or eq(hdr, "permission") or
        eq(hdr, "approve");
}

fn findPendingInput(c: *Ctx, chat_id: []const u8, wanted_id: ?[]const u8) !?Value {
    const rendered = try transcript.render(c.a, try c.transcriptOf(chat_id), .{});
    if (wanted_id) |want_id| {
        var k = rendered.len;
        while (k > 0) {
            k -= 1;
            if (rendered[k].pending_input) |p| {
                if (std.mem.eql(u8, u.str(p, "requestId") orelse "", want_id)) return p;
            }
        }
        return null;
    }
    return transcript.lastPendingInput(rendered);
}

fn respondToInput(c: *Ctx, args: Value) !Value {
    try decode(c, args, "RespondArgs", &respond_fields, false);
    const chat = try c.resolveChat(argStr(args, "chat").?);
    const chat_id = u.str(chat, "id") orelse "";
    const given_id = given(args, "request_id");
    const pending = try findPendingInput(c, chat_id, given_id);
    const request_id = given_id orelse (if (pending) |p| u.str(p, "requestId") else null) orelse
        return c.fail("chat {s} has no pending question", .{u.short(chat_id)});
    if (pending) |p| {
        for (u.array(p, "questions") orelse u.none) |q| {
            if (isHumanApprovalQuestion(q)) {
                return c.failMsg("this prompt requires human approval in the Harness UI");
            }
        }
    }
    const given_answers = u.array(args, "answers") orelse u.none;
    if (given_answers.len == 0) return c.failMsg("answers is empty");
    var answers = u.arr(c.a);
    for (given_answers) |ans| {
        var o = u.obj(c.a);
        try o.put("questionId", u.field(ans, "question_id"));
        try o.put("labels", u.field(ans, "labels"));
        try answers.append(o.value());
    }
    var cmd = u.obj(c.a);
    try cmd.put("kind", u.s("respondInput"));
    try cmd.put("requestId", u.s(request_id));
    try cmd.put("answers", .{ .array = answers });
    try cmd.put("fromAgent", u.b(true));
    const command_id = try c.queueCommand(chat_id, cmd.value());
    var r = u.obj(c.a);
    try r.put("chatId", u.field(chat, "id"));
    try r.put("requestId", u.s(request_id));
    try r.put("commandId", u.s(command_id));
    return r.value();
}

// ---- shared pieces --------------------------------------------------------------------------

/// Prefix the sender's identity when this server speaks for a chat.
fn attribute(c: *Ctx, target: Value, text: []const u8) ![]const u8 {
    const origin_id = c.t.origin.chat_id orelse return text;
    if (std.mem.eql(u8, origin_id, u.str(target, "id") orelse "")) return text;
    const rendered = try transcript.render(c.a, try c.transcriptOf(origin_id), .{});
    // Peer-inbox mail is not in the transcript; the ledger carries its depth.
    const ledger = c.t.relay.inbound(c.a, origin_id, rendered, c.t.nowMs());
    const inbound = @max(peer.inboundDepth(rendered), ledger);
    const depth = peer.checkedNext(inbound) orelse return c.failMsg(peer.chain_limit_msg);
    var probe: Ctx = .{ .t = c.t, .a = c.a };
    const title: ?[]const u8 = if (probe.resolveChat(origin_id)) |ch| u.str(ch, "title") else |err| switch (err) {
        error.ToolFailed => null,
        else => return err,
    };
    const label = if (title) |t| (if (!u.isBlank(t))
        try std.fmt.allocPrint(c.a, "{s} ({s})", .{ u.trim(t), u.short(origin_id) })
    else
        u.short(origin_id)) else u.short(origin_id);
    return peer.frame(c.a, label, origin_id, depth, text);
}

/// Pick and perform the delivery the composer would.
pub fn deliver(c: *Ctx, chat: Value, space: ?Value, hs: []const Value, session: ?Value, text: []const u8, mode: []const u8) !Value {
    const a = c.a;
    const eq = std.mem.eql;
    const chat_id = u.str(chat, "id") orelse "";
    const harness = chatHarness(chat) orelse try defaultHarness(c, hs);
    const info = findHarness(hs, harness);
    const now = c.t.nowMs();
    const status = statusOf(session, now).label;
    const live: []const u8 = if (session) |s| blk: {
        const st = u.str(s, "status") orelse "idle";
        const stale = now - (ms(s, "updatedAt") orelse now) > session_stale_ms;
        break :blk if (stale and eq(u8, st, "working")) "idle" else st;
    } else "idle";
    const steers = if (info) |h| steersMidTurn(h) else false;
    // A working graff chat here reads its own peer inbox mid-turn.
    const peer_to: ?[]const u8 = if (eq(u8, mode, "auto") and eq(u8, live, "working") and !steers)
        try graffPeerTarget(c, chat, harness, session)
    else
        null;
    var chosen: []const u8 = undefined;
    if (eq(u8, mode, "auto")) {
        if (eq(u8, live, "working")) {
            chosen = if (steers) "steer" else if (peer_to != null) "peer" else "queue";
        } else if (eq(u8, live, "awaitingInput")) {
            return c.fail("chat {s} is waiting for an answer; use respond_to_input (or mode 'queue' to hold this message for after the turn)", .{u.short(chat_id)});
        } else {
            chosen = "run";
        }
    } else if (eq(u8, mode, "run") or eq(u8, mode, "steer") or eq(u8, mode, "queue")) {
        chosen = mode;
    } else {
        return c.fail("unknown mode {s}; expected auto, run, steer, or queue", .{try u.debugQuote(a, mode)});
    }
    var fallback: ?[]const u8 = null;
    var id: []const u8 = undefined;
    if (eq(u8, chosen, "run")) {
        const cfg = config(chat);
        const cwd: []const u8 = u.str(chat, "cwd") orelse (if (space) |sp| u.str(sp, "path") else null) orelse "~";
        var req = u.obj(a);
        try req.put("prompt", u.s(text));
        try req.put("turnOrigin", u.s("peer"));
        try req.put("harness", u.s(harness));
        try req.put("model", if (cfg) |x| u.field(x, "model") else .null);
        try req.put("reasoning", if (cfg) |x| u.field(x, "reasoning") else .null);
        try req.put("modelOptions", if (cfg) |x| (u.get(x, "modelOptions") orelse emptyObj(c)) else emptyObj(c));
        try req.put("cwd", u.s(cwd));
        try req.put("sandbox", if (cfg) |x| (u.get(x, "sandbox") orelse u.s("workspace-write")) else u.s("workspace-write"));
        try req.put("autoApprove", u.b(false));
        try req.put("resume", .null);
        var cmd = u.obj(a);
        try cmd.put("kind", u.s("run"));
        try cmd.put("request", req.value());
        try cmd.put("messageId", u.s(try newId(c)));
        id = try c.queueCommand(chat_id, cmd.value());
    } else if (eq(u8, chosen, "steer")) {
        var cmd = u.obj(a);
        try cmd.put("kind", u.s("steer"));
        try cmd.put("prompt", u.s(text));
        try cmd.put("turnOrigin", u.s("peer"));
        try cmd.put("messageId", u.s(try newId(c)));
        id = try c.queueCommand(chat_id, cmd.value());
    } else if (eq(u8, chosen, "peer")) {
        const to = peer_to.?;
        const origin = c.t.origin.chat_id;
        const from = if (origin) |o| try std.fmt.allocPrint(a, "harness:{s}", .{u.short(o)}) else "harness";
        // Record the hop before sending: unrecorded, it would not count.
        const record_err: ?[]const u8 = if (origin) |o|
            try c.t.relay.record(a, chat_id, peer.relayDepth(text), o, now)
        else blk: {
            c.t.relay.clear(a, chat_id);
            break :blk null;
        };
        const sent: peer.PeerSend.SendResult = if (record_err) |e|
            .{ .err = try std.fmt.allocPrint(a, "relay depth not recorded: {s}", .{e}) }
        else
            try c.t.peer.send(a, from, to, text);
        switch (sent) {
            .ok => |detail| {
                var r = u.obj(a);
                try r.put("delivery", u.s("peer"));
                try r.put("id", u.s(to));
                try r.put("detail", u.s(detail));
                try r.put("chatStatusAtSend", u.s(status));
                return r.value();
            },
            // Explicit fallback: the queue still delivers at turn end.
            .err => |why| {
                chosen = "queue";
                fallback = why;
                id = try c.queueMessage(chat_id, text);
            },
        }
    } else {
        id = try c.queueMessage(chat_id, text);
    }
    var r = u.obj(a);
    try r.put("delivery", u.s(chosen));
    try r.put("id", u.s(id));
    try r.put("chatStatusAtSend", u.s(status));
    if (fallback) |f| try r.put("peerFallback", u.s(f));
    return r.value();
}

fn graffPeerTarget(c: *Ctx, chat: Value, harness: []const u8, session: ?Value) !?[]const u8 {
    if (!std.mem.eql(u8, harness, "graff")) return null;
    const local = c.t.origin.device_id orelse blk: {
        var probe: Ctx = .{ .t = c.t, .a = c.a };
        break :blk probe.localDeviceId() catch |err| switch (err) {
            error.ToolFailed => return null,
            else => return err,
        };
    };
    return peer.peerTarget(chat, harness, session, local);
}

fn waitLimit(c: *Ctx, secs: ?u64) i64 {
    // A chat caller receives the recipient's reply asynchronously: its waits
    // are status snapshots, never blocking tool calls.
    if (c.t.fromChat()) return 0;
    const want: i64 = if (secs) |n| @as(i64, @intCast(@min(n, @as(u64, 3_600)))) * 1000 else default_wait_ms;
    return @min(want, max_wait_ms);
}

// ---- turn waiting ------------------------------------------------------------------------------

pub const TurnOutcome = enum {
    completed,
    awaitingInput,
    errored,
    timedOut,
};

/// A session row's completion marker, as the engine sent it: the Zig
/// engine writes the turn's entry id (a string), an edge op or an older
/// engine a counter (a number). Absent and `null` are both "none".
pub fn turnMarker(row: Value) ?Value {
    const v = u.get(row, "lastCompletedTurn") orelse return null;
    return if (v == .null) null else v;
}

/// Raw JSON equality of two markers: same type and value, so a string and
/// a number never match.
fn sameMarker(x: Value, y: Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .string => |t| std.mem.eql(u8, t, y.string),
        .number_string => |t| std.mem.eql(u8, t, y.number_string),
        .integer => |n| n == y.integer,
        .float => |f| f == y.float,
        .bool => |v| v == y.bool,
        .null => true,
        // Not a marker any engine sends; compare the compact text.
        .array, .object => {
            var bx: [512]u8 = undefined;
            var by: [512]u8 = undefined;
            var wx: std.Io.Writer = .fixed(&bx);
            var wy: std.Io.Writer = .fixed(&by);
            json.Stringify.value(x, .{}, &wx) catch return false;
            json.Stringify.value(y, .{}, &wy) catch return false;
            return std.mem.eql(u8, wx.buffered(), wy.buffered());
        },
    };
}

fn sameTurn(x: ?Value, y: ?Value) bool {
    const xm = if (x) |v| turnMarker(v) else null;
    const ym = if (y) |v| turnMarker(v) else null;
    if (xm == null and ym == null) return true;
    if (xm == null or ym == null) return false;
    return sameMarker(xm.?, ym.?);
}

fn advancedPast(row: Value, baseline: ?Value) bool {
    const b = baseline orelse return true;
    return (ms(row, "updatedAt") orelse 0) > (ms(b, "updatedAt") orelse 0) or !sameTurn(row, b);
}

/// The zero-timeout answer: one bounded snapshot of the chat's posture.
pub fn snapshotOutcome(row: ?Value, baseline: ?Value, expect_turn: bool) TurnOutcome {
    const r = row orelse return if (!expect_turn) .completed else .timedOut;
    if (expect_turn and !advancedPast(r, baseline)) return .timedOut;
    const st = u.str(r, "status") orelse "idle";
    if (std.mem.eql(u8, st, "awaitingInput")) return .awaitingInput;
    if (std.mem.eql(u8, st, "errored")) return .errored;
    if (std.mem.eql(u8, st, "idle")) {
        const has_turn = turnMarker(r) != null;
        if (!expect_turn or (has_turn and (baseline == null or !sameTurn(baseline, r)))) return .completed;
    }
    return .timedOut;
}

/// One step of the blocking wait over a `WatchSessions` item.
pub const TurnWatch = struct {
    baseline: ?Value,
    expect_turn: bool,
    saw_working: bool = false,
    last: ?Value = null,

    pub fn observe(w: *TurnWatch, row: ?Value) ?TurnOutcome {
        const session = row orelse {
            // No row: the chat never ran. With a send in flight the row
            // appears when the host picks it up.
            return if (w.expect_turn) null else .completed;
        };
        const advanced = advancedPast(session, w.baseline);
        const st = u.str(session, "status") orelse "idle";
        if (std.mem.eql(u8, st, "working")) {
            w.saw_working = true;
            w.last = session;
            return null;
        }
        if (std.mem.eql(u8, st, "awaitingInput") and (advanced or w.saw_working)) {
            w.last = session;
            return .awaitingInput;
        }
        if (std.mem.eql(u8, st, "errored") and (advanced or w.saw_working)) {
            w.last = session;
            return .errored;
        }
        if (std.mem.eql(u8, st, "idle")) {
            const turn_changed = if (w.baseline) |b|
                !sameTurn(b, session)
            else if (w.expect_turn)
                turnMarker(session) != null
            else
                true;
            w.last = session;
            if (turn_changed or w.saw_working) return .completed;
            return null;
        }
        w.last = session;
        return null;
    }
};

const Waited = struct { outcome: TurnOutcome, session: ?Value };

/// Block until `chat`'s turn settles (`Harness::wait_for_turn`).
fn waitForTurn(c: *Ctx, chat: Value, baseline: ?Value, expect_turn: bool, timeout_ms: i64) !Waited {
    if (timeout_ms <= 0) {
        const row = sessionFor(try c.sessions(), chat);
        return .{ .outcome = snapshotOutcome(row, baseline, expect_turn), .session = row };
    }
    const t = c.t;
    const deadline = nowMsReal(t) + timeout_ms;
    var w: TurnWatch = .{ .baseline = baseline, .expect_turn = expect_turn, .last = baseline };
    while (true) {
        if (deadline - nowMsReal(t) <= 0) return .{ .outcome = .timedOut, .session = w.last };
        const sub = switch (try t.engine.subscribe(c.a, "WatchSessions", "{}")) {
            .sub => |s| s,
            .err => |m| return c.failMsg(m),
        };
        defer sub.close();
        while (true) {
            const remaining = deadline - nowMsReal(t);
            if (remaining <= 0) return .{ .outcome = .timedOut, .session = w.last };
            switch (try sub.next(c.a, remaining)) {
                .timeout => return .{ .outcome = .timedOut, .session = w.last },
                .ended => {
                    Io.sleep(t.io, .fromMilliseconds(resubscribe_delay_ms), .awake) catch {};
                    break;
                },
                .item => |item| {
                    if (item != .array) continue;
                    if (w.observe(sessionFor(item.array.items, chat))) |outcome| return .{ .outcome = outcome, .session = w.last };
                },
            }
        }
    }
}

fn nowMsReal(t: *const Tools) i64 {
    return t.nowMsReal();
}

/// Wait, then report the outcome with the replies of the turn waited on.
pub fn awaitTurn(c: *Ctx, chat: Value, baseline: ?Value, expect_turn: bool, timeout_ms: i64, since_ms: i64) !Value {
    const a = c.a;
    const waited = try waitForTurn(c, chat, baseline, expect_turn, timeout_ms);
    var probe: Ctx = .{ .t = c.t, .a = a };
    const entries: []const Value = probe.transcriptOf(u.str(chat, "id") orelse "") catch |err| switch (err) {
        error.ToolFailed => &.{},
        else => return err,
    };
    const rendered = try transcript.render(a, entries, .{});
    const replies = try transcript.turnReplies(a, entries, since_ms);
    const status = statusOf(waited.session, c.t.nowMs()).label;
    const timed_out = waited.outcome == .timedOut;
    var turn = u.obj(a);
    try turn.put("outcome", u.s(@tagName(waited.outcome)));
    try turn.put("status", u.s(status));
    try turn.put("timedOut", u.b(timed_out));
    try turn.put("pendingInput", transcript.lastPendingInput(rendered) orelse .null);
    try turn.put("replies", try transcript.toValues(a, replies.replies));
    if (replies.truncated) {
        try turn.put("repliesTruncated", u.b(true));
        try turn.put("repliesNote", u.s(transcript.replies_truncated_note));
    }
    if (timed_out and c.t.fromChat()) try turn.put("note", u.s(chat_wait_note));
    return turn.value();
}

// ---- publishing into the origin chat ------------------------------------------------------------

fn showImage(c: *Ctx, args: Value) !Value {
    // Unknown fields (chat, id, targetDeviceId) are refused: the destination
    // is always the injected origin chat, never caller-chosen.
    try decode(c, args, "ShowImageArgs", &.{
        .{ .name = "path", .kind = .string, .required = true },
        .{ .name = "caption", .kind = .opt_string },
    }, true);
    const chat_id = c.t.origin.chat_id orelse return c.failMsg("show_image needs a chat context: this server is not running inside a chat");
    const path = argStr(args, "path").?;
    // Whitespace is legal in filenames; only a fully blank path fails.
    if (u.isBlank(path) or u.charCount(path) > 4096) return c.failMsg("show_image path must be 1-4096 characters");
    const caption = argStr(args, "caption");
    if (caption) |cap| if (u.charCount(cap) > 200) return c.failMsg("show_image caption is limited to 200 characters");
    var p = u.obj(c.a);
    try p.put("chatId", u.s(chat_id));
    // Minted per invocation, so the client's one reconnect retry dedupes.
    try p.put("id", u.s(try newId(c)));
    try p.put("path", u.s(path));
    try p.put("caption", u.optS(caption));
    return c.call("ShowImage", p.value());
}

pub const visual_title_max_chars: usize = 200;
pub const visual_script_max_bytes: usize = 64 * 1024;

/// `harness_proto::visual::validate_visual`.
pub fn validateVisual(title: []const u8, script: []const u8) ?[]const u8 {
    if (u.isBlank(title) or u.charCount(title) > visual_title_max_chars) return "visual title must be nonblank and at most 200 characters";
    if (u.isBlank(script) or script.len > visual_script_max_bytes) return "visual script must be nonblank and at most 64 KiB of UTF-8";
    return null;
}

fn showVisual(c: *Ctx, args: Value) !Value {
    try decode(c, args, "ShowVisualArgs", &.{
        .{ .name = "title", .kind = .string, .required = true },
        .{ .name = "script", .kind = .string, .required = true },
    }, true);
    const chat_id = c.t.origin.chat_id orelse return c.failMsg("show_visual needs a chat context: this server is not running inside a chat");
    const title = argStr(args, "title").?;
    const script = argStr(args, "script").?;
    if (validateVisual(title, script)) |why| return c.failMsg(why);
    var p = u.obj(c.a);
    try p.put("chatId", u.s(chat_id));
    try p.put("id", u.s(try newId(c)));
    try p.put("title", u.s(title));
    try p.put("script", u.s(script));
    return c.call("ShowVisual", p.value());
}

pub const artifact_title_max_chars: usize = 200;
pub const artifact_content_max_bytes: usize = 2 * 1024 * 1024;

fn isValidArtifactFormat(fmt: []const u8) bool {
    return std.mem.eql(u8, fmt, "html") or std.mem.eql(u8, fmt, "svg") or std.mem.eql(u8, fmt, "markdown");
}

fn isValidArtifactVisibility(vis: []const u8) bool {
    return std.mem.eql(u8, vis, "private") or std.mem.eql(u8, vis, "public");
}

fn createArtifact(c: *Ctx, args: Value) !Value {
    try decode(c, args, "CreateArtifactArgs", &.{
        .{ .name = "title", .kind = .string, .required = true },
        .{ .name = "format", .kind = .string, .required = true },
        .{ .name = "content", .kind = .string, .required = true },
        .{ .name = "visibility", .kind = .string },
    }, true);
    const chat_id = c.t.origin.chat_id orelse return c.failMsg("create_artifact needs a chat context: this server is not running inside a chat");
    const title = argStr(args, "title").?;
    const format = argStr(args, "format").?;
    const content = argStr(args, "content").?;
    const visibility = argStr(args, "visibility");
    if (u.isBlank(title) or u.charCount(std.mem.trim(u8, title, " \t\r\n")) > artifact_title_max_chars) {
        return c.failMsg("artifact title must be nonblank and at most 200 characters");
    }
    if (!isValidArtifactFormat(format)) return c.failMsg("artifact format must be html, svg, or markdown");
    if (content.len == 0 or content.len > artifact_content_max_bytes) {
        return c.failMsg("artifact content must be non-empty and at most 2 MiB");
    }
    if (visibility) |vis| if (!isValidArtifactVisibility(vis)) return c.failMsg("artifact visibility must be private or public");
    var p = u.obj(c.a);
    try p.put("chatId", u.s(chat_id));
    try p.put("id", u.s(try newId(c)));
    try p.put("title", u.s(std.mem.trim(u8, title, " \t\r\n")));
    try p.put("format", u.s(format));
    try p.put("content", u.s(content));
    if (visibility) |vis| try p.put("visibility", u.s(vis));
    return c.call("CreateArtifact", p.value());
}

fn updateArtifact(c: *Ctx, args: Value) !Value {
    try decode(c, args, "UpdateArtifactArgs", &.{
        .{ .name = "artifactId", .kind = .string, .required = true },
        .{ .name = "title", .kind = .string },
        .{ .name = "format", .kind = .string },
        .{ .name = "content", .kind = .string },
        .{ .name = "visibility", .kind = .string },
    }, true);
    const chat_id = c.t.origin.chat_id orelse return c.failMsg("update_artifact needs a chat context: this server is not running inside a chat");
    const artifact_id = argStr(args, "artifactId").?;
    if (!@import("../artifact_url.zig").isValidId(artifact_id)) {
        return c.failMsg("artifactId must be art- followed by 24 lowercase hex characters");
    }
    const title = argStr(args, "title");
    const format = argStr(args, "format");
    const content = argStr(args, "content");
    const visibility = argStr(args, "visibility");
    if (title == null and format == null and content == null and visibility == null) {
        return c.failMsg("update_artifact needs at least one of title, format, content, or visibility");
    }
    if (title) |t| if (u.isBlank(t) or u.charCount(std.mem.trim(u8, t, " \t\r\n")) > artifact_title_max_chars) {
        return c.failMsg("artifact title must be nonblank and at most 200 characters");
    };
    if (format) |f| if (!isValidArtifactFormat(f)) return c.failMsg("artifact format must be html, svg, or markdown");
    if (content) |body| if (body.len == 0 or body.len > artifact_content_max_bytes) {
        return c.failMsg("artifact content must be non-empty and at most 2 MiB");
    };
    if (visibility) |vis| if (!isValidArtifactVisibility(vis)) return c.failMsg("artifact visibility must be private or public");
    var p = u.obj(c.a);
    try p.put("chatId", u.s(chat_id));
    try p.put("artifactId", u.s(artifact_id));
    if (title) |t| try p.put("title", u.s(std.mem.trim(u8, t, " \t\r\n")));
    if (format) |f| try p.put("format", u.s(f));
    if (content) |body| try p.put("content", u.s(body));
    if (visibility) |vis| try p.put("visibility", u.s(vis));
    return c.call("UpdateArtifact", p.value());
}
