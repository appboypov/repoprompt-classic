import Foundation
import AppKit

/// Caches pre-highlighted code blocks as attributed strings.
/// - Uses NSCache for automatic eviction.
/// - Cache key format: "language|hash|fontSize".
@MainActor
class CodeHighlightCache {
    static let shared = CodeHighlightCache()

    private let cache = NSCache<NSString, NSAttributedString>()

    /// Returns a pre-highlighted attributed string for the given code snippet.
    /// - Parameters:
    ///   - code: Raw code text.
    ///   - language: Optional language hint.
    ///   - fontPointSize: Monospaced font size to render with.
    func highlighted(_ code: String, language: String? = nil, fontPointSize: CGFloat) -> NSAttributedString {
        let key = "\(language ?? "plain")|\(code.hashValue)|\(Int(fontPointSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Build base attributes and highlight synchronously
        let font = NSFont.monospacedSystemFont(ofSize: fontPointSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        let mutable = NSMutableAttributedString(string: code, attributes: attrs)

        // Reuse the app's highlighter
        CodeHighlighter.applyHighlighting(to: mutable, code: code)

        cache.setObject(mutable, forKey: key)
        return mutable
    }

    /// Clears the cache (optional; NSCache will also auto-evict entries).
    func clear() {
        cache.removeAllObjects()
    }
}
