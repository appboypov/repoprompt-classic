import Foundation

struct ParsedPath: Hashable {
    let displayPath: String
    let path: String
}

/// Extracts file and folder paths from messy, real-world pasted text.
///
/// Optimized for large inputs (e.g., huge git diffs) via:
/// - Streaming line enumeration (no giant array allocation)
/// - Yield-based extraction (no intermediate arrays)
/// - Smart pre-filtering to skip lines that can't contain paths
/// - Length cap to skip absurdly long tokens
enum PastedPathExtractor {

    // Hard cap to avoid spending time on absurdly-long "tokens" (minified blobs, base64, etc.)
    private static let maxCandidateLength = 2048

    static func extractPaths(from text: String) -> [ParsedPath] {
        // Avoid allocating a trimmed copy of huge text; just check "has any non-whitespace".
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else { return [] }

        var results: [ParsedPath] = []
        results.reserveCapacity(64)

        var seen = Set<String>()
        seen.reserveCapacity(128)

        var tree = TreeReconstructor()

        // Stream lines (no giant array allocation for large pastes).
        text.enumerateLines { line, _ in
            let isTreeLine = TreeReconstructor.isTreeLine(line)

            if isTreeLine {
                for item in tree.consume(line: line) {
                    appendUnique(item, into: &results, seen: &seen)
                }
            }

            extractPathsFromLine(line, suppressBareFilenames: isTreeLine) { item in
                appendUnique(item, into: &results, seen: &seen)
            }
        }

        return results
    }

    // MARK: - Per-line extraction

    @inline(__always)
    private static func extractPathsFromLine(_ line: String, suppressBareFilenames: Bool, yield: (ParsedPath) -> Void) {
        guard !line.isEmpty else { return }

        // Very common in huge diffs; handle and bail early.
        if line.hasPrefix("diff --git ") {
            extractGitDiffHeaderPaths(from: line, yield: yield)
            return
        }
        if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
            extractGitDiffMarkerPaths(from: line, yield: yield)
            return
        }

        // Cheap pre-filter to avoid regex work on lines that obviously can't contain paths.
        let hasSlash = line.contains("/")
        let hasTilde = line.contains("~")
        let hasFileURL = line.contains("file://")
        let hasMarkdownLink = line.contains("](")
        let hasQuoteOrTick = line.contains("\"") || line.contains("'") || line.contains("`")

        if !(hasSlash || hasTilde || hasFileURL || hasMarkdownLink || hasQuoteOrTick) && !mayContainBareFilename(line, suppressBareFilenames: suppressBareFilenames) {
            return
        }

        // Quoted/backticked is only useful for paths with spaces; regex is written to require / . or ~ inside.
        if hasQuoteOrTick {
            matches(regex: Regex.quotedOrBackticked, in: line, captureGroup: 2, inDiffContext: false, yield: yield)
        }

        if hasMarkdownLink {
            matches(regex: Regex.markdownLinkTarget, in: line, captureGroup: 1, inDiffContext: false, yield: yield)
        }

        // One generic token regex instead of multiple "absolute / dot-relative / slash-relative" passes.
        if hasSlash || hasTilde || hasFileURL {
            matches(regex: Regex.genericPathToken, in: line, captureGroup: nil, inDiffContext: false, yield: yield)
        }

        if mayContainBareFilename(line, suppressBareFilenames: suppressBareFilenames) {
            matches(regex: Regex.bareFileToken, in: line, captureGroup: nil, inDiffContext: false, yield: yield)
        }
    }

    private static func mayContainBareFilename(_ line: String, suppressBareFilenames: Bool) -> Bool {
        guard !suppressBareFilenames else { return false }

        // Compiler-ish hints: `File.swift:123` or `File.swift#L123`
        if line.contains("#L") { return true }

        // Only treat `:` as a "line suffix hint" if a digit immediately follows a colon somewhere.
        var prevWasColon = false
        for ch in line.unicodeScalars {
            if prevWasColon, CharacterSet.decimalDigits.contains(ch) { return true }
            prevWasColon = (ch == ":")
        }

        // Prose: "See File.swift" (no slash). Avoid the expensive regex unless we see a plausible extension hint.
        guard line.contains(".") else { return false }

        for hint in commonBareFileExtensionHints {
            if line.range(of: hint, options: .caseInsensitive) != nil { return true }
        }

        return false
    }

    // MARK: - Git diff extraction

    private static func extractGitDiffHeaderPaths(from line: String, yield: (ParsedPath) -> Void) {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)

        guard let match = Regex.gitDiffHeader.firstMatch(in: line, options: [], range: range) else { return }

        let aRange = match.range(at: 1)
        if aRange.location != NSNotFound, aRange.length > 0, aRange.length <= maxCandidateLength {
            let aPath = ns.substring(with: aRange)
            let display = "a/\(aPath)"
            if let parsed = buildParsedPath(displayCandidate: display, inDiffContext: true, allowSingleSegmentPaths: false) {
                yield(parsed)
            }
        }

        let bRange = match.range(at: 2)
        if bRange.location != NSNotFound, bRange.length > 0, bRange.length <= maxCandidateLength {
            let bPath = ns.substring(with: bRange)
            let display = "b/\(bPath)"
            if let parsed = buildParsedPath(displayCandidate: display, inDiffContext: true, allowSingleSegmentPaths: false) {
                yield(parsed)
            }
        }
    }

    private static func extractGitDiffMarkerPaths(from line: String, yield: (ParsedPath) -> Void) {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)

        guard let match = Regex.gitDiffMarker.firstMatch(in: line, options: [], range: range) else { return }

        let pathRange = match.range(at: 1)
        guard pathRange.location != NSNotFound, pathRange.length > 0, pathRange.length <= maxCandidateLength else { return }

        let token = ns.substring(with: pathRange)
        if let parsed = buildParsedPath(displayCandidate: token, inDiffContext: true, allowSingleSegmentPaths: false) {
            yield(parsed)
        }
    }

    private static func matches(
        regex: NSRegularExpression,
        in line: String,
        captureGroup: Int?,
        inDiffContext: Bool,
        yield: (ParsedPath) -> Void
    ) {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)

        regex.enumerateMatches(in: line, options: [], range: range) { match, _, _ in
            guard let match else { return }

            let r: NSRange
            if let captureGroup {
                guard match.numberOfRanges > captureGroup else { return }
                r = match.range(at: captureGroup)
            } else {
                r = match.range
            }

            guard r.location != NSNotFound, r.length > 0, r.length <= maxCandidateLength else { return }

            let raw = ns.substring(with: r)
            if let parsed = buildParsedPath(displayCandidate: raw, inDiffContext: inDiffContext, allowSingleSegmentPaths: false) {
                yield(parsed)
            }
        }
    }

    // MARK: - Build / clean / validate

    private static func buildParsedPath(
        displayCandidate: String,
        inDiffContext: Bool,
        allowSingleSegmentPaths: Bool
    ) -> ParsedPath? {
        var display = trimWrappingCharacters(displayCandidate)
        guard !display.isEmpty else { return nil }

        if let fileURLPath = decodeFileURLToPath(display) {
            display = fileURLPath
        }

        let cleaned = cleanForLookup(display, inDiffContext: inDiffContext)

        guard isValidPath(cleaned, allowSingleSegmentPaths: allowSingleSegmentPaths) else { return nil }

        return ParsedPath(displayPath: display, path: cleaned)
    }

    private static func cleanForLookup(_ display: String, inDiffContext: Bool) -> String {
        var result = display.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip ANSI color codes (only if present - fast path check first)
        result = stripANSIEscapes(result)

        if let fileURLPath = decodeFileURLToPath(result) {
            result = fileURLPath
        }

        if result.hasPrefix("~/") {
            result = (result as NSString).expandingTildeInPath
        }

        result = trimWrappingCharacters(result)
        result = stripLineSuffixes(result)

        if inDiffContext {
            result = stripGitDiffPrefix(result)
        }

        while result.hasSuffix("/") && result.count > 1 {
            result.removeLast()
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripANSIEscapes(_ s: String) -> String {
        // Fast path: most strings won't contain ANSI escapes (ESC = 0x1B)
        guard s.contains("\u{001B}") else { return s }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        return Regex.ansiEscape.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }

    private static func stripLineSuffixes(_ path: String) -> String {
        var result = path

        // Avoid regex work unless the delimiter is present.
        if result.contains("#L") {
            let ns = result as NSString
            let range = NSRange(location: 0, length: ns.length)
            result = Regex.githubLineSuffix.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        if result.contains(":") {
            let ns = result as NSString
            let range = NSRange(location: 0, length: ns.length)
            result = Regex.colonLineSuffix.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        return result
    }

    private static func stripGitDiffPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }

    private static func isValidPath(_ path: String, allowSingleSegmentPaths: Bool) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }

        let lower = trimmed.lowercased()

        if lower == "/dev/null" { return false }

        for blocked in blockedSubstrings {
            if lower.contains(blocked) { return false }
        }

        if looksLikeURL(trimmed) { return false }

        if trimmed.rangeOfCharacter(from: .letters) == nil { return false }

        if trimmed.contains("/") {
            return true
        }

        if let ext = trimmed.split(separator: ".").last.map({ String($0).lowercased() }),
           trimmed.contains(".") {
            return allowedBareFileExtensions.contains(ext)
        }

        guard allowSingleSegmentPaths else { return false }
        return isPlausibleSingleSegment(trimmed)
    }

    private static func isPlausibleSingleSegment(_ token: String) -> Bool {
        if token.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return false }
        if token.hasPrefix("-") { return false }
        if token.count > 128 { return false }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func looksLikeURL(_ candidate: String) -> Bool {
        let s = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()

        if lower.hasPrefix("file://") { return false }

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://") || lower.hasPrefix("mailto:") {
            return true
        }
        if lower.contains("://") { return true }
        if lower.hasPrefix("www.") { return true }

        if !lower.hasPrefix("/") && !lower.hasPrefix("~/") && !lower.hasPrefix("./") && !lower.hasPrefix("../") {
            let firstComponent = lower.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            if firstComponent.contains(".") {
                let host = firstComponent.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? firstComponent
                if let tld = host.split(separator: ".").last.map({ String($0) }),
                   commonTLDs.contains(tld) {
                    return true
                }
            }
        }

        return false
    }

    private static func trimWrappingCharacters(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        while let first = result.first, leadingWrappers.contains(first) {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while let last = result.last, trailingWrappers.contains(last) {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    private static func decodeFileURLToPath(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("file://") else { return nil }
        guard let url = URL(string: trimmed), url.isFileURL else { return nil }
        return url.path
    }

    // MARK: - Deduplication

    private static func appendUnique(_ item: ParsedPath, into results: inout [ParsedPath], seen: inout Set<String>) {
        let key = dedupeKey(for: item.path)
        guard !seen.contains(key) else { return }
        seen.insert(key)
        results.append(item)
    }

    private static func dedupeKey(for path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)

        while p.hasPrefix("./") {
            p.removeFirst(2)
        }

        while p.contains("//") {
            p = p.replacingOccurrences(of: "//", with: "/")
        }

        while p.hasSuffix("/") && p.count > 1 {
            p.removeLast()
        }

        return p.lowercased()
    }

    // MARK: - Constants / Regex

    private enum Regex {
        static let gitDiffHeader = try! NSRegularExpression(
            pattern: #"diff --git\s+a/(\S+)\s+b/(\S+)"#,
            options: []
        )

        static let gitDiffMarker = try! NSRegularExpression(
            pattern: #"^(?:\+\+\+|---)\s+([ab]/\S+)"#,
            options: [.anchorsMatchLines]
        )

        // Matches "..." '...' `...` BUT requires the inner text to contain / or . or ~,
        // and uses a backreference so opening/closing quotes match.
        // Group 2 is the content (path).
        static let quotedOrBackticked = try! NSRegularExpression(
            pattern: #"(["'`])(?=[^"'`\n]*(?:/|\.|~))([^"'`\n]+)\1"#,
            options: []
        )

        static let markdownLinkTarget = try! NSRegularExpression(
            pattern: #"\[[^\]]+\]\(([^)\s]+)\)"#,
            options: []
        )

        // One token regex for absolute, ~/ , ./ , ../ and slash-relative paths.
        // Also supports file://... tokens.
        // Requires at least one ASCII letter to avoid matching stuff like "////" or "123/456".
        static let genericPathToken = try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])(?=[^\s"'`]*[A-Za-z])(?:file://|~\/|\/|\.\.?\/|[A-Za-z0-9._-]+\/)[^\s"'`]+"#,
            options: []
        )

        static let bareFileToken = try! NSRegularExpression(
            pattern: #"\b[A-Za-z0-9][A-Za-z0-9._-]*\.(?:swift|m|mm|c|cc|cpp|h|hpp|inc|js|ts|jsx|tsx|py|rb|go|java|kt|kts|cs|rs|php|html|css|scss|json|yml|yaml|toml|md|txt|log|plist|xcconfig|xcodeproj|pbxproj|storyboard|xib)\b(?::\d+(?::\d+)?)?(?:#L\d+(?:-\d+)?)?"#,
            options: []
        )

        static let githubLineSuffix = try! NSRegularExpression(
            pattern: #"#L\d+(?:-\d+)?$"#,
            options: []
        )

        static let colonLineSuffix = try! NSRegularExpression(
            pattern: #":\d+(?::\d+)?$"#,
            options: []
        )

        // ANSI escape sequences (ESC[...m)
        static let ansiEscape = try! NSRegularExpression(
            pattern: "\\x1B\\[[0-9;]*m",
            options: []
        )
    }

    private static let blockedSubstrings: [String] = [
        "http://", "https://", "ftp://", "mailto:",
        "/.git/", ".git/", "\\.git\\",
        "node_modules"
    ]

    private static let commonTLDs: Set<String> = [
        "com", "net", "org", "io", "dev", "app", "ai", "co", "me", "ca", "uk", "de", "fr", "jp", "cn",
        "edu", "gov", "info", "biz"
    ]

    private static let allowedBareFileExtensions: Set<String> = [
        "swift", "m", "mm", "c", "cc", "cpp", "h", "hpp", "inc",
        "js", "ts", "jsx", "tsx",
        "py", "rb", "go", "java", "kt", "kts", "cs", "rs", "php",
        "html", "css", "scss",
        "json", "yml", "yaml", "toml",
        "md", "txt", "log",
        "plist", "xcconfig", "xcodeproj", "pbxproj", "storyboard", "xib"
    ]

    // Keep this list small-ish for speed; it's only a gate for running the full regex.
    private static let commonBareFileExtensionHints: [String] = [
        ".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".h", ".hpp",
        ".json", ".plist", ".md", ".txt", ".log",
        ".yml", ".yaml", ".toml",
        ".xcconfig", ".pbxproj", ".xcodeproj",
        ".storyboard", ".xib", ".html", ".css", ".scss"
    ]

    private static let leadingWrappers: Set<Character> = ["\"", "'", "`", "(", "[", "{", "<"]
    private static let trailingWrappers: Set<Character> = ["\"", "'", "`", ")", "]", "}", ">", ",", ";", ".", ":"]
}

// MARK: - Tree output reconstructor

private extension PastedPathExtractor {

    struct TreeReconstructor {
        private var stack: [String] = []

        static func isTreeLine(_ line: String) -> Bool {
            line.contains("├──") || line.contains("└──") || line.contains("|--") || line.contains("`--")
        }

        mutating func consume(line: String) -> [ParsedPath] {
            guard let parsed = parseTreeLine(line) else { return [] }

            if stack.count > parsed.depth {
                stack.removeLast(stack.count - parsed.depth)
            }

            let name = parsed.name
            let isDirectory = parsed.isDirectory

            if isDirectory {
                stack.append(name)
                let full = stack.joined(separator: "/")
                if let item = PastedPathExtractor.buildParsedPath(displayCandidate: full, inDiffContext: false, allowSingleSegmentPaths: true) {
                    return [item]
                }
                return []
            } else {
                let full = (stack + [name]).joined(separator: "/")
                if let item = PastedPathExtractor.buildParsedPath(displayCandidate: full, inDiffContext: false, allowSingleSegmentPaths: true) {
                    return [item]
                }
                return []
            }
        }

        private func parseTreeLine(_ line: String) -> (depth: Int, name: String, isDirectory: Bool)? {
            let markers: [String] = ["├──", "└──", "|--", "`--"]

            guard let marker = markers.first(where: { line.contains($0) }),
                  let markerRange = line.range(of: marker) else {
                return nil
            }

            let prefix = String(line[..<markerRange.lowerBound])
            let after = String(line[markerRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            guard !after.isEmpty else { return nil }

            let depth = treeDepth(fromPrefix: prefix)
            let cleanedNameToken = stripTrailingMetaTokens(after)

            let isDirectory = cleanedNameToken.hasSuffix("/")
                || (!cleanedNameToken.contains(".") && !cleanedNameToken.contains("#"))

            let name = cleanedNameToken.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            guard !name.isEmpty else { return nil }

            return (depth: depth, name: name, isDirectory: isDirectory)
        }

        private func treeDepth(fromPrefix prefix: String) -> Int {
            var depth = 0
            var i = prefix.startIndex

            while i < prefix.endIndex {
                let remaining = prefix[i...]
                if remaining.hasPrefix("│   ") || remaining.hasPrefix("|   ") || remaining.hasPrefix("    ") {
                    depth += 1
                    i = prefix.index(i, offsetBy: 4, limitedBy: prefix.endIndex) ?? prefix.endIndex
                } else {
                    i = prefix.index(after: i)
                }
            }

            return depth
        }

        private func stripTrailingMetaTokens(_ s: String) -> String {
            let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { return s }

            var trimmed = parts
            while let last = trimmed.last, isMetaToken(last) {
                trimmed.removeLast()
            }
            return trimmed.joined(separator: " ")
        }

        private func isMetaToken(_ token: String) -> Bool {
            if token == "*" || token == "+" { return true }
            if token.hasPrefix("(") && token.hasSuffix(")") { return true }
            return false
        }
    }
}
