//! ACP form elicitation (`elicitation/create`, mode `form`): an agent asks the
//! user to fill a small flat schema mid-turn. Graff 0.0.302.6 sends ask_user
//! this way to clients that advertise `clientCapabilities.elicitation.form`,
//! and answers at once ("assume and continue") for clients that don't.
//!
//! Each supported property becomes one question on the engine's input bridge:
//! strings (free text, or picks when the schema has an `enum`), booleans
//! (Yes / No), and numbers. A schema with a required property we can't show
//! is declined so the agent never waits on a form nobody can fill.

use harness_proto::{UserInputAnswer, UserInputQuestion};
use serde_json::{Map, Value, json};

/// The capability advertised at `initialize`.
pub(super) fn capability() -> Value {
    json!({ "form": {} })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Text,
    Bool,
    Integer,
    Number,
}

#[derive(Debug, Clone)]
struct Field {
    key: String,
    kind: Kind,
    question: UserInputQuestion,
}

/// A form the user can answer, with the questions to show.
#[derive(Debug, Clone)]
pub(super) struct Form {
    fields: Vec<Field>,
}

impl Form {
    pub(super) fn questions(&self) -> Vec<UserInputQuestion> {
        self.fields
            .iter()
            .map(|field| field.question.clone())
            .collect()
    }

    /// The `elicitation/create` result for these answers. No answers at all
    /// (the resolver was dropped or the turn ended) cancels; an answered form
    /// missing a value, or holding one that doesn't parse, declines.
    pub(super) fn response(&self, answers: &[UserInputAnswer]) -> Value {
        if answers.is_empty() {
            return cancel();
        }
        let mut content = Map::new();
        for field in &self.fields {
            let labels = answers
                .iter()
                .find(|answer| answer.question_id == field.question.id)
                .map(|answer| answer.labels.as_slice())
                .unwrap_or_default();
            let mut labels = labels
                .iter()
                .map(|label| label.trim())
                .filter(|label| !label.is_empty());
            // Free text keeps every label: files attached to an answer ride
            // as a second one. A choice or typed value is just the first.
            let label = if field.kind == Kind::Text && field.question.options.is_empty() {
                labels.collect::<Vec<_>>().join("\n\n")
            } else {
                labels.next().unwrap_or_default().to_owned()
            };
            if label.is_empty() {
                return json!({ "action": "decline" });
            }
            let Some(value) = field.kind.parse(&label) else {
                return json!({ "action": "decline" });
            };
            content.insert(field.key.clone(), value);
        }
        json!({ "action": "accept", "content": content })
    }
}

impl Kind {
    fn parse(self, label: &str) -> Option<Value> {
        match self {
            Kind::Text => Some(Value::String(label.to_owned())),
            Kind::Bool => match label.to_ascii_lowercase().as_str() {
                "yes" | "true" => Some(Value::Bool(true)),
                "no" | "false" => Some(Value::Bool(false)),
                _ => None,
            },
            Kind::Integer => label.parse::<i64>().ok().map(Value::from),
            Kind::Number => label
                .parse::<f64>()
                .ok()
                .and_then(|n| serde_json::Number::from_f64(n).map(Value::Number)),
        }
    }
}

/// The response for a request we won't show (wrong session, unsupported form).
pub(super) fn cancel() -> Value {
    json!({ "action": "cancel" })
}

/// Parse `elicitation/create` params into a form, or None when it can't be
/// shown: URL mode, a nested or empty schema, or a required property of a
/// type we don't render. Optional properties we can't render are left out.
pub(super) fn form(params: &Value, new_id: impl Fn() -> String) -> Option<Form> {
    if params.get("mode").and_then(Value::as_str).unwrap_or("form") != "form" {
        return None;
    }
    let message = params
        .get("message")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|message| !message.is_empty())
        .unwrap_or("The agent needs your input.");
    let schema = params.get("requestedSchema")?;
    let properties = schema.get("properties")?.as_object()?;
    let required: Vec<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|keys| keys.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let single = properties.len() == 1;
    let mut fields = Vec::new();
    for (key, property) in properties {
        let Some((kind, options)) = kind_of(property) else {
            if required.contains(&key.as_str()) {
                return None;
            }
            continue;
        };
        let title = property
            .get("title")
            .or_else(|| property.get("description"))
            .and_then(Value::as_str)
            .unwrap_or(key);
        let question = if single {
            message.to_owned()
        } else {
            format!("{message}\n\n{title}")
        };
        fields.push(Field {
            key: key.clone(),
            kind,
            question: UserInputQuestion {
                id: new_id(),
                header: "Agent question".into(),
                question,
                options,
                prefill: None,
                multiline: false,
                multi_select: false,
                requires_human_ui: false,
            },
        });
    }
    (!fields.is_empty()).then_some(Form { fields })
}

fn kind_of(property: &Value) -> Option<(Kind, Vec<String>)> {
    match property.get("type").and_then(Value::as_str)? {
        "string" => {
            let options = property
                .get("enum")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            Some((Kind::Text, options))
        }
        "boolean" => Some((Kind::Bool, vec!["Yes".into(), "No".into()])),
        "integer" => Some((Kind::Integer, Vec::new())),
        "number" => Some((Kind::Number, Vec::new())),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids() -> impl Fn() -> String {
        let next = std::cell::Cell::new(0);
        move || {
            next.set(next.get() + 1);
            format!("q{}", next.get())
        }
    }

    fn answer(id: &str, label: &str) -> UserInputAnswer {
        UserInputAnswer {
            question_id: id.into(),
            labels: vec![label.into()],
        }
    }

    /// The exact shape graff 0.0.302.6 sends for ask_user with choices.
    fn graff_ask(choices: Option<&[&str]>) -> Value {
        let mut answer = json!({ "type": "string", "title": "Answer" });
        if let Some(choices) = choices {
            answer["enum"] = json!(choices);
        }
        json!({
            "sessionId": "s1",
            "mode": "form",
            "message": "Which database should I use?",
            "requestedSchema": {
                "type": "object",
                "properties": { "answer": answer },
                "required": ["answer"],
            },
        })
    }

    #[test]
    fn graff_ask_user_becomes_one_question_and_answers_accept() {
        let form = form(&graff_ask(Some(&["Postgres", "SQLite"])), ids()).unwrap();
        let questions = form.questions();
        assert_eq!(questions.len(), 1);
        assert_eq!(questions[0].question, "Which database should I use?");
        assert_eq!(questions[0].options, ["Postgres", "SQLite"]);
        assert_eq!(
            form.response(&[answer("q1", "SQLite")]),
            json!({ "action": "accept", "content": { "answer": "SQLite" } })
        );
    }

    #[test]
    fn free_text_questions_take_typed_answers() {
        let form = form(&graff_ask(None), ids()).unwrap();
        assert!(form.questions()[0].options.is_empty());
        assert_eq!(
            form.response(&[answer("q1", "  the one in docker  ")]),
            json!({ "action": "accept", "content": { "answer": "the one in docker" } })
        );
    }

    #[test]
    fn attached_files_ride_a_free_text_answer_but_not_a_choice() {
        let attached = UserInputAnswer {
            question_id: "q1".into(),
            labels: vec!["see this".into(), "Attached images:\n- /tmp/a.png".into()],
        };
        let free = form(&graff_ask(None), ids()).unwrap();
        assert_eq!(
            free.response(std::slice::from_ref(&attached)),
            json!({ "action": "accept", "content": { "answer": "see this\n\nAttached images:\n- /tmp/a.png" } })
        );
        let choice = form(&graff_ask(Some(&["see this", "other"])), ids()).unwrap();
        assert_eq!(
            choice.response(&[attached]),
            json!({ "action": "accept", "content": { "answer": "see this" } })
        );
    }

    #[test]
    fn a_dropped_or_blank_answer_never_accepts() {
        let form = form(&graff_ask(None), ids()).unwrap();
        assert_eq!(form.response(&[]), json!({ "action": "cancel" }));
        assert_eq!(
            form.response(&[answer("q1", "   ")]),
            json!({ "action": "decline" })
        );
    }

    #[test]
    fn typed_fields_parse_or_decline() {
        let params = json!({
            "message": "Settings",
            "requestedSchema": {
                "type": "object",
                "properties": {
                    "confirm": { "type": "boolean", "title": "Proceed?" },
                    "count": { "type": "integer" },
                },
                "required": ["confirm", "count"],
            },
        });
        let form = form(&params, ids()).unwrap();
        let questions = form.questions();
        assert_eq!(questions[0].options, ["Yes", "No"]);
        assert_eq!(questions[0].question, "Settings\n\nProceed?");
        assert_eq!(
            form.response(&[answer("q1", "Yes"), answer("q2", "3")]),
            json!({ "action": "accept", "content": { "confirm": true, "count": 3 } })
        );
        assert_eq!(
            form.response(&[answer("q1", "Yes"), answer("q2", "three")]),
            json!({ "action": "decline" })
        );
    }

    fn picks(id: &str, labels: &[&str]) -> UserInputAnswer {
        UserInputAnswer {
            question_id: id.into(),
            labels: labels.iter().map(|label| (*label).into()).collect(),
        }
    }

    /// The exact shape agy 1.5.14 sends for `ask_question` (captured over
    /// `agy acp`): each question a titled single (`oneOf`) or multiple
    /// (`array` of `anyOf`) choice, plus an optional `_other` write-in, and
    /// no `required` list.
    fn agy_ask() -> Value {
        json!({
            "sessionId": "s1",
            "toolCallId": "call-1",
            "mode": "form",
            "message": "The agent has 2 questions.",
            "requestedSchema": {
                "type": "object",
                "properties": {
                    "q1": {
                        "type": "string",
                        "title": "Which fruit?",
                        "oneOf": [
                            { "const": "1", "title": "Apple" },
                            { "const": "2", "title": "Banana" },
                            { "const": "3", "title": "Cherry" },
                        ],
                    },
                    "q1_other": {
                        "type": "string",
                        "title": "Other",
                        "description": "Optional free-form answer to: Which fruit?",
                    },
                    "q2": {
                        "type": "array",
                        "title": "Which colours?",
                        "items": { "anyOf": [
                            { "const": "1", "title": "Red" },
                            { "const": "2", "title": "Green" },
                            { "const": "3", "title": "Blue" },
                        ] },
                    },
                    "q2_other": {
                        "type": "string",
                        "title": "Other",
                        "description": "Optional free-form answer to: Which colours?",
                    },
                },
            },
        })
    }

    #[test]
    fn antigravity_questions_are_one_page_each_with_the_write_in_folded_in() {
        let form = form(&agy_ask(), ids()).unwrap();
        let questions = form.questions();
        assert_eq!(questions.len(), 2, "{questions:?}");
        assert_eq!(questions[0].question, "Which fruit?");
        assert_eq!(questions[0].options, ["Apple", "Banana", "Cherry"]);
        assert!(!questions[0].multi_select);
        assert_eq!(questions[1].question, "Which colours?");
        assert_eq!(questions[1].options, ["Red", "Green", "Blue"]);
        assert!(questions[1].multi_select);
    }

    #[test]
    fn a_pick_answers_the_select_key_and_a_typed_answer_the_write_in_key() {
        let form = form(&agy_ask(), ids()).unwrap();
        // Byte for byte what agy 1.5.14 accepted for each.
        assert_eq!(
            form.response(&[answer("q1", "Apple"), picks("q2", &["Red", "Green"])]),
            json!({ "action": "accept", "content": { "q1": "1", "q2": ["1", "2"] } })
        );
        assert_eq!(
            form.response(&[
                answer("q1", "Dragonfruit, typed by hand"),
                picks("q2", &["Red", "Green"]),
            ]),
            json!({ "action": "accept", "content": {
                "q1_other": "Dragonfruit, typed by hand",
                "q2": ["1", "2"],
            } })
        );
    }

    #[test]
    fn multi_select_answers_as_a_list() {
        let form = form(&agy_ask(), ids()).unwrap();
        assert_eq!(
            form.response(&[answer("q1", "Banana"), picks("q2", &["Blue"])]),
            json!({ "action": "accept", "content": { "q1": "2", "q2": ["3"] } })
        );
        assert_eq!(
            form.response(&[answer("q1", "Banana"), answer("q2", "Purple")]),
            json!({ "action": "accept", "content": { "q1": "2", "q2_other": "Purple" } })
        );
    }

    #[test]
    fn titled_choices_show_titles_and_answer_with_their_values() {
        let titled = json!({
            "message": "Which region?",
            "requestedSchema": {
                "type": "object",
                "properties": { "region": { "type": "string", "oneOf": [
                    { "const": "eu-west-1", "title": "Ireland" },
                    { "const": "us-east-1", "title": "Virginia" },
                ] } },
                "required": ["region"],
            },
        });
        let form = form(&titled, ids()).unwrap();
        assert_eq!(form.questions()[0].question, "Which region?");
        assert_eq!(form.questions()[0].options, ["Ireland", "Virginia"]);
        assert_eq!(
            form.response(&[answer("q1", "Virginia")]),
            json!({ "action": "accept", "content": { "region": "us-east-1" } })
        );
        let named = json!({
            "message": "Which tier?",
            "requestedSchema": {
                "type": "object",
                "properties": { "tier": {
                    "type": "string", "enum": ["a", "b"], "enumNames": ["Alpha", "Beta"],
                } },
            },
        });
        let form = super::form(&named, ids()).unwrap();
        assert_eq!(form.questions()[0].options, ["Alpha", "Beta"]);
        assert_eq!(
            form.response(&[answer("q1", "Beta")]),
            json!({ "action": "accept", "content": { "tier": "b" } })
        );
    }

    #[test]
    fn optional_blank_fields_are_left_out_not_declined() {
        let params = json!({
            "message": "Profile",
            "requestedSchema": {
                "type": "object",
                "properties": {
                    "name": { "type": "string", "title": "Name" },
                    "nickname": { "type": "string", "title": "Nickname" },
                },
                "required": ["name"],
            },
        });
        let form = form(&params, ids()).unwrap();
        assert_eq!(
            form.response(&[answer("q1", "Ada"), answer("q2", "  ")]),
            json!({ "action": "accept", "content": { "name": "Ada" } })
        );
        assert_eq!(
            form.response(&[answer("q1", " "), answer("q2", "Countess")]),
            json!({ "action": "decline" })
        );
    }

    #[test]
    fn numbered_questions_keep_their_order_past_nine() {
        let mut properties = serde_json::Map::new();
        for n in 1..=10 {
            properties.insert(
                format!("q{n}"),
                json!({ "type": "string", "title": format!("Question {n}"), "oneOf": [
                    { "const": "1", "title": "Yes" },
                    { "const": "2", "title": "No" },
                ] }),
            );
            properties.insert(
                format!("q{n}_other"),
                json!({ "type": "string", "title": "Other" }),
            );
        }
        let params = json!({
            "message": "The agent has 10 questions.",
            "requestedSchema": { "type": "object", "properties": properties },
        });
        let shown: Vec<String> = form(&params, ids())
            .unwrap()
            .questions()
            .into_iter()
            .map(|question| question.question)
            .collect();
        let expected: Vec<String> = (1..=10).map(|n| format!("Question {n}")).collect();
        assert_eq!(shown, expected);
    }

    #[test]
    fn unshowable_forms_are_refused() {
        let url = json!({ "mode": "url", "url": "https://example.com", "message": "Sign in" });
        assert!(form(&url, ids()).is_none());
        let nested = json!({
            "message": "x",
            "requestedSchema": {
                "type": "object",
                "properties": { "items": { "type": "array" } },
                "required": ["items"],
            },
        });
        assert!(form(&nested, ids()).is_none());
    }
}
