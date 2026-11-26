# Draft: NanoHarness trajectory sharing

**Status: proposal only.** NanoHarness does not collect or upload runs for this program. The Settings page is informational and has no opt-in control. This document is not the program terms or a representation that a provider permits sharing.

## Intended scope

A future, separately reviewed opt-in could cover eligible future NanoHarness sessions, including regular sessions using a customer’s own supported agent or model subscription. A trajectory could include prompts, responses, tool calls and results, outcomes, and eligible delegated-agent steps. The feature must remain off for every account unless all user, organization, provider, and server-side requirements below are met. No historical or pre-consent session data may be collected.

## Launch gates

- Obtain current, verifiable approval of versioned program terms from an authorized company administrator for managed workspaces. An employee’s checkbox alone is not company approval.
- Require a separate affirmative, initially unchecked user confirmation. For work: “My company has accepted the Trajectory Sharing Terms and authorized me to share these runs. I confirm that we have permission to share this material and that our subscription terms allow the stated uses.” Provide a distinct personal-use acknowledgment.
- Scope consent to the authenticated account and workspace, record the terms version, and fail closed for missing, stale, or unverifiable approval.
- Allowlist provider, subscription, model, and harness surfaces only after their applicable terms are reviewed for capture and the stated uses. An app opt-in cannot grant rights under a provider contract.
- Use an isolated authenticated receiver that derives identity from verified credentials and enforces consent, scope, provider eligibility, and revocation before accepting or storing any body. Never trust client-supplied account or consent headers as authorization.
- Keep collection independent from aggregate performance telemetry. Do not read vendor credentials, browser/session stores, arbitrary harness logs, private shell history, or raw model reasoning. Capture only supported visible app events; redact secrets; validate and bound payloads. No third-party onward sharing without separate authorization.
- On revocation, stop new capture, cancel queued uploads, and prevent pre-consent or out-of-scope records from upload. Define access, retention, deletion, backups, and treatment of data already used for training in reviewed terms before launch.
- Publish reviewed disclosure and terms before enabling the feature. Standard Harness remains responsible for its own handling and legal obligations; user representations do not replace those obligations.
