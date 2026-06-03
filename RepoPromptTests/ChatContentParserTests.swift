//
//  ChatContentParserTests.swift
//  RepoPromptTests
//
//  Created by Your Name on 3/29/25.
//

import XCTest
@testable import RepoPrompt

/**
 Tests for the `ChatContentParser` class to ensure correct parsing
 of plain text, code blocks, <file> ... </file> blocks, <Plan> ... </Plan> blocks,
 as well as partial/streaming vs. final parse scenarios.
 
 All multi-line strings have been converted to single-line Swift strings with explicit \n characters.
 This makes the code easier to copy/paste into Xcode without issues arising from triple quotes or tabs.
 */
class ChatContentParserTests: XCTestCase {
	
	/**
	 Test that a simple text with no special tags or backticks
	 is parsed as a single `.text` `ContentItem`.
	 */
	func testParseSimpleText() {
		var processedSet = Set<Int>()
		let input = "Hello, this is just a line of text."
		
		let (items, core, newDelegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(items.count, 1, "Expected exactly one ContentItem for a simple text parse.")
		XCTAssertEqual(items[0].type, .text, "Expected the item type to be `.text`.")
		XCTAssertEqual(items[0].content, "Hello, this is just a line of text.")
		XCTAssertTrue(core.contains("Hello, this is just a line of text"), "Core content should include the text.")
		XCTAssertTrue(newDelegateEdits.isEmpty, "No delegate edits should be found in a plain text input.")
	}
	
	/**
	 Test that text with a triple-backtick code block is parsed into two items:
	 1) text item (before code)
	 2) code item
	 3) text item (after code)
	 */
	func testParseTextWithCodeBlock() {
		var processedSet = Set<Int>()
		let input =
		"Some introduction text.\n" +
		"```swift\n" +
		"print(\"Hello Code\")\n" +
		"```\n" +
		"Then some concluding remarks."
		
		let (items, core, newDelegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(items.count, 1)
		XCTAssertEqual(items[0].type, .text)
		XCTAssertTrue(items[0].content.contains("```swift"))
		XCTAssertTrue(items[0].content.contains("print(\"Hello Code\")"))
		XCTAssertTrue(items[0].content.contains("Then some concluding remarks."))
		
		XCTAssertTrue(core.contains("Some introduction text."))
		XCTAssertTrue(core.contains("```swift"))
		XCTAssertTrue(newDelegateEdits.isEmpty)
	}
	
	/**
	 Test that a `<Plan>` block is extracted as a text `ContentItem`,
	 and that the parser includes the plan content in the `core` text.
	 */
	func testParsePlanBlock() {
		var processedSet = Set<Int>()
		let input =
		"Regular text above.\n\n" +
		"<Plan>\n" +
		"- Step 1: Do something\n" +
		"- Step 2: Verify results\n" +
		"</Plan>\n\n" +
		"Some text after plan.\n"
		
		let (items, core, _) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		// Expect 3 items: text before plan, plan block as text, text after plan.
		XCTAssertEqual(items.count, 3, "Should produce 3 content items.")
		
		let planItem = items[1]
		XCTAssertEqual(planItem.type, .text, "Plan content is stored as `.text`.")
		XCTAssertTrue(planItem.content.contains("Step 1: Do something"))
		
		XCTAssertTrue(core.contains("Plan:\n- Step 1: Do something"), "Core should include plan content.")
	}
	
	/**
	 Test that the parser extracts `<file ... action="create">... </file>` content
	 as a `.file` ContentItem, capturing the file path, action, and raw snippet.
	 */
	func testParseFileWithActionCreate() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"Sources/MyClass.swift\" action=\"create\">\n" +
		"<change>\n" +
		"<description>Implement new class</description>\n" +
		"<content>\n" +
		"public class MyClass {\n" +
		"    func greet() {\n" +
		"        print(\"Hello World\")\n" +
		"    }\n" +
		"}\n" +
		"</content>\n" +
		"</change>\n" +
		"</file>\n"
		
		let (items, core, _) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		let fileItem = try! XCTUnwrap(items.first)
		XCTAssertEqual(fileItem.type, .file)
		XCTAssertEqual(fileItem.filePath, "Sources/MyClass.swift")
		
		// ‼️ new header format (no `(Action: …)` suffix)
		XCTAssertTrue(core.contains("File: Sources/MyClass.swift"))
		XCTAssertTrue(core.contains("Implement new class"))
	}
	
	/**
	 Test that multiple `<change>` blocks within a single `<file>` are captured as multiple `changes`.
	 */
	func testParseFileWithMultipleChanges() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"Sources/MultiChangeFile.swift\" action=\"modify\">\n" +
		"<change><description>First change</description><content>func doA(){}</content></change>\n" +
		"<change><description>Second change</description><content>func doB(){}</content></change>\n" +
		"</file>"
		
		let (items, core, _) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertTrue(core.contains("File: Sources/MultiChangeFile.swift"))
		XCTAssertTrue(core.contains("Change #1:"))
		XCTAssertTrue(core.contains("Change #2:"))
	}
	
	/**
	 Test that delegate-edit actions (`action="delegate edit"`) produce the expected `.file` item
	 plus the `newDelegateEdits` array containing the relevant snippet info.
	 */
	func testParseDelegateEditAction() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"MyDelegateFile.swift\" action=\"delegate edit\">\n" +
		"<change><description>Delegate snippet 1</description><complexity>2</complexity><content>let x = 10</content></change>\n" +
		"<change><description>Delegate snippet 2</description><content>print(\"Delegate #2\")</content></change>\n" +
		"</file>"
		
		let (_, core, newDelegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(newDelegateEdits.count, 1)
		XCTAssertTrue(core.contains("File: MyDelegateFile.swift")) // new header format
	}
	
	/**
	 Test partial parse scenario (isFinal = false): The parser truncates the last line
	 of text if there's no trailing newline, while code blocks are unaffected if they close properly.
	 */
	func testPartialParseTruncation() {
		var processedSet = Set<Int>()
		let input =
		"Hello line 1\n" +
		"Hello line 2 (no trailing newline)" +
		"\n```swift\nfunc codeBlock() {}\n```\n"
		
		let (items, core, _) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: false
		)
		
		XCTAssertTrue(core.contains("line 2"))
		XCTAssertEqual(items.count, 1)
		XCTAssertEqual(items[0].type, .text)
		XCTAssertTrue(items[0].content.contains("```swift"))
		XCTAssertFalse(items[0].content.hasSuffix("```"))
	}
	
	/**
	 Test that <chatName=...> snippet is removed from content and does not appear in final items,
	 but the rest of the text is preserved.
	 */
	func testChatNameExtractionAndRemoval() {
		var processedSet = Set<Int>()
		let input = "<chatName=\"Eric\"> Hello. This text is after chatName spec.\n"
		
		let (items, core, _) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(items.count, 1, "Only one text item expected.")
		XCTAssertEqual(items[0].type, .text)
		XCTAssertFalse(items[0].content.contains("<chatName="), "Chat name snippet should be removed from final content.")
		XCTAssertTrue(items[0].content.contains("Hello. This text is after chatName spec."), "The rest of the line should remain.")
		XCTAssertFalse(core.contains("<chatName="), "Core also should not contain the chat name snippet.")
		XCTAssertTrue(core.contains("Hello. This text is after chatName spec."), "Core retains the normal text.")
	}
	
	/**
	 Test that if we have `<file>` blocks with no closing `</file>` and `isFinal=false`,
	 it won't remove incomplete file tags. This ensures partial parse keeps that text around.
	 */
	func testIncompleteFileTagPartialParse() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"Incomplete.swift\" action=\"modify\">\n" +
		"  // Some changes here\n"
		
		let (items, _, _) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: false
		)
		
		XCTAssertEqual(items.count, 1)
		XCTAssertTrue(items[0].content.contains("// Some changes here"))
	}
	
	/**
	 Test that multiple <file> blocks and a <Plan> block are parsed in sequence,
	 verifying items appear in correct order and final `core` text merges them correctly.
	 */
	func testParseMultipleFilesAndPlan() {
		var processedSet = Set<Int>()
		let input =
		"<file path=\"FileA.swift\" action=\"create\"><change><description>Change A1</description><content>Content A1</content></change></file>\n" +
		"Some between text.\n" +
		"<Plan>This is a plan section.</Plan>\n" +
		"<file path=\"FileB.swift\" action=\"modify\"><change><description>Change B1</description><content>Content B1</content></change><change><description>Change B2</description><content>Content B2</content></change></file>"
		
		let (_, core, _) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertTrue(core.contains("File: FileA.swift"))
		XCTAssertTrue(core.contains("File: FileB.swift"))
	}
	
	/**
	 Test that a snippet with leading/trailing triple backticks around everything
	 is unwrapped, so the inner `<file>` or `<Plan>` can be parsed properly.
	 */
	func testOuterBackticksRemoval() {
		var processedSet = Set<Int>()
		let input =
		"```\n<file path=\"OuterTicked.swift\" action=\"create\"><change><description>Outer Backtick Test</description><content>print(\"Example\")</content></change></file>\n```"
		
		let (_, core, _) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertTrue(core.contains("File: OuterTicked.swift"))
		XCTAssertTrue(core.contains("Outer Backtick Test"))
	}
	
	func testDelegateEditDuplicateSuppressionWithinSingleParse() {
		var processedSet = Set<Int>()
		let delegateBlock =
			"<file path=\"src/Foo.swift\" action=\"delegate edit\">\n" +
			"<change><description>Keep unique</description><content>let value = 1</content></change>\n" +
			"</file>\n"
		let input = delegateBlock + delegateBlock
		
		let (_, _, newDelegateEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(newDelegateEdits.count, 1)
		XCTAssertEqual(processedSet.count, 1)
	}
	
	func testDelegateEditDuplicateSuppressionAcrossParses() {
		var processedSet = Set<Int>()
		let input =
			"<file path=\"src/Foo.swift\" action=\"delegate edit\">\n" +
			"<change><description>Duplicate block</description><content>let value = 1</content></change>\n" +
			"</file>\n"
		
		let (_, _, firstEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		XCTAssertEqual(firstEdits.count, 1)
		
		let (_, _, secondEdits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		XCTAssertTrue(secondEdits.isEmpty)
	}
	
	func testDelegateEditHashDistinguishesDifferentPaths() {
		var processedSet = Set<Int>()
		let blockA =
			"<file path=\"src/Foo.swift\" action=\"delegate edit\">\n" +
			"<change><description>Shared snippet</description><content>let value = 1</content></change>\n" +
			"</file>\n"
		let blockB =
			"<file path=\"src/Bar.swift\" action=\"delegate edit\">\n" +
			"<change><description>Shared snippet</description><content>let value = 1</content></change>\n" +
			"</file>\n"
		let input = blockA + blockB
		
		let (_, _, edits) = ChatContentParser.parseContent(
			input,
			processedDelegateEditHashes: &processedSet,
			isFinal: true
		)
		
		XCTAssertEqual(edits.count, 2)
	}
	
	// MARK: - Utility Function Tests for C Port
	
	/**
	 Test removeOuterBackticks function with various inputs
	 */
	func testRemoveOuterBackticks() {
		// Test case 1: Complete code block with language
		let input1 = "```swift\nlet x = 42\nprint(x)\n```"
		let result1 = ChatContentParser.removeOuterBackticks(from: input1)
		XCTAssertEqual(result1, "let x = 42\nprint(x)")
		
		// Test case 2: Complete code block without language
		let input2 = "```\nlet x = 42\nprint(x)\n```"
		let result2 = ChatContentParser.removeOuterBackticks(from: input2)
		XCTAssertEqual(result2, "let x = 42\nprint(x)")
		
		// Test case 3: Incomplete code block (no closing backticks)
		let input3 = "```swift\nlet x = 42\nprint(x)"
		let result3 = ChatContentParser.removeOuterBackticks(from: input3)
		XCTAssertEqual(result3, "let x = 42\nprint(x)")
		
		// Test case 4: No backticks
		let input4 = "let x = 42\nprint(x)"
		let result4 = ChatContentParser.removeOuterBackticks(from: input4)
		XCTAssertEqual(result4, "let x = 42\nprint(x)")
		
		// Test case 5: With whitespace
		let input5 = "  \n```python\ndef hello():\n    print('world')\n```  \n"
		let result5 = ChatContentParser.removeOuterBackticks(from: input5)
		XCTAssertEqual(result5, "def hello():\n    print('world')")
		
		// Test case 6: Empty code block
		let input6 = "```\n```"
		let result6 = ChatContentParser.removeOuterBackticks(from: input6)
		XCTAssertEqual(result6, "")
		
		// Test case 7: Just opening backticks
		let input7 = "```"
		let result7 = ChatContentParser.removeOuterBackticks(from: input7)
		XCTAssertEqual(result7, "")
	}
	
	/**
	 Test trimContent function
	 */
	func testTrimContent() {
		// Test case 1: Basic indentation removal
		let input1 = "    func hello() {\n        print(\"world\")\n    }"
		let result1 = ChatContentParser.trimContent(input1)
		XCTAssertEqual(result1, "func hello() {\n    print(\"world\")\n}")
		
		// Test case 2: Mixed tabs and spaces (tabs normalize to spaces)
		let input2 = " \tline1\n \tline2\n \tline3"
		let result2 = ChatContentParser.trimContent(input2)
		XCTAssertEqual(result2, "line1\nline2\nline3")
		
		// Test case 3: Empty lines should be preserved
		let input3 = "    code\n\n    more code"
		let result3 = ChatContentParser.trimContent(input3)
		XCTAssertEqual(result3, "code\n\nmore code")
		
		// Test case 4: No common whitespace
		let input4 = "no indent\n    indented\n  semi indented"
		let result4 = ChatContentParser.trimContent(input4)
		XCTAssertEqual(result4, input4)
		
		// Test case 5: HTML entities are decoded before trimming
		let input5 = "    &lt;tag&gt;\n    &amp;"
		let result5 = ChatContentParser.trimContent(input5)
		XCTAssertEqual(result5, "<tag>\n&")
	}
	
	/**
	 Test extractDescription function
	 */
	func testExtractDescription() {
		// Test case 1: Basic description
		let input1 = "<description>This is a test description</description>"
		let result1 = ChatContentParser.extractDescription(from: input1)
		XCTAssertEqual(result1, "This is a test description")
		
		// Test case 2: Description with other content
		let input2 = "Some text before\n<description>Extract this</description>\nSome text after"
		let result2 = ChatContentParser.extractDescription(from: input2)
		XCTAssertEqual(result2, "Extract this")
		
		// Test case 3: No description tag
		let input3 = "Just some regular text"
		let result3 = ChatContentParser.extractDescription(from: input3)
		XCTAssertEqual(result3, "")
		
		// Test case 4: Empty description
		let input4 = "<description></description>"
		let result4 = ChatContentParser.extractDescription(from: input4)
		XCTAssertEqual(result4, "")
		
		// Test case 5: Multiple descriptions (should get first)
		let input5 = "<description>First</description><description>Second</description>"
		let result5 = ChatContentParser.extractDescription(from: input5)
		XCTAssertEqual(result5, "First")
	}
	
	/**
	 Test extractComplexity function
	 */
	func testExtractComplexity() {
		// Test case 1: Valid complexity
		let input1 = "<complexity>5</complexity>"
		let result1 = ChatContentParser.extractComplexity(from: input1)
		XCTAssertEqual(result1, 5)
		
		// Test case 2: Complexity with other content
		let input2 = "Before\n<complexity>3</complexity>\nAfter"
		let result2 = ChatContentParser.extractComplexity(from: input2)
		XCTAssertEqual(result2, 3)
		
		// Test case 3: No complexity tag
		let input3 = "No complexity here"
		let result3 = ChatContentParser.extractComplexity(from: input3)
		XCTAssertNil(result3)
		
		// Test case 4: Invalid complexity value
		let input4 = "<complexity>not-a-number</complexity>"
		let result4 = ChatContentParser.extractComplexity(from: input4)
		XCTAssertNil(result4)
		
		// Test case 5: Empty complexity
		let input5 = "<complexity></complexity>"
		let result5 = ChatContentParser.extractComplexity(from: input5)
		XCTAssertNil(result5)
		
		// Test case 6: Large complexity value
		let input6 = "<complexity>10</complexity>"
		let result6 = ChatContentParser.extractComplexity(from: input6)
		XCTAssertEqual(result6, 10)
	}
	
	// MARK: - Robustness Tests for C Port
	
	/**
	 Test removeOuterBackticks with edge cases and potential memory issues
	 */
	func testRemoveOuterBackticksRobustness() {
		// Test case 1: Empty string
		let input1 = ""
		let result1 = ChatContentParser.removeOuterBackticks(from: input1)
		XCTAssertEqual(result1, "")
		
		// Test case 2: Very long content
		let longContent = String(repeating: "a", count: 10000)
		let input2 = "```\n\(longContent)\n```"
		let result2 = ChatContentParser.removeOuterBackticks(from: input2)
		XCTAssertEqual(result2, longContent)
		
		// Test case 3: Multiple backtick sets
		let input3 = "```outer\n```inner\ncontent\n```\n```"
		let result3 = ChatContentParser.removeOuterBackticks(from: input3)
		XCTAssertEqual(result3, "```inner\ncontent\n```")
		
		// Test case 4: Unicode content (preserves internal spaces)
		let input4 = "```swift\n let emoji = \"🎉🔥💯\" \n```"
		let result4 = ChatContentParser.removeOuterBackticks(from: input4)
		XCTAssertEqual(result4, " let emoji = \"🎉🔥💯\" ")
		
		// Test case 5: Only whitespace
		let input5 = "   \n\t  \r\n   "
		let result5 = ChatContentParser.removeOuterBackticks(from: input5)
		XCTAssertEqual(result5, "")
		
		// Test case 6: Malformed backticks
		let input6 = "``swift\ncode\n```"
		let result6 = ChatContentParser.removeOuterBackticks(from: input6)
		XCTAssertEqual(result6, "``swift\ncode\n```")
		
		// Test case 7: Windows line endings
		let input7 = "```\r\ncode\r\n```"
		let result7 = ChatContentParser.removeOuterBackticks(from: input7)
		XCTAssertEqual(result7, "code")
		
		// Test case 8: Language with special characters
		let input8 = "```c++\ncode\n```"
		let result8 = ChatContentParser.removeOuterBackticks(from: input8)
		XCTAssertEqual(result8, "code")
	}
	
	/**
	 Test trimContent with edge cases
	 */
	func testTrimContentRobustness() {
		// Test case 1: Empty content
		let input1 = ""
		let result1 = ChatContentParser.trimContent(input1)
		XCTAssertEqual(result1, "")
		
		// Test case 2: Single line
		let input2 = "    single line"
		let result2 = ChatContentParser.trimContent(input2)
		XCTAssertEqual(result2, "single line")
		
		// Test case 3: Unicode indentation is not treated as trim whitespace
		let input3 = "　　Japanese\r　　full-width\r　　spaces"  // Full-width spaces
		let result3 = ChatContentParser.trimContent(input3)
		XCTAssertEqual(result3, input3)
		
		// Test case 4: Very long lines
		let longLine = "    " + String(repeating: "x", count: 5000)
		let input4 = "\(longLine)\n    short\n\(longLine)"
		let result4 = ChatContentParser.trimContent(input4)
		let trimmedLong = String(repeating: "x", count: 5000)
		XCTAssertEqual(result4, "\(trimmedLong)\nshort\n\(trimmedLong)")
		
		// Test case 5: Literal indentation tags are preserved as content
		let input5 = "<s4>encoded\r\n    regular\r\n\ttab"
		let result5 = ChatContentParser.trimContent(input5)
		XCTAssertEqual(result5, "<s4>encoded\r\n    regular\r\n    tab")
		
		// Test case 6: Detected line endings are preserved
		let input6 = "    one\r\n        two\r\n    three"
		let result6 = ChatContentParser.trimContent(input6)
		XCTAssertEqual(result6, "one\r\n    two\r\nthree")
		
		// Test case 7: Only whitespace lines mixed with content
		let input7 = "    \n    content\n        \n    more"
		let result7 = ChatContentParser.trimContent(input7)
		XCTAssertEqual(result7, "\ncontent\n    \nmore")
	}
	
	/**
	 Test extractDescription with edge cases
	 */
	func testExtractDescriptionRobustness() {
		// Test case 1: Very long description
		let longDesc = String(repeating: "This is a very long description. ", count: 500)
		let input1 = "<description>\(longDesc)</description>"
		let result1 = ChatContentParser.extractDescription(from: input1)
		XCTAssertEqual(result1, longDesc.trimmingCharacters(in: .whitespaces))
		
		// Test case 2: Nested tags
		let input2 = "<description>Outer <description>Inner</description> Outer</description>"
		let result2 = ChatContentParser.extractDescription(from: input2)
		// Should get first opening to first closing
		XCTAssertEqual(result2, "Outer <description>Inner")
		
		// Test case 3: Special characters and unicode
		let input3 = "<description>Special: <>&\"' 你好 🌍</description>"
		let result3 = ChatContentParser.extractDescription(from: input3)
		XCTAssertEqual(result3, "Special: <>&\"' 你好 🌍")
		
		// Test case 4: Description with newlines
		let input4 = "<description>\n  Multi\n  Line\n  Description\n</description>"
		let result4 = ChatContentParser.extractDescription(from: input4)
		XCTAssertEqual(result4, "Multi\n  Line\n  Description")
		
		// Test case 5: Case sensitivity
		let input5 = "<DESCRIPTION>UPPERCASE</DESCRIPTION>"
		let result5 = ChatContentParser.extractDescription(from: input5)
		XCTAssertEqual(result5, "")  // Should not match due to case
		
		// Test case 6: Malformed XML-like content
		let input6 = "<description>Unclosed tag"
		let result6 = ChatContentParser.extractDescription(from: input6)
		XCTAssertEqual(result6, "")
		
		// Test case 7: Multiple on same line
		let input7 = "prefix <description>First</description> middle <description>Second</description> suffix"
		let result7 = ChatContentParser.extractDescription(from: input7)
		XCTAssertEqual(result7, "First")  // Should get first one
	}
	
	/**
	 Test extractComplexity with edge cases
	 */
	func testExtractComplexityRobustness() {
		// Test case 1: Maximum int value
		let input1 = "<complexity>2147483647</complexity>"  // INT_MAX
		let result1 = ChatContentParser.extractComplexity(from: input1)
		XCTAssertEqual(result1, 2147483647)
		
		// Test case 2: Negative number
		let input2 = "<complexity>-5</complexity>"
		let result2 = ChatContentParser.extractComplexity(from: input2)
		XCTAssertNil(result2)  // Should reject negative
		
		// Test case 3: Floating point
		let input3 = "<complexity>3.14</complexity>"
		let result3 = ChatContentParser.extractComplexity(from: input3)
		XCTAssertNil(result3)  // Should reject non-integer
		
		// Test case 4: Leading zeros
		let input4 = "<complexity>007</complexity>"
		let result4 = ChatContentParser.extractComplexity(from: input4)
		XCTAssertEqual(result4, 7)
		
		// Test case 5: Whitespace around number
		let input5 = "<complexity>  \n  42  \t  </complexity>"
		let result5 = ChatContentParser.extractComplexity(from: input5)
		XCTAssertEqual(result5, 42)
		
		// Test case 6: Too large for int
		let input6 = "<complexity>9999999999999999999</complexity>"
		let result6 = ChatContentParser.extractComplexity(from: input6)
		XCTAssertNil(result6)  // Should reject overflow
		
		// Test case 7: Zero
		let input7 = "<complexity>0</complexity>"
		let result7 = ChatContentParser.extractComplexity(from: input7)
		XCTAssertEqual(result7, 0)
		
		// Test case 8: Mixed content
		let input8 = "<complexity>5 stars</complexity>"
		let result8 = ChatContentParser.extractComplexity(from: input8)
		XCTAssertNil(result8)  // Should reject non-pure number
	}

	/**
	 Stress test trimContent with large input to catch crashes or regressions.
	 */
	func testTrimContentLargeInput() {
		let lineCount = 2000
		let payload = String(repeating: "x", count: 80)
		var lines: [String] = []
		lines.reserveCapacity(lineCount)
		for i in 0..<lineCount {
			lines.append("    line \(i) \(payload)")
		}
		let input = lines.joined(separator: "\n")
		
		let result = ChatContentParser.trimContent(input)
		let firstLine = result.split(separator: "\n", omittingEmptySubsequences: false).first
		
		XCTAssertEqual(firstLine, Substring("line 0 \(payload)"))
		XCTAssertTrue(result.contains("line \(lineCount - 1) \(payload)"))
		XCTAssertFalse(result.contains("\n    line \(lineCount - 1)"))
	}

	/**
	 Stress test trimContent preserves detected CRLF endings on large input.
	 */
	func testTrimContentLargeInputPreservesCRLF() {
		let lineCount = 1500
		var lines: [String] = []
		lines.reserveCapacity(lineCount)
		for i in 0..<lineCount {
			lines.append("    row \(i)")
		}
		let input = lines.joined(separator: "\r\n")
		
		let result = ChatContentParser.trimContent(input)
		let (_, ending) = String.splitContentPreservingLineEndings(result)
		
		XCTAssertEqual(ending, "\r\n")
		XCTAssertTrue(result.hasPrefix("row 0"))
	}
}
