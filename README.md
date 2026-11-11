# Meeting Recorder — public CI mirror

This repository is a **sanitized CI mirror**, not the canonical development repository.

- The private engineering repository remains the sole source of truth.
- Only an explicitly audited, allowlisted source snapshot may be imported.
- No private Git history, meeting recordings, user transcripts, personal evidence, Android signing material, API credentials, or private runner configuration may be published.
- The mirror's Linux tests **must not** be treated as equivalent to private CI until an audited source manifest is present and all required tests pass at that exact snapshot.
- No release APK, provider-network integration or paid API usage is authorized.

## Current status

**BOOTSTRAP_ONLY for application CI.** The mirror now independently executes one audited, source-identical **offline synthetic AAC physical 2-hour positive/negative regression** on standard Ubuntu, alongside publication guardrails. This partial project-test PASS does **not** certify the private application, Flutter suite, Android Kotlin, original data or APK readiness. The complete Linux application gate remains blocked until an audited source manifest is published and full coverage is verified.

Do not place sensitive material in issues, pull requests, Actions logs, artifacts, or commits.


## Audited application snapshot handoff (not yet published)

The public runner currently validates only the offline synthetic AAC contract and publication safety tests. A complete Flutter/Android result **must remain HOLD** until an exact-head allowlisted snapshot, including the two Owner-provided original Noto Sans TC TTF files and OFL license, passes the manifest guard.

A repository owner with **local, separate checkouts** can stage a reviewed snapshot without allowing this public repo or its workflows to access Private Repo credentials:


```bash
python3 ci/prepare_public_snapshot.py \
  --private-root /path/to/private/meeting-recorder \
  --public-root /path/to/public/meeting-recorder_public \
  --private-head <exact-40-char-private-PR79-HEAD>
# After dry-run PASS and human review, repeat with --apply.
# The script NEVER pushes, merges, signs or calls any Provider.
```

The exporter reads only immutable Git blobs, checks original Regular/Bold TTF SHA256 and OFL, rejects credentials/personal paths, private CI configuration, symlinks and media, and creates an exact SHA256 manifest. It refuses an already populated public snapshot or a mismatched HEAD. **Do not push** the resulting worktree until its full source/license review and missing binary Android launcher-icon dependency are resolved. The current GitHub connector cannot transport the original binary font blobs cross-repository; this is a real blocker, not a reason to use substitute glyphs or weaken the guard. Normal Git with a reviewed local checkout can transfer the two files.

Do not treat Public bootstrap SUCCESS as equivalent to Private Source/Test/Gradle CI or Android UAT; use original exact-HEAD CI results for those Gates.

## Owner font upload verified (2026-11-10)

The original static **Noto Sans TC Regular/Bold** files (7,109,460 / 7,104,212 bytes) and SIL OFL `OFL.txt` (4,481 bytes) are now present on the font-intake branch, exact-Git-blob equivalent to private PR79. The public guard hard-pins their complete SHA256; partial uploads or substitute fonts fail closed. The `FONT_ASSETS_READY` result is **not** `SOURCE_INTEGRITY_READY` and never enables application Flutter/Kotlin steps by itself. The complete audited private exact-head source manifest remains required.

## Exact Private PR79 sensitive audit (blocking prerequisite)

The offline exporter now scans **every tracked text blob** of the local exact Private Git HEAD, even sources excluded from the later public mirror; it does not rely solely on the manifest's claimed SHA. It forbids tracked signing properties, credential-like strings and personal-contact patterns, and requires the **original Private HEAD** to ignore `android/upload-keystore.properties` and the `.jks` signing key. This is a real pre-existing Private `.gitignore` vulnerability: the workflow generates unquoted `storePassword` and `keyPassword` fields, but the Private head does not ignore its `upload-keystore.properties`. **Do not copy or publish Private Source/Test while this hold remains.** This does not certify license or media rights. The tool does not push or run a Provider; tests use only synthetic Git repositories.


## Independent Public Android APK, new signer (DISARMED)

Owner approved on 2026-11-11: original Private signing JKS backup is unavailable.
Public APKs MUST NOT overwrite Private installs or Private user data. New Public
applicationId: com.example.meeting_recorder.public; historical Private ID:
com.example.meeting_recorder. Public builds use a NEW keypair kept in a securely
backed up JKS. Later Public APK updates must use the SAME new key and App ID
with an increasing versionCode; the two apps have separate storage.

Owner attests assets/app_icon.png was co-designed with ChatGPT, no third-party
stock/asset-library source, and approves publication. Inspect generated Android
launcher PNG assets against this icon before including them in the public export.
OpenAI image output ownership is subject to applicable terms; this attestation
does not grant a general open-source license to the application's source code.

Signing remains disabled: manually dispatch only after full immutable Private
source/rights review and PUBLIC_EXPORT_SOURCE_INTEGRITY_READY; the generated
android/app/build.gradle.kts must contain exactly one Public applicationId,
checked with ci/verify_public_apk_identity.py --check-source. Provision GitHub
Environment android-stable-signing with main-only restrictions and Owner-required
reviewers; create and independently back up a NEW Public JKS in a trusted local
environment. Enter protected Environment secrets ANDROID_KEYSTORE_BASE64,
ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD,
and Environment variable PUBLIC_SIGNER_SHA256 (new DER certificate SHA256).
Both missing fingerprint and any use of the Private legacy certificate are
blocking failures. Only then may Owner enable PUBLIC_APK_SIGNING_ARMED=true.
Do not paste JKS, passwords or base64 into chat, repo or logs.

The workflow checks the new signer before signing, and after build verifies
apksigner cryptographic validity, Public-only applicationId, minSdk21, version,
APK SHA256, exact-head provenance and artifact retention. No signed APK exists
yet. Private Linux Hosted CI is retained until full Public source-parity PASS.
