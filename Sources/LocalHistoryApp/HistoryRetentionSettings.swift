#if os(macOS)
import SwiftUI
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let goalongRetentionPolicyDidChange = Notification.Name("goalongRetentionPolicyDidChange")
}

extension HistoryDataClass {
    var retentionTitle: String {
        switch self {
        case .detailedEvents: return "Detailed activity"
        case .semanticSnapshots: return "Saved visible context"
        case .memories: return "Derived memories & Computer History"
        case .analysisCaches: return "Local analysis caches"
        case .minuteSeals: return "Local cryptographic seals"
        case .anchorReceipts: return "Local verification receipts"
        }
    }
}
extension HistoryRetentionPolicy {
    mutating func setDuration(_ duration: RetentionDuration, for kind: HistoryDataClass) {
        switch kind {
        case .detailedEvents: detailedEvents = duration
        case .semanticSnapshots: semanticSnapshots = duration
        case .memories: memories = duration
        case .analysisCaches: analysisCaches = duration
        case .minuteSeals: minuteSeals = duration
        case .anchorReceipts: anchorReceipts = duration
        }
    }
    var includesProofExpiry: Bool { minuteSeals.days != nil || anchorReceipts.days != nil }
    var retentionDescription: String {
        HistoryDataClass.allCases.map { kind in
            let duration = duration(for: kind).days.map { "\($0) days" } ?? "until you delete it"
            return "\(kind.retentionTitle): \(duration)"
        }.joined(separator: "\n")
    }
}

@MainActor final class HistoryRetentionSettingsModel: ObservableObject {
    @Published var draft: HistoryRetentionPolicy
    @Published var automaticCleanup: Bool
    @Published var error: String?
    @Published private(set) var savedPolicy: HistoryRetentionPolicy
    @Published private(set) var savedAutomaticCleanup: Bool
    private let store: HistoryRetentionStore

    init(store: HistoryRetentionStore? = nil) {
        let resolved = store ?? HistoryRetentionStore(legacyRetentionDays: 30)
        self.store = resolved
        draft = resolved.policy; savedPolicy = resolved.policy
        automaticCleanup = resolved.isAutomaticCleanupEnabled
        savedAutomaticCleanup = resolved.isAutomaticCleanupEnabled
    }
    var hasChanges: Bool { draft != savedPolicy || automaticCleanup != savedAutomaticCleanup }
    @discardableResult func apply(proofDeletionConfirmed: Bool) -> Bool {
        guard !automaticCleanup || !draft.includesProofExpiry || proofDeletionConfirmed else {
            error = "Confirm proof deletion separately, or keep seals and receipts indefinitely."
            return false
        }
        do {
            if automaticCleanup { try store.activate(draft) }
            else { _ = try store.save(draft) }
            savedPolicy = store.policy
            savedAutomaticCleanup = store.isAutomaticCleanupEnabled
            automaticCleanup = savedAutomaticCleanup
            error = nil
            NotificationCenter.default.post(name: .goalongRetentionPolicyDidChange, object: nil)
            return true
        } catch {
            self.error = "The retention change was not confirmed: \(error.localizedDescription). Reopen this panel to check the saved policy before retrying."
            return false
        }
    }
}

@MainActor struct HistoryRetentionSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: HistoryRetentionSettingsModel
    @State private var proofDeletionConfirmed = false
    @State private var showingConfirmation = false

    init(model: HistoryRetentionSettingsModel? = nil) {
        _model = StateObject(wrappedValue: model ?? HistoryRetentionSettingsModel())
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("How long to keep local data").font(.system(size: 22, weight: .semibold))
                    Text("Separate rules for details, memories and proofs.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("Automatically delete expired local data", isOn: $model.automaticCleanup)
                        .toggleStyle(.switch).font(.system(size: 14, weight: .semibold))
                        .accessibilityIdentifier("retention-automatic")
                    Text(model.automaticCleanup
                         ? "After confirmation, expired data can be removed now and during daily cleanup. Reducing a duration affects existing data, not only future recordings."
                         : "Automatic cleanup is off. Data stays until you delete it manually. Choosing durations below does not activate deletion.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    ForEach(HistoryDataClass.allCases, id: \.self) { kind in
                        HStack(alignment: .center, spacing: 16) {
                            Text(kind.retentionTitle).font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Picker(kind.retentionTitle, selection: durationBinding(kind)) {
                                Text("Until I delete it").tag(0)
                                ForEach(durationOptions(kind), id: \.self) { days in Text("\(days) days").tag(days) }
                            }.labelsHidden().frame(width: 170)
                                .accessibilityIdentifier("retention-\(kind.rawValue)")
                        }.padding(12).background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.automaticCleanup && model.draft.includesProofExpiry {
                        Toggle("I also authorize deleting expired local seals and receipts. Verification of those periods may be lost.", isOn: $proofDeletionConfirmed)
                            .font(.system(size: 13)).foregroundStyle(LHTheme.warning)
                            .accessibilityIdentifier("retention-confirm-proofs")
                    }
                    Text("These rules cover Goalong-managed activity, visible context, derived memories (including its Computer History mirror), analysis caches, seals and receipts. They do not delete Apple Screen Time originals or archives, AI source conversations, ChatGPT recap/run history, exported files, backups or data already sent to a website or provider. Those need separate deletion in their respective controls.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(LHTheme.warning)
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(24)
            }
            Divider()
            HStack {
                Text("No changes are applied until you confirm.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(model.automaticCleanup ? "Review & apply…" : "Save without automatic deletion") {
                    if model.automaticCleanup { showingConfirmation = true }
                    else if model.apply(proofDeletionConfirmed: false) { dismiss() }
                }.buttonStyle(LHPrimaryButtonStyle())
                    .disabled(!model.hasChanges || (model.automaticCleanup && model.draft.includesProofExpiry && !proofDeletionConfirmed))
                    .accessibilityIdentifier("retention-apply")
            }.padding(20)
        }
        .frame(width: 700, height: 670).background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .onChange(of: model.draft) { _ in proofDeletionConfirmed = false }
        .alert("Apply automatic deletion?", isPresented: $showingConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Apply these retention rules", role: .destructive) {
                if model.apply(proofDeletionConfirmed: proofDeletionConfirmed) { dismiss() }
            }
        } message: {
            Text(model.draft.retentionDescription + "\n\nExpired local artifacts may be deleted immediately. This cannot be undone here. Exports and remote copies are not removed.")
        }
    }
    private func durationOptions(_ kind: HistoryDataClass) -> [Int] {
        Array(Set([1, 7, 30, 90, 365] + [model.draft.duration(for: kind).days].compactMap { $0 })).sorted()
    }
    private func durationBinding(_ kind: HistoryDataClass) -> Binding<Int> {
        Binding(get: { model.draft.duration(for: kind).days ?? 0 },
                set: { model.draft.setDuration(RetentionDuration(days: $0), for: kind) })
    }
}
#endif
