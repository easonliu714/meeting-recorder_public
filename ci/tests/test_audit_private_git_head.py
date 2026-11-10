"""Local synthetic Git tests: never connect to a real private repository."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audit_private_git_head import (  # noqa: E402
    PublicationHold, inspect_private_head, inspect_text,
)
from verify_public_snapshot import _allowed_source  # noqa: E402


class PrivateExactHeadAuditTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="audit-private-fixture-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.git("init", "-q", "-b", "test", self.root.as_posix())
        self.git("-C", str(self.root), "config", "user.name", "Synthetic CI")
        self.git("-C", str(self.root), "config", "user.email", "ci@example.invalid")
        self.write(".gitignore", b"*.log\n")
        self.write("android/.gitignore",
                   b"**/*.jks\n/upload-keystore.properties\n")
        self.write("lib/main.dart", b"void main() {}")
        self.commit()

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], stderr=subprocess.DEVNULL,
        ).decode().strip()

    def write(self, path, data):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(data)

    def commit(self):
        self.git("-C", str(self.root), "add", "-A")
        self.git("-C", str(self.root), "commit", "-qm", "Synthetic fixture only")
        return self.git("-C", str(self.root), "rev-parse", "HEAD")

    def test_clean_head_is_scanned_without_network_or_mutation(self):
        head = self.git("-C", str(self.root), "rev-parse", "HEAD")
        before = self.git("-C", str(self.root), "status", "--porcelain")
        self.assertEqual(inspect_private_head(self.root, head), (3, 0))
        self.assertEqual(self.git("-C", str(self.root), "status", "--porcelain"), before)

    def test_exact_head_lease_fails_closed(self):
        with self.assertRaisesRegex(PublicationHold, "PRIVATE_HEAD_CHANGED"):
            inspect_private_head(self.root, "0" * 40)

    def test_private_signing_properties_missing_ignore_rule_is_hold(self):
        self.write("android/.gitignore", b"**/*.jks\n")
        head = self.commit()
        with self.assertRaisesRegex(PublicationHold, "IGNORE_GAP"):
            inspect_private_head(self.root, head)

    def test_private_signing_config_even_if_forced_tracked_is_blocked(self):
        self.write("android/upload-keystore.properties",
                   b"storePassword=not-a-real-credential\n")
        self.git("-C", str(self.root), "add", "-f", "android/upload-keystore.properties")
        self.git("-C", str(self.root), "commit", "-qm", "Synthetic forced tracked")
        head = self.git("-C", str(self.root), "rev-parse", "HEAD")
        with self.assertRaisesRegex(PublicationHold, "TRACKED_SENSITIVE_FILE"):
            inspect_private_head(self.root, head)

    def test_excluded_private_docs_are_still_scanned(self):
        self.write("docs/private-notes.md", b"owner_contact@example.com")
        head = self.commit()
        with self.assertRaisesRegex(PublicationHold, "PRIVATE_SENSITIVE_TEXT"):
            inspect_private_head(self.root, head)

    def test_valid_secret_syntax_is_detected_without_value_in_error(self):
        with self.assertRaises(PublicationHold) as captured:
            inspect_text("lib/key.dart", b"const apiKey = 'ghp_" + b"x" * 32 + b"';")
        self.assertNotIn("ghp_", str(captured.exception))

    def test_taiwan_phone_is_detected_in_excluded_docs(self):
        with self.assertRaisesRegex(PublicationHold, "taiwan_mobile"):
            inspect_text("docs/owner.md", b"mobile=0912345678")

    def test_properties_plaintext_is_detected(self):
        with self.assertRaisesRegex(PublicationHold, "PRIVATE_PROPERTY_CREDENTIAL"):
            inspect_text("android/custom.properties", b"storePassword=synthetic-long-value")

    def test_public_manifest_denies_private_signing_properties(self):
        for path in (
            "android/upload-keystore.properties",
            "android/app/signing.properties",
            "android/google-services.json",
            "android/app/service-account.json",
        ):
            with self.subTest(path=path):
                self.assertFalse(_allowed_source(path))


if __name__ == "__main__":
    unittest.main()
