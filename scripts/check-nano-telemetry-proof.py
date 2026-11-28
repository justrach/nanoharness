#!/usr/bin/env python3
"""Compile all Lean proof modules for Nano telemetry and verify vector conformance."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROOFS_DIR = ROOT / "apps" / "nano" / "lean-proofs"
NANO_DIR = PROOFS_DIR / "Nano"
VECTORS_CSV = ROOT / "apps" / "nano" / "src" / "telemetry_policy_vectors.csv"
FORBIDDEN_RE = re.compile(r"(^|[^\w])(sorry|axiom|admit)([^\w]|$)", re.MULTILINE)


def run(cmd: list[str], cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, env=env, check=True, text=True, capture_output=True)


def check_no_forbidden(paths: list[Path]) -> None:
    for path in paths:
        # Strip line comments (-- ...) and block comments (/- ... -/) before scanning
        text = path.read_text(encoding="utf-8")
        text = re.sub(r"/-.*?-/", "", text, flags=re.DOTALL)
        text = re.sub(r"--[^\n]*", "", text)
        match = FORBIDDEN_RE.search(text)
        if match:
            raise SystemExit(f"Forbidden keyword '{match.group(2)}' found in {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-zig", action="store_true", help="Skip running Zig performance vector test")
    args = parser.parse_args()

    lean_files = sorted(NANO_DIR.glob("*.lean"))
    entry_files = [PROOFS_DIR / "Main.lean", PROOFS_DIR / "TelemetryVectors.lean"]
    check_no_forbidden(lean_files + entry_files)

    with tempfile.TemporaryDirectory(prefix="nano-telemetry-proof-") as tmp:
        tmp_path = Path(tmp)
        (tmp_path / "Nano").mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["LEAN_PATH"] = f"{tmp_path}{os.pathsep}{PROOFS_DIR}"

        for mod in lean_files:
            out = tmp_path / "Nano" / f"{mod.stem}.olean"
            subprocess.run(
                ["lean", "-R", str(PROOFS_DIR), "-o", str(out), str(mod)],
                cwd=PROOFS_DIR,
                env=env,
                check=True,
            )

        run(["lean", "--run", "Main.lean"], cwd=PROOFS_DIR, env=env)
        generated = run(["lean", "--run", "TelemetryVectors.lean"], cwd=PROOFS_DIR, env=env).stdout

    expected = VECTORS_CSV.read_text(encoding="utf-8")
    if generated != expected:
        raise SystemExit(
            f"Telemetry vector mismatch between Lean output and {VECTORS_CSV.relative_to(ROOT)}"
        )

    if not args.skip_zig:
        subprocess.run(
            ["../../scripts/heavy-build.sh", "zig", "build", "test", "-Dtest-filter=desktop performance"],
            cwd=ROOT / "apps" / "nano",
            check=True,
        )

    print("Lean telemetry proofs and vectors verified.")


if __name__ == "__main__":
    main()
