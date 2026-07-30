import Foundation
import Supabase
#if canImport(PhrasaSync)
import PhrasaSync
#endif
// When these sources are embedded into the host app module beside PhrasaSync
// sources, types resolve in-module without an import. Never import the host
// module from embedded package sources (circular).

public enum SupabaseClientFactory {
    /// Creates one app-wide client. The SDK stores refresh credentials in the
    /// platform Keychain and uses PKCE for email links and OAuth providers.
    /// `keychainService` is platform-specific (iOS vs Mac bundle id suffix).
    public static func make(
        configuration: CloudConfiguration,
        keychainService: String = "com.phrasa.app.supabase.auth",
        storageKey: String = "phrasa.supabase.session"
    ) -> SupabaseClient {
        let authOptions = SupabaseClientOptions.AuthOptions(
            storage: KeychainLocalStorage(service: keychainService),
            redirectToURL: configuration.redirectURL,
            storageKey: storageKey,
            flowType: .pkce,
            autoRefreshToken: true,
            emitLocalSessionAsInitialSession: false
        )
        return SupabaseClient(
            supabaseURL: configuration.projectURL,
            supabaseKey: configuration.publishableKey,
            options: SupabaseClientOptions(auth: authOptions)
        )
    }
}
