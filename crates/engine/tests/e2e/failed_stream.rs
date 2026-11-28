use super::*;

#[tokio::test]
async fn interrupt_stamps_streaming_entry_aborted() {
    let dir = tempfile::tempdir().unwrap();
    let core = assemble(
        dir.path(),
        Arc::new(ScriptedHarness {
            script: vec![AgentEvent::TextDelta {
                text: "partial output".into(),
            }],
            step_delay: Duration::from_millis(5),
            hang_until_interrupt: true,
        }),
    );
    let handle = core.doc_host.open(CHAT).unwrap();
    queue_as_viewer(
        handle.doc(),
        "cmd-run-hang",
        SessionCommandPayload::Run {
            request: run_request("hang"),
            message_id: "m-1".into(),
        },
    );

    // Wait until the streaming entry is visibly in the doc, then interrupt via a
    // viewer-queued durable command (based_on = the streaming entry = current turn).
    wait_for(
        || {
            entries(&core)
                .iter()
                .any(|e| e.status == Some(MessageStatus::Streaming))
        },
        "streaming entry",
    )
    .await;
    queue_as_viewer(
        handle.doc(),
        "cmd-int-1",
        SessionCommandPayload::Interrupt {},
    );

    wait_for(
        || {
            entries(&core)
                .iter()
                .any(|e| e.status == Some(MessageStatus::Aborted))
        },
        "aborted stamp",
    )
    .await;

    let all = entries(&core);
    let assistant = all
        .iter()
        .find(|e| e.role == MessageRole::Assistant)
        .unwrap();
    assert_eq!(assistant.status, Some(MessageStatus::Aborted));
    match &assistant.parts[0] {
        MessagePart::Text { text, .. } => assert_eq!(text, "partial output"),
        other => panic!("unexpected part {other:?}"),
    }
    // The command's Applied stamp is a separate doc write from the abort
    // stamp; under a loaded test run it can land a beat later.
    wait_for(
        || command_status(&core, "cmd-int-1") == Some((SessionCommandStatus::Applied, None)),
        "interrupt command applied",
    )
    .await;
    // Journal closed with a Done — nothing left to recover.
    let journal = RunJournal::open(dir.path().join("orgs/dev-org/dev-user/journals")).unwrap();
    assert!(journal.stale_sessions().unwrap().is_empty());
    assert_eq!(
        core.sessions.session_status(CHAT).map(|s| s.status),
        Some(SessionStatus::Idle)
    );
}

struct BrokenTransport {
    delta: Option<AgentEvent>,
    release: Arc<tokio::sync::Notify>,
}

#[async_trait]
impl Harness for BrokenTransport {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Broken transport"
    }
    fn supports_steering(&self) -> bool {
        false
    }
    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::TurnBoundary
    }
    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[]
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }
    async fn run(
        &self,
        _request: RunRequest,
        _controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let delta = self.delta.clone().map(Ok);
        let release = self.release.clone();
        let failure = futures::stream::once(async move {
            release.notified().await;
            Err(std::io::Error::new(std::io::ErrorKind::ConnectionReset, "connection lost").into())
        });
        Ok(futures::stream::iter(delta).chain(failure).boxed())
    }
}

#[tokio::test]
async fn broken_transport_persists_one_typed_failure_and_partial_output() {
    const ERROR: &str = "io: connection lost";

    for event in [
        None,
        Some(AgentEvent::ReasoningDelta {
            text: "partial reasoning".into(),
        }),
        Some(AgentEvent::TextDelta {
            text: "partial reply".into(),
        }),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let release = Arc::new(tokio::sync::Notify::new());
        let core = assemble(
            dir.path(),
            Arc::new(BrokenTransport {
                delta: event.clone(),
                release: release.clone(),
            }),
        );
        let handle = core.doc_host.open(CHAT).unwrap();
        queue_as_viewer(
            handle.doc(),
            "cmd-run-failure",
            SessionCommandPayload::Run {
                request: run_request("go"),
                message_id: "prompt".into(),
            },
        );
        let streamed_id = if event.is_some() {
            let streaming = || {
                entries_now(&core).into_iter().find(|entry| {
                    entry.role == MessageRole::Assistant
                        && entry.status == Some(MessageStatus::Streaming)
                })
            };
            wait_for(|| streaming().is_some(), "persisted streaming segment").await;
            Some(
                streaming()
                    .expect("stream stays open until failure is released")
                    .id,
            )
        } else {
            None
        };
        release.notify_one();
        wait_for(
            || {
                core.sessions
                    .session_status(CHAT)
                    .is_some_and(|s| s.status == SessionStatus::Errored)
            },
            "transport failure status",
        )
        .await;

        assert!(
            core.sessions
                .session_status(CHAT)
                .unwrap()
                .last_completed_turn
                .is_none()
        );
        let snapshot = handle.doc().export_snapshot().unwrap();
        let imported = loro::LoroDoc::new();
        imported.import(&snapshot).unwrap();
        let all = SessionDoc::from_doc(imported).read_entries().unwrap();
        assert_eq!(all, entries(&core));
        assert_eq!(all.len(), 2, "{all:#?}");
        assert_eq!(all[0].role, MessageRole::User);
        let assistant = &all[1];
        assert_eq!(assistant.role, MessageRole::Assistant);
        if let Some(id) = streamed_id {
            assert_eq!(assistant.id, id);
        }

        let parts = assistant.parts.as_slice();
        let (last, preceding) = parts.split_last().expect("one typed error part");
        assert!(
            matches!(last, MessagePart::Error { message, .. } if message == ERROR),
            "{parts:#?}"
        );
        match event {
            None => assert!(preceding.is_empty()),
            Some(AgentEvent::ReasoningDelta { .. }) => assert!(
                matches!(
                    preceding, [MessagePart::Reasoning { text, .. }] if text == "partial reasoning"
                ),
                "{parts:#?}"
            ),
            Some(AgentEvent::TextDelta { .. }) => assert!(
                matches!(
                    preceding, [MessagePart::Text { text, .. }] if text == "partial reply"
                ),
                "{parts:#?}"
            ),
            _ => unreachable!(),
        }
    }
}

#[tokio::test]
async fn session_watch_retains_only_known_local_outcomes_after_engine_restart() {
    use harness_proto::Session;

    let dir = tempfile::tempdir().unwrap();
    let restart = || {
        assemble(
            dir.path(),
            Arc::new(MockHarness {
                script: mock_script(),
            }),
        )
    };
    let make_row = |device_id: &str, chat_id: &str, status, completed: Option<&str>| Session {
        chat_id: chat_id.into(),
        device_id: device_id.into(),
        status,
        started_at: None,
        updated_at: chrono::Utc::now(),
        last_completed_turn: completed.map(str::to_owned),
        last_completed_peer_only: false,
    };
    {
        let core = restart();
        for (id, status, completed) in [
            ("completed", SessionStatus::Idle, Some("assistant-result")),
            ("errored", SessionStatus::Errored, None),
            ("idle-without-outcome", SessionStatus::Idle, None),
            ("orphaned-active", SessionStatus::Working, None),
        ] {
            core.workspace
                .record_session(&make_row(&core.device_id, id, status, completed));
        }
        core.workspace.flush();
    }

    let core = restart();
    assert_eq!(core.workspace.read_sessions().unwrap().len(), 4);
    let (live_tx, live_rx) = tokio::sync::watch::channel(Vec::new());
    let mut merged = core.workspace.merged_sessions_watch(live_rx);
    let expected = [
        ("completed".to_string(), SessionStatus::Idle),
        ("errored".to_string(), SessionStatus::Errored),
    ];
    let marks = |rows: &[Session]| {
        rows.iter()
            .map(|row| (row.chat_id.clone(), row.status))
            .collect::<Vec<_>>()
    };
    assert_eq!(marks(&merged.borrow()), expected);

    live_tx
        .send(vec![make_row(
            &core.device_id,
            "completed",
            SessionStatus::Working,
            None,
        )])
        .unwrap();
    tokio::time::timeout(Duration::from_secs(2), merged.changed())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(merged.borrow()[0].status, SessionStatus::Working);
}
