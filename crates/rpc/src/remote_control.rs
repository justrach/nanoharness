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
}

/// Error text when [`RelayAdmit::RemoteControlOff`].
pub const REMOTE_CONTROL_OFF: &str =
    "Remote control is off on this computer. Enable it in Settings → Devices.";

/// Error text when [`RelayAdmit::LocalOnly`].
pub const RELAY_LOCAL_ONLY: &str = "This action can only be done on the computer itself.";

/// Error text when [`RelayAdmit::NeedsApproval`].
pub const RELAY_NEEDS_APPROVAL: &str =
    "This remote action needs approval on the computer. Check Settings → Devices.";

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
            | methods::CREATE_WORKTREE
            | methods::DELETE_WORKTREE
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
