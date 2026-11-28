//! The queue tray over the composer (crates/ui/src/queue.rs): a surface
//! above (never behind) the input. Rows wrap their actions in narrow panes
//! instead of clipping them: Edit, Steer and Remove precede "Send now". Narrow
//! rows show only action icons; the row being edited reads "Editing in composer"
//! with "Save to queue" and "Cancel" when there is room.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const queue = @import("queue.zig");
const App = @import("app.zig").App;

/// Visible separation between the queue surface and the composer.
pub const gap: f32 = 8;
const row_height: f32 = 36;

pub const RowLayout = struct {
    stacked: bool,
    columns: usize,
    button_width: f32,
    fit_width: f32,
};

/// Reserve the tray's border/padding and row gutters before allocating
/// actions; when text and actions no longer fit, put actions on rows of
/// their own. Rows have no drag handle: the queue has no reordering.
pub fn rowLayout(width: f32, actions: usize) RowLayout {
    const available = @max(0, width - 26);
    const count = @max(1, actions);
    const action_width = @as(f32, @floatFromInt(count)) * 28 + @as(f32, @floatFromInt(count - 1)) * 4;
    const columns = @min(count, @max(1, @as(usize, @intFromFloat(@floor((available + 4) / 32)))));
    const button_width = @min(28, available);
    return .{
        .stacked = available < action_width + 4 + 32,
        .columns = columns,
        .button_width = button_width,
        .fit_width = @min(@max(0, width), @as(f32, @floatFromInt(columns)) * button_width + @as(f32, @floatFromInt(columns - 1)) * 4 + 26),
    };
}

test "composer dock queue layout wraps priority actions only when they no longer fit" {
    const narrow = rowLayout(108, 4);
    try std.testing.expect(narrow.stacked);
    try std.testing.expectEqual(@as(usize, 2), narrow.columns);
    try std.testing.expectEqual(@as(f32, 86), narrow.fit_width);
    try std.testing.expectEqual(@as(usize, 3), rowLayout(148, 4).columns);
    try std.testing.expectEqual(@as(f32, 118), rowLayout(148, 4).fit_width);
    try std.testing.expectEqual(@as(f32, 86), rowLayout(488, 2).fit_width);
    try std.testing.expect(!rowLayout(188, 4).stacked);
}

pub fn tray(c: *ui.Context, a: *App, k: theme.Colors, w: f32) bool {
    if (a.queue.items.len == 0) return false;
    const compact = w < 520;
    var width: f32 = 0;
    for (a.queue.items) |r| {
        const editing = if (a.queue_edit) |e| std.mem.eql(u8, e.row, r.id) else false;
        const can_steer = @import("app_queue.zig").rowCanSteer(a, r);
        const layout = rowLayout(w, if (editing) 2 else 2 + @as(usize, @intFromBool(!r.agent)) + @as(usize, @intFromBool(can_steer)));
        // The composer width is a ceiling, not a target for an icon grid.
        width = @max(width, if (compact and layout.stacked) layout.fit_width else @max(0, w));
    }
    const box = ui.div(c).column().w(width).bg(k.composer).border(k.border).borderW(1).rounded(16).pb(8).pt(4).px(4);
    defer box.end();
    // Reuse PR #844's row-only scroll-region approach: surface decoration
    // cannot consume scroll range or hide the last row underneath the input.
    const pane_h = @import("view_transcript.zig").paneHeight(c, a) orelse c.size.h;
    const rows = ui.div(c).column().wFull().maxH(@max(row_height, pane_h * 0.3 - 14))
        .scrollY().scrollbar(.{ .overlay = k.muted.alpha(0.5) });
    defer rows.end();
    for (a.queue.items, 0..) |r, i| {
        ui.key(c, c.print("q-{s}", .{r.id}));
        row(c, a, k, r, i + 1 == a.queue.items.len, compact, width);
    }
    return true;
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, r: queue.Row, newest: bool, compact: bool, w: f32) void {
    const editing = if (a.queue_edit) |e| std.mem.eql(u8, e.row, r.id) else false;
    const can_steer = @import("app_queue.zig").rowCanSteer(a, r);
    const layout = rowLayout(w, if (editing) 2 else 2 + @as(usize, @intFromBool(!r.agent)) + @as(usize, @intFromBool(can_steer)));
    const stacked = compact and layout.stacked;
    var line = ui.div(c).wFull().px(8).gap(if (compact) 4 else 8).rounded(8);
    line = if (stacked) line.column().py(4) else line.row().h(row_height).itemsCenter();
    line = if (editing) line.bg(k.ink(0.06)) else line.hover(k.ink(0.04));
    defer line.end();
    const gated = r.gate != .none;
    if (!stacked) {
        var col = ui.div(c).column().clip().grow().w(0);
        defer col.end();
        const title: []const u8 = if (editing) blk: {
            if (a.queue_edit.?.saving) break :blk "Saving…";
            const buf = c.alloc().alloc(u8, 400) catch break :blk "Editing in composer";
            const one = queue.oneLine(buf, r.text);
            break :blk if (one.len > 0) c.print("Editing · {s}", .{one}) else "Editing in composer";
        } else switch (r.gate) {
            .editing => |who| c.print("Editing on {s}", .{who}),
            .review => "Needs review",
            .none => blk: {
                const buf = c.alloc().alloc(u8, 400) catch break :blk r.text;
                const one = queue.oneLine(buf, r.text);
                break :blk if (r.agent) c.print("Agent message · {s}", .{one}) else one;
            },
        };
        kit.fadeText(c, title, kit.style(c, 12.5, 16, .{ .color = k.text.alpha(0.9) }), 2000);
        if (r.attachments > 0 and !editing)
            ui.text(c, c.print("{d} attachment{s}", .{ r.attachments, if (r.attachments == 1) "" else "s" }), .{ .size = 11, .color = k.muted });
    }
    if (stacked) {
        narrowActions(c, a, k, r, editing, can_steer, layout);
        return;
    }
    if (editing) {
        if (compact) {
            if (rowButton(c, k, .check, "Save to queue", true)) a.queueFinishEdit(.commit);
            if (rowButton(c, k, .close, "Cancel", true)) a.queueFinishEdit(.cancel);
        } else {
            if (textButton(c, k, .check, "Save to queue", true)) a.queueFinishEdit(.commit);
            if (textButton(c, k, .close, "Cancel", true)) a.queueFinishEdit(.cancel);
        }
        return;
    }
    if (rowButton(c, k, .@"trash-bin-minimalistic", "Remove", !gated)) a.queueRemove(r.id);
    if (!r.agent and rowButton(c, k, .pen, "Edit", !gated and a.queue_edit == null)) a.queueBeginEdit(r.id);
    const queue_mod = @import("app_queue.zig");
    if (queue_mod.rowCanSteer(a, r)) {
        if (compact) {
            if (rowButton(c, k, .@"fast-tier", "Steer into active turn", true)) queue_mod.steerRowNow(a, r.id);
        } else {
            var sb = ui.div(c).row().h(28).px(8).center().rounded(5).opacity(0.72).hover(k.ink(0.07));
            sb = tip.on(sb, k, .{ .text = "Steer into active turn", .delay = tip.quick, .look = .queue });
            defer sb.end();
            if (sb.clicked()) queue_mod.steerRowNow(a, r.id);
            ui.text(c, "Steer", .{ .size = 11.5, .color = k.muted });
        }
    }
    const can_send = a.caps.actions and !gated;
    // `QueuePrimaryAction::tooltip`, or why it waits.
    const send_tip = if (can_send) "Send now (interrupt)" else "Waiting for provider capabilities";
    const label = if (newest and c.input.cmd) "⌘ Enter" else "Send now";
    if (compact) {
        if (rowButton(c, k, .@"arrow-up", send_tip, can_send)) a.queueSendNow(r.id);
    } else {
        var b = ui.div(c).row().size(72, 28).center().rounded(5).opacity(if (can_send) 0.72 else 0.45);
        if (can_send) b = b.hover(k.ink(0.07));
        b = tip.on(b, k, .{ .text = send_tip, .delay = tip.quick, .look = .queue });
        defer b.end();
        if (b.clicked() and can_send) a.queueSendNow(r.id);
        ui.text(c, label, .{ .size = 11.5, .color = k.muted });
    }
}

const Action = enum { edit, steer, remove, send, save, cancel };

fn narrowActions(c: *ui.Context, a: *App, k: theme.Colors, r: queue.Row, editing: bool, can_steer: bool, layout: RowLayout) void {
    var actions: std.ArrayList(Action) = .empty;
    const alloc = c.alloc();
    if (editing) {
        actions.appendSlice(alloc, &.{ .save, .cancel }) catch return;
    } else {
        if (!r.agent) actions.append(alloc, .edit) catch return;
        if (can_steer) actions.append(alloc, .steer) catch return;
        actions.appendSlice(alloc, &.{ .remove, .send }) catch return;
    }
    var start: usize = 0;
    while (start < actions.items.len) : (start += layout.columns) {
        const buttons = ui.div(c).row().wFull().h(28).gap(4).justifyCenter();
        defer buttons.end();
        for (actions.items[start..@min(start + layout.columns, actions.items.len)]) |action| {
            ui.key(c, @tagName(action));
            const enabled = switch (action) {
                .edit => r.gate == .none and a.queue_edit == null,
                .remove => r.gate == .none,
                .send => a.caps.actions and r.gate == .none,
                else => true,
            };
            const name: icons.Name = switch (action) {
                .edit => .pen,
                .steer => .@"fast-tier",
                .remove => .@"trash-bin-minimalistic",
                .send => .@"arrow-up",
                .save => .check,
                .cancel => .close,
            };
            const label: []const u8 = switch (action) {
                .edit => "Edit",
                .steer => "Steer into active turn",
                .remove => "Remove",
                .send => if (enabled) "Send now (interrupt)" else "Waiting for provider capabilities",
                .save => "Save to queue",
                .cancel => "Cancel",
            };
            if (rowButtonWidth(c, k, name, label, enabled, layout.button_width)) switch (action) {
                .edit => a.queueBeginEdit(r.id),
                .steer => @import("app_queue.zig").steerRowNow(a, r.id),
                .remove => a.queueRemove(r.id),
                .send => a.queueSendNow(r.id),
                .save => a.queueFinishEdit(.commit),
                .cancel => a.queueFinishEdit(.cancel),
            };
        }
    }
}

/// A `queue_action`: its icon, and `label` as its tooltip.
fn rowButton(c: *ui.Context, k: theme.Colors, name: icons.Name, label: []const u8, enabled: bool) bool {
    return rowButtonWidth(c, k, name, label, enabled, 28);
}

fn rowButtonWidth(c: *ui.Context, k: theme.Colors, name: icons.Name, label: []const u8, enabled: bool, width: f32) bool {
    var b = ui.div(c).row().size(width, 28).center().rounded(5).opacity(if (enabled) 0.72 else 0.45);
    if (enabled) b = b.hover(k.ink(0.07));
    b = tip.on(b, k, .{ .text = label, .delay = tip.quick, .look = .queue });
    defer b.end();
    const hot = b.hovered() and enabled;
    icons.icon(c, name, 13, if (hot) k.text else k.muted.alpha(0.8), 0);
    return b.clicked() and enabled;
}

fn textButton(c: *ui.Context, k: theme.Colors, name: icons.Name, label: []const u8, enabled: bool) bool {
    var b = ui.div(c).row().h(28).px(8).gap(5).itemsCenter().rounded(5).hover(k.ink(0.07));
    if (!enabled) b = b.opacity(0.45);
    b = tip.on(b, k, .{ .text = label, .delay = tip.quick, .look = .queue });
    defer b.end();
    icons.icon(c, name, 13, k.muted, 0);
    ui.text(c, label, .{ .size = 11.5, .color = k.muted });
    return b.clicked() and enabled;
}
