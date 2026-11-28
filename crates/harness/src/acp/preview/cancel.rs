use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use super::{
    RpcClient,
    reducer::{EntityKind, Reducer},
};

/// A target in the currently active Preview connection, not a foreground stop.
#[derive(Debug, Clone)]
pub enum PreviewCancelTarget {
    Tool { session: String, id: String },
    Terminal { session: String, id: String },
    Child { session: String },
}

pub(super) struct Command(pub PreviewCancelTarget, pub oneshot::Sender<bool>);

#[derive(Default, Clone)]
pub(in crate::acp) struct Controls(Arc<Mutex<HashMap<String, mpsc::Sender<Command>>>>);

impl Controls {
    pub(super) fn attach(&self, chat: &str) -> (mpsc::Receiver<Command>, impl Drop + use<>) {
        let (tx, rx) = mpsc::channel(8);
        self.0.lock().unwrap().insert(chat.to_owned(), tx.clone());
        (rx, Registration(self.clone(), chat.to_owned(), tx))
    }

    pub async fn cancel(&self, chat: &str, target: PreviewCancelTarget) -> bool {
        let tx = self.0.lock().unwrap().get(chat).cloned();
        let Some(tx) = tx else {
            return false;
        };
        let (reply, outcome) = oneshot::channel();
        tx.try_send(Command(target, reply)).is_ok()
            && tokio::time::timeout(std::time::Duration::from_secs(5), outcome)
                .await
                .is_ok_and(|reply| reply.unwrap_or(false))
    }
}

struct Registration(Controls, String, mpsc::Sender<Command>);
impl Drop for Registration {
    fn drop(&mut self) {
        let mut routes = self.0.0.lock().unwrap();
        if routes
            .get(&self.1)
            .is_some_and(|route| route.same_channel(&self.2))
        {
            routes.remove(&self.1);
        }
    }
}

pub(super) fn send(
    reducer: &Reducer,
    client: &RpcClient,
    target: PreviewCancelTarget,
) -> Option<Option<i64>> {
    let (kind, session, id, method, id_field) = match target {
        PreviewCancelTarget::Tool { session, id } => (
            EntityKind::Tool,
            session,
            id,
            "tool_call/cancel",
            "toolCallId",
        ),
        PreviewCancelTarget::Terminal { session, id } => (
            EntityKind::Terminal,
            session,
            id,
            "terminal/cancel",
            "terminalId",
        ),
        PreviewCancelTarget::Child { session } => {
            let child = reducer.session(&session)?;
            child.parent.as_ref()?;
            if child.announcement.get("capabilities")?["cancel"].is_object()
                && child.state.as_ref().is_some_and(|state| {
                    matches!(state["state"].as_str(), Some("running" | "requires_action"))
                })
            {
                client.notify("session/cancel", Some(json!({"sessionId": session})));
                return Some(None);
            }
            return None;
        }
    };
    let owner = reducer.session(&session)?;
    let target = owner.entities.get(&(kind, id.clone()))?;
    if !target.fields.get("capabilities")?["cancel"].is_object() {
        return None;
    }
    let active = match kind {
        EntityKind::Tool => matches!(
            target.fields.get("status").and_then(Value::as_str),
            Some("pending" | "in_progress" | "paused")
        ),
        EntityKind::Terminal => !target.fields.contains_key("exitStatus"),
        _ => false,
    };
    if !active {
        return None;
    }
    let mut params = json!({"sessionId": session});
    params[id_field] = json!(id);
    client.request_ordered(method, params).ok().map(Some)
}
