# MCP Apps Host Specification (SEP-1865 `2026-01-26`)

NanoHarness supports interactive MCP Apps (SEP-1865 / `io.modelcontextprotocol/ui`) alongside offline `~/.graff/mcp-apps/<32-hex>.html` snapshots. See [ADR 0010](adr/0010-mcp-apps-host.md) for isolation guarantees.

## Architecture Overview

```text
  MCP App iframe (opaque origin, sandbox="allow-scripts", srcdoc + <meta CSP>)
        │  postMessage (JSON-RPC 2.0 allowlist)
        ▼
  Outer shell (mcp-app://host/<session-id>, no cookies, no storage)
        │  WKScriptMessageHandler "mcpApp" (isMainFrame required)
        ▼
  Nano Zig Host (app_mcp_apps.zig + mcp_app_host.zig + mcp_app_native.zig)
        │  Local Engine WebSocket RPC (McpAppFetchResource / McpAppCallTool)
        ▼
  Rust Engine Relay (crates/engine/src/mcp_apps.rs)
        │  HTTPS / loopback HTTP Streamable HTTP MCP (secrets stay in engine)
        ▼
  Configured MCP Server (.mcp.json -> ~/.codegraff/mcp.json)
```

## Server Configuration & Capabilities

NanoHarness resolves Streamable HTTP server entries by `serverName` from:
1. `<project_cwd>/.mcp.json` (`mcpServers.<name>`)
2. `<graff_home>/.codegraff/mcp.json` (`mcpServers.<name>`)

Accepted fields on a server entry:
- `url`, `httpUrl`, or `serverUrl`: must use `https://`, or `http://` strictly on loopback (`127.0.0.1`, `localhost`, `[::1]`).
- `headers`: optional map of HTTP headers (held strictly in the engine, never serialized to chat documents or WebKit).
- `useCodegraffAuth` (or `auth: "codegraff"`): opt-in flag instructing the engine to attach `Authorization: Bearer <cg_sk_...>` from `~/.simple-harness-codegraff.json` (`Sign in with CodeGraff`) solely when calling that server — the key never crosses into docs or WebKit.

During Streamable HTTP `initialize`, the engine advertises:

```json
{
  "protocolVersion": "2025-03-26",
  "clientInfo": { "name": "NanoHarness", "version": "0.2.x" },
  "capabilities": {
    "extensions": {
      "io.modelcontextprotocol/ui": {
        "mimeTypes": ["text/html;profile=mcp-app"]
      }
    }
  }
}
```

## Transcript Part & ACP Normalization

On terminal tool updates (`completed` or `failed`), `crates/harness/src/acp/normalize.rs` extracts `AgentEvent::McpApp { id, app }` when any of the following metadata shapes are present:
- `_meta.ui.resourceUri` or `_meta["ui/resourceUri"]` (string starting with `ui://`)
- `_meta["graff/mcpApp"]` (`{ server, resourceUri, tool?, title? }`)

Server resolution order: `_meta["graff/mcpApp"].server` -> `_meta.mcp.server` -> `mcp__<server>__<tool>` tool-name prefix.

`harness-proto::McpAppRef` enforces:
- `serverName`: 1–128 chars in `[A-Za-z0-9._-]`
- `resourceUri`: starts with `ui://`, 6–512 printable ASCII chars, no whitespace, `..`, or `#`
- `toolName`: 1–128 chars in `[A-Za-z0-9._:-]`
- `toolInput` / `toolResult`: each capped to `256 KiB` serialized JSON when folded into docs (`MessagePart::Tool.mcp_app`).

## Engine RPC Surface (`harness-rpc`)

Added to `HeadlessRpc` / `EngineRpc` only (refused by `McpScopedRpc` and excluded from `RemoteRelayRpc` `forwardable`):

| Method | Request | Response |
| --- | --- | --- |
| `McpAppList` | `{ serverName, cwd? }` | `McpAppSummary[]` |
| `McpAppFetchResource` | `{ serverName, resourceUri, cwd? }` | `McpAppResource` (`html`, `mimeType`, `prefersBorder`, sanitized `csp`, `allowedAppTools`) |
| `McpAppCallTool` | `{ serverName, toolName, arguments?, cwd? }` | MCP `tools/call` JSON result (`content`, `structuredContent`, `isError`) |

## SEP-1865 (`2026-01-26`) Host Bridge Contract

### Supported JSON-RPC 2.0 Methods (App -> Host)
- `ui/initialize`: Returns `protocolVersion: "2026-01-26"`, `hostInfo`, `hostCapabilities`, and `hostContext` (`theme`, `displayMode`, `account` `{ codegraffEmail?, harnessEmail?, activeHarness?, activeModel? }`, `styles.variables` mapped from `theme.zig` tokens).
- `ui/notifications/initialized`: Triggers host delivery of `ui/notifications/tool-input` and `ui/notifications/tool-result` when present.
- `tools/call`: Verified against `allowedAppTools` (`_meta.ui.visibility` including `"app"` or default visible); disallowed tools fail with JSON-RPC `-32602`.
- `ui/update-model-context`: Records the app's summary text on the active tab session and displays a synced indicator in the pane header.
- `ui/open-link`: Opens only `https://` or loopback `http://127.0.0.1` / `http://localhost` links externally; rejects all other schemes with `-32602`.
- `ui/request-display-mode`: Switches between `"inline"` and `"fullscreen"` (`a.view.strip.expanded = .host`).
- `ui/notifications/size-changed`: Records preferred content height without scheduling per-frame relayout loops (ADR 0007).
- `ui/message`: Prefills the active chat composer with the handed-off prompt (restoring inline view if fullscreen so the user can review active account and submit) and acknowledges `{ "accepted": true }`.
- All other methods return JSON-RPC `-32601 Method not found`.

### Host -> App Notifications & Requests
- `ui/notifications/tool-input`
- `ui/notifications/tool-result`
- `ui/notifications/host-context-changed` (pushed live when NanoHarness switches light/dark appearance)
- `ui/resource-teardown` (dispatched on reload or close)

## Content Security Policy & Limits

- **HTML payload cap:** 4 MiB (`4 * 1024 * 1024` bytes), MIME type must be `text/html;profile=mcp-app`.
- **Iframe CSP:**
  - `default-src 'none'`
  - `script-src 'unsafe-inline'`
  - `style-src 'unsafe-inline'`
  - `img-src data: blob: <sanitized resourceDomains>`
  - `media-src data: blob:`
  - `font-src data: <sanitized resourceDomains>`
  - `connect-src <sanitized connectDomains | 'none'>`
  - `frame-src <sanitized frameDomains | 'none'>`
  - `form-action 'none'; base-uri 'none'`
- `_meta.ui.csp` domains are accepted only when strictly formatted as `https://<host>[:port]` or loopback `http://127.0.0.1[:port]` / `http://localhost[:port]` (no wildcards, paths, queries, fragments, or userinfo).

## Verification Gates

```sh
rustfmt --edition 2024 --config skip_children=true --check \
  crates/proto/src/agent.rs crates/doc/src/parts.rs crates/doc/src/schema.rs \
  crates/harness/src/acp/normalize.rs crates/rpc/src/lib.rs \
  crates/engine/src/lib.rs crates/engine/src/mcp_apps.rs crates/engine/src/rpc.rs

bash scripts/heavy-build.sh cargo test --locked -p harness-proto -p harness-doc -p harness-adapters -p harness-rpc
bash scripts/heavy-build.sh cargo test --locked -p harness-engine --lib mcp
cd apps/nano && bash ../../scripts/heavy-build.sh zig build test
```
