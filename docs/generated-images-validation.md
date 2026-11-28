# Generated images in conversation threads

Codex `imageGeneration` uses `savedPath` as its only source. The engine imports a
PNG, JPEG, WebP, or GIF of at most 24 MiB into the active profile's uploads root
before publishing the event. Neither the original path nor `result` enters the
journal or session document. Source files remain owned by Codex.

The desktop transcript loads the imported file through the attachment cache
(`apps/nano/src/app_attachment_images.zig`) and draws it in the reply
(`view_reply_images.zig`); consecutive images share one gallery card
(`view_image_gallery.zig`). Clicking an image opens the image preview
(`view_image_preview.zig`). Media bytes stay on the host.

## Automated checks

```sh
cargo test -p harness-proto -p harness-doc
cargo test -p harness-engine generated_image
cargo test -p harness-engine --test e2e --test device_routing --test workspace_sync
cargo test -p harness-adapters codex
cargo test -p harness-adapters --test codex
(cd edge && npm test)
(cd apps/nano && zig build test -Dtest-filter="reply images")
```

The engine fixture covers repeated completions, restart-style Loro export/import,
removal of the original Codex source, replay after removal, and negative journal
assertions. Upload tests cover supported signatures, size/path/symlink rejection,
source replacement during copying, atomic cleanup and idempotent destinations.
The two-device routing test reads the imported file locally and via the relay,
and verifies that the original source cannot be read remotely.

## Optional real-provider smoke (consumes quota)

These tests stay ignored in normal runs. They require an authenticated Codex
installation and a model/account provisioned for image generation.

```sh
cargo test -p harness-adapters --test codex real_image_generation_smoke -- --ignored
cargo test -p harness-engine --test e2e real_image_generation_profile_smoke -- --ignored
```

The harness smoke checks that the real provider returns an existing saved file;
the engine smoke also requires the persisted path to be under profile uploads.
No real-provider smoke or manual visual check was performed as part of the
implementation's automated tests.

## Manual visual check

Run a normal Codex chat in both light and dark themes, including a narrow window:

1. Generate a goblin PNG. Check the live chip, resolved chip, inline image,
   rounded corners, contained aspect ratio, and the image preview's click and
   Escape.
2. Generate two images with text before and after. Check order, spacing and
   timestamp placement. Small images should keep their natural size.
3. Change chat and return, then restart. The durable image should reappear.
4. Open the thread on another client. Disconnect the owning host and check
   the unavailable placeholder without affecting other message parts.
5. Exercise the fake provider's quota-error and missing-path scenarios. Neither
   should leave an unresolved chip or produce an empty image part.

For the generated turn, inspect the profile journal/document for the uploads
reference and absence of the original Codex path, inline `result`, data URLs or
image Base64. Other user-authored content may legitimately contain those strings.

## iOS client

The iOS session mirror recognizes the same `image` part metadata. Generated
images form independent transcript rows with the message's device as the first
source and the chat host as fallback. They preserve aspect ratio, have rounded
corners, and open the shared attachment lightbox. Loading and unavailable states
use the existing attachment cache and relay; visible rows retry failed sources.
The generation tool keeps its ordinary lifecycle presentation.

Generated downloads validate the declared and actual raster MIME type and the
24 MiB encoded-file limit. ImageIO reads dimensions before decoding, rejects
sources exceeding 4096 pixels on either axis, and decodes one static frame at
most 2048 pixels on its longest side off the main actor. The cache accounts for
decoded pixel memory and separates validated generated images from generic
attachment entries. Geometry changes notify the native transcript table.

`GeneratedImageTests` covers metadata decoding, malformed references, row identity
and device/content corrections, source ordering, raster limits, and cache policy
isolation. `TranscriptLayoutTests.testGeneratedImageArrivalResizesTheRowAndKeepsTheTailVisible`
covers a placeholder becoming a loaded image in the native scrolling transcript.
`reauth.yml` runs `GeneratedImageTests` on a macOS runner. On a Mac with the project dependencies installed and `SIMULATOR_UDID` set:

```sh
xcodebuild test -project apps/ios/Harness.xcodeproj -scheme Harness \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:HarnessTests/GeneratedImageTests \
  -only-testing:HarnessTests/TranscriptLayoutTests
```

For the device check, generate an image on a desktop host and open its chat on
an iPhone. Verify inline display, tap-to-preview, returning to the chat, and scroll
position during loading. Reopen on a client without cached bytes while the host
is offline, then reconnect the host and verify retry recovery. Also check light
and dark appearances and a portrait image whose displayed height reaches the cap.
