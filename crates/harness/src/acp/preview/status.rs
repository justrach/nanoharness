use std::collections::{HashMap, HashSet};

use harness_proto::AgentEvent;
use serde_json::{Value, json};

#[derive(Default)]
pub(super) struct Status {
    recovery: HashMap<String, Value>,
    candidates: HashMap<String, Activity>,
    requests: HashSet<(String, Activity)>,
    shown: HashSet<(String, Activity)>,
    active: HashSet<String>,
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct Activity {
    kind: &'static str,
    id: String,
    tool: String,
}

fn activity(kind: &str, id: &Value, tool: &Value) -> Option<Activity> {
    let kind = match kind {
        "permission" => "child-permission",
        "elicitation" => "child-elicitation",
        _ => return None,
    };
    let id = if let Some(id) = id.as_str() {
        format!("s:{id}")
    } else {
        format!("n:{}", id.as_i64()?)
    };
    Some(Activity {
        kind,
        id,
        tool: tool.as_str().filter(|s| !s.is_empty())?.into(),
    })
}

fn child_event(owner: &str, state: &str) -> AgentEvent {
    AgentEvent::ToolProgress {
        id: format!(
            "{}child:{}",
            harness_proto::ACP_PREVIEW_STATUS_PREFIX,
            json!(owner)
        ),
        output: String::new(),
        state: Some(state.into()),
    }
}

fn event(owner: &str, value: Option<&Value>) -> AgentEvent {
    AgentEvent::ToolProgress {
        id: format!(
            "{}{}",
            harness_proto::ACP_PREVIEW_STATUS_PREFIX,
            json!(owner)
        ),
        output: value.map(Value::to_string).unwrap_or_default(),
        state: Some(
            if value.is_some() {
                "waiting"
            } else {
                "cleared"
            }
            .into(),
        ),
    }
}

impl Status {
    pub fn update(&mut self, owner: &str, update: &Value) -> Option<AgentEvent> {
        if update["sessionUpdate"] != "state_update" {
            return None;
        }
        let meta = &update["_meta"];
        let key = "graff/networkRecovery";
        let value = match update["state"].as_str()? {
            "running" if !meta.is_null() || update.get("_meta").is_none() => meta.get(key)?,
            _ => &Value::Null,
        };
        if value.is_null() {
            return self.recovery.remove(owner).map(|_| event(owner, None));
        }
        let cause = value["cause"].as_str()?;
        if value["phase"] != "waiting" || !matches!(cause, "connection_lost" | "stream_dropped") {
            return None;
        }
        let value = json!({"cause": cause, "attempt": value["attempt"].as_u64()?, "retryInMs": value["retryInMs"].as_u64()?});
        if self.recovery.get(owner) == Some(&value) {
            return None;
        }
        let result = event(owner, Some(&value));
        self.recovery.insert(owner.into(), value);
        Some(result)
    }

    pub fn child_update(&mut self, owner: &str, update: &Value) -> Option<AgentEvent> {
        if update["sessionUpdate"] != "state_update" {
            return None;
        }
        if update["state"] != "requires_action" {
            self.requests.retain(|(session, _)| session != owner);
            self.candidates.remove(owner);
            return self
                .active
                .remove(owner)
                .then(|| child_event(owner, "cleared"));
        }
        let value = update["_meta"].get("graff/childActivity")?;
        if value.is_null() {
            self.candidates.remove(owner);
            return self
                .active
                .remove(owner)
                .then(|| child_event(owner, "cleared"));
        }
        let candidate = activity(
            value["kind"].as_str()?,
            &value["requestId"],
            &value["toolCallId"],
        )?;
        self.candidates.insert(owner.into(), candidate);
        self.correlate(owner)
    }

    pub fn child_request(
        &mut self,
        owner: &str,
        method: &str,
        id: &Value,
        params: &Value,
    ) -> Option<AgentEvent> {
        let (kind, tool) = match method {
            "session/request_permission" if params["subject"]["type"] == "tool_call" => {
                ("permission", &params["subject"]["toolCall"]["toolCallId"])
            }
            "elicitation/create" if params.get("requestId").is_none() => {
                ("elicitation", &params["toolCallId"])
            }
            _ => return None,
        };
        if self.requests.len() >= 256 {
            return None;
        }
        self.requests
            .insert((owner.into(), activity(kind, id, tool)?));
        self.correlate(owner)
    }

    fn correlate(&mut self, owner: &str) -> Option<AgentEvent> {
        let key = (owner.to_owned(), self.candidates.get(owner)?.clone());
        if !self.requests.remove(&key)
            || self.shown.len() >= 1024
            || !self.shown.insert(key.clone())
        {
            return None;
        }
        self.active.insert(owner.into());
        Some(child_event(owner, key.1.kind))
    }

    pub fn clear(&mut self) -> impl Iterator<Item = AgentEvent> + '_ {
        self.recovery
            .drain()
            .map(|(owner, _)| event(&owner, None))
            .chain(
                self.active
                    .drain()
                    .map(|owner| child_event(&owner, "cleared")),
            )
    }
}
