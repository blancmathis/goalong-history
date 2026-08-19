#if os(macOS)
    import Foundation
    import LocalHistoryCore

    extension DashboardViewModel {
        func isDomainExcludedFromCapture(_ host: String) -> Bool {
            URLRedactor.domain(host, matches: configuredExcludedDomains)
        }

        /// Updates the recorder's persistent excluded-domain list from the Activity screen.
        /// Existing sealed history is not rewritten; disabling capture affects future events.
        func setDomainCaptureEnabled(_ enabled: Bool, host: String) {
            let normalized = SharingSubjectKey.normalizedHost(host)
            guard !normalized.isEmpty else { return }
            guard !settingsHaveChanges else {
                alert = DashboardAlert(
                    kind: .information,
                    title: "Save or discard Settings changes first",
                    message:
                        "A website capture rule cannot be changed while the Settings page has unrelated unsaved edits."
                )
                return
            }

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

        func hideWebsiteInEveryShare(_ host: String) {
            let normalized = SharingSubjectKey.normalizedHost(host)
            guard !normalized.isEmpty else { return }
            setSharingVisibility(.hidden, for: SharingSubjectKey.website(host: normalized))
        }

        private var configuredExcludedDomains: [String] {
            settingsDraft.excludedDomainsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
#endif
