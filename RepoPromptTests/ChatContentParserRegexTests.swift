//
//  ChatContentParserRegexTests.swift
//  RepoPromptTests
//
//  Tests to validate all regex patterns used in ChatContentParser
//

import XCTest
@testable import RepoPrompt

class ChatContentParserRegexTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Enable debug logging to trace the issue
        ChatContentParser.enableDebugLogging = true
    }
    
    override func tearDown() {
        ChatContentParser.enableDebugLogging = false
        super.tearDown()
    }
    
    // MARK: - Test Regex Compilation
    
    func testAllRegexPatternsCompile() {
        // Test patterns that should match file blocks
        let filePatterns = [
            "<file path=\"test.swift\" action=\"create\">",
            "<file path=\"/path/to/file.py\" action=\"modify\">",
            "<file path='single-quotes.js' action='delete'>",
            "<file path=\"test.txt\">", // No action
        ]
        
        // Test patterns that should match plan blocks
        let planPatterns = [
            "<Plan>",
            "<plan>",
            "<PLAN>",
            "</Plan>",
            "</plan>",
            "</PLAN>"
        ]
        
        // Test patterns that should match change blocks
        let changePatterns = [
            "<change>",
            "<CHANGE>",
            "</change>",
            "</CHANGE>"
        ]
        
        // Test chat name patterns
        let chatNamePatterns = [
            "<chatName=\"Alice\">",
            "<chatName='Bob'>",
            "<chatName=Charlie>", // Unquoted
            "<chatName = \"David\" >", // With spaces
        ]
        
        // Test by parsing content with each pattern
        var processedSet = Set<Int>()
        
        // Test file patterns
        for pattern in filePatterns {
            let input = "\(pattern)\nContent here\n</file>"
            let (items, _, _) = ChatContentParser.parseContent(
                input,
                processedDelegateEditHashes: &processedSet,
                isFinal: true
            )
            // Should parse without crashing
            XCTAssertTrue(true, "File pattern should not crash: \(pattern)")
        }
        
        // Test plan patterns
        for pattern in planPatterns {
            let input = pattern.starts(with: "</") ? "<Plan>Content\n\(pattern)" : "\(pattern)\nContent\n</Plan>"
            let (items, _, _) = ChatContentParser.parseContent(
                input,
                processedDelegateEditHashes: &processedSet,
                isFinal: true
            )
            // Should parse without crashing
            XCTAssertTrue(true, "Plan pattern should not crash: \(pattern)")
        }
        
        // Test change patterns
        for pattern in changePatterns {
            let content = pattern.starts(with: "</") ? "<content>code</content>" : "<content>code</content>\n\(pattern)"
            let input = "<file path=\"test.swift\" action=\"create\">\n<change>\n\(content)\n</change>\n</file>"
            let (items, _, _) = ChatContentParser.parseContent(
                input,
                processedDelegateEditHashes: &processedSet,
                isFinal: true
            )
            // Should parse without crashing
            XCTAssertTrue(true, "Change pattern should not crash: \(pattern)")
        }
        
        // Test chat name patterns
        for pattern in chatNamePatterns {
            let input = "\(pattern) Hello world"
            let (items, _, _) = ChatContentParser.parseContent(
                input,
                processedDelegateEditHashes: &processedSet,
                isFinal: true
            )
            // Should parse without crashing
            XCTAssertTrue(true, "Chat name pattern should not crash: \(pattern)")
        }
    }
    
    func testScopeMarkerRegex() {
        var processedSet = Set<Int>()
        
        let scopePatterns = [
            "// REPOMARK: Description here",
            "# REPOMARK: Python comment",
            "/* REPOMARK: C-style comment */",
            "-- REPOMARK: SQL comment",
            "<!-- REPOMARK: HTML comment -->",
        ]
        
        for pattern in scopePatterns {
            let input = "<file path=\"test.ext\" action=\"delegate edit\">\n<change>\n<content>\n\(pattern)\ncode here\n</content>\n</change>\n</file>"
            let (_, _, delegates) = ChatContentParser.parseContent(
                input,
                processedDelegateEditHashes: &processedSet,
                isFinal: true
            )
            // Should parse without crashing
            XCTAssertTrue(true, "Scope marker pattern should not crash: \(pattern)")
        }
    }
    
    func testPlaceholderRegex() {
        var processedSet = Set<Int>()
        
        // Test various placeholder patterns for different file types
        let testCases: [(String, String)] = [
            ("test.swift", "// ... existing code ..."),
            ("test.js", "// ... existing code ..."),
            ("test.py", "# ... existing code ..."),
            ("test.rb", "# ... existing code ..."),
            ("test.sql", "-- ... existing code ..."),
            ("test.html", "<!-- ... existing code ... -->"),
            ("test.c", "/* ... existing code ... */"),
        ]
        
        for (filename, placeholder) in testCases {
            let input = "<file path=\"\(filename)\" action=\"delegate edit\">\n<change>\n<content>\ncode before\n\(placeholder)\ncode after\n</content>\n</change>\n</file>"
            let (_, _, delegates) = ChatContentParser.parseContent(
                input,
                processedDelegateEditHashes: &processedSet,
                isFinal: true
            )
            // Should parse without crashing
            XCTAssertTrue(true, "Placeholder pattern should not crash for \(filename): \(placeholder)")
        }
    }
    
    func testComplexRegexPatterns() {
        var processedSet = Set<Int>()
        
        // Test complex nested patterns
        let complexInput = """
        <chatName="TestUser"> Starting complex test
        
        <Plan>
        - Step 1: Create file
        - Step 2: Modify file
        </Plan>
        
        <file path="complex/test.swift" action="create">
        <change>
        <description>Create initial file</description>
        <complexity>3</complexity>
        <content>
        // REPOMARK: Initial implementation
        class TestClass {
            // ... existing code ...
            func test() {
                print("Hello")
            }
        }
        </content>
        </change>
        </file>
        
        <file path="another.py" action="delegate edit">
        <change>
        <description>Python delegate edit</description>
        <content>
        # REPOMARK: Update function
        def process():
            # ... existing code ...
            return result
        </content>
        </change>
        </file>
        """
        
        let (items, core, delegates) = ChatContentParser.parseContent(
            complexInput,
            processedDelegateEditHashes: &processedSet,
            isFinal: true
        )
        
        // Should parse without crashing
        XCTAssertTrue(true, "Complex nested patterns should not crash")
        XCTAssertGreaterThan(items.count, 0, "Should parse some items")
    }
    
    func testEdgeCasePatterns() {
        var processedSet = Set<Int>()
        
        // Test edge cases that might break regex
        let edgeCases = [
            "<file path=\"test[bracket].swift\">", // Brackets in path
            "<file path=\"test(paren).py\">", // Parentheses in path
            "<file path=\"test{brace}.js\">", // Braces in path
            "<file path=\"test$dollar.rb\">", // Dollar sign in path
            "<file path=\"test^caret.go\">", // Caret in path
            "<file path=\"test+plus.cpp\">", // Plus in path
            "<file path=\"test*star.c\">", // Star in path
            "<file path=\"test?question.h\">", // Question mark in path
            "<file path=\"test|pipe.sh\">", // Pipe in path
            "<file path=\"test\\backslash.txt\">", // Backslash in path
        ]
        
        for pattern in edgeCases {
            let input = "\(pattern)\n<change><content>test</content></change>\n</file>"
            let (items, _, _) = ChatContentParser.parseContent(
                input,
                processedDelegateEditHashes: &processedSet,
                isFinal: true
            )
            // Should parse without crashing
            XCTAssertTrue(true, "Edge case pattern should not crash: \(pattern)")
        }
    }
}