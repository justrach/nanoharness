//! ACP v2 Preview stdio runner, pinned to schema-v2.0.0-beta.4.
//! Discovery and the v1 run loop intentionally remain separate.

pub(super) mod cancel;
mod display;
mod interaction;
mod reducer;
mod status;

pub(super) const PROTOCOL_OPTION: &str = "harnessAcpV2Preview";

use super::{
    AgentEvent, Child, DoneStatus, HarnessError, Incoming, RpcClient, Session, SlashCommand,
    new_message_id, prompt_images, send,
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

pub(super) fn connect(
    child: &mut Child,
) -> Result<(RpcClient, mpsc::Receiver<Incoming>), HarnessError> {
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| protocol("agent child has no stdin"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| protocol("agent child has no stdout"))?;
    Ok(RpcClient::new(stdin, stdout))
}

fn protocol(message: &str) -> HarnessError {
    HarnessError::Protocol(message.to_owned())
}

pub(super) async fn negotiate(
    client: &RpcClient,
    incoming: &mut mpsc::Receiver<Incoming>,
) -> Result<Option<Value>, HarnessError> {
    let result = draining(
        client,
        incoming,
        "initialize",
        json!({
            "protocolVersion": 2,
            "info": {"name": "harness", "version": env!("CARGO_PKG_VERSION")},
            "capabilities": {"elicitation": {"form": {}}},
        }),
    )
    .await?;
    match result["protocolVersion"].as_u64() {
        Some(1) => Ok(None),
        Some(2) if result["info"]["name"].is_string() && result["info"]["version"].is_string() => {
            Ok(Some(result))
        }
        _ => Err(protocol("invalid ACP Preview initialize response")),
    }
}

// Preview never delegates here to v1's automatic permission paths. Component C
// can replace this policy with scoped permission/elicitation handling.
fn reject_request(client: &RpcClient, id: &Value, method: &str) {
    match method {
        "session/request_permission" => {
            client.respond(id, json!({"outcome": {"outcome": "cancelled"}}))
        }
        "elicitation/create" => client.respond(id, json!({"action": "decline"})),
        _ => client.respond_error(id, -32601, "Unsupported client method"),
    }
}

async fn draining(
    client: &RpcClient,
    incoming: &mut mpsc::Receiver<Incoming>,
    method: &str,
    params: Value,
) -> Result<Value, HarnessError> {
    draining_updates(client, incoming, method, params, |_| {}).await
}

async fn draining_updates(
    client: &RpcClient,
    incoming: &mut mpsc::Receiver<Incoming>,
    method: &str,
    params: Value,
    mut update: impl FnMut(&Value),
) -> Result<Value, HarnessError> {
    let request_id = client.request_ordered(method, params)?;
    loop {
        match incoming.recv().await {
            Some(Incoming::OrderedResponse { id, outcome }) if id == request_id => return outcome,
            Some(Incoming::Request { id, method, .. }) => reject_request(client, &id, &method),
            Some(Incoming::Notification { method, params }) if method == "session/update" => {
                update(&params)
            }
            Some(Incoming::Eof) | None => {
                return Err(protocol("ACP Preview disconnected during setup"));
            }
            _ => {}
        }
    }
}

#[derive(Deserialize)]
struct Command {
    name: String,
    description: String,
    input: Option<Value>,
}

fn commands(value: &Value) -> Option<Vec<SlashCommand>> {
    Some(
        value
            .as_array()?
            .iter()
            .filter_map(|value| {
                if value["type"] != "command" {
                    return None;
                }
                let command: Command = serde_json::from_value(value.clone()).ok()?;
                if command.name.is_empty() || command.name.contains(char::is_whitespace) {
                    return None;
                }
                let input = command.input.filter(|input| input["type"] == "text");
                Some(SlashCommand {
                    name: command.name,
                    description: command.description,
                    input_hint: input.and_then(|input| input["hint"].as_str().map(str::to_owned)),
                })
            })
            .collect(),
    )
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Choice {
    Item { value: String },
    Group { options: Vec<Choice> },
}

impl Choice {
    fn contains(&self, id: &str) -> bool {
        match self {
            Self::Item { value } => id == value,
            Self::Group { options } => options.iter().any(|option| option.contains(id)),
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Config {
    Select { options: Vec<Choice> },
    Boolean,
}

fn config_params(session: &str, config: &Value, selected: &Value) -> Option<Value> {
    let id = config["configId"].as_str()?;
    let config: Config = serde_json::from_value(config.clone()).ok()?;
    let kind = match config {
        Config::Select { options }
            if options
                .iter()
                .any(|choice| selected.as_str().is_some_and(|id| choice.contains(id))) =>
        {
            "id"
        }
        Config::Boolean if selected.is_boolean() => "boolean",
        _ => return None,
    };
    Some(json!({"sessionId": session, "configId": id, "type": kind, "value": selected}))
}

fn submission_key(origin: Option<&crate::RunOrigin>) -> String {
    let Some((origin, id)) =
        origin.and_then(|origin| Some((origin, origin.submission_id.as_deref()?)))
    else {
        return new_message_id();
    };
    // Fixed length even if an untrusted command supplies an overlong entry ID.
    // Include the chat's identity in case two chats activate the same ACP session.
    let mut hash = Sha256::new();
    hash.update(b"harness/acp-preview/submission/v1");
    hash.update((origin.chat_id.len() as u64).to_be_bytes());
    hash.update(origin.chat_id.as_bytes());
    hash.update(id.as_bytes());
    format!("harness:{:x}", hash.finalize())
}

fn update_for<'a>(params: &'a Value, session_id: &str) -> Option<&'a Value> {
    (params["sessionId"].as_str() == Some(session_id)).then(|| &params["update"])
}

#[derive(Default)]
struct Foreground {
    ack: Option<String>,
    observed_user: Option<String>,
    idle: Option<Value>,
}

impl Foreground {
    fn update(&mut self, update: &Value) {
        match update["sessionUpdate"].as_str() {
            Some("user_message" | "user_message_chunk") => {
                if let Some(id) = update["messageId"].as_str().filter(|s| !s.is_empty())
                    && self.observed_user.as_deref() != Some(id)
                    && self.ack.as_deref().is_none_or(|ack| ack == id)
                {
                    self.observed_user = Some(id.to_owned());
                    self.idle = None;
                }
            }
            Some("state_update") => match update["state"].as_str() {
                Some("idle") if self.observed_user.is_some() => self.idle = Some(update.clone()),
                Some("running" | "requires_action" | "unknown") => self.idle = None,
                _ => {}
            },
            _ => {}
        }
    }

    fn outcome(&self) -> Option<Outcome> {
        self.ack
            .as_ref()
            .filter(|id| Some(*id) == self.observed_user.as_ref())?;
        let idle = self.idle.as_ref()?;
        Some(
            idle["stopReason"]
                .as_str()
                .and_then(|reason| terminal_outcome(reason, None))
                .unwrap_or_else(|| {
                    (
                        DoneStatus::Disconnected,
                        Some(
                            "ACP Preview agent is idle but did not report a recognized outcome"
                                .into(),
                        ),
                    )
                }),
        )
    }
}

async fn setup(
    session: &mut Session,
    init: &Value,
) -> Result<(String, Value, reducer::Reducer), HarnessError> {
    let mut params = json!({"cwd": session.request.cwd});
    if init
        .pointer("/capabilities/session/mcp/stdio")
        .is_some_and(Value::is_object)
    {
        let mut servers =
            super::harness_mcp_servers(session.harness, session.controls.origin.as_ref());
        if let Some(servers) = servers.as_array_mut() {
            servers.retain_mut(|server| {
                if !server["command"]
                    .as_str()
                    .is_some_and(|path| std::path::Path::new(path).is_absolute())
                {
                    return false;
                }
                server["type"] = json!("stdio");
                true
            });
        }
        params["mcpServers"] = servers;
    }
    let (session_id, response, mut projection) = if let Some(id) = &session.request.resume {
        params["sessionId"] = json!(id);
        params["replayFrom"] = json!({"type": "start"});
        let mut projection = reducer::Reducer::new(id.clone(), true);
        let response = draining_updates(
            &session.client,
            &mut session.incoming,
            "session/resume",
            params,
            |params| {
                let _ = projection.apply(params);
            },
        )
        .await;
        if projection.finish_replay(response.is_ok()) != 0 {
            return Err(protocol("ACP Preview resume omitted a replay barrier"));
        }
        (id.clone(), response?, projection)
    } else {
        let response = draining(
            &session.client,
            &mut session.incoming,
            "session/new",
            params,
        )
        .await?;
        let id = response["sessionId"]
            .as_str()
            .filter(|id| !id.is_empty())
            .ok_or_else(|| protocol("invalid ACP Preview session ID"))?
            .to_owned();
        (id.clone(), response, reducer::Reducer::new(id, false))
    };
    if !response.is_object() {
        return Err(protocol("invalid ACP Preview session response"));
    }
    let mut advertised = response["configOptions"].clone();
    let mut choices = session.request.model_options.clone();
    if let Some(model) = &session.request.model
        && let Some(model_config) = advertised
            .as_array()
            .and_then(|options| options.iter().find(|option| option["category"] == "model"))
        && let Some(id) = model_config["configId"].as_str()
    {
        choices.insert(id.to_owned(), json!(model));
    }
    // Apply a model selection first; its response can replace dependent options.
    let model_id = advertised
        .as_array()
        .and_then(|options| options.iter().find(|option| option["category"] == "model"))
        .and_then(|option| option["configId"].as_str())
        .map(str::to_owned);
    let mut choices: Vec<_> = choices.into_iter().collect();
    choices.sort_by_key(|(id, _)| Some(id) != model_id.as_ref());
    for (id, choice) in choices {
        let config = advertised.as_array().and_then(|options| {
            options
                .iter()
                .find(|option| option["configId"].as_str() == Some(&id))
        });
        let params = config
            .and_then(|config| config_params(&session_id, config, &choice))
            .ok_or_else(|| protocol("requested ACP Preview option is not advertised"))?;
        let response = draining_updates(
            &session.client,
            &mut session.incoming,
            "session/set_config_option",
            params,
            |params| {
                let _ = projection.apply(params);
            },
        )
        .await?;
        if !response["configOptions"].is_array() {
            return Err(protocol("invalid ACP Preview config response"));
        }
        advertised = response["configOptions"].clone();
    }
    Ok((session_id, response, projection))
}

pub(super) async fn run(mut session: Session, init: Value, target_controls: cancel::Controls) {
    let mut started = None;
    let chat = session
        .controls
        .origin
        .as_ref()
        .map(|origin| origin.chat_id.clone());
    let mut route = chat.as_deref().map(|chat| target_controls.attach(chat));
    let mut foreground_reported = false;
    let mut transient_status = status::Status::default();
    let exit = run_inner(
        &mut session,
        &init,
        &mut started,
        &mut foreground_reported,
        &mut transient_status,
        route.as_mut().map(|(receiver, _)| receiver),
    )
    .await;
    drop(route);
    for event in transient_status.clear() {
        let _ = send(&session.event_tx, event).await;
    }
    let (status, error) = match exit {
        Ok(outcome) => outcome,
        Err(error) => (DoneStatus::Errored, Some(error.to_string())),
    };
    if !foreground_reported {
        let _ = send(
            &session.event_tx,
            AgentEvent::Done {
                status,
                result: None,
                error,
                session_id: started,
            },
        )
        .await;
    }
    session.child.shutdown(session.kill_grace).await;
}

type Outcome = (DoneStatus, Option<String>);

fn terminal_outcome(reason: &str, error: Option<&str>) -> Option<Outcome> {
    Some(match reason {
        "end_turn" | "max_tokens" | "max_turn_requests" => (DoneStatus::Completed, None),
        "cancelled" => (DoneStatus::Interrupted, None),
        "error" => (
            DoneStatus::Errored,
            Some(error.unwrap_or("ACP Preview foreground work failed").into()),
        ),
        "refusal" => (
            DoneStatus::Errored,
            Some("ACP Preview agent refused the request".into()),
        ),
        _ => return None,
    })
}

async fn run_inner(
    session: &mut Session,
    init: &Value,
    started: &mut Option<String>,
    foreground_reported: &mut bool,
    transient_status: &mut status::Status,
    mut targets: Option<&mut mpsc::Receiver<cancel::Command>>,
) -> Result<Outcome, HarnessError> {
    let interrupt = session.controls.interrupt.clone();
    let event_tx = session.event_tx.clone();
    let (id, response, mut projection) = tokio::select! {
        _ = interrupt.cancelled() => return Ok((DoneStatus::Interrupted, None)),
        _ = event_tx.closed() => return Ok((DoneStatus::Interrupted, None)),
        result = tokio::time::timeout(session.handshake_timeout, setup(session, init)) => result.map_err(|_| protocol("ACP Preview setup timed out"))??,
    };
    if session.request.resume.is_some()
        && !projection
            .session(&id)
            .and_then(|s| s.state.as_ref())
            .is_some_and(|state| state["state"] == "idle")
    {
        return Err(protocol(
            "ACP Preview resumed without a confirmed idle foreground",
        ));
    }
    *started = Some(id.clone());
    let _ = send(
        &event_tx,
        AgentEvent::SessionStarted {
            harness: session.harness,
            model: session.request.model.clone().unwrap_or_default(),
            cwd: session.request.cwd.clone(),
            tools: vec![],
            session_id: id.clone(),
            assistant_message_id: new_message_id(),
        },
    )
    .await;
    let _ = send(
        &event_tx,
        AgentEvent::AvailableCommands {
            commands: commands(&response["availableCommands"]).unwrap_or_default(),
        },
    )
    .await;

    let request = &session.request;
    let images = init
        .pointer("/capabilities/session/prompt/image")
        .is_some_and(Value::is_object);
    let text = if session.harness == super::HarnessId::Graff {
        // Preview commands are ordinary text prompts, without the v1 Graff
        // command extension. Decode Nano's stored command selection first.
        harness_proto::invocation::graff_command_prompt(&request.prompt).0
    } else {
        request.prompt.clone()
    };
    let prompt =
        prompt_images::prompt_blocks(text, &request.attachments, &request.attachments, images)
            .await;
    if prompt.is_empty() {
        return Err(protocol("ACP Preview cannot submit an empty prompt"));
    }
    if interrupt.is_cancelled() || event_tx.is_closed() {
        return Ok((DoneStatus::Interrupted, None));
    }
    let client = &session.client;
    let acknowledgement = client.request("session/prompt", json!({
        "sessionId": id, "prompt": prompt, "idempotencyKey": submission_key(session.controls.origin.as_ref()),
    }));
    tokio::pin!(acknowledgement);
    let ack_deadline = tokio::time::sleep(session.handshake_timeout);
    tokio::pin!(ack_deadline);
    let mut foreground = Foreground::default();
    let mut retry_outcome = None;
    let mut display = display::Display::default();
    if session.request.resume.is_some() {
        display.communications(&projection, &id, true);
    }
    let mut pending_cancels = std::collections::HashMap::new();
    let mut form: Option<(
        Value,
        Vec<harness_proto::UserInputQuestion>,
        tokio::sync::oneshot::Receiver<Vec<harness_proto::UserInputAnswer>>,
    )> = None;
    if let Some(state) = projection.session(&id).and_then(|s| s.state.as_ref()) {
        let mut snapshot = state.clone();
        snapshot["sessionUpdate"] = json!("state_update");
        for event in display.update(&projection, &id, &snapshot) {
            let _ = send(&event_tx, event).await;
        }
    }
    let mut cancelled = false;
    let cancel_deadline = tokio::time::sleep(std::time::Duration::ZERO);
    tokio::pin!(cancel_deadline);
    loop {
        if *foreground_reported && !display.has_background() {
            return Ok((DoneStatus::Completed, None));
        }
        if !*foreground_reported
            && let Some(outcome) = retry_outcome.take().or_else(|| foreground.outcome())
        {
            for event in display.communications(&projection, &id, false) {
                let _ = send(&event_tx, event).await;
            }
            if let Some((request_id, _, _)) = form.take() {
                client.respond(&request_id, json!({"action": "cancel"}));
            }
            if !display.has_background() || cancelled {
                return Ok(outcome);
            }
            *foreground_reported = true;
            let _ = send(
                &event_tx,
                AgentEvent::Done {
                    status: outcome.0,
                    result: None,
                    error: outcome.1,
                    session_id: Some(id.clone()),
                },
            )
            .await;
        }
        tokio::select! {
            biased;
            _ = event_tx.closed() => return Ok((DoneStatus::Interrupted, None)),
            _ = interrupt.cancelled(), if !cancelled => {
                client.notify("session/cancel", Some(json!({"sessionId": id})));
                if let Some((request_id, _, _)) = form.take() {
                    client.respond(&request_id, json!({"action": "cancel"}));
                }
                cancelled = true;
                cancel_deadline.as_mut().reset(tokio::time::Instant::now() + session.interrupt_grace);
            }
            _ = &mut cancel_deadline, if cancelled => return Ok((DoneStatus::Interrupted, None)),
            ack = &mut acknowledgement, if foreground.ack.is_none() => {
                let ack = match ack {
                    Ok(ack) => ack,
                    Err(_) if cancelled => return Ok((DoneStatus::Interrupted, None)),
                    Err(_) if client.is_closed() => return Ok(uncertain_delivery()),
                    Err(error) => return Err(error),
                };
                let Some(message_id) = ack["messageId"].as_str().filter(|id| !id.is_empty()) else { return Ok(uncertain_delivery()); };
                foreground.ack = Some(message_id.to_owned());
                // Only this Graff prompt ACK correlates a stored outcome with the
                // submitted key. Replay state describes the session, not this turn.
                if session.harness == super::HarnessId::Graff {
                    let saved = &ack["_meta"]["graff/turnOutcome"];
                    if let Some(reason) = saved["stopReason"].as_str() {
                        let error = &saved["error"];
                        let message = error["code"].as_i64().and_then(|_| error["message"].as_str());
                        retry_outcome = terminal_outcome(reason, message);
                    }
                }
            }
            _ = &mut ack_deadline, if foreground.ack.is_none() && !cancelled => return Ok(uncertain_delivery()),
            answers = async { (&mut form.as_mut().unwrap().2).await }, if form.is_some() => {
                let (request_id, questions, _) = form.take().unwrap();
                client.respond(&request_id, interaction::answer(&questions, answers.unwrap_or_default()));
            }
            command = async { targets.as_mut().unwrap().recv().await }, if targets.is_some() && !cancelled => {
                if let Some(cancel::Command(target, reply)) = command {
                    match cancel::send(&projection, client, target) {
                        Some(Some(request_id)) => { pending_cancels.insert(request_id, reply); }
                        Some(None) => { let _ = reply.send(true); }
                        None => { let _ = reply.send(false); }
                    }
                } else {
                    targets = None;
                }
            }
            frame = session.incoming.recv() => match frame {
                Some(Incoming::OrderedResponse { id: request_id, outcome }) => {
                    if let Some(reply) = pending_cancels.remove(&request_id) {
                        let _ = reply.send(outcome.is_ok());
                    }
                }
                Some(Incoming::Request { id: request_id, method, params }) => {
                    if session.harness == super::HarnessId::Graff && !cancelled
                        && let Some(owner) = params["sessionId"].as_str()
                        && projection.session(owner).is_some_and(|child| child.parent.is_some())
                        && let Some(event) = transient_status.child_request(owner, &method, &request_id, &params)
                    {
                        let _ = send(&event_tx, event).await;
                    }
                    if let Some(questions) = (method == "elicitation/create" && !cancelled && !*foreground_reported && form.is_none()
                        && update_for(&params, &id).is_some() && foreground.observed_user.is_some())
                        .then(|| interaction::form(&params)).flatten()
                    {
                        let answers = (session.controls.request_input)(questions.clone());
                        form = Some((request_id, questions, answers));
                    } else {
                        reject_request(client, &request_id, &method);
                    }
                },
                Some(Incoming::Notification { method, params }) if method == "session/update" => {
                    if projection.apply(&params) != Ok(reducer::Applied::Live) { continue; }
                    let Some(owner) = params["sessionId"].as_str() else { continue; };
                    let update = &params["update"];
                    if session.harness == super::HarnessId::Graff
                        && let Some(event) = transient_status.update(owner, update)
                    {
                        let _ = send(&event_tx, event).await;
                    }
                    if session.harness == super::HarnessId::Graff && !cancelled && owner != id
                        && let Some(event) = transient_status.child_update(owner, update)
                    {
                        let _ = send(&event_tx, event).await;
                    }
                    for event in display.update(&projection, owner, update) {
                        let _ = send(&event_tx, event).await;
                    }
                    if owner != id {
                        if projection.session(owner).and_then(|child| child.parent.as_deref()) == Some(&id) {
                            let event = match update["sessionUpdate"].as_str() {
                                Some("agent_message_chunk") if update["content"]["type"] == "text" => update["content"]["text"].as_str().map(|text| AgentEvent::TextDelta { text: text.into() }),
                                Some("agent_message") => update["content"].as_array().map(|blocks| AgentEvent::TextDelta { text: blocks.iter().filter(|block| block["type"] == "text").filter_map(|block| block["text"].as_str()).collect() }),
                                Some("state_update") if update["state"] == "idle" => Some(AgentEvent::Done { status: DoneStatus::Completed, result: None, error: None, session_id: None }),
                                _ => None,
                            };
                            if let Some(event) = event && !matches!(&event, AgentEvent::TextDelta { text } if text.is_empty()) {
                                let _ = send(&event_tx, AgentEvent::Subagent { parent_tool_use_id: display::child_key(&id, owner), event: Box::new(event) }).await;
                            }
                        }
                        continue;
                    }
                    if *foreground_reported { continue; }
                    foreground.update(update);
                    match update["sessionUpdate"].as_str() {
                        Some("available_commands_update") => if let Some(commands) = commands(&update["availableCommands"]) {
                            let _ = send(&event_tx, AgentEvent::AvailableCommands { commands }).await;
                        },
                        Some("agent_message_chunk" | "agent_thought_chunk") if foreground.observed_user.is_some() && update["content"]["type"] == "text" => {
                            if let Some(text) = update["content"]["text"].as_str() {
                                let text = text.to_owned();
                                let event = if update["sessionUpdate"] == "agent_message_chunk" { AgentEvent::TextDelta { text } } else { AgentEvent::ReasoningDelta { text } };
                                let _ = send(&event_tx, event).await;
                            }
                        },
                        _ => {},
                    }
                },
                Some(Incoming::Eof) | None => return Ok(if cancelled {
                    (DoneStatus::Interrupted, None)
                } else if foreground.ack.is_some() {
                    (DoneStatus::Disconnected, Some("ACP Preview disconnected after accepting the message; foreground outcome is unknown".into()))
                } else {
                    uncertain_delivery()
                }),
                _ => {},
            }
        }
    }
}

fn uncertain_delivery() -> Outcome {
    (
        DoneStatus::Disconnected,
        Some("ACP Preview delivery is uncertain; the message was not retried".into()),
    )
}
