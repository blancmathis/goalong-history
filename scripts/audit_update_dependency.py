#!/usr/bin/env python3
"""Reject extra/unpinned dependencies and a return of the no-op updater."""
from pathlib import Path
import json
import re
from update_policy import SPARKLE_VERSION, FEED_URL
root = Path(__file__).resolve().parent.parent
package = (root / "Package.swift").read_text()
dependencies = re.findall(r"\.package\s*\(([^)]*)\)", package)
expected = f'url: "https://github.com/sparkle-project/Sparkle", exact: "{SPARKLE_VERSION}"'
assert dependencies == [expected], "Only exact-pinned Sparkle is reviewed"
excludes = re.search(r"let appExcludes[^=]*=\s*\[([\s\S]*?)\]", package).group(1)
assert '"LocalOnlySoftwareUpdateManager.swift"' in excludes
assert '"SoftwareUpdateManager.swift"' not in excludes
assert FEED_URL in (root / "Sources/LocalHistoryApp/SoftwareUpdateManager.swift").read_text()
resolved = root / "Package.resolved"
if resolved.exists():
    pins = json.loads(resolved.read_text()).get("pins", [])
    assert len(pins) == 1 and pins[0]["identity"] == "sparkle"
    assert pins[0]["state"]["version"] == SPARKLE_VERSION
    assert pins[0]["state"]["revision"] == "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a"
    assert pins[0]["location"] == "https://github.com/sparkle-project/Sparkle"
print("Update dependency audit passed: one exact-pinned Sparkle package; real updater compiled.")
