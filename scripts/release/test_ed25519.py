"""Tests for ed25519.swift, through the real tool. macOS only (it uses CryptoKit); skipped elsewhere.

Each call compiles the script, so this is a handful of calls rather than one per assertion."""

import base64
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOL = pathlib.Path(__file__).with_name("ed25519.swift")


def run(*args, key=None):
    env = {k: v for k, v in os.environ.items() if k != "ED25519_PRIVATE_KEY"}
    if key is not None:
        env["ED25519_PRIVATE_KEY"] = key
    return subprocess.run(["swift", str(TOOL), *args], capture_output=True, text=True, env=env, timeout=300)


def fields(text):
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swift"), "needs macOS and swift (CryptoKit)")
class Ed25519ToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.mkdtemp()
        cls.file = os.path.join(cls.folder, "update.bin")
        pathlib.Path(cls.file).write_bytes(b"the bytes of an update" * 100)
        generated = run("generate")
        assert generated.returncode == 0, generated.stderr
        cls.keys = fields(generated.stdout)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.folder, ignore_errors=True)

    def test_keys_have_the_sizes_sparkle_expects(self):
        self.assertEqual(len(base64.b64decode(self.keys["public"])), 32)
        self.assertEqual(len(base64.b64decode(self.keys["private"])), 64)  # seed + public, as `generate_keys -x`

    def test_a_signature_verifies_and_matches_the_files_length(self):
        signed = run("sign", self.file, key=self.keys["private"])
        self.assertEqual(signed.returncode, 0, signed.stderr)
        result = fields(signed.stdout)
        self.assertEqual(result["length"], str(os.path.getsize(self.file)))
        self.assertEqual(len(base64.b64decode(result["signature"])), 64)
        self.assertEqual(run("verify", self.file, self.keys["public"], result["signature"]).stdout.strip(), "valid")

    def test_tampering_a_wrong_key_and_a_corrupt_key_are_all_refused(self):
        signature = fields(run("sign", self.file, key=self.keys["private"]).stdout)["signature"]

        tampered = os.path.join(self.folder, "tampered.bin")
        pathlib.Path(tampered).write_bytes(b"something else entirely")
        self.assertNotEqual(run("verify", tampered, self.keys["public"], signature).returncode, 0)

        other_public = fields(run("generate").stdout)["public"]
        self.assertNotEqual(run("verify", self.file, other_public, signature).returncode, 0)

        # A 64-byte key whose public half belongs to another key is refused rather than used.
        seed = base64.b64decode(self.keys["private"])[:32]
        mismatched = base64.b64encode(seed + base64.b64decode(other_public)).decode()
        refused = run("sign", self.file, key=mismatched)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("mismatched", refused.stderr)

    def test_a_32_byte_seed_works_and_gives_the_same_public_key(self):
        seed = base64.b64encode(base64.b64decode(self.keys["private"])[:32]).decode()
        self.assertEqual(run("public", key=seed).stdout.strip(), self.keys["public"])

    def test_the_key_must_come_from_the_environment(self):
        missing = run("sign", self.file)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("ED25519_PRIVATE_KEY", missing.stderr)


if __name__ == "__main__":
    unittest.main()
