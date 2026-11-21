#!/usr/bin/env python3
"""Opt-in real microphone Lab capture source-only contract."""
from pathlib import Path
import unittest

LAB = Path(__file__).resolve().parents[1]
CAPTURE = (LAB / "native/LabMicPartRecorder.kt").read_text(encoding="utf-8")
MAIN = (LAB / "native/MainActivity.kt").read_text(encoding="utf-8")
DART = (LAB / "lib/lab_mic_capture.dart").read_text(encoding="utf-8")
UI = (LAB / "lib/main.dart").read_text(encoding="utf-8")
BOOT = (LAB / "tool/bootstrap.sh").read_text(encoding="utf-8")
IDENTITY = (LAB / "tool/verify_android_identity.py").read_text(encoding="utf-8")

class MicWitness(unittest.TestCase):
    def test_real_audio_record_is_one_stream_two_parts_no_silence_forgery(self):
        for token in (
            "AudioRecord(MediaRecorder.AudioSource.MIC",
            "AudioRecord.READ_BLOCKING",
            "recorder.read(chunk",
            "SystemClock.elapsedRealtimeNanos()",
            "PART_FRAMES = 48000",
            "PART_COUNT = 2",
            "frameStart", "frameEnd",
            "FileOutputStream(file, false).use",
            "file.createNewFile()",
            "output.fd.sync()",
            "startedMonoNs",
            "endedMonoNs",
            "recorder.release()"
        ):
            self.assertIn(token, CAPTURE)
        for forbidden in ("HttpClient", "MediaCodec.createEncoder",
                          "MediaRecorder.OutputFormat", "source.delete()",
                          "AudioRecord.READ_NON_BLOCKING"):
            self.assertNotIn(forbidden, CAPTURE)

    def test_permission_and_exact_owner_click_only(self):
        for token in ('android.Manifest', 'captureLabMicParts',
                      'LAB_MIC_PERMISSION_REQUIRED_HOLD',
                      'android.permission.RECORD_AUDIO'):
            self.assertIn(token, MAIN + BOOT)
        self.assertIn('LabMicPartRecorder.capture(applicationContext)', MAIN)
        self.assertIn('key: const Key(\'lab-mic-capture\')', UI)
        self.assertIn('LAB_MIC_CAPTURE_OK', UI)
        self.assertIn('LAB_MIC_CAPTURE_HOLD', UI)
        self.assertIn('LAB_MIC_SOURCE_CHANGED_HOLD', DART)
        self.assertIn('LabPartRoster.verify(receipts)', DART)
        self.assertNotIn("'source_path':", UI)
        self.assertNotIn("'api_key':", UI)
        self.assertIn('LabMicPartRecorder.kt', BOOT)
        self.assertIn('"LabMicPartRecorder"', IDENTITY)

if __name__ == "__main__":
    unittest.main()
