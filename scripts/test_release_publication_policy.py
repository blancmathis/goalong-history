#!/usr/bin/env python3
import unittest
from release_publication_policy import validate_staging_run

SHA = 'a' * 40
class PublicationPolicyTests(unittest.TestCase):
    def run_info(self):
        return dict(conclusion='success', headSha=SHA, headBranch='main',
                    workflowName='Prepare universal archive for local signing')
    def test_exact_tested_commit_can_be_promoted_without_recompilation(self):
        r = self.run_info()
        validate_staging_run(r, SHA)
        r['headBranch'] = 'release-candidate'
        validate_staging_run(r, SHA)
    def test_main_branch_name_cannot_authorize_a_stale_commit(self):
        r = self.run_info(); r['headSha'] = 'b' * 40
        with self.assertRaises(ValueError): validate_staging_run(r, SHA)
    def test_failed_or_running_or_cancelled_builds_are_rejected(self):
        for value in [None, '', 'failure', 'cancelled', 'skipped']:
            r = self.run_info(); r['conclusion'] = value
            with self.assertRaises(ValueError): validate_staging_run(r, SHA)
    def test_unrelated_workflow_cannot_produce_a_release_input(self):
        r = self.run_info(); r['workflowName'] = 'macOS quality gate'
        with self.assertRaises(ValueError): validate_staging_run(r, SHA)
    def test_short_or_invalid_revision_is_rejected(self):
        for value in ['aaaaaaa', 'A'*40, '../main', 'main']:
            with self.assertRaises(ValueError): validate_staging_run(self.run_info(), value)
if __name__ == '__main__': unittest.main()
