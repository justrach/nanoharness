//! Real hidden macOS WKWebView integration test for the SEP-1865 double-sandbox host.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const nanoui = @import("nanoui");
const testing = std.testing;

const App = @import("app.zig").App;
const theme = @import("theme.zig");
const host = @import("mcp_app_host.zig");
const mcp_apps = @import("app_mcp_apps.zig");

const app_fixture_html =
    \\<!doctype html>
    \\<html><head><title>SEP-1865 Fixture</title></head><body>
    \\<div id="status">boot</div>
    \\<script>
    \\(function(){
    \\  var originOk = (window.origin === "null");
    \\  var domIsolated = (function(){ try { void window.parent.document.title; return false; } catch (_) { return true; } })();
    \\  // Attempt direct subframe spoof: must be dropped by WKScriptMessageHandler isMainFrame guard.
    \\  try {
    \\    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mcpApp) {
    \\      window.webkit.messageHandlers.mcpApp.postMessage(JSON.stringify({
    \\        jsonrpc: "2.0",
    \\        id: 999,
    \\        method: "ui/update-model-context",
    \\        params: { content: [{ type: "text", text: "SPOOFED_SUBFRAME" }] }
    \\      }));
    \\    }
    \\  } catch (_) {}
    \\  var gotInput = false;
    \\  var gotResult = false;
    \\  var gotForbiddenErr = false;
    \\  var gotAllowedOk = false;
    \\  var gotBadLinkErr = false;
    \\  var gotFileLinkErr = false;
    \\  var gotUnknownErr = false;
    \\  var gotThemeDark = false;
    \\  var gotAccount = false;
    \\  var nextStageStarted = false;
    \\  var finalSent = false;
    \\
    \\  function send(obj) {
    \\    window.parent.postMessage(obj, "*");
    \\  }
    \\
    \\  function maybeFinish() {
    \\    if (finalSent) return;
    \\    if (originOk && domIsolated && gotAccount && gotInput && gotResult && gotForbiddenErr && gotAllowedOk && gotBadLinkErr && gotFileLinkErr && gotUnknownErr && gotThemeDark) {
    \\      finalSent = true;
    \\      send({ jsonrpc: "2.0", id: 8, method: "ui/update-model-context", params: { content: [{ type: "text", text: "E2E_ALL_GREEN" }] } });
    \\    }
    \\  }
    \\
    \\  function maybeContinueAfterPayloads() {
    \\    if (nextStageStarted || !gotInput || !gotResult) return;
    \\    nextStageStarted = true;
    \\    send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "forbidden_tool", arguments: {} } });
    \\    send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "allowed_ping", arguments: { ping: 7 } } });
    \\    send({ jsonrpc: "2.0", id: 4, method: "ui/update-model-context", params: { content: [{ type: "text", text: "Synced from WebKit" }] } });
    \\    send({ jsonrpc: "2.0", method: "ui/notifications/size-changed", params: { height: 312 } });
    \\    send({ jsonrpc: "2.0", id: 5, method: "ui/open-link", params: { url: "javascript:alert(1)" } });
    \\    send({ jsonrpc: "2.0", id: 6, method: "ui/open-link", params: { url: "file:///etc/passwd" } });
    \\    send({ jsonrpc: "2.0", id: 7, method: "ui/does-not-exist", params: {} });
    \\  }
    \\
    \\  window.addEventListener("message", function(ev) {
    \\    var d = ev.data;
    \\    if (!d || d.jsonrpc !== "2.0") return;
    \\    if (d.id === 1 && d.result) {
    \\      var ctx = d.result.hostContext || {};
    \\      var vars = (ctx.styles && ctx.styles.variables) || {};
    \\      if (ctx.account && ctx.account.codegraffEmail === "rach@standardharness.com") gotAccount = true;
    \\      if (d.result.protocolVersion === "2026-01-26" && typeof vars["--color-background-primary"] === "string") {
    \\        send({ jsonrpc: "2.0", method: "ui/notifications/initialized" });
    \\      }
    \\      return;
    \\    }
    \\    if (d.method === "ui/notifications/tool-input") {
    \\      if (d.params && d.params.arguments && d.params.arguments.node === "hero") gotInput = true;
    \\      maybeContinueAfterPayloads();
    \\      return;
    \\    }
    \\    if (d.method === "ui/notifications/tool-result") {
    \\      if (d.params && d.params.structuredContent && d.params.structuredContent.ready === true) gotResult = true;
    \\      maybeContinueAfterPayloads();
    \\      return;
    \\    }
    \\    if (d.id === 2 && d.error && d.error.code === -32602) { gotForbiddenErr = true; maybeFinish(); return; }
    \\    if (d.id === 3 && d.result && d.result.structuredContent && d.result.structuredContent.pong === 7) { gotAllowedOk = true; maybeFinish(); return; }
    \\    if (d.id === 5 && d.error && d.error.code === -32602) { gotBadLinkErr = true; maybeFinish(); return; }
    \\    if (d.id === 6 && d.error && d.error.code === -32602) { gotFileLinkErr = true; maybeFinish(); return; }
    \\    if (d.id === 7 && d.error && d.error.code === -32601) { gotUnknownErr = true; maybeFinish(); return; }
    \\    if (d.method === "ui/notifications/host-context-changed" && d.params && d.params.theme === "dark") {
    \\      gotThemeDark = true;
    \\      if (!(originOk && domIsolated && gotAccount && gotInput && gotResult && gotForbiddenErr && gotAllowedOk && gotBadLinkErr && gotFileLinkErr && gotUnknownErr)) {
    \\        send({
    \\          jsonrpc: "2.0",
    \\          method: "ui/update-model-context",
    \\          params: {
    \\            content: [{
    \\              type: "text",
    \\              text: "DIAG origin=" + window.origin +
    \\                " originOk=" + originOk +
    \\                " domIso=" + domIsolated +
    \\                " acct=" + gotAccount +
    \\                " in=" + gotInput +
    \\                " res=" + gotResult +
    \\                " forb=" + gotForbiddenErr +
    \\                " ok=" + gotAllowedOk +
    \\                " badLink=" + gotBadLinkErr +
    \\                " fileLink=" + gotFileLinkErr +
    \\                " unk=" + gotUnknownErr
    \\            }]
    \\          }
    \\        });
    \\      }
    \\      maybeFinish();
    \\      return;
    \\    }
    \\  });
    \\
    \\  send({
    \\    jsonrpc: "2.0",
    \\    id: 1,
    \\    method: "ui/initialize",
    \\    params: {
    \\      appInfo: { name: "synthetic-fixture", version: "1.0.0" },
    \\      appCapabilities: {},
    \\      protocolVersion: "2026-01-26"
    \\    }
    \\  });
    \\})();
    \\</script></body></html>
;

test "isolated WKWebView enforces double sandbox and completes full SEP-1865 round-trip" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();

    _ = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});

    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.account.codegraff.signed_in = true;
    a.account.codegraff.who = try testing.allocator.dupe(u8, "rach@standardharness.com");

    const s = try mcp_apps.Session.create(&a, "chat-e2e", .{
        .server_name = "studio",
        .resource_uri = "ui://studio/card.html",
        .tool_name = "open_studio",
        .title = "Studio E2E",
        .tool_input_json = "{\"node\":\"hero\"}",
        .tool_result_json = "{\"content\":[],\"structuredContent\":{\"ready\":true}}",
    }, null);
    defer s.destroy();

    s.allowed_app_tools = blk: {
        const list = try testing.allocator.alloc([]u8, 1);
        list[0] = try testing.allocator.dupe(u8, "allowed_ping");
        break :blk list;
    };

    const MockTool = struct {
        called: bool = false,
        fn invoke(ctx: *anyopaque, sess: *mcp_apps.Session, id: host.RpcId, name: []const u8, args: ?json.Value) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "allowed_ping")) {
                self.called = true;
                _ = args;
                const ok = host.buildRpcResult(sess.app.gpa, id, "{\"content\":[],\"structuredContent\":{\"pong\":7}}") catch return;
                defer sess.app.gpa.free(ok);
                sess.deliver(ok);
            }
        }
    };
    var mock_tool: MockTool = .{};
    s.tool_call_override = .{ .ctx = &mock_tool, .func = MockTool.invoke };

    const native = try @import("mcp_app_native.zig").McpAppNative.create(testing.allocator, .{
        .ctx = s,
        .on_message = struct {
            fn f(ctx: *anyopaque, raw: []const u8) void {
                const sess: *mcp_apps.Session = @ptrCast(@alignCast(ctx));
                sess.handleBridgeMessage(raw);
            }
        }.f,
        .on_state = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    });
    s.native = native;

    // Confirm ephemeral nonPersistentDataStore.
    const cfg = objc.msg(objc.Object, native.view, "configuration", .{});
    const store = objc.msg(objc.Object, cfg, "websiteDataStore", .{});
    try testing.expect(!objc.msg(objc.BOOL, store, "isPersistent", .{}));

    const window = objc.msg(
        objc.Object,
        objc.alloc("NSWindow"),
        "initWithContentRect:styleMask:backing:defer:",
        .{ objc.CGRect{ .size = .{ .width = 520, .height = 420 } }, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 2), objc.NO },
    );
    defer objc.release(window);
    const parent = objc.msg(objc.Object, window, "contentView", .{});
    native.mount(parent, .{ .x = 0, .y = 0, .w = 520, .h = 420 });

    const csp: host.Csp = .{};
    const shell = try host.buildHostShellHtml(testing.allocator, app_fixture_html, csp);
    defer testing.allocator.free(shell);
    try native.loadShell(s.id, shell, host.buildShellCsp(), &.{});

    // Pump NSRunLoop until initial handshake + calls complete, then trigger live dark theme push.
    var pushed_theme = false;
    var step: usize = 0;
    while (step < 80) : (step += 1) {
        nanoui.runFor(0.1);
        if (!pushed_theme and s.preferred_height != null and s.context_note != null and mock_tool.called) {
            try testing.expectEqual(@as(?f32, 312.0), s.preferred_height);
            try testing.expectEqualStrings("Synced from WebKit", s.context_note.?);
            pushed_theme = true;
            s.syncTheme(theme.colors(true));
        }
        if (s.context_note) |note| {
            if (std.mem.eql(u8, note, "E2E_ALL_GREEN")) break;
        }
    }

    try testing.expect(pushed_theme);
    try testing.expect(mock_tool.called);
    try testing.expectEqualStrings("E2E_ALL_GREEN", s.context_note orelse "");
}
