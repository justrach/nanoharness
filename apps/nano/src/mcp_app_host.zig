//! Pure SEP-1865 (`2026-01-26`) MCP Apps host protocol, CSP sanitizer/builder,
//! theme CSS variable mapper, and isolated `srcdoc` bridge HTML generator.
const std = @import("std");
const nanoui = @import("nanoui");
const theme = @import("theme.zig");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const protocol_version = "2026-01-26";
pub const host_name = "NanoHarness";
pub const host_version = "0.2.0";
pub const max_bridge_message_bytes: usize = 512 * 1024;
pub const max_html_bytes: usize = 4 * 1024 * 1024;

pub const rpc_err_method_not_found: i32 = -32601;
pub const rpc_err_invalid_params: i32 = -32602;
pub const rpc_err_internal: i32 = -32603;

pub const DisplayMode = enum {
    inline_mode,
    fullscreen,

    pub fn asWireString(self: DisplayMode) []const u8 {
        return switch (self) {
            .inline_mode => "inline",
            .fullscreen => "fullscreen",
        };
    }

    pub fn parse(raw: []const u8) ?DisplayMode {
        if (std.mem.eql(u8, raw, "inline")) return .inline_mode;
        if (std.mem.eql(u8, raw, "fullscreen")) return .fullscreen;
        return null;
    }
};

pub const Csp = struct {
    resource_domains: []const []const u8 = &.{},
    connect_domains: []const []const u8 = &.{},
    frame_domains: []const []const u8 = &.{},
};

pub const HostAccount = struct {
    codegraff_email: ?[]const u8 = null,
    harness_email: ?[]const u8 = null,
    active_harness: ?[]const u8 = null,
    active_model: ?[]const u8 = null,
};

const WireHostAccount = struct {
    codegraffEmail: ?[]const u8 = null,
    harnessEmail: ?[]const u8 = null,
    activeHarness: ?[]const u8 = null,
    activeModel: ?[]const u8 = null,
};

pub fn accountFingerprint(acct: HostAccount) u64 {
    var h = std.hash.Wyhash.init(0x4143_4354);
    inline for (.{ acct.codegraff_email, acct.harness_email, acct.active_harness, acct.active_model }) |opt| {
        if (opt) |s| {
            h.update(&.{1});
            h.update(s);
        } else {
            h.update(&.{0});
        }
    }
    return h.final();
}

pub const RpcId = union(enum) {
    int: i64,
    str: []const u8,
};

pub const OwnedRpcId = union(enum) {
    int: i64,
    str: []u8,

    pub fn dupe(gpa: Allocator, id: RpcId) !OwnedRpcId {
        return switch (id) {
            .int => |v| .{ .int = v },
            .str => |s| .{ .str = try gpa.dupe(u8, s) },
        };
    }

    pub fn asRef(self: *const OwnedRpcId) RpcId {
        return switch (self.*) {
            .int => |v| .{ .int = v },
            .str => |s| .{ .str = s },
        };
    }

    pub fn deinit(self: *OwnedRpcId, gpa: Allocator) void {
        switch (self.*) {
            .int => {},
            .str => |s| gpa.free(s),
        }
    }
};

pub const BridgeMessage = struct {
    id: ?RpcId = null,
    method: []const u8,
    params: ?json.Value = null,
};

pub const ParsedBridgeMessage = struct {
    arena: std.heap.ArenaAllocator,
    msg: BridgeMessage,

    pub fn deinit(self: *ParsedBridgeMessage) void {
        self.arena.deinit();
    }
};

fn isAsciiControlOrSpace(b: u8) bool {
    return b <= 0x20 or b >= 0x7f;
}

fn isValidPort(port_str: []const u8) bool {
    if (port_str.len == 0 or port_str.len > 5) return false;
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch return false;
    return port >= 1;
}

fn parseAuthorityHost(authority: []const u8) ?[]const u8 {
    if (authority.len == 0) return null;
    if (authority[0] == '[') {
        const close_idx = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        if (close_idx <= 1) return null;
        const inner = authority[1..close_idx];
        for (inner) |ch| {
            const ok = std.ascii.isHex(ch) or ch == ':' or ch == '.';
            if (!ok) return null;
        }
        const host = authority[0 .. close_idx + 1];
        const rest = authority[close_idx + 1 ..];
        if (rest.len > 0) {
            if (rest[0] != ':' or !isValidPort(rest[1..])) return null;
        }
        return host;
    }

    if (std.mem.indexOfAny(u8, authority, "[]/@\\") != null) return null;
    var host = authority;
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        if (std.mem.lastIndexOfScalar(u8, authority, ':') != colon) return null;
        if (!isValidPort(authority[colon + 1 ..])) return null;
        host = authority[0..colon];
    }
    if (host.len == 0) return null;
    if (host[0] == '.' or host[host.len - 1] == '.' or host[0] == '-' or host[host.len - 1] == '-') return null;
    for (host) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-';
        if (!ok) return null;
    }
    return host;
}

fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "127.0.0.1")) return true;
    if (std.ascii.eqlIgnoreCase(host, "[::1]")) return true;
    return false;
}

/// Validates one origin entry from `_meta.ui.csp`.
/// Accepts only `https://<host>[:port]` or loopback `http://127.0.0.1[:port]`,
/// `http://localhost[:port]`, `http://[::1][:port]` (with optional trailing `/`).
pub fn validateCspOrigin(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > 256) return false;
    for (raw) |b| {
        if (isAsciiControlOrSpace(b)) return false;
        switch (b) {
            '*', '?', '#', '@', ';', '\'', '"', '\\', '<', '>' => return false,
            else => {},
        }
    }
    const trimmed = if (raw[raw.len - 1] == '/') raw[0 .. raw.len - 1] else raw;
    if (std.mem.startsWith(u8, trimmed, "https://")) {
        const auth = trimmed["https://".len..];
        return parseAuthorityHost(auth) != null;
    }
    if (std.mem.startsWith(u8, trimmed, "http://")) {
        const auth = trimmed["http://".len..];
        const host = parseAuthorityHost(auth) orelse return false;
        return isLoopbackHost(host);
    }
    return false;
}

/// Validates a `ui/open-link` URL before opening it outside the sandbox.
/// Accepts only `https://...` or loopback `http://127.0.0.1|localhost|[::1]`.
pub fn validateOpenLinkUrl(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > 2048) return false;
    for (raw) |b| {
        if (isAsciiControlOrSpace(b) or b == '\\') return false;
    }
    const rest, const require_loopback = if (std.mem.startsWith(u8, raw, "https://"))
        .{ raw["https://".len..], false }
    else if (std.mem.startsWith(u8, raw, "http://"))
        .{ raw["http://".len..], true }
    else
        return false;

    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const auth = rest[0..end];
    if (std.mem.indexOfScalar(u8, auth, '@') != null) return false;
    const host = parseAuthorityHost(auth) orelse return false;
    if (require_loopback and !isLoopbackHost(host)) return false;
    return true;
}

/// Checks whether a destination `url` matches one sanitized `origin` (`https://host[:port]`).
pub fn urlMatchesOrigin(url: []const u8, origin: []const u8) bool {
    if (!validateCspOrigin(origin)) return false;
    const clean_origin = if (origin[origin.len - 1] == '/') origin[0 .. origin.len - 1] else origin;
    if (!std.mem.startsWith(u8, url, clean_origin)) return false;
    if (url.len == clean_origin.len) return true;
    const next = url[clean_origin.len];
    return next == '/' or next == '?' or next == '#';
}

fn writeValidatedOrigins(wr: *std.Io.Writer, domains: []const []const u8, had_prior_tokens: bool) !bool {
    var wrote_any = had_prior_tokens;
    for (domains) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (!validateCspOrigin(trimmed)) continue;
        const clean = if (trimmed[trimmed.len - 1] == '/') trimmed[0 .. trimmed.len - 1] else trimmed;
        if (wrote_any) try wr.writeByte(' ');
        try wr.writeAll(clean);
        wrote_any = true;
    }
    return wrote_any;
}

/// Builds the `<meta http-equiv="Content-Security-Policy">` string injected into the sandboxed `srcdoc` app.
pub fn buildAppCsp(gpa: Allocator, csp: Csp) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;

    try wr.writeAll("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:");
    _ = try writeValidatedOrigins(wr, csp.resource_domains, true);

    try wr.writeAll("; media-src data: blob:; font-src data:");
    _ = try writeValidatedOrigins(wr, csp.resource_domains, true);

    try wr.writeAll("; connect-src ");
    if (!(try writeValidatedOrigins(wr, csp.connect_domains, false))) {
        try wr.writeAll("'none'");
    }

    try wr.writeAll("; frame-src ");
    if (!(try writeValidatedOrigins(wr, csp.frame_domains, false))) {
        try wr.writeAll("'none'");
    }

    try wr.writeAll("; form-action 'none'; base-uri 'none'");
    return aw.toOwnedSlice();
}

/// Baseline outer shell CSP string (`mcp-app://host/<session-id>`).
pub fn buildShellCsp() []const u8 {
    return "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src 'self' about: data: blob:; child-src 'self' about: data: blob:; form-action 'none'; base-uri 'none'";
}

/// Outer shell HTTP header CSP including sanitized app domains so WebKit's `srcdoc`
/// CSP inheritance permits validated `resourceDomains` / `connectDomains` / `frameDomains`
/// while enforcing `default-src 'none'`, `form-action 'none'`, and `base-uri 'none'`.
pub fn buildShellHeaderCsp(gpa: Allocator, csp: Csp) ![]u8 {
    if (csp.resource_domains.len == 0 and csp.connect_domains.len == 0 and csp.frame_domains.len == 0) {
        return gpa.dupe(u8, buildShellCsp());
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;
    try wr.writeAll("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:");
    _ = try writeValidatedOrigins(wr, csp.resource_domains, true);
    try wr.writeAll("; media-src data: blob:; font-src data:");
    _ = try writeValidatedOrigins(wr, csp.resource_domains, true);
    try wr.writeAll("; connect-src ");
    if (!(try writeValidatedOrigins(wr, csp.connect_domains, false))) {
        try wr.writeAll("'none'");
    }
    try wr.writeAll("; frame-src 'self' about: data: blob:");
    _ = try writeValidatedOrigins(wr, csp.frame_domains, true);
    try wr.writeAll("; child-src 'self' about: data: blob:");
    _ = try writeValidatedOrigins(wr, csp.frame_domains, true);
    try wr.writeAll("; form-action 'none'; base-uri 'none'");
    return aw.toOwnedSlice();
}

fn writeHtmlAttrEscaped(wr: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try wr.writeAll("&amp;"),
        '"' => try wr.writeAll("&quot;"),
        '\'' => try wr.writeAll("&#39;"),
        '<' => try wr.writeAll("&lt;"),
        '>' => try wr.writeAll("&gt;"),
        else => try wr.writeByte(ch),
    };
}

fn findHeadClose(html: []const u8) ?usize {
    var i: usize = 0;
    while (i + 5 < html.len) : (i += 1) {
        if (html[i] != '<') continue;
        if (!std.ascii.eqlIgnoreCase(html[i + 1 .. i + 5], "head")) continue;
        const after = html[i + 5];
        const is_tag_end = after == '>' or after == ' ' or after == '\t' or after == '\r' or after == '\n' or after == '/';
        if (!is_tag_end) continue;
        var j = i + 5;
        while (j < html.len) : (j += 1) {
            if (html[j] == '>') return j + 1;
            if (html[j] == '<') break;
        }
    }
    return null;
}

pub fn injectMetaCsp(gpa: Allocator, raw_html: []const u8, app_csp: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;

    if (findHeadClose(raw_html)) |idx| {
        try wr.writeAll(raw_html[0..idx]);
        try wr.writeAll("<meta http-equiv=\"Content-Security-Policy\" content=\"");
        try writeHtmlAttrEscaped(wr, app_csp);
        try wr.writeAll("\">");
        try wr.writeAll(raw_html[idx..]);
    } else {
        try wr.writeAll("<head><meta http-equiv=\"Content-Security-Policy\" content=\"");
        try writeHtmlAttrEscaped(wr, app_csp);
        try wr.writeAll("\"></head>");
        try wr.writeAll(raw_html);
    }
    return aw.toOwnedSlice();
}

/// Wraps untrusted app HTML inside an opaque-origin `sandbox="allow-scripts"` iframe
/// (`srcdoc`) with a strict `postMessage` JSON-RPC 2.0 allowlist bridge to `webkit.messageHandlers.mcpApp`.
pub fn buildHostShellHtml(gpa: Allocator, raw_html: []const u8, csp: Csp) ![]u8 {
    if (raw_html.len > max_html_bytes) return error.HtmlTooLarge;
    const app_csp = try buildAppCsp(gpa, csp);
    defer gpa.free(app_csp);
    const app_with_csp = try injectMetaCsp(gpa, raw_html, app_csp);
    defer gpa.free(app_with_csp);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;

    try wr.writeAll(
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><style>
        \\html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:transparent;}
        \\#mcp-app-frame{width:100%;height:100%;border:0;display:block;}
        \\</style></head><body><iframe id="mcp-app-frame" sandbox="allow-scripts" referrerpolicy="no-referrer" srcdoc="
    );
    try writeHtmlAttrEscaped(wr, app_with_csp);
    try wr.writeAll(
        \\"></iframe><script>
        \\(function(){
        \\  var frame=document.getElementById('mcp-app-frame');
        \\  var loaded=false;
        \\  var outbox=[];
        \\  var allowed={
        \\    'ui/initialize':1,
        \\    'ui/notifications/initialized':1,
        \\    'ui/notifications/size-changed':1,
        \\    'tools/call':1,
        \\    'ui/update-model-context':1,
        \\    'ui/open-link':1,
        \\    'ui/request-display-mode':1,
        \\    'ui/message':1
        \\  };
        \\  function flush(){
        \\    if(!loaded||!frame||!frame.contentWindow)return;
        \\    while(outbox.length>0){
        \\      frame.contentWindow.postMessage(outbox.shift(),'*');
        \\    }
        \\  }
        \\  frame.addEventListener('load',function(){loaded=true;flush();});
        \\  window.addEventListener('message',function(ev){
        \\    if(!frame||ev.source!==frame.contentWindow)return;
        \\    var d=ev.data;
        \\    if(!d||typeof d!=='object'||d.jsonrpc!=='2.0'||typeof d.method!=='string')return;
        \\    if(!Object.prototype.hasOwnProperty.call(allowed,d.method)&&d.method.indexOf('ui/')!==0&&d.method!=='tools/call')return;
        \\    var raw;
        \\    try{raw=JSON.stringify(d);}catch(_){return;}
        \\    if(!raw||raw.length>524288)return;
        \\    if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.mcpApp){
        \\      window.webkit.messageHandlers.mcpApp.postMessage(raw);
        \\    }
        \\  });
        \\  window.__mcpHostDeliver=function(b64){
        \\    var bin=atob(b64);
        \\    var bytes=new Uint8Array(bin.length);
        \\    for(var i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);
        \\    var text=new TextDecoder('utf-8').decode(bytes);
        \\    var msg=JSON.parse(text);
        \\    outbox.push(msg);
        \\    flush();
        \\  };
        \\})();
        \\</script></body></html>
    );
    return aw.toOwnedSlice();
}

pub fn formatHexColor(buf: *[7]u8, col: nanoui.ui.Color) []const u8 {
    const r = toChannelByte(col.r);
    const g = toChannelByte(col.g);
    const b = toChannelByte(col.b);
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch "#000000";
}

fn toChannelByte(v: f32) u8 {
    const clamped = std.math.clamp(v, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

pub fn colorFingerprint(k: theme.Colors) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(&.{@intFromBool(k.dark)});
    inline for (.{ k.background, k.panel, k.raised, k.sidebar, k.text, k.muted, k.accent, k.on_accent, k.border }) |col| {
        const rgb = [3]u8{ toChannelByte(col.r), toChannelByte(col.g), toChannelByte(col.b) };
        h.update(&rgb);
    }
    return h.final();
}

fn writeHostContextFields(wr: *std.Io.Writer, k: theme.Colors, mode: DisplayMode, acct: HostAccount) !void {
    var buf: [7]u8 = undefined;
    try wr.writeAll("\"theme\":");
    try json.Stringify.value(if (k.dark) @as([]const u8, "dark") else "light", .{}, wr);
    try wr.writeAll(",\"displayMode\":");
    try json.Stringify.value(mode.asWireString(), .{}, wr);
    try wr.writeAll(",\"availableDisplayModes\":[\"inline\",\"fullscreen\"],\"account\":");
    try json.Stringify.value(WireHostAccount{
        .codegraffEmail = acct.codegraff_email,
        .harnessEmail = acct.harness_email,
        .activeHarness = acct.active_harness,
        .activeModel = acct.active_model,
    }, .{ .emit_null_optional_fields = false }, wr);
    try wr.writeAll(",\"styles\":{\"variables\":{");

    const secondary_bg = if (k.panel.a > 0) k.panel else k.raised;
    const entries = .{
        .{ "--color-background-primary", k.background },
        .{ "--color-background-secondary", secondary_bg },
        .{ "--color-background-tertiary", k.sidebar },
        .{ "--color-text-primary", k.text },
        .{ "--color-text-secondary", k.muted },
        .{ "--color-text-tertiary", k.faint },
        .{ "--color-border-primary", k.border },
        .{ "--color-border-secondary", k.border_strong },
        .{ "--color-accent-primary", k.accent },
        .{ "--color-accent-text", k.on_accent },
        .{ "--color-danger", k.danger },
        .{ "--color-warning", k.warning },
        .{ "--color-success", k.success },
    };
    inline for (entries, 0..) |entry, idx| {
        if (idx > 0) try wr.writeByte(',');
        try json.Stringify.value(entry[0], .{}, wr);
        try wr.writeByte(':');
        try json.Stringify.value(formatHexColor(&buf, entry[1]), .{}, wr);
    }
    try wr.writeAll("}}");
}

fn writeRpcId(wr: *std.Io.Writer, id: RpcId) !void {
    switch (id) {
        .int => |v| try wr.print("{d}", .{v}),
        .str => |s| try json.Stringify.value(s, .{}, wr),
    }
}

pub fn buildInitializeResult(gpa: Allocator, id: RpcId, k: theme.Colors, mode: DisplayMode, acct: HostAccount) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;

    try wr.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeRpcId(wr, id);
    try wr.writeAll(",\"result\":{\"protocolVersion\":");
    try json.Stringify.value(protocol_version, .{}, wr);
    try wr.writeAll(",\"hostInfo\":{\"name\":");
    try json.Stringify.value(host_name, .{}, wr);
    try wr.writeAll(",\"version\":");
    try json.Stringify.value(host_version, .{}, wr);
    try wr.writeAll("},\"hostCapabilities\":{\"openLinks\":{},\"serverTools\":{},\"updateModelContext\":{},\"message\":{}},\"hostContext\":{");
    try writeHostContextFields(wr, k, mode, acct);
    try wr.writeAll("}}}");
    return aw.toOwnedSlice();
}

pub fn buildHostContextChangedNotification(gpa: Allocator, k: theme.Colors, mode: DisplayMode, acct: HostAccount) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;

    try wr.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"ui/notifications/host-context-changed\",\"params\":{");
    try writeHostContextFields(wr, k, mode, acct);
    try wr.writeAll("}}");
    return aw.toOwnedSlice();
}

pub fn buildToolInputNotification(gpa: Allocator, raw_arguments_json: []const u8) ![]u8 {
    const parsed = try json.parseFromSlice(json.Value, gpa, raw_arguments_json, .{});
    defer parsed.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;
    try wr.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"ui/notifications/tool-input\",\"params\":{\"arguments\":");
    try json.Stringify.value(parsed.value, .{}, wr);
    try wr.writeAll("}}");
    return aw.toOwnedSlice();
}

pub fn buildToolResultNotification(gpa: Allocator, raw_result_json: []const u8) ![]u8 {
    const parsed = try json.parseFromSlice(json.Value, gpa, raw_result_json, .{});
    defer parsed.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;
    try wr.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"ui/notifications/tool-result\",\"params\":");
    if (parsed.value == .object) {
        try json.Stringify.value(parsed.value, .{}, wr);
    } else {
        try wr.writeAll("{\"content\":[],\"structuredContent\":");
        try json.Stringify.value(parsed.value, .{}, wr);
        try wr.writeByte('}');
    }
    try wr.writeByte('}');
    return aw.toOwnedSlice();
}

pub fn buildRpcResult(gpa: Allocator, id: RpcId, raw_result_json: []const u8) ![]u8 {
    const parsed = try json.parseFromSlice(json.Value, gpa, raw_result_json, .{});
    defer parsed.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;
    try wr.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeRpcId(wr, id);
    try wr.writeAll(",\"result\":");
    try json.Stringify.value(parsed.value, .{}, wr);
    try wr.writeByte('}');
    return aw.toOwnedSlice();
}

pub fn buildRpcResultValue(gpa: Allocator, id: RpcId, value: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;
    try wr.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeRpcId(wr, id);
    try wr.writeAll(",\"result\":");
    try json.Stringify.value(value, .{}, wr);
    try wr.writeByte('}');
    return aw.toOwnedSlice();
}

pub fn buildRpcError(gpa: Allocator, id: RpcId, code: i32, message: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const wr = &aw.writer;
    try wr.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeRpcId(wr, id);
    try wr.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try json.Stringify.value(message, .{}, wr);
    try wr.writeAll("}}");
    return aw.toOwnedSlice();
}

pub fn buildTeardownRequest(gpa: Allocator, id: u64) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"ui/resource-teardown\",\"params\":{{}}}}", .{id});
}

pub fn parseBridgeMessage(gpa: Allocator, raw: []const u8) !ParsedBridgeMessage {
    if (raw.len == 0 or raw.len > max_bridge_message_bytes) return error.BridgeMessageTooLarge;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const val = try json.parseFromSliceLeaky(json.Value, a, raw, .{});
    if (val != .object) return error.InvalidBridgeMessage;
    const obj = val.object;
    const ver = obj.get("jsonrpc") orelse return error.InvalidBridgeMessage;
    if (ver != .string or !std.mem.eql(u8, ver.string, "2.0")) return error.InvalidBridgeMessage;
    const meth = obj.get("method") orelse return error.InvalidBridgeMessage;
    if (meth != .string or meth.string.len == 0 or meth.string.len > 128) return error.InvalidBridgeMessage;

    var parsed_id: ?RpcId = null;
    if (obj.get("id")) |id_val| {
        parsed_id = switch (id_val) {
            .integer => |n| .{ .int = n },
            .string => |s| if (s.len > 0 and s.len <= 128) .{ .str = s } else return error.InvalidBridgeMessage,
            .null => null,
            else => return error.InvalidBridgeMessage,
        };
    }
    return .{
        .arena = arena,
        .msg = .{
            .id = parsed_id,
            .method = meth.string,
            .params = obj.get("params"),
        },
    };
}

test "validateCspOrigin and validateOpenLinkUrl enforce strict scheme and host boundaries" {
    const testing = std.testing;
    try testing.expect(validateCspOrigin("https://cdn.example.com"));
    try testing.expect(validateCspOrigin("https://api.example.com:8443/"));
    try testing.expect(validateCspOrigin("http://127.0.0.1:4123"));
    try testing.expect(validateCspOrigin("http://localhost:3000"));
    try testing.expect(validateCspOrigin("http://[::1]:8080"));

    try testing.expect(!validateCspOrigin("https://*.example.com"));
    try testing.expect(!validateCspOrigin("https://example.com/path"));
    try testing.expect(!validateCspOrigin("https://user@example.com"));
    try testing.expect(!validateCspOrigin("http://example.com"));
    try testing.expect(!validateCspOrigin("javascript:alert(1)"));
    try testing.expect(!validateCspOrigin("https://example.com;script-src 'unsafe-eval'"));

    try testing.expect(validateOpenLinkUrl("https://docs.example.com/guide?q=1#top"));
    try testing.expect(validateOpenLinkUrl("http://localhost:8080/preview"));
    try testing.expect(validateOpenLinkUrl("http://127.0.0.1:9999/"));
    try testing.expect(!validateOpenLinkUrl("http://192.168.1.50/admin"));
    try testing.expect(!validateOpenLinkUrl("javascript:alert(1)"));
    try testing.expect(!validateOpenLinkUrl("file:///etc/passwd"));
    try testing.expect(!validateOpenLinkUrl("data:text/html,<script>1</script>"));
    try testing.expect(!validateOpenLinkUrl("https://user:pass@example.com/"));
}

test "buildAppCsp and buildHostShellHtml enforce sandbox, meta CSP, and escaping" {
    const testing = std.testing;
    const csp_str = try buildAppCsp(testing.allocator, .{
        .resource_domains = &.{ "https://cdn.example.com", "http://evil.example.com", "https://*.bad.com" },
        .connect_domains = &.{"https://api.example.com:8443/"},
        .frame_domains = &.{},
    });
    defer testing.allocator.free(csp_str);

    try testing.expectEqualStrings(
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob: https://cdn.example.com; media-src data: blob:; font-src data: https://cdn.example.com; connect-src https://api.example.com:8443; frame-src 'none'; form-action 'none'; base-uri 'none'",
        csp_str,
    );

    const raw_html = "<!doctype html><html><head><title>App</title></head><body><button data-quote=\"a&b\">Go</button></body></html>";
    const shell = try buildHostShellHtml(testing.allocator, raw_html, .{
        .resource_domains = &.{"https://cdn.example.com"},
    });
    defer testing.allocator.free(shell);

    try testing.expect(std.mem.indexOf(u8, shell, "sandbox=\"allow-scripts\"") != null);
    try testing.expect(std.mem.indexOf(u8, shell, "allow-same-origin") == null);
    try testing.expect(std.mem.indexOf(u8, shell, "Content-Security-Policy") != null);
    try testing.expect(std.mem.indexOf(u8, shell, "&quot;a&amp;b&quot;") != null);
    try testing.expect(std.mem.indexOf(u8, shell, "window.__mcpHostDeliver") != null);
}

test "buildInitializeResult, parseBridgeMessage, and buildRpcError round-trip SEP-1865 JSON-RPC" {
    const testing = std.testing;
    const k = theme.colors(true);
    const init_json = try buildInitializeResult(testing.allocator, .{ .int = 42 }, k, .inline_mode, .{
        .codegraff_email = "rach@standardharness.com",
        .active_harness = "graff",
    });
    defer testing.allocator.free(init_json);

    var parsed_init = try json.parseFromSlice(json.Value, testing.allocator, init_json, .{});
    defer parsed_init.deinit();
    const res = parsed_init.value.object.get("result").?.object;
    try testing.expectEqualStrings(protocol_version, res.get("protocolVersion").?.string);
    const ctx = res.get("hostContext").?.object;
    try testing.expectEqualStrings("dark", ctx.get("theme").?.string);
    try testing.expectEqualStrings("inline", ctx.get("displayMode").?.string);
    try testing.expectEqualStrings("rach@standardharness.com", ctx.get("account").?.object.get("codegraffEmail").?.string);
    const vars = ctx.get("styles").?.object.get("variables").?.object;
    try testing.expect(vars.get("--color-background-primary").?.string.len == 7);
    try testing.expect(vars.get("--color-accent-primary").?.string[0] == '#');

    var msg = try parseBridgeMessage(testing.allocator,
        \\{"jsonrpc":"2.0","id":"req-1","method":"tools/call","params":{"name":"inspect","arguments":{"ok":true}}}
    );
    defer msg.deinit();
    try testing.expectEqualStrings("tools/call", msg.msg.method);
    try testing.expectEqualStrings("req-1", msg.msg.id.?.str);

    const err_json = try buildRpcError(testing.allocator, .{ .str = "req-1" }, rpc_err_invalid_params, "Disallowed \"quoted\" param");
    defer testing.allocator.free(err_json);
    var parsed_err = try json.parseFromSlice(json.Value, testing.allocator, err_json, .{});
    defer parsed_err.deinit();
    try testing.expectEqual(@as(i64, rpc_err_invalid_params), parsed_err.value.object.get("error").?.object.get("code").?.integer);
}
