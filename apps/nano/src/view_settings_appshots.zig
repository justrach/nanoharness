//! The macOS permission checks and the small badge and action Settings ›
//! Agents draws (Screen Recording for agents' screenshots). They came from
//! the GPUI app's Appshots page (settings/appshots.rs); Nano has no Appshot
//! capture path, so it shows no such page and keeps its saved choices
//! (`appshotsEnabled`, `appshotSoundEnabled`, `appshotDestination`,
//! `keymap.captureAppshot`) untouched.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const set = @import("view_settings.zig");

/// A permission's state (`CapabilityState`).
pub const Capability = enum { ready, required };

/// Screen Recording and Accessibility, as macOS says this process has them.
pub const Capabilities = struct { capture: Capability, text: Capability };

pub fn capabilities() Capabilities {
    return .{
        .capture = if (ask("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGPreflightScreenCaptureAccess")) .ready else .required,
        .text = if (ask("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", "AXIsProcessTrusted")) .ready else .required,
    };
}

/// A yes-or-no question for the system, looked up where the system has it.
fn ask(lib: [*:0]const u8, name: [*:0]const u8) bool {
    if (comptime @import("builtin").os.tag != .macos) return false;
    const h = std.c.dlopen(lib, .{ .LAZY = true }) orelse return false;
    const f: *const fn () callconv(.c) bool = @ptrCast(@alignCast(std.c.dlsym(h, name) orelse return false));
    return f();
}

/// Asks for one, the first time; System Settings after (`request_*_access`).
pub fn request(lib: [*:0]const u8, name: [*:0]const u8) void {
    if (comptime @import("builtin").os.tag != .macos) return;
    const h = std.c.dlopen(lib, .{ .LAZY = true }) orelse return;
    const f: *const fn () callconv(.c) bool = @ptrCast(@alignCast(std.c.dlsym(h, name) orelse return));
    _ = f();
}

/// `badge`: a hairline pill, 8 by 2 inside its border (which GPUI's box
/// holds, and nanoui draws over: 9 by 3 here).
pub fn badge(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const b = ui.div(c).row().px(9).py(3).roundedFull().border(k.border).borderW(1);
    defer b.end();
    ui.text(c, label, set.st(c, 10.5, .{ .color = k.muted }));
}

/// `ghost_action`: 12-point muted words, a wash under the pointer.
pub fn action(c: *ui.Context, k: theme.Colors, label: []const u8) bool {
    const b = ui.div(c).row().px(10).py(6).gap(6).rounded(8).itemsCenter().hover(k.ink(0.06));
    defer b.end();
    ui.text(c, label, set.st(c, 12, .{ .color = if (b.hovered()) k.text else k.muted }));
    return b.clicked();
}
