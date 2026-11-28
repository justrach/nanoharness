# Transcript web links

A web link in an agent message, a tool's output or a Markdown file preview belongs to that conversation. Clicking it opens the system browser. GitHub links follow **Open GitHub links in Harness** in **Settings → Links & browsing**: on, they open beside the chat in Harness; off, in the system browser.

Right-click a web link for **Open in Harness** (a Browser tab in the conversation, opening the side panel if needed), **Open in browser** or **Copy link**. A link to a local file offers **Open file** and **Copy link**. Up and Down move through the menu, Enter chooses, and Escape or a click outside closes it. The menu closes when its link's conversation is no longer the one showing. Copy never navigates.

An inline code span that holds only an HTTP(S) URL is a link too, and its context menu copies the exact destination.

Only explicit HTTP(S) addresses can navigate (`allowedNavigation` in `apps/nano/src/browser_url.zig`); a link that fails the check never reaches the OS opener. The integrated Browser tab is available on macOS only; see [the browser's boundaries](nano-browser.md).

## Code

- `apps/nano/src/app_browser.zig`: `openLink`, `openInternalLink`, `openExternalLink`.
- `apps/nano/src/view_link_menu.zig`: the context menu.
- `apps/nano/src/browser_url.zig`: which addresses may navigate, and bare-URL detection.

## Tests

From `apps/nano`:

```sh
zig build test -Dtest-filter="link actions"
zig build test -Dtest-filter="transcript web link"
```
