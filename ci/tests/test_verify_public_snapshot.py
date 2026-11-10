"""Negative and positive security regression tests for the public CI mirror."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_public_snapshot import (  # noqa: E402
    BOOTSTRAP_FILES, ORIGINAL_FONT_ASSETS, REQUIRED_SOURCE_FILES, PublicationHold, audit,
)


class PublicationBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for path in BOOTSTRAP_FILES:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("bootstrap", encoding="utf-8")

    def make_source(self):
        paths = sorted(REQUIRED_SOURCE_FILES)
        for path in paths:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            # Font integrity is a separate non-negotiable prerequisite.
            # The successful manifest fixture must contain the real pinned
            # Owner binaries; negative tests still mutate only their target.
            if path in ORIGINAL_FONT_ASSETS:
                target.write_bytes((Path(__file__).resolve().parents[2] / path).read_bytes())
            else:
                target.write_bytes(("fixture: " + path).encode())
        rows = [
            {"path": path, "sha256": hashlib.sha256(
                (self.root / path).read_bytes()).hexdigest()}
            for path in paths
        ]
        manifest = {
            "schema": 1, "private_source_head": "a" * 40, "files": rows
        }
        (self.root / "ci/public_snapshot_manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )

    def test_empty_bootstrap_is_not_application_pass(self):
        self.assertEqual(audit(self.root), "BOOTSTRAP_ONLY")

    def test_digest_bound_clean_snapshot_can_enter_next_gate(self):
        self.make_source()
        self.assertEqual(audit(self.root), "SOURCE_INTEGRITY_READY")

    def test_digest_tamper_fails_closed(self):
        self.make_source()
        (self.root / "lib/main.dart").write_text("tampered", encoding="utf-8")
        with self.assertRaisesRegex(PublicationHold, "DIGEST_MISMATCH"):
            audit(self.root)

    def test_unlisted_private_evidence_is_blocked(self):
        self.make_source()
        extra = self.root / "evidence/owner_transcript.md"
        extra.parent.mkdir(parents=True, exist_ok=True)
        extra.write_text("not for publication", encoding="utf-8")
        with self.assertRaisesRegex(PublicationHold, "UNATTESTED_OR_EXTRA_FILE"):
            audit(self.root)

    def test_forbidden_private_ci_contract_cannot_be_listed(self):
        self.make_source()
        path = "tool/tests/test_mr_windows_smoke_workflow.py"
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("test", encoding="utf-8")
        manifest = self.root / "ci/public_snapshot_manifest.json"
        doc = json.loads(manifest.read_text(encoding="utf-8"))
        doc["files"].append({
            "path": path,
            "sha256": hashlib.sha256(b"test").hexdigest()
        })
        doc["files"] = sorted(doc["files"], key=lambda item: item["path"])
        manifest.write_text(json.dumps(doc), encoding="utf-8")
        with self.assertRaisesRegex(PublicationHold, "UNSAFE_SOURCE"):
            audit(self.root)

    def test_secret_like_content_fails_closed_even_with_matching_digest(self):
        self.make_source()
        p = self.root / "lib/main.dart"
        p.write_text("const token = 'ghp_" + "a" * 28 + "';", encoding="utf-8")
        manifest = self.root / "ci/public_snapshot_manifest.json"
        doc = json.loads(manifest.read_text(encoding="utf-8"))
        for row in doc["files"]:
            if row["path"] == "lib/main.dart":
                row["sha256"] = hashlib.sha256(p.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(doc), encoding="utf-8")
        with self.assertRaisesRegex(PublicationHold, "SENSITIVE_TEXT_PATTERN"):
            audit(self.root)

    def test_unmanifested_binary_icon_is_blocked(self):
        extra = self.root / "assets/app_icon.png"
        extra.parent.mkdir(parents=True, exist_ok=True)
        extra.write_bytes(b"\x89PNG fake")
        with self.assertRaisesRegex(PublicationHold, "UNATTESTED_SOURCE"):
            audit(self.root)


if __name__ == "__main__":
    unittest.main()
