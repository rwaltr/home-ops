"""Self-check the non-admin registration signature without contacting Tuwunel."""

import importlib.util
import hashlib
import hmac
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "provision-matrix-bot.py"
SPEC = importlib.util.spec_from_file_location("provision_matrix_bot", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
BOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOT)


class RegistrationPayloadTest(unittest.TestCase):
    def test_signs_non_admin_request(self):
        nonce = "nonce-value"
        username = "teletran"
        password = "throwaway-password"
        secret = b"registration-secret"
        expected_data = b"\0".join(
            (nonce.encode(), username.encode(), password.encode(), b"notadmin")
        )
        expected_mac = hmac.new(secret, expected_data, hashlib.sha1).hexdigest()

        payload = BOT.registration_payload(nonce, username, password, secret)

        self.assertEqual(payload["mac"], expected_mac)
        self.assertIs(payload["admin"], False)
        self.assertEqual(payload["username"], username)


if __name__ == "__main__":
    unittest.main()
