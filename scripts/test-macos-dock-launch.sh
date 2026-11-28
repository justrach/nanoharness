#!/usr/bin/env bash
# Run with a built NanoHarness CLI; all GUI registration belongs to a
# short-lived synthetic accessory app with no windows or activation calls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$(cd "$(dirname "${1:?usage: test-macos-dock-launch.sh <harness CLI>}")" && pwd)/$(basename "$1")"
[[ "$(uname -s)" == Darwin && -x "$CLI" ]]
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
APP="$SCRATCH/Dock Launch Fixture.app"
ID="org.example.harness-dock-test.$$"
mkdir -p "$APP/Contents/MacOS" "$SCRATCH/home"
cp "$ROOT/dist/macos/Info.plist" "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$ID" "$PLIST"
plutil -replace CFBundleName -string 'Synthetic Dock Launch Fixture' "$PLIST"
plutil -replace CFBundleDisplayName -string 'Synthetic Dock Launch Fixture' "$PLIST"
plutil -replace CFBundleVersion -string '1' "$PLIST"
plutil -replace CFBundleShortVersionString -string '1' "$PLIST"
plutil -remove CFBundleURLTypes "$PLIST"
plutil -insert LSUIElement -bool YES "$PLIST"
plutil -insert LSEnvironment -json "{\"HOME\":\"$SCRATCH/home\"}" "$PLIST"
install -m 755 "$CLI" "$APP/Contents/MacOS/harness"
cat > "$SCRATCH/fixture.swift" <<'SWIFT'
import AppKit
let app = NSApplication.shared
_ = app.setActivationPolicy(.prohibited)
// The test never needs to activate, create a window, or opt into a Dock tile.
DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
app.run()
SWIFT
swiftc "$SCRATCH/fixture.swift" -o "$APP/Contents/MacOS/harness-nano"
codesign --force --sign - "$APP/Contents/MacOS/harness-nano" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null
run_cli() { env -i HOME="$SCRATCH/home" PATH='/usr/bin:/bin' "$APP/Contents/MacOS/harness" </dev/null >/dev/null; }
run_cli & first=$!
run_cli & second=$!
peak="$(DOCK_TEST_ID="$ID" osascript -l JavaScript <<'JXA'
ObjC.import('AppKit');
ObjC.import('Foundation');
var id = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey('DOCK_TEST_ID'));
var peak = 0;
for (var i = 0; i < 20; i++) {
    var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(id);
    var count = 0;
    for (var j = 0; j < apps.count; j++) if (apps.objectAtIndex(j).finishedLaunching) count++;
    peak = Math.max(peak, count);
    $.NSThread.sleepForTimeInterval(0.15);
}
peak;
JXA
)"
wait "$first"
wait "$second"
# Let any fixture GUI outlive neither its temporary files nor this test.
DOCK_TEST_ID="$ID" osascript -l JavaScript <<'JXA'
ObjC.import('AppKit');
ObjC.import('Foundation');
var id = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey('DOCK_TEST_ID'));
var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(id);
for (var i = 0; i < apps.count; i++) apps.objectAtIndex(i).terminate;
JXA
printf 'Peak running GUI instances after two non-terminal CLI launches: %s (expected 1)\n' "$peak"
[[ "$peak" == 1 ]]
for plist in "$ROOT/dist/macos/Info.plist" "$ROOT/dist/macos/Info-dev.plist"; do
  [[ "$(plutil -extract CFBundleExecutable raw "$plist")" == harness-nano ]]
done
