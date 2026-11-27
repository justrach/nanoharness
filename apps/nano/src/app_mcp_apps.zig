//! Asynchronous SEP-1865 MCP Apps session coordinator & browser tab integration.
//! Never blocks the UI thread: resource fetches (`McpAppFetchResource`) and app
//! tool invocations (`McpAppCallTool`) dispatch through `a.engine.call`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const nanoui = @import("nanoui");
const Allocator = std.mem.Allocator;

const App = @import("app.zig").App;
const Browser = @import("app_browser.zig").Browser;
const rpc = @import("rpc.zig");
const theme = @import("theme.zig");
const host = @import("mcp_app_host.zig");
const McpAppNative = @import("mcp_app_native.zig").McpAppNative;

pub const PartData = struct {
    server_name: []u8,
    resource_uri: []u8,
    tool_name: []u8,
    title: ?[]u8 = null,
    tool_input_json: ?[]u8 = null,
    tool_result_json: ?[]u8 = null,

    pub fn parse(gpa: Allocator, v: json.Value) !?PartData {
        if (v != .object) return null;
        const o = v.object;
        const server = switch (o.get("serverName") orelse return null) {
            .string => |s| if (s.len > 0) s else return null,
            else => return null,
        };
        const uri = switch (o.get("resourceUri") orelse return null) {
            .string => |s| if (std.mem.startsWith(u8, s, "ui://")) s else return null,
            else => return null,
        };
        const tool = switch (o.get("toolName") orelse return null) {
            .string => |s| if (s.len > 0) s else return null,
            else => return null,
        };

        const srv_d = try gpa.dupe(u8, server);
        errdefer gpa.free(srv_d);
        const uri_d = try gpa.dupe(u8, uri);
        errdefer gpa.free(uri_d);
        const tool_d = try gpa.dupe(u8, tool);
        errdefer gpa.free(tool_d);

        const title_d: ?[]u8 = if (o.get("title")) |tv| switch (tv) {
            .string => |s| if (s.len > 0) try gpa.dupe(u8, s) else null,
            else => null,
        } else null;
        errdefer if (title_d) |t| gpa.free(t);

        const input_d: ?[]u8 = if (o.get("toolInput")) |iv|
            if (iv != .null) try json.Stringify.valueAlloc(gpa, iv, .{}) else null
        else
            null;
        errdefer if (input_d) |i| gpa.free(i);

        const result_d: ?[]u8 = if (o.get("toolResult")) |rv|
            if (rv != .null) try json.Stringify.valueAlloc(gpa, rv, .{}) else null
        else
            null;
        errdefer if (result_d) |r| gpa.free(r);

        return .{
            .server_name = srv_d,
            .resource_uri = uri_d,
            .tool_name = tool_d,
            .title = title_d,
            .tool_input_json = input_d,
            .tool_result_json = result_d,
        };
    }

    pub fn deinit(self: *PartData, gpa: Allocator) void {
        gpa.free(self.server_name);
        gpa.free(self.resource_uri);
        gpa.free(self.tool_name);
        if (self.title) |s| gpa.free(s);
        if (self.tool_input_json) |s| gpa.free(s);
        if (self.tool_result_json) |s| gpa.free(s);
        self.* = undefined;
    }
};

pub const LaunchSpec = struct {
    server_name: []const u8,
    resource_uri: []const u8,
    tool_name: []const u8 = "",
    title: ?[]const u8 = null,
    tool_input_json: ?[]const u8 = null,
    tool_result_json: ?[]const u8 = null,
};

const PendingToolCall = struct {
    session_id: u64,
    rpc_id: host.OwnedRpcId,
};

const PendingList = struct {
    parent: []u8,
    server_name: []u8,
};

pub const DeliverHook = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, []const u8) void,
};

pub const ToolCallHook = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, *Session, host.RpcId, []const u8, ?json.Value) void,
};

pub const State = struct {
    next_session_id: u64 = 1,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    pending_fetches: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    pending_tool_calls: std.AutoHashMapUnmanaged(u64, PendingToolCall) = .empty,
    pending_lists: std.AutoHashMapUnmanaged(u64, PendingList) = .empty,
    teardown_seq: u64 = 1,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.sessions.deinit(gpa);
        s.pending_fetches.deinit(gpa);
        var pit = s.pending_tool_calls.valueIterator();
        while (pit.next()) |call| {
            var id = call.rpc_id;
            id.deinit(gpa);
        }
        s.pending_tool_calls.deinit(gpa);
        var lit = s.pending_lists.valueIterator();
        while (lit.next()) |list| {
            gpa.free(list.parent);
            gpa.free(list.server_name);
        }
        s.pending_lists.deinit(gpa);
        s.* = .{};
    }
};

pub const Session = struct {
    id: u64,
    app: *App,
    parent: []u8,
    server_name: []u8,
    resource_uri: []u8,
    tool_name: []u8,
    title: []u8,
    cwd: ?[]u8 = null,
    tool_input_json: ?[]u8 = null,
    tool_result_json: ?[]u8 = null,
    allowed_app_tools: [][]u8 = &.{},
    shell_html: ?[]u8 = null,
    shell_csp: ?[]u8 = null,
    frame_domains: [][]u8 = &.{},
    loading: bool = true,
    loaded_into_native: bool = false,
    initialized: bool = false,
    display_mode: host.DisplayMode = .inline_mode,
    preferred_height: ?f32 = null,
    context_note: ?[]u8 = null,
    err: ?[]u8 = null,
    theme_colors: theme.Colors,
    last_theme_hash: u64 = 0,
    last_account_hash: u64 = 0,
    native: ?*McpAppNative = null,
    deliver_override: ?DeliverHook = null,
    tool_call_override: ?ToolCallHook = null,

    pub fn create(app: *App, parent: []const u8, spec: LaunchSpec, cwd_opt: ?[]const u8) !*Session {
        const gpa = app.gpa;
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);

        const sid = app.mcp_apps.next_session_id;
        app.mcp_apps.next_session_id += 1;

        const parent_d = try gpa.dupe(u8, parent);
        errdefer gpa.free(parent_d);
        const server_d = try gpa.dupe(u8, spec.server_name);
        errdefer gpa.free(server_d);
        const uri_d = try gpa.dupe(u8, spec.resource_uri);
        errdefer gpa.free(uri_d);
        const tool_d = try gpa.dupe(u8, spec.tool_name);
        errdefer gpa.free(tool_d);
        const title_src = spec.title orelse (if (spec.tool_name.len > 0) spec.tool_name else spec.server_name);
        const title_d = try gpa.dupe(u8, title_src);
        errdefer gpa.free(title_d);
        const cwd_d: ?[]u8 = if (cwd_opt) |c| (if (c.len > 0) try gpa.dupe(u8, c) else null) else null;
        errdefer if (cwd_d) |c| gpa.free(c);
        const input_d: ?[]u8 = if (spec.tool_input_json) |i| try gpa.dupe(u8, i) else null;
        errdefer if (input_d) |i| gpa.free(i);
        const result_d: ?[]u8 = if (spec.tool_result_json) |r| try gpa.dupe(u8, r) else null;
        errdefer if (result_d) |r| gpa.free(r);

        const default_colors = theme.colors(false);
        const init_acct = resolveHostAccount(app, parent);
        s.* = .{
            .id = sid,
            .app = app,
            .parent = parent_d,
            .server_name = server_d,
            .resource_uri = uri_d,
            .tool_name = tool_d,
            .title = title_d,
            .cwd = cwd_d,
            .tool_input_json = input_d,
            .tool_result_json = result_d,
            .theme_colors = default_colors,
            .last_theme_hash = host.colorFingerprint(default_colors),
            .last_account_hash = host.accountFingerprint(init_acct),
        };
        try app.mcp_apps.sessions.put(gpa, sid, s);
        return s;
    }

    pub fn destroy(s: *Session) void {
        const gpa = s.app.gpa;
        _ = s.app.mcp_apps.sessions.remove(s.id);
        if (s.initialized and s.native != null) {
            const req_id = s.app.mcp_apps.teardown_seq;
            s.app.mcp_apps.teardown_seq += 1;
            if (host.buildTeardownRequest(gpa, req_id)) |msg| {
                defer gpa.free(msg);
                s.deliver(msg);
            } else |_| {}
        }
        if (s.native) |n| n.destroy();
        s.native = null;

        s.clearFetchedResource();
        if (s.cwd) |c| gpa.free(c);
        if (s.tool_input_json) |i| gpa.free(i);
        if (s.tool_result_json) |r| gpa.free(r);
        if (s.context_note) |cn| gpa.free(cn);
        if (s.err) |e| gpa.free(e);
        gpa.free(s.parent);
        gpa.free(s.server_name);
        gpa.free(s.resource_uri);
        gpa.free(s.tool_name);
        gpa.free(s.title);
        gpa.destroy(s);
    }

    fn clearFetchedResource(s: *Session) void {
        const gpa = s.app.gpa;
        if (s.shell_html) |h| gpa.free(h);
        if (s.shell_csp) |c| gpa.free(c);
        for (s.allowed_app_tools) |t| gpa.free(t);
        if (s.allowed_app_tools.len > 0) gpa.free(s.allowed_app_tools);
        for (s.frame_domains) |d| gpa.free(d);
        if (s.frame_domains.len > 0) gpa.free(s.frame_domains);
        s.shell_html = null;
        s.shell_csp = null;
        s.allowed_app_tools = &.{};
        s.frame_domains = &.{};
        s.loaded_into_native = false;
    }

    pub fn ensureNative(s: *Session) void {
        if (comptime builtin.os.tag != .macos) return;
        if (s.native != null or s.app.window == null) return;
        s.native = McpAppNative.create(s.app.gpa, .{
            .ctx = s,
            .on_message = onNativeMessage,
            .on_state = onNativeState,
        }) catch {
            s.setError("Could not start isolated MCP App WebKit host.");
            return;
        };
        s.loadShellIfReady();
    }

    pub fn mount(s: *Session, parent_view: anytype, rect: nanoui.ui.Rect) void {
        if (comptime builtin.os.tag != .macos) return;
        const n = s.native orelse return;
        n.mount(parent_view, rect);
    }

    pub fn hide(s: *Session) void {
        if (comptime builtin.os.tag != .macos) return;
        if (s.native) |n| n.show(false);
    }

    pub fn setZoom(s: *Session, factor: f64) void {
        if (comptime builtin.os.tag != .macos) return;
        if (s.native) |n| n.setZoom(factor);
    }

    pub fn reload(s: *Session) void {
        const gpa = s.app.gpa;
        if (s.initialized) {
            const req_id = s.app.mcp_apps.teardown_seq;
            s.app.mcp_apps.teardown_seq += 1;
            if (host.buildTeardownRequest(gpa, req_id)) |msg| {
                defer gpa.free(msg);
                s.deliver(msg);
            } else |_| {}
        }
        s.initialized = false;
        s.loaded_into_native = false;
        s.fetchResource();
    }

    pub fn toggleDisplayMode(s: *Session) void {
        s.display_mode = if (s.display_mode == .inline_mode) .fullscreen else .inline_mode;
        s.app.view.strip.expanded = if (s.display_mode == .fullscreen) .host else null;
        if (s.initialized) s.pushHostContext();
        s.app.redraw();
    }

    pub fn syncTheme(s: *Session, k: theme.Colors) void {
        const fp = host.colorFingerprint(k);
        const acct_fp = host.accountFingerprint(resolveHostAccount(s.app, s.parent));
        s.theme_colors = k;
        if (fp == s.last_theme_hash and acct_fp == s.last_account_hash) return;
        s.last_theme_hash = fp;
        s.last_account_hash = acct_fp;
        if (s.initialized) s.pushHostContext();
    }

    fn pushHostContext(s: *Session) void {
        const msg = host.buildHostContextChangedNotification(
            s.app.gpa,
            s.theme_colors,
            s.display_mode,
            resolveHostAccount(s.app, s.parent),
        ) catch return;
        defer s.app.gpa.free(msg);
        s.deliver(msg);
    }

    pub fn deliver(s: *Session, json_msg: []const u8) void {
        if (s.deliver_override) |hook| {
            hook.func(hook.ctx, json_msg);
            return;
        }
        if (comptime builtin.os.tag == .macos) {
            if (s.native) |n| n.deliver(json_msg);
        }
    }

    fn setError(s: *Session, msg: []const u8) void {
        const gpa = s.app.gpa;
        if (s.err) |old| gpa.free(old);
        s.err = gpa.dupe(u8, msg) catch null;
    }

    fn clearError(s: *Session) void {
        if (s.err) |old| {
            s.app.gpa.free(old);
            s.err = null;
        }
    }

    fn isToolAllowed(s: *const Session, tool_name: []const u8) bool {
        for (s.allowed_app_tools) |allowed| {
            if (std.mem.eql(u8, allowed, tool_name)) return true;
        }
        return false;
    }

    fn loadShellIfReady(s: *Session) void {
        if (comptime builtin.os.tag != .macos) return;
        const n = s.native orelse return;
        const html = s.shell_html orelse return;
        if (s.loaded_into_native) return;
        const csp_str = s.shell_csp orelse host.buildShellCsp();
        var frame_refs: std.ArrayList([]const u8) = .empty;
        defer frame_refs.deinit(s.app.gpa);
        for (s.frame_domains) |d| frame_refs.append(s.app.gpa, d) catch return;
        n.loadShell(s.id, html, csp_str, frame_refs.items) catch {
            s.setError("Could not load isolated MCP App shell.");
            return;
        };
        s.loaded_into_native = true;
    }

    pub fn fetchResource(s: *Session) void {
        s.clearError();
        if (!s.app.engine.up()) {
            s.loading = false;
            s.setError("Engine not connected");
            s.app.redraw();
            return;
        }
        s.loading = true;
        const Params = struct {
            serverName: []const u8,
            resourceUri: []const u8,
            cwd: ?[]const u8 = null,
        };
        const req_id = s.app.engine.call(
            "McpAppFetchResource",
            Params{
                .serverName = s.server_name,
                .resourceUri = s.resource_uri,
                .cwd = s.cwd,
            },
            .of(App, s.app, onFetchReply),
        ) orelse {
            s.loading = false;
            s.setError("Engine not connected");
            s.app.redraw();
            return;
        };
        s.app.mcp_apps.pending_fetches.put(s.app.gpa, req_id, s.id) catch {};
        s.app.redraw();
    }

    fn deliverInitialPayloads(s: *Session) void {
        const gpa = s.app.gpa;
        if (s.tool_input_json) |raw_in| {
            if (host.buildToolInputNotification(gpa, raw_in)) |msg| {
                defer gpa.free(msg);
                s.deliver(msg);
            } else |_| {}
        }
        if (s.tool_result_json) |raw_res| {
            if (host.buildToolResultNotification(gpa, raw_res)) |msg| {
                defer gpa.free(msg);
                s.deliver(msg);
            } else |_| {}
        }
    }

    pub fn handleBridgeMessage(s: *Session, raw: []const u8) void {
        const gpa = s.app.gpa;
        var parsed = host.parseBridgeMessage(gpa, raw) catch return;
        defer parsed.deinit();

        const msg = parsed.msg;
        if (std.mem.eql(u8, msg.method, "ui/initialize")) {
            const id = msg.id orelse return;
            const reply = host.buildInitializeResult(
                gpa,
                id,
                s.theme_colors,
                s.display_mode,
                resolveHostAccount(s.app, s.parent),
            ) catch return;
            defer gpa.free(reply);
            s.deliver(reply);
            return;
        }

        if (std.mem.eql(u8, msg.method, "ui/notifications/initialized")) {
            s.initialized = true;
            s.deliverInitialPayloads();
            return;
        }

        if (std.mem.eql(u8, msg.method, "tools/call")) {
            const id = msg.id orelse return;
            const params_obj = if (msg.params) |p| (if (p == .object) p.object else null) else null;
            const name = if (params_obj) |po| switch (po.get("name") orelse json.Value.null) {
                .string => |st| if (st.len > 0) st else null,
                else => null,
            } else null;
            if (name == null) {
                s.replyError(id, host.rpc_err_invalid_params, "Missing tool name");
                return;
            }
            if (!s.isToolAllowed(name.?)) {
                s.replyError(id, host.rpc_err_invalid_params, "Tool is not permitted for MCP App calls");
                return;
            }
            const args_val: ?json.Value = if (params_obj) |po| po.get("arguments") else null;
            if (s.tool_call_override) |hook| {
                hook.func(hook.ctx, s, id, name.?, args_val);
                return;
            }
            if (!s.app.engine.up()) {
                s.replyError(id, -32000, "Engine not connected");
                return;
            }
            var owned_rpc_id = host.OwnedRpcId.dupe(gpa, id) catch return;
            const CallParams = struct {
                serverName: []const u8,
                toolName: []const u8,
                arguments: ?json.Value = null,
                cwd: ?[]const u8 = null,
            };
            const req_id = s.app.engine.call(
                "McpAppCallTool",
                CallParams{
                    .serverName = s.server_name,
                    .toolName = name.?,
                    .arguments = args_val,
                    .cwd = s.cwd,
                },
                .of(App, s.app, onToolCallReply),
            ) orelse {
                owned_rpc_id.deinit(gpa);
                s.replyError(id, -32000, "Engine not connected");
                return;
            };
            s.app.mcp_apps.pending_tool_calls.put(gpa, req_id, .{
                .session_id = s.id,
                .rpc_id = owned_rpc_id,
            }) catch {
                owned_rpc_id.deinit(gpa);
                s.replyError(id, host.rpc_err_internal, "Out of memory");
            };
            return;
        }

        if (std.mem.eql(u8, msg.method, "ui/update-model-context")) {
            s.updateModelContext(msg.params);
            if (msg.id) |id| s.replyEmptyOk(id);
            return;
        }

        if (std.mem.eql(u8, msg.method, "ui/open-link")) {
            const url: ?[]const u8 = if (msg.params) |p| switch (p) {
                .object => |po| if (po.get("url")) |uv| (if (uv == .string) uv.string else null) else null,
                else => null,
            } else null;
            if (url == null or !host.validateOpenLinkUrl(url.?)) {
                if (msg.id) |id| s.replyError(id, host.rpc_err_invalid_params, "Disallowed URL scheme or non-loopback HTTP link");
                return;
            }
            _ = @import("app_browser.zig").open_external_url(url.?);
            if (msg.id) |id| s.replyEmptyOk(id);
            return;
        }

        if (std.mem.eql(u8, msg.method, "ui/request-display-mode")) {
            const mode_str: ?[]const u8 = if (msg.params) |p| switch (p) {
                .object => |po| if (po.get("mode")) |mv| (if (mv == .string) mv.string else null) else null,
                else => null,
            } else null;
            const mode = if (mode_str) |ms| host.DisplayMode.parse(ms) else null;
            if (mode == null) {
                if (msg.id) |id| s.replyError(id, host.rpc_err_invalid_params, "Unsupported displayMode");
                return;
            }
            s.display_mode = mode.?;
            s.app.view.strip.expanded = if (s.display_mode == .fullscreen) .host else null;
            s.app.redraw();
            if (msg.id) |id| {
                const reply = host.buildRpcResultValue(gpa, id, .{ .mode = s.display_mode.asWireString() }) catch return;
                defer gpa.free(reply);
                s.deliver(reply);
            }
            return;
        }

        if (std.mem.eql(u8, msg.method, "ui/notifications/size-changed")) {
            if (msg.params) |p| if (p == .object) {
                if (p.object.get("height")) |hv| {
                    const h: ?f32 = switch (hv) {
                        .integer => |n| if (n >= 0) @as(f32, @floatFromInt(n)) else null,
                        .float => |f| if (std.math.isFinite(f) and f >= 0) @as(f32, @floatCast(f)) else null,
                        else => null,
                    };
                    if (h) |valid_h| {
                        s.preferred_height = @min(valid_h, 16384.0);
                    }
                }
            };
            return;
        }

        if (std.mem.eql(u8, msg.method, "ui/message")) {
            s.prefillComposerFromMessage(msg.params);
            if (msg.id) |id| {
                const reply = host.buildRpcResultValue(gpa, id, .{ .accepted = true }) catch return;
                defer gpa.free(reply);
                s.deliver(reply);
            }
            return;
        }

        if (msg.id) |id| {
            s.replyError(id, host.rpc_err_method_not_found, "Method not found");
        }
    }

    fn prefillComposerFromMessage(s: *Session, params: ?json.Value) void {
        const gpa = s.app.gpa;
        const p = params orelse return;
        if (p != .object) return;
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(gpa);

        if (p.object.get("content")) |content| switch (content) {
            .string => |st| text_buf.appendSlice(gpa, st) catch return,
            .array => |arr| for (arr.items) |item| {
                if (item != .object) continue;
                if (item.object.get("text")) |tv| if (tv == .string) {
                    if (text_buf.items.len > 0) text_buf.appendSlice(gpa, "\n") catch return;
                    text_buf.appendSlice(gpa, tv.string) catch return;
                    if (text_buf.items.len >= 4096) break;
                };
            },
            else => {},
        };
        if (text_buf.items.len == 0) return;
        const clamped = text_buf.items[0..@min(text_buf.items.len, 4096)];
        s.app.composer.set(clamped);
        s.app.composer.want_caret = clamped.len;
        s.app.view.focus_composer = true;
        if (s.display_mode == .fullscreen) {
            s.display_mode = .inline_mode;
            s.app.view.strip.expanded = null;
        }
        s.app.redraw();
    }

    fn updateModelContext(s: *Session, params: ?json.Value) void {
        const gpa = s.app.gpa;
        const p = params orelse return;
        if (p != .object) return;
        var summary: std.ArrayList(u8) = .empty;
        defer summary.deinit(gpa);

        if (p.object.get("content")) |content| switch (content) {
            .string => |st| summary.appendSlice(gpa, st) catch return,
            .array => |arr| for (arr.items) |item| {
                if (item != .object) continue;
                if (item.object.get("text")) |tv| if (tv == .string) {
                    if (summary.items.len > 0) summary.appendSlice(gpa, " ") catch return;
                    summary.appendSlice(gpa, tv.string) catch return;
                    if (summary.items.len >= 512) break;
                };
            },
            else => {},
        };

        if (summary.items.len == 0) {
            if (p.object.get("structuredContent")) |_| {
                summary.appendSlice(gpa, "Structured context updated") catch return;
            }
        }
        if (summary.items.len == 0) return;

        const max_len = @min(summary.items.len, 512);
        const duped = gpa.dupe(u8, summary.items[0..max_len]) catch return;
        if (s.context_note) |old| gpa.free(old);
        s.context_note = duped;
        s.app.redraw();
    }

    fn replyEmptyOk(s: *Session, id: host.RpcId) void {
        const gpa = s.app.gpa;
        const EmptyObj = struct {};
        const msg = host.buildRpcResultValue(gpa, id, EmptyObj{}) catch return;
        defer gpa.free(msg);
        s.deliver(msg);
    }

    fn replyError(s: *Session, id: host.RpcId, code: i32, text: []const u8) void {
        const gpa = s.app.gpa;
        const msg = host.buildRpcError(gpa, id, code, text) catch return;
        defer gpa.free(msg);
        s.deliver(msg);
    }

    fn applyResourceResponse(s: *Session, v: json.Value) !void {
        if (v != .object) return error.InvalidResponse;
        const gpa = s.app.gpa;
        const o = v.object;
        const html = switch (o.get("html") orelse return error.InvalidResponse) {
            .string => |st| if (st.len > 0 and st.len <= host.max_html_bytes) st else return error.InvalidResponse,
            else => return error.InvalidResponse,
        };

        var res_domains: std.ArrayList([]const u8) = .empty;
        defer res_domains.deinit(gpa);
        var conn_domains: std.ArrayList([]const u8) = .empty;
        defer conn_domains.deinit(gpa);
        var frame_domains_in: std.ArrayList([]const u8) = .empty;
        defer frame_domains_in.deinit(gpa);

        if (o.get("csp")) |csp_val| if (csp_val == .object) {
            const co = csp_val.object;
            try collectStringSlice(gpa, &res_domains, co.get("resourceDomains"));
            try collectStringSlice(gpa, &conn_domains, co.get("connectDomains"));
            try collectStringSlice(gpa, &frame_domains_in, co.get("frameDomains"));
        };

        const csp: host.Csp = .{
            .resource_domains = res_domains.items,
            .connect_domains = conn_domains.items,
            .frame_domains = frame_domains_in.items,
        };

        const shell = try host.buildHostShellHtml(gpa, html, csp);
        errdefer gpa.free(shell);
        const shell_csp = try host.buildShellHeaderCsp(gpa, csp);
        errdefer gpa.free(shell_csp);

        var owned_frames: std.ArrayList([]u8) = .empty;
        errdefer {
            for (owned_frames.items) |d| gpa.free(d);
            owned_frames.deinit(gpa);
        }
        for (frame_domains_in.items) |d| {
            if (host.validateCspOrigin(d)) {
                try owned_frames.append(gpa, try gpa.dupe(u8, d));
            }
        }

        var owned_tools: std.ArrayList([]u8) = .empty;
        errdefer {
            for (owned_tools.items) |t| gpa.free(t);
            owned_tools.deinit(gpa);
        }
        if (o.get("allowedAppTools")) |tv| if (tv == .array) {
            for (tv.array.items) |item| {
                if (item == .string and item.string.len > 0) {
                    try owned_tools.append(gpa, try gpa.dupe(u8, item.string));
                }
            }
        };

        s.clearFetchedResource();
        s.shell_html = shell;
        s.shell_csp = shell_csp;
        s.frame_domains = try owned_frames.toOwnedSlice(gpa);
        s.allowed_app_tools = try owned_tools.toOwnedSlice(gpa);
        s.loading = false;
        s.clearError();
        s.loadShellIfReady();
    }
};

fn collectStringSlice(gpa: Allocator, list: *std.ArrayList([]const u8), maybe_val: ?json.Value) !void {
    const val = maybe_val orelse return;
    if (val != .array) return;
    for (val.array.items) |item| {
        if (item == .string and item.string.len > 0) {
            try list.append(gpa, item.string);
        }
    }
}

fn onNativeMessage(ctx: *anyopaque, raw: []const u8) void {
    const s: *Session = @ptrCast(@alignCast(ctx));
    s.handleBridgeMessage(raw);
}

fn onNativeState(ctx: *anyopaque) void {
    const s: *Session = @ptrCast(@alignCast(ctx));
    if (comptime builtin.os.tag == .macos) {
        if (s.native) |n| {
            if (n.error_len > 0) s.setError(n.error_text[0..n.error_len]);
        }
    }
    s.app.redraw();
}

fn onFetchReply(a: *App, id: u64, r: rpc.Reply) void {
    const kv = a.mcp_apps.pending_fetches.fetchRemove(id) orelse return;
    const s = a.mcp_apps.sessions.get(kv.value) orelse return;
    switch (r) {
        .err => |msg| {
            s.loading = false;
            s.setError(if (std.mem.eql(u8, msg, "not connected")) "Engine not connected" else msg);
            a.redraw();
        },
        .ok => |v| {
            s.applyResourceResponse(v) catch {
                s.loading = false;
                s.setError("MCP App resource payload was invalid.");
            };
            a.redraw();
        },
        else => {},
    }
}

fn onToolCallReply(a: *App, id: u64, r: rpc.Reply) void {
    const kv = a.mcp_apps.pending_tool_calls.fetchRemove(id) orelse return;
    var pending = kv.value;
    defer pending.rpc_id.deinit(a.gpa);

    const s = a.mcp_apps.sessions.get(pending.session_id) orelse return;
    switch (r) {
        .err => |msg| {
            s.replyError(pending.rpc_id.asRef(), -32000, msg);
        },
        .ok => |v| {
            const reply = host.buildRpcResultValue(a.gpa, pending.rpc_id.asRef(), v) catch return;
            defer a.gpa.free(reply);
            s.deliver(reply);
        },
        else => {},
    }
}

fn resolveCwd(a: *const App, parent: []const u8) ?[]const u8 {
    const ch = a.findChat(parent) orelse return null;
    if (ch.cwd) |c| if (c.len > 0) return c;
    if (a.findSpace(ch.space_id)) |sp| if (sp.path.len > 0) return sp.path;
    return null;
}

pub fn resolveHostAccount(a: *const App, parent: []const u8) host.HostAccount {
    const ch = a.findChat(parent);
    return .{
        .codegraff_email = if (a.account.codegraff.signed_in) a.account.codegraff.who else null,
        .harness_email = if (a.account.user) |*u| (if (u.email.len > 0) u.email else null) else null,
        .active_harness = if (ch) |c| c.harness else null,
        .active_model = if (ch) |c| c.model else null,
    };
}

/// Discovers an MCP server's interactive `ui://` apps via `McpAppList` and opens the first one.
pub fn openServerApp(a: *App, server_name: []const u8, cwd: ?[]const u8) void {
    const parent = a.selected orelse {
        a.setNotice("Open or select a chat first to launch an MCP App.");
        a.redraw();
        return;
    };
    if (!a.engine.up()) {
        a.setNotice("Sign in or start Harness engine to launch MCP Apps.");
        a.redraw();
        return;
    }
    const ListParams = struct {
        serverName: []const u8,
        cwd: ?[]const u8 = null,
    };
    const req_id = a.engine.call(
        "McpAppList",
        ListParams{ .serverName = server_name, .cwd = cwd },
        .of(App, a, onListAppsReply),
    ) orelse {
        a.setNotice("Could not query MCP App list from engine.");
        a.redraw();
        return;
    };
    const parent_d = a.gpa.dupe(u8, parent) catch return;
    const server_d = a.gpa.dupe(u8, server_name) catch {
        a.gpa.free(parent_d);
        return;
    };
    a.mcp_apps.pending_lists.put(a.gpa, req_id, .{
        .parent = parent_d,
        .server_name = server_d,
    }) catch {
        a.gpa.free(parent_d);
        a.gpa.free(server_d);
    };
}

fn onListAppsReply(a: *App, id: u64, r: rpc.Reply) void {
    const kv = a.mcp_apps.pending_lists.fetchRemove(id) orelse return;
    defer {
        a.gpa.free(kv.value.parent);
        a.gpa.free(kv.value.server_name);
    }
    switch (r) {
        .err => |msg| {
            a.setNotice(msg);
            a.redraw();
        },
        .ok => |v| {
            if (v != .array or v.array.items.len == 0) {
                a.setNotice("This MCP server has no interactive ui:// apps.");
                a.redraw();
                return;
            }
            const first = v.array.items[0];
            if (first != .object) return;
            const o = first.object;
            const uri = switch (o.get("resourceUri") orelse return) {
                .string => |s| s,
                else => return,
            };
            const title_opt: ?[]const u8 = if (o.get("title")) |tv| switch (tv) {
                .string => |s| s,
                else => null,
            } else null;
            var tool_name: []const u8 = "";
            if (o.get("toolNames")) |tnv| if (tnv == .array and tnv.array.items.len > 0) {
                if (tnv.array.items[0] == .string) tool_name = tnv.array.items[0].string;
            };
            a.view.settings_open = false;
            open(a, kv.value.parent, .{
                .server_name = kv.value.server_name,
                .resource_uri = uri,
                .tool_name = tool_name,
                .title = title_opt,
            });
        },
        else => {},
    }
}

pub fn openFromPart(a: *App, parent: []const u8, part: *const PartData) void {
    open(a, parent, .{
        .server_name = part.server_name,
        .resource_uri = part.resource_uri,
        .tool_name = part.tool_name,
        .title = part.title,
        .tool_input_json = part.tool_input_json,
        .tool_result_json = part.tool_result_json,
    });
}

pub fn open(a: *App, parent: []const u8, spec: LaunchSpec) void {
    const app_browser = @import("app_browser.zig");
    const owner = app_browser.sourceOwner(a, parent) orelse return;

    for (a.panels.tabs.items, 0..) |tab, idx| {
        const existing = tab.browser orelse continue;
        if (tab.kind != .browser) continue;
        const s = existing.mcp_app orelse continue;
        if (!std.mem.eql(u8, s.parent, parent)) continue;
        if (!std.mem.eql(u8, s.server_name, spec.server_name)) continue;
        if (!std.mem.eql(u8, s.resource_uri, spec.resource_uri)) continue;

        if (spec.title) |t| if (t.len > 0) {
            if (a.gpa.dupe(u8, t)) |owned_t| {
                a.gpa.free(s.title);
                s.title = owned_t;
                existing.title.set(owned_t);
            } else |_| {}
        };
        if (spec.tool_input_json) |raw_in| {
            if (a.gpa.dupe(u8, raw_in)) |owned_in| {
                if (s.tool_input_json) |old| a.gpa.free(old);
                s.tool_input_json = owned_in;
            } else |_| {}
        }
        if (spec.tool_result_json) |raw_res| {
            if (a.gpa.dupe(u8, raw_res)) |owned_res| {
                if (s.tool_result_json) |old| a.gpa.free(old);
                s.tool_result_json = owned_res;
            } else |_| {}
        }
        if (s.initialized) s.deliverInitialPayloads();
        a.panels.active = idx;
        a.panels.host_open = true;
        a.view.strip.focused = .host;
        a.redraw();
        return;
    }

    const b = Browser.create(a, parent) catch return;
    const s = Session.create(a, parent, spec, resolveCwd(a, parent)) catch {
        b.destroy();
        return;
    };
    b.mcp_app = s;
    b.pending_source = owner;
    b.url = a.gpa.dupe(u8, spec.resource_uri) catch {
        b.destroy();
        return;
    };
    b.address.set(b.url);
    b.title.set(s.title);
    b.focus_address = false;
    if (a.panels.pending_browser) |old| old.destroy();
    a.panels.pending_browser = b;
    s.fetchResource();
    a.redraw();
}

test "PartData.parse decodes and frees camelCase SEP-1865 doc payloads cleanly" {
    const testing = std.testing;
    var parsed = try json.parseFromSlice(json.Value, testing.allocator,
        \\{
        \\  "serverName": "review-studio",
        \\  "resourceUri": "ui://review/studio.html",
        \\  "toolName": "open_studio",
        \\  "title": "Review Studio",
        \\  "toolInput": {"screenId": "home"},
        \\  "toolResult": {"content": [{"type": "text", "text": "ok"}]}
        \\}
    , .{});
    defer parsed.deinit();

    var pd = (try PartData.parse(testing.allocator, parsed.value)).?;
    defer pd.deinit(testing.allocator);
    try testing.expectEqualStrings("review-studio", pd.server_name);
    try testing.expectEqualStrings("ui://review/studio.html", pd.resource_uri);
    try testing.expectEqualStrings("open_studio", pd.tool_name);
    try testing.expectEqualStrings("Review Studio", pd.title.?);
    try testing.expect(pd.tool_input_json != null);
    try testing.expect(pd.tool_result_json != null);
}

test "Session bridge handles SEP-1865 allowlists, link validation, context, displayMode, and errors" {
    const testing = std.testing;
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();

    const s = try Session.create(&a, "chat-1", .{
        .server_name = "studio",
        .resource_uri = "ui://studio/main.html",
        .tool_name = "open_studio",
        .title = "Studio",
        .tool_input_json = "{\"node\":\"hero\"}",
        .tool_result_json = "{\"content\":[],\"structuredContent\":{\"ok\":true}}",
    }, null);
    defer s.destroy();

    s.allowed_app_tools = blk: {
        const list = try testing.allocator.alloc([]u8, 1);
        list[0] = try testing.allocator.dupe(u8, "allowed_tool");
        break :blk list;
    };

    const Capture = struct {
        msgs: std.ArrayList([]u8) = .empty,
        gpa: Allocator,

        fn record(ctx: *anyopaque, raw: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const copy = self.gpa.dupe(u8, raw) catch return;
            self.msgs.append(self.gpa, copy) catch self.gpa.free(copy);
        }

        fn deinit(self: *@This()) void {
            for (self.msgs.items) |m| self.gpa.free(m);
            self.msgs.deinit(self.gpa);
        }
    };

    var cap: Capture = .{ .gpa = testing.allocator };
    defer cap.deinit();
    s.deliver_override = .{ .ctx = &cap, .func = Capture.record };

    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","id":1,"method":"ui/initialize","params":{}}
    );
    try testing.expectEqual(@as(usize, 1), cap.msgs.items.len);
    try testing.expect(std.mem.indexOf(u8, cap.msgs.items[0], "\"protocolVersion\":\"2026-01-26\"") != null);

    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","method":"ui/notifications/initialized"}
    );
    try testing.expect(s.initialized);
    try testing.expectEqual(@as(usize, 3), cap.msgs.items.len);
    try testing.expect(std.mem.indexOf(u8, cap.msgs.items[1], "ui/notifications/tool-input") != null);
    try testing.expect(std.mem.indexOf(u8, cap.msgs.items[2], "ui/notifications/tool-result") != null);

    // Disallowed tool fails with JSON-RPC -32602.
    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"forbidden_tool","arguments":{}}}
    );
    try testing.expect(std.mem.indexOf(u8, cap.msgs.items[3], "-32602") != null);

    // Model context & size update.
    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","id":3,"method":"ui/update-model-context","params":{"content":[{"type":"text","text":"Selected card 2"}]}}
    );
    try testing.expectEqualStrings("Selected card 2", s.context_note.?);

    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":420}}
    );
    try testing.expectEqual(@as(?f32, 420.0), s.preferred_height);

    // Unsafe open-link is rejected with -32602; safe https link succeeds.
    const MockOpen = struct {
        var last_buf: [256]u8 = undefined;
        var last_len: usize = 0;
        fn openUrl(url: []const u8) bool {
            last_len = @min(url.len, last_buf.len);
            @memcpy(last_buf[0..last_len], url[0..last_len]);
            return true;
        }
        fn last() ?[]const u8 {
            return if (last_len > 0) last_buf[0..last_len] else null;
        }
    };
    MockOpen.last_len = 0;
    const prev_opener = @import("app_browser.zig").open_external_url;
    defer @import("app_browser.zig").open_external_url = prev_opener;
    @import("app_browser.zig").open_external_url = MockOpen.openUrl;

    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","id":4,"method":"ui/open-link","params":{"url":"javascript:alert(1)"}}
    );
    try testing.expect(MockOpen.last() == null);
    try testing.expect(std.mem.indexOf(u8, cap.msgs.items[5], "-32602") != null);

    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","id":5,"method":"ui/open-link","params":{"url":"https://docs.example.com/ref"}}
    );
    try testing.expectEqualStrings("https://docs.example.com/ref", MockOpen.last().?);

    // Display mode switches cleanly and sets fullscreen expansion.
    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","id":6,"method":"ui/request-display-mode","params":{"mode":"fullscreen"}}
    );
    try testing.expectEqual(host.DisplayMode.fullscreen, s.display_mode);
    try testing.expect(a.view.strip.expanded != null);

    // ui/message prefills composer and restores inline mode.
    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","id":7,"method":"ui/message","params":{"role":"user","content":[{"type":"text","text":"Run stage locally in NanoHarness"}]}}
    );
    try testing.expectEqualStrings("Run stage locally in NanoHarness", a.composer.text());
    try testing.expectEqual(host.DisplayMode.inline_mode, s.display_mode);

    // Unknown method returns -32601.
    s.handleBridgeMessage(
        \\{"jsonrpc":"2.0","id":8,"method":"ui/does-not-exist","params":{}}
    );
    try testing.expect(std.mem.indexOf(u8, cap.msgs.items[cap.msgs.items.len - 1], "-32601") != null);
}
