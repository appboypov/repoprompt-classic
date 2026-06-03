import XCTest
@testable import RepoPrompt
import Foundation

final class SearchRegexRuntimePerformanceSmokeTests: XCTestCase {

	private struct SmokeWorkload {
		let name: String
		let pattern: String
		let options: SearchOptions
		let minimumHitCount: Int
	}

	private struct SmokeSignature: Equatable, CustomStringConvertible {
		let pathCount: Int
		let contentCount: Int
		let contentFileCount: Int
		let searchedFileCount: Int
		let pathIdentities: [String]
		let matchIdentities: [String]

		var description: String {
			"paths=\(pathCount), content=\(contentCount), contentFiles=\(contentFileCount), searched=\(searchedFileCount)"
		}
	}

	private struct RuntimeMeasurement {
		let signature: SmokeSignature
		let totalMilliseconds: Double
		let iterations: Int

		var averageMilliseconds: Double {
			totalMilliseconds / Double(max(iterations, 1))
		}
	}

	private struct SmokeInputStats {
		let totalBytes: Int
		let totalLines: Int
	}

	private struct SmokeJITDiagnostic {
		let statusDescription: String
		let isCompiled: Bool
		let isFallback: Bool
		let isUnavailable: Bool
		let isDisabled: Bool
		let isCompileError: Bool
	}

	private enum SmokeExpectation {
		case defaultMode
		case jitDisabled
		case matchLimitsDisabled
	}

	private final class SmokeFileViewModel: FileViewModel {
		private let mockContent: String?

		init(name: String, relativePath: String, content: String?) async throws {
			self.mockContent = content

			let rootPath = "/regex-runtime-smoke/root"
			let fullPath = rootPath + "/" + relativePath
			let file = File(
				name: name,
				path: fullPath,
				modificationDate: Date(timeIntervalSince1970: 0)
			)
			let fileSystemService = try await FileSystemService(
				path: FileManager.default.temporaryDirectory.path,
				respectGitignore: false,
				skipSymlinks: true
			)

			super.init(
				file: file,
				rootPath: rootPath,
				hierarchyLevel: 0,
				rootIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
				rootFolderPath: rootPath,
				fileSystemService: fileSystemService
			)
		}

		override var latestContent: String? {
			get async { mockContent }
		}
	}

	func testRegexRuntimePerformanceSmokeComparison() async throws {
		try await runRegexRuntimePerformanceSmokeComparison(expectation: .defaultMode)
	}

	func testRegexRuntimePerformanceSmokeComparisonWithJITDisabled() async throws {
		// This diagnostic variant intentionally mutates process-global environment for the
		// duration of this serial smoke test so it exercises the same rollback knob as production.
		try await withEnvironmentVariable("REPOPROMPT_PCRE2_JIT", value: "disabled") {
			try await runRegexRuntimePerformanceSmokeComparison(expectation: .jitDisabled)
		}
	}

	func testRegexRuntimePerformanceSmokeComparisonWithMatchLimitsDisabled() async throws {
		// This diagnostic variant intentionally mutates process-global environment for the
		// duration of this serial smoke test so it exercises the same rollback knob as production.
		try await withEnvironmentVariable("REPOPROMPT_PCRE2_MATCH_LIMITS", value: "disabled") {
			try await runRegexRuntimePerformanceSmokeComparison(expectation: .matchLimitsDisabled)
		}
	}

	private func runRegexRuntimePerformanceSmokeComparison(expectation: SmokeExpectation) async throws {
		let files = try await Self.makeSmokeFiles()
		let workloads = Self.makeSmokeWorkloads()
		let iterations = Self.iterationCountFromEnvironment(defaultValue: 3)
		let inputStats = await Self.inputStats(for: files)
		let jitDiagnostics = workloads.map(Self.pcre2JITDiagnostic(for:))
		let compiledJITCount = jitDiagnostics.filter(\.isCompiled).count
		let fallbackJITCount = jitDiagnostics.filter(\.isFallback).count
		let unavailableJITCount = jitDiagnostics.filter(\.isUnavailable).count
		let disabledJITCount = jitDiagnostics.filter(\.isDisabled).count
		let compileErrorJITCount = jitDiagnostics.filter(\.isCompileError).count
		var reportRows: [String] = []

		reportRows.append("PCRE2 regex runtime smoke comparison")
		reportRows.append("iterations=\(iterations), files=\(files.count), timing=average per workload after same-process warm-up, batchExecution=enabled")
		reportRows.append("inputBytes=\(inputStats.totalBytes), inputLines=\(inputStats.totalLines)")
		reportRows.append("pcre2BuildJITSupported=\(PCRE2BuildConfiguration.isJITSupported), pcre2JITMode=\(String(describing: RepoPromptRegexRuntime.pcre2JITMode)), matchLimitsEnabled=\(RepoPromptRegexRuntime.pcre2SearchMatchLimitsEnabled)")
		reportRows.append("pcre2JITStatusSummary=compiled \(compiledJITCount)/\(jitDiagnostics.count), fallback \(fallbackJITCount), unavailable \(unavailableJITCount), disabled \(disabledJITCount), compileError \(compileErrorJITCount)")
		reportRows.append("env REPOPROMPT_PCRE2_JIT=\(Self.environmentDescription("REPOPROMPT_PCRE2_JIT")), REPOPROMPT_PCRE2_MATCH_LIMITS=\(Self.environmentDescription("REPOPROMPT_PCRE2_MATCH_LIMITS")), REPOPROMPT_REQUIRE_PCRE2_JIT_SMOKE=\(Self.environmentDescription("REPOPROMPT_REQUIRE_PCRE2_JIT_SMOKE"))")
		reportRows.append("No timing threshold is asserted; this test asserts sane completion and representative hit counts only.")
		reportRows.append("")

		switch expectation {
		case .defaultMode:
			break
		case .jitDisabled:
			XCTAssertEqual(RepoPromptRegexRuntime.pcre2JITMode, .disabled)
			XCTAssertEqual(
				disabledJITCount,
				jitDiagnostics.count,
				"REPOPROMPT_PCRE2_JIT=disabled should report all smoke regexes as JIT disabled; statuses: \(jitDiagnostics.map(\.statusDescription))"
			)
		case .matchLimitsDisabled:
			XCTAssertFalse(RepoPromptRegexRuntime.pcre2SearchMatchLimitsEnabled)
		}

		if Self.requiresPCRE2JITSmoke,
			PCRE2BuildConfiguration.isJITSupported,
			RepoPromptRegexRuntime.pcre2JITMode == .auto {
			XCTAssertGreaterThan(
				compiledJITCount,
				0,
				"REPOPROMPT_REQUIRE_PCRE2_JIT_SMOKE=1 expected at least one smoke regex to compile with PCRE2 JIT; statuses: \(jitDiagnostics.map(\.statusDescription))"
			)
		}

		for (index, workload) in workloads.enumerated() {
			reportRows.append(Self.diagnosticLine(for: workload, inputStats: inputStats, jitStatusDescription: jitDiagnostics[index].statusDescription))
			_ = try await measure(
				workload,
				files: files,
				iterations: 1
			)

			let pcre2 = try await measure(
				workload,
				files: files,
				iterations: iterations
			)

			XCTAssertGreaterThanOrEqual(
				pcre2.signature.pathCount + pcre2.signature.contentCount,
				workload.minimumHitCount,
				"Workload '\(workload.name)' should exercise at least \(workload.minimumHitCount) hit(s)"
			)

			reportRows.append(Self.reportLine(workload: workload.name, pcre2: pcre2))
		}

		let report = reportRows.joined(separator: "\n")
		let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-regex-runtime-smoke-report.txt")
		try? report.write(to: reportURL, atomically: true, encoding: .utf8)
		print("\n\(report)\n")
		await MainActor.run {
			XCTContext.runActivity(named: "Regex runtime smoke performance report") { activity in
				activity.add(XCTAttachment(string: report))
			}
		}
	}

	private func measure(
		_ workload: SmokeWorkload,
		files: [FileViewModel],
		iterations: Int
	) async throws -> RuntimeMeasurement {
		let actor = FileSearchActor()
		var firstSignature: SmokeSignature?
		var lastSignature: SmokeSignature?
		let clampedIterations = max(iterations, 1)
		let start = DispatchTime.now().uptimeNanoseconds

		for _ in 0..<clampedIterations {
			let results = try await actor.searchUnified(
				pattern: workload.pattern,
				isRegex: true,
				options: workload.options,
				in: files
			)
			let signature = Self.signature(for: results)
			if let firstSignature {
				XCTAssertEqual(signature, firstSignature, "Search results should be stable across smoke iterations for workload '\(workload.name)'")
			} else {
				firstSignature = signature
			}
			lastSignature = signature
		}

		let end = DispatchTime.now().uptimeNanoseconds
		return RuntimeMeasurement(
			signature: lastSignature ?? SmokeSignature(pathCount: 0, contentCount: 0, contentFileCount: 0, searchedFileCount: 0, pathIdentities: [], matchIdentities: []),
			totalMilliseconds: Double(end - start) / 1_000_000.0,
			iterations: clampedIterations
		)
	}

	private func withEnvironmentVariable<T>(
		_ name: String,
		value: String?,
		_ body: () throws -> T
	) rethrows -> T {
		let oldValue = getenv(name).map { String(cString: $0) }
		setEnvironmentVariable(name, value: value)
		defer { setEnvironmentVariable(name, value: oldValue) }
		return try body()
	}

	private func withEnvironmentVariable<T>(
		_ name: String,
		value: String?,
		_ body: () async throws -> T
	) async rethrows -> T {
		let oldValue = getenv(name).map { String(cString: $0) }
		setEnvironmentVariable(name, value: value)
		defer { setEnvironmentVariable(name, value: oldValue) }
		return try await body()
	}

	private func setEnvironmentVariable(_ name: String, value: String?) {
		if let value {
			XCTAssertEqual(setenv(name, value, 1), 0, "Expected to set \(name)")
		} else {
			XCTAssertEqual(unsetenv(name), 0, "Expected to unset \(name)")
		}
	}

	private static func signature(for results: SearchResults) -> SmokeSignature {
		let paths = results.paths ?? []
		let matches = results.matches ?? []
		return SmokeSignature(
			pathCount: paths.count,
			contentCount: results.totalCount ?? matches.count,
			contentFileCount: results.contentFileCount ?? 0,
			searchedFileCount: results.searchedFileCount ?? 0,
			pathIdentities: paths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(),
			matchIdentities: matches.map { match in
				let fileName = URL(fileURLWithPath: match.filePath).lastPathComponent
				return "\(fileName):\(match.lineNumber):\(match.lineText)"
			}.sorted()
		)
	}

	private static func inputStats(for files: [FileViewModel]) async -> SmokeInputStats {
		var totalBytes = 0
		var totalLines = 0
		for file in files {
			guard let text = await file.latestContent else { continue }
			totalBytes += text.utf8.count
			totalLines += text.isEmpty ? 0 : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
		}
		return SmokeInputStats(totalBytes: totalBytes, totalLines: totalLines)
	}

	private static func environmentDescription(_ name: String) -> String {
		environmentValue(name) ?? "<unset>"
	}

	private static func environmentValue(_ name: String) -> String? {
		getenv(name).map { String(cString: $0) }
	}

	private static var requiresPCRE2JITSmoke: Bool {
		switch environmentValue("REPOPROMPT_REQUIRE_PCRE2_JIT_SMOKE")?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased() {
		case "1", "true", "yes", "on", "require", "required":
			return true
		default:
			return false
		}
	}

	private static func diagnosticLine(for workload: SmokeWorkload, inputStats: SmokeInputStats, jitStatusDescription: String) -> String {
		let anchored = RegexToolkit.isLineAnchored(workload.pattern) || workload.pattern.first == "^" || workload.pattern.last == "$"
		let expensiveUnanchored = RegexToolkit.isExpensiveUnanchored(workload.pattern)
		let anchoredDeclaration = RepoPromptPCRE2Adapter.anchoredDeclarationLinePlan(for: workload.pattern, caseInsensitive: workload.options.caseInsensitive)
		let asciiMarker = RepoPromptPCRE2Adapter.asciiMarkerLinePatternPlan(forRegex: workload.pattern, caseInsensitive: workload.options.caseInsensitive)
		let linePrefilter = RepoPromptPCRE2Adapter.linePrefilterForAnchoredPattern(workload.pattern, caseInsensitive: workload.options.caseInsensitive)
		let asciiWholeWord = RepoPromptPCRE2Adapter.asciiWholeWordLiteralPlan(
			pattern: workload.pattern,
			isRegex: true,
			wholeWord: workload.options.wholeWord,
			caseInsensitive: workload.options.caseInsensitive
		)
		let pathSuffix = RepoPromptPCRE2Adapter.pathSuffixPattern(forRegex: workload.pattern)
		let scanHint: String = {
			switch workload.options.mode {
			case .path:
				return pathSuffix == nil ? "path-regex" : "path-suffix-fast-path"
			case .content, .both, .auto:
				if asciiWholeWord != nil { return "content-ascii-whole-word-fast-path" }
				if anchoredDeclaration != nil { return "content-anchored-declaration-fast-path" }
				if asciiMarker != nil { return "content-ascii-marker-fast-path" }
				if anchored || expensiveUnanchored { return linePrefilter == nil ? "content-line-by-line" : "content-line-by-line-prefilter" }
				if inputStats.totalBytes > 1_000_000 { return "content-line-by-line-large-input" }
				return "content-full-buffer"
			}
		}()
		return "diagnostic \(workload.name) | anchored=\(anchored), expensiveUnanchored=\(expensiveUnanchored), scanHint=\(scanHint), anchoredDeclaration=\(anchoredDeclaration != nil), linePrefilter=\(linePrefilter?.asciiRequiredAlternatives ?? []), asciiWholeWord=\(asciiWholeWord != nil), asciiMarker=\(asciiMarker != nil), batchExecution=enabled, countOnly=\(workload.options.countOnly), contextLines=\(workload.options.contextLines), maxResults=\(workload.options.maxResults), pathSuffix=\(pathSuffix?.suffixes ?? []), pcre2PatternJIT=\(jitStatusDescription)"
	}

	private static func pcre2JITDiagnostic(for workload: SmokeWorkload) -> SmokeJITDiagnostic {
		let effectivePattern = workload.options.wholeWord ? "\\b\(workload.pattern)\\b" : workload.pattern
		do {
			let regex = try RepoPromptPCRE2Adapter.compile(RepoPromptPCRE2CompileRequest(
				pattern: effectivePattern,
				caseInsensitive: workload.options.caseInsensitive,
				multilineAnchors: effectivePattern.contains("^") || effectivePattern.contains("$")
			))
			let statusDescription = String(describing: regex.jitStatus)
			switch regex.jitStatus {
			case .compiled:
				return SmokeJITDiagnostic(statusDescription: statusDescription, isCompiled: true, isFallback: false, isUnavailable: false, isDisabled: false, isCompileError: false)
			case .fallback:
				return SmokeJITDiagnostic(statusDescription: statusDescription, isCompiled: false, isFallback: true, isUnavailable: false, isDisabled: false, isCompileError: false)
			case .unavailable:
				return SmokeJITDiagnostic(statusDescription: statusDescription, isCompiled: false, isFallback: false, isUnavailable: true, isDisabled: false, isCompileError: false)
			case .disabled:
				return SmokeJITDiagnostic(statusDescription: statusDescription, isCompiled: false, isFallback: false, isUnavailable: false, isDisabled: true, isCompileError: false)
			}
		} catch {
			return SmokeJITDiagnostic(statusDescription: "compile-error(\(error.localizedDescription))", isCompiled: false, isFallback: false, isUnavailable: false, isDisabled: false, isCompileError: true)
		}
	}

	private static func makeSmokeWorkloads() -> [SmokeWorkload] {
		let contentCountOnly = SearchOptions(
			mode: .content,
			caseInsensitive: false,
			includeExtensions: [".swift"],
			maxResults: 500,
			countOnly: true,
			fuzzySpaceMatching: false,
			allowLiteralUnescapeFallback: false
		)
		let materializedContent = SearchOptions(
			mode: .content,
			caseInsensitive: false,
			includeExtensions: [".swift"],
			contextLines: 0,
			maxResults: 500,
			countOnly: false,
			fuzzySpaceMatching: false,
			allowLiteralUnescapeFallback: false
		)
		let pathOnly = SearchOptions(
			mode: .path,
			caseInsensitive: false,
			includeExtensions: [".swift"],
			maxResults: 20,
			countOnly: false,
			fuzzySpaceMatching: false,
			allowLiteralUnescapeFallback: false
		)
		let largePathOnly = SearchOptions(
			mode: .path,
			caseInsensitive: false,
			includeExtensions: [".swift"],
			maxResults: 250,
			countOnly: false,
			fuzzySpaceMatching: false,
			allowLiteralUnescapeFallback: false
		)

		let alternationTokens = (0..<80).map { "token\($0)" }.joined(separator: "|")

		return [
			SmokeWorkload(
				name: "anchored declarations",
				pattern: #"^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*"#,
				options: contentCountOnly,
				minimumHitCount: 1
			),
			SmokeWorkload(
				name: "PCRE shorthand todo markers",
				pattern: #"\bTODO-\d{3}:\s+Search\w*"#,
				options: materializedContent,
				minimumHitCount: 1
			),
			SmokeWorkload(
				name: "regex whole-word wrapper",
				pattern: #"SearchResult"#,
				options: SearchOptions(
					mode: .content,
					caseInsensitive: false,
					wholeWord: true,
					includeExtensions: [".swift"],
					maxResults: 500,
					countOnly: true,
					fuzzySpaceMatching: false,
					allowLiteralUnescapeFallback: false
				),
				minimumHitCount: 1
			),
			SmokeWorkload(
				name: "stress alternation from search coverage",
				pattern: alternationTokens,
				options: contentCountOnly,
				minimumHitCount: 1
			),
			SmokeWorkload(
				name: "path regex suffix",
				pattern: #"GeneratedSearchFile_0[0-7]\.swift$"#,
				options: pathOnly,
				minimumHitCount: 1
			),
			SmokeWorkload(
				name: "large corpus sparse content regex",
				pattern: #"\bSparseNeedle\d{4}\b"#,
				options: contentCountOnly,
				minimumHitCount: 10
			),
			SmokeWorkload(
				name: "large corpus path regex",
				pattern: #"LargeCorpusFile_0\d{3}\.swift$"#,
				options: largePathOnly,
				minimumHitCount: 100
			)
		]
	}

	private static func makeSmokeFiles() async throws -> [SmokeFileViewModel] {
		var files: [SmokeFileViewModel] = []
		files.reserveCapacity(1208)

		for fileIndex in 0..<8 {
			let name = String(format: "GeneratedSearchFile_%02d.swift", fileIndex)
			let relativePath = "Smoke/Search/\(name)"
			let content = makeSmokeContent(fileIndex: fileIndex)
			let file = try await SmokeFileViewModel(
				name: name,
				relativePath: relativePath,
				content: content
			)
			files.append(file)
		}

		for fileIndex in 0..<1200 {
			let name = String(format: "LargeCorpusFile_%04d.swift", fileIndex)
			let relativePath = "Smoke/Large/Shard_\(fileIndex / 100)/\(name)"
			let content = makeLargeSmokeContent(fileIndex: fileIndex)
			let file = try await SmokeFileViewModel(
				name: name,
				relativePath: relativePath,
				content: content
			)
			files.append(file)
		}

		return files
	}

	private static func makeSmokeContent(fileIndex: Int) -> String {
		var lines: [String] = []
		lines.reserveCapacity(260)

		for lineIndex in 0..<260 {
			switch lineIndex % 10 {
			case 0:
				lines.append("func performSearch\(fileIndex)_\(lineIndex)(query: String) -> SearchResult { return SearchResult(id: token\(lineIndex % 80)) }")
			case 1:
				lines.append("final class GeneratedSearchController\(fileIndex)_\(lineIndex) { let marker = \"TODO-\(100 + (lineIndex % 50)): SearchIndex\" }")
			case 2:
				lines.append("struct SearchResultEnvelope\(fileIndex)_\(lineIndex) { let value: SearchResult }")
			case 3:
				lines.append("// FIXME-\(200 + (lineIndex % 70)): RegexMigration token\(lineIndex % 80)")
			case 4:
				lines.append("let message\(lineIndex) = \"Rocket     launch SearchResult token\(lineIndex % 80)\"")
			case 5:
				lines.append("let stress\(lineIndex) = \"token\(lineIndex % 80) token\((lineIndex + 13) % 80) token\((lineIndex + 29) % 80)\"")
			default:
				lines.append("// filler \(fileIndex)-\(lineIndex) without indexed search markers")
			}
		}

		return lines.joined(separator: "\n")
	}

	private static func makeLargeSmokeContent(fileIndex: Int) -> String {
		var lines: [String] = []
		lines.reserveCapacity(24)
		for lineIndex in 0..<24 {
			if fileIndex % 97 == 0, lineIndex == 7 {
				lines.append(String(format: "let sparse_%04d = \"SparseNeedle%04d SearchResult\"", fileIndex, fileIndex))
			} else if lineIndex % 8 == 0 {
				lines.append("func largeCorpusHelper\(fileIndex)_\(lineIndex)() -> String { \"SearchResult\" }")
			} else {
				lines.append("// large filler \(fileIndex)-\(lineIndex) token\(lineIndex % 80)")
			}
		}
		return lines.joined(separator: "\n")
	}

	private static func iterationCountFromEnvironment(defaultValue: Int) -> Int {
		let rawValue = ProcessInfo.processInfo.environment["REPOPROMPT_REGEX_PERF_SMOKE_ITERATIONS"]
		guard let rawValue, let parsed = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
			return defaultValue
		}
		return max(parsed, 1)
	}

	private static func reportLine(workload: String, pcre2: RuntimeMeasurement) -> String {
		String(
			format: "%@ | PCRE2 %.2f ms avg | %@",
			workload,
			pcre2.averageMilliseconds,
			pcre2.signature.description
		)
	}
}
