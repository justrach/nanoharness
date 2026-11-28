# Markdown file preview

Files opens `.md` and `.markdown` documents in Preview. An editable document has one toolbar button that switches between **Edit** and **Preview**; the choice holds while the file stays open. Preview draws the current buffer, unsaved edits included, with the same Markdown renderer as chat replies. The extension check is case-sensitive: `README.MD` opens as text.

Links in a preview belong to the file's conversation and use the same link actions as the transcript; see [transcript links](transcript-browser-links.md).

## Math

Inline `$…$` and `\(…\)` and display `$$…$$` and `\[…\]` are typeset as TeX layout (fractions stack, scripts sit above and below the baseline), painted by nanoui from the bounded engine in `apps/nano/native_math/`. Prices such as `$5 and $10` stay text, an unmatched opener does not swallow a later equation, and an equation the engine does not support stays as its literal source. Copying a selection copies the original source.

## Mermaid

Mermaid fences are parsed and laid out in Zig (`apps/nano/src/mermaid.zig`): `flowchart`/`graph`, `stateDiagram`, `classDiagram`, `erDiagram`, `sequenceDiagram` and `pie`. A fence can switch between the diagram and its source. The layout is Harness's own, not Mermaid.js output.

## Code

- `apps/nano/src/view_host.zig`: the file toolbar and the Edit / Preview button.
- `apps/nano/src/app_file_editor.zig`: the editor state and the preview default.
- `apps/nano/src/view_markdown.zig`, `markdown.zig`, `markdown_cache.zig`: parsing and drawing.
- `apps/nano/src/native_math.zig`, `native_math_flow.zig`: math layout.
- `apps/nano/src/mermaid.zig`, `view_mermaid.zig`, `view_mermaid_seq.zig`: diagrams.

## Tests

From `apps/nano`:

```sh
zig build test -Dtest-filter="native math"
```
