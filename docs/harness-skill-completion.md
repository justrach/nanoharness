# Commands and skill completion across harnesses

## Workspace commands

Every harness gets Harness actions in the `/` picker. Selecting one runs the action
immediately; it does not create a model turn. Actions that require a conversation
are shown only in an existing chat.

| Command | Action |
| --- | --- |
| `/model` | Choose agent, model and reasoning |
| `/new` | Start a new session |
| `/resume` | Resume a Harness session |
| `/settings` | Open Harness settings |
| `/help` | Show keyboard shortcuts |
| `/custom-theme` | Create or pick a custom theme and animated backdrop |
| `/zen` | Toggle Zen / Developer workspace mode |
| `/design` | Toggle Design mode (Paper canvas) |
| `/diff` | Open changes (in a chat) |
| `/files` | Open files (in a chat) |
| `/terminal` | Open terminal (in a chat) |
| `/rename` | Rename this session (in a chat) |
| `/stop` | Stop the current run (in a chat) |

The list is `native` in `apps/nano/src/composer_completion.zig`.

Provider commands remain available alongside these actions. When a provider owns
the same name, its command keeps the name and the Harness action gets a `harness:`
prefix, for example `/harness:model`. Until the provider's catalog has loaded,
every Harness action uses the `harness:` prefix. A provider command and a workspace action are
distinct entries, even when they have the same purpose. `/` completion works at
any word boundary in the draft, including later lines.
Code, URLs and paths remain literal.

Selecting a workspace action consumes only its trigger, preserving surrounding
text, attachments and queued edits. Provider
commands and skills insert references into the draft and are delivered on Send;
provider command execution still follows its protocol's leading-command rules.
Typing an unselected inline `/word` does not execute a local action.

| Harness | Additional provider commands |
| --- | --- |
| Codex | Native `/compact` and `/review` |
| Claude Code | Project-scoped commands from its initialize catalog |
| OpenCode | Project-scoped server command catalog |
| Pi | Native `get_commands`, including extension commands and `skill:*` invocations |
| Devin, Grok, Hermes, Antigravity | Advertised ACP commands, including session command updates |
| Cursor | Workspace actions; its SDK adapter has no native command catalog |

This does not imply that every command in a provider's terminal UI can execute
through its SDK. Provider-only operations without a corresponding protocol or
Harness action are not advertised as executable commands.

## Skills in the pickers

Skills are offered after both `/` and `$`. A `$` followed by a digit is not a
trigger, so prices stay text. Selecting a skill stores its identity in the
composer; literal dollar signs, code, and unselected text keep their meaning.
Settings → Shortcuts → Composer completion has no per-agent switches.

## Discovery and delivery

Discovery runs on the selected host in the project directory. Codex uses its
native skill catalog. Other adapters discover standard project and user skill
directories, including shared `.agents/skills` directories. Claude checks native
command availability; OpenCode adds skills from its server command catalog.
ACP adapters bind discovered skills to advertised commands, and Pi also exposes
advertised `/skill:name` entries without a local file.
Shared `.agents/skills` files use explicit file delivery in Claude and generic ACP
catalogs: a matching built-in command name does not establish skill identity.
Pi's `skill:` namespace and OpenCode's skill source metadata identify native skills
explicitly and remain eligible for native delivery.

At delivery, Codex receives typed skill inputs. A leading skill selection with a
native command for the current harness becomes that command, preserving its
arguments. Other selections include an explicit skill reference in the prompt.
Native command metadata is scoped to its harness, so switching agents does not
invoke another agent’s same-named command.

File discovery covers the standard directories implemented by each adapter;
custom plugin paths and provider configuration are exposed where the native
catalog provides them. It is not a complete parser of every provider’s config.
Unreadable files, directories, and directory entries are skipped with diagnostics
so an unrelated skill root cannot suppress valid results.

Hosts advertise `composer-references-v1` for canonical reference delivery.
Selecting a provider command for an older host inserts literal slash text.
Sending an existing file, command, or skill chip to an unsupported host asks the
user to update that device and preserves the draft and attachments; the same
check applies when committing an edited queued message. Literal code examples
do not require this capability.

Provider references:

- [Claude Code skills](https://code.claude.com/docs/en/skills)
- [OpenCode skills](https://opencode.ai/v2/docs/skills)
- [OpenCode command source and skill classification](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/command/index.ts)
- [Cursor skills](https://prod.cursor.com/docs/skills)
- [Grok skills](https://docs.x.ai/build/features/skills-plugins-marketplaces)
- [Hermes skills](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills)
- [Pi skills](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md)
