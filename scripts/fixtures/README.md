The `.jsonl` files are journals for `scripts/replay-claude.py`. Point the
Claude adapter's `CLAUDE_CODE_EXECUTABLE` at that script and
`HARNESS_REPLAY_JOURNAL` at a journal: it replays the journal's text and
reasoning deltas at a fixed cadence, with no network or API calls.
`HARNESS_REPLAY_DELAY_MS` sets the delay per delta (default 40) and
`HARNESS_REPLAY_REPEAT` repeats the stream (default 1).

`resource-stream.jsonl` contains sanitized deltas from a successful Haiku
profiling response: an 80-section Rust ownership tutorial with code fences.
Only text/reasoning deltas and the successful completion marker are retained;
account, session, timestamp and usage metadata are omitted.

The assistant text is 51,769 bytes, SHA-256
`c1809f92c26c682c6f035478f7ca63980e25fb5e97ea7746dcb41ecd7dbb0a25`.
Reasoning contributes another 853 bytes. The production transcript's part
separators bring the combined short reply to 52,624 bytes.

Use `HARNESS_REPLAY_REPEAT=10 HARNESS_REPLAY_DELAY_MS=8` for a synthetic long
workload.

`runway-short-stream.jsonl` is a synthetic short reply in 24-character chunks.
With a 400 ms replay delay it keeps the own-send runway active through
completion.

`transcript-selection-stream.jsonl` is a synthetic short reply in six-character
chunks. A 1200 ms replay delay leaves time to expand/collapse a long prompt and
select live text.

`markdown-preview/` holds one Mermaid source per diagram kind: class, ER,
flowchart, Gantt, sequence and state.
