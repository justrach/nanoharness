//! Native browser chrome; WebKit occupies only the content rectangle.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const App = @import("app.zig").App;
const Browser = @import("app_browser.zig").Browser;

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, b: *Browser) void {
    if (c.shortcut(.{ .key = '-', .cmd = true })) b.applyZoom(.out);
    if (c.shortcut(.{ .key = '=', .cmd = true }) or c.shortcut(.{ .key = '+', .cmd = true, .shift = true })) b.applyZoom(.in);
    if (c.shortcut(.{ .key = '0', .cmd = true })) b.applyZoom(.reset);
    {
        const bar = ui.div(c).row().wFull().h(38).px(8).gap(4).itemsCenter().border(k.border).borderW(1);
        defer bar.end();
        if (comptime builtin.os.tag == .macos) {
            const n = b.native;
            if (kit.iconButton(c, k, .@"arrow-left", .{ .size = 24, .icon = 13, .tip = .{ .text = "Back" } })) if (n) |native| if (native.canBack()) native.back();
            if (kit.iconButton(c, k, .@"arrow-right", .{ .size = 24, .icon = 13, .tip = .{ .text = "Forward" } })) if (n) |native| if (native.canForward()) native.forward();
            if (kit.iconButton(c, k, .refresh, .{ .size = 24, .icon = 13, .tip = .{ .text = "Reload" } })) if (n) |native| native.reload();
        }
        if (b.saved_view != null) {
            kit.fadeText(c, b.address.text(), .{ .size = 11, .color = k.muted }, 330);
        } else {
            const field = ui.div(c).row().grow().w(0).px(6).itemsCenter().rounded(5).bg(k.ink(0.04));
            defer field.end();
            ui.key(c, "browser-address");
            const at = c.nodes.items.len;
            const r = ui.textField(c, &b.address, .{ .bare = true, .width = .fill, .size = 11.5, .placeholder = "Website or localhost" });
            const id = c.node(@intCast(at)).id;
            if (b.focus_address) {
                c.focus = id;
                c.changed = true;
                b.focus_address = false;
            }
            b.editing = c.focus == id;
            if (r.submitted) b.navigate(b.address.text());
        }
        // Confirmation belongs to this browser/address, not another tab that
        // happens to occupy the same chrome slot.
        ui.key(c, c.print("browser-copy-{x}-{s}", .{ @intFromPtr(b), b.address.text() }));
        if (kit.copyButton(c, k, &a.view.copy_feedback, .{ .size = 24, .icon = 13, .disabled = b.address.text().len == 0, .tip = .{ .text = "Copy address" } })) c.clipboard.write(c.clipboard.ctx, b.address.text());
        if (b.saved_view == null and b.url.len > 0 and @import("browser_url.zig").allowedNavigation(b.url)) {
            if (kit.iconButton(c, k, .@"arrow-up-right", .{ .size = 24, .icon = 13, .tip = .{ .text = "Open in browser" } })) _ = @import("app_browser.zig").open_external_url(b.url);
        }
    }
    if (b.saved_view == null and b.url.len > 0 and @import("browser_url.zig").requiresSystemBrowserForPasskeys(b.url)) {
        ui.key(c, "browser-passkey-handoff");
        const bar = ui.div(c).row().wFull().px(12).py(8).gap(10).itemsCenter().bg(k.ink(0.05)).border(k.border).borderW(1);
        defer bar.end();
        @import("icons.zig").icon(c, .globe, 15, k.muted, 0);
        {
            const host_w = if (a.view.chrome.host_width > 0) a.view.chrome.host_width else 520;
            const avail = @max(140, host_w - 190);
            const msg = ui.div(c).column().grow().w(0).gap(2);
            defer msg.end();
            kit.ellipsisText(c, "Passkeys aren't supported in the in-app browser.", .{ .size = 12, .line_height = 16, .weight = .medium, .color = k.text }, avail);
            kit.ellipsisText(c, "Finish OpenAI sign-in in your system browser.", .{ .size = 11.5, .line_height = 15, .color = k.muted }, avail);
        }
        ui.key(c, "browser-passkey-open-external");
        const open_btn = ui.div(c).row().px(10).py(5).gap(5).itemsCenter().rounded(7).bg(k.solid).hover(k.solid.alpha(0.88)).control();
        defer open_btn.end();
        ui.text(c, "Open in browser", .{ .size = 12, .line_height = 16, .weight = .medium, .color = k.on_solid });
        @import("icons.zig").icon(c, .@"arrow-up-right", 12, k.on_solid, 0);
        if (open_btn.clicked()) _ = @import("app_browser.zig").open_external_url(b.url);
    }
    if (b.notice.text().len > 0) {
        const notice = ui.div(c).column().wFull().px(12).py(8);
        defer notice.end();
        ui.text(c, b.notice.text(), .{ .size = 12, .wrap = true, .color = k.danger });
    }
    if (comptime builtin.os.tag == .macos) {
        if (b.saved_view) |saved| if (saved.kind == .mcpApp) {
            const notice = ui.div(c).column().wFull().px(12).py(8);
            defer notice.end();
            ui.text(c, "Saved result. Live tool calls are unavailable.", .{ .size = 12, .wrap = true, .color = k.muted });
        };
    }
    const body = ui.div(c).column().wFull().grow().h(0).center().gap(8);
    defer body.end();
    b.body_node = c.node(body.index).id;
    if (b.url.len == 0) {
        @import("icons.zig").icon(c, .globe, 28, k.faint, 0);
        ui.text(c, "Open a website or local development server.", .{ .size = 12, .color = k.muted });
        ui.text(c, "Enter an address above, such as localhost:3000.", .{ .size = 11, .color = k.faint });
    } else if (builtin.os.tag != .macos) {
        ui.text(c, "The integrated browser is available on macOS.", .{ .size = 12, .color = k.muted });
    } else if (a.window == null) {
        // ui.Tester renders native chrome without launching a browser process.
        ui.text(c, "Integrated browser", .{ .size = 12, .color = k.faint });
    }
}
