#!/usr/bin/env python3
"""Regression tests for signed updates, privacy controls and release ordering."""
import base64
import copy
import os
import re
from pathlib import Path
import subprocess
import unittest
from update_policy import SETTINGS, FEED_URL, validate_info, manifest_policy

ROOT = Path(__file__).resolve().parent.parent

class UpdatePolicyTests(unittest.TestCase):
    def configured(self):
        return dict(SETTINGS, SUPublicEDKey=base64.b64encode(bytes(range(32))).decode())

    def test_configured_release_and_disabled_source_build(self):
        self.assertTrue(validate_info(self.configured(), require_configured=True))
        self.assertFalse(validate_info({}))
        with self.assertRaises(ValueError):
            validate_info({}, require_configured=True)
        self.assertFalse(manifest_policy({})['automaticChecksDefault'])
        self.assertTrue(manifest_policy(self.configured())['automaticChecksDefault'])

    def test_every_security_setting_is_required_and_exact(self):
        for key in self.configured():
            info = self.configured()
            del info[key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_info(info)
        for key in SETTINGS:
            info = self.configured()
            info[key] = 'unsafe-value'
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_info(info)

    def test_malicious_feed_profiles_unsigned_installs_and_extra_keys_are_rejected(self):
        for patch in [
            {'SUFeedURL': 'https://example.com/feed.xml'},
            {'SUFeedURL': FEED_URL + '?activity=private'},
            {'SURequireSignedFeed': False},
            {'SUVerifyUpdateBeforeExtraction': False},
            {'SUAllowsAutomaticUpdates': True},
            {'SUEnableSystemProfiling': True},
            {'SUSendProfileInfo': True},
            {'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True}},
            {'SUPublicEDKey': 'not-a-key'},
        ]:
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                validate_info(dict(self.configured(), **patch))

    def test_numeric_boolean_cannot_disable_strict_validation(self):
        with self.assertRaises(ValueError):
            validate_info(dict(self.configured(), SURequireSignedFeed=1))

    def test_rolling_version_upgrades_date_numbered_installs_and_retries(self):
        def resolve(run, attempt=1):
            env = dict(os.environ, GOALONG_CURRENT_ROLLING_VERSION='0.6.0',
                       GOALONG_VERSION_FLOOR='0.6.0', GITHUB_RUN_ATTEMPT=str(attempt), GITHUB_RUN_ID=str(run))
            result = subprocess.check_output(['bash', str(ROOT / 'scripts/resolve_rolling_version.sh'), str(run)], env=env, text=True)
            output = dict(line.split('=', 1) for line in result.strip().splitlines())
            self.assertEqual(output['value'], '0.6.1')
            return tuple(map(int, output['build'].split('.')))
        build = resolve(67)
        self.assertGreater(build, (20260912, 4))
        self.assertGreater(build, (5000, 0, 99))
        self.assertGreater(resolve(67, 2), build)
        self.assertGreater(resolve(68), resolve(67, 2))

    def test_release_does_not_expose_feed_before_immutable_archive(self):
        workflow = (ROOT / '.github/workflows/continuous-release.yml').read_text()
        self.assertIn('cancel-in-progress: false', workflow)
        self.assertLess(workflow.index('Publish immutable update archive'), workflow.index('Publish authenticated feed last'))
        self.assertIn('dist/community-appcast.xml "$IMMUTABLE_TAG"', workflow)
        self.assertIn('LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED: 1', workflow)
        self.assertIn('SPARKLE_PRIVATE_ED_KEY:', workflow)

    def test_updater_is_started_and_noop_is_not_compiled(self):
        package = (ROOT / 'Package.swift').read_text()
        exclusions = re.search(r"let appExcludes[^=]*=\s*\[([\s\S]*?)\]", package).group(1)
        self.assertIn('"LocalOnlySoftwareUpdateManager.swift"', exclusions)
        self.assertNotIn('"SoftwareUpdateManager.swift"', exclusions)
        delegate = (ROOT / 'Sources/LocalHistoryApp/AppDelegate.swift').read_text()
        self.assertIn('SoftwareUpdateManager.shared.start()', delegate)
        self.assertIn('SoftwareUpdateManager.shared.stop()', delegate)

if __name__ == '__main__':
    unittest.main()
