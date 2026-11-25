//! Host-relay admission: remote control is off until the user opts in.
//!
//! `relay_rpc_refuses_queue_command_until_remote_control_is_on` fails on
//! main (the host relay used to serve QueueCommand with no opt-in).

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;

use harness_engine::{HarnessRegistry, RelayRpc};
use harness_rpc::{RpcError, RpcReply, RpcService, methods};

struct Inner;

#[async_trait]
impl RpcService for Inner {
    async fn handle(&self, method: &str, _params: serde_json::Value) -> Result<RpcReply, RpcError> {
        RpcReply::value(&json!({ "method": method }))
    }
}

#[tokio::test]
async fn relay_rpc_refuses_queue_command_until_remote_control_is_on() {
    let registry = Arc::new(HarnessRegistry::new());
    assert!(
        !registry.remote_control(),
        "a fresh computer must not be a remotely driven host"
    );
    let client = harness_rpc::memory_client(RelayRpc::wrap(Arc::new(Inner), registry.clone()));

    let err = client
        .call(methods::QUEUE_COMMAND, json!({}))
        .await
        .expect_err("QueueCommand over the relay must fail while remote control is off");
    assert!(err.to_string().contains("Remote control is off"), "{err}");

    let probe = client
        .call(methods::GET_REMOTE_CONTROL, json!({}))
        .await
        .expect("GetRemoteControl is a probe");
    assert_eq!(probe["method"], methods::GET_REMOTE_CONTROL);

    registry.set_remote_control(true);
    let parked = client
        .call(
            methods::QUEUE_COMMAND,
            json!({ "relayDeviceId": "phone-1" }),
        )
        .await
        .expect_err("first remote QueueCommand needs local approval");
    assert!(parked.to_string().contains("needs approval"), "{parked}");
    assert_eq!(registry.pending_remote_approvals().len(), 1);

    registry.approve_remote_device("phone-1");
    let queued = client
        .call(
            methods::QUEUE_COMMAND,
            json!({ "relayDeviceId": "phone-1" }),
        )
        .await
        .expect("QueueCommand is served once this caller is approved");
    assert_eq!(queued["method"], methods::QUEUE_COMMAND);
}

#[tokio::test]
async fn relay_rpc_never_lets_the_edge_flip_the_gate() {
    let registry = Arc::new(HarnessRegistry::new());
    registry.set_remote_control(true);
    let client = harness_rpc::memory_client(RelayRpc::wrap(Arc::new(Inner), registry.clone()));
    let err = client
        .call(methods::SET_REMOTE_CONTROL, json!({ "enabled": true }))
        .await
        .expect_err("SetRemoteControl must stay on local IPC");
    assert!(
        err.to_string().contains("only be done on the computer"),
        "{err}"
    );
    assert!(registry.remote_control());
}

#[tokio::test]
async fn local_ipc_can_change_remote_control() {
    let dir = tempfile::tempdir().expect("tempdir");
    let core = harness_engine::EngineCore::assemble(
        dir.path(),
        Arc::new(HarnessRegistry::new()),
        harness_proto::HarnessId::Mock,
        None,
    )
    .expect("engine assembles");
    let client = harness_rpc::memory_client(core.rpc_service());
    let before = client
        .call(methods::GET_REMOTE_CONTROL, json!({}))
        .await
        .expect("GetRemoteControl");
    assert_eq!(before, json!({ "enabled": false }));
    let after = client
        .call(methods::SET_REMOTE_CONTROL, json!({ "enabled": true }))
        .await
        .expect("SetRemoteControl on local IPC");
    assert_eq!(after, json!({ "enabled": true }));
    assert!(core.registry.remote_control());
    let rejected = client
        .call(
            methods::SET_REMOTE_CONTROL,
            json!({ "enabled": false, "targetDeviceId": "some-other-computer" }),
        )
        .await
        .expect_err("SetRemoteControl must not retarget another device");
    assert!(
        rejected
            .to_string()
            .contains("only be done on the computer"),
        "{rejected}"
    );
    assert!(core.registry.remote_control());
    core.shutdown().await;
}

#[tokio::test]
async fn relay_rpc_never_admits_autonomy_or_updates() {
    let registry = Arc::new(HarnessRegistry::new());
    registry.set_remote_control(true);
    registry.approve_remote_device("phone-1");
    let client = harness_rpc::memory_client(RelayRpc::wrap(Arc::new(Inner), registry.clone()));
    for method in [
        methods::SET_AUTONOMY,
        methods::APPLY_UPDATE,
        methods::APPLY_HARNESS_UPDATE,
        methods::SET_E2EE,
    ] {
        let err = client
            .call(method, json!({ "relayDeviceId": "phone-1" }))
            .await
            .expect_err(method);
        assert!(
            err.to_string().contains("only be done on the computer"),
            "{method}: {err}"
        );
    }
}

#[tokio::test]
async fn remote_chat2_run_parks_until_opt_in_or_approval() {
    use harness_doc::{SessionCommandEntry, SessionCommandPayload, SessionCommandStatus};
    use harness_proto::{HarnessId, RunRequest, SandboxLevel};

    let dir = tempfile::tempdir().expect("tempdir");
    let core = harness_engine::EngineCore::assemble(
        dir.path(),
        Arc::new(HarnessRegistry::new()),
        HarnessId::Mock,
        None,
    )
    .expect("engine assembles");
    let chat = "remote-park";
    let handle = core.doc_host.open(chat).expect("open");
    handle
        .doc()
        .queue_command(&SessionCommandEntry {
            id: "phone-run".into(),
            payload: SessionCommandPayload::Run {
                request: RunRequest {
                    turn_origin: Default::default(),
                    prompt: "list the files".into(),
                    harness: Some(HarnessId::Mock),
                    model: None,
                    reasoning: None,
                    model_options: Default::default(),
                    cwd: dir.path().to_string_lossy().into(),
                    sandbox: SandboxLevel::WorkspaceWrite,
                    auto_approve: true,
                    attachments: Vec::new(),
                    worktree: None,
                    resume: None,
                },
                message_id: "m1".into(),
            },
            issued_by: "phone".into(),
            issued_at: chrono::Utc::now().timestamp_millis(),
            based_on: None,
            expires_at: None,
            status: SessionCommandStatus::Pending,
            resolution: None,
        })
        .expect("queue");
    core.doc_host.drain_commands(&handle).await;
    let commands = handle.doc().read_commands().expect("commands");
    assert_eq!(commands[0].status, SessionCommandStatus::Pending);
    assert!(
        !core.registry.pending_remote_approvals().is_empty(),
        "the host must park a remote Run while remote control is off"
    );

    core.registry.set_remote_control(true);
    core.doc_host.drain_commands(&handle).await;
    let after = handle.doc().read_commands().expect("commands");
    assert_ne!(
        after[0].status,
        SessionCommandStatus::Pending,
        "opting in lets the iOS composer drain"
    );
    core.shutdown().await;
}

#[tokio::test]
async fn local_ipc_exposes_device_identity_and_e2ee_flag() {
    let dir = tempfile::tempdir().expect("tempdir");
    let core = harness_engine::EngineCore::assemble(
        dir.path(),
        Arc::new(HarnessRegistry::new()),
        harness_proto::HarnessId::Mock,
        None,
    )
    .expect("engine assembles");
    let client = harness_rpc::memory_client(core.rpc_service());
    let identity = client
        .call(methods::GET_DEVICE_IDENTITY, json!({}))
        .await
        .expect("GetDeviceIdentity");
    assert_eq!(identity["deviceId"], core.doc_host.device_id());
    assert!(identity["verifyingKey"].as_str().unwrap().len() > 20);
    assert!(identity["ecdhPublic"].as_str().unwrap().len() > 20);
    let e2ee = client
        .call(methods::GET_E2EE, json!({}))
        .await
        .expect("GetE2ee");
    assert_eq!(e2ee, json!({ "enabled": false }));
    let after = client
        .call(methods::SET_E2EE, json!({ "enabled": true }))
        .await
        .expect("SetE2ee on local IPC");
    assert_eq!(after, json!({ "enabled": true }));
    core.shutdown().await;
}
