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

    /// Written for guided generation: the model fills a `summary` field and a
    /// list of sections, and the app assembles the markdown (ADR-0006). So
    /// these instructions say nothing about headings, code fences or output
    /// format — telling a model to "output markdown only" while handing it a
    /// schema is the kind of contradiction a small on-device model handles
    /// badly. `summary` is the note's opening paragraph, which is why no Preset
    /// asks for a Summary *section*: it would just repeat it.
    private static let shared = """
        You write notes from a diarized transcript. The transcript labels the note-taker \
        "Me" and other speakers "Speaker 1", "Speaker 2", etc. A list of participant names \
        may be provided as hints. \(namingRule) \
        Base every statement on the transcript; never invent facts, decisions, or action \
        items it does not support. Write clear, plain English, and prefer the transcript's \
        own words for names, numbers, dates and commitments. Produce one section for each \
        heading listed below, in that order, skipping any heading the transcript has \
        nothing for rather than padding it.
        """

    public static let defaults: [Preset] = [
        Preset(name: "Meeting", prompt: """
            \(shared)

            Headings: Key points, Decisions, Action items (with owner and due date where \
            stated), Open questions.
            """),
        Preset(name: "Lecture", prompt: """
            \(shared)

            Headings: Topics covered, Key concepts and definitions, Examples given, \
            Follow-up questions.
            """),
        Preset(name: "Interview", prompt: """
            \(shared)

            Headings: Background, Questions and answers, Notable quotes, Follow-ups.
            """),
        Preset(name: "Training", prompt: """
            \(shared)

            Headings: Skills and procedures taught, Steps to remember, Resources \
            mentioned, Action items.
            """),
    ]
}
