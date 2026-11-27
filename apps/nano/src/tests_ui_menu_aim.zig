//! Nested-menu pointer aim: diagonal travel, idle fallthrough, and the
//! off path via the internal hook. Synthetic workspace only.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const menus = @import("view_sidebar_menus.zig");
const menu_aim = @import("menu_aim.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness, dark: bool) !void {
        theme.registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = dark;
        h.a.account.scope = .local;
        const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-project","deviceId":"synthetic-device","path":"/work/synthetic-notes","gitDetected":false}]
        , .{});
        defer spaces.deinit();
        try h.a.spaces.replace(spaces.value);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic-chat","deviceId":"synthetic-device","title":"Synthetic menu-aim conversation","spaceId":"synthetic-project","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{
            .width = 1200,
            .height = 780,
            .dark = dark,
            .theme = theme.ui(dark),
        });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

fn openOrganize(h: *Harness) !void {
    menus.openView(&h.a);
    h.t.settle(0.3);
    const organize = h.t.findText("Organize") orelse return error.NoOrganize;
    h.t.moveTo(organize.x + 8, organize.y + organize.h / 2);
    h.t.settle(0.2);
    h.t.frame();
    try testing.expectEqual(@as(?usize, 0), h.a.view.menus.open);
    try testing.expect(h.t.hasText("By status"));
    try testing.expect(!h.t.hasText("Created"));
    try testing.expect(h.a.view.menus.sub_rect != null);
}

fn slide(t: *ui.Tester, x0: f32, y0: f32, x1: f32, y1: f32, steps: usize) void {
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const f = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        t.moveTo(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f);
    }
}

/// A diagonal from Organize toward its submenu that crosses Sort.
fn diagonalTowardOrganizeSubmenu(h: *Harness) !void {
    const organize = h.t.findText("Organize") orelse return error.NoOrganize;
    const sort = h.t.findText("Sort") orelse return error.NoSort;
    const sub = h.a.view.menus.sub_rect orelse return error.NoSubmenu;
    const x0 = organize.x + 12;
    const y0 = organize.y + organize.h / 2;
    const mid_x = sort.x + sort.w * 0.72;
    const mid_y = sort.y + sort.h / 2;
    const x1 = sub.x + @min(40, sub.w * 0.35);
    const y1 = sub.y + sub.h * 0.55;
    slide(&h.t, x0, y0, mid_x, mid_y, 8);
    slide(&h.t, mid_x, mid_y, x1, y1, 10);
}

test "menu-aim off via the internal hook lets a diagonal open the wrong submenu" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    menu_aim.enabled = false;
    defer menu_aim.resetHook();
    try openOrganize(&h);
    try diagonalTowardOrganizeSubmenu(&h);
    h.snap("menu-aim-before");
    // The pointer crossed Sort and Last activity; either is the wrong submenu.
    try testing.expect(h.a.view.menus.open != @as(?usize, 0));
    try testing.expect(h.a.view.menus.open != null);
    try testing.expect(!h.t.hasText("By status"));
}

test "menu-aim holds Organize while the pointer crosses Sort toward its submenu" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try testing.expect(menu_aim.enabled);
    try testing.expect(!menu_aim.debugOn());
    try openOrganize(&h);
    try diagonalTowardOrganizeSubmenu(&h);
    h.snap("menu-aim-after");
    try testing.expectEqual(@as(?usize, 0), h.a.view.menus.open);
    try testing.expect(h.t.hasText("By status"));
    try testing.expect(!h.t.hasText("Created"));
}

test "menu-aim idle fallthrough lets hover switching resume after 300ms" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try openOrganize(&h);
    const sort = h.t.findText("Sort") orelse return error.NoSort;
    const organize = h.t.findText("Organize") orelse return error.NoOrganize;
    const x0 = organize.x + 12;
    const y0 = organize.y + organize.h / 2;
    const x1 = sort.x + sort.w * 0.72;
    const y1 = sort.y + sort.h / 2;
    slide(&h.t, x0, y0, x1, y1, 8);
    try testing.expectEqual(@as(?usize, 0), h.a.view.menus.open);
    h.t.advance(0.25);
    try testing.expectEqual(@as(?usize, 0), h.a.view.menus.open);
    h.t.advance(0.10);
    try testing.expectEqual(@as(?usize, 1), h.a.view.menus.open);
    try testing.expect(h.t.hasText("Created"));
}
