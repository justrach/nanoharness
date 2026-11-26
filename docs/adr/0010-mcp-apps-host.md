# ADR 0010: Isolated SEP-1865 MCP Apps Host and Engine Relay

- Status: Accepted
- Date: 2026-11-25

## Context

NanoHarness previously handled `_meta["graff/view"]` (`{ kind: "mcp_app", id }`) only as static offline HTML snapshots saved under `~/.graff/mcp-apps/<32-hex>.html` and loaded through `graff-view://mcp-app/<id>` in `apps/nano/src/browser_native.zig`. Those pages ran with `connect-src 'none'` and no host bridge (`tests_browser_native.zig` asserts zero `WKUserScript` injections and zero native IPC bridges on ordinary/generated browser panes).

Interactive MCP Apps implementing the SEP-1865 (`2026-01-26`) specification (such as the StandardHarness Review Studio) return dynamic `ui://...` HTML resources (`text/html;profile=mcp-app`) from remote or local Streamable HTTP MCP servers and rely on a structured JSON-RPC `postMessage` channel to receive host theme tokens and initial tool payloads, call allowlisted server tools (`tools/call`), sync state back to the conversation (`ui/update-model-context`), open external links safely (`ui/open-link`), and toggle inline/fullscreen presentation (`ui/request-display-mode`).

Loading external or dynamic app HTML inside the same `WKWebView` context as `nanoui`, or granting arbitrary scripts direct access to Harness's WebSocket IPC (`HeadlessRpc`), would break NanoHarness's process and credential isolation boundaries.

## Decision

1. **Preserve strict isolation on `browser_native.zig`.** Ordinary web pages, `graff-view://` snapshots, and hosted `artifact.codegraff.com` panes keep using `HarnessNanoBrowserDelegate` with zero `WKScriptMessageHandler` and zero `WKUserScript` bridges.

2. **Double-sandbox macOS host (`mcp_app_native.zig` + `mcp_app_host.zig`).** Interactive MCP Apps mount in a separate `HarnessNanoMcpAppDelegate` `WKWebView` backed by `WKWebsiteDataStore.nonPersistentDataStore()`:
   - The outer shell loads on `mcp-app://host/<session-id>` via an in-memory `WKURLSchemeHandler` and injects no ambient cookies or storage.
   - Untrusted MCP App HTML is wrapped in an opaque-origin `<iframe id="mcp-app-frame" sandbox="allow-scripts" srcdoc="...">` with an injected `<meta http-equiv="Content-Security-Policy">` derived strictly from sanitized `_meta.ui.csp` origins (`https://<host>[:port]` or loopback `http://127.0.0.1` / `localhost` only; wildcards, `javascript:`, `file:`, and `data:` navigation rejected).
   - Only the outer shell receives the narrow `window.webkit.messageHandlers.mcpApp` bridge, and `userContentController:didReceiveScriptMessage:` requires `message.frameInfo.isMainFrame == YES`, filtering inner iframe messages by `event.source === frame.contentWindow` and an explicit JSON-RPC method allowlist (`ui/initialize`, `ui/notifications/initialized`, `ui/notifications/size-changed`, `tools/call`, `ui/update-model-context`, `ui/open-link`, `ui/request-display-mode`, `ui/message`).
   - Host-to-app JSON-RPC frames cross from Zig into WebKit UTF-8 cleanly via base64 + `TextDecoder` into `window.__mcpHostDeliver(...)`.

3. **Engine-owned Streamable HTTP relay (`crates/engine/src/mcp_apps.rs`).** Secrets (`headers`, bearer tokens, query parameters in `.mcp.json` / `~/.codegraff/mcp.json`) stay in the engine and never enter chat docs, `MessagePart::Tool.mcp_app`, or WebKit state:
   - ACP normalization (`crates/harness/src/acp/normalize.rs`) captures only bounded metadata (`McpAppRef`: `serverName`, `resourceUri`, `toolName`, optional `title`, and capped `toolInput` / `toolResult`) onto `MessagePart::Tool`.
   - `McpAppList`, `McpAppFetchResource`, and `McpAppCallTool` are registered on `HeadlessRpc` / `EngineRpc` for local headed/UI use only — they are excluded from `McpScopedRpc` (so agents cannot invoke host MCP App relay endpoints) and excluded from `forwardable(...)`.
   - `McpAppFetchResource` validates `ui://` URIs, `text/html;profile=mcp-app` MIME type, and a 4 MiB HTML size limit, sanitizes CSP origins, and records `_meta.ui.visibility` allowlists (`allowedAppTools`).
   - `McpAppCallTool` verifies against the originating server's `tools/list` that the requested tool exists and includes `"app"` visibility (rejecting `"model"`-only or unknown tools).
   - The HTTP client disables HTTP redirects (`redirect::Policy::none()`) and refuses non-loopback `http://` endpoints.

4. **Non-blocking frames (ADR 0007).** Opening an MCP App tab and invoking `tools/call` dispatch asynchronously over `RpcClient` (`app_mcp_apps.zig`). Layout size updates record preferred dimensions without triggering `frameIn` feedback loops.

## Consequences

- Designers and engineers can open interactive `ui://` MCP App surfaces directly from tool chips in the split pane, while offline `~/.graff/mcp-apps/<32-hex>.html` snapshots continue working untouched.
- Server credentials in `.mcp.json` / `~/.codegraff/mcp.json` never reach WebKit or synced Loro chat documents.
- Non-macOS targets fail closed cleanly in the native pane without exposing external system-browser privileges to untrusted app HTML.
