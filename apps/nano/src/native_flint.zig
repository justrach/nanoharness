//! Public setup information only. Runtime installation and readiness belong
//! to the selected device's Graff engine, never to a local settings toggle.
pub const name = "Native Flint";
pub const provider = "nanoattention";
pub const model = provider ++ "/flint";
pub const download_label = "Download weights";
pub const download_url = "https://codegraff.com/flint";
pub const description = "Run Flint locally on Apple Silicon with a separately installed external runtime. Harness does not install or start the runtime.";
pub const setup = "Download the weights and follow the setup instructions. On the selected Apple Silicon Mac, install and start the runtime and use a compatible Graff build. Then choose " ++ model ++ " from Graff's live model catalog. If it is missing, check Graff compatibility and runtime setup on that device.";

test "Native Flint setup links to public weights and names the live route" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings("https://codegraff.com/flint", download_url);
    try testing.expectEqualStrings("nanoattention/flint", model);
    try testing.expect(@import("std").mem.indexOf(u8, setup, model) != null);
}
