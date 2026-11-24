//! The open chat's transcript, as the GPUI transcript draws it
//! (crates/ui/src/transcript.rs): a centred column 736 points wide, the
//! user's messages as bubbles on the right, the agent's Markdown, its tool
//! calls and reasoning folded into groups ("Ran 2 commands"), errors as
//! chips, and under each message a lane whose copy button shows on hover.
//! An error signing in fixes says so and offers "Log in" (run_errors.zig);
//! a typed ChatGPT sign-in error carries its reconnect card
//! (view_reauth.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const file_icons = @import("file_icons.zig");
const kit = @import("view_kit.zig");
const tools = @import("tools.zig");
const compact = @import("compact.zig");
const tr = @import("transcript.zig");
const steer_order = @import("steer_order.zig");
const attachment_refs = @import("attachment_refs.zig");
const attachment_images = @import("app_attachment_images.zig");
const before_after = @import("view_before_after.zig");
const image_gallery = @import("view_image_gallery.zig");
const reply_images = @import("view_reply_images.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;
const rows_st = @import("view_settings_accounts_rows.zig").st;

/// The column's width: Settings › Appearance's conversation width
/// (`transcript_width`, 736 unless set), as of this frame.
pub var column_w: f32 = 736;

/// The column's width in a main area `w` wide, with its gutters.
pub fn columnWidth(w: f32) f32 {
    const gutter = std.math.clamp(w * 0.06, 12, 48);
    return @max(0, @min(column_w, w - 2 * gutter));
}

/// The shared shell frame owns the actual chat allocation, including the
/// dynamic host/explorer widths; never subtract their old fixed widths.
pub fn mainWidth(c: *ui.Context, a: *const App) f32 {
    _ = c;
    return a.view.chrome.chat_width;
}

/// What lays out inside the column: GPUI's card takes the rounded seam's
/// hairline as its left border (`border_l_1`), a point of layout, while
/// its width sums and the rail's gate use the column whole.
pub fn contentWidth(c: *ui.Context, a: *const App) f32 {
    return mainWidth(c, a) - a.view.seam_inset;
}

/// The focused pane's width: the chat column's, less the other panes of a
/// split across it.
pub fn paneWidth(c: *ui.Context, a: *const App) f32 {
    const w = contentWidth(c, a);
    if (@import("view_tab_strip.zig").layoutExpanded(a) != null) return w;
    const s = a.tabs.layout() orelse return w;
    if (s.zoomed or s.axis != .horizontal or s.panes.items.len <= 1) return w;
    const total = a.view.chrome.chat_width;
    const chrome = @import("panel_chrome.zig");
    const ws_gutter = chrome.zen_gutter;
    const target = chrome.paneSpanIn(total, s.shares.items[s.focus], s.panes.items.len, true, ws_gutter);
    const span = if (a.view.split_reveal) |r| blk: {
        if (r.tab != a.tabs.active or r.new_index >= s.panes.items.len) break :blk target;
        const start = r.started orelse c.time;
        const raw: f32 = if (c.reduced_motion) 1 else @floatCast(std.math.clamp((c.time - start) / 0.24, 0, 1));
        const inv = 1 - raw;
        const t: f32 = if (c.reduced_motion) 1 else 1 - inv * inv * inv * inv * inv;
        break :blk @import("view.zig").revealSpan(total, true, r, s.focus, target, t);
    } else target;
    return @max(0, span - a.view.seam_inset);
}

/// The focused pane's height under the title bar, in a split down the
/// window; null when it has the column's full height.
pub fn paneHeight(c: *ui.Context, a: *const App) ?f32 {
    const s = a.tabs.layout() orelse return null;
    if (s.zoomed or s.axis != .vertical or @import("view_tab_strip.zig").layoutExpanded(a) != null) return null;
    _ = c;
    return @max(0, @import("panel_chrome.zig").paneSpan(a.view.chrome.height, s.shares.items[s.focus], s.panes.items.len, false) - a.view.seam_inset);
}

/// The open chat's transcript, and over its left edge the prompt rail
/// (`render_rail`, view_rail.zig): the column it is in is the rail's.
pub fn transcript(c: *ui.Context, a: *App, k: theme.Colors) void {
    const rail = @import("view_rail.zig");
    rail.step(c, &a.view.rail);
    const just_stuck = a.view.stick_end;
    const pane_w = paneWidth(c, a);
    const header_view = @import("view_chat_header.zig");
    const top_pad: f32 = if (header_view.height(a) > 0) 16 else 64 - @import("view_sidebar.zig").titlebar_h;
    const drawn = entries(c, a, k, &a.transcript, pane_w, a.w_doc.id != null, top_pad);
    if (a.settings.hierarchyProfile().shows_prompt_rail)
        rail.rail(c, k, &a.view.rail, &a.transcript, drawn.ticks, drawn.box, pane_w + a.view.seam_inset);
    if (!just_stuck and !drawn.turn_anchored) recoverBlank(c, a, drawn);
    a.view.jump_box = drawn.box;
    a.view.jump_distance = drawn.from_end;
}

/// A scroll offset left over from a taller transcript can park the reader
/// in padding, with no row in the window. That is not a place to stay.
fn recoverBlank(c: *ui.Context, a: *App, drawn: Drawn) void {
    if (drawn.box == 0 or drawn.ticks.len == 0) return;
    const view = c.rects.get(drawn.box) orelse return;
    var any = false;
    var near = false;
    for (drawn.ticks) |tick| if (tick.top) |top| {
        any = true;
        if (top + 200 >= view.y - 80 and top <= view.y + view.h + 80) near = true;
    };
    if (c.scroll_max.get(drawn.box)) |max| {
        const at = c.scroll.get(drawn.box) orelse 0;
        if (at <= max + 1) near = true;
    }
    if (!any or near) return;
    // One correction. Repeating it rebuilds the window forever and the
    // beachball follows.
    if (a.view.blank_recovered == drawn.box) return;
    a.view.blank_recovered = drawn.box;
    c.scroll.put(c.gpa, drawn.box, std.math.floatMax(f32)) catch {};
    c.scroll_follow.put(c.gpa, drawn.box, true) catch {};
    a.view.jump_distance = 0;
    a.view.jump_shown = false;
    c.changed = true;
}

/// What a transcript drew: its scroll box, and its prompts' rows as last
/// laid out.
pub const Drawn = struct {
    box: u64 = 0,
    /// The current turn owns positioning; historical blank recovery must
    /// not replace its deliberate top anchor with bottom-follow.
    turn_anchored: bool = false,
    ticks: []const @import("view_rail.zig").Tick = &.{},
    /// How far the reader is from the end. The jump pill shows past GPUI's
    /// `SCROLL_BUTTON_THRESHOLD_PX`.
    from_end: f32 = 0,
};

/// A transcript `w` wide: the open chat's, or a split pane's neighbor's.
/// The first row sits `top` points down. Live turns keep a top reading
/// anchor; untouched completed history opens at its normal end position.
pub fn entries(c: *ui.Context, a: *App, k: theme.Colors, t: *const tr.Transcript, w: f32, loading: bool, top: f32) Drawn {
    const frame = ui.div(c).column().grow().wFull().h(0);
    defer frame.end();
    const drawn = rows(c, a, k, t, w, loading, top);
    topFade(c, a, k, drawn.box);
    return drawn;
}

/// `TRANSCRIPT_FADE_BAND`: rows scrolled up fade out over the 24 points
/// under the title bar, gone by its edge (shell.rs `edge_faded`, its
/// `inset_top(TITLEBAR_HEIGHT)`), here as the column's colour laid over
/// them a point at a time.
fn topFade(c: *ui.Context, a: *const App, k: theme.Colors, scroll_box: u64) void {
    _ = a;
    // Leave unscrolled conversations completely clean at the top and gently
    // fade scrolled rows into the inset card plane.
    if ((c.scroll.get(scroll_box) orelse 0) <= 1.0) return;
    const fade_bg = @import("view_panel_chrome.zig").zenPageBg(k);
    const band: f32 = 18;
    var y: f32 = 0;
    while (y < band) : (y += 1) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = fade_bg.alpha(1 - (y + 0.5) / band), .absolute = true, .offset = .{ .x = 0, .y = y } }, .none, null);
    }
}

/// A live turn is positioned once, not chased as its content grows. Only an
/// explicit send starts another anchor; manual scrolling always remains free.
pub const TurnAnchor = struct { turn: u64, pending: bool = true };

fn rows(c: *ui.Context, a: *App, k: theme.Colors, t: *const tr.Transcript, w: f32, loading: bool, top: f32) Drawn {
    const tweening = a.view.sidebar_tween != null or a.view.split_reveal != null;
    const resizing = c.time < a.view.resize_until;
    const raw_col = columnWidth(w);
    const col = @import("motion_rules.zig").tweenColumnWidth(tweening, raw_col, column_w);
    // The last row clears the status strip over the composer and the fade
    // band above it (`bottom_clearance + TRANSCRIPT_FADE_BAND + 8`); the
    // composer itself is under the scroll, not over it. Its bar shows
    // while it scrolls, as GPUI's overlay rail.
    var st: ui.Style = .{ .grow = 1, .width = .fill, .padding = .{ .top = top, .bottom = 24 + 24 + 8 }, .align_items = .center, .justify = .end, .follow_end = true };
    if (@hasField(ui.Style, "scrollbar")) st.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
    const subagent = for (a.panels.tabs.items) |tab| {
        if (tab.agent) |s| if (&s.transcript == t) break s;
    } else null;
    if (subagent != null) st.justify = .start;
    st.scroll = true;
    st.selectable = true;
    st.direction = .column;
    // The chat these are, for routing a sign-in: the open one's or a pane's.
    const chat_id: ?[]const u8 = if (subagent) |s| s.parent else if (t == &a.transcript) a.selected else for (a.peers.items) |*p| {
        if (&p.transcript == t) break p.id;
    } else null;
    if (subagent == null) if (chat_id) |id| ui.key(c, c.print("scroll-{s}", .{id}));
    const scroll = c.open(st, null);
    // A cached peer is promoted into the focused outlet after its release.
    // Its native text/edit/control IDs must follow the transcript, not the
    // old parent's node position, or the just-created selection vanishes.
    if (subagent) |agent| {
        // A child tab is a revocable surface, not just a slot or document
        // name. A press retained from a closed child must not match the
        // link/control IDs of a replacement (even the same doc reopened).
        // Duplicate opens reuse the live Agent, so its feed and native IDs
        // stay stable until that actual surface is retired.
        const lifetime = @intFromPtr(agent);
        var identity = std.hash.Wyhash.init(0x4348_494c_445f_5549);
        identity.update(agent.parent);
        identity.update(agent.doc);
        identity.update(std.mem.asBytes(&lifetime));
        c.node(scroll).id = identity.final();
    } else if (chat_id) |id| {
        c.node(scroll).id = std.hash.Wyhash.hash(0x5452_414e_5343_5250, id);
    }
    defer ui.end(c);
    var drawn: Drawn = .{ .box = c.node(scroll).id };
    const entries_ = t.entries.items;
    const streaming = entries_.len > 0 and entries_[entries_.len - 1].status == .streaming;
    // Keep the prompt and current reply near the top, with enough runway
    // below a short turn to position it there. Completed history retains its
    // normal end position until a live turn has established an anchor.
    const turn_start: ?usize = blk: {
        if (subagent != null or entries_.len == 0) break :blk null;
        var i = entries_.len;
        while (i > 0) {
            i -= 1;
            if (entries_[i].isHumanPrompt()) break :blk i;
        }
        break :blk entries_.len - 1;
    };
    var anchor: ?*TurnAnchor = null;
    if (turn_start) |i| {
        const turn = std.hash.Wyhash.hash(drawn.box, entries_[i].id);
        const previous = a.view.reply_anchors.get(drawn.box);
        const session = if (chat_id) |id| @import("workspace.zig").sessionOf(a.sessions.items, id) else null;
        const pending = if (chat_id) |id| @import("app_send_feedback.zig").active(a, id, t) != null else false;
        const live = streaming or (entries_[entries_.len - 1].role == .user and (pending or (session != null and session.?.status == .working)));
        if (live or (previous != null and previous.?.turn == turn)) {
            const slot = a.view.reply_anchors.getOrPut(a.gpa, drawn.box) catch null;
            if (slot) |s| {
                if (!s.found_existing or s.value_ptr.turn != turn) s.value_ptr.* = .{
                    .turn = turn,
                    .pending = !c.scroll.contains(drawn.box) or (c.scroll_follow.get(drawn.box) orelse true),
                };
                anchor = s.value_ptr;
                c.node(scroll).style.justify = .start;
            }
        }
    }
    // Just sent: past the end, which layout clamps to it, and moving the
    // offset there makes the box follow its end again (`follow_end`).
    const just_stuck = subagent == null and t == &a.transcript and a.view.stick_end;
    if (just_stuck and anchor != null) {
        a.view.stick_end = false;
        anchor.?.pending = true;
    } else if (just_stuck) {
        a.view.stick_end = false;
        const sync = @import("motion_rules.zig").stickEndScroll(c.scroll_max.get(drawn.box));
        c.scroll_follow.put(c.gpa, drawn.box, sync.follow) catch {};
        c.scroll.put(c.gpa, drawn.box, sync.scroll) catch {};
        c.scroll_seen.put(c.gpa, drawn.box, sync.seen) catch {};
    }
    drawn.turn_anchored = anchor != null;
    if (anchor) |target| if (target.pending) {
        const offset = c.scroll.get(drawn.box) orelse 0;
        c.scroll.put(c.gpa, drawn.box, offset) catch {};
        c.scroll_seen.put(c.gpa, drawn.box, offset) catch {};
        c.scroll_follow.put(c.gpa, drawn.box, false) catch {};
    };
    if (subagent == null and t == &a.transcript) {
        if (streaming and !a.offscreen and !c.reduced_motion and !just_stuck and a.view.rail.glide == null) {
            const last_e = &entries_[entries_.len - 1];
            var sig: u64 = @as(u64, last_e.parts.items.len) << 32;
            for (last_e.parts.items) |*p| sig +%= @as(u64, p.text.items.len) *% 0x9e3779b97f4a7c15;
            if (sig != a.view.stream_sig) {
                a.view.stream_sig = sig;
                a.view.stream_glide_until = c.time + 0.32;
            }
            const follow = c.scroll_follow.get(drawn.box) orelse true;
            if (follow) {
                const max_s = c.scroll_max.get(drawn.box) orelse 0;
                const cap = ui.spring(c, drawn.box, 0x7363_6361, max_s, .{ .response = 0.20, .damping = 1.0 });
                c.scroll_cap.put(c.gpa, drawn.box, @max(0, cap)) catch {};
                if (@abs(cap - max_s) > 0.25 or c.time < a.view.stream_glide_until) {
                    c.animationFrame();
                }
            } else {
                ui.jump(c, drawn.box, 0x7363_6361, c.scroll.get(drawn.box) orelse 0);
                _ = c.scroll_cap.remove(drawn.box);
            }
        } else {
            a.view.stream_sig = 0;
            ui.jump(c, drawn.box, 0x7363_6361, c.scroll_max.get(drawn.box) orelse 0);
            _ = c.scroll_cap.remove(drawn.box);
        }
    }
    if (c.scroll_max.get(drawn.box)) |max| {
        const at = c.scroll.get(drawn.box) orelse 0;
        drawn.from_end = @max(0, max - at);
    }
    var ticks: std.ArrayList(@import("view_rail.zig").Tick) = .empty;
    const body = ui.div(c).column().w(col).clip();
    if (subagent == null and t == &a.transcript and streaming and !a.offscreen and !c.reduced_motion and !just_stuck and a.view.rail.glide == null) {
        c.node(body.index).style.settle_y = .{ .response = 0.20, .damping = 1.0 };
    }
    defer body.end();
    // Loading does not itself imply work; the session row does, even when
    // no assistant part has arrived yet.
    _ = loading;
    const scroll_rect = c.rects.get(drawn.box);
    const sel_owner_mod = @import("selection_owner.zig");
    const sel_surface = sel_owner_mod.state(c).surface;
    const saved_pin = sel_owner_mod.pin(c).*;
    const anchor_id: u64 = if (c.selection.anchor) |p| p.id else 0;
    const focus_id: u64 = if (c.selection.focus) |p| p.id else anchor_id;
    const selection_elsewhere = sel_surface != 0 and sel_surface != drawn.box;
    const pin_same_surface = saved_pin.surface == drawn.box;
    const pin_usable = anchor_id != 0 and !selection_elsewhere and pin_same_surface and saved_pin.anchor == anchor_id;
    const need_full_for_selection = !selection_elsewhere and anchor_id != 0 and pin_same_surface and saved_pin.needs_scan;
    // The column's required clip prevents NanoUI's retained-scroll fast
    // path. Keep measured offscreen rows as spacers during wheel scroll,
    // mouse-down, active drag, and completed selection: only the active
    // selection's own row span is pinned while unselected history stays
    // culled. A one-shot scan runs only when an endpoint is offscreen and
    // not yet pinned.
    const cull_offscreen = !need_full_for_selection and (!a.offscreen or tweening or resizing) and a.view.rail.glide == null;
    var sel_pin: SelectionPin = .{
        .active = pin_usable and saved_pin.lo_row != 0,
        .lo_row = if (pin_usable) saved_pin.lo_row else 0,
        .hi_row = if (pin_usable) saved_pin.hi_row else 0,
        .scanning = anchor_id != 0 and !selection_elsewhere,
        .anchor_id = anchor_id,
        .focus_id = focus_id,
    };
    const offset = c.scroll.get(drawn.box) orelse 0;
    const previous_offset = c.scroll_seen.get(drawn.box) orelse offset;
    const cull: Cull = .{ .on = cull_offscreen, .loose = tweening or resizing, .pad = if (tweening or resizing) 220 else 380, .view = scroll_rect, .col = col, .offset_delta = offset - previous_offset };
    // A message sent while its turn works is drawn where it arrived, and
    // what the reply gains after it under it (steer_order.zig).
    const steer = &a.view.steer;
    const steer_chat: ?u64 = if (subagent == null) (if (chat_id) |id| steer_order.hash(id) else null) else null;
    if (steer_chat) |chat| steer.observe(chat, entries_);
    const steered = if (steer_chat) |chat| steer.any(chat) else false;
    // Cold-open bottom-anchor estimation (#1496): when opening a long chat at
    // its end before rows have been measured, estimate heights from the bottom
    // up so far-offscreen historical replies stand in as spacers on frame 1.
    var cold_cutoff: usize = 0;
    if (cull.on and anchor == null and (c.scroll_follow.get(drawn.box) orelse true)) {
        if (scroll_rect) |view| {
            const budget = view.h + cull.pad * 2;
            var acc: f32 = 0;
            var idx = entries_.len;
            while (idx > 0) {
                idx -= 1;
                const ent = &entries_[idx];
                const h_est = if (ent.cached_h > 0) ent.cached_h else estimateEntryHeight(ent, col);
                acc += h_est + (if (idx > 0) @as(f32, 16) else 0);
                if (acc > budget) {
                    cold_cutoff = idx;
                    break;
                }
            }
        }
    }
    var turn_node: ?u32 = null;
    defer if (turn_node != null) c.end();
    for (entries_, 0..) |*e, i| {
        if (turn_start != null and i == turn_start.?) {
            const height = if (anchor != null and scroll_rect != null) @max(0, scroll_rect.?.h - top - st.padding.bottom) else 0;
            turn_node = c.open(.{ .direction = .column, .width = .fill, .min_height = height }, null);
            // The wrapper remains after completion so tool/detail identities
            // do not change when streaming stops or resumes.
            c.node(turn_node.?).id = std.hash.Wyhash.hash(drawn.box, e.id);
            if (anchor != null and anchor.?.pending) {
                if (scroll_rect) |viewport| if (c.rects.get(anchor.?.turn)) |r| {
                    const anchored_offset = @max(0, (c.scroll.get(drawn.box) orelse 0) + r.y - viewport.y - top);
                    c.scroll.put(c.gpa, drawn.box, anchored_offset) catch {};
                    c.scroll_seen.put(c.gpa, drawn.box, anchored_offset) catch {};
                    c.scroll_follow.put(c.gpa, drawn.box, false) catch {};
                    anchor.?.pending = false;
                    c.changed = true;
                };
                if (anchor.?.pending) c.frameIn(0);
            }
        }
        const tail = if (steered and e.role == .user) steer_order.tailAfter(steer, steer_chat.?, entries_, i) else null;
        // After its message, whether that was drawn or is off screen.
        defer if (tail) |x| steerTail(c, a, k, x, entries_, i, chat_id, cull, just_stuck, &sel_pin);
        const parts_len = e.parts.items.len;
        const head_end = if (steered and e.role == .assistant) steer_order.headEnd(steer, steer_chat.?, entries_, i) else parts_len;
        // Everything it has came after the message: nothing in its place.
        if (head_end == 0 and parts_len > 0) continue;
        // `top_gap_for`: every entry's first row opens a turn (`SPACE_LG`).
        if (i > 0) _ = c.leaf(.{ .height = .{ .px = 16 } }, .none, null);
        ui.key(c, c.print("entry-{s}-{s}", .{ chat_id orelse "", e.id }));
        const row_id = c.peekId(null);
        const row_pinned = sel_pin.isPinned(row_id);
        const can_cull = !row_pinned and (!just_stuck or i + 1 < entries_.len) and !(anchor != null and i == turn_start.?) and e.status != .streaming;
        if (can_cull and i < cold_cutoff and e.cached_h == 0 and c.rects.get(row_id) == null) {
            const est = estimateEntryHeight(e, col);
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = est } }, .none, null);
            sel_pin.noteCulled();
            continue;
        }
        if (spacer(c, cull, can_cull, &e.cached_h, &e.cached_w, &e.measured_w)) |r| {
            sel_pin.noteCulled();
            if (e.isHumanPrompt()) {
                ticks.append(c.alloc(), .{ .entry = i, .top = r.y - (if (i > 0) @as(f32, 16) else 0) }) catch {};
            }
            continue;
        }
        const row_start = c.nodes.items.len;
        var at: At = .{ .chat_id = chat_id, .entries = entries_, .index = i, .col = col, .scroll = scroll_rect };
        switch (e.role) {
            .user => {
                // Its row starts where the turn's gap does (`top_gap_for`).
                const r = user(c, a, k, e, col, chat_id);
                if (e.isHumanPrompt()) ticks.append(c.alloc(), .{ .entry = i, .top = if (r) |x| x.y - (if (i > 0) @as(f32, 16) else 0) else null }) catch {};
            },
            .assistant => if (head_end == parts_len) assistant(c, a, k, e, at) else {
                // Under the reply's own id: its rows keep what they
                // remembered when the message split it.
                at.closes = false;
                assistant(c, a, k, steerPiece(c, e, e.id, 0, head_end) orelse e, at);
            },
            .system => system(c, a, k, e, at),
        }
        sel_pin.observe(c, row_id, row_start);
    }
    const trailer_start = c.nodes.items.len;
    if (subagent == null) {
        var pending_count: usize = 0;
        if (chat_id) |id| for (a.pending_sends.items) |pending| {
            if (!@import("app_send_feedback.zig").visible(pending, id, t)) continue;
            if (entries_.len > 0 or pending_count > 0) _ = c.leaf(.{ .height = .{ .px = 16 } }, .none, null);
            ui.key(c, c.print("pending-{s}-{s}", .{ pending.chat, pending.message }));
            const entry = pending.entry();
            _ = user(c, a, k, &entry, col, chat_id);
            pending_count += 1;
        };
        @import("view_working.zig").trailer(c, a, k, chat_id, t);
    }
    if (sel_pin.scanning) {
        var trailer_hit = false;
        for (c.nodes.items[trailer_start..]) |n| {
            if (n.id == anchor_id or n.id == focus_id) {
                trailer_hit = true;
                break;
            }
        }
        if (sel_pin.saw_anchor and sel_pin.saw_focus) {
            sel_owner_mod.pin(c).* = .{
                .surface = drawn.box,
                .anchor = anchor_id,
                .focus = focus_id,
                .lo_row = sel_pin.first_row,
                .hi_row = sel_pin.last_row,
                .needs_scan = false,
                .scanned = true,
            };
            if (sel_pin.culled_between) c.changed = true;
        } else if ((sel_pin.saw_anchor or sel_pin.saw_focus) and trailer_hit) {
            sel_owner_mod.pin(c).* = .{
                .surface = drawn.box,
                .anchor = anchor_id,
                .focus = focus_id,
                .lo_row = sel_pin.first_row,
                .hi_row = 0,
                .needs_scan = false,
                .scanned = true,
            };
            if (sel_pin.saw_culled_after_first) c.changed = true;
        } else if (!sel_pin.saw_anchor and !sel_pin.saw_focus and trailer_hit) {
            sel_owner_mod.pin(c).* = .{
                .surface = drawn.box,
                .anchor = anchor_id,
                .focus = focus_id,
                .lo_row = 0,
                .hi_row = 0,
                .needs_scan = false,
                .scanned = true,
            };
        } else if (cull_offscreen) {
            const already_scanned = pin_same_surface and saved_pin.anchor == anchor_id and saved_pin.focus == focus_id and saved_pin.scanned;
            if (!already_scanned) {
                sel_owner_mod.pin(c).* = .{
                    .surface = drawn.box,
                    .anchor = anchor_id,
                    .focus = focus_id,
                    .lo_row = saved_pin.lo_row,
                    .hi_row = saved_pin.hi_row,
                    .needs_scan = true,
                    .scanned = false,
                };
                c.changed = true;
            }
        } else {
            sel_owner_mod.pin(c).* = .{
                .surface = drawn.box,
                .anchor = anchor_id,
                .focus = focus_id,
                .lo_row = 0,
                .hi_row = 0,
                .needs_scan = false,
                .scanned = true,
            };
        }
    }
    drawn.ticks = ticks.items;
    return drawn;
}

const SelectionPin = struct {
    active: bool = false,
    lo_row: u64 = 0,
    hi_row: u64 = 0,
    in_span: bool = false,
    scanning: bool = false,
    anchor_id: u64 = 0,
    focus_id: u64 = 0,
    first_row: u64 = 0,
    last_row: u64 = 0,
    saw_anchor: bool = false,
    saw_focus: bool = false,
    saw_culled_after_first: bool = false,
    culled_between: bool = false,

    fn isPinned(self: *SelectionPin, row_id: u64) bool {
        if (!self.active or self.lo_row == 0) return false;
        if (row_id == self.lo_row) self.in_span = true;
        const pinned = self.in_span;
        if (self.hi_row != 0 and row_id == self.hi_row) self.in_span = false;
        return pinned;
    }

    fn noteCulled(self: *SelectionPin) void {
        if (self.scanning and self.first_row != 0) self.saw_culled_after_first = true;
    }

    fn observe(self: *SelectionPin, c: *const ui.Context, row_id: u64, start_ix: usize) void {
        if (!self.scanning) return;
        var hit = false;
        for (c.nodes.items[start_ix..]) |n| {
            if (n.id == self.anchor_id) {
                self.saw_anchor = true;
                hit = true;
            }
            if (n.id == self.focus_id) {
                self.saw_focus = true;
                hit = true;
            }
        }
        if (hit) {
            if (self.first_row == 0) {
                self.first_row = row_id;
            } else if (self.saw_culled_after_first) {
                self.culled_between = true;
            }
            self.last_row = row_id;
        }
    }
};

/// What decides whether a row off screen is drawn or stood in for.
const Cull = struct {
    on: bool,
    /// The column is changing width: a remembered height still stands in.
    loose: bool,
    pad: f32,
    view: ?ui.Rect,
    col: f32,
    /// Rects belong to the preceding layout. Project them through this
    /// wheel delta so a large jump mounts its destination immediately.
    offset_delta: f32 = 0,
};

/// For the row keyed just before: its last rect when it is off screen and
/// a spacer of its remembered height stands in for it, else null with the
/// row still to draw. `h`, `w` and `m` are what the row remembers (an
/// entry's `cached_h`, `cached_w` and `measured_w`).
fn spacer(c: *ui.Context, cull: Cull, settled: bool, h: *f32, w: *f32, m: *f32) ?ui.Rect {
    const prev = c.rects.get(c.peekId(null));
    if (prev) |r| if (r.h > 0 and m.* > 0) {
        h.* = r.h;
        w.* = m.*;
    };
    const width_ok = cull.loose or @abs(w.* - cull.col) <= 1.0;
    if (cull.on and settled and h.* > 0 and width_ok) {
        if (cull.view) |view| if (prev) |r| {
            if (@import("motion_rules.zig").skipOffscreenRow(true, r.y - cull.offset_delta, r.y + r.h - cull.offset_delta, view.y, view.y + view.h, cull.pad)) {
                m.* = 0;
                _ = c.leaf(.{ .width = .fill, .height = .{ .px = h.* } }, .none, null);
                return r;
            }
        };
    }
    m.* = cull.col;
    return null;
}

/// A reply's parts `[start, end)` as an entry of this frame's to draw.
fn steerPiece(c: *ui.Context, e: *const tr.Entry, id: []const u8, start: usize, end: usize) ?*const tr.Entry {
    const p = c.alloc().create(tr.Entry) catch return null;
    p.* = steer_order.piece(e, id, start, end);
    return p;
}

/// Under a message sent while its turn worked: what the reply gained
/// after it, a row of its own with the gap of one.
fn steerTail(c: *ui.Context, a: *App, k: theme.Colors, t: steer_order.Tail, entries_: []tr.Entry, user_ix: usize, chat_id: ?[]const u8, cull: Cull, just_stuck: bool, sel_pin: *SelectionPin) void {
    if (t.start >= t.end) return;
    const owner = &entries_[t.owner];
    const message = entries_[user_ix].id;
    _ = c.leaf(.{ .height = .{ .px = 16 } }, .none, null);
    ui.key(c, c.print("entry-{s}-{s}-after-{s}", .{ chat_id orelse "", owner.id, message }));
    const row_id = c.peekId(null);
    const row_pinned = sel_pin.isPinned(row_id);
    const at_end = user_ix + 1 == entries_.len;
    if (spacer(c, cull, !row_pinned and (!just_stuck or !at_end) and owner.status != .streaming, &t.cut.cached_h, &t.cut.cached_w, &t.cut.measured_w) != null) {
        sel_pin.noteCulled();
        return;
    }
    const row_start = c.nodes.items.len;
    const piece = steerPiece(c, owner, c.print("{s}~{s}", .{ owner.id, message }), t.start, t.end) orelse return;
    const closes = t.end == owner.parts.items.len;
    assistant(c, a, k, piece, .{ .chat_id = chat_id, .entries = entries_, .index = t.owner, .col = cull.col, .scroll = cull.view, .closes = closes, .last = closes and at_end });
    sel_pin.observe(c, row_id, row_start);
}

/// A prompt's bubble; where it was last laid out.
fn user(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, col: f32, chat_id: ?[]const u8) ?ui.Rect {
    if (e.peer()) |message| return peerMessage(c, a, k, e, message);
    const wrap = ui.div(c).column().wFull().itemsEnd();
    defer wrap.end();
    const hovered = wrap.hovered();
    if (c.hot == c.node(wrap.index).id) c.cursor_hand = false;
    {
        const bubble = ui.div(c).column().maxW(col * 0.8).bg(k.user_bubble).rounded(16).px(16).py(10).gap(6);
        defer bubble.end();
        const st = kit.style(c, 14, 22, .{ .wrap = true, .color = k.text });
        for (e.parts.items) |*p| switch (p.kind) {
            .text => {
                const parsed = attachment_refs.parse(c.alloc(), p.text.items) catch attachment_refs.Parsed{ .text = p.text.items };
                if (parsed.text.len > 0) {
                    ui.key(c, c.print("user-text-{s}-{s}-{x}", .{ chat_id orelse "", p.id, std.hash.Wyhash.hash(0, parsed.text) }));
                    ui.text(c, parsed.text, st);
                }
                for (parsed.paths, 0..) |path, index| {
                    ui.key(c, c.print("user-attachment-{s}-{d}", .{ p.id, index }));
                    sentAttachment(c, a, k, chat_id, path);
                }
            },
            .image => attachment(c, k, .document, p.text.items),
            else => {},
        };
    }
    lane(c, a, k, e, hovered, true);
    return c.rects.get(c.node(wrap.index).id);
}

fn peerMessage(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, message: @import("peer_message.zig").Message) ?ui.Rect {
    const box = ui.div(c).column().wFull().gap(6);
    defer box.end();
    const header = ui.div(c).row().control();
    ui.text(c, c.print("Agent message · {s}", .{message.sender}), .{ .size = 11, .weight = .medium, .color = k.muted });
    header.end();
    // Coordination is not a right-aligned human prompt. Keep its body
    // selectable, while the sender label is not part of cross-message Copy.
    @import("view_markdown.zig").markdown(c, k, message.body, &a.view.copy_feedback);
    lane(c, a, k, e, box.hovered(), false);
    return c.rects.get(c.node(box.index).id);
}

fn sentAttachment(c: *ui.Context, a: *App, k: theme.Colors, chat_id: ?[]const u8, path: []const u8) void {
    const tiles = @import("view_composer_attachments.zig");
    const name = @import("app_attachments.zig").displayName(path);
    const image = attachment_images.get(a, chat_id, path);
    const bytes: []const u8 = if (image) |loaded| attachment_images.tileBytes(loaded) else "";
    const tile = ui.div(c).column().w(56).gap(2).control();
    defer tile.end();
    {
        const thumb = ui.div(c).row().size(56, 56).center().rounded(8).border(k.border).bg(k.hover).clip();
        defer thumb.end();
        tiles.picture(c, k, c.print("{s}:{s}", .{ chat_id orelse "", path }), name, bytes);
        if (image) |loaded| if (loaded.status == .ready) {
            const leaf = c.nodes.items.len - 1;
            if (c.nodes.items[leaf].content == .image) {
                const picture = @import("preview_focus.zig").action(c, @intCast(leaf), k, c.print("Open image preview: {s}", .{name}));
                if (picture or thumb.clicked()) {
                    c.focus = c.node(@intCast(leaf)).id;
                    @import("view_image_preview.zig").open(a, chat_id, loaded);
                }
            }
        };
    }
    kit.ellipsisText(c, name, .{ .size = 10, .line_height = 12, .color = k.muted }, 56);
}

/// `format_timestamp`: "Jul 1, 3:45 PM", `offset_s` from UTC.
pub fn formatTimestamp(buf: []u8, ms: i64, offset_s: i64) []const u8 {
    const accounts = @import("accounts.zig");
    const at = ms + offset_s * 1000;
    const day = accounts.monthDay(@divFloor(at, 86_400_000));
    const in_day = @mod(at, 86_400_000);
    const h = @divFloor(in_day, 3_600_000);
    const m = @divFloor(@mod(in_day, 3_600_000), 60_000);
    const h12: u64 = @intCast(if (@mod(h, 12) == 0) 12 else @mod(h, 12));
    return std.fmt.bufPrint(buf, "{s} {d}, {d}:{d:0>2} {s}", .{ accounts.month_names[day.month - 1], day.day, h12, @as(u64, @intCast(m)), if (h < 12) "AM" else "PM" }) catch "";
}

test "a message's timestamp reads as the GPUI app's" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Jan 1, 12:00 AM", formatTimestamp(&b, 0, 0));
    // 2026-07-01 15:45 UTC.
    try std.testing.expectEqualStrings("Jul 1, 3:45 PM", formatTimestamp(&b, 1782920700000, 0));
    try std.testing.expectEqualStrings("Jul 1, 11:45 PM", formatTimestamp(&b, 1782920700000, 8 * 3600));
    try std.testing.expectEqualStrings("Jul 2, 12:05 AM", formatTimestamp(&b, 1782920700000 + 20 * 60_000, 8 * 3600));
}

/// Whether the pointer is in the padding the last row carries under it: the
/// clearance that takes it down behind the composer, which nothing there
/// occludes (`bottom_pad`). A menu or the picker over it does.
fn underLastRow(c: *ui.Context, a: *const App, row: ?ui.Rect, scroll: ?ui.Rect) bool {
    const r = row orelse return false;
    const pane = scroll orelse return false;
    const m = c.input.mouse;
    if (@import("view.zig").menuKeepsKeys(a) or a.view.account_menu) return false;
    return m.x >= pane.x and m.x < pane.x + pane.w and m.y >= r.y + r.h and m.y < c.size.h;
}

/// Under a message: 32 points held for its time and copy button, shown on
/// hover (`strip`).
fn lane(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, hovered: bool, right: bool) void {
    var l = ui.div(c).row().wFull().h(32).pt(8).gap(8).itemsCenter().control();
    if (right) l = l.justifyEnd();
    defer l.end();
    if (!hovered) return;
    if (e.created_ms != 0) {
        const buf = c.alloc().alloc(u8, 32) catch return;
        ui.text(c, formatTimestamp(buf, e.created_ms, @import("accounts.zig").localOffset(e.created_ms)), .{ .size = 12, .line_height = 12 * 1.618, .color = k.muted.alpha(0.55) });
    }
    if (kit.copyButton(c, k, &a.view.copy_feedback, .{ .size = 24, .radius = 6, .icon = 14 })) {
        var text: std.ArrayList(u8) = .empty;
        for (e.parts.items) |*p| if (p.kind == .text) {
            if (text.items.len > 0) text.appendSlice(c.alloc(), "\n\n") catch {};
            text.appendSlice(c.alloc(), p.text.items) catch {};
        };
        c.clipboard.write(c.clipboard.ctx, text.items);
    }
}

/// Where an entry is: its chat, its place among the entries, the column.
const At = struct {
    chat_id: ?[]const u8,
    entries: []const tr.Entry,
    index: usize,
    col: f32,
    /// The scroll box as last laid out.
    scroll: ?ui.Rect = null,
    /// Whether the row ends its reply. One split by a message sent while
    /// it worked (steer_order.zig) ends in the piece under the last such
    /// message: only that piece has the answer's heading and the lane.
    closes: bool = true,
    /// The transcript's last row, though its entry isn't the last one.
    last: bool = false,
};

fn assistant(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At) void {
    const last = at.last or at.index + 1 == at.entries.len;
    const col = ui.div(c).column().wFull();
    defer col.end();
    const hovered = col.hovered() or (last and underLastRow(c, a, c.rects.get(c.node(col.index).id), at.scroll));
    if (c.hot == c.node(col.index).id) c.cursor_hand = false;
    // Its parts 12 apart; the lane right under the last (the row's
    // `strip`, with no gap of its own).
    const parts_box = ui.div(c).column().wFull().gap(12);
    const answer: Answer = .{ .part = if (!at.closes) null else if (compact.finalAnswerPart(e)) |i| &e.parts.items[i] else null };
    if (a.settings.get(.transcript_compact_mode))
        compactParts(c, a, k, e, at, answer)
    else
        partRows(c, a, k, e, e.parts.items, at, last, answer);
    if (e.status == .streaming and e.parts.items.len == 0) ui.text(c, "Working…", .{ .size = 12, .color = k.muted });
    parts_box.end();
    if (e.status != .streaming and at.closes) lane(c, a, k, e, hovered, false);
}

/// The part a finished reply's answer starts at, which a divider heads,
/// and whether the divider says how long the turn worked (compact mode's
/// work line already does).
const Answer = struct {
    part: ?*const tr.Part,
    label: bool = true,
};

/// Parts as rows: tool calls and reasoning folded into groups, the rest
/// one row each. `auto` lets a streaming reply's tail group open itself.
fn partRows(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, parts: []const tr.Part, at: At, auto: bool, answer: Answer) void {
    const buf = c.alloc().alloc(tools.Run, parts.len) catch {
        ui.text(c, "Unable to render reply: out of memory", .{ .size = 12, .color = k.danger });
        return;
    };
    const runs = tools.runs(buf, parts);
    const chat = if (at.chat_id) |cid| a.findChat(cid) else null;
    const cwd = if (chat) |ch| ch.cwd else null;
    const ba_on = a.settings.get(.design_before_after_enabled);
    var skip: usize = 0;
    for (runs, 0..) |r, ri| {
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        const p = &parts[r.start];
        ui.key(c, c.print("run-{s}-{s}", .{ e.id, p.id }));
        if (r.group) {
            // ACP often creates its answer placeholder before its first
            // text chunk. An empty placeholder must not hide live work.
            const tail = e.status == .streaming and auto and for (parts[r.end..]) |next| {
                if (next.kind != .text or std.mem.trim(u8, next.text.items, " \t\r\n").len > 0) break false;
            } else true;
            group(c, a, k, e, parts[r.start..r.end], tail, at.chat_id);
            continue;
        }
        if (p.kind == .image and ba_on and ri + 1 < runs.len) {
            const nr = runs[ri + 1];
            if (!nr.group) {
                const np = &parts[nr.start];
                if (np.kind == .image) {
                    if (before_after.matchPair(p.text.items, np.text.items)) |caption| {
                        before_after.drawPair(c, a, k, at.chat_id, before_after.cardId(at.chat_id, e.id, p.id, np.id), p.path, p.text.items, np.path, np.text.items, caption, at.col);
                        skip = 1;
                        continue;
                    }
                }
            }
        }
        if (p.kind == .image and reply_images.resolve(c.alloc(), cwd, p.path) != null) {
            var items_buf: [image_gallery.max_items]image_gallery.Item = undefined;
            var n: usize = 0;
            var j = ri;
            while (j < runs.len and n < image_gallery.max_items) : (j += 1) {
                if (runs[j].group) break;
                const cand = &parts[runs[j].start];
                if (cand.kind != .image) break;
                if (reply_images.resolve(c.alloc(), cwd, cand.path) == null) break;
                if (j > ri and ba_on and j + 1 < runs.len and !runs[j + 1].group) {
                    const next_cand = &parts[runs[j + 1].start];
                    if (next_cand.kind == .image and before_after.matchPair(cand.text.items, next_cand.text.items) != null) break;
                }
                items_buf[n] = .{ .path = cand.path, .caption = cand.text.items };
                n += 1;
            }
            if (n >= 2) {
                image_gallery.draw(c, a, k, at.chat_id, image_gallery.cardId(at.chat_id, e.id, p.id, n), items_buf[0..n], at.col);
                skip = n - 1;
                continue;
            }
        }
        part(c, a, k, e, p, at, answer);
    }
}

pub fn streamMarkdown(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, chat_id: ?[]const u8) void {
    const state = @import("tool_ui_state.zig");
    const part_id = state.key(chat_id, e.id, p.id);
    const live = e.status == .streaming;
    const use_veil = !a.offscreen and !c.reduced_motion and (live or a.view.tool_ui.veils.isFading(part_id));
    const row_veil = if (use_veil)
        a.view.tool_ui.veils.getOrCreate(a.gpa, part_id, live and p.text.items.len > 64, c.time * 1000.0)
    else
        null;
    const markdown = @import("view_markdown.zig");
    if (e.role == .assistant and e.status == .complete and p.kind == .text) {
        markdown.withCommandBlocks(c, k, p.text.items, a, chat_id, row_veil);
    } else {
        markdown.withLinksVeil(c, k, p.text.items, a, chat_id, row_veil, live and !a.offscreen);
    }
    if (!live and row_veil != null) {
        a.view.tool_ui.veils.pruneSettled(a.gpa, part_id);
    }
}

fn part(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, at: At, answer: Answer) void {
    switch (p.kind) {
        .text => {
            if (answer.part == p) {
                const box = ui.div(c).column().wFull();
                defer box.end();
                answerHeading(c, k, e, answer.label);
                streamMarkdown(c, a, k, e, p, at.chat_id);
            } else streamMarkdown(c, a, k, e, p, at.chat_id);
        },
        .tool => treeRow(c, a, k, e, p, true, at.chat_id),
        .@"error" => errorPart(c, a, k, e, p, at),
        .image => @import("view_reply_images.zig").draw(c, a, k, at.chat_id, p.path, p.text.items, null),
        .visual => @import("view_visual.zig").draw(c, a, k, e, p),
        .artifact => @import("view_artifact.zig").draw(c, a, k, e, p),
        .delegation => attachment(c, k, .widget, "Delegated to a subagent"),
        .input => {
            // The stored part still records the request for history and sync;
            // a resolved question is no longer an actionable transcript chip.
            if (p.resolved) return;
            const q = if (p.questions.len > 0) p.questions[0] else null;
            const label = if (q) |x| (if (x.question.len > 0) x.question else x.header) else "Question";
            @import("view_question.zig").chip(c, k, label, p.resolved, at.col);
        },
        else => {},
    }
}

/// Above a finished reply's answer (GPUI's `final_answer` heading): a thin
/// divider, 12 points over the answer, under a muted "Worked for …" (or
/// "Final answer") unless compact mode's work line already says it.
fn answerHeading(c: *ui.Context, k: theme.Colors, e: *const tr.Entry, label: bool) void {
    const h = ui.div(c).column().wFull().pb(12).control();
    defer h.end();
    if (label) {
        const l = ui.div(c).row().wFull().pt(8).pb(12);
        defer l.end();
        var buf: [48]u8 = undefined;
        const text = if (compact.workedSecs(e)) |s| compact.workedFor(&buf, s) else "Final answer";
        ui.text(c, c.print("{s}", .{text}), kit.style(c, 13, 18, .{ .color = k.muted }));
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
}

/// Compact mode (GPUI's `compact_shell`): the turn's thinking, tool calls
/// and the narration between them stay visible while the turn runs, then
/// fold behind one line. Finished work can be opened again. Saved views
/// stay rows after it; questions, errors and
/// the reply keep their places.
fn compactParts(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At, answer_in: Answer) void {
    const items = e.parts.items;
    const reply = compact.replyStart(items, e.status == .streaming);
    var work: std.ArrayList(tr.Part) = .empty;
    var views: std.ArrayList(tr.Part) = .empty;
    var first: ?usize = null;
    for (items, 0..) |*p, i| if (compact.isWork(i, p, reply)) {
        if (first == null) first = i;
        // Read-only copies: the rows draw from them this frame only.
        (if (compact.isView(p)) &views else &work).append(c.alloc(), p.*) catch return;
    };
    var answer = answer_in;
    answer.label = work.items.len == 0;
    const chat = if (at.chat_id) |cid| a.findChat(cid) else null;
    const cwd = if (chat) |ch| ch.cwd else null;
    const ba_on = a.settings.get(.design_before_after_enabled);
    var skip: usize = 0;
    for (items, 0..) |*p, i| {
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        if (compact.isWork(i, p, reply)) {
            if (i != first.?) continue;
            if (work.items.len > 0) {
                ui.key(c, c.print("work-{s}", .{e.id}));
                workLine(c, a, k, e, work.items, at);
            }
            if (views.items.len > 0) partRows(c, a, k, e, views.items, at, false, answer);
            continue;
        }
        ui.key(c, c.print("part-{s}-{s}", .{ e.id, p.id }));
        if (p.kind == .image and ba_on and i + 1 < items.len) {
            const np = &items[i + 1];
            if (!compact.isWork(i + 1, np, reply) and np.kind == .image) {
                if (before_after.matchPair(p.text.items, np.text.items)) |caption| {
                    before_after.drawPair(c, a, k, at.chat_id, before_after.cardId(at.chat_id, e.id, p.id, np.id), p.path, p.text.items, np.path, np.text.items, caption, at.col);
                    skip = 1;
                    continue;
                }
            }
        }
        if (p.kind == .image and reply_images.resolve(c.alloc(), cwd, p.path) != null) {
            var items_buf: [image_gallery.max_items]image_gallery.Item = undefined;
            var n: usize = 0;
            var j = i;
            while (j < items.len and n < image_gallery.max_items) : (j += 1) {
                const cand = &items[j];
                if (compact.isWork(j, cand, reply) or cand.kind != .image) break;
                if (reply_images.resolve(c.alloc(), cwd, cand.path) == null) break;
                if (j > i and ba_on and j + 1 < items.len and !compact.isWork(j + 1, &items[j + 1], reply)) {
                    const next_cand = &items[j + 1];
                    if (next_cand.kind == .image and before_after.matchPair(cand.text.items, next_cand.text.items) != null) break;
                }
                items_buf[n] = .{ .path = cand.path, .caption = cand.text.items };
                n += 1;
            }
            if (n >= 2) {
                image_gallery.draw(c, a, k, at.chat_id, image_gallery.cardId(at.chat_id, e.id, p.id, n), items_buf[0..n], at.col);
                skip = n - 1;
                continue;
            }
        }
        part(c, a, k, e, p, at, answer);
    }
}

/// The compact work line: a group's header that says what's running while
/// the turn works, then "Worked for …" once it has.
fn workLine(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, work: []const tr.Part, at: At) void {
    const legacy = c.print("{s}#work", .{e.id});
    const key = c.print("{s}/{s}", .{ at.chat_id orelse "", legacy });
    const live = e.status == .streaming;
    const live_key = c.print("{s}/live", .{key});
    const settled_key = c.print("{s}/settled", .{key});
    // A resumed turn starts a fresh live phase. Choices made while running
    // must not pin the completed work open; reopening it afterwards is local
    // to the settled phase. Legacy keys still work for loaded history.
    if (live) {
        for ([_][]const u8{ key, legacy, settled_key }) |old_key| {
            if (a.view.groups.fetchRemove(old_key)) |kv| a.gpa.free(kv.key);
        }
    } else {
        if (a.view.groups.fetchRemove(live_key)) |kv| a.gpa.free(kv.key);
    }
    const override = if (live) live_key else settled_key;
    const default_open = compact.defaultWorkOpen(e.parts.items, live);
    const open = a.view.groups.get(override) orelse if (live) true else (a.view.groups.get(key) orelse a.view.groups.get(legacy) orelse default_open);
    const box = ui.div(c).column().wFull();
    defer box.end();
    {
        const h = kit.pressFeedback(ui.div(c).row().wFull().h(26).gap(6).pr(4).itemsCenter().rounded(4).clip().control().hover(k.wash(0.04)));
        defer h.end();
        if (h.clicked()) a.view.toggleGroup(a.gpa, override, open);
        const slot = ui.div(c).row().size(22, 18).center();
        @import("view_tool_rows.zig").chevron(c, k, open, 14);
        slot.end();
        const max_title_w = @import("motion_rules.zig").toolGroupTitleCap(at.col, 28, 8);
        const title_slot = ui.div(c).row().grow().w(0).clip();
        defer title_slot.end();
        const st = kit.style(c, 15, 18, .{ .color = if (h.hovered()) k.text else k.muted });
        const settled = if (e.status != .streaming) compact.workedSecs(e) else null;
        if (settled) |s| {
            const lb = c.alloc().alloc(u8, 48) catch return;
            kit.fadeText(c, compact.workedFor(lb, s), st, max_title_w);
        } else {
            const lb = c.alloc().alloc(u8, 160) catch return;
            // Thinking belongs to the piece the reply is still writing.
            const active = e.status == .streaming and for (work) |p| {
                if ((p.kind == .reasoning and at.closes) or (p.kind == .tool and !p.resolved)) break true;
            } else false;
            @import("view_tool_rows.zig").title(c, k, workLabel(c, lb, work), work, active, h.hovered(), max_title_w);
        }
    }
    const state = @import("tool_ui_state.zig");
    const fold_id = state.key(at.chat_id, key, "compact-fold");
    const estimate = 12 + @as(f32, @floatFromInt(work.len)) * 32;
    const fold = a.view.tool_ui.fold(a.gpa, fold_id, open, if (a.view.tool_ui.folds.contains(fold_id)) 0 else estimate, c.time, c.reduced_motion);
    const is_animating = fold.animating(c.time, c.reduced_motion);
    if (!open and !is_animating) return;
    var viewport = ui.div(c).column().wFull().clip();
    if (is_animating and fold.natural > 0) viewport = viewport.h(fold.height(c.time, c.reduced_motion));
    defer viewport.end();
    const body = ui.div(c).column().wFull().pt(8).gap(12);
    defer body.end();
    @import("view_tool_tree.zig").rememberHeight(c, a, fold_id, body.index);
    if (is_animating) c.animationFrame();
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    workRows(c, a, k, e, work, at);
}

fn workLabel(c: *ui.Context, lb: []u8, work: []const tr.Part) []const u8 {
    var has_tools = false;
    for (work) |p| if (p.kind == .tool) {
        has_tools = true;
        break;
    };
    if (!has_tools) return tools.label(lb, work);
    var filtered = std.ArrayList(tr.Part).empty;
    for (work) |p| if (p.kind == .tool) {
        filtered.append(c.alloc(), p) catch return tools.label(lb, work);
    };
    return tools.label(lb, filtered.items);
}

fn workRows(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, work: []const tr.Part, at: At) void {
    const buf = c.alloc().alloc(tools.Run, work.len) catch {
        ui.text(c, "Unable to render reply: out of memory", .{ .size = 12, .color = k.danger });
        return;
    };
    const runs = tools.runs(buf, work);
    var tool_run_count: usize = 0;
    var has_non_reasoning = false;
    for (work) |p| {
        if (p.kind != .reasoning) has_non_reasoning = true;
    }
    for (runs) |r| {
        if (!r.group) continue;
        for (work[r.start..r.end]) |p| {
            if (p.kind == .tool) {
                tool_run_count += 1;
                break;
            }
        }
    }
    for (runs) |r| {
        const p = &work[r.start];
        ui.key(c, c.print("run-{s}-{s}", .{ e.id, p.id }));
        if (!r.group) {
            part(c, a, k, e, p, at, .{ .part = null });
            continue;
        }
        var tool_parts = std.ArrayList(tr.Part).empty;
        for (work[r.start..r.end]) |item| {
            if (item.kind == .tool) tool_parts.append(c.alloc(), item) catch return;
        }
        if (tool_parts.items.len == 0) {
            if (!has_non_reasoning) {
                const thoughts = ui.div(c).column().wFull().pl(28).gap(6);
                defer thoughts.end();
                for (work[r.start..r.end]) |*tp| {
                    if (tp.kind == .reasoning and tp.text.items.len > 0) {
                        streamMarkdown(c, a, k, e, tp, at.chat_id);
                    }
                }
            }
            continue;
        }
        if (e.status == .streaming and tool_run_count == 1) {
            for (tool_parts.items, 0..) |*tp, idx| {
                ui.key(c, c.print("work-tool-{s}-{s}", .{ e.id, tp.id }));
                treeRow(c, a, k, e, tp, idx + 1 == tool_parts.items.len, at.chat_id);
            }
        } else {
            group(c, a, k, e, tool_parts.items, false, at.chat_id);
        }
    }
}

/// The current desktop renders expanded results in the task tree itself.
fn group(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, parts: []const tr.Part, tail: bool, parent: ?[]const u8) void {
    @import("view_tool_tree.zig").group(c, a, k, e, parts, tail, parent);
}

fn treeRow(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, last: bool, parent: ?[]const u8) void {
    @import("view_tool_tree.zig").row(c, a, k, e, p, last, parent);
}

/// An opened edit: its hunks as the Changes pane draws them, numbers,
/// markers and syntax colors (`ToolDetail::Diff`).
pub fn editDiff(c: *ui.Context, k: theme.Colors, p: *const tr.Part, new: []const u8) void {
    const f = @import("tool_diff.zig").file(c.alloc(), p.path, p.diff_old, new) catch return;
    if (f.hunks.len == 0) return;
    ui.key(c, c.print("edit-diff-{s}", .{p.id}));
    const box = ui.div(c).column().wFull().py(4).clip();
    defer box.end();
    @import("view_diffs.zig").body(c, k, &f);
}

/// A thinned edit's files, one row each: its icon, path and counts
/// (`ToolDetail::Stats`).
pub fn statRows(c: *ui.Context, k: theme.Colors, stats: []const tr.Stat) void {
    const box = ui.div(c).column().wFull().py(4);
    defer box.end();
    const mono: ui.TextStyle = .{ .size = 12, .mono = true, .color = k.faint };
    for (stats) |s| {
        const r = ui.div(c).row().wFull().h(18).gap(8).itemsCenter();
        defer r.end();
        file_icons.icon(c, s.path, false, k.dark, 14);
        {
            const path = ui.div(c).row().grow().w(0).clip();
            defer path.end();
            ui.text(c, s.path, mono);
        }
        var st = mono;
        st.color = k.success;
        ui.text(c, c.print("+{d}", .{s.additions}), st);
        st.color = k.danger;
        ui.text(c, c.print("−{d}", .{s.deletions}), st);
    }
}

fn toolIcon(p: *const tr.Part) icons.Name {
    return @import("view_tool_tree.zig").toolIcon(p);
}

test "tool rows use the GPUI transcript's original Harness SVGs" {
    const cases = .{
        .{ tr.ToolKind.exec, icons.Name.terminal },
        .{ tr.ToolKind.readFile, icons.Name.document },
        .{ tr.ToolKind.applyPatch, icons.Name.document },
        .{ tr.ToolKind.writeFile, icons.Name.@"document-add" },
        .{ tr.ToolKind.editFile, icons.Name.pen },
        .{ tr.ToolKind.search, icons.Name.magnifer },
        .{ tr.ToolKind.glob, icons.Name.@"folder-with-files" },
        .{ tr.ToolKind.webFetch, icons.Name.global },
        .{ tr.ToolKind.webSearch, icons.Name.global },
        .{ tr.ToolKind.todo, icons.Name.checklist },
        .{ tr.ToolKind.mcp, icons.Name.widget },
    };
    inline for (cases) |case| {
        const p: tr.Part = .{ .id = &.{}, .kind = .tool, .tool = case[0] };
        try std.testing.expectEqual(case[1], toolIcon(&p));
    }
    for ([_][]const u8{ "Agent", "Waiting on" }) |label| {
        for ([_]tr.ToolKind{ .unknown, .mcp }) |kind| {
            const p: tr.Part = .{ .id = &.{}, .kind = .tool, .tool = kind, .chip = label };
            try std.testing.expectEqual(icons.Name.bot, toolIcon(&p));
        }
    }
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn limitLines(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    for (s, 0..) |ch, i| if (ch == '\n') {
        count += 1;
        if (count == n) return s[0..i];
    };
    return s;
}

/// An error part: a typed sign-in error's reconnect card, else the chip.
fn errorPart(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, at: At) void {
    const row_id = c.print("{s}#{s}", .{ e.id, p.id });
    // Harness-generated; the chip is one line.
    const message = singleLine(c, p.text.items);
    const provider = p.reauth orelse return errorChip(c, a, k, at.chat_id, message);
    // The chat moved on: a person's message after this error.
    const later = for (at.entries[at.index + 1 ..]) |x| {
        if (x.role == .user) break true;
    } else false;
    @import("view_reauth.zig").card(c, a, k, .{ .chat_id = at.chat_id, .row_id = row_id, .message = message, .provider = provider, .later_activity = later, .col = at.col });
}

/// `single_line`: every run of whitespace as one space, none at the ends.
fn singleLine(c: *ui.Context, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n\x0b\x0c");
    while (it.next()) |w| {
        if (out.items.len > 0) out.append(c.alloc(), ' ') catch return s;
        out.appendSlice(c.alloc(), w) catch return s;
    }
    return out.items;
}

/// `notice_chip` with its tile (notice.rs): the danger triangle, `label`,
/// Copy, then the message wrapped. The caller adds what goes under it and
/// ends it.
pub fn noticeChip(c: *ui.Context, feedback: *kit.CopyFeedback, k: theme.Colors, label: []const u8, message: []const u8) ui.Div {
    return messageChip(c, feedback, k, label, message, false);
}

fn messageChip(c: *ui.Context, feedback: *kit.CopyFeedback, k: theme.Colors, label: []const u8, message: []const u8, calm: bool) ui.Div {
    const tone = if (calm) k.muted else k.danger;
    const ink = if (calm) k.muted else k.danger_muted;
    // GPUI's edge insets what's inside it; here it's drawn over the box.
    const chip = ui.div(c).column().wFull().rounded(10).px(10 + 1).py(8 + 1).gap(6).border(tone.alpha(0.16)).borderW(1).bg(tone.alpha(0.05));
    {
        const h = ui.div(c).row().wFull().gap(8).itemsCenter().control();
        defer h.end();
        const tile = ui.div(c).row().size(20, 20).center().rounded(6).bg(tone.alpha(0.12));
        icons.icon(c, if (calm) .restart else .@"danger-triangle", 12, ink.alpha(0.8), 0);
        tile.end();
        ui.text(c, label, .{ .size = 12, .weight = .medium, .color = ink.alpha(0.8) });
        ui.spacer(c);
        var copy_colors = k;
        copy_colors.hover = tone.alpha(0.12);
        if (kit.copyButton(c, copy_colors, feedback, .{ .size = 20, .icon = 12, .color = ink.alpha(0.8) })) c.clipboard.write(c.clipboard.ctx, message);
    }
    // GPUI's line height (phi), as the GPUI renderer draws the chip.
    ui.text(c, message, rows_st(c, 12, .{ .wrap = true, .color = k.text.alpha(0.8) }));
    return chip;
}

/// `error_chip`: the message wraps; a refusal the provider account fixes says
/// so in the label, and with a chat to route it carries its button under the
/// message: "Log in" (`sign_in_for_chat`) or "Update key" (`update_key_for_chat`).
fn errorChip(c: *ui.Context, a: *App, k: theme.Colors, chat_id: ?[]const u8, message: []const u8) void {
    const run_errors = @import("run_errors.zig");
    // The ChatGPT plan's own limit has its plan-usage card in the GPUI app,
    // never "Log in".
    const notice = run_errors.restartNotice(message);
    const problem = if (notice != null or run_errors.isPlanUsageLimit(message)) null else run_errors.providerProblem(message);
    const outer = ui.div(c).column().wFull().py(4);
    defer outer.end();
    const chip = messageChip(c, &a.view.copy_feedback, k, if (notice) |n| n.label() else if (problem) |p| p.label() else "Error", message, notice != null);
    defer chip.end();
    const p = problem orelse return;
    const id = chat_id orelse return;
    const r = ui.div(c).row().pt(2).control();
    defer r.end();
    // `btn_primary` at px(10) py(5) rounded(7), 12 points.
    const b = ui.div(c).row().px(10).py(5).rounded(7).bg(k.solid);
    defer b.end();
    ui.text(c, p.actionLabel(), rows_st(c, 12, .{ .weight = .medium, .color = k.on_solid }));
    if (b.clicked()) switch (p) {
        .key_rejected => @import("app_reauth.zig").updateKeyForChat(a, id),
        else => @import("app_reauth.zig").signInForChat(a, id),
    };
}

fn attachment(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8) void {
    const row = ui.div(c).row().gap(6).itemsCenter().control();
    defer row.end();
    icons.icon(c, icon, 14, k.muted, 0);
    ui.text(c, label, .{ .size = 12, .color = k.muted });
}

fn system(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At) void {
    const col = ui.div(c).column().wFull();
    defer col.end();
    for (e.parts.items) |*p| switch (p.kind) {
        .text => ui.text(c, p.text.items, kit.style(c, 12, 18, .{ .wrap = true, .color = k.faint })),
        .@"error" => errorPart(c, a, k, e, p, at),
        else => {},
    };
}

/// Content-based height estimate for an unmeasured transcript row (mirroring
/// Zeron's `ROW_ESTIMATE` in #1496) so cold chat opens at the bottom don't
/// build and discard dozens of offscreen long replies on frame 1.
pub fn estimateEntryHeight(e: *const tr.Entry, col_w: f32) f32 {
    const eff_w = @max(180, @min(col_w, column_w));
    const chars_per_line = @max(20.0, eff_w / 7.8);
    switch (e.role) {
        .user => {
            var h: f32 = 44;
            const bubble_cpl = @max(18.0, @min(eff_w * 0.78, 520.0) / 7.8);
            for (e.parts.items) |*p| switch (p.kind) {
                .text => h += estimateMarkdownHeight(p.text.items, bubble_cpl, 22.5, false),
                .image => h += 96,
                else => {},
            };
            return @max(56, h);
        },
        .assistant => {
            var h: f32 = 36;
            var in_tools = false;
            for (e.parts.items) |*p| switch (p.kind) {
                .text => {
                    in_tools = false;
                    h += 12 + estimateMarkdownHeight(p.text.items, chars_per_line, 22.5, true);
                },
                .tool, .delegation => {
                    if (!in_tools) {
                        h += 38;
                        in_tools = true;
                    }
                },
                .reasoning => {
                    in_tools = false;
                    h += 34;
                },
                .image, .visual => {
                    in_tools = false;
                    h += 240;
                },
                .artifact => {
                    in_tools = false;
                    h += 88;
                },
                .input => {
                    in_tools = false;
                    if (!p.resolved) h += 42;
                },
                .@"error" => {
                    in_tools = false;
                    h += 48;
                },
                else => {},
            };
            return @max(48, h);
        },
        .system => return 40,
    }
}

fn estimateMarkdownHeight(text: []const u8, chars_per_line: f32, line_h: f32, rich_md: bool) f32 {
    if (text.len == 0) return line_h;
    var h: f32 = 0;
    var in_code = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (rich_md and std.mem.startsWith(u8, line, "```")) {
            in_code = !in_code;
            h += if (in_code) 40 else 12;
            continue;
        }
        if (in_code) {
            h += 18;
            continue;
        }
        if (line.len == 0) {
            h += 12;
            continue;
        }
        if (rich_md and line[0] == '|') {
            h += 34;
            continue;
        }
        if (rich_md and line[0] == '#') {
            h += 30;
            continue;
        }
        const wrapped = @max(1.0, @ceil(@as(f32, @floatFromInt(line.len)) / chars_per_line));
        h += wrapped * line_h;
    }
    return @max(line_h, h);
}

test "estimateEntryHeight scales with user text, markdown code/tables, and folded tool groups" {
    const testing = std.testing;
    var short_user: tr.Entry = .{ .id = @constCast("u1"), .role = .user, .status = .complete };
    var p1: tr.Part = .{ .id = @constCast("p1"), .kind = .text };
    try p1.text.appendSlice(testing.allocator, "Hi");
    defer p1.text.deinit(testing.allocator);
    try short_user.parts.append(testing.allocator, p1);
    defer short_user.parts.deinit(testing.allocator);

    var long_assistant: tr.Entry = .{ .id = @constCast("a1"), .role = .assistant, .status = .complete };
    var p2: tr.Part = .{ .id = @constCast("p2"), .kind = .text };
    try p2.text.appendSlice(testing.allocator,
        \\## Summary
        \\
        \\Here is a detailed reply with a fenced code block and a markdown table:
        \\
        \\```zig
        \\pub fn example() void {
        \\    const a = 1;
        \\    const b = 2;
        \\    _ = a + b;
        \\}
        \\```
        \\
        \\| Col A | Col B |
        \\| --- | --- |
        \\| Row 1 | Value 1 |
        \\| Row 2 | Value 2 |
    );
    defer p2.text.deinit(testing.allocator);
    try long_assistant.parts.append(testing.allocator, p2);
    for (0..4) |_| try long_assistant.parts.append(testing.allocator, .{ .id = @constCast("t"), .kind = .tool });
    defer long_assistant.parts.deinit(testing.allocator);

    const h_short = estimateEntryHeight(&short_user, 680);
    const h_long = estimateEntryHeight(&long_assistant, 680);
    try testing.expect(h_short >= 56 and h_short < 120);
    try testing.expect(h_long > 320);
}
