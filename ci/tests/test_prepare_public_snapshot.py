"""Fail-closed, zero-network tests for local sanitized Public snapshot export."""
import hashlib
import json
import os
import subprocess
from unittest.mock import patch
import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_public_snapshot import (  # noqa: E402
    EXPECTED_FONT_ASSETS, PublicationHold, inspect_bytes, tracked_entries,
    read_approved_scope, verify_approved_rows, transform_public_source, git,
    verify_public_checkout_clean, require_trusted_repo_origin,
)
from verify_public_snapshot import (  # noqa: E402
    OWNER_APPROVED_ICON_GIT_BLOBS, _allowed_source,
)


class LocalPublicSnapshotExportTests(unittest.TestCase):

    def test_exact_gradle_transform_preserves_namespace_and_min_sdk(self):
        original = (
            'namespace = "com.example.myapp"\n'
            'applicationId = "com.example.meeting_recorder" // existing\n'
            'minSdk = 21\n'
        ).encode()
        output = transform_public_source("android/app/build.gradle.kts", original)
        self.assertIn(b'applicationId = "com.example.meeting_recorder.public"', output)
        self.assertIn(b'namespace = "com.example.myapp"', output)
        self.assertIn(b'minSdk = 21', output)
        self.assertNotEqual(hashlib.sha256(output).digest(), hashlib.sha256(original).digest())
        self.assertEqual(transform_public_source("lib/main.dart", original), original)

    def test_gradle_transform_rejects_missing_duplicate_suffix_and_legacy(self):
        cases = (
            b'// applicationId = "com.example.meeting_recorder"\n',
            b'applicationId = "com.example.meeting_recorder.public"\n',
            b'applicationId = "com.example.meeting_recorder"\n'
            b'applicationId = "com.example.meeting_recorder"\n',
            b'applicationId = "com.example.meeting_recorder"\n'
            b'applicationIdSuffix = ".debug"\n',
            b'applicationId = "com.example.meeting_recorder"\n'
            b'// old com.example.meeting_recorder\n',
        )
        for original in cases:
            with self.subTest(case=original[:40]):
                with self.assertRaisesRegex(PublicationHold, "PUBLIC_GRADLE_"):
                    transform_public_source("android/app/build.gradle.kts", original)


    def test_exact_owner_icon_allowlist_only_not_arbitrary_png(self):
        self.assertEqual(len(OWNER_APPROVED_ICON_GIT_BLOBS), 11)
        for path in OWNER_APPROVED_ICON_GIT_BLOBS:
            with self.subTest(path=path):
                self.assertTrue(_allowed_source(path))
                with self.assertRaisesRegex(PublicationHold, "OWNER_ICON_BLOB_MISMATCH"):
                    inspect_bytes(path, b"fake png or unapproved replacement")
        for path in ("assets/owner_photo.png", "web/icons/Icon-192.png",
                     "android/app/src/main/res/mipmap-mdpi/private.png"):
            self.assertFalse(_allowed_source(path))

    def test_private_scope_approval_exact_head_rights_and_privacy(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "private-scope.json"
            row = {"path": "lib/main.dart", "sha256": "a" * 64,
                   "rights": "OWNER_PASS", "privacy": "REVIEW_PASS"}
            doc = {"schema": 1, "private_source_head": "b" * 40,
                   "files": [row]}
            p.write_text(json.dumps(doc), encoding="utf-8")
            self.assertEqual(read_approved_scope(p, "b" * 40),
                             {"lib/main.dart": "a" * 64})
            with self.assertRaisesRegex(PublicationHold, "HEAD_OR_SCHEMA"):
                read_approved_scope(p, "c" * 40)
            for key, value in (("rights", "HOLD"), ("privacy", "HOLD")):
                bad = json.loads(json.dumps(doc))
                bad["files"][0][key] = value
                p.write_text(json.dumps(bad), encoding="utf-8")
                with self.assertRaisesRegex(PublicationHold, "UNAPPROVED"):
                    read_approved_scope(p, "b" * 40)
            doc["files"].append(dict(row))
            p.write_text(json.dumps(doc), encoding="utf-8")
            with self.assertRaisesRegex(PublicationHold, "DUPLICATE"):
                read_approved_scope(p, "b" * 40)

    def test_approved_source_scope_must_match_every_path_and_sha(self):
        rows = [{"path": "lib/main.dart", "sha256": "a" * 64}]
        verify_approved_rows(rows, {"lib/main.dart": "a" * 64})
        with self.assertRaisesRegex(PublicationHold, "FILE_SET"):
            verify_approved_rows(rows, {"lib/other.dart": "a" * 64})
        with self.assertRaisesRegex(PublicationHold, "SHA256"):
            verify_approved_rows(rows, {"lib/main.dart": "b" * 64})

    def test_owner_original_font_and_ofl_pins_do_not_drift(self):
        self.assertEqual(set(EXPECTED_FONT_ASSETS), {
            "assets/fonts/NotoSansTC-Regular.ttf",
            "assets/fonts/NotoSansTC-Bold.ttf",
            "assets/fonts/OFL.txt",
        })
        for name, (size, digest) in EXPECTED_FONT_ASSETS.items():
            with self.subTest(name=name):
                self.assertGreater(size, 4000)
                self.assertEqual(len(digest), 64)

    def test_tampered_original_regular_font_is_refused(self):
        with self.assertRaisesRegex(PublicationHold, "ORIGINAL_FONT"):
            inspect_bytes("assets/fonts/NotoSansTC-Regular.ttf", b"not the font")

    def test_tampered_original_bold_font_is_refused(self):
        with self.assertRaisesRegex(PublicationHold, "ORIGINAL_FONT"):
            inspect_bytes("assets/fonts/NotoSansTC-Bold.ttf", b"not the font")

    def test_tampered_original_ofl_is_refused(self):
        with self.assertRaisesRegex(PublicationHold, "ORIGINAL_FONT"):
            inspect_bytes("assets/fonts/OFL.txt", b"modified license")

    def test_limited_safe_utf8_text_is_digested(self):
        data = b"void main() { print('offline'); }\n"
        self.assertEqual(inspect_bytes("lib/benign.dart", data),
                         hashlib.sha256(data).hexdigest())

    def test_api_key_is_blocked_even_when_git_sha_is_correct(self):
        data = b"const key = 'gsk_" + b"x" * 32 + b"';"
        with self.assertRaisesRegex(PublicationHold, "SENSITIVE_SOURCE"):
            inspect_bytes("lib/main.dart", data)

    def test_private_workstation_path_is_blocked(self):
        data = b"C:\\Users\\some-account\\AppData"
        with self.assertRaisesRegex(PublicationHold, "SENSITIVE_SOURCE"):
            inspect_bytes("lib/main.dart", data)

    def test_non_utf8_nonfont_binary_is_blocked(self):
        with self.assertRaisesRegex(PublicationHold, "NON_UTF8|UNEXPECTED_BINARY"):
            inspect_bytes("lib/sneaky.dart", b"\xff\xfe\x00")

    def test_source_symlink_cannot_be_exported(self):
        from unittest.mock import patch
        class FakeGit:
            def __call__(self, *_args):
                return (b"120000 blob " + b"a"*40 +
                        b"\tlib/symlink.dart\0")
        with patch("prepare_public_snapshot.git", new=FakeGit()):
            with self.assertRaisesRegex(PublicationHold, "GIT_SYMLINK"):
                tracked_entries(Path("/does-not-matter"), "a"*40)

    def test_minimal_approved_scope_does_not_export_other_candidates(self):
        from unittest.mock import patch

        class FakeGit:
            def __call__(self, *_args):
                return b"\0".join([
                    b"100644 blob " + b"a" * 40 + b"\tlib/main.dart",
                    b"100644 blob " + b"b" * 40 + b"\ttest/main_test.dart",
                    b"100644 blob " + b"c" * 40 + b"\ttool/patch_old_private.py",
                ]) + b"\0"

        with patch("prepare_public_snapshot.git", new=FakeGit()):
            rows = tracked_entries(Path("/none"), "a" * 40,
                                   {"lib/main.dart", "test/main_test.dart"})
            self.assertEqual([row[0] for row in rows],
                             ["lib/main.dart", "test/main_test.dart"])
            with self.assertRaisesRegex(PublicationHold, "FILE_SET"):
                verify_approved_rows(
                    [{"path": name, "sha256": "a" * 64} for name, _, _ in rows],
                    {"lib/main.dart": "a" * 64, "missing.dart": "a" * 64},
                )

    def test_private_test_and_user_media_paths_are_not_exported(self):
        from unittest.mock import patch
        class FakeGit:
            def __call__(self, *_args):
                entries = [
                    b"100644 blob " + b"a"*40 + b"\tlib/groq_policy.dart",
                    b"100644 blob " + b"b"*40 + b"\ttool/tests/test_mr_windows_smoke_workflow.py",
                    b"100644 blob " + b"c"*40 + b"\trecordings/meeting.wav",
                ]
                return b"\0".join(entries) + b"\0"
        with patch("prepare_public_snapshot.git", new=FakeGit()):
            self.assertEqual(
                tracked_entries(Path("/none"), "a"*40),
                [("lib/groq_policy.dart", "100644", "a"*40)],
            )

    def test_real_git_remote_identity_positive_and_spoofed_negative(self):
        # Real Git remote reads, no network and no Private checkout.
        with tempfile.TemporaryDirectory(prefix="public-origin-") as tmp:
            root = Path(tmp) / "fixture"
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "remote", "add", "origin",
                            "https://github.com/easonliu714/meeting-recorder.git"],
                           check=True)
            for name in ("meeting-recorder", "meeting-recorder_public"):
                good = (
                    "https://github.com/easonliu714/" + name,
                    "https://github.com/easonliu714/" + name + ".git",
                    "git@github.com:easonliu714/" + name + ".git",
                    "ssh://git@github.com/easonliu714/" + name,
                )
                bad = (
                    "https://evil.example/easonliu714/" + name + ".git",
                    "https://github.com.evil.example/easonliu714/" + name,
                    "https://attacker@github.com/easonliu714/" + name,
                    "http://github.com/easonliu714/" + name,
                    "https://github.com/foreign/" + name,
                    "file:///tmp/easonliu714/" + name + ".git",
                )
                for remote in good + bad:
                    with self.subTest(name=name, remote=remote):
                        subprocess.run(["git", "-C", str(root), "remote",
                                        "set-url", "origin", remote], check=True)
                        actual = git(root, "remote", "get-url", "origin").decode().strip()
                        if remote in good:
                            require_trusted_repo_origin(actual, name)
                        else:
                            with self.assertRaisesRegex(PublicationHold, "REPOSITORY_IDENTITY"):
                                require_trusted_repo_origin(actual, name)
            with self.assertRaisesRegex(PublicationHold, "REPOSITORY_IDENTITY"):
                require_trusted_repo_origin(
                    "https://github.com/easonliu714/meeting-recorder.git", "other")

    def test_public_checkout_guard_rejects_dirty_and_head_drift(self):
        # Real local Git fixture: do not confuse a passing structural guard
        # with an immutable reviewed checkout or a safe concurrent handoff.
        with tempfile.TemporaryDirectory(prefix="public-head-guard-") as tmp:
            root = Path(tmp) / "public"
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config",
                            "user.email", "ci@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(root), "config",
                            "user.name", "Synthetic CI"], check=True)
            readme = root / "README.md"
            readme.write_text("reviewed bootstrap", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "README.md"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm",
                            "Initial reviewed bootstrap"], check=True)
            head = git(root, "rev-parse", "HEAD").decode("ascii").strip()
            self.assertEqual(verify_public_checkout_clean(root), head)
            self.assertEqual(verify_public_checkout_clean(root, head), head)

            readme.write_text("unreviewed bootstrap", encoding="utf-8")
            with self.assertRaisesRegex(PublicationHold, "WORKTREE_DIRTY"):
                verify_public_checkout_clean(root, head)
            readme.write_text("reviewed bootstrap", encoding="utf-8")

            extra = root / "untracked-secret.txt"
            extra.write_text("never publish", encoding="utf-8")
            with self.assertRaisesRegex(PublicationHold, "WORKTREE_DIRTY"):
                verify_public_checkout_clean(root, head)
            extra.unlink()

            readme.write_text("new committed bootstrap", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "README.md"], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm",
                            "Concurrent writer"], check=True)
            self.assertNotEqual(verify_public_checkout_clean(root), head)
            with self.assertRaisesRegex(PublicationHold, "HEAD_DRIFT"):
                verify_public_checkout_clean(root, head)

    def test_exporter_git_read_ignores_foreign_git_dir_and_object_store(self):
        with tempfile.TemporaryDirectory(prefix="export-git-env-") as tmp:
            root = Path(tmp)
            private = root / "private"
            foreign = root / "foreign"
            for directory in (private, foreign):
                subprocess.run(["git", "init", "-q", str(directory)],
                               check=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
            subprocess.run(["git", "-C", str(private), "config",
                            "user.email", "ci@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(private), "config",
                            "user.name", "Synthetic CI"], check=True)
            (private / "marker.txt").write_text("private exact-head", encoding="utf-8")
            subprocess.run(["git", "-C", str(private), "add", "marker.txt"], check=True)
            subprocess.run(["git", "-C", str(private), "commit", "-qm",
                            "Synthetic local test"], check=True)
            expected = subprocess.check_output(
                ["git", "-C", str(private), "rev-parse", "HEAD"]
            )
            with patch.dict(os.environ, {
                "GIT_DIR": str(foreign / ".git"),
                "GIT_WORK_TREE": str(foreign),
                "GIT_OBJECT_DIRECTORY": str(foreign / ".git" / "objects"),
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "core.bare",
                "GIT_CONFIG_VALUE_0": "true",
            }):
                self.assertEqual(git(private, "rev-parse", "HEAD"), expected)
                self.assertIn(b"marker.txt",
                              git(private, "ls-tree", "-r", "--name-only", "HEAD"))


if __name__ == "__main__":
    unittest.main()
