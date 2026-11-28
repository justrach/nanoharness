# Packaging

## Linux (implemented)

```sh
scripts/package-linux.sh                 # size-optimized engine (`headless` profile)
PROFILE=release scripts/package-linux.sh # quicker optimized engine build
PROFILE=debug scripts/package-linux.sh   # fast smoke package
```

The script builds `harness-engine` with Cargo and the desktop app and CLI with
`zig build -Doptimize=ReleaseSafe -Dcpu=baseline` in `apps/nano`. It produces
`target/package/harness-<version>-linux-<arch>.tar.gz` containing:

- `harness` — the CLI (`harness` opens the desktop app; `harness headless` runs the engine alone)
- `harness-engine` — the engine
- `harness-nano` — the desktop app
- `harness.desktop` — XDG desktop entry
- `harness.png` — 1024×1024 Harness app icon
- `install.sh` — installs into `~/.local/{bin,share/applications,share/icons}`
- `LICENSE`, `THIRD_PARTY_NOTICES.md` and `licenses/`

The `headless` profile in the root `Cargo.toml` inherits the fat-LTO `dist`
profile and optimizes for size (`opt-level = "z"`).

## macOS

```sh
GRAFF_BINARY=/path/to/graff scripts/package-macos.sh
```

The script builds `Harness.app`, bundles the supplied Graff CLI, and produces
`target/package/harness-<version>-macos-<arch>.dmg` plus an app tarball for
stable updates. Omit `GRAFF_BINARY` to fetch the latest stable Graff release
and verify it against that release's `SHA256SUMS`. `HARNESS_BINARY` can point
to an already tested Harness executable. Signed distribution builds set
`CODESIGN_IDENTITY` and either App Store Connect notary credentials or
`NOTARYTOOL_PROFILE`; the script signs nested code, notarizes the app and DMG,
and staples both. `Harness.app` seeds its bundled Graff into the user's
Harness managed directory and puts the CLI on the terminal PATH on first open.

The DMG artwork is generated from the synthetic plate with
`swift scripts/dmg-background.swift`. The rendered 1x and 2x backgrounds are
committed so packaging does not require a graphics generator.
