"""Gate B foreground microphone service and explicit lifecycle safety source contract."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
SERVICE=(ROOT/"native/LabBackgroundRecorderService.kt").read_text()
ACTIVITY=(ROOT/"native/MainActivity.kt").read_text()
BOOT=(ROOT/"tool/bootstrap.sh").read_text()
UI=(ROOT/"lib/main.dart").read_text()

class GateBContract(unittest.TestCase):
    def test_explicit_permission_and_no_auto_start(self):
        self.assertIn('call.method == "labBackgroundStart"',ACTIVITY)
        self.assertIn("!probeForeground",ACTIVITY)
        self.assertIn("Manifest.permission.RECORD_AUDIO",ACTIVITY)
        self.assertIn("Manifest.permission.POST_NOTIFICATIONS",ACTIVITY)
        self.assertIn("LAB_B_ALREADY_RUNNING_HOLD",SERVICE)
        init=UI.split("void initState()",1)[1].split("void dispose()",1)[0]
        self.assertNotIn("labBackgroundStart",init)
    def test_no_onpause_stop_of_service(self):
        p=ACTIVITY.split("override fun onPause()",1)[1].split("override fun onDestroy()",1)[0]
        self.assertNotIn("LabBackgroundRecorderService.requestStop",p)
        self.assertIn("multiMode.compareAndSet(0,1)",p)
        self.assertIn("LabMultiPartCapture.capture(applicationContext",SERVICE)
        self.assertIn("START_NOT_STICKY",SERVICE)
        self.assertIn("mode.compareAndSet(0,1)",SERVICE)
    def test_notification_and_private_service_manifest(self):
        for v in ("FOREGROUND_SERVICE","FOREGROUND_SERVICE_MICROPHONE","POST_NOTIFICATIONS",
                  "android:exported=\\"false\\"","android:foregroundServiceType"):
            self.assertIn(v.replace('\\',''),BOOT)
        for v in ("startForeground(","NotificationChannel(","PendingIntent.getService(",
                  "FOREGROUND_SERVICE_TYPE_MICROPHONE","STOP_FOREGROUND_REMOVE"):
            self.assertIn(v,SERVICE)
    def test_no_unapproved_auto_resume_or_deletion(self):
        self.assertIn("mode.compareAndSet(0,2)",SERVICE)
        self.assertIn("LAB_B_CAPTURE_OR_STORAGE_HOLD",SERVICE)
        self.assertNotIn("START_STICKY",SERVICE)
        self.assertNotIn("Files.delete(",SERVICE)
        self.assertNotIn("HttpClient",SERVICE)
        for label in ("開始 24 秒背景錄音","查詢背景錄音狀態",
                      "停止背景錄音並封存","手動核對背景錄音 Part"):
            self.assertIn(label,UI)
if __name__=="__main__":unittest.main()
