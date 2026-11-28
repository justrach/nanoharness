# Streaming and startup hot paths

This pass covers the engine (`crates/engine`, `crates/doc`, `crates/sync`). It
starts at `92a4f49` on an M-series Mac with the `app-dev` profile (opt-level 2).
Each figure comes from a temporary `#[ignore]` benchmark run against the named
function, then removed. The code paths were found by reading the streaming,
publication and launch paths end to end. They were not profiled.

## Measured changes

| Path | Workload | Before | After |
| --- | --- | ---: | ---: |
| Boot stale-run scan (`RunJournal::stale_sessions`) | 31 real journals, 24 MB | 105.6 ms | 1.0 ms |
| Watched transcript publication (`read_entries_cached`), per commit | 2,000 messages × 2 KB, one message changed | 4.21 ms | 0.75 ms |

- **Journals.** Boot recovery only needs each journal's last event, but it
  parsed every journal in full. Journals are never compacted, so that cost grew
  with every chat ever run. It now reads backwards from the end in growing
  windows. Appends no longer clone each event to serialize it. The open-file
  cap now closes only the least recently written journal instead of all 16.
- **Publication.** Each streaming commit (about 8 per second) re-materialized
  the whole `messages` list through a Loro deep value, JSON and serde. The
  root-diff callback that already feeds `TranscriptHistory` now also
  invalidates per message container, so only changed messages are rebuilt.
  Any unobserved change (nobody watching) drops the cache.

## Unmeasured changes

- chat2 maintenance (tail sidecar upload and threshold checkpoint) waits for
  1 s of quiet, at most 15 s, instead of running about once a second while
  streaming. Legacy snapshots keep their 1 s cadence because they are the only
  persistence for legacy docs.
- The duplicate outbox insert per commit is gone (`enqueue_persisted_batch`).
- The engine's Ready no longer waits on the login-shell PATH probe:
  `prewarm_managed_adapters` runs on the blocking pool. `scutil` runs once
  instead of twice.
- `WATCH_QUEUE` and model-context resolution run on the blocking pool, not on
  async workers.

## Checked and left alone

- `SegmentWriter::sync` compares and copies the growing segment on every tick.
  That is linear per tick in memcpy terms and under 1 ms even for megabytes of
  tool output.
- Command and queue drains on every commit depend on turn state, time and
  attachments, so they cannot be gated on ledger changes alone. A drain costs
  about 0.1 ms.
