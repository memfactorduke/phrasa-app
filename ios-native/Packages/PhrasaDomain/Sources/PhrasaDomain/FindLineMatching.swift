import Foundation

/// Pure find-a-line matching for Mac and keyboard-equipped iPad editors.
/// UI layers own presentation; this type only locates ranges and line numbers.
public enum FindLineMatching {
    /// Returns the UTF-16 `NSRange` of the first case-insensitive match of
    /// `query` in `body` at or after `fromUTF16Offset`, wrapping once to the start.
    public static func firstMatchRange(
        in body: String,
        query: String,
        fromUTF16Offset: Int = 0
    ) -> NSRange? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let nsBody = body as NSString
        let full = NSRange(location: 0, length: nsBody.length)
        let start = max(0, min(fromUTF16Offset, nsBody.length))
        let tail = NSRange(location: start, length: nsBody.length - start)

        let tailMatch = nsBody.range(
            of: trimmed,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: tail
        )
        if tailMatch.location != NSNotFound {
            return tailMatch
        }

        if start > 0 {
            let head = NSRange(location: 0, length: start)
            let headMatch = nsBody.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: head
            )
            if headMatch.location != NSNotFound {
                return headMatch
            }
        }

        let whole = nsBody.range(
            of: trimmed,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: full
        )
        return whole.location == NSNotFound ? nil : whole
    }

    /// 1-based line number containing the given UTF-16 offset.
    public static func lineNumber(in body: String, utf16Offset: Int) -> Int {
        let nsBody = body as NSString
        let clamped = max(0, min(utf16Offset, nsBody.length))
        var line = 1
        var index = 0
        while index < clamped {
            let ch = nsBody.character(at: index)
            if ch == 0x0A { // \n
                line += 1
            } else if ch == 0x0D { // \r
                line += 1
                let next = index + 1
                if next < clamped, nsBody.character(at: next) == 0x0A {
                    index = next
                }
            }
            index += 1
        }
        return line
    }
}
