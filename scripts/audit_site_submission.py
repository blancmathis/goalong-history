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
        "health_ui": "Sources/LocalHistoryApp/GoalongHealthImportSheet.swift",
        "health_import": "Sources/LocalHistoryQueryCLI/GoalongHealthImport.swift",
        "contract": "Sources/LocalHistoryQueryCLI/GoalongCLIContract.swift",
        "schedule": "Sources/LocalHistoryApp/GoalongWebsiteAutoSender.swift",
        "sharing_model": "Sources/LocalHistoryApp/GoalongWebsiteSharingModel.swift",
        "sharing_ui": "Sources/LocalHistoryApp/GoalongWebsiteSharingSheet.swift",
        "sharing_link": "Sources/LocalHistoryQueryCLI/GoalongSiteSharingLink.swift",
        "catalog": "Sources/LocalHistoryQueryCLI/GoalongSiteSelectionCatalog.swift",
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
            'forHTTPHeaderField: "Idempotency-Key"', 'SHA256Digest.hashHex(payload)',
            'SHA256Digest.hashHex(Data(token.utf8)) != expectedTokenFingerprint',
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
        "schedule": [
            'guard !busy, enabled, var current = configuration()',
            'current.policyVersion == 2', 'current.paused != true',
            'current.lastAttempt != day', 'current.lastAttempt = day', 'try store(current)',
            'configuration()?.identifier == snapshot.identifier',
            'configuration()?.origin == snapshot.origin', 'configuration()?.tokenPath == snapshot.tokenPath',
            'guard sourceConsent(current.options)', 'guard sourceConsent(snapshot.options)',
            'selected.includeRecap = false', 'selected.recapText = nil', 'selected.recapSectionIndices = nil',
            'selected.contextualRhythm = nil', 'selected.rhythmProject = nil',
            'selected.includeRhythmContext = false', 'selected.includeRhythmTimeline = false',
            'options.selectedApplicationIDs != nil', 'options.selectedWebsiteDomains != nil',
            'if !selected.maskedApplications.isEmpty { selected.includeWebsites = false }',
            'snapshot.credentialFingerprint', 'saved.paused = true', 'defaults.removeObject(forKey: key)', 'enabled = false',
        ],
        "sharing_model": [
            'guard !busy, reviewed, let approved = preview else { return }',
            'approved.draft == draft', 'approved.origin == origin.trimmingCharacters',
            'approved.tokenPath == tokenPath', 'Date().timeIntervalSince(approved.createdAt) <= 900',
            'sourceConsent(approved.draft.options)',
            'SHA256Digest.hashHex(Data(token.utf8)) == approved.credentialFingerprint',
            'try sender(approved.payload, approved.origin', 'approved.credentialFingerprint)',
            'autoSender.enable(origin: approved.origin', 'options: approved.draft.options',
            'if autoSender.enabled { autoSender.stop()', 'func invalidate() { preview = nil; reviewed = false;',
            'var deviceIDs = Set<String>()', 'var applicationIDs = Set<String>()', 'var websiteDomains = Set<String>()',
        ],
        "sharing_ui": [
            'model.confirm(origin: origin, tokenPath: tokenPath)',
            '.disabled(model.busy || !model.reviewed)',
            'Toggle(isOn: $model.reviewed)',
        ],
        "sharing_link": ['items.count == 2', 'Set(items.map(\\.name)) == ["site", "account"]',
                         'parts.fragment == nil', 'UUID(uuidString: account)',
                         'GoalongSiteSubmission.endpoint(origin: site)'],
        "contract": ['case sendsExplicitSiteImport', 'name: "export-site"', 'name: "send-site"',
                     'effect: .sendsExplicitSiteImport', 'configured website sharing rules apply'],
        "health_ui": ['action: sendReviewedHealth', 'guard let payload, consent else { return }',
                      'consent = false', '.disabled(!consent || origin.isEmpty || tokenFilePath.isEmpty)',
                      'GoalongHealthArchive.read(', 'GoalongHealthImport.read('],
        "health_import": ['parser.shouldResolveExternalEntities = false', 'O_NOFOLLOW',
                          '"source": "apple-health"', 'payload.count <= 2 * 1024 * 1024'],
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
    if sorted(callers) != sorted([paths["cli"], paths["ui"], paths["health_ui"], paths["schedule"], paths["sharing_model"]]):
        errors.append("Website sending requires exactly the reviewed CLI, buttons and opt-in scheduler")
    if re.search(r"URLSession|URLRequest|HTTPURLResponse", sources["schedule"]):
        errors.append("The opt-in scheduler must use only the existing bounded website transport")
    if sources["sharing_model"].count('autoSender.enable(') != 1 or 'autoSender.enable(' in sources["ui"]:
        errors.append("Scheduling requires the reviewed sharing model, never the legacy advanced window")
    if sources["sharing_ui"].count('model.confirm(') != 1 or sources["sharing_model"].count('func confirm(') != 1:
        errors.append("The sharing confirmation requires exactly one explicit UI caller")
    for key in ["sharing_model", "sharing_ui", "catalog"]:
        if re.search(r"URLSession|URLRequest|HTTPURLResponse", sources[key]):
            errors.append(f"The {key} must not add an alternate website transport")
    if re.search(r"GoalongSiteSubmission\.send|\.confirm\(|autoSender\.enable|URLSession", sources["sharing_link"]):
        errors.append("A website sharing link may only describe navigation, never authorization or transmission")
    if len(re.findall(r"\bsendReviewedData\b", sources["ui"])) != 2:
        errors.append("The native send action has an additional caller; passive/lifecycle sending is prohibited")
    if len(re.findall(r"\bsendReviewedHealth\b", sources["health_ui"])) != 2:
        errors.append("The Health send action has an additional caller; passive/lifecycle sending is prohibited")
    if re.search(r"URLSession|URLRequest|HTTPURLResponse|GoalongSiteSubmission", sources["health_import"]):
        errors.append("The local Health parser must not contain a transport")
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
    pairing_path = root / "Sources/LocalHistoryQueryCLI/GoalongSitePairing.swift"
    coordinator_path = root / "Sources/LocalHistoryApp/GoalongWebsitePairingCoordinator.swift"
    if not pairing_path.exists() or not coordinator_path.exists():
        errors.append("Explicit pairing sources are missing")
    else:
        pairing = pairing_path.read_text()
        coordinator = coordinator_path.read_text()
        for marker in ['GoalongSiteSubmission.endpoint(origin: site)', 'parts.scheme == "goalong-history"', 'parts.host == "connect"', 'parts.queryItems?.count == 1', 'completionHandler(nil)', 'URLSessionConfiguration.ephemeral', 'configuration.httpShouldSetCookies = false', 'configuration.httpCookieStorage = nil', 'configuration.urlCredentialStorage = nil', 'configuration.urlCache = nil', 'configuration.timeoutIntervalForResource = 30', 'data.count + chunk.count <= 8192', 'O_EXCL | O_NOFOLLOW', '0o600', '0o700']:
            if marker not in pairing: errors.append("Pairing constraint missing: " + marker)
        if len(re.findall(r"\.dataTask\s*\(", pairing)) != 1 or "URLSession.shared" in pairing:
            errors.append("Pairing must use one bounded explicit request")
        if 'guard await present(confirmation, on: window) == .alertFirstButtonReturn else { return false }' not in coordinator:
            errors.append("Native pairing requires explicit confirmation")
        if 'alert.beginSheetModal(for: window)' not in coordinator or '.runModal()' in coordinator:
            errors.append("Native pairing confirmation must belong to the visible app window")
        for marker in ['requested.origin == savedOrigin', 'requested.accountID == savedAccount',
                       'SHA256Digest.hashHex(Data(token.utf8)) == fingerprint', 'GoalongWebsiteAutoSender.shared.forget()']:
            if marker not in coordinator: errors.append("Account-bound picker invariant missing: " + marker)
        if coordinator.count('pairing.exchange()') != 1:
            errors.append("Pairing must not retry automatically")
        callers = [p for p in (root / "Sources").rglob("*.swift") if 'pairing.exchange()' in p.read_text()]
        if callers != [coordinator_path]: errors.append("Pairing has an unexpected caller")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    errors = audit(args.source_root)
    for error in errors:
        print(error)
    if not errors:
        print("Website boundary passed: selected fields, protected token, safe origin, bounded requests, reviewed opt-in scheduling, no unapproved caller.")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
