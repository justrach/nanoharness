//! Project actions (crates/ui/src/shell/actions_ui.rs, project_actions.rs):
//! named commands kept per project on its device (`ListProjectActions`,
//! `UpsertProjectAction`, `DeleteProjectAction`). Running one
//! (`RunProjectAction`) starts it in a terminal in the chat's checkout; its
//! output streams into a tab of the dock under the chat
//! (`SubscribeTerminal`), and closing the tab ends it (`CloseTerminal`).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const termlog = @import("termlog.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const icons = [_][]const u8{ "play", "test", "lint", "configure", "build", "debug" };

pub const Action = struct { id: []const u8, name: []const u8, command: []const u8, icon: []const u8, setup: bool };

pub const Status = enum { idle, loading, ready, unavailable, unsupported };

pub const Editor = struct {
    /// The action being changed (owned); null adds one.
    id: ?[]u8 = null,
    name: nanoui.ui.TextBuffer = .{},
    command: nanoui.ui.TextBuffer = .{},
    icon: usize = 0,
    setup: bool = false,
    err: ?[]const u8 = null,
    saving: bool = false,
    confirm_delete: bool = false,
    /// The name field takes the keys when the dialog opens.
    want_focus: bool = true,

    fn deinit(e: *Editor, gpa: Allocator) void {
        if (e.id) |id| gpa.free(id);
        @import("text_buffer.zig").deinit(&e.name);
        @import("text_buffer.zig").deinit(&e.command);
        e.* = .{};
    }
};

const CommandReview = struct {
    chat: []u8,
    cwd: []u8,
    source: []u8,
    shell: []const u8,
    block: u64,
    want_focus: bool = true,

    fn deinit(r: CommandReview, gpa: Allocator) void {
        gpa.free(r.chat);
        gpa.free(r.cwd);
        gpa.free(r.source);
    }
};

pub const Run = struct {
    terminal: []u8 = &.{},
    name: []u8,
    log: termlog.Log,
    exited: ?i64 = null,
    opening: ?u64 = null,
    watch: ?u64 = null,
    host: ?[]u8 = null,
    chat: ?[]u8 = null,
    block: ?u64 = null,
    want_focus: bool = false,
    writing: ?u64 = null,
    pending_input: std.ArrayList(u8) = .empty,

    pub fn visible(r: Run, chat: ?[]const u8) bool {
        return if (r.chat) |owner| std.mem.eql(u8, owner, chat orelse "") else true;
    }
};

pub const Actions = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    status: Status = .idle,
    list: []Action = &.{},
    error_text: ?[]const u8 = null,
    space: ?[]u8 = null,
    request: ?u64 = null,
    menu: bool = false,
    anchor: ?nanoui.ui.Rect = null,
    editor: ?Editor = null,
    command_review: ?CommandReview = null,
    /// The last action run, by project, for the control's main button.
    last: std.StringHashMapUnmanaged([]u8) = .empty,
    runs: std.ArrayList(Run) = .empty,
    dock_open: bool = false,
    dock_active: usize = 0,

    pub fn init(gpa: Allocator) Actions {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(x: *Actions) void {
        x.arena.deinit();
        if (x.space) |s| x.gpa.free(s);
        if (x.editor) |*e| e.deinit(x.gpa);
        if (x.command_review) |review| review.deinit(x.gpa);
        var it = x.last.iterator();
        while (it.next()) |e| {
            x.gpa.free(e.key_ptr.*);
            x.gpa.free(e.value_ptr.*);
        }
        x.last.deinit(x.gpa);
        for (x.runs.items) |*r| freeRun(x.gpa, r);
        x.runs.deinit(x.gpa);
    }
};

fn freeRun(gpa: Allocator, r: *Run) void {
    gpa.free(r.terminal);
    gpa.free(r.name);
    if (r.host) |dev| gpa.free(dev);
    if (r.chat) |id| gpa.free(id);
    r.pending_input.deinit(gpa);
    r.log.deinit();
}

/// The project whose actions show: the open chat's, when it lives on the
/// project's own device.
pub fn spaceOf(a: *const App) ?[]const u8 {
    const chat = a.findChat(a.selected orelse return null) orelse return null;
    const sid = chat.space_id orelse return null;
    const space = a.findSpace(sid) orelse return null;
    if (space.device_id != null and chat.device_id != null and !std.mem.eql(u8, space.device_id.?, chat.device_id.?)) return null;
    return sid;
}

fn host(a: *const App) ?[]const u8 {
    const dev = (a.findChat(a.selected orelse return null) orelse return null).device_id orelse return null;
    if (a.device_id) |mine| if (std.mem.eql(u8, mine, dev)) return null;
    return dev;
}

/// Lists the open chat's project's actions, when it changed.
pub fn refresh(a: *App) void {
    const x = &a.actions;
    const sid = spaceOf(a) orelse return;
    if (!a.engine.up()) {
        if (x.space) |s| if (!std.mem.eql(u8, s, sid)) {
            a.retireSlice(s);
            x.space = null;
            x.list = &.{};
            x.error_text = null;
            x.status = .idle;
            x.request = null;
        };
        return;
    }
    if (x.space) |s| if (std.mem.eql(u8, s, sid) and x.status != .idle) return;
    if (x.space) |s| a.retireSlice(s);
    x.space = x.gpa.dupe(u8, sid) catch null;
    x.error_text = null;
    x.status = .loading;
    x.request = null;
    x.request = a.send_(requests.listActions(sid, host(a)), .of(App, a, onSnapshot));
}

pub fn disconnected(a: *App) void {
    const x = &a.actions;
    if (x.status == .loading) {
        x.status = .idle;
        x.request = null;
    }
    for (x.runs.items) |*r| {
        if (r.opening != null) {
            r.opening = null;
            failRun(r, "Engine disconnected while opening terminal");
        }
        r.watch = null;
        r.writing = null;
        r.pending_input.clearAndFree(x.gpa);
    }
}

pub fn reconnected(a: *App) void {
    const x = &a.actions;
    if (x.status == .loading or x.status == .unavailable or x.status == .unsupported) {
        x.status = .idle;
        x.error_text = null;
        x.request = null;
    }
    if (a.selected != null) refresh(a);
}

fn onSnapshot(a: *App, id: u64, r: rpc.Reply) void {
    const x = &a.actions;
    if (x.request) |expected| {
        if (id != expected) return;
    } else if (x.status != .loading and (x.editor == null or !x.editor.?.saving)) {
        return;
    }
    x.request = null;
    switch (r) {
        .ok => |v| {
            x.error_text = null;
            a.retireArena(x.arena);
            x.arena = .init(x.gpa);
            const ar = x.arena.allocator();
            var out: std.ArrayList(Action) = .empty;
            const list = if (v == .object) v.object.get("actions") else null;
            if (list) |l| if (l == .array) for (l.array.items) |it| if (it == .object) {
                const o = it.object;
                out.append(ar, .{
                    .id = ar.dupe(u8, str(o, "id") orelse continue) catch continue,
                    .name = ar.dupe(u8, str(o, "name") orelse "") catch continue,
                    .command = ar.dupe(u8, str(o, "command") orelse "") catch continue,
                    .icon = ar.dupe(u8, str(o, "icon") orelse "play") catch continue,
                    .setup = if (o.get("runOnWorktreeCreate")) |s| s == .bool and s.bool else false,
                }) catch {};
            };
            x.list = out.items;
            x.status = .ready;
            if (x.editor) |*e| {
                e.saving = false;
                closeEditor(a);
            }
        },
        .err => |e| {
            if (x.editor) |*ed| {
                ed.saving = false;
                ed.err = x.arena.allocator().dupe(u8, e) catch "Couldn't save the action";
                return a.redraw();
            }
            x.status = if (std.mem.indexOf(u8, e, "unknown method") != null) .unsupported else .unavailable;
            x.error_text = x.arena.allocator().dupe(u8, e) catch null;
        },
        else => {},
    }
    a.redraw();
}

/// The action the control's main button runs: the last one run here, else
/// the first that isn't a worktree's setup, else the first.
pub fn preferred(a: *const App) ?Action {
    const x = &a.actions;
    if (x.list.len == 0) return null;
    if (x.space) |s| if (x.last.get(s)) |id| for (x.list) |act| {
        if (std.mem.eql(u8, act.id, id)) return act;
    };
    for (x.list) |act| if (!act.setup) return act;
    return x.list[0];
}

pub fn openEditor(a: *App, act: ?Action) void {
    const x = &a.actions;
    x.menu = false;
    if (x.editor) |*old| old.deinit(x.gpa);
    var e: Editor = .{};
    if (act) |it| {
        e.id = x.gpa.dupe(u8, it.id) catch null;
        e.name.set(it.name);
        e.command.set(it.command);
        e.setup = it.setup;
        for (icons, 0..) |n, i| if (std.mem.eql(u8, n, it.icon)) {
            e.icon = i;
        };
    }
    x.editor = e;
    a.redraw();
}

pub fn closeEditor(a: *App) void {
    const x = &a.actions;
    if (x.editor) |*e| e.deinit(x.gpa);
    x.editor = null;
    a.redraw();
}

/// "Save action": checked as the engine checks it first.
pub fn save(a: *App) void {
    const x = &a.actions;
    const e = if (x.editor) |*e| e else return;
    const sid = x.space orelse return;
    const name = std.mem.trim(u8, e.name.text(), " \t\n");
    const command = std.mem.trim(u8, e.command.text(), " \t\n");
    e.err = if (name.len == 0)
        "Action name is required"
    else if (name.len > 80)
        "Action name must not exceed 80 characters"
    else if (command.len == 0)
        "Action command is required"
    else
        null;
    if (e.err != null) return a.redraw();
    e.saving = true;
    x.request = null;
    x.request = a.send_(requests.upsertAction(sid, e.id, .{ .name = name, .command = command, .icon = icons[e.icon], .runOnWorktreeCreate = e.setup }, host(a)), .of(App, a, onSnapshot));
}

pub fn delete(a: *App) void {
    const x = &a.actions;
    const e = if (x.editor) |*e| e else return;
    const id = e.id orelse return;
    const sid = x.space orelse return;
    e.saving = true;
    e.confirm_delete = false;
    x.request = null;
    x.request = a.send_(requests.deleteAction(sid, id, host(a)), .of(App, a, onSnapshot));
}

/// Runs `act` in the chat's checkout; its output opens in the dock.
pub fn run(a: *App, act: Action) void {
    const x = &a.actions;
    x.menu = false;
    const sid = x.space orelse return;
    const chat = a.selected orelse return;
    const dev = host(a);
    var r = Run{ .name = x.gpa.dupe(u8, act.name) catch return, .log = .{ .gpa = x.gpa, .palette = a.ansi } };
    r.host = if (dev) |d| x.gpa.dupe(u8, d) catch return freeRun(x.gpa, &r) else null;
    x.runs.append(x.gpa, r) catch return freeRun(x.gpa, &r);
    showRun(a, x.runs.items.len - 1);
    remember(a, sid, act.id);
    const opened = &x.runs.items[x.dock_active];
    opened.opening = a.send_(requests.runAction(sid, chat, act.id, dev), .of(App, a, onRun));
    if (opened.opening == null) failRun(opened, "Could not open terminal");
}

/// Whether the dock has a run to show beside `chat`: its own, or one that
/// belongs to no chat.
pub fn hasVisibleRun(x: *const Actions, chat: ?[]const u8) bool {
    for (x.runs.items) |r| if (r.visible(chat)) return true;
    return false;
}

pub const no_runs_tip = "No terminal or action runs in this chat yet";
const no_runs_notice = "No terminal or action runs in this chat yet. Run a project action to open one.";

/// The terminal and action-runs dock under the chat: the title bar's
/// button, ⌘J (`toggleTerminal`) and the palette's "Toggle terminal". With
/// nothing to show it stays shut and says why instead of opening empty.
pub fn toggleDock(a: *App) void {
    const x = &a.actions;
    if (!hasVisibleRun(x, a.selected)) {
        x.dock_open = false;
        a.setNotice(no_runs_notice);
        return a.redraw();
    }
    x.dock_open = !x.dock_open;
    a.redraw();
}

fn showRun(a: *App, i: usize) void {
    a.actions.dock_active = i;
    a.actions.dock_open = true;
    a.actions.runs.items[i].want_focus = a.actions.runs.items[i].block != null;
    a.redraw();
}

pub fn commandShell(lang: []const u8, source: []const u8) ?[]const u8 {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return null;
    if (source.len > 32 * 1024 or std.mem.trim(u8, source, " \t\n").len == 0) return null;
    for (source) |b| if ((b < 32 and b != '\n' and b != '\t') or b == 127) return null;
    inline for (.{ "sh", "bash", "zsh", "fish", "shell" }) |shell| {
        if (std.ascii.eqlIgnoreCase(lang, shell)) return shell;
    }
    return null;
}

/// Resolve the owner before showing anything executable. Never fall back to
/// another chat, a remote device, or the user's home directory.
pub fn commandCwd(a: *const App, chat_id: []const u8) ?[]const u8 {
    if (!a.engine.up() or !std.mem.eql(u8, a.selected orelse return null, chat_id)) return null;
    const chat = a.findChat(chat_id) orelse return null;
    if (chat.archived or !std.mem.eql(u8, a.device_id orelse return null, chat.device_id orelse return null)) return null;
    if (chat.cwd) |cwd| if (std.fs.path.isAbsolute(cwd)) return cwd;
    const space = a.findSpace(chat.space_id orelse return null) orelse return null;
    if (!std.mem.eql(u8, a.device_id.?, space.device_id orelse return null)) return null;
    return if (std.fs.path.isAbsolute(space.path)) space.path else null;
}

pub fn commandRun(a: *const App, chat: []const u8, block: u64) ?usize {
    for (a.actions.runs.items, 0..) |r, i| {
        if (r.block == block and r.visible(chat)) return i;
    }
    return null;
}

pub fn openCommand(a: *App, chat: []const u8, block: u64, shell: []const u8, source: []const u8) void {
    if (commandRun(a, chat, block)) |i| return showRun(a, i);
    const cwd = commandCwd(a, chat) orelse return;
    reviewCommand(a, chat, cwd, block, shell, source) catch return;
    a.redraw();
}

fn reviewCommand(a: *App, chat: []const u8, cwd: []const u8, block: u64, shell: []const u8, source: []const u8) !void {
    const gpa = a.gpa;
    const owner = try gpa.dupe(u8, chat);
    errdefer gpa.free(owner);
    const dir = try gpa.dupe(u8, cwd);
    errdefer gpa.free(dir);
    const command = try gpa.dupe(u8, source);
    dismissCommand(a);
    a.actions.command_review = .{ .chat = owner, .cwd = dir, .source = command, .shell = shell, .block = block };
}

pub fn dismissCommand(a: *App) void {
    if (a.actions.command_review) |review| review.deinit(a.gpa);
    a.actions.command_review = null;
    a.redraw();
}

pub fn startCommand(a: *App) void {
    const x = &a.actions;
    const review = x.command_review orelse return;
    defer dismissCommand(a);
    const cwd = commandCwd(a, review.chat) orelse return;
    if (!std.mem.eql(u8, cwd, review.cwd)) return;
    var r = Run{ .name = x.gpa.dupe(u8, review.shell) catch return, .log = .{ .gpa = x.gpa, .palette = a.ansi }, .block = review.block };
    r.chat = x.gpa.dupe(u8, review.chat) catch return freeRun(x.gpa, &r);
    x.runs.append(x.gpa, r) catch return freeRun(x.gpa, &r);
    showRun(a, x.runs.items.len - 1);
    const opened = &x.runs.items[x.dock_active];
    opened.opening = a.send_(requests.openCommandTerminal(review.chat, review.cwd, .{ .shell = review.shell, .source = review.source }), .of(App, a, onRun));
    if (opened.opening == null) failRun(opened, "Could not open terminal");
}

pub fn terminalInput(a: *App, r: *Run, bytes: []const u8) void {
    if (r.block == null or r.watch == null or r.exited != null or !r.visible(a.selected) or bytes.len == 0) return;
    if (bytes.len > 64 * 1024 - r.pending_input.items.len) {
        a.setNotice("Terminal input is too large");
        return a.redraw();
    }
    r.pending_input.appendSlice(a.gpa, bytes) catch return;
    flushInput(a, r);
}

fn flushInput(a: *App, r: *Run) void {
    if (r.writing != null or r.watch == null or r.exited != null or r.pending_input.items.len == 0) return;
    // The RPC server dispatches calls concurrently. Wait for each write's
    // acknowledgement so Return (or Ctrl+C) cannot overtake typed bytes.
    const enc = std.base64.standard.Encoder;
    const buf = a.gpa.alloc(u8, enc.calcSize(r.pending_input.items.len)) catch return;
    defer a.gpa.free(buf);
    r.writing = a.send_(requests.writeTerminal(r.terminal, enc.encode(buf, r.pending_input.items)), .of(App, a, onWrite));
    r.pending_input.clearAndFree(a.gpa);
    if (r.writing == null) {
        a.setNotice("Could not send terminal input");
        a.redraw();
    }
}

fn onWrite(a: *App, id: u64, reply: rpc.Reply) void {
    const r = for (a.actions.runs.items) |*run_| {
        if (run_.writing == id) break run_;
    } else return;
    r.writing = null;
    if (reply == .ok) return flushInput(a, r);
    r.pending_input.clearAndFree(a.gpa);
    App.onNotice(a, id, reply);
}

fn remember(a: *App, sid: []const u8, id: []const u8) void {
    const x = &a.actions;
    const v = x.gpa.dupe(u8, id) catch return;
    if (x.last.getPtr(sid)) |old| {
        x.gpa.free(old.*);
        old.* = v;
        return;
    }
    const k = x.gpa.dupe(u8, sid) catch return x.gpa.free(v);
    x.last.put(x.gpa, k, v) catch {
        x.gpa.free(k);
        x.gpa.free(v);
    };
}

fn failRun(r: *Run, msg: []const u8) void {
    r.log.feed("\x1b[31m");
    r.log.feed(msg);
    r.log.feed("\x1b[0m\n");
    r.exited = -1;
}

fn onRun(a: *App, id: u64, r: rpc.Reply) void {
    const x = &a.actions;
    const run_ = for (x.runs.items) |*it| {
        if (it.opening == id) break it;
    } else return;
    run_.opening = null;
    switch (r) {
        .ok => |v| {
            const term = if (v != .object) null else if (run_.block != null) v else v.object.get("terminal");
            const tid = if (term) |t| (if (t == .object) str(t.object, "id") else null) else null;
            if (tid) |terminal| {
                run_.terminal = x.gpa.dupe(u8, terminal) catch return;
                run_.watch = a.send_(requests.subscribeTerminal(run_.terminal, run_.host), .of(App, a, onOutput));
            } else failRun(run_, "Terminal did not return a session ID");
        },
        .err => |e| failRun(run_, e),
        else => {},
    }
    a.redraw();
}

fn onOutput(a: *App, id: u64, r: rpc.Reply) void {
    const x = &a.actions;
    const run_ = for (x.runs.items) |*it| {
        if (it.watch == id) break it;
    } else return;
    switch (r) {
        .item => |v| if (v == .object) {
            const o = v.object;
            const kind = str(o, "type") orelse "";
            if (std.mem.eql(u8, kind, "data")) {
                const b64 = str(o, "data") orelse "";
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(b64) catch return;
                const buf = x.gpa.alloc(u8, n) catch return;
                defer x.gpa.free(buf);
                dec.decode(buf, b64) catch return;
                run_.log.feed(buf);
            } else if (std.mem.eql(u8, kind, "exit")) {
                const code = if (o.get("exitCode")) |c| (if (c == .integer) c.integer else 0) else 0;
                run_.exited = code;
                run_.pending_input.clearAndFree(a.gpa);
                var buf: [64]u8 = undefined;
                run_.log.feed(std.fmt.bufPrint(&buf, "\n\x1b[2m[process exited {d}]\x1b[0m\n", .{code}) catch "");
            }
        },
        .done => {
            run_.watch = null;
            run_.pending_input.clearAndFree(a.gpa);
        },
        .err => |e| {
            run_.watch = null;
            run_.pending_input.clearAndFree(a.gpa);
            run_.log.feed("\nTerminal connection lost: ");
            run_.log.feed(e);
        },
        .ok => {},
    }
    a.redraw();
}

/// Closes a dock tab, ending its program if it still runs.
pub fn closeRun(a: *App, i: usize) void {
    const x = &a.actions;
    if (i >= x.runs.items.len or x.runs.items[i].opening != null) return;
    var r = x.runs.orderedRemove(i);
    if (r.watch) |w| a.engine.cancel(w);
    if (r.terminal.len > 0) a.request(requests.closeTerminal(r.terminal, r.host), .of(App, a, App.onNotice));
    freeRun(x.gpa, &r);
    if (i < x.dock_active) x.dock_active -= 1;
    if (x.dock_active >= x.runs.items.len) x.dock_active = x.runs.items.len -| 1;
    if (x.runs.items.len == 0) x.dock_open = false;
    a.redraw();
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}
