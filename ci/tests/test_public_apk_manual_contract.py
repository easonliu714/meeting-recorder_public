"""Public APK manual signing must fail closed before any secret use."""
from pathlib import Path
import unittest
WF = Path(__file__).resolve().parents[2] / ".github/workflows/public-apk-manual.yml"
class ManualApkGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = WF.read_text(encoding="utf-8")
    def test_no_automatic_or_pr_signing_and_exact_main_only(self):
        for forbidden in ("  push:", "  pull_request:", "pull_request_target:", "self-hosted"):
            self.assertNotIn(forbidden, self.s)
        for required in ("  workflow_dispatch:", "github.ref == 'refs/heads/main'",
                         "github.repository == 'easonliu714/meeting-recorder_public'",
                         "persist-credentials: false", "APPROVED_HEAD", "GITHUB_SHA"):
            self.assertIn(required, self.s)
    def test_complete_source_and_test_gate_before_secrets(self):
        for required in ("PUBLIC_EXPORT_SOURCE_INTEGRITY_READY", "needs: source-gate",
                         "vars.PUBLIC_APK_SIGNING_ARMED == 'true'",
                         "name: android-stable-signing", "flutter test", "flutter analyze",
                         ":app:compileDebugKotlin", "unittest discover -s ci/tests",
                         "unittest discover -s tool/tests"):
            self.assertIn(required, self.s)
        self.assertLess(self.s.index("name: Full Flutter regressions"),
                        self.s.index("name: Restore Owner signer"))
    def test_original_signer_attestation_before_artifact(self):
        for required in ("secrets.ANDROID_KEYSTORE_BASE64", "secrets.ANDROID_KEYSTORE_PASSWORD",
                         "secrets.ANDROID_KEY_ALIAS", "secrets.ANDROID_KEY_PASSWORD",
                         "211EBB33C98359E8F49F0423231826DF22B04643BE418754C939ECB2FFC1435D",
                         "tool/verify_signed_android_apk.py", "--expected-head", "--manifest-out",
                         "retention-days: 5", "retention-days: 30",
                         "Remove temporary signing key", "OWNER_SIGNING_CERT_MISMATCH"):
            self.assertIn(required, self.s)
        self.assertLess(self.s.index("name: Verify APK certificate"),
                        self.s.index("name: Upload debug APK"))
    def test_remove_signing_arm_rule_is_a_contract_regression(self):
        modified = self.s.replace("vars.PUBLIC_APK_SIGNING_ARMED == 'true'", "true")
        self.assertNotIn("vars.PUBLIC_APK_SIGNING_ARMED == 'true'", modified)
        self.assertIn("vars.PUBLIC_APK_SIGNING_ARMED == 'true'", self.s)
if __name__ == "__main__":
    unittest.main()
