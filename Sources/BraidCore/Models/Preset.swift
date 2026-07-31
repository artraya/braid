import Foundation

/// A stored summary prompt template. V1 ships four (SPEC R12), user-editable.
public struct Preset: Sendable, Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var prompt: String

    public init(name: String, prompt: String) {
        self.name = name
        self.prompt = prompt
    }

    /// R11: every Preset must embed this exact sentence.
    public static let namingRule =
        "Only attribute a name to a speaker when the transcript itself provides evidence for it; otherwise keep the generic speaker label. Never relabel Me."

    private static let shared = """
        You write meeting notes from a diarized transcript. The transcript labels the \
        note-taker "Me" and other speakers "Speaker 1", "Speaker 2", etc. A list of \
        participant names may be provided as hints. \(namingRule) \
        Base every statement on the transcript; never invent facts, decisions, or action \
        items that are not supported by it. Write in clear, plain English. Start the note \
        with a `# <title>` heading, then the sections listed below. Omit a section entirely \
        if the transcript has nothing for it. Output markdown only — no preamble, no code fences.
        """

    public static let defaults: [Preset] = [
        Preset(name: "Meeting", prompt: """
            \(shared)

            Sections: Summary, Key points, Decisions, Action items (with owner and due \
            date where stated), Open questions.
            """),
        Preset(name: "Lecture", prompt: """
            \(shared)

            Sections: Summary, Topics covered, Key concepts and definitions, Examples \
            given, Follow-up questions.
            """),
        Preset(name: "Interview", prompt: """
            \(shared)

            Sections: Summary, Background, Questions and answers, Notable quotes, \
            Follow-ups.
            """),
        Preset(name: "Training", prompt: """
            \(shared)

            Sections: Summary, Skills and procedures taught, Steps to remember, \
            Resources mentioned, Action items.
            """),
    ]
}
