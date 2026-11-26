//! Host-relay admission: remote control is off until the user opts in on
//! personal computers, enabled in memory for headless cloud sandboxes, and
//! drains parked remote work once turned on.
//!
//! `relay_rpc_refuses_queue_command_until_remote_control_is_on` fails on
//! pre-#179 main, while `sandbox_runtime_admits_remote_commands_and_relay_actions_while_blocking_local_only`,
//! `enabling_remote_control_drains_previously_parked_remote_commands`, and
//! `relay_upload_commit_with_device_id_is_admitted_for_approved_caller` fail on
//! pre-fix `main` (`e9e410fa`).

#![allow(clippy::result_large_err)]

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::{SinkExt, StreamExt};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::tungstenite::handshake::server::{
    Request as WsRequest, Response as WsResponse,
};

use harness_engine::auth::sandbox_sign_in;
use harness_engine::{
    Auth, AuthConfig, Engine, EngineConfig, EngineCore, HarnessRegistry, RelayRpc,
};
use harness_proto::{HarnessId, WorkspaceScope};
use harness_rpc::{
    DeviceFrameHeader, LinkCache, LinkCacheConfig, RpcError, RpcReply, RpcService, StaticToken,
    decode_device_frame, encode_device_frame, methods,
};

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

async fn start_sandbox_auth_edge() -> (String, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind edge");
    let url = format!("http://{}", listener.local_addr().expect("addr"));
    let task = tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let mut len = 0;
                let head = loop {
                    let n = stream.read(&mut buf[len..]).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    len += n;
                    let text = String::from_utf8_lossy(&buf[..len]).to_string();
                    if let Some((head, _)) = text.split_once("\r\n\r\n") {
                        break head.to_string();
                    }
                };
                let path = head.split_whitespace().nth(1).unwrap_or("");
                let (status, payload) = if path == "/auth/sandbox" {
                    (
                        "200 OK",
                        json!({
                            "user": { "id": "42", "email": "sandbox@example.test" },
                            "orgId": "user-42",
                            "accessToken": "e30.eyJzdWIiOiI0MiIsImV4cCI6OTk5OTk5OTk5OX0.sig",
                        })
                        .to_string(),
                    )
                } else {
                    ("404 Not Found", "{}".to_string())
                };
                let reply = format!(
                    "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{payload}",
                    payload.len()
                );
                let _ = stream.write_all(reply.as_bytes()).await;
            });
        }
    });
    (url, task)
}

#[derive(Default)]
struct RelayRoomState {
    host: Option<mpsc::UnboundedSender<Vec<u8>>>,
    clients: HashMap<String, mpsc::UnboundedSender<Vec<u8>>>,
}

async fn start_fake_device_room() -> (String, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind relay");
    let url = format!(
        "http://127.0.0.1:{}",
        listener.local_addr().expect("addr").port()
    );
    let state = Arc::new(Mutex::new(RelayRoomState::default()));
    let task = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let state = state.clone();
            tokio::spawn(async move {
                let mut uri = String::new();
                let Ok(ws) = tokio_tungstenite::accept_hdr_async(
                    stream,
                    |req: &WsRequest, res: WsResponse| {
                        uri = req.uri().to_string();
                        Ok(res)
                    },
                )
                .await
                else {
                    return;
                };
                let query = uri.split_once('?').map(|(_, q)| q).unwrap_or("");
                let is_host = query.contains("role=host");
                let conn_id = query
                    .split('&')
                    .find_map(|kv| kv.strip_prefix("connId="))
                    .unwrap_or("anon")
                    .to_string();
                let (mut sink, mut ws_stream) = ws.split();
                let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
                {
                    let mut st = state.lock().expect("lock");
                    if is_host {
                        st.host = Some(tx);
                    } else {
                        st.clients.insert(conn_id.clone(), tx);
                    }
                }
                let writer = tokio::spawn(async move {
                    while let Some(bytes) = rx.recv().await {
                        if sink.send(WsMessage::Binary(bytes)).await.is_err() {
                            break;
                        }
                    }
                });
                while let Some(Ok(message)) = ws_stream.next().await {
                    let WsMessage::Binary(bytes) = message else {
                        continue;
                    };
                    let Ok((header, payload)) = decode_device_frame(&bytes) else {
                        break;
                    };
                    let st = state.lock().expect("lock");
                    if is_host {
                        let Some(to) = header.to else { continue };
                        if let Some(client) = st.clients.get(&to) {
                            let stripped = DeviceFrameHeader::new(header.s, header.k);
                            let _ = client
                                .send(encode_device_frame(&stripped, &payload).expect("encode"));
                        }
                    } else if let Some(host) = &st.host {
                        let mut routed = DeviceFrameHeader::new(header.s, header.k);
                        routed.from = Some(conn_id.clone());
                        let _ = host.send(encode_device_frame(&routed, &payload).expect("encode"));
                    }
                }
                writer.abort();
            });
        }
    });
    (url, task)
}

#[tokio::test]
async fn sandbox_runtime_admits_remote_commands_and_relay_actions_while_blocking_local_only() {
    use harness_doc::{SessionCommandEntry, SessionCommandPayload, SessionCommandStatus};
    use harness_proto::{RunRequest, SandboxLevel};

    let (edge_url, edge_task) = start_sandbox_auth_edge().await;
    let dir = tempfile::tempdir().expect("tempdir");
    let data = dir.path().join("data");
    std::fs::create_dir_all(&data).expect("data dir");
    std::fs::write(
        data.join("harness-prefs.json"),
        r#"{"remoteControl":false}"#,
    )
    .expect("write prefs");
    let token_path = dir.path().join("access.json");
    let synthetic_token = "cg_lt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    std::fs::write(&token_path, format!(r#"{{"apiKey":"{synthetic_token}"}}"#))
        .expect("write sandbox token");

    let config = EngineConfig {
        data_dir: data.clone(),
        edge_url: edge_url.clone(),
        edge_token: None,
        ipc_port: 0,
        default_harness: HarnessId::Mock,
        org_id: Some("user-42".into()),
        codegraff_client_id: Some("cg_client_test".into()),
    };
    let session = sandbox_sign_in(&edge_url, &token_path)
        .await
        .expect("sandbox sign-in")
        .expect("session");
    let mut auth_config = AuthConfig::new(&edge_url, &data);
    auth_config.codegraff_client_id = Some("cg_client_test".into());
    auth_config.callback_port = None;
    auth_config.sandbox_token_file = Some(token_path);
    let auth = Auth::new(auth_config.with_sandbox_session(session));
    let scope = Engine::initial_workspace_scope(&auth);
    assert_eq!(scope, WorkspaceScope::Synced);
    let profile = Engine::resolve_profile(&config, &auth, scope)
        .expect("resolve profile")
        .expect("synced profile");

    let runtime = Engine::assemble_runtime(&config, auth, profile)
        .await
        .expect("assemble sandbox runtime");

    assert!(
        runtime.core().registry.remote_control(),
        "cloud sandbox must enable remote control in memory even when prefs say false"
    );

    let chat = "sandbox-remote-chat";
    let handle = runtime.core().doc_host.open(chat).expect("open chat");
    handle
        .doc()
        .queue_command(&SessionCommandEntry {
            id: "mac-run".into(),
            payload: SessionCommandPayload::Run {
                request: RunRequest {
                    turn_origin: Default::default(),
                    prompt: "synthetic hi".into(),
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
                message_id: "m-sandbox-1".into(),
            },
            issued_by: "mac-client".into(),
            issued_at: chrono::Utc::now().timestamp_millis(),
            based_on: None,
            expires_at: None,
            status: SessionCommandStatus::Pending,
            resolution: None,
        })
        .expect("queue");
    runtime.core().doc_host.drain_commands(&handle).await;
    let commands = handle.doc().read_commands().expect("commands");
    assert_ne!(
        commands[0].status,
        SessionCommandStatus::Pending,
        "cloud sandbox must drain remote commands without parking for desktop approval"
    );
    assert!(
        runtime
            .core()
            .registry
            .pending_remote_approvals()
            .is_empty()
    );

    let stub_relay = harness_rpc::memory_client(RelayRpc::wrap(
        Arc::new(Inner),
        runtime.core().registry.clone(),
    ));
    for method in [
        methods::QUEUE_COMMAND,
        methods::RELAY_COMMAND,
        methods::OPEN_TERMINAL,
        methods::UPLOAD_COMMIT,
    ] {
        let reply = stub_relay
            .call(method, json!({ "relayDeviceId": "mac-client" }))
            .await
            .unwrap_or_else(|err| panic!("sandbox relay must admit {method}: {err}"));
        assert_eq!(reply["method"], method);
    }

    for method in [
        methods::SET_REMOTE_CONTROL,
        methods::SET_AUTONOMY,
        methods::APPLY_UPDATE,
        methods::APPLY_HARNESS_UPDATE,
        methods::SET_HARNESS_UPDATE_POLICY,
        methods::SET_E2EE,
        methods::APPROVE_REMOTE_ACTION,
        methods::DENY_REMOTE_ACTION,
    ] {
        let err = stub_relay
            .call(method, json!({ "relayDeviceId": "mac-client" }))
            .await
            .expect_err(method);
        assert!(
            err.to_string().contains("only be done on the computer"),
            "{method}: {err}"
        );
    }

    let full_relay = harness_rpc::memory_client(runtime.core().relay_rpc_service());
    for method in [
        methods::SET_AUTONOMY,
        methods::APPLY_UPDATE,
        methods::APPLY_HARNESS_UPDATE,
        methods::SET_HARNESS_UPDATE_POLICY,
    ] {
        let err = full_relay
            .call(method, json!({ "relayDeviceId": "mac-client" }))
            .await
            .expect_err(method);
        assert!(
            err.to_string().contains("only be done on the computer"),
            "{method}: {err}"
        );
    }
    for method in [
        methods::SET_REMOTE_CONTROL,
        methods::SET_E2EE,
        methods::APPROVE_REMOTE_ACTION,
        methods::DENY_REMOTE_ACTION,
        methods::STOP_ENGINE,
        methods::MUTATE,
    ] {
        let err = full_relay
            .call(method, json!({ "relayDeviceId": "mac-client" }))
            .await
            .expect_err(method);
        assert!(
            err.to_string().contains("not forwardable"),
            "{method}: {err}"
        );
    }

    runtime.shutdown().await;
    edge_task.abort();
}

#[tokio::test]
async fn enabling_remote_control_drains_previously_parked_remote_commands() {
    use harness_doc::{SessionCommandEntry, SessionCommandPayload, SessionCommandStatus};
    use harness_proto::{RunRequest, SandboxLevel};

    let dir = tempfile::tempdir().expect("tempdir");
    let core = EngineCore::assemble(
        dir.path(),
        Arc::new(HarnessRegistry::new()),
        HarnessId::Mock,
        None,
    )
    .expect("engine assembles");
    let chat = "parked-then-enabled";
    let handle = core.doc_host.open(chat).expect("open");
    handle
        .doc()
        .queue_command(&SessionCommandEntry {
            id: "phone-run-parked".into(),
            payload: SessionCommandPayload::Run {
                request: RunRequest {
                    turn_origin: Default::default(),
                    prompt: "synthetic hello".into(),
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
                message_id: "m-park-1".into(),
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
    assert_eq!(
        handle.doc().read_commands().expect("commands")[0].status,
        SessionCommandStatus::Pending
    );
    assert_eq!(core.registry.pending_remote_approvals().len(), 1);

    let local = harness_rpc::memory_client(core.rpc_service());
    let reply = local
        .call(methods::SET_REMOTE_CONTROL, json!({ "enabled": true }))
        .await
        .expect("SetRemoteControl on local IPC");
    assert_eq!(reply, json!({ "enabled": true }));

    assert!(
        core.registry.pending_remote_approvals().is_empty(),
        "enabling remote control must clear parked command approvals"
    );
    let after = handle.doc().read_commands().expect("commands");
    assert_ne!(
        after[0].status,
        SessionCommandStatus::Pending,
        "enabling remote control must immediately drain previously parked commands"
    );
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn relay_upload_commit_with_device_id_is_admitted_for_approved_caller() {
    use harness_doc::SessionCommandPayload;
    use harness_proto::{Device, RunRequest, SandboxLevel};

    let (relay_url, relay_task) = start_fake_device_room().await;
    let dirs = tempfile::tempdir().expect("tempdir");

    let dir_b = dirs.path().join("b");
    std::fs::create_dir_all(&dir_b).expect("dir b");
    std::fs::write(dir_b.join("device-id"), "device-b").expect("device b id");
    let core_b = EngineCore::assemble(
        &dir_b,
        Arc::new(HarnessRegistry::new()),
        HarnessId::Mock,
        None,
    )
    .expect("core b");
    core_b.registry.set_remote_control(true);
    core_b.registry.approve_remote_device("device-a");
    let _host = core_b.start_host_relay(&relay_url);

    let dir_a = dirs.path().join("a");
    std::fs::create_dir_all(&dir_a).expect("dir a");
    std::fs::write(dir_a.join("device-id"), "device-a").expect("device a id");
    let core_a = EngineCore::assemble(
        &dir_a,
        Arc::new(HarnessRegistry::new()),
        HarnessId::Mock,
        None,
    )
    .expect("core a");
    let mut link_config =
        LinkCacheConfig::new(relay_url.clone(), Arc::new(StaticToken("test-user".into())));
    link_config.probe_timeout = Duration::from_secs(5);
    core_a.set_links(LinkCache::new(link_config));

    core_a.workspace.upsert_device_row(&Device {
        id: "device-b".into(),
        name: "b".into(),
        platform: "linux".into(),
        last_seen_at: Some(chrono::Utc::now()),
        created_at: None,
        version: Some("0.2.238".into()),
        cursor_sdk_version: None,
        capabilities: harness_proto::capabilities::current(),
    });

    let chat = "chat-upload-relay-auth";
    let client_a = harness_rpc::memory_client(core_a.rpc_service());
    client_a
        .call(
            methods::MUTATE,
            json!({ "op": "createChat", "chatId": chat, "deviceId": "device-b" }),
        )
        .await
        .expect("createChat on A");

    let upload_id = "upload-relay-test";
    let file_name = "shot.png";
    core_a
        .uploads
        .append(upload_id, "c3ludGhldGlj", Some(0))
        .expect("stage chunk");
    core_a
        .uploads
        .commit(upload_id, file_name)
        .expect("commit local upload");

    let pending_ref = format!("pending://{upload_id}/{file_name}");
    let command = serde_json::to_value(SessionCommandPayload::Run {
        request: RunRequest {
            turn_origin: Default::default(),
            prompt: "inspect attachment".into(),
            harness: None,
            model: None,
            reasoning: None,
            model_options: Default::default(),
            cwd: "~".into(),
            sandbox: SandboxLevel::WorkspaceWrite,
            auto_approve: true,
            attachments: vec![pending_ref.clone()],
            worktree: None,
            resume: None,
        },
        message_id: "msg-upload-relay-1".into(),
    })
    .expect("command json");

    client_a
        .call(
            methods::QUEUE_COMMAND,
            json!({
                "chatId": chat,
                "command": command,
                "transfers": [{ "uploadId": upload_id, "fileName": file_name }],
            }),
        )
        .await
        .expect("queue with transfer");

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if core_b.uploads.resolve_pending(&pending_ref).is_some() {
            break;
        }
        assert!(
            core_b.registry.pending_remote_approvals().is_empty(),
            "approved caller upload parked for approval: {:?}",
            core_b.registry.pending_remote_approvals()
        );
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for relayed UploadCommit on approved caller"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    core_a.shutdown().await;
    core_b.shutdown().await;
    relay_task.abort();
}
