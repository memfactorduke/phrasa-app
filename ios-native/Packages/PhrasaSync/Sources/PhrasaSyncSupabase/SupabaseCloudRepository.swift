import Foundation
import Supabase
#if canImport(PhrasaSync)
import PhrasaSync
#endif
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif
// When these sources are embedded into the host app module beside PhrasaSync /
// PhrasaDomain sources, types resolve in-module without an import. Never import
// the host module from embedded package sources (circular).

public actor SupabaseCloudRepository: CloudLibraryRepository {
    private static let pageSize = 250
    private let client: SupabaseClient
    /// Exact `updated_at` JSON strings from the last server representation, keyed
    /// by script id. OCC predicates must use these — not `timestamp(Date)` —
    /// because reformatting a decoded Date can fail `eq` while curl with the
    /// original wire string succeeds.
    private var scriptUpdatedAtWire: [UUID: String] = [:]

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func fetchScripts(accountID: UUID, updatedAfter: Date? = nil) async throws -> [ScriptDocument] {
        var rows: [CloudScriptRow] = []
        var cursor: UUID?
        var expectedTotal: Int?

        while true {
            try await verifyAuthenticatedAccount(accountID)
            let query = client.from("scripts")
                .select(Self.scriptColumns, count: .exact)
                .eq("user_id", value: accountID.uuidString)
            if let updatedAfter {
                _ = query.gt("updated_at", value: Self.timestamp(updatedAfter))
            }
            if let cursor {
                _ = query.gt("id", value: cursor.uuidString)
            }
            let response: PostgrestResponse<[CloudScriptRow]> = try await query
                .order("id")
                .limit(Self.pageSize)
                .execute()
            let reachedEnd = try Self.appendCompleteKeysetPage(
                response.value,
                rowIDs: response.value.map(\.id),
                after: cursor,
                reportedCount: response.count,
                expectedTotal: &expectedTotal,
                accumulated: &rows
            )
            cursor = response.value.last?.id ?? cursor
            if reachedEnd { break }
        }

        try await verifyAuthenticatedAccount(accountID)
        guard Set(rows.map(\.id)).count == rows.count else {
            throw Self.incompleteRemoteSnapshot("fetchScripts.duplicateIDs")
        }
        for row in rows { rememberScriptRow(row) }
        return rows.map(\.document)
    }

    public func fetchScript(id: UUID, accountID: UUID) async throws -> ScriptDocument? {
        try await verifyAuthenticatedAccount(accountID)
        let rows: [CloudScriptRow] = try await client
            .from("scripts")
            .select(Self.scriptColumns)
            .eq("id", value: id.uuidString)
            .eq("user_id", value: accountID.uuidString)
            .limit(1)
            .execute()
            .value
        if let row = rows.first { rememberScriptRow(row) }
        return rows.first?.document
    }

    public func writeScripts(
        _ writes: [CloudScriptWrite],
        accountID: UUID
    ) async throws -> [ScriptDocument] {
        var written: [ScriptDocument] = []
        for write in writes {
            try await verifyAuthenticatedAccount(accountID)
            if let expected = write.expectedRemote {
                written.append(try await updateScript(
                    write,
                    expected: expected,
                    accountID: accountID
                ))
            } else {
                written.append(try await insertScript(write, accountID: accountID))
            }
        }
        return written
    }

    public func deleteScript(expected: ScriptDocument, accountID: UUID) async throws {
        try await verifyAuthenticatedAccount(accountID)
        let query = client
            .from("scripts")
            .delete(returning: .representation)
            .eq("id", value: expected.id.uuidString)
            .eq("user_id", value: accountID.uuidString)
            .eq("updated_at", value: updatedAtOCCValue(id: expected.id, date: expected.updatedAt))
        let deletedRows: [CloudScriptRow] = try await query
            .execute()
            .value

        guard deletedRows.isEmpty else {
            for row in deletedRows { rememberScriptRow(row) }
            return
        }
        // No row is the normal idempotent result when another device already
        // deleted the exact version we observed. Any row still present means
        // that version changed, or its timestamp could not be matched exactly;
        // fail closed instead of deleting data we did not reconcile.
        if try await fetchScript(id: expected.id, accountID: accountID) != nil {
            throw CloudRepositoryError.newerRemoteEdit
        }
    }

    public func fetchFolders(accountID: UUID) async throws -> [ScriptFolder] {
        var rows: [CloudFolderRow] = []
        var cursor: UUID?
        var expectedTotal: Int?

        while true {
            try await verifyAuthenticatedAccount(accountID)
            let query = client
                .from("folders")
                .select("id,name,created_at", count: .exact)
                .eq("user_id", value: accountID.uuidString)
            if let cursor {
                _ = query.gt("id", value: cursor.uuidString)
            }
            let response: PostgrestResponse<[CloudFolderRow]> = try await query
                .order("id")
                .limit(Self.pageSize)
                .execute()
            let reachedEnd = try Self.appendCompleteKeysetPage(
                response.value,
                rowIDs: response.value.map(\.id),
                after: cursor,
                reportedCount: response.count,
                expectedTotal: &expectedTotal,
                accumulated: &rows
            )
            cursor = response.value.last?.id ?? cursor
            if reachedEnd { break }
        }

        try await verifyAuthenticatedAccount(accountID)
        guard Set(rows.map(\.id)).count == rows.count else {
            throw Self.incompleteRemoteSnapshot("fetchFolders.duplicateIDs")
        }
        return rows.map(\.folder)
    }

    public func fetchFolder(id: UUID, accountID: UUID) async throws -> ScriptFolder? {
        try await verifyAuthenticatedAccount(accountID)
        let rows: [CloudFolderRow] = try await client
            .from("folders")
            .select("id,name,created_at")
            .eq("id", value: id.uuidString)
            .eq("user_id", value: accountID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first?.folder
    }

    public func writeFolders(_ writes: [CloudFolderWrite], accountID: UUID) async throws {
        for write in writes {
            try await verifyAuthenticatedAccount(accountID)
            if let expected = write.expectedRemote {
                try await updateFolder(write, expected: expected, accountID: accountID)
            } else {
                try await insertFolder(write, accountID: accountID)
            }
        }
    }

    public func deleteFolder(expected: ScriptFolder, accountID: UUID) async throws {
        try await verifyAuthenticatedAccount(accountID)
        let deletedRows: [CloudFolderRow] = try await client
            .from("folders")
            .delete(returning: .representation)
            .eq("id", value: expected.id.uuidString)
            .eq("user_id", value: accountID.uuidString)
            .eq("name", value: expected.name)
            .eq("created_at", value: Self.timestamp(expected.createdAt))
            .execute()
            .value

        guard deletedRows.isEmpty else { return }
        // No row is the normal idempotent result when another device already
        // deleted the exact generation we observed. Any row still present means
        // the conditional baseline did not match; fail closed whether that was
        // a concurrent rename/recreation or a timestamp-precision mismatch.
        guard try await fetchFolder(id: expected.id, accountID: accountID) == nil else {
            throw CloudRepositoryError.newerRemoteFolder
        }
    }

    public func fetchSettings(accountID: UUID) async throws -> ReaderSettings? {
        try await verifyAuthenticatedAccount(accountID)
        let rows: [CloudSettingsRow] = try await client
            .from("user_settings")
            .select("settings")
            .eq("user_id", value: accountID.uuidString)
            .limit(1)
            .execute()
            .value
        guard var settings = rows.first?.settings.readerSettings else { return nil }
        settings.normalize()
        return settings
    }

    public func saveSettings(_ settings: ReaderSettings, accountID: UUID) async throws {
        try await verifyAuthenticatedAccount(accountID)
        try await client
            .from("user_settings")
            .upsert(
                CloudSettingsMutation(userID: accountID, settings: CloudReaderSettings(settings)),
                onConflict: "user_id",
                returning: .minimal
            )
            .execute()
    }

    private func updateScript(
        _ write: CloudScriptWrite,
        expected: ScriptDocument,
        accountID: UUID
    ) async throws -> ScriptDocument {
        // A metadata-only reconciliation must not fire the content-edit
        // trigger. It either advances last-opened conditionally or accepts the
        // fetched server edit timestamp as authoritative.
        if CloudScriptFingerprint.make(write.desired)
            == CloudScriptFingerprint.make(expected) {
            return try await updateLastOpenedIfNeeded(
                write,
                current: expected,
                accountID: accountID
            )
        }

        do {
            let query = try client
                .from("scripts")
                .update(
                    CloudScriptContentMutation(document: write.desired),
                    returning: .representation
                )
                .eq("id", value: write.desired.id.uuidString)
                .eq("user_id", value: accountID.uuidString)
                .eq("updated_at", value: updatedAtOCCValue(id: write.desired.id, date: expected.updatedAt))
            let rows: [CloudScriptRow] = try await query
                .execute()
                .value
            guard rows.count <= 1 else {
                throw Self.incompleteRemoteSnapshot("updateScript.multipleRows")
            }
            if let row = rows.first {
                rememberScriptRow(row)
                guard CloudScriptFingerprint.make(row.document)
                        == CloudScriptFingerprint.make(write.desired) else {
                    throw CloudRepositoryError.scriptConflict(write.desired)
                }
                return try await updateLastOpenedIfNeeded(
                    write,
                    current: row.document,
                    accountID: accountID
                )
            }
            return try await reconcileScriptWrite(
                write,
                accountID: accountID,
                originalError: nil,
                missingIsConflict: true
            )
        } catch let error as CloudRepositoryError {
            throw error
        } catch {
            return try await reconcileScriptWrite(
                write,
                accountID: accountID,
                originalError: error,
                missingIsConflict: true
            )
        }
    }

    private func updateLastOpenedIfNeeded(
        _ write: CloudScriptWrite,
        current: ScriptDocument,
        accountID: UUID,
        retryCount: Int = 0
    ) async throws -> ScriptDocument {
        guard let desiredOpenedAt = write.desired.lastOpenedAt else { return current }
        // Wire-ms satisfaction: server `.871` must not be rewritten for local
        // `.871xxx`; only a true multi-ms advance issues a write.
        guard CloudScriptOpenUpdate.needsAdvancement(
            desired: desiredOpenedAt,
            current: current.lastOpenedAt
        ) else {
            return current
        }

        let openToWrite = CloudScriptOpenUpdate.valueToWrite(desired: desiredOpenedAt)

        do {
            let rows: [CloudScriptRow] = try await client
                .from("scripts")
                .update(
                    CloudScriptOpenedMutation(lastOpenedAt: openToWrite),
                    returning: .representation
                )
                .eq("id", value: write.desired.id.uuidString)
                .eq("user_id", value: accountID.uuidString)
                .or(
                    CloudScriptOpenUpdate.monotonicOpenOrFilter(
                        openToWrite: openToWrite,
                        timestamp: Self.timestamp
                    )
                )
                .execute()
                .value
            guard rows.count <= 1 else {
                throw Self.incompleteRemoteSnapshot("updateLastOpened.multipleRows")
            }
            if let row = rows.first {
                rememberScriptRow(row)
                guard write.currentMatchesDesired(row.document) else {
                    return try await reconcileLastOpenedWrite(
                        write,
                        accountID: accountID,
                        originalError: nil,
                        retryCount: retryCount
                    )
                }
                return row.document
            }
            return try await reconcileLastOpenedWrite(
                write,
                accountID: accountID,
                originalError: nil,
                retryCount: retryCount
            )
        } catch let error as CloudRepositoryError {
            throw error
        } catch {
            return try await reconcileLastOpenedWrite(
                write,
                accountID: accountID,
                originalError: error,
                retryCount: retryCount
            )
        }
    }

    private func reconcileLastOpenedWrite(
        _ write: CloudScriptWrite,
        accountID: UUID,
        originalError: Error?,
        retryCount: Int
    ) async throws -> ScriptDocument {
        let current: ScriptDocument?
        do {
            current = try await fetchScript(id: write.desired.id, accountID: accountID)
        } catch let repositoryError as CloudRepositoryError {
            throw repositoryError
        } catch {
            throw originalError ?? error
        }
        guard let current else {
            if let originalError { throw originalError }
            throw Self.incompleteRemoteSnapshot("reconcileLastOpened.missing")
        }
        // Content mismatch: fail closed — never return server content that the
        // engine would re-baseline as a successful open write.
        guard CloudScriptFingerprint.make(current)
                == CloudScriptFingerprint.make(write.desired) else {
            throw CloudRepositoryError.scriptConflict(write.desired)
        }
        // Open already covers desired (including concurrent newer open) — OK.
        if write.currentMatchesDesired(current) { return current }
        guard retryCount < 1 else {
            // Production failure mode: PATCH matched zero rows, open still
            // behind, adapter returned current and sync "succeeded" while
            // re-baselining with lagging open. Fail loudly instead.
            throw Self.incompleteRemoteSnapshot("reconcileLastOpened.retryExhausted")
        }
        return try await updateLastOpenedIfNeeded(
            write,
            current: current,
            accountID: accountID,
            retryCount: retryCount + 1
        )
    }

    private func rememberScriptRow(_ row: CloudScriptRow) {
        scriptUpdatedAtWire[row.id] = row.updatedAtWire
    }

    private func updatedAtOCCValue(id: UUID, date: Date) -> String {
        scriptUpdatedAtWire[id] ?? Self.timestamp(date)
    }

    private func insertScript(
        _ write: CloudScriptWrite,
        accountID: UUID
    ) async throws -> ScriptDocument {
        do {
            let rows: [CloudScriptRow] = try await client
                .from("scripts")
                .insert(
                    CloudScriptMutation(userID: accountID, document: write.desired),
                    returning: .representation
                )
                .execute()
                .value
            guard rows.count == 1,
                  let row = rows.first,
                  write.currentMatchesDesired(row.document) else {
                throw Self.incompleteRemoteSnapshot("insertScript.echoMismatch")
            }
            rememberScriptRow(row)
            return row.document
        } catch let error as CloudRepositoryError {
            throw error
        } catch {
            return try await reconcileScriptWrite(
                write,
                accountID: accountID,
                originalError: error,
                missingIsConflict: false
            )
        }
    }

    private func reconcileScriptWrite(
        _ write: CloudScriptWrite,
        accountID: UUID,
        originalError: Error?,
        missingIsConflict: Bool
    ) async throws -> ScriptDocument {
        let current: ScriptDocument?
        do {
            current = try await fetchScript(id: write.desired.id, accountID: accountID)
        } catch let repositoryError as CloudRepositoryError {
            throw repositoryError
        } catch {
            throw originalError ?? error
        }
        if let current {
            guard write.currentMatchesDesired(current) else {
                throw CloudRepositoryError.scriptConflict(write.desired)
            }
            return current
        }
        if missingIsConflict {
            throw CloudRepositoryError.scriptConflict(write.desired)
        }
        if let originalError { throw originalError }
        throw Self.incompleteRemoteSnapshot("reconcileScriptWrite.missingAfterInsert")
    }

    private func updateFolder(
        _ write: CloudFolderWrite,
        expected: ScriptFolder,
        accountID: UUID
    ) async throws {
        do {
            let rows: [CloudFolderRow] = try await client
                .from("folders")
                .update(
                    CloudFolderRenameMutation(folder: write.desired),
                    returning: .representation
                )
                .eq("id", value: write.desired.id.uuidString)
                .eq("user_id", value: accountID.uuidString)
                .eq("name", value: expected.name)
                .eq("created_at", value: Self.timestamp(expected.createdAt))
                .execute()
                .value
            guard rows.count <= 1 else {
                throw Self.incompleteRemoteSnapshot("updateFolder.multipleRows")
            }
            if let row = rows.first {
                guard write.currentMatchesDesired(row.folder) else {
                    throw CloudRepositoryError.folderConflict(
                        device: write.desired,
                        cloud: row.folder
                    )
                }
                return
            }
            try await reconcileFolderWrite(
                write,
                accountID: accountID,
                originalError: nil,
                missingIsConflict: true
            )
        } catch let error as CloudRepositoryError {
            throw error
        } catch {
            try await reconcileFolderWrite(
                write,
                accountID: accountID,
                originalError: error,
                missingIsConflict: true
            )
        }
    }

    private func insertFolder(
        _ write: CloudFolderWrite,
        accountID: UUID
    ) async throws {
        do {
            let rows: [CloudFolderRow] = try await client
                .from("folders")
                .insert(
                    CloudFolderInsertMutation(userID: accountID, folder: write.desired),
                    returning: .representation
                )
                .execute()
                .value
            guard rows.count == 1,
                  let row = rows.first,
                  write.currentMatchesDesired(row.folder) else {
                throw Self.incompleteRemoteSnapshot("insertFolder.echoMismatch")
            }
        } catch let error as CloudRepositoryError {
            throw error
        } catch {
            try await reconcileFolderWrite(
                write,
                accountID: accountID,
                originalError: error,
                missingIsConflict: false
            )
        }
    }

    private func reconcileFolderWrite(
        _ write: CloudFolderWrite,
        accountID: UUID,
        originalError: Error?,
        missingIsConflict: Bool
    ) async throws {
        let current: ScriptFolder?
        do {
            current = try await fetchFolder(id: write.desired.id, accountID: accountID)
        } catch let repositoryError as CloudRepositoryError {
            throw repositoryError
        } catch {
            throw originalError ?? error
        }
        if let current {
            guard write.currentMatchesDesired(current) else {
                throw CloudRepositoryError.folderConflict(
                    device: write.desired,
                    cloud: current
                )
            }
            return
        }
        if missingIsConflict {
            guard let expected = write.expectedRemote else {
                throw Self.incompleteRemoteSnapshot("reconcileFolderWrite.missingExpected")
            }
            throw CloudRepositoryError.folderConflict(
                device: write.desired,
                cloud: expected
            )
        }
        if let originalError { throw originalError }
        throw Self.incompleteRemoteSnapshot("reconcileFolderWrite.missingAfterInsert")
    }

    private func verifyAuthenticatedAccount(_ expectedAccountID: UUID) async throws {
        let authenticatedUserID: UUID
        do { authenticatedUserID = try await client.auth.session.user.id }
        catch { throw CloudRepositoryError.notAuthenticated }
        guard authenticatedUserID == expectedAccountID else {
            throw CloudRepositoryError.accountChanged
        }
    }

    private static func incompleteRemoteSnapshot(_ context: StaticString) -> CloudRepositoryError {
        #if DEBUG
        NSLog("PHRASA_SYNC_INCOMPLETE_CONTEXT=%@", String(describing: context))
        #endif
        return .incompleteRemoteSnapshot
    }

    public static func appendCompleteKeysetPage<Row>(
        _ page: [Row],
        rowIDs: [UUID],
        after cursor: UUID?,
        reportedCount: Int?,
        expectedTotal: inout Int?,
        accumulated: inout [Row]
    ) throws -> Bool {
        guard let reportedCount else {
            throw Self.incompleteRemoteSnapshot("page.missingCount")
        }
        guard rowIDs.count == page.count,
              page.count <= reportedCount else {
            throw Self.incompleteRemoteSnapshot("page.invalidPageCount")
        }
        if let expectedTotal {
            // Exact count is evaluated after this page's `id > cursor`
            // filter, so the rows already accumulated plus the reported
            // remainder must always equal the first page's full total.
            guard accumulated.count + reportedCount == expectedTotal else {
                throw Self.incompleteRemoteSnapshot("page.totalChanged")
            }
        } else {
            expectedTotal = reportedCount
        }

        var previousID = cursor.map(Self.canonicalID)
        var pageIDs: Set<UUID> = []
        for id in rowIDs {
            let canonicalID = Self.canonicalID(id)
            guard pageIDs.insert(id).inserted,
                  previousID.map({ canonicalID > $0 }) ?? true else {
                throw Self.incompleteRemoteSnapshot("page.invalidKeysetOrder")
            }
            previousID = canonicalID
        }

        guard !page.isEmpty || reportedCount == 0 else {
            throw Self.incompleteRemoteSnapshot("page.emptyWithPositiveCount")
        }
        accumulated.append(contentsOf: page)
        guard let expectedTotal, accumulated.count <= expectedTotal else {
            throw Self.incompleteRemoteSnapshot("page.accumulatedExceedsTotal")
        }
        return accumulated.count == expectedTotal
    }

    private static let scriptColumns = "id,folder_id,title,body,source_type,outline,word_count,est_seconds,tags,last_opened_at,created_at,updated_at"

    public static func timestamp(_ date: Date) -> String {
        var wholeSeconds = floor(date.timeIntervalSince1970)
        var microseconds = Int(
            ((date.timeIntervalSince1970 - wholeSeconds) * 1_000_000).rounded()
        )
        if microseconds == 1_000_000 {
            wholeSeconds += 1
            microseconds = 0
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let base = formatter.string(from: Date(timeIntervalSince1970: wholeSeconds))
        return "\(base.dropLast()).\(String(format: "%06d", microseconds))Z"
    }

    private static func canonicalID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

/// Server script row. Timestamps are decoded from **strings** so OCC can reuse
/// the exact wire form PostgREST returned (not a reformatted `Date`).
struct CloudScriptRow: Decodable, Sendable {
    let id: UUID
    let folderID: UUID?
    let title: String
    let body: String
    let sourceType: ScriptSource
    let outline: [CloudOutlinePoint]?
    let tags: [String]
    let lastOpenedAt: Date?
    let lastOpenedAtWire: String?
    let createdAt: Date
    let createdAtWire: String
    let updatedAt: Date
    /// Exact JSON string for `updated_at` — use for OCC predicates.
    let updatedAtWire: String

    enum CodingKeys: String, CodingKey {
        case id, title, body, outline, tags
        case folderID = "folder_id"
        case sourceType = "source_type"
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        sourceType = try container.decode(ScriptSource.self, forKey: .sourceType)
        outline = try container.decodeIfPresent([CloudOutlinePoint].self, forKey: .outline)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []

        updatedAtWire = try container.decode(String.self, forKey: .updatedAt)
        updatedAt = try Self.parseTimestamptz(updatedAtWire, codingPath: container.codingPath)

        createdAtWire = try container.decode(String.self, forKey: .createdAt)
        createdAt = try Self.parseTimestamptz(createdAtWire, codingPath: container.codingPath)

        if container.contains(.lastOpenedAt),
           try container.decodeNil(forKey: .lastOpenedAt) == false {
            let wire = try container.decode(String.self, forKey: .lastOpenedAt)
            lastOpenedAtWire = wire
            lastOpenedAt = try Self.parseTimestamptz(wire, codingPath: container.codingPath)
        } else {
            lastOpenedAtWire = nil
            lastOpenedAt = nil
        }
    }

    var document: ScriptDocument {
        ScriptDocument(
            id: id,
            title: title,
            body: body,
            source: sourceType,
            folderID: folderID,
            tags: tags,
            outline: outline?.compactMap(\.point) ?? [],
            lastOpenedAt: lastOpenedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Parse PostgREST timestamptz JSON the same way supabase-swift does.
    static func parseTimestamptz(
        _ string: String,
        codingPath: [any CodingKey]
    ) throws -> Date {
        if let date = try? Date(
            string,
            strategy: .iso8601
                .year().month().day()
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: true)
        ) {
            return date
        }
        if let date = try? Date(
            string,
            strategy: .iso8601
                .year().month().day()
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: false)
        ) {
            return date
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Invalid timestamptz: \(string)"
            )
        )
    }
}

private struct CloudScriptMutation: Encodable, Sendable {
    let id: UUID
    let userID: UUID
    let folderID: UUID?
    let title: String
    let body: String
    let sourceType: ScriptSource
    let outline: [CloudOutlinePoint]?
    let wordCount: Int
    let estimatedSeconds: Int
    let tags: [String]
    let lastOpenedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(userID: UUID, document: ScriptDocument) {
        id = document.id
        self.userID = userID
        folderID = document.folderID
        title = document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled script" : document.title
        body = document.body
        sourceType = document.source
        outline = CloudOutlinePoint.cloudPoints(from: document.outline)
        wordCount = document.wordCount
        estimatedSeconds = Int(document.estimatedDuration.rounded())
        tags = document.tags
        lastOpenedAt = document.lastOpenedAt
        createdAt = document.createdAt
        updatedAt = document.updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, outline, tags
        case userID = "user_id"
        case folderID = "folder_id"
        case sourceType = "source_type"
        case wordCount = "word_count"
        case estimatedSeconds = "est_seconds"
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Existing-row content updates omit **all** timestamps.
///
/// - `updated_at` / `last_opened_at`: PostgreSQL trigger + separate open mutation.
/// - `created_at`: immutable row metadata. Rewriting it is incorrect and unsafe:
///   encoding an already-ms `Date` through Double can slip one millisecond
///   backward (production: `.734` → `.733` after a successful tags update),
///   which then failed fingerprint validation of the successful response.
///
/// Internal (not private) so PhrasaSyncSupabaseTests can assert the wire keys.
struct CloudScriptContentMutation: Encodable, Sendable {
    let folderID: UUID?
    let title: String
    let body: String
    let sourceType: ScriptSource
    let outline: [CloudOutlinePoint]?
    let wordCount: Int
    let estimatedSeconds: Int
    let tags: [String]

    init(document: ScriptDocument) {
        folderID = document.folderID
        title = document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled script" : document.title
        body = document.body
        sourceType = document.source
        outline = CloudOutlinePoint.cloudPoints(from: document.outline)
        wordCount = document.wordCount
        estimatedSeconds = Int(document.estimatedDuration.rounded())
        tags = document.tags
    }

    enum CodingKeys: String, CodingKey {
        case title, body, outline, tags
        case folderID = "folder_id"
        case sourceType = "source_type"
        case wordCount = "word_count"
        case estimatedSeconds = "est_seconds"
    }
}

/// Metadata-only open stamp. Encodes solely `last_opened_at` (no content / created_at).
struct CloudScriptOpenedMutation: Encodable, Sendable {
    let lastOpenedAt: Date

    enum CodingKeys: String, CodingKey {
        case lastOpenedAt = "last_opened_at"
    }
}

private struct CloudFolderRow: Decodable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }

    var folder: ScriptFolder { ScriptFolder(id: id, name: name, createdAt: createdAt) }
}

/// Insert-only folder row (includes immutable `created_at` once).
struct CloudFolderInsertMutation: Encodable, Sendable {
    let id: UUID
    let userID: UUID
    let name: String
    let createdAt: Date

    init(userID: UUID, folder: ScriptFolder) {
        id = folder.id
        self.userID = userID
        name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled folder" : folder.name
        createdAt = folder.createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case userID = "user_id"
        case createdAt = "created_at"
    }
}

/// Existing-folder rename: name only. Must not rewrite `created_at` (same Double
/// drift hazard as script content updates). OCC still predicates on the expected
/// name + created_at in the query filter, not in the SET clause.
struct CloudFolderRenameMutation: Encodable, Sendable {
    let name: String

    init(folder: ScriptFolder) {
        name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled folder" : folder.name
    }

    enum CodingKeys: String, CodingKey {
        case name
    }
}

private struct CloudSettingsRow: Decodable, Sendable {
    let settings: CloudReaderSettings
}

private struct CloudSettingsMutation: Encodable, Sendable {
    let userID: UUID
    let settings: CloudReaderSettings

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case settings
    }
}

/// Wire shape kept identical to the historical cloud client keys so a user's
/// reader preferences move across devices without translation loss.
///
/// Internal (not private) so PhrasaSyncSupabaseTests can round-trip encode/decode
/// without a second wire model.
struct CloudReaderSettings: Codable, Sendable {
    let mode: ReaderMode
    let scrollStyle: ScrollStyle
    let fontFamily: ReadingFont
    let fontSize: Double
    let lineHeight: Double
    let marginX: Double
    let align: String
    let theme: ReaderTheme
    let mirrorH: Bool
    let mirrorV: Bool
    let focusPosition: Double
    let speedWpm: Double
    let speedCountdown: SpeedCountdown
    let recognitionLang: String
    let showPacing: Bool
    let targetSec: TimeInterval?

    init(from decoder: Decoder) throws {
        let defaults = ReaderSettings()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? values.decodeIfPresent(ReaderMode.self, forKey: .mode)) ?? defaults.mode
        scrollStyle = (try? values.decodeIfPresent(ScrollStyle.self, forKey: .scrollStyle)) ?? defaults.scrollStyle
        fontFamily = (try? values.decodeIfPresent(ReadingFont.self, forKey: .fontFamily)) ?? defaults.font
        fontSize = (try? values.decodeIfPresent(Double.self, forKey: .fontSize)) ?? defaults.fontSize
        lineHeight = (try? values.decodeIfPresent(Double.self, forKey: .lineHeight)) ?? defaults.lineHeight
        marginX = (try? values.decodeIfPresent(Double.self, forKey: .marginX)) ?? defaults.horizontalMargin * 100
        align = (try? values.decodeIfPresent(String.self, forKey: .align)) ?? "left"
        theme = (try? values.decodeIfPresent(ReaderTheme.self, forKey: .theme)) ?? defaults.theme
        mirrorH = (try? values.decodeIfPresent(Bool.self, forKey: .mirrorH)) ?? defaults.mirrorHorizontal
        mirrorV = (try? values.decodeIfPresent(Bool.self, forKey: .mirrorV)) ?? defaults.mirrorVertical
        focusPosition = (try? values.decodeIfPresent(Double.self, forKey: .focusPosition)) ?? defaults.focusPosition
        speedWpm = (try? values.decodeIfPresent(Double.self, forKey: .speedWpm)) ?? defaults.speedWPM
        if let raw = try? values.decodeIfPresent(Int.self, forKey: .speedCountdown),
           let countdown = SpeedCountdown(rawValue: raw) {
            speedCountdown = countdown
        } else {
            speedCountdown = defaults.speedCountdown
        }
        let language = (try? values.decodeIfPresent(String.self, forKey: .recognitionLang))
            ?? defaults.recognitionLanguage
        recognitionLang = language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaults.recognitionLanguage : language
        showPacing = (try? values.decodeIfPresent(Bool.self, forKey: .showPacing)) ?? defaults.showPacing
        targetSec = try? values.decodeIfPresent(TimeInterval.self, forKey: .targetSec)
    }

    init(_ settings: ReaderSettings) {
        mode = settings.mode
        scrollStyle = settings.scrollStyle
        fontFamily = settings.font
        fontSize = settings.fontSize
        lineHeight = settings.lineHeight
        marginX = settings.horizontalMargin * 100
        align = settings.alignment == .leading ? "left" : "center"
        theme = settings.theme
        mirrorH = settings.mirrorHorizontal
        mirrorV = settings.mirrorVertical
        focusPosition = settings.focusPosition
        speedWpm = settings.speedWPM
        speedCountdown = settings.speedCountdown
        recognitionLang = settings.recognitionLanguage
        showPacing = settings.showPacing
        targetSec = settings.targetDuration
    }

    var readerSettings: ReaderSettings {
        ReaderSettings(
            mode: mode,
            scrollStyle: scrollStyle,
            font: fontFamily,
            fontSize: fontSize,
            lineHeight: lineHeight,
            horizontalMargin: marginX / 100,
            alignment: align == "center" ? .center : .leading,
            theme: theme,
            mirrorHorizontal: mirrorH,
            mirrorVertical: mirrorV,
            focusPosition: focusPosition,
            speedWPM: speedWpm,
            speedCountdown: speedCountdown,
            recognitionLanguage: recognitionLang,
            showPacing: showPacing,
            targetDuration: targetSec
        )
    }
}
