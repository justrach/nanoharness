#!/usr/bin/env python3
"""Compile all Nano Lean 4 proof modules, enforce zero sorry/axiom/admit,
verify/export witness CSV vectors, and run Zig conformance tests."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROOFS_DIR = ROOT / "apps" / "nano" / "lean-proofs"
NANO_DIR = PROOFS_DIR / "Nano"
TELEMETRY_CSV = ROOT / "apps" / "nano" / "src" / "telemetry_policy_vectors.csv"
UX_CSV = ROOT / "apps" / "nano" / "src" / "ux_proof_vectors.csv"
FORBIDDEN_RE = re.compile(r"(^|[^\w])(sorry|axiom|admit)([^\w]|$)", re.MULTILINE)


def run_capture(cmd: list[str], cwd: Path, env: dict[str, str]) -> str:
    res = subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=True)
    if res.returncode != 0:
        raise SystemExit(
            f"Command {' '.join(cmd)} failed (exit {res.returncode}):\n{res.stdout}\n{res.stderr}"
        )
    return res.stdout


def strip_lean_comments(src: str) -> str:
    src = re.sub(r"/-.*?-/", "", src, flags=re.DOTALL)
    return re.sub(r"--[^\n]*", "", src)


def check_no_forbidden(paths: list[Path]) -> None:
    for path in paths:
        cleaned = strip_lean_comments(path.read_text(encoding="utf-8"))
        match = FORBIDDEN_RE.search(cleaned)
        if match:
            raise SystemExit(f"Forbidden proof hole '{match.group(2)}' found in {path.relative_to(ROOT)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update-vectors", action="store_true", help="Write Lean witness CSV outputs to disk")
    parser.add_argument("--skip-zig", action="store_true", help="Skip running Zig conformance tests")
    args = parser.parse_args()

    nano_mods = sorted(NANO_DIR.glob("*.lean"))
    entries = [
        PROOFS_DIR / "Main.lean",
        PROOFS_DIR / "UxMain.lean",
        PROOFS_DIR / "TelemetryVectors.lean",
        PROOFS_DIR / "UxVectors.lean",
    ]
    check_no_forbidden(nano_mods + entries)

    # Order modules respecting intra-Nano dependencies if any (Telemetry imports FrameSchedule/ScrollFollow/etc.)
    preferred_order = [
        "FrameSchedule",
        "ScrollFollow",
        "Tween",
        "StripMenu",
        "ModelPicker",
        "FooterChips",
        "QuestionPanel",
        "SubagentTasks",
        "Telemetry",
        "OverlayMutex",
        "EscapeTermination",
        "HoverStability",
        "FocusAndClose",
        "TabNavModel",
        "KeymapPartition",
        "UiMode3",
        "DesignCanvas",
        "BrowseConnect",
        "WindowA11yFocus",
    ]
    by_stem = {p.stem: p for p in nano_mods}
    ordered_mods = [by_stem[s] for s in preferred_order if s in by_stem] + [
        p for p in nano_mods if p.stem not in preferred_order
    ]

    with tempfile.TemporaryDirectory(prefix="nano-ux-proofs-") as tmp:
        tmp_path = Path(tmp)
        (tmp_path / "Nano").mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["LEAN_PATH"] = f"{tmp_path}{os.pathsep}{PROOFS_DIR}"

        for mod in ordered_mods:
            out = tmp_path / "Nano" / f"{mod.stem}.olean"
            run_capture(["lean", "-R", str(PROOFS_DIR), "-o", str(out), str(mod)], PROOFS_DIR, env)

        main_out = run_capture(["lean", "--run", "Main.lean"], PROOFS_DIR, env)
        ux_out = run_capture(["lean", "--run", "UxMain.lean"], PROOFS_DIR, env)
        telemetry_csv = run_capture(["lean", "--run", "TelemetryVectors.lean"], PROOFS_DIR, env)
        ux_csv = run_capture(["lean", "--run", "UxVectors.lean"], PROOFS_DIR, env)

    if args.update_vectors:
        TELEMETRY_CSV.write_text(telemetry_csv, encoding="utf-8")
        UX_CSV.write_text(ux_csv, encoding="utf-8")
    else:
        if TELEMETRY_CSV.read_text(encoding="utf-8") != telemetry_csv:
            raise SystemExit(f"Drift in {TELEMETRY_CSV.relative_to(ROOT)}; rerun with --update-vectors")
        if not UX_CSV.exists() or UX_CSV.read_text(encoding="utf-8") != ux_csv:
            raise SystemExit(f"Drift in {UX_CSV.relative_to(ROOT)}; rerun with --update-vectors")

    if not args.skip_zig:
        run_capture(["zig", "test", "apps/nano/src/tests_ux_proofs.zig"], ROOT, os.environ.copy())
        run_capture(
            ["../../scripts/heavy-build.sh", "zig", "build", "test", "-Dtest-filter=lean UiMode"],
            ROOT / "apps" / "nano",
            os.environ.copy(),
        )
        run_capture(
            ["../../scripts/heavy-build.sh", "zig", "build", "test", "-Dtest-filter=desktop performance"],
            ROOT / "apps" / "nano",
            os.environ.copy(),
        )

    print(f"Verified {len(ordered_mods)} Lean 4 proof modules ({len(ux_csv.splitlines())} UX witness rows).")
    for line in (main_out + ux_out).strip().splitlines():
        print(f"  {line}")


if __name__ == "__main__":
    main()
