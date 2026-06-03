import AppKit

/// Helper that produces an `NSAttributedString` whose occurrences of `query`
/// (case-insensitive) are marked with a yellow background.  If `query` is empty
/// the original plain string is returned.
enum SearchTextHighlighter {
    static func make(fullText: String,
                     query: String,
                     font: NSFont = FontScalePreset.current.nsFont) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: fullText)
        // Apply base font first so highlight and empty-query results do not revert to system default
        if attributed.length > 0 {
            attributed.addAttribute(.font,
                                    value: font,
                                    range: NSRange(location: 0, length: attributed.length))
        }
        guard !query.isEmpty else { return attributed }

        let lowerFull  = fullText.lowercased()
        let lowerQuery = query.lowercased()

        var searchRange: Range<String.Index>? = lowerFull.startIndex..<lowerFull.endIndex

        while let range = lowerFull.range(of: lowerQuery, options: [], range: searchRange) {
            let nsRange = NSRange(range, in: fullText)
            attributed.addAttribute(.backgroundColor,
                                    value: NSColor.searchHighlightColor,
                                    range: nsRange)
            // Continue searching after the current match
            searchRange = range.upperBound..<lowerFull.endIndex
        }
        return attributed
    }
}