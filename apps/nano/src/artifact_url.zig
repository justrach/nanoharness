//! Pure validation and URL helpers for hosted CodeGraff artifacts (`artifact.codegraff.com`).
//! Transcript parts carry only bounded metadata and canonical `https://codegraff.com/a/<id>` links;
//! signed `https://artifact.codegraff.com/<id>?t=...` URLs are minted on demand for isolated WebViews.
const std = @import("std");

pub const id_len: usize = 28; // "art-" + 24 lowercase hex chars
pub const canonical_prefix = "https://codegraff.com/a/";
pub const public_prefix = "https://codegraff.com/public/a/";
pub const frame_prefix = "https://artifact.codegraff.com/";
pub const max_title_chars: usize = 200;

pub fn isValidId(id: []const u8) bool {
    if (id.len != id_len or !std.mem.startsWith(u8, id, "art-")) return false;
    for (id[4..]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!is_hex) return false;
    }
    return true;
}

pub fn isValidFormat(fmt: []const u8) bool {
    return std.mem.eql(u8, fmt, "html") or std.mem.eql(u8, fmt, "svg") or std.mem.eql(u8, fmt, "markdown");
}

pub fn isValidVisibility(vis: []const u8) bool {
    return std.mem.eql(u8, vis, "private") or std.mem.eql(u8, vis, "public");
}

pub fn canonicalUrl(buf: []u8, id: []const u8) ?[]const u8 {
    if (!isValidId(id)) return null;
    return std.fmt.bufPrint(buf, canonical_prefix ++ "{s}", .{id}) catch null;
}

pub fn publicUrl(buf: []u8, id: []const u8) ?[]const u8 {
    if (!isValidId(id)) return null;
    return std.fmt.bufPrint(buf, public_prefix ++ "{s}", .{id}) catch null;
}

pub fn isCanonicalUrl(url: []const u8, id: []const u8) bool {
    var buf: [64]u8 = undefined;
    const expected = canonicalUrl(&buf, id) orelse return false;
    return std.mem.eql(u8, url, expected);
}

/// Validates a sandbox iframe/WebView URL on `artifact.codegraff.com`.
/// Accepts unsigned public `https://artifact.codegraff.com/art-...` or signed `?t=<exp>.<sig>`.
/// Rejects fragments, other query keys, other origins, and malformed ids.
pub fn isSandboxFrameUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, frame_prefix)) return false;
    const rest = url[frame_prefix.len..];
    if (rest.len < id_len) return false;
    const id = rest[0..id_len];
    if (!isValidId(id)) return false;
    const tail = rest[id_len..];
    if (tail.len == 0) return true;
    if (!std.mem.startsWith(u8, tail, "?t=")) return false;
    const token = tail[3..];
    if (token.len == 0) return false;
    for (token) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn validatePart(id: []const u8, title: []const u8, format: []const u8, visibility: []const u8, url: []const u8) bool {
    if (!isValidId(id)) return false;
    const trimmed = std.mem.trim(u8, title, " \t\r\n");
    if (trimmed.len == 0) return false;
    if ((std.unicode.utf8CountCodepoints(trimmed) catch std.math.maxInt(usize)) > max_title_chars) return false;
    if (!isValidFormat(format) or !isValidVisibility(visibility)) return false;
    return isCanonicalUrl(url, id);
}

const testing = std.testing;

test "artifact id, canonical/public links, and sandbox frame validation" {
    const id = "art-0123456789abcdef01234567";
    try testing.expect(isValidId(id));
    try testing.expect(!isValidId("art-0123"));
    try testing.expect(!isValidId("art-0123456789ABCDEF01234567"));

    var canon_buf: [64]u8 = undefined;
    var pub_buf: [64]u8 = undefined;
    const canon = canonicalUrl(&canon_buf, id).?;
    try testing.expectEqualStrings("https://codegraff.com/a/art-0123456789abcdef01234567", canon);
    try testing.expectEqualStrings("https://codegraff.com/public/a/art-0123456789abcdef01234567", publicUrl(&pub_buf, id).?);
    try testing.expect(isCanonicalUrl(canon, id));
    try testing.expect(!isCanonicalUrl("https://codegraff.com/a/art-0123456789abcdef01234567?t=sig", id));

    try testing.expect(isSandboxFrameUrl("https://artifact.codegraff.com/art-0123456789abcdef01234567"));
    try testing.expect(isSandboxFrameUrl("https://artifact.codegraff.com/art-0123456789abcdef01234567?t=1900000900.abc-DEF_12"));
    try testing.expect(!isSandboxFrameUrl("https://artifact.codegraff.com/art-0123456789abcdef01234567?t="));
    try testing.expect(!isSandboxFrameUrl("https://artifact.codegraff.com/art-0123456789abcdef01234567?foo=bar"));
    try testing.expect(!isSandboxFrameUrl("https://artifact.codegraff.com/art-0123456789abcdef01234567#frag"));
    try testing.expect(!isSandboxFrameUrl("https://codegraff.com/a/art-0123456789abcdef01234567"));

    try testing.expect(validatePart(id, "Chart", "html", "private", canon));
    try testing.expect(!validatePart(id, "  \n", "html", "private", canon));
    try testing.expect(!validatePart(id, "Chart", "pdf", "private", canon));
    try testing.expect(!validatePart(id, "Chart", "html", "unlisted", canon));
    try testing.expect(!validatePart(id, "Chart", "html", "private", "https://artifact.codegraff.com/art-0123456789abcdef01234567"));
}
