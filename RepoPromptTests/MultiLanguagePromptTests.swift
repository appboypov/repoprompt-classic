//
//  MultiLanguagePromptTests.swift
//  RepoPromptTests
//
//  Created by Assistant on 2025-01-14.
//

import XCTest
@testable import RepoPrompt

class MultiLanguagePromptTests: XCTestCase {
	
	func testScopeMarkerPatterns() {
		// NOTE: The patterns produced by DiffParserUtils escape "//" ➜ "\/\/"
		let testCases: [(language: String, expectedPrefix: String)] = [
			("swift",      #"^\s*\/\/\s*REPOMARK:SCOPE:\s*(\d+)"#),
			("javascript", #"^\s*\/\/\s*REPOMARK:SCOPE:\s*(\d+)"#),
			("python",     #"^\s*#\s*REPOMARK:SCOPE:\s*(\d+)"#),
			("ruby",       #"^\s*#\s*REPOMARK:SCOPE:\s*(\d+)"#),
			("java",       #"^\s*\/\/\s*REPOMARK:SCOPE:\s*(\d+)"#),
			("c",          #"^\s*\/\/\s*REPOMARK:SCOPE:\s*(\d+)"#),
			("unknown",    #"^\s*\/\/\s*REPOMARK:SCOPE:\s*(\d+)"#)
		]
		
		for (language, expectedPrefix) in testCases {
			let pattern = DiffParserUtils.scopeMarkerPattern(for: language)
			let expectedFullPattern = expectedPrefix + #"\s*-\s*(.+)$"#
			XCTAssertEqual(pattern, expectedFullPattern, "Pattern mismatch for language: \(language)")
		}
	}
	
	func testScopeBasedParsing() {
		// Test Swift scope parsing
		let swiftContent = """
		// REPOMARK:SCOPE: 1 - First test function
		func test() {
			print("Hello")
		}
		
		// ... existing code ...
		
		// REPOMARK:SCOPE: 2 - Second test function
		func test2() {
			print("World")
		}
		"""
		
		let swiftScopes = DiffParserUtils.parseScopeBasedDelegateEdit(swiftContent, language: "swift")
		
		// Add safety checks
		if swiftScopes.isEmpty {
			XCTFail("Swift scope parsing returned empty array")
			return
		}
		
		XCTAssertEqual(swiftScopes.count, 2, "Expected 2 Swift scopes but got \(swiftScopes.count)")
		
		if swiftScopes.count >= 1 {
			XCTAssertEqual(swiftScopes[0].scopeNumber, 1)
			XCTAssertTrue(swiftScopes[0].content.contains("func test()"))
		}
		
		if swiftScopes.count >= 2 {
			XCTAssertEqual(swiftScopes[1].scopeNumber, 2)
			XCTAssertTrue(swiftScopes[1].content.contains("func test2()"))
		}
		
		// Test Python scope parsing
		let pythonContent = """
		# REPOMARK:SCOPE: 1 - First Python function
		def test():
			print("Hello")
		
		# ... existing code ...
		
		# REPOMARK:SCOPE: 2 - Second Python function
		def test2():
			print("World")
		"""
		
		let pythonScopes = DiffParserUtils.parseScopeBasedDelegateEdit(pythonContent, language: "python")
		
		// Add safety checks for Python
		if pythonScopes.isEmpty {
			XCTFail("Python scope parsing returned empty array")
			return
		}
		
		XCTAssertEqual(pythonScopes.count, 2, "Expected 2 Python scopes but got \(pythonScopes.count)")
		
		if pythonScopes.count >= 1 {
			XCTAssertEqual(pythonScopes[0].scopeNumber, 1)
			XCTAssertTrue(pythonScopes[0].content.contains("def test():"))
		}
		
		if pythonScopes.count >= 2 {
			XCTAssertEqual(pythonScopes[1].scopeNumber, 2)
			XCTAssertTrue(pythonScopes[1].content.contains("def test2():"))
		}
	}
	
	func testPromptFactoryLanguageSelection() {
		// Test Swift selection
		let swiftConfig = PromptConfig(
			role: .codeAssistant,
			canCreate: true,
			canRewrite: true,
			canSearchReplace: true,
			canDelete: true,
			canDelegateEdit: true,
			supportsRename: true,
			language: "Swift",
			fileExtension: "swift",
			codeBlockFence: "```",
			includeIndentationEncoding: false,
			includeEscapingRules: false
		)
		
		let swiftPrompt = PromptFactory.buildPrompt(with: swiftConfig)
		XCTAssertTrue(swiftPrompt.contains("struct User"))
		XCTAssertTrue(swiftPrompt.contains("// REPOMARK:SCOPE:"))
		
		// Test JavaScript selection
		let jsConfig = PromptConfig(
			role: .codeAssistant,
			canCreate: true,
			canRewrite: true,
			canSearchReplace: true,
			canDelete: true,
			canDelegateEdit: true,
			supportsRename: true,
			language: "JavaScript",
			fileExtension: "js",
			codeBlockFence: "```",
			includeIndentationEncoding: false,
			includeEscapingRules: false
		)
		
		let jsPrompt = PromptFactory.buildPrompt(with: jsConfig)
		XCTAssertTrue(jsPrompt.contains("class User"))
		XCTAssertTrue(jsPrompt.contains("constructor"))
		XCTAssertTrue(jsPrompt.contains("// REPOMARK:SCOPE:"))
		
		// Test Python selection
		let pyConfig = PromptConfig(
			role: .codeAssistant,
			canCreate: true,
			canRewrite: true,
			canSearchReplace: true,
			canDelete: true,
			canDelegateEdit: true,
			supportsRename: true,
			language: "Python",
			fileExtension: "py",
			codeBlockFence: "```",
			includeIndentationEncoding: false,
			includeEscapingRules: false
		)
		
		let pyPrompt = PromptFactory.buildPrompt(with: pyConfig)
		XCTAssertTrue(pyPrompt.contains("class User:"))
		XCTAssertTrue(pyPrompt.contains("def __init__"))
		XCTAssertTrue(pyPrompt.contains("# REPOMARK:SCOPE:"))
	}
	
	func testPredominantLanguageDetection() {
		// Test language detection based on file paths
		
		// Test with no files - should return default
		let files1: Set<String> = []
		let (lang1, ext1) = detectPredominantLanguage(from: files1)
		XCTAssertEqual(lang1, "JavaScript") // default
		XCTAssertEqual(ext1, "js")
		
		// Test with Swift files
		let files2: Set<String> = [
			"/path/to/file1.swift",
			"/path/to/file2.swift"
		]
		let (lang2, ext2) = detectPredominantLanguage(from: files2)
		XCTAssertEqual(lang2, "Swift")
		XCTAssertEqual(ext2, "swift")
		
		// Test with mixed files - more Python files
		let files3: Set<String> = [
			"/path/to/file1.swift",
			"/path/to/script1.py",
			"/path/to/script2.py",
			"/path/to/script3.py"
		]
		let (lang3, ext3) = detectPredominantLanguage(from: files3)
		XCTAssertEqual(lang3, "Python")
		XCTAssertEqual(ext3, "py")
		
		// Test with various file types
		let files4: Set<String> = [
			"/path/to/app.js",
			"/path/to/component.tsx",
			"/path/to/server.ts",
			"/path/to/style.css"
		]
		let (lang4, ext4) = detectPredominantLanguage(from: files4)
		
		// Any of these may be selected when counts tie.
		XCTAssertTrue(["JavaScript", "TypeScript", "CSS"].contains(lang4))
		XCTAssertTrue(["js", "ts", "tsx", "css"].contains(ext4))
	}
	
	// Helper function to simulate predominant language detection
	private func detectPredominantLanguage(from filePaths: Set<String>) -> (String, String) {
		guard !filePaths.isEmpty else {
			return ("JavaScript", "js") // default
		}
		
		// Count extensions
		var extensionCounts: [String: Int] = [:]
		for path in filePaths {
			let ext = (path as NSString).pathExtension.lowercased()
			extensionCounts[ext, default: 0] += 1
		}
		
		// Find most common extension
		guard let mostCommon = extensionCounts.max(by: { $0.value < $1.value }) else {
			return ("JavaScript", "js")
		}
		
		// Map extension to language
		let languageMap: [String: (String, String)] = [
			"swift": ("Swift", "swift"),
			"py": ("Python", "py"),
			"js": ("JavaScript", "js"),
			"ts": ("TypeScript", "ts"),
			"tsx": ("TypeScript", "tsx"),
			"rb": ("Ruby", "rb"),
			"go": ("Go", "go"),
			"java": ("Java", "java"),
			"c": ("C", "c"),
			"cpp": ("C++", "cpp"),
			"rs": ("Rust", "rs"),
			"php": ("PHP", "php"),
			"cs": ("C#", "cs"),
			"m": ("Objective-C", "m"),
			"mm": ("Objective-C++", "mm"),
			"kt": ("Kotlin", "kt"),
			"scala": ("Scala", "scala"),
			"r": ("R", "r"),
			"dart": ("Dart", "dart"),
			"lua": ("Lua", "lua"),
			"perl": ("Perl", "pl"),
			"sh": ("Shell", "sh"),
			"bash": ("Bash", "bash"),
			"sql": ("SQL", "sql"),
			"html": ("HTML", "html"),
			"css": ("CSS", "css"),
			"xml": ("XML", "xml"),
			"json": ("JSON", "json"),
			"yaml": ("YAML", "yaml"),
			"yml": ("YAML", "yml"),
			"toml": ("TOML", "toml"),
			"md": ("Markdown", "md")
		]
		
		return languageMap[mostCommon.key] ?? ("JavaScript", "js")
	}
	
	func testCommentStyleMapping() {
		// Verify comment styles are correctly mapped
		XCTAssertEqual(DiffParserUtils.commentStyles["python"], "#")
		XCTAssertEqual(DiffParserUtils.commentStyles["py"], "#")
		XCTAssertEqual(DiffParserUtils.commentStyles["ruby"], "#")
		XCTAssertEqual(DiffParserUtils.commentStyles["swift"], "//")
		XCTAssertEqual(DiffParserUtils.commentStyles["javascript"], "//")
		XCTAssertEqual(DiffParserUtils.commentStyles["java"], "//")
		XCTAssertEqual(DiffParserUtils.commentStyles["shell"], "#")
	}
}
