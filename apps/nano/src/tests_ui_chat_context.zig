//! Synthetic regressions verifying that the active conversation card and Zen
//! footer clearly communicate what session is active and which project/branch/host
//! it runs in — across crowded top tab bars, split panes, and chrome-free full screen.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const chrome = @import("panel_chrome.zig");
const S = ui.Shortcut;
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, dark: bool) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = dark;
        h.a.device_id = try testing.allocator.dupe(u8, "studio");
        try replace(&h.a.devices,
            \\[{"id":"studio","name":"Studio Mac"},{"id":"builder","name":"Build box"}]
        );
        try replace(&h.a.spaces,
            \\[{"id":"fieldnotes","deviceId":"studio","name":"fieldnotes","path":"/work/fieldnotes","gitDetected":true},
            \\ {"id":"harbor","deviceId":"builder","name":"harbor","path":"/work/harbor","gitDetected":true},
            \\ {"id":"sketches","deviceId":"studio","name":"sketches","path":"/work/sketches","gitDetected":false}]
        );
        try replace(&h.a.chats,
            \\[{"id":"cedar","deviceId":"studio","title":"Cedar layout audit for desktop shell","spaceId":"fieldnotes","cwd":"/work/fieldnotes/.graff/worktrees/cedar-wt","branch":"feat/context-bar","archived":false,"lastMessageAt":"2026-11-24T06:00:00Z"},
            \\ {"id":"rowan","deviceId":"builder","title":"Rowan palette review","spaceId":"harbor","cwd":"/work/harbor","branch":"main","archived":false,"lastMessageAt":"2026-11-24T05:50:00Z"},
            \\ {"id":"birch","deviceId":"studio","title":"Birch onboarding polish","spaceId":"fieldnotes","cwd":"/work/fieldnotes","branch":"fix/onboarding","archived":false,"lastMessageAt":"2026-11-24T05:40:00Z"},
            \\ {"id":"maple","deviceId":"studio","title":"Maple composer alignment","spaceId":"fieldnotes","cwd":"/work/fieldnotes","branch":"feat/composer","archived":false,"lastMessageAt":"2026-11-24T05:30:00Z"},
            \\ {"id":"alder","deviceId":"studio","title":"Alder scroll follow-up","spaceId":"harbor","cwd":"/work/harbor","branch":"feat/scroll","archived":false,"lastMessageAt":"2026-11-24T05:20:00Z"},
            \\ {"id":"willow","deviceId":"studio","title":"Willow attachment strip","spaceId":"fieldnotes","cwd":"/work/fieldnotes","branch":"feat/attachments","archived":false,"lastMessageAt":"2026-11-24T05:10:00Z"},
            \\ {"id":"note","deviceId":"studio","title":"Plain studio sketch","spaceId":"sketches","cwd":"/work/sketches","branch":"main","archived":false,"lastMessageAt":"2026-11-24T05:00:00Z"}]
        );
        h.a.openChat("cedar", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = dark });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
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

fn seedTranscript(h: *Harness) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[
        \\ {"id":"m1","role":"user","parts":[{"kind":"text","text":"Keep full project, chat title, and branch context visible inside the card even with 6 tabs or full screen."}]},
        \\ {"id":"m2","role":"assistant","parts":[{"kind":"text","text":"The quiet 32pt session header displays the project folder, full conversation title, and git branch at the top of the card, while Zen footer fills in the matching project + branch breadcrumb beside the composer."}]}
        \\]}
    , .{});
    defer parsed.deinit();
    try h.a.transcript.apply(parsed.value);
}

test "Zen mode shows full project, chat title, and git branch inside the card and footer with 6 collapsed-sidebar tabs" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    h.a.view.sidebar_open = false;
    for ([_][]const u8{ "rowan", "birch", "maple", "alder", "willow" }) |id| {
        h.a.newWorkspaceSession();
        h.a.openChat(id, null);
    }
    h.a.showTab(0);
    try testing.expectEqualStrings("cedar", h.a.selected.?);
    try testing.expectEqual(@as(usize, 6), h.a.tabs.items.items.len);
    try seedTranscript(&h);
    h.t.settle(1);

    const card_top = h.a.view.chrome.y;
    const pill = h.a.view.composer_anchor orelse return error.MissingComposer;

    // Context header inside card (below header_height, within the first 32pt of card).
    const hdr_proj = h.t.findText("fieldnotes") orelse return error.MissingHeaderProject;
    try testing.expect(hdr_proj.y >= card_top and hdr_proj.y + hdr_proj.h <= card_top + 32);
    const hdr_title = h.t.findText("Cedar layout audit for desktop shell") orelse return error.MissingHeaderTitle;
    try testing.expect(hdr_title.y >= card_top and hdr_title.y + hdr_title.h <= card_top + 32);
    const hdr_branch = h.t.findText("feat/context-bar") orelse return error.MissingHeaderBranch;
    try testing.expect(hdr_branch.y >= card_top and hdr_branch.y + hdr_branch.h <= card_top + 32);
    // Zen footer breadcrumb sits under the composer pill.
    var footer_proj = false;
    var footer_branch = false;
    for (h.t.ctx.nodes.items) |node| {
        if (node.content != .text) continue;
        if (node.rect.y < pill.y + pill.h) continue;
        if (std.mem.eql(u8, node.content.text.str, "fieldnotes")) footer_proj = true;
        if (std.mem.eql(u8, node.content.text.str, "feat/context-bar")) footer_branch = true;
    }
    try testing.expect(footer_proj and footer_branch);
    h.snap("context-after-zen-light");
}

test "minimal full screen keeps project, chat title, branch, host, and clickable Cmd+K button inside the header" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try seedTranscript(&h);
    h.a.setFullScreen(true);
    h.t.settle(1);

    const kbd = if (comptime builtin.os.tag == .macos) "\u{2318}K" else "Ctrl+K";
    try testing.expectEqual(@as(f32, chrome.fs_top_inset), h.a.view.chrome.y);
    try testing.expect(h.t.hasText("fieldnotes"));
    try testing.expect(h.t.hasText("Cedar layout audit for desktop shell"));
    try testing.expect(h.t.hasText("feat/context-bar"));
    try testing.expect(h.t.hasText("Studio Mac"));
    try testing.expect(h.t.hasText(kbd));
    h.snap("context-after-fullscreen");

    // Clicking the header Cmd+K pill opens the command palette directly.
    try testing.expect(!h.a.view.palette.open);
    try h.t.clickText(kbd);
    h.t.settle(1);
    try testing.expect(h.a.view.palette.open);
    _ = h.t.shortcut(.{ .key = S.escape });
    h.t.settle(1);
}

test "split panes display each pane's own project and title in minimal full screen" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.openChat("rowan", null);
    h.a.setFullScreen(true);
    h.t.settle(1);

    // Left unfocused pane shows cedar (fieldnotes) and right focused pane shows rowan (harbor).
    try testing.expect(h.t.hasText("fieldnotes"));
    try testing.expect(h.t.hasText("Cedar layout audit for desktop shell"));
    try testing.expect(h.t.hasText("harbor"));
    try testing.expect(h.t.hasText("Rowan palette review"));
}

test "non-git projects show folder and title cleanly without leaking git branch text" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.settings.applyUiMode(.zen);
    h.a.openChat("note", null);
    h.t.settle(1);

    try testing.expect(h.t.hasText("sketches"));
    try testing.expect(h.t.hasText("Plain studio sketch"));
    try testing.expect(!h.t.hasText("main"));
    try testing.expect(!h.t.hasText("Local checkout"));
    try testing.expect(!h.t.hasText("Worktree"));
    try testing.expect(!h.t.hasText("No ref"));
}

test "3-pane split draft always exposes clickable folder and computer selectors in narrow Developer and fullscreen Zen modes" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try seedTranscript(&h);
    h.a.view.sidebar_open = false;
    h.a.splitPane(.horizontal);
    h.a.openChat("rowan", null);
    h.a.splitPane(.horizontal);
    h.t.settle(1);

    // Focused 3rd pane is a ~380px draft split off pane 2 ("rowan" on "builder"): developer mode keeps labeled Project and Computer pills reachable.
    try testing.expect(h.t.hasText("No project") or h.t.hasText("harbor"));
    try testing.expect(h.t.hasText("Run on: Build box") or h.t.hasText("Build box"));
    h.snap("browse-narrow-zen-draft");

    // Fullscreen keeps labeled targets both in the 28pt draft header and under the composer when narrow.
    h.a.settings.applyUiMode(.zen);
    h.a.setFullScreen(true);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Build box"));
    try testing.expect(h.t.hasText("No project") or h.t.hasText("harbor"));
    h.snap("browse-fs-draft-targets");
}

test "browse-style Cmd+K switcher previews selected items, splits with Cmd+D, and closes background tabs with Cmd+Backspace" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.openChatInTab("rowan");
    h.a.openChatInTab("note");
    h.a.showTab(0);
    try seedTranscript(&h);
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.tabs.items.items.len);

    _ = h.t.shortcut(.{ .key = 'k', .cmd = true });
    h.t.settle(1);
    try testing.expect(h.a.view.palette.open);
    try testing.expect(h.t.hasText("Open Tabs"));
    try testing.expect(h.t.hasText("3 open"));
    try testing.expect(h.t.hasText("Switch to Tab ↩"));
    try testing.expect(h.t.hasText("Split ⌘D"));
    h.snap("browse-cmdk-preview");

    // Close highlighted open tab with Cmd+Backspace while keeping palette open.
    _ = h.t.shortcut(S.native(.{ .cmd = true, .key = S.backspace }));
    h.t.settle(1);
    try testing.expect(h.a.view.palette.open);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.items.items.len);

    // Split open highlighted tab with Cmd+D.
    _ = h.t.shortcut(S.native(.{ .cmd = true, .key = 'd' }));
    h.t.settle(1);
    try testing.expect(!h.a.view.palette.open);
    try testing.expect(h.a.tabs.layout() != null);
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
}
