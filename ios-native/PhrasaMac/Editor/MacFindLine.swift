import Foundation
import PhrasaDomain

/// Mac find-a-line policy. Delegates to the shared domain matcher so iPad and
/// Mac stay aligned, while tests can keep targeting this type name.
enum MacFindLineService {
    static func firstMatchRange(
        in body: String,
        query: String,
        fromUTF16Offset: Int = 0
    ) -> NSRange? {
        FindLineMatching.firstMatchRange(
            in: body,
            query: query,
            fromUTF16Offset: fromUTF16Offset
        )
    }

    static func lineNumber(in body: String, utf16Offset: Int) -> Int {
        FindLineMatching.lineNumber(in: body, utf16Offset: utf16Offset)
    }
}
