import Foundation

public enum ScriptSource: String, Codable, CaseIterable, Sendable {
    case manual
    case upload
    case googleDrive = "gdrive"
}

public struct OutlinePoint: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var note: String

    public init(id: UUID = UUID(), text: String = "", note: String = "") {
        self.id = id
        self.text = text
        self.note = note
    }
}

public struct ScriptDocument: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var source: ScriptSource
    public var folderID: UUID?
    public var tags: [String]
    public var outline: [OutlinePoint]
    public var lastOpenedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "Untitled script",
        body: String = "",
        source: ScriptSource = .manual,
        folderID: UUID? = nil,
        tags: [String] = [],
        outline: [OutlinePoint] = [],
        lastOpenedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled script" : title
        self.body = body
        self.source = source
        self.folderID = folderID
        self.tags = tags
        self.outline = outline
        self.lastOpenedAt = lastOpenedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var wordCount: Int { TextMetrics.wordCount(body) }
    public var estimatedDuration: TimeInterval { TextMetrics.estimatedDuration(body) }
    public var preview: String {
        body.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .prefix(180)
            .description
    }
}

public struct ScriptFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public enum TextMetrics {
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    public static func estimatedDuration(_ text: String, wordsPerMinute: Double = 150) -> TimeInterval {
        guard wordsPerMinute > 0 else { return 0 }
        return Double(wordCount(text)) / wordsPerMinute * 60
    }
}
