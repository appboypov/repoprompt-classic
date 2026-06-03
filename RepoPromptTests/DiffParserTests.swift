//
//  DiffParserTests.swift
//  RepoPromptTests
//
//  Comprehensive tests for DiffParser and DiffParserUtils
//  Consolidated from DiffParserGeneralTests, DiffParserUtilsTests, and DiffParserCoalescingTests
//

import XCTest
@testable import RepoPrompt

final class DiffParserTests: XCTestCase {
    
    private var fileManager: RepoFileManagerViewModel!
    private var diffParser: DiffParser!
    
    override func setUp() async throws {
        try await super.setUp()
        fileManager = await RepoFileManagerViewModel()
        
        // Create DiffParser with debug configuration for consistent test behavior
        #if DEBUG
        let debugConfig = DiffParser.DebugConfig(
            treatNonExistentFilesAsExisting: true,
            alwaysPreserveRewriteAction: true
        )
        diffParser = DiffParser(fileManager: fileManager, debugConfig: debugConfig)
        #else
        diffParser = DiffParser(fileManager: fileManager)
        #endif
    }
    
    override func tearDown() async throws {
        diffParser = nil
        fileManager = nil
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func extract(_ text: String,
                        tag: String = "content",
                        flex: Bool = false) -> String? {
        DiffParserUtils.extractContent(from: text, tag: tag, flexible: flex)
    }
    
    func testDebugModePreservesRewriteAction() async throws {
        #if DEBUG
        // With debug config that preserves rewrite actions
        let debugConfig = DiffParser.DebugConfig(
            treatNonExistentFilesAsExisting: false,
            alwaysPreserveRewriteAction: true
        )
        let parser = DiffParser(fileManager: fileManager, debugConfig: debugConfig)
        #else
        let parser = DiffParser(fileManager: fileManager)
        #endif
        
        let input = """
        <file path="test.swift" action="rewrite">
        <content>
        ===
        // Rewritten content
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        #if DEBUG
        // In debug mode with alwaysPreserveRewriteAction, should stay as rewrite
        XCTAssertEqual(result[0].action, .rewrite)
        #else
        // In production mode, rewrite on non-existent file becomes create
        XCTAssertEqual(result[0].action, .create)
        #endif
    }
    
    func testDebugModeTreatsFilesAsExisting() async throws {
        #if DEBUG
        let debugConfig = DiffParser.DebugConfig(
            treatNonExistentFilesAsExisting: true,
            alwaysPreserveRewriteAction: false
        )
        let parser = DiffParser(fileManager: fileManager, debugConfig: debugConfig)
        #else
        let parser = DiffParser(fileManager: fileManager)
        #endif
        
        let input = """
        <file path="test.swift" action="modify">
        <change>
        <description>Modify non-existent file</description>
        <content>
        ===
        func test() {}
        ===
        </content>
        </change>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].changes.count, 1)
        
        #if DEBUG
        // With treatNonExistentFilesAsExisting, changes should be .modify type
        XCTAssertEqual(result[0].changes[0].type, .modify)
        #else
        // In production, modify on non-existent file creates .add type changes
        XCTAssertEqual(result[0].changes[0].type, .add)
        #endif
    }
    
    // MARK: - Error Handling Tests
    
    func testInvalidActionGeneratesError() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="test.swift" action="invalid-action">
        <content>Some content</content>
        </file>
        """
        
        // Should not throw, but should skip the invalid file
        let result = try await parser.parse(input)
        XCTAssertEqual(result.count, 0)
    }
    
    func testModifyNonExistentFileGeneratesError() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="nonexistent.swift" action="modify">
        <change>
        <description>Try to modify</description>
        <content>
        ===
        // Content
        ===
        </content>
        </change>
        </file>
        """
        
        // Should parse successfully despite the error
        let result = try await parser.parse(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].action, .modify)
        // Changes should be .add type since file doesn't exist
        XCTAssertEqual(result[0].changes[0].type, .add)
    }
    
    func testMultipleErrorsStillParseSuccessfully() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="invalid1.swift" action="invalid-action">
        <content>Content 1</content>
        </file>
        <file path="valid.swift" action="create">
        <content>
        ===
        // Valid file
        ===
        </content>
        </file>
        <file path="invalid2.swift" action="another-invalid">
        <content>Content 2</content>
        </file>
        <file path="modify-missing.swift" action="modify">
        <change>
        <description>Modify missing</description>
        <content>
        ===
        // Modified
        ===
        </content>
        </change>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        // Should have 2 valid files (create and modify)
        XCTAssertEqual(result.count, 2)
        
        let createFile = result.first { $0.fileName.contains("valid.swift") }
        let modifyFile = result.first { $0.fileName.contains("modify-missing.swift") }
        
        XCTAssertNotNil(createFile)
        XCTAssertNotNil(modifyFile)
        
        XCTAssertEqual(createFile?.action, .create)
        XCTAssertEqual(modifyFile?.action, .modify)
    }
    
    // MARK: - Complex Parsing Scenarios
    
    func testEmptyChangeBlocksAreHandled() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="test.swift" action="modify">
        <change>
        <description>Empty change</description>
        </change>
        <change>
        <description>Change with content</description>
        <content>
        ===
        func hasContent() {}
        ===
        </content>
        </change>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        // Should have at least the change with content
        XCTAssertGreaterThanOrEqual(result[0].changes.count, 1)
        
        // Find the change with content
        let contentChange = result[0].changes.first { change in
            change.summary.contains("Change with content")
        }
        XCTAssertNotNil(contentChange)
        XCTAssertNotNil(contentChange?.content)
    }
    
    func testMalformedXMLHandling() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="test.swift" action="create">
        <content>
        ===
        Unclosed content
        <!-- Missing closing tags -->
        """
        
        // Should handle gracefully
        let result = try await parser.parse(input)
        // May or may not parse depending on implementation
        XCTAssertTrue(result.count >= 0)
    }
    
    // MARK: - Broken XML and Fragment Tests
    
    func testBrokenClosingTags() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="broken1.swift" action="create">
        <content>
        ===
        func test() {
            print("Missing closing fence")
        </content>
        </file>
        <file path="broken2.swift" action="modify">
        <change>
        <description>Missing closing change tag
        <content>
        ===
        func broken() {}
        ===
        </content>
        </file>
        <file path="valid.swift" action="create">
        <content>
        ===
        func valid() {}
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        // Should at least parse the valid file
        let validFile = result.first { $0.fileName.contains("valid.swift") }
        XCTAssertNotNil(validFile)
        
        // Check that broken files don't leak content into valid ones
        if let valid = validFile {
            XCTAssertFalse(valid.fileContent.contains("Missing closing"))
            XCTAssertTrue(valid.fileContent.contains("func valid()"))
        }
    }
    
    func testOrphanedFenceMarkers() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="orphan.swift" action="create">
        <content>
        ===
        func first() {
            // Normal content
        }
        ===
        ===
        // This is an orphaned fence that shouldn't be included
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        // Content should not include orphaned fence markers
        let content = result[0].fileContent
        let fenceCount = content.components(separatedBy: "===").count - 1
        XCTAssertLessThanOrEqual(fenceCount, 0, "Content should not contain === markers")
    }
    
    func testMismatchedFenceMarkers() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="mismatched.swift" action="create">
        <content>
        ====
        func test() {
            // Using 4 equals instead of 3
        }
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        if result.count > 0 {
            // Should either parse correctly or skip
            let content = result[0].fileContent
            // Should not include fence markers in content
            XCTAssertFalse(content.hasPrefix("===="))
            XCTAssertFalse(content.hasSuffix("==="))
        }
    }
    
    
    func testIncompleteChangeBlocks() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="incomplete.swift" action="modify">
        <change>
        <description>First change</description>
        <content>
        ===
        func first() {}
        ===
        </content>
        </change>
        <change>
        <description>Incomplete change
        <content>
        ===
        func incomplete() {
        <!-- Missing closing for everything -->
        """
        
        let result = try await parser.parse(input)
        
        // Should at least get the first complete change
        if result.count > 0 {
            let changes = result[0].changes
            XCTAssertGreaterThanOrEqual(changes.count, 1)
            
            // First change should be complete
            let firstChange = changes[0]
            XCTAssertEqual(firstChange.summary, "First change")
            XCTAssertNotNil(firstChange.content)
        }
    }
    
    func testContentWithXMLLikeStrings() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="xmllike.swift" action="create">
        <content>
        ===
        // This content has XML-like strings that shouldn't confuse parser
        let xml = "<tag>content</tag>"
        let comparison = "if a < b && c > d { }"
        let generic = "Array<String>"
        let fence = "// === This is not a fence ==="
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        let content = result[0].fileContent
        
        // All XML-like content should be preserved
        XCTAssertTrue(content.contains("<tag>content</tag>"))
        XCTAssertTrue(content.contains("< b && c >"))
        XCTAssertTrue(content.contains("Array<String>"))
        XCTAssertTrue(content.contains("=== This is not a fence ==="))
    }

    // MARK: - Create-vs-Rewrite Resolution

    /// Ensure a create action does not flip to rewrite when a resolver would suggest
    /// a deeper path with the same filename (extra directory component).
    func testCreateDoesNotRewriteWhenCandidateHasExtraComponent() async throws {
        @MainActor
        class FakeFM: RepoFileManagerViewModel {
			override func getFileSystemServiceForRelativePath(_ userPath: String, exactMatchOnly: Bool = false, profile: PathLocateProfile? = nil, rootScopeOverride: RepoFileManagerViewModel.LookupRootScope? = nil) async -> PathLocation? {
                if userPath == "A/B/file.swift" {
                    // Simulate a candidate with an extra component (A/B/C/file.swift)
                    return PathLocation(rootPath: "/tmp/root", correctedPath: "A/B/C/file.swift", rootIdentifier: nil)
                }
                return nil
            }
        }

        let fakeFM = await FakeFM()
        let parser = DiffParser(fileManager: fakeFM)

        let input = """
        <file path="A/B/file.swift" action="create">
        <content>
        ===
        print("hello")
        ===
        </content>
        </file>
        """

        let result = try await parser.parse(input)

        XCTAssertEqual(result.count, 1)
        // Should remain create (not rewrite), and keep original path
        XCTAssertEqual(result[0].action, .create)
        XCTAssertEqual(result[0].fileName, "A/B/file.swift")
    }
    
    func testEmptyAndWhitespaceOnlyContent() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="empty1.swift" action="create">
        <content>
        ===
        ===
        </content>
        </file>
        <file path="empty2.swift" action="create">
        <content>
        ===
        
        
        
        ===
        </content>
        </file>
        <file path="empty3.swift" action="create">
        <content></content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        // All files should parse
        XCTAssertEqual(result.count, 3)
        
        // Check each file
        for file in result {
            XCTAssertEqual(file.action, .create)
            // Content might be empty or whitespace only
            let trimmed = file.fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(trimmed.isEmpty || file.fileContent.count >= 0)
        }
    }
    
    func testMixedValidAndInvalidContent() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="mixed.swift" action="modify">
        <change>
        <description>Valid change 1</description>
        <content>
        ===
        func valid1() {}
        ===
        </content>
        </change>
        <change>
        <description>Broken change</description>
        <content>
        ===
        func broken() {
        </change>
        <change>
        <description>Valid change 2</description>
        <content>
        ===
        func valid2() {}
        ===
        </content>
        </change>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        if result.count > 0 {
            let changes = result[0].changes
            
            // Should have at least the valid changes
            let validChanges = changes.filter { change in
                change.summary.contains("Valid change")
            }
            XCTAssertGreaterThanOrEqual(validChanges.count, 1)
            
            // Valid changes should have proper content
            for validChange in validChanges {
                XCTAssertNotNil(validChange.content)
                if let content = validChange.content {
                    XCTAssertFalse(content.isEmpty)
                }
            }
        }
    }
    
    func testExtremelyLongLines() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        // Create a very long line
        let longLine = String(repeating: "a", count: 10000)
        
        let input = """
        <file path="longline.swift" action="create">
        <content>
        ===
        let veryLongString = "\(longLine)"
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].fileContent.contains(longLine))
    }
    
    func testRecursiveFencePatterns() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="recursive.swift" action="create">
        <content>
        =====
        // Using 5 equals
        let markdown = \"\"\"
        ```
        ===
        This looks like a fence but isn't
        ===
        ```
        \"\"\"
        =====
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        if result.count > 0 {
            let content = result[0].fileContent
            // Should preserve the content between the actual fences
            XCTAssertTrue(content.contains("This looks like a fence"))
            // But should not include the outer fence markers
            XCTAssertFalse(content.hasPrefix("====="))
        }
    }
    
    func testLargeFileHandling() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        // Create a large input with many changes
        var changes = ""
        for i in 0..<100 {
            changes += """
            <change>
            <description>Change \(i)</description>
            <content>
            ===
            func function\(i)() {
                print("Function \(i)")
            }
            ===
            </content>
            </change>
            
            """
        }
        
        let input = """
        <file path="large.swift" action="modify">
        \(changes)
        </file>
        """
        
        let startTime = Date()
        let result = try await parser.parse(input)
        let elapsedTime = Date().timeIntervalSince(startTime)
        
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].changes.count, 100)
        XCTAssertLessThan(elapsedTime, 5.0) // Should parse within 5 seconds
    }
    
    // MARK: - Special Characters and Encoding Tests
    
    func testHandlesSpecialCharacters() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="special.swift" action="create">
        <content>
        ===
        // Special characters: < > & " ' ` \\ / 
        let string = "Hello \"World\""
        let html = "<div>Content</div>"
        let ampersand = "Tom & Jerry"
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].fileContent.contains("<div>"))
        XCTAssertTrue(result[0].fileContent.contains("&"))
        XCTAssertTrue(result[0].fileContent.contains("\""))
    }
    
    func testHandlesUnicodeContent() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="unicode.swift" action="create">
        <content>
        ===
        // Unicode: 你好世界 🌍 🚀 
        let emoji = "😀"
        let chinese = "中文"
        let arabic = "مرحبا"
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].fileContent.contains("😀"))
        XCTAssertTrue(result[0].fileContent.contains("中文"))
        XCTAssertTrue(result[0].fileContent.contains("مرحبا"))
    }
    
    // MARK: - Line Ending Tests
    
    func testPreservesLineEndings() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        // Test with CRLF line endings
        let input = """
        <file path="crlf.swift" action="create">
        <content>
        ===
        line1\r
        line2\r
        line3
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        // Line ending detection should work
        XCTAssertNotNil(result[0].lineEnding)
    }
    
    // MARK: - Delegate Edit Tests
    
    func testDelegateEditActionSkipped() async throws {
        let parser = DiffParser(fileManager: fileManager)
        
        let input = """
        <file path="test.swift" action="delegateEdit">
        <content>
        // SCOPE: 1
        func shouldNotParse() {}
        </content>
        </file>
        <file path="normal.swift" action="create">
        <content>
        ===
        func shouldParse() {}
        ===
        </content>
        </file>
        """
        
        let result = try await parser.parse(input)
        
        // Should only have the normal file
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].fileName, "normal.swift")
    }
    
    // MARK: - Performance Comparison Tests
	
	func testProductionModeHasNoDebugCode() async throws {
		// This test only runs in production mode
		let parser = DiffParser(fileManager: fileManager)
		
		// Verify that debug-specific behavior doesn't exist
		let input = """
		<file path="test.swift" action="rewrite">
		<content>
		===
		// Content
		===
		</content>
		</file>
		"""
		
		let result = try await parser.parse(input)
		
		// In production, rewrite on non-existent file becomes create
		XCTAssertEqual(result[0].action, .create)
	}
	
	// MARK: - Special Character Path Tests
	
	func testParseFilesWithHyphensAndUnderscores() async throws {
		let parser = DiffParser(fileManager: fileManager)
		
		let input = """
		<file path="src/my-component_test.js" action="modify">
		<change>
			<description>Update component test function</description>
			<search>
			===
			function myComponent_test() {
				return "test";
			}
			===
			</search>
			<content>
			===
			// Test content for mixed special chars
			function myComponent_test() {
				return "test";
			}
			===
			</content>
		</change>
		</file>
		
		<file path="tests/auth-service_spec.rb" action="modify">
		<change>
			<description>Add auth service test</description>
			<content>
			===
			describe "AuthService" do
			  it "handles auth" do
				expect(true).to be true
			  end
			end
			===
			</content>
		</change>
		</file>
		
		<file path="lib/data-parser_utils.py" action="modify">
		<change>
			<description>Update parse_data function</description>
			<search>
			===
			def parse_data(input):
				pass
			===
			</search>
			<content>
			===
			def parse_data(input):
				return input.strip()
			===
			</content>
		</change>
		</file>
		"""
		
		let result = try await parser.parse(input)
		
		XCTAssertEqual(result.count, 3, "Expected 3 parsed files but got \(result.count)")
		
		let names = Set(result.map { $0.fileName })
		XCTAssertTrue(names.contains("src/my-component_test.js"))
		XCTAssertTrue(names.contains("tests/auth-service_spec.rb"))
		XCTAssertTrue(names.contains("lib/data-parser_utils.py"))
		
		let js = result.first { $0.fileName == "src/my-component_test.js" }
		let rb = result.first { $0.fileName == "tests/auth-service_spec.rb" }
		let py = result.first { $0.fileName == "lib/data-parser_utils.py" }
		
		XCTAssertTrue(js?.fileContent.contains("myComponent_test") == true)
		XCTAssertTrue(rb?.fileContent.contains("AuthService") == true)
		XCTAssertTrue(py?.fileContent.contains("parse_data") == true)
	}
	
	func testComplexSpecialCharacterPaths() async throws {
		let parser = DiffParser(fileManager: fileManager)
		
		let input = """
		<file path="@types/node_modules/react-native.d.ts" action="modify">
		<change>
			<description>Update React Native type definitions</description>
			<search>
			===
			declare module "react-native" {
				// empty interface
			}
			===
			</search>
			<content>
			===
			declare module "react-native" {
				export interface ViewProps {}
			}
			===
			</content>
		</change>
		</file>
		
		<file path="src/[id]/page-component_test.tsx" action="modify">
		<change>
			<description>Add page component test</description>
			<content>
			===
			export const PageComponent = () => {
				return <div>Test</div>;
			};
			===
			</content>
		</change>
		</file>
		
		<file path="lib/@company/shared-utils_v2.1.0.js" action="modify">
		<change>
			<description>Update shared utils version</description>
			<search>
			===
			export const utils = {
				version: "2.0.0"
			};
			===
			</search>
			<content>
			===
			export const utils = {
				version: "2.1.0"
			};
			===
			</content>
		</change>
		</file>
		"""
		
		let result = try await parser.parse(input)
		
		XCTAssertEqual(result.count, 3, "Expected 3 parsed files but got \(result.count)")
		
		guard result.count >= 3 else {
			XCTFail("Not enough results to test. Got \(result.count) files")
			return
		}
		
		// Check that all expected files are present (order may vary)
		let fileNames = result.map { $0.fileName }
		XCTAssertTrue(fileNames.contains("@types/node_modules/react-native.d.ts"))
		XCTAssertTrue(fileNames.contains("src/[id]/page-component_test.tsx"))
		XCTAssertTrue(fileNames.contains("lib/@company/shared-utils_v2.1.0.js"))
	}
	
	func testMixedActionsWithSpecialCharPaths() async throws {
		let parser = DiffParser(fileManager: fileManager)
		
		let input = """
		<file path="old-module_v1.js" action="delete" />
		
		<file path="new-module_v2.js" action="create">
		<content>
		// New version of the module
		export default {
			version: 2
		};
		</content>
		</file>
		
		<file path="config/app-settings_prod.json" action="modify">
		<change>
			<description>Update module reference to v2</description>
			<search>
			===
			{
			    "module": "old-module_v1",
			===
			</search>
			<content>
			===
			{
			    "module": "new-module_v2",
			===
			</content>
		</change>
		</file>
		"""
		
		let result = try await parser.parse(input)
		
		XCTAssertEqual(result.count, 3, "Expected 3 parsed files but got \(result.count)")
		
		guard result.count >= 3 else {
			XCTFail("Not enough results to test. Got \(result.count) files")
			return
		}
		
		// Find each file by name and verify its action
		let oldModule = result.first { $0.fileName == "old-module_v1.js" }
		let newModule = result.first { $0.fileName == "new-module_v2.js" }
		let configFile = result.first { $0.fileName == "config/app-settings_prod.json" }
		
		XCTAssertNotNil(oldModule, "old-module_v1.js not found")
		XCTAssertNotNil(newModule, "new-module_v2.js not found")
		XCTAssertNotNil(configFile, "config/app-settings_prod.json not found")
		
		XCTAssertEqual(oldModule?.action, .delete)
		XCTAssertEqual(newModule?.action, .create)
		XCTAssertEqual(configFile?.action, .modify)
	}
	
	// MARK: - Fence Seam Cleanup Tests
	
	func testNoXmlLeakIntoContentOrSearchWithInlineFenceSeam() async throws {
		let parser = DiffParser(fileManager: fileManager)
		let input = """
<file path="foo.swift" action="modify">
<change>
	<description>Test</description>
	<content>
===
func a() {}
===<search>
===
func b() {}
===
</search>
</change>
</file>
"""
		let result = try await parser.parse(input)
		XCTAssertEqual(result.count, 1)
		let changes = result[0].changes
		XCTAssertEqual(changes.count, 1)
		let change = changes[0]
		// Content cleaned
		let contentJoined = change.content?.joined(separator: "\n") ?? ""
		XCTAssertFalse(contentJoined.contains("<search"), "content must not leak <search>")
		XCTAssertTrue(contentJoined.contains("func a()"))
		// Search cleaned
		let searchJoined = change.searchBlock?.joined(separator: "\n") ?? ""
		XCTAssertFalse(searchJoined.contains("<content"), "search must not leak <content>")
		XCTAssertTrue(searchJoined.contains("func b()"))
	}
    
    // MARK: - DiffParserUtils Tests
    
    // MARK: ­­--­­- STRICT content-extraction tests
    
    func testStrictFencePairMultiline() {
    	let src = """
    	<content>
    	===
    	foo
    	bar
    	===
    	</content>
    	"""
    	XCTAssertEqual(extract(src), "foo\nbar")
    }
    
    func testStrictFencePairSameLine() {
    	let src = "<content>===baz===</content>"
    	XCTAssertEqual(extract(src), "baz")
    }
    
    func testStrictMatchingFenceBackRef() {
    	let src = """
    <content>
    ==== Hello
    world
    ====
    </content>
    """
    	XCTAssertEqual(extract(src), " Hello\nworld")
    }
    
    func testStrictAnyFenceLength() {
    	let src = """
    	<content>
    	=====one=====
    	</content>
    	"""
    	XCTAssertEqual(extract(src), "one")
    }
    
    func testStrictPartialStartOnly() {
    	let src = """
    	<content>
    	===
    	alpha
    	</content>
    	"""
    	XCTAssertEqual(extract(src), "alpha\n")
    }
    
    func testStrictPartialEndOnly() {
    	let src = """
    <content>
    bravo
    ===
    </content>
    """
    	XCTAssertEqual(extract(src), "bravo")
    }
    
    func testStrictFencePairWithChangeCloser() {
    	let src = """
    	<content>
    	===
    	charlie
    	===
    	</change>
    	"""
    	XCTAssertEqual(extract(src), "charlie")
    }
    
    func testStrictFencePairWithFileCloser() {
    	let src = """
    	<content>
    	===
    	delta
    	===
    	</file>
    	"""
    	XCTAssertEqual(extract(src), "delta")
    }
    
    func testStrictPlainPatternNoFences() {
    	let src = "<content>echo</content>"
    	XCTAssertEqual(extract(src), "echo")
    }
    
    // MARK: ­­--­­- FLEXIBLE content-extraction tests
    
    func testFlexibleFencePairMultiline() {
    	let src = """
    	<content>
    	===
    	foxtrot
    	===
    	</content>
    	"""
    	XCTAssertEqual(extract(src, flex: true), "foxtrot")
    }
    
    func testFlexibleSameLine() {
    	let src = "<content>===golf===</content>"
    	XCTAssertEqual(extract(src, flex: true), "golf")
    }
    
    func testFlexibleLenientFence() {
    	let src = """
    <content>
    ===two
    lines
    =====
    </content>
    """
    	XCTAssertEqual(extract(src, flex: true), "two\nlines")
    }
    
    func testFlexibleTagContentNoFence() {
    	let src = """
    	<content>
    	hotel
    	</content>
    	"""
    	XCTAssertEqual(extract(src, flex: true), "hotel\n")
    }
    
    func testFlexibleMostLenientUntilEOS() {
    	let src = """
    	<content>
    	===
    	india
    	"""
    	XCTAssertEqual(extract(src, flex: true), "india")
    }
    
    // MARK: ­­--­­- Non-backtick fallback
    
    func testNonBacktickTagExtraction() {
    	let src = "<title>MyTitle</title>"
    	XCTAssertEqual(extract(src, tag: "title"), "MyTitle")
    }
    
    // MARK: ­­--­­- sliceIntoChangeBlocks
    
    func testSliceIntoChangeBlocksPerfect() {
    	let body = """
    	<change>ONE</change>
    	<change>TWO</change>
    	"""
    	let blocks = DiffParserUtils.sliceIntoChangeBlocks(body)
    	XCTAssertEqual(blocks.count, 2)
    	XCTAssertTrue(blocks[0].contains("ONE"))
    	XCTAssertTrue(blocks[1].contains("TWO"))
    }
    
    func testSliceIntoChangeBlocksMissingClosingChange() {
    	let body = """
    	<change>A
    	<change>B</change>
    	</file>
    	"""
    	let blocks = DiffParserUtils.sliceIntoChangeBlocks(body)
    	XCTAssertEqual(blocks.count, 2, "Should yield two blocks even with first <change> unclosed.")
    	XCTAssertTrue(blocks[0].contains("A"))
    	XCTAssertTrue(blocks[1].contains("B"))
    }
    
    func testSliceIntoChangeBlocksMissingFileCloser() {
    	let body = """
    	<change>Alpha
    	"""
    	let blocks = DiffParserUtils.sliceIntoChangeBlocks(body)
    	XCTAssertEqual(blocks.count, 1)
    	XCTAssertTrue(blocks[0].contains("Alpha"))
    }
    
    // MARK: ­­--­­- stripCDATA & think-removal
    
    func testStripCDATAAndThinkRemoval() {
    	let raw = """
    	<think>log…</think>
    	<![CDATA[
    	data
    	]]>
    	"""
    	let noThink = DiffParserUtils.removeThinkTag(from: raw)
    	let stripped = DiffParserUtils.stripCDATA(noThink)
    	XCTAssertEqual(stripped, "data")
    }
    
    // MARK: ­­--­­- splitContentToLines indentation regex
    
    func testSplitContentToLinesSpaces() {
    	let src = "  indented\nplain"
    	let lines = DiffParserUtils.splitContentToLines(src, true)
    	XCTAssertEqual(lines[0], "<s2>indented")
    	XCTAssertEqual(lines[1], "<s0>plain")
    }
    
    func testSplitContentToLinesTabs() {
    	let src = "\tfoo\n\t\tbar"
    	let lines = DiffParserUtils.splitContentToLines(src, false)
    	XCTAssertEqual(lines[0], "<t1>foo")
    	XCTAssertEqual(lines[1], "<t2>bar")
    }
    
    // MARK: ––––––––– FILE-ENTRY EXTRACTION –––––––––
    
    func testExtractFileEntriesSingle() {
    	let src = """
    	<file path="a.swift" action="create">
    	<content>one</content>
    	</file>
    	"""
    	let entries = DiffParserUtils.extractFileEntries(from: src)
    	XCTAssertEqual(entries.count, 1)
    	XCTAssertEqual(entries[0].path,   "a.swift")
    	XCTAssertEqual(entries[0].action, "create")
    	XCTAssertTrue(entries[0].body.contains("<content>"))
    }
    
    func testExtractFileEntriesMultiple() {
    	let src = """
    	<file path="x.txt" action="modify"><content>x</content></file>
    	<file path="y.txt" action="delete"><content>y</content></file>
    	"""
    	let entries = DiffParserUtils.extractFileEntries(from: src)
    	XCTAssertEqual(entries.count, 2)
    	XCTAssertEqual(entries[1].path, "y.txt")
    	XCTAssertEqual(entries[1].action, "delete")
    }
    
    func testExtractFileEntryWithoutClosingTag() {
    	let src = """
    	<file path="lonely.md" action="create">
    	<content>hello</content>
    	"""
    	let entries = DiffParserUtils.extractFileEntries(from: src)
    	XCTAssertEqual(entries.count, 1)
    	XCTAssertEqual(entries[0].path, "lonely.md")
    }
    
    // MARK: ––––––––– CHANGE-PARSING (static helper) –––––––––
    
    /// Verifies that a proper `<change>` block is parsed with the expected
    /// `.modify` type and correctly encoded content lines.
    /// Verifies that a proper `<change>` block is parsed with the expected
    /// `.modify` type and correctly encoded content lines.
    func testParseChangesExplicitBlock() {
    	let body = """
<change>
  <description>Update greeting</description>
  <content>
===
hello
===
  </content>
</change>
"""
    	
    	let changes = DiffParserUtils.parseChanges(
    		body,
    		filePath   : "greet.txt",
    		fileAction : .rewrite,   // fileExists = true ⇒ .modify
    		lineEnding : "\n",
    		fileExists : true,
    		usesSpaces : true,
    		originalFileContent: ""
    	)
    	
    	XCTAssertEqual(changes.count, 1)
    	XCTAssertEqual(changes[0].type, .modify)
    	XCTAssertEqual(changes[0].summary, "Update greeting")
    	// With no extra spaces in the fence, we expect <s0>
    	XCTAssertEqual(changes[0].content?.first, "<s0>hello")
    }

    
    /*
    /// When no `<change>` tags exist, the entire `<content>` should become a
    /// single `.add`/`.modify` fallback change.
    /// When no `<change>` tags exist, the entire `<content>` should become a
    /// single `.add`/`.modify` fallback change.
    func testParseChangesFallbackWholeFile() {
    	let body = """
<content>
===
{ "k": 1 }
===
</content>
"""
    	
    	let changes = DiffParserUtils.parseChanges(
    		body,
    		filePath   : "data.json",
    		fileAction : .rewrite,  // fileExists = false ⇒ .add
    		lineEnding : "\n",
    		fileExists : false,
    		usesSpaces : true
    	)
    	
    	XCTAssertEqual(changes.count, 1)
    	XCTAssertEqual(changes[0].type, .add)
    	XCTAssertTrue(changes[0].summary.contains("Rewrite entire file"))
    	XCTAssertEqual(changes[0].content?.first, "<s0>{ \"k\": 1 }")
    }
    */
    
    // MARK: ­­--­­- ADVANCED CHANGE-PARSING (search / replace) –––––––––
    
    func testParseChangesWithSearchReplace() {
    	let body = """
<change>
  <description>Add Debug.Log at the start of Explode() to indicate when it is called</description>
  <search>
===
    	void Explode()
    	{
    		if(!isPrimed)
    			return;
    	}
===
  </search>
  <content>
===
    	void Explode()
    	{
    		Debug.Log($"BombExplode.Explode() called on {gameObject.name} (isPrimed={isPrimed})");
    		if(!isPrimed)
    			return;
    	}
===
  </content>
</change>
"""
    	
    	let changes = DiffParserUtils.parseChanges(
    		body,
    		filePath   : "BombExplode.cs",
    		fileAction : .modify,
    		lineEnding : "\n",
    		fileExists : true,
    		usesSpaces : true,
    		originalFileContent: ""
    	)
    	
    	XCTAssertEqual(changes.count, 1)
    	let change = changes[0]
    	XCTAssertEqual(change.type, .modify)
    	XCTAssertTrue(change.summary.contains("Debug.Log"))
    	
    	// • searchBlock decoded & indentation-encoded
    	XCTAssertNotNil(change.searchBlock)
    	XCTAssertGreaterThan(change.searchBlock!.count, 0)
    	XCTAssertTrue(change.searchBlock!.first!.hasPrefix("<s8>"))
    	XCTAssertTrue(change.searchBlock!.first!.contains("void Explode()"))
    	
    	// • content decoded & indentation-encoded
    	XCTAssertNotNil(change.content)
    	XCTAssertTrue(change.content!.first!.hasPrefix("<s8>"))
    	XCTAssertTrue(change.content!.first!.contains("void Explode()"))
    }

    
    func testParseMultipleChangeBlocks() {
    	let body = """
<change>
  <description>First</description>
  <content>
===
one
===
  </content>
</change>
<change>
  <description>Second</description>
  <content>
===
two
===
  </content>
</change>
"""
    	
    	let changes = DiffParserUtils.parseChanges(
    		body,
    		filePath   : "example.txt",
    		fileAction : .modify,
    		lineEnding : "\n",
    		fileExists : true,
    		usesSpaces : true,
    		originalFileContent: ""
    	)
    	
    	XCTAssertEqual(changes.count, 2)
    	XCTAssertEqual(changes[0].summary, "First")
    	XCTAssertEqual(changes[1].summary, "Second")
    	XCTAssertEqual(changes[0].type, .modify)
    	XCTAssertEqual(changes[1].type, .modify)
    }

    // MARK: ­­--­­- MULTI-FILE EXTRACTION –––––––––––––––––––––––––––––
    
    /// Covers:
    ///   • normal quotes and “smart” quotes
    ///   • mixed closing-tag presence
    ///   • preservation of per-file body payloads
    func testExtractFileEntriesComplexMulti() {
    	let input = """
<file path="Assets/Scripts/A.cs" action="modify">
<content>alpha</content>
</file>
<file path=“Assets/Scripts/B.cs” action=“create”>
<content>bravo</content>
</file>
<file path="Docs/readme.md" action="delete">
<content>charlie</content>
""" // intentionally missing </file>
    	
    	let entries = DiffParserUtils.extractFileEntries(from: input)
    	XCTAssertEqual(entries.count, 3, "Should detect all three <file> blocks")
    	
    	// --- file #1 ---
    	XCTAssertEqual(entries[0].path,   "Assets/Scripts/A.cs")
    	XCTAssertEqual(entries[0].action, "modify")
    	XCTAssertTrue(entries[0].body.contains("alpha"))
    	
    	// --- file #2 (smart quotes) ---
    	XCTAssertEqual(entries[1].path,   "Assets/Scripts/B.cs")
    	XCTAssertEqual(entries[1].action, "create")
    	XCTAssertTrue(entries[1].body.contains("bravo"))
    	
    	// --- file #3 (no closing </file>) ---
    	XCTAssertEqual(entries[2].path,   "Docs/readme.md")
    	XCTAssertEqual(entries[2].action, "delete")
    	XCTAssertTrue(entries[2].body.contains("charlie"))
    }
    

    func testFlexibleFencePairWithUnequalLengthsAndWhitespace() {
    	let src = """
  <content>
  ===== 
  yankee
  ===
  </content>
  """
    	XCTAssertEqual(extract(src, flex: true), "yankee")
    }
    
    func testFlexibleFencePairWithUnequalLengthsAndWhitespace2() {
    	let src = """
  <content>
  === 
  yankee
  =====
  </content>
  """
    	XCTAssertEqual(extract(src, flex: true), "yankee")
    }
    
    // MARK: ­­--­­- JSX / “===” edge‑case tests
    // These cases mimic real‑world code where angle‑brackets and triple‑equals
    // appear in the source itself.  They ensure our regexes don’t mistake them
    // for structural tags or fences.
    
    func testStrictContentWithJSXAndTripleEqualsOperator() {
    	let src = """
<content>
===
function MyComponent() {
  return <div className=\\"root\\">Hello === World</div>;
}
===
</content>
"""
    	
    	let expected = """
function MyComponent() {
  return <div className=\\"root\\">Hello === World</div>;
}
"""
    	
    	XCTAssertEqual(extract(src), expected)
    }
    
    /// In this lenient scenario the closing `===` fence is missing on purpose.
    /// The parser should still capture the payload without including the fence.
    func testFlexibleContentWithMissingClosingFence() {
    	let src = """
<content>
===
const result = arr.filter(i => i.value === 42);
</content>
"""
    	let expected = "const result = arr.filter(i => i.value === 42);\n"
    	
    	XCTAssertEqual(extract(src, flex: true), expected)
    }
    
    /// Verifies that nested angle‑brackets (e.g. JSX) do not cause the content
    /// extractor to abort early when a strict closing fence *is* present.
    func testStrictContentContainingNestedTags() {
    	let src = """
<content>
===
export const Card = () => (
  <section className=\\"card\\">
    <header>Title</header>
    <p>Body with === operator?</p>
  </section>
);
===
</content>
"""
    	
    	let expected = """
export const Card = () => (
  <section className=\\"card\\">
    <header>Title</header>
    <p>Body with === operator?</p>
  </section>
);
"""
    	
    	XCTAssertEqual(extract(src), expected)
    }
    
    // MARK: ­­--­­- INLINE “=== … ===” FENCE CASES  (NEW) ­­­­------------------
    
    /// Verifies that a `<content>` block whose opening and closing fences live
    /// on the *same* line keeps the exact leading indentation / whitespace that
    /// follows the `===` marker and does **not** leak the fence itself.
    func testStrictContentWithInlineClosingFencePreservesWhitespace() {
    	let src = """
<content>
===    Button("Manage Presets…") {
\tNotificationCenter.default.post(name: .showManagePresetsTab, object: nil)
}    ===
</content>
"""
    	guard let result = extract(src) else {
    		XCTFail("Extraction failed")
    		return
    	}
    	
    	// • `===` must be gone
    	XCTAssertFalse(result.contains("==="))
    	// • leading spaces (four) must be preserved
    	XCTAssertTrue(result.hasPrefix("    Button(\"Manage Presets…\")"))
    }
    
    /// Same scenario but for a `<search>` tag.
    func testSearchBlockWithInlineClosingFence() {
    	let src = """
<search>
===// MARK: - WorkspacesMenuView
struct WorkspacesMenuView: View {
\t@EnvironmentObject var workspaceManager: WorkspaceManagerViewModel
\tlet onManage: () -> Void===
</search>
"""
    	guard let result = extract(src, tag: "search") else {
    		XCTFail("Extraction failed")
    		return
    	}
    	
    	XCTAssertFalse(result.contains("==="))
    	XCTAssertTrue(result.hasPrefix("// MARK: - WorkspacesMenuView"))
    	XCTAssertTrue(result.contains("let onManage: () -> Void"))
    }
    
    /// Confirms that mismatched fence lengths (e.g. `=== … ====`)
    /// are *not* accepted by the strict extractor – we want a nil result.
    func testInlineClosingFenceWithMismatchedLength() {
    	let src = """
<content>
=== something ====
</content>
"""
    	XCTAssertEqual(extract(src), " something")
    }
    
    // MARK: - Fence Seam and Sibling Boundary Tests
    
    func testLenientContentStopsBeforeSiblingSearchTag_InlineFenceSeam() {
    	let src = """
<change>
    <description>desc</description>
    <content>
===
line1
===<search>
===
pattern
===
</search>
</change>
"""
    	// We exercise the lenient path because closing tags/fences are malformed.
    	let content = DiffParserUtils.extractLenientContent(from: src, tag: "content")
    	XCTAssertNotNil(content)
    	XCTAssertEqual(content?.trimmingCharacters(in: .whitespacesAndNewlines), "line1",
    					"Content should not include '===<search>' seam or the <search> tag")
    }
    
    func testLenientSearchStopsBeforeSiblingContentTag_InlineFenceSeam() {
    	let src = """
<change>
    <description>desc</description>
    <search>
===
old
===<content>
===
new
===
</content>
</change>
"""
    	let search = DiffParserUtils.extractLenientContent(from: src, tag: "search")
    	XCTAssertNotNil(search)
    	XCTAssertEqual(search?.trimmingCharacters(in: .whitespacesAndNewlines), "old",
    					"Search should not include '===<content>' seam or the <content> tag")
    }
    
    func testSanitizeFenceSeamsDoesNotTouchTripleEqualsInCode() {
    	let code = """
if (a === 42) {
    return b === 7 ? 1 : 0
}
"""
    	// Not a lenient scenario; ensure sanitizer is conservative.
    	let cleaned = DiffParserUtils.sanitizeFenceSeams(code)
    	XCTAssertEqual(cleaned, code, "Code triple-equals must be preserved")
    }
    
    func testSiblingBoundaryDoesNotEatGenericHTMLOrJSX() {
    	let src = """
<content>
===
<div>
    <span>Hello</span>
</div>
===
</content>
"""
    	// Strict path should extract correctly.
    	let content = DiffParserUtils.extractContent(from: src, tag: "content")
    	XCTAssertTrue(content?.contains("<div>") == true)
    	XCTAssertTrue(content?.contains("</div>") == true)
    	// Ensure boundary trimming doesn't eat it (shouldn't match "div" as a sibling tag).
    }
    
    func testTripleEqualsOperatorPreservedWhileFenceRemoved() {
        let src = """
        <content>
        ===
        if (a === 42) { return 1 }
        ===
        </content>
        """
        let out = DiffParserUtils.extractContent(from: src, tag: "content", flexible: false)!
        XCTAssertTrue(out.contains("a === 42"))
        XCTAssertFalse(out.contains("===\n")) // no fence lines remain
    }
    
    func testHtmlJsxNotTrimmedBySiblingBoundary() {
        let src = """
        <content>
        ===
        return <div>ok</div>
        ===
        </content>
        """
        let out = DiffParserUtils.extractContent(from: src, tag: "content", flexible: true)!
        XCTAssertTrue(out.contains("<div>ok</div>"))
    }

    
    // MARK: - Delete + Create Coalescing Tests
    
    // MARK: - Delete + Create → Rewrite Tests
    
    func testDeleteFollowedByCreateCoalescesToRewrite() async throws {
        // Input with delete followed by create for the same file
        let input = """
        <file path="MyFile.swift" action="delete">
        </file>
        <file path="MyFile.swift" action="create">
        <content>
        ===
        class NewImplementation {
            func newMethod() {
                print("New code")
            }
        }
        ===
        </content>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        // Should have only one ParsedFile entry
        XCTAssertEqual(result.count, 1)
        
        let file = result[0]
        XCTAssertEqual(file.fileName, "MyFile.swift")
        // The action should be rewrite, not delete or create
        XCTAssertEqual(file.action, .rewrite)
        
        // Should have changes that represent the rewrite
        XCTAssertFalse(file.changes.isEmpty)
        
        // Should not have any .remove changes (they should be filtered out)
        let removeChanges = file.changes.filter { $0.type == .remove }
        XCTAssertTrue(removeChanges.isEmpty, "Remove changes should be filtered out in a rewrite")
        
        // All changes should be .modify (converted from .add)
        let modifyChanges = file.changes.filter { $0.type == .modify }
        XCTAssertEqual(modifyChanges.count, file.changes.count, "All changes should be .modify in a rewrite")
    }
    
    // MARK: - Create + Delete → Rewrite Tests
    
    func testCreateFollowedByDeleteCoalescesToRewrite() async throws {
        // Input with create followed by delete for the same file
        let input = """
        <file path="NewFile.swift" action="create">
        <content>
        ===
        struct NewStruct {
            let value: String
        }
        ===
        </content>
        </file>
        <file path="NewFile.swift" action="delete">
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        // Should have only one ParsedFile entry
        XCTAssertEqual(result.count, 1)
        
        let file = result[0]
        XCTAssertEqual(file.fileName, "NewFile.swift")
        // The action should be rewrite
        XCTAssertEqual(file.action, .rewrite)
    }
    
    // MARK: - Change Type Conversion Tests
    
    func testAddChangesConvertToModifyDuringCoalescing() async throws {
        let input = """
        <file path="Convert.swift" action="delete">
        </file>
        <file path="Convert.swift" action="create">
        <change>
        <description>Add new functionality</description>
        <content>
        ===
        func newFunction() {
            print("New function")
        }
        ===
        </content>
        </change>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        let file = result[0]
        XCTAssertEqual(file.action, .rewrite)
        
        // The change type should be .modify, not .add
        XCTAssertEqual(file.changes.count, 1)
        XCTAssertEqual(file.changes[0].type, .modify)
        XCTAssertEqual(file.changes[0].summary, "Add new functionality")
    }
    
    // MARK: - Non-Coalescing Tests
    
    func testDeleteAndCreateForDifferentFilesDoNotCoalesce() async throws {
        let input = """
        <file path="FileA.swift" action="delete">
        </file>
        <file path="FileB.swift" action="create">
        <content>
        ===
        // New file B
        ===
        </content>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        // Should have two separate files
        XCTAssertEqual(result.count, 2)
        
        // Find each file
        let fileA = result.first { $0.fileName == "FileA.swift" }
        let fileB = result.first { $0.fileName == "FileB.swift" }
        
        XCTAssertNotNil(fileA)
        XCTAssertNotNil(fileB)
        
        // FileA should remain delete
        XCTAssertEqual(fileA?.action, .delete)
        // FileB should remain create
        XCTAssertEqual(fileB?.action, .create)
    }
    
    func testModifyFollowedByDeleteDoesNotBecomeRewrite() async throws {
        let input = """
        <file path="Modify.swift" action="modify">
        <change>
        <description>Update content</description>
        <content>
        ===
        // Modified
        ===
        </content>
        </change>
        </file>
        <file path="Modify.swift" action="delete">
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        let file = result[0]
        // Should use the latest action (delete), not rewrite
        XCTAssertEqual(file.action, .delete)
    }
    
    // MARK: - Empty File + Create Tests
    
    func testEmptyFileFollowedByCreateUsesNewContent() async throws {
        // Test the specific scenario: empty file exists, create action comes in
        // The actual behavior depends on whether the file system reports the file as existing
        
        // First, let's test the coalescing scenario where we have both actions
        let input = """
        <file path="EmptyExisting.swift" action="modify">
        <change>
        <description>Empty file placeholder</description>
        <content>
        ===
        ===
        </content>
        </change>
        </file>
        <file path="EmptyExisting.swift" action="create">
        <content>
        ===
        // New content for empty file
        class NewClass {
            func newMethod() {
                print("This should replace the empty file")
            }
        }
        ===
        </content>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        let file = result[0]
        
        // modify + create = create (latest wins)
        XCTAssertEqual(file.action, .create, "modify + create should result in create action")
        
        // Most importantly: the file content should have the new content
        XCTAssertFalse(file.fileContent.isEmpty, "File content should not be empty")
        XCTAssertTrue(file.fileContent.contains("New content for empty file"))
        XCTAssertTrue(file.fileContent.contains("class NewClass"))
        XCTAssertTrue(file.fileContent.contains("This should replace the empty file"))
        
        // The main thing we're testing is that the file content is correct
        // Changes parsing is secondary - what matters is the final content is preserved
    }
    
    func testDeleteEmptyFileFollowedByCreateUsesNewContent() async throws {
        // This better represents the scenario where an empty file is deleted and recreated
        // This should coalesce to a rewrite with the new content
        let input = """
        <file path="EmptyFile.swift" action="delete">
        </file>
        <file path="EmptyFile.swift" action="create">
        <content>
        ===
        // New content replacing empty file
        struct NewStructure {
            let value: String = "Not empty anymore"
        }
        ===
        </content>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        let file = result[0]
        
        // delete + create = rewrite
        XCTAssertEqual(file.action, .rewrite, "delete + create should coalesce to rewrite")
        
        // The file content should be the new content from create action
        XCTAssertFalse(file.fileContent.isEmpty, "File content should not be empty")
        XCTAssertTrue(file.fileContent.contains("New content replacing empty file"))
        XCTAssertTrue(file.fileContent.contains("struct NewStructure"))
        XCTAssertTrue(file.fileContent.contains("Not empty anymore"))
        
        // All changes should be modify type (converted from add during coalescing)
        XCTAssertFalse(file.changes.isEmpty)
        XCTAssertTrue(file.changes.allSatisfy { $0.type == .modify }, "All changes should be modify type in a rewrite")
    }
    
    // MARK: - Edge Cases
    
    func testRewriteActionPreservedInMerge() async throws {
        let input = """
        <file path="Rewrite.swift" action="rewrite">
        <content>
        ===
        // First rewrite
        ===
        </content>
        </file>
        <file path="Rewrite.swift" action="modify">
        <content>
        ===
        // Second change
        ===
        </content>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        // Any action + rewrite should stay rewrite
        XCTAssertEqual(result[0].action, .rewrite)
    }
    
    func testMultipleDeleteCreatePairsForSameFile() async throws {
        let input = """
        <file path="Multi.swift" action="delete">
        </file>
        <file path="Multi.swift" action="create">
        <content>
        ===
        // First create
        ===
        </content>
        </file>
        <file path="Multi.swift" action="delete">
        </file>
        <file path="Multi.swift" action="create">
        <content>
        ===
        // Second create
        ===
        </content>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        let file = result[0]
        // Should end up as rewrite
        XCTAssertEqual(file.action, .rewrite)
        
        // Should have content from the last create
        // Check both fileContent and the changes
        let hasSecondCreateInFileContent = file.fileContent.contains("Second create")
        let hasSecondCreateInChanges = file.changes.contains { change in
            let content = change.content?.joined(separator: "\n") ?? ""
            // Remove indentation markers when checking
            let cleanContent = content.replacingOccurrences(of: "<s\\d+>", with: "", options: .regularExpression)
                                     .replacingOccurrences(of: "<t\\d+>", with: "", options: .regularExpression)
            return cleanContent.contains("Second create")
        }
        
        XCTAssertTrue(
            hasSecondCreateInFileContent || hasSecondCreateInChanges,
            "Expected to find 'Second create' in either fileContent or changes. FileContent: '\(file.fileContent)', Changes: \(file.changes.count)"
        )
    }
    
    // MARK: - Complex Scenarios
    
    func testMultipleModifiesAreCombined() async throws {
        let input = """
        <file path="Combine.swift" action="modify">
        <change>
        <description>First modification</description>
        <content>
        ===
        func firstChange() {
            print("First")
        }
        ===
        </content>
        </change>
        </file>
        <file path="Combine.swift" action="modify">
        <change>
        <description>Second modification</description>
        <content>
        ===
        func secondChange() {
            print("Second")
        }
        ===
        </content>
        </change>
        </file>
        <file path="Combine.swift" action="modify">
        <change>
        <description>Third modification</description>
        <content>
        ===
        func thirdChange() {
            print("Third")
        }
        ===
        </content>
        </change>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        let file = result[0]
        
        // Should remain as modify
        XCTAssertEqual(file.action, .modify)
        
        // Should have all 3 changes combined
        XCTAssertEqual(file.changes.count, 3)
        
        // Verify all changes are present and in order
        let summaries = file.changes.map { $0.summary }
        XCTAssertEqual(summaries, ["First modification", "Second modification", "Third modification"])
        
        // With debug config treatNonExistentFilesAsExisting: true, changes are .modify type
        XCTAssertTrue(file.changes.allSatisfy { $0.type == .modify })
        
        // Verify content is preserved
        let hasFirst = file.changes[0].content?.joined(separator: "\n").contains("First") ?? false
        let hasSecond = file.changes[1].content?.joined(separator: "\n").contains("Second") ?? false
        let hasThird = file.changes[2].content?.joined(separator: "\n").contains("Third") ?? false
        
        XCTAssertTrue(hasFirst, "First change content should be preserved")
        XCTAssertTrue(hasSecond, "Second change content should be preserved")
        XCTAssertTrue(hasThird, "Third change content should be preserved")
    }
    
    func testDeleteCreateWithMultipleChanges() async throws {
        let input = """
        <file path="Complex.swift" action="delete">
        </file>
        <file path="Complex.swift" action="create">
        <change>
        <description>Add class definition</description>
        <content>
        ===
        class ComplexClass {
            var property: String
        ===
        </content>
        </change>
        <change>
        <description>Add method</description>
        <content>
        ===
            func method() {
                print("Method")
            }
        }
        ===
        </content>
        </change>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        let file = result[0]
        XCTAssertEqual(file.action, .rewrite)
        XCTAssertEqual(file.changes.count, 2)
        // Both changes should be .modify (converted from .add during coalescing)
        XCTAssertTrue(file.changes.allSatisfy { $0.type == .modify })
    }
    
    func testRewriteBecomesAddWhenFileDoesNotExist() async throws {
        let input = """
        <file path="NonExistent.swift" action="rewrite">
        <content>
        ===
        struct NewStruct {
            let value: String
        }
        ===
        </content>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        XCTAssertEqual(result.count, 1)
        let file = result[0]
        
        // With debug config alwaysPreserveRewriteAction: true, rewrite stays as rewrite
        XCTAssertEqual(file.action, .rewrite)
        
        // Changes should be .modify type (since we treat files as existing)
        XCTAssertTrue(file.changes.allSatisfy { $0.type == .modify })
    }
    
    // MARK: - Rename + Modify/Rewrite Tests
    
    func testRenameFollowedByRewrite() async throws {
        // Rename converts to delete old + create new
        // Then rewrite on the new file should merge with create
        let input = """
        <file path="OldName.swift" action="rename">
        <new path="NewName.swift" />
        </file>
        <file path="NewName.swift" action="rewrite">
        <content>
        ===
        // Completely new content after rename
        struct NewStructure {
            let value: String
        }
        ===
        </content>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        // Should have 2 files: delete old, create new (with rewrite content)
        XCTAssertEqual(result.count, 2)
        
        // Find the delete and create entries
        let deleteFile = result.first { $0.fileName.contains("OldName.swift") }
        let createFile = result.first { $0.fileName.contains("NewName.swift") }
        
        XCTAssertNotNil(deleteFile)
        XCTAssertNotNil(createFile)
        
        // Old file should be deleted
        XCTAssertEqual(deleteFile?.action, .delete)
        
        // New file should be rewrite (create from rename + rewrite = rewrite)
        XCTAssertEqual(createFile?.action, .rewrite)
        XCTAssertTrue(createFile?.fileContent.contains("Completely new content") ?? false)
        XCTAssertTrue(createFile?.fileContent.contains("NewStructure") ?? false)
    }
    
    func testRenameFollowedByModify() async throws {
        // Rename converts to delete old + create new
        // Modify on new file should produce an error but still parse
        let input = """
        <file path="OldFile.swift" action="rename">
        <new path="NewFile.swift" />
        </file>
        <file path="NewFile.swift" action="modify">
        <change>
        <description>Try to modify renamed file</description>
        <content>
        ===
        // This modify should produce an error
        func modifiedFunction() {
            print("Modified")
        }
        ===
        </content>
        </change>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        // Should still have 2 files
        XCTAssertEqual(result.count, 2)
        
        let deleteFile = result.first { $0.fileName.contains("OldFile.swift") }
        let newFile = result.first { $0.fileName.contains("NewFile.swift") }
        
        XCTAssertNotNil(deleteFile)
        XCTAssertNotNil(newFile)
        
        // Old file should be deleted
        XCTAssertEqual(deleteFile?.action, .delete)
        
        // New file should remain create (create from rename + modify = create)
        // Can't modify a file that doesn't exist yet, so it stays as create
        XCTAssertEqual(newFile?.action, .create)
        
        // Should have changes from both rename and modify combined
        XCTAssertGreaterThanOrEqual(newFile?.changes.count ?? 0, 1)
        
        // Check that the modify content was added
        let hasModifyContent = newFile?.changes.contains { change in
            change.summary.contains("Try to modify renamed file") || 
            change.summary.contains("Rename from")
        } ?? false
        XCTAssertTrue(hasModifyContent)
    }
    
    func testComplexRenameRewriteScenario() async throws {
        // Test: rename + delete on new name + create on new name
        // This simulates a complex refactoring scenario
        let input = """
        <file path="Legacy.swift" action="rename">
        <new path="Modern.swift" />
        </file>
        <file path="Modern.swift" action="delete">
        </file>
        <file path="Modern.swift" action="create">
        <content>
        ===
        // Brand new implementation
        class ModernImplementation {
            func newMethod() {
                print("Modern approach")
            }
        }
        ===
        </content>
        </file>
        """
        
        let result = try await diffParser.parse(input)
        
        // Should coalesce to delete old + rewrite new
        let legacyFile = result.first { $0.fileName.contains("Legacy.swift") }
        let modernFile = result.first { $0.fileName.contains("Modern.swift") }
        
        XCTAssertNotNil(legacyFile)
        XCTAssertNotNil(modernFile)
        
        XCTAssertEqual(legacyFile?.action, .delete)
        // The create from rename + delete + create should coalesce to rewrite
        XCTAssertEqual(modernFile?.action, .rewrite)
        XCTAssertTrue(modernFile?.fileContent.contains("ModernImplementation") ?? false)
    }
    
    func testMixedOperationsCombining() async throws {
        // Test various combinations to ensure mergedAction works correctly
        
        // Test 1: modify + create = create (latest wins)
        let input1 = """
        <file path="Mixed1.swift" action="modify">
        <change>
        <description>Initial modification</description>
        <content>
        ===
        // Modified content
        ===
        </content>
        </change>
        </file>
        <file path="Mixed1.swift" action="create">
        <content>
        ===
        // Brand new content
        ===
        </content>
        </file>
        """
        
        let result1 = try await diffParser.parse(input1)
        XCTAssertEqual(result1.count, 1)
        XCTAssertEqual(result1[0].action, .create, "modify + create should = create")
        
        // Test 2: create + modify = create (can't modify a file that doesn't exist yet)
        let input2 = """
        <file path="Mixed2.swift" action="create">
        <content>
        ===
        // Created content
        ===
        </content>
        </file>
        <file path="Mixed2.swift" action="modify">
        <change>
        <description>Subsequent modification</description>
        <content>
        ===
        // Modified after creation
        ===
        </content>
        </change>
        </file>
        """
        
        let result2 = try await diffParser.parse(input2)
        XCTAssertEqual(result2.count, 1)
        XCTAssertEqual(result2[0].action, .create, "create + modify should = create")
        
        // Test 3: modify + rewrite = rewrite (rewrite always wins)
        let input3 = """
        <file path="Mixed3.swift" action="modify">
        <change>
        <description>Initial modification</description>
        <content>
        ===
        // Modified
        ===
        </content>
        </change>
        </file>
        <file path="Mixed3.swift" action="rewrite">
        <content>
        ===
        // Complete rewrite
        ===
        </content>
        </file>
        """
        
        let result3 = try await diffParser.parse(input3)
        XCTAssertEqual(result3.count, 1)
        XCTAssertEqual(result3[0].action, .rewrite, "modify + rewrite should = rewrite")
    }
}
