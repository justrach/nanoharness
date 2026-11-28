use std::collections::{HashMap, HashSet};

use harness_proto::{AgentEvent, TodoItem, ToolCall};
use serde_json::{Value, json};

use super::reducer::{EntityKind, Reducer};

#[derive(Default)]
pub(super) struct Display {
    shown: HashSet<String>,
    settled: HashSet<String>,
    background: HashMap<String, HashSet<String>>,
}

fn scoped(owner: &str, kind: &str, id: &str) -> String {
    format!("acp2:{}", json!([owner, kind, id]))
}

fn safe_text(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
        .take(8192)
        .collect()
}

impl Display {
    pub fn has_background(&self) -> bool {
        self.background.values().any(|tasks| !tasks.is_empty())
    }

    pub fn update(&mut self, reducer: &Reducer, owner: &str, update: &Value) -> Vec<AgentEvent> {
        let Some(session) = reducer.session(owner) else {
            return vec![];
        };
        let mut events = vec![];
        let tag = update["sessionUpdate"].as_str().unwrap_or_default();
        if tag == "state_update" {
            // Omitted or null is not evidence of a task settling.
            if let Some(entries) = update["background"].as_array() {
                let current: HashSet<_> = entries
                    .iter()
                    .filter_map(|entry| {
                        let kind = entry["type"].as_str()?;
                        let key = match kind {
                            "tool_call" => "toolCallId",
                            "terminal" => "terminalId",
                            "subagent" => "sessionId",
                            _ => return None,
                        };
                        let id = entry[key].as_str()?;
                        if kind == "subagent"
                            && reducer.session(id)?.parent.as_deref() != Some(owner)
                        {
                            return None;
                        }
                        Some(scoped(owner, kind, id))
                    })
                    .collect();
                let prev = self.background.entry(owner.to_owned()).or_default();
                events.extend(
                    prev.difference(&current)
                        .map(|id| AgentEvent::BackgroundTask {
                            id: id.clone(),
                            running: false,
                        }),
                );
                events.extend(
                    current
                        .difference(prev)
                        .map(|id| AgentEvent::BackgroundTask {
                            id: id.clone(),
                            running: true,
                        }),
                );
                *prev = current;
            }
        }
        let (entity_kind, raw_id, wire_kind) = match tag {
            "tool_call_update" | "tool_call_content_chunk" => {
                (EntityKind::Tool, &update["toolCallId"], "tool_call")
            }
            "terminal_update" | "terminal_output_chunk" => {
                (EntityKind::Terminal, &update["terminalId"], "terminal")
            }
            "plan_update" => (EntityKind::Plan, &update["plan"]["planId"], "plan"),
            _ => return events,
        };
        let Some(raw_id) = raw_id.as_str() else {
            return events;
        };
        let Some(entity) = session.entities.get(&(entity_kind, raw_id.to_owned())) else {
            return events;
        };
        let id = scoped(owner, wire_kind, raw_id);
        let fields = &entity.fields;
        let field = |key: &str| fields.get(key).unwrap_or(&Value::Null);
        if entity_kind == EntityKind::Plan {
            if let Some(entries) = field("entries").as_array() {
                let items = entries
                    .iter()
                    .filter_map(|entry| {
                        let done = match entry["status"].as_str()? {
                            "completed" => true,
                            "pending" | "in_progress" => false,
                            _ => return None,
                        };
                        Some(TodoItem {
                            text: safe_text(entry["content"].as_str()?),
                            done,
                        })
                    })
                    .collect();
                events.push(AgentEvent::ToolCall {
                    id,
                    call: ToolCall::Todo { items },
                });
            }
            return events;
        }
        let name = field(if entity_kind == EntityKind::Terminal {
            "command"
        } else {
            "title"
        })
        .as_str()
        .or_else(|| field("name").as_str())
        .unwrap_or(wire_kind);
        if self.shown.insert(id.clone()) {
            events.push(AgentEvent::ToolCall {
                id: id.clone(),
                call: ToolCall::Unknown {
                    name: safe_text(name),
                    input: None,
                },
            });
        }
        let status = field("status").as_str();
        let output = if entity_kind == EntityKind::Terminal {
            entity
                .terminal_bytes
                .as_ref()
                .map(|bytes| safe_text(&String::from_utf8_lossy(bytes)))
        } else {
            field("content").as_array().map(|items| {
                let mut text = String::new();
                for item in items {
                    if let Some(block) = match item["type"].as_str() {
                        Some("content") if item["content"]["type"] == "text" => {
                            item["content"]["text"].as_str()
                        }
                        Some("diff") if item["patch"]["format"] == "git_patch" => {
                            item["patch"]["text"].as_str()
                        }
                        _ => None,
                    } {
                        text.extend(block.chars().take(8192usize.saturating_sub(text.len())));
                    }
                }
                safe_text(&text)
            })
        };
        let failed = if entity_kind == EntityKind::Terminal {
            let exit = field("exitStatus");
            exit["exitCode"]
                .as_i64()
                .map(|code| code != 0)
                .or_else(|| exit["signal"].as_str().map(|_| true))
        } else {
            match status {
                Some("completed") => Some(false),
                Some("failed" | "cancelled") => Some(true),
                _ => None,
            }
        };
        if let Some(is_error) = failed {
            if self.settled.insert(id.clone()) {
                events.push(AgentEvent::ToolResult {
                    id,
                    is_error,
                    output,
                    diff: None,
                });
            }
        } else if output.is_some() || status == Some("paused") {
            events.push(AgentEvent::ToolProgress {
                id,
                output: output.unwrap_or_default(),
                state: status.map(str::to_owned),
            });
        }
        events
    }
}
