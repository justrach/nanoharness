# Tab and panel behaviour

How chat tabs, split panes and the side panel open and close in the desktop
app (`apps/nano/src`).

## The rules

1. **A link, file or diff opens in a side panel beside the chat, at a set
   width.** It isn't squeezed to an equal share of a split. The side panel
   gets its preferred width (the saved side-pane width, 520 by default) while
   every other panel keeps its 220 pt minimum; when the window is too narrow
   for that, it gets an equal share. This is `sidePanelShare` in
   `panel_chrome.zig`. Stacked panels stay equal.
2. **Later ones join the same side panel.** They don't open another.
3. **The chat stays on screen.** Opening a link keeps the chat selected and
   showing in its own panel.
4. **One close is enough.** Closing a side panel's last tab removes the panel
   and gives its room back. No empty panel is left behind.
5. **⌘W closes what's beside the chat first.** With a file tab open beside
   the chat, ⌘W closes it and the chat stays on screen. The next ⌘W closes
   the chat.
6. **Closing a tab goes back to the one you were on before**, not to the
   neighbour that slid into its place (`activeAfterClose` in `tabs.zig`). After a restart, with no history yet, the neighbour is used.
7. **The window's only tab becomes a new chat** when it is closed.
8. **A strip slot closes with its own ✕.** It shows under the pointer when the
   slot is at least 136 pt wide (`slot_room_for_close` in `panel_chrome.zig`);
   narrower slots close from their menu. Pressing ✕ closes the panel's
   selected tab; if that was its last tab, the panel goes too (rule 4).

## Tests

From `apps/nano`, `zig build test -Dtest-filter="<name>"` with any of:

- `a link opens beside the chat at the side pane's width` (`tests_ui_surfaces.zig`)
- `a second link joins the panel already holding a page` (`tests_ui_surfaces.zig`)
- `closing a linked page once gives the chat its room back` (`tests_ui_surfaces.zig`)
- `a link in a split is not squeezed to an equal share` (`tests_ui_split.zig`)
- `closing a split page leaves no empty panel to close again` (`tests_ui_split.zig`)
- `Cmd+W closes an open file tab before closing a chat tab` (`tests_ui.zig`)
- `closing the only tab moves on to a new chat` (`tests_ui_tab_strip.zig`)
- `closing the tab you are on goes back to the one before it` (`tests_ui_tab_strip.zig`)
- `strip slot close button closes a tab and then its panel` (`tests_ui_tab_strip.zig`)
