//! Browser surfaces are conversation-owned, lazy native views. Merely
//! launching nano or opening an empty tab must not start WebKit processes.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const web = @import("browser_url.zig");
const saved = @import("saved_view.zig");
pub const Native = if (builtin.os.tag == .macos) @import("browser_native.zig").Native else void;

const Source = struct { tab: u64, pane: ?u64 = null, pane_index: ?usize = null, project: ?u64 = null };

/// Cached views can precede the first chat snapshot. A known archival or an
/// authoritative deletion revokes navigation immediately, before repaint.
fn source(a: *const App, parent: []const u8) ?Source {
    if (a.view.settings_open or a.view.write_open or a.bots.page != .none) return null;
    const chat = a.findChat(parent);
    if (chat) |ch| {
        if (ch.archived) return null;
    } else if (a.chats_synced) return null;
    if (a.tabs.active >= a.tabs.identities.items.len) return null;
    const identity = a.tabs.identities.items[a.tabs.active];
    var result: Source = .{ .tab = identity.workspace, .pane = identity.pane };
    if (chat) |ch| {
        var hash = std.hash.Wyhash.init(0x4252_4f57_5345_52);
        for ([_]?[]const u8{ ch.space_id, ch.device_id }) |value| {
            hash.update(&.{@intFromBool(value != null)});
            if (value) |text| {
                hash.update(std.mem.asBytes(&text.len));
                hash.update(text);
            }
        }
        result.project = hash.final();
    }
    if (a.tabs.layout()) |split| {
        if (split.focus >= split.panes.items.len) return null;
        // The focused slot is intentionally empty: Tabs owns its live chat.
        const focused = a.tabs.current();
        if (a.selected) |selected| {
            if (focused == null or !std.mem.eql(u8, selected, focused.?)) return null;
        } else if (focused != null) return null;
        for (split.panes.items, 0..) |pane, ix| {
            const id = (if (ix == split.focus) focused else pane) orelse continue;
            if (!std.mem.eql(u8, id, parent) or (split.zoomed and ix != split.focus)) continue;
            if (a.view.strip.expanded) |expanded| {
                if (expanded != .chat or expanded.chat != ix) return null;
            }
            result.pane = split.identities[ix];
            result.pane_index = ix;
            return result;
        }
        return null;
    }
    if (a.view.strip.expanded) |expanded| if (expanded != .chat) return null;
    const selected = a.selected orelse return null;
    const active = a.tabs.current() orelse return null;
    return if (std.mem.eql(u8, selected, parent) and std.mem.eql(u8, active, parent)) result else null;
}

pub const Browser = struct {
    app: *App,
    parent: []u8,
    pending_source: ?Source = null,
    url: []u8 = &.{},
    address: nanoui.ui.TextBuffer = .{},
    title: nanoui.ui.TextBuffer = .{},
    notice: nanoui.ui.TextBuffer = .{},
    saved_view: ?saved.View = null,
    artifact_id: ?[]u8 = null,
    frame_url: ?[]u8 = null,
    native: ?*Native = null,
    zoom: f64 = 1.0,
    body_node: u64 = 0,
    editing: bool = false,
    focus_address: bool = true,

    fn create(a: *App, parent: []const u8) !*Browser {
        const b = try a.gpa.create(Browser);
        errdefer a.gpa.destroy(b);
        b.* = .{ .app = a, .parent = try a.gpa.dupe(u8, parent) };
        b.title.set("Browser");
        return b;
    }

    pub fn destroy(b: *Browser) void {
        @import("text_buffer.zig").deinit(&b.address);
        @import("text_buffer.zig").deinit(&b.title);
        @import("text_buffer.zig").deinit(&b.notice);
        if (comptime builtin.os.tag == .macos) if (b.native) |n| n.destroy();
        const gpa = b.app.gpa;
        if (b.artifact_id) |aid| gpa.free(aid);
        if (b.frame_url) |furl| gpa.free(furl);
        gpa.free(b.parent);
        gpa.free(b.url);
        gpa.destroy(b);
    }

    pub fn usesEmbeddedWebView(b: *const Browser) bool {
        return b.artifact_id != null or @import("ux_rules.zig").BrowseConnect.routeUrl(b.url) == .local_saved_view;
    }

    pub fn belongsTo(b: *const Browser, parent: ?[]const u8) bool {
        const p = parent orelse return false;
        if (std.mem.eql(u8, b.parent, p)) return true;
        if (b.app.selected) |sel| if (std.mem.eql(u8, sel, p)) {
            if (b.app.tabs.layout()) |s| for (s.panes.items) |pane| if (pane) |id| {
                if (std.mem.eql(u8, b.parent, id)) return true;
            };
        };
        return false;
    }

    pub fn navigate(b: *Browser, input: []const u8) void {
        if (b.saved_view != null or b.artifact_id != null or source(b.app, b.parent) == null) return;
        const url = web.normalize(b.app.gpa, input) catch |err| {
            b.notice.set(web.message(err));
            b.app.redraw();
            return;
        };
        b.app.gpa.free(b.url);
        b.url = url;
        b.address.set(url);
        b.notice.clear();
        b.focus_address = false;
        if (b.usesEmbeddedWebView()) {
            if (comptime builtin.os.tag == .macos) if (b.native) |n| n.navigate(b.frame_url orelse b.url);
        } else {
            if (comptime builtin.os.tag == .macos) if (b.native) |n| n.show(false);
            if (b.app.window != null and !b.app.offscreen) {
                const bc = b.app.ensureBrowseClient();
                bc.setSession(b.parent);
                bc.spawnOp(.open_url, b.url, 0, 0);
            }
        }
        b.app.redraw();
    }

    pub fn ensureNative(b: *Browser) void {
        if (comptime builtin.os.tag != .macos) return;
        if (b.native != null or b.url.len == 0 or b.app.window == null) return;
        if (!b.usesEmbeddedWebView()) return;
        const home = if (b.app.env) |env| env.get("HOME") orelse "" else "";
        const n = Native.createWithOptions(b.app.gpa, b.app.io, home, .{ .ctx = b, .changed = nativeChanged }, b.artifact_id != null) catch {
            b.notice.set("The integrated browser could not start.");
            return;
        };
        b.native = n;
        if (b.zoom != 1.0) n.setZoom(b.zoom);
        n.navigate(b.frame_url orelse b.url);
    }

    pub fn applyZoom(b: *Browser, dir: enum { in, out, reset }) void {
        if (comptime builtin.os.tag == .macos) {
            const zdir: Native.ZoomDir = switch (dir) {
                .in => .in,
                .out => .out,
                .reset => .reset,
            };
            b.zoom = Native.nextZoom(b.zoom, zdir);
            if (b.native) |n| n.setZoom(b.zoom);
        }
        b.app.redraw();
    }

    pub fn reload(b: *Browser) void {
        if (comptime builtin.os.tag == .macos) if (b.native) |n| n.reload();
        b.app.redraw();
    }

    fn nativeChanged(ctx: *anyopaque) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        const n = b.native orelse return;
        const title = n.title();
        if (title.len > 0 and b.artifact_id == null) b.title.set(title);
        const url = n.url();
        if (b.saved_view == null and b.artifact_id == null and url.len > 0 and web.allowedNavigation(url) and !std.mem.eql(u8, b.url, url)) {
            if (b.app.gpa.dupe(u8, url)) |owned| {
                b.app.gpa.free(b.url);
                b.url = owned;
            } else |_| {}
        }
        if (!b.editing and b.artifact_id == null and url.len > 0) b.address.set(url);
        if (n.error_len > 0) b.notice.set(n.error_text[0..n.error_len]) else b.notice.clear();
        b.app.redraw();
    }
};

pub const LinkOwner = Source;

/// Shared conversation/pane ownership for non-web artifact actions. It grants
/// no path access; local bytes must still pass the owning host's read jail.
pub fn sourceOwner(a: *const App, parent: []const u8) ?LinkOwner {
    return source(a, parent);
}

pub fn linkOwner(a: *const App, parent: []const u8, url: []const u8) ?LinkOwner {
    if (!web.allowedNavigation(url)) return null;
    return source(a, parent);
}

/// Injectable OS boundary; tests record the destination without opening a browser.
pub var open_external_url: *const fn ([]const u8) bool = nanoui.shell.openUrl;

pub fn openInternalLink(a: *App, parent: []const u8, url: []const u8) void {
    if (linkOwner(a, parent, url) == null) return;
    open(a, parent, url, null);
}

pub fn openExternalLink(a: *App, parent: []const u8, url: []const u8) void {
    if (linkOwner(a, parent, url) == null) return;
    _ = open_external_url(url);
}

/// Transcript links are explicit HTTP(S), not address-bar guesses. A bad
/// link never falls through to an OS opener or a privileged URL scheme.
pub fn openLink(a: *App, parent: []const u8, url: []const u8) void {
    if (linkOwner(a, parent, url) == null) return;
    // Honor the GitHub preference before the test/offscreen browser fallback.
    // Explicit internal/external actions bypass this default dispatcher.
    if (@import("github_link.zig").parse(url) != null) {
        if (a.settings.get(.open_github_links_in_harness)) return openInternalLink(a, parent, url);
        return openExternalLink(a, parent, url);
    }
    if (!builtin.is_test and a.window != null and !a.offscreen) {
        openExternalLink(a, parent, url);
        return;
    }
    openInternalLink(a, parent, url);
}

pub fn openBlank(a: *App) void {
    open(a, a.selected orelse return, null, null);
}

pub fn openSaved(a: *App, parent: []const u8, view: saved.View) void {
    const chat = a.findChat(parent) orelse return a.setNotice("This view's host is not known yet.");
    const local = a.device_id orelse return a.setNotice("This view's host is not known yet.");
    const host = chat.device_id orelse return a.setNotice("This view's host is not known yet.");
    if (!std.mem.eql(u8, local, host)) return a.setNotice("This view is saved on another computer. Open it there.");
    open(a, parent, null, view);
}

/// Opens a hosted CodeGraff artifact inside an ephemeral split-pane WKWebView on macOS,
/// reusing any already-open tab for `(parent, artifact_id)`, or opens externally elsewhere.
pub fn openArtifact(a: *App, parent: []const u8, artifact_id: []const u8, title: []const u8, frame_url: []const u8) void {
    const art = @import("artifact_url.zig");
    if (!art.isValidId(artifact_id) or !art.isSandboxFrameUrl(frame_url)) return;
    if (builtin.os.tag != .macos) {
        _ = open_external_url(frame_url);
        return;
    }
    const owner = source(a, parent) orelse return;
    var canon_buf: [64]u8 = undefined;
    const canon_url = art.canonicalUrl(&canon_buf, artifact_id) orelse return;
    for (a.panels.tabs.items, 0..) |tab, idx| {
        const existing = tab.browser orelse continue;
        if (tab.kind != .browser or !std.mem.eql(u8, existing.parent, parent)) continue;
        const eid = existing.artifact_id orelse continue;
        if (!std.mem.eql(u8, eid, artifact_id)) continue;
        const owned_frame = a.gpa.dupe(u8, frame_url) catch return;
        if (existing.frame_url) |old| a.gpa.free(old);
        existing.frame_url = owned_frame;
        if (title.len > 0) existing.title.set(title);
        existing.notice.clear();
        if (existing.native) |n| n.navigate(owned_frame);
        a.panels.active = idx;
        a.panels.host_open = true;
        a.view.strip.focused = .host;
        a.redraw();
        return;
    }
    const b = Browser.create(a, parent) catch return;
    b.pending_source = owner;
    b.artifact_id = a.gpa.dupe(u8, artifact_id) catch return b.destroy();
    b.frame_url = a.gpa.dupe(u8, frame_url) catch return b.destroy();
    b.url = a.gpa.dupe(u8, canon_url) catch return b.destroy();
    b.address.set(b.url);
    b.title.set(if (title.len > 0) title else "Artifact");
    b.focus_address = false;
    if (a.panels.pending_browser) |old| old.destroy();
    a.panels.pending_browser = b;
    a.redraw();
}

fn open(a: *App, parent: []const u8, url: ?[]const u8, view: ?saved.View) void {
    const owner = source(a, parent) orelse return;
    const b = Browser.create(a, parent) catch return;
    b.pending_source = owner;
    if (view) |v| {
        b.url = v.url(a.gpa) catch return b.destroy();
        b.saved_view = v;
        b.address.set(b.url);
        b.title.set(if (v.kind == .html) "Generated page" else "MCP App");
        b.focus_address = false;
    } else if (url) |u| b.navigate(u);
    if (a.panels.pending_browser) |old| old.destroy();
    a.panels.pending_browser = b;
    a.redraw();
}

pub fn settleFrame(a: *App) void {
    // Keep archived references, but release deleted owners through the same
    // frame-safe surface cleanup as explicit closure. Never prune startup data.
    if (a.chats_synced) {
        var i: usize = 0;
        while (i < a.panels.tabs.items.len) {
            const tab = a.panels.tabs.items[i];
            if (tab.browser) |old| if (a.findChat(old.parent) == null) {
                const before = a.panels.tabs.items.len;
                @import("app_panels.zig").closeTab(a, i);
                if (a.panels.tabs.items.len < before) continue;
            };
            i += 1;
        }
    }
    const b = a.panels.pending_browser orelse return;
    a.panels.pending_browser = null;
    const original = b.pending_source orelse return b.destroy();
    const owner = source(a, b.parent) orelse return b.destroy();
    if (owner.tab != original.tab or owner.pane != original.pane or
        (original.project != null and original.project != owner.project)) return b.destroy();
    // A peer link is delivered before deferred pointer promotion. Promote
    // through the ordinary path so canvas text/model/device choices park too.
    const selected = if (a.selected) |id| std.mem.eql(u8, id, b.parent) else false;
    if (!selected) {
        const pane_index = owner.pane_index orelse return b.destroy();
        a.focusPane(pane_index);
        if (a.selected == null or !std.mem.eql(u8, a.selected.?, b.parent)) return b.destroy();
        // Consume the matching deferred pane-promotion focus queued by the same
        // pointer release so strip.settle() does not overwrite .host below.
        if (a.view.strip.pending) |pending| switch (pending) {
            .focus => |panel| switch (panel) {
                .chat => |ix| if (ix == pane_index) {
                    a.view.strip.pending = null;
                },
                else => {},
            },
            else => {},
        };
    }
    b.pending_source = null;
    if (@import("github_link.zig").parse(b.url)) |target| {
        @import("app_github_repository.zig").openLinked(a, target);
        b.destroy();
        return;
    }
    const p = &a.panels;
    p.tabs.append(p.gpa, .{ .kind = .browser, .browser = b, .shown = p.bumpShown() }) catch return b.destroy();
    p.active = p.tabs.items.len - 1;
    p.host_open = true;
    a.view.strip.focused = .host;
}

/// Synchronize native visibility after the app has built its overlays.
/// Unlike frame timers, navigation callbacks wake the UI only on change.
pub fn syncNative(a: *App, c: *nanoui.ui.Context) void {
    if (comptime builtin.os.tag != .macos) return;
    const window = a.window orelse return;
    const active = if (a.panels.activeTab()) |t| t.browser else null;
    const modal = a.view.setup != null or a.view.project_setup.open or a.view.settings_open or a.picker != .none or a.view.palette.open or a.view.theme_import != null or
        a.view.strip.menu != null or a.view.account_menu or a.view.more_menu or a.view.filter_menu or a.view.space_menu or a.view.checkout_menu or a.view.ref_menu;
    for (a.panels.tabs.items) |t| if (t.browser) |b| {
        // Public http/https links route to `justrach/browse` Connected Apps;
        // sandboxed internal `graff-view://` and hosted artifact panes mount local WKWebView.
        const is_local = b.usesEmbeddedWebView();
        const visible = is_local and active == b and a.panels.host_open and b.belongsTo(a.selected) and !modal;
        if (visible) b.ensureNative();
        const n = b.native orelse continue;
        if (visible) {
            if (c.rects.get(b.body_node)) |rect| {
                if (rect.w > 0 and rect.h > 0 and !overlayCovers(c, rect)) {
                    n.mount(nanoui.objc.msg(nanoui.objc.Object, window.nswindow, "contentView", .{}), rect);
                    continue;
                }
            } else c.changed = true;
        }
        n.show(false);
    };
}

fn overlayCovers(c: *nanoui.ui.Context, body: nanoui.ui.Rect) bool {
    for (c.nodes.items) |node| {
        if (node.style.layer == 0) continue;
        const r = c.rects.get(node.id) orelse {
            c.changed = true;
            return true;
        };
        if (r.x < body.x + body.w and r.x + r.w > body.x and r.y < body.y + body.h and r.y + r.h > body.y) return true;
    }
    return false;
}
