# Windows icon

`harness.ico` contains 16, 24, 32, 48, 64, 128, and 256 pixel PNG frames
converted from the existing `../macos/icon-1024.png` artwork with Lanczos
resampling. It preserves the artwork's transparency.

`harness.rc` declares it as icon resource 1. The Windows build
(`apps/nano/build.zig`, `scripts/package-windows.ps1`) does not compile
`harness.rc` into `harness.exe` or `harness-nano.exe`.
