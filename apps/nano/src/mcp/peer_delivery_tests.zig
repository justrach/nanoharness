const std = @import("std");
const fixture = @import("unit_tests.zig");
const u = @import("util.zig");
const testing = std.testing;

const local_chat =
    \\,{"id":"chat-delta-4","deviceId":"dev-local","title":"Delta","archived":false,"config":{"harness":"graff"},"harnessSessionId":"sess-delta"}
;
const remote_chat =
    \\,{"id":"chat-delta-4","deviceId":"dev-remote","title":"Delta","archived":false,"config":{"harness":"graff"},"harnessSessionId":"sess-delta"}
;
const working =
    \\[{"chatId":"chat-delta-4","deviceId":"dev-local","status":"working","updatedAt":"2026-11-10T00:45:00Z"}]
;

test "mcp peer delivery #1803: local working recipients get attributed native inbox mail" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const w = try fixture.WorldFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer w.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    w.t.relay.dir = try tmp.dir.realPathFileAlloc(testing.io, ".", w.arena.allocator());
    w.world.extra_chats = local_chat;
    w.world.sessions = working;
    const v = try fixture.ok(try w.call("send_message", "{\"chat\":\"Delta\",\"text\":\"evidence received\"}"));
    try testing.expectEqualStrings("peer", u.str(u.field(v, "sent"), "delivery").?);
    try testing.expectEqual(@as(usize, 0), w.world.writes.items.len);
    try testing.expectEqual(@as(usize, 1), w.peer.sends.items.len);
    const from, const to, const body = w.peer.sends.items[0];
    try testing.expectEqualStrings("harness:chat-bet", from);
    try testing.expectEqualStrings("sess-delta", to);
    try testing.expect(std.mem.startsWith(u8, body, "[Message from Harness chat Beta"));
}

test "mcp peer delivery #1803: FYI never starts a prompt or falls back to the queue" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const w = try fixture.WorldFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer w.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    w.t.relay.dir = try tmp.dir.realPathFileAlloc(testing.io, ".", w.arena.allocator());
    w.world.extra_chats = local_chat;
    const args = "{\"chat\":\"Delta\",\"text\":\"[fyi] evidence received\"}";
    const v = try fixture.ok(try w.call("send_message", args));
    try testing.expectEqualStrings("peer", u.str(u.field(v, "sent"), "delivery").?);
    try testing.expectEqual(@as(usize, 1), w.peer.sends.items.len);
    try testing.expect(std.mem.startsWith(u8, w.peer.sends.items[0][2], "[fyi] [Message from Harness chat Beta"));
    w.world.sessions = working;
    w.peer.fail = "native send failed";
    try fixture.expectErr(try w.call("send_message", args), "native send failed");
    w.world.extra_chats = remote_chat;
    try fixture.expectErr(try w.call("send_message", args), "FYI inbox unavailable on this device");
    try testing.expectEqual(@as(usize, 0), w.world.writes.items.len);
}

test "mcp peer delivery #1803: actionable queue fallback names the unavailable native inbox" {
    const w = try fixture.WorldFixture.create(.{ .chat_id = "chat-beta-2", .device_id = "dev-local" });
    defer w.destroy();
    w.world.extra_chats = remote_chat;
    w.world.sessions =
        \\[{"chatId":"chat-delta-4","deviceId":"dev-remote","status":"working","updatedAt":"2026-11-10T00:45:00Z"}]
    ;
    const v = try fixture.ok(try w.call("send_message", "{\"chat\":\"Delta\",\"text\":\"can you verify the output?\"}"));
    const sent = u.field(v, "sent");
    try testing.expectEqualStrings("queue", u.str(sent, "delivery").?);
    try testing.expectEqualStrings("native graff peer inbox unavailable on this device", u.str(sent, "peerFallback").?);
    try testing.expectEqual(@as(usize, 1), w.world.writes.items.len);
    try testing.expectEqual(@as(usize, 0), w.peer.sends.items.len);
}
