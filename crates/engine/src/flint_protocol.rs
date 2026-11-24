//! Pure-Rust OpenAI-compatible protocol layer for Native Flint (`flint session`).
//!
//! Zero Python dependency: implements Flint's exact chat template, `<think>` /
//! `<tool_call>` XML protocol parser, KV-prefix reuse bookkeeping, 65,536-token
//! JSONL framing, and OpenAI JSON / SSE response builders.

use crate::flint_policy::NativeModelKind;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::{SystemTime, UNIX_EPOCH};

pub const MODEL_ID: &str = "flint";
pub const INKLING_MODEL_ID: &str = "inkling-2-mini";
pub const DEFAULT_INKLING_EFFORT: &str = "low";
pub const NATIVE_CHUNK: usize = 65_536;
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 4_096;

#[derive(Debug, Clone)]
pub struct AdapterError {
    pub status: u16,
    pub message: String,
}

impl AdapterError {
    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self {
            status: 400,
            message: msg.into(),
        }
    }
    pub fn new(status: u16, msg: impl Into<String>) -> Self {
        Self {
            status,
            message: msg.into(),
        }
    }
}

impl std::fmt::Display for AdapterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

pub trait FlintTokenizer: Send + Sync {
    fn encode(&self, text: &str) -> Result<Vec<u32>, String>;
    fn decode(&self, ids: &[u32]) -> Result<String, String>;
}

#[derive(Debug, Clone, Serialize)]
pub struct WorkerRequest {
    pub id: u64,
    pub tokens: Vec<u32>,
    pub max_tokens: u32,
    pub reset: bool,
    pub return_logits: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkerResponse {
    pub id: u64,
    pub tokens: Vec<u32>,
    pub eos: bool,
    pub cache_before: u32,
    pub cache_after: u32,
    pub prefill_tokens: usize,
    pub decode_forward_tokens: usize,
    pub reused_prefix_tokens: u32,
    pub prefill_seconds: f64,
    pub decode_seconds: f64,
    pub kv_allocated_bytes: u64,
    pub kv_valid_bytes: u64,
    #[serde(default = "default_kv_storage")]
    pub kv_storage: String,
}

fn default_kv_storage() -> String {
    "fp32".into()
}

pub trait FlintWorker: Send {
    fn request(&mut self, req: &WorkerRequest) -> Result<WorkerResponse, String>;
    fn close(&mut self, graceful: bool);
}

#[derive(Debug, Clone, PartialEq)]
pub struct NormalizedToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NormalizedMessage {
    pub role: String,
    pub content: String,
    pub reasoning_content: Option<String>,
    pub tool_calls: Vec<NormalizedToolCall>,
    pub tool_call_id: Option<String>,
    /// When set, emitted directly after `<|assistant|>` to preserve exact token prefixes.
    pub raw_assistant: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ParsedCompletion {
    pub content: String,
    pub reasoning_content: String,
    pub tool_calls: Vec<Value>,
    pub finish_reason: &'static str,
}

fn flint_text(t: &str) -> String {
    t.replace('\0', "")
        .replace("<think>", "")
        .replace("</think>", "")
        .replace("<|begin_of_text|>", "&lt;|begin_of_text|&gt;")
        .replace("<|end_of_text|>", "&lt;|end_of_text|&gt;")
        .replace("<|system|>", "&lt;|system|&gt;")
        .replace("<|developer|>", "&lt;|developer|&gt;")
        .replace("<|user|>", "&lt;|user|&gt;")
        .replace("<|assistant|>", "&lt;|assistant|&gt;")
        .replace("<|observation|>", "&lt;|observation|&gt;")
}

/// Exact port of Flint INT4's `chat_template.jinja`.
pub fn render_chat_template(
    messages: &[NormalizedMessage],
    tools: &[Value],
    add_generation_prompt: bool,
) -> String {
    let mut tool_preamble = String::new();
    if !tools.is_empty() {
        tool_preamble.push_str(
            "<|system|>\n# Tools\n\nYou may call one or more functions to assist with the user query.\n\nYou are provided with function signatures within <tools></tools> XML tags:\n<tools>",
        );
        for tool in tools {
            let func = tool.get("function").unwrap_or(tool);
            let serialized = serde_json::to_string(func).unwrap_or_else(|_| "{}".into());
            tool_preamble.push('\n');
            tool_preamble.push_str(&serialized);
        }
        tool_preamble.push_str(
            "\n</tools>\n\nFor each function call, output the function name and arguments within the following XML format:\n<tool_call>{function-name}<arg_key>{arg-key-1}</arg_key><arg_value>{arg-value-1}</arg_value>...</tool_call>\n",
        );
    }

    let mut out = String::new();
    let mut tools_pending = true;
    for m in messages {
        if tools_pending && m.role != "system" {
            out.push_str(&tool_preamble);
            tools_pending = false;
        }
        match m.role.as_str() {
            "system" => {
                out.push_str("<|system|>");
                out.push_str(&flint_text(&m.content));
            }
            "developer" => {
                out.push_str("<|developer|>");
                out.push_str(&flint_text(&m.content));
            }
            "user" => {
                out.push_str("<|user|>");
                out.push_str(&flint_text(&m.content));
            }
            "assistant" => {
                out.push_str("<|assistant|>");
                if let Some(raw) = &m.raw_assistant {
                    out.push_str(raw);
                    continue;
                }
                if let Some(reasoning) = &m.reasoning_content
                    && !reasoning.is_empty()
                {
                    out.push_str("<think>");
                    out.push_str(reasoning);
                    out.push_str("</think>");
                }
                if !m.content.is_empty() {
                    out.push_str(&m.content);
                }
                for tc in &m.tool_calls {
                    out.push_str("<tool_call>");
                    out.push_str(&tc.name);
                    for (k, v) in &tc.arguments {
                        out.push_str("<arg_key>");
                        out.push_str(k);
                        out.push_str("</arg_key><arg_value>");
                        if let Some(s) = v.as_str() {
                            out.push_str(s);
                        } else {
                            out.push_str(&serde_json::to_string(v).unwrap_or_default());
                        }
                        out.push_str("</arg_value>");
                    }
                    out.push_str("</tool_call>");
                }
            }
            "tool" => {
                out.push_str("<|observation|><tool_response>");
                out.push_str(&flint_text(&m.content));
                out.push_str("</tool_response>");
            }
            _ => {}
        }
    }
    if tools_pending {
        out.push_str(&tool_preamble);
    }
    if add_generation_prompt {
        out.push_str("<|assistant|>");
    }
    out
}

fn inkling_text(t: &str) -> String {
    let mut out = t.replace('\0', "");
    for tok in [
        "<|endoftext|>",
        "<|message_user|>",
        "<|message_model|>",
        "<|message_system|>",
        "<|message_tool|>",
        "<|content_text|>",
        "<|content_image|>",
        "<|content_model_end_sampling|>",
        "<|content_thinking|>",
        "<|end_message|>",
        "<|content_tool_error|>",
        "<|content_xml|>",
        "<|begin_of_text|>",
        "<|content_invoke_tool_json|>",
        "<|content_invoke_tool_text|>",
    ] {
        if let Some(inner) = tok.strip_prefix('<').and_then(|s| s.strip_suffix('>')) {
            out = out.replace(tok, &format!("&lt;{inner}&gt;"));
        }
    }
    out
}

fn canonical_json_value(value: &Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.iter().map(canonical_json_value).collect()),
        Value::Object(map) => {
            let sorted: BTreeMap<&String, Value> = map
                .iter()
                .map(|(k, v)| (k, canonical_json_value(v)))
                .collect();
            let mut out = Map::with_capacity(sorted.len());
            for (k, v) in sorted {
                out.insert(k.clone(), v);
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

fn to_compact_sorted_json(value: &Value) -> String {
    serde_json::to_string(&canonical_json_value(value)).unwrap_or_else(|_| "{}".into())
}

fn inkling_effort_number(effort: &str) -> &'static str {
    match effort.trim() {
        "none" => "0",
        "minimal" => "0.1",
        "low" => "0.2",
        "medium" => "0.7",
        "high" => "0.9",
        "xhigh" | "max" => "0.99",
        _ => "0.2",
    }
}

fn push_inkling_effort(out: &mut String, effort: &str) {
    out.push_str("<|message_system|><|content_text|>Thinking effort level: ");
    out.push_str(inkling_effort_number(effort));
    out.push_str("<|end_message|>");
}

/// Faithful port of Inkling 2 Mini's `chat_template.jinja`.
pub fn render_inkling_chat_template(
    messages: &[NormalizedMessage],
    tools: &[Value],
    reasoning_effort: &str,
) -> String {
    let mut out = String::new();
    if !tools.is_empty() {
        let mut specs = Vec::with_capacity(tools.len());
        for tool in tools {
            let func = tool.get("function").unwrap_or(tool);
            let spec = json!({
                "description": func.get("description").and_then(Value::as_str).unwrap_or(""),
                "name": func.get("name").and_then(Value::as_str).unwrap_or(""),
                "parameters": func.get("parameters").cloned().unwrap_or_else(|| json!({})),
                "type": tool.get("type").and_then(Value::as_str).unwrap_or("function"),
            });
            specs.push(canonical_json_value(&spec));
        }
        out.push_str("<|message_system|>tool_declare<|content_xml|>");
        out.push_str(&serde_json::to_string(&Value::Array(specs)).unwrap_or_else(|_| "[]".into()));
        out.push_str("<|end_message|>");
    }

    let mut call_names: HashMap<&str, &str> = HashMap::new();
    let mut effort_emitted = false;

    for m in messages {
        if !effort_emitted && !matches!(m.role.as_str(), "system" | "developer") {
            push_inkling_effort(&mut out, reasoning_effort);
            effort_emitted = true;
        }
        match m.role.as_str() {
            "system" | "developer" => {
                out.push_str("<|message_system|><|content_text|>");
                out.push_str(&inkling_text(&m.content));
                out.push_str("<|end_message|>");
            }
            "user" => {
                out.push_str("<|message_user|><|content_text|>");
                out.push_str(&inkling_text(&m.content));
                out.push_str("<|end_message|>");
            }
            "tool" => {
                out.push_str("<|message_tool|>");
                if let Some(id) = m.tool_call_id.as_deref()
                    && let Some(fn_name) = call_names.get(id)
                {
                    out.push_str(fn_name);
                }
                out.push_str("<|content_text|>");
                out.push_str(&inkling_text(&m.content));
                out.push_str("<|end_message|>");
            }
            "assistant" => {
                for tc in &m.tool_calls {
                    call_names.insert(tc.id.as_str(), tc.name.as_str());
                }
                if let Some(raw) = &m.raw_assistant {
                    out.push_str(raw);
                    continue;
                }
                if let Some(reasoning) = &m.reasoning_content
                    && !reasoning.is_empty()
                {
                    out.push_str("<|message_model|><|content_thinking|>");
                    out.push_str(reasoning);
                    out.push_str("<|end_message|>");
                }
                if !m.content.is_empty()
                    || (m.tool_calls.is_empty()
                        && m.reasoning_content.as_deref().unwrap_or("").is_empty())
                {
                    out.push_str("<|message_model|><|content_text|>");
                    out.push_str(&m.content);
                    out.push_str("<|end_message|>");
                }
                for tc in &m.tool_calls {
                    let args_json = to_compact_sorted_json(&Value::Object(tc.arguments.clone()));
                    let name_json =
                        serde_json::to_string(&tc.name).unwrap_or_else(|_| "\"\"".into());
                    out.push_str("<|message_model|>");
                    out.push_str(&tc.name);
                    out.push_str("<|content_invoke_tool_json|>{\"name\":");
                    out.push_str(&name_json);
                    out.push_str(",\"args\":");
                    out.push_str(&args_json);
                    out.push_str("}<|end_message|>");
                }
                out.push_str("<|content_model_end_sampling|>");
            }
            _ => {}
        }
    }
    if !effort_emitted {
        push_inkling_effort(&mut out, reasoning_effort);
    }
    out
}

fn find_next_marker(text: &str, from: usize) -> Option<(usize, usize, &str)> {
    const TAGS: [&str; 8] = [
        "<think>",
        "</think>",
        "<tool_call>",
        "</tool_call>",
        "<arg_key>",
        "</arg_key>",
        "<arg_value>",
        "</arg_value>",
    ];
    let slice = &text[from..];
    let mut best: Option<(usize, usize, &str)> = None;
    for tag in TAGS {
        if let Some(rel) = slice.find(tag) {
            let start = from + rel;
            let end = start + tag.len();
            if best.is_none_or(|(b_start, _, _)| start < b_start) {
                best = Some((start, end, tag));
            }
        }
    }
    best
}

fn schema_type_hints(schema: &Value) -> Vec<&str> {
    let Some(obj) = schema.as_object() else {
        return vec![];
    };
    if let Some(t) = obj.get("type") {
        if let Some(s) = t.as_str() {
            return vec![s];
        }
        if let Some(arr) = t.as_array() {
            return arr.iter().filter_map(Value::as_str).collect();
        }
    }
    let mut out = Vec::new();
    for kw in ["anyOf", "oneOf", "allOf"] {
        if let Some(branches) = obj.get(kw).and_then(Value::as_array) {
            for b in branches {
                out.extend(schema_type_hints(b));
            }
        }
    }
    out
}

fn matches_type(value: &Value, kind: &str) -> bool {
    match kind {
        "string" => value.is_string(),
        "integer" => value.is_i64() || value.is_u64(),
        "number" => value.is_number(),
        "boolean" => value.is_boolean(),
        "object" => value.is_object(),
        "array" => value.is_array(),
        "null" => value.is_null(),
        _ => true,
    }
}

fn coerce_argument(raw: &str, schema: &Value) -> Result<Value, AdapterError> {
    let hints = schema_type_hints(schema);
    if hints.len() == 1 && hints[0] == "string" {
        return Ok(Value::String(raw.to_string()));
    }
    if hints.is_empty() {
        if let Ok(parsed) = serde_json::from_str::<Value>(raw) {
            return Ok(parsed);
        }
        return Ok(Value::String(raw.to_string()));
    }
    let allows_string = hints.contains(&"string");
    let allows_non_string = hints.iter().any(|k| *k != "string");
    let mut candidates = Vec::new();
    if allows_non_string
        && let Ok(parsed) = serde_json::from_str::<Value>(raw)
        && hints.iter().any(|k| matches_type(&parsed, k))
    {
        candidates.push(parsed);
    }
    if allows_string {
        let s = Value::String(raw.to_string());
        if !candidates.contains(&s) {
            candidates.push(s);
        }
    }
    if candidates.len() == 1 {
        Ok(candidates.pop().unwrap())
    } else if candidates.is_empty() {
        Err(AdapterError::new(
            502,
            "tool argument does not match schema type",
        ))
    } else {
        // Prefer the typed non-string value if string was also allowed in a union
        // only when exact match; otherwise reject ambiguity like flint_tool_protocol.py.
        Err(AdapterError::new(
            502,
            "tool argument is ambiguous for its schema",
        ))
    }
}

fn parse_tool_call(
    body: &str,
    schemas: &HashMap<String, Value>,
    index: usize,
) -> Result<Value, AdapterError> {
    let first_tag = body.find('<');
    let name = match first_tag {
        Some(i) => body[..i].trim(),
        None => body.trim(),
    };
    let schema = schemas
        .get(name)
        .ok_or_else(|| AdapterError::new(502, format!("unknown function call: {name}")))?;
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let additional = schema
        .get("additionalProperties")
        .cloned()
        .unwrap_or(Value::Bool(true));

    let mut pos = first_tag.unwrap_or(body.len());
    let mut args = Map::new();
    while !body[pos..].trim().is_empty() {
        pos += body[pos..].len() - body[pos..].trim_start().len();
        if !body[pos..].starts_with("<arg_key>") {
            return Err(AdapterError::new(502, "expected <arg_key> in tool_call"));
        }
        let key_start = pos + "<arg_key>".len();
        let key_end_rel = body[key_start..]
            .find("</arg_key>")
            .ok_or_else(|| AdapterError::new(502, "unclosed <arg_key> in tool_call"))?;
        let key = &body[key_start..key_start + key_end_rel];
        if key.is_empty() || key.contains('<') || args.contains_key(key) {
            return Err(AdapterError::new(
                502,
                "empty, malformed, or duplicate argument key",
            ));
        }
        pos = key_start + key_end_rel + "</arg_key>".len();
        pos += body[pos..].len() - body[pos..].trim_start().len();
        if !body[pos..].starts_with("<arg_value>") {
            return Err(AdapterError::new(502, "expected <arg_value> in tool_call"));
        }
        let val_start = pos + "<arg_value>".len();
        let val_end_rel = body[val_start..]
            .find("</arg_value>")
            .ok_or_else(|| AdapterError::new(502, "unclosed <arg_value> in tool_call"))?;
        let raw_val = &body[val_start..val_start + val_end_rel];
        let arg_schema = properties.get(key).unwrap_or(&additional);
        if arg_schema == &Value::Bool(false) {
            return Err(AdapterError::new(
                502,
                format!("unexpected argument {key} for {name}"),
            ));
        }
        let coerced = coerce_argument(raw_val, arg_schema)?;
        args.insert(key.to_string(), coerced);
        pos = val_start + val_end_rel + "</arg_value>".len();
    }

    if let Some(required) = schema.get("required").and_then(Value::as_array) {
        for req in required {
            if let Some(req_key) = req.as_str()
                && !args.contains_key(req_key)
            {
                return Err(AdapterError::new(
                    502,
                    format!("missing required argument {req_key} for {name}"),
                ));
            }
        }
    }

    let serialized = serde_json::to_string(&Value::Object(args))
        .map_err(|e| AdapterError::new(502, format!("could not encode tool arguments: {e}")))?;
    Ok(json!({
        "id": format!("call_{index}"),
        "type": "function",
        "function": {
            "name": name,
            "arguments": serialized,
        }
    }))
}

fn validate_json_tool_args(
    name: &str,
    raw_args: &Map<String, Value>,
    schemas: &HashMap<String, Value>,
    index: usize,
) -> Result<Value, AdapterError> {
    let schema = schemas
        .get(name)
        .ok_or_else(|| AdapterError::new(502, format!("unknown function call: {name}")))?;
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let additional = schema
        .get("additionalProperties")
        .cloned()
        .unwrap_or(Value::Bool(true));

    for (key, val) in raw_args {
        let arg_schema = properties.get(key).unwrap_or(&additional);
        if arg_schema == &Value::Bool(false) {
            return Err(AdapterError::new(
                502,
                format!("unexpected argument {key} for {name}"),
            ));
        }
        let hints = schema_type_hints(arg_schema);
        if !hints.is_empty() && !hints.iter().any(|k| matches_type(val, k)) {
            return Err(AdapterError::new(
                502,
                format!("tool argument {key} does not match schema type"),
            ));
        }
    }

    if let Some(required) = schema.get("required").and_then(Value::as_array) {
        for req in required {
            if let Some(req_key) = req.as_str()
                && !raw_args.contains_key(req_key)
            {
                return Err(AdapterError::new(
                    502,
                    format!("missing required argument {req_key} for {name}"),
                ));
            }
        }
    }

    let serialized = serde_json::to_string(&Value::Object(raw_args.clone()))
        .map_err(|e| AdapterError::new(502, format!("could not encode tool arguments: {e}")))?;
    Ok(json!({
        "id": format!("call_{index}"),
        "type": "function",
        "function": {
            "name": name,
            "arguments": serialized,
        }
    }))
}

fn tool_schemas_map(tools: &[Value]) -> HashMap<String, Value> {
    let mut schemas = HashMap::new();
    for tool in tools {
        let Some(func) = tool.get("function").and_then(Value::as_object) else {
            continue;
        };
        if let Some(name) = func.get("name").and_then(Value::as_str) {
            let params = func
                .get("parameters")
                .cloned()
                .unwrap_or_else(|| json!({"type": "object"}));
            schemas.insert(name.to_string(), params);
        }
    }
    schemas
}

/// Port of `tools/inkling_tool_protocol.parse_completion`.
pub fn parse_inkling_completion(
    text: &str,
    tools: &[Value],
    stopped: bool,
) -> Result<ParsedCompletion, AdapterError> {
    const MESSAGE: &str = "<|message_model|>";
    const END: &str = "<|end_message|>";
    const THINKING: &str = "<|content_thinking|>";
    const TEXT: &str = "<|content_text|>";
    const INVOKE: &str = "<|content_invoke_tool_json|>";
    const SAMPLING_END: &str = "<|content_model_end_sampling|>";

    let cleaned = text.replace(SAMPLING_END, "");
    if !stopped {
        return Ok(ParsedCompletion {
            content: cleaned,
            reasoning_content: String::new(),
            tool_calls: Vec::new(),
            finish_reason: "length",
        });
    }

    let schemas = tool_schemas_map(tools);
    let mut visible = String::new();
    let mut reasoning = String::new();
    let mut calls = Vec::new();
    let mut had_invalid = false;

    for part in cleaned.split(MESSAGE) {
        if part.trim().is_empty() {
            continue;
        }
        let Some(body) = part.strip_suffix(END) else {
            had_invalid = true;
            visible.push_str(part);
            continue;
        };
        if let Some(thought) = body.strip_prefix(THINKING) {
            reasoning.push_str(thought);
        } else if let Some(msg) = body.strip_prefix(TEXT) {
            visible.push_str(msg);
        } else if let Some((name, raw)) = body.split_once(INVOKE) {
            let parsed_call = serde_json::from_str::<Value>(raw)
                .ok()
                .and_then(|v| v.as_object().cloned())
                .filter(|obj| {
                    obj.len() == 2
                        && obj.get("name").and_then(Value::as_str) == Some(name)
                        && obj.get("args").is_some_and(Value::is_object)
                })
                .and_then(|obj| {
                    obj.get("args").and_then(Value::as_object).and_then(|args| {
                        validate_json_tool_args(name, args, &schemas, calls.len()).ok()
                    })
                });
            if let Some(call) = parsed_call {
                calls.push(call);
            } else {
                had_invalid = true;
                visible.push_str(body);
            }
        } else {
            had_invalid = true;
            visible.push_str(body);
        }
    }

    if had_invalid {
        calls.clear();
    }
    let finish_reason = if calls.is_empty() {
        "stop"
    } else {
        "tool_calls"
    };
    Ok(ParsedCompletion {
        content: visible,
        reasoning_content: reasoning,
        tool_calls: calls,
        finish_reason,
    })
}

/// Port of `flint_tool_protocol.parse_completion`.
pub fn parse_completion(
    text: &str,
    tools: &[Value],
    stopped: bool,
) -> Result<ParsedCompletion, AdapterError> {
    let mut visible = String::new();
    let mut reasoning = String::new();
    let mut untrusted = String::new();
    let mut bodies: Vec<&str> = Vec::new();
    let mut incomplete_thinking = false;
    let mut malformed = false;
    let mut pos = 0;

    while pos < text.len() {
        let Some((m_start, m_end, tag)) = find_next_marker(text, pos) else {
            visible.push_str(&text[pos..]);
            untrusted.push_str(&text[pos..]);
            break;
        };
        visible.push_str(&text[pos..m_start]);
        untrusted.push_str(&text[pos..m_start]);
        match tag {
            "<think>" => {
                if let Some(end_rel) = text[m_end..].find("</think>") {
                    let thought = &text[m_end..m_end + end_rel];
                    if thought.contains("<think>") {
                        malformed = true;
                    }
                    reasoning.push_str(thought);
                    pos = m_end + end_rel + "</think>".len();
                } else {
                    reasoning.push_str(&text[m_end..]);
                    incomplete_thinking = true;
                    break;
                }
            }
            "<tool_call>" => {
                if let Some(end_rel) = text[m_end..].find("</tool_call>") {
                    let body = &text[m_end..m_end + end_rel];
                    bodies.push(body);
                    let close_end = m_end + end_rel + "</tool_call>".len();
                    untrusted.push_str(&text[m_start..close_end]);
                    pos = close_end;
                } else {
                    malformed = true;
                    untrusted.push_str(&text[m_start..]);
                    break;
                }
            }
            _ => {
                malformed = true;
                untrusted.push_str(tag);
                pos = m_end;
            }
        }
    }

    if !stopped || incomplete_thinking {
        return Ok(ParsedCompletion {
            content: untrusted,
            reasoning_content: reasoning,
            tool_calls: Vec::new(),
            finish_reason: "length",
        });
    }
    if malformed {
        return Err(AdapterError::new(
            502,
            "malformed tool or thinking delimiters",
        ));
    }

    let mut schemas = HashMap::new();
    for tool in tools {
        let Some(func) = tool.get("function").and_then(Value::as_object) else {
            continue;
        };
        if let Some(name) = func.get("name").and_then(Value::as_str) {
            let params = func
                .get("parameters")
                .cloned()
                .unwrap_or_else(|| json!({"type": "object"}));
            schemas.insert(name.to_string(), params);
        }
    }

    let mut calls = Vec::with_capacity(bodies.len());
    for (idx, body) in bodies.iter().enumerate() {
        calls.push(parse_tool_call(body, &schemas, idx)?);
    }
    let finish_reason = if calls.is_empty() {
        "stop"
    } else {
        "tool_calls"
    };
    Ok(ParsedCompletion {
        content: visible,
        reasoning_content: reasoning,
        tool_calls: calls,
        finish_reason,
    })
}

fn content_text(value: Option<&Value>) -> Result<String, AdapterError> {
    match value {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(s)) => Ok(s.clone()),
        Some(Value::Array(items)) => {
            let mut parts = Vec::with_capacity(items.len());
            for item in items {
                let Some(obj) = item.as_object() else {
                    return Err(AdapterError::bad_request(
                        "only text message content is supported",
                    ));
                };
                if obj.get("type").and_then(Value::as_str) != Some("text") {
                    return Err(AdapterError::bad_request(
                        "only text message content is supported",
                    ));
                }
                let Some(text) = obj.get("text").and_then(Value::as_str) else {
                    return Err(AdapterError::bad_request(
                        "only text message content is supported",
                    ));
                };
                parts.push(text);
            }
            Ok(parts.join("\n"))
        }
        _ => Err(AdapterError::bad_request(
            "only text message content is supported",
        )),
    }
}

pub fn normalize_messages(raw: Option<&Value>) -> Result<Vec<NormalizedMessage>, AdapterError> {
    let Some(items) = raw.and_then(Value::as_array) else {
        return Err(AdapterError::bad_request(
            "messages must be a nonempty bounded array",
        ));
    };
    if items.is_empty() || items.len() > 4096 {
        return Err(AdapterError::bad_request(
            "messages must be a nonempty bounded array",
        ));
    }
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let Some(obj) = item.as_object() else {
            return Err(AdapterError::bad_request("unsupported message role"));
        };
        let Some(role) = obj.get("role").and_then(Value::as_str) else {
            return Err(AdapterError::bad_request("unsupported message role"));
        };
        if !matches!(role, "system" | "developer" | "user" | "assistant" | "tool") {
            return Err(AdapterError::bad_request("unsupported message role"));
        }
        let content = content_text(obj.get("content"))?;
        let reasoning_content = match obj.get("reasoning_content") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) => Some(s.clone()),
            _ => {
                return Err(AdapterError::bad_request("reasoning_content must be text"));
            }
        };
        let mut tool_calls = Vec::new();
        if let Some(raw_calls) = obj.get("tool_calls").filter(|v| !v.is_null()) {
            if role != "assistant" {
                return Err(AdapterError::bad_request(
                    "tool_calls require an assistant message",
                ));
            }
            let Some(arr) = raw_calls.as_array() else {
                return Err(AdapterError::bad_request("invalid tool_calls array"));
            };
            for call in arr {
                let Some(co) = call.as_object() else {
                    return Err(AdapterError::bad_request("unsupported tool call"));
                };
                if co.get("type").and_then(Value::as_str) != Some("function") {
                    return Err(AdapterError::bad_request("unsupported tool call"));
                }
                let Some(id) = co.get("id").and_then(Value::as_str) else {
                    return Err(AdapterError::bad_request("invalid function call history"));
                };
                let Some(fo) = co.get("function").and_then(Value::as_object) else {
                    return Err(AdapterError::bad_request("unsupported tool call"));
                };
                let Some(name) = fo.get("name").and_then(Value::as_str) else {
                    return Err(AdapterError::bad_request("invalid function call history"));
                };
                let arguments = match fo.get("arguments") {
                    None | Some(Value::Null) => Map::new(),
                    Some(Value::Object(m)) => m.clone(),
                    Some(Value::String(s)) => match serde_json::from_str::<Value>(s) {
                        Ok(Value::Object(m)) => m,
                        _ => {
                            return Err(AdapterError::bad_request(
                                "tool arguments must be a JSON object",
                            ));
                        }
                    },
                    _ => {
                        return Err(AdapterError::bad_request(
                            "tool arguments must be a JSON object",
                        ));
                    }
                };
                tool_calls.push(NormalizedToolCall {
                    id: id.to_string(),
                    name: name.to_string(),
                    arguments,
                });
            }
        }
        let tool_call_id = if role == "tool" {
            let Some(id) = obj.get("tool_call_id").and_then(Value::as_str) else {
                return Err(AdapterError::bad_request(
                    "tool observations require tool_call_id",
                ));
            };
            Some(id.to_string())
        } else {
            None
        };
        out.push(NormalizedMessage {
            role: role.to_string(),
            content,
            reasoning_content,
            tool_calls,
            tool_call_id,
            raw_assistant: None,
        });
    }
    if !matches!(out.last().map(|m| m.role.as_str()), Some("user" | "tool")) {
        return Err(AdapterError::bad_request(
            "last message must be a user message or tool observation",
        ));
    }
    Ok(out)
}

#[derive(Debug, Clone)]
pub struct ValidatedRequest {
    pub messages: Vec<NormalizedMessage>,
    pub tools: Vec<Value>,
    pub budget: u32,
    pub stream: bool,
    pub include_usage: bool,
    pub require_tool: bool,
    pub parallel_tool_calls: bool,
    pub reasoning_effort: Option<String>,
}

pub fn validate_request(
    payload: &Value,
    max_output: u32,
) -> Result<ValidatedRequest, AdapterError> {
    validate_request_for_model(payload, max_output, NativeModelKind::Flint)
}

pub fn validate_request_for_model(
    payload: &Value,
    max_output: u32,
    kind: NativeModelKind,
) -> Result<ValidatedRequest, AdapterError> {
    let Some(obj) = payload.as_object() else {
        return Err(AdapterError::bad_request("request body must be an object"));
    };
    let model = obj
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or(match kind {
            NativeModelKind::Flint => MODEL_ID,
            NativeModelKind::Inkling => INKLING_MODEL_ID,
        });
    match kind {
        NativeModelKind::Flint => {
            if model != MODEL_ID {
                return Err(AdapterError::bad_request("unknown model; use flint"));
            }
        }
        NativeModelKind::Inkling => {
            if model != INKLING_MODEL_ID && model != MODEL_ID {
                return Err(AdapterError::bad_request(
                    "unknown model; use inkling-2-mini or flint",
                ));
            }
        }
    }
    let reasoning_effort = match obj.get("reasoning_effort") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            if !matches!(
                trimmed,
                "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max"
            ) {
                return Err(AdapterError::bad_request(
                    "unsupported reasoning_effort for local model",
                ));
            }
            Some(trimmed.to_string())
        }
        _ => return Err(AdapterError::bad_request("reasoning_effort must be text")),
    };
    if let Some(n) = obj.get("n")
        && n.as_u64() != Some(1)
    {
        return Err(AdapterError::bad_request("only n=1 is supported"));
    }
    let stream = match obj.get("stream") {
        None => false,
        Some(Value::Bool(b)) => *b,
        _ => return Err(AdapterError::bad_request("stream must be boolean")),
    };
    let include_usage = match obj.get("stream_options") {
        None | Some(Value::Null) => false,
        Some(Value::Object(so)) => match so.get("include_usage") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(b)) => *b,
            _ => return Err(AdapterError::bad_request("invalid stream_options")),
        },
        _ => return Err(AdapterError::bad_request("invalid stream_options")),
    };
    let parallel_tool_calls = match obj.get("parallel_tool_calls") {
        None | Some(Value::Null) => true,
        Some(Value::Bool(b)) => *b,
        _ => {
            return Err(AdapterError::bad_request(
                "parallel_tool_calls must be boolean",
            ));
        }
    };
    for (name, default) in [
        ("temperature", 0.0_f64),
        ("top_p", 1.0_f64),
        ("presence_penalty", 0.0_f64),
        ("frequency_penalty", 0.0_f64),
    ] {
        if let Some(v) = obj.get(name).filter(|v| !v.is_null()) {
            let Some(f) = v.as_f64() else {
                return Err(AdapterError::bad_request(format!(
                    "native greedy inference requires {name}={default}"
                )));
            };
            if !f.is_finite() || (f - default).abs() > f64::EPSILON {
                return Err(AdapterError::bad_request(format!(
                    "native greedy inference requires {name}={default}"
                )));
            }
        }
    }
    let max_completion = obj
        .get("max_completion_tokens")
        .filter(|v| !v.is_null())
        .map(|v| {
            v.as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .filter(|&n| n > 0)
                .ok_or_else(|| {
                    AdapterError::bad_request("max_completion_tokens must be a positive u32")
                })
        })
        .transpose()?;
    let max_tokens = obj
        .get("max_tokens")
        .filter(|v| !v.is_null())
        .map(|v| {
            v.as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .filter(|&n| n > 0)
                .ok_or_else(|| AdapterError::bad_request("max_tokens must be a positive u32"))
        })
        .transpose()?;
    if let (Some(a), Some(b)) = (max_completion, max_tokens)
        && a != b
    {
        return Err(AdapterError::bad_request("conflicting token budgets"));
    }
    let budget = max_completion
        .or(max_tokens)
        .unwrap_or(max_output)
        .min(max_output);

    let mut tools = Vec::new();
    if let Some(raw_tools) = obj.get("tools").filter(|v| !v.is_null()) {
        let Some(arr) = raw_tools.as_array() else {
            return Err(AdapterError::bad_request("tools must be a bounded array"));
        };
        if arr.len() > 256 {
            return Err(AdapterError::bad_request("tools must be a bounded array"));
        }
        let mut seen = HashSet::new();
        for tool in arr {
            let Some(to) = tool.as_object() else {
                return Err(AdapterError::bad_request(
                    "only function tools are supported",
                ));
            };
            if to.get("type").and_then(Value::as_str) != Some("function") {
                return Err(AdapterError::bad_request(
                    "only function tools are supported",
                ));
            }
            let Some(fo) = to.get("function").and_then(Value::as_object) else {
                return Err(AdapterError::bad_request("invalid function schema"));
            };
            let Some(name) = fo.get("name").and_then(Value::as_str) else {
                return Err(AdapterError::bad_request("invalid function schema"));
            };
            if !seen.insert(name.to_string()) {
                return Err(AdapterError::bad_request("duplicate function names"));
            }
            tools.push(tool.clone());
        }
    }

    let mut require_tool = false;
    match obj.get("tool_choice") {
        None | Some(Value::Null) => {}
        Some(Value::String(s)) if s == "auto" => {}
        Some(Value::String(s)) if s == "none" => tools.clear(),
        Some(Value::String(s)) if s == "required" => {
            if tools.is_empty() {
                return Err(AdapterError::bad_request(
                    "required tool_choice has no tools",
                ));
            }
            require_tool = true;
        }
        Some(Value::Object(co)) => {
            let wanted = co
                .get("function")
                .and_then(|f| f.get("name"))
                .and_then(Value::as_str);
            if co.get("type").and_then(Value::as_str) != Some("function") || wanted.is_none() {
                return Err(AdapterError::bad_request("unsupported tool_choice"));
            }
            let wanted = wanted.unwrap();
            tools.retain(|t| {
                t.get("function")
                    .and_then(|f| f.get("name"))
                    .and_then(Value::as_str)
                    == Some(wanted)
            });
            if tools.len() != 1 {
                return Err(AdapterError::bad_request(
                    "forced function is not available",
                ));
            }
        }
        _ => return Err(AdapterError::bad_request("unsupported tool_choice")),
    }

    let messages = normalize_messages(obj.get("messages"))?;
    Ok(ValidatedRequest {
        messages,
        tools,
        budget,
        stream,
        include_usage,
        require_tool,
        parallel_tool_calls,
        reasoning_effort,
    })
}

fn fingerprint_messages(messages: &[NormalizedMessage]) -> String {
    let mut hasher = Sha256::new();
    for m in messages {
        hasher.update(m.role.as_bytes());
        hasher.update(b"\x1f");
        hasher.update(m.content.as_bytes());
        hasher.update(b"\x1f");
        if let Some(id) = &m.tool_call_id {
            hasher.update(id.as_bytes());
        }
        hasher.update(b"\x1f");
        for tc in &m.tool_calls {
            hasher.update(tc.id.as_bytes());
            hasher.update(b":");
            hasher.update(tc.name.as_bytes());
            hasher.update(b":");
            hasher.update(
                serde_json::to_string(&Value::Object(tc.arguments.clone()))
                    .unwrap_or_default()
                    .as_bytes(),
            );
            hasher.update(b";");
        }
        hasher.update(b"\x1e");
    }
    hex_bytes(&hasher.finalize())
}

fn hex_bytes(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0xf) as usize] as char);
    }
    s
}

fn assistant_signature(m: &NormalizedMessage) -> String {
    let mut clone = m.clone();
    clone.reasoning_content = None;
    clone.raw_assistant = None;
    fingerprint_messages(&[clone])
}

struct AssistantRecord {
    index: usize,
    prefix_hash: String,
    signature: String,
    raw: String,
    reasoning: String,
}

pub struct FlintBackend<T: FlintTokenizer, W: FlintWorker> {
    tokenizer: T,
    worker_factory: Box<dyn Fn() -> Result<W, String> + Send>,
    worker: Option<W>,
    model_kind: NativeModelKind,
    context: u32,
    eos: HashSet<u32>,
    vocab_size: usize,
    cached_ids: Vec<u32>,
    records: Vec<AssistantRecord>,
    needs_reset: bool,
    sequence: u64,
}

impl<T: FlintTokenizer, W: FlintWorker> FlintBackend<T, W> {
    pub fn new(
        tokenizer: T,
        worker_factory: Box<dyn Fn() -> Result<W, String> + Send>,
        context: u32,
        eos_ids: Vec<u32>,
        vocab_size: usize,
    ) -> Self {
        Self::new_for_model(
            tokenizer,
            worker_factory,
            NativeModelKind::Flint,
            context,
            eos_ids,
            vocab_size,
        )
    }

    pub fn new_for_model(
        tokenizer: T,
        worker_factory: Box<dyn Fn() -> Result<W, String> + Send>,
        model_kind: NativeModelKind,
        context: u32,
        eos_ids: Vec<u32>,
        vocab_size: usize,
    ) -> Self {
        Self {
            tokenizer,
            worker_factory,
            worker: None,
            model_kind,
            context,
            eos: eos_ids.into_iter().collect(),
            vocab_size,
            cached_ids: Vec::new(),
            records: Vec::new(),
            needs_reset: true,
            sequence: 0,
        }
    }

    pub fn model_kind(&self) -> NativeModelKind {
        self.model_kind
    }

    pub fn model_id(&self) -> &'static str {
        self.model_kind.model_id()
    }

    pub fn context(&self) -> u32 {
        self.context
    }

    pub fn abort(&mut self) {
        self.needs_reset = true;
        self.cached_ids.clear();
        if let Some(mut worker) = self.worker.take() {
            worker.close(false);
        }
    }

    pub fn close(&mut self) {
        self.needs_reset = true;
        self.cached_ids.clear();
        if let Some(mut worker) = self.worker.take() {
            worker.close(true);
        }
    }

    pub fn complete(&mut self, req: &ValidatedRequest) -> Result<Value, AdapterError> {
        let mut rendered_messages = req.messages.clone();
        for rec in &self.records {
            if rec.index >= req.messages.len() {
                continue;
            }
            if fingerprint_messages(&req.messages[..rec.index]) != rec.prefix_hash {
                continue;
            }
            let current = &req.messages[rec.index];
            if assistant_signature(current) != rec.signature {
                continue;
            }
            if let Some(r) = &current.reasoning_content
                && r != &rec.reasoning
            {
                continue;
            }
            rendered_messages[rec.index].raw_assistant = Some(rec.raw.clone());
        }

        let prompt_text = match self.model_kind {
            NativeModelKind::Flint => render_chat_template(&rendered_messages, &req.tools, true),
            NativeModelKind::Inkling => render_inkling_chat_template(
                &rendered_messages,
                &req.tools,
                req.reasoning_effort
                    .as_deref()
                    .unwrap_or(DEFAULT_INKLING_EFFORT),
            ),
        };
        let ids = self
            .tokenizer
            .encode(&prompt_text)
            .map_err(|e| AdapterError::new(500, format!("tokenization failed: {e}")))?;
        if ids.is_empty() || ids.iter().any(|&id| (id as usize) >= self.vocab_size) {
            return Err(AdapterError::new(500, "invalid template token IDs"));
        }
        if ids.len() + (req.budget as usize) > (self.context as usize) {
            return Err(AdapterError::bad_request(
                "prompt plus reserved committed output exceeds context",
            ));
        }

        let hit = !self.needs_reset
            && ids.len() >= self.cached_ids.len()
            && ids[..self.cached_ids.len()] == self.cached_ids[..];
        let reused = if hit { self.cached_ids.len() } else { 0 };
        let suffix = &ids[reused..];
        if suffix.is_empty() {
            return Err(AdapterError::bad_request(
                "request has no new template suffix",
            ));
        }
        let reset = !hit;

        let exec_result = self.execute_chunks(&ids, suffix, reused, reset, req);
        if exec_result.is_err() {
            self.abort();
        }
        exec_result
    }

    fn execute_chunks(
        &mut self,
        ids: &[u32],
        suffix: &[u32],
        reused: usize,
        reset: bool,
        req: &ValidatedRequest,
    ) -> Result<Value, AdapterError> {
        if self.worker.is_none() {
            let w = (self.worker_factory)()
                .map_err(|e| AdapterError::new(502, format!("failed to launch flint: {e}")))?;
            self.worker = Some(w);
        }

        let mut prefill_seconds = 0.0_f64;
        let mut decode_seconds = 0.0_f64;
        let mut before = reused as u32;
        let mut final_resp: Option<WorkerResponse> = None;

        for (chunk_idx, chunk) in suffix.chunks(NATIVE_CHUNK).enumerate() {
            let is_final = (chunk_idx + 1) * NATIVE_CHUNK >= suffix.len();
            self.sequence += 1;
            let wreq = WorkerRequest {
                id: self.sequence,
                tokens: chunk.to_vec(),
                max_tokens: if is_final { req.budget } else { 0 },
                reset: reset && chunk_idx == 0,
                return_logits: false,
            };
            let resp = self
                .worker
                .as_mut()
                .unwrap()
                .request(&wreq)
                .map_err(|e| AdapterError::new(502, format!("flint session error: {e}")))?;

            if resp.id != wreq.id
                || resp.tokens.len() > wreq.max_tokens as usize
                || resp.tokens.iter().any(|&t| (t as usize) >= self.vocab_size)
            {
                return Err(AdapterError::new(502, "invalid native token response"));
            }
            let expected_after = before + (wreq.tokens.len() as u32) + (resp.tokens.len() as u32);
            if resp.cache_before != before
                || resp.cache_after != expected_after
                || resp.prefill_tokens != wreq.tokens.len()
                || resp.decode_forward_tokens != resp.tokens.len()
                || resp.reused_prefix_tokens != before
                || resp.cache_after > self.context
            {
                return Err(AdapterError::new(502, "native cache accounting mismatch"));
            }
            let ended_with_eos = resp
                .tokens
                .last()
                .is_some_and(|last| self.eos.contains(last));
            if resp.eos != ended_with_eos {
                return Err(AdapterError::new(502, "native EOS accounting mismatch"));
            }
            if resp
                .tokens
                .len()
                .checked_sub(1)
                .is_some_and(|n| resp.tokens[..n].iter().any(|t| self.eos.contains(t)))
            {
                return Err(AdapterError::new(502, "native generated after EOS"));
            }
            before = resp.cache_after;
            prefill_seconds += resp.prefill_seconds;
            decode_seconds += resp.decode_seconds;
            final_resp = Some(resp);
        }

        let resp = final_resp.ok_or_else(|| AdapterError::new(502, "no worker response"))?;
        let generated = resp.tokens.clone();
        self.cached_ids = ids.to_vec();
        self.cached_ids.extend_from_slice(&generated);
        self.needs_reset = false;

        let raw = self
            .tokenizer
            .decode(&generated)
            .map_err(|e| AdapterError::new(502, format!("decode failed: {e}")))?;
        let visible_ids = if generated.last().is_some_and(|t| self.eos.contains(t)) {
            &generated[..generated.len() - 1]
        } else {
            &generated[..]
        };
        let text = self
            .tokenizer
            .decode(visible_ids)
            .map_err(|e| AdapterError::new(502, format!("decode failed: {e}")))?;

        let mut parsed = match self.model_kind {
            NativeModelKind::Flint => parse_completion(&text, &req.tools, resp.eos)?,
            NativeModelKind::Inkling => parse_inkling_completion(&raw, &req.tools, resp.eos)?,
        };
        if resp.eos && req.require_tool && parsed.tool_calls.is_empty() {
            return Err(AdapterError::new(
                502,
                "model did not produce the required function call",
            ));
        }
        if !req.parallel_tool_calls && parsed.tool_calls.len() > 1 {
            return Err(AdapterError::new(
                502,
                "model produced multiple calls when disabled",
            ));
        }

        let req_uuid = uuid::Uuid::new_v4().simple().to_string();
        let request_id = format!("chatcmpl-{req_uuid}");
        for (idx, call) in parsed.tool_calls.iter_mut().enumerate() {
            if let Some(obj) = call.as_object_mut() {
                obj.insert("id".into(), Value::String(format!("call_{req_uuid}_{idx}")));
            }
        }

        let mut message = Map::new();
        message.insert("role".into(), Value::String("assistant".into()));
        message.insert("content".into(), Value::String(parsed.content.clone()));
        if !parsed.reasoning_content.is_empty() {
            message.insert(
                "reasoning_content".into(),
                Value::String(parsed.reasoning_content.clone()),
            );
        }
        if !parsed.tool_calls.is_empty() {
            message.insert("tool_calls".into(), Value::Array(parsed.tool_calls.clone()));
        }

        if let Ok(re_encoded) = self.tokenizer.encode(&raw)
            && re_encoded == generated
        {
            let mut norm_calls = Vec::new();
            for call in &parsed.tool_calls {
                if let (Some(id), Some(name), Some(args_str)) = (
                    call.get("id").and_then(Value::as_str),
                    call.get("function")
                        .and_then(|f| f.get("name"))
                        .and_then(Value::as_str),
                    call.get("function")
                        .and_then(|f| f.get("arguments"))
                        .and_then(Value::as_str),
                ) && let Ok(Value::Object(args_map)) = serde_json::from_str::<Value>(args_str)
                {
                    norm_calls.push(NormalizedToolCall {
                        id: id.to_string(),
                        name: name.to_string(),
                        arguments: args_map,
                    });
                }
            }
            let asst = NormalizedMessage {
                role: "assistant".into(),
                content: parsed.content.clone(),
                reasoning_content: (!parsed.reasoning_content.is_empty())
                    .then_some(parsed.reasoning_content.clone()),
                tool_calls: norm_calls,
                tool_call_id: None,
                raw_assistant: None,
            };
            self.records.push(AssistantRecord {
                index: req.messages.len(),
                prefix_hash: fingerprint_messages(&req.messages),
                signature: assistant_signature(&asst),
                raw,
                reasoning: parsed.reasoning_content,
            });
            if self.records.len() > 256 {
                let excess = self.records.len() - 256;
                self.records.drain(..excess);
            }
        }

        let created = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        Ok(json!({
            "id": request_id,
            "object": "chat.completion",
            "created": created,
            "model": self.model_id(),
            "choices": [{
                "index": 0,
                "message": Value::Object(message),
                "finish_reason": parsed.finish_reason,
            }],
            "usage": {
                "prompt_tokens": ids.len(),
                "completion_tokens": generated.len(),
                "total_tokens": ids.len() + generated.len(),
                "prompt_tokens_details": {
                    "cached_tokens": reused,
                }
            },
            "nanoattention": {
                "cache_reset": reset,
                "reused_prefix_tokens": reused,
                "new_prefill_tokens": suffix.len(),
                "cache_after": resp.cache_after,
                "prefill_seconds": prefill_seconds,
                "decode_seconds": decode_seconds,
                "kv_allocated_bytes": resp.kv_allocated_bytes,
                "kv_valid_bytes": resp.kv_valid_bytes,
                "kv_storage": resp.kv_storage,
                "effective_max_tokens": req.budget,
                "sampling": "greedy",
            }
        }))
    }
}

pub fn sse_events(result: &Value, include_usage: bool) -> Vec<Value> {
    let id = result.get("id").cloned().unwrap_or(Value::Null);
    let created = result.get("created").cloned().unwrap_or(json!(0));
    let model = result
        .get("model")
        .cloned()
        .unwrap_or_else(|| Value::String(MODEL_ID.into()));
    let chunk = |delta: Value, finish: Value| {
        json!({
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [{
                "index": 0,
                "delta": delta,
                "finish_reason": finish,
            }]
        })
    };

    let mut out = vec![chunk(json!({"role": "assistant"}), Value::Null)];
    if let Some(choice) = result
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
    {
        if let Some(msg) = choice.get("message").and_then(Value::as_object) {
            for field in ["reasoning_content", "content"] {
                if let Some(text) = msg.get(field).and_then(Value::as_str)
                    && !text.is_empty()
                {
                    let chars: Vec<char> = text.chars().collect();
                    for piece in chars.chunks(4096) {
                        let s: String = piece.iter().collect();
                        out.push(chunk(json!({ field: s }), Value::Null));
                    }
                }
            }
            if let Some(calls) = msg.get("tool_calls").and_then(Value::as_array) {
                for (index, call) in calls.iter().enumerate() {
                    let mut c = call.clone();
                    if let Some(obj) = c.as_object_mut() {
                        obj.insert("index".into(), json!(index));
                    }
                    out.push(chunk(json!({"tool_calls": [c]}), Value::Null));
                }
            }
        }
        let finish = choice.get("finish_reason").cloned().unwrap_or(Value::Null);
        out.push(chunk(json!({}), finish));
    }
    if include_usage {
        out.push(json!({
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [],
            "usage": result.get("usage").cloned().unwrap_or(Value::Null),
            "nanoattention": result.get("nanoattention").cloned().unwrap_or(Value::Null),
        }));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_template_matches_flint_format_with_tools_and_sanitization() {
        let msgs = vec![
            NormalizedMessage {
                role: "system".into(),
                content: "Be concise <|user|>".into(),
                reasoning_content: None,
                tool_calls: vec![],
                tool_call_id: None,
                raw_assistant: None,
            },
            NormalizedMessage {
                role: "user".into(),
                content: "Check <think>now</think>".into(),
                reasoning_content: None,
                tool_calls: vec![],
                tool_call_id: None,
                raw_assistant: None,
            },
        ];
        let tools = vec![json!({
            "type": "function",
            "function": {
                "name": "read_file",
                "parameters": {"type": "object", "properties": {"path": {"type": "string"}}}
            }
        })];
        let rendered = render_chat_template(&msgs, &tools, true);
        assert!(rendered.starts_with("<|system|>Be concise &lt;|user|&gt;<|system|>\n# Tools"));
        assert!(rendered.contains("<tools>\n{\"name\":\"read_file\""));
        assert!(rendered.contains("<|user|>Check now<|assistant|>"));
    }

    #[test]
    fn parse_completion_extracts_thinking_and_typed_tool_calls() {
        let tools = vec![json!({
            "type": "function",
            "function": {
                "name": "search",
                "parameters": {
                    "type": "object",
                    "required": ["query", "limit"],
                    "properties": {
                        "query": {"type": "string"},
                        "limit": {"type": "integer"}
                    }
                }
            }
        })];
        let raw = "<think>checking</think>Running search.<tool_call>search<arg_key>query</arg_key><arg_value>flint</arg_value><arg_key>limit</arg_key><arg_value>5</arg_value></tool_call>";
        let parsed = parse_completion(raw, &tools, true).unwrap();
        assert_eq!(parsed.reasoning_content, "checking");
        assert_eq!(parsed.content, "Running search.");
        assert_eq!(parsed.finish_reason, "tool_calls");
        assert_eq!(parsed.tool_calls.len(), 1);
        let args: Value = serde_json::from_str(
            parsed.tool_calls[0]["function"]["arguments"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(args, json!({"query": "flint", "limit": 5}));

        // Unclosed <think> or length stop never emits executable tool calls.
        let truncated = parse_completion(raw, &tools, false).unwrap();
        assert_eq!(truncated.finish_reason, "length");
        assert!(truncated.tool_calls.is_empty());
    }

    struct ByteTokenizer;
    impl FlintTokenizer for ByteTokenizer {
        fn encode(&self, text: &str) -> Result<Vec<u32>, String> {
            let mut out = Vec::new();
            let mut rest = text;
            while !rest.is_empty() {
                if let Some(after) = rest.strip_prefix("<|end_of_text|>") {
                    out.push(255);
                    rest = after;
                } else {
                    let b = rest.as_bytes()[0];
                    out.push(b as u32);
                    rest = &rest[1..];
                }
            }
            Ok(out)
        }
        fn decode(&self, ids: &[u32]) -> Result<String, String> {
            let mut out = String::new();
            let mut buf = Vec::new();
            for &id in ids {
                if id == 255 {
                    out.push_str(
                        &String::from_utf8(std::mem::take(&mut buf)).map_err(|e| e.to_string())?,
                    );
                    out.push_str("<|end_of_text|>");
                } else {
                    buf.push(id as u8);
                }
            }
            out.push_str(&String::from_utf8(buf).map_err(|e| e.to_string())?);
            Ok(out)
        }
    }

    struct MockWorker {
        cache_len: u32,
        reply: Vec<u32>,
    }
    impl FlintWorker for MockWorker {
        fn request(&mut self, req: &WorkerRequest) -> Result<WorkerResponse, String> {
            if req.reset {
                self.cache_len = 0;
            }
            let before = self.cache_len;
            let tokens = if req.max_tokens > 0 {
                self.reply.clone()
            } else {
                vec![]
            };
            self.cache_len = before + (req.tokens.len() as u32) + (tokens.len() as u32);
            Ok(WorkerResponse {
                id: req.id,
                eos: tokens.last() == Some(&255),
                tokens,
                cache_before: before,
                cache_after: self.cache_len,
                prefill_tokens: req.tokens.len(),
                decode_forward_tokens: if req.max_tokens > 0 {
                    self.reply.len()
                } else {
                    0
                },
                reused_prefix_tokens: before,
                prefill_seconds: 0.01,
                decode_seconds: 0.02,
                kv_allocated_bytes: 1024,
                kv_valid_bytes: 512,
                kv_storage: "fp32".into(),
            })
        }
        fn close(&mut self, _graceful: bool) {}
    }

    #[test]
    fn backend_reuses_kv_prefix_on_followup_turn() {
        let mut reply: Vec<u32> = b"Hello!".iter().map(|&b| b as u32).collect();
        reply.push(255); // EOS
        let mut backend = FlintBackend::new(
            ByteTokenizer,
            Box::new(move || {
                Ok(MockWorker {
                    cache_len: 0,
                    reply: reply.clone(),
                })
            }),
            8192,
            vec![255],
            300,
        );

        let r1 = validate_request(
            &json!({"model": "flint", "messages": [{"role": "user", "content": "hi"}]}),
            256,
        )
        .unwrap();
        let out1 = backend.complete(&r1).unwrap();
        assert_eq!(out1["choices"][0]["message"]["content"], "Hello!");
        assert_eq!(out1["nanoattention"]["cache_reset"], true);
        assert_eq!(out1["nanoattention"]["reused_prefix_tokens"], 0);

        let r2 = validate_request(
            &json!({
                "model": "flint",
                "messages": [
                    {"role": "user", "content": "hi"},
                    {"role": "assistant", "content": "Hello!"},
                    {"role": "user", "content": "more"}
                ]
            }),
            256,
        )
        .unwrap();
        let out2 = backend.complete(&r2).unwrap();
        assert_eq!(out2["nanoattention"]["cache_reset"], false);
        assert!(
            out2["nanoattention"]["reused_prefix_tokens"]
                .as_u64()
                .unwrap()
                > 0
        );
    }

    #[test]
    fn inkling_chat_template_renders_tools_effort_and_tool_results() {
        let mut args = Map::new();
        args.insert("path".into(), json!("src/lib.rs"));
        let msgs = vec![
            NormalizedMessage {
                role: "system".into(),
                content: "Stay sharp <|end_message|>".into(),
                reasoning_content: None,
                tool_calls: vec![],
                tool_call_id: None,
                raw_assistant: None,
            },
            NormalizedMessage {
                role: "user".into(),
                content: "Inspect lib".into(),
                reasoning_content: None,
                tool_calls: vec![],
                tool_call_id: None,
                raw_assistant: None,
            },
            NormalizedMessage {
                role: "assistant".into(),
                content: String::new(),
                reasoning_content: Some("Need file".into()),
                tool_calls: vec![NormalizedToolCall {
                    id: "call_1".into(),
                    name: "read_file".into(),
                    arguments: args,
                }],
                tool_call_id: None,
                raw_assistant: None,
            },
            NormalizedMessage {
                role: "tool".into(),
                content: "pub fn ok() {}".into(),
                reasoning_content: None,
                tool_calls: vec![],
                tool_call_id: Some("call_1".into()),
                raw_assistant: None,
            },
        ];
        let tools = vec![json!({
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read a file",
                "parameters": {"type": "object", "properties": {"path": {"type": "string"}}}
            }
        })];
        let rendered = render_inkling_chat_template(&msgs, &tools, "low");
        assert!(rendered.starts_with("<|message_system|>tool_declare<|content_xml|>"));
        assert!(rendered.contains("&lt;|end_message|&gt;"));
        assert!(rendered.contains("Thinking effort level: 0.2<|end_message|>"));
        assert!(rendered.contains("<|message_model|><|content_thinking|>Need file<|end_message|>"));
        assert!(rendered.contains("<|message_model|>read_file<|content_invoke_tool_json|>{\"name\":\"read_file\",\"args\":{\"path\":\"src/lib.rs\"}}<|end_message|><|content_model_end_sampling|>"));
        assert!(
            rendered.ends_with(
                "<|message_tool|>read_file<|content_text|>pub fn ok() {}<|end_message|>"
            )
        );
    }

    #[test]
    fn inkling_completion_parser_handles_thinking_text_tool_calls_and_invalid_fallback() {
        let tools = vec![json!({
            "type": "function",
            "function": {
                "name": "search",
                "parameters": {
                    "type": "object",
                    "required": ["query"],
                    "properties": {"query": {"type": "string"}}
                }
            }
        })];
        let raw = "<|message_model|><|content_thinking|>plan<|end_message|><|message_model|><|content_text|>Searching<|end_message|><|message_model|>search<|content_invoke_tool_json|>{\"name\":\"search\",\"args\":{\"query\":\"inkling\"}}<|end_message|><|content_model_end_sampling|>";
        let parsed = parse_inkling_completion(raw, &tools, true).unwrap();
        assert_eq!(parsed.reasoning_content, "plan");
        assert_eq!(parsed.content, "Searching");
        assert_eq!(parsed.finish_reason, "tool_calls");
        assert_eq!(parsed.tool_calls.len(), 1);
        assert_eq!(parsed.tool_calls[0]["function"]["name"], "search");

        // An unwhitelisted function invalidates calls and falls back to plain stop text.
        let bad = "<|message_model|>unknown_fn<|content_invoke_tool_json|>{\"name\":\"unknown_fn\",\"args\":{}}<|end_message|><|content_model_end_sampling|>";
        let invalid = parse_inkling_completion(bad, &tools, true).unwrap();
        assert_eq!(invalid.finish_reason, "stop");
        assert!(invalid.tool_calls.is_empty());
        assert!(invalid.content.contains("unknown_fn"));

        // Truncated output leaves tool calls unexecuted with finish_reason length.
        let cut = parse_inkling_completion(raw, &tools, false).unwrap();
        assert_eq!(cut.finish_reason, "length");
        assert!(cut.tool_calls.is_empty());
    }

    #[test]
    fn inkling_backend_reuses_kv_prefix_across_turns() {
        struct InklingMockTokenizer;
        impl FlintTokenizer for InklingMockTokenizer {
            fn encode(&self, text: &str) -> Result<Vec<u32>, String> {
                let mut out = Vec::new();
                let mut rest = text;
                while !rest.is_empty() {
                    if let Some(after) = rest.strip_prefix("<|content_model_end_sampling|>") {
                        out.push(299);
                        rest = after;
                    } else {
                        out.push(rest.as_bytes()[0] as u32);
                        rest = &rest[1..];
                    }
                }
                Ok(out)
            }
            fn decode(&self, ids: &[u32]) -> Result<String, String> {
                let mut out = String::new();
                let mut buf = Vec::new();
                for &id in ids {
                    if id == 299 {
                        out.push_str(
                            &String::from_utf8(std::mem::take(&mut buf))
                                .map_err(|e| e.to_string())?,
                        );
                        out.push_str("<|content_model_end_sampling|>");
                    } else {
                        buf.push(id as u8);
                    }
                }
                out.push_str(&String::from_utf8(buf).map_err(|e| e.to_string())?);
                Ok(out)
            }
        }
        struct InklingWorker {
            cache_len: u32,
            reply: Vec<u32>,
        }
        impl FlintWorker for InklingWorker {
            fn request(&mut self, req: &WorkerRequest) -> Result<WorkerResponse, String> {
                if req.reset {
                    self.cache_len = 0;
                }
                let before = self.cache_len;
                let tokens = if req.max_tokens > 0 {
                    self.reply.clone()
                } else {
                    vec![]
                };
                self.cache_len = before + (req.tokens.len() as u32) + (tokens.len() as u32);
                Ok(WorkerResponse {
                    id: req.id,
                    eos: tokens.last() == Some(&299),
                    tokens,
                    cache_before: before,
                    cache_after: self.cache_len,
                    prefill_tokens: req.tokens.len(),
                    decode_forward_tokens: if req.max_tokens > 0 {
                        self.reply.len()
                    } else {
                        0
                    },
                    reused_prefix_tokens: before,
                    prefill_seconds: 0.01,
                    decode_seconds: 0.02,
                    kv_allocated_bytes: 1024,
                    kv_valid_bytes: 512,
                    kv_storage: "bf16".into(),
                })
            }
            fn close(&mut self, _graceful: bool) {}
        }

        let raw_reply = "<|message_model|><|content_text|>Hi there!<|end_message|><|content_model_end_sampling|>";
        let reply = InklingMockTokenizer.encode(raw_reply).unwrap();
        let mut backend = FlintBackend::new_for_model(
            InklingMockTokenizer,
            Box::new(move || {
                Ok(InklingWorker {
                    cache_len: 0,
                    reply: reply.clone(),
                })
            }),
            NativeModelKind::Inkling,
            8192,
            vec![299],
            300,
        );

        let r1 = validate_request_for_model(
            &json!({"model": "inkling-2-mini", "messages": [{"role": "user", "content": "hi"}]}),
            256,
            NativeModelKind::Inkling,
        )
        .unwrap();
        let out1 = backend.complete(&r1).unwrap();
        assert_eq!(out1["model"], "inkling-2-mini");
        assert_eq!(out1["choices"][0]["message"]["content"], "Hi there!");
        assert_eq!(out1["nanoattention"]["cache_reset"], true);

        let r2 = validate_request_for_model(
            &json!({
                "model": "inkling-2-mini",
                "messages": [
                    {"role": "user", "content": "hi"},
                    {"role": "assistant", "content": "Hi there!"},
                    {"role": "user", "content": "more"}
                ]
            }),
            256,
            NativeModelKind::Inkling,
        )
        .unwrap();
        let out2 = backend.complete(&r2).unwrap();
        assert_eq!(out2["nanoattention"]["cache_reset"], false);
        assert!(
            out2["nanoattention"]["reused_prefix_tokens"]
                .as_u64()
                .unwrap()
                > 0
        );
    }
}
