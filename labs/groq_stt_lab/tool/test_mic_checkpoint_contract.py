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

class LabMicInterruptedContract(unittest.TestCase):
    def test_native_commit_precedes_uncommitted_tail_and_can_stop(self):
        native = (LAB / "native/LabMicPartRecorder.kt").read_text(encoding="utf-8")
        probe = native.split("fun captureInterruptProbe", 1)[1]
        for phrase in (
            "output.fd.sync()", "sha256(first)", "part_01_commit.tmp",
            "part_01_commit_v1.json", "part_02_inflight.pcm",
            "finished_v1.txt", "cancelled()", "recorder.release()",
        ):
            self.assertIn(phrase, probe)
        self.assertLess(probe.index("part_01_commit_v1.json"),
                        probe.index("part_02_inflight.pcm"))
        self.assertLess(probe.index("part_02_inflight.pcm"),
                        probe.index("finished_v1.txt"))
        activity = (LAB / "native/MainActivity.kt").read_text(encoding="utf-8")
        self.assertIn('call.method == "stopLabMicInterruptProbe"', activity)
        self.assertIn('if (probeRunning.get()) probeStop.set(true)', activity)
        self.assertIn('if (!probeForeground)', activity)
        self.assertIn('probeRunning.compareAndSet(false, true)', activity)

    def test_recovery_is_read_only_and_does_not_promote_tail(self):
        reader = (LAB / "lib/lab_mic_interrupt_probe.dart").read_text(encoding="utf-8")
        recovery = reader.split("Future<LabMicInterruptedReceipt> recover", 1)[1]
        for term in ("followLinks: false", "LabAudioPipeline.digest(source)",
                     "LabPartRoster.verify([receipt])", "LAB_MIC_INTERRUPT_UNCOMMITTED_HOLD",
                     "LAB_MIC_INTERRUPT_NOT_INCOMPLETE_HOLD"):
            self.assertIn(term, reader)
        for term in ("invokeMethod", "writeAs", ".delete(", "AudioRecord", "HttpClient"):
            self.assertNotIn(term, recovery)
        self.assertEqual(recovery.count("LabPartRoster.append("), 1)
        self.assertIn("source: source", recovery)
        self.assertIn("LAB_MIC_INTERRUPT_PREFIX_OK", UI)
        self.assertIn("tail_bytes_uncommitted", UI)
        self.assertIn("fresh install missing capture parent", TEST)

if __name__ == "__main__":
    unittest.main()
