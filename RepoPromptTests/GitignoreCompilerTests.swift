import XCTest
@testable import RepoPrompt

final class GitignoreCompilerTests: XCTestCase {
	
	// MARK: - Test Helpers
	
	/// Helper to compile patterns and test matching
	private func compileAndMatch(_ patterns: [String], path: String, isDirectory: Bool = false) -> CompiledIgnoreRules.MatchOutcome {
		let content = patterns.joined(separator: "\n")
		let compiled = GitignoreCompiler.compile(content: content)
		let components = path.split(separator: "/")
		return compiled.outcome(for: components, isDirectory: isDirectory)
	}
	
	/// Helper to test if a path is ignored
	private func isIgnored(_ patterns: [String], path: String, isDirectory: Bool = false) -> Bool {
		return compileAndMatch(patterns, path: path, isDirectory: isDirectory) == .ignore
	}

	// MARK: - Pattern Pool Tests

	func testPatternPoolDoesNotExceedCapacity() {
		let pool = PatternPool.shared
		pool.resetForTesting()
		defer { pool.resetForTesting() }

		let capacity = pool.capacityForTesting
		for index in 0..<(capacity + 257) {
			_ = pool.intern("bounded-pattern-\(index)")
		}

		XCTAssertLessThanOrEqual(pool.countForTesting, capacity)
	}

	func testPatternPoolEvictionDoesNotInvalidateCompiledRules() {
		let pool = PatternPool.shared
		pool.resetForTesting()
		defer { pool.resetForTesting() }

		let compiled = GitignoreCompiler.compile(content: "retained-unique-pattern.txt")
		XCTAssertEqual(compiled.outcome(for: "retained-unique-pattern.txt", isDirectory: false), .ignore)

		for index in 0...pool.capacityForTesting {
			_ = pool.intern("pool-overflow-\(index)")
		}

		XCTAssertLessThanOrEqual(pool.countForTesting, pool.capacityForTesting)
		XCTAssertEqual(compiled.outcome(for: "retained-unique-pattern.txt", isDirectory: false), .ignore)
	}
	
	// MARK: - Basic Pattern Tests
	
	func testLiteralPatterns() {
		// Exact filename matches
		XCTAssertTrue(isIgnored(["test.txt"], path: "test.txt"))
		XCTAssertTrue(isIgnored(["test.txt"], path: "dir/test.txt"))
		XCTAssertFalse(isIgnored(["test.txt"], path: "test2.txt"))
		XCTAssertFalse(isIgnored(["test.txt"], path: "test.txt.bak"))
	}
	
	func testSingleStarPatterns() {
		// * matches zero or more characters
		XCTAssertTrue(isIgnored(["*.txt"], path: "test.txt"))
		XCTAssertTrue(isIgnored(["*.txt"], path: "dir/test.txt"))
		XCTAssertTrue(isIgnored(["test*"], path: "test123"))
		XCTAssertTrue(isIgnored(["*test*"], path: "mytestfile"))
		XCTAssertFalse(isIgnored(["*.txt"], path: "test.md"))
	}
	
	func testQuestionMarkPatterns() {
		// ? matches exactly one character
		XCTAssertTrue(isIgnored(["test?.txt"], path: "test1.txt"))
		XCTAssertTrue(isIgnored(["test?.txt"], path: "dir/test2.txt"))
		XCTAssertFalse(isIgnored(["test?.txt"], path: "test.txt"))
		XCTAssertFalse(isIgnored(["test?.txt"], path: "test12.txt"))
	}
	
	func testCharacterClassPatterns() {
		// [...] character classes
		XCTAssertTrue(isIgnored(["test[123].txt"], path: "test1.txt"))
		XCTAssertTrue(isIgnored(["test[123].txt"], path: "test2.txt"))
		XCTAssertTrue(isIgnored(["test[123].txt"], path: "test3.txt"))
		XCTAssertFalse(isIgnored(["test[123].txt"], path: "test4.txt"))
		
		// Negated character classes
		XCTAssertTrue(isIgnored(["test[!123].txt"], path: "test4.txt"))
		XCTAssertFalse(isIgnored(["test[!123].txt"], path: "test1.txt"))
	}
	
	// MARK: - Double Star Tests
	
	func testDoubleStarAtStart() {
		// **/pattern matches in any directory
		XCTAssertTrue(isIgnored(["**/test.txt"], path: "test.txt"))
		XCTAssertTrue(isIgnored(["**/test.txt"], path: "dir/test.txt"))
		XCTAssertTrue(isIgnored(["**/test.txt"], path: "a/b/c/test.txt"))
		XCTAssertFalse(isIgnored(["**/test.txt"], path: "test2.txt"))
	}
	
	func testDoubleStarAtEnd() {
		// pattern/** matches directory and all contents
		XCTAssertTrue(isIgnored(["foo/**"], path: "foo", isDirectory: true))
		XCTAssertTrue(isIgnored(["foo/**"], path: "foo/bar.txt"))
		XCTAssertTrue(isIgnored(["foo/**"], path: "foo/bar/baz.txt"))
		XCTAssertFalse(isIgnored(["foo/**"], path: "bar/foo.txt"))
	}
	
	func testDoubleStarInMiddle() {
		// pattern/**/pattern matches with any intermediate directories
		XCTAssertTrue(isIgnored(["foo/**/bar"], path: "foo/bar"))
		XCTAssertTrue(isIgnored(["foo/**/bar"], path: "foo/x/bar"))
		XCTAssertTrue(isIgnored(["foo/**/bar"], path: "foo/x/y/z/bar"))
		XCTAssertFalse(isIgnored(["foo/**/bar"], path: "bar/foo"))
		XCTAssertFalse(isIgnored(["foo/**/bar"], path: "foo/bar.txt"))
	}
	
	func testMultipleDoubleStars() {
		// Multiple ** in pattern
		XCTAssertTrue(isIgnored(["**/**/test.txt"], path: "test.txt"))
		XCTAssertTrue(isIgnored(["**/**/test.txt"], path: "a/test.txt"))
		XCTAssertTrue(isIgnored(["**/**/test.txt"], path: "a/b/c/test.txt"))
		
		XCTAssertTrue(isIgnored(["a/**/b/**/c"], path: "a/b/c"))
		XCTAssertTrue(isIgnored(["a/**/b/**/c"], path: "a/x/b/c"))
		XCTAssertTrue(isIgnored(["a/**/b/**/c"], path: "a/b/x/c"))
		XCTAssertTrue(isIgnored(["a/**/b/**/c"], path: "a/x/y/b/z/c"))
	}
	
	func testConsecutiveDoubleStars() {
		// Consecutive ** should be collapsed
		XCTAssertTrue(isIgnored(["**/**/**/*.txt"], path: "test.txt"))
		XCTAssertTrue(isIgnored(["**/**/**/*.txt"], path: "a/b/c/test.txt"))
	}
	
	// MARK: - Anchored Patterns
	
	func testAbsolutePatterns() {
		// Leading / anchors to root
		XCTAssertTrue(isIgnored(["/test.txt"], path: "test.txt"))
		XCTAssertFalse(isIgnored(["/test.txt"], path: "dir/test.txt"))
		
		XCTAssertTrue(isIgnored(["/foo/bar"], path: "foo/bar"))
		XCTAssertFalse(isIgnored(["/foo/bar"], path: "baz/foo/bar"))
	}
	
	// MARK: - Directory-Only Patterns
	
	func testDirectoryOnlyPatterns() {
		// Trailing / means directory only
		XCTAssertTrue(isIgnored(["foo/"], path: "foo", isDirectory: true))
		XCTAssertTrue(isIgnored(["foo/"], path: "bar/foo", isDirectory: true))
		XCTAssertFalse(isIgnored(["foo/"], path: "foo", isDirectory: false))
		XCTAssertFalse(isIgnored(["foo/"], path: "bar/foo", isDirectory: false))
	}

	func testDirectoryOnlyPatternsIgnoreDescendantDirectories() {
		XCTAssertTrue(isIgnored(["dir/"], path: "dir", isDirectory: true))
		XCTAssertTrue(isIgnored(["dir/"], path: "dir/file.txt"))
		XCTAssertTrue(isIgnored(["dir/"], path: "dir/subdir", isDirectory: true))
		XCTAssertTrue(isIgnored(["dir/"], path: "dir/subdir/file.txt"))
		XCTAssertTrue(isIgnored(["dir/"], path: "other/dir/subdir", isDirectory: true))
		XCTAssertTrue(isIgnored(["dir/"], path: "other/dir/subdir/file.txt"))
	}

	func testAnchoredDirectoryOnlyPatternsStayRootScoped() {
		XCTAssertTrue(isIgnored(["/dir/"], path: "dir", isDirectory: true))
		XCTAssertTrue(isIgnored(["/dir/"], path: "dir/file.txt"))
		XCTAssertTrue(isIgnored(["/dir/"], path: "dir/subdir", isDirectory: true))
		XCTAssertFalse(isIgnored(["/dir/"], path: "other/dir", isDirectory: true))
		XCTAssertFalse(isIgnored(["/dir/"], path: "other/dir/file.txt"))
	}

	func testDirectoryDoubleStarIsScopedAndMatchesBase() {
		XCTAssertTrue(isIgnored(["dir/**"], path: "dir", isDirectory: true))
		XCTAssertFalse(isIgnored(["dir/**"], path: "dir", isDirectory: false))
		XCTAssertTrue(isIgnored(["dir/**"], path: "dir/subdir", isDirectory: true))
		XCTAssertTrue(isIgnored(["dir/**"], path: "dir/subdir/file.txt"))
		XCTAssertFalse(isIgnored(["dir/**"], path: "other/dir", isDirectory: true))
		XCTAssertFalse(isIgnored(["dir/**"], path: "other/dir/file.txt"))
	}

	func testUnignoredDirectoryAllowsDescendantsDirectly() {
		let compiled = GitignoreCompiler.compile(content: "dir/\n!dir/")

		XCTAssertEqual(compiled.outcome(for: "dir", isDirectory: true), .allow)
		XCTAssertEqual(compiled.outcome(for: "dir/file.txt", isDirectory: false), .allow)
		XCTAssertEqual(compiled.outcome(for: "dir/subdir", isDirectory: true), .allow)
		XCTAssertEqual(compiled.outcome(for: "dir/subdir/file.txt", isDirectory: false), .allow)
		XCTAssertEqual(compiled.outcome(for: "other/dir/file.txt", isDirectory: false), .allow)
	}

	func testNestedUnignoredDirectoryAllowsDescendantsDirectly() {
		let compiled = GitignoreCompiler.compile(content: "/dir/\n!/dir/subdir/")

		XCTAssertEqual(compiled.outcome(for: "dir", isDirectory: true), .ignore)
		XCTAssertEqual(compiled.outcome(for: "dir/other/file.txt", isDirectory: false), .ignore)
		XCTAssertEqual(compiled.outcome(for: "dir/subdir", isDirectory: true), .allow)
		XCTAssertEqual(compiled.outcome(for: "dir/subdir/file.txt", isDirectory: false), .allow)
		XCTAssertEqual(compiled.outcome(for: "other/dir/subdir/file.txt", isDirectory: false), .noMatch)
	}

	func testExplicitFileAllowInsideIgnoredDirectoryDirectlyAllowsFile() {
		let compiled = GitignoreCompiler.compile(content: "/dir/\n!/dir/subdir/keep.txt")

		XCTAssertEqual(compiled.outcome(for: "dir", isDirectory: true), .ignore)
		XCTAssertEqual(compiled.outcome(for: "dir/subdir", isDirectory: true), .ignore)
		XCTAssertEqual(compiled.outcome(for: "dir/subdir/drop.txt", isDirectory: false), .ignore)
		XCTAssertEqual(compiled.outcome(for: "dir/subdir/keep.txt", isDirectory: false), .allow)
	}
	
	// MARK: - Negation Patterns
	
	func testNegationPatterns() {
		// ! negates previous patterns
		let patterns = ["*.txt", "!important.txt"]
		XCTAssertTrue(isIgnored(patterns, path: "test.txt"))
		XCTAssertFalse(isIgnored(patterns, path: "important.txt"))
		XCTAssertTrue(isIgnored(patterns, path: "dir/test.txt"))
		XCTAssertFalse(isIgnored(patterns, path: "dir/important.txt"))
	}
	
	func testComplexNegationScenarios() {
		// Complex negation with directories
		let patterns = ["build/", "!build/important/", "build/important/*.tmp"]
		
		// Git's behavior: 
		// - "build/" ignores everything under build/ directory
		// - "!build/important/" un-ignores the build/important/ directory AND its contents
		// - "build/important/*.tmp" re-ignores .tmp files in that directory
		
		XCTAssertTrue(isIgnored(patterns, path: "build/test.txt"))
		XCTAssertTrue(isIgnored(patterns, path: "build/dir/file.txt"))
		XCTAssertFalse(isIgnored(patterns, path: "build/important/keep.txt"))
		XCTAssertTrue(isIgnored(patterns, path: "build/important/temp.tmp"))
	}
	
	// MARK: - Edge Cases
	
	func testEmptyPath() {
		XCTAssertFalse(isIgnored(["test"], path: ""))
		XCTAssertFalse(isIgnored(["*"], path: ""))
		XCTAssertTrue(isIgnored(["**"], path: ""))
	}
	
	func testEmptyPattern() {
		let compiled = GitignoreCompiler.compile(content: "")
		XCTAssertEqual(compiled.outcome(for: "test", isDirectory: false), .noMatch)
	}
	
	func testWhitespaceHandling() {
		// Leading/trailing whitespace should be trimmed
		XCTAssertTrue(isIgnored(["  test.txt  "], path: "test.txt"))
		XCTAssertTrue(isIgnored(["\ttest.txt\t"], path: "test.txt"))
	}
	
	func testCommentHandling() {
		// Comments should be ignored
		let patterns = [
			"# This is a comment",
			"test.txt",
			"  # Another comment",
			"!important.txt"
		]
		XCTAssertTrue(isIgnored(patterns, path: "test.txt"))
		XCTAssertFalse(isIgnored(patterns, path: "important.txt"))
	}

	func testEscapedLeadingBangIsLiteral() {
		XCTAssertTrue(isIgnored(["\\!literal.txt"], path: "!literal.txt"))
		XCTAssertFalse(isIgnored(["\\!literal.txt"], path: "literal.txt"))

		let negatedLiteralBang = GitignoreCompiler.compile(content: "*.txt\n!\\!literal.txt")
		XCTAssertEqual(negatedLiteralBang.outcome(for: "!literal.txt", isDirectory: false), .allow)
		XCTAssertEqual(negatedLiteralBang.outcome(for: "other.txt", isDirectory: false), .ignore)

		let doubleBang = GitignoreCompiler.compile(content: "*.txt\n!!literal.txt")
		XCTAssertEqual(doubleBang.outcome(for: "!literal.txt", isDirectory: false), .allow)
		XCTAssertEqual(doubleBang.outcome(for: "literal.txt", isDirectory: false), .ignore)
	}

	func testEscapedHashAndTrailingSpaceParsing() {
		XCTAssertTrue(isIgnored(["\\#not-a-comment.txt"], path: "#not-a-comment.txt"))
		XCTAssertFalse(isIgnored(["\\#not-a-comment.txt"], path: "not-a-comment.txt"))

		let negatedHash = GitignoreCompiler.compile(content: "*.txt\n!\\#keep.txt")
		XCTAssertEqual(negatedHash.outcome(for: "#keep.txt", isDirectory: false), .allow)
		XCTAssertEqual(negatedHash.outcome(for: "drop.txt", isDirectory: false), .ignore)

		XCTAssertTrue(isIgnored(["trailing\\ "], path: "trailing "))
		XCTAssertFalse(isIgnored(["trailing\\ "], path: "trailing"))
		XCTAssertTrue(isIgnored(["multi\\ \\ "], path: "multi  "))
		XCTAssertFalse(isIgnored(["multi\\ \\ "], path: "multi "))
	}
	
	// MARK: - Performance Tests
	
	func testDeepPathPerformance() {
		// Test with very deep paths
		let deepPath = (0..<100).map { "dir\($0)" }.joined(separator: "/") + "/file.txt"
		let patterns = ["**/file.txt"]
		
		measure {
			for _ in 0..<100 {
				_ = isIgnored(patterns, path: deepPath)
			}
		}
	}
	
	func testManyPatternsPerformance() {
		// Test with many patterns
		let patterns = (0..<1000).map { "pattern\($0).txt" }
		
		measure {
			for i in 0..<100 {
				_ = isIgnored(patterns, path: "pattern\(i).txt")
			}
		}
	}
	
	func testComplexDoubleStarPerformance() {
		// Test complex ** patterns
		let patterns = ["a/**/b/**/c/**/d/**/e"]
		let path = "a/x/y/b/z/w/c/m/n/d/o/p/e"
		
		measure {
			for _ in 0..<1000 {
				_ = isIgnored(patterns, path: path)
			}
		}
	}
	
	// MARK: - Specific Regression Tests
	
	func testGitignoreCompatibility() {
		// Test patterns that should behave like Git
		
		// node_modules anywhere
		XCTAssertTrue(isIgnored(["node_modules/"], path: "node_modules", isDirectory: true))
		XCTAssertTrue(isIgnored(["node_modules/"], path: "src/node_modules", isDirectory: true))
		
		// Build outputs
		XCTAssertTrue(isIgnored(["*.o", "*.a", "*.so"], path: "test.o"))
		XCTAssertTrue(isIgnored(["*.o", "*.a", "*.so"], path: "lib/libtest.a"))
		XCTAssertTrue(isIgnored(["*.o", "*.a", "*.so"], path: "lib/libtest.so"))
		
		// Hidden files
		XCTAssertTrue(isIgnored([".*"], path: ".gitignore"))
		XCTAssertTrue(isIgnored([".*"], path: ".DS_Store"))
		// Note: .DS_Store may be ignored by default hardcoded patterns in the app
		// Test that negation patterns work correctly
		XCTAssertFalse(isIgnored([".*", "!.gitignore"], path: ".gitignore"))
	}
	
	// MARK: - Complex Git Compliance Tests
	
	func testNestedDirectoryPatterns() {
		// Test nested directory exclusions with negations
		let patterns = [
			"data/",
			"!data/important/",
			"data/important/temp/",
			"!data/important/temp/keep.txt"
		]
		
		// Everything under data/ is ignored
		XCTAssertTrue(isIgnored(patterns, path: "data/file.txt"))
		XCTAssertTrue(isIgnored(patterns, path: "data/subfolder/file.txt"))
		
		// Except data/important/
		XCTAssertFalse(isIgnored(patterns, path: "data/important/file.txt"))
		XCTAssertFalse(isIgnored(patterns, path: "data/important/docs/readme.md"))
		
		// But data/important/temp/ is ignored again
		XCTAssertTrue(isIgnored(patterns, path: "data/important/temp/file.txt"))
		XCTAssertTrue(isIgnored(patterns, path: "data/important/temp/subfolder/file.txt"))
		
		// Except the specific file
		XCTAssertFalse(isIgnored(patterns, path: "data/important/temp/keep.txt"))
	}
	
	func testDoubleStarWithDirectoryPatterns() {
		// Test ** with directory-only patterns
		let patterns = ["**/build/", "!**/build/important/"]
		
		// Any build directory is ignored
		XCTAssertTrue(isIgnored(patterns, path: "build/output.txt"))
		XCTAssertTrue(isIgnored(patterns, path: "src/build/output.txt"))
		XCTAssertTrue(isIgnored(patterns, path: "src/main/java/build/output.txt"))
		
		// But not build/important in any location
		XCTAssertFalse(isIgnored(patterns, path: "build/important/keep.txt"))
		XCTAssertFalse(isIgnored(patterns, path: "src/build/important/keep.txt"))
		XCTAssertFalse(isIgnored(patterns, path: "deep/nested/build/important/keep.txt"))
	}
	
	func testAbsoluteVsRelativePatterns() {
		// Test the difference between /pattern and pattern
		
		// Absolute pattern only matches at root
		XCTAssertTrue(isIgnored(["/config.json"], path: "config.json"))
		XCTAssertFalse(isIgnored(["/config.json"], path: "src/config.json"))
		XCTAssertFalse(isIgnored(["/config.json"], path: "deep/nested/config.json"))
		
		// Relative pattern matches anywhere
		XCTAssertTrue(isIgnored(["config.json"], path: "config.json"))
		XCTAssertTrue(isIgnored(["config.json"], path: "src/config.json"))
		XCTAssertTrue(isIgnored(["config.json"], path: "deep/nested/config.json"))
		
		// Absolute directory patterns
		XCTAssertTrue(isIgnored(["/build/"], path: "build/output.txt"))
		XCTAssertFalse(isIgnored(["/build/"], path: "src/build/output.txt"))
	}
	
	func testComplexWildcardPatterns() {
		// Test various wildcard combinations
		
		// Single * doesn't cross directory boundaries
		XCTAssertTrue(isIgnored(["test-*"], path: "test-file.txt"))
		XCTAssertTrue(isIgnored(["test-*"], path: "dir/test-file.txt"))
		XCTAssertFalse(isIgnored(["test-*"], path: "test/file.txt"))
		
		// Multiple wildcards in pattern
		XCTAssertTrue(isIgnored(["*-test-*"], path: "prefix-test-suffix.txt"))
		XCTAssertTrue(isIgnored(["*-test-*"], path: "a-test-b"))
		XCTAssertFalse(isIgnored(["*-test-*"], path: "test-only"))
		
		// Wildcards with extensions
		XCTAssertTrue(isIgnored(["*.test.*"], path: "file.test.js"))
		XCTAssertTrue(isIgnored(["*.test.*"], path: "component.test.tsx"))
		XCTAssertFalse(isIgnored(["*.test.*"], path: "test.js"))
	}
	
	func testEscapedCharacters() {
		// Test patterns with special characters
		
		// Note: In gitignore, square brackets create character classes
		// To match literal brackets, they need to be escaped in the gitignore file
		// Since we're testing the pattern directly, [1] will match "1"
		XCTAssertTrue(isIgnored(["file[1].txt"], path: "file1.txt"))
		XCTAssertFalse(isIgnored(["file[1].txt"], path: "file[1].txt"))
		
		// Patterns with spaces
		XCTAssertTrue(isIgnored(["my file.txt"], path: "my file.txt"))
		XCTAssertTrue(isIgnored(["my file.txt"], path: "dir/my file.txt"))
		
		// Patterns with special chars
		XCTAssertTrue(isIgnored(["file#1.txt"], path: "file#1.txt"))
		XCTAssertTrue(isIgnored(["file@host.txt"], path: "file@host.txt"))
	}
	
	func testCharacterClassesInDetail() {
		// Test character class behavior
		
		// Basic character class
		XCTAssertTrue(isIgnored(["file[123].txt"], path: "file1.txt"))
		XCTAssertTrue(isIgnored(["file[123].txt"], path: "file2.txt"))
		XCTAssertTrue(isIgnored(["file[123].txt"], path: "file3.txt"))
		XCTAssertFalse(isIgnored(["file[123].txt"], path: "file4.txt"))
		XCTAssertFalse(isIgnored(["file[123].txt"], path: "file[123].txt"))
		
		// Range in character class
		XCTAssertTrue(isIgnored(["file[a-z].txt"], path: "filea.txt"))
		XCTAssertTrue(isIgnored(["file[a-z].txt"], path: "filez.txt"))
		XCTAssertFalse(isIgnored(["file[a-z].txt"], path: "fileA.txt"))
		XCTAssertFalse(isIgnored(["file[a-z].txt"], path: "file1.txt"))
		
		// Negated character class
		XCTAssertTrue(isIgnored(["file[!0-9].txt"], path: "filea.txt"))
		XCTAssertTrue(isIgnored(["file[!0-9].txt"], path: "fileA.txt"))
		XCTAssertFalse(isIgnored(["file[!0-9].txt"], path: "file1.txt"))
		XCTAssertFalse(isIgnored(["file[!0-9].txt"], path: "file9.txt"))
		
		// Mixed character class
		XCTAssertTrue(isIgnored(["file[a-zA-Z0-9].txt"], path: "filea.txt"))
		XCTAssertTrue(isIgnored(["file[a-zA-Z0-9].txt"], path: "fileZ.txt"))
		XCTAssertTrue(isIgnored(["file[a-zA-Z0-9].txt"], path: "file5.txt"))
		XCTAssertFalse(isIgnored(["file[a-zA-Z0-9].txt"], path: "file_.txt"))
		XCTAssertFalse(isIgnored(["file[a-zA-Z0-9].txt"], path: "file-.txt"))
	}
	
	func testNegationOrdering() {
		// Test that order matters for negations
		
		// Later patterns override earlier ones
		let patterns1 = ["*.log", "!important.log", "*.log"]
		XCTAssertTrue(isIgnored(patterns1, path: "important.log")) // Last *.log wins
		
		let patterns2 = ["*.log", "*.log", "!important.log"]
		XCTAssertFalse(isIgnored(patterns2, path: "important.log")) // Last !important.log wins
		
		// Complex ordering with directories
		let patterns3 = [
			"logs/",
			"!logs/important/",
			"logs/important/debug/",
			"!logs/important/debug/critical.log"
		]
		XCTAssertTrue(isIgnored(patterns3, path: "logs/error.log"))
		XCTAssertFalse(isIgnored(patterns3, path: "logs/important/info.log"))
		XCTAssertTrue(isIgnored(patterns3, path: "logs/important/debug/verbose.log"))
		XCTAssertFalse(isIgnored(patterns3, path: "logs/important/debug/critical.log"))
	}
	
	func testSubdirectoryGitignoreSemantics() {
		// In Git, patterns in subdirectory .gitignore files are relative to that directory
		// This test verifies our pattern matching works correctly when given pre-adjusted paths
		
		// Simulating a .gitignore in src/ directory with pattern "*.tmp"
		// The path would be relative to repository root
		XCTAssertTrue(isIgnored(["src/*.tmp"], path: "src/temp.tmp"))
		XCTAssertFalse(isIgnored(["src/*.tmp"], path: "temp.tmp"))
		XCTAssertFalse(isIgnored(["src/*.tmp"], path: "other/temp.tmp"))
	}
	
	func testDoubleStarEdgeCases() {
		// Test edge cases with ** patterns
		
		// ** at the beginning
		XCTAssertTrue(isIgnored(["**/file.txt"], path: "file.txt"))
		XCTAssertTrue(isIgnored(["**/file.txt"], path: "a/file.txt"))
		XCTAssertTrue(isIgnored(["**/file.txt"], path: "a/b/c/file.txt"))
		
		// ** at the end
		XCTAssertTrue(isIgnored(["dir/**"], path: "dir", isDirectory: true))
		XCTAssertTrue(isIgnored(["dir/**"], path: "dir/file.txt"))
		XCTAssertTrue(isIgnored(["dir/**"], path: "dir/sub/file.txt"))
		// Slash-containing patterns are scoped to the ignore-file directory.
		XCTAssertFalse(isIgnored(["dir/**"], path: "other/dir/file.txt"))
		XCTAssertTrue(isIgnored(["**/dir/**"], path: "other/dir/file.txt"))
		
		// Test anchored version
		XCTAssertTrue(isIgnored(["/dir/**"], path: "dir/file.txt"))
		XCTAssertFalse(isIgnored(["/dir/**"], path: "other/dir/file.txt"))
		
		// ** in the middle
		XCTAssertTrue(isIgnored(["a/**/b"], path: "a/b"))
		XCTAssertTrue(isIgnored(["a/**/b"], path: "a/x/b"))
		XCTAssertTrue(isIgnored(["a/**/b"], path: "a/x/y/z/b"))
		
		// Multiple ** (should work but is redundant)
		XCTAssertTrue(isIgnored(["**/**/file.txt"], path: "file.txt"))
		XCTAssertTrue(isIgnored(["**/**/file.txt"], path: "a/b/c/file.txt"))
		
		// ** with file extensions
		XCTAssertTrue(isIgnored(["**/*.tmp"], path: "temp.tmp"))
		XCTAssertTrue(isIgnored(["**/*.tmp"], path: "deep/nested/temp.tmp"))
		
		// Combining ** with directory patterns
		XCTAssertTrue(isIgnored(["**/node_modules/**"], path: "node_modules/package.json"))
		XCTAssertTrue(isIgnored(["**/node_modules/**"], path: "src/node_modules/package.json"))
		XCTAssertTrue(isIgnored(["**/node_modules/**"], path: "src/node_modules/lib/index.js"))
	}
	
	func testRealWorldPatterns() {
		// Test common real-world .gitignore patterns
		
		// Python
		let pythonPatterns = ["__pycache__/", "*.pyc", "*.pyo", "*.pyd", ".Python", "venv/", "*.egg-info/"]
		XCTAssertTrue(isIgnored(pythonPatterns, path: "__pycache__", isDirectory: true))
		XCTAssertTrue(isIgnored(pythonPatterns, path: "src/__pycache__", isDirectory: true))
		XCTAssertTrue(isIgnored(pythonPatterns, path: "src/__pycache__/module.pyc"))
		XCTAssertTrue(isIgnored(pythonPatterns, path: "test.pyc"))
		XCTAssertTrue(isIgnored(pythonPatterns, path: "venv/lib/python3.9/site-packages/file.py"))
		XCTAssertTrue(isIgnored(pythonPatterns, path: "mypackage.egg-info/PKG-INFO"))
		
		// Node.js
		let nodePatterns = ["node_modules/", "npm-debug.log*", "*.log", "coverage/", ".env", "dist/"]
		XCTAssertTrue(isIgnored(nodePatterns, path: "node_modules/express/index.js"))
		XCTAssertTrue(isIgnored(nodePatterns, path: "npm-debug.log"))
		XCTAssertTrue(isIgnored(nodePatterns, path: "npm-debug.log.12345"))
		XCTAssertTrue(isIgnored(nodePatterns, path: ".env"))
		XCTAssertTrue(isIgnored(nodePatterns, path: "dist/bundle.js"))
		XCTAssertTrue(isIgnored(nodePatterns, path: "coverage/lcov.info"))
		
		// IDE/Editor files
		let idePatterns = [".vscode/", ".idea/", "*.swp", "*.swo", "*~", ".DS_Store"]
		XCTAssertTrue(isIgnored(idePatterns, path: ".vscode/settings.json"))
		XCTAssertTrue(isIgnored(idePatterns, path: ".idea/workspace.xml"))
		XCTAssertTrue(isIgnored(idePatterns, path: "file.swp"))
		XCTAssertTrue(isIgnored(idePatterns, path: "src/file.swo"))
		XCTAssertTrue(isIgnored(idePatterns, path: "backup~"))
		XCTAssertTrue(isIgnored(idePatterns, path: ".DS_Store"))
	}
	
	func testTrailingSpacesAndSlashes() {
		// Git strips trailing spaces from patterns (unless escaped)
		// Our implementation should handle this during pattern compilation
		
		// Pattern with trailing slash for directory
		XCTAssertTrue(isIgnored(["logs/"], path: "logs", isDirectory: true))
		XCTAssertTrue(isIgnored(["logs/"], path: "logs/error.log"))
		XCTAssertFalse(isIgnored(["logs/"], path: "logs", isDirectory: false))
		
		// Multiple slashes are treated as single slash
		XCTAssertTrue(isIgnored(["foo//bar"], path: "foo/bar"))
		XCTAssertTrue(isIgnored(["foo///bar"], path: "foo/bar"))
	}
	
	func testPatternAnchoring() {
		// Test various anchoring scenarios
		
		// Pattern with slash but not at start is scoped to the ignore-file directory
		XCTAssertTrue(isIgnored(["foo/bar"], path: "foo/bar"))
		XCTAssertFalse(isIgnored(["foo/bar"], path: "baz/foo/bar"))
		XCTAssertTrue(isIgnored(["**/foo/bar"], path: "baz/foo/bar"))
		XCTAssertFalse(isIgnored(["foo/bar"], path: "foo/baz/bar"))
		
		// Pattern without slash matches any level
		XCTAssertTrue(isIgnored(["bar"], path: "bar"))
		XCTAssertTrue(isIgnored(["bar"], path: "foo/bar"))
		XCTAssertTrue(isIgnored(["bar"], path: "foo/baz/bar"))
		
		// Leading slash anchors to repository root
		XCTAssertTrue(isIgnored(["/foo"], path: "foo"))
		XCTAssertFalse(isIgnored(["/foo"], path: "bar/foo"))
		
		// Trailing slash only matches directories
		XCTAssertTrue(isIgnored(["foo/"], path: "foo", isDirectory: true))
		XCTAssertFalse(isIgnored(["foo/"], path: "foo", isDirectory: false))
	}
	
	func testEmptyAndCommentPatterns() {
		// Test handling of empty lines and comments
		
		let patterns = [
			"# This is a comment",
			"",  // Empty line
			"   ",  // Whitespace only
			"test.txt",
			"  # Another comment with leading spaces",
			"!important.txt",
			"\\#not-a-comment.txt"  // Escaped hash
		]
		
		// Only test.txt and important.txt patterns should be active
		XCTAssertTrue(isIgnored(patterns, path: "test.txt"))
		XCTAssertFalse(isIgnored(patterns, path: "important.txt"))
		
		// The escaped hash pattern should work
		XCTAssertTrue(isIgnored(patterns, path: "#not-a-comment.txt"))
		
		// Comments themselves shouldn't match
		XCTAssertFalse(isIgnored(patterns, path: "# This is a comment"))
	}
	
	func testGlobstarBehavior() {
		// Test specific ** (globstar) behaviors
		
		// ** must be surrounded by slashes (or string start/end) to be special as globstar
		// When not surrounded by slashes, ** acts as two regular * wildcards
		XCTAssertTrue(isIgnored(["a**b"], path: "a**b"))  // Exact match
		XCTAssertTrue(isIgnored(["a**b"], path: "aXXb"))  // Two wildcards match XX
		XCTAssertTrue(isIgnored(["a**b"], path: "aXYZb")) // Two wildcards match XYZ
		XCTAssertTrue(isIgnored(["a**b"], path: "ab"))    // Two wildcards match empty
		
		// Proper globstar usage
		XCTAssertTrue(isIgnored(["**/foo"], path: "foo"))
		XCTAssertTrue(isIgnored(["**/foo"], path: "bar/foo"))
		XCTAssertTrue(isIgnored(["foo/**"], path: "foo/bar"))
		XCTAssertTrue(isIgnored(["foo/**/bar"], path: "foo/bar"))
		XCTAssertTrue(isIgnored(["foo/**/bar"], path: "foo/baz/bar"))
		
		// ** can match zero directories
		XCTAssertTrue(isIgnored(["foo/**/bar"], path: "foo/bar"))
	}
	
	func testSlashHandling() {
		// Test how slashes in patterns affect matching
		
		// Pattern with internal slash is scoped to the ignore-file directory
		XCTAssertTrue(isIgnored(["foo/bar"], path: "foo/bar"))
		XCTAssertFalse(isIgnored(["foo/bar"], path: "baz/foo/bar"))
		XCTAssertTrue(isIgnored(["**/foo/bar"], path: "baz/foo/bar"))
		XCTAssertFalse(isIgnored(["foo/bar"], path: "foox/bar"))
		XCTAssertFalse(isIgnored(["foo/bar"], path: "xfoo/bar"))
		
		// Leading slash makes it absolute
		XCTAssertTrue(isIgnored(["/foo/bar"], path: "foo/bar"))
		XCTAssertFalse(isIgnored(["/foo/bar"], path: "baz/foo/bar"))
		
		// No slash means match at any level
		XCTAssertTrue(isIgnored(["bar"], path: "bar"))
		XCTAssertTrue(isIgnored(["bar"], path: "foo/bar"))
		XCTAssertTrue(isIgnored(["bar"], path: "foo/baz/bar"))
	}

	func testSlashPatternsAreScopedToDirectoryPath() {
		let compiled = GitignoreCompiler.compile(content: "cache/*.dat\n!cache/keep.dat", directoryPath: "src")

		XCTAssertEqual(compiled.outcome(for: "src/cache/drop.dat", isDirectory: false), .ignore)
		XCTAssertEqual(compiled.outcome(for: "src/cache/keep.dat", isDirectory: false), .allow)
		XCTAssertEqual(compiled.outcome(for: "cache/drop.dat", isDirectory: false), .noMatch)
		XCTAssertEqual(compiled.outcome(for: "other/src/cache/drop.dat", isDirectory: false), .noMatch)
	}

	func testTrailingDoubleStarMatchesBaseDirectoryWhenScoped() {
		XCTAssertTrue(isIgnored(["foo/**"], path: "foo", isDirectory: true))
		XCTAssertFalse(isIgnored(["foo/**"], path: "foo", isDirectory: false))
		XCTAssertTrue(isIgnored(["foo/**"], path: "foo/bar.txt"))
		XCTAssertFalse(isIgnored(["foo/**"], path: "other/foo", isDirectory: true))
		XCTAssertFalse(isIgnored(["foo/**"], path: "other/foo/bar.txt"))

		XCTAssertTrue(isIgnored(["**/foo/**"], path: "foo", isDirectory: true))
		XCTAssertTrue(isIgnored(["**/foo/**"], path: "a/foo", isDirectory: true))
		XCTAssertFalse(isIgnored(["**/foo/**"], path: "a/foo", isDirectory: false))
		XCTAssertTrue(isIgnored(["**/foo/**"], path: "a/foo/bar.txt"))
	}

	func testDirectUnignoreForSlashScopedDescendant() {
		let compiled = GitignoreCompiler.compile(content: "/Temp/\n!/Temp/Tracked/TrackedIgnoredFile.txt")

		XCTAssertEqual(compiled.outcome(for: "Temp", isDirectory: true), .ignore)
		XCTAssertEqual(compiled.outcome(for: "Temp/Other/file.txt", isDirectory: false), .ignore)
		XCTAssertEqual(compiled.outcome(for: "Temp/Tracked/TrackedIgnoredFile.txt", isDirectory: false), .allow)
	}

	func testConservativePrefiltersPreserveLiteralSuffixAndAnchoredSemantics() {
		let basenameAndDirectory = GitignoreCompiler.compile(content: "node_modules\nbuild/")
		XCTAssertEqual(basenameAndDirectory.outcome(for: "packages/node_modules", isDirectory: true), .ignore)
		XCTAssertEqual(basenameAndDirectory.outcome(for: "src/build/drop.txt", isDirectory: false), .ignore)
		XCTAssertEqual(basenameAndDirectory.outcome(for: "src/node_modules/package.json", isDirectory: false), .ignore)
		XCTAssertEqual(basenameAndDirectory.outcome(for: "src/build-product/drop.txt", isDirectory: false), .noMatch)

		let anchored = GitignoreCompiler.compile(content: "/src/cache\n/generated/")
		XCTAssertEqual(anchored.outcome(for: "src/cache", isDirectory: false), .ignore)
		XCTAssertEqual(anchored.outcome(for: "other/src/cache", isDirectory: false), .noMatch)
		XCTAssertEqual(anchored.outcome(for: "generated", isDirectory: true), .ignore)
		XCTAssertEqual(anchored.outcome(for: "generated/file.swift", isDirectory: false), .ignore)
		XCTAssertEqual(anchored.outcome(for: "other/generated/file.swift", isDirectory: false), .noMatch)

		let suffixWithNegation = GitignoreCompiler.compile(content: "*.log\n!important.log")
		XCTAssertEqual(suffixWithNegation.outcome(for: "logs/debug.log", isDirectory: false), .ignore)
		XCTAssertEqual(suffixWithNegation.outcome(for: "logs/important.log", isDirectory: false), .allow)
		XCTAssertEqual(suffixWithNegation.outcome(for: "logs/debug.txt", isDirectory: false), .noMatch)

		let fallbackGlobSyntax = GitignoreCompiler.compile(content: "file?.txt\n[Ll]ibrary\n**/keep.txt")
		XCTAssertEqual(fallbackGlobSyntax.outcome(for: "file1.txt", isDirectory: false), .ignore)
		XCTAssertEqual(fallbackGlobSyntax.outcome(for: "Library", isDirectory: true), .ignore)
		XCTAssertEqual(fallbackGlobSyntax.outcome(for: "deep/path/keep.txt", isDirectory: false), .ignore)
	}

	func testNegationTraversalDiagnosticsForLiteralDirectoryUnignores() {
		let compiled = GitignoreCompiler.compile(content: "/dir/\n!/dir/subdir/")

		XCTAssertTrue(compiled.requiresTraversal(for: "dir"))
		XCTAssertTrue(compiled.requiresTraversal(for: "dir/subdir"))
		XCTAssertFalse(compiled.requiresTraversal(for: "dir/subdir/file.txt"))
		XCTAssertEqual(compiled.traversalDiagnostics.exactPrefixCount, 2)
		XCTAssertEqual(compiled.traversalDiagnostics.patternHintCount, 0)
		XCTAssertEqual(compiled.traversalDiagnostics.broadPatternHintCount, 0)
		XCTAssertEqual(compiled.traversalDiagnostics.basenameOnlyNegationCount, 0)
	}

	func testNegationTraversalPatternHintsForWildcardIgnoredDirectories() {
		let compiled = GitignoreCompiler.compile(content: "temp-*/\n!temp-*/important.txt")

		XCTAssertTrue(compiled.requiresTraversal(for: "temp-123"))
		XCTAssertTrue(compiled.requiresTraversal(for: "temp-abc"))
		XCTAssertFalse(compiled.requiresTraversal(for: "other/temp-123"))
		XCTAssertFalse(compiled.requiresTraversal(for: "temp-123/nested"))
		XCTAssertEqual(compiled.traversalDiagnostics.exactPrefixCount, 0)
		XCTAssertEqual(compiled.traversalDiagnostics.patternHintCount, 1)
		XCTAssertEqual(compiled.traversalDiagnostics.broadPatternHintCount, 0)
		XCTAssertEqual(compiled.traversalDiagnostics.basenameOnlyNegationCount, 0)
	}

	func testNegationTraversalPatternHintsForGlobstarDescendants() {
		let compiled = GitignoreCompiler.compile(content: "logs/**\n!logs/**/keep.txt")

		XCTAssertTrue(compiled.requiresTraversal(for: "logs"))
		XCTAssertTrue(compiled.requiresTraversal(for: "logs/a"))
		XCTAssertTrue(compiled.requiresTraversal(for: "logs/a/b"))
		XCTAssertFalse(compiled.requiresTraversal(for: "other/logs"))
		XCTAssertEqual(compiled.traversalDiagnostics.exactPrefixCount, 1)
		XCTAssertEqual(compiled.traversalDiagnostics.patternHintCount, 1)
		XCTAssertEqual(compiled.traversalDiagnostics.broadPatternHintCount, 0)
		XCTAssertEqual(compiled.traversalDiagnostics.basenameOnlyNegationCount, 0)
	}

	func testNegationTraversalDiagnosticsForBasenameOnlyAndBroadNegations() {
		let basenameOnly = GitignoreCompiler.compile(content: "*.log\n!important.log")
		XCTAssertFalse(basenameOnly.requiresTraversal(for: "ignored-dir"))
		XCTAssertEqual(basenameOnly.traversalDiagnostics.basenameOnlyNegationCount, 1)

		let broad = GitignoreCompiler.compile(content: "ignored/\n!**/keep.txt")
		XCTAssertTrue(broad.requiresTraversal(for: "ignored"))
		XCTAssertTrue(broad.requiresTraversal(for: "anything/deep"))
		XCTAssertEqual(broad.traversalDiagnostics.patternHintCount, 1)
		XCTAssertEqual(broad.traversalDiagnostics.broadPatternHintCount, 1)
	}

	#if DEBUG
	func testDebugMetricsCaptureCompilationMatchingAndTraversalHints() {
		IgnoreDebugMetricsRecorder.reset()

		let content = [
			"/ignored/",
			"!ignored/keep.txt",
			"temp-*/",
			"!temp-*/important.txt",
			"logs/**",
			"!logs/**/keep.txt",
			"!**/global-keep.txt",
			"!basename.log"
		].joined(separator: "\n")
		let compiled = GitignoreCompiler.compile(content: content)

		XCTAssertEqual(compiled.outcome(for: "temp-123/important.txt", isDirectory: false), .allow)
		XCTAssertEqual(compiled.outcome(for: "logs", isDirectory: true), .ignore)
		XCTAssertTrue(compiled.requiresTraversal(for: "ignored"))
		XCTAssertTrue(compiled.requiresTraversal(for: "temp-123"))
		XCTAssertTrue(compiled.requiresTraversal(for: "logs/a/b"))
		XCTAssertTrue(compiled.requiresTraversal(for: "anything/deep"))

		let metrics = IgnoreDebugMetricsRecorder.snapshot()
		XCTAssertGreaterThanOrEqual(metrics.compileCallCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.compileRawLineCount, 8)
		XCTAssertGreaterThanOrEqual(metrics.compilePatternCount, 8)
		XCTAssertGreaterThanOrEqual(metrics.compileNegationPatternCount, 5)
		XCTAssertGreaterThanOrEqual(metrics.compileTraversalExactPrefixCount, 2)
		XCTAssertGreaterThanOrEqual(metrics.compileTraversalPatternHintCount, 3)
		XCTAssertGreaterThanOrEqual(metrics.compileTraversalBroadPatternHintCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.compileBasenameOnlyNegationCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.outcomeEvaluationCount, 2)
		XCTAssertGreaterThan(metrics.patternMatchAttemptCount, 0)
		XCTAssertGreaterThan(metrics.patternVisitCount, 0)
		XCTAssertGreaterThanOrEqual(metrics.maxPatternVisitsPerOutcome, metrics.maxPatternAttemptsPerOutcome)
		XCTAssertEqual(
			metrics.outcomeZeroAttemptCount
				+ metrics.outcomeOneAttemptCount
				+ metrics.outcomeTwoToFourAttemptCount
				+ metrics.outcomeFiveToEightAttemptCount
				+ metrics.outcomeNineToSixteenAttemptCount
				+ metrics.outcomeSeventeenToThirtyTwoAttemptCount
				+ metrics.outcomeThirtyThreeToSixtyFourAttemptCount
				+ metrics.outcomeSixtyFivePlusAttemptCount,
			metrics.outcomeEvaluationCount
		)
		XCTAssertGreaterThan(metrics.trailingDoubleStarBaseCheckCount, 0)
		XCTAssertGreaterThanOrEqual(metrics.traversalRequiresCheckCount, 4)
		XCTAssertGreaterThan(metrics.traversalExactPrefixHitCount, 0)
		XCTAssertGreaterThan(metrics.traversalPatternCheckCount, 0)
		XCTAssertGreaterThan(metrics.traversalPatternHitCount, 0)
	}

	func testDebugMetricsCapturePrefilterSkipsAndAttemptHistogram() {
		IgnoreDebugMetricsRecorder.reset()

		let compiled = GitignoreCompiler.compile(content: """
		node_modules
		build/
		/src/cache
		*.log
		!important.log
		dist
		coverage/
		""")

		XCTAssertEqual(compiled.outcome(for: "src/app/main.swift", isDirectory: false), .noMatch)
		XCTAssertEqual(compiled.outcome(for: "logs/debug.log", isDirectory: false), .ignore)

		let metrics = IgnoreDebugMetricsRecorder.snapshot()
		XCTAssertGreaterThanOrEqual(metrics.outcomeEvaluationCount, 2)
		XCTAssertGreaterThan(metrics.patternVisitCount, 0)
		XCTAssertGreaterThan(metrics.patternPrefilterCheckCount, 0)
		XCTAssertGreaterThan(metrics.patternPrefilterSkipCount, 0)
		XCTAssertGreaterThan(metrics.patternPrefilterPassCount, 0)
		XCTAssertLessThan(metrics.patternMatchAttemptCount, metrics.patternVisitCount)
		XCTAssertGreaterThan(metrics.outcomeZeroAttemptCount, 0)
		XCTAssertGreaterThan(metrics.maxPatternVisitsPerOutcome, metrics.maxPatternAttemptsPerOutcome)
	}
	#endif
	
	func testComplexNegationWithWildcards() {
		// Test negation patterns with wildcards
		
		let patterns = [
			"*.log",
			"!important-*.log",
			"important-temp-*.log"
		]
		
		XCTAssertTrue(isIgnored(patterns, path: "debug.log"))
		XCTAssertTrue(isIgnored(patterns, path: "error.log"))
		XCTAssertFalse(isIgnored(patterns, path: "important-system.log"))
		XCTAssertFalse(isIgnored(patterns, path: "important-critical.log"))
		XCTAssertTrue(isIgnored(patterns, path: "important-temp-2023.log"))
		XCTAssertTrue(isIgnored(patterns, path: "important-temp-old.log"))
	}
	
	func testCaseSensitivity() {
		// Git ignore patterns are case-sensitive by default
		
		XCTAssertTrue(isIgnored(["test.txt"], path: "test.txt"))
		XCTAssertFalse(isIgnored(["test.txt"], path: "Test.txt"))
		XCTAssertFalse(isIgnored(["test.txt"], path: "TEST.TXT"))
		
		XCTAssertTrue(isIgnored(["*.TXT"], path: "file.TXT"))
		XCTAssertFalse(isIgnored(["*.TXT"], path: "file.txt"))
	}
	
	func testSpecialPatternCombinations() {
		// Test some tricky pattern combinations
		
		// Negating a directory should un-ignore its contents
		let patterns1 = ["build/", "!build/keep/"]
		XCTAssertTrue(isIgnored(patterns1, path: "build/temp.txt"))
		XCTAssertFalse(isIgnored(patterns1, path: "build/keep/important.txt"))
		
		// Wildcards in directory patterns
		let patterns2 = ["temp-*/", "!temp-*/important.txt"]
		XCTAssertTrue(isIgnored(patterns2, path: "temp-123/file.txt"))
		XCTAssertTrue(isIgnored(patterns2, path: "temp-abc/other.txt"))
		XCTAssertFalse(isIgnored(patterns2, path: "temp-123/important.txt"))
		XCTAssertFalse(isIgnored(patterns2, path: "temp-abc/important.txt"))
		
		// Multiple levels of negation
		let patterns3 = ["*", "!*.txt", "temp-*.txt", "!temp-important-*.txt"]
		XCTAssertTrue(isIgnored(patterns3, path: "file.doc"))
		XCTAssertFalse(isIgnored(patterns3, path: "file.txt"))
		XCTAssertTrue(isIgnored(patterns3, path: "temp-123.txt"))
		XCTAssertFalse(isIgnored(patterns3, path: "temp-important-456.txt"))
	}
}
