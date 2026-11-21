import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parents[2] / "f" / "paperless" / "immich_bridge.py"
spec = importlib.util.spec_from_file_location("immich_bridge", SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class Response:
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def read(self):
        return b'"task-id"'


class PaperlessUploadTest(unittest.TestCase):
    def test_uploads_file_and_title_as_multipart(self):
        bridge.PAPERLESS_URL = "http://paperless.test"
        bridge.PAPERLESS_KEY = "not-a-real-secret"
        with patch.object(bridge.urllib.request, "urlopen", return_value=Response()) as open_url:
            result = bridge.paperless_upload("2026 receipt.pdf", b"%PDF-test")

        self.assertEqual(result, "task-id")
        request = open_url.call_args.args[0]
        body = request.data
        self.assertEqual(request.full_url, "http://paperless.test/api/documents/post_document/")
        self.assertIn(b'name="document"; filename="2026 receipt.pdf"', body)
        self.assertIn(b'name="title"\r\n\r\n2026 receipt', body)
        self.assertIn(b"%PDF-test", body)
        self.assertIn("multipart/form-data; boundary=", request.get_header("Content-type"))
        self.assertEqual(request.get_header("Authorization"), "Token not-a-real-secret")


if __name__ == "__main__":
    unittest.main()
