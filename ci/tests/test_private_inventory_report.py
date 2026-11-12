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


    def test_confidential_dataflow_evidence_is_line_only_and_fail_closed(self):
        # Positive: real executable dataflow is located by line and category,
        # while standalone comments are ignored without shifting line numbers.
        self.write("lib/evidence.dart",
                   b"// Authorization SharedPreferences apiKey documentation\n"
                   b"final prefs = SharedPreferences.getInstance();\n"
                   b"final h = 'Authorization: Bearer runtime';\n")
        self.write("lib/multiline_evidence.dart",
                   b"const embedded = '''\n// Authorization\n''';\n")
        secret = b"gsk_" + b"x" * 40
        self.write("lib/secret_evidence.dart",
                   b"const leaked = '" + secret + b"';\n")
        self.head = self.commit()
        report = inventory_private_head(self.private, self.head)
        rows = {row["path"]: row for row in report["files"]}
        self.assertEqual(rows["lib/evidence.dart"]["audit_status"],
                         "HOLD_REVIEW")
        self.assertEqual(rows["lib/evidence.dart"]["review_evidence"], [
            {"kind": "LOCAL_PREFERENCES", "lines": [2], "truncated": False},
            {"kind": "AUTHORIZATION", "lines": [3], "truncated": False},
        ])
        self.assertEqual(rows["lib/multiline_evidence.dart"]["review_evidence"],
                         [{"kind": "AUTHORIZATION", "lines": [2],
                           "truncated": False}])
        self.assertEqual(rows["lib/secret_evidence.dart"]["audit_status"],
                         "HOLD_REVIEW")
        self.assertEqual(rows["lib/secret_evidence.dart"]["review_evidence"], [])
        # Regex literals must compile and locate actual File()/image.path
        # references without treating documentation as executable.
        from private_inventory_report import dataflow_review_evidence
        self.assertEqual(
            dataflow_review_evidence("lib/io.dart",
                                     b"// File(path) image.path\n"
                                     b"final f = File(path);\n"
                                     b"final p = image.path;\n"),
            [{"kind": "MEDIA_PATH", "lines": [3], "truncated": False},
             {"kind": "FILE_IO", "lines": [2], "truncated": False}],
        )
        self.assertNotIn(secret.decode(), json.dumps(report))
        self.assertEqual(sum(report["candidate_audit"]["states"].values()),
                         report["candidate_audit"]["candidate"])

    def test_comment_only_dataflow_is_not_secret_but_executable_remains_hold(self):
        # Positive: documentation names do not create a runtime data leak.
        # Negative: real executable paths, multiline literals and credentials
        # remain blocked. The Private tracked originals are never rewritten.
        self.write("lib/documentation.dart",
                   b"/// Authorization is not a provider grant.\n"
                   b"// SharedPreferences apiKey File(path) are documentation.\n"
                   b"int localValue() => 42;\n")
        self.write("lib/executable.dart",
                   b"final header = 'Authorization: Bearer runtime';\n")
        self.write("lib/preferences.dart",
                   b"final prefs = SharedPreferences.getInstance();\n")
        self.write("android/app/src/main/AndroidManifest.xml",
                   b"<manifest><![CDATA[\n// Authorization: Bearer runtime\n"
                   b"]]></manifest>\n")
        self.write("lib/multiline.dart",
                   b"const embedded = '''\n// Authorization: Bearer runtime\n''';\n")
        secret = b"gsk_" + b"x" * 40
        self.write("lib/secret_comment.dart", b"/// " + secret + b"\n")
        self.head = self.commit()
        report = inventory_private_head(self.private, self.head)
        rows = {row["path"]: row for row in report["files"]}
        self.assertEqual(rows["lib/documentation.dart"]["audit_status"],
                         "PASS_AS_IS")
        self.assertEqual(rows["lib/documentation.dart"]["decision"], "HOLD")
        for name in ("lib/executable.dart", "lib/preferences.dart",
                     "lib/multiline.dart", "lib/secret_comment.dart",
                     "android/app/src/main/AndroidManifest.xml"):
            self.assertEqual(rows[name]["audit_status"], "HOLD_REVIEW", name)
        self.assertEqual(rows["lib/secret_comment.dart"]["decision"], "DENY")
        self.assertNotIn(secret.decode(), json.dumps(report))
        counts = report["candidate_audit"]
        self.assertEqual(counts["candidate"], sum(counts["states"].values()))
        self.assertEqual(counts["tracked"],
                         counts["candidate"] + counts["excluded"])


    def test_real_secret_in_gradle_is_hold_not_ordinary_id_sanitization(self):
        # Negative: a leaked credential in the Gradle source must not be
        # classified as a routine app-ID rewrite; Private bytes remain intact.
        secret = b"gsk_" + b"x" * 40
        self.write("android/app/build.gradle.kts",
                   b'android { defaultConfig { applicationId = "com.example.meeting_recorder" } }\n'
                   + b"// credential " + secret + b"\n")
        self.head = self.commit()
        report = inventory_private_head(self.private, self.head)
        row = next(x for x in report["files"]
                   if x["path"] == "android/app/build.gradle.kts")
        self.assertEqual(row["decision"], "DENY")
        self.assertEqual(row["audit_status"], "HOLD_REVIEW")
        self.assertIsNone(row["safe_copy_sha256"])
        self.assertNotIn(secret.decode(), json.dumps(report))
        self.assertEqual(sum(report["candidate_audit"]["states"].values()),
                         report["candidate_audit"]["candidate"])


    def test_private_report_cannot_promote_dataflow_hold_with_forged_counts(self):
        # Positive: an unmodified full-tree scanner report is bound to HEAD.
        # Negative: a forged PASS_AS_IS and internally consistent counts must
        # not turn SharedPreferences dataflow into a Public-export allowlist.
        from prepare_public_snapshot import (
            read_candidate_allowlist, verify_candidate_report_against_private_tree,
        )
        self.write("lib/preferences.dart",
                   b"SharedPreferences.getInstance();\\n")
        self.write("lib/safe.dart", b"int safeValue() => 42;\\n")
        self.head = self.commit()
        original = inventory_private_head(self.private, self.head)
        path = self.base / "confidential-report.json"
        path.write_text(json.dumps(original), encoding="utf-8")
        verify_candidate_report_against_private_tree(self.private, self.head, path)

        forged = json.loads(json.dumps(original))
        row = next(x for x in forged["files"]
                   if x["path"] == "lib/preferences.dart")
        self.assertEqual(row["audit_status"], "HOLD_REVIEW")
        self.assertEqual(row["decision"], "HOLD")
        row["audit_status"] = "PASS_AS_IS"
        row["audit_reason"] = "BATCH_OWNER_RIGHTS_AND_STATIC_SCAN_PASS"
        states = forged["candidate_audit"]["states"]
        states["HOLD_REVIEW"] -= 1
        states["PASS_AS_IS"] += 1
        forged["candidate_audit"]["copyable"] += 1
        path.write_text(json.dumps(forged), encoding="utf-8")
        # A schema/conservation-only parser would accept this promotion.
        self.assertIn("lib/preferences.dart",
                      read_candidate_allowlist(path, self.head))
        with self.assertRaisesRegex(PublicationHold, "RESCAN_MISMATCH"):
            verify_candidate_report_against_private_tree(
                self.private, self.head, path)

        # Also reject a forged source hash, even if both digest fields agree.
        forged = json.loads(json.dumps(original))
        row = next(x for x in forged["files"] if x["path"] == "lib/safe.dart")
        self.assertEqual(row["audit_status"], "PASS_AS_IS")
        row["sha256"] = "a" * 64
        row["source_sha256"] = "a" * 64
        path.write_text(json.dumps(forged), encoding="utf-8")
        with self.assertRaisesRegex(PublicationHold, "RESCAN_MISMATCH"):
            verify_candidate_report_against_private_tree(
                self.private, self.head, path)
        with self.assertRaisesRegex(PublicationHold, "REPORT_MISSING"):
            verify_candidate_report_against_private_tree(
                self.private, self.head, self.base / "missing.json")


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



    def test_confidential_report_never_enters_unrelated_git_repositories(self):
        # Positive: a genuinely non-Git owner-local directory remains writable,
        # even when an inherited GIT_DIR tries to redirect the probe.
        report = inventory_private_head(self.private, self.head)
        clean = self.base / "clean-report.json"
        with patch.dict(os.environ, {
            "GIT_DIR": str(self.private / ".git"),
            "GIT_WORK_TREE": str(self.private),
        }):
            save_confidential_report(report, clean, self.private, self.public)
        self.assertTrue(clean.is_file())

        # Negative: a foreign worktree, nested directory, and bare repository
        # are all unsafe, even though none is inside the known two checkouts.
        foreign = self.base / "foreign"
        bare = self.base / "bare.git"
        self.git("init", "-q", str(foreign))
        self.git("init", "--bare", "-q", str(bare))
        nested = foreign / "nested" / "reports"
        nested.mkdir(parents=True)
        for parent in (foreign, nested, bare):
            target = parent / "confidential.json"
            with self.subTest(parent=parent):
                with self.assertRaisesRegex(PublicationHold, "GIT_REPOSITORY_HOLD"):
                    save_confidential_report(
                        report, target, self.private, self.public)
                self.assertFalse(target.exists())

        # Negative: Git failure other than the exact non-repository condition
        # is ambiguous and must not be treated as permission to write.
        ambiguous = subprocess.CompletedProcess(
            args=["git"], returncode=1, stdout=b"",
            stderr=b"fatal: detected dubious ownership")
        target = self.base / "ambiguous.json"
        with patch("private_inventory_report.subprocess.run",
                   return_value=ambiguous):
            with self.assertRaisesRegex(PublicationHold, "GIT_PROBE_HOLD"):
                save_confidential_report(
                    report, target, self.private, self.public)
        self.assertFalse(target.exists())

    def test_new_private_exporter_preflight_and_tests_are_excluded(self):
        # Positive: real application Source remains a candidate. Negative:
        # the trusted Private-runner-only preflight is never published.
        private_paths = (
            "tool/private_public_export_preflight.py",
            "tool/tests/test_private_public_export_preflight.py",
        )
        for path in private_paths:
            self.write(path, b"Private-only CI handoff, never Public App Source\\n")
        self.write("lib/safe_app.dart", b"int safeApp() => 7;\\n")
        self.head = self.commit()
        report = inventory_private_head(self.private, self.head)
        rows = {row["path"]: row for row in report["files"]}
        for path in private_paths:
            self.assertFalse(rows[path]["candidate"])
            self.assertIsNone(rows[path]["audit_status"])
            self.assertEqual(rows[path]["audit_reason"],
                             "EXCLUDED_FROM_PUBLIC_APP_SCOPE")
        self.assertTrue(rows["lib/safe_app.dart"]["candidate"])
        self.assertEqual(rows["lib/safe_app.dart"]["audit_status"], "PASS_AS_IS")
        self.assertEqual(report["candidate_audit"]["tracked"], len(rows))
        self.assertEqual(report["candidate_audit"]["candidate"] +
                         report["candidate_audit"]["excluded"], len(rows))


if __name__ == "__main__":
    unittest.main()
