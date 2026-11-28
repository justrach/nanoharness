# harness-nano

Harness's desktop app, in Zig on [nanoui](https://github.com/justrach/nanoui).
nanoui is vendored in `nanoui/`, pinned and described in `nanoui/PROVENANCE.md`.

The engine (the Harness daemon, or `harness headless`) keeps the workspaces,
sessions and agents; harness-nano talks to it over the engine's local
WebSocket RPC (`crates/rpc`). Other windows and clients on the machine attach
to the same engine.

HTTPS goes through [http-zig](https://github.com/justrach/http-zig), the HTTP/2
client codegraff uses.

The same build makes `harness`, the command-line launcher (`src/cli_main.zig`):
`harness` opens the app, `harness headless` runs the engine through the
`harness-engine` binary beside it, and `harness mcp`, `status`, `login`,
`logout` and `daemon` are served in Zig.

## What it does

- Sidebar: your spaces and their chats, newest first, with each chat's status
  (working, waiting for you, errored). **Add folder** adds a space on this
  device. Workspaces and their panel tabs stay in ordinary navigation;
  **Chat history** reopens conversations, including archived ones.
- Chat: the transcript as it streams in, with Markdown replies (code
  highlighted, with a Copy button), reasoning, and each tool call with how it
  went. In Compact mode, progress stays visible while a turn runs and
  folds when it finishes; the final reply stays visible and the work can
  be reopened.
- Composer: Return sends, Shift-Return starts a new line, **Stop** interrupts a
  running turn. A new chat picks its agent, model, and execution computer
  through **Run on**. Choosing another computer clears an incompatible
  project; an existing conversation stays on its original host. Drop local
  files or images into a chat pane to attach them to that pane (24 MB per
  file), or use the attachment picker. Rejected files show an explanation.
- Agent rows stay visible and open their live transcript in a side tab without
  leaving the parent chat. Finished agents use their saved transcript, falling
  back to the document feed if the snapshot is unavailable.
- On macOS, a native Browser side tab opens websites, localhost previews and
  generated HTML/MCP App pages. A plain click on a transcript link opens the
  system browser; the link's menu has **Open in Harness**. See
  [the browser's boundaries and checks](../../docs/nano-browser.md).
- Three workspace modes, Zen (the default), Developer and Design, decide how
  much chrome the window shows. See "Workspace modes" in
  [`DESIGN.md`](../../DESIGN.md).

Also: answering the agent's questions, the message queue, the changes pane,
the file explorer and its editor, project actions with their terminal dock,
attachments, dictation, pins and settings.

## Releases

Releases build this app for macOS, Linux and Windows
(`scripts/package-macos.sh`, `scripts/package-linux.sh`,
`scripts/package-windows.ps1`, run by `.github/workflows/release.yml`). The
Linux release job runs `zig build test-visual` before it packages, and a macOS
release is published only Developer ID signed and notarized.

## Build and run

You need Zig 0.17.0 and, on macOS, Xcode or the Command Line Tools.

```sh
cd apps/nano
zig build test          # unit tests (also runs native_math's cargo tests)
zig build test -Dtest-filter="native math"   # only tests whose names contain this
zig build run           # build and open the window
zig build snap -- scenes/narrow-panes.json /tmp/nano-snap   # draw a scene offscreen
```

For a full development bundle with its own engine, data folder and port, run
`./scripts/run-macos-dev.sh` from the repository root. `sh scripts/bundle.sh`
wraps a release build of the window alone as `zig-out/Harness Nano.app`, ad-hoc
signed; it forwards Zig build arguments.

harness-nano needs an engine. With Harness open, its engine is already
running, so harness-nano shows your chats. When nothing answers, harness-nano
starts `harness headless` itself, with its own environment, and writes the
engine's output to `harness-nano-engine.log` in Harness's logs folder. It looks
for `harness` in `HARNESS_NANO_ENGINE_BIN`, beside its own executable, in
`/Applications/Harness.app`, in `~/Applications/Harness.app`, then on `PATH`
(`src/engine_start.zig`). It never stops an engine, the one it started
included: once started, that engine is the machine's engine, and every other
window attaches to it. Set `HARNESS_NANO_NO_ENGINE_START` to wait for an engine
instead.

harness-nano connects to `127.0.0.1:27664`. Set `HARNESS_IPC_PORT` to use
another engine.

## Trying it against a throwaway engine

To keep your own chats out of it, run a second engine with its own port, data
and home:

```sh
dir=$(mktemp -d)
HARNESS_IPC_PORT=27990 HARNESS_DATA_DIR="$dir/data" HOME="$dir/home" \
  /Applications/Harness.app/Contents/MacOS/harness headless &
HARNESS_IPC_PORT=27990 HARNESS_NANO_HARNESS=mock zig build run
```

`HARNESS_NANO_HARNESS` sets the agent new chats start with. The engine's
`mock` agent replies without a model or an account.

nanoui's flags render the window offscreen, with no window on screen, for
checks and screenshots:

```sh
HARNESS_IPC_PORT=27990 zig-out/bin/harness-nano --nanoui-snapshot=/tmp/nano.png \
  --nanoui-wait=3 --nanoui-script="click:Do anything…;type:Hello;key:enter;live:8"
```

To open a chat at launch (for those checks), set `HARNESS_NANO_OPEN_CHAT` to
its id.

## Tests that it matches the engine

`protocol/desktop/` holds what this app and the Rust crates must agree on, as
data: the sidebar's rules (times, status marks, order), tool chips and group
summaries, how transcript frames apply, the Codegraff theme roles, and every
request this app sends the engine. `src/parity.zig` runs every file here; the
Rust runners (`crates/*/tests/desktop_*`) run the rules, transcript and request
files, and the request runner sends each request to a real engine. See
`protocol/desktop/README.md`.

After changing a request on purpose: `zig build vectors`, then `cargo test -p harness-engine --test desktop_requests`.

## Themes and artwork

`themes.json` is the built-in theme catalog (22 families, 37 variants), embedded
at build time and read by `src/themes.zig`. Codegraff Light and Dark are its
defaults; `protocol/desktop/theme.json` pins the roles they resolve to. A
change to a Codegraff colour changes both files.

The interface icons are Harness's own SVGs in `assets/icons` (Solar Linear by
480 Design, CC BY 4.0, plus the agents' marks). File badges, explorer rows,
tabs and diffs use the Symbols artwork in `assets/file-icons` and its
`assets/file-icons.json` manifest, including exact filenames, compound
extensions and named folders; `file_icons_build.zig` compiles the manifest at
build time rather than parsing it at launch.

## Layout

| File | |
|---|---|
| `src/ws.zig` | WebSocket client for the engine's socket. It sends no `Origin` header, which the engine refuses. |
| `src/rpc.zig` | The RPC frames: calls, replies, streams, cancel. |
| `src/engine.zig` | The connection: a reader thread, messages handed to the UI thread, reconnecting every 2 s. |
| `src/workspace.zig` | Spaces, chats, sessions, agents and models, each list replaced whole. |
| `src/transcript.zig` | A chat's transcript: resets and deltas, checked as `protocol/desktop/transcript.json` pins them. |
| `src/app.zig` | The state, and the calls that open a chat, create one and send. |
| `src/view*.zig`, `src/theme.zig` | The window: title bar, sidebar, transcript, composer, new-chat canvas, menus and pickers. |
| `src/tabs.zig`, `src/rules.zig`, `src/tools.zig` | Tabs; relative times, project monograms and reasoning labels; how tool calls fold and what their groups say. |
| `src/icons.zig`, `src/icons/` | Harness's icons and agent marks, tinted as drawn. |
| `src/markdown.zig`, `markdown_html.zig`, `highlight.zig` | nanoterm's Markdown parser and code highlighting. |
| `src/cli_main.zig` | The `harness` command-line launcher. |
| `src/release.zig` | The newest release, over HTTP/2. |
| `lean-proofs/` | Lean 4 models of UI rules, checked by `scripts/check-nano-proofs.py`. |

## Seeing the window without opening it

`zig build snap -- scene.json out-dir` draws the window offscreen from a
made-up scene (no window on screen, no engine) and saves a PNG for each
`snap` step. A scene gives the window's size and theme, the spaces, chats
and transcripts to show, and steps that press shortcuts, click, type and
check what's drawn (`expect`, `expectNot` fail the run). The format is at
the top of `src/snap.zig`; `scenes/` has examples.
