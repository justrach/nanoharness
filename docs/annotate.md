# Image annotation

Point at parts of an image before asking the agent about it: drop numbered pins on the image and give each one a note.

## Flow

1. Click an image in the chat (a reply's picture or one you sent). It opens in the image preview; see [image preview and zoom](image-preview.md).
2. Choose **Annotate** in the preview's toolbar. The hint line changes to "Click image to drop callout pins · Click a pin to edit its note · Esc to exit annotate".
3. Click the image to drop a numbered pin, up to eight. Its note field opens in the list under the image. Clicking an existing pin edits its note instead of adding another.
4. The × beside a note deletes that pin. **Undo** removes the last pin and **Clear** removes them all.
5. **Send feedback (N)** attaches the image to the chat's composer, adds the notes to the draft (after any text already there) and closes the preview. Nothing is sent until you send the message.

Esc first leaves the note you are typing in, then annotate mode, then closes the preview.

The draft gets one line per pin, its position as a percentage of the image's width and height:

```
Image feedback on billing.png:
1. (62%, 18%): Make this the primary button
2. (31%, 44%): (marked area)
```

A pin with no note reads `(marked area)`. Pins are not drawn into the image; the agent gets the original picture and the text.

## Code

- `apps/nano/src/image_annotate.zig`: pin state (add, remove, undo, clear), screen-to-image mapping under zoom, and the feedback text.
- `apps/nano/src/view_image_preview.zig`: the Annotate button, pins, notes and the feedback handoff.
- `apps/nano/src/app_attachment_images.zig`: the preview's state.

## Tests

From `apps/nano`:

```sh
zig build test -Dtest-filter="image annotation"
zig build test -Dtest-filter="Annotate"
```

## Limits

- Pins cannot be moved; delete one and drop another.
- The iOS app does not annotate.
