//! OS-env gates for product telemetry, crash uploads, and background network
//! (update checks, npm prewarm, catalog pings). Rules:
//! `protocol/privacy-killswitch.json`.

pub use harness_proto::privacy::{
    Decision, assert_protocol_vectors, background_network_from_os, decide, decide_from_os, flag_on,
};

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn killswitch_matches_protocol_vectors() {
        assert_protocol_vectors();
    }

    #[test]
    fn do_not_track_writes_no_telemetry_id_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("telemetry-id");
        write_telemetry_id_if_allowed(&path, true, |key| {
            (key == "DO_NOT_TRACK").then(|| "1".into())
        });
        assert!(
            !path.exists(),
            "this fails on main: DO_NOT_TRACK=1 must not create a telemetry ID file"
        );
        write_telemetry_id_if_allowed(&path, false, |_| None);
        assert!(
            !path.exists(),
            "opt-out must not create a telemetry ID file"
        );
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
