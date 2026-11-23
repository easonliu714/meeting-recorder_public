#!/usr/bin/env python3
"""Lab APK version provenance: prevent repeat of Owner v22 T01 HOLD."""
from pathlib import Path
import unittest

LAB = Path(__file__).resolve().parents[1]
REPO = LAB.parents[1]
WORKFLOW = (REPO / ".github/workflows/public-groq-lab-v021-debug-apk.yml")

def identity_is_consistent(workflow: str, pubspec: str, debug: str) -> bool:
    return all((
        'version: 0.4.34+39' in pubspec,
        "versionName = '0.4.34'" in debug,
        'versionCode = 39' in debug,
        'public_lab_v39.groq_stt_lab' in debug,
        'echo "VERSION=0.4.34+39"' in workflow,
        '--build-name=0.4.34 --build-number=39' in workflow,
        "versionName='0.4.34'" in workflow,
        "versionCode='39'" in workflow,
        'public_lab_v39.groq_stt_lab' in workflow,
        'groq-stt-lab-v0.4.34+39-public-debug.apk' in workflow,
    ))

class BuildIdentityParityTests(unittest.TestCase):
    def test_source_ui_provenance_and_artifact_version_parity(self):
        self.assertTrue(identity_is_consistent(
            WORKFLOW.read_text(encoding='utf8'),
            (LAB / 'pubspec.yaml').read_text(encoding='utf8'),
            (LAB / 'lib/lab_debug_log.dart').read_text(encoding='utf8')))

    def test_bootstrap_native_package_matches_current_identity(self):
        bootstrap = (LAB / 'tool/bootstrap.sh').read_text(encoding='utf8')
        from verify_android_identity import EXPECTED_PACKAGE
        organization = EXPECTED_PACKAGE.rsplit('.', 1)[0]
        package_path = EXPECTED_PACKAGE.replace('.', '/')
        self.assertIn('--org=' + organization, bootstrap)
        self.assertIn('android/app/src/main/kotlin/' + package_path, bootstrap)
        self.assertNotIn('public_lab_v25', bootstrap)
        self.assertIn('v0.4.34+39', bootstrap)

    def test_stale_provenance_fails_closed(self):
        workflow = WORKFLOW.read_text(encoding='utf8')
        pubspec = (LAB / 'pubspec.yaml').read_text(encoding='utf8')
        debug = (LAB / 'lib/lab_debug_log.dart').read_text(encoding='utf8')
        self.assertFalse(identity_is_consistent(
            workflow.replace('echo "VERSION=0.4.34+39"',
                             'echo "VERSION=0.4.17+22"'),
            pubspec, debug))
        self.assertFalse(identity_is_consistent(
            workflow, pubspec,
            debug.replace("versionCode = 39", "versionCode = 21")))

if __name__ == '__main__':
    unittest.main()
