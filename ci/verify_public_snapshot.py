#!/usr/bin/env python3
"""Fail-closed guardrails for a sanitized public CI snapshot.

Bootstrap success is NOT application CI success.
This tool intentionally has no private repository credentials or network calls.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

BOOTSTRAP_FILES = {
    "README.md",
    "ci/verify_public_snapshot.py",
    "ci/tests/test_verify_public_snapshot.py",
    "ci/tests/test_public_ci_workflow_contract.py",
    "ci/tests/test_h04m_physical_two_hour_aac.py",
    "ci/prepare_public_snapshot.py",
    "ci/tests/test_prepare_public_snapshot.py",
    "ci/tests/test_font_intake.py",
    "ci/audit_private_git_head.py",
    "ci/tests/test_audit_private_git_head.py",
    "ci/private_inventory_report.py",
    "ci/tests/test_private_inventory_report.py",
    ".github/workflows/public-ci.yml",
    ".github/workflows/public-apk-manual.yml",
    "ci/tests/test_public_apk_manual_contract.py",
    "ci/verify_public_apk_identity.py",
    "ci/tests/test_verify_public_apk_identity.py",
}
MANIFEST = "ci/public_snapshot_manifest.json"
ROOT_SOURCE_FILES = {
    "pubspec.yaml", "pubspec.lock", "analysis_options.yaml",
    ".gitignore", ".metadata", "devtools_options.yaml",
}
SOURCE_PREFIXES = ("lib/", "test/", "tool/", "android/", "assets/fonts/")
REQUIRED_SOURCE_FILES = {
    "lib/main.dart", "pubspec.yaml", "pubspec.lock",
    "android/app/src/main/AndroidManifest.xml",
    "android/app/build.gradle.kts",
    "tool/patch_v1_1_4_issue65_import_roster_groq_clock_quality_default_p0.py",
    "assets/fonts/OFL.txt",
    "assets/fonts/NotoSansTC-Regular.ttf",
    "assets/fonts/NotoSansTC-Bold.ttf",
}
# These tests are bound to private runner / signing workflows and must be
# replaced by independently audited public contract tests, never copied.
PRIVATE_ONLY_TESTS = {
    "tool/tests/test_mr_windows_smoke_workflow.py",
    "tool/tests/test_private_ci_event_policy.py",
    "tool/tests/test_generated_android_build_identity.py",
    "tool/tests/test_generated_groq_native_delivery_gate.py",
    # Private inventory and legacy signing/UAT tools have Public replacements.
    "tool/private_exact_head_inventory.py",
    "tool/tests/test_private_exact_head_inventory.py",
    # Read-only Private exporter handoff and its synthetic tests never ship.
    "tool/private_public_export_preflight.py",
    "tool/tests/test_private_public_export_preflight.py",
    "tool/verify_signed_android_apk.py",
    "tool/tests/test_verify_signed_android_apk.py",
    "tool/verify_uat_artifact_zip.py",
    "tool/tests/test_verify_uat_artifact_zip.py",
}
FORBIDDEN_PREFIXES = (
    "evidence/", "docs/", ".idx/", ".vscode/", "recordings/",
    "private/", "secrets/", "backup/", ".github/actions/",
)
FORBIDDEN_NAMES = {
    "GEMINI.md", "key.properties", "local.properties",
    "gradle.properties.local", ".env", ".env.local",
    "upload-keystore.properties", "signing.properties",
    "service-account.json", "google-services.json",
}
FORBIDDEN_EXTENSIONS = {
    ".wav", ".mp3", ".m4a", ".aac", ".mp4", ".ogg", ".apk", ".aab",
    ".jks", ".keystore", ".p12", ".pfx", ".pem", ".key", ".sqlite",
    ".sqlite3", ".db", ".zip", ".tar", ".log", ".jsonl", ".png",
    ".jpg", ".jpeg", ".webp", ".ico",
}

# Owner-approved exact eleven PNG Git blobs, independently verified at Private
# PR79 and reproduced 10/10 with pinned flutter_launcher_icons 0.13.1.
# The pins authorize only these bytes, not other Private Source/Test rights.
OWNER_APPROVED_ICON_GIT_BLOBS = {
    "android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png": "7f08a66899bd0a1e7064cec782de6b925fdb670a",
    "android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png": "776884810a7392f717472b71eeb4b1c92558229c",
    "android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground.png": "8c9c9045cbf33287ba49a6a5b94d8246c3b14a72",
    "android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png": "8dd2c173241540841ff31b279ad88613d171b944",
    "android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png": "e2342a82ccdfcdeeda30245a00c45b09756d73e7",
    "android/app/src/main/res/mipmap-hdpi/ic_launcher.png": "f053c50b238bc1c9a7f6e7283b1a6ca675db6c6a",
    "android/app/src/main/res/mipmap-mdpi/ic_launcher.png": "2ee3bfbdfd4a946b9fe398681ebe1c3cbb64ec5f",
    "android/app/src/main/res/mipmap-xhdpi/ic_launcher.png": "a02e1bf488cccca6580eeefb1a891a94f046111e",
    "android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png": "6a2cedb957a35195728c6aebf5826f959be04fca",
    "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png": "dfc3d96b2388a583472889a7ab5f02781e2af7bf",
    "assets/app_icon.png": "1525671bf194a4627a7aa275cbf32528fa8ada49",
}

BINARY_WHITELIST = {
    "assets/fonts/NotoSansTC-Regular.ttf",
    "assets/fonts/NotoSansTC-Bold.ttf",
} | set(OWNER_APPROVED_ICON_GIT_BLOBS)
# H04J exact original Owner font identity: a changed manifest may NOT relabel
# a modified font as approved. Check the same immutable digests in both
# bootstrap-intake and full-source modes.
ORIGINAL_FONT_ASSETS = {
    "assets/fonts/NotoSansTC-Regular.ttf": (7109460, "add35d53f70727657b4509531677c4e3712b67df3d54661efdee5d3a0c16d954"),
    "assets/fonts/NotoSansTC-Bold.ttf": (7104212, "ed4ae6ed781e34d0beee896e9be5d835a938ac7adabbcc1b6b6904290006f372"),
    "assets/fonts/OFL.txt": (4481, "92c343f7e7caebff8bace350bc091b79755f4d0c8b70bb0df21570a1828917b8"),
}


def _audit_original_fonts(root: Path) -> None:
    """No incomplete pair, substitute binaries, missing OFL or silent repair."""
    for path, (expected_size, expected_sha) in ORIGINAL_FONT_ASSETS.items():
        target = root / path
        if not target.is_file() or target.is_symlink():
            raise PublicationHold("ORIGINAL_FONT_PAIR_MISSING:" + path)
        data = target.read_bytes()
        if len(data) != expected_size or hashlib.sha256(data).hexdigest() != expected_sha:
            raise PublicationHold("ORIGINAL_FONT_BYTES_MISMATCH:" + path)

SENSITIVE_PATTERNS = [
    re.compile(r"gh[pousr]_[A-Za-z0-9_]{24,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{24,}"),
    re.compile(r"(?:gsk_|sk-)[A-Za-z0-9_-]{25,}"),
    re.compile(r"AIza[A-Za-z0-9_-]{30,}"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.I),
]


class PublicationHold(Exception):
    pass


def _allowed_source(path: str) -> bool:
    return (
        path in OWNER_APPROVED_ICON_GIT_BLOBS or (
            (path in ROOT_SOURCE_FILES or path.startswith(SOURCE_PREFIXES))
            and path not in PRIVATE_ONLY_TESTS
            and not path.startswith(FORBIDDEN_PREFIXES)
            and Path(path).name not in FORBIDDEN_NAMES
            and Path(path).suffix.lower() not in FORBIDDEN_EXTENSIONS
        )
    )



PUBLIC_APP_ID = "com.example.meeting_recorder.public"
PUBLIC_GRADLE_PATH = "android/app/build.gradle.kts"


def mask_gradle_comments(source: str) -> str:
    """Mask nested Kotlin comments/raw strings without shifting source offsets."""
    chars = list(source)
    size = len(source)
    i = 0
    while i < size:
        if source.startswith("//", i):
            end = source.find("\n", i)
            if end < 0:
                end = size
            for pos in range(i, end):
                if chars[pos] not in "\r\n":
                    chars[pos] = " "
            i = end
        elif source.startswith("/*", i):
            start, depth = i, 1
            i += 2
            while depth:
                if i >= size:
                    raise PublicationHold("GRADLE_UNTERMINATED_BLOCK_COMMENT_HOLD")
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            for pos in range(start, i):
                if chars[pos] not in "\r\n":
                    chars[pos] = " "
        elif source.startswith('"""', i):
            end = source.find('"""', i + 3)
            if end < 0:
                raise PublicationHold("GRADLE_UNTERMINATED_RAW_STRING_HOLD")
            for pos in range(i, end + 3):
                if chars[pos] not in "\r\n":
                    chars[pos] = " "
            i = end + 3
        elif source[i] in ('"', "'"):
            quote = source[i]
            i += 1
            while i < size:
                if source[i] == "\\":
                    i += 2
                elif source[i] == quote:
                    i += 1
                    break
                elif source[i] in "\r\n":
                    raise PublicationHold("GRADLE_UNTERMINATED_STRING_HOLD")
                else:
                    i += 1
            else:
                raise PublicationHold("GRADLE_UNTERMINATED_STRING_HOLD")
        else:
            i += 1
    return "".join(chars)


def verify_public_android_identity(root: Path) -> None:
    """Require one executable Public app ID, not a commented or quoted decoy."""
    target = root / "android/app/build.gradle.kts"
    try:
        source = target.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise PublicationHold("PUBLIC_APP_ID_BUILD_FILE_HOLD") from exc
    effective = mask_gradle_comments(source)
    assignments = re.findall(r'(?m)^[ \t]*applicationId[ \t]*=', effective)
    valid = re.findall(
        r'(?m)^[ \t]*applicationId[ \t]*=[ \t]*"([^"\r\n]+)"[ \t]*$',
        effective,
    )
    if (len(assignments) != 1 or valid != [PUBLIC_APP_ID] or
            re.search(r'(?m)^[ \t]*applicationIdSuffix[ \t]*=', effective) or
            re.search(r'com\.example\.meeting_recorder(?!\.public)', source)):
        raise PublicationHold("PUBLIC_APP_ID_INDEPENDENCE_HOLD")


def audit(root: Path) -> str:
    actual: set[str] = set()
    for item in root.rglob("*"):
        rel = item.relative_to(root).as_posix()
        if rel == ".git" or rel.startswith(".git/"):
            continue
        if item.is_symlink():
            raise PublicationHold("SYMLINK_BLOCKED:" + rel)
        if item.is_file():
            if not item.is_relative_to(root):
                raise PublicationHold("PATH_ESCAPE_BLOCKED")
            actual.add(rel)
    if not BOOTSTRAP_FILES.issubset(actual):
        raise PublicationHold("BOOTSTRAP_FILES_MISSING")
    if MANIFEST not in actual:
        if actual == BOOTSTRAP_FILES:
            return "BOOTSTRAP_ONLY"
        if actual == BOOTSTRAP_FILES | set(ORIGINAL_FONT_ASSETS):
            _audit_original_fonts(root)
            return "FONT_ASSETS_READY"
        raise PublicationHold("UNATTESTED_SOURCE_IN_BOOTSTRAP")
    # Full Source+Test attestation is NOT a bypass around original asset hashes.
    _audit_original_fonts(root)
    try:
        doc = json.loads((root / MANIFEST).read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as exc:
        raise PublicationHold("INVALID_SOURCE_MANIFEST") from exc
    if doc.get("schema") != 1 or not re.fullmatch(
        r"[0-9a-f]{40}", doc.get("private_source_head", "")
    ):
        raise PublicationHold("MISSING_EXACT_SOURCE_HEAD")
    rows = doc.get("files")
    if not isinstance(rows, list) or not rows:
        raise PublicationHold("EMPTY_SOURCE_MANIFEST")
    allowed: set[str] = set()
    previous = ""
    for item in rows:
        if not isinstance(item, dict):
            raise PublicationHold("INVALID_MANIFEST_ENTRY")
        fields = set(item)
        transformed = fields == {"path", "sha256", "source_sha256", "transform"}
        if fields != {"path", "sha256"} and not transformed:
            raise PublicationHold("INVALID_MANIFEST_ENTRY")
        path, expected = item["path"], item["sha256"]
        # The reviewed Private input and transformed Public bytes are distinct.
        if path == PUBLIC_GRADLE_PATH and not transformed:
            raise PublicationHold("PUBLIC_GRADLE_TRANSFORM_ATTESTATION_HOLD")
        if transformed and (
            path != PUBLIC_GRADLE_PATH or item["transform"] != "PUBLIC_APP_ID_V1"
            or not isinstance(item["source_sha256"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", item["source_sha256"])
            or item["source_sha256"] == expected
        ):
            raise PublicationHold("PUBLIC_GRADLE_TRANSFORM_PROVENANCE_HOLD")
        if not isinstance(path, str) or not isinstance(expected, str):
            raise PublicationHold("INVALID_MANIFEST_TYPES")
        if path <= previous or not _allowed_source(path):
            raise PublicationHold("UNORDERED_OR_UNSAFE_SOURCE:" + path)
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise PublicationHold("INVALID_FILE_SHA256:" + path)
        previous = path
        allowed.add(path)
        target = root / path
        if not target.is_file() or target.is_symlink():
            raise PublicationHold("MISSING_SOURCE:" + path)
        data = target.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise PublicationHold("SOURCE_DIGEST_MISMATCH:" + path)
        if path in OWNER_APPROVED_ICON_GIT_BLOBS:
            object_bytes = b"blob " + str(len(data)).encode("ascii") + b"\0" + data
            if hashlib.sha1(object_bytes).hexdigest() != OWNER_APPROVED_ICON_GIT_BLOBS[path]:
                raise PublicationHold("OWNER_ICON_BLOB_MISMATCH:" + path)
        if path not in BINARY_WHITELIST:
            try:
                content = data.decode("utf-8")
            except UnicodeError as exc:
                raise PublicationHold("NON_UTF8_SOURCE:" + path) from exc
            if any(pattern.search(content) for pattern in SENSITIVE_PATTERNS):
                raise PublicationHold("SENSITIVE_TEXT_PATTERN:" + path)
    if not REQUIRED_SOURCE_FILES.issubset(allowed):
        raise PublicationHold("REQUIRED_SOURCE_FILE_MISSING")
    if actual != BOOTSTRAP_FILES | {MANIFEST} | allowed:
        raise PublicationHold("UNATTESTED_OR_EXTRA_FILE")
    verify_public_android_identity(root)
    return "SOURCE_INTEGRITY_READY"


if __name__ == "__main__":
    try:
        state = audit(ROOT)
    except PublicationHold as exc:
        print("PUBLIC_EXPORT_HOLD:" + str(exc))
        raise SystemExit(1)
    print("PUBLIC_EXPORT_" + state)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as stream:
            stream.write("has_source=" + ("true" if state == "SOURCE_INTEGRITY_READY" else "false") + "\n")
