# Agent-driven tests

New features here are built by agents. Agent-driven tests make the result hold:
one agent writes the tests, a second makes them pass, a third tries to break
them. This adds to "Tests every change carries" in [`AGENTS.md`](../AGENTS.md).

**When it applies:** every new feature, and every change to behaviour that
guards access or stores user state. A small fix keeps the existing rule (a test
that fails on `main`) and doesn't need three agents.

## Three roles, three agents

Each role is a separate agent. None sees another's reasoning, only what it
committed.

- **Test author.** Reads the request and the existing code, then writes the test
  plan and the tests before any implementation exists. Every test fails because
  the behaviour is missing, not because it doesn't compile: where a symbol must
  exist to compile, add the smallest stub that fails (a function that returns
  the wrong value or `error.Unimplemented`). Writes no behaviour.
- **Implementer.** Makes the tests pass. May add tests. May not weaken, skip or
  delete an assertion. If a test is wrong, stops and says which one and why; the
  test author, or a person, changes it.
- **Breaker.** Tries to break the result with a mutation pass and an attack
  pass (below). Every defect found becomes a failing test first, then a fix by
  the implementer.

## Sharing a machine

One worktree per feature; the roles use it one after another, never at once.
Every build goes through `scripts/heavy-build.sh`, one build per call: a script
that runs several builds inside one call holds the lock throughout and starves
every other worktree. To split the queue into lanes, give each lane its own lock
path in `HARNESS_HEAVY_BUILD_LOCK` (default `${TMPDIR:-/tmp}/harness-heavy-build.lock`).
A worktree's build caches cost gigabytes: remove a feature's worktree once its
branch is pushed, and don't copy the checkout for scratch builds.

## The test plan

One row per scenario: an id, what the user or caller does, what must then be
true, the layer, and the test's name. A reviewer checks the table against the
request without reading code. The test author commits it with the tests as
`docs/test-plans/<feature>.md`; a role that adds a test adds its row. For an
invented "snooze a chat" feature:

| Id | The user or caller | Then | Layer | Test |
|---|---|---|---|---|
| SN-1 | Snoozes a chat for one hour at 09:00 (injected clock) | Hidden at 09:59, shown again at 10:00 | rule | `snooze hides a row until its wake time` |
| SN-2 | Chooses **Snooze → 1 hour** on "Synthetic notes", opens another chat, comes back | The row stays out of the sidebar and **Snoozed (1)** shows | UI tree | `snooze ui row stays hidden across chats` |
| SN-3 | Snoozes while the engine is offline | Nothing changes; the error reads "Couldn't snooze Synthetic notes: the engine is offline" and offers **Retry** only | failure | `snooze offline names the chat and offers retry` |

## Layers a user-facing feature covers

- **Rules:** pure functions, tested as tables or generated cases. A rule several
  implementations share is a vector, as `AGENTS.md` says.
- **UI tree:** the real view code under nanoui's `ui.Tester` (see the
  `apps/nano/src/tests_ui_*.zig` files), not a copy of the layout.
- **End to end:** at least one scripted scene through `zig build snap`, with its
  picture. Scenes are JSON in `apps/nano/scenes/`; `expect` and `expectNot`
  steps fail the run. The format is at the top of `apps/nano/src/snap.zig`.
  Set `"surface": "opaque"`: the default frosted surface draws the window
  transparent in the PNG. A `{"press": "ctrl+cmd+f"}` step toggles real
  fullscreen, and `"uiMode"` picks `zen`, `developer` or `design`.
- **Failure paths:** each error names what failed, says why, and offers only a
  remedy that applies.
- **State:** survives moving between chats, tabs and panes, and a restart.
- **Refusals:** for anything that guards access, what must be refused is tested
  as carefully as what is allowed.
- **Performance:** a sensitive path gets a test of the shape with a generous
  ratio, as `AGENTS.md` already requires.

## Determinism

Injected clocks, seeded randomness, synthetic data, no sleeps, no network. Run
a new test twenty times before trusting it. One failure in twenty is a bug in
the test or the code; fix it, don't retry it.

## Mutation pass

The breaker mutates in the feature's worktree, not a copy. With the
implementation committed, change it one small step at a time, run the narrow
tests, note whether any failed, and `git checkout -- <file>` before the next
mutant. Never commit a mutant.
For the snooze feature, where `isHidden(now, wake)` is `now < wake`:

1. `now <= wake` (a bound shifted by one): SN-1 must fail at 10:00.
2. `now > wake` (the condition flipped).
3. `isHidden(wake, now)` for `isHidden(now, wake)` (two arguments swapped).
4. The offline check deleted, so the snooze is sent anyway (an error path removed).
5. `return false` at the top of `isHidden` (an early return; a branch dropped).

Record each as killed (a test failed) or surviving. A survivor gets a new test
that fails with the mutant and passes without it, or a written reason it is
**equivalent**: no input can tell the mutant from the original. Swapping
`i < len` for `i != len`, in a loop where `i` starts at 0 and only goes up by
one, is equivalent; "no test covers it" is not.

## Attack pass

Inputs and sequences the plan didn't list: empty, huge, non-ASCII and
right-to-left text; the same action repeated, and two at once; the engine
offline or slow; permission refused; a restart part way through; a narrow
window and a fullscreen one. Each defect is a failing test before it is fixed.

## What the pull request reports

The plan table; the mutation result as tried / killed / surviving, with each
survivor's reason; what the breaker found, and the test that now covers it; the
pictures, a normal window and fullscreen, light and dark where looks changed (a
scene's `"dark"` field and a `ctrl+cmd+f` step); the commands to re-run
everything; and what was not tested, and why.

## Commands

Nano from `apps/nano`, Rust from the repository root:

```bash
../../scripts/heavy-build.sh zig build test        # every nano test
../../scripts/heavy-build.sh zig build snap -- scenes/<scene>.json /tmp/<feature>-snap
scripts/heavy-build.sh cargo test -p <crate> <filter>   # e.g. -p harness-sync --test chat2_vectors
```

`zig build test -Dtest-filter="<text>"` runs the matching tests but may print
only some of their names. To see each test, build the filtered tests and run the
binary with its output piped; that also gives twenty runs without twenty builds:

```bash
../../scripts/heavy-build.sh zig build test-build -Dtest-filter="<text>"
zig-out/bin/test 2>&1 | cat    # one line per test: 1/3 <name>...OK
for i in $(seq 20); do zig-out/bin/test 2>/tmp/<feature>-run.log || break; done
```

## Briefs

Copy one, fill in the angle brackets, and hand it to a fresh agent.

```text
Role: test author for <feature>. Worktree: <worktree> (branch <branch>).
Read AGENTS.md and docs/agent-driven-tests.md first.
Request: <the request, verbatim>.
Write the test plan as docs/test-plans/<feature>.md: one row per scenario
(id, what the user or caller does, what must then be true, layer, test name).
Cover rules, UI tree, one snap scene, failure paths, state and, if it guards
access, refusals. Write the tests. Each must fail because the behaviour is
missing; add only the smallest stub that compiles and fails. Write no behaviour.
Synthetic data, injected clocks, no sleeps, no network.
Build only through scripts/heavy-build.sh, one build per call. Show each new
test failing. Commit the plan, tests and stubs. Don't push.
Report: the plan, each test's failure message, anything in the request unclear.
```

```text
Role: implementer for <feature>. Worktree: <worktree> (branch <branch>).
Read AGENTS.md, docs/agent-driven-tests.md and docs/test-plans/<feature>.md.
Make every test in the plan pass. You may add tests, and add their rows.
Don't weaken, skip or delete an assertion. If a test is wrong, stop and say
which one and why; don't change it.
Build only through scripts/heavy-build.sh, one build per call. Run the new
tests twenty times (zig build test-build -Dtest-filter=..., then
zig-out/bin/test in a loop). Run the snap scene and look at its pictures.
Commit. Don't push.
Report: what you changed, the test commands and their results, and any test
you think is wrong.
```

```text
Role: breaker for <feature>. Worktree: <worktree> (branch <branch>).
Read AGENTS.md, docs/agent-driven-tests.md and docs/test-plans/<feature>.md.
Mutation pass: one small change at a time in the working tree (flip a
condition, drop a branch, shift a bound by one, swap two arguments, remove an
error path, return early), run the narrow tests, git checkout -- <file> after
each. Never commit a mutant.
Attack pass: empty, huge, non-ASCII and right-to-left text; repeated and
concurrent actions; engine offline or slow; permission refused; restart part
way; narrow and fullscreen windows.
For each surviving mutant, commit a test that fails with the mutant and passes
without it, or write in the plan why the mutant is equivalent. For each defect,
commit a test that fails now, with its plan row. Don't fix the code.
Build only through scripts/heavy-build.sh, one build per call. Don't push.
Report: tried / killed / surviving with reasons, and each defect with its test.
```
