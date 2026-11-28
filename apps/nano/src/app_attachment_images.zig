//! Host-jailed attachment read-back. Never open a transported local path.
const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const attachments = @import("app_attachments.zig");
const refs = @import("attachment_refs.zig");

pub const Cache = struct {
    items: std.ArrayList(*Image) = .empty,
    generation: u64 = 0,
    /// The open inspector pins already loaded bytes; no second host read.
    preview: ?*Image = null,
    preview_chat: ?[]u8 = null,
    zoom: f32 = 1,
    center: @import("nanoui").ui.Point = .{ .x = 0.5, .y = 0.5 },
    drag: ?@import("nanoui").ui.Point = null,
    inspection: @import("image_inspection.zig").State = .{},
    focus_scope: @import("preview_focus.zig").State = .{},
    annotate: @import("image_annotate.zig").State = .{},
    copy_status: enum { none, copied, failed } = .none,
    copy_until: f64 = 0,

    pub fn deinit(cache: *Cache, gpa: std.mem.Allocator) void {
        cache.annotate.deinit();
        if (cache.preview_chat) |chat| gpa.free(chat);
        for (cache.items.items) |image| image.destroy();
        cache.items.deinit(gpa);
    }
};

pub const Image = struct {
    app: *App,
    device: []u8,
    path: []u8,
    bytes: std.ArrayList(u8) = .empty,
    /// A small JPEG the tile can decode without blocking the frame.
    preview: std.ArrayList(u8) = .empty,
    encoded: std.ArrayList(u8) = .empty,
    status: enum { loading, ready, failed } = .loading,
    shrinking: bool = false,
    request: ?u64 = null,
    offset: u64 = 0,
    chunks: usize = 0,
    /// Computed once on completion; reply render keys must distinguish new
    /// content after eviction/reload without hashing megabytes every frame.
    content_hash: u64 = 0,
    used: u64 = 0,

    fn destroy(image: *Image) void {
        const gpa = image.app.gpa;
        gpa.free(image.device);
        gpa.free(image.path);
        image.bytes.deinit(gpa);
        image.preview.deinit(gpa);
        image.encoded.deinit(gpa);
        gpa.destroy(image);
    }

    /// ImageIO on the UI thread is the beachball. A 112-point JPEG is
    /// made here, off that thread, and the tile draws only that.
    fn shrink(image: *Image) void {
        if (image.shrinking or image.bytes.items.len <= 256 * 1024) return;
        image.shrinking = true;
        const t = std.Thread.spawn(.{}, shrinkWork, .{image}) catch {
            image.shrinking = false;
            return;
        };
        t.detach();
    }

    fn fail(image: *Image) void {
        image.request = null;
        image.status = .failed;
        image.encoded.clearAndFree(image.app.gpa);
        image.app.redraw();
    }

    fn next(image: *Image) void {
        const a = image.app;
        const local = if (a.device_id) |mine| std.mem.eql(u8, mine, image.device) else image.device.len == 0;
        image.request = a.send_(.{ .method = "ReadAttachmentChunk", .params = .{
            .path = image.path,
            .offset = image.offset,
            .targetDeviceId = if (local) @as(?[]const u8, null) else image.device,
        } }, .of(Image, image, onChunk));
        if (image.request == null) image.fail();
    }

    fn onChunk(image: *Image, _: u64, reply: rpc.Reply) void {
        image.request = null;
        const value = switch (reply) {
            .ok => |v| v,
            else => return image.fail(),
        };
        if (value != .object) return image.fail();
        const o = value.object;
        const data = o.get("data") orelse return image.fail();
        const done = o.get("done") orelse return image.fail();
        const mime = o.get("mimeType") orelse return image.fail();
        if (data != .string or done != .bool or mime != .string or !std.mem.startsWith(u8, mime.string, "image/")) return image.fail();
        if (!withinReadBudget(image.encoded.items.len, data.string.len, image.chunks)) return image.fail();
        image.chunks += 1;
        image.encoded.appendSlice(image.app.gpa, data.string) catch return image.fail();
        if (done.bool) {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(image.encoded.items) catch return image.fail();
            if (size == 0 or size > attachments.max_bytes) return image.fail();
            image.bytes.resize(image.app.gpa, size) catch return image.fail();
            decoder.decode(image.bytes.items, image.encoded.items) catch {
                image.bytes.clearAndFree(image.app.gpa);
                return image.fail();
            };
            image.encoded.clearAndFree(image.app.gpa);
            image.content_hash = std.hash.Wyhash.hash(0, image.bytes.items);
            image.status = .ready;
            image.shrink();
            image.app.redraw();
            return;
        }
        const offset = o.get("nextOffset") orelse return image.fail();
        if (offset != .integer or offset.integer <= 0) return image.fail();
        const next_offset: u64 = @intCast(offset.integer);
        if (next_offset <= image.offset) return image.fail();
        image.offset = next_offset;
        image.next();
    }
};

fn shrinkImageBytes(gpa: std.mem.Allocator, io: std.Io, bytes: []const u8, scratch_parent: []const u8) ?[]u8 {
    var rnd: [16]u8 = undefined;
    io.random(&rnd);
    const dir_path = std.fmt.allocPrint(gpa, "{s}/harness-nano-thumb-{s}", .{ scratch_parent, &std.fmt.bytesToHex(rnd, .lower) }) catch return null;
    defer gpa.free(dir_path);

    const cwd = std.Io.Dir.cwd();
    const dir_perms: std.Io.Dir.Permissions = if (comptime builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
    cwd.createDir(io, dir_path, dir_perms) catch return null;
    defer cwd.deleteTree(io, dir_path) catch {};

    const path = std.fmt.allocPrint(gpa, "{s}/in.png", .{dir_path}) catch return null;
    defer gpa.free(path);
    const out = std.fmt.allocPrint(gpa, "{s}/out.jpg", .{dir_path}) catch return null;
    defer gpa.free(out);
    defer cwd.deleteFile(io, path) catch {};
    defer cwd.deleteFile(io, out) catch {};

    const file_perms: std.Io.File.Permissions = if (comptime builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    {
        var file = cwd.createFile(io, path, .{ .exclusive = true, .permissions = file_perms }) catch return null;
        defer file.close(io);
        file.writeStreamingAll(io, bytes) catch return null;
    }
    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/sips", "-Z", "224", "-s", "format", "jpeg", "-s", "formatOptions", "60", path, "--out", out },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;
    const term = child.wait(io) catch return null;
    if (term != .exited or term.exited != 0) return null;
    return cwd.readFileAlloc(io, out, gpa, .limited(256 * 1024)) catch null;
}

fn shrinkWork(image: *Image) void {
    const jpeg = shrinkImageBytes(image.app.gpa, image.app.io, image.bytes.items, "/tmp");
    shrinkDone(image, jpeg);
}

fn shrinkDone(image: *Image, jpeg: ?[]u8) void {
    image.shrinking = false;
    if (jpeg) |bytes| {
        image.preview.clearRetainingCapacity();
        image.preview.appendSlice(image.app.gpa, bytes) catch {};
        image.app.gpa.free(bytes);
    }
    image.app.redraw();
}

pub fn tileBytes(image: *Image) []const u8 {
    if (image.preview.items.len > 0) return image.preview.items;
    if (image.status == .ready and image.bytes.items.len <= attachments.max_bytes) return image.bytes.items;
    return "";
}

/// Resolve the containing chat, not the focused pane or the message author.
pub fn get(a: *App, chat_id: ?[]const u8, path: []const u8) ?*Image {
    const chat = a.findChat(chat_id orelse return null) orelse return null;
    const device = chat.device_id orelse return null;
    return getDevice(a, device, path);
}

pub fn getDevice(a: *App, device: []const u8, path: []const u8) ?*Image {
    if (!refs.validPath(path) or !attachments.isImageName(path)) return null;
    const cache = &a.attachments.images;
    for (cache.items.items) |image| if (std.mem.eql(u8, image.device, device) and std.mem.eql(u8, image.path, path)) {
        image.used = cache.generation;
        return image;
    };
    if (!a.engine.up()) return null;
    const image = a.gpa.create(Image) catch return null;
    const dev = a.gpa.dupe(u8, device) catch {
        a.gpa.destroy(image);
        return null;
    };
    const ref = a.gpa.dupe(u8, path) catch {
        a.gpa.free(dev);
        a.gpa.destroy(image);
        return null;
    };
    image.* = .{ .app = a, .device = dev, .path = ref, .used = cache.generation };
    cache.items.append(a.gpa, image) catch {
        image.destroy();
        return null;
    };
    image.next();
    return image;
}

/// A frame's image nodes borrow encoded bytes. Evict only at the following
/// frame boundary, never from a render callback. Bound retained history to
/// two attachment budgets / 64 refs, while keeping currently drawn tiles.
pub fn reap(a: *App) void {
    const cache = &a.attachments.images;
    cache.generation += 1;
    var bytes: usize = 0;
    for (cache.items.items) |image| bytes += image.bytes.items.len + image.encoded.items.len;
    var i: usize = 0;
    while (i < cache.items.items.len) {
        const image = cache.items.items[i];
        if ((bytes > 2 * attachments.max_bytes or cache.items.items.len > 64) and image.used + 1 < cache.generation and cache.preview != image) {
            if (image.request) |id| a.engine.cancel(id);
            bytes -= image.bytes.items.len + image.encoded.items.len;
            _ = cache.items.orderedRemove(i);
            image.destroy();
        } else i += 1;
    }
}

pub fn withinReadBudget(encoded: usize, incoming: usize, chunks: usize) bool {
    const max_encoded = std.base64.standard.Encoder.calcSize(attachments.max_bytes);
    return chunks < 1000 and encoded <= max_encoded and incoming <= max_encoded -| encoded;
}

test "nano image parity read budget uses existing byte and chunk caps" {
    const t = std.testing;
    const max_encoded = std.base64.standard.Encoder.calcSize(attachments.max_bytes);
    try t.expect(withinReadBudget(0, max_encoded, 999));
    try t.expect(!withinReadBudget(0, max_encoded + 1, 0));
    try t.expect(!withinReadBudget(max_encoded, 1, 0));
    try t.expect(!withinReadBudget(0, 1, 1000));
    try t.expect(!withinReadBudget(std.math.maxInt(usize), 1, 0));
}

test "shrinkImageBytes removes temporary scratch files on success and failure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const t = std.testing;
    const io = t.io;
    const gpa = t.allocator;
    const parent = "/tmp/harness-nano-thumb-cleanup-test";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, parent) catch {};
    defer cwd.deleteTree(io, parent) catch {};
    try cwd.createDirPath(io, parent);

    // Invalid bytes fail sips; scratch dir must still be cleaned up.
    try t.expect(shrinkImageBytes(gpa, io, "not-a-png", parent) == null);

    // Valid 1x1 PNG succeeds and leaves no scratch dir behind.
    const png_1x1 = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };
    const jpeg = shrinkImageBytes(gpa, io, &png_1x1, parent) orelse return error.ExpectedThumbnail;
    defer gpa.free(jpeg);
    try t.expect(std.mem.startsWith(u8, jpeg, "\xff\xd8\xff"));

    var dir = try cwd.openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    try t.expect((try it.next(io)) == null);
}
