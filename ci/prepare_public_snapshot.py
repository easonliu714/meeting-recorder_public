#!/usr/bin/env python3
"""Stage a fail-closed, reviewed snapshot from a LOCAL private Git checkout.

No network, credentials, remote push, release, provider traffic, or user media.
The source of truth remains the private repository at --private-head. Never
replace its main/master branch or copy its Git history into the public mirror.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile

from audit_private_git_head import inspect_private_head
from verify_public_snapshot import (
    BINARY_WHITELIST, BOOTSTRAP_FILES, MANIFEST, REQUIRED_SOURCE_FILES,
    OWNER_APPROVED_ICON_GIT_BLOBS,
    SENSITIVE_PATTERNS, PublicationHold, _allowed_source, audit,
)

# These are the Owner-supplied original files, not a regenerated font.
EXPECTED_FONT_ASSETS = {
    "assets/fonts/NotoSansTC-Regular.ttf": (
        7109460, "add35d53f70727657b4509531677c4e3712b67df3d54661efdee5d3a0c16d954"),
    "assets/fonts/NotoSansTC-Bold.ttf": (
        7104212, "ed4ae6ed781e34d0beee896e9be5d835a938ac7adabbcc1b6b6904290006f372"),
    "assets/fonts/OFL.txt": (
        4481, "92c343f7e7caebff8bace350bc091b79755f4d0c8b70bb0df21570a1828917b8"),
}
SENSITIVE_EXTRA = (
    re.compile(r"(?:C:\\Users\\[^\\\s]+\\|/Users/[^/\s]+/)", re.I),
    re.compile(r"(?i)(?:api[_-]?key|password|private[_-]?token)\s*[:=]\s*['\"][^'\"]{10,}['\"]"),
)
HEX40 = re.compile(r"[0-9a-f]{40}")


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise PublicationHold("LOCAL_GIT_READ_HOLD:" + args[0])
    return result.stdout


def tracked_entries(repo: Path, head: str) -> list[tuple[str, str, str]]:
    """Read immutable Git tree objects, never untracked working-tree bytes."""
    entries = []
    for item in git(repo, "ls-tree", "-r", "-z", head).split(b"\0"):
        if not item:
            continue
        try:
            descriptor, raw_path = item.split(b"\t", 1)
            mode, kind, blob = descriptor.decode("ascii").split()
            path = raw_path.decode("utf-8")
        except (UnicodeError, ValueError) as exc:
            raise PublicationHold("GIT_TREE_PARSE_HOLD") from exc
        if (not path or path.startswith("/") or "\\" in path or
                ".." in PurePosixPath(path).parts or
                PurePosixPath(path).as_posix() != path):
            raise PublicationHold("GIT_PATH_HOLD")
        if not _allowed_source(path):
            continue
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise PublicationHold("GIT_SYMLINK_OR_MODE_HOLD:" + path)
        if not HEX40.fullmatch(blob):
            raise PublicationHold("GIT_BLOB_SHA_HOLD")
        entries.append((path, mode, blob))
    if len({path for path, _, _ in entries}) != len(entries):
        raise PublicationHold("DUPLICATE_SOURCE_PATH_HOLD")
    return sorted(entries)


def inspect_bytes(path: str, data: bytes) -> str:
    digest = hashlib.sha256(data).hexdigest()
    expected = EXPECTED_FONT_ASSETS.get(path)
    if expected and (len(data), digest) != expected:
        raise PublicationHold("ORIGINAL_FONT_OR_OFL_INTEGRITY_HOLD:" + path)
    if path in OWNER_APPROVED_ICON_GIT_BLOBS:
        object_bytes = b"blob " + str(len(data)).encode("ascii") + b"\0" + data
        if hashlib.sha1(object_bytes).hexdigest() != OWNER_APPROVED_ICON_GIT_BLOBS[path]:
            raise PublicationHold("OWNER_ICON_BLOB_MISMATCH_HOLD:" + path)
    if path in BINARY_WHITELIST:
        return digest
    if len(data) > 1_000_000 or b"\0" in data:
        raise PublicationHold("UNEXPECTED_BINARY_SOURCE_HOLD:" + path)
    try:
        content = data.decode("utf-8")
    except UnicodeError as exc:
        raise PublicationHold("NON_UTF8_SOURCE_HOLD:" + path) from exc
    if any(pattern.search(content) for pattern in (*SENSITIVE_PATTERNS, *SENSITIVE_EXTRA)):
        raise PublicationHold("SENSITIVE_SOURCE_HOLD:" + path)
    return digest



def read_approved_scope(path: Path, head: str) -> dict[str, str]:
    """Local per-file human rights/privacy sign-off; never a public artifact.

    A regex-only PASS, icon approval, or a matching SHA does not authorize
    unrelated application code. This review input must be held privately.
    """
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError) as exc:
        raise PublicationHold("PRIVATE_SCOPE_APPROVAL_MISSING_OR_INVALID_HOLD") from exc
    if (not isinstance(doc, dict) or set(doc) !=
            {"schema", "private_source_head", "files"} or
            doc["schema"] != 1 or doc["private_source_head"] != head or
            not isinstance(doc["files"], list) or not doc["files"]):
        raise PublicationHold("PRIVATE_SCOPE_HEAD_OR_SCHEMA_HOLD")
    approved: dict[str, str] = {}
    for row in doc["files"]:
        if (not isinstance(row, dict) or set(row) !=
                {"path", "sha256", "rights", "privacy"}):
            raise PublicationHold("PRIVATE_SCOPE_ROW_SCHEMA_HOLD")
        name, digest = row["path"], row["sha256"]
        if (not isinstance(name, str) or not isinstance(digest, str) or
                not _allowed_source(name) or not re.fullmatch(r"[0-9a-f]{64}", digest) or
                name in approved or row["rights"] != "OWNER_PASS" or
                row["privacy"] != "REVIEW_PASS"):
            raise PublicationHold("PRIVATE_SCOPE_UNAPPROVED_OR_DUPLICATE_HOLD")
        approved[name] = digest
    return approved


def verify_approved_rows(rows: list[dict], approved: dict[str, str]) -> None:
    """Fail closed on missing, extra, or changed source relative to review."""
    if {row["path"] for row in rows} != set(approved):
        raise PublicationHold("PRIVATE_SCOPE_FILE_SET_MISMATCH_HOLD")
    if any(row["sha256"] != approved[row["path"]] for row in rows):
        raise PublicationHold("PRIVATE_SCOPE_SHA256_MISMATCH_HOLD")


def create_staging(private: Path, public: Path, head: str, destination: Path,
                   approved: dict[str, str]) -> dict:
    if not HEX40.fullmatch(head):
        raise PublicationHold("INVALID_PRIVATE_HEAD")
    if git(private, "rev-parse", "HEAD").decode().strip() != head:
        raise PublicationHold("PRIVATE_HEAD_CHANGED_HOLD")
    if audit(public) not in ("BOOTSTRAP_ONLY", "FONT_ASSETS_READY"):
        raise PublicationHold("PUBLIC_NOT_CLEAN_BOOTSTRAP_HOLD")
    for name in BOOTSTRAP_FILES:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(public / name, target)
    manifest_rows = []
    for path, _mode, blob in tracked_entries(private, head):
        content = git(private, "cat-file", "blob", blob)
        digest = inspect_bytes(path, content)
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        manifest_rows.append({"path": path, "sha256": digest})
    verify_approved_rows(manifest_rows, approved)
    exported = {row["path"] for row in manifest_rows}
    if not REQUIRED_SOURCE_FILES.issubset(exported):
        raise PublicationHold("PRIVATE_REQUIRED_SOURCE_MISSING_HOLD")
    manifest = {"schema": 1, "private_source_head": head, "files": manifest_rows}
    target = destination / MANIFEST
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                      encoding="utf-8")
    if audit(destination) != "SOURCE_INTEGRITY_READY":
        raise PublicationHold("PUBLIC_STAGE_INTEGRITY_HOLD")
    return manifest


def prepare(private: Path, public: Path, head: str, approval_manifest: Path,
            apply: bool = False) -> int:
    # Verify the local checkout is the intended private repo, not a fork or
    # accidentally reused public clone. Only immutable tracked blobs are read.
    private_remote = git(private, "remote", "get-url", "origin").decode().strip()
    public_remote = git(public, "remote", "get-url", "origin").decode().strip()
    if (not re.search(r"easonliu714/meeting-recorder(?:\.git)?$", private_remote) or
            not re.search(r"easonliu714/meeting-recorder_public(?:\.git)?$", public_remote)):
        raise PublicationHold("REPOSITORY_IDENTITY_HOLD")
    # Scan ALL tracked Private exact-HEAD blobs before selective export. This
    # catches sensitive material even under excluded docs/CI files and refuses
    # the original Private signing-properties .gitignore vulnerability.
    inspect_private_head(private, head)
    approved = read_approved_scope(approval_manifest, head)
    with tempfile.TemporaryDirectory(prefix="mr-public-export-") as temp:
        staged = Path(temp)
        manifest = create_staging(private, public, head, staged, approved)
        if not apply:
            print("PUBLIC_SNAPSHOT_DRY_RUN_PASS_SOURCE_FILES=" + str(len(manifest["files"])))
            print("PUBLIC_SNAPSHOT_NO_PUBLIC_WRITE")
            return len(manifest["files"])
        # Never modify existing tracked paths, Git refs, histories or bootstrap
        # guards. The recipient must independently review/git-add/git-push.
        if audit(public) not in ("BOOTSTRAP_ONLY", "FONT_ASSETS_READY"):
            raise PublicationHold("PUBLIC_CONCURRENT_CHANGE_HOLD")
        for row in manifest["files"]:
            path = row["path"]
            dst = public / path
            if dst.exists() or dst.is_symlink():
                # Owner-uploaded original TTFs and OFL may already be staged.
                # Only byte-identical attested originals may be retained.
                if path not in EXPECTED_FONT_ASSETS or dst.is_symlink() or (
                        hashlib.sha256(dst.read_bytes()).hexdigest() != row["sha256"]):
                    raise PublicationHold("PUBLIC_DESTINATION_EXISTS_HOLD:" + path)
        for row in manifest["files"]:
            path = row["path"]
            dst = public / path
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists():
                shutil.copyfile(staged / path, dst)
        (public / MANIFEST).write_bytes((staged / MANIFEST).read_bytes())
        if audit(public) != "SOURCE_INTEGRITY_READY":
            raise PublicationHold("PUBLIC_POST_COPY_AUDIT_HOLD")
        print("PUBLIC_SNAPSHOT_STAGED_LOCAL_NO_PUSH_SOURCE_FILES=" +
              str(len(manifest["files"])))
        print("PRIVATE_EXACT_HEAD=" + head)
        return len(manifest["files"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-root", required=True, type=Path)
    parser.add_argument("--public-root", required=True, type=Path)
    parser.add_argument("--private-head", required=True)
    parser.add_argument("--approval-manifest", required=True, type=Path,
                        help="Private local per-file Owner rights and privacy review; never commit")
    parser.add_argument("--apply", action="store_true", help="Copy only after full dry-run audit; NEVER push")
    args = parser.parse_args()
    try:
        prepare(args.private_root.resolve(), args.public_root.resolve(),
                args.private_head, args.approval_manifest.resolve(), apply=args.apply)
    except PublicationHold as exc:
        print("PUBLIC_EXPORT_HOLD:" + str(exc))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
