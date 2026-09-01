#!/usr/bin/env python3
"""Generate auditable capability, SBOM, and release manifests from a built app."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import stat
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
FORBIDDEN_LOCAL_ENTITLEMENTS = {
    "com.apple.security.network.client",
    "com.apple.security.network.server",
    "com.apple.security.automation.apple-events",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.get-task-allow",
}
TRANSPORT_MARKERS = {
    "codexAppServer": b"app-server",
    "managedOAuth": b"account/login/start",
    "commitmentUploader": b"URLSessionConfiguration.ephemeral",
    "sparkleUpdater": b"SPUStandardUpdaterController",
}


def run(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        args,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_digest(path: Path) -> str:
    digest = hashlib.sha256()
    for candidate in sorted(path.rglob("*"), key=lambda value: value.as_posix()):
        relative = candidate.relative_to(path).as_posix().encode("utf-8")
        metadata = candidate.lstat()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        if candidate.is_symlink():
            target = os.readlink(candidate).encode("utf-8")
            digest.update(b"L")
            digest.update(len(target).to_bytes(4, "big"))
            digest.update(target)
        elif candidate.is_file():
            digest.update(b"F")
            digest.update(bytes.fromhex(sha256_file(candidate)))
        elif candidate.is_dir():
            digest.update(b"D")
    return digest.hexdigest()


def git_value(root: Path, *args: str) -> str | None:
    result = run("/usr/bin/git", *args, cwd=root)
    if result.returncode != 0:
        return None
    value = result.stdout.decode("utf-8", "replace").strip()
    return value or None


def parse_codesign_metadata(path: Path) -> dict[str, Any]:
    details = run("/usr/bin/codesign", "-d", "--verbose=4", str(path))
    text = details.stderr.decode("utf-8", "replace")
    fields: dict[str, str] = {}
    authorities: list[str] = []
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key == "Authority":
            authorities.append(value)
        elif key in {"Identifier", "TeamIdentifier", "CDHash", "Signature", "CodeDirectory"}:
            fields[key] = value

    requirement_result = run("/usr/bin/codesign", "-d", "-r-", str(path))
    requirement = requirement_result.stderr.decode("utf-8", "replace").strip()
    if requirement.startswith("designated => "):
        requirement = requirement.removeprefix("designated => ")

    entitlement_result = run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(path))
    entitlements: dict[str, Any] = {}
    payload = entitlement_result.stdout
    if payload:
        try:
            decoded = plistlib.loads(payload)
            if isinstance(decoded, dict):
                entitlements = decoded
        except Exception:
            pass

    return {
        "identifier": fields.get("Identifier"),
        "teamIdentifier": fields.get("TeamIdentifier"),
        "codeDirectoryHash": fields.get("CDHash"),
        "signature": fields.get("Signature"),
        "authorities": authorities,
        "designatedRequirement": requirement or None,
        "entitlements": entitlements,
        "codesignInspectionSucceeded": details.returncode == 0,
    }


def linked_libraries(path: Path) -> list[str]:
    result = run("/usr/bin/otool", "-L", str(path))
    if result.returncode != 0:
        return []
    libraries: list[str] = []
    for line in result.stdout.decode("utf-8", "replace").splitlines()[1:]:
        value = line.strip().split(" (compatibility version", 1)[0]
        if value:
            libraries.append(value)
    return libraries


def executable_files(app: Path) -> list[Path]:
    roots = [app / "Contents" / "MacOS", app / "Contents" / "Frameworks"]
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.is_symlink() or not path.is_file():
                continue
            if os.access(path, os.X_OK) or run("/usr/bin/file", "-b", str(path)).stdout.startswith(b"Mach-O"):
                files.append(path)
    return sorted(set(files), key=lambda value: value.as_posix())


def inspect_code(app: Path) -> tuple[list[dict[str, Any]], dict[str, bool]]:
    objects: list[dict[str, Any]] = []
    detected = {key: False for key in TRANSPORT_MARKERS}
    for path in executable_files(app):
        data = path.read_bytes()
        for key, marker in TRANSPORT_MARKERS.items():
            detected[key] = detected[key] or marker in data
        objects.append(
            {
                "path": path.relative_to(app).as_posix(),
                "sizeBytes": path.stat().st_size,
                "sha256": sha256_file(path),
                "linkedLibraries": linked_libraries(path),
                "codeSignature": parse_codesign_metadata(path),
            }
        )
    return objects, detected


def entitlement_strings(signatures: list[dict[str, Any]], key: str) -> list[str]:
    values: set[str] = set()
    for signature in signatures:
        value = (signature.get("entitlements") or {}).get(key)
        if isinstance(value, str):
            values.add(value)
        elif isinstance(value, list):
            values.update(item for item in value if isinstance(item, str))
    return sorted(values)


def load_resolved_dependencies(root: Path) -> list[dict[str, Any]]:
    path = root / "Package.resolved"
    if not path.exists():
        return []
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    pins = value.get("pins") or value.get("object", {}).get("pins") or []
    dependencies: list[dict[str, Any]] = []
    for pin in pins:
        state = pin.get("state", {})
        dependencies.append(
            {
                "identity": pin.get("identity") or pin.get("package"),
                "location": pin.get("location") or pin.get("repositoryURL"),
                "version": state.get("version"),
                "revision": state.get("revision"),
            }
        )
    return sorted(dependencies, key=lambda item: str(item.get("identity")))


def capability_manifest(app: Path, edition: str, root: Path) -> dict[str, Any]:
    with (app / "Contents" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    code_objects, detected = inspect_code(app)
    app_signature = parse_codesign_metadata(app)
    app_entitlements = app_signature.get("entitlements") or {}
    signatures = [app_signature] + [
        item.get("codeSignature") or {} for item in code_objects
    ]
    app_groups = entitlement_strings(
        signatures, "com.apple.security.application-groups"
    )
    mach_lookup_services = entitlement_strings(
        signatures, "com.apple.security.temporary-exception.mach-lookup.global-name"
    )
    mach_register_services = entitlement_strings(
        signatures, "com.apple.security.temporary-exception.mach-register.global-name"
    )
    xpc_services = sorted(
        candidate.relative_to(app).as_posix()
        for candidate in app.rglob("*.xpc")
        if candidate.is_dir() and not candidate.is_symlink()
    )
    frameworks = sorted(
        candidate.name
        for candidate in (app / "Contents" / "Frameworks").glob("*.framework")
    ) if (app / "Contents" / "Frameworks").exists() else []
    capability_states = {
        "singlePublicApplication": "present",
        "defaultCapabilityState": "all-off",
        "explicitConsentRegistry": "present",
        "firstPartyNetworkTransport": "absent",
        "automaticUpdater": "absent",
        "managedChatGPTBridge": "explicit-consent-only",
        "directProviderSourceReaders": "present",
        "processExecution": "fixed-codex-app-server-only",
        "fullDiskAccessIsolationService": "not-shipped",
        "osEnforcedNetworkSandbox": "not-enabled",
    }
    declared_network_destinations: list[dict[str, str]] = [
        {
            "purpose": "managed-ChatGPT-analysis-after-explicit-consent",
            "destination": "Codex app-server managed account transport",
            "source": "separately installed Codex executable; no URLSession in Goalong",
        }
    ]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "product": {
            "name": info.get("CFBundleDisplayName") or info.get("CFBundleName"),
            "bundleIdentifier": info.get("CFBundleIdentifier"),
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "edition": info.get("GoalongBuildEdition"),
        },
        "source": {
            "commit": git_value(root, "rev-parse", "HEAD"),
            "dirty": bool(git_value(root, "status", "--porcelain")),
        },
        "bundle": {
            "treeSha256": tree_digest(app),
            "sizeBytes": sum(path.stat().st_size for path in app.rglob("*") if path.is_file() and not path.is_symlink()),
            "frameworks": frameworks,
            "infoPlistNetworkAndUpdateKeys": sorted(
                key for key in info if key.startswith("SU") or key in {"NSAppTransportSecurity"}
            ),
            "privacyUsageDescriptions": {
                key: info[key]
                for key in ("NSAccessibilityUsageDescription", "NSInputMonitoringUsageDescription")
                if key in info
            },
            "expectedTCC": [
                {
                    "permission": "Accessibility",
                    "purpose": "foreground app, window and permitted interface context",
                    "usageDescriptionPresent": "NSAccessibilityUsageDescription" in info,
                },
                {
                    "permission": "Input Monitoring",
                    "purpose": "click, scroll and coarse keyboard activity",
                    "usageDescriptionPresent": "NSInputMonitoringUsageDescription" in info,
                },
                {
                    "permission": "Full Disk Access",
                    "purpose": "read Apple Screen Time and enabled provider-owned local histories",
                    "usageDescriptionPresent": False,
                },
            ],
            "appGroups": app_groups,
            "machServices": {
                "lookup": mach_lookup_services,
                "register": mach_register_services,
            },
            "xpcServices": xpc_services,
            "codeSignature": app_signature,
        },
        "network": {
            "declaredDestinations": declared_network_destinations,
            "osEnforcedDeny": False,
        },
        "dataAccess": {
            "readOnlyProviderRoots": [
                "Apple Screen Time private stores",
                "~/.codex",
                "~/.claude",
                "~/.cursor",
                "~/.local/share/opencode",
                "~/.gemini/tmp",
                "VS Code/Cursor workspace storage",
                "explicitly enabled custom provider folders",
            ],
            "goalongOwnedWriteRoot": "~/Library/Application Support/LocalHistory",
            "userSelectedExportDestinations": True,
            "consentRegistry": "~/Library/Application Support/LocalHistory/capability-consent.json",
            "consentRegistryMode": "0600",
            "newInstallDefaults": {
                "computerHistory": False,
                "appleScreenTime": False,
                "aiConversations": False,
                "chatGPTAnalysis": False,
                "remoteVerification": False,
                "automaticUpdates": False,
                "launchAtLogin": False,
            },
            "enforcement": "reviewed source policy and runtime validation; not an App Sandbox path allowlist",
        },
        "ipc": {
            "protocolVersion": "goalong-readonly-unix-v1",
            "transport": "unix-domain-socket",
            "authentication": "same-user-filesystem-permissions",
            "runtimeDirectoryMode": "0700",
            "socketMode": "0600",
            "commands": ["screen-time"],
            "maximumRequestBytes": 4 * 1024,
            "maximumResponseBytes": 64 * 1024 * 1024,
            "persistsResponses": False,
            "authenticatedSensitiveReader": "not-shipped",
        },
        "capabilities": capability_states,
        "detectedBinaryMarkers": detected,
        "forbiddenLocalEntitlementsPresent": sorted(FORBIDDEN_LOCAL_ENTITLEMENTS.intersection(app_entitlements)),
        "codeObjects": code_objects,
        "limitations": [
            "This manifest inventories the built artifact; the separately published GitHub/Sigstore attestation binds artifact digests to CI provenance but does not prove source-to-binary reproducibility.",
            "Absence of reviewed transport markers does not create an OS network sandbox.",
            "Full Disk Access readers still run in the main process; a separately sandboxed reader is not shipped.",
            "The explicit-consent Codex process bridge is an emission path and remains part of the review surface.",
        ],
    }


def spdx_manifest(app: Path, capabilities: dict[str, Any], root: Path) -> dict[str, Any]:
    product = capabilities["product"]
    dependencies = load_resolved_dependencies(root)
    packages: list[dict[str, Any]] = [
        {
            "SPDXID": "SPDXRef-GoalongHistory",
            "name": product["name"],
            "versionInfo": product["version"],
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": True,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "MIT",
            "copyrightText": "NOASSERTION",
            "checksums": [{"algorithm": "SHA256", "checksumValue": capabilities["bundle"]["treeSha256"]}],
        }
    ]
    relationships: list[dict[str, str]] = []
    for index, dependency in enumerate(dependencies, start=1):
        identifier = f"SPDXRef-Dependency-{index}"
        packages.append(
            {
                "SPDXID": identifier,
                "name": dependency.get("identity") or f"dependency-{index}",
                "versionInfo": dependency.get("version") or dependency.get("revision") or "NOASSERTION",
                "downloadLocation": dependency.get("location") or "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "copyrightText": "NOASSERTION",
                "externalRefs": ([{
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": f"pkg:swift/{dependency.get('identity')}@{dependency.get('version')}",
                }] if dependency.get("identity") and dependency.get("version") else []),
            }
        )
        relationships.append(
            {
                "spdxElementId": "SPDXRef-GoalongHistory",
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": identifier,
            }
        )
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"{product['name']}-{product['version']}-sbom",
        "documentNamespace": f"https://github.com/blancmathis/goalong-history/spdx/{capabilities['bundle']['treeSha256']}",
        "creationInfo": {
            "created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "creators": ["Tool: Goalong-History-security-artifact-generator/1"],
        },
        "packages": packages,
        "relationships": relationships,
    }


def release_manifest(
    output: Path,
    app: Path,
    capabilities: dict[str, Any],
    include_release_artifacts: bool,
) -> dict[str, Any]:
    artifacts: list[dict[str, Any]] = [
        {
            "path": app.name,
            "kind": "app-bundle",
            "sizeBytes": capabilities["bundle"]["sizeBytes"],
            "sha256": capabilities["bundle"]["treeSha256"],
        }
    ]
    release_prefix = "Goalong-History-"
    always_included = {"security-capabilities.json", "sbom.spdx.json"}
    for path in sorted(output.iterdir(), key=lambda value: value.name):
        if path.name == "release-manifest.json":
            continue
        if path.resolve() == app:
            continue
        elif path.is_file() and not path.is_symlink() and (
            path.name in always_included
            or (include_release_artifacts and path.name.startswith(release_prefix))
        ):
            artifacts.append(
                {
                    "path": path.name,
                    "kind": path.suffix.lstrip(".") or "file",
                    "sizeBytes": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sourceCommit": capabilities["source"]["commit"],
        "sourceDirty": capabilities["source"]["dirty"],
        "product": capabilities["product"],
        "artifacts": artifacts,
    }


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--edition", required=True, choices=("unified",))
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--include-release-artifacts", action="store_true")
    args = parser.parse_args()

    app = args.app.resolve()
    output = args.output_dir.resolve()
    root = args.source_root.resolve()
    if not (app / "Contents" / "Info.plist").is_file():
        raise SystemExit(f"Incomplete app bundle: {app}")
    output.mkdir(parents=True, exist_ok=True)
    capabilities = capability_manifest(app, args.edition, root)
    write_json(output / "security-capabilities.json", capabilities)
    write_json(output / "sbom.spdx.json", spdx_manifest(app, capabilities, root))
    write_json(
        output / "release-manifest.json",
        release_manifest(output, app, capabilities, args.include_release_artifacts),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
