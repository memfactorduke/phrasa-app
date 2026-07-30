import CryptoKit
import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

/// Wire shape for outline points. Empty text+note placeholders are dropped so
/// fingerprints and payloads stay stable across encode/decode.
public struct CloudOutlinePoint: Codable, Sendable {
    public let id: String
    public let text: String
    public let note: String?

    public init(_ point: OutlinePoint) {
        id = point.id.uuidString
        text = point.text
        note = point.note.isEmpty ? nil : point.note
    }

    public static func cloudPoints(from points: [OutlinePoint]) -> [Self]? {
        let encoded = points.compactMap { point -> Self? in
            let cloudPoint = Self(point)
            return hasMeaningfulContent(text: cloudPoint.text, note: cloudPoint.note)
                ? cloudPoint
                : nil
        }
        return encoded.isEmpty ? nil : encoded
    }

    public static func hasMeaningfulContent(text: String, note: String?) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var point: OutlinePoint? {
        guard Self.hasMeaningfulContent(text: text, note: note) else { return nil }
        return OutlinePoint(
            id: UUID(uuidString: id) ?? Self.stableID(for: id),
            text: text,
            note: note ?? ""
        )
    }

    private static func stableID(for value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
