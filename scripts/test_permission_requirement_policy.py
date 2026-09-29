#!/usr/bin/env python3
import unittest
from permission_requirement_policy import fingerprint, verify, COMPONENTS

class RequirementPolicyTests(unittest.TestCase):
    requirement = 'identifier "ai.goalong.localhistory" and anchor apple generic and certificate leaf[subject.CN] = "Publisher Name"'
    def pins(self):
        return {"schema": 1, "requirementsSHA256": {name: fingerprint(self.requirement) for name in COMPONENTS}}
    def test_whitespace_and_comments_do_not_rotate_identity(self):
        verify("app", self.requirement.replace(" and ", "\n and  ") + " /* rendering only */", self.pins())
    def test_quoted_identity_is_not_normalized(self):
        with self.assertRaises(ValueError):
            verify("app", self.requirement.replace("Publisher Name", "Publisher  Name"), self.pins())
    def test_weakened_changed_and_hash_pinned_requirements_are_rejected(self):
        for dr in ['identifier "ai.goalong.localhistory"', self.requirement + ' or true', 'cdhash H"abcd"', self.requirement.replace('Publisher Name','Another Publisher')]:
            with self.assertRaises(ValueError): verify("app", dr, self.pins())
    def test_missing_component_policy_is_rejected(self):
        pins=self.pins(); del pins['requirementsSHA256']['relauncher']
        with self.assertRaises(ValueError): verify("app", self.requirement, pins)
    def test_empty_oversized_unknown_component_rejected(self):
        for dr in ['', 'x'*16385]:
            with self.assertRaises(ValueError): fingerprint(dr)
        with self.assertRaises(ValueError): verify('unknown', self.requirement, self.pins())

if __name__ == '__main__': unittest.main()
