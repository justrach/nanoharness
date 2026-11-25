use crate::{RunOrigin, process};

/// Attribute build-wait markers only to the run explicitly owning this child,
/// and scrub engine credentials (`HARNESS_IPC_TOKEN`,
/// `HARNESS_SANDBOX_TOKEN_FILE`, `HARNESS_EDGE_TOKEN`) so untrusted agent
/// processes never inherit direct engine/edge authority. The engine's MCP server
/// receives its own scoped token explicitly via `RunOrigin.ipc_token`.
pub(crate) fn apply_run_environment(cmd: &mut process::Command, origin: Option<&RunOrigin>) {
    cmd.env_remove("HARNESS_IPC_TOKEN");
    cmd.env_remove("HARNESS_SANDBOX_TOKEN_FILE");
    cmd.env_remove("HARNESS_EDGE_TOKEN");
    if let Some(dir) = origin.and_then(|origin| origin.build_wait_dir.as_ref()) {
        cmd.env("HARNESS_BUILD_WAIT_DIR", dir);
    } else {
        cmd.env_remove("HARNESS_BUILD_WAIT_DIR");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{OsStr, OsString};

    fn configured_directory(cmd: &mut process::Command) -> Option<Option<OsString>> {
        cmd.as_std_mut()
            .get_envs()
            .find(|(key, _)| *key == OsStr::new("HARNESS_BUILD_WAIT_DIR"))
            .map(|(_, value)| value.map(OsStr::to_os_string))
    }

    #[test]
    fn build_wait_environment_sets_the_current_runs_directory() {
        let origin = RunOrigin {
            build_wait_dir: Some(std::path::PathBuf::from("synthetic/current run")),
            ..Default::default()
        };
        let mut cmd = process::Command::new("synthetic-agent");
        cmd.env("HARNESS_BUILD_WAIT_DIR", "synthetic/other-run");
        apply_run_environment(&mut cmd, Some(&origin));
        assert_eq!(
            configured_directory(&mut cmd),
            Some(Some(OsString::from("synthetic/current run")))
        );
    }

    #[test]
    fn build_wait_environment_removes_inheritance_without_a_directory() {
        for origin in [None, Some(RunOrigin::default())] {
            let mut cmd = process::Command::new("synthetic-agent");
            cmd.env("HARNESS_BUILD_WAIT_DIR", "synthetic/other-run");
            apply_run_environment(&mut cmd, origin.as_ref());
            // An explicit removal, not merely an absent override: inherited
            // process environment must be scrubbed as well.
            assert_eq!(configured_directory(&mut cmd), Some(None));
        }
    }

    #[test]
    fn scrubs_ipc_and_sandbox_tokens_from_child_environment() {
        let origin = RunOrigin {
            build_wait_dir: Some(std::path::PathBuf::from("synthetic/run")),
            ..Default::default()
        };
        let mut cmd = process::Command::new("synthetic-agent");
        for key in [
            "HARNESS_IPC_TOKEN",
            "HARNESS_SANDBOX_TOKEN_FILE",
            "HARNESS_EDGE_TOKEN",
        ] {
            cmd.env(key, "secret-value");
        }
        apply_run_environment(&mut cmd, Some(&origin));
        for key in [
            "HARNESS_IPC_TOKEN",
            "HARNESS_SANDBOX_TOKEN_FILE",
            "HARNESS_EDGE_TOKEN",
        ] {
            let entry = cmd
                .as_std_mut()
                .get_envs()
                .find(|(k, _)| *k == OsStr::new(key))
                .map(|(_, v)| v.map(OsStr::to_os_string));
            assert_eq!(entry, Some(None), "{key} must be scrubbed from agent env");
        }
    }
}
