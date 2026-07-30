import Foundation
import Observation
import SwiftUI

/// Compact user-facing account+sync presentation.
///
/// Offline-only / signed-out local mode does not surface a nag state.
enum CloudAccountSyncUserPresentation: Equatable, Sendable {
    case synced
    case syncing
    case offline
    case needsAttention

    var label: String {
        switch self {
        case .synced: "Synced"
        case .syncing: "Syncing"
        case .offline: "Offline"
        case .needsAttention: "Needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .synced: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .offline: "icloud.slash"
        case .needsAttention: "exclamationmark.icloud"
        }
    }

    var tint: Color {
        switch self {
        case .synced: PhrasaDesign.success
        case .syncing: PhrasaDesign.muted
        case .offline, .needsAttention: PhrasaDesign.ember
        }
    }
}

/// Why a coalesced synchronization pass was requested.
enum CloudAccountSyncTrigger: Equatable, Sendable {
    case launch
    case authRestored
    case foreground
    case manual
    case durablePush
}

/// Single @MainActor shipping controller for iOS account + library sync.
///
/// Local `LibraryStore.load` always runs first and never waits on this type.
/// All launch / foreground / manual / durable-push triggers coalesce through
/// one synchronization lane owned by `CloudCoordinator`.
@MainActor
@Observable
final class CloudAccountSyncRuntime {
    private(set) var coordinator: CloudCoordinator
    private(set) var userPresentation: CloudAccountSyncUserPresentation?
    private(set) var lastManualSyncAt: Date?
    /// Test seam: number of times the single-flight lane entered work.
    private(set) var synchronizationPassCount = 0
    /// Test seam: number of repository-bound synchronize attempts that passed
    /// the post-prepare eligibility lease gate.
    private(set) var networkSynchronizeAttempts = 0

    /// Resets counters for deterministic unit tests after harness warm-up.
    func resetTestCounters() {
        synchronizationPassCount = 0
        networkSynchronizeAttempts = 0
        lastManualSyncAt = nil
    }

    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private var authObservationTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var hasCompletedLaunchPull = false
    @ObservationIgnored private var lastKnownSignedInUserID: UUID?
    @ObservationIgnored private var pendingTriggers: Set<CloudAccountSyncTrigger> = []
    @ObservationIgnored private var isRunningLane = false
    @ObservationIgnored private var durablePushTask: Task<Void, Never>?
    @ObservationIgnored private var busyRetryTask: Task<Void, Never>?
    @ObservationIgnored private var lastFailureWasTransport = false
    @ObservationIgnored private var durablePushDebounce: Duration
    /// Test-only barrier invoked inside the live preflight after lease capture
    /// and before lease revalidation. Shipping never sets this.
    @ObservationIgnored var testPreflightBarrier: (@MainActor () -> Void)?

    /// Defaults match production shipping debounce for coalesced durable push.
    init(
        coordinator: CloudCoordinator,
        durablePushDebounce: Duration = .milliseconds(800)
    ) {
        self.coordinator = coordinator
        self.durablePushDebounce = durablePushDebounce
        refreshPresentation()
    }

    static func live(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CloudAccountSyncRuntime {
        CloudAccountSyncRuntime(
            coordinator: CloudCoordinator.live(bundle: bundle, environment: environment)
        )
    }

    var canRequestManualSync: Bool {
        library != nil
            && coordinator.canSync
            && !isRunningLane
    }

    /// Bind the local library after `LibraryStore.load` completes. Never starts
    /// network work from this call alone.
    func attach(library: LibraryStore) {
        self.library = library
        library.onDurableCloudRelevantMutation = { [weak self] in
            self?.noteDurableCloudRelevantMutation()
        }
        refreshPresentation()
    }

    /// Begin observing auth. Safe to call once after local library load.
    func start() {
        guard !started else { return }
        started = true
        coordinator.start()
        authObservationTask?.cancel()
        authObservationTask = Task { [weak self] in
            guard let self else { return }
            // Observation-backed loop: no timers. Fires when authState changes.
            while !Task.isCancelled {
                let snapshot = self.coordinator.authState
                await self.considerAuthRestoredPullIfNeeded()
                await self.waitForAuthStateChange(from: snapshot)
            }
        }
        refreshPresentation()
    }

    private func waitForAuthStateChange(from previous: CloudAuthState) async {
        if coordinator.authState != previous { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = ResumeOnceBox(continuation)
            withObservationTracking {
                _ = coordinator.authState
            } onChange: {
                box.resume()
            }
            if coordinator.authState != previous {
                box.resume()
            }
        }
    }

    /// Launch pull after local load + auth observation. Coalesces with other
    /// triggers; no-ops when offline-only or signed out.
    func handleLaunch() {
        request(.launch)
    }

    func handleForeground() {
        request(.foreground)
    }

    func handleAuthStateChange() {
        Task { await considerAuthRestoredPullIfNeeded() }
        refreshPresentation()
    }

    func handleOpenURL(_ url: URL) async {
        await coordinator.handleOpenURL(url)
        await considerAuthRestoredPullIfNeeded()
        refreshPresentation()
    }

    /// Manual Sync Now. Uses the same single-flight lane as automatic triggers.
    /// Reader settings remain local-only for this release (no restore toggle).
    func syncNow() async {
        request(.manual)
        await drainLane()
    }

    /// Durable local commit completed — coalesce a push after a short debounce.
    /// Never called from `stageEditorDraft` or failed saves.
    func noteDurableCloudRelevantMutation() {
        durablePushTask?.cancel()
        durablePushTask = Task { [weak self, durablePushDebounce] in
            try? await Task.sleep(for: durablePushDebounce)
            guard !Task.isCancelled else { return }
            self?.request(.durablePush)
        }
    }

    // MARK: - Lane

    private func request(_ trigger: CloudAccountSyncTrigger) {
        guard library != nil else { return }
        switch coordinator.availability {
        case .offlineOnly:
            // Fully local mode — never nag or schedule network work.
            refreshPresentation()
            return
        case .unavailable:
            userPresentation = .needsAttention
            return
        case .ready:
            break
        }

        pendingTriggers.insert(trigger)
        Task { await drainLane() }
    }

    private func drainLane() async {
        guard !isRunningLane else { return }
        guard library != nil else { return }
        isRunningLane = true
        defer {
            isRunningLane = false
            if !pendingTriggers.isEmpty {
                Task { await drainLane() }
            }
            refreshPresentation()
        }

        while !pendingTriggers.isEmpty {
            let triggers = pendingTriggers
            pendingTriggers.removeAll()
            await performSynchronizationPass(triggers: triggers)
        }
    }

    private func performSynchronizationPass(triggers: Set<CloudAccountSyncTrigger>) async {
        guard let library else { return }
        guard case .ready = coordinator.availability else {
            refreshPresentation()
            return
        }
        guard case .signedIn = coordinator.authState else {
            // Signed-out / recovery / loading: no automatic network.
            if triggers.contains(.manual) {
                // Manual while signed out surfaces via coordinator messages.
            }
            refreshPresentation()
            return
        }

        guard let token = coordinator.beginSynchronization() else {
            // Auth callback/deletion/another coordinator action is in flight.
            // Never reinsert into this same drain pass: doing so creates a
            // non-suspending MainActor loop that can prevent the busy operation
            // from ever completing. One yielding retry preserves the trigger.
            let retryable = triggers.subtracting([.manual])
            scheduleBusyRetry(retryable)
            refreshPresentation()
            return
        }
        busyRetryTask?.cancel()
        busyRetryTask = nil

        synchronizationPassCount += 1
        userPresentation = .syncing
        lastFailureWasTransport = false
        if triggers.contains(.manual) {
            lastManualSyncAt = Date()
        }

        // Shipping keeps reader settings local-only; scripts/folders are the
        // sync product. Whole-JSON settings LWW restore is not offered.
        let effectivePreference: CloudPreferenceResolution = .localOnly

        let accountID = token.accountID
        let prepared: CloudSyncInput
        do {
            switch try await library.prepareCloudSync(for: accountID) {
            case .deferred(let reason):
                coordinator.reportLocalSyncDeferred(reason, for: token)
                userPresentation = .needsAttention
                return
            case .ready(let input):
                prepared = input
            }
        } catch {
            coordinator.reportLocalSyncPreparationFailure(error, for: token)
            userPresentation = .needsAttention
            return
        }

        guard let issuedLease = library.cloudSyncEligibilityLease else {
            let reason = CloudSyncDeferredReason.editorContentNotPersisted(
                scriptCount: max(1, library.cloudSyncHostDirtyState.unpersistedEditorScriptCount)
            )
            coordinator.reportLocalSyncDeferred(reason, for: token)
            userPresentation = .needsAttention
            return
        }

        // Live async preflight hops to MainActor at the final point inside the
        // engine, immediately before the first repository call. Value-only
        // dirty captures are not sufficient; the lease is revalidated here.
        // Never hold the durable store lock across network I/O.
        let preflightLibrary = library
        let lease = issuedLease
        let barrier = testPreflightBarrier
        let preflight: CloudSyncPreflightValidator = {
            try await MainActor.run {
                barrier?()
                guard preflightLibrary.isCloudSyncEligibilityLeaseValid(lease) else {
                    let count = max(
                        1,
                        preflightLibrary.cloudSyncHostDirtyState.unpersistedEditorScriptCount
                    )
                    throw CloudSyncEligibilityError.deferred(
                        .editorContentNotPersisted(scriptCount: count)
                    )
                }
            }
        }

        guard let result = await coordinator.synchronize(
            token,
            local: prepared,
            preferences: effectivePreference,
            preflight: preflight
        ) else {
            // Count only attempts that passed live preflight (engine reached
            // remote I/O). Dirty deferred outcomes stay at zero.
            if case .failed = coordinator.syncStatus {
                networkSynchronizeAttempts += 1
            }
            applyTerminalPresentation(from: coordinator.syncStatus)
            return
        }
        networkSynchronizeAttempts += 1

        // Lease must still not be required across apply — apply holds its own
        // durable mutation lock. If a draft staged during network I/O, apply
        // reconciliation preserves it.
        do {
            try await library.applyCloudSyncResult(result)
            coordinator.reportLocalSyncApplied(result.summary, for: token)
            lastFailureWasTransport = false
            if triggers.contains(.launch) || triggers.contains(.authRestored) {
                hasCompletedLaunchPull = true
            }
            userPresentation = .synced
        } catch {
            coordinator.reportLocalMergeFailure(error, for: token)
            userPresentation = .needsAttention
        }
    }

    private func scheduleBusyRetry(_ triggers: Set<CloudAccountSyncTrigger>) {
        guard !triggers.isEmpty else { return }
        busyRetryTask?.cancel()
        busyRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.busyRetryTask = nil
            self.pendingTriggers.formUnion(triggers)
            await self.drainLane()
        }
    }

    private func considerAuthRestoredPullIfNeeded() async {
        let currentID = coordinator.signedInUser?.id
        defer { lastKnownSignedInUserID = currentID }

        guard let currentID else {
            refreshPresentation()
            return
        }

        if lastKnownSignedInUserID != currentID || !hasCompletedLaunchPull {
            request(hasCompletedLaunchPull ? .authRestored : .launch)
        }
        refreshPresentation()
    }

    private func applyTerminalPresentation(from status: CloudSyncStatus) {
        switch status {
        case .idle:
            refreshPresentation()
        case .syncing:
            userPresentation = .syncing
        case .succeeded:
            lastFailureWasTransport = false
            userPresentation = .synced
        case .failed(let message):
            if Self.isTransportFailureMessage(message) {
                lastFailureWasTransport = true
                userPresentation = .offline
            } else {
                lastFailureWasTransport = false
                userPresentation = .needsAttention
            }
        case .deferred:
            userPresentation = .needsAttention
        }
    }

    private func refreshPresentation() {
        switch coordinator.availability {
        case .offlineOnly:
            userPresentation = nil
            return
        case .unavailable:
            userPresentation = .needsAttention
            return
        case .ready:
            break
        }

        switch coordinator.authState {
        case .loading, .signedOut, .passwordRecovery:
            // Local mode while signed out — no nag.
            if userPresentation == .syncing { userPresentation = nil }
            else if case .synced = userPresentation { userPresentation = nil }
            else if case .offline = userPresentation, !lastFailureWasTransport {
                userPresentation = nil
            }
            // Keep needsAttention / offline transport only when relevant.
            if coordinator.signedInUser == nil,
               userPresentation == .needsAttention || userPresentation == .offline {
                // Drop transport offline when signed out.
                if !lastFailureWasTransport {
                    userPresentation = nil
                } else {
                    userPresentation = nil
                    lastFailureWasTransport = false
                }
            }
            return
        case .signedIn:
            break
        }

        if isRunningLane || coordinator.isSynchronizing {
            userPresentation = .syncing
            return
        }

        switch coordinator.syncStatus {
        case .syncing:
            userPresentation = .syncing
        case .succeeded:
            userPresentation = .synced
        case .failed(let message):
            userPresentation = Self.isTransportFailureMessage(message) ? .offline : .needsAttention
        case .deferred:
            userPresentation = .needsAttention
        case .idle:
            if userPresentation == nil {
                userPresentation = .synced
            }
        }
    }

    static func isTransportFailureMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unreachable")
            || lower.contains("network")
            || lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("connection")
            || lower.contains("offline")
            || lower.contains("internet")
    }
}

/// Guards CheckedContinuation against double-resume under Observation races.
private final class ResumeOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
