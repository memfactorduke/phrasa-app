import AppKit
import CoreGraphics
import Foundation
import SwiftUI

private final class MacScreenObserverHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func install(_ token: NSObjectProtocol) {
        lock.withLock {
            self.token = token
        }
    }

    func cancel() {
        let token = lock.withLock {
            defer { self.token = nil }
            return self.token
        }
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    deinit {
        cancel()
    }
}

// MARK: - Display catalog

/// A resolved physical display the controller may target for audience output.
struct MacDisplayDescriptor: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    let frame: CGRect
    let isMain: Bool
    /// Ephemeral IDs are process-local fallbacks when CGDisplay UUID is unavailable.
    let isEphemeral: Bool
}

@MainActor
protocol MacDisplayCatalogProviding: AnyObject {
    func currentDisplays() -> [MacDisplayDescriptor]
}

/// Live catalog backed by `NSScreen` + `CGDisplayCreateUUIDFromDisplayID`.
@MainActor
final class MacSystemDisplayCatalog: MacDisplayCatalogProviding {
    func currentDisplays() -> [MacDisplayDescriptor] {
        let screens = NSScreen.screens
        let mainID = NSScreen.main.flatMap { Self.displayID(of: $0) }
        return screens.compactMap { screen in
            guard let displayID = Self.displayID(of: screen) else { return nil }
            let resolved = Self.stableID(for: displayID)
            return MacDisplayDescriptor(
                id: resolved.id,
                name: screen.localizedName,
                frame: screen.frame,
                isMain: mainID == displayID,
                isEphemeral: resolved.isEphemeral
            )
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { CGDirectDisplayID(truncating: $0) }
    }

    /// Stable UUID from CoreGraphics when available; otherwise an explicit ephemeral UUID.
    nonisolated static func stableID(for displayID: CGDirectDisplayID) -> (id: UUID, isEphemeral: Bool) {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            let bytes = CFUUIDGetUUIDBytes(cfUUID)
            let uuid = UUID(uuid: (
                bytes.byte0, bytes.byte1, bytes.byte2, bytes.byte3,
                bytes.byte4, bytes.byte5, bytes.byte6, bytes.byte7,
                bytes.byte8, bytes.byte9, bytes.byte10, bytes.byte11,
                bytes.byte12, bytes.byte13, bytes.byte14, bytes.byte15
            ))
            return (uuid, false)
        }
        // Explicit ephemeral fallback — never silently alias another display.
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let raw = displayID.bigEndian
        withUnsafeBytes(of: raw) { src in
            withUnsafeMutableBytes(of: &bytes) { dst in
                // Tag as ephemeral in the first two bytes, embed display ID in the last four.
                dst[0] = 0xE1
                dst[1] = 0xF1
                for i in 0..<min(4, src.count) {
                    dst[12 + i] = src[i]
                }
            }
        }
        return (UUID(uuid: bytes), true)
    }
}

/// Pure selection resolution by stable ID — never by array index.
enum MacDisplaySelectionResolver {
    static func resolve(
        selectedID: UUID?,
        in displays: [MacDisplayDescriptor]
    ) -> MacDisplayDescriptor? {
        guard let selectedID else { return nil }
        return displays.first { $0.id == selectedID }
    }

    static func isSelectionConnected(
        selectedID: UUID?,
        in displays: [MacDisplayDescriptor]
    ) -> Bool {
        resolve(selectedID: selectedID, in: displays) != nil
    }
}

// MARK: - Audience window seam

/// Testable surface for audience window side effects.
@MainActor
protocol MacAudienceWindowControlling: AnyObject {
    var isVisible: Bool { get }
    var currentFrame: CGRect? { get }
    /// Bound reader/controller window used for key reassert after reconnect.
    var boundControllerWindow: NSWindow? { get }
    func bindControllerWindow(_ window: NSWindow?)
    func present(frame: CGRect, content: NSView)
    func reframe(to frame: CGRect)
    func hide()
    func teardown()
}

/// Borderless, non-key, mouse-transparent audience stage window.
final class MacAudienceStageWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MacAudienceStageWindowController: NSWindowController, MacAudienceWindowControlling {
    private(set) var isVisible = false
    /// Weak reference to the actual reader/controller host window (never NSApp lookup).
    private weak var controllerWindow: NSWindow?

    var currentFrame: CGRect? { window?.frame }
    var boundControllerWindow: NSWindow? { controllerWindow }

    convenience init(offScreen: Bool = false) {
        let initialFrame = offScreen
            ? CGRect(x: -10_000, y: -10_000, width: 100, height: 100)
            : .zero
        let window = MacAudienceStageWindow(
            contentRect: initialFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.level = .normal
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .fullScreenDisallowsTiling
        ]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.animationBehavior = .none
        self.init(window: window)
    }

    func bindControllerWindow(_ window: NSWindow?) {
        controllerWindow = window
    }

    func present(frame: CGRect, content: NSView) {
        guard let window else { return }
        window.contentView = content
        window.setFrame(frame, display: true)
        // Audience cannot become key; order only — never makeKeyAndOrderFront.
        window.orderFrontRegardless()
        // Reassert controller key only when reconnecting while the app is active
        // and the bound controller window is still visible/eligible. Never search
        // NSApp.windows for a fallback.
        reassertControllerKeyIfEligible()
        isVisible = true
    }

    func reframe(to frame: CGRect) {
        window?.setFrame(frame, display: true)
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    func teardown() {
        hide()
        window?.contentView = nil
        window?.close()
        controllerWindow = nil
    }

    /// After reconnect present: restore key to the bound controller if eligible.
    private func reassertControllerKeyIfEligible() {
        guard NSApp.isActive else { return }
        guard let controller = controllerWindow else { return }
        guard controller.isVisible, !controller.isMiniaturized, controller.canBecomeKey else { return }
        controller.makeKey()
    }
}

// MARK: - Controller window accessor

/// Resolves the actual host `NSWindow` of a SwiftUI hierarchy without
/// consulting `NSApp.keyWindow` or scanning `NSApp.windows`.
struct MacControllerWindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MacControllerWindowProbeView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MacControllerWindowProbeView)?.onResolve = onResolve
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

/// Tiny NSView that reports its host window once attached to a window.
private final class MacControllerWindowProbeView: NSView {
    var onResolve: ((NSWindow?) -> Void)?
    private var lastReported: ObjectIdentifier?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportIfNeeded()
    }

    override func layout() {
        super.layout()
        reportIfNeeded()
    }

    private func reportIfNeeded() {
        let id = window.map { ObjectIdentifier($0) }
        guard id != lastReported else { return }
        lastReported = id
        onResolve?(window)
    }
}

// MARK: - Coordinator

/// Owns explicit audience enable/disable + display selection intent.
/// Never auto-covers a display. Never falls back to the controller/main screen.
@MainActor
@Observable
final class MacAudienceOutputCoordinator {
    private(set) var availableDisplays: [MacDisplayDescriptor] = []
    /// Explicit user selection by stable UUID (not array index).
    private(set) var selectedDisplayID: UUID?
    /// User intent to show audience output when the selection is connected.
    private(set) var isEnabled = false
    /// True when the audience window is currently ordered on a resolved screen.
    private(set) var isAudienceVisible = false
    /// Restrained status for disconnect / missing selection.
    private(set) var statusMessage: String?

    private let catalog: any MacDisplayCatalogProviding
    private let windowController: any MacAudienceWindowControlling
    @ObservationIgnored private let screenObserver = MacScreenObserverHolder()
    private var contentFactory: (() -> NSView)?
    private var isTornDown = false

    init(
        catalog: (any MacDisplayCatalogProviding)? = nil,
        windowController: (any MacAudienceWindowControlling)? = nil
    ) {
        self.catalog = catalog ?? MacSystemDisplayCatalog()
        self.windowController = windowController ?? MacAudienceStageWindowController()
        refreshDisplays()
        screenObserver.install(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleScreenParametersChanged()
                }
            }
        )
    }

    var resolvedSelection: MacDisplayDescriptor? {
        MacDisplaySelectionResolver.resolve(
            selectedID: selectedDisplayID,
            in: availableDisplays
        )
    }

    /// Whether a live audience surface is ordered on a resolved display.
    var hasVisibleAudienceOutput: Bool {
        isEnabled && isAudienceVisible && resolvedSelection != nil
    }

    /// Bound controller window exposed for tests / fullscreen reuse.
    var boundControllerWindow: NSWindow? {
        windowController.boundControllerWindow
    }

    /// Bind the actual reader host window (from `MacControllerWindowAccessor`).
    func bindControllerWindow(_ window: NSWindow?) {
        guard !isTornDown else { return }
        windowController.bindControllerWindow(window)
    }

    func refreshDisplays() {
        availableDisplays = catalog.currentDisplays()
    }

    func selectDisplay(id: UUID?) {
        selectedDisplayID = id
        reconcilePresentation()
    }

    /// Enable/disable audience output. Does not auto-select a display.
    func setEnabled(_ enabled: Bool, contentFactory: (() -> NSView)? = nil) {
        if let contentFactory {
            self.contentFactory = contentFactory
        }
        isEnabled = enabled
        reconcilePresentation()
    }

    /// Provide or replace the hosted audience content factory.
    func setContentFactory(_ factory: @escaping () -> NSView) {
        contentFactory = factory
        if isAudienceVisible {
            // Refresh content on the live window without changing selection intent.
            if let display = resolvedSelection, let content = contentFactory?() {
                windowController.present(frame: display.frame, content: content)
                isAudienceVisible = windowController.isVisible
            }
        }
    }

    func handleScreenParametersChanged() {
        refreshDisplays()
        reconcilePresentation()
    }

    /// Injected test seam: apply a display list as if the catalog refreshed.
    func applyDisplaysForTesting(_ displays: [MacDisplayDescriptor]) {
        availableDisplays = displays
        reconcilePresentation()
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        isEnabled = false
        contentFactory = nil
        hideAudience(status: nil)
        windowController.teardown()
        screenObserver.cancel()
    }

    // MARK: - State machine

    private func reconcilePresentation() {
        guard !isTornDown else { return }

        guard isEnabled else {
            hideAudience(status: nil)
            return
        }

        guard selectedDisplayID != nil else {
            hideAudience(status: "Select a display for audience output.")
            return
        }

        guard let display = resolvedSelection else {
            // Disconnect: hide, retain selection + enabled intent, restrained status.
            hideAudience(status: "Audience display disconnected.")
            return
        }

        // Connected (including reconnect of same UUID): show/reframe.
        statusMessage = nil
        showAudience(on: display)
    }

    private func showAudience(on display: MacDisplayDescriptor) {
        guard let contentFactory else {
            statusMessage = "Audience output is not ready."
            hideAudience(status: statusMessage)
            return
        }
        if windowController.isVisible {
            // Geometry-only change while already visible: reframe, do not re-present.
            windowController.reframe(to: display.frame)
        } else {
            // Hidden → connected (initial show or reconnect): present content.
            let content = contentFactory()
            windowController.present(frame: display.frame, content: content)
        }
        isAudienceVisible = windowController.isVisible
        if isAudienceVisible {
            statusMessage = nil
        }
    }

    private func hideAudience(status: String?) {
        if windowController.isVisible {
            windowController.hide()
        }
        isAudienceVisible = false
        statusMessage = status
    }
}
