import Foundation

#if DEBUG

enum MCPFileSearchPerfDiagnostics {
	private static let defaultsKey = "enableMCPFileSearchPerfDiagnostics"
	private static let environmentKey = "REPOPROMPT_MCP_FILE_SEARCH_PERF"
	private static let enabledEnvironmentValues: Set<String> = ["1", "true", "yes", "on"]
	private static let bufferLimit = 2_000
	private static let lock = NSLock()
	private static var processOverrideEnabled: Bool?
	private static var activeRuns: [UUID: RunMetric] = [:]
	private static var recentRuns: [RunMetric] = []

	struct RunMetric: Codable, Equatable, Sendable {
		let runID: UUID
		var label: String?
		var totalMS: Double?
		var parseArgsMS: Double?
		var fileManagerSearchMS: Double?
		var scopeFilteringMS: Double?
		var actorSearchMS: Double?
		var responseFormattingMS: Double?
		var responseJSONBytes: Int?
		var allFileCount: Int?
		var scopedFileCount: Int?
		var searchedFileCount: Int?
		var pathFilterCount: Int?
		var pathClauseCount: Int?
		var pathFilterVisitedCount: Int?
		var pathFilterMatchedCount: Int?
		var pathMatches: Int?
		var contentMatches: Int?
		var totalMatches: Int?
		var scopeFilterCancelled: Bool
		var cancellationReason: String?
		var correctnessMismatch: Bool?
		fileprivate var startMS: Double
	}

	static var isEnabled: Bool {
		if let processOverrideEnabled {
			return processOverrideEnabled
		}
		return UserDefaults.standard.bool(forKey: defaultsKey) || environmentFlagEnabled(environmentKey)
	}

	static func setProcessOverrideEnabled(_ enabled: Bool?) {
		lock.lock()
		processOverrideEnabled = enabled
		lock.unlock()
	}

	static func clear() {
		lock.lock()
		activeRuns.removeAll()
		recentRuns.removeAll()
		lock.unlock()
	}

	static func beginRun(label: String?) -> UUID? {
		guard isEnabled else { return nil }
		let runID = UUID()
		let metric = RunMetric(
			runID: runID,
			label: sanitizedLabel(label),
			totalMS: nil,
			parseArgsMS: nil,
			fileManagerSearchMS: nil,
			scopeFilteringMS: nil,
			actorSearchMS: nil,
			responseFormattingMS: nil,
			responseJSONBytes: nil,
			allFileCount: nil,
			scopedFileCount: nil,
			searchedFileCount: nil,
			pathFilterCount: nil,
			pathClauseCount: nil,
			pathFilterVisitedCount: nil,
			pathFilterMatchedCount: nil,
			pathMatches: nil,
			contentMatches: nil,
			totalMatches: nil,
			scopeFilterCancelled: false,
			cancellationReason: nil,
			correctnessMismatch: nil,
			startMS: timestampMS()
		)
		lock.lock()
		activeRuns[runID] = metric
		lock.unlock()
		return runID
	}

	static func recordParseArgs(runID: UUID?, durationMS: Double) {
		update(runID) { $0.parseArgsMS = durationMS }
	}

	static func recordFileManagerSearch(runID: UUID?, durationMS: Double) {
		update(runID) { $0.fileManagerSearchMS = durationMS }
	}

	static func recordSearchInputs(
		runID: UUID?,
		allFileCount: Int,
		pathFilterCount: Int,
		pathClauseCount: Int
	) {
		update(runID) { metric in
			metric.allFileCount = allFileCount
			metric.pathFilterCount = pathFilterCount
			metric.pathClauseCount = pathClauseCount
		}
	}

	static func recordScopeFiltering(
		runID: UUID?,
		durationMS: Double,
		visitedSnapshotCount: Int,
		matchedCount: Int,
		cancelled: Bool,
		cancellationReason: String? = nil
	) {
		update(runID) { metric in
			metric.scopeFilteringMS = durationMS
			metric.pathFilterVisitedCount = visitedSnapshotCount
			metric.pathFilterMatchedCount = matchedCount
			metric.scopeFilterCancelled = cancelled
			metric.cancellationReason = cancellationReason
		}
	}

	static func recordActorSearch(
		runID: UUID?,
		durationMS: Double,
		scopedFileCount: Int,
		searchedFileCount: Int?,
		pathMatches: Int,
		contentMatches: Int,
		totalMatches: Int
	) {
		update(runID) { metric in
			metric.actorSearchMS = durationMS
			metric.scopedFileCount = scopedFileCount
			metric.searchedFileCount = searchedFileCount
			metric.pathMatches = pathMatches
			metric.contentMatches = contentMatches
			metric.totalMatches = totalMatches
		}
	}

	static func recordResponseFormatting(
		runID: UUID?,
		durationMS: Double,
		responseJSONBytes: Int?,
		pathMatches: Int,
		contentMatches: Int,
		totalMatches: Int
	) {
		update(runID) { metric in
			metric.responseFormattingMS = durationMS
			metric.responseJSONBytes = responseJSONBytes
			metric.pathMatches = pathMatches
			metric.contentMatches = contentMatches
			metric.totalMatches = totalMatches
		}
	}

	static func finishRun(runID: UUID?, responseJSONBytes: Int? = nil, correctnessMismatch: Bool? = nil) {
		guard let runID else { return }
		lock.lock()
		guard var metric = activeRuns.removeValue(forKey: runID) else {
			lock.unlock()
			return
		}
		metric.totalMS = timestampMS() - metric.startMS
		if let responseJSONBytes {
			metric.responseJSONBytes = responseJSONBytes
		}
		if let correctnessMismatch {
			metric.correctnessMismatch = correctnessMismatch
		}
		recentRuns.append(metric)
		if recentRuns.count > bufferLimit {
			recentRuns.removeFirst(recentRuns.count - bufferLimit)
		}
		lock.unlock()
	}

	static func recentRunMetrics() -> [RunMetric] {
		lock.lock()
		let runs = recentRuns
		lock.unlock()
		return runs
	}

	static func timestampMS() -> Double {
		CFAbsoluteTimeGetCurrent() * 1_000
	}

	static func elapsedMS(since startMS: Double) -> Double {
		timestampMS() - startMS
	}

	private static func update(_ runID: UUID?, _ mutate: (inout RunMetric) -> Void) {
		guard let runID else { return }
		lock.lock()
		if var metric = activeRuns[runID] {
			mutate(&metric)
			activeRuns[runID] = metric
		}
		lock.unlock()
	}

	private static func environmentFlagEnabled(_ name: String) -> Bool {
		guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
			!value.isEmpty else {
			return false
		}
		return enabledEnvironmentValues.contains(value)
	}

	private static func sanitizedLabel(_ label: String?) -> String? {
		guard let label else { return nil }
		let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
		let sanitizedScalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
		return String(sanitizedScalars).prefix(96).description
	}
}

#endif
