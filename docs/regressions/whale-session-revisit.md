# Whale session blank-on-revisit regression

Base: `c24e0e26` (main, v0.2.76). Verified on Linux with synthetic local data.

The engine half of the defect: `publish_messages_if_watched` checked the
receiver count and cleared the mirror outside the lock used by
`watch_messages`. A worker that observed zero receivers could mark dirty, let
attach rebuild and clear dirty, then overwrite that freshly published
transcript with an empty snapshot. A quiet document could remain empty until
the next change.

The engine now serializes receiver checks, clearing, attach, and
materialization under the same mutex (`crates/engine/src/doc_host.rs`).

## Before/after proof

The regression test was retained while the publication methods were
temporarily restored from the base commit. It failed:

```text
transcript_attach_and_unwatched_clear_share_a_critical_section ... FAILED
unwatched clear escaped attach's critical section
```

With the fix restored, it passes.

## Reproduce

```sh
cargo test -p harness-engine --lib transcript_attach_and_unwatched_clear_share_a_critical_section
```

## First-open follow-up: actual whale snapshot

The revisit fixes above did not address the first-open cost. A read-only copy of a
large local snapshot was profiled without connecting to the edge. No transcript content or snapshot is committed.
It contains 37,630 parts across just 16 joined messages (21,628,288 snapshot bytes).
The original 2,000-message fixture did not represent this shape.

Linux debug measurements before first paint (not a laptop or rendered-frame benchmark):

| Stage | Original full opening | New 128-part opening |
| --- | ---: | ---: |
| Snapshot file read | ~16 ms | ~16 ms |
| CRDT import | ~24 ms | ~24 ms |
| Transcript materialization | ~604 ms | ~2.2 ms |
| JSON encoding + decoding | ~1,007 ms | ~2.6 ms |
| Opening response | 16,414,959 bytes | 44,127 bytes |

The bottleneck is whole-history materialization and transfer before anything can
be displayed, not disk I/O. In addition, the viewport builds presentation rows
from the opening response; that rendering cost is not included in this probe.

The desktop (`apps/nano/src/requests.zig`, `watchDoc`) opts into
`WatchDocMessages { openingTail: true }`. The engine
reads the last 128 parts directly from local CRDT containers, preserving part
contents and continuation root IDs, and yields that provisional frame before
building the full mirror. The next frame is the ordinary complete reset, then
normal live deltas. Full snapshot opening/materialization runs on the blocking
pool. Nothing is
truncated in storage, and no remote response gates this local opening.

The provisional frame carries `historyPending: true`
(`apps/nano/src/transcript.zig` reads it). Clients that do not opt in retain
their existing full-reset protocol.

New engine tests prove the first opening arrives while full publication is
held blocked; every original part and a write between preview/attach appear in
the full reset; subsequent live deltas still arrive; and previews preserve
continuation IDs and leave the snapshot unchanged.

Reproduce the read-only timing comparison with an exported snapshot:

```sh
cargo run -p harness-engine --example transcript_load_probe -- /path/to/session.bin
```

The new path removes the full-history barrier to initial content. It does not
claim that reconstructing/rendering all 37,630 parts is instantaneous.
