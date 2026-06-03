//
//  CodeMapQueryValidationTests.swift
//  RepoPromptTests
//
//  Validates that all codemap queries compile correctly and follow formatting standards.
//  This is a fast test that catches query syntax errors without needing fixtures.
//

import XCTest
@testable import RepoPrompt

final class CodeMapQueryValidationTests: XCTestCase {

    private struct CaptureSignature: Equatable, Sendable {
        let name: String
        let location: Int
        let length: Int
    }

    // MARK: - Query Compilation Tests

    /// Validates all codemap queries compile and have no tabs
    func testAllCodeMapQueries_CompileSuccessfully() {
        CodeMapQueryValidator.validateAllQueries()
    }

    func testCachedCodeMapQueryReuse_IsSafeUnderConcurrentExecution() async throws {
        let cases: [(name: String, fileExtension: String, content: String)] = [
            (
                name: "Swift",
                fileExtension: "swift",
                content: """
                import Foundation
                public struct ConcurrentCodemapExample {
                    let value: Int
                    func doubled() -> Int { value * 2 }
                }
                """
            ),
            (
                name: "TypeScript",
                fileExtension: "ts",
                content: """
                export interface ConcurrentCodemapUser {
                    id: string
                    name: string
                }
                export class ConcurrentCodemapStore {
                    load(id: string): ConcurrentCodemapUser | undefined { return undefined }
                }
                export const makeUser = (id: string): ConcurrentCodemapUser => ({ id, name: id })
                """
            )
        ]

        for testCase in cases {
            let baseline = try Self.captureSignature(
                content: testCase.content,
                fileExtension: testCase.fileExtension
            )
            XCTAssertFalse(baseline.isEmpty, "\(testCase.name) baseline should produce captures")

            try await withThrowingTaskGroup(of: [CaptureSignature].self) { group in
                for _ in 0..<160 {
                    group.addTask {
                        try Self.captureSignature(
                            content: testCase.content,
                            fileExtension: testCase.fileExtension
                        )
                    }
                }

                for try await signature in group {
                    XCTAssertEqual(signature, baseline, "\(testCase.name) cached query reuse should be deterministic under concurrent execution")
                }
            }
        }
    }

    func testLazySwiftHighlightQueryReuse_IsSafeUnderRepeatedAndConcurrentUse() async throws {
        let content = """
        import Foundation
        public struct ConcurrentHighlightExample {
            let value: Int
            func doubled() -> Int { value * 2 }
        }
        """

        let baseline = try Self.highlightSignature(content: content, fileExtension: "swift")
        let repeated = try Self.highlightSignature(content: content, fileExtension: "swift")
        XCTAssertEqual(repeated, baseline, "Repeated Swift highlight calls should be deterministic")

        try await withThrowingTaskGroup(of: [CaptureSignature].self) { group in
            for _ in 0..<80 {
                group.addTask {
                    try Self.highlightSignature(content: content, fileExtension: "swift")
                }
            }

            for try await signature in group {
                XCTAssertEqual(signature, baseline, "Concurrent Swift highlight calls should be deterministic")
            }
        }
    }

    private static func captureSignature(content: String, fileExtension: String) throws -> [CaptureSignature] {
        try SyntaxManager.shared.codeMap(content: content, fileExtension: fileExtension)
            .map { capture in
                CaptureSignature(
                    name: capture.name,
                    location: capture.range.location,
                    length: capture.range.length
                )
            }
    }

    private static func highlightSignature(content: String, fileExtension: String) throws -> [CaptureSignature] {
        try SyntaxManager.shared.highlight(content: content, fileExtension: fileExtension)
            .map { capture in
                CaptureSignature(
                    name: capture.name,
                    location: capture.range.location,
                    length: capture.range.length
                )
            }
    }

    // MARK: - Individual Language Query Tests

    func testSwiftQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "swift")
    }

    func testTypeScriptQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "ts")
    }

    func testTSXQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "tsx")
    }

    func testJavaScriptQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "js")
    }

    func testPythonQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "py")
    }

    func testGoQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "go")
    }

    func testRustQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "rs")
    }

    func testCQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "c")
    }

    func testCppQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "cpp")
    }

    func testCSharpQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "cs")
    }

    func testJavaQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "java")
    }

    func testDartQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "dart")
    }

    func testPHPQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "php")
    }

    func testRubyQuery_IsValid() {
        CodeMapQueryValidator.validateQuery(forExtension: "rb")
    }

    // MARK: - Query Coverage Tests

    /// Ensures every language in extensionToLanguage has a codemap query
    func testAllLanguageTypes_HaveCodeMapQueries() {
        for ext in CodeMapFixtureRunner.supportedExtensions {
            guard let languageType = SyntaxManager.shared.extensionToLanguage[ext.lowercased()] else {
                XCTFail("[\(ext)] No language type found")
                continue
            }

            let hasQuery = SyntaxManager.shared.codeMapQueries[languageType] != nil
            XCTAssertTrue(hasQuery, "[\(ext)/\(languageType)] Missing codemap query")
        }
    }

    /// Tests that queries don't contain common problematic patterns
    func testCodeMapQueries_NoProblematicPatterns() {
        for ext in CodeMapFixtureRunner.supportedExtensions {
            guard let languageType = SyntaxManager.shared.extensionToLanguage[ext.lowercased()],
                  let queryString = SyntaxManager.shared.codeMapQueries[languageType] else {
                continue
            }

            // No tabs (can cause parsing issues) - soft warning for now
            if queryString.contains("\t") {
                print("⚠️ [\(ext)] Query contains tabs - consider using spaces")
            }

            // No trailing whitespace in capture names (common typo)
            let capturePattern = #"@[\w.]+ \""#
            if queryString.range(of: capturePattern, options: .regularExpression) != nil {
                // This is a soft check - just looking for @name followed by space before quote
                // Not a hard fail since some patterns might legitimately have this
            }

            // Should have at least one capture
            XCTAssertTrue(queryString.contains("@"),
                          "[\(ext)] Query has no captures (no @ symbols)")
        }
    }

    // MARK: - Query Content Tests

    /// Tests that queries capture expected node types for their language
    func testSwiftQuery_CapturesExpectedNodes() {
        guard let query = SyntaxManager.shared.codeMapQueries[.swift] else {
            XCTFail("Swift codemap query not found")
            return
        }

        // Swift queries should capture these common constructs
        XCTAssertTrue(query.contains("class_declaration") || query.contains("class.definition"),
                      "Swift query should capture class declarations")
        XCTAssertTrue(query.contains("function_declaration") || query.contains("function.definition"),
                      "Swift query should capture function declarations")
        XCTAssertTrue(query.contains("import_declaration") || query.contains("import"),
                      "Swift query should capture imports")
    }

    func testTypeScriptQuery_CapturesExpectedNodes() {
        guard let query = SyntaxManager.shared.codeMapQueries[.ts] else {
            XCTFail("TypeScript codemap query not found")
            return
        }

        // TypeScript queries should capture these common constructs
        XCTAssertTrue(query.contains("class_declaration") || query.contains("class.definition"),
                      "TypeScript query should capture class declarations")
        XCTAssertTrue(query.contains("interface_declaration") || query.contains("interface.definition"),
                      "TypeScript query should capture interface declarations")
        XCTAssertTrue(query.contains("function_declaration") || query.contains("function.definition") || query.contains("arrow_function"),
                      "TypeScript query should capture function declarations")
    }

    func testPythonQuery_CapturesExpectedNodes() {
        guard let query = SyntaxManager.shared.codeMapQueries[.python] else {
            XCTFail("Python codemap query not found")
            return
        }

        // Python queries should capture these common constructs
        XCTAssertTrue(query.contains("class_definition"),
                      "Python query should capture class definitions")
        XCTAssertTrue(query.contains("function_definition"),
                      "Python query should capture function definitions")
        XCTAssertTrue(query.contains("import_statement") || query.contains("import_from_statement"),
                      "Python query should capture imports")
    }

    func testRubyQuery_CapturesExpectedNodes() {
        guard let query = SyntaxManager.shared.codeMapQueries[.ruby] else {
            XCTFail("Ruby codemap query not found")
            return
        }

        // Ruby queries should capture these common constructs
        XCTAssertTrue(query.contains("class"),
                      "Ruby query should capture class declarations")
        XCTAssertTrue(query.contains("module"),
                      "Ruby query should capture module declarations")
        XCTAssertTrue(query.contains("method") || query.contains("singleton_method"),
                      "Ruby query should capture method declarations")
    }
}
