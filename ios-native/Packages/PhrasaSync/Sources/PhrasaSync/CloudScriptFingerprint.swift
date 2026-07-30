import CryptoKit
import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

/// A stable digest of script **row identity (UUID)** and **editable content**.
/// Mutable timestamps are excluded and reconciled monotonically after content
/// is compared. Outline placeholders with neither text nor a note are omitted.
///
/// ## Why `createdAt` is not in the digest (v2)
/// Row identity is the UUID primary key. `createdAt` is immutable metadata, not
/// user-editable content. Including it caused false content conflicts when:
/// 1. JSON wire truncation shifted sub-ms creates, or
/// 2. Content updates accidentally rewrote `created_at` and Double encoding
///    slipped an already-ms value by 1 ms (production: `.734` → `.733` after a
///    successful tags update). Local desired still had `.734`, fingerprint
///    rejected the successful response, baseline stayed stale, retries risked
///    Local conflict copies.
/// Excluding `createdAt` heals already-damaged rows on retry when tags/body/…
/// agree, without weakening genuine editable-content conflict detection.
/// Baselines recorded under v1 (with createdAt) re-anchor on the next
/// successful two-sided content match via `reconcileMatchingContent`.
public enum CloudScriptFingerprint {
    public static func make(_ script: ScriptDocument) -> String {
        var framedFields: [String] = []

        func append(_ value: String?) {
            guard let value else {
                framedFields.append("-1:")
                return
            }
            framedFields.append("\(value.utf8.count):\(value)")
        }

        append("phrasa-cloud-script-v2")
        append(script.id.uuidString.lowercased())
        append(script.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled script"
            : script.title)
        append(script.body)
        append(script.source.rawValue)
        append(script.folderID?.uuidString.lowercased())

        append(String(script.tags.count))
        for tag in script.tags { append(tag) }

        let outline = script.outline.filter {
            CloudOutlinePoint.hasMeaningfulContent(text: $0.text, note: $0.note)
        }
        append(String(outline.count))
        for point in outline {
            append(point.id.uuidString.lowercased())
            append(point.text)
            append(point.note)
        }

        let digest = SHA256.hash(data: Data(framedFields.joined().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum CloudScriptVersion {
    public static func matches(_ left: ScriptDocument, _ right: ScriptDocument) -> Bool {
        // updatedAt stays microsecond-exact: OCC predicates/deletes must still
        // distinguish sub-ms stale expected values. lastOpenedAt uses wire ms
        // so a server echo cannot force repeat open uploads.
        CloudScriptFingerprint.make(left) == CloudScriptFingerprint.make(right)
            && CloudTimestampPrecision.matches(left.updatedAt, right.updatedAt)
            && CloudTimestampPrecision.wireMatches(left.lastOpenedAt, right.lastOpenedAt)
    }

    public static func mergingMetadata(
        contentFrom preferred: ScriptDocument,
        local: ScriptDocument,
        remote: ScriptDocument
    ) -> ScriptDocument {
        var merged = preferred
        // updatedAt OCC precision unchanged (µs latest).
        merged.updatedAt = CloudTimestampPrecision.latest(local.updatedAt, remote.updatedAt)
        // Open recency at wire precision: sub-ms local vs server is one open.
        merged.lastOpenedAt = CloudTimestampPrecision.wireLatest(
            local.lastOpenedAt,
            remote.lastOpenedAt
        )
        return merged
    }
}

/// Deterministic unfiled conflict copy for divergent script edits.
public enum CloudScriptConflictCopy {
    public static func make(local: ScriptDocument, accountID: UUID) -> ScriptDocument {
        let localFingerprint = CloudScriptFingerprint.make(local)
        let seed = [
            "phrasa-script-conflict-v1",
            accountID.uuidString.lowercased(),
            local.id.uuidString.lowercased(),
            localFingerprint
        ].joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        var copy = local
        copy.id = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        // Keep the preserved copy unfiled so its retry representation never
        // depends on a separately reconciled folder row.
        copy.folderID = nil
        let baseTitle = local.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled script"
            : local.title
        copy.title = "\(baseTitle) — Local conflict"
        return copy
    }
}
