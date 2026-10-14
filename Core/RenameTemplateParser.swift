import Foundation

struct RenameTemplateParser {
    enum Segment {
        case pattern(String)
        case literal(String)
    }
    enum TemplateError: LocalizedError {
        case unclosedQuote
        var errorDescription: String? {
            "Close the double quotes around literal text, e.g. \"abc\"."
        }
    }
    /// Quotes delimit literal text; the delimiters themselves are not emitted.
    static func segments(of template: String) throws -> [Segment] {
        var segments: [Segment] = []
        var buffer = ""
        var isQuoted = false
        for character in template {
            if character == "\"" {
                segments.append(isQuoted ? .literal(buffer) : .pattern(buffer))
                buffer = ""
                isQuoted.toggle()
            } else {
                buffer.append(character)
            }
        }
        guard !isQuoted else { throw TemplateError.unclosedQuote }
        segments.append(.pattern(buffer))
        return segments
    }
    static func render(template: String, date: Date, originalStem: String,
                       sequenceIndex: Int, fileExtension: String) -> String {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        var replacements = [
            "YYYY": String(format: "%04d", year),
            "YY": String(format: "%02d", year % 100),
            "MM": String(format: "%02d", calendar.component(.month, from: date)),
            "DD": String(format: "%02d", calendar.component(.day, from: date)),
            "hh": String(format: "%02d", calendar.component(.hour, from: date)),
            "mm": String(format: "%02d", calendar.component(.minute, from: date)),
            "ss": String(format: "%02d", calendar.component(.second, from: date)),
            "[original]": originalStem
        ]
        for width in 1...5 {
            let maximum = [9, 99, 999, 9999, 99999][width - 1]
            let value = ((max(sequenceIndex, 1) - 1) % maximum) + 1
            replacements["[s\(width)]"] = String(format: "%0\(width)d", value)
        }
        // Inserted original names and quoted text must never become tokens.
        let tokens = ["[original]", "[s1]", "[s2]", "[s3]", "[s4]", "[s5]",
                      "YYYY", "YY", "MM", "DD", "hh", "mm", "ss"]
        let segments = (try? segments(of: template)) ?? [.literal(template)]
        let result = segments.map { segment -> String in
            switch segment {
            case .literal(let text): return text
            case .pattern(let pattern):
                var output = ""
                var index = pattern.startIndex
                while index < pattern.endIndex {
                    if let token = tokens.first(where: { pattern[index...].hasPrefix($0) }) {
                        output += replacements[token]!
                        index = pattern.index(index, offsetBy: token.count)
                    } else {
                        output.append(pattern[index])
                        index = pattern.index(after: index)
                    }
                }
                return output
            }
        }.joined()
        return fileExtension.isEmpty ? result : "\(result).\(fileExtension)"
    }
}
