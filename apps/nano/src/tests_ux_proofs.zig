//! Executable conformance suite verifying that `ux_rules.zig` matches every
//! Lean 4 witness row in `ux_proof_vectors.csv` emitted by `UxVectors.lean`.
const std = @import("std");
const testing = std.testing;
const ux = @import("ux_rules.zig");

const vectors_csv = @embedFile("ux_proof_vectors.csv");

fn parseU32(tok: []const u8) !u32 {
    return std.fmt.parseInt(u32, tok, 10);
}

fn parseBool01(tok: []const u8) !bool {
    if (std.mem.eql(u8, tok, "1")) return true;
    if (std.mem.eql(u8, tok, "0")) return false;
    return error.InvalidBool;
}

fn escStateCase(idx: u32) ux.EscapeTermination.EscState {
    return switch (idx) {
        0 => .{},
        1 => .{ .setup_open = true, .palette_open = true, .agent_busy = true },
        2 => .{ .project_setup_open = true, .popup_menu_open = true },
        3 => .{ .open_chooser_open = true, .settings_open = true },
        4 => .{ .palette_open = true, .popup_menu_open = true, .agent_busy = true },
        5 => .{ .picker_open = true, .settings_open = true },
        6 => .{ .settings_recording = true, .settings_open = true },
        7 => .{ .close_choice_open = true, .agent_busy = true },
        8 => .{ .dialog_open = true, .popup_menu_open = true },
        9 => .{ .popup_menu_open = true, .wizard_can_back = true, .agent_busy = true },
        10 => .{ .image_preview_open = true, .agent_busy = true },
        11 => .{ .write_open = true, .settings_open = true },
        12 => .{ .queue_edit_open = true, .composer_completion_open = true, .agent_busy = true },
        13 => .{ .wizard_can_back = true, .composer_completion_open = true, .agent_busy = true },
        14 => .{ .composer_completion_open = true, .agent_busy = true },
        15 => .{ .settings_open = true, .agent_busy = true },
        16 => .{ .agent_busy = true },
        else => unreachable,
    };
}

test "ux_proof_vectors CSV matches every Lean 4 UX kernel 100%" {
    var lines = std.mem.tokenizeScalar(u8, vectors_csv, '\n');
    var total_rows: usize = 0;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r\t ");
        if (line.len == 0) continue;
        total_rows += 1;
        var it = std.mem.splitScalar(u8, line, ',');
        const kind = it.next().?;

        if (std.mem.eql(u8, kind, "footer")) {
            const sw = try parseU32(it.next().?);
            const pad = try parseU32(it.next().?);
            const sc = try parseBool01(it.next().?);
            const ct = try parseU32(it.next().?);
            const sb = try parseBool01(it.next().?);
            const bt = try parseU32(it.next().?);
            const sa = try parseBool01(it.next().?);
            const got = ux.sessionFooterLayout(sw);
            try testing.expectEqual(pad, got.pad);
            try testing.expectEqual(sc, got.show_checkout);
            try testing.expectEqual(ct, got.checkout_text_max);
            try testing.expectEqual(sb, got.show_branch);
            try testing.expectEqual(bt, got.branch_text_max);
            try testing.expectEqual(sa, got.show_actions);
        } else if (std.mem.eql(u8, kind, "overlay")) {
            const cur: ux.OverlayMutex.OverlayKind = @enumFromInt(try parseU32(it.next().?));
            const nxt: ux.OverlayMutex.OverlayKind = @enumFromInt(try parseU32(it.next().?));
            const res_id = try parseU32(it.next().?);
            const tog_id = try parseU32(it.next().?);
            const t_val = try parseU32(it.next().?);
            const layer_val = try parseU32(it.next().?);
            const scrim_val = try parseBool01(it.next().?);
            const keys_val = try parseBool01(it.next().?);
            const got = ux.OverlayMutex.openOverlay(cur, nxt);
            const got_tog = ux.OverlayMutex.toggleOverlay(cur, nxt);
            try testing.expectEqual(res_id, @intFromEnum(got));
            try testing.expectEqual(tog_id, @intFromEnum(got_tog));
            try testing.expectEqual(t_val, ux.OverlayMutex.tier(got));
            try testing.expectEqual(layer_val, ux.OverlayMutex.activeLayer(got));
            try testing.expectEqual(scrim_val, ux.OverlayMutex.scrimActive(got));
            try testing.expectEqual(keys_val, ux.OverlayMutex.keepsKeyboard(got));
        } else if (std.mem.eql(u8, kind, "escape")) {
            const idx = try parseU32(it.next().?);
            const act_id = try parseU32(it.next().?);
            const w0 = try parseU32(it.next().?);
            const w1 = try parseU32(it.next().?);
            const rc = try parseBool01(it.next().?);
            const st = escStateCase(idx);
            const got_act = ux.EscapeTermination.escAction(st);
            const next_st = ux.EscapeTermination.stepEsc(st);
            try testing.expectEqual(act_id, @intFromEnum(got_act));
            try testing.expectEqual(w0, ux.EscapeTermination.escWeight(st));
            try testing.expectEqual(w1, ux.EscapeTermination.escWeight(next_st));
            try testing.expectEqual(rc, ux.EscapeTermination.restoresComposer(got_act));
        } else if (std.mem.eql(u8, kind, "hover")) {
            const cw = try parseU32(it.next().?);
            const act = try parseBool01(it.next().?);
            const hov = try parseBool01(it.next().?);
            const cc = try parseBool01(it.next().?);
            const res = try parseU32(it.next().?);
            const lw = try parseU32(it.next().?);
            const op = try parseU32(it.next().?);
            try testing.expectEqual(res, ux.HoverStability.tabControlsReserve(cw, act, cc));
            try testing.expectEqual(lw, ux.HoverStability.tabLabelWidth(cw, act, hov, cc));
            try testing.expectEqual(op, ux.HoverStability.tabCloseGlyphOpacityPct(act, hov, cc));
        } else if (std.mem.eql(u8, kind, "close")) {
            const sf: ux.FocusAndClose.SurfaceFocus = @enumFromInt(try parseU32(it.next().?));
            const cc = try parseBool01(it.next().?);
            const gt = try parseU32(it.next().?);
            const sp = try parseU32(it.next().?);
            const hb = try parseBool01(it.next().?);
            const ex = try parseBool01(it.next().?);
            const ic = try parseBool01(it.next().?);
            const na = try parseBool01(it.next().?);
            const dec_id = try parseU32(it.next().?);
            try testing.expectEqual(dec_id, @intFromEnum(ux.FocusAndClose.decideClose(sf, cc, gt, sp, hb, ex, ic, na)));
        } else if (std.mem.eql(u8, kind, "tabcycle")) {
            const tot = try parseU32(it.next().?);
            const cur = try parseU32(it.next().?);
            const fwd = try parseBool01(it.next().?);
            const expected_idx = try parseU32(it.next().?);
            try testing.expectEqual(expected_idx, ux.TabNavModel.stepFlatTab(tot, cur, fwd));
        } else if (std.mem.eql(u8, kind, "mode3")) {
            const mode: ux.UiMode3.UiMode = @enumFromInt(try parseU32(it.next().?));
            const settings_open = try parseBool01(it.next().?);
            const got = ux.UiMode3.profileOf(mode);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_workspace_tree);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_multi_axis_filters);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_row_tech_badges);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_git_checkout_chrome);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_prompt_rail);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_action_toolbar);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_grouped_sections);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_dev_trailing_toggles);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_design_canvas_toggle);
            try testing.expectEqual(try parseBool01(it.next().?), got.shows_zen_new_session_box);
            try testing.expectEqual(try parseBool01(it.next().?), got.suppresses_promos);
            try testing.expectEqual(try parseU32(it.next().?), got.composer_corner_radius);
            try testing.expectEqual(try parseU32(it.next().?), got.trailing_button_count);
            try testing.expectEqual(try parseU32(it.next().?), ux.UiMode3.trailingReservePx(mode, settings_open));
            try testing.expectEqual(try parseU32(it.next().?), @intFromEnum(ux.UiMode3.nextMode(mode)));
        } else if (std.mem.eql(u8, kind, "mode3_resp")) {
            const mode: ux.UiMode3.UiMode = @enumFromInt(try parseU32(it.next().?));
            const settings_open = try parseBool01(it.next().?);
            const avail = try parseU32(it.next().?);
            const last_slot = try parseU32(it.next().?);
            try testing.expectEqual(try parseU32(it.next().?), ux.UiMode3.effectiveTrailingCount(mode, settings_open, avail, last_slot));
            try testing.expectEqual(try parseU32(it.next().?), ux.UiMode3.effectiveTrailingReservePx(mode, settings_open, avail, last_slot));
        } else if (std.mem.eql(u8, kind, "design_zoom")) {
            const z = try parseU32(it.next().?);
            try testing.expectEqual(try parseU32(it.next().?), ux.DesignCanvas.clampZoomPct(z));
            try testing.expectEqual(try parseU32(it.next().?), ux.DesignCanvas.stepZoomPct(z, true));
            try testing.expectEqual(try parseU32(it.next().?), ux.DesignCanvas.stepZoomPct(z, false));
        } else if (std.mem.eql(u8, kind, "design_radius")) {
            const outer = try parseU32(it.next().?);
            const border = try parseU32(it.next().?);
            const pad = try parseU32(it.next().?);
            try testing.expectEqual(try parseU32(it.next().?), ux.DesignCanvas.concentricInner(outer, border, pad));
        } else if (std.mem.eql(u8, kind, "design_contrast")) {
            const la = try parseU32(it.next().?);
            const lb = try parseU32(it.next().?);
            try testing.expectEqual(try parseU32(it.next().?), ux.DesignCanvas.contrastRatioX100(la, lb));
            try testing.expectEqual(try parseBool01(it.next().?), ux.DesignCanvas.meetsWcagAA(la, lb, false));
            try testing.expectEqual(try parseBool01(it.next().?), ux.DesignCanvas.meetsWcagAA(la, lb, true));
        } else if (std.mem.eql(u8, kind, "browse_route")) {
            const scheme: ux.BrowseConnect.UrlScheme = @enumFromInt(try parseU32(it.next().?));
            try testing.expectEqual(try parseU32(it.next().?), @intFromEnum(ux.BrowseConnect.routeScheme(scheme)));
        } else if (std.mem.eql(u8, kind, "browse_code")) {
            const be = try parseU32(it.next().?);
            try testing.expectEqual(try parseU32(it.next().?), ux.BrowseConnect.pairingCode(be));
        } else if (std.mem.eql(u8, kind, "browse_nonce")) {
            const seen = try parseBool01(it.next().?);
            const skew = try parseU32(it.next().?);
            try testing.expectEqual(try parseBool01(it.next().?), ux.BrowseConnect.nonceAccepted(seen, skew));
        } else if (std.mem.eql(u8, kind, "browse_poll")) {
            const st: ux.BrowseConnect.ConnState = @enumFromInt(try parseU32(it.next().?));
            const vis = try parseBool01(it.next().?);
            const elapsed = try parseU32(it.next().?);
            const inf = try parseBool01(it.next().?);
            try testing.expectEqual(try parseBool01(it.next().?), ux.BrowseConnect.shouldPollFrame(st, vis, elapsed, inf));
        } else if (std.mem.eql(u8, kind, "a11y")) {
            const role: ux.WindowA11yFocus.A11yRole = @enumFromInt(try parseU32(it.next().?));
            const has_label = try parseBool01(it.next().?);
            const enabled = try parseBool01(it.next().?);
            const focused = try parseBool01(it.next().?);
            const kb = try parseBool01(it.next().?);
            try testing.expectEqual(try parseBool01(it.next().?), ux.WindowA11yFocus.isInteractiveRole(role));
            try testing.expectEqual(try parseBool01(it.next().?), ux.WindowA11yFocus.requiresAccessibleName(role));
            try testing.expectEqual(try parseBool01(it.next().?), ux.WindowA11yFocus.allowsFocusRing(role, enabled, kb));
            try testing.expectEqual(try parseBool01(it.next().?), ux.WindowA11yFocus.a11yNodeValid(role, has_label, enabled, focused));
        } else if (std.mem.eql(u8, kind, "winfocus")) {
            const modal_open = try parseBool01(it.next().?);
            const cur = try parseU32(it.next().?);
            const modal_id = try parseU32(it.next().?);
            const st: ux.WindowA11yFocus.WindowFocusState = .{
                .active_win = 1,
                .saved_focus = cur,
                .modal_focus = modal_id,
                .current_focus = cur,
                .modal_open = modal_open,
                .window_focused = true,
            };
            const after = ux.WindowA11yFocus.onWindowFocus(ux.WindowA11yFocus.onWindowBlur(st));
            const sw = ux.WindowA11yFocus.onSwitchWindow(st, 2, 77);
            try testing.expectEqual(try parseU32(it.next().?), after.current_focus);
            try testing.expectEqual(try parseU32(it.next().?), sw.active_win);
            try testing.expectEqual(try parseU32(it.next().?), sw.current_focus);
        } else {
            return error.UnknownVectorKind;
        }
    }
    try testing.expect(total_rows >= 300);
}

test "KeymapPartition default bindings are pairwise disjoint and avoid fixed/reserved chords" {
    const KP = ux.KeymapPartition;
    for (KP.fixed_window_chords) |c| {
        try testing.expect(!KP.memChord(c, &KP.composer_reserved_chords));
    }
    for (KP.default_rebindable_chords) |b| {
        try testing.expect(KP.canBindShortcut(b.chord, b.action_id, &KP.default_rebindable_chords));
    }
    // Attempting to bind Cmd+W or Cmd+K or Return must be rejected.
    try testing.expect(!KP.canBindShortcut(.{ .code = 'w', .cmd = true }, 0, &KP.default_rebindable_chords));
    try testing.expect(!KP.canBindShortcut(.{ .code = 'k', .cmd = true }, 0, &KP.default_rebindable_chords));
    try testing.expect(!KP.canBindShortcut(.{ .code = KP.key_enter }, 0, &KP.default_rebindable_chords));
}
