//! Actual editor owners, synthetic engine requests/acks, and mounted input.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const files = @import("app_files.zig");
const editors = @import("app_file_editor.zig");
const Editor = editors.Editor;
const writable =
    \\{"ReadWorkspaceFile":{"checkoutId":"checkout-original","path":"notes.txt","text":"original","contentHash":"hash-original","size":8,"encoding":"utf8","lineEnding":"lf","truncated":false},"WriteWorkspaceFile":{"status":"written","file":{"path":"notes.txt","contentHash":"hash-after-save","size":10}}}
;
fn connect(h: *Harness, source: []const u8) !void {
    if (h.a.engine.scene) |*old| old.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, source, .{});
    h.a.engine.state = .connected;
}
fn open(h: *Harness) !*Editor {
    files.openFile(&h.a, "notes.txt");
    _ = h.a.engine.pump();
    const e = h.a.panels.tabs.items[h.a.panels.active].editor orelse return error.NoEditor;
    try testing.expect(!e.loading and e.editable);
    return e;
}
fn edit(e: *Editor, text: []const u8) void {
    e.buffer.set(text);
    e.changed();
}
fn count(h: *Harness, method: []const u8) !usize {
    var n: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.object.get("method").?.string, method)) n += 1;
    }
    return n;
}
test "file settings apply Show all to root expanded folders and active search" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h,
        \\{"ListWorkspaceDirectory":{"entries":[]},"SearchWorkspaceFiles":[]}
    );
    h.a.settings.set(.files_show_all, true);
    files.toggle(&h.a);
    files.toggleDir(&h.a, "synthetic-folder");
    h.a.panels.search.set("synthetic");
    files.search(&h.a);
    try expectVisibilityRequests(&h, 0, true);
    const before = h.a.engine.sent.items.len;
    h.a.settings.set(.files_show_all, false);
    _ = h.a.tick(h.a.now);
    try expectVisibilityRequests(&h, before, false);
}

fn expectVisibilityRequests(h: *Harness, start: usize, include_ignored: bool) !void {
    var root: usize = 0;
    var expanded: usize = 0;
    var search: usize = 0;
    for (h.a.engine.sent.items[start..]) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const method = parsed.value.object.get("method").?.string;
        if (std.mem.eql(u8, method, "ListWorkspaceDirectory")) {
            const params = parsed.value.object.get("params").?.object;
            try testing.expectEqual(include_ignored, params.get("includeIgnored").?.bool);
            const dir = params.get("directory").?.string;
            if (dir.len == 0) root += 1;
            if (std.mem.eql(u8, dir, "synthetic-folder")) expanded += 1;
        } else if (std.mem.eql(u8, method, "SearchWorkspaceFiles")) {
            const params = parsed.value.object.get("params").?.object;
            try testing.expectEqual(include_ignored, params.get("includeIgnored").?.bool);
            try testing.expectEqualStrings("synthetic", params.get("query").?.string);
            search += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), root);
    try testing.expectEqual(@as(usize, 1), expanded);
    try testing.expectEqual(@as(usize, 1), search);
}

test "file settings Word wrap changes a mounted editor without changing its text" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    const e = try open(&h);
    const long = "synthetic text for wrapping " ++ "with enough words to extend beyond the editor's viewport when the text should stay on a single physical line. " ++ "More synthetic words make the line reliably wider than the pane even if the pane is expanded by the window layout. " ++ "A further phrase provides room to test horizontal scrolling.";
    edit(e, long ++ "\nsecond physical line");
    h.t.settle(0.2);
    const unwrapped = h.t.ctx.rects.get(e.field) orelse return error.MissingEditorGeometry;
    const before_scroll = h.t.findText(long) orelse return error.MissingUnwrappedLine;
    h.t.moveTo(unwrapped.x + unwrapped.w / 2, unwrapped.y + 8);
    h.t.ctx.input.scroll = .{ .x = -200 };
    h.t.frame();
    const after_scroll = h.t.findText(long) orelse return error.MissingUnwrappedLine;
    try testing.expect(after_scroll.x < before_scroll.x);
    h.t.click(unwrapped.x + 12, unwrapped.y + 8);
    const caret = h.t.ctx.focused_text orelse return error.MissingEditorFocus;
    try testing.expect(caret.caret > 10 and caret.caret < long.len);
    h.a.settings.set(.files_word_wrap, true);
    h.t.settle(0.2);
    const wrapped = h.t.ctx.rects.get(e.field) orelse return error.MissingEditorGeometry;
    try testing.expect(wrapped.h > unwrapped.h);
    try testing.expect(!h.t.hasText(long));
    h.a.settings.set(.files_word_wrap, false);
    h.t.settle(0.2);
    const restored = h.t.ctx.rects.get(e.field) orelse return error.MissingEditorGeometry;
    try testing.expectEqual(unwrapped.h, restored.h);
    try testing.expectEqualStrings(long ++ "\nsecond physical line", e.buffer.text());
}

test "file settings Autosave debounces latest text and keeps its remote owner" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    h.a.openChatInTab("b");
    const e = try open(&h);
    const start = h.a.now;
    edit(e, "still manual by default");
    _ = h.a.tick(start + 5);
    try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    h.a.settings.set(.files_autosave_enabled, true);
    edit(e, "intermediate edit");
    _ = h.a.tick(start + 5.5);
    edit(e, "latest remote edit");
    h.a.openChatInTab("a");
    _ = h.a.tick(start + 5.9); // Past the first edit's deadline, before the second's.
    try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    _ = h.a.tick(start + 7);
    try testing.expectEqual(@as(usize, 1), try count(&h, "WriteWorkspaceFile"));
    try testing.expect(e.dirty());
    const write_id = e.save_id orelse return error.MissingAutosave;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("id").?.integer != write_id) continue;
        const params = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings("b", params.get("chatId").?.string);
        try testing.expectEqualStrings("remote", params.get("targetDeviceId").?.string);
        try testing.expectEqualStrings("checkout-original", params.get("expectedCheckoutId").?.string);
        try testing.expectEqualStrings("hash-original", params.get("expectedContentHash").?.string);
        try testing.expectEqualStrings("latest remote edit", params.get("text").?.string);
    }
    _ = h.a.tick(start + 7.1);
    try testing.expect(!e.dirty());
    try testing.expectEqualStrings("hash-after-save", e.hash);
    try testing.expectEqual(@as(usize, 1), try count(&h, "WriteWorkspaceFile"));
}

test "file settings Autosave stops on disable and disk conflict without losing text" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h,
        \\{"ReadWorkspaceFile":{"checkoutId":"checkout-original","path":"notes.txt","text":"original","contentHash":"hash-original","size":8,"encoding":"utf8","lineEnding":"lf","truncated":false},"WriteWorkspaceFile":{"status":"conflict","reason":"changed","currentContentHash":"external-hash"}}
    );
    const e = try open(&h);
    const start = h.a.now;
    h.a.settings.set(.files_autosave_enabled, true);
    edit(e, "dirty before disable");
    h.a.settings.set(.files_autosave_enabled, false);
    _ = h.a.tick(start + 1);
    try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    try testing.expectEqualStrings("dirty before disable", e.buffer.text());
    h.a.settings.set(.files_autosave_enabled, true);
    edit(e, "retain on conflict");
    _ = h.a.tick(start + 2); // Send.
    _ = h.a.tick(start + 3); // Receive conflict.
    _ = h.a.tick(start + 10);
    try testing.expectEqual(@as(usize, 1), try count(&h, "WriteWorkspaceFile"));
    try testing.expect(e.conflict and e.dirty() and e.error_text != null);
    try testing.expectEqualStrings("retain on conflict", e.buffer.text());
    try testing.expectEqualStrings("hash-original", e.hash);
    editors.requestReload(&h.a, e);
    editors.decide(&h.a, .cancel);
    try testing.expectEqualStrings("retain on conflict", e.buffer.text());
    editors.requestReload(&h.a, e);
    editors.decide(&h.a, .discard);
    _ = h.a.tick(start + 11);
    try testing.expect(!e.dirty() and !e.conflict);
    try testing.expectEqualStrings("original", e.buffer.text());
}

test "file settings Autosave waits for an in-flight acknowledgement before saving newer text" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    const e = try open(&h);
    const start = h.a.now;
    h.a.settings.set(.files_autosave_enabled, true);
    edit(e, "manual snapshot");
    try testing.expect(e.save());
    try testing.expectEqual(@as(usize, 1), try count(&h, "WriteWorkspaceFile"));
    edit(e, "newer unsaved snapshot");
    _ = editors.tick(&h.a, start + 2); // Still awaiting the manual save reply.
    try testing.expectEqual(@as(usize, 1), try count(&h, "WriteWorkspaceFile"));
    _ = h.a.tick(start + 2); // Receive first acknowledgement, then autosave.
    try testing.expectEqual(@as(usize, 2), try count(&h, "WriteWorkspaceFile"));
    const write_id = e.save_id orelse return error.MissingFollowupAutosave;
    var found = false;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("id").?.integer != write_id) continue;
        const params = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings("hash-after-save", params.get("expectedContentHash").?.string);
        try testing.expectEqualStrings("newer unsaved snapshot", params.get("text").?.string);
        found = true;
    }
    try testing.expect(found);
    _ = h.a.tick(start + 3);
    try testing.expect(!e.dirty());
}

test "file settings Autosave does not write marked composition or bypass a close decision" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    const e = try open(&h);
    h.t.settle(0.2);
    try testing.expect(e.focused);
    h.a.settings.set(.files_autosave_enabled, true);
    h.t.textOps(&.{.{ .set_marked = .{ .text = "日本", .sel_start = 6, .sel_len = 0 } }});
    try testing.expect(e.composing and e.dirty());
    // The shortcut and close dialog also use Editor.save directly.
    try testing.expect(!e.save());
    h.t.time += 2;
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    h.t.textOps(&.{.unmark});
    try testing.expect(!e.composing and e.autosave_at != null);
    try testing.expect(h.t.ctx.frame_in != null);
    @import("app_panels.zig").closeTab(&h.a, h.a.panels.active);
    try testing.expectEqual(editors.Intent.tab, h.a.panels.file_close.intent.?);
    h.t.time += 2;
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    try testing.expectEqualStrings("original日本", e.buffer.text());
    editors.decide(&h.a, .cancel);
    h.t.frame();
    h.t.frame();
    try testing.expectEqual(@as(usize, 1), try count(&h, "WriteWorkspaceFile"));
    try testing.expect(!e.dirty());
}

test "file settings Autosave restores the selection replaced by pointer-canceled composition" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    const e = try open(&h);
    h.t.settle(0.2);
    try testing.expect(e.focused);
    h.a.settings.set(.files_autosave_enabled, true);
    h.t.textOps(&.{ .{ .select = .{ .anchor = 6, .caret = 2 } }, .{ .set_marked = .{ .text = "日本", .sel_start = 6, .sel_len = 0 } } });
    try testing.expectEqualStrings("or日本al", e.buffer.text());
    try testing.expect(e.composing);
    const rect = h.t.ctx.rects.get(e.field) orelse return error.MissingEditorGeometry;
    h.t.click(rect.x + 1, rect.y + 8);
    try testing.expect(e.focused);
    h.t.time += 2;
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    h.t.typeText("!");
    h.t.time += 2;
    h.t.frame();
    try expectSingleFileWrite(&h, "!original");
    try testing.expectEqualStrings("!original", e.buffer.text());
}

test "file settings Autosave preserves explicit IME insert and unmark of a replacement" {
    for ([_]bool{ false, true }) |commit_by_unmark| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try connect(&h, writable);
        const e = try open(&h);
        h.t.settle(0.2);
        try testing.expect(e.focused);
        h.a.settings.set(.files_autosave_enabled, true);
        h.t.textOps(&.{ .{ .select = .{ .anchor = 6, .caret = 2 } }, .{ .set_marked = .{ .text = "に", .sel_start = 3, .sel_len = 0 } } });
        h.t.textOps(&.{.{ .set_marked = .{ .text = "日本", .sel_start = 6, .sel_len = 0 } }});
        h.t.time += 2;
        h.t.frame();
        try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
        h.t.textOps(&.{if (commit_by_unmark) .unmark else .{ .insert = "日報" }});
        const rect = h.t.ctx.rects.get(e.field) orelse return error.MissingEditorGeometry;
        h.t.click(rect.x + 1, rect.y + 8);
        h.t.time += 2;
        h.t.frame();
        const expected = if (commit_by_unmark) "or日本al" else "or日報al";
        try expectSingleFileWrite(&h, expected);
        try testing.expectEqualStrings(expected, e.buffer.text());
    }
}

test "file settings Autosave retains an IME commit when a new mark in the same event is canceled" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    const e = try open(&h);
    h.t.settle(0.2);
    try testing.expect(e.focused);
    h.a.settings.set(.files_autosave_enabled, true);
    h.t.textOps(&.{.{ .set_marked = .{ .text = "ni", .sel_start = 2, .sel_len = 0 } }});
    h.t.textOps(&.{ .{ .insert = "你" }, .{ .set_marked = .{ .text = "hao", .sel_start = 3, .sel_len = 0 } } });
    h.t.time += 2;
    h.t.frame();
    try testing.expect(e.composing);
    try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    const rect = h.t.ctx.rects.get(e.field) orelse return error.MissingEditorGeometry;
    h.t.click(rect.x + 1, rect.y + 8);
    h.t.textOps(&.{.unmark}); // Unmark with no live mark cannot revive the canceled bytes.
    h.t.time += 2;
    h.t.frame();
    try expectSingleFileWrite(&h, "original你");
    try testing.expectEqualStrings("original你", e.buffer.text());
}

fn expectSingleFileWrite(h: *Harness, expected: []const u8) !void {
    var writes: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.object.get("method").?.string, "WriteWorkspaceFile")) continue;
        writes += 1;
        const params = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings(expected, params.get("text").?.string);
    }
    try testing.expectEqual(@as(usize, 1), writes);
}

const Completion = struct {
    calls: usize = 0,
    fn done(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
    }
    fn callback(self: *@This()) editors.Completion {
        return .{ .ctx = self, .func = done };
    }
};

test "file editor open focuses its buffer without stealing a later composer choice" {
    for ([_]bool{ false, true }) |chose_composer| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try connect(&h, writable);
        h.a.composer.set("preserved composer draft");
        files.openFile(&h.a, "notes.txt");
        const e = h.a.panels.tabs.items[h.a.panels.active].editor.?;
        if (chose_composer) {
            h.a.view.strip.focused = .{ .chat = 0 };
            h.a.view.focus_composer = true;
        }
        _ = h.a.engine.pump();
        h.t.settle(0.2);
        h.press(.{ .key = 'a', .cmd = true });
        h.t.typeText("explicit keyboard edit");
        h.t.settle(0.1);
        if (chose_composer) {
            try testing.expectEqualStrings("original", e.buffer.text());
            try testing.expectEqualStrings("explicit keyboard edit", h.a.composer.text());
        } else {
            try testing.expectEqualStrings("explicit keyboard edit", e.buffer.text());
            try testing.expectEqualStrings("preserved composer draft", h.a.composer.text());
        }
    }
}

test "file editor delayed save ack remains owner revision and target scoped" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    h.a.openChatInTab("b");
    const remote = try open(&h);
    edit(remote, "saved snapshot");
    try testing.expect(remote.save());
    const write_id = remote.save_id.?;
    edit(remote, "later unsaved revision");
    h.a.openChatInTab("a");
    const local = try open(&h); // Also pumps the pending remote ack.
    try testing.expect(remote != local);
    try testing.expect(remote.dirty());
    try testing.expectEqualStrings("later unsaved revision", remote.buffer.text());
    try testing.expectEqualStrings("saved snapshot", remote.baseline);
    try testing.expectEqualStrings("hash-after-save", remote.hash);
    try testing.expect(!local.dirty());
    try testing.expectEqualStrings("original", local.buffer.text());
    var found = false;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("id").?.integer != write_id) continue;
        const params = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings("b", params.get("chatId").?.string);
        try testing.expectEqualStrings("remote", params.get("targetDeviceId").?.string);
        try testing.expectEqualStrings("checkout-original", params.get("expectedCheckoutId").?.string);
        try testing.expectEqualStrings("hash-original", params.get("expectedContentHash").?.string);
        try testing.expectEqualStrings("saved snapshot", params.get("text").?.string);
        found = true;
    }
    try testing.expect(found);
    // Replayed/obsolete acknowledgements cannot clean the newer revision.
    const stale = try std.json.Stringify.valueAlloc(testing.allocator, .{ .id = write_id, .ok = .{ .status = "written", .file = .{ .path = "notes.txt", .contentHash = "stale-hash", .size = 1 } } }, .{});
    defer testing.allocator.free(stale);
    try h.a.engine.mux.dispatch(stale);
    try testing.expect(remote.dirty());
    try testing.expectEqualStrings("hash-after-save", remote.hash);
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "file editor errors conflict and mismatched acknowledgements retain dirty text and content fence" {
    for ([_][]const u8{
        \\{"ReadWorkspaceFile":{"checkoutId":"checkout-original","path":"notes.txt","text":"original","contentHash":"hash-original","size":8,"encoding":"utf8","lineEnding":"lf","truncated":false},"WriteWorkspaceFile":{"$err":"Synthetic disk error"}}
        ,
        \\{"ReadWorkspaceFile":{"checkoutId":"checkout-original","path":"notes.txt","text":"original","contentHash":"hash-original","size":8,"encoding":"utf8","lineEnding":"lf","truncated":false},"WriteWorkspaceFile":{"status":"conflict","reason":"changed","currentContentHash":"external-hash"}}
        ,
        \\{"ReadWorkspaceFile":{"checkoutId":"checkout-original","path":"notes.txt","text":"original","contentHash":"hash-original","size":8,"encoding":"utf8","lineEnding":"lf","truncated":false},"WriteWorkspaceFile":{"status":"written","file":{"path":"different.txt","contentHash":"bad-ack","size":1}}}
    }) |source| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try connect(&h, source);
        const e = try open(&h);
        edit(e, "retain these edits");
        try testing.expect(e.save());
        _ = h.a.engine.pump();
        try testing.expect(e.dirty());
        try testing.expect(e.pending == null);
        try testing.expect(e.error_text != null);
        try testing.expectEqualStrings("retain these edits", e.buffer.text());
        try testing.expectEqualStrings("hash-original", e.hash);
        if (e.conflict) {
            try testing.expect(!e.save()); // No implicit force-save/rebase.
            editors.requestReload(&h.a, e);
            editors.decide(&h.a, .cancel);
            try testing.expectEqualStrings("retain these edits", e.buffer.text());
        }
    }
}

test "file editor dirty close cancel discard and save wait for actual acknowledgement" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    const e = try open(&h);
    edit(e, "first dirty version");
    var completion: Completion = .{};
    try testing.expect(!editors.requestExit(&h.a, .window, completion.callback()));
    editors.decide(&h.a, .cancel);
    try testing.expect(e.dirty());
    try testing.expectEqual(@as(usize, 0), completion.calls);
    try testing.expect(h.a.panels.file_close.intent == null);
    try testing.expect(!editors.requestExit(&h.a, .quit, completion.callback()));
    editors.decide(&h.a, .save);
    try testing.expect(e.pending != null);
    try testing.expectEqual(@as(usize, 0), completion.calls);
    edit(e, "typed while saving");
    _ = h.a.engine.pump();
    try testing.expectEqual(@as(usize, 0), completion.calls);
    try testing.expect(h.a.panels.file_close.intent == .quit);
    editors.decide(&h.a, .save);
    _ = h.a.engine.pump();
    try testing.expectEqual(@as(usize, 1), completion.calls);
    try testing.expect(!e.dirty());
    try testing.expect(h.a.panels.file_close.intent == null);
    edit(e, "discarded version");
    @import("app_panels.zig").closeTab(&h.a, h.a.panels.active);
    try testing.expectEqual(@as(usize, 1), h.a.panels.tabs.items.len);
    editors.decide(&h.a, .cancel);
    try testing.expectEqualStrings("discarded version", e.buffer.text());
    @import("app_panels.zig").closeTab(&h.a, h.a.panels.active);
    const writes = try count(&h, "WriteWorkspaceFile");
    editors.decide(&h.a, .discard);
    try testing.expectEqual(@as(usize, 0), h.a.panels.tabs.items.len);
    try testing.expectEqual(writes, try count(&h, "WriteWorkspaceFile"));
}

test "file editor cancel while save is pending never resumes the canceled exit" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    const e = try open(&h);
    edit(e, "saved but exit canceled");
    var completion: Completion = .{};
    try testing.expect(!editors.requestExit(&h.a, .window, completion.callback()));
    editors.decide(&h.a, .save);
    editors.decide(&h.a, .cancel);
    _ = h.a.engine.pump();
    try testing.expectEqual(@as(usize, 0), completion.calls);
    try testing.expect(h.a.panels.file_close.intent == null);
    try testing.expect(!e.dirty());
}

test "file editor exit reveals each actual dirty owner using preserving navigation" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    const first = try open(&h);
    edit(first, "Alpha dirty file");
    h.a.openChatInTab("b");
    const second = try open(&h);
    edit(second, "Beta dirty file");
    h.a.composer.set("Beta parked composer");
    var completion: Completion = .{};
    try testing.expect(!editors.requestExit(&h.a, .quit, completion.callback()));
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expect(h.a.tabs.find("b") != null);
    try testing.expect(h.a.panels.activeTab().?.editor == first);
    editors.decide(&h.a, .discard);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expect(h.a.panels.activeTab().?.editor == second);
    try testing.expectEqualStrings("Beta parked composer", h.a.composer.text());
    editors.decide(&h.a, .cancel);
    try testing.expect(second.dirty());
    try testing.expectEqual(@as(usize, 0), completion.calls);
    try testing.expect(h.a.tabs.find("a") != null);
    h.a.openChatInTab("a");
    try testing.expect(h.a.panels.activeTab().?.editor == first);
    @import("app_panels.zig").showTab(&h.a, 1);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expect(h.a.panels.activeTab().?.editor == second);
    try testing.expect(h.a.tabs.find("a") != null);
}

test "file editor blank canvas uses explicit space checkout target and returns to its original pane" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    h.a.newTab();
    h.a.select(null, "local-project");
    const e = try open(&h);
    try testing.expect(e.target.chatId == null);
    try testing.expectEqualStrings("local-project", e.target.spaceId.?);
    try testing.expectEqualStrings("/synthetic/fieldnotes", e.target.checkoutPath.?);
    edit(e, "draft file edits");
    h.a.openChatInTab("b");
    const count_before = h.a.tabs.items.items.len;
    var completion: Completion = .{};
    try testing.expect(!editors.requestExit(&h.a, .window, completion.callback()));
    try testing.expect(h.a.selected == null);
    try testing.expectEqual(count_before, h.a.tabs.items.items.len);
    try testing.expect(h.a.tabs.find("b") != null);
    editors.decide(&h.a, .save);
    _ = h.a.engine.pump();
    try testing.expectEqual(@as(usize, 1), completion.calls);
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.object.get("method").?.string, "WriteWorkspaceFile")) continue;
        const params = parsed.value.object.get("params").?.object;
        try testing.expect(params.get("chatId") == null);
        try testing.expectEqualStrings("local-project", params.get("spaceId").?.string);
        try testing.expectEqualStrings("/synthetic/fieldnotes", params.get("checkoutPath").?.string);
    }
}

test "file editor closed blank canvas recovers an owner without replacing surviving chat work" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    h.a.newTab();
    h.a.select(null, "local-project");
    const e = try open(&h);
    edit(e, "orphaned draft file edits");
    h.a.closeTab(h.a.tabs.active);
    h.a.openChatInTab("b");
    h.a.composer.set("surviving Beta draft");
    var completion: Completion = .{};
    try testing.expect(!editors.requestExit(&h.a, .window, completion.callback()));
    try testing.expect(h.a.selected == null);
    try testing.expect(h.a.panels.activeTab().?.editor == e);
    try testing.expectEqualStrings("local-project", e.target.spaceId.?);
    try testing.expect(h.a.tabs.find("b") != null);
    editors.decide(&h.a, .cancel);
    h.a.openChatInTab("b");
    try testing.expectEqualStrings("surviving Beta draft", h.a.composer.text());
    try testing.expectEqualStrings("orphaned draft file edits", e.buffer.text());
}

test "file editor failed save keeps a queued exit blocked until explicit discard" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h,
        \\{"ReadWorkspaceFile":{"checkoutId":"checkout-original","path":"notes.txt","text":"original","contentHash":"hash-original","size":8,"encoding":"utf8","lineEnding":"lf","truncated":false},"WriteWorkspaceFile":{"$err":"Synthetic save failure"}}
    );
    const e = try open(&h);
    edit(e, "must not vanish on failed quit save");
    var completion: Completion = .{};
    try testing.expect(!editors.requestExit(&h.a, .quit, completion.callback()));
    editors.decide(&h.a, .save);
    _ = h.a.engine.pump();
    try testing.expectEqual(@as(usize, 0), completion.calls);
    try testing.expect(e.dirty());
    try testing.expect(h.a.panels.file_close.intent == .quit);
    try testing.expectEqualStrings("must not vanish on failed quit save", e.buffer.text());
    editors.decide(&h.a, .discard);
    try testing.expectEqual(@as(usize, 1), completion.calls);
}

test "file editor late reads stay on their captured owner and never overwrite another active file" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h,
        \\{"ReadWorkspaceFile":{"$seq":[{"checkoutId":"checkout-a","path":"notes.txt","text":"Alpha disk snapshot","contentHash":"hash-a","size":19,"encoding":"utf8","lineEnding":"lf","truncated":false},{"checkoutId":"checkout-b","path":"notes.txt","text":"Beta disk snapshot","contentHash":"hash-b","size":18,"encoding":"utf8","lineEnding":"lf","truncated":false}]}}
    );
    files.openFile(&h.a, "notes.txt");
    const first = h.a.panels.tabs.items[h.a.panels.active].editor.?;
    h.a.openChatInTab("b");
    files.openFile(&h.a, "notes.txt");
    const second = h.a.panels.tabs.items[h.a.panels.active].editor.?;
    try testing.expect(first != second);
    _ = h.a.engine.pump();
    try testing.expectEqualStrings("Alpha disk snapshot", first.buffer.text());
    try testing.expectEqualStrings("Beta disk snapshot", second.buffer.text());
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expect(h.a.panels.activeTab().?.editor == second);
}

test "file editor size truncation metadata and encoded line endings remain fenced" {
    for (0..5) |case| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        const source = try std.json.Stringify.valueAlloc(testing.allocator, .{ .ReadWorkspaceFile = .{
            .checkoutId = if (case == 0) "" else "checkout-original",
            .path = "notes.txt",
            .text = "original",
            .contentHash = if (case == 1) "" else "hash-original",
            .size = if (case == 2) editors.limit + 1 else @as(usize, 8),
            .encoding = "utf8",
            .lineEnding = if (case == 3) "mixed" else "lf",
            .truncated = case == 4,
        } }, .{});
        defer testing.allocator.free(source);
        try connect(&h, source);
        files.openFile(&h.a, "notes.txt");
        _ = h.a.engine.pump();
        const e = h.a.panels.tabs.items[h.a.panels.active].editor.?;
        try testing.expect(!e.editable);
        edit(e, "cannot grant authority by typing");
        try testing.expect(!e.save());
        try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    }
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h,
        \\{"ReadWorkspaceFile":{"checkoutId":"checkout-original","path":"notes.txt","text":"a\nb\n","contentHash":"hash-original","size":9,"encoding":"utf8Bom","lineEnding":"crlf","truncated":false},"WriteWorkspaceFile":{"status":"written","file":{"path":"notes.txt","contentHash":"new-bom-crlf-hash","size":8}}}
    );
    const e = try open(&h);
    edit(e, "new\n");
    try testing.expect(e.save());
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.object.get("method").?.string, "WriteWorkspaceFile")) continue;
        const params = parsed.value.object.get("params").?.object;
        try testing.expectEqualStrings("utf8Bom", params.get("encoding").?.string);
        try testing.expectEqualStrings("crlf", params.get("lineEnding").?.string);
        try testing.expectEqualStrings("new\n", params.get("text").?.string);
    }
    _ = h.a.engine.pump();
    edit(e, "contains\runsupported newline");
    try testing.expect(!e.save());
    const large = try testing.allocator.alloc(u8, editors.limit);
    defer testing.allocator.free(large);
    @memset(large, 'x');
    edit(e, large); // BOM would take it over the authoritative encoded limit.
    try testing.expect(!e.save());
    try testing.expectEqual(@as(usize, 1), try count(&h, "WriteWorkspaceFile"));
}

test "file editor close modal consumes underlying composer input without submitting or changing drafts" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h, writable);
    const e = try open(&h);
    edit(e, "dirty file remains");
    h.a.composer.set("unsent composer remains");
    var completion: Completion = .{};
    try testing.expect(!editors.requestExit(&h.a, .window, completion.callback()));
    h.t.ctx.focus = h.a.view.composer_id;
    h.t.ctx.input.shortcut = .{ .key = @import("nanoui").ui.Shortcut.enter, .cmd = true };
    h.t.ctx.input.key = .enter;
    h.t.ctx.input.chars = "not a hidden edit";
    try testing.expect(editors.keys(&h.t.ctx, &h.a));
    h.t.frame();
    try testing.expectEqualStrings("unsent composer remains", h.a.composer.text());
    try testing.expectEqualStrings("dirty file remains", e.buffer.text());
    try testing.expectEqual(@as(usize, 0), try count(&h, "QueueCommand"));
    try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    editors.decide(&h.a, .cancel);
}

test "file editor native window close Cancel Discard Save uses real dirty owners and waits for ack" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const nanoui = @import("nanoui");
    const objc = nanoui.objc;
    const ui = nanoui.ui;
    const pool = objc.Pool.push();
    defer pool.pop();
    const Native = struct {
        app: *@import("app.zig").App,
        runtime: nanoui.App,
        window: ?*nanoui.Window = null,
        completed: usize = 0,
        fn draw(a: *@import("app.zig").App, c: *ui.Context) void {
            editors.dialog(c, a, @import("theme.zig").colors(true));
        }
        fn finish(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.completed += 1;
            if (self.window) |window| window.close();
        }
        fn ask(ctx: *anyopaque, _: *nanoui.Window) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return editors.requestExit(self.app, .window, .{ .ctx = self, .func = finish });
        }
        fn closed(ctx: *anyopaque, _: *nanoui.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.window = null;
        }
        fn init(self: *@This(), a: *@import("app.zig").App) !void {
            const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
            self.* = .{ .app = a, .runtime = .{ .gpa = testing.allocator, .io = testing.io, .options = .{ .quit_on_last_window_closed = false }, .nsapp = nsapp, .delegate = nsapp, .flags = .{ .hidden = true } } };
            self.runtime.running = true;
            self.window = try self.runtime.newWindow(.{
                .visible = false,
                .width = 600,
                .height = 400,
                .should_close = .{ .ctx = self, .func = ask },
                .on_close = .{ .ctx = self, .func = closed },
                .content = .{ .view = .init(a, draw) },
            });
        }
        fn deinit(self: *@This()) void {
            if (self.window) |window| window.close();
            nanoui.runFor(0.1);
            self.runtime.running = false;
            self.runtime.windows.deinit(testing.allocator);
        }
    };
    for ([_]editors.Decision{ .cancel, .discard, .save }) |decision| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        try connect(&h, writable);
        const e = try open(&h);
        edit(e, "native dirty owner");
        var native: Native = undefined;
        try native.init(&h.a);
        defer native.deinit();
        try testing.expectEqual(objc.NO, objc.msg(objc.BOOL, native.window.?.nswindow, "isVisible", .{}));
        objc.msg(void, native.window.?.nswindow, "performClose:", .{@as(?objc.Object, null)});
        try testing.expect(native.window != null);
        try testing.expect(!native.runtime.stopping);
        var modal: ui.Tester = undefined;
        try modal.init(testing.allocator, .init(&h.a, Native.draw), .{ .width = 600, .height = 400, .dark = true });
        defer modal.deinit();
        modal.settle(0.2);
        try modal.clickText(switch (decision) {
            .cancel => "Cancel",
            .discard => "Discard changes",
            .save => "Save changes",
        });
        if (decision == .save) {
            try testing.expect(native.window != null);
            try testing.expect(e.pending != null);
            _ = h.a.engine.pump();
        }
        if (decision == .cancel) {
            try testing.expect(native.window != null);
            try testing.expect(e.dirty());
            try testing.expectEqual(@as(usize, 0), native.completed);
        } else {
            try testing.expect(native.window == null);
            try testing.expectEqual(@as(usize, 1), native.completed);
        }
        try testing.expect(!native.runtime.stopping);
    }
}

test "file editor read-only snapshots and invalid paths never gain write authority" {
    for ([_][]const u8{ "binary", "unsupportedEncoding", "mixedLineEndings", "symlink", "tooLarge", "permissionDenied", "notRegularFile" }) |reason| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        const source = try std.json.Stringify.valueAlloc(testing.allocator, .{ .ReadWorkspaceFile = .{
            .checkoutId = "checkout-original",
            .path = "notes.txt",
            .text = "preview only",
            .contentHash = "hash-original",
            .size = 12,
            .encoding = "utf8",
            .lineEnding = "lf",
            .truncated = false,
            .readOnlyReason = reason,
        } }, .{});
        defer testing.allocator.free(source);
        try connect(&h, source);
        files.openFile(&h.a, "notes.txt");
        _ = h.a.engine.pump();
        const e = h.a.panels.tabs.items[h.a.panels.active].editor.?;
        try testing.expect(!e.editable);
        edit(e, "not authorized");
        try testing.expect(!e.save());
        try testing.expectEqual(@as(usize, 0), try count(&h, "WriteWorkspaceFile"));
    }
    for ([_][]const u8{ "", "/absolute", "../escape", "a/../escape", "C:/outside", "a\\..\\outside", "a//b", ".git/config", "a/.GIT/config" }) |path| try testing.expect(!editors.validPath(path));
}
