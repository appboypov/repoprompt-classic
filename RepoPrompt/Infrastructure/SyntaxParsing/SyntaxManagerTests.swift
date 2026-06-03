//
//  SyntaxManager+Tests.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-05.
//  Extension for testing and debugging purposes.
//

#if DEBUG

import Foundation

extension SyntaxManager {
	
	/// Debug helper that prints the parse tree for the given content and `LanguageType`.
	func debugPrintTree(for content: String, languageType: LanguageType) {
		debugPrintTree(for: content, fileExtension: languageType.canonicalFileExtension)
	}
	
	// MARK: - Grammar & Query Tests
	
	/// Runs a simple parse test for each embedded grammar through SyntaxManager's safe gateway.
	func testGrammars() {
		let tests: [(language: LanguageType, sampleCode: String)] = [
			(.js, "function foo() { return 42; }"),
			(.swift, "let x = 10"),
			(.c_sharp, "class Test { static void Main() { } }"),
			(.python, "def foo():\n    return 42"),
			(.c, "int main() { return 0; }"),
			(.rust, "fn main() { println!(\"Hello, world!\"); }"),
			(.cpp, "int main() { return 0; }"),
			(.go, "package main\nfunc main() { println(\"Hello, world!\") }"),
			(.java, "public class Test { public static void main(String[] args) { System.out.println(\"Hello, world!\"); } }"),
			(.dart, "void main() { print('Hello, world!'); }"),
			(.php, "<?php\nfunction greet() { echo \"Hello, world!\"; }\n?>"),
			(.ruby, "class Greeter\n  def say_hello\n    puts 'Hello, world!'\n  end\nend")
		]
		
		for test in tests {
			let ext = test.language.canonicalFileExtension
			do {
				let description = try debugTreeDescription(
					content: test.sampleCode,
					fileExtension: ext,
					originName: "testGrammars.\(test.language.rawValue)"
				)
				if let description, !description.isEmpty {
					print("Test passed for \(test.language.displayName): \(description)")
				} else {
					print("Test failed for \(test.language.displayName): Parsing returned nil.")
				}
			} catch {
				print("Test failed for \(test.language.displayName) with error: \(error)")
			}
		}
	}
	
	/// Debug helper that prints the parse tree for the given content and file extension.
	func debugPrintTree(for content: String, fileExtension: String) {
		do {
			guard let description = try debugTreeDescription(
				content: content,
				fileExtension: fileExtension,
				originName: "debugPrintTree"
			) else {
				print("No parse tree produced for \(fileExtension).")
				return
			}
			print("Parse tree for \(fileExtension):")
			print(description)
			print("Node outline for \(fileExtension):")
			print(try debugNodeOutline(
				content: content,
				fileExtension: fileExtension,
				originName: "debugPrintTree.outline"
			))
		} catch {
			print("Error parsing content for \(fileExtension): \(error)")
		}
	}
	
	/// Debug helper that attempts to create a Query for a given language type,
	/// printing detailed error information if query creation fails.
	func debugQueryCreation(for languageType: LanguageType) {
		guard let queryText = optimizedQueries[languageType] else {
			print("No query text found for \(languageType.rawValue).")
			return
		}
		
		do {
			try debugCompileQuery(
				queryText: queryText,
				fileExtension: languageType.canonicalFileExtension,
				originName: "debugQueryCreation.\(languageType.rawValue)"
			)
			print("Query for \(languageType.rawValue) created successfully.")
		} catch {
			print("Error creating query for \(languageType.rawValue): \(error)")
		}
	}
	
	/// Debug helper to test the Swift regex literal specifically.
	func debugSwiftRegexLiteral() {
		let minimalSwiftCode = "let regex = /abc/"
		let simplifiedQuery = "(regex_literal) @string.regex"
		do {
			print("=== Parse Tree (s-expression) for Swift regex test ===")
			print(try debugTreeDescription(
				content: minimalSwiftCode,
				fileExtension: "swift",
				originName: "debugSwiftRegexLiteral.tree"
			) ?? "<no s-expression>")
			let result = try debugRunQuery(
				queryText: simplifiedQuery,
				fileExtension: "swift",
				content: minimalSwiftCode,
				originName: "debugSwiftRegexLiteral.query"
			)
			printDebugQueryResult(result, emptyMessage: "No highlights found using the simplified regex query.")
		} catch {
			print("Error during Swift regex debug: \(error)")
		}
	}
	
	/// Debug helper that tests each individual query line in `swiftQuery`.
	func debugTestSwiftQueryLines() {
		let sampleSwiftCode = "func greet() { print(\"Hello, world!\") }"
		let queryLines = swiftQuery.components(separatedBy: .newlines)
		
		for (index, line) in queryLines.enumerated() {
			let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmedLine.isEmpty { continue }
			
			do {
				let result = try debugRunQuery(
					queryText: trimmedLine,
					fileExtension: "swift",
					content: sampleSwiftCode,
					originName: "debugTestSwiftQueryLines.line\(index + 1)"
				)
				print("Line \(index + 1) succeeded with \(result.captures.count) captures. Query: \(trimmedLine)")
			} catch {
				print("Line \(index + 1) FAILED. Query: \(trimmedLine)\nError: \(error)")
			}
		}
	}
	
	/// Runs a test of the highlight queries for each supported language.
	func testHighlightQueries() {
		let testSamples = debugCodeSamples()
		
		for sample in testSamples {
			print("Testing highlight query for \(sample.language.rawValue):")
			do {
				let tokens = try highlight(
					content: sample.code,
					fileExtension: sample.fileExtension,
					origin: .debugHelper(name: "testHighlightQueries.\(sample.language.rawValue)")
				)
				if tokens.isEmpty {
					print("  No highlights found for \(sample.language.rawValue).")
					debugPrintTree(for: sample.code, fileExtension: sample.fileExtension)
				} else {
					for token in tokens {
						print("  \(token)")
					}
				}
			} catch {
				print("  Error during highlighting \(sample.language.rawValue): \(error)")
				debugQueryCreation(for: sample.language)
			}
		}
	}
	
	/// Debug helper that tests code-map queries granularly for each supported language.
	func debugGranularCodeMapQueries() {
		for sample in debugCodeSamples() {
			debugGranularCodeMapQuery(
				language: sample.language,
				fileExtension: sample.fileExtension,
				code: sample.code
			)
		}
	}
	
	/// Debug helper that tests the code-map query specifically for Swift.
	func debugGranularSwiftCodeMapQuery() {
		debugGranularCodeMapQuery(
			language: .swift,
			fileExtension: "swift",
			code: """
import Foundation
struct Greeter {
	func sayHello() {
		print("Hello!")
	}
}
"""
		)
	}
	
	// MARK: - Dart

	/// Debug helper that tests the code-map query specifically for Dart.
	func debugGranularDartCodeMapQuery() {
		debugGranularCodeMapQuery(
			language: .dart,
			fileExtension: "dart",
			code: """
class Greeter {
	void sayHello() {
		print("Hello!");
	}
}
"""
		)
	}
	
	/// Debug helper that tests the code-map query specifically for TypeScript.
	func debugGranularTypeScriptQuery() {
		debugGranularCodeMapQuery(
			language: .ts,
			fileExtension: "ts",
			code: """
function greet(): void {
	console.log("Hello, world!");
}
"""
		)
	}

	/// Debug helper that tests the code-map query specifically for JavaScript.
	func debugGranularJavaScriptQuery() {
		debugGranularCodeMapQuery(
			language: .js,
			fileExtension: "js",
			code: """
function greet() {
	console.log("Hello, world!");
}
"""
		)
	}

	/// Debug helper that compiles PHP highlight & code-map queries in
	/// increasingly smaller chunks to isolate the first failing block or line.
	func debugGranularPHPQueries() {
		print("=== Granular PHP Query Debug ===")
		
		let sampleCode = """
<?php
namespace App\\Debug;
class Dummy { public function foo() { return 42; } }
function bar($x) { return $x; }
"""
		
		do {
			let outline = try debugNodeOutline(
				content: sampleCode,
				fileExtension: "php",
				originName: "debugGranularPHPQueries.outline"
			)
			print("\n--- PHP sample tree outline ---")
			print(outline)
			print("--- End PHP sample tree outline ---\n")
		} catch {
			print("Failed to parse sample PHP code for node outline: \(error)")
		}
		
		print("\n--- PHP Highlight Query ---")
		compileOrSplit(
			queryString: phpHighlightQuery,
			fileExtension: "php",
			content: sampleCode,
			label: "PHP highlight query"
		)
		
		print("\n--- PHP Code-Map Query ---")
		guard let codeMapText = codeMapQueries[.php] else {
			print("No PHP code-map query text available.")
			return
		}
		compileOrSplit(
			queryString: codeMapText,
			fileExtension: "php",
			content: sampleCode,
			label: "PHP code-map query"
		)
		
		print("=== End PHP Query Debug ===")
	}
	
	private func debugGranularCodeMapQuery(language: LanguageType, fileExtension: String, code: String) {
		print("=== Granular Code-Map Query Test for \(language.rawValue) ===")
		guard let codeMapQueryText = codeMapQueries[language] else {
			print("No code-map query found for \(language.rawValue)")
			return
		}
		compileOrSplit(
			queryString: codeMapQueryText,
			fileExtension: fileExtension,
			content: code,
			label: "\(language.rawValue) code-map query"
		)
		print("=== End of \(language.rawValue) granular test ===\n")
	}
	
	private func compileOrSplit(queryString: String, fileExtension: String, content: String, label: String) {
		do {
			let result = try debugRunQuery(
				queryText: queryString,
				fileExtension: fileExtension,
				content: content,
				originName: "compileOrSplit.\(label)"
			)
			print("Full \(label) compiled successfully with \(result.captures.count) captures across \(result.matchCount) matches.")
		} catch {
			print("Full \(label) FAILED: \(error)")
			print("Splitting the query into smaller blocks for granular testing...")
			splitAndTest(queryString: queryString, fileExtension: fileExtension, content: content)
		}
	}
	
	/// Splits a query string by blank lines, then by individual lines,
	/// compiling each piece to report successes/failures through SyntaxManager's DEBUG gateway.
	private func splitAndTest(queryString: String, fileExtension: String, content: String) {
		let blocks = queryString
			.components(separatedBy: "\n\n")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		
		for (blockIdx, block) in blocks.enumerated() {
			do {
				let result = try debugRunQuery(
					queryText: block,
					fileExtension: fileExtension,
					content: content,
					originName: "splitAndTest.block\(blockIdx + 1)"
				)
				print("  ✓ Block \(blockIdx + 1) compiled with \(result.captures.count) captures")
				continue
			} catch {
				print("  ✗ Block \(blockIdx + 1) failed: \(error)")
			}
			
			let lines = block
				.split(separator: "\n")
				.map { String($0).trimmingCharacters(in: .whitespaces) }
				.filter { !$0.isEmpty && !$0.hasPrefix(";") }
			
			for (lineIdx, line) in lines.enumerated() {
				do {
					try debugCompileQuery(
						queryText: line,
						fileExtension: fileExtension,
						originName: "splitAndTest.block\(blockIdx + 1).line\(lineIdx + 1)"
					)
					print("      • line \(lineIdx + 1) OK")
				} catch {
					print("      • line \(lineIdx + 1) BAD → \(line)")
					print("        Error: \(error)")
				}
			}
		}
	}
	
	private func printDebugQueryResult(_ result: SyntaxDebugQueryRunResult, emptyMessage: String) {
		guard !result.captures.isEmpty else {
			print(emptyMessage)
			return
		}
		print("=== Debug Query Captures ===")
		for capture in result.captures {
			print("  \(capture.name): \(capture.textPreview)")
		}
	}
	
	private func debugCodeSamples() -> [(language: LanguageType, fileExtension: String, code: String)] {
		[
			(.swift, "swift", """
import Foundation
struct Greeter {
	func sayHello() { print("Hello!") }
}
"""),
			(.js, "js", """
class Greeter {
  sayHello() { console.log("Hello!"); }
}
"""),
			(.c_sharp, "cs", """
namespace HelloApp {
	class Greeter {
		public void SayHello() {
			System.Console.WriteLine("Hello!");
		}
	}
}
"""),
			(.python, "py", """
class Greeter:
	def say_hello(self):
		print("Hello!")
"""),
			(.c, "c", """
void sayHello() {
	printf("Hello!");
}
"""),
			(.rust, "rs", """
struct Greeter;
impl Greeter {
	fn say_hello(&self) {
		println!("Hello!");
	}
}
"""),
			(.cpp, "cpp", """
#include <iostream>
class Greeter {
public:
	void sayHello() { std::cout << "Hello!\\n"; }
};
"""),
			(.go, "go", """
package main
import "fmt"
type Greeter struct {}
func (g Greeter) sayHello() {
	fmt.Println("Hello!")
}
"""),
			(.java, "java", """
public class Greeter {
	public void sayHello() {
		System.out.println("Hello!");
	}
}
"""),
			(.dart, "dart", """
class Greeter {
  void sayHello() {
		print("Hello!");
  }
}
"""),
			(.ts, "ts", """
function greet(): void {
	console.log("Hello!");
}
"""),
			(.tsx, "tsx", """
import React from 'react';

type Props = {
	title: string;
};

const Greeter: React.FC<Props> = ({ title }) => {
	return <div>{title}</div>;
};

export default Greeter;
"""),
			(.php, "php", """
<?php
class Greeter {
	public function sayHello() {
		echo "Hello!";
	}
}
?>
"""),
			(.ruby, "rb", """
class Greeter
  def say_hello
		puts "Hello!"
  end
end
""")
		]
	}
}

#endif
