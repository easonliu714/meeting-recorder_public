#!/usr/bin/env python3
"""Fail-closed public Lab PCM diagnostic contract: no sensitive payloads."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DECODER = (ROOT / "native/GroqLabAudioDecoder.kt").read_text(encoding="utf-8")
ACTIVITY = (ROOT / "native/MainActivity.kt").read_text(encoding="utf-8")
UI = (ROOT / "lib/main.dart").read_text(encoding="utf-8")

class PublicPcmEvidenceTests(unittest.TestCase):
    def test_original_hard_window_gate_unchanged(self):
        for token in ("frames > 0L", "frames >= expected - 320L",
                      "frames <= expected", "firstDecodedUs <= startUs",
                      "lastDecodedUs >= endUs - 25_000L"):
            self.assertIn(token, DECODER)
        self.assertIn("throw LabPcmWindowEvidence", DECODER)
        self.assertIn("if (!completed) output?.delete()", DECODER)

    def test_only_allowlisted_numeric_metrics_exposed(self):
        keys = ("expected_frames", "decoded_frames", "first_pts_us",
                "last_pts_us", "window_start_us", "window_end_us",
                "source_duration_us")
        for key in keys:
            self.assertIn('"' + key + '" to ', DECODER)
            self.assertIn("'" + key + "'", UI)
        self.assertIn('(error as? LabPcmWindowEvidence)?.safeMetrics', ACTIVITY)
        self.assertIn("value is int && value >= -1 && value <= 172800000000", UI)
        self.assertIn("STAGE_PCM_WINDOW_METRICS", UI)
        for unsafe in ("sourcePath", "apiKey", "transcript", "sourceSha256"):
            self.assertNotIn('"' + unsafe + '" to ', DECODER[
                DECODER.index('throw LabPcmWindowEvidence'):
                DECODER.index('finishWav(file, frames)')
            ])

if __name__ == "__main__":
    unittest.main()
