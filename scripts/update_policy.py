#!/usr/bin/env python3
"""The exact reviewed update channel, shared by packaging and artifact validation."""
from __future__ import annotations
import argparse
import base64
import os
import plistlib
from pathlib import Path

SPARKLE_VERSION = "2.9.6"
PUBLIC_KEY_FILE = Path(__file__).resolve().parent.parent / "Distribution/sparkle-public-ed-key.txt"

def release_public_key() -> str:
    """Public trust anchor, reviewed in source control; never retrieved from the network."""
    key = PUBLIC_KEY_FILE.read_text(encoding="ascii").strip()
    if not valid_key(key):
        raise ValueError("The committed Sparkle public key is missing or malformed")
    return key

def configure_info(info: dict, environment: dict) -> dict:
    result = dict(info)
    if environment.get("LOCALHISTORY_DISABLE_UPDATES", "0") not in ("0", "1"):
        raise ValueError("LOCALHISTORY_DISABLE_UPDATES must be 0 or 1")
    if environment.get("LOCALHISTORY_DISABLE_UPDATES") == "1":
        if environment.get("LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED") == "1":
            raise ValueError("A public release cannot disable update authentication")
        for name in set(SETTINGS) | {"SUPublicEDKey"}:
            result.pop(name, None)
        validate_info(result)
        return result
    key = release_public_key()
    override = environment.get("LOCALHISTORY_SPARKLE_PUBLIC_ED_KEY", "")
    if override and override != key:
        raise ValueError("Release key does not match the committed public trust anchor; do not rotate it implicitly")
    result.update(SETTINGS, SUPublicEDKey=key)
    validate_info(result, require_configured=True)
    return result

FEED_URL = "https://github.com/blancmathis/goalong-history/releases/download/latest-main/community-appcast.xml"
SETTINGS = {
    "SUFeedURL": FEED_URL,
    "SURequireSignedFeed": True,
    "SUSignedFeedFailureExpirationInterval": 0,
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
        return False  # Explicit offline builds only; ordinary source builds include the trust anchor.
    if keys != set(SETTINGS) | {"SUPublicEDKey"}:
        raise ValueError("Missing, partial or unexpected update/network configuration")
    if not valid_key(info.get("SUPublicEDKey")) or info["SUPublicEDKey"] != release_public_key():
        raise ValueError("The committed Sparkle public Ed25519 key is required")
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
        info = configure_info(info, dict(os.environ))
        # Validate before writing so a rejected configuration never mutates the bundle.
        validate_info(info, args.require_configured)
        path.write_bytes(plistlib.dumps(info))
    validate_info(info, args.require_configured or os.environ.get("LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED") == "1")

if __name__ == "__main__":
    main()
