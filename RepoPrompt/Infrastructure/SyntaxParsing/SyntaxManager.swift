//
//  SyntaxManager.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-05.
//

import Foundation
import SwiftTreeSitter
import tree_sitter  // For TSLanguage
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterRuby

enum LanguageType: String, Comparable, Codable, Sendable {
	case swift, js, c_sharp, python, c, rust, cpp, go, java, dart, ts, tsx,
			php, ruby      // ➜ NEW

	var displayName: String {
		switch self {
		case .swift:  return "Swift"
		case .js:     return "JavaScript"
		case .c_sharp:return "C#"
		case .python: return "Python"
		case .c:      return "C"
		case .rust:   return "Rust"
		case .cpp:    return "C++"
		case .go:     return "Go"
		case .java:   return "Java"
		case .dart:   return "Dart"
		case .ts:     return "TypeScript"
		case .tsx:    return "TSX"
		case .php:    return "PHP"          // NEW
		case .ruby:   return "Ruby"
		}
	}

	var canonicalFileExtension: String {
		switch self {
		case .swift: return "swift"
		case .js: return "js"
		case .c_sharp: return "cs"
		case .python: return "py"
		case .c: return "c"
		case .rust: return "rs"
		case .cpp: return "cpp"
		case .go: return "go"
		case .java: return "java"
		case .dart: return "dart"
		case .ts: return "ts"
		case .tsx: return "tsx"
		case .php: return "php"
		case .ruby: return "rb"
		}
	}

	// MARK: - Comparable
	static func < (lhs: LanguageType, rhs: LanguageType) -> Bool {
		lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
		// If you’d rather sort by declaration order instead, use:
		// lhs.rawValue < rhs.rawValue
	}
}

struct SyntaxLanguageMetadata: Equatable, Sendable {
	let languageType: LanguageType
	let displayName: String
	let canonicalFileExtension: String
}

struct SyntaxParseSummary: Equatable, Sendable {
	let languageType: LanguageType
	let rootNodeType: String?
	let hasRootNode: Bool
}

#if DEBUG
enum SyntaxDebugError: Error, LocalizedError {
	case unsupportedExtension(String)
	case missingLanguageContext(String)
	case parseFailed(String)

	var errorDescription: String? {
		switch self {
		case .unsupportedExtension(let fileExtension):
			return "Unsupported syntax debug file extension: \(fileExtension)"
		case .missingLanguageContext(let fileExtension):
			return "Missing syntax debug language context for extension: \(fileExtension)"
		case .parseFailed(let fileExtension):
			return "Syntax debug parse failed for extension: \(fileExtension)"
		}
	}
}

struct SyntaxDebugQueryCapture: Sendable {
	let name: String
	let range: NSRange
	let textPreview: String
}

struct SyntaxDebugQueryRunResult: Sendable {
	let rootNodeType: String?
	let captures: [SyntaxDebugQueryCapture]
	let matchCount: Int
}
#endif

enum SyntaxOperationOrigin: Sendable {
	case unspecified
	case codeScan(relativePath: String, rootFolderPath: String)
	case previewFull(relativePath: String)
	case previewSlice(relativePath: String, sliceCount: Int)
	case debugHelper(name: String)
	case test(name: String)

	var category: String {
		switch self {
		case .unspecified: return "unspecified"
		case .codeScan: return "codeScan"
		case .previewFull: return "previewFull"
		case .previewSlice: return "previewSlice"
		case .debugHelper: return "debugHelper"
		case .test: return "test"
		}
	}

	var diagnosticSummary: String {
		switch self {
		case .unspecified:
			return category
		case .codeScan(let relativePath, _):
			return "\(category)(pathHash: \(Self.pathHash(relativePath)))"
		case .previewFull(let relativePath):
			return "\(category)(pathHash: \(Self.pathHash(relativePath)))"
		case .previewSlice(let relativePath, let sliceCount):
			return "\(category)(pathHash: \(Self.pathHash(relativePath)), slices: \(sliceCount))"
		case .debugHelper(let name), .test(let name):
			return "\(category)(\(name))"
		}
	}

	private static func pathHash(_ path: String) -> String {
		// Swift's standard string hash is intentionally randomized per process; use a stable
		// FNV-1a digest so diagnostics can correlate events across launches without raw paths.
		var hash: UInt64 = 0xcbf29ce484222325
		for byte in path.utf8 {
			hash ^= UInt64(byte)
			hash &*= 0x100000001b3
		}
		return String(hash, radix: 16)
	}
}

private enum SyntaxTreeSitterOperation: String {
	case warmCache
	case parse
	case highlight
	case codeMap
	case highlightQuery
	case codeMapQuery
	case debugQuery
}

private enum TreeSitterActivityReporter {
	private static var diagnosticsEnabled: Bool {
		#if DEBUG
		let value = ProcessInfo.processInfo.environment["REPOPROMPT_TREE_SITTER_DIAGNOSTICS"]?.lowercased()
		return value == "1" || value == "true" || value == "yes"
		#else
		return false
		#endif
	}

	static func record(
		_ event: String,
		operation: SyntaxTreeSitterOperation,
		origin: SyntaxOperationOrigin = .unspecified,
		fileExtension: String? = nil,
		languageType: LanguageType? = nil,
		byteCount: Int? = nil,
		captureCount: Int? = nil,
		status: String? = nil,
		gateHeld: Bool = SyntaxManager.isTreeSitterGateHeldForCurrentThread()
	) {
		#if DEBUG
		guard diagnosticsEnabled else { return }
		var parts = [
			"event=\(event)",
			"operation=\(operation.rawValue)",
			"origin=\(origin.diagnosticSummary)",
			"gateHeld=\(gateHeld)"
		]
		if let fileExtension { parts.append("ext=\(fileExtension)") }
		if let languageType { parts.append("language=\(languageType.displayName)") }
		if let byteCount { parts.append("bytes=\(byteCount)") }
		if let captureCount { parts.append("captures=\(captureCount)") }
		if let status { parts.append("status=\(status)") }
		print("[TreeSitter] \(parts.joined(separator: " "))")
		#endif
	}
}

final class SyntaxManager {
	static let shared = SyntaxManager()

	private enum CodeMapQueryLookupStatus {
		// Static-slot retrieval is reported as a hit even when Swift performs the slot's first lazy initialization.
		case precomputedHit
		case fallbackCompile
	}

	private struct CodeMapQueryLookupResult {
		let query: Query
		let status: CodeMapQueryLookupStatus
	}

	private enum HighlightQueryLookupStatus {
		case cached
		case compiled
	}

	private struct HighlightQueryLookupResult {
		let query: Query
		let status: HighlightQueryLookupStatus
	}

	private struct TreeSitterLanguageContext {
		let languageType: LanguageType
		let displayName: String
		let language: Language
		let rawPointerAddress: UInt
	}

	private enum LazyCodeMapQueryStore {
		static func lookup(for languageType: LanguageType) throws -> CodeMapQueryLookupResult {
			switch languageType {
			case .swift:
				return CodeMapQueryLookupResult(query: try SwiftQuery.result.get(), status: .precomputedHit)
			case .js:
				return CodeMapQueryLookupResult(query: try JavaScriptQuery.result.get(), status: .precomputedHit)
			case .c_sharp:
				return CodeMapQueryLookupResult(query: try CSharpQuery.result.get(), status: .precomputedHit)
			case .python:
				return CodeMapQueryLookupResult(query: try PythonQuery.result.get(), status: .precomputedHit)
			case .c:
				return CodeMapQueryLookupResult(query: try CQuery.result.get(), status: .precomputedHit)
			case .rust:
				return CodeMapQueryLookupResult(query: try RustQuery.result.get(), status: .precomputedHit)
			case .cpp:
				return CodeMapQueryLookupResult(query: try CppQuery.result.get(), status: .precomputedHit)
			case .go:
				return CodeMapQueryLookupResult(query: try GoQuery.result.get(), status: .precomputedHit)
			case .java:
				return CodeMapQueryLookupResult(query: try JavaQuery.result.get(), status: .precomputedHit)
			case .dart:
				return CodeMapQueryLookupResult(query: try DartQuery.result.get(), status: .precomputedHit)
			case .ts:
				return CodeMapQueryLookupResult(query: try TypeScriptQuery.result.get(), status: .precomputedHit)
			case .tsx:
				return CodeMapQueryLookupResult(query: try TSXQuery.result.get(), status: .precomputedHit)
			case .php:
				return CodeMapQueryLookupResult(query: try PHPQuery.result.get(), status: .precomputedHit)
			case .ruby:
				return CodeMapQueryLookupResult(query: try RubyQuery.result.get(), status: .precomputedHit)
			}
		}

		private enum SwiftQuery { static let result = make(languageType: .swift, queryText: swiftCodeMapQuery) }
		private enum JavaScriptQuery { static let result = make(languageType: .js, queryText: javascriptCodeMapQuery) }
		private enum CSharpQuery { static let result = make(languageType: .c_sharp, queryText: csharpCodeMapQuery) }
		private enum PythonQuery { static let result = make(languageType: .python, queryText: pythonCodeMapQuery) }
		private enum CQuery { static let result = make(languageType: .c, queryText: cCodeMapQuery) }
		private enum RustQuery { static let result = make(languageType: .rust, queryText: rustCodeMapQuery) }
		private enum CppQuery { static let result = make(languageType: .cpp, queryText: cppCodeMapQuery) }
		private enum GoQuery { static let result = make(languageType: .go, queryText: goCodeMapQuery) }
		private enum JavaQuery { static let result = make(languageType: .java, queryText: javaCodeMapQuery) }
		private enum DartQuery { static let result = make(languageType: .dart, queryText: dartCodeMapQuery) }
		private enum TypeScriptQuery { static let result = make(languageType: .ts, queryText: typeScriptCodeMapQuery) }
		private enum TSXQuery { static let result = make(languageType: .tsx, queryText: typeScriptCodeMapQuery) }
		private enum PHPQuery { static let result = make(languageType: .php, queryText: phpCodeMapQuery) }
		private enum RubyQuery { static let result = make(languageType: .ruby, queryText: rubyCodeMapQuery) }

		private static func make(languageType: LanguageType, queryText: String) -> Result<Query, Error> {
			Result {
				SyntaxManager.debugAssertTreeSitterGateHeld("codemap query static creation")
				let (pointer, _) = SyntaxManager.languagePointerAndName(for: languageType)
				guard let pointer else {
					TreeSitterActivityReporter.record(
						"codemap-query-create-failed",
						operation: .codeMapQuery,
						languageType: languageType,
						status: "missing-language-pointer"
					)
					throw SyntaxManager.missingCodeMapQueryError(for: languageType)
				}
				guard let data = queryText.data(using: .utf8) else {
					TreeSitterActivityReporter.record(
						"codemap-query-create-failed",
						operation: .codeMapQuery,
						languageType: languageType,
						status: "invalid-query-utf8"
					)
					throw SyntaxManager.missingCodeMapQueryError(for: languageType)
				}
				TreeSitterActivityReporter.record(
					"codemap-query-create",
					operation: .codeMapQuery,
					languageType: languageType,
					status: "pointer=0x\(String(UInt(bitPattern: pointer), radix: 16))"
				)
				SyntaxManager.debugAssertTreeSitterGateHeld("codemap query Language wrapper creation")
				let language = Language(language: pointer)
				SyntaxManager.debugAssertTreeSitterGateHeld("codemap query compile")
				return try Query(language: language, data: data)
			}
		}
	}

	// Large-file safety thresholds (tuned to avoid common real-world files).
	static let parseLineLimit = 25_000
	static let parseUTF16Limit = 1_500_000
	static let parseUTF8Limit = 5_000_000

	enum ParseOversizeReason: Equatable, CustomStringConvertible {
		case lineCountExceeded(actual: Int)
		case utf16LengthExceeded(actual: Int)
		case utf8SizeExceeded(actual: Int)

		var description: String {
			switch self {
			case .lineCountExceeded(let actual):
				return "line count \(actual) exceeded limit \(SyntaxManager.parseLineLimit)"
			case .utf16LengthExceeded(let actual):
				return "UTF-16 length \(actual) exceeded limit \(SyntaxManager.parseUTF16Limit)"
			case .utf8SizeExceeded(let actual):
				return "UTF-8 size \(actual) exceeded limit \(SyntaxManager.parseUTF8Limit)"
			}
		}
	}

	// Maps file extension to LanguageType.
	let extensionToLanguage: [String: LanguageType] = [
		"swift": .swift,
		"js": .js,
		"cs": .c_sharp,
		"py": .python,
		"c": .c,
		"rs": .rust,
		"cpp": .cpp,
		"go": .go,
		"java": .java,
		"dart": .dart,
		"ts" : .ts,
		"tsx": .tsx,
		"php": .php,          // NEW
		"rb": .ruby
	]

	// Optimized Tree‑sitter highlight queries.
	let optimizedQueries: [LanguageType: String] = [
		.swift: swiftQuery,
		.js: javascriptQuery,
		.c_sharp: csharpQuery,
		.python: pythonQuery,
		.c: cQuery,
		.rust: rustQuery,
		.cpp: cppQuery,
		.go: goQuery,
		.java: javaQuery,
		.dart: dartQuery,
		.ts: typeScriptHighlightQuery,
		.tsx: typeScriptHighlightQuery,
		.php: basicPhpQuery,         // NEW
		.ruby: rubyHighlightQuery
	]

	// Code‑map queries for extracting structure.
	let codeMapQueries: [LanguageType: String] = [
		.c: cCodeMapQuery,
		.cpp: cppCodeMapQuery,
		.c_sharp: csharpCodeMapQuery,
		.go: goCodeMapQuery,
		.rust: rustCodeMapQuery,
		.js: javascriptCodeMapQuery,
		.swift: swiftCodeMapQuery,
		.dart: dartCodeMapQuery,
		.java: javaCodeMapQuery,
		.python: pythonCodeMapQuery,
		.ts: typeScriptCodeMapQuery,
		.tsx: typeScriptCodeMapQuery,
		.php: phpCodeMapQuery,            // NEW
		.ruby: rubyCodeMapQuery
	]

	// Cache for private language contexts. SwiftTreeSitter Language wrappers never leave SyntaxManager in production.
	private var languageContexts: [LanguageType: TreeSitterLanguageContext] = [:]

	// Serializes SwiftTreeSitter language/parser/query work. These wrappers own C pointers and
	// are shared through cached language contexts/Query values, so keep their access one-at-a-time.
	private let treeSitterExecutionLock = NSRecursiveLock()

	// Highlight queries are compiled lazily on first highlight use so codemap startup avoids highlight query work.
	private let highlightQueryCacheLock = NSLock()
	private var highlightQueryResults: [LanguageType: Result<Query, Error>] = [:]

	private static let treeSitterGateDepthKey = "RepoPrompt.SyntaxManager.treeSitterGateDepth"

	fileprivate static func isTreeSitterGateHeldForCurrentThread() -> Bool {
		(Thread.current.threadDictionary[treeSitterGateDepthKey] as? Int ?? 0) > 0
	}

	fileprivate static func debugAssertTreeSitterGateHeld(_ phase: String) {
		#if DEBUG
		let isHeld = isTreeSitterGateHeldForCurrentThread()
		assert(isHeld, "Tree-sitter entry point used outside SyntaxManager gate: \(phase)")
		if !isHeld {
			TreeSitterActivityReporter.record(
				"gate-violation",
				operation: .debugQuery,
				status: phase,
				gateHeld: false
			)
		}
		#endif
	}

	private func withTreeSitterExecution<T>(
		operation: SyntaxTreeSitterOperation,
		origin: SyntaxOperationOrigin,
		fileExtension: String? = nil,
		languageType: LanguageType? = nil,
		byteCount: Int? = nil,
		_ body: () throws -> T
	) rethrows -> T {
		treeSitterExecutionLock.lock()
		let threadDictionary = Thread.current.threadDictionary
		let previousDepth = threadDictionary[Self.treeSitterGateDepthKey] as? Int ?? 0
		threadDictionary[Self.treeSitterGateDepthKey] = previousDepth + 1
		TreeSitterActivityReporter.record(
			"gate-enter",
			operation: operation,
			origin: origin,
			fileExtension: fileExtension,
			languageType: languageType,
			byteCount: byteCount,
			gateHeld: true
		)
		defer {
			TreeSitterActivityReporter.record(
				"gate-exit",
				operation: operation,
				origin: origin,
				fileExtension: fileExtension,
				languageType: languageType,
				byteCount: byteCount,
				gateHeld: true
			)
			if previousDepth == 0 {
				threadDictionary.removeObject(forKey: Self.treeSitterGateDepthKey)
			} else {
				threadDictionary[Self.treeSitterGateDepthKey] = previousDepth
			}
			treeSitterExecutionLock.unlock()
		}
		return try body()
	}

	/// Returns a reason if the provided content should skip Tree-sitter parsing.
	func parsingOversizeReason(for content: String) -> ParseOversizeReason? {
		let utf8View = content.utf8  // (anchor) keep as first line for stable patching

		// 1) Fast-path: UTF‑8 byte size (O(1) when contiguous, otherwise fallback)
		if let byteCount = utf8View.withContiguousStorageIfAvailable({ $0.count }) {
			if byteCount > Self.parseUTF8Limit {
				return .utf8SizeExceeded(actual: byteCount)
			}
		} else {
			let utf8Size = utf8View.count
			if utf8Size > Self.parseUTF8Limit {
				return .utf8SizeExceeded(actual: utf8Size)
			}
		}

		// 2) UTF‑16 code units (only if we didn't already exceed UTF‑8 bytes)
		let utf16Length = content.utf16.count
		if utf16Length > Self.parseUTF16Limit {
			return .utf16LengthExceeded(actual: utf16Length)
		}

		// 3) Line count (early exit when crossing the threshold)
		if let actualLines = exceededLineCount(in: utf8View, limit: Self.parseLineLimit) {
			return .lineCountExceeded(actual: actualLines)
		}
		return nil
	}

	private func exceededLineCount(in utf8: String.UTF8View, limit: Int) -> Int? {
		guard limit > 0 else { return nil }
		guard !utf8.isEmpty else { return nil }

		// Fast path: contiguous UTF‑8 buffer scanning (no indexing overhead)
		if let res = utf8.withContiguousStorageIfAvailable({ (buf: UnsafeBufferPointer<UInt8>) -> Int? in
			var lines = 1
			var i = buf.startIndex
			let end = buf.endIndex

			while i < end {
				let b = buf[i]
				if b == 0x0A { // \n
					lines += 1
					if lines > limit { return lines }
					i = buf.index(after: i)
					continue
				} else if b == 0x0D { // \r
					lines += 1
					if lines > limit { return lines }
					i = buf.index(after: i)
					if i < end, buf[i] == 0x0A { // swallow \r\n
						i = buf.index(after: i)
					}
					continue
				}
				i = buf.index(after: i)
			}
			return nil
		}) {
			// res is Int? produced by the closure; return if limit exceeded
			if let exceeded = res { return exceeded }
			// else fall through to return nil below
			return nil
		}

		// Fallback: safe index-based scan (original logic)
		var lines = 1
		var index = utf8.startIndex
		while index < utf8.endIndex {
			let byte = utf8[index]
			if byte == 0x0A { // \n
				lines += 1
				if lines > limit { return lines }
				index = utf8.index(after: index)
				continue
			} else if byte == 0x0D { // \r
				lines += 1
				if lines > limit { return lines }
				let next = utf8.index(after: index)
				if next < utf8.endIndex, utf8[next] == 0x0A {
					index = utf8.index(after: next)
				} else {
					index = next
				}
				continue
			}
			index = utf8.index(after: index)
		}
		return nil
	}

	private static func languagePointerAndName(for languageType: LanguageType) -> (pointer: UnsafePointer<TSLanguage>?, name: String) {
		switch languageType {
		case .swift:     return (tree_sitter_swift(), "Swift")
		case .js:        return (tree_sitter_javascript(), "JavaScript")
		case .c_sharp:   return (tree_sitter_c_sharp(), "C#")
		case .python:    return (tree_sitter_python(), "Python")
		case .c:         return (tree_sitter_c(), "C")
		case .rust:      return (tree_sitter_rust(), "Rust")
		case .cpp:       return (tree_sitter_cpp(), "C++")
		case .go:        return (tree_sitter_go(), "Go")
		case .java:      return (tree_sitter_java(), "Java")
		case .dart:      return (tree_sitter_dart(), "Dart")
		case .ts:		 return (tree_sitter_typescript(), "TypeScript")
		case .tsx:		 return (tree_sitter_tsx(), "TSX")
		case .php:       return (tree_sitter_php(), "PHP")     // NEW
		case .ruby:      return (tree_sitter_ruby(), "Ruby")
		}
	}

	init() {
		let pipelineStats = CodeMapPerfRuntime.sharedPipelineStats
		let collectStartupPerf = pipelineStats != nil
		var startupStats = CodeMapSyntaxStartupPerfStats()
		let primeStart = collectStartupPerf ? CodeMapPerfRuntime.currentTime() : nil

		warmCache(startupStats: &startupStats, collectPerf: collectStartupPerf)

		if let primeStart {
			startupStats.primeDuration += CodeMapPerfRuntime.durationSince(primeStart)
			pipelineStats?.mergeSyntaxManagerStartupStats(startupStats)
		}
	}

	/// Pre-loads all language contexts at app boot.
	private func warmCache(startupStats: inout CodeMapSyntaxStartupPerfStats, collectPerf: Bool) {
		let warmCacheStart = collectPerf ? CodeMapPerfRuntime.currentTime() : nil
		defer {
			if let warmCacheStart {
				startupStats.warmCacheDuration += CodeMapPerfRuntime.durationSince(warmCacheStart)
			}
		}

		withTreeSitterExecution(operation: .warmCache, origin: .unspecified) {
			for languageType in Set(optimizedQueries.keys).union(codeMapQueries.keys).sorted() {
				if collectPerf { startupStats.warmCacheLanguageCount += 1 }
				if languageContexts[languageType] == nil,
					let context = createLanguageContext(for: languageType, startupStats: &startupStats, collectPerf: collectPerf) {
					languageContexts[languageType] = context
				}
			}
		}
	}

	func languageMetadata(forFileExtension ext: String) -> SyntaxLanguageMetadata? {
		guard let languageType = extensionToLanguage[ext.lowercased()] else { return nil }
		return languageMetadata(for: languageType)
	}

	func languageMetadata(for languageType: LanguageType) -> SyntaxLanguageMetadata {
		SyntaxLanguageMetadata(
			languageType: languageType,
			displayName: languageType.displayName,
			canonicalFileExtension: languageType.canonicalFileExtension
		)
	}

	/// Returns the private language context while the Tree-sitter execution lock is already held.
	private func languageContextUnlocked(forFileExtension ext: String) -> TreeSitterLanguageContext? {
		guard let langType = extensionToLanguage[ext.lowercased()] else { return nil }
		if let context = languageContexts[langType] { return context }
		if let newContext = createLanguageContext(for: langType) {
			languageContexts[langType] = newContext
			return newContext
		}
		return nil
	}

	private func createLanguageContext(for languageType: LanguageType) -> TreeSitterLanguageContext? {
		var startupStats = CodeMapSyntaxStartupPerfStats()
		return createLanguageContext(for: languageType, startupStats: &startupStats, collectPerf: false)
	}

	private func createLanguageContext(
		for languageType: LanguageType,
		startupStats: inout CodeMapSyntaxStartupPerfStats,
		collectPerf: Bool
	) -> TreeSitterLanguageContext? {
		Self.debugAssertTreeSitterGateHeld("language context creation")
		if collectPerf { startupStats.languageConfigCreateCount += 1 }
		let createStart = collectPerf ? CodeMapPerfRuntime.currentTime() : nil
		defer {
			if let createStart {
				startupStats.languageConfigCreateDuration += CodeMapPerfRuntime.durationSince(createStart)
			}
		}

		let pointerStart = collectPerf ? CodeMapPerfRuntime.currentTime() : nil
		let (pointer, name) = Self.languagePointerAndName(for: languageType)
		if let pointerStart {
			startupStats.languagePointerDuration += CodeMapPerfRuntime.durationSince(pointerStart)
		}
		guard let ptr = pointer else {
			print("No language pointer for \(name).")
			TreeSitterActivityReporter.record(
				"language-context-create-failed",
				operation: .warmCache,
				languageType: languageType,
				status: "missing-language-pointer"
			)
			if collectPerf { startupStats.languageConfigFailureCount += 1 }
			return nil
		}
		Self.debugAssertTreeSitterGateHeld("Language wrapper creation")
		let language = Language(language: ptr)

		if collectPerf { startupStats.languageConfigSuccessCount += 1 }
		TreeSitterActivityReporter.record(
			"language-context-create",
			operation: .warmCache,
			languageType: languageType,
			status: "pointer=0x\(String(UInt(bitPattern: ptr), radix: 16))"
		)
		return TreeSitterLanguageContext(
			languageType: languageType,
			displayName: name,
			language: language,
			rawPointerAddress: UInt(bitPattern: ptr)
		)
	}

	/// Parses file content and returns safe value-only summary data without exposing SwiftTreeSitter wrappers.
	func parseSummary(
		content: String,
		fileExtension: String,
		origin: SyntaxOperationOrigin = .unspecified
	) throws -> SyntaxParseSummary? {
		guard let langType = extensionToLanguage[fileExtension.lowercased()] else { return nil }
		if let reason = parsingOversizeReason(for: content) {
			print("[SyntaxManager] Skipping parse for .\(fileExtension): \(reason)")
			return nil
		}

		return try withTreeSitterExecution(
			operation: .parse,
			origin: origin,
			fileExtension: fileExtension,
			languageType: langType,
			byteCount: content.utf8.count
		) {
			guard let context = languageContextUnlocked(forFileExtension: fileExtension) else { return nil }
			guard let tree = try parseTreeUnlocked(
				content: content,
				context: context,
				assertionPrefix: "parse"
			), let root = tree.rootNode else {
				return nil
			}
			return SyntaxParseSummary(
				languageType: langType,
				rootNodeType: root.nodeType,
				hasRootNode: true
			)
		}
	}

	/// Returns whether parsing produced a root node without exposing the underlying MutableTree.
	func parseSucceeds(
		content: String,
		fileExtension: String,
		origin: SyntaxOperationOrigin = .unspecified
	) throws -> Bool {
		try parseSummary(content: content, fileExtension: fileExtension, origin: origin)?.hasRootNode == true
	}

	private func parseTreeUnlocked(
		content: String,
		context: TreeSitterLanguageContext,
		assertionPrefix: String
	) throws -> MutableTree? {
		Self.debugAssertTreeSitterGateHeld("\(assertionPrefix) Parser()")
		let parser = Parser()
		Self.debugAssertTreeSitterGateHeld("\(assertionPrefix) setLanguage")
		try parser.setLanguage(context.language)
		Self.debugAssertTreeSitterGateHeld("\(assertionPrefix) content")
		return parser.parse(content)
	}

	/// Runs the highlight query for a given file's content.
	func highlight(
		content: String,
		fileExtension: String,
		origin: SyntaxOperationOrigin = .unspecified
	) throws -> [NamedRange] {
		// Fast, zero-allocation line guard (bails early once past 5k)
		guard exceededLineCount(in: content.utf8, limit: 5_000) == nil else {
			return []
		}

		guard let langType = extensionToLanguage[fileExtension.lowercased()] else { return [] }
		if let reason = parsingOversizeReason(for: content) {
			print("[SyntaxManager] Skipping highlight parse for .\(fileExtension): \(reason)")
			return []
		}

		return try withTreeSitterExecution(
			operation: .highlight,
			origin: origin,
			fileExtension: fileExtension,
			languageType: langType,
			byteCount: content.utf8.count
		) {
			guard let context = languageContextUnlocked(forFileExtension: fileExtension) else { return [] }
			Self.debugAssertTreeSitterGateHeld("highlight Parser()")
			let parser = Parser()
			Self.debugAssertTreeSitterGateHeld("highlight setLanguage")
			try parser.setLanguage(context.language)

			Self.debugAssertTreeSitterGateHeld("highlight parse")
			guard let tree = parser.parse(content),
				let root = tree.rootNode else {
				return []
			}
			guard let highlightLookup = try highlightQuery(
				for: langType,
				language: context.language,
				origin: origin,
				fileExtension: fileExtension
			) else {
				return []
			}

			TreeSitterActivityReporter.record(
				"highlight-query-lookup",
				operation: .highlightQuery,
				origin: origin,
				fileExtension: fileExtension,
				languageType: langType,
				status: String(describing: highlightLookup.status)
			)
			Self.debugAssertTreeSitterGateHeld("highlight query execute")
			let cursor = highlightLookup.query.execute(node: root, in: tree)
			Self.debugAssertTreeSitterGateHeld("highlight capture materialization")
			let captures = cursor.highlights()
			TreeSitterActivityReporter.record(
				"highlight-captures",
				operation: .highlight,
				origin: origin,
				fileExtension: fileExtension,
				languageType: langType,
				captureCount: captures.count
			)
			return captures
		}
	}

	private func highlightQuery(
		for languageType: LanguageType,
		language: Language,
		origin: SyntaxOperationOrigin,
		fileExtension: String
	) throws -> HighlightQueryLookupResult? {
		try highlightQueryCacheLock.withLock {
			if let cachedResult = highlightQueryResults[languageType] {
				switch cachedResult {
				case .success(let query):
					TreeSitterActivityReporter.record(
						"highlight-query-cache",
						operation: .highlightQuery,
						origin: origin,
						fileExtension: fileExtension,
						languageType: languageType,
						status: "cached"
					)
					return HighlightQueryLookupResult(query: query, status: .cached)
				case .failure(let error):
					TreeSitterActivityReporter.record(
						"highlight-query-cache",
						operation: .highlightQuery,
						origin: origin,
						fileExtension: fileExtension,
						languageType: languageType,
						status: "cached-failure"
					)
					if languageType == .php || languageType == .ruby {
						return nil
					}
					throw error
				}
			}

			guard let highlightQueryText = optimizedQueries[languageType],
				let data = highlightQueryText.data(using: .utf8) else {
				return nil
			}

			Self.debugAssertTreeSitterGateHeld("highlight query compile")
			let result = Result {
				try Query(language: language, data: data)
			}
			highlightQueryResults[languageType] = result

			switch result {
			case .success(let query):
				TreeSitterActivityReporter.record(
					"highlight-query-cache",
					operation: .highlightQuery,
					origin: origin,
					fileExtension: fileExtension,
					languageType: languageType,
					status: "compiled"
				)
				return HighlightQueryLookupResult(query: query, status: .compiled)
			case .failure(let error):
				TreeSitterActivityReporter.record(
					"highlight-query-cache",
					operation: .highlightQuery,
					origin: origin,
					fileExtension: fileExtension,
					languageType: languageType,
					status: "compile-failure"
				)
				print("Error creating query for \(languageType.displayName): \(error)")
				if languageType == .php || languageType == .ruby {
					return nil
				}
				throw error
			}
		}
	}

	private static func missingCodeMapQueryError(for languageType: LanguageType) -> NSError {
		NSError(
			domain: "SyntaxManager.CodeMapQuery",
			code: 1,
			userInfo: [NSLocalizedDescriptionKey: "Missing codemap query for \(languageType.displayName)"]
		)
	}

	private func codeMapQuery(
		for languageType: LanguageType,
		origin: SyntaxOperationOrigin,
		fileExtension: String
	) throws -> CodeMapQueryLookupResult {
		Self.debugAssertTreeSitterGateHeld("codemap query lookup")
		let lookup = try Self.LazyCodeMapQueryStore.lookup(for: languageType)
		TreeSitterActivityReporter.record(
			"codemap-query-lookup",
			operation: .codeMapQuery,
			origin: origin,
			fileExtension: fileExtension,
			languageType: languageType,
			status: String(describing: lookup.status)
		)
		return lookup
	}

	/// Runs the code‑map query for a given file's content.
	func codeMap(
		content: String,
		fileExtension: String,
		origin: SyntaxOperationOrigin = .unspecified
	) throws -> [NamedRange] {
		let pipelineStats = CodeMapPerfRuntime.sharedPipelineStats
		let collectSyntaxPerf = pipelineStats != nil
		var syntaxPerf = CodeMapSyntaxPerfStats()
		if collectSyntaxPerf {
			syntaxPerf.calls = 1
		}
		defer {
			if collectSyntaxPerf {
				pipelineStats?.mergeSyntaxCodeMapStats(syntaxPerf)
			}
		}

		let languageLookupStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
		let langType = extensionToLanguage[fileExtension.lowercased()]
		if let languageLookupStart {
			syntaxPerf.languageLookupDuration += CodeMapPerfRuntime.durationSince(languageLookupStart)
		}
		guard let langType else {
			if collectSyntaxPerf { syntaxPerf.unsupported += 1 }
			return []
		}

		let oversizeGuardStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
		let oversizeReason = parsingOversizeReason(for: content)
		if let oversizeGuardStart {
			syntaxPerf.oversizeGuardDuration += CodeMapPerfRuntime.durationSince(oversizeGuardStart)
		}
		if let reason = oversizeReason {
			if collectSyntaxPerf { syntaxPerf.oversized += 1 }
			print("[SyntaxManager] Skipping code map parse for .\(fileExtension): \(reason)")
			return []
		}

		return try withTreeSitterExecution(
			operation: .codeMap,
			origin: origin,
			fileExtension: fileExtension,
			languageType: langType,
			byteCount: content.utf8.count
		) {
			let configLookupStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
			defer {
				if let configLookupStart {
					syntaxPerf.languageLookupDuration += CodeMapPerfRuntime.durationSince(configLookupStart)
				}
			}
			guard let context = languageContextUnlocked(forFileExtension: fileExtension) else {
				if collectSyntaxPerf { syntaxPerf.unsupported += 1 }
				return []
			}

			let parserCreateStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
			Self.debugAssertTreeSitterGateHeld("codemap Parser()")
			let parser = Parser()
			if let parserCreateStart {
				syntaxPerf.parserCreateDuration += CodeMapPerfRuntime.durationSince(parserCreateStart)
				syntaxPerf.parserCreates += 1
			}

			do {
				let setLanguageStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
				defer {
					if let setLanguageStart {
						syntaxPerf.setLanguageDuration += CodeMapPerfRuntime.durationSince(setLanguageStart)
					}
				}
				Self.debugAssertTreeSitterGateHeld("codemap setLanguage")
				try parser.setLanguage(context.language)
			}

			let tree: MutableTree?
			let parseStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
			Self.debugAssertTreeSitterGateHeld("codemap parse")
			tree = parser.parse(content)
			if let parseStart {
				syntaxPerf.parseDuration += CodeMapPerfRuntime.durationSince(parseStart)
			}
			guard let tree else {
				if collectSyntaxPerf { syntaxPerf.parseNilTree += 1 }
				return []
			}
			guard let root = tree.rootNode else {
				if collectSyntaxPerf { syntaxPerf.parseNilRoot += 1 }
				return []
			}


			/*
			print("\nNode tree for file: \(fileExtension)\n")
			// Debug print: Enumerate all nodes in the tree.
			let fullRange = 0..<UInt32(content.utf16.count)
			print("Enumerating all nodes in the tree:")
			tree.enumerateNodes(in: fullRange) { node in
				print("Node: \(node) - Type: \(node.nodeType)")
			}
			print("\n-------------------------------------------------\n")
			*/

			let query: Query
			do {
				let queryLookupStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
				defer {
					if let queryLookupStart {
						syntaxPerf.codeMapQueryLookupDuration += CodeMapPerfRuntime.durationSince(queryLookupStart)
					}
				}
				let lookup = try codeMapQuery(for: langType, origin: origin, fileExtension: fileExtension)
				if collectSyntaxPerf {
					switch lookup.status {
					case .precomputedHit:
						syntaxPerf.codeMapQueryCacheHits += 1
					case .fallbackCompile:
						syntaxPerf.codeMapQueryCacheMisses += 1
					}
				}
				query = lookup.query
			}

			let queryExecuteStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
			Self.debugAssertTreeSitterGateHeld("codemap query execute")
			let cursor = query.execute(node: root, in: tree)
			if let queryExecuteStart {
				syntaxPerf.queryExecuteDuration += CodeMapPerfRuntime.durationSince(queryExecuteStart)
				syntaxPerf.queryExecutes += 1
			}

			let materializationStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
			Self.debugAssertTreeSitterGateHeld("codemap capture materialization")
			let captures = cursor.highlights()
			if let materializationStart {
				syntaxPerf.captureMaterializationDuration += CodeMapPerfRuntime.durationSince(materializationStart)
				syntaxPerf.captures += captures.count
			}
			TreeSitterActivityReporter.record(
				"codemap-captures",
				operation: .codeMap,
				origin: origin,
				fileExtension: fileExtension,
				languageType: langType,
				captureCount: captures.count
			)
			return captures
		}
	}

	#if DEBUG
	func debugCompileQuery(
		queryText: String,
		fileExtension: String,
		originName: String
	) throws {
		guard let langType = extensionToLanguage[fileExtension.lowercased()] else {
			throw SyntaxDebugError.unsupportedExtension(fileExtension)
		}
		try withTreeSitterExecution(
			operation: .debugQuery,
			origin: .debugHelper(name: originName),
			fileExtension: fileExtension,
			languageType: langType,
			byteCount: queryText.utf8.count
		) {
			guard let context = languageContextUnlocked(forFileExtension: fileExtension) else {
				throw SyntaxDebugError.missingLanguageContext(fileExtension)
			}
			Self.debugAssertTreeSitterGateHeld("debug query compile")
			_ = try Query(language: context.language, data: Data(queryText.utf8))
		}
	}

	func debugRunQuery(
		queryText: String,
		fileExtension: String,
		content: String,
		originName: String
	) throws -> SyntaxDebugQueryRunResult {
		guard let langType = extensionToLanguage[fileExtension.lowercased()] else {
			throw SyntaxDebugError.unsupportedExtension(fileExtension)
		}

		return try withTreeSitterExecution(
			operation: .debugQuery,
			origin: .debugHelper(name: originName),
			fileExtension: fileExtension,
			languageType: langType,
			byteCount: content.utf8.count
		) {
			guard let context = languageContextUnlocked(forFileExtension: fileExtension) else {
				throw SyntaxDebugError.missingLanguageContext(fileExtension)
			}
			Self.debugAssertTreeSitterGateHeld("debug Parser()")
			let parser = Parser()
			Self.debugAssertTreeSitterGateHeld("debug setLanguage")
			try parser.setLanguage(context.language)
			Self.debugAssertTreeSitterGateHeld("debug parse")
			guard let tree = parser.parse(content), let root = tree.rootNode else {
				throw SyntaxDebugError.parseFailed(fileExtension)
			}

			Self.debugAssertTreeSitterGateHeld("debug query compile")
			let query = try Query(language: context.language, data: Data(queryText.utf8))
			Self.debugAssertTreeSitterGateHeld("debug query execute")
			let cursor = query.execute(node: root, in: tree)
			var captures: [SyntaxDebugQueryCapture] = []
			var matchCount = 0
			while let match = cursor.next() {
				matchCount += 1
				for capture in match.captures {
					let captureName = query.captureName(for: capture.index) ?? "unknown"
					captures.append(SyntaxDebugQueryCapture(
						name: captureName,
						range: capture.node.range,
						textPreview: debugTextPreview(for: capture.node.range, in: content)
					))
				}
			}
			return SyntaxDebugQueryRunResult(
				rootNodeType: root.nodeType,
				captures: captures,
				matchCount: matchCount
			)
		}
	}

	func debugTreeDescription(
		content: String,
		fileExtension: String,
		originName: String
	) throws -> String? {
		guard let langType = extensionToLanguage[fileExtension.lowercased()] else {
			throw SyntaxDebugError.unsupportedExtension(fileExtension)
		}
		return try withTreeSitterExecution(
			operation: .debugQuery,
			origin: .debugHelper(name: originName),
			fileExtension: fileExtension,
			languageType: langType,
			byteCount: content.utf8.count
		) {
			guard let context = languageContextUnlocked(forFileExtension: fileExtension) else {
				throw SyntaxDebugError.missingLanguageContext(fileExtension)
			}
			Self.debugAssertTreeSitterGateHeld("debug tree Parser()")
			let parser = Parser()
			Self.debugAssertTreeSitterGateHeld("debug tree setLanguage")
			try parser.setLanguage(context.language)
			Self.debugAssertTreeSitterGateHeld("debug tree parse")
			guard let tree = parser.parse(content), let root = tree.rootNode else {
				throw SyntaxDebugError.parseFailed(fileExtension)
			}
			return root.sExpressionString ?? root.debugDescription
		}
	}

	func debugNodeOutline(
		content: String,
		fileExtension: String,
		maxDepth: Int = 6,
		maxNodes: Int = 250,
		originName: String
	) throws -> String {
		guard let langType = extensionToLanguage[fileExtension.lowercased()] else {
			throw SyntaxDebugError.unsupportedExtension(fileExtension)
		}
		return try withTreeSitterExecution(
			operation: .debugQuery,
			origin: .debugHelper(name: originName),
			fileExtension: fileExtension,
			languageType: langType,
			byteCount: content.utf8.count
		) {
			guard let context = languageContextUnlocked(forFileExtension: fileExtension) else {
				throw SyntaxDebugError.missingLanguageContext(fileExtension)
			}
			Self.debugAssertTreeSitterGateHeld("debug outline Parser()")
			let parser = Parser()
			Self.debugAssertTreeSitterGateHeld("debug outline setLanguage")
			try parser.setLanguage(context.language)
			Self.debugAssertTreeSitterGateHeld("debug outline parse")
			guard let tree = parser.parse(content), let root = tree.rootNode else {
				throw SyntaxDebugError.parseFailed(fileExtension)
			}

			var lines: [String] = []
			var visited = 0
			func visit(_ node: Node, depth: Int) {
				guard visited < maxNodes else { return }
				visited += 1
				let indent = String(repeating: "  ", count: depth)
				let nodeType = node.nodeType ?? "unknown"
				let preview = debugTextPreview(for: node.range, in: content)
				lines.append("\(indent)[\(nodeType)] '\(preview)'")
				guard depth < maxDepth else { return }
				for index in 0..<node.childCount {
					guard let child = node.child(at: index) else { continue }
					visit(child, depth: depth + 1)
				}
			}
			visit(root, depth: 0)
			if visited >= maxNodes {
				lines.append("… truncated after \(maxNodes) nodes")
			}
			return lines.joined(separator: "\n")
		}
	}

	private func debugTextPreview(for range: NSRange, in content: String) -> String {
		guard let stringRange = Range(range, in: content) else { return "" }
		let raw = String(content[stringRange])
			.replacingOccurrences(of: "\n", with: "\\n")
			.replacingOccurrences(of: "\t", with: "\\t")
		if raw.count <= 80 { return raw }
		return String(raw.prefix(80)) + "…"
	}
	#endif

	static func isSupportedFileExtension(_ fileExt: String) -> Bool {
		switch fileExt.lowercased() {
		case "swift", "js", "cs", "py", "c", "rs", "cpp", "go", "java", "dart", "ts", "tsx",
				"php", "rb":   // NEW
			return true
		default:
			return false
		}
	}

	/// Returns `true` if the file extension has a codemap query available.
	/// This is stricter than `isSupportedFileExtension` which only checks syntax highlighting.
	static func supportsCodeMap(fileExtension: String) -> Bool {
		guard let langType = shared.extensionToLanguage[fileExtension.lowercased()] else {
			return false
		}
		return shared.codeMapQueries[langType] != nil
	}

	/// Instance method variant for codemap support check.
	func supportsCodeMap(fileExtension: String) -> Bool {
		guard let langType = extensionToLanguage[fileExtension.lowercased()] else {
			return false
		}
		return codeMapQueries[langType] != nil
	}

	// MARK: - Helper: languages with lightweight extraction
	/// Returns `true` for languages whose code-map extraction skips
	/// full regex/type parsing and instead relies on raw declaration text.
	static func isLightweight(language: LanguageType) -> Bool {
		switch language {
		case .php, .ruby, .ts, .tsx, .js:
			return true
		default:
			return false
		}
	}
}
