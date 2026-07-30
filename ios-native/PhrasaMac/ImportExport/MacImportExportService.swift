import Foundation
import PDFKit
import PhrasaDomain

enum MacImportExportLimits {
    static let maximumFileSize = 15 * 1_024 * 1_024
    static let maximumLibraryBackupSize = 100 * 1_024 * 1_024
    static let maximumPDFPages = 500
    static let maximumExtractedCharacters = 500_000
}

enum MacScriptImportError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge(maximumBytes: Int)
    case unsupportedFileType(String)
    case unreadableFile
    case unreadableText
    case unreadablePDF
    case passwordProtectedPDF
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(maximumBytes):
            let megabytes = maximumBytes / 1_024 / 1_024
            return "That file is too large. Choose a file smaller than \(megabytes) MB."
        case let .unsupportedFileType(fileExtension):
            let type = fileExtension.isEmpty ? "unknown" : ".\(fileExtension)"
            return "Phrasa cannot import \(type) files yet. Choose a text, Markdown, or PDF file."
        case .unreadableFile:
            return "Phrasa could not open that file. It may have moved or you may not have permission to read it."
        case .unreadableText:
            return "Phrasa could not read the text in that file. Save it as UTF-8 text and try again."
        case .unreadablePDF:
            return "Phrasa could not read that PDF. The file may be damaged or use an unsupported PDF format."
        case .passwordProtectedPDF:
            return "That PDF is password protected. Remove the password and try importing it again."
        case .emptyDocument:
            return "That file does not contain any readable text."
        }
    }
}

struct MacScriptImportService: Sendable {
    func importFile(at url: URL) throws -> ScriptDocument {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               fileSize > MacImportExportLimits.maximumFileSize {
                throw MacScriptImportError.fileTooLarge(
                    maximumBytes: MacImportExportLimits.maximumFileSize
                )
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try importData(data, filename: url.lastPathComponent)
        } catch let error as MacScriptImportError {
            throw error
        } catch {
            throw MacScriptImportError.unreadableFile
        }
    }

    func importData(_ data: Data, filename: String) throws -> ScriptDocument {
        guard data.count <= MacImportExportLimits.maximumFileSize else {
            throw MacScriptImportError.fileTooLarge(
                maximumBytes: MacImportExportLimits.maximumFileSize
            )
        }

        let fileExtension = (filename as NSString).pathExtension.lowercased()
        let rawText: String

        switch fileExtension {
        case "txt", "md", "markdown":
            guard let decodedText = decodeText(data) else {
                throw MacScriptImportError.unreadableText
            }
            rawText = decodedText
        case "pdf":
            rawText = try extractText(fromPDFData: data)
        default:
            throw MacScriptImportError.unsupportedFileType(fileExtension)
        }

        let body = cleanImportedText(rawText)
        guard !body.isEmpty else {
            throw MacScriptImportError.emptyDocument
        }

        return ScriptDocument(
            title: importTitle(from: filename),
            body: body,
            source: .upload
        )
    }

    private func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        return nil
    }

    private func extractText(fromPDFData data: Data) throws -> String {
        guard let document = PDFDocument(data: data) else {
            throw MacScriptImportError.unreadablePDF
        }
        guard !document.isLocked else {
            throw MacScriptImportError.passwordProtectedPDF
        }

        var extractedText = ""
        let pageCount = min(document.pageCount, MacImportExportLimits.maximumPDFPages)

        for pageIndex in 0..<pageCount {
            guard let pageText = document.page(at: pageIndex)?.string, !pageText.isEmpty else {
                continue
            }
            if !extractedText.isEmpty {
                extractedText.append("\n\n")
            }
            let remaining = MacImportExportLimits.maximumExtractedCharacters - extractedText.count
            guard remaining > 0 else { break }
            extractedText.append(contentsOf: pageText.prefix(remaining))
            if extractedText.count >= MacImportExportLimits.maximumExtractedCharacters {
                break
            }
        }
        return extractedText
    }

    private func cleanImportedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[\t ]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importTitle(from filename: String) -> String {
        let title = (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled script" : title
    }
}

enum MacScriptExportError: Error, Equatable, LocalizedError, Sendable {
    case unableToCreateExport
    case libraryBackupTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .unableToCreateExport:
            return "Phrasa could not create the export file. Your script has not been changed."
        case let .libraryBackupTooLarge(maximumBytes):
            let megabytes = maximumBytes / 1_024 / 1_024
            return "This library is too large for one backup file. Phrasa did not create an incomplete backup. The backup limit is \(megabytes) MB."
        }
    }
}

enum MacLibraryBackupImportError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge(maximumBytes: Int)
    case invalidBackup
    case invalidLibraryStructure
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(maximumBytes):
            return "That backup is too large. Choose a backup no larger than \(maximumBytes / 1_024 / 1_024) MB."
        case .invalidBackup:
            return "That file is not a valid Phrasa library backup."
        case .invalidLibraryStructure:
            return "That backup contains duplicate items or a script assigned to a missing folder. Nothing was restored."
        case .unsupportedVersion:
            return "That backup was created by a newer version of Phrasa. Update the app and try again."
        }
    }
}

enum MacLibraryBackupJSONCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value)
                ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a Phrasa date timestamp."
            )
        }
        return decoder
    }
}

enum MacLibraryBackupNormalizer {
    static func normalized(_ snapshot: LibrarySnapshot) -> LibrarySnapshot {
        var usedFolderIDs: Set<UUID> = []
        var firstFolderIDByOriginalID: [UUID: UUID] = [:]
        let folders = snapshot.folders.map { folder in
            var normalized = folder
            while usedFolderIDs.contains(normalized.id) { normalized.id = UUID() }
            usedFolderIDs.insert(normalized.id)
            firstFolderIDByOriginalID[folder.id] = firstFolderIDByOriginalID[folder.id]
                ?? normalized.id
            return normalized
        }

        var usedScriptIDs: Set<UUID> = []
        let scripts = snapshot.scripts.map { script in
            var normalized = script
            while usedScriptIDs.contains(normalized.id) { normalized.id = UUID() }
            usedScriptIDs.insert(normalized.id)
            normalized.folderID = script.folderID.flatMap { firstFolderIDByOriginalID[$0] }

            var seenTags: Set<String> = []
            normalized.tags = script.tags.filter { seenTags.insert($0).inserted }

            var seenOutlineIDs: Set<UUID> = []
            normalized.outline = script.outline.map { point in
                var normalizedPoint = point
                while seenOutlineIDs.contains(normalizedPoint.id) {
                    normalizedPoint.id = UUID()
                }
                seenOutlineIDs.insert(normalizedPoint.id)
                return normalizedPoint
            }
            return normalized
        }

        return LibrarySnapshot(
            schemaVersion: snapshot.schemaVersion,
            scripts: scripts,
            folders: folders,
            settings: snapshot.settings,
            seeded: snapshot.seeded
        )
    }
}

struct MacLibraryExportEnvelope: Codable, Sendable {
    let format: String
    let version: Int
    let exportedAt: Date
    let schemaVersion: Int
    let scripts: [ScriptDocument]
    let folders: [ScriptFolder]
    let settings: ReaderSettings
    let seeded: Bool

    init(snapshot: LibrarySnapshot, exportedAt: Date) {
        format = "phrasa-library"
        version = 1
        self.exportedAt = exportedAt
        schemaVersion = snapshot.schemaVersion
        scripts = snapshot.scripts
        folders = snapshot.folders
        settings = snapshot.settings
        seeded = snapshot.seeded
    }
}

struct MacScriptExportEnvelope: Codable, Sendable {
    let format: String
    let version: Int
    let exportedAt: Date
    let script: ScriptDocument

    init(script: ScriptDocument, exportedAt: Date) {
        format = "phrasa-script"
        version = 1
        self.exportedAt = exportedAt
        self.script = script
    }
}

struct MacExportedDocument: Equatable, Sendable {
    let suggestedFilename: String
    let mimeType: String
    let data: Data
}

struct MacLibraryBackupImportService: Sendable {
    func importFile(at url: URL) throws -> LibrarySnapshot {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               fileSize > MacImportExportLimits.maximumLibraryBackupSize {
                throw MacLibraryBackupImportError.fileTooLarge(
                    maximumBytes: MacImportExportLimits.maximumLibraryBackupSize
                )
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try importData(data)
        } catch let error as MacLibraryBackupImportError {
            throw error
        } catch {
            throw MacLibraryBackupImportError.invalidBackup
        }
    }

    func importData(_ data: Data) throws -> LibrarySnapshot {
        guard data.count <= MacImportExportLimits.maximumLibraryBackupSize else {
            throw MacLibraryBackupImportError.fileTooLarge(
                maximumBytes: MacImportExportLimits.maximumLibraryBackupSize
            )
        }
        let decoder = MacLibraryBackupJSONCoding.makeDecoder()
        guard let envelope = try? decoder.decode(MacLibraryExportEnvelope.self, from: data),
              envelope.format == "phrasa-library" else {
            throw MacLibraryBackupImportError.invalidBackup
        }
        guard envelope.version == 1, envelope.schemaVersion == 1 else {
            throw MacLibraryBackupImportError.unsupportedVersion
        }
        let scriptIDs = Set(envelope.scripts.map(\.id))
        let folderIDs = Set(envelope.folders.map(\.id))
        guard scriptIDs.count == envelope.scripts.count,
              folderIDs.count == envelope.folders.count,
              envelope.scripts.allSatisfy({ script in
                  let outlineIDs = Set(script.outline.map(\.id))
                  return (script.folderID.map(folderIDs.contains) ?? true)
                      && outlineIDs.count == script.outline.count
                      && Set(script.tags).count == script.tags.count
              }) else {
            throw MacLibraryBackupImportError.invalidLibraryStructure
        }
        var settings = envelope.settings
        settings.normalize()
        return LibrarySnapshot(
            schemaVersion: envelope.schemaVersion,
            scripts: envelope.scripts,
            folders: envelope.folders,
            settings: settings,
            seeded: true
        )
    }
}

struct MacScriptExportService: Sendable {
    func plainText(script: ScriptDocument) -> MacExportedDocument {
        var text = "\(displayTitle(for: script))\n\n\(script.body)"
        let outline = script.outline.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !outline.isEmpty {
            text.append("\n\n---\nOutline:\n")
            text.append(outline.map { point in
                let pointText = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let note = point.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if pointText.isEmpty { return "- Note: \(note)" }
                return note.isEmpty ? "- \(pointText)" : "- \(pointText) (\(note))"
            }.joined(separator: "\n"))
        }
        if !text.hasSuffix("\n") {
            text.append("\n")
        }
        return MacExportedDocument(
            suggestedFilename: "\(safeFilename(displayTitle(for: script))).txt",
            mimeType: "text/plain",
            data: Data(text.utf8)
        )
    }

    func scriptJSON(
        script: ScriptDocument,
        exportedAt: Date = .now
    ) throws -> MacExportedDocument {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(
                MacScriptExportEnvelope(script: script, exportedAt: exportedAt)
            )
            return MacExportedDocument(
                suggestedFilename: "\(safeFilename(displayTitle(for: script))).json",
                mimeType: "application/json",
                data: data
            )
        } catch {
            throw MacScriptExportError.unableToCreateExport
        }
    }

    func libraryBackup(
        snapshot: LibrarySnapshot,
        exportedAt: Date = .now
    ) throws -> MacExportedDocument {
        do {
            let normalized = MacLibraryBackupNormalizer.normalized(snapshot)
            let data = try MacLibraryBackupJSONCoding.makeEncoder().encode(
                MacLibraryExportEnvelope(snapshot: normalized, exportedAt: exportedAt)
            )
            guard data.count <= MacImportExportLimits.maximumLibraryBackupSize else {
                throw MacScriptExportError.libraryBackupTooLarge(
                    maximumBytes: MacImportExportLimits.maximumLibraryBackupSize
                )
            }
            let filenameDate = exportedAt.formatted(
                .iso8601.year().month().day().dateSeparator(.dash)
            )
            return MacExportedDocument(
                suggestedFilename: "phrasa-library-\(filenameDate).json",
                mimeType: "application/json",
                data: data
            )
        } catch let error as MacScriptExportError {
            throw error
        } catch {
            throw MacScriptExportError.unableToCreateExport
        }
    }

    private func displayTitle(for script: ScriptDocument) -> String {
        let title = script.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled script" : title
    }

    private func safeFilename(_ title: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        let cleanedScalars = title.unicodeScalars.map { scalar -> Character in
            forbiddenCharacters.contains(scalar) ? "-" : Character(scalar)
        }
        let cleaned = String(cleanedScalars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Untitled script" : String(cleaned.prefix(100))
    }
}
