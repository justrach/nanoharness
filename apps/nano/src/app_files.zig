//! The file explorer's calls (crates/ui/src/files/*): the chat's checkout
//! listed a folder at a time as folders open (`ListWorkspaceDirectory`,
//! gitignored files left out unless "show all" is on), git's view of each
//! file for its colour (`WatchWorkspaceGitStatus`), and an opened file read
//! into a tab (`ReadWorkspaceFile`).
const std = @import("std");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const panels = @import("app_panels.zig");
const App = @import("app.zig").App;

fn host(a: *const App) ?[]const u8 {
    const id = a.selected orelse return null;
    const dev = (a.findChat(id) orelse return null).device_id orelse return null;
    if (a.device_id) |mine| if (std.mem.eql(u8, mine, dev)) return null;
    return dev;
}

pub fn toggle(a: *App) void {
    a.panels.files_open = !a.panels.files_open;
    if (a.panels.files_open) open(a);
    a.redraw();
}

/// Lists the root and watches git, unless they are already.
pub fn open(a: *App) void {
    const p = &a.panels;
    syncVisibility(a);
    listExpanded(a);
    if (p.search_id == null and query(a).len != 0) search(a);
    if (p.w_git == null) {
        const chat = a.findChat(a.selected orelse return) orelse return;
        if (chat.space_id) |sid| if (chat.cwd) |dir| {
            p.w_git = a.send_(requests.watchGit(sid, dir, host(a)), .of(App, a, onGit));
        };
    }
}

/// Opens or shuts a folder; its entries are listed the first time.
pub fn toggleDir(a: *App, path: []const u8) void {
    const p = &a.panels;
    p.selected = (p.arena.allocator().dupe(u8, path) catch return);
    if (p.expanded.remove(path)) return a.redraw();
    const key = p.arena.allocator().dupe(u8, path) catch return;
    p.expanded.put(p.gpa, key, {}) catch return;
    if (!p.listings.contains(path)) list(a, key);
    a.redraw();
}

/// The Files pane's eye and Settings control the same preference.
pub fn setShowAll(a: *App, on: bool) void {
    a.settings.set(.files_show_all, on);
    syncVisibility(a);
    a.redraw();
}

/// Invalidate requests as well as results: an old reply must not restore
/// entries from the previous visibility mode.
pub fn syncVisibility(a: *App) void {
    const p = &a.panels;
    const show_all = a.settings.get(.files_show_all);
    if (p.listed_show_all == show_all) return;
    p.listed_show_all = show_all;
    resetListings(a);
    resetSearch(a);
    if (p.files_open) {
        listExpanded(a);
        if (query(a).len != 0) search(a);
    }
}

fn listExpanded(a: *App) void {
    const p = &a.panels;
    if (!p.listings.contains("")) list(a, "");
    var it = p.expanded.keyIterator();
    while (it.next()) |k| if (!p.listings.contains(k.*)) list(a, k.*);
}

pub fn resetSearch(a: *App) void {
    a.panels.search_id = null;
    a.panels.searching = false;
    a.panels.results = &.{};
}

pub fn resetListings(a: *App) void {
    const p = &a.panels;
    var pending = p.pending_lists.keyIterator();
    while (pending.next()) |id| a.engine.cancel(id.*);
    p.pending_lists.clearRetainingCapacity();
    p.listings.clearRetainingCapacity();
    a.retireArena(p.listing_arena);
    p.listing_arena = .init(p.gpa);
}

fn list(a: *App, dir: []const u8) void {
    const p = &a.panels;
    if (a.selected == null) return;
    const key = p.listing_arena.allocator().dupe(u8, dir) catch return;
    p.listings.put(p.gpa, key, .{}) catch return;
    requestPage(a, key, p.listings.getPtr(key).?);
}

/// Continue this folder, or retry the request that failed. A stale cursor
/// clears the continuation so a retry starts at the beginning instead.
pub fn loadMore(a: *App, dir: []const u8) void {
    const p = &a.panels;
    if (p.listed_show_all != a.settings.get(.files_show_all)) return;
    const entry = p.listings.getEntry(dir) orelse return;
    const listing = entry.value_ptr;
    if (listing.loading or (listing.next_cursor == null and listing.err == null)) return;
    requestPage(a, entry.key_ptr.*, listing);
    a.redraw();
}

fn requestPage(a: *App, key: []const u8, listing: *panels.Listing) void {
    const p = &a.panels;
    const chat = a.selected orelse return;
    p.pending_lists.ensureUnusedCapacity(p.gpa, 1) catch {
        listing.err = "Couldn't list this folder";
        return;
    };
    const id = a.send_(requests.listDirectoryPage(chat, key, p.listed_show_all, listing.next_cursor, host(a)), .of(App, a, onListed)) orelse {
        listing.err = "Couldn't request this folder";
        return;
    };
    p.pending_lists.putAssumeCapacityNoClobber(id, key);
    listing.loading = true;
    listing.err = null;
}

fn onListed(a: *App, id: u64, r: rpc.Reply) void {
    if (r == .item) return;
    const p = &a.panels;
    const dir = (p.pending_lists.fetchRemove(id) orelse return).value;
    // Settings may have changed since the last frame (whose pump precedes syncVisibility).
    if (p.listed_show_all != a.settings.get(.files_show_all)) return;
    const listing = p.listings.getPtr(dir) orelse return;
    const ar = p.listing_arena.allocator();
    listing.loading = false;
    switch (r) {
        .ok => |v| applyPage(listing, ar, dir, v) catch {
            listing.err = "Couldn't read this folder page";
        },
        .err => |e| {
            if (std.mem.endsWith(u8, e, "; restart listing") or std.mem.endsWith(u8, e, "invalid directory cursor")) {
                listing.next_cursor = null;
            }
            listing.err = ar.dupe(u8, e) catch "Couldn't list this folder";
        },
        .done => listing.err = "Couldn't read this folder page",
        .item => unreachable,
    }
    a.redraw();
}

fn applyPage(listing: *panels.Listing, ar: std.mem.Allocator, dir: []const u8, v: std.json.Value) !void {
    if (v != .object) return error.InvalidDirectoryPage;
    if (str(v.object, "directory")) |actual| if (!std.mem.eql(u8, actual, dir)) return error.InvalidDirectoryPage;
    const entries = v.object.get("entries") orelse return error.InvalidDirectoryPage;
    if (entries != .array) return error.InvalidDirectoryPage;
    const next = if (v.object.get("nextCursor")) |cursor| switch (cursor) {
        .string => cursor.string,
        .null => null,
        else => return error.InvalidDirectoryPage,
    } else null;
    if (next) |cursor| {
        if (cursor.len == 0 or std.mem.eql(u8, cursor, listing.next_cursor orelse "")) return error.InvalidDirectoryPage;
    }
    const owned_next = if (next) |cursor| try ar.dupe(u8, cursor) else null;
    // A normal continuation appends in engine order. A restart replaces the
    // old snapshot only after a valid first page arrives.
    var fresh: std.ArrayList(panels.Entry) = .empty;
    const out = if (listing.next_cursor != null) &listing.entries else &fresh;
    const old_len = out.items.len;
    errdefer out.items.len = old_len;
    try out.ensureUnusedCapacity(ar, entries.array.items.len);
    for (entries.array.items) |entry| {
        if (entry != .object) return error.InvalidDirectoryPage;
        const o = entry.object;
        const path = str(o, "path") orelse return error.InvalidDirectoryPage;
        out.appendAssumeCapacity(.{
            .path = try ar.dupe(u8, path),
            .name = try ar.dupe(u8, str(o, "name") orelse std.fs.path.basename(path)),
            .dir = std.mem.eql(u8, str(o, "kind") orelse "", "directory"),
            .ignored = if (o.get("ignored")) |g| g == .bool and g.bool else false,
        });
    }
    if (listing.next_cursor == null) listing.entries = fresh;
    listing.next_cursor = owned_next;
    listing.truncated = if (v.object.get("truncated")) |t| t == .bool and t.bool else false;
}

fn onGit(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.panels;
    if (p.w_git != id) return;
    switch (r) {
        .item => |v| {
            p.git.clearRetainingCapacity();
            const st = if (v == .object) v.object.get("status") else null;
            const fs = if (st) |s| (if (s == .object) s.object.get("files") else null) else null;
            if (fs) |f| if (f == .array) for (f.array.items) |x| if (x == .object) {
                const path = str(x.object, "path") orelse continue;
                const kind = gitKind(str(x.object, "worktree") orelse "", str(x.object, "index") orelse "") orelse continue;
                const key = p.arena.allocator().dupe(u8, path) catch continue;
                p.git.put(p.gpa, key, kind) catch {};
            };
        },
        .done, .err => p.w_git = null,
        .ok => {},
    }
    a.redraw();
}

/// Git's colour for a file (`git_status.rs`): added and untracked green,
/// modified amber, renamed accent, deleted and conflicted red.
pub fn gitKind(worktree: []const u8, index: []const u8) ?panels.GitKind {
    const eq = std.mem.eql;
    for ([_][]const u8{ worktree, index }) |s| {
        if (eq(u8, s, "deleted") or eq(u8, s, "unmerged")) return .deleted;
    }
    for ([_][]const u8{ worktree, index }) |s| {
        if (eq(u8, s, "modified") or eq(u8, s, "typeChanged")) return .modified;
        if (eq(u8, s, "renamed") or eq(u8, s, "copied")) return .renamed;
        if (eq(u8, s, "added") or eq(u8, s, "untracked")) return .added;
    }
    return null;
}

/// A folder's colour: the most severe of what changed inside it.
pub fn dirKind(a: *const App, dir: []const u8) ?panels.GitKind {
    var worst: ?panels.GitKind = null;
    var it = a.panels.git.iterator();
    while (it.next()) |e| {
        const path = e.key_ptr.*;
        if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir) or path[dir.len] != '/') continue;
        const k = e.value_ptr.*;
        if (worst == null or @backingInt(k) > @backingInt(worst.?)) worst = k;
    }
    return worst;
}

fn query(a: *const App) []const u8 {
    return std.mem.trim(u8, a.panels.search.text(), " ");
}

/// Searches the checkout's file names for what the search box holds.
pub fn search(a: *App) void {
    const p = &a.panels;
    const chat = a.selected orelse return;
    const q = query(a);
    resetSearch(a);
    if (q.len != 0) {
        p.search_id = a.send_(requests.searchFiles(chat, q, a.settings.get(.files_show_all), host(a)), .of(App, a, onSearched));
        p.searching = p.search_id != null;
    }
    a.redraw();
}

fn onSearched(a: *App, id: u64, r: rpc.Reply) void {
    const p = &a.panels;
    if (p.search_id != id) return;
    p.searching = false;
    const ar = p.arena.allocator();
    var out: std.ArrayList(panels.Entry) = .empty;
    switch (r) {
        .ok => |v| if (v == .array) for (v.array.items) |x| if (x == .object) {
            const o = x.object;
            const path = str(o, "path") orelse continue;
            out.append(ar, .{
                .path = ar.dupe(u8, path) catch continue,
                .name = ar.dupe(u8, str(o, "name") orelse std.fs.path.basename(path)) catch continue,
                .dir = std.mem.eql(u8, str(o, "kind") orelse "", "directory"),
                .ignored = false,
            }) catch {};
        },
        else => {},
    }
    p.results = out.items;
    a.redraw();
}

/// Opens `path` in a file tab (or the tab already showing it).
pub fn openFile(a: *App, path: []const u8) void {
    const p = &a.panels;
    p.selected = p.arena.allocator().dupe(u8, path) catch null;
    a.view.strip.focused = .host;
    if (a.view.strip.expanded != null) a.view.strip.expanded = .host;
    for (p.tabs.items, 0..) |t, i| if (t.kind == .file and std.mem.eql(u8, t.path, path) and (if (t.editor) |e| e.matchesCurrent(a) else false)) {
        p.host_open = true;
        return panels.showTab(a, i);
    };
    const editor = @import("app_file_editor.zig").Editor.create(a, path) catch return a.setNotice("This file has no available workspace owner or valid relative path.");
    const copy = p.gpa.dupe(u8, path) catch return editor.destroy();
    p.tabs.append(p.gpa, .{ .kind = .file, .path = copy, .editor = editor }) catch {
        p.gpa.free(copy);
        return editor.destroy();
    };
    p.host_open = true;
    panels.showTab(a, p.tabs.items.len - 1);
}

pub fn read(a: *App, path: []const u8) void {
    const p = &a.panels;
    if (p.active >= p.tabs.items.len) return;
    const tab = &p.tabs.items[p.active];
    if (tab.kind != .file or !std.mem.eql(u8, tab.path, path)) return;
    if (tab.editor == null) tab.editor = @import("app_file_editor.zig").Editor.create(a, path) catch return;
    const editor = tab.editor.?;
    if (!editor.belongsTo(a.selected)) return;
    // A retained editor is not re-read (and never reset) on chat/tab focus.
    if (editor.loading and editor.read_id == null) editor.read();
}

fn onRead(a: *App, _: u64, r: rpc.Reply) void {
    const p = &a.panels;
    const ar = p.arena.allocator();
    p.file = .{ .loading = false };
    switch (r) {
        .ok => |v| if (v == .object) {
            const o = v.object;
            if (str(o, "text")) |t| p.file.text = ar.dupe(u8, t) catch null;
            if (p.file.text == null) p.file.reason = switch (reasonOf(str(o, "readOnlyReason") orelse str(o, "encoding") orelse "")) {
                .binary => "Binary files cannot be previewed.",
                .large => "This file is too large to preview.",
                .other => "This file can't be shown.",
            };
        },
        .err => |e| p.file.reason = ar.dupe(u8, e) catch "Couldn't read this file",
        else => {},
    }
    a.redraw();
}

fn reasonOf(s: []const u8) enum { binary, large, other } {
    if (std.mem.eql(u8, s, "binary")) return .binary;
    if (std.mem.eql(u8, s, "tooLarge")) return .large;
    return .other;
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;

fn connectFixture(h: *Harness, scene: []const u8) !void {
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, scene, .{});
    h.a.engine.state = .connected;
}

fn expectDirectoryCall(h: *const Harness, start: usize, chat: []const u8, dir: []const u8, show_all: bool, cursor: ?[]const u8, target: ?[]const u8) !u64 {
    var matching: ?u64 = null;
    for (h.a.engine.sent.items[start..]) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const call = parsed.value.object;
        if (!std.mem.eql(u8, str(call, "method") orelse "", "ListWorkspaceDirectory")) continue;
        const params = call.get("params").?.object;
        if (!std.mem.eql(u8, str(params, "directory").?, dir)) continue;
        try testing.expect(matching == null);
        try testing.expectEqualStrings(chat, str(params, "chatId").?);
        try testing.expectEqual(show_all, params.get("includeIgnored").?.bool);
        if (cursor) |s| try testing.expectEqualStrings(s, str(params, "cursor") orelse return error.MissingCursor) else try testing.expect(!params.contains("cursor"));
        if (target) |s| try testing.expectEqualStrings(s, str(params, "targetDeviceId") orelse return error.MissingTarget) else try testing.expect(!params.contains("targetDeviceId"));
        matching = @intCast(call.get("id").?.integer);
    }
    return matching orelse error.MissingDirectoryCall;
}

test "Show all files mounted tree appends the next 500-entry directory page" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var scene: std.Io.Writer.Allocating = .init(testing.allocator);
    defer scene.deinit();
    try scene.writer.writeAll(
        \\{"ListWorkspaceDirectory":{"$seq":[
        \\{"directory":"","entries":[{"path":"z-tracked.txt","name":"z-tracked.txt","kind":"file"}],"truncated":false},
        \\{"directory":"","entries":[
    );
    for (0..500) |i| {
        if (i != 0) try scene.writer.writeByte(',');
        try scene.writer.print(
            \\{{"path":"a-ignored-{d:0>3}.txt","name":"a-ignored-{d:0>3}.txt","kind":"file","ignored":true}}
        , .{ i, i });
    }
    try scene.writer.writeAll(
        \\],"nextCursor":"7b226f6666736574223a3530307d","truncated":false},
        \\{"directory":"","entries":[{"path":"z-tracked.txt","name":"z-tracked.txt","kind":"file"}],"truncated":false}]}}
    );
    try connectFixture(&h, scene.written());
    toggle(&h.a);
    h.t.settle(0.2);
    try testing.expect(h.t.hasText("z-tracked.txt"));

    const first = h.a.engine.sent.items.len;
    h.a.settings.set(.files_show_all, true);
    // The first frame sends the request; the next pumps the fixture reply.
    h.t.advance(0.2);
    _ = try expectDirectoryCall(&h, first, "a", "", true, null, null);
    try testing.expect(!h.t.hasText("z-tracked.txt"));
    const first_page = h.a.panels.listings.get("").?.entries.items;
    try testing.expectEqual(@as(usize, 500), first_page.len);
    try testing.expectEqualStrings("a-ignored-000.txt", first_page[0].path);
    const search_rect = h.t.findText("Search files") orelse return error.MissingFileTree;
    h.t.scroll(search_rect.x + 8, search_rect.y + search_rect.h + 24, -20_000);
    h.t.settle(0.2);
    const more = h.a.engine.sent.items.len;
    try h.t.clickText("Load more");
    h.t.settle(0.2);
    _ = try expectDirectoryCall(&h, more, "a", "", true, "7b226f6666736574223a3530307d", null);
    const entries = h.a.panels.listings.get("").?.entries.items;
    try testing.expectEqual(@as(usize, 501), entries.len);
    try testing.expectEqualStrings("a-ignored-000.txt", entries[0].path);
    try testing.expectEqualStrings("a-ignored-499.txt", entries[499].path);
    try testing.expectEqualStrings("z-tracked.txt", entries[500].path);
    try testing.expect(h.t.hasText("a-ignored-000.txt"));
    try testing.expect(h.t.hasText("a-ignored-499.txt"));
    try testing.expect(h.t.hasText("z-tracked.txt"));
    try testing.expect(!h.t.hasText("Load more"));
}

fn clickPageButton(h: *Harness, label: []const u8) !void {
    for (h.t.ctx.a11y_items.items) |item| {
        if (!std.mem.eql(u8, item.label, label)) continue;
        const r = h.t.ctx.rects.get(item.id) orelse return error.MissingPageButtonGeometry;
        h.t.click(r.x + r.w / 2, r.y + r.h / 2);
        return;
    }
    return error.MissingPageButton;
}

test "directory pages retry and restart locally, and cancel on visibility and chat changes" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connectFixture(&h,
        \\{"ListWorkspaceDirectory":{"$seq":[
        \\{"directory":"","entries":[{"path":"folder","kind":"directory"}],"nextCursor":"root-next"},
        \\{"directory":"folder","entries":[{"path":"folder/first.txt","kind":"file"}],"nextCursor":"folder-next"},
        \\{"$err":"workspace directory listing timed out"},
        \\{"$err":"bad params: directory changed between pages; restart listing"},
        \\{"directory":"folder","entries":[{"path":"folder/fresh.txt","kind":"file"}],"nextCursor":"folder-fresh"},
        \\{"directory":"folder","entries":[{"path":"folder/late-visibility.txt","kind":"file","ignored":true}]},
        \\{"directory":"","entries":[{"path":"folder","kind":"directory"}],"nextCursor":"filtered-root"},
        \\{"directory":"folder","entries":[{"path":"folder/visible.txt","kind":"file"}]},
        \\{"directory":"","entries":[{"path":"late-chat.txt","kind":"file"}]},
        \\{"directory":"","entries":[{"path":"remote-first.txt","kind":"file"}],"nextCursor":"remote-next"},
        \\{"directory":"","entries":[{"path":"remote-last.txt","kind":"file"}],"truncated":true}]}}
    );
    h.a.settings.set(.files_show_all, true);
    toggle(&h.a);
    h.t.settle(0.2);
    try h.t.clickText("folder");
    h.t.settle(0.2);
    try testing.expect(h.t.hasText("first.txt"));

    var start = h.a.engine.sent.items.len;
    try clickPageButton(&h, "Load more in folder");
    h.t.settle(0.2);
    _ = try expectDirectoryCall(&h, start, "a", "folder", true, "folder-next", null);
    try testing.expect(h.t.hasText("first.txt"));
    try testing.expect(h.t.hasText("workspace directory listing timed out"));

    start = h.a.engine.sent.items.len;
    try clickPageButton(&h, "Retry in folder");
    h.t.settle(0.2);
    _ = try expectDirectoryCall(&h, start, "a", "folder", true, "folder-next", null);
    try testing.expect(h.t.hasText("first.txt"));
    try testing.expect(h.t.hasText("Refresh folder"));

    start = h.a.engine.sent.items.len;
    try clickPageButton(&h, "Refresh folder in folder");
    h.t.settle(0.2);
    _ = try expectDirectoryCall(&h, start, "a", "folder", true, null, null);
    try testing.expect(!h.t.hasText("first.txt"));
    try testing.expect(h.t.hasText("fresh.txt"));
    try testing.expectEqualStrings("root-next", h.a.panels.listings.get("").?.next_cursor.?);

    start = h.a.engine.sent.items.len;
    loadMore(&h.a, "folder");
    loadMore(&h.a, "folder"); // Don't send the same cursor again while it is pending.
    const visibility_call = try expectDirectoryCall(&h, start, "a", "folder", true, "folder-fresh", null);
    try testing.expect(h.a.engine.mux.pending.contains(visibility_call));
    start = h.a.engine.sent.items.len;
    setShowAll(&h.a, false);
    try testing.expect(!h.a.engine.mux.pending.contains(visibility_call));
    _ = try expectDirectoryCall(&h, start, "a", "", false, null, null);
    _ = try expectDirectoryCall(&h, start, "a", "folder", false, null, null);
    h.t.settle(0.2);
    try testing.expect(!h.t.hasText("late-visibility.txt"));
    try testing.expect(!h.t.hasText("fresh.txt"));
    try testing.expect(h.t.hasText("visible.txt"));

    start = h.a.engine.sent.items.len;
    loadMore(&h.a, "");
    const old_chat_call = try expectDirectoryCall(&h, start, "a", "", false, "filtered-root", null);
    try testing.expect(h.a.engine.mux.pending.contains(old_chat_call));
    start = h.a.engine.sent.items.len;
    h.a.openChatInTab("b");
    try testing.expect(!h.a.engine.mux.pending.contains(old_chat_call));
    _ = try expectDirectoryCall(&h, start, "b", "", false, null, "remote");
    h.t.settle(0.2);
    try testing.expect(!h.t.hasText("late-chat.txt"));
    try testing.expect(!h.t.hasText("visible.txt"));

    start = h.a.engine.sent.items.len;
    try clickPageButton(&h, "Load more");
    h.t.settle(0.2);
    _ = try expectDirectoryCall(&h, start, "b", "", false, "remote-next", "remote");
    try testing.expect(h.t.hasText("remote-first.txt"));
    try testing.expect(h.t.hasText("remote-last.txt"));
    try testing.expect(h.t.hasText("Directory limit reached"));
    try testing.expect(!h.t.hasText("Load more"));
}

test "git colours, most severe first" {
    try std.testing.expectEqual(panels.GitKind.added, gitKind("untracked", "unchanged").?);
    try std.testing.expectEqual(panels.GitKind.modified, gitKind("modified", "added").?);
    try std.testing.expectEqual(panels.GitKind.deleted, gitKind("unchanged", "unmerged").?);
    try std.testing.expect(gitKind("unchanged", "unchanged") == null);
}
