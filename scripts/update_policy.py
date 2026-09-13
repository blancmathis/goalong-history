#!/usr/bin/env python3
"""The exact reviewed update channel, shared by packaging and artifact validation."""
from __future__ import annotations
import argparse
import base64
import os
import plistlib
from pathlib import Path

SPARKLE_VERSION = "2.9.6"
FEED_URL = "https://github.com/blancmathis/goalong-history/releases/download/latest-main/community-appcast.xml"
SETTINGS = {
    "SUFeedURL": FEED_URL,
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
    "SUEnableAutomaticChecks": True,
    "SUScheduledCheckInterval": 3600,
    "SUAllowsAutomaticUpdates": False,
    "SUAutomaticallyUpdate": False,
    "SUEnableSystemProfiling": False,
    "SUSendProfileInfo": False,
}

def valid_key(key: str) -> bool:
    try:
        return len(base64.b64decode(key, validate=True)) == 32
    except (ValueError, TypeError):
        return False

def validate_info(info: dict, require_configured: bool = False) -> bool:
    keys = {key for key in info if key.startswith("SU") or key == "NSAppTransportSecurity"}
    if not keys and not require_configured:
        return False  # Source builds embed Sparkle but cannot contact a live release feed.
    if keys != set(SETTINGS) | {"SUPublicEDKey"}:
        raise ValueError("Missing, partial or unexpected update/network configuration")
    if not valid_key(info.get("SUPublicEDKey")):
        raise ValueError("A 32-byte Sparkle public Ed25519 key is required")
    for key, expected in SETTINGS.items():
        if type(info.get(key)) is not type(expected) or info[key] != expected:
            raise ValueError(f"Unexpected update setting: {key}")
    return True

def manifest_policy(info: dict) -> dict:
    configured = validate_info(info)
    return {
        "frameworkVersion": SPARKLE_VERSION,
        "configured": configured,
        "feedURL": FEED_URL if configured else None,
        "feedAuthentication": "Ed25519-required",
        "archiveAuthentication": "Ed25519-before-extraction",
        "automaticChecksDefault": configured,
        "scheduledCheckIntervalSeconds": 3600,
        "installation": "user-approved-only",
        "systemProfile": False,
        "activityDataSent": False,
        "archiveURLs": "immutable-per-build-GitHub-release",
        "appleNotarization": False,
        "permissionContinuityGuaranteed": False,
    }

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--configure-info", type=Path)
    parser.add_argument("--verify-info", type=Path)
    parser.add_argument("--require-configured", action="store_true")
    args = parser.parse_args()
    path = args.configure_info or args.verify_info
    if path is None:
        parser.error("an Info.plist path is required")
    info = plistlib.loads(path.read_bytes())
    if args.configure_info:
        key = os.environ.get("LOCALHISTORY_SPARKLE_PUBLIC_ED_KEY", "")
        if key:
            if not valid_key(key):
                raise ValueError("Invalid release public key")
            info.update(SETTINGS, SUPublicEDKey=key)
            path.write_bytes(plistlib.dumps(info))
    validate_info(info, args.require_configured or os.environ.get("LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED") == "1")

if __name__ == "__main__":
    main()
