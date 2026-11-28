//! Codegraff hosted artifacts (`gateway.codegraff.com/v1/artifacts`) for MCP tools & transcript cards.

use std::time::Duration;

use harness_proto::artifact::{
    ARTIFACT_TITLE_MAX_CHARS, is_valid_artifact_format, is_valid_artifact_id,
    is_valid_artifact_visibility,
};
use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{CodegraffAuth, http, urlencode};

pub const MAX_ARTIFACT_BYTES: usize = 2 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffArtifact {
    pub id: String,
    pub title: String,
    pub format: String,
    pub visibility: String,
    pub bytes: u64,
    pub sha256: String,
    pub url: String,
    pub public_url: Option<String>,
    pub frame_url: Option<String>,
    pub frame_expires_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffArtifactFrame {
    pub id: String,
    pub visibility: String,
    pub url: String,
    pub public_url: Option<String>,
    pub frame_url: String,
    pub frame_expires_at: Option<i64>,
}

impl CodegraffAuth {
    pub async fn create_artifact(
        &self,
        title: &str,
        format: &str,
        content: &str,
        visibility: Option<&str>,
    ) -> Result<CodegraffArtifact, String> {
        let title = title.trim();
        if title.is_empty() || title.chars().count() > ARTIFACT_TITLE_MAX_CHARS {
            return Err("Artifact title must be 1 to 200 characters.".into());
        }
        if !is_valid_artifact_format(format) {
            return Err("Artifact format must be html, svg, or markdown.".into());
        }
        if content.is_empty() || content.len() > MAX_ARTIFACT_BYTES {
            return Err("Artifact content must be non-empty and at most 2 MiB.".into());
        }
        if let Some(vis) = visibility
            && !is_valid_artifact_visibility(vis)
        {
            return Err("Artifact visibility must be private or public.".into());
        }
        let mut body = Map::new();
        body.insert("title".into(), json!(title));
        body.insert("format".into(), json!(format));
        body.insert("content".into(), json!(content));
        if let Some(vis) = visibility {
            body.insert("visibility".into(), json!(vis));
        }
        self.artifact_request(Method::POST, "/v1/artifacts", Some(Value::Object(body)))
            .await
    }

    pub async fn update_artifact(
        &self,
        artifact_id: &str,
        title: Option<&str>,
        format: Option<&str>,
        content: Option<&str>,
        visibility: Option<&str>,
    ) -> Result<CodegraffArtifact, String> {
        if !is_valid_artifact_id(artifact_id) {
            return Err("Invalid artifact id.".into());
        }
        let mut body = Map::new();
        if let Some(title) = title {
            let trimmed = title.trim();
            if trimmed.is_empty() || trimmed.chars().count() > ARTIFACT_TITLE_MAX_CHARS {
                return Err("Artifact title must be 1 to 200 characters.".into());
            }
            body.insert("title".into(), json!(trimmed));
        }
        if let Some(format) = format {
            if !is_valid_artifact_format(format) {
                return Err("Artifact format must be html, svg, or markdown.".into());
            }
            body.insert("format".into(), json!(format));
        }
        if let Some(content) = content {
            if content.is_empty() || content.len() > MAX_ARTIFACT_BYTES {
                return Err("Artifact content must be non-empty and at most 2 MiB.".into());
            }
            body.insert("content".into(), json!(content));
        }
        if let Some(vis) = visibility {
            if !is_valid_artifact_visibility(vis) {
                return Err("Artifact visibility must be private or public.".into());
            }
            body.insert("visibility".into(), json!(vis));
        }
        if body.is_empty() {
            return Err("Provide at least one artifact field to update.".into());
        }
        let path = format!("/v1/artifacts/{}", urlencode(artifact_id));
        self.artifact_request(Method::PATCH, &path, Some(Value::Object(body)))
            .await
    }

    pub async fn artifact_frame_url(
        &self,
        artifact_id: &str,
    ) -> Result<CodegraffArtifactFrame, String> {
        if !is_valid_artifact_id(artifact_id) {
            return Err("Invalid artifact id.".into());
        }
        let path = format!("/v1/artifacts/{}/frame-url", urlencode(artifact_id));
        self.artifact_request(Method::POST, &path, None).await
    }

    async fn artifact_request<T: serde::de::DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<T, String> {
        let key = self.current_key().ok_or_else(|| {
            "Sign in with Codegraff first to create or view artifacts.".to_string()
        })?;
        crate::auth::validate_secure_url("CodeGraff gateway", &self.gateway)?;
        let url = format!("{}{path}", self.gateway);
        let mut req = http()
            .request(method, url)
            .bearer_auth(key)
            .timeout(TIMEOUT);
        if let Some(body) = body {
            req = req.json(&body);
        }
        let response = req
            .send()
            .await
            .map_err(|e| format!("Couldn't reach CodeGraff: {e}"))?;
        let status = response.status();
        let value = response.json::<Value>().await.ok();
        if !status.is_success() {
            return Err(artifact_error(status.as_u16(), value.as_ref()));
        }
        let value =
            value.ok_or_else(|| "CodeGraff returned an empty artifact response.".to_string())?;
        serde_json::from_value(value)
            .map_err(|e| format!("Unexpected CodeGraff artifact response: {e}"))
    }
}

fn artifact_error(status: u16, body: Option<&Value>) -> String {
    let error_type = body
        .and_then(|v| v.pointer("/error/type"))
        .and_then(Value::as_str);
    match error_type {
        Some("insufficient_scope") => {
            return "This Codegraff sign-in cannot manage artifacts. Sign in again.".into();
        }
        Some("limit_exceeded") => {
            return "Artifact limit reached (200 per account). Delete an older artifact on codegraff.com first.".into();
        }
        Some("not_found") => return "Artifact not found.".into(),
        _ => {}
    }
    if status == 401 {
        return "Codegraff sign-in expired. Sign in again.".into();
    }
    let message = body
        .and_then(|v| v.pointer("/error/message"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|m| !m.is_empty());
    match message {
        Some(m) => m.to_string(),
        None => format!("CodeGraff artifact request failed ({status})."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codegraff_auth::tests::auth_in;
    use crate::codegraff_auth::{KEY_FILE, write_private};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn mock_artifact_gateway() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                tokio::spawn(async move {
                    let mut buf = [0u8; 8192];
                    let n = socket.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]);
                    let line = req.lines().next().unwrap_or("");
                    let art_id = "art-0123456789abcdef01234567";
                    let (status, body) = if line.starts_with("POST /v1/artifacts/art-")
                        && line.contains("/frame-url")
                    {
                        (
                            "200 OK",
                            format!(
                                r#"{{"id":"{art_id}","visibility":"private","url":"https://codegraff.com/a/{art_id}","publicUrl":null,"frameUrl":"https://artifact.codegraff.com/{art_id}?t=1900000900.sig","frameExpiresAt":1900000900}}"#
                            ),
                        )
                    } else if line.starts_with("PATCH /v1/artifacts/art-") {
                        (
                            "200 OK",
                            format!(
                                r#"{{"id":"{art_id}","title":"Updated","format":"html","visibility":"public","bytes":12,"sha256":"abc","url":"https://codegraff.com/a/{art_id}","publicUrl":"https://codegraff.com/public/a/{art_id}","frameUrl":"https://artifact.codegraff.com/{art_id}","frameExpiresAt":null,"createdAt":10,"updatedAt":20}}"#
                            ),
                        )
                    } else if line.starts_with("POST /v1/artifacts ") {
                        (
                            "201 Created",
                            format!(
                                r#"{{"id":"{art_id}","title":"Diagram","format":"html","visibility":"private","bytes":11,"sha256":"abc","url":"https://codegraff.com/a/{art_id}","publicUrl":null,"frameUrl":"https://artifact.codegraff.com/{art_id}?t=1900000900.sig","frameExpiresAt":1900000900,"createdAt":10,"updatedAt":10}}"#
                            ),
                        )
                    } else {
                        ("404 Not Found", r#"{"error":{"type":"not_found"}}"#.into())
                    };
                    let resp = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = socket.write_all(resp.as_bytes()).await;
                });
            }
        });
        format!("http://127.0.0.1:{port}")
    }

    #[tokio::test]
    async fn artifact_crud_and_frame_url_round_trip() {
        let gateway = mock_artifact_gateway().await;
        let dir = tempfile::tempdir().unwrap();
        let auth = auth_in(dir.path(), gateway);
        write_private(
            &dir.path().join("home").join(KEY_FILE),
            br#"{"api_key":"cg_sk_art_test"}"#,
        )
        .unwrap();

        let created = auth
            .create_artifact("Diagram", "html", "<h1>Hi</h1>", None)
            .await
            .unwrap();
        assert_eq!(created.id, "art-0123456789abcdef01234567");
        assert!(created.frame_url.unwrap().contains("?t="));

        let updated = auth
            .update_artifact(&created.id, Some("Updated"), None, None, Some("public"))
            .await
            .unwrap();
        assert_eq!(updated.visibility, "public");
        assert_eq!(
            updated.public_url.as_deref(),
            Some("https://codegraff.com/public/a/art-0123456789abcdef01234567")
        );

        let frame = auth.artifact_frame_url(&created.id).await.unwrap();
        assert_eq!(frame.frame_expires_at, Some(1900000900));
        assert!(auth.artifact_frame_url("bad-id").await.is_err());
    }
}
