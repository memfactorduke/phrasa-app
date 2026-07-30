import Foundation

public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var scripts: [ScriptDocument]
    public var folders: [ScriptFolder]
    public var settings: ReaderSettings
    public var seeded: Bool

    public init(
        schemaVersion: Int = 1,
        scripts: [ScriptDocument],
        folders: [ScriptFolder],
        settings: ReaderSettings,
        seeded: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.scripts = scripts
        self.folders = folders
        self.settings = settings
        self.seeded = seeded
    }

    public static let empty = LibrarySnapshot(
        scripts: [],
        folders: [],
        settings: .init(),
        seeded: false
    )
}
