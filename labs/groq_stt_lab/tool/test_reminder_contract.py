"""Gate C source-only: verify the isolated Kotlin model is built and tested."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "native/LabTwoHourReminder.kt").read_text()
HOST = (ROOT / "tool/host_tests/LabTwoHourReminderHostTest.kt").read_text()
BOOT = (ROOT / "tool/bootstrap.sh").read_text()
WORKFLOW = (ROOT.parent.parent / ".github/workflows/public-groq-lab-v021-debug-apk.yml").read_text()

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
        self.assertIn("LAB_BUILD_MODE: source_only", WORKFLOW)
    def test_no_provider_or_delete_in_core(self):
        for token in ("HttpClient", "Files.delete", "Groq", "apiKey"):
            self.assertNotIn(token, MODEL)

if __name__ == "__main__":
    unittest.main()
