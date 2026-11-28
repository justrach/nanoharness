//! Real WebKit, hidden and with synthetic pages and an ephemeral data store.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const testing = std.testing;

const Probe = struct {
    changes: usize = 0,
    fn changed(ctx: *anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.changes += 1;
    }
};

fn prepareAppKit() void {
    _ = nanoui.objc.msg(nanoui.objc.Object, nanoui.objc.class("NSApplication"), "sharedApplication", .{});
}

test "the native Browser renders a generated page without injecting an app bridge" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    prepareAppKit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const id = "0123456789abcdef0123456789abcdef";
    try tmp.dir.createDirPath(testing.io, ".graff/views");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".graff/views/" ++ id ++ ".html", .data = "<!doctype html><title>Synthetic generated page</title><script>document.title='Synthetic page ready'</script><p>Only made-up data.</p>" });
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    var probe: Probe = .{};
    const native = try @import("browser_native.zig").Native.create(testing.allocator, testing.io, home, .{ .ctx = &probe, .changed = Probe.changed });
    defer native.destroy();
    const parent = objc.msg(objc.Object, objc.alloc("NSView"), "initWithFrame:", .{objc.CGRect{ .size = .{ .width = 520, .height = 600 } }});
    defer objc.release(parent);
    native.mount(parent, .{ .x = 0, .y = 38, .w = 520, .h = 500 });
    try testing.expect(native.visible);
    try testing.expect(native.allowsBackForwardGestures());
    native.navigate("graff-view://html/" ++ id);
    try testing.expect(!native.allowsBackForwardGestures());
    nanoui.runFor(3);
    try testing.expectEqualStrings("Synthetic page ready", native.title());
    try testing.expect(probe.changes > 0);
    const config = objc.msg(objc.Object, native.view, "configuration", .{});
    const content = objc.msg(objc.Object, config, "userContentController", .{});
    const scripts = objc.msg(objc.Object, content, "userScripts", .{});
    try testing.expectEqual(@as(objc.NSUInteger, 0), objc.msg(objc.NSUInteger, scripts, "count", .{}));
    native.show(false);
    try testing.expect(!native.visible);
    try testing.expect(objc.msg(objc.BOOL, native.view, "isHidden", .{}));
}

const App = @import("app.zig").App;
const app_browser = @import("app_browser.zig");
const Browser = app_browser.Browser;

fn zoomKey(menu: *nanoui.Menu, key: []const u8, code: u16) bool {
    const objc = nanoui.objc;
    const event = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10), objc.CGPoint{}, @as(objc.NSUInteger, 1 << 20), @as(f64, 0), @as(objc.NSInteger, 0), @as(?objc.Object, null), objc.nsString(key), objc.nsString(key), objc.NO, code,
    });
    return objc.msg(objc.BOOL, menu.ns, "performKeyEquivalent:", .{event});
}

fn fixtureBrowser(a: *App, home: []const u8, parent: nanoui.objc.Object, probe: *Probe) !*Browser {
    @import("app_browser.zig").openLink(a, "zoom-fixture", "http://localhost:31997/synthetic");
    @import("app_browser.zig").settleFrame(a);
    const b = a.panels.tabs.items[a.panels.active].browser.?;
    const n = try @import("browser_native.zig").Native.create(testing.allocator, testing.io, home, .{ .ctx = probe, .changed = Probe.changed });
    b.native = n;
    n.mount(parent, .{ .x = 0, .y = 0, .w = 520, .h = 400 });
    n.navigate("graff-view://html/0123456789abcdef0123456789abcdef");
    return b;
}

test "browser zoom shortcuts route native menu and UI keys to the focused visible WebKit page" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    prepareAppKit();
    @import("theme.zig").registerFonts();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".graff/views");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".graff/views/0123456789abcdef0123456789abcdef.html", .data = "<!doctype html><title>Synthetic zoom fixture</title><p>Made-up zoom target.</p>" });
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    const window = objc.msg(objc.Object, objc.alloc("NSWindow"), "initWithContentRect:styleMask:backing:defer:", .{ objc.CGRect{ .size = .{ .width = 520, .height = 400 } }, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 2), objc.NO });
    defer objc.release(window);
    const parent = objc.msg(objc.Object, window, "contentView", .{});
    // The two paths share App's production routing, not test-only zoom logic.
    for ([_]bool{ true, false }) |native_menu| {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        a.openChat("zoom-fixture", null);
        var t: nanoui.ui.Tester = undefined;
        try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1400, .height = 900 });
        defer t.deinit();
        t.settle(1);
        var probe: Probe = .{};
        const inactive = try fixtureBrowser(&a, home, parent, &probe);
        inactive.native.?.show(false);
        const focused = try fixtureBrowser(&a, home, parent, &probe);
        nanoui.runFor(3);
        try testing.expectEqualStrings("Synthetic zoom fixture", focused.native.?.title());
        try testing.expectEqualStrings("Synthetic zoom fixture", inactive.native.?.title());
        const config = objc.msg(objc.Object, focused.native.?.view, "configuration", .{});
        const store = objc.msg(objc.Object, config, "websiteDataStore", .{});
        try testing.expect(!objc.msg(objc.BOOL, store, "isPersistent", .{}));
        const items = @import("native_menu.zig").viewItems(&a);
        const menu = try nanoui.Menu.create(testing.allocator, "Fixture", &.{.{ .role = .view_menu, .submenu = &items }});
        defer menu.destroy();
        for ([_]struct { key: []const u8, code: u16, zoom: f64 }{
            .{ .key = "=", .code = 24, .zoom = 1.1 },
            .{ .key = "-", .code = 27, .zoom = 1.0 },
            .{ .key = "=", .code = 24, .zoom = 1.1 },
            .{ .key = "0", .code = 29, .zoom = 1.0 },
        }) |key| {
            if (native_menu) try testing.expect(zoomKey(menu, key.key, key.code)) else try testing.expect(t.shortcut(.{ .key = key.key[0], .cmd = true }));
            try testing.expectApproxEqAbs(key.zoom, focused.native.?.pageZoom(), 1e-12);
            try testing.expectApproxEqAbs(key.zoom, focused.zoom, 1e-12);
            try testing.expectEqual(@as(f32, 16), a.settings.uiFontSize());
            try testing.expectApproxEqAbs(@as(f64, 1), inactive.native.?.pageZoom(), 1e-12);
        }
        // A click in WebKit changes AppKit's responder without a UI event.
        // Native focus must still win even if the strip last focused chat.
        a.view.strip.focused = .{ .chat = 0 };
        try testing.expect(objc.msg(objc.BOOL, window, "makeFirstResponder:", .{focused.native.?.view}));
        if (native_menu) try testing.expect(zoomKey(menu, "=", 24)) else try testing.expect(t.shortcut(.{ .key = '=', .cmd = true }));
        try testing.expectApproxEqAbs(@as(f64, 1.1), focused.native.?.pageZoom(), 1e-12);
        try testing.expectEqual(@as(f32, 16), a.settings.uiFontSize());
        if (native_menu) try testing.expect(zoomKey(menu, "0", 29)) else try testing.expect(t.shortcut(.{ .key = '0', .cmd = true }));
        try testing.expect(objc.msg(objc.BOOL, window, "makeFirstResponder:", .{@as(?objc.Object, null)}));
        // A visible but unfocused browser, a hidden native view, and a closed
        // host panel must not steal app text zoom. Stale host focus is covered.
        for (0..3) |state| {
            a.panels.host_open = state != 2;
            a.view.strip.focused = if (state == 0) .{ .chat = 0 } else .host;
            focused.native.?.show(state != 1);
            if (native_menu) try testing.expect(zoomKey(menu, "=", 24)) else try testing.expect(t.shortcut(.{ .key = '=', .cmd = true }));
            try testing.expectEqual(@as(f32, 18), a.settings.uiFontSize());
            try testing.expectApproxEqAbs(@as(f64, 1), focused.native.?.pageZoom(), 1e-12);
            if (native_menu) try testing.expect(zoomKey(menu, "0", 29)) else try testing.expect(t.shortcut(.{ .key = '0', .cmd = true }));
            try testing.expectEqual(@as(f32, 16), a.settings.uiFontSize());
        }
    }
}

fn waitForTitle(native: *const app_browser.Native, expected: []const u8) !void {
    const deadline = std.Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(5));
    while (!std.mem.eql(u8, expected, native.title())) {
        if (std.Io.Clock.awake.now(testing.io).compare(.gte, deadline)) break;
        const pool = nanoui.objc.Pool.push();
        defer pool.pop();
        nanoui.runFor(0.01);
    }
    try testing.expectEqualStrings(expected, native.title());
}

const HiddenPreview = struct {
    const objc = nanoui.objc;
    const button: objc.CGPoint = .{ .x = 50, .y = 32 };
    const input: objc.CGPoint = .{ .x = 50, .y = 80 };

    fn windowPoint(native: *const app_browser.Native, point: objc.CGPoint) objc.CGPoint {
        const bounds = objc.msg(objc.CGRect, native.view, "bounds", .{});
        const flipped = objc.msg(objc.BOOL, native.view, "isFlipped", .{});
        return objc.msg(objc.CGPoint, native.view, "convertPoint:toView:", .{
            objc.CGPoint{ .x = point.x, .y = if (flipped) point.y else bounds.size.height - point.y },
            @as(?objc.Object, null),
        });
    }

    fn settleLayout(surface: *nanoui.Surface, browser: *const Browser) !nanoui.ui.Rect {
        // Native sync during the build consumes the preceding layout's rects.
        surface.frame();
        surface.frame();
        const body = surface.ctx.rects.get(browser.body_node) orelse return error.NoBrowserBody;
        const native = browser.native orelse return error.NoNativePreview;
        try testing.expectEqual(body, native.rect orelse return error.NoNativeRect);
        return body;
    }

    fn themeFrame(window: objc.Object) !objc.Object {
        const content = objc.msg(objc.Object, window, "contentView", .{});
        return objc.msg(?objc.Object, content, "superview", .{}) orelse error.NoThemeFrame;
    }

    fn hit(window: objc.Object, location: objc.CGPoint) !objc.Object {
        const frame = try themeFrame(window);
        const parent = objc.msg(?objc.Object, frame, "superview", .{});
        // hitTest: takes a point in the receiver's superview (window base
        // coordinates if the theme frame has no superview).
        const p = if (parent) |v| objc.msg(objc.CGPoint, v, "convertPoint:fromView:", .{ location, @as(?objc.Object, null) }) else location;
        return objc.msg(?objc.Object, frame, "hitTest:", .{p}) orelse error.NoWindowHit;
    }

    fn inPreview(view: objc.Object, native: *const app_browser.Native) bool {
        return view == native.view or objc.msg(objc.BOOL, view, "isDescendantOf:", .{native.view});
    }

    fn expectChrome(window: objc.Object, native: *const app_browser.Native, body: nanoui.ui.Rect) !void {
        // Halfway up the address bar, immediately above the body.
        try testing.expect(body.y > 19);
        const content = objc.msg(objc.Object, window, "contentView", .{});
        const location = objc.msg(objc.CGPoint, content, "convertPoint:toView:", .{
            objc.CGPoint{ .x = body.x + body.w / 2, .y = body.y - 19 }, @as(?objc.Object, null),
        });
        const target = try hit(window, location);
        try testing.expect(!inPreview(target, native));
        try testing.expectEqual(content, target);
    }

    fn click(surface: *nanoui.Surface, native: *const app_browser.Native, body: nanoui.ui.Rect, point: objc.CGPoint) !void {
        const window = surface.window.nswindow;
        const location = windowPoint(native, point);
        const p = surface.toView(location);
        try testing.expect(p.x >= body.x and p.x < body.x + body.w and p.y >= body.y and p.y < body.y + body.h);
        const target = try hit(window, location);
        if (!inPreview(target, native)) {
            const name = objc.msg(objc.Object, target, "className", .{});
            std.debug.print("Browser body hit {s} instead of WebKit\n", .{objc.fromNSString(name)});
            return error.BrowserBodyDidNotHitWebKit;
        }
        // Deliver only to the window hierarchy's hit target, not the global
        // event queue or NSWindow's window-ordering path.
        const number = objc.msg(objc.NSInteger, window, "windowNumber", .{});
        for ([_]objc.NSUInteger{ 1, 2 }) |kind| { // leftMouseDown, leftMouseUp
            const event = objc.msg(objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
                kind, location, @as(objc.NSUInteger, 0), @as(f64, 0), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), @as(objc.NSInteger, 1), @as(f32, if (kind == 1) 1 else 0),
            });
            objc.msg(void, target, if (kind == 1) "mouseDown:" else "mouseUp:", .{event});
        }
    }

    fn typeX(window: objc.Object, native: *const app_browser.Native) !void {
        const event = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
            @as(objc.NSUInteger, 10),                              objc.CGPoint{},          @as(objc.NSUInteger, 0), @as(f64, 0),
            objc.msg(objc.NSInteger, window, "windowNumber", .{}), @as(?objc.Object, null), objc.nsString("x"),      objc.nsString("x"),
            objc.NO,                                               @as(u16, 7),
        });
        // The preceding click must have moved the responder into WebKit;
        // do not repair focus just to get a successful DOM input event.
        const target = objc.msg(objc.Object, window, "firstResponder", .{});
        try testing.expect(target == native.view or objc.msg(objc.BOOL, target, "isKindOfClass:", .{objc.class("NSView")}) and
            objc.msg(objc.BOOL, target, "isDescendantOf:", .{native.view}));
        objc.msg(void, target, "keyDown:", .{event});
    }
};

test "the native Browser delivers input to a saved generated page without an engine" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    prepareAppKit();
    // HTTP(S), including localhost, routes to browse Connected Apps. A saved
    // generated page exercises the production embedded WebKit path offline.
    const id = "0123456789abcdef0123456789abcdef";
    const address = "graff-view://html/" ++ id;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".graff/views");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".graff/views/" ++ id ++ ".html",
        .data =
        \\<!doctype html><title></title>
        \\<style>body { margin: 16px; } button, input { box-sizing: border-box; display: block; width: 180px; height: 36px; margin: 0 0 12px; }</style>
        \\<button type="button">Count</button><input aria-label="Fixture text"><output>count=0; text=</output>
        \\<script>
        \\const button = document.querySelector('button'), field = document.querySelector('input');
        \\const output = document.querySelector('output');
        \\let count = 0;
        \\function show() { document.title = output.textContent = `count=${count}; text=${field.value}`; }
        \\button.addEventListener('click', event => { if (event.isTrusted) { ++count; show(); } });
        \\field.addEventListener('focus', () => { document.title = 'Fixture input focused'; });
        \\field.addEventListener('input', event => { if (event.isTrusted) show(); });
        \\document.title = 'Synthetic generated preview ready';
        \\</script>
        ,
    });
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", home);
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.env = &env;
    a.offscreen = true;
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"preview-fixture","deviceId":"synthetic-local","title":"Synthetic preview","archived":false}]
    , .{});
    defer chats.deinit();
    try a.chats.replace(chats.value);
    a.device_id = try testing.allocator.dupe(u8, "synthetic-local");
    a.openChat("preview-fixture", null);
    app_browser.openSaved(&a, "preview-fixture", @import("saved_view.zig").View.init(.html, id).?);
    app_browser.settleFrame(&a);
    const preview_tab = a.panels.active;
    const browser = (a.panels.activeTab() orelse return error.NoBrowserTab).browser orelse return error.NoBrowserTab;
    try testing.expect(browser.native == null);

    // Same native hierarchy as the app, but never ordered or made key. The
    // synthetic runtime installs no application delegate and starts no engine.
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    var runtime: nanoui.App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .options = .{ .quit_on_last_window_closed = false },
        .nsapp = nsapp,
        .delegate = nsapp,
        .flags = .{ .hidden = true },
    };
    const window = try runtime.newWindow(.{
        .width = 1400,
        .height = 900,
        .visible = false,
        .title_bar = .hidden,
        .theme = @import("theme.zig").ui(false),
        .content = .{ .view = .init(&a, @import("view.zig").view) },
    });
    defer {
        a.window = null;
        runtime.running = true;
        window.close();
        nanoui.runFor(0.1);
        runtime.windows.deinit(testing.allocator);
    }
    a.window = window;
    const surface = window.surface.?;
    try testing.expect(!objc.msg(objc.BOOL, window.nswindow, "isVisible", .{}));
    try testing.expect(!objc.msg(objc.BOOL, window.nswindow, "isKeyWindow", .{}));
    const body = try HiddenPreview.settleLayout(surface, browser);
    const native = browser.native orelse return error.NoNativePreview;
    try testing.expect(native.visible);
    // This route locks navigation to the saved page and uses no app bridge or
    // persistent website data. The native view is created by the real layout.
    try testing.expect(!native.allowsBackForwardGestures());
    const config = objc.msg(objc.Object, native.view, "configuration", .{});
    const store = objc.msg(objc.Object, config, "websiteDataStore", .{});
    try testing.expect(!objc.msg(objc.BOOL, store, "isPersistent", .{}));
    const controller = objc.msg(objc.Object, config, "userContentController", .{});
    const scripts = objc.msg(objc.Object, controller, "userScripts", .{});
    try testing.expectEqual(@as(objc.NSUInteger, 0), objc.msg(objc.NSUInteger, scripts, "count", .{}));
    try waitForTitle(native, "Synthetic generated preview ready");
    try testing.expectEqualStrings(address, native.url());

    objc.msg(void, try HiddenPreview.themeFrame(window.nswindow), "layoutSubtreeIfNeeded", .{});
    try HiddenPreview.expectChrome(window.nswindow, native, body);
    try HiddenPreview.click(surface, native, body, HiddenPreview.button);
    try waitForTitle(native, "count=1; text=");
    try HiddenPreview.click(surface, native, body, HiddenPreview.input);
    try waitForTitle(native, "Fixture input focused");
    try HiddenPreview.typeX(window.nswindow, native);
    try waitForTitle(native, "count=1; text=x");

    app_browser.openBlank(&a);
    app_browser.settleFrame(&a);
    try testing.expect(a.panels.active != preview_tab);
    surface.frame();
    try testing.expect(!native.visible);
    try testing.expect(objc.msg(objc.BOOL, native.view, "isHidden", .{}));
    try testing.expect(a.panels.activeTab().?.browser.?.native == null);
    @import("app_panels.zig").showTab(&a, preview_tab);
    const restored_body = try HiddenPreview.settleLayout(surface, browser);
    try testing.expectEqual(native, browser.native.?);
    try testing.expect(native.visible);
    objc.msg(void, try HiddenPreview.themeFrame(window.nswindow), "layoutSubtreeIfNeeded", .{});
    try HiddenPreview.expectChrome(window.nswindow, native, restored_body);
    try HiddenPreview.click(surface, native, restored_body, HiddenPreview.button);
    try waitForTitle(native, "count=2; text=x");
    try HiddenPreview.click(surface, native, restored_body, HiddenPreview.input);
    try waitForTitle(native, "Fixture input focused");
    try HiddenPreview.typeX(window.nswindow, native);
    try waitForTitle(native, "count=2; text=xx");
    try testing.expect(!objc.msg(objc.BOOL, window.nswindow, "isVisible", .{}));
    try testing.expect(!objc.msg(objc.BOOL, window.nswindow, "isKeyWindow", .{}));

    const Native = app_browser.Native;
    native.setZoom(Native.nextZoom(native.pageZoom(), .out));
    try testing.expectApproxEqAbs(@as(f64, 0.9090909090909091), native.pageZoom(), 1e-12);
    native.setZoom(Native.nextZoom(native.pageZoom(), .in));
    try testing.expectApproxEqAbs(@as(f64, 1.0), native.pageZoom(), 1e-12);
    native.setZoom(Native.nextZoom(native.pageZoom(), .in));
    try testing.expectApproxEqAbs(@as(f64, 1.1), native.pageZoom(), 1e-12);
    native.setZoom(Native.nextZoom(native.pageZoom(), .reset));
    try testing.expectApproxEqAbs(@as(f64, 1.0), native.pageZoom(), 1e-12);
}
