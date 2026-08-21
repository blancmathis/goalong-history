#if os(macOS)
    import Foundation
    import LocalHistoryCore

    extension DashboardViewModel {
        func isDomainExcludedFromCapture(_ host: String) -> Bool {
            URLRedactor.domain(host, matches: configuredExcludedDomains)
        }

        func isApplicationExcludedFromCapture(_ bundleIdentifier: String) -> Bool {
            let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return false }
            if normalized.caseInsensitiveCompare(ProductIdentity.bundleIdentifier) == .orderedSame {
                return true
            }
            return configuredExcludedApplications.contains {
                $0.caseInsensitiveCompare(normalized) == .orderedSame
            }
        }

        /// Updates the recorder's persistent excluded-domain list from the Activity screen.
        /// Existing sealed history is not rewritten; disabling capture affects future events.
        func setDomainCaptureEnabled(_ enabled: Bool, host: String) {
            let normalized = SharingSubjectKey.normalizedHost(host)
            guard !normalized.isEmpty else { return }
            guard canEditMonitoringRules() else { return }

            var domains = configuredExcludedDomains
            if enabled {
                domains.removeAll {
                    SharingSubjectKey.normalizedHost($0) == normalized
                }
            } else if !domains.contains(where: {
                SharingSubjectKey.normalizedHost($0) == normalized
            }) {
                domains.append(normalized)
            }

            settingsDraft.excludedDomainsText = domains.sorted().joined(separator: "\n")
            saveSettings()
        }

        /// Updates the recorder's persistent excluded-application list from the Activity screen.
        /// Goalong's own bundle is permanently excluded and cannot be enabled.
        func setApplicationCaptureEnabled(_ enabled: Bool, bundleIdentifier: String?) {
            guard let bundleIdentifier else { return }
            let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            guard normalized.caseInsensitiveCompare(ProductIdentity.bundleIdentifier) != .orderedSame else {
                return
            }
            guard canEditMonitoringRules() else { return }

            var applications = configuredExcludedApplications
            if enabled {
                applications.removeAll {
                    $0.caseInsensitiveCompare(normalized) == .orderedSame
                }
            } else if !applications.contains(where: {
                $0.caseInsensitiveCompare(normalized) == .orderedSame
            }) {
                applications.append(normalized)
            }

            settingsDraft.excludedApplicationsText = applications
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .joined(separator: "\n")
            saveSettings()
        }

        func hideWebsiteInEveryShare(_ host: String) {
            let normalized = SharingSubjectKey.normalizedHost(host)
            guard !normalized.isEmpty else { return }
            setSharingVisibility(.hidden, for: SharingSubjectKey.website(host: normalized))
        }

        private func canEditMonitoringRules() -> Bool {
            guard !settingsHaveChanges else {
                alert = DashboardAlert(
                    kind: .information,
                    title: "Save or discard Settings changes first",
                    message:
                        "A monitoring rule cannot be changed while the Settings page has unrelated unsaved edits."
                )
                return false
            }
            return true
        }

        private var configuredExcludedDomains: [String] {
            settingsDraft.excludedDomainsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        private var configuredExcludedApplications: [String] {
            settingsDraft.excludedApplicationsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
#endif
