//! Native surface payloads through the real Nano view; synthetic files/replies only.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const attachments = @import("app_attachments.zig");

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, split: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = true;
        h.a.account.scope = .local;
        h.a.device_id = try h.a.gpa.dupe(u8, "synthetic-local");
        const chats = try std.json.parseFromSlice(std.json.Value, h.a.gpa,
            \\[ {"id":"drop-a","deviceId":"synthetic-local"},
            \\  {"id":"drop-b","deviceId":"synthetic-remote"},
            \\  {"id":"drop-c","deviceId":"synthetic-local"} ]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("drop-a", null);
        if (split) {
            h.a.splitPane(.horizontal);
            h.a.openChatInTab("drop-b");
            h.a.focusPane(0);
        }
        try h.t.init(h.a.gpa, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn hover(h: *Harness) void {
        h.t.ctx.input.drag_over = .{ .x = 1000, .y = 600 };
        h.t.frame();
    }

    fn release(h: *Harness, urls: []const []const u8) void {
        h.t.ctx.input.drag_over = null;
        h.t.ctx.input.drop = .{ .point = .{ .x = 1000, .y = 600 }, .urls = urls };
        h.t.frame();
    }

    fn snap(h: *Harness, name: []const u8) !void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
        try h.t.screenshot(path);
    }
};

fn dropTargets(a: *App, c: *ui.Context) void {
    const root = ui.div(c).row().sizeFull();
    defer root.end();
    for (0..2) |ix| {
        ui.key(c, c.print("drop-pane-{d}", .{ix}));
        const pane = ui.div(c).grow().hFull();
        defer pane.end();
        @import("view_attachment_drop.zig").target(c, a, pane.index, ix);
    }
}

fn fileUrl(tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "synthetic.png", .data = @embedFile("icons/close.png") });
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/synthetic.png", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const path = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(path);
    // Windows native drops supply absolute paths, not file://C:\\... URLs
    // (which would incorrectly name C: as a remote authority).
    if (@import("builtin").os.tag == .windows) return testing.allocator.dupe(u8, path);
    return std.fmt.allocPrint(testing.allocator, "file://{s}", .{path});
}

// Genuine regressions against v0.2.187: a hover's destination may not silently
// change, and rejected payloads may not switch the active composer.
test "native drop rejects a chat replaced during hover instead of retargeting" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp);
    defer testing.allocator.free(url);
    h.hover();
    h.a.focusPane(1);
    h.a.openChatInTab("drop-c");
    h.a.focusPane(0);
    h.hover();
    h.release(&.{url});
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), h.a.attachments.items.items.len);
    try testing.expectEqualStrings("drop-a", h.a.selected.?);
}

test "native drop empty invalid and oversize payloads never activate another pane" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp);
    defer testing.allocator.free(url);
    const file = try tmp.dir.createFile(testing.io, "synthetic.png", .{});
    try file.setLength(testing.io, attachments.max_bytes + 1);
    file.close(testing.io);
    for ([_][]const []const u8{ &.{""}, &.{"https://example.invalid/image.png"}, &.{"file:///missing-synthetic-drop"}, &.{url} }) |urls| {
        h.t.drop(1000, 600, urls, "");
        h.t.frame();
        try testing.expectEqualStrings("drop-a", h.a.selected.?);
        try testing.expectEqual(@as(usize, 0), h.a.attachments.items.items.len);
    }
}

test "native drop text remains available without attachment error or activation" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.t.drop(1000, 600, &.{}, "Synthetic dragged text");
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), h.a.notice_len);
    try testing.expectEqualStrings("drop-a", h.a.selected.?);
    try testing.expect(h.a.file_drop.pending == null);
}

test "native drop pending release cancels after chat replacement or closed pane" {
    for ([_]bool{ false, true }) |close| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try fileUrl(&tmp);
        defer testing.allocator.free(url);
        // Isolate the release/pre-tree boundary: native intake runs now,
        // but the next view build (and prepare) is deliberately delayed.
        h.t.deinit();
        try h.t.init(h.a.gpa, .init(&h.a, dropTargets), .{ .width = 1200, .height = 780 });
        h.t.frame();
        h.t.drop(1000, 600, &.{url}, "");
        try testing.expect(h.a.file_drop.pending != null);
        h.a.focusPane(1);
        if (close) h.a.closePanel() else h.a.openChatInTab("drop-c");
        @import("view_attachment_drop.zig").prepare(&h.a);
        try testing.expectEqual(@as(usize, 0), h.a.attachments.items.items.len);
        try testing.expect(h.a.file_drop.pending == null);
    }
}

test "native drop activates stable inactive chat and uploads files and images exactly once" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = try fileUrl(&tmp);
    defer testing.allocator.free(url);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, h.a.gpa,
        \\{"UploadChunk":{},"UploadCommit":{"path":"/synthetic/uploads/dropped.png"}}
    , .{});
    h.a.engine.state = .connected;
    h.a.composer.set("Keep the outgoing draft");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "synthetic.txt", .data = "Synthetic dropped file" });
    const text_url = try std.fmt.allocPrint(testing.allocator, "{s}/synthetic.txt", .{std.fs.path.dirname(url) orelse return error.MissingDropParent});
    defer testing.allocator.free(text_url);
    h.t.drop(1000, 600, &.{ url, text_url }, "");
    h.t.frame();
    for (0..20) |_| if (!h.a.engine.pump()) break;
    try testing.expectEqualStrings("drop-b", h.a.selected.?);
    try testing.expectEqual(@as(usize, 2), attachments.count(&h.a));
    try testing.expect(attachments.isImageName(h.a.attachments.items.items[0].name));
    try testing.expect(!attachments.isImageName(h.a.attachments.items.items[1].name));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings("drop-b", item.owner);
    try testing.expectEqualStrings("synthetic-remote", item.target.?);
    try testing.expect(item.status == .ready);
    try testing.expectEqualStrings("/synthetic/uploads/dropped.png", item.path.?);
    try testing.expectEqual(@as(usize, 0), h.a.pending_sends.items.len);
    h.t.frame();
    try testing.expectEqual(@as(usize, 2), h.a.attachments.items.items.len);
    var chunks: usize = 0;
    var commits: usize = 0;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, h.a.gpa, frame, .{});
        defer parsed.deinit();
        const method = parsed.value.object.get("method").?.string;
        if (std.mem.eql(u8, method, "UploadChunk")) chunks += 1;
        if (std.mem.eql(u8, method, "UploadCommit")) commits += 1;
    }
    try testing.expectEqual(@as(usize, 2), chunks);
    try testing.expectEqual(@as(usize, 2), commits);
    h.a.focusPane(0);
    try testing.expectEqualStrings("Keep the outgoing draft", h.a.composer.text());
    try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
}

test "native drop cancelled hover cannot attach after pane close or resize" {
    for ([_]bool{ false, true }) |close| {
        var h: Harness = undefined;
        try h.init(true);
        defer h.deinit();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try fileUrl(&tmp);
        defer testing.allocator.free(url);
        h.hover();
        if (close) {
            h.a.focusPane(1);
            h.a.closePanel();
        } else {
            h.a.tabs.layout().?.shares.items[0] = 0.6;
            h.a.tabs.layout().?.shares.items[1] = 0.4;
        }
        h.hover();
        h.release(&.{url});
        h.t.frame();
        try testing.expectEqual(@as(usize, 0), h.a.attachments.items.items.len);
        // A genuine exit ends cancellation. A fresh drag may attach.
        h.t.ctx.input.drag_over = null;
        h.t.frame();
        h.t.drop(1000, 600, &.{url}, "");
        h.t.frame();
        try testing.expectEqual(@as(usize, 1), h.a.attachments.items.items.len);
    }
}

test "macos pasteboard file-reference NSURL resolves identically to picker intake (#43)" {
    if (comptime @import("builtin").os.tag != .macos) return;
    const objc = @import("nanoui").objc;
    const pool = objc.Pool.push();
    defer pool.pop();

    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.dark = false;
    h.a.view.setup_checked = true;
    h.t.settle(0.3);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const expected_bytes = @embedFile("icons/close.png");
    const filename = "synthetic #✓.png";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = filename, .data = expected_bytes });
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, filename });
    defer testing.allocator.free(relative);
    const native_path = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(native_path);

    const file_url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(native_path)});
    const ref_url = objc.msg(?objc.Object, file_url, "fileReferenceURL", .{}) orelse return error.MissingFileReferenceUrl;
    try testing.expect(objc.msg(objc.BOOL, ref_url, "isFileReferenceURL", .{}));
    const raw_ref = objc.fromNSString(objc.msg(?objc.Object, ref_url, "absoluteString", .{}));
    try testing.expect(std.mem.startsWith(u8, raw_ref, "file:///.file/id="));

    // Write the real macOS file-reference NSURL to a private unique pasteboard
    // and read it back through nanoui's exact AppKit drop adapter.
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "pasteboardWithUniqueName", .{});
    defer objc.msg(void, pb, "releaseGlobally", .{});
    const objs = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{ref_url});
    try testing.expect(objc.msg(objc.BOOL, pb, "writeObjects:", .{objs}));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dropped_urls = ui.surface_drop.readPasteboardUrls(arena.allocator(), pb);
    try testing.expectEqual(@as(usize, 1), dropped_urls.len);

    // Compare against the NSOpenPanel picker path (NSURL.path -> readFile).
    const picker_path = objc.fromNSString(objc.msg(?objc.Object, ref_url, "path", .{}));
    const picker_bytes = try attachments.readFile(&h.a, picker_path);
    defer testing.allocator.free(picker_bytes);
    try testing.expectEqualSlices(u8, expected_bytes, picker_bytes);

    h.t.drop(800, 600, dropped_urls, "");
    h.t.settle(0.3);
    try h.snap("file-ref-drop-composer");

    try testing.expectEqual(@as(usize, 0), h.a.notice_len);
    try testing.expect(h.a.file_drop.last_failure == null);
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings(filename, item.name);
    try testing.expectEqualSlices(u8, picker_bytes, item.bytes);
}

test "macos pasteboard mixed batch attaches valid file-reference into inactive pane and classifies rejected references (#43)" {
    if (comptime @import("builtin").os.tag != .macos) return;
    const objc = @import("nanoui").objc;
    const drop = @import("view_attachment_drop.zig");
    const pool = objc.Pool.push();
    defer pool.pop();

    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const valid_name = "notes #✓.txt";
    const valid_bytes = "Synthetic file-reference attachment bytes\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = valid_name, .data = valid_bytes });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "deleted.txt", .data = "gone" });

    const rel_valid = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, valid_name });
    defer testing.allocator.free(rel_valid);
    const abs_valid = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, rel_valid, testing.allocator);
    defer testing.allocator.free(abs_valid);
    const rel_deleted = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/deleted.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_deleted);
    const abs_deleted = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, rel_deleted, testing.allocator);
    defer testing.allocator.free(abs_deleted);

    const valid_url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(abs_valid)});
    const valid_ref = objc.msg(?objc.Object, valid_url, "fileReferenceURL", .{}) orelse return error.MissingFileReferenceUrl;
    const deleted_url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(abs_deleted)});
    const deleted_ref = objc.msg(?objc.Object, deleted_url, "fileReferenceURL", .{}) orelse return error.MissingFileReferenceUrl;
    try tmp.dir.deleteFile(testing.io, "deleted.txt");
    const remote_file = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString("file://remote/tmp/a.png")}) orelse return error.InvalidUrl;

    // 1. Rejected-only unresolved reference never activates the inactive pane.
    {
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "pasteboardWithUniqueName", .{});
        defer objc.msg(void, pb, "releaseGlobally", .{});
        const list = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{deleted_ref});
        try testing.expect(objc.msg(objc.BOOL, pb, "writeObjects:", .{list}));
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const urls = ui.surface_drop.readPasteboardUrls(arena.allocator(), pb);
        h.t.drop(1000, 600, urls, "");
        h.t.frame();
        try testing.expectEqualStrings("drop-a", h.a.selected.?);
        try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
        try testing.expectEqual(@as(?drop.FailureKind, .url_resolution), h.a.file_drop.last_failure);
        const notice = h.a.noticeText() orelse return error.MissingNotice;
        try testing.expectEqualStrings(drop.failureNotice(.url_resolution), notice);
        try testing.expect(std.mem.indexOf(u8, notice, "/.file/id=") == null);
    }

    // 2. Mixed batch attaches the valid file-reference into drop-b while keeping
    //    rejected items out and recording the resolution failure without leaking paths.
    {
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "pasteboardWithUniqueName", .{});
        defer objc.msg(void, pb, "releaseGlobally", .{});
        const list = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, 3)});
        objc.msg(void, list, "addObject:", .{remote_file});
        objc.msg(void, list, "addObject:", .{valid_ref});
        objc.msg(void, list, "addObject:", .{deleted_ref});
        try testing.expect(objc.msg(objc.BOOL, pb, "writeObjects:", .{list}));
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const urls = ui.surface_drop.readPasteboardUrls(arena.allocator(), pb);
        h.t.drop(1000, 600, urls, "");
        h.t.frame();
        try testing.expectEqualStrings("drop-b", h.a.selected.?);
        try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
        const item = h.a.attachments.items.items[0];
        try testing.expectEqualStrings(valid_name, item.name);
        try testing.expectEqualStrings("synthetic-remote", item.target.?);
        try testing.expectEqualSlices(u8, valid_bytes, item.bytes);
        try testing.expectEqual(@as(?drop.FailureKind, .url_resolution), h.a.file_drop.last_failure);
        const notice = h.a.noticeText() orelse return error.MissingNotice;
        try testing.expect(std.mem.indexOf(u8, notice, "/.file/id=") == null);
        try testing.expect(std.mem.indexOf(u8, notice, abs_valid) == null);
    }
}

test "native drop distinguishes url resolution, missing, directory, empty, and oversize failures without leaking paths (#43)" {
    const drop = @import("view_attachment_drop.zig");
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(rel_dir);
    const abs_dir = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, rel_dir, testing.allocator);
    defer testing.allocator.free(abs_dir);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.txt", .data = "" });
    const empty_path = try std.fs.path.join(testing.allocator, &.{ abs_dir, "empty.txt" });
    defer testing.allocator.free(empty_path);

    const big_file = try tmp.dir.createFile(testing.io, "oversize.bin", .{});
    try big_file.setLength(testing.io, attachments.max_bytes + 1);
    big_file.close(testing.io);
    const oversize_path = try std.fs.path.join(testing.allocator, &.{ abs_dir, "oversize.bin" });
    defer testing.allocator.free(oversize_path);

    const missing_path = try std.fs.path.join(testing.allocator, &.{ abs_dir, "missing-file.txt" });
    defer testing.allocator.free(missing_path);

    const cases = [_]struct { url: []const u8, kind: drop.FailureKind }{
        .{ .url = "https://example.invalid/image.png", .kind = .not_local_file },
        .{ .url = "file:///.file/id=6571367.999999", .kind = .url_resolution },
        .{ .url = missing_path, .kind = .unreadable_file },
        .{ .url = abs_dir, .kind = .is_directory },
        .{ .url = empty_path, .kind = .empty_file },
        .{ .url = oversize_path, .kind = .oversize_file },
    };

    for (cases, 0..) |case, i| {
        h.t.drop(1000, 600, &.{case.url}, "");
        h.t.frame();
        try testing.expectEqualStrings("drop-a", h.a.selected.?);
        try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
        try testing.expectEqual(@as(?drop.FailureKind, case.kind), h.a.file_drop.last_failure);
        const notice = h.a.noticeText() orelse return error.MissingNotice;
        try testing.expectEqualStrings(drop.failureNotice(case.kind), notice);
        try testing.expect(std.mem.indexOf(u8, notice, abs_dir) == null);
        try testing.expect(std.mem.indexOf(u8, notice, "6571367") == null);
        for (cases[0..i]) |prev| {
            try testing.expect(!std.mem.eql(u8, drop.failureNotice(prev.kind), notice));
        }
    }
    try testing.expectEqual(drop.FailureKind.permission_denied, drop.classifyReadError(error.AccessDenied));
    try testing.expect(!std.mem.eql(u8, drop.failureNotice(.permission_denied), drop.failureNotice(.unreadable_file)));
}

test "macos transient file drops deleted before next frame attach from eager drop payload (#97)" {
    if (comptime @import("builtin").os.tag != .macos) return;
    const objc = @import("nanoui").objc;
    const pool = objc.Pool.push();
    defer pool.pop();

    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const expected_bytes = @embedFile("icons/close.png");
    const filename = "telegram-transient.png";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = filename, .data = expected_bytes });
    const rel = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, filename });
    defer testing.allocator.free(rel);
    const native_path = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, rel, testing.allocator);
    defer testing.allocator.free(native_path);

    const file_url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(native_path)});
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "pasteboardWithUniqueName", .{});
    defer objc.msg(void, pb, "releaseGlobally", .{});
    const objs = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{file_url});
    try testing.expect(objc.msg(objc.BOOL, pb, "writeObjects:", .{objs}));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const payload = ui.surface_drop.readPasteboardDrop(arena.allocator(), testing.io, pb);
    // Simulate a chat app removing or revoking its temporary drag file immediately after drop.
    try tmp.dir.deleteFile(testing.io, filename);

    h.t.ctx.input.drag_over = .{ .x = 800, .y = 600 };
    h.t.frame();
    h.t.ctx.input.drag_over = null;
    h.t.ctx.input.drop = .{ .point = .{ .x = 800, .y = 600 }, .urls = payload.urls, .files = payload.files };
    h.t.settle(0.3);

    try testing.expectEqual(@as(usize, 0), h.a.notice_len);
    try testing.expect(h.a.file_drop.last_failure == null);
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings(filename, item.name);
    try testing.expectEqualSlices(u8, expected_bytes, item.bytes);
}

test "macos pasteboard PNG and TIFF fallback rescues drops whose local file path is missing (#97)" {
    if (comptime @import("builtin").os.tag != .macos) return;
    const objc = @import("nanoui").objc;
    const pool = objc.Pool.push();
    defer pool.pop();

    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();

    const png_bytes = @embedFile("icons/close.png");
    const bogus_url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString("/nonexistent/telegram/temp-photo.png")});
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "pasteboardWithUniqueName", .{});
    defer objc.msg(void, pb, "releaseGlobally", .{});
    const objs = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{bogus_url});
    try testing.expect(objc.msg(objc.BOOL, pb, "writeObjects:", .{objs}));
    const data = objc.msg(?objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{
        @as(*const anyopaque, png_bytes.ptr), @as(objc.NSUInteger, png_bytes.len),
    }) orelse return error.MissingNSData;
    try testing.expect(objc.msg(objc.BOOL, pb, "setData:forType:", .{ data, objc.nsString("public.png") }));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const payload = ui.surface_drop.readPasteboardDrop(arena.allocator(), testing.io, pb);
    h.t.ctx.input.drag_over = .{ .x = 800, .y = 600 };
    h.t.frame();
    h.t.ctx.input.drag_over = null;
    h.t.ctx.input.drop = .{ .point = .{ .x = 800, .y = 600 }, .urls = payload.urls, .files = payload.files };
    h.t.settle(0.3);

    try testing.expectEqual(@as(usize, 0), h.a.notice_len);
    try testing.expect(h.a.file_drop.last_failure == null);
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings("temp-photo.png", item.name);
    try testing.expectEqualSlices(u8, png_bytes, item.bytes);
}
