#if os(macOS)
    import Foundation
    import LocalHistoryCore

    extension DashboardViewModel {
        func isDomainExcludedFromCapture(_ host: String) -> Bool {
            switch settingsDraft.websiteCaptureMode {
            case .excludeListed:
                return URLRedactor.domain(host, matches: configuredExcludedDomains)
            case .includeOnly:
                return !URLRedactor.domain(host, matches: configuredIncludedDomains)
            }
        }

        func isApplicationExcludedFromCapture(_ bundleIdentifier: String) -> Bool {
            let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                return settingsDraft.applicationCaptureMode == .includeOnly
            }
            if normalized.caseInsensitiveCompare(ProductIdentity.bundleIdentifier) == .orderedSame {
                return true
            }
            switch settingsDraft.applicationCaptureMode {
            case .excludeListed:
                return configuredExcludedApplications.contains {
                    $0.caseInsensitiveCompare(normalized) == .orderedSame
                }
            case .includeOnly:
                return !configuredIncludedApplications.contains {
                    $0.caseInsensitiveCompare(normalized) == .orderedSame
                }
            }
        }

        /// Updates the recorder's persistent website capture policy from the Activity screen.
        /// Existing sealed history is not rewritten; changes affect future events only.
        func setDomainCaptureEnabled(_ enabled: Bool, host: String) {
            let normalized = SharingSubjectKey.normalizedHost(host)
            guard !normalized.isEmpty else { return }
            guard canEditMonitoringRules() else { return }

            switch settingsDraft.websiteCaptureMode {
            case .excludeListed:
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

            case .includeOnly:
                var domains = configuredIncludedDomains
                if enabled {
                    if !domains.contains(where: {
                        SharingSubjectKey.normalizedHost($0) == normalized
                    }) {
                        domains.append(normalized)
                    }
                } else {
                    domains.removeAll {
                        SharingSubjectKey.normalizedHost($0) == normalized
                    }
                }
                settingsDraft.includedDomainsText = domains.sorted().joined(separator: "\n")
            }
            saveSettings()
        }

        /// Updates the recorder's persistent application capture policy from the Activity screen.
        /// Goalong's own bundle is permanently excluded and cannot be enabled.
        func setApplicationCaptureEnabled(_ enabled: Bool, bundleIdentifier: String?) {
            guard let bundleIdentifier else { return }
            let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            guard normalized.caseInsensitiveCompare(ProductIdentity.bundleIdentifier) != .orderedSame else {
                return
            }
            guard canEditMonitoringRules() else { return }

            switch settingsDraft.applicationCaptureMode {
            case .excludeListed:
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

            case .includeOnly:
                var applications = configuredIncludedApplications
                if enabled {
                    if !applications.contains(where: {
                        $0.caseInsensitiveCompare(normalized) == .orderedSame
                    }) {
                        applications.append(normalized)
                    }
                } else {
                    applications.removeAll {
                        $0.caseInsensitiveCompare(normalized) == .orderedSame
                    }
                }
                settingsDraft.includedApplicationsText = applications
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    .joined(separator: "\n")
            }
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
            lines(settingsDraft.excludedDomainsText)
        }

        private var configuredIncludedDomains: [String] {
            lines(settingsDraft.includedDomainsText)
        }

        private var configuredExcludedApplications: [String] {
            lines(settingsDraft.excludedApplicationsText)
        }

        private var configuredIncludedApplications: [String] {
            lines(settingsDraft.includedApplicationsText)
        }

        private func lines(_ value: String) -> [String] {
            value
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
#endif
