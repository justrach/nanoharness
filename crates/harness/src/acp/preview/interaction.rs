use harness_proto::{UserInputAnswer, UserInputQuestion};
use serde_json::{Map, Value, json};

// Fail closed on constraints the existing question bridge cannot enforce.
// Only simple, required enum strings are offered; URL and request-scoped
// elicitations never launch or request information here.
pub(super) fn form(params: &Value) -> Option<Vec<UserInputQuestion>> {
    if params["mode"] != "form"
        || params.get("requestId").is_some()
        || !params["toolCallId"].is_null()
    {
        return None;
    }
    let message = params["message"].as_str()?;
    if message.len() > 1024 {
        return None;
    }
    let schema = params["requestedSchema"].as_object()?;
    if schema["type"] != "object"
        || schema
            .keys()
            .any(|key| !matches!(key.as_str(), "type" | "properties" | "required"))
    {
        return None;
    }
    let props = schema.get("properties")?.as_object()?;
    let required = schema.get("required")?.as_array()?;
    if props.is_empty() || props.len() > 8 || props.len() != required.len() {
        return None;
    }
    props
        .iter()
        .map(|(id, prop)| {
            if id.is_empty() || id.len() > 80 || !required.iter().any(|key| key == id) {
                return None;
            }
            let prop = prop.as_object()?;
            if prop.get("type")?.as_str()? != "string"
                || prop
                    .keys()
                    .any(|key| !matches!(key.as_str(), "type" | "enum"))
            {
                return None;
            }
            let choices = prop.get("enum")?.as_array()?;
            if choices.len() < 2 || choices.len() > 8 {
                return None;
            }
            let mut options = Vec::new();
            for choice in choices {
                let choice = choice.as_str()?;
                if choice.is_empty()
                    || choice.len() > 120
                    || choice.chars().any(char::is_control)
                    || options.iter().any(|option| option == choice)
                {
                    return None;
                }
                options.push(choice.to_owned());
            }
            Some(UserInputQuestion {
                id: id.clone(),
                header: "Agent form".into(),
                question: format!("{message}\n{id}"),
                options,
                multi_select: false,
                prefill: None,
                multiline: false,
                requires_human_ui: true,
            })
        })
        .collect()
}

pub(super) fn answer(questions: &[UserInputQuestion], answers: Vec<UserInputAnswer>) -> Value {
    if answers.len() != questions.len() {
        return json!({"action": "cancel"});
    }
    let mut content = Map::new();
    for answer in answers {
        let [value] = answer.labels.as_slice() else {
            return json!({"action": "cancel"});
        };
        if !questions
            .iter()
            .any(|q| q.id == answer.question_id && q.options.contains(value))
            || content.insert(answer.question_id, json!(value)).is_some()
        {
            return json!({"action": "cancel"});
        }
    }
    json!({"action": "accept", "content": content})
}
