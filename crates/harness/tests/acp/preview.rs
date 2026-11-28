use super::*;

#[path = "preview_lifecycle.rs"]
mod lifecycle;

fn fixture(mode: &str, preview: bool) -> (tempfile::TempDir, AcpHarness, RunRequest) {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let executable = root.path().join("agent.py");
    std::fs::write(&executable, include_str!("../fixtures/fake-acp-preview.py")).unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::write(root.path().join("mode"), mode).unwrap();
    let harness = AcpHarness::grok()
        .with_executable(executable)
        .with_preview_stdio(preview);
    let mut req = request("Synthetic submission");
    req.cwd = root.path().to_str().unwrap().into();
    req.model = None;
    (root, harness, req)
}

fn traffic(root: &tempfile::TempDir) -> String {
    std::fs::read_to_string(root.path().join("traffic")).unwrap()
}

#[tokio::test]
async fn preview_default_and_fallback_each_submit_once() {
    for (enabled, handshakes) in [
        (false, "initialize 1\n"),
        (true, "initialize 2\ninitialize 1\n"),
    ] {
        let (root, harness, req) = fixture("fallback", enabled);
        // The v1 runner stays attached for steering while its sender is live.
        let (control, steering, _) = controls();
        let mut stream = harness.run(req, control).await.unwrap();
        let status = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if let AgentEvent::Done { status, .. } = stream.next().await.unwrap().unwrap() {
                    break status;
                }
            }
        })
        .await
        .unwrap();
        drop(steering);
        assert_eq!(status, DoneStatus::Completed);
        assert_eq!(
            traffic(&root),
            format!("{handshakes}session/new\nsession/prompt v1\n")
        );
    }
}

#[tokio::test]
async fn preview_ack_and_foreground_are_independent_with_typed_setup() {
    for (mode, expected) in [
        ("normal", DoneStatus::Completed),
        ("pre-ack", DoneStatus::Completed),
        ("error", DoneStatus::Errored),
    ] {
        let (root, harness, mut req) = fixture(mode, true);
        req.model_options
            .insert("example".into(), serde_json::json!(true));
        let events = run_to_end(&harness, req, controls().0).await;
        assert_eq!(
            dones(&events)
                .iter()
                .map(|(status, _)| *status)
                .collect::<Vec<_>>(),
            [expected]
        );
        assert!(events.iter().any(
            |event| matches!(event, AgentEvent::TextDelta { text } if text == "Synthetic reply")
        ));
        assert!(events.iter().any(|event| matches!(event, AgentEvent::AvailableCommands { commands } if commands.len() == 1 && commands[0].input_hint.as_deref() == Some("fixture argument"))));
        assert!(traffic(&root).starts_with(
            "initialize 2\nsession/new\nsession/set_config_option boolean\nsession/prompt "
        ));
    }
}

#[tokio::test]
async fn preview_uncertain_delivery_does_not_fallback_or_retry_and_key_survives_reconnect() {
    for mode in ["drop", "invalid-ack"] {
        let (root, harness, req) = fixture(mode, true);
        let (mut ctl, _, _) = controls();
        let origin = harness_adapters::RunOrigin {
            chat_id: "synthetic-chat".into(),
            submission_id: Some("synthetic-submission".into()),
            ..Default::default()
        };
        ctl.origin = Some(origin.clone());
        let events = run_to_end(&harness, req.clone(), ctl).await;
        assert!(matches!(
            dones(&events).as_slice(),
            [(DoneStatus::Disconnected, Some(_))]
        ));
        let first = traffic(&root);
        let key = first
            .strip_prefix("initialize 2\nsession/new\nsession/prompt ")
            .unwrap()
            .trim_end();
        assert!(key.starts_with("harness:"));
        assert!(!key.contains('\n'), "no retry or fallback");

        // Explicit reconnect invocation, not an adapter-initiated retry.
        std::fs::write(root.path().join("mode"), "normal").unwrap();
        let (mut ctl, _, _) = controls();
        ctl.origin = Some(origin);
        let mut req = req;
        req.resume = Some("synthetic-session".into());
        let events = run_to_end(&harness, req, ctl).await;
        assert_eq!(dones(&events), [(DoneStatus::Completed, None)]);
        assert_eq!(
            traffic(&root),
            format!("{first}initialize 2\nsession/resume\nsession/prompt {key}\n")
        );
    }
}

#[tokio::test]
async fn preview_foreground_cancel_is_session_scoped() {
    let (root, harness, req) = fixture("cancel", true);
    let (ctl, _, interrupt) = controls();
    let mut stream = harness.run(req, ctl).await.unwrap();
    let done = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match stream.next().await.unwrap().unwrap() {
                AgentEvent::TextDelta { .. } => interrupt.cancel(),
                AgentEvent::Done { status, .. } => break status,
                _ => {}
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(done, DoneStatus::Interrupted);
    assert!(traffic(&root).ends_with("\nsession/cancel\n"));
}
