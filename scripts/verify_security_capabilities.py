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
    return verify_manifest(value, info, args.edition)


def verify_manifest(value: dict, info: dict, edition: str) -> int:
    if value.get("schemaVersion") != 1:
        fail("unsupported schemaVersion")
    if value.get("product", {}).get("edition") != edition:
        fail("manifest edition does not match the requested edition")
    if info.get("GoalongBuildEdition") != edition:
        fail("Info.plist edition does not match the requested edition")
    if value.get("product", {}).get("bundleIdentifier") != info.get("CFBundleIdentifier"):
        fail("bundle identifier mismatch")
    if not value.get("codeObjects"):
        fail("no signed executable inventory")
    if any(not item.get("sha256") for item in value["codeObjects"]):
        fail("an executable has no SHA-256 digest")

    expected_absent = ("automaticUpdater",)
    for capability in expected_absent:
        if value.get("capabilities", {}).get(capability) != "absent":
            fail(f"single-app capability is not absent: {capability}")
    if value.get("capabilities", {}).get("firstPartyNetworkTransport") != "explicit-site-pairing-and-submission-only":
        fail("first-party transport is not confined to explicit website submission")
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
        fail("retired commitment uploader or updater marker is present")
    if markers.get("siteSubmission") is not True:
        fail("explicit website submission marker is missing")
    if value.get("bundle", {}).get("infoPlistNetworkAndUpdateKeys"):
        fail("single app contains an update or network Info.plist key")
    if value.get("network", {}).get("osEnforcedDeny") is not False:
        fail("network sandbox state is not reported honestly")
    expected_pairing = {"trigger": "native-confirmed-goalong-history-link", "path": "/api/goalong/v1/native/pairing/claim", "method": "POST", "codeLifetimeSeconds": 300, "singleUse": True, "redirects": "refused", "responseMaximumBytes": 8192, "tokenStorage": "user-owned-0600-file", "activityDataSent": False}
    if value.get("network", {}).get("sitePairing") != expected_pairing:
        fail("explicit pairing differs from the reviewed contract")
    if info.get("CFBundleURLTypes") != [{"CFBundleURLName": "ai.goalong.website-connection", "CFBundleURLSchemes": ["goalong-history"], "CFBundleTypeRole": "Viewer"}]:
        fail("unexpected website pairing URL handler")
    expected_submission = {
        "triggers": ["send-site", "native-reviewed-send-button", "native-consented-health-send-button", "native-reviewed-opt-in-schedule"], "automaticSync": "opt-in-previous-day-after-9-app-open",
        "method": "POST", "path": "/api/goalong/v1/import", "transport": "HTTPS-or-development-loopback",
        "authentication": "user-owned-0600-upload-token-file", "redirects": "refused",
        "requestMaximumBytes": 2 * 1024 * 1024, "responseMaximumBytes": 64 * 1024,
        "resourceTimeoutSeconds": 30, "automaticRetry": False, "rawConversationBodies": False,
        "localPathsInPayload": False, "verification": "unverified", "sharing": "managed-on-site",
    }
    if value.get("network", {}).get("siteSubmission") != expected_submission:
        fail("explicit website submission constraints differ from the reviewed contract")
    destinations = value.get("network", {}).get("declaredDestinations", [])
    if len(destinations) != 3 or {item.get("purpose") for item in destinations} != {
        "managed-ChatGPT-analysis-after-explicit-consent", "explicit-selected-website-import", "explicit-website-pairing"
    }:
        fail("declared network emission paths differ from the two reviewed optional features")
    if value.get("ipc", {}).get("authenticatedSensitiveReader") != "not-shipped":
        fail("reader isolation state is not reported honestly")
    defaults = value.get("dataAccess", {}).get("newInstallDefaults", {})
    if not defaults or any(defaults.values()):
        fail("new-install capability defaults are not all false")
    if defaults.get("websiteSubmission") is not False:
        fail("website submission must be off until an explicit user action")
    expected_health = {
        "discovery": False, "sourceMutation": False, "rawXMLRetention": False,
        "archive": "health/YYYY-MM-DD.json", "directoryMode": "0700", "fileMode": "0600",
        "retention": "until-explicit-user-removal", "groups": ["sleep", "heart", "activity", "workouts"],
        "clinicalRecords": False, "gpsRoutes": False, "automaticSync": False,
    }
    if value.get("dataAccess", {}).get("appleHealthImport") != expected_health:
        fail("explicit Apple Health import differs from the reviewed local-data contract")
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
