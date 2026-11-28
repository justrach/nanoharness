//! Cloud computer subscription/status API (`codegraff.com/api/computer/*`) using the user's `cg_sk_` key.

use std::time::Duration;

use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{CodegraffAuth, http};

pub const CODEGRAFF_API_BASE: &str = "https://codegraff.com";
const TIMEOUT: Duration = Duration::from_secs(90);

fn api_base() -> String {
    std::env::var("HARNESS_CODEGRAFF_API_BASE")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| CODEGRAFF_API_BASE.into())
        .trim_end_matches('/')
        .to_owned()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffComputerSpec {
    pub cpu: u32,
    #[serde(rename = "memoryGiB")]
    pub memory_gib: u32,
    #[serde(rename = "diskGiB")]
    pub disk_gib: u32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffComputerSummary {
    pub state: String,
    pub slot: u32,
    pub machine_id: Option<String>,
    pub paid_through: Option<i64>,
    pub retire_at: Option<i64>,
    pub complimentary: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffComputerLive {
    pub phase: String,
    pub machine_id: Option<String>,
    pub state: Option<String>,
    pub device_name: Option<String>,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffComputerOffer {
    pub enabled: bool,
    pub on_sale: u32,
    pub free_slots: u32,
    pub total_slots: u32,
    pub price_monthly_usd: u32,
    pub spec: CodegraffComputerSpec,
    pub offer: Option<CodegraffComputerSummary>,
    pub live: CodegraffComputerLive,
    pub manage_url: String,
    pub billing_url: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffComputerCheckout {
    pub url: String,
}

impl CodegraffAuth {
    pub async fn computer_offer(&self) -> Result<Option<CodegraffComputerOffer>, String> {
        self.computer_offer_at(&api_base()).await
    }

    pub async fn computer_offer_at(
        &self,
        base: &str,
    ) -> Result<Option<CodegraffComputerOffer>, String> {
        let Some(key) = self.current_key() else {
            return Ok(None);
        };
        let base = base.trim_end_matches('/');
        crate::auth::validate_secure_url("CodeGraff", base)?;
        let response = http()
            .get(format!("{base}/api/computer/offer"))
            .bearer_auth(key)
            .timeout(TIMEOUT)
            .send()
            .await
            .map_err(|e| format!("Couldn't reach CodeGraff: {e}"))?;
        let status = response.status();
        if status.as_u16() == 404 {
            return Ok(Some(CodegraffComputerOffer::default()));
        }
        let body = response.json::<Value>().await.ok();
        if !status.is_success() {
            return Err(computer_error(status.as_u16(), body.as_ref()));
        }
        let body =
            body.ok_or_else(|| "CodeGraff returned an empty computer status.".to_string())?;
        serde_json::from_value(body)
            .map(Some)
            .map_err(|e| format!("Unexpected CodeGraff computer response: {e}"))
    }

    pub async fn computer_checkout(&self) -> Result<CodegraffComputerCheckout, String> {
        self.computer_checkout_at(&api_base()).await
    }

    pub async fn computer_checkout_at(
        &self,
        base: &str,
    ) -> Result<CodegraffComputerCheckout, String> {
        let out: CodegraffComputerCheckout =
            self.computer_post(base, "/api/computer/checkout").await?;
        crate::auth::validate_secure_url("Stripe Checkout", &out.url)?;
        Ok(out)
    }

    pub async fn computer_start(&self) -> Result<CodegraffComputerLive, String> {
        self.computer_start_at(&api_base()).await
    }

    pub async fn computer_start_at(&self, base: &str) -> Result<CodegraffComputerLive, String> {
        self.computer_post(base, "/api/computer/start").await
    }

    async fn computer_post<T: serde::de::DeserializeOwned>(
        &self,
        base: &str,
        path: &str,
    ) -> Result<T, String> {
        let key = self
            .current_key()
            .ok_or_else(|| "Sign in with Codegraff first.".to_string())?;
        let base = base.trim_end_matches('/');
        crate::auth::validate_secure_url("CodeGraff", base)?;
        let response = http()
            .request(Method::POST, format!("{base}{path}"))
            .bearer_auth(key)
            .header(reqwest::header::ACCEPT, "application/json")
            .timeout(Duration::from_secs(60))
            .send()
            .await
            .map_err(|e| format!("Couldn't reach CodeGraff: {e}"))?;
        let status = response.status();
        let body = response.json::<Value>().await.ok();
        if !status.is_success() {
            return Err(computer_error(status.as_u16(), body.as_ref()));
        }
        let body = body.ok_or_else(|| "CodeGraff returned an empty response.".to_string())?;
        serde_json::from_value(body)
            .map_err(|e| format!("Unexpected CodeGraff computer response: {e}"))
    }
}

fn computer_error(status: u16, body: Option<&Value>) -> String {
    let code = body
        .and_then(|v| v.get("error"))
        .and_then(|v| v.as_str().or_else(|| v.get("type").and_then(Value::as_str)));
    match code {
        Some("computers_sold_out") => "Cloud computers are sold out right now.".into(),
        Some("computer_exists") => {
            "You already have a Cloud computer: one per account.".into()
        }
        Some("computer_hold_limit") => {
            "Checkout pause limit reached for today. Try again tomorrow.".into()
        }
        Some("insufficient_scope") => {
            "This Codegraff sign-in lacks the sandbox permission needed for Cloud computers. Sign in again.".into()
        }
        Some("unauthorized") | Some("unauthenticated") => {
            "Sign in with Codegraff again to manage your Cloud computer.".into()
        }
        Some(other) => format!("Cloud computer request failed ({other})."),
        None => format!("Cloud computer request failed ({status})."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codegraff_auth::tests::auth_in;
    use crate::codegraff_auth::{KEY_FILE, write_private};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn mock_computer_site() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                tokio::spawn(async move {
                    let mut buf = [0u8; 4096];
                    let n = socket.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]);
                    let line = req.lines().next().unwrap_or("");
                    let (status, body) = if line.starts_with("GET /api/computer/offer") {
                        if req.contains("Bearer cg_sk_complimentary") {
                            (
                                "200 OK",
                                r#"{"enabled":true,"onSale":1,"freeSlots":0,"totalSlots":1,"priceMonthlyUsd":50,"spec":{"cpu":4,"memoryGiB":8,"diskGiB":60},"offer":{"state":"provisioned","slot":1,"machineId":"m_123","paidThrough":1798133213,"complimentary":true},"live":{"phase":"running","machineId":"m_123","deviceName":"Cloud computer"},"manageUrl":"https://codegraff.com/dashboard/sandboxes#computer","billingUrl":"https://codegraff.com/dashboard/billing"}"#,
                            )
                        } else {
                            (
                                "200 OK",
                                r#"{"enabled":true,"onSale":1,"freeSlots":1,"totalSlots":1,"priceMonthlyUsd":50,"spec":{"cpu":4,"memoryGiB":8,"diskGiB":60},"offer":{"state":"paid","slot":1},"live":{"phase":"none"},"manageUrl":"https://codegraff.com/dashboard/sandboxes#computer","billingUrl":"https://codegraff.com/dashboard/billing"}"#,
                            )
                        }
                    } else if line.starts_with("POST /api/computer/checkout") {
                        if req.contains("Bearer cg_sk_soldout") {
                            ("409 Conflict", r#"{"error":"computers_sold_out"}"#)
                        } else {
                            (
                                "200 OK",
                                r#"{"url":"https://checkout.stripe.com/c/pay/cs_test_123"}"#,
                            )
                        }
                    } else if line.starts_with("POST /api/computer/start") {
                        (
                            "200 OK",
                            r#"{"phase":"provisioning","machineId":"m_123","state":"provisioning"}"#,
                        )
                    } else {
                        ("404 Not Found", r#"{"error":"not_found"}"#)
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
    async fn computer_offer_checkout_and_start() {
        let base = mock_computer_site().await;
        let dir = tempfile::tempdir().unwrap();
        let auth = auth_in(dir.path(), base.clone());
        assert_eq!(auth.computer_offer_at(&base).await.unwrap(), None);

        write_private(
            &dir.path().join("home").join(KEY_FILE),
            br#"{"api_key":"cg_sk_comp"}"#,
        )
        .unwrap();
        let offer = auth.computer_offer_at(&base).await.unwrap().unwrap();
        assert!(offer.enabled);
        assert_eq!(offer.free_slots, 1);
        assert_eq!(offer.price_monthly_usd, 50);
        assert!(!offer.offer.as_ref().unwrap().complimentary);

        let checkout = auth.computer_checkout_at(&base).await.unwrap();
        assert_eq!(
            checkout.url,
            "https://checkout.stripe.com/c/pay/cs_test_123"
        );

        let started = auth.computer_start_at(&base).await.unwrap();
        assert_eq!(started.phase, "provisioning");
        assert_eq!(started.machine_id.as_deref(), Some("m_123"));

        write_private(
            &dir.path().join("home").join(KEY_FILE),
            br#"{"api_key":"cg_sk_complimentary"}"#,
        )
        .unwrap();
        let comp = auth.computer_offer_at(&base).await.unwrap().unwrap();
        assert!(comp.offer.as_ref().unwrap().complimentary);
        assert_eq!(comp.live.phase, "running");

        write_private(
            &dir.path().join("home").join(KEY_FILE),
            br#"{"api_key":"cg_sk_soldout"}"#,
        )
        .unwrap();
        let err = auth.computer_checkout_at(&base).await.unwrap_err();
        assert!(err.contains("sold out"));
    }
}
