# Context usage

Every selected conversation whose agent reports a context window has a context
ring at the right of its composer footer, including project-less and remote
conversations (`apps/nano/src/view_context.zig`). The ring stays muted, turns to
the warning color at 75% and the danger color at 90%; its drawing clamps at a
full circle while the label keeps over-capacity measurements. In a narrow split
footer it shows the ring without the percentage. An agent that reports no window
gets no ring at all.

Resting the pointer on the ring for half a second opens the context card:
its "Context" heading, the count against the window, a 62-segment bar split by
what fills it (chat history or its summary, files, commands and "System & other", estimated from
the transcript since its last compaction and scaled to the reported total), its
legend, a status line, the prompt cache share when known, graff's savings meter
and the exact numbers (`apps/nano/src/context_window.zig`).

The host normalizes context occupancy separately from billing `Usage` events:

| Harness | Measurement |
| --- | --- |
| Claude Code | Latest parent assistant message's input plus cache-read/cache-creation tokens; capacity from that model's result metadata. Aggregate result billing and child agents are excluded. |
| Codex | Latest model call (`tokenUsage.last`), with `modelContextWindow`; never the cumulative thread total. |
| OpenCode | Latest parent assistant message's total, or input/output/cache counts; capacity from the advertised provider/model catalog. Empty in-progress placeholders do not clear a measurement. |
| ACP (Devin, Grok, Hermes, pi) | `usage_update.used` and advertised capacity when the agent reports them. |
| Cursor | The pinned SDK exposes billed per-turn counts, not context occupancy. The shared control shows unavailable. |
| Mock / older hosts | Unavailable until a context snapshot is supplied. |

`AgentEvent::ContextUsage` updates one atomic `meta.contextUsage` value in the
session document. Partial measurements preserve known fields; a zero capacity is
ignored. New non-resumed runs clear old usage. Post-turn updates can refresh the
snapshot without reopening a completed turn, and subagent events cannot change
the parent meter.

The existing document sync carries the value through the relay and local storage.
`WatchDocMessages` includes a typed `TranscriptUpdate` envelope with the snapshot,
including context-only commits and the opening reset. Old readers ignore the
additive field; old hosts decode as unavailable. Thin-document rebuilding also
preserves the snapshot. UI rendering reads the in-memory state, with no polling,
provider calls, filesystem access, or new remote endpoint.

Validation covers adapter normalization, compaction to zero, cache accounting,
subagent isolation, snapshot and incremental import, thin rebuilds, context-only
watch updates, reconnects, and old/new watch compatibility. The desktop ring and
card are tested in `apps/nano/src/tests_ui_chat_context.zig`.
