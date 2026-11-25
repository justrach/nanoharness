<p align="center">
  <img src="dist/macos/icon-1024.png" width="112" height="112" alt="NanoHarness app icon">
</p>

<h1 align="center">NanoHarness</h1>

<p align="center">
  <strong>Run your coding agents, review their diffs, and ship from one native workspace.</strong><br>
  Built in Zig on <a href="https://github.com/justrach/nanoui">nanoui</a>.
</p>

<p align="center">
  <strong><a href="https://github.com/justrach/nanoharness/releases/latest">Download NanoHarness</a></strong> ·
  <a href="#download-with-curl">Download with curl</a>
</p>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.hindi.md">हिन्दी</a> ·
  <a href="README.thai.md">ไทย</a> ·
  <a href="README.indo.md">Bahasa Indonesia</a> ·
  <a href="README.malay.md">Bahasa Melayu</a>
</p>

<p align="center">
  <img src="docs/media/readme/nanoharness-github-light.png" width="960" alt="NanoHarness with an agent chat beside the GitHub pull request review pane">
  <br><sub>Review a pull request without leaving the agent conversation. Synthetic example.</sub>
</p>

## Get started

### Prebuilt releases

Download the latest signed release from **[Releases](https://github.com/justrach/nanoharness/releases/latest)**:

| Platform | Package | Notes |
| --- | --- | --- |
| **macOS (Apple Silicon)** | `Harness-macos-arm64.dmg` | Developer ID signed &amp; notarized; auto-updates in-app |
| **Windows (x64)** | `Harness-windows-x86_64.zip` | Portable `harness.exe`; keep `harness-update.json` beside it for in-app updates |
| **Arch Linux** | `harness-VERSION-linux-x86_64.pkg.tar.zst` (or `-aarch64`) | Install via `sudo pacman -U ./harness-*.pkg.tar.zst` (Vulkan driver required; updates via pacman) |

### Download with curl

<details>
<summary>Show commands for macOS, Windows, and Arch Linux</summary>

These commands download the package to the current directory; they do not install it.

**macOS (Apple Silicon):**

```sh
curl -fLO https://github.com/justrach/nanoharness/releases/latest/download/Harness-macos-arm64.dmg
```

**Windows (x64, PowerShell):**

```powershell
curl.exe -fLO https://github.com/justrach/nanoharness/releases/latest/download/Harness-windows-x86_64.zip
```

**Arch Linux (x86_64; set `arch=aarch64` for ARM64):**

```sh
release=https://github.com/justrach/nanoharness/releases
arch=x86_64
version=$(curl -fsSL "$release/latest/download/latest.txt") &&
  curl -fLO "$release/download/v$version/harness-$version-linux-$arch.pkg.tar.zst"
```

</details>

[Workspace](#the-workspace) · [GitHub review](#native-github-and-splits) · [Agents](#agents-and-settings) · [Build from source](#build-from-source) · [License](#license)

## The workspace

- **Bring your agents.** Switch agents, models, and speed tiers from the same composer and keyboard shortcuts.
- **Review changes beside the chat.** Use side-by-side splits for GitHub review, files, the browser, and terminals.
- **Work locally, sync when you want.** Start without an account, then opt in to follow or drive sessions from another trusted desktop or iOS device.

<p align="center">
  <img src="docs/media/readme/nanoharness-workspace-light.png" width="960" alt="NanoHarness desktop workspace in light mode showing a multi-project sidebar, tool summary, native typeset math, color emoji, and code block">
  <br><sub>NanoHarness in light mode with <strong>Graff</strong>, native Markdown &amp; LaTeX typesetting, color emoji, and viewport-culled transcripts. Synthetic example session.</sub>
</p>

## Native GitHub and splits

Open pull requests, inspect file diffs, read review activity, and check CI right beside your conversation without leaving the workspace.

## Agents and settings

NanoHarness supports **CodeGraff (`graff`)**, Claude Code, Codex, Cursor, Devin, Grok, Hermes, Pi, OpenCode, Antigravity, and [Exo](https://github.com/exoharness/exo). Enable or configure installed agents from **Settings → Agents**. Exo is off by default and connects through its agent-cli adapter (`./exo.sh --setup agent-cli`) via Harness's built-in ACP bridge.

<p align="center">
  <img src="docs/media/readme/nanoharness-agents-light.png" width="960" alt="NanoHarness Settings Agents page in light mode showing Graff, Claude Code, Codex, OpenCode, and Cursor">
  <br><sub>Installed agents appear in <strong>Settings → Agents</strong>, including Graff's context compaction threshold and one-click CLI updates.</sub>
</p>

### Native Flint

Run **Flint INT4** locally on Apple Silicon alongside NanoHarness and a compatible Graff build. Licensed weights, resumable downloads, and SHA-256 checksums are available at **[codegraff.com/flint](https://codegraff.com/flint)** (also linked directly from **Settings → Agents**).

## Build from source

Build from a checkout with Zig `0.17.0` and the Rust toolchain in [`rust-toolchain.toml`](rust-toolchain.toml):

| Platform | Run |
| --- | --- |
| **macOS** | `./scripts/run-macos-dev.sh` |
| **Linux** | `cargo build -p harness && ./target/debug/harness` |
| **Windows** | `cargo run --locked -p harness` |

The macOS script opens `target/macos-dev/Harness.app`. Development data lives in `target/macos-dev/data` unless `HARNESS_DEV_DATA_DIR` is set. Quit the app before rebuilding. For an offline tour with seeded sessions, run `./scripts/dev-demo.sh`.

See [Windows development](docs/reference/windows-development.md) and the [Linux browser runtime](docs/reference/linux-browser.md) for platform-specific details.

## CodeGraff

NanoHarness includes a first-class adapter for [CodeGraff](https://github.com/justrach/codegraff). Its app icon was designed to sit beside the CodeGraff mark.

<p align="center">
  <img src="docs/brand/codegraff-emblem.png" width="82" alt="CodeGraff emblem">
  &nbsp;&nbsp;
  <img src="docs/brand/codegraff-workshop.png" width="156" alt="CodeGraff workshop illustration">
</p>

<p align="center">
  <img src="docs/brand/codegraff-context.png" width="900" alt="How context moves through graff">
</p>

The macOS app bundles a managed `graff` CLI. While Harness is open, it checks the [latest stable CodeGraff release](https://github.com/justrach/codegraff/releases) shortly after launch and every six hours, installing newer versions only after verifying the release archive's SHA-256 checksum. You can also update `graff` in **Settings → Agents** or choose **Install beta** to opt in to the newest published CodeGraff beta for new sessions (open sessions keep their current engine; **Update** switches back to stable). Set `HARNESS_GRAFF_AUTO_UPDATE=0` to disable background checks; Harness leaves a custom `GRAFF_EXECUTABLE` alone.

The CodeGraff images are credited in [third-party notices](THIRD_PARTY_NOTICES.md).

## Devices and accounts

Each desktop device runs an engine and stores its local sessions. The GUI connects to an engine on the local IPC port or starts one in the app process. `harness headless` runs the engine without a window.

In the desktop app, open the account menu and choose **Enable sync**. Sign in with your CodeGraff account, then choose whether to bring existing local work into the synced workspace or start fresh. Harness does not upload existing local sessions until you choose **Bring my work**. New work in the synced workspace is stored at `edge.codegraff.com` and appears on your other signed-in devices, including the SwiftUI iOS companion. Running commands, terminals or file writes from another device also needs **Settings → Devices → Allow remote control** on the computer that would execute them (off by default), and the first of those actions from a given device still asks for a local approval. New installs default agent autonomy to Workspace; existing preferences are left alone.

For a headless device, stop the engine before changing profiles:

```sh
harness daemon stop
harness login
harness daemon start
```

Harness sync uses CodeGraff OAuth; signing in to the `graff` agent is a separate step. Coding agents keep their own provider credentials on the host device. Synced chat content and workspace metadata go to the Harness edge service. A trusted remote device can ask an online host to read and write workspace files; **Show ignored files** also exposes ignored files such as `.env`. Sign in only devices you trust with those files. To return to the local profile on a headless device, stop the daemon, run `harness logout`, and restart it.

For the internals, see [architecture](ARCHITECTURE.md). For appearance and theme import, see [the theme guide](docs/theme-system.md).

## License

**Modified GNU AGPL-3.0** ([`LICENSE`](LICENSE)), built the same way as [CodeGraff](https://github.com/justrach/codegraff)'s. Network use triggers Section 13. Standard Harness Pte. Ltd., **Rach Pradhan (justrach)** and **Yu Xi Lim (yxlyx)** reserve the right to offer proprietary or hosted versions of the original Harness contributions they own. A recipient's AGPL license is perpetual unless they breach it. Commercial permission without copyleft exists only if **all three grant it jointly in writing**, and is revocable. Earlier and third-party material keeps its own copyright and license notices; see [third-party notices](THIRD_PARTY_NOTICES.md).

**Companies need a commercial license.** Every version after v0.2.108 adds one term. Your organization, counted together with its affiliates, needs a commercial license for any use of Harness (including on its own machines, cloud, CI and network) if it meets **any one** of these:

- it has raised more than **US$500k** in total from investors or lenders;
- its net worth or latest valuation is more than **US$500k**;
- its gross revenue was more than **US$100k** in its last fiscal year or any 12-month period.

A company that crosses a line must contact us within 5 working days. Individuals always use Harness under the AGPL, whatever they earn, and so do organizations that meet none of these tests. Versions up to v0.2.108 keep the license they shipped with. Unsure? Treat yourself as covered and get in touch.
Contact [rach@standardharness.com](mailto:rach@standardharness.com).

**Contributing.** All contributions require prior agreement to the [Contributor Assignment and License Agreement (`CLA.md`)](CLA.md) (see [`CONTRIBUTING.md`](CONTRIBUTING.md)), under which contributions are irrevocably assigned to the Licensors and become part of `Licensor Material` governed by [`LICENSE`](LICENSE).

### Upstream license notice ([zeronsh/zeron](https://github.com/zeronsh/zeron))

Earlier portions of the workspace and engine stack were adapted from [Zeron (`zeronsh/zeron`)](https://github.com/zeronsh/zeron), Copyright (c) 2026 Wing, under the MIT License. The original MIT permission and warranty notice is retained verbatim in [`third_party/licenses/Zeron-MIT.txt`](third_party/licenses/Zeron-MIT.txt) alongside [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
