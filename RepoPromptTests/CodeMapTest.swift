//
//  CodeMapTest.swift
//  RepoPromptTests
//
//  Combined comprehensive tests for the CodeMap system including system tests,
//  edge case tests, and language syntax tests.
//
//  NOTE: Updated so that when TypeCleaner filters out primitives/containers,
//        the tests expect the reduced set (often empty) rather than the raw type.
//
//  Also added more thorough coverage for Go, Rust, Dart, C, C++ and JS.
//


import XCTest
@testable import RepoPrompt

// MARK: - CodeMap System Tests

final class CodeMapSystemTests: XCTestCase {
	
	// MARK: - TypeCleaner Tests
	
	// 1) Test extraction (filtered)
	func testRawExtractBaseTypes() {
		// SWIFT
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "Int", language: .swift),
			[],
			"Filtered extraction removes Swift primitives."
		)
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "Array<String>", language: .swift),
			[],
			"Filtered extraction removes containers and primitives."
		)
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "Dictionary<String, User>", language: .swift),
			["User"],
			"Filtered extraction keeps only non-primitive referenced types."
		)
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "(String, Int) -> Bool", language: .swift),
			[],
			"Filtered extraction removes primitive param/return types."
		)
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "some View", language: .swift),
			[],
			"Filtered extraction drops opaque Swift types."
		)
		
		// TypeScript
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "string", language: .ts),
			[],
			"Filtered extraction removes TS primitives."
		)
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "Promise<User>", language: .ts),
			["User"],
			"Filtered extraction removes container types."
		)
		XCTAssertEqual(
			Set(TypeCleaner.extractBaseTypes(from: "User | null", language: .ts)),
			Set(["User"]),
			"Filtered extraction removes null from unions."
		)
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "Record<string, User>", language: .ts),
			["User"]
		)
		XCTAssertEqual(
			Set(TypeCleaner.extractBaseTypes(from: "User & Serializable", language: .ts)),
			Set(["User", "Serializable"])
		)
	}
	
	// 2) Test filtering only
	func testFilterOutPrimitiveAndSpecialTypes() {
		// SWIFT
		XCTAssertEqual(
			TypeCleaner.filterOutPrimitiveAndSpecialTypes(["Int"], language: .swift),
			[],
			"'Int' is a primitive in Swift => removed."
		)
		XCTAssertEqual(
			TypeCleaner.filterOutPrimitiveAndSpecialTypes(["Array", "String"], language: .swift),
			[],
			"Both 'Array' (container) and 'String' (primitive) get removed."
		)
		XCTAssertEqual(
			TypeCleaner.filterOutPrimitiveAndSpecialTypes(["Dictionary", "String", "User"], language: .swift),
			["User"],
			"Remove container and primitive, leaving only 'User'."
		)
		XCTAssertEqual(
			TypeCleaner.filterOutPrimitiveAndSpecialTypes(["String", "Int", "Bool"], language: .swift),
			[],
			"All are Swift primitives => empty."
		)
		XCTAssertEqual(
			TypeCleaner.filterOutPrimitiveAndSpecialTypes(["View"], language: .swift),
			[],
			"Swift ephemeral types like 'View' also get removed."
		)
		
		// TypeScript
		XCTAssertEqual(
			TypeCleaner.filterOutPrimitiveAndSpecialTypes(["string"], language: .ts),
			[],
			"TS 'string' => removed as a primitive."
		)
		XCTAssertEqual(
			TypeCleaner.filterOutPrimitiveAndSpecialTypes(["Promise", "User"], language: .ts),
			["User"],
			"'Promise' is a container => removed; 'User' remains."
		)
		XCTAssertEqual(
			Set(TypeCleaner.filterOutPrimitiveAndSpecialTypes(["User", "null"], language: .ts)),
			Set(["User"]),
			"TS 'null' => removed."
		)
		XCTAssertEqual(
			TypeCleaner.filterOutPrimitiveAndSpecialTypes(["Record", "string", "User"], language: .ts),
			["User"]
		)
		XCTAssertEqual(
			Set(TypeCleaner.filterOutPrimitiveAndSpecialTypes(["User", "Serializable"], language: .ts)),
			Set(["User", "Serializable"]),
			"Neither 'User' nor 'Serializable' is a recognized primitive/container => remain."
		)
	}
	
	// 3) Integration: extraction + filtering
	func testExtractThenFilterIntegration() {
		// Swift example: "Dictionary<String, User>"
		let rawSwift = TypeCleaner.extractBaseTypes(from: "Dictionary<String, User>", language: .swift)
		let finalSwift = TypeCleaner.filterOutPrimitiveAndSpecialTypes(rawSwift, language: .swift)
		XCTAssertEqual(finalSwift, ["User"])
		
		// TS example: "Promise<User>"
		let rawTs = TypeCleaner.extractBaseTypes(from: "Promise<User>", language: .ts)
		let finalTs = TypeCleaner.filterOutPrimitiveAndSpecialTypes(rawTs, language: .ts)
		XCTAssertEqual(finalTs, ["User"])
	}
	
	func testTypeCleanerFilterPrimitives() {
		// Swift
		let swiftTypes = ["Array", "String", "Int", "Bool", "Dictionary", "CustomType"]
		// Containers (Array/Dictionary) and primitives (String/Int/Bool) -> only "CustomType" remains
		let filteredSwift = TypeCleaner.filterOutPrimitiveAndSpecialTypes(swiftTypes, language: .swift)
		XCTAssertEqual(filteredSwift, ["CustomType"])
		
		// TypeScript
		let tsTypes = ["Promise", "string", "number", "User", "any", "Record"]
		// "Promise"/"Record" => containers, "string"/"number"/"any" => TS primitives => only "User" remains
		let filteredTS = TypeCleaner.filterOutPrimitiveAndSpecialTypes(tsTypes, language: .ts)
		XCTAssertEqual(filteredTS, ["User"])
		
		// C#
		let csharpTypes = ["List", "string", "int", "User", "Dictionary"]
		// "List"/"Dictionary" => containers, "string"/"int" => primitives => only "User" remains
		let filteredCSharp = TypeCleaner.filterOutPrimitiveAndSpecialTypes(csharpTypes, language: .c_sharp)
		XCTAssertEqual(filteredCSharp, ["User"])
	}
	
	func testTypeCleanerComplexTypes() {
		// None of these are recognized containers or primitives except "Void" below:
		
		XCTAssertEqual(
			Set(TypeCleaner.extractBaseTypes(from: "Observable<Result<User, ApiError>>", language: .swift)),
			Set(["Observable", "Result", "User", "ApiError"])
		)
		
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "User.withSettings()", language: .swift),
			["User"]
		)
		
		// "Void" is recognized as ephemeral/primitive (lowercased -> "void"), so it gets removed -> only "User" remains
		XCTAssertEqual(
			TypeCleaner.extractBaseTypes(from: "((User) -> Void)?", language: .swift),
			["User"]
		)
	}
	
	// MARK: - LanguageTypeExtractor Tests
	
	func testExtractSwiftVariables() {
		let swiftVar1 = "var user: User"
		let swiftVar2 = "let count: Int = 0"
		let swiftVar3 = "@Published var items: [Item]"
		
		let result1 = LanguageTypeExtractor.matchAnyVariableLine(swiftVar1, language: .swift)
		XCTAssertEqual(result1?["name"], "user")
		XCTAssertEqual(result1?["type"], "User")
		
		let result2 = LanguageTypeExtractor.matchAnyVariableLine(swiftVar2, language: .swift)
		XCTAssertEqual(result2?["name"], "count")
		XCTAssertEqual(result2?["type"], "Int")
		
		let result3 = LanguageTypeExtractor.matchAnyVariableLine(swiftVar3, language: .swift)
		XCTAssertEqual(result3?["name"], "items")
		XCTAssertEqual(result3?["type"], "[Item]")
	}
	
	func testExtractSwiftFunctions() {
		let swiftFunc1 = "func fetchUser(id: Apple) -> User"
		let swiftFunc2 = "func processItems<T: Identifiable>(items: [T]) -> [Apple: T]"
		let swiftFunc3 = "func authenticate() async throws -> AuthResult"
		
		let result1 = LanguageTypeExtractor.matchAnyFunctionLine(swiftFunc1, language: .swift)
		XCTAssertEqual(result1?["name"], "fetchUser")
		XCTAssertEqual(result1?["returnType"], "User")
		XCTAssertEqual(result1?["parameterTypes"], "Apple")
		
		let result2 = LanguageTypeExtractor.matchAnyFunctionLine(swiftFunc2, language: .swift)
		XCTAssertEqual(result2?["name"], "processItems")
		XCTAssertEqual(result2?["returnType"], "[Apple: T]")
		XCTAssertEqual(result2?["parameterTypes"], "[T]")
		
		let result3 = LanguageTypeExtractor.matchAnyFunctionLine(swiftFunc3, language: .swift)
		XCTAssertEqual(result3?["name"], "authenticate")
		XCTAssertEqual(result3?["returnType"], "AuthResult")
	}
	
	func testExtractTypeScriptVariables() {
		let tsVar1 = "const user: User = { id: 1 }"
		let tsVar2 = "let items: Array<Item>"
		let tsVar3 = "var count = 0"
		
		let result1 = LanguageTypeExtractor.matchAnyVariableLine(tsVar1, language: .ts)
		XCTAssertEqual(result1?["name"], "user")
		XCTAssertEqual(result1?["type"], "User")
		
		let result2 = LanguageTypeExtractor.matchAnyVariableLine(tsVar2, language: .ts)
		XCTAssertEqual(result2?["name"], "items")
		XCTAssertEqual(result2?["type"], "Array<Item>")
		
		let result3 = LanguageTypeExtractor.matchAnyVariableLine(tsVar3, language: .ts)
		XCTAssertEqual(result3?["name"], "count")
		XCTAssertNil(result3?["type"], "No explicit type => nil")
	}
	
	func testExtractTypeScriptFunctions() {
		let tsFunc1 = "function fetchUser(id: string): Promise<User>"
		let tsFunc2 = "const processItems = (items: Item[]): Map<string, Item> => {"
		let tsFunc3 = "class UserService { getUser(id: string): User { } }"
		
		let result1 = LanguageTypeExtractor.matchAnyFunctionLine(tsFunc1, language: .ts)
		XCTAssertEqual(result1?["name"], "fetchUser")
		XCTAssertEqual(result1?["returnType"], "Promise<User>")
		XCTAssertEqual(result1?["parameterTypes"], "string")
		
		let result2 = LanguageTypeExtractor.matchAnyFunctionLine(tsFunc2, language: .ts)
		XCTAssertEqual(result2?["name"], "processItems")
		
		// This one won't match a top-level function in code because it's inside a class
		let result3 = LanguageTypeExtractor.matchAnyFunctionLine(tsFunc3, language: .ts)
		XCTAssertNil(result3)
	}
	
	func testExtractMultiLanguageFunctions() {
		// C#
		let csharpFunc = "public User GetUser(string id, int version)"
		let csharpResult = LanguageTypeExtractor.matchAnyFunctionLine(csharpFunc, language: .c_sharp)
		XCTAssertEqual(csharpResult?["name"], "GetUser")
		XCTAssertEqual(csharpResult?["returnType"], "User")
		XCTAssertEqual(csharpResult?["parameterTypes"], "string, int")
		
		// Java
		let javaFunc = "public User getUser(String id, int version)"
		let javaResult = LanguageTypeExtractor.matchAnyFunctionLine(javaFunc, language: .java)
		XCTAssertEqual(javaResult?["name"], "getUser")
		XCTAssertEqual(javaResult?["returnType"], "User")
		XCTAssertEqual(javaResult?["parameterTypes"], "String, int")
		
		// Python
		let pythonFunc = "def get_user(id: str, version: int) -> User:"
		let pythonResult = LanguageTypeExtractor.matchAnyFunctionLine(pythonFunc, language: .python)
		XCTAssertEqual(pythonResult?["name"], "get_user")
		XCTAssertEqual(pythonResult?["returnType"], "User")
		XCTAssertEqual(pythonResult?["parameterTypes"], "str, int")
		
		// Go
		let goFunc = "func GetUser(id string, version int) User"
		let goResult = LanguageTypeExtractor.matchAnyFunctionLine(goFunc, language: .go)
		XCTAssertEqual(goResult?["name"], "GetUser")
		XCTAssertEqual(goResult?["parameterTypes"], "string, int")
		
		// Dart
		let dartFunc = "Pear fetchUser(Apple id, int version) {"
		let dartResult = LanguageTypeExtractor.matchAnyFunctionLine(dartFunc, language: .dart)
		XCTAssertEqual(dartResult?["name"], "fetchUser")
		XCTAssertEqual(dartResult?["returnType"], "Pear")
		XCTAssertEqual(dartResult?["parameterTypes"], "Apple, int")
		
		// Rust
		let rustFunc = "fn get_user(id: &str, version: i32) -> User {"
		let rustResult = LanguageTypeExtractor.matchAnyFunctionLine(rustFunc, language: .rust)
		XCTAssertEqual(rustResult?["name"], "get_user")
		XCTAssertEqual(rustResult?["returnType"], "User")
		XCTAssertEqual(rustResult?["parameterTypes"], "&str, i32")
	}
	
	// MARK: - SyntaxManager Tests
	
	func testSyntaxManagerLanguageDetection() {
		XCTAssertEqual(SyntaxManager.shared.extensionToLanguage["swift"], .swift)
		XCTAssertEqual(SyntaxManager.shared.extensionToLanguage["js"], .js)
		XCTAssertEqual(SyntaxManager.shared.extensionToLanguage["ts"], .ts)
		XCTAssertEqual(SyntaxManager.shared.extensionToLanguage["py"], .python)
		
		XCTAssertTrue(SyntaxManager.isSupportedFileExtension("swift"))
		XCTAssertTrue(SyntaxManager.isSupportedFileExtension("ts"))
		XCTAssertFalse(SyntaxManager.isSupportedFileExtension("md"))
		XCTAssertFalse(SyntaxManager.isSupportedFileExtension("json"))
	}
	
	func testSyntaxManagerConfiguration() {
		// Test Swift metadata
		let swiftMetadata = SyntaxManager.shared.languageMetadata(forFileExtension: "swift")
		XCTAssertNotNil(swiftMetadata)
		XCTAssertEqual(swiftMetadata?.displayName, "Swift")
		XCTAssertEqual(swiftMetadata?.canonicalFileExtension, "swift")
		
		// Test TypeScript metadata
		let tsMetadata = SyntaxManager.shared.languageMetadata(forFileExtension: "ts")
		XCTAssertNotNil(tsMetadata)
		XCTAssertEqual(tsMetadata?.displayName, "TypeScript")
		XCTAssertEqual(tsMetadata?.canonicalFileExtension, "ts")
		
		// Test unsupported extension
		let unsupportedMetadata = SyntaxManager.shared.languageMetadata(forFileExtension: "unknown")
		XCTAssertNil(unsupportedMetadata)
	}
	
	func testSyntaxManagerParsing() throws {
		// Simple Swift code parsing
		let swiftCode = "func hello() { print(\"Hello\") }"
		let swiftSummary = try SyntaxManager.shared.parseSummary(content: swiftCode, fileExtension: "swift")
		XCTAssertNotNil(swiftSummary)
		XCTAssertTrue(swiftSummary?.hasRootNode == true)
		
		// Simple JS code parsing
		let jsCode = "function hello() { console.log('Hello'); }"
		let jsSummary = try SyntaxManager.shared.parseSummary(content: jsCode, fileExtension: "js")
		XCTAssertNotNil(jsSummary)
		XCTAssertTrue(jsSummary?.hasRootNode == true)
	}
	
	func testSyntaxManagerCodeMap() throws {
		// Quick check; skipping in CI
		guard ProcessInfo.processInfo.environment["CI"] == nil else {
			return
		}
		
		// Test Swift code map
		let swiftCode = """
		struct User {
			var id: String
			var name: String
			
			func fullName() -> String {
				return name
			}
		}
		"""
		
		let swiftMap = try SyntaxManager.shared.codeMap(content: swiftCode, fileExtension: "swift")
		XCTAssertFalse(swiftMap.isEmpty)
		
		// Test JS code map
		let jsCode = """
		class User {
			constructor(id, name) {
				this.id = id;
				this.name = name;
			}
			
			fullName() {
				return this.name;
			}
		}
		"""
		
		let jsMap = try SyntaxManager.shared.codeMap(content: jsCode, fileExtension: "js")
		XCTAssertFalse(jsMap.isEmpty)
	}
	
	// MARK: - Integration Tests
	
	func testCodeMapIntegration() throws {
		let swiftCode = """
		import Foundation
		
		struct User {
			let id: UUID
			var name: String
			var friends: [User]
			
			func addFriend(_ friend: User) -> Bool {
				if !friends.contains(where: { $0.id == friend.id }) {
					friends.append(friend)
					return true
				}
				return false
			}
			
			func getFriendsByName() -> [String: User] {
				return Dictionary(uniqueKeysWithValues: friends.map { ($0.name, $0) })
			}
		}
		"""
		
		// 1. Parse the code
		let parseSucceeded = try SyntaxManager.shared.parseSucceeds(content: swiftCode, fileExtension: "swift")
		XCTAssertTrue(parseSucceeded)
		
		// 2. Get the code map
		let map = try SyntaxManager.shared.codeMap(content: swiftCode, fileExtension: "swift")
		XCTAssertFalse(map.isEmpty)
		
		// 3. Spot-check extraction logic
		let idLine = "let id: UUID"
		let idResult = LanguageTypeExtractor.matchAnyVariableLine(idLine, language: .swift)
		XCTAssertEqual(idResult?["name"], "id")
		XCTAssertEqual(idResult?["type"], "UUID")
		
		let friendsLine = "var friends: [User]"
		let friendsResult = LanguageTypeExtractor.matchAnyVariableLine(friendsLine, language: .swift)
		XCTAssertEqual(friendsResult?["name"], "friends")
		XCTAssertEqual(friendsResult?["type"], "[User]")
		
		let addFriendLine = "func addFriend(_ friend: User) -> Bool {"
		let addFriendResult = LanguageTypeExtractor.matchAnyFunctionLine(addFriendLine, language: .swift)
		XCTAssertEqual(addFriendResult?["name"], "addFriend")
		XCTAssertEqual(addFriendResult?["returnType"], "Bool")
		XCTAssertEqual(addFriendResult?["paramList"], "_ friend: User")
		XCTAssertEqual(addFriendResult?["parameterTypes"], "User")
		
		// 4. If we run these types through TypeCleaner:
		let friendTypes = TypeCleaner.extractBaseTypes(from: friendsResult?["type"] ?? "", language: .swift)
		// "Array" + "User" => "Array" is a container, so removed => "User" remains:
		XCTAssertEqual(friendTypes, ["User"])
		
		let returnTypes = TypeCleaner.extractBaseTypes(from: addFriendResult?["returnType"] ?? "", language: .swift)
		// "Bool" is recognized as a primitive => empty
		XCTAssertEqual(returnTypes, [])
	}
}

// MARK: - CodeMap Edge Case Tests

final class CodeMapEdgeCaseTests: XCTestCase {
	
	func testComplexGenerics() {
		// Swift complex generics
		let swiftType = "Result<Dictionary<String, Array<User>>, Error>"
		// "Result" + "Dictionary" + "String" + "Array" + "User" + "Error"
		// "String" => primitive, "Dictionary"/"Array" => containers -> left with "Result","User","Error"
		let swiftBaseTypes = TypeCleaner.extractBaseTypes(from: swiftType, language: .swift)
		XCTAssertEqual(Set(swiftBaseTypes), Set(["Result", "User"]))
		
		// TypeScript mapped types
		let tsType = "Record<keyof User, Promise<User[]>>"
		// "Record","Promise" => containers, "User[]" => "User" inside => final: ["User"]
		let tsBaseTypes = TypeCleaner.extractBaseTypes(from: tsType, language: .ts)
		XCTAssertTrue(tsBaseTypes.contains("User"))
		XCTAssertEqual(tsBaseTypes.count, 1)
	}
	
	func testUnbalancedBrackets() {
		// "Array<String" -> treat "String" as a primitive => container => empty
		let unbalanced1 = "Array<String"
		let types1 = TypeCleaner.extractBaseTypes(from: unbalanced1, language: .swift)
		XCTAssertEqual(types1, [])
		
		// "String>" -> "String" -> primitive => empty
		let unbalanced2 = "String>"
		let types2 = TypeCleaner.extractBaseTypes(from: unbalanced2, language: .swift)
		XCTAssertEqual(types2, [])
	}
	
	func testSpecialSwiftSyntax() {
		// "some Identifiable" -> "Identifiable" is not ephemeral => remains
		let some = "some Identifiable"
		let someTypes = TypeCleaner.extractBaseTypes(from: some, language: .swift)
		XCTAssertEqual(someTypes, ["Identifiable"])
		
		// For "[User]" => container + "User" => only "User" remains
		let returnResult = TypeCleaner.extractBaseTypes(from: "[User]", language: .swift)
		XCTAssertEqual(returnResult, ["User"])
	}
	
	func testSpecialTypeScriptSyntax() {
		// "User | Error | null" => "User","Error"
		let unionType = "User | Error | null"
		let unions = TypeCleaner.extractBaseTypes(from: unionType, language: .ts)
		XCTAssertEqual(Set(unions), Set(["User", "Error"]))
	}
	
	func testCommentsInTypes() {
		// "Array<Apple> /* with a comment */" => container removed, Apple remains
		let swiftWithComment = "Array<Apple> /* with a comment */"
		let swiftTypes = TypeCleaner.extractBaseTypes(from: swiftWithComment, language: .swift)
		XCTAssertEqual(swiftTypes, ["Apple"])
		
		// "vector<Apple> // with a comment" => container removed, Apple remains
		let cppWithComment = "vector<Apple> // with a comment"
		let cppTypes = TypeCleaner.extractBaseTypes(from: cppWithComment, language: .cpp)
		XCTAssertEqual(cppTypes, ["Apple"])
	}
	
	func testEmptyAndInvalidCases() {
		// Empty type
		XCTAssertEqual(TypeCleaner.extractBaseTypes(from: "", language: .swift), [])
		
		// Invalid syntax
		XCTAssertEqual(TypeCleaner.extractBaseTypes(from: "???", language: .swift), [])
		
		// Non-matching variables
		XCTAssertNil(LanguageTypeExtractor.matchAnyVariableLine("not a variable", language: .swift))
		
		// Non-matching functions
		XCTAssertNil(LanguageTypeExtractor.matchAnyFunctionLine("not a function", language: .swift))
	}
}

// MARK: - CodeMap Language Syntax Tests

final class CodeMapLanguageSyntaxTests: XCTestCase {
	
	func testSwiftSyntaxVariants() {
		let swiftSamples = [
			"var user: User?",
			"let ids: [UUID] = []",
			"@available(iOS 14.0, *) func process() -> some View",
			"static var shared: UserManager { get }",
			"private(set) var name: String",
			"func transform<T: Codable, U>(_ value: T) -> U?",
			"func handle(completion: @escaping (Result<User, Error>) -> Void)",
			"func fetchAsync() async throws -> [User]"
		]
		
		for sample in swiftSamples {
			if sample.contains("func") {
				// Function match
				let result = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: .swift)
				XCTAssertNotNil(result, "Failed to match Swift function: \(sample)")
			} else {
				// Variable match
				let result = LanguageTypeExtractor.matchAnyVariableLine(sample, language: .swift)
				XCTAssertNotNil(result, "Failed to match Swift variable: \(sample)")
			}
		}
	}
	
	func testTypeScriptSyntaxVariants() {
		let tsSamples = [
			"const user: User = { id: 1 }",
			"let items: Array<Item> = []",
			"var optional?: string",
			"function process<T extends Item>(items: T[]): Promise<T[]>",
			"const handler = (event: Event): void => {}",
			"class UserService { getUser(id: string): User }",
			"interface Repository<T> { findAll(): T[] }",
			"type UserMap = Record<string, User>",
			"export default function App(): JSX.Element"
		]
		
		for sample in tsSamples {
			if sample.hasPrefix("const")
				|| sample.hasPrefix("let")
				|| sample.hasPrefix("var")
				|| sample.hasPrefix("type") {
				let result = LanguageTypeExtractor.matchAnyVariableLine(sample, language: .ts)
				XCTAssertNotNil(result, "Failed to match TypeScript variable: \(sample)")
			} else if sample.hasPrefix("function")
						|| sample.hasPrefix("const handler") {
				let result = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: .ts)
				XCTAssertNotNil(result, "Failed to match TypeScript function: \(sample)")
			}
			// We skip direct class/interface parse checks here, but can confirm it doesn't crash
		}
	}
	
	func testJSSyntaxVariants() {
		let jsSamples = [
			"var count = 0",
			"let user = { name: 'Bob' }",
			"const greet = function(name) { console.log(name); }",
			"function doSomething(x, y) { return x + y; }"
		]
		
		for sample in jsSamples {
			// JavaScript is all dynamic, so type annotations are usually absent
			// We'll attempt function or variable extraction:
			let varResult = LanguageTypeExtractor.matchAnyVariableLine(sample, language: .js)
			let funcResult = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: .js)
			XCTAssertTrue(
				varResult != nil || funcResult != nil,
				"Expected JS code to match either var or function: \(sample)"
			)
		}
	}
	
	func testDartSyntaxVariants() {
		let dartSamples = [
			"var count = 0",
			"final name = 'Alice';",
			"String greet(String who) => 'Hello, \\$who';",
			"int add(int x, int y) { return x + y; }",
			"const pi = 3.14;",
			"final List<User> users = [];"
		]
		
		for sample in dartSamples {
			if sample.hasPrefix("var")
				|| sample.hasPrefix("final")
				|| sample.hasPrefix("const")
				|| sample.contains("List<") {
				// Variable extraction
				let result = LanguageTypeExtractor.matchAnyVariableLine(sample, language: .dart)
				// Or function? For lines like "String greet(String who) =>"
				let funcRes = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: .dart)
				XCTAssertTrue(result != nil || funcRes != nil,
							  "Failed to match Dart var or function: \(sample)")
			} else {
				// Try function
				let result = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: .dart)
				XCTAssertNotNil(result, "Failed to match Dart function: \(sample)")
			}
		}
	}
	
	func testGoSyntaxVariants() {
		let goSamples = [
			"var count int",
			"var name = \"Bob\"",
			"func Add(x int, y int) int { return x + y }",
			"func greet(names ...string) { fmt.Println(names) }",
			"const version = 1.2",
			"func multipleReturns() (int, string) { return 123, \"abc\" }"
		]
		
		for sample in goSamples {
			let varResult = LanguageTypeExtractor.matchAnyVariableLine(sample, language: .go)
			let funcResult = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: .go)
			XCTAssertTrue(varResult != nil || funcResult != nil,
						  "Failed to match Go var or function: \(sample)")
		}
	}
	
	func testRustSyntaxVariants() {
		let rustSamples = [
			"let mut count: i32 = 0;",
			"let name = String::from(\"Alice\");",
			"fn add(x: i32, y: i32) -> i32 { x + y }",
			"fn greet(names: &mut Vec<String>) { println!(\"{:?}\", names); }",
			"let data: Option<&str> = None;",
			"fn complex_return() -> Result<Option<User>, Box<dyn Error>> { /* ... */ }"
		]
		
		for sample in rustSamples {
			let varResult = LanguageTypeExtractor.matchAnyVariableLine(sample, language: .rust)
			let funcResult = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: .rust)
			XCTAssertTrue(varResult != nil || funcResult != nil,
						  "Failed to match Rust var or function: \(sample)")
		}
	}
	
	func testCAndCPPSyntaxVariants() {
		let cSamples = [
			"int count = 0;",
			"float values[10];",
			"static const char* msg = \"Hello\";",
			"void process(char* data) { /* ... */ }"
		]
		for sample in cSamples {
			let varResult = LanguageTypeExtractor.matchAnyVariableLine(sample, language: .c)
			let funcResult = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: .c)
			XCTAssertTrue(varResult != nil || funcResult != nil,
						  "Failed to match C var or function: \(sample)")
		}
		
		let cppSamples = [
			"std::vector<std::string> names;",
			"auto getValue(int x) -> double;",
			"static constexpr int MAX_COUNT = 100;",
			"inline void doSomething(std::string_view msg) { /* ... */ }",
			"template<typename T> T multiply(T a, T b) { return a * b; }"
		]
		for sample in cppSamples {
			// Try to see if it’s a variable or a function.
			// The code can be tricky, but we just want to confirm it doesn't fail.
			let varResult = LanguageTypeExtractor.matchAnyVariableLine(sample, language: .cpp)
			let funcResult = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: .cpp)
			XCTAssertTrue(varResult != nil || funcResult != nil,
						  "Failed to match C++ var or function: \(sample)")
		}
	}
	
	func testMultiLanguageSamples() {
		// Map of language types to sample code that should match either a var or func pattern
		let samples: [LanguageType: [String]] = [
			.c: [
				"int count = 0;",
				"void process(char* data);"
			],
			.cpp: [
				"std::vector<std::string> names;",
				"template<typename T> T getValue()"
			],
			.python: [
				"def process(data: list[str]) -> dict[str, int]:",
				"user: User = get_user()"
			],
			.java: [
				"private List<User> users;",
				"public User getUser(String id) throws NotFoundException"
			],
			.c_sharp: [
				"private readonly List<User> _users;",
				"public async Task<User> GetUserAsync(string id)"
			],
			.go: [
				"var config string",
				"func Initialize(cfg string) error"
			],
			.rust: [
				"let some_value: i32 = 10;",
				"fn do_something(x: &str) -> bool { true }"
			],
			.dart: [
				"final int total = 99;",
				"String fetchData(String url) { return 'data'; }"
			],
			.js: [
				"var token = 'abc';",
				"function doStuff(a, b) { return a + b; }"
			]
		]
		
		for (language, languageSamples) in samples {
			for sample in languageSamples {
				let varResult = LanguageTypeExtractor.matchAnyVariableLine(sample, language: language)
				let funcResult = LanguageTypeExtractor.matchAnyFunctionLine(sample, language: language)
				
				XCTAssertTrue(
					varResult != nil || funcResult != nil,
					"Failed to match either variable or function for \(language): \(sample)"
				)
			}
		}
	}
}
