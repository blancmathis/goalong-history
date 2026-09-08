#!/usr/bin/env python3
"""Guard the reviewed explicit website emission boundary; never read user history."""
from __future__ import annotations

import argparse
import re
from pathlib import Path


def audit(root: Path) -> list[str]:
    errors: list[str] = []
    paths = {
        "transport": "Sources/LocalHistoryQueryCLI/GoalongSiteSubmission.swift",
        "export": "Sources/LocalHistoryQueryCLI/GoalongSiteExport.swift",
        "cli": "Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift",
        "ui": "Sources/LocalHistoryApp/GoalongWebsiteConnectionCard.swift",
        "contract": "Sources/LocalHistoryQueryCLI/GoalongCLIContract.swift",
    }
    sources = {}
    for key, path in paths.items():
        try:
            sources[key] = (root / path).read_text()
        except OSError:
            errors.append(f"Missing reviewed website boundary: {path}")
    if errors:
        return errors

    required = {
        "transport": [
            'parts.path = "/api/goalong/v1/import"', 'parts.scheme == "https"',
            '["127.0.0.1", "localhost", "[::1]", "::1"]',
            'parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil',
            'O_NOFOLLOW', 'metadata.st_uid == getuid()', 'metadata.st_mode & 0o777 == 0o600',
            'request.httpMethod = "POST"', 'forHTTPHeaderField: "Authorization"',
            'forHTTPHeaderField: "Idempotency-Key"', 'UUID().uuidString',
            'URLSessionConfiguration.ephemeral', 'configuration.httpShouldSetCookies = false',
            'payload.count <= 2 * 1024 * 1024',
            'configuration.httpCookieStorage = nil', 'configuration.urlCredentialStorage = nil',
            'configuration.urlCache = nil', 'configuration.timeoutIntervalForResource = 30',
            'willPerformHTTPRedirection', 'completionHandler(nil)',
            'response.expectedContentLength > 65_536', 'data.count + chunk.count <= 65_536',
            'response["verification"] as? String == "unverified"',
        ],
        "export": [
            '"version": 2, "source": "goalong-history"', '"outcomes": [], "activities": []',
            '"websites": websiteValue, "agent": NSNull()', 'data.count <= 2 * 1024 * 1024',
            'options.includeApplications', 'options.includeHourly', 'options.includeWebsites',
            'options.includeRecap', 'summaryText.utf16.count <= 3000',
        ],
        "cli": [
            'case "export-site", "send-site":', 'if command == "send-site", let origin, let tokenPath',
            'siteExportPayload(rootDirectory: root, day: raw, options: options)',
            'capabilityConsentEnabled(rootDirectory: root, capability: "appleScreenTime")',
            'capabilityConsentEnabled(rootDirectory: root, capability: "localComputerHistory")',
            'capabilityConsentEnabled(rootDirectory: root, capability: "chatGPTAnalysis")',
            'archive.storedRecord(for: requestedDay)',
        ],
        "ui": [
            'Button("Send reviewed data", action: sendReviewedData)',
            'guard let reviewedPayload = payload else { return }',
            'payload: reviewedPayload, origin: target, tokenFile: tokenFile',
        ],
        "contract": ['case sendsExplicitSiteImport', 'name: "export-site"', 'name: "send-site"',
                     'effect: .sendsExplicitSiteImport', 'configured website sharing rules apply'],
    }
    for key, fragments in required.items():
        for fragment in fragments:
            if fragment not in sources[key]:
                errors.append(f"Website boundary invariant missing in {paths[key]}: {fragment}")

    # An extra send call, lifecycle hook or alternate caller needs an explicit new review.
    callers = []
    for directory in [root / "Sources", root / "Features"]:
        for path in directory.rglob("*.swift"):
            text = path.read_text()
            calls = re.findall(r"GoalongSiteSubmission\s*\.\s*send\s*\(", text)
            callers.extend([path.relative_to(root).as_posix()] * len(calls))
    if sorted(callers) != sorted([paths["cli"], paths["ui"]]):
        errors.append("Website sending may be called only once from explicit CLI dispatch and once from the reviewed native button")
    if len(re.findall(r"\bsendReviewedData\b", sources["ui"])) != 2:
        errors.append("The native send action has an additional caller; passive/lifecycle sending is prohibited")
    if len(re.findall(r"\.dataTask\s*\(", sources["transport"])) != 1:
        errors.append("Website transport must create exactly one explicit data task, without an automatic retry")
    if re.search(r"\.\s*(?:uploadTask|downloadTask|webSocketTask|streamTask)\s*\(|URLSession\.shared", sources["transport"]):
        errors.append("An additional or ambient transport was introduced in the website sender")
    for key in ["export", "transport"]:
        if re.search(r"\b(?:Timer|NotificationCenter|NSWorkspace|Process)\b|\.scheduledTimer\b", sources[key]):
            errors.append(f"Website {key} introduces a process, lifecycle, browser or timer dependency")
    if re.search(r'"(?:messages|transcript|rawEvents|capturedText|sourcePath|rootDirectory)"\s*:', sources["export"]):
        errors.append("Website export contains a forbidden raw body or local-path field")
    if re.search(r"URLSession|URLRequest|HTTPURLResponse|GoalongSiteSubmission", sources["export"]):
        errors.append("The offline website projector must not contain a transport")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    errors = audit(args.source_root)
    for error in errors:
        print(error)
    if not errors:
        print("Explicit website boundary passed: selected v2 fields, owner-only token, safe origin, no redirects, bounded one-shot request, no passive caller.")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
