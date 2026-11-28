//! Device-room host relay admission and remote-command consent.
//!
//! The host relay serves the same [`RpcService`] the local IPC socket does. A
//! compromised edge that can inject frames into a live host socket would
//! otherwise get a full ControlRpc surface on every synced computer. Admission
//! is a pure function of the device-local preference, the method name, and
//! whether this remote caller has been approved locally so tests can pin the
//! gates without a Durable Object.

use crate::methods;
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

/// Whether a method may run on the host-relay RPC surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayAdmit {
    /// Serve it. Either remote control is on, or the method is a liveness /
    /// status probe that must work so a phone can see the setting.
    Allow,
    /// User has not enabled Settings → Devices → Allow remote control.
    RemoteControlOff,
    /// Never served over the relay, even when remote control is on. Changing
    /// the gate itself from the relay, flipping autonomy, or applying a
    /// binary update would let a compromised edge own the computer.
    LocalOnly,
    /// Remote control is on, but this caller has not yet been approved for
    /// execution / file writes / terminals on this computer.
    NeedsApproval,
    /// Like [`Self::NeedsApproval`], but the request named no device, so
    /// there is nobody this computer could approve. Refused, never parked.
    UnidentifiedCaller,
}

/// Error text when [`RelayAdmit::LocalOnly`].
pub const RELAY_LOCAL_ONLY: &str = "This action can only be done on the computer itself.";

/// The host in a refusal when its device row has no name.
pub const RELAY_HOST_FALLBACK: &str = "the computer you're connecting to";

/// The caller in a refusal when its device row has no name. The refusal is
/// read on the device that sent the request.
pub const RELAY_DEVICE_FALLBACK: &str = "this device";

/// The caller id a parked item carried before unidentified callers were
/// refused outright. The engine never records it as an approved device.
pub const UNKNOWN_CALLER: &str = "unknown";

/// What a refused relay caller reads, for each refusal. `host` and `device`
/// are device-row names when this computer knows them; `allow_once` is
/// [`relay_allow_once_method`] for the refused method. `None` for
/// [`RelayAdmit::Allow`].
pub fn relay_refusal_text(
    admit: RelayAdmit,
    allow_once: bool,
    host: Option<&str>,
    device: Option<&str>,
) -> Option<String> {
    let host = host
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(RELAY_HOST_FALLBACK);
    let device = device
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(RELAY_DEVICE_FALLBACK);
    Some(match admit {
        RelayAdmit::Allow => return None,
        RelayAdmit::LocalOnly => RELAY_LOCAL_ONLY.to_string(),
        RelayAdmit::RemoteControlOff => format!(
            "Remote control is off on {host}. On {host}, turn on Settings → Devices → \
             Allow remote control, then try again."
        ),
        RelayAdmit::NeedsApproval => {
            let choice = if allow_once {
                "Allow once or Always allow"
            } else {
                "Always allow"
            };
            format!(
                "This action from {device} needs approval on {host}. On {host}, open \
                 Settings → Devices and choose {choice}, then try again."
            )
        }
        RelayAdmit::UnidentifiedCaller => format!(
            "This action wasn't run: {host} couldn't tell which device sent it, so it \
             can't be approved. Update Harness on this device, then try again."
        ),
    })
}

/// A short reason for the denial log line.
pub fn relay_refusal_reason(admit: RelayAdmit) -> &'static str {
    match admit {
        RelayAdmit::Allow => "allowed",
        RelayAdmit::RemoteControlOff => "remote_control_off",
        RelayAdmit::LocalOnly => "local_only",
        RelayAdmit::NeedsApproval => "needs_approval",
        RelayAdmit::UnidentifiedCaller => "unidentified_caller",
    }
}

/// A parked remote action waiting for a person on the host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteApproval {
    pub id: String,
    /// `command` (chat2 drain) or `rpc` (ControlRpc).
    pub kind: String,
    pub device_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chat_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    pub summary: String,
    /// Whether Settings → Devices offers "Allow once" for this item. False
    /// where one approval cannot cover the action (terminals).
    #[serde(default = "allow_once_default")]
    pub allow_once: bool,
    /// The parked request's [`RelayOnceGrant::request_digest`] (`rpc` items
    /// only). Kept on this computer: never serialized, so the approval list
    /// a peer can read does not carry it.
    #[serde(skip)]
    pub request_digest: Option<String>,
}

fn allow_once_default() -> bool {
    true
}

/// How long "Allow once" on a parked relayed action waits for the same
/// device to try that action again. Long enough to walk back to the other
/// device; short enough that a forgotten approval doesn't linger.
pub const RELAY_ALLOW_ONCE_TTL: Duration = Duration::from_secs(5 * 60);

/// "Allow once" on a parked relayed action: the one retry it admits. Held in
/// memory only (never in prefs), spent by its first use.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayOnceGrant {
    pub device_id: String,
    pub method: String,
    /// Digest of the parked request's params (the caller id stripped), so the
    /// grant admits that request and no other.
    pub request_digest: String,
    pub granted_at: Instant,
}

impl RelayOnceGrant {
    /// Past [`RELAY_ALLOW_ONCE_TTL`] at `now`.
    pub fn expired(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.granted_at) >= RELAY_ALLOW_ONCE_TTL
    }

    /// Whether this grant admits `method` with params digest `request_digest`
    /// from `device_id` at `now`. Only ever consulted after
    /// [`admit_relay_caller`] answered [`RelayAdmit::NeedsApproval`], so remote
    /// control is on and the method is not local-only; this re-checks the
    /// method class anyway so a grant can never stand in for more.
    pub fn admits(
        &self,
        device_id: &str,
        method: &str,
        request_digest: &str,
        now: Instant,
    ) -> bool {
        relay_allow_once_method(method)
            && relay_caller_identified(device_id)
            && self.device_id == device_id
            && self.method == method
            && !request_digest.is_empty()
            && self.request_digest == request_digest
            && !self.expired(now)
    }
}

/// Whether a chat2 command the host is about to drain may run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteCommandAdmit {
    /// Issued by this computer.
    Local,
    /// Remote, and either remote control is on (iOS composer) or the user
    /// approved this command / this device.
    Execute,
    /// Park it and show an approval chip. Do not mark processed.
    NeedsApproval,
}

/// Methods the host relay may serve while remote control is off. `ListHarnesses`
/// is the peer-link readiness probe; `GetRemoteControl` lets another device
/// show that this computer has not opted in. Everything else is execution,
/// filesystem, terminals, or settings mutation.
fn relay_probe_method(method: &str) -> bool {
    matches!(
        method,
        methods::GET_REMOTE_CONTROL
            | methods::GET_REMOTE_APPROVALS
            | methods::LIST_HARNESSES
            | methods::ENGINE_INFO
            | methods::ENGINE_READY
            | methods::GET_DEVICE_IDENTITY
            | methods::GET_E2EE
    )
}

/// Never served over the relay, even when remote control is on.
fn relay_local_only_method(method: &str) -> bool {
    matches!(
        method,
        methods::SET_REMOTE_CONTROL
            | methods::SET_AUTONOMY
            | methods::APPLY_UPDATE
            | methods::APPLY_HARNESS_UPDATE
            | methods::SET_HARNESS_UPDATE_POLICY
            | methods::SET_E2EE
            | methods::APPROVE_REMOTE_ACTION
            | methods::DENY_REMOTE_ACTION
    )
}

/// First execution / file write / terminal from a remote caller needs a local
/// approval even when remote control is on.
pub fn relay_first_action_method(method: &str) -> bool {
    matches!(
        method,
        methods::QUEUE_COMMAND
            | methods::RELAY_COMMAND
            | methods::OPEN_TERMINAL
            | methods::WRITE_TERMINAL
            | methods::RESIZE_TERMINAL
            | methods::CLOSE_TERMINAL
            | methods::WRITE_WORKSPACE_FILE
            | methods::ADD_REPO
            | methods::CLONE_REPO
            | methods::CREATE_REPO
            | methods::FETCH_ALL
            | methods::SWITCH_REF
            | methods::CREATE_WORKTREE
            | methods::DELETE_WORKTREE
            | methods::GRAFF_WORKTREE_ACTION
            | methods::UPSERT_PROJECT_ACTION
            | methods::DELETE_PROJECT_ACTION
            | methods::RUN_PROJECT_ACTION
            | methods::MERGE_CHANGE_REQUEST
            | methods::MCP_SERVER_ACTION
            | methods::INVOKE_NATIVE_EXTENSION
            | methods::BOT_ACTION
            | methods::RUN_BOT
            | methods::UPLOAD_COMMIT
            | methods::APPLY_CHECKOUT_GIT_ACTION
            | methods::DISCARD_WORKING_TREE
    )
}

/// Admit one ControlRpc method on the device-room **host** socket.
///
/// Local IPC is unrestricted: the GUI on this computer still talks to the
/// engine over `127.0.0.1`. This gate applies only to frames that arrived
/// through the edge relay.
pub fn admit_relay_rpc(remote_control: bool, method: &str) -> RelayAdmit {
    admit_relay_action(remote_control, method, true)
}

/// Like [`admit_relay_rpc`], with the per-caller first-action consent.
pub fn admit_relay_action(remote_control: bool, method: &str, caller_approved: bool) -> RelayAdmit {
    if relay_local_only_method(method) {
        return RelayAdmit::LocalOnly;
    }
    if !(remote_control || relay_probe_method(method)) {
        return RelayAdmit::RemoteControlOff;
    }
    if relay_first_action_method(method) && !caller_approved {
        RelayAdmit::NeedsApproval
    } else {
        RelayAdmit::Allow
    }
}

/// Whether a relay caller id names a device this computer could approve.
pub fn relay_caller_identified(device_id: &str) -> bool {
    !device_id.is_empty() && device_id != UNKNOWN_CALLER
}

/// [`admit_relay_action`] for a caller id: a request that would need
/// approval but names no device is [`RelayAdmit::UnidentifiedCaller`].
pub fn admit_relay_caller(
    remote_control: bool,
    method: &str,
    caller_id: &str,
    caller_approved: bool,
) -> RelayAdmit {
    match admit_relay_action(remote_control, method, caller_approved) {
        RelayAdmit::NeedsApproval if !relay_caller_identified(caller_id) => {
            RelayAdmit::UnidentifiedCaller
        }
        verdict => verdict,
    }
}

/// Whether one "Allow once" can cover a parked call of `method`. A terminal
/// is a stream of calls (every keystroke is a `WriteTerminal`), so a
/// one-request grant would admit a single keystroke; those offer only
/// "Always allow".
pub fn relay_allow_once_method(method: &str) -> bool {
    relay_first_action_method(method)
        && !matches!(
            method,
            methods::OPEN_TERMINAL
                | methods::WRITE_TERMINAL
                | methods::RESIZE_TERMINAL
                | methods::CLOSE_TERMINAL
        )
}

/// Chat2 drain consent. Run/Steer from another device are Peer work and only
/// execute when remote control is on or the user approved. Interrupt and
/// question answers still drain so a phone can stop a turn it started.
pub fn admit_remote_command(
    local_device_id: &str,
    issued_by: &str,
    kind: &str,
    remote_control: bool,
    command_approved: bool,
    device_always_allowed: bool,
) -> RemoteCommandAdmit {
    if issued_by.is_empty() || issued_by == local_device_id {
        return RemoteCommandAdmit::Local;
    }
    let needs_consent = matches!(kind, "run" | "steer" | "Run" | "Steer");
    if !needs_consent {
        return RemoteCommandAdmit::Execute;
    }
    if command_approved || device_always_allowed || remote_control {
        RemoteCommandAdmit::Execute
    } else {
        RemoteCommandAdmit::NeedsApproval
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_command_is_refused_until_remote_control_is_on() {
        assert_eq!(
            admit_relay_rpc(false, methods::QUEUE_COMMAND),
            RelayAdmit::RemoteControlOff
        );
        assert_eq!(
            admit_relay_rpc(true, methods::QUEUE_COMMAND),
            RelayAdmit::Allow
        );
    }

    #[test]
    fn terminals_and_file_writes_follow_the_same_gate() {
        for method in [
            methods::OPEN_TERMINAL,
            methods::WRITE_TERMINAL,
            methods::WRITE_WORKSPACE_FILE,
            methods::RELAY_COMMAND,
            methods::MCP_SERVER_ACTION,
        ] {
            assert_eq!(
                admit_relay_rpc(false, method),
                RelayAdmit::RemoteControlOff,
                "{method}"
            );
            assert_eq!(admit_relay_rpc(true, method), RelayAdmit::Allow, "{method}");
        }
    }

    #[test]
    fn repo_mutations_and_project_actions_require_first_action_approval() {
        for method in [
            methods::ADD_REPO,
            methods::CLONE_REPO,
            methods::CREATE_REPO,
            methods::FETCH_ALL,
            methods::SWITCH_REF,
            methods::GRAFF_WORKTREE_ACTION,
            methods::UPSERT_PROJECT_ACTION,
            methods::DELETE_PROJECT_ACTION,
            methods::RUN_PROJECT_ACTION,
            methods::MERGE_CHANGE_REQUEST,
        ] {
            assert_eq!(
                admit_relay_action(true, method, false),
                RelayAdmit::NeedsApproval,
                "{method} must require first-action approval over the relay"
            );
            assert_eq!(
                admit_relay_action(true, method, true),
                RelayAdmit::Allow,
                "{method} should be allowed once caller is approved"
            );
        }
    }

    #[test]
    fn autonomy_and_updates_are_never_served_over_the_relay() {
        for method in [
            methods::SET_REMOTE_CONTROL,
            methods::SET_AUTONOMY,
            methods::APPLY_UPDATE,
            methods::APPLY_HARNESS_UPDATE,
            methods::SET_E2EE,
        ] {
            assert_eq!(
                admit_relay_rpc(false, method),
                RelayAdmit::LocalOnly,
                "{method}"
            );
            assert_eq!(
                admit_relay_rpc(true, method),
                RelayAdmit::LocalOnly,
                "{method}"
            );
        }
    }

    #[test]
    fn first_remote_execution_needs_local_approval() {
        assert_eq!(
            admit_relay_action(true, methods::QUEUE_COMMAND, false),
            RelayAdmit::NeedsApproval
        );
        assert_eq!(
            admit_relay_action(true, methods::WRITE_WORKSPACE_FILE, false),
            RelayAdmit::NeedsApproval
        );
        assert_eq!(
            admit_relay_action(true, methods::OPEN_TERMINAL, true),
            RelayAdmit::Allow
        );
        assert_eq!(
            admit_relay_action(true, methods::LIST_HARNESSES, false),
            RelayAdmit::Allow
        );
    }

    #[test]
    fn probes_work_while_remote_control_is_off() {
        for method in [
            methods::GET_REMOTE_CONTROL,
            methods::LIST_HARNESSES,
            methods::ENGINE_INFO,
            methods::ENGINE_READY,
        ] {
            assert_eq!(
                admit_relay_rpc(false, method),
                RelayAdmit::Allow,
                "{method}"
            );
        }
    }

    #[test]
    fn set_remote_control_is_never_served_over_the_relay() {
        assert_eq!(
            admit_relay_rpc(false, methods::SET_REMOTE_CONTROL),
            RelayAdmit::LocalOnly
        );
        assert_eq!(
            admit_relay_rpc(true, methods::SET_REMOTE_CONTROL),
            RelayAdmit::LocalOnly
        );
    }

    fn grant(device: &str, method: &str, digest: &str, at: Instant) -> RelayOnceGrant {
        RelayOnceGrant {
            device_id: device.into(),
            method: method.into(),
            request_digest: digest.into(),
            granted_at: at,
        }
    }

    #[test]
    fn allow_once_grant_admits_only_its_device_method_request_and_lifetime() {
        let t0 = Instant::now();
        let git = methods::APPLY_CHECKOUT_GIT_ACTION;
        let g = grant("phone-1", git, "digest-a", t0);
        assert!(g.admits("phone-1", git, "digest-a", t0));
        assert!(g.admits(
            "phone-1",
            git,
            "digest-a",
            t0 + RELAY_ALLOW_ONCE_TTL - Duration::from_secs(1)
        ));
        assert!(!g.admits("phone-1", git, "digest-a", t0 + RELAY_ALLOW_ONCE_TTL));
        assert!(!g.admits("phone-2", git, "digest-a", t0), "another device");
        assert!(
            !g.admits("phone-1", methods::DISCARD_WORKING_TREE, "digest-a", t0),
            "another gated method"
        );
        assert!(!g.admits("phone-1", git, "digest-b", t0), "another request");
        assert!(!g.admits("phone-1", git, "", t0));

        // Even a grant recorded for them never covers a local-only method,
        // an ungated one, a terminal, or an unidentified caller.
        for method in [
            methods::SET_REMOTE_CONTROL,
            methods::SET_AUTONOMY,
            methods::APPLY_UPDATE,
            methods::APPROVE_REMOTE_ACTION,
            methods::LIST_HARNESSES,
            methods::WRITE_TERMINAL,
        ] {
            assert!(
                !grant("phone-1", method, "d", t0).admits("phone-1", method, "d", t0),
                "{method}"
            );
        }
        for caller in ["", UNKNOWN_CALLER] {
            assert!(!grant(caller, git, "d", t0).admits(caller, git, "d", t0));
        }
    }

    #[test]
    fn terminals_are_not_offered_allow_once() {
        assert!(relay_allow_once_method(methods::APPLY_CHECKOUT_GIT_ACTION));
        assert!(relay_allow_once_method(methods::WRITE_WORKSPACE_FILE));
        assert!(relay_allow_once_method(methods::RELAY_COMMAND));
        for method in [
            methods::OPEN_TERMINAL,
            methods::WRITE_TERMINAL,
            methods::RESIZE_TERMINAL,
            methods::CLOSE_TERMINAL,
            methods::LIST_HARNESSES,
            methods::SET_REMOTE_CONTROL,
        ] {
            assert!(!relay_allow_once_method(method), "{method}");
        }
    }

    #[test]
    fn unidentified_callers_are_refused_not_parked() {
        let git = methods::APPLY_CHECKOUT_GIT_ACTION;
        assert_eq!(
            admit_relay_caller(true, git, "", false),
            RelayAdmit::UnidentifiedCaller
        );
        assert_eq!(
            admit_relay_caller(true, git, UNKNOWN_CALLER, false),
            RelayAdmit::UnidentifiedCaller
        );
        assert_eq!(
            admit_relay_caller(true, git, "phone-1", false),
            RelayAdmit::NeedsApproval
        );
        // The earlier gates keep their answers.
        assert_eq!(
            admit_relay_caller(false, git, "", false),
            RelayAdmit::RemoteControlOff
        );
        assert_eq!(
            admit_relay_caller(true, methods::SET_AUTONOMY, "", true),
            RelayAdmit::LocalOnly
        );
        assert_eq!(
            admit_relay_caller(true, methods::LIST_HARNESSES, "", false),
            RelayAdmit::Allow
        );
        // A sandbox host approves every caller; identity is not asked.
        assert_eq!(admit_relay_caller(true, git, "", true), RelayAdmit::Allow);
    }

    #[test]
    fn each_refusal_names_its_case_the_host_and_the_device() {
        let text =
            |admit, once, host, device| relay_refusal_text(admit, once, host, device).unwrap();
        assert_eq!(
            text(
                RelayAdmit::RemoteControlOff,
                true,
                Some("Studio Mac"),
                Some("Pocket")
            ),
            "Remote control is off on Studio Mac. On Studio Mac, turn on Settings → Devices → \
             Allow remote control, then try again."
        );
        assert_eq!(
            text(
                RelayAdmit::NeedsApproval,
                true,
                Some("Studio Mac"),
                Some("Pocket")
            ),
            "This action from Pocket needs approval on Studio Mac. On Studio Mac, open \
             Settings → Devices and choose Allow once or Always allow, then try again."
        );
        assert_eq!(
            text(
                RelayAdmit::NeedsApproval,
                false,
                Some("Studio Mac"),
                Some("Pocket")
            ),
            "This action from Pocket needs approval on Studio Mac. On Studio Mac, open \
             Settings → Devices and choose Always allow, then try again."
        );
        assert_eq!(
            text(
                RelayAdmit::UnidentifiedCaller,
                true,
                Some("Studio Mac"),
                None
            ),
            "This action wasn't run: Studio Mac couldn't tell which device sent it, so it \
             can't be approved. Update Harness on this device, then try again."
        );
        assert_eq!(
            text(RelayAdmit::LocalOnly, true, Some("Studio Mac"), None),
            RELAY_LOCAL_ONLY
        );
        // Unnamed rows fall back to words the reader can place.
        let unnamed = text(RelayAdmit::NeedsApproval, true, None, Some("  "));
        assert!(unnamed.contains(RELAY_DEVICE_FALLBACK), "{unnamed}");
        assert!(unnamed.contains(RELAY_HOST_FALLBACK), "{unnamed}");
        assert_eq!(
            relay_refusal_text(RelayAdmit::Allow, true, None, None),
            None
        );
    }

    #[test]
    fn the_request_digest_never_leaves_this_computer() {
        let item = RemoteApproval {
            id: "a1".into(),
            kind: "rpc".into(),
            device_id: "phone-1".into(),
            chat_id: None,
            command_id: None,
            method: Some(methods::APPLY_CHECKOUT_GIT_ACTION.into()),
            summary: "ApplyCheckoutGitAction from Pocket".into(),
            allow_once: true,
            request_digest: Some("secret-ish-digest".into()),
        };
        let wire = serde_json::to_value(&item).unwrap();
        assert_eq!(wire["allowOnce"], true);
        assert!(wire.get("requestDigest").is_none(), "{wire}");
        assert!(!wire.to_string().contains("secret-ish-digest"));
        // An item from an engine that predates `allowOnce` keeps the button.
        let old: RemoteApproval = serde_json::from_value(serde_json::json!({
            "id": "a1", "kind": "rpc", "deviceId": "phone-1", "summary": "s",
        }))
        .unwrap();
        assert!(old.allow_once);
        assert_eq!(old.request_digest, None);
    }

    #[test]
    fn remote_run_parks_until_opt_in_or_approval() {
        assert_eq!(
            admit_remote_command("host", "phone", "run", false, false, false),
            RemoteCommandAdmit::NeedsApproval
        );
        assert_eq!(
            admit_remote_command("host", "phone", "run", true, false, false),
            RemoteCommandAdmit::Execute
        );
        assert_eq!(
            admit_remote_command("host", "phone", "run", false, true, false),
            RemoteCommandAdmit::Execute
        );
        assert_eq!(
            admit_remote_command("host", "phone", "run", false, false, true),
            RemoteCommandAdmit::Execute
        );
        assert_eq!(
            admit_remote_command("host", "host", "run", false, false, false),
            RemoteCommandAdmit::Local
        );
        assert_eq!(
            admit_remote_command("host", "phone", "interrupt", false, false, false),
            RemoteCommandAdmit::Execute
        );
    }
}
