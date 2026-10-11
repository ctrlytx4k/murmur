import AppKit

/// What happens to a transcript before it is typed: custom words, and snippet triggers.
public nonisolated enum TextProcessor {
    /// Replaces each spoken phrase with its written form, whole words only, any case.
    /// An entry scoped to named apps only applies when the text is going to one of them.
    public static func applyDictionary(_ entries: [DictionaryEntry], to text: String, app: String?) -> String {
        var result = text
        // Longest phrases first, so "post gres sequel" wins over "post gres".
        for entry in entries.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            let scope = entry.scope.trimmingCharacters(in: .whitespaces)
            if !scope.isEmpty, scope.caseInsensitiveCompare("All apps") != .orderedSame {
                guard let app, scope.localizedCaseInsensitiveContains(app) else { continue }
            }
            let spoken = entry.spoken.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: spoken).replacingOccurrences(of: "\\ ", with: "\\s+").replacingOccurrences(of: " ", with: "\\s+") + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.written))
        }
        return result
    }

    /// A take that is exactly a trigger phrase, or "insert <trigger>", stands for its snippet.
    public static func snippet(for text: String, in snippets: [Snippet]) -> Snippet? {
        func normalize(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "’", with: "'")
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "'" }
                .map(String.init).joined()
                .split(separator: " ").joined(separator: " ")
        }
        var said = normalize(text)
        if said.hasPrefix("insert ") { said = String(said.dropFirst("insert ".count)) }
        guard !said.isEmpty else { return nil }
        return snippets.first { normalize($0.trigger) == said }
    }

    /// Fills {date}, {time} and {clipboard}.
    @MainActor
    public static func expand(_ text: String, now: Date, clipboard: String? = NSPasteboard.general.string(forType: .string)) -> String {
        text.replacingOccurrences(of: "{date}", with: now.formatted(date: .long, time: .omitted))
            .replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
            .replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
    }
}
