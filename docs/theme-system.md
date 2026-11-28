# Theme system

Harness themes are complete, source-neutral theme definitions stored in
`apps/nano/themes.json` and loaded by `apps/nano/src/themes.zig`. Runtime
components consume only Harness semantic roles (`theme.Colors` in
`apps/nano/src/theme.zig`). VS Code workbench ids and TextMate selectors stop
at the importer.

## Runtime model

- A family groups related variants; a variant (`themes.Variant`) is one
  completely resolved light or dark palette.
- The settings keep independent light and dark choices
  (`themeSelection.light`, `themeSelection.dark`). New installs use
  `codegraff-light` and `codegraff-dark`.
- Settings → Appearance switches between **System**, **Light** and **Dark**.
- `accent` is `themeDefault` (the variant's authored accent) or the name of a
  preset, which derives a contrast-checked interaction overlay. The accent
  affects controls, focus, selections, caret, activity and the three-tone
  glyph. It does not recolor syntax, terminal ANSI, status, or diff semantics.
- Every variant records a recommended surface treatment. Harness, Codegraff,
  Warm Harp and Harp recommend frost; the others recommend opaque surfaces.
- The surface preference is a separate device-local choice, stored as
  `surface`: `frosted`, `opaque`, or absent for the variant's recommendation
  (`apps/nano/src/surface_palette.zig`). It does not change appearance, theme
  or accent. Settings shows it as one **Frosted glass** switch reflecting the
  look in effect; flipping it stores `frosted` or `opaque`.
- Terminal ANSI colors belong to the variant.

Frost derives the window, card, overlay and composer tints from the variant's
own shell roles rather than fixed greys, and thickens a tint when needed to
keep text readable against the desktop behind it. macOS and Windows let the
window shell show through; elsewhere the shell stays opaque.

## Built-in themes

`apps/nano/themes.json` has 37 variants across 22 families:

- Harness Light and Dark
- Codegraff Light and Dark
- OpenCodex Light and Dark (an independently adapted Codex-inspired palette)
- VS Code Default: Light+ and Dark+
- Catppuccin Latte and Mocha
- Tokyo Night Light and Tokyo Night
- Dracula
- GitHub Light and Dark
- Ayu Light, Dark, and Mirage
- Gruvbox Light and Dark
- Rosé Pine Dawn and Moon
- Nord
- One Dark Pro
- Atom One Dark
- Night Owl Light and Night Owl
- Winter is Coming Light and Dark Blue
- Palenight
- SynthWave '84
- Cobalt2
- Andromeda
- Warm Harp Light and Dark
- Harp Light and Dark

Every bundled variant records its source URL, upstream revision, license, and
a SHA-256 hash of the resolved definition. The file is maintained by hand in
this repository.

Appearance settings keep the light and dark choices in ordinary settings rows.
Each row opens a menu ("Light themes" or "Dark themes") with a small palette
preview per variant, so the catalog can grow without turning the page into a
grid of buttons. Accent is a compact row of swatches; the first means "Theme
default".

## VS Code import

The importer (`apps/nano/src/theme_import.zig`) reads JSONC (comments,
trailing commas), `include` inheritance up to 32 levels, inline or external
token rules, TextMate `.tmTheme`/plist files, workbench colors and semantic
token colors.

Settings → Appearance → **Add theme** accepts a theme file, an extension
`package.json`, or an extension folder. Packages are detected from
`contributes.themes`; variants are classified by `uiTheme` or the resolved
editor background. Each package variant compiles independently, so a broken
variant is reported without hiding valid siblings. **Theme mapping** shows,
per variant, every role mapping, adjustment, fallback and warning.

The importer records `opaque` as an imported variant's recommended surface
treatment and says so in the report; the Frosted glass switch can still
force frost.

After mapping, a hardening pass checks Harness's shared roles where they are
painted and adjusts a color toward a contrast-safe anchor only when no
related source role can carry it. Syntax, terminal ANSI, diff, warning, error
and success identity stay theme-owned.

The custom library (`apps/nano/src/theme_library.zig`) has four source forms:

- an imported snapshot, a self-contained compiled copy;
- a linked file, which follows one source theme file;
- a linked package, which follows a VS Code extension package;
- an editable file, a native resolved-family JSON file created by
  **Duplicate as editable**.

Linked sources reload on **Reload**. All four resolve to the same variant
model as the built-ins, so runtime components never see VS Code tokens. The
library is `theme-library.json` in Harness's data folder. Harness does not
fetch or run VSIX packages; custom sources are local files compiled into
resolved data.

The importer's output is pinned by `apps/parity/vectors/theme-import.json`.

## Tests and review

From `apps/nano`:

```sh
zig build test -Dtest-filter="theme-import vectors"
zig build test -Dtest-filter="JSONC"
zig build test -Dtest-filter="every built-in variant"
```

Before adding or updating a bundled variant, look at both appearances where
available: the sidebar, transcript Markdown and code, the composer, a picker,
Settings → Appearance, a diff, the terminal, an empty state and a dialog.
Check normal, hover, active, focused, selected, disabled, working, warning,
error, and success states. Importer reports and contrast checks do not replace
that visual pass.
