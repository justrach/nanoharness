//! Managed Native Flint (`justrach/nanoattention`) status model and pure
//! unified-memory rules for Settings › Agents (macOS Apple Silicon only).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const name = "Native Flint";
pub const provider = "nanoattention";
pub const model = provider ++ "/flint";
pub const download_label = "Download weights";
pub const download_url = "https://codegraff.com/flint";
pub const description = "Run Flint INT4 locally on Apple Silicon Metal with managed start and stop. Exposed to Graff as " ++ model ++ " while running.";
pub const setup = "Download the INT4 weights, pick a context window that fits your Mac's unified memory, then turn the local server on. Choose " ++ model ++ " from Graff's model picker.";

pub const context_presets = [_]u32{ 8_192, 16_384, 32_768, 65_536, 131_072 };

pub const State = enum {
    stopped,
    starting,
    running,
    @"error",

    pub fn parse(raw: []const u8) State {
        if (std.mem.eql(u8, raw, "starting")) return .starting;
        if (std.mem.eql(u8, raw, "running")) return .running;
        if (std.mem.eql(u8, raw, "error")) return .@"error";
        return .stopped;
    }
};

pub const RamTier = enum {
    unsupported_platform,
    insufficient_ram,
    tight,
    good,
    optimal,

    pub fn parse(raw: []const u8) RamTier {
        if (std.mem.eql(u8, raw, "insufficient_ram")) return .insufficient_ram;
        if (std.mem.eql(u8, raw, "tight")) return .tight;
        if (std.mem.eql(u8, raw, "good")) return .good;
        if (std.mem.eql(u8, raw, "optimal")) return .optimal;
        return .unsupported_platform;
    }
};

pub const Status = struct {
    platform_supported: bool = false,
    ram_supported: bool = false,
    ram_tier: RamTier = .unsupported_platform,
    total_ram_gb: u32 = 0,
    min_ram_gb: u32 = 32,
    recommended_context: u32 = 0,
    max_context: u32 = 0,
    estimated_footprint_gb: u32 = 25,
    binary_available: bool = false,
    checkpoint_valid: bool = false,
    state: State = .stopped,
    context: u32 = 32_768,
    checkpoint_dir: std.ArrayList(u8) = .empty,
    checkpoint_hint: std.ArrayList(u8) = .empty,
    endpoint_url: std.ArrayList(u8) = .empty,
    err: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Status, gpa: Allocator) void {
        self.checkpoint_dir.deinit(gpa);
        self.checkpoint_hint.deinit(gpa);
        self.endpoint_url.deinit(gpa);
        self.err.deinit(gpa);
    }

    pub fn replaceFromJson(self: *Status, gpa: Allocator, v: json.Value) !void {
        if (v != .object) return error.UnexpectedShape;
        const o = v.object;
        self.platform_supported = boolField(o, "platformSupported", false);
        self.ram_supported = boolField(o, "ramSupported", false);
        self.ram_tier = RamTier.parse(strField(o, "ramTier") orelse "unsupported_platform");
        self.total_ram_gb = u32Field(o, "totalRamGb", 0);
        self.min_ram_gb = u32Field(o, "minRamGb", 32);
        self.recommended_context = u32Field(o, "recommendedContext", 0);
        self.max_context = u32Field(o, "maxContext", 0);
        self.estimated_footprint_gb = u32Field(o, "estimatedFootprintGb", 25);
        self.binary_available = boolField(o, "binaryAvailable", false);
        self.checkpoint_valid = boolField(o, "checkpointValid", false);
        self.state = State.parse(strField(o, "state") orelse "stopped");
        self.context = u32Field(o, "context", self.recommended_context);
        try setSlice(gpa, &self.checkpoint_dir, strField(o, "checkpointDir") orelse "");
        try setSlice(gpa, &self.checkpoint_hint, strField(o, "checkpointHint") orelse "");
        try setSlice(gpa, &self.endpoint_url, strField(o, "endpointUrl") orelse "");
        try setSlice(gpa, &self.err, strField(o, "error") orelse "");
    }
};

fn boolField(o: json.ObjectMap, key: []const u8, fallback: bool) bool {
    const val = o.get(key) orelse return fallback;
    return if (val == .bool) val.bool else fallback;
}

fn u32Field(o: json.ObjectMap, key: []const u8, fallback: u32) u32 {
    const val = o.get(key) orelse return fallback;
    if (val != .integer or val.integer < 0) return fallback;
    return std.math.cast(u32, val.integer) orelse fallback;
}

fn strField(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = o.get(key) orelse return null;
    return if (val == .string) val.string else null;
}

fn setSlice(gpa: Allocator, dst: *std.ArrayList(u8), src: []const u8) !void {
    dst.clearRetainingCapacity();
    try dst.appendSlice(gpa, src);
}

/// Estimated Apple Silicon unified memory footprint (GB) for Flint INT4
/// (~22.6 GB weights + FP32 KV cache + runtime buffers). Mirrors
/// `crates/engine/src/flint_policy.rs`.
pub fn estimatedFootprintGb(context: u32) u32 {
    if (context <= 8_192) return 25;
    if (context <= 16_384) return 27;
    if (context <= 32_768) return 31;
    if (context <= 65_536) return 37;
    return 49;
}

pub fn contextLabel(context: u32) []const u8 {
    return switch (context) {
        8_192 => "8K",
        16_384 => "16K",
        32_768 => "32K",
        65_536 => "64K",
        131_072 => "128K",
        else => "32K",
    };
}

pub fn effectiveContext(st: *const Status, chosen: ?u32) u32 {
    if (st.state == .running and st.context > 0) return st.context;
    if (chosen) |c| {
        if (c > 0 and (st.max_context == 0 or c <= st.max_context)) return c;
    }
    if (st.context > 0 and (st.max_context == 0 or st.context <= st.max_context)) return st.context;
    if (st.recommended_context > 0) return st.recommended_context;
    return 8_192;
}

pub fn canStart(st: *const Status, selected_context: u32, has_custom_dir: bool) bool {
    if (!st.platform_supported or !st.ram_supported or !st.binary_available) return false;
    if (!st.checkpoint_valid and !has_custom_dir) return false;
    return selected_context > 0 and selected_context <= st.max_context;
}

pub fn ramFraction(st: *const Status, selected_context: u32) f32 {
    if (st.total_ram_gb == 0) return 0;
    const est: f32 = @floatFromInt(estimatedFootprintGb(selected_context));
    const total: f32 = @floatFromInt(st.total_ram_gb);
    return std.math.clamp(est / total, 0.0, 1.0);
}

pub fn statusBadge(st: *const Status, busy: bool) []const u8 {
    if (busy) return if (st.state == .running) "Stopping…" else "Starting…";
    return switch (st.state) {
        .running => "Running",
        .starting => "Starting…",
        .@"error" => "Error",
        .stopped => if (!st.platform_supported)
            "Apple Silicon only"
        else if (!st.ram_supported)
            "Needs 32 GB RAM"
        else if (!st.binary_available)
            "Runtime missing"
        else
            "Off",
    };
}

pub fn ramSummary(buf: []u8, st: *const Status, selected_context: u32) []const u8 {
    if (!st.platform_supported) return "Requires macOS on Apple Silicon (arm64)";
    const est = estimatedFootprintGb(selected_context);
    if (!st.ram_supported) {
        return std.fmt.bufPrint(buf, "{d} GB unified memory · needs at least {d} GB (~{d} GB minimum)", .{
            st.total_ram_gb,
            st.min_ram_gb,
            estimatedFootprintGb(8_192),
        }) catch "Insufficient unified memory";
    }
    return std.fmt.bufPrint(buf, "{d} GB unified memory · ~{d} GB estimated for {s} context", .{
        st.total_ram_gb,
        est,
        contextLabel(selected_context),
    }) catch "Unified memory ready";
}

pub fn ramAdvice(st: *const Status) []const u8 {
    return switch (st.ram_tier) {
        .unsupported_platform => "Native Flint runs locally on Apple Silicon Macs only for now.",
        .insufficient_ram => "Flint INT4 loads ~22.6 GB of weights plus KV cache. At least 32 GB of unified memory is required.",
        .tight => "Tight fit on 32 GB Macs — close memory-heavy apps before starting. Context is capped at 16K.",
        .good => "Fits comfortably in unified memory up to 64K context (32K recommended).",
        .optimal => "Full unified memory headroom for Flint INT4 across 8K–128K context.",
    };
}

test "Native Flint setup links to public weights and names the live route" {
    const testing = std.testing;
    try testing.expectEqualStrings("https://codegraff.com/flint", download_url);
    try testing.expectEqualStrings("nanoattention/flint", model);
    try testing.expect(std.mem.indexOf(u8, setup, model) != null);
}

test "Native Flint RAM guard blocks under 32 GB and caps 32 GB Macs at 16K" {
    const testing = std.testing;
    var low: Status = .{
        .platform_supported = true,
        .ram_supported = false,
        .ram_tier = .insufficient_ram,
        .total_ram_gb = 16,
        .min_ram_gb = 32,
        .max_context = 0,
        .binary_available = true,
        .checkpoint_valid = true,
    };
    try testing.expect(!canStart(&low, 8_192, false));
    try testing.expectEqualStrings("Needs 32 GB RAM", statusBadge(&low, false));

    var tight: Status = .{
        .platform_supported = true,
        .ram_supported = true,
        .ram_tier = .tight,
        .total_ram_gb = 32,
        .min_ram_gb = 32,
        .recommended_context = 8_192,
        .max_context = 16_384,
        .binary_available = true,
        .checkpoint_valid = true,
    };
    try testing.expect(canStart(&tight, 8_192, false));
    try testing.expect(canStart(&tight, 16_384, false));
    try testing.expect(!canStart(&tight, 32_768, false));
    try testing.expect(ramFraction(&tight, 8_192) > 0.75);
}

test "Native Flint parses engine status JSON payload" {
    const testing = std.testing;
    const raw =
        \\{"platformSupported":true,"ramSupported":true,"ramTier":"optimal","totalRamGb":128,"minRamGb":32,"recommendedContext":65536,"maxContext":131072,"estimatedFootprintGb":37,"binaryAvailable":true,"checkpointDir":"/tmp/flint","checkpointValid":true,"state":"running","context":65536,"endpointUrl":"http://127.0.0.1:8080/v1/chat/completions"}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{});
    defer parsed.deinit();
    var st: Status = .{};
    defer st.deinit(testing.allocator);
    try st.replaceFromJson(testing.allocator, parsed.value);
    try testing.expect(st.platform_supported);
    try testing.expect(st.ram_supported);
    try testing.expectEqual(RamTier.optimal, st.ram_tier);
    try testing.expectEqual(State.running, st.state);
    try testing.expectEqual(@as(u32, 65_536), st.context);
    try testing.expectEqualStrings("/tmp/flint", st.checkpoint_dir.items);
    try testing.expectEqualStrings("Running", statusBadge(&st, false));
}
