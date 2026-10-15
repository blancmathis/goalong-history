#!/usr/bin/env python3
import unittest
from deferred_release_deltas import select_delta_bases


class DeltaBaseSelectionTests(unittest.TestCase):
    def test_orphan_without_public_receipt_is_excluded(self):
        tags = ["main-9-1", "main-8-1", "main-7-1", "main-6-1", "main-5-1"]
        published = {"main-8-1", "main-7-1", "main-6-1", "main-5-1"}
        self.assertEqual(select_delta_bases(tags, published.__contains__), ["main-8-1", "main-7-1", "main-6-1"])

    def test_at_most_three_bases_and_fewer_when_few_are_published(self):
        self.assertEqual(select_delta_bases(["a", "b", "c", "d"], lambda t: True), ["a", "b", "c"])
        self.assertEqual(select_delta_bases(["a", "b"], lambda t: t == "b"), ["b"])


if __name__ == "__main__":
    unittest.main()
