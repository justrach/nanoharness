//! Per-artifact state for CodeGraff hosted artifacts (`artifact.codegraff.com`):
//! mints short-lived frame URLs, toggles public/private visibility, and auto-opens
//! newly created live artifacts into macOS split-pane WKWebView once.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const art = @import("artifact_url.zig");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    frame_url: ?[]u8 = null,
    frame_expires_at: ?i64 = null,
    visibility: ?[]u8 = null,
    loading: bool = false,
    toggling: bool = false,
    pending_open: bool = false,
    auto_opened: bool = false,
    chat_id: ?[]u8 = null,
    title: ?[]u8 = null,
    err: ?[]u8 = null,

    pub fn deinit(e: *Entry, gpa: Allocator) void {
        inline for (.{ "frame_url", "visibility", "chat_id", "title", "err" }) |f| {
            if (@field(e, f)) |s| gpa.free(s);
        }
        e.* = .{};
    }
};

const PendingKind = enum { frame, visibility };

const PendingCall = struct {
    artifact_id: []u8,
    kind: PendingKind,
};

pub const State = struct {
    entries: std.StringHashMapUnmanaged(Entry) = .{},
    pending: std.AutoHashMapUnmanaged(u64, PendingCall) = .{},

    pub fn deinit(s: *State, gpa: Allocator) void {
        var it = s.entries.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            kv.value_ptr.deinit(gpa);
        }
        s.entries.deinit(gpa);

        var pit = s.pending.valueIterator();
        while (pit.next()) |p| gpa.free(p.artifact_id);
        s.pending.deinit(gpa);
        s.* = .{};
    }

    pub fn entry(s: *const State, artifact_id: []const u8) ?*const Entry {
        return s.entries.getPtr(artifact_id);
    }
};

fn ensureEntry(a: *App, artifact_id: []const u8) ?*Entry {
    const s = &a.hosted_artifacts;
    if (s.entries.getPtr(artifact_id)) |e| return e;
    const key = a.gpa.dupe(u8, artifact_id) catch return null;
    s.entries.put(a.gpa, key, .{}) catch {
        a.gpa.free(key);
        return null;
    };
    return s.entries.getPtr(artifact_id);
}

fn replaceOpt(gpa: Allocator, slot: *?[]u8, val: ?[]const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (val) |v| gpa.dupe(u8, v) catch null else null;
}

pub fn effectiveVisibility(a: *const App, artifact_id: []const u8, doc_visibility: []const u8) []const u8 {
    if (a.hosted_artifacts.entries.getPtr(artifact_id)) |e| {
        if (e.visibility) |v| return v;
    }
    return doc_visibility;
}

pub fn hasFreshFrameUrl(e: *const Entry, now_s: i64) bool {
    const furl = e.frame_url orelse return false;
    if (!art.isSandboxFrameUrl(furl)) return false;
    if (e.frame_expires_at) |exp| return exp > now_s + 60;
    return true;
}

/// Called after applying a `WatchDocMessages` frame on the selected chat.
/// Historical `reset` frames mark artifacts seen without auto-opening; live `upsert`
/// frames auto-open newly created artifacts once when an interactive window is active.
pub fn onTranscriptFrame(a: *App, was_reset: bool) void {
    const chat_id = a.selected orelse return;
    for (a.transcript.entries.items) |*msg| {
        for (msg.parts.items) |*p| {
            if (p.kind != .artifact or !art.isValidId(p.artifact_id)) continue;
            const e = ensureEntry(a, p.artifact_id) orelse continue;
            if (was_reset) {
                e.auto_opened = true;
            } else if (!e.auto_opened) {
                e.auto_opened = true;
                if (!builtin.is_test and a.window != null and !a.offscreen) {
                    open(a, chat_id, p.artifact_id, p.text.items);
                }
            }
        }
    }
}

pub fn open(a: *App, chat_id: []const u8, artifact_id: []const u8, title: []const u8) void {
    if (!art.isValidId(artifact_id)) return;
    const e = ensureEntry(a, artifact_id) orelse return;
    const now_s: i64 = @divTrunc(a.nowMs(), 1000);
    if (hasFreshFrameUrl(e, now_s)) {
        @import("app_browser.zig").openArtifact(a, chat_id, artifact_id, title, e.frame_url.?);
        return;
    }
    if (!a.engine.up()) {
        replaceOpt(a.gpa, &e.err, "Engine not connected");
        a.setNotice("Sign in or start Harness engine to preview this artifact.");
        a.redraw();
        return;
    }
    replaceOpt(a.gpa, &e.err, null);
    replaceOpt(a.gpa, &e.chat_id, chat_id);
    replaceOpt(a.gpa, &e.title, title);
    e.pending_open = true;
    if (e.loading) return;
    e.loading = true;
    callArtifactRpc(a, artifact_id, .frame, "CodegraffArtifactFrameUrl", .{ .artifactId = artifact_id });
    a.redraw();
}

pub fn toggleVisibility(a: *App, artifact_id: []const u8, current_visibility: []const u8) void {
    if (!art.isValidId(artifact_id)) return;
    const e = ensureEntry(a, artifact_id) orelse return;
    if (e.toggling) return;
    if (!a.engine.up()) {
        replaceOpt(a.gpa, &e.err, "Engine not connected");
        a.redraw();
        return;
    }
    const vis = effectiveVisibility(a, artifact_id, current_visibility);
    const next_vis: []const u8 = if (std.mem.eql(u8, vis, "public")) "private" else "public";
    replaceOpt(a.gpa, &e.err, null);
    replaceOpt(a.gpa, &e.frame_url, null);
    e.frame_expires_at = null;
    e.toggling = true;
    callArtifactRpc(a, artifact_id, .visibility, "CodegraffArtifactSetVisibility", .{
        .artifactId = artifact_id,
        .visibility = next_vis,
    });
    a.redraw();
}

fn callArtifactRpc(a: *App, artifact_id: []const u8, kind: PendingKind, method: []const u8, params: anytype) void {
    const req_id = a.engine.call(method, params, .of(App, a, onRpcReply)) orelse {
        if (a.hosted_artifacts.entries.getPtr(artifact_id)) |e| {
            e.loading = false;
            e.toggling = false;
            e.pending_open = false;
            replaceOpt(a.gpa, &e.err, "Engine not connected");
        }
        return;
    };
    const dup_id = a.gpa.dupe(u8, artifact_id) catch return;
    a.hosted_artifacts.pending.put(a.gpa, req_id, .{ .artifact_id = dup_id, .kind = kind }) catch {
        a.gpa.free(dup_id);
    };
}

fn onRpcReply(a: *App, id: u64, r: rpc.Reply) void {
    const kv = a.hosted_artifacts.pending.fetchRemove(id) orelse return;
    const pending = kv.value;
    defer a.gpa.free(pending.artifact_id);
    const e = a.hosted_artifacts.entries.getPtr(pending.artifact_id) orelse return;
    switch (pending.kind) {
        .frame => e.loading = false,
        .visibility => e.toggling = false,
    }
    switch (r) {
        .err => |msg| {
            e.pending_open = false;
            const why = if (std.mem.eql(u8, msg, "not connected")) "Engine not connected" else msg;
            replaceOpt(a.gpa, &e.err, why);
            a.setNotice(why);
        },
        .ok => |v| {
            if (v != .object) {
                e.pending_open = false;
                replaceOpt(a.gpa, &e.err, "Unexpected artifact response");
            } else {
                const o = v.object;
                if (o.get("visibility")) |vis| if (vis == .string and art.isValidVisibility(vis.string)) {
                    replaceOpt(a.gpa, &e.visibility, vis.string);
                };
                if (o.get("frameExpiresAt")) |exp| {
                    e.frame_expires_at = if (exp == .integer) exp.integer else null;
                } else if (pending.kind == .frame) {
                    e.frame_expires_at = null;
                }
                if (o.get("frameUrl")) |fu| if (fu == .string and art.isSandboxFrameUrl(fu.string)) {
                    replaceOpt(a.gpa, &e.frame_url, fu.string);
                };
                replaceOpt(a.gpa, &e.err, null);
                if (pending.kind == .frame and e.pending_open) {
                    e.pending_open = false;
                    if (e.frame_url) |furl| {
                        const cid = e.chat_id orelse a.selected orelse "";
                        if (cid.len > 0) @import("app_browser.zig").openArtifact(a, cid, pending.artifact_id, e.title orelse "Artifact", furl);
                    }
                }
            }
        },
        else => {
            e.pending_open = false;
        },
    }
    a.redraw();
}

const testing = std.testing;

test "historical reset marks artifacts seen without opening; fresh frame url check respects expiry" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.selected = try a.gpa.dupe(u8, "chat-art");
    const art_id = "art-0123456789abcdef01234567";
    const frame = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"reset":[{"id":"m1","role":"assistant","parts":[{"id":"show-artifact:art-0123456789abcdef01234567","kind":"artifact","artifactId":"art-0123456789abcdef01234567","title":"Architecture","format":"html","visibility":"private","url":"https://codegraff.com/a/art-0123456789abcdef01234567"}]}]}
    , .{});
    defer frame.deinit();
    try a.transcript.apply(frame.value);
    onTranscriptFrame(&a, true);
    const e = a.hosted_artifacts.entry(art_id).?;
    try testing.expect(e.auto_opened);
    try testing.expect(!e.loading);

    var sample: Entry = .{
        .frame_url = try testing.allocator.dupe(u8, "https://artifact.codegraff.com/art-0123456789abcdef01234567?t=1000.sig"),
        .frame_expires_at = 1000,
    };
    defer sample.deinit(testing.allocator);
    try testing.expect(hasFreshFrameUrl(&sample, 900));
    try testing.expect(!hasFreshFrameUrl(&sample, 950));
}
