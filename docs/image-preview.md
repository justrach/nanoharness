# Image preview and zoom

Clicking a picture in the chat (a reply's image, a generated image, a gallery's stage or a picture you sent) opens it in the image preview, which covers the workspace below the title bar. The preview belongs to its chat: it shows only while that chat's pane is active.

The toolbar has **Close preview**, **Zoom out**, **Zoom in**, **Fit**, **Copy image** and **Annotate**, followed by the zoom percentage. **Copy image** copies the original bytes and shows "Copied" or "Copy failed". **Annotate** adds numbered pins; see [image annotation](annotate.md).

- Scroll or pinch over the image to zoom around the pointer; the page underneath does not scroll.
- Drag to pan.
- Zoom runs from 100% (the image fitted to the preview) to 400%. The buttons step by 1.5×; **Fit** returns to 100% and recentres.
- Esc closes the preview (in annotate mode it first leaves the note you are typing, then annotate mode).

Zoom and pan ease toward their target; with reduced motion they snap.

Image files opened in the Files panel are not shown as pictures: Files reports them as binary.

## Code

- `apps/nano/src/view_image_preview.zig`: the preview, its toolbar and keys.
- `apps/nano/src/image_inspection.zig`: wheel, pinch and drag geometry.
- `apps/nano/src/app_attachment_images.zig`: the image cache and the preview's state.

## Tests

From `apps/nano`:

```sh
zig build test -Dtest-filter="reply images"
zig build test -Dtest-filter="image preview"
```
