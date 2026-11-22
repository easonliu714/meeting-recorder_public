#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# LAB v0.4.29+34: independent Android package, foreground-only Groq HTTP.
# v0.3's launch package mismatch is a blocking regression contract.
python3 -m unittest discover -s tool -p 'test_native_identity.py' -v
flutter create --no-pub --platforms=android --project-name=groq_stt_lab \
  --org=com.example.meeting_recorder.public_lab_v34 .
python3 - <<'PY'
from pathlib import Path
native = Path("android/app/src/main/kotlin/com/example/meeting_recorder/public_lab_v34/groq_stt_lab")
native.mkdir(parents=True, exist_ok=True)
for name in ("MainActivity.kt", "GroqLabAudioDecoder.kt", "LabMicPartRecorder.kt", "LabMultiPartProof.kt", "LabMultiPartCapture.kt"):
    source = Path("native") / name
    if not source.is_file():
        raise SystemExit("LAB_NATIVE_SOURCE_MISSING_" + name)
    (native / name).write_bytes(source.read_bytes())
PY
# Network is enabled ONLY for a foreground-confirmed Groq Free Chunk.
python3 - <<'PY'
from pathlib import Path
m = Path('android/app/src/main/AndroidManifest.xml')
text = m.read_text(encoding='utf-8')
needle = '<application'
if 'android.permission.INTERNET' not in text:
    if needle not in text:
        raise SystemExit('LAB_MANIFEST_APPLICATION_NOT_FOUND')
    text = text.replace(needle,
        '<uses-permission android:name="android.permission.INTERNET"/>\n    <application', 1)
if 'android.permission.RECORD_AUDIO' not in text:
    text = text.replace(needle,
        '<uses-permission android:name="android.permission.RECORD_AUDIO"/>\n    <application', 1)
m.write_text(text, encoding='utf-8')
PY
python3 tool/verify_android_identity.py android
