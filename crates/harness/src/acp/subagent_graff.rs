//! Draft ACP subagent sessions exposed by Graff.
//!
//! The parent announces a child with `subagent_update`; later ordinary ACP
//! updates carry the child's session ID. Harness keeps its existing subagent
//! document model by creating one parent Agent chip for each announcement and
//! routing child updates to that chip. A child ID is never used as a user-facing
//! session to prompt or resume.

use std::collections::{HashMap, HashSet};

use harness_proto::{AgentEvent, DoneStatus, ToolCall};
use serde_json::{Value, json};

use super::normalize::{map_update, subagent_reason};

/// What a failed child says when graff sent no reason. Older engines' terminal
/// frames carry `state` alone (`acp_subagent_live.zig` `finish` and
/// `finishBackground`); then only a foreground child's parent tool result
/// has the failure text. Newer ones add `reason` (and `failureKind`, which
/// Harness has no place for and ignores).
pub(crate) const NO_REASON: &str = "The subagent failed. Graff did not report why.";

#[derive(Default)]
pub(crate) struct GraffTracker {
    parent_session: String,
    children: HashMap<String, Child>,
    settled: HashSet<String>,
    background_seq: HashMap<String, u64>,
    /// Foreground children that reported `failed`, by chip (the parent's
    /// tool call id) → child id. graff writes the child's terminal update
    /// before the parent's result for that call, and only that result says
    /// why, so the child's Done waits for it (or for [`Self::finish_open`]).
    awaiting_reason: HashMap<String, String>,
}

struct Child {
    parent: String,
    chip_id: String,
    /// The chip is the parent's own tool call (`graff/parentToolCallId`),
    /// so that call's result follows the child's terminal update.
    tool_backed: bool,
    name: String,
    task: String,
}

impl GraffTracker {
    pub(crate) fn new(parent_session: String) -> Self {
        Self {
            parent_session,
            ..Self::default()
        }
    }

    /// Graff's namespaced background stream keeps running after the parent
    /// prompt settles. Correlate every frame to an announced child and the
    /// stable parent tool id before it can touch the chat's child transcript.
    pub(crate) fn map_background(&mut self, params: &Value) -> Vec<AgentEvent> {
        if params.get("parentSessionId").and_then(Value::as_str)
            != Some(self.parent_session.as_str())
        {
            return Vec::new();
        }
        let Some(id) = params
            .get("subagentSessionId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && *id != self.parent_session.as_str())
        else {
            return Vec::new();
        };
        let Some(tool_id) = params
            .get("parentToolCallId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
        else {
            return Vec::new();
        };
        let Some(seq) = params.get("seq").and_then(Value::as_u64) else {
            return Vec::new();
        };
        if self.background_seq.get(id).is_some_and(|last| seq <= *last) || self.settled.contains(id)
        {
            return Vec::new();
        }
        let Some(event) = params.get("event") else {
            return Vec::new();
        };
        let result = match event.get("type").and_then(Value::as_str) {
            Some("spawn") if !self.children.contains_key(id) => self.map(
                Some(&self.parent_session.clone()),
                &json!({
                    "sessionUpdate": "subagent_update",
                    "subagentSessionId": id,
                    "name": event.get("name").and_then(Value::as_str).unwrap_or("Subagent"),
                    "task": event.get("task").and_then(Value::as_str).unwrap_or(""),
                    "_meta": { "graff/parentToolCallId": tool_id },
                }),
            ),
            Some("update")
                if self
                    .children
                    .get(id)
                    .is_some_and(|child| child.chip_id == tool_id) =>
            {
                let Some(update) = event.get("update").filter(|update| update.is_object()) else {
                    return Vec::new();
                };
                self.map(Some(id), update)
            }
            Some("terminal")
                if self
                    .children
                    .get(id)
                    .is_some_and(|child| child.chip_id == tool_id) =>
            {
                let Some(state) = event.get("state").and_then(Value::as_str).filter(|state| {
                    matches!(
                        *state,
                        "completed" | "failed" | "cancelled" | "disconnected"
                    )
                }) else {
                    return Vec::new();
                };
                // A detached child's spawn call resolved long ago: no
                // result with a reason follows this frame, only its own.
                self.map_subagent(
                    &self.parent_session.clone(),
                    &json!({
                        "sessionUpdate": "subagent_update", "subagentSessionId": id, "state": state,
                        "_meta": { "graff/subagent": { "reason": event.get("reason") } },
                    }),
                    false,
                )
            }
            _ => return Vec::new(),
        };
        self.background_seq.insert(id.to_owned(), seq);
        result
    }

    pub(crate) fn map(&mut self, session: Option<&str>, update: &Value) -> Vec<AgentEvent> {
        let Some(session) = session else {
            return Vec::new();
        };
        if update.get("sessionUpdate").and_then(Value::as_str) != Some("subagent_update") {
            if session == self.parent_session {
                return self.release_failed(map_update(update));
            }
            let Some(child) = self.children.get(session) else {
                return Vec::new();
            };
            if self.settled.contains(session) {
                return Vec::new();
            }
            return self.wrap(&child.parent, &child.chip_id, map_update(update));
        }
        self.map_subagent(session, update, true)
    }

    /// A failed child's Done, once its parent call's result arrives: the
    /// result's text (when the call failed) is the child's reason.
    fn release_failed(&mut self, events: Vec<AgentEvent>) -> Vec<AgentEvent> {
        if self.awaiting_reason.is_empty() {
            return events;
        }
        let mut released = Vec::new();
        for event in &events {
            let AgentEvent::ToolResult {
                id,
                is_error,
                output,
                ..
            } = event
            else {
                continue;
            };
            let Some(child) = self.awaiting_reason.remove(id) else {
                continue;
            };
            let reason = output
                .as_deref()
                .map(str::trim)
                .filter(|text| *is_error && !text.is_empty())
                .unwrap_or(NO_REASON);
            released.extend(self.failed_done(&child, reason));
        }
        released.extend(events);
        released
    }

    fn failed_done(&self, child: &str, reason: &str) -> Vec<AgentEvent> {
        let Some(child) = self.children.get(child) else {
            return Vec::new();
        };
        self.wrap(
            &child.parent,
            &child.chip_id,
            vec![AgentEvent::Done {
                status: DoneStatus::Errored,
                result: None,
                error: Some(reason.to_owned()),
                session_id: None,
            }],
        )
    }

    fn map_subagent(
        &mut self,
        session: &str,
        update: &Value,
        result_follows: bool,
    ) -> Vec<AgentEvent> {
        let Some(id) = update
            .get("subagentSessionId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
        else {
            return Vec::new();
        };
        if id == self.parent_session
            || self.settled.contains(id)
            || session != self.parent_session && !self.children.contains_key(session)
        {
            return Vec::new();
        }
        let first = !self.children.contains_key(id);
        let correlated_chip = update
            .get("_meta")
            .and_then(|meta| meta.get("graff/parentToolCallId"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty());
        let child = self.children.entry(id.to_owned()).or_insert_with(|| Child {
            parent: session.to_owned(),
            chip_id: correlated_chip
                .map(str::to_owned)
                .unwrap_or_else(|| format!("acp-subagent:{id}")),
            tool_backed: correlated_chip.is_some(),
            name: String::new(),
            task: String::new(),
        });
        if child.parent != session {
            return Vec::new();
        }
        let mut changed = first;
        if let Some(name) = update.get("name").and_then(Value::as_str) {
            changed |= child.name != name;
            child.name = name.to_owned();
        }
        if let Some(task) = update.get("task").and_then(Value::as_str) {
            changed |= child.task != task;
            child.task = task.to_owned();
        }
        let parent = child.parent.clone();
        let chip_id = child.chip_id.clone();
        let tool_backed = child.tool_backed;
        let task = child.task.clone();
        let title = if !task.is_empty() {
            task.clone()
        } else if !child.name.is_empty() {
            child.name.clone()
        } else {
            "Subagent".into()
        };
        let mut events = Vec::new();
        if changed {
            let call = AgentEvent::ToolCall {
                id: chip_id.clone(),
                call: ToolCall::Unknown {
                    name: format!("Agent: {title}"),
                    input: Some(json!({ "name": child.name, "task": task })),
                },
            };
            if parent == self.parent_session {
                events.push(call);
            } else if let Some(owner) = self.children.get(&parent) {
                events.push(AgentEvent::Subagent {
                    parent_tool_use_id: owner.chip_id.clone(),
                    event: Box::new(call),
                });
            }
        }
        if first {
            let opening = if task.is_empty() { title } else { task };
            events.extend(self.wrap(
                &parent,
                &chip_id,
                vec![AgentEvent::UserMessage { text: opening }],
            ));
        }
        let status = match update.get("state").and_then(Value::as_str) {
            Some("completed") => Some(DoneStatus::Completed),
            Some("failed") => Some(DoneStatus::Errored),
            Some("cancelled") => Some(DoneStatus::Cancelled),
            Some("disconnected") => Some(DoneStatus::Disconnected),
            _ => None,
        };
        if let Some(status) = status {
            self.settled.insert(id.to_owned());
            if status == DoneStatus::Errored {
                // The frame's own reason wins; then the parent's result is
                // ordinary tool output and settles nothing a second time.
                if let Some(reason) =
                    subagent_reason(update.pointer("/_meta/graff~1subagent/reason"))
                {
                    events.extend(self.failed_done(id, &reason));
                } else if result_follows && tool_backed && parent == self.parent_session {
                    self.awaiting_reason.insert(chip_id, id.to_owned());
                } else {
                    events.extend(self.failed_done(id, NO_REASON));
                }
                return events;
            }
            events.extend(self.wrap(
                &parent,
                &chip_id,
                vec![AgentEvent::Done {
                    status,
                    result: None,
                    error: None,
                    session_id: None,
                }],
            ));
        }
        events
    }

    pub(crate) fn finish_open(&mut self, _status: DoneStatus) -> Vec<AgentEvent> {
        // A child that said it failed, whose parent result never came.
        let mut events: Vec<AgentEvent> = std::mem::take(&mut self.awaiting_reason)
            .into_values()
            .flat_map(|child| self.failed_done(&child, NO_REASON))
            .collect();
        let open: Vec<(String, String, String)> = self
            .children
            .iter()
            .filter(|(id, _)| !self.settled.contains(*id))
            .map(|(id, child)| (id.clone(), child.parent.clone(), child.chip_id.clone()))
            .collect();
        for (id, parent, chip_id) in open {
            self.settled.insert(id);
            events.extend(self.wrap(
                &parent,
                &chip_id,
                vec![AgentEvent::Done {
                    // The parent ending without a child terminal update says
                    // nothing about the child's task outcome.
                    status: DoneStatus::Disconnected,
                    result: None,
                    error: None,
                    session_id: None,
                }],
            ));
        }
        events
    }

    fn wrap(&self, parent: &str, chip_id: &str, events: Vec<AgentEvent>) -> Vec<AgentEvent> {
        events
            .into_iter()
            .map(|event| {
                let event = AgentEvent::Subagent {
                    parent_tool_use_id: chip_id.to_owned(),
                    event: Box::new(event),
                };
                if parent == self.parent_session {
                    event
                } else if let Some(owner) = self.children.get(parent) {
                    AgentEvent::Subagent {
                        parent_tool_use_id: owner.chip_id.clone(),
                        event: Box::new(event),
                    }
                } else {
                    event
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use harness_proto::{AgentEvent, DoneStatus, ToolCall};
    use serde_json::json;

    use super::GraffTracker;

    fn background(id: &str, tool: &str, seq: u64, event: serde_json::Value) -> serde_json::Value {
        json!({
            "parentSessionId": "parent", "subagentSessionId": id,
            "parentToolCallId": tool, "seq": seq, "event": event,
        })
    }

    #[test]
    fn background_children_continue_after_parent_done_and_settle_independently() {
        let mut tracker = GraffTracker::new("parent".into());
        for (id, tool) in [("a", "call-a"), ("b", "call-b")] {
            let spawn = tracker.map_background(&background(
                id,
                tool,
                0,
                json!({
                    "type": "spawn", "name": "Explore", "task": format!("Inspect {id}")
                }),
            ));
            assert!(matches!(&spawn[0], AgentEvent::ToolCall { id, .. } if id == tool));
        }
        // The parent turn can already have emitted Done. Background frames
        // still map into the same stable child chip, independently per child.
        let b = tracker.map_background(&background("b", "call-b", 1, json!({
            "type": "update", "update": { "sessionUpdate": "agent_message_chunk", "content": {"type":"text", "text":"B"} }
        })));
        assert!(
            matches!(&b[..], [AgentEvent::Subagent { parent_tool_use_id, event }]
            if parent_tool_use_id == "call-b" && matches!(event.as_ref(), AgentEvent::TextDelta { text } if text == "B"))
        );
        let a = tracker.map_background(&background(
            "a",
            "call-a",
            1,
            json!({
                "type": "terminal", "state": "cancelled"
            }),
        ));
        assert!(
            matches!(&a[..], [AgentEvent::Subagent { parent_tool_use_id, event }]
            if parent_tool_use_id == "call-a" && matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Cancelled, .. }))
        );
        let b = tracker.map_background(&background(
            "b",
            "call-b",
            2,
            json!({
                "type": "terminal", "state": "completed"
            }),
        ));
        assert!(
            matches!(&b[..], [AgentEvent::Subagent { parent_tool_use_id, event }]
            if parent_tool_use_id == "call-b" && matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Completed, .. }))
        );
        assert!(tracker.finish_open(DoneStatus::Interrupted).is_empty());
    }

    #[test]
    fn background_rejects_unknown_mismatched_and_replayed_children() {
        let mut tracker = GraffTracker::new("parent".into());
        let unknown = background(
            "child",
            "call",
            2,
            json!({
                "type": "update", "update": { "sessionUpdate": "agent_message_chunk", "content": {"type":"text", "text":"x"} }
            }),
        );
        assert!(tracker.map_background(&unknown).is_empty());
        let mut wrong_parent = background("child", "call", 0, json!({ "type": "spawn" }));
        wrong_parent["parentSessionId"] = json!("other");
        assert!(tracker.map_background(&wrong_parent).is_empty());
        assert_eq!(
            tracker
                .map_background(&background("child", "call", 0, json!({ "type": "spawn" })))
                .len(),
            2
        );
        assert!(
            tracker
                .map_background(&background(
                    "child",
                    "wrong-call",
                    2,
                    json!({ "type": "terminal", "state": "completed" })
                ))
                .is_empty()
        );
        assert!(
            tracker
                .map_background(&background(
                    "child",
                    "call",
                    0,
                    json!({ "type": "terminal", "state": "completed" })
                ))
                .is_empty()
        );
        assert!(
            matches!(&tracker.map_background(&background("child", "call", 1, json!({ "type": "terminal", "state": "disconnected" })))[..],
            [AgentEvent::Subagent { event, .. }] if matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Disconnected, .. }))
        );
        assert!(
            tracker
                .map_background(&background(
                    "child",
                    "call",
                    3,
                    json!({ "type": "update", "update": {} })
                ))
                .is_empty()
        );
    }

    #[test]
    fn announces_routes_and_settles_two_interleaved_children() {
        let mut tracker = GraffTracker::new("parent".into());
        for id in ["child-a", "child-b"] {
            let events = tracker.map(
                Some("parent"),
                &json!({
                    "sessionUpdate": "subagent_update", "subagentSessionId": id,
                    "name": "Explore", "task": format!("Inspect {id}")
                }),
            );
            assert!(
                matches!(&events[0], AgentEvent::ToolCall { id: chip, call: ToolCall::Unknown { name, .. } }
                if chip == &format!("acp-subagent:{id}") && name == &format!("Agent: Inspect {id}"))
            );
            assert!(
                matches!(&events[1], AgentEvent::Subagent { parent_tool_use_id, event }
                if parent_tool_use_id == &format!("acp-subagent:{id}") && matches!(event.as_ref(), AgentEvent::UserMessage { .. }))
            );
        }
        let child = tracker.map(Some("child-b"), &json!({
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Found it"}
        }));
        assert!(
            matches!(&child[..], [AgentEvent::Subagent { parent_tool_use_id, event }]
            if parent_tool_use_id == "acp-subagent:child-b"
                && matches!(event.as_ref(), AgentEvent::TextDelta { text } if text == "Found it"))
        );
        let done = tracker.map(Some("parent"), &json!({
            "sessionUpdate": "subagent_update", "subagentSessionId": "child-b", "state": "completed"
        }));
        assert!(matches!(&done[..], [AgentEvent::Subagent { event, .. }]
            if matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Completed, .. })));
        assert!(tracker.map(Some("child-b"), &json!({
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Late"}
        })).is_empty());
        let unfinished = tracker.finish_open(DoneStatus::Interrupted);
        assert_eq!(unfinished.len(), 1);
        assert!(
            matches!(&unfinished[0], AgentEvent::Subagent { parent_tool_use_id, .. }
            if parent_tool_use_id == "acp-subagent:child-a")
        );
        assert!(matches!(&unfinished[0], AgentEvent::Subagent { event, .. }
            if matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Disconnected, .. })));
    }

    #[test]
    fn correlated_spawn_uses_parent_tool_id_and_preserves_terminal_outcomes() {
        let mut tracker = GraffTracker::new("parent".into());
        assert!(
            tracker
                .map(
                    Some("parent"),
                    &json!({
                        "sessionUpdate": "subagent_update", "subagentSessionId": "parent"
                    })
                )
                .is_empty()
        );
        let spawn = tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "subagent_update", "subagentSessionId": "child",
                "task": "Inspect tests", "_meta": {"graff/parentToolCallId": "call-9"}
            }),
        );
        assert!(matches!(&spawn[0], AgentEvent::ToolCall { id, .. } if id == "call-9"));
        assert!(
            matches!(&spawn[1], AgentEvent::Subagent { parent_tool_use_id, .. }
            if parent_tool_use_id == "call-9")
        );
        let cancelled = tracker.map(Some("parent"), &json!({
            "sessionUpdate": "subagent_update", "subagentSessionId": "child", "state": "cancelled"
        }));
        assert!(
            matches!(&cancelled[..], [AgentEvent::Subagent { parent_tool_use_id, event }]
            if parent_tool_use_id == "call-9"
                && matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Cancelled, .. }))
        );
        assert!(tracker.map(Some("parent"), &json!({
            "sessionUpdate": "subagent_update", "subagentSessionId": "child", "state": "failed"
        })).is_empty());
    }

    fn child_done(events: &[AgentEvent], chip: &str) -> Option<(DoneStatus, Option<String>)> {
        events.iter().find_map(|event| match event {
            AgentEvent::Subagent {
                parent_tool_use_id,
                event,
            } if parent_tool_use_id == chip => match event.as_ref() {
                AgentEvent::Done { status, error, .. } => Some((*status, error.clone())),
                _ => None,
            },
            _ => None,
        })
    }

    // graff's draft stream sends a failed child's terminal `subagent_update`
    // with `state` alone (acp_subagent_live.zig `finish`), then the parent's
    // own result for the same tool call, whose text is the failure
    // (subagent_run.zig `subagentFailure`). That text is the child's reason.
    #[test]
    fn failed_draft_child_takes_its_reason_from_the_parent_tool_result() {
        let mut tracker = GraffTracker::new("parent".into());
        tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "subagent_update", "subagentSessionId": "child",
                "task": "Audit the synthetic parser", "_meta": {"graff/parentToolCallId": "call-7"}
            }),
        );
        let failed = tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "subagent_update", "subagentSessionId": "child", "state": "failed",
                "_meta": {"graff/parentToolCallId": "call-7"}
            }),
        );
        assert_eq!(child_done(&failed, "call-7"), None, "held for the reason");
        let reason = "subagent sa-007 failed before producing a report: synthetic 503 \
                      [transport failure, 3 attempts]. retry is likely safe";
        let result = tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "tool_call_update", "toolCallId": "call-7", "status": "failed",
                "content": [{"type": "content", "content": {"type": "text", "text": reason}}]
            }),
        );
        assert_eq!(
            child_done(&result, "call-7"),
            Some((DoneStatus::Errored, Some(reason.to_owned())))
        );
        // The parent's chip still resolves as failed with the same text.
        assert!(result.iter().any(|event| matches!(event,
            AgentEvent::ToolResult { id, is_error: true, output: Some(text), .. }
                if id == "call-7" && text == reason)));
        assert!(tracker.finish_open(DoneStatus::Interrupted).is_empty());
    }

    // An older graff's background `terminal` event is `{type, state}` and
    // nothing else (acp_subagent_live.zig `finishBackground`), and a draft
    // child whose parent result never arrives has no reason either. Say it failed, and
    // that no reason came, rather than inventing one or calling it
    // disconnected.
    #[test]
    fn failed_child_without_a_reported_reason_says_so() {
        use super::NO_REASON;
        let mut tracker = GraffTracker::new("parent".into());
        tracker.map_background(&background(
            "bg",
            "call-bg",
            0,
            json!({ "type": "spawn", "name": "Explore", "task": "Inspect bg" }),
        ));
        let bg = tracker.map_background(&background(
            "bg",
            "call-bg",
            1,
            json!({ "type": "terminal", "state": "failed" }),
        ));
        assert_eq!(
            child_done(&bg, "call-bg"),
            Some((DoneStatus::Errored, Some(NO_REASON.to_owned())))
        );

        tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "subagent_update", "subagentSessionId": "fg",
                "task": "Inspect fg", "_meta": {"graff/parentToolCallId": "call-fg"}
            }),
        );
        tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "subagent_update", "subagentSessionId": "fg", "state": "failed"
            }),
        );
        let open = tracker.finish_open(DoneStatus::Interrupted);
        assert_eq!(
            child_done(&open, "call-fg"),
            Some((DoneStatus::Errored, Some(NO_REASON.to_owned())))
        );
    }

    fn child_dones(events: &[AgentEvent]) -> usize {
        events
            .iter()
            .filter(|event| {
                matches!(event, AgentEvent::Subagent { event, .. }
                if matches!(event.as_ref(), AgentEvent::Done { .. }))
            })
            .count()
    }

    // Newer graff puts the reason on the background terminal event itself.
    #[test]
    fn background_terminal_reason_is_the_failure_text() {
        let mut tracker = GraffTracker::new("parent".into());
        tracker.map_background(&background(
            "bg",
            "call-bg",
            0,
            json!({ "type": "spawn", "name": "Explore", "task": "Inspect bg" }),
        ));
        let reason = "synthetic quota refusal [quota/rate-limit failure, 3 attempts]";
        let bg = tracker.map_background(&background(
            "bg",
            "call-bg",
            1,
            json!({ "type": "terminal", "state": "failed", "reason": reason, "failureKind": "quota" }),
        ));
        assert_eq!(
            child_done(&bg, "call-bg"),
            Some((DoneStatus::Errored, Some(reason.to_owned())))
        );
    }

    // A draft terminal frame with its own reason settles at once; the
    // parent's later result for the same call must not settle it twice.
    #[test]
    fn draft_terminal_reason_is_used_without_waiting_for_the_parent() {
        let mut tracker = GraffTracker::new("parent".into());
        tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "subagent_update", "subagentSessionId": "child",
                "task": "Inspect example", "_meta": {"graff/parentToolCallId": "call-3"}
            }),
        );
        let reason = "synthetic bad argument [invalid-arguments failure, 1 attempt]";
        let failed = tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "subagent_update", "subagentSessionId": "child", "state": "failed",
                "_meta": {
                    "graff/parentToolCallId": "call-3",
                    "graff/subagent": {"reason": reason, "failureKind": "invalid"}
                }
            }),
        );
        assert_eq!(
            child_done(&failed, "call-3"),
            Some((DoneStatus::Errored, Some(reason.to_owned())))
        );
        let result = tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "tool_call_update", "toolCallId": "call-3", "status": "failed",
                "content": [{"type": "content", "content": {"type": "text",
                    "text": "subagent sa-003 failed before producing a report: synthetic bad argument"}}]
            }),
        );
        assert_eq!(child_dones(&result), 0, "{result:?}");
        assert!(
            result
                .iter()
                .any(|event| matches!(event, AgentEvent::ToolResult { id, is_error: true, .. } if id == "call-3"))
        );
        assert!(tracker.finish_open(DoneStatus::Interrupted).is_empty());
    }

    // The reason is untrusted display text: one line, no control or
    // direction-override characters, and bounded however long it arrives.
    #[test]
    fn an_unsafe_reason_is_displayed_safely() {
        let mut tracker = GraffTracker::new("parent".into());
        tracker.map_background(&background(
            "bg",
            "call-bg",
            0,
            json!({ "type": "spawn", "name": "Explore", "task": "Inspect bg" }),
        ));
        let raw = format!(
            "bad\u{1b}[31m red\r\nnext\tline\u{202e}reversed\u{0}{}",
            "é".repeat(2000)
        );
        let bg = tracker.map_background(&background(
            "bg",
            "call-bg",
            1,
            json!({ "type": "terminal", "state": "failed", "reason": raw }),
        ));
        let Some((DoneStatus::Errored, Some(text))) = child_done(&bg, "call-bg") else {
            panic!("{bg:?}");
        };
        assert!(
            text.starts_with("bad [31m red next line reversed"),
            "{text}"
        );
        assert!(
            !text.chars().any(|c| c.is_control() || c == '\u{202e}'),
            "{text}"
        );
        assert!(text.len() <= 512, "{}", text.len());
        assert!(text.ends_with('…'), "{text}");
    }
}
