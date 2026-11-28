//! Offscreen UI regressions for subagent & task management:
//! composer-footer Agent Work pill + popover card, structured `.todo` checklist,
//! live `Agent` rows with `WatchToolProgress` tails, parked `graff/waiting`
//! banner, and `.subagent` surface header + steer bar. Synthetic data only.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

test {
    _ = @import("agent_work.zig");
    _ = @import("app_tool_progress.zig");
    _ = @import("view_agent_work.zig");
}

const synthetic_chats =
    \\[{"id":"chat-syn","deviceId":"dev-syn","title":"Subagent task verification","cwd":"/work/synthetic","archived":false,"config":{"harness":"graff","model":"gpt-6.1-sol"}}]
;

const live_fixture =
    \\{"reset":[
    \\  {"id":"u1","role":"user","parts":[{"id":"up","kind":"text","text":"Verify the subagent and task UI"}]},
    \\  {"id":"a1","role":"assistant","status":"streaming","createdAt":10000,"parts":[
    \\    {"id":"todo-1","kind":"tool","resolved":true,"call":{"kind":"todo","items":[
    \\      {"text":"Map adapter events","done":true},
    \\      {"text":"Prove state machine bounds","done":false},
    \\      {"text":"Render showcase snapshots","done":false}]}},
    \\    {"id":"ag-1","kind":"tool","resolved":false,"subagentRef":"doc-lean-1","call":{
    \\      "kind":"unknown","name":"Agent: Lean verifier","input":{"model":"claude-opus-4-6"}}},
    \\    {"id":"ag-2","kind":"tool","resolved":false,"subagentRef":"doc-ui-2","call":{
    \\      "kind":"unknown","name":"Agent: Layout auditor","input":{"model":"gpt-6.1-sol"}}},
    \\    {"id":"edit-1","kind":"tool","resolved":true,"call":{"kind":"editFile","path":"src/agent_work.zig"},"diffStats":[{"path":"src/agent_work.zig","additions":24,"deletions":2}]},
    \\    {"id":"exec-1","kind":"tool","resolved":false,"call":{"kind":"exec","command":"zig build test"}}
    \\  ]}
    \\],"contextUsage":{"tokens":42000,"window":200000}}
;

const live_progress =
    \\[
    \\  {"toolId":"ag-1","output":"▸ Checking 360 state cells\n▸ Proving card_within_window","state":"running"},
    \\  {"toolId":"ag-2","output":"▸ Measuring descender clearance","state":"running"}
    \\]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, transcript_json: []const u8, progress_json: ?[]const u8) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        h.a.settings.set(.transcript_compact_mode, false);

        var chats = try std.json.parseFromSlice(std.json.Value, testing.allocator, synthetic_chats, .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("chat-syn", null);

        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, transcript_json, .{});
        defer parsed.deinit();
        try h.a.transcript.apply(parsed.value);

        if (progress_json) |pj| {
            var prog = try std.json.parseFromSlice(std.json.Value, testing.allocator, pj, .{});
            defer prog.deinit();
            try @import("app_progress.zig").apply(&h.a, "chat-syn", prog.value);
        }

        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1280, .height = 820, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }
};

test "809 footer Agent Work chip opens clamped popover and links into subagent surface" {
    var h: Harness = undefined;
    try h.init(live_fixture, live_progress);
    defer h.deinit();

    // Footer chip shows live agent count beside the context meter.
    try testing.expect(h.t.hasText("2 agents"));
    const anchor = h.a.view.agent_work.anchor orelse return error.MissingAgentWorkAnchor;

    // Click the footer chip to pin open the Agent Work popover card.
    h.t.click(anchor.x + anchor.w / 2, anchor.y + anchor.h / 2);
    h.t.advance(0.2);
    h.t.settle(1);

    try testing.expect(h.a.view.agent_work.open);
    try testing.expect(h.t.hasText("Tasks"));
    try testing.expect(h.t.hasText("1 of 3"));
    try testing.expect(h.t.hasText("Map adapter events"));
    try testing.expect(h.t.hasText("Prove state machine bounds"));
    try testing.expect(h.t.hasText("2 agents running"));
    try testing.expect(h.t.hasText("Lean verifier"));
    try testing.expect(h.t.hasText("Proving card_within_window"));
    try testing.expect(h.t.hasText("claude-opus-4-6"));
    try testing.expect(h.t.hasText("Agents"));
    try testing.expect(h.t.hasText("Terminal"));
    try testing.expect(h.t.hasText("Files"));

    const card = h.a.view.agent_work.card orelse return error.MissingAgentWorkCard;
    try testing.expect(card.x >= 8);
    try testing.expect(card.y >= 8);
    try testing.expect(card.x + card.w <= 1280 - 8 + 0.5);
    try testing.expect(card.y + card.h <= 820 - 8 + 0.5);

    snap(&h, "agent-work-popover-dark");
    h.a.dark = false;
    h.t.settle(1);
    snap(&h, "agent-work-popover-light");
    h.a.dark = true;
    h.t.settle(1);

    // Clicking a linked subagent row inside the popover opens the right-hand subagent surface with header + steer bar.
    try h.t.clickText("claude-opus-4-6");
    h.t.settle(2);
    try testing.expect(h.a.panels.host_open);
    try testing.expectEqual(@import("app_panels.zig").TabKind.subagent, h.a.panels.activeTab().?.kind);
    try testing.expect(h.t.containsText("Steer Lean verifier"));
    const child = h.a.panels.activeTab().?.agent.?;
    const child_frame = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"child-reply","role":"assistant","status":"streaming","parts":[{"id":"child-text","kind":"text","text":"Verifying the synthetic task boundaries and reporting progress."}]}]}
    , .{});
    defer child_frame.deinit();
    try child.transcript.apply(child_frame.value);
    child.loaded = true;
    h.t.settle(1);
    snap(&h, "subagent-surface-dark");
    const completed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"items":[{"toolId":"ag-1","output":"Synthetic check complete","state":"completed"}]}
    , .{});
    defer completed.deinit();
    try @import("app_progress.zig").apply(&h.a, "chat-syn", completed.value);
    h.t.settle(1);
    try testing.expect(h.t.containsText("Follow up on Lean verifier"));
    try testing.expect(h.t.hasText("Done"));
    h.a.dark = false;
    h.t.settle(1);
    snap(&h, "subagent-surface-light");
}

test "809 expanding Todo in the task tree renders a structured checklist instead of raw JSON" {
    var h: Harness = undefined;
    try h.init(live_fixture, live_progress);
    defer h.deinit();

    // Top-level subagent rows stream live WatchToolProgress tails directly in the transcript.
    try testing.expect(h.t.hasText("Proving card_within_window"));

    // Open the Todo group ("Updated todos"), then expand the Todo row.
    try h.t.clickText("Updated todos");
    h.t.advance(0.35);
    h.t.settle(1);
    try testing.expect(h.t.hasText("1/3 done"));

    try h.t.clickText("Todo");
    h.t.advance(0.35);
    h.t.settle(1);

    try testing.expect(h.t.hasText("Map adapter events"));
    try testing.expect(h.t.hasText("Prove state machine bounds"));
    try testing.expect(h.t.hasText("Render showcase snapshots"));
    snap(&h, "todo-checklist-dark");
    // Never dump raw JSON invocation text for structured todo checklists.
    try testing.expect(!h.t.containsText("\"kind\": \"todo\""));
}

test "809 parked session displays cross-turn graff/waiting subagent status until cleared" {
    const settled_turn =
        \\{"reset":[
        \\  {"id":"u1","role":"user","parts":[{"id":"up","kind":"text","text":"Spawn background audit"}]},
        \\  {"id":"a1","role":"assistant","status":"complete","parts":[
        \\    {"id":"p1","kind":"text","text":"Launched the background audit; I will wake when it reports back."}
        \\  ]}
        \\]}
    ;
    const waiting_progress =
        \\[{"toolId":"harness:graff-waiting","output":"{\"text\":\"Waiting on 1 background subagent\",\"wakes\":true,\"agents\":[{\"id\":\"bg-1\",\"name\":\"Security auditor\",\"model\":\"claude-opus-4-6\",\"task\":\"Scanning auth routes\"}]}","state":"parked"}]
    ;

    var h: Harness = undefined;
    try h.init(settled_turn, waiting_progress);
    defer h.deinit();

    try testing.expect(h.t.hasText("Waiting on 1 background subagent"));
    try testing.expect(h.t.hasText("· wakes when done"));
    try testing.expect(h.t.hasText("1 agent running"));

    snap(&h, "parked-waiting-dark");
    // Clearing graff/waiting removes both the banner and the running footer pill.
    var cleared = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[]", .{});
    defer cleared.deinit();
    try @import("app_progress.zig").apply(&h.a, "chat-syn", cleared.value);
    h.t.settle(1);

    try testing.expect(!h.t.hasText("Waiting on 1 background subagent"));
    try testing.expect(!h.t.hasText("1 agent running"));
}

test "809 Agent Work synthetic regression" {
    var h: Harness = undefined;
    try h.init(live_fixture, live_progress);
    defer h.deinit();
    if (std.c.getenv("NANO_SNAP_DIR")) |dir| {
        var buf: [2048]u8 = undefined;
        try h.t.screenshot(try std.fmt.bufPrint(&buf, "{s}/agent-work.png", .{std.mem.span(dir)}));
    }
    try testing.expect(h.t.hasText("2 agents"));
}

fn snap(h: *Harness, name: []const u8) void {
    const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
    var buf: [2048]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
    h.t.screenshot(path) catch {};
}

test "ACP Preview transient status is shown and clears without transcript changes" {
    var h: Harness = undefined;
    try h.init("{\"reset\":[]}", null);
    defer h.deinit();
    snap(&h, "preview-status-before");
    const states = [_]struct { state: []const u8, label: []const u8, name: []const u8 }{
        .{ .state = "waiting", .label = "Recovering agent connection", .name = "preview-recovery-after" },
        .{ .state = "child-permission", .label = "Subagent requested permission", .name = "preview-child-activity-after" },
    };
    for (states) |fixture| {
        const frame = try std.json.Stringify.valueAlloc(testing.allocator, .{.{ .toolId = "harness:acp-preview:synthetic", .output = "", .state = fixture.state }}, .{});
        defer testing.allocator.free(frame);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        try @import("app_progress.zig").apply(&h.a, "chat-syn", parsed.value);
        h.t.settle(2);
        try testing.expect(h.t.hasText(fixture.label));
        snap(&h, fixture.name);
        const empty = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[]", .{});
        defer empty.deinit();
        try @import("app_progress.zig").apply(&h.a, "chat-syn", empty.value);
        h.t.settle(2);
        try testing.expect(!h.t.hasText(fixture.label));
        try testing.expectEqual(@as(usize, 0), h.a.transcript.entries.items.len);
    }
}

test "ACP Preview communication links open only the associated local child" {
    const fixture =
        \\{"reset":[{"id":"assistant","role":"assistant","status":"complete","parts":[
        \\{"id":"first","kind":"tool","resolved":true,"call":{"kind":"agentCommunication","outgoing":true,"childKey":"acp2-child:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"subagentRef":"chat-syn--sub--fd5d8f38f7cd3ace"},
        \\{"id":"second","kind":"tool","resolved":true,"call":{"kind":"agentCommunication","outgoing":false,"childKey":"acp2-child:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"subagentRef":"chat-syn--sub--3b6f1494bd7cb2d8"},
        \\{"id":"collision","kind":"tool","resolved":true,"call":{"kind":"agentCommunication","outgoing":true,"childKey":"acp2-child:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"subagentRef":"chat-syn--sub--3b6f1494bd7cb2d8"}]}]}
    ;
    var filler: std.ArrayList(u8) = .empty;
    defer filler.deinit(testing.allocator);
    try filler.appendSlice(testing.allocator, "\"id\":\"height\",\"kind\":\"text\",\"text\":\"");
    for (0..80) |_| try filler.appendSlice(testing.allocator, "Synthetic line\\n\\n");
    try filler.appendSlice(testing.allocator, "\"},{\"id\":\"first\"");
    const tall = try std.mem.replaceOwned(u8, testing.allocator, fixture, "\"id\":\"first\"", filler.items);
    defer testing.allocator.free(tall);
    var h: Harness = undefined;
    try h.init(tall, null);
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"WatchDocMessages\":[]}", .{});
    h.a.engine.state = .connected;
    h.a.composer.set("Synthetic draft");
    const attachment = try h.a.gpa.create(@import("app_attachments.zig").Item);
    attachment.* = .{
        .app = &h.a,
        .owner = try h.a.gpa.dupe(u8, "chat-syn"),
        .name = try h.a.gpa.dupe(u8, "fixture.txt"),
        .bytes = try h.a.gpa.dupe(u8, "fixture"),
        .target = null,
        .id = "00000000-0000-0000-0000-000000000001".*,
        .status = .ready,
    };
    try h.a.attachments.items.append(h.a.gpa, attachment);
    h.a.view.stick_end = false;
    const parts = h.a.transcript.entries.items[0].parts.items[1..];
    const api = @import("app_subagents.zig");
    api.open(&h.a, "chat-syn", &parts[2]);
    api.settleFrame(&h.a);
    try testing.expect(h.a.panels.activeTab() == null);
    h.t.settle(2);
    const scroll_key = std.hash.Wyhash.hash(0x5452_414e_5343_5250, "chat-syn");
    try testing.expect((h.t.ctx.scroll_max.get(scroll_key) orelse 0) > 80);
    try h.t.ctx.scroll.put(h.t.ctx.gpa, scroll_key, 80);
    try h.t.ctx.scroll_seen.put(h.t.ctx.gpa, scroll_key, 80);
    try h.t.ctx.scroll_follow.put(h.t.ctx.gpa, scroll_key, false);
    h.t.settle(1);
    const parent_offset = h.t.ctx.scroll.get(scroll_key) orelse 0;
    try testing.expectEqual(@as(f32, 80), parent_offset);
    const parent_follow = h.t.ctx.scroll_follow.get(scroll_key);
    const start = h.a.engine.sent.items.len;
    for (parts[0..2], 0..) |*part, index| {
        api.open(&h.a, "chat-syn", part);
        api.settleFrame(&h.a);
        const child = h.a.panels.activeTab().?.agent.?;
        try testing.expect(child.read_only);
        try testing.expectEqualStrings(part.subagent_ref, child.doc);
        const child_frame = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"reset":[{"id":"reply","role":"assistant","status":"complete","parts":[{"id":"text","kind":"text","text":"Handoff reviewed."}]}]}
        , .{});
        defer child_frame.deinit();
        try child.transcript.apply(child_frame.value);
        h.t.settle(1);
        if (index == 0) snap(&h, "communication-linked");
        @import("view_host.zig").submitSubagentSteer(&h.a, child, "Must not send");
        @import("app_panels.zig").closeTab(&h.a, h.a.panels.active);
        try testing.expectEqualStrings("chat-syn", h.a.selected.?);
        try testing.expectEqualStrings("Synthetic draft", h.a.composer.text());
        try testing.expect(!h.a.view.stick_end);
        try testing.expectEqual(parent_offset, h.t.ctx.scroll.get(scroll_key) orelse 0);
        try testing.expectEqual(parent_follow, h.t.ctx.scroll_follow.get(scroll_key));
        try testing.expectEqual(@as(usize, 1), h.a.attachments.items.items.len);
        try testing.expect(h.a.attachments.items.items[0] == attachment);
        try testing.expectEqualStrings("fixture", attachment.bytes);
    }
    const frames = h.a.engine.sent.items[start..];
    try testing.expectEqual(@as(usize, 2), frames.len);
    for (frames) |frame| try testing.expect(std.mem.indexOf(u8, frame, "\"method\":\"WatchDocMessages\"") != null);
}

test "ACP Preview read-only child pane keeps the running worker and parent composer separate" {
    var h: Harness = undefined;
    try h.init(live_fixture, live_progress);
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"WatchDocMessages":[],"QueueCommand":{}}
    , .{});
    h.a.engine.state = .connected;
    h.a.composer.set("Synthetic parent draft");
    h.a.view.focus_composer = true;
    const start = h.a.engine.sent.items.len;
    const part = &h.a.transcript.entries.items[1].parts.items[1];
    @import("app_subagents.zig").open(&h.a, "chat-syn", part);
    @import("app_subagents.zig").settleFrame(&h.a);
    const child = h.a.panels.activeTab().?.agent.?;
    try testing.expectEqualStrings("doc-lean-1", child.doc);
    const watch = child.watch orelse return error.MissingChildWatch;
    try testing.expect(h.a.engine.mux.pending.contains(watch));
    try testing.expectEqualStrings("chat-syn", h.a.selected.?);
    try testing.expectEqualStrings("Synthetic parent draft", h.a.composer.text());
    @import("app_panels.zig").closeTab(&h.a, h.a.panels.active);
    try testing.expect(!h.a.panels.host_open);
    try testing.expect(!h.a.engine.mux.pending.contains(watch));
    try testing.expectEqualStrings("chat-syn", h.a.selected.?);
    try testing.expectEqualStrings("Synthetic parent draft", h.a.composer.text());
    // The pane lifecycle may start/stop its observation, never a child run.
    const prior = h.a.engine.sent.items[start..];
    try testing.expectEqual(@as(usize, 1), prior.len);
    try testing.expect(std.mem.indexOf(u8, prior[0], "\"method\":\"WatchDocMessages\"") != null);
    const after_close = h.a.engine.sent.items.len;
    h.a.send();
    const frames = h.a.engine.sent.items[after_close..];
    try testing.expectEqual(@as(usize, 1), frames.len);
    try testing.expect(std.mem.indexOf(u8, frames[0], "\"method\":\"QueueCommand\"") != null);
    try testing.expect(std.mem.indexOf(u8, frames[0], "\"chatId\":\"chat-syn\"") != null);
    try testing.expect(std.mem.indexOf(u8, frames[0], "doc-lean-1") == null);
}

test "809 subagent follow-up routes through parent without consuming composer draft" {
    var h: Harness = undefined;
    try h.init(live_fixture, live_progress);
    defer h.deinit();
    const part = &h.a.transcript.entries.items[1].parts.items[1];
    @import("app_subagents.zig").open(&h.a, "chat-syn", part);
    @import("app_subagents.zig").settleFrame(&h.a);
    const sub = h.a.panels.activeTab().?.agent.?;
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"QueueMessage":{"id":"queued-synthetic"},"SteerQueuedMessageNow":{"sent":true}}
    , .{});
    h.a.engine.state = .connected;
    h.a.composer.set("Keep this draft and its attachments");
    h.a.view.subagent_steer.set("Check the final boundary case");
    @import("view_host.zig").submitSubagentSteer(&h.a, sub, h.a.view.subagent_steer.text());
    try testing.expectEqualStrings("Keep this draft and its attachments", h.a.composer.text());
    try testing.expectEqualStrings("chat-syn", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.engine.sent.items.len);
    const sent = try std.json.parseFromSlice(std.json.Value, testing.allocator, h.a.engine.sent.items[0], .{});
    defer sent.deinit();
    try testing.expectEqualStrings("QueueMessage", sent.value.object.get("method").?.string);
    const params = sent.value.object.get("params").?.object;
    try testing.expectEqualStrings("chat-syn", params.get("chatId").?.string);
    try testing.expectEqualStrings("For subagent \"Lean verifier\": Check the final boundary case", params.get("text").?.string);

    // A live steer uses the parent's established queue/promote path, never the child doc.
    const sessions = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"chatId":"chat-syn","status":"working","updatedAt":1000}]
    , .{});
    defer sessions.deinit();
    try h.a.sessions.replace(sessions.value);
    h.a.device_id = try testing.allocator.dupe(u8, "dev-syn");
    h.a.caps.queue = true;
    h.a.caps.actions = true;
    try testing.expect(@import("app_queue.zig").steerBlocker(&h.a, true, false) == null);
    @import("view_host.zig").submitSubagentSteer(&h.a, sub, "Continue the boundary audit");
    _ = h.a.engine.pump();
    _ = h.a.engine.pump();
    try testing.expectEqual(@as(usize, 3), h.a.engine.sent.items.len);
    const promoted = try std.json.parseFromSlice(std.json.Value, testing.allocator, h.a.engine.sent.items[2], .{});
    defer promoted.deinit();
    try testing.expectEqualStrings("SteerQueuedMessageNow", promoted.value.object.get("method").?.string);
    try testing.expectEqualStrings("chat-syn", promoted.value.object.get("params").?.object.get("chatId").?.string);
    try testing.expectEqualStrings("Keep this draft and its attachments", h.a.composer.text());
}
