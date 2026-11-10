# Meeting Recorder — public CI mirror

This repository is a **sanitized CI mirror**, not the canonical development repository.

- The private engineering repository remains the sole source of truth.
- Only an explicitly audited, allowlisted source snapshot may be imported.
- No private Git history, meeting recordings, user transcripts, personal evidence, Android signing material, API credentials, or private runner configuration may be published.
- The mirror's Linux tests **must not** be treated as equivalent to private CI until an audited source manifest is present and all required tests pass at that exact snapshot.
- No release APK, provider-network integration or paid API usage is authorized.

## Current status

**BOOTSTRAP_ONLY**. The initial public workflow checks publication guardrails. It does not verify the application until an approved snapshot is published and the complete Linux validation gate passes.

Do not place sensitive material in issues, pull requests, Actions logs, artifacts, or commits.
