#!/usr/bin/env python3
"""Native packet-PTS inspection contract: source-local and read-only."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
NATIVE = (ROOT / "native/GroqLabAudioDecoder.kt").read_text(encoding="utf-8")
ACTIVITY = (ROOT / "native/MainActivity.kt").read_text(encoding="utf-8")
DART = (ROOT / "lib/lab_part_native_pts.dart").read_text(encoding="utf-8")
UI = (ROOT / "lib/main.dart").read_text(encoding="utf-8")

class NativePartPtsContract(unittest.TestCase):
    def test_real_extractor_sample_clock_and_bounds(self):
        self.assertIn("fun inspectSourcePts(sourcePath: String)", NATIVE)
        part = NATIVE.split("fun inspectSourcePts(sourcePath: String)", 1)[1]
        part = part.split("fun decodeWindow(", 1)[0]
        for token in ("MediaExtractor()", "extractor.sampleTime",
                      "extractor.sampleTrackIndex", "extractor.advance()",
                      "LAB_PART_NATIVE_PTS_NON_MONOTONIC_HOLD",
                      "LAB_PART_NATIVE_PTS_GAP_HOLD",
                      "LAB_PART_NATIVE_PTS_PACKET_LIMIT_HOLD",
                      "source.length()", "source.lastModified()",
                      "extractor.release()"):
            self.assertIn(token, part)
        for forbidden in ("source.delete()", "setDataSource(FileOutputStream",
                          "MediaCodec.createDecoderByType", "HttpClient"):
            self.assertNotIn(forbidden, part)

    def test_channel_bounded_source_and_scoped_log(self):
        self.assertIn('"inspectPartPts" -> GroqLabAudioDecoder.inspectSourcePts(sourcePath)', ACTIVITY)
        self.assertIn('GroqLabAudioDecoder.inspectSourcePts(sourcePath)', ACTIVITY)
        for token in ("LabPartRoster.verify(parts)", "sourceBytes",
                      "firstPtsUs", "lastPtsUs", "maxGapUs",
                      "LAB_PART_NATIVE_PTS_WAV_UNSUPPORTED_HOLD"):
            self.assertIn(token, DART)
        self.assertIn("PART_NATIVE_PTS_OK", UI)
        self.assertIn("PART_NATIVE_PTS_HOLD", UI)
        self.assertNotIn("'source_path':", UI)
        self.assertNotIn("'api_key':", UI)

if __name__ == "__main__":
    unittest.main()
