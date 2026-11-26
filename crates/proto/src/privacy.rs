//! Product-telemetry, crash-upload, and background-network killswitches.
//!
//! Rules live in `protocol/privacy-killswitch.json`. The engine, desktop app
//! and iOS app each run that file. Sync `device-id` is not a telemetry ID.

use std::collections::HashMap;

use serde::Deserialize;

/// Trimmed, case-insensitive 1 / true / yes.
pub fn flag_on(value: Option<&str>) -> bool {
    value.is_some_and(|raw| {
        matches!(
            raw.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes"
        )
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Decision {
    pub do_not_track: bool,
    pub offline: bool,
    pub product_telemetry: bool,
    pub crash_upload: bool,
    pub background_network: bool,
    pub create_telemetry_id: bool,
}

/// `get` is an env lookup (`DO_NOT_TRACK`, `HARNESS_OFFLINE`). No I/O.
pub fn decide(
    consent: bool,
    crash_consent: bool,
    mut get: impl FnMut(&str) -> Option<String>,
) -> Decision {
    let do_not_track = flag_on(get("DO_NOT_TRACK").as_deref());
    let offline = flag_on(get("HARNESS_OFFLINE").as_deref());
    let blocked = do_not_track || offline;
    Decision {
        do_not_track,
        offline,
        product_telemetry: consent && !blocked,
        crash_upload: crash_consent && !blocked,
        background_network: !blocked,
        create_telemetry_id: consent && !blocked,
    }
}

/// OS environment. Tests should call [`decide`] with an explicit map instead.
pub fn decide_from_os(consent: bool, crash_consent: bool) -> Decision {
    decide(consent, crash_consent, |key| std::env::var(key).ok())
}

pub fn background_network_from_os() -> bool {
    decide_from_os(true, true).background_network
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vectors {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    name: String,
    env: HashMap<String, String>,
    consent: bool,
    crash_consent: bool,
    expect: Expect,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Expect {
    do_not_track: bool,
    offline: bool,
    product_telemetry: bool,
    crash_upload: bool,
    background_network: bool,
    create_telemetry_id: bool,
}

/// Shared runner so the engine crate's lib tests (Windows CI) cover the file.
pub fn assert_protocol_vectors() {
    let vectors: Vectors =
        serde_json::from_str(include_str!("../../../protocol/privacy-killswitch.json"))
            .expect("protocol/privacy-killswitch.json");
    assert!(
        !vectors.cases.is_empty(),
        "privacy killswitch vector file is empty"
    );
    for case in &vectors.cases {
        let got = decide(case.consent, case.crash_consent, |key| {
            case.env.get(key).cloned()
        });
        assert_eq!(
            got,
            Decision {
                do_not_track: case.expect.do_not_track,
                offline: case.expect.offline,
                product_telemetry: case.expect.product_telemetry,
                crash_upload: case.expect.crash_upload,
                background_network: case.expect.background_network,
                create_telemetry_id: case.expect.create_telemetry_id,
            },
            "{}",
            case.name
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn killswitch_matches_protocol_vectors() {
        assert_protocol_vectors();
    }

    #[test]
    fn do_not_track_does_not_write_a_telemetry_id_file() {
        let dir = std::env::temp_dir().join(format!(
            "harness-privacy-dnt-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("telemetry-id");
        write_telemetry_id_if_allowed(&path, true, |key| {
            (key == "DO_NOT_TRACK").then(|| "1".to_string())
        });
        assert!(
            !path.exists(),
            "DO_NOT_TRACK=1 must not create a telemetry ID file"
        );
        write_telemetry_id_if_allowed(&path, false, |_| None);
        assert!(
            !path.exists(),
            "opt-out must not create a telemetry ID file"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn write_telemetry_id_if_allowed(
        path: &Path,
        consent: bool,
        get: impl FnMut(&str) -> Option<String>,
    ) {
        if !decide(consent, false, get).create_telemetry_id {
            return;
        }
        std::fs::write(path, "should-not-exist-under-dnt").unwrap();
    }
}
