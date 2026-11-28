//! Native peer inbox delivery. Advisory FYI mail never enters the prompt queue.
const std = @import("std");
const peer = @import("peer.zig");
const tools = @import("tools.zig");
const u = @import("util.zig");
const Value = std.json.Value;
const marker = "[fyi]";

pub fn isFyi(text: []const u8) bool {
    return std.mem.startsWith(u8, text, marker);
}

pub fn body(text: []const u8) []const u8 {
    return if (isFyi(text)) u.trim(text[marker.len..]) else text;
}

pub fn target(c: *tools.Ctx, chat: Value, harness: []const u8, session: ?Value) !?[]const u8 {
    if (!std.mem.eql(u8, harness, "graff")) return null;
    const local = c.t.origin.device_id orelse blk: {
        var probe: tools.Ctx = .{ .t = c.t, .a = c.a };
        break :blk probe.localDeviceId() catch |err| switch (err) {
            error.ToolFailed => return null,
            else => return err,
        };
    };
    return peer.peerTarget(chat, harness, session, local);
}

pub fn send(c: *tools.Ctx, chat_id: []const u8, to: []const u8, text: []const u8, fyi: bool) !peer.PeerSend.SendResult {
    const from = if (c.t.origin.chat_id) |origin| blk: {
        // Account for the attributed hop before writing to the peer inbox.
        if (try c.t.relay.record(c.a, chat_id, peer.relayDepth(text), origin, c.t.nowMs())) |reason|
            return .{ .err = try std.fmt.allocPrint(c.a, "relay depth not recorded: {s}", .{reason}) };
        break :blk try std.fmt.allocPrint(c.a, "harness:{s}", .{u.short(origin)});
    } else blk: {
        c.t.relay.clear(c.a, chat_id);
        break :blk "harness";
    };
    // The engine detects FYI at the start of the body, before attribution.
    const payload = if (fyi) try std.fmt.allocPrint(c.a, marker ++ " {s}", .{text}) else text;
    return c.t.peer.send(c.a, from, to, payload);
}

pub fn sendFyi(c: *tools.Ctx, chat: Value, session: ?Value, text: []const u8) !Value {
    if (u.boolean(chat, "archived") orelse false) return c.failMsg(tools.archived_refusal);
    const to = try target(c, chat, tools.chatHarness(chat) orelse "", session) orelse
        return c.failMsg("FYI inbox unavailable on this device");
    return switch (try send(c, u.str(chat, "id") orelse "", to, text, true)) {
        .err => |reason| c.failMsg(reason),
        .ok => |detail| result(c.a, to, detail, tools.statusOf(session, c.t.nowMs()).label),
    };
}

pub fn result(a: std.mem.Allocator, to: []const u8, detail: []const u8, status: []const u8) !Value {
    var r = u.obj(a);
    try r.put("delivery", u.s("peer"));
    try r.put("id", u.s(to));
    try r.put("detail", u.s(detail));
    try r.put("chatStatusAtSend", u.s(status));
    return r.value();
}
