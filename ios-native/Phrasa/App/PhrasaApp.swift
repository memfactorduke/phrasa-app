import SwiftUI

@main
struct PhrasaApp: App {
    @State private var library = LibraryStore()
    @State private var accountSync = CloudAccountSyncRuntime.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(accountSync)
                .task {
                    // Local library load is always first and never waits on network.
                    await library.load()
                    accountSync.attach(library: library)
                    accountSync.start()
                    accountSync.handleLaunch()
                }
                .onOpenURL { url in
                    Task { await accountSync.handleOpenURL(url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        accountSync.handleForeground()
                    }
                }
        }
    }
}
