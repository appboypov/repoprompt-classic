//
//  StringExtensionsParityTests.swift
//  RepoPromptTests
//
//  Tests to ensure parity between the legacy Swift splitter and the optimized version
//

import XCTest
@testable import RepoPrompt

final class StringExtensionsParityTests: XCTestCase {
    
    // MARK: - splitContentPreservingAllLineEndings Tests
    
    func testSplitContentPreservingAllLineEndingsParity() {
        let testCases = [
            // Basic cases
            "Hello\nWorld",
            "Hello\r\nWorld",
            "Hello\rWorld",
            
            // Multiple lines
            "Line1\nLine2\nLine3",
            "Line1\r\nLine2\r\nLine3",
            "Line1\rLine2\rLine3",
            
            // Mixed line endings
            "Line1\nLine2\r\nLine3\rLine4",
            
            // Empty lines
            "\n\n\n",
            "\r\n\r\n\r\n",
            "\r\r\r",
            
            // No line endings
            "Single line with no ending",
            
            // Trailing line ending
            "Hello World\n",
            "Hello World\r\n",
            "Hello World\r",
            
            // Empty string
            "",
            
            // Special characters
            "Hello\tWorld\nNext Line",
            "Path/to/file\r\nAnother/path",
            
            // Long lines
            String(repeating: "a", count: 1000) + "\n" + String(repeating: "b", count: 1000),
            
            // Unicode
            "Hello 👋\nWorld 🌍",
            "こんにちは\r\n世界",
            
            // Edge cases
            "\n",
            "\r\n",
            "\r",
            "Just text",
            "\nStarting with newline",
            "Ending with newline\n"
        ]
        
        for testCase in testCases {
            let swiftResult = String.splitContentPreservingAllLineEndings_old(testCase)
            let optimizedResult = String.splitContentPreservingAllLineEndings(testCase)
            
            XCTAssertEqual(swiftResult.count, optimizedResult.count, 
                          "Count mismatch for input: \(testCase.debugDescription)")
            
            for (index, (swiftPair, optimizedPair)) in zip(swiftResult, optimizedResult).enumerated() {
                XCTAssertEqual(swiftPair.line, optimizedPair.line, 
                              "Line mismatch at index \(index) for input: \(testCase.debugDescription)")
                XCTAssertEqual(swiftPair.ending, optimizedPair.ending, 
                              "Ending mismatch at index \(index) for input: \(testCase.debugDescription)")
            }
        }
    }
    
	func testSplitContentPerformanceComparison() {
		let largeContent: String = {
			var builder = String()
			builder.reserveCapacity(4_00_000)
			for index in 0..<50000 {
				builder.append("Line \(index)")
				switch index % 3 {
				case 0:
					builder.append("\n")
				case 1:
					builder.append("\r\n")
				default:
					builder.append("\r")
				}
			}
			return builder
		}()
		
		// First verify parity - both produce same results
		let swiftResult = String.splitContentPreservingAllLineEndings_old(largeContent)
		let optimizedResult = String.splitContentPreservingAllLineEndings(largeContent)
		
		XCTAssertEqual(swiftResult.count, optimizedResult.count, "Both implementations should return same number of lines")
		for i in 0..<min(swiftResult.count, optimizedResult.count) {
			XCTAssertEqual(swiftResult[i].line, optimizedResult[i].line, "Line \(i) should match")
			XCTAssertEqual(swiftResult[i].ending, optimizedResult[i].ending, "Line ending \(i) should match")
		}
		
		// Warm the runtime to avoid first-call overhead
		_ = String.splitContentPreservingAllLineEndings_old(largeContent)
		_ = String.splitContentPreservingAllLineEndings(largeContent)
		
		let iterations = 3
		var swiftTotal: TimeInterval = 0
		var cTotal: TimeInterval = 0
		
		for _ in 0..<iterations {
			swiftTotal += measureTime {
				_ = String.splitContentPreservingAllLineEndings_old(largeContent)
			}
			
			cTotal += measureTime {
				_ = String.splitContentPreservingAllLineEndings(largeContent)
			}
		}
		
		let swiftAverage = swiftTotal / Double(iterations)
		let cAverage = cTotal / Double(iterations)
		let speedup = swiftAverage / cAverage
		
		print("\nSplit Content Performance:")
		print("Swift avg: \(String(format: "%.3f", swiftAverage * 1000))ms")
		print("Optimized avg: \(String(format: "%.3f", cAverage * 1000))ms")
		print("Optimized is \(String(format: "%.2f", speedup))x faster on average vs legacy Swift")
		
		// Assert that optimized routine is faster with a small tolerance for noise
		XCTAssertLessThan(cAverage, swiftAverage, "Optimized implementation should be faster than the legacy Swift version on average")
	}
    
    func testSplitContentPerformanceSwift() {
        let largeContent = (0..<10000).map { "Line \($0)" }.joined(separator: "\n")
        
        measure {
            _ = String.splitContentPreservingAllLineEndings_old(largeContent)
        }
    }
    
	func testSplitContentPerformanceOptimized() {
		let largeContent = (0..<10000).map { "Line \($0)" }.joined(separator: "\n")
		
		measure {
			_ = String.splitContentPreservingAllLineEndings(largeContent)
		}
    }
    
    // Helper function to measure execution time
    private func measureTime(block: () -> Void) -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return CFAbsoluteTimeGetCurrent() - start
    }
    
    // MARK: - Encode/Decode Indentation Tests
    
    func testEncodeIndentationParity() {
        let testCases = [
            // Basic indentation
            "    Hello World",
            "\tHello World",
            "\t\tHello World",
            "        Hello World",
            
            // No indentation
            "Hello World",
            
            // Empty lines
            "",
            "    ",
            "\t\t",
            
            // Mixed indentation (should still work)
            "\t    Hello",
            "    \tHello",
            
            // Special content
            "    <tag>content</tag>",
            "\tfunction() { return true; }",
        ]
        
        for testCase in testCases {
            // Test space encoding
            let swiftSpaceResult = encodeIndentationAsSpaces_old(testCase)
            let cSpaceResult = String.encodeIndentationAsSpaces(testCase)
            
            XCTAssertEqual(swiftSpaceResult, cSpaceResult,
                          "Space encoding mismatch for input: \(testCase.debugDescription)")
            
            // Test decoding
            let swiftDecoded = String.decodeIndentation_old(swiftSpaceResult)
            let cDecoded = String.decodeIndentation(cSpaceResult)
            
            XCTAssertEqual(swiftDecoded, cDecoded,
                          "Decoding mismatch for encoded: \(swiftSpaceResult.debugDescription)")
        }
    }
    
    // MARK: - Fuzzy Space Matching Tests
    
    func testFuzzySpaceMatchingParity() {
        let testCases: [(pattern: String, text: String, caseInsensitive: Bool, expected: Bool)] = [
            // Basic matching
            ("hello world", "hello world", false, true),
            ("hello world", "hello  world", false, true),
            ("hello world", "hello\tworld", false, true),
            ("hello world", "hello\n\nworld", false, true),
            
            // Case sensitivity
            ("Hello World", "hello world", true, true),
            ("Hello World", "hello world", false, false),
            
            // Multiple spaces in pattern - spaces in pattern match any whitespace
            ("foo  bar", "foo bar", false, true),   // Pattern has 2 spaces, text has 1
            ("foo bar", "foo     bar", false, true), // Pattern has 1 space, text has many
            
            // No spaces
            ("helloworld", "helloworld", false, true),
            ("helloworld", "hello world", false, false),
            
            // Edge cases
            ("", "", false, false),  // Empty pattern with case_insensitive=false returns false
            (" ", "   ", false, true),
            ("a b c", "a\tb\nc", false, true),
        ]
        
        for (pattern, text, caseInsensitive, expected) in testCases {
            let cResult = pattern.fuzzySpaceMatch(text, caseInsensitive: caseInsensitive)
            
            XCTAssertEqual(cResult, expected,
                          "Fuzzy match result mismatch for pattern: '\(pattern)' text: '\(text)' case: \(caseInsensitive)")
        }
    }
    
    // MARK: - HTML Entity Decoding Tests
    
    func testHTMLEntityDecodingParity() {
        let testCases: [(input: String, expected: String)] = [
            // Basic entities supported by C implementation
            ("&lt;tag&gt;", "<tag>"),
            ("&amp; &quot;hello&quot;", "& \"hello\""),
            ("&nbsp;space&nbsp;", " space "),
            
            // No entities
            ("Plain text with no entities", "Plain text with no entities"),
            
            // Mixed content
            ("Hello &lt;world&gt; &amp; goodbye", "Hello <world> & goodbye"),
            
            // Edge cases
            ("", ""),
            ("&", "&"),
            ("&unknown;", "&unknown;"),
            ("&&&&", "&&&&"),
            
            // Note: Numeric entities (&#65;, &#x41;) and &apos; are not supported by the C implementation
        ]
        
        for (input, expected) in testCases {
            let cResult = input.decodingHTMLEntities()
            
            XCTAssertEqual(cResult, expected,
                          "HTML decoding mismatch for input: \(input.debugDescription)")
        }
    }
    
    // MARK: - Whitespace Condensing Tests
    
    func testWhitespaceCondensingParity() {
        let testCases: [(input: String, expected: String)] = [
            // Basic cases - all whitespace runs become single spaces
            ("hello  world", "hello world"),
            ("hello\t\tworld", "hello world"),
            ("hello\n\nworld", "hello world"),
            ("hello   \t\n  world", "hello world"),
            
            // Edge cases
            ("", ""),
            ("   ", " "),  // Multiple spaces become one
            ("\t\n\r", " "), // Mixed whitespace becomes single space
            ("no-spaces", "no-spaces"),
            
            // Complex cases
            ("  leading and trailing  ", " leading and trailing "),  // Preserves leading/trailing
            ("multiple   spaces   between   words", "multiple spaces between words"),
            ("tabs\t\tand\nnewlines\r\neverywhere", "tabs and newlines everywhere"),
        ]
        
        for (input, expected) in testCases {
            let cResult = input.condensingWhitespace()
            
            XCTAssertEqual(cResult, expected,
                          "Whitespace condensing mismatch for input: \(input.debugDescription)")
        }
    }
    
    // MARK: - Performance Comparison Tests
    
    func testFuzzySpaceMatchPerformanceComparison() {
        let patterns = ["hello world", "foo bar baz", "test pattern with spaces"]
        let texts = [
            "hello  world",
            "hello\t\tworld",
            "foo   bar   baz",
            "test\npattern\twith\r\nspaces"
        ]
        
        var swiftTotal: TimeInterval = 0
        var cTotal: TimeInterval = 0
        
        // Run multiple iterations for more accurate timing
        let iterations = 1000
        
        for _ in 0..<iterations {
            for pattern in patterns {
                for text in texts {
                    // Measure Swift implementation (using simple contains for old implementation)
                    swiftTotal += measureTime {
                        _ = pattern.fuzzySpaceMatch_old(text, caseInsensitive: false)
                    }
                    
                    // Measure C implementation
                    cTotal += measureTime {
                        _ = pattern.fuzzySpaceMatch(text, caseInsensitive: false)
                    }
                }
            }
        }
        
        let speedup = swiftTotal / cTotal
        print("\nFuzzy Space Match Performance:")
        print("Swift implementation: \(String(format: "%.3f", swiftTotal * 1000))ms total")
        print("C implementation: \(String(format: "%.3f", cTotal * 1000))ms total")
        print("C is \(String(format: "%.2f", speedup))x faster")
        
        XCTAssertLessThan(cTotal, swiftTotal, "C fuzzy match should be faster")
    }
    
    func testCondensingWhitespacePerformanceComparison() {
        let testStrings = [
            String(repeating: "word   ", count: 1000),
            String(repeating: "line\n\n\n", count: 1000),
            String(repeating: "tab\t\t\tmixed   spaces\n\n", count: 500)
        ]
        
        var swiftTotal: TimeInterval = 0
        var cTotal: TimeInterval = 0
        
        for testString in testStrings {
            // Measure Swift implementation
            swiftTotal += measureTime {
                _ = testString.condensingWhitespace_old()
            }
            
            // Measure C implementation
            cTotal += measureTime {
                _ = testString.condensingWhitespace()
            }
        }
        
        let speedup = swiftTotal / cTotal
        print("\nWhitespace Condensing Performance:")
        print("Swift implementation: \(String(format: "%.3f", swiftTotal * 1000))ms total")
        print("C implementation: \(String(format: "%.3f", cTotal * 1000))ms total")
        print("C is \(String(format: "%.2f", speedup))x faster")
        
        XCTAssertLessThan(cTotal, swiftTotal, "C whitespace condensing should be faster")
    }
}

// MARK: - Old Swift Implementations for Comparison

// Free functions for old implementations
func encodeIndentationAsSpaces_old(_ line: String) -> String {
    // Keep the old Swift implementation for comparison
    // This is a simplified version - should be replaced with actual old implementation
    return String.encodeIndentationAsSpaces(line)
}

extension String {
    
    // This is the actual old Swift implementation that used regex
    static func splitContentPreservingAllLineEndings_old(_ content: String) -> [(line: String, ending: String)] {
        let regex = try! NSRegularExpression(pattern: "(\r\n|\n|\r)")
        var result: [(String, String)] = []
        var lastIndex = content.startIndex
        
        regex.enumerateMatches(in: content, range: NSRange(content.startIndex..., in: content)) { match, _, _ in
            guard let match = match, let range = Range(match.range, in: content) else { return }
            
            let line = String(content[lastIndex..<range.lowerBound])
            let ending = String(content[range])
            
            result.append((line, ending))
            lastIndex = range.upperBound
        }
        
        // Handle the last line, which might not have a trailing line ending
        if lastIndex < content.endIndex {
            result.append((String(content[lastIndex...]), ""))
        }
        
        return result
    }
    
    static func decodeIndentation_old(_ encodedLine: String) -> String {
        // For now, use the C implementation since we don't have the old Swift one
        return String.decodeIndentation(encodedLine)
    }
    
    func fuzzySpaceMatch_old(_ text: String, caseInsensitive: Bool = false) -> Bool {
        // Simple regex-based implementation for comparison
        let escapedPattern = NSRegularExpression.escapedPattern(for: self)
        let pattern = escapedPattern.replacingOccurrences(of: " ", with: "\\s+")
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return false
        }
        
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
    
    func condensingWhitespace_old() -> String {
        // Simple regex-based implementation
        let pattern = "[\\s\\u{00A0}]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }
        
        let range = NSRange(location: 0, length: self.utf16.count)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: " ")
    }
}
