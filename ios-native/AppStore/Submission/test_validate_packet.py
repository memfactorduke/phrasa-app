#!/usr/bin/env python3
"""Automated tests for the three-phase App Store packet validator.

Covers:
  - all three modes PASS on the real submitted build-14 evidence
  - success fixtures for release-ready and submission-ready (temp copies)
  - wrong-value failures for new gates (name, tax category, build, slots, etc.)

Run from this directory:
  python3 -m unittest test_validate_packet.py -v
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
IOS_NATIVE = ROOT.parent.parent  # ios-native/
VALIDATOR = ROOT / "validate_packet.py"


def run_mode(mode: str, root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(VALIDATOR), "--mode", mode, "--root", str(root)],
        capture_output=True,
        text=True,
        check=False,
    )


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class RealTemplateTests(unittest.TestCase):
    """Repository packet — honest current state."""

    def test_packet_mode_passes(self) -> None:
        proc = run_mode("packet", ROOT)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("RESULT: PASS [packet mode]", proc.stdout)

    def test_release_ready_passes_after_explicit_archive_authorization(self) -> None:
        proc = run_mode("release-ready", ROOT)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("RESULT: PASS [release-ready mode]", proc.stdout)
        self.assertIn("RELEASE-READY: voice gate status = passed", proc.stdout)
        self.assertIn("RELEASE-READY: ready_to_archive = true", proc.stdout)
        # Must not demand Connect screenshot/build selection evidence in this phase
        self.assertNotIn("SUBMISSION-READY: screenshots", proc.stdout)
        self.assertNotIn("SUBMISSION-READY: build_selection", proc.stdout)

    def test_submission_ready_passes_for_processed_selected_build(self) -> None:
        proc = run_mode("submission-ready", ROOT)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("RESULT: PASS [submission-ready mode]", proc.stdout)
        self.assertIn("SUBMISSION-READY: build processing_state = processed", proc.stdout)
        self.assertIn(
            "SUBMISSION-READY: build_selection.selected_for_version = true",
            proc.stdout,
        )

    def test_final_is_alias_for_submission_ready(self) -> None:
        proc = run_mode("final", ROOT)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("RESULT: PASS [submission-ready mode]", proc.stdout)
        self.assertIn("SUBMISSION-READY: build processing_state = processed", proc.stdout)

    def test_validate_sh_packet(self) -> None:
        proc = subprocess.run(
            ["bash", str(ROOT / "validate.sh"), "--mode", "packet"],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(ROOT),
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


class FixtureBase(unittest.TestCase):
    """Isolated AppStore tree so fixtures never mutate real evidence files."""

    def setUp(self) -> None:
        self._td = tempfile.TemporaryDirectory(prefix="phrasa-packet-")
        self.base = Path(self._td.name)
        # Mirror ios-native layout for relative paths in packet.json
        self.ios = self.base / "ios-native"
        self.sub = self.ios / "AppStore" / "Submission"
        self.shots = self.ios / "AppStore" / "Screenshots"

        shutil.copytree(ROOT, self.sub, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        # Local screenshots sibling
        real_shots = ROOT.parent / "Screenshots"
        shutil.copytree(real_shots, self.shots)

        # Project evidence files (symlinks to real sources)
        for rel in (
            "project.yml",
            "Phrasa/Info.plist",
            "Phrasa/Resources/PrivacyInfo.xcprivacy",
            "Phrasa/Resources/Fonts/OFL.txt",
        ):
            src = IOS_NATIVE / rel
            dst = self.ios / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_file():
                dst.symlink_to(src)

    def tearDown(self) -> None:
        self._td.cleanup()

    def fill_voice_passed(self) -> None:
        text = (self.sub / "voice-gate.yaml").read_text(encoding="utf-8")
        text = text.replace("status: not_passed", "status: passed", 1)
        text = text.replace(
            "    device_model: null\n    ios_version: null\n    tested_on: null\n    notes: null\n",
            "    device_model: iPhone 15 Pro\n"
            "    ios_version: \"18.5\"\n"
            "    tested_on: \"2026-07-18\"\n"
            "    notes: Full mic→speech→alignment path exercised on hardware.\n",
            1,
        )
        write_text(self.sub / "voice-gate.yaml", text)

    def fill_operator_release(self) -> None:
        write_text(
            self.sub / "operator-placeholders.yaml",
            """schema: operator-placeholders-v2
owner_gated: true
app_review_contact:
  connect_current: blank
  first_name: Ada
  last_name: Lovelace
  phone_number: "+1-555-0100"
  email: owner@example.com
copyright:
  holder: Example LLC
  year: "2026"
  display_string: "2026 Example LLC"
dsa_trader_status:
  connect_banner_present: true
  status: non_trader
public_support_channel:
  intended_address: support@phrasa.app
  activated: true
  monitored: true
  verified_at: "2026-07-18"
production_website_redeploy:
  latest_source_redeployed: true
  live_urls_reverified_at: "2026-07-18"
public_name_change:
  intended_name: Phrasa
""",
        )

    def fill_release_prereqs(self, **overrides: object) -> None:
        data = {
            "schema": "release-prerequisites-v1",
            "last_updated": "2026-07-18",
            "candidate": {
                "marketing_version": "1.0",
                "build_number": "14",
                "display": "1.0 (14)",
                "bundle_id": "com.phrasa.app",
                "apple_id": "6780259086",
                "project": "PhrasaNative.xcodeproj",
                "forbid_finder_duplicate_projects": True,
            },
            "signing": {
                "apple_distribution_identity_available": True,
                "provisioning_for_bundle_ready": True,
                "notes": "fixture",
            },
            "upload_path": {
                "method": "api_key",
                "credentials_verified": True,
                "notes": "fixture",
            },
            "ready_to_archive": True,
            "post_release_claims_forbidden_until_later": {
                "archive_completed": False,
                "export_completed": False,
                "upload_completed": False,
                "build_processed_in_connect": False,
                "build_selected_in_connect": False,
            },
        }
        for k, v in overrides.items():
            if k in data and isinstance(data[k], dict) and isinstance(v, dict):
                data[k].update(v)  # type: ignore[arg-type]
            else:
                data[k] = v
        # Write as YAML-ish JSON is not YAML; emit simple YAML
        lines = ["schema: release-prerequisites-v1", 'last_updated: "2026-07-18"']
        lines.append("candidate:")
        for k, v in data["candidate"].items():  # type: ignore[union-attr]
            if isinstance(v, bool):
                lines.append(f"  {k}: {'true' if v else 'false'}")
            elif isinstance(v, str) and not v.replace(".", "").replace("(", "").replace(")", "").isalnum() and " " in v:
                lines.append(f'  {k}: "{v}"')
            else:
                lines.append(f'  {k}: "{v}"' if isinstance(v, str) else f"  {k}: {v}")
        # Fix quoting for simple strings
        lines = ["schema: release-prerequisites-v1", 'last_updated: "2026-07-18"']
        c = data["candidate"]  # type: ignore[assignment]
        lines.append("candidate:")
        lines.append(f'  marketing_version: "{c["marketing_version"]}"')
        lines.append(f'  build_number: "{c["build_number"]}"')
        lines.append(f'  display: "{c["display"]}"')
        lines.append(f"  bundle_id: {c['bundle_id']}")
        lines.append(f'  apple_id: "{c["apple_id"]}"')
        lines.append(f"  project: {c['project']}")
        lines.append(
            f"  forbid_finder_duplicate_projects: {'true' if c['forbid_finder_duplicate_projects'] else 'false'}"
        )
        s = data["signing"]  # type: ignore[assignment]
        lines.append("signing:")
        lines.append(
            f"  apple_distribution_identity_available: {'true' if s['apple_distribution_identity_available'] else 'false'}"
        )
        lines.append(
            f"  provisioning_for_bundle_ready: {'true' if s['provisioning_for_bundle_ready'] else 'false'}"
        )
        lines.append("  notes: fixture")
        u = data["upload_path"]  # type: ignore[assignment]
        lines.append("upload_path:")
        lines.append(f"  method: {u['method']}")
        lines.append(
            f"  credentials_verified: {'true' if u['credentials_verified'] else 'false'}"
        )
        lines.append("  notes: fixture")
        lines.append(
            f"ready_to_archive: {'true' if data['ready_to_archive'] else 'false'}"
        )
        p = data["post_release_claims_forbidden_until_later"]  # type: ignore[assignment]
        lines.append("post_release_claims_forbidden_until_later:")
        for key in p:
            lines.append(f"  {key}: {'true' if p[key] else 'false'}")
        write_text(self.sub / "release-prerequisites.yaml", "\n".join(lines) + "\n")

    def fill_connect_evidence(self, **mutators: object) -> None:
        order = [
            "05-voice-reader.jpg",
            "01-library.jpg",
            "02-editor.jpg",
            "03-speed-reader.jpg",
            "04-onboarding.jpg",
        ]
        files_yaml = "\n".join(f"      - {f}" for f in order)
        body = f"""schema: connect-evidence-v1
owner_gated: true
last_updated: "2026-07-18"
public_app_name:
  saved_value: Phrasa
version_metadata:
  subtitle_saved: true
  promotional_text_saved: true
  description_saved: true
  keywords_saved: true
  support_url_saved: true
  marketing_url_saved: true
  privacy_policy_url_saved: true
  whats_new_omitted: true
privacy:
  questionnaire_completed: true
  published: true
  collects_data_answer: true
  tracks_users_answer: false
  privacy_policy_url: https://phrasa.app/privacy
  expected_data_types:
    - Email Address
    - User ID
    - Other User Content
  purpose: App Functionality
  linked_to_user: true
  used_for_tracking: false
age_rating:
  saved: true
  intended_rating: "4+"
  social_media_capability: no
  social_media_and_ugc_all_no: true
categories:
  primary_saved: Productivity
  secondary_saved: Utilities
content_rights:
  saved: true
  has_rights_to_all_content: true
export_compliance:
  saved: true
  uses_non_exempt_encryption: false
pricing_availability:
  price: free
  tax_category: "App Store software"
  us_availability_saved: true
  territories_include_us: true
screenshots:
  iphone_6_9:
    connect_slot: "iPhone 6.9-inch"
    uploaded_count: 5
    uploaded_files_in_order:
{files_yaml}
    not_uploaded_to_forbidden_slots: true
  ipad_13:
    connect_slot: "iPad 13-inch"
    uploaded_count: 5
    uploaded_files_in_order:
{files_yaml}
    not_uploaded_to_forbidden_slots: true
build_selection:
  marketing_version: "1.0"
  build_number: "14"
  display: "1.0 (14)"
  processing_state: processed
  selected_for_version: true
sign_in_required:
  saved_value: false
release_mode:
  saved_value: manual
apple_silicon_mac:
  availability: disabled
vision_pro:
  compatibility: disabled
app_review:
  contact_first_name: Ada
  contact_last_name: Lovelace
  contact_phone_number: "+1-555-0100"
  contact_email: owner@example.com
  review_notes_saved: true
dsa:
  decision_saved: true
  status: non_trader
social_media_age_rating:
  answer_saved: true
  answer: no
accessibility_labels:
  required: false
  claimed: false
  evidence: null
"""
        # Apply simple string replacements for wrong-value tests
        for needle, replacement in mutators.items():
            if not isinstance(replacement, str):
                raise TypeError(needle)
            if needle not in body:
                raise KeyError(f"mutator key not found in evidence body: {needle}")
            body = body.replace(needle, replacement, 1)
        write_text(self.sub / "connect-evidence.yaml", body)

    def fill_all_for_submission(self) -> None:
        self.fill_voice_passed()
        self.fill_operator_release()
        self.fill_release_prereqs()
        self.fill_connect_evidence()


class ReleaseReadyFixtureTests(FixtureBase):
    def test_release_ready_passes_when_filled(self) -> None:
        self.fill_voice_passed()
        self.fill_operator_release()
        self.fill_release_prereqs()
        proc = run_mode("release-ready", self.sub)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("RESULT: PASS [release-ready mode]", proc.stdout)

    def test_release_ready_fails_wrong_candidate_build(self) -> None:
        self.fill_voice_passed()
        self.fill_operator_release()
        self.fill_release_prereqs(
            candidate={
                "marketing_version": "1.0",
                "build_number": "13",
                "display": "1.0 (13)",
                "bundle_id": "com.phrasa.app",
                "apple_id": "6780259086",
                "project": "PhrasaNative.xcodeproj",
                "forbid_finder_duplicate_projects": True,
            }
        )
        proc = run_mode("release-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("candidate.build_number must be '14'", proc.stdout)

    def test_release_ready_fails_if_upload_claimed_early(self) -> None:
        self.fill_voice_passed()
        self.fill_operator_release()
        self.fill_release_prereqs(
            post_release_claims_forbidden_until_later={
                "archive_completed": False,
                "export_completed": False,
                "upload_completed": True,
                "build_processed_in_connect": False,
                "build_selected_in_connect": False,
            }
        )
        proc = run_mode("release-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("upload_completed must not be true", proc.stdout)

    def test_release_ready_fails_without_voice_evidence_notes(self) -> None:
        # status passed but empty evidence
        text = (self.sub / "voice-gate.yaml").read_text(encoding="utf-8")
        text = text.replace(
            '    device_model: "iPad Air (5th generation; iPad13,16)"',
            "    device_model: null",
            1,
        )
        write_text(self.sub / "voice-gate.yaml", text)
        self.fill_operator_release()
        self.fill_release_prereqs()
        proc = run_mode("release-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("voice-gate evidence.device_model", proc.stdout)

    def test_release_ready_does_not_require_connect_name_evidence(self) -> None:
        self.fill_voice_passed()
        self.fill_operator_release()
        self.fill_release_prereqs()
        # leave connect-evidence null
        proc = run_mode("release-ready", self.sub)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("SUBMISSION-READY: public_app_name", proc.stdout)


class SubmissionReadyFixtureTests(FixtureBase):
    def test_submission_ready_passes_when_filled(self) -> None:
        self.fill_all_for_submission()
        proc = run_mode("submission-ready", self.sub)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("RESULT: PASS [submission-ready mode]", proc.stdout)

    def test_wrong_public_name_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "  saved_value: Phrasa\n",
            '  saved_value: "Phrasa Free Teleprompter Name Is Far Too Long"\n',
            1,
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(
            "public_app_name.saved_value must be an available, owner-selected App Store name",
            proc.stdout,
        )

    def test_wrong_tax_category_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            'tax_category: "App Store software"',
            'tax_category: "Apps"',
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("tax_category must be exactly 'App Store software'", proc.stdout)

    def test_wrong_build_number_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace('build_number: "14"', 'build_number: "13"', 1)
        text = text.replace('display: "1.0 (14)"', 'display: "1.0 (13)"', 1)
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        out = proc.stdout
        self.assertTrue(
            "build_selection.build_number must be '14'" in out
            or "build_selection.display must be '1.0 (14)'" in out,
            out,
        )

    def test_sign_in_still_on_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "sign_in_required:\n  saved_value: false\n",
            "sign_in_required:\n  saved_value: true\n",
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("sign_in_required.saved_value must be false", proc.stdout)

    def test_automatic_release_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "release_mode:\n  saved_value: manual\n",
            "release_mode:\n  saved_value: automatic\n",
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("release_mode.saved_value must be 'manual'", proc.stdout)

    def test_wrong_screenshot_slot_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            'connect_slot: "iPhone 6.9-inch"',
            'connect_slot: "iPhone 6.5-inch"',
            1,
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("connect_slot must be 'iPhone 6.9-inch'", proc.stdout)

    def test_wrong_screenshot_count_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "iphone_6_9:\n    connect_slot: \"iPhone 6.9-inch\"\n    uploaded_count: 5\n",
            "iphone_6_9:\n    connect_slot: \"iPhone 6.9-inch\"\n    uploaded_count: 2\n",
            1,
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("uploaded_count must be 5", proc.stdout)

    def test_mac_not_disabled_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "apple_silicon_mac:\n  availability: disabled\n",
            "apple_silicon_mac:\n  availability: enabled\n",
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("apple_silicon_mac.availability must be 'disabled'", proc.stdout)

    def test_vision_pro_not_disabled_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "vision_pro:\n  compatibility: disabled\n",
            "vision_pro:\n  compatibility: enabled\n",
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("vision_pro.compatibility must be 'disabled'", proc.stdout)

    def test_wrong_social_media_answer_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "social_media_age_rating:\n  answer_saved: true\n  answer: no\n",
            "social_media_age_rating:\n  answer_saved: true\n  answer: yes\n",
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("social_media_age_rating.answer must be 'no'", proc.stdout)

    def test_accessibility_claimed_without_evidence_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "accessibility_labels:\n  required: false\n  claimed: false\n  evidence: null\n",
            "accessibility_labels:\n  required: false\n  claimed: true\n  evidence: null\n",
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("accessibility_labels.claimed is true but evidence is null", proc.stdout)

    def test_wrong_dsa_status_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "dsa:\n  decision_saved: true\n  status: non_trader\n",
            "dsa:\n  decision_saved: true\n  status: maybe\n",
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("dsa.status must be one of", proc.stdout)

    def test_wrong_categories_fail(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "primary_saved: Productivity\n  secondary_saved: Utilities\n",
            "primary_saved: Games\n  secondary_saved: Utilities\n",
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("categories.primary_saved must be 'Productivity'", proc.stdout)

    def test_collects_data_false_fails(self) -> None:
        self.fill_all_for_submission()
        text = (self.sub / "connect-evidence.yaml").read_text(encoding="utf-8")
        text = text.replace(
            "collects_data_answer: true\n",
            "collects_data_answer: false\n",
        )
        write_text(self.sub / "connect-evidence.yaml", text)
        proc = run_mode("submission-ready", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("privacy.collects_data_answer must be true", proc.stdout)


class PacketCorruptionTests(FixtureBase):
    def test_packet_fails_wrong_name_file(self) -> None:
        write_text(self.sub / "en-US" / "name.txt", "Phrasa (bd0543)\n")
        proc = run_mode("packet", self.sub)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(
            "public name file must be exactly 'Phrasa Free Teleprompter'",
            proc.stdout,
        )

    def test_packet_still_passes_with_null_evidence(self) -> None:
        # Default template copy should pass packet without filling evidence
        proc = run_mode("packet", self.sub)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


class YamlParseUnitTests(unittest.TestCase):
    def test_parse_simple_yaml_nested(self) -> None:
        # Import from validator module
        sys.path.insert(0, str(ROOT))
        import validate_packet as vp  # noqa: WPS433

        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
            fh.write(
                "outer:\n  inner: true\n  name: Phrasa\n  count: 5\n  empty: null\nlistish:\n  - a\n  - b\n"
            )
            path = Path(fh.name)
        try:
            data = vp.parse_simple_yaml(path)
            self.assertTrue(data["outer"]["inner"] is True)
            self.assertEqual(data["outer"]["name"], "Phrasa")
            self.assertEqual(data["outer"]["count"], 5)
            self.assertIsNone(data["outer"]["empty"])
            self.assertEqual(data["listish"], ["a", "b"])
        finally:
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
