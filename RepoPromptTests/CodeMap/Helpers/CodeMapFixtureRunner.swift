//
//  CodeMapFixtureRunner.swift
//  RepoPromptTests
//
//  Fixture discovery and execution for codemap testing.
//  Automatically discovers fixtures and runs them through the full pipeline.
//

import Foundation
import XCTest
import SwiftTreeSitter
@testable import RepoPrompt

// MARK: - Fixture Model

/// Represents a discovered codemap test fixture
struct CodeMapFixture {
	/// Relative path from fixtures root (e.g., "ts/smoke.ts")
	let relativePath: String
	/// Absolute path on disk
	let absolutePath: String
	/// File extension (e.g., "ts")
	let fileExtension: String
	/// Source code content
	let content: String
	
	/// Virtual path used in FileAPI (stable across machines)
	var virtualPath: String {
		"fixtures/\(relativePath)"
	}
	
	/// Language type for this fixture
	var languageType: LanguageType? {
		SyntaxManager.shared.extensionToLanguage[fileExtension.lowercased()]
	}
}

// MARK: - Fixture Runner

/// Orchestrates fixture discovery and execution
struct CodeMapFixtureRunner {
	
	/// Set to true to regenerate all golden files, then set back to false
	static let regenerateGoldens: Bool = {
		#if UPDATE_CODEMAP_GOLDENS
		let compileFlag = true
		#else
		let compileFlag = false
		#endif
		if compileFlag {
			return true
		}
		if FileManager.default.fileExists(atPath: "/tmp/repoprompt-update-codemap-goldens") {
			return true
		}
		let env = ProcessInfo.processInfo.environment
		if env["UPDATE_CODEMAP_GOLDENS"] != nil {
			return true
		}
		return CommandLine.arguments.contains("UPDATE_CODEMAP_GOLDENS=1")
			|| CommandLine.arguments.contains("--update-codemap-goldens")
	}()
	
	/// All supported file extensions that have codemap queries
	static let supportedExtensions: Set<String> = [
		"swift", "js", "cs", "py", "c", "rs", "cpp", "go", "java", "dart", "ts", "tsx", "php", "rb"
	]
	
	/// Discover all fixtures under the given root directory
	/// - Parameter fixturesRoot: Root directory to search
	/// - Returns: Array of discovered fixtures
	static func discoverFixtures(fixturesRoot: URL) throws -> [CodeMapFixture] {
		let fileManager = FileManager.default
		
		guard fileManager.fileExists(atPath: fixturesRoot.path) else {
			return []
		}
		
		var fixtures: [CodeMapFixture] = []
		
		let enumerator = fileManager.enumerator(
			at: fixturesRoot,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		)
		
		while let fileURL = enumerator?.nextObject() as? URL {
			let ext = fileURL.pathExtension.lowercased()
			
			// Only include files with supported codemap extensions
			guard supportedExtensions.contains(ext),
				  SyntaxManager.shared.supportsCodeMap(fileExtension: ext) else {
				continue
			}
			
			// Compute relative path
			let absolutePath = fileURL.path
			let relativePath = absolutePath
				.replacingOccurrences(of: fixturesRoot.path + "/", with: "")
			
			// Read content
			let content = try String(contentsOf: fileURL, encoding: .utf8)
			
			fixtures.append(CodeMapFixture(
				relativePath: relativePath,
				absolutePath: absolutePath,
				fileExtension: ext,
				content: content
			))
		}
		
		// Sort for deterministic ordering
		return fixtures.sorted { $0.relativePath < $1.relativePath }
	}
	
	/// Run the codemap pipeline for a single fixture
	/// - Parameters:
	///   - fixture: The fixture to process
	///   - goldensRoot: Root directory for golden files
	///   - updatePolicy: Policy for golden file updates
	/// - Returns: Pipeline result for further validation
	@discardableResult
	static func runFixture(
		_ fixture: CodeMapFixture,
		goldensRoot: URL,
		updatePolicy: GoldenUpdatePolicy = regenerateGoldens ? .always : .never,
		file: StaticString = #filePath,
		line: UInt = #line
	) throws -> PipelineResult {
		// Step 1: Run tree-sitter to get captures
		let captures = try SyntaxManager.shared.codeMap(
			content: fixture.content,
			fileExtension: fixture.fileExtension
		)
		
		// Step 2: Generate FileAPI from captures
		let fileAPI = CodeMapGenerator.generateCodeMap(
			from: captures,
			content: fixture.content,
			fullPath: fixture.virtualPath
		)
		
		let result = PipelineResult(
			fixture: fixture,
			captures: captures,
			fileAPI: fileAPI
		)
		
		// Step 3: Validate FileAPI invariants
		try validateFileAPIInvariants(result, file: file, line: line)
		
		// Step 4: Compare against golden files
		try compareAgainstGoldens(result, goldensRoot: goldensRoot, updatePolicy: updatePolicy, file: file, line: line)
		
		return result
	}
	
	/// Validate structural invariants on the FileAPI
	private static func validateFileAPIInvariants(
		_ result: PipelineResult,
		file: StaticString,
		line: UInt
	) throws {
		guard let api = result.fileAPI else {
			// nil FileAPI is valid for files with no extractable structure
			return
		}
		
		// Imports should be deduplicated
		let uniqueImports = Set(api.imports)
		XCTAssertEqual(uniqueImports.count, api.imports.count,
					   "[\(result.fixture.relativePath)] Imports contain duplicates",
					   file: file, line: line)
		
		// Exports should be deduplicated
		let uniqueExports = Set(api.exports)
		XCTAssertEqual(uniqueExports.count, api.exports.count,
					   "[\(result.fixture.relativePath)] Exports contain duplicates",
					   file: file, line: line)
		
		// No hollow classes (classes with no methods or properties)
		// Note: Generator already filters these, but we validate
		for classInfo in api.classes {
			let hasContent = !classInfo.methods.isEmpty || !classInfo.properties.isEmpty
			XCTAssertTrue(hasContent,
						  "[\(result.fixture.relativePath)] Hollow class: \(classInfo.name)",
						  file: file, line: line)
		}
		
		// No empty referenced types
		for refType in api.referencedTypes {
			let trimmed = refType.trimmingCharacters(in: .whitespacesAndNewlines)
			XCTAssertFalse(trimmed.isEmpty,
						   "[\(result.fixture.relativePath)] Empty referenced type found",
						   file: file, line: line)
		}
		
		if let language = result.fixture.languageType {
			var functionSignatureTypes = Set<String>()
			var propertySignatureTypes = Set<String>()
			let functionList = api.functions
				+ api.classes.flatMap { $0.methods }
				+ api.interfaces.flatMap { $0.methods }
			for fn in functionList {
				if let returnType = fn.returnType {
					for t in TypeCleaner.extractBaseTypes(from: returnType, language: language) {
						functionSignatureTypes.insert(t)
					}
				}
				for param in fn.parameters {
					if let typeName = param.typeName {
						for t in TypeCleaner.extractBaseTypes(from: typeName, language: language) {
							functionSignatureTypes.insert(t)
						}
					}
				}
			}
			
			let propertyList = api.globalVars.map { PropertyInfo(name: $0.name, typeName: $0.typeName) }
				+ api.classes.flatMap { $0.properties }
				+ api.interfaces.flatMap { $0.properties }
			for prop in propertyList {
				if let typeName = prop.typeName {
					for t in TypeCleaner.extractBaseTypes(from: typeName, language: language) {
						propertySignatureTypes.insert(t)
					}
				}
			}
			
			let allSignatureTypes = functionSignatureTypes.union(propertySignatureTypes)
			
			let missing = allSignatureTypes.subtracting(api.referencedTypes)
			if !missing.isEmpty {
				let preview = missing.sorted().prefix(12).joined(separator: ", ")
				XCTFail("[\(result.fixture.relativePath)] Missing referenced types from signatures: \(preview)",
						file: file, line: line)
			}
			
			for refType in api.referencedTypes {
				if TypeCleaner.isPrimitiveType(refType, language: language) {
					XCTFail("[\(result.fixture.relativePath)] Referenced type contains primitive: \(refType)",
							file: file, line: line)
				}
				if TypeCleaner.isContainerType(refType, language: language) {
					XCTFail("[\(result.fixture.relativePath)] Referenced type contains container: \(refType)",
							file: file, line: line)
				}
				if TypeCleaner.isGenericPlaceholderTypeName(refType, language: language) {
					XCTFail("[\(result.fixture.relativePath)] Referenced type contains generic placeholder: \(refType)",
							file: file, line: line)
				}
				if language == .swift, TypeCleaner.isSwiftSpecialTypeName(refType) {
					XCTFail("[\(result.fixture.relativePath)] Referenced type contains Swift special type: \(refType)",
							file: file, line: line)
				}
			}
			
			if language == .swift {
				let functionLines = functionList.map { $0.definitionLine }
				for lineText in functionLines {
					if lineText.contains("{") || lineText.contains("\n") {
						XCTFail("[\(result.fixture.relativePath)] Function definition line is not signature-only: \(lineText)",
								file: file, line: line)
					}
				}
				let propertyLines = propertyList.map { $0.name }
				for lineText in propertyLines {
					if lineText.contains("{") || lineText.contains("\n") {
						XCTFail("[\(result.fixture.relativePath)] Property definition line is not signature-only: \(lineText)",
								file: file, line: line)
					}
				}
			} else if language == .ts || language == .tsx {
				let functionLines = functionList.map { $0.definitionLine }
				for lineText in functionLines {
					if lineText.contains("\n") {
						XCTFail("[\(result.fixture.relativePath)] Function definition line spans multiple lines: \(lineText)",
								file: file, line: line)
					}
				}
				let propertyLines = propertyList.map { $0.name }
				for lineText in propertyLines {
					if lineText.contains("\n") {
						XCTFail("[\(result.fixture.relativePath)] Property definition line spans multiple lines: \(lineText)",
								file: file, line: line)
					}
				}
			}
			
			let expectations = parseTypeExpectations(from: result.fixture.content, language: language)
			if !expectations.expectedReferenced.isEmpty {
				let missingExpected = expectations.expectedReferenced.subtracting(api.referencedTypes)
				if !missingExpected.isEmpty {
					let preview = missingExpected.sorted().prefix(12).joined(separator: ", ")
					XCTFail("[\(result.fixture.relativePath)] Missing expected referenced types: \(preview)",
							file: file, line: line)
				}
			}
			if !expectations.forbiddenReferenced.isEmpty {
				let presentForbidden = expectations.forbiddenReferenced.intersection(api.referencedTypes)
				if !presentForbidden.isEmpty {
					let preview = presentForbidden.sorted().prefix(12).joined(separator: ", ")
					XCTFail("[\(result.fixture.relativePath)] Found forbidden referenced types: \(preview)",
							file: file, line: line)
				}
			}
			if !expectations.expectedFunctionTypes.isEmpty {
				let missingExpected = expectations.expectedFunctionTypes.subtracting(functionSignatureTypes)
				if !missingExpected.isEmpty {
					let preview = missingExpected.sorted().prefix(12).joined(separator: ", ")
					XCTFail("[\(result.fixture.relativePath)] Missing expected function signature types: \(preview)",
							file: file, line: line)
				}
			}
			if !expectations.expectedPropertyTypes.isEmpty {
				let missingExpected = expectations.expectedPropertyTypes.subtracting(propertySignatureTypes)
				if !missingExpected.isEmpty {
					let preview = missingExpected.sorted().prefix(12).joined(separator: ", ")
					XCTFail("[\(result.fixture.relativePath)] Missing expected property signature types: \(preview)",
							file: file, line: line)
				}
			}
			
			for (target, expectedTypes) in expectations.expectedFunctionTypesFor {
				let matches = functionList.filter { matchesFunctionTarget(target, function: $0) }
				if matches.isEmpty {
					XCTFail("[\(result.fixture.relativePath)] No function matches expectation target: \(target)",
							file: file, line: line)
					continue
				}
				var observed = Set<String>()
				for fn in matches {
					observed.formUnion(signatureTypes(for: fn, language: language))
				}
				let missing = expectedTypes.subtracting(observed)
				if !missing.isEmpty {
					let preview = missing.sorted().prefix(12).joined(separator: ", ")
					XCTFail("[\(result.fixture.relativePath)] Missing expected function types for \(target): \(preview)",
							file: file, line: line)
				}
			}
			
			for (target, expectedTypes) in expectations.expectedPropertyTypesFor {
				let matches = propertyList.filter { matchesPropertyTarget(target, property: $0) }
				if matches.isEmpty {
					XCTFail("[\(result.fixture.relativePath)] No property matches expectation target: \(target)",
							file: file, line: line)
					continue
				}
				var observed = Set<String>()
				for prop in matches {
					observed.formUnion(signatureTypes(for: prop, language: language))
				}
				let missing = expectedTypes.subtracting(observed)
				if !missing.isEmpty {
					let preview = missing.sorted().prefix(12).joined(separator: ", ")
					XCTFail("[\(result.fixture.relativePath)] Missing expected property types for \(target): \(preview)",
							file: file, line: line)
				}
			}
			
			for (target, forbiddenTypes) in expectations.forbiddenFunctionTypesFor {
				let matches = functionList.filter { matchesFunctionTarget(target, function: $0) }
				if matches.isEmpty {
					XCTFail("[\(result.fixture.relativePath)] No function matches forbid target: \(target)",
							file: file, line: line)
					continue
				}
				var observed = Set<String>()
				for fn in matches {
					observed.formUnion(signatureTypes(for: fn, language: language))
				}
				let present = observed.intersection(forbiddenTypes)
				if !present.isEmpty {
					let preview = present.sorted().prefix(12).joined(separator: ", ")
					XCTFail("[\(result.fixture.relativePath)] Found forbidden function types for \(target): \(preview)",
							file: file, line: line)
				}
			}
			
			for (target, forbiddenTypes) in expectations.forbiddenPropertyTypesFor {
				let matches = propertyList.filter { matchesPropertyTarget(target, property: $0) }
				if matches.isEmpty {
					XCTFail("[\(result.fixture.relativePath)] No property matches forbid target: \(target)",
							file: file, line: line)
					continue
				}
				var observed = Set<String>()
				for prop in matches {
					observed.formUnion(signatureTypes(for: prop, language: language))
				}
				let present = observed.intersection(forbiddenTypes)
				if !present.isEmpty {
					let preview = present.sorted().prefix(12).joined(separator: ", ")
					XCTFail("[\(result.fixture.relativePath)] Found forbidden property types for \(target): \(preview)",
							file: file, line: line)
				}
			}
		}
	}

	private struct FixtureTypeExpectations {
		var expectedReferenced: Set<String> = []
		var forbiddenReferenced: Set<String> = []
		var expectedFunctionTypes: Set<String> = []
		var expectedPropertyTypes: Set<String> = []
		var expectedFunctionTypesFor: [String: Set<String>] = [:]
		var expectedPropertyTypesFor: [String: Set<String>] = [:]
		var forbiddenFunctionTypesFor: [String: Set<String>] = [:]
		var forbiddenPropertyTypesFor: [String: Set<String>] = [:]
	}

	private static func parseTypeExpectations(from content: String, language: LanguageType) -> FixtureTypeExpectations {
		var expectations = FixtureTypeExpectations()
		let lines = content.split(whereSeparator: \.isNewline)
		for rawLine in lines {
			let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
			if let range = line.range(of: "EXPECT_REFERENCED_TYPES:") {
				let tokens = parseExpectationList(line[range.upperBound...])
				for token in tokens {
					let extracted = TypeCleaner.extractBaseTypes(from: token, language: language)
					expectations.expectedReferenced.formUnion(extracted)
				}
				continue
			}
			if let range = line.range(of: "FORBID_REFERENCED_TYPES:") {
				let tokens = parseExpectationList(line[range.upperBound...])
				for token in tokens where !token.isEmpty {
					expectations.forbiddenReferenced.insert(token)
				}
				continue
			}
			if let range = line.range(of: "EXPECT_FUNCTION_TYPES:") {
				let tokens = parseExpectationList(line[range.upperBound...])
				for token in tokens {
					let extracted = TypeCleaner.extractBaseTypes(from: token, language: language)
					expectations.expectedFunctionTypes.formUnion(extracted)
				}
				continue
			}
			if let range = line.range(of: "EXPECT_PROPERTY_TYPES:") {
				let tokens = parseExpectationList(line[range.upperBound...])
				for token in tokens {
					let extracted = TypeCleaner.extractBaseTypes(from: token, language: language)
					expectations.expectedPropertyTypes.formUnion(extracted)
				}
				continue
			}
			if let range = line.range(of: "EXPECT_FUNCTION_TYPES_FOR:") {
				if let (target, tokens) = parseTargetedExpectation(line[range.upperBound...]) {
					let extracted = tokens.flatMap { TypeCleaner.extractBaseTypes(from: $0, language: language) }
					expectations.expectedFunctionTypesFor[target, default: []].formUnion(extracted)
				}
				continue
			}
			if let range = line.range(of: "EXPECT_PROPERTY_TYPES_FOR:") {
				if let (target, tokens) = parseTargetedExpectation(line[range.upperBound...]) {
					let extracted = tokens.flatMap { TypeCleaner.extractBaseTypes(from: $0, language: language) }
					expectations.expectedPropertyTypesFor[target, default: []].formUnion(extracted)
				}
				continue
			}
			if let range = line.range(of: "FORBID_FUNCTION_TYPES_FOR:") {
				if let (target, tokens) = parseTargetedExpectation(line[range.upperBound...]) {
					let extracted = tokens.flatMap { TypeCleaner.extractBaseTypes(from: $0, language: language) }
					expectations.forbiddenFunctionTypesFor[target, default: []].formUnion(extracted)
				}
				continue
			}
			if let range = line.range(of: "FORBID_PROPERTY_TYPES_FOR:") {
				if let (target, tokens) = parseTargetedExpectation(line[range.upperBound...]) {
					let extracted = tokens.flatMap { TypeCleaner.extractBaseTypes(from: $0, language: language) }
					expectations.forbiddenPropertyTypesFor[target, default: []].formUnion(extracted)
				}
				continue
			}
		}
		return expectations
	}

	private static func parseExpectationList(_ raw: Substring) -> [String] {
		raw.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}
	
	private static func parseTargetedExpectation(_ raw: Substring) -> (target: String, tokens: [String])? {
		guard let arrowRange = raw.range(of: "=>") else { return nil }
		let target = raw[..<arrowRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
		guard !target.isEmpty else { return nil }
		let tokens = parseExpectationList(raw[arrowRange.upperBound...])
		return (target: target, tokens: tokens)
	}
	
	private static func signatureTypes(for function: FunctionInfo, language: LanguageType) -> Set<String> {
		var types = Set<String>()
		if let returnType = function.returnType {
			types.formUnion(TypeCleaner.extractBaseTypes(from: returnType, language: language))
		}
		for param in function.parameters {
			if let typeName = param.typeName {
				types.formUnion(TypeCleaner.extractBaseTypes(from: typeName, language: language))
			}
		}
		return types
	}
	
	private static func signatureTypes(for property: PropertyInfo, language: LanguageType) -> Set<String> {
		var types = Set<String>()
		if let typeName = property.typeName {
			types.formUnion(TypeCleaner.extractBaseTypes(from: typeName, language: language))
		}
		return types
	}
	
	private static func matchesFunctionTarget(_ target: String, function: FunctionInfo) -> Bool {
		return function.name == target || function.definitionLine.contains(target)
	}
	
	private static func matchesPropertyTarget(_ target: String, property: PropertyInfo) -> Bool {
		return property.name == target || property.name.contains(target)
	}

	/// Compare pipeline results against golden files
	private static func compareAgainstGoldens(
		_ result: PipelineResult,
		goldensRoot: URL,
		updatePolicy: GoldenUpdatePolicy,
		file: StaticString,
		line: UInt
	) throws {
		// Golden path: lang/lang_filename.fileapi.json (unique naming to avoid Xcode resource conflicts)
		let fixtureDir = (result.fixture.relativePath as NSString).deletingLastPathComponent
		let fixtureBasename = (result.fixture.relativePath as NSString).lastPathComponent
			.replacingOccurrences(of: ".\(result.fixture.fileExtension)", with: "")
		let goldenBasename = "\(fixtureDir)_\(fixtureBasename).fileapi.json"
		let goldenPath = "\(fixtureDir)/\(goldenBasename)"
		let goldenURL = goldensRoot.appendingPathComponent(goldenPath)
		
		// Create snapshot for comparison
		if let api = result.fileAPI {
			let snapshot = FileAPISnapshot(api: api, stablePath: result.fixture.virtualPath)
			try GoldenStore.assertGolden(snapshot, goldenURL: goldenURL, updatePolicy: updatePolicy, file: file, line: line)
		} else {
			// For nil FileAPI, use an empty marker
			let emptyMarker = EmptyFileAPIMarker(fixture: result.fixture.virtualPath, reason: "No extractable code structure")
			try GoldenStore.assertGolden(emptyMarker, goldenURL: goldenURL, updatePolicy: updatePolicy, file: file, line: line)
		}
		
		// Optional: capture snapshot comparison
		let captureGoldenBasename = "\(fixtureDir)_\(fixtureBasename).captures.json"
		let captureGoldenPath = "\(fixtureDir)/\(captureGoldenBasename)"
		let captureGoldenURL = goldensRoot.appendingPathComponent(captureGoldenPath)
		
		let captureSnapshot = CaptureSnapshot(fixture: result.fixture.virtualPath, captures: result.captures)
		try GoldenStore.assertGolden(captureSnapshot, goldenURL: captureGoldenURL, updatePolicy: updatePolicy, file: file, line: line)
	}
}

// MARK: - Supporting Types

/// Result of running the codemap pipeline
struct PipelineResult {
	let fixture: CodeMapFixture
	let captures: [NamedRange]
	let fileAPI: FileAPI?
}

/// Marker for fixtures that produce no FileAPI
struct EmptyFileAPIMarker: Codable {
	let fixture: String
	let reason: String
}

// MARK: - Query Validation

/// Validates codemap queries for all supported languages
struct CodeMapQueryValidator {
	
	/// Validate that all codemap queries compile and have no tabs
	/// - Parameter file: Source file for assertion failures
	/// - Parameter line: Source line for assertion failures
	static func validateAllQueries(file: StaticString = #filePath, line: UInt = #line) {
		for ext in CodeMapFixtureRunner.supportedExtensions {
			validateQuery(forExtension: ext, file: file, line: line)
		}
	}
	
	/// Validate codemap query for a specific extension
	static func validateQuery(forExtension ext: String, file: StaticString = #filePath, line: UInt = #line) {
		guard let languageType = SyntaxManager.shared.extensionToLanguage[ext.lowercased()] else {
			XCTFail("[\(ext)] No language type mapping found", file: file, line: line)
			return
		}
		
		guard SyntaxManager.shared.supportsCodeMap(fileExtension: ext) else {
			XCTFail("[\(ext)] Extension doesn't support codemap", file: file, line: line)
			return
		}
		
		// Get the query string
		guard let queryString = SyntaxManager.shared.codeMapQueries[languageType] else {
			XCTFail("[\(ext)/\(languageType)] No codemap query found", file: file, line: line)
			return
		}
		
		// Check for tabs (they can cause query compilation issues)
		// Note: This is a soft warning - tabs don't always cause issues but are discouraged
		if queryString.contains("\t") {
			print("⚠️ [\(ext)/\(languageType)] Codemap query contains tab characters - consider using spaces")
		}
		
		// Validate query compiles by trying to use it
		// The actual compilation happens inside SyntaxManager.codeMap
		// We do a minimal test here
		let testContent = "// test"
		do {
			_ = try SyntaxManager.shared.codeMap(content: testContent, fileExtension: ext)
		} catch {
			XCTFail("[\(ext)/\(languageType)] Codemap query failed to compile: \(error)", file: file, line: line)
		}
	}
}
