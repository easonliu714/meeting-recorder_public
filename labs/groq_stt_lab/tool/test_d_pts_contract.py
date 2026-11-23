"""Gate D stage-1: only actual Android AudioRecord timestamps may be labeled hardware PTS."""
from pathlib import Path
import unittest

LAB=Path(__file__).resolve().parents[1]
MODEL=(LAB/"native/LabDPtsEvidence.kt").read_text()
CAPTURE=(LAB/"native/LabMultiPartCapture.kt").read_text()
SERVICE=(LAB/"native/LabBackgroundRecorderService.kt").read_text()
ACTIVITY=(LAB/"native/MainActivity.kt").read_text()
UI=(LAB/"lib/lab_d_pts_panel.dart").read_text()
BOOT=(LAB/"tool/bootstrap.sh").read_text()
WORKFLOW=(LAB.parent.parent/".github/workflows/public-groq-lab-v021-debug-apk.yml").read_text()

class LabDPtsContract(unittest.TestCase):
    def test_actual_hardware_sampling_and_fail_closed_uncertainty(self):
        for s in ("AudioTimestamp()", "getTimestamp(stamp,AudioTimestamp.TIMEBASE_MONOTONIC)",
                  "stamp.framePosition", "stamp.nanoTime",
                  "SystemClock.elapsedRealtimeNanos()", "LabDPtsEvidence.publish(",
                  "recoverD(context:Context)", "latest_d_attempt_v1.txt"):
            self.assertIn(s,CAPTURE)
        for s in ("NOT_VERIFIED", "HARDWARE_PTS_OBSERVED_NOT_GAP_FREE",
                  "LAB_D_PTS_RESET_OR_STALL_HOLD", "LAB_D_PTS_UNALIGNED_HOLD",
                  "StandardOpenOption.CREATE_NEW", "channel.force(", "LAB_D_PTS_READBACK_HOLD"):
            if s=="channel.force(":
                self.assertIn("ch.force(true)",MODEL)
            else:
                self.assertIn(s,MODEL)
        self.assertNotIn("stamp.framePosition=total",CAPTURE)
        self.assertNotIn("AudioTimestamp(",MODEL)

    def test_d_is_explicit_nonsticky_fgs_and_keeps_A_B_C(self):
        for s in ("START_D", "dHardwarePts", "hardwareD=dHardwarePts", "START_NOT_STICKY",
                  "startForeground(3601,notification", "LabTwoHourReminder(0L)"):
            self.assertIn(s,SERVICE)
        for s in ('"labDPtsStart"', '"labDPtsStop"', '"labDPtsStatus"', '"labDPtsRecover"',
                  "if (!probeForeground", "requestPermissions("):
            self.assertIn(s,ACTIVITY)
        self.assertIn('lab_c_reminder_v40',SERVICE)

    def test_readback_pilot_not_long_recording_or_fake_gap_free(self):
        for s in ("開始 24 秒硬體 PTS 預檢", "核對硬體 PTS／已提交 Part",
                  "非", "不自動續錄", "HARDWARE_PTS_OBSERVED_NOT_GAP_FREE",
                  "LAB_D_READBACK_HOLD"):
            if s=="非":
                self.assertIn("這不是",UI)
            else:
                self.assertIn(s,UI)
        for unsafe in ("getTimestamp(", "SourcePath", "Files.delete", "START_STICKY"):
            self.assertNotIn(unsafe,UI)
        self.assertIn('"LabDPtsEvidence.kt"',BOOT)
        self.assertIn("LabDPtsEvidenceHostTest.kt",WORKFLOW)
        self.assertIn("LAB_BUILD_MODE: delivery",WORKFLOW)

if __name__=="__main__":
    unittest.main()
