"""Independent Public app and signer fail-closed contract; no JKS/real APK."""
import base64
import hashlib
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from verify_public_apk_identity import (
    PUBLIC_ID, PRIVATE_ID, PRIVATE_SIGNER, PublicHold,
    check_source, check_signer, parse_badging, parse_certificate,
)
BASE=("package: name='com.example.meeting_recorder.public' "
      "versionCode='1' versionName='1.0.0'\nsdkVersion:'21'\n")
class PublicIdentityTests(unittest.TestCase):
    def test_distinct_app_and_valid_source(self):
        self.assertNotEqual(PUBLIC_ID,PRIVATE_ID)
        check_source('applicationId = "com.example.meeting_recorder.public"')
        self.assertEqual(parse_badging(BASE),("1","1.0.0","21"))
    def test_private_package_and_duplicate_ids_rejected(self):
        for s in ('applicationId = "com.example.meeting_recorder"',
                  'applicationId = "'+PUBLIC_ID+'"\napplicationId = "'+PUBLIC_ID+'"',
                  ""):
            with self.subTest(s=s),self.assertRaises(PublicHold):
                check_source(s)
        with self.assertRaisesRegex(PublicHold,"PRIVATE_APP_OVERWRITE"):
            parse_badging(BASE.replace(PUBLIC_ID,PRIVATE_ID))
    def test_badging_sdk_version_or_record_tamper(self):
        for bad in (BASE.replace("sdkVersion:'21'","sdkVersion:'24'"),
                    BASE.replace("versionCode='1'","versionCode='0'"),
                    BASE+BASE,BASE.replace("sdkVersion:'21'","")):
            with self.subTest(bad=bad),self.assertRaises(PublicHold):
                parse_badging(bad)
    def test_unpinned_and_private_signer_rejected(self):
        for bad in ("","A"*63,"a"*64,PRIVATE_SIGNER):
            with self.subTest(bad=bad),self.assertRaises(PublicHold):
                check_signer(bad)
        check_signer("A"*64)
    def test_pem_der_digest_and_multisigner_guard(self):
        der=b"\x30\x07synthetic-only-certificate"
        payload=base64.b64encode(der).decode()
        log="Signer #1 certificate DN: CN=test\n-----BEGIN CERTIFICATE-----\n"+payload+"\n-----END CERTIFICATE-----"
        self.assertEqual(parse_certificate(log),hashlib.sha256(der).hexdigest().upper())
        with self.assertRaisesRegex(PublicHold,"COUNT"):
            parse_certificate(log+"\n"+log)
        with self.assertRaisesRegex(PublicHold,"MULTIPLE"):
            parse_certificate(log.replace("Signer #1","Signer #2"))
if __name__=="__main__":
    unittest.main()
