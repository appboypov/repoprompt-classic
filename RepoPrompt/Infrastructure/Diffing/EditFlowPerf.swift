import Foundation
#if DEBUG || EDIT_FLOW_PERF
import os
#endif

/// Lightweight, gated instrumentation for apply_edits / delegate edit hot paths.
///
/// Keep this utility safe for broad use:
/// - disabled by default and cheap on the fast path;
/// - stage names are static;
/// - dimensions are coarse counts/status labels only;
/// - never pass raw paths, patterns, replacement text, file content, or diffs.
enum EditFlowPerf {
	#if DEBUG || EDIT_FLOW_PERF
	typealias IntervalState = OSSignpostIntervalState
	#else
	struct IntervalState: Sendable {}
	#endif

	struct Dimensions: Sendable {
		var toolName: String?
		var runPurpose: String?
		var status: String?
		var outcome: String?
		var fileBytes: Int?
		var lineCount: Int?
		var diffLines: Int?
		var editCount: Int?
		var matchCount: Int?
		var appliedCount: Int?
		var chunkCount: Int?
		var taskCount: Int?
		var activeCount: Int?
		var isError: Bool?
		var isForced: Bool?
		var isAgentMode: Bool?
		var includesToolCardDiff: Bool?
		var searchMode: String?
		var scanKind: String?
		var fileCount: Int?
		var batchSize: Int?
		var maxResults: Int?
		var cacheHit: Bool?
		var isRegex: Bool?
		var countOnly: Bool?
		var caseInsensitive: Bool?
		var wholeWord: Bool?
		var contextLines: Int?
		var sourceItemCount: Int?
		var sanitizedActivityCount: Int?
		var retainedPayloadCount: Int?
		var retainedPayloadBytes: Int?
		var jsonParseAttemptCount: Int?
		var jsonParseCacheHitCount: Int?
		var jsonParseCacheMissCount: Int?
		var jsonParseSuccessCount: Int?
		var jsonParseFailureCount: Int?
		var jsonParseByteCount: Int?
		var toolExecutionCacheHitCount: Int?
		var toolExecutionCacheMissCount: Int?
		var bashMetadataCacheHitCount: Int?
		var bashMetadataCacheMissCount: Int?
		var regexCaptureCallCount: Int?
		var inputBytes: Int?
		var contentItemCount: Int?
		var delegateEditCount: Int?
		var changeCount: Int?
		var scopeCount: Int?
		var warningCount: Int?
		var fileAction: String?

		init(
			toolName: String? = nil,
			runPurpose: String? = nil,
			status: String? = nil,
			outcome: String? = nil,
			fileBytes: Int? = nil,
			lineCount: Int? = nil,
			diffLines: Int? = nil,
			editCount: Int? = nil,
			matchCount: Int? = nil,
			appliedCount: Int? = nil,
			chunkCount: Int? = nil,
			taskCount: Int? = nil,
			activeCount: Int? = nil,
			isError: Bool? = nil,
			isForced: Bool? = nil,
			isAgentMode: Bool? = nil,
			includesToolCardDiff: Bool? = nil,
			searchMode: String? = nil,
			scanKind: String? = nil,
			fileCount: Int? = nil,
			batchSize: Int? = nil,
			maxResults: Int? = nil,
			cacheHit: Bool? = nil,
			isRegex: Bool? = nil,
			countOnly: Bool? = nil,
			caseInsensitive: Bool? = nil,
			wholeWord: Bool? = nil,
			contextLines: Int? = nil,
			sourceItemCount: Int? = nil,
			sanitizedActivityCount: Int? = nil,
			retainedPayloadCount: Int? = nil,
			retainedPayloadBytes: Int? = nil,
			jsonParseAttemptCount: Int? = nil,
			jsonParseCacheHitCount: Int? = nil,
			jsonParseCacheMissCount: Int? = nil,
			jsonParseSuccessCount: Int? = nil,
			jsonParseFailureCount: Int? = nil,
			jsonParseByteCount: Int? = nil,
			toolExecutionCacheHitCount: Int? = nil,
			toolExecutionCacheMissCount: Int? = nil,
			bashMetadataCacheHitCount: Int? = nil,
			bashMetadataCacheMissCount: Int? = nil,
			regexCaptureCallCount: Int? = nil,
			inputBytes: Int? = nil,
			contentItemCount: Int? = nil,
			delegateEditCount: Int? = nil,
			changeCount: Int? = nil,
			scopeCount: Int? = nil,
			warningCount: Int? = nil,
			fileAction: String? = nil
		) {
			self.toolName = Self.sanitizedLabel(toolName)
			self.runPurpose = Self.sanitizedLabel(runPurpose)
			self.status = Self.sanitizedLabel(status)
			self.outcome = Self.sanitizedLabel(outcome)
			self.fileBytes = Self.nonNegative(fileBytes)
			self.lineCount = Self.nonNegative(lineCount)
			self.diffLines = Self.nonNegative(diffLines)
			self.editCount = Self.nonNegative(editCount)
			self.matchCount = Self.nonNegative(matchCount)
			self.appliedCount = Self.nonNegative(appliedCount)
			self.chunkCount = Self.nonNegative(chunkCount)
			self.taskCount = Self.nonNegative(taskCount)
			self.activeCount = Self.nonNegative(activeCount)
			self.isError = isError
			self.isForced = isForced
			self.isAgentMode = isAgentMode
			self.includesToolCardDiff = includesToolCardDiff
			self.searchMode = Self.sanitizedLabel(searchMode)
			self.scanKind = Self.sanitizedLabel(scanKind)
			self.fileCount = Self.nonNegative(fileCount)
			self.batchSize = Self.nonNegative(batchSize)
			self.maxResults = Self.nonNegative(maxResults)
			self.cacheHit = cacheHit
			self.isRegex = isRegex
			self.countOnly = countOnly
			self.caseInsensitive = caseInsensitive
			self.wholeWord = wholeWord
			self.contextLines = Self.nonNegative(contextLines)
			self.sourceItemCount = Self.nonNegative(sourceItemCount)
			self.sanitizedActivityCount = Self.nonNegative(sanitizedActivityCount)
			self.retainedPayloadCount = Self.nonNegative(retainedPayloadCount)
			self.retainedPayloadBytes = Self.nonNegative(retainedPayloadBytes)
			self.jsonParseAttemptCount = Self.nonNegative(jsonParseAttemptCount)
			self.jsonParseCacheHitCount = Self.nonNegative(jsonParseCacheHitCount)
			self.jsonParseCacheMissCount = Self.nonNegative(jsonParseCacheMissCount)
			self.jsonParseSuccessCount = Self.nonNegative(jsonParseSuccessCount)
			self.jsonParseFailureCount = Self.nonNegative(jsonParseFailureCount)
			self.jsonParseByteCount = Self.nonNegative(jsonParseByteCount)
			self.toolExecutionCacheHitCount = Self.nonNegative(toolExecutionCacheHitCount)
			self.toolExecutionCacheMissCount = Self.nonNegative(toolExecutionCacheMissCount)
			self.bashMetadataCacheHitCount = Self.nonNegative(bashMetadataCacheHitCount)
			self.bashMetadataCacheMissCount = Self.nonNegative(bashMetadataCacheMissCount)
			self.regexCaptureCallCount = Self.nonNegative(regexCaptureCallCount)
			self.inputBytes = Self.nonNegative(inputBytes)
			self.contentItemCount = Self.nonNegative(contentItemCount)
			self.delegateEditCount = Self.nonNegative(delegateEditCount)
			self.changeCount = Self.nonNegative(changeCount)
			self.scopeCount = Self.nonNegative(scopeCount)
			self.warningCount = Self.nonNegative(warningCount)
			self.fileAction = Self.sanitizedLabel(fileAction)
		}

		fileprivate var logDescription: String {
			var parts: [String] = []
			append("tool", toolName, to: &parts)
			append("purpose", runPurpose, to: &parts)
			append("status", status, to: &parts)
			append("outcome", outcome, to: &parts)
			append("fileBytes", fileBytes, to: &parts)
			append("lineCount", lineCount, to: &parts)
			append("diffLines", diffLines, to: &parts)
			append("editCount", editCount, to: &parts)
			append("matchCount", matchCount, to: &parts)
			append("appliedCount", appliedCount, to: &parts)
			append("chunkCount", chunkCount, to: &parts)
			append("taskCount", taskCount, to: &parts)
			append("activeCount", activeCount, to: &parts)
			append("isError", isError, to: &parts)
			append("isForced", isForced, to: &parts)
			append("isAgentMode", isAgentMode, to: &parts)
			append("includesToolCardDiff", includesToolCardDiff, to: &parts)
			append("searchMode", searchMode, to: &parts)
			append("scanKind", scanKind, to: &parts)
			append("fileCount", fileCount, to: &parts)
			append("batchSize", batchSize, to: &parts)
			append("maxResults", maxResults, to: &parts)
			append("cacheHit", cacheHit, to: &parts)
			append("isRegex", isRegex, to: &parts)
			append("countOnly", countOnly, to: &parts)
			append("caseInsensitive", caseInsensitive, to: &parts)
			append("wholeWord", wholeWord, to: &parts)
			append("contextLines", contextLines, to: &parts)
			append("sourceItemCount", sourceItemCount, to: &parts)
			append("sanitizedActivityCount", sanitizedActivityCount, to: &parts)
			append("retainedPayloadCount", retainedPayloadCount, to: &parts)
			append("retainedPayloadBytes", retainedPayloadBytes, to: &parts)
			append("jsonParseAttemptCount", jsonParseAttemptCount, to: &parts)
			append("jsonParseCacheHitCount", jsonParseCacheHitCount, to: &parts)
			append("jsonParseCacheMissCount", jsonParseCacheMissCount, to: &parts)
			append("jsonParseSuccessCount", jsonParseSuccessCount, to: &parts)
			append("jsonParseFailureCount", jsonParseFailureCount, to: &parts)
			append("jsonParseByteCount", jsonParseByteCount, to: &parts)
			append("toolExecutionCacheHitCount", toolExecutionCacheHitCount, to: &parts)
			append("toolExecutionCacheMissCount", toolExecutionCacheMissCount, to: &parts)
			append("bashMetadataCacheHitCount", bashMetadataCacheHitCount, to: &parts)
			append("bashMetadataCacheMissCount", bashMetadataCacheMissCount, to: &parts)
			append("regexCaptureCallCount", regexCaptureCallCount, to: &parts)
			append("inputBytes", inputBytes, to: &parts)
			append("contentItemCount", contentItemCount, to: &parts)
			append("delegateEditCount", delegateEditCount, to: &parts)
			append("changeCount", changeCount, to: &parts)
			append("scopeCount", scopeCount, to: &parts)
			append("warningCount", warningCount, to: &parts)
			append("fileAction", fileAction, to: &parts)
			return parts.joined(separator: " ")
		}

		fileprivate var isEmpty: Bool {
			logDescription.isEmpty
		}

		private static func nonNegative(_ value: Int?) -> Int? {
			value.map { max(0, $0) }
		}

		private static func sanitizedLabel(_ value: String?) -> String? {
			guard let value else { return nil }
			let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { return nil }
			let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
			let replacement = UnicodeScalar("_")
			let scalars = trimmed.unicodeScalars.map { scalar in
				allowed.contains(scalar) ? scalar : replacement
			}
			return String(String.UnicodeScalarView(scalars.prefix(64)))
		}

		private func append(_ key: String, _ value: String?, to parts: inout [String]) {
			guard let value else { return }
			parts.append("\(key)=\(value)")
		}

		private func append(_ key: String, _ value: Int?, to parts: inout [String]) {
			guard let value else { return }
			parts.append("\(key)=\(value)")
		}

		private func append(_ key: String, _ value: Bool?, to parts: inout [String]) {
			guard let value else { return }
			parts.append("\(key)=\(value ? "true" : "false")")
		}
	}

	enum Stage {
		enum MCPToolCall {
			static let total: StaticString = "EditFlow.MCPToolCall.Total"
			static let normalizeArgs: StaticString = "EditFlow.MCPToolCall.NormalizeArgs"
			static let delegateSandboxIntercept: StaticString = "EditFlow.MCPToolCall.DelegateSandboxIntercept"
			static let logicalContextResolution: StaticString = "EditFlow.MCPToolCall.LogicalContextResolution"
			static let policyGating: StaticString = "EditFlow.MCPToolCall.PolicyGating"
			static let observerCallbacks: StaticString = "EditFlow.MCPToolCall.ObserverCallbacks"
			static let dispatch: StaticString = "EditFlow.MCPToolCall.Dispatch"
		}

		enum ApplyEdits {
			static let serviceRun: StaticString = "EditFlow.ApplyEdits.ServiceRun"
			static let servicePreview: StaticString = "EditFlow.ApplyEdits.ServicePreview"
			static let requestBuild: StaticString = "EditFlow.ApplyEdits.RequestBuild"
			static let hostRead: StaticString = "EditFlow.ApplyEdits.HostRead"
			static let hostWrite: StaticString = "EditFlow.ApplyEdits.HostWrite"
			static let engineApply: StaticString = "EditFlow.ApplyEdits.EngineApply"
			static let diffGeneration: StaticString = "EditFlow.ApplyEdits.DiffGeneration"
			static let patchApply: StaticString = "EditFlow.ApplyEdits.PatchApply"
			static let toolCardDiff: StaticString = "EditFlow.ApplyEdits.ToolCardDiff"
			static let format: StaticString = "EditFlow.ApplyEdits.Format"
			static let formatDecode: StaticString = "EditFlow.ApplyEdits.FormatDecode"
			static let formatMarkdown: StaticString = "EditFlow.ApplyEdits.FormatMarkdown"
			static let formatResource: StaticString = "EditFlow.ApplyEdits.FormatResource"
			static let approvalWait: StaticString = "EditFlow.ApplyEdits.ApprovalWait"
			static let flushDeltas: StaticString = "EditFlow.ApplyEdits.FlushDeltas"
		}

		enum Search {
			static let entrypoint: StaticString = "EditFlow.Search.Entrypoint"
			static let scopeFiltering: StaticString = "EditFlow.Search.ScopeFiltering"
			static let actorSearchCall: StaticString = "EditFlow.Search.ActorSearchCall"
			static let actorSearchUnified: StaticString = "EditFlow.Search.ActorSearchUnified"
			static let contentBatch: StaticString = "EditFlow.Search.ContentBatch"
			static let pathBatch: StaticString = "EditFlow.Search.PathBatch"
			static let fileContentFetch: StaticString = "EditFlow.Search.FileContentFetch"
			static let lineIndexCacheKey: StaticString = "EditFlow.Search.LineIndexCacheKey"
			static let lineIndexLookup: StaticString = "EditFlow.Search.LineIndexLookup"
			static let lineIndexBuild: StaticString = "EditFlow.Search.LineIndexBuild"
			static let countOnlyFastPath: StaticString = "EditFlow.Search.CountOnlyFastPath"
			static let regexFullBufferScan: StaticString = "EditFlow.Search.RegexFullBufferScan"
			static let regexLineByLineScan: StaticString = "EditFlow.Search.RegexLineByLineScan"
			static let literalScan: StaticString = "EditFlow.Search.LiteralScan"
			static let materializeMatches: StaticString = "EditFlow.Search.MaterializeMatches"
		}

		enum Transcript {
			static let scheduleRefresh: StaticString = "EditFlow.Transcript.ScheduleRefresh"
			static let refreshTotal: StaticString = "EditFlow.Transcript.RefreshTotal"
			static let importTranscript: StaticString = "EditFlow.Transcript.ImportTranscript"
			static let incrementalImport: StaticString = "EditFlow.Transcript.IncrementalImport"
			static let payloadMap: StaticString = "EditFlow.Transcript.PayloadMap"
			static let sanitize: StaticString = "EditFlow.Transcript.Sanitize"
			static let projectionBuild: StaticString = "EditFlow.Transcript.ProjectionBuild"
			static let publish: StaticString = "EditFlow.Transcript.Publish"
			static let toolProcessing: StaticString = "EditFlow.Transcript.ToolProcessing"
		}

		enum Parser {
			static let chatContentParse: StaticString = "EditFlow.Parser.ChatContentParse"
			static let chatDelegateEditParse: StaticString = "EditFlow.Parser.ChatDelegateEditParse"
			static let diffParseChanges: StaticString = "EditFlow.Parser.DiffParseChanges"
			static let diffRegexCacheLookup: StaticString = "EditFlow.Parser.DiffRegexCacheLookup"
		}

		enum DelegateSandbox {
			static let readFile: StaticString = "EditFlow.DelegateSandbox.ReadFile"
			static let fileSearch: StaticString = "EditFlow.DelegateSandbox.FileSearch"
			static let applyEdits: StaticString = "EditFlow.DelegateSandbox.ApplyEdits"
			static let regexCompile: StaticString = "EditFlow.DelegateSandbox.RegexCompile"
		}

		enum Delegate {
			static let runForFile: StaticString = "EditFlow.Delegate.RunForFile"
			static let taskSpawn: StaticString = "EditFlow.Delegate.TaskSpawn"
			static let taskDuplicateSkip: StaticString = "EditFlow.Delegate.TaskDuplicateSkip"
			static let watchdogArm: StaticString = "EditFlow.Delegate.WatchdogArm"
			static let watchdogSkip: StaticString = "EditFlow.Delegate.WatchdogSkip"
			static let watchdogCancel: StaticString = "EditFlow.Delegate.WatchdogCancel"
			static let watchdogComplete: StaticString = "EditFlow.Delegate.WatchdogComplete"
			static let observerRegister: StaticString = "EditFlow.Delegate.ObserverRegister"
			static let observerUnregister: StaticString = "EditFlow.Delegate.ObserverUnregister"
		}

		enum UnifiedDiff {
			static let parseForRender: StaticString = "EditFlow.UnifiedDiff.ParseForRender"
			static let attributedBuild: StaticString = "EditFlow.UnifiedDiff.AttributedBuild"
		}

		enum Git {
			static let hunkParsing: StaticString = "EditFlow.Git.HunkParsing"
		}
	}

	#if DEBUG || EDIT_FLOW_PERF
	private static let signposter = OSSignposter(subsystem: "com.repoprompt.edit-flow", category: "perf")
	private static let logger = Logger(subsystem: "com.repoprompt.edit-flow", category: "perf")
	private static let environmentEnabled: Bool = {
		guard let raw = ProcessInfo.processInfo.environment["REPOPROMPT_EDIT_FLOW_PERF"] else {
			return false
		}
		let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		return ["1", "true", "yes", "y", "on"].contains(value)
	}()

	static var isEnabled: Bool {
		environmentEnabled || UserDefaults.standard.bool(forKey: "editFlowPerfEnabled")
	}

	@discardableResult
	static func begin(_ name: StaticString) -> IntervalState? {
		guard isEnabled else { return nil }
		return signposter.beginInterval(name)
	}

	@discardableResult
	static func begin(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) -> IntervalState? {
		guard isEnabled else { return nil }
		logDimensions(dimensions())
		return signposter.beginInterval(name)
	}

	static func end(_ name: StaticString, _ state: IntervalState?) {
		guard let state else { return }
		signposter.endInterval(name, state)
	}

	static func end(_ name: StaticString, _ state: IntervalState?, _ dimensions: @autoclosure () -> Dimensions) {
		guard let state else { return }
		if isEnabled {
			logDimensions(dimensions())
		}
		signposter.endInterval(name, state)
	}

	static func event(_ name: StaticString) {
		guard isEnabled else { return }
		signposter.emitEvent(name)
	}

	static func event(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) {
		guard isEnabled else { return }
		logDimensions(dimensions())
		signposter.emitEvent(name)
	}

	static func measure<T>(
		_ name: StaticString,
		operation: () throws -> T
	) rethrows -> T {
		let state = begin(name)
		defer { end(name, state) }
		return try operation()
	}

	static func measure<T>(
		_ name: StaticString,
		_ dimensions: @autoclosure () -> Dimensions,
		operation: () throws -> T
	) rethrows -> T {
		let state = begin(name, dimensions())
		defer { end(name, state) }
		return try operation()
	}

	static func measure<T>(
		_ name: StaticString,
		operation: () async throws -> T
	) async rethrows -> T {
		let state = begin(name)
		defer { end(name, state) }
		return try await operation()
	}

	static func measure<T>(
		_ name: StaticString,
		_ dimensions: @autoclosure () -> Dimensions,
		operation: () async throws -> T
	) async rethrows -> T {
		let state = begin(name, dimensions())
		defer { end(name, state) }
		return try await operation()
	}

	private static func logDimensions(_ dimensions: Dimensions) {
		guard !dimensions.isEmpty else { return }
		logger.debug("dimensions \(dimensions.logDescription, privacy: .public)")
	}
	#else
	static var isEnabled: Bool { false }

	@discardableResult
	@inline(__always)
	static func begin(_ name: StaticString) -> IntervalState? {
		nil
	}

	@discardableResult
	@inline(__always)
	static func begin(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) -> IntervalState? {
		nil
	}

	@inline(__always)
	static func end(_ name: StaticString, _ state: IntervalState?) {}

	@inline(__always)
	static func end(_ name: StaticString, _ state: IntervalState?, _ dimensions: @autoclosure () -> Dimensions) {}

	@inline(__always)
	static func event(_ name: StaticString) {}

	@inline(__always)
	static func event(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) {}

	@inline(__always)
	static func measure<T>(
		_ name: StaticString,
		operation: () throws -> T
	) rethrows -> T {
		try operation()
	}

	@inline(__always)
	static func measure<T>(
		_ name: StaticString,
		_ dimensions: @autoclosure () -> Dimensions,
		operation: () throws -> T
	) rethrows -> T {
		try operation()
	}

	@inline(__always)
	static func measure<T>(
		_ name: StaticString,
		operation: () async throws -> T
	) async rethrows -> T {
		try await operation()
	}

	@inline(__always)
	static func measure<T>(
		_ name: StaticString,
		_ dimensions: @autoclosure () -> Dimensions,
		operation: () async throws -> T
	) async rethrows -> T {
		try await operation()
	}
	#endif
}
