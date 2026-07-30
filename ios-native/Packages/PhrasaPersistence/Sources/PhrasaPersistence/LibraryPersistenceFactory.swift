import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

/// Construction boundary for library stores.
///
/// - Shipping code must use `makeShipping` (SQLite + recovery).
/// - `makeJSONTestDouble` exists only for unit tests and migration fixtures.
public enum LibraryPersistenceFactory {
    /// Production offline library: one SQLite file with WAL, migrations, and recovery.
    public static func makeShipping(
        fileURL: URL? = nil
    ) -> SQLitePersistenceClient {
        SQLitePersistenceClient(fileURL: fileURL)
    }

    /// Explicit test double. Never call from app launch or feature screens.
    public static func makeJSONTestDouble(fileURL: URL? = nil) -> PersistenceClient {
        PersistenceClient(fileURL: fileURL)
    }
}
