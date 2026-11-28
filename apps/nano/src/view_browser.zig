//! Native browser chrome; WebKit occupies only the content rectangle.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const icons = @import("icons.zig");
const App = @import("app.zig").App;
const Browser = @import("app_browser.zig").Browser;
const ux = @import("ux_rules.zig").BrowseConnect;
const browse_connect = @import("browse_connect.zig");

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, b: *Browser) void {
    if (c.shortcut(.{ .key = '-', .cmd = true })) b.applyZoom(.out);
    if (c.shortcut(.{ .key = '=', .cmd = true }) or c.shortcut(.{ .key = '+', .cmd = true, .shift = true })) b.applyZoom(.in);
    if (c.shortcut(.{ .key = '0', .cmd = true })) b.applyZoom(.reset);
    {
        const bar = ui.div(c).row().wFull().h(38).px(8).gap(4).itemsCenter().border(k.border).borderW(1);
        defer bar.end();
        const is_external = !b.usesEmbeddedWebView();
        if (is_external) {
            const bc = a.ensureBrowseClient();
            const conn = bc.status() == .connected;
            if (kit.iconButton(c, k, .@"arrow-left", .{ .size = 24, .icon = 13, .tip = .{ .text = "Back" } }) and conn) bc.spawnOp(.back, "", 0, 0);
            if (kit.iconButton(c, k, .@"arrow-right", .{ .size = 24, .icon = 13, .tip = .{ .text = "Forward" } }) and conn) bc.spawnOp(.forward, "", 0, 0);
            if (kit.iconButton(c, k, .refresh, .{ .size = 24, .icon = 13, .tip = .{ .text = "Reload" } }) and conn) bc.spawnOp(.reload, "", 0, 0);
        } else if (comptime builtin.os.tag == .macos) {
            const n = b.native;
            if (b.artifact_id == null) {
                if (kit.iconButton(c, k, .@"arrow-left", .{ .size = 24, .icon = 13, .tip = .{ .text = "Back" } })) if (n) |native| if (native.canBack()) native.back();
                if (kit.iconButton(c, k, .@"arrow-right", .{ .size = 24, .icon = 13, .tip = .{ .text = "Forward" } })) if (n) |native| if (native.canForward()) native.forward();
            }
            if (kit.iconButton(c, k, .refresh, .{ .size = 24, .icon = 13, .tip = .{ .text = "Reload" } })) if (n) |native| native.reload();
        }
        if (b.artifact_id != null) {
            kit.fadeText(c, b.title.text(), .{ .size = 11.5, .weight = .medium, .color = k.text }, 330);
        } else if (b.saved_view != null) {
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
    if (!b.usesEmbeddedWebView()) {
        drawBrowseViewport(c, a, k, b);
        return;
    }
    if (b.saved_view == null and b.artifact_id == null and b.url.len > 0 and @import("browser_url.zig").requiresSystemBrowserForPasskeys(b.url)) {
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

fn drawBrowseViewport(c: *ui.Context, a: *App, k: theme.Colors, b: *Browser) void {
    const bc = a.ensureBrowseClient();
    bc.setSession(b.parent);
    if (bc.state == .waiting_browse_launch or bc.state == .needs_browse_install) {
        if (a.window != null and !a.offscreen) bc.spawnOp(.probe, "", 0, 0);
    }

    const area = ui.div(c).column().wFull().grow().h(0).p(12).gap(10).bg(k.panel);
    defer area.end();

    const st = bc.status();
    // Action header bar for `justrach/browse` Connected Apps (`v1-p256-sig`).
    {
        const bar = ui.div(c).row().wFull().gap(6).itemsCenter();
        defer bar.end();
        const badge_label = switch (st) {
            .needs_browse_install => "Install browse",
            .waiting_browse_launch => "Launch browse",
            .discovered => "Ready to pair",
            .pairing_pending => "Confirm 6-digit code",
            .connected => "browse Connected",
            .pair_denied => "Pairing declined",
            .token_expired => "Session expired",
        };
        const pill = ui.div(c).row().h(24).px(8).gap(6).itemsCenter().rounded(6)
            .bg(if (st == .connected) k.success.alpha(0.14) else k.ink(0.06));
        icons.icon(c, .globe, 12, if (st == .connected) k.success else k.muted, 0);
        ui.text(c, badge_label, .{ .size = 11, .weight = .medium, .color = if (st == .connected) k.success else k.text });
        pill.end();

        if (st == .connected) {
            if (browseBtn(c, k, "Back", false)) bc.spawnOp(.back, "", 0, 0);
            if (browseBtn(c, k, "Forward", false)) bc.spawnOp(.forward, "", 0, 0);
            if (browseBtn(c, k, "Reload", false)) bc.spawnOp(.reload, "", 0, 0);
            if (browseBtn(c, k, "Send to Design", false)) {
                a.settings.applyUiMode(.design);
                a.view.design.source = .browse_snapshot;
                a.view.design.preview_url.set(b.url);
                @import("app_panels.zig").openDesignCanvas(a);
            }
        }
        ui.spacer(c);
        if (st == .connected) {
            if (browseBtn(c, k, "Open in browse", true)) {
                // The browse window outlives this tab, and Nano cannot see it.
                a.preview_consumers.hold(a.gpa, b.url);
                bc.spawnOp(.show, "", 0, 0);
            }
        } else if (b.url.len > 0) {
            if (browseBtn(c, k, "Open externally", false)) {
                a.preview_consumers.hold(a.gpa, b.url);
                _ = @import("app_browser.zig").open_external_url(b.url);
            }
        }
    }

    switch (st) {
        .needs_browse_install => {
            const card = ui.div(c).column().wFull().p(16).gap(10).rounded(12).bg(k.composer).border(k.border).borderW(1);
            defer card.end();
            ui.text(c, "Keep your logins & passkeys with browse.app", .{ .size = 14, .weight = .semibold, .color = k.text });
            ui.text(c, "Nano does not embed an unauthenticated web view for public sites. Install justrach/browse to pair locally over P-256 ECDH/ECDSA (`v1-p256-sig`) and view live authenticated tabs inside this pane.", .{ .size = 12, .wrap = true, .color = k.muted });
            const row = ui.div(c).row().gap(8).itemsCenter();
            defer row.end();
            if (browseBtn(c, k, "Download browse", true)) _ = @import("nanoui").shell.openUrl(browse_connect.release_url);
            if (browseBtn(c, k, "Check again", false)) bc.spawnOp(.probe, "", 0, 0);
        },
        .waiting_browse_launch => {
            const card = ui.div(c).column().wFull().p(16).gap(10).rounded(12).bg(k.composer).border(k.border).borderW(1);
            defer card.end();
            ui.text(c, "browse.app is installed — launch it to pair", .{ .size = 14, .weight = .semibold, .color = k.text });
            ui.text(c, "Open browse so Nano can discover ~/Library/Application Support/browse/Agent/connect.json and request one-time P-256 pairing.", .{ .size = 12, .wrap = true, .color = k.muted });
            const row = ui.div(c).row().gap(8).itemsCenter();
            defer row.end();
            if (browseBtn(c, k, "Open browse app", true)) {
                browse_connect.launchBrowseApp(a.io);
                bc.spawnOp(.probe, "", 0, 0);
            }
            if (browseBtn(c, k, "Retry discovery", false)) bc.spawnOp(.probe, "", 0, 0);
        },
        .discovered, .pair_denied, .token_expired => {
            const card = ui.div(c).column().wFull().p(16).gap(10).rounded(12).bg(k.composer).border(k.border).borderW(1);
            defer card.end();
            ui.text(c, "Pair Nano with browse Connected Apps", .{ .size = 14, .weight = .semibold, .color = k.text });
            ui.text(c, "Generates an ephemeral P-256 client keypair (`X-Signature` DER) and requests scoped session control with your signed-in cookies intact.", .{ .size = 12, .wrap = true, .color = k.muted });
            if (browseBtn(c, k, "Pair with browse", true)) bc.spawnOp(.pair, "", 0, 0);
        },
        .pairing_pending => {
            const card = ui.div(c).column().wFull().p(16).gap(10).rounded(12).bg(k.composer).border(k.accent.alpha(0.4)).borderW(1);
            defer card.end();
            ui.text(c, "Approve Connected App in browse", .{ .size = 14, .weight = .semibold, .color = k.text });
            ui.text(c, &bc.pair.code_display, .{ .size = 24, .weight = .semibold, .mono = true, .color = k.accent });
            ui.text(c, "Confirm this 6-digit P-256 verification code in the browse Connected Apps prompt.", .{ .size = 12, .wrap = true, .color = k.muted });
            if (browseBtn(c, k, "Check approval", true)) bc.spawnOp(.poll_pair, "", 0, 0);
        },
        .connected => {
            const snap = bc.snapshotCopy(c.alloc());
            if (snap) |img| {
                ui.key(c, "browse-live-viewport");
                const stage_peek = c.peekId(null);
                const focused = c.focus == stage_peek;
                const stage = ui.div(c).column().wFull().grow().h(0).rounded(10).bg(k.background)
                    .border(if (focused) k.accent else k.border).borderW(1).clip().control().wheel();
                const stage_id = c.node(stage.index).id;
                c.addA11y(stage.index, .group, "Connected browse viewport", "", false, true);
                _ = c.interact(stage.index, .{ .focusable = true });
                defer stage.end();
                const rect = c.rects.get(stage_id) orelse ui.Rect{ .x = 0, .y = 0, .w = 480, .h = 360 };
                _ = ui.image(c, .{
                    .key = c.print("browse-frame-{d}", .{img.seq}),
                    .source = .{ .encoded = img.png },
                    .box = .{ .w = @max(120, rect.w), .h = @max(120, rect.h) },
                    .radius = 10,
                });
                if (stage.clicked()) {
                    c.focus = stage_id;
                    c.changed = true;
                    const rel_x: i32 = @intFromFloat(@round(@max(0, c.input.mouse.x - rect.x)));
                    const rel_y: i32 = @intFromFloat(@round(@max(0, c.input.mouse.y - rect.y)));
                    bc.spawnOp(.click_at, "", rel_x, rel_y);
                }
                if (c.focus == stage_id and !b.editing) {
                    for (c.input.ops) |op| switch (op) {
                        .insert => |txt| if (txt.len > 0) bc.spawnOp(.type_text, txt, 0, 0),
                        .command => |cmd| {
                            const key_name: ?[]const u8 = switch (cmd) {
                                .insert_newline, .insert_line_break => "Enter",
                                .delete_backward => "Backspace",
                                .delete_forward => "Delete",
                                .insert_tab => "Tab",
                                .move_up => "ArrowUp",
                                .move_down => "ArrowDown",
                                .move_left => "ArrowLeft",
                                .move_right => "ArrowRight",
                                else => null,
                            };
                            if (key_name) |kn| bc.spawnOp(.press_key, kn, 0, 0);
                        },
                        else => {},
                    };
                    if (c.input.key) |kv| {
                        const mapped: ?[]const u8 = switch (kv) {
                            .enter => "Enter",
                            .backspace => "Backspace",
                            .delete => "Delete",
                            .tab => "Tab",
                            .up => "ArrowUp",
                            .down => "ArrowDown",
                            .left => "ArrowLeft",
                            .right => "ArrowRight",
                            else => null,
                        };
                        if (mapped) |kn| {
                            bc.spawnOp(.press_key, kn, 0, 0);
                            c.input.key = null;
                        }
                    }
                }
                if (stage.hovered() and c.input.scroll.y != 0) {
                    const dy: i32 = @intFromFloat(@round(c.input.scroll.y));
                    c.input.scroll.y = 0;
                    bc.spawnOp(.scroll, "", 0, dy);
                }
            } else {
                const empty = ui.div(c).column().wFull().grow().h(0).center().gap(8).rounded(10).bg(k.composer).border(k.border).borderW(1);
                defer empty.end();
                ui.text(c, "Connected to browse — loading viewport…", .{ .size = 13, .color = k.muted });
                if (b.url.len > 0) {
                    if (browseBtn(c, k, "Open URL in pane", true)) bc.spawnOp(.open_url, b.url, 0, 0);
                }
            }
        },
    }
}

fn browseBtn(c: *ui.Context, k: theme.Colors, label: []const u8, primary: bool) bool {
    ui.key(c, label);
    var b = ui.div(c).row().h(26).px(10).itemsCenter().rounded(7).control();
    b = if (primary) b.bg(k.accent) else b.bg(k.ink(0.06)).hover(k.hover);
    defer b.end();
    ui.text(c, label, .{ .size = 11.5, .weight = if (primary) .medium else .regular, .color = if (primary) k.onAccent() else k.text });
    return b.clicked();
}
