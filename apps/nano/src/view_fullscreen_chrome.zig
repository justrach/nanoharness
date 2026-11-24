//! Browse-style minimal full-screen chrome over pure #000000 black:
//! - Top-edge centered pill handle (Fold.swift) revealing a floating top bar on click or edge dwell.
//! - Borderless 28pt pane caption strip above each card (Split.swift) showing chat/project/branch/device
//!   or interactive folder/computer pickers on draft panes, plus subtle swap/expand/close & ⌘K controls.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const chrome = @import("panel_chrome.zig");
const tabs = @import("tabs.zig");
const strip = @import("view_tab_strip.zig");
const footer_view = @import("view_session_footer.zig");
const header_view = @import("view_chat_header.zig");
const sidebar = @import("view_sidebar.zig");
const palette_view = @import("view_palette.zig");
const App = @import("app.zig").App;

const phi: f32 = 1.618;

fn knownDevice(a: *const App, id: ?[]const u8) ?[]const u8 {
    const want = id orelse return null;
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, want)) return d.name;
    return null;
}

pub fn updatePeek(c: *ui.Context, a: *App) void {
    if (!a.view.full_screen) return;
    if (!a.view.fs_top_peek and
        !c.input.pressed and
        !c.input.released and
        c.input.mouse.x >= a.view.sidebar_width and
        c.input.mouse.y > 0 and
        c.input.mouse.y <= 2.5 and
        !a.view.palette.open and
        !a.view.settings_open and
        a.view.strip.menu == null)
    {
        a.view.fs_top_peek = true;
        a.redraw();
    }
}

pub fn drawTopHandle(c: *ui.Context, a: *App) void {
    if (!a.view.full_screen or a.view.fs_top_peek) return;
    const x = a.view.sidebar_width;
    const w = @max(0, c.size.w - x);
    if (w < 40) return;
    const dk = theme.colors(true);
    ui.key(c, "fullscreen-top-handle-bar");
    const bar = ui.div(c).fixed().offset(x, 0).size(w, chrome.fs_handle_h).row().justifyCenter().itemsCenter().layer(3);
    defer bar.end();
    ui.key(c, "fullscreen-top-handle");
    const hit = tip.on(
        ui.div(c).row().size(96, chrome.fs_handle_h).center().control(),
        dk,
        .{ .text = "Click or move to top edge for tabs & controls", .look = .tab },
    );
    defer hit.end();
    const hot = hit.hovered();
    ui.div(c).size(if (hot) @as(f32, 58) else 44, if (hot) @as(f32, 3) else 2.5)
        .rounded(if (hot) @as(f32, 1.5) else 1.25)
        .bg(ui.Color.white.alpha(if (hot) 0.55 else 0.24))
        .end();
    if (hit.clicked()) {
        a.view.fs_top_peek = true;
        a.redraw();
    }
}

pub fn drawTopPeek(c: *ui.Context, a: *App, strip_layout: strip.rendering.Layout, pane_widths: *const [tabs.max_panes]?f32) void {
    if (!a.view.full_screen or !a.view.fs_top_peek) return;
    const dk = theme.colors(true);

    // Click anywhere below the floating peek bar to tuck it back into the bezel.
    ui.key(c, "fullscreen-top-peek-scrim");
    const scrim = ui.div(c).fixed().offset(0, chrome.header_height).size(c.size.w, @max(0, c.size.h - chrome.header_height)).layer(1);
    defer scrim.end();
    if (scrim.clicked()) {
        a.view.fs_top_peek = false;
        a.redraw();
        return;
    }

    const bar_x = a.view.sidebar_width;
    const bar_w = @max(0, c.size.w - bar_x);
    ui.key(c, "fullscreen-top-peek-backdrop");
    {
        const bg = ui.div(c).fixed().offset(bar_x, 0).size(bar_w, chrome.header_height).column().bg(ui.Color.black.alpha(0.95)).layer(2);
        defer bg.end();
        ui.spacer(c);
        ui.div(c).wFull().h(1).bg(ui.Color.white.alpha(0.10)).end();
    }

    strip.draw(c, a, dk, strip_layout, pane_widths);

    if (!a.view.sidebar_open) {
        ui.key(c, "fullscreen-peek-sidebar-toggle");
        const lead = ui.div(c).fixed().offset(12, 4 + (34 - 24) / 2).row().itemsCenter().gap(4).layer(3);
        defer lead.end();
        if (darkIconButton(c, dk, .@"sidebar-minimalistic-left", 24, 15, "Show sidebar (\u{2318}B)", false)) {
            a.view.sidebar_open = true;
            a.view.fs_top_peek = false;
            a.redraw();
        }
    }

    ui.key(c, "fullscreen-peek-exit");
    const exit_x = @max(bar_x + 12, c.size.w - 118);
    const trail = ui.div(c).fixed().offset(exit_x, 4 + (34 - 24) / 2).row().itemsCenter().layer(3);
    defer trail.end();
    var exit_btn = tip.on(
        ui.div(c).row().h(24).px(8).gap(4).center().rounded(6).bg(ui.Color.white.alpha(0.08)).hover(ui.Color.white.alpha(0.16)).control(),
        dk,
        .{ .text = "Exit full screen", .look = .tab },
    );
    defer exit_btn.end();
    icons.icon(c, .@"expand-arrows", 11, ui.Color.white.alpha(0.75), 0);
    ui.text(c, "Exit full screen", .{ .size = 11, .line_height = 14, .weight = .medium, .color = ui.Color.white.alpha(0.85) });
    if (exit_btn.clicked()) a.setFullScreen(false);
}

pub fn chatHeader(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    pane_ix: usize,
    chat_id: ?[]const u8,
    pane_w: f32,
    focused: bool,
    is_split: bool,
) void {
    const dk = theme.colors(true);
    ui.key(c, c.print("fs-pane-header-{d}", .{pane_ix}));
    const bar = ui.div(c).row().wFull().h(chrome.fs_pane_header_h).px(6).gap(6).itemsCenter().clip();
    defer bar.end();
    const row_hot = bar.hovered();

    if (chat_id) |cid| {
        const chat = a.findChat(cid);
        const space = if (chat) |ch| a.findSpace(ch.space_id) else null;

        var proj_icon: icons.Name = if (chat != null) .folder else .@"chat-round-line";
        var proj_name: ?[]const u8 = null;
        var proj_tip: ?[]const u8 = null;
        var checkout: footer_view.Checkout = .local;
        if (space) |sp| {
            if (chat) |ch| checkout = if (sp.git) footer_view.checkoutOf(ch, sp) else .local;
            if (sp.git and checkout != .local) proj_icon = .@"folder-with-files";
            proj_name = sp.name;
            const path = if (chat) |ch| (ch.cwd orelse sp.path) else sp.path;
            proj_tip = if (sp.git) c.print("{s} \u{00b7} {s}", .{ checkout.label(), path }) else path;
        } else if (chat) |ch| if (ch.cwd) |cwd| if (cwd.len > 0) {
            proj_name = header_view.pathBasename(cwd);
            proj_tip = cwd;
        };

        const branch: ?[]const u8 = if (space) |sp|
            (if (sp.git and chat != null) (chat.?.row_branch orelse chat.?.branch) else null)
        else
            null;
        const dev_id: ?[]const u8 = if (chat) |ch| ch.device_id else null;
        const is_remote = if (dev_id) |did| (if (a.device_id) |local| !std.mem.eql(u8, did, local) else true) else false;
        const device_name: ?[]const u8 = if (is_remote or pane_w >= 620) knownDevice(a, dev_id) else null;
        const title: []const u8 = if (chat) |ch| sidebar.chatLabel(ch) else "Conversation";

        const trailing_w: f32 = if (is_split) 74 else 128;
        const proj_style: ui.TextStyle = .{ .size = 11, .line_height = 14, .weight = .medium };
        const meta_style: ui.TextStyle = .{ .size = 10.5, .line_height = 14 };
        const show_proj = proj_name != null and pane_w >= 240;
        const proj_max: f32 = if (show_proj) @min(@min(130, pane_w * 0.24), @ceil(c.text.width(proj_name.?, proj_style))) else 0;
        const proj_w: f32 = if (proj_max > 0) proj_max + 20 else 0;
        const show_branch = branch != null and pane_w >= 390;
        const branch_max: f32 = if (show_branch) @min(@min(135, pane_w * 0.22), @ceil(c.text.width(branch.?, meta_style))) else 0;
        const branch_w: f32 = if (branch_max > 0) branch_max + 26 else 0;
        const show_device = device_name != null and (is_remote or pane_w >= 620);
        const device_max: f32 = if (show_device) @min(@min(120, pane_w * 0.18), @ceil(c.text.width(device_name.?, meta_style))) else 0;
        const device_w: f32 = if (device_max > 0) device_max + 24 else 0;
        const lead_icon_w: f32 = (if (focused) @as(f32, 11) else 0) + 18;
        const title_max = @max(72, pane_w - 12 - trailing_w - lead_icon_w - proj_w - branch_w - device_w - 12);

        {
            const lead = ui.div(c).row().grow().w(0).gap(6).itemsCenter().clip().control();
            defer lead.end();
            if (focused) {
                ui.div(c).size(5, 5).rounded(2.5).bg(k.accent.alpha(0.92)).end();
            }
            icons.icon(c, proj_icon, 12.5, ui.Color.white.alpha(if (focused) 0.78 else 0.45), 0);
            const title_style: ui.TextStyle = .{
                .size = 11.5,
                .line_height = 15,
                .weight = if (focused) .semibold else .regular,
                .color = ui.Color.white.alpha(if (focused) 0.92 else 0.55),
            };
            const truncated = c.text.width(title, title_style) > title_max;
            var title_wrap = ui.div(c).row().grow().w(0).itemsCenter().clip();
            if (truncated) title_wrap = tip.on(title_wrap, dk, .{ .text = title, .look = .tab });
            {
                defer title_wrap.end();
                kit.ellipsisText(c, title, title_style, title_max);
            }
            if (proj_max > 0) if (proj_name) |pn| {
                var pchip = ui.div(c).row().h(18).px(5).gap(4).itemsCenter().rounded(4)
                    .bg(ui.Color.white.alpha(if (focused) 0.085 else 0.05)).clip();
                if (proj_tip) |pt| pchip = tip.on(pchip, dk, .{ .text = pt, .look = .tab });
                defer pchip.end();
                kit.ellipsisText(c, pn, .{
                    .size = 11,
                    .line_height = 14,
                    .weight = .medium,
                    .color = ui.Color.white.alpha(if (focused) 0.78 else 0.48),
                }, proj_max);
            };
            if (branch_max > 0) if (branch) |br| {
                var bchip = ui.div(c).row().h(18).px(5).gap(3).itemsCenter().rounded(4)
                    .bg(ui.Color.white.alpha(if (focused) 0.08 else 0.045)).clip();
                if (proj_tip) |pt| bchip = tip.on(bchip, dk, .{ .text = pt, .look = .tab });
                defer bchip.end();
                icons.icon(c, .@"git-branch", 10.5, ui.Color.white.alpha(if (focused) 0.68 else 0.42), 0);
                kit.ellipsisText(c, br, .{
                    .size = 10.5,
                    .line_height = 14,
                    .color = ui.Color.white.alpha(if (focused) 0.72 else 0.45),
                }, branch_max);
            };
            if (device_max > 0) if (device_name) |dn| {
                const dchip = ui.div(c).row().h(18).px(4).gap(3).itemsCenter().clip();
                defer dchip.end();
                icons.icon(c, .monitor, 10.5, ui.Color.white.alpha(if (focused) 0.65 else 0.42), 0);
                kit.ellipsisText(c, dn, .{
                    .size = 10.5,
                    .line_height = 14,
                    .color = ui.Color.white.alpha(if (focused) 0.72 else 0.45),
                }, device_max);
            };
            if (!focused and lead.clicked()) strip.queue(a, .{ .focus = .{ .chat = pane_ix } });
        }
    } else {
        // Draft pane: explicit clickable project & computer pills on the black bezel strip.
        const target: strip.Panel = .{ .chat = pane_ix };
        const proj = strip.folder(a, target);
        const proj_name = if (proj) |f| f.name else "No project";
        const computer = strip.deviceLabel(a, strip.device(a, target));
        const trailing_w: f32 = if (is_split) 74 else 128;
        const avail = @max(80, pane_w - 16 - trailing_w - (if (focused) @as(f32, 11) else 0));
        const chip_cap = @max(42, (avail - 64) / 2);

        if (focused) {
            ui.div(c).size(5, 5).rounded(2.5).bg(k.accent.alpha(0.92)).end();
        }
        {
            ui.key(c, c.print("fs-draft-folder-{d}", .{pane_ix}));
            var fpill = tip.on(
                ui.div(c).row().h(20).px(6).gap(4).itemsCenter().rounded(5)
                    .bg(ui.Color.white.alpha(if (focused) 0.12 else 0.06))
                    .hover(ui.Color.white.alpha(0.18)).control(),
                dk,
                .{ .text = "Choose project / folder", .look = .tab },
            );
            defer fpill.end();
            const frect = c.rects.get(c.node(fpill.index).id);
            if (focused) if (frect) |r| {
                a.view.strip.active_folder_anchor = r;
            };
            icons.icon(c, .folder, 11, ui.Color.white.alpha(if (focused) 0.85 else 0.55), 0);
            kit.ellipsisText(c, proj_name, .{
                .size = 11.5,
                .line_height = 14,
                .weight = if (focused) .medium else .regular,
                .color = ui.Color.white.alpha(if (focused) 0.92 else 0.62),
            }, chip_cap);
            icons.icon(c, .@"alt-arrow-down", 10, ui.Color.white.alpha(0.55), 0);
            if (fpill.clicked()) {
                const state = &a.view.strip;
                if (state.menu == .folder and !state.footer_folder and strip.same(state.target, target)) {
                    state.menu = null;
                } else {
                    if (!focused) strip.queue(a, .{ .focus = target });
                    strip.open(a, .folder, target, frect);
                }
            }
        }
        {
            ui.key(c, c.print("fs-draft-device-{d}", .{pane_ix}));
            var dpill = tip.on(
                ui.div(c).row().h(20).px(6).gap(4).itemsCenter().rounded(5)
                    .bg(ui.Color.white.alpha(if (focused) 0.10 else 0.05))
                    .hover(ui.Color.white.alpha(0.16)).control(),
                dk,
                .{ .text = "Choose computer / runtime host", .look = .tab },
            );
            defer dpill.end();
            const drect = c.rects.get(c.node(dpill.index).id);
            if (focused and a.view.strip.menu != .device) if (drect) |r| {
                a.view.strip.device_anchor = r;
            };
            icons.icon(c, .monitor, 11, ui.Color.white.alpha(if (focused) 0.80 else 0.52), 0);
            kit.ellipsisText(c, computer, .{
                .size = 11,
                .line_height = 14,
                .color = ui.Color.white.alpha(if (focused) 0.84 else 0.55),
            }, chip_cap);
            icons.icon(c, .@"alt-arrow-down", 10, ui.Color.white.alpha(0.50), 0);
            if (dpill.clicked()) {
                const state = &a.view.strip;
                if (state.menu == .device and strip.same(state.target, target)) {
                    state.menu = null;
                } else {
                    if (!focused) strip.queue(a, .{ .focus = target });
                    strip.open(a, .device, target, drect);
                }
            }
        }
        const gap_fill = ui.div(c).row().grow().w(0).hFull().control();
        gap_fill.end();
        if (!focused and gap_fill.clicked()) strip.queue(a, .{ .focus = target });
    }

    trailingControls(c, a, dk, pane_ix, focused, is_split, row_hot);
}

fn trailingControls(
    c: *ui.Context,
    a: *App,
    dk: theme.Colors,
    pane_ix: usize,
    focused: bool,
    is_split: bool,
    row_hot: bool,
) void {
    if (is_split) {
        const op: f32 = if (focused or row_hot) 1.0 else 0.35;
        const actions = ui.div(c).row().gap(2).itemsCenter().opacity(op);
        defer actions.end();
        const target: strip.Panel = .{ .chat = pane_ix };
        ui.key(c, c.print("fs-pane-swap-{d}", .{pane_ix}));
        if (darkIconButton(
            c,
            dk,
            if (pane_ix == 0) .@"alt-arrow-right" else .@"alt-arrow-left",
            22,
            11,
            "Swap split sides",
            false,
        )) {
            strip.queue(a, if (pane_ix == 0) .{ .move_right = target } else .{ .move_left = target });
        }
        ui.key(c, c.print("fs-pane-zoom-{d}", .{pane_ix}));
        if (darkIconButton(
            c,
            dk,
            .@"expand-arrows",
            22,
            10.5,
            if (a.view.strip.expanded != null) "Restore panes" else "Just this pane",
            a.view.strip.expanded != null,
        )) {
            strip.queue(a, .{ .zoom = target });
        }
        ui.key(c, c.print("fs-pane-close-{d}", .{pane_ix}));
        if (darkIconButton(c, dk, .close, 22, 10.5, "Close this pane", false)) {
            strip.queue(a, .{ .close = target });
        }
        return;
    }

    const actions = ui.div(c).row().gap(4).itemsCenter();
    defer actions.end();
    {
        ui.key(c, "fullscreen-header-palette-trigger");
        const kbd = if (comptime builtin.os.tag == .macos) "\u{2318}K" else "Ctrl+K";
        var btn = tip.on(
            ui.div(c).row().h(20).px(6).center().rounded(5).bg(ui.Color.white.alpha(0.10)).hover(ui.Color.white.alpha(0.18)).control(),
            dk,
            .{ .text = "Command switcher (tabs, sessions, commands)", .look = .tab },
        );
        defer btn.end();
        ui.text(c, kbd, .{ .size = 11, .line_height = 11 * phi, .weight = .medium, .color = ui.Color.white.alpha(0.80) });
        if (btn.clicked()) palette_view.toggle(a, .preserve_tabs);
    }
    ui.key(c, "fullscreen-header-overview");
    if (darkIconButton(c, dk, .widget, 22, 11.5, "Tab overview (\u{21e7}\u{2318}\\)", false)) {
        @import("view_tab_overview.zig").toggle(a);
    }
    ui.key(c, "fullscreen-header-split");
    if (darkIconButton(c, dk, .@"split-columns", 22, 11.5, "Split pane right (\u{2318}D)", false)) {
        strip.splitChoosingFolder(a, .horizontal);
    }
    ui.key(c, "fullscreen-header-exit");
    if (darkIconButton(c, dk, .@"expand-arrows", 22, 11, "Exit full screen", false)) {
        a.setFullScreen(false);
    }
}

pub fn hostHeader(c: *ui.Context, a: *App, k: theme.Colors, focused: bool) void {
    const dk = theme.colors(true);
    ui.key(c, "fs-host-header");
    const bar = ui.div(c).row().wFull().h(chrome.fs_pane_header_h).px(6).gap(6).itemsCenter().clip();
    defer bar.end();
    {
        const lead = ui.div(c).row().grow().w(0).gap(6).itemsCenter().clip().control();
        defer lead.end();
        if (focused) ui.div(c).size(5, 5).rounded(2.5).bg(k.accent.alpha(0.92)).end();
        icons.icon(c, strip.glyph(a, .host), 12.5, ui.Color.white.alpha(if (focused) 0.78 else 0.45), 0);
        ui.text(c, strip.title(a, .host), .{
            .size = 11.5,
            .line_height = 15,
            .weight = if (focused) .semibold else .regular,
            .color = ui.Color.white.alpha(if (focused) 0.90 else 0.55),
        });
        if (!focused and lead.clicked()) strip.queue(a, .{ .focus = .host });
    }
    ui.key(c, "fs-host-close");
    if (darkIconButton(c, dk, .close, 22, 10.5, "Close panel", false)) {
        strip.queue(a, .{ .close = .host });
    }
}

pub fn filesHeader(c: *ui.Context, a: *App, k: theme.Colors, focused: bool) void {
    const dk = theme.colors(true);
    ui.key(c, "fs-files-header");
    const bar = ui.div(c).row().wFull().h(chrome.fs_pane_header_h).px(6).gap(6).itemsCenter().clip();
    defer bar.end();
    {
        const lead = ui.div(c).row().grow().w(0).gap(6).itemsCenter().clip().control();
        defer lead.end();
        if (focused) ui.div(c).size(5, 5).rounded(2.5).bg(k.accent.alpha(0.92)).end();
        icons.icon(c, .folder, 12.5, ui.Color.white.alpha(if (focused) 0.78 else 0.45), 0);
        ui.text(c, "Files", .{
            .size = 11.5,
            .line_height = 15,
            .weight = if (focused) .semibold else .regular,
            .color = ui.Color.white.alpha(if (focused) 0.90 else 0.55),
        });
        if (!focused and lead.clicked()) strip.queue(a, .{ .focus = .files });
    }
    ui.key(c, "fs-files-close");
    if (darkIconButton(c, dk, .close, 22, 10.5, "Close files panel", false)) {
        strip.queue(a, .{ .close = .files });
    }
}

pub fn settingsHeader(c: *ui.Context, a: *App) void {
    const dk = theme.colors(true);
    ui.key(c, "fs-settings-header");
    const bar = ui.div(c).row().wFull().h(chrome.fs_pane_header_h).px(6).gap(6).itemsCenter().clip();
    defer bar.end();
    icons.icon(c, .@"settings-minimalistic", 12.5, ui.Color.white.alpha(0.75), 0);
    ui.text(c, "Settings", .{ .size = 11.5, .line_height = 15, .weight = .semibold, .color = ui.Color.white.alpha(0.90) });
    ui.spacer(c);
    if (darkIconButton(c, dk, .close, 22, 10.5, "Close settings (Esc)", false)) {
        @import("view_settings.zig").close(a);
    }
}

fn darkIconButton(
    c: *ui.Context,
    dk: theme.Colors,
    icon_name: icons.Name,
    box_size: f32,
    icon_size: f32,
    help: []const u8,
    on: bool,
) bool {
    var b = tip.on(
        ui.div(c).row().size(box_size, box_size).center().rounded(5)
            .bg(if (on) ui.Color.white.alpha(0.14) else .transparent)
            .hover(ui.Color.white.alpha(0.12))
            .control(),
        dk,
        .{ .text = help, .look = .tab },
    );
    defer b.end();
    const hot = b.hovered();
    icons.icon(c, icon_name, icon_size, ui.Color.white.alpha(if (on or hot) 0.92 else 0.58), 0);
    return b.clicked();
}
