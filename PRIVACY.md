# Privacy

NanoHarness does not ship PostHog, Sentry, or any other analytics/crash SDK in the desktop, engine, or iOS apps. Product telemetry is opt-in on desktop and on-by-default on iOS (see [defaults awaiting a maintainer decision](#defaults-awaiting-a-maintainer-decision)). This file lists every outbound call the product can make.

Killswitches, honored everywhere below:

| Variable | Effect |
| --- | --- |
| `DO_NOT_TRACK=1` (`true` / `yes` also work) | No product telemetry, no crash uploads, no telemetry IDs, no background update/catalog/npm pings |
| `HARNESS_OFFLINE=1` | Same as `DO_NOT_TRACK`, a no-network killswitch for product-initiated background calls |

User-initiated agent turns, signed-in workspace sync, and GitHub review are **not** blocked by these variables. They are the product. Set them in the process environment (`~/.harness/env` on a managed install, or the shell that launches Harness).

The shared rules live in [`protocol/privacy-killswitch.json`](protocol/privacy-killswitch.json). Rust, Zig, and Swift each run that file.

## Product telemetry

| Call | Where | Default | Data | Stopped by |
| --- | --- | --- | --- | --- |
| `POST https://otel.codegraff.com/v1/metrics` | Desktop (`apps/nano/src/perf_transport.zig`) | **Off** (Settings → Notifications → Privacy) | OTLP histograms: app version, OS type, CPU arch, renderer, pane-count band, frame timings. No account, path, prompt, hardware model, or install ID | Toggle off, `DO_NOT_TRACK`, `HARNESS_OFFLINE`, debug/hidden/test builds |
| `POST https://otel.codegraff.com/v1/metrics` | iOS (`PerfUpload.swift` / `PerfOTLP.swift`) | **On** (Settings → Diagnostics → Performance) | OTLP histograms: app/OS version, arch, refresh rate, timings/CPU/memory/disk. Per-launch `service.instance.id` only while sharing is allowed. No hardware model, account, prompt, or path | Toggle off, `DO_NOT_TRACK`, `HARNESS_OFFLINE`, DEBUG/simulator |
| `POST https://us.i.posthog.com/i/v0/e/?ip=0` | Marketing site only (`apps/landing/public/telemetry.js`) | On at `https://codegraff.com/` | Anonymous `$pageview` / `download_clicked`. `$geoip_disable: true`. No cookies or stored ID | Browser DNT / GPC |

There is **no** telemetry ID file. Desktop never writes one. iOS mints a random per-launch id in memory only while sharing is allowed; opt-out and `DO_NOT_TRACK` skip it.

`{data_dir}/device-id` is a **sync identity** (multi-device routing), not product telemetry. It is created for the local engine even when telemetry is off.

## Crash reporting

| Call | Where | Default | Data | Stopped by |
| --- | --- | --- | --- | --- |
| Local panic/stall logs in `~/.harness/logs` | Desktop (`crash_log.zig`) | On, **local only** | Stacks; no prompts or paths | Not uploaded |
| `POST /diagnostics/crash-reports` | iOS MetricKit → edge (`CrashReports.swift`) | **On** while signed in (Settings → Crash reports) | MetricKit JSON: code addresses, build, device type, OS version. Linked to the signed-in account | Toggle off, sign out, `DO_NOT_TRACK`, `HARNESS_OFFLINE` |

## Background update and catalog pings (not analytics)

These are version checks, not usage analytics. `DO_NOT_TRACK` and `HARNESS_OFFLINE` stop them. Existing env flags still apply:

| Call | Where | Default | Stopped by |
| --- | --- | --- | --- |
| GitHub `manifest.json` / latest release | Desktop app + `update-daemon` | On for eligible installs | `DO_NOT_TRACK`, `HARNESS_OFFLINE`; `HARNESS_AUTO_UPDATE=0` still disables auto-install |
| GitHub CodeGraff releases | Managed `graff` updater | Auto-install on | `DO_NOT_TRACK`, `HARNESS_OFFLINE`, `HARNESS_GRAFF_AUTO_UPDATE=0`, `GRAFF_EXECUTABLE` |
| GitHub codedb releases | Managed codedb | On | `DO_NOT_TRACK`, `HARNESS_OFFLINE`, `HARNESS_CODEDB_AUTO_INSTALL=0` |
| npm registry / GitHub for agent CLIs | `harness_updates` | On, every 6h | `DO_NOT_TRACK`, `HARNESS_OFFLINE` |
| npm adapter prewarm | `prewarm_managed_adapters` | On at engine start | `DO_NOT_TRACK`, `HARNESS_OFFLINE` |

## Signed-in product network (not telemetry)

These run only after the user signs in or otherwise asks:

- CodeGraff OAuth and `edge.codegraff.com` sync (chats, devices, vault)
- iOS APNs token registration (push)
- Provider APIs the user configured (Claude, Codex, OpenAI, …)
- GitHub API for the in-app review pane
- Flint weight downloads the user starts from Settings
- `edge/src/install.sh` and packaging scripts fetching GitHub release assets when the user (or a maintainer) installs or builds

Remote-control execution stays off by default and still requires local approval. This document does not change that.

## What we do not send

Product telemetry never includes prompts, replies, diffs, file paths, emails, MAC addresses, or hardware serials. iOS crash reports can include a device type string (needed to symbolicate); they are not sent when crash upload is off or a killswitch is set. PostHog on the marketing homepage disables GeoIP.

## Docs that were wrong

- `apps/ios/README.md` previously said performance sharing “starts off”. Release iOS builds default **on**; this file and the Settings copy match the code.
- `apps/parity/PERFORMANCE.md` previously said desktop kept a per-install `install_id` file. Desktop OTLP has **no** install ID.
- `docs/releases/v0.2.87.md` described desktop stats as opt-out. Current desktop stats are opt-in (`docs/desktop-responsiveness.md`).

## Defaults awaiting a maintainer decision

These would change what a new install does. They are **not** in this change:

1. iOS performance sharing: on-by-default → opt-in
2. iOS crash “Send to Harness”: on-by-default → opt-in
3. Marketing PostHog pageviews: on-by-default (DNT already honored) → require a cookie banner / fail-closed opt-in
4. Background update checks: on-by-default → opt-in (would also need a Settings toggle that stops the GitHub ping, not only auto-install)
5. Creating `{data_dir}/device-id` before the user enables sync
