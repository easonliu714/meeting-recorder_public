#!/usr/bin/env python3
"""Strict local Lab mic restart checkpoint contract: no automatic recording."""
from pathlib import Path
import unittest

LAB = Path(__file__).resolve().parents[1]
STORE = (LAB / "lib/lab_mic_checkpoint.dart").read_text(encoding="utf-8")
UI = (LAB / "lib/main.dart").read_text(encoding="utf-8")
TEST = (LAB / "test/lab_mic_capture_test.dart").read_text(encoding="utf-8")

class LabMicRestartContract(unittest.TestCase):
    def test_proof_is_immutable_local_sha_checked_metadata_not_raw_upload(self):
        for phrase in (
            "source_proof_v1.json", "latest_source_proof_v1.txt",
            "manifest.create(exclusive: true)", "temp.create(exclusive: true)",
            "await temp.rename(pointer.path)", "LabAudioPipeline.digest(file)",
            "LabMicCapture.verify(session)", "LabPartRoster.append(",
            "LAB_MIC_CHECKPOINT_SOURCE_HOLD",
            "LAB_MIC_CHECKPOINT_MISSING_HOLD",
            "LAB_MIC_CHECKPOINT_FORMAT_HOLD",
            "LAB_MIC_CHECKPOINT_ID_HOLD",
            "LAB_MIC_CHECKPOINT_EXISTS_HOLD",
            "resolveSymbolicLinks()",
        ):
            self.assertIn(phrase, STORE)
        for forbidden in (
            "source.delete(", "file.delete(", "manifest.delete(",
            "HttpClient", "MultipartRequest", "GroqStt",
            "MediaRecorder", "AudioRecord(",
        ):
            self.assertNotIn(forbidden, STORE)

    def test_restore_is_user_tap_only_and_never_restarts_mic(self):
        init = UI.split("void initState()", 1)[1].split("Future<void> _chooseAudio", 1)[0]
        self.assertNotIn("_restoreLabMicCheckpoint()", init)
        self.assertNotIn("_captureLabMicParts()", init)
        self.assertIn("key: const Key('lab-mic-restore')", UI)
        self.assertIn("onPressed: _busy ? null : _restoreLabMicCheckpoint", UI)
        self.assertIn("await _micCheckpoints.save(captured)", UI)
        self.assertIn("await _micCheckpoints.restore()", UI)
        self.assertIn("LAB_MIC_CHECKPOINT_RESTORE_OK", UI)
        self.assertIn("LAB_MIC_CHECKPOINT_RESTORE_HOLD", UI)
        self.assertNotIn("'source_path':", UI)
        self.assertNotIn("'api_key':", UI)
        # Original Free UI stays before the new Lab mic section.
        self.assertLess(UI.index("key: const Key('free-monitor-offline')"),
                        UI.index("key: const Key('lab-mic-recorder')"))

    def test_positive_and_negative_disk_tests_present(self):
        for name in (
            "restart recovery reads two real app-private WAVs",
            "missing checkpoint and incomplete recorder session hold",
            "wrong pointer and forged session ID",
            "altered or truncated source is rejected",
            "manifest forged frames, file, ID and SHA fail closed",
            "immutable receipt cannot be overwritten",
        ):
            self.assertIn(name, TEST)

if __name__ == "__main__":
    unittest.main()
