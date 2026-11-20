#!/usr/bin/env python3
"""Owner T05 v23: bounded local MP3 tail-origin replay, never a Provider retry.

Static native safeguards plus independently exercised observed/negative
eligibility models; physical Android MediaCodec proof remains Owner UAT.
"""
from pathlib import Path
import unittest

LAB = Path(__file__).resolve().parents[1]
NATIVE = (LAB / "native/GroqLabAudioDecoder.kt").read_text(encoding="utf-8")
DART = (LAB / "lib/lab_audio_pipeline.dart").read_text(encoding="utf-8")
UI = (LAB / "lib/main.dart").read_text(encoding="utf-8")


def model_allows_tail_replay(kind, start_ms, end_ms, expected, decoded,
                             first_pts_us, last_pts_us):
    missing = expected - decoded
    return (
        kind == "audio/mpeg" and 0 < start_ms < end_ms <= 900000
        and expected > 0 and decoded > 0 and 321 <= missing <= 32000
        and 0 <= first_pts_us <= start_ms * 1000
        and end_ms * 1000 - 2000000 <= last_pts_us < end_ms * 1000
    )


class Mp3OriginReplayContract(unittest.TestCase):
    def test_owner_12m_mp3_second_window_is_eligible_for_one_local_attempt(self):
        self.assertTrue(model_allows_tail_replay(
            "audio/mpeg", 358019, 720039, 5792320, 5781512,
            357033126, 719363466))

    def test_negative_and_protected_source_cases(self):
        known = ("audio/mpeg", 358019, 720039, 5792320, 5781512,
                 357033126, 719363466)
        self.assertFalse(model_allows_tail_replay("audio/mp4a-latm", *known[1:]))
        self.assertFalse(model_allows_tail_replay(
            "audio/mpeg", 0, 720039, *known[3:]))
        self.assertFalse(model_allows_tail_replay(
            "audio/mpeg", 358019, 900001, *known[3:]))
        self.assertFalse(model_allows_tail_replay(
            "audio/mpeg", 358019, 720039, 5792320, 5700000,
            357033126, 719363466))
        self.assertFalse(model_allows_tail_replay(
            "audio/mpeg", 358019, 720039, 5792320, 5781512,
            360000000, 719363466))
        self.assertFalse(model_allows_tail_replay(
            "audio/mpeg", 358019, 720039, 5792320, 5781512,
            357033126, 710000000))
        self.assertFalse(model_allows_tail_replay(
            "audio/mpeg", 358019, 720039, 5792320, 5792320,
            357033126, 719363466))

    def test_native_origin_seek_cannot_bypass_original_hard_pcm_gate(self):
        for required in (
            "eligibleForOriginReplay(first.safeMetrics, startMs, endMs)",
            'actualMime != "audio/mpeg"',
            "MAX_REPLAY_END_MS = 15L * 60L * 1000L",
            "MAX_REPLAY_MISSING_FRAMES = 32_000L",
            "missing in 321L..MAX_REPLAY_MISSING_FRAMES",
            "fromOrigin = false", "fromOrigin = true",
            "if (fromOrigin) 0L else maxOf(0L, startUs - 1_000_000L)",
            "frames + leadingFrames >= expected - 320L",
            "lastDecodedUs >= endUs - 25_000L",
            "if (!completed) output?.delete()",
            "sha256(source) == originalSha",
            "mp3OriginReplay",
            "last_input_pts_us", "input_eos_queued", "output_eos_seen",
        ):
            self.assertIn(required, NATIVE, required)
        self.assertEqual(NATIVE.count("fromOrigin = true"), 1)
        self.assertIn("LabNativePcmCoverage.accepts(", DART)
        self.assertIn("STAGE_MP3_ORIGIN_REPLAY_OK", UI)
        self.assertIn("mp3_origin_replay_attempted", UI)
        self.assertIn("providerUploadAuthorized", NATIVE)
        self.assertNotIn("MediaCodec.BUFFER_FLAG_CODEC_CONFIG", NATIVE)

if __name__ == "__main__":
    unittest.main()
