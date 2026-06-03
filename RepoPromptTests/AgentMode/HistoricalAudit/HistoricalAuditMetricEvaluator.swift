import Foundation
@testable import RepoPrompt

struct HistoricalMetricSnapshot: Equatable {
	let values: [String: Int]

	subscript(_ metricName: String) -> Int {
		values[metricName] ?? 0
	}

	func reports(_ metricName: String) -> Bool {
		values.keys.contains(metricName)
	}
}

struct HistoricalMetricReport {
	let caseID: String
	let rawFixture: HistoricalMetricSnapshot
	let normalizedModel: HistoricalMetricSnapshot
	let projection: HistoricalMetricSnapshot
	let export: HistoricalMetricSnapshot
	let persistedStorage: HistoricalMetricSnapshot

	func reports(_ metricName: String) -> Bool {
		rawFixture.reports(metricName)
			&& normalizedModel.reports(metricName)
			&& projection.reports(metricName)
			&& export.reports(metricName)
			&& persistedStorage.reports(metricName)
	}
}

enum HistoricalAuditMetricEvaluator {
	static let supportedMetricNames: Set<String> = [
		"activityGhostAssistantCount",
		"assistantMicroNoiseCount",
		"displaylessConclusionCount",
		"duplicateInvocationIDGroupCount",
		"duplicatedTextResultJSONChars",
		"exportGhostAssistantCount",
		"lowSubstantiveFinalAnswerCount",
		"maxPersistedToolSummaryBytes",
		"maxToolPayloadChars",
		"missingConclusionWithAssistantCount",
		"orphanToolResultCount",
		"pathLikeToolNameCount",
		"pathLikeToolNameVisibleCount",
		"pendingToolAfterTerminalCount",
		"pendingToolCount",
		"persistedRawBashOutputCount",
		"persistedRawFileSearchCount",
		"persistedRawReadFileCount",
		"persistedRawToolPayloadCount",
		"persistedThinkingRowCount",
		"placeholderToolCount",
		"placeholderVisibleBlockCount",
		"projectedGhostAssistantCount",
		"resultOverwriteCorruptionCount",
		"sessionFileBytes",
		"sourceByteCount",
		"sourceGhostAssistantCount",
		"sourceThinkingRowCount",
		"staleConclusionCount",
		"staleToolCallWithoutResultCount",
		"thinkingPayloadChars",
		"unresolvedToolCallCount",

		// Historical manifest diagnostic aliases. These are filled from the same
		// evaluator formulas when possible and kept as reportable keys so manifest
		// additions fail loudly only when a genuinely new metric appears.
		"duplicatedTextResultJSONCharsOriginal",
		"maxToolPayloadCharsOriginal",
		"sessionFileBytesOriginal",
		"sourceThinkingRowCountOriginal"
	]

	static func expectedMetricNames(in manifest: HistoricalAuditManifest) -> Set<String> {
		Set(manifest.cases.flatMap { auditCase in
			Array((auditCase.expectedMetricsAfterFix ?? [:]).keys)
		})
	}

	static func allManifestMetricNames(in manifest: HistoricalAuditManifest) -> Set<String> {
		Set(manifest.cases.flatMap { auditCase in
			Array((auditCase.expectedMetricsAfterFix ?? [:]).keys)
				+ Array((auditCase.expectedMetricsCurrent ?? [:]).keys)
				+ Array((auditCase.sourceOriginalMetrics ?? [:]).keys)
		})
	}

	static func report(
		caseID: String,
		rawSession: AgentSession,
		normalizedSession: AgentSession? = nil,
		persistedData: Data? = nil,
		rawData: Data? = nil
	) -> HistoricalMetricReport {
		let modelSession = normalizedSession ?? rawSession
		let persistedSession = persistedData.flatMap { try? JSONDecoder().decode(AgentSession.self, from: $0) } ?? modelSession
		return HistoricalMetricReport(
			caseID: caseID,
			rawFixture: sessionSnapshot(for: rawSession, data: rawData ?? persistedData),
			normalizedModel: sessionSnapshot(for: modelSession, data: nil),
			projection: projectionSnapshot(for: modelSession),
			export: exportSnapshot(for: modelSession),
			persistedStorage: sessionSnapshot(for: persistedSession, data: persistedData)
		)
	}

	// MARK: - Snapshot builders

	private static func sessionSnapshot(for session: AgentSession, data: Data?) -> HistoricalMetricSnapshot {
		var values = emptyValues()
		let sourceItems = sourceRows(in: session)
		let activities = transcript(for: session)?.allActivities ?? []
		let records = toolRecords(in: session)
		let terminalRecords = records.filter(\.isTerminalScope)
		let assistantRows = sourceItems.filter(isAssistantRow)

		values["sourceGhostAssistantCount"] = assistantRows.filter { !AgentDisplayableText.hasDisplayableBody($0.text) }.count
		values["activityGhostAssistantCount"] = activities.filter { isAssistantKind($0.itemKind) && !AgentDisplayableText.hasDisplayableBody($0.text) }.count
		values["assistantMicroNoiseCount"] = assistantRows.filter { isAssistantMicroNoise($0.text) }.count
		values["sourceThinkingRowCount"] = sourceItems.filter { $0.kind == .thinking }.count
		values["sourceThinkingRowCountOriginal"] = values["sourceThinkingRowCount"]
		values["persistedThinkingRowCount"] = sourceItems.filter { $0.kind == .thinking }.count
		values["thinkingPayloadChars"] = sourceItems.filter { $0.kind == .thinking }.reduce(0) { $0 + utf8Count($1.text) }

		values["pendingToolCount"] = records.filter { $0.status == .pending || $0.status == .running || $0.kind == .toolCall }.count
		values["pendingToolAfterTerminalCount"] = terminalRecords.filter { $0.kind == .toolCall || $0.status == .pending || $0.status == .running }.count
		values["unresolvedToolCallCount"] = terminalRecords.filter { $0.kind == .toolCall || $0.status == .pending || $0.status == .running }.count
		values["staleToolCallWithoutResultCount"] = staleToolCount(in: terminalRecords)
		values["duplicateInvocationIDGroupCount"] = duplicateInvocationGroupCount(in: records)
		values["resultOverwriteCorruptionCount"] = resultOverwriteCorruptionCount(in: records)
		values["orphanToolResultCount"] = orphanToolResultCount(in: records)

		values["placeholderToolCount"] = records.filter { isPlaceholderToolName($0.toolName) }.count
		values["placeholderVisibleBlockCount"] = records.filter { isPlaceholderToolName($0.toolName) && isSummaryOnlyOrEmpty($0) }.count
		values["pathLikeToolNameCount"] = records.filter { isPathLikeToolName($0.toolName) }.count
		values["pathLikeToolNameVisibleCount"] = values["pathLikeToolNameCount"]

		let payloadStats = payloadStats(for: records)
		values["maxPersistedToolSummaryBytes"] = payloadStats.maxPayloadChars
		values["maxToolPayloadChars"] = payloadStats.maxPayloadChars
		values["maxToolPayloadCharsOriginal"] = payloadStats.maxPayloadChars
		values["duplicatedTextResultJSONChars"] = payloadStats.duplicatedTextResultJSONChars
		values["duplicatedTextResultJSONCharsOriginal"] = payloadStats.duplicatedTextResultJSONChars
		values["persistedRawReadFileCount"] = rawPayloadCount(in: records, canonicalToolName: "read_file")
		values["persistedRawFileSearchCount"] = rawPayloadCount(in: records, canonicalToolName: "file_search")
		values["persistedRawBashOutputCount"] = rawPayloadCount(in: records, canonicalToolName: "bash")
		values["persistedRawToolPayloadCount"] = (values["persistedRawReadFileCount"] ?? 0)
			+ (values["persistedRawFileSearchCount"] ?? 0)
			+ (values["persistedRawBashOutputCount"] ?? 0)

		values["displaylessConclusionCount"] = displaylessConclusionCount(in: session)
		values["staleConclusionCount"] = staleConclusionCount(in: session)
		values["missingConclusionWithAssistantCount"] = missingConclusionWithAssistantCount(in: session)
		values["lowSubstantiveFinalAnswerCount"] = lowSubstantiveFinalAnswerCount(in: session)

		if let data {
			values["sourceByteCount"] = data.count
			values["sessionFileBytes"] = data.count
			values["sessionFileBytesOriginal"] = data.count
		}

		return HistoricalMetricSnapshot(values: values)
	}

	private static func projectionSnapshot(for session: AgentSession) -> HistoricalMetricSnapshot {
		var values = sessionSnapshot(for: session, data: nil).values
		guard let transcript = transcript(for: session) else {
			return HistoricalMetricSnapshot(values: values)
		}
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let rows = projection.archivedRows + projection.workingRows
		let blocks = projection.archivedBlocks + projection.workingBlocks

		values["projectedGhostAssistantCount"] = rows.filter { isAssistantRow($0) && !AgentDisplayableText.hasDisplayableBody($0.text) }.count
		values["assistantMicroNoiseCount"] = rows.filter { isAssistantRow($0) && isAssistantMicroNoise($0.text) }.count
		values["placeholderVisibleBlockCount"] = blocks.filter { block in
			block.rows.contains { row in
				isToolRow(row) && isPlaceholderToolName(row.toolName) && isSummaryOnlyOrEmpty(row)
			}
		}.count
		values["pathLikeToolNameVisibleCount"] = rows.filter { isToolRow($0) && isPathLikeToolName($0.toolName) }.count
		values["displaylessConclusionCount"] = rows.filter { isAssistantRow($0) && !AgentDisplayableText.hasDisplayableBody($0.text) }.count
		return HistoricalMetricSnapshot(values: values)
	}

	private static func exportSnapshot(for session: AgentSession) -> HistoricalMetricSnapshot {
		var values = sessionSnapshot(for: session, data: nil).values
		guard let transcript = transcript(for: session) else {
			return HistoricalMetricSnapshot(values: values)
		}
		let conversationHistory = AgentTranscriptIO.buildConversationHistory(from: transcript)
		let forkXML = AgentTranscriptIO.buildForkTranscriptXML(from: transcript)
		let exportedAssistantBodies = assistantTagBodies(in: conversationHistory) + assistantTagBodies(in: forkXML)
		let exportedToolNames = toolTagNames(in: conversationHistory) + toolTagNames(in: forkXML)
		values["exportGhostAssistantCount"] = exportedAssistantBodies.filter { !AgentDisplayableText.hasDisplayableBody($0) }.count
		values["assistantMicroNoiseCount"] = exportedAssistantBodies.filter(isAssistantMicroNoise).count
		values["lowSubstantiveFinalAnswerCount"] = exportedAssistantBodies.suffix(1).filter(isLowSubstantiveFinalAnswer).count
		values["placeholderVisibleBlockCount"] = exportedToolNames.filter(isPlaceholderToolName).count
		values["pathLikeToolNameVisibleCount"] = exportedToolNames.filter(isPathLikeToolName).count
		return HistoricalMetricSnapshot(values: values)
	}

	private static func emptyValues() -> [String: Int] {
		Dictionary(uniqueKeysWithValues: supportedMetricNames.map { ($0, 0) })
	}

	// MARK: - Transcript traversal

	private static func transcript(for session: AgentSession) -> AgentTranscript? {
		if let transcript = session.transcript {
			return transcript
		}
		let items = session.items.map { $0.toItem() }
		guard !items.isEmpty else { return nil }
		return AgentTranscriptIO.buildTranscript(
			from: items,
			terminalState: session.lastRunState.flatMap(AgentSessionRunState.init(rawValue:)),
			nextSequenceIndex: (items.map(\.sequenceIndex).max() ?? -1) + 1,
			policy: .canonical,
			compact: false
		)
	}

	private static func sourceRows(in session: AgentSession) -> [AgentChatItem] {
		let itemRows = session.items.map { $0.toItem() }
		if !itemRows.isEmpty {
			return itemRows
		}
		return transcript(for: session)?.allActivities.map { $0.toItem() } ?? []
	}

	private static func toolRecords(in session: AgentSession) -> [ToolRecord] {
		if let transcript = transcript(for: session) {
			let sessionTerminal = isTerminal(session.lastRunState.flatMap(AgentSessionRunState.init(rawValue:)))
			return transcript.turns.flatMap { turn in
				let turnTerminal = sessionTerminal
				return turn.responseSpans.flatMap { span in
					span.activities.compactMap { activity in
						ToolRecord(activity: activity, turnID: turn.id, isTerminalScope: turnTerminal)
					}
				}
			}
		}
		let terminal = isTerminal(session.lastRunState.flatMap(AgentSessionRunState.init(rawValue:)))
		return session.items.compactMap { ToolRecord(item: $0.toItem(), turnID: nil, isTerminalScope: terminal) }
	}

	private static func isTerminal(_ state: AgentSessionRunState?) -> Bool {
		guard let state else { return false }
		return !state.isActive && state != .idle
	}

	// MARK: - Metric formulas

	private static func staleToolCount(in terminalRecords: [ToolRecord]) -> Int {
		terminalRecords.filter { record in
			record.kind == .toolCall || record.status == .pending || record.status == .running
		}.count
	}

	private static func duplicateInvocationGroupCount(in records: [ToolRecord]) -> Int {
		let grouped = Dictionary(grouping: records.compactMap { record -> (UUID, ToolRecord)? in
			guard let invocationID = record.invocationID else { return nil }
			return (invocationID, record)
		}, by: { $0.0 })
		return grouped.values.filter { group in
			let executionSignatures = Set(group.map { duplicateExecutionSignature(for: $0.1) })
			return executionSignatures.count > 1
		}.count
	}

	private static func resultOverwriteCorruptionCount(in records: [ToolRecord]) -> Int {
		let grouped = Dictionary(grouping: records.compactMap { record -> (UUID, ToolRecord)? in
			guard let invocationID = record.invocationID, record.kind == .toolResult else { return nil }
			return (invocationID, record)
		}, by: { $0.0 })
		return grouped.values.filter { group in
			let records = group.map(\.1)
			let turnIDs = Set(records.compactMap(\.turnID))
			let toolNames = Set(records.map { canonicalToolName($0.toolName) ?? "" })
			return turnIDs.count <= 1 && toolNames.count > 1
		}.count
	}

	private static func orphanToolResultCount(in records: [ToolRecord]) -> Int {
		let callKeys = Set(records.filter { $0.kind == .toolCall }.map(executionIdentity))
		return records.filter { record in
			record.kind == .toolResult
				&& record.invocationID != nil
				&& !callKeys.isEmpty
				&& !callKeys.contains(executionIdentity(for: record))
		}.count
	}

	private static func displaylessConclusionCount(in session: AgentSession) -> Int {
		guard let transcript = transcript(for: session) else { return 0 }
		return transcript.turns.filter { turn in
			guard let conclusionActivityID = turn.conclusionActivityID,
				let conclusion = turn.allActivities.first(where: { $0.id == conclusionActivityID }),
				isAssistantKind(conclusion.itemKind)
			else {
				return false
			}
			return !AgentDisplayableText.hasDisplayableBody(conclusion.text)
		}.count
	}

	private static func staleConclusionCount(in session: AgentSession) -> Int {
		guard let transcript = transcript(for: session) else { return 0 }
		return transcript.turns.filter { turn in
			let expected = trailingDisplayableAssistant(in: turn)
			let stored = turn.conclusionActivityID
			switch (stored, expected?.id) {
			case (nil, _):
				return false
			case let (stored?, expectedID?):
				return stored != expectedID
			case (_?, nil):
				return true
			}
		}.count
	}

	private static func missingConclusionWithAssistantCount(in session: AgentSession) -> Int {
		guard let transcript = transcript(for: session) else { return 0 }
		return transcript.turns.filter { turn in
			turn.conclusionActivityID == nil && trailingDisplayableAssistant(in: turn) != nil
		}.count
	}

	private static func lowSubstantiveFinalAnswerCount(in session: AgentSession) -> Int {
		guard let transcript = transcript(for: session) else { return 0 }
		return transcript.turns.filter { turn in
			guard let assistant = conclusionOrLatestDisplayableAssistant(in: turn) else { return false }
			return isLowSubstantiveFinalAnswer(assistant.text)
		}.count
	}

	private static func latestDisplayableAssistant(in turn: AgentTranscriptTurn) -> AgentTranscriptActivity? {
		turn.allActivities.reversed().first { activity in
			isAssistantKind(activity.itemKind) && AgentDisplayableText.hasDisplayableBody(activity.text)
		}
	}

	private static func trailingDisplayableAssistant(in turn: AgentTranscriptTurn) -> AgentTranscriptActivity? {
		turn.allActivities.reversed().prefix { activity in
			isAssistantKind(activity.itemKind)
		}.first { activity in
			AgentDisplayableText.hasDisplayableBody(activity.text)
		}
	}

	private static func conclusionOrLatestDisplayableAssistant(in turn: AgentTranscriptTurn) -> AgentTranscriptActivity? {
		if let conclusionID = turn.conclusionActivityID,
			let conclusion = turn.allActivities.first(where: { $0.id == conclusionID }),
			isAssistantKind(conclusion.itemKind),
			AgentDisplayableText.hasDisplayableBody(conclusion.text) {
			return conclusion
		}
		return latestDisplayableAssistant(in: turn)
	}

	private static func payloadStats(for records: [ToolRecord]) -> (maxPayloadChars: Int, duplicatedTextResultJSONChars: Int) {
		var maxPayloadChars = 0
		var duplicatedTextResultJSONChars = 0
		for record in records {
			let payloads = ([record.toolName, record.argsJSON, record.resultJSON, record.text, record.processID, record.summaryText]
				+ record.keyPaths.map(Optional.some)).compactMap { $0 }
			for payload in payloads {
				maxPayloadChars = max(maxPayloadChars, utf8Count(payload))
			}
			if let resultJSON = record.resultJSON,
				!resultJSON.isEmpty,
				record.text == resultJSON,
				!isSummaryOnlyJSON(resultJSON) {
				duplicatedTextResultJSONChars += utf8Count(resultJSON)
			}
		}
		return (maxPayloadChars, duplicatedTextResultJSONChars)
	}

	private static func rawPayloadCount(in records: [ToolRecord], canonicalToolName expectedName: String) -> Int {
		records.filter { record in
			guard record.kind == .toolResult,
				canonicalToolName(record.toolName) == expectedName,
				let payload = record.resultJSON ?? (record.text.isEmpty ? nil : record.text)
			else {
				return false
			}
			return looksLikeRawPayload(payload, toolName: expectedName)
		}.count
	}

	// MARK: - Predicates

	private static func isAssistantRow(_ row: AgentChatItem) -> Bool {
		isAssistantKind(row.kind)
	}

	private static func isAssistantKind(_ kind: AgentChatItemKind) -> Bool {
		kind == .assistant || kind == .assistantInline
	}

	private static func isToolRow(_ row: AgentChatItem) -> Bool {
		row.kind == .toolCall || row.kind == .toolResult
	}

	private static func isPlaceholderToolName(_ raw: String?) -> Bool {
		AgentTranscriptToolVisibilityPolicy.isPlaceholderToolName(raw)
	}

	private static func isPathLikeToolName(_ raw: String?) -> Bool {
		AgentTranscriptToolVisibilityPolicy.isPathLikeToolName(raw)
	}

	private static func canonicalToolName(_ raw: String?) -> String? {
		AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(raw)
	}

	private static func isSummaryOnlyOrEmpty(_ row: AgentChatItem) -> Bool {
		let payload = row.toolResultJSON ?? row.toolArgsJSON ?? row.text
		return payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSummaryOnlyJSON(payload)
	}

	private static func isSummaryOnlyOrEmpty(_ record: ToolRecord) -> Bool {
		let payload = record.resultJSON ?? record.argsJSON ?? record.text
		return payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSummaryOnlyJSON(payload)
	}

	private static func isSummaryOnlyJSON(_ raw: String) -> Bool {
		let compact = raw.replacingOccurrences(of: " ", with: "").lowercased()
		return compact.contains("\"summary_only\":true") || compact.contains("\"summaryonly\":true")
	}

	private static func looksLikeRawPayload(_ payload: String, toolName: String) -> Bool {
		if isSummaryOnlyJSON(payload) { return false }
		let lower = payload.lowercased()
		if utf8Count(payload) > 65_536 { return true }
		switch toolName {
		case "read_file":
			return lower.contains("\"content\"")
				|| lower.contains("\"contents\"")
				|| lower.contains("file_content")
		case "file_search":
			return lower.contains("\"matches\"")
				|| lower.contains("\"results\"")
				|| lower.contains("context_before")
				|| lower.contains("context_after")
		case "bash":
			return lower.contains("\"stdout\"")
				|| lower.contains("\"stderr\"")
				|| lower.contains("\"output\"")
		default:
			return false
		}
	}

	private static func isAssistantMicroNoise(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed == "."
	}

	private static func isLowSubstantiveFinalAnswer(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard AgentDisplayableText.hasDisplayableBody(trimmed) else { return false }
		if isAssistantMicroNoise(trimmed) { return false }
		let words = trimmed.split { $0.isWhitespace || $0.isPunctuation }
		return trimmed.count <= 32 && words.count <= 4
	}

	private static func toolTagNames(in xml: String) -> [String] {
		guard !xml.isEmpty,
			let regex = try? NSRegularExpression(
				pattern: #"<tool_(?:call|result)\s+name=\"([^\"]+)\""#,
				options: []
			)
		else {
			return []
		}
		let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
		return regex.matches(in: xml, range: nsRange).compactMap { match in
			guard match.numberOfRanges > 1,
				let range = Range(match.range(at: 1), in: xml)
			else {
				return nil
			}
			return String(xml[range])
		}
	}

	private static func assistantTagBodies(in xml: String) -> [String] {
		guard !xml.isEmpty,
			let regex = try? NSRegularExpression(
				pattern: #"<assistant>(.*?)</assistant>"#,
				options: [.dotMatchesLineSeparators]
			)
		else {
			return []
		}
		let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
		return regex.matches(in: xml, range: nsRange).compactMap { match in
			guard match.numberOfRanges > 1,
				let range = Range(match.range(at: 1), in: xml)
			else {
				return nil
			}
			return String(xml[range])
		}
	}

	private static func executionIdentity(for record: ToolRecord) -> String {
		if let invocationID = record.invocationID {
			return invocationID.uuidString
		}
		if let stableExecutionID = record.stableExecutionID, !stableExecutionID.isEmpty {
			return stableExecutionID
		}
		return "\(record.turnID?.uuidString ?? "no-turn"):\(record.sequenceIndex):\(canonicalToolName(record.toolName) ?? "unknown")"
	}

	private static func duplicateExecutionSignature(for record: ToolRecord) -> String {
		if let stableExecutionID = record.stableExecutionID,
			!stableExecutionID.isEmpty,
			stableExecutionID != record.invocationID?.uuidString {
			return stableExecutionID
		}
		return [
			record.turnID?.uuidString ?? "no-turn",
			canonicalToolName(record.toolName) ?? "unknown"
		].joined(separator: "\u{1F}")
	}

	private static func utf8Count(_ string: String) -> Int {
		string.utf8.count
	}

	private struct ToolRecord {
		let kind: AgentChatItemKind
		let toolName: String?
		let invocationID: UUID?
		let stableExecutionID: String?
		let argsJSON: String?
		let resultJSON: String?
		let text: String
		let status: AgentTranscriptToolStatus
		let processID: String?
		let summaryText: String?
		let keyPaths: [String]
		let turnID: UUID?
		let sequenceIndex: Int
		let isTerminalScope: Bool

		init?(activity: AgentTranscriptActivity, turnID: UUID, isTerminalScope: Bool) {
			guard activity.itemKind == .toolCall || activity.itemKind == .toolResult else { return nil }
			self.kind = activity.itemKind
			self.toolName = activity.toolExecution?.toolName
			self.invocationID = activity.toolExecution?.invocationID
			self.stableExecutionID = activity.toolExecution?.stableExecutionID
			self.argsJSON = activity.toolExecution?.argsJSON
			self.resultJSON = activity.toolExecution?.resultJSON
			self.text = activity.text
			self.status = activity.itemKind == .toolCall ? .pending : (activity.toolExecution?.status ?? .unknown)
			self.processID = activity.toolExecution?.processID
			self.summaryText = activity.toolExecution?.summaryText
			self.keyPaths = activity.toolExecution?.keyPaths ?? []
			self.turnID = turnID
			self.sequenceIndex = activity.sequenceIndex
			self.isTerminalScope = isTerminalScope
		}

		init?(item: AgentChatItem, turnID: UUID?, isTerminalScope: Bool) {
			guard item.kind == .toolCall || item.kind == .toolResult else { return nil }
			self.kind = item.kind
			self.toolName = item.toolName
			self.invocationID = item.toolInvocationID
			self.stableExecutionID = item.toolInvocationID?.uuidString
			self.argsJSON = item.toolArgsJSON
			self.resultJSON = item.toolResultJSON
			self.text = item.text
			self.status = item.kind == .toolCall ? .pending : AgentTranscriptToolNormalizer.status(for: item)
			self.processID = nil
			self.summaryText = nil
			self.keyPaths = []
			self.turnID = turnID
			self.sequenceIndex = item.sequenceIndex
			self.isTerminalScope = isTerminalScope
		}
	}
}
