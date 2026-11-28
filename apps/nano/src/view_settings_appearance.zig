//! Settings › Appearance, as the GPUI app's (settings/appearance.rs): System,
//! Light or Dark from previews; the themes, the accent and the theme
//! library; frosted glass and the composer's background; compact mode;
//! motion; the fonts and the conversation's width. What it sets is the GPUI
//! app's own `ui-settings.json`; the appearance, accent and width apply here
//! too.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const import_view = @import("view_settings_theme_import.zig");
const App = @import("app.zig").App;
const Color = ui.Color;

pub const Mode = enum { system, light, dark };

pub fn mode(a: *const App) Mode {
    return std.meta.stringToEnum(Mode, a.settings.text("appearance") orelse "system") orelse .system;
}

/// The accent presets in the picker's order, dark and light
/// (`AccentPreset`, theme/src/lib.rs).
pub const Preset = struct { name: []const u8, label: []const u8, dark: u24, light: u24 };
pub const presets = [_]Preset{
    .{ .name = "harness", .label = "Harness", .dark = 0x8b7cf6, .light = 0x5b43e8 },
    .{ .name = "orange", .label = "Orange", .dark = 0xfb923c, .light = 0xc2410c },
    .{ .name = "amber", .label = "Amber", .dark = 0xfbbf24, .light = 0xa16207 },
    .{ .name = "green", .label = "Green", .dark = 0x4ade80, .light = 0x15803d },
    .{ .name = "cyan", .label = "Cyan", .dark = 0x22d3ee, .light = 0x0e7490 },
    .{ .name = "blue", .label = "Blue", .dark = 0x60a5fa, .light = 0x2563eb },
    .{ .name = "pink", .label = "Pink", .dark = 0xf472b6, .light = 0xbe185d },
};

pub fn presetNamed(name: []const u8) ?Preset {
    for (presets) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// The page's colours with the chosen accent in place of the theme's.
pub fn withAccent(k: theme.Colors, a: *const App) theme.Colors {
    const p = presetNamed(a.settings.accent() orelse return k) orelse return k;
    var out = k;
    out.accent = Color.hex(if (k.dark) p.dark else p.light);
    out.accent_strong = out.accent;
    out.on_accent = out.onAccent();
    out.accent_wash = out.accent.alpha(if (k.dark) 0.22 else 0.12);
    return out;
}

const default_transcript_width: f32 = 736;
const transcript_width_step: f32 = 16;

/// The conversation's column, 560 to 1200 by 16 (`transcriptWidth`).
pub fn transcriptWidth(a: *const App) f32 {
    const w = a.settings.number("transcriptWidth") orelse default_transcript_width;
    return normalizeWidth(@floatCast(w));
}

pub fn normalizeWidth(w: f32) f32 {
    const clamped = std.math.clamp(w, 560, 1200);
    return 560 + @round((clamped - 560) / transcript_width_step) * transcript_width_step;
}

const phi: f32 = 1.618;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    set.header(c, k, "Appearance", null);
    set.subtitle(c, k, "Choose how Harness looks. These settings stay on this device.", true);
    caption(c, k, "Appearance");
    options(c, a, k);
    caption(c, k, "Theme");
    themeCard(c, a, k);
    caption(c, k, "Custom themes & animated backdrops");
    customThemeCard(c, a, k);
    caption(c, k, "Window and background");
    windowCard(c, a, k);
    caption(c, k, "Workspace mode");
    workspaceModeCard(c, a, k);
    caption(c, k, "Conversation");
    {
        const cd = card(c, k);
        defer cd.end();
        {
            const r = set.row(c, k, false, false);
            defer r.end();
            set.tile(c, k, .@"eye-closed");
            words(c, k, "Compact mode", "Fold a turn's thinking, tool calls, and narration into one collapsed row — only the reply shows.", 32);
            if (switch_(c, k, a.settings.get(.transcript_compact_mode), 0)) a.settings.toggle(.transcript_compact_mode);
        }
        {
            const r = set.row(c, k, true, false).control();
            defer r.end();
            _ = kit.focusRing(c, r, k.accent, 2);
            set.tile(c, k, .@"file-image");
            words(c, k, "Design before & after", "Show interactive before and after visual comparisons inline in chat when an agent changes UI or styling.", 32);
            const switched = switch_(c, k, a.settings.get(.design_before_after_enabled), 0);
            if (switched or r.clicked()) {
                a.settings.toggle(.design_before_after_enabled);
                a.redraw();
            }
        }
    }
    caption(c, k, "Motion");
    motionCard(c, a, k);
    fonts(c, a, k);
    import_view.warning(c, a, k);
}

fn customThemeCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const cd = card(c, k);
    defer cd.end();
    {
        const r = set.row(c, k, false, false);
        defer r.end();
        set.tile(c, k, .@"magic-stick-3");
        // The studio is right below; no second copy of it in a dialog.
        words(c, k, "Backdrop studio", "Synthesize a custom palette + animated canvas from a prompt, or pick from 20 curated scenes.", 0);
    }
    ui.div(c).wFull().h(1).bg(k.border.alpha(0.55)).end();
    {
        const body = ui.div(c).column().wFull().px(18).pt(14).pb(16);
        defer body.end();
        @import("view_custom_theme_studio.zig").studioBody(c, a, k, @max(220, set.inner_w - 38), false);
    }
}

fn workspaceModeCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const motion = @import("motion_rules.zig");
    const ui_mode = a.settings.uiMode();
    const dev = ui_mode == .developer;
    const profile = a.settings.hierarchyProfile();
    const base_profile = motion.HierarchyProfile.ofMode(ui_mode);
    const customized = !std.meta.eql(profile, base_profile);

    const cd = card(c, k);
    defer cd.end();
    {
        const hdr = ui.div(c).row().wFull().px(20).py(16).gap(12).itemsCenter();
        defer hdr.end();
        set.tile(c, k, if (dev) .terminal else .@"magic-stick-3");
        {
            const info = ui.div(c).column().grow().w(0).gap(3);
            defer info.end();
            ui.text(c, "Mode preset", set.st(c, 13.5, .{ .weight = .medium, .color = k.text }));
            const desc = if (customized)
                c.print("Customized {s} layout · individual parts overridden", .{ui_mode.label()})
            else switch (ui_mode) {
                .zen => "Zen mode · calm single flat session list without hierarchy clutter",
                .developer => "Developer mode · full workspaces tree, project groups, git footer & rail",
                .design => "Design mode · Design Canvas and a flat session list",
            };
            ui.text(c, desc, .{ .size = 12, .line_height = 17, .color = k.muted, .wrap = true });
        }
        {
            const right = ui.div(c).row().gap(8).itemsCenter();
            defer right.end();
            if (customized) {
                if (compactAction(c, k, "Reset", true)) {
                    a.settings.applyUiMode(ui_mode);
                    a.redraw();
                }
            }
            const shortcuts = @import("shortcuts.zig");
            var shortcut_buf: [64]u8 = undefined;
            kit.kbdHint(c, k, c.print("{s}", .{shortcuts.chordBadge(&shortcut_buf, shortcuts.cycle_ui_mode)}));
            const seg = ui.div(c).row().p(3).gap(3).rounded(8).bg(k.ink(if (k.dark) 0.08 else 0.055));
            defer seg.end();
            const is_dev = ui_mode == .developer;
            const is_des = ui_mode == .design;
            inline for (.{
                .{ motion.UiMode.zen, "settings-mode-zen", icons.Name.@"magic-stick-3", "Zen", !is_dev and !is_des },
                .{ motion.UiMode.developer, "settings-mode-developer", icons.Name.terminal, "Developer", is_dev },
                .{ motion.UiMode.design, "settings-mode-design", icons.Name.@"palette-search", "Design", is_des },
            }) |item| {
                ui.key(c, item[1]);
                var pill = ui.div(c).row().h(28).px(10).gap(5).center().rounded(6).control();
                pill = if (item[4])
                    pill.bg(if (k.frosted) k.card else k.background).border(k.border_strong).borderW(1)
                else
                    pill.hover(k.selected);
                defer pill.end();
                icons.icon(c, item[2], 12.5, if (item[4]) k.text else k.muted, 0);
                ui.text(c, item[3], .{ .size = 12, .weight = if (item[4]) .semibold else .regular, .color = if (item[4]) k.text else k.muted });
                if (pill.clicked()) {
                    const was_design = a.settings.uiMode() == .design;
                    a.settings.applyUiMode(item[0]);
                    if (item[0] == .design) {
                        @import("app_panels.zig").openDesignCanvas(a);
                    } else if (was_design) {
                        @import("app_panels.zig").closeDesignCanvas(a);
                    }
                    a.redraw();
                }
            }
        }
    }

    const items = [_]struct { part: motion.MovingPart, icon: icons.Name, title: []const u8, desc: []const u8 }{
        .{ .part = .open_workspaces_tree, .icon = .@"split-columns", .title = "Open workspaces tree", .desc = "Show open workspace sessions and nested split panes above the session list." },
        .{ .part = .git_checkout_chrome, .icon = .@"git-branch", .title = "Git & branch controls", .desc = "Show local/worktree checkout pickers, branch selectors, and pull request footer chips." },
        .{ .part = .prompt_rail, .icon = .list, .title = "Prompt rail", .desc = "Show the right-margin jump rail for navigating long conversations by prompt." },
        .{ .part = .action_toolbar, .icon = .@"action-play", .title = "Actions toolbar", .desc = "Show project build, test, and run buttons in the session header." },
        .{ .part = .grouped_sections, .icon = .@"folder-with-files", .title = "Grouped sidebar sections", .desc = "Group sessions under workspace folders instead of a single flat Zen list." },
        .{ .part = .row_tech_badges, .icon = .@"file-code", .title = "Row branch & agent badges", .desc = "Show git branch names and agent badges inside sidebar session rows." },
        .{ .part = .multi_axis_filters, .icon = .tuning, .title = "Project & activity filters", .desc = "Show workspace, status, and sort filter menus above the session list." },
    };
    for (items) |it| {
        const r = set.row(c, k, true, false);
        defer r.end();
        set.tile(c, k, it.icon);
        words(c, k, it.title, it.desc, 32);
        if (switch_(c, k, profile.partEnabled(it.part), 0)) a.settings.toggleMovingPart(it.part);
    }
}

fn words(c: *ui.Context, k: theme.Colors, title: []const u8, meta: []const u8, trailing: f32) void {
    set.words(c, k, title, meta, trailing);
}

/// A group's caption, 32 below what's above, 12 above its content.
/// This page's switches: the bare 32 by 18 switch, `ml` points after the
/// words, pinned to the row's end.
fn switch_(c: *ui.Context, k: theme.Colors, on: bool, ml: f32) bool {
    const box = ui.div(c).row().pl(ml);
    defer box.end();
    return kit.toggleSwitch(c, k, on);
}

fn caption(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    set.space(c, 32);
    set.fieldLabel(c, k, label);
    set.space(c, 12);
}

/// `section_card` with its top margin taken off.
fn card(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell);
}

// System, Light, Dark.

fn options(c: *ui.Context, a: *App, k: theme.Colors) void {
    const r = ui.div(c).row().wFull().gap(16);
    defer r.end();
    const current = mode(a);
    const w = (set.inner_w - 32) / 3;
    inline for (.{ .{ Mode.system, "System" }, .{ Mode.light, "Light" }, .{ Mode.dark, "Dark" } }) |o| {
        const selected = current == o[0];
        const col = ui.div(c).column().w(w).gap(8).itemsCenter();
        defer col.end();
        {
            const frame = ui.div(c).row().wFull().h(148).p(1).rounded(6).border(if (selected) k.accent else k.border).borderW(1).clip();
            defer frame.end();
            const inner_w = w - 2;
            switch (o[0]) {
                .light => miniature(c, theme.colors(false), inner_w, .all),
                .dark => miniature(c, theme.colors(true), inner_w, .all),
                .system => {
                    miniature(c, theme.colors(false), inner_w / 2, .left);
                    miniature(c, theme.colors(true), inner_w / 2, .right);
                },
            }
            if (frame.clicked()) setMode(a, o[0]);
        }
        const cap = ui.div(c).row().gap(6).itemsCenter();
        defer cap.end();
        // GPUI's caption icon is given no colour and draws nothing; its
        // room stays.
        _ = c.leaf(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }, .none, null);
        ui.text(c, o[1], .{ .size = 13, .line_height = 13 * phi, .weight = if (selected) .medium else .regular, .color = if (selected) k.accent else k.muted });
        if (cap.clicked()) setMode(a, o[0]);
    }
}

pub const default_light_id = "codegraff-light";
pub const default_dark_id = "codegraff-dark";

pub fn isSystemDefault(a: *const App) bool {
    const scene = a.settings.backdropScene();
    const clean_scene = scene.len == 0 or std.mem.eql(u8, scene, "auto") or std.mem.eql(u8, scene, "off") or std.mem.eql(u8, scene, "none");
    return mode(a) == .system and
        std.mem.eql(u8, a.settings.themeId(false), default_light_id) and
        std.mem.eql(u8, a.settings.themeId(true), default_dark_id) and
        clean_scene;
}

pub fn applySystemDefault(a: *App) void {
    setMode(a, .system);
    a.settings.setTheme(false, default_light_id);
    a.settings.setTheme(true, default_dark_id);
    a.settings.setBackdropScene("auto");
    a.redraw();
}

pub fn toggleLightDark(a: *App) void {
    const currently_dark = a.dark orelse nanoui.isDark();
    setMode(a, if (currently_dark) .light else .dark);
    a.redraw();
}

pub fn setMode(a: *App, m: Mode) void {
    a.settings.setText("appearance", @tagName(m));
    a.dark = switch (m) {
        .system => null,
        .light => false,
        .dark => true,
    };
}

pub const Corners = enum { all, left, right };

/// A window in little: a sidebar of four bars and a pane of four lines.
pub fn miniature(c: *ui.Context, t: theme.Colors, w: f32, corners: Corners) void {
    _ = corners;
    const line = t.text.alpha(0.22);
    const strong = t.text.alpha(0.34);
    const root = ui.div(c).row().w(w).hFull().bg(t.shell);
    defer root.end();
    {
        const side = ui.div(c).column().w(44).hFull().gap(7).px(8).pt(14);
        defer side.end();
        for ([_]f32{ 0.7, 1, 0.85, 1 }, 0..) |f, i| bar(c, 28 * f, if (i == 0) strong else line);
    }
    const pane = ui.div(c).column().grow().w(0).hFull().py(8).pr(8);
    defer pane.end();
    const box = ui.div(c).column().wFull().grow().h(0).rounded(6).border(t.border).borderW(1).bg(t.background).p(11).gap(7);
    defer box.end();
    const inner = w - 44 - 8 - 22 - 2;
    for ([_]f32{ 0.62, 0.88, 0.76, 0.52 }, 0..) |f, i| bar(c, inner * f, if (i == 0) strong else line);
}

fn bar(c: *ui.Context, w: f32, color: Color) void {
    _ = c.leaf(.{ .width = .{ .px = w }, .height = .{ .px = 5 }, .radius = 3, .background = color }, .none, null);
}

// The theme card.

fn themeCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const cd = card(c, k);
    defer cd.end();
    {
        const r = set.row(c, k, true, false);
        defer r.end();
        set.tile(c, k, .monitor);
        words(c, k, "Default system theme", "Follow macOS Light and Dark automatically with Harness's built-in desktop palette.", 124);
        ui.spacer(c);
        ui.key(c, "settings-default-system-theme");
        if (isSystemDefault(a)) {
            const pill = ui.div(c).row().h(28).px(10).gap(5).itemsCenter().rounded(7).border(k.accent.alpha(0.45)).borderW(1).bg(k.accent_wash);
            defer pill.end();
            icons.icon(c, .check, 12, k.accent, 0);
            ui.text(c, "Active", .{ .size = 11.5, .line_height = 11.5 * phi, .weight = .medium, .color = k.accent });
        } else {
            if (compactAction(c, k, "Use default", true)) applySystemDefault(a);
        }
    }
    inline for (.{ .{ .sun, "Light theme", false }, .{ .moon, "Dark theme", true } }) |t| {
        const r = set.row(c, k, false, false);
        defer r.end();
        set.tile(c, k, t[0]);
        words(c, k, t[1], "Used whenever this appearance is active.", 218);
        const id = a.settings.themeId(t[2]);
        const v = themes.find(id);
        const open = a.view.theme_menu != null and a.view.theme_menu.? == t[2];
        const rect = picker(c, k, if (v) |x| x.colors else theme.builtin(t[2]), if (v) |x| x.name else id, open);
        if (rect.clicked) {
            a.view.theme_menu = if (open) null else t[2];
            // A theme the GPUI app added since shows in the menu.
            if (!open) a.view.theme_reload = true;
            a.view.theme_anchor = rect.at;
            c.changed = true;
        }
        if (open) a.view.theme_anchor = rect.at;
    }
    {
        const r = set.row(c, k, false, false);
        defer r.end();
        set.tile(c, k, .tuning);
        const chosen = if (a.settings.accent()) |n| presetNamed(n) else null;
        const meta = if (chosen) |p| c.print("{s} · Controls, glyphs, selections, code, and activity.", .{p.label}) else "Theme default · Uses the palette's intended color.";
        words(c, k, "Accent color", meta, 10 + 8 * 30 + 7 * 6);
        const sw = ui.div(c).row().pl(10).gap(6);
        defer sw.end();
        if (swatch(c, k, null, chosen == null)) a.settings.setAccent(null);
        for (presets) |p| if (swatch(c, k, p, chosen != null and std.mem.eql(u8, chosen.?.name, p.name))) a.settings.setAccent(p.name);
    }
    {
        const r = set.row(c, k, false, false);
        defer r.end();
        set.tile(c, k, .@"folder-with-files");
        words(c, k, "Theme library", "Import or link custom themes.", 92);
        const b = ui.div(c).row().px(12).py(6).rounded(8).bg(k.solid);
        defer b.end();
        ui.text(c, "Add theme", .{ .size = 13, .line_height = 13 * phi, .weight = .medium, .color = k.on_solid });
        if (b.clicked()) import_view.open(a);
    }
    import_view.libraryRows(c, a, k);
}

/// The theme picker's trigger: the variant's swatch, its name, and the
/// up-down arrow (`render_theme_selector`).
fn picker(c: *ui.Context, k: theme.Colors, t: theme.Colors, name: []const u8, open: bool) struct { clicked: bool, at: ?ui.Rect } {
    var p = ui.div(c).row().w(218).h(34).px(11).gap(8).itemsCenter().rounded(8).border(if (open) k.border_strong else k.border).borderW(1).bg(if (open and k.is_harp) k.active else k.raised.alpha(if (open) 0.75 else 0.42));
    if (!open) p = p.hover(k.raised);
    defer p.end();
    preview(c, k, t);
    const n = ui.div(c).row().grow().w(0).clip();
    {
        defer n.end();
        ui.text(c, name, .{ .size = 12.5, .line_height = 12.5 * phi, .weight = .medium, .color = k.text });
    }
    icons.icon(c, .@"sort-vertical", 14, k.muted.alpha(if (open) 0.9 else 0.45), 0);
    return .{ .clicked = p.clicked(), .at = c.rects.get(c.node(p.index).id) };
}

/// `palette_preview`: the variant's shell, background and accent in a
/// bordered 30 by 18 chip.
pub fn preview(c: *ui.Context, k: theme.Colors, t: theme.Colors) void {
    _ = k;
    const sw = ui.div(c).row().size(30, 18).p(1).rounded(5).border(t.border).borderW(1).clip();
    defer sw.end();
    for ([_]Color{ t.shell, t.background, t.accent }) |col| _ = c.leaf(.{ .width = .{ .px = 28.0 / 3.0 }, .height = .fill, .background = col }, .none, null);
}

/// The open theme menu under its trigger: "Light themes" or "Dark themes",
/// then every variant of that appearance; picking one applies it.
pub fn themeMenu(c: *ui.Context, a: *App, k: theme.Colors) void {
    const dark = a.view.theme_menu orelse return;
    const at = a.view.theme_anchor orelse return;
    if (kit.pressedOutside(c, at)) {
        a.view.theme_menu = null;
        return;
    }
    const w: f32 = 260;
    // Know the menu's height before showing it: using last frame's height
    // moves its rows between mouse-down and mouse-up on the first pick.
    var count: usize = 0;
    for (themes.all()) |v| if (v.dark == dark) {
        count += 1;
    };
    const custom_themes = @import("custom_themes.zig");
    for (custom_themes.userPresets()) |p| if (p.variant.dark == dark) {
        count += 1;
    };
    for (custom_themes.curated()) |p| if (p.variant.dark == dark) {
        count += 1;
    };
    const heading_h = c.text.lineHeight(set.st(c, 10, .{ .weight = .medium })) + 10;
    const row_h = @max(18, c.text.lineHeight(set.st(c, 13, .{}))) + 10;
    const rows_h = @as(f32, @floatFromInt(count)) * (row_h + 1) - 1;
    const rows_max = @min(360, @max(0, c.size.h - 16 - 10 - heading_h - 2));
    const h = 10 + heading_h + 2 + @min(rows_h, rows_max);
    const rules = @import("rules.zig");
    // Hung from the trigger's padding box, as GPUI's anchored menus are.
    const x = rules.snapToWindow(at.x + 1, w, c.size.w, 8);
    const y = rules.snapToWindow(at.y + at.h + 4.5, h, c.size.h, 8);
    ui.key(c, "appearance-theme-menu");
    const m = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(4 + 1).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer m.end();
    {
        const hd = ui.div(c).row().wFull().px(8).pt(6).pb(4);
        defer hd.end();
        ui.text(c, if (dark) "D\u{200A}A\u{200A}R\u{200A}K\u{200A} \u{200A}T\u{200A}H\u{200A}E\u{200A}M\u{200A}E\u{200A}S" else "L\u{200A}I\u{200A}G\u{200A}H\u{200A}T\u{200A} \u{200A}T\u{200A}H\u{200A}E\u{200A}M\u{200A}E\u{200A}S", set.st(c, 10, .{ .weight = .medium, .color = k.muted }));
    }
    ui.scroll(c, .{ .width = .fill, .max_height = rows_max, .direction = .column, .gap = 1, .scrollbar = .{ .overlay = k.faint.alpha(0.5) } });
    defer ui.end(c);
    const picked = a.settings.themeId(dark);
    for (themes.all()) |*v| if (v.dark == dark) {
        themeMenuRow(c, a, k, picked, dark, v, false);
    };
    for (custom_themes.userPresets()) |*p| if (p.variant.dark == dark) {
        themeMenuRow(c, a, k, picked, dark, &p.variant, true);
    };
    for (custom_themes.curated()) |*p| if (p.variant.dark == dark) {
        themeMenuRow(c, a, k, picked, dark, &p.variant, true);
    };
}

fn themeMenuRow(c: *ui.Context, a: *App, k: theme.Colors, picked: []const u8, dark: bool, v: *const themes.Variant, has_backdrop: bool) void {
    ui.key(c, c.print("theme-{s}", .{v.id}));
    const active = std.mem.eql(u8, v.id, picked);
    const is_default = std.mem.eql(u8, v.id, default_light_id) or std.mem.eql(u8, v.id, default_dark_id);
    const base = ui.div(c).row().wFull().px(8).py(5).gap(10).itemsCenter().rounded(7);
    const lh = kit.listenerHover(&a.view.hovers, if (active) base.bg(if (k.is_harp) k.active else k.selected) else base, k.hover);
    const row = lh.div;
    defer row.end();
    const hot = lh.hovered;
    preview(c, k, v.colors);
    {
        const n = ui.div(c).row().grow().w(0).clip();
        defer n.end();
        ui.text(c, v.name, set.st(c, 13, .{ .color = if (active or hot) k.text else k.text.alpha(0.9) }));
    }
    if (is_default) ui.text(c, "Default", set.st(c, 11, .{ .color = k.muted.alpha(0.75) }));
    if (active) icons.icon(c, .check, 14, k.accent, 0);
    if (row.clicked()) {
        a.settings.setTheme(dark, v.id);
        if (has_backdrop) {
            a.settings.setBackdropScene("auto");
        } else {
            const cur_scene = a.settings.backdropScene();
            if (!std.mem.eql(u8, cur_scene, "off") and !std.mem.eql(u8, cur_scene, "none")) {
                a.settings.setBackdropScene("auto");
            }
        }
        a.view.theme_menu = null;
        c.changed = true;
        a.redraw();
    }
}

/// One accent: a 30-point chip over a 2-point underline in its colour when
/// chosen. The theme's own shows the glyph's three bars on its wash.
fn swatch(c: *ui.Context, k: theme.Colors, p: ?Preset, selected: bool) bool {
    const col = ui.div(c).column().w(30).gap(2);
    defer col.end();
    const accent = if (p) |pre| Color.hex(if (k.dark) pre.dark else pre.light) else k.accent;
    const chip = ui.div(c).row().size(30, 30).p(3).rounded(8).border(if (selected) k.border_strong else k.border).borderW(1).bg(k.raised.alpha(0.42));
    {
        defer chip.end();
        if (p != null) {
            _ = c.leaf(.{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .radius = 6, .background = accent }, .none, null);
        } else {
            const wash = ui.div(c).row().size(24, 24).rounded(6).bg(k.accent_wash).gap(2).center();
            defer wash.end();
            for ([_]f32{ 13, 16, 11 }, [_]Color{ k.glyph[0], k.glyph[1], k.glyph[2] }) |h, g| _ = c.leaf(.{ .width = .{ .px = 4 }, .height = .{ .px = h }, .radius = 2, .background = g }, .none, null);
        }
    }
    _ = c.leaf(.{ .width = .{ .px = 30 }, .height = .{ .px = 2 }, .background = if (selected) accent else Color{ .a = 0 } }, .none, null);
    return chip.clicked();
}

// Window and background.

fn windowCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const cd = card(c, k);
    defer cd.end();
    {
        const r = set.row(c, k, true, false);
        defer r.end();
        const frosted = @import("surface_palette.zig").requested(a.settings.text("surface"), k.recommended_frosted);
        set.tile(c, k, .widget);
        words(c, k, "Frosted glass", if (frosted) "Blurs and tints what sits behind the window, where supported." else "Solid surfaces in every theme.", 42);
        if (switch_(c, k, frosted, 10)) {
            a.settings.setText("surface", if (frosted) "opaque" else "frosted");
            c.changed = true;
        }
    }
    const r = set.row(c, k, false, false);
    defer r.end();
    set.tile(c, k, .@"file-image");
    words(c, k, "New thread composer background", "Custom images for empty new threads aren't available in NanoHarness.", 0);
}

/// `compact_action`: a small bordered button.
fn compactAction(c: *ui.Context, k: theme.Colors, label: []const u8, enabled: bool) bool {
    // Padding plus the border, which GPUI insets by too.
    const b = ui.div(c).row().h(28).px(10).itemsCenter().rounded(7).border(k.border).borderW(1).bg(k.raised.alpha(0.34)).control();
    defer b.end();
    if (!enabled) _ = b.opacity(0.55);
    ui.text(c, label, .{ .size = 11.5, .line_height = 11.5 * phi, .color = if (enabled and b.hovered()) k.text else k.muted });
    return @import("control_behavior.zig").activate(c, b, k, label, enabled, false);
}

// Motion.

/// First thing each frame: "Reduce motion" On or Off in place of what the
/// system asks for; System leaves the system's choice. The platform applies
/// the override before the next frame too (`reduce_motion_override`).
pub fn applyReduceMotion(c: *ui.Context, a: *App) void {
    const forced = a.settings.reduceMotion().override();
    c.reduce_motion_override = forced;
    if (forced) |on| {
        c.reduce_motion = on;
        c.reduced_motion = on;
        a.view.motion_forced = true;
    } else if (a.view.motion_forced) {
        c.reduce_motion = c.system_reduce_motion;
        c.reduced_motion = c.system_reduce_motion;
        a.view.motion_forced = false;
    }
}

/// The line under "Reduce motion": what the choice does, and with System,
/// what the system asks for right now.
pub fn reduceMotionCaption(pref: @import("settings.zig").ReduceMotion, system_reduces: bool) []const u8 {
    return switch (pref) {
        .on => "Animations skip straight to their final state.",
        .off => "Animations play even if the system asks for less motion.",
        .system => if (system_reduces)
            "Following the system, which currently asks for less motion."
        else
            "Following the system, which currently allows motion.",
    };
}

fn motionCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const cd = card(c, k);
    defer cd.end();
    {
        const r = set.row(c, k, true, false);
        defer r.end();
        const value = @tagName(a.settings.reduceMotion());
        set.tile(c, k, .@"magic-stick-3");
        const copy = reduceMotionCaption(a.settings.reduceMotion(), c.system_reduce_motion);
        // The choices' width: 10 before them, each 10 in a side (its
        // border with them), its words (laid out to the whole point), 6
        // between.
        var seg_w: f32 = 10 + 2 * 6;
        inline for (.{ .{ "System", "system" }, .{ "On", "on" }, .{ "Off", "off" } }) |o| {
            const selected = std.mem.eql(u8, value, o[1]);
            seg_w += 2 * 10 + @ceil(c.text.width(o[0], .{ .size = 11, .weight = if (selected) .medium else .regular }));
        }
        words(c, k, "Reduce motion", copy, seg_w);
        const seg = ui.div(c).row().pl(10).gap(6);
        defer seg.end();
        inline for (.{ .{ "System", "system" }, .{ "On", "on" }, .{ "Off", "off" } }) |o| {
            const selected = std.mem.eql(u8, value, o[1]);
            var chip = ui.div(c).row().h(28).px(10).itemsCenter().rounded(7).borderW(1);
            chip = if (selected) chip.border(k.accent).bg(if (k.is_harp) k.active else k.accent_wash) else chip.border(k.border).bg(k.raised.alpha(0.28)).hover(k.raised);
            defer chip.end();
            ui.text(c, o[0], .{ .size = 11, .line_height = 11 * phi, .weight = if (selected) .medium else .regular, .color = if (selected) k.accent else k.muted });
            if (!selected and chip.clicked()) {
                a.settings.setText("reduceMotion", o[1]);
                a.redraw();
            }
        }
    }
    // No "Pause animations in background" switch: nothing read it, and the
    // ambient backdrop and sandbox sprite already stop ticking, and loaders
    // slow to a third, whenever the window isn't focused (view_backdrop.zig,
    // view_sandbox_strip.zig, view_kit.zig `background_tick_divisor`).
}

// Fonts and the conversation's width.

fn fonts(c: *ui.Context, a: *App, k: theme.Colors) void {
    set.space(c, 36);
    const box = ui.div(c).column().wFull().gap(18);
    defer box.end();
    const rows = [_]struct { title: []const u8, detail: []const u8, can_resize: bool = false }{
        .{ .title = "Interface font", .detail = "Menus, sidebars, and conversation text. Font family can't be changed in NanoHarness.", .can_resize = true },
        .{ .title = "Terminal font", .detail = "Terminal panes and shell output. Font family and size can't be changed in NanoHarness." },
        .{ .title = "Code & diff font", .detail = "Code blocks, diffs, and workspace file editors. Font family and size can't be changed in NanoHarness." },
    };
    for (rows) |f| {
        const gap = 24;
        const control_w: f32 = if (f.can_resize) gap + 140 else 0;
        const r = ui.div(c).row().wFull().gap(gap).itemsCenter();
        defer r.end();
        {
            const l = ui.div(c).column().w(@min(set.inner_w - control_w, 520)).gap(4);
            defer l.end();
            set.fieldLabel(c, k, f.title);
            ui.text(c, f.detail, .{ .size = 12, .line_height = 18, .wrap = true, .color = k.muted });
        }
        if (f.can_resize) {
            const settings = @import("settings.zig");
            const size = a.settings.uiFontSize();
            if (compactAction(c, k, c.print("Cycle size · {d:.0} px", .{size}), true)) {
                const sizes = settings.ui_font_sizes;
                a.settings.setUiFontSize(if (size == sizes[sizes.len - 1]) sizes[0] else settings.stepUiFontSize(size, 1));
            }
        }
    }
    widthRow(c, a, k);
}

/// "Conversation width": a slider from 560 to 1,200 points by 16 with a
/// persistent readout and a reset to the default conversation width.
fn widthRow(c: *ui.Context, a: *App, k: theme.Colors) void {
    const r = ui.div(c).row().wFull().gap(20).itemsCenter();
    defer r.end();
    {
        const l = ui.div(c).column().w(set.inner_w - 20 - 240).gap(4);
        defer l.end();
        set.fieldLabel(c, k, "Conversation width");
        ui.text(c, "Maximum width of messages and the composer in conversations. Adapts to smaller windows.", .{ .size = 12, .line_height = 18, .wrap = true, .color = k.muted });
    }
    const col = ui.div(c).column().w(240).gap(4);
    defer col.end();
    const width = transcriptWidth(a);
    const value = c.print("{d:.0} px", .{width});
    {
        const readout = ui.div(c).row().wFull().itemsCenter();
        defer readout.end();
        ui.text(c, value, set.st(c, 12, .{ .color = k.text }));
        ui.spacer(c);
        if (compactAction(c, k, "Reset to default", width != default_transcript_width)) {
            a.settings.setNumber("transcriptWidth", default_transcript_width);
        }
    }
    {
        const slider = ui.div(c).row().w(240).h(28).control();
        const it = slider.interaction();
        defer slider.end();
        c.adjustable(slider.index, .{ .label = "Conversation width", .value = value });
        const frac = (width - 560) / 640;
        const track = ui.div(c).absolute().offset(7, 12).w(226).h(4).roundedFull().bg(k.border);
        {
            defer track.end();
            _ = c.leaf(.{ .width = .{ .px = 226 * frac }, .height = .fill, .radius = 2, .background = k.accent }, .none, null);
        }
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 7 + 226 * frac - 7, .y = 12 - 5 }, .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = k.accent }, .none, null);
        var next = width;
        if (it.pressed) if (it.rect) |rect| {
            const f = std.math.clamp((c.input.mouse.x - rect.x - 7) / 226, 0, 1);
            next = normalizeWidth(560 + f * 640);
        };
        if (it.a11y_step != 0) next = normalizeWidth(width + @as(f32, @floatFromInt(it.a11y_step)) * transcript_width_step);
        if (next != width) {
            a.settings.setNumber("transcriptWidth", next);
            c.changed = true;
        }
    }
}

const testing = std.testing;

test "appearance values as the GPUI app keeps them" {
    try testing.expectEqual(@as(f32, 736), normalizeWidth(736));
    try testing.expectEqual(@as(f32, 560), normalizeWidth(100));
    try testing.expectEqual(@as(f32, 1200), normalizeWidth(5000));
    try testing.expectEqual(@as(f32, 752), normalizeWidth(750));
    // Halfway rounds away from 560, as Rust's `round` does.
    try testing.expectEqual(@as(f32, 1008), normalizeWidth(1000));
    try testing.expectEqual(@as(u24, 0xfb923c), presetNamed("orange").?.dark);
    try testing.expect(presetNamed("teal") == null);
}

// Render the actual Appearance rows without starting an engine or loading a profile.
const AppearanceFixture = struct {
    a: App,
    t: ui.Tester,

    fn init(f: *AppearanceFixture) !void {
        f.a = .init(testing.allocator, testing.io, 1);
        errdefer f.a.deinit();
        f.a.offscreen = true;
        try f.t.init(testing.allocator, .init(&f.a, view), .{ .width = 760, .height = 1100 });
        f.t.settle(0.2);
    }

    fn deinit(f: *AppearanceFixture) void {
        f.t.deinit();
        f.a.deinit();
    }

    fn view(a: *App, c: *ui.Context) void {
        const prev_w = set.inner_w;
        defer set.inner_w = prev_w;
        set.inner_w = 720;
        const root = ui.div(c).column().w(set.inner_w).gap(12);
        defer root.end();
        const k = theme.colors(false);
        windowCard(c, a, k);
        workspaceModeCard(c, a, k);
        fonts(c, a, k);
    }
};

test "appearance explains unavailable image and font settings inline and still cycles interface size" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    f.a.settings.apply(
        \\{"uiFontFamily":"installed:Fixture UI","terminalFontFamily":"installed:Fixture Terminal","codeFontFamily":"installed:Fixture Code","terminalFontSize":13,"codeFontSize":12.5}
    );
    f.t.settle(0.2);
    try testing.expect(f.t.hasText("Custom images for empty new threads aren't available in NanoHarness."));
    try testing.expect(f.t.hasText("Menus, sidebars, and conversation text. Font family can't be changed in NanoHarness."));
    try testing.expect(f.t.hasText("Terminal panes and shell output. Font family and size can't be changed in NanoHarness."));
    try testing.expect(f.t.hasText("Code blocks, diffs, and workspace file editors. Font family and size can't be changed in NanoHarness."));
    for ([_][]const u8{ "Choose image", "Fixture UI", "Fixture Terminal", "Fixture Code", "13 px", "12.5 px" }) |label| {
        try testing.expect(!f.t.hasText(label));
    }
    try f.t.clickText("Cycle size · 16 px");
    f.t.settle(0.2);
    try testing.expectEqual(@as(f32, 18), f.a.settings.uiFontSize());
    try testing.expect(f.t.hasText("Cycle size · 18 px"));
}

test "appearance conversation width reads back click and drag and resets to 736 px" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expect(f.t.hasText("736 px"));
    const slider_rect = for (f.t.ctx.a11y_items.items) |item| {
        if (item.role == .slider and std.mem.eql(u8, item.label, "Conversation width")) {
            break f.t.ctx.rects.get(item.id) orelse return error.MissingSliderRect;
        }
    } else return error.MissingConversationWidthSlider;
    const y = slider_rect.y + slider_rect.h / 2;
    const clicked_x = slider_rect.x + 7 + 0.775 * (slider_rect.w - 14);
    f.t.click(clicked_x, y);
    f.t.moveTo(750, 0);
    try testing.expectEqual(@as(?f64, 1056), f.a.settings.number("transcriptWidth"));
    try testing.expect(f.t.hasText("1056 px"));
    f.t.drag(clicked_x, y, slider_rect.x + slider_rect.w / 2, y);
    try testing.expectEqual(@as(?f64, 880), f.a.settings.number("transcriptWidth"));
    try testing.expect(f.t.hasText("880 px"));
    try f.t.clickText("Reset to default");
    f.t.settle(0.2);
    try testing.expectEqual(@as(?f64, 736), f.a.settings.number("transcriptWidth"));
    try testing.expect(f.t.hasText("736 px"));
}

test "appearance names the Design preset in default and customized layouts" {
    var f: AppearanceFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.t.clickText("Design");
    f.t.settle(0.2);
    try testing.expectEqual(@import("motion_rules.zig").UiMode.design, f.a.settings.uiMode());
    try testing.expect(f.t.hasText("Design mode · Design Canvas and a flat session list"));
    try testing.expect(!f.t.containsText("Zen mode ·"));
    f.a.settings.toggleMovingPart(.prompt_rail);
    f.t.settle(0.2);
    try testing.expect(f.t.hasText("Customized Design layout · individual parts overridden"));
    try testing.expect(!f.t.containsText("Customized Zen layout"));
}
