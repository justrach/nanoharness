# Antigravity over ACP

Harness uses Antigravity's native `agy acp` entry point when the `agy` CLI is installed. The existing Antigravity agent identity, chats, model picker, sign-in and permission handling are retained; this is not a second provider.

## Setup and resolution

1. Install or update the Antigravity CLI using its original installation method.
2. Confirm `agy acp --help` works. Native ACP was verified with CLI 1.5.7; older CLIs without this subcommand need updating.
3. Enable Antigravity in **Settings → Agents**, or on a headless host by editing prefs / setting `HARNESS_OPTED_IN` (below), then use Sign in if required.

Explicit `ANTIGRAVITY_ACP_EXECUTABLE` overrides take precedence. Point it to the executable, not a command string. Native executables named `agy` / `agy.exe` receive the `acp` subcommand. Custom legacy ACP servers receive the existing server arguments. Without an override, native `agy` takes precedence over a legacy `agy_acp_server` on PATH or a previously installed managed archive. Detection does not log in, start a session, or download an adapter.

Settings' Install action remains available for the pinned legacy ACP archive on supported platforms. Existing legacy installations and custom server overrides continue working. Harness does not automatically install a replacement CLI or enable permission-skipping flags.

## Headless Linux

Antigravity is **off by default**. A desktop turns it on in Settings → Agents. A Linux server with no desktop does the same by writing the prefs file, or by an env / CLI overlay that is **not** persisted.

### Prefs path and key

| | |
| --- | --- |
| File | `{data_dir}/harness-prefs.json` |
| Default data dir (Linux / macOS) | `~/.harness` (legacy `~/.harnesser` only if it already exists) |
| Override | `HARNESS_DATA_DIR`, then the older `DATA_DIR` |
| Windows default | `%LOCALAPPDATA%\Harness` |
| Key | `optedIn` — JSON array of kebab-case agent ids |
| Remote control | `remoteControl` (boolean, **off** unless the file says `true`; not an env flag) |

Example that enables Antigravity when `agy` is installed, without turning on remote control:

```json
{"optedIn":["antigravity"]}
```

A string (`"optedIn": "antigravity"`) or a comma-separated string is accepted. A boolean `true` is ignored for this key and does **not** discard the rest of the file.

### Env and CLI (not persisted)

```sh
# one-shot
harness headless --opt-in antigravity

# or, for a systemd user unit (EnvironmentFile already points here):
echo 'HARNESS_OPTED_IN=antigravity' >> ~/.harness/env
```

`HARNESS_PROVIDER=antigravity` also opts Antigravity in for that process (it already selected it as the default harness). Repeat `--opt-in` or comma-separate `HARNESS_OPTED_IN`. `harness daemon install` captures `HARNESS_OPTED_IN` into the unit when it is set.

### Finding `agy` with no desktop

Detection looks on `PATH`, the login shell's `PATH`, and well-known bins that a systemd unit's minimal `PATH` otherwise misses: `~/.local/bin`, `~/.antigravity/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, `/opt/Antigravity/bin`. Override with `ANTIGRAVITY_ACP_EXECUTABLE` if the binary lives elsewhere. There is no GUI or display requirement.

`harness daemon install` captures `ANTIGRAVITY_ACP_EXECUTABLE`, `GEMINI_HOME` and `GEMINI_API_KEY` when they are set. You can also put them in `~/.harness/env` (the systemd unit already loads that file).

### Sign-in on a host with no browser

agy 1.5.17 sends the Google OAuth URL to `$BROWSER` rather than stdout. Headless login uses a recording shim so `PollAgentLogin` can show the URL, and `CompleteAgentLogin` pastes the code into `agy acp --login` — the CLI's `127.0.0.1` callback is not reachable from another machine.

Settings live in `$GEMINI_HOME/antigravity-cli/settings.json` (agy 1.5.17) with `$GEMINI_HOME/antigravity-acp/settings.json` as the older ACP path (`GEMINI_HOME` defaults to `~/.gemini`).

## Questions

Harness advertises `clientCapabilities.elicitation.form` to Antigravity at `initialize`. With it, `agy` sends its `ask_question` tool as an `elicitation/create` form, and the question opens Harness's question picker. Without it, `agy` writes the questions into its reply as `- [1] …` rows.

The form shape was verified with `agy` 1.5.14:

- Each question is a property `qN` titled with the question. A single choice is a string with titled `oneOf` `{const, title}` entries. A multiple choice is an `array` whose `items` are titled `anyOf` entries.
- Each question also has an optional `qN_other` write-in, and the form has no `required` list.
- In the picker, each question is one page. A pick answers `qN` with the choice's `const`; typed text answers `qN_other`.

Older CLIs and the legacy `agy_acp_server` that don't read the capability keep asking in chat.

## Update checklist

- Resolve the exact executable used by sessions before checking its version.
- Native `agy` / `agy.exe`: read `--version`; run that same executable with `update` only after an explicit update request.
- Do not invent `update --check` or `--yes`: the verified CLI does not document them. Without a non-mutating latest-version query, distinguish a check-and-update action from a confirmed available update.
- Legacy or custom ACP servers: show manual instructions; never send `update` to an arbitrary server or update its containing Homebrew package by inference.
- Keep active-run scheduling, cancellation and post-update version verification in the shared updater pipeline.

## Verification

Synthetic ACP fixtures exercise native discovery and a complete turn through `agy acp`, explicit overrides, native-before-legacy precedence, legacy server arguments and missing/partial installations. The native `initialize` handshake was also checked with a disposable home, telemetry disabled, no account credentials and no provider prompt. It advertised ACP version 1 and `oauth-personal` among its authentication methods. This does not constitute a signed-in live-model turn or physical Windows execution.
