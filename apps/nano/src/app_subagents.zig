//! Subagent transcripts are read-only side surfaces, not selectable chats.
//! Each tab owns its feed; document IDs never reach FocusChat or Run.
const std = @import("std");
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const Transcript = @import("transcript.zig").Transcript;

pub const Agent = struct {
    app: *App,
    parent: []u8,
    doc: []u8,
    title: []u8,
    frozen: bool,
    transcript: Transcript,
    watch: ?u64 = null,
    fetch: ?u64 = null,
    retry_at: ?f64 = null,
    loaded: bool = false,
    /// The feed's last error, shown in the tab until an item arrives.
    error_text: ?[]u8 = null,
    /// Failed watches since the last item, for `retryDelay`.
    failures: u32 = 0,

    fn create(a: *App, parent: []const u8, doc: []const u8, title: []const u8, frozen: bool) !*Agent {
        const s = try a.gpa.create(Agent);
        errdefer a.gpa.destroy(s);
        const owned_parent = try a.gpa.dupe(u8, parent);
        errdefer a.gpa.free(owned_parent);
        const owned_doc = try a.gpa.dupe(u8, doc);
        errdefer a.gpa.free(owned_doc);
        const owned_title = try a.gpa.dupe(u8, title);
        s.* = .{ .app = a, .parent = owned_parent, .doc = owned_doc, .title = owned_title, .frozen = frozen, .transcript = .{ .gpa = a.gpa } };
        return s;
    }

    pub fn stop(s: *Agent) void {
        if (s.watch) |id| s.app.engine.cancel(id);
        if (s.fetch) |id| s.app.engine.cancel(id);
        s.watch = null;
        s.fetch = null;
        s.retry_at = null;
    }

    /// Feeds are stopped before retirement, or the engine is already torn
    /// down. Never call back into the engine from an ownership destructor.
    pub fn destroy(s: *Agent) void {
        const gpa = s.app.gpa;
        s.transcript.deinit();
        if (s.error_text) |t| gpa.free(t);
        gpa.free(s.parent);
        gpa.free(s.doc);
        gpa.free(s.title);
        gpa.destroy(s);
    }

    pub fn belongsTo(s: *const Agent, parent: ?[]const u8) bool {
        const id = parent orelse return false;
        if (std.mem.eql(u8, s.parent, id)) return true;
        if (s.app.selected) |sel| if (std.mem.eql(u8, sel, id)) {
            if (s.app.tabs.layout()) |sp| for (sp.panes.items) |pane| if (pane) |p| {
                if (std.mem.eql(u8, s.parent, p)) return true;
            };
        };
        return false;
    }

    fn start(s: *Agent) void {
        if (!s.app.engine.up() or s.watch != null or s.fetch != null or s.loaded) return;
        if (s.frozen) {
            const ref = std.fmt.allocPrint(s.app.gpa, "{s}/{s}", .{ s.parent, s.doc }) catch return s.watchDoc();
            defer s.app.gpa.free(ref);
            s.fetch = s.app.send_(requests.fetchToolBlob(ref), .of(Agent, s, onSnapshot));
        } else s.watchDoc();
    }

    fn watchDoc(s: *Agent) void {
        s.retry_at = null;
        s.watch = s.app.send_(requests.watchDoc(s.doc, false), .of(Agent, s, onDoc));
    }

    fn onSnapshot(s: *Agent, id: u64, reply: rpc.Reply) void {
        if (s.fetch != id) return;
        s.fetch = null;
        const parsed = switch (reply) {
            .ok => |v| blk: {
                const text = if (v == .object) v.object.get("text") else null;
                if (text) |t| if (t == .string) {
                    break :blk std.json.parseFromSlice(std.json.Value, s.app.gpa, t.string, .{}) catch null;
                };
                break :blk null;
            },
            else => null,
        };
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .array) {
                var object: std.json.ObjectMap = .empty;
                defer object.deinit(s.app.gpa);
                object.put(s.app.gpa, "reset", p.value) catch return s.watchDoc();
                s.transcript.apply(.{ .object = object }) catch return s.watchDoc();
                s.loaded = true;
                s.app.redraw();
                return;
            }
        }
        // Frozen uploads are best effort; GPUI falls back to the live doc.
        s.watchDoc();
        s.app.redraw();
    }

    fn onDoc(s: *Agent, id: u64, reply: rpc.Reply) void {
        if (s.watch != id) return;
        switch (reply) {
            .item => |frame| if (s.transcript.apply(frame)) |_| {
                s.failures = 0;
                s.setError(null);
            } else |_| {
                // A frame out of step: a fresh watch starts from a reset.
                s.app.engine.cancel(id);
                s.watch = null;
                s.backOff();
            },
            // The engine ended the feed: the transcript is final.
            .done => {
                s.watch = null;
                s.retry_at = null;
                s.loaded = true;
            },
            .err => |why| {
                s.watch = null;
                s.setError(why);
                s.backOff();
            },
            .ok => {},
        }
        s.app.redraw();
    }

    fn backOff(s: *Agent) void {
        s.failures +|= 1;
        s.retry_at = s.app.now + retryDelay(s.failures);
    }

    fn setError(s: *Agent, why: ?[]const u8) void {
        if (s.error_text) |t| s.app.gpa.free(t);
        s.error_text = if (why) |w| s.app.gpa.dupe(u8, w) catch null else null;
    }
};

/// Seconds before a failed subagent feed is watched again, after `failures`
/// failures in a row: 2 s, doubling, at most a minute.
pub fn retryDelay(failures: u32) f64 {
    if (failures == 0) return 0;
    const doublings: u5 = @intCast(@min(failures - 1, 5));
    return @min(2 * @as(f64, @floatFromInt(@as(u32, 1) << doublings)), 60);
}

/// Retain targets now, activate at the next frame boundary. A nested
/// agent click must not free/reallocate the transcript being laid out.
pub fn open(a: *App, parent: []const u8, part: *const @import("transcript.zig").Part) void {
    if (!part.agent or part.subagent_ref.len == 0 or part.subagent_title.len == 0) return;
    const frozen = if (part.subagent_status) |s| s != .running else false;
    const next = Agent.create(a, parent, part.subagent_ref, part.subagent_title, frozen) catch return;
    if (a.panels.pending_agent) |old| old.destroy();
    a.panels.pending_agent = next;
    a.redraw();
}

pub fn settleFrame(a: *App) void {
    const p = &a.panels;
    for (p.retired.items) |t| @import("app_panels.zig").destroyTab(p, t);
    p.retired.clearRetainingCapacity();
    const next = p.pending_agent orelse return;
    p.pending_agent = null;
    if (!next.belongsTo(a.selected)) return next.destroy();
    for (p.tabs.items, 0..) |*t, i| if (t.agent) |s| {
        if (!std.mem.eql(u8, s.doc, next.doc) or !std.mem.eql(u8, s.parent, next.parent)) continue;
        next.destroy();
        p.active = i;
        t.shown = p.bumpShown();
        p.host_open = true;
        return;
    };
    p.tabs.append(p.gpa, .{ .kind = .subagent, .agent = next, .shown = p.bumpShown() }) catch return next.destroy();
    p.active = p.tabs.items.len - 1;
    p.host_open = true;
    next.start();
}

pub fn tick(a: *App, now: f64) ?f64 {
    if (!a.engine.up()) return null;
    var next: ?f64 = null;
    for (a.panels.tabs.items) |t| if (t.agent) |s| {
        if (s.retry_at) |at| {
            if (now >= at) s.watchDoc() else next = if (next) |n| @min(n, at) else at;
        } else s.start();
    };
    return next;
}
