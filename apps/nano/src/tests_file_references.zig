//! Chat file references (#199, #200, #201): where Open file sends them,
//! what their link menu copies, and what a failed open says. Synthetic
//! chats, paths and host replies only; nothing reads this computer's files.
const std = @import("std");
const testing = std.testing;
const artifacts = @import("artifact_links.zig");
const Harness = @import("tests_ui_tab_strip.zig").Harness;

/// Alpha's chat on `device` in `space`'s `cwd`, showing one assistant reply with
/// `markdown` as its text, against a scripted host.
fn chatOnHost(h: *Harness, device: []const u8, space: []const u8, cwd: []const u8, markdown: []const u8, connected: bool) !void {
    try h.init(false);
    errdefer h.deinit();
    const list = try std.json.Stringify.valueAlloc(testing.allocator, .{.{ .id = "a", .deviceId = device, .cwd = cwd, .spaceId = space, .archived = false }}, .{});
    defer testing.allocator.free(list);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator, list, .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"ReadAttachmentChunk":{"$err":"Synthetic host could not read the file"},
        \\ "ReadWorkspaceFile":{"text":"# Example Notes\n\nSynthetic notes.\n","encoding":"utf-8"}}
    , .{});
    if (connected) h.a.engine.state = .connected;
    const json = try std.json.Stringify.valueAlloc(testing.allocator, .{ .reset = .{.{ .id = "reply", .role = "assistant", .status = "complete", .parts = .{.{ .id = "p", .kind = "text", .text = markdown }} }} }, .{});
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
    h.t.settle(0.3);
}

fn chatWithReply(h: *Harness, markdown: []const u8, connected: bool) !void {
    return chatOnHost(h, "local", "local-project", "/synthetic/fieldnotes", markdown, connected);
}

fn rightClickLabel(h: *Harness, label: []const u8) !void {
    const rect = h.t.findText(label) orelse return error.MissingSyntheticLink;
    h.t.rightClick(rect.x + 8, rect.y + rect.h / 2);
    h.t.settle(0.2);
}

fn openFromMenu(h: *Harness, label: []const u8) !void {
    try rightClickLabel(h, label);
    try h.t.clickText("Open file");
    h.t.settle(0.3);
}

fn fileTab(h: *Harness) ?[]const u8 {
    for (h.a.panels.tabs.items) |tab| if (tab.kind == .file) return tab.path;
    return null;
}

/// The `params` of each request for `method`, as sent.
fn sentParams(h: *Harness, method: []const u8, out: *std.ArrayList(std.json.Parsed(std.json.Value))) !void {
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        if (!std.mem.eql(u8, parsed.value.object.get("method").?.string, method)) {
            parsed.deinit();
            continue;
        }
        try out.append(testing.allocator, parsed);
    }
}

fn countSent(h: *Harness, method: []const u8) !usize {
    var list: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
    defer {
        for (list.items) |p| p.deinit();
        list.deinit(testing.allocator);
    }
    try sentParams(h, method, &list);
    return list.items.len;
}

const media_hint = "Use a video, image, GIF or PDF link";

test "issue 199: Open file on a workspace Markdown reference opens it in Files Preview" {
    for ([_][]const u8{ "Example%20Notes.md", "/synthetic/fieldnotes/Example%20Notes.md", "file:///synthetic/fieldnotes/Example%20Notes.md" }) |destination| {
        var h: Harness = undefined;
        const text = try std.fmt.allocPrint(testing.allocator, "Saved for review:\n\n- **[Example Notes.md]({s})**\n", .{destination});
        defer testing.allocator.free(text);
        try chatWithReply(&h, text, true);
        defer h.deinit();
        try rightClickLabel(&h, "Example Notes.md");
        try testing.expect(h.t.hasText("Open file"));
        try h.t.clickText("Open file");
        h.t.settle(0.3);
        if (h.a.noticeText()) |notice| {
            if (std.mem.indexOf(u8, notice, media_hint) != null) {
                std.debug.print("issue 199: Open file on {s} showed: {s}\n", .{ destination, notice });
                return error.MarkdownRejectedAsMedia;
            }
        }
        const path = fileTab(&h) orelse return error.NoFilesPreviewTab;
        try testing.expect(std.mem.endsWith(u8, path, "Example Notes.md"));
        try testing.expect(h.a.panels.host_open);
    }
}

test "issue 199: Open file reads a workspace document from the chat's own host by its workspace path" {
    var h: Harness = undefined;
    try chatOnHost(&h, "remote", "remote-project", "/synthetic/remote-project", "Saved for review:\n\n- **[Example Notes.md](docs/Example%20Notes.md)**\n", true);
    defer h.deinit();
    try openFromMenu(&h, "Example Notes.md");
    try testing.expectEqualStrings("docs/Example Notes.md", fileTab(&h) orelse return error.NoFilesPreviewTab);
    try testing.expect(h.a.panels.activeTab().?.editor.?.preview);
    var reads: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
    defer {
        for (reads.items) |p| p.deinit();
        reads.deinit(testing.allocator);
    }
    try sentParams(&h, "ReadWorkspaceFile", &reads);
    try testing.expect(reads.items.len > 0);
    for (reads.items) |read| {
        const params = read.value.object.get("params").?.object;
        try testing.expectEqualStrings("docs/Example Notes.md", params.get("path").?.string);
        try testing.expectEqualStrings("a", params.get("chatId").?.string);
        try testing.expectEqualStrings("remote", params.get("targetDeviceId").?.string);
    }
    try testing.expectEqual(@as(usize, 0), try countSent(&h, "ReadAttachmentChunk"));
}

test "issue 199: Open file from a chat in an unfocused split pane opens the document for that chat" {
    const App = @import("app.zig").App;
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.device_id = try a.gpa.dupe(u8, "viewer-device");
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"notes-chat","deviceId":"notes-host","spaceId":"notes-project","cwd":"/synthetic/project","archived":false}]
    , .{});
    defer chats.deinit();
    try a.chats.replace(chats.value);
    a.openChat("notes-chat", null);
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, a.gpa, "{}", .{});
    a.engine.state = .connected;
    a.splitPane(.horizontal);
    // The new pane has focus; the chat holding the reference is its peer.
    try testing.expect(a.selected == null or !std.mem.eql(u8, a.selected.?, "notes-chat"));
    artifacts.openReference(&a, "notes-chat", "docs/Example%20Notes.md");
    try testing.expectEqualStrings("notes-chat", a.selected orelse return error.ChatNotSelected);
    const tab = a.panels.tabs.items[a.panels.active];
    try testing.expectEqualStrings("docs/Example Notes.md", tab.path);
    try testing.expectEqualStrings("notes-chat", tab.editor.?.target.chatId.?);
    try testing.expectEqualStrings("notes-host", tab.editor.?.target.targetDeviceId.?);
}

test "issue 199: a click on a workspace Markdown reference opens it as Open file does" {
    var h: Harness = undefined;
    try chatWithReply(&h, "Saved for review:\n\n- **[Example Notes.md](Example%20Notes.md)**\n", true);
    defer h.deinit();
    const rect = h.t.findText("Example Notes.md") orelse return error.MissingSyntheticLink;
    h.t.click(rect.x + 8, rect.y + rect.h / 2);
    h.t.settle(0.3);
    try testing.expectEqualStrings("Example Notes.md", fileTab(&h) orelse return error.NoFilesPreviewTab);
}

test "issue 199: a document outside the chat's workspace is not opened in Files" {
    for ([_][]const u8{ "../elsewhere/Example%20Notes.md", "/synthetic/elsewhere/Example%20Notes.md", "/synthetic/fieldnotes-copy/Example%20Notes.md" }) |destination| {
        var h: Harness = undefined;
        const text = try std.fmt.allocPrint(testing.allocator, "Saved for review:\n\n- **[Example Notes.md]({s})**\n", .{destination});
        defer testing.allocator.free(text);
        try chatWithReply(&h, text, true);
        defer h.deinit();
        try openFromMenu(&h, "Example Notes.md");
        try testing.expect(fileTab(&h) == null);
        try testing.expectEqual(@as(usize, 0), try countSent(&h, "ReadWorkspaceFile"));
        try testing.expect(h.a.noticeText() != null);
    }
}

test "issue 199: Open file routes media and PDF to the viewer and other workspace files to Files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const files = [_][2][]const u8{
        .{ "/w/Example Notes.md", "Example Notes.md" },
        .{ "/w/docs/notes.markdown", "docs/notes.markdown" },
        .{ "/w/src/main.zig", "src/main.zig" },
        .{ "/w/Example Notes.xyz", "Example Notes.xyz" },
    };
    for (files) |case| {
        switch (artifacts.route(arena.allocator(), "/w", case[0])) {
            .files => |relative| try testing.expectEqualStrings(case[1], relative),
            else => return error.NotRoutedToFiles,
        }
    }
    for ([_][]const u8{ "/w/clip.mp4", "/w/report.PDF", "/uploads/frame.png" }) |path| {
        try testing.expect(artifacts.route(arena.allocator(), "/w", path) == .viewer);
    }
    const failures = [_]struct { []const u8, artifacts.Failure }{
        .{ "/elsewhere/notes.md", .outside_workspace },
        .{ "/wx/notes.md", .outside_workspace },
        .{ "/w", .outside_workspace },
        .{ "/w/.git/config", .unsupported },
    };
    for (failures) |case| switch (artifacts.route(arena.allocator(), "/w", case[0])) {
        .failure => |failure| try testing.expectEqual(case[1], failure),
        else => return error.ExpectedFailure,
    };
}

test "issue 200: a file reference offers Copy file path and copies the decoded plain path" {
    const cases = [_]struct { destination: []const u8, path: []const u8 }{
        .{ .destination = "file:///synthetic/fieldnotes/Example%20Notes.md", .path = "/synthetic/fieldnotes/Example Notes.md" },
        .{ .destination = "Example%20Notes.md", .path = "Example Notes.md" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        const text = try std.fmt.allocPrint(testing.allocator, "Saved for review:\n\n- **[Example Notes.md]({s})**\n", .{case.destination});
        defer testing.allocator.free(text);
        try chatWithReply(&h, text, true);
        defer h.deinit();
        try rightClickLabel(&h, "Example Notes.md");
        try testing.expect(h.t.hasText("Open file"));
        if (!h.t.hasText("Copy file path")) {
            std.debug.print("issue 200: file reference {s} menu has Copy link={}, Copy file path=false\n", .{ case.destination, h.t.hasText("Copy link") });
            return error.MissingCopyFilePath;
        }
        try testing.expect(!h.t.hasText("Copy link"));
        try h.t.clickText("Copy file path");
        h.t.settle(0.2);
        try testing.expectEqualStrings(case.path, h.t.clipboard.items);
    }
}

test "issue 200: a web URL ending in .md keeps Copy link and copies the URL verbatim" {
    // Control for #200: holds on main and must keep holding after the fix.
    const url = "https://example.com/notes.md?view=1";
    var h: Harness = undefined;
    try chatWithReply(&h, "Read first:\n\n- **[Web page](" ++ url ++ ")**\n", true);
    defer h.deinit();
    try rightClickLabel(&h, "Web page");
    try testing.expect(h.t.hasText("Open in browser"));
    try testing.expect(!h.t.hasText("Copy file path"));
    try h.t.clickText("Copy link");
    h.t.settle(0.2);
    try testing.expectEqualStrings(url, h.t.clipboard.items);
}

fn expectNoticeNames(h: *Harness, basename: []const u8) !void {
    const notice = h.a.noticeText() orelse return error.NoNotice;
    if (std.mem.indexOf(u8, notice, basename) == null or std.mem.indexOf(u8, notice, media_hint) != null) {
        std.debug.print("issue 201: notice for {s} was: {s}\n", .{ basename, notice });
        return error.NoticeDoesNotExplainTheFile;
    }
}

test "issue 201: an unsupported file's open notice names the file and suggests no media types" {
    var h: Harness = undefined;
    try chatWithReply(&h, "Saved for review:\n\n- **[Example Notes.xyz](Example%20Notes.xyz)**\n", true);
    defer h.deinit();
    try rightClickLabel(&h, "Example Notes.xyz");
    try h.t.clickText("Open file");
    h.t.settle(0.3);
    // Either Files opens it, or the notice says which file and why.
    if (fileTab(&h) == null) try expectNoticeNames(&h, "Example Notes.xyz");
}

test "issue 201: an offline host's open notice names the file" {
    var h: Harness = undefined;
    try chatWithReply(&h, "Rendered for review:\n\n- **[clip.mp4](artifacts/clip.mp4)**\n", false);
    defer h.deinit();
    try rightClickLabel(&h, "clip.mp4");
    try h.t.clickText("Open file");
    h.t.settle(0.3);
    try expectNoticeNames(&h, "clip.mp4");
}

test "issue 201: a host read failure's notice names the file" {
    var h: Harness = undefined;
    try chatWithReply(&h, "Rendered for review:\n\n- **[clip.mp4](artifacts/clip.mp4)**\n", true);
    defer h.deinit();
    try rightClickLabel(&h, "clip.mp4");
    try h.t.clickText("Open file");
    h.t.settle(0.3);
    try expectNoticeNames(&h, "clip.mp4");
}

test "issue 201: notices name another computer that owns the chat, and a document outside the workspace says so" {
    var h: Harness = undefined;
    try chatOnHost(&h, "remote", "remote-project", "/synthetic/remote-project", "Saved for review:\n\n- **[Example Notes.md](Example%20Notes.md)**\n- **[clip.mp4](clip.mp4)**\n- **[Draft.md](/synthetic/elsewhere/Draft.md)**\n", false);
    defer h.deinit();
    try openFromMenu(&h, "Example Notes.md");
    try testing.expectEqualStrings("Couldn't open “Example Notes.md”: not connected to Build box. Reconnect and try again.", h.a.noticeText().?);
    try testing.expect(fileTab(&h) == null);
    try openFromMenu(&h, "clip.mp4");
    try testing.expectEqualStrings("Couldn't open “clip.mp4”: not connected to Build box. Reconnect and try again.", h.a.noticeText().?);
    h.a.engine.state = .connected;
    try openFromMenu(&h, "Draft.md");
    try testing.expectEqualStrings("Couldn't open “Draft.md”: it's outside this chat's workspace.", h.a.noticeText().?);
    try openFromMenu(&h, "clip.mp4");
    for (0..20) |_| if (!h.a.engine.pump()) break;
    h.t.settle(0.2);
    try testing.expectEqualStrings("Couldn't read “clip.mp4” on Build box.", h.a.noticeText().?);
}

test "issue 201: each open failure names the file, says why, and offers only a remedy that applies" {
    const cases = [_]struct { failure: artifacts.Failure, name: []const u8, host: ?[]const u8, text: []const u8 }{
        .{ .failure = .unsupported, .name = "Example Notes.xyz", .host = null, .text = "Couldn't open “Example Notes.xyz”: this kind of file can't be opened from a chat." },
        .{ .failure = .outside_workspace, .name = "Example Notes.md", .host = null, .text = "Couldn't open “Example Notes.md”: it's outside this chat's workspace." },
        .{ .failure = .offline, .name = "Example Notes.md", .host = null, .text = "Couldn't open “Example Notes.md”: not connected to its host. Reconnect and try again." },
        .{ .failure = .offline, .name = "clip.mp4", .host = "Build box", .text = "Couldn't open “clip.mp4”: not connected to Build box. Reconnect and try again." },
        .{ .failure = .unreadable, .name = "clip.mp4", .host = null, .text = "Couldn't read “clip.mp4” on its host." },
        .{ .failure = .unreadable, .name = "clip.mp4", .host = "Build box", .text = "Couldn't read “clip.mp4” on Build box." },
    };
    var buf: [artifacts.max_notice]u8 = undefined;
    for (cases) |case| {
        const text = artifacts.failureText(&buf, case.failure, case.name, case.host);
        try testing.expectEqualStrings(case.text, text);
        try testing.expect(std.mem.indexOf(u8, text, media_hint) == null);
    }
    // A long name or host is shortened on a character boundary, never cut
    // off the end of the notice.
    const long = "éééééééééééééééééééééééééééééééééééééééé.md";
    for (std.enums.values(artifacts.Failure)) |failure| {
        const text = artifacts.failureText(&buf, failure, long, "Studio of a synthetic workshop with a very long name");
        try testing.expect(std.unicode.utf8ValidateSlice(text));
        try testing.expect(std.mem.indexOf(u8, text, "…") != null);
        try testing.expect(std.mem.endsWith(u8, text, "."));
    }
}
