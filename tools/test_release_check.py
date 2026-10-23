"""Offline tests only: fixture passes do not certify the real app for release."""
import json
import tempfile
import unittest
from pathlib import Path
from release_check import REQUIRED, check, public_https_url


class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "Config").mkdir()
        # Syntactically valid fixture URLs; these are never contacted.
        self.services = dict(feedbackEndpoint="https://fixture.okiru.invalidhost/exec",
                             privacyURL="https://fixture.okiru.invalidhost/privacy",
                             supportURL="https://fixture.okiru.invalidhost/support", appStoreID="123456789")
        self.evidence = {key: {"passed": True, "evidence": "fixture-only"} for key in REQUIRED}

    def run_check(self):
        for name, value in (("Services", self.services), ("ReleaseEvidence", self.evidence)):
            (self.root / f"Config/{name}.json").write_text(json.dumps(value))
        return check(self.root)

    def test_complete_fixture(self):
        self.assertEqual(self.run_check(), [])

    def test_missing_urls_and_gates_fail(self):
        self.services = {}; self.evidence = {}
        self.assertEqual(len(self.run_check()), 14)

    def test_null_evidence_never_certifies_a_gate(self):
        for value in (None, [], {}, 1, "", "   "):
            with self.subTest(value=value):
                self.evidence[REQUIRED[0]] = {"passed": True, "evidence": value}
                self.assertTrue(self.run_check())

    def test_only_boolean_true_passes(self):
        for value in ("true", 1, False, None):
            self.evidence[REQUIRED[0]]["passed"] = value
            self.assertTrue(self.run_check())

    def test_invalid_entry_types_fail(self):
        for value in (None, [], "done"):
            self.evidence[REQUIRED[0]] = value
            self.assertTrue(self.run_check())

    def test_top_level_arrays_fail(self):
        self.evidence = []
        self.assertTrue(self.run_check())

    def test_non_numeric_ids_fail(self):
        for value in (None, 123, "0", "", "１２３", "123/456"):
            self.services["appStoreID"] = value
            self.assertTrue(self.run_check())

    def test_private_placeholder_and_credential_urls_fail(self):
        for url in ("http://app.site/privacy", "https://localhost", "https://127.0.0.1",
                    "https://10.1.2.3", "https://[::1]", "https://app.local",
                    "https://privacy.example.com", "https://example.org", "https://app.test",
                    "https://user:password@app.site", "https://app.site:bad", None, [], " https://app.site"):
            with self.subTest(url=url):
                self.assertFalse(public_https_url(url))

    def test_malformed_json_fails(self):
        (self.root / "Config/Services.json").write_text("{")
        self.assertTrue(check(self.root))

    def test_missing_files_fail(self):
        self.assertTrue(check(self.root))


if __name__ == "__main__":
    unittest.main()
