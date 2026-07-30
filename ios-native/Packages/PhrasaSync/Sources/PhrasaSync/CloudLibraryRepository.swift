import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

/// Platform-agnostic remote library transport. Implementations must never sync
/// audio or transcripts; only scripts, folders, outline points, and settings.
public protocol CloudLibraryRepository: Sendable {
    func fetchScripts(accountID: UUID, updatedAfter: Date?) async throws -> [ScriptDocument]
    func fetchScript(id: UUID, accountID: UUID) async throws -> ScriptDocument?
    func writeScripts(
        _ writes: [CloudScriptWrite],
        accountID: UUID
    ) async throws -> [ScriptDocument]
    func deleteScript(expected: ScriptDocument, accountID: UUID) async throws
    func fetchFolders(accountID: UUID) async throws -> [ScriptFolder]
    func fetchFolder(id: UUID, accountID: UUID) async throws -> ScriptFolder?
    func writeFolders(_ writes: [CloudFolderWrite], accountID: UUID) async throws
    func deleteFolder(expected: ScriptFolder, accountID: UUID) async throws
    func fetchSettings(accountID: UUID) async throws -> ReaderSettings?
    func saveSettings(_ settings: ReaderSettings, accountID: UUID) async throws
}

public struct CloudScriptWrite: Equatable, Sendable {
    public let desired: ScriptDocument
    public let expectedRemote: ScriptDocument?

    public init(desired: ScriptDocument, expectedRemote: ScriptDocument?) {
        self.desired = desired
        self.expectedRemote = expectedRemote
    }

    public static func make(
        desired: [ScriptDocument],
        from remote: [ScriptDocument]
    ) -> [Self] {
        let remoteByID = Dictionary(
            remote.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return desired.map {
            Self(desired: $0, expectedRemote: remoteByID[$0.id])
        }
    }

    public func currentMatchesDesired(_ current: ScriptDocument) -> Bool {
        guard CloudScriptFingerprint.make(current)
                == CloudScriptFingerprint.make(desired) else {
            return false
        }
        // lastOpenedAt round-trips through the JSON wire (ms truncation). A
        // server echo of .746000 must satisfy local desired .746402; µs
        // comparison falsely fails and surfaces incompleteRemoteSnapshot.
        guard let desiredOpenedAt = desired.lastOpenedAt else { return true }
        guard let currentOpenedAt = current.lastOpenedAt else { return false }
        return CloudTimestampPrecision.wireIsAtLeast(currentOpenedAt, desiredOpenedAt)
    }
}

public struct CloudFolderWrite: Equatable, Sendable {
    public let desired: ScriptFolder
    public let expectedRemote: ScriptFolder?

    public init(desired: ScriptFolder, expectedRemote: ScriptFolder?) {
        self.desired = desired
        self.expectedRemote = expectedRemote
    }

    public static func make(desired: [ScriptFolder], from remote: [ScriptFolder]) -> [Self] {
        let remoteByID = Dictionary(
            remote.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return desired.map {
            Self(desired: $0, expectedRemote: remoteByID[$0.id])
        }
    }

    public func currentMatchesDesired(_ current: ScriptFolder) -> Bool {
        CloudFolderSyncPlan.matches(current, baseline: desired)
    }
}

public enum CloudRepositoryError: LocalizedError, Equatable {
    case notAuthenticated
    case accountChanged
    case newerRemoteEdit
    case newerRemoteFolder
    case conflictingScriptEdits(id: UUID, title: String)
    case conflictingFolderEdits(id: UUID, deviceName: String, cloudName: String)
    case incompleteRemoteSnapshot

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Sign in before syncing this library."
        case .accountChanged:
            "The signed-in account changed during sync. Nothing from this device was sent to the new account."
        case .newerRemoteEdit:
            "A cloud script changed while this device was deleting the copy it had reviewed. Nothing newer was overwritten; sync again."
        case .newerRemoteFolder:
            "A cloud folder changed while this device was deleting the copy it had reviewed. Nothing newer was overwritten; sync again."
        case .conflictingScriptEdits(let id, let title):
            "Phrasa stopped before overwriting the script “\(title)” (\(id.uuidString)). Export a backup first. To keep the cloud copy, delete this device’s copy and sync again. To keep this device’s copy, delete the cloud copy from another signed-in device and sync again."
        case .conflictingFolderEdits(let id, let deviceName, let cloudName):
            "Phrasa found two names for folder \(id.uuidString). Device: “\(deviceName)”. Cloud: “\(cloudName)”. Export a backup first. To keep the cloud name, rename this device’s folder to “\(cloudName)” and sync again. To keep the device name, use another signed-in client to rename the cloud folder to “\(deviceName)”, then sync again."
        case .incompleteRemoteSnapshot:
            "Phrasa could not prove that it received your complete cloud library, so it left this device unchanged. Sync again in a moment."
        }
    }

    public static func scriptConflict(_ script: ScriptDocument) -> Self {
        .conflictingScriptEdits(id: script.id, title: script.title)
    }

    public static func folderConflict(device: ScriptFolder, cloud: ScriptFolder) -> Self {
        .conflictingFolderEdits(
            id: device.id,
            deviceName: device.name,
            cloudName: cloud.name
        )
    }
}
