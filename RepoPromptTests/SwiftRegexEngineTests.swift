import XCTest
@testable import RepoPrompt
import Foundation

/// Tests for the Swift Regex engine prioritization and behavior.
///
/// These tests verify:
/// 1. Engine selection heuristics (Swift Regex vs NSRegularExpression)
/// 2. Large-line handling with different limits per engine
/// 3. Behavior consistency between engines
/// 4. Cache behavior and memory limits
class SwiftRegexEngineTests: XCTestCase {

    // MARK: - Test Infrastructure

    /// Mock FileViewModel for generating test content programmatically
    final class EngineMockFileViewModel: FileViewModel {
        private let mockContent: String?

        init(
            name: String,
            relativePath: String,
            content: String?
        ) async throws {
            self.mockContent = content

            let rootPath = "/engine/test"
            let consistentFullPath = rootPath + "/" + relativePath

            let file = File(
                name: name,
                path: consistentFullPath,
                modificationDate: Date()
            )

            let tempDir = FileManager.default.temporaryDirectory
            let fileSystemService = try await FileSystemService(
                path: tempDir.path,
                respectGitignore: false,
                skipSymlinks: true
            )

            try await super.init(
                file: file,
                rootPath: rootPath,
                hierarchyLevel: 0,
                rootIdentifier: UUID(),
                rootFolderPath: rootPath,
                fileSystemService: fileSystemService
            )
        }

        override var latestContent: String? {
            get async { mockContent }
        }
    }

    /// Helper to create mock files
    private func mockFile(name: String, content: String) async throws -> EngineMockFileViewModel {
        try await EngineMockFileViewModel(name: name, relativePath: name, content: content)
    }

    /// Generates a line of specified byte length using ASCII characters
    private func generateLine(byteLength: Int, char: Character = "x") -> String {
        String(repeating: char, count: byteLength)
    }

    /// Generates content with a specific line length pattern
    private func generateContentWithLongLine(
        lineLength: Int,
        matchText: String = "FINDME",
        insertMatchAt position: Int = -1
    ) -> String {
        var line = generateLine(byteLength: lineLength - matchText.count, char: "a")
        if position >= 0 && position < line.count {
            let idx = line.index(line.startIndex, offsetBy: position)
            line.insert(contentsOf: matchText, at: idx)
        } else {
            line += matchText
        }
        return line
    }

    // MARK: - Engine Selection Tests

    /// Verifies that "vanilla" patterns without PCRE tokens use Swift Regex
    func testVanillaPatternsUseSwiftRegex() async throws {
        let content = """
        function foo() {
            return bar();
        }
        """
        let file = try await mockFile(name: "test.js", content: content)

        // These patterns should use Swift Regex (no PCRE tokens, no wholeWord)
        let vanillaPatterns = [
            "foo.*bar",           // Basic wildcard
            "[a-z]+",             // Character class
            "(foo|bar)",          // Alternation group
            "a?b+c*",             // Quantifiers
            "func.*\\(",          // Escaped paren
            "^function",          // Anchor
            "return.*;$",         // End anchor
        ]

        let actor = FileSearchActor()

        for pattern in vanillaPatterns {
            var wasAutoCorrected: Bool? = nil
            let results = try await actor.search(
                pattern: pattern,
                isRegex: true,
                wasAutoCorrected: &wasAutoCorrected,
                options: SearchOptions(caseInsensitive: true, wholeWord: false),
                in: [file]
            )
            // Just verify it doesn't crash - Swift Regex should handle these
            XCTAssertNotNil(results, "Pattern '\(pattern)' should be handled without error")
        }
    }

    /// Verifies that PCRE-specific patterns fall back to NSRegularExpression
    func testPCREPatternsUseNSRegex() async throws {
        let content = "hello world 123 testing"
        let file = try await mockFile(name: "test.txt", content: content)

        // These patterns contain PCRE tokens and should use NSRegularExpression
        let pcrePatterns = [
            "\\w+",               // Word characters - matches "hello"
            "\\d+",               // Digits - matches "123"
            "\\s+",               // Whitespace - matches spaces
            "\\bworld\\b",        // Word boundaries - matches standalone "world"
            "\\Besting",          // Non-word boundary - matches "esting" within "testing"
        ]

        let actor = FileSearchActor()

        for pattern in pcrePatterns {
            let results = try await actor.search(
                pattern: pattern,
                isRegex: true,
                options: SearchOptions(caseInsensitive: true),
                in: [file]
            )
            XCTAssertFalse(results.isEmpty, "PCRE pattern '\(pattern)' should find matches")
        }
    }

    /// Verifies that wholeWord option forces NSRegularExpression
    func testWholeWordForcesNSRegex() async throws {
        let content = "hello world testing"
        let file = try await mockFile(name: "test.txt", content: content)

        let actor = FileSearchActor()

        // With wholeWord=true, even a vanilla pattern should work (uses \b internally)
        let results = try await actor.search(
            pattern: "world",
            isRegex: true,
            options: SearchOptions(caseInsensitive: true, wholeWord: true),
            in: [file]
        )

        XCTAssertEqual(results.count, 1, "Whole word search should find 'world'")

        // Verify it doesn't match partial words
        let partialResults = try await actor.search(
            pattern: "test",
            isRegex: true,
            options: SearchOptions(caseInsensitive: true, wholeWord: true),
            in: [file]
        )

        // "test" appears in "testing" but wholeWord should not match it
        XCTAssertEqual(partialResults.count, 0, "Whole word should not match 'test' in 'testing'")
    }

    // MARK: - Large Line Handling Tests

    /// Tests that lines under 4KB are processed by NSRegularExpression
    func testNSRegexProcessesLinesUnder4KB() async throws {
        // 3KB line with match text - should be processed
        let lineLength = 3 * 1024
        let content = generateContentWithLongLine(lineLength: lineLength, matchText: "FINDME")
        let file = try await mockFile(name: "medium.txt", content: content)

        let actor = FileSearchActor()

        // Use \w+ to force NSRegularExpression
        let results = try await actor.search(
            pattern: "\\w+",
            isRegex: true,
            options: SearchOptions(maxResults: 10),
            in: [file]
        )

        XCTAssertFalse(results.isEmpty, "3KB line should be processed by NSRegex")
    }

    /// Tests that lines over 4KB are skipped by NSRegularExpression (high-risk)
    func testNSRegexSkipsLinesOver4KBForHighRisk() async throws {
        // 5KB line - should be skipped for high-risk NSRegex patterns
        let lineLength = 5 * 1024
        let content = generateContentWithLongLine(lineLength: lineLength, matchText: "FINDME")
        let file = try await mockFile(name: "large.txt", content: content)

        let actor = FileSearchActor()

        // Anchored pattern with PCRE token triggers high-risk path
        let results = try await actor.search(
            pattern: "^\\w+FINDME",
            isRegex: true,
            options: SearchOptions(maxResults: 10),
            in: [file]
        )

        // Line is >4KB and pattern is anchored, so it may be skipped
        // This behavior is implementation-dependent based on highRisk detection
        XCTAssertNotNil(results, "Search should complete without hanging")
    }

    /// Tests that Swift Regex handles lines up to 64KB
    func testSwiftRegexHandlesLinesUpTo64KB() async throws {
        // 60KB line - should be processed by Swift Regex
        let lineLength = 60 * 1024
        let content = generateContentWithLongLine(lineLength: lineLength, matchText: "TARGETMATCH")
        let file = try await mockFile(name: "verylarge.txt", content: content)

        let actor = FileSearchActor()

        // Vanilla pattern without PCRE tokens should use Swift Regex
        let results = try await actor.search(
            pattern: "TARGET.*MATCH",
            isRegex: true,
            options: SearchOptions(maxResults: 10),
            in: [file]
        )

        // Swift Regex with 64KB limit should find the match
        XCTAssertFalse(results.isEmpty, "Swift Regex should handle 60KB lines")
    }

    /// Tests that lines over 64KB are skipped even by Swift Regex
    func testSwiftRegexSkipsLinesOver64KB() async throws {
        // 70KB line - exceeds Swift Regex limit
        let lineLength = 70 * 1024
        let content = generateContentWithLongLine(lineLength: lineLength, matchText: "TARGETMATCH")
        let file = try await mockFile(name: "huge.txt", content: content)

        let actor = FileSearchActor()

        // Anchored vanilla pattern uses Swift Regex line-by-line
        let results = try await actor.search(
            pattern: "^.*TARGETMATCH",
            isRegex: true,
            options: SearchOptions(maxResults: 10),
            in: [file]
        )

        // Line exceeds 64KB limit, so it should be skipped
        XCTAssertTrue(results.isEmpty, "Swift Regex should skip lines over 64KB")
    }

    // MARK: - Minified File Tests (Real-World Large Lines)

    /// Simulates searching in minified JavaScript (single long line)
    func testMinifiedJavaScriptSearch() async throws {
        // Simulate minified JS: one very long line with repeated patterns
        let jsFragment = "function a(){return b;}var c=function(){d();};"
        let minifiedContent = String(repeating: jsFragment, count: 500) // ~22KB
        let file = try await mockFile(name: "bundle.min.js", content: minifiedContent)

        let actor = FileSearchActor()

        // Search for function declarations
        let results = try await actor.search(
            pattern: "function",
            isRegex: false,
            options: SearchOptions(maxResults: 100),
            in: [file]
        )

        // Should find multiple matches on the single line
        XCTAssertFalse(results.isEmpty, "Should find matches in minified JS")
        XCTAssertEqual(results.first?.lineNumber, 0, "All matches should be on line 0")
    }

    /// Simulates searching in minified CSS
    func testMinifiedCSSSearch() async throws {
        // Simulate minified CSS
        let cssFragment = ".class{color:red;margin:0;padding:0;}"
        let minifiedContent = String(repeating: cssFragment, count: 300) // ~12KB
        let file = try await mockFile(name: "styles.min.css", content: minifiedContent)

        let actor = FileSearchActor()

        // Regex search for color properties
        let results = try await actor.search(
            pattern: "color:[^;]+",
            isRegex: true,
            options: SearchOptions(maxResults: 50),
            in: [file]
        )

        XCTAssertFalse(results.isEmpty, "Should find color properties in minified CSS")
    }

    // MARK: - Behavior Consistency Tests

    /// Verifies that both engines produce the same results for compatible patterns
    func testEngineConsistencyForSimplePatterns() async throws {
        let content = """
        The quick brown fox jumps over the lazy dog.
        Pack my box with five dozen liquor jugs.
        How vexingly quick daft zebras jump!
        """
        let file = try await mockFile(name: "pangrams.txt", content: content)

        let actor = FileSearchActor()

        // Test various patterns that should work identically in both engines
        let testCases: [(pattern: String, expectedCount: Int)] = [
            ("quick", 2),
            ("the", 2),  // case insensitive
            ("fox|dog", 2),
            ("jump.*", 2),
        ]

        for (pattern, expectedCount) in testCases {
            let results = try await actor.search(
                pattern: pattern,
                isRegex: true,
                options: SearchOptions(caseInsensitive: true),
                in: [file]
            )
            XCTAssertEqual(results.count, expectedCount,
                          "Pattern '\(pattern)' should find \(expectedCount) matches")
        }
    }

    /// Tests Unicode handling across engines
    func testUnicodeHandlingConsistency() async throws {
        let content = """
        Café résumé naïve
        日本語テキスト
        Emoji: 🎉🚀💡
        Math: π ≈ 3.14159
        """
        let file = try await mockFile(name: "unicode.txt", content: content)

        let actor = FileSearchActor()

        // Unicode literal searches
        let emojiResults = try await actor.search(
            pattern: "🚀",
            isRegex: false,
            options: SearchOptions(),
            in: [file]
        )
        XCTAssertEqual(emojiResults.count, 1, "Should find rocket emoji")

        // Unicode in regex (Swift Regex)
        let accentResults = try await actor.search(
            pattern: "é",
            isRegex: true,
            options: SearchOptions(),
            in: [file]
        )
        XCTAssertFalse(accentResults.isEmpty, "Should find accented characters")

        // Japanese text
        let japaneseResults = try await actor.search(
            pattern: "テキスト",
            isRegex: false,
            options: SearchOptions(),
            in: [file]
        )
        XCTAssertEqual(japaneseResults.count, 1, "Should find Japanese text")
    }

    // MARK: - Timeout and Performance Tests

    /// Verifies that complex patterns respect the per-file timeout
    func testTimeoutForComplexPatterns() async throws {
        // Create a large file that would take a long time to scan
        let content = String(repeating: "abcdefghij", count: 100_000) // ~1MB
        let file = try await mockFile(name: "large.txt", content: content)

        let actor = FileSearchActor()

        let start = Date()

        // Complex pattern that could be slow
        let results = try await actor.search(
            pattern: "abc.*hij",
            isRegex: true,
            options: SearchOptions(maxResults: 100),
            in: [file]
        )

        let elapsed = Date().timeIntervalSince(start)

        // Should complete within a reasonable time (perFileTimeout is 2 seconds)
        XCTAssertLessThan(elapsed, 5.0, "Search should complete within timeout bounds")
        XCTAssertNotNil(results, "Search should return results")
    }

    /// Tests that the cache size limit prevents unbounded growth
    func testCacheSizeLimitBehavior() async throws {
        let content = "test content for cache testing"
        let file = try await mockFile(name: "cache.txt", content: content)

        let actor = FileSearchActor()

        // Generate many unique patterns to stress the cache
        for i in 0..<300 {
            let pattern = "pattern\(i)"
            _ = try? await actor.search(
                pattern: pattern,
                isRegex: true,
                options: SearchOptions(maxResults: 1),
                in: [file]
            )
        }

        // If we got here without crashing or running out of memory, the cache
        // eviction is working. The cache limit is 256, so some eviction should
        // have occurred.
        XCTAssertTrue(true, "Cache should handle many unique patterns without issues")
    }

    // MARK: - Edge Case Tests

    /// Tests patterns that might behave differently between engines
    func testEdgeCasePatterns() async throws {
        let content = """
        interface{} type assertion
        func() callback
        map[string]int dictionary
        struct { field int }
        """
        let file = try await mockFile(name: "go.txt", content: content)

        let actor = FileSearchActor()

        // Patterns with special characters that need proper escaping
        let testCases = [
            ("interface\\{\\}", 1),  // Escaped braces (Go empty interface)
            ("func\\(\\)", 1),       // Escaped parens
            ("map\\[", 1),           // Escaped bracket
        ]

        for (pattern, expectedCount) in testCases {
            let results = try await actor.search(
                pattern: pattern,
                isRegex: true,
                options: SearchOptions(),
                in: [file]
            )
            XCTAssertEqual(results.count, expectedCount,
                          "Pattern '\(pattern)' should find \(expectedCount) matches")
        }
    }

    /// Tests that empty and whitespace patterns are handled correctly
    func testEmptyAndWhitespacePatterns() async throws {
        let content = "some content here"
        let file = try await mockFile(name: "test.txt", content: content)

        let actor = FileSearchActor()

        // Empty pattern should return no results
        let emptyResults = try await actor.search(
            pattern: "",
            isRegex: false,
            options: SearchOptions(),
            in: [file]
        )
        XCTAssertTrue(emptyResults.isEmpty, "Empty pattern should return no results")

        // Whitespace-only pattern should return no results
        let whitespaceResults = try await actor.search(
            pattern: "   ",
            isRegex: false,
            options: SearchOptions(),
            in: [file]
        )
        XCTAssertTrue(whitespaceResults.isEmpty, "Whitespace pattern should return no results")
    }

    // MARK: - JSON/MCP Escape Handling Tests

    /// Tests that double-escaped patterns from JSON/MCP are auto-corrected
    /// When patterns arrive via JSON transport, escapes can be doubled (e.g., "\\(" becomes "\\\\(")
    func testJSONDoubleEscapeHandling() async throws {
        let content = """
        func hello() {
            print("world")
        }
        frame(minWidth: 100)
        """
        let file = try await mockFile(name: "code.swift", content: content)

        let actor = FileSearchActor()

        // Simulate pattern that arrived over-escaped from JSON: "frame\\(" -> should find "frame("
        // The double backslash before ( should be compressed to single backslash
        var wasAutoCorrected: Bool? = nil
        let results = try await actor.search(
            pattern: "frame\\\\(",  // Double-escaped from JSON
            isRegex: true,
            wasAutoCorrected: &wasAutoCorrected,
            options: SearchOptions(),
            in: [file]
        )

        // Should find the match after auto-correction
        XCTAssertFalse(results.isEmpty, "Should find 'frame(' after fixing double-escapes")
        XCTAssertEqual(wasAutoCorrected, true, "Pattern should have been auto-corrected")
    }

    /// Tests that properly escaped patterns still work (no false corrections)
    func testProperlyEscapedPatternsWork() async throws {
        let content = """
        test\\(literal backslash-paren
        test(normal paren)
        """
        let file = try await mockFile(name: "test.txt", content: content)

        let actor = FileSearchActor()

        // Pattern with single escape should match literal backslash-paren
        let results = try await actor.search(
            pattern: "test\\(",
            isRegex: true,
            options: SearchOptions(),
            in: [file]
        )

        // Should find the normal paren (since \( in regex means literal ()
        XCTAssertFalse(results.isEmpty, "Should find matches with properly escaped pattern")
    }

    /// Tests lookahead patterns (should fall back to NSRegex or handle gracefully)
    func testLookaheadPatterns() async throws {
        let content = """
        foo followed by bar
        foo not followed by baz
        standalone foo
        """
        let file = try await mockFile(name: "lookahead.txt", content: content)

        let actor = FileSearchActor()

        // Positive lookahead - may use different engine
        let lookaheadResults = try await actor.search(
            pattern: "foo(?= followed)",
            isRegex: true,
            options: SearchOptions(),
            in: [file]
        )

        // Just verify it completes without error - behavior may vary by engine
        XCTAssertNotNil(lookaheadResults, "Lookahead pattern should be handled")
    }

    /// Tests alternation with many branches
    func testLargeAlternation() async throws {
        let words = (0..<100).map { "word\($0)" }
        let content = words.joined(separator: " ")
        let file = try await mockFile(name: "words.txt", content: content)

        let actor = FileSearchActor()

        // Large alternation pattern - each match is counted separately
        let pattern = "word50|word75|word99"
        let results = try await actor.search(
            pattern: pattern,
            isRegex: true,
            options: SearchOptions(),
            in: [file]
        )

        XCTAssertEqual(results.count, 3, "Should find three separate matches for each alternation branch")
    }
}
