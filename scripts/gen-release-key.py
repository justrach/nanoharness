#!/usr/bin/env python3
"""Generate an Ed25519 release-signing keypair. Never commit the private key.

Usage:
  python3 scripts/gen-release-key.py
  python3 scripts/gen-release-key.py --key release-ed25519.pem --pubkey
  python3 scripts/gen-release-key.py --key release-ed25519.pem --sign path/to/manifest.json

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
import shutil
import stat
import subprocess
import sys
import tempfile

_ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


def _load_cryptography():
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PrivateKey,
            Ed25519PublicKey,
        )
    except ImportError:
        return None
    return serialization, Ed25519PrivateKey, Ed25519PublicKey


def _require_openssl() -> str:
    openssl = shutil.which("openssl")
    if openssl:
        return openssl
    sys.stderr.write(
        "install cryptography (`pip install cryptography`) or OpenSSL 3+ (`openssl`) to generate or sign with Ed25519.\n"
    )
    raise SystemExit(1)


def _extract_raw_ed25519_pubkey(spki_der: bytes) -> bytes:
    if len(spki_der) != len(_ED25519_SPKI_PREFIX) + 32 or not spki_der.startswith(
        _ED25519_SPKI_PREFIX
    ):
        raise ValueError(
            f"unexpected Ed25519 SPKI DER payload ({len(spki_der)} bytes)"
        )
    return spki_der[len(_ED25519_SPKI_PREFIX) :]


def _write_private_pem_exclusive(path: str, pem: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(pem)
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    except BaseException:
        if os.path.exists(path):
            os.unlink(path)
        raise


def _print_pubkey(pub: bytes) -> None:
    if len(pub) != 32:
        raise ValueError(f"expected 32-byte Ed25519 public key, got {len(pub)}")
    zig = ", ".join(f"0x{b:02x}" for b in pub)
    print("public key for updates_host.zig release_verify_key:")
    print(f"    {zig},")
    print("hex:", pub.hex())


def _generate_openssl(path: str) -> bytes:
    openssl = _require_openssl()
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_pem = os.path.join(tmpdir, "key.pem")
        subprocess.run(
            [openssl, "genpkey", "-algorithm", "ED25519", "-out", tmp_pem],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        with open(tmp_pem, "rb") as handle:
            pem = handle.read()
    _write_private_pem_exclusive(path, pem)
    return _pubkey_openssl(path)


def _pubkey_openssl(pem_path: str) -> bytes:
    openssl = _require_openssl()
    res = subprocess.run(
        [openssl, "pkey", "-in", pem_path, "-pubout", "-outform", "DER"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return _extract_raw_ed25519_pubkey(res.stdout)


def _sign_openssl(pem_path: str, message: bytes) -> bytes:
    openssl = _require_openssl()
    with tempfile.TemporaryDirectory() as tmpdir:
        msg_path = os.path.join(tmpdir, "msg.bin")
        sig_path = os.path.join(tmpdir, "msg.sig")
        with open(msg_path, "wb") as handle:
            handle.write(message)
        subprocess.run(
            [
                openssl,
                "pkeyutl",
                "-sign",
                "-inkey",
                pem_path,
                "-rawin",
                "-in",
                msg_path,
                "-out",
                sig_path,
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        with open(sig_path, "rb") as handle:
            sig = handle.read()
    if len(sig) != 64:
        raise ValueError(f"expected 64-byte Ed25519 signature, got {len(sig)}")
    return sig


def generate(path: str) -> None:
    crypto = _load_cryptography()
    if crypto is not None:
        serialization, Ed25519PrivateKey, _ = crypto
        key = Ed25519PrivateKey.generate()
        pem = key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        _write_private_pem_exclusive(path, pem)
        pub = key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
    else:
        pub = _generate_openssl(path)
    print(f"private key: {path} (0600, do not commit)")
    _print_pubkey(pub)


def pubkey_from_file(pem_path: str) -> bytes:
    crypto = _load_cryptography()
    if crypto is not None:
        serialization, _, _ = crypto
        with open(pem_path, "rb") as handle:
            key = serialization.load_pem_private_key(handle.read(), password=None)
        return key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
    return _pubkey_openssl(pem_path)


def manifest_message(doc: dict) -> bytes:
    version = str(doc.get("version", "")).strip()
    files = doc.get("files") or {}
    lines = [version]
    if isinstance(files, dict):
        for name in sorted(files):
            meta = files[name]
            if not isinstance(meta, dict):
                continue
            sha = meta.get("sha256")
            if isinstance(sha, str):
                lines.append(f"{name}={sha}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def sign_bytes(pem_path: str, message: bytes) -> bytes:
    crypto = _load_cryptography()
    if crypto is not None:
        serialization, _, _ = crypto
        with open(pem_path, "rb") as handle:
            key = serialization.load_pem_private_key(handle.read(), password=None)
        return key.sign(message)
    return _sign_openssl(pem_path, message)


def sign(pem_path: str, manifest_path: str) -> None:
    with open(manifest_path, encoding="utf-8") as handle:
        doc = json.load(handle)
    sig = sign_bytes(pem_path, manifest_message(doc)).hex()
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
    parser.add_argument("--pubkey", action="store_true")
    parser.add_argument("--key", default="release-ed25519.pem")
    args = parser.parse_args()
    if args.sign:
        sign(args.key, args.sign)
    elif args.pubkey:
        _print_pubkey(pubkey_from_file(args.key))
    else:
        generate(args.out)


if __name__ == "__main__":
    main()
