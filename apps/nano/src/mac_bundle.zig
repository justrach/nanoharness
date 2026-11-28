//! Resolve the app bundle and seed its packaged command-line tools.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn seed(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) void {
    const home = env.get("HOME") orelse return;
    if (home.len == 0) return;
    const exe = std.process.executablePathAlloc(io, gpa) catch return;
    defer gpa.free(exe);
    const bundle = ancestor(exe) orelse return;
    const cli = std.fs.path.join(gpa, &.{ bundle, "Contents", "MacOS", "harness" }) catch return;
    defer gpa.free(cli);
    // Standalone developer bundles may contain only the GUI executable.
    _ = Io.Dir.cwd().statFile(io, cli, .{}) catch return;
    seedTools(gpa, io, bundle, cli, home);
}

pub fn ancestor(exe_path: []const u8) ?[]const u8 {
    var cur: ?[]const u8 = std.fs.path.dirname(exe_path);
    while (cur) |dir| {
        if (std.mem.endsWith(u8, dir, ".app")) return dir;
        cur = std.fs.path.dirname(dir);
    }
    return null;
}

fn seedTools(gpa: Allocator, io: Io, bundle: []const u8, cli: []const u8, home: []const u8) void {
    const bundled_graff = std.fs.path.join(gpa, &.{ bundle, "Contents", "Resources", "bin", "graff" }) catch return;
    defer gpa.free(bundled_graff);
    if (Io.Dir.cwd().statFile(io, bundled_graff, .{})) |_| {
        const bin_dir = std.fs.path.join(gpa, &.{ home, ".harness", "bin" }) catch return;
        defer gpa.free(bin_dir);
        const managed_graff = std.fs.path.join(gpa, &.{ bin_dir, "graff" }) catch return;
        defer gpa.free(managed_graff);
        if (Io.Dir.cwd().statFile(io, managed_graff, .{})) |_| {} else |_| {
            Io.Dir.cwd().createDirPath(io, bin_dir) catch {};
            if (Io.Dir.cwd().readFileAlloc(io, bundled_graff, gpa, .limited(256 << 20))) |bytes| {
                defer gpa.free(bytes);
                const tmp_graff = std.fs.path.join(gpa, &.{ bin_dir, ".graff.tmp" }) catch return;
                defer gpa.free(tmp_graff);
                if (Io.Dir.cwd().createFile(io, tmp_graff, .{ .truncate = true, .permissions = .fromMode(0o755) })) |f| {
                    f.writeStreamingAll(io, bytes) catch {};
                    f.close(io);
                    Io.Dir.rename(std.Io.Dir.cwd(), tmp_graff, std.Io.Dir.cwd(), managed_graff, io) catch {};
                } else |_| {}
            } else |_| {}
        }
    } else |_| {}

    const local_bin = std.fs.path.join(gpa, &.{ home, ".local", "bin" }) catch return;
    defer gpa.free(local_bin);
    if (Io.Dir.cwd().openDir(io, local_bin, .{})) |d| {
        var dir = d;
        dir.close(io);
        const shim = std.fs.path.join(gpa, &.{ local_bin, "harness" }) catch return;
        defer gpa.free(shim);
        if (Io.Dir.cwd().statFile(io, shim, .{})) |_| {} else |_| {
            Io.Dir.cwd().symLink(io, cli, shim, .{}) catch {};
        }
    } else |_| {}
}
