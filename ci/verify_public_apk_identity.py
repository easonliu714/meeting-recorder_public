#!/usr/bin/env python3
"""Public-only identity and new signer. Never accept the historical Private APK."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import ssl
import subprocess
import sys

PUBLIC_ID = "com.example.meeting_recorder.public"
PRIVATE_ID = "com.example.meeting_recorder"
PRIVATE_SIGNER = "211EBB33C98359E8F49F0423231826DF22B04643BE418754C939ECB2FFC1435D"
APP_ID_RE = re.compile(r'(?m)^\s*applicationId\s*=\s*"([A-Za-z0-9_.]+)"\s*(?://.*)?$')
PKG_RE = re.compile(r"^package:\s+name='([^']+)'\s+versionCode='(\d+)'\s+versionName='([^']+)'(?:\s|$)")
SDK_RE = re.compile(r"(?m)^sdkVersion:'(\d+)'$")
PEM_RE = re.compile(r"-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----", re.S)

class PublicHold(Exception):
    pass

def check_source(source: str) -> None:
    if APP_ID_RE.findall(source) != [PUBLIC_ID]:
        raise PublicHold("SOURCE_PUBLIC_APP_ID_REQUIRED")

def check_signer(expected: str) -> None:
    if not re.fullmatch("[A-F0-9]{64}", expected or ""):
        raise PublicHold("PUBLIC_SIGNER_NOT_PINNED")
    if expected == PRIVATE_SIGNER:
        raise PublicHold("PRIVATE_SIGNER_REUSE_BLOCKED")

def parse_badging(data: str) -> tuple[str,str,str]:
    rows = [m.groups() for line in data.splitlines() if (m := PKG_RE.match(line))]
    sdk = SDK_RE.findall(data)
    if len(rows) != 1 or len(sdk) != 1:
        raise PublicHold("PACKAGE_IDENTITY_RECORD_COUNT")
    app, code, name = rows[0]
    if app != PUBLIC_ID or app == PRIVATE_ID:
        raise PublicHold("PRIVATE_APP_OVERWRITE_BLOCKED")
    if sdk[0] != "21" or int(code) < 1 or not name.strip():
        raise PublicHold("PUBLIC_PACKAGE_VERSION_SDK_INVALID")
    return code, name, sdk[0]

def parse_certificate(data: str) -> str:
    blocks = PEM_RE.findall(data)
    if len(blocks) != 1:
        raise PublicHold("APK_SIGNER_CERT_COUNT_INVALID")
    signer_indices = set(re.findall(r"(?im)^\s*Signer\s*#\s*(\d+)\s+certificate\b", data))
    if signer_indices and signer_indices != {"1"}:
        raise PublicHold("APK_MULTIPLE_SIGNERS")
    try:
        der = ssl.PEM_cert_to_DER_cert("-----BEGIN CERTIFICATE-----\n"+blocks[0].strip()+"\n-----END CERTIFICATE-----")
    except (ValueError, ssl.SSLError) as exc:
        raise PublicHold("APK_SIGNER_CERT_INVALID") from exc
    if len(der) < 8 or der[0] != 0x30:
        raise PublicHold("APK_SIGNER_DER_INVALID")
    return hashlib.sha256(der).hexdigest().upper()

def run_checked(argv: list[str], stage: str) -> str:
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if p.returncode:
        raise PublicHold(stage+"_FAILED")
    try:
        return p.stdout.decode("utf-8")
    except UnicodeError as exc:
        raise PublicHold(stage+"_NON_UTF8") from exc

def verify(apk: Path, apksigner: str, aapt: str, signer: str,
           expected_head: str, manifest: Path) -> dict[str,str]:
    check_signer(signer)
    if not re.fullmatch("[0-9a-f]{40}", expected_head or ""):
        raise PublicHold("EXACT_HEAD_INVALID")
    if run_checked(["git","rev-parse","HEAD"],"GIT_HEAD").strip() != expected_head:
        raise PublicHold("EXACT_HEAD_CHANGED")
    if not apk.is_file() or apk.is_symlink() or apk.stat().st_size == 0:
        raise PublicHold("APK_MISSING")
    if manifest != apk.with_name(apk.name+".provenance.json") or manifest.exists():
        raise PublicHold("PROVENANCE_PATH_INVALID")
    actual = parse_certificate(run_checked(
        [apksigner,"verify","--verbose","--print-certs-pem",str(apk)],"APKSIGNER"))
    if actual != signer:
        raise PublicHold("PUBLIC_CERTIFICATE_MISMATCH")
    code, name, sdk = parse_badging(run_checked([aapt,"dump","badging",str(apk)],"AAPT"))
    h=hashlib.sha256()
    with apk.open("rb") as f:
        while chunk := f.read(1024*1024):
            h.update(chunk)
    record={
        "schema":"public-independent-apk-v1",
        "source_head":expected_head,
        "application_id":PUBLIC_ID,
        "version_code":code,
        "version_name":name,
        "min_sdk":sdk,
        "signer_certificate_sha256":actual,
        "apk_sha256":h.hexdigest(),
        "overwrites_private_app":False,
    }
    manifest.write_text(json.dumps(record, sort_keys=True, indent=2)+"\n",encoding="utf-8")
    if json.loads(manifest.read_text(encoding="utf-8")) != record:
        raise PublicHold("PROVENANCE_READBACK_MISMATCH")
    print("PUBLIC_APK_IDENTITY_SIGNER_PASS")
    print("APK_SHA256="+record["apk_sha256"])
    return record

def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    for key in ("apksigner","aapt","expected-signer","expected-head"):
        p.add_argument("--"+key)
    p.add_argument("--check-source",type=Path)
    p.add_argument("--apk",type=Path)
    p.add_argument("--manifest-out",type=Path)
    a=p.parse_args()
    try:
        if a.check_source:
            if any(x is not None for x in (a.apk,a.apksigner,a.aapt,a.expected_signer,a.expected_head,a.manifest_out)):
                raise PublicHold("MIXED_MODES")
            check_source(a.check_source.read_text(encoding="utf-8"))
            print("PUBLIC_SOURCE_APP_ID_PASS")
        else:
            if any(x is None for x in (a.apk,a.apksigner,a.aapt,a.expected_signer,a.expected_head,a.manifest_out)):
                raise PublicHold("REQUIRED_ARGS_MISSING")
            verify(a.apk,a.apksigner,a.aapt,a.expected_signer,a.expected_head,a.manifest_out)
    except (PublicHold, OSError, UnicodeError) as exc:
        msg=str(exc) if isinstance(exc,PublicHold) else "FILE_IO_ERROR"
        print("PUBLIC_APK_HOLD:"+msg,file=sys.stderr)
        return 1
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
