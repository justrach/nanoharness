# Windows development

Windows supports native x64 source builds and portable release ZIPs. Release
packages offer in-app updates through GitHub; keep `harness-update.json` beside
`harness.exe`. Installers and background services are not supported yet.

## Build and run

Install stable MSVC Rust (the toolchain in `rust-toolchain.toml`), Visual Studio
C++ build tools, the Windows SDK, Zig 0.17.0 and Git for Windows. Build the
engine, then the desktop app and the `harness` CLI from `apps/nano`:

```powershell
cargo build --locked -p harness-engine --bin harness-engine
cd apps/nano
zig build -Dtarget=x86_64-windows-msvc
.\zig-out\bin\harness-nano.exe
```

`harness-nano.exe` starts `harness.exe headless` from its own folder when no
engine answers, and `harness.exe` finds `harness-engine.exe` beside it or in the
repository's `target\debug` (or `release`, `dist`, `app-dev`). Close the app
before rebuilding.

The portable package is built by the release script:

```powershell
./scripts/package-windows.ps1 -ReleasesUrl https://github.com/justrach/nanoharness/releases/latest/download
```

It builds the engine with the `headless` profile and the app with
`-Doptimize=ReleaseSafe`, downloads the WebView2 SDK's `WebView2Loader.dll`, and
writes `target/package/harness-<version>-windows-x86_64.zip` holding
`harness.exe`, `harness-nano.exe`, `harness-engine.exe`, `WebView2Loader.dll`,
`harness-update.json` and the license notices.

## Configuration and agent support

| Setting | Behavior |
| --- | --- |
| Application data | `%LOCALAPPDATA%\Harness`, falling back to `%USERPROFILE%\AppData\Local\Harness`. Override with `HARNESS_DATA_DIR`. |
| Managed adapters | `HARNESS_ADAPTERS_DIR`, then `HARNESS_DATA_DIR/adapters`, then the default application's `adapters` directory. |
| Provider credentials | Keep their provider-owned locations; changing Harness's data root does not migrate them. |
| `CODEX_EXECUTABLE` | Executable override. `.exe` (and `.com`) launch directly; `.cmd`/`.bat` shims launch through a wrapped `cmd.exe` with literal, individually escaped arguments. The override must exist on disk. |

ACP, Claude, Codex, and opencode search PATH and known native installation
directories. Discovery is PATHEXT-aware: npm's `.cmd` shims (and any `.bat`)
resolve like `cmd.exe` would — per directory, extensions in PATHEXT order —
and spawn through `cmd.exe /e:ON /v:OFF /d /c` inside the same Job Object, so npm-
installed agents (`codex`, `opencode`, `pi`, a bare `npm i -g grok`)
work without following `node_modules` payloads. Batch arguments containing
CR/LF and batch executable paths containing percent expansion syntax are rejected.
GUI launches additionally
backfill `%APPDATA%\npm`, `%LOCALAPPDATA%\{pnpm,Programs\nodejs,Volta\bin}`,
scoop shims, and `%USERPROFILE%\{.local\bin,.bun\bin}` from PATH. Managed
JavaScript adapters run through Node; installation requires `node.exe` beside
`node_modules/npm/bin/npm-cli.js`. Volta's selected tool-image npm location is
unsupported.

An OS file lock prevents engines from sharing a profile; `engine.lock.pid` is
only diagnostic. Terminals use ConPTY. Windows agents, login commands, adapter
installs, and terminals own their child process trees through Job Objects.
Terminal close waits up to five seconds for cleanup and reports failure;
shutdown/drop log failures. Processes started through external services or
brokers are outside this ownership. Closing a terminal or exiting its shell also
terminates processes detached inside that job (including `start` children).

The integrated Browser tab is available on macOS only.

## Verification

[Windows CI](../../.github/workflows/windows.yml) runs the Zig client's tests
(`zig build test` in `apps/nano`), builds and packages the app with
`scripts/package-windows.ps1`, runs `scripts/test-windows-startup.ps1`, and runs
the engine and adapter tests below. To run the same checks locally:

```powershell
cd apps/nano; zig build test; cd ../..
cargo test --locked -p harness-engine -p harness-adapters --lib
cargo test --locked -p harness-adapters --features native-fixture --test codex_availability --test windows_native
cargo test --locked -p harness-engine --test codex_catalog --test codex_login_resolution --test auth --test workspace_files --test desktop_requests
```

Fixtures use synthetic agents, so these tests do not establish authenticated
provider compatibility. The app lifecycle probe is an optional CI dispatch
check and can also run on an interactive Windows desktop. It launches
`target\release\harness.exe` by default (`-Exe` names another) with isolated
data and provider homes, and writes results to an ignored
`target/windows-lifecycle-*` directory:

```powershell
cargo build --release --locked -p harness-engine --bin harness-engine
cd apps/nano; zig build -Doptimize=ReleaseSafe cli; cd ../..
Copy-Item ./apps/nano/zig-out/bin/harness.exe ./target/release/harness.exe
./scripts/test-windows-lifecycle.ps1 -Runs 5
```
