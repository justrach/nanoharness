//! Paper.design-inspired responsive design canvas & DESIGN.md token inspector
//! inside Nano's right host surface (`.design_canvas` tab kind).
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const ux = @import("ux_rules.zig").DesignCanvas;
const design = @import("design_canvas.zig");
const App = @import("app.zig").App;

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.design;
    const audit = design.auditTheme(k);

    const root = ui.div(c).column().wFull().grow().h(0).bg(k.panel);
    defer root.end();

    toolbar(c, a, k, s, audit);
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);

    const body = ui.div(c).row().wFull().grow().h(0).clip();
    defer body.end();

    stage(c, a, k, s, audit);
    if (s.show_inspector) {
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
        inspectorDrawer(c, a, k, s, audit);
    }
}

fn toolbar(c: *ui.Context, a: *App, k: theme.Colors, s: *design.State, audit: design.Audit) void {
    const bar = ui.div(c).row().wFull().h(40).px(8).gap(4).itemsCenter().bg(k.shell);
    defer bar.end();

    icons.icon(c, .@"palette-search", 14, k.accent, 0);

    // Responsive Artboard Presets (Paper.design frames)
    const track = ui.div(c).row().p(2).gap(2).rounded(7).bg(k.ink(if (k.dark) 0.08 else 0.05));
    defer track.end();
    inline for (.{
        .{ ux.ArtboardPreset.mobile, icons.Name.smartphone, "390", "Mobile 390x844" },
        .{ ux.ArtboardPreset.tablet, icons.Name.laptop, "768", "Tablet 768x1024" },
        .{ ux.ArtboardPreset.desktop, icons.Name.monitor, "1440", "Desktop 1440x900" },
    }) |p| {
        const active = s.preset == p[0];
        ui.key(c, p[2]);
        var seg = ui.div(c).row().h(22).px(5).gap(3).itemsCenter().rounded(5).control();
        seg = if (active) seg.bg(k.background).border(k.border_strong).borderW(1) else seg.hover(k.hover);
        seg = tip.on(seg, k, .{ .text = p[3], .delay = tip.quick });
        defer seg.end();
        icons.icon(c, p[1], 11, if (active) k.text else k.muted, 0);
        ui.text(c, p[2], .{ .size = 10.5, .weight = if (active) .medium else .regular, .color = if (active) k.text else k.muted });
        if (seg.clicked()) {
            s.setPreset(p[0]);
            a.redraw();
        }
    }

    // Zoom controls (click percentage pill to reset to 100%)
    if (kit.iconButton(c, k, .minus, .{ .size = 22, .icon = 11, .tip = .{ .text = "Zoom out" } })) {
        s.stepZoom(false);
        a.redraw();
    }
    if (pillBtn(c, k, c.print("{d}%", .{s.zoom_pct}), false)) {
        s.resetZoom();
        a.redraw();
    }
    if (kit.iconButton(c, k, .plus, .{ .size = 22, .icon = 11, .tip = .{ .text = "Zoom in" } })) {
        s.stepZoom(true);
        a.redraw();
    }

    ui.spacer(c);

    // Pin annotate toggle + Grid toggle + Audit inspector toggle
    const pin_label = if (s.pin_count > 0) c.print("Pin ({d})", .{s.pin_count}) else "Pin";
    if (pillBtn(c, k, pin_label, s.pin_mode)) {
        s.pin_mode = !s.pin_mode;
        a.redraw();
    }
    if (pillBtn(c, k, "Grid", s.show_grid)) {
        s.show_grid = !s.show_grid;
        a.redraw();
    }
    if (pillBtn(c, k, c.print("Audit {d}/4", .{audit.score}), s.show_inspector)) {
        s.show_inspector = !s.show_inspector;
        a.redraw();
    }
    if (pillBtn(c, k, "Exit", false)) {
        a.settings.applyUiMode(.zen);
        @import("app_panels.zig").closeDesignCanvas(a);
        a.redraw();
    }
}

fn pillBtn(c: *ui.Context, k: theme.Colors, label: []const u8, on: bool) bool {
    ui.key(c, label);
    var b = ui.div(c).row().h(24).px(7).itemsCenter().rounded(6).control();
    b = if (on) b.bg(k.accent.alpha(0.14)).border(k.accent.alpha(0.35)).borderW(1) else b.bg(k.ink(0.05)).hover(k.hover);
    defer b.end();
    ui.text(c, label, .{ .size = 10.5, .weight = if (on) .medium else .regular, .color = if (on) k.accent else k.text });
    return b.clicked();
}

fn stage(c: *ui.Context, a: *App, k: theme.Colors, s: *design.State, audit: design.Audit) void {
    ui.key(c, "design-canvas-stage");
    const area = ui.div(c).column().grow().w(0).hFull().bg(k.ink(if (k.dark) 0.03 else 0.025)).clip().control().wheel();
    defer area.end();

    const rect = c.rects.get(c.node(area.index).id) orelse ui.Rect{ .x = 0, .y = 0, .w = 600, .h = 600 };

    // Mouse wheel zooms or pans on the canvas.
    if (area.hovered() and c.input.scroll.y != 0) {
        if (c.input.cmd or c.input.ctrl) {
            s.stepZoom(c.input.scroll.y > 0);
        } else {
            s.pan_y = std.math.clamp(s.pan_y + c.input.scroll.y, -480, 480);
            s.pan_x = std.math.clamp(s.pan_x + c.input.scroll.x, -480, 480);
        }
        c.input.scroll = .{};
        c.changed = true;
    }

    // Optional dot-grid backdrop via canvas leaf
    if (s.show_grid) {
        const cv = ui.canvas(c, .{ .absolute = true, .width = .fill, .height = .fill });
        const step: f32 = 24;
        var gx: f32 = 16;
        while (gx < rect.w) : (gx += step) {
            var gy: f32 = 16;
            while (gy < rect.h) : (gy += step) {
                cv.line(.{ .x = gx, .y = gy }, .{ .x = gx + 0.1, .y = gy }, .{ .width = 1.8, .color = k.muted.alpha(0.22) });
            }
        }
    }

    const art = ux.presetSize(s.preset);
    const scale_fit = @min((@max(rect.w - 48, 120)) / @as(f32, @floatFromInt(art.w)), (@max(rect.h - 64, 120)) / @as(f32, @floatFromInt(art.h)));
    const scale = scale_fit * (@as(f32, @floatFromInt(s.zoom_pct)) / 100.0);
    const frame_w = @max(180.0, @as(f32, @floatFromInt(art.w)) * scale);
    const frame_h = @max(220.0, @as(f32, @floatFromInt(art.h)) * scale);
    const ox = (rect.w - frame_w) * 0.5 + s.pan_x;
    const oy = @max(18.0, (rect.h - frame_h) * 0.5 + s.pan_y);

    // Artboard dimension label header above frame
    {
        const hdr = ui.div(c).absolute().offset(ox, @max(2, oy - 18)).row().gap(6).itemsCenter();
        defer hdr.end();
        ui.text(c, c.print("{s}  {d}×{d}", .{ @tagName(s.preset), art.w, art.h }), .{ .size = 10.5, .weight = .medium, .color = k.muted });
        if (s.pin_mode) ui.text(c, "· Click to pin", .{ .size = 10.5, .color = k.accent });
    }

    ui.key(c, "design-artboard-frame");
    const board = kit.shadowLg(
        ui.div(c).absolute().offset(ox, oy).size(frame_w, frame_h).column().p(16).gap(12)
            .bg(k.background).border(if (s.pin_mode) k.accent else k.border_strong).borderW(1).rounded(16).clip().control(),
    );
    defer board.end();

    if (s.pin_mode and board.clicked()) {
        if (c.rects.get(c.node(board.index).id)) |br| {
            const nx = (c.input.mouse.x - br.x) / @max(br.w, 1);
            const ny = (c.input.mouse.y - br.y) / @max(br.h, 1);
            _ = s.addPinNorm(nx, ny);
            a.redraw();
        }
    }

    // Live artboard content: either captured browse snapshot OR live theme/token artboard preview.
    const snap = if (s.source == .browse_snapshot)
        (if (a.browse_conn) |bc| bc.snapshotCopy(c.alloc()) else null)
    else
        null;

    if (snap) |img| {
        ui.text(c, if (img.title.len > 0) img.title else img.url, .{ .size = 11, .weight = .medium, .color = k.muted });
        _ = ui.image(c, .{
            .key = c.print("design-browse-{d}", .{img.seq}),
            .source = .{ .encoded = img.png },
            .box = .{ .w = @max(120, frame_w - 32), .h = @max(120, frame_h - 60) },
            .radius = @floatFromInt(audit.inner_radius),
        });
    } else {
        artboardThemeSpecimen(c, k, s, audit, frame_w);
    }

    if (s.source == .browse_snapshot and s.show_dom_overlay) if (a.browse_conn) |bc| {
        var nodes: [8]@import("browse_connect.zig").StyleNode = undefined;
        const ncount = bc.inspectCopy(&nodes);
        if (ncount > 0) {
            const ov = ui.div(c).absolute().offset(10, @max(10, frame_h - 30 - @as(f32, @floatFromInt(@min(ncount, 3))) * 22)).column().gap(4);
            defer ov.end();
            for (nodes[0..@min(ncount, 3)], 0..) |nd, ni| {
                ui.key(c, c.print("dom-ov-{d}", .{ni}));
                const tag_pill = ui.div(c).row().h(18).px(6).gap(4).itemsCenter().rounded(5)
                    .bg(k.shell.alpha(0.9)).border(if (nd.hit_ok) k.success.alpha(0.5) else k.warning.alpha(0.6)).borderW(1);
                ui.text(c, c.print("<{s}> {d}px r={d}", .{ nd.tagSlice(), nd.font_size_px, nd.radius_px }), .{
                    .size = 9.5,
                    .mono = true,
                    .color = if (nd.hit_ok) k.text else k.warning,
                });
                tag_pill.end();
            }
        }
    };

    // Spatial numbered callout pins overlaid on the artboard.
    const on_accent = k.onAccent();
    for (s.pins[0..s.pin_count], 0..) |pin, idx| {
        const px = std.math.clamp(pin.x * frame_w - 11, 0, @max(0, frame_w - 22));
        const py = std.math.clamp(pin.y * frame_h - 11, 0, @max(0, frame_h - 22));
        ui.key(c, c.print("design-pin-{d}", .{idx}));
        const selected = if (s.focus_pin) |fp| fp == idx else false;
        const badge = ui.div(c).absolute().offset(px, py).size(22, 22).center().roundedFull()
            .bg(if (selected) k.text else k.accent).border(k.background).borderW(1.5).control();
        ui.text(c, c.print("{d}", .{idx + 1}), .{ .size = 10.5, .weight = .semibold, .color = if (selected) k.background else on_accent });
        if (badge.clicked()) {
            s.focus_pin = idx;
            a.redraw();
        }
        badge.end();
    }
}

fn artboardThemeSpecimen(c: *ui.Context, k: theme.Colors, s: *const design.State, audit: design.Audit, frame_w: f32) void {
    // Showcase active theme surface tokens + 2x2 swatches + concentric Dia specimen
    const hero = ui.div(c).column().wFull().p(12).gap(8).rounded(@floatFromInt(audit.inner_radius))
        .bg(k.composer).border(k.border).borderW(1);
    defer hero.end();
    {
        const row = ui.div(c).row().wFull().itemsCenter().gap(6);
        defer row.end();
        const dot = ui.div(c).row().size(18, 18).rounded(5).bg(k.accent);
        dot.end();
        kit.ellipsisText(c, "Design Token Stage", .{ .size = 12.5, .weight = .semibold, .color = k.text }, @max(80, frame_w - 110));
        if (frame_w >= 260) {
            ui.spacer(c);
            const badge = ui.div(c).row().h(18).px(6).center().rounded(5).bg(k.accent.alpha(0.14));
            ui.text(c, c.print("{d}/4 DESIGN.md", .{audit.score}), .{ .size = 10, .weight = .medium, .color = k.accent });
            badge.end();
        }
    }
    ui.text(c, c.print("Artboard {s} · 16px outer -> {d}px concentric", .{ @tagName(s.preset), audit.inner_radius }), .{
        .size = 11,
        .wrap = true,
        .color = k.muted,
    });

    // 2x2 Swatch Specimen Grid (never collides on narrow 390px mobile artboard)
    const swatch_rows = .{
        .{ .{ "Surface", k.background }, .{ "Composer", k.composer } },
        .{ .{ "Accent", k.accent }, .{ "Ink", k.text } },
    };
    inline for (swatch_rows) |pair| {
        const r = ui.div(c).row().wFull().gap(6);
        defer r.end();
        inline for (pair) |sw| {
            const card = ui.div(c).column().grow().w(0).p(6).gap(4).rounded(8).bg(k.ink(0.04)).border(k.border).borderW(1);
            defer card.end();
            ui.div(c).wFull().h(16).rounded(4).bg(sw[1]).border(k.border).borderW(1).end();
            ui.text(c, sw[0], .{ .size = 10.5, .color = k.muted });
        }
    }

    // Concentric Composer & Hit Target Specimen
    const comp = ui.div(c).column().wFull().p(10).gap(8).rounded(@floatFromInt(audit.inner_radius)).bg(k.background).border(k.border).borderW(1);
    defer comp.end();
    ui.text(c, "Sample prompt card", .{ .size = 11, .color = k.muted });
    const cta = ui.div(c).row().wFull().h(32).px(10).center().rounded(8).bg(k.accent);
    ui.text(c, "Apply tokens (>= 32px)", .{ .size = 11, .weight = .medium, .color = k.onAccent() });
    cta.end();
}

fn inspectorDrawer(c: *ui.Context, a: *App, k: theme.Colors, s: *design.State, audit: design.Audit) void {
    const drawer = ui.div(c).column().w(232).hFull().p(10).gap(10).bg(k.shell).scrollY();
    defer drawer.end();

    // 1. Live DESIGN.md Audit Scorecard
    {
        const sec = ui.div(c).column().wFull().gap(5);
        defer sec.end();
        const hdr = ui.div(c).row().wFull().itemsCenter();
        ui.text(c, "DESIGN.md AUDIT", .{ .size = 10, .weight = .semibold, .color = k.muted });
        ui.spacer(c);
        ui.text(c, c.print("{d}.{d:0>2}:1", .{ audit.contrast_x100 / 100, audit.contrast_x100 % 100 }), .{ .size = 10.5, .weight = .medium, .color = k.accent });
        hdr.end();

        for (audit.rules) |rule| {
            const row = ui.div(c).row().wFull().p(7).gap(7).itemsCenter().rounded(7).bg(k.ink(0.04));
            defer row.end();
            icons.icon(c, if (rule.passed) .check else .@"danger-triangle", 13, if (rule.passed) k.success else k.warning, 0);
            const col = ui.div(c).column().w(172).gap(1);
            kit.ellipsisText(c, rule.name, .{ .size = 11, .weight = .medium, .color = k.text }, 172);
            kit.ellipsisText(c, rule.detail, .{ .size = 10, .color = k.muted }, 172);
            col.end();
        }
    }

    // 2. Backdrop Shader & Source Selector
    {
        const sec = ui.div(c).column().wFull().gap(5);
        defer sec.end();
        ui.text(c, "CANVAS SOURCE & SHADER", .{ .size = 10, .weight = .semibold, .color = k.muted });
        const row = ui.div(c).row().wFull().gap(4);
        if (pillBtn(c, k, "Tokens", s.source == .theme_preview)) {
            s.source = .theme_preview;
            a.redraw();
        }
        if (pillBtn(c, k, "Browse live", s.source == .browse_snapshot)) {
            s.source = .browse_snapshot;
            if (a.browse_conn) |bc| _ = bc.refreshScreenshot() catch {};
            a.redraw();
        }
        row.end();

        const studio_btn = ui.div(c).row().wFull().h(30).px(8).gap(6).itemsCenter().rounded(7).bg(k.ink(0.05)).hover(k.hover).control();
        icons.icon(c, .tuning, 12, k.muted, 0);
        ui.text(c, "Backdrop & Scene Studio…", .{ .size = 11, .color = k.text });
        studio_btn.end();
        if (studio_btn.clicked()) @import("view_custom_theme_studio.zig").open(a);

        if (s.source == .browse_snapshot) {
            const dom_hdr = ui.div(c).row().wFull().pt(4).gap(4).itemsCenter();
            ui.text(c, "LIVE DOM STYLES", .{ .size = 10, .weight = .semibold, .color = k.muted });
            ui.spacer(c);
            if (pillBtn(c, k, "Overlay", s.show_dom_overlay)) {
                s.show_dom_overlay = !s.show_dom_overlay;
                a.redraw();
            }
            if (pillBtn(c, k, "Sync DOM", false)) {
                if (a.browse_conn) |bc| bc.spawnOp(.inspect_styles, "", 0, 0);
            }
            dom_hdr.end();
            if (a.browse_conn) |bc| {
                var nodes: [8]@import("browse_connect.zig").StyleNode = undefined;
                const ncount = bc.inspectCopy(&nodes);
                if (ncount == 0) {
                    const msg_box = ui.div(c).w(212);
                    ui.text(c, "Click Sync DOM after connecting browse.app to inspect live CSS & hit targets.", .{ .size = 10, .wrap = true, .color = k.muted });
                    msg_box.end();
                } else {
                    for (nodes[0..@min(ncount, 4)], 0..) |nd, ni| {
                        ui.key(c, c.print("dom-row-{d}", .{ni}));
                        const nrow = ui.div(c).row().wFull().p(5).gap(6).itemsCenter().rounded(6).bg(k.ink(0.04));
                        icons.icon(c, if (nd.hit_ok) .check else .@"danger-triangle", 11, if (nd.hit_ok) k.success else k.warning, 0);
                        kit.ellipsisText(c, c.print("<{s}> {d}px r={d} ({d}×{d})", .{ nd.tagSlice(), nd.font_size_px, nd.radius_px, nd.w, nd.h }), .{ .size = 10, .mono = true, .color = k.text }, 182);
                        nrow.end();
                    }
                }
            }
        }
    }

    // 3. Spatial Callout Pins
    {
        const sec = ui.div(c).column().wFull().gap(5);
        defer sec.end();
        const hdr = ui.div(c).row().wFull().itemsCenter();
        ui.text(c, "SPATIAL PINS", .{ .size = 10, .weight = .semibold, .color = k.muted });
        ui.spacer(c);
        if (s.pin_count > 0) {
            if (pillBtn(c, k, "Clear", false)) {
                s.clearPins();
                a.redraw();
            }
        }
        hdr.end();

        if (s.pin_count == 0) {
            const box = ui.div(c).w(212);
            ui.text(c, "Enable Pin mode above and click artboard to attach critique notes.", .{ .size = 10.5, .wrap = true, .color = k.muted });
            box.end();
        } else {
            var remove_idx: ?usize = null;
            for (s.pins[0..s.pin_count], 0..) |*pin, idx| {
                ui.key(c, c.print("dpin-{d}", .{idx}));
                const card = ui.div(c).column().wFull().p(6).gap(3).rounded(7).bg(k.ink(0.04));
                defer card.end();
                const top = ui.div(c).row().wFull().itemsCenter().gap(4);
                ui.text(c, c.print("#{d} ({d}%, {d}%)", .{ idx + 1, pin.permille_x / 10, pin.permille_y / 10 }), .{ .size = 10.5, .weight = .medium, .color = k.accent });
                ui.spacer(c);
                if (kit.iconButton(c, k, .close, .{ .size = 18, .icon = 10 })) remove_idx = idx;
                top.end();
                _ = ui.textField(c, &pin.note, .{
                    .placeholder = "Describe fix…",
                    .placeholder_color = k.faint,
                    .width = .fill,
                    .bare = true,
                    .size = 11,
                    .line_height = 16,
                });
            }
            if (remove_idx) |ri| {
                s.removePin(ri);
                a.redraw();
            }
            ui.key(c, "design-send-to-agent");
            const send_b = ui.div(c).row().wFull().h(30).px(10).gap(5).center().rounded(7).bg(k.accent).control();
            icons.icon(c, .@"arrow-up", 12, k.onAccent(), 0);
            ui.text(c, "Send critique to chat", .{ .size = 11, .weight = .medium, .color = k.onAccent() });
            send_b.end();
            if (send_b.clicked()) sendCritiqueToComposer(a, s, k);
        }
    }
}

fn sendCritiqueToComposer(a: *App, s: *design.State, k: theme.Colors) void {
    const audit = design.auditTheme(k);
    const formatted = design.formatFeedback(a.gpa, s, k) catch return;
    defer a.gpa.free(formatted);

    // Stage annotated PNG artboard (or live connected browse capture) into composer attachments.
    var staged_live = false;
    if (s.source == .browse_snapshot) if (a.browse_conn) |bc| {
        if (bc.snapshotCopy(a.gpa)) |snap| {
            defer {
                a.gpa.free(snap.png);
                a.gpa.free(snap.title);
                a.gpa.free(snap.url);
            }
            if (snap.png.len > 0) {
                @import("app_attachments.zig").stage(a, "design-canvas-critique.png", snap.png) catch {};
                staged_live = true;
            }
        }
    };
    if (!staged_live) {
        if (design.renderAnnotatedArtboardPng(a.gpa, s, k, audit)) |png| {
            defer a.gpa.free(png);
            @import("app_attachments.zig").stage(a, "design-canvas-critique.png", png) catch {};
        } else |_| {}
    }

    const cur = std.mem.trim(u8, a.composer.text(), " \t\r\n");
    if (cur.len == 0) {
        a.composer.set(formatted);
    } else {
        const joined = std.fmt.allocPrint(a.gpa, "{s}\n\n{s}", .{ cur, formatted }) catch return;
        defer a.gpa.free(joined);
        a.composer.set(joined);
    }
    a.view.focus_composer = true;
    a.redraw();
}
