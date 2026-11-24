//! Settings › Accounts › browse (settings/browse_link.rs): connect Harness
//! to the user's browse so agents browse with their sign-ins (the engine's
//! `BrowseLinkStatus`, `BrowseLinkPair`, `BrowseLinkDisconnect`). Pairing
//! shows six digits browse also shows; the user confirms there and picks
//! what Harness may do. On macOS, for this device only: browse pairs with
//! the engine on the Mac it runs on.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const rpc = @import("rpc.zig");
const rows = @import("view_settings_accounts_rows.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

const poll_every_s: f64 = 1;

/// `BrowseLinkStatus`, its strings owned.
pub const Status = struct {
    browse_running: bool = false,
    paired: bool = false,
    scopes: [][]u8 = &.{},
    pairing_code: ?[]u8 = null,
    key_mismatch: bool = false,
    err: ?[]u8 = null,

    fn deinit(s: *Status, gpa: Allocator) void {
        for (s.scopes) |x| gpa.free(x);
        gpa.free(s.scopes);
        if (s.pairing_code) |x| gpa.free(x);
        if (s.err) |x| gpa.free(x);
        s.* = .{};
    }

    pub fn parse(gpa: Allocator, v: json.Value) !Status {
        if (v != .object) return .{};
        const o = v.object;
        var s: Status = .{
            .browse_running = flag(o, "browseRunning"),
            .paired = flag(o, "paired"),
            .key_mismatch = flag(o, "keyMismatch"),
        };
        errdefer s.deinit(gpa);
        if (text(o, "pairingCode")) |t| s.pairing_code = try gpa.dupe(u8, t);
        if (text(o, "error")) |t| s.err = try gpa.dupe(u8, t);
        if (o.get("scopes")) |list| if (list == .array) {
            var out: std.ArrayList([]u8) = .empty;
            errdefer {
                for (out.items) |x| gpa.free(x);
                out.deinit(gpa);
            }
            for (list.array.items) |x| if (x == .string) try out.append(gpa, try gpa.dupe(u8, x.string));
            s.scopes = try out.toOwnedSlice(gpa);
        };
        return s;
    }
};

fn flag(o: json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

fn text(o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

/// What each browse scope lets agents do, in the card's words (`scope_label`).
pub fn scopeLabel(scope: []const u8) []const u8 {
    const pairs = .{ .{ "read", "Search and read" }, .{ "act-own-pages", "Act in its own pages" }, .{ "act-user-tabs", "Use your tabs" }, .{ "run-js", "Run scripts" } };
    inline for (pairs) |p| if (std.mem.eql(u8, scope, p[0])) return p[1];
    return scope;
}

/// "123456" → "123 456" (`spaced_code`).
pub fn spacedCode(buf: []u8, code: []const u8) []const u8 {
    if (code.len != 6) return code;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ code[0..3], code[3..] }) catch code;
}

test "codes and scopes read well (codes_and_scopes_read_well)" {
    var b: [8]u8 = undefined;
    try std.testing.expectEqualStrings("012 345", spacedCode(&b, "012345"));
    try std.testing.expectEqualStrings("12", spacedCode(&b, "12"));
    try std.testing.expectEqualStrings("Use your tabs", scopeLabel("act-user-tabs"));
    try std.testing.expectEqualStrings("other", scopeLabel("other"));
}

test "a status reads its fields, and nothing from a non-object" {
    const gpa = std.testing.allocator;
    const p = try json.parseFromSlice(json.Value, gpa, "{\"paired\":true,\"browseRunning\":true,\"scopes\":[\"read\",\"run-js\"],\"error\":\"x\"}", .{});
    defer p.deinit();
    var s = try Status.parse(gpa, p.value);
    defer s.deinit(gpa);
    try std.testing.expect(s.paired and s.browse_running and !s.key_mismatch);
    try std.testing.expectEqual(@as(usize, 2), s.scopes.len);
    try std.testing.expectEqualStrings("x", s.err.?);
    var none = try Status.parse(gpa, .null);
    defer none.deinit(gpa);
    try std.testing.expect(!none.paired and none.pairing_code == null);
}

test "settings audit browse Disconnect reports failure while connected and clears it on retry" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const Harness = @import("tests_ui_tab_strip.zig").Harness;
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.engine.scene = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"BrowseLinkStatus":{"$seq":[{"paired":true,"browseRunning":true},
        \\  {"paired":true,"browseRunning":true},{"paired":false,"browseRunning":true}]},
        \\ "BrowseLinkDisconnect":{"$seq":[{"$err":"Synthetic disconnect refused"},{"ok":true}]}}
    , .{});
    h.a.engine.state = .connected;
    h.a.settings.section = .agents;
    @import("view_settings.zig").open(&h.a);
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("Connected"));

    try h.t.clickText("Disconnect");
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("Connected"));
    const button = h.t.findText("Disconnect") orelse return error.MissingDisconnect;
    const message = h.t.findText("Synthetic disconnect refused") orelse return error.MissingDisconnectError;
    try testing.expect(message.y > button.y and message.y - button.y < 100);
    try testing.expect(message.y + message.h <= h.t.size.h);
    try testing.expectEqual(@as(usize, 2), h.a.engine.seq_used.get("BrowseLinkStatus").?);

    try h.t.clickText("Disconnect");
    // At click release the new action is pending; the prior error is gone,
    // but the last confirmed status must still be connected.
    try testing.expect(h.t.hasText("Connected"));
    try testing.expect(!h.t.hasText("Synthetic disconnect refused"));
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("Connect"));
    try testing.expect(!h.t.hasText("Connected"));
    try testing.expect(!h.t.hasText("Synthetic disconnect refused"));
    try testing.expectEqual(@as(usize, 2), h.a.engine.seq_used.get("BrowseLinkDisconnect").?);
}

test "settings audit browse retries a failed status check without repeating Disconnect" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const Harness = @import("tests_ui_tab_strip.zig").Harness;
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.engine.scene = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"BrowseLinkStatus":{"$seq":[{"paired":true,"browseRunning":true},
        \\  {"$err":"Synthetic status unavailable"},{"paired":false,"browseRunning":true}]},
        \\ "BrowseLinkDisconnect":{"$seq":[{"ok":true}]}}
    , .{});
    h.a.engine.state = .connected;
    h.a.settings.section = .agents;
    @import("view_settings.zig").open(&h.a);
    h.t.advance(0.2);
    try h.t.clickText("Disconnect");
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("Connected"));
    try testing.expect(h.t.hasText("Couldn't check browse status: Synthetic status unavailable"));
    try h.t.clickText("Retry status check");
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("Connect"));
    try testing.expect(!h.t.hasText("Connected"));
    try testing.expect(!h.t.hasText("Retry status check"));
    try testing.expectEqual(@as(usize, 1), h.a.engine.seq_used.get("BrowseLinkDisconnect").?);
    try testing.expectEqual(@as(usize, 3), h.a.engine.seq_used.get("BrowseLinkStatus").?);
}

pub const State = struct {
    status: ?Status = null,
    busy: bool = false,
    err: ?[]u8 = null,
    status_err: ?[]u8 = null,
    started: bool = false,
    call: ?u64 = null,
    poll_at: ?f64 = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        if (s.status) |*x| x.deinit(gpa);
        if (s.err) |x| gpa.free(x);
        if (s.status_err) |x| gpa.free(x);
    }
};

/// Shown on macOS, for this device's logins (`show_browse`).
pub fn shown(a: *const App) bool {
    return builtin.os.tag == .macos and a.view.accounts.target == null;
}

fn state(a: *App) *State {
    return &a.view.accounts.browse;
}

/// Ask for the status again; it keeps polling while a code is up.
pub fn refresh(a: *App) void {
    const s = state(a);
    s.started = true;
    s.poll_at = null;
    // Sends can report a transport error synchronously with id zero.
    s.call = 0;
    const call = a.engine.call("BrowseLinkStatus", rpc.empty, .of(App, a, onStatus));
    if (s.call == 0) {
        s.call = call;
        if (call == null) statusFailed(a, "Could not send browse status check");
    }
}

fn onStatus(a: *App, id: u64, r: rpc.Reply) void {
    const s = state(a);
    if (s.call != id) return;
    s.call = null;
    switch (r) {
        .ok => |v| if (Status.parse(a.gpa, v)) |next| {
            if (s.status) |*old| old.deinit(a.gpa);
            s.status = next;
            if (s.status_err) |old| a.gpa.free(old);
            s.status_err = null;
            s.poll_at = if (next.pairing_code != null) a.now + poll_every_s else null;
        } else |_| statusFailed(a, "Unexpected reply"),
        .err => |e| statusFailed(a, e),
        else => {},
    }
    a.redraw();
}

fn statusFailed(a: *App, msg: []const u8) void {
    const s = state(a);
    if (s.status_err) |old| a.gpa.free(old);
    s.status_err = a.gpa.dupe(u8, msg) catch null;
    // A transient status error doesn't cancel a pairing already in progress.
    s.poll_at = if (s.status) |prior| (if (prior.pairing_code != null) a.now + poll_every_s else null) else null;
    a.redraw();
}

fn act(a: *App, method: []const u8) void {
    const s = state(a);
    if (s.busy) return;
    s.busy = true;
    setErr(a, null);
    if (a.engine.call(method, rpc.empty, .of(App, a, onAction)) == null and s.busy) {
        onAction(a, 0, .{ .err = "Could not send browse action" });
    }
}

fn onAction(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => setErr(a, null),
        .err => |e| setErr(a, e),
        else => return,
    }
    state(a).busy = false;
    // Only status can tell whether browse is still paired. A successful
    // status refresh must not erase the separate action error.
    refresh(a);
    a.redraw();
}

fn setErr(a: *App, e: ?[]const u8) void {
    const s = state(a);
    if (s.err) |old| a.gpa.free(old);
    s.err = if (e) |t| a.gpa.dupe(u8, t) catch null else null;
}

/// The section: "browse" with its globe, 24 under what's above, and its
/// card 8 under that.
pub fn card(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = state(a);
    if (!s.started) refresh(a);
    if (s.poll_at) |t| {
        if (a.now >= t) {
            s.poll_at = null;
            refresh(a);
        } else c.frameIn(@floatCast(t - a.now));
    }
    @import("view_settings.zig").space(c, 24);
    {
        const h = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer h.end();
        rows.sectionHead(c, k, .globe, null, "browse");
    }
    const cd = rows.card(c, k, 8);
    defer cd.end();
    const body = ui.div(c).column().wFull().px(20).py(14).gap(10);
    defer body.end();
    const status: Status = s.status orelse .{};
    if (status.pairing_code) |code| {
        var buf: [8]u8 = undefined;
        ui.text(c, c.print("{s}", .{spacedCode(&buf, code)}), rows.st(c, 26, .{ .weight = .semibold, .color = k.text }));
        note(c, k, "Check that browse shows the same code, then allow Harness there and choose what it may do.");
        if (rows.ghost(c, k, .{ .label = if (s.busy) "Cancelling\u{2026}" else "Cancel", .dim = s.busy })) act(a, "BrowseLinkDisconnect");
    } else if (status.paired) {
        {
            const badges = ui.div(c).row().gap(6).itemsCenter();
            defer badges.end();
            rows.badgeActive(c, k, "Connected");
            for (status.scopes) |scope| rows.badge(c, k, scopeLabel(scope));
        }
        note(c, k, if (status.key_mismatch)
            "A different browse is running than the one Harness connected to. Disconnect and connect again."
        else if (status.browse_running)
            "New agent runs get browse's tools, with your sign-ins. Each run has its own pages, closed when it ends."
        else
            "browse isn't running with Connected apps on, so agents use Harness's own browser for now.");
        note(c, k, "Change what Harness may do, or revoke it, in browse \u{203a} Settings \u{203a} Agent \u{203a} Connected apps.");
        if (rows.ghost(c, k, .{ .label = if (s.busy) "Disconnecting\u{2026}" else "Disconnect", .dim = s.busy })) act(a, "BrowseLinkDisconnect");
    } else if (status.browse_running) {
        note(c, k, "Let agents use browse, with your sign-ins. You'll confirm a code in browse and choose what Harness may do.");
        if (rows.ghost(c, k, .{ .label = if (s.busy) "Connecting\u{2026}" else "Connect", .dim = s.busy })) act(a, "BrowseLinkPair");
    } else {
        note(c, k, "Open browse and turn on Settings \u{203a} Agent \u{203a} Connected apps to let agents use it with your sign-ins.");
        if (s.status_err == null and rows.ghost(c, k, .{ .label = "Check again", .dim = s.call != null }) and s.call == null) {
            setErr(a, null);
            refresh(a);
        }
    }
    const e = s.err orelse status.err;
    if (e) |msg| _ = rows.errorStrip(c, k, msg, false);
    if (s.status_err) |msg| {
        _ = rows.errorStrip(c, k, c.print("Couldn't check browse status: {s}", .{msg}), false);
        const waiting = s.call != null or s.busy;
        if (rows.ghost(c, k, .{ .label = if (waiting) "Checking status…" else "Retry status check", .dim = waiting }) and !waiting) refresh(a);
    }
}

/// A muted line at 12 on 18 (`note`), wrapped to the card.
fn note(c: *ui.Context, k: theme.Colors, words: []const u8) void {
    const w = ui.div(c).column().w(rows.rowInner());
    defer w.end();
    var style = rows.st(c, 12, .{ .wrap = true, .color = k.muted });
    style.line_height = 18;
    ui.text(c, words, style);
}
