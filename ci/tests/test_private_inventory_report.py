"""Real synthetic Git positive/negative tests; no Private checkout required."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from private_inventory_report import (
    PublicationHold, inventory_private_head, save_confidential_report,
)
from verify_public_snapshot import OWNER_APPROVED_ICON_GIT_BLOBS


class ConfidentialInventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mr-inventory-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.private = self.base / "private"
        self.public = self.base / "public"
        self.public.mkdir()
        self.git("init", "-q", str(self.private))
        self.git("-C", str(self.private), "config", "user.name", "Synthetic")
        self.git("-C", str(self.private), "config", "user.email", "ci@example.invalid")
        self.git("-C", str(self.private), "remote", "add", "origin",
                 "https://github.com/easonliu714/meeting-recorder.git")
        self.write("lib/main.dart", b"void main() {}\n")
        self.write("lib/secret.dart", b"const token = 'ghp_" + b"x" * 30 + b"';")
        self.write("docs/owner.md", b"phone=0912345678")
        self.write("recordings/private.wav", b"RIFF-private")
        self.write("tool/tests/test_private_ci_event_policy.py", b"private test")
        self.write("assets/app_icon.png", b"synthetic-approved-icon")
        self.head = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL).decode().strip()

    def write(self, path, data):
        target = self.private / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def commit(self):
        self.git("-C", str(self.private), "add", "-A")
        self.git("-C", str(self.private), "commit", "-qm", "Synthetic")
        return self.git("-C", str(self.private), "rev-parse", "HEAD")

    def test_every_blob_sha256_and_allow_deny_hold(self):
        data = b"synthetic-approved-icon"
        blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        with patch.dict(OWNER_APPROVED_ICON_GIT_BLOBS, {"assets/app_icon.png": blob}):
            report = inventory_private_head(self.private, self.head)
        rows = {r["path"]: r for r in report["files"]}
        self.assertEqual(len(rows), 6)
        self.assertEqual(rows["assets/app_icon.png"]["decision"], "ALLOW")
        self.assertEqual(rows["lib/main.dart"]["decision"], "HOLD")
        for path in ("lib/secret.dart", "docs/owner.md", "recordings/private.wav",
                     "tool/tests/test_private_ci_event_policy.py"):
            self.assertEqual(rows[path]["decision"], "DENY")
        self.assertEqual(rows["lib/main.dart"]["sha256"], hashlib.sha256(b"void main() {}\n").hexdigest())
        self.assertNotIn("ghp_", json.dumps(report))
        self.assertEqual(sum(report["counts"].values()), len(rows))

    def test_candidate_conservation_and_no_unreviewed_publication(self):
        self.write("android/app/build.gradle.kts",
                   b'android { defaultConfig { applicationId = "com.example.meeting_recorder" } }')
        self.write("lib/safe.dart", b"int safeValue() => 42;\n")
        self.write("lib/preferences.dart", b"SharedPreferences.getInstance();")
        self.write("pubspec.lock", b"packages:\n  example: third_party\n")
        self.write("tool/private_exact_head_inventory.py", b"private inventory")
        self.head = self.commit()
        report = inventory_private_head(self.private, self.head)
        rows = {row["path"]: row for row in report["files"]}
        audit = report["candidate_audit"]
        self.assertEqual(audit["tracked"], len(rows))
        self.assertEqual(audit["candidate"] + audit["excluded"], len(rows))
        self.assertEqual(sum(audit["states"].values()), audit["candidate"])
        self.assertEqual(audit["actually_copied"], 0)
        self.assertEqual(rows["lib/safe.dart"]["audit_status"], "PASS_AS_IS")
        self.assertEqual(rows["lib/preferences.dart"]["audit_status"], "HOLD_REVIEW")
        self.assertEqual(rows["lib/secret.dart"]["audit_status"], "HOLD_REVIEW")
        self.assertEqual(rows["pubspec.lock"]["audit_status"], "HOLD_REVIEW")
        self.assertEqual(rows["android/app/build.gradle.kts"]["audit_status"],
                         "NEEDS_SANITIZATION")
        self.assertIsNone(rows["android/app/build.gradle.kts"]["safe_copy_sha256"])
        self.assertFalse(rows["tool/private_exact_head_inventory.py"]["candidate"])
        self.assertIsNone(rows["tool/private_exact_head_inventory.py"]["audit_status"])
        self.assertEqual(
            audit["copyable"],
            audit["states"]["PASS_AS_IS"] + audit["states"]["PASS_SANITIZED"],
        )
        self.assertNotIn("ghp_", json.dumps(report))

    def test_modified_candidate_blob_and_unreviewed_binary_fail_closed(self):
        self.write("lib/safe.dart", b"const key = 'gsk_" + b"x" * 40 + b"';")
        self.write("android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png",
                   b"not-a-png")
        self.head = self.commit()
        report = inventory_private_head(self.private, self.head)
        rows = {row["path"]: row for row in report["files"]}
        self.assertEqual(rows["lib/safe.dart"]["audit_status"], "HOLD_REVIEW")
        self.assertEqual(
            rows["android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png"]["audit_status"],
            "HOLD_REVIEW",
        )
        self.assertEqual(report["candidate_audit"]["actually_copied"], 0)

    def test_wrong_head_origin_and_mutated_worktree_are_handled(self):
        with self.assertRaisesRegex(PublicationHold, "CHECKOUT_HEAD"):
            inventory_private_head(self.private, "0" * 40)
        self.write("lib/main.dart", b"dirty uncommitted")
        report = inventory_private_head(self.private, self.head)
        row = next(x for x in report["files"] if x["path"] == "lib/main.dart")
        self.assertEqual(row["sha256"], hashlib.sha256(b"void main() {}\n").hexdigest())
        self.git("-C", str(self.private), "remote", "set-url", "origin",
                 "https://github.com/foreign/meeting-recorder.git")
        with self.assertRaisesRegex(PublicationHold, "REPOSITORY_IDENTITY_HOLD"):
            inventory_private_head(self.private, self.head)

    def test_inventory_rejects_lookalike_github_origins_before_reading_blobs(self):
        # Negative: suffix-based origin matching must not trust a lookalike host,
        # URL userinfo, an extra path component, or a foreign SSH host.
        forged = (
            "https://notgithub.com/easonliu714/meeting-recorder.git",
            "https://github.com@evil.example/easonliu714/meeting-recorder.git",
            "ssh://git@github.com.evil.example/easonliu714/meeting-recorder.git",
            "https://github.com/easonliu714/meeting-recorder.git/extra",
        )
        for remote in forged:
            with self.subTest(remote=remote):
                self.git("-C", str(self.private), "remote", "set-url", "origin", remote)
                with self.assertRaisesRegex(PublicationHold, "REPOSITORY_IDENTITY_HOLD"):
                    inventory_private_head(self.private, self.head)
        # Positive: exact HTTPS and SSH canonical origins still work.
        for remote in (
            "https://github.com/easonliu714/meeting-recorder.git",
            "git@github.com:easonliu714/meeting-recorder.git",
        ):
            with self.subTest(remote=remote):
                self.git("-C", str(self.private), "remote", "set-url", "origin", remote)
                report = inventory_private_head(self.private, self.head)
                self.assertEqual(report["private_source_head"], self.head)
                self.assertEqual(len(report["files"]), 6)

    def test_report_is_private_0600_and_never_inside_public_or_private(self):
        report = inventory_private_head(self.private, self.head)
        path = self.base / "owner-confidential.json"
        save_confidential_report(report, path, self.private, self.public)
        self.assertEqual(json.loads(path.read_text())["private_source_head"], self.head)
        if os.name == "posix":
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with self.assertRaisesRegex(PublicationHold, "DESTINATION"):
            save_confidential_report(report, path, self.private, self.public)
        for target in (self.private / "inventory.json", self.public / "inventory.json"):
            with self.assertRaisesRegex(PublicationHold, "DESTINATION"):
                save_confidential_report(report, target, self.private, self.public)


if __name__ == "__main__":
    unittest.main()
