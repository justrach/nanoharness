//! Quiet 32pt workspace/session context header inside each conversation panel.
//! Surfaces project/folder, full conversation title, git branch, remote/host
//! device, and a clickable ⌘K trigger in minimal fullscreen so orientation holds
//! even when top tabs overflow or fullscreen hides window chrome.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const workspace = @import("workspace.zig");
const footer_view = @import("view_session_footer.zig");
const sidebar = @import("view_sidebar.zig");
const palette_view = @import("view_palette.zig");
const App = @import("app.zig").App;

pub const bar_height: f32 = 32;
const phi: f32 = 1.618;

pub fn shownInMode(a: *const App) bool {
    return a.settings.uiMode() == .zen or a.view.full_screen;
}

pub fn height(a: *const App) f32 {
    return if (a.selected != null and shownInMode(a)) bar_height else 0;
}

pub const HeaderLayout = struct {
    project_max: f32,
    title_max: f32,
    show_branch: bool,
    branch_max: f32,
    show_device: bool,
    device_max: f32,
    show_palette_hint: bool,
};

pub fn headerLayout(
    pane_w_in: f32,
    proj_text_w: f32,
    branch_text_w: f32,
    device_text_w: f32,
    full_screen: bool,
    focused_pane: bool,
) HeaderLayout {
    const pane_w = @max(0, pane_w_in);
    const pad: f32 = if (pane_w < 340) 20 else 32;
    const inner = @max(0, pane_w - pad);
    const show_palette_hint = full_screen and focused_pane and pane_w >= 360;
    const show_device = device_text_w > 0 and pane_w >= 480;
    const show_branch = branch_text_w > 0 and pane_w >= 340;
    const palette_w: f32 = if (show_palette_hint) 44 else 0;
    const device_max: f32 = if (show_device) @min(@min(120, pane_w * 0.18), @ceil(device_text_w)) else 0;
    const device_w: f32 = if (show_device) device_max + 26 else 0;
    const branch_max: f32 = if (show_branch) @min(@min(140, pane_w * 0.24), @ceil(branch_text_w)) else 0;
    const branch_w: f32 = if (show_branch) branch_max + 28 else 0;
    const trailing_w = palette_w + device_w + branch_w;
    const trailing_gap: f32 = if (trailing_w > 0) 8 else 0;
    const project_max: f32 = if (proj_text_w > 0 and pane_w >= 240) @min(@min(160, pane_w * 0.28), @ceil(proj_text_w)) else 0;
    const project_w: f32 = if (project_max > 0) project_max + 42 else 0;
    const title_max = @max(90, inner - trailing_w - trailing_gap - project_w);
    return .{
        .project_max = project_max,
        .title_max = title_max,
        .show_branch = show_branch,
        .branch_max = branch_max,
        .show_device = show_device,
        .device_max = device_max,
        .show_palette_hint = show_palette_hint,
    };
}

pub fn pathBasename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    if (trimmed.len == 0) return "~";
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    const back = std.mem.lastIndexOfScalar(u8, trimmed, '\\');
    const cut: ?usize = if (slash) |s| (if (back) |b| @max(s, b) else s) else back;
    return if (cut) |i| trimmed[i + 1 ..] else trimmed;
}

fn knownDevice(a: *const App, id: ?[]const u8) ?[]const u8 {
    const want = id orelse return null;
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, want)) return d.name;
    return null;
}

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors, chat_id: []const u8, pane_w: f32, focused_pane: bool) void {
    if (!shownInMode(a)) return;
    const chat = a.findChat(chat_id) orelse return;
    const space = a.findSpace(chat.space_id);

    var proj_icon: icons.Name = .folder;
    var proj_name: ?[]const u8 = null;
    var proj_tip: ?[]const u8 = null;
    var checkout: footer_view.Checkout = .local;
    if (space) |sp| {
        checkout = if (sp.git) footer_view.checkoutOf(chat, sp) else .local;
        if (sp.git and checkout != .local) proj_icon = .@"folder-with-files";
        proj_name = sp.name;
        const path = chat.cwd orelse sp.path;
        proj_tip = if (sp.git) c.print("{s} \u{00b7} {s}", .{ checkout.label(), path }) else path;
    } else if (chat.cwd) |cwd| {
        if (cwd.len > 0) {
            proj_name = pathBasename(cwd);
            proj_tip = cwd;
        }
    }

    const branch: ?[]const u8 = if (space) |sp| (if (sp.git) (chat.row_branch orelse chat.branch) else null) else null;
    const is_remote = if (chat.device_id) |did| (if (a.device_id) |local| !std.mem.eql(u8, did, local) else true) else false;
    const device_name: ?[]const u8 = if (is_remote or a.view.full_screen) knownDevice(a, chat.device_id) else null;

    const proj_style: ui.TextStyle = .{ .size = 12, .line_height = 15, .weight = theme.ui_medium_weight };
    const meta_style: ui.TextStyle = .{ .size = 11.5, .line_height = 15 };
    const proj_text_w: f32 = if (proj_name) |pn| c.text.width(pn, proj_style) else 0;
    const branch_text_w: f32 = if (branch) |br| c.text.width(br, meta_style) else 0;
    const device_text_w: f32 = if (device_name) |dn| c.text.width(dn, meta_style) else 0;

    const lay = headerLayout(pane_w, proj_text_w, branch_text_w, device_text_w, a.view.full_screen, focused_pane);
    const title = sidebar.chatLabel(chat);
    const px_val: f32 = if (pane_w < 340) 10 else 16;

    ui.key(c, "chat-context-header");
    const outer = ui.div(c).column().wFull().h(bar_height);
    defer outer.end();
    {
        const row = ui.div(c).row().wFull().h(bar_height - 1).px(px_val).gap(8).itemsCenter().clip();
        defer row.end();
        {
            const leading = ui.div(c).row().grow().w(0).gap(6).itemsCenter().clip();
            defer leading.end();
            if (proj_name) |pn| if (lay.project_max > 0) {
                var chip = ui.div(c).row().h(20).px(5).gap(4).itemsCenter().rounded(5).bg(k.ink(if (k.dark) 0.055 else 0.04)).clip();
                if (proj_tip) |pt| chip = tip.on(chip, k, .{ .text = pt, .look = .tab });
                {
                    defer chip.end();
                    icons.icon(c, proj_icon, 12, k.muted, 0);
                    kit.ellipsisText(c, pn, .{ .size = 12, .line_height = 15, .weight = theme.ui_medium_weight, .color = k.text.alpha(0.88) }, lay.project_max);
                }
                ui.text(c, "/", .{ .size = 12, .line_height = 15, .color = k.muted.alpha(0.45) });
            };
            const title_style: ui.TextStyle = .{
                .size = 12.5,
                .line_height = 16,
                .weight = .medium,
                .color = if (focused_pane) k.text else k.text.alpha(0.75),
            };
            const truncated = c.text.width(title, title_style) > lay.title_max;
            var title_box = ui.div(c).row().grow().w(0).itemsCenter().clip();
            if (truncated) title_box = tip.on(title_box, k, .{ .text = title, .look = .tab });
            defer title_box.end();
            kit.ellipsisText(c, title, title_style, lay.title_max);
        }
        if ((lay.show_branch and branch != null) or (lay.show_device and device_name != null) or lay.show_palette_hint) {
            const trailing = ui.div(c).row().gap(6).itemsCenter();
            defer trailing.end();
            if (lay.show_branch) if (branch) |br| {
                const path = chat.cwd orelse (if (space) |sp| sp.path else "");
                var bchip = ui.div(c).row().h(20).px(6).gap(4).itemsCenter().rounded(5).bg(k.ink(if (k.dark) 0.055 else 0.04));
                if (path.len > 0) bchip = tip.on(bchip, k, .{ .text = c.print("{s} \u{00b7} {s}", .{ checkout.label(), path }), .look = .tab });
                defer bchip.end();
                icons.icon(c, .@"git-branch", 11, k.muted, 0);
                kit.ellipsisText(c, br, .{ .size = 11.5, .line_height = 15, .color = k.muted }, lay.branch_max);
            };
            if (lay.show_device) if (device_name) |dn| {
                const dchip = ui.div(c).row().h(20).px(5).gap(4).itemsCenter();
                defer dchip.end();
                icons.icon(c, .monitor, 11, k.muted, 0);
                kit.ellipsisText(c, dn, .{ .size = 11.5, .line_height = 15, .color = k.muted }, lay.device_max);
            };
            if (lay.show_palette_hint) {
                ui.key(c, "fullscreen-header-palette-trigger");
                const kbd = if (comptime builtin.os.tag == .macos) "\u{2318}K" else "Ctrl+K";
                var btn = tip.on(
                    ui.div(c).row().h(20).px(6).center().rounded(5).bg(k.ink(if (k.dark) 0.08 else 0.05)).hover(k.hover).control(),
                    k,
                    .{ .text = "Command palette (tabs, files, full screen)", .look = .tab },
                );
                defer btn.end();
                ui.text(c, kbd, .{ .size = 11, .line_height = 11 * phi, .weight = .medium, .color = k.muted });
                if (btn.clicked()) palette_view.toggle(a, .preserve_tabs);
            }
        }
    }
    ui.div(c).wFull().h(1).bg(k.border.alpha(0.45)).end();
}

const testing = std.testing;

test "chat header layout degrades gracefully across pane widths while keeping readable title room" {
    const wide = headerLayout(900, 62, 96, 66, true, true);
    try testing.expect(wide.project_max == 62);
    try testing.expect(wide.show_branch and wide.show_device and wide.show_palette_hint);
    try testing.expect(wide.title_max >= 400);

    const split = headerLayout(591, 62, 96, 66, true, false);
    try testing.expect(split.show_branch and split.show_device and !split.show_palette_hint);
    try testing.expect(split.title_max >= 230);

    const long_chips = headerLayout(900, 260, 220, 200, true, true);
    try testing.expect(long_chips.project_max == 160);
    try testing.expect(long_chips.branch_max == 140);
    try testing.expect(long_chips.device_max == 120);

    const mid = headerLayout(520, 62, 96, 66, false, true);
    try testing.expect(mid.show_branch and mid.show_device and !mid.show_palette_hint);
    try testing.expect(mid.title_max >= 90);

    const compact = headerLayout(360, 62, 96, 66, false, true);
    try testing.expect(compact.show_branch and !compact.show_device and !compact.show_palette_hint);
    try testing.expect(compact.title_max >= 90);

    const tight = headerLayout(220, 62, 96, 66, false, true);
    try testing.expect(tight.project_max == 0);
    try testing.expect(!tight.show_branch and !tight.show_device and !tight.show_palette_hint);
    try testing.expect(tight.title_max >= 90);

    try testing.expectEqualStrings("nanoharness", pathBasename("/Users/dev/nanoharness/"));
    try testing.expectEqualStrings("~", pathBasename("/"));
}
