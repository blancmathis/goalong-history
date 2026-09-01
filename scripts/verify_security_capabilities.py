#!/usr/bin/env python3
"""Fail closed when a generated build-capability manifest contradicts its app."""

from __future__ import annotations

import argparse
import json
import plistlib
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"Security capability verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--edition", required=True, choices=("unified",))
    args = parser.parse_args()

    value = json.loads(args.manifest.read_text(encoding="utf-8"))
    with (args.app / "Contents" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if value.get("schemaVersion") != 1:
        fail("unsupported schemaVersion")
    if value.get("product", {}).get("edition") != args.edition:
        fail("manifest edition does not match the requested edition")
    if info.get("GoalongBuildEdition") != args.edition:
        fail("Info.plist edition does not match the requested edition")
    if value.get("product", {}).get("bundleIdentifier") != info.get("CFBundleIdentifier"):
        fail("bundle identifier mismatch")
    if not value.get("codeObjects"):
        fail("no signed executable inventory")
    if any(not item.get("sha256") for item in value["codeObjects"]):
        fail("an executable has no SHA-256 digest")

    expected_absent = ("firstPartyNetworkTransport", "automaticUpdater")
    for capability in expected_absent:
        if value.get("capabilities", {}).get(capability) != "absent":
            fail(f"single-app capability is not absent: {capability}")
    if value.get("capabilities", {}).get("singlePublicApplication") != "present":
        fail("single public application invariant is missing")
    if value.get("capabilities", {}).get("defaultCapabilityState") != "all-off":
        fail("new-install capability defaults are not all off")
    if value.get("capabilities", {}).get("managedChatGPTBridge") != "explicit-consent-only":
        fail("Codex bridge consent state is not explicit")
    if value.get("capabilities", {}).get("processExecution") != "fixed-codex-app-server-only":
        fail("process execution is broader than the fixed Codex bridge")
    if value.get("bundle", {}).get("frameworks"):
        fail("single app embeds a framework")
    if value.get("bundle", {}).get("appGroups"):
        fail("single app contains an app-group channel")
    mach_services = value.get("bundle", {}).get("machServices", {})
    if mach_services.get("lookup") or mach_services.get("register"):
        fail("single app contains a Mach-service exception")
    if value.get("bundle", {}).get("xpcServices"):
        fail("single app unexpectedly embeds an XPC service")
    if value.get("forbiddenLocalEntitlementsPresent"):
        fail("single app contains a forbidden entitlement")
    markers = value.get("detectedBinaryMarkers", {})
    if not markers.get("codexAppServer") or not markers.get("managedOAuth"):
        fail("explicit-consent Codex bridge markers are missing")
    if markers.get("commitmentUploader") or markers.get("sparkleUpdater"):
        fail("first-party network or updater marker is present")
    if value.get("bundle", {}).get("infoPlistNetworkAndUpdateKeys"):
        fail("single app contains an update or network Info.plist key")
    if value.get("network", {}).get("osEnforcedDeny") is not False:
        fail("network sandbox state is not reported honestly")
    if value.get("ipc", {}).get("authenticatedSensitiveReader") != "not-shipped":
        fail("reader isolation state is not reported honestly")
    defaults = value.get("dataAccess", {}).get("newInstallDefaults", {})
    if not defaults or any(defaults.values()):
        fail("new-install capability defaults are not all false")
    expected_ipc = {
            "protocolVersion": "goalong-readonly-unix-v1",
            "transport": "unix-domain-socket",
            "authentication": "same-user-filesystem-permissions",
            "runtimeDirectoryMode": "0700",
            "socketMode": "0600",
            "commands": ["screen-time"],
            "maximumRequestBytes": 4 * 1024,
            "maximumResponseBytes": 64 * 1024 * 1024,
            "persistsResponses": False,
    }
    for field, expected in expected_ipc.items():
        if value.get("ipc", {}).get(field) != expected:
            fail(f"read-only IPC manifest mismatch: {field}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
