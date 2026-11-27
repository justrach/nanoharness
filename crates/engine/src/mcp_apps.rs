//! Engine-side SEP-1865 MCP Apps runtime (Streamable HTTP JSON-RPC 2.0).
//!
//! Server URLs and HTTP headers stay in `<cwd>/.mcp.json` / `<graff_home>/.codegraff/mcp.json`
//! and never cross into chat documents or WebKit views.

use std::collections::BTreeMap;
use std::net::IpAddr;
use std::path::Path;
use std::time::Duration;

use harness_proto::{
    McpAppCsp, McpAppResource, McpAppSummary, is_valid_mcp_identifier, is_valid_mcp_tool_name,
    is_valid_mcp_ui_uri,
};
use serde_json::{Value, json};

use crate::EngineError;

pub const MCP_PROTOCOL_VERSION: &str = "2025-03-26";
pub const MAX_HTML_BYTES: usize = 4 * 1024 * 1024;
const MAX_HTTP_BODY_BYTES: usize = 8 * 1024 * 1024;
const MAX_LIST_PAGES: usize = 16;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedServerConfig {
    pub url: String,
    pub headers: BTreeMap<String, String>,
}

fn is_loopback_host(host: &str) -> bool {
    let trimmed = host.trim_start_matches('[').trim_end_matches(']');
    if trimmed.eq_ignore_ascii_case("localhost") {
        return true;
    }
    trimmed
        .parse::<IpAddr>()
        .map(|ip| ip.is_loopback())
        .unwrap_or(false)
}

/// Server URLs may use `https://` anywhere or `http://` strictly on loopback.
pub fn is_allowed_server_url(raw: &str) -> bool {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed
            .bytes()
            .any(|b| b.is_ascii_control() || b.is_ascii_whitespace())
    {
        return false;
    }
    let Ok(parsed) = reqwest::Url::parse(trimmed) else {
        return false;
    };
    if !parsed.username().is_empty() || parsed.password().is_some() || parsed.fragment().is_some() {
        return false;
    }
    let Some(host) = parsed.host_str() else {
        return false;
    };
    if host.is_empty() {
        return false;
    }
    match parsed.scheme() {
        "https" => true,
        "http" => is_loopback_host(host),
        _ => false,
    }
}

/// Sanitize one origin entry from `_meta.ui.csp.{resourceDomains,connectDomains,frameDomains}`.
/// Permits only `https://<host>[:port]` or loopback `http://127.0.0.1[:port]` / `localhost[:port]`.
pub fn sanitize_csp_domain(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.contains('*')
        || trimmed.contains('?')
        || trimmed.contains('#')
        || trimmed.contains('@')
        || trimmed
            .bytes()
            .any(|b| b.is_ascii_control() || b.is_ascii_whitespace())
    {
        return None;
    }
    let parsed = reqwest::Url::parse(trimmed).ok()?;
    if !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }
    if parsed.path() != "" && parsed.path() != "/" {
        return None;
    }
    let host = parsed.host_str()?;
    if host.is_empty() {
        return None;
    }
    let scheme = parsed.scheme();
    let allowed = match scheme {
        "https" => true,
        "http" => is_loopback_host(host),
        _ => false,
    };
    if !allowed {
        return None;
    }
    Some(match parsed.port() {
        Some(port) => format!("{scheme}://{host}:{port}"),
        None => format!("{scheme}://{host}"),
    })
}

/// Returns true for `text/html;profile=mcp-app` (tolerating parameter whitespace or extra params).
pub fn is_mcp_app_mime(mime: &str) -> bool {
    let mut parts = mime.split(';').map(str::trim);
    let Some(base) = parts.next() else {
        return false;
    };
    if !base.eq_ignore_ascii_case("text/html") {
        return false;
    }
    parts.any(|param| {
        let Some((key, val)) = param.split_once('=') else {
            return false;
        };
        key.trim().eq_ignore_ascii_case("profile")
            && val.trim().trim_matches('"').eq_ignore_ascii_case("mcp-app")
    })
}

/// SEP-1865 `_meta.ui.visibility`: default (`None`) allows both `"model"` and `"app"`.
pub fn tool_is_app_visible(tool: &Value) -> bool {
    let vis = tool
        .pointer("/_meta/ui/visibility")
        .or_else(|| tool.pointer("/_meta/ui~1visibility"));
    let Some(Value::Array(items)) = vis else {
        return true;
    };
    items.iter().any(|item| item.as_str() == Some("app"))
}

fn tool_resource_uri(tool: &Value) -> Option<&str> {
    tool.pointer("/_meta/ui/resourceUri")
        .and_then(Value::as_str)
        .or_else(|| {
            tool.pointer("/_meta/ui~1resourceUri")
                .and_then(Value::as_str)
        })
        .filter(|uri| is_valid_mcp_ui_uri(uri))
}

fn parse_server_entry(
    server_name: &str,
    entry: &Value,
    codegraff_key: Option<&str>,
) -> Result<ResolvedServerConfig, EngineError> {
    let obj = entry.as_object().ok_or_else(|| {
        EngineError::Other(format!(
            "MCP server '{server_name}' configuration must be a JSON object"
        ))
    })?;
    if obj.get("enabled").and_then(Value::as_bool) == Some(false)
        || obj.get("disabled").and_then(Value::as_bool) == Some(true)
    {
        return Err(EngineError::Other(format!(
            "MCP server '{server_name}' is disabled"
        )));
    }
    let raw_url = ["url", "httpUrl", "serverUrl"]
        .iter()
        .find_map(|key| obj.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            EngineError::Other(format!(
                "MCP server '{server_name}' does not declare a Streamable HTTP URL"
            ))
        })?;
    if !is_allowed_server_url(raw_url) {
        return Err(EngineError::Other(format!(
            "MCP server '{server_name}' URL must use https:// or loopback http://"
        )));
    }
    let mut headers = BTreeMap::new();
    if let Some(hdr_obj) = obj.get("headers").and_then(Value::as_object) {
        for (k, v) in hdr_obj {
            let Some(val) = v.as_str() else {
                continue;
            };
            let key = k.trim();
            if key.is_empty()
                || key.bytes().any(|b| b.is_ascii_control())
                || val.bytes().any(|b| b == b'\r' || b == b'\n' || b == 0)
            {
                continue;
            }
            headers.insert(key.to_owned(), val.to_owned());
        }
    }
    let use_codegraff_auth = obj
        .get("useCodegraffAuth")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || obj
            .get("auth")
            .and_then(Value::as_str)
            .is_some_and(|s| s.eq_ignore_ascii_case("codegraff"));
    let has_auth_header = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("authorization"));
    if use_codegraff_auth && !has_auth_header {
        let key = codegraff_key
            .map(str::trim)
            .filter(|k| k.starts_with("cg_sk_"))
            .ok_or_else(|| {
                EngineError::Other(format!(
                    "MCP server '{server_name}' requires Sign in with CodeGraff (Settings > Accounts)."
                ))
            })?;
        headers.insert("Authorization".into(), format!("Bearer {key}"));
    }
    Ok(ResolvedServerConfig {
        url: raw_url.to_owned(),
        headers,
    })
}

pub(crate) fn resolve_server_config_with_key(
    graff_home: &Path,
    cwd: Option<&Path>,
    server_name: &str,
    codegraff_key: Option<&str>,
) -> Result<ResolvedServerConfig, EngineError> {
    if !is_valid_mcp_identifier(server_name) {
        return Err(EngineError::Other(format!(
            "Invalid MCP server identifier: {server_name}"
        )));
    }
    let mut candidates = Vec::new();
    if let Some(dir) = cwd.filter(|d| !d.as_os_str().is_empty()) {
        candidates.push(dir.join(".mcp.json"));
    }
    candidates.push(graff_home.join(".codegraff").join("mcp.json"));

    let mut last_err: Option<EngineError> = None;
    for path in candidates {
        let Ok(raw) = std::fs::read_to_string(&path) else {
            continue;
        };
        let parsed: Value = match serde_json::from_str(&raw) {
            Ok(v) => v,
            Err(err) => {
                last_err = Some(EngineError::Other(format!(
                    "Invalid JSON in {}: {err}",
                    path.display()
                )));
                continue;
            }
        };
        if let Some(entry) = parsed.get("mcpServers").and_then(|s| s.get(server_name)) {
            return parse_server_entry(server_name, entry, codegraff_key);
        }
    }
    Err(last_err.unwrap_or_else(|| {
        EngineError::Other(format!(
            "MCP server '{server_name}' was not found in .mcp.json or ~/.codegraff/mcp.json"
        ))
    }))
}

#[cfg(test)]
pub(crate) fn resolve_server_config(
    graff_home: &Path,
    cwd: Option<&Path>,
    server_name: &str,
) -> Result<ResolvedServerConfig, EngineError> {
    resolve_server_config_with_key(graff_home, cwd, server_name, None)
}

fn parse_sse_jsonrpc(body: &str, expected_id: u64) -> Option<Value> {
    let mut last_match: Option<Value> = None;
    let mut data_lines: Vec<&str> = Vec::new();

    let mut flush_event = |lines: &mut Vec<&str>| {
        if lines.is_empty() {
            return;
        }
        let joined = lines.join("\n");
        lines.clear();
        let trimmed = joined.trim();
        if trimmed.is_empty() {
            return;
        }
        if let Ok(val) = serde_json::from_str::<Value>(trimmed)
            && val.get("id").and_then(Value::as_u64) == Some(expected_id)
        {
            last_match = Some(val);
        }
    };

    for raw_line in body.lines() {
        let line = raw_line.trim_end_matches('\r');
        if line.is_empty() {
            flush_event(&mut data_lines);
            continue;
        }
        if let Some(rest) = line.strip_prefix("data:") {
            data_lines.push(rest.strip_prefix(' ').unwrap_or(rest));
        }
    }
    flush_event(&mut data_lines);
    last_match
}

struct McpHttpSession {
    client: reqwest::Client,
    config: ResolvedServerConfig,
    session_id: Option<String>,
    next_id: u64,
}

impl McpHttpSession {
    fn new(config: ResolvedServerConfig) -> Result<Self, EngineError> {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(|e| EngineError::Other(format!("Failed to create HTTP client: {e}")))?;
        Ok(Self {
            client,
            config,
            session_id: None,
            next_id: 1,
        })
    }

    async fn send_post(
        &mut self,
        payload: Value,
    ) -> Result<(reqwest::StatusCode, String, String), EngineError> {
        let mut req = self
            .client
            .post(&self.config.url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .header(
                reqwest::header::ACCEPT,
                "application/json, text/event-stream",
            )
            .header("MCP-Protocol-Version", MCP_PROTOCOL_VERSION);

        if let Some(sid) = &self.session_id {
            req = req.header("Mcp-Session-Id", sid);
        }
        for (k, v) in &self.config.headers {
            if k.eq_ignore_ascii_case("host")
                || k.eq_ignore_ascii_case("content-length")
                || k.eq_ignore_ascii_case("transfer-encoding")
            {
                continue;
            }
            req = req.header(k.as_str(), v.as_str());
        }

        let resp = req
            .json(&payload)
            .send()
            .await
            .map_err(|e| EngineError::Other(format!("MCP HTTP request failed: {e}")))?;

        if let Some(sid) = resp
            .headers()
            .get("mcp-session-id")
            .and_then(|h| h.to_str().ok())
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            self.session_id = Some(sid.to_owned());
        }

        let status = resp.status();
        let content_type = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|h| h.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        if let Some(len) = resp.content_length()
            && len as usize > MAX_HTTP_BODY_BYTES
        {
            return Err(EngineError::Other(
                "MCP HTTP response exceeded 8 MiB limit".into(),
            ));
        }

        let bytes = resp
            .bytes()
            .await
            .map_err(|e| EngineError::Other(format!("MCP HTTP body read failed: {e}")))?;
        if bytes.len() > MAX_HTTP_BODY_BYTES {
            return Err(EngineError::Other(
                "MCP HTTP response exceeded 8 MiB limit".into(),
            ));
        }
        let text = String::from_utf8(bytes.to_vec())
            .map_err(|_| EngineError::Other("MCP HTTP response was not valid UTF-8".into()))?;
        Ok((status, content_type, text))
    }

    async fn rpc(&mut self, method: &str, params: Value) -> Result<Value, EngineError> {
        let id = self.next_id;
        self.next_id += 1;
        let payload = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        let (status, content_type, text) = self.send_post(payload).await?;
        if !status.is_success() {
            let preview: String = text.chars().take(200).collect();
            return Err(EngineError::Other(format!(
                "MCP '{method}' failed with HTTP {}: {preview}",
                status.as_u16()
            )));
        }

        let rpc_obj = if content_type.contains("text/event-stream") {
            parse_sse_jsonrpc(&text, id).ok_or_else(|| {
                EngineError::Other(format!(
                    "MCP '{method}' SSE response contained no matching JSON-RPC frame"
                ))
            })?
        } else {
            serde_json::from_str::<Value>(&text).map_err(|e| {
                EngineError::Other(format!("MCP '{method}' returned invalid JSON: {e}"))
            })?
        };

        if let Some(err) = rpc_obj.get("error") {
            let msg = err
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("MCP JSON-RPC error");
            return Err(EngineError::Other(format!("MCP '{method}': {msg}")));
        }
        Ok(rpc_obj.get("result").cloned().unwrap_or(Value::Null))
    }

    async fn notify(&mut self, method: &str, params: Value) -> Result<(), EngineError> {
        let payload = json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        });
        let _ = self.send_post(payload).await?;
        Ok(())
    }

    async fn initialize(&mut self) -> Result<(), EngineError> {
        let _ = self
            .rpc(
                "initialize",
                json!({
                    "protocolVersion": MCP_PROTOCOL_VERSION,
                    "clientInfo": {
                        "name": "NanoHarness",
                        "version": env!("CARGO_PKG_VERSION"),
                    },
                    "capabilities": {
                        "extensions": {
                            "io.modelcontextprotocol/ui": {
                                "mimeTypes": ["text/html;profile=mcp-app"]
                            }
                        }
                    }
                }),
            )
            .await?;
        self.notify("notifications/initialized", json!({})).await?;
        Ok(())
    }

    async fn list_all_tools(&mut self) -> Result<Vec<Value>, EngineError> {
        let mut all = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..MAX_LIST_PAGES {
            let params = match &cursor {
                Some(c) => json!({ "cursor": c }),
                None => json!({}),
            };
            let res = self.rpc("tools/list", params).await?;
            if let Some(tools) = res.get("tools").and_then(Value::as_array) {
                all.extend(tools.iter().cloned());
            }
            cursor = res
                .get("nextCursor")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            if cursor.is_none() {
                break;
            }
        }
        Ok(all)
    }

    async fn list_all_resources(&mut self) -> Result<Vec<Value>, EngineError> {
        let mut all = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..MAX_LIST_PAGES {
            let params = match &cursor {
                Some(c) => json!({ "cursor": c }),
                None => json!({}),
            };
            let res = self.rpc("resources/list", params).await?;
            if let Some(items) = res.get("resources").and_then(Value::as_array) {
                all.extend(items.iter().cloned());
            }
            cursor = res
                .get("nextCursor")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            if cursor.is_none() {
                break;
            }
        }
        Ok(all)
    }
}

fn sanitize_domain_list(val: Option<&Value>) -> Vec<String> {
    val.and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .filter_map(sanitize_csp_domain)
                .collect()
        })
        .unwrap_or_default()
}

fn extract_csp(content_item: &Value) -> McpAppCsp {
    let ui = content_item
        .pointer("/_meta/ui/csp")
        .or_else(|| content_item.pointer("/_meta/ui~1csp"));
    let Some(csp) = ui else {
        return McpAppCsp::default();
    };
    McpAppCsp {
        resource_domains: sanitize_domain_list(csp.get("resourceDomains")),
        connect_domains: sanitize_domain_list(csp.get("connectDomains")),
        frame_domains: sanitize_domain_list(csp.get("frameDomains")),
    }
}

fn extract_prefers_border(content_item: &Value) -> bool {
    content_item
        .pointer("/_meta/ui/prefersBorder")
        .and_then(Value::as_bool)
        .or_else(|| {
            content_item
                .pointer("/_meta/ui~1prefersBorder")
                .and_then(Value::as_bool)
        })
        .unwrap_or(true)
}

/// List interactive `ui://` MCP Apps declared by `server_name`.
pub async fn list_apps(
    graff_home: &Path,
    cwd: Option<&Path>,
    server_name: &str,
    codegraff_key: Option<&str>,
) -> Result<Vec<McpAppSummary>, EngineError> {
    let cfg = resolve_server_config_with_key(graff_home, cwd, server_name, codegraff_key)?;
    let mut session = McpHttpSession::new(cfg)?;
    session.initialize().await?;

    let resources = session.list_all_resources().await?;
    let tools = session.list_all_tools().await?;

    let mut summaries = Vec::new();
    for res in &resources {
        let Some(uri) = res.get("uri").and_then(Value::as_str) else {
            continue;
        };
        if !is_valid_mcp_ui_uri(uri) {
            continue;
        }
        let mime = res.get("mimeType").and_then(Value::as_str).unwrap_or("");
        if !mime.is_empty() && !is_mcp_app_mime(mime) {
            continue;
        }
        let tool_names: Vec<String> = tools
            .iter()
            .filter(|t| tool_resource_uri(t) == Some(uri) && tool_is_app_visible(t))
            .filter_map(|t| t.get("name").and_then(Value::as_str))
            .filter(|name| is_valid_mcp_tool_name(name))
            .map(str::to_owned)
            .collect();
        summaries.push(McpAppSummary {
            server_name: server_name.to_owned(),
            resource_uri: uri.to_owned(),
            title: res
                .get("title")
                .or_else(|| res.get("name"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            description: res
                .get("description")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            tool_names,
        });
    }
    Ok(summaries)
}

/// Fetch one SEP-1865 `ui://` HTML resource and validate its MIME, HTML size, CSP,
/// and app-visible tools (`_meta.ui.visibility`).
pub async fn fetch_resource(
    graff_home: &Path,
    cwd: Option<&Path>,
    server_name: &str,
    resource_uri: &str,
    codegraff_key: Option<&str>,
) -> Result<McpAppResource, EngineError> {
    if !is_valid_mcp_ui_uri(resource_uri) {
        return Err(EngineError::Other(format!(
            "Invalid MCP App resource URI: {resource_uri}"
        )));
    }
    let cfg = resolve_server_config_with_key(graff_home, cwd, server_name, codegraff_key)?;
    let mut session = McpHttpSession::new(cfg)?;
    session.initialize().await?;

    let read_res = session
        .rpc("resources/read", json!({ "uri": resource_uri }))
        .await?;
    let contents = read_res
        .get("contents")
        .and_then(Value::as_array)
        .filter(|arr| !arr.is_empty())
        .ok_or_else(|| {
            EngineError::Other(format!(
                "MCP resource '{resource_uri}' returned empty contents"
            ))
        })?;
    let item = contents
        .iter()
        .find(|entry| entry.get("uri").and_then(Value::as_str) == Some(resource_uri))
        .unwrap_or(&contents[0]);

    let mime_type = item
        .get("mimeType")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::Other(format!("MCP resource '{resource_uri}' omitted mimeType"))
        })?;
    if !is_mcp_app_mime(mime_type) {
        return Err(EngineError::Other(format!(
            "MCP resource '{resource_uri}' has unsupported mimeType '{mime_type}'"
        )));
    }

    let html = item
        .get("text")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            EngineError::Other(format!("MCP resource '{resource_uri}' omitted text HTML"))
        })?;
    if html.len() > MAX_HTML_BYTES {
        return Err(EngineError::Other(format!(
            "MCP resource '{resource_uri}' exceeded 4 MiB HTML limit"
        )));
    }

    let tools = session.list_all_tools().await?;
    let allowed_app_tools: Vec<String> = tools
        .iter()
        .filter(|t| tool_is_app_visible(t))
        .filter_map(|t| t.get("name").and_then(Value::as_str))
        .filter(|name| is_valid_mcp_tool_name(name))
        .map(str::to_owned)
        .collect();

    Ok(McpAppResource {
        server_name: server_name.to_owned(),
        resource_uri: resource_uri.to_owned(),
        mime_type: mime_type.to_owned(),
        html: html.to_owned(),
        prefers_border: extract_prefers_border(item),
        csp: extract_csp(item),
        allowed_app_tools,
    })
}

/// Invoke an app-visible MCP tool (`_meta.ui.visibility` includes `"app"` or is unset).
pub async fn call_tool(
    graff_home: &Path,
    cwd: Option<&Path>,
    server_name: &str,
    tool_name: &str,
    arguments: Option<Value>,
    codegraff_key: Option<&str>,
) -> Result<Value, EngineError> {
    if !is_valid_mcp_tool_name(tool_name) {
        return Err(EngineError::Other(format!(
            "Invalid MCP tool name: {tool_name}"
        )));
    }
    let cfg = resolve_server_config_with_key(graff_home, cwd, server_name, codegraff_key)?;
    let mut session = McpHttpSession::new(cfg)?;
    session.initialize().await?;

    let tools = session.list_all_tools().await?;
    let tool_entry = tools
        .iter()
        .find(|t| t.get("name").and_then(Value::as_str) == Some(tool_name))
        .ok_or_else(|| {
            EngineError::Other(format!(
                "MCP tool '{tool_name}' is not declared by server '{server_name}'"
            ))
        })?;
    if !tool_is_app_visible(tool_entry) {
        return Err(EngineError::Other(format!(
            "MCP tool '{tool_name}' is restricted to model calls (_meta.ui.visibility)"
        )));
    }

    session
        .rpc(
            "tools/call",
            json!({
                "name": tool_name,
                "arguments": arguments.unwrap_or_else(|| json!({})),
            }),
        )
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn spawn_mock_mcp_server(
        use_sse_for_call: bool,
    ) -> (String, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                tokio::spawn(async move {
                    let mut buf = Vec::new();
                    let mut tmp = [0u8; 4096];
                    let mut header_end = None;
                    let mut content_len = 0usize;
                    loop {
                        let Ok(n) = stream.read(&mut tmp).await else {
                            return;
                        };
                        if n == 0 {
                            break;
                        }
                        buf.extend_from_slice(&tmp[..n]);
                        if header_end.is_none()
                            && let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n")
                        {
                            header_end = Some(pos + 4);
                            let hdrs = String::from_utf8_lossy(&buf[..pos]);
                            for line in hdrs.lines() {
                                if let Some((k, v)) = line.split_once(':')
                                    && k.trim().eq_ignore_ascii_case("content-length")
                                {
                                    content_len = v.trim().parse().unwrap_or(0);
                                }
                            }
                        }
                        if let Some(end) = header_end
                            && buf.len() >= end + content_len
                        {
                            break;
                        }
                    }
                    let Some(end) = header_end else {
                        return;
                    };
                    let body = &buf[end..end + content_len];
                    let req: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
                    let method = req.get("method").and_then(Value::as_str).unwrap_or("");
                    let id = req.get("id").cloned();

                    let (ctype, resp_body) = match method {
                        "notifications/initialized" => (
                            "application/json",
                            String::new(),
                        ),
                        "initialize" => (
                            "application/json",
                            json!({
                                "jsonrpc": "2.0",
                                "id": id,
                                "result": {
                                    "protocolVersion": MCP_PROTOCOL_VERSION,
                                    "serverInfo": { "name": "mock-mcp", "version": "1.0.0" },
                                    "capabilities": { "tools": {}, "resources": {} }
                                }
                            })
                            .to_string(),
                        ),
                        "resources/list" => (
                            "application/json",
                            json!({
                                "jsonrpc": "2.0",
                                "id": id,
                                "result": {
                                    "resources": [{
                                        "uri": "ui://mock/studio.html",
                                        "name": "studio_app",
                                        "title": "Review Studio",
                                        "mimeType": "text/html;profile=mcp-app"
                                    }]
                                }
                            })
                            .to_string(),
                        ),
                        "tools/list" => (
                            "application/json",
                            json!({
                                "jsonrpc": "2.0",
                                "id": id,
                                "result": {
                                    "tools": [
                                        {
                                            "name": "list_screens",
                                            "_meta": { "ui": { "resourceUri": "ui://mock/studio.html", "visibility": ["model", "app"] } }
                                        },
                                        {
                                            "name": "app_only_submit",
                                            "_meta": { "ui": { "visibility": ["app"] } }
                                        },
                                        {
                                            "name": "model_only_secret",
                                            "_meta": { "ui": { "visibility": ["model"] } }
                                        }
                                    ]
                                }
                            })
                            .to_string(),
                        ),
                        "resources/read" => {
                            let uri = req
                                .pointer("/params/uri")
                                .and_then(Value::as_str)
                                .unwrap_or("");
                            let html = if uri == "ui://mock/oversized.html" {
                                "x".repeat(MAX_HTML_BYTES + 16)
                            } else {
                                "<!doctype html><html><body>Synthetic Studio</body></html>".into()
                            };
                            let mime = if uri == "ui://mock/badmime.html" {
                                "text/plain"
                            } else {
                                "text/html;profile=mcp-app"
                            };
                            (
                                "application/json",
                                json!({
                                    "jsonrpc": "2.0",
                                    "id": id,
                                    "result": {
                                        "contents": [{
                                            "uri": uri,
                                            "mimeType": mime,
                                            "text": html,
                                            "_meta": {
                                                "ui": {
                                                    "prefersBorder": true,
                                                    "csp": {
                                                        "resourceDomains": [
                                                            "https://cdn.example.com/",
                                                            "javascript:alert(1)",
                                                            "https://*.wildcard.invalid",
                                                            "http://insecure.example.com"
                                                        ],
                                                        "connectDomains": ["https://api.example.com:8443"],
                                                        "frameDomains": ["http://127.0.0.1:8788"]
                                                    }
                                                }
                                            }
                                        }]
                                    }
                                })
                                .to_string(),
                            )
                        }
                        "tools/call" => {
                            let name = req
                                .pointer("/params/name")
                                .and_then(Value::as_str)
                                .unwrap_or("");
                            let frame = json!({
                                "jsonrpc": "2.0",
                                "id": id,
                                "result": {
                                    "content": [{ "type": "text", "text": format!("called:{name}") }],
                                    "structuredContent": { "tool": name, "ok": true }
                                }
                            })
                            .to_string();
                            if use_sse_for_call {
                                ("text/event-stream", format!("event: message\ndata: {frame}\n\n"))
                            } else {
                                ("application/json", frame)
                            }
                        }
                        _ => (
                            "application/json",
                            json!({
                                "jsonrpc": "2.0",
                                "id": id,
                                "error": { "code": -32601, "message": "Method not found" }
                            })
                            .to_string(),
                        ),
                    };
                    let status = if resp_body.is_empty() {
                        "202 Accepted"
                    } else {
                        "200 OK"
                    };
                    let reply = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nMcp-Session-Id: sess-1\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{resp_body}",
                        resp_body.len()
                    );
                    let _ = stream.write_all(reply.as_bytes()).await;
                });
            }
        });
        (format!("http://127.0.0.1:{port}/mcp"), handle)
    }

    #[test]
    fn validates_urls_mime_and_csp_origins() {
        assert!(is_allowed_server_url("https://eval.example.com/mcp"));
        assert!(is_allowed_server_url("http://127.0.0.1:8788/mcp?token=abc"));
        assert!(is_allowed_server_url("http://localhost:3000/mcp"));
        assert!(!is_allowed_server_url("http://example.com/mcp"));
        assert!(!is_allowed_server_url("file:///etc/passwd"));
        assert!(!is_allowed_server_url("javascript:alert(1)"));

        assert_eq!(
            sanitize_csp_domain("https://cdn.example.com/"),
            Some("https://cdn.example.com".into())
        );
        assert_eq!(
            sanitize_csp_domain("http://127.0.0.1:8788"),
            Some("http://127.0.0.1:8788".into())
        );
        assert_eq!(sanitize_csp_domain("https://cdn.example.com/subpath"), None);
        assert_eq!(sanitize_csp_domain("https://*.example.com"), None);
        assert_eq!(sanitize_csp_domain("http://evil.com"), None);
        assert_eq!(sanitize_csp_domain("javascript:alert(1)"), None);

        assert!(is_mcp_app_mime("text/html;profile=mcp-app"));
        assert!(is_mcp_app_mime(
            "TEXT/HTML; charset=utf-8; profile=\"mcp-app\""
        ));
        assert!(!is_mcp_app_mime("text/html"));
        assert!(!is_mcp_app_mime("text/plain"));
    }

    #[test]
    fn project_mcp_json_overrides_user_config() {
        let home = tempfile::tempdir().unwrap();
        let proj = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join(".codegraff")).unwrap();
        std::fs::write(
            home.path().join(".codegraff/mcp.json"),
            r#"{"mcpServers":{"demo":{"url":"https://global.example.com/mcp","headers":{"Authorization":"Bearer global"}}}}"#,
        )
        .unwrap();
        std::fs::write(
            proj.path().join(".mcp.json"),
            r#"{"mcpServers":{"demo":{"url":"https://project.example.com/mcp"}}}"#,
        )
        .unwrap();

        let cfg = resolve_server_config(home.path(), Some(proj.path()), "demo").unwrap();
        assert_eq!(cfg.url, "https://project.example.com/mcp");
    }

    #[tokio::test]
    async fn lists_fetches_sanitizes_and_calls_visible_tools_only() {
        let (url, _srv) = spawn_mock_mcp_server(true).await;
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join(".codegraff")).unwrap();
        std::fs::write(
            home.path().join(".codegraff/mcp.json"),
            json!({
                "mcpServers": {
                    "mockapp": {
                        "url": url,
                        "headers": { "Authorization": "Bearer secret-tok" }
                    }
                }
            })
            .to_string(),
        )
        .unwrap();

        let apps = list_apps(home.path(), None, "mockapp", None).await.unwrap();
        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].resource_uri, "ui://mock/studio.html");
        assert_eq!(apps[0].tool_names, vec!["list_screens"]);

        let res = fetch_resource(home.path(), None, "mockapp", "ui://mock/studio.html", None)
            .await
            .unwrap();
        assert!(res.html.contains("Synthetic Studio"));
        assert_eq!(res.csp.resource_domains, vec!["https://cdn.example.com"]);
        assert_eq!(
            res.csp.connect_domains,
            vec!["https://api.example.com:8443"]
        );
        assert_eq!(res.csp.frame_domains, vec!["http://127.0.0.1:8788"]);
        assert_eq!(
            res.allowed_app_tools,
            vec!["list_screens", "app_only_submit"]
        );

        // Allowed SSE tool call succeeds.
        let call_ok = call_tool(
            home.path(),
            None,
            "mockapp",
            "app_only_submit",
            Some(json!({ "rating": 5 })),
            None,
        )
        .await
        .unwrap();
        assert_eq!(call_ok["structuredContent"]["tool"], "app_only_submit");

        // Model-only and undeclared tools are blocked.
        let err_model = call_tool(
            home.path(),
            None,
            "mockapp",
            "model_only_secret",
            None,
            None,
        )
        .await
        .unwrap_err()
        .to_string();
        assert!(err_model.contains("model calls"), "{err_model}");

        let err_unknown = call_tool(home.path(), None, "mockapp", "nonexistent", None, None)
            .await
            .unwrap_err()
            .to_string();
        assert!(err_unknown.contains("not declared"), "{err_unknown}");

        // Bad MIME & oversized HTML are rejected.
        assert!(
            fetch_resource(home.path(), None, "mockapp", "ui://mock/badmime.html", None)
                .await
                .is_err()
        );
        assert!(
            fetch_resource(
                home.path(),
                None,
                "mockapp",
                "ui://mock/oversized.html",
                None,
            )
            .await
            .is_err()
        );
    }

    #[test]
    fn use_codegraff_auth_injects_bearer_and_fails_when_signed_out() {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join(".codegraff")).unwrap();
        std::fs::write(
            home.path().join(".codegraff/mcp.json"),
            r#"{"mcpServers":{"rle":{"url":"https://rle.example.com/mcp","useCodegraffAuth":true}}}"#,
        )
        .unwrap();

        let err = resolve_server_config_with_key(home.path(), None, "rle", None)
            .unwrap_err()
            .to_string();
        assert!(err.contains("Sign in with CodeGraff"), "{err}");

        let cfg = resolve_server_config_with_key(home.path(), None, "rle", Some("cg_sk_test_1234"))
            .unwrap();
        assert_eq!(
            cfg.headers.get("Authorization").map(String::as_str),
            Some("Bearer cg_sk_test_1234")
        );
    }
}
