#!/usr/bin/env python3
"""Tests for scripts/gen-release-key.py manifest encoding and Ed25519 signing."""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

_SCRIPT_PATH = Path(__file__).resolve().with_name("gen-release-key.py")
_SPEC = importlib.util.spec_from_file_location("gen_release_key", _SCRIPT_PATH)
assert _SPEC is not None and _SPEC.loader is not None
gen_release_key = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(gen_release_key)

# Deterministic synthetic Ed25519 test seed (0x00..0x1f), shared with updates_host.zig tests.
_TEST_SEED = bytes(range(32))
_EXPECTED_PUB_HEX = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
_EXPECTED_SIG_HEX = (
    "31682043ec7dc3bcf3db6e76618652e92d5b3120032be03d718e9e4f0554aeae"
    "0d7012143d917424c4744bc3a570dd49acbb8194307ee7b34db3723755b1b30f"
)
_SAMPLE_MANIFEST = {
    "version": "0.2.237",
    "files": {
        "b.zip": {"sha256": "2222"},
        "a.tar.gz": {"sha256": "1111"},
    },
}


class GenReleaseKeyTest(unittest.TestCase):
    def test_manifest_message_empty_files(self) -> None:
        self.assertEqual(
            gen_release_key.manifest_message({"version": "0.2.237", "files": {}}),
            b"0.2.237\n",
        )
        self.assertEqual(
            gen_release_key.manifest_message({"version": "0.2.237"}),
            b"0.2.237\n",
        )

    def test_manifest_message_sorted_and_skips_invalid_entries(self) -> None:
        doc = {
            "version": "0.2.237",
            "files": {
                "b.zip": {"sha256": "2222"},
                "ignored_not_dict": "bad",
                "ignored_missing_sha": {},
                "ignored_bad_sha": {"sha256": 123},
                "a.tar.gz": {"sha256": "1111"},
            },
        }
        self.assertEqual(
            gen_release_key.manifest_message(doc),
            b"0.2.237\na.tar.gz=1111\nb.zip=2222\n",
        )

    def test_extract_raw_ed25519_pubkey(self) -> None:
        spki = gen_release_key._ED25519_SPKI_PREFIX + bytes.fromhex(_EXPECTED_PUB_HEX)
        self.assertEqual(
            gen_release_key._extract_raw_ed25519_pubkey(spki),
            bytes.fromhex(_EXPECTED_PUB_HEX),
        )
        with self.assertRaises(ValueError):
            gen_release_key._extract_raw_ed25519_pubkey(b"short")

    def test_sign_deterministic_vector_and_round_trip(self) -> None:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PrivateKey,
            Ed25519PublicKey,
        )

        key = Ed25519PrivateKey.from_private_bytes(_TEST_SEED)
        pem = key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            key_path = os.path.join(tmpdir, "test-ed25519.pem")
            manifest_path = os.path.join(tmpdir, "manifest.json")
            gen_release_key._write_private_pem_exclusive(key_path, pem)
            self.assertEqual(stat.S_IMODE(os.stat(key_path).st_mode), 0o600)
            self.assertEqual(
                gen_release_key.pubkey_from_file(key_path).hex(),
                _EXPECTED_PUB_HEX,
            )

            with open(manifest_path, "w", encoding="utf-8") as handle:
                json.dump(_SAMPLE_MANIFEST, handle)
            gen_release_key.sign(key_path, manifest_path)
            with open(manifest_path, encoding="utf-8") as handle:
                signed = json.load(handle)

            self.assertEqual(len(signed["sig"]), 128)
            self.assertEqual(signed["sig"], _EXPECTED_SIG_HEX)
            pub = Ed25519PublicKey.from_public_bytes(bytes.fromhex(_EXPECTED_PUB_HEX))
            pub.verify(
                bytes.fromhex(signed["sig"]),
                gen_release_key.manifest_message(signed),
            )

            if self._openssl_supports_ed25519():
                self.assertEqual(
                    gen_release_key._pubkey_openssl(key_path).hex(),
                    _EXPECTED_PUB_HEX,
                )
                self.assertEqual(
                    gen_release_key._sign_openssl(
                        key_path, gen_release_key.manifest_message(_SAMPLE_MANIFEST)
                    ).hex(),
                    _EXPECTED_SIG_HEX,
                )

    def test_generate_creates_0600_key_and_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            key_path = os.path.join(tmpdir, "generated.pem")
            gen_release_key.generate(key_path)
            self.assertEqual(stat.S_IMODE(os.stat(key_path).st_mode), 0o600)
            pub = gen_release_key.pubkey_from_file(key_path)
            self.assertEqual(len(pub), 32)
            with self.assertRaises(FileExistsError):
                gen_release_key.generate(key_path)

    @staticmethod
    def _openssl_supports_ed25519() -> bool:
        openssl = shutil.which("openssl")
        if not openssl:
            return False
        res = subprocess.run(
            [openssl, "genpkey", "-algorithm", "ED25519"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return res.returncode == 0


if __name__ == "__main__":
    unittest.main()
