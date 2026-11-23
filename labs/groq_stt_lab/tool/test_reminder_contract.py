"""Gate C source-only: verify the isolated Kotlin model is built and tested."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "native/LabTwoHourReminder.kt").read_text()
HOST = (ROOT / "tool/host_tests/LabTwoHourReminderHostTest.kt").read_text()
BOOT = (ROOT / "tool/bootstrap.sh").read_text()
WORKFLOW = (ROOT.parent.parent / ".github/workflows/public-groq-lab-v021-debug-apk.yml").read_text()
SERVICE = (ROOT / "native/LabBackgroundRecorderService.kt").read_text()
ACTIVITY = (ROOT / "native/MainActivity.kt").read_text()
UI = (ROOT / "lib/main.dart").read_text()

class GateCModelContract(unittest.TestCase):
    def test_meeting_anchor_and_no_part_clock(self):
        self.assertIn("private val startedElapsedMs: Long", MODEL)
        self.assertIn("THRESHOLD_MS = 120L * 60L * 1000L", MODEL)
        self.assertNotIn("PART_COUNT", MODEL)
        self.assertNotIn("PART_BYTES", MODEL)
    def test_fail_closed_choices_and_pending(self):
        for token in ("LAB_C_MONOTONIC_CLOCK_HOLD", "LAB_C_UNVERIFIED_SEAL_HOLD",
                      "pendingOnReturn()", "continueRecording()", "requestEnd()",
                      "BACKGROUND_NOTIFICATION", "FOREGROUND_CONFIRM"):
            self.assertIn(token, MODEL)
    def test_real_jvm_regression_is_required_by_ci(self):
        self.assertIn("LAB_C_CLOCK_HOST_SUITE_PASS cases=", HOST)
        self.assertIn("LabTwoHourReminderHostTest.kt", WORKFLOW)
        self.assertIn("LabTwoHourReminder.kt", BOOT)
        self.assertIn("LabTwoHourReminder.kt", BOOT)
    def test_c_reminder_is_service_scoped_and_explicit(self):
        for token in ("LabTwoHourReminder(0L)", "SystemClock.elapsedRealtime()",
                      "cContinue()", "cEnd()", "LAB_C_UNVERIFIED_SEAL_HOLD",
                      "cPending", "cElapsedSimMs", "showReminderNotification()",
                      "startForeground(", "STOP_FOREGROUND_REMOVE"):
            self.assertIn(token, SERVICE)
        self.assertIn("C_SPEED=900L", SERVICE)
        self.assertIn("if(acceleratedC) START_C else START", SERVICE)
        self.assertNotIn("onTick(", SERVICE.split("fun begin(", 1)[1].split("override fun onBind", 1)[0])
    def test_android_channel_and_lifecycle(self):
        for token in ('call.method == "labReminderStart"', 'call.method == "labReminderContinue"',
                      'call.method == "labReminderEnd"', 'call.method == "labReminderStatus"',
                      "LabBackgroundRecorderService.setUiForeground(false)",
                      "LabBackgroundRecorderService.setUiForeground(true)"):
            self.assertIn(token, ACTIVITY)
        old = ACTIVITY.split("override fun onPause()", 1)[1].split("override fun onDestroy()", 1)[0]
        self.assertNotIn("LabBackgroundRecorderService.requestStop", old)
    def test_visible_simulation_confirm_and_safe_readback(self):
        for token in ("LAB-REC-C｜兩小時提醒（加速模擬）", "開始 24 秒兩小時提醒加速模擬",
                      "繼續錄音", "結束並封存", "核對提醒測試已提交 Part",
                      "_showCPrompt()", "didChangeAppLifecycleState", "加速測試，非真正兩小時錄音"):
            self.assertIn(token, UI)
        self.assertNotIn("labReminderStart", UI.split("void initState()",1)[1].split("void dispose()",1)[0])
    def test_no_unsafe_side_effects_in_gate_c(self):
        for token in ("HttpClient", "Files.delete(", "START_STICKY", "apiKey"):
            self.assertNotIn(token, SERVICE)

    def test_no_provider_or_delete_in_core(self):
        for token in ("HttpClient", "Files.delete", "Groq", "apiKey"):
            self.assertNotIn(token, MODEL)

if __name__ == "__main__":
    unittest.main()
