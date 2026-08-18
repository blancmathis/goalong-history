import Foundation

public enum ActivityAgentDigestRenderer {
    public static func render(_ analysis: ActivityDayAnalysis, tokenBudget: Int) -> String {
        var writer = BudgetWriter(tokenBudget: tokenBudget)
        let day = dayFormatter.string(from: analysis.dayStart)
        _ = writer.append("# LocalHistory day brief — \(day)")
        _ = writer.append("summary: \(analysis.headline)")
        _ = writer.append(
            "active=\(duration(analysis.activeSeconds)); work=\(duration(analysis.workSeconds)); private=\(analysis.coverage.privateMinuteCount)m; blocks=\(analysis.focusBlocks.count); sites=\(analysis.sites.count); events=\(analysis.coverage.sourceEventCount)↓\(analysis.coverage.representativeMinuteCount) representative minutes"
        )

        if !analysis.focusBlocks.isEmpty {
            _ = writer.append("\n## Focus blocks")
            for block in analysis.focusBlocks {
                let apps = block.applications.prefix(3).joined(separator: ",")
                let hosts = block.hosts.prefix(3).joined(separator: ",")
                var line = "- \(timeFormatter.string(from: block.start))–\(timeFormatter.string(from: block.end)) \(duration(block.activeSeconds)) | \(block.title)"
                let context = [apps.isEmpty ? nil : "apps=\(apps)", hosts.isEmpty ? nil : "sites=\(hosts)"]
                    .compactMap { $0 }
                    .joined(separator: "; ")
                if !context.isEmpty { line += " [\(context)]" }
                guard writer.append(line) else { break }
                if let request = block.requestSnippets.first {
                    _ = writer.append("  request: \(request)")
                } else if let context = block.contextSnippets.first {
                    _ = writer.append("  context: \(context)")
                } else if !block.pageTitles.isEmpty {
                    _ = writer.append("  pages: \(block.pageTitles.prefix(2).joined(separator: " | "))")
                }
            }
        }

        if !analysis.requests.isEmpty, writer.remainingTokens > 120 {
            _ = writer.append("\n## Requests / intentions")
            for request in analysis.requests {
                let location = request.host ?? request.application ?? "local context"
                guard writer.append("- \(timeFormatter.string(from: request.firstSeen)) | \(request.text) [\(location)]") else {
                    break
                }
            }
        }

        if !analysis.sites.isEmpty, writer.remainingTokens > 100 {
            _ = writer.append("\n## Sites")
            for site in analysis.sites {
                let pageNames = site.pages.prefix(3).map(\.title).joined(separator: " | ")
                var line = "- \(site.host) \(duration(site.activeSeconds)); visits=\(site.visitCount); pages=\(site.pageCount)"
                if !pageNames.isEmpty { line += ": \(pageNames)" }
                guard writer.append(line) else { break }
            }
        }

        if !analysis.applications.isEmpty, writer.remainingTokens > 80 {
            _ = writer.append("\n## Applications")
            let compact = analysis.applications.prefix(10).map {
                "\($0.name)=\(duration($0.activeSeconds))"
            }.joined(separator: "; ")
            _ = writer.append(compact)
        }

        if !analysis.contextHighlights.isEmpty, writer.remainingTokens > 120 {
            _ = writer.append("\n## Additional visible context")
            for item in analysis.contextHighlights {
                guard writer.append("- \(item.text)") else { break }
            }
        }

        _ = writer.append("\n## Coverage")
        var coverageLine =
            "semantic_snapshots=\(analysis.coverage.semanticSnapshotCount); rich_context=\(analysis.coverage.semanticContextEnabledInData ? "present" : "not present")"
        if let first = analysis.coverage.sourceFirstSequence,
            let last = analysis.coverage.sourceLastSequence
        {
            coverageLine += "; source_chain=\(first)-\(last)"
        }
        if let hash = analysis.coverage.sourceLastEventHash {
            coverageLine += "; last_event_hash=\(hash.prefix(16))…"
        }
        coverageLine +=
            "; private periods expose no content. Durations are minute-level foreground estimates, not billing-grade time tracking."
        _ = writer.append(coverageLine)
        return writer.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private struct BudgetWriter {
        let tokenBudget: Int
        private(set) var text = ""

        init(tokenBudget: Int) {
            self.tokenBudget = max(200, tokenBudget)
        }

        var remainingTokens: Int {
            max(0, tokenBudget - ActivityAnalysisEngine.estimatedTokens(text))
        }

        mutating func append(_ line: String) -> Bool {
            let candidate = text.isEmpty ? line : text + "\n" + line
            guard ActivityAnalysisEngine.estimatedTokens(candidate) <= tokenBudget else { return false }
            text = candidate
            return true
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func duration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let hours = value / 3_600
        let minutes = (value % 3_600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}
