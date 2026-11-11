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
    OWNER_APPROVED_ICON_GIT_BLOBS, PRIVATE_ONLY_TESTS, _allowed_source,
)
from prepare_public_snapshot import require_trusted_repo_origin


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
    # Share the exporter\u0027s exact GitHub owner/host allowlist; a regex suffix\n    # would accept lookalike domains such as notgithub.com.\n    require_trusted_repo_origin(origin, "meeting-recorder")
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
        rows.append({"path": path, "git_blob_sha1": blob, "sha256": digest,
                     "decision": decision, "reason": reason})
    if not rows:
        raise PublicationHold("INVENTORY_EMPTY_TREE_HOLD")
    rows.sort(key=lambda row: row["path"])
    counts = {state: sum(row["decision"] == state for row in rows)
              for state in ("ALLOW", "DENY", "HOLD")}
    return {"schema": 1, "private_source_head": head,
            "classification": "CONFIDENTIAL_LOCAL_REVIEW_ONLY_NOT_PUBLICATION_APPROVAL",
            "counts": counts, "files": rows}


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
    print("PRIVATE_INVENTORY_LOCAL_ONLY_FILES=" + str(len(report["files"])))
    print("PUBLIC_SOURCE_COPY_REMAINS_HOLD_PENDING_FILE_RIGHTS_PRIVACY_PARITY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
