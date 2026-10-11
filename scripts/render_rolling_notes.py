#!/usr/bin/env python3
"""Render the latest-main release notes (one text for the fast path and the fallback)."""
from pathlib import Path
import sys

version, build, commit, target = sys.argv[1:]
template = (Path(__file__).resolve().parents[1] / 'Distribution/rolling-release-notes.md').read_text()
Path(target).write_text(template.replace('{version}', version).replace('{build}', build).replace('{commit}', commit))
