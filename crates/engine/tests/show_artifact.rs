//! Explicit artifact intake must use the normal ordered journal/fold/doc pipeline.
use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use futures::stream::BoxStream;
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::MessagePart;
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SessionStatus, SteeringMode,
};

const CHAT: &str = "chat-show-artifact";
const ART_ID: &str = "art-0123456789abcdef01234567";

fn art_url() -> String {
    format!("https://codegraff.com/a/{ART_ID}")
}

fn done() -> AgentEvent {
    AgentEvent::Done {
        status: DoneStatus::Completed,
        result: None,
        error: None,
        session_id: None,
    }
}

fn request(cwd: &std::path::Path) -> RunRequest {
    RunRequest {
        turn_origin: Default::default(),
        prompt: "work".into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: cwd.to_string_lossy().into_owned(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: vec![],
        worktree: None,
        resume: None,
    }
}

#[derive(Default)]
struct ChannelHarness {
    tx: std::sync::Mutex<Option<tokio::sync::mpsc::Sender<Result<AgentEvent, HarnessError>>>>,
}

impl ChannelHarness {
    async fn emit(&self, event: AgentEvent) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        let tx = loop {
            if let Some(tx) = self.tx.lock().unwrap().clone() {
                break tx;
            }
            assert!(tokio::time::Instant::now() < deadline, "run did not start");
            tokio::time::sleep(Duration::from_millis(10)).await;
        };
        tx.send(Ok(event)).await.unwrap();
    }

    fn close(&self) {
        self.tx.lock().unwrap().take();
    }
}

#[async_trait]
impl Harness for ChannelHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Channel"
    }
    fn supports_steering(&self) -> bool {
        true
    }
    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::StepBoundary
    }
    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[ReasoningLevel::Medium]
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }
    async fn run(
        &self,
        _request: RunRequest,
        _controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let (tx, rx) = tokio::sync::mpsc::channel(16);
        *self.tx.lock().unwrap() = Some(tx);
        Ok(Box::pin(futures::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|event| (event, rx))
        })))
    }
}

fn assemble(dir: &std::path::Path, harness: Arc<ChannelHarness>) -> EngineCore {
    let registry = HarnessRegistry::new();
    registry.register(harness);
    EngineCore::assemble(dir, Arc::new(registry), HarnessId::Mock, None).unwrap()
}

fn parts(core: &EngineCore) -> Vec<MessagePart> {
    core.doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap()
        .into_iter()
        .flat_map(|entry| entry.parts)
        .collect()
}

fn artifact_parts(core: &EngineCore) -> Vec<MessagePart> {
    parts(core)
        .into_iter()
        .filter(|p| matches!(p, MessagePart::Artifact { .. }))
        .collect()
}

async fn wait_for(mut predicate: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !predicate() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "condition did not settle"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn show_artifact_ack_updates_in_place_and_dedupes_exact_replay() {
    let dir = tempfile::tempdir().unwrap();
    let harness = Arc::new(ChannelHarness::default());
    let core = assemble(dir.path(), harness.clone());
    let url = art_url();

    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request(dir.path()), None)
        .await
        .unwrap();
    harness
        .emit(AgentEvent::TextDelta {
            text: "before".into(),
        })
        .await;
    wait_for(|| {
        parts(&core)
            .iter()
            .any(|p| matches!(p, MessagePart::Text { text, .. } if text == "before"))
    })
    .await;

    core.sessions
        .show_artifact(CHAT, ART_ID, ART_ID, "Overview", "html", "private", &url)
        .await
        .unwrap();
    assert_eq!(artifact_parts(&core).len(), 1);

    // Exact replay is a no-op ACK.
    core.sessions
        .show_artifact(CHAT, ART_ID, ART_ID, "Overview", "html", "private", &url)
        .await
        .unwrap();
    assert_eq!(
        core.sessions
            .subscribe(CHAT, 0)
            .unwrap()
            .0
            .iter()
            .filter(|row| matches!(&row.event, AgentEvent::GeneratedArtifact { .. }))
            .count(),
        1
    );

    // Updating title and visibility on the same artifact updates the single doc part in place.
    core.sessions
        .show_artifact(
            CHAT,
            ART_ID,
            ART_ID,
            "Updated Overview",
            "svg",
            "public",
            &url,
        )
        .await
        .unwrap();
    let current = artifact_parts(&core);
    assert_eq!(current.len(), 1);
    assert!(matches!(
        &current[0],
        MessagePart::Artifact { id, artifact_id, title, format, visibility, url: u }
            if id == &format!("show-artifact:{ART_ID}")
                && artifact_id == ART_ID
                && title == "Updated Overview"
                && format == "svg"
                && visibility == "public"
                && u == &url
    ));

    harness
        .emit(AgentEvent::TextDelta {
            text: "after".into(),
        })
        .await;
    harness.emit(done()).await;
    wait_for(|| {
        core.sessions
            .session_status(CHAT)
            .is_some_and(|s| s.status == SessionStatus::Idle)
    })
    .await;

    // Idle run rejects even exact replays.
    assert!(
        core.sessions
            .show_artifact(
                CHAT,
                ART_ID,
                ART_ID,
                "Updated Overview",
                "svg",
                "public",
                &url
            )
            .await
            .unwrap_err()
            .to_string()
            .contains("idle")
    );

    harness.close();
    core.doc_host.shutdown_workers().await;
    core.sessions.shutdown().await;
    drop(core);

    let core = assemble(dir.path(), Arc::new(ChannelHarness::default()));
    assert_eq!(
        artifact_parts(&core).len(),
        1,
        "artifact metadata survives snapshot/reopen"
    );
    core.sessions.shutdown().await;
}

#[tokio::test]
async fn show_artifact_rejects_signed_urls_bad_fields_and_interruption() {
    let dir = tempfile::tempdir().unwrap();
    let harness = Arc::new(ChannelHarness::default());
    let core = assemble(dir.path(), harness.clone());
    let url = art_url();

    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request(dir.path()), None)
        .await
        .unwrap();

    for bad_url in [
        format!("{url}?t=1900000900.sig"),
        format!("https://artifact.codegraff.com/{ART_ID}"),
        "https://evil.example/a/art-0123456789abcdef01234567".to_string(),
    ] {
        assert!(
            core.sessions
                .show_artifact(CHAT, ART_ID, ART_ID, "Title", "html", "private", &bad_url)
                .await
                .is_err()
        );
    }
    assert!(
        core.sessions
            .show_artifact(CHAT, ART_ID, "bad", "Title", "html", "private", &url)
            .await
            .is_err()
    );
    assert!(
        core.sessions
            .show_artifact(CHAT, ART_ID, ART_ID, "Title", "pdf", "private", &url)
            .await
            .is_err()
    );
    assert_eq!(artifact_parts(&core).len(), 0);

    core.sessions.interrupt(CHAT).await.unwrap();
    tokio::time::timeout(
        Duration::from_secs(10),
        core.sessions
            .show_artifact(CHAT, ART_ID, ART_ID, "Title", "html", "private", &url),
    )
    .await
    .unwrap()
    .expect_err("interrupted run must reject");
    assert_eq!(artifact_parts(&core).len(), 0);
    harness.close();
    core.sessions.shutdown().await;
}

#[tokio::test]
async fn create_and_update_artifact_rpc_enforce_owner_active_run_bounds_and_unknown_fields() {
    use harness_rpc::{memory_client, methods};
    use serde_json::json;

    let dir = tempfile::tempdir().unwrap();
    let harness = Arc::new(ChannelHarness::default());
    let core = assemble(dir.path(), harness.clone());
    let client = memory_client(core.rpc_service());
    let create_params = json!({
        "chatId": CHAT,
        "id": "req-1",
        "title": "Overview",
        "format": "html",
        "content": "<h1>Hello</h1>",
        "visibility": "private"
    });
    assert!(
        client
            .call(methods::CREATE_ARTIFACT, create_params.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("chat not found")
    );
    core.workspace
        .create_chat(
            CHAT,
            None,
            Some(&core.device_id),
            None,
            Some(dir.path().to_string_lossy().into_owned()),
        )
        .unwrap();
    assert!(
        client
            .call(methods::CREATE_ARTIFACT, create_params.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("No active run")
    );
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request(dir.path()), None)
        .await
        .unwrap();
    let mut spoof = create_params.clone();
    spoof["targetDeviceId"] = json!("another-device");
    assert!(
        client
            .call(methods::CREATE_ARTIFACT, spoof)
            .await
            .unwrap_err()
            .to_string()
            .contains("unknown field")
    );
    core.workspace
        .create_chat("foreign", None, Some("another-device"), None, None)
        .unwrap();
    let mut foreign = create_params.clone();
    foreign["chatId"] = json!("foreign");
    assert!(
        client
            .call(methods::CREATE_ARTIFACT, foreign)
            .await
            .unwrap_err()
            .to_string()
            .contains("another device")
    );
    let mut bad_format = create_params;
    bad_format["format"] = json!("pdf");
    assert!(
        client
            .call(methods::CREATE_ARTIFACT, bad_format)
            .await
            .unwrap_err()
            .to_string()
            .contains("html, svg, or markdown")
    );
    let empty_update = json!({
        "chatId": CHAT,
        "artifactId": ART_ID
    });
    assert!(
        client
            .call(methods::UPDATE_ARTIFACT, empty_update)
            .await
            .unwrap_err()
            .to_string()
            .contains("at least one artifact field")
    );

    harness.emit(done()).await;
    harness.close();
    core.sessions.shutdown().await;
}
