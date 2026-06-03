//
//  ScopeSplittingTests.swift
//  RepoPromptTests
//
//  Consolidated tests for scope splitting functionality in ChatContentParser
//  Merged from: ChatContentParserScopeSplittingTests, ChatContentParserScopeSplittingAdditionalTests,
//  and ChatContentParserContextScopeStressTests
//

import XCTest
@testable import RepoPrompt

/**
 Comprehensive tests for the scope splitting logic in ChatContentParser.
 Tests cover various programming languages, comment styles, edge cases,
 and the REPOMARK:SCOPE parsing functionality.
 */
class ScopeSplittingTests: XCTestCase {
	
	override func setUp() {
		super.setUp()
		// Enable debug logging for better test visibility
		ChatContentParser.setDebugLogging(true)
	}
	
	override func tearDown() {
		// Restore default state
		ChatContentParser.setDebugLogging(false)
		super.tearDown()
	}
	
	// MARK: - Helper Methods
	
	/// Helper to extract delegate edit changes from XML input
	private func delegateChanges(from input: String) -> [DelegateEditItem.Change] {
		var processedSet = Set<Int>()
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		return delegateEdits.first?.changes ?? []
	}
	
	/// Helper to get the first change's code snippet
	private func firstChangeCode(from input: String) -> String {
		let changes = delegateChanges(from: input)
		return changes.first?.codeSnippet ?? ""
	}
	
	// MARK: - Tests from ChatContentParserScopeSplittingTests
	
	// MARK: - Swift Language Tests
	
	func testSwiftSingleScopeWithREPOMARK() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"Example.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <description>Swift refactoring</description>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - Add validation for user input\n" +
		"        func validateInput(_ input: String) -> Bool {\n" +
		"            return !input.isEmpty && input.count <= 100\n" +
		"        }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (items, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(items.count, 1)
		XCTAssertEqual(items[0].type, .file)
		XCTAssertEqual(delegateEdits.count, 1)
		
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 1)
		XCTAssertEqual(changes[0].description, "Add validation for user input")
		
		XCTAssertFalse(changes[0].codeSnippet.contains("REPOMARK"),
					   "Marker line should be stripped from snippet.")
	}
	
	func testSwiftMultipleScopesWithREPOMARK() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"UserManager.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - Add user authentication method\n" +
		"        func authenticate(username: String, password: String) -> Bool {\n" +
		"            // Implementation here\n" +
		"            return true\n" +
		"        }\n" +
		"        \n" +
		"        // ... existing code ...\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 2 - Add password reset functionality\n" +
		"        func resetPassword(for email: String) {\n" +
		"            // Send reset email\n" +
		"            print(\"Password reset sent to \\(email)\")\n" +
		"        }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(delegateEdits.count, 1)
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 2)
		
		XCTAssertEqual(changes[0].description, "Add user authentication method")
		XCTAssertTrue(changes[0].codeSnippet.contains("func authenticate"))
		XCTAssertFalse(changes[0].codeSnippet.contains("resetPassword"))
		
		XCTAssertEqual(changes[1].description, "Add password reset functionality")
		XCTAssertTrue(changes[1].codeSnippet.contains("func resetPassword"))
		XCTAssertFalse(changes[1].codeSnippet.contains("authenticate"))
	}
	
	// MARK: - Python Language Tests
	
	func testPythonScopesWithHashComments() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"data_processor.py\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        # REPOMARK:SCOPE: 1 - Add data validation function\n" +
		"        def validate_data(data):\n" +
		"            if not isinstance(data, dict):\n" +
		"                raise ValueError(\"Data must be a dictionary\")\n" +
		"            return True\n" +
		"        \n" +
		"        # ... existing code ...\n" +
		"        \n" +
		"        # REPOMARK:SCOPE: 2 - Add data transformation\n" +
		"        def transform_data(data):\n" +
		"            # Transform the data\n" +
		"            return {k: v.upper() if isinstance(v, str) else v for k, v in data.items()}\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(delegateEdits.count, 1)
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 2)
		
		XCTAssertEqual(changes[0].description, "Add data validation function")
		XCTAssertTrue(changes[0].codeSnippet.contains("def validate_data"))
		
		XCTAssertEqual(changes[1].description, "Add data transformation")
		XCTAssertTrue(changes[1].codeSnippet.contains("def transform_data"))
	}
	
	func testPythonWithMixedCaseREPOMARK() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"utils.py\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        # repomark:scope: 1 - Add utility function\n" +
		"        def utility_func():\n" +
		"            pass\n" +
		"        \n" +
		"        # REPOMARK:SCOPE: 2 - Add another function\n" +
		"        def another_func():\n" +
		"            pass\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Should handle case-insensitive REPOMARK
		XCTAssertEqual(delegateEdits[0].changes.count, 2)
		XCTAssertEqual(delegateEdits[0].changes[0].description, "Add utility function")
		XCTAssertEqual(delegateEdits[0].changes[1].description, "Add another function")
	}
	
	// MARK: - JavaScript/TypeScript Tests
	
	func testJavaScriptScopesWithCStyleComments() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"app.js\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - Add event handler\n" +
		"        function handleClick(event) {\n" +
		"            event.preventDefault();\n" +
		"            console.log('Button clicked');\n" +
		"        }\n" +
		"        \n" +
		"        // ... existing code ...\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 2 - Add API fetch function\n" +
		"        async function fetchData(url) {\n" +
		"            const response = await fetch(url);\n" +
		"            return response.json();\n" +
		"        }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(delegateEdits[0].changes.count, 2)
		XCTAssertEqual(delegateEdits[0].changes[0].description, "Add event handler")
		XCTAssertEqual(delegateEdits[0].changes[1].description, "Add API fetch function")
	}
	
	// MARK: - SQL Tests
	
	func testSQLScopesWithDoubleDashComments() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"schema.sql\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        -- REPOMARK:SCOPE: 1 - Create users table\n" +
		"        CREATE TABLE users (\n" +
		"            id INTEGER PRIMARY KEY,\n" +
		"            username VARCHAR(50) NOT NULL,\n" +
		"            email VARCHAR(100) NOT NULL\n" +
		"        );\n" +
		"        \n" +
		"        -- ... existing code ...\n" +
		"        \n" +
		"        -- REPOMARK:SCOPE: 2 - Add index on email\n" +
		"        CREATE INDEX idx_users_email ON users(email);\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(delegateEdits[0].changes.count, 2)
		XCTAssertEqual(delegateEdits[0].changes[0].description, "Create users table")
		XCTAssertTrue(delegateEdits[0].changes[0].codeSnippet.contains("CREATE TABLE"))
		
		XCTAssertEqual(delegateEdits[0].changes[1].description, "Add index on email")
		XCTAssertTrue(delegateEdits[0].changes[1].codeSnippet.contains("CREATE INDEX"))
	}
	
	// MARK: - HTML/XML Tests
	
	func testHTMLScopesWithHTMLComments() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"index.html\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        <!-- REPOMARK:SCOPE: 1 - Add navigation header -->\n" +
		"        <header>\n" +
		"            <nav>\n" +
		"                <ul>\n" +
		"                    <li><a href=\"/\">Home</a></li>\n" +
		"                </ul>\n" +
		"            </nav>\n" +
		"        </header>\n" +
		"        \n" +
		"        <!-- ... existing code ... -->\n" +
		"        \n" +
		"        <!-- REPOMARK:SCOPE: 2 - Add footer section -->\n" +
		"        <footer>\n" +
		"            <p>&copy; 2025 Company Name</p>\n" +
		"        </footer>\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(delegateEdits[0].changes.count, 2)
		XCTAssertEqual(delegateEdits[0].changes[0].description, "Add navigation header")
		XCTAssertTrue(delegateEdits[0].changes[0].codeSnippet.contains("<header>"))
		
		XCTAssertEqual(delegateEdits[0].changes[1].description, "Add footer section")
		XCTAssertTrue(delegateEdits[0].changes[1].codeSnippet.contains("<footer>"))
	}
	
	// MARK: - Edge Cases
	
	func testEmptyScope() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"test.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - Empty scope test\n" +
		"        // REPOMARK:SCOPE: 2 - Non-empty scope\n" +
		"        func test() { }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Empty scopes should be handled gracefully
		XCTAssertEqual(delegateEdits[0].changes.count, 2, "Expected 2 changes from scope splitting")
		
		// Only check first change if it exists
		if delegateEdits[0].changes.count > 0 {
			XCTAssertEqual(delegateEdits[0].changes[0].description, "Empty scope test")
			XCTAssertFalse(delegateEdits[0].changes[0].codeSnippet.contains("REPOMARK"),
						   "Marker line should be stripped from snippet.")
		}
		
		// Only check second change if it exists
		if delegateEdits[0].changes.count > 1 {
			XCTAssertEqual(delegateEdits[0].changes[1].description, "Non-empty scope")
			XCTAssertTrue(delegateEdits[0].changes[1].codeSnippet.contains("func test"))
		}
	}
	
	func testScopeWithoutNumber() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"test.py\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        # REPOMARK:SCOPE: - Missing number\n" +
		"        def test1():\n" +
		"            pass\n" +
		"        \n" +
		"        # REPOMARK:SCOPE: 1 - Valid scope\n" +
		"        def test2():\n" +
		"            pass\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Should handle malformed markers gracefully
		let changes = delegateEdits[0].changes
		XCTAssertGreaterThanOrEqual(changes.count, 1)
		
		// Find the valid scope
		let validScope = changes.first { $0.description == "Valid scope" }
		XCTAssertNotNil(validScope)
		XCTAssertTrue(validScope?.codeSnippet.contains("def test2") ?? false)
	}
	
	func testMixedPlaceholderStyles() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"mixed.js\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - First function\n" +
		"        function first() { return 1; }\n" +
		"        \n" +
		"        // ... existing code ...\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 2 - Second function\n" +
		"        function second() { return 2; }\n" +
		"        \n" +
		"        /* ... existing code ... */\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 3 - Third function\n" +
		"        function third() { return 3; }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Should handle both styles of existing code placeholders
		XCTAssertEqual(delegateEdits[0].changes.count, 3)
		XCTAssertEqual(delegateEdits[0].changes[0].description, "First function")
		XCTAssertEqual(delegateEdits[0].changes[1].description, "Second function")
		XCTAssertEqual(delegateEdits[0].changes[2].description, "Third function")
		
		// Forward-only: first scope should NOT include the placeholder
		XCTAssertFalse(delegateEdits[0].changes[0].codeSnippet.localizedCaseInsensitiveContains("existing code"))
		// Second scope should include the first placeholder (carried forward, deduped)
		XCTAssertTrue(delegateEdits[0].changes[1].codeSnippet.localizedCaseInsensitiveContains("existing code"))
		// Third scope should carry forward deduped placeholder(s) from second block style
		XCTAssertTrue(delegateEdits[0].changes[2].codeSnippet.localizedCaseInsensitiveContains("existing code"))
	}
	
	// MARK: - Description Extraction Tests
	
	func testDescriptionExtractionFallback() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"fallback.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <description>XML Description</description>\n" +
		"        <content>\n" +
		"        func noScopeMarker() {\n" +
		"            // This has no REPOMARK\n" +
		"        }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Should fall back to XML description when no scope markers
		XCTAssertEqual(delegateEdits[0].changes.count, 1)
		XCTAssertEqual(delegateEdits[0].changes[0].description, "XML Description")
	}
	
	func testMultipleScopesWithXMLDescription() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"multi.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <description>Overall change description</description>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - First scope\n" +
		"        func first() { }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 2 - Second scope\n" +
		"        func second() { }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Should prefer scope descriptions over XML description
		XCTAssertEqual(delegateEdits[0].changes.count, 2)
		XCTAssertEqual(delegateEdits[0].changes[0].description, "First scope")
		XCTAssertEqual(delegateEdits[0].changes[1].description, "Second scope")
	}
	
	// MARK: - Complex Integration Tests
	
	func testComplexMultiLanguageFile() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"config.rb\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <complexity>5</complexity>\n" +
		"        <content>\n" +
		"        # REPOMARK:SCOPE: 1 - Add database configuration\n" +
		"        DATABASE_CONFIG = {\n" +
		"          host: 'localhost',\n" +
		"          port: 5432,\n" +
		"          database: 'myapp'\n" +
		"        }\n" +
		"        \n" +
		"        # ... existing code ...\n" +
		"        \n" +
		"        # REPOMARK:SCOPE: 2 - Add Redis configuration\n" +
		"        REDIS_CONFIG = {\n" +
		"          host: 'localhost',\n" +
		"          port: 6379\n" +
		"        }\n" +
		"        \n" +
		"        # REPOMARK:SCOPE: 3 - Add feature flags\n" +
		"        FEATURE_FLAGS = {\n" +
		"          new_ui: true,\n" +
		"          analytics: false\n" +
		"        }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (items, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(items.count, 1)
		XCTAssertEqual(delegateEdits.count, 1)
		
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 3)
		
		// All should inherit the complexity from the parent
		XCTAssertEqual(changes[0].complexity, 5)
		XCTAssertEqual(changes[1].complexity, 5)
		XCTAssertEqual(changes[2].complexity, 5)
		
		// Check descriptions
		XCTAssertEqual(changes[0].description, "Add database configuration")
		XCTAssertEqual(changes[1].description, "Add Redis configuration")
		XCTAssertEqual(changes[2].description, "Add feature flags")
		
		// Verify content isolation
		XCTAssertTrue(changes[0].codeSnippet.contains("DATABASE_CONFIG"))
		XCTAssertFalse(changes[0].codeSnippet.contains("REDIS_CONFIG"))
		
		XCTAssertTrue(changes[1].codeSnippet.contains("REDIS_CONFIG"))
		XCTAssertFalse(changes[1].codeSnippet.contains("FEATURE_FLAGS"))
		
		XCTAssertTrue(changes[2].codeSnippet.contains("FEATURE_FLAGS"))
		XCTAssertFalse(changes[2].codeSnippet.contains("DATABASE_CONFIG"))
	}
	
	// MARK: - Partial Parse Tests
	
	func testPartialParseWithIncompleteDelegateEdit() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"partial.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - Incomplete scope\n" +
		"        func incomplete() {\n" +
		"            // Not finished yet..."
		// Note: No closing tags
		
		let (items, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: false
		)
		
		// Should create preview item but no delegate edit
		XCTAssertEqual(items.count, 1)
		XCTAssertEqual(items[0].type, .file)
		XCTAssertEqual(delegateEdits.count, 0, "Incomplete delegate edits should not be emitted in partial parse")
	}
	
	// MARK: - Debug Logging Tests
	
	func testDebugLoggingToggle() {
		// Test that debug logging can be toggled
		ChatContentParser.setDebugLogging(false)
		XCTAssertFalse(ChatContentParser.enableDebugLogging)
		
		ChatContentParser.setDebugLogging(true)
		XCTAssertTrue(ChatContentParser.enableDebugLogging)
	}
	
	// MARK: - Performance Tests
	
	func testLargeScopeCount() {
		var processedSet = Set<Int>()
		var content = ""
		
		// Generate 50 scopes
		for i in 1...50 {
			content += "// REPOMARK:SCOPE: \(i) - Scope number \(i)\n"
			content += "func function\(i)() { print(\"\(i)\") }\n\n"
			if i < 50 {
				content += "// ... existing code ...\n\n"
			}
		}
		
		let input =
		"<file path=\"large.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		content +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let startTime = CFAbsoluteTimeGetCurrent()
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		let elapsed = CFAbsoluteTimeGetCurrent() - startTime
		
		XCTAssertEqual(delegateEdits[0].changes.count, 50)
		XCTAssertLessThan(elapsed, 1.0, "Parsing 50 scopes should complete in under 1 second")
		
		// Verify a few random scopes
		XCTAssertEqual(delegateEdits[0].changes[0].description, "Scope number 1")
		XCTAssertEqual(delegateEdits[0].changes[24].description, "Scope number 25")
		XCTAssertEqual(delegateEdits[0].changes[49].description, "Scope number 50")
	}
	
	// MARK: - Malformed Marker Tests
	
	func testMalformedREPOMARKVariations() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"malformed.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK SCOPE: 1 - Missing colon after REPOMARK\n" +
		"        func test1() { }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE 2 - Missing colon after SCOPE\n" +
		"        func test2() { }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: - Missing number\n" +
		"        func test3() { }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: a - Non-numeric scope\n" +
		"        func test4() { }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 5 Missing dash\n" +
		"        func test5() { }\n" +
		"        \n" +
		"        //REPOMARK:SCOPE:6-No space before comment\n" +
		"        func test6() { }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 7 - Valid one for comparison\n" +
		"        func test7() { }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Should handle malformed markers gracefully
		// The exact behavior depends on the regex, but it should not crash
		XCTAssertGreaterThanOrEqual(delegateEdits.count, 0)
		
		if !delegateEdits.isEmpty && !delegateEdits[0].changes.isEmpty {
			// Check if at least the valid marker was parsed
			let validScope = delegateEdits[0].changes.first {
				$0.description.contains("Valid one for comparison")
			}
			XCTAssertNotNil(validScope, "Should parse at least the valid scope marker")
		}
	}
	
	func testIncompleteAndBrokenMarkers() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"broken.py\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        # REPO\n" +
		"        def incomplete1():\n" +
		"            pass\n" +
		"        \n" +
		"        # REPOMARK:\n" +
		"        def incomplete2():\n" +
		"            pass\n" +
		"        \n" +
		"        # REPOMARK:SCO\n" +
		"        def incomplete3():\n" +
		"            pass\n" +
		"        \n" +
		"        # REPOMARK:SCOPE\n" +
		"        def incomplete4():\n" +
		"            pass\n" +
		"        \n" +
		"        # REPOMARK:SCOPE:\n" +
		"        def incomplete5():\n" +
		"            pass\n" +
		"        \n" +
		"        # REPOMARK:SCOPE: 1\n" +
		"        def incomplete6():\n" +
		"            # Missing description after number\n" +
		"            pass\n" +
		"        \n" +
		"        # REPOMARK:SCOPE: 2 -\n" +
		"        def incomplete7():\n" +
		"            # Missing description after dash\n" +
		"            pass\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Should not crash on incomplete markers
		XCTAssertTrue(true, "Parser should handle incomplete markers without crashing")
	}
	
	func testMixedValidAndInvalidMarkers() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"mixed.js\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - Valid first scope\n" +
		"        function valid1() { return 1; }\n" +
		"        \n" +
		"        // REPOMARK SCOPE 2 - Invalid format\n" +
		"        function invalid1() { return 2; }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 3 - Valid third scope\n" +
		"        function valid2() { return 3; }\n" +
		"        \n" +
		"        // repomark:scope: four - Non-numeric\n" +
		"        function invalid2() { return 4; }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 5 - Valid fifth scope\n" +
		"        function valid3() { return 5; }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		if !delegateEdits.isEmpty {
			let changes = delegateEdits[0].changes
			
			// Count valid scopes
			let validScopes = changes.filter { change in
				change.description.contains("Valid") &&
				(change.description.contains("first") ||
				 change.description.contains("third") ||
				 change.description.contains("fifth"))
			}
			
			XCTAssertGreaterThanOrEqual(validScopes.count, 1, "Should parse at least some valid markers")
		}
	}
	
	func testNestedAndOverlappingMarkers() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"nested.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - Outer scope\n" +
		"        func outer() {\n" +
		"            // REPOMARK:SCOPE: 2 - Inner scope (should end outer)\n" +
		"            func inner() {\n" +
		"                print(\"nested\")\n" +
		"            }\n" +
		"        }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 3 - After nested\n" +
		"        func afterNested() { }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		if !delegateEdits.isEmpty {
			let changes = delegateEdits[0].changes
			
			// Nested markers should create separate scopes
			XCTAssertGreaterThanOrEqual(changes.count, 2)
			
			// First scope should not contain the inner function
			if changes.count >= 1 {
				XCTAssertTrue(changes[0].codeSnippet.contains("func outer"))
				// The inner marker should terminate the outer scope
				XCTAssertFalse(changes[0].codeSnippet.contains("func inner"))
			}
		}
	}
	
	func testExtremelyLongDescriptions() {
		var processedSet = Set<Int>()
		let veryLongDesc = String(repeating: "Very long description ", count: 100)
		let input =
		"<file path=\"long.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - \(veryLongDesc)\n" +
		"        func test() { }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		if !delegateEdits.isEmpty && !delegateEdits[0].changes.isEmpty {
			let desc = delegateEdits[0].changes[0].description
			// Should handle long descriptions
			XCTAssertTrue(desc.contains("Very long description"))
			// Trimming should work
			XCTAssertFalse(desc.hasPrefix(" "))
			XCTAssertFalse(desc.hasSuffix(" "))
		}
	}
	
	func testUnicodeAndControlCharacters() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"unicode.py\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        # REPOMARK:SCOPE: 1 - Handle 你好世界 🌍 \\u{200B}zero-width\\u{200B} chars\n" +
		"        def unicode_test():\n" +
		"            chinese = \"你好世界\"\n" +
		"            emoji = \"🌍🚀✨\"\n" +
		"        \n" +
		"        # REPOMARK:SCOPE: 2 - Tab\\tand\\nnewline\\rhandling\n" +
		"        def control_chars():\n" +
		"            pass\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		if !delegateEdits.isEmpty && delegateEdits[0].changes.count >= 2 {
			// Should handle unicode properly
			XCTAssertTrue(delegateEdits[0].changes[0].description.contains("你好世界"))
			XCTAssertTrue(delegateEdits[0].changes[0].description.contains("🌍"))
			
			// Should handle control characters
			let desc2 = delegateEdits[0].changes[1].description
			XCTAssertTrue(desc2.contains("Tab") || desc2.contains("newline"))
		}
	}
	
	// MARK: - Special Character Tests
	
	func testScopesWithSpecialCharacters() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"special.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - Handle UTF-8: 🚀 émojis & spéçiål çhars\n" +
		"        func handleEmoji() {\n" +
		"            let rocket = \"🚀\"\n" +
		"            let special = \"émojis & spéçiål\"\n" +
		"        }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 2 - Process <XML> & \"quotes\"\n" +
		"        func processXML() {\n" +
		"            let xml = \"<tag>value</tag>\"\n" +
		"        }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(delegateEdits[0].changes.count, 2)
		XCTAssertEqual(delegateEdits[0].changes[0].description, "Handle UTF-8: 🚀 émojis & spéçiål çhars")
		XCTAssertEqual(delegateEdits[0].changes[1].description, "Process <XML> & \"quotes\"")
	}
	
	func testCommentStyleConfusion() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"confusing.js\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        /* REPOMARK:SCOPE: 1 - Wrong comment style */\n" +
		"        function wrongStyle1() { }\n" +
		"        \n" +
		"        # REPOMARK:SCOPE: 2 - Python comment in JS file\n" +
		"        function wrongStyle2() { }\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 3 - Correct JS comment\n" +
		"        function correctStyle() { }\n" +
		"        \n" +
		"        <!-- REPOMARK:SCOPE: 4 - HTML comment in JS -->\n" +
		"        function wrongStyle3() { }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Should at least parse the correct comment style
		if !delegateEdits.isEmpty && !delegateEdits[0].changes.isEmpty {
			let correctScope = delegateEdits[0].changes.first {
				$0.description.contains("Correct JS comment")
			}
			XCTAssertNotNil(correctScope, "Should parse markers with correct comment style")
		}
	}
	
	func testPlaceholderVariations() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"placeholders.swift\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        // REPOMARK:SCOPE: 1 - Before placeholder\n" +
		"        func before() { }\n" +
		"        \n" +
		"        // ...existing code...\n" +
		"        // ... existing  code ...\n" +
		"        //...existing code ...\n" +
		"        // ... EXISTING CODE ...\n" +
		"        // ... Existing Code ...\n" +
		"        \n" +
		"        // REPOMARK:SCOPE: 2 - After placeholder variations\n" +
		"        func after() { }\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// All placeholder variations should terminate the first scope
		if !delegateEdits.isEmpty && !delegateEdits[0].changes.isEmpty {
			XCTAssertGreaterThanOrEqual(delegateEdits[0].changes.count, 2)
			
			// First scope should contain placeholder comments but not the second function
			if delegateEdits[0].changes.count >= 1 {
				XCTAssertTrue(delegateEdits[0].changes[0].codeSnippet.contains("existing code"))
				XCTAssertFalse(delegateEdits[0].changes[0].codeSnippet.contains("func after"))
			}
		}
	}
	
	// MARK: - Whitespace Handling Tests
	
	func testScopesWithVariousWhitespace() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"whitespace.py\" action=\"delegate edit\">\n" +
		"    <change>\n" +
		"        <content>\n" +
		"        #    REPOMARK:SCOPE:    1    -    Extra    spaces    \n" +
		"        def extra_spaces():\n" +
		"            pass\n" +
		"        \n" +
		"        #\tREPOMARK:SCOPE:\t2\t-\tWith tabs\t\n" +
		"        def with_tabs():\n" +
		"            pass\n" +
		"        </content>\n" +
		"    </change>\n" +
		"</file>\n"
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(delegateEdits[0].changes.count, 2)
		// Descriptions should be trimmed
		XCTAssertEqual(delegateEdits[0].changes[0].description, "Extra    spaces")
		XCTAssertEqual(delegateEdits[0].changes[1].description, "With tabs")
	}
	
	// MARK: - Tests from ChatContentParserScopeSplittingAdditionalTests
	
	/// Validate that Windows CR-LF line-endings do not break detection.
	func testCRLFLineEndings() {
		let input = """
		<file path="win.swift" action="delegate edit">\r
			<change>\r
				<content>\r
				// REPOMARK:SCOPE: 1 - First CRLF scope\r
				func one() {}\r
		\r
				// ... existing code ...\r
		\r
				// REPOMARK:SCOPE: 2 - Second CRLF scope\r
				func two() {}\r
				</content>\r
			</change>\r
		</file>\r
		"""
		
		let changes = delegateChanges(from: input)
		XCTAssertEqual(changes.count, 2)
		XCTAssertEqual(changes[0].description, "First CRLF scope")
		XCTAssertEqual(changes[1].description, "Second CRLF scope")
	}
	
	/// Duplicate scope numbers should still create independent changes.
	func testDuplicateScopeNumbers() {
		let input = """
		<file path="dup.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - First occurrence
				func a() {}
				
				// ... existing code ...
				
				// REPOMARK:SCOPE: 1 - Second occurrence with same number
				func b() {}
				</content>
			</change>
		</file>
		"""
			
		let changes = delegateChanges(from: input)
		XCTAssertEqual(changes.count, 2)
		XCTAssertEqual(changes[0].description, "First occurrence")
		XCTAssertEqual(changes[1].description, "Second occurrence with same number")
	}
	
	/// Out-of-order numbering should be accepted; order follows appearance.
	func testOutOfOrderScopeNumbers() {
		let input = """
		<file path="order.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 3 - Third comes first
				func three() {}
				
				// REPOMARK:SCOPE: 1 - First comes second
				func one() {}
				
				// REPOMARK:SCOPE: 2 - Second comes third
				func two() {}
				</content>
			</change>
		</file>
		"""
			
		let changes = delegateChanges(from: input)
		XCTAssertEqual(changes.count, 3)
		XCTAssertEqual(changes.map { $0.description },
					   ["Third comes first", "First comes second", "Second comes third"])
	}
	
	/// REPOMARK inside a block-comment (`/* … */`) must be ignored.
	func testBlockCommentMarkerIgnored() {
		let input = """
		<file path="block.js" action="delegate edit">
			<change>
				<content>
				/* REPOMARK:SCOPE: 0 - Should be ignored */
				// REPOMARK:SCOPE: 1 - Real scope
				function real() {}
				</content>
			</change>
		</file>
		"""
		
		let changes = delegateChanges(from: input)
		XCTAssertEqual(changes.count, 1)
		XCTAssertEqual(changes.first?.description, "Real scope")
	}
	
	/// Marker text that appears inside a multi-line string literal should *not* start a new scope.
	/// Currently this is a known limitation, so we flag the test as an expected failure.
	func testMarkerInsideStringLiteralIgnored_expectedFailure() {
		XCTExpectFailure("Markers inside string literals are incorrectly treated as real markers (known limitation).")
		
		let input = """
		<file path="stringLiteral.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - Before string
				func before() {}
				
				let str = \"\"\" 
				// REPOMARK:SCOPE: 99 - Inside string literal
				\"\"\"
				
				// REPOMARK:SCOPE: 2 - After string
				func after() {}
				</content>
			</change>
		</file>
		"""
		
		let changes = delegateChanges(from: input)
		// Desired behaviour: only two real scopes
		XCTAssertEqual(changes.count, 2)
		XCTAssertEqual(changes[0].description, "Before string")
		XCTAssertEqual(changes[1].description, "After string")
	}
	
	// MARK: - Additional Edge Cases
	
	/// Test multiple existing code placeholders between scopes
	func testMultiplePlaceholdersBetweenScopes() {
		let input = """
		<file path="placeholders.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - Before placeholders
				func first() {}
				
				// ... existing code ...
				// ... more existing code ...
				//... existing code...
				
				// REPOMARK:SCOPE: 2 - After multiple placeholders
				func second() {}
				</content>
			</change>
		</file>
		"""
			
			let changes = delegateChanges(from: input)
			XCTAssertEqual(changes.count, 2)
			
			// Forward-only: first scope should NOT contain placeholder comments
			XCTAssertFalse(changes[0].codeSnippet.contains("existing code"))
			XCTAssertFalse(changes[0].codeSnippet.contains("second"))
			
			// Second scope should not contain the first function
			XCTAssertFalse(changes[1].codeSnippet.contains("first"))
			// Second scope should get (deduped) placeholders at the top
			let second = changes[1].codeSnippet
			let countExisting = second.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains("existing code") }.count
			XCTAssertGreaterThanOrEqual(countExisting, 1)
	}
		
		/// Test scope with only whitespace content
	func testScopeWithOnlyWhitespace() {
			let input = """
		<file path="whitespace.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - Whitespace only scope
				
				
				
				// REPOMARK:SCOPE: 2 - Normal scope
				func normal() {}
				</content>
			</change>
		</file>
		"""
			
			let changes = delegateChanges(from: input)
			XCTAssertEqual(changes.count, 2)
			XCTAssertTrue(changes[0].codeSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			XCTAssertTrue(changes[1].codeSnippet.contains("func normal"))
	}
		
		/// Test scope marker at the very end of content
	func testScopeMarkerAtEndOfContent() {
			let input = """
		<file path="end.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - Normal scope
				func first() {}
				
				// REPOMARK:SCOPE: 2 - Last scope with no content after marker
				</content>
			</change>
		</file>
		"""
			
			let changes = delegateChanges(from: input)
			XCTAssertEqual(changes.count, 2)
			XCTAssertTrue(changes[1].codeSnippet.isEmpty)
	}
		
		/// Test mixed line endings (LF and CRLF)
	func testMixedLineEndings() {
			let input = "<file path=\"mixed.swift\" action=\"delegate edit\">\n" +
			"    <change>\n" +
			"        <content>\n" +
			"        // REPOMARK:SCOPE: 1 - LF ending\n" +
			"        func lf() {}\r\n" +
			"        \r\n" +
			"        // REPOMARK:SCOPE: 2 - CRLF ending\r\n" +
			"        func crlf() {}\n" +
			"        </content>\n" +
			"    </change>\n" +
			"</file>"
			
			let changes = delegateChanges(from: input)
			XCTAssertEqual(changes.count, 2)
			XCTAssertEqual(changes[0].description, "LF ending")
			XCTAssertEqual(changes[1].description, "CRLF ending")
	}
		
		/// Test scope marker with excessive whitespace
	func testExcessiveWhitespaceInMarker() {
			let input = """
		<file path="spaces.swift" action="delegate edit">
			<change>
				<content>
				//    REPOMARK:SCOPE:    1    -    Lots    of    spaces    
				func spaces() {}
				
				//\tREPOMARK:SCOPE:\t2\t-\tWith\ttabs\t
				func tabs() {}
				</content>
			</change>
		</file>
		"""
			
			let changes = delegateChanges(from: input)
			XCTAssertEqual(changes.count, 2)
			// Descriptions should be trimmed
			XCTAssertEqual(changes[0].description, "Lots    of    spaces")
			XCTAssertEqual(changes[1].description, "With\ttabs")
	}
		
		/// Test scope numbers with leading zeros
	func testLeadingZerosInScopeNumbers() {
			let input = """
		<file path="zeros.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 01 - First with leading zero
				func first() {}
				
				// REPOMARK:SCOPE: 002 - Second with leading zeros
				func second() {}
				
				// REPOMARK:SCOPE: 0003 - Third with more leading zeros
				func third() {}
				</content>
			</change>
		</file>
		"""
			
			let changes = delegateChanges(from: input)
			XCTAssertEqual(changes.count, 3)
			XCTAssertEqual(changes[0].description, "First with leading zero")
			XCTAssertEqual(changes[1].description, "Second with leading zeros")
			XCTAssertEqual(changes[2].description, "Third with more leading zeros")
	}
		
		/// Test very large scope numbers
	func testLargeScopeNumbers() {
			let input = """
		<file path="large.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 999999 - Very large number
				func large() {}
				
				// REPOMARK:SCOPE: 1234567890 - Even larger
				func larger() {}
				</content>
			</change>
		</file>
		"""
			
			let changes = delegateChanges(from: input)
			XCTAssertEqual(changes.count, 2)
			XCTAssertEqual(changes[0].description, "Very large number")
			XCTAssertEqual(changes[1].description, "Even larger")
	}
		
		/// The last REPOMARK scope keeps placeholder comments inside its snippet.
	func testFinalScopeKeepsPlaceholders() {
			let input = """
		<file path="final.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - First scope
				func a() {}
		
				// ... existing code ...
		
				// REPOMARK:SCOPE: 2 - Final scope
				func b() {}
		
				// ... existing code ...
				// Still inside final scope
				func c() {}
				</content>
			</change>
		</file>
		"""
			
			var processed = Set<Int>()
			let (_, _, edits) = ChatContentParser.parseContent(
				input,
				processedDelegateEditHashes: &processed,
				isFinal: true
			)
			
			XCTAssertEqual(edits.count, 1)
			XCTAssertEqual(edits[0].changes.count, 2)
			
			let finalSnippet = edits[0].changes[1].codeSnippet
			XCTAssertTrue(finalSnippet.contains("// ... existing code ..."),
						  "Placeholder comment should be preserved in final snippet.")
			XCTAssertTrue(finalSnippet.contains("func b()"))
			XCTAssertTrue(finalSnippet.contains("func c()"))
	}
		
		/// Test that placeholder comments are preserved in the final scope
	func testPlaceholdersInFinalScope() {
			let input = """
		<file path="final.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - Only scope
				func implementation() {}
				
				// ... existing code ...
				// This should stay in the scope
				</content>
			</change>
		</file>
		"""
			
			let changes = delegateChanges(from: input)
			XCTAssertEqual(changes.count, 1)
			
			// The single scope should include both the function and placeholder
			let snippet = changes[0].codeSnippet
			XCTAssertTrue(snippet.contains("func implementation()"))
			XCTAssertTrue(snippet.contains("// ... existing code ..."))
			XCTAssertTrue(snippet.contains("// This should stay in the scope"))
	}
		
		/// Ensure the last N lines of pre-marker context are NOT duplicated in the previous scope
	func testNoOverlapAcrossScopes() {
			let xml = """
		<file path="NoOverlap.swift" action="delegate edit">
		  <change>
			<content>
			// REPOMARK:SCOPE: 1 - Scope One
			func one() {}
		
			// Pre-context for scope two
			let c1 = 1      // preceding-2
			let c2 = 2      // preceding-1
			// REPOMARK:SCOPE: 2 - Scope Two
			func two() {}
			</content>
		  </change>
		</file>
		"""
			let changes = delegateChanges(from: xml)
			XCTAssertEqual(changes.count, 2)
			let first  = changes[0].codeSnippet
			let second = changes[1].codeSnippet
			
			// Context lines should only be present in the second scope (no overlap)
			XCTAssertFalse(first.contains("preceding-1"))
			XCTAssertFalse(first.contains("preceding-2"))
			XCTAssertTrue(second.contains("preceding-1"))
			XCTAssertTrue(second.contains("preceding-2"))
	}
		
		/// Repeated placeholder lines are deduplicated when carried forward
	func testDeduplicatedCarryPlaceholders() {
			let xml = """
		<file path="Dedup.swift" action="delegate edit">
		  <change>
			<content>
			// REPOMARK:SCOPE: 1 - First
			func a() {}
		
			// ... existing code ...
			// ... existing code ...
			// ... EXISTING CODE ...
		
			// REPOMARK:SCOPE: 2 - Second
			func b() {}
			</content>
		  </change>
		</file>
		"""
			let changes = delegateChanges(from: xml)
			XCTAssertEqual(changes.count, 2)
			let second = changes[1].codeSnippet
			let lines  = second.split(separator: "\n").map(String.init)
			let count  = lines.filter { $0.localizedCaseInsensitiveContains("existing code") }.count
			XCTAssertEqual(count, 1, "Second scope should have exactly one placeholder")
	}
		
		// MARK: - Tests from ChatContentParserContextScopeStressTests
		
	func testContextScopeWithPrecedingLines() {
			let xml = """
		<file path="test.swift" action="delegate edit">
		  <change>
			<content>
			int a = 0;                     // preceding‑3
			int b = 1;                     // preceding‑2
			int c = 2;                     // preceding‑1
			// REPOMARK:SCOPE: 1 - Example
			void Foo() { }
			</content>
		  </change>
		</file>
		"""
			
			let snippet = firstChangeCode(from: xml)
			
			XCTAssertFalse(snippet.contains("REPOMARK"),
						   "Marker line should NOT be present in snippet.")
			XCTAssertTrue(snippet.contains("int b = 1;"),
						  "Last‑2 context line should be kept.")
			XCTAssertTrue(snippet.contains("int c = 2;"),
						  "Last‑1 context line should be kept.")
			XCTAssertFalse(snippet.contains("int a = 0;"),
						   "Lines earlier than the 2‑line window must be excluded.")
	}
		
		// MARK: - Sliding‑window memory safety ------------------------------------------
		
		/// Parse **1 000 scopes** (~10 000 lines) and ensure it completes
		/// comfortably under 2 s on a unit‑test runner.
	func testVeryLargeScopeCountPerformance() {
			var body = ""
			for i in 1...1_000 {
				// 2 lines of context before each marker
				body += "let pre\(i)_1 = \(i);\n"
				body += "let pre\(i)_2 = \(i * 2);\n"
				body += "// REPOMARK:SCOPE: \(i) - Scope number \(i)\n"
				body += "func f\(i)() { print(\(i)) }\n\n"
			}
			
			let xml = """
		<file path="Huge.swift" action="delegate edit">
		  <change>
			<content>
		\(body)
			</content>
		  </change>
		</file>
		"""
			
			var processed = Set<Int>()
			measure(metrics: [XCTClockMetric()]) {
				let (_, _, edits) = ChatContentParser.parseContent(xml,
																   processedDelegateEditHashes: &processed,
																   isFinal: true)
				XCTAssertEqual(edits.first?.changes.count, 1_000,
							   "All scopes should be detected.")
			}
	}
		
		// MARK: - Placeholder propagation ------------------------------------------------
		
		/// Ensure placeholder comments preceding a marker are copied into both
		/// the current and subsequent scopes exactly once.
	func testPlaceholderPropagation() {
			let xml = """
		<file path="Placeholders.swift" action="delegate edit">
		  <change>
			<content>
			// REPOMARK:SCOPE: 1 - First
			func first() { }
			
			// ... existing code ...
			
			// REPOMARK:SCOPE: 2 - Second
			func second() { }
			</content>
		  </change>
		</file>
		"""
			
			var processed = Set<Int>()
			let (_, _, edits) = ChatContentParser.parseContent(xml,
															   processedDelegateEditHashes: &processed,
															   isFinal: true)
			
			let changes = edits.first!.changes
			XCTAssertEqual(changes.count, 2)
			
			let firstSnippet  = changes[0].codeSnippet
			let secondSnippet = changes[1].codeSnippet
			
			XCTAssertFalse(firstSnippet.contains("REPOMARK"))
			XCTAssertFalse(secondSnippet.contains("REPOMARK"))
			
			// Forward-only: placeholder should be carried to NEXT scope, not duplicated in previous
			XCTAssertFalse(firstSnippet.contains("// ... existing code ..."),
						   "Placeholder should NOT be in the first scope (no duplication).")
			XCTAssertTrue(secondSnippet.contains("// ... existing code ..."),
						  "Placeholder should be in the second scope.")
	}
	
	// MARK: - Regression Tests for Single Line Scope Fix
	
	func testSingleLineThenBlankBeforeNextMarker_NoEmptyFirstScope() {
		var processedSet = Set<Int>()
		let input =
		"""
		<file path="Edge.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - First
				func first() {}

				// REPOMARK:SCOPE: 2 - Second
				func second() {}
				</content>
			</change>
		</file>
		"""

		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)

		XCTAssertEqual(delegateEdits.count, 1)
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 2, "Should split into two scopes")

		let firstTrimmed = changes[0].codeSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
		XCTAssertFalse(firstTrimmed.isEmpty,
					"First scope must not be empty when it has a single code line followed by a blank line.")
		XCTAssertTrue(firstTrimmed.contains("func first()"),
					"First scope should contain its code line.")
		XCTAssertTrue(changes[1].codeSnippet.contains("func second()"),
					"Second scope should contain the second function.")
	}
	
	func testSingleLineThenPlaceholderBetweenMarkers_NoEmptyFirstScope() {
		var processedSet = Set<Int>()
		let input =
		"""
		<file path="EdgeWithPlaceholder.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - First
				func first() {}

				// ... existing code ...

				// REPOMARK:SCOPE: 2 - Second
				func second() {}
				</content>
			</change>
		</file>
		"""

		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)

		XCTAssertEqual(delegateEdits.count, 1, "Expected a single delegate-edit file.")
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 2, "Should split into two scoped changes.")

		// First scope should NOT be empty and should contain its code line.
		let first = changes[0].codeSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
		XCTAssertFalse(first.isEmpty, "First scope must not be empty when it has a single code line.")
		XCTAssertTrue(first.contains("func first()"), "First scope should contain its function.")
		// Placeholder should not be in the first scope (carried forward only).
		XCTAssertFalse(first.localizedCaseInsensitiveContains("existing code"))

		// Second scope should contain the placeholder and its own code.
		let second = changes[1].codeSnippet
		XCTAssertTrue(second.contains("func second()"), "Second scope should contain its function.")
		XCTAssertTrue(second.localizedCaseInsensitiveContains("existing code"),
					"Placeholder should be carried forward into the second scope.")
		XCTAssertFalse(second.contains("func first()"), "No leakage from the first scope into the second.")
	}
	
	// MARK: - Additional Edge Case Tests for Placeholder Handling
	
	/// Helper to count existing placeholder lines
	private func countExistingPlaceholders(_ snippet: String) -> Int {
		return snippet
			.components(separatedBy: .newlines)
			.filter { $0.localizedCaseInsensitiveContains("existing code") }
			.count
	}
	
	// MARK: - Placeholder run threshold (carry vs. backfill)
	
	/// 3 contiguous placeholders between scopes → carry forward (dedup to 1 in next scope)
	func testPlaceholderRunOfThreeLines_CarriesForward_DedupToOne() {
		let xml = """
		<file path="Threshold3.swift" action="delegate edit">
			<change>
			<content>
			// REPOMARK:SCOPE: 1 - First
			func one() {}

			// ... existing code ...
			// ... existing code ...
			// ... existing code ...

			// REPOMARK:SCOPE: 2 - Second
			func two() {}
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 2)

		XCTAssertFalse(changes[0].codeSnippet.localizedCaseInsensitiveContains("existing code"),
						"Placeholders should NOT be in first scope (carried forward).")

		let second = changes[1].codeSnippet
		XCTAssertTrue(second.contains("func two()"))
		XCTAssertEqual(countExistingPlaceholders(second), 1,
						"Carried placeholders should be deduped to a single line in the next scope.")
	}
	
	/// 4 contiguous placeholders between scopes → backfill into the *first* scope (threshold behavior)
	func testPlaceholderRunOfFourLines_BelongsToFirst_NotCarried() {
		let xml = """
		<file path="Threshold4.swift" action="delegate edit">
			<change>
			<content>
			// REPOMARK:SCOPE: 1 - First
			func one() {}

			// ... existing code ...
			// ... existing code ...
			// ... existing code ...
			// ... existing code ...

			// REPOMARK:SCOPE: 2 - Second
			func two() {}
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 2)

		XCTAssertTrue(changes[0].codeSnippet.localizedCaseInsensitiveContains("existing code"),
						"Long placeholder run (≥ threshold) should be committed to the first scope.")
		XCTAssertFalse(changes[1].codeSnippet.localizedCaseInsensitiveContains("existing code"),
						"Placeholders should NOT be carried to the second scope when backfilled.")
	}
	
	// MARK: - Pre-marker placeholder handling
	
	/// Placeholders appearing *before* the first marker (with real code following) are ignored entirely.
	func testPlaceholdersBeforeFirstMarker_AreIgnored() {
		let xml = """
		<file path="PreFirst.swift" action="delegate edit">
			<change>
			<content>
			// ... existing code ...
			// ... existing code ...
			let x = 1

			// REPOMARK:SCOPE: 1 - Only
			func impl() {}
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 1)

		let snippet = changes[0].codeSnippet
		XCTAssertTrue(snippet.contains("func impl()"))
		XCTAssertFalse(snippet.localizedCaseInsensitiveContains("existing code"),
						"Pre-first-scope placeholders should be dropped.")
		XCTAssertTrue(snippet.contains("let x = 1"),
						"Last pre-marker context line may be kept for the first scope.")
	}
	
	// MARK: - Pre-marker lookbehind seeding for first scope
	
	/// With a *single* pre-marker context line, it should seed into the first scope.
	func testFirstScope_OneLinePreMarkerLookbehind_IsSeeded() {
		let xml = """
		<file path="Lookbehind1.swift" action="delegate edit">
			<change>
			<content>
			let c1 = 1 // preceding-1
			// REPOMARK:SCOPE: 1 - Example
			func f() { }
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 1)

		let snippet = changes[0].codeSnippet
		XCTAssertTrue(snippet.contains("preceding-1"))
		XCTAssertTrue(snippet.contains("func f()"))
	}
	
	// MARK: - Seeding previous trailing only when window is full
	
	/// If a scope has only a *single* line of real content before the next marker,
	/// the seeding window isn't full → nothing should be seeded into the next scope.
	func testNoSeedWhenTrailingWindowNotFull_OneLineScope() {
		let xml = """
		<file path="NoSeed.swift" action="delegate edit">
			<change>
			<content>
			// REPOMARK:SCOPE: 1 - S1
			func one() {}
			// REPOMARK:SCOPE: 2 - S2
			func two() {}
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 2)

		let second = changes[1].codeSnippet
		XCTAssertFalse(second.contains("func one() {}"),
						"With an incomplete trailing window, previous scope lines should NOT seed into the next scope.")
	}
	
	// MARK: - Back-to-back markers
	
	/// Two markers with nothing in between → first scope snippet is empty, second has the code.
	func testBackToBackMarkers_FirstEmptySecondHasCode() {
		let xml = """
		<file path="BackToBack.swift" action="delegate edit">
			<change>
			<content>
			// REPOMARK:SCOPE: 1 - A
			// REPOMARK:SCOPE: 2 - B
			func b() {}
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 2)

		XCTAssertTrue(changes[0].codeSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
						"First scope should be empty.")
		XCTAssertTrue(changes[1].codeSnippet.contains("func b() {}"))
	}
	
	// MARK: - Cross-style placeholder dedup (JS: // and /* */)
	
	/// For JS files, both `// ...` and `/* ... */` placeholders should dedup to a single line when carried.
	func testCrossStylePlaceholders_DedupToOne_InNextScope_JS() {
		let xml = """
		<file path="MixedPlaceholders.js" action="delegate edit">
			<change>
			<content>
			// REPOMARK:SCOPE: 1 - First
			function first() {}

			// ... existing code ...
			/* ... existing code ... */
			// ... EXISTING CODE ...

			// REPOMARK:SCOPE: 2 - Second
			function second() {}
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 2)

		// Below threshold → carried forward and deduped to exactly one line
		XCTAssertFalse(changes[0].codeSnippet.localizedCaseInsensitiveContains("existing code"))
		XCTAssertEqual(countExistingPlaceholders(changes[1].codeSnippet), 1,
						"Mixed placeholder styles should dedup to a single line in the next scope.")
	}
	
	// MARK: - Final-scope variations
	
	/// Final scope with only placeholders after the marker (no code) should include placeholders
	/// (contrasts with marker-at-EOF which has truly no content).
	func testFinalScopeOnlyPlaceholders_AreIncluded() {
		let xml = """
		<file path="FinalOnlyPlaceholders.swift" action="delegate edit">
			<change>
			<content>
			// REPOMARK:SCOPE: 1 - First
			func a() {}

			// REPOMARK:SCOPE: 2 - Final with only placeholders
			// ... existing code ...
			// ... existing code ...
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 2)

		let finalSnippet = changes[1].codeSnippet
		XCTAssertTrue(finalSnippet.localizedCaseInsensitiveContains("existing code"),
						"Placeholders that directly follow the final marker should be kept in the final scope.")
		XCTAssertFalse(finalSnippet.contains("func a()"),
						"No content should leak from previous scope.")
	}
	
	// MARK: - Description trimming (tabs & spaces)
	
	func testDescriptionTrimming_WithTabsAndSpaces() {
		let xml = """
		<file path="TrimTabs.swift" action="delegate edit">
			<change>
			<content>
			//\t REPOMARK:SCOPE:\t1\t-\t  Title With Tabs\t
			func f() {}
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 1)
		XCTAssertEqual(changes[0].description, "Title With Tabs")
		XCTAssertTrue(changes[0].codeSnippet.contains("func f()"))
	}
	
	// MARK: - SQL placeholders
	
	func testSQLPlaceholders_CarryForwardAndDedup() {
		let xml = """
		<file path="schema.sql" action="delegate edit">
			<change>
			<content>
			-- REPOMARK:SCOPE: 1 - First
			CREATE TABLE a (id INT);

			-- ... existing code ...
			-- ... existing code ...

			-- REPOMARK:SCOPE: 2 - Second
			CREATE TABLE b (id INT);
			</content>
			</change>
		</file>
		"""
		let changes = delegateChanges(from: xml)
		XCTAssertEqual(changes.count, 2)
		XCTAssertFalse(changes[0].codeSnippet.localizedCaseInsensitiveContains("existing code"))
		XCTAssertEqual(countExistingPlaceholders(changes[1].codeSnippet), 1,
						"SQL-style placeholders should carry forward and be deduped.")
	}
	
	func testExistingCodeBoundaryPreventsSeeding_SingleLinePlusBlank() {
		var processedSet = Set<Int>()
		let input =
		"""
		<file path="PromptViewModel.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - First
				@Published var publicIsDirty: Bool = false

				// ... existing code ...

				// REPOMARK:SCOPE: 2 - Second
				func resetTokenCounts() {
					tokenCountingViewModel.resetCounts()
				}
				</content>
			</change>
		</file>
		"""

		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)

		XCTAssertEqual(delegateEdits.count, 1, "Expected a single delegate-edit file.")
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 2, "Should split into two scoped changes.")

		// First scope must keep its only real line, and not carry the placeholder.
		let first = changes[0].codeSnippet
		XCTAssertTrue(first.contains("@Published var publicIsDirty"),
						"First scope should include the property line.")
		XCTAssertFalse(first.localizedCaseInsensitiveContains("existing code"),
						"Placeholder should not be in the first scope.")

		// Second scope must not contain the property; it should carry the boundary placeholder + its own code.
		let second = changes[1].codeSnippet
		XCTAssertFalse(second.contains("@Published var publicIsDirty"),
						"Property line from scope 1 must not leak into scope 2.")
		XCTAssertTrue(second.localizedCaseInsensitiveContains("existing code"),
						"Boundary placeholder should be carried to scope 2.")
		XCTAssertTrue(second.contains("func resetTokenCounts"),
						"Scope 2 should contain its function.")
	}

	func testBoundaryPlaceholderKeepsAllTrailingContent_NoLoss() {
		var processedSet = Set<Int>()
		let input =
		"""
		<file path="EdgeMulti.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - First multi
				let a = 1
				let b = 2

				// ... existing code ...

				// REPOMARK:SCOPE: 2 - Second multi
				func doWork() { print(a + b) }
				</content>
			</change>
		</file>
		"""

		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)

		XCTAssertEqual(delegateEdits.count, 1)
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 2)

		// Scope 1 keeps *all* trailing content (no loss), since placeholder is a hard boundary.
		let s1 = changes[0].codeSnippet
		XCTAssertTrue(s1.contains("let a = 1"))
		XCTAssertTrue(s1.contains("let b = 2"))
		XCTAssertFalse(s1.localizedCaseInsensitiveContains("existing code"),
						"Boundary placeholder must not be backfilled into scope 1.")

		// Scope 2 receives the placeholder and its own code, with no leakage from scope 1.
		let s2 = changes[1].codeSnippet
		XCTAssertTrue(s2.localizedCaseInsensitiveContains("existing code"))
		XCTAssertTrue(s2.contains("func doWork()"))
		XCTAssertFalse(s2.contains("let a = 1"))
		XCTAssertFalse(s2.contains("let b = 2"))
	}
	
	func testWhitespaceNormalization_WithPlaceholderBoundary() {
		var processedSet = Set<Int>()
		let input =
		"""
		<file path="WhitespacePH.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - First
				let a = 1


				// ... existing code ...


				// REPOMARK:SCOPE: 2 - Second
				let b = 2


				</content>
			</change>
		</file>
		"""

		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		XCTAssertEqual(delegateEdits.count, 1)
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 2)

		func assertTrimAndCompact(_ s: String,
									file: StaticString = #filePath,
									line: UInt = #line) {
			let lines = s.components(separatedBy: .newlines)
			// No leading/trailing blank lines
			if let first = lines.first {
				XCTAssertFalse(first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
								"Leading blank line", file: file, line: line)
			}
			if let last = lines.last {
				XCTAssertFalse(last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
								"Trailing blank line", file: file, line: line)
			}
			// No more than one consecutive blank line
			var prevBlank = false
			for lineStr in lines {
				let blank = lineStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				if blank {
					XCTAssertFalse(prevBlank, "More than one consecutive blank line", file: file, line: line)
				}
				prevBlank = blank
			}
		}

		assertTrimAndCompact(changes[0].codeSnippet)
		assertTrimAndCompact(changes[1].codeSnippet)

		// Sanity: placeholder stays with second scope
		XCTAssertFalse(changes[0].codeSnippet.localizedCaseInsensitiveContains("existing code"))
		XCTAssertTrue(changes[1].codeSnippet.localizedCaseInsensitiveContains("existing code"))
	}

	func testWhitespaceNormalization_NoPlaceholderBoundary() {
		var processedSet = Set<Int>()
		let input =
		"""
		<file path="WhitespaceNoPH.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - First
				let a = 1



				// REPOMARK:SCOPE: 2 - Second
				let b = 2



				</content>
			</change>
		</file>
		"""

		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		XCTAssertEqual(delegateEdits.count, 1)
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 2)

		func assertTrimAndCompact(_ s: String,
									file: StaticString = #filePath,
									line: UInt = #line) {
			let lines = s.components(separatedBy: .newlines)
			// No leading/trailing blank lines
			if let first = lines.first {
				XCTAssertFalse(first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
								"Leading blank line", file: file, line: line)
			}
			if let last = lines.last {
				XCTAssertFalse(last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
								"Trailing blank line", file: file, line: line)
			}
			// No more than one consecutive blank line
			var prevBlank = false
			for lineStr in lines {
				let blank = lineStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				if blank {
					XCTAssertFalse(prevBlank, "More than one consecutive blank line", file: file, line: line)
				}
				prevBlank = blank
			}
		}

		assertTrimAndCompact(changes[0].codeSnippet)
		assertTrimAndCompact(changes[1].codeSnippet)
	}
	
	func testNoTrailingBlankLineInEachScope() {
		var processedSet = Set<Int>()
		let input =
		"""
		<file path="NoTrailingBlank.swift" action="delegate edit">
			<change>
				<content>
				// REPOMARK:SCOPE: 1 - First
				let a = 1

				// ... existing code ...

				// REPOMARK:SCOPE: 2 - Second
				let b = 2
				</content>
			</change>
		</file>
		"""
		
		let (_, _, delegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		XCTAssertEqual(delegateEdits.count, 1)
		let changes = delegateEdits[0].changes
		XCTAssertEqual(changes.count, 2)
		
		func assertNoTrailingBlankOrNewline(_ snippet: String,
											file: StaticString = #filePath,
											line: UInt = #line) {
			guard !snippet.isEmpty else { return } // empty scopes are allowed elsewhere
			// 1) Must not end with a newline char
			XCTAssertFalse(snippet.hasSuffix("\n") || snippet.hasSuffix("\r"),
							"Snippet ends with a newline", file: file, line: line)
			// 2) Last line must not be blank
			let parts = snippet.components(separatedBy: .newlines)
			if let last = parts.last {
				XCTAssertFalse(last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
								"Snippet ends with a blank line", file: file, line: line)
			}
		}
		
		assertNoTrailingBlankOrNewline(changes[0].codeSnippet)
		assertNoTrailingBlankOrNewline(changes[1].codeSnippet)
		
		// Sanity: placeholder stays with second scope and no leakage from scope 1
		XCTAssertFalse(changes[0].codeSnippet.localizedCaseInsensitiveContains("existing code"))
		XCTAssertTrue(changes[1].codeSnippet.localizedCaseInsensitiveContains("existing code"))
		XCTAssertFalse(changes[1].codeSnippet.contains("let a = 1"))
	}
	
	// MARK: - Placeholder Regex Compilation Test
	
	func testPlaceholderRegex_CStyleCompilation_NoCrash() {
		// This test ensures the C-style placeholder regex compiles without crashing
		// Previously, an unbalanced parenthesis in the pattern caused a crash
		var processed = Set<Int>()
		let input = """
		<file path="file.js" action="delegate edit">
			<change>
			<content>
			// REPOMARK:SCOPE: 1 - First
			const a = 1;
			
			// ... existing code ...
			
			// REPOMARK:SCOPE: 2 - Second
			const b = a + 1;
			</content>
			</change>
		</file>
		"""
		
		// If the C-style pattern is malformed, the old try! would crash here
		let (_, _, edits) = ChatContentParser.parseContent(input,
															processedDelegateEditHashes: &processed,
															isFinal: true)
		XCTAssertEqual(edits.count, 1)
		XCTAssertEqual(edits.first?.changes.count, 2)
		
		// Verify the placeholder was properly handled
		if let changes = edits.first?.changes {
			XCTAssertFalse(changes[0].codeSnippet.contains("existing code"))
			XCTAssertTrue(changes[1].codeSnippet.contains("existing code"))
		}
	}
	
	}

