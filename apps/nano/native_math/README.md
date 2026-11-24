# Native equation engine

Nano retains the original desktop equation implementation (`math_layout.rs`
before the native-UI migration), including its geometry corrections and safety
checks. The vendored `latex-rust` 2.1.1 SVG backend supplies the TeX AST,
exact-rational box layout, and embedded STIX Two Math font. `usvg` measures
trusted generated glyph outlines to keep italic bearings and negative spacing
inside the viewport. No system math-font installation or network access is
needed at runtime.

`build.zig` builds this static library with Cargo and links it directly into
nano. `src/native_math.zig` copies a caller-owned equation result into the
frame arena and frees the native allocation. Generated SVG contains font
outlines/rules only; nanoui's native SVG primitive paints it. User LaTeX is
never interpolated into SVG/HTML, evaluated, or sent to a browser/service.

Supported original syntax includes nested fractions, superscripts/subscripts,
indexed radicals, Greek/Unicode symbols, stretchy delimiters, matrices and
aligned environments, accents, underbraces and their annotations, display
operator limits, text/font commands, colors, and supported absolute spacing.
Inline equations share a baseline with surrounding styled prose and links.
Selection copies the original delimited equation source, not flattened math.

Math style declarations apply within the current math list, including fractions,
scripts, delimiters, and matrix cells. `\limits` and `\nolimits` override the
operator's default placement. Explicit skips are added to automatic TeX glue
without changing how binary operators are classified; `pt`/`bp` skips keep
physical width across style changes. Unknown or malformed input, barless and
style-specific fraction commands, and `\rule` still fall back to literal source.
Source/token/depth/AST/grid/box/output/area limits and the 32-entry/2-MiB vector
cache are retained. FFI panics are caught; failed layouts return literal source
rather than a changed equation.

Verification (from the repository root):

```sh
scripts/heavy-build.sh cargo test --locked --manifest-path apps/nano/native_math/Cargo.toml -j2
# The regular `zig build test -j2` also runs the Rust engine tests.
```

The first build requires Cargo and its pinned dependency sources; release
binaries contain the math engine and font and require neither Cargo nor a
runtime download.

## Vendored parser and layout

`vendor/latex-rust` is sourced from the crates.io 2.1.1 release (upstream
`e377ecb4af876b8b75e62b8b83e8a9535499944c`), with only the SVG backend built.
The patch preserves style declarations, explicit operator placement and
absolute skips in the AST and resolves spacing in the actual row layout.
The upstream crate discarded the declarations and treated skips as atom
boundaries; moving the behavior here avoids guessing from source strings or
repairing geometry after layout. Keep the upstream notices and font license
when updating it. Remove the local dependency once upstream preserves these
semantics and the native and transcript regressions still pass.
