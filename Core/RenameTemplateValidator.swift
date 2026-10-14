import Foundation

struct RenameTemplateValidationResult {
    let isValid: Bool
    let errorMessage: String?
    let warningMessage: String?
}

struct RenameTemplateValidator {
    static func validate(_ template: String) -> RenameTemplateValidationResult {
        guard !template.isEmpty else {
            return invalid("The filename template is empty.")
        }
        let segments: [RenameTemplateParser.Segment]
        do {
            segments = try RenameTemplateParser.segments(of: template)
        } catch {
            return invalid(error.localizedDescription)
        }
        let patterns = segments.compactMap { segment -> String? in
            if case .pattern(let text) = segment { return text }
            return nil
        }
        let known = ["[original]", "[s1]", "[s2]", "[s3]", "[s4]", "[s5]"]
        let regex = try! NSRegularExpression(pattern: #"\[[^\]]+\]"#)
        // Bracket-like strings inside quotes are ordinary text, not tokens.
        for pattern in patterns {
            let range = NSRange(pattern.startIndex..<pattern.endIndex, in: pattern)
            for match in regex.matches(in: pattern, range: range) {
                guard let range = Range(match.range, in: pattern) else { continue }
                let token = String(pattern[range])
                guard known.contains(token) else {
                    return invalid("Unsupported token: \(token)")
                }
            }
        }
        let hasUniqueToken = patterns.contains { pattern in
            known.contains { pattern.contains($0) }
        }
        let warning = hasUniqueToken ? nil :
            "Filenames may conflict. Add a sequence token [s1]–[s5] or include [original]."
        return RenameTemplateValidationResult(isValid: true, errorMessage: nil, warningMessage: warning)
    }
    private static func invalid(_ message: String) -> RenameTemplateValidationResult {
        RenameTemplateValidationResult(isValid: false, errorMessage: message, warningMessage: nil)
    }
}
