# ACP v2 Preview — draft #267 test plan

This is retrospective independent test authorship, permitted by the maintainer for this draft only. The implementation and existing Rust/Zig tests were already present at `941527e1`; the independent scene and baseline runs came afterward. Baseline: `19e314f1`. All inputs are synthetic.

| ID | User or caller | Then | Layer | Test |
|---|---|---|---|---|
| ACP-1 | Opens a Codex row menu, then a Graff row menu; enables Preview, then opens the Graff menu again | No Preview control for Codex; Graff offers **Try ACP v2 Preview**, then **Use ACP v1** | Offscreen | `acp-v2-preview-menu.json` |
| ACP-2 | Enables Preview for one Graff chat, toggles it off and back on, edits reasoning and sends | Only that chat changes; the send and config edit retain Preview, sandbox and service tier | UI tree / state | `ACP Preview is opt-in for one Graff chat and survives config edits and send` |
| ACP-3 | Runs legacy by default or selects Preview with an unsupported agent; alternates selections through one adapter | Default/fallback submits once; one request does not opt in the next | Wire / rules | `preview_default_and_fallback_each_submit_once`; `preview_selector_is_per_request_on_one_adapter` |
| ACP-4 | Prompts a Preview agent with typed setup; ACK and foreground completion are independent | Setup uses negotiated methods; receipt alone is not completion | Wire / rules | `preview_ack_and_foreground_are_independent_with_typed_setup` |
| ACP-5 | Loses the transport before delivery is known, then reconnects | No silent fallback or automatic resend; the same intended submission retains its key | Wire / failure / state | `preview_uncertain_delivery_does_not_fallback_or_retry_and_key_survives_reconnect` |
| ACP-6 | Retries an older keyed turn after another turn; receives saved success, cancel, error, or a live completion | Exactly one terminal result for the requested turn; no inference from the newer resume snapshot or replay completion; non-Graff refusal remains an error | Wire / failure / state | `preview_retry_outcome_is_correlated_and_finishes_once` |
| ACP-7 | Reattaches while a required replay barrier is withheld | Does not submit early or invent completion; child markers do not satisfy root replay | Wire / reducer | `preview_requires_each_replay_barrier_before_submission`; `replay_barriers_follow_the_reporting_session_not_the_root`; `replay_loss_and_missing_markers_do_not_invent_state` |
| ACP-8 | Interleaves chunks, patches by ID, sends a malformed update or supplies a terminal snapshot | Ownership and addressing stay session-local; malformed updates do not partially mutate state; terminal snapshot replaces chunks | Reducer / rules | `ownership_requires_announcement_and_ids_are_session_local`; `interleaved_chunks_patch_by_id_and_malformed_updates_are_atomic`; `terminal_snapshots_replace_independently_decoded_chunks` |
| ACP-9 | Clicks into a child from either direction of a handoff, or presents a mismatched child key/ref or foreign interaction | Only the owned child opens, read-only; no forwarding or child steer; closing preserves parent selection, draft, attachment and scroll; a colliding tool ID in another session does not confer ownership | Wire / refusal / UI state | `preview_session_message_parent_to_child`; `preview_session_message_child_to_parent`; `preview_scope_separates_tool_ids_and_rejects_foreign_interaction`; `ACP Preview communication links open only the associated local child` |
| ACP-10 | Opens then closes a child pane while the worker is running, then sends the parent draft | Watch lifetime is separate from run lifetime; the next prompt targets the parent only | UI tree / state | `ACP Preview read-only child pane keeps the running worker and parent composer separate` |
| ACP-11 | Receives child activity before or after its actual request, or receives stale/unauthorized activity or elicitation | One matching transient notice; stale or unauthorized activity does not show, child input is not solicited, and child permission is not granted | Wire / refusal | `preview_child_activity_matches_real_requests_in_either_order`; `preview_status_stale_unauthorized_and_elicitation_are_fail_closed` |
| ACP-12 | Receives recovery or child attention, then status clears | Shows only live, owned recovery and transient attention; clears without adding transcript entries or claiming success | Wire / UI tree | `preview_reports_only_live_owned_network_recovery`; `ACP Preview transient status is shown and clears without transcript changes` |
| ACP-13 | Stops foreground work or cancels a particular child tool | Foreground stop is session-scoped and remains separate from targeted tool cancellation | Wire / refusal | `preview_foreground_cancel_is_session_scoped`; `preview_targeted_tool_cancel_keeps_foreground_stop_separate` |
| ACP-14 | Exercises Preview menu, recovery/attention and communication in Codegraff Light/Dark, normal/fullscreen | One truthful label/action per surface; menu switches protocol, attention clears, child opens read-only and the parent draft stays put | Offscreen matrix | `before/after × light/dark × normal/fullscreen × menu/status/communication` (local fixture scenes) |

## Design checks

1. **Works:** ACP-1/2 cover the control and the send path consuming its setting; ACP-9 covers the child destination.
2. **Truthful labels:** ACP-1/2/12 cover labels as protocol or activity changes.
3. **One action per surface:** ACP-14 compares the menu/row and their changed states; exact control counts are not asserted by the text-based checks.
4. **Helpful errors:** ACP-5/6/7 cover unknown delivery, saved errors and blocked replay; no blind retry. This is not a full error-copy review.
5. **State stays put:** ACP-2/6/9/10 cover config edits, reattach and pane navigation; not a native app restart test for every draft, attachment or scroll field.
6. **Native text:** no new selection or clipboard behavior; native text gestures not requalified here.
7. **Markdown/math:** no renderer change; not requalified here.
8. **Honest status:** ACP-4/5/6/7/12 distinguish receipt, replay, transient status and terminal result.
9. **Normal/fullscreen:** ACP-14 uses Nano's fullscreen shortcut offscreen, not an OS window transition.
10. **Synthetic and reproducible:** ACP-1 is a stock snap scene. ACP-14 uses synthetic local-only snap inputs; no evidence files or private interop assets are committed.

## Reproduction and scope

```sh
scripts/heavy-build.sh cargo test --offline -p harness-adapters --test acp preview_
scripts/heavy-build.sh cargo test --offline -p harness-adapters --lib acp::preview
(cd apps/nano && ../../scripts/heavy-build.sh zig build test-build -Dtest-filter='ACP Preview')
apps/nano/zig-out/bin/test
(cd apps/nano && ../../scripts/heavy-build.sh zig build snap -- scenes/acp-v2-preview-menu.json ../../target/acp-preview-menu)
```

- The same menu scene runs on both revisions. On `19e314f1`, both row menus open and the Codex refusal assertion passes; the test then fails because **Try ACP v2 Preview** is not drawn for Graff. On `941527e1`, it reaches **Use ACP v1** and saves both frames.
- The same synthetic normal Light candidate status and communication scenes also ran on the baseline using fixture-only snap hooks to supply progress and reveal the tool group. The baseline fails at **Recovering agent connection** and **Agent communication**, respectively. These are runtime view assertions, not build failures. The candidate passes both. The before/after matrix uses revision-specific expectations for capturing the expected surfaces, not as a substitute for these same-assertion red/green runs.
- The candidate passed 14 adapter integration tests, five reducer unit tests and four named UI-tree tests. The adapter integration and filtered Zig test binaries, and the menu snap scenario, each passed 20 consecutive runs.
- The existing adapter and UI-tree suites are candidate coverage; these baseline trials do not claim that every candidate test was backported or that the Graff reconnect regression was demonstrated on `19e314f1`. Real Graff reconnect evidence and the breaker's mutation/attack results are separate from this test-author run.
