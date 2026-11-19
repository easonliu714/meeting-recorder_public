# Groq STT Lab — audited Public Android test branch

This is a **separate Lab-only application**, not the Meeting Recorder public main application, and is **not** a publication of the Private Main project's history. The source/test/tool files in this branch were selected after an explicit Owner scope decision, reviewed for credentials and personal content, and imported as independent text snapshots. This document is not a roadmap: authoritative progress and Owner UAT remain in the Private repository's two canonical governance documents.

## Security and data boundary

- This Lab has an independently generated Android application ID: `com.example.meeting_recorder.public_lab_v21.groq_stt_lab`. Do not uninstall earlier Private Lab or Main App for this test. This build does not migrate Raw, Journal, draft or original recordings.
- The APK is **Debug-only**, not a release and not signed with any Private or long-lived public keystore. It does not offer in-place upgrades for earlier Lab versions.
- The Android picker reads an Owner-selected local file; source remains read-only. Synthetic fixtures and local-loopback tests only are used in CI.
- The UI retains optional Groq/Gemini transports that are gated by explicit end-user consent; **CI never executes live Provider requests** and no secrets are used, persisted or embedded. No paid plan, background upload or automatic retry may be enabled.
- The Public standard-runner workflow is scoped exclusively to this Lab branch and verifies source, tests, Kotlin, Debug APK App ID, signature, provenance and ZIP integrity. The existing Public Main CI/snapshot publication guard remains unchanged.
- No recordings, transcripts, API credentials, private signing files, build histories, user logs, archived binaries or unreviewed Main source are copied into this branch.
- Publishing source does not itself assert the right to redistribute third-party components under a new license; respect original dependency licenses. No new open-source license is granted by this snapshot.

## v0.4.16+21 — bounded MediaCodec PCM evidence

The prior v20 Android Owner test returned `LAB_AUDIO_INCOMPLETE_PCM_WINDOW` for MP3 and AAC/M4A. v21 does **not** bypass the audio completeness Gate. Instead, failing native decoding returns only seven bounded integer counters: expected/decoded frames, first/last PCM timestamps, requested start/end and source duration. These may appear in a **user-triggered, sanitized Debug Log**, never filenames, original audio, transcript, key or codec buffer contents. This evidence should distinguish encoder priming/trim from actual sample loss in the next Android UAT.

### Build locally (Flutter 3.32.8)

```bash
cd labs/groq_stt_lab
python3 -m unittest discover -s tool -p 'test_*.py' -v
bash tool/bootstrap.sh
flutter pub get
flutter analyze
flutter test
(cd android && ./gradlew :app:compileDebugKotlin --no-daemon)
flutter build apk --debug --no-pub --build-name=0.4.16 --build-number=21
```

No API key or provider call is required for local or CI testing.
