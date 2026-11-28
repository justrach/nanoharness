# Harness architecture

Harness is a native desktop workspace for coding agents. The desktop GUI and CLI launcher (`apps/nano`, `cli_main.zig`) are built in Zig on `nanoui` and `http.zig`, backed by the local Rust session/sync engine (`crates/engine`, `harness-engine`). The SwiftUI companion in `apps/ios/Harness` displays synced workspaces and can send commands to a trusted desktop host.

## Local process

- `apps/nano` renders the native desktop shell, conversation, file browser, terminal, settings, and agent controls in Zig on `nanoui`, and hosts the `harness` CLI launcher, MCP server (`mcp_server.zig`), preview coordinator (`preview/`), Luau visual sandbox (`visual_luau.zig`), and self-updater (`updates_host.zig`).
- `crates/engine` owns local workspaces, session records, worktrees, queues, and device control.
- `crates/harness` (package `harness-adapters`) contains provider adapters. Each adapter uses the provider's local CLI and credentials.
- `crates/proto` defines shared messages and models.
- `crates/doc` (`harness-doc`) holds the session and workspace Loro document schemas.
- `crates/rpc` (`harness-rpc`) is the typed RPC the GUI and the engine speak over WebSocket, plus the device-room relay transport.
- `crates/sync` handles optional account sync, registry state, session logs, and the device relay.

The GUI and engine run as separate processes and talk over that WebSocket RPC on `127.0.0.1:27664` (`HARNESS_IPC_PORT` overrides it; `apps/nano/src/ws.zig`, `rpc.zig`). Local mode requires no account or cloud service. The current profile is chosen at engine start; stop and restart the daemon after `harness login` or `harness logout` to change between local and synced profiles.

The iOS app keeps its Swift port of the sync protocol in `apps/ios/Harness/Sync`; `apps/parity` pins the rules shared across implementations.

## Sync service

The TypeScript Worker at `edge/` implements the Harness sync protocol. It deploys from this directory to `https://edge.codegraff.com`. The worker validates Harness tokens before forwarding requests into Durable Objects. Session, chat, registry, preview, and device rooms use WebSockets for live updates; R2 stores attachments and release artifacts. The CLI and iOS app use the same endpoint. Agent rooms add one live Durable Object per room over PostgreSQL. See `docs/chat2-sync.md`, `docs/registry-sync.md` and `docs/agent-rooms.md` for wire details.

A synced device can request files and commands from another device through the relay only when that computer has **Allow remote control** enabled in Settings → Devices (off by default). The first execution, file write or terminal from a given remote caller still needs a local approval chip. Chat2 commands from another device are Peer work and drain only after that opt-in or chip. `ApplyUpdate`, `SetAutonomy` and `SetRemoteControl` never run on the host relay. Treat account access plus that opt-in as access to the connected device's workspace files, including ignored files when that option is enabled. See ADR 0009.

## Distribution

`scripts/package-macos.sh`, `scripts/package-linux.sh`, and `scripts/package-windows.ps1` produce platform archives with the Harness icon and license notices. The root `LICENSE` covers original Harness contributions under a modified AGPLv3 (AGPL-3.0 plus reserved commercial and cloud rights for the licensors it names) from this change onward. Upstream and bundled material retain their own notices in `THIRD_PARTY_NOTICES.md`.
