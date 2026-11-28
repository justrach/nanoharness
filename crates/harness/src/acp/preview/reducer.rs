//! Connection-local ACP v2 Preview projection (schema-v2.0.0-beta.4).
//!
//! Call in wire order, on the reducer for the connection that received the
//! frame. Use a fresh reducer for a replaying resume; keep any earlier local
//! transcript separately until the replay outcome is known. No I/O or actions
//! (including cancellation or granting permission) originate here.

use std::collections::{BTreeMap, HashMap};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Map, Value};

type Fields = Map<String, Value>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum EntityKind {
    UserMessage,
    AgentMessage,
    Thought,
    SessionMessage,
    Tool,
    Terminal,
    Plan,
    Compaction,
}

#[derive(Debug, Default)]
pub(super) struct Entity {
    pub fields: Fields,
    /// None means no output has been reported (or it was cleared).
    pub terminal_bytes: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum Replay {
    #[default]
    NotRequested,
    Pending,
    Marked,
    /// Successful response without this session's required marker.
    ConfirmedWithoutMarker,
    Truncated,
}

#[derive(Debug, Default)]
pub(super) struct Session {
    pub parent: Option<String>,
    pub replay: Replay,
    /// Fields from the parent's announcements, not including mirrored state.
    pub announcement: Fields,
    /// Current whole snapshot, from this session or its parent's live mirror.
    pub state: Option<Value>,
    /// First-seen timeline order, scoped to this session.
    pub order: Vec<(EntityKind, String)>,
    pub entities: HashMap<(EntityKind, String), Entity>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Applied {
    History,
    Live,
    ReplayMarker,
    Ignored,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Invalid {
    Shape,
    UnknownSession,
    Ownership,
    UnexpectedMarker,
}

pub(super) struct Reducer {
    sessions: HashMap<String, Session>,
    replay_in_flight: bool,
}

impl Reducer {
    /// Create before sending a resume with replay, or for an ordinary session
    /// once its root ID is known. Use one reducer per root activation.
    pub fn new(root: String, replay: bool) -> Self {
        Self {
            sessions: HashMap::from([(
                root,
                Session {
                    replay: if replay {
                        Replay::Pending
                    } else {
                        Replay::NotRequested
                    },
                    ..Session::default()
                },
            )]),
            replay_in_flight: replay,
        }
    }

    pub fn session(&self, id: &str) -> Option<&Session> {
        self.sessions.get(id)
    }

    /// Project both observations into the root transcript's message identity.
    /// The child copy can supply content before the root copy arrives, but
    /// only an explicit cross-reference allows it to stand in for that copy.
    pub fn communications<'a>(&'a self, root: &str) -> BTreeMap<&'a str, (bool, &'a [Value])> {
        let mut rows = BTreeMap::new();
        for (owner, session) in &self.sessions {
            if owner != root && session.parent.as_deref() != Some(root) {
                continue;
            }
            for ((kind, id), entity) in &session.entities {
                if *kind != EntityKind::SessionMessage {
                    continue;
                }
                let fields = &entity.fields;
                let (Ok(sender), Ok(recipient)) = (
                    string(fields, "senderSessionId"),
                    string(fields, "recipientSessionId"),
                ) else {
                    continue;
                };
                let (child, outgoing, reference) = if sender == root {
                    (recipient, true, "senderMessageId")
                } else if recipient == root {
                    (sender, false, "recipientMessageId")
                } else {
                    continue;
                };
                if self.session(child).and_then(|s| s.parent.as_deref()) != Some(root) {
                    continue;
                }
                let key = if owner == root {
                    id.as_str()
                } else if owner == child {
                    let Ok(link) = string(fields, reference) else {
                        continue;
                    };
                    link
                } else {
                    continue;
                };
                let Some(content) = fields.get("content").and_then(Value::as_array) else {
                    continue;
                };
                if owner == root {
                    rows.insert(key, (outgoing, content.as_slice()));
                } else {
                    rows.entry(key).or_insert((outgoing, content.as_slice()));
                }
            }
        }
        rows
    }

    /// Call on the matched resume response, or on loss of that connection.
    /// Returns the number of missing markers on success (a protocol violation).
    /// A marker confirms history selection, not successful activation.
    pub fn finish_replay(&mut self, success: bool) -> usize {
        self.replay_in_flight = false;
        let mut missing = 0;
        for session in self.sessions.values_mut() {
            if session.replay == Replay::Pending {
                session.replay = if success {
                    missing += 1;
                    Replay::ConfirmedWithoutMarker
                } else {
                    Replay::Truncated
                };
            }
        }
        missing
    }

    /// Apply `session/update` params (not a JSON-RPC envelope). `Live` is a
    /// routing classification, not a turn-completion signal: e.g. a resume
    /// snapshot can carry the stop reason of work already finished.
    pub fn apply(&mut self, params: &Value) -> Result<Applied, Invalid> {
        let params = object(params)?;
        validate(params, &[("_meta", Value::is_object)])?;
        let id = string(params, "sessionId")?;
        let update = object(params.get("update").ok_or(Invalid::Shape)?)?;
        let tag = string(update, "sessionUpdate")?;
        validate(update, &[("_meta", Value::is_object)])?;
        let session = self.sessions.get_mut(id).ok_or(Invalid::UnknownSession)?;
        if session.replay == Replay::Truncated {
            return Ok(Applied::Ignored);
        }
        let history = session.replay == Replay::Pending;
        match tag {
            "replay_complete" => {
                if !history {
                    return Err(Invalid::UnexpectedMarker);
                }
                session.replay = Replay::Marked;
                return Ok(Applied::ReplayMarker);
            }
            "state_update" => {
                state(update)?;
                if history {
                    return Ok(Applied::Ignored);
                }
                let mut snapshot = update.clone();
                snapshot.remove("sessionUpdate");
                session.state = Some(Value::Object(snapshot));
            }
            "subagent_update" => self.announce(id, update, history)?,
            "plan_update" => {
                let plan = object(update.get("plan").ok_or(Invalid::Shape)?)?;
                let plan_id = string(plan, "planId")?;
                match string(plan, "type")? {
                    "items" if !plan.get("entries").is_some_and(Value::is_array) => {
                        return Err(Invalid::Shape);
                    }
                    "markdown" => {
                        string(plan, "content")?;
                    }
                    _ => {}
                }
                session.entity(EntityKind::Plan, plan_id).fields = plan.clone();
            }
            "plan_removed" => {
                let key = (EntityKind::Plan, string(update, "planId")?.to_owned());
                session.entities.remove(&key);
                session.order.retain(|entry| entry != &key);
            }
            // The session driver owns these live reports; do not project them
            // into replay or synthesize absent configuration/usage/notices.
            "available_commands_update"
            | "config_option_update"
            | "session_info_update"
            | "usage_update"
            | "notice" => {
                return Ok(if history {
                    Applied::Ignored
                } else {
                    Applied::Live
                });
            }
            _ => {
                let Some((kind, key, chunk)) = entity_tag(tag) else {
                    return Ok(Applied::Ignored);
                };
                let entity_id = string(update, key)?;
                // The same session-local message ID cannot switch message kinds.
                let message_kinds = [
                    EntityKind::UserMessage,
                    EntityKind::AgentMessage,
                    EntityKind::Thought,
                    EntityKind::SessionMessage,
                ];
                if message_kinds.contains(&kind)
                    && message_kinds.iter().any(|other| {
                        *other != kind
                            && session
                                .entities
                                .contains_key(&(*other, entity_id.to_owned()))
                    })
                {
                    return Err(Invalid::Shape);
                }
                if kind == EntityKind::Terminal {
                    let bytes = if chunk {
                        Some(decode(string(update, "data")?)?)
                    } else {
                        validate(
                            update,
                            &[
                                ("command", Value::is_string),
                                ("cwd", Value::is_string),
                                ("exitStatus", Value::is_object),
                                ("size", Value::is_object),
                                ("capabilities", Value::is_object),
                            ],
                        )?;
                        update
                            .get("output")
                            .filter(|v| !v.is_null())
                            .map(|v| {
                                let output = object(v)?;
                                validate(output, &[("_meta", Value::is_object)])?;
                                decode(string(output, "data")?)
                            })
                            .transpose()?
                    };
                    let entity = session.entity(kind, entity_id);
                    if chunk {
                        entity
                            .terminal_bytes
                            .get_or_insert_with(Vec::new)
                            .extend(bytes.unwrap_or_default());
                    } else {
                        if update.contains_key("output") {
                            entity.terminal_bytes = bytes;
                            entity.fields.remove("outputMeta");
                            if let Some(meta) =
                                update["output"].get("_meta").filter(|v| !v.is_null())
                            {
                                entity.fields.insert("outputMeta".into(), meta.clone());
                            }
                        }
                        patch(
                            &mut entity.fields,
                            update,
                            &["command", "cwd", "exitStatus", "size", "capabilities"],
                        );
                    }
                } else if chunk {
                    let content = update.get("content").ok_or(Invalid::Shape)?;
                    content_item(kind, content)?;
                    let field = if kind == EntityKind::Compaction {
                        "summary"
                    } else {
                        "content"
                    };
                    let slot = session
                        .entity(kind, entity_id)
                        .fields
                        .entry(field)
                        .or_insert_with(|| Value::Array(Vec::new()));
                    slot.as_array_mut()
                        .expect("validated content array")
                        .push(content.clone());
                } else {
                    let field = if kind == EntityKind::Compaction {
                        "summary"
                    } else {
                        "content"
                    };
                    if let Some(items) = update.get(field).filter(|v| !v.is_null()) {
                        for item in items.as_array().ok_or(Invalid::Shape)? {
                            content_item(kind, item)?;
                        }
                    }
                    let fields: &[&str] = match kind {
                        EntityKind::Tool => {
                            validate(
                                update,
                                &[
                                    ("name", Value::is_string),
                                    ("title", Value::is_string),
                                    ("kind", Value::is_string),
                                    ("status", Value::is_string),
                                    ("locations", Value::is_array),
                                    ("capabilities", Value::is_object),
                                ],
                            )?;
                            &[
                                "name",
                                "title",
                                "kind",
                                "status",
                                "content",
                                "locations",
                                "rawInput",
                                "rawOutput",
                                "capabilities",
                            ]
                        }
                        EntityKind::SessionMessage => {
                            validate(
                                update,
                                &[
                                    ("senderSessionId", Value::is_string),
                                    ("recipientSessionId", Value::is_string),
                                    ("senderMessageId", Value::is_string),
                                    ("recipientMessageId", Value::is_string),
                                ],
                            )?;
                            &[
                                "content",
                                "senderSessionId",
                                "recipientSessionId",
                                "senderMessageId",
                                "recipientMessageId",
                            ]
                        }
                        EntityKind::Compaction => {
                            validate(
                                update,
                                &[("status", Value::is_string), ("error", Value::is_string)],
                            )?;
                            &["status", "summary", "error"]
                        }
                        _ => &["content"],
                    };
                    patch(&mut session.entity(kind, entity_id).fields, update, fields);
                }
            }
        }
        Ok(if history {
            Applied::History
        } else {
            Applied::Live
        })
    }

    fn announce(&mut self, parent: &str, update: &Fields, history: bool) -> Result<(), Invalid> {
        let id = string(update, "sessionId")?;
        // An existing root cannot become a child; an existing child cannot be
        // reparented. Because parents must already exist, this also bars cycles.
        if id == parent
            || self
                .sessions
                .get(id)
                .is_some_and(|s| s.parent.as_deref() != Some(parent))
        {
            return Err(Invalid::Ownership);
        }
        validate(
            update,
            &[
                ("title", Value::is_string),
                ("description", Value::is_string),
                ("cwd", Value::is_string),
                ("capabilities", Value::is_object),
            ],
        )?;
        if let Some(dirs) = update.get("additionalDirectories").filter(|v| !v.is_null()) {
            if !dirs
                .as_array()
                .is_some_and(|a| a.iter().all(Value::is_string))
            {
                return Err(Invalid::Shape);
            }
        }
        let mirror = update.get("state");
        if let Some(snapshot) = mirror.filter(|v| !v.is_null()) {
            state(object(snapshot)?)?;
        }
        let child = self
            .sessions
            .entry(id.to_owned())
            .or_insert_with(|| Session {
                parent: Some(parent.to_owned()),
                replay: if self.replay_in_flight {
                    Replay::Pending
                } else {
                    Replay::NotRequested
                },
                ..Session::default()
            });
        patch(
            &mut child.announcement,
            update,
            &["title", "description", "cwd", "additionalDirectories"],
        );
        if !history {
            // Avoid applying top-level metadata twice.
            patch_field(&mut child.announcement, update, "capabilities");
            if let Some(snapshot) = mirror {
                child.state = (!snapshot.is_null()).then(|| snapshot.clone());
            }
        }
        Ok(())
    }
}

impl Session {
    fn entity(&mut self, kind: EntityKind, id: &str) -> &mut Entity {
        let key = (kind, id.to_owned());
        self.entities.entry(key.clone()).or_insert_with(|| {
            self.order.push(key);
            Entity::default()
        })
    }
}

fn entity_tag(tag: &str) -> Option<(EntityKind, &'static str, bool)> {
    use EntityKind::*;
    Some(match tag {
        "user_message" => (UserMessage, "messageId", false),
        "user_message_chunk" => (UserMessage, "messageId", true),
        "agent_message" => (AgentMessage, "messageId", false),
        "agent_message_chunk" => (AgentMessage, "messageId", true),
        "agent_thought" => (Thought, "messageId", false),
        "agent_thought_chunk" => (Thought, "messageId", true),
        "session_message" => (SessionMessage, "messageId", false),
        "session_message_chunk" => (SessionMessage, "messageId", true),
        "tool_call_update" => (Tool, "toolCallId", false),
        "tool_call_content_chunk" => (Tool, "toolCallId", true),
        "terminal_update" => (Terminal, "terminalId", false),
        "terminal_output_chunk" => (Terminal, "terminalId", true),
        "compaction_update" => (Compaction, "compactionId", false),
        "compaction_summary_chunk" => (Compaction, "compactionId", true),
        _ => return None,
    })
}

fn object(value: &Value) -> Result<&Fields, Invalid> {
    value.as_object().ok_or(Invalid::Shape)
}

fn string<'a>(fields: &'a Fields, key: &str) -> Result<&'a str, Invalid> {
    fields
        .get(key)
        .and_then(Value::as_str)
        .ok_or(Invalid::Shape)
}

fn validate(fields: &Fields, columns: &[(&str, fn(&Value) -> bool)]) -> Result<(), Invalid> {
    if columns
        .iter()
        .any(|(key, check)| fields.get(*key).is_some_and(|v| !v.is_null() && !check(v)))
    {
        return Err(Invalid::Shape);
    }
    Ok(())
}

fn state(fields: &Fields) -> Result<(), Invalid> {
    string(fields, "state")?;
    validate(
        fields,
        &[
            ("stopReason", Value::is_string),
            ("_meta", Value::is_object),
        ],
    )?;
    if let Some(background) = fields.get("background").filter(|v| !v.is_null()) {
        for item in background.as_array().ok_or(Invalid::Shape)? {
            let item = object(item)?;
            let key = match string(item, "type")? {
                "tool_call" => "toolCallId",
                "terminal" => "terminalId",
                "subagent" => "sessionId",
                _ => continue,
            };
            string(item, key)?;
        }
    }
    Ok(())
}

fn content_item(kind: EntityKind, item: &Value) -> Result<(), Invalid> {
    let item = object(item)?;
    match (kind, string(item, "type")?) {
        (EntityKind::Tool, "content") => content_item(
            EntityKind::AgentMessage,
            item.get("content").ok_or(Invalid::Shape)?,
        )?,
        (EntityKind::Tool, "diff") if !item.get("changes").is_some_and(Value::is_array) => {
            return Err(Invalid::Shape);
        }
        (EntityKind::Tool, "terminal") => {
            string(item, "terminalId")?;
        }
        (EntityKind::Tool, "session") => {
            string(item, "sessionId")?;
        }
        (_, "text") => {
            string(item, "text")?;
        }
        _ => {} // Preserve future variants and opaque nested payloads.
    }
    Ok(())
}

fn decode(data: &str) -> Result<Vec<u8>, Invalid> {
    STANDARD.decode(data).map_err(|_| Invalid::Shape)
}

fn patch_field(target: &mut Fields, update: &Fields, key: &str) {
    match update.get(key) {
        None => {}
        Some(Value::Null) => {
            target.remove(key);
        }
        Some(value) => {
            target.insert(key.into(), value.clone());
        }
    }
}

fn patch(target: &mut Fields, update: &Fields, keys: &[&str]) {
    for key in keys {
        patch_field(target, update, key);
    }
    if let Some(Value::Object(delta)) = update.get("_meta") {
        let metadata = target
            .entry("_meta")
            .or_insert_with(|| Value::Object(Fields::new()));
        let metadata = metadata.as_object_mut().expect("validated metadata object");
        for key in delta.keys() {
            patch_field(metadata, delta, key);
        }
    } else if update.get("_meta") == Some(&Value::Null) {
        target.remove("_meta");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn send(r: &mut Reducer, id: &str, update: Value) -> Result<Applied, Invalid> {
        r.apply(&json!({"sessionId": id, "update": update}))
    }

    fn mark(r: &mut Reducer, id: &str) -> Result<Applied, Invalid> {
        send(r, id, json!({"sessionUpdate": "replay_complete"}))
    }

    fn entity<'a>(r: &'a Reducer, session: &str, kind: EntityKind, id: &str) -> &'a Entity {
        &r.session(session).unwrap().entities[&(kind, id.into())]
    }

    #[test]
    fn replay_barriers_follow_the_reporting_session_not_the_root() {
        let mut r = Reducer::new("root".into(), true);
        assert_eq!(
            send(
                &mut r,
                "root",
                json!({"sessionUpdate":"subagent_update", "sessionId":"child", "state":{"state":"idle"}, "capabilities":{"cancel":{}}})
            ),
            Ok(Applied::History)
        );
        assert!(
            r.session("child")
                .unwrap()
                .announcement
                .get("capabilities")
                .is_none()
        );
        assert!(r.session("child").unwrap().state.is_none());
        assert_eq!(
            send(
                &mut r,
                "child",
                json!({"sessionUpdate":"state_update", "state":"idle"})
            ),
            Ok(Applied::Ignored)
        );
        assert_eq!(mark(&mut r, "child"), Ok(Applied::ReplayMarker));
        assert_eq!(
            send(
                &mut r,
                "child",
                json!({"sessionUpdate":"state_update", "state":"running"})
            ),
            Ok(Applied::Live)
        );
        assert_eq!(r.session("root").unwrap().replay, Replay::Pending);
        assert_eq!(mark(&mut r, "root"), Ok(Applied::ReplayMarker));
        assert_eq!(mark(&mut r, "root"), Err(Invalid::UnexpectedMarker));
        send(
            &mut r,
            "root",
            json!({"sessionUpdate":"subagent_update", "sessionId":"child", "state":null}),
        )
        .unwrap();
        assert!(r.session("child").unwrap().state.is_none());
        assert_eq!(r.finish_replay(true), 0);
        assert!(r.session("root").unwrap().state.is_none());
    }

    #[test]
    fn replay_loss_and_missing_markers_do_not_invent_state() {
        let mut r = Reducer::new("root".into(), true);
        mark(&mut r, "root").unwrap();
        send(
            &mut r,
            "root",
            json!({"sessionUpdate":"subagent_update", "sessionId":"child"}),
        )
        .unwrap();
        r.finish_replay(false);
        assert_eq!(r.session("root").unwrap().replay, Replay::Marked);
        assert_eq!(r.session("child").unwrap().replay, Replay::Truncated);
        assert_eq!(mark(&mut r, "child"), Ok(Applied::Ignored));
        let mut r = Reducer::new("root".into(), true);
        assert_eq!(r.finish_replay(true), 1);
        assert_eq!(
            r.session("root").unwrap().replay,
            Replay::ConfirmedWithoutMarker
        );
        assert!(r.session("root").unwrap().state.is_none());
    }

    #[test]
    fn ownership_requires_announcement_and_ids_are_session_local() {
        let mut r = Reducer::new("root".into(), false);
        send(&mut r, "root", json!({"sessionUpdate":"session_message", "messageId":"shared", "recipientSessionId":"child"})).unwrap();
        let tool = json!({"sessionUpdate":"tool_call_update", "toolCallId":"shared", "status":"completed"});
        assert_eq!(
            send(&mut r, "child", tool.clone()),
            Err(Invalid::UnknownSession)
        );
        send(
            &mut r,
            "root",
            json!({"sessionUpdate":"subagent_update", "sessionId":"child"}),
        )
        .unwrap();
        send(
            &mut r,
            "child",
            json!({"sessionUpdate":"subagent_update", "sessionId":"nested"}),
        )
        .unwrap();
        assert_eq!(
            send(
                &mut r,
                "root",
                json!({"sessionUpdate":"subagent_update", "sessionId":"nested"})
            ),
            Err(Invalid::Ownership)
        );
        assert_eq!(
            send(
                &mut r,
                "nested",
                json!({"sessionUpdate":"subagent_update", "sessionId":"root"})
            ),
            Err(Invalid::Ownership)
        );
        send(&mut r, "child", tool).unwrap();
        send(
            &mut r,
            "root",
            json!({"sessionUpdate":"tool_call_update", "toolCallId":"shared"}),
        )
        .unwrap();
        assert!(
            entity(&r, "root", EntityKind::Tool, "shared")
                .fields
                .get("status")
                .is_none()
        );
        assert_eq!(
            entity(&r, "child", EntityKind::Tool, "shared").fields["status"],
            "completed"
        );
    }

    #[test]
    fn interleaved_chunks_patch_by_id_and_malformed_updates_are_atomic() {
        let mut r = Reducer::new("root".into(), true);
        for (id, text) in [("a", "1"), ("b", "2"), ("a", "3")] {
            send(&mut r, "root", json!({"sessionUpdate":"agent_message_chunk", "messageId":id, "content":{"type":"text", "text":text}, "_meta":{"transient":true}})).unwrap();
        }
        mark(&mut r, "root").unwrap();
        fn a(r: &Reducer) -> &Entity {
            entity(r, "root", EntityKind::AgentMessage, "a")
        }
        assert_eq!(a(&r).fields["content"].as_array().unwrap().len(), 2);
        assert!(a(&r).fields.get("_meta").is_none());
        assert_eq!(
            send(
                &mut r,
                "root",
                json!({"sessionUpdate":"agent_message", "messageId":"a", "content":[{"type":"text"}], "_meta":{"bad":true}})
            ),
            Err(Invalid::Shape)
        );
        assert!(a(&r).fields.get("_meta").is_none());
        send(&mut r, "root", json!({"sessionUpdate":"agent_message", "messageId":"a", "content":null, "_meta":{"a":{"old":true},"b":2}})).unwrap();
        send(&mut r, "root", json!({"sessionUpdate":"agent_message", "messageId":"a", "_meta":{"a":{"new":true},"b":null}})).unwrap();
        assert_eq!(a(&r).fields["_meta"], json!({"a":{"new":true}}));
        assert!(a(&r).fields.get("content").is_none());
        send(&mut r, "root", json!({"sessionUpdate":"agent_message_chunk", "messageId":"a", "content":{"type":"text", "text":"4"}})).unwrap();
        assert_eq!(
            a(&r).fields["content"],
            json!([{"type":"text", "text":"4"}])
        );
        assert_eq!(
            r.session("root").unwrap().order,
            vec![
                (EntityKind::AgentMessage, "a".into()),
                (EntityKind::AgentMessage, "b".into())
            ]
        );
    }

    #[test]
    fn terminal_snapshots_replace_independently_decoded_chunks() {
        let mut r = Reducer::new("root".into(), false);
        fn terminal(r: &Reducer) -> &Entity {
            entity(r, "root", EntityKind::Terminal, "t")
        }
        for data in ["/w==", "YQ=="] {
            send(
                &mut r,
                "root",
                json!({"sessionUpdate":"terminal_output_chunk", "terminalId":"t", "data":data}),
            )
            .unwrap();
        }
        assert_eq!(
            terminal(&r).terminal_bytes.as_deref(),
            Some(&[255, b'a'][..])
        );
        send(
            &mut r,
            "root",
            json!({"sessionUpdate":"terminal_update", "terminalId":"t", "output":{"data":"Yg=="}}),
        )
        .unwrap();
        assert_eq!(
            send(
                &mut r,
                "root",
                json!({"sessionUpdate":"terminal_output_chunk", "terminalId":"t", "data":"not base64"})
            ),
            Err(Invalid::Shape)
        );
        assert_eq!(terminal(&r).terminal_bytes.as_deref(), Some(&b"b"[..]));
        send(
            &mut r,
            "root",
            json!({"sessionUpdate":"terminal_update", "terminalId":"t", "output":null}),
        )
        .unwrap();
        assert!(terminal(&r).terminal_bytes.is_none());
    }
}
