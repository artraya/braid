import Foundation

/// Turns a language model's freeform reply into a Note body.
///
/// Apple's path does not need this: a generation schema constrains the model,
/// so the fields arrive typed. An open-weights model has no such constraint, so
/// it is *asked* for JSON and frequently returns something adjacent to it — a
/// reasoning block first, a code fence around it, a bold title echoing the
/// prompt, or JSON with a bracket in the wrong place. All of that is
/// recoverable, and the alternative to recovering it is showing the user raw
/// JSON in their vault.
///
/// Lives in BraidCore rather than beside the MLX summariser so it can be tested
/// in the fast loop: `swift build` cannot compile MLX's Metal shaders, so
/// anything in that target is out of reach of `swift test`.
public enum ModelReply {

    /// What one reply yielded: the Note body, and the title for it if the model
    /// gave a usable one (R9a).
    public struct Reply: Equatable {
        public var body: String
        public var title: String?
    }

    /// The Note body, from whatever the model actually said.
    public static func note(from raw: String) -> String {
        parse(raw).body
    }

    /// Body and title together.
    public static func parse(_ raw: String) -> Reply {
        let text = clean(raw)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end else {
            // Prose: the model ignored the contract. Still usable as a note,
            // but there is no field to read a title out of.
            return Reply(body: text, title: nil)
        }
        let candidate = String(text[start...end])

        if let data = candidate.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rendered = render(object) {
            return Reply(body: rendered,
                         title: Session.cleanTitle(object["title"] as? String))
        }
        // Malformed JSON is the common failure, not the rare one: a 4B model
        // closed a `bullets` array with `}` instead of `]` on the first real
        // run. Everything needed is still in the text, so it is read out by
        // pattern rather than thrown away.
        let title = Session.cleanTitle(field("title", in: candidate))
        if let salvaged = renderByPattern(candidate) {
            return Reply(body: salvaged, title: title)
        }
        // Last resort: the summary alone, never the raw JSON.
        return Reply(body: summaryField(candidate) ?? text, title: title)
    }

    /// Strips the wrapping a small model puts around its answer. Public because
    /// the map stage of a long Session wants tidy prose without the JSON step.
    public static func clean(_ raw: String) -> String {
        var text = raw

        // Reasoning models emit their scratchpad first.
        while let open = text.range(of: "<think>"),
              let close = text.range(of: "</think>"), close.upperBound > open.lowerBound {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A whole-reply code fence.
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n")
        }

        // A title the Note's filename already carries (R9). Models write it as
        // an `# H1`, or as a bold pseudo-heading echoing back whatever title
        // they were given.
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            let isTitleHeading = trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ")
            let isBoldTitle = trimmed.hasPrefix("**") && trimmed.hasSuffix("**")
                && trimmed.count < 80 && !trimmed.contains(". ")
            if trimmed.isEmpty || isTitleHeading || isBoldTitle {
                lines.removeFirst()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func render(_ object: [String: Any]) -> String? {
        var out = ((object["summary"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for section in (object["sections"] as? [[String: Any]]) ?? [] {
            let heading = ((section["heading"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bullets = ((section["bullets"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !heading.isEmpty, !bullets.isEmpty else { continue }
            out += "\n\n## \(heading)\n" + bullets.map { "- \($0)" }.joined(separator: "\n")
        }
        let assembled = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return assembled.isEmpty ? nil : assembled
    }

    /// Reads the fields out of JSON too broken to decode.
    static func renderByPattern(_ json: String) -> String? {
        guard let summary = summaryField(json) else { return nil }
        var out = summary

        let headings = matches(#""heading"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: json)
        let spans = ranges(#""heading"\s*:\s*""#, in: json)
        for (index, heading) in headings.enumerated() {
            guard index < spans.count else { break }
            let from = spans[index].upperBound
            let to = index + 1 < spans.count ? spans[index + 1].lowerBound : json.endIndex
            let body = String(json[from..<to])
            guard let bulletsAt = body.range(of: #""bullets"\s*:"#, options: .regularExpression)
            else { continue }
            let bullets = matches(#""((?:[^"\\]|\\.)*)""#, in: String(body[bulletsAt.upperBound...]))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let name = heading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !bullets.isEmpty else { continue }
            out += "\n\n## \(name)\n" + bullets.map { "- \($0)" }.joined(separator: "\n")
        }
        return out
    }

    static func summaryField(_ json: String) -> String? {
        field("summary", in: json)
    }

    /// One top-level string field, read out of JSON that may not parse.
    static func field(_ name: String, in json: String) -> String? {
        matches(#""\#(name)"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: json).first
            .map { $0.replacingOccurrences(of: "\\\"", with: "\"") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// First capture group of every match.
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: .dotMatchesLineSeparators) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func ranges(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full).compactMap { Range($0.range, in: text) }
    }
}
