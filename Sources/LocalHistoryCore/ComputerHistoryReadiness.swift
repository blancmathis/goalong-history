import Foundation

public enum ComputerHistoryReadinessState: String, Codable, CaseIterable {
    case metadataOnly
    case permissionRequired
    case inputCaptureUnproven
    case awaitingDayEvidence
    case partialSemanticCoverage
    case ready
}

/// Honest, externally presentable readiness for full Computer History analysis.
/// Enabling Rich Context is consent, not proof. Readiness additionally requires
/// functional permissions, a working event tap with a real callback, and measured
/// before/after coverage for the selected day.
public struct ComputerHistoryReadinessAssessment: Codable, Equatable {
    public let state: ComputerHistoryReadinessState
    public let title: String
    public let detail: String
    public let captureProven: Bool
    public let stablePermissionIdentity: Bool?
    public let semanticPairRatio: Double?
    public let limitations: [String]

    public init(
        state: ComputerHistoryReadinessState,
        title: String,
        detail: String,
        captureProven: Bool,
        stablePermissionIdentity: Bool?,
        semanticPairRatio: Double?,
        limitations: [String]
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.captureProven = captureProven
        self.stablePermissionIdentity = stablePermissionIdentity
        self.semanticPairRatio = semanticPairRatio
        self.limitations = limitations
    }

    public static func assess(
        richContextEnabled: Bool,
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        eventTapRunning: Bool,
        captureHealth: CaptureHealthAssessment?,
        captureHealthSnapshot: CaptureHealthSnapshot?,
        coverage: ComputerHistoryCoverage?,
        minimumSemanticPairRatio: Double = 0.90
    ) -> ComputerHistoryReadinessAssessment {
        let stableIdentity = captureHealthSnapshot?.build.isStableAcrossUpdates
        let pairRatio = coverage?.semanticPairCoverage
        var limitations: [String] = []
        if stableIdentity == false {
            limitations.append(
                "This build does not have a Developer ID or App Store identity that is stable across updates."
            )
        }

        guard richContextEnabled else {
            return ComputerHistoryReadinessAssessment(
                state: .metadataOnly,
                title: "Metadata-only analysis is active",
                detail: "Rich Context is off. Apps and actions can still appear, but semantic changes, task status and resume answers may be incomplete.",
                captureProven: captureHealth?.captureProven == true,
                stablePermissionIdentity: stableIdentity,
                semanticPairRatio: pairRatio,
                limitations: limitations + [
                    "Visible and selected Accessibility text is not being added to new semantic snapshots."
                ]
            )
        }

        guard accessibilityGranted, inputMonitoringGranted else {
            let missing = [
                accessibilityGranted ? nil : "Accessibility",
                inputMonitoringGranted ? nil : "Input Monitoring",
            ].compactMap { $0 }.joined(separator: " and ")
            return ComputerHistoryReadinessAssessment(
                state: .permissionRequired,
                title: "Full analysis is missing required permission evidence",
                detail: "\(missing) is not currently granted to the running app identity.",
                captureProven: false,
                stablePermissionIdentity: stableIdentity,
                semanticPairRatio: pairRatio,
                limitations: limitations
            )
        }

        guard eventTapRunning,
            captureHealth?.captureProven == true
        else {
            let healthDetail = captureHealth?.detail
                ?? "No persisted capture-health assessment is available yet."
            return ComputerHistoryReadinessAssessment(
                state: .inputCaptureUnproven,
                title: "Rich Context is enabled, but input capture is not proven",
                detail: healthDetail,
                captureProven: false,
                stablePermissionIdentity: stableIdentity,
                semanticPairRatio: pairRatio,
                limitations: limitations + (captureHealth?.limitations ?? [])
            )
        }

        guard let coverage, coverage.actionEventCount > 0 else {
            return ComputerHistoryReadinessAssessment(
                state: .awaitingDayEvidence,
                title: "Capture works; this day has no causal action evidence yet",
                detail: "A real callback reached this process, but the selected day contains no eligible action from which before/after coverage can be measured.",
                captureProven: true,
                stablePermissionIdentity: stableIdentity,
                semanticPairRatio: pairRatio,
                limitations: limitations
            )
        }

        guard let pairRatio, pairRatio >= minimumSemanticPairRatio else {
            let rendered = pairRatio.map {
                "\(Int(($0 * 100).rounded()))%"
            } ?? "unavailable"
            return ComputerHistoryReadinessAssessment(
                state: .partialSemanticCoverage,
                title: "Computer History has partial semantic evidence",
                detail: "Before/after coverage is \(rendered) for the selected day; at least \(Int((minimumSemanticPairRatio * 100).rounded()))% is required before the day is presented as fully understood.",
                captureProven: true,
                stablePermissionIdentity: stableIdentity,
                semanticPairRatio: pairRatio,
                limitations: limitations + [
                    "Episodes and answers must be interpreted with the displayed gaps and uncertainties."
                ]
            )
        }

        return ComputerHistoryReadinessAssessment(
            state: .ready,
            title: "Causal Computer History is evidenced for this day",
            detail: "The running process has proven input capture and \(Int((pairRatio * 100).rounded()))% of reconstructed interactions contain both before and after semantic context.",
            captureProven: true,
            stablePermissionIdentity: stableIdentity,
            semanticPairRatio: pairRatio,
            limitations: limitations
        )
    }
}
