import Foundation

public enum PrivacyBoundaryViolation: String, Codable, CaseIterable {
    case rawCharacterAttachedToTypingBurst
    case rawTextMetadataAttachedToTypingBurst
    case detailedContentDuringSuppression
    case semanticContentDuringSuppression
    case semanticContentFromSecureElement
    case secureInputContainsKeyboardDetail
}

/// Defense-in-depth validation for events before persistence and in audits. It does
/// not replace the recorder's early privacy gates; it catches regressions that would
/// otherwise write content after a gate failed.
public enum PrivacyBoundaryValidator {
    public static func violations(in event: HistoryEvent) -> [PrivacyBoundaryViolation] {
        var output: [PrivacyBoundaryViolation] = []

        if event.kind == .typingBurst {
            if let key = event.keyboard?.key, !key.isEmpty {
                output.append(.rawCharacterAttachedToTypingBurst)
            }
            let forbiddenKeys = [
                "characters", "character", "raw_characters", "raw_text",
                "typed_text", "unicode", "text", "value",
            ]
            if event.metadata?.contains(where: { key, value in
                let normalized = key.lowercased()
                let isTextKey = forbiddenKeys.contains(normalized)
                    || normalized.hasSuffix("typed_text")
                    || normalized.hasSuffix("raw_text")
                return isTextKey && !value.isEmpty && value.lowercased() != "false"
            }) == true {
                output.append(.rawTextMetadataAttachedToTypingBurst)
            }
        }

        let semanticPlaintext = [
            event.metadata?["analysis.semantic_text"],
            event.metadata?["semantic.text"],
            event.metadata?["rich_context.text"],
        ].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if event.suppressionReason != nil {
            if event.window != nil || event.element != nil || event.url != nil
                || event.pointer != nil || event.keyboard != nil || event.scroll != nil
            {
                output.append(.detailedContentDuringSuppression)
            }
            if event.semanticContext != nil || semanticPlaintext {
                output.append(.semanticContentDuringSuppression)
            }
        }

        if event.element?.isSecure == true,
            event.semanticContext != nil || semanticPlaintext
        {
            output.append(.semanticContentFromSecureElement)
        }

        if event.suppressionReason == .secureInput,
            event.keyboard != nil
        {
            output.append(.secureInputContainsKeyboardDetail)
        }

        return output
    }
}
