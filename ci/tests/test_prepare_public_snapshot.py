"""Fail-closed, zero-network tests for local sanitized Public snapshot export."""
import hashlib
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_public_snapshot import (  # noqa: E402
    EXPECTED_FONT_ASSETS, PublicationHold, inspect_bytes, tracked_entries,
)


class LocalPublicSnapshotExportTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
