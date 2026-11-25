# Vendored nanoui

Source: https://github.com/justrach/nanoui

Pinned revision: `09033e1fc9a2fe99fe9d276bb5e548914f4733a5` (nanoui 0.13.0).
Original Zig package hash: `nanoui-0.13.0-we0KMZixOgAWGOwh3EwZBX_6abC1iZRv9nr53YZoE_wn`.
The unmodified copy was verified with `zig fetch` to produce that exact hash before local changes.

Only the upstream package's declared distribution paths are included: build files, `src`, `tools/ios`, `tools/android`, `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `third_party/licenses`. Examples, build output, package caches, and unrelated tools are not vendored. The MIT license and all bundled third-party notices/licenses are retained unchanged.

Harness-local changes restore scroll viewport alpha fades (#427): `Style.scroll_edge_fade` masks a scrolling box's complete content after compositing it, leaving its own background, native scrollbar and hit regions intact. Hidden-edge rules live in `src/ui/scroll_fade.zig`. Metal, OpenGL/ES, D3D11 and the CPU reference renderer consume the same nested group stream without changing the 192-byte GPU instance ABI. D3D11 uses grayscale glyph coverage inside transparent groups. Existing ordinary-opacity groups retain their parent-backdrop glass behavior.

The scrolling-mask local edits are limited to the two build manifests; `src/ui/{types,gpu,paint,metal,opengl,d3d11,raster,ui}.zig`; the three `shader.{metal,glsl,hlsl}` files; and the new `scroll_fade.zig` / `tests_scroll_fade.zig`. `test-scroll-fade` runs native or portable pixel/rule tests; `check-scroll-fade` compiles the platform GPU entry points without running a cross-target executable. Examples and unrelated tools are not required by either gate. `.gitignore` excludes only generated local build/dependency directories.

Harness-local pointer-selection changes also update `src/ui/selection.zig`
and add `text_selection.zig`, generated `text_selection_data.zig`, and the
unmodified Unicode 17.0.0 `grapheme_break_test.txt`. Double-click hit testing
uses the glyph cell under the pointer, not the nearest insertion caret or
word-cursor navigation. Unicode UAX #29 extended-grapheme segmentation
preserves combining marks, emoji modifiers, flags, ZWJ sequences, and Indic
conjuncts; words retain identifier and Unicode letter/number runs, while
punctuation/emoji select whole individual graphemes. Original UTF-8 source
bytes and ordinary caret/drag indexing are unchanged. Native and reference
shapers use the same rule. Prior viewport mask/fade changes are retained.

The Unicode 17.0.0 official UCD sources are listed in the generated table
header. Regenerate offline using `python3 src/ui/gen_text_selection.py
<ucd-directory>` with those four property files plus `GraphemeBreakTest.txt`.
Hangul LV/LVT properties are computed algorithmically; all other
break properties, Extended_Pictographic, and Indic_Conjunct_Break come from
the pinned Unicode data. The Unicode license and notice are retained in
`third_party/licenses/Unicode-3.0.txt` and `THIRD_PARTY_NOTICES.md`.
`zig test src/ui/text_selection.zig -fllvm` runs the full pinned Unicode
GraphemeBreakTest corpus and word/pointer boundary vectors. Harness's
`deep interface doubleclick` tests exercise production native rendering
and source-byte Copy across glyph-cell edges.

Harness-local desktop termination gating adds the optional
`Options.should_terminate` predicate to `src/app.zig`, `src/linux/app.zig`
and `src/windows/app.zig`. `App.quit` checks it before changing lifecycle
state or stopping the event loop, so explicit Save/Discard/Cancel decisions
can safely veto Quit. A null hook preserves upstream behavior. The macOS
native delegate and imperative Quit share the gate; the native veto test
also checks exactly-once termination callbacks. AppOptions changed, so
rebuild the native runtime through the normal package graph after updating.

The Linux native window also retains `Options.should_close` and honors it
for GTK 3 delete events, GTK 4 close requests and imperative close. Final App
teardown uses `destroyNow` after close decisions have been resolved, matching
Windows' forced-disposal path and avoiding a vetoed-close teardown loop.
This supplies the same dirty-document veto contract to all desktop windows.

NanoHarness-local selection changes port the unmerged Harness proposals
https://github.com/justrach/harness/pull/831 and
https://github.com/justrach/harness/pull/843 to this dependency's current path.
`src/ui/{selection,text_selection,textedit,textfield,textfield_lines,textarea,types}.zig`
share source-byte word/sentence/paragraph selection for two/three/four clicks
in prose and prompt editors, retaining the initial multi-click unit while
held and extending drags in complete units. Four or more clicks remain
paragraph-only; Cmd+A remains the explicit select-all command. Code and
ordinary fields retain word/visual-line selection. The app owns continuous
edge scrolling in the original selection viewport without disabling row
culling or replacing split-pane scroll-position preservation.

`src/ui/{accessible_text,a11y}.zig` expose selected source text and UTF-16
ranges to macOS accessibility. A stable read-only text-area element represents
cross-paragraph output selections; editor selections use their real field.
Native hidden-window tests cover queries, stale-selection withdrawal and
window isolation, not system-wide Speak Selection playback. These public
struct changes require rebuilding the native runtime through the package
graph, rather than reusing a runtime compiled against an older layout.

The native timeline row is cherry-picked from upstream proposal
https://github.com/justrach/nanoui/pull/177, commit
`b641cf30f360d40f41248478fea3aed0597a14ed`: `src/kit/timeline.zig`
and its two public exports in `src/kit/kit.zig`. The upstream base/pin is
unchanged. The proposal carries the domain-neutral component tests and
cross-platform checks; Harness's native history tests exercise the consumer.
No Luau module or runtime is included.

Harness-local responsiveness instrumentation adds an optional `View.after_frame`
callback in `src/ui/ui.zig`, invoked exactly once by `src/ui/frame.zig` after
completed CPU-frame work (including retained frames). A null callback leaves
upstream behavior unchanged. Harness owns the bounded metric recorder and
background transport; the toolkit hook does not serialize or send data.

Harness-local bottom overscroll changes in `src/ui/scroll.zig` use a bounded
nonlinear resistance curve and its inverse, preserving event-coalescing and
reversal behavior. Precise native momentum crossing the bottom now seeds one
bounded rebound, without pumping the spring again on later momentum events.
The impact invalidates retained scrolling so its displacement is freshly laid
out and painted. Discrete wheels and Reduce Motion do not gain an inertial
bounce. Harness's `tests_scroll_bounce` module checks the production consumer,
including full-tree/culled pixel parity through impact and recovery.

Harness-local ImageIO orientation handling in `src/ui/image.zig` reports
EXIF-oriented dimensions for both header layout and transformed thumbnails.
Small rotated/mirrored images also use ImageIO's transformed thumbnail path,
so their decoded pixels and layout agree. Harness's native headless
`image orientation` regression checks small and large synthetic PNGs and
actual rendered quadrant positions; ordinary reply-image tests remain intact.

Harness-local sidebar scrollbar timing adds the optional
`Style.scroll_bar_idle_timeout` in `src/ui/{types,scroll}.zig`. It includes
its final 0.3-second fade, ignores stationary hover, and stays visible during
thumb dragging. Null retains the upstream/default and legacy fade behavior.
Harness's `Cmd+B sidebar scrollbars` test covers both production sidebar lists
with simulated time, wheel input, hover, dragging and native screenshots.

Harness-local clipboard image support adds `Clipboard.write_image` in
`src/ui/input.zig`, `platform.clipboardWriteImage` in `src/platform.zig`,
macOS PNG/TIFF pasteboard writes in `src/desktop.zig`, and `Tester.clipboard_image`
in `src/ui/tester.zig` so image previews can copy full image content directly
and tests can verify success and failure paths without touching the host clipboard.

Harness-local macOS/iOS colour glyph rendering preserves colour emoji RGB and
internal detail end to end in `src/ui/{atlas,atlas_tt,gpu,paint,metal,shader.metal,text_mac,surface,tester}.zig`
and `src/ios/surface.zig`: fonts carrying `kCTFontTraitColorGlyphs` rasterize into
a lazy sRGB premultiplied BGRA8 atlas texture and sample via `Kind.color_text`
with opacity, clipping, motion blur, and horizontal fades while ordinary text
keeps its R8 mask, smoothing, and dilation path unchanged.

Harness-local pointer cancellation in `src/ui/{context,frame,surface_events}.zig`
retires held gestures when a window loses focus, without synthesizing a click
or drop. Real macOS mouse moves reconcile the tracked button with AppKit's
button snapshot, recovering from releases consumed by native responders while
preserving completed text ranges. Synthetic/scripted frames do not poll live
mouse state. Harness's `retention selection window deactivation cancels` and
`retention selection swallowed release` tests cover offscreen cancellation,
cross-pane movement, exact Copy and the next ordinary selection.

SDR-clean Windows D3D11/DirectWrite/DXGI parity is selectively cherry-picked
from upstream `justrach/nanoui` `v0.14.11` (`07d7a34284aeab78ae4ea958a128ca3573bf2673`,
commits `66b9741`, `0c71af4`, `ac97477`, `ac8dfb1`):
- `src/ui/corner_sdf.hlsl`, `src/ui/shader.hlsl`, `src/ui/d3d11_glue.zig`,
  `src/ui/d3d11.zig`, `src/ui/tests_d3d11.zig`, `src/windows/d3d.zig`, and
  `src/windows/surface_gpu.zig` add continuous/circular `corner_sdf_aa`,
  8-sample shadow blur with `shadow_dither`, multi-stop `gradient_stops` via
  `StructuredBuf`, and explicit `DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709`
  sRGB swap-chain configuration.
- `src/ui/{dwrite,atlas_tt,text_tt,raster,tests_dwrite}.zig` add GDI Classic
  per-analysis blend parameters/tags (`254`/`127`) and `GetGdiCompatibleGlyphMetrics`
  whole-pixel advances + rounded kerning.
- `src/ui/{gpu,paint,raster,shader.metal,shader.glsl,tests_raster}.zig`
  preserve negative circular radii through rounded clip packing (`clipRound` /
  `clipCorners`).
All Harness-local patches above (including `scroll_fade`, `d3d11_texture`,
`d3d11_device`, `color_text`, `text_selection`, `should_terminate`, and
`after_frame`) are retained, and HDR files (`d3d11_hdr.zig`, `hdr.hlsl`,
`hdr_output.zig`) remain excluded.

These changes live in this checked-in package, not an ignored download cache.

To update: start with the pinned upstream distribution, retain the notices,
reapply/reconcile the local mask, pointer-selection and termination changes, and run the
`test-scroll-fade` gate in both native and `-Dportable=true` modes with LLVM.
Also run the Unicode conformance/helper and Harness double-click gates above.
Update this revision/hash when changing the upstream base; a Unicode data
upgrade updates its pinned version, tables, conformance vectors and notice
together.
