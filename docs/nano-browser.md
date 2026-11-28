# Nano's Browser pane

Nano keeps its native UI. A Browser side tab embeds the system WKWebView on
macOS; it does not put the app itself in a webview. On Linux and Windows the
tab says "The integrated browser is available on macOS." The sidebar, transcript,
composer and browser controls still use Harness's original SVGs and native
layout.

Open the right pane, press **+**, then choose **Browser**. Enter a website
or a local address such as `localhost:3000`; bare loopback addresses use HTTP,
other bare hosts use HTTPS. Back, Forward, Reload and Copy address are in the
native toolbar. Each Browser tab belongs to its conversation. Switching away
or closing the pane hides its native view; closing the tab destroys it at a
safe frame boundary.

**Open in Harness** on a link's context menu opens it in a new Browser tab
of that conversation; a plain click opens the system browser, except GitHub
links, which follow **Open GitHub links in Harness** (see
[transcript links](transcript-browser-links.md)). Links in a subagent or a
Markdown file preview keep the containing chat as their owner. Privileged
schemes, malformed URLs and embedded credentials are rejected; they never fall
through to a system-browser launch.

A tool's generated-page chip opens its saved HTML or MCP App in the pane.
These are host-local: an unknown or different host is not guessed. Only a
validated kind and 32-character lowercase hexadecimal ID can locate a page,
under `.graff/views` or `.graff/mcp-apps` in the host's home directory. The
reader refuses symlinks and non-regular files and bounds the body to 16 MiB.
The `graff-view` scheme supplies Harness's existing Content Security Policy:
inline scripts/styles, no network or forms, sandboxed origin, and only the
MCP App kind's inline data frames. These tabs cannot navigate to websites or
arbitrary files.

Ordinary websites have no nanoui IPC bridge, injected app scripts, or engine
handles. WebKit is allocated only when a nonempty Browser tab is actually
shown; the normal native app's startup does not create browser processes.
Browser navigation is event driven, not polled.

## Preview consumers

graff stops a background server that is still listening only when
`~/.codegraff/preview-consumers.json` holds an explicit 0 for its port
(codegraff #941). Nano writes that file: the number of web tabs that show
each loopback port (`localhost`, `*.localhost`, `127.0.0.0/8`, `::1`), and
0 once the last of them closes or Nano quits. Each Nano process also keeps
its own counts in the file, so the next one to start retires the counts of
a process that crashed. A port Nano handed to a browser it cannot see (a
transcript link opened in the system browser, **Open externally**, **Open
in browse**) is never written as 0 while that Nano runs. Zeros expire after
a day. Updates take a lock beside the file and rename a complete file into
place. `apps/nano/src/preview_consumers_vectors.json` pins the contract;
graff runs an identical copy. Hidden, scripted and replayed runs, tests and
scenes do not write it.

## Checks

From `apps/nano` (nanoui is the in-tree copy at `apps/nano/nanoui`):

```sh
../../scripts/heavy-build.sh zig build test
```

`tests_ui_surfaces.zig` drives the native controls, transcript links and agent
side tabs using synthetic data. `tests_browser_native.zig` exercises real,
hidden WebKit against a generated page in a temporary home and an ephemeral
localhost HTTP server. Tests use a nonpersistent website data store and never
consult a person's saved pages, browser history, accounts or engine.
