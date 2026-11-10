#!/usr/bin/env python3
"""Offline PRIVATE exact-Git-HEAD sensitive-material audit. Never publishes.

Checks every tracked text blob, including private-only docs/CI scripts
excluded from the later Public export. A clean regex result is NOT an
Owner license approval, rights verification or full data-flow review.
This tool never reads the working-tree media, tokens or GitHub secrets,
and does not print matched secret values. Its execution is local only.
"""
from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import re
import subprocess

from verify_public_snapshot import PublicationHold, SENSITIVE_PATTERNS

HEX40 = re.compile(r"^[0-9a-f]{40}$")
# Binary code/media cannot become public merely by passing a text scan.
KNOWN_PRIVATE_BINARY = {".png", ".ttf"}
# Never let accidental tracked credential data through, EVEN IF it is
# referenced only by the private signing workflow rather than the app.
FORBIDDEN_TRACKED_NAMES = {
    "upload-keystore.properties", "key.properties", "local.properties",
    "signing.properties", "service-account.json", "google-services.json",
    ".env", ".env.local",
}
FORBIDDEN_TRACKED_SUFFIXES = {
    ".jks", ".keystore", ".p12", ".pfx", ".pem", ".key",
    ".wav", ".mp3", ".aac", ".m4a", ".mp4", ".sqlite", ".db",
    ".zip", ".log", ".jsonl",
}
PROPERTIES_SECRET = re.compile(
    r"(?mi)^\s*(?:storePassword|keyPassword|api[_-]?key|"
    r"client[_-]?secret|auth[_-]?token)\s*[:=]\s*\S+"
)
TAIWAN_MOBILE = re.compile(r"(?<!\d)(?:\+886[- ]?9\d{8}|09\d{8})(?!\d)")


def private_git(root: Path, *args: str) -> bytes:
    process = subprocess.run(
        ["git", "-C", str(root), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if process.returncode:
        # Do not echo git stderr; it may include credentials from remotes.
        raise PublicationHold("PRIVATE_GIT_READ_HOLD:" + args[0])
    return process.stdout


def inspect_text(path: str, contents: bytes) -> None:
    if b"\0" in contents or len(contents) > 2_000_000:
        raise PublicationHold("PRIVATE_UNEXPECTED_BINARY_HOLD:" + path)
    try:
        value = contents.decode("utf-8")
    except UnicodeError as exc:
        raise PublicationHold("PRIVATE_NON_UTF8_HOLD:" + path) from exc
    for kind, pattern in (
        *[(("credential_or_personal_data"), p) for p in SENSITIVE_PATTERNS],
        ("taiwan_mobile", TAIWAN_MOBILE),
    ):
        match = pattern.search(value)
        if match:
            line = value.count("\n", 0, match.start()) + 1
            raise PublicationHold(
                "PRIVATE_SENSITIVE_TEXT_HOLD:" + kind + ":" +
                path + ":L" + str(line)
            )
    if path.endswith(".properties"):
        match = PROPERTIES_SECRET.search(value)
        if match:
            line = value.count("\n", 0, match.start()) + 1
            raise PublicationHold(
                "PRIVATE_PROPERTY_CREDENTIAL_HOLD:" + path + ":L" + str(line)
            )


def inspect_private_head(root: Path, head: str) -> tuple[int, int]:
    if not HEX40.fullmatch(head):
        raise PublicationHold("INVALID_PRIVATE_AUDIT_HEAD")
    if private_git(root, "rev-parse", "HEAD").decode("ascii").strip() != head:
        raise PublicationHold("PRIVATE_HEAD_CHANGED_HOLD")
    tree = private_git(root, "ls-tree", "-r", "-z", head)
    audited_text = 0
    excluded_binary = 0
    seen: set[str] = set()
    gitignores: dict[str, str] = {}
    for entry in tree.split(b"\0"):
        if not entry:
            continue
        try:
            metadata, encoded_path = entry.split(b"\t", 1)
            mode, kind, sha = metadata.decode("ascii").split()
            path = encoded_path.decode("utf-8")
        except (ValueError, UnicodeError) as exc:
            raise PublicationHold("PRIVATE_TREE_PARSE_HOLD") from exc
        if (not path or path in seen or path.startswith("/") or
                "\\" in path or ".." in PurePosixPath(path).parts or
                PurePosixPath(path).as_posix() != path or
                mode not in {"100644", "100755"} or kind != "blob" or
                not HEX40.fullmatch(sha)):
            raise PublicationHold("PRIVATE_TREE_PATH_OR_SYMLINK_HOLD")
        seen.add(path)
        suffix = Path(path).suffix.lower()
        if Path(path).name in FORBIDDEN_TRACKED_NAMES or suffix in FORBIDDEN_TRACKED_SUFFIXES:
            raise PublicationHold("PRIVATE_TRACKED_SENSITIVE_FILE_HOLD:" + path)
        if suffix in KNOWN_PRIVATE_BINARY:
            excluded_binary += 1
            continue
        body = private_git(root, "cat-file", "blob", sha)
        inspect_text(path, body)
        audited_text += 1
        if path in (".gitignore", "android/.gitignore"):
            gitignores[path] = body.decode("utf-8")
    if "android/.gitignore" not in gitignores:
        raise PublicationHold("PRIVATE_ANDROID_GITIGNORE_MISSING_HOLD")
    android_patterns = {
        line.split("#", 1)[0].strip()
        for line in gitignores["android/.gitignore"].splitlines()
    }
    root_patterns = {
        line.split("#", 1)[0].strip()
        for line in gitignores.get(".gitignore", "").splitlines()
    }
    # CI generates plaintext storePassword/keyPassword in this file.
    # An exact Private HEAD must protect it, even if no key is tracked now.
    if not (
        {"/upload-keystore.properties", "upload-keystore.properties"} & android_patterns
        or {"/android/upload-keystore.properties", "android/upload-keystore.properties"} & root_patterns
    ):
        raise PublicationHold("PRIVATE_SIGNING_PROPERTIES_IGNORE_GAP_HOLD")
    if not any(x in android_patterns for x in ("**/*.jks", "*.jks", "/app/upload-keystore.jks")):
        raise PublicationHold("PRIVATE_SIGNING_KEY_IGNORE_GAP_HOLD")
    if audited_text == 0:
        raise PublicationHold("EMPTY_PRIVATE_TEXT_AUDIT_HOLD")
    return audited_text, excluded_binary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-root", required=True, type=Path)
    parser.add_argument("--private-head", required=True)
    args = parser.parse_args()
    try:
        texts, binaries = inspect_private_head(
            args.private_root.resolve(), args.private_head,
        )
    except PublicationHold as exc:
        print("PRIVATE_HEAD_SENSITIVE_AUDIT_HOLD:" + str(exc))
        return 1
    print(f"PRIVATE_HEAD_SENSITIVE_PATTERN_SCAN_PASS_TEXT={texts}_BINARY_EXCLUDED={binaries}")
    print("PRIVATE_PUBLICATION_RIGHTS_AND_MANUAL_REVIEW_STILL_REQUIRED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
