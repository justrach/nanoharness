//! MCP tool unit tests using the scripted `World` engine double (ported from
//! `zig/full` `mcp/tests.zig`, decoupled from `engine_host.zig`).
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const mcp = @import("../mcp_server.zig");
const tools = @import("tools.zig");
const link = @import("engine_link.zig");
const peer = @import("peer.zig");
const bots = @import("bots.zig");
const u = @import("util.zig");
const Value = json.Value;

const host_now: i64 = 1794271500000;

const FakePeer = struct {
    sends: std.ArrayList([3][]const u8) = .empty,
    fail: ?[]const u8 = null,
    a: Allocator,

    fn peerSend(self: *FakePeer) peer.PeerSend {
        return .{ .ptr = self, .send_fn = send };
    }

    fn send(ptr: *anyopaque, _: Allocator, from: []const u8, to: []const u8, text: []const u8) anyerror!peer.PeerSend.SendResult {
        const self: *FakePeer = @ptrCast(@alignCast(ptr));
        try self.sends.append(self.a, .{ try self.a.dupe(u8, from), try self.a.dupe(u8, to), try self.a.dupe(u8, text) });
        if (self.fail) |f| return .{ .err = f };
        return .{ .ok = "delivered to peer inbox" };
    }
};

const FakeBots = struct {
    a: Allocator,
    calls: std.ArrayList([]const u8) = .empty,
    /// `args joined by space` → stdout; missing → `unknown command`.
    outputs: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn cli(self: *FakeBots) bots.BotCli {
        return .{ .ptr = self, .bot_fn = run };
    }

    fn set(self: *FakeBots, args: []const u8, out: []const u8) !void {
        try self.outputs.put(self.a, args, out);
    }

    fn run(ptr: *anyopaque, a: Allocator, folder: []const u8, args: []const []const u8) anyerror!bots.BotCli.Result {
        const self: *FakeBots = @ptrCast(@alignCast(ptr));
        const joined = try std.mem.join(self.a, " ", args);
        try self.calls.append(self.a, try std.fmt.allocPrint(self.a, "{s}: {s}", .{ folder, joined }));
        if (self.outputs.get(joined)) |out| return .{ .ok = try a.dupe(u8, out) };
        return .{ .err = "unknown command" };
    }
};

/// Logs every call it forwards, so tests see what reached the engine.
const Recorder = struct {
    inner: link.Engine,
    a: Allocator,
    log: std.ArrayList([2][]const u8) = .empty,

    fn engine(self: *Recorder) link.Engine {
        return .{ .ptr = self, .vtable = &.{ .call = callFn, .subscribe = subFn } };
    }

    fn callFn(ptr: *anyopaque, a: Allocator, method: []const u8, params: []const u8) anyerror!link.Result {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        try self.log.append(self.a, .{ try self.a.dupe(u8, method), try self.a.dupe(u8, params) });
        return self.inner.call(a, method, params);
    }

    fn subFn(ptr: *anyopaque, a: Allocator, method: []const u8, params: []const u8) anyerror!link.Subscribed {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        return self.inner.subscribe(a, method, params);
    }

    /// Params of the last call to `method`, parsed.
    fn last(self: *Recorder, method: []const u8) ?Value {
        var k = self.log.items.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, self.log.items[k][0], method))
                return json.parseFromSliceLeaky(Value, self.a, self.log.items[k][1], .{}) catch null;
        }
        return null;
    }

    fn count(self: *Recorder, method: []const u8) usize {
        var n: usize = 0;
        for (self.log.items) |e| {
            if (std.mem.eql(u8, e[0], method)) n += 1;
        }
        return n;
    }
};

/// A scripted engine (the Rust tests' `World`): fixed replies by method.
const World = struct {
    a: Allocator,
    sessions: []const u8 = "[]",
    queue_items: []const u8 = "[]",
    extra_chats: []const u8 = "",
    own_bots: ?[]const u8 = null,
    room_post_body: []const u8 =
        \\{"message":{"seq":3,"hop":1},"deliver":[
        \\  {"member":"alpha","memberKind":"harness_chat","memberRef":"chat-alpha-1","deviceId":"dev-local"},
        \\  {"member":"claude@laptop","memberKind":"graff","memberRef":null,"deviceId":"laptop"}],
        \\ "unreadFrom":{"alpha":1},"redacted":{"email":1},"stripped":0}
    ,
    room_post_status: i64 = 200,
    /// The transcript `WatchDocMessages` resets to; null: a greeting.
    doc_reset: ?[]const u8 = null,
    /// Replies the edge gives, by HTTP method and path suffix; checked
    /// before the defaults below.
    room_replies: []const RoomReply = &.{},
    writes: std.ArrayList([2][]const u8) = .empty,

    const RoomReply = struct { method: []const u8, path_end: []const u8, status: i64, body: []const u8 };

    fn engine(self: *World) link.Engine {
        return .{ .ptr = self, .vtable = &.{ .call = callFn, .subscribe = subFn } };
    }

    fn reply(self: *World, a: Allocator, method: []const u8, params: Value) !link.Result {
        _ = self;
        const eq = std.mem.eql;
        const text: []const u8 = if (eq(u8, method, "LocalDevice"))
            "{\"deviceId\":\"dev-local\"}"
        else if (eq(u8, method, "EngineInfo"))
            "{\"deviceId\":\"dev-local\",\"workspaceScope\":\"local\"}"
        else if (eq(u8, method, "ListHarnesses"))
            \\[{"id":"claude-code","name":"Claude Code","supportsSteering":true,"steeringMode":"step-boundary","reasoningLevels":[],"installed":true,"enabled":true},
            \\ {"id":"codex","name":"Codex","supportsSteering":true,"steeringMode":"turn-boundary","reasoningLevels":[],"installed":false,"enabled":true},
            \\ {"id":"graff","name":"graff","supportsSteering":true,"steeringMode":"turn-boundary","reasoningLevels":[],"installed":true,"enabled":true}]
        else if (eq(u8, method, "ListModels"))
            "[{\"id\":\"opus\",\"label\":\"Opus\"},{\"id\":\"sonnet\",\"label\":\"Sonnet\"}]"
        else if (eq(u8, method, "ShowImage") and eq(u8, u.str(params, "path") orelse "", "bad.png"))
            return .{ .err = "ShowImage: no active run accepts images" }
        else
            return .{ .err = try std.fmt.allocPrint(a, "{s}: unknown method: {s}", .{ method, method }) };
        return .{ .ok = try json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always }) };
    }

    fn callFn(ptr: *anyopaque, a: Allocator, method: []const u8, params_json: []const u8) anyerror!link.Result {
        const self: *World = @ptrCast(@alignCast(ptr));
        const eq = std.mem.eql;
        const params = try json.parseFromSliceLeaky(Value, a, params_json, .{ .allocate = .alloc_always });
        if (eq(u8, method, "Mutate") or eq(u8, method, "QueueCommand") or eq(u8, method, "QueueMessage") or eq(u8, method, "RunBot") or eq(u8, method, "ShowImage")) {
            try self.writes.append(self.a, .{ try self.a.dupe(u8, method), try self.a.dupe(u8, params_json) });
        }
        if (eq(u8, method, "Mutate") or eq(u8, method, "QueueCommand") or eq(u8, method, "QueueMessage"))
            return .{ .ok = try json.parseFromSliceLeaky(Value, a, "{\"commandId\":\"cmd-1\",\"id\":\"q-1\"}", .{}) };
        if (eq(u8, method, "BotsState")) {
            const own = self.own_bots orelse return .{ .err = "BotsState: unknown method: BotsState" };
            return .{ .ok = try json.parseFromSliceLeaky(Value, a, own, .{ .allocate = .alloc_always }) };
        }
        if (eq(u8, method, "RunBot")) {
            var o = u.obj(a);
            try o.put("chatId", u.s("chat-standing"));
            try o.put("bot", u.field(params, "bot"));
            return .{ .ok = o.value() };
        }
        if (eq(u8, method, "RoomRequest")) return self.room(a, params, params_json);
        return self.reply(a, method, params);
    }

    fn room(self: *World, a: Allocator, params: Value, params_json: []const u8) !link.Result {
        const eq = std.mem.eql;
        const m = u.str(params, "method") orelse "";
        const path = u.str(params, "path") orelse "";
        for (self.room_replies) |r| {
            if (!eq(u8, m, r.method) or !std.mem.endsWith(u8, path, r.path_end)) continue;
            if (eq(u8, m, "POST")) try self.writes.append(self.a, .{ "RoomRequest", try self.a.dupe(u8, params_json) });
            var o = u.obj(a);
            try o.put("status", u.i(r.status));
            try o.put("body", try json.parseFromSliceLeaky(Value, a, r.body, .{ .allocate = .alloc_always }));
            return .{ .ok = o.value() };
        }
        var status: i64 = 200;
        const body: []const u8 = if (eq(u8, m, "GET") and eq(u8, path, "rooms"))
            "{\"rooms\":[{\"id\":\"room_0123456789abcdef01234567\",\"name\":\"build\"}]}"
        else if (eq(u8, m, "GET") and std.mem.endsWith(u8, path, "/state"))
            \\{"members":[{"member":"beta","memberRef":"chat-beta-2","deviceId":"dev-local","readSeq":4},
            \\            {"member":"alpha","memberRef":"chat-alpha-1","deviceId":"dev-local","readSeq":0}]}
        else if (eq(u8, m, "GET") and std.mem.endsWith(u8, path, "/messages"))
            "{\"messages\":[{\"seq\":5,\"member\":\"alpha\",\"body\":\"hi\"}],\"lastSeq\":5}"
        else if (eq(u8, m, "GET") and eq(u8, path, "rooms/inbox"))
            "{\"items\":[{\"room\":\"build\",\"seq\":5}]}"
        else if (eq(u8, m, "POST") and std.mem.endsWith(u8, path, "/post")) blk: {
            try self.writes.append(self.a, .{ "RoomRequest", try self.a.dupe(u8, params_json) });
            status = self.room_post_status;
            break :blk self.room_post_body;
        } else if (eq(u8, m, "POST") and eq(u8, path, "rooms")) blk: {
            try self.writes.append(self.a, .{ "RoomRequest", try self.a.dupe(u8, params_json) });
            break :blk "{\"room\":{\"id\":\"room_new\",\"name\":\"plan\"}}";
        } else if (eq(u8, m, "POST")) blk: {
            try self.writes.append(self.a, .{ "RoomRequest", try self.a.dupe(u8, params_json) });
            break :blk "{\"ok\":true,\"member\":\"gamma\"}";
        } else blk: {
            status = 404;
            break :blk "{\"error\":\"not_found\"}";
        };
        var o = u.obj(a);
        try o.put("status", u.i(status));
        try o.put("body", try json.parseFromSliceLeaky(Value, a, body, .{ .allocate = .alloc_always }));
        return .{ .ok = o.value() };
    }

    fn snapshotText(self: *World, a: Allocator, method: []const u8, params: Value) ![]const u8 {
        const eq = std.mem.eql;
        if (eq(u8, method, "WatchDevices")) return "[{\"id\":\"dev-local\",\"name\":\"Laptop\",\"platform\":\"linux\",\"lastSeenAt\":null}]";
        if (eq(u8, method, "WatchSpaces")) return "[{\"id\":\"space-1\",\"deviceId\":\"dev-local\",\"path\":\"/repo/comet\",\"gitDetected\":true,\"createdAt\":\"2026-09-01T00:00:00Z\"}]";
        if (eq(u8, method, "WatchChats")) return std.fmt.allocPrint(a,
            \\[{{"id":"chat-alpha-1","deviceId":"dev-local","title":"Alpha","archived":false,"spaceId":"space-1",
            \\  "config":{{"harness":"claude-code","model":"opus","reasoning":null,"sandbox":"workspace-write"}},"createdAt":"2026-09-01T00:00:00Z"}},
            \\ {{"id":"chat-beta-2","deviceId":"dev-local","title":"Beta","archived":false,"spaceId":"space-1","createdAt":"2026-09-02T00:00:00Z"}},
            \\ {{"id":"chat-gamma-3","deviceId":"dev-local","title":"Gamma","archived":true,"spaceId":"space-1","createdAt":"2026-08-30T00:00:00Z"}}{s}]
        , .{self.extra_chats});
        if (eq(u8, method, "WatchSessions")) return self.sessions;
        if (eq(u8, method, "WatchQueue")) return std.fmt.allocPrint(a, "{{\"items\":{s}}}", .{self.queue_items});
        if (eq(u8, method, "WatchDocMessages")) {
            _ = params;
            if (self.doc_reset) |reset| return std.fmt.allocPrint(a, "{{\"reset\":{s}}}", .{reset});
            return
            \\{"reset":[{"id":"u1","role":"user","createdAt":1,"deviceId":"dev-local","parts":[{"kind":"text","id":"t","text":"hi"}]},
            \\          {"id":"a1","role":"assistant","createdAt":2,"deviceId":"dev-local","status":"complete","parts":[{"kind":"text","id":"t","text":"hello back"}]}]}
            ;
        }
        return error.UnknownWatch;
    }

    const Sub = struct { item: ?[]const u8, a: Allocator };

    fn subFn(ptr: *anyopaque, a: Allocator, method: []const u8, params_json: []const u8) anyerror!link.Subscribed {
        const self: *World = @ptrCast(@alignCast(ptr));
        const params = try json.parseFromSliceLeaky(Value, a, params_json, .{});
        const text = self.snapshotText(a, method, params) catch return .{ .err = try std.fmt.allocPrint(a, "{s}: unknown method: {s}", .{ method, method }) };
        const s = try self.a.create(Sub);
        s.* = .{ .item = text, .a = self.a };
        return .{ .sub = .{ .ptr = s, .vtable = &.{ .next = subNext, .close = subClose } } };
    }

    fn subNext(ptr: *anyopaque, a: Allocator, _: i64) anyerror!link.Next {
        const s: *Sub = @ptrCast(@alignCast(ptr));
        const text = s.item orelse return .timeout;
        s.item = null;
        return .{ .item = try json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always }) };
    }

    fn subClose(_: *anyopaque) void {}
};

// ---- fixtures -------------------------------------------------------------------------

/// A Claude Code CLI stand-in (stream-json over stdio): one text reply that
/// quotes the prompt, then a successful result. A prompt starting `ask:`
/// first asks to run a tool and quotes the answer (`allowed`/`denied`).
const mock_claude =
    \\#!/bin/sh
    \\IFS= read -r first
    \\p=$(printf '%s' "$first" | /usr/bin/sed 's/.*"content":"\([^"]*\)".*/\1/')
    \\echo '{"type":"system","subtype":"init","session_id":"sess-mcp","model":"m"}'
    \\case "$p" in
    \\  ask:*)
    \\    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}]}}'
    \\    echo '{"type":"control_request","request_id":"cr1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}'
    \\    IFS= read -r resp
    \\    case "$resp" in *'"behavior":"allow"'*) ok=allowed;; *) ok=denied;; esac
    \\    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","is_error":false}]}}'
    \\    echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Reply to: '"$p"' ('"$ok"')"}}}'
    \\    ;;
    \\  *) echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Reply to: '"$p"'"}}}' ;;
    \\esac
    \\echo '{"type":"result","subtype":"success","session_id":"sess-mcp"}'
    \\
;

/// An in-process engine with made-up spaces and chats, and the tools over it.
const WorldFixture = struct {
    arena: std.heap.ArenaAllocator,
    world: World = undefined,
    peer: FakePeer = undefined,
    bots: FakeBots = undefined,
    t: tools.Tools = undefined,

    fn create(origin: tools.Origin) !*WorldFixture {
        const gpa = testing.allocator;
        const f = try gpa.create(WorldFixture);
        f.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        const a = f.arena.allocator();
        f.world = .{ .a = a };
        f.peer = .{ .a = a };
        f.bots = .{ .a = a };
        f.t = .{
            .io = testing.io,
            .engine = f.world.engine(),
            .origin = origin,
            .peer = f.peer.peerSend(),
            .relay = .{ .io = testing.io, .dir = null },
            .bots = f.bots.cli(),
            .git = null,
            .fixed_now_ms = host_now,
        };
        return f;
    }

    fn destroy(f: *WorldFixture) void {
        f.arena.deinit();
        testing.allocator.destroy(f);
    }

    fn call(f: *WorldFixture, name: []const u8, args: []const u8) !tools.Outcome {
        const a = f.arena.allocator();
        return f.t.call(a, name, try json.parseFromSliceLeaky(Value, a, args, .{}));
    }

    fn lastWrite(f: *WorldFixture, method: []const u8) ?Value {
        var k = f.world.writes.items.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, f.world.writes.items[k][0], method))
                return json.parseFromSliceLeaky(Value, f.arena.allocator(), f.world.writes.items[k][1], .{}) catch null;
        }
        return null;
    }
};

fn ok(o: tools.Outcome) !Value {
    return switch (o) {
        .ok => |v| v,
        .err => |m| {
            std.debug.print("unexpected tool error: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectErr(o: tools.Outcome, want: []const u8) !void {
    switch (o) {
        .ok => return error.TestExpectedError,
        .err => |m| try testing.expectEqualStrings(want, m),
    }
}

fn expectErrStarts(o: tools.Outcome, want: []const u8) !void {
    switch (o) {
        .ok => return error.TestExpectedError,
        .err => |m| if (!std.mem.startsWith(u8, m, want)) {
            std.debug.print("error was: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

fn sval(v: Value, path: []const []const u8) ?[]const u8 {
    var cur = v;
    for (path) |p| cur = u.get(cur, p) orelse return null;
    return if (cur == .string) cur.string else null;
}

// ---- protocol --------------------------------------------------------------------------

/// `protocol/mcp-tools.json`, read from the repository at test time.
fn sharedCatalog(a: Allocator) ![]const Value {
    const protocol_dir = @import("parity_options").protocol_dir;
    const path = try std.fs.path.join(a, &.{ protocol_dir, "..", "mcp-tools.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20));
    return (try json.parseFromSliceLeaky(Value, a, text, .{})).array.items;
}

test "mcp catalog: tools/list serves protocol/mcp-tools.json exactly: names, order, descriptions and input schemas" {
    const f = try WorldFixture.create(.{ .chat_id = "chat-beta-2" });
    defer f.destroy();
    const a = f.arena.allocator();
    const shared = try sharedCatalog(a);
    try testing.expectEqual(@as(usize, 33), shared.len);
    for (shared) |t| {
        const has_ann = u.get(t, "annotations") != null;
        // Exactly these keys, so nothing else could be served.
        try testing.expectEqual(@as(usize, if (has_ann) 4 else 3), t.object.count());
        if (has_ann) {
            const ann = u.get(t, "annotations").?;
            try testing.expect(ann == .object);
            try testing.expect(u.boolean(ann, "readOnlyHint") == true);
        }
        try testing.expect(u.str(t, "name") != null and u.str(t, "description") != null);
        try testing.expect(u.get(t, "inputSchema").? == .object);
    }
    // The embedded copy is the file, byte for byte.
    const protocol_dir = @import("parity_options").protocol_dir;
    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fs.path.join(a, &.{ protocol_dir, "..", "mcp-tools.json" }), a, .limited(1 << 20));
    try testing.expectEqualStrings(raw, tools.catalog_json);

    // From a chat: every tool, in the file's order, each exactly as written.
    const served = u.array(u.get(try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(1), "tools/list", .null), .{}), "result").?, "tools").?;
    try testing.expectEqual(shared.len, served.len);
    for (shared, served) |want, got| try testing.expectEqualStrings(try u.stringify(a, want), try u.stringify(a, got));
    // From a terminal: the same, without the two that publish into a chat.
    f.t.origin = .{};
    const plain = u.array(u.get(try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(2), "tools/list", .null), .{}), "result").?, "tools").?;
    var k: usize = 0;
    for (shared) |want| {
        const name = u.str(want, "name").?;
        if (std.mem.eql(u8, name, "show_image") or std.mem.eql(u8, name, "show_visual") or std.mem.eql(u8, name, "create_artifact") or std.mem.eql(u8, name, "update_artifact")) continue;
        try testing.expectEqualStrings(try u.stringify(a, want), try u.stringify(a, plain[k]));
        k += 1;
    }
    try testing.expectEqual(plain.len, k);
}

test "mcp catalog: the shared catalog is the Rust server's tool list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try json.parseFromSliceLeaky(Value, a, tools.catalog_json, .{});
    const want = [_][]const u8{
        "whoami",       "list_devices", "list_projects", "list_harnesses", "list_models",     "list_chats",      "get_chat",
        "create_chat",  "read_chat",    "send_message",  "wait_for_turn",  "interrupt_chat",  "dismiss_input",   "respond_to_input",
        "rename_chat",  "archive_chat", "show_visual",   "show_image",     "create_artifact", "update_artifact", "list_rooms",
        "create_room",  "join_room",    "leave_room",    "post_room",      "release_claim",   "read_room",       "room_inbox",
        "archive_room", "destroy_room", "list_bots",     "run_bot",        "run_due_bots",
    };
    try testing.expectEqual(want.len, all.array.items.len);
    for (all.array.items, want) |t, name| {
        try testing.expectEqualStrings(name, u.str(t, "name").?);
        try testing.expect(u.str(t, "description").?.len > 10);
        try testing.expectEqualStrings("object", sval(t, &.{ "inputSchema", "type" }).?);
        try testing.expect(tools.Tools.has(name));
    }
    try testing.expect(!tools.Tools.has("render_visual"));
    // Spot checks against the Rust schemas.
    const rename = all.array.items[14];
    try testing.expectEqual(@as(usize, 2), u.array(u.get(rename, "inputSchema").?, "required").?.len);
    const image = all.array.items[17];
    try testing.expect(u.boolean(u.get(image, "inputSchema").?, "additionalProperties").? == false);
    try testing.expect(std.mem.indexOf(u8, tools.catalog_json, "secret_detected (rewrite it without the value)") != null);
}

test "mcp protocol: initialize, ping, list, and protocol errors match the Rust server" {
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    const a = f.arena.allocator();
    const init_line = try mcp.handleRequest(&f.t, a, u.i(1), "initialize", try json.parseFromSliceLeaky(Value, a, "{\"protocolVersion\":\"2025-03-26\"}", .{}));
    const init_v = try json.parseFromSliceLeaky(Value, a, init_line, .{});
    try testing.expectEqualStrings("2025-03-26", sval(init_v, &.{ "result", "protocolVersion" }).?);
    try testing.expectEqualStrings("harness", sval(init_v, &.{ "result", "serverInfo", "name" }).?);
    try testing.expect(u.boolean(u.get(u.get(u.get(init_v, "result").?, "capabilities").?, "tools").?, "listChanged").? == false);
    try testing.expect(std.mem.startsWith(u8, sval(init_v, &.{ "result", "instructions" }).?, "Harness runs coding agents"));
    const newest = try mcp.handleRequest(&f.t, a, u.i(2), "initialize", try json.parseFromSliceLeaky(Value, a, "{\"protocolVersion\":\"1999-01-01\"}", .{}));
    try testing.expect(std.mem.indexOf(u8, newest, "\"protocolVersion\":\"2025-06-18\"") != null);

    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}", try mcp.handleRequest(&f.t, a, u.i(3), "ping", .null));
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"result\":{\"resources\":[]}}", try mcp.handleRequest(&f.t, a, u.s("r"), "resources/list", .null));
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32601,\"message\":\"unknown method: nope\"}}", try mcp.handleRequest(&f.t, a, u.i(4), "nope", .null));
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32602,\"message\":\"tools/call needs a tool name\"}}", try mcp.handleRequest(&f.t, a, u.i(5), "tools/call", .null));
    const unknown = try mcp.handleRequest(&f.t, a, u.i(6), "tools/call", try json.parseFromSliceLeaky(Value, a, "{\"name\":\"render_visual\"}", .{}));
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32602,\"message\":\"unknown tool: render_visual\"}}", unknown);

    // Without an origin chat, show_image/show_visual/create_artifact/update_artifact are hidden.
    const listed = try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(7), "tools/list", .null), .{});
    try testing.expectEqual(@as(usize, 29), u.array(u.get(listed, "result").?, "tools").?.len);
    f.t.origin = .{ .chat_id = "chat-beta-2" };
    const listed2 = try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(8), "tools/list", .null), .{});
    try testing.expectEqual(@as(usize, 33), u.array(u.get(listed2, "result").?, "tools").?.len);

    // A tool error is a result with isError, never a protocol error.
    const failed = try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(9), "tools/call", try json.parseFromSliceLeaky(Value, a, "{\"name\":\"get_chat\",\"arguments\":{\"chat\":\"nope\"}}", .{})), .{});
    try testing.expect(u.boolean(u.get(failed, "result").?, "isError").?);
    try testing.expect(u.get(u.get(failed, "result").?, "structuredContent") == null);
    // A success carries pretty text and the object as structuredContent.
    const good = try json.parseFromSliceLeaky(Value, a, try mcp.handleRequest(&f.t, a, u.i(10), "tools/call", try json.parseFromSliceLeaky(Value, a, "{\"name\":\"list_harnesses\"}", .{})), .{});
    const res = u.get(good, "result").?;
    try testing.expect(!u.boolean(res, "isError").?);
    try testing.expect(std.mem.startsWith(u8, u.str(u.array(res, "content").?[0], "text").?, "{\n  \"harnesses\": ["));
    try testing.expect(u.get(u.get(res, "structuredContent").?, "harnesses") != null);

    switch (try mcp.route(a, "not json")) {
        .reply => |line| try testing.expect(std.mem.startsWith(u8, line, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"parse error: ")),
        else => return error.TestUnexpectedResult,
    }
    switch (try mcp.route(a, "[1]")) {
        .reply => |line| try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"expected a JSON-RPC object\"}}", line),
        else => return error.TestUnexpectedResult,
    }
    switch (try mcp.route(a, "{\"jsonrpc\":\"2.0\"}")) {
        .reply => |line| try testing.expect(std.mem.indexOf(u8, line, "missing method") != null),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect((try mcp.route(a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")) == .none);
    try testing.expect((try mcp.route(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")) == .none);
    try testing.expect((try mcp.route(a, "  ")) == .none);
}

test "mcp protocol: config reads the port and origin from the environment" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(@as(u16, 27664), mcp.Config.fromEnv(&env).ipc_port);
    try env.put("HARNESS_IPC_PORT", "27990");
    try env.put("HARNESS_CHAT_ID", "  chat-1 \n");
    try env.put("HARNESS_DEVICE_ID", "");
    const cfg = mcp.Config.fromEnv(&env);
    try testing.expectEqual(@as(u16, 27990), cfg.ipc_port);
    try testing.expectEqualStrings("chat-1", cfg.origin.chat_id.?);
    try testing.expect(cfg.origin.device_id == null);
}

test "mcp protocol: stdio serving answers concurrently and finishes in-flight requests at EOF" {
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    var input = std.Io.Reader.fixed(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" ++
            "\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"whoami\"}}\n" ++
            "garbage\n",
    );
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var server: mcp.Server = .{ .gpa = testing.allocator, .io = testing.io, .tools = f.t, .out = &out.writer };
    try server.serve(&input);
    const written = out.written();
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, written, "\n"));
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":1,\"result\":{\"protocolVersion\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":2,\"result\":{\"content\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "-32700") != null);
}

/// The id-sorted lines `serve` wrote, each parsed.
fn servedLines(a: Allocator, written: []const u8) ![]const Value {
    var out: std.ArrayList(Value) = .empty;
    var it = std.mem.splitScalar(u8, written, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try out.append(a, try json.parseFromSliceLeaky(Value, a, line, .{}));
    }
    std.mem.sort(Value, out.items, {}, struct {
        fn lt(_: void, x: Value, y: Value) bool {
            return (u.int(x, "id") orelse -1) < (u.int(y, "id") orelse -1);
        }
    }.lt);
    return out.items;
}

test "mcp protocol: a 1 MiB request line is answered; a line over the cap is refused and serving goes on" {
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    const gpa = testing.allocator;
    const a = f.arena.allocator();
    // A 1 MiB argument, then a line one byte over the 16 MiB cap, then a ping.
    const pad = try a.alloc(u8, 1024 * 1024);
    @memset(pad, 'p');
    const over = try a.alloc(u8, mcp.max_line_bytes + 1);
    @memset(over, 'x');
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    try input.print(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"list_models\",\"arguments\":{{\"harness\":\"claude-code\",\"pad\":\"{s}\"}}}}}}\n", .{pad});
    try input.appendSlice(gpa, over);
    try input.appendSlice(gpa, "\n{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}");
    // Through a 64 KiB buffer, as stdin is read.
    var small: [64 * 1024]u8 = undefined;
    var stdin_like = std.testing.Reader.init(&small, &.{.{ .buffer = input.items }});
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server: mcp.Server = .{ .gpa = gpa, .io = testing.io, .tools = f.t, .out = &out.writer };
    try server.serve(&stdin_like.interface);
    const lines = try servedLines(a, out.written());
    try testing.expectEqual(@as(usize, 3), lines.len);
    // The refusal has no id; it sorts first.
    try testing.expect(u.get(lines[0], "id").? == .null);
    try testing.expectEqual(@as(i64, -32600), u.int(u.get(lines[0], "error").?, "code").?);
    try testing.expectEqualStrings("request line longer than 16777216 bytes", sval(lines[0], &.{ "error", "message" }).?);
    try testing.expectEqual(@as(i64, 1), u.int(lines[1], "id").?);
    try testing.expectEqualStrings("claude-code", sval(lines[1], &.{ "result", "structuredContent", "harness" }).?);
    try testing.expectEqual(@as(i64, 3), u.int(lines[2], "id").?);
    try testing.expect(u.get(lines[2], "result") != null);
}

/// Stdin that hands over one line at a time, each only after every
/// earlier request was answered, and notes how many were still in flight.
const PacedInput = struct {
    interface: std.Io.Reader,
    lines: []const []const u8,
    next: usize = 0,
    offset: usize = 0,
    server: *mcp.Server = undefined,
    out: *std.Io.Writer.Allocating = undefined,
    max_in_flight_between: usize = 0,
    waited_too_long: bool = false,

    fn init(buffer: []u8, lines: []const []const u8) PacedInput {
        return .{ .lines = lines, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn answered(self: *PacedInput) usize {
        self.server.out_lock.lockUncancelable(testing.io);
        defer self.server.out_lock.unlock(testing.io);
        return std.mem.count(u8, self.out.written(), "\n");
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *PacedInput = @alignCast(@fieldParentPtr("interface", r));
        if (self.next == self.lines.len) return error.EndOfStream;
        if (self.offset == 0 and self.next > 0) {
            var waited: u32 = 0;
            while (self.answered() < self.next) : (waited += 5) {
                if (waited >= 5000) {
                    self.waited_too_long = true;
                    return error.EndOfStream;
                }
                std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
            }
            // A worker retires right after writing its reply.
            if (@hasDecl(mcp.Server, "inFlight")) {
                var retired: u32 = 0;
                while (self.server.inFlight() != 0) : (retired += 5) {
                    if (retired >= 2000) {
                        self.max_in_flight_between = @max(self.max_in_flight_between, self.server.inFlight());
                        break;
                    }
                    std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
                }
            }
        }
        const line = self.lines[self.next];
        const n = try w.write(limit.sliceConst(line[self.offset..]));
        self.offset += n;
        if (self.offset == line.len) {
            self.next += 1;
            self.offset = 0;
        }
        return n;
    }
};

test "mcp protocol: a finished request leaves no thread or record behind during a long session" {
    // Serving keeps a count of requests in flight, not a list of threads
    // that only EOF would join.
    try testing.expect(!@hasField(mcp.Server, "workers"));
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    const a = f.arena.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    for (0..25) |k| try lines.append(a, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"ping\"}}\n", .{k + 1}));
    var buf: [256]u8 = undefined;
    var input = PacedInput.init(&buf, lines.items);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var server: mcp.Server = .{ .gpa = testing.allocator, .io = testing.io, .tools = f.t, .out = &out.writer };
    input.server = &server;
    input.out = &out;
    try server.serve(&input.interface);
    try testing.expect(!input.waited_too_long);
    try testing.expectEqual(@as(usize, 25), std.mem.count(u8, out.written(), "\n"));
    try testing.expectEqual(@as(usize, 0), input.max_in_flight_between);
    if (@hasDecl(mcp.Server, "inFlight")) try testing.expectEqual(@as(usize, 0), server.inFlight());
}

test "mcp protocol: line reading keeps a line of exactly the cap and refuses one byte more" {
    const gpa = testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    var small: [2]u8 = undefined;
    var r = std.testing.Reader.init(&small, &.{.{ .buffer = "abcd\nabcde\nab\r\n\nlast" }});
    try testing.expectEqualStrings("abcd", (try mcp.nextLine(&r.interface, &buf, 4)).line);
    try testing.expect((try mcp.nextLine(&r.interface, &buf, 4)) == .too_long);
    try testing.expectEqualStrings("ab\r", (try mcp.nextLine(&r.interface, &buf, 4)).line);
    try testing.expectEqualStrings("", (try mcp.nextLine(&r.interface, &buf, 4)).line);
    try testing.expectEqualStrings("last", (try mcp.nextLine(&r.interface, &buf, 4)).line);
    try testing.expect((try mcp.nextLine(&r.interface, &buf, 4)) == .end);
    // An over-cap line the input ends inside.
    var tail = std.Io.Reader.fixed("abcdefgh");
    try testing.expect((try mcp.nextLine(&tail, &buf, 4)) == .too_long);
    try testing.expect((try mcp.nextLine(&tail, &buf, 4)) == .end);
}

// ---- chat tools against the in-process engine ---------------------------------------------

test "mcp resolution: id, prefix, title; project by id, path, name or suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try WorldFixture.create(.{});
    defer f.destroy();
    var c: tools.Ctx = .{ .t = &f.t, .a = a };
    const chats = (try json.parseFromSliceLeaky(Value, a,
        \\[{"id":"aaaa1111-1","title":"Fix login"},{"id":"aaaa2222-2","title":"Fix Login"},{"id":"bbbb3333-3","title":"Docs"}]
    , .{})).array.items;
    try testing.expectEqualStrings("bbbb3333-3", u.str(try tools.resolveChatIn(&c, chats, "bbbb3333-3"), "id").?);
    try testing.expectEqualStrings("bbbb3333-3", u.str(try tools.resolveChatIn(&c, chats, "bbbb"), "id").?);
    try testing.expectEqualStrings("bbbb3333-3", u.str(try tools.resolveChatIn(&c, chats, "docs"), "id").?);
    try testing.expectError(error.ToolFailed, tools.resolveChatIn(&c, chats, "aaaa"));
    try testing.expectEqualStrings("2 chats start with \"aaaa\"; be more specific: aaaa1111, aaaa2222", c.msg);
    try testing.expectError(error.ToolFailed, tools.resolveChatIn(&c, chats, "fix login"));
    try testing.expectEqualStrings("2 chats are titled \"fix login\"; use an id: aaaa1111, aaaa2222", c.msg);
    try testing.expectError(error.ToolFailed, tools.resolveChatIn(&c, chats, "zzz"));
    try testing.expectEqualStrings("no chat matches \"zzz\" (id, id prefix, or exact title); try list_chats", c.msg);

    const spaces = (try json.parseFromSliceLeaky(Value, a,
        \\[{"id":"s1","path":"/home/u/GitHub/comet"},{"id":"s2","path":"/home/u/GitHub/comet-ios","name":"iOS"}]
    , .{})).array.items;
    try testing.expectEqualStrings("s2", u.str(try tools.resolveSpaceIn(&c, spaces, "s2"), "id").?);
    try testing.expectEqualStrings("s1", u.str(try tools.resolveSpaceIn(&c, spaces, "/home/u/GitHub/comet"), "id").?);
    try testing.expectEqualStrings("s2", u.str(try tools.resolveSpaceIn(&c, spaces, "ios"), "id").?);
    try testing.expectEqualStrings("s2", u.str(try tools.resolveSpaceIn(&c, spaces, "comet-ios"), "id").?);
    try testing.expectEqualStrings("s1", u.str(try tools.resolveSpaceIn(&c, spaces, "comet"), "id").?);
    try testing.expectError(error.ToolFailed, tools.resolveSpaceIn(&c, spaces, "GitHub"));
    try testing.expectEqualStrings("2 projects match \"GitHub\"; use an id: /home/u/GitHub/comet (s1), /home/u/GitHub/comet-ios (s2)", c.msg);
    try testing.expectError(error.ToolFailed, tools.resolveSpaceIn(&c, spaces, ""));
    try testing.expectEqualStrings("project is required", c.msg);
    try testing.expectError(error.ToolFailed, c.resolveChat("  "));
    try testing.expectEqualStrings("chat is required", c.msg);
}

test "mcp respond_to_input: the current pending question is found in the transcript" {
    const w = try WorldFixture.create(.{});
    defer w.destroy();
    // An older answered question, then the one still open.
    w.world.doc_reset =
        \\[{"id":"u1","role":"user","createdAt":1,"deviceId":"dev-local","parts":[{"kind":"text","id":"t","text":"ship it"}]},
        \\ {"id":"a1","role":"assistant","createdAt":2,"deviceId":"dev-local","status":"streaming","parts":[
        \\   {"kind":"input","id":"i1","requestId":"req-old","questions":[{"id":"q0","prompt":"Start?"}],"resolved":true},
        \\   {"kind":"input","id":"i2","requestId":"req-7","questions":[{"id":"q1","prompt":"Push to main?"}],"resolved":false}]}]
    ;
    try testing.expectEqualStrings("req-7", sval(try ok(try w.call("get_chat", "{\"chat\":\"Alpha\"}")), &.{ "pendingInput", "requestId" }).?);
    const answered = try ok(try w.call("respond_to_input", "{\"chat\":\"Alpha\",\"answers\":[{\"question_id\":\"q1\",\"labels\":[\"Yes\"]}]}"));
    try testing.expectEqualStrings("req-7", u.str(answered, "requestId").?);
    const sent = w.lastWrite("QueueCommand").?;
    try testing.expectEqualStrings("chat-alpha-1", u.str(sent, "chatId").?);
    try testing.expectEqualStrings("respondInput", sval(sent, &.{ "command", "kind" }).?);
    try testing.expectEqualStrings("req-7", sval(sent, &.{ "command", "requestId" }).?);
    try testing.expect(u.boolean(u.get(sent, "command").?, "fromAgent").?);
    const ans = u.array(u.get(sent, "command").?, "answers").?;
    try testing.expectEqualStrings("q1", u.str(ans[0], "questionId").?);
    try testing.expectEqualStrings("Yes", u.array(ans[0], "labels").?[0].string);
    const dismissed = try ok(try w.call("dismiss_input", "{\"chat\":\"Alpha\"}"));
    try testing.expectEqualStrings("req-7", u.str(dismissed, "requestId").?);
    try testing.expectEqualStrings("req-7", sval(w.lastWrite("QueueCommand").?, &.{ "command", "requestId" }).?);
    // Once answered, nothing is pending.
    w.world.doc_reset =
        \\[{"id":"a1","role":"assistant","createdAt":2,"deviceId":"dev-local","status":"complete","parts":[
        \\   {"kind":"input","id":"i2","requestId":"req-7","questions":[{"id":"q1","prompt":"Push to main?"}],"resolved":true}]}]
    ;
    try expectErr(try w.call("respond_to_input", "{\"chat\":\"Alpha\",\"answers\":[{\"question_id\":\"q1\",\"labels\":[\"Yes\"]}]}"), "chat chat-alp has no pending question");
}

test "mcp respond_to_input refuses tool-approval prompts and peer relayDepth reads room hops" {
    const w = try WorldFixture.create(.{});
    defer w.destroy();
    w.world.doc_reset =
        \\[{"id":"u1","role":"user","createdAt":1,"deviceId":"dev-local","parts":[{"kind":"text","id":"t","text":"run it"}]},
        \\ {"id":"a1","role":"assistant","createdAt":2,"deviceId":"dev-local","status":"streaming","parts":[
        \\   {"kind":"input","id":"i2","requestId":"req-perm","questions":[{"id":"q1","header":"Approve tool","prompt":"Run shell command?","requiresHumanUi":true}],"resolved":false}]}]
    ;
    try expectErr(try w.call("respond_to_input", "{\"chat\":\"Alpha\",\"answers\":[{\"question_id\":\"q1\",\"labels\":[\"Yes\"]}]}"), "this prompt requires human approval in the Harness UI");
    try testing.expect(w.lastWrite("QueueCommand") == null);

    const room_msg =
        \\<!--harness-room {"room_id":"r1","room_name":"build","seq":7,"from_member":"codex","member_kind":"graff","from_user":false,"external":false,"hop":4} -->
        \\[room message from codex · room build #7 · agent, advisory]: @alpha ping
    ;
    try testing.expectEqual(@as(u32, 4), peer.relayDepth(room_msg));

    const w_room = try WorldFixture.create(.{ .chat_id = "chat-alpha-1" });
    defer w_room.destroy();
    w_room.world.doc_reset =
        \\[{"id":"u1","role":"user","createdAt":1,"deviceId":"dev-local","parts":[{"kind":"text","id":"t","text":"[Message from Harness chat Beta. Sender chat: chat-beta-1. Relay depth: 2/4. Agent coordination, not a human request. Reply with Harness `send_message` only for an actionable question, blocker, or final requested result; otherwise do not reply. Do not send acknowledgements or progress updates.]\n\ncheck"}]}]
    ;
    const posted = try ok(try w_room.call("post_room", "{\"room\":\"build\",\"text\":\"@beta update\"}"));
    _ = posted;
    const post_req = w_room.lastWrite("RoomRequest").?;
    try testing.expectEqual(@as(i64, 2), u.int(u.get(post_req, "body").?, "parentHop").?);
}

test "mcp list_chats and create_chat ignore blank optional string filters" {
    const w = try WorldFixture.create(.{});
    defer w.destroy();
    const listed = try ok(try w.call("list_chats", "{\"project\":\"\",\"device\":\"  \",\"parent\":\"\",\"include_archived\":true,\"limit\":50}"));
    try testing.expect(u.int(listed, "total").? >= 1);
    const chats = u.array(listed, "chats").?;
    try testing.expect(chats.len >= 1);
    const created = try ok(try w.call("create_chat", "{\"harness\":\"\",\"model\":\"\",\"reasoning\":\"\",\"sandbox\":\"\",\"parent\":\"\",\"device\":\"\",\"title\":\"Blank opts\"}"));
    try testing.expectEqualStrings("Blank opts", u.str(created, "title").?);
}

// ---- publishing -------------------------------------------------------------------------

test "mcp show_image and show_visual: scripted engine surfaces errors and validates bounds" {
    const w = try WorldFixture.create(.{ .chat_id = "chat-alpha-1" });
    defer w.destroy();
    try expectErr(try w.call("show_image", "{\"path\":\"bad.png\"}"), "ShowImage: no active run accepts images");
    try testing.expect(tools.validateVisual(try repeat(w.arena.allocator(), "界", 200), try repeat(w.arena.allocator(), "é", 32768)) == null);
    try testing.expect(tools.validateVisual(try repeat(w.arena.allocator(), "界", 201), "x") != null);
    try testing.expect(tools.validateVisual("title", try repeat(w.arena.allocator(), "é", 32769)) != null);

    // create_artifact & update_artifact validate inputs locally and forward the RPC shape.
    try expectErr(try w.call("create_artifact", "{\"title\":\"  \",\"format\":\"html\",\"content\":\"<h1>x</h1>\"}"), "artifact title must be nonblank and at most 200 characters");
    try expectErr(try w.call("create_artifact", "{\"title\":\"Chart\",\"format\":\"pdf\",\"content\":\"x\"}"), "artifact format must be html, svg, or markdown");
    try expectErr(try w.call("update_artifact", "{\"artifactId\":\"bad\"}"), "artifactId must be art- followed by 24 lowercase hex characters");
    try expectErr(try w.call("update_artifact", "{\"artifactId\":\"art-0123456789abcdef01234567\"}"), "update_artifact needs at least one of title, format, content, or visibility");
}

// ---- rooms -------------------------------------------------------------------------------

test "mcp post_room: queues framed peer mail for mentioned chats and reports redactions" {
    const w = try WorldFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer w.destroy();
    const v = try ok(try w.call("post_room", "{\"room\":\"build\",\"text\":\"@alpha the build is green\",\"kind\":\"message\"}"));
    try testing.expectEqual(@as(i64, 3), u.int(v, "seq").?);
    const woken = u.array(v, "woken").?;
    try testing.expectEqual(@as(usize, 1), woken.len);
    try testing.expectEqualStrings("alpha", u.str(woken[0], "member").?);
    try testing.expect(u.boolean(woken[0], "queued").?);
    try testing.expectEqual(@as(i64, 1), u.int(u.get(v, "redacted").?, "email").?);
    try testing.expectEqual(@as(i64, 0), u.int(v, "stripped").?);
    const post = w.lastWrite("RoomRequest").?;
    try testing.expectEqualStrings("room/room_0123456789abcdef01234567/post", u.str(post, "path").?);
    try testing.expectEqualStrings("beta", sval(post, &.{ "body", "member" }).?);
    try testing.expect(!u.boolean(u.get(post, "body").?, "fromUser").?);
    try testing.expectEqual(@as(usize, 32), sval(post, &.{ "body", "clientId" }).?.len);
    const queued = w.lastWrite("QueueMessage").?;
    try testing.expectEqualStrings("chat-alpha-1", u.str(queued, "chatId").?);
    const text = u.str(queued, "text").?;
    try testing.expect(peer.isRoomDelivery(w.arena.allocator(), text));
    try testing.expect(std.mem.indexOf(u8, text, "[room message from beta · room build #3 · agent, advisory]: @alpha the build is green") != null);

    // The room's refusals come back readable, and are not retried.
    w.world.room_post_status = 422;
    w.world.room_post_body = "{\"error\":\"secret_detected\",\"message\":\"the post contains a credential\"}";
    const before = w.world.writes.items.len;
    try expectErr(try w.call("post_room", "{\"room\":\"build\",\"text\":\"token=abc\"}"), "room request failed (422): secret_detected: the post contains a credential");
    try testing.expectEqual(before + 1, w.world.writes.items.len);
    w.world.room_post_body = "{\"error\":\"not_a_member\"}";
    try expectErr(try w.call("post_room", "{\"room\":\"build\",\"text\":\"hi\"}"), "room request failed (422): not_a_member");
    try expectErr(try w.call("post_room", "{\"room\":\"Build\",\"text\":\"hi\"}"), "no room named \"Build\" that you can see (names are exact and case-sensitive; the room may have been destroyed, or you aren't in it — see list_rooms)");
    try expectErr(try w.call("post_room", "{\"room\":\"build\"}"), "invalid arguments: missing field `text`");
}

test "mcp rooms: list, create, join, read, inbox, release, archive, destroy and leave" {
    const w = try WorldFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer w.destroy();
    const listed = try ok(try w.call("list_rooms", "{}"));
    try testing.expectEqualStrings("beta", u.str(listed, "you").?);
    try testing.expectEqual(@as(usize, 1), u.array(listed, "rooms").?.len);

    const created = try ok(try w.call("create_room", "{\"name\":\"plan\",\"members\":[\"Alpha\"]}"));
    try testing.expectEqualStrings("room_new", sval(created, &.{ "room", "id" }).?);
    try testing.expectEqualStrings("gamma", u.array(created, "added").?[0].string);
    try expectErr(try w.call("create_room", "{\"name\":\"plan\",\"project\":true}"), "this chat's checkout has no origin remote to bind the room to");

    const read = try ok(try w.call("read_room", "{\"room\":\"room_0123456789abcdef01234567\"}"));
    try testing.expectEqualStrings("build", u.str(read, "room").?);
    try testing.expectEqual(@as(i64, 5), u.int(read, "lastSeq").?);

    const inbox = try ok(try w.call("room_inbox", "{}"));
    try testing.expectEqual(@as(usize, 1), u.array(inbox, "items").?.len);

    _ = try ok(try w.call("release_claim", "{\"room\":\"build\",\"claim_key\":\"task-1\"}"));
    try testing.expectEqualStrings("task-1", sval(w.lastWrite("RoomRequest").?, &.{ "body", "claimKey" }).?);
    try expectErr(try w.call("release_claim", "{\"room\":\"build\"}"), "invalid arguments: missing field `claim_key`");
    _ = try ok(try w.call("archive_room", "{\"room\":\"build\"}"));
    try testing.expect(u.boolean(u.get(w.lastWrite("RoomRequest").?, "body").?, "archived").?);
    _ = try ok(try w.call("destroy_room", "{\"room\":\"build\"}"));
    try testing.expectEqualStrings("room/room_0123456789abcdef01234567/destroy", u.str(w.lastWrite("RoomRequest").?, "path").?);
    _ = try ok(try w.call("join_room", "{\"room\":\"build\"}"));
    _ = try ok(try w.call("leave_room", "{\"room\":\"room_unknown\"}"));
    try testing.expectEqualStrings("room/room_unknown/leave", u.str(w.lastWrite("RoomRequest").?, "path").?);

    w.t.origin = .{};
    try expectErr(try w.call("list_rooms", "{}"), "room tools speak for a Harness chat; this server has no HARNESS_CHAT_ID");
    try expectErr(try w.call("room_inbox", "{}"), "room tools speak for a Harness chat; this server has no HARNESS_CHAT_ID");
}

test "mcp rooms: the edge's refusals read as errors, and a reply that is not an object is never a success" {
    const w = try WorldFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer w.destroy();
    // The edge's own replies (`edge/src/index.ts`: `{error, message}` with
    // the RoomError status): a credential in a post, a claim someone else
    // holds, and a destroy by a member who is not an owner.
    w.world.room_replies = &.{
        .{ .method = "POST", .path_end = "/post", .status = 422, .body = "{\"error\":\"secret_detected\",\"message\":\"the post looks like it contains a credential (api key)\"}" },
        .{ .method = "POST", .path_end = "/release", .status = 409, .body = "{\"error\":\"claim_held\",\"message\":\"task-1 is held or done by someone else\"}" },
        .{ .method = "POST", .path_end = "/destroy", .status = 403, .body = "{\"error\":\"owner_only\",\"message\":\"owner_only\"}" },
    };
    try expectErr(try w.call("post_room", "{\"room\":\"build\",\"text\":\"key=sk-synthetic\"}"), "room request failed (422): secret_detected: the post looks like it contains a credential (api key)");
    try expectErr(try w.call("release_claim", "{\"room\":\"build\",\"claim_key\":\"task-1\"}"), "room request failed (409): claim_held: task-1 is held or done by someone else");
    try expectErr(try w.call("destroy_room", "{\"room\":\"build\"}"), "room request failed (403): owner_only");
    // A refused post queued nothing for anyone.
    try testing.expect(w.lastWrite("QueueMessage") == null);

    // A 2xx whose body is not an object: every room tool fails rather than
    // answering nulls, and a post never reports seq 0 as sent.
    w.world.room_replies = &.{
        .{ .method = "GET", .path_end = "rooms", .status = 200, .body = "\"ok\"" },
    };
    try expectErr(try w.call("list_rooms", "{}"), "room request failed (200): the room's reply is not a JSON object");
    try expectErr(try w.call("read_room", "{\"room\":\"build\"}"), "room request failed (200): the room's reply is not a JSON object");
    w.world.room_replies = &.{
        .{ .method = "POST", .path_end = "/post", .status = 200, .body = "[]" },
        .{ .method = "GET", .path_end = "rooms/inbox", .status = 204, .body = "null" },
    };
    const before = w.world.writes.items.len;
    try expectErr(try w.call("post_room", "{\"room\":\"build\",\"text\":\"@alpha done\"}"), "room request failed (200): the room's reply is not a JSON object");
    // Not retried (the room answered), and nobody was woken.
    try testing.expectEqual(before + 1, w.world.writes.items.len);
    try testing.expect(w.lastWrite("QueueMessage") == null);
    try expectErr(try w.call("room_inbox", "{}"), "room request failed (204): the room's reply is not a JSON object");
    // The edge's real success replies still read through.
    w.world.room_replies = &.{};
    try testing.expectEqual(@as(i64, 3), u.int(try ok(try w.call("post_room", "{\"room\":\"build\",\"text\":\"@alpha done\"}")), "seq").?);
}

test "mcp: timeValue normalizes timestamps across fractional seconds and offsets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "2026-11-10T00:00:01Z", "2026-11-10T00:00:01Z" },
        .{ "2026-11-10T00:00:01.000Z", "2026-11-10T00:00:01Z" },
        .{ "2026-11-10T00:00:01.5Z", "2026-11-10T00:00:01.500Z" },
        .{ "2026-11-10T00:00:01.120Z", "2026-11-10T00:00:01.120Z" },
        .{ "2026-11-10T00:00:01.123456Z", "2026-11-10T00:00:01.123456Z" },
        .{ "2026-11-10T00:00:01.000001Z", "2026-11-10T00:00:01.000001Z" },
        .{ "2026-11-10T00:00:01.123456789Z", "2026-11-10T00:00:01.123456789Z" },
        .{ "2026-11-10T00:00:01.1234567891Z", "2026-11-10T00:00:01.123456789Z" },
        .{ "2026-11-10T08:00:01.25+08:00", "2026-11-10T00:00:01.250Z" },
        .{ "not a time", "not a time" },
    };
    for (cases) |c| {
        var o = u.obj(a);
        try o.put("at", u.s(c[0]));
        try testing.expectEqualStrings(c[1], (try tools.timeValue(a, o.value(), "at")).string);
    }
    try testing.expect((try tools.timeValue(a, u.obj(a).value(), "at")) == .null);
}

test "mcp bots: the person's own bots run in their standing chat through the engine" {
    const w = try WorldFixture.create(.{});
    defer w.destroy();
    w.world.own_bots = "{\"bots\":[{\"name\":\"scout\",\"job\":\"Watch CI\"}]}";
    const listed = try ok(try w.call("list_bots", "{}"));
    try testing.expectEqualStrings("scout", u.str(u.array(listed, "yours").?[0], "name").?);
    try testing.expect(u.get(listed, "bots") == null);
    const ran = try ok(try w.call("run_bot", "{\"bot\":\"scout\",\"message\":\"check main\"}"));
    try testing.expectEqualStrings("chat-standing", u.str(ran, "chatId").?);
    try testing.expect(u.boolean(ran, "standingChat").?);
    try testing.expectEqualStrings("check main", u.str(w.lastWrite("RunBot").?, "message").?);
    try expectErr(try w.call("run_bot", "{\"bot\":\"scout\"}"), "pass message or routine, one of them");
    // Without own bots and without a project, the project error stands.
    w.world.own_bots = null;
    try expectErr(try w.call("list_bots", "{}"), "name the project: this server is not speaking for a chat");
}

fn repeat(a: Allocator, unit: []const u8, n: usize) ![]const u8 {
    const out = try a.alloc(u8, unit.len * n);
    for (0..n) |k| @memcpy(out[k * unit.len ..][0..unit.len], unit);
    return out;
}
