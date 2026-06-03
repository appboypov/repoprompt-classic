import XCTest
@testable import RepoPrompt
import Foundation

class SearchMatchTests: XCTestCase {

    // MARK: - Mock FileViewModel for Testing

    class MockFileViewModel: FileViewModel {
        private let mockContent: String?

        init(
            name: String,
            relativePath: String,
            fullPath: String,
            content: String? = nil
        ) async throws {
            self.mockContent = content

            // Create a consistent root path and full path
            let rootPath = "/test/root"
            let consistentFullPath = rootPath + "/" + relativePath

            // Create a minimal File struct for the parent initializer
            let file = File(
                name: name,
                path: consistentFullPath,
                modificationDate: Date()
            )

            // Create a mock FileSystemService - use a temp directory for testing
            let tempDir = FileManager.default.temporaryDirectory
            let mockFileSystemService = try await FileSystemService(
                path: tempDir.path,
                respectGitignore: false,
                skipSymlinks: true
            )

            super.init(
                file: file,
                rootPath: rootPath,
                hierarchyLevel: 0,
                rootIdentifier: UUID(),
                rootFolderPath: rootPath,
                fileSystemService: mockFileSystemService
            )
        }

        override var latestContent: String? {
            get async {
                return mockContent
            }
        }
    }

    // MARK: - Test Data

    private func createMockFiles() async throws -> [MockFileViewModel] {
        return [
            try await MockFileViewModel(
                name: "SearchService.swift",
                relativePath: "Services/Search/SearchService.swift",
                fullPath: "/project/Services/Search/SearchService.swift",
                content: """
                import Foundation

                class SearchService {
                    func performSearch(query: String) -> [SearchResult] {
                        // Implementation here
                        return []
                    }

                    private func filterResults() {
                        // Filter logic
                    }
                }
                """
            ),
            try await MockFileViewModel(
                name: "UserService.js",
                relativePath: "services/user/UserService.js",
                fullPath: "/project/services/user/UserService.js",
                content: """
                class UserService {
                    constructor() {
                        this.users = [];
                    }

                    searchUsers(query) {
                        return this.users.filter(user =>
                            user.name.includes(query)
                        );
                    }
                }
                """
            ),
            try await MockFileViewModel(
                name: "config.json",
                relativePath: "config/config.json",
                fullPath: "/project/config/config.json",
                content: """
                {
                    "search": {
                        "enabled": true,
                        "maxResults": 100
                    },
                    "api": {
                        "endpoint": "https://api.example.com/search"
                    }
                }
                """
            ),
            try await MockFileViewModel(
                name: "README.md",
                relativePath: "README.md",
                fullPath: "/project/README.md",
                content: """
                # Project Search

                This project implements a powerful search functionality.

                ## Features
                - Fast text search
                - Regex support
                - Case insensitive search options

                ## Usage
                Use the search function to find content across files.
                """
            ),
            try await MockFileViewModel(
                name: "EmptyFile.txt",
                relativePath: "tests/EmptyFile.txt",
                fullPath: "/project/tests/EmptyFile.txt",
                content: ""
            ),
            try await MockFileViewModel(
                name: "NoContent.swift",
                relativePath: "NoContent.swift",
                fullPath: "/project/NoContent.swift",
                content: nil
            )
        ]
    }

    // MARK: - Literal Search Tests

    func testBasicLiteralSearch() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let results = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find matches for 'search'")

        // Verify we get matches from multiple files
        let filePaths = Set(results.map { $0.filePath })
        XCTAssertTrue(filePaths.count > 1, "Should find matches in multiple files")

        // Check specific matches
        let searchServiceMatches = results.filter { $0.filePath.contains("SearchService.swift") }
        XCTAssertFalse(searchServiceMatches.isEmpty, "Should find matches in SearchService.swift")

        // Verify line numbers are 0-based
        for result in results {
            XCTAssertGreaterThanOrEqual(result.lineNumber, 0, "Line numbers should be 0-based")
        }
    }

    func testCaseSensitiveSearch() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let caseSensitiveResults = try await actor.search(
            pattern: "Search",
            isRegex: false,
            options: SearchOptions(caseInsensitive: false),
            in: files
        )

        let caseInsensitiveResults = try await actor.search(
            pattern: "Search",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertLessThanOrEqual(caseSensitiveResults.count, caseInsensitiveResults.count,
                                "Case sensitive search should find fewer or equal matches")
    }

    func testFuzzySpaceSearch() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test fuzzy space matching - "search function" should match "search functionality"
        let results = try await actor.search(
            pattern: "search function",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find fuzzy matches for 'search function'")

        // Should match README.md which has "search functionality"
        let readmeMatches = results.filter { $0.filePath.contains("README.md") }
        XCTAssertFalse(readmeMatches.isEmpty, "Should find fuzzy match in README.md")
    }

    func testNoMatches() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let results = try await actor.search(
            pattern: "nonexistent_pattern_xyz",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertTrue(results.isEmpty, "Should find no matches for nonexistent pattern")
    }

    // MARK: - Regex Search Tests

    func testBasicRegexSearch() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Search for class declarations
        let results = try await actor.search(
            pattern: "class\\s+\\w+",
            isRegex: true,
            options: SearchOptions(caseInsensitive: false),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find class declarations")

        // Should find classes in both Swift and JavaScript files
        let swiftMatches = results.filter { $0.filePath.contains(".swift") }
        let jsMatches = results.filter { $0.filePath.contains(".js") }

        XCTAssertFalse(swiftMatches.isEmpty, "Should find Swift class")
        XCTAssertFalse(jsMatches.isEmpty, "Should find JavaScript class")
    }

    func testRegexWithGroups() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Search for function definitions with capture groups
        let results = try await actor.search(
            pattern: "(func|function)\\s+(\\w+)",
            isRegex: true,
            options: SearchOptions(caseInsensitive: false),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find function definitions")

        // Verify we get matches from both Swift and JS files
        let functionFiles = Set(results.map { $0.filePath })
        let hasSwift = functionFiles.contains { $0.contains(".swift") }
        let hasJS = functionFiles.contains { $0.contains(".js") }

        XCTAssertTrue(hasSwift || hasJS, "Should find functions in Swift or JavaScript files")
    }

	func testRegexPipeOperatorAlternation() async throws {
		let actor = FileSearchActor()
		let files = try await createMockFiles()

		// Test pipe operator for alternation (performSearch|searchUsers)
		let results = try await actor.search(
			pattern: "performSearch|searchUsers",
			isRegex: true,
			options: SearchOptions(caseInsensitive: false),
			in: files
		)

		XCTAssertFalse(results.isEmpty, "Should find matches for regex alternation")

		// Should find both performSearch in Swift file and searchUsers in JS file
		let swiftMatches = results.filter { $0.filePath.contains(".swift") && $0.lineText.contains("performSearch") }
		let jsMatches = results.filter { $0.filePath.contains(".js") && $0.lineText.contains("searchUsers") }

		XCTAssertFalse(swiftMatches.isEmpty, "Should find performSearch in Swift file")
		XCTAssertFalse(jsMatches.isEmpty, "Should find searchUsers in JavaScript file")

		// Verify the matches are on the correct lines
		for match in swiftMatches {
			XCTAssertTrue(match.lineText.contains("performSearch"), "Swift match should contain performSearch")
		}

		for match in jsMatches {
			XCTAssertTrue(match.lineText.contains("searchUsers"), "JS match should contain searchUsers")
		}
	}

	func testRegexMultiplePipeAlternations() async throws {
		let actor = FileSearchActor()
		let files = try await createMockFiles()

		// Test multiple alternations with pipe operator
		let results = try await actor.search(
			pattern: "class|func|function|constructor",
			isRegex: true,
			options: SearchOptions(caseInsensitive: false),
			in: files
		)

		XCTAssertFalse(results.isEmpty, "Should find matches for multiple alternations")

		// Verify we found different types of declarations
		let matchedLines = results.map { $0.lineText }
		let hasClass = matchedLines.contains { $0.contains("class") }
		let hasFunc = matchedLines.contains { $0.contains("func") }
		let hasFunction = matchedLines.contains { $0.contains("function") }
		let hasConstructor = matchedLines.contains { $0.contains("constructor") }

		XCTAssertTrue(hasClass, "Should find class declarations")
		XCTAssertTrue(hasFunc || hasFunction, "Should find function declarations")
		XCTAssertTrue(hasConstructor, "Should find constructor declarations")
	}

	func testContainsRegexSyntaxRecognizesPCREExtensionConstructs() {
		let regexPatterns = [
			#"(?<!xx)GetComponent"#,
			#"(?<!\/\/.*)GetComponent"#,
			#"(?i)GAMEOBJECT"#,
			#"(?>GetComponent)"#,
		]

		for pattern in regexPatterns {
			XCTAssertTrue(FileSearchActor.containsRegexSyntax(pattern), "Expected auto-detection for \(pattern)")
		}
		XCTAssertTrue(RegexToolkit.usesPCREOnlyFeatures(#"(?>GetComponent)"#))
		XCTAssertFalse(FileSearchActor.containsRegexSyntax("component?"), "Bare ? should remain path/wildcard syntax, not regex syntax")
	}

	func testAutoDetectedFixedLookbehindUsesRegexSemantics() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "components.swift",
			relativePath: "components.swift",
			fullPath: "/project/components.swift",
			content: "xxGetComponent\nabGetComponent\ncall GetComponent()"
		)
		let pattern = #"(?<!xx)GetComponent"#
		let autoIsRegex = FileSearchActor.containsRegexSyntax(pattern)

		XCTAssertTrue(autoIsRegex)
		let results = try await actor.searchUnified(
			pattern: pattern,
			isRegex: autoIsRegex,
			options: SearchOptions(mode: .auto, caseInsensitive: false, maxResults: 20),
			in: [file]
		)

		XCTAssertEqual(results.matches?.map(\.lineNumber), [1, 2])
	}

	func testAutoDetectedInlineCaseFlagUsesPCRE2SemanticsAndCountOnly() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "case.swift",
			relativePath: "case.swift",
			fullPath: "/project/case.swift",
			content: "GAMEOBJECT\nGameObject\ngameobject\nOtherThing"
		)
		let pattern = #"(?i)GAMEOBJECT"#
		let autoIsRegex = FileSearchActor.containsRegexSyntax(pattern)

		XCTAssertTrue(autoIsRegex)
		let materialized = try await actor.searchUnified(
			pattern: pattern,
			isRegex: autoIsRegex,
			options: SearchOptions(mode: .auto, caseInsensitive: false, maxResults: 20),
			in: [file]
		)
		let countOnly = try await actor.searchUnified(
			pattern: pattern,
			isRegex: autoIsRegex,
			options: SearchOptions(mode: .auto, caseInsensitive: false, countOnly: true),
			in: [file]
		)

		XCTAssertEqual(materialized.matches?.map(\.lineNumber), [0, 1, 2])
		XCTAssertNil(countOnly.matches)
		XCTAssertEqual(countOnly.totalCount, 3)
		XCTAssertEqual(countOnly.contentFileCount, 1)
	}

	func testAutoDetectedAtomicGroupUsesRegexSemantics() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "atomic.swift",
			relativePath: "atomic.swift",
			fullPath: "/project/atomic.swift",
			content: "GetComponent\nxxGetComponent\nNoMatch"
		)
		let pattern = #"(?>GetComponent)"#
		let autoIsRegex = FileSearchActor.containsRegexSyntax(pattern)

		XCTAssertTrue(autoIsRegex)
		let results = try await actor.searchUnified(
			pattern: pattern,
			isRegex: autoIsRegex,
			options: SearchOptions(mode: .auto, caseInsensitive: false, maxResults: 20),
			in: [file]
		)

		XCTAssertEqual(results.matches?.map(\.lineNumber), [0, 1])
	}

	func testAutoDetectedVariableLengthLookbehindSurfacesRegexError() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "invalid-lookbehind.swift",
			relativePath: "invalid-lookbehind.swift",
			fullPath: "/project/invalid-lookbehind.swift",
			content: "GetComponent\n// anything GetComponent"
		)
		let pattern = #"(?<!\/\/.*)GetComponent"#
		let autoIsRegex = FileSearchActor.containsRegexSyntax(pattern)

		XCTAssertTrue(autoIsRegex)
		do {
			_ = try await actor.searchUnified(
				pattern: pattern,
				isRegex: autoIsRegex,
				options: SearchOptions(mode: .auto, caseInsensitive: false, maxResults: 20),
				in: [file]
			)
			XCTFail("Expected variable-length lookbehind to surface a regex compile error")
		} catch {
			XCTAssertTrue(error is RegexPatternFailure, "Expected regex-pattern failure, got \(type(of: error))")
			let message = error.localizedDescription.lowercased()
			XCTAssertTrue(message.contains("variable-length lookbehind"), "Expected actionable lookbehind error, got: \(error.localizedDescription)")
			XCTAssertTrue(message.contains("fixed or bounded length"), "Expected fixed-length guidance, got: \(error.localizedDescription)")
			XCTAssertFalse(message.contains("pcre2"), "Engine name should not be user-facing: \(error.localizedDescription)")
			XCTAssertFalse(message.contains("byte offset 0"), "Offset should not be the primary error detail: \(error.localizedDescription)")
			XCTAssertFalse(message.contains("(125)"), "PCRE2 code should not be surfaced as the primary error detail: \(error.localizedDescription)")
		}
	}

	func testNoAutoDetectRegexPatterns() async throws {
		let actor = FileSearchActor()
		let files = try await createMockFiles()

		// Test that pipe operator does NOT auto-enable regex mode when isRegex is false
		let pipeResults = try await actor.searchUnified(
			pattern: "performSearch|searchUsers",
			isRegex: false,  // Should be treated as literal
			options: SearchOptions(caseInsensitive: false),
			in: files
		)

		// Should not find any matches since we're looking for the literal string "performSearch|searchUsers"
		XCTAssertTrue(pipeResults.matches?.isEmpty ?? true, "Should treat pipe as literal when regex=false")

		// Test with regex enabled
		let regexResults = try await actor.searchUnified(
			pattern: "performSearch|searchUsers",
			isRegex: true,  // Explicit regex
			options: SearchOptions(caseInsensitive: false),
			in: files
		)

		XCTAssertFalse(regexResults.matches?.isEmpty ?? true, "Should find matches with regex=true")
		let matches = regexResults.matches ?? []
		let hasPerformSearch = matches.contains { $0.lineText.contains("performSearch") }
		let hasSearchUsers = matches.contains { $0.lineText.contains("searchUsers") }

		XCTAssertTrue(hasPerformSearch, "Should find performSearch with regex enabled")
		XCTAssertTrue(hasSearchUsers, "Should find searchUsers with regex enabled")

		// Test that normal patterns without regex syntax are not treated as regex
		let literalResults = try await actor.searchUnified(
			pattern: "search",  // Simple literal search
			isRegex: false,
			options: SearchOptions(caseInsensitive: true),
			in: files
		)

		// Should find multiple matches for "search" as a literal
		XCTAssertFalse(literalResults.matches?.isEmpty ?? true, "Should find literal matches")

		// Test edge case: lone pipe should not trigger regex mode
		let lonePipeResults = try await actor.searchUnified(
			pattern: "|",
			isRegex: false,
			options: SearchOptions(caseInsensitive: false),
			in: files
		)

		// Should treat as literal search for "|" character
		// (Won't find any in our test data, but shouldn't crash)
		_ = lonePipeResults  // Just verify it doesn't crash
	}

	func testPipeOperatorRequiresExplicitRegex() async throws {
		let actor = FileSearchActor()
		let files = try await createMockFiles()

		// Test 1: Pipe pattern without isRegex flag is literal
		let literalResults = try await actor.searchUnified(
			pattern: "SearchService|UserService",
			isRegex: false,  // Literal search
			options: SearchOptions(mode: .content),
			in: files
		)

		// Should NOT find matches since we're looking for literal "SearchService|UserService"
		XCTAssertTrue(literalResults.matches?.isEmpty ?? true,
						"Pipe should be literal when regex=false")

		// Test 2: Same pattern with regex enabled
		let regexResults = try await actor.searchUnified(
			pattern: "SearchService|UserService",
			isRegex: true,  // Regex enabled
			options: SearchOptions(mode: .content),
			in: files
		)

		XCTAssertFalse(regexResults.matches?.isEmpty ?? true, "Should find matches with regex=true")
		let matches = regexResults.matches ?? []
		let foundSearchService = matches.contains { $0.lineText.contains("SearchService") }
		let foundUserService = matches.contains { $0.lineText.contains("UserService") }

		XCTAssertTrue(foundSearchService, "Should find SearchService with regex")
		XCTAssertTrue(foundUserService, "Should find UserService with regex")

		// Test 3: Complex pattern with multiple pipes requires regex
		let complexLiteralResults = try await actor.searchUnified(
			pattern: "import|class|return",
			isRegex: false,  // Literal
			options: SearchOptions(mode: .content),
			in: files
		)

		XCTAssertTrue(complexLiteralResults.matches?.isEmpty ?? true,
						"Multiple pipes should be literal when regex=false")

		// Test 3: Verify normal searches still work (no false positives)
		let normalResults = try await actor.searchUnified(
			pattern: "Service",  // No regex syntax
			isRegex: false,
			options: SearchOptions(mode: .content),
			in: files
		)

		XCTAssertFalse(normalResults.matches?.isEmpty ?? true,
						"Normal searches should still work as literal")

		// Test 4: Edge case - pattern that looks like regex but user wants literal
		// Add a file with actual pipe character in content for this test
		let pipeFile = try await MockFileViewModel(
			name: "commands.txt",
			relativePath: "docs/commands.txt",
			fullPath: "/project/docs/commands.txt",
			content: "Use grep | sort to filter results"
		)

		let filesWithPipe = files + [pipeFile]

		// When searching for literal "|" it should NOT trigger regex
		let literalPipeResults = try await actor.searchUnified(
			pattern: " | ",  // Spaces around pipe - less likely to be regex
			isRegex: false,
			options: SearchOptions(mode: .content),
			in: filesWithPipe
		)

		// Should find the literal pipe in commands.txt
		XCTAssertFalse(literalPipeResults.matches?.isEmpty ?? true,
						"Should find literal pipe when surrounded by spaces")
		XCTAssertTrue(literalPipeResults.matches?.first?.lineText.contains(" | ") ?? false,
						"Should match literal pipe character")
	}

    // MARK: - Path Search Tests

    func testPathSearchLiteral() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test literal pattern search - should find files containing "Service"
		let results = try await actor.searchPaths(
            pattern: "Service",
            limit: 100,
            in: files,
            caseInsensitive: true,
            isRegex: false
        )

        XCTAssertFalse(results.isEmpty, "Should find files with 'Service' in path")

        // Should find files containing "Service" (SearchService.swift and UserService.js)
        let serviceFiles = results.filter { $0.lowercased().contains("service") }
        XCTAssertTrue(serviceFiles.count >= 2, "Should find multiple files with 'Service' in path")

        // Verify we get both expected files
        let hasSearchService = results.contains { $0.contains("SearchService.swift") }
        let hasUserService = results.contains { $0.contains("UserService.js") }
        XCTAssertTrue(hasSearchService, "Should find SearchService.swift")
        XCTAssertTrue(hasUserService, "Should find UserService.js")
    }

    func testPathSearchWildcard() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

		let results = try await actor.searchPaths(
            pattern: "*.swift",
            limit: 100,
            in: files,
            caseInsensitive: true,
            isRegex: false
        )

        XCTAssertFalse(results.isEmpty, "Should find Swift files")

        // All results should be Swift files
        for path in results {
            XCTAssertTrue(path.hasSuffix(".swift"), "All results should be Swift files: \(path)")
        }
    }

    func testPathSearchLiteralVsWildcard() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test literal pattern (should use contains logic)
		let literalResults = try await actor.searchPaths(
            pattern: "Search",
            limit: 100,
            in: files,
            caseInsensitive: true,
            isRegex: false
        )

        // Test wildcard pattern (should use regex logic)
		let wildcardResults = try await actor.searchPaths(
            pattern: "*Search*",
            limit: 100,
            in: files,
            caseInsensitive: true,
            isRegex: false
        )

        // Both should find the same files for this pattern
        XCTAssertFalse(literalResults.isEmpty, "Literal search should find files")
        XCTAssertFalse(wildcardResults.isEmpty, "Wildcard search should find files")

        // Both should find SearchService.swift
        let literalHasSearchService = literalResults.contains { $0.contains("SearchService.swift") }
        let wildcardHasSearchService = wildcardResults.contains { $0.contains("SearchService.swift") }

        XCTAssertTrue(literalHasSearchService, "Literal search should find SearchService.swift")
        XCTAssertTrue(wildcardHasSearchService, "Wildcard search should find SearchService.swift")
    }

    func testPathSearchRegex() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

		let results = try await actor.searchPaths(
            pattern: ".*\\.(js|swift)$",
            limit: 100,
            in: files,
            caseInsensitive: true,
            isRegex: true
        )

        XCTAssertFalse(results.isEmpty, "Should find JS and Swift files")

        // All results should be either JS or Swift files
        for path in results {
            XCTAssertTrue(path.hasSuffix(".js") || path.hasSuffix(".swift"),
                         "All results should be JS or Swift files: \(path)")
        }
    }

	func testPathRegexEndAnchorMatchesRelativePathCandidate() async throws {
		let actor = FileSearchActor()
		let files = try await [
			MockFileViewModel(name: "SearchMatchTests.swift", relativePath: "Tests/SearchMatchTests.swift", fullPath: "/project/Tests/SearchMatchTests.swift", content: nil),
			MockFileViewModel(name: "SearchMatchTests.swift.bak", relativePath: "Tests/SearchMatchTests.swift.bak", fullPath: "/project/Tests/SearchMatchTests.swift.bak", content: nil),
			MockFileViewModel(name: "SearchMatchTests.md", relativePath: "Tests/SearchMatchTests.md", fullPath: "/project/Tests/SearchMatchTests.md", content: nil),
			MockFileViewModel(name: "App.swift", relativePath: "Sources/App.swift", fullPath: "/project/Sources/App.swift", content: nil)
		]

		let unanchoredHits = try await actor.searchPaths(
			pattern: #"Test.*\.swift"#,
			limit: 10,
			in: files,
			caseInsensitive: true,
			isRegex: true
		)
		XCTAssertTrue(unanchoredHits.contains("/test/root/Tests/SearchMatchTests.swift"))
		XCTAssertTrue(unanchoredHits.contains("/test/root/Tests/SearchMatchTests.swift.bak"))

		let anchoredHits = try await actor.searchPaths(
			pattern: #"Test.*\.swift$"#,
			limit: 10,
			in: files,
			caseInsensitive: true,
			isRegex: true
		)
		XCTAssertEqual(anchoredHits, ["/test/root/Tests/SearchMatchTests.swift"])
	}

	func testPathRegexStartAndEndAnchorsMatchRelativePathCandidate() async throws {
		let actor = FileSearchActor()
		let files = try await [
			MockFileViewModel(name: "SearchMatchTests.swift", relativePath: "Tests/SearchMatchTests.swift", fullPath: "/project/Tests/SearchMatchTests.swift", content: nil),
			MockFileViewModel(name: "SearchMatchTests.swift.bak", relativePath: "Tests/SearchMatchTests.swift.bak", fullPath: "/project/Tests/SearchMatchTests.swift.bak", content: nil),
			MockFileViewModel(name: "App.swift", relativePath: "Sources/App.swift", fullPath: "/project/Sources/App.swift", content: nil)
		]

		let hits = try await actor.searchPaths(
			pattern: #"^Tests/.*\.swift$"#,
			limit: 10,
			in: files,
			caseInsensitive: true,
			isRegex: true
		)
		XCTAssertEqual(hits, ["/test/root/Tests/SearchMatchTests.swift"])
	}

    // MARK: - Unified Search Tests

    func testUnifiedSearchBoth() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let results = try await actor.searchUnified(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                mode: .both,
                caseInsensitive: true,
                maxResults: 100
            ),
            in: files
        )

        // SearchResults sets paths/matches to nil if empty, so we check for content
        let hasPaths = results.paths?.isEmpty == false
        let hasMatches = results.matches?.isEmpty == false

        XCTAssertTrue(hasPaths || hasMatches, "Should have either path results or content matches")

        if let paths = results.paths {
            XCTAssertFalse(paths.isEmpty, "Should find files with 'search' in path")
        }

        if let matches = results.matches {
            XCTAssertFalse(matches.isEmpty, "Should find content matches for 'search'")
        }
    }

    func testUnifiedSearchPathOnly() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let results = try await actor.searchUnified(
            pattern: "Service",
            isRegex: false,
            options: SearchOptions(
                mode: .path,
                caseInsensitive: true,
                maxResults: 100
            ),
            in: files
        )

        XCTAssertNil(results.matches, "Should not have content matches in path-only mode")

        // Path results may be nil if no matches found
        if let paths = results.paths {
            XCTAssertFalse(paths.isEmpty, "Should find service files")
        } else {
            print("No path results found for 'Service' pattern")
        }
    }

	func testUnifiedPathRegexEndAnchorMatchesRelativePathCandidate() async throws {
		let actor = FileSearchActor()
		let files = try await [
			MockFileViewModel(name: "SearchMatchTests.swift", relativePath: "Tests/SearchMatchTests.swift", fullPath: "/project/Tests/SearchMatchTests.swift", content: "content should not matter"),
			MockFileViewModel(name: "SearchMatchTests.swift.bak", relativePath: "Tests/SearchMatchTests.swift.bak", fullPath: "/project/Tests/SearchMatchTests.swift.bak", content: "Test content")
		]
		var options = SearchOptions()
		options.mode = .path
		options.caseInsensitive = true
		options.maxResults = 10

		let results = try await actor.searchUnified(
			pattern: #"Test.*\.swift$"#,
			isRegex: true,
			options: options,
			in: files
		)

		XCTAssertEqual(results.paths, ["/test/root/Tests/SearchMatchTests.swift"])
		XCTAssertNil(results.matches)
	}

    func testUnifiedSearchContentOnly() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let results = try await actor.searchUnified(
            pattern: "constructor",
            isRegex: false,
            options: SearchOptions(
                mode: .content,
                caseInsensitive: true,
                maxResults: 100
            ),
            in: files
        )

        XCTAssertNil(results.paths, "Should not have path results in content-only mode")
        XCTAssertNotNil(results.matches, "Should have content matches")

        if let matches = results.matches {
            XCTAssertFalse(matches.isEmpty, "Should find 'constructor' in content")

            // Should find it in the JavaScript file
            let jsMatches = matches.filter { $0.filePath.contains(".js") }
            XCTAssertFalse(jsMatches.isEmpty, "Should find constructor in JS file")
        }
    }

	func testUnifiedSearchAutoMode() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test auto mode with path-like pattern
        let pathResults = try await actor.searchUnified(
            pattern: "*.swift",
            isRegex: false,
            options: SearchOptions(
                mode: .auto,
                caseInsensitive: true,
                maxResults: 100
            ),
            in: files
        )

        // Auto mode should detect this as a path pattern due to the "*" wildcard
        let hasPathResults = pathResults.paths?.isEmpty == false
        XCTAssertTrue(hasPathResults || pathResults.matches != nil, "Auto mode should detect path pattern and return some results")

        // Test auto mode with content-like pattern
        let contentResults = try await actor.searchUnified(
            pattern: "Implementation here",
            isRegex: false,
            options: SearchOptions(
                mode: .auto,
                caseInsensitive: true,
                maxResults: 100
            ),
            in: files
        )

        // Auto mode should detect this as content pattern due to the space
        let hasContentResults = contentResults.matches?.isEmpty == false
        XCTAssertTrue(hasContentResults || contentResults.paths != nil, "Auto mode should detect content pattern and return some results")
    }

	func testInferredAutoModeTreatsEscapedLiteralMetacharactersAsContent() {
		XCTAssertEqual(FileSearchActor.inferredAutoMode(#"Destroy\("#), .content)
		XCTAssertEqual(FileSearchActor.inferredAutoMode(#"Destroy\\("#), .content)
	}

	func testInferredAutoModeKeepsSlashPathsAndWindowsPathsAsPath() {
		XCTAssertEqual(FileSearchActor.inferredAutoMode("foo/bar/baz"), .path)
		XCTAssertEqual(FileSearchActor.inferredAutoMode(#"C:\Users\foo"#), .path)
	}

	func testUnifiedSearchAutoModeRepairsEscapedLiteralParenForContent() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "events.cs",
			relativePath: "Assets/Content/Scripts/BombLogic/events.cs",
			fullPath: "/test/root/Assets/Content/Scripts/BombLogic/events.cs",
			content: "Destroy(player)\nDestroy(other)\n"
		)

		let singleEscaped = try await actor.searchUnified(
			pattern: #"Destroy\("#,
			isRegex: false,
			options: SearchOptions(mode: .auto),
			in: [file]
		)
		XCTAssertEqual(singleEscaped.matches?.count, 2)
		XCTAssertNil(singleEscaped.paths)

		let doubleEscaped = try await actor.searchUnified(
			pattern: #"Destroy\\("#,
			isRegex: false,
			options: SearchOptions(mode: .auto),
			in: [file]
		)
		XCTAssertEqual(doubleEscaped.matches?.count, 2)
		XCTAssertNil(doubleEscaped.paths)
	}

    // MARK: - Edge Cases

    func testSearchEmptyFiles() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let results = try await actor.search(
            pattern: "anything",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        // Should not find matches in empty files
        let emptyFileMatches = results.filter { $0.filePath.contains("EmptyFile.txt") }
        XCTAssertTrue(emptyFileMatches.isEmpty, "Should not find matches in empty files")
    }

    func testSearchFilesWithoutContent() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let results = try await actor.search(
            pattern: "anything",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        // Should not find matches in files without content
        let noContentMatches = results.filter { $0.filePath.contains("NoContent.swift") }
        XCTAssertTrue(noContentMatches.isEmpty, "Should not find matches in files without content")
    }

    func testSearchWithSpecialCharacters() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test searching for JSON syntax
        let results = try await actor.search(
            pattern: "\"search\":",
            isRegex: false,
            options: SearchOptions(caseInsensitive: false),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find JSON key 'search'")

        let jsonMatches = results.filter { $0.filePath.contains(".json") }
        XCTAssertFalse(jsonMatches.isEmpty, "Should find matches in JSON file")
    }

    func testLimitResults() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

		let limitedResults = try await actor.searchPaths(
            pattern: "*",
            limit: 2,
            in: files,
            caseInsensitive: true,
            isRegex: false
        )

        XCTAssertLessThanOrEqual(limitedResults.count, 2, "Should respect the limit parameter")
    }

    // MARK: - Result Validation

    func testResultsSorting() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let results = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        // Verify results are sorted by file path then line number
        for i in 1..<results.count {
            let prev = results[i-1]
            let curr = results[i]

            if prev.filePath == curr.filePath {
                XCTAssertLessThanOrEqual(prev.lineNumber, curr.lineNumber,
                                        "Results within same file should be sorted by line number")
            } else {
                XCTAssertLessThan(prev.filePath, curr.filePath,
                                 "Results should be sorted by file path")
            }
        }
    }

    func testMaxResultsReturnsOrderedPrefixAcrossFiles() async throws {
        let actor = FileSearchActor()
        let files = try await [
            MockFileViewModel(
                name: "zeta.txt",
                relativePath: "zeta.txt",
                fullPath: "/project/zeta.txt",
                content: "search"
            ),
            MockFileViewModel(
                name: "alpha.txt",
                relativePath: "alpha.txt",
                fullPath: "/project/alpha.txt",
                content: "search"
            ),
            MockFileViewModel(
                name: "middle.txt",
                relativePath: "middle.txt",
                fullPath: "/project/middle.txt",
                content: "search"
            )
        ]

        let results = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true, maxResults: 2),
            in: files
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map { ($0.filePath as NSString).lastPathComponent }, ["alpha.txt", "middle.txt"])
    }

	func testContentBatchingReturnsOrderedPrefixAcrossMultipleBatches() async throws {
		let actor = FileSearchActor()
		var files: [MockFileViewModel] = []
		for index in stride(from: 47, through: 0, by: -1) {
			let name = String(format: "BatchContent_%03d.swift", index)
			files.append(try await MockFileViewModel(
				name: name,
				relativePath: "Batch/\(name)",
				fullPath: "/project/Batch/\(name)",
				content: "needle line \(index)"
			))
		}

		let results = try await actor.search(
			pattern: "needle",
			isRegex: false,
			options: SearchOptions(caseInsensitive: false, maxResults: 23),
			in: files
		)

		let expected = (0..<23).map { String(format: "BatchContent_%03d.swift", $0) }
		XCTAssertEqual(results.count, 23)
		XCTAssertEqual(results.map { ($0.filePath as NSString).lastPathComponent }, expected)
	}

	func testContentBatchingCountOnlyAcrossMultipleBatches() async throws {
		let actor = FileSearchActor()
		var files: [MockFileViewModel] = []
		for index in 0..<41 {
			let name = String(format: "BatchCount_%03d.swift", index)
			let hitLines = index % 3 + 1
			let content = (0..<hitLines).map { "needle \($0) in \(name)" }.joined(separator: "\n")
			files.append(try await MockFileViewModel(
				name: name,
				relativePath: "BatchCount/\(name)",
				fullPath: "/project/BatchCount/\(name)",
				content: content
			))
		}

		let results = try await actor.searchUnified(
			pattern: "needle",
			isRegex: false,
			options: SearchOptions(mode: .content, caseInsensitive: false, maxResults: 5, countOnly: true),
			in: files
		)

		let expectedTotal = (0..<41).reduce(0) { $0 + ($1 % 3 + 1) }
		XCTAssertNil(results.matches)
		XCTAssertEqual(results.totalCount, expectedTotal)
		XCTAssertEqual(results.contentFileCount, 41)
	}

	func testLiteralCountOnlyDeduplicatesSameLineAndHandlesCRLF() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "literal-count.txt",
			relativePath: "literal-count.txt",
			fullPath: "/project/literal-count.txt",
			content: "needle needle\r\nno hit\r\nNeedle again\nneedle"
		)

		let materialized = try await actor.search(
			pattern: "needle",
			isRegex: false,
			options: SearchOptions(caseInsensitive: true, maxResults: 20),
			in: [file]
		)
		let countOnly = try await actor.searchUnified(
			pattern: "needle",
			isRegex: false,
			options: SearchOptions(mode: .content, caseInsensitive: true, maxResults: 1, countOnly: true),
			in: [file]
		)

		XCTAssertEqual(materialized.map(\.lineNumber), [0, 2, 3])
		XCTAssertNil(countOnly.matches)
		XCTAssertEqual(countOnly.totalCount, materialized.count)
		XCTAssertEqual(countOnly.contentFileCount, 1)
	}

	func testLiteralCountOnlyUsesSearchLineBoundarySemantics() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "unicode-separator-count.txt",
			relativePath: "unicode-separator-count.txt",
			fullPath: "/project/unicode-separator-count.txt",
			content: "needle\u{2028}needle\nneedle"
		)

		let materialized = try await actor.search(
			pattern: "needle",
			isRegex: false,
			options: SearchOptions(caseInsensitive: false, maxResults: 20),
			in: [file]
		)
		let countOnly = try await actor.searchUnified(
			pattern: "needle",
			isRegex: false,
			options: SearchOptions(mode: .content, caseInsensitive: false, countOnly: true),
			in: [file]
		)

		XCTAssertEqual(materialized.map(\.lineNumber), [0, 1])
		XCTAssertEqual(countOnly.totalCount, materialized.count)
	}

	func testAnchoredRegexCountOnlyMatchesMaterializedLineCount() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "anchored-count.txt",
			relativePath: "anchored-count.txt",
			fullPath: "/project/anchored-count.txt",
			content: "needle1\nnot needle2\nneedle3\n  needle4"
		)

		let materialized = try await actor.search(
			pattern: #"^needle\d+"#,
			isRegex: true,
			options: SearchOptions(caseInsensitive: false, maxResults: 20),
			in: [file]
		)
		let countOnly = try await actor.searchUnified(
			pattern: #"^needle\d+"#,
			isRegex: true,
			options: SearchOptions(mode: .content, caseInsensitive: false, countOnly: true),
			in: [file]
		)

		XCTAssertEqual(materialized.map(\.lineNumber), [0, 2])
		XCTAssertNil(countOnly.matches)
		XCTAssertEqual(countOnly.totalCount, materialized.count)
		XCTAssertEqual(countOnly.contentFileCount, 1)
	}

	func testMaxResultsCapsDenseSingleFileOrderedPrefix() async throws {
		let actor = FileSearchActor()
		let content = (0..<50).map { "needle line \($0)" }.joined(separator: "\n")
		let file = try await MockFileViewModel(
			name: "dense.txt",
			relativePath: "dense.txt",
			fullPath: "/project/dense.txt",
			content: content
		)

		let results = try await actor.search(
			pattern: "needle",
			isRegex: false,
			options: SearchOptions(caseInsensitive: false, maxResults: 7),
			in: [file]
		)

		XCTAssertEqual(results.map(\.lineNumber), Array(0..<7))
		XCTAssertEqual(results.map(\.lineText), (0..<7).map { "needle line \($0)" })
	}

	func testPathBatchingReturnsDeterministicInputOrderAcrossMultipleBatches() async throws {
		let actor = FileSearchActor()
		var files: [MockFileViewModel] = []
		for index in stride(from: 259, through: 0, by: -1) {
			let name = String(format: "BatchPath_%03d.swift", index)
			files.append(try await MockFileViewModel(
				name: name,
				relativePath: "PathBatch/\(name)",
				fullPath: "/project/PathBatch/\(name)",
				content: nil
			))
		}

		let results = try await actor.searchPaths(
			pattern: "BatchPath_",
			limit: 150,
			in: files,
			caseInsensitive: false,
			isRegex: false
		)

		let expected = stride(from: 259, through: 110, by: -1).map { String(format: "BatchPath_%03d.swift", $0) }
		XCTAssertEqual(results.count, 150)
		XCTAssertEqual(results.map { ($0 as NSString).lastPathComponent }, expected)
	}

	func testRevisionBackedLineIndexInvalidatesSameLengthContentChanges() async throws {
		let actor = FileSearchActor()
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("SearchRevision-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let fileURL = rootURL.appendingPathComponent("same.txt")
		let initial = "target\nfirst"
		let updated = "first\ntarget"
		XCTAssertEqual(initial.utf16.count, updated.utf16.count)
		try initial.write(to: fileURL, atomically: true, encoding: .utf8)
		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: false,
			skipSymlinks: true
		)
		let fileVM = FileViewModel(
			file: File(name: "same.txt", path: fileURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootURL.path,
			fileSystemService: service
		)

		let first = try await actor.search(
			pattern: "target",
			isRegex: false,
			options: SearchOptions(caseInsensitive: false, maxResults: 10),
			in: [fileVM]
		)
		XCTAssertEqual(first.map(\.lineNumber), [0])
		XCTAssertEqual(first.map(\.lineText), ["target"])

		await fileVM.updateContent(updated)
		let second = try await actor.search(
			pattern: "target",
			isRegex: false,
			options: SearchOptions(caseInsensitive: false, maxResults: 10),
			in: [fileVM]
		)
		XCTAssertEqual(second.map(\.lineNumber), [1])
		XCTAssertEqual(second.map(\.lineText), ["target"])

		let repeated = try await actor.search(
			pattern: "target",
			isRegex: false,
			options: SearchOptions(caseInsensitive: false, maxResults: 10),
			in: [fileVM]
		)
		XCTAssertEqual(repeated, second)
	}

    func testSearchMatchStructure() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        let results = try await actor.search(
            pattern: "class",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find matches for 'class'")

        for match in results {
            // Verify SearchMatch structure
            XCTAssertFalse(match.filePath.isEmpty, "File path should not be empty")
            XCTAssertGreaterThanOrEqual(match.lineNumber, 0, "Line number should be 0-based")
            XCTAssertFalse(match.lineText.isEmpty, "Line text should not be empty")

            // Verify the match contains the search pattern
            XCTAssertTrue(match.lineText.lowercased().contains("class"),
                         "Line text should contain the search pattern: \(match.lineText)")
        }
    }

    // MARK: - Enhanced Features Tests

    func testExtensionFiltering() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test filtering for only Swift files
        let swiftResults = try await actor.search(
            pattern: "class",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                includeExtensions: [".swift"]
            ),
            in: files
        )

        // All results should be from Swift files
        for match in swiftResults {
            XCTAssertTrue(match.filePath.hasSuffix(".swift"), "Should only find matches in Swift files")
        }

        // Test filtering for only JavaScript files
        let jsResults = try await actor.search(
            pattern: "class",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                includeExtensions: [".js"]
            ),
            in: files
        )

        // All results should be from JS files
        for match in jsResults {
            XCTAssertTrue(match.filePath.hasSuffix(".js"), "Should only find matches in JS files")
        }

        // Swift and JS combined should have more results than Swift alone
        let combinedResults = try await actor.search(
            pattern: "class",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                includeExtensions: [".swift", ".js"]
            ),
            in: files
        )

        XCTAssertGreaterThanOrEqual(combinedResults.count, swiftResults.count, "Combined results should have at least as many as Swift alone")
    }

    func testExcludePatterns() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test excluding config files
        let excludeConfigResults = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                excludePatterns: ["config/*", "*.json"]
            ),
            in: files
        )

        // Should not find matches in config.json
        let configMatches = excludeConfigResults.filter { $0.filePath.contains("config.json") }
        XCTAssertTrue(configMatches.isEmpty, "Should exclude config files")

        // Test excluding all markdown files
        let excludeMarkdownResults = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                excludePatterns: ["*.md"]
            ),
            in: files
        )

        // Should not find matches in README.md
        let markdownMatches = excludeMarkdownResults.filter { $0.filePath.contains(".md") }
        XCTAssertTrue(markdownMatches.isEmpty, "Should exclude markdown files")
    }

    func testContextLines() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test with context lines
        let contextResults = try await actor.search(
            pattern: "SearchService",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                contextLines: 2
            ),
            in: files
        )

        XCTAssertFalse(contextResults.isEmpty, "Should find matches for 'SearchService'")

        // Check that context lines are provided
        for match in contextResults {
            if match.lineNumber > 0 {
                XCTAssertNotNil(match.contextBefore, "Should have context before for non-first lines")
            }

            // Context arrays should not exceed the requested number of lines
            if let contextBefore = match.contextBefore {
                XCTAssertLessThanOrEqual(contextBefore.count, 2, "Context before should not exceed 2 lines")
            }

            if let contextAfter = match.contextAfter {
                XCTAssertLessThanOrEqual(contextAfter.count, 2, "Context after should not exceed 2 lines")
            }
        }
    }

    func testWholeWordSearch() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test whole word search - "search" should not match "searchUsers"
        let wholeWordResults = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                wholeWord: true
            ),
            in: files
        )

        let regularResults = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                wholeWord: false
            ),
            in: files
        )

        // Whole word search should find fewer or equal matches
        XCTAssertLessThanOrEqual(wholeWordResults.count, regularResults.count, "Whole word search should be more restrictive")

        // Verify whole word matches don't include substring matches
        for match in wholeWordResults {
            let line = match.lineText.lowercased()
            // Simple heuristic: if line contains "searchusers", it shouldn't be in whole word results
            if line.contains("searchusers") {
                XCTFail("Whole word search should not match substrings in 'searchUsers': \(match.lineText)")
            }
        }
    }

    func testLiteralSubstringMatch() async throws {
        let actor = FileSearchActor()
        let stepFile = try await MockFileViewModel(
            name: "Steps.txt",
            relativePath: "docs/Steps.txt",
            fullPath: "/project/docs/Steps.txt",
            content: "step3p5"
        )

        let results = try await actor.search(
            pattern: "step3",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                wholeWord: false
            ),
            in: [stepFile]
        )
        XCTAssertFalse(results.isEmpty, "Literal search should match substrings when wholeWord is false")
        XCTAssertTrue(results.contains { $0.lineText.contains("step3p5") })

        let wholeWordResults = try await actor.search(
            pattern: "step3",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                wholeWord: true
            ),
            in: [stepFile]
        )
        XCTAssertTrue(wholeWordResults.isEmpty, "Whole word search should not match substrings")
    }

    func testCountOnlyMode() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test count-only mode with unified search
        let countResults = try await actor.searchUnified(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                mode: .content,
                caseInsensitive: true,
                countOnly: true
            ),
            in: files
        )

        // Should have total count but no individual matches
        XCTAssertNil(countResults.matches, "Count-only mode should not return individual matches")
        XCTAssertNotNil(countResults.totalCount, "Count-only mode should return total count")

        if let totalCount = countResults.totalCount {
            XCTAssertGreaterThan(totalCount, 0, "Should find some matches for 'search'")
        }
    }

    func testRegexSearchDeduplicatesMultipleMatchesOnSameLine() async throws {
        let actor = FileSearchActor()
        let file = try await MockFileViewModel(
            name: "dedupe.txt",
            relativePath: "dedupe.txt",
            fullPath: "/project/dedupe.txt",
            content: "search search search\nsearch once"
        )

        let results = try await actor.search(
            pattern: "search",
            isRegex: true,
            options: SearchOptions(caseInsensitive: true),
            in: [file]
        )

        XCTAssertEqual(results.map { $0.lineNumber }, [0, 1])
        XCTAssertEqual(results.count, 2)
    }

    func testRegexCountOnlyMatchesMaterializedLineCount() async throws {
        let actor = FileSearchActor()
        let files = try await [
            MockFileViewModel(
                name: "dedupe.txt",
                relativePath: "dedupe.txt",
                fullPath: "/project/dedupe.txt",
                content: "search search search\nsearch once"
            ),
            MockFileViewModel(
                name: "extra.txt",
                relativePath: "extra.txt",
                fullPath: "/project/extra.txt",
                content: "search"
            )
        ]

        let materialized = try await actor.search(
            pattern: "search",
            isRegex: true,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        let countOnly = try await actor.searchUnified(
            pattern: "search",
            isRegex: true,
            options: SearchOptions(
                mode: .content,
                caseInsensitive: true,
                countOnly: true
            ),
            in: files
        )

        XCTAssertNil(countOnly.matches)
        XCTAssertEqual(countOnly.totalCount, materialized.count)
        XCTAssertEqual(countOnly.contentFileCount, 2)
    }

	func testMultilineRegexReportsStartingLineOnly() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "multiline-regex.txt",
			relativePath: "multiline-regex.txt",
			fullPath: "/project/multiline-regex.txt",
			content: "alpha\r\nbeta\nomega"
		)

		let materialized = try await actor.search(
			pattern: "alpha\\s+beta",
			isRegex: true,
			options: SearchOptions(caseInsensitive: true),
			in: [file]
		)
		let countOnly = try await actor.searchUnified(
			pattern: "alpha\\s+beta",
			isRegex: true,
			options: SearchOptions(mode: .content, caseInsensitive: true, countOnly: true),
			in: [file]
		)

		XCTAssertEqual(materialized.count, 1)
		XCTAssertEqual(materialized.first?.lineNumber, 0)
		XCTAssertEqual(countOnly.totalCount, 1)
	}

	func testRegexLineNumbersAfterMultibyteUTF8Prefix() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "unicode.txt",
			relativePath: "unicode.txt",
			fullPath: "/project/unicode.txt",
			content: "emoji 😀 prefix\nneedle here\n"
		)

		let results = try await actor.search(
			pattern: "needle\\s+here",
			isRegex: true,
			options: SearchOptions(caseInsensitive: true),
			in: [file]
		)

		XCTAssertEqual(results.map(\.lineNumber), [1])
		XCTAssertEqual(results.first?.lineText, "needle here")
	}

	func testAnchoredRegexLineScannerDoesNotMatchAcrossLines() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "anchored.txt",
			relativePath: "anchored.txt",
			fullPath: "/project/anchored.txt",
			content: "foo\nbar\nfoo bar"
		)

		let results = try await actor.search(
			pattern: #"^foo\s+bar$"#,
			isRegex: true,
			options: SearchOptions(caseInsensitive: false),
			in: [file]
		)

		XCTAssertEqual(results.map(\.lineNumber), [2])
		XCTAssertEqual(results.first?.lineText, "foo bar")
	}

	func testAnchoredDeclarationFastPathDoesNotBypassRegexWholeWordWrapping() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "decl.swift",
			relativePath: "decl.swift",
			fullPath: "/project/decl.swift",
			content: "    class Foo\nstruct Bar"
		)

		let results = try await actor.search(
			pattern: #"^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*"#,
			isRegex: true,
			options: SearchOptions(caseInsensitive: false, wholeWord: true),
			in: [file]
		)

		XCTAssertEqual(results.map(\.lineNumber), [1])
		XCTAssertEqual(results.first?.lineText, "struct Bar")
	}

	func testTodoStyleRegexPreservesCrossLineWhitespaceAndStartingLine() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "todo.swift",
			relativePath: "todo.swift",
			fullPath: "/project/todo.swift",
			content: "// TODO-123:\nSearchThing\n// TODO-x TODO-456: SearchLater\n"
		)

		let results = try await actor.search(
			pattern: #"\bTODO-\d{3}:\s+Search\w*"#,
			isRegex: true,
			options: SearchOptions(caseInsensitive: false, fuzzySpaceMatching: false),
			in: [file]
		)

		XCTAssertEqual(results.map(\.lineNumber), [0, 2])
		XCTAssertEqual(results.map(\.lineText), ["// TODO-123:", "// TODO-x TODO-456: SearchLater"])
	}

	func testTodoStyleRegexNonASCIIFallsBackToPCRE2() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "todo-unicode.swift",
			relativePath: "todo-unicode.swift",
			fullPath: "/project/todo-unicode.swift",
			content: "café marker\nTODO-123: SearchThing\n"
		)

		let results = try await actor.search(
			pattern: #"\bTODO-\d{3}:\s+Search\w*"#,
			isRegex: true,
			options: SearchOptions(caseInsensitive: false, fuzzySpaceMatching: false),
			in: [file]
		)

		XCTAssertEqual(results.map(\.lineNumber), [1])
		XCTAssertEqual(results.map(\.lineText), ["TODO-123: SearchThing"])
	}

	func testTodoStyleRegexCountOnlyUsesPrefixCandidateParity() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "todo.swift",
			relativePath: "todo.swift",
			fullPath: "/project/todo.swift",
			content: "TODO-123: SearchOne and TODO-456: SearchTwo\nNOTE-123: SearchNope\nTODO-789:\nSearchAcross\n"
		)

		let results = try await actor.searchUnified(
			pattern: #"\bTODO-\d{3}:\s+Search\w*"#,
			isRegex: true,
			options: SearchOptions(mode: .content, caseInsensitive: false, maxResults: 20, countOnly: true, fuzzySpaceMatching: false),
			in: [file]
		)

		XCTAssertEqual(results.totalCount, 2)
		XCTAssertEqual(results.contentFileCount, 1)
	}

	func testWholeWordRegexNonASCIIDocumentFallsBackToPCRE2() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "unicode-word.txt",
			relativePath: "unicode-word.txt",
			fullPath: "/project/unicode-word.txt",
			content: "café SearchResult\nSearchResultEnvelope"
		)

		let results = try await actor.search(
			pattern: "SearchResult",
			isRegex: true,
			options: SearchOptions(caseInsensitive: false, wholeWord: true),
			in: [file]
		)

		XCTAssertEqual(results.map(\.lineNumber), [0])
	}

	func testPathRegexSuffixFastPathCaseInsensitiveAndFallbackShape() async throws {
		let actor = FileSearchActor()
		let files = try await [
			MockFileViewModel(name: "App.SWIFT", relativePath: "Sources/App.SWIFT", fullPath: "/project/Sources/App.SWIFT", content: nil),
			MockFileViewModel(name: "index.JS", relativePath: "web/index.JS", fullPath: "/project/web/index.JS", content: nil),
			MockFileViewModel(name: "README.md", relativePath: "README.md", fullPath: "/project/README.md", content: nil)
		]

		let suffixHits = try await actor.searchPaths(
			pattern: #".*\.(js|swift)$"#,
			limit: 10,
			in: files,
			caseInsensitive: true,
			isRegex: true
		)
		XCTAssertEqual(Set(suffixHits), ["/test/root/Sources/App.SWIFT", "/test/root/web/index.JS"])

		let fallbackHits = try await actor.searchPaths(
			pattern: #"^Sources/.*\.SWIFT$"#,
			limit: 10,
			in: files,
			caseInsensitive: false,
			isRegex: true
		)
		XCTAssertEqual(fallbackHits, ["/test/root/Sources/App.SWIFT"])
	}

	func testRegexLineNumbersWithCRLFAndMultibytePrefix() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "crlf-unicode.txt",
			relativePath: "crlf-unicode.txt",
			fullPath: "/project/crlf-unicode.txt",
			content: "emoji 😀 prefix\r\nmiddle\r\nneedle here\r\n"
		)

		let results = try await actor.search(
			pattern: "needle\\s+here",
			isRegex: true,
			options: SearchOptions(caseInsensitive: true),
			in: [file]
		)

		XCTAssertEqual(results.map(\.lineNumber), [2])
		XCTAssertEqual(results.first?.lineText, "needle here")
	}

    func testContextLinesPreserveMixedLineEndingSemantics() async throws {
        let actor = FileSearchActor()
        let file = try await MockFileViewModel(
            name: "mixed.txt",
            relativePath: "mixed.txt",
            fullPath: "/project/mixed.txt",
            content: "zero\r\none\nmatch here\rthree"
        )

        let results = try await actor.search(
            pattern: "match here",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                contextLines: 1
            ),
            in: [file]
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.lineNumber, 2)
        XCTAssertEqual(results.first?.contextBefore, ["one"])
        XCTAssertEqual(results.first?.contextAfter, ["three"])
    }

    func testMaxResultsLimit() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test with a very low limit
        let limitedResults = try await actor.search(
            pattern: "a", // Very common letter to ensure we hit the limit
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                maxResults: 3
            ),
            in: files
        )

        XCTAssertLessThanOrEqual(limitedResults.count, 3, "Should respect maxResults limit")
    }

    func testFuzzySpaceMatching() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test with fuzzy space matching enabled (default)
        let fuzzyResults = try await actor.search(
            pattern: "search functionality",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                fuzzySpaceMatching: true
            ),
            in: files
        )

        // Test with fuzzy space matching disabled
        let exactResults = try await actor.search(
            pattern: "search functionality",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                fuzzySpaceMatching: false
            ),
            in: files
        )

        // Fuzzy matching should find more or equal matches than exact
        XCTAssertGreaterThanOrEqual(fuzzyResults.count, exactResults.count, "Fuzzy space matching should be more flexible")
    }

    // MARK: - Comprehensive Fuzzy Space Matching Tests

    func testFuzzySpaceMatchingComprehensive() async throws {
        // Test all permutations of fuzzy space matching
        let testCases: [(content: String, pattern: String, shouldMatch: Bool, description: String)] = [
            // Basic cases
            ("hello world", "hello world", true, "Exact match"),
            ("hello  world", "hello world", true, "Double space"),
            ("hello   world", "hello world", true, "Triple space"),
            ("hello\tworld", "hello world", true, "Tab character"),
            ("hello\nworld", "hello world", false, "Newline breaks the match"),
            ("hello\r\nworld", "hello world", false, "Windows newline breaks the match"),
            ("hello \t world", "hello world", true, "Mixed whitespace"),

            // Multiple spaces in pattern - pattern spaces must exist in content
            ("hello world", "hello  world", false, "Pattern has more spaces than content"),
            ("hello world", "hello   world", false, "Pattern has even more spaces than content"),
            ("hello  world", "hello world", true, "Content has more spaces than pattern"),

            // Multiple words
            ("the quick brown fox", "the quick brown fox", true, "Four words exact"),
            ("the  quick   brown    fox", "the quick brown fox", true, "Variable spaces"),
            ("the\tquick brown fox", "the quick brown fox", true, "Tab as whitespace"),

            // Edge cases
            (" hello world", " hello world", true, "Leading space"),
            ("hello world ", "hello world ", true, "Trailing space"),
            ("  hello  world  ", "  hello  world  ", true, "Multiple leading/trailing"),

            // Special characters in pattern
            ("test (hello world)", "test (hello world)", true, "Parentheses"),
            ("price: $50.00", "price: $50.00", true, "Dollar sign and dot"),
            ("email@test.com sent", "email@test.com sent", true, "Email address"),
            ("C:\\Program Files\\test", "C:\\Program Files\\test", true, "Backslashes"),

            // No spaces
            ("helloworld", "hello world", false, "Missing space shouldn't match"),
            ("hello", "hello world", false, "Missing word shouldn't match"),

            // Case sensitivity (when combined with case-insensitive: false)
            ("Hello World", "hello world", false, "Case mismatch with fuzzy spaces"),
            ("HELLO  WORLD", "hello world", false, "Case mismatch with multiple spaces")
        ]

        for testCase in testCases {
            let file = try await MockFileViewModel(
                name: "test.txt",
                relativePath: "test.txt",
                fullPath: "/test/root/test.txt",
                content: testCase.content
            )

            let actor = FileSearchActor()
            let results = try await actor.search(
                pattern: testCase.pattern,
                isRegex: false,
                options: SearchOptions(
                    caseInsensitive: false,
                    fuzzySpaceMatching: true
                ),
                in: [file]
            )

            if testCase.shouldMatch {
                XCTAssertEqual(results.count, 1, "Failed: \(testCase.description) - Expected match for '\(testCase.pattern)' in '\(testCase.content)'")
            } else {
                XCTAssertEqual(results.count, 0, "Failed: \(testCase.description) - Expected no match for '\(testCase.pattern)' in '\(testCase.content)'")
            }
        }
    }

    func testFuzzySpaceMatchingWithOtherOptions() async throws {
        let actor = FileSearchActor()

        // Test fuzzy space + case insensitive
        let file1 = try await MockFileViewModel(
            name: "test1.txt",
            relativePath: "test1.txt",
            fullPath: "/test/root/test1.txt",
            content: "Hello   World"
        )

        let results1 = try await actor.search(
            pattern: "hello world",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                fuzzySpaceMatching: true
            ),
            in: [file1]
        )
        XCTAssertEqual(results1.count, 1, "Fuzzy space + case insensitive should match")

        // Test fuzzy space + whole word
        let file2 = try await MockFileViewModel(
            name: "test2.txt",
            relativePath: "test2.txt",
            fullPath: "/test/root/test2.txt",
            content: "prefix hello   world suffix"
        )

        let results2 = try await actor.search(
            pattern: "hello world",
            isRegex: false,
            options: SearchOptions(
                wholeWord: true,
                fuzzySpaceMatching: true
            ),
            in: [file2]
        )
        XCTAssertEqual(results2.count, 1, "Fuzzy space + whole word should match")

        // Test that partial words don't match with whole word + fuzzy
        let file3 = try await MockFileViewModel(
            name: "test3.txt",
            relativePath: "test3.txt",
            fullPath: "/test/root/test3.txt",
            content: "helloworld"
        )

        let results3 = try await actor.search(
            pattern: "hello world",
            isRegex: false,
            options: SearchOptions(
                wholeWord: true,
                fuzzySpaceMatching: true
            ),
            in: [file3]
        )
        XCTAssertEqual(results3.count, 0, "Concatenated words shouldn't match with whole word option")
    }

    func testFuzzySpaceMatchingMultiline() async throws {
        let content = """
        Line one with  spaces
        Line two  with   more    spaces
        Line three\twith\ttabs
        Line four
        with newline in middle
        """

        let file = try await MockFileViewModel(
            name: "multiline.txt",
            relativePath: "multiline.txt",
            fullPath: "/test/root/multiline.txt",
            content: content
        )

        let actor = FileSearchActor()

        // Test each line
        let testPatterns = [
            ("Line one with spaces", 1),
            ("Line two with more spaces", 1),
            ("Line three with tabs", 1),
            ("Line four with newline", 0)  // Newline breaks the match across lines
        ]

        for (pattern, expectedCount) in testPatterns {
            let results = try await actor.search(
                pattern: pattern,
                isRegex: false,
                options: SearchOptions(fuzzySpaceMatching: true),
                in: [file]
            )
            XCTAssertEqual(results.count, expectedCount,
                          "Pattern '\(pattern)' should have \(expectedCount) matches")
        }
    }

    func testFuzzySpaceMatchingDisabled() async throws {
        let file = try await MockFileViewModel(
            name: "test.txt",
            relativePath: "test.txt",
            fullPath: "/test/root/test.txt",
            content: "hello  world"  // Double space
        )

        let actor = FileSearchActor()

        // With fuzzy matching disabled, only exact space matches
        let results = try await actor.search(
            pattern: "hello world",  // Single space
            isRegex: false,
            options: SearchOptions(fuzzySpaceMatching: false),
            in: [file]
        )

        XCTAssertEqual(results.count, 0, "With fuzzy matching disabled, spaces must match exactly")

        // Exact match should work
        let exactResults = try await actor.search(
            pattern: "hello  world",  // Double space
            isRegex: false,
            options: SearchOptions(fuzzySpaceMatching: false),
            in: [file]
        )

        XCTAssertEqual(exactResults.count, 1, "Exact space matching should work")
    }

    func testFuzzySpaceMatchingEdgeCases() async throws {
        let actor = FileSearchActor()

        // Empty pattern
        let file1 = try await MockFileViewModel(
            name: "test1.txt",
            relativePath: "test1.txt",
            fullPath: "/test/root/test1.txt",
            content: "hello world"
        )

        let emptyResults = try await actor.search(
            pattern: "",
            isRegex: false,
            options: SearchOptions(fuzzySpaceMatching: true),
            in: [file1]
        )
        XCTAssertEqual(emptyResults.count, 0, "Empty pattern should not match")

        // Pattern with only spaces - this is an edge case that won't match
        // because the pattern becomes \s+\s+\s+ which requires at least 3 whitespace chars
        let spaceResults = try await actor.search(
            pattern: "   ",
            isRegex: false,
            options: SearchOptions(fuzzySpaceMatching: true),
            in: [file1]
        )
        XCTAssertEqual(spaceResults.count, 0, "Space-only pattern won't match regular content")

        // Very long content with many spaces
        let longContent = "word" + String(repeating: " ", count: 100) + "another"
        let file2 = try await MockFileViewModel(
            name: "test2.txt",
            relativePath: "test2.txt",
            fullPath: "/test/root/test2.txt",
            content: longContent
        )

        let longResults = try await actor.search(
            pattern: "word another",
            isRegex: false,
            options: SearchOptions(fuzzySpaceMatching: true),
            in: [file2]
        )
        XCTAssertEqual(longResults.count, 1, "Should match even with 100 spaces between words")
    }

    // MARK: - Complex Combinatorial Tests

    func testAutoDetectionEdgeCases() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test boundary case: exactly 3 characters should trigger .both mode
        let threeCharResults = try await actor.searchUnified(
            pattern: "the", // 3 chars, should be in content
            isRegex: false,
            options: SearchOptions(mode: .auto, caseInsensitive: true),
            in: files
        )

        // Should search both paths and content for 3-char patterns
        let hasPaths = threeCharResults.paths?.isEmpty == false
        let hasMatches = threeCharResults.matches?.isEmpty == false
        // Note: 3-char patterns trigger .both mode, so we should get some results
        XCTAssertTrue(hasPaths || hasMatches, "3-char pattern should trigger both mode and find some results")

        // Test ambiguous pattern with mixed signals
        let mixedSignalResults = try await actor.searchUnified(
            pattern: "search function", // Has space (content) - should find something in our mock data
            isRegex: false,
            options: SearchOptions(mode: .auto, caseInsensitive: true),
            in: files
        )

        // Should detect as content due to space
        XCTAssertNotNil(mixedSignalResults.matches, "Pattern with space should be detected as content search")

        // Test pattern starting with * (should be path)
        let wildcardResults = try await actor.searchUnified(
            pattern: "*Service*",
            isRegex: false,
            options: SearchOptions(mode: .auto, caseInsensitive: true),
            in: files
        )

        // Should detect as path search
        XCTAssertNotNil(wildcardResults.paths, "Wildcard pattern should be detected as path search")

        // Test pattern with / (should be path)
        let slashResults = try await actor.searchUnified(
            pattern: "Services/Search",
            isRegex: false,
            options: SearchOptions(mode: .auto, caseInsensitive: true),
            in: files
        )

        // Should detect as path search
        XCTAssertNotNil(slashResults.paths, "Pattern with / should be detected as path search")
    }

    func testRegexCombinations() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test regex with whole word search
        let regexWholeWordResults = try await actor.search(
            pattern: "class",
            isRegex: true,
            options: SearchOptions(
                caseInsensitive: false,
                wholeWord: true
            ),
            in: files
        )

        XCTAssertFalse(regexWholeWordResults.isEmpty, "Regex with whole word should find matches")

        // Test regex with context lines
        let regexContextResults = try await actor.search(
            pattern: "function\\s+\\w+",
            isRegex: true,
            options: SearchOptions(
                caseInsensitive: false,
                contextLines: 2
            ),
            in: files
        )

        // Verify context is provided
        for match in regexContextResults {
            if match.lineNumber > 0 {
                XCTAssertNotNil(match.contextBefore, "Regex search should include context lines")
            }
        }

        // Test regex in path mode
        let regexPathResults = try await actor.searchUnified(
            pattern: ".*Service\\.(swift|js)$",
            isRegex: true,
            options: SearchOptions(mode: .path, caseInsensitive: false),
            in: files
        )

        XCTAssertNotNil(regexPathResults.paths, "Regex path search should return paths")
        if let paths = regexPathResults.paths {
            for path in paths {
                XCTAssertTrue(path.contains("Service") && (path.hasSuffix(".swift") || path.hasSuffix(".js")),
                             "Regex path should match pattern")
            }
        }
    }

    func testFileFilteringConflicts() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test conflicting include/exclude: include .swift but exclude all files
        let conflictResults = try await actor.search(
            pattern: "class",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                includeExtensions: [".swift"],
                excludePatterns: ["*"] // Exclude everything
            ),
            in: files
        )

        XCTAssertTrue(conflictResults.isEmpty, "Conflicting filters should result in no matches")

        // Test multiple include extensions
        let multiExtResults = try await actor.search(
            pattern: "class",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                includeExtensions: [".swift", ".js", ".ts"]
            ),
            in: files
        )

        // All results should be from specified extensions
        for match in multiExtResults {
            let hasValidExtension = match.filePath.hasSuffix(".swift") ||
                                   match.filePath.hasSuffix(".js") ||
                                   match.filePath.hasSuffix(".ts")
            XCTAssertTrue(hasValidExtension, "Results should only be from included extensions")
        }

        // Test exclude patterns with wildcards
        let excludeWildcardResults = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                excludePatterns: ["*.md", "config/*"]
            ),
            in: files
        )

        // Should not find matches in README.md or config files
        for match in excludeWildcardResults {
            XCTAssertFalse(match.filePath.hasSuffix(".md"), "Should exclude .md files")
            XCTAssertFalse(match.filePath.contains("config/"), "Should exclude config directory")
        }
    }

    func testContextLinesEdgeCases() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test large context line request
        let largeContextResults = try await actor.search(
            pattern: "SearchService",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                contextLines: 10 // Larger than file content
            ),
            in: files
        )

        // Context should not exceed file boundaries
        for match in largeContextResults {
            if let contextBefore = match.contextBefore {
                XCTAssertLessThanOrEqual(contextBefore.count, match.lineNumber,
                                       "Context before should not exceed available lines")
            }
            if let contextAfter = match.contextAfter {
                XCTAssertLessThanOrEqual(contextAfter.count, 10,
                                       "Context after should be reasonable")
            }
        }

        // Test context with matches at file start
        let startMatchResults = try await actor.search(
            pattern: "import", // Should be at start of files
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                contextLines: 3
            ),
            in: files
        )

        // First line matches should have no context before
        for match in startMatchResults {
            if match.lineNumber == 1 { // Remember: 1-based for user-facing API
                XCTAssertNil(match.contextBefore, "First line should have no context before")
            }
        }
    }

    func testRealWorldScenarios() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Scenario 1: Find all function definitions with context
        let functionDefResults = try await actor.search(
            pattern: "(func|function)\\s+\\w+",
            isRegex: true,
            options: SearchOptions(
                caseInsensitive: false,
                includeExtensions: [".swift", ".js"],
                contextLines: 2
            ),
            in: files
        )

        XCTAssertFalse(functionDefResults.isEmpty, "Should find function definitions")

        // Scenario 2: Search for config values excluding certain directories
        let configSearchResults = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                includeExtensions: [".json"],
                excludePatterns: ["node_modules/*", "dist/*"],
                contextLines: 1
            ),
            in: files
        )

        // Should only find matches in JSON files
        for match in configSearchResults {
            XCTAssertTrue(match.filePath.hasSuffix(".json"), "Should only search JSON files")
        }

        // Scenario 3: Find imports/dependencies in specific directory
        let importSearchResults = try await actor.searchUnified(
            pattern: "import",
            isRegex: false,
            options: SearchOptions(
                mode: .content,
                caseInsensitive: true,
                includeExtensions: [".swift", ".js"]
            ),
            in: files
        )

        XCTAssertNotNil(importSearchResults.matches, "Should find import statements")

        // Scenario 4: Count-only search for performance
        let countOnlyResults = try await actor.searchUnified(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                mode: .content,
                caseInsensitive: true,
                countOnly: true
            ),
            in: files
        )

        XCTAssertNil(countOnlyResults.matches, "Count-only should not return matches")
        XCTAssertNotNil(countOnlyResults.totalCount, "Count-only should return total count")
        XCTAssertGreaterThan(countOnlyResults.totalCount ?? 0, 0, "Should count some matches")
    }

    func testPerformanceAndLimits() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test max results with different modes
        let limitedPathResults = try await actor.searchUnified(
            pattern: "*",
            isRegex: false,
            options: SearchOptions(
                mode: .path,
                caseInsensitive: true,
                maxResults: 2
            ),
            in: files
        )

        if let paths = limitedPathResults.paths {
            XCTAssertLessThanOrEqual(paths.count, 2, "Should respect max results for path search")
        }

        let limitedContentResults = try await actor.search(
            pattern: "a", // Common letter
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                maxResults: 3
            ),
            in: files
        )

        XCTAssertLessThanOrEqual(limitedContentResults.count, 3, "Should respect max results for content search")

        // Test very restrictive filtering
        let restrictiveResults = try await actor.search(
            pattern: "nonexistent",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                wholeWord: true,
                includeExtensions: [".xyz"] // Non-existent extension
            ),
            in: files
        )

        XCTAssertTrue(restrictiveResults.isEmpty, "Very restrictive filters should return no results")
    }

    func testErrorConditionsAndEdgeCases() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test empty pattern
        let emptyPatternResults = try await actor.search(
            pattern: "",
            isRegex: false,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertTrue(emptyPatternResults.isEmpty, "Empty pattern should return no results")

        // Test complex regex with other features
        let complexRegexResults = try await actor.search(
            pattern: "\\b(class|interface|struct)\\s+\\w+\\s*\\{",
            isRegex: true,
            options: SearchOptions(
                caseInsensitive: false,
                wholeWord: false, // Should be ignored for regex
                includeExtensions: [".swift", ".js"],
                contextLines: 2
            ),
            in: files
        )

        // Should handle complex regex with other features
        for match in complexRegexResults {
            XCTAssertTrue(match.filePath.hasSuffix(".swift") || match.filePath.hasSuffix(".js"),
                         "Complex regex should respect file filtering")
        }

        // Test fuzzy space matching with regex (should be ignored)
        let regexFuzzyResults = try await actor.search(
            pattern: "class\\s+\\w+",
            isRegex: true,
            options: SearchOptions(
                caseInsensitive: false,
                fuzzySpaceMatching: true // Should be ignored for regex
            ),
            in: files
        )

        // Should work normally (fuzzy space matching ignored for regex)
        XCTAssertFalse(regexFuzzyResults.isEmpty, "Regex should work even with fuzzy space option")

        // Test exclude patterns that exclude everything
        let excludeAllResults = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                excludePatterns: ["*"] // Exclude everything
            ),
            in: files
        )

        XCTAssertTrue(excludeAllResults.isEmpty, "Excluding everything should return no results")
    }

    func testFeatureInteractions() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test all features combined
        let kitchenSinkResults = try await actor.search(
            pattern: "search",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                wholeWord: false,
                includeExtensions: [".swift", ".js"],
                excludePatterns: ["config/*"], // Exclude config directory instead
                contextLines: 1,
                maxResults: 10,
                fuzzySpaceMatching: true
            ),
            in: files
        )

        // Verify all constraints are applied
        for match in kitchenSinkResults {
            XCTAssertTrue(match.filePath.hasSuffix(".swift") || match.filePath.hasSuffix(".js"),
                         "Should respect include extensions")
            XCTAssertFalse(match.filePath.lowercased().contains("config/"),
                          "Should respect exclude patterns")
        }

        XCTAssertLessThanOrEqual(kitchenSinkResults.count, 10, "Should respect max results")

        // Test conflicting whole word and fuzzy space
        let conflictingOptionsResults = try await actor.search(
            pattern: "search function",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: true,
                wholeWord: true, // Both words should be whole
                fuzzySpaceMatching: true // Should still allow flexible space matching
            ),
            in: files
        )

        // Both features should work together logically
        for match in conflictingOptionsResults {
            let line = match.lineText.lowercased()
            // This is a complex interaction - the implementation should handle it sensibly
            XCTAssertTrue(line.contains("search") || line.contains("function"),
                         "Should find matches with the pattern components")
        }
    }

    // MARK: - Pipe (|) OR Pattern Tests

    func testBasicPipeORPattern() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test basic OR pattern with two alternatives
        let results = try await actor.search(
            pattern: "search|filter",
            isRegex: true,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find matches for 'search|filter' pattern")

        // Verify we get matches for both patterns
        let searchMatches = results.filter { $0.lineText.lowercased().contains("search") }
        let filterMatches = results.filter { $0.lineText.lowercased().contains("filter") }

        XCTAssertFalse(searchMatches.isEmpty, "Should find 'search' matches")
        XCTAssertFalse(filterMatches.isEmpty, "Should find 'filter' matches")
    }

    func testMultiplePipeORPattern() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test OR pattern with multiple alternatives
        let results = try await actor.search(
            pattern: "class|function|interface|struct",
            isRegex: true,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find matches for multiple OR pattern")

        // Verify matches contain at least one of the alternatives
        for match in results {
            let line = match.lineText.lowercased()
            let hasMatch = line.contains("class") ||
                          line.contains("function") ||
                          line.contains("interface") ||
                          line.contains("struct")
            XCTAssertTrue(hasMatch, "Each match should contain at least one alternative: \(match.lineText)")
        }
    }

    func testPipeORWithWordBoundaries() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test OR pattern with word boundaries
        let results = try await actor.search(
            pattern: "\\b(search|filter)\\b",
            isRegex: true,
            options: SearchOptions(caseInsensitive: false),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find whole word matches for 'search|filter'")

        // Verify word boundaries are respected
        for match in results {
            // Should not match partial words like 'searched' or 'filtering'
            let line = match.lineText
            if line.contains("search") {
                // Check it's not part of a larger word
                let pattern = try! NSRegularExpression(pattern: "\\bsearch\\b", options: [])
                let range = NSRange(location: 0, length: line.count)
                let hasWholeWord = pattern.firstMatch(in: line, options: [], range: range) != nil
                XCTAssertTrue(hasWholeWord, "Should match 'search' as whole word")
            }
        }
    }

    func testPipeORInPathSearch() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test OR pattern in path search
		let results = try await actor.searchPaths(
            pattern: "Search.*\\.swift|User.*\\.js",
            limit: 100,
            in: files,
            caseInsensitive: false,
            isRegex: true
        )

        XCTAssertFalse(results.isEmpty, "Should find paths matching OR pattern")

        // Should find both SearchService.swift and UserService.js
        let hasSearchService = results.contains { $0.contains("SearchService.swift") }
        let hasUserService = results.contains { $0.contains("UserService.js") }

        XCTAssertTrue(hasSearchService, "Should find SearchService.swift")
        XCTAssertTrue(hasUserService, "Should find UserService.js")
    }

    func testComplexPipeORPattern() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test complex OR pattern with groups and modifiers
        let results = try await actor.search(
            pattern: "(performSearch|searchUsers)\\s*\\(",
            isRegex: true,
            options: SearchOptions(caseInsensitive: false),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find function calls matching OR pattern")

        // Verify matches are function calls
        for match in results {
            let line = match.lineText
            let hasPerformSearch = line.contains("performSearch(")
            let hasSearchUsers = line.contains("searchUsers(")
            XCTAssertTrue(hasPerformSearch || hasSearchUsers,
                         "Should match function calls: \(line)")
        }
    }

    func testPipeORWithSpecialCharacters() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test OR pattern with special characters that need escaping
        let results = try await actor.search(
            pattern: "\\[\\]|\\{\\}|\\(\\)",
            isRegex: true,
            options: SearchOptions(caseInsensitive: false),
            in: files
        )

        // Should find brackets, braces, or parentheses
        for match in results {
            let line = match.lineText
            let hasMatch = line.contains("[]") || line.contains("{}") || line.contains("()")
            XCTAssertTrue(hasMatch, "Should match brackets, braces, or parentheses")
        }
    }

    func testPipeORWithContextLines() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test OR pattern with context lines
        let results = try await actor.search(
            pattern: "import|export",
            isRegex: true,
            options: SearchOptions(
                caseInsensitive: true,
                contextLines: 2
            ),
            in: files
        )

        // Verify context is provided for OR pattern matches
        for match in results {
            if match.lineNumber > 0 {
                XCTAssertNotNil(match.contextBefore, "Should have context before")
            }
            XCTAssertNotNil(match.contextAfter, "Should have context after")
        }
    }

    func testPipeORWithFileFiltering() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test OR pattern with file extension filtering
        let results = try await actor.search(
            pattern: "class|interface",
            isRegex: true,
            options: SearchOptions(
                caseInsensitive: true,
                includeExtensions: [".swift"]
            ),
            in: files
        )

        // All results should be from Swift files only
        for match in results {
            XCTAssertTrue(match.filePath.hasSuffix(".swift"),
                         "Should only find matches in Swift files: \(match.filePath)")
        }
    }

    func testPipeORPatternEdgeCases() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test empty alternatives (should be handled gracefully)
        let emptyAltResults = try await actor.search(
            pattern: "search||filter",  // Empty alternative in middle
            isRegex: true,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        // Should still find matches for non-empty alternatives
        XCTAssertFalse(emptyAltResults.isEmpty, "Should handle empty alternatives gracefully")

        // Test pipe at start/end
        let pipeAtStartResults = try await actor.search(
            pattern: "|search",  // Pipe at start
            isRegex: true,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertFalse(pipeAtStartResults.isEmpty, "Should handle pipe at start")

        // Test nested groups with OR
        let nestedResults = try await actor.search(
            pattern: "(perform|execute)(Search|Filter)",
            isRegex: true,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        // Should match combinations like performSearch, executeFilter, etc.
        for match in nestedResults {
            let line = match.lineText.lowercased()
            let hasValidCombo = (line.contains("perform") || line.contains("execute")) &&
                               (line.contains("search") || line.contains("filter"))
            if !hasValidCombo {
                // Check if it's a valid match despite not containing expected substrings
                print("Unexpected match: \(match.lineText)")
            }
        }
    }

    func testPipeORInUnifiedSearch() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test OR pattern in unified search with auto mode
        let autoResults = try await actor.searchUnified(
            pattern: "search|filter",
            isRegex: true,
            options: SearchOptions(
                mode: .auto,
                caseInsensitive: true
            ),
            in: files
        )

        // Should detect as content search and find matches
        XCTAssertNotNil(autoResults.matches, "Should have content matches for OR pattern")

        if let matches = autoResults.matches {
            XCTAssertFalse(matches.isEmpty, "Should find matches for OR pattern")
        }

        // Test OR pattern in path mode
        let pathResults = try await actor.searchUnified(
            pattern: "Service|Controller|Manager",
            isRegex: true,
            options: SearchOptions(
                mode: .path,
                caseInsensitive: true
            ),
            in: files
        )

        XCTAssertNotNil(pathResults.paths, "Should have path results for OR pattern")

        if let paths = pathResults.paths {
            // Should find Service files
            let serviceFiles = paths.filter { $0.lowercased().contains("service") }
            XCTAssertFalse(serviceFiles.isEmpty, "Should find Service files")
        }
    }

    func testPipeORPerformance() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test performance with many alternatives
        let manyAlternatives = (1...10).map { "pattern\($0)" }.joined(separator: "|")

        let startTime = Date()
        let results = try await actor.search(
            pattern: manyAlternatives,
            isRegex: true,
            options: SearchOptions(
                caseInsensitive: true,
                maxResults: 50
            ),
            in: files
        )
        let elapsed = Date().timeIntervalSince(startTime)

        // Should complete in reasonable time
        XCTAssertLessThan(elapsed, 5.0, "Complex OR pattern should complete quickly")

        // Verify max results is respected
        XCTAssertLessThanOrEqual(results.count, 50, "Should respect max results with OR pattern")
    }

    func testPipeORWithWholeWordOption() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test OR pattern with whole word option (should be ignored for regex)
        let results = try await actor.search(
            pattern: "search|filter",
            isRegex: true,
            options: SearchOptions(
                caseInsensitive: true,
                wholeWord: true  // Should be ignored for regex
            ),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find matches even with wholeWord option")

        // The wholeWord option should be ignored for regex patterns
        // So we might find partial matches
        let hasSearchInSearchUsers = results.contains {
            $0.lineText.lowercased().contains("searchusers")
        }
        // This is OK because wholeWord is ignored for regex
        print("Found searchUsers: \(hasSearchInSearchUsers)")
    }

    func testPipeORCaseInsensitive() async throws {
        let actor = FileSearchActor()
        let files = try await createMockFiles()

        // Test case insensitive OR pattern
        let results = try await actor.search(
            pattern: "SEARCH|filter",  // Mixed case
            isRegex: true,
            options: SearchOptions(caseInsensitive: true),
            in: files
        )

        XCTAssertFalse(results.isEmpty, "Should find matches with case insensitive OR")

        // Should find both uppercase and lowercase matches
        let hasLowercaseSearch = results.contains {
            $0.lineText.contains("search") && !$0.lineText.contains("SEARCH")
        }
        XCTAssertTrue(hasLowercaseSearch, "Should match lowercase 'search' with case insensitive option")
    }

	// MARK: - Regex Pattern Validation Tests

	func testRegexPatternValidation() async throws {
		let actor = FileSearchActor()
		let files = try await createMockFiles()

		// 1) Patterns with unmatched parentheses should NOT throw.
		// They are auto-escaped and treated as literal text in regex mode.
		let autoEscapedParenPatterns = [
			"gatherExpandedFolderPaths(",
			"func test(",
			"(hello)",
			"(hello",     // opening paren without closing
			"world)",     // closing paren without opening
			"func\\s+[a-zA-Z_][a-zA-Z0-9_]*(" // typical "func name(" pattern
		]
		for pattern in autoEscapedParenPatterns {
			do {
				_ = try await actor.search(
					pattern: pattern,
					isRegex: true,
					options: SearchOptions(),
					in: files
				)
				// Success: no throw expected
			} catch {
				XCTFail("Pattern '\(pattern)' should not throw; unmatched parentheses are auto-escaped.")
			}
		}

		// 2) Truly malformed patterns should still throw with PCRE2 diagnostics.
		// Some invalid quantifier syntax like `{` is normalized as literal text for search UX,
		// but malformed character classes and impossible quantifier bounds remain hard errors.
		let malformedPatterns: [(pattern: String, expectedError: String)] = [
			// Unmatched / malformed character classes.
			("[a-z", "missing terminating ]"),
			("test[", "missing terminating ]"),
			("[^abc", "missing terminating ]"),

			// Extremely large quantifiers are rejected by PCRE2.
			("a{999999999}", "number too big"),
		]

		// Patterns that normalization accepts by treating incomplete/invalid quantifier syntax as literal text:
		// - "test{"
		// - "test{3,"
		// - "test{,}"

		for (pattern, expectedError) in malformedPatterns {
			do {
				_ = try await actor.search(
					pattern: pattern,
					isRegex: true,
					options: SearchOptions(),
					in: files
				)
				XCTFail("Pattern '\(pattern)' should have thrown an error")
			} catch {
				let errorMessage = error.localizedDescription
				XCTAssertTrue(
					errorMessage.contains(expectedError),
					"Error for pattern '\(pattern)' should contain '\(expectedError)'. Got: '\(errorMessage)'"
				)
			}
		}
	}

	func testValidRegexPatterns() async throws {
		let actor = FileSearchActor()
		let files = try await createMockFiles()

		// Test valid regex patterns that should work
		let validPatterns = [
			// Escaped parentheses
			"gatherExpandedFolderPaths\\(\\)",
			"func\\s+test\\(\\)",
			"\\(hello\\)",

			// Valid brackets
			"[a-z]+",
			"test[0-9]",
			"[^abc]+",
			"class\\s+\\{[^}]*\\}",

			// Valid quantifiers
			"test{3}",
			"test{3,5}",
			"a{0,10}",

			// Valid alternatives
			"test|hello",
			"one|two|three",
			"(cat|dog|fish)",

			// Valid escape sequences
			"\\\\",
			"\\.",
			"\\s+",
			"\\w+",
			"\\d+",
			"\\n",
			"\\t",

			// Complex valid patterns
			"^[a-zA-Z_][a-zA-Z0-9_]*$",
			"\\b(class|interface|struct)\\s+\\w+",
			"(?:public|private|protected)\\s+",
			"\\d{4}-\\d{2}-\\d{2}",

			// Normalized lenient patterns - these are valid because invalid quantifier
			// syntax is treated as literal search text.
			"test{",       // `{` treated as literal
			"test{3,",     // incomplete quantifier treated as literal
			"test{,}",     // invalid quantifier treated as literal
		]

		for pattern in validPatterns {
			do {
				_ = try await actor.search(
					pattern: pattern,
					isRegex: true,
					options: SearchOptions(),
					in: files
				)
				// Success - pattern is valid
			} catch {
				XCTFail("Valid pattern '\(pattern)' should not throw error: \(error)")
			}
		}
	}

	func testAutoCorrectedPatterns() async throws {
		let actor = FileSearchActor()
		let files = try await createMockFiles()

		// Test patterns that are auto-corrected and should work
		let autoCorrectedPatterns = [
			// Empty alternatives that get cleaned up
			("test|", "test"),  // Trailing pipe removed
			("|test", "test"),  // Leading pipe removed
			("hello||world", "hello|world"),  // Double pipe fixed
			("one|two||three", "one|two|three"),  // Multiple fixes
		]

		for (pattern, _) in autoCorrectedPatterns {
			do {
				_ = try await actor.search(
					pattern: pattern,
					isRegex: true,
					options: SearchOptions(),
					in: files
				)
				// Success - pattern was auto-corrected and worked
			} catch {
				XCTFail("Auto-corrected pattern '\(pattern)' should not throw error: \(error)")
			}
		}
	}

	func testLiteralSearchWithSpecialCharacters() async throws {
		// Create test file with special characters
		let file = try await MockFileViewModel(
			name: "test.swift",
			relativePath: "test.swift",
			fullPath: "/test/root/test.swift",
			content: """
			func gatherExpandedFolderPaths() {
				// Implementation
			}

			let regex = "test.*pattern"
			let price = $50.00
			let email = "user@example.com"
			let path = "C:\\Program Files\\App"
			array[index]
			dict["key"]
			(a + b) * c
			test|alternative
			"""
		)

		let actor = FileSearchActor()

		// Test literal search for patterns with special regex characters
		let literalPatterns = [
			("gatherExpandedFolderPaths()", 1),
			("test.*pattern", 1),
			("$50.00", 1),
			("user@example.com", 1),
			("C:\\Program Files\\App", 1),
			("array[index]", 1),
			("dict[\"key\"]", 1),
			("(a + b) * c", 1),
			("test|alternative", 1),
		]

		for (pattern, expectedCount) in literalPatterns {
			let results = try await actor.search(
				pattern: pattern,
				isRegex: false,  // Literal search
				options: SearchOptions(),
				in: [file]
			)
			XCTAssertEqual(
				results.count, expectedCount,
				"Literal search for '\(pattern)' should find \(expectedCount) matches"
			)
		}
	}

	func testDotStarPatterns() async throws {
		let file = try await MockFileViewModel(
			name: "test.swift",
			relativePath: "test.swift",
			fullPath: "/test/root/test.swift",
			content: """
			test content here
			test: more content on same line
			func test() { return content }
			// test comment with content
			testcontent (no space)
			"""
		)

		let actor = FileSearchActor()

		// Test dot-star patterns
		let results = try await actor.search(
			pattern: "test.*content",
			isRegex: true,
			options: SearchOptions(),
			in: [file]
		)

		XCTAssertEqual(results.count, 5, "Should match all lines with 'test' followed by 'content'")

		// Test with spaces
		let spaceResults = try await actor.search(
			pattern: "test.+content",  // Requires at least one character between
			isRegex: true,
			options: SearchOptions(),
			in: [file]
		)

		XCTAssertEqual(spaceResults.count, 4, "Should not match 'testcontent' without space")
	}

	func testNonCapturingGroups() async throws {
		let file = try await MockFileViewModel(
			name: "test.swift",
			relativePath: "test.swift",
			fullPath: "/test/root/test.swift",
			content: """
			public func test()
			private func test()
			protected func test()
			internal func test()
			func test()
			"""
		)

		let actor = FileSearchActor()

		// Test non-capturing groups
		let results = try await actor.search(
			pattern: "(?:public|private|protected)\\s+func",
			isRegex: true,
			options: SearchOptions(),
			in: [file]
		)

		XCTAssertEqual(results.count, 3, "Should match functions with access modifiers")

		// Verify the matches
		let matchedLines = results.map { $0.lineText }
		XCTAssertTrue(matchedLines.contains("public func test()"))
		XCTAssertTrue(matchedLines.contains("private func test()"))
		XCTAssertTrue(matchedLines.contains("protected func test()"))
	}

	func testWholeWordWithRegex() async throws {
		let file = try await MockFileViewModel(
			name: "test.swift",
			relativePath: "test.swift",
			fullPath: "/test/root/test.swift",
			content: """
			test
			testing
			pretest
			test123
			my test here
			"""
		)

		let actor = FileSearchActor()

		// Test whole word with regex enabled
		let wholeWordResults = try await actor.search(
			pattern: "test",
			isRegex: true,
			options: SearchOptions(wholeWord: true),
			in: [file]
		)

		// Should only match 'test' as a whole word
		XCTAssertEqual(wholeWordResults.count, 2, "Should only match 'test' as whole word")

		// Verify matches
		let matchedLines = wholeWordResults.map { $0.lineText }
		XCTAssertTrue(matchedLines.contains("test"))
		XCTAssertTrue(matchedLines.contains("my test here"))
	}

	func testCaseInsensitiveRegex() async throws {
		let file = try await MockFileViewModel(
			name: "test.swift",
			relativePath: "test.swift",
			fullPath: "/test/root/test.swift",
			content: """
			SearchService
			searchService
			SEARCHSERVICE
			search_service
			"""
		)

		let actor = FileSearchActor()

		// Test case insensitive regex
		let results = try await actor.search(
			pattern: "searchservice",
			isRegex: true,
			options: SearchOptions(caseInsensitive: true),
			in: [file]
		)

		XCTAssertEqual(results.count, 3, "Should match regardless of case")

		// Test case sensitive
		let caseSensitiveResults = try await actor.search(
			pattern: "searchService",
			isRegex: true,
			options: SearchOptions(caseInsensitive: false),
			in: [file]
		)

		XCTAssertEqual(caseSensitiveResults.count, 1, "Should only match exact case")
	}

	func testRegexWithContextLines() async throws {
		let file = try await MockFileViewModel(
			name: "test.swift",
			relativePath: "test.swift",
			fullPath: "/test/root/test.swift",
			content: """
			line 1
			line 2
			test pattern here
			line 4
			line 5
			"""
		)

		let actor = FileSearchActor()

		// Test regex with context lines
		let results = try await actor.search(
			pattern: "test.*pattern",
			isRegex: true,
			options: SearchOptions(contextLines: 2),
			in: [file]
		)

		XCTAssertEqual(results.count, 1)
		let match = results[0]

		// Check context
		XCTAssertNotNil(match.contextBefore)
		XCTAssertNotNil(match.contextAfter)

		if let before = match.contextBefore {
			XCTAssertEqual(before.count, 2)
			XCTAssertEqual(before[0], "line 1")
			XCTAssertEqual(before[1], "line 2")
		}

		if let after = match.contextAfter {
			XCTAssertEqual(after.count, 2)
			XCTAssertEqual(after[0], "line 4")
			XCTAssertEqual(after[1], "line 5")
		}
	}

	func testRegexErrorPropagation() async throws {
		let actor = FileSearchActor()
		let files = try await createMockFiles()

		// Test that regex errors are properly caught and re-thrown
		do {
			_ = try await actor.search(
				pattern: "invalid\\k",  // Invalid escape sequence
				isRegex: true,
				options: SearchOptions(),
				in: files
			)
			XCTFail("Should have thrown an error for invalid regex")
		} catch {
			// Verify the error message is helpful
			let errorMessage = error.localizedDescription
			XCTAssertTrue(
				errorMessage.contains("Invalid") || errorMessage.contains("escape"),
				"Error should mention invalid escape sequence"
			)
		}
	}

    // MARK: - High-Risk Pattern Detection Tests

    func testHighRiskPatternDetection() async throws {
        let file = try await MockFileViewModel(
            name: "test.txt",
            relativePath: "test.txt",
            fullPath: "/test/root/test.txt",
            content: "aaaaaaaaaaaa"
        )

        let actor = FileSearchActor()

        // Test catastrophic backtracking patterns are rejected
        do {
            _ = try await actor.search(
                pattern: "^(a+)+b$",
                isRegex: true,
                options: SearchOptions(),
                in: [file]
            )
            XCTFail("Should have thrown SearchPatternTooComplexError")
        } catch is SearchPatternTooComplexError {
            // Expected
        }

        // Test other dangerous patterns
        let dangerousPatterns = [
            "^(a*)*b$",
            "^(a?)?b$",
            "^(a{1,3}){2,5}b$",
            "^((a+))+$"
        ]

        for pattern in dangerousPatterns {
            do {
                _ = try await actor.search(
                    pattern: pattern,
                    isRegex: true,
                    options: SearchOptions(),
                    in: [file]
                )
                XCTFail("Pattern '\(pattern)' should have been rejected")
            } catch is SearchPatternTooComplexError {
                // Expected
            }
        }
    }

    func testSafeAnchoredPatternsAllowed() async throws {
        let file = try await MockFileViewModel(
            name: "test.txt",
            relativePath: "test.txt",
            fullPath: "/test/root/test.txt",
            content: "TODO: fix this\nBUG: broken\n2024-01-01"
        )

        let actor = FileSearchActor()

        // These anchored patterns should work fine
        // Note: Only patterns with both ^ and $ are considered "line-anchored" and use line-by-line scanning
        // Patterns with only ^ match start of entire string, not start of each line
        let safePatterns = [
            ("^TODO:", 1),  // Matches start of string
            ("TODO:", 1),   // Non-anchored version
            ("BUG:", 1),    // Non-anchored - will find BUG: on second line
            ("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", 1),  // Full line anchor - uses line-by-line
            ("^\\w+:$", 0),  // No match - no line ends with just word:
            ("(?m)^[A-Z]+:", 2),  // Multi-line mode to match start of each line
            ("[A-Z]+:", 2)   // Non-anchored - will find both TODO: and BUG:
        ]

        for (pattern, expectedCount) in safePatterns {
            let results = try await actor.search(
                pattern: pattern,
                isRegex: true,
                options: SearchOptions(),
                in: [file]
            )
            XCTAssertEqual(results.count, expectedCount,
                          "Pattern '\(pattern)' should have \(expectedCount) matches. Got \(results.count): \(results.map { $0.lineText })")
        }
    }

    func testPatternLengthLimit() async throws {
        let file = try await MockFileViewModel(
            name: "test.txt",
            relativePath: "test.txt",
            fullPath: "/test/root/test.txt",
            content: "test content"
        )

        let actor = FileSearchActor()

        // Create a pattern that exceeds the 2000 character limit
        let longPattern = String(repeating: "a", count: 2001)

        do {
            _ = try await actor.search(
                pattern: longPattern,
                isRegex: true,
                options: SearchOptions(),
                in: [file]
            )
            XCTFail("Should have thrown SearchPatternTooComplexError for overly long pattern")
        } catch is SearchPatternTooComplexError {
            // Expected
        }

        // Pattern just under the limit should work
        let almostLongPattern = String(repeating: "a", count: 1999)
        _ = try await actor.search(
            pattern: almostLongPattern,
            isRegex: false,  // Use literal search to avoid other validation
            options: SearchOptions(),
            in: [file]
        )
        // Should not throw
    }

    // MARK: - Regression Tests for Practical Patterns

    func testPracticalCodebasePatterns() async throws {
        let actor = FileSearchActor()

        // Create mock files with realistic code content
        let swiftFile = try await MockFileViewModel(
            name: "Example.swift",
            relativePath: "Example.swift",
            fullPath: "/test/Example.swift",
            content: """
import Foundation

func setupDatabase() throws {
    // TODO: Implement connection pooling
    print("Setting up database")
}

var userName: String = "test"
var userId: Int = 123

@State private var isLoading = false
@Published var users: [User] = []

do {
    try performAction()
} catch DatabaseError.connectionFailed {
    print("Connection failed")
} catch {
    throw error
}
"""
        )

        let jsFile = try await MockFileViewModel(
            name: "app.js",
            relativePath: "app.js",
            fullPath: "/test/app.js",
            content: """
            function validateUser(email) {
                // FIXME: Add proper email validation
                return email.includes('@');
            }

            const userData = {
                name: 'John',
                email: 'john@example.com'
            };

            try {
                const result = await fetchData();
                console.log(result);
            } catch (error) {
                console.error('Error:', error);
            }
            """
        )

        let files = [swiftFile, jsFile]

        // Test cases: (pattern, isRegex, shouldMatch, description)
        let testCases: [(String, Bool, Bool, String)] = [
            // PCRE-style patterns that now work with NSRegularExpression
            ("func \\w+\\(", true, true, "Function definitions with word characters"),
            ("var \\w+: \\w+", true, true, "Variable declarations with types"),
            ("\\w+@\\w+\\.\\w+", true, true, "Email pattern with word boundaries"),
            ("\\d+", true, true, "Numeric literals"),
            ("\\b\\w+Error\\b", true, true, "Error class names with word boundaries"),

            // Alternative patterns
            ("TODO|FIXME|HACK|XXX", true, true, "Code comment markers"),
            ("catch|throw|throws", true, true, "Exception handling keywords"),
            ("@State|@Published", true, true, "SwiftUI property wrappers"),
            ("import|export|require", true, true, "Module system keywords"),

            // Character classes and quantifiers
            ("[A-Z][a-z]+", true, true, "Capitalized words"),
            ("\\w{3,}", true, true, "Words with 3+ characters"),
            ("'[^']*'", true, true, "Single-quoted strings"),

            // Anchored patterns
            ("^import", true, true, "Lines starting with import"),
            ("\\}$", true, true, "Lines ending with closing brace"),
            ("^\\s*//", true, true, "Comment lines"),

            // Lookahead/lookbehind (if supported)
            ("\\w+(?=\\()", true, true, "Function names followed by parentheses"),

            // Should not match
            ("nonexistentfunction", true, false, "Non-existent function name"),
            ("\\w{50,}", true, false, "Extremely long words"),
        ]

        for (pattern, isRegex, shouldMatch, description) in testCases {
            do {
                let results = try await actor.search(
                    pattern: pattern,
                    isRegex: isRegex,
                    options: SearchOptions(),
                    in: files
                )

                let hasMatches = !results.isEmpty
                XCTAssertEqual(hasMatches, shouldMatch,
                    "Pattern '\(pattern)' \(description): expected \(shouldMatch ? "matches" : "no matches") but got \(hasMatches ? "matches" : "no matches")")

                if shouldMatch && hasMatches {
                    // Verify we get reasonable results
                    XCTAssertTrue(results.count > 0, "Should have at least one match for '\(pattern)'")

                    // Verify match content makes sense
                    for match in results {
                        XCTAssertFalse(match.lineText.isEmpty, "Match line should not be empty")
                        XCTAssertTrue(match.lineNumber >= 0, "Line number should be valid")
                    }
                }

            } catch {
                XCTFail("Pattern '\(pattern)' (\(description)) threw unexpected error: \(error)")
            }
        }
    }

    func testDualEngineSelection() async throws {
        let actor = FileSearchActor()
        let file = try await MockFileViewModel(
            name: "code.swift",
            relativePath: "code.swift",
            fullPath: "/test/code.swift",
            content: "func testFunction() { print('test') }"
        )

        // Test that PCRE-only patterns use NSRegularExpression engine
        let pcrePattern = "func \\w+\\("  // Contains \w which is PCRE-only
        let results = try await actor.search(
            pattern: pcrePattern,
            isRegex: true,
            options: SearchOptions(),
            in: [file]
        )

        XCTAssertEqual(results.count, 1, "Should find the function definition")
        XCTAssertTrue(results[0].lineText.contains("func testFunction"), "Should match the correct line")
    }

    func testStartAnchorMatchesEachLine() async throws {
        let file = try await MockFileViewModel(
            name: "test.txt",
            relativePath: "test.txt",
            fullPath: "/test/test.txt",
            content: "line\n // c1\n // c2"
        )
        let actor = FileSearchActor()
        let hits = try await actor.search(
            pattern: "^\\s*//",
            isRegex: true,
            options: SearchOptions(),
            in: [file]
        )
		XCTAssertEqual(hits.map(\.lineNumber), [1, 2], "Should match both comment lines")
    }

    func testPCREShortcuts() async throws {
        let file = try await MockFileViewModel(
            name: "sample.swift",
            relativePath: "sample.swift",
            fullPath: "/tmp/sample.swift",
            content: "func test123()\nlet foo_bar = 1\n"
        )
        let actor = FileSearchActor()

        let patterns = ["\\w+", "\\bfoo_bar\\b", "\\s+", "test\\d+"]
        for pat in patterns {
            let hits = try await actor.search(pattern: pat,
                                              isRegex: true,
                                              options: SearchOptions(),
                                              in: [file])
            XCTAssertFalse(hits.isEmpty, "Pattern \(pat) should match")
        }
    }


    func testPerFileErrorHandling() async throws {
        let actor = FileSearchActor()
        let files = [
            try await MockFileViewModel(name: "good.txt", relativePath: "good.txt", fullPath: "/test/good.txt", content: "normal content"),
            try await MockFileViewModel(name: "bad.txt", relativePath: "bad.txt", fullPath: "/test/bad.txt", content: "more content")
        ]

        // Use unified search to test per-file error collection
        let results = try await actor.searchUnified(
            pattern: "content",
            isRegex: false,
            options: SearchOptions(),
            in: files
        )

        // Should get matches from both files
        XCTAssertNotNil(results.matches, "Should have matches")
        XCTAssertEqual(results.matches?.count, 2, "Should match in both files")

        // Should not have per-file errors for simple literal search
        XCTAssertNil(results.perFileErrors, "Should not have per-file errors for simple search")
    }

	// MARK: - Regex Normalization and Escaping Tests

	func testNormaliseEscapesAndPreservesParens() throws {
		// Repairs unmatched '('
		let r1 = try RegexToolkit.normalise("frame(minWidth:")
		XCTAssertEqual(r1.text, "frame\\(minWidth:")
		XCTAssertTrue(r1.wasModified)

		// Repairs both sides in alternation while preserving escaped dot
		let r2 = try RegexToolkit.normalise("frame(minWidth:|\\.frame(minWidth:")
		XCTAssertEqual(r2.text, "frame\\(minWidth:|\\.frame\\(minWidth:")
		XCTAssertTrue(r2.wasModified)

		// Preserves intentional escapes
		let r3 = try RegexToolkit.normalise("frame\\(minWidth:")
		XCTAssertEqual(r3.text, "frame\\(minWidth:")
		XCTAssertFalse(r3.wasModified)
	}

	func testRegexSearchWithEscapedParenViaJSON() async throws {
		let file = try await MockFileViewModel(
			name: "view.swift",
			relativePath: "view.swift",
			fullPath: "/test/root/view.swift",
			content: "Text(\"hi\").frame(minWidth: 10)"
		)
		let actor = FileSearchActor()
		let results = try await actor.search(
			pattern: "frame\\(minWidth:",
			isRegex: true,
			options: SearchOptions(),
			in: [file]
		)
		XCTAssertEqual(results.count, 1, "Regex with escaped '(' should match the literal parenthesis")
		XCTAssertTrue(results[0].lineText.contains("frame(minWidth:"))
	}

	func testAutoLiteralFallbackForOverEscapedParen() async throws {
		let file = try await MockFileViewModel(
			name: "view.swift",
			relativePath: "view.swift",
			fullPath: "/test/root/view.swift",
			content: "Text(\"hi\").frame(minWidth: 10)"
		)
		let actor = FileSearchActor()
		// User mistakenly over-escaped in literal mode
		let results = try await actor.search(
			pattern: "frame\\(minWidth:",
			isRegex: false,
			options: SearchOptions(),
			in: [file]
		)
		XCTAssertEqual(results.count, 1, "Auto mode should fallback by de-escaping and find the literal parenthesis")
	}

	func testAutoLiteralFallbackForDoubleEscapedParen() async throws {
		let file = try await MockFileViewModel(
			name: "view.swift",
			relativePath: "view.swift",
			fullPath: "/test/root/view.swift",
			content: "Text(\"hi\").frame(minWidth: 10)"
		)
		let actor = FileSearchActor()
		let results = try await actor.search(
			pattern: #"frame\\(minWidth:"#,
			isRegex: false,
			options: SearchOptions(),
			in: [file]
		)
		XCTAssertEqual(results.count, 1, "Double-escaped literal input should repair to the intended literal search")
		XCTAssertTrue(results[0].lineText.contains("frame(minWidth:"))
	}

	func testDoubleEscapedPureLiteralBackslashPatternDoesNotAutoRepair() async throws {
		let file = try await MockFileViewModel(
			name: "view.swift",
			relativePath: "view.swift",
			fullPath: "/test/root/view.swift",
			content: "Text(\"hi\").frame(minWidth: 10)"
		)
		let actor = FileSearchActor()
		let results = try await actor.search(
			pattern: #"\\("#,
			isRegex: false,
			options: SearchOptions(),
			in: [file]
		)
		XCTAssertEqual(results.count, 0, "A pure literal backslash+meta search should not auto-repair to a plain metacharacter")
	}

	func testStrictLiteralNoFallback() async throws {
		let file = try await MockFileViewModel(
			name: "view.swift",
			relativePath: "view.swift",
			fullPath: "/test/root/view.swift",
			content: "Text(\"hi\").frame(minWidth: 10)"
		)
		var options = SearchOptions()
		options.allowLiteralUnescapeFallback = false
		let actor = FileSearchActor()
		let results = try await actor.search(
			pattern: "frame\\(minWidth:",
			isRegex: false,
			options: options,
			in: [file]
		)
		XCTAssertEqual(results.count, 0, "With fallback disabled, over-escaped literal should not match")
	}

	func testPathRegexAutoEscapesUnbalancedParens() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "Button(Style).swift",
			relativePath: "Views/Button(Style).swift",
			fullPath: "/test/root/Views/Button(Style).swift",
			content: "struct ButtonStyle {}"
		)
		let hits = try await actor.searchPaths(
			pattern: "Button(Style",
			limit: 10,
			in: [file],
			caseInsensitive: true,
			isRegex: true
		)
		XCTAssertEqual(hits, ["/test/root/Views/Button(Style).swift"], "Path regex should work after normalization of unmatched '('")
	}

	func testLiteralDoubleBackslashPreserved() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "doc.txt",
			relativePath: "doc.txt",
			fullPath: "/test/root/doc.txt",
			content: #"Use regex \( to escape a parenthesis. Also backslash: \\("#
		)
		// Literal search for "\(" should match the backslash + paren sequence
		let results = try await actor.search(
			pattern: "\\(",
			isRegex: false,
			options: SearchOptions(),
			in: [file]
		)
		XCTAssertEqual(results.count, 1, "Literal backslash + '(' should be found")
		XCTAssertTrue(results[0].lineText.contains("\\("))
	}

	// MARK: - Regressions: Path wildcard friendliness (*Manager vs *Manager.cs)

	/// Ensures that a suffix-style glob like `*Manager` continues to find
	/// files such as `GameManager.cs` (via our friendly glob fallback),
	/// and that the stricter `*Manager.cs` baseline still works.
	func testPathWildcardFriendlyFallback_Manager() async throws {
		let actor = FileSearchActor()
		let managerFiles = [
			"Assets/Content/Scripts/BoxManager.cs",
			"Assets/Content/Scripts/GameManager.cs",
			"Assets/Content/Scripts/GameUIManager.cs",
			"Assets/Content/Scripts/TutorialManager.cs",
			"Assets/Content/Scripts/WallManager.cs"
		]
		// Negative control
		let otherFiles = [
			"Assets/Content/Scripts/Player.cs",
			"Docs/Readme.md"
		]

		var files: [MockFileViewModel] = []
		for p in managerFiles + otherFiles {
			let name = (p as NSString).lastPathComponent
			files.append(try await MockFileViewModel(
				name: name,
				relativePath: p,
				fullPath: "/project/\(p)",
				content: nil
			))
		}

		// Baseline: explicit extension should match exactly those 5 files.
		let extHits = try await actor.searchPaths(
			pattern: "*Manager.cs",
			limit: 100,
			in: files,
			caseInsensitive: true,
			isRegex: false
		)
		let expectedFullPaths = Set(managerFiles.map { "/test/root/\($0)" })
		XCTAssertEqual(Set(extHits), expectedFullPaths, "*Manager.cs should match exactly the Manager.cs files")

		// Friendly behavior: *Manager should also include those Manager.cs files
		// (broader intent when strict suffix finds nothing).
		let suffixHits = try await actor.searchPaths(
			pattern: "*Manager",
			limit: 100,
			in: files,
			caseInsensitive: true,
			isRegex: false
		)
		for expected in managerFiles {
			let fullExpected = "/test/root/\(expected)"
			XCTAssertTrue(suffixHits.contains(fullExpected), "*Manager should include \(expected)")
		}
		XCTAssertGreaterThanOrEqual(suffixHits.count, managerFiles.count,
									"*Manager can be broader, but must include all Manager.cs files")
	}

	/// Verifies that case-insensitive path wildcard matching works
	/// (guards the CASEFOLD flag wiring). Lowercased pattern must
	/// still match camel-cased filenames.
	func testPathWildcardCaseInsensitive_Manager() async throws {
		let actor = FileSearchActor()
		let paths = [
			"Assets/Content/Scripts/GameManager.cs",
			"Assets/Content/Scripts/BoxManager.cs"
		]
		var files: [MockFileViewModel] = []
		for p in paths {
			let name = (p as NSString).lastPathComponent
			files.append(try await MockFileViewModel(
				name: name,
				relativePath: p,
				fullPath: "/project/\(p)",
				content: nil
			))
		}

		let hits = try await actor.searchPaths(
			pattern: "*manager.cs",   // lowercased pattern
			limit: 100,
			in: files,
			caseInsensitive: true,    // must be honored
			isRegex: false
		)
		let expectedCasePaths = Set(paths.map { "/test/root/\($0)" })
		XCTAssertEqual(Set(hits), expectedCasePaths, "Case-insensitive glob should match camel-cased filenames")
	}

	/// Ensures that when the caller defaults to regex=true, globby path inputs
	/// like `*Manager` still succeed (regex compile fails → fallback to glob).
	func testPathGlobWithRegexDefaultFallback_Manager() async throws {
		let actor = FileSearchActor()
		let managerFiles = [
			"Assets/Content/Scripts/GameManager.cs",
			"Assets/Content/Scripts/WallManager.cs"
		]
		var files: [MockFileViewModel] = []
		for p in managerFiles {
			let name = (p as NSString).lastPathComponent
			files.append(try await MockFileViewModel(
				name: name,
				relativePath: p,
				fullPath: "/project/\(p)",
				content: nil
			))
		}

		// Intentionally pass isRegex=true with a glob pattern.
		// Implementation should gracefully fall back to glob/literal.
		let hits = try await actor.searchPaths(
			pattern: "*Manager",
			limit: 100,
			in: files,
			caseInsensitive: true,
			isRegex: true
		)
		for expected in managerFiles {
			let fullExpected = "/test/root/\(expected)"
			XCTAssertTrue(hits.contains(fullExpected),
						  "With default regex=true, glob '*Manager' should still match via fallback: \(expected)")
		}
	}

	func testPathSearchHonorsRootAliasPrefixes() async throws {
		let actor = FileSearchActor()
		let file = try await MockFileViewModel(
			name: "index.ts",
			relativePath: "src/index.ts",
			fullPath: "/project/src/index.ts",
			content: nil
		)
		let aliasMap = ["/test/root": "RepoPromptWeb"]

		let wildcardHits = try await actor.searchPaths(
			pattern: "RepoPromptWeb/src/*.ts",
			limit: 10,
			in: [file],
			caseInsensitive: true,
			isRegex: false,
			aliasByRootPath: aliasMap
		)
		let expectedAliasPath = ["/test/root/src/index.ts"]
		XCTAssertEqual(wildcardHits, expectedAliasPath)

		let literalHits = try await actor.searchPaths(
			pattern: "RepoPromptWeb/src/index.ts",
			limit: 10,
			in: [file],
			caseInsensitive: true,
			isRegex: false,
			aliasByRootPath: aliasMap
		)
		XCTAssertEqual(literalHits, expectedAliasPath)

		let regexHits = try await actor.searchPaths(
			pattern: #"^RepoPromptWeb/src/.*\.ts$"#,
			limit: 10,
			in: [file],
			caseInsensitive: true,
			isRegex: true,
			aliasByRootPath: aliasMap
		)
		XCTAssertEqual(regexHits, expectedAliasPath)

		var options = SearchOptions()
		options.mode = .path
		let unified = try await actor.searchUnified(
			pattern: "RepoPromptWeb/src/index.ts",
			isRegex: false,
			options: options,
			in: [file],
			aliasByRootPath: aliasMap
		)
		XCTAssertEqual(unified.paths, expectedAliasPath)
	}
}
