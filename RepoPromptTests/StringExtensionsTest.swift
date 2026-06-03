//
//  StringExtensionsTests.swift
//  RepoPromptTests
//
//  Created by Eric Provencher on 2024-07-25.
//

import XCTest
@testable import RepoPrompt

final class StringExtensionsTests: XCTestCase {
	
	func testSimilarityExactMatch() throws {
		let str1 = "Hello World"
		let str2 = "Hello World"
		XCTAssertEqual(str1.similarity(to: str2), 1.0, "Identical strings should have 1.0 similarity.")
	}
	
	func testSimilarityPartial() throws {
		let str1 = "Hello"
		let str2 = "Hella"
		let similarityScore = str1.similarity(to: str2)
		XCTAssertTrue(similarityScore > 0.7 && similarityScore < 1.0, "Expected partial similarity between 'Hello' and 'Hella'.")
	}
	
	func testIsSimilarWithThreshold() throws {
		let str1 = "   Hello "
		let str2 = "hello"
		XCTAssertTrue(str1.isSimilar(to: str2, threshold: 0.8), "Trimming & case differences should still be considered similar above threshold.")
		
		let str3 = "   Helloz "
		XCTAssertFalse(str1.isSimilar(to: str3, threshold: 0.9), "Extra difference should fail at 0.9 threshold.")
	}
	
	func testLevenshteinDistance() throws {
		let str1 = "kitten"
		let str2 = "sitting"
		let distance = str1.levenshteinDistance(to: str2)
		XCTAssertEqual(distance, 3, "Classic example: kitten -> sitting = distance of 3")
	}
	
	func testLongestCommonSubsequence() throws {
		let str1 = "abcdef"
		let str2 = "axbdf"
		let lcs = str1.longestCommonSubsequence(with: str2)
		XCTAssertEqual(lcs, "abdf", "Longest common subsequence should be 'abdf'.")
	}
	
	func testSplitIntoLines() throws {
		let sample = " line1\n  line2\n\tline3"
		let lines = sample.splitIntoLines(usesSpaces: true, indentSize: 4)
		
		XCTAssertEqual(lines.count, 3)
		XCTAssertTrue(lines[0].starts(with: "<s1>"), "line1 has 1 leading space so <s1>")
		XCTAssertTrue(lines[1].starts(with: "<s2>"), "line2 has 2 leading spaces so <s2>")
		XCTAssertTrue(lines[2].starts(with: "<s4>"), "line3 has 1 tab, which becomes 4 spaces => <s4>")
	}
	
	func testEncodeDecodeIndentation() throws {
		let original = "<s4>some text"
		let decoded = String.decodeIndentation(original)
		XCTAssertEqual(decoded, "    some text")
		
		let reencoded = String.encodeIndentationAsSpaces(decoded)
		XCTAssertEqual(reencoded, original, "Encoding + Decoding should round-trip to the same representation.")
	}
	
	func testRangesOfSubstring() throws {
		let sample = "Hello Hello Hello"
		let occurrences = sample.ranges(of: "Hello")
		XCTAssertEqual(occurrences.count, 3, "Should find 3 occurrences of 'Hello'.")
	}
	
	func testEscapedString() throws {
		let sample = "He said \"Hello\".\nNewLine"
		let escaped = sample.escapedString()
		let expected = "He said \\\"Hello\\\".\\nNewLine"
		XCTAssertEqual(escaped, expected, "Escaped form should replace quotes and newlines.")
		
		let unescaped = escaped.unescaped()
		XCTAssertEqual(unescaped, sample, "Unescape should return to original string.")
	}
	
	// MARK: – Dice Coefficient ----------------------------------------------------
	
	func testDiceCoefficientIdentical() throws {
		let str1 = "Swift Package"
		let str2 = "Swift Package"
		let score = str1.diceCoefficient(against: str2)
		XCTAssertEqual(score, 1.0, accuracy: 0.0001,
						"Identical strings should have a dice coefficient of 1.0")
	}
	
	func testDiceCoefficientPartial() throws {
		let str1 = "Foundation"
		let str2 = "Foundational"
		let score = str1.diceCoefficient(against: str2)
		XCTAssertTrue(score > 0.6 && score < 1.0,
						"Expected high—but not perfect—similarity between close spellings.")
	}
	
	// MARK: - Optimized Levenshtein Distance Tests
	
	func testLevenshteinDistanceWithCap() throws {
		let str1 = "kitten"
		let str2 = "sitting"
		
		// Test with cap higher than actual distance
		let distance1 = str1.levenshteinDistance(to: str2, maxAllowedDistance: 5)
		XCTAssertEqual(distance1, 3, "Should return exact distance when under cap")
		
		// Test with cap lower than actual distance
		let distance2 = str1.levenshteinDistance(to: str2, maxAllowedDistance: 2)
		XCTAssertEqual(distance2, 3, "Should return cap + 1 (3) when actual distance (3) exceeds cap (2)")
	}
	
	func testLevenshteinDistancePathOptimization() throws {
		// Test common prefix optimization
		let path1 = "/Users/john/Documents/project/src/main.swift"
		let path2 = "/Users/john/Documents/project/src/test.swift"
		let distance = path1.levenshteinDistance(to: path2)
		XCTAssertEqual(distance, 4, "Should efficiently handle common prefixes")
		
		// Test common suffix optimization
		let file1 = "ComponentA.swift"
		let file2 = "ComponentB.swift"
		let dist2 = file1.levenshteinDistance(to: file2)
		XCTAssertEqual(dist2, 1, "Should efficiently handle common suffixes")
	}
	
	func testLevenshteinDistanceEdgeCases() throws {
		// Empty strings
		XCTAssertEqual("".levenshteinDistance(to: "hello"), 5)
		XCTAssertEqual("hello".levenshteinDistance(to: ""), 5)
		XCTAssertEqual("".levenshteinDistance(to: ""), 0)
		
		// Identical strings
		XCTAssertEqual("test".levenshteinDistance(to: "test"), 0)
		
		// Completely different strings
		XCTAssertEqual("abc".levenshteinDistance(to: "xyz"), 3)
	}
	
	func testLevenshteinDistanceUnicode() throws {
		// Test with Unicode characters
		let str1 = "café"
		let str2 = "cafe"
		let distance = str1.levenshteinDistance(to: str2)
		XCTAssertEqual(distance, 1, "Should handle Unicode characters correctly")
		
		// Test with emoji
		let emoji1 = "Hello 👋"
		let emoji2 = "Hello 🌍"
		let dist2 = emoji1.levenshteinDistance(to: emoji2)
		XCTAssertEqual(dist2, 1, "Should handle emoji correctly")
	}
	
	// MARK: - Fast Similarity Tests
	
	func testSimilarityFastShortStrings() throws {
		// Test short strings (should use Levenshtein)
		let str1 = "hello"
		let str2 = "hallo"
		let similarity = str1.similarityFast(to: str2)
		XCTAssertEqual(similarity, 0.8, accuracy: 0.01, "One character difference in 5-char string = 80% similarity")
		
		// Test identical short strings
		XCTAssertEqual("test".similarityFast(to: "test"), 1.0)
		
		// Test completely different short strings
		let sim2 = "abc".similarityFast(to: "xyz")
		XCTAssertTrue(sim2 < 0.85, "Completely different strings should have low similarity")
	}
	
	func testSimilarityFastLongStrings() throws {
		// Create long strings (>64 chars) to trigger Dice coefficient
		let longStr1 = String(repeating: "abc", count: 25) + "test" // 79 chars
		let longStr2 = String(repeating: "abc", count: 25) + "best" // 79 chars
		let similarity = longStr1.similarityFast(to: longStr2)
		XCTAssertTrue(similarity > 0.85, "Very similar long strings should have high similarity")
		
		// Test very different long strings
		let longStr3 = String(repeating: "xyz", count: 25) // 75 chars
		let longStr4 = String(repeating: "abc", count: 25) // 75 chars
		let sim2 = longStr3.similarityFast(to: longStr4)
		XCTAssertTrue(sim2 < 0.3, "Completely different long strings should have low similarity")
	}
	
	func testSimilarityFastPathComparisons() throws {
		// Test typical file path comparisons
		let path1 = "/Users/john/Documents/project/src/components/Button.swift"
		let path2 = "/Users/john/Documents/project/src/components/Label.swift"
		let similarity = path1.similarityFast(to: path2)
		XCTAssertTrue(similarity > 0.8, "Paths with same directory should be very similar")
		
		// Test paths with different depths
		let path3 = "src/main.swift"
		let path4 = "src/utils/helper.swift"
		let sim2 = path3.similarityFast(to: path4)
		XCTAssertTrue(sim2 > 0.4 && sim2 < 0.8, "Paths with different depths should have moderate similarity")
	}
	
	func testSimilarityFastThresholdBehavior() throws {
		// Test behavior around common thresholds
		let str1 = "ViewController"
		let str2 = "ViewControler" // One character missing
		let similarity = str1.similarityFast(to: str2)
		XCTAssertTrue(similarity > 0.9, "Should exceed 0.9 threshold for single character difference")
		
		// Test with multiple differences
		let str3 = "ViewController"
		let str4 = "ViewCntrlr" // Multiple characters missing
		let sim2 = str3.similarityFast(to: str4)
		XCTAssertTrue(sim2 < 0.9, "Should be below 0.9 threshold with multiple differences")
	}
	
	// MARK: - Dice Coefficient Fast Tests
	
	func testDiceCoefficientFastEdgeCases() throws {
		// Empty strings
		XCTAssertEqual("".diceCoefficient(against: "hello"), 0.0)
		XCTAssertEqual("hello".diceCoefficient(against: ""), 0.0)
		XCTAssertEqual("".diceCoefficient(against: ""), 0.0)
		
		// Single character strings
		XCTAssertEqual("a".diceCoefficient(against: "a"), 1.0)
		XCTAssertEqual("a".diceCoefficient(against: "b"), 0.0)
		
		// Two character strings (minimum for bigrams)
		XCTAssertEqual("ab".diceCoefficient(against: "ab"), 1.0)
		XCTAssertEqual("ab".diceCoefficient(against: "ba"), 0.0)
	}
	
	func testDiceCoefficientFastPerformance() throws {
		// Test with long strings to ensure performance
		let longStr1 = String(repeating: "abcdefghij", count: 100) // 1000 chars
		let longStr2 = String(repeating: "abcdefghik", count: 100) // Slightly different
		
		let startTime = CFAbsoluteTimeGetCurrent()
		let score = longStr1.diceCoefficient(against: longStr2)
		let elapsed = CFAbsoluteTimeGetCurrent() - startTime
		
		XCTAssertTrue(score > 0.8, "Very similar long strings should have high Dice coefficient")
		XCTAssertTrue(elapsed < 0.01, "Dice coefficient should be very fast even for long strings")
	}
	
	// MARK: - Integration Tests
	
	func testSimilarityConsistency() throws {
		// Ensure similarity() delegates to similarityFast()
		let testPairs = [
			("hello", "hallo"),
			("test", "test"),
			("abc", "xyz"),
			("/path/to/file.swift", "/path/to/file.swift"),
			("ViewController", "ViewControler")
		]
		
		for (str1, str2) in testPairs {
			let sim1 = str1.similarity(to: str2)
			let sim2 = str1.similarityFast(to: str2)
			XCTAssertEqual(sim1, sim2, accuracy: 0.0001, 
							"similarity() should return same result as similarityFast()")
		}
	}
	
	func testIsFuzzyMatch() throws {
		// Test case-insensitive substring matching
		XCTAssertTrue("ViewController".isFuzzyMatch(to: "controller", threshold: 0.5))
		XCTAssertTrue("MainViewController".isFuzzyMatch(to: "viewcontroller", threshold: 0.5))
		
		// Test with length difference > 6
		XCTAssertFalse("abc".isFuzzyMatch(to: "abcdefghijk", threshold: 0.9))
		
		// Test with high threshold
		XCTAssertTrue("hello".isFuzzyMatch(to: "hallo", threshold: 0.5))
		XCTAssertFalse("hello".isFuzzyMatch(to: "world", threshold: 0.65))
	}

}
