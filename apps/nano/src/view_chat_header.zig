//! The project folder name a header shows for a chat with no project row.
//! The windowed in-card context header this file held is gone: a pane's
//! title, project, branch and computer now live in one header strip, the
//! title bar's caption or full screen's (`view_fullscreen_chrome.chatHeader`).
const std = @import("std");

pub fn pathBasename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    if (trimmed.len == 0) return "~";
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    const back = std.mem.lastIndexOfScalar(u8, trimmed, '\\');
    const cut: ?usize = if (slash) |s| (if (back) |b| @max(s, b) else s) else back;
    return if (cut) |i| trimmed[i + 1 ..] else trimmed;
}

test "a header names a projectless chat by its folder" {
    try std.testing.expectEqualStrings("nanoharness", pathBasename("/Users/dev/nanoharness/"));
    try std.testing.expectEqualStrings("~", pathBasename("/"));
}
