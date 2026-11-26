//! Isolated macOS WKWebView host for SEP-1865 MCP Apps.
//! Keeps `browser_native.zig` strictly zero-IPC by isolating the
//! `HarnessNanoMcpAppDelegate` scheme & script handler in this module.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const host = @import("mcp_app_host.zig");

pub const Events = struct {
    ctx: *anyopaque,
    on_message: *const fn (*anyopaque, []const u8) void,
    on_state: *const fn (*anyopaque) void,
};

pub const McpAppNative = if (builtin.os.tag != .macos)
    struct {
        loading: bool = false,
        visible: bool = false,
        zoom: f64 = 1.0,
        error_len: usize = 0,
        error_text: [512]u8 = undefined,

        pub fn create(_: std.mem.Allocator, _: Events) !*@This() {
            return error.UnsupportedPlatform;
        }
        pub fn destroy(_: *@This()) void {}
        pub fn loadShell(_: *@This(), _: u64, _: []const u8, _: []const u8, _: []const []const u8) !void {}
        pub fn deliver(_: *@This(), _: []const u8) void {}
        pub fn mount(_: *@This(), _: anytype, _: nanoui.ui.Rect) void {}
        pub fn show(_: *@This(), _: bool) void {}
        pub fn setZoom(_: *@This(), _: f64) void {}
        pub fn reload(_: *@This()) void {}
    }
else
    MacOsMcpAppNative;

const objc = nanoui.objc;

const MacOsMcpAppNative = struct {
    gpa: std.mem.Allocator,
    view: objc.Object,
    delegate: objc.Object,
    events: Events,
    host_url: ?[]u8 = null,
    shell_html: ?[]u8 = null,
    shell_csp: ?[]u8 = null,
    frame_domains: [][]u8 = &.{},
    loading: bool = false,
    visible: bool = false,
    attached: bool = false,
    zoom: f64 = 1.0,
    error_text: [512]u8 = undefined,
    error_len: usize = 0,
    rect: ?nanoui.ui.Rect = null,

    pub const min_zoom: f64 = 0.25;
    pub const max_zoom: f64 = 4.0;
    const handler_name = "mcpApp";
    const scheme_name = "mcp-app";

    pub fn create(gpa: std.mem.Allocator, events: Events) !*MacOsMcpAppNative {
        const pool = objc.Pool.push();
        defer pool.pop();

        const self = try gpa.create(MacOsMcpAppNative);
        errdefer gpa.destroy(self);

        const cls = objc.defineClass(.{
            .name = "HarnessNanoMcpAppDelegate",
            .protocols = &.{ "WKNavigationDelegate", "WKUIDelegate", "WKURLSchemeHandler", "WKScriptMessageHandler" },
            .methods = &.{
                .{ .name = "webView:decidePolicyForNavigationAction:decisionHandler:", .imp = &decide, .types = "v@:@@@?" },
                .{ .name = "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", .imp = &createPopup, .types = "@@:@@@@" },
                .{ .name = "webView:didStartProvisionalNavigation:", .imp = &started, .types = "v@:@@" },
                .{ .name = "webView:didFinishNavigation:", .imp = &finished, .types = "v@:@@" },
                .{ .name = "webView:didFailNavigation:withError:", .imp = &failed, .types = "v@:@@@" },
                .{ .name = "webView:didFailProvisionalNavigation:withError:", .imp = &failed, .types = "v@:@@@" },
                .{ .name = "webView:startURLSchemeTask:", .imp = &schemeStart, .types = "v@:@@" },
                .{ .name = "webView:stopURLSchemeTask:", .imp = &schemeStop, .types = "v@:@@" },
                .{ .name = "userContentController:didReceiveScriptMessage:", .imp = &didReceiveScriptMessage, .types = "v@:@@" },
            },
        });
        const delegate = objc.msg(objc.Object, cls, "new", .{});
        errdefer objc.release(delegate);

        const config = objc.new("WKWebViewConfiguration");
        defer objc.release(config);

        const store = objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "nonPersistentDataStore", .{});
        objc.msg(void, config, "setWebsiteDataStore:", .{store});
        objc.msg(void, config, "setURLSchemeHandler:forURLScheme:", .{ delegate, objc.nsString(scheme_name) });

        const ucc = objc.msg(objc.Object, config, "userContentController", .{});
        objc.msg(void, ucc, "addScriptMessageHandler:name:", .{ delegate, objc.nsString(handler_name) });

        const view = objc.msg(objc.Object, objc.alloc("WKWebView"), "initWithFrame:configuration:", .{ objc.CGRect{}, config });
        self.* = .{
            .gpa = gpa,
            .view = view,
            .delegate = delegate,
            .events = events,
        };
        objc.setZig(delegate, self);
        objc.msg(void, view, "setNavigationDelegate:", .{delegate});
        objc.msg(void, view, "setUIDelegate:", .{delegate});
        objc.msg(void, view, "setAllowsBackForwardNavigationGestures:", .{objc.NO});
        objc.msg(void, view, "setHidden:", .{objc.YES});
        return self;
    }

    pub fn destroy(s: *MacOsMcpAppNative) void {
        const pool = objc.Pool.push();
        defer pool.pop();

        // Break WKUserContentController's strong retain on delegate and ignore late callbacks.
        objc.setZig(s.delegate, null);
        const cfg = objc.msg(objc.Object, s.view, "configuration", .{});
        const ucc = objc.msg(objc.Object, cfg, "userContentController", .{});
        objc.msg(void, ucc, "removeScriptMessageHandlerForName:", .{objc.nsString(handler_name)});
        objc.msg(void, s.view, "setNavigationDelegate:", .{@as(?objc.Object, null)});
        objc.msg(void, s.view, "setUIDelegate:", .{@as(?objc.Object, null)});
        objc.msg(void, s.view, "stopLoading", .{});
        objc.msg(void, s.view, "removeFromSuperview", .{});
        objc.release(s.view);
        objc.release(s.delegate);
        s.freeShellBuffers();
        s.gpa.destroy(s);
    }

    fn freeShellBuffers(s: *MacOsMcpAppNative) void {
        if (s.host_url) |u| s.gpa.free(u);
        if (s.shell_html) |h| s.gpa.free(h);
        if (s.shell_csp) |c| s.gpa.free(c);
        for (s.frame_domains) |d| s.gpa.free(d);
        if (s.frame_domains.len > 0) s.gpa.free(s.frame_domains);
        s.host_url = null;
        s.shell_html = null;
        s.shell_csp = null;
        s.frame_domains = &.{};
    }

    pub fn loadShell(
        s: *MacOsMcpAppNative,
        session_id: u64,
        shell_html: []const u8,
        shell_csp: []const u8,
        frame_domains: []const []const u8,
    ) !void {
        const pool = objc.Pool.push();
        defer pool.pop();

        const next_url = try std.fmt.allocPrint(s.gpa, "mcp-app://host/{d}", .{session_id});
        errdefer s.gpa.free(next_url);
        const next_html = try s.gpa.dupe(u8, shell_html);
        errdefer s.gpa.free(next_html);
        const next_csp = try s.gpa.dupe(u8, shell_csp);
        errdefer s.gpa.free(next_csp);

        var next_frames: std.ArrayList([]u8) = .empty;
        errdefer {
            for (next_frames.items) |d| s.gpa.free(d);
            next_frames.deinit(s.gpa);
        }
        for (frame_domains) |raw| {
            const clean = std.mem.trim(u8, raw, " \t\r\n");
            if (!host.validateCspOrigin(clean)) continue;
            try next_frames.append(s.gpa, try s.gpa.dupe(u8, clean));
        }
        const owned_frames = try next_frames.toOwnedSlice(s.gpa);

        s.freeShellBuffers();
        s.host_url = next_url;
        s.shell_html = next_html;
        s.shell_csp = next_csp;
        s.frame_domains = owned_frames;
        s.error_len = 0;

        const ns_url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(next_url)}) orelse return error.InvalidUrl;
        const req = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{ns_url});
        _ = objc.msg(?objc.Object, s.view, "loadRequest:", .{req});
    }

    /// Delivers one JSON-RPC message safely across ObjC/JS using base64 + UTF-8 `TextDecoder`.
    pub fn deliver(s: *MacOsMcpAppNative, json_msg: []const u8) void {
        if (json_msg.len == 0) return;
        const pool = objc.Pool.push();
        defer pool.pop();

        const b64_len = std.base64.standard.Encoder.calcSize(json_msg.len);
        const prefix = "window.__mcpHostDeliver&&window.__mcpHostDeliver('";
        const suffix = "');";
        const full = s.gpa.alloc(u8, prefix.len + b64_len + suffix.len) catch return;
        defer s.gpa.free(full);

        @memcpy(full[0..prefix.len], prefix);
        _ = std.base64.standard.Encoder.encode(full[prefix.len .. prefix.len + b64_len], json_msg);
        @memcpy(full[prefix.len + b64_len ..], suffix);

        objc.msg(void, s.view, "evaluateJavaScript:completionHandler:", .{ objc.nsString(full), @as(?*anyopaque, null) });
    }

    pub fn mount(s: *MacOsMcpAppNative, parent: objc.Object, rect: nanoui.ui.Rect) void {
        if (!s.attached) {
            objc.msg(void, parent, "addSubview:", .{s.view});
            s.attached = true;
        }
        if (s.rect == null or !std.meta.eql(s.rect.?, rect)) {
            const bounds = objc.msg(objc.CGRect, parent, "bounds", .{});
            const flipped = objc.msg(objc.BOOL, parent, "isFlipped", .{});
            objc.msg(void, s.view, "setFrame:", .{objc.CGRect{
                .origin = .{ .x = rect.x, .y = if (flipped) rect.y else bounds.size.height - rect.y - rect.h },
                .size = .{ .width = rect.w, .height = rect.h },
            }});
            s.rect = rect;
        }
        s.show(true);
    }

    pub fn show(s: *MacOsMcpAppNative, visible: bool) void {
        if (s.visible == visible) return;
        objc.msg(void, s.view, "setHidden:", .{if (visible) objc.NO else objc.YES});
        s.visible = visible;
    }

    pub fn setZoom(s: *MacOsMcpAppNative, factor: f64) void {
        const clamped = std.math.clamp(factor, min_zoom, max_zoom);
        s.zoom = clamped;
        objc.msg(void, s.view, "setPageZoom:", .{@as(objc.CGFloat, clamped)});
    }

    pub fn reload(s: *MacOsMcpAppNative) void {
        if (s.host_url) |u| {
            const pool = objc.Pool.push();
            defer pool.pop();
            const ns_url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(u)}) orelse return;
            const req = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{ns_url});
            _ = objc.msg(?objc.Object, s.view, "loadRequest:", .{req});
        }
    }

    fn isSubframeAllowed(s: *const MacOsMcpAppNative, address: []const u8) bool {
        if (std.mem.eql(u8, address, "about:srcdoc") or std.mem.eql(u8, address, "about:blank")) return true;
        if (!std.mem.startsWith(u8, address, "https://")) return false;
        for (s.frame_domains) |origin| {
            if (host.urlMatchesOrigin(address, origin)) return true;
        }
        return false;
    }

    fn notifyState(s: *MacOsMcpAppNative) void {
        s.events.on_state(s.events.ctx);
    }
};

const Decision = extern struct {
    isa: ?*anyopaque,
    flags: i32,
    reserved: i32,
    invoke: *const fn (*const Decision, isize) callconv(.c) void,
};

fn decide(delegate: objc.Object, _: objc.SEL, _: objc.Object, action: objc.Object, handler: *const Decision) callconv(.c) void {
    const s = objc.getZig(MacOsMcpAppNative, delegate) orelse return handler.invoke(handler, 0);
    const pool = objc.Pool.push();
    defer pool.pop();
    const request = objc.msg(objc.Object, action, "request", .{});
    const url = objc.msg(?objc.Object, request, "URL", .{}) orelse return handler.invoke(handler, 0);
    const address = objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
    const frame = objc.msg(?objc.Object, action, "targetFrame", .{});
    const main = if (frame) |f| objc.msg(objc.BOOL, f, "isMainFrame", .{}) else true;

    const allowed = if (main) blk: {
        const expected = s.host_url orelse break :blk false;
        break :blk std.mem.eql(u8, address, expected);
    } else s.isSubframeAllowed(address);

    handler.invoke(handler, if (allowed) 1 else 0);
}

fn createPopup(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, _: objc.Object, _: objc.Object) callconv(.c) ?objc.Object {
    return null;
}

fn started(delegate: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(MacOsMcpAppNative, delegate) orelse return;
    s.loading = true;
    s.error_len = 0;
    s.notifyState();
}

fn finished(delegate: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(MacOsMcpAppNative, delegate) orelse return;
    s.loading = false;
    s.notifyState();
}

fn failed(delegate: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object, err: objc.Object) callconv(.c) void {
    const s = objc.getZig(MacOsMcpAppNative, delegate) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const text = objc.fromNSString(objc.msg(?objc.Object, err, "localizedDescription", .{}));
    s.error_len = @min(text.len, s.error_text.len);
    @memcpy(s.error_text[0..s.error_len], text[0..s.error_len]);
    s.loading = false;
    s.notifyState();
}

fn schemeStart(delegate: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object) callconv(.c) void {
    const s = objc.getZig(MacOsMcpAppNative, delegate) orelse return schemeFail(task);
    const pool = objc.Pool.push();
    defer pool.pop();
    const request = objc.msg(objc.Object, task, "request", .{});
    const url = objc.msg(?objc.Object, request, "URL", .{}) orelse return schemeFail(task);
    const address = objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
    const expected = s.host_url orelse return schemeFail(task);
    if (!std.mem.eql(u8, address, expected)) return schemeFail(task);
    const body = s.shell_html orelse return schemeFail(task);
    const csp_val = s.shell_csp orelse host.buildShellCsp();

    const keys = [_]objc.Object{
        objc.nsString("Content-Type"),
        objc.nsString("Content-Security-Policy"),
        objc.nsString("Cache-Control"),
    };
    const values = [_]objc.Object{
        objc.nsString("text/html; charset=utf-8"),
        objc.nsString(csp_val),
        objc.nsString("no-store"),
    };
    const headers = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, keys.len) });
    const response = objc.msg(objc.Object, objc.alloc("NSHTTPURLResponse"), "initWithURL:statusCode:HTTPVersion:headerFields:", .{ url, @as(objc.NSInteger, 200), objc.nsString("HTTP/1.1"), headers });
    defer objc.release(response);
    objc.msg(void, task, "didReceiveResponse:", .{response});
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ body.ptr, @as(objc.NSUInteger, body.len) });
    objc.msg(void, task, "didReceiveData:", .{data});
    objc.msg(void, task, "didFinish", .{});
}

fn schemeFail(task: objc.Object) void {
    const err = objc.msg(objc.Object, objc.class("NSError"), "errorWithDomain:code:userInfo:", .{ objc.nsString("HarnessNanoMcpApp"), @as(objc.NSInteger, 1), @as(?objc.Object, null) });
    objc.msg(void, task, "didFailWithError:", .{err});
}

fn schemeStop(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object) callconv(.c) void {}

fn didReceiveScriptMessage(delegate: objc.Object, _: objc.SEL, _: objc.Object, message: objc.Object) callconv(.c) void {
    const s = objc.getZig(MacOsMcpAppNative, delegate) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();

    const frame = objc.msg(?objc.Object, message, "frameInfo", .{}) orelse return;
    if (!objc.msg(objc.BOOL, frame, "isMainFrame", .{})) return;
    const req = objc.msg(?objc.Object, frame, "request", .{}) orelse return;
    const url = objc.msg(?objc.Object, req, "URL", .{}) orelse return;
    const addr = objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
    const expected = s.host_url orelse return;
    if (!std.mem.eql(u8, addr, expected)) return;

    const body = objc.msg(?objc.Object, message, "body", .{}) orelse return;
    if (!objc.msg(objc.BOOL, body, "isKindOfClass:", .{objc.class("NSString")})) return;
    const text = objc.fromNSString(body);
    if (text.len == 0 or text.len > host.max_bridge_message_bytes) return;
    s.events.on_message(s.events.ctx, text);
}
