# Groq STT Lab — audited Public Android test branch

This is a **separate Lab-only application**, not the Meeting Recorder public main application, and is **not** a publication of the Private Main project's history. The source/test/tool files in this branch were selected after an explicit Owner scope decision, reviewed for credentials and personal content, and imported as independent text snapshots. This document is not a roadmap: authoritative progress and Owner UAT remain in the Private repository's two canonical governance documents.

## Security and data boundary

- This Lab has an independently generated Android application ID: `com.example.meeting_recorder.public_lab_v26.groq_stt_lab`. Do not uninstall earlier Private Lab or Main App for this test. This build does not migrate Raw, Journal, draft or original recordings.
- The APK is **Debug-only**, not a release and not signed with any Private or long-lived public keystore. It does not offer in-place upgrades for earlier Lab versions.
- The Android picker reads an Owner-selected local file; source remains read-only. Synthetic fixtures and local-loopback tests only are used in CI.
- The UI retains optional Groq/Gemini transports that are gated by explicit end-user consent; **CI never executes live Provider requests** and no secrets are used, persisted or embedded. No paid plan, background upload or automatic retry may be enabled.
- The Public standard-runner workflow is scoped exclusively to this Lab branch and verifies source, tests, Kotlin, Debug APK App ID, signature, provenance and ZIP integrity. The existing Public Main CI/snapshot publication guard remains unchanged.
- No recordings, transcripts, API credentials, private signing files, build histories, user logs, archived binaries or unreviewed Main source are copied into this branch.
- Publishing source does not itself assert the right to redistribute third-party components under a new license; respect original dependency licenses. No new open-source license is granted by this snapshot.

## v0.4.21+26 — source-rate bounded AAC-LC priming and fail-closed diagnostics

The Owner v25 60-minute 16kHz M4A reproduces LAB_AUDIO_LEADING_PTS_HOLD
before a physical Chunk, while 60-minute WAV and 12-minute MP3 staging
and cancellation remain scoped Owner PASS. AAC-LC has a 1024-sample
frame (64ms at 16kHz), which can exceed the prior fixed 50ms
first-wire leading-PTS limit. Only one physical AAC source-rate
frame plus 2ms rounding (absolute 130ms cap) can be rebased.
The source MIME and rate are independently bound through the native
probe and Dart physical output contract. Later windows, MP3's 50ms
limit, complete Core/Wire timestamps, actual output frame count,
SHA256, no silence insertion, source read-only and rollback remain.
Early PTS failures report numeric PTS/rate/window evidence without
paths, raw audio, transcript or credentials. Added bounded positive
and negative codec/frame/source-rate tests plus cancellation regression.
Physical Android AAC fix remains NOT_VERIFIED until Owner tests v26.

## v0.4.20+25 — LAB-1 user-cancellable 1–2h staging and failure-safe WAV cleanup
The isolated Public Lab adds a cancel button while WAV/MP3/M4A staging.
WAV cancellation is checked between every 32 KiB read/write; its
splitter deletes only the new temporary directory if interrupted.
Compressed cancellation takes effect between completed native PCM
windows, not inside an active MediaCodec decode call; already verified
temporary outputs from this invocation are rolled back fail-closed.
If WAV output finished but final source SHA/cancellation verification
fails, only verified freshly produced app-owned WAV files are removed,
never source audio, Provider Raw, Notes or saved user preferences.
No Groq requests, silent PCM padding or relaxed PTS/PCM/SHA checks.
New positive/negative tests cover WAV copy interruption, physical
two-window cancel-before-next-window, and cross-root cleanup protection.
A real 1–2h Android test is NOT_VERIFIED until Owner executes it.

## v0.4.19+24 — LAB-1 MP3 second-window bounded local replay
Owner v23 Android 12m MP3 T05 failed closed: final decoded PTS
719363466us versus required 720039000us, 10808 PCM frames short.
Source SHA and FFprobe full MP3 packet timeline remain independently valid.
The MP3-only bounded noninitial-window recovery attempts one local
MediaExtractor/MediaCodec replay from time zero if physical tail was
short by 321..32000 frames and was otherwise within 2s of required end.
Original no-loss, true PCM, PTS, SHA256, 22.5MB and temporary cleanup
gates remain unchanged. AAC/M4A v23 T06 OWNER_PASS stays frozen.
A successful local replay is logged as STAGE_MP3_ORIGIN_REPLAY_OK;
a failed attempt reports bounded input/output EOS numeric evidence and
stays HOLD. No Groq provider submission or fabricated silence.
Owner Android retest T05 remains NOT_VERIFIED until real-device UAT.

## v0.4.18+23 — LAB-1 compressed physical multi-window checkpoint
This update checks each physical MP3/M4A PCM16 output for continuous
core time and 2-second wire overlap, then fails closed on gaps or
incomplete output. If a later decode fails, verified temporary PCM
from earlier windows in the same stage is removed, without touching
source, Raw, Notes or preferences. A real >10-minute Owner Android
test is still required before multi-window Owner PASS.
The earlier v22 short-file results are preserved unchanged.

## v0.4.17+22 — bounded MP3/AAC leading-PTS recovery

Owner v21 real-device Log recorded MP3 40249us and AAC/M4A 23219us
first decoded timestamps. The former absolute-zero target got stuck
at zero rendered PCM frames. Only first-window codec priming up to
50ms can now rebase sample PTS; actual decoded PCM samples alone are
written, with no fabricated silence. A raw timestamp origin and
last-PTS receipt are independently validated in the Dart stage.
Later-window timestamp drift, source SHA mutation, interior audio gaps,
corrupt source and incomplete physical PCM still fail closed.
Encoder priming correction does not prove full acoustic fidelity or
Groq real Provider E2E. Owner Android verification remains required.

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
flutter build apk --debug --no-pub --build-name=0.4.21 --build-number=26
```

No API key or provider call is required for local or CI testing.
