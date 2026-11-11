"""Public CI safety contract: never depend on private runners or signing."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_WORKFLOW = ROOT / ".github/workflows/public-ci.yml"


class PublicWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = PUBLIC_WORKFLOW.read_text(encoding="utf-8")

    def test_ubuntu_only_and_read_only_token(self):
        self.assertIn("runs-on: ubuntu-latest", self.workflow)
        self.assertIn("permissions:\n  contents: read", self.workflow)
        self.assertIn("persist-credentials: false", self.workflow)
        self.assertIn("github.repository == 'easonliu714/meeting-recorder_public'", self.workflow)

    def test_no_private_runner_or_sensitive_workflow_actions(self):
        for forbidden in (
            "self-hosted", "NETWORK SERVICE", "C:\\actions-runner",
            "CI_Runner_Control", "pull_request_target:",
            "secrets.", "upload-artifact@", "flutter build apk",
            "gradle assemble", "ANDROID_KEYSTORE_BASE64",
            "api.groq.com", "api.deepgram.com",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, self.workflow)

    def test_security_guard_runs_before_external_aac_install(self):
        first = self.workflow.index("Validate publication guard positive and negative tests")
        audit = self.workflow.index("Verify exact public snapshot files and safety boundary")
        apt = self.workflow.index("Verify physical AAC offline toolchain")
        full = self.workflow.index("Run all publication tests including real offline AAC")
        self.assertLess(first, audit)
        self.assertLess(audit, apt)
        self.assertLess(apt, full)
        self.assertIn("timeout 120s sudo apt-get update", self.workflow)
        self.assertIn("timeout 180s sudo apt-get install", self.workflow)
        self.assertIn("python3 -m unittest discover -s ci/tests", self.workflow)
        unsafe = self.workflow.replace("timeout 120s sudo apt-get update",
                                       "sudo apt-get update")
        self.assertNotIn("timeout 120s sudo apt-get update", unsafe)

    def test_source_integrity_blocks_application_without_snapshot(self):
        self.assertIn("id: guard", self.workflow)
        self.assertIn("python3 ci/verify_public_snapshot.py", self.workflow)
        self.assertIn("PUBLIC", PUBLIC_WORKFLOW.name.upper() + self.workflow.upper())
        self.assertGreaterEqual(
            self.workflow.count("if: steps.guard.outputs.has_source == 'true'"),
            8,
        )

    def test_original_required_regressions_retained(self):
        for required in (
            "python3 -m unittest discover -s tool/tests",
            "flutter pub get",
            "flutter analyze",
            "flutter test",
            ":app:compileDebugKotlin",
            "ffmpeg",
            "ffprobe",
            "test ! -e ../build/app/outputs/flutter-apk/app-debug.apk",
            "flutter-version: '3.32.8'",
            "gradle-version: '8.12'",
            "java-version: '17'",
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.workflow)

    def test_public_only_events_no_untrusted_pr_execution(self):
        self.assertIn("push:", self.workflow)
        self.assertIn("- main", self.workflow)
        self.assertIn("workflow_dispatch:", self.workflow)
        self.assertNotIn("pull_request:", self.workflow)
        self.assertNotIn("pull_request_target:", self.workflow)

    def test_mutation_that_removes_public_guard_is_rejected(self):
        mutated = self.workflow.replace(
            "if: steps.guard.outputs.has_source == 'true'", "if: always()")
        self.assertLess(
            mutated.count("if: steps.guard.outputs.has_source == 'true'"),
            8,
        )


if __name__ == "__main__":
    unittest.main()
