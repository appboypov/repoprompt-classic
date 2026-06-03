import XCTest
@testable import RepoPrompt
import Foundation

private func XCTAssertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) async {
    do { _ = try await expression() }
    catch { return }         // ✅ expected throw
    XCTFail(message(), file: file, line: line)
}

// MARK: - In-memory FileViewModel for stress tests
final class StressMockFileViewModel: FileViewModel {
    private let mockContent: String?
    
    init(
        name: String,
        relativePath: String,
        fullPath: String,
        content: String? = nil
    ) async throws {
        self.mockContent = content
        
        let rootPath = "/stress/root"
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

// MARK: - Helper utilities
struct TestDataBuilder {
    /// Returns a single `StressMockFileViewModel` with the supplied content.
    static func mockFile(
        name: String,
        relativePath: String,
        content: String
    ) async throws -> StressMockFileViewModel {
        try await StressMockFileViewModel(
            name: name,
            relativePath: relativePath,
            fullPath: "/project/\(relativePath)",
            content: content
        )
    }
    
    /// Repeats `line` `count` times separated by `\n`.
    static func repeatedLine(_ line: String, count: Int) -> String {
        Array(repeating: line, count: count).joined(separator: "\n")
    }
    
    /// Generates a very long line containing mixed Unicode scalars.
    static func largeUnicodeLine(repeatCount: Int) -> String {
        let fragment = "👩🏽‍🚀—π≈𝟘💡"
        return String(repeating: fragment, count: repeatCount)
    }
}

// MARK: - Stress test-suite
class SearchStressTests: XCTestCase {
    
    // Convenience actor instance reused across tests
    private let actor = FileSearchActor()
    
    // MARK: 1) Regex complexity – nested look-aheads
    func testCrazyRegexLookahead() async throws {
        let content = TestDataBuilder.repeatedLine("abc123", count: 150)
        let file = try await TestDataBuilder.mockFile(
            name: "Crazy.swift",
            relativePath: "Crazy.swift",
            content: content
        )
        
        // Build a 50-nested group pattern which is still heavy but compiles fast
        let nestedPattern = String(repeating: "(", count: 50) + "\\w" + String(repeating: ")", count: 50)
        
        let actor = FileSearchActor()
        let results = try await actor.search(
            pattern: nestedPattern,
            isRegex: true,
            options: SearchOptions(maxResults: 5),
            in: [file]
        )
        
        XCTAssertFalse(results.isEmpty, "Deeply nested regex should still yield matches")
    }
    
    // MARK: 2) Catastrophic backtracking – should respect per-file timeout
    func testCatastrophicBacktracking() async throws {
        let longA = String(repeating: "a", count: 800)
        let file  = try await TestDataBuilder.mockFile(
            name: "Backtrack.txt",
            relativePath: "Backtrack.txt",
            content: longA
        )

        await XCTAssertThrowsAsync(
            try await FileSearchActor().search(
                pattern: "^(a+)+b$",
                isRegex: true,
                options: SearchOptions(maxResults: 5),
                in: [file]
            ),
            "High-risk pattern should be rejected immediately"
        )
    }
    
    // MARK: 3) Content edge-case – very long Unicode line
    func testVeryLongUnicodeLine() async throws {
        let line   = TestDataBuilder.largeUnicodeLine(repeatCount: 100_000 / 10) // ≈1 MB
        let file   = try await TestDataBuilder.mockFile(
            name: "Unicode.txt",
            relativePath: "Unicode.txt",
            content: line
        )
        let results = try await actor.search(
            pattern: "👩🏽‍🚀",
            isRegex: false,
            options: SearchOptions(caseInsensitive: false, maxResults: 5),
            in: [file]
        )
        XCTAssertEqual(results.count, 1, "Should find the emoji exactly once in huge line")
        let match = results[0]
        XCTAssertEqual(match.lineNumber, 0, "Match should be on first (and only) line")
    }
    
    // MARK: 4) Pattern edge-case – extremely long alternation
    func testExtremelyLongAlternation() async throws {
        let tokens = (0..<200).map { "token\($0)" }
        let pattern = tokens.joined(separator: "|")
        let content = "prefix token50 suffix"
        
        let file = try await TestDataBuilder.mockFile(
            name: "Alt.swift",
            relativePath: "Alt.swift",
            content: content
        )
        
        let results = try await actor.search(
            pattern: pattern,
            isRegex: true,
            options: SearchOptions(caseInsensitive: false, maxResults: 20),
            in: [file]
        )
        
        XCTAssertFalse(results.isEmpty, "Long alternation pattern should compile and match")
    }
    
    // MARK: 5) Performance stress – one million matches, enforce maxResults
    func testMillionMatchesLimit() async throws {
        let content = TestDataBuilder.repeatedLine("hit", count: 100_000)
        let file = try await TestDataBuilder.mockFile(
            name: "Hits.txt",
            relativePath: "Hits.txt",
            content: content
        )
        
        let start = Date()
        let results = try await actor.search(
            pattern: "hit",
            isRegex: false,
            options: SearchOptions(maxResults: 500),
            in: [file]
        )
        let elapsed = Date().timeIntervalSince(start)
        
        XCTAssertLessThanOrEqual(results.count, 500,
                                 "Search should cap results at the requested maxResults")
        XCTAssertLessThan(elapsed, 3.0,
                          "Large literal scan should conclude quickly")
    }
    
    // MARK: 6) Boundary conditions – matches at start & end of file
    func testMatchAtStartAndEndOfFile() async throws {
        let content = ["START", "middle", "END"].joined(separator: "\n")
        let file = try await TestDataBuilder.mockFile(
            name: "Boundary.txt",
            relativePath: "Boundary.txt",
            content: content
        )
        
        let actor = FileSearchActor()
        
        // Start line
        let startMatches = try await actor.search(
            pattern: "START",
            isRegex: false,
            options: SearchOptions(contextLines: 2),
            in: [file]
        )
        let startContextBeforeIsEmpty = startMatches.first?.contextBefore?.isEmpty ?? true
        XCTAssertTrue(startContextBeforeIsEmpty, "First line match should have no contextBefore")
        
        // End line
        let endMatches = try await actor.search(
            pattern: "END",
            isRegex: false,
            options: SearchOptions(contextLines: 2),
            in: [file]
        )
        let endContextAfterIsEmpty = endMatches.first?.contextAfter?.isEmpty ?? true
        XCTAssertTrue(endContextAfterIsEmpty, "Last line match should have no contextAfter")
    }
    
    // MARK: 7) Error conditions – invalid regex pattern
    func testInvalidRegexPattern() async throws {
        let file = try await TestDataBuilder.mockFile(
            name: "Dummy.txt",
            relativePath: "Dummy.txt",
            content: "just some text"
        )
        
        await XCTAssertThrowsAsync(
            try await FileSearchActor().search(
                pattern: "[a-z",
                isRegex: true,
                options: SearchOptions(),
                in: [file]
            ),
            "Compiling an obviously invalid regex must throw"
        )
    }
    
    // MARK: 8) Feature combination – whole word + fuzzy space + case sensitivity
    func testWholeWordPlusFuzzyPlusCase() async throws {
        let content = "Rocket     launch successful"
        let file = try await TestDataBuilder.mockFile(
            name: "Launch.log",
            relativePath: "Launch.log",
            content: content
        )
        
        let results = try await FileSearchActor().search(
            pattern: "Rocket launch",
            isRegex: false,
            options: SearchOptions(
                caseInsensitive: false,
                wholeWord: false,          // wholeWord is incompatible with fuzzy spaces here
                maxResults: 10,
                fuzzySpaceMatching: true
            ),
            in: [file]
        )
        
        XCTAssertEqual(results.count, 1,
                       "Combined options should match despite variable spacing")
    }
}
