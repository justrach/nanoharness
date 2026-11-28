# Shared app rules

Rules and copy the iOS app must keep live here as data. The SwiftUI app is the reference: each file's expected
values are what it does. Where the desktop client (`apps/nano`) or the engine applies the same rule, it runs its
own test against the same file, read from the repository at test time, so no side can drift without a test failing.

| File | What it pins | iOS runs it in | Desktop and engine run it in |
| --- | --- | --- | --- |
| `vectors/message-queue.json` | queue labels, one-line text, moves, host-action results, edit leases | `ParityTests.swift` | |
| `vectors/account-deletion.json` | every answer the edge can give and the exact message shown | `ParityTests.swift` | |
| `vectors/home-grouping.json` | project and device sections, the Pinned section | `ParityTests.swift` | |
| `ux-contract.json` | user-visible strings and the queue panel's layout numbers | `ParityTests.swift` | |
| `vectors/agent-readiness.json` | when an agent counts as brought in (Graff, Claude Code, OpenAI Codex on an online computer), and the download link | `ParityTests.swift` | |
| `vectors/run-errors.json` | which run errors read as signed out, limit reached or a rejected API key, and their labels and buttons | `ParityTests.swift` | `crates/proto/src/run_errors.rs`, `apps/nano/src/run_errors.zig` |
| `vectors/restart-notices.json` | which historical error parts are neutral update/restart recovery notices rather than failures | `TranscriptPresentationTests.swift` | `crates/doc/src/restart_note.rs`, `apps/nano/src/run_errors.zig` |
| `vectors/registry-projection.json` | which registry rows become devices, projects, sessions and pins, with their defaults and order | `ParityTests.swift` (through `WorkspaceStore`) | |
| `vectors/transcript-decode.json` | how a session doc's messages, parts and queue rows decode, and which ones are dropped | `ParityTests.swift` (through `SessionStore`) | |
| `vectors/cloud-sandbox.json` | how a cloud sandbox list reads: row titles, details and buttons, hourly rates, size choices, the running summary, and which size a create names (iOS uses the same rules for computer-relayed Settings and the phone's direct gateway path) | `ParityTests.swift` | `crates/engine/src/codegraff_auth/sandboxes.rs`, `apps/nano/src/parity_sandboxes.zig` |
| `vectors/chat-mode.json` | chat mode's auto tiers (order, names, the older-gateway stand-in), when a chat can start, the model a new chat starts on, and the cost and unavailable notes | `ParityTests.swift` | |
| `vectors/composer-stop.json` | how long the composer ignores Stop after a question panel gives way to it | `ParityTests.swift` | |
| `vectors/localhost-pages.json` | which addresses open on the phone as a page its computer renders, and the address that computer's browser opens | `ParityTests.swift` | `crates/engine/src/localhost_view/url_rule.rs` |
| `vectors/presence-rule.json` | what the phone may say about another device's presence, and when that can next change | `ParityTests.swift` | |
| `perf-contract.json` | the operations the performance monitor times, their budgets, and the Performance page copy | `ParityTests.swift` | |
| `vectors/perf-stats.json` | the `harness.mobile.stats.v1` upload body (see [PERFORMANCE.md](PERFORMANCE.md)) | `ParityTests.swift` | |
| `vectors/theme-import.json` | what a VS Code theme import produces, byte for byte | | `apps/nano/src/theme_import.zig` |
| `apps/ios/Harness/Theme/themes.json` | the iOS theme catalog | `ThemeStoreTests.swift` | |

`vectors/annotations.json` has no runner.

## Adding a rule

1. Add cases to a file in `vectors/`, working out the expected value from the iOS behavior.
2. Add the check to `ParityTests.swift` and run it: `xcodebuild test -only-testing:HarnessTests/ParityTests`.
3. If the desktop client or the engine applies the same rule, add a runner there too. Zig tests read the file
   through `@import("parity_options").vectors_dir` (see `apps/nano/src/parity_sandboxes.zig`) and run with
   `cd apps/nano && zig build test`; Rust tests read it by relative path (see
   `crates/engine/src/localhost_view/url_rule.rs`).

`parity.yml` runs `ParityTests` and `Chat2VectorTests` on a macOS runner. The Zig runners are part of
`zig build test`, and the Rust runners are ordinary unit tests in their crates.

A new piece of user-visible copy goes in `ux-contract.json`. The test checks that each string appears as a quoted
literal in the SwiftUI sources, which catches a reworded label.

## What this does not cover

It checks rules, copy and a few layout numbers. It does not compare pixels, animation, or how a screen feels, so
visual parity still needs eyes on each app. It also assumes a rule is reachable as a pure function or a model
call: behavior that only exists inside a view has to be pulled out before it can be pinned here.
