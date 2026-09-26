#!/usr/bin/env python3
"""Source assertions for the separately reviewed opt-in Jev emission boundary.
These checks supplement tests/review; they are not a sandbox or a proof of privacy.
"""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {
    'Sources/LocalHistoryCore/JevFocus.swift': [
        'maximumRequestBytes = 1600', 'maximumInputTokens = 999',
        'model = "jev-1.13.0"', 'window.hasActivity',
        'state["avoid"] = work.procrastination', 'non-exhaustive', 'unlisted can distract',
        'count >= 1, !warningIssued', 'samples.filter { $0.date >= start && $0.date < end }',
        'response.usage.input_tokens <= JevPayload.maximumInputTokens',
        'response.model == JevPayload.model', 'throw JevError.budget',
        'actions.sorted().joined', 'clean(row.excerpt, bytes: excerptBytes)',
    ],
    'Sources/LocalHistoryApp/JevTransport.swift': [
        'https://api.typesafe.ai/v1/systemone', 'URLSessionConfiguration = { .ephemeral }',
        'configuration.httpShouldSetCookies = false', 'configuration.httpCookieStorage = nil',
        'configuration.urlCredentialStorage = nil', 'configuration.urlCache = nil',
        'configuration.timeoutIntervalForResource = 12', 'completionHandler(nil)',
        'buffer.count + data.count <= 65_536', 'withTaskCancellationHandler',
        'body.count <= JevPayload.maximumRequestBytes', 'response.url == Self.endpoint',
    ],
    'Sources/LocalHistoryApp/JevMonitor.swift': [
        'isEnabled(.jevMonitoring)', 'isEnabled(.localComputerHistory)',
        'GoalongGlobalPause.isPaused()', 'BackgroundContinuityPreferences().manuallyPaused',
        'inbox.configure(enabled: available', 'window.hasActivity', 'scheduleTimer(seconds: 15)',
        'self.inbox.generation == generation', 'self.epoch == token',
        'GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory).revision == policy.revision',
        'GoalongGlobalPause.load().revision == pause.revision',
        'timedBreak != nil || breakStorageInvalid', 'self.streak.accept',
        'self.circuitOpen = true', 'self.retryAfter = Date().addingTimeInterval(Double(seconds))',
        'request?.cancel()',
    ],
    'Sources/LocalHistoryApp/JevIngress.swift': [
        'private var enabled = false', 'private var includeText = false',
        'guard enabled, !privateWindow, !blocked, !overflow', 'event.suppressionReason == nil',
        'event.element?.isSecure != true', 'sample.date.timeIntervalSince($0.date) > 60',
        'samples.count < 512', '!IsSecureEventInputEnabled()',
        'GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory).permits(event)',
        'Self.shouldSampleForeground(presence: presence, evidence: foregroundEvidence)',
        'revision == expected', 'offerVisibleText', 'foregroundSampleInterval: TimeInterval = 5',
        'guard enabled, includeText, !privateWindow, !blocked',
        'DispatchQueue.main.async { center.post(name: .jevBoundaryChanged',
    ],
    'Sources/LocalHistoryApp/JevVisibleContextSampler.swift': [
        'inbox.wantsVisibleText', 'ActivityAnalysisPreferences.richContextEnabled',
        'remoteText && localText', 'self.inbox.generation == ingressGeneration',
        'let current = revalidate()', 'Self.sameBoundary(current, context)',
        'JevVisibleTextPolicy.permitsTraversal', 'JevVisibleTextPolicy.isVisible(bounds, in: viewport)',
        'private var pending = false', 'qos: .utility', 'index < 200',
        'AXProtectedContent', 'AXEditable', 'AXHidden',
    ],
    'Sources/LocalHistoryApp/JevLocalFiles.swift': [
        'O_NOFOLLOW', 'O_CLOEXEC', 'info.st_uid == getuid()', '0o600', '0o700',
        '["api-key", "break.json", "work-context.json"].contains(name)',
    ],
    'Sources/LocalHistoryApp/CapabilityConsentStore.swift': ['case jevMonitoring', 'static let disabledByDefault'],
    'Sources/LocalHistoryApp/ContextProvider.swift': ['JevIngress.shared.setPrivateWindow(cachedPrivateWindow)'],
    'Sources/LocalHistoryApp/JevControls.swift': ['confirmingText = true'],
    'Sources/LocalHistoryApp/JevWarningPanel.swift': ['.nonactivatingPanel', 'overlay.ignoresMouseEvents = true', 'timeInterval: 30', 'RunLoop.main.add(lease, forMode: .common)', 'func hide(', 'canBecomeKey: Bool { false }', 'JevInterventionSettings.overlayOpacity(intensity: stage.intensity)', 'JevReminderPresentation.detail(after: content.seconds)'],
    'Sources/LocalHistoryCore/JevInterventions.swift': ['effectsEnabled = false', 'intensityRange = 10...85', 'intensities.contains(stage.intensity)', 'intensities: 10...40', 'durationThresholdSeconds = 600', 'appearance > 1', 'filter { $0 != previous }'],
    'Sources/LocalHistoryCore/JevWorkContext.swift': ['public let procrastination: String', 'hasProductivityCriteria', 'maximumBytes = 800', 'schemaVersion == 3'],
    'Sources/LocalHistoryApp/JevWorkContextStore.swift': ['JevLocalFiles.read("work-context.json"', 'value.isValid', 'revision = UUID()', 'func save('],
    'Sources/LocalHistoryApp/JevMonitoringPage.swift': ['confirming = true', 'Autoriser les envois à TypeSafe', 'monitor.setEnabled(false)', 'availability.canToggle(isEnabled: enabled)'],
    'Sources/LocalHistoryApp/JevConnectionSheet.swift': ['Une clé est enregistrée sur ce Mac', 'SecureField(', 'monitor.saveKey(key)'],
}


def audit(root=ROOT):
    errors = []
    for relative, fragments in REQUIRED.items():
        try:
            text = (root / relative).read_text()
        except OSError:
            errors.append(f'Missing {relative}')
            continue
        for fragment in fragments:
            if fragment not in text:
                errors.append(f'{relative}: missing {fragment!r}')
    warning = (root / 'Sources/LocalHistoryApp/JevWarningPanel.swift').read_text()
    for forbidden in ['startBreak(', 'setEnabled(false)', 'jev-warning-disable', 'jev-warning-pause']:
        if forbidden in warning:
            errors.append(f'Unexpected popup action {forbidden}')
    ingress = (root / 'Sources/LocalHistoryApp/JevIngress.swift').read_text()
    if 'excerpts[payload.id]' in ingress or 'payload.text' in ingress:
        errors.append('Mixed local semantic payload must not supply remote visible excerpts')
    for path in (root / 'Sources').rglob('Jev*.swift'):
        text = path.read_text()
        if path.name != 'JevTransport.swift' and any(v in text for v in ['URLSession', 'URLRequest(', 'HTTPURLResponse']):
            errors.append(f'Unexpected Jev transport in {path.name}')
        for forbidden in ['URLSession.shared', 'NSPasteboard', 'CGWindowListCreateImage', 'CGEventKeyboardGetUnicodeString', 'Process()']:
            if forbidden in text:
                errors.append(f'Forbidden Jev primitive {forbidden} in {path.name}')
    return errors


if __name__ == '__main__':
    errors = audit()
    for error in errors:
        print(error, file=sys.stderr)
    if not errors:
        print('Jev boundary: separate opt-in, recent evidence, read-only excerpts, bounded transport and cancellation verified in source.')
    raise SystemExit(bool(errors))
