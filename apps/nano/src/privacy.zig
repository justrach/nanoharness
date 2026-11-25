//! Product-telemetry, crash-upload, and background-network killswitches.
//! Rules live in `protocol/privacy-killswitch.json`.
const std = @import("std");

pub const Decision = struct {
    do_not_track: bool,
    offline: bool,
    product_telemetry: bool,
    crash_upload: bool,
    background_network: bool,
    create_telemetry_id: bool,
};

pub const Env = struct {
    dnt: ?[]const u8 = null,
    offline: ?[]const u8 = null,

    pub fn fromMap(map: ?*const std.process.Environ.Map) Env {
        return .{
            .dnt = if (map) |m| m.get("DO_NOT_TRACK") else null,
            .offline = if (map) |m| m.get("HARNESS_OFFLINE") else null,
        };
    }

    pub fn fromGet(dnt: ?[]const u8, offline: ?[]const u8) Env {
        return .{ .dnt = dnt, .offline = offline };
    }
};

pub fn flagOn(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return false, " \t\r\n");
    var buf: [8]u8 = undefined;
    if (v.len > buf.len) return false;
    const low = std.ascii.lowerString(&buf, v);
    return std.mem.eql(u8, low, "1") or std.mem.eql(u8, low, "true") or std.mem.eql(u8, low, "yes");
}

pub fn decide(consent: bool, crash_consent: bool, env: Env) Decision {
    const do_not_track = flagOn(env.dnt);
    const offline = flagOn(env.offline);
    const blocked = do_not_track or offline;
    return .{
        .do_not_track = do_not_track,
        .offline = offline,
        .product_telemetry = consent and !blocked,
        .crash_upload = crash_consent and !blocked,
        .background_network = !blocked,
        .create_telemetry_id = consent and !blocked,
    };
}

pub fn productTelemetryAllowed(consent: bool, map: ?*const std.process.Environ.Map) bool {
    return decide(consent, false, .fromMap(map)).product_telemetry;
}

pub fn backgroundNetworkAllowed(map: ?*const std.process.Environ.Map) bool {
    return decide(true, true, .fromMap(map)).background_network;
}

pub fn backgroundNetworkAllowedGet(dnt: ?[]const u8, offline: ?[]const u8) bool {
    return decide(true, true, .fromGet(dnt, offline)).background_network;
}

test "privacy killswitch matches protocol vectors" {
    const path = @import("parity_options").privacy_killswitch;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expect(cases.len > 0);
    for (cases) |case_val| {
        const case = case_val.object;
        const env = case.get("env").?.object;
        const expect = case.get("expect").?.object;
        const got = decide(case.get("consent").?.bool, case.get("crashConsent").?.bool, .fromGet(
            if (env.get("DO_NOT_TRACK")) |v| v.string else null,
            if (env.get("HARNESS_OFFLINE")) |v| v.string else null,
        ));
        try std.testing.expectEqual(expect.get("doNotTrack").?.bool, got.do_not_track);
        try std.testing.expectEqual(expect.get("offline").?.bool, got.offline);
        try std.testing.expectEqual(expect.get("productTelemetry").?.bool, got.product_telemetry);
        try std.testing.expectEqual(expect.get("crashUpload").?.bool, got.crash_upload);
        try std.testing.expectEqual(expect.get("backgroundNetwork").?.bool, got.background_network);
        try std.testing.expectEqual(expect.get("createTelemetryId").?.bool, got.create_telemetry_id);
    }
}

test "DO_NOT_TRACK=1 does not write a telemetry ID file" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const allowed = decide(true, true, .fromGet("1", null)).create_telemetry_id;
    if (allowed) try dir.dir.writeFile(std.testing.io, .{ .sub_path = "telemetry-id", .data = "nope" });
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, "telemetry-id", .{}));
}
