import Foundation
import MCP

/// An in-memory, single-file virtualised environment for agent delegate edits.
/// All operations are strictly limited to `allowedPath`.
actor DelegateEditSandbox {
	// MARK: - Errors
	private enum SandboxApplyError: Swift.Error {
		case invalidParams(String)
		case internalError(String)
	}

	private enum SandboxRegexMode: Hashable {
		case regex
		case wholeWordLiteral
	}

	private struct SandboxRegexCacheKey: Hashable {
		let pattern: String
		let mode: SandboxRegexMode
		let caseInsensitive: Bool
		let wholeWord: Bool
	}

	private typealias LineEndingPair = (line: String, ending: String)

	// MARK: - State
	let allowedPath: String
	let original: String
	private(set) var current: String
	private var contentRevision: UInt64 = 0
	private var cachedSearchLines: (revision: UInt64, lines: [String])?
	private var cachedLineEndingPairs: (revision: UInt64, pairs: [LineEndingPair])?
	private var regexCache: [SandboxRegexCacheKey: PCRE2Regex] = [:]

    // MARK: - Init
    init(allowedPath: String, original: String) {
        self.allowedPath = allowedPath
        self.original = original
        self.current = original
    }

    // MARK: - Public API

	/// Returns the current in-memory content.
	func currentContent() -> String {
		current
	}

	/// Overwrite the current in-memory content.
	func setContent(_ content: String) {
		guard content != current else { return }
		current = content
		contentRevision &+= 1
		cachedSearchLines = nil
		cachedLineEndingPairs = nil
	}

	/// Read a portion (or all) of the file.
	/// - Args:
	///   - path (optional): ignored; sandbox always operates on allowedPath (a note is emitted when it differs)
	///   - start_line (optional Int or String): 1-based start line; if negative, treated as "last N lines"
	///   - limit (optional Int or String): number of lines to return from start_line
	func callReadFile(args: [String: Value]) async -> CallTool.Result {
		let perfState = EditFlowPerf.begin(
			EditFlowPerf.Stage.DelegateSandbox.readFile,
			EditFlowPerf.Dimensions(fileBytes: current.utf8.count)
		)
		defer {
			EditFlowPerf.end(
				EditFlowPerf.Stage.DelegateSandbox.readFile,
				perfState,
				EditFlowPerf.Dimensions(fileBytes: current.utf8.count)
			)
		}

		let correctionNote = correctedPathNote(from: args["path"])
		let startLineParam = Self.parseInt(from: args["start_line"]) ?? Self.parseInt(from: args["offset"])
		let limitParam = Self.parseInt(from: args["limit"])

		if let start = startLineParam, start == 0 {
			return CallTool.Result.err("read_file: start_line must be positive (1-based) or negative (tail-like behavior).")
		}
		if let start = startLineParam, start < 0, limitParam != nil {
			return CallTool.Result.err("read_file: limit parameter is not allowed with negative start_line. Use start_line=-N to read the last N lines.")
		}

		let pairs = lineEndingPairsForCurrentContent()
		let totalLines = pairs.count

		let (firstIndex, lastExclusive): (Int, Int) = {
			guard let start = startLineParam else {
				return (0, totalLines)
			}
			if start < 0 {
				let linesToRead = max(0, -start)
				let startIndex = max(0, totalLines - linesToRead)
				return (startIndex, totalLines)
			}
			let zeroBasedStart = max(0, start - 1)
			let endIndex: Int
			if let limitParam = limitParam, limitParam >= 0 {
				endIndex = min(totalLines, zeroBasedStart + limitParam)
			} else {
				endIndex = totalLines
			}
			return (zeroBasedStart, endIndex)
		}()

		let displayPath = allowedPath

		if !(firstIndex < totalLines || totalLines == 0) {
			let dto = ToolResultDTOs.ReadFileReply(
				content: "",
				totalLines: totalLines,
				firstLine: max(1, firstIndex + 1),
				lastLine: totalLines,
				message: Self.combineMessages("Requested start_line exceeds file length.", correctionNote),
				displayPath: displayPath
			)
			return encodeDTOResult(dto, toolName: "read_file")
		}

		let sliceContent: String = {
			if totalLines == 0 { return "" }
			let slice = pairs[firstIndex..<lastExclusive]
			return slice.map { $0.line + $0.ending }.joined()
		}()

		let shownFirst = totalLines == 0 ? 0 : (firstIndex + 1)
		let shownLast = totalLines == 0 ? 0 : lastExclusive

		let dto = ToolResultDTOs.ReadFileReply(
			content: sliceContent,
			totalLines: totalLines,
			firstLine: shownFirst,
			lastLine: shownLast,
			message: correctionNote,
			displayPath: displayPath
		)
		return encodeDTOResult(dto, toolName: "read_file")
	}

	/// Search for a pattern within the current content.
	/// - Args:
	///   - pattern (string, required)
	///   - regex (bool, optional, auto-detected by default)
	///   - whole_word (bool, optional, default false)
	///   - case_insensitive (bool, optional, default true)
	///   - mode (string, optional, ignored for now; preserved for future expansion)
	func callFileSearch(args: [String: Value]) async -> CallTool.Result {
		var perfMatchCount: Int?
		var perfLineCount: Int?
		var perfIsRegex: Bool?
		var perfWholeWord: Bool?
		var perfCountOnly: Bool?
		var perfCaseInsensitive: Bool?
		var perfContextLines: Int?
		var perfCacheHit: Bool?
		let perfState = EditFlowPerf.begin(
			EditFlowPerf.Stage.DelegateSandbox.fileSearch,
			EditFlowPerf.Dimensions(fileBytes: current.utf8.count)
		)
		defer {
			EditFlowPerf.end(
				EditFlowPerf.Stage.DelegateSandbox.fileSearch,
				perfState,
				EditFlowPerf.Dimensions(
					fileBytes: current.utf8.count,
					lineCount: perfLineCount,
					matchCount: perfMatchCount,
					cacheHit: perfCacheHit,
					isRegex: perfIsRegex,
					countOnly: perfCountOnly,
					caseInsensitive: perfCaseInsensitive,
					wholeWord: perfWholeWord,
					contextLines: perfContextLines
				)
			)
		}

		guard let rawPattern = args["pattern"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPattern.isEmpty else {
			return CallTool.Result.err("file_search: 'pattern' is required.")
		}

		let regexArg = args["regex"]?.boolValue
		let useRegex = regexArg ?? FileSearchActor.containsRegexSyntax(rawPattern)
		let wholeWord = args["whole_word"]?.boolValue ?? false
		let caseInsensitive = args["case_insensitive"]?.boolValue ?? true
		let contextLines = max(0, Self.parseInt(from: args["context_lines"]) ?? 0)
		let countOnly = args["count_only"]?.boolValue ?? false
		let requestedMax = Self.parseInt(from: args["max_results"]) ?? 50
		let maxResults = requestedMax > 0 ? requestedMax : 50
		perfIsRegex = useRegex
		perfWholeWord = wholeWord
		perfCountOnly = countOnly
		perfCaseInsensitive = caseInsensitive
		perfContextLines = contextLines

		let lineSnapshot = searchLinesSnapshotForCurrentContent()
		let lines = lineSnapshot.lines
		perfLineCount = lines.count
		perfCacheHit = lineSnapshot.cacheHit

		func matchedLineIndices(using regex: PCRE2Regex) throws -> [Int] {
			try regex.withMatchSession(matchLimits: RepoPromptPCRE2MatchPolicy.fileSearchLine) { session in
				var indices: [Int] = []
				indices.reserveCapacity(8)
				for (idx, line) in lines.enumerated() {
					if try session.containsMatch(in: line) {
						indices.append(idx)
					}
				}
				return indices
			}
		}

		func regexErrorDTO(message: String, suggestion: String? = nil) -> ToolResultDTOs.SearchResultDTO {
			ToolResultDTOs.SearchResultDTO(
				totalMatches: 0,
				totalFiles: 0,
				contentMatches: 0,
				pathMatches: 0,
				limitHit: false,
				perFileCounts: [],
				pathMatchLines: [],
				contentMatchGroups: [],
				sizeLimitHit: nil,
				omittedTotal: nil,
				omittedContentMatches: nil,
				omittedPathMatches: nil,
				errorMessage: message,
				suggestion: suggestion,
				perFileTotals: nil
			)
		}

		func regexFailureDTO(prefix: String, failure: RegexPatternFailure) -> ToolResultDTOs.SearchResultDTO {
			if let searchError = failure as? SearchPatternError {
				let parts = SearchPatternErrorFormatter.parts(
					for: rawPattern,
					isRegex: true,
					error: searchError
				)
				return regexErrorDTO(message: parts.issue, suggestion: parts.suggestion)
			}
			return regexErrorDTO(message: "\(prefix): \(failure.localizedDescription)")
		}

		let matchedIndices: [Int]
		if useRegex {
			do {
				let regex = try cachedSearchRegex(
					pattern: rawPattern,
					caseInsensitive: caseInsensitive,
					wholeWord: wholeWord
				)
				matchedIndices = try matchedLineIndices(using: regex)
			} catch {
				let failure = RepoPromptPCRE2Adapter.searchPatternError(from: error, pattern: rawPattern)
				let dto = regexFailureDTO(prefix: "invalid regex pattern", failure: failure)
				return encodeDTOResult(dto, toolName: "file_search")
			}
		} else if wholeWord {
			do {
				let regex = try cachedWholeWordLiteralRegex(
					pattern: rawPattern,
					caseInsensitive: caseInsensitive
				)
				matchedIndices = try matchedLineIndices(using: regex)
			} catch {
				let failure = RepoPromptPCRE2Adapter.searchPatternError(from: error, pattern: rawPattern)
				let dto = regexFailureDTO(prefix: "invalid whole-word pattern", failure: failure)
				return encodeDTOResult(dto, toolName: "file_search")
			}
		} else {
			let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
			matchedIndices = lines.enumerated().compactMap { idx, line in
				line.range(of: rawPattern, options: options) != nil ? idx : nil
			}
		}

		let totalMatches = matchedIndices.count
		perfMatchCount = totalMatches
		let limitedMatches = countOnly ? matchedIndices : Array(matchedIndices.prefix(maxResults))
		let limitedCount = limitedMatches.count
		let limitHit = !countOnly && totalMatches > limitedCount
		let omitted = limitHit ? (totalMatches - limitedCount) : 0

		let perFileCounts: [ToolResultDTOs.PerFileCount] = (totalMatches > 0)
			? [ToolResultDTOs.PerFileCount(path: allowedPath, count: totalMatches)]
			: []

		var groups: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup] = []
		if !countOnly && !limitedMatches.isEmpty {
			let groupLines: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup.Line] = limitedMatches.map { lineIndex in
				let beforeIndices: [Int]
				if contextLines > 0 {
					let start = max(0, lineIndex - contextLines)
					let end = lineIndex - 1
					beforeIndices = end >= start ? Array(start...end) : []
				} else {
					beforeIndices = []
				}

				let afterIndices: [Int]
				if contextLines > 0 {
					let start = lineIndex + 1
					let end = min(lines.count - 1, lineIndex + contextLines)
					afterIndices = end >= start ? Array(start...end) : []
				} else {
					afterIndices = []
				}

				let beforeContexts: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine]? = beforeIndices.isEmpty
					? nil
					: beforeIndices.map {
						ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine(
							lineNumber: $0 + 1,
							lineText: String(lines[$0])
						)
					}

				let afterContexts: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine]? = afterIndices.isEmpty
					? nil
					: afterIndices.map {
						ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine(
							lineNumber: $0 + 1,
							lineText: String(lines[$0])
						)
					}

				return ToolResultDTOs.SearchResultDTO.ContentMatchGroup.Line(
					lineNumber: lineIndex + 1,
					lineText: String(lines[lineIndex]),
					contextBefore: beforeContexts,
					contextAfter: afterContexts
				)
			}

			groups = [
				ToolResultDTOs.SearchResultDTO.ContentMatchGroup(
					path: allowedPath,
					lines: groupLines
				)
			]
		}

		let dto = ToolResultDTOs.SearchResultDTO(
			totalMatches: totalMatches,
			totalFiles: totalMatches > 0 ? 1 : 0,
			contentMatches: totalMatches,
			pathMatches: 0,
			limitHit: limitHit,
			perFileCounts: perFileCounts,
			pathMatchLines: [],
			contentMatchGroups: countOnly ? [] : groups,
			sizeLimitHit: nil,
			omittedTotal: limitHit ? omitted : nil,
			omittedContentMatches: limitHit ? omitted : nil,
			omittedPathMatches: nil,
			errorMessage: nil,
			suggestion: nil,
			perFileTotals: nil
		)
		return encodeDTOResult(dto, toolName: "file_search")
	}

	/// Apply edits to the current in-memory content.
	/// - Supported modes:
	///   a) rewrite: String → replace entire content
	///   b) search + replace (+ all: Bool) → find/replace single or all occurrences
	///   c) edits: [ {search, replace, all?} ] → batch search/replace operations
	/// - Additional:
	///   - path (string, optional): ignored; sandbox always edits allowedPath (note emitted when different)
	///   - verbose (bool, optional): when true, returns a unified diff of the change
	func callApplyEdits(
		args: [String: Value],
		surfaceToolName: String = DelegateEditToolNames.editFile,
		argsAreNormalized: Bool = false
	) async -> CallTool.Result {
		let perfState = EditFlowPerf.begin(
			EditFlowPerf.Stage.DelegateSandbox.applyEdits,
			EditFlowPerf.Dimensions(toolName: surfaceToolName, fileBytes: current.utf8.count)
		)
		var appliedCount: Int?
		defer {
			EditFlowPerf.end(
				EditFlowPerf.Stage.DelegateSandbox.applyEdits,
				perfState,
				EditFlowPerf.Dimensions(
					toolName: surfaceToolName,
					fileBytes: current.utf8.count,
					appliedCount: appliedCount
				)
			)
		}

		do {
			let request = try EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.requestBuild) {
				if argsAreNormalized {
					try ApplyEditsRequestBuilder().buildFromNormalizedPayload(args)
				} else {
					try ApplyEditsRequestBuilder().build(from: args)
				}
			}
			let correctionNote = correctedPathNote(request.path)
			let service = ApplyEditsService(
				engine: .default,
				host: SandboxFileEditHost(sandbox: self)
			)
			let result = try await service.run(request, options: .delegateSandbox)
			appliedCount = result.editsApplied
			let note = Self.combineMessages(result.note, correctionNote)
			return buildResult(diff: result.unifiedDiff, note: note)
		} catch {
			return CallTool.Result.err(errorMessage(from: error, surfaceToolName: surfaceToolName))
		}
	}

	// MARK: - Helpers

	/// Build the result from an edit response (with optional diff and note)
	private func buildResult(diff: String?, note: String?) -> CallTool.Result {
		var payload: [String: String] = ["status": "ok"]
		if let diff = diff {
			payload["diff"] = diff
		}
		if let note = note {
			payload["note"] = note
		}

		let body = Self.encodeJSON(payload)
		return CallTool.Result(content: [.text(body)], isError: false)
	}
	
	/// Convert errors to user-friendly messages
	private func errorMessage(from error: Swift.Error, surfaceToolName: String) -> String {
		if let editError = error as? ApplyEditsError {
			switch editError {
			case .invalidParams(let message):
				return "\(surfaceToolName): \(message)"
			case .internalError(let message):
				return "\(surfaceToolName): \(message)"
			}
		}
		return "\(surfaceToolName): \(error.localizedDescription)"
	}

	private static func encodeJSON(_ dict: [String: String]) -> String {
		if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
		   let json = String(data: data, encoding: .utf8) {
			return json
		}
		return "{\"status\":\"ok\"}"
	}

	/// Build correction message if requested path differs from allowedPath
	private func correctedPathNote(from pathValue: Value?) -> String? {
		correctedPathNote(pathValue?.stringValue)
	}

	private func correctedPathNote(_ requested: String?) -> String? {
		guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !requested.isEmpty,
			  requested != allowedPath else {
			return nil
		}
		return "Path corrected to '\(allowedPath)'."
	}

	private func lineEndingPairsForCurrentContent() -> [LineEndingPair] {
		if let cachedLineEndingPairs, cachedLineEndingPairs.revision == contentRevision {
			return cachedLineEndingPairs.pairs
		}
		let pairs = String.splitContentPreservingAllLineEndings(current)
		cachedLineEndingPairs = (revision: contentRevision, pairs: pairs)
		return pairs
	}

	private func searchLinesSnapshotForCurrentContent() -> (lines: [String], cacheHit: Bool) {
		if let cachedSearchLines, cachedSearchLines.revision == contentRevision {
			return (cachedSearchLines.lines, true)
		}
		let lines = current
			.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
			.map(String.init)
		cachedSearchLines = (revision: contentRevision, lines: lines)
		return (lines, false)
	}

	private func cachedSearchRegex(
		pattern: String,
		caseInsensitive: Bool,
		wholeWord: Bool
	) throws -> PCRE2Regex {
		let key = SandboxRegexCacheKey(
			pattern: pattern,
			mode: .regex,
			caseInsensitive: caseInsensitive,
			wholeWord: wholeWord
		)
		if let regex = regexCache[key] {
			return regex
		}
		let regex = try EditFlowPerf.measure(EditFlowPerf.Stage.DelegateSandbox.regexCompile) {
			try RepoPromptPCRE2Adapter.compileSearchRegexWithRepairs(
				pattern: pattern,
				caseInsensitive: caseInsensitive,
				wholeWord: wholeWord,
				multilineAnchors: false
			)
		}
		storeRegex(regex, for: key)
		return regex
	}

	private func cachedWholeWordLiteralRegex(
		pattern rawPattern: String,
		caseInsensitive: Bool
	) throws -> PCRE2Regex {
		let key = SandboxRegexCacheKey(
			pattern: rawPattern,
			mode: .wholeWordLiteral,
			caseInsensitive: caseInsensitive,
			wholeWord: true
		)
		if let regex = regexCache[key] {
			return regex
		}
		let regex = try EditFlowPerf.measure(EditFlowPerf.Stage.DelegateSandbox.regexCompile) {
			let escaped = RepoPromptPCRE2Adapter.escapedLiteral(rawPattern)
			let pattern = "\\b\(escaped)\\b"
			return try RepoPromptPCRE2Adapter.compile(RepoPromptPCRE2CompileRequest(
				pattern: pattern,
				caseInsensitive: caseInsensitive,
				multilineAnchors: false
			))
		}
		storeRegex(regex, for: key)
		return regex
	}

	private func storeRegex(_ regex: PCRE2Regex, for key: SandboxRegexCacheKey) {
		if regexCache.count >= 64 {
			regexCache.removeAll(keepingCapacity: true)
		}
		regexCache[key] = regex
	}

	private static func combineMessages(_ primary: String?, _ secondary: String?) -> String? {
		switch (primary, secondary) {
		case (nil, nil):
			return nil
		case (let first?, nil):
			return first
		case (nil, let second?):
			return second
		case (let first?, let second?):
			return "\(first) \(second)"
		}
	}

	private func encodeDTOResult<T: Encodable>(_ dto: T, toolName: String) -> CallTool.Result {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		do {
			let data = try encoder.encode(dto)
			guard let json = String(data: data, encoding: .utf8) else {
				return CallTool.Result.err("\(toolName): failed to encode response.")
			}
			return CallTool.Result(content: [.text(json)], isError: false)
		} catch {
			return CallTool.Result.err("\(toolName): failed to encode response: \(error.localizedDescription)")
		}
	}

	private static func parseInt(from value: Value?) -> Int? {
		if let intValue = value?.intValue {
			return intValue
		}
		if let str = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
			return Int(str)
		}
		return nil
	}

	// Note: Edit execution now delegated to ApplyEditsService + ApplyEditsEngine.
}
