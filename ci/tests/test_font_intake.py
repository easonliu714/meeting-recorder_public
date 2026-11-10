"""H04J original font intake: offline positive and negative publication gates.

The real TTF and OFL files are provided by the Owner in this Public branch.
CI must NOT call this an application-source snapshot or package an APK.
"""
from pathlib import Path
import hashlib
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ci"))
from verify_public_snapshot import (  # noqa: E402
    BOOTSTRAP_FILES, ORIGINAL_FONT_ASSETS, PublicationHold, audit,
)


class OriginalFontIntakeTests(unittest.TestCase):
    def test_uploaded_fonts_and_ofl_match_original_private_git_blobs(self):
        for path, (size, digest) in ORIGINAL_FONT_ASSETS.items():
            with self.subTest(path=path):
                payload = (ROOT / path).read_bytes()
                self.assertEqual(len(payload), size)
                self.assertEqual(hashlib.sha256(payload).hexdigest(), digest)
        self.assertIn(audit(ROOT), ("FONT_ASSETS_READY", "SOURCE_INTEGRITY_READY"))

    def test_partial_or_unlisted_font_intake_does_not_count_as_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp)
            for path in BOOTSTRAP_FILES:
                p = dest / path
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("bootstrap", encoding="utf-8")
            (dest / "assets/fonts").mkdir(parents=True, exist_ok=True)
            (dest / "assets/fonts/NotoSansTC-Regular.ttf").write_bytes(b"partial")
            with self.assertRaisesRegex(PublicationHold, "UNATTESTED_SOURCE"):
                audit(dest)

    def test_complete_named_pair_with_modified_content_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp)
            for path in BOOTSTRAP_FILES:
                p = dest / path
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("bootstrap", encoding="utf-8")
            for path in ORIGINAL_FONT_ASSETS:
                p = dest / path
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b"fake")
            with self.assertRaisesRegex(PublicationHold, "ORIGINAL_FONT_BYTES_MISMATCH"):
                audit(dest)

    def test_untracked_private_material_blocks_font_intake(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp)
            for path in BOOTSTRAP_FILES:
                p = dest / path
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("bootstrap", encoding="utf-8")
            for path in ORIGINAL_FONT_ASSETS:
                p = dest / path
                p.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / path, p)
            (dest / "credentials.json").write_text("not public", encoding="utf-8")
            with self.assertRaisesRegex(PublicationHold, "UNATTESTED_SOURCE"):
                audit(dest)


if __name__ == "__main__":
    unittest.main()
