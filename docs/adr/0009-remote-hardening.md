# ADR 0009: Device-bound remote control, signed updates, and optional E2EE

- Status: Accepted
- Date: 2026-11-25

## Context

PR #179 turns the device-room host ControlRpc surface off until the user opts
in. Remaining audit findings: chat2 `drain_commands` still ran peer commands
unconditionally; ControlRpc trusted `?device=`; ApplyUpdate / SetAutonomy were
reachable on the relay once remote control was on; update manifests were
SHA-256 only; access tokens lasted 55 minutes and a stolen
`HARNESS_AUTH_SIGNING_KEY` could mint them; the edge stored plaintext Loro
bytes; new installs defaulted autonomy to FullAccess.

## Decision

1. **Chat2 drain.** Remotely issued Run/Steer (`issued_by` ≠ this computer)
   are `TurnOrigin::Peer` and execute only when remote control is on **or**
   the user approves locally (Settings → Devices chip). Interrupt and
   question answers still drain so a phone can stop a turn it started.

2. **First ControlRpc action.** Even with remote control on, QueueCommand,
   file writes, terminals, and similar first-execution methods park until
   this computer approves that caller. `SetRemoteControl`, `SetAutonomy`,
   `ApplyUpdate`, `ApplyHarnessUpdate`, `SetE2ee`, and the approval RPCs
   themselves are never served on the host relay.

3. **Device identity.** Each engine mints an Ed25519 + X25519 pair
   (`{data_dir}/device-keys.json`, 0600), reusing ADR 0005 wrap
   (ephemeral X25519 + HKDF + XChaCha20-Poly1305). Chat2 rows and ControlRpc
   payloads may carry `H2S1` / `H2E1` envelopes. The edge attributes a push
   to `envelope.deviceId` when present and ignores `?device=` for those
   rows. Unsigned legacy rows still use `?device=` so existing iOS clients
   keep working. `HARNESS_REQUIRE_DEVICE_AUTH=1` fail-closes on unsigned
   mutating pushes.

4. **Signed manifests.** `ApplyUpdate` verifies an Ed25519 `sig` over
   `manifestMessage(version, files)` then the existing SHA-256. The public
   key is baked as `release_verify_key` in `apps/nano/src/updates_host.zig`.
   Generate and rotate with `scripts/gen-release-key.py`. Never commit the
   private key. Tests that predate signing set `require_manifest_sig = false`;
   production stays true. **Rach must generate a production key, paste the
   public bytes into `release_verify_key`, and sign GitHub `manifest.json`
   before the first signed release.**

5. **Auth.** Access tokens last **15 minutes**. Optional
   `HARNESS_AUTH_ED25519_PRIVATE` (PKCS8 PEM) issues EdDSA tokens; HS256
   remains until that secret is set. Device signatures on mutating frames
   mean a stolen HMAC secret is routing-only once clients enroll.

6. **E2EE (flagged).** `HARNESS_E2EE=1` or Settings `SetE2ee` seals new
   chat2 rows and ControlRpc payloads with the per-workspace key wrapped to
   each enrolled device. The edge stores ciphertext + wrapped keys only.
   Existing unsigned / unencrypted rows stay readable (migration). iOS can
   sign (`DeviceCrypto.swift`) but does not yet unwrap workspace keys or
   open `H2E1`. Device revoke rotates the workspace key and re-wraps the
   remainder (same as ADR 0005 §10). Full client wrap of every ChatClient
   push and HostRelay frame is still behind the flag.

7. **Autonomy.** A missing `harness-prefs.json` (new install) stamps
   Workspace and `autonomyIsDefault`. Existing files without the key stay
   FullAccess. `SetAutonomy` clears the default flag.

## Consequences

- iOS composer works after the user opts in on the computer; without opt-in
  a chip appears instead of a silent run.
- GitHub releases without `sig` will not install on production builds once
  this ships. Sign them before tagging.
- E2EE migration: mixed plaintext/ciphertext logs are allowed until every
  enrolled device speaks `H2E1`. Do not enable `HARNESS_REQUIRE_DEVICE_AUTH`
  until iOS wraps pushes.
