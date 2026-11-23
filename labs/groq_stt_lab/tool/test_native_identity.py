#!/usr/bin/env python3
"""Negative startup-identity regression for the v0.3 MainActivity crash."""
import tempfile
import unittest
from pathlib import Path

from verify_android_identity import EXPECTED_PACKAGE, assert_launcher_identity


def fixture(root: Path) -> Path:
    android = root / "android"
    gradle = android / "app/build.gradle.kts"
    gradle.parent.mkdir(parents=True)
    gradle.write_text(
        'android {\n'
        f' namespace = "{EXPECTED_PACKAGE}"\n'
        f' defaultConfig {{\n applicationId = "{EXPECTED_PACKAGE}"\n }}\n'
        '}\n', encoding="utf-8")
    manifest = android / "app/src/main/AndroidManifest.xml"
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text("""<manifest xmlns:android="http://schemas.android.com/apk/res/android">
       <uses-permission android:name="android.permission.INTERNET"/>
       <uses-permission android:name="android.permission.RECORD_AUDIO"/>
       <application><activity android:name=".MainActivity">
         <intent-filter>
           <action android:name="android.intent.action.MAIN"/>
           <category android:name="android.intent.category.LAUNCHER"/>
         </intent-filter>
       </activity></application></manifest>""", encoding="utf-8")
    native = android / "app/src/main/kotlin" / Path(*EXPECTED_PACKAGE.split("."))
    native.mkdir(parents=True)
    (native / "MainActivity.kt").write_text(
        f"package {EXPECTED_PACKAGE}\nclass MainActivity : FlutterActivity() {{}}\n",
        encoding="utf-8")
    (native / "GroqLabAudioDecoder.kt").write_text(
        f"package {EXPECTED_PACKAGE}\ninternal object GroqLabAudioDecoder {{}}\n",
        encoding="utf-8")
    (native / "LabMicPartRecorder.kt").write_text(
        f"package {EXPECTED_PACKAGE}\ninternal object LabMicPartRecorder {{}}\n",
        encoding="utf-8")
    return android


class LauncherIdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.android = fixture(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def test_valid_android_launcher_with_matching_kotlin_passes(self):
        assert_launcher_identity(self.android)

    def test_regression_v3_manifest_with_old_v2_kotlin_fails_closed(self):
        f = self.android / "app/src/main/kotlin" / Path(*EXPECTED_PACKAGE.split(".")) / "MainActivity.kt"
        f.write_text("package com.example.meeting_recorder.lab_v2.groq_stt_lab\n"
                     "class MainActivity : FlutterActivity() {}\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "LAB_NATIVE_PACKAGE_MISMATCH_MAINACTIVITY"):
            assert_launcher_identity(self.android)

    # A Private v20 package must never launch the independent Public v22 Lab.
    def test_private_v20_native_package_rejected_for_public_v22(self):
        self.assertEqual(
            EXPECTED_PACKAGE, "com.example.meeting_recorder.public_lab_v37.groq_stt_lab"
        )
        native = (self.android / "app/src/main/kotlin"
                  / Path(*EXPECTED_PACKAGE.split(".")) / "MainActivity.kt")
        native.write_text(
            "package com.example.meeting_recorder.lab_v20.groq_stt_lab\n"
            "class MainActivity : FlutterActivity() {}\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            ValueError, "LAB_NATIVE_PACKAGE_MISMATCH_MAINACTIVITY"
        ):
            assert_launcher_identity(self.android)

    def test_wrong_android_manifest_launch_activity_fails_closed(self):
        manifest = self.android / "app/src/main/AndroidManifest.xml"
        manifest.write_text(manifest.read_text().replace(
            'android:name=".MainActivity"', 'android:name=".SomeOtherActivity"'),
            encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "LAB_LAUNCHER_MANIFEST_MISMATCH"):
            assert_launcher_identity(self.android)

    def test_different_application_id_fails_closed(self):
        gradle = self.android / "app/build.gradle.kts"
        gradle.write_text(gradle.read_text().replace(
            f'applicationId = "{EXPECTED_PACKAGE}"',
            'applicationId = "com.example.meeting_recorder.lab_v3.groq_stt_lab"'),
            encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "LAB_APPLICATIONID_MISMATCH"):
            assert_launcher_identity(self.android)

    def test_missing_internet_permission_fails_closed(self):
        manifest = self.android / "app/src/main/AndroidManifest.xml"
        manifest.write_text(
            manifest.read_text().replace(
                '<uses-permission android:name="android.permission.INTERNET"/>', ''),
            encoding="utf-8")
        with self.assertRaisesRegex(
                ValueError, "LAB_GROQ_INTERNET_PERMISSION_MISSING_OR_DUPLICATED"):
            assert_launcher_identity(self.android)

    def test_mic_permission_missing_fails_closed(self):
        manifest = self.android / "app/src/main/AndroidManifest.xml"
        manifest.write_text(manifest.read_text().replace(
            '<uses-permission android:name="android.permission.RECORD_AUDIO"/>',
            ''), encoding="utf-8")
        with self.assertRaisesRegex(ValueError,
            "LAB_MICROPHONE_PERMISSION_MISSING_OR_DUPLICATED"):
            assert_launcher_identity(self.android)

    def test_missing_native_mic_capture_fails_closed(self):
        native = (self.android / "app/src/main/kotlin"
                  / Path(*EXPECTED_PACKAGE.split(".")))
        (native / "LabMicPartRecorder.kt").unlink()
        with self.assertRaisesRegex(ValueError, "LAB_NATIVE_FILE_MISSING_LABMICPARTRECORDER"):
            assert_launcher_identity(self.android)

    def test_missing_native_activity_fails_closed(self):
        native = self.android / "app/src/main/kotlin" / Path(*EXPECTED_PACKAGE.split("."))
        (native / "MainActivity.kt").unlink()
        with self.assertRaisesRegex(ValueError, "LAB_NATIVE_FILE_MISSING_MAINACTIVITY"):
            assert_launcher_identity(self.android)


if __name__ == "__main__":
    unittest.main()
