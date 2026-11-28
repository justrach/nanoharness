//! Settings › MCP servers, as the GPUI app's (settings/mcp.rs): the servers
//! graff starts for agents (`ListMcpServers`), each with its state, tool
//! count and origin; Reconnect, Sign in and the switch act through
//! `McpServerAction`, and a row opens to its tools.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const set = @import("view_settings.zig");
const rpc = @import("rpc.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Tool = struct { name: []const u8, description: []const u8 };

/// A server (`McpServerRow`).
pub const Server = struct {
    name: []const u8,
    source: []const u8 = "",
    transport: []const u8 = "",
    origin: []const u8 = "",
    enabled: bool = true,
    state: []const u8 = "",
    problem: ?[]const u8 = null,
    tool_count: usize = 0,
    tools: []Tool = &.{},
};

fn parseServer(a: Allocator, o: json.ObjectMap) ?Server {
    const str = workspace.str;
    var tools: std.ArrayList(Tool) = .empty;
    if (o.get("tools")) |t| if (t == .array) for (t.array.items) |v| if (v == .object) {
        tools.append(a, .{ .name = str(a, v.object, "name") orelse continue, .description = str(a, v.object, "description") orelse "" }) catch {};
    };
    return .{
        .name = str(a, o, "name") orelse return null,
        .source = str(a, o, "source") orelse "",
        .transport = str(a, o, "transport") orelse "",
        .origin = str(a, o, "origin") orelse "",
        .enabled = if (o.get("enabled")) |v| !(v == .bool and !v.bool) else true,
        .state = str(a, o, "state") orelse "",
        // What went wrong: its detail, else its error.
        .problem = str(a, o, "detail") orelse str(a, o, "error"),
        .tool_count = if (o.get("toolCount")) |v| (if (v == .integer and v.integer > 0) @intCast(v.integer) else 0) else 0,
        .tools = tools.items,
    };
}

pub const Servers = workspace.List(Server, parseServer);

/// The page's state, kept between visits as the GPUI app keeps its page.
pub const Mcp = struct {
    phase: enum { idle, loading, recovering, loaded, partial, failed } = .idle,
    servers: Servers,
    failure: std.ArrayList(u8) = .empty,
    /// An action's error, over the list; cleared by a click.
    notice: std.ArrayList(u8) = .empty,
    /// The server an action is running for; "" for Check all.
    busy: ?struct { name: []const u8, call: ?u64 = null } = null,
    open: std.StringHashMapUnmanaged(void) = .empty,
    /// The project (its space id) the last load was for (`McpTarget`);
    /// none for every project, as before the engine was up.
    target: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Mcp {
        return .{ .servers = .init(gpa) };
    }

    pub fn deinit(m: *Mcp, gpa: Allocator) void {
        m.servers.deinit();
        m.failure.deinit(gpa);
        m.notice.deinit(gpa);
        m.endAction(gpa);
        m.closeAll(gpa);
        m.open.deinit(gpa);
        m.target.deinit(gpa);
    }

    fn loading(m: *const Mcp) bool {
        return m.phase == .loading or m.phase == .recovering;
    }

    fn endAction(m: *Mcp, gpa: Allocator) void {
        if (m.busy) |b| gpa.free(b.name);
        m.busy = null;
    }

    fn closeAll(m: *Mcp, gpa: Allocator) void {
        var it = m.open.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        m.open.clearRetainingCapacity();
    }
};

/// A state's words and its dot's colour (`McpServerState`).
pub fn stateLabel(s: []const u8) []const u8 {
    const names = .{
        .{ "ready", "Connected" },       .{ "on_demand", "Starts on first use" }, .{ "connecting", "Connecting" },
        .{ "failed", "Failed" },         .{ "needs_login", "Sign-in required" },  .{ "off", "Off" },
        .{ "opt_in", "Off (optional)" }, .{ "not_started", "Not started" },
    };
    inline for (names) |n| if (std.mem.eql(u8, s, n[0])) return n[1];
    return "Not checked yet";
}

fn stateColor(k: theme.Colors, s: []const u8) ui.Color {
    if (std.mem.eql(u8, s, "ready") or std.mem.eql(u8, s, "on_demand")) return k.success;
    if (std.mem.eql(u8, s, "failed")) return k.danger;
    if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "opt_in") or std.mem.eql(u8, s, "not_started")) return k.muted.alpha(0.4);
    return k.warning;
}

/// The project the list is for: the one picked for new chats when it was
/// loaded (`McpTarget`, `selected_space_row`); none for every project.
fn project(a: *const App) ?workspace.Space {
    return a.findSpace(if (a.mcp.target.items.len > 0) a.mcp.target.items else null);
}

/// A different project lists different servers.
fn retargeted(a: *const App) bool {
    return !std.mem.eql(u8, a.mcp.target.items, a.space orelse "");
}

fn load(a: *App, recovering: bool) void {
    const m = &a.mcp;
    m.notice.clearRetainingCapacity();
    // Without the engine there's no list, and the target stays as it was.
    if (a.engine.up() and retargeted(a)) {
        // A pending action belongs to the previous project, even if it
        // completes after the new list has loaded.
        m.endAction(a.gpa);
        m.closeAll(a.gpa);
        const target = a.space orelse "";
        m.target.ensureTotalCapacity(a.gpa, target.len) catch {
            fail(a, "Could not load project MCP servers");
            return;
        };
        m.target.clearRetainingCapacity();
        m.target.appendSliceAssumeCapacity(target);
    }
    m.phase = if (recovering) .recovering else .loading;
    const handler: rpc.Handler = .of(App, a, onList);
    const call = if (project(a)) |p|
        a.engine.call("ListMcpServers", .{ .cwd = p.path }, handler)
    else
        a.engine.call("ListMcpServers", rpc.empty, handler);
    if (call == null and m.loading()) onList(a, 0, .{ .err = "Could not send MCP list request" });
}

fn onList(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| if (a.mcp.servers.replace(v)) |_| {
            a.mcp.phase = .loaded;
            a.mcp.failure.clearRetainingCapacity();
        } else |_| fail(a, "Unexpected reply"),
        .err => |e| fail(a, if (std.mem.eql(u8, e, "not connected")) "Engine not connected" else e),
        else => {},
    }
    a.redraw();
}

fn fail(a: *App, why: []const u8) void {
    a.mcp.phase = if (a.mcp.phase == .recovering) .partial else .failed;
    a.mcp.failure.clearRetainingCapacity();
    a.mcp.failure.appendSlice(a.gpa, why) catch {};
}

fn act(a: *App, action: []const u8, name: ?[]const u8) void {
    const m = &a.mcp;
    if (m.busy != null or m.loading() or retargeted(a)) return;
    m.notice.clearRetainingCapacity();
    m.busy = .{ .name = a.gpa.dupe(u8, name orelse "") catch return };
    const call = if (project(a)) |p|
        a.engine.call("McpServerAction", .{ .action = action, .name = name, .cwd = p.path }, .of(App, a, onAction))
    else
        a.engine.call("McpServerAction", .{ .action = action, .name = name }, .of(App, a, onAction));
    // Failed sends can reply synchronously, clearing busy before call returns.
    if (m.busy) |*b| {
        if (call) |id| b.call = id else onAction(a, 0, .{ .err = "Could not send MCP action" });
    }
}

fn onAction(a: *App, id: u64, r: rpc.Reply) void {
    const m = &a.mcp;
    const busy = m.busy orelse return;
    if (busy.call) |call| if (call != id) return;
    const check_all = busy.name.len == 0;
    m.endAction(a.gpa);
    if (retargeted(a)) return a.redraw();
    switch (r) {
        .ok => |v| if (v != .array) {
            m.notice.appendSlice(a.gpa, "Unexpected reply") catch {};
        } else if (check_all and (m.phase == .failed or m.phase == .partial)) {
            // graff reconnect --all returns only enabled servers. Keep those
            // results, but reload the full list to include switched-off ones.
            m.servers.replace(v) catch {
                m.notice.appendSlice(a.gpa, "Unexpected reply") catch {};
                return a.redraw();
            };
            load(a, true);
        } else merge(a, v) catch {
            m.notice.appendSlice(a.gpa, "Unexpected reply") catch {};
        },
        .err => |e| m.notice.appendSlice(a.gpa, e) catch {},
        else => {},
    }
    a.redraw();
}

/// The servers an action touched, in place by name; new ones after.
fn merge(a: *App, reply: json.Value) !void {
    if (a.mcp.phase != .loaded and a.mcp.phase != .partial) return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var rows: json.Array = .init(ar);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (reply.array.items) |v| if (v == .object) if (v.object.get("name")) |n| if (n == .string) seen.put(ar, n.string, {}) catch {};
    for (a.mcp.servers.items) |s| {
        if (seen.contains(s.name)) {
            for (reply.array.items) |v| if (v == .object) if (v.object.get("name")) |n| if (n == .string and std.mem.eql(u8, n.string, s.name)) try rows.append(v);
        } else try rows.append(try asJson(ar, s));
    }
    for (reply.array.items) |v| if (v == .object) if (v.object.get("name")) |n| if (n == .string) {
        var known = false;
        for (a.mcp.servers.items) |s| known = known or std.mem.eql(u8, s.name, n.string);
        if (!known) try rows.append(v);
    };
    try a.mcp.servers.replace(.{ .array = rows });
}

fn asJson(ar: Allocator, s: Server) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(ar, "name", .{ .string = s.name });
    try o.put(ar, "source", .{ .string = s.source });
    try o.put(ar, "transport", .{ .string = s.transport });
    try o.put(ar, "origin", .{ .string = s.origin });
    try o.put(ar, "enabled", .{ .bool = s.enabled });
    try o.put(ar, "state", .{ .string = s.state });
    if (s.problem) |p| try o.put(ar, "detail", .{ .string = p });
    try o.put(ar, "toolCount", .{ .integer = @intCast(s.tool_count) });
    var tools: json.Array = .init(ar);
    for (s.tools) |t| {
        var to: json.ObjectMap = .empty;
        try to.put(ar, "name", .{ .string = t.name });
        try to.put(ar, "description", .{ .string = t.description });
        try tools.append(.{ .object = to });
    }
    try o.put(ar, "tools", .{ .array = tools });
    return .{ .object = o };
}

const phi: f32 = 1.618;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.mcp.phase == .idle or (!a.mcp.loading() and a.engine.up() and retargeted(a))) load(a, false);
    const m = &a.mcp;
    {
        const h = ui.div(c).row().wFull().itemsCenter();
        defer h.end();
        set.header(c, k, "MCP servers", if (m.phase == .loaded and m.servers.items.len > 0) m.servers.items.len else null);
        ui.spacer(c);
        const checking = if (m.busy) |b| b.name.len == 0 else false;
        const actionable = m.busy == null and !m.loading() and !retargeted(a);
        var b = ui.div(c).row().px(11).py(7).gap(6).itemsCenter().rounded(8).border(k.border).borderW(1);
        b = if (actionable) b.hover(k.ink(0.06)) else b.opacity(0.5);
        defer b.end();
        const hot = b.hovered();
        icons.icon(c, .refresh, 14, k.muted, 0);
        ui.text(c, if (checking) "Checking…" else "Check all", .{ .size = 12, .line_height = 12 * phi, .color = if (hot) k.text else k.muted });
        if (b.clicked() and actionable) act(a, "reconnect", null);
    }
    const copy = if (project(a)) |p|
        c.print("Servers graff starts for agents in {s}: this project's .mcp.json plus your user-level and imported servers. Reconnect runs a fresh handshake and refreshes the tools the next turn sees.", .{p.name})
    else
        "Servers graff starts for agents in every project: your user-level and imported servers. Pick a project to include its .mcp.json. Reconnect runs a fresh handshake and refreshes the tools the next turn sees.";
    set.subtitle(c, k, copy, false);
    if (m.notice.items.len > 0) if (errorStrip(c, k, m.notice.items)) m.notice.clearRetainingCapacity();
    switch (m.phase) {
        .idle, .loading => {
            set.space(c, 24);
            ui.text(c, "Loading MCP servers…", .{ .size = 12.5, .line_height = 12.5 * phi, .color = k.muted.alpha(0.6) });
        },
        .recovering => {
            set.subtitle(c, k, "Loading the full list…", false);
            if (!retargeted(a) and m.servers.items.len > 0) list(c, a, k);
        },
        .failed, .partial => {
            const partial = m.phase == .partial;
            const message = if (partial)
                c.print("Couldn't load the full list. Only Check all results are available: {s}", .{m.failure.items})
            else
                m.failure.items;
            _ = errorStrip(c, k, message);
            set.space(c, 8);
            {
                var r = ui.div(c).row().px(10).py(6).rounded(8);
                r = if (m.busy == null) r.hover(k.ink(0.06)) else r.opacity(0.5);
                defer r.end();
                ui.text(c, "Retry", .{ .size = 12, .line_height = 12 * phi, .color = k.muted });
                if (r.clicked() and m.busy == null) load(a, partial and !retargeted(a));
            }
            if (partial and m.servers.items.len > 0) list(c, a, k);
        },
        .loaded => if (m.servers.items.len == 0) empty(c, k) else list(c, a, k),
    }
}

/// `error_strip`: red-tinted, a warning triangle, the words. True when
/// clicked.
pub fn errorStrip(c: *ui.Context, k: theme.Colors, message: []const u8) bool {
    set.space(c, 16);
    const s = ui.div(c).row().wFull().px(17).py(13).gap(8).rounded(12).border(k.danger.alpha(0.2)).borderW(1).bg(k.danger.alpha(0.06));
    defer s.end();
    {
        const ic = ui.div(c).column().pt(2);
        defer ic.end();
        icons.icon(c, .@"danger-triangle", 16, k.danger_muted.alpha(0.9), 0);
    }
    // Wrapped text needs its width up front: the strip less its border,
    // insets, icon and gap (at zero it took a line a word).
    const w = ui.div(c).column().w(@max(set.inner_w - 2 - 2 * 17 - 16 - 8, 80));
    {
        defer w.end();
        ui.text(c, message, .{ .size = 12.5, .line_height = 12.5 * phi, .wrap = true, .color = k.danger_muted.alpha(0.9) });
    }
    return s.clicked();
}

fn empty(c: *ui.Context, k: theme.Colors) void {
    set.space(c, 96);
    const e = ui.div(c).column().wFull().itemsCenter();
    defer e.end();
    icons.icon(c, .@"remote-server", 28, k.muted.alpha(0.2), 0);
    set.space(c, 12);
    ui.text(c, "No MCP servers configured", .{ .size = 14, .line_height = 14 * phi, .color = k.muted.alpha(0.5) });
    set.space(c, 4);
    ui.text(c, "Add one with `graff mcp add`, or ask an agent to.", .{ .size = 12, .line_height = 12 * phi, .color = k.muted.alpha(0.4) });
}

fn list(c: *ui.Context, a: *App, k: theme.Colors) void {
    set.space(c, 16);
    const cd = ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell);
    defer cd.end();
    for (a.mcp.servers.items, 0..) |s, ix| {
        ui.key(c, s.name);
        if (ix > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        server(c, a, k, s);
    }
}

fn server(c: *ui.Context, a: *App, k: theme.Colors, s: Server) void {
    const m = &a.mcp;
    const actionable = m.busy == null and !m.loading() and !retargeted(a);
    const busy = if (m.busy) |b| (b.name.len == 0 and s.enabled) or std.mem.eql(u8, b.name, s.name) else false;
    const open = m.open.contains(s.name);
    const box = ui.div(c).column().wFull();
    defer box.end();
    const r = ui.div(c).row().wFull().px(20).py(14).gap(14).itemsCenter().hover(k.hover);
    {
        defer r.end();
        set.tile(c, k, if (std.mem.eql(u8, s.transport, "http")) .@"remote-server" else .terminal);
        // Wrapped text needs its width up front: the row less its edge,
        // insets, tile, the buttons after and the gaps (at zero, the
        // problem's line took a word a line and the row grew that tall).
        const sign_in = std.mem.eql(u8, s.state, "needs_login");
        var trailing: f32 = 14 + 40;
        if (sign_in) trailing += 14 + buttonW(c, if (busy) "Signing in…" else "Sign in");
        if (s.enabled) trailing += 14 + buttonW(c, if (busy) "Connecting…" else "Reconnect");
        const words_w = @max(set.inner_w - 2 - 2 * 20 - 36 - 14 - trailing, 80);
        const words = ui.div(c).column().w(words_w);
        {
            defer words.end();
            const t = ui.div(c).row().gap(8).itemsCenter();
            {
                defer t.end();
                ui.text(c, s.name, set.st(c, 13, .{ .weight = .medium, .color = k.text }));
                if (s.source.len > 0) badge(c, k, s.source);
            }
            set.space(c, 1);
            const meta = ui.div(c).row().gap(8).itemsCenter();
            {
                defer meta.end();
                const st = set.st(c, 12, .{ .color = k.muted.alpha(0.65) });
                const dotrow = ui.div(c).row().gap(6).itemsCenter();
                {
                    defer dotrow.end();
                    _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = stateColor(k, s.state) }, .none, null);
                    ui.text(c, stateLabel(s.state), st);
                }
                if (s.tool_count > 0) {
                    ui.text(c, "·", set.st(c, 12, .{ .color = k.muted.alpha(0.3) }));
                    ui.text(c, c.print("{d} {s}", .{ s.tool_count, if (s.tool_count == 1) "tool" else "tools" }), st);
                }
                if (s.origin.len > 0) {
                    ui.text(c, "·", set.st(c, 12, .{ .color = k.muted.alpha(0.3) }));
                    ui.text(c, s.origin, st);
                }
            }
            if (s.problem) |p| {
                set.space(c, 4);
                ui.text(c, p, .{ .size = 12, .line_height = 12 * phi, .wrap = true, .color = k.danger_muted.alpha(0.9) });
            }
        }
        if (sign_in) {
            if (button(c, k, .@"key-minimalistic", if (busy) "Signing in…" else "Sign in", !actionable) and actionable) act(a, "login", s.name);
        }
        if (s.enabled) if (button(c, k, .restart, if (busy) "Connecting…" else "Reconnect", !actionable) and actionable) act(a, "reconnect", s.name);
        if (set.toggle(c, k, s.enabled, actionable)) act(a, if (s.enabled) "disable" else "enable", s.name);
    }
    if (r.clicked()) toggleOpen(a, s.name);
    if (!open) return;
    const tools = ui.div(c).column().wFull().pl(70).pr(20).pb(12).gap(4);
    defer tools.end();
    if (s.tools.len == 0) {
        ui.text(c, "No tools known yet. Reconnect lists them.", .{ .size = 12, .line_height = 12 * phi, .color = k.muted.alpha(0.6) });
        return;
    }
    for (s.tools) |t| {
        const row = ui.div(c).row().wFull().gap(8);
        defer row.end();
        ui.text(c, t.name, .{ .size = 12, .line_height = 12 * phi, .mono = true, .color = k.text });
        const d = ui.div(c).row().grow().w(0).clip();
        defer d.end();
        ui.text(c, t.description, .{ .size = 12, .line_height = 12 * phi, .color = k.muted.alpha(0.7) });
    }
}

fn toggleOpen(a: *App, name: []const u8) void {
    if (a.mcp.open.fetchRemove(name)) |kv| return a.gpa.free(kv.key);
    const k = a.gpa.dupe(u8, name) catch return;
    a.mcp.open.put(a.gpa, k, {}) catch a.gpa.free(k);
}

/// `badge`: a quiet pill.
pub fn badge(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const b = ui.div(c).row().px(9).py(3).roundedFull().border(k.border).borderW(1);
    defer b.end();
    ui.text(c, label, .{ .size = 10.5, .line_height = 10.5 * phi, .color = k.muted });
}

/// `action_button`: a bordered ghost action with its icon.
/// A `button`'s width: 11 in each side (10 and its border), the glyph, the
/// gap and the words.
fn buttonW(c: *ui.Context, label: []const u8) f32 {
    return 2 * 11 + 14 + 6 + c.text.width(label, .{ .size = 12 });
}

fn button(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8, busy: bool) bool {
    var b = ui.div(c).row().px(11).py(7).gap(6).itemsCenter().rounded(8).border(k.border).borderW(1).hover(k.ink(0.06));
    if (busy) b = b.opacity(0.5);
    defer b.end();
    icons.icon(c, icon, 14, k.muted, 0);
    ui.text(c, label, .{ .size = 12, .line_height = 12 * phi, .color = if (b.hovered()) k.text else k.muted });
    return b.clicked();
}

const testing = std.testing;

test "settings audit MCP Check all recovers a failed list without losing switched-off servers or expansion" {
    const Harness = @import("tests_ui_tab_strip.zig").Harness;
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.engine.scene = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"ListMcpServers":{"$seq":[{"$err":"Synthetic MCP list failure"},
        \\  [{"name":"demo-tools","state":"ready","toolCount":1,"tools":[{"name":"first-tool"}]},
        \\   {"name":"demo-off","state":"off","enabled":false}]]},
        \\ "McpServerAction":{"$seq":[[{"name":"demo-tools","state":"ready","toolCount":1,"tools":[{"name":"first-tool"}]}],
        \\   [{"name":"demo-tools","state":"ready","toolCount":1,"tools":[{"name":"updated-tool"}]}]]}}
    , .{});
    h.a.engine.state = .connected;
    h.a.settings.section = .mcp;
    set.open(&h.a);
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("Synthetic MCP list failure"));

    try h.t.clickText("Check all");
    h.t.advance(0.2);
    try testing.expect(!h.t.hasText("Synthetic MCP list failure"));
    try testing.expect(h.t.hasText("demo-tools"));
    try testing.expect(h.t.hasText("demo-off"));
    try testing.expect(!h.t.hasText("Retry"));

    try h.t.clickText("demo-tools");
    h.t.advance(0.1);
    try testing.expect(h.t.hasText("first-tool"));
    try h.t.clickText("Check all");
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("updated-tool"));
    try testing.expect(h.t.hasText("demo-off"));
}

test "settings audit MCP shows checked rows when the full-list recovery fails and Retry preserves expansion" {
    const Harness = @import("tests_ui_tab_strip.zig").Harness;
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.engine.scene = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"ListMcpServers":{"$seq":[{"$err":"Synthetic initial failure"},{"$err":"Synthetic recovery failure"},
        \\  [{"name":"demo-tools","state":"on_demand","tools":[{"name":"demo-tool"}]},{"name":"demo-off","enabled":false}]]},
        \\ "McpServerAction":[{"name":"demo-tools","state":"ready","tools":[{"name":"demo-tool"}]}]}
    , .{});
    h.a.engine.state = .connected;
    h.a.settings.section = .mcp;
    set.open(&h.a);
    h.t.advance(0.2);
    try h.t.clickText("Check all");
    h.t.advance(0.2);
    try testing.expect(!h.t.hasText("Synthetic initial failure"));
    try testing.expect(h.t.containsText("Synthetic recovery failure"));
    try testing.expect(h.t.hasText("demo-tools"));
    try testing.expect(!h.t.hasText("No MCP servers configured"));

    try h.t.clickText("demo-tools");
    h.t.advance(0.1);
    try testing.expect(h.t.hasText("demo-tool"));
    try h.t.clickText("Retry");
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("demo-tool"));
    try testing.expect(h.t.hasText("demo-off"));
    try testing.expect(!h.t.containsText("Synthetic recovery failure"));
}

test "settings audit MCP disabled switch does not toggle the server disclosure" {
    const Harness = @import("tests_ui_tab_strip.zig").Harness;
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.engine.scene = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"ListMcpServers":[{"name":"demo-tools","state":"ready"}],
        \\ "McpServerAction":[{"name":"demo-tools","state":"ready"}]}
    , .{});
    h.a.engine.state = .connected;
    h.a.settings.section = .mcp;
    set.open(&h.a);
    h.t.advance(0.2);
    h.a.mcp.busy = .{ .name = try testing.allocator.dupe(u8, "demo-tools") };
    h.t.advance(0.2);
    const track = for (h.t.ctx.nodes.items) |node| {
        if (node.rect.w == 32 and node.rect.h == 18 and node.rect.x > h.t.size.w / 2) break node.rect;
    } else return error.MissingServerSwitch;
    const before = h.a.engine.sent.items.len;
    h.t.click(track.x + 16, track.y + 9);
    try testing.expect(!h.a.mcp.open.contains("demo-tools"));
    h.t.click(track.x + 16, track.y - 4);
    try testing.expectEqual(before, h.a.engine.sent.items.len);
    try testing.expect(!h.a.mcp.open.contains("demo-tools"));
    try h.t.clickText("demo-tools");
    try testing.expect(h.a.mcp.open.contains("demo-tools"));
}

test "settings audit MCP ignores Check all replies from the previous project" {
    const Harness = @import("tests_ui_tab_strip.zig").Harness;
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.select(null, "local-project");
    h.a.engine.scene = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"ListMcpServers":{"$seq":[[{"name":"local-tools"}],[{"name":"remote-tools"}]]},
        \\ "McpServerAction":[{"name":"local-action-result"}]}
    , .{});
    h.a.engine.state = .connected;
    h.a.settings.section = .mcp;
    set.open(&h.a);
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("local-tools"));

    // Send the same action directly so we can hold the reply before the
    // tester renders another frame and pumps the scene.
    act(&h.a, "reconnect", null);
    const held = try h.a.engine.queued.toOwnedSlice(testing.allocator);
    defer {
        for (held) |frame| testing.allocator.free(frame);
        testing.allocator.free(held);
    }
    try testing.expectEqual(@as(usize, 1), held.len);
    const action = try json.parseFromSlice(json.Value, testing.allocator, h.a.engine.sent.items[h.a.engine.sent.items.len - 1], .{});
    defer action.deinit();
    try testing.expectEqualStrings("McpServerAction", action.value.object.get("method").?.string);
    try testing.expectEqualStrings("/synthetic/fieldnotes", action.value.object.get("params").?.object.get("cwd").?.string);

    h.a.select(null, "remote-project");
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("remote-tools"));
    try h.a.engine.mux.dispatch(held[0]);
    h.t.advance(0.2);
    try testing.expect(h.t.hasText("remote-tools"));
    try testing.expect(!h.t.hasText("local-action-result"));
}

test "servers read as the engine sends them, and state names as the GPUI app's" {
    var l: Servers = .init(testing.allocator);
    defer l.deinit();
    const v = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"name":"codedb","source":"global","transport":"stdio","origin":"codedb","enabled":true,"state":"on_demand","toolCount":1,"tools":[{"name":"search","description":"Find code"}]},
        \\ {"name":"lic","state":"failed","error":"lic: not licensed","toolCount":0,"tools":[]},
        \\ {"name":"off","enabled":false,"state":"off"}]
    , .{});
    defer v.deinit();
    try l.replace(v.value);
    try testing.expectEqual(@as(usize, 3), l.items.len);
    try testing.expectEqualStrings("Starts on first use", stateLabel(l.items[0].state));
    try testing.expectEqualStrings("search", l.items[0].tools[0].name);
    try testing.expectEqualStrings("lic: not licensed", l.items[1].problem.?);
    try testing.expect(!l.items[2].enabled);
    try testing.expectEqualStrings("Not checked yet", stateLabel("whatever"));
}
