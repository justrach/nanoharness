use super::*;

#[tokio::test]
async fn preview_targeted_tool_cancel_keeps_foreground_stop_separate() {
    use harness_adapters::acp::PreviewCancelTarget;
    let (root, harness, req) = fixture("targeted", true);
    let (mut ctl, _, _) = controls();
    ctl.origin = Some(harness_adapters::RunOrigin {
        chat_id: "owner".into(),
        ..Default::default()
    });
    let mut events = harness.run(req, ctl).await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(event) = events.next().await {
            if matches!(
                event.unwrap(),
                AgentEvent::Done {
                    status: DoneStatus::Completed,
                    ..
                }
            ) {
                let target = PreviewCancelTarget::Tool {
                    session: "synthetic-session".into(),
                    id: "owned".into(),
                };
                assert!(
                    !harness
                        .cancel_preview_target("other-chat", target.clone())
                        .await
                );
                assert!(
                    !harness
                        .cancel_preview_target(
                            "owner",
                            PreviewCancelTarget::Tool {
                                session: "foreign".into(),
                                id: "owned".into()
                            }
                        )
                        .await
                );
                assert!(harness.cancel_preview_target("owner", target).await);
                break;
            }
        }
        let tail: Vec<_> = events.by_ref().collect().await;
        assert!(tail.into_iter().any(|event| matches!(
            event.unwrap(),
            AgentEvent::BackgroundTask { running: false, .. }
        )));
    })
    .await
    .unwrap();
    assert_eq!(
        traffic(&root)
            .lines()
            .filter(|line| *line == "tool_call/cancel")
            .count(),
        1
    );
    assert!(!traffic(&root).contains("session/cancel"));
}

#[tokio::test]
async fn preview_requires_each_replay_barrier_before_submission() {
    let (root, harness, mut req) = fixture("missing-child-barrier", true);
    req.resume = Some("synthetic-session".into());
    let events = run_to_end(&harness, req, controls().0).await;
    assert!(
        matches!(dones(&events).as_slice(), [(DoneStatus::Errored, Some(message))] if message.contains("replay barrier"))
    );
    assert_eq!(traffic(&root), "initialize 2\nsession/resume\n");
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, AgentEvent::TextDelta { .. }))
    );
}

#[tokio::test]
async fn preview_scope_separates_tool_ids_and_rejects_foreign_interaction() {
    let (root, harness, req) = fixture("interaction", true);
    let events = run_to_end(&harness, req, controls().0).await;
    assert_eq!(dones(&events), [(DoneStatus::Completed, None)]);
    let tools: Vec<_> = events
        .iter()
        .filter_map(|e| match e {
            AgentEvent::ToolCall {
                id,
                call: ToolCall::Unknown { name, .. },
            } => Some((id, name.as_str())),
            _ => None,
        })
        .collect();
    assert_eq!(
        tools.iter().map(|(_, name)| *name).collect::<Vec<_>>(),
        ["Root tool", "Child tool"]
    );
    assert_ne!(tools[0].0, tools[1].0);
    let lifecycle: Vec<_> = events
        .iter()
        .filter_map(|event| match event {
            AgentEvent::BackgroundTask { running, .. } => Some(*running),
            _ => None,
        })
        .collect();
    assert_eq!(lifecycle, [true, false]);
    let traffic = traffic(&root);
    assert!(traffic.contains("foreign-form {\"action\": \"decline\"}"));
    assert!(traffic.contains("approval {\"outcome\": {\"outcome\": \"cancelled\"}}"));
    assert!(
        traffic.contains("owned-form {\"action\": \"accept\", \"content\": {\"answer\": \"Yes\"}}")
    );
}

#[tokio::test]
async fn preview_selector_is_per_request_on_one_adapter() {
    let (root, _, mut req) = fixture("normal", false);
    let harness = AcpHarness::graff().with_executable(root.path().join("agent.py"));
    assert!(harness.supports_steering_for(&req));
    req.model_options
        .insert("harnessAcpV2Preview".into(), serde_json::json!(true));
    assert!(!harness.supports_steering_for(&req));
    let events = run_to_end(&harness, req.clone(), controls().0).await;
    assert_eq!(dones(&events), [(DoneStatus::Completed, None)]);
    req.model_options.clear();
    assert!(harness.supports_steering_for(&req));
    let (ctl, steering, _) = controls();
    let mut stream = harness.run(req, ctl).await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(event) = stream.next().await {
            if matches!(
                event.unwrap(),
                AgentEvent::Done {
                    status: DoneStatus::Completed,
                    ..
                }
            ) {
                return;
            }
        }
        panic!("v1 did not complete");
    })
    .await
    .unwrap();
    drop(steering);
    assert!(traffic(&root).contains("initialize 1\nsession/new\nsession/prompt v1\n"));
}
