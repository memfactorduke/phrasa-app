import Foundation

/// Why a foreground/manual sync request cannot snapshot, push, or pull yet.
///
/// Only durable local persistence may make a library eligible. Staged editor
/// drafts that have not been written to SQLite must never enter a sync plan.
public enum CloudSyncDeferredReason: Equatable, Sendable {
    /// In-memory editor content is staged and not yet durably persisted.
    case editorContentNotPersisted(scriptCount: Int)

    public var userFacingMessage: String {
        switch self {
        case .editorContentNotPersisted(let count):
            let noun = count == 1 ? "script" : "scripts"
            return "Save your editor changes first. Phrasa will not sync \(count) unsaved \(noun) until they are written on this device."
        }
    }
}

/// Pure eligibility decision for one push/pull attempt.
public enum CloudSyncEligibility: Equatable, Sendable {
    case eligible
    case deferred(CloudSyncDeferredReason)

    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }
}

/// Outcome of preparing a local library snapshot for an explicit sync.
public enum CloudSyncPreparationOutcome: Sendable {
    case ready(CloudSyncInput)
    case deferred(CloudSyncDeferredReason)
}

/// Short-lived eligibility token issued after a successful local prepare.
///
/// A synchronous `stageEditorDraft` after prepare and before the first network
/// fetch/write must invalidate this token. Validation is fail-closed and must
/// not hold any durable store lock across network I/O.
public struct CloudSyncEligibilityLease: Equatable, Sendable {
    public let generation: UInt64

    public init(generation: UInt64) {
        self.generation = generation
    }
}

/// Host-reported dirty-editor boundary for one sync attempt.
///
/// Platform stores fill this from their unpersisted editor-draft set. The
/// shared engine never inspects UI state directly.
public struct CloudSyncHostDirtyState: Equatable, Sendable {
    public let unpersistedEditorScriptCount: Int

    public init(unpersistedEditorScriptCount: Int) {
        self.unpersistedEditorScriptCount = max(0, unpersistedEditorScriptCount)
    }

    public static let clean = CloudSyncHostDirtyState(unpersistedEditorScriptCount: 0)

    public var eligibility: CloudSyncEligibility {
        CloudSyncEligibilityGate.evaluate(self)
    }
}

/// Deterministic eligibility / deferred-trigger gate shared by packages and apps.
public enum CloudSyncEligibilityGate {
    public static func evaluate(_ host: CloudSyncHostDirtyState) -> CloudSyncEligibility {
        if host.unpersistedEditorScriptCount > 0 {
            return .deferred(
                .editorContentNotPersisted(scriptCount: host.unpersistedEditorScriptCount)
            )
        }
        return .eligible
    }

    /// Fail closed before any remote push/pull when the host is dirty.
    public static func requireEligible(_ eligibility: CloudSyncEligibility) throws {
        if case .deferred(let reason) = eligibility {
            throw CloudSyncEligibilityError.deferred(reason)
        }
    }

    public static func requireEligible(_ host: CloudSyncHostDirtyState) throws {
        try requireEligible(host.eligibility)
    }
}

public enum CloudSyncEligibilityError: LocalizedError, Equatable, Sendable {
    case deferred(CloudSyncDeferredReason)

    public var errorDescription: String? {
        switch self {
        case .deferred(let reason):
            reason.userFacingMessage
        }
    }
}

/// Live eligibility gate invoked by `LibrarySyncEngine` immediately before the
/// first repository/network operation. Shipping hosts hop to MainActor and
/// revalidate a generation-bound lease plus current dirty state. Must not hold
/// a durable store lock or actor across subsequent network I/O.
public typealias CloudSyncPreflightValidator = @Sendable () async throws -> Void

/// Explicit preflight helpers. Shipping call sites must supply a live validator;
/// the always-eligible convenience exists only for package/unit tests.
public enum CloudSyncPreflight {
    /// Test-only gate that never inspects host state. Do not use in app code.
    public static let unsafeTestOnlyAlwaysEligible: CloudSyncPreflightValidator = {}

    /// Builds a preflight from a live dirty-state snapshot taken at call time.
    public static func requireLiveHost(
        _ host: @escaping @Sendable () async -> CloudSyncHostDirtyState
    ) -> CloudSyncPreflightValidator {
        {
            try CloudSyncEligibilityGate.requireEligible(await host())
        }
    }
}
