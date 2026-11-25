#!/usr/bin/env python3
"""Generate an Ed25519 release-signing keypair. Never commit the private key.

Usage:
  python3 scripts/gen-release-key.py
  python3 scripts/gen-release-key.py --sign path/to/manifest.json

The public key is printed as 32 hex bytes to paste into
`apps/nano/src/updates_host.zig` (`release_verify_key`). The private key is
written to `release-ed25519.pem` in the current directory (0600). Keep that
file in the release secrets store, not the repo.

Signing a manifest: the message is `version` then each `file=sha256` line,
sorted by file name — the same bytes `manifestMessage` in updates_host.zig
hashes. The signature is stored as a 128-char hex `sig` field on the JSON.
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys


def _require_cryptography():
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PrivateKey,
            Ed25519PublicKey,
        )
    except ImportError as err:
        sys.stderr.write(
            "install cryptography (`pip install cryptography`) or generate with:\n"
            "  openssl genpkey -algorithm ED25519 -out release-ed25519.pem\n"
            "  openssl pkey -in release-ed25519.pem -pubout\n"
        )
        raise SystemExit(1) from err
    return serialization, Ed25519PrivateKey, Ed25519PublicKey


def generate(path: str) -> None:
    serialization, Ed25519PrivateKey, _ = _require_cryptography()
    key = Ed25519PrivateKey.generate()
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(pem)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    pub = key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    zig = ", ".join(f"0x{b:02x}" for b in pub)
    print(f"private key: {path} (0600, do not commit)")
    print("public key for updates_host.zig release_verify_key:")
    print(f"    {zig},")
    print("hex:", pub.hex())


def manifest_message(doc: dict) -> bytes:
    version = str(doc.get("version", "")).strip()
    files = doc.get("files") or {}
    lines = [version, ""]
    for name in sorted(files):
        meta = files[name] or {}
        sha = (meta.get("sha256") or "").strip()
        if sha:
            lines.append(f"{name}={sha}")
    return "\n".join(lines[:2] + lines[2:] + ([""] if files else [])).encode()


def sign(pem_path: str, manifest_path: str) -> None:
    serialization, Ed25519PrivateKey, _ = _require_cryptography()
    with open(pem_path, "rb") as handle:
        key = serialization.load_pem_private_key(handle.read(), password=None)
    with open(manifest_path, encoding="utf-8") as handle:
        doc = json.load(handle)
    sig = key.sign(manifest_message(doc)).hex()
    doc["sig"] = sig
    text = json.dumps(doc, indent=2, sort_keys=False)
    with open(manifest_path, "w", encoding="utf-8") as handle:
        handle.write(text)
        handle.write("\n")
    print(f"signed {manifest_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="release-ed25519.pem")
    parser.add_argument("--sign")
    parser.add_argument("--key", default="release-ed25519.pem")
    args = parser.parse_args()
    if args.sign:
        sign(args.key, args.sign)
    else:
        generate(args.out)


if __name__ == "__main__":
    main()
