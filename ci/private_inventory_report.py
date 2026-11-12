#!/usr/bin/env python3
"""Confidential, immutable-blob SHA256 inventory for a local Private checkout.

This is a classification aid, not source publication approval. Never commit the
result, print private file contents, access provider APIs, or change user data.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re

from audit_private_git_head import (
    FORBIDDEN_TRACKED_NAMES, FORBIDDEN_TRACKED_SUFFIXES, HEX40,
    KNOWN_PRIVATE_BINARY, PublicationHold, inspect_text, private_git,
)
from verify_public_snapshot import (
    OWNER_APPROVED_ICON_GIT_BLOBS, ORIGINAL_FONT_ASSETS,
    PRIVATE_ONLY_TESTS, PUBLIC_GRADLE_PATH, _allowed_source,
)
from prepare_public_snapshot import require_trusted_repo_origin



# Owner batch rights cover self-owned Source/Test, never real secrets or third-party
# exceptions. No PASS_SANITIZED without verified transformed bytes and tests.
CANDIDATE_STATES = (
    "NOT_SCANNED", "PASS_AS_IS", "NEEDS_SANITIZATION",
    "PASS_SANITIZED", "HOLD_REVIEW",
)
DATAFLOW_REVIEW = re.compile(
    rb"SharedPreferences|shared_preferences|app_logs|image\.path|"
    rb"Authorization|api[_-]?key|apiKey|access[_-]?token|"
    rb"ProviderRaw|recordingPath|File\(|content://|file://",
    re.I,
)


def classify_candidate_audit(path: str, blob: str, data: bytes,
                             decision: str, reason: str,
                             digest: str) -> tuple[str | None, str]:
    """Fail closed on unresolved rights/dataflow; never alter Private bytes."""
    if not _allowed_source(path):
        return None, "EXCLUDED_FROM_PUBLIC_APP_SCOPE"
    # Never downgrade a real secret/PII finding to a routine App-ID rewrite.
    # The Private original is immutable; sanitization must be separately reviewed.
    if decision == "DENY":
        return "HOLD_REVIEW", reason
    if path == PUBLIC_GRADLE_PATH:
        return "NEEDS_SANITIZATION", "PUBLIC_APP_ID_TRANSFORM_AND_PARITY_REQUIRED"
    if path in OWNER_APPROVED_ICON_GIT_BLOBS:
        if (blob == OWNER_APPROVED_ICON_GIT_BLOBS[path] and
                data.startswith(b"\x89PNG\r\n\x1a\n")):
            return "PASS_AS_IS", "PINNED_OWNER_ICON_AND_REPRODUCTION_GATE"
        return "HOLD_REVIEW", "ICON_CONTENT_OR_PIN_MISMATCH"
    if path in ORIGINAL_FONT_ASSETS:
        size, expected = ORIGINAL_FONT_ASSETS[path]
        if len(data) == size and digest == expected:
            return "PASS_AS_IS", "PINNED_OFL_FONT_ASSET"
        return "HOLD_REVIEW", "THIRD_PARTY_FONT_OR_LICENSE_MISMATCH"
    if decision != "HOLD":
        return "HOLD_REVIEW", "UNEXPECTED_INVENTORY_DECISION"
    if path in {"pubspec.yaml", "pubspec.lock"}:
        return "HOLD_REVIEW", "THIRD_PARTY_SDK_LICENSE_REVIEW"
    if path == "lib/main.dart" or path.startswith("tool/patch_"):
        return "HOLD_REVIEW", "GENERATED_SOURCE_PRIVACY_AND_PARITY_REVIEW"
    if path.endswith((".png", ".ttf")) or b"\0" in data:
        return "HOLD_REVIEW", "BINARY_CONTENT_REVIEW"
    if DATAFLOW_REVIEW.search(data):
        return "HOLD_REVIEW", "RUNTIME_DATAFLOW_REVIEW"
    return "PASS_AS_IS", "BATCH_OWNER_RIGHTS_AND_STATIC_SCAN_PASS"


def summarize_candidate_audit(rows: list[dict]) -> dict:
    """Conservation across exactly the candidate rows; no guessed approvals."""
    candidates = [row for row in rows if row["candidate"]]
    counts = {state: sum(row["audit_status"] == state for row in candidates)
              for state in CANDIDATE_STATES}
    if sum(counts.values()) != len(candidates):
        raise PublicationHold("CANDIDATE_AUDIT_CONSERVATION_HOLD")
    return {
        "tracked": len(rows),
        "candidate": len(candidates),
        "excluded": len(rows) - len(candidates),
        "states": counts,
        "copyable": counts["PASS_AS_IS"] + counts["PASS_SANITIZED"],
        # Inventory alone is NOT a GitHub Public commit/readback.
        "actually_copied": 0,
    }



def _inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def inventory_private_head(private: Path, head: str) -> dict:
    """Read and classify *every* exact-HEAD tracked blob, including exclusions."""
    private = private.resolve(strict=True)
    if not HEX40.fullmatch(head):
        raise PublicationHold("INVENTORY_INVALID_HEAD_HOLD")
    top = Path(private_git(private, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if top != private or private_git(private, "rev-parse", "HEAD").decode().strip() != head:
        raise PublicationHold("INVENTORY_CHECKOUT_HEAD_HOLD")
    origin = private_git(private, "remote", "get-url", "origin").decode().strip()
    # Share the exporter's exact GitHub owner/host allowlist. A regex suffix
    # would accept lookalike domains such as notgithub.com.
    require_trusted_repo_origin(origin, "meeting-recorder")
    rows, seen = [], set()
    for raw in private_git(private, "ls-tree", "-r", "-z", head).split(b"\0"):
        if not raw:
            continue
        try:
            descriptor, encoded = raw.split(b"\t", 1)
            mode, kind, blob = descriptor.decode("ascii").split()
            path = encoded.decode("utf-8")
        except (UnicodeError, ValueError) as exc:
            raise PublicationHold("INVENTORY_TREE_PARSE_HOLD") from exc
        if (not path or path in seen or path.startswith("/") or "\\" in path or
                ".." in PurePosixPath(path).parts or
                PurePosixPath(path).as_posix() != path or not HEX40.fullmatch(blob)):
            raise PublicationHold("INVENTORY_PATH_HOLD")
        seen.add(path)
        data = private_git(private, "cat-file", "blob", blob)
        actual_blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if actual_blob != blob:
            raise PublicationHold("INVENTORY_GIT_BLOB_INTEGRITY_HOLD")
        digest = hashlib.sha256(data).hexdigest()
        suffix = Path(path).suffix.lower()
        if mode not in ("100644", "100755") or kind != "blob":
            decision, reason = "DENY", "UNSAFE_GIT_MODE_OR_SYMLINK"
        elif Path(path).name in FORBIDDEN_TRACKED_NAMES or suffix in FORBIDDEN_TRACKED_SUFFIXES:
            decision, reason = "DENY", "PRIVATE_CREDENTIAL_OR_USER_MEDIA_FILE"
        elif path in PRIVATE_ONLY_TESTS or not _allowed_source(path):
            decision, reason = "DENY", "PRIVATE_ONLY_OR_OUT_OF_PUBLIC_SCOPE"
        elif path in OWNER_APPROVED_ICON_GIT_BLOBS:
            if blob == OWNER_APPROVED_ICON_GIT_BLOBS[path]:
                decision, reason = "ALLOW", "EXACT_OWNER_APPROVED_ICON_ONLY"
            else:
                decision, reason = "HOLD", "OWNER_ICON_BLOB_CHANGED"
        elif suffix in KNOWN_PRIVATE_BINARY or b"\0" in data or len(data) > 2_000_000:
            decision, reason = "HOLD", "BINARY_PROVENANCE_AND_RIGHTS_REVIEW"
        else:
            try:
                inspect_text(path, data)
            except PublicationHold:
                decision, reason = "DENY", "TEXT_SECRET_OR_PII_PATTERN_REVIEW"
            else:
                decision, reason = "HOLD", "SOURCE_RIGHTS_PRIVACY_DATAFLOW_REVIEW"
        audit_status, audit_reason = classify_candidate_audit(
            path, blob, data, decision, reason, digest)
        rows.append({"path": path, "git_blob_sha1": blob, "sha256": digest,
                     "source_sha256": digest, "safe_copy_sha256": None,
                     "candidate": audit_status is not None,
                     "audit_status": audit_status, "audit_reason": audit_reason,
                     "decision": decision, "reason": reason})
    if not rows:
        raise PublicationHold("INVENTORY_EMPTY_TREE_HOLD")
    rows.sort(key=lambda row: row["path"])
    counts = {state: sum(row["decision"] == state for row in rows)
              for state in ("ALLOW", "DENY", "HOLD")}
    return {"schema": 2, "private_source_head": head,
            "classification": "CONFIDENTIAL_LOCAL_REVIEW_ONLY_NOT_PUBLICATION_APPROVAL",
            "counts": counts, "candidate_audit": summarize_candidate_audit(rows),
            "files": rows}


def save_confidential_report(report: dict, destination: Path,
                             private: Path, public: Path) -> None:
    """Create a new owner-local 0600 report, never under either Git checkout."""
    parent = destination.parent.resolve(strict=True)
    target = parent / destination.name
    if (not destination.name or destination.name in (".", "..") or
            _inside(target, private.resolve()) or _inside(target, public.resolve()) or
            target.exists() or target.is_symlink()):
        raise PublicationHold("INVENTORY_REPORT_DESTINATION_HOLD")
    payload = (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(target, flags, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError as exc:
        raise PublicationHold("INVENTORY_LOCAL_REPORT_WRITE_HOLD") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-root", required=True, type=Path)
    parser.add_argument("--public-root", required=True, type=Path)
    parser.add_argument("--private-head", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = inventory_private_head(args.private_root, args.private_head)
        save_confidential_report(report, args.output, args.private_root, args.public_root)
    except (PublicationHold, OSError) as exc:
        print("PRIVATE_INVENTORY_HOLD:" + str(exc))
        return 1
    summary = report["candidate_audit"]
    print("PRIVATE_INVENTORY_LOCAL_ONLY_FILES=" + str(len(report["files"])))
    print("N_CANDIDATE=" + str(summary["candidate"]))
    for state in CANDIDATE_STATES:
        print("N_" + state + "=" + str(summary["states"][state]))
    print("N_COPYABLE=" + str(summary["copyable"]))
    print("N_ACTUALLY_COPIED=0")
    print("PUBLIC_SOURCE_COPY_REMAINS_HOLD_PENDING_FULL_AUDIT_AND_DRY_RUN")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
