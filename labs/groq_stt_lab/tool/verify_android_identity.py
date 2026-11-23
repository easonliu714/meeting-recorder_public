#!/usr/bin/env python3
"""Fail-closed Android launcher/DEX source identity gate for isolated Public Groq Lab.

The old v0.3 APK compiled but crashed when its manifest requested lab_v3
MainActivity while compiled Kotlin declared package lab_v2.
"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

EXPECTED_PACKAGE = "com.example.meeting_recorder.public_lab_v40.groq_stt_lab"
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


def assert_launcher_identity(android_root: Path, package: str = EXPECTED_PACKAGE) -> None:
    android_root = Path(android_root)
    build = android_root / "app/build.gradle.kts"
    if not build.is_file():
        raise ValueError("LAB_GRADLE_MISSING")
    gradle = build.read_text(encoding="utf-8")
    for property_name in ("applicationId", "namespace"):
        matches = re.findall(
            rf'^\s*{property_name}\s*=\s*"([^"]+)"',
            gradle, flags=re.MULTILINE,
        )
        if matches != [package]:
            raise ValueError(f"LAB_{property_name.upper()}_MISMATCH")

    manifest = android_root / "app/src/main/AndroidManifest.xml"
    if not manifest.is_file():
        raise ValueError("LAB_MANIFEST_MISSING")
    try:
        document = ET.parse(manifest).getroot()
    except ET.ParseError as exc:
        raise ValueError("LAB_MANIFEST_INVALID") from exc
    internet = [p.get(ANDROID_NS + "name") for p in
                document.findall("./uses-permission")]
    if internet.count("android.permission.INTERNET") != 1:
        raise ValueError("LAB_GROQ_INTERNET_PERMISSION_MISSING_OR_DUPLICATED")
    if internet.count("android.permission.RECORD_AUDIO") != 1:
        raise ValueError("LAB_MICROPHONE_PERMISSION_MISSING_OR_DUPLICATED")

    launcher_activities = []
    for activity in document.findall("./application/activity"):
        for intent in activity.findall("./intent-filter"):
            actions = {v.get(ANDROID_NS + "name") for v in intent.findall("action")}
            categories = {v.get(ANDROID_NS + "name") for v in intent.findall("category")}
            if ("android.intent.action.MAIN" in actions
                    and "android.intent.category.LAUNCHER" in categories):
                name = activity.get(ANDROID_NS + "name")
                resolved = package + name if name and name.startswith(".") else name
                launcher_activities.append(resolved)
    if launcher_activities != [package + ".MainActivity"]:
        raise ValueError("LAB_LAUNCHER_MANIFEST_MISMATCH")

    location = android_root / "app/src/main/kotlin" / Path(*package.split("."))
    for class_name in ("MainActivity", "GroqLabAudioDecoder", "LabMicPartRecorder"):
        native = location / (class_name + ".kt")
        if not native.is_file():
            raise ValueError("LAB_NATIVE_FILE_MISSING_" + class_name.upper())
        contents = native.read_text(encoding="utf-8")
        packages = re.findall(r"^\s*package\s+([A-Za-z_][\w.]*)\s*$",
                              contents, flags=re.MULTILINE)
        if packages != [package]:
            raise ValueError("LAB_NATIVE_PACKAGE_MISMATCH_" + class_name.upper())
        if class_name == "MainActivity" and not re.search(
            r"class\s+MainActivity\s*:\s*FlutterActivity\s*\(\s*\)",
            contents,
        ):
            raise ValueError("LAB_LAUNCHER_FLUTTER_ACTIVITY_MISSING")

    print(f"PASS LAB_ANDROID_LAUNCHER_CLASS_PACKAGE={package}")


if __name__ == "__main__":
    try:
        assert_launcher_identity(Path(sys.argv[1]) if len(sys.argv) > 1
                                 else Path("android"))
    except (ValueError, OSError) as exc:
        sys.exit(str(exc))
