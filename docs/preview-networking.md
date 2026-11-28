# Project previews

Run an HTTP development server in a project and it gets a stable address:
`http://<device>.<project>.localhost:7331`; additional services receive persistent
names such as `<device>.<project>-api.localhost:7331`. The engine reports a
session's services through the `WatchPreviews` RPC, and
`harness preview-servers` prints the local scan as JSON.

The preview daemon (`harness preview-daemon`, `apps/nano/src/preview/`) owns
this listener and discovery; the engine starts it and relays its catalog
(`crates/engine/src/preview_bridge.rs`). Closing a browser tab does not stop
discovery or change an address. A busy proxy port produces an inline error
instead of changing the URL.

## Discovery and identities

On Linux, the scanner joins the current user's `/proc` process cwd, ancestry,
creation time and socket descriptors to listening TCP sockets. On macOS it uses
`lsof` and `ps` for equivalent metadata. Only loopback-reachable listeners whose
cwd belongs to a known local project are probed. The deepest matching project
wins. Unrelated listeners and non-HTTP services are excluded. HTTP probes are
bounded and run every two seconds, using HEAD and accepting valid HTTP status
responses (including authentication and application errors).

Harness terminal/task/agent descendants are marked as Harness-owned. Framework
commands identify Vite, Next.js, Astro, Miniflare and Node servers; otherwise the
list uses a generic HTTP label. Before a local backend connection, the daemon
rechecks the listener's process identity and cwd to reject stale port reuse.

The profile's `previews.json` stores project and service IDs and hostname labels
separately from observed PIDs and ports. Command identities omit common port
options. Device-name collisions get persisted suffixes. The first service keeps
the project hostname; additional services get descriptive suffixes. Two
indistinguishable instances of the same command in the same cwd get separate
slots; their individual identities cannot be inferred across simultaneous
restarts without additional application-provided identity.

`WatchPreviews` resolves the session's current cwd on each catalog or workspace
change and reports the services for the session's owning device. Changing the active
checkout therefore changes the list without copying paths or entering ports.

## HTTP proxy

The loopback proxy (`apps/nano/src/preview/proxy.zig`) listens on 127.0.0.1 and
::1 at port 7331. The Host header must name a live catalog service at the
proxy's own port; before each connection the proxy rechecks that the backend
listener is still the same process. It removes hop-by-hop headers, keeps Host
and Origin together, sets
`X-Forwarded-Host` and `X-Forwarded-Proto`, keeps client proxy credentials from
the project, and rewrites absolute localhost redirects to the preview origin.
Bodies stream with their own framing. WebSocket upgrades keep their byte
stream, allowing Vite HMR through the same URL. `CONNECT` reaches only catalog
names at the proxy port, for WebKit's per-domain proxy on older macOS.

Only this device's services are served. The catalog holds no services from
other devices, so a preview opens only on the computer running the server.
macOS and Linux provide discovery.

## Validation

From `apps/nano`, `zig build test -Dtest-filter="preview"` covers the catalog
(persistent names across port changes and restarts, hostname rules,
framework labels, probe back-off), discovery from recorded `lsof`/`ps` output
and a made-up `/proc` tree, and the proxy (forwarding by hostname, redirects,
refusal of unknown names, wrong ports and stale processes, WebSocket bytes,
CONNECT tunnels, a taken port).

`cargo test -p harness-engine --test previews` checks that `WatchPreviews`
follows the session's checkout and owning device. CI runs it in
`preview-tests.yml`.
