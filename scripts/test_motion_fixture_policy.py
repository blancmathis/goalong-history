#!/usr/bin/env python3
"""Exercise the actual CI restoration function with a stub, never macOS defaults."""
import os
from pathlib import Path
import subprocess
import unittest

class MotionPreferenceFixtureTests(unittest.TestCase):
    def invoke(self, original):
        source = (Path(__file__).resolve().parents[1] / '.github/workflows/motion-integration.yml').read_text()
        function = source[source.index('          restore_preference() {'):source.index('          trap restore_preference EXIT')]
        return subprocess.run(['bash', '-c', 'defaults() { printf "%s\\n" "$*"; }\n' + function + '\nrestore_preference'],
                              env={**os.environ, 'original': original}, text=True, capture_output=True)
    def test_numeric_and_text_booleans_are_restored_without_type_error(self):
        for original, expected in [('0', 'false'), ('1', 'true'), ('false', 'false'), ('true', 'true'), ('YES', 'true'), ('NO', 'false')]:
            result = self.invoke(original)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), 'write com.apple.universalaccess reduceMotion -bool ' + expected)
    def test_absent_preference_is_removed_not_set(self):
        result = self.invoke('')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'delete com.apple.universalaccess reduceMotion')
    def test_unexpected_value_is_not_overwritten(self):
        result = self.invoke('not-a-boolean')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

if __name__ == '__main__': unittest.main()
