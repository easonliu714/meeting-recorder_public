"""Gate A bounded recorder/worker wiring, fail-closed and explicit local recovery."""
from pathlib import Path
import unittest

LAB = Path(__file__).resolve().parents[1]
NATIVE = (LAB / "native/LabMultiPartCapture.kt").read_text(encoding="utf-8")
UI = (LAB / "lib/main.dart").read_text(encoding="utf-8")
PROOF = (LAB / "native/LabMultiPartProof.kt").read_text(encoding="utf-8")

class GateAMultiPartContract(unittest.TestCase):
    def test_capture_worker_is_bounded_and_never_blocks_read_on_disk(self):
        for phrase in ("ArrayBlockingQueue<ByteArray>(16)", "queue.offer(buffer.copyOf(n))",
                       "AudioRecord.READ_NON_BLOCKING", "LAB_MULTI_QUEUE_HOLD",
                       "StandardCopyOption.ATOMIC_MOVE", "LAB_MULTI_STORAGE_HOLD",
                       "sink.finish(normal.get())", "recorder.release()"):
            self.assertIn(phrase, NATIVE)
        self.assertEqual(NATIVE.count("val recorder=AudioRecord("), 1)
        self.assertNotIn("queue.put(", NATIVE)
        self.assertNotIn("HttpClient", NATIVE)

    def test_manual_recovery_does_not_start_capture(self):
        recovery = NATIVE.split("fun recover(", 1)[1].split("fun capture(", 1)[0]
        self.assertNotIn("AudioRecord(", recovery)
        self.assertNotIn("write(", recovery)
        init = UI.split("void initState()", 1)[1].split("void dispose()", 1)[0]
        self.assertNotIn("labMultiStart", init)
        self.assertNotIn("_runMultiPart(", init)
        for key in ("lab-multi-start", "lab-multi-interrupt", "lab-multi-finish", "lab-multi-recover"):
            self.assertIn("Key('" + key + "')", UI)

    def test_symbolic_failure_codes_without_private_path_leak(self):
        for name in ("LAB_MULTI_RAW_FSYNC_HOLD", "LAB_MULTI_WAV_FSYNC_HOLD",
                     "LAB_MULTI_HARDLINK_IO_HOLD", "LAB_MULTI_HARDLINK_UNSUPPORTED_HOLD",
                     "LAB_MULTI_RECEIPT_FSYNC_HOLD", "LAB_MULTI_RECEIPT_READBACK_HOLD"):
            self.assertIn(name, PROOF)
        self.assertIn("hardLink(dest, tmp)", PROOF)
        self.assertNotIn("StandardCopyOption.REPLACE_EXISTING", PROOF)
        activity = (LAB / "native/MainActivity.kt").read_text(encoding="utf-8")
        self.assertNotIn("result.error(error.message", activity)
        self.assertIn('Regex("^[A-Z][A-Z0-9_]{1,63}$")', activity)

    def test_worker_retains_uncommitted_raw_and_never_seals_on_interrupt(self):
        sink = PROOF.split("internal class LabMultiPartSink",1)[1]
        self.assertIn('_inflight.pcm', sink)
        self.assertIn("if(normal && written>0) seal()", sink)
        self.assertIn("proof.commit(index)", sink)
        self.assertIn("proof.finish(index-1)", sink)
        self.assertNotIn(".delete(", sink)

if __name__ == "__main__":
    unittest.main()
