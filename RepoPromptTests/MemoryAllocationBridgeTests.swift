//
//  MemoryAllocationBridgeTests.swift
//  RepoPromptTests
//
//  Memory allocation and safety tests for C/Swift bridge helpers
//

import XCTest
@testable import RepoPrompt

final class MemoryAllocationBridgeTests: XCTestCase {

    // MARK: - String Extensions Wrapper Memory Tests
    
    func testStringExtensionsMemoryAllocations() throws {
        // Test functions that allocate memory internally
        let testString = "Hello, world! This is a test string with special chars: <>&\""
        
        // Test multiple cycles to catch memory leaks
        for _ in 0..<100 {
            // Functions that return dynamically allocated strings
            _ = testString.decodingHTMLEntities()
            _ = testString.condensingWhitespace()
            _ = testString.escapedString()
            _ = testString.unescaped()
            _ = String.canonicalKey(testString)
            
            // Functions with indentation encoding/decoding
            let indentedString = "    \(testString)"
            _ = String.encodeIndentationAsSpaces(indentedString)
            _ = String.encodeIndentationAsTabs(indentedString)
            _ = String.decodeIndentation("<s4>\(testString)")
            _ = String.decodeIndentation("<t2>\(testString)")
            
            // LCS which allocates result string
            _ = testString.longestCommonSubsequence(with: "Hello, world!")
        }
    }
    
    func testStringExtensionsLargeInputMemory() throws {
        // Test with large inputs to stress memory allocation
        let largeString = String(repeating: "test ", count: 10000)
        let veryLargeString = String(repeating: "a", count: 100000)
        
        // Should handle large inputs without memory issues
        _ = largeString.condensingWhitespace()
        _ = veryLargeString.similarityFast(to: largeString)
        _ = String.canonicalKey(largeString)
        
        // Test with very deep indentation
        let deepIndent = String(repeating: " ", count: 1000) + "content"
        _ = String.encodeIndentationAsSpaces(deepIndent)
        
        // Decode large indentation
        _ = String.decodeIndentation("<s1000>content")
        _ = String.decodeIndentation("<t500>content")
    }
    
    func testStringExtensionsEdgeCaseMemory() throws {
        // Test edge cases that might cause memory issues
        let edgeCases = [
            "",
            "a",
            String(repeating: "\\", count: 100),
            String(repeating: "&lt;", count: 50),
            String(repeating: " \t\n", count: 100),
            "test\0null\0chars",
            "🎉🎊😀 Unicode test 你好世界",
        ]
        
        for testCase in edgeCases {
            // All these functions should handle edge cases gracefully
            _ = testCase.decodingHTMLEntities()
            _ = testCase.condensingWhitespace()
            _ = testCase.escapedString()
            _ = testCase.unescaped()
            _ = String.canonicalKey(testCase)
            _ = testCase.longestCommonSubsequence(with: "test")
        }
    }
    
    func testSplitContentMemoryAllocations() throws {
        // Test split content functions that allocate arrays
        let contentVariations = [
            "line1\nline2\nline3",
            "line1\r\nline2\r\nline3",
            "line1\rline2\rline3",
            "mixed\nlines\r\nand\rendings",
            String(repeating: "line\n", count: 1000),
            "", // Empty content
            "single line",
            "\n\n\n\n", // Only line endings
        ]
        
        for content in contentVariations {
            let (lines, ending) = String.splitContentPreservingLineEndings(content)
            
            // Verify we got reasonable results
            XCTAssertNotNil(lines)
            XCTAssertNotNil(ending)
            
            // Lines should be valid strings
            for line in lines {
                XCTAssertNotNil(line)
            }
        }
    }
    
    // MARK: - Search Scoring Memory Tests
    
    func testSearchScoringBatchBufferMemory() throws {
        // Test batch buffer creation and cleanup
        let fileCount = 1000
        let names = (0..<fileCount).map { "file\($0).swift" }
        let paths = (0..<fileCount).map { "src/folder\($0)/file\($0).swift" }
        let namesLower = names.map { $0.lowercased() }
        let pathsLower = paths.map { $0.lowercased() }
        
        // Test multiple batch operations to stress memory management
        for iteration in 0..<10 {
            let query = "file\(iteration)"
            
            // Create file info structs (these use strdup internally in C)
            let namesCStrings = names.map { strdup($0) }
            let pathsCStrings = paths.map { strdup($0) }
            let namesLowerCStrings = namesLower.map { strdup($0) }
            let pathsLowerCStrings = pathsLower.map { strdup($0) }
            
            defer {
                // Clean up allocated memory
                namesCStrings.forEach { free($0) }
                pathsCStrings.forEach { free($0) }
                namesLowerCStrings.forEach { free($0) }
                pathsLowerCStrings.forEach { free($0) }
            }
            
            let files = zip(zip(namesCStrings, pathsCStrings), zip(namesLowerCStrings, pathsLowerCStrings)).map { names, lowers in
                repo_file_info(name: names.0, path: names.1, name_lower: lowers.0, path_lower: lowers.1)
            }
            var scores = [Int32](repeating: 0, count: fileCount)
            
            let queryLower = query.lowercased()
            files.withUnsafeBufferPointer { filesPtr in
                scores.withUnsafeMutableBufferPointer { scoresPtr in
                    query.withCString { queryPtr in
                        queryLower.withCString { queryLowerPtr in
                            repo_score_matches_batch(filesPtr.baseAddress, files.count,
                                                   queryPtr, queryLowerPtr, false, false, 0.85,
                                                   scoresPtr.baseAddress)
                        }
                    }
                }
            }
            
            // Verify we got reasonable scores
            XCTAssertTrue(scores.allSatisfy { $0 >= 0 && $0 <= 1000 })
        }
    }
    
    func testSearchScoringEdgeCaseMemory() throws {
        // Test edge cases that might cause memory issues
        let edgeCaseNames = [
            "",
            "a",
            String(repeating: "x", count: 1000),
            "file-with-dashes.swift",
            "file_with_underscores.c",
            "CamelCaseFileName.java",
            "file with spaces.txt",
            "file\0with\0nulls.bin",
            "🎉emoji🎊file.js",
        ]
        
        let edgeCasePaths = edgeCaseNames.map { "src/\($0)" }
        
        let namesCStrings = edgeCaseNames.map { strdup($0) }
        let pathsCStrings = edgeCasePaths.map { strdup($0) }
        let namesLowerCStrings = edgeCaseNames.map { strdup($0.lowercased()) }
        let pathsLowerCStrings = edgeCasePaths.map { strdup($0.lowercased()) }
        
        defer {
            namesCStrings.forEach { free($0) }
            pathsCStrings.forEach { free($0) }
            namesLowerCStrings.forEach { free($0) }
            pathsLowerCStrings.forEach { free($0) }
        }
        
        let files = zip(zip(namesCStrings, pathsCStrings), zip(namesLowerCStrings, pathsLowerCStrings)).map { names, lowers in
            repo_file_info(name: names.0, path: names.1, name_lower: lowers.0, path_lower: lowers.1)
        }
        var scores = [Int32](repeating: 0, count: files.count)
        
        let queries = ["test", "", "x", "very_long_query_string", "🎉", "\0"]
        
        for query in queries {
            let queryLower = query.lowercased()
            files.withUnsafeBufferPointer { filesPtr in
                scores.withUnsafeMutableBufferPointer { scoresPtr in
                    query.withCString { queryPtr in
                        queryLower.withCString { queryLowerPtr in
                            repo_score_matches_batch(filesPtr.baseAddress, files.count,
                                                   queryPtr, queryLowerPtr, false, false, 0.85,
                                                   scoresPtr.baseAddress)
                        }
                    }
                }
            }
            
            // Should handle all edge cases without crashing
            XCTAssertEqual(scores.count, files.count)
        }
    }
    
    // MARK: - Wildmatch Wrapper Memory Tests
    
    func testWildmatchPatternMemory() throws {
        // Test wildcard pattern matching which may allocate internal buffers
        let patterns = [
            "*.swift",
            "**/test/**",
            "src/**/*.c",
            "file?.txt",
            "very_long_" + String(repeating: "pattern_", count: 100) + "*.ext",
            "",
            "*",
            "**",
            "pattern_with_unicode_🎉*.swift",
        ]
        
        let testPaths = [
            "test.swift",
            "src/test/file.c",
            "deep/nested/path/file.txt",
            "file1.txt",
            String(repeating: "long_", count: 50) + "path.ext",
            "",
            "unicode_🎉_file.swift",
        ]
        
        // Test all pattern/path combinations
        for pattern in patterns {
            for path in testPaths {
                // These should not crash or leak memory
                pattern.withCString { patternPtr in
                    path.withCString { pathPtr in
                        _ = repo_gitignore_match_anchored(patternPtr, pathPtr)
                        _ = repo_gitignore_match_anywhere(patternPtr, pathPtr)
                    }
                }
            }
        }
    }
    
    // MARK: - Chat Content Parser Memory Tests
    
    func testChatContentParserMemory() throws {
        // Test chat content parsing which has complex memory structures
        let testContents = [
            """
            <file path="test.swift" action="create">
            func hello() {
                print("Hello, World!")
            }
            </file>
            """,
            """
            <file path="complex.c" action="edit">
            <change>
            <description>Add main function</description>
            int main() { return 0; }
            </change>
            </file>
            """,
            """
            Multiple files and changes:
            <file path="file1.swift">
            content1
            </file>
            <file path="file2.c">
            content2
            </file>
            """,
            String(repeating: "<file path=\"test\">content</file>\n", count: 100),
            "", // Empty content
            "No special tags here",
            // Unicode content
            """
            <file path="unicode.swift">
            let greeting = "你好世界 🌍"
            </file>
            """,
        ]
        
        for content in testContents {
            // Test parsing with different configurations
            content.withCString { contentPtr in
                // Test with no processed hashes
                if let result = repo_parse_content(contentPtr, nil, 0, true, false) {
                    // Verify the result structure
                    XCTAssertNotNil(result.pointee.items)
                    XCTAssertGreaterThanOrEqual(result.pointee.item_count, 0)
                    
                    // Clean up the result
                    repo_free_parse_result(result)
                }
                
                // Test with some processed hashes
                var hashes: [Int64] = [12345, 67890]
                let hashCount = hashes.count
                hashes.withUnsafeMutableBufferPointer { hashesPtr in
                    if let result = repo_parse_content(contentPtr, hashesPtr.baseAddress, hashCount, false, true) {
                        // Clean up
                        repo_free_parse_result(result)
                    }
                }
            }
        }
    }
    
    func testChatContentParserUtilities() throws {
        // Test utility functions that allocate memory
        let testInputs = [
            "<![CDATA[some content]]>",
            "<description>Test description</description>",
            "<complexity>5</complexity>",
            "```swift\nlet x = 1\n```",
            "    indented content",
            "mixed\ncontent\nlines",
            "",
            String(repeating: "large input ", count: 1000),
        ]
        
        for input in testInputs {
            input.withCString { inputPtr in
                // Test CDATA stripping
                if let stripped = repo_strip_cdata(inputPtr) {
                    XCTAssertNotNil(stripped)
                    free(stripped)
                }
                
                // Test content extraction
                if let extracted = repo_extract_content(inputPtr, "description", true) {
                    XCTAssertNotNil(extracted)
                    free(extracted)
                }
                
                // Test line splitting
                var lines: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                var count: Int = 0
                if let ending = repo_split_content_to_lines(inputPtr, true, &lines, &count) {
                    XCTAssertNotNil(ending)
                    
                    // Clean up lines
                    if let linesPtr = lines {
                        for i in 0..<count {
                            free(linesPtr[i])
                        }
                        free(linesPtr)
                    }
                    free(ending)
                }
                
                // Test indentation decoding
                if let decoded = repo_decode_indentation_in_code_block(inputPtr) {
                    XCTAssertNotNil(decoded)
                    free(decoded)
                }
            }
        }
    }
    
    // MARK: - Stress Tests
    
    func testMemoryStressAllBridges() throws {
        // Stress test all bridge functions simultaneously
        let iterations = 50
        let concurrentQueues = 4
        let group = DispatchGroup()
        
        for queueIndex in 0..<concurrentQueues {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                
                for iteration in 0..<iterations {
                    let testString = "Stress test \(queueIndex)-\(iteration) with special chars: <>&\""
                    
                    // String extensions
                    _ = testString.decodingHTMLEntities()
                    _ = testString.condensingWhitespace()
                    _ = testString.escapedString()
                    _ = String.canonicalKey(testString)
                    _ = testString.longestCommonSubsequence(with: "test")
                    
                    // Split content
                    let content = "line1\nline2\rline3\r\n"
                    let (lines, ending) = String.splitContentPreservingLineEndings(content)
                    XCTAssertNotNil(lines)
                    XCTAssertNotNil(ending)
                    
                    // Search scoring
                    let fileName = "test\(iteration).swift"
                    let filePath = "src/test\(iteration).swift"
                    let query = "test"
                    
                    fileName.withCString { namePtr in
                        filePath.withCString { pathPtr in
                            query.withCString { queryPtr in
                                _ = repo_score_match(namePtr, pathPtr, namePtr, pathPtr,
                                                   queryPtr, queryPtr, false, false, 0.85)
                            }
                        }
                    }
                    
                    // Wildmatch
                    let pattern = "*.swift"
                    pattern.withCString { patternPtr in
                        filePath.withCString { pathPtr in
                            _ = repo_gitignore_match_anchored(patternPtr, pathPtr)
                        }
                    }
                }
            }
        }
        
        let result = group.wait(timeout: .now() + 30)
        XCTAssertEqual(result, .success, "Stress test should complete within 30 seconds")
    }
    
    func testMemoryLeakDetection() throws {
        // This test helps detect memory leaks by performing many allocations
        let baseMemory = getMemoryUsage()
        let iterations = 1000
        
        // Perform many operations that allocate memory
        for i in 0..<iterations {
            let testString = "Memory leak test iteration \(i)"
            
            // String operations that allocate
            autoreleasepool {
                _ = testString.decodingHTMLEntities()
                _ = testString.condensingWhitespace()
                _ = testString.escapedString()
                _ = String.canonicalKey(testString + " with more content to make it longer")
                _ = testString.longestCommonSubsequence(with: "test iteration")
            }
            
            // Split operations
            let content = "line1\(i)\nline2\(i)\nline3\(i)"
            autoreleasepool {
                let (_, _) = String.splitContentPreservingLineEndings(content)
            }
            
            // Search operations with C strings
            let fileName = "file\(i).swift"
            let query = "file"
            autoreleasepool {
                fileName.withCString { namePtr in
                    fileName.withCString { pathPtr in
                        query.withCString { queryPtr in
                            _ = repo_score_match(namePtr, pathPtr, namePtr, pathPtr,
                                               queryPtr, queryPtr, false, false, 0.85)
                        }
                    }
                }
            }
        }
        
        // Force garbage collection
        autoreleasepool {}
        
        let finalMemory = getMemoryUsage()
        let memoryGrowth = finalMemory - baseMemory
        
        // Memory growth should be reasonable (less than 10MB for this test)
        XCTAssertLessThan(memoryGrowth, 10_000_000, 
                         "Memory growth (\(memoryGrowth) bytes) suggests potential leaks")
    }
    
    // MARK: - Helper Functions
    
    private func getMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
    
    // MARK: - Buffer Overflow Protection Tests
    
    func testBufferOverflowProtection() throws {
        // Test functions with potential buffer overflow issues
        
        // Test very long inputs that might cause buffer overflows
        let veryLongString = String(repeating: "x", count: 10000)
        let maliciousPattern = String(repeating: "*", count: 1000)
        
        // These should not crash or cause buffer overflows
        _ = String.canonicalKey(veryLongString)
        _ = veryLongString.escapedString()
        _ = veryLongString.condensingWhitespace()
        
        // Test indentation with extreme values
        let extremeIndent = "<s\(Int.max)>content"
        _ = String.decodeIndentation(extremeIndent) // Should handle gracefully
        
        let extremeNegativeIndent = "<s-1000>content"
        _ = String.decodeIndentation(extremeNegativeIndent) // Should handle gracefully
        
        // Test wildcard patterns with extreme nesting
        maliciousPattern.withCString { patternPtr in
            veryLongString.withCString { pathPtr in
                _ = repo_gitignore_match_anchored(patternPtr, pathPtr)
                _ = repo_gitignore_match_anywhere(patternPtr, pathPtr)
            }
        }
    }
    
    func testNullPointerSafety() throws {
        // Test that C function calls handle null pointers gracefully
        
        // These should not crash when passed null/empty pointers
        XCTAssertEqual(repo_score_match(nil, nil, nil, nil, nil, nil, false, false, 0.85), 0)
        
        "test".withCString { testPtr in
            XCTAssertEqual(repo_score_match(testPtr, nil, testPtr, nil, testPtr, testPtr, false, false, 0.85), 0)
            XCTAssertEqual(repo_score_match(nil, testPtr, nil, testPtr, testPtr, testPtr, false, false, 0.85), 0)
        }
        
        // Wildmatch with nulls - WM_NOMATCH = 1
        XCTAssertEqual(repo_gitignore_match_anchored(nil, nil), 1)
        
        "test".withCString { testPtr in
            XCTAssertEqual(repo_gitignore_match_anchored(testPtr, nil), 1)
            XCTAssertEqual(repo_gitignore_match_anchored(nil, testPtr), 1)
        }
        
        // Parse content with null
        XCTAssertNil(repo_parse_content(nil, nil, 0, true, false))
        
        // String utilities with null
        XCTAssertNil(repo_strip_cdata(nil))
        XCTAssertNil(repo_extract_content(nil, "test", true))
    }
    
    // MARK: - Performance Under Memory Pressure
    
    func testPerformanceUnderMemoryPressure() throws {
        // Simulate memory pressure and ensure functions still work correctly
        
        measure {
            // Create many large allocations to simulate memory pressure
            var largeAllocations: [String] = []
            
            for i in 0..<100 {
                let largeString = String(repeating: "Large allocation \(i) ", count: 1000)
                largeAllocations.append(largeString)
                
                // Perform bridge operations under memory pressure  
                _ = largeString.decodingHTMLEntities()
                _ = largeString.condensingWhitespace()
                _ = String.canonicalKey(largeString)
                
                let (lines, ending) = String.splitContentPreservingLineEndings(largeString + "\n")
                XCTAssertNotNil(lines)
                XCTAssertNotNil(ending)
            }
            
            // Clean up
            largeAllocations.removeAll()
        }
    }
}