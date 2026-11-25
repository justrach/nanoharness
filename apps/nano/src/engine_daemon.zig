//! `harness-engine daemon …`: installs and manages `harness-engine headless`
//! as a background service, a launchd LaunchAgent on macOS and a systemd
//! user unit on Linux (`apps/harness/src/daemon.rs`). The unit runs this
//! executable with the `HARNESS_*` environment captured at install time.
//!
//! Each action is a plan of steps (a pure function, for tests) that `run`
//! carries out. The label and unit name are the ones the Rust CLI and the
//! curl installer use, so installing here replaces that service rather than
//! running a second engine beside it.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const DaemonAction = @import("engine_cli.zig").DaemonAction;

pub const launchd_label = "harness.codegraff.app";
pub const systemd_unit = "harness.service";
pub const exe_name = if (builtin.os.tag == .windows) "harness-engine.exe" else "harness-engine";

/// Environment captured into the unit. `PATH` always (the engine starts agent
/// CLIs that a service manager's minimal PATH won't find); the rest when set.
pub const captured_env = [_][]const u8{
    "PATH",
    "HARNESS_DATA_DIR",
    "HARNESS_EDGE_URL",
    "HARNESS_EDGE_TOKEN",
    "HARNESS_ORG_ID",
    "HARNESS_CODEGRAFF_CLIENT_ID",
    "HARNESS_CODEGRAFF_API_BASE",
    "HARNESS_CODEGRAFF_GATEWAY",
    "HARNESS_IPC_PORT",
    "HARNESS_CALLBACK_PORT",
    "HARNESS_PROVIDER",
    "HARNESS_OPTED_IN",
    "HARNESS_DEVICE_NAME",
    "ANTIGRAVITY_ACP_EXECUTABLE",
    "GEMINI_HOME",
    "GEMINI_API_KEY",
    "HARNESS_AUTH_DISABLED",
    "GRAFF_EXECUTABLE",
};

pub const Pair = struct { key: []const u8, value: []const u8 };

pub fn capture(gpa: Allocator, env: *const Map) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    errdefer out.deinit(gpa);
    for (captured_env) |key| if (env.get(key)) |v| try out.append(gpa, .{ .key = key, .value = v });
    return out.toOwnedSlice(gpa);
}

fn writeXmlEscaped(w: *Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(ch),
    };
}

/// The LaunchAgent: started at login, restarted when it fails (not when it
/// exits cleanly, as after `StopEngine`), output to `log`.
pub fn renderLaunchdPlist(gpa: Allocator, exe: []const u8, env: []const Pair, log: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\  <dict>
        \\    <key>Label</key><string>
    ++ launchd_label ++
        \\</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\      <string>
    );
    try writeXmlEscaped(w, exe);
    try w.writeAll(
        \\</string>
        \\      <string>headless</string>
        \\    </array>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\
    );
    for (env) |p| {
        try w.writeAll("      <key>");
        try writeXmlEscaped(w, p.key);
        try w.writeAll("</key><string>");
        try writeXmlEscaped(w, p.value);
        try w.writeAll("</string>\n");
    }
    try w.writeAll(
        \\    </dict>
        \\    <key>RunAtLoad</key><true/>
        \\    <key>KeepAlive</key>
        \\    <dict>
        \\      <key>SuccessfulExit</key><false/>
        \\    </dict>
        \\    <key>ThrottleInterval</key><integer>30</integer>
        \\    <key>StandardOutPath</key><string>
    );
    try writeXmlEscaped(w, log);
    try w.writeAll("</string>\n    <key>StandardErrorPath</key><string>");
    try writeXmlEscaped(w, log);
    try w.writeAll("</string>\n  </dict>\n</plist>\n");
    return aw.toOwnedSlice();
}

/// The binary a systemd unit runs. One under `~/.harness/app/` came from the
/// curl installer, whose upgrades relink `app/current`: point at the link so
/// the unit never pins a version.
pub fn systemdExecPath(gpa: Allocator, exe: []const u8, home: ?[]const u8) ![]u8 {
    if (home) |h| if (h.len > 0) {
        const app_root = try std.fs.path.join(gpa, &.{ h, ".harness", "app" });
        defer gpa.free(app_root);
        if (std.mem.startsWith(u8, exe, app_root) and exe.len > app_root.len and exe[app_root.len] == '/')
            return gpa.dupe(u8, "%h/.harness/app/current/" ++ exe_name);
    };
    return gpa.dupe(u8, exe);
}

pub fn renderSystemdUnit(gpa: Allocator, exec_path: []const u8, env: []const Pair) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("[Unit]\nDescription=Harness headless engine\nAfter=network-online.target\nStartLimitIntervalSec=60\nStartLimitBurst=5\n\n[Service]\n");
    for (env) |p| {
        // systemd unquotes the value: escape what it treats specially.
        try w.print("Environment=\"{s}=", .{p.key});
        for (p.value) |ch| switch (ch) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => try w.writeByte(ch),
        };
        try w.writeAll("\"\n");
    }
    try w.print("ExecStart={s} headless\nRestart=on-failure\nRestartSec=5\nEnvironmentFile=-%h/.harness/env\n\n[Install]\nWantedBy=default.target\n", .{exec_path});
    return aw.toOwnedSlice();
}

pub const Os = enum { macos, linux, other };

pub fn hostOs() Os {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        else => .other,
    };
}

/// What a plan works from.
pub const Facts = struct {
    os: Os,
    uid: u32,
    /// This executable, absolute.
    exe: []const u8,
    home: []const u8,
    /// `XDG_CONFIG_HOME`, when set.
    xdg_config: ?[]const u8 = null,
    data_dir: []const u8,
    env: []const Pair,
    /// Whether the LaunchAgent plist / systemd unit file exists now.
    installed: bool,
};

pub const Step = union(enum) {
    /// Run a command; `quiet` ones may fail (an expected branch).
    run: struct { argv: []const []const u8, quiet: bool = false },
    /// Run a command with this terminal's output, its exit status ignored.
    passthrough: []const []const u8,
    /// `launchctl print`, keeping the liveness lines.
    launchctl_print: []const []const u8,
    mkdir: []const u8,
    write: struct { path: []const u8, body: []const u8 },
    /// Remove a file; `Not installed.` when it isn't there.
    remove: []const u8,
    say: []const u8,
    fail: []const u8,
    /// `restart` on macOS: try a kickstart, and if the job isn't loaded, start it.
    kickstart_or_start: struct { kick: []const []const u8, start: []const Step },
};

/// The steps for `action`, every string in `arena`.
pub fn plan(arena: Allocator, action: DaemonAction, f: Facts) ![]const Step {
    var steps: std.ArrayList(Step) = .empty;
    const unsupported = "Harness daemon is only supported on macOS (launchd) and Linux (systemd)";
    switch (f.os) {
        .other => try steps.append(arena, .{ .fail = unsupported }),
        .macos => {
            const domain = try std.fmt.allocPrint(arena, "gui/{d}", .{f.uid});
            const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ domain, launchd_label });
            const plist = try std.fs.path.join(arena, &.{ f.home, "Library", "LaunchAgents", launchd_label ++ ".plist" });
            const bootstrap = try arena.dupe([]const u8, &.{ "launchctl", "bootstrap", domain, plist });
            const start_steps = try arena.dupe(Step, &.{
                .{ .run = .{ .argv = bootstrap, .quiet = true } },
                .{ .run = .{ .argv = try arena.dupe([]const u8, &.{ "launchctl", "kickstart", target }) } },
                .{ .say = "Started." },
            });
            switch (action) {
                .install => {
                    const log = try std.fs.path.join(arena, &.{ f.data_dir, "daemon.log" });
                    try steps.appendSlice(arena, &.{
                        .{ .mkdir = std.fs.path.dirname(plist).? },
                        .{ .mkdir = f.data_dir },
                        // Reinstall-friendly: unload any earlier one first.
                        .{ .run = .{ .argv = try arena.dupe([]const u8, &.{ "launchctl", "bootout", target }), .quiet = true } },
                        .{ .write = .{ .path = plist, .body = try renderLaunchdPlist(arena, f.exe, f.env, log) } },
                        .{ .run = .{ .argv = bootstrap } },
                        .{ .say = try std.fmt.allocPrint(arena, "Installed and started {s} ({s}).\nWithout a saved account the engine stays local-only; sign-in and restart are optional for sync.\nLogs: {s}", .{ launchd_label, plist, log }) },
                    });
                },
                .uninstall => try steps.appendSlice(arena, &.{
                    .{ .run = .{ .argv = try arena.dupe([]const u8, &.{ "launchctl", "bootout", target }), .quiet = true } },
                    .{ .remove = plist },
                }),
                .start => if (!f.installed)
                    try steps.append(arena, .{ .fail = "not installed — run `harness-engine daemon install` first" })
                else
                    try steps.appendSlice(arena, start_steps),
                // bootout, not kill: with KeepAlive the job would come back.
                .stop => try steps.appendSlice(arena, &.{
                    .{ .run = .{ .argv = try arena.dupe([]const u8, &.{ "launchctl", "bootout", target }) } },
                    .{ .say = "Stopped." },
                }),
                .restart => try steps.append(arena, .{ .kickstart_or_start = .{
                    .kick = try arena.dupe([]const u8, &.{ "launchctl", "kickstart", "-k", target }),
                    .start = if (f.installed) start_steps else try arena.dupe(Step, &.{.{ .fail = "not installed — run `harness-engine daemon install` first" }}),
                } }),
                .status => try steps.appendSlice(arena, &.{
                    .{ .launchctl_print = try arena.dupe([]const u8, &.{ "launchctl", "print", target }) },
                    .{ .say = if (f.installed) " (installed — `harness-engine daemon start`)" else " (not installed — `harness-engine daemon install`)" },
                }),
            }
        },
        .linux => {
            const config = f.xdg_config orelse try std.fs.path.join(arena, &.{ f.home, ".config" });
            const unit = try std.fs.path.join(arena, &.{ config, "systemd", "user", systemd_unit });
            const sc = struct {
                fn argv(a: Allocator, args: []const []const u8) ![]const []const u8 {
                    var list: std.ArrayList([]const u8) = .empty;
                    try list.appendSlice(a, &.{ "systemctl", "--user" });
                    try list.appendSlice(a, args);
                    return list.toOwnedSlice(a);
                }
            };
            switch (action) {
                .install => {
                    const exec = try systemdExecPath(arena, f.exe, f.home);
                    try steps.appendSlice(arena, &.{
                        .{ .mkdir = std.fs.path.dirname(unit).? },
                        .{ .write = .{ .path = unit, .body = try renderSystemdUnit(arena, exec, f.env) } },
                        .{ .run = .{ .argv = try sc.argv(arena, &.{"daemon-reload"}) } },
                        .{ .run = .{ .argv = try sc.argv(arena, &.{ "enable", "--now", systemd_unit }) } },
                        .{ .say = try std.fmt.allocPrint(arena, "Installed and started {s} ({s}).\nFor start-at-boot without an active login session (VPS): loginctl enable-linger $USER\nWithout a saved account the engine stays local-only; sign-in and restart are optional for sync.\nLogs: journalctl --user -u {s}", .{ systemd_unit, unit, systemd_unit }) },
                    });
                },
                .uninstall => {
                    try steps.append(arena, .{ .run = .{ .argv = try sc.argv(arena, &.{ "disable", "--now", systemd_unit }), .quiet = true } });
                    try steps.append(arena, .{ .remove = unit });
                    if (f.installed) try steps.append(arena, .{ .run = .{ .argv = try sc.argv(arena, &.{"daemon-reload"}) } });
                },
                .start => try steps.appendSlice(arena, &.{ .{ .run = .{ .argv = try sc.argv(arena, &.{ "start", systemd_unit }) } }, .{ .say = "Started." } }),
                .stop => try steps.appendSlice(arena, &.{ .{ .run = .{ .argv = try sc.argv(arena, &.{ "stop", systemd_unit }) } }, .{ .say = "Stopped." } }),
                .restart => try steps.appendSlice(arena, &.{ .{ .run = .{ .argv = try sc.argv(arena, &.{ "restart", systemd_unit }) } }, .{ .say = "Restarted." } }),
                .status => try steps.append(arena, .{ .passthrough = try sc.argv(arena, &.{ "--no-pager", "status", systemd_unit }) }),
            }
        },
    }
    return steps.toOwnedSlice(arena);
}

/// The lines of `launchctl print` worth showing.
pub fn writeLivenessLines(w: *Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "state = ") or std.mem.startsWith(u8, t, "pid = ") or std.mem.startsWith(u8, t, "last exit code = "))
            try w.print("  {s}\n", .{t});
    }
}

pub const Runner = struct {
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    /// Where errors go; null: this process's stderr (as the Rust CLI's).
    err: ?*Io.Writer = null,

    fn fail(r: Runner, comptime fmt: []const u8, args: anytype) !void {
        try r.out.flush();
        try printErr(r.io, r.err, fmt, args);
    }

    const Ran = struct { ok: bool, stdout: []u8, stderr: []u8 };

    fn exec(r: Runner, argv: []const []const u8) !Ran {
        const res = try std.process.run(r.gpa, r.io, .{
            .argv = argv,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
        });
        return .{ .ok = switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        }, .stdout = res.stdout, .stderr = res.stderr };
    }

    /// Carries out `steps`; the exit code.
    pub fn run(r: Runner, steps: []const Step) !u8 {
        for (steps, 0..) |step, i| switch (step) {
            .fail => |msg| {
                try r.fail("harness-engine: {s}\n", .{msg});
                return 1;
            },
            .say => |msg| try r.out.print("{s}\n", .{msg}),
            .mkdir => |dir| try Io.Dir.cwd().createDirPath(r.io, dir),
            .write => |wf| try Io.Dir.cwd().writeFile(r.io, .{ .sub_path = wf.path, .data = wf.body }),
            .remove => |path| {
                if (Io.Dir.cwd().deleteFile(r.io, path)) |_| {
                    try r.out.print("Removed {s}.\n", .{path});
                } else |err| switch (err) {
                    error.FileNotFound => {
                        try r.out.writeAll("Not installed.\n");
                        // Nothing left to reload.
                        return 0;
                    },
                    else => |e| return e,
                }
            },
            .run => |cmd| {
                if (!cmd.quiet) try r.out.print("$ {s}\n", .{try std.mem.join(r.gpa, " ", cmd.argv)});
                const ran = r.exec(cmd.argv) catch |err| {
                    if (cmd.quiet) continue;
                    try r.fail("harness-engine: running {s} failed: {t}\n", .{ cmd.argv[0], err });
                    return 1;
                };
                defer r.gpa.free(ran.stdout);
                defer r.gpa.free(ran.stderr);
                if (!ran.ok and !cmd.quiet) {
                    try r.fail("harness-engine: {s} failed: {s}\n", .{ try std.mem.join(r.gpa, " ", cmd.argv), std.mem.trim(u8, ran.stderr, " \r\n") });
                    return 1;
                }
            },
            .passthrough => |argv| {
                var child = std.process.spawn(r.io, .{ .argv = argv, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit }) catch |err| {
                    try r.fail("harness-engine: running {s} failed: {t}\n", .{ argv[0], err });
                    return 1;
                };
                _ = child.wait(r.io) catch {};
            },
            .launchctl_print => |argv| {
                const ran = try r.exec(argv);
                defer r.gpa.free(ran.stdout);
                defer r.gpa.free(ran.stderr);
                if (!ran.ok) {
                    // The next step says whether it is installed.
                    const note = if (i + 1 < steps.len and steps[i + 1] == .say) steps[i + 1].say else "";
                    try r.out.print("{s}: not loaded{s}\n", .{ launchd_label, note });
                    return 0;
                }
                try r.out.print("{s}: loaded\n", .{launchd_label});
                try writeLivenessLines(r.out, ran.stdout);
                return 0;
            },
            .kickstart_or_start => |ks| {
                const ran = r.exec(ks.kick) catch return r.run(ks.start);
                defer r.gpa.free(ran.stdout);
                defer r.gpa.free(ran.stderr);
                // Not loaded (after `stop`, say): a plain start.
                if (!ran.ok) return r.run(ks.start);
                try r.out.writeAll("Restarted.\n");
            },
        };
        return 0;
    }
};

/// `harness-engine daemon <action>` for this machine.
fn printErr(io: Io, err_w: ?*Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    if (err_w) |w| {
        try w.print(fmt, args);
        try w.flush();
        return;
    }
    var buf: [1024]u8 = undefined;
    var ew = Io.File.stderr().writerStreaming(io, &buf);
    try ew.interface.print(fmt, args);
    try ew.interface.flush();
}

pub fn main(gpa: Allocator, io: Io, env: *const Map, data_dir: []const u8, action: DaemonAction, out: *Io.Writer) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const os = hostOs();
    if (os == .other) {
        try printErr(io, null, "harness-engine: Harness daemon is only supported on macOS (launchd) and Linux (systemd)\n", .{});
        return 1;
    }
    const home = env.get("HOME") orelse {
        try printErr(io, null, "harness-engine: HOME not set\n", .{});
        return 1;
    };
    const exe = try std.process.executablePathAlloc(io, arena);
    var facts: Facts = .{
        .os = os,
        .uid = if (comptime builtin.os.tag == .windows) 0 else @intCast(std.c.getuid()),
        .exe = exe,
        .home = home,
        .xdg_config = env.get("XDG_CONFIG_HOME"),
        .data_dir = data_dir,
        .env = try capture(arena, env),
        .installed = false,
    };
    const unit_path = if (os == .macos)
        try std.fs.path.join(arena, &.{ home, "Library", "LaunchAgents", launchd_label ++ ".plist" })
    else
        try std.fs.path.join(arena, &.{ facts.xdg_config orelse try std.fs.path.join(arena, &.{ home, ".config" }), "systemd", "user", systemd_unit });
    facts.installed = if (Io.Dir.cwd().access(io, unit_path, .{})) |_| true else |_| false;
    const steps = try plan(arena, action, facts);
    const runner: Runner = .{ .gpa = arena, .io = io, .out = out };
    return runner.run(steps);
}

const testing = std.testing;

test "launchd plist: label, headless argv, escaped values, restart on failure only" {
    const plist = try renderLaunchdPlist(testing.allocator, "/Users/x/harness & co/harness-engine", &.{.{ .key = "HARNESS_EDGE_URL", .value = "https://e?a=1&b=2" }}, "/Users/x/.harness/daemon.log");
    defer testing.allocator.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>Label</key><string>harness.codegraff.app</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>/Users/x/harness &amp; co/harness-engine</string>\n      <string>headless</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>HARNESS_EDGE_URL</key><string>https://e?a=1&amp;b=2</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>SuccessfulExit</key><false/>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>StandardOutPath</key><string>/Users/x/.harness/daemon.log</string>") != null);
}

test "daemon capture includes HARNESS_OPTED_IN so a headless install keeps the env opt-in" {
    for ([_][]const u8{
        "HARNESS_OPTED_IN",
        "ANTIGRAVITY_ACP_EXECUTABLE",
        "GEMINI_HOME",
        "GEMINI_API_KEY",
    }) |want| {
        var found = false;
        for (captured_env) |key| {
            if (std.mem.eql(u8, key, want)) found = true;
        }
        try testing.expect(found);
    }
}

test "systemd unit: headless ExecStart, quoted environment, start limits" {
    const unit = try renderSystemdUnit(testing.allocator, "/usr/local/bin/harness-engine", &.{
        .{ .key = "PATH", .value = "/usr/bin:/bin" },
        .{ .key = "HARNESS_DEVICE_NAME", .value = "box \"one\"" },
    });
    defer testing.allocator.free(unit);
    try testing.expect(std.mem.indexOf(u8, unit, "ExecStart=/usr/local/bin/harness-engine headless\n") != null);
    try testing.expect(std.mem.indexOf(u8, unit, "Environment=\"PATH=/usr/bin:/bin\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, unit, "Environment=\"HARNESS_DEVICE_NAME=box \\\"one\\\"\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, unit, "StartLimitBurst=5\n") != null);
    try testing.expect(std.mem.indexOf(u8, unit, "Restart=on-failure") != null);
    try testing.expect(std.mem.indexOf(u8, unit, "EnvironmentFile=-%h/.harness/env") != null);
}

test "an installer-managed engine's unit follows the current link" {
    const managed = try systemdExecPath(testing.allocator, "/home/u/.harness/app/0.3.0/harness-engine", "/home/u");
    defer testing.allocator.free(managed);
    try testing.expectEqualStrings("%h/.harness/app/current/harness-engine", managed);
    const source = try systemdExecPath(testing.allocator, "/src/zig-out/bin/harness-engine", "/home/u");
    defer testing.allocator.free(source);
    try testing.expectEqualStrings("/src/zig-out/bin/harness-engine", source);
}

fn testFacts(os: Os, installed: bool) Facts {
    return .{ .os = os, .uid = 501, .exe = "/Applications/Harness.app/Contents/MacOS/harness-engine", .home = "/Users/synthetic", .data_dir = "/Users/synthetic/.harness", .env = &.{}, .installed = installed };
}

test "daemon plans: launchd and systemd steps for each action, matching the Rust CLI" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const install = try plan(arena, .install, testFacts(.macos, false));
    try testing.expectEqualStrings("/Users/synthetic/Library/LaunchAgents/harness.codegraff.app.plist", install[3].write.path);
    try testing.expect(std.mem.indexOf(u8, install[3].write.body, "<string>/Applications/Harness.app/Contents/MacOS/harness-engine</string>") != null);
    try testing.expect(install[2].run.quiet);
    try testing.expectEqualStrings("bootout", install[2].run.argv[1]);
    try testing.expectEqualStrings("gui/501", install[4].run.argv[2]);

    const start_missing = try plan(arena, .start, testFacts(.macos, false));
    try testing.expect(start_missing[0] == .fail);
    const start = try plan(arena, .start, testFacts(.macos, true));
    try testing.expectEqualStrings("kickstart", start[1].run.argv[1]);
    try testing.expectEqualStrings("gui/501/harness.codegraff.app", start[1].run.argv[2]);

    const stop = try plan(arena, .stop, testFacts(.macos, true));
    try testing.expectEqualStrings("bootout", stop[0].run.argv[1]);
    const restart = try plan(arena, .restart, testFacts(.macos, true));
    try testing.expectEqualStrings("-k", restart[0].kickstart_or_start.kick[2]);

    var linux = testFacts(.linux, true);
    linux.exe = "/home/synthetic/.harness/app/0.3.0/harness-engine";
    linux.home = "/home/synthetic";
    const lin_install = try plan(arena, .install, linux);
    try testing.expectEqualStrings("/home/synthetic/.config/systemd/user/harness.service", lin_install[1].write.path);
    try testing.expect(std.mem.indexOf(u8, lin_install[1].write.body, "ExecStart=%h/.harness/app/current/harness-engine headless") != null);
    try testing.expectEqualStrings("enable", lin_install[3].run.argv[2]);
    const lin_status = try plan(arena, .status, linux);
    try testing.expectEqualStrings("status", lin_status[0].passthrough[3]);
    const lin_uninstall = try plan(arena, .uninstall, linux);
    try testing.expect(lin_uninstall[0].run.quiet);
    try testing.expectEqualStrings("daemon-reload", lin_uninstall[2].run.argv[2]);

    const other = try plan(arena, .install, testFacts(.other, false));
    try testing.expect(other[0] == .fail);
}

test "daemon runner: missing unit says not installed; a failing command stops the plan" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var ew: Io.Writer.Allocating = .init(testing.allocator);
    defer ew.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    // A command that fails, from the POSIX shell (no `false` binary assumed).
    const failing = &[_][]const u8{ "/bin/sh", "-c", "exit 3" };
    var missing_buf: [96]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buf, "/tmp/nano-daemon-test-missing-{d}.plist", .{std.c.getpid()});
    const runner: Runner = .{ .gpa = arena_state.allocator(), .io = testing.io, .out = &aw.writer, .err = &ew.writer };
    try testing.expectEqual(@as(u8, 0), try runner.run(&.{
        .{ .run = .{ .argv = failing, .quiet = true } },
        .{ .remove = missing },
        .{ .say = "unreachable" },
    }));
    try testing.expectEqualStrings("Not installed.\n", aw.written());
    aw.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 1), try runner.run(&.{
        .{ .run = .{ .argv = failing } },
        .{ .say = "unreachable" },
    }));
    // The failure is on stderr; stdout has only the command line.
    try testing.expect(std.mem.indexOf(u8, ew.written(), "/bin/sh -c exit 3 failed") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "failed") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "unreachable") == null);
}

test "launchctl print: only the liveness lines" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeLivenessLines(&aw.writer, "gui/501/harness.codegraff.app = {\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n\tlast exit code = 0\n}\n");
    try testing.expectEqualStrings("  state = running\n  pid = 4242\n  last exit code = 0\n", aw.written());
}
