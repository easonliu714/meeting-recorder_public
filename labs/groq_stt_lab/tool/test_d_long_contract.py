"""Gate D real 60/120 minute bounded physical recording contracts, with negative safety gates."""
import unittest
from pathlib import Path
LAB=Path(__file__).resolve().parents[1]
CAPTURE=(LAB/"native/LabDLongCapture.kt").read_text(encoding="utf8")
CLOCK=(LAB/"native/LabDLongClock.kt").read_text(encoding="utf8")
PTS=(LAB/"native/LabDLongPts.kt").read_text(encoding="utf8")
SERVICE=(LAB/"native/LabBackgroundRecorderService.kt").read_text(encoding="utf8")
ACTIVITY=(LAB/"native/MainActivity.kt").read_text(encoding="utf8")
UI=(LAB/"lib/lab_d_long_panel.dart").read_text(encoding="utf8")
BOOT=(LAB/"tool/bootstrap.sh").read_text(encoding="utf8")
WORKFLOW=(LAB.parent.parent/".github/workflows/public-groq-lab-v021-debug-apk.yml").read_text(encoding="utf8")
class DLongContracts(unittest.TestCase):
    def test_true_60_120_150_not_simulated(self):
        for token in ("HOUR_MS=60L*60L*1000L","REMINDER_MS=120L*60L*1000L",
                      "CAP_MS=150L*60L*1000L","HOUR_CHECKPOINT",
                      "FOREGROUND_REMINDER","BACKGROUND_NOTIFICATION",
                      "continueRecording()","endRecording()",
                      "LAB_D_LONG_CLOCK_REGRESSION_HOLD"):
            self.assertIn(token,CLOCK)
        self.assertNotIn("C_SPEED",CLOCK)
        self.assertIn("val event=longModel.tick(SystemClock.elapsedRealtime()",SERVICE)
        self.assertIn("真實錄音：已達 120 分鐘",SERVICE)
        self.assertIn('LONG_CHANNEL="lab_d_long_reminder_v40"',SERVICE)
        self.assertIn("IMPORTANCE_HIGH",SERVICE)
        self.assertIn("START_NOT_STICKY",SERVICE)
    def test_actual_pcm_and_gap_unknown_not_sample_clock(self):
        for token in ("PART_BYTES=115200000","PART_LIMIT=3","MAX_BYTES=288000000",
                      "MIN_FREE=1250000000L","REMAINING_SAFE",
                      "ArrayBlockingQueue<ByteArray>(2048)",
                      "recorder.getTimestamp(timestamp,AudioTimestamp.TIMEBASE_MONOTONIC)",
                      "timestamp.framePosition","timestamp.nanoTime",
                      "SystemClock.elapsedRealtimeNanos()",
                      "LabMultiPartSink(dir,id,PART_BYTES,PART_LIMIT",
                      "latest_long_attempt_v1.txt",
                      "LabDLongPts.publish","LabDLongPts.read",
                      "sourceIdentity\" to \"NOT_VERIFIED",
                      "StandardCopyOption.ATOMIC_MOVE"):
            self.assertIn(token,CAPTURE)
        self.assertNotIn("C_SPEED",CAPTURE)
        self.assertNotIn("File.delete",CAPTURE)
        self.assertNotIn("silence",CAPTURE)
        for token in ("HARDWARE_PTS_OBSERVED_NOT_GAP_FREE",
                      "LAB_D_LONG_PTS_RESET_OR_STALL_HOLD",
                      "LAB_D_LONG_PTS_UNALIGNED_HOLD",
                      "StandardOpenOption.CREATE_NEW","ch.force(true)",
                      "NOT_VERIFIED"):
            self.assertIn(token,PTS)
    def test_signed_crosswalk_and_current_app_open_version(self):
        for token in ("fun crosswalk", "hardwareMinusPcm",
                      "hardwareClockMinusFramesNs", "POSSIBLE_GAP",
                      "POSSIBLE_OVERLAP", "RESET_OR_STALL",
                      "WITHIN_DIAGNOSTIC_BOUND_NOT_GAP_FREE",
                      "crosses60", "crosses120", "observedElapsedNs"):
            self.assertIn(token, PTS)
        self.assertIn("LabDLongPts.crosswalk(pts)", CAPTURE)
        self.assertIn("ptsIntervals", UI)
        self.assertIn("LAB_D_LONG_PTS_CROSSWALK_HOLD", UI)
        main=(LAB/"lib/main.dart").read_text(encoding="utf8")
        self.assertIn("${LabBuildInfo.versionName}+${LabBuildInfo.versionCode}", main)
        self.assertNotIn("'version': '0.4.34+39'", main)
    def test_user_tap_permissions_and_verdict_truth(self):
        for token in ('"labDLongStart"','"labDLongStop"','"labDLongStatus"',
                      '"labDLongRecover"','"labDLongContinue"','"labDLongEnd"',
                      "probeForeground","RECORD_AUDIO",
                      "POST_NOTIFICATIONS", "LabDLongCapture.recover("):
            self.assertIn(token,ACTIVITY)
        for token in ("開始真實最長 150 分鐘錄音",
                      "查詢真實錄音與 60 分鐘檢查點",
                      "繼續錄音","結束並封存",
                      "核對真實錄音 Part／硬體 PTS／SHA",
                      "不補零","NOT_VERIFIED",
                      "1.25 GB","RegExp", "不等於"):
            if token=="不等於":
                self.assertIn("不證明聲學",UI)
            else:self.assertIn(token,UI)
        self.assertIn('LabDLongCapture.kt',BOOT)
        self.assertIn("LabDLongClockHostTest.kt",WORKFLOW)
        self.assertIn("LabDLongPtsHostTest.kt",WORKFLOW)
        self.assertIn("GATE_D_REAL_60_120_MINUTE_SOURCE=IMPLEMENTED_NOT_OWNER_TESTED",WORKFLOW)
if __name__=="__main__":unittest.main()
