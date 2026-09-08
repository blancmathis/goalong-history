#!/usr/bin/env python3
"""Negative guards for the explicit website transport and build capability inventory."""
import contextlib
import copy
import io
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import audit_site_submission as boundary
import generate_security_artifacts as generator
import verify_security_capabilities as verifier

ROOT = Path(__file__).resolve().parent.parent
FILES = [
    "Sources/LocalHistoryQueryCLI/GoalongSiteSubmission.swift",
    "Sources/LocalHistoryQueryCLI/GoalongSiteExport.swift",
    "Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift",
    "Sources/LocalHistoryQueryCLI/GoalongCLIContract.swift",
    "Sources/LocalHistoryApp/GoalongWebsiteConnectionCard.swift",
]


class WebsiteBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="goalong-site-policy-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for relative in FILES:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text((ROOT / relative).read_text())

    def change(self, relative, before, after):
        path = self.root / relative
        self.assertIn(before, path.read_text())
        path.write_text(path.read_text().replace(before, after))

    def test_reviewed_boundary_passes(self):
        self.assertEqual(boundary.audit(self.root), [])

    def test_passive_caller_is_rejected(self):
        (self.root / "Sources/Passive.swift").write_text("func refresh() { GoalongSiteSubmission.send(payload: data, origin: origin, tokenFile: token) }")
        self.assertTrue(boundary.audit(self.root))

    def test_native_lifecycle_send_is_rejected(self):
        self.change(FILES[4], '.onChange(of: origin) { _ in status = nil }', '.onChange(of: origin) { _ in sendReviewedData() }')
        self.assertTrue(boundary.audit(self.root))

    def test_redirect_permission_change_is_rejected(self):
        self.change(FILES[0], 'completionHandler(nil)', 'completionHandler(request)')
        self.assertTrue(boundary.audit(self.root))

    def test_raw_body_field_is_rejected(self):
        self.change(FILES[1], '"outcomes": [], "activities": []', '"outcomes": [], "activities": [], "messages": []')
        self.assertTrue(boundary.audit(self.root))

    def test_offline_export_transport_is_rejected(self):
        with (self.root / FILES[1]).open("a") as stream:
            stream.write("\nlet unsafe = URLSession.shared\n")
        self.assertTrue(boundary.audit(self.root))

    def test_ambient_extra_transport_is_rejected(self):
        with (self.root / FILES[0]).open("a") as stream:
            stream.write("\nlet unsafe = URLSession.shared\n")
        self.assertTrue(boundary.audit(self.root))


class CapabilityManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="goalong-site-manifest-")
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Synthetic.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = {"GoalongBuildEdition": "unified", "CFBundleIdentifier": "example.synthetic",
                     "CFBundleDisplayName": "Synthetic", "CFBundleShortVersionString": "0", "CFBundleVersion": "0"}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        markers = {"codexAppServer": True, "managedOAuth": True, "siteSubmission": True,
                   "commitmentUploader": False, "sparkleUpdater": False}
        with patch.object(generator, "inspect_code", return_value=([{"sha256": "synthetic"}], markers)), \
             patch.object(generator, "parse_codesign_metadata", return_value={}):
            self.value = generator.capability_manifest(self.app, "unified", ROOT)

    def fails(self, mutate):
        value = copy.deepcopy(self.value)
        mutate(value)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            verifier.verify_manifest(value, self.info, "unified")

    def test_current_generated_contract_passes(self):
        self.assertEqual(verifier.verify_manifest(self.value, self.info, "unified"), 0)
        self.assertIn("explicit-selected-website-import", [v["purpose"] for v in self.value["network"]["declaredDestinations"]])

    def test_stale_absent_transport_claim_is_rejected(self):
        self.fails(lambda value: value["capabilities"].update(firstPartyNetworkTransport="absent"))

    def test_every_submission_limit_is_checked(self):
        for key in self.value["network"]["siteSubmission"]:
            with self.subTest(field=key):
                self.fails(lambda value: value["network"]["siteSubmission"].pop(key))

    def test_passive_sync_raw_body_and_verified_claim_are_rejected(self):
        for key, replacement in [("automaticSync", True), ("rawConversationBodies", True), ("verification", "verified"),
                                 ("redirects", "allowed"), ("sharing", "always-private")]:
            with self.subTest(field=key):
                self.fails(lambda value: value["network"]["siteSubmission"].update({key: replacement}))

    def test_missing_sender_and_retired_transport_are_rejected(self):
        self.fails(lambda value: value["detectedBinaryMarkers"].update(siteSubmission=False))
        self.fails(lambda value: value["detectedBinaryMarkers"].update(commitmentUploader=True))
        self.fails(lambda value: value["detectedBinaryMarkers"].update(sparkleUpdater=True))
        self.fails(lambda value: value["network"]["declaredDestinations"].append({"purpose": "passive-upload"}))
        self.fails(lambda value: value["dataAccess"]["newInstallDefaults"].update(websiteSubmission=True))

    def test_new_sender_marker_is_distinct_from_retired_transport(self):
        self.assertNotEqual(generator.TRANSPORT_MARKERS["siteSubmission"], generator.TRANSPORT_MARKERS["commitmentUploader"])
        self.assertNotIn(b"URLSessionConfiguration.ephemeral", [generator.TRANSPORT_MARKERS["commitmentUploader"]])


class CodeSignatureMetadataTests(unittest.TestCase):
    def metadata(self, requirement_stdout=b"", requirement_stderr=b"", returncode=0):
        responses = [
            subprocess.CompletedProcess([], 0, b"", b"Identifier=example.synthetic\n"),
            subprocess.CompletedProcess([], returncode, requirement_stdout, requirement_stderr),
            subprocess.CompletedProcess([], 0, b"", b""),
        ]
        with patch.object(generator, "run", side_effect=responses):
            return generator.parse_codesign_metadata(Path("/fixture/Synthetic.app"))

    def test_requirement_stdout_is_separate_from_executable_diagnostic(self):
        value = self.metadata(b'designated => identifier "example.synthetic" and anchor apple generic\n',
                              b"Executable=/fixture/Synthetic.app/Contents/MacOS/Synthetic\n")
        self.assertEqual(value["designatedRequirement"], 'identifier "example.synthetic" and anchor apple generic')

    def test_explicit_requirement_on_stderr_is_supported(self):
        value = self.metadata(requirement_stderr=b'Executable=/fixture/Synthetic\ndesignated => identifier "example.synthetic"\n')
        self.assertEqual(value["designatedRequirement"], 'identifier "example.synthetic"')

    def test_executable_path_is_never_reported_as_requirement(self):
        value = self.metadata(requirement_stderr=b"Executable=/fixture/Synthetic\n")
        self.assertIsNone(value["designatedRequirement"])

    def test_failed_inspection_cannot_report_a_requirement(self):
        value = self.metadata(b'designated => identifier "example.synthetic"\n', returncode=1)
        self.assertIsNone(value["designatedRequirement"])


if __name__ == "__main__":
    unittest.main()
