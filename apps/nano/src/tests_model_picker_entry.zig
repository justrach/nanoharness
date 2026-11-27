//! The model picker has one way in: its chip under the composer. No slash
//! command of the app's own and no shortcut opens it, and the chip works
//! from the keyboard as it does from the pointer. Driven headlessly on
//! made-up chats, agents and models; no engine, no person's data.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const shortcuts = @import("shortcuts.zig");
const completion = @import("composer_completion.zig");
const rules = @import("completion_rules.zig");
const theme = @import("theme.zig");
const S = ui.Shortcut;
const testing = std.testing;

const catalog =
    \\[{"id":"openai/synthetic-fast","label":"Synthetic Fast","description":"128k context","maker":"openai","billing":"credits","reasoningLevels":["low","high"]},
    \\ {"id":"openai/synthetic-max","label":"Synthetic Max","description":"256k context","maker":"openai","billing":"credits","reasoningLevels":["high","max"]}]
;

/// An agent whose own command list has no `model`.
const no_model_commands =
    \\{"ListCommands":[{"name":"goal","description":"Synthetic goal command"},{"name":"compact","description":"Compact the synthetic context"}],"ListSkills":[],"QueueCommand":{"commandId":"synthetic-command"},"FocusChat":{},"Mutate":{}}
;
/// An agent with a `model` command of its own.
const own_model_commands =
    \\{"ListCommands":[{"name":"model","description":"Synthetic agent model command"},{"name":"compact","description":"Compact the synthetic context"}],"ListSkills":[],"QueueCommand":{"commandId":"synthetic-command"},"FocusChat":{},"Mutate":{}}
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, scene: []const u8) !void {
        theme.registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        h.a.device_id = try testing.allocator.dupe(u8, "studio");
        h.a.new_harness = try testing.allocator.dupe(u8, "graff");
        h.a.models_for = try testing.allocator.dupe(u8, "graff");
        try replace(&h.a.devices,
            \\[{"id":"studio","name":"Studio"}]
        );
        try replace(&h.a.spaces,
            \\[{"id":"fieldnotes","deviceId":"studio","path":"/synthetic/fieldnotes"}]
        );
        try replace(&h.a.chats,
            \\[{"id":"cedar","deviceId":"studio","title":"Cedar layout audit","spaceId":"fieldnotes","cwd":"/synthetic/fieldnotes","archived":false,"config":{"harness":"graff","model":"openai/synthetic-fast","reasoning":"high"}},
            \\ {"id":"rowan","deviceId":"studio","title":"Rowan palette review","spaceId":"fieldnotes","cwd":"/synthetic/fieldnotes","archived":false,"config":{"harness":"graff","model":"openai/synthetic-max","reasoning":"high"}}]
        );
        try replace(&h.a.harnesses,
            \\[{"id":"graff","name":"graff","enabled":true},{"id":"codex","name":"Codex","enabled":true}]
        );
        try replace(&h.a.models, catalog);
        h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
        h.a.engine.state = .connected;
        h.a.openChat("cedar", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true, .theme = theme.ui(true) });
        h.draw();
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    /// The catalog's answers delivered and drawn.
    fn draw(h: *Harness) void {
        for (0..2) |_| {
            _ = h.a.engine.pump();
            h.t.ctx.changed = true;
            h.t.settle(2);
        }
    }

    fn draft(h: *Harness, text: []const u8) void {
        h.a.composer.set(text);
        h.a.composer.want_caret = text.len;
        h.a.view.focus_composer = true;
        h.draw();
    }

    fn press(h: *Harness, key: S) void {
        _ = h.t.shortcut(key);
        h.t.settle(1);
    }

    /// The node the chip is drawn as, by the rect it last had.
    fn chip(h: *Harness) !u32 {
        const anchor = h.a.view.chip_anchor orelse return error.MissingChip;
        for (h.t.ctx.nodes.items, 0..) |node, i| {
            if (node.interactive and std.meta.eql(node.rect, anchor)) return @intCast(i);
        }
        return error.MissingChip;
    }

    fn chipId(h: *Harness) !u64 {
        return h.t.ctx.node(try h.chip()).id;
    }

    /// Tab from the message box until the chip has the focus, as a person
    /// with no pointer does.
    fn tabToChip(h: *Harness) !void {
        h.a.view.focus_composer = true;
        h.t.settle(1);
        try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
        const want = try h.chipId();
        for (0..64) |_| {
            h.t.key(.tab);
            h.t.settle(1);
            if (h.t.ctx.focus == want) return;
        }
        return error.ChipNotInFocusOrder;
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

fn replace(list: anytype, text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try list.replace(parsed.value);
}

/// What `/model` offers: every entry named `model` or `…:model`.
fn modelEntries(h: *Harness, arena: std.mem.Allocator) ![]const completion.Entry {
    const rows = try completion.entries(&h.a, arena, rules.token("/model", 6).?);
    var out: std.ArrayList(completion.Entry) = .empty;
    for (rows) |e| if (std.mem.endsWith(u8, e.name, "model")) try out.append(arena, e);
    return out.items;
}

fn noHarnessModel(rows: []const completion.Entry) !void {
    for (rows) |e| try testing.expect(std.mem.indexOf(u8, e.name, "harness:model") == null);
}

test "model picker entry: /model offers nothing of the app's where the agent has no model command" {
    var h: Harness = undefined;
    try h.init(no_model_commands);
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(h.a.completion.commands_done);
    const rows = try modelEntries(&h, arena.allocator());
    try testing.expectEqual(@as(usize, 0), rows.len);
    try noHarnessModel(rows);
    // Nor while the agent's commands are still loading, when the app's own
    // are offered under `harness:`.
    h.a.completion.commands_done = false;
    try noHarnessModel(try completion.entries(&h.a, arena.allocator(), rules.token("/harness:model", 14).?));
    try testing.expectEqual(@as(usize, 0), (try modelEntries(&h, arena.allocator())).len);
    h.a.completion.commands_done = true;
    // Typed and accepted from the menu, it doesn't open the picker.
    h.draft("/model");
    try testing.expect(!h.t.hasText("Choose agent, model and reasoning"));
    h.press(.{ .key = S.tab });
    h.draw();
    try testing.expectEqual(.none, h.a.picker);
}

test "model picker entry: /model is only the agent's own where the agent has one" {
    var h: Harness = undefined;
    try h.init(own_model_commands);
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rows = try modelEntries(&h, arena.allocator());
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("model", rows[0].name);
    try testing.expect(rows[0].action == null);
    try testing.expectEqualStrings("Synthetic agent model command", rows[0].description);
    try noHarnessModel(rows);
    try noHarnessModel(try completion.entries(&h.a, arena.allocator(), rules.token("/harness:", 9).?));
    h.draft("/mo");
    h.snap("slash-mo-agent-model");
    try testing.expect(h.t.hasText("Synthetic agent model command"));
    try testing.expect(!h.t.containsText("harness:model"));
    h.press(.{ .key = S.tab });
    h.draw();
    // The agent's command, as a reference in the draft; no picker.
    try testing.expectEqualStrings("/model ", h.a.composer.text());
    try testing.expectEqual(.none, h.a.picker);
    const sent = (try completion.prompt(&h.a)) orelse return error.MissingAgentCommand;
    defer testing.allocator.free(sent);
    try testing.expect(std.mem.indexOf(u8, sent, "harness-invoke:") != null);
}

test "model picker entry: Cmd+/ and Ctrl+/ do not open the picker" {
    var h: Harness = undefined;
    try h.init(no_model_commands);
    defer h.deinit();
    for ([_]S{ .{ .key = '/', .cmd = true }, .{ .key = '/', .ctrl = true } }) |key| {
        h.press(key);
        try testing.expectEqual(.none, h.a.picker);
    }
    // Nor from inside an open picker (it used to close it).
    const chip = h.a.view.chip_anchor orelse return error.MissingChip;
    h.t.click(chip.x + chip.w / 2, chip.y + chip.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.picker == .model);
    h.press(.{ .key = '/', .cmd = true });
    try testing.expect(h.a.picker == .model);
}

test "model picker entry: a saved openModelPicker binding loads cleanly and does nothing" {
    var h: Harness = undefined;
    try h.init(no_model_commands);
    defer h.deinit();
    h.a.settings.apply(
        \\{"keymap":{"openModelPicker":"mod-alt-y"}}
    );
    try testing.expect(!h.a.settings.keymapChanged());
    for (shortcuts.all) |entry| try testing.expect(!std.mem.eql(u8, entry.key, "openModelPicker"));
    h.press(.{ .key = 'y', .cmd = true, .alt = true });
    try testing.expectEqual(.none, h.a.picker);
    h.press(.{ .key = '/', .cmd = true });
    try testing.expectEqual(.none, h.a.picker);
    try testing.expect(h.a.noticeText() == null);
}

test "model picker entry: Settings > Shortcuts has no model picker row and nothing advertises a key for it" {
    for (shortcuts.all) |entry| {
        try testing.expect(std.ascii.findIgnoreCase(entry.title, "model") == null);
        try testing.expect(!std.mem.eql(u8, entry.default, "mod-/"));
    }
    for (shortcuts.fixed) |entry| try testing.expect(std.ascii.findIgnoreCase(entry.title, "model") == null);
    var h: Harness = undefined;
    try h.init(no_model_commands);
    defer h.deinit();
    h.a.settings.setSection(.shortcuts);
    @import("view_settings.zig").open(&h.a);
    h.t.settle(1);
    try testing.expect(h.t.hasText("New chat"));
    try testing.expect(!h.t.hasText("Open model picker"));
    try testing.expect(!h.t.containsText("model picker"));
    // The picker itself, the compact card and the full list it expands to,
    // shows no key that opens it.
    @import("view_settings.zig").close(&h.a);
    h.t.settle(1);
    const chip = h.a.view.chip_anchor orelse return error.MissingChip;
    h.t.click(chip.x + chip.w / 2, chip.y + chip.h / 2);
    h.t.settle(1);
    for ([_]bool{ true, false }) |compact| {
        try testing.expectEqual(compact, h.a.view.model_picker.stage != null);
        for ([_][]const u8{ "⌘/", "Cmd+/", "Ctrl+/" }) |hint| try testing.expect(!h.t.containsText(hint));
        h.press(.{ .key = S.enter });
    }
}

test "model picker entry: clicking the chip opens the compact card" {
    var h: Harness = undefined;
    try h.init(no_model_commands);
    defer h.deinit();
    try testing.expectEqual(.none, h.a.picker);
    const chip = h.a.view.chip_anchor orelse return error.MissingChip;
    h.t.click(chip.x + chip.w / 2, chip.y + chip.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.picker == .model);
    try testing.expect(h.a.view.model_picker.stage.?.compact);
    // The full list is the same card's: its model row expands it, Escape
    // comes back to the compact card.
    h.press(.{ .key = S.enter });
    try testing.expect(h.a.view.model_picker.stage == null);
    try testing.expect(h.a.view.model_picker.can_return_compact);
    h.press(.{ .key = S.escape });
    try testing.expect(h.a.view.model_picker.stage.?.compact);
    h.press(.{ .key = S.escape });
    try testing.expectEqual(.none, h.a.picker);
}

test "model picker entry: Tab reaches the chip, it shows its focus, Return opens it and Escape returns to the message box" {
    var h: Harness = undefined;
    try h.init(no_model_commands);
    defer h.deinit();
    try h.tabToChip();
    const chip = try h.chip();
    // A visible focus state: the accent ring, painted.
    const ring = h.t.ctx.node(chip).style.border orelse return error.MissingFocusRing;
    try testing.expectEqualDeep(theme.colors(true).accent, ring);
    try testing.expect(h.t.ctx.node(chip).style.border_width > 0);
    var found = false;
    for (h.t.ctx.a11y_items.items) |item| if (item.node_index == chip) {
        found = true;
        try testing.expectEqual(ui.access.Role.button, item.role);
    };
    try testing.expect(found);
    h.t.key(.enter);
    h.t.settle(1);
    try testing.expect(h.a.picker == .model);
    try testing.expect(h.a.view.model_picker.stage.?.compact);
    h.snap("compact-card-from-keyboard");
    // Escape closes it, and (today's rule for the compact card) the message
    // box has the focus again.
    h.press(.{ .key = S.escape });
    try testing.expectEqual(.none, h.a.picker);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    // Space opens it as Return does.
    try h.tabToChip();
    h.t.typeText(" ");
    h.t.settle(1);
    try testing.expect(h.a.picker == .model);
    try testing.expect(h.a.view.model_picker.stage.?.compact);
}

test "model picker entry: the chip opens the same card in a window, full screen, one pane and a split's focused pane" {
    for ([_]bool{ false, true }) |full_screen| for ([_]bool{ false, true }) |split| {
        var h: Harness = undefined;
        try h.init(no_model_commands);
        defer h.deinit();
        if (split) {
            h.a.splitPane(.horizontal);
            h.t.settle(1);
        }
        if (full_screen) {
            h.a.setFullScreen(true);
            h.t.settle(1);
        }
        // By pointer.
        const chip = h.a.view.chip_anchor orelse return error.MissingChip;
        h.t.click(chip.x + chip.w / 2, chip.y + chip.h / 2);
        h.t.settle(1);
        try testing.expect(h.a.picker == .model);
        try testing.expect(h.a.view.model_picker.stage.?.compact);
        h.press(.{ .key = S.escape });
        try testing.expectEqual(.none, h.a.picker);
        // By keyboard.
        try h.tabToChip();
        h.t.key(.enter);
        h.t.settle(1);
        try testing.expect(h.a.picker == .model);
        try testing.expect(h.a.view.model_picker.stage.?.compact);
        h.press(.{ .key = S.escape });
        try testing.expectEqual(.none, h.a.picker);
        // And never by Cmd+/.
        h.press(.{ .key = '/', .cmd = true });
        try testing.expectEqual(.none, h.a.picker);
    };
}
