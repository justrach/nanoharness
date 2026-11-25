//! The composer, as the GPUI composer draws it (crates/ui/src/composer.rs,
//! pickers.rs): one rounded pill with attach and dictate on the left, the
//! input ("Do anything…") and a round accent send button that becomes Stop
//! while a run goes with nothing typed. It expands with a line break, and
//! for multiline drafts. New chats share the dock. The model chip (the agent's mark, the model, the
//! reasoning level) leads the footer under the pill.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const attachments = @import("app_attachments.zig");
const attachmentStrip = @import("view_composer_attachments.zig").strip;
const quotes = @import("app_quotes.zig");
const transcript_view = @import("view_transcript.zig");
const footer_view = @import("view_session_footer.zig");
const App = @import("app.zig").App;

fn completionWashes(ctx: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8, changed: bool, undo_restored: bool) []const ui.TextFieldRangeWash {
    const a: *App = @ptrCast(@alignCast(ctx orelse return &.{}));
    const completion = @import("composer_completion.zig");
    completion.afterEdit(a, changed, undo_restored);
    return completion.rangeWashes(a, allocator, text);
}

test {
    _ = @import("tests_composer_completion.zig");
}

/// Docked under a chat's transcript: as wide as the conversation column
/// setting, less its 16-point gutters only once the pane is narrower
/// (shell.rs `composer_target_width`, less the composer's `px(SPACE_LG)`).
pub fn docked(c: *ui.Context, a: *App, k: theme.Colors) void {
    // A selected chat can be visible while host/files own the keys. Do not
    // mount its answer field or replace it with a second prompt editor.
    const question = @import("app_question.zig");
    if ((a.wizard != null or question.pendingInput(a) != null) and !question.ownsActivePane(a)) return;
    // A question that cannot fit this pane has one window-bounded outlet,
    // rendered after the split tree, never a second squeezed copy here.
    if (@import("view_question.zig").expanded(c, a)) return;
    const w = dockedWidth(transcript_view.paneWidth(c, a), transcript_view.column_w);
    const queue_view = @import("view_queue.zig");
    const queued = a.queue.items.len > 0;
    // Queue and input are separate flow surfaces. Never lift the input over
    // the queue's scroll viewport or use decorative padding as scroll content.
    const outer = ui.div(c).column().wFull().px(16).pb(if (a.selected == null and @import("view_newchat.zig").needsTargetRow(c, a, w)) @as(f32, 64) else 40).gap(if (queued) queue_view.gap else 0).itemsCenter();
    defer outer.end();
    // Anchor the work cue to the whole dock so it clears queued rows.
    {
        const work = @import("view_turn_work.zig");
        if (work.changes(c, a)) |t| {
            ui.key(c, "dock-overlays");
            const top = ui.div(c).column().w(w).h(0);
            defer top.end();
            ui.key(c, "turn-work-cue");
            const cue = ui.div(c).row().absolute().offset(-8, -(work.cardHeight(c, a, t, w + 16) + work.gap));
            defer cue.end();
            work.card(c, a, k, t, w + 16);
        }
    }
    // Keyed: the tray coming and going must not change the input's id
    // (which would take its focus).
    dictationStatus(c, a, k, w);
    ui.key(c, "queue-tray");
    _ = queue_view.tray(c, a, k, w);
    ui.key(c, "composer-notice");
    noticeBanner(c, a, k, w, queued);
    ui.key(c, "composer");
    if (a.wizard != null) {
        const q = ui.div(c).column();
        defer q.end();
        // The question may be taller than its pane (a split, a short
        // window): it is told the room the dock has, the pane as last laid
        // out less the bars the conversation shares it with.
        const actions = @import("view_actions.zig");
        const pane = c.node(outer.index).parent;
        c.node(pane).layout_dependent = true;
        const pane_h = if (c.rects.get(c.node(pane).id)) |r| r.h else c.size.h;
        return @import("view_question.zig").panel(c, a, k, w, .{
            .height = pane_h - @import("view_chat_header.zig").height(a) - actions.toolbarHeight(a) - actions.dockHeight(a),
            .dock = outer.index,
        });
    }
    const expanded = attachments.count(a) > 0 or quotes.count(a) > 0 or composerFlip(
        a.view.composer_expanded,
        c.text.width(a.composer.text(), .{ .size = 14, .line_height = 22.75 }),
        compactCapacity(w, dictate.shown(a)),
        std.mem.indexOfScalar(u8, a.composer.text(), '\n') != null,
    );
    a.view.composer_expanded = expanded;
    const p = ui.div(c).column();
    defer p.end();
    pill(c, a, k, w, if (expanded) .expanded else .compact, radius);
    // The session footer, in the slot the 40 points under the pill keep
    // for it (`SESSION_FOOTER_HEIGHT`, 8 under the pill).
    {
        // This zero-height flow anchor follows THIS frame's pill bottom.
        // Offsetting from composer_anchor used its previous height, making
        // the footer jump into the text for one frame on every line change.
        const anchor = ui.div(c).column().w(w).h(0);
        defer anchor.end();
        const f = ui.div(c).row().absolute().offset(0, footer_view.gap);
        defer f.end();
        if (a.selected == null) @import("view_newchat.zig").footer(c, a, k, w) else footer_view.footer(c, a, k, w);
    }
}

/// `composer_target_width` less the composer's own 16-point sides: the
/// conversation width `column` while the pane has room, else the pane
/// less 32.
pub fn dockedWidth(pane_w: f32, column: f32) f32 {
    return @max(@min(column + 32, pane_w) - 32, 0);
}

test "the docked composer is the conversation's width until the pane is narrower (composer_width_shares_the_maximum_only_in_established_threads)" {
    for ([_][2]f32{ .{ 560, 560 }, .{ 736, 736 }, .{ 1200, 1200 } }) |case| {
        try std.testing.expectEqual(case[1], dockedWidth(1600, case[0]));
        try std.testing.expectEqual(@as(f32, 468), dockedWidth(500, case[0]));
        try std.testing.expectEqual(@as(f32, 0), dockedWidth(0, case[0]));
    }
}

/// The GPUI composer's `composer_flip`: decide against the compact width,
/// never the wider post-flip field, so resizing/typing cannot oscillate.
pub fn composerFlip(expanded: bool, text_width: f32, capacity: f32, newline: bool) bool {
    if (newline or capacity < 200) return true;
    return if (expanded) text_width >= capacity - 32 else text_width > capacity;
}

/// The compact input's width less 8 (`compact_capacity`): the pill less
/// its edges (2), side insets (16), attach (28), input insets (16),
/// Send's gap (8) and button (28), then the 8-point expansion reserve.
/// The mic adds its 28-point button and 2-point utility gap.
fn compactCapacity(w: f32, dictation: bool) f32 {
    return @max(0, w - 106 - (if (dictation) @as(f32, 30) else 0));
}

test "composer expansion uses GPUI's width threshold and collapse hysteresis" {
    try std.testing.expectEqual(@as(f32, 204), compactCapacity(340, true));
    try std.testing.expectEqual(@as(f32, 198), compactCapacity(334, true));
    try std.testing.expectEqual(@as(f32, 234), compactCapacity(340, false));
    try std.testing.expectEqual(@as(f32, 0), compactCapacity(0, true));
    try std.testing.expect(!composerFlip(false, 300, 300, false));
    try std.testing.expect(composerFlip(false, 301, 300, false));
    try std.testing.expect(composerFlip(true, 280, 300, false));
    try std.testing.expect(!composerFlip(true, 267, 300, false));
    try std.testing.expect(composerFlip(false, 0, 199, false));
    try std.testing.expect(composerFlip(false, 0, 400, true));
}

pub const Shape = enum { compact, expanded };

/// The pill's corners, docked or on a new chat (`COMPOSER_RADIUS`, 16
/// since 0fe89ff0a).
pub const radius: f32 = 16;

/// `TEXTAREA_MIN`, and the expanded pill it gives (`COMPOSER_MIN_HEIGHT`).
pub const textarea_min: f32 = 60;
pub const expanded_min: f32 = textarea_min + 42 + 2;

pub const ExpandedActionsLayout = struct {
    px: f32,
    send_pl: f32,
    show_mic: bool,
    show_write: bool,
};

/// Keep the primary Attach and Send/Stop controls strictly inside the composer
/// pill in narrow split panes by tightening padding before dropping optional
/// secondary controls (expand-editor, then dictation).
pub fn expandedActionsLayout(w: f32, has_mic: bool) ExpandedActionsLayout {
    const inner = @max(0, w - 2);
    const mic_w: f32 = if (has_mic) 30 else 0;
    // Normal: px(12)*2 + attach(28) + mic(30?) + write(30) + send(pl 8 + 28).
    if (inner >= 24 + 28 + mic_w + 30 + 36) return .{ .px = 12, .send_pl = 8, .show_mic = has_mic, .show_write = true };
    // Tight padding keeps every control down to ~134pt composer width.
    if (inner >= 12 + 28 + mic_w + 30 + 32) return .{ .px = 6, .send_pl = 4, .show_mic = has_mic, .show_write = true };
    // Drop expand-editor (still reachable via ⌘⇧E / Ctrl+Alt+E) before mic.
    if (inner >= 12 + 28 + mic_w + 32) return .{ .px = 6, .send_pl = 4, .show_mic = has_mic, .show_write = false };
    return .{ .px = 6, .send_pl = 4, .show_mic = false, .show_write = false };
}

test "expandedActionsLayout keeps primary controls inside narrow split composers" {
    const wide = expandedActionsLayout(300, true);
    try std.testing.expectEqual(@as(f32, 12), wide.px);
    try std.testing.expect(wide.show_mic and wide.show_write);
    const tight = expandedActionsLayout(140, true);
    try std.testing.expectEqual(@as(f32, 6), tight.px);
    try std.testing.expect(tight.show_mic and tight.show_write);
    const narrow = expandedActionsLayout(128, true);
    try std.testing.expectEqual(@as(f32, 6), narrow.px);
    try std.testing.expect(narrow.show_mic and !narrow.show_write);
    const minimal = expandedActionsLayout(96, true);
    try std.testing.expect(!minimal.show_mic and !minimal.show_write);
}

pub fn pill(c: *ui.Context, a: *App, k: theme.Colors, w: f32, shape: Shape, corner: f32) void {
    @import("view_composer_completion.zig").menu(c, a, k, w);
    // `border_1` takes its point from inside the box in GPUI: the pill is
    // 49 tall compact (`COMPACT_TOTAL_HEIGHT`), 60 + 42 + 2 = 104 expanded
    // (`COMPOSER_MIN_HEIGHT`), its controls a point in from each edge.
    // The accent at 0.55 while the field has the keys (`pill_border`); the
    // field's id is last frame's, which `keepFocus` keeps current.
    if (a.view.focus_composer and a.view.composer_id != 0) c.focus = a.view.composer_id;
    const focused = a.view.composer_id != 0 and c.focus == a.view.composer_id;
    const edge = if (focused) k.accent.alpha(0.55) else k.border;
    ui.key(c, "composer-surface");
    //0.2.172 keeps the writing plane opaque over a glass shell. Use the
    // selected theme before the shell's translucent material is applied.
    const fill = if (k.frosted) theme.colors(k.dark).pill() else k.pill();
    const p = kit.shadowLg(ui.div(c).w(w).bg(fill).border(edge).borderW(1).rounded(corner).p(1)).bg(fill).clip();
    const box = if (shape == .compact) p.column().h(49) else p.column();
    defer box.end();
    // The whole writing plane focuses the input, including its padding.
    // Picker controls keep their own focus when they open.
    if (box.clicked() and a.picker == .none and !a.view.write_open) {
        a.view.focus_composer = true;
        c.selection.clear();
    }
    if (c.rects.get(c.node(box.index).id)) |r| a.view.composer_anchor = r else if (a.window == null) c.animationFrame();
    if (shape == .expanded) {
        attachmentStrip(c, a, k, w);
        @import("view_quotes.zig").strip(c, a, k, w);
    }
    {
        // Keep the field's keyed ancestry in both shapes. Only styles and
        // neighboring controls change: focus, selection, undo and caret do
        // not need to be recreated when the first newline expands the pill.
        ui.key(c, "composer-text-area");
        const area = if (shape == .compact)
            ui.div(c).row().wFull().h(47).px(8).itemsCenter()
        else
            ui.div(c).row().wFull();
        if (shape == .expanded) c.node(area.index).style.min_height = textarea_min;
        defer area.end();
        if (shape == .compact) attachButtons(c, a, k, dictate.shown(a));
        {
            ui.key(c, "composer-text-inner");
            const base = ui.div(c).column().grow().w(0);
            // Preserve GPUI's expanded baseline and bare-field padding.
            const text_gutter: f32 = if (w < 160) 10 else 16;
            const inner = if (shape == .compact) base else base.px(text_gutter - ui.TextFieldRangeWash.side_padding).pt(16 - 1.5).pb(4 + 1.5 - 4);
            defer inner.end();
            input(c, a, k, shape);
        }
        if (shape == .compact) send(c, a, k, 8);
    }
    if (shape == .compact) return;
    // Expanded: attach (and the mic) at the start, Send at the end.
    const act = expandedActionsLayout(w, dictate.shown(a));
    const actions = ui.div(c).row().wFull().h(42).px(act.px).pt(2).pb(8).itemsCenter();
    defer actions.end();
    attachButtons(c, a, k, act.show_mic);
    // Keep the expand button mounted whenever the composer is wide enough
    // (`fixed_write_button_survives_focus_blur` in `Nano/FrameSchedule.lean`),
    // so `ui.textField` blurring `c.focus` on `mouseDown` never unmounts
    // `composer-write` before `mouseUp` completes `clicked()`.
    if (act.show_write) {
        _ = c.leaf(.{ .width = .{ .px = 2 } }, .none, null);
        @import("view_write.zig").button(c, a, k);
    }
    if (a.view.write_open) a.view.focus_composer = false;
    ui.spacer(c);
    send(c, a, k, act.send_pl);
}

const dictate = @import("app_dictation.zig");

fn attachButtons(c: *ui.Context, a: *App, k: theme.Colors, show_mic: bool) void {
    if (kit.iconButton(c, k, .paperclip, .{ .size = 28, .radius = 14, .icon = 18 }))
        attachments.pick(a);
    // The mic shows where the device's Codex voice was found, and while a
    // session is live.
    if (!show_mic) return;
    _ = c.leaf(.{ .width = .{ .px = 2 } }, .none, null);
    if (micButton(c, a, k)) dictate.toggle(a);
}

/// `render_dictation_button`: listening, a red wash as loud as the mic
/// and a red mic; starting or finishing, a faint one.
fn micButton(c: *ui.Context, a: *App, k: theme.Colors) bool {
    const s = &a.dictation;
    const listening = s.running != null and s.listening and !s.finishing;
    const busy = s.running != null and !listening;
    const level = std.math.clamp(s.level, 0, 1);
    ui.key(c, "composer-dictate");
    const base = ui.div(c).row().size(28, 28).center().roundedFull().circular();
    const b = if (listening) base.bg(k.danger.alpha(0.10 + 0.30 * level)) else kit.listenerHover(&a.view.hovers, base, k.ink(0.10)).div;
    defer b.end();
    icons.icon(c, .microphone, 17, if (listening) k.danger else if (busy) k.faint else k.muted, 0);
    return b.clicked();
}

/// `render_dictation_status`: one quiet caption over the composer while
/// dictating, as the queue's notice.
pub fn dictationStatus(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const s = &a.dictation;
    if (s.running == null) return;
    const dot = if (s.finishing or !s.listening) k.faint else k.danger;
    const text = if (s.finishing)
        "Finishing dictation…"
    else if (!s.listening)
        "Starting dictation…"
    else if (s.partial.items.len == 0)
        "Listening — click the mic to stop"
    else
        c.print("Listening — {s}", .{s.partial.items});
    const row = ui.div(c).row().w(w).px(8).pt(6).gap(6).itemsCenter();
    defer row.end();
    _ = c.leaf(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 2.5, .background = dot }, .none, null);
    kit.ellipsisText(c, text, .{ .size = 11, .line_height = 14, .color = k.faint }, w - 16 - 11);
}

/// Separate, width-bounded composer status region (#44). Lives above the keyed
/// composer surface so long notices wrap cleanly without taking horizontal
/// space from the editable field or resetting caret, focus, selection, or undo.
fn noticeBanner(c: *ui.Context, a: *App, k: theme.Colors, w: f32, has_gap: bool) void {
    const text = a.noticeText() orelse return;
    const wrap = ui.div(c).row().w(w).pb(if (has_gap) 0 else 6);
    defer wrap.end();
    const pad_x: f32 = 10;
    const icon_w: f32 = 14;
    const close_w: f32 = 18;
    const gap: f32 = 8;
    const border_w: f32 = 2;
    const show_icon = w >= 160;
    const chrome_w = border_w + pad_x * 2 + (if (show_icon) icon_w + gap else 0) + gap + close_w;
    const text_w = @max(1, w - chrome_w);
    const card = ui.div(c).row().wFull().px(pad_x).py(6).gap(gap).itemsStart().rounded(10)
        .bg(k.danger.alpha(if (k.dark) 0.14 else 0.08))
        .border(k.danger.alpha(if (k.dark) 0.30 else 0.22)).borderW(1);
    defer card.end();
    if (show_icon) {
        const ic = ui.div(c).row().pt(1.5);
        defer ic.end();
        icons.icon(c, .@"danger-triangle", icon_w, k.danger, 0);
    }
    {
        const body = ui.div(c).column().w(text_w).maxH(96).scrollY();
        defer body.end();
        ui.text(c, text, .{ .size = 12, .line_height = 17, .color = k.danger, .wrap = true });
    }
    ui.key(c, "composer-notice-dismiss");
    if (kit.iconButton(c, k, .close, .{
        .size = close_w,
        .radius = 4,
        .icon = 11,
        .color = k.danger.alpha(0.78),
        .label = "Dismiss notice",
    })) {
        a.clearNotice();
        a.view.focus_composer = true;
        c.changed = true;
        a.redraw();
    }
}

fn input(c: *ui.Context, a: *App, k: theme.Colors, shape: Shape) void {
    // Compact, GPUI's line sits half a point lower than nano's centred one.
    const box = if (shape == .compact) ui.div(c).row().wFull().px(8 - ui.TextFieldRangeWash.side_padding).pt(1).itemsCenter() else ui.div(c).column().wFull();
    defer box.end();
    const placeholder = if (a.engine.state != .connected)
        @import("engine_start.zig").waiting(a)
    else if (a.queue_edit != null)
        "Edit queued message…"
    else
        "Do anything…";
    attachments.paste(c, a);
    const field_id = c.peekId(null);
    keepFocus(c, a, field_id);
    // Native popup keys precede the field's Tab traversal and Return submit.
    _ = @import("view_composer_completion.zig").keys(c, a);
    @import("composer_completion.zig").beforeEdit(a, c);
    const prev_edit = c.edits.get(field_id);
    const prev_caret: ?usize = if (prev_edit) |e| e.caret else null;
    const prev_anchor: ?usize = if (prev_edit) |e| e.anchor else null;
    const viewport = transcript_view.paneHeight(c, a) orelse c.size.h;
    const max_lines: u16 = @intFromFloat(@max(1, @min(11, @floor(viewport * 0.35 / 22.75))));
    const field_index: u32 = @intCast(c.nodes.items.len);
    const r = ui.textField(c, &a.composer, .{
        .placeholder = placeholder,
        .width = .fill,
        .bare = true,
        .size = 14,
        // GPUI's composer: 22.75-point lines; with mentions on, its
        // placeholder is muted, not faint (`ComposerInput::render`).
        .line_height = 22.75,
        .placeholder_color = k.muted,
        .multiline = true,
        .selection_mode = .prompt,
        .max_lines = if (shape == .compact) 1 else max_lines,
        .caret = message_caret,
        .caret_color = k.accent,
        .range_wash_context = a,
        .range_wash_provider = completionWashes,
    });
    c.node(field_index).style.scroll_bar = false;
    _ = c.scrollbars.remove(field_id);
    _ = c.anims.remove(field_id);
    if (c.edits.get(field_id)) |e| {
        const clicked_field = c.input.pressed and c.input.button == .left and !c.input.secondary and !c.right_press and c.hot == field_id;
        const moved_selection = prev_caret != null and (e.caret != prev_caret.? or e.anchor != prev_anchor.?);
        if (clicked_field or r.changed or moved_selection) c.selection.clear();
    }
    if (r.focused and c.shortcut(.{ .key = 'a', .cmd = true })) {
        if (c.edits.getPtr(field_id)) |e| {
            e.anchor = 0;
            e.caret = a.composer.text().len;
            c.selection.clear();
            c.changed = true;
        }
    }
    // "Send messages with" (Settings › Shortcuts): Enter sends, or starts a
    // new line and ⌘↩ sends (`composerSendBehavior`).
    a.view.composer_caret = r.caret;
    const on_enter = @import("view_settings_shortcuts.zig").sendsOnEnter(a);
    if (r.submitted) {
        // Shift-Return is always a newline. The field owns this translation,
        // but keep the app boundary safe if a native submit arrives with the
        // modifier still set: it must never send the draft.
        if (on_enter and !c.input.shift) {
            a.send();
        } else {
            _ = a.composer.insert(r.caret, "\n");
            a.composer.want_caret = r.caret + 1;
        }
    }
    // ⌘↩ with something typed sends; with Enter sending, during a run it
    // takes the other follow-up, as ⌘⌥↩ always does (`on_modified_submit`,
    // `on_follow_up_shortcut`).
    const queue_mod = @import("app_queue.zig");
    const has_content = std.mem.trim(u8, a.composer.text(), " \n\t").len > 0 or attachments.count(a) > 0 or quotes.count(a) > 0;
    const other = queue_mod.opposite(queue_mod.followUpBehavior(a));
    if (has_content and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) {
        if (on_enter and a.queues() and a.queue_edit == null) a.sendFollowUp(other) else a.send();
    }
    if (has_content and a.queues() and a.queue_edit == null and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true, .alt = true })) {
        a.sendFollowUp(other);
    }
    recall(c, a, field_id);
    // ⌘↩ with nothing typed sends the newest queued message now.
    if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }) and std.mem.trim(u8, a.composer.text(), " \n\t").len == 0) {
        if (a.queue.items.len > 0) a.queueSendNow(a.queue.items[a.queue.items.len - 1].id);
    }
    if (a.queue_edit != null and c.shortcut(.{ .key = ui.Shortcut.escape })) a.queueFinishEdit(.cancel);
}

/// The message caret (composer.rs, the input's paint: "a rounded accent
/// bar, inset from the line box"): 3 points wide, 2 short of the line box
/// top and bottom, 1.5 round, in the primary accent (the user's accent
/// override included). It blinks at 500 ms and is solid after an edit or
/// a caret move, as nanoui's caret already does.
/// GPUI's insertion caret: a hairline on the glyph, not a 3-point block.
pub const message_caret: ui.TextFieldCaret = .{ .width = 3, .inset = 1, .radius = 1.5 };

/// ↑ at the text's start or ↓ at its end steps through the chat's earlier
/// prompts (`history_step`, `navigate_prompt_history`), unless a question,
/// a queued edit or the model picker has the composer. The key comes as a
/// shortcut before the field sees it, so the caret hasn't moved yet.
fn recall(c: *ui.Context, a: *App, id: u64) void {
    if (a.wizard != null or a.queue_edit != null or a.picker != .none) return;
    const s = c.input.shortcut orelse return;
    if (s.cmd or s.ctrl or s.alt or s.shift) return;
    const delta: i8 = if (s.key == ui.Shortcut.up) -1 else if (s.key == ui.Shortcut.down) 1 else return;
    const f = c.focused_text orelse return;
    if (f.id != id) return;
    const history = @import("prompt_history.zig");
    const text = a.composer.text();
    if (!history.wantsStep(&a.prompt_nav, text, delta, f.caret, f.anchor, f.marked != null)) return;
    _ = c.shortcut(s);
    const next = a.prompt_nav.step(a.gpa, a.transcript.entries.items, text, delta) catch return;
    if (next) |t| {
        a.composer.set(t);
        c.selection.clear();
    }
}

/// The composer has the keys after the window moves to another chat, pane
/// or tab (`focus_composer`), and keeps them when its field moves in the
/// layout (into a split's pane, or taller with a second line), which
/// gives the field another id.
fn keepFocus(c: *ui.Context, a: *App, id: u64) void {
    const moved = a.view.composer_id != 0 and id != a.view.composer_id and c.focus == a.view.composer_id;
    a.view.composer_frame = c.frame;
    if (a.view.focus_composer or moved) {
        const pill_unfocused = a.view.composer_id == 0 or c.focus != a.view.composer_id;
        c.focus = id;
        if (pill_unfocused) c.changed = true;
        a.view.focus_composer = false;
    }
    a.view.composer_id = id;
}

/// The model chip: what the next message runs on, 24 tall at the footer's
/// leading edge (`PickerKind::HarnessModel`'s trigger). Returns the width
/// it takes this frame, for the footer to share out the rest.
const chip_measure_style: ui.TextStyle = .{ .size = 12, .line_height = 12 * 1.618, .weight = theme.ui_medium_weight };

const ChipMeasure = struct {
    t: @import("app_agent.zig").Target,
    chat_harness: bool,
    max_chip_w: f32,
    unresolved: bool,
    label_loading: bool,
    failed: bool,
    label_text: []const u8,
    suffix_text: ?[]const u8,
    icon_only: bool,
    wanted_w: f32,
    target_w: f32,
    glyph_w: f32,
    idle_drawn_w: f32,
};

fn measureChip(c: *ui.Context, a: *const App, max_w_override: ?f32) ChipMeasure {
    const t = a.target();
    const room = @max(28, transcript_view.paneWidth(c, a) - 32 - 100);
    const max_chip_w = if (max_w_override) |m| @max(28, @min(248, m)) else @min(248, room);
    const chat_harness = if (a.selected) |id| (if (a.findChat(id)) |ch| ch.harness != null else false) else false;
    const unresolved = a.harnesses.items.len == 0 and !chat_harness and a.harnesses_failed;
    const label_loading = !unresolved and a.models.items.len == 0 and t.model == null;
    const failed = if (label_loading) (if (a.view.model_picker.catalogs.get(t.harness)) |cat| cat.failed else false) else false;
    const label_text = if (!unresolved and !label_loading) a.modelLabel(t.model) else "";
    const suffix_text: ?[]const u8 = if (!unresolved and !label_loading) (if (t.reasoning) |level| rules.reasoningLabel(level) else null) else null;
    const icon_only = max_chip_w < 52;
    var wanted_w: f32 = 12 + 16;
    if (!unresolved and !icon_only) {
        if (label_loading) {
            if (!failed) wanted_w += 6 + 56;
        } else {
            wanted_w += 6 + @ceil(c.text.width(label_text, chip_measure_style));
            if (suffix_text) |sfx| wanted_w += 6 + @ceil(c.text.width(sfx, chip_measure_style));
        }
    }
    const glyph_w: f32 = if (!unresolved and a.harnesses.items.len == 0 and !chat_harness) 5 else 16;
    return .{
        .t = t,
        .chat_harness = chat_harness,
        .max_chip_w = max_chip_w,
        .unresolved = unresolved,
        .label_loading = label_loading,
        .failed = failed,
        .label_text = label_text,
        .suffix_text = suffix_text,
        .icon_only = icon_only,
        .wanted_w = wanted_w,
        .target_w = @min(wanted_w, max_chip_w),
        .glyph_w = glyph_w,
        .idle_drawn_w = @min(@max(wanted_w - 16, 12 + (if (icon_only) @as(f32, 0) else 6)) + glyph_w, max_chip_w),
    };
}

/// Non-mutating chip width estimate for layout probes before the footer draws.
pub fn chipWidth(c: *ui.Context, a: *const App) f32 {
    return measureChip(c, a, null).idle_drawn_w;
}

pub fn chip(c: *ui.Context, a: *App, k: theme.Colors) f32 {
    return chipWithMax(c, a, k, null);
}

pub fn chipWithMax(c: *ui.Context, a: *App, k: theme.Colors, max_w_override: ?f32) f32 {
    const mp = @import("model_picker.zig");
    const m = measureChip(c, a, max_w_override);
    const width_sample = mp.ScalarTransition.sample(&a.view.model_picker.chip_width, m.target_w, c.time, c.reduced_motion);
    if (width_sample.moving) c.frameIn(1.0 / 120.0);

    var base = ui.div(c).row().h(24).maxW(m.max_chip_w).px(6).gap(if (m.icon_only) 0 else 6).itemsCenter().rounded(8).clip();
    if (width_sample.moving) base = base.w(width_sample.value);
    const full_hint: ?[]const u8 = if (!m.unresolved and !m.label_loading and (m.icon_only or m.wanted_w > m.max_chip_w))
        (if (m.suffix_text) |sfx| c.print("{s} · {s}", .{ m.label_text, sfx }) else m.label_text)
    else
        null;
    if (full_hint) |hint| base = @import("view_tooltip.zig").on(base, k, .{ .text = hint });
    // At rest it is its content: the glyph (the 5-point loader until an
    // agent is known) in its insets, the label's gap (kept even for no
    // label), and the words.
    const drawn_w = if (width_sample.moving) @min(width_sample.value, m.max_chip_w) else m.idle_drawn_w;
    // GPUI's trigger uses on_hover: closing by keyboard doesn't move the
    // pointer and must not clear the wash until the pointer actually moves.
    const b = kit.listenerHover(&a.view.hovers, if (a.picker != .none) base.bg(k.hover) else base, k.hover).div;
    defer b.end();
    if (b.clicked()) a.togglePickerCompact();
    if (c.rects.get(c.node(b.index).id)) |r| a.view.chip_anchor = r;
    // Before the engine lists them: the glyph spinner for an agent not yet
    // known (an open chat's is: its own), a pulsing bar for its model
    // (`trigger_chip` loading, `chip_icon_loading`).
    // The list failed and nothing names an agent: GPUI's `effective_harness`
    // is none, so a muted terminal and no label, not a loader.
    // Its label is always a child, empty or not, so its gap stays.
    if (m.unresolved) {
        icons.icon(c, .terminal, 16, k.muted, 0);
        if (!m.icon_only) _ = c.leaf(.{ .width = .{ .px = 0 } }, .none, null);
        return drawn_w;
    }
    if (a.harnesses.items.len == 0 and !m.chat_harness) {
        kit.snake(c, k);
    } else if (chipMaker(a)) |maker| {
        // With the two-step picker, the model's maker names it, untinted
        // (muted); the agent's mark only when no maker is known (pickers.rs
        // `model_maker`/`maker_icon` over `model_chip_icon`).
        icons.icon(c, maker, 16, k.muted, 0);
    } else {
        const mark = icons.harnessMark(m.t.harness);
        icons.icon(c, mark.name, 16, mark.brand orelse k.muted, 0);
    }
    if (m.icon_only) return drawn_w;
    if (m.label_loading) {
        // A failed catalog has nothing to name: no label, no ghost bar.
        if (m.failed) _ = c.leaf(.{ .width = .{ .px = 0 } }, .none, null) else skeleton(c);
        return drawn_w;
    }
    // `hover_blend`: the label brightens under the pointer, rolling Scritto-style when changed.
    // Re-read after `togglePickerCompact` in case opening the picker synced `a.models`.
    const live_t = a.target();
    const live_label = if (!m.unresolved and !m.label_loading) a.modelLabel(live_t.model) else m.label_text;
    const live_suffix: ?[]const u8 = if (!m.unresolved and !m.label_loading) (if (live_t.reasoning) |level| rules.reasoningLabel(level) else null) else m.suffix_text;
    const label_st: ui.TextStyle = .{ .size = 12, .line_height = 12 * 1.618, .weight = theme.ui_medium_weight, .color = if (b.hovered()) k.text else k.text.alpha(0.9) };
    const suffix_st: ui.TextStyle = .{ .size = 12, .line_height = 12 * 1.618, .weight = theme.ui_medium_weight, .color = k.muted.alpha(0.7) };
    const text_room = @max(0, m.max_chip_w - (12 + m.glyph_w + 6));
    const live_label_w = @ceil(c.text.width(live_label, chip_measure_style));
    const live_suffix_w: f32 = if (live_suffix) |sfx| 6 + @ceil(c.text.width(sfx, chip_measure_style)) else 0;
    if (live_label_w + live_suffix_w <= text_room) {
        kit.rollText(c, "composer-model-label", live_label, label_st);
        if (live_suffix) |sfx| kit.rollText(c, "composer-effort-suffix", sfx, suffix_st);
    } else {
        kit.ellipsisText(c, live_label, label_st, text_room);
    }
    return drawn_w;
}

/// Whether the footer has a follow-up switch to draw.
pub fn followUpShown(a: *const App) bool {
    return @import("app_queue.zig").targetSteersMidTurn(a);
}

/// "Steer" or "Queue", as the follow-up switch says it.
pub fn followUpLabel(a: *const App) []const u8 {
    return if (@import("app_queue.zig").followUpBehavior(a) == .steer) "Steer" else "Queue";
}

/// Follow-up mode switch in the composer footer: shows whether a message
/// sent during a live turn will Steer or Queue, and toggles on click.
/// `glyph_only` leaves its word to the tooltip where the footer is narrow.
pub fn followUpChip(c: *ui.Context, a: *App, k: theme.Colors, glyph_only: bool) void {
    const queue_mod = @import("app_queue.zig");
    if (!followUpShown(a)) return;
    const mode = queue_mod.followUpBehavior(a);
    const is_steer = mode == .steer;
    const hint = if (is_steer)
        "Follow-ups steer into the active turn. Click to queue for the next turn"
    else
        "Follow-ups wait in the queue until the turn finishes. Click to steer immediately";
    ui.key(c, "composer-follow-up-chip");
    var b = ui.div(c).row().h(20).px(if (glyph_only) 4 else 8).gap(if (glyph_only) 0 else 5).itemsCenter().rounded(6).hover(k.hover);
    b = @import("view_tooltip.zig").on(b, k, .{ .text = hint });
    defer b.end();
    const hot = b.hovered();
    const color = if (hot) k.text.alpha(0.85) else if (is_steer) k.text.alpha(0.78) else k.muted.alpha(0.7);
    icons.icon(c, if (is_steer) .@"fast-tier" else .@"queue-drag-handle", 12, color, 0);
    if (!glyph_only) ui.text(c, followUpLabel(a), .{
        .size = 12,
        .line_height = 12 * 1.618,
        .weight = theme.ui_medium_weight,
        .color = color,
    });
    if (b.clicked()) queue_mod.toggleFollowUp(a);
}

/// The selected model's maker mark, or the catalog's first model's when
/// none is picked, as the label resolves it.
fn chipMaker(a: *App) ?icons.Name {
    const mp = @import("model_picker.zig");
    const t = a.target();
    const list = mp.modelsFor(a, t.harness);
    const id = t.model orelse (if (list.len > 0) list[0].id else return null);
    for (list) |m| if (std.mem.eql(u8, m.id, id)) return mp.makerIcon(m);
    return null;
}

/// A label still loading: a 56 by 11 bar whose opacity breathes between
/// 0.35 and 0.75 every 2.4 s (popover.rs `skeleton_bar`).
fn skeleton(c: *ui.Context) void {
    const phase = @sin(@as(f32, @floatCast(c.time)) * std.math.tau / 2.4) * 0.5 + 0.5;
    kit.loaderFrame(c, 1.0 / 30.0);
    _ = c.leaf(.{ .width = .{ .px = 56 }, .height = .{ .px = 11 }, .radius = 5.5, .background = c.theme.text.alpha(0.08 * (0.35 + 0.4 * phase)) }, .none, null);
}

/// Send (or queue, while a run goes); Stop with nothing typed mid-run.
fn send(c: *ui.Context, a: *App, k: theme.Colors, pad_left: f32) void {
    const empty = std.mem.trim(u8, a.composer.text(), " \n\t").len == 0 and attachments.count(a) == 0 and quotes.count(a) == 0;
    const running = a.selectedStatus() == .working;
    const stop = running and empty;
    // Dimmed only when it can't send at all; an empty box just does nothing.
    const blocked = !stop and (@import("app_agent.zig").chatSendBlocked(a) or !attachments.ready(a));
    const pad = ui.div(c).row().pl(pad_left);
    defer pad.end();
    // Filled with the primary accent, its glyph contrast-checked on it
    // (`render_send_button`, `on_primary_accent`). `.circular()` renders a
    // true analytical Euclidean circle rather than a squircle polygon.
    var b = ui.div(c).row().size(28, 28).center().roundedFull().circular().bg(k.accent);
    b = b.opacity(if (blocked) 0.35 else if (b.hovered()) 0.85 else 1);
    defer b.end();
    if (b.clicked() and !blocked and (stop or !empty)) {
        if (stop) a.interrupt() else a.send();
    }
    if (stop) {
        _ = c.leaf(.{ .width = .{ .px = 11 }, .height = .{ .px = 11 }, .radius = 3, .background = k.onAccent() }, .none, null);
    } else {
        icons.icon(c, .@"arrow-up", 14, k.onAccent(), 0);
    }
}
