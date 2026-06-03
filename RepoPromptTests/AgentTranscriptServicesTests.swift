import XCTest
@testable import RepoPrompt

final class AgentTranscriptServicesTests: XCTestCase {
	func testContinuousCompactionPreservesRequestResponseSpineWithinBudget() {
		let items = makeLongTranscriptItems(turnCount: 40)
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let compacted = AgentTranscriptCompactor.compact(transcript)
		let projection = AgentTranscriptProjectionBuilder.build(from: compacted)

		XCTAssertLessThanOrEqual(projection.workingUnitCount, AgentTranscriptCompactor.hardMaxWorkingUnitCount)
		XCTAssertFalse(projection.archivedRows.isEmpty)
		XCTAssertTrue(projection.archivedRows.contains(where: { $0.kind == .user && $0.text == "user 0" }))
		XCTAssertTrue(projection.archivedRows.contains(where: { $0.kind == .assistant && $0.text.contains("final summary 0") }))
	}

	func testConversationHistoryUsesStructuredTranscriptAfterCompaction() {
		let items = makeLongTranscriptItems(turnCount: 8)
		let compacted = AgentTranscriptCompactor.compact(AgentTranscriptIO.importLegacyItems(items))

		let history = AgentTranscriptIO.buildConversationHistory(from: compacted)

		XCTAssertTrue(history.contains("<user>user 0</user>"))
		XCTAssertTrue(history.contains("<assistant>final summary 0</assistant>"))
	}

	func testProjectionSuppressesWhitespaceOnlyAssistantRowsBetweenToolBlocks() {
		let firstInvocationID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
		let secondInvocationID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
		let ghostAssistant = AgentChatItem.assistant("\n\t ", sequenceIndex: 3)
		let items: [AgentChatItem] = [
			.user("Inspect the workspace.", sequenceIndex: 0),
			.toolCall(name: "read_file", invocationID: firstInvocationID, argsJSON: #"{"path":"README.md"}"#, sequenceIndex: 1),
			.toolResult(name: "read_file", invocationID: firstInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 2),
			ghostAssistant,
			.toolCall(name: "file_search", invocationID: secondInvocationID, argsJSON: #"{"pattern":"TODO"}"#, sequenceIndex: 4),
			.toolResult(name: "file_search", invocationID: secondInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 5),
			.assistant("Done.", sequenceIndex: 6)
		]

		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let visibleAssistantRows = projection.workingRows.filter { $0.kind == .assistant || $0.kind == .assistantInline }

		XCTAssertFalse(visibleAssistantRows.contains { !AgentDisplayableText.hasDisplayableBody($0.text) })
		XCTAssertEqual(visibleAssistantRows.map(\.text), ["Done."])
		assertNoProjectedAnchor(for: ghostAssistant.id, in: projection)
		XCTAssertEqual(
			AgentTranscriptProjectionBuilder.projectedVisibleRowCount(for: transcript),
			presentedItemCount(for: projection.workingBlocks) + presentedItemCount(for: projection.archivedBlocks)
		)
		XCTAssertEqual(
			AgentTranscriptProjectionBuilder.estimatedWorkingUnitCount(for: transcript),
			projection.workingUnitCount
		)
	}

	func testProjectionSanitizesPlaceholderOnlyFrozenGroupedSummaries() {
		let user = AgentChatItem.user("Continue.", sequenceIndex: 0)
		let spanID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
		let staleToolSummary = AgentTranscriptClusterSummary(
			toolCount: 1,
			toolNames: ["other"],
			toolNameCounts: ["other": 1],
			toolGroups: ClusterToolCategory.buildGroups(toolNames: ["other"], counts: ["other": 1]),
			keyPaths: [],
			containsRunningWork: false,
			containsFailure: false,
			containsWarning: false,
			shortNarration: nil
		)
		let staleSummary = AgentTranscriptGroupedHistorySummary(
			hiddenToolCardCount: 1,
			hiddenAssistantCount: 0,
			hiddenProgressCount: 0,
			hiddenNoteCount: 0,
			toolSummary: staleToolSummary
		)
		let turn = AgentTranscriptTurn(
			id: user.id,
			request: AgentTranscriptRequestAnchor(from: user),
			responseSpans: [
				AgentTranscriptProviderResponseSpan(
					id: spanID,
					startedAt: user.timestamp,
					lastActivityAt: user.timestamp,
					completedAt: user.timestamp,
					activities: [],
					collapsedSummary: staleSummary
				)
			],
			retentionTier: .summary,
			startedAt: user.timestamp,
			lastActivityAt: user.timestamp,
			completedAt: user.timestamp
		)
		let transcript = AgentTranscript(turns: [turn], nextSequenceIndex: 1)

		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let groupedSummary = projection.workingBlocks.compactMap(\.groupedHistory?.summary).first

		XCTAssertEqual(groupedSummary?.hiddenToolCardCount, 0)
		XCTAssertTrue(groupedSummary?.toolSummary?.toolNames.isEmpty ?? true)
		XCTAssertFalse(groupedSummary?.collapsedDisplay?.title.localizedCaseInsensitiveContains("other") == true)
		XCTAssertFalse(groupedSummary?.collapsedDisplay?.toolGroupText?.localizedCaseInsensitiveContains("other") == true)
	}

	func testProjectionRetaxesPersistedAgentControlGroupedSummaryForPresentation() throws {
		let user = AgentChatItem.user("Continue.", sequenceIndex: 0)
		let spanID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
		let staleToolSummary = AgentTranscriptClusterSummary(
			toolCount: 4,
			toolNames: ["agent_run", "agent_explore", "prompt", "git"],
			toolNameCounts: ["agent_run": 1, "agent_explore": 1, "prompt": 1, "git": 1],
			toolGroups: [.init(icon: "gearshape", label: "Config ×4")],
			keyPaths: [],
			containsRunningWork: false,
			containsFailure: false,
			containsWarning: false,
			shortNarration: nil,
			collapsedDisplay: AgentTranscriptCollapsedSummaryDisplay(
				title: "Tool activity",
				count: 4,
				detailText: "Config ×4",
				toolGroupText: "Config ×4"
			)
		)
		let staleSummary = AgentTranscriptGroupedHistorySummary(
			hiddenToolCardCount: 4,
			hiddenAssistantCount: 0,
			hiddenProgressCount: 0,
			hiddenNoteCount: 0,
			toolSummary: staleToolSummary,
			collapsedDisplay: AgentTranscriptCollapsedSummaryDisplay(
				title: "Tool activity",
				count: 4,
				detailText: "Config ×4",
				toolGroupText: "Config ×4"
			)
		)
		let turn = AgentTranscriptTurn(
			id: user.id,
			request: AgentTranscriptRequestAnchor(from: user),
			responseSpans: [
				AgentTranscriptProviderResponseSpan(
					id: spanID,
					startedAt: user.timestamp,
					lastActivityAt: user.timestamp,
					completedAt: user.timestamp,
					activities: [],
					collapsedSummary: staleSummary
				)
			],
			retentionTier: .summary,
			startedAt: user.timestamp,
			lastActivityAt: user.timestamp,
			completedAt: user.timestamp
		)
		let transcript = AgentTranscript(turns: [turn], nextSequenceIndex: 1)

		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let groupedSummary = try XCTUnwrap(projection.workingBlocks.compactMap(\.groupedHistory?.summary).first)

		XCTAssertEqual(groupedSummary.toolSummary?.toolGroups.map(\.icon), ["person.2", "gearshape"])
		XCTAssertEqual(groupedSummary.toolSummary?.toolGroups.map(\.label), ["Agent ×2", "Config ×2"])
		XCTAssertEqual(groupedSummary.toolSummary?.collapsedDisplay?.title, "Agent activity")
		XCTAssertEqual(groupedSummary.toolSummary?.collapsedDisplay?.toolGroupText, "Agent ×2, Config ×2")
		XCTAssertEqual(groupedSummary.collapsedDisplay?.title, "Agent activity")
		XCTAssertEqual(groupedSummary.collapsedDisplay?.toolGroupText, "Agent ×2, Config ×2")
	}

	func testConversationHistoryAndForkXMLSuppressDisplaylessAssistantRows() {
		let ghostAssistant = AgentChatItem.assistant("\n\n\n", sequenceIndex: 1)
		let items: [AgentChatItem] = [
			.user("Resume the session.", sequenceIndex: 0),
			ghostAssistant,
			.assistant(".", sequenceIndex: 2),
			.assistant("resumed after stop", sequenceIndex: 3)
		]
		let transcript = AgentTranscriptIO.importLegacyItems(items)

		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let history = AgentTranscriptIO.buildConversationHistory(from: transcript)
		let forkXML = AgentTranscriptIO.buildForkTranscriptXML(from: transcript)

		XCTAssertFalse((projection.workingRows + projection.archivedRows).contains { $0.id == ghostAssistant.id })
		assertNoProjectedAnchor(for: ghostAssistant.id, in: projection)
		XCTAssertFalse(history.contains("<assistant></assistant>"))
		XCTAssertFalse(history.contains("<assistant>\n\n\n</assistant>"))
		XCTAssertFalse(forkXML.contains("<assistant></assistant>"))
		XCTAssertFalse(forkXML.contains("<assistant>\n\n\n</assistant>"))
		XCTAssertTrue(history.contains("<assistant>.</assistant>"))
		XCTAssertTrue(forkXML.contains("<assistant>.</assistant>"))
		XCTAssertTrue(history.contains("<assistant>resumed after stop</assistant>"))
		XCTAssertTrue(forkXML.contains("<assistant>resumed after stop</assistant>"))
	}

	func testProjectionSuppressesFormatOnlyAssistantRowsBetweenToolBlocks() {
		let firstInvocationID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
		let secondInvocationID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
		let ghostAssistant = AgentChatItem.assistant("\u{200B}\u{2060}\u{FEFF}\u{200E}\u{200F}\u{2800}\u{3164}\u{FFA0}", sequenceIndex: 3)
		let items: [AgentChatItem] = [
			.user("Inspect the workspace.", sequenceIndex: 0),
			.toolCall(name: "read_file", invocationID: firstInvocationID, argsJSON: #"{"path":"README.md"}"#, sequenceIndex: 1),
			.toolResult(name: "read_file", invocationID: firstInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 2),
			ghostAssistant,
			.toolCall(name: "file_search", invocationID: secondInvocationID, argsJSON: #"{"pattern":"TODO"}"#, sequenceIndex: 4),
			.toolResult(name: "file_search", invocationID: secondInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 5),
			.assistant("Done.", sequenceIndex: 6)
		]

		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let visibleAssistantRows = projection.workingRows.filter { $0.kind == .assistant || $0.kind == .assistantInline }

		XCTAssertEqual(visibleAssistantRows.map(\.text), ["Done."])
		assertNoProjectedAnchor(for: ghostAssistant.id, in: projection)
		XCTAssertEqual(
			projection.workingRows.map { "\($0.sequenceIndex):\($0.kind.rawValue)" },
			[
				"0:user",
				"1:toolCall",
				"2:toolResult",
				"4:toolCall",
				"5:toolResult",
				"6:assistant"
			]
		)
		XCTAssertEqual(
			AgentTranscriptProjectionBuilder.projectedVisibleRowCount(for: transcript),
			presentedItemCount(for: projection.workingBlocks) + presentedItemCount(for: projection.archivedBlocks)
		)
		XCTAssertEqual(
			AgentTranscriptProjectionBuilder.estimatedWorkingUnitCount(for: transcript),
			projection.workingUnitCount
		)
	}

	func testProjectionSuppressesStaleDisplaylessConclusionActivity() {
		let now = Date(timeIntervalSince1970: 1_700_000_000)
		let user = AgentChatItem.user("Inspect the workspace.", sequenceIndex: 0)
		let ghostAssistant = AgentChatItem.assistant("\u{200B}\u{2060}", sequenceIndex: 1)
		let activity = AgentTranscriptActivity(from: ghostAssistant)
		let spanID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
		let turn = AgentTranscriptTurn(
			id: user.id,
			request: AgentTranscriptRequestAnchor(from: user),
			responseSpans: [
				AgentTranscriptProviderResponseSpan(
					id: spanID,
					startedAt: now,
					lastActivityAt: now,
					completedAt: now,
					activities: [activity]
				)
			],
			conclusionActivityID: ghostAssistant.id,
			retentionTier: .archived,
			summary: AgentTranscriptTurnSummary(
				requestText: user.text,
				conclusionText: ghostAssistant.text,
				compactConclusionText: ghostAssistant.text,
				middleSummaryText: nil,
				toolCount: 0,
				notableToolNames: [],
				keyPaths: [],
				compactedActivityCount: 1,
				hadWarning: false,
				hadError: false
			),
			startedAt: now,
			lastActivityAt: now,
			completedAt: now
		)
		let transcript = AgentTranscript(turns: [turn], nextSequenceIndex: 2)

		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let visibleRows = projection.workingRows + projection.archivedRows

		XCTAssertFalse(visibleRows.contains { $0.id == ghostAssistant.id })
		XCTAssertFalse(visibleRows.contains { $0.kind == .assistant || $0.kind == .assistantInline })
		assertNoProjectedAnchor(for: ghostAssistant.id, in: projection)
	}

	func testRichHarnessBashRunningPayloadParsesAsRunning() {
		let raw = BashToolResultParser.resultJSON(
			statusWord: "running",
			command: "xcodetester build",
			processID: "stress-bash-24017",
			output: "CompileSwift normal arm64\nLd RepoPrompt.debug.dylib\n",
			exitCode: nil,
			summaryOnly: false
		)
		let parsed = BashToolResultParser.parse(raw: raw, argsJSON: #"{"cmd":"xcodetester build"}"#)

		XCTAssertTrue(parsed.isRunning)
		XCTAssertEqual(parsed.processID, "stress-bash-24017")
		XCTAssertEqual(parsed.command, "xcodetester build")
		XCTAssertFalse(parsed.isSummaryOnly)
		XCTAssertTrue(parsed.output?.contains("CompileSwift normal arm64") == true)
	}

	func testRichHarnessBashCompletedPayloadParsesAsCompleted() {
		let raw = BashToolResultParser.resultJSON(
			statusWord: "completed",
			command: "xcodetester test --only-testing RepoPromptTests/AgentTranscriptServicesTests/testRichHarnessBashRunningPayloadParsesAsRunning",
			processID: "stress-bash-24018",
			output: "Test Suite 'AgentTranscriptServicesTests' passed.\n",
			exitCode: 0,
			summaryOnly: false
		)
		let parsed = BashToolResultParser.parse(raw: raw, argsJSON: #"{"cmd":"xcodetester test --only-testing RepoPromptTests/AgentTranscriptServicesTests/testRichHarnessBashRunningPayloadParsesAsRunning"}"#)

		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.exitCode, 0)
		XCTAssertEqual(parsed.processID, "stress-bash-24018")
		XCTAssertTrue(parsed.output?.contains("passed") == true)
	}

	func testBashTerminationStatusNormalizesConsistentlyAcrossTranscriptAndSanitization() throws {
		let raw = #"{"type":"commandExecution","status":"terminated","processId":"bash-123","durationMs":10}"#
		let item = AgentChatItem.toolResult(
			name: "bash",
			invocationID: UUID(),
			resultJSON: raw,
			isError: nil,
			sequenceIndex: 0
		)

		let status = AgentTranscriptToolNormalizer.status(for: item)
		let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: item))

		XCTAssertEqual(status, .cancelled)
		XCTAssertEqual(sanitized.transcriptStatus, .cancelled)
		XCTAssertEqual(sanitized.persistedStatusWord, "cancelled")
	}

	func testPendingToolResultStatusRemainsPendingAcrossTranscriptAndSanitization() throws {
		let raw = #"{"status":"pending"}"#
		let item = AgentChatItem.toolResult(
			name: "read_file",
			invocationID: UUID(),
			resultJSON: raw,
			isError: nil,
			sequenceIndex: 0
		)

		let status = AgentTranscriptToolNormalizer.status(for: item)
		let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: item))

		XCTAssertEqual(status, .pending)
		XCTAssertEqual(sanitized.transcriptStatus, .pending)
		XCTAssertEqual(sanitized.persistedStatusWord, "pending")
	}

	func testAgentRunToolResultUsesSemanticRunStatus() throws {
		let raw = #"{"status":"failed","session_id":"075cda44-1111-2222-3333-444444444444","assistant_text":"hello world"}"#
		let item = AgentChatItem.toolResult(
			name: "agent_run",
			invocationID: UUID(),
			resultJSON: raw,
			isError: false,
			sequenceIndex: 0
		)

		let status = AgentTranscriptToolNormalizer.status(for: item)
		let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: item))
		let object = try XCTUnwrap(ToolRawJSON.object(from: sanitized.resultJSON))

		XCTAssertEqual(status, .failed)
		XCTAssertEqual(sanitized.transcriptStatus, .failed)
		XCTAssertEqual(sanitized.persistedStatusWord, "failed")
		XCTAssertTrue(ToolRawJSON.bool(object, key: "summary_only") == true)
		XCTAssertEqual(ToolRawJSON.string(object, key: "session_id"), "075cda44-1111-2222-3333-444444444444")
		XCTAssertEqual(ToolRawJSON.string(object, key: "assistant_text"), "hello world")
		XCTAssertTrue(sanitized.summaryOnly)
		XCTAssertFalse(sanitized.preservesRawPayload)
	}

	func testAgentExploreToolResultUsesSemanticRunStatusAndCompactSummary() throws {
		let raw = #"{"status":"waiting_for_input","session_id":"075cda44-1111-2222-3333-555555555555","assistant_text":"need more direction","interaction":{"kind":"question","prompt":"Which area should I inspect?"}}"#
		let item = AgentChatItem.toolResult(
			name: "agent_explore",
			invocationID: UUID(),
			resultJSON: raw,
			isError: false,
			sequenceIndex: 0
		)

		let status = AgentTranscriptToolNormalizer.status(for: item)
		let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: item))
		let object = try XCTUnwrap(ToolRawJSON.object(from: sanitized.resultJSON))

		XCTAssertEqual(status, .warning)
		XCTAssertEqual(sanitized.transcriptStatus, .warning)
		XCTAssertEqual(sanitized.persistedStatusWord, "waiting_for_input")
		XCTAssertTrue(ToolRawJSON.bool(object, key: "summary_only") == true)
		XCTAssertEqual(ToolRawJSON.string(object, key: "session_id"), "075cda44-1111-2222-3333-555555555555")
		XCTAssertEqual(ToolRawJSON.string(object, key: "assistant_text"), "need more direction")
		XCTAssertNotNil(object["interaction"] as? [String: Any])
		XCTAssertTrue(sanitized.summaryOnly)
		XCTAssertFalse(sanitized.preservesRawPayload)

		let persisted = try persistedToolResultActivity(toolName: "agent_explore", resultJSON: raw)
		XCTAssertEqual(persisted.execution.toolName, "agent_explore")
		XCTAssertEqual(persisted.execution.status, .warning)
		XCTAssertTrue(persisted.execution.summaryOnly)
	}

	func testAgentManageToolResultPersistsCompactManagementSummary() throws {
		let raw = #"{"status":"success","sessions":[{"name":"Child Session","state":"idle","agent":{"id":"codex"}}]}"#
		let item = AgentChatItem.toolResult(
			name: "agent_manage",
			invocationID: UUID(),
			resultJSON: raw,
			isError: false,
			sequenceIndex: 0
		)

		let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: item))
		let object = try XCTUnwrap(ToolRawJSON.object(from: sanitized.resultJSON))

		XCTAssertEqual(sanitized.transcriptStatus, .success)
		XCTAssertTrue(ToolRawJSON.bool(object, key: "summary_only") == true)
		XCTAssertNil(ToolRawJSON.string(object, key: "run_state"))
		XCTAssertNil(ToolRawJSON.string(object, key: "workflow_name"))
		XCTAssertEqual((object["sessions"] as? [[String: Any]])?.count, 1)
		XCTAssertTrue(sanitized.summaryOnly)
		XCTAssertFalse(sanitized.preservesRawPayload)

		let persisted = try persistedToolResultActivity(toolName: "agent_manage", resultJSON: raw)
		let persistedObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		XCTAssertNil(persistedObject["sessions"])
	}

	func testAgentManageCleanupSessionsToolResultPreservesCompactCounts() throws {
		let raw = #"{"status":"success","deleted_count":2,"skipped_count":1,"deleted_sessions":[{"id":"deleted"}],"skipped_sessions":[{"id":"skipped","reason":"running"}]}"#
		let item = AgentChatItem.toolResult(
			name: "agent_manage",
			invocationID: UUID(),
			resultJSON: raw,
			isError: false,
			sequenceIndex: 0
		)

		let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: item))
		let object = try XCTUnwrap(ToolRawJSON.object(from: sanitized.resultJSON))

		XCTAssertTrue(ToolRawJSON.bool(object, key: "summary_only") == true)
		XCTAssertEqual(ToolRawJSON.int(object, key: "deleted_count"), 2)
		XCTAssertEqual(ToolRawJSON.int(object, key: "skipped_count"), 1)
		XCTAssertEqual(ToolRawJSON.string(object, key: "summary_text"), "2 deleted, 1 skipped")
		XCTAssertNil(object["deleted_sessions"])
		XCTAssertNil(object["skipped_sessions"])

		let persisted = try persistedToolResultActivity(
			toolName: "agent_manage",
			resultJSON: raw,
			argsJSON: #"{"op":"cleanup_sessions"}"#
		)
		let persistedObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		XCTAssertEqual(ToolRawJSON.int(persistedObject, key: "deleted_count"), 2)
		XCTAssertEqual(ToolRawJSON.int(persistedObject, key: "skipped_count"), 1)
		XCTAssertEqual(ToolRawJSON.string(persistedObject, key: "summary_text"), "2 deleted, 1 skipped")
		XCTAssertTrue(persisted.execution.summaryOnly)
	}

	func testOracleToolResultPreservesCompactSummaryMetadataOnly() throws {
		let raw = #"{"status":"success","chat_id":"oracle-chat","mode":"plan","response":"SENTINEL_ORACLE_RESPONSE","diffs":[{"path":"RepoPrompt/Foo.swift","patch":"SENTINEL_DIFF"}]}"#
		let item = AgentChatItem.toolResult(
			name: "ask_oracle",
			invocationID: UUID(),
			resultJSON: raw,
			isError: false,
			sequenceIndex: 0
		)

		let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: item))
		let object = try XCTUnwrap(ToolRawJSON.object(from: sanitized.resultJSON))

		XCTAssertTrue(ToolRawJSON.bool(object, key: "summary_only") == true)
		XCTAssertEqual(ToolRawJSON.string(object, key: "chat_id"), "oracle-chat")
		XCTAssertEqual(ToolRawJSON.string(object, key: "mode"), "plan")
		XCTAssertEqual(ToolRawJSON.int(object, key: "diff_count"), 1)
		XCTAssertEqual(ToolRawJSON.bool(object, key: "has_response"), true)
		XCTAssertEqual(ToolRawJSON.string(object, key: "summary_text"), "plan • 1 diff")
		XCTAssertFalse(sanitized.resultJSON?.contains("SENTINEL_ORACLE_RESPONSE") == true)
		XCTAssertFalse(sanitized.resultJSON?.contains("SENTINEL_DIFF") == true)
		XCTAssertTrue(sanitized.summaryOnly)
		XCTAssertFalse(sanitized.preservesRawPayload)

		let persisted = try persistedToolResultActivity(toolName: "ask_oracle", resultJSON: raw)
		let persistedObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		XCTAssertEqual(ToolRawJSON.string(persistedObject, key: "chat_id"), "oracle-chat")
		XCTAssertEqual(ToolRawJSON.string(persistedObject, key: "mode"), "plan")
		XCTAssertEqual(ToolRawJSON.int(persistedObject, key: "diff_count"), 1)
		XCTAssertFalse(persisted.encoded.contains("SENTINEL_ORACLE_RESPONSE"))
		XCTAssertFalse(persisted.encoded.contains("SENTINEL_DIFF"))
		XCTAssertTrue(persisted.execution.summaryOnly)

		let errorRaw = #"{"status":"failed","chat_id":"oracle-chat","mode":"plan","errors":["one","two","three","four"]}"#
		let errorItem = AgentChatItem.toolResult(
			name: "oracle_send",
			invocationID: UUID(),
			resultJSON: errorRaw,
			isError: true,
			sequenceIndex: 0
		)
		let errorSanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: errorItem))
		let errorObject = try XCTUnwrap(ToolRawJSON.object(from: errorSanitized.resultJSON))
		XCTAssertEqual(ToolRawJSON.int(errorObject, key: "error_count"), 4)
		XCTAssertEqual((errorObject["errors"] as? [String])?.count, 3)
	}

	func testSummaryTitleSemanticUsesSharedTaxonomyWithoutPromotingWorkspaceContext() {
		XCTAssertEqual(
			ClusterToolCategory.summaryTitleSemantic(
				toolNames: ["workspace_context"],
				toolNameCounts: [:],
				containsRunningWork: false
			),
			.toolActivity
		)
		XCTAssertEqual(
			ClusterToolCategory.summaryTitleSemantic(
				toolNames: ["agent_run"],
				toolNameCounts: [:],
				containsRunningWork: false
			),
			.agentActivity
		)
		XCTAssertEqual(
			ClusterToolCategory.summaryTitleSemantic(
				toolNames: ["agent_explore", "agent_manage"],
				toolNameCounts: [:],
				containsRunningWork: false
			),
			.agentActivity
		)
		XCTAssertEqual(
			ClusterToolCategory.summaryTitleSemantic(
				toolNames: ["read_file", "apply_edits"],
				toolNameCounts: [:],
				containsRunningWork: false
			),
			.exploredAndEdited
		)
		let summary = AgentTranscriptClusterSummary(
			toolCount: 2,
			toolNames: ["workspace_context"],
			toolNameCounts: [:],
			keyPaths: [],
			containsRunningWork: false,
			containsFailure: false,
			containsWarning: false,
			shortNarration: nil
		)
		let agentSummary = AgentTranscriptClusterSummary(
			toolCount: 2,
			toolNames: ["agent_run", "agent_explore"],
			toolNameCounts: [:],
			keyPaths: [],
			containsRunningWork: false,
			containsFailure: false,
			containsWarning: false,
			shortNarration: nil
		)
		XCTAssertEqual(AgentTranscriptSummaryTextFormatter.summaryTitle(for: summary, fallbackCount: 1), "Tool activity")
		XCTAssertEqual(AgentTranscriptSummaryTextFormatter.summaryTitle(for: agentSummary, fallbackCount: 2), "Agent activity")
	}

	func testCollapsedDisplayPrecomputesRenderFriendlyStrings() {
		let summary = AgentTranscriptClusterSummary(
			toolCount: 3,
			toolNames: ["bash", "read_file"],
			toolNameCounts: ["bash": 2, "read_file": 1],
			toolGroups: [
				.init(icon: "terminal", label: "Bash x2"),
				.init(icon: "doc.text", label: "Read File")
			],
			keyPaths: [],
			containsRunningWork: false,
			containsFailure: false,
			containsWarning: true,
			shortNarration: "Checked the workspace",
			collapsedDisplay: AgentTranscriptSummaryTextFormatter.collapsedDisplay(
				for: AgentTranscriptClusterSummary(
					toolCount: 3,
					toolNames: ["bash", "read_file"],
					toolNameCounts: ["bash": 2, "read_file": 1],
					toolGroups: [
						.init(icon: "terminal", label: "Bash x2"),
						.init(icon: "doc.text", label: "Read File")
					],
					keyPaths: [],
					containsRunningWork: false,
					containsFailure: false,
					containsWarning: true,
					shortNarration: "Checked the workspace"
				),
				fallbackCount: 3
			)
		)

		XCTAssertEqual(summary.collapsedDisplay?.title, "Ran commands")
		XCTAssertEqual(summary.collapsedDisplay?.count, 3)
		XCTAssertEqual(summary.collapsedDisplay?.detailText, "Checked the workspace • Bash x2, Read File")
		XCTAssertEqual(summary.collapsedDisplay?.status, .warning)
	}

	func testCondensedSummaryUsesCompactCountsAndNormalizedRepoPromptToolNames() throws {
		let readInvocationID = UUID()
		let treeInvocationID = UUID()
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate prompt export", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "checking the old transcript summary", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "mcp__RepoPrompt__read_file", invocationID: readInvocationID, argsJSON: #"{"path":"RepoPrompt/Services/AI/Prompts/Prompts.swift"}"#, sequenceIndex: 2),
			AgentChatItem.toolResult(name: "mcp__RepoPrompt__read_file", invocationID: readInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem.toolCall(name: "mcp__RepoPrompt__get_file_tree", invocationID: treeInvocationID, argsJSON: #"{"path":"RepoPrompt/Services/AI/Prompts"}"#, sequenceIndex: 4),
			AgentChatItem.toolResult(name: "mcp__RepoPrompt__get_file_tree", invocationID: treeInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 5),
			AgentChatItem.assistant("final summary", sequenceIndex: 6)
		]

		var turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		turn.retentionTier = .condensed
		let rows = AgentTranscriptProjectionBuilder.rows(for: turn, archived: false, isLatestTurn: false)
		let summaryRow = try XCTUnwrap(rows.first(where: { $0.kind == .system }))

		XCTAssertEqual(summaryRow.text, "2 tools called • 1 assistant message • 2 files • read_file, get_file_tree")
		XCTAssertFalse(summaryRow.text.contains("Tools:"))
		XCTAssertFalse(summaryRow.text.contains("Files:"))
		XCTAssertFalse(summaryRow.text.contains("mcp__RepoPrompt__"))
	}

	func testConversationHistoryUsesCondensedSummaryWithoutLogStylePrefixes() throws {
		let invocationID = UUID()
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate prompt export", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "checking the old transcript summary", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "mcp__RepoPrompt__read_file", invocationID: invocationID, argsJSON: #"{"path":"RepoPrompt/Services/AI/Prompts/Prompts.swift"}"#, sequenceIndex: 2),
			AgentChatItem.toolResult(name: "mcp__RepoPrompt__read_file", invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem.assistant("final summary", sequenceIndex: 4)
		]

		var transcript = AgentTranscriptIO.importLegacyItems(items)
		transcript.turns[0].retentionTier = .condensed
		let history = AgentTranscriptIO.buildConversationHistory(from: transcript)

		XCTAssertTrue(history.contains("<system>1 tool called • 1 assistant message • 1 file • read_file</system>"))
		XCTAssertFalse(history.contains("Tools:"))
		XCTAssertFalse(history.contains("Files:"))
		XCTAssertFalse(history.contains("mcp__RepoPrompt__"))
	}

	func testCondensedTierUsesGroupedHistoryVisualBlock() throws {
		var transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		]))
		transcript.turns[0].retentionTier = .condensed
		let condensedTurn = try XCTUnwrap(transcript.turns.first)

		let blocks = AgentTranscriptProjectionBuilder.blocks(for: condensedTurn, archived: false)
		let counts = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)

		let groupedHistory = try XCTUnwrap(blocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory)
		XCTAssertFalse(blocks.contains(where: { $0.kind == .middleSummary }))
		XCTAssertEqual(blocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 0)
		XCTAssertTrue(groupedHistory.sections.isEmpty)
		XCTAssertEqual(counts.canonicalVisibleRowCount, presentedItemCount(for: blocks))
	}

	func testCompletedTurnsStayFullUntilBudgetPressure() {
		let transcript = AgentTranscriptIO.importLegacyItems(makeLongTranscriptItems(turnCount: 8))
		let compacted = AgentTranscriptCompactor.compact(transcript)

		XCTAssertTrue(compacted.turns.allSatisfy { $0.retentionTier == .full })
		XCTAssertNil(compacted.compactionFrontier)
	}

	func testNormalizedTranscriptClearsStaleCompactionFrontierWhenPrefixIsNoLongerCompacted() {
		let items = makeLongTranscriptItems(turnCount: 2)
		var transcript = AgentTranscriptIO.importLegacyItems(items)
		transcript.compactionFrontier = AgentTranscriptCompactionFrontier(
			frozenPrefixTurnCount: 1,
			lastFrozenTurnID: transcript.turns[0].id
		)

		let normalized = AgentTranscriptIO.normalizedTranscript(transcript)

		XCTAssertNil(normalized.compactionFrontier)
	}

	func testContainsExcludedLegacyItemsHonorsImportPolicy() {
		let items: [AgentChatItem] = [
			.user("Start", sequenceIndex: 0),
			.toolCall(name: "ask_user", invocationID: UUID(), argsJSON: #"{"question":"Proceed?"}"#, sequenceIndex: 1),
			.toolResult(name: "ask_user", invocationID: UUID(), resultJSON: #"{"response":"Yes"}"#, isError: false, sequenceIndex: 2)
		]

		XCTAssertFalse(AgentTranscriptIO.containsExcludedLegacyItems(items, policy: .canonical))
		XCTAssertTrue(
			AgentTranscriptIO.containsExcludedLegacyItems(
				items,
				policy: .liveSession(hidePendingQuestionToolCall: true)
			)
		)
	}

	func testFullDetailTurnEnvelopeChangedTracksOnlyFullTurnIDs() throws {
		let transcript = AgentTranscriptCompactor.compact(
			AgentTranscriptIO.importLegacyItems(makeLongTranscriptItems(turnCount: 40))
		)
		var sameEnvelope = transcript
		let compactedTurnIndex = try XCTUnwrap(sameEnvelope.turns.firstIndex(where: { $0.retentionTier != .full }))
		sameEnvelope.turns[compactedTurnIndex].summary?.compactConclusionText = "updated summary shell"

		XCTAssertFalse(AgentTranscriptIO.fullDetailTurnEnvelopeChanged(from: transcript, to: sameEnvelope))

		var changedEnvelope = transcript
		let envelopeChangeIndex = changedEnvelope.turns.firstIndex(where: { $0.retentionTier == .full }) ?? compactedTurnIndex
		changedEnvelope.turns[envelopeChangeIndex].retentionTier = changedEnvelope.turns[envelopeChangeIndex].retentionTier == .full
			? .condensed
			: .full

		XCTAssertTrue(AgentTranscriptIO.fullDetailTurnEnvelopeChanged(from: transcript, to: changedEnvelope))
	}

	func testSummaryAndArchiveRowsKeepRequestResponseSpine() {
		let items = makeLongTranscriptItems(turnCount: 40)
		let compacted = AgentTranscriptCompactor.compact(AgentTranscriptIO.importLegacyItems(items))

		guard let summarizedTurn = compacted.turns.first(where: { $0.retentionTier == .summary }) else {
			return XCTFail("Expected at least one summarized turn")
		}
		let summarizedRows = AgentTranscriptProjectionBuilder.rows(for: summarizedTurn, archived: false)
		XCTAssertEqual(summarizedRows.first?.kind, .user)
		XCTAssertEqual(summarizedRows.last?.kind, .assistant)
		XCTAssertEqual(summarizedRows.first?.text, summarizedTurn.request?.text)
		XCTAssertTrue(summarizedRows.last?.text.contains("final summary") == true)

		guard let archivedTurn = compacted.turns.first(where: { $0.retentionTier == .archived }) else {
			return XCTFail("Expected at least one archived turn")
		}
		let archivedRows = AgentTranscriptProjectionBuilder.rows(for: archivedTurn, archived: true)
		XCTAssertEqual(archivedRows.first?.kind, .user)
		XCTAssertEqual(archivedRows.last?.kind, .assistant)
		XCTAssertEqual(archivedRows.first?.text, archivedTurn.request?.text)
		XCTAssertTrue(archivedRows.last?.text.contains("final summary") == true)
	}

	func testFullTurnKeepsLowSignalItemsDetailedUntilThreshold() throws {
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "checking parser", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "read_file", invocationID: nil, argsJSON: "{\"path\":\"Parser.swift\"}", sequenceIndex: 2),
			AgentChatItem.toolResult(name: "read_file", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 4), kind: .assistantInline, text: "searching usage sites", sequenceIndex: 4),
			AgentChatItem.toolCall(name: "search", invocationID: nil, argsJSON: "{\"pattern\":\"Parser\"}", sequenceIndex: 5),
			AgentChatItem.toolResult(name: "search", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 6),
			AgentChatItem.assistant("final summary", sequenceIndex: 7)
		]

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)

		XCTAssertEqual(blocks.map(\.kind), [
			.request,
			.standaloneAssistant,
			.standaloneTool,
			.standaloneAssistant,
			.standaloneTool,
			.conclusion
		])
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(blocks.dropFirst().dropLast().flatMap(\.rows).map(\.sequenceIndex), [1, 2, 3, 4, 5, 6])
	}

	func testFullTurnKeepsSubstantiveIntermediateAssistantStandalone() throws {
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "checking parser", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "read_file", invocationID: nil, argsJSON: "{\"path\":\"Parser.swift\"}", sequenceIndex: 2),
			AgentChatItem.toolResult(name: "read_file", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 4), kind: .assistant, text: "Found the root cause.\nIt is in Parser.swift.", sequenceIndex: 4),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 5), kind: .assistantInline, text: "verifying the call sites", sequenceIndex: 5),
			AgentChatItem.toolCall(name: "search", invocationID: nil, argsJSON: "{\"pattern\":\"Parser\"}", sequenceIndex: 6),
			AgentChatItem.toolResult(name: "search", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 7),
			AgentChatItem.assistant("final summary", sequenceIndex: 8)
		]

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)

		XCTAssertEqual(blocks.map(\.kind), [
			.request,
			.standaloneAssistant,
			.standaloneTool,
			.standaloneAssistant,
			.standaloneAssistant,
			.standaloneTool,
			.conclusion
		])
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertTrue(blocks.flatMap(\.rows).contains(where: { $0.text == "Found the root cause.\nIt is in Parser.swift." }))
	}

	func testImportLegacyItemsAssignsDeterministicSpanIDsAcrossEquivalentRebuilds() throws {
		let items = makeToolHeavyTurnItems(toolNames: ["read_file", "search", "read_file"])
		let first = AgentTranscriptIO.importLegacyItems(items)
		let second = AgentTranscriptIO.importLegacyItems(items)
		let firstTurn = try XCTUnwrap(first.turns.first)
		let secondTurn = try XCTUnwrap(second.turns.first)
		let firstSpan = try XCTUnwrap(firstTurn.responseSpans.first)
		let secondSpan = try XCTUnwrap(secondTurn.responseSpans.first)

		XCTAssertEqual(firstTurn.id, secondTurn.id)
		XCTAssertEqual(firstSpan.id, secondSpan.id)
	}

	func testCondensedProjectionUsesSerializedSpanCollapsedSummary() throws {
		let items = makeToolHeavyTurnItems(toolNames: ["read_file", "search", "apply_edits", "search", "read_file", "search", "read_file"])
		var turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		turn.retentionTier = .condensed
		turn.responseSpans[0].collapsedSummary = AgentTranscriptGroupedHistorySummary(
			hiddenToolCardCount: 7,
			hiddenAssistantCount: 2,
			hiddenProgressCount: 1,
			hiddenNoteCount: 3,
			toolSummary: AgentTranscriptClusterSummary(
				toolCount: 7,
				toolNames: ["apply_edits", "search", "read_file"],
				toolNameCounts: ["apply_edits": 1, "search": 3, "read_file": 3],
				toolGroups: [],
				keyPaths: ["B.swift", "A.swift"],
				containsRunningWork: false,
				containsFailure: false,
				containsWarning: true,
				shortNarration: "serialized summary"
			)
		)

		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)
		let groupedBlock = try XCTUnwrap(blocks.first(where: { $0.kind == .groupedHistory }))
		let summary = try XCTUnwrap(groupedBlock.groupedHistory?.summary)

		XCTAssertEqual(summary, turn.responseSpans[0].collapsedSummary)
		XCTAssertEqual(summary.toolSummary?.toolNames, ["apply_edits", "search", "read_file"])
		XCTAssertEqual(summary.toolSummary?.keyPaths, ["B.swift", "A.swift"])
		XCTAssertEqual(summary.toolSummary?.shortNarration, "serialized summary")
	}

	func testGroupedHistoryIDStaysStableAsTailGrowsPastThreshold() throws {
		let initialItems = makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])
		let extendedItems = makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search"
		])

		let initialTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(initialItems).turns.first)
		let importedExtendedTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(extendedItems).turns.first)
		let extendedSpan = try XCTUnwrap(importedExtendedTurn.responseSpans.first)
		let extendedTurn = AgentTranscriptTurn(
			id: initialTurn.id,
			request: initialTurn.request,
			responseSpans: [AgentTranscriptProviderResponseSpan(
				id: initialTurn.responseSpans.first?.id ?? extendedSpan.id,
				providerTurnID: extendedSpan.providerTurnID,
				runID: extendedSpan.runID,
				lifecycle: extendedSpan.lifecycle,
				startedAt: extendedSpan.startedAt,
				completedAt: extendedSpan.completedAt,
				activities: extendedSpan.activities
			)],
			conclusionActivityID: importedExtendedTurn.conclusionActivityID,
			retentionTier: importedExtendedTurn.retentionTier,
			summary: importedExtendedTurn.summary,
			terminalState: importedExtendedTurn.terminalState,
			startedAt: importedExtendedTurn.startedAt,
			completedAt: importedExtendedTurn.completedAt
		)
		let initialBlocks = AgentTranscriptProjectionBuilder.blocks(for: initialTurn, archived: false)
		let extendedBlocks = AgentTranscriptProjectionBuilder.blocks(for: extendedTurn, archived: false)
		let initialGroupedBlock = try XCTUnwrap(initialBlocks.first(where: { $0.kind == .groupedHistory }))
		let extendedGroupedBlock = try XCTUnwrap(extendedBlocks.first(where: { $0.kind == .groupedHistory }))
		let initialGroupedID = initialGroupedBlock.id
		let extendedGroupedID = extendedGroupedBlock.id

		let initialSpanID = try XCTUnwrap(initialTurn.responseSpans.first?.id)
		XCTAssertEqual(initialGroupedID, extendedGroupedID)
		XCTAssertEqual(initialGroupedBlock.primaryAnchor, extendedGroupedBlock.primaryAnchor)
		XCTAssertEqual(initialGroupedBlock.primaryAnchor, .groupedHistory(turnID: initialTurn.id, spanID: initialSpanID))
		XCTAssertEqual(initialBlocks.prefix(4).map(\.kind), [.request, .standaloneAssistant, .groupedHistory, .standaloneAssistant])
		XCTAssertEqual(extendedBlocks.prefix(4).map(\.kind), [.request, .standaloneAssistant, .groupedHistory, .standaloneAssistant])
		XCTAssertFalse(initialBlocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertFalse(extendedBlocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(initialBlocks.dropFirst().first?.rows.first?.text, "step 1")
		XCTAssertEqual(extendedBlocks.dropFirst().first?.rows.first?.text, "step 1")
	}

	func testRebuildPreservesCompactedShellsWhenProtectionKeepsMiddleTurnFull() throws {
		let imported = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: Array(
			repeating: ["read_file"],
			count: 20
		)))
		let protectedTurnID = imported.turns[2].id
		let protection = AgentTranscriptProjectionProtection.protectedTurn(protectedTurnID)
		let protectedTranscript = AgentTranscriptCompactor.compact(imported, protection: protection)
		let workingItems = AgentTranscriptIO.workingSourceItems(from: protectedTranscript)
		let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
			existingTranscript: protectedTranscript,
			workingItems: workingItems,
			protection: protection
		)

		XCTAssertEqual(protectedTranscript.turns[2].retentionTier, .full)
		XCTAssertTrue(protectedTranscript.turns.dropFirst(3).contains(where: { $0.retentionTier != .full }))
		XCTAssertEqual(rebuilt.turns.map(\.id), protectedTranscript.turns.map(\.id))
		XCTAssertEqual(rebuilt.turns.map(\.retentionTier), protectedTranscript.turns.map(\.retentionTier))
	}

	// MARK: - Newest Turn Protection (Compaction Invariant)

	func testCompactionNeverDegadesNewestTurnBelowFullEvenWithNoProtection() {
		// Reproduce the bug: a massive last turn with protection: .none should stay .full.
		// Before the fix, the compactor would downshift it to .condensed, stripping all activities.
		// Use 30 small turns + 1 large last turn to guarantee compaction pressure exceeds thresholds.
		var toolNamesByTurn: [[String]] = Array(repeating: ["read_file"], count: 30)
		toolNamesByTurn.append(Array(repeating: "read_file", count: 30))
		let items = makeMultiTurnToolHeavyItems(toolNamesByTurn: toolNamesByTurn)
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let compacted = AgentTranscriptCompactor.compact(transcript, protection: .none)

		// The newest turn must always remain .full
		XCTAssertEqual(compacted.turns.last?.retentionTier, .full)
		// It must still have its inline activities
		XCTAssertGreaterThan(compacted.turns.last?.allActivities.count ?? 0, 0)
		// Older turns should still be compacted under pressure
		XCTAssertTrue(compacted.turns.dropLast().contains(where: { $0.retentionTier != .full }))
	}

	func testPersistedPipelineNeverDegadesNewestTurnBelowFullWithNoProtection() {
		// Same scenario through the full persisted pipeline path
		var toolNamesByTurn: [[String]] = Array(repeating: ["read_file"], count: 30)
		toolNamesByTurn.append(Array(repeating: "read_file", count: 30))
		let items = makeMultiTurnToolHeavyItems(toolNamesByTurn: toolNamesByTurn)
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let persisted = AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript, protection: .none)

		XCTAssertEqual(persisted.transcript.turns.last?.retentionTier, .full)
		XCTAssertGreaterThan(persisted.transcript.turns.last?.allActivities.count ?? 0, 0)
		XCTAssertTrue(persisted.transcript.turns.dropLast().contains(where: { $0.retentionTier != .full }))
	}

	// MARK: - Tool-call anchored retention tail

	func testCompactionProtectsLastEightVisibleToolsAcrossMultipleTurns() throws {
		let olderTurns: [[String]] = Array(repeating: ["read_file"], count: 25)
		let protectedTailTurns = [
			["read_file", "search"],
			["read_file", "search", "bash"],
			["read_file"],
			["read_file", "search"]
		]
		let items = makeContextRichMultiTurnToolItems(toolNamesByTurn: olderTurns + protectedTailTurns)
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let expectedProtectedTurnIDs = Set(transcript.turns.suffix(protectedTailTurns.count).map(\.id))
		let compacted = AgentTranscriptCompactor.compact(transcript)

		XCTAssertTrue(compacted.turns.prefix(olderTurns.count).contains(where: { $0.retentionTier != .full }))
		for turnID in expectedProtectedTurnIDs {
			let turn = try XCTUnwrap(compacted.turns.first(where: { $0.id == turnID }))
			XCTAssertEqual(turn.retentionTier, .full)
			XCTAssertTrue(turn.allActivities.contains(where: { $0.itemKind == .toolCall }))
			XCTAssertTrue(turn.allActivities.contains(where: { $0.itemKind == .toolResult }))
			XCTAssertTrue(turn.allActivities.contains(where: { $0.itemKind == .thinking }))
			XCTAssertTrue(turn.allActivities.contains(where: { $0.itemKind == .system }))
		}
	}

	func testCompactionProtectsWholeTurnWhenLastEightToolsStartInsideToolHeavyTurn() throws {
		var toolNamesByTurn: [[String]] = Array(repeating: ["read_file"], count: 25)
		toolNamesByTurn.append(Array(repeating: "read_file", count: 12))
		toolNamesByTurn.append([]) // Newer steering turn proves this is not newest-turn-only protection.
		let items = makeContextRichMultiTurnToolItems(toolNamesByTurn: toolNamesByTurn)
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let toolHeavyTurnID = transcript.turns[25].id
		let compacted = AgentTranscriptCompactor.compact(transcript)
		let toolHeavyTurn = try XCTUnwrap(compacted.turns.first(where: { $0.id == toolHeavyTurnID }))
		let projection = AgentTranscriptProjectionBuilder.build(from: compacted)
		let toolHeavyBlocks = projection.workingBlocks.filter { $0.turnID == toolHeavyTurnID }

		XCTAssertEqual(toolHeavyTurn.retentionTier, .full)
		XCTAssertEqual(toolHeavyTurn.allActivities.filter { $0.itemKind == .toolCall }.count, 12)
		XCTAssertTrue(toolHeavyBlocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertEqual(toolHeavyBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, AgentTranscriptCompactor.protectedDetailedToolExecutionTailCount)
	}

	func testProtectedSummaryToolTailIsNotArchivedUnderHardPressure() throws {
		let items = makeMultiTurnToolHeavyItems(toolNamesByTurn: Array(repeating: ["read_file"], count: 45))
		var transcript = AgentTranscriptIO.importLegacyItems(items)
		for index in transcript.turns.indices {
			transcript.turns[index].retentionTier = .summary
		}
		let protectedSummaryTurnIDs = Set(transcript.turns.suffix(AgentTranscriptCompactor.protectedDetailedToolExecutionTailCount).map(\.id))
		let compacted = AgentTranscriptCompactor.compact(transcript)

		XCTAssertTrue(compacted.turns.prefix(compacted.turns.count - protectedSummaryTurnIDs.count).contains(where: { $0.retentionTier == .archived }))
		for turnID in protectedSummaryTurnIDs {
			let turn = try XCTUnwrap(compacted.turns.first(where: { $0.id == turnID }))
			XCTAssertEqual(turn.retentionTier, .summary)
			XCTAssertFalse(turn.allActivities.contains(where: { $0.itemKind == .toolCall }))
			XCTAssertEqual(turn.summary?.toolCount, 1)
		}
	}

	func testStructurallyCompactedSummaryToolTailUsesSummaryCountsToAvoidArchive() throws {
		let transcript = makeStructurallyCompactedSummaryTranscript(turnCount: 45, toolCountPerTurn: 1)
		let protectedSummaryTurnIDs = Set(transcript.turns.suffix(AgentTranscriptCompactor.protectedDetailedToolExecutionTailCount).map(\.id))
		let compacted = AgentTranscriptCompactor.compact(transcript)

		XCTAssertTrue(compacted.turns.prefix(compacted.turns.count - protectedSummaryTurnIDs.count).contains(where: { $0.retentionTier == .archived }))
		for turnID in protectedSummaryTurnIDs {
			let turn = try XCTUnwrap(compacted.turns.first(where: { $0.id == turnID }))
			XCTAssertEqual(turn.retentionTier, .summary)
			XCTAssertEqual(turn.summary?.toolCount, 1)
			XCTAssertFalse(turn.allActivities.contains(where: { $0.itemKind == .toolCall || $0.itemKind == .toolResult }))
		}
	}

	func testSeparatedToolCallAndResultCountAsOneProtectedExecution() throws {
		let olderTurns: [[String]] = Array(repeating: ["read_file"], count: 25)
		let items = makeContextRichMultiTurnToolItems(toolNamesByTurn: olderTurns)
			+ makeContextRichToolTurnItems(
				toolNames: ["read_file"],
				startingSequenceIndex: makeContextRichMultiTurnToolItems(toolNamesByTurn: olderTurns).count,
				userText: "Boundary visible tool",
				finalSummaryText: "boundary visible done"
			)
		let afterBoundaryStart = (items.last?.sequenceIndex ?? -1) + 1
		let separatedItems = makeSeparatedCallResultToolTurnItems(
			toolNames: Array(repeating: "search", count: 4),
			startingSequenceIndex: afterBoundaryStart,
			userText: "Separated call result tools",
			finalSummaryText: "separated done"
		)
		let finalItems = makeContextRichToolTurnItems(
			toolNames: Array(repeating: "bash", count: 3),
			startingSequenceIndex: (separatedItems.last?.sequenceIndex ?? afterBoundaryStart) + 1,
			userText: "Final visible tools",
			finalSummaryText: "final visible done"
		)
		let transcript = AgentTranscriptIO.importLegacyItems(items + separatedItems + finalItems)
		let boundaryTurn = try XCTUnwrap(transcript.turns.first(where: { $0.request?.text == "Boundary visible tool" }))
		let compacted = AgentTranscriptCompactor.compact(transcript)
		let compactedBoundaryTurn = try XCTUnwrap(compacted.turns.first(where: { $0.id == boundaryTurn.id }))

		XCTAssertEqual(compactedBoundaryTurn.retentionTier, .full)
		XCTAssertEqual(compactedBoundaryTurn.allActivities.filter { $0.itemKind == .toolCall }.count, 1)
		XCTAssertEqual(compactedBoundaryTurn.allActivities.filter { $0.itemKind == .toolResult }.count, 1)
	}

	func testSuppressedInternalToolsDoNotConsumeProtectedToolTailBudget() throws {
		let olderTurns: [[String]] = Array(repeating: ["read_file"], count: 25)
		let olderItems = makeContextRichMultiTurnToolItems(toolNamesByTurn: olderTurns)
		let boundaryItems = makeContextRichToolTurnItems(
			toolNames: Array(repeating: "read_file", count: 7),
			startingSequenceIndex: (olderItems.last?.sequenceIndex ?? -1) + 1,
			userText: "Boundary seven visible tools",
			finalSummaryText: "boundary seven done"
		)
		let hiddenItems = makeHiddenInternalToolTurnItems(
			toolCount: 12,
			startingSequenceIndex: (boundaryItems.last?.sequenceIndex ?? -1) + 1,
			userText: "Hidden internal tools",
			finalSummaryText: "hidden internal done"
		)
		let finalItems = makeContextRichToolTurnItems(
			toolNames: ["search"],
			startingSequenceIndex: (hiddenItems.last?.sequenceIndex ?? -1) + 1,
			userText: "Final one visible tool",
			finalSummaryText: "final one done"
		)
		let transcript = AgentTranscriptIO.buildTranscript(
			from: olderItems + boundaryItems + hiddenItems + finalItems,
			compact: false
		)
		let boundaryTurn = try XCTUnwrap(transcript.turns.first(where: { $0.request?.text == "Boundary seven visible tools" }))
		let compacted = AgentTranscriptCompactor.compact(transcript)
		let compactedBoundaryTurn = try XCTUnwrap(compacted.turns.first(where: { $0.id == boundaryTurn.id }))

		XCTAssertFalse(transcript.allActivities.contains(where: { $0.toolExecution?.toolName == "set_status" }))
		XCTAssertEqual(compactedBoundaryTurn.retentionTier, .full)
		XCTAssertEqual(compactedBoundaryTurn.allActivities.filter { $0.itemKind == .toolCall }.count, 7)
	}

	func testWorkingSourceRebuildPreservesToolTailForSmallAppends() throws {
		let baseToolTurnIndex = 25
		var baseToolNamesByTurn: [[String]] = Array(repeating: ["read_file"], count: baseToolTurnIndex)
		baseToolNamesByTurn.append(Array(repeating: "read_file", count: 7))
		let baseItems = makeContextRichMultiTurnToolItems(toolNamesByTurn: baseToolNamesByTurn)
		let baseTranscript = AgentTranscriptIO.importLegacyItems(baseItems)
		let baseToolTurnID = baseTranscript.turns[baseToolTurnIndex].id
		let compacted = AgentTranscriptCompactor.compact(baseTranscript)
		XCTAssertEqual(compacted.turns.first(where: { $0.id == baseToolTurnID })?.retentionTier, .full)

		for appendToolCount in [1, 2, 7] {
			let workingItems = AgentTranscriptIO.workingSourceItems(from: compacted)
			let nextSequenceIndex = (workingItems.map(\.sequenceIndex).max() ?? -1) + 1
			let appendedUserText = "Append tool tail \(appendToolCount)"
			let appendedItems = makeContextRichToolTurnItems(
				toolNames: Array(repeating: "search", count: appendToolCount),
				startingSequenceIndex: nextSequenceIndex,
				userText: appendedUserText,
				finalSummaryText: "APPENDED_TOOL_TAIL_DONE_\(appendToolCount)"
			)
			let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
				existingTranscript: compacted,
				workingItems: workingItems + appendedItems,
				nextSequenceIndex: nextSequenceIndex + appendedItems.count
			)
			let rebuiltBaseToolTurn = try XCTUnwrap(rebuilt.turns.first(where: { $0.id == baseToolTurnID }))
			let appendedTurn = try XCTUnwrap(rebuilt.turns.first(where: { $0.request?.text == appendedUserText }))
			let rebuiltWorkingItems = AgentTranscriptIO.workingSourceItems(from: rebuilt)

			XCTAssertEqual(rebuiltBaseToolTurn.retentionTier, .full)
			XCTAssertEqual(rebuiltBaseToolTurn.allActivities.filter { $0.itemKind == .toolCall }.count, 7)
			XCTAssertEqual(appendedTurn.retentionTier, .full)
			XCTAssertEqual(appendedTurn.allActivities.filter { $0.itemKind == .toolCall }.count, appendToolCount)
			XCTAssertTrue(rebuiltWorkingItems.contains(where: { $0.text == "APPENDED_TOOL_TAIL_DONE_\(appendToolCount)" }))
		}
	}

	func testIncrementalFinalTurnUpdatePreservesPreviousToolTailTurn() throws {
		let livePolicy = AgentTranscriptImportPolicy.liveSession(hidePendingQuestionToolCall: false)
		var toolNamesByTurn: [[String]] = Array(repeating: ["read_file"], count: 25)
		toolNamesByTurn.append(Array(repeating: "read_file", count: 7))
		toolNamesByTurn.append(["search"])
		let initialItems = makeContextRichMultiTurnToolItems(toolNamesByTurn: toolNamesByTurn)
		let existingTranscript = AgentTranscriptIO.buildTranscript(
			from: initialItems,
			terminalState: .running,
			nextSequenceIndex: initialItems.count,
			policy: livePolicy
		)
		let previousToolTailTurnID = existingTranscript.turns[25].id
		var updatedItems = initialItems
		let finalAssistantSequenceIndex = try XCTUnwrap(updatedItems.last?.sequenceIndex)
		updatedItems[updatedItems.count - 1] = AgentChatItem.assistant(
			"UPDATED_FINAL_INCREMENTAL_TOOL_TAIL",
			sequenceIndex: finalAssistantSequenceIndex
		)
		let finalTurnStartIndex = try XCTUnwrap(updatedItems.lastIndex(where: { $0.kind == .user }))
		let incrementalTranscript = try XCTUnwrap(AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
			existingTranscript: existingTranscript,
			items: updatedItems,
			earliestChangedIndex: finalTurnStartIndex,
			terminalState: .running,
			nextSequenceIndex: updatedItems.count,
			policy: livePolicy
		))

		XCTAssertEqual(incrementalTranscript.turns.first(where: { $0.id == previousToolTailTurnID })?.retentionTier, .full)
		XCTAssertEqual(incrementalTranscript.turns.last?.retentionTier, .full)
		XCTAssertTrue(incrementalTranscript.turns.last?.allActivities.contains(where: { $0.text == "UPDATED_FINAL_INCREMENTAL_TOOL_TAIL" }) == true)
	}

	func testACPFixtureRebuildDoesNotWorsenLegacyCompactionAndPreservesNewToolTail() throws {
		let fixture = try loadFixtureTranscript(named: "transcript-collapse-acp-steering-coalesce-A4B8CF7F.json")
		let originalTierByTurnID = Dictionary(uniqueKeysWithValues: fixture.turns.map { ($0.id, $0.retentionTier) })
		let originalFinalFullTurn = try XCTUnwrap(fixture.turns.last)
		let originalFinalFullSequences = Set(
			([originalFinalFullTurn.request?.sequenceIndex].compactMap { $0 })
				+ originalFinalFullTurn.allActivities.map(\.sequenceIndex)
		)

		XCTAssertEqual(fixture.turns.count, 39)
		XCTAssertEqual(fixture.compactionFrontier?.frozenPrefixTurnCount, 38)
		XCTAssertEqual(fixture.turns.filter { $0.retentionTier == .archived }.count, 6)
		XCTAssertEqual(fixture.turns.filter { $0.retentionTier == .summary }.count, 32)
		XCTAssertEqual(fixture.turns.filter { $0.retentionTier == .full }.count, 1)
		XCTAssertEqual(fixture.turns.last?.retentionTier, .full)

		let rebuilt = appendSyntheticVisibleToolTurn(
			to: fixture,
			toolExecutionCount: 2,
			label: "ACP"
		)
		let appendedTurn = try XCTUnwrap(rebuilt.turns.last)
		let projection = AgentTranscriptProjectionBuilder.build(from: rebuilt)

		let rebuiltOriginalFinalTurn = try XCTUnwrap(rebuilt.turns.first { turn in
			let rebuiltSequences = Set(([turn.request?.sequenceIndex].compactMap { $0 }) + turn.allActivities.map(\.sequenceIndex))
			return !rebuiltSequences.isDisjoint(with: originalFinalFullSequences)
		})

		XCTAssertEqual(rebuilt.turns.count, fixture.turns.count + 1)
		XCTAssertEqual(rebuiltOriginalFinalTurn.retentionTier, .full)
		XCTAssertEqual(appendedTurn.retentionTier, .full)
		XCTAssertEqual(appendedTurn.allActivities.filter { $0.itemKind == .toolCall }.count, 2)
		XCTAssertTrue(projection.workingRows.contains(where: { $0.text == "PRODUCTION_APPEND_DONE_ACP_2" }))

		for originalTurn in fixture.turns.dropLast() {
			let rebuiltTurn = try XCTUnwrap(rebuilt.turns.first(where: { $0.id == originalTurn.id }))
			XCTAssertEqual(rebuiltTurn.retentionTier, originalTierByTurnID[originalTurn.id])
			XCTAssertNotEqual(rebuiltTurn.retentionTier, .full)
		}
	}

	func testProductionTranscriptCollapseFixturesPreserveTailWhenExtended() throws {
		let fixtureNames = [
			"transcript-collapse-acp-steering-coalesce-A4B8CF7F.json",
			"transcript-collapse-fanout-cursor-cli-docs-update-7B2A756D.json"
		]
		for fixtureName in fixtureNames {
			let fixture = try loadFixtureTranscript(named: fixtureName)
			let originalTierByTurnID = Dictionary(uniqueKeysWithValues: fixture.turns.map { ($0.id, $0.retentionTier) })
			let originalFinalFullTurn = try XCTUnwrap(fixture.turns.last, "\(fixtureName) should have a final turn")
			let originalFinalSequences = sequenceIndexSet(for: originalFinalFullTurn)
			let baselineWorkingItems = AgentTranscriptIO.workingSourceItems(from: fixture)
			let baselineProjection = AgentTranscriptProjectionBuilder.build(from: fixture)

			XCTAssertFalse(baselineWorkingItems.isEmpty, "\(fixtureName) should expose a recoverable working suffix")
			XCTAssertGreaterThan(baselineProjection.workingUnitCount, 0, "\(fixtureName) should project working content")
			XCTAssertNotNil(fixture.compactionFrontier, "\(fixtureName) should exercise durable frozen-prefix reuse")

			for appendToolCount in [1, 2, 7] {
				let rebuilt = appendSyntheticVisibleToolTurn(
					to: fixture,
					toolExecutionCount: appendToolCount,
					label: "\(fixtureName)-\(appendToolCount)"
				)
				let appendedTurn = try XCTUnwrap(rebuilt.turns.last)
				let rebuiltOriginalFinalTurn = try XCTUnwrap(rebuilt.turns.first { turn in
					!sequenceIndexSet(for: turn).isDisjoint(with: originalFinalSequences)
				})
				let projection = AgentTranscriptProjectionBuilder.build(from: rebuilt)

				XCTAssertEqual(rebuiltOriginalFinalTurn.retentionTier, .full, "\(fixtureName) append \(appendToolCount)")
				XCTAssertEqual(appendedTurn.retentionTier, .full, "\(fixtureName) append \(appendToolCount)")
				XCTAssertEqual(appendedTurn.allActivities.filter { $0.itemKind == .toolCall }.count, appendToolCount)
				XCTAssertTrue(
					appendedTurn.allActivities.contains(where: { $0.itemKind == .thinking || $0.itemKind == .system }),
					"\(fixtureName) append \(appendToolCount) should retain intervening context"
				)
				XCTAssertTrue(
					projection.workingRows.contains(where: { $0.text == "PRODUCTION_APPEND_DONE_\(fixtureName)-\(appendToolCount)_\(appendToolCount)" }),
					"\(fixtureName) append \(appendToolCount) should project appended conclusion"
				)

				for originalTurn in fixture.turns where originalTurn.retentionTier != .full {
					let rebuiltTurn = try XCTUnwrap(rebuilt.turns.first(where: { $0.id == originalTurn.id }))
					XCTAssertEqual(rebuiltTurn.retentionTier, originalTierByTurnID[originalTurn.id], "\(fixtureName) append \(appendToolCount) should not worsen legacy prefix")
					XCTAssertNotEqual(rebuiltTurn.retentionTier, .full, "\(fixtureName) append \(appendToolCount) should not falsely restore legacy prefix")
				}
			}
		}
	}

	func testACPFixtureRepeatedSingleToolExtensionsPreserveRecoverableTail() throws {
		var transcript = try loadFixtureTranscript(named: "transcript-collapse-acp-steering-coalesce-A4B8CF7F.json")
		let originalFinalSequences = try sequenceIndexSet(for: XCTUnwrap(transcript.turns.last))
		let originalTierByTurnID = Dictionary(uniqueKeysWithValues: transcript.turns.map { ($0.id, $0.retentionTier) })

		for cycle in 1...3 {
			transcript = appendSyntheticVisibleToolTurn(
				to: transcript,
				toolExecutionCount: 1,
				label: "ACP-cycle-\(cycle)"
			)
			let appendedTurn = try XCTUnwrap(transcript.turns.last)
			let originalFinalTurn = try XCTUnwrap(transcript.turns.first { turn in
				!sequenceIndexSet(for: turn).isDisjoint(with: originalFinalSequences)
			})
			let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

			XCTAssertEqual(originalFinalTurn.retentionTier, .full)
			XCTAssertEqual(appendedTurn.retentionTier, .full)
			XCTAssertTrue(projection.workingRows.contains(where: { $0.text == "PRODUCTION_APPEND_DONE_ACP-cycle-\(cycle)_1" }))
			for (turnID, tier) in originalTierByTurnID where tier != .full {
				let rebuiltTurn = try XCTUnwrap(transcript.turns.first(where: { $0.id == turnID }))
				XCTAssertEqual(rebuiltTurn.retentionTier, tier)
			}
		}
	}

	#if DEBUG
	@MainActor
	func testLiveViewModelProductionTranscriptCollapseFixtureExtensionMetricsReport() async throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["RP_RUN_TRANSCRIPT_METRICS"] == "1"
			|| ProcessInfo.processInfo.environment["RP_TRANSCRIPT_METRICS_REPORT_PATH"] != nil,
			"Transcript metric reports are opt-in. Set RP_RUN_TRANSCRIPT_METRICS=1 to enable."
		)
		let recorder = TranscriptInstrumentationRecorder()
		AgentTranscriptDebugInstrumentation.reset()
		AgentTranscriptDebugInstrumentation.isEnabled = true
		AgentTranscriptDebugInstrumentation.protectedTailScanHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.compactionHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.workingSourceItemsHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.rebuildHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.projectionBuildHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.refreshAttemptHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.presentationPublishHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.sessionItemsReplacementHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.projectionIdentityHandler = { recorder.record($0) }
		defer { AgentTranscriptDebugInstrumentation.reset() }

		let fixtureNames = [
			"transcript-collapse-acp-steering-coalesce-A4B8CF7F.json",
			"transcript-collapse-fanout-cursor-cli-docs-update-7B2A756D.json"
		]
		var report: [String] = [
			"TRANSCRIPT_LIVE_VIEWMODEL_METRICS_BEGIN",
			"Fixtures: production transcript-collapse fixtures hydrated into AgentModeViewModel.TabSession; DEBUG-only instrumentation, no observable metric fields added",
			"Scenarios: fresh append turns with 1/2/7 tools; repeated single-tool cycles through session.appendItem live mutation refresh plus final manual rebuild"
		]

		for fixtureName in fixtureNames {
			let persistedSession = try loadFixtureSession(named: fixtureName)
			let fixture = try XCTUnwrap(persistedSession.transcript)
			let baseline = try await makeLiveMetricsSession(
				fixtureName: fixtureName,
				persistedSession: persistedSession,
				fixture: fixture,
				recorder: recorder
			)
			report.append(
				"baseline fixture=\(fixtureName) turns=\(fixture.turns.count) tierVector=\(tierVector(fixture)) frontier=\(fixture.compactionFrontier?.frozenPrefixTurnCount.description ?? "nil") sourceItems=\(baseline.session.items.count) rows=\(baseline.session.transcriptProjection.workingRows.count + baseline.session.transcriptProjection.archivedRows.count) blocks=\(baseline.session.transcriptProjection.workingBlocks.count + baseline.session.transcriptProjection.archivedBlocks.count) cacheCount=\(baseline.session.turnProjectionCaches.count) \(formatMetrics(baseline.metrics)) perf=\(formatPerformanceSnapshot(baseline.session.transcriptPerformanceSnapshot))"
			)

			for appendToolCount in [1, 2, 7] {
				let live = try await makeLiveMetricsSession(
					fixtureName: fixtureName,
					persistedSession: persistedSession,
					fixture: fixture,
					recorder: recorder
				)
				let operation = try runLiveViewModelAppendScenario(
					vm: live.vm,
					session: live.session,
					fixtureName: fixtureName,
					baselineTranscript: fixture,
					toolExecutionCount: appendToolCount,
					label: "\(fixtureName)-live-\(appendToolCount)",
					recorder: recorder
				)
				report.append(formatLiveOperationMetrics(operation, scenario: "append", fixtureName: fixtureName, ordinal: appendToolCount))
			}

			let repeated = try await makeLiveMetricsSession(
				fixtureName: fixtureName,
				persistedSession: persistedSession,
				fixture: fixture,
				recorder: recorder
			)
			for cycle in 1...3 {
				let operation = try runLiveViewModelAppendScenario(
					vm: repeated.vm,
					session: repeated.session,
					fixtureName: fixtureName,
					baselineTranscript: fixture,
					toolExecutionCount: 1,
					label: "\(fixtureName)-live-cycle-\(cycle)",
					recorder: recorder
				)
				report.append(formatLiveOperationMetrics(operation, scenario: "repeat", fixtureName: fixtureName, ordinal: cycle))
			}
		}

		report.append("TRANSCRIPT_LIVE_VIEWMODEL_METRICS_END")
		let reportText = report.joined(separator: "\n")
		let reportURL = liveTranscriptMetricsReportURL()
		try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try reportText.write(to: reportURL, atomically: true, encoding: .utf8)
		print(reportText)
	}

	@MainActor
	func testLongActiveCrawlFinalTurnRefreshBenchmarkReport() async throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["RP_RUN_TRANSCRIPT_METRICS"] == "1"
			|| ProcessInfo.processInfo.environment["RP_TRANSCRIPT_CRAWL_REFRESH_REPORT_PATH"] != nil
			|| FileManager.default.fileExists(atPath: crawlTranscriptRefreshOptInFlagURL().path),
			"Crawl transcript refresh benchmark is opt-in. Set RP_RUN_TRANSCRIPT_METRICS=1 or create the DEBUG test sentinel to enable."
		)
		let recorder = TranscriptInstrumentationRecorder()
		AgentTranscriptDebugInstrumentation.reset()
		AgentTranscriptDebugInstrumentation.isEnabled = true
		AgentTranscriptDebugInstrumentation.protectedTailScanHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.compactionHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.workingSourceItemsHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.rebuildHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.projectionBuildHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.refreshAttemptHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.presentationPublishHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.sessionItemsReplacementHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.projectionIdentityHandler = { recorder.record($0) }
		defer { AgentTranscriptDebugInstrumentation.reset() }

		let config = CrawlRefreshScenarioConfig()
		let aggregate = try await runCrawlRefreshBenchmark(config: config, recorder: recorder)
		let reportURL = crawlTranscriptRefreshReportURL()
		let benchmarkJSON = try crawlRefreshBenchmarkJSON(aggregate, reportURL: reportURL)
		let reportText = formatCrawlRefreshBenchmarkReport(aggregate, reportURL: reportURL, benchmarkJSON: benchmarkJSON)

		try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try reportText.write(to: reportURL, atomically: true, encoding: .utf8)
		print(reportText)
		print("CRAWL_TRANSCRIPT_REFRESH_BENCHMARK_JSON=\(benchmarkJSON)")
	}

	func testProductionTranscriptCollapseFixtureExtensionMetricsReport() throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["RP_RUN_TRANSCRIPT_METRICS"] == "1"
			|| ProcessInfo.processInfo.environment["RP_TRANSCRIPT_METRICS_REPORT_PATH"] != nil,
			"Transcript metric reports are opt-in. Set RP_RUN_TRANSCRIPT_METRICS=1 to enable."
		)
		let recorder = TranscriptInstrumentationRecorder()
		AgentTranscriptDebugInstrumentation.reset()
		AgentTranscriptDebugInstrumentation.isEnabled = true
		AgentTranscriptDebugInstrumentation.protectedTailScanHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.compactionHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.workingSourceItemsHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.rebuildHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.projectionBuildHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.refreshAttemptHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.presentationPublishHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.sessionItemsReplacementHandler = { recorder.record($0) }
		AgentTranscriptDebugInstrumentation.projectionIdentityHandler = { recorder.record($0) }
		defer { AgentTranscriptDebugInstrumentation.reset() }

		var report: [String] = [
			"TRANSCRIPT_TOOL_TAIL_METRICS_BEGIN",
			"Fixtures: production transcript extension simulations; DEBUG-only instrumentation, no observable session/UI state"
		]
		let fixtureNames = [
			"transcript-collapse-acp-steering-coalesce-A4B8CF7F.json",
			"transcript-collapse-fanout-cursor-cli-docs-update-7B2A756D.json"
		]

		for fixtureName in fixtureNames {
			let fixture = try loadFixtureTranscript(named: fixtureName)
			let baselineMark = recorder.mark()
			let baselineWorkingItems = AgentTranscriptIO.workingSourceItems(from: fixture)
			let baselineProjection = AgentTranscriptProjectionBuilder.build(from: fixture)
			let baselineMetrics = recorder.slice(since: baselineMark)
			report.append(
				"baseline fixture=\(fixtureName) turns=\(fixture.turns.count) frontier=\(fixture.compactionFrontier?.frozenPrefixTurnCount.description ?? "nil") workingSourceItems=\(baselineWorkingItems.count) projectionRows=\(baselineProjection.workingRows.count + baselineProjection.archivedRows.count) projectionBlocks=\(baselineProjection.workingBlocks.count + baselineProjection.archivedBlocks.count) \(formatMetrics(baselineMetrics))"
			)

			let originalTierByTurnID = Dictionary(uniqueKeysWithValues: fixture.turns.map { ($0.id, $0.retentionTier) })
			let originalFinalFullTurn = try XCTUnwrap(fixture.turns.last, "\(fixtureName) should have a final turn")
			let originalFinalSequences = sequenceIndexSet(for: originalFinalFullTurn)

			for appendToolCount in [1, 2, 7] {
				let mark = recorder.mark()
				let rebuilt = appendSyntheticVisibleToolTurn(
					to: fixture,
					toolExecutionCount: appendToolCount,
					label: "\(fixtureName)-metrics-\(appendToolCount)"
				)
				let projection = AgentTranscriptProjectionBuilder.build(from: rebuilt)
				let metrics = recorder.slice(since: mark)
				let rebuiltOriginalFinalTurn = try XCTUnwrap(rebuilt.turns.first { turn in
					!sequenceIndexSet(for: turn).isDisjoint(with: originalFinalSequences)
				})
				let appendedTurn = try XCTUnwrap(rebuilt.turns.last)
				let rebuildMetric = try XCTUnwrap(metrics.rebuilds.last)

				XCTAssertEqual(rebuiltOriginalFinalTurn.retentionTier, .full, "\(fixtureName) append \(appendToolCount)")
				XCTAssertEqual(appendedTurn.retentionTier, .full, "\(fixtureName) append \(appendToolCount)")
				XCTAssertEqual(appendedTurn.allActivities.filter { $0.itemKind == .toolCall }.count, appendToolCount)
				XCTAssertEqual(rebuildMetric.legacyNonFullTierWorseningCount, 0, "\(fixtureName) append \(appendToolCount) should not worsen legacy prefix")
				for (turnID, tier) in originalTierByTurnID where tier != .full {
					let rebuiltTurn = try XCTUnwrap(rebuilt.turns.first(where: { $0.id == turnID }))
					XCTAssertEqual(rebuiltTurn.retentionTier, tier, "\(fixtureName) append \(appendToolCount)")
				}

				report.append(
					"append fixture=\(fixtureName) tools=\(appendToolCount) \(formatMetrics(metrics)) projectionRows=\(projection.workingRows.count + projection.archivedRows.count) projectionBlocks=\(projection.workingBlocks.count + projection.archivedBlocks.count)"
				)
			}

			var rollingTranscript = fixture
			let repeatedOriginalSequences = originalFinalSequences
			for cycle in 1...3 {
				let mark = recorder.mark()
				rollingTranscript = appendSyntheticVisibleToolTurn(
					to: rollingTranscript,
					toolExecutionCount: 1,
					label: "\(fixtureName)-cycle-\(cycle)"
				)
				let projection = AgentTranscriptProjectionBuilder.build(from: rollingTranscript)
				let metrics = recorder.slice(since: mark)
				let originalFinalTurn = try XCTUnwrap(rollingTranscript.turns.first { turn in
					!sequenceIndexSet(for: turn).isDisjoint(with: repeatedOriginalSequences)
				})
				let rebuildMetric = try XCTUnwrap(metrics.rebuilds.last)

				XCTAssertEqual(originalFinalTurn.retentionTier, .full, "\(fixtureName) cycle \(cycle)")
				XCTAssertEqual(rebuildMetric.legacyNonFullTierWorseningCount, 0, "\(fixtureName) cycle \(cycle) should not worsen legacy prefix")
				report.append(
					"repeat fixture=\(fixtureName) cycle=\(cycle) \(formatMetrics(metrics)) projectionRows=\(projection.workingRows.count + projection.archivedRows.count) projectionBlocks=\(projection.workingBlocks.count + projection.archivedBlocks.count)"
				)
			}
		}

		let noCompactionMark = recorder.mark()
		let underThreshold = AgentTranscriptIO.importLegacyItems(makeLongTranscriptItems(turnCount: 2))
		let compactedUnderThreshold = AgentTranscriptCompactor.compact(underThreshold)
		let noCompactionMetrics = recorder.slice(since: noCompactionMark)
		XCTAssertEqual(compactedUnderThreshold.turns.count, underThreshold.turns.count)
		XCTAssertTrue(noCompactionMetrics.compactions.contains(where: \.softGuardSkippedScan))
		XCTAssertTrue(noCompactionMetrics.protectedTailScans.isEmpty, "Soft guard should skip protected-tail scan under threshold")
		report.append("under-threshold \(formatMetrics(noCompactionMetrics)) scans=\(noCompactionMetrics.protectedTailScans.count)")
		report.append("TRANSCRIPT_TOOL_TAIL_METRICS_END")
		let reportText = report.joined(separator: "\n")
		let reportURL = transcriptMetricsReportURL()
		try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try reportText.write(to: reportURL, atomically: true, encoding: .utf8)
		print(reportText)
	}
	#endif

	func testCompactedTurnsRetainFinalAssistantMessage() {
		// After compaction, every non-full turn must still contain its conclusion
		// assistant activity. This is the actual deliverable of each turn — stripping
		// it loses the user-visible answer.
		let items = makeLongTranscriptItems(turnCount: 40)
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let compacted = AgentTranscriptCompactor.compact(transcript)

		let nonFullTurns = compacted.turns.filter { $0.retentionTier != .full }
		XCTAssertFalse(nonFullTurns.isEmpty, "Need at least one compacted turn for this test")

		for (index, turn) in compacted.turns.enumerated() {
			guard turn.retentionTier != .full else { continue }
			// The turn must still have its conclusion activity
			XCTAssertNotNil(
				turn.conclusionActivityID,
				"Turn \(index) (\(turn.retentionTier)) lost its conclusionActivityID"
			)
			// The actual activity must still be present in a span
			let conclusionActivity = turn.allActivities.first(where: { $0.id == turn.conclusionActivityID })
			XCTAssertNotNil(
				conclusionActivity,
				"Turn \(index) (\(turn.retentionTier)) lost its conclusion activity data"
			)
			// It should be the final assistant summary text
			XCTAssertTrue(
				conclusionActivity?.text.contains("final summary") == true,
				"Turn \(index) conclusion text doesn't match expected: \(conclusionActivity?.text ?? "nil")"
			)
		}
	}

	func testInspectCompactedFixtureContents() throws {
		let fixtures = [
			"long-session-78turns-414068FC.json",
			"mixed-tiers-37turns-921E33DA.json",
			"archived-43turns-76D2C176.json"
		]
		var out = ""
		for fixtureName in fixtures {
			let transcript: AgentTranscript
			do {
				transcript = try loadFixtureTranscript(named: fixtureName)
			} catch {
				out += "=== SKIP \(fixtureName): \(error) ===\n\n"
				continue
			}

			let persisted = AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript)
			let compacted = persisted.transcript

			out += "=== \(fixtureName): \(compacted.turns.count) turns ===\n"
			var tierCounts: [String: Int] = [:]
			for turn in compacted.turns { tierCounts["\(turn.retentionTier)", default: 0] += 1 }
			out += "Tiers: \(tierCounts)\n\n"

			for (i, turn) in compacted.turns.enumerated() {
				let activities = turn.allActivities
				let requestText = String((turn.request?.text ?? "(none)").prefix(80))
				out += "Turn \(i) [\(turn.retentionTier)]"
				out += " req=\"\(requestText)\""
				out += " conclusionID=\(turn.conclusionActivityID != nil ? "yes" : "nil")"
				out += " activities=\(activities.count)"
				if activities.isEmpty {
					out += " ⚠️ NO ACTIVITIES"
				}
				out += "\n"
				for act in activities {
					let textPreview = String(act.text.prefix(120)).replacingOccurrences(of: "\n", with: "\\n")
					out += "  → \(act.role): \"\(textPreview)\"\n"
				}
			}
			out += "\n"
		}

		let url = FileManager.default.temporaryDirectory.appendingPathComponent("compaction-inspection.txt")
		try out.write(toFile: url.path, atomically: true, encoding: .utf8)
		XCTAssertTrue(true)
	}

	func testSingleOversizedCompletedTurnRemainsFullWithNoProtection() {
		// Edge case: only one turn in the session, but it's massive
		let items = makeToolHeavyTurnItems(
			toolNames: Array(repeating: "read_file", count: 40)
		)
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let compacted = AgentTranscriptCompactor.compact(transcript, protection: .none)

		// The sole turn must remain .full — there are no older candidates
		XCTAssertEqual(compacted.turns.count, 1)
		XCTAssertEqual(compacted.turns.first?.retentionTier, .full)
		XCTAssertGreaterThan(compacted.turns.first?.allActivities.count ?? 0, 0)
	}

	func testHighSignalToolActivitiesStayStandaloneAndGroupedByExecution() throws {
		let invocationID = UUID()
		let items: [AgentChatItem] = [
			AgentChatItem.user("Apply the fix", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "applying the patch", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "apply_edits", invocationID: invocationID, argsJSON: "{\"path\":\"Parser.swift\"}", sequenceIndex: 2),
			AgentChatItem.toolResult(name: "apply_edits", invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem.assistant("final summary", sequenceIndex: 4)
		]

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)

		XCTAssertEqual(blocks.map(\.kind), [.request, .standaloneAssistant, .standaloneTool, .conclusion])
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(
			blocks.flatMap(\.rows).filter { $0.kind == .toolCall || $0.kind == .toolResult }.map(\.kind),
			[.toolCall, .toolResult]
		)
	}

	func testShortFinalAssistantStillBecomesConclusionAnchor() throws {
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "checking parser", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "read_file", invocationID: nil, argsJSON: "{\"path\":\"Parser.swift\"}", sequenceIndex: 2),
			AgentChatItem.toolResult(name: "read_file", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem.assistant("Fixed it.", sequenceIndex: 4)
		]

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)

		XCTAssertEqual(blocks.map(\.kind), [.request, .standaloneAssistant, .standaloneTool, .conclusion])
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(blocks.last?.rows.first?.text, "Fixed it.")
	}

	func testProjectionBlocksStaySequenceOrderedWhenAnAssistantPrecedesALaterTool() throws {
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem.assistant("Interim answer", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "read_file", invocationID: nil, argsJSON: "{\"path\":\"Parser.swift\"}", sequenceIndex: 2)
		]

		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let turn = try XCTUnwrap(transcript.turns.first)
		let turnBlocks = projection.workingBlocks.filter { $0.turnID == turn.id }
		let projectedSequenceOrder = turnBlocks.flatMap { $0.rows.map(\.sequenceIndex) }

		XCTAssertNil(turn.conclusionActivityID)
		XCTAssertEqual(projectedSequenceOrder, [0, 1, 2])
		XCTAssertEqual(turnBlocks.first?.kind, .request)
		XCTAssertFalse(turnBlocks.contains(where: { $0.kind == .conclusion }))
		XCTAssertEqual(turnBlocks.dropFirst().flatMap { $0.rows.map(\.sequenceIndex) }, [1, 2])
	}

	func testBuildTranscriptFiltersHiddenCoordinationToolsFromCanonicalTranscript() {
		let items: [AgentChatItem] = [
			AgentChatItem.user("Start", sequenceIndex: 0),
			AgentChatItem.toolCall(name: "set_status", invocationID: nil, argsJSON: #"{"text":"Thinking"}"#, sequenceIndex: 1),
			AgentChatItem.toolResult(name: "set_status", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 2),
			AgentChatItem.assistant("Done", sequenceIndex: 3)
		]

		let transcript = AgentTranscriptIO.buildTranscript(
			from: items,
			nextSequenceIndex: 4,
			policy: .canonical,
			compact: false
		)
		let rows = AgentTranscriptIO.flattenFullTranscript(transcript)

		XCTAssertEqual(rows.map(\.kind), [.user, .assistant])
		XCTAssertEqual(rows.map(\.text), ["Start", "Done"])
	}

	func testProjectionClustersVisibleAssistantFragmentsAcrossFilteredHiddenBoundary() throws {
		let items: [AgentChatItem] = [
			AgentChatItem.user("Start", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "Thinking through the request", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "set_status", invocationID: nil, argsJSON: #"{"text":"Checking"}"#, sequenceIndex: 2),
			AgentChatItem.toolResult(name: "set_status", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 4), kind: .assistantInline, text: "Still working through it", sequenceIndex: 4),
			AgentChatItem.assistant("Done", sequenceIndex: 5)
		]

		let transcript = AgentTranscriptIO.buildTranscript(
			from: items,
			nextSequenceIndex: 6,
			policy: .canonical,
			compact: false
		)
		let blocks = AgentTranscriptProjectionBuilder.build(from: transcript).workingBlocks

		XCTAssertEqual(blocks.map(\.kind), [.request, .standaloneAssistant, .standaloneAssistant, .conclusion])
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(blocks.dropFirst().dropLast().flatMap(\.rows).map(\.sequenceIndex), [1, 4])
	}

	func testIncrementalFinalTurnRebuildMatchesFullRebuildForTailToolReplacement() throws {
		let invocationID = UUID()
		let livePolicy = AgentTranscriptImportPolicy.liveSession(hidePendingQuestionToolCall: false)
		let initialItems: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "Checking parser", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "read_file", invocationID: invocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 2)
		]
		let updatedItems: [AgentChatItem] = [
			initialItems[0],
			initialItems[1],
			AgentChatItem.toolResult(name: "read_file", invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 2)
		]

		let existingTranscript = AgentTranscriptIO.buildTranscript(
			from: initialItems,
			terminalState: .running,
			nextSequenceIndex: 3,
			policy: livePolicy
		)
		let incrementalTranscript = AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
			existingTranscript: existingTranscript,
			items: updatedItems,
			earliestChangedIndex: 2,
			terminalState: .running,
			nextSequenceIndex: 3,
			policy: livePolicy
		)
		let fullTranscript = AgentTranscriptIO.buildTranscript(
			from: updatedItems,
			terminalState: .running,
			nextSequenceIndex: 3,
			policy: livePolicy
		)

		XCTAssertEqual(incrementalTranscript, fullTranscript)
	}

	func testIncrementalFinalTurnRebuildReturnsNilWhenMutationPrecedesFinalTurnBoundary() {
		let livePolicy = AgentTranscriptImportPolicy.liveSession(hidePendingQuestionToolCall: false)
		let items: [AgentChatItem] = [
			AgentChatItem.user("First", sequenceIndex: 0),
			AgentChatItem.assistant("Done first", sequenceIndex: 1),
			AgentChatItem.user("Second", sequenceIndex: 2),
			AgentChatItem.assistant("Working second", sequenceIndex: 3)
		]
		let existingTranscript = AgentTranscriptIO.buildTranscript(
			from: items,
			terminalState: .running,
			nextSequenceIndex: 4,
			policy: livePolicy
		)

		let incrementalTranscript = AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
			existingTranscript: existingTranscript,
			items: items,
			earliestChangedIndex: 1,
			terminalState: .running,
			nextSequenceIndex: 4,
			policy: livePolicy
		)

		XCTAssertNil(incrementalTranscript)
	}

	func testIncrementalFinalTurnRebuildMatchesFullRebuildWhenOlderTurnsAreDurablyCompacted() {
		let livePolicy = AgentTranscriptImportPolicy.liveSession(hidePendingQuestionToolCall: false)
		let initialItems = makeLongTranscriptItems(turnCount: 40)
		let compactedTranscript = AgentTranscriptIO.buildTranscript(
			from: initialItems,
			terminalState: .running,
			nextSequenceIndex: initialItems.count,
			policy: livePolicy
		)
		XCTAssertTrue(compactedTranscript.turns.dropLast().contains(where: { $0.retentionTier != .full }))
		XCTAssertNotNil(compactedTranscript.compactionFrontier)

		let lastTurnStartIndex = initialItems.lastIndex(where: { $0.kind == .user })!
		var updatedItems = initialItems
		updatedItems[updatedItems.count - 1] = AgentChatItem.assistant("updated final summary", sequenceIndex: updatedItems.count - 1)
		let incrementalTranscript = AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
			existingTranscript: compactedTranscript,
			items: updatedItems,
			earliestChangedIndex: lastTurnStartIndex,
			terminalState: .running,
			nextSequenceIndex: updatedItems.count,
			policy: livePolicy
		)
		let fullTranscript = AgentTranscriptIO.buildTranscript(
			from: updatedItems,
			terminalState: .running,
			nextSequenceIndex: updatedItems.count,
			policy: livePolicy
		)

		XCTAssertEqual(incrementalTranscript, fullTranscript)
	}

	func testIncrementalFinalTurnRebuildReturnsNilWhenCompactionFrontierIsInvalid() {
		let livePolicy = AgentTranscriptImportPolicy.liveSession(hidePendingQuestionToolCall: false)
		let initialItems = makeLongTranscriptItems(turnCount: 40)
		var compactedTranscript = AgentTranscriptIO.buildTranscript(
			from: initialItems,
			terminalState: .running,
			nextSequenceIndex: initialItems.count,
			policy: livePolicy
		)
		compactedTranscript.compactionFrontier = AgentTranscriptCompactionFrontier(
			frozenPrefixTurnCount: compactedTranscript.compactionFrontier?.frozenPrefixTurnCount ?? 1,
			lastFrozenTurnID: UUID()
		)

		let lastTurnStartIndex = initialItems.lastIndex(where: { $0.kind == .user })!
		let incrementalTranscript = AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
			existingTranscript: compactedTranscript,
			items: initialItems,
			earliestChangedIndex: lastTurnStartIndex,
			terminalState: .running,
			nextSequenceIndex: initialItems.count,
			policy: livePolicy
		)

		XCTAssertNil(incrementalTranscript)
	}

	func testToolProcessingContextRecordsParseCacheAndRegexMetrics() throws {
		let context = AgentToolResultProcessingContext()
		let rawJSON = #"{"status":"success","exitCode":0}"#

		XCTAssertNotNil(context.jsonObject(from: rawJSON))
		XCTAssertNotNil(context.jsonObject(from: rawJSON))
		_ = BashToolResultParser.parseMetadata(raw: rawJSON, context: context)
		_ = BashToolResultParser.parseMetadata(raw: rawJSON, context: context)

		let invocationID = UUID()
		let item = AgentChatItem.toolResult(
			name: "bash",
			invocationID: invocationID,
			resultJSON: rawJSON,
			isError: false,
			sequenceIndex: 1
		)
		XCTAssertNotNil(AgentTranscriptToolNormalizer.toolExecution(for: item, context: context))
		XCTAssertNotNil(AgentTranscriptToolNormalizer.toolExecution(for: item, context: context))

		let runningText = "process running with session id abc"
		let runningItem = AgentChatItem.toolResult(
			name: "bash",
			invocationID: UUID(),
			resultJSON: runningText,
			isError: nil,
			sequenceIndex: 2
		)
		let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: runningItem, context: context))
		XCTAssertEqual(sanitized.processID, "abc")

		let metrics = context.snapshotMetrics()
		XCTAssertGreaterThanOrEqual(metrics.jsonParseAttemptCount, 2)
		XCTAssertGreaterThanOrEqual(metrics.jsonParseCacheHitCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.jsonParseCacheMissCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.jsonParseSuccessCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.toolExecutionCacheHitCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.toolExecutionCacheMissCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.bashMetadataCacheHitCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.bashMetadataCacheMissCount, 1)
		XCTAssertGreaterThanOrEqual(metrics.regexCaptureCallCount, 1)
	}

	func testPartialSanitizeReuseMatchesFullSanitizeForIncrementalTailUpdate() throws {
		let livePolicy = AgentTranscriptImportPolicy.liveSession(hidePendingQuestionToolCall: false)
		let initialItems = makeLongTranscriptItems(turnCount: 40)
		let previousSanitizedTranscript = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
			AgentTranscriptIO.buildTranscript(
				from: initialItems,
				terminalState: .running,
				nextSequenceIndex: initialItems.count,
				policy: livePolicy
			)
		).transcript
		var updatedItems = initialItems
		let lastTurnStartIndex = try XCTUnwrap(updatedItems.lastIndex(where: { $0.kind == .user }))
		updatedItems[updatedItems.count - 1] = AgentChatItem.assistant(
			"updated final summary",
			sequenceIndex: updatedItems.count - 1
		)
		let incrementallyUpdatedTranscript = try XCTUnwrap(
			AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
				existingTranscript: previousSanitizedTranscript,
				items: updatedItems,
				earliestChangedIndex: lastTurnStartIndex,
				terminalState: .running,
				nextSequenceIndex: updatedItems.count,
				policy: livePolicy
			)
		)

		let partialSanitize = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
			incrementallyUpdatedTranscript,
			previousSanitizedTranscript: previousSanitizedTranscript,
			reusablePrefixTurnCount: previousSanitizedTranscript.turns.count - 1
		)
		let fullSanitize = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
			incrementallyUpdatedTranscript
		)

		let expectedReusableTurnCount = zip(
			incrementallyUpdatedTranscript.turns,
			previousSanitizedTranscript.turns
		).prefix { currentTurn, previousTurn in
			currentTurn.retentionTier != .full
				&& previousTurn.retentionTier != .full
				&& currentTurn == previousTurn
		}.count

		XCTAssertEqual(partialSanitize.transcript, fullSanitize.transcript)
		XCTAssertEqual(partialSanitize.reusedTurnCount, expectedReusableTurnCount)
	}

	func testFrozenPrefixProjectionReuseMatchesFullProjectionBuild() throws {
		let livePolicy = AgentTranscriptImportPolicy.liveSession(hidePendingQuestionToolCall: false)
		let initialItems = makeLongTranscriptItems(turnCount: 40)
		let previousSanitizedTranscript = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
			AgentTranscriptIO.buildTranscript(
				from: initialItems,
				terminalState: .running,
				nextSequenceIndex: initialItems.count,
				policy: livePolicy
			)
		).transcript
		let previousProjection = AgentTranscriptProjectionBuilder.build(from: previousSanitizedTranscript)
		var updatedItems = initialItems
		let lastTurnStartIndex = try XCTUnwrap(updatedItems.lastIndex(where: { $0.kind == .user }))
		updatedItems[updatedItems.count - 1] = AgentChatItem.assistant(
			"updated final summary",
			sequenceIndex: updatedItems.count - 1
		)
		let incrementallyUpdatedTranscript = try XCTUnwrap(
			AgentTranscriptIO.incrementallyUpdatedTranscriptForFinalTurn(
				existingTranscript: previousSanitizedTranscript,
				items: updatedItems,
				earliestChangedIndex: lastTurnStartIndex,
				terminalState: .running,
				nextSequenceIndex: updatedItems.count,
				policy: livePolicy
			)
		)
		let sanitizedTranscript = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
			incrementallyUpdatedTranscript,
			previousSanitizedTranscript: previousSanitizedTranscript,
			reusablePrefixTurnCount: previousSanitizedTranscript.turns.count - 1
		).transcript
		let reusableFrozenPrefixTurnCount = AgentTranscriptIO.validatedReusableFrozenPrefixTurnCount(in: sanitizedTranscript)
		if let reusableFrozenPrefixTurnCount {
			// Non-full turns now retain their conclusionActivityID and conclusion activity
			// to preserve the final assistant message through compaction.
			XCTAssertGreaterThan(reusableFrozenPrefixTurnCount, 0)
		}
		let fullProjection = AgentTranscriptProjectionBuilder.build(from: sanitizedTranscript)

		guard let reusableFrozenPrefixTurnCount else {
			XCTAssertNil(
				AgentTranscriptProjectionBuilder.buildReusingFrozenPrefix(
					from: sanitizedTranscript,
					previousTranscript: previousSanitizedTranscript,
					previousProjection: previousProjection,
					previousProtection: .none,
					protection: .none,
					reusableFrozenPrefixTurnCount: 0
				)
			)
			return
		}

		let reusedProjection = try XCTUnwrap(
			AgentTranscriptProjectionBuilder.buildReusingFrozenPrefix(
				from: sanitizedTranscript,
				previousTranscript: previousSanitizedTranscript,
				previousProjection: previousProjection,
				previousProtection: .none,
				protection: .none,
				reusableFrozenPrefixTurnCount: reusableFrozenPrefixTurnCount
			)
		)

		let blockSignature: (AgentTranscriptRenderBlock) -> String = { block in
			let rowIDs = block.rows.map(\.id.uuidString).joined(separator: ",")
			return "\(block.id)|\(block.kind)|\(block.turnID.uuidString)|\(block.retentionTier)|\(rowIDs)"
		}
		XCTAssertEqual(reusedProjection.workingBlocks.map(blockSignature), fullProjection.workingBlocks.map(blockSignature))
		XCTAssertEqual(reusedProjection.archivedBlocks.map(blockSignature), fullProjection.archivedBlocks.map(blockSignature))
		XCTAssertEqual(reusedProjection.workingRows.map(\.id), fullProjection.workingRows.map(\.id))
		XCTAssertEqual(reusedProjection.archivedRows.map(\.id), fullProjection.archivedRows.map(\.id))
		XCTAssertEqual(reusedProjection.rowAnchorIndex, fullProjection.rowAnchorIndex)
		XCTAssertEqual(reusedProjection.anchorBlockIndex, fullProjection.anchorBlockIndex)
		XCTAssertEqual(reusedProjection, fullProjection)
	}

	func testImportLegacyItemsLeavesTrailingTurnOpenWhenRunIsStillActive() throws {
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "Checking parser", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "read_file", invocationID: nil, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 2)
		]

		let transcript = AgentTranscriptIO.importLegacyItems(items, terminalState: .running)
		let turn = try XCTUnwrap(transcript.turns.first)
		let span = try XCTUnwrap(turn.responseSpans.first)

		XCTAssertFalse(turn.isCompleted)
		XCTAssertNil(turn.completedAt)
		XCTAssertEqual(turn.lastActivityAt, items.last?.timestamp)
		XCTAssertEqual(turn.terminalState, .running)
		XCTAssertEqual(span.lifecycle, .open)
		XCTAssertNil(span.completedAt)
		XCTAssertEqual(span.lastActivityAt, items.last?.timestamp)
	}

	func testProjectionCompactsIncompleteLiveTurnAfterGlobalDetailedToolLimit() throws {
		let items = Array(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		]).dropLast())
		let transcript = AgentTranscriptIO.importLegacyItems(items, terminalState: .running)
		let turn = try XCTUnwrap(transcript.turns.first)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let blocks = projection.workingBlocks.filter { $0.turnID == turn.id }
		let groupedHistory = try XCTUnwrap(blocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory)

		XCTAssertFalse(turn.isCompleted)
		XCTAssertEqual(groupedHistory.summary.hiddenToolCardCount, 1)
		XCTAssertEqual(blocks.filter { $0.kind == .standaloneTool }.count, 8)
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertTrue(projection.workingRows.contains(where: { $0.kind == .assistantInline && $0.text == "step 1" }))
		XCTAssertTrue(projection.workingRows.contains(where: { $0.kind == .assistantInline && $0.text == "step 5" }))
		XCTAssertTrue(projection.workingRows.contains(where: { $0.kind == .toolCall && $0.sequenceIndex == 26 }))
	}

	func testProjectedVisibleRowCountMatchesProjectionForIncompleteLiveTurn() throws {
		let items = Array(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		]).dropLast())
		let transcript = AgentTranscriptIO.importLegacyItems(items, terminalState: .running)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

		XCTAssertEqual(
			AgentTranscriptProjectionBuilder.projectedVisibleRowCount(for: transcript),
			presentedItemCount(for: projection.workingBlocks) + presentedItemCount(for: projection.archivedBlocks)
		)
		XCTAssertEqual(
			AgentTranscriptProjectionBuilder.estimatedWorkingUnitCount(for: transcript),
			projection.workingUnitCount
		)
	}

	func testProjectionCountsIncludeCollapsedGroupedHistorySummaryRow() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		]))
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let counts = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)

		XCTAssertEqual(
			counts.canonicalVisibleRowCount,
			presentedItemCount(for: projection.workingBlocks) + presentedItemCount(for: projection.archivedBlocks)
		)
		XCTAssertEqual(counts.defaultPresentedRowCount, presentedItemCount(for: projection.workingBlocks))
		XCTAssertEqual(
			counts.canonicalVisibleRowCount,
			AgentTranscriptProjectionBuilder.projectedVisibleRowCount(for: transcript)
		)
		XCTAssertEqual(counts.canonicalVisibleRowCount, projection.workingRows.count + 1)
	}

	func testProjectionCountsHideArchivedRowsUntilCompressedHistoryIsRevealed() throws {
		let compacted = AgentTranscriptCompactor.compact(
			AgentTranscriptIO.importLegacyItems(makeLongTranscriptItems(turnCount: 40))
		)
		let projection = AgentTranscriptProjectionBuilder.build(from: compacted)
		let counts = AgentTranscriptProjectionBuilder.projectionCounts(for: compacted)

		XCTAssertFalse(projection.archivedBlocks.isEmpty)
		XCTAssertEqual(counts.defaultPresentedRowCount, presentedItemCount(for: projection.workingBlocks))
		XCTAssertEqual(
			counts.canonicalVisibleRowCount,
			presentedItemCount(for: projection.workingBlocks) + presentedItemCount(for: projection.archivedBlocks)
		)
		XCTAssertGreaterThan(counts.hiddenArchivedRowCount, 0)
	}

	func testWorkingProjectionDropsArchivedPrefixState() throws {
		let compacted = AgentTranscriptCompactor.compact(
			AgentTranscriptIO.importLegacyItems(makeLongTranscriptItems(turnCount: 40))
		)
		let fullProjection = AgentTranscriptProjectionBuilder.build(from: compacted)
		let workingProjection = AgentTranscriptProjectionBuilder.workingProjection(from: fullProjection)
		let workingRowIDs = Set(fullProjection.workingRows.map(\.id))
		let workingBlockIDs = Set(fullProjection.workingBlocks.map(\.id))

		XCTAssertFalse(fullProjection.archivedBlocks.isEmpty)
		XCTAssertEqual(workingProjection.workingBlocks, fullProjection.workingBlocks)
		XCTAssertEqual(workingProjection.workingRows, fullProjection.workingRows)
		XCTAssertTrue(workingProjection.archivedBlocks.isEmpty)
		XCTAssertTrue(workingProjection.archivedRows.isEmpty)
		XCTAssertEqual(Set(workingProjection.rowAnchorIndex.keys), Set(workingProjection.workingRows.map(\.id)))
		XCTAssertEqual(Set(workingProjection.rowAnchorIndex.keys), workingRowIDs)
		XCTAssertTrue(workingProjection.anchorBlockIndex.values.allSatisfy { workingBlockIDs.contains($0) })
	}

	func testArchivedSnapshotRetainsArchivedPrefixStateAndCounts() throws {
		let compacted = AgentTranscriptCompactor.compact(
			AgentTranscriptIO.importLegacyItems(makeLongTranscriptItems(turnCount: 40))
		)
		let fullProjection = AgentTranscriptProjectionBuilder.build(from: compacted)
		let snapshot = AgentTranscriptProjectionBuilder.archivedSnapshot(from: fullProjection)
		let archivedRowIDs = Set(fullProjection.archivedRows.map(\.id))
		let archivedBlockIDs = Set(fullProjection.archivedBlocks.map(\.id))

		XCTAssertEqual(snapshot.blocks, fullProjection.archivedBlocks)
		XCTAssertEqual(snapshot.rows, fullProjection.archivedRows)
		XCTAssertEqual(snapshot.presentedRowCount, presentedItemCount(for: fullProjection.archivedBlocks))
		XCTAssertEqual(snapshot.blockCount, fullProjection.archivedBlocks.count)
		XCTAssertEqual(snapshot.compressedItems, fullProjection.archivedRows.map { .single($0) })
		XCTAssertEqual(Set(snapshot.rowAnchorIndex.keys), archivedRowIDs)
		XCTAssertTrue(snapshot.anchorBlockIndex.values.allSatisfy { archivedBlockIDs.contains($0) })
		XCTAssertTrue(snapshot.historyState.hasArchivedHistory)
		XCTAssertGreaterThan(snapshot.historyState.presentedRowCount, 0)
	}

	func testTranscriptSanitizationPreservesVisibleStandaloneToolPayloads() throws {
		let invocationID = UUID()
		let rawPatchResult = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}"#
		let items: [AgentChatItem] = [
			AgentChatItem.user("Patch it", sequenceIndex: 0),
			AgentChatItem.toolCall(name: "apply_patch", invocationID: invocationID, argsJSON: #"{"path":"/tmp/file.swift","change_count":1}"#, sequenceIndex: 1),
			AgentChatItem.toolResult(name: "apply_patch", invocationID: invocationID, resultJSON: rawPatchResult, isError: false, sequenceIndex: 2)
		]

		let sanitized = AgentToolResultPersistencePolicy.sanitizeTranscript(AgentTranscriptIO.importLegacyItems(items))
		let activity = try XCTUnwrap(sanitized.turns.first?.responseSpans.first?.activities.last)
		let execution = try XCTUnwrap(activity.toolExecution)
		let flattenedResult = AgentTranscriptIO.flattenFullTranscript(sanitized).last

		XCTAssertTrue(execution.resultJSON?.contains("@@ -1 +1 @@") == true)
		XCTAssertTrue(activity.text.contains("@@ -1 +1 @@"))
		XCTAssertEqual(activity.text, execution.resultJSON)
		XCTAssertEqual(flattenedResult?.toolResultJSON, rawPatchResult)
		XCTAssertEqual(flattenedResult?.text, rawPatchResult)
	}

	func testTranscriptSanitizationSummarizesHiddenGroupedToolPayloads() throws {
		var items = makeToolHeavyTurnItems(toolNames: Array(repeating: "read_file", count: 10))
		let hiddenPayload = #"{"status":"success","payload":"FIRST-HIDDEN-PAYLOAD"}"#
		let firstToolResultIndex = try XCTUnwrap(items.firstIndex(where: { $0.kind == .toolResult }))
		items[firstToolResultIndex].toolResultJSON = hiddenPayload
		items[firstToolResultIndex].text = hiddenPayload

		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let rawProjection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let visibleResultIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: rawProjection)
		let sanitized = AgentToolResultPersistencePolicy.sanitizeTranscript(transcript)
		let hiddenResult = try XCTUnwrap(sanitized.turns.first?.allActivities.first(where: {
			$0.itemKind == .toolResult && !visibleResultIDs.contains($0.id)
		}))
		let execution = try XCTUnwrap(hiddenResult.toolExecution)

		XCTAssertFalse(execution.resultJSON?.contains("FIRST-HIDDEN-PAYLOAD") == true)
		XCTAssertTrue(execution.resultJSON?.contains(#""summary_only":true"#) == true)
		XCTAssertEqual(hiddenResult.text, execution.resultJSON)
	}

	func testRuntimeSanitizationRetainsPromptExportMetadataEnvelope() throws {
		let promptSentinel = "RUNTIME-PROMPT-EXPORT-TEXT-SENTINEL"
		let arbitrarySentinel = "RUNTIME-PROMPT-EXPORT-ARBITRARY-PAYLOAD"
		let raw = try promptExportEnvelopeJSON(
			path: "/tmp/RepoPrompt-export.md",
			tokens: 1234,
			bytes: 5678,
			files: [
				[
					"path": "Sources/App.swift",
					"tokens": 321,
					"render_mode": "full",
					"is_auto": false,
					"content": promptSentinel
				]
			],
			copyPreset: [
				"id": "copy-preset-id",
				"name": "Compact Export",
				"kind": "builtIn",
				"is_built_in": true
			],
			extraExportFields: ["prompt": promptSentinel],
			extraEnvelopeFields: ["payload": arbitrarySentinel]
		)
		let invocationID = UUID()
		let items: [AgentChatItem] = [
			.user("Export prompt", sequenceIndex: 0),
			.toolResult(name: "mcp__RepoPrompt__prompt", invocationID: invocationID, resultJSON: raw, isError: false, sequenceIndex: 1)
		]

		let metrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
			AgentTranscriptIO.importLegacyItems(items),
			purpose: .runtimePresentation
		)
		let resultActivity = try XCTUnwrap(metrics.transcript.turns.first?.allActivities.first(where: { $0.itemKind == .toolResult }))
		let execution = try XCTUnwrap(resultActivity.toolExecution)
		let resultJSON = try XCTUnwrap(execution.resultJSON)
		let envelope = try decodePromptToolEnvelope(resultJSON)
		let export = try XCTUnwrap(envelope.export)
		let encoded = String(data: try JSONEncoder().encode(metrics.transcript), encoding: .utf8) ?? ""

		XCTAssertEqual(envelope.op, "export")
		XCTAssertEqual(export.path, "/tmp/RepoPrompt-export.md")
		XCTAssertEqual(export.tokens, 1234)
		XCTAssertEqual(export.bytes, 5678)
		XCTAssertEqual(export.copyPreset?.name, "Compact Export")
		XCTAssertFalse(execution.summaryOnly)
		XCTAssertFalse(resultJSON.contains(#""summary_only":true"#))
		XCTAssertFalse(resultJSON.contains(#""summaryOnly":true"#))
		XCTAssertFalse(encoded.contains(promptSentinel))
		XCTAssertFalse(encoded.contains(arbitrarySentinel))
		XCTAssertEqual(resultActivity.text, resultJSON)
	}

	func testPersistentStorageRetainsPromptExportMetadataEnvelope() throws {
		let promptSentinel = "PERSISTENT-PROMPT-EXPORT-TEXT-SENTINEL"
		let raw = try promptExportEnvelopeJSON(
			path: "/tmp/persisted-prompt-export.md",
			tokens: 222,
			bytes: 333,
			files: [
				[
					"path": "Sources/Persisted.swift",
					"tokens": 111,
					"renderMode": "slice",
					"isAuto": true,
					"content": promptSentinel
				]
			],
			copyPreset: [
				"id": "persisted-copy-preset-id",
				"name": "Persistent Export",
				"isBuiltIn": false
			],
			extraExportFields: ["prompt_text": promptSentinel]
		)

		let persisted = try persistedToolResultActivity(toolName: "prompt", resultJSON: raw, argsJSON: #"{"op":"export"}"#)
		let resultJSON = try XCTUnwrap(persisted.execution.resultJSON)
		let envelope = try decodePromptToolEnvelope(resultJSON)
		let export = try XCTUnwrap(envelope.export)

		XCTAssertEqual(envelope.op, "export")
		XCTAssertEqual(export.path, "/tmp/persisted-prompt-export.md")
		XCTAssertEqual(export.tokens, 222)
		XCTAssertEqual(export.bytes, 333)
		XCTAssertEqual(export.copyPreset?.id, "persisted-copy-preset-id")
		XCTAssertEqual(export.copyPreset?.name, "Persistent Export")
		XCTAssertFalse(persisted.execution.summaryOnly)
		XCTAssertNil(persisted.execution.argsJSON)
		XCTAssertEqual(persisted.execution.keyPaths, [])
		XCTAssertFalse(resultJSON.contains(#""summary_only":true"#))
		XCTAssertFalse(resultJSON.contains(#""summaryOnly":true"#))
		XCTAssertFalse(persisted.encoded.contains(promptSentinel))
		XCTAssertEqual(persisted.activity.text, resultJSON)
	}

	func testPromptNonExportResultDoesNotRetainPromptEnvelopeMetadata() throws {
		let promptSentinel = "PROMPT-NON-EXPORT-TEXT-SENTINEL"
		let raw = #"{"op":"get","prompt":{"prompt":"__SENTINEL__","lines":1}}"#
			.replacingOccurrences(of: "__SENTINEL__", with: promptSentinel)

		let persisted = try persistedToolResultActivity(toolName: "prompt", resultJSON: raw)
		let resultJSON = try XCTUnwrap(persisted.execution.resultJSON)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: resultJSON))

		XCTAssertTrue(persisted.execution.summaryOnly)
		XCTAssertTrue(ToolRawJSON.bool(resultObject, key: "summary_only") == true)
		XCTAssertNil(resultObject["export"])
		XCTAssertFalse(persisted.encoded.contains(promptSentinel))
	}

	func testPromptExportMetadataRetentionDropsOversizedCopyPresetKindBeforeCoreMetadata() throws {
		let longPath = "/tmp/" + String(repeating: "p", count: 507)
		let raw = try promptExportEnvelopeJSON(
			path: longPath,
			tokens: 1,
			bytes: 2,
			files: [],
			copyPreset: [
				"id": String(repeating: "i", count: 512),
				"name": String(repeating: "n", count: 512),
				"kind": String(repeating: "k", count: 512),
				"is_built_in": true
			]
		)

		let persisted = try persistedToolResultActivity(toolName: "prompt", resultJSON: raw)
		let resultJSON = try XCTUnwrap(persisted.execution.resultJSON)
		let envelope = try decodePromptToolEnvelope(resultJSON)
		let export = try XCTUnwrap(envelope.export)

		XCTAssertFalse(persisted.execution.summaryOnly)
		XCTAssertLessThanOrEqual(resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertEqual(export.path, longPath)
		XCTAssertEqual(export.tokens, 1)
		XCTAssertEqual(export.bytes, 2)
		XCTAssertNotNil(export.copyPreset)
		XCTAssertNil(export.copyPreset?.kind)
	}

	func testPromptExportMetadataRetentionCapsOversizedFilesAndDropsPromptText() throws {
		let promptSentinel = "OVERSIZED-PROMPT-EXPORT-TEXT-SENTINEL"
		let fileContentSentinel = "OVERSIZED-PROMPT-EXPORT-FILE-CONTENT-SENTINEL"
		let files: [[String: Any]] = (0..<80).map { index in
			[
				"path": "Sources/File\(index).swift",
				"tokens": index + 1,
				"render_mode": "full",
				"is_auto": false,
				"content": "\(fileContentSentinel)-\(index)"
			]
		}
		let raw = try promptExportEnvelopeJSON(
			path: "/tmp/oversized-prompt-export.md",
			tokens: 9999,
			bytes: 8888,
			files: files,
			copyPreset: [
				"id": "oversized-copy-preset-id",
				"name": "Oversized Export",
				"is_built_in": true
			],
			extraExportFields: ["prompt": String(repeating: promptSentinel, count: 40)]
		)
		XCTAssertGreaterThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(toolName: "prompt", resultJSON: raw)
		let resultJSON = try XCTUnwrap(persisted.execution.resultJSON)
		let envelope = try decodePromptToolEnvelope(resultJSON)
		let export = try XCTUnwrap(envelope.export)

		XCTAssertFalse(persisted.execution.summaryOnly)
		XCTAssertLessThanOrEqual(resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertEqual(export.path, "/tmp/oversized-prompt-export.md")
		XCTAssertEqual(export.tokens, 9999)
		XCTAssertEqual(export.bytes, 8888)
		XCTAssertEqual(export.copyPreset?.name, "Oversized Export")
		XCTAssertLessThanOrEqual(export.files.count, 12)
		XCTAssertFalse(resultJSON.contains(#""summary_only":true"#))
		XCTAssertFalse(persisted.encoded.contains(promptSentinel))
		XCTAssertFalse(persisted.encoded.contains(fileContentSentinel))
	}

	func testPersistedTranscriptSanitizesVisibleAndHiddenToolResults() throws {
		var items = makeToolHeavyTurnItems(toolNames: Array(repeating: "read_file", count: 10))
		let hiddenPayload = #"{"status":"success","payload":"FIRST-HIDDEN-PAYLOAD"}"#
		let visiblePayload = #"{"status":"success","payload":"LAST-VISIBLE-PAYLOAD"}"#
		let toolResultIndexes = items.indices.filter { items[$0].kind == .toolResult }
		let firstToolResultIndex = try XCTUnwrap(toolResultIndexes.first)
		let lastToolResultIndex = try XCTUnwrap(toolResultIndexes.last)
		let hiddenToolResultID = items[firstToolResultIndex].id
		let visibleToolResultID = items[lastToolResultIndex].id
		items[firstToolResultIndex].toolResultJSON = hiddenPayload
		items[firstToolResultIndex].text = hiddenPayload
		items[lastToolResultIndex].toolResultJSON = visiblePayload
		items[lastToolResultIndex].text = visiblePayload

		let persisted = AgentTranscriptIO.persistedTranscript(AgentTranscriptIO.importLegacyItems(items))
		let projection = AgentTranscriptProjectionBuilder.build(from: persisted)
		let visibleResultIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(in: projection)
		let hiddenResult = try XCTUnwrap(persisted.turns.first?.allActivities.first(where: {
			$0.id == hiddenToolResultID
		}))
		let visibleResult = try XCTUnwrap(persisted.turns.first?.allActivities.first(where: {
			$0.id == visibleToolResultID
		}))
		let encoded = String(data: try JSONEncoder().encode(persisted), encoding: .utf8) ?? ""

		XCTAssertFalse(visibleResultIDs.contains(hiddenToolResultID))
		XCTAssertTrue(visibleResultIDs.contains(visibleToolResultID))

		XCTAssertFalse(hiddenResult.toolExecution?.resultJSON?.contains("FIRST-HIDDEN-PAYLOAD") == true)
		XCTAssertFalse(visibleResult.toolExecution?.resultJSON?.contains("LAST-VISIBLE-PAYLOAD") == true)
		XCTAssertTrue(hiddenResult.toolExecution?.resultJSON?.contains(#""summary_only":true"#) == true)
		XCTAssertTrue(visibleResult.toolExecution?.resultJSON?.contains(#""summary_only":true"#) == true)
		XCTAssertTrue(hiddenResult.toolExecution?.summaryOnly == true)
		XCTAssertTrue(visibleResult.toolExecution?.summaryOnly == true)
		XCTAssertFalse(encoded.contains("FIRST-HIDDEN-PAYLOAD"))
		XCTAssertFalse(encoded.contains("LAST-VISIBLE-PAYLOAD"))
	}

	func testPersistentStorageSanitizationDoesNotReuseRuntimeRawPrefix() throws {
		var items = makeToolHeavyTurnItems(toolNames: Array(repeating: "read_file", count: 10))
		let visiblePayload = #"{"status":"success","payload":"RUNTIME-PREFIX-RAW-PAYLOAD"}"#
		let lastToolResultIndex = try XCTUnwrap(items.indices.last(where: { items[$0].kind == .toolResult }))
		items[lastToolResultIndex].toolResultJSON = visiblePayload
		items[lastToolResultIndex].text = visiblePayload
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let runtimeSanitized = AgentToolResultPersistencePolicy.sanitizeTranscript(transcript)

		let storageMetrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
			transcript,
			previousSanitizedTranscript: runtimeSanitized,
			reusablePrefixTurnCount: runtimeSanitized.turns.count,
			purpose: .persistentStorage
		)
		let encoded = String(data: try JSONEncoder().encode(storageMetrics.transcript), encoding: .utf8) ?? ""

		XCTAssertEqual(storageMetrics.reusedTurnCount, 0)
		XCTAssertFalse(encoded.contains("RUNTIME-PREFIX-RAW-PAYLOAD"))
	}

	func testPersistentStorageCapsOversizedToolMetadata() throws {
		let hugeProcessID = String(repeating: "p", count: AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes + 1)
		let rawBashResult = "process running with session id \(hugeProcessID)"
		let items: [AgentChatItem] = [
			.user("Run long session", sequenceIndex: 0),
			.toolResult(name: "bash", invocationID: UUID(), resultJSON: rawBashResult, isError: nil, sequenceIndex: 1)
		]

		let persisted = AgentTranscriptIO.persistedTranscript(AgentTranscriptIO.importLegacyItems(items))
		let persistedResult = try XCTUnwrap(persisted.turns.first?.allActivities.first(where: { $0.itemKind == .toolResult }))
		let execution = try XCTUnwrap(persistedResult.toolExecution)
		let encoded = String(data: try JSONEncoder().encode(persisted), encoding: .utf8) ?? ""

		XCTAssertNil(execution.processID)
		XCTAssertTrue(execution.summaryOnly)
		XCTAssertLessThanOrEqual(persistedResult.text.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertLessThanOrEqual(execution.resultJSON?.utf8.count ?? 0, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertFalse(encoded.contains(hugeProcessID))
	}

	func testPersistentStorageRemovesBelowBudgetReadFileRawPayloadAndKeepsRenderSummary() throws {
		let sentinel = "READ-FILE-BELOW-BUDGET-SENTINEL"
		let raw = #"{"status":"success","content":"__SENTINEL__","display_path":"BombSquadPointerData.cs","total_lines":68,"first_line":1,"last_line":68}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(
			toolName: "read_file",
			resultJSON: raw,
			argsJSON: #"{"path":"RAW-ARG-READ-FILE-PATH.cs"}"#
		)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: sentinel)
		XCTAssertFalse(persisted.encoded.contains("RAW-ARG-READ-FILE-PATH"))
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "BombSquadPointerData.cs • Lines 1-68 of 68")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "tool_name"), "read_file")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), "BombSquadPointerData.cs • Lines 1-68 of 68")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "status"), "success")
	}

	func testPersistentStorageRemovesBelowBudgetFileSearchRawPayloadAndKeepsRenderSummary() throws {
		let sentinel = "FILE-SEARCH-BELOW-BUDGET-SENTINEL"
		let raw = #"{"total_matches":8,"total_files":3,"content_matches":8,"path_matches":0,"limit_hit":true,"per_file_counts":[{"path":"Sources/File.swift","count":8}],"path_match_lines":[],"content_match_groups":[{"path":"Sources/File.swift","lines":[{"line_number":7,"line_text":"__SENTINEL__","context_before":[{"line_number":6,"line_text":"before __SENTINEL__"}],"context_after":[{"line_number":8,"line_text":"after __SENTINEL__"}]}]}]}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(
			toolName: "file_search",
			resultJSON: raw,
			argsJSON: #"{"pattern":"SpatialPointerKind","path":"RAW-SEARCH-ARG-PATH"}"#
		)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: sentinel)
		XCTAssertFalse(persisted.encoded.contains("RAW-SEARCH-ARG-PATH"))
		XCTAssertFalse(persisted.encoded.contains("line_text"))
		XCTAssertFalse(persisted.encoded.contains("context_before"))
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), #""SpatialPointerKind" • 8 matches in 3 files (limited)"#)
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "tool_name"), "file_search")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), #""SpatialPointerKind" • 8 matches in 3 files (limited)"#)
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "status"), "warning")
	}

	func testPersistentStorageRemovesBelowBudgetManageSelectionRawPayloadAndKeepsRenderSummary() throws {
		let pathSentinel = "SELECTION-PATH-BELOW-BUDGET-SENTINEL"
		let blockSentinel = "SELECTION-BLOCK-BELOW-BUDGET-SENTINEL"
		let raw = #"{"status":"success","total_tokens":1085,"files":[{"path":"__PATH__-1.swift"},{"path":"__PATH__-2.swift"},{"path":"__PATH__-3.swift"},{"path":"__PATH__-4.swift"},{"path":"__PATH__-5.swift"},{"path":"__PATH__-6.swift"},{"path":"__PATH__-7.swift"}],"blocks":["__BLOCK__"],"summary":{"full_count":0,"slice_count":2,"codemap_count":5,"full_tokens":0,"slice_tokens":320,"codemap_tokens":765}}"#
			.replacingOccurrences(of: "__PATH__", with: pathSentinel)
			.replacingOccurrences(of: "__BLOCK__", with: blockSentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(
			toolName: "manage_selection",
			resultJSON: raw,
			argsJSON: #"{"op":"set","paths":["RAW-SELECTION-ARG-PATH.swift"]}"#
		)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: pathSentinel)
		XCTAssertFalse(persisted.encoded.contains(blockSentinel))
		XCTAssertFalse(persisted.encoded.contains("RAW-SELECTION-ARG-PATH"))
		XCTAssertFalse(persisted.encoded.contains("blocks"))
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "set • 7 files • 1085 tokens • 0 full • 2 sliced • 5 codemap")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "tool_name"), "manage_selection")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), "set • 7 files • 1085 tokens")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "detail_text"), "0 full • 2 sliced • 5 codemap")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "status"), "success")
	}

	func testPersistentStorageRemovesBelowBudgetWorkspaceContextRawPayloadAndKeepsRenderSummary() throws {
		let fileBlockSentinel = "WORKSPACE-FILE-BLOCK-BELOW-BUDGET-SENTINEL"
		let codeSentinel = "WORKSPACE-CODE-BELOW-BUDGET-SENTINEL"
		let promptSentinel = "WORKSPACE-PROMPT-BELOW-BUDGET-SENTINEL"
		let pathSentinel = "WORKSPACE-PATH-BELOW-BUDGET-SENTINEL"
		let raw = #"{"prompt":"","prompt_text":"__PROMPT__","code":"__CODE__","selection":{"files":[{"path":"__PATH__-1.swift"},{"path":"__PATH__-2.swift"},{"path":"__PATH__-3.swift"},{"path":"__PATH__-4.swift"},{"path":"__PATH__-5.swift"},{"path":"__PATH__-6.swift"},{"path":"__PATH__-7.swift"}],"total_tokens":1460},"file_blocks":["__FILE_BLOCK__"],"copy_preset":{"name":"Compact"}}"#
			.replacingOccurrences(of: "__FILE_BLOCK__", with: fileBlockSentinel)
			.replacingOccurrences(of: "__CODE__", with: codeSentinel)
			.replacingOccurrences(of: "__PROMPT__", with: promptSentinel)
			.replacingOccurrences(of: "__PATH__", with: pathSentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(toolName: "workspace_context", resultJSON: raw)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: fileBlockSentinel)
		XCTAssertFalse(persisted.encoded.contains(codeSentinel))
		XCTAssertFalse(persisted.encoded.contains(promptSentinel))
		XCTAssertFalse(persisted.encoded.contains(pathSentinel))
		XCTAssertFalse(persisted.encoded.contains("file_blocks"))
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "7 files • 1460 tokens • selection • file blocks • copy preset")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "tool_name"), "workspace_context")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), "7 files • 1460 tokens")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "detail_text"), "selection • file blocks • copy preset")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "status"), "success")
	}

	func testPersistentStorageRemovesBelowBudgetWorkspaceContextCamelCaseCodeStructureRawPayloadAndKeepsRenderSummary() throws {
		let codeSentinel = "WORKSPACE-CODE-STRUCTURE-CONTENT-SENTINEL"
		let pathSentinel = "WORKSPACE-CODE-STRUCTURE-PATH-SENTINEL"
		let raw = #"{"selection":{"files":["WorkspaceA.swift","WorkspaceB.swift"],"total_tokens":200},"codeStructure":{"file_count":2,"content":"__CODE__","unmapped_paths":["/tmp/__PATH__/Feature/Pending.swift"]}}"#
			.replacingOccurrences(of: "__CODE__", with: codeSentinel)
			.replacingOccurrences(of: "__PATH__", with: pathSentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(toolName: "workspace_context", resultJSON: raw)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: codeSentinel)
		XCTAssertFalse(persisted.encoded.contains(pathSentinel))
		XCTAssertNil(resultObject["codeStructure"])
		XCTAssertNil(resultObject["code_structure"])
		XCTAssertNil(resultObject["content"])
		XCTAssertNil(resultObject["unmapped_paths"])
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "2 files • 200 tokens • selection • code structure")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "tool_name"), "workspace_context")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), "2 files • 200 tokens")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "detail_text"), "selection • code structure")
	}

	func testPersistentStorageRemovesBelowBudgetManageSelectionCodeStructureRawPayloadAndKeepsRenderSummary() throws {
		let codeSentinel = "SELECTION-CODE-STRUCTURE-CONTENT-SENTINEL"
		let pathSentinel = "SELECTION-CODE-STRUCTURE-PATH-SENTINEL"
		let raw = #"{"status":"success","total_tokens":10,"files":[{"path":"Selection.swift"}],"summary":{"full_count":1,"slice_count":0,"codemap_count":0},"code_structure":{"file_count":1,"content":"__CODE__","unmapped_paths":["/tmp/__PATH__/Feature/Pending.swift"]}}"#
			.replacingOccurrences(of: "__CODE__", with: codeSentinel)
			.replacingOccurrences(of: "__PATH__", with: pathSentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(
			toolName: "manage_selection",
			resultJSON: raw,
			argsJSON: #"{"op":"get"}"#
		)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: codeSentinel)
		XCTAssertFalse(persisted.encoded.contains(pathSentinel))
		XCTAssertNil(resultObject["code_structure"])
		XCTAssertNil(resultObject["content"])
		XCTAssertNil(resultObject["unmapped_paths"])
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "get • 1 files • 10 tokens • 1 full • 0 sliced • 0 codemap • code structure")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "tool_name"), "manage_selection")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), "get • 1 files • 10 tokens")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "detail_text"), "1 full • 0 sliced • 0 codemap • code structure")
	}

	func testPersistentStorageRemovesBelowBudgetCodeStructureRawPayloadAndKeepsRenderSummary() throws {
		let contentSentinel = "CODE-STRUCTURE-CONTENT-SENTINEL"
		let pathSentinel = "CODE-STRUCTURE-UNMAPPED-PATH-SENTINEL"
		let raw = #"{"file_count":3,"content":"__CONTENT__","unmapped_paths":["/tmp/__PATH__/Feature/PendingOne.swift","PendingTwo.swift","/tmp/__PATH__/Other/PendingThree.swift"],"codemaps_omitted":1,"token_budget_omitted":2,"token_budget_hit":true}"#
			.replacingOccurrences(of: "__CONTENT__", with: contentSentinel)
			.replacingOccurrences(of: "__PATH__", with: pathSentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(
			toolName: "get_code_structure",
			resultJSON: raw,
			argsJSON: #"{"paths":["RAW-CODE-STRUCTURE-ARG-PATH"]}"#
		)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: contentSentinel)
		XCTAssertFalse(persisted.encoded.contains(pathSentinel))
		XCTAssertFalse(persisted.encoded.contains("RAW-CODE-STRUCTURE-ARG-PATH"))
		XCTAssertNil(resultObject["content"])
		XCTAssertNil(resultObject["unmapped_paths"])
		XCTAssertNil(resultObject["codemaps_omitted"])
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "3 files • 3 omitted • 3 unmapped • …/Feature/PendingOne.swift • PendingTwo.swift • (+1 more)")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "tool_name"), "get_code_structure")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), "3 files • 3 omitted • 3 unmapped")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "detail_text"), "…/Feature/PendingOne.swift • PendingTwo.swift • (+1 more)")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "status"), "warning")
	}

	func testPersistentStorageDoesNotTrustRawSummaryOnlyCodeStructureRenderSummaryPayload() throws {
		let sentinel = "MALICIOUS-CODE-STRUCTURE-RAW-SENTINEL"
		let raw = #"{"status":"success","summary_only":true,"summary_text":"3 files • /tmp/__SENTINEL__/Feature/Pending.swift","render_summary":{"schema_version":1,"tool_name":"get_code_structure","title":"Code Structure","subtitle":"3 files • 1 unmapped","detail_text":"/tmp/__SENTINEL__/Feature/Pending.swift","status":"success","op":"get_code_structure"}}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(toolName: "get_code_structure", resultJSON: raw)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: sentinel)
		XCTAssertNil(resultObject["render_summary"])
		XCTAssertFalse(persisted.encoded.contains(sentinel))
		XCTAssertNotEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "3 files • /tmp/\(sentinel)/Feature/Pending.swift")
	}

	func testPersistentStorageRemovesBelowBudgetFileTreeRawPayloadAndKeepsRenderSummary() throws {
		let sentinel = "FILE-TREE-BELOW-BUDGET-SENTINEL"
		let raw = #"{"roots_count":1,"uses_legend":true,"tree":"__SENTINEL__","was_truncated":false}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(
			toolName: "get_file_tree",
			resultJSON: raw,
			argsJSON: #"{"type":"files","mode":"selected"}"#
		)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: sentinel)
		XCTAssertNil(resultObject["tree"])
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "Selected • 1 root")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "tool_name"), "get_file_tree")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), "Selected • 1 root")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "status"), "success")
	}

	func testPersistentStorageRemovesBelowBudgetGitShowRawPayloadAndKeepsRenderSummary() throws {
		let sentinel = "GIT-SHOW-BELOW-BUDGET-SENTINEL"
		let raw = #"{"op":"show","show":{"sha":"04ada27afull","short_sha":"04ada27a","author":"Dev","date":"2026-04-15","message":"Merge branch 'masiknight'","totals":{"files":2,"insertions":3732,"deletions":3890},"files":[{"path":"__SENTINEL__.swift","status":"modified","insertions":1,"deletions":1,"hunks":[{"header":"@@ -1 +1 @@","old_start":1,"new_start":1,"patch":"__SENTINEL__"}]}],"hunks":[{"header":"@@ -1 +1 @@","old_start":1,"new_start":1,"patch":"__SENTINEL__"}]},"artifacts":{"manifest":"__SENTINEL__","map":"__SENTINEL__","files_tsv":"__SENTINEL__","tree":"__SENTINEL__"}}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(toolName: "git", resultJSON: raw)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: sentinel)
		XCTAssertNil(resultObject["show"])
		XCTAssertNil(resultObject["files"])
		XCTAssertNil(resultObject["hunks"])
		XCTAssertNil(resultObject["artifacts"])
		XCTAssertEqual(persisted.execution.summaryText, "show • 04ada27a • Merge branch 'masiknight' • 2 files (+3732 -3890)")
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "show • 04ada27a • Merge branch 'masiknight' • 2 files (+3732 -3890)")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "tool_name"), "git")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), "show • 04ada27a")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "detail_text"), "Merge branch 'masiknight' • 2 files (+3732 -3890)")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "status"), "success")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "op"), "show")
	}

	func testPersistentStorageDoesNotTrustRawSummaryOnlyRenderSummaryPayload() throws {
		let sentinel = "MALICIOUS-RAW-RENDER-SUMMARY-SENTINEL"
		let raw = #"{"status":"success","summary_only":true,"summary_text":"__SENTINEL__","render_summary":{"schema_version":1,"tool_name":"read_file","title":"Read File","subtitle":"__SENTINEL__","detail_text":"__SENTINEL__","status":"success","op":"read_file"}}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(toolName: "read_file", resultJSON: raw)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: sentinel)
		XCTAssertNil(resultObject["render_summary"])
		XCTAssertNotEqual(ToolRawJSON.string(resultObject, key: "summary_text"), sentinel)
	}

	func testPersistentStorageKeepsFailedFileSearchRenderStatusSticky() throws {
		let raw = #"{"status":"failed","total_matches":8,"total_files":3,"content_matches":8,"path_matches":0,"limit_hit":true,"per_file_counts":[],"path_match_lines":[],"content_match_groups":[]}"#

		let persisted = try persistedToolResultActivity(
			toolName: "file_search",
			resultJSON: raw,
			argsJSON: #"{"pattern":"SpatialPointerKind"}"#
		)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		let renderSummary = try renderSummaryObject(from: resultObject)

		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "status"), "failed")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "status"), "failure")
		XCTAssertEqual(ToolRawJSON.string(renderSummary, key: "subtitle"), #""SpatialPointerKind" • 8 matches in 3 files (limited)"#)
	}

	func testPersistentStorageRemovesBelowBudgetBashRawPayload() throws {
		let sentinel = "BASH-BELOW-BUDGET-SENTINEL"
		let raw = #"{"type":"commandExecution","status":"success","exitCode":0,"stdout":"__SENTINEL__","stderr":"__SENTINEL__","output":"__SENTINEL__","aggregatedOutput":"__SENTINEL__"}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(toolName: "bash", resultJSON: raw)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: sentinel)
		XCTAssertEqual(persisted.execution.exitCode, 0)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		XCTAssertEqual(ToolRawJSON.int(resultObject, key: "exitCode"), 0)
	}

	func testRuntimeTranscriptSanitizesVisibleApplyEditsDiffPayload() throws {
		let sentinel = "RUNTIME-APPLY-EDITS-DIFF-SENTINEL"
		let oversizedDiff = "diff --git a/File.swift b/File.swift\\n" + (0..<500)
			.map { "+\(sentinel)-\($0)" }
			.joined(separator: "\\n")
		let rawObject: [String: Any] = [
			"status": "success",
			"edits_requested": 2,
			"edits_applied": 2,
			"total_lines_changed": 500,
			"unified_diff": oversizedDiff,
			"card_unified_diff": oversizedDiff
		]
		let rawResult = String(
			data: try JSONSerialization.data(withJSONObject: rawObject, options: []),
			encoding: .utf8
		)!
		let invocationID = UUID()
		let items: [AgentChatItem] = [
			.user("Apply edits", sequenceIndex: 0),
			.toolCall(name: "apply_edits", invocationID: invocationID, argsJSON: #"{"path":"File.swift"}"#, sequenceIndex: 1),
			.toolResult(name: "apply_edits", invocationID: invocationID, resultJSON: rawResult, isError: false, sequenceIndex: 2)
		]

		let metrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
			AgentTranscriptIO.importLegacyItems(items),
			purpose: .runtimePresentation
		)
		let resultActivity = try XCTUnwrap(metrics.transcript.turns.first?.allActivities.first(where: { $0.itemKind == .toolResult }))
		let execution = try XCTUnwrap(resultActivity.toolExecution)
		let resultJSON = try XCTUnwrap(execution.resultJSON)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: resultJSON))
		let encoded = String(data: try JSONEncoder().encode(metrics.transcript), encoding: .utf8) ?? ""

		XCTAssertGreaterThan(metrics.sanitizedActivityCount, 0)
		XCTAssertFalse(encoded.contains(sentinel))
		XCTAssertFalse(resultActivity.text.contains(sentinel))
		XCTAssertFalse(resultJSON.contains(sentinel))
		XCTAssertFalse(resultJSON.contains("unified_diff"))
		XCTAssertFalse(resultJSON.contains("card_unified_diff"))
		XCTAssertLessThanOrEqual(resultActivity.text.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertLessThanOrEqual(resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertTrue(ToolRawJSON.bool(resultObject, key: "summary_only") == true)
		XCTAssertEqual(ToolRawJSON.int(resultObject, key: "edits_requested"), 2)
		XCTAssertEqual(ToolRawJSON.int(resultObject, key: "edits_applied"), 2)
		XCTAssertEqual(ToolRawJSON.int(resultObject, key: "total_lines_changed"), 500)
		XCTAssertTrue(execution.summaryOnly)
	}

	func testRuntimeTranscriptSanitizesBashAggregatedOutputPayloadAndKeepsMetadata() throws {
		let sentinel = "RUNTIME-BASH-AGGREGATED-OUTPUT-SENTINEL"
		let oversizedOutput = (0..<500)
			.map { "\(sentinel)-\($0)" }
			.joined(separator: "\\n")
		let rawObject: [String: Any] = [
			"type": "commandExecution",
			"status": "failed",
			"processId": "pid-123",
			"exitCode": 7,
			"aggregatedOutput": oversizedOutput
		]
		let rawResult = String(
			data: try JSONSerialization.data(withJSONObject: rawObject, options: []),
			encoding: .utf8
		)!
		let items: [AgentChatItem] = [
			.user("Run command", sequenceIndex: 0),
			.toolResult(name: "bash", invocationID: UUID(), resultJSON: rawResult, isError: true, sequenceIndex: 1)
		]

		let metrics = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
			AgentTranscriptIO.importLegacyItems(items),
			purpose: .runtimePresentation
		)
		let resultActivity = try XCTUnwrap(metrics.transcript.turns.first?.allActivities.first(where: { $0.itemKind == .toolResult }))
		let execution = try XCTUnwrap(resultActivity.toolExecution)
		let resultJSON = try XCTUnwrap(execution.resultJSON)
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: resultJSON))
		let encoded = String(data: try JSONEncoder().encode(metrics.transcript), encoding: .utf8) ?? ""

		XCTAssertGreaterThan(metrics.sanitizedActivityCount, 0)
		XCTAssertFalse(encoded.contains(sentinel))
		XCTAssertFalse(resultActivity.text.contains(sentinel))
		XCTAssertFalse(resultJSON.contains(sentinel))
		XCTAssertFalse(resultJSON.contains("aggregatedOutput"))
		XCTAssertLessThanOrEqual(resultActivity.text.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertLessThanOrEqual(resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertTrue(ToolRawJSON.bool(resultObject, key: "summary_only") == true)
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "type"), "commandExecution")
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "processId"), "pid-123")
		XCTAssertEqual(ToolRawJSON.int(resultObject, key: "exitCode"), 7)
		XCTAssertEqual(execution.processID, "pid-123")
		XCTAssertEqual(execution.exitCode, 7)
		XCTAssertTrue(execution.summaryOnly)
	}

	func testPersistentTranscriptSanitizesApplyEditsAndBashPayloadsAndKeepsMetadata() throws {
		let applySentinel = "PERSISTENT-APPLY-EDITS-DIFF-SENTINEL"
		let bashSentinel = "PERSISTENT-BASH-AGGREGATED-OUTPUT-SENTINEL"
		let applyDiff = (0..<500).map { "+\(applySentinel)-\($0)" }.joined(separator: "\\n")
		let bashOutput = (0..<500).map { "\(bashSentinel)-\($0)" }.joined(separator: "\\n")
		let applyResult = String(
			data: try JSONSerialization.data(withJSONObject: [
				"status": "success",
				"edits_requested": 1,
				"edits_applied": 1,
				"unified_diff": applyDiff,
				"card_unified_diff": applyDiff
			] as [String: Any], options: []),
			encoding: .utf8
		)!
		let bashResult = String(
			data: try JSONSerialization.data(withJSONObject: [
				"type": "commandExecution",
				"status": "failed",
				"processId": "pid-456",
				"exitCode": 9,
				"aggregatedOutput": bashOutput
			] as [String: Any], options: []),
			encoding: .utf8
		)!
		let applyInvocationID = UUID()
		let bashInvocationID = UUID()
		let items: [AgentChatItem] = [
			.user("Run tools", sequenceIndex: 0),
			.toolResult(name: "apply_edits", invocationID: applyInvocationID, resultJSON: applyResult, isError: false, sequenceIndex: 1),
			.toolResult(name: "bash", invocationID: bashInvocationID, resultJSON: bashResult, isError: true, sequenceIndex: 2)
		]

		let metrics = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistenceWithMetrics(
			AgentTranscriptIO.importLegacyItems(items)
		)
		let activities = metrics.transcript.turns.flatMap(\.allActivities)
		let applyActivity = try XCTUnwrap(activities.first(where: { $0.itemKind == .toolResult && $0.toolExecution?.toolName == "apply_edits" }))
		let bashActivity = try XCTUnwrap(activities.first(where: { $0.itemKind == .toolResult && $0.toolExecution?.toolName == "bash" }))
		let applyJSON = try XCTUnwrap(applyActivity.toolExecution?.resultJSON)
		let bashExecution = try XCTUnwrap(bashActivity.toolExecution)
		let bashJSON = try XCTUnwrap(bashExecution.resultJSON)
		let applyObject = try XCTUnwrap(ToolRawJSON.object(from: applyJSON))
		let bashObject = try XCTUnwrap(ToolRawJSON.object(from: bashJSON))
		let encoded = String(data: try JSONEncoder().encode(metrics.transcript), encoding: .utf8) ?? ""

		XCTAssertFalse(encoded.contains(applySentinel))
		XCTAssertFalse(encoded.contains(bashSentinel))
		XCTAssertFalse(applyJSON.contains("unified_diff"))
		XCTAssertFalse(bashJSON.contains("aggregatedOutput"))
		XCTAssertLessThanOrEqual(applyJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertLessThanOrEqual(bashJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertTrue(ToolRawJSON.bool(applyObject, key: "summary_only") == true)
		XCTAssertEqual(ToolRawJSON.int(applyObject, key: "edits_requested"), 1)
		XCTAssertEqual(ToolRawJSON.int(applyObject, key: "edits_applied"), 1)
		XCTAssertTrue(ToolRawJSON.bool(bashObject, key: "summary_only") == true)
		XCTAssertEqual(ToolRawJSON.string(bashObject, key: "processId"), "pid-456")
		XCTAssertEqual(ToolRawJSON.int(bashObject, key: "exitCode"), 9)
		XCTAssertEqual(bashExecution.processID, "pid-456")
		XCTAssertEqual(bashExecution.exitCode, 9)
	}

	func testPersistentStorageRemovesBelowBudgetGitStatusRawPayloadAndKeepsSummaryLine() throws {
		let sentinel = "GIT-STATUS-BELOW-BUDGET-SENTINEL"
		let staged = (["\"staged-\(sentinel)\""] + (2...29).map { "\"s\($0)\"" }).joined(separator: ",")
		let modified = (["\"modified-\(sentinel)\""] + (2...10).map { "\"m\($0)\"" }).joined(separator: ",")
		let untracked = (["\"untracked-\(sentinel)\""] + (2...5).map { "\"u\($0)\"" }).joined(separator: ",")
		let raw = #"{"op":"status","status":{"branch":"Dev","upstream":"origin/Dev","ahead":0,"behind":0,"staged":[__STAGED__],"modified":[__MODIFIED__],"untracked":[__UNTRACKED__],"summary":"raw status"}}"#
			.replacingOccurrences(of: "__STAGED__", with: staged)
			.replacingOccurrences(of: "__MODIFIED__", with: modified)
			.replacingOccurrences(of: "__UNTRACKED__", with: untracked)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(toolName: "git", resultJSON: raw)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: sentinel)
		XCTAssertEqual(persisted.execution.summaryText, "status • Dev • origin/Dev • 29 staged • 10 modified • 5 untracked")
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "status • Dev • origin/Dev • 29 staged • 10 modified • 5 untracked")
	}

	func testPersistentStorageRemovesBelowBudgetGitDiffRawPayloadAndKeepsSummaryLine() throws {
		let sentinel = "GIT-DIFF-BELOW-BUDGET-SENTINEL"
		let raw = #"{"op":"diff","diff":{"compare":"main","detail":"files","totals":{"files":42,"insertions":8884,"deletions":181},"oneliner":"42 files (+8884 -181)","files":[{"path":"Sources/__SENTINEL__.swift","status":"modified","insertions":1,"deletions":1,"hunks":[{"header":"@@ -1 +1 @@","old_start":1,"new_start":1,"patch":"-old __SENTINEL__\n+new"}]}]}}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = try persistedToolResultActivity(toolName: "git", resultJSON: raw)

		assertPersistedToolResultIsSummaryOnly(persisted, excluding: sentinel)
		XCTAssertEqual(persisted.execution.summaryText, "diff • 42 files (+8884 -181) • files")
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.execution.resultJSON))
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "diff • 42 files (+8884 -181) • files")
	}

	func testPersistedGitSummaryOnlyPayloadsRemainIdempotent() throws {
		let statusSummary = "status • Dev • origin/Dev • 29 staged • 10 modified • 5 untracked"
		let diffSummary = "diff • 42 files (+8884 -181) • files"
		let items: [AgentChatItem] = [
			.user("Re-persist git", sequenceIndex: 0),
			.toolResult(
				name: "git",
				invocationID: UUID(),
				resultJSON: AgentToolResultPersistencePolicy.minimalResultJSON(
					statusWord: "success",
					normalizedToolName: "git",
					summaryText: statusSummary
				),
				isError: false,
				sequenceIndex: 1
			),
			.toolResult(
				name: "git",
				invocationID: UUID(),
				resultJSON: AgentToolResultPersistencePolicy.minimalResultJSON(
					statusWord: "success",
					normalizedToolName: "git",
					summaryText: diffSummary
				),
				isError: false,
				sequenceIndex: 2
			)
		]

		let once = AgentTranscriptIO.persistedTranscript(AgentTranscriptIO.importLegacyItems(items))
		let twice = AgentTranscriptIO.persistedTranscript(once)
		let summaries = twice.turns.flatMap(\.allActivities).compactMap { activity -> String? in
			guard activity.itemKind == .toolResult,
				let object = ToolRawJSON.object(from: activity.toolExecution?.resultJSON)
			else { return nil }
			return ToolRawJSON.string(object, key: "summary_text")
		}

		XCTAssertEqual(summaries, [statusSummary, diffSummary])
	}

	func testAgentChatItemPersistRemovesBelowBudgetRawToolPayloads() throws {
		let sentinel = "CHAT-ITEM-PERSIST-BELOW-BUDGET-SENTINEL"
		let raw = #"{"status":"success","content":"__SENTINEL__","display_path":"Secrets.swift","total_lines":1,"first_line":1,"last_line":1}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		var item = AgentChatItem.toolResult(
			name: "read_file",
			invocationID: UUID(),
			resultJSON: raw,
			isError: false,
			sequenceIndex: 0
		)
		item.toolArgsJSON = #"{"path":"__SENTINEL__.swift"}"#.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		item.text = "raw text \(sentinel) \(raw)"
		XCTAssertLessThan(raw.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let persisted = AgentChatItemPersist(from: item)
		let encoded = String(data: try JSONEncoder().encode(persisted), encoding: .utf8) ?? ""
		let resultObject = try XCTUnwrap(ToolRawJSON.object(from: persisted.toolResultJSON))

		XCTAssertFalse(encoded.contains(sentinel))
		XCTAssertNil(persisted.toolArgsJSON)
		XCTAssertEqual(persisted.text, persisted.toolResultJSON)
		XCTAssertTrue(ToolRawJSON.bool(resultObject, key: "summary_only") == true)
		XCTAssertEqual(ToolRawJSON.string(resultObject, key: "summary_text"), "Secrets.swift • Lines 1-1 of 1")
	}

	func testPersistentStorageSanitizedTranscriptDoesNotRehydrateRawPayloadInRuntimePipeline() throws {
		let invocationID = UUID()
		let rawBashResult = #"{"type":"commandExecution","status":"success","exitCode":0,"aggregatedOutput":"REBOOT-RAW-BASH-PAYLOAD"}"#
		let items: [AgentChatItem] = [
			.user("Run", sequenceIndex: 0),
			.toolCall(name: "bash", invocationID: invocationID, argsJSON: #"{"command":"echo REBOOT-RAW-BASH-PAYLOAD"}"#, sequenceIndex: 1),
			.toolResult(name: "bash", invocationID: invocationID, resultJSON: rawBashResult, isError: false, sequenceIndex: 2)
		]
		let rawTranscript = AgentTranscriptIO.importLegacyItems(items)
		let storageSafeTranscript = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistence(rawTranscript)
		let runtimeTranscript = AgentTranscriptPolicyPipeline.runtimeTranscript(storageSafeTranscript).transcript
		let encoded = String(data: try JSONEncoder().encode(runtimeTranscript), encoding: .utf8) ?? ""
		let workingItems = AgentTranscriptIO.workingSourceItems(from: runtimeTranscript)

		XCTAssertFalse(encoded.contains("REBOOT-RAW-BASH-PAYLOAD"))
		XCTAssertFalse(workingItems.contains { $0.text.contains("REBOOT-RAW-BASH-PAYLOAD") || ($0.toolArgsJSON?.contains("REBOOT-RAW-BASH-PAYLOAD") == true) || ($0.toolResultJSON?.contains("REBOOT-RAW-BASH-PAYLOAD") == true) })
	}

	func testPersistedTranscriptDropsToolArgsForCallsAndResults() throws {
		let invocationID = UUID()
		let argsPayload = #"{"command":"echo ARG-SENTINEL","secret":"ARG-SENTINEL"}"#
		let resultPayload = #"{"type":"commandExecution","status":"success","exitCode":0,"aggregatedOutput":"RESULT-SENTINEL"}"#
		var call = AgentChatItem.toolCall(name: "bash", invocationID: invocationID, argsJSON: argsPayload, sequenceIndex: 1)
		call.text = "CALL-TEXT-SENTINEL \(argsPayload)"
		var result = AgentChatItem.toolResult(
			name: "bash",
			invocationID: invocationID,
			resultJSON: resultPayload,
			isError: false,
			sequenceIndex: 2
		)
		result.toolArgsJSON = argsPayload
		let items: [AgentChatItem] = [
			.user("Run command", sequenceIndex: 0),
			call,
			result
		]

		let persisted = AgentTranscriptIO.persistedTranscript(AgentTranscriptIO.importLegacyItems(items))
		let activities = persisted.turns.flatMap(\.allActivities)
		let encoded = String(data: try JSONEncoder().encode(persisted), encoding: .utf8) ?? ""

		XCTAssertFalse(encoded.contains("ARG-SENTINEL"))
		XCTAssertFalse(encoded.contains("CALL-TEXT-SENTINEL"))
		XCTAssertFalse(encoded.contains("RESULT-SENTINEL"))
		XCTAssertTrue(activities.contains { $0.itemKind == .toolCall })
		XCTAssertTrue(activities.contains { $0.itemKind == .toolResult })
		for activity in activities where activity.itemKind == .toolCall || activity.itemKind == .toolResult {
			XCTAssertNil(activity.toolExecution?.argsJSON)
			XCTAssertFalse(activity.toolExecution?.summaryText?.contains("ARG-SENTINEL") == true)
			XCTAssertFalse(activity.toolExecution?.summaryText?.contains("RESULT-SENTINEL") == true)
			XCTAssertEqual(activity.toolExecution?.keyPaths, [])
		}
		let persistedCall = try XCTUnwrap(activities.first(where: { $0.itemKind == .toolCall }))
		XCTAssertEqual(persistedCall.text, "Using tool: bash")
		XCTAssertEqual(persistedCall.toolExecution?.summaryText, "bash • pending")
		let persistedItem = AgentChatItemPersist(from: call)
		XCTAssertEqual(persistedItem.text, "Using tool: bash")
		XCTAssertNil(persistedItem.toolArgsJSON)

		let persistedResult = try XCTUnwrap(activities.first(where: { $0.itemKind == .toolResult }))
		XCTAssertEqual(persistedResult.toolExecution?.summaryText, "bash • success")
		XCTAssertTrue(persistedResult.toolExecution?.resultJSON?.contains(#""summary_only":true"#) == true)
		XCTAssertFalse(persistedResult.toolExecution?.resultJSON?.contains("RESULT-SENTINEL") == true)
	}

	func testPersistedGitTranscriptKeepsCompactResultSubtitleWithoutPayloads() throws {
		let diffInvocationID = UUID()
		let statusInvocationID = UUID()
		let diffArgsPayload = #"{"op":"diff","detail":"patches","path":"ARG-DIFF-SENTINEL.swift"}"#
		let diffResultPayload = #"{"op":"diff","status":"success","diff":{"oneliner":"3 files (+43 -8)","detail":"patches","files":[{"path":"RESULT-DIFF-SENTINEL.swift","patch":"PATCH-SENTINEL"}],"totals":{"files":3,"insertions":43,"deletions":8}},"inputs":{"compare":"","scope":""}}"#
		let statusResultPayload = #"{"op":"status","status":{"branch":"Dev","upstream":"origin/Dev","ahead":1,"behind":0,"staged":[],"modified":["RESULT-STATUS-MODIFIED-1.swift","RESULT-STATUS-MODIFIED-2.swift"],"untracked":["RESULT-STATUS-UNTRACKED.swift"],"summary":"ignored raw summary"}}"#
		let items: [AgentChatItem] = [
			.user("Check git", sequenceIndex: 0),
			.toolCall(name: "git", invocationID: diffInvocationID, argsJSON: diffArgsPayload, sequenceIndex: 1),
			.toolResult(name: "git", invocationID: diffInvocationID, resultJSON: diffResultPayload, isError: false, sequenceIndex: 2),
			.toolCall(name: "git", invocationID: statusInvocationID, argsJSON: #"{"op":"status"}"#, sequenceIndex: 3),
			.toolResult(name: "git", invocationID: statusInvocationID, resultJSON: statusResultPayload, isError: false, sequenceIndex: 4)
		]

		let persisted = AgentTranscriptIO.persistedTranscript(AgentTranscriptIO.importLegacyItems(items))
		let activities = persisted.turns.flatMap(\.allActivities)
		let encoded = String(data: try JSONEncoder().encode(persisted), encoding: .utf8) ?? ""
		let diffResult = try XCTUnwrap(activities.first(where: { $0.itemKind == .toolResult && $0.toolExecution?.invocationID == diffInvocationID }))
		let statusResult = try XCTUnwrap(activities.first(where: { $0.itemKind == .toolResult && $0.toolExecution?.invocationID == statusInvocationID }))

		let diffResultObject = try XCTUnwrap(ToolRawJSON.object(from: diffResult.toolExecution?.resultJSON))
		let statusResultObject = try XCTUnwrap(ToolRawJSON.object(from: statusResult.toolExecution?.resultJSON))

		XCTAssertEqual(diffResult.toolExecution?.summaryText, "diff • 3 files (+43 -8) • patches")
		XCTAssertEqual(statusResult.toolExecution?.summaryText, "status • Dev • +1 -0 • origin/Dev • 2 modified • 1 untracked")
		XCTAssertEqual(ToolRawJSON.string(diffResultObject, key: "summary_text"), "diff • 3 files (+43 -8) • patches")
		XCTAssertEqual(ToolRawJSON.string(statusResultObject, key: "summary_text"), "status • Dev • +1 -0 • origin/Dev • 2 modified • 1 untracked")
		XCTAssertFalse(encoded.contains("ARG-DIFF-SENTINEL"))
		XCTAssertFalse(encoded.contains("RESULT-DIFF-SENTINEL"))
		XCTAssertFalse(encoded.contains("PATCH-SENTINEL"))
		XCTAssertFalse(encoded.contains("RESULT-STATUS-MODIFIED"))
		XCTAssertFalse(encoded.contains("RESULT-STATUS-UNTRACKED"))
		XCTAssertTrue(diffResult.toolExecution?.summaryOnly == true)
		XCTAssertTrue(statusResult.toolExecution?.summaryOnly == true)
		XCTAssertEqual(diffResult.toolExecution?.keyPaths, [])
		XCTAssertEqual(statusResult.toolExecution?.keyPaths, [])
	}

	func testTranscriptSanitizationKeepsApplyPatchSummaryMetadataUsableForHiddenGroupedResults() throws {
		let rawPatchResult = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}"#
		var items = makeToolHeavyTurnItems(toolNames: ["apply_patch"] + Array(repeating: "read_file", count: 10))
		let applyPatchResultIndex = try XCTUnwrap(items.firstIndex(where: { $0.kind == .toolResult && $0.toolName == "apply_patch" }))
		let applyPatchResultID = items[applyPatchResultIndex].id
		items[applyPatchResultIndex].toolResultJSON = rawPatchResult
		items[applyPatchResultIndex].text = rawPatchResult

		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let visibleResultIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
			in: AgentTranscriptProjectionBuilder.build(from: transcript)
		)
		XCTAssertFalse(visibleResultIDs.contains(applyPatchResultID))

		let sanitized = AgentToolResultPersistencePolicy.sanitizeTranscript(transcript)
		let resultActivity = try XCTUnwrap(sanitized.turns.first?.allActivities.first(where: { $0.id == applyPatchResultID }))
		let dto = ToolJSON.decode(ToolResultDTOs.ApplyPatchSummary.self, from: resultActivity.toolExecution?.resultJSON)

		XCTAssertEqual(dto?.status, "success")
		XCTAssertEqual(dto?.changeCount, 1)
		XCTAssertEqual(dto?.summaryOnly, true)
		XCTAssertEqual(dto?.changes.first?.path, "/tmp/file.swift")
		XCTAssertEqual(dto?.changes.first?.diff, "")
	}

	func testTranscriptSanitizationDropsCompactApplyEditsCardDiffMetadataForHiddenGroupedResults() throws {
		let rawApplyEditsResult = #"{"status":"success","edits_requested":1,"edits_applied":1,"total_lines_changed":2,"unified_diff":"diff --git a/File.swift b/File.swift\n--- a/File.swift\n+++ b/File.swift\n@@ -1 +1 @@\n-old\n+new","card_unified_diff":"diff --git a/File.swift b/File.swift\n--- a/File.swift\n+++ b/File.swift\n@@ -1 +1 @@\n-old\n+new"}"#
		var items = makeToolHeavyTurnItems(toolNames: ["apply_edits"] + Array(repeating: "read_file", count: 10))
		let applyEditsResultIndex = try XCTUnwrap(items.firstIndex(where: { $0.kind == .toolResult && $0.toolName == "apply_edits" }))
		let applyEditsResultID = items[applyEditsResultIndex].id
		items[applyEditsResultIndex].toolResultJSON = rawApplyEditsResult
		items[applyEditsResultIndex].text = rawApplyEditsResult

		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let visibleResultIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
			in: AgentTranscriptProjectionBuilder.build(from: transcript)
		)
		XCTAssertFalse(visibleResultIDs.contains(applyEditsResultID))

		let sanitized = AgentToolResultPersistencePolicy.sanitizeTranscript(transcript)
		let resultActivity = try XCTUnwrap(sanitized.turns.first?.allActivities.first(where: { $0.id == applyEditsResultID }))
		let resultJSON = try XCTUnwrap(resultActivity.toolExecution?.resultJSON)
		let dto = ToolJSON.decode(ToolResultDTOs.EditSummary.self, from: resultJSON)
		let object = try XCTUnwrap(ToolRawJSON.object(from: resultJSON))

		XCTAssertEqual(dto?.status, "success")
		XCTAssertEqual(dto?.editsRequested, 1)
		XCTAssertEqual(dto?.editsApplied, 1)
		XCTAssertEqual(dto?.totalLinesChanged, 2)
		XCTAssertNil(dto?.cardUnifiedDiff)
		XCTAssertNil(dto?.unifiedDiff)
		XCTAssertFalse(resultJSON.contains("card_unified_diff"))
		XCTAssertTrue(ToolRawJSON.bool(object, key: "summary_only") == true)
	}

	func testTranscriptSanitizationOmitsOversizedCompactApplyEditsCardDiffForHiddenGroupedResults() throws {
		let oversizedDiff = "diff --git a/File.swift b/File.swift\n" + String(repeating: "+line\n", count: 5_000)
		let rawApplyEditsObject: [String: Any] = [
			"status": "success",
			"edits_requested": 1,
			"edits_applied": 1,
			"card_unified_diff": oversizedDiff
		]
		let rawApplyEditsResult = String(
			data: try! JSONSerialization.data(withJSONObject: rawApplyEditsObject, options: []),
			encoding: .utf8
		)!
		var items = makeToolHeavyTurnItems(toolNames: ["apply_edits"] + Array(repeating: "read_file", count: 10))
		let applyEditsResultIndex = try XCTUnwrap(items.firstIndex(where: { $0.kind == .toolResult && $0.toolName == "apply_edits" }))
		let applyEditsResultID = items[applyEditsResultIndex].id
		items[applyEditsResultIndex].toolResultJSON = rawApplyEditsResult
		items[applyEditsResultIndex].text = rawApplyEditsResult

		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let visibleResultIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
			in: AgentTranscriptProjectionBuilder.build(from: transcript)
		)
		XCTAssertFalse(visibleResultIDs.contains(applyEditsResultID))

		let sanitized = AgentToolResultPersistencePolicy.sanitizeTranscript(transcript)
		let resultActivity = try XCTUnwrap(sanitized.turns.first?.allActivities.first(where: { $0.id == applyEditsResultID }))
		let resultJSON = try XCTUnwrap(resultActivity.toolExecution?.resultJSON)
		let dto = ToolJSON.decode(ToolResultDTOs.EditSummary.self, from: resultJSON)
		let object = try XCTUnwrap(ToolRawJSON.object(from: resultJSON))

		XCTAssertEqual(dto?.status, "success")
		XCTAssertNil(dto?.cardUnifiedDiff)
		XCTAssertTrue(ToolRawJSON.bool(object, key: "summary_only") == true)
	}

	func testTranscriptSanitizationDoesNotChangeProjectionStructure() {
		let items = makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let rawProjection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let sanitizedProjection = AgentTranscriptProjectionBuilder.build(
			from: AgentToolResultPersistencePolicy.sanitizeTranscript(transcript)
		)

		XCTAssertEqual(rawProjection.workingBlocks.map(\.kind), sanitizedProjection.workingBlocks.map(\.kind))
		XCTAssertEqual(rawProjection.archivedBlocks.map(\.kind), sanitizedProjection.archivedBlocks.map(\.kind))
		XCTAssertEqual(rawProjection.workingRows.map(\.id), sanitizedProjection.workingRows.map(\.id))
		XCTAssertEqual(rawProjection.archivedRows.map(\.id), sanitizedProjection.archivedRows.map(\.id))
	}

	func testFinalizePendingToolCallsCanCloseExplicitRepoPromptToolCallsAfterRunEnd() {
		var items: [AgentChatItem] = [
			AgentChatItem.user("Start", sequenceIndex: 0),
			AgentChatItem.toolCall(name: "mcp__RepoPrompt__context_builder", invocationID: nil, argsJSON: #"{"query":"help"}"#, sequenceIndex: 1)
		]

		let finalizedCount = AgentTranscriptIO.finalizePendingToolCalls(
			in: &items,
			terminalState: .completed,
			includeExplicitRepoPromptToolCalls: true,
			nonToolBoundary: 200
		)

		XCTAssertEqual(finalizedCount, 1)
		XCTAssertEqual(items[1].kind, .toolResult)
		XCTAssertTrue(items[1].toolResultJSON?.contains("result_missing") == true)
	}

	func testFinalizePendingToolCallsCanCloseDurableRunningToolResultsAfterRunEnd() {
		var items: [AgentChatItem] = [
			AgentChatItem.user("Start", sequenceIndex: 0),
			AgentChatItem.toolResult(
				name: "bash",
				invocationID: UUID(),
				resultJSON: #"{"status":"running","title":"Bash"}"#,
				isError: false,
				sequenceIndex: 1
			),
			AgentChatItem.toolResult(
				name: "tool",
				invocationID: UUID(),
				resultJSON: #"{"status":"pending"}"#,
				isError: false,
				sequenceIndex: 2
			)
		]

		let finalizedCount = AgentTranscriptIO.finalizePendingToolCalls(
			in: &items,
			terminalState: .completed,
			includeExplicitRepoPromptToolCalls: false,
			nonToolBoundary: 200
		)

		XCTAssertEqual(finalizedCount, 2)
		XCTAssertEqual(items[1].kind, .toolResult)
		XCTAssertEqual(items[2].kind, .toolResult)
		XCTAssertEqual(items[1].toolIsError, true)
		XCTAssertEqual(items[2].toolIsError, true)
		XCTAssertTrue(items[1].toolResultJSON?.contains("result_missing") == true)
		XCTAssertTrue(items[2].toolResultJSON?.contains("result_missing") == true)
	}

	func testGroupedHistorySummaryTracksCollapsedToolStatusesWithinLatestTurnPrefix() throws {
		let items = makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		], resultStatusByToolIndex: [0: "success"])

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let grouped = try XCTUnwrap(AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false).first(where: { $0.kind == .groupedHistory }))
		let summary = try XCTUnwrap(grouped.groupedHistory?.summary.toolSummary)

		XCTAssertEqual(grouped.groupedHistory?.summary.hiddenToolCardCount, 1)
		XCTAssertEqual(summary.toolCount, 1)
		XCTAssertFalse(summary.containsRunningWork)
		XCTAssertFalse(summary.containsFailure)
		XCTAssertFalse(summary.containsWarning)
	}

	func testGroupedHistorySummaryUsesNewestAssistantNarration() throws {
		let items = makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search"
		])

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let grouped = try XCTUnwrap(AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false).first(where: { $0.kind == .groupedHistory }))
		let summary = try XCTUnwrap(grouped.groupedHistory?.summary.toolSummary)

		XCTAssertEqual(summary.shortNarration, "step 2")
	}

	func testGroupedHistoryKeepsAssistantToolAndProgressFromSameTurnInOneSection() throws {
		let readInvocationID = UUID()
		let searchInvocationID = UUID()
		let thirdInvocationID = UUID()
		let fourthInvocationID = UUID()
		let fifthInvocationID = UUID()
		let sixthInvocationID = UUID()
		let seventhInvocationID = UUID()
		let eighthInvocationID = UUID()
		let ninthInvocationID = UUID()
		let tenthInvocationID = UUID()
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "step 1", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "read_file", invocationID: readInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 2),
			AgentChatItem.toolResult(name: "read_file", invocationID: readInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 4), kind: .thinking, text: "verifying the parser flow", sequenceIndex: 4),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 5), kind: .assistantInline, text: "step 2", sequenceIndex: 5),
			AgentChatItem.toolCall(name: "search", invocationID: searchInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 6),
			AgentChatItem.toolResult(name: "search", invocationID: searchInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 7),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 8), kind: .assistantInline, text: "step 3", sequenceIndex: 8),
			AgentChatItem.toolCall(name: "read_file", invocationID: thirdInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 9),
			AgentChatItem.toolResult(name: "read_file", invocationID: thirdInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 10),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 11), kind: .assistantInline, text: "step 4", sequenceIndex: 11),
			AgentChatItem.toolCall(name: "search", invocationID: fourthInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 12),
			AgentChatItem.toolResult(name: "search", invocationID: fourthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 13),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 14), kind: .assistantInline, text: "step 5", sequenceIndex: 14),
			AgentChatItem.toolCall(name: "read_file", invocationID: fifthInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 15),
			AgentChatItem.toolResult(name: "read_file", invocationID: fifthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 16),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 17), kind: .assistantInline, text: "step 6", sequenceIndex: 17),
			AgentChatItem.toolCall(name: "search", invocationID: sixthInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 18),
			AgentChatItem.toolResult(name: "search", invocationID: sixthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 19),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 20), kind: .assistantInline, text: "step 7", sequenceIndex: 20),
			AgentChatItem.toolCall(name: "read_file", invocationID: seventhInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 21),
			AgentChatItem.toolResult(name: "read_file", invocationID: seventhInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 22),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 23), kind: .assistantInline, text: "step 8", sequenceIndex: 23),
			AgentChatItem.toolCall(name: "search", invocationID: eighthInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 24),
			AgentChatItem.toolResult(name: "search", invocationID: eighthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 25),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 26), kind: .assistantInline, text: "step 9", sequenceIndex: 26),
			AgentChatItem.toolCall(name: "read_file", invocationID: ninthInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 27),
			AgentChatItem.toolResult(name: "read_file", invocationID: ninthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 28),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 29), kind: .assistantInline, text: "step 10", sequenceIndex: 29),
			AgentChatItem.toolCall(name: "search", invocationID: tenthInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 30),
			AgentChatItem.toolResult(name: "search", invocationID: tenthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 31),
			AgentChatItem.assistant("final summary", sequenceIndex: 32)
		]

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let groupedHistory = try XCTUnwrap(AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false).first(where: { $0.kind == .groupedHistory })?.groupedHistory)

		XCTAssertEqual(groupedHistory.summary.hiddenToolCardCount, 2)
		XCTAssertEqual(groupedHistory.summary.hiddenAssistantCount, 2)
		XCTAssertEqual(groupedHistory.summary.hiddenProgressCount, 1)
		XCTAssertEqual(groupedHistory.sections.count, 1)
		let section = try XCTUnwrap(groupedHistory.sections.first)
		XCTAssertEqual(section.kind, .tools)
		XCTAssertEqual(section.childBlocks.map(\.kind), [
			.standaloneAssistant,
			.standaloneTool,
			.standaloneNote,
			.standaloneAssistant,
			.standaloneTool
		])
		XCTAssertEqual(section.clusterSummary?.toolCount, 2)
	}

	func testGroupedHistoryKeepsNoteBlocksSeparatedFromActivitySections() throws {
		let readInvocationID = UUID()
		let searchInvocationID = UUID()
		let thirdInvocationID = UUID()
		let fourthInvocationID = UUID()
		let fifthInvocationID = UUID()
		let sixthInvocationID = UUID()
		let seventhInvocationID = UUID()
		let eighthInvocationID = UUID()
		let ninthInvocationID = UUID()
		let tenthInvocationID = UUID()
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "step 1", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "read_file", invocationID: readInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 2),
			AgentChatItem.toolResult(name: "read_file", invocationID: readInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 4), kind: .system, text: "daemon switched to fallback mode", sequenceIndex: 4),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 5), kind: .assistantInline, text: "step 2", sequenceIndex: 5),
			AgentChatItem.toolCall(name: "search", invocationID: searchInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 6),
			AgentChatItem.toolResult(name: "search", invocationID: searchInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 7),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 8), kind: .assistantInline, text: "step 3", sequenceIndex: 8),
			AgentChatItem.toolCall(name: "read_file", invocationID: thirdInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 9),
			AgentChatItem.toolResult(name: "read_file", invocationID: thirdInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 10),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 11), kind: .assistantInline, text: "step 4", sequenceIndex: 11),
			AgentChatItem.toolCall(name: "search", invocationID: fourthInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 12),
			AgentChatItem.toolResult(name: "search", invocationID: fourthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 13),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 14), kind: .assistantInline, text: "step 5", sequenceIndex: 14),
			AgentChatItem.toolCall(name: "read_file", invocationID: fifthInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 15),
			AgentChatItem.toolResult(name: "read_file", invocationID: fifthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 16),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 17), kind: .assistantInline, text: "step 6", sequenceIndex: 17),
			AgentChatItem.toolCall(name: "search", invocationID: sixthInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 18),
			AgentChatItem.toolResult(name: "search", invocationID: sixthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 19),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 20), kind: .assistantInline, text: "step 7", sequenceIndex: 20),
			AgentChatItem.toolCall(name: "read_file", invocationID: seventhInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 21),
			AgentChatItem.toolResult(name: "read_file", invocationID: seventhInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 22),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 23), kind: .assistantInline, text: "step 8", sequenceIndex: 23),
			AgentChatItem.toolCall(name: "search", invocationID: eighthInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 24),
			AgentChatItem.toolResult(name: "search", invocationID: eighthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 25),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 26), kind: .assistantInline, text: "step 9", sequenceIndex: 26),
			AgentChatItem.toolCall(name: "read_file", invocationID: ninthInvocationID, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 27),
			AgentChatItem.toolResult(name: "read_file", invocationID: ninthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 28),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 29), kind: .assistantInline, text: "step 10", sequenceIndex: 29),
			AgentChatItem.toolCall(name: "search", invocationID: tenthInvocationID, argsJSON: #"{"pattern":"Parser"}"#, sequenceIndex: 30),
			AgentChatItem.toolResult(name: "search", invocationID: tenthInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 31),
			AgentChatItem.assistant("final summary", sequenceIndex: 32)
		]

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let groupedHistory = try XCTUnwrap(AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false).first(where: { $0.kind == .groupedHistory })?.groupedHistory)

		XCTAssertEqual(groupedHistory.sections.map(\.kind), [.tools, .notes, .tools])
		XCTAssertEqual(groupedHistory.sections.compactMap(\.clusterSummary?.toolCount), [1, 1])
		XCTAssertEqual(groupedHistory.sections[1].childBlocks.map(\.kind), [.standaloneNote])
	}

	func testLatestTurnUnderToolTailLimitKeepsStandaloneToolBlocks() throws {
		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search"
		])).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)

		XCTAssertFalse(blocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(blocks.filter { $0.kind == .standaloneTool }.count, 2)
		XCTAssertEqual(blocks.flatMap(\.rows).filter { $0.kind == .toolCall }.map(\.toolName), ["read_file", "search"])
	}

	func testLatestHighSignalBashAndEditToolsStayVisibleAsStandaloneTail() throws {
		let items = makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "bash", "apply_edits"
		])

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)
		let toolCallNames = blocks.flatMap(\.rows).compactMap { $0.kind == .toolCall ? $0.toolName : nil }
		let assistantTexts = blocks.flatMap(\.rows).compactMap {
			($0.kind == .assistant || $0.kind == .assistantInline) ? $0.text : nil
		}

		XCTAssertFalse(blocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(blocks.filter { $0.kind == .standaloneTool }.count, 7)
		XCTAssertEqual(toolCallNames, ["read_file", "search", "read_file", "search", "read_file", "bash", "apply_edits"])
		XCTAssertEqual(blocks.flatMap(\.rows).filter { $0.kind == .toolResult }.count, 7)
		XCTAssertEqual(assistantTexts, ["step 1", "step 2", "step 3", "step 4", "step 5", "step 6", "step 7", "final summary"])
	}

	func testProjectionWorkingRowsExcludeGroupedHistoryChildRows() throws {
		let items = makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])

		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

		XCTAssertTrue(projection.workingBlocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertFalse(projection.workingRows.contains(where: { $0.kind == .toolCall && $0.sequenceIndex == 2 }))
		XCTAssertFalse(projection.workingRows.contains(where: { $0.kind == .toolResult && $0.sequenceIndex == 3 }))
		XCTAssertTrue(projection.workingRows.contains(where: { $0.kind == .assistantInline && $0.sequenceIndex == 13 }))
		XCTAssertTrue(projection.workingRows.contains(where: { $0.kind == .toolCall && $0.sequenceIndex == 14 }))
		XCTAssertEqual(projection.workingRows.first?.kind, .user)
		XCTAssertEqual(projection.workingRows.last?.kind, .assistant)
	}

	func testLatestTurnKeepsAllVisibleToolsWhenWithinGlobalDetailedToolLimit() throws {
		let items = makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file"
		])

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)
		let visibleToolNames = blocks.flatMap(\.rows).compactMap { $0.kind == .toolCall ? $0.toolName : nil }
		let visibleAssistantTexts = blocks.compactMap {
			$0.kind == .standaloneAssistant ? $0.rows.first?.text : nil
		}

		XCTAssertFalse(blocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(blocks.filter { $0.kind == .standaloneTool }.count, 5)
		XCTAssertEqual(visibleAssistantTexts, ["step 1", "step 2", "step 3", "step 4", "step 5"])
		XCTAssertEqual(visibleToolNames, ["read_file", "search", "read_file", "search", "read_file"])
	}

	func testLowSignalAssistantNarrationStillKeepsVisibleWhenWithinGlobalDetailedToolLimit() throws {
		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeLowSignalToolHeavyTurnItems(
			toolNames: ["read_file", "search", "read_file", "search", "read_file"]
		)).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)

		XCTAssertFalse(blocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(blocks.filter { $0.kind == .standaloneTool }.count, 5)
		XCTAssertEqual(blocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 5)
	}

	func testCompletedTurnsUnderToolTailLimitCanLaterAutoCollapseAcrossTurns() throws {
		let firstTurnItems = makeLowSignalToolHeavyTurnItems(
			toolNames: ["read_file", "search", "read_file", "search", "read_file", "search", "read_file"],
			userText: "Investigate 1",
			finalSummaryText: "final summary 1"
		)
		let secondTurnItems = makeToolHeavyTurnItems(
			toolNames: ["read_file", "search", "read_file", "search", "read_file", "search", "read_file"],
			startingSequenceIndex: (firstTurnItems.last?.sequenceIndex ?? 0) + 1,
			userText: "Investigate 2",
			finalSummaryText: "final summary 2"
		)
		let transcript = AgentTranscriptIO.importLegacyItems(firstTurnItems + secondTurnItems)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let lastTurn = try XCTUnwrap(transcript.turns.last)
		let firstTurnBlocks = projection.workingBlocks.filter { $0.turnID == firstTurn.id }
		let lastTurnBlocks = projection.workingBlocks.filter { $0.turnID == lastTurn.id }

		XCTAssertFalse(firstTurnBlocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertFalse(lastTurnBlocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(firstTurnBlocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory?.summary.hiddenToolCardCount, 6)
		XCTAssertFalse(lastTurnBlocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertNil(firstTurn.frozenDetailedToolTailLimit)
		XCTAssertNil(lastTurn.frozenDetailedToolTailLimit)
		XCTAssertEqual(firstTurnBlocks.filter { $0.kind == .standaloneTool }.count, 1)
		XCTAssertEqual(lastTurnBlocks.filter { $0.kind == .standaloneTool }.count, 7)
		XCTAssertEqual(projection.workingRows.filter { $0.kind == .toolCall }.count, 8)
	}

	func testCompletedFullTurnsUnderToolTailLimitCanLaterAutoCollapseSequentially() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"],
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"]
		]))
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let lastTurn = try XCTUnwrap(transcript.turns.last)
		let firstTurnBlocks = projection.workingBlocks.filter { $0.turnID == firstTurn.id }
		let lastTurnBlocks = projection.workingBlocks.filter { $0.turnID == lastTurn.id }

		XCTAssertFalse(firstTurnBlocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertFalse(lastTurnBlocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(firstTurnBlocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory?.summary.hiddenToolCardCount, 6)
		XCTAssertFalse(lastTurnBlocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertNil(firstTurn.frozenDetailedToolTailLimit)
		XCTAssertNil(lastTurn.frozenDetailedToolTailLimit)
		XCTAssertEqual(firstTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 1)
		XCTAssertEqual(lastTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 7)
		XCTAssertEqual(projection.workingRows.filter { $0.kind == .toolCall }.count, 8)
	}

	func testDetachedFocusRowTargetPreservesProjectionTopology() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"],
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"]
		]))
		let baselineProjection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let firstTurnRequestID = try XCTUnwrap(firstTurn.request?.id)

		let protection = AgentTranscriptProjectionBuilder.projectionProtection(
			for: transcript,
			viewportState: AgentTranscriptViewportState(
				isDetachedFromLiveBottom: true,
				detachedAuthority: DetachedViewportAuthority(
					targetID: .row(firstTurnRequestID),
					anchor: nil,
					sequenceIndex: nil,
					blockID: nil,
					viewportMinY: nil
				)
			)
		)
		let protectedProjection = AgentTranscriptProjectionBuilder.build(
			from: transcript,
			protection: protection
		)

		XCTAssertEqual(protectedProjection.workingBlocks.map(\.kind), baselineProjection.workingBlocks.map(\.kind))
		XCTAssertEqual(protectedProjection.workingRows.map(\.kind), baselineProjection.workingRows.map(\.kind))
		XCTAssertEqual(
			protectedProjection.workingBlocks.first(where: { $0.turnID == firstTurn.id && $0.kind == .groupedHistory })?.groupedHistory?.summary.hiddenToolCardCount,
			baselineProjection.workingBlocks.first(where: { $0.turnID == firstTurn.id && $0.kind == .groupedHistory })?.groupedHistory?.summary.hiddenToolCardCount
		)
	}

	func testDetachedFocusGroupedHistoryAnchorPreservesProjectionTopology() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"],
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"]
		]))
		let baselineProjection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let firstSpanID = try XCTUnwrap(firstTurn.responseSpans.first?.id)

		let protection = AgentTranscriptProjectionBuilder.projectionProtection(
			for: transcript,
			viewportState: AgentTranscriptViewportState(
				isDetachedFromLiveBottom: true,
				detachedAuthority: DetachedViewportAuthority(
					targetID: nil,
					anchor: .groupedHistory(turnID: firstTurn.id, spanID: firstSpanID),
					sequenceIndex: nil,
					blockID: nil,
					viewportMinY: nil
				)
			)
		)
		let protectedProjection = AgentTranscriptProjectionBuilder.build(
			from: transcript,
			protection: protection
		)

		XCTAssertEqual(protectedProjection.workingBlocks.map(\.kind), baselineProjection.workingBlocks.map(\.kind))
		XCTAssertEqual(protectedProjection.workingRows.map(\.kind), baselineProjection.workingRows.map(\.kind))
	}

	func testDetachedFocusDoesNotIncreaseVisibleToolBudget() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			Array(repeating: "bash", count: 10),
			Array(repeating: "bash", count: 10)
		]))
		let baselineProjection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let firstTurnRequestID = try XCTUnwrap(firstTurn.request?.id)
		let lastTurn = try XCTUnwrap(transcript.turns.last)

		let protection = AgentTranscriptProjectionBuilder.projectionProtection(
			for: transcript,
			viewportState: AgentTranscriptViewportState(
				isDetachedFromLiveBottom: true,
				detachedAuthority: DetachedViewportAuthority(
					targetID: .row(firstTurnRequestID),
					anchor: nil,
					sequenceIndex: nil,
					blockID: nil,
					viewportMinY: nil
				)
			)
		)
		let protectedProjection = AgentTranscriptProjectionBuilder.build(
			from: transcript,
			protection: protection
		)
		let baselineLastTurnBlocks = baselineProjection.workingBlocks.filter { $0.turnID == lastTurn.id }
		let protectedLastTurnBlocks = protectedProjection.workingBlocks.filter { $0.turnID == lastTurn.id }
		let baselineVisibleToolCallCount = baselineProjection.workingRows.filter { $0.kind == .toolCall }.count
		let protectedVisibleToolCallCount = protectedProjection.workingRows.filter { $0.kind == .toolCall }.count
		let baselineLastTurnVisibleToolCallCount = baselineLastTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count
		let protectedLastTurnVisibleToolCallCount = protectedLastTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count

		XCTAssertEqual(protectedVisibleToolCallCount, baselineVisibleToolCallCount)
		XCTAssertEqual(protectedVisibleToolCallCount, 8)
		XCTAssertEqual(protectedLastTurnVisibleToolCallCount, baselineLastTurnVisibleToolCallCount)
		XCTAssertEqual(protectedLastTurnVisibleToolCallCount, 0)
		XCTAssertEqual(protectedProjection.workingBlocks.map(\.kind), baselineProjection.workingBlocks.map(\.kind))
	}

	func testDetachedProjectionProtectionResolvesProtectedTurnFromRowTarget() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file"],
			["read_file", "search"]
		]))
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let firstTurnRequestID = try XCTUnwrap(firstTurn.request?.id)

		let protection = AgentTranscriptProjectionBuilder.projectionProtection(
			for: transcript,
			viewportState: AgentTranscriptViewportState(
				isDetachedFromLiveBottom: true,
				detachedAuthority: DetachedViewportAuthority(
					targetID: .row(firstTurnRequestID),
					anchor: nil,
					sequenceIndex: nil,
					blockID: nil,
					viewportMinY: nil
				)
			)
		)

		XCTAssertEqual(protection.protectedTurnID, firstTurn.id)
	}

	func testDetachedProjectionProtectionResolvesProtectedTurnFromGroupedHistoryAnchor() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file"],
			["read_file", "search"]
		]))
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let firstSpanID = try XCTUnwrap(firstTurn.responseSpans.first?.id)

		let protection = AgentTranscriptProjectionBuilder.projectionProtection(
			for: transcript,
			viewportState: AgentTranscriptViewportState(
				isDetachedFromLiveBottom: true,
				detachedAuthority: DetachedViewportAuthority(
					targetID: nil,
					anchor: .groupedHistory(turnID: firstTurn.id, spanID: firstSpanID),
					sequenceIndex: nil,
					blockID: nil,
					viewportMinY: nil
				)
			)
		)

		XCTAssertEqual(protection.protectedTurnID, firstTurn.id)
	}

	func testDetachedProjectionProtectionResolvesProtectedTurnFromSequenceIndexAuthority() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file"],
			["read_file", "search"]
		]))
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let firstTurnSequenceIndex = try XCTUnwrap(firstTurn.request?.sequenceIndex)

		let protection = AgentTranscriptProjectionBuilder.projectionProtection(
			for: transcript,
			viewportState: AgentTranscriptViewportState(
				isDetachedFromLiveBottom: true,
				detachedAuthority: DetachedViewportAuthority(
					targetID: nil,
					anchor: nil,
					sequenceIndex: firstTurnSequenceIndex,
					blockID: nil,
					viewportMinY: nil
				)
			)
		)

		XCTAssertEqual(protection.protectedTurnID, firstTurn.id)
	}

	func testLatestTurnKeepsLeadingAssistantVisibleWhenOnlyHiddenToolsFollowIt() throws {
		var items: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "keeping this visible", sequenceIndex: 1)
		]
		var sequenceIndex = 2
		for toolName in ["read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file"] {
			let invocationID = UUID()
			let argsJSON = toolName == "search" ? #"{"pattern":"Parser"}"# : #"{"path":"Parser.swift"}"#
			items.append(AgentChatItem.toolCall(name: toolName, invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolResult(name: toolName, invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}

		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(items).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)
		let groupedHistory = try XCTUnwrap(blocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory)

		XCTAssertEqual(blocks.prefix(3).map(\.kind), [.request, .standaloneAssistant, .groupedHistory])
		XCTAssertEqual(blocks.dropFirst().first?.rows.first?.text, "keeping this visible")
		XCTAssertEqual(groupedHistory.summary.hiddenToolCardCount, 3)
		XCTAssertEqual(groupedHistory.summary.hiddenAssistantCount, 0)
		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(blocks.filter { $0.kind == .standaloneTool }.count, 8)
	}

	func testCompletedFullTurnProjectionIsStableWhenNewTurnStarts() throws {
		let firstTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])).turns.first)
		let baselineTranscript = AgentTranscript(turns: [firstTurn], nextSequenceIndex: 100)
		let secondTurn = AgentTranscriptTurn(
			id: UUID(),
			request: AgentTranscriptRequestAnchor(from: AgentChatItem.user("Next task", sequenceIndex: 100)),
			responseSpans: [],
			retentionTier: .full,
			startedAt: Date(timeIntervalSince1970: 100),
			completedAt: nil
		)
		let transcript = AgentTranscript(turns: [firstTurn, secondTurn], nextSequenceIndex: 101)

		let baselineProjection = AgentTranscriptProjectionBuilder.build(from: baselineTranscript)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let baselineBlocks = baselineProjection.workingBlocks.filter { $0.turnID == firstTurn.id }
		let firstTurnBlocks = projection.workingBlocks.filter { $0.turnID == firstTurn.id }

		XCTAssertEqual(firstTurnBlocks, baselineBlocks)
	}

	func testRefreshCompletedFullTurnGroupedHistoryCachesFreezesTurnOnFirstCollapse() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"],
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"]
		]))

		let refreshed = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: transcript)
		let firstTurn = try XCTUnwrap(refreshed.turns.first)
		let lastTurn = try XCTUnwrap(refreshed.turns.last)

		XCTAssertEqual(firstTurn.frozenDetailedToolTailLimit, 1)
		XCTAssertNil(lastTurn.frozenDetailedToolTailLimit)
	}

	func testCompletedTurnUnderTailLimitCanAutoCollapseWhenNewTurnsExceedBudget() throws {
		let completedTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])).turns.first)
		let baselineTranscript = AgentTranscript(turns: [completedTurn], nextSequenceIndex: 100)
		let nextTurnTranscript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(
			toolNames: ["read_file", "search", "read_file", "search", "read_file", "search", "read_file"],
			startingSequenceIndex: 100,
			userText: "Next task",
			finalSummaryText: "next summary"
		))
		let expandedTranscript = AgentTranscript(
			turns: [completedTurn] + nextTurnTranscript.turns,
			nextSequenceIndex: nextTurnTranscript.nextSequenceIndex
		)

		let baselineBlocks = AgentTranscriptProjectionBuilder.build(from: baselineTranscript).workingBlocks
			.filter { $0.turnID == completedTurn.id }
		let expandedBlocks = AgentTranscriptProjectionBuilder.build(from: expandedTranscript).workingBlocks
			.filter { $0.turnID == completedTurn.id }

		XCTAssertNil(completedTurn.frozenDetailedToolTailLimit)
		XCTAssertNil(expandedTranscript.turns.first?.frozenDetailedToolTailLimit)
		XCTAssertNotEqual(expandedBlocks, baselineBlocks)
		XCTAssertEqual(expandedBlocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory?.summary.hiddenToolCardCount, 6)
		XCTAssertEqual(expandedBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 1)
	}

	func testFrozenTailLimitNormalizationClearsCompletedTurnWhenNoCollapseOccurred() throws {
		let completedTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])).turns.first)
		var transcript = AgentTranscript(
			turns: [completedTurn],
			nextSequenceIndex: 100
		)
		transcript.turns[0].frozenDetailedToolTailLimit = 7

		let normalized = AgentTranscriptProjectionBuilder.normalizedFrozenDetailedToolTailLimits(in: transcript)
		let completedBlocks = AgentTranscriptProjectionBuilder.build(from: normalized).workingBlocks.filter {
			$0.turnID == completedTurn.id
		}

		XCTAssertNil(normalized.turns.first?.frozenDetailedToolTailLimit)
		XCTAssertFalse(completedBlocks.contains(where: { $0.kind == .groupedHistory }))

		transcript.turns[0].frozenDetailedToolTailLimit = 99
		let normalizedOversized = AgentTranscriptProjectionBuilder.normalizedFrozenDetailedToolTailLimits(in: transcript)
		XCTAssertNil(normalizedOversized.turns.first?.frozenDetailedToolTailLimit)
	}

	func testFrozenTailLimitNormalizationBackfillsCompletedTurnWhenCollapseOccurred() throws {
		var completedTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(
			toolNames: Array(repeating: "read_file", count: 12)
		)).turns.first)
		completedTurn.frozenDetailedToolTailLimit = nil
		let transcript = AgentTranscript(turns: [completedTurn], nextSequenceIndex: 100)

		let normalized = AgentTranscriptProjectionBuilder.normalizedFrozenDetailedToolTailLimits(in: transcript)
		let completedBlocks = AgentTranscriptProjectionBuilder.build(from: normalized).workingBlocks.filter {
			$0.turnID == completedTurn.id
		}

		XCTAssertEqual(normalized.turns.first?.frozenDetailedToolTailLimit, 8)
		XCTAssertTrue(completedBlocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertEqual(completedBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 8)
	}

	func testFrozenTailLimitNormalizationUsesNewestFirstAllocation() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			Array(repeating: "read_file", count: 12),
			Array(repeating: "search", count: 12)
		]))
		var legacyTranscript = transcript
		legacyTranscript.turns[0].frozenDetailedToolTailLimit = nil
		legacyTranscript.turns[1].frozenDetailedToolTailLimit = nil

		let normalized = AgentTranscriptProjectionBuilder.normalizedFrozenDetailedToolTailLimits(in: legacyTranscript)

		XCTAssertEqual(normalized.turns[0].frozenDetailedToolTailLimit, 0)
		XCTAssertEqual(normalized.turns[1].frozenDetailedToolTailLimit, 8)
	}

	func testCompletedCollapsedTurnYieldsTailBudgetToNewerTurns() throws {
		let completedTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(
			toolNames: Array(repeating: "read_file", count: 12)
		)).turns.first)
		let baselineTranscript = AgentTranscript(turns: [completedTurn], nextSequenceIndex: 100)
		let nextTurnTranscript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(
			toolNames: ["search", "read_file"],
			startingSequenceIndex: 100,
			userText: "Next task",
			finalSummaryText: "next summary"
		))
		let expandedTranscript = AgentTranscript(
			turns: [completedTurn] + nextTurnTranscript.turns,
			nextSequenceIndex: nextTurnTranscript.nextSequenceIndex
		)

		let baselineBlocks = AgentTranscriptProjectionBuilder.build(from: baselineTranscript).workingBlocks
			.filter { $0.turnID == completedTurn.id }
		let expandedBlocks = AgentTranscriptProjectionBuilder.build(from: expandedTranscript).workingBlocks
			.filter { $0.turnID == completedTurn.id }
		let refreshedExpandedTranscript = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
			in: expandedTranscript
		)

		XCTAssertEqual(completedTurn.frozenDetailedToolTailLimit, 8)
		XCTAssertEqual(expandedTranscript.turns.first?.frozenDetailedToolTailLimit, 8)
		XCTAssertEqual(refreshedExpandedTranscript.turns.first?.frozenDetailedToolTailLimit, 6)
		XCTAssertTrue(baselineBlocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertEqual(baselineBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 8)
		XCTAssertNotEqual(expandedBlocks, baselineBlocks)
		XCTAssertEqual(expandedBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 6)
	}

	func testNewToolHeavySteeredTurnGetsTailBudgetFromPreviouslyFrozenTurn() throws {
		let completedTurnItems = Array(makeToolHeavyTurnItems(
			toolNames: Array(repeating: "read_file", count: 12),
			userText: "Initial task"
		).dropLast())
		let completedTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(completedTurnItems).turns.first)
		XCTAssertEqual(completedTurn.frozenDetailedToolTailLimit, 8)

		let steerItems = Array(makeToolHeavyTurnItems(
			toolNames: Array(repeating: "search", count: 10),
			startingSequenceIndex: 100,
			userText: "Steer"
		).dropLast())
		let steerTranscript = AgentTranscriptIO.importLegacyItems(steerItems)
		let steeredTranscript = AgentTranscript(
			turns: [completedTurn] + steerTranscript.turns,
			nextSequenceIndex: steerTranscript.nextSequenceIndex
		)

		let projection = AgentTranscriptProjectionBuilder.build(from: steeredTranscript)
		let firstTurn = try XCTUnwrap(steeredTranscript.turns.first)
		let lastTurn = try XCTUnwrap(steeredTranscript.turns.last)
		let firstTurnBlocks = projection.workingBlocks.filter { $0.turnID == firstTurn.id }
		let lastTurnBlocks = projection.workingBlocks.filter { $0.turnID == lastTurn.id }
		let refreshedTranscript = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(
			in: steeredTranscript
		)

		XCTAssertEqual(firstTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 0)
		XCTAssertEqual(lastTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 8)
		XCTAssertEqual(projection.workingRows.filter { $0.kind == .toolCall }.count, 8)
		XCTAssertEqual(refreshedTranscript.turns.first?.frozenDetailedToolTailLimit, 0)
		XCTAssertEqual(refreshedTranscript.turns.last?.frozenDetailedToolTailLimit, 8)
	}

	func testSmallCompletedTurnAutoCollapsesWhenNewerToolHeavyTurnConsumesBudget() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search"],
			Array(repeating: "read_file", count: 10)
		]))
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let lastTurn = try XCTUnwrap(transcript.turns.last)
		let firstTurnBlocks = projection.workingBlocks.filter { $0.turnID == firstTurn.id }
		let lastTurnBlocks = projection.workingBlocks.filter { $0.turnID == lastTurn.id }

		XCTAssertNil(firstTurn.frozenDetailedToolTailLimit)
		XCTAssertEqual(lastTurn.frozenDetailedToolTailLimit, 8)
		XCTAssertEqual(firstTurnBlocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory?.summary.hiddenToolCardCount, 2)
		XCTAssertEqual(firstTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 0)
		XCTAssertEqual(lastTurnBlocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory?.summary.hiddenToolCardCount, 2)
		XCTAssertEqual(lastTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 8)
		XCTAssertEqual(projection.workingRows.filter { $0.kind == .toolCall }.count, 8)
	}

	func testCondensedFrozenTurnDoesNotConsumeDetailedTailBudget() throws {
		let completedTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])).turns.first)
		let liveTranscript = AgentTranscriptIO.importLegacyItems(
			Array(makeToolHeavyTurnItems(
				toolNames: ["read_file", "search", "read_file"],
				startingSequenceIndex: 100,
				userText: "Next task",
				finalSummaryText: "next summary"
			).dropLast()),
			terminalState: .running
		)
		let liveTurn = try XCTUnwrap(liveTranscript.turns.first)
		var transcript = AgentTranscript(
			turns: [completedTurn, liveTurn],
			nextSequenceIndex: liveTranscript.nextSequenceIndex
		)
		transcript.turns[0].retentionTier = .condensed
		let normalized = AgentTranscriptCompactor.compact(transcript)
		let liveBlocks = AgentTranscriptProjectionBuilder.build(from: normalized).workingBlocks.filter {
			$0.turnID == liveTurn.id
		}

		XCTAssertFalse(liveBlocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertEqual(liveBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 3)
	}

	func testBuildWithCachesCachesCompletedTurnsOnlyAndReusesCompletedTurnState() throws {
		let firstTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])).turns.first)
		let secondTurn = AgentTranscriptTurn(
			id: UUID(),
			request: AgentTranscriptRequestAnchor(from: AgentChatItem.user("Open task", sequenceIndex: 100)),
			responseSpans: [],
			retentionTier: .full,
			terminalState: .running,
			startedAt: Date(timeIntervalSince1970: 100),
			completedAt: nil
		)
		let transcript = AgentTranscript(turns: [firstTurn, secondTurn], nextSequenceIndex: 101)

		let initialResult = AgentTranscriptProjectionBuilder.buildWithCaches(
			from: transcript,
			turnCaches: [:]
		)
		let cachedResult = AgentTranscriptProjectionBuilder.buildWithCaches(
			from: transcript,
			turnCaches: initialResult.updatedTurnCaches
		)

		XCTAssertEqual(initialResult.projection, AgentTranscriptProjectionBuilder.build(from: transcript))
		XCTAssertEqual(cachedResult.projection, initialResult.projection)
		XCTAssertEqual(Set(initialResult.updatedTurnCaches.keys), Set([firstTurn.id]))
		XCTAssertEqual(cachedResult.updatedTurnCaches[firstTurn.id], initialResult.updatedTurnCaches[firstTurn.id])
		XCTAssertNil(cachedResult.updatedTurnCaches[secondTurn.id])
	}

	func testBuildWithCachesBypassesProtectedTurnWithoutOverwritingStoredCache() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"],
			["read_file", "search", "read_file"]
		]))
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let initialResult = AgentTranscriptProjectionBuilder.buildWithCaches(
			from: transcript,
			turnCaches: [:]
		)
		let originalCache = try XCTUnwrap(initialResult.updatedTurnCaches[firstTurn.id])
		let sentinelCache = AgentTranscriptTurnProjectionCache(
			token: originalCache.token,
			workingBlocks: [],
			archivedBlocks: [],
			workingRows: [],
			archivedRows: [],
			rowAnchorIndex: [:],
			anchorBlockIndex: [:]
		)
		var seededCaches = initialResult.updatedTurnCaches
		seededCaches[firstTurn.id] = sentinelCache
		let protection = AgentTranscriptProjectionProtection.protectedTurn(firstTurn.id)

		let protectedResult = AgentTranscriptProjectionBuilder.buildWithCaches(
			from: transcript,
			protection: protection,
			turnCaches: seededCaches
		)

		XCTAssertEqual(
			protectedResult.projection,
			AgentTranscriptProjectionBuilder.build(from: transcript, protection: protection)
		)
		XCTAssertEqual(protectedResult.updatedTurnCaches[firstTurn.id], sentinelCache)
	}

	func testPreviousUnderLimitTurnAutoCollapsesWhenNewerTurnNeedsBudget() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file"],
			["read_file", "search"]
		]))
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let firstTurn = try XCTUnwrap(transcript.turns.first)
		let lastTurn = try XCTUnwrap(transcript.turns.last)
		let firstTurnBlocks = projection.workingBlocks.filter { $0.turnID == firstTurn.id }
		let lastTurnBlocks = projection.workingBlocks.filter { $0.turnID == lastTurn.id }

		XCTAssertNil(firstTurn.frozenDetailedToolTailLimit)
		XCTAssertNil(lastTurn.frozenDetailedToolTailLimit)
		XCTAssertEqual(firstTurnBlocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory?.summary.hiddenToolCardCount, 1)
		XCTAssertFalse(lastTurnBlocks.contains(where: { $0.kind == .groupedHistory }))
		XCTAssertEqual(firstTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 6)
		XCTAssertEqual(lastTurnBlocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 2)
		XCTAssertEqual(projection.workingRows.filter { $0.kind == .toolCall }.count, 8)
	}

	func testPerTurnProjectionIgnoresLatestnessFlagAndKeepsLocalTail() throws {
		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])).turns.first)
		let latestBlocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false)
		let nonLatestBlocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false, isLatestTurn: false)

		XCTAssertEqual(nonLatestBlocks, latestBlocks)
	}

	func testPerTurnProjectionCanExplicitlyRenderPartialDetailedToolTail() throws {
		let turn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])).turns.first)
		let blocks = AgentTranscriptProjectionBuilder.blocks(for: turn, archived: false, detailedToolTailLimit: 3)

		XCTAssertFalse(blocks.contains(where: { $0.kind == .activityCluster }))
		XCTAssertEqual(blocks.filter { $0.kind == .standaloneTool }.count, 3)
		XCTAssertEqual(blocks.first(where: { $0.kind == .groupedHistory })?.groupedHistory?.summary.hiddenToolCardCount, 4)
		XCTAssertEqual(blocks.flatMap(\.rows).filter { $0.kind == .toolCall }.count, 3)
	}

	func testEstimatedWorkingUnitCountMatchesProjectionAcrossTurnsWithLocalTailLimits() throws {
		let firstTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		])).turns.first)
		let secondTurn = try XCTUnwrap(AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(
			toolNames: ["read_file", "search"],
			startingSequenceIndex: 100,
			userText: "Next task",
			finalSummaryText: "done"
		)).turns.first)
		let thirdTurn = AgentTranscriptTurn(
			id: UUID(),
			request: AgentTranscriptRequestAnchor(from: AgentChatItem.user("Fresh prompt", sequenceIndex: 200)),
			responseSpans: [],
			retentionTier: .full,
			startedAt: Date(timeIntervalSince1970: 200),
			completedAt: nil
		)
		let transcript = AgentTranscript(turns: [firstTurn, secondTurn, thirdTurn], nextSequenceIndex: 201)

		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

		XCTAssertEqual(AgentTranscriptProjectionBuilder.estimatedWorkingUnitCount(for: transcript), projection.workingUnitCount)
	}

	func testProjectedVisibleRowCountMatchesProjectionAcrossRetentionTiers() throws {
		var transcript = AgentTranscriptIO.importLegacyItems(makeMultiTurnToolHeavyItems(toolNamesByTurn: [
			["read_file", "search", "read_file"],
			["read_file", "search"],
			["read_file"],
			["read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search"]
		]))
		transcript.turns[0].retentionTier = .archived
		transcript.turns[1].retentionTier = .summary
		transcript.turns[2].retentionTier = .condensed
		transcript.turns[3].retentionTier = .full

		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let counts = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)

		XCTAssertEqual(
			counts.canonicalVisibleRowCount,
			presentedItemCount(for: projection.workingBlocks) + presentedItemCount(for: projection.archivedBlocks)
		)
		XCTAssertEqual(counts.defaultPresentedRowCount, presentedItemCount(for: projection.workingBlocks))
	}

	func testRepeatedCountPathsStayConsistentWithLargeToolPayloads() {
		let payload = String(repeating: "x", count: 20_000)
		var items: [AgentChatItem] = [AgentChatItem.user("Investigate", sequenceIndex: 0)]
		var sequenceIndex = 1
		for step in 0..<8 {
			let invocationID = UUID()
			items.append(AgentChatItem(
				timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceIndex)),
				kind: .assistantInline,
				text: "step \(step + 1)",
				sequenceIndex: sequenceIndex
			))
			sequenceIndex += 1
			items.append(AgentChatItem.toolCall(
				name: "bash",
				invocationID: invocationID,
				argsJSON: #"{"cmd":"swift test"}"#,
				sequenceIndex: sequenceIndex
			))
			sequenceIndex += 1
			items.append(AgentChatItem.toolResult(
				name: "bash",
				invocationID: invocationID,
				resultJSON: #"{"status":"success","stdout":"\#(payload)"}"#,
				isError: false,
				sequenceIndex: sequenceIndex
			))
			sequenceIndex += 1
		}
		items.append(AgentChatItem.assistant("done", sequenceIndex: sequenceIndex))

		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)

		for _ in 0..<5 {
			XCTAssertEqual(
				AgentTranscriptProjectionBuilder.estimatedWorkingUnitCount(for: transcript),
				projection.workingUnitCount
			)
			XCTAssertEqual(
				AgentTranscriptProjectionBuilder.projectedVisibleRowCount(for: transcript),
				presentedItemCount(for: projection.workingBlocks) + presentedItemCount(for: projection.archivedBlocks)
			)
		}
	}

	func testClusterToolCategoryPreservesCategoryOrderAndLabelsForMixedCaseInputs() {
		let groups = ClusterToolCategory.buildGroups(
			toolNames: [
				"READ_FILE", "file_search",
				"Apply_Edits", "apply_patch",
				"BASH", "shell",
				"ASK_USER", "ask_oracle",
				"Agent_Run", "agent_explore", "AGENT_MANAGE",
				"PROMPT", "git",
				"customOne", "customTwo"
			],
			counts: [
				"READ_FILE": 2, "file_search": 1,
				"Apply_Edits": 1, "apply_patch": 1,
				"BASH": 1, "shell": 2,
				"ASK_USER": 1, "ask_oracle": 1,
				"Agent_Run": 1, "agent_explore": 1, "AGENT_MANAGE": 1,
				"PROMPT": 1, "git": 1,
				"customOne": 2, "customTwo": 1
			]
		)

		XCTAssertEqual(groups.map(\.icon), [
			"magnifyingglass",
			"pencil",
			"terminal",
			"bubble.left",
			"person.2",
			"gearshape",
			"ellipsis.circle"
		])
		XCTAssertEqual(groups.map(\.label), [
			"Navigate ×3",
			"Edit ×2",
			"Bash ×3",
			"Chat ×2",
			"Agent ×3",
			"Config ×2",
			"Other ×3"
		])
	}

	func testBlockIDStaysStableWhenAnchorActivityChangesPresentationKind() {
		let requestItem = AgentChatItem.user("Investigate", sequenceIndex: 0)
		let request = AgentTranscriptRequestAnchor(from: requestItem)
		let activityID = UUID()
		let baseTimestamp = Date(timeIntervalSince1970: 1)
		let clusterableActivity = AgentTranscriptActivity(
			id: activityID,
			timestamp: baseTimestamp,
			sequenceIndex: 1,
			role: .assistant,
			itemKind: .assistantInline,
			text: "checking parser",
			isSubstantiveAssistant: false,
			sealsAssistantBoundary: false
		)
		let standaloneActivity = AgentTranscriptActivity(
			id: activityID,
			timestamp: baseTimestamp,
			sequenceIndex: 1,
			role: .assistant,
			itemKind: .assistantInline,
			text: "Root cause is in Parser.swift.",
			isSubstantiveAssistant: true,
			sealsAssistantBoundary: false
		)
		let clusterableTurn = AgentTranscriptTurn(
			id: UUID(),
			request: request,
			responseSpans: [AgentTranscriptProviderResponseSpan(startedAt: baseTimestamp, activities: [clusterableActivity])],
			retentionTier: .full,
			startedAt: request.timestamp,
			completedAt: baseTimestamp
		)
		let standaloneTurn = AgentTranscriptTurn(
			id: clusterableTurn.id,
			request: request,
			responseSpans: [AgentTranscriptProviderResponseSpan(startedAt: baseTimestamp, activities: [standaloneActivity])],
			retentionTier: .full,
			startedAt: request.timestamp,
			completedAt: baseTimestamp
		)

		let clusterableBlockID = AgentTranscriptProjectionBuilder.blocks(for: clusterableTurn, archived: false)[1].id
		let standaloneBlockID = AgentTranscriptProjectionBuilder.blocks(for: standaloneTurn, archived: false)[1].id

		XCTAssertEqual(clusterableBlockID, standaloneBlockID)
	}

	func testGroupedHistoryAnchorBlockIndexResolvesGroupedHistoryAnchorToGroupedBlock() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		]))
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let groupedBlock = try XCTUnwrap(projection.workingBlocks.first(where: { $0.kind == .groupedHistory }))
		let groupedAnchor = try XCTUnwrap(groupedBlock.primaryAnchor)

		XCTAssertEqual(projection.anchorBlockIndex[groupedAnchor], groupedBlock.id)
	}

	func testGroupedHistoryAnchorBlockIndexResolvesHiddenChildAnchorToGroupedBlock() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		]))
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let groupedBlock = try XCTUnwrap(projection.workingBlocks.first(where: { $0.kind == .groupedHistory }))
		let hiddenChildBlock = try XCTUnwrap(groupedBlock.groupedHistory?.sections.first?.childBlocks.first)
		let hiddenChildAnchor = try XCTUnwrap(hiddenChildBlock.primaryAnchor)

		XCTAssertEqual(projection.anchorBlockIndex[hiddenChildAnchor], groupedBlock.id)
	}


	func testCondensedTierAnchorBlockIndexResolvesHiddenChildAnchorToGroupedBlock() throws {
		var transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		]))
		transcript.turns[0].retentionTier = .condensed
		let turn = try XCTUnwrap(transcript.turns.first)
		let span = try XCTUnwrap(turn.responseSpans.first)
		let hiddenActivity = try XCTUnwrap(span.activities.first(where: { $0.id != turn.conclusionActivityID }))
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let groupedBlock = try XCTUnwrap(projection.workingBlocks.first(where: { $0.kind == .groupedHistory }))
		let hiddenChildAnchor = try XCTUnwrap(projection.rowAnchorIndex[hiddenActivity.id])

		XCTAssertEqual(projection.anchorBlockIndex[hiddenChildAnchor], groupedBlock.id)
	}

	func testSummaryTierAnchorBlockIndexResolvesLegacySummaryAnchorToGroupedBlock() throws {
		var transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file"
		]))
		transcript.turns[0].retentionTier = .summary
		let turn = try XCTUnwrap(transcript.turns.first)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let groupedBlock = try XCTUnwrap(projection.workingBlocks.first(where: { $0.kind == .groupedHistory }))

		XCTAssertEqual(projection.anchorBlockIndex[.summary(turnID: turn.id)], groupedBlock.id)
	}

	func testCompactedTranscriptSessionStillRehydratesRenderableRowsFromStructuredTranscript() {
		let compacted = AgentTranscriptCompactor.compact(AgentTranscriptIO.importLegacyItems(makeLongTranscriptItems(turnCount: 24)))
		let session = AgentSession(items: [], transcript: compacted)
		let projection = AgentTranscriptProjectionBuilder.build(from: compacted)

		let liveItems = session.toLiveItems()

		XCTAssertEqual(liveItems.count, projection.archivedRows.count + projection.workingRows.count)
		XCTAssertTrue(liveItems.contains(where: { $0.kind == .user && $0.text == "user 0" }))
		XCTAssertTrue(liveItems.contains(where: { $0.kind == .system && $0.text.contains("read_file") }))
		XCTAssertTrue(liveItems.contains(where: { $0.kind == .assistant && $0.text == "final summary 0" }))
	}

	func testSessionStubRecoversMetadataFromTranscriptWithoutLegacyItems() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "TranscriptOnlySession", root: tempRoot)
		let service = AgentSessionDataService.shared

		let items = makeLongTranscriptItems(turnCount: 3)
		let compacted = AgentTranscriptCompactor.compact(AgentTranscriptIO.importLegacyItems(items))
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Transcript Only",
			items: [],
			transcript: compacted,
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let stub = try await service.loadAgentSessionStub(
			from: fileURL,
			recoverMissingMetadata: true,
			persistRecoveredMetadata: false
		)
		let loaded = try await service.loadAgentSession(from: fileURL)
		let loadedRows = AgentTranscriptIO.flattenFullTranscript(try XCTUnwrap(loaded.transcript))

		XCTAssertEqual(stub.lastUserMessageAt, items.last(where: { $0.kind == .user })?.timestamp)
		XCTAssertEqual(stub.itemCount, AgentTranscriptProjectionBuilder.projectedVisibleRowCount(for: compacted))
		XCTAssertEqual(loaded.transcript?.turns.count, compacted.turns.count)
		XCTAssertEqual(loaded.transcript?.nextSequenceIndex, compacted.nextSequenceIndex)
		XCTAssertEqual(loaded.transcript?.compactionFrontier, compacted.compactionFrontier)
		XCTAssertTrue(loadedRows.contains(where: { $0.kind == .toolResult }))
	}

	func testBuildForkTranscriptXMLIncludesCondensedSystemSummaryRows() {
		let invocationID = UUID()
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate prompt export", sequenceIndex: 0),
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .assistantInline, text: "checking the old transcript summary", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "mcp__RepoPrompt__read_file", invocationID: invocationID, argsJSON: #"{"path":"RepoPrompt/Services/AI/Prompts/Prompts.swift"}"#, sequenceIndex: 2),
			AgentChatItem.toolResult(name: "mcp__RepoPrompt__read_file", invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			AgentChatItem.assistant("final summary", sequenceIndex: 4)
		]

		var transcript = AgentTranscriptIO.importLegacyItems(items)
		transcript.turns[0].retentionTier = .condensed

		let xml = AgentTranscriptIO.buildForkTranscriptXML(from: transcript)

		XCTAssertFalse(xml.contains("<tool_call"))
		XCTAssertTrue(xml.contains(#"<assistant>final summary</assistant>"#))
	}

	func testBuildSpartanLogXMLIncludesCompactedSystemSummaryRows() throws {
		var transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search"
		]))
		transcript.turns[0].retentionTier = .summary

		let xml = AgentTranscriptIO.buildSpartanLogXML(from: transcript)

		XCTAssertTrue(xml.contains("<system>"), xml)
		XCTAssertTrue(xml.contains("read_file"), xml)
		XCTAssertTrue(xml.contains(#"<assistant>final summary</assistant>"#), xml)
	}

	func testBuildSpartanLogXMLPreservesInterleavedAssistantNarrationBetweenTools() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeInterleavedAssistantToolOrderingItems())

		let xml = AgentTranscriptIO.buildSpartanLogXML(from: transcript)

		let orderedSnippets = [
			"start calling tools read only, and between each tool say hello",
			"I'll read the README first.",
			"README.md",
			"Hello after README.",
			"GameManager.cs",
			"Hello after GameManager.",
			"BombBehavior.cs",
			"Hello final summary."
		]
		var previousUpperBound = xml.startIndex
		for snippet in orderedSnippets {
			let range = try XCTUnwrap(xml.range(of: snippet), "Missing expected snippet: \(snippet)\n\(xml)")
			XCTAssertLessThanOrEqual(previousUpperBound, range.lowerBound, "Snippet out of order: \(snippet)\n\(xml)")
			previousUpperBound = range.upperBound
		}
		XCTAssertFalse(xml.contains("omitted to fit"))
	}

	func testBuildSpartanLogXMLHonorsMaxTranscriptItemsBudget() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeInterleavedAssistantToolOrderingItems())

		let xml = AgentTranscriptIO.buildSpartanLogXML(from: transcript, maxTranscriptItems: 6)

		XCTAssertFalse(xml.contains("README.md"), xml)
		XCTAssertFalse(xml.contains("GameManager.cs"), xml)
		XCTAssertTrue(xml.contains("BombBehavior.cs"), xml)
		XCTAssertTrue(xml.contains("Hello after README."), xml)
		XCTAssertTrue(xml.contains("Hello after GameManager."), xml)
		XCTAssertTrue(xml.contains(#"<note>2 items omitted to fit 6 item budget.</note>"#), xml)
	}

	func testBuildForkTranscriptXMLStillCompactsIntermediateNarrationForInterleavedTools() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeInterleavedAssistantToolOrderingItems())

		let xml = AgentTranscriptIO.buildForkTranscriptXML(from: transcript)

		XCTAssertTrue(xml.contains("start calling tools read only, and between each tool say hello"))
		XCTAssertTrue(xml.contains("I'll read the README first."))
		XCTAssertTrue(xml.contains("README.md"))
		XCTAssertTrue(xml.contains("GameManager.cs"))
		XCTAssertTrue(xml.contains("BombBehavior.cs"))
		XCTAssertTrue(xml.contains("Hello final summary."))
		XCTAssertFalse(xml.contains("<assistant>Hello after README.</assistant>"))
	}

	func testBuildForkTranscriptXMLIncludesGroupedHistorySummaryForFullTurn() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search"
		]))

		let xml = AgentTranscriptIO.buildForkTranscriptXML(from: transcript)

		let step1Range = try XCTUnwrap(xml.range(of: "<assistant>step 1</assistant>"))
		let summaryRange = try XCTUnwrap(xml.range(of: "<system>Explored codebase • step 2"))
		let conclusionRange = try XCTUnwrap(xml.range(of: "<assistant>final summary</assistant>"))
		XCTAssertLessThan(step1Range.lowerBound, summaryRange.lowerBound)
		XCTAssertLessThan(summaryRange.lowerBound, conclusionRange.lowerBound)
		// step 2 collapsed into grouped history; steps 3-9 dropped as intermediate narration
		XCTAssertFalse(xml.contains("<assistant>step 2</assistant>"))
		for step in 3...9 {
			XCTAssertFalse(xml.contains("<assistant>step \(step)</assistant>"), "step \(step) should be dropped as intermediate narration")
		}
		// step 10 is the last intermediate — kept but truncated (short enough to survive intact)
		XCTAssertTrue(xml.contains("<assistant>step 10</assistant>"))
		XCTAssertEqual(xml.components(separatedBy: "<tool_call name=").count - 1, 8)
		XCTAssertFalse(xml.contains(#""summary_only":true"#))
		XCTAssertFalse(xml.contains(#""collapsed":true"#))
	}

#if DEBUG
	func testHandoffIntermediateNarrationIgnoresDisplaylessAssistantWhenSelectingConclusion() throws {
		let turnID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
		let realConclusionID = try XCTUnwrap(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
		let realConclusion = "Real conclusion sentinel. " + String(repeating: "This protected final answer detail must stay complete. ", count: 8)
		let displaylessPlaceholder = "\u{200B}\u{2060}\u{FEFF}"
		let rows: [AgentChatItem] = [
			AgentChatItem.assistant("I will inspect the relevant data first.", sequenceIndex: 0),
			AgentChatItem.toolCall(name: "read_file", invocationID: UUID(), argsJSON: #"{"path":"README.md"}"#, sequenceIndex: 1),
			AgentChatItem(
				id: realConclusionID,
				kind: .assistant,
				text: realConclusion,
				sequenceIndex: 2
			),
			AgentChatItem.assistant(displaylessPlaceholder, sequenceIndex: 3)
		]

		let filtered = AgentTranscriptIO.debugFilterIntermediateAssistantNarrationForTesting(rows, turnID: turnID)
		let filteredConclusion = try XCTUnwrap(
			filtered.first { $0.id == realConclusionID },
			"Filtering should retain the real post-tool conclusion when a later assistant placeholder is displayless."
		)

		XCTAssertEqual(
			filteredConclusion.text,
			realConclusion,
			"Displayless assistant placeholders must not become the last-assistant sentinel and truncate or drop the real conclusion."
		)
	}
#endif

	func testBuildHandoffTranscriptItemsMaterializeGroupedHistorySummarySystemItem() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search"
		]))
		let upToRowID = try XCTUnwrap(transcript.turns.first?.allActivities.last?.id)

		let items = AgentTranscriptIO.buildHandoffTranscriptItems(from: transcript, upToRowID: upToRowID)

		XCTAssertEqual(items.filter { $0.kind == .toolCall }.count, 0)
		XCTAssertEqual(items.filter { $0.kind == .toolResult }.count, 8)
		let summaryItem = try XCTUnwrap(items.first(where: { $0.kind == .system && $0.text.contains("Explored codebase") }))
		XCTAssertTrue(summaryItem.text.contains("step 2"))
		XCTAssertTrue(summaryItem.text.contains("read_file"))
	}

	func testBuildHandoffTranscriptItemsPreserveStandaloneToolResultStatusForMigratedSession() throws {
		var legacyItems = makeToolHeavyTurnItems(toolNames: ["read_file"])
		let resultIndex = try XCTUnwrap(legacyItems.firstIndex(where: { $0.kind == .toolResult && $0.toolName == "read_file" }))
		legacyItems[resultIndex].toolResultJSON = #"{"status":"success","output":"very large raw payload","details":{"line_count":42}}"#
		legacyItems[resultIndex].text = legacyItems[resultIndex].toolResultJSON ?? ""
		let transcript = AgentTranscriptIO.importLegacyItems(legacyItems)
		let upToRowID = try XCTUnwrap(transcript.turns.first?.allActivities.last?.id)

		var items = AgentTranscriptIO.buildHandoffTranscriptItems(from: transcript, upToRowID: upToRowID)
		let migratedToolResult = try XCTUnwrap(items.first(where: { $0.kind == .toolResult && $0.toolName == "read_file" }))
		XCTAssertTrue(migratedToolResult.toolResultJSON?.contains(#""status":"success""#) == true)
		XCTAssertTrue(migratedToolResult.toolResultJSON?.contains(#""summary_only":true"#) == true)
		XCTAssertFalse(migratedToolResult.toolResultJSON?.contains("very large raw payload") == true)
		XCTAssertEqual(items.filter { $0.kind == .toolCall && $0.toolName == "read_file" }.count, 0)

		let finalizedCount = AgentTranscriptIO.finalizePendingToolCalls(
			in: &items,
			terminalState: .idle,
			includeExplicitRepoPromptToolCalls: false,
			nonToolBoundary: 200
		)
		XCTAssertEqual(finalizedCount, 0)
		XCTAssertEqual(items.first(where: { $0.toolName == "read_file" })?.kind, .toolResult)
		XCTAssertTrue(items.first(where: { $0.toolName == "read_file" })?.toolResultJSON?.contains(#""status":"success""#) == true)
	}

	func testBuildHandoffTranscriptItemsPreserveFailedStandaloneToolResultWhenXMLPreviewIsOmitted() throws {
		var legacyItems = makeToolHeavyTurnItems(toolNames: ["read_file"], resultStatusByToolIndex: [0: "failed"])
		let resultIndex = try XCTUnwrap(legacyItems.firstIndex(where: { $0.kind == .toolResult && $0.toolName == "read_file" }))
		legacyItems[resultIndex].toolResultJSON = #"{"status":"failed","stderr":"sensitive failure details","code":1}"#
		legacyItems[resultIndex].text = legacyItems[resultIndex].toolResultJSON ?? ""
		let transcript = AgentTranscriptIO.importLegacyItems(legacyItems)
		let upToRowID = try XCTUnwrap(transcript.turns.first?.allActivities.last?.id)

		var items = AgentTranscriptIO.buildHandoffTranscriptItems(from: transcript, upToRowID: upToRowID)
		let migratedToolResult = try XCTUnwrap(items.first(where: { $0.kind == .toolResult && $0.toolName == "read_file" }))
		XCTAssertTrue(migratedToolResult.toolResultJSON?.contains(#""status":"failed""#) == true)
		XCTAssertTrue(migratedToolResult.toolResultJSON?.contains(#""summary_only":true"#) == true)
		XCTAssertFalse(migratedToolResult.toolResultJSON?.contains("sensitive failure details") == true)
		XCTAssertEqual(items.filter { $0.kind == .toolCall && $0.toolName == "read_file" }.count, 0)

		let finalizedCount = AgentTranscriptIO.finalizePendingToolCalls(
			in: &items,
			terminalState: .idle,
			includeExplicitRepoPromptToolCalls: false,
			nonToolBoundary: 200
		)
		XCTAssertEqual(finalizedCount, 0)
		XCTAssertEqual(items.first(where: { $0.toolName == "read_file" })?.kind, .toolResult)
		XCTAssertTrue(items.first(where: { $0.toolName == "read_file" })?.toolResultJSON?.contains(#""status":"failed""#) == true)
	}

	func testHandoffExportStopsAtGroupedHistorySummaryWhenCutoffFallsInsideHiddenHistory() throws {
		let transcript = AgentTranscriptIO.importLegacyItems(makeToolHeavyTurnItems(toolNames: [
			"read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search"
		]))
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let groupedHistoryBlock = try XCTUnwrap(
			(projection.workingBlocks + projection.archivedBlocks).first(where: { $0.kind == .groupedHistory })
		)
		let hiddenToolResultID = try XCTUnwrap(groupedHistoryBlock.activityIDs.first)

		XCTAssertTrue(AgentTranscriptIO.isValidHandoffExportCutoffRowID(hiddenToolResultID, in: transcript))
		XCTAssertFalse(AgentTranscriptIO.isValidHandoffExportCutoffRowID(UUID(), in: transcript))

		let items = AgentTranscriptIO.buildHandoffTranscriptItems(from: transcript, upToRowID: hiddenToolResultID)
		let xml = AgentTranscriptIO.buildForkTranscriptXML(from: transcript, upToRowID: hiddenToolResultID)

		XCTAssertTrue(items.contains(where: { $0.kind == .system && $0.text.contains("Explored codebase") }))
		XCTAssertFalse(items.contains(where: { $0.kind == .assistant && $0.text == "step 3" }))
		XCTAssertEqual(items.filter { $0.kind == .toolCall }.count, 0)
		XCTAssertFalse(xml.contains("<assistant>step 3</assistant>"))
		XCTAssertEqual(xml.components(separatedBy: "<tool_call name=").count - 1, 0)
	}

	func testHandoffCutoffValidationRejectsThinkingRowsExcludedFromExportUniverse() {
		let user = AgentChatItem.user("Investigate", sequenceIndex: 0)
		let thinking = AgentChatItem.thinking("Private scratchpad", sequenceIndex: 1)
		let assistant = AgentChatItem.assistant("Done", sequenceIndex: 2)
		let transcript = AgentTranscriptIO.importLegacyItems([user, thinking, assistant])

		XCTAssertTrue(AgentTranscriptIO.isValidHandoffExportCutoffRowID(user.id, in: transcript))
		XCTAssertFalse(AgentTranscriptIO.isValidHandoffExportCutoffRowID(thinking.id, in: transcript))
		XCTAssertTrue(AgentTranscriptIO.isValidHandoffExportCutoffRowID(assistant.id, in: transcript))
	}

	func testBuildForkTranscriptXMLDropsToolCallsFirstWhenOverBudget() {
		let items: [AgentChatItem] = [
			AgentChatItem.user("Investigate", sequenceIndex: 0),
			AgentChatItem.assistant("Need to inspect the file first", sequenceIndex: 1),
			AgentChatItem.toolCall(name: "read_file", invocationID: nil, argsJSON: #"{"path":"Parser.swift"}"#, sequenceIndex: 2),
			AgentChatItem.toolResult(name: "read_file", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3)
		]
		let transcript = AgentTranscriptIO.importLegacyItems(items)

		// Budget of 2: the single assistant is the turn conclusion (essential along with the user message).
		// The tool call is lowest priority and gets dropped first.
		let xml = AgentTranscriptIO.buildForkTranscriptXML(from: transcript, maxTranscriptItems: 2)

		XCTAssertFalse(xml.contains("<tool_call"))
		XCTAssertTrue(xml.contains("<user>"))
		XCTAssertTrue(xml.contains("<assistant>Need to inspect the file first</assistant>"))
		XCTAssertTrue(xml.contains(#"<note>1 item omitted to fit 2 item budget.</note>"#))
	}

	func testBuildForkTranscriptXMLDropsOldestWholeTurnsWhenEssentialItemsExceedBudget() {
		let items: [AgentChatItem] = [
			AgentChatItem.user("user 0", sequenceIndex: 0),
			AgentChatItem.assistant("answer 0", sequenceIndex: 1),
			AgentChatItem.user("user 1", sequenceIndex: 2),
			AgentChatItem.assistant("answer 1", sequenceIndex: 3),
			AgentChatItem.user("user 2", sequenceIndex: 4),
			AgentChatItem.assistant("answer 2", sequenceIndex: 5)
		]
		let transcript = AgentTranscriptIO.importLegacyItems(items)

		let xml = AgentTranscriptIO.buildForkTranscriptXML(from: transcript, maxTranscriptItems: 4)

		XCTAssertFalse(xml.contains("<user>user 0</user>"))
		XCTAssertFalse(xml.contains("<assistant>answer 0</assistant>"))
		XCTAssertTrue(xml.contains("<user>user 1</user>"))
		XCTAssertTrue(xml.contains("<assistant>answer 1</assistant>"))
		XCTAssertTrue(xml.contains("<user>user 2</user>"))
		XCTAssertTrue(xml.contains("<assistant>answer 2</assistant>"))
		XCTAssertTrue(xml.contains(#"<note>2 items omitted to fit 4 item budget.</note>"#))
	}

	func testBuildForkTranscriptXMLCountsMergedSystemOutputAgainstBudget() {
		let invocationID = UUID()
		let assistantID = UUID()
		let toolExecution = AgentTranscriptToolExecution(
			stableExecutionID: "read_file#1",
			toolName: "read_file",
			invocationID: invocationID,
			argsJSON: #"{"path":"Parser.swift"}"#,
			resultJSON: nil,
			toolIsError: nil,
			status: .pending
		)
		let activities: [AgentTranscriptActivity] = [
			AgentTranscriptActivity(
				id: UUID(),
				timestamp: Date(timeIntervalSince1970: 1),
				sequenceIndex: 1,
				role: .system,
				itemKind: .system,
				text: "summary A"
			),
			AgentTranscriptActivity(
				id: UUID(),
				timestamp: Date(timeIntervalSince1970: 2),
				sequenceIndex: 2,
				role: .toolExecution,
				itemKind: .toolCall,
				text: "",
				toolExecution: toolExecution
			),
			AgentTranscriptActivity(
				id: UUID(),
				timestamp: Date(timeIntervalSince1970: 3),
				sequenceIndex: 3,
				role: .system,
				itemKind: .system,
				text: "summary B"
			),
			AgentTranscriptActivity(
				id: assistantID,
				timestamp: Date(timeIntervalSince1970: 4),
				sequenceIndex: 4,
				role: .assistant,
				itemKind: .assistant,
				text: "final summary",
				isSubstantiveAssistant: true,
				sealsAssistantBoundary: true
			)
		]
		let request = AgentTranscriptRequestAnchor(from: AgentChatItem.user("Investigate", sequenceIndex: 0))
		let turn = AgentTranscriptTurn(
			id: UUID(),
			request: request,
			responseSpans: [
				AgentTranscriptProviderResponseSpan(
					startedAt: request.timestamp,
					lastActivityAt: Date(timeIntervalSince1970: 4),
					completedAt: Date(timeIntervalSince1970: 4),
					activities: activities
				)
			],
			conclusionActivityID: assistantID,
			startedAt: request.timestamp,
			lastActivityAt: Date(timeIntervalSince1970: 4),
			completedAt: Date(timeIntervalSince1970: 4)
		)
		let transcript = AgentTranscript(turns: [turn], nextSequenceIndex: 5)

		let xml = AgentTranscriptIO.buildForkTranscriptXML(from: transcript, maxTranscriptItems: 3)

		XCTAssertFalse(xml.contains("<tool_call"))
		XCTAssertTrue(xml.contains("summary A"))
		XCTAssertTrue(xml.contains("summary B"))
		XCTAssertTrue(xml.contains("<assistant>final summary</assistant>"))
		XCTAssertTrue(xml.contains(#"<note>1 item omitted to fit 3 item budget.</note>"#))
	}

	private func promptExportEnvelopeJSON(
		path: String,
		tokens: Int,
		bytes: Int,
		files: [[String: Any]],
		copyPreset: [String: Any]? = nil,
		extraExportFields: [String: Any] = [:],
		extraEnvelopeFields: [String: Any] = [:]
	) throws -> String {
		var export: [String: Any] = [
			"path": path,
			"tokens": tokens,
			"bytes": bytes,
			"files": files
		]
		if let copyPreset {
			export["copy_preset"] = copyPreset
		}
		for (key, value) in extraExportFields {
			export[key] = value
		}
		var envelope: [String: Any] = [
			"op": "export",
			"export": export
		]
		for (key, value) in extraEnvelopeFields {
			envelope[key] = value
		}
		let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
		return String(data: data, encoding: .utf8) ?? ""
	}

	private func decodePromptToolEnvelope(
		_ json: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) throws -> ToolResultDTOs.PromptToolEnvelope {
		let data = try XCTUnwrap(json.data(using: .utf8), file: file, line: line)
		return try JSONDecoder().decode(ToolResultDTOs.PromptToolEnvelope.self, from: data)
	}

	private func persistedToolResultActivity(
		toolName: String,
		resultJSON: String,
		argsJSON: String? = nil,
		file: StaticString = #filePath,
		line: UInt = #line
	) throws -> (activity: AgentTranscriptActivity, execution: AgentTranscriptToolExecution, encoded: String) {
		var result = AgentChatItem.toolResult(
			name: toolName,
			invocationID: UUID(),
			resultJSON: resultJSON,
			isError: false,
			sequenceIndex: 1
		)
		result.toolArgsJSON = argsJSON
		let items: [AgentChatItem] = [
			.user("Run tool", sequenceIndex: 0),
			result
		]
		let persisted = AgentTranscriptIO.persistedTranscript(AgentTranscriptIO.importLegacyItems(items))
		let activity = try XCTUnwrap(
			persisted.turns.first?.allActivities.first(where: { $0.itemKind == .toolResult }),
			file: file,
			line: line
		)
		let execution = try XCTUnwrap(activity.toolExecution, file: file, line: line)
		let encoded = String(data: try JSONEncoder().encode(persisted), encoding: .utf8) ?? ""
		return (activity, execution, encoded)
	}

	private func renderSummaryObject(
		from resultObject: [String: Any],
		file: StaticString = #filePath,
		line: UInt = #line
	) throws -> [String: Any] {
		let renderSummary = try XCTUnwrap(
			resultObject["render_summary"] as? [String: Any],
			"Expected persisted summary-only JSON to include render_summary",
			file: file,
			line: line
		)
		XCTAssertEqual(ToolRawJSON.int(renderSummary, key: "schema_version"), 1, file: file, line: line)
		return renderSummary
	}

	private func assertPersistedToolResultIsSummaryOnly(
		_ persisted: (activity: AgentTranscriptActivity, execution: AgentTranscriptToolExecution, encoded: String),
		excluding sentinel: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertFalse(persisted.encoded.contains(sentinel), file: file, line: line)
		XCTAssertFalse(persisted.activity.text.contains(sentinel), file: file, line: line)
		XCTAssertFalse(persisted.execution.resultJSON?.contains(sentinel) == true, file: file, line: line)
		XCTAssertNil(persisted.execution.argsJSON, file: file, line: line)
		XCTAssertEqual(persisted.execution.keyPaths, [], file: file, line: line)
		XCTAssertTrue(persisted.execution.summaryOnly, file: file, line: line)
		XCTAssertLessThanOrEqual(
			persisted.activity.text.utf8.count,
			AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes,
			file: file,
			line: line
		)
		XCTAssertLessThanOrEqual(
			persisted.execution.resultJSON?.utf8.count ?? 0,
			AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes,
			file: file,
			line: line
		)
		guard let object = ToolRawJSON.object(from: persisted.execution.resultJSON) else {
			XCTFail("Expected summary-only JSON", file: file, line: line)
			return
		}
		XCTAssertTrue(ToolRawJSON.bool(object, key: "summary_only") == true, file: file, line: line)
		XCTAssertEqual(persisted.activity.text, persisted.execution.resultJSON, file: file, line: line)
	}

	private func makeLongTranscriptItems(turnCount: Int) -> [AgentChatItem] {
		var items: [AgentChatItem] = []
		var sequenceIndex = 0
		for turn in 0..<turnCount {
			let baseDate = Date(timeIntervalSince1970: TimeInterval(turn * 10))
			items.append(AgentChatItem(timestamp: baseDate, kind: .user, text: "user \(turn)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem(timestamp: baseDate.addingTimeInterval(1), kind: .assistantInline, text: "checking \(turn)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolCall(name: "read_file", invocationID: nil, argsJSON: "{\"path\":\"file\(turn).swift\"}", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolResult(name: "read_file", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem(timestamp: baseDate.addingTimeInterval(2), kind: .assistant, text: "final summary \(turn)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		return items
	}

	private func makeInterleavedAssistantToolOrderingItems() -> [AgentChatItem] {
		let firstInvocationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
		let secondInvocationID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
		let thirdInvocationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
		return [
			.user("start calling tools read only, and between each tool say hello", sequenceIndex: 0),
			.assistant("I'll read the README first.", sequenceIndex: 1),
			.toolCall(name: "read_file", invocationID: firstInvocationID, argsJSON: #"{"path":"README.md"}"#, sequenceIndex: 2),
			.toolResult(name: "read_file", invocationID: firstInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			.assistant("Hello after README.", sequenceIndex: 4),
			.toolCall(name: "read_file", invocationID: secondInvocationID, argsJSON: #"{"path":"Assets/Content/Scripts/GameManager.cs"}"#, sequenceIndex: 5),
			.toolResult(name: "read_file", invocationID: secondInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 6),
			.assistant("Hello after GameManager.", sequenceIndex: 7),
			.toolCall(name: "read_file", invocationID: thirdInvocationID, argsJSON: #"{"path":"Assets/Content/Scripts/BombBehavior.cs"}"#, sequenceIndex: 8),
			.toolResult(name: "read_file", invocationID: thirdInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 9),
			.assistant("Hello final summary.", sequenceIndex: 10)
		]
	}

	private func makeToolHeavyTurnItems(
		toolNames: [String],
		resultStatusByToolIndex: [Int: String] = [:],
		startingSequenceIndex: Int = 0,
		userText: String = "Investigate",
		finalSummaryText: String = "final summary"
	) -> [AgentChatItem] {
		var items: [AgentChatItem] = [AgentChatItem.user(userText, sequenceIndex: startingSequenceIndex)]
		var sequenceIndex = startingSequenceIndex + 1
		for (offset, toolName) in toolNames.enumerated() {
			let step = offset + 1
			let invocationID = UUID()
			items.append(AgentChatItem(
				timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceIndex)),
				kind: .assistantInline,
				text: "step \(step)",
				sequenceIndex: sequenceIndex
			))
			sequenceIndex += 1
			let argsJSON: String
			switch toolName {
			case "search":
				argsJSON = #"{"pattern":"Parser"}"#
			case "bash":
				argsJSON = #"{"cmd":"swift test"}"#
			case "apply_edits":
				argsJSON = #"{"path":"Parser.swift"}"#
			default:
				argsJSON = #"{"path":"Parser.swift"}"#
			}
			items.append(AgentChatItem.toolCall(name: toolName, invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			let rawStatus = resultStatusByToolIndex[offset] ?? "success"
			let resultJSON: String
			if toolName == "bash" {
				resultJSON = #"{"status":"\#(rawStatus)","exitCode":0}"#
			} else {
				resultJSON = #"{"status":"\#(rawStatus)"}"#
			}
			items.append(AgentChatItem.toolResult(name: toolName, invocationID: invocationID, resultJSON: resultJSON, isError: rawStatus != "success", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		items.append(AgentChatItem.assistant(finalSummaryText, sequenceIndex: sequenceIndex))
		return items
	}

	private func makeMultiTurnToolHeavyItems(toolNamesByTurn: [[String]]) -> [AgentChatItem] {
		var sequenceIndex = 0
		var items: [AgentChatItem] = []
		for (offset, toolNames) in toolNamesByTurn.enumerated() {
			let turnItems = makeToolHeavyTurnItems(
				toolNames: toolNames,
				startingSequenceIndex: sequenceIndex,
				userText: "Investigate \(offset + 1)",
				finalSummaryText: "final summary \(offset + 1)"
			)
			items.append(contentsOf: turnItems)
			sequenceIndex = (turnItems.last?.sequenceIndex ?? sequenceIndex) + 1
		}
		return items
	}

	private func makeContextRichMultiTurnToolItems(toolNamesByTurn: [[String]]) -> [AgentChatItem] {
		var sequenceIndex = 0
		var items: [AgentChatItem] = []
		for (offset, toolNames) in toolNamesByTurn.enumerated() {
			let turnItems = makeContextRichToolTurnItems(
				toolNames: toolNames,
				startingSequenceIndex: sequenceIndex,
				userText: "Context turn \(offset + 1)",
				finalSummaryText: "context final summary \(offset + 1)"
			)
			items.append(contentsOf: turnItems)
			sequenceIndex = (turnItems.last?.sequenceIndex ?? sequenceIndex) + 1
		}
		return items
	}

	private func sequenceIndexSet(for turn: AgentTranscriptTurn) -> Set<Int> {
		Set(([turn.request?.sequenceIndex].compactMap { $0 }) + turn.allActivities.map(\.sequenceIndex))
	}

	private func appendSyntheticVisibleToolTurn(
		to transcript: AgentTranscript,
		toolExecutionCount: Int,
		label: String
	) -> AgentTranscript {
		let workingItems = AgentTranscriptIO.workingSourceItems(from: transcript)
		let nextSequenceIndex = (workingItems.map(\.sequenceIndex).max() ?? transcript.nextSequenceIndex - 1) + 1
		let toolCycle = ["read_file", "search", "bash"]
		let appendedItems = makeContextRichToolTurnItems(
			toolNames: (0..<toolExecutionCount).map { toolCycle[$0 % toolCycle.count] },
			startingSequenceIndex: nextSequenceIndex,
			userText: "Synthetic production append \(label)",
			finalSummaryText: "PRODUCTION_APPEND_DONE_\(label)_\(toolExecutionCount)"
		)
		return AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
			existingTranscript: transcript,
			workingItems: workingItems + appendedItems,
			nextSequenceIndex: nextSequenceIndex + appendedItems.count
		)
	}

	private func makeContextRichToolTurnItems(
		toolNames: [String],
		startingSequenceIndex: Int = 0,
		userText: String = "Context-rich investigate",
		finalSummaryText: String = "context-rich final summary"
	) -> [AgentChatItem] {
		var items: [AgentChatItem] = [AgentChatItem.user(userText, sequenceIndex: startingSequenceIndex)]
		var sequenceIndex = startingSequenceIndex + 1
		items.append(AgentChatItem.assistantInline("Starting investigation", sequenceIndex: sequenceIndex))
		sequenceIndex += 1
		items.append(AgentChatItem.thinking("Planning tool sequence", sequenceIndex: sequenceIndex))
		sequenceIndex += 1
		for (offset, toolName) in toolNames.enumerated() {
			let invocationID = UUID()
			items.append(AgentChatItem.system("Progress before tool \(offset + 1)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			let argsJSON: String
			switch toolName {
			case "search":
				argsJSON = #"{"pattern":"Tail"}"#
			case "bash":
				argsJSON = #"{"cmd":"swift test"}"#
			default:
				argsJSON = #"{"path":"Tail.swift"}"#
			}
			items.append(AgentChatItem.toolCall(name: toolName, invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolResult(name: toolName, invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.assistantInline("Observed tool \(offset + 1)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		items.append(AgentChatItem.assistant(finalSummaryText, sequenceIndex: sequenceIndex))
		return items
	}

	private func makeSeparatedCallResultToolTurnItems(
		toolNames: [String],
		startingSequenceIndex: Int,
		userText: String,
		finalSummaryText: String
	) -> [AgentChatItem] {
		var items: [AgentChatItem] = [AgentChatItem.user(userText, sequenceIndex: startingSequenceIndex)]
		var sequenceIndex = startingSequenceIndex + 1
		for (offset, toolName) in toolNames.enumerated() {
			let invocationID = UUID()
			items.append(AgentChatItem.toolCall(name: toolName, invocationID: invocationID, argsJSON: #"{"pattern":"Separated"}"#, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.thinking("Thinking between call and result \(offset + 1)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.system("Progress between call and result \(offset + 1)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolResult(name: toolName, invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		items.append(AgentChatItem.assistant(finalSummaryText, sequenceIndex: sequenceIndex))
		return items
	}

	private func makeHiddenInternalToolTurnItems(
		toolCount: Int,
		startingSequenceIndex: Int,
		userText: String,
		finalSummaryText: String
	) -> [AgentChatItem] {
		var items: [AgentChatItem] = [AgentChatItem.user(userText, sequenceIndex: startingSequenceIndex)]
		var sequenceIndex = startingSequenceIndex + 1
		for offset in 0..<toolCount {
			let invocationID = UUID()
			items.append(AgentChatItem.toolCall(name: "set_status", invocationID: invocationID, argsJSON: #"{"session_name":"hidden"}"#, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolResult(name: "set_status", invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.assistantInline("hidden tool \(offset + 1) filtered", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		items.append(AgentChatItem.assistant(finalSummaryText, sequenceIndex: sequenceIndex))
		return items
	}

	private func makeStructurallyCompactedSummaryTranscript(turnCount: Int, toolCountPerTurn: Int) -> AgentTranscript {
		let turns = (0..<turnCount).map { index -> AgentTranscriptTurn in
			let request = AgentChatItem.user("summary user \(index)", sequenceIndex: index * 3)
			let summary = AgentTranscriptTurnSummary(
				requestText: nil,
				conclusionText: "summary conclusion \(index)",
				compactConclusionText: "summary conclusion \(index)",
				middleSummaryText: "summarized tool work \(index)",
				toolCount: toolCountPerTurn,
				notableToolNames: ["read_file"],
				keyPaths: [],
				compactedActivityCount: toolCountPerTurn * 2,
				hadWarning: false,
				hadError: false
			)
			let collapsedSummary = AgentTranscriptGroupedHistorySummary(
				hiddenToolCardCount: toolCountPerTurn,
				hiddenAssistantCount: 0,
				hiddenProgressCount: 0,
				hiddenNoteCount: 0,
				toolSummary: nil
			)
			let conclusionActivity: AgentTranscriptActivity? = index.isMultiple(of: 2)
				? nil
				: AgentTranscriptActivity(
					from: AgentChatItem.assistant("summary conclusion \(index)", sequenceIndex: index * 3 + 2)
				)
			let span = AgentTranscriptProviderResponseSpan(
				startedAt: request.timestamp,
				lastActivityAt: conclusionActivity?.timestamp ?? request.timestamp,
				completedAt: conclusionActivity?.timestamp ?? request.timestamp,
				activities: conclusionActivity.map { [$0] } ?? [],
				collapsedSummary: collapsedSummary
			)
			return AgentTranscriptTurn(
				id: request.id,
				request: AgentTranscriptRequestAnchor(from: request),
				responseSpans: [span],
				conclusionActivityID: conclusionActivity?.id,
				retentionTier: .summary,
				summary: summary,
				startedAt: request.timestamp,
				lastActivityAt: conclusionActivity?.timestamp ?? request.timestamp,
				completedAt: conclusionActivity?.timestamp ?? request.timestamp
			)
		}
		return AgentTranscript(turns: turns, nextSequenceIndex: turnCount * 3)
	}

	private func assertNoProjectedAnchor(
		for activityID: UUID,
		in projection: AgentTranscriptProjection,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertNil(projection.rowAnchorIndex[activityID], file: file, line: line)
		XCTAssertFalse(
			projection.anchorBlockIndex.keys.contains { anchor in
				switch anchor {
				case .activity(_, _, let anchoredActivityID), .conclusion(_, let anchoredActivityID):
					return anchoredActivityID == activityID
				case .request, .summary, .groupedHistory:
					return false
				}
			},
			file: file,
			line: line
		)
	}

	private func presentedItemCount(for blocks: [AgentTranscriptRenderBlock]) -> Int {
		blocks.reduce(0) { partial, block in
			switch block.kind {
			case .activityCluster, .groupedHistory:
				return partial + 1
			case .request, .standaloneAssistant, .standaloneTool, .standaloneNote, .middleSummary, .conclusion:
				return partial + block.rows.count
			}
		}
	}

	private func makeLowSignalToolHeavyTurnItems(
		toolNames: [String],
		startingSequenceIndex: Int = 0,
		userText: String = "Investigate",
		finalSummaryText: String = "final summary"
	) -> [AgentChatItem] {
		var items: [AgentChatItem] = [AgentChatItem.user(userText, sequenceIndex: startingSequenceIndex)]
		var sequenceIndex = startingSequenceIndex + 1
		for (offset, toolName) in toolNames.enumerated() {
			let invocationID = UUID()
			items.append(AgentChatItem(
				timestamp: Date(timeIntervalSince1970: TimeInterval(sequenceIndex)),
				kind: .assistantInline,
				text: offset.isMultiple(of: 2) ? "checking parser" : "searching usage sites",
				sequenceIndex: sequenceIndex
			))
			sequenceIndex += 1
			let argsJSON = toolName == "search" ? #"{"pattern":"Parser"}"# : #"{"path":"Parser.swift"}"#
			items.append(AgentChatItem.toolCall(name: toolName, invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolResult(name: toolName, invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		items.append(AgentChatItem.assistant(finalSummaryText, sequenceIndex: sequenceIndex))
		return items
	}

	// MARK: - Historical Truncation Policy Tests

	func testHistoricalTruncationLeavesSmallFixtureUnchanged() throws {
		let transcript = try loadLiveSessionFixtureTranscript()

		let truncated = AgentTranscriptHistoricalTruncationPolicy.truncatedTranscript(transcript)

		// Every turn should be byte-identical since no field exceeds the 10k token cap.
		XCTAssertEqual(transcript.turns.count, truncated.turns.count)
		for (original, reduced) in zip(transcript.turns, truncated.turns) {
			XCTAssertEqual(original, reduced, "Turn \(original.id) should not have been modified")
		}
	}

	func testLiveSessionFixtureCompactionStaysHighFidelityWithoutArchiveOrTruncation() throws {
		let transcript = try loadLiveSessionFixtureTranscript()
		let compacted = AgentTranscriptCompactor.compact(transcript)
		let compactedProjection = AgentTranscriptProjectionBuilder.build(from: compacted)
		let tierSummary = compacted.turns.enumerated().map { index, turn in
			"\(index):\(turn.retentionTier)"
		}.joined(separator: ", ")
		print("Live fixture compaction tiers -> \(tierSummary)")

		XCTAssertEqual(compacted.turns.count, transcript.turns.count)
		XCTAssertGreaterThanOrEqual(compacted.turns.filter { $0.retentionTier == .full }.count, 1)
		XCTAssertEqual(compactedProjection.archivedBlocks.count, 0)

		let conversationHistory = AgentTranscriptIO.buildConversationHistory(from: compacted)
		XCTAssertFalse(conversationHistory.contains("[content truncated]"))
		XCTAssertTrue(conversationHistory.contains("Weve been having issues with the scroll getting stuck"))
		XCTAssertTrue(conversationHistory.contains("also consider the context provided in this session"))
	}

	func testHistoricalTruncationReducesOversizedOldTurns() {
		// Build a transcript where old turns have huge assistant text that exceeds the cap.
		let oversizedText = String(repeating: "x", count: 60_000) // ~15k tokens at 4 bytes/token
		var items: [AgentChatItem] = []
		var seq = 0

		// 6 turns: turns 0-2 are old and oversized, turns 3-5 are recent (exempt)
		for turn in 0..<6 {
			let baseDate = Date(timeIntervalSince1970: TimeInterval(turn * 100))
			items.append(AgentChatItem(timestamp: baseDate, kind: .user, text: "user \(turn)", sequenceIndex: seq))
			seq += 1
			let text = turn < 3 ? oversizedText : "short response \(turn)"
			items.append(AgentChatItem(timestamp: baseDate.addingTimeInterval(1), kind: .assistant, text: text, sequenceIndex: seq))
			seq += 1
		}

		let transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)
		XCTAssertEqual(transcript.turns.count, 6)

		let truncated = AgentTranscriptHistoricalTruncationPolicy.truncatedTranscript(transcript)
		XCTAssertEqual(truncated.turns.count, 6)

		// Old turns (0-2) should have been truncated.
		for i in 0..<3 {
			let originalActivities = transcript.turns[i].allActivities
			let truncatedActivities = truncated.turns[i].allActivities
			let originalAssistant = originalActivities.first(where: { $0.itemKind == .assistant })!
			let truncatedAssistant = truncatedActivities.first(where: { $0.itemKind == .assistant })!

			XCTAssertTrue(
				truncatedAssistant.text.utf8.count < originalAssistant.text.utf8.count,
				"Turn \(i) assistant text should be smaller after truncation"
			)
			XCTAssertTrue(
				truncatedAssistant.text.contains("[content truncated]"),
				"Turn \(i) should contain truncation marker"
			)
			// Should be roughly 10k tokens * 4 = 40k bytes
			let truncatedBytes = truncatedAssistant.text.utf8.count
			XCTAssertTrue(truncatedBytes < 41_000, "Truncated text should be near the 40k byte budget, got \(truncatedBytes)")
		}

		// Recent turns (3-5) should be untouched.
		for i in 3..<6 {
			let originalActivities = transcript.turns[i].allActivities
			let truncatedActivities = truncated.turns[i].allActivities
			XCTAssertEqual(
				originalActivities.first(where: { $0.itemKind == .assistant })?.text,
				truncatedActivities.first(where: { $0.itemKind == .assistant })?.text,
				"Turn \(i) should be exempt from truncation"
			)
		}
	}

	func testHistoricalTruncationNeverTouchesUserMessagesOrToolJSON() {
		let oversizedText = String(repeating: "y", count: 60_000)
		var items: [AgentChatItem] = []
		var seq = 0
		let baseDate = Date(timeIntervalSince1970: 0)

		// Turn 0: old turn with oversized user text and tool args — both should be preserved.
		items.append(AgentChatItem(timestamp: baseDate, kind: .user, text: oversizedText, sequenceIndex: seq))
		seq += 1
		let invocationID = UUID()
		items.append(AgentChatItem.toolCall(name: "bash", invocationID: invocationID, argsJSON: oversizedText, sequenceIndex: seq))
		seq += 1
		items.append(AgentChatItem.toolResult(name: "bash", invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: seq))
		seq += 1
		items.append(AgentChatItem(timestamp: baseDate.addingTimeInterval(1), kind: .assistant, text: "done", sequenceIndex: seq))
		seq += 1

		// Turns 1-4: filler to push turn 0 out of the exempt window
		for turn in 1...4 {
			let d = Date(timeIntervalSince1970: TimeInterval(turn * 100))
			items.append(AgentChatItem(timestamp: d, kind: .user, text: "filler \(turn)", sequenceIndex: seq))
			seq += 1
			items.append(AgentChatItem(timestamp: d.addingTimeInterval(1), kind: .assistant, text: "reply \(turn)", sequenceIndex: seq))
			seq += 1
		}

		let transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)
		let truncated = AgentTranscriptHistoricalTruncationPolicy.truncatedTranscript(transcript)

		// User message text in turn 0 should be preserved verbatim.
		let originalRequest = transcript.turns[0].request?.text
		let truncatedRequest = truncated.turns[0].request?.text
		XCTAssertEqual(originalRequest, truncatedRequest, "User messages must never be truncated")

		// Tool argsJSON should be preserved verbatim.
		let originalArgs = transcript.turns[0].allActivities
			.compactMap(\.toolExecution?.argsJSON)
			.first(where: { $0.count > 1000 })
		let truncatedArgs = truncated.turns[0].allActivities
			.compactMap(\.toolExecution?.argsJSON)
			.first(where: { $0.count > 1000 })
		XCTAssertEqual(originalArgs, truncatedArgs, "Tool argsJSON must never be truncated")
	}

	func testCompactorWithSimulatedBytesDoesNotOverCullWhenSingleMessageIsHuge() {
		// Build a transcript where one old turn has a massive assistant message
		// but the total turn count is modest. The compactor should not aggressively
		// demote turns just because of the one oversized message.
		var items: [AgentChatItem] = []
		var seq = 0

		// 5 turns: turn 0 has a huge message, turns 1-4 are normal sized
		for turn in 0..<5 {
			let d = Date(timeIntervalSince1970: TimeInterval(turn * 100))
			items.append(AgentChatItem(timestamp: d, kind: .user, text: "user \(turn)", sequenceIndex: seq))
			seq += 1
			let text: String
			if turn == 0 {
				text = String(repeating: "z", count: 200_000) // ~50k tokens
			} else {
				text = "normal response \(turn)"
			}
			items.append(AgentChatItem(timestamp: d.addingTimeInterval(1), kind: .assistant, text: text, sequenceIndex: seq))
			seq += 1
		}

		let transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)

		// The simulated byte count should be dramatically lower than the actual.
		let actualBytes = transcript.turns.reduce(0) { sum, turn in
			sum + turn.allActivities.reduce(0) { $0 + $1.text.utf8.count }
		}
		let simulatedBytes = AgentTranscriptHistoricalTruncationPolicy.simulatedRetainedFullDetailBytes(for: transcript)

		XCTAssertTrue(
			simulatedBytes < actualBytes,
			"Simulated bytes (\(simulatedBytes)) should be less than actual (\(actualBytes))"
		)

		// Compact with our new logic — should keep more turns at full detail
		// than if we were using raw byte counts.
		let compacted = AgentTranscriptCompactor.compact(transcript)
		let fullTurns = compacted.turns.filter { $0.retentionTier == .full }
		XCTAssertTrue(
			fullTurns.count >= 3,
			"Should retain at least 3 full turns (got \(fullTurns.count)) — oversized turn 0 shouldn't force culling of normal turns"
		)
	}

	func testPersistedTranscriptAppliesHistoricalTruncation() throws {
		let oversizedText = String(repeating: "w", count: 60_000)
		var items: [AgentChatItem] = []
		var seq = 0

		for turn in 0..<5 {
			let d = Date(timeIntervalSince1970: TimeInterval(turn * 100))
			items.append(AgentChatItem(timestamp: d, kind: .user, text: "user \(turn)", sequenceIndex: seq))
			seq += 1
			let text = turn == 0 ? oversizedText : "short \(turn)"
			items.append(AgentChatItem(timestamp: d.addingTimeInterval(1), kind: .assistant, text: text, sequenceIndex: seq))
			seq += 1
		}

		let transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)
		let persisted = AgentTranscriptIO.persistedTranscript(transcript)

		// Turn 0 is old and oversized. Compaction may demote it to condensed/summary
		// (stripping activities), or truncation may reduce its text. Either outcome
		// means the persisted form is smaller than the original.
		let turn0 = persisted.turns[0]
		if turn0.retentionTier == .full {
			// Still full — truncation should have reduced the assistant text.
			let persistedAssistant = try XCTUnwrap(
				turn0.allActivities.first(where: { $0.itemKind == .assistant })
			)
			XCTAssertTrue(
				persistedAssistant.text.contains("[content truncated]"),
				"Persisted old oversized full turn should be truncated"
			)
			XCTAssertTrue(persistedAssistant.text.utf8.count < oversizedText.utf8.count)
		} else {
			// Compaction demoted it — activities stripped, summary present instead.
			XCTAssertFalse(turn0.hasStoredActivities, "Compacted turn should have no activities")
			XCTAssertNotNil(turn0.summary, "Compacted turn should have a summary")
		}
	}

	func testHandoffExportSliceTruncatesRelativeToSlice() {
		let oversizedText = String(repeating: "v", count: 60_000)
		var items: [AgentChatItem] = []
		var seq = 0

		// 6 turns, turn 0 is oversized
		for turn in 0..<6 {
			let d = Date(timeIntervalSince1970: TimeInterval(turn * 100))
			items.append(AgentChatItem(timestamp: d, kind: .user, text: "user \(turn)", sequenceIndex: seq))
			seq += 1
			let text = turn == 0 ? oversizedText : "reply \(turn)"
			items.append(AgentChatItem(timestamp: d.addingTimeInterval(1), kind: .assistant, text: text, sequenceIndex: seq))
			seq += 1
		}

		let transcript = AgentTranscriptIO.buildTranscript(from: items, compact: false)

		// Export only the first 4 turns (upToRowID = last activity of turn 3).
		// In a 4-turn slice with exemptionCount=3, only turn 0 is eligible for truncation.
		let turn3Activities = transcript.turns[3].allActivities
		let lastTurn3ActivityID = turn3Activities.last!.id

		let handoffItems = AgentTranscriptIO.buildHandoffTranscriptItems(
			from: transcript,
			upToRowID: lastTurn3ActivityID
		)
		// The handoff should contain items and the oversized turn 0 text should be truncated.
		XCTAssertFalse(handoffItems.isEmpty, "Handoff should produce items")

		let forkXML = AgentTranscriptIO.buildForkTranscriptXML(
			from: transcript,
			upToRowID: lastTurn3ActivityID
		)
		XCTAssertTrue(forkXML.contains("<transcript>"), "Fork XML should have transcript wrapper")
	}

	func testPersistedPolicyPipelineIsIdempotent() throws {
		let rawPatchResult = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}"#
		var items = makeToolHeavyTurnItems(toolNames: ["apply_patch"] + Array(repeating: "read_file", count: 9))
		let applyPatchResultIndex = try XCTUnwrap(items.firstIndex(where: { $0.kind == .toolResult && $0.toolName == "apply_patch" }))
		items[applyPatchResultIndex].toolResultJSON = rawPatchResult
		items[applyPatchResultIndex].text = rawPatchResult
		let transcript = AgentTranscriptIO.importLegacyItems(items)

		let once = AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript).transcript
		let twice = AgentTranscriptPolicyPipeline.persistedTranscript(from: once).transcript

		XCTAssertEqual(once, twice)
	}

	func testPersistedNormalizedPolicyMatchesPersistedTranscriptMaterialization() throws {
		let rawPatchResult = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}"#
		var items = makeToolHeavyTurnItems(toolNames: ["apply_patch"] + Array(repeating: "read_file", count: 9))
		let applyPatchResultIndex = try XCTUnwrap(items.firstIndex(where: { $0.kind == .toolResult && $0.toolName == "apply_patch" }))
		items[applyPatchResultIndex].toolResultJSON = rawPatchResult
		items[applyPatchResultIndex].text = rawPatchResult
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let normalized = AgentTranscriptIO.runtimeNormalizedTranscript(transcript)

		let exact = AgentTranscriptPolicyPipeline.persistedNormalizedTranscript(normalized)
		let persisted = AgentTranscriptIO.persistedTranscript(normalized)

		XCTAssertEqual(exact.transcript, persisted)
		XCTAssertEqual(
			exact.retainedFullDetailBytes,
			AgentTranscriptCompactor.retainedFullDetailBytes(for: persisted)
		)
	}

	func testLiveFixturePipelineDiagnostic() throws {
		let transcript = try loadLiveSessionFixtureTranscript()
		var out = ""
		func log(_ s: String) { out += s + "\n" }

		// --- Raw fixture stats ---
		let rawTurnCount = transcript.turns.count
		var rawTotalBytes = 0
		for turn in transcript.turns {
			for activity in turn.allActivities {
				rawTotalBytes += activity.text.utf8.count
				rawTotalBytes += (activity.reasoning ?? "").utf8.count
			}
			if let summary = turn.summary {
				rawTotalBytes += (summary.middleSummaryText ?? "").utf8.count
				rawTotalBytes += (summary.conclusionText ?? "").utf8.count
				rawTotalBytes += (summary.compactConclusionText ?? "").utf8.count
			}
		}

		// --- Persisted pipeline ---
		let persisted = AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript)
		let persistedFullTurns = persisted.transcript.turns.filter { $0.retentionTier == .full }.count
		let persistedCondensed = persisted.transcript.turns.filter { $0.retentionTier == .condensed }.count
		let persistedSummary = persisted.transcript.turns.filter { $0.retentionTier == .summary }.count
		let persistedArchived = persisted.transcript.turns.filter { $0.retentionTier == .archived }.count

		// --- Runtime pipeline ---
		let runtime = AgentTranscriptPolicyPipeline.runtimeTranscript(transcript)

		// --- Handoff full export ---
		let forkXML = AgentTranscriptIO.buildForkTranscriptXML(from: transcript)
		let lastActivityID = transcript.turns.last?.allActivities.last?.id
		let handoffItems: [AgentChatItem] = lastActivityID.map {
			AgentTranscriptIO.buildHandoffTranscriptItems(from: transcript, upToRowID: $0)
		} ?? []

		// --- Handoff partial export (first 3 turns) ---
		let partialCutoffID: UUID? = transcript.turns.count >= 3
			? transcript.turns[2].allActivities.last?.id
			: nil
		let partialForkXML: String? = partialCutoffID.map {
			AgentTranscriptIO.buildForkTranscriptXML(from: transcript, upToRowID: $0)
		}

		// --- Build diagnostic ---
		log("--- RAW FIXTURE ---")
		log("Turns: \(rawTurnCount), Total text bytes: \(rawTotalBytes)")
		for (i, turn) in transcript.turns.enumerated() {
			let activities = turn.allActivities
			let textBytes = activities.reduce(0) { $0 + $1.text.utf8.count }
			let reqText = String((turn.request?.text ?? "").prefix(80))
			log("  Turn \(i): tier=\(turn.retentionTier) activities=\(activities.count) textBytes=\(textBytes) req=\"\(reqText)\"")
		}

		log("\n--- PERSISTED ---")
		log("Turns: \(persisted.transcript.turns.count) (full=\(persistedFullTurns) condensed=\(persistedCondensed) summary=\(persistedSummary) archived=\(persistedArchived))")
		log("Retained detail bytes: \(persisted.retainedFullDetailBytes)")
		log("Sanitized activities: \(persisted.sanitizedActivityCount)")
		log("Visible tool result rows preserved: \(persisted.visibleToolResultRowIDs.count)")

		log("\n--- RUNTIME ---")
		log("Retained detail bytes: \(runtime.retainedFullDetailBytes)")
		log("Sanitized activities: \(runtime.sanitizedActivityCount)")
		log("Visible tool result rows preserved: \(runtime.visibleToolResultRowIDs.count)")

		log("\n--- HANDOFF FULL (fork XML) ---")
		log("Fork XML length: \(forkXML.utf8.count) bytes, Handoff items: \(handoffItems.count)")
		log(forkXML)

		if let partialForkXML {
			log("\n--- HANDOFF PARTIAL (first 3 turns) ---")
			log("Partial fork XML length: \(partialForkXML.utf8.count) bytes")
			log(partialForkXML)
		}

		log("\n--- HANDOFF ITEMS DETAIL ---")
		for (i, item) in handoffItems.enumerated() {
			let textPreview = String(item.text.prefix(200)).replacingOccurrences(of: "\n", with: "\\n")
			log("  [\(i)] kind=\(item.kind.rawValue) tool=\(item.toolName ?? "-") text=\"\(textPreview)\"")
		}

		// Write to temp file
		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("truncation-diagnostic.txt")
		try out.write(toFile: outputURL.path, atomically: true, encoding: .utf8)

		// Basic sanity assertions
		XCTAssertGreaterThan(rawTurnCount, 0)
		XCTAssertTrue(forkXML.contains("<transcript>"))
		XCTAssertTrue(forkXML.contains("</transcript>"))

	}

	func testMultiFixtureHandoffDiagnostic() throws {
		let fixtures = [
			"long-session-78turns-414068FC.json",
			"mixed-tiers-37turns-921E33DA.json",
			"archived-43turns-76D2C176.json"
		]
		var out = ""
		func log(_ s: String) { out += s + "\n" }

		for fixtureName in fixtures {
			let transcript: AgentTranscript
			do {
				transcript = try loadFixtureTranscript(named: fixtureName)
			} catch {
				log("=== SKIP \(fixtureName): \(error) ===\n")
				continue
			}

			log("=== \(fixtureName) ===")
			log("Turns: \(transcript.turns.count)")
			var tierCounts: [String: Int] = [:]
			for turn in transcript.turns {
				tierCounts["\(turn.retentionTier)", default: 0] += 1
			}
			log("Tiers: \(tierCounts)")

			// Persisted pipeline
			let persisted = AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript)
			log("Persisted: retained=\(persisted.retainedFullDetailBytes)B sanitized=\(persisted.sanitizedActivityCount) visibleToolRows=\(persisted.visibleToolResultRowIDs.count)")

			// Handoff full export
			let forkXML = AgentTranscriptIO.buildForkTranscriptXML(from: transcript)
			let lastActivityID = transcript.turns.last?.allActivities.last?.id
			let handoffItems: [AgentChatItem] = lastActivityID.map {
				AgentTranscriptIO.buildHandoffTranscriptItems(from: transcript, upToRowID: $0)
			} ?? []
			let toolCallItems = handoffItems.filter { $0.kind == .toolCall }
			let systemItems = handoffItems.filter { $0.kind == .system }
			let assistantItems = handoffItems.filter { $0.kind == .assistant || $0.kind == .assistantInline }
			let userItems = handoffItems.filter { $0.kind == .user }
			let xmlToolCallCount = forkXML.components(separatedBy: "<tool_call name=").count - 1
			log("Handoff: xmlBytes=\(forkXML.utf8.count) items=\(handoffItems.count)")
			log("  users=\(userItems.count) assistants=\(assistantItems.count) systems=\(systemItems.count) toolCalls=\(toolCallItems.count) xmlToolCalls=\(xmlToolCallCount)")

			// Show the full fork XML
			log("\n--- FORK XML ---")
			log(forkXML)

			// Show handoff items detail
			log("\n--- ITEMS ---")
			for (i, item) in handoffItems.enumerated() {
				let textPreview = String(item.text.prefix(200)).replacingOccurrences(of: "\n", with: "\\n")
				log("  [\(i)] \(item.kind.rawValue): \"\(textPreview)\"")
			}

			// Block analysis — what kinds exist and do they have tool call rows?
			let materialized = AgentTranscriptPolicyPipeline.handoffTranscript(from: transcript, upToRowID: nil)
			let allBlocks = materialized.projection.archivedBlocks + materialized.projection.workingBlocks
			var blockKindCounts: [String: Int] = [:]
			var blockToolCallRowCounts: [String: Int] = [:]
			for blk in allBlocks {
				let kind = blk.kind.rawValue
				blockKindCounts[kind, default: 0] += 1
				let tcRows = blk.rows.filter { $0.kind == .toolCall }
				if !tcRows.isEmpty {
					blockToolCallRowCounts[kind, default: 0] += tcRows.count
				}
			}
			log("Blocks: \(blockKindCounts)")
			log("BlocksWithToolCallRows: \(blockToolCallRowCounts)")
			// Check tail blocks
			let tailBlocks = allBlocks.suffix(10)
			for (i, blk) in tailBlocks.enumerated() {
				let rowKinds = blk.rows.map { $0.kind.rawValue }
				log("  tail[\(i)] kind=\(blk.kind.rawValue) rows=\(blk.rows.count) rowKinds=\(rowKinds) grouped=\(blk.groupedHistory != nil)")
			}

			// Sanity checks
			XCTAssertTrue(forkXML.contains("<transcript>"), "\(fixtureName): missing <transcript>")
			XCTAssertTrue(forkXML.contains("</transcript>"), "\(fixtureName): missing </transcript>")

			log("")
		}

		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("multi-fixture-diagnostic.txt")
		try out.write(toFile: outputURL.path, atomically: true, encoding: .utf8)
	}

	#if DEBUG
	private struct CrawlRefreshScenarioConfig {
		let scenarioName: String = "long_active_final_turn_replace_tail_40x24KiB_raw_tools"
		let toolResultPairCount: Int = 40
		let minimumPayloadBytes: Int = 24 * 1024
		let measuredSampleCount: Int = 9
		let warmupSampleCount: Int = 1
	}

	private struct CrawlRefreshSeed {
		let items: [AgentChatItem]
		let representativeToolResultID: UUID
		let representativeMarker: String
	}

	private struct CrawlRefreshBenchmarkSample {
		let ordinal: Int
		let phase: String
		let appendWallClockMS: Double
		let refreshMS: Double
		let importMS: Double?
		let incrementalImportMS: Double?
		let sanitizeMS: Double?
		let projectionMS: Double?
		let payloadCaptureMS: Double?
		let sanitizedActivityCount: Int?
		let sourceItemsRevision: Int
		let itemCount: Int
		let transcriptTurnCount: Int
		let rawToolResultBytesInItems: Int
		let ephemeralPayloadBytes: Int
		let retainedPayloadEntryCount: Int
		let retainedPayloadBytesFromSnapshot: Int
		let toolProcessingMetrics: AgentToolResultProcessingMetrics
		let incrementalImportAttempts: Int
		let incrementalImportSuccesses: Int
		let incrementalImportFallbacks: Int
		let refreshAttemptCount: Int
		let rebuildCount: Int
		let projectionBuildCount: Int
		let sessionItemReplacementCount: Int
		let compactionCount: Int
		let presentationPublishCount: Int
	}

	private struct CrawlRefreshBenchmarkAggregate {
		let scenario: String
		let config: CrawlRefreshScenarioConfig
		let warmup: CrawlRefreshBenchmarkSample
		let measured: [CrawlRefreshBenchmarkSample]
		let trimmedRefreshMS: [Double]
		let trimmedMedianRefreshMS: Double
		let trimmedP95RefreshMS: Double
		let trimmedAppendMedianMS: Double
		let trimmedAppendP95MS: Double
	}

	private struct LiveMetricsSession {
		let vm: AgentModeViewModel
		let session: AgentModeViewModel.TabSession
		let metrics: TranscriptInstrumentationSlice
	}

	private struct TranscriptPerformanceDelta {
		let projectionBuildCount: Int
		let projectionPublishCount: Int
		let refreshRequestCount: Int
		let refreshImmediateCount: Int
		let incrementalImportAttemptCount: Int
		let incrementalImportSuccessCount: Int
		let incrementalImportFallbackCount: Int
		let frontierReuseAttemptCount: Int
		let frontierReuseSuccessCount: Int
		let frontierReuseFallbackCount: Int
		let sanitizeReuseAttemptCount: Int
		let sanitizeReuseSuccessCount: Int
		let sanitizeReuseFallbackCount: Int
		let projectionReuseAttemptCount: Int
		let projectionReuseSuccessCount: Int
		let projectionReuseFallbackCount: Int
	}

	private struct LiveOperationMetrics {
		let toolExecutionCount: Int
		let appendedItemCount: Int
		let sourceRevisionDelta: Int
		let extraSourceItemReplacementCount: Int
		let itemCountBefore: Int
		let itemCountAfter: Int
		let fullDetailEnvelopeChanged: Bool
		let activePresentationRevisionDelta: Int
		let visibleRowDelta: Int
		let visibleBlockDelta: Int
		let cacheCountBefore: Int
		let cacheCountAfter: Int
		let originalFinalTurnTier: AgentTranscriptRetentionTier?
		let appendedTurnTier: AgentTranscriptRetentionTier?
		let appendedToolCallCount: Int
		let finalTierVector: String
		let performanceDelta: TranscriptPerformanceDelta
		let finalPerformance: AgentTranscriptPerformanceSnapshot
		let metrics: TranscriptInstrumentationSlice
	}

	@MainActor
	private func makeLiveMetricsSession(
		fixtureName: String,
		persistedSession: AgentSession,
		fixture: AgentTranscript,
		recorder: TranscriptInstrumentationRecorder
	) async throws -> LiveMetricsSession {
		let vm = makeLiveMetricsViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		vm.test_setCurrentTabIDOverride(tabID)
		let workingItems = AgentTranscriptIO.workingSourceItems(from: fixture)
		let mark = recorder.mark()
		session.selectedAgent = persistedSession.agentKind.flatMap(DiscoverAgentKind.init(rawValue:)) ?? .codexExec
		session.selectedModelRaw = persistedSession.agentModel ?? AgentModel.defaultModel.rawValue
		session.setItemsSilently(workingItems, reason: .testOverride)
		vm.applyTranscriptPresentation(
			fixture,
			sourceItems: workingItems,
			to: session,
			isColdLoad: true
		)
		vm.test_applySessionToBindings(tabID: tabID)
		XCTAssertEqual(session.items, workingItems, "\(fixtureName) baseline hydration should keep canonical working suffix")
		return LiveMetricsSession(
			vm: vm,
			session: session,
			metrics: recorder.slice(since: mark)
		)
	}

	@MainActor
	private func runLiveViewModelAppendScenario(
		vm: AgentModeViewModel,
		session: AgentModeViewModel.TabSession,
		fixtureName: String,
		baselineTranscript: AgentTranscript,
		toolExecutionCount: Int,
		label: String,
		recorder: TranscriptInstrumentationRecorder
	) throws -> LiveOperationMetrics {
		let beforeTranscript = session.transcript
		let beforeSourceRevision = session.sourceItemsRevision
		let beforeItemCount = session.items.count
		let beforePresentationRevision = vm.test_activeTranscriptPresentationRevisionValue()
		let beforeVisibleRowCount = vm.activeTranscriptPresentation.visibleRows.count
		let beforeVisibleBlockCount = vm.activeTranscriptPresentation.visibleBlocks.count
		let beforeCacheCount = session.turnProjectionCaches.count
		let beforePerformance = session.transcriptPerformanceSnapshot
		let originalFinalSequences = try sequenceIndexSet(for: XCTUnwrap(baselineTranscript.turns.last, "\(fixtureName) should have an original final turn"))
		let mark = recorder.mark()
		let appendedItems = syntheticVisibleToolTurnItems(
			startingSequenceIndex: session.nextSequenceIndex,
			toolExecutionCount: toolExecutionCount,
			label: label
		)

		session.runState = .running
		for item in appendedItems {
			session.appendItem(item)
		}
		session.runState = .completed
		vm.test_rebuildStructuredTranscript(tabID: session.tabID)

		let metrics = recorder.slice(since: mark)
		let sourceRevisionDelta = session.sourceItemsRevision - beforeSourceRevision
		let extraSourceItemReplacementCount = max(0, sourceRevisionDelta - appendedItems.count)
		let originalFinalTurn = session.transcript.turns.first { turn in
			!sequenceIndexSet(for: turn).isDisjoint(with: originalFinalSequences)
		}
		let appendedTurn = try XCTUnwrap(session.transcript.turns.last, "\(fixtureName) should have an appended final turn")
		let appendedToolCallCount = appendedTurn.allActivities.filter { $0.itemKind == .toolCall }.count
		let nonFullTierByID = Dictionary(
			uniqueKeysWithValues: baselineTranscript.turns.compactMap { turn -> (UUID, AgentTranscriptRetentionTier)? in
				guard turn.retentionTier != .full else { return nil }
				return (turn.id, turn.retentionTier)
			}
		)
		for (turnID, tier) in nonFullTierByID {
			let rebuiltTurn = try XCTUnwrap(session.transcript.turns.first(where: { $0.id == turnID }))
			XCTAssertEqual(rebuiltTurn.retentionTier, tier, "\(fixtureName) should not worsen legacy prefix")
		}
		XCTAssertEqual(originalFinalTurn?.retentionTier, .full, "\(fixtureName) should keep original tail turn protected")
		XCTAssertEqual(appendedTurn.retentionTier, .full, "\(fixtureName) should keep appended turn protected")
		XCTAssertEqual(appendedToolCallCount, toolExecutionCount, "\(fixtureName) appended tool count")

		return LiveOperationMetrics(
			toolExecutionCount: toolExecutionCount,
			appendedItemCount: appendedItems.count,
			sourceRevisionDelta: sourceRevisionDelta,
			extraSourceItemReplacementCount: extraSourceItemReplacementCount,
			itemCountBefore: beforeItemCount,
			itemCountAfter: session.items.count,
			fullDetailEnvelopeChanged: AgentTranscriptIO.fullDetailTurnEnvelopeChanged(from: beforeTranscript, to: session.transcript),
			activePresentationRevisionDelta: vm.test_activeTranscriptPresentationRevisionValue() - beforePresentationRevision,
			visibleRowDelta: vm.activeTranscriptPresentation.visibleRows.count - beforeVisibleRowCount,
			visibleBlockDelta: vm.activeTranscriptPresentation.visibleBlocks.count - beforeVisibleBlockCount,
			cacheCountBefore: beforeCacheCount,
			cacheCountAfter: session.turnProjectionCaches.count,
			originalFinalTurnTier: originalFinalTurn?.retentionTier,
			appendedTurnTier: appendedTurn.retentionTier,
			appendedToolCallCount: appendedToolCallCount,
			finalTierVector: tierVector(session.transcript),
			performanceDelta: performanceDelta(from: beforePerformance, to: session.transcriptPerformanceSnapshot),
			finalPerformance: session.transcriptPerformanceSnapshot,
			metrics: metrics
		)
	}

	private func syntheticVisibleToolTurnItems(
		startingSequenceIndex: Int,
		toolExecutionCount: Int,
		label: String
	) -> [AgentChatItem] {
		let toolCycle = ["read_file", "search", "bash"]
		return makeContextRichToolTurnItems(
			toolNames: (0..<toolExecutionCount).map { toolCycle[$0 % toolCycle.count] },
			startingSequenceIndex: startingSequenceIndex,
			userText: "Synthetic production append \(label)",
			finalSummaryText: "PRODUCTION_APPEND_DONE_\(label)_\(toolExecutionCount)"
		)
	}

	@MainActor
	private func runCrawlRefreshBenchmark(
		config: CrawlRefreshScenarioConfig,
		recorder: TranscriptInstrumentationRecorder
	) async throws -> CrawlRefreshBenchmarkAggregate {
		let vm = makeLiveMetricsViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		vm.test_setCurrentTabIDOverride(tabID)
		let seed = try makeLongActiveCrawlFinalTurnItems(config: config)
		defer {
			session.saveDebounceTask?.cancel()
			session.saveDebounceTask = nil
			session.derivedTranscriptRefreshTask?.cancel()
			session.derivedTranscriptRefreshTask = nil
		}

		session.selectedAgent = .codexExec
		session.selectedModelRaw = AgentModel.defaultModel.rawValue
		session.runState = .running
		session.setItemsSilently(seed.items, reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)
		await drainCrawlRefreshIfNeeded(session: session)

		XCTAssertEqual(session.runState, .running)
		XCTAssertEqual(session.items.count, seed.items.count)
		XCTAssertFalse(session.transcriptProjection.workingRows.isEmpty)
		let initialRawPayload = try XCTUnwrap(vm.rawToolResultPayloadForRendering(tabID: tabID, itemID: seed.representativeToolResultID))
		XCTAssertTrue(initialRawPayload.contains(seed.representativeMarker))

		var warmups: [CrawlRefreshBenchmarkSample] = []
		for ordinal in 1...config.warmupSampleCount {
			warmups.append(try await runCrawlRefreshBenchmarkSample(
				vm: vm,
				session: session,
				seed: seed,
				expectedItemCount: seed.items.count,
				ordinal: ordinal,
				phase: "warmup",
				recorder: recorder
			))
		}

		var measured: [CrawlRefreshBenchmarkSample] = []
		for ordinal in 1...config.measuredSampleCount {
			measured.append(try await runCrawlRefreshBenchmarkSample(
				vm: vm,
				session: session,
				seed: seed,
				expectedItemCount: seed.items.count,
				ordinal: ordinal,
				phase: "measured",
				recorder: recorder
			))
		}

		let trimmedSamples = trimmedRefreshSamples(measured)
		let trimmedRefreshMS = trimmedSamples.map(\.refreshMS)
		let trimmedAppendMS = trimmedSamples.map(\.appendWallClockMS)
		return CrawlRefreshBenchmarkAggregate(
			scenario: config.scenarioName,
			config: config,
			warmup: try XCTUnwrap(warmups.first),
			measured: measured,
			trimmedRefreshMS: trimmedRefreshMS,
			trimmedMedianRefreshMS: median(trimmedRefreshMS),
			trimmedP95RefreshMS: nearestRankP95(trimmedRefreshMS),
			trimmedAppendMedianMS: median(trimmedAppendMS),
			trimmedAppendP95MS: nearestRankP95(trimmedAppendMS)
		)
	}

	@MainActor
	private func runCrawlRefreshBenchmarkSample(
		vm: AgentModeViewModel,
		session: AgentModeViewModel.TabSession,
		seed: CrawlRefreshSeed,
		expectedItemCount: Int,
		ordinal: Int,
		phase: String,
		recorder: TranscriptInstrumentationRecorder
	) async throws -> CrawlRefreshBenchmarkSample {
		let trailingIndex = expectedItemCount - 1
		XCTAssertTrue(session.items.indices.contains(trailingIndex))
		let previousAssistant = session.items[trailingIndex]
		let replacementText = "CRAWL_REFRESH_REPLACEMENT_\(phase)_\(ordinal)"
		let replacement = AgentChatItem(
			id: previousAssistant.id,
			timestamp: previousAssistant.timestamp,
			kind: .assistant,
			text: replacementText,
			sequenceIndex: previousAssistant.sequenceIndex
		)
		let beforePerformance = session.transcriptPerformanceSnapshot
		let mark = recorder.mark()
		let start = DispatchTime.now().uptimeNanoseconds
		session.replaceItem(at: trailingIndex, with: replacement)
		await drainCrawlRefreshIfNeeded(session: session)
		let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
		let metrics = recorder.slice(since: mark)
		let snapshot = session.transcriptPerformanceSnapshot
		let refreshMS = try XCTUnwrap(snapshot.lastRefreshTotalDurationMS)

		XCTAssertEqual(session.runState, .running)
		XCTAssertEqual(session.items.count, expectedItemCount)
		XCTAssertTrue(session.transcriptProjection.workingRows.contains { $0.id == replacement.id && $0.text.contains(replacementText) })
		XCTAssertNotNil(snapshot.lastRefreshTotalDurationMS)
		let rawPayload = try XCTUnwrap(vm.rawToolResultPayloadForRendering(tabID: session.tabID, itemID: seed.representativeToolResultID))
		XCTAssertTrue(rawPayload.contains(seed.representativeMarker))
		XCTAssertNil(session.derivedTranscriptRefreshTask)
		XCTAssertFalse(session.transcriptProjection.workingRows.isEmpty)

		let delta = performanceDelta(from: beforePerformance, to: snapshot)
		return CrawlRefreshBenchmarkSample(
			ordinal: ordinal,
			phase: phase,
			appendWallClockMS: elapsedMS,
			refreshMS: refreshMS,
			importMS: snapshot.lastImportDurationMS,
			incrementalImportMS: snapshot.lastIncrementalImportDurationMS,
			sanitizeMS: snapshot.lastSanitizeDurationMS,
			projectionMS: snapshot.lastProjectionBuildDurationMS,
			payloadCaptureMS: snapshot.lastPayloadCaptureDurationMS,
			sanitizedActivityCount: snapshot.lastSanitizedActivityCount,
			sourceItemsRevision: session.sourceItemsRevision,
			itemCount: session.items.count,
			transcriptTurnCount: session.transcript.turns.count,
			rawToolResultBytesInItems: rawToolResultBytes(in: session.items),
			ephemeralPayloadBytes: ephemeralPayloadBytes(in: session),
			retainedPayloadEntryCount: snapshot.retainedRawPayloadEntryCount,
			retainedPayloadBytesFromSnapshot: snapshot.retainedRawPayloadTotalBytes,
			toolProcessingMetrics: snapshot.lastToolProcessingMetrics,
			incrementalImportAttempts: delta.incrementalImportAttemptCount,
			incrementalImportSuccesses: delta.incrementalImportSuccessCount,
			incrementalImportFallbacks: delta.incrementalImportFallbackCount,
			refreshAttemptCount: metrics.refreshAttempts.count,
			rebuildCount: metrics.rebuilds.count,
			projectionBuildCount: metrics.projectionBuilds.count,
			sessionItemReplacementCount: metrics.sessionItemsReplacements.count,
			compactionCount: metrics.compactions.count,
			presentationPublishCount: metrics.presentationPublishes.count
		)
	}

	@MainActor
	private func drainCrawlRefreshIfNeeded(session: AgentModeViewModel.TabSession) async {
		for _ in 0..<4 {
			guard let task = session.derivedTranscriptRefreshTask else { return }
			let generation = session.derivedTranscriptRefreshGeneration
			await task.value
			await Task.yield()
			if session.derivedTranscriptRefreshTask != nil,
				session.derivedTranscriptRefreshGeneration == generation {
				session.derivedTranscriptRefreshTask = nil
			}
		}
	}

	private func makeLongActiveCrawlFinalTurnItems(config: CrawlRefreshScenarioConfig) throws -> CrawlRefreshSeed {
		var sequenceIndex = 0
		var items: [AgentChatItem] = [AgentChatItem.user("Run a long active crawl and keep refreshing the transcript.", sequenceIndex: sequenceIndex)]
		sequenceIndex += 1
		let toolCycle = ["apply_patch", "apply_edits", "bash"]
		var representativeID: UUID?
		var representativeMarker: String?
		for ordinal in 0..<config.toolResultPairCount {
			let toolName = toolCycle[ordinal % toolCycle.count]
			let marker = "CRAWL_REFRESH_RAW_PAYLOAD_MARKER_\(ordinal)"
			let invocationID = UUID()
			items.append(AgentChatItem.toolCall(
				name: toolName,
				invocationID: invocationID,
				argsJSON: crawlRefreshToolArgsJSON(toolName: toolName, ordinal: ordinal),
				sequenceIndex: sequenceIndex
			))
			sequenceIndex += 1
			let payload = try crawlRefreshToolResultJSON(
				toolName: toolName,
				ordinal: ordinal,
				marker: marker,
				minimumPayloadBytes: config.minimumPayloadBytes
			)
			let result = AgentChatItem.toolResult(
				name: toolName,
				invocationID: invocationID,
				resultJSON: payload,
				isError: false,
				sequenceIndex: sequenceIndex
			)
			if representativeID == nil {
				representativeID = result.id
				representativeMarker = marker
			}
			items.append(result)
			sequenceIndex += 1
		}
		items.append(AgentChatItem.assistant("CRAWL_REFRESH_INITIAL_TAIL", sequenceIndex: sequenceIndex))
		return CrawlRefreshSeed(
			items: items,
			representativeToolResultID: try XCTUnwrap(representativeID),
			representativeMarker: try XCTUnwrap(representativeMarker)
		)
	}

	private func crawlRefreshToolArgsJSON(toolName: String, ordinal: Int) -> String {
		switch toolName {
		case "apply_patch":
			return #"{"patch":"*** Begin Patch\n*** Update File: Crawl.swift\n@@\n- old\n+ new\n*** End Patch"}"#
		case "apply_edits":
			return #"{"path":"Crawl.swift","edits":[{"search":"old","replace":"new"}]}"#
		case "bash":
			return #"{"cmd":"printf crawl-refresh"}"#
		default:
			return #"{"ordinal":\#(ordinal)}"#
		}
	}

	private func crawlRefreshToolResultJSON(
		toolName: String,
		ordinal: Int,
		marker: String,
		minimumPayloadBytes: Int
	) throws -> String {
		let diff = "@@ -1,3 +1,3 @@\n- old crawl line \(ordinal)\n+ new crawl line \(ordinal) \(marker)\n"
		var payload: [String: Any]
		switch toolName {
		case "apply_patch":
			payload = [
				"status": "success",
				"marker": marker,
				"changes": [["path": "Sources/Crawl\(ordinal).swift", "diff": diff, "summary": "patched \(ordinal)"]]
			]
		case "apply_edits":
			payload = [
				"status": "success",
				"marker": marker,
				"path": "Sources/Crawl\(ordinal).swift",
				"card_unified_diff": diff,
				"edits": [["path": "Sources/Crawl\(ordinal).swift", "card_unified_diff": diff]]
			]
		case "bash":
			payload = [
				"status": "success",
				"marker": marker,
				"stdout": "crawl bash output \(marker)\n",
				"stderr": "",
				"metadata": ["exit_code": 0, "duration_ms": 12, "command": "printf crawl-refresh"]
			]
		default:
			payload = ["status": "success", "marker": marker]
		}
		var paddingBytes = minimumPayloadBytes
		while true {
			payload["padding"] = String(repeating: "\(marker)-payload-line-\(ordinal)\n", count: max(1, paddingBytes / 48))
			let json = try jsonString(payload)
			if json.utf8.count >= minimumPayloadBytes {
				return json
			}
			paddingBytes += minimumPayloadBytes / 2
		}
	}

	private func jsonString(_ payload: [String: Any]) throws -> String {
		let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
		return String(data: data, encoding: .utf8) ?? "{}"
	}

	private func rawToolResultBytes(in items: [AgentChatItem]) -> Int {
		items.reduce(0) { partial, item in
			guard item.kind == .toolResult else { return partial }
			return partial + (item.toolResultJSON?.utf8.count ?? 0)
		}
	}

	@MainActor
	private func ephemeralPayloadBytes(in session: AgentModeViewModel.TabSession) -> Int {
		session.ephemeralToolResultPayloadByItemID.values.reduce(0) { $0 + $1.utf8.count }
	}

	private func trimmedRefreshSamples(_ samples: [CrawlRefreshBenchmarkSample]) -> [CrawlRefreshBenchmarkSample] {
		let sorted = samples.sorted { $0.refreshMS < $1.refreshMS }
		guard sorted.count > 2 else { return sorted }
		return Array(sorted.dropFirst().dropLast())
	}

	private func median(_ values: [Double]) -> Double {
		let sorted = values.sorted()
		guard !sorted.isEmpty else { return 0 }
		let midpoint = sorted.count / 2
		if sorted.count.isMultiple(of: 2) {
			return (sorted[midpoint - 1] + sorted[midpoint]) / 2
		}
		return sorted[midpoint]
	}

	private func nearestRankP95(_ values: [Double]) -> Double {
		let sorted = values.sorted()
		guard !sorted.isEmpty else { return 0 }
		let rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
		return sorted[min(sorted.count - 1, rank - 1)]
	}

	@MainActor
	private func makeLiveMetricsViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			TranscriptMetricsFakeCodexController()
		}
	}

	private struct TranscriptInstrumentationMark {
		let protectedTailScanCount: Int
		let compactionCount: Int
		let workingSourceItemsCount: Int
		let rebuildCount: Int
		let projectionBuildCount: Int
		let refreshAttemptCount: Int
		let presentationPublishCount: Int
		let sessionItemsReplacementCount: Int
		let projectionIdentityCount: Int
	}

	private struct TranscriptInstrumentationSlice {
		let protectedTailScans: [AgentTranscriptProtectedTailScanMetrics]
		let compactions: [AgentTranscriptCompactionMetrics]
		let workingSourceItems: [AgentTranscriptWorkingSourceItemsMetrics]
		let rebuilds: [AgentTranscriptRebuildMetrics]
		let projectionBuilds: [AgentTranscriptProjectionBuildMetrics]
		let refreshAttempts: [AgentTranscriptRefreshAttemptMetrics]
		let presentationPublishes: [AgentTranscriptPresentationPublishMetrics]
		let sessionItemsReplacements: [AgentTranscriptSessionItemsReplacementMetrics]
		let projectionIdentities: [AgentTranscriptProjectionIdentityMetrics]
	}

	private final class TranscriptInstrumentationRecorder {
		private let lock = NSLock()
		private var protectedTailScans: [AgentTranscriptProtectedTailScanMetrics] = []
		private var compactions: [AgentTranscriptCompactionMetrics] = []
		private var workingSourceItems: [AgentTranscriptWorkingSourceItemsMetrics] = []
		private var rebuilds: [AgentTranscriptRebuildMetrics] = []
		private var projectionBuilds: [AgentTranscriptProjectionBuildMetrics] = []
		private var refreshAttempts: [AgentTranscriptRefreshAttemptMetrics] = []
		private var presentationPublishes: [AgentTranscriptPresentationPublishMetrics] = []
		private var sessionItemsReplacements: [AgentTranscriptSessionItemsReplacementMetrics] = []
		private var projectionIdentities: [AgentTranscriptProjectionIdentityMetrics] = []

		func record(_ metrics: AgentTranscriptProtectedTailScanMetrics) {
			lock.lock()
			protectedTailScans.append(metrics)
			lock.unlock()
		}

		func record(_ metrics: AgentTranscriptCompactionMetrics) {
			lock.lock()
			compactions.append(metrics)
			lock.unlock()
		}

		func record(_ metrics: AgentTranscriptWorkingSourceItemsMetrics) {
			lock.lock()
			workingSourceItems.append(metrics)
			lock.unlock()
		}

		func record(_ metrics: AgentTranscriptRebuildMetrics) {
			lock.lock()
			rebuilds.append(metrics)
			lock.unlock()
		}

		func record(_ metrics: AgentTranscriptProjectionBuildMetrics) {
			lock.lock()
			projectionBuilds.append(metrics)
			lock.unlock()
		}

		func record(_ metrics: AgentTranscriptRefreshAttemptMetrics) {
			lock.lock()
			refreshAttempts.append(metrics)
			lock.unlock()
		}

		func record(_ metrics: AgentTranscriptPresentationPublishMetrics) {
			lock.lock()
			presentationPublishes.append(metrics)
			lock.unlock()
		}

		func record(_ metrics: AgentTranscriptSessionItemsReplacementMetrics) {
			lock.lock()
			sessionItemsReplacements.append(metrics)
			lock.unlock()
		}

		func record(_ metrics: AgentTranscriptProjectionIdentityMetrics) {
			lock.lock()
			projectionIdentities.append(metrics)
			lock.unlock()
		}

		func mark() -> TranscriptInstrumentationMark {
			lock.lock()
			defer { lock.unlock() }
			return .init(
				protectedTailScanCount: protectedTailScans.count,
				compactionCount: compactions.count,
				workingSourceItemsCount: workingSourceItems.count,
				rebuildCount: rebuilds.count,
				projectionBuildCount: projectionBuilds.count,
				refreshAttemptCount: refreshAttempts.count,
				presentationPublishCount: presentationPublishes.count,
				sessionItemsReplacementCount: sessionItemsReplacements.count,
				projectionIdentityCount: projectionIdentities.count
			)
		}

		func slice(since mark: TranscriptInstrumentationMark) -> TranscriptInstrumentationSlice {
			lock.lock()
			defer { lock.unlock() }
			return .init(
				protectedTailScans: Array(protectedTailScans.dropFirst(mark.protectedTailScanCount)),
				compactions: Array(compactions.dropFirst(mark.compactionCount)),
				workingSourceItems: Array(workingSourceItems.dropFirst(mark.workingSourceItemsCount)),
				rebuilds: Array(rebuilds.dropFirst(mark.rebuildCount)),
				projectionBuilds: Array(projectionBuilds.dropFirst(mark.projectionBuildCount)),
				refreshAttempts: Array(refreshAttempts.dropFirst(mark.refreshAttemptCount)),
				presentationPublishes: Array(presentationPublishes.dropFirst(mark.presentationPublishCount)),
				sessionItemsReplacements: Array(sessionItemsReplacements.dropFirst(mark.sessionItemsReplacementCount)),
				projectionIdentities: Array(projectionIdentities.dropFirst(mark.projectionIdentityCount))
			)
		}
	}

	private func formatLiveOperationMetrics(
		_ operation: LiveOperationMetrics,
		scenario: String,
		fixtureName: String,
		ordinal: Int
	) -> String {
		let projectionBuilds = operation.metrics.projectionBuilds
		let projectionDurationMS = projectionBuilds.reduce(0) { $0 + $1.durationMS }
		let projectionCacheHits = projectionBuilds.reduce(0) { $0 + $1.cacheHitCount }
		let projectionCacheMissApprox = projectionBuilds.reduce(0) { partial, build in
			partial + max(0, build.turnCount - build.reusedPrefixTurnCount - build.cacheHitCount)
		}
		let maxProjectionMS = projectionBuilds.map(\.durationMS).max()
		let rebuild = operation.metrics.rebuilds.last
		let compactionProtectedTurns = operation.metrics.compactions.last?.protectedToolTailTurnCount ?? 0
		let scanProtectedTurns = operation.metrics.protectedTailScans.last?.protectedTurnCount ?? 0
		let duplicateRefreshes = operation.metrics.refreshAttempts.filter(\.isConsecutiveDuplicateInput).count
		let incrementalPaths = countedValues(operation.metrics.refreshAttempts.map(\.incrementalPath))
		let equalItemReplacements = operation.metrics.sessionItemsReplacements.filter(\.isEqual).count
		let semanticNoOpPublishes = operation.metrics.presentationPublishes.filter(\.semanticNoOpPublishOpportunity).count
		let publishAttempts = operation.metrics.presentationPublishes.count
		let rowDriftCount = operation.metrics.projectionIdentities.filter(\.rowIdentityDrift).count
		let blockDriftCount = operation.metrics.projectionIdentities.filter(\.blockIdentityDrift).count
		return [
			"\(scenario) fixture=\(fixtureName)",
			"ordinal=\(ordinal)",
			"tools=\(operation.toolExecutionCount)",
			"appendedItems=\(operation.appendedItemCount)",
			"sourceRevisions=\(operation.sourceRevisionDelta)",
			"extraItemReplacements=\(operation.extraSourceItemReplacementCount)",
			"items=\(operation.itemCountBefore)->\(operation.itemCountAfter)",
			"fullEnvelopeChanged=\(operation.fullDetailEnvelopeChanged)",
			"activeRevisionDelta=\(operation.activePresentationRevisionDelta)",
			"visibleRowDelta=\(operation.visibleRowDelta)",
			"visibleBlockDelta=\(operation.visibleBlockDelta)",
			"cacheCount=\(operation.cacheCountBefore)->\(operation.cacheCountAfter)",
			"projectionBuilds=\(projectionBuilds.count)",
			"projectionMS=\(formatMS(projectionDurationMS))",
			"maxProjectionMS=\(formatMS(maxProjectionMS))",
			"lastProjectionMS=\(formatMS(projectionBuilds.last?.durationMS))",
			"lastProjectionReusedPrefix=\(projectionBuilds.last?.reusedPrefixTurnCount.description ?? "nil")",
			"projectionCacheHits=\(projectionCacheHits)",
			"projectionCacheMissApprox=\(projectionCacheMissApprox)",
			"refreshAttempts=\(operation.metrics.refreshAttempts.count)",
			"duplicateRefreshes=\(duplicateRefreshes)",
			"incrementalPaths=\(incrementalPaths)",
			"itemReplacements=\(operation.metrics.sessionItemsReplacements.count)/equal=\(equalItemReplacements)",
			"publishAttempts=\(publishAttempts)/semanticNoOp=\(semanticNoOpPublishes)",
			"identityDrift=row:\(rowDriftCount)/block:\(blockDriftCount)",
			"perf=\(formatPerformanceDelta(operation.performanceDelta))",
			"lastPerf=\(formatPerformanceSnapshot(operation.finalPerformance))",
			"sanitizeReused=\(operation.finalPerformance.lastSanitizeReusedTurnCount?.description ?? "nil")",
			"frontier=\(rebuild?.reusableFrozenPrefixTurnCount?.description ?? "nil")",
			"mode=\(rebuild.map { String(describing: $0.requestedCompactionMode) } ?? "nil")",
			"worsen=\(rebuild?.tierWorseningCount.description ?? "nil")",
			"legacyWorsen=\(rebuild?.legacyNonFullTierWorseningCount.description ?? "nil")",
			"originalFinalTier=\(operation.originalFinalTurnTier?.rawValue ?? "nil")",
			"appendedTier=\(operation.appendedTurnTier?.rawValue ?? "nil")",
			"appendedToolCalls=\(operation.appendedToolCallCount)",
			"protectedTurns=scan:\(scanProtectedTurns)/compact:\(compactionProtectedTurns)",
			"tierVector=\(operation.finalTierVector)",
			"\(formatMetrics(operation.metrics))"
		].joined(separator: " ")
	}

	private func countedValues(_ values: [String]) -> String {
		guard !values.isEmpty else { return "none" }
		let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
		return counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
	}

	private func formatMetrics(_ metrics: TranscriptInstrumentationSlice) -> String {
		let scans = metrics.protectedTailScans
		let compactions = metrics.compactions
		let rebuild = metrics.rebuilds.last
		let workingSource = metrics.workingSourceItems.last
		let projection = metrics.projectionBuilds.last
		let scanActivities = scans.reduce(0) { $0 + $1.activitiesInspected }
		let scanTurns = scans.reduce(0) { $0 + $1.turnsVisited }
		let scanSortedSpans = scans.reduce(0) { $0 + $1.sortedSpanCount }
		let scanOrderedSpans = scans.reduce(0) { $0 + $1.alreadyOrderedSpanCount }
		let summarizedUseCount = scans.reduce(0) { $0 + $1.summarizedToolSignalUseCount }
		let summarizedSignalCount = scans.reduce(0) { $0 + $1.summarizedToolSignalCount }
		let protectedTurnCount = scans.last?.protectedTurnCount ?? 0
		let downshiftCount = compactions.reduce(0) { $0 + $1.downshiftIterationCount }
		let archivePassCount = compactions.reduce(0) { $0 + $1.archiveIterationCount }
		let archivedTurnCount = compactions.reduce(0) { $0 + $1.archivedTurnCount }
		let softGuardSkippedScan = compactions.contains(where: \.softGuardSkippedScan)
		let initialUnits = compactions.first?.initialWorkingUnitCount
		let finalUnits = compactions.last?.finalWorkingUnitCount
		let compactionMS = compactions.reduce(0) { $0 + $1.durationMS }
		let scanMS = scans.reduce(0) { $0 + $1.durationMS }
		let duplicateRefreshes = metrics.refreshAttempts.filter(\.isConsecutiveDuplicateInput).count
		let equalItemReplacements = metrics.sessionItemsReplacements.filter(\.isEqual).count
		let semanticNoOpPublishes = metrics.presentationPublishes.filter(\.semanticNoOpPublishOpportunity).count
		let rowDriftCount = metrics.projectionIdentities.filter(\.rowIdentityDrift).count
		let blockDriftCount = metrics.projectionIdentities.filter(\.blockIdentityDrift).count

		return [
			"workingSourceItems=\(workingSource?.itemCount.description ?? "nil")",
			"appendedRows=\(rebuild?.appendedRowDelta.description ?? "nil")",
			"rebuildMS=\(formatMS(rebuild?.durationMS))",
			"frontier=\(rebuild?.reusableFrozenPrefixTurnCount?.description ?? "nil")",
			"mode=\(rebuild.map { String(describing: $0.requestedCompactionMode) } ?? "nil")",
			"worsen=\(rebuild?.tierWorseningCount.description ?? "nil")",
			"legacyWorsen=\(rebuild?.legacyNonFullTierWorseningCount.description ?? "nil")",
			"compactions=\(compactions.count)",
			"softSkip=\(softGuardSkippedScan)",
			"units=\(initialUnits.map(String.init) ?? "nil")->\(finalUnits.map(String.init) ?? "nil")",
			"downshift=\(downshiftCount)",
			"archivePasses=\(archivePassCount)",
			"archiveTurns=\(archivedTurnCount)",
			"protectedTurns=\(protectedTurnCount)",
			"scanTurns=\(scanTurns)",
			"scanActivities=\(scanActivities)",
			"spansSorted=\(scanSortedSpans)",
			"spansOrdered=\(scanOrderedSpans)",
			"summarizedUses=\(summarizedUseCount)",
			"summarizedTools=\(summarizedSignalCount)",
			"scanMS=\(formatMS(scanMS))",
			"projectionRows=\(projection.map { $0.workingRowCount + $0.archivedRowCount }.map(String.init) ?? "nil")",
			"projectionBlocks=\(projection.map { $0.workingBlockCount + $0.archivedBlockCount }.map(String.init) ?? "nil")",
			"projectionMS=\(formatMS(projection?.durationMS))",
			"projectionReusedPrefix=\(projection?.reusedPrefixTurnCount.description ?? "nil")",
			"projectionCacheHits=\(projection?.cacheHitCount.description ?? "nil")",
			"refreshAttempts=\(metrics.refreshAttempts.count)",
			"duplicateRefreshes=\(duplicateRefreshes)",
			"incrementalPaths=\(countedValues(metrics.refreshAttempts.map(\.incrementalPath)))",
			"itemReplacements=\(metrics.sessionItemsReplacements.count)/equal=\(equalItemReplacements)",
			"publishAttempts=\(metrics.presentationPublishes.count)/semanticNoOp=\(semanticNoOpPublishes)",
			"identityDrift=row:\(rowDriftCount)/block:\(blockDriftCount)",
			"compactionMS=\(formatMS(compactionMS))"
		].joined(separator: " ")
	}

	private func performanceDelta(
		from before: AgentTranscriptPerformanceSnapshot,
		to after: AgentTranscriptPerformanceSnapshot
	) -> TranscriptPerformanceDelta {
		TranscriptPerformanceDelta(
			projectionBuildCount: after.projectionBuildCount - before.projectionBuildCount,
			projectionPublishCount: after.projectionPublishCount - before.projectionPublishCount,
			refreshRequestCount: after.refreshRequestCount - before.refreshRequestCount,
			refreshImmediateCount: after.refreshImmediateCount - before.refreshImmediateCount,
			incrementalImportAttemptCount: after.incrementalImportAttemptCount - before.incrementalImportAttemptCount,
			incrementalImportSuccessCount: after.incrementalImportSuccessCount - before.incrementalImportSuccessCount,
			incrementalImportFallbackCount: after.incrementalImportFallbackCount - before.incrementalImportFallbackCount,
			frontierReuseAttemptCount: after.frontierReuseAttemptCount - before.frontierReuseAttemptCount,
			frontierReuseSuccessCount: after.frontierReuseSuccessCount - before.frontierReuseSuccessCount,
			frontierReuseFallbackCount: after.frontierReuseFallbackCount - before.frontierReuseFallbackCount,
			sanitizeReuseAttemptCount: after.sanitizeReuseAttemptCount - before.sanitizeReuseAttemptCount,
			sanitizeReuseSuccessCount: after.sanitizeReuseSuccessCount - before.sanitizeReuseSuccessCount,
			sanitizeReuseFallbackCount: after.sanitizeReuseFallbackCount - before.sanitizeReuseFallbackCount,
			projectionReuseAttemptCount: after.projectionReuseAttemptCount - before.projectionReuseAttemptCount,
			projectionReuseSuccessCount: after.projectionReuseSuccessCount - before.projectionReuseSuccessCount,
			projectionReuseFallbackCount: after.projectionReuseFallbackCount - before.projectionReuseFallbackCount
		)
	}

	private func formatPerformanceDelta(_ delta: TranscriptPerformanceDelta) -> String {
		[
			"build=\(delta.projectionBuildCount)",
			"publish=\(delta.projectionPublishCount)",
			"refresh=\(delta.refreshRequestCount)/immediate=\(delta.refreshImmediateCount)",
			"incremental=\(delta.incrementalImportAttemptCount)/\(delta.incrementalImportSuccessCount)/\(delta.incrementalImportFallbackCount)",
			"frontier=\(delta.frontierReuseAttemptCount)/\(delta.frontierReuseSuccessCount)/\(delta.frontierReuseFallbackCount)",
			"sanitize=\(delta.sanitizeReuseAttemptCount)/\(delta.sanitizeReuseSuccessCount)/\(delta.sanitizeReuseFallbackCount)",
			"projectionReuse=\(delta.projectionReuseAttemptCount)/\(delta.projectionReuseSuccessCount)/\(delta.projectionReuseFallbackCount)"
		].joined(separator: ",")
	}

	private func formatPerformanceSnapshot(_ snapshot: AgentTranscriptPerformanceSnapshot) -> String {
		[
			"build=\(snapshot.projectionBuildCount)",
			"publish=\(snapshot.projectionPublishCount)",
			"lastBuildMS=\(formatMS(snapshot.lastProjectionBuildDurationMS))",
			"lastRefreshMS=\(formatMS(snapshot.lastRefreshTotalDurationMS))",
			"lastImportMS=\(formatMS(snapshot.lastImportDurationMS))",
			"lastIncrementalMS=\(formatMS(snapshot.lastIncrementalImportDurationMS))",
			"lastSanitizeMS=\(formatMS(snapshot.lastSanitizeDurationMS))",
			"lastSanitizeReused=\(snapshot.lastSanitizeReusedTurnCount?.description ?? "nil")",
			"lastProjectionReused=\(snapshot.lastProjectionReusedTurnCount?.description ?? "nil")",
			"payloadScan=\(snapshot.lastPayloadCaptureScannedItemCount?.description ?? "nil")",
			"retainedPayloads=\(snapshot.retainedRawPayloadEntryCount)",
			"toolParse=\(snapshot.lastToolProcessingMetrics.jsonParseCacheHitCount)/\(snapshot.lastToolProcessingMetrics.jsonParseCacheMissCount)"
		].joined(separator: ",")
	}

	private func tierVector(_ transcript: AgentTranscript) -> String {
		let counts = Dictionary(grouping: transcript.turns, by: \.retentionTier).mapValues(\.count)
		return AgentTranscriptRetentionTier.allCases
			.map { "\($0.rawValue):\(counts[$0] ?? 0)" }
			.joined(separator: ",")
	}

	private func formatMS(_ value: Double?) -> String {
		guard let value else { return "nil" }
		return String(format: "%.3f", value)
	}

	private func formatCrawlRefreshBenchmarkReport(
		_ aggregate: CrawlRefreshBenchmarkAggregate,
		reportURL: URL,
		benchmarkJSON: String
	) -> String {
		var lines: [String] = [
			"CRAWL_TRANSCRIPT_REFRESH_BENCHMARK_BEGIN",
			"scenario=\(aggregate.scenario)",
			"reportPath=\(reportURL.path)",
			"shape=toolPairs:\(aggregate.config.toolResultPairCount) minPayloadBytes:\(aggregate.config.minimumPayloadBytes) warmup:\(aggregate.config.warmupSampleCount) measured:\(aggregate.config.measuredSampleCount)",
			"trimmedRefreshMS=\(aggregate.trimmedRefreshMS.map { formatMS($0) }.joined(separator: ","))",
			"trimmedMedianRefreshMS=\(formatMS(aggregate.trimmedMedianRefreshMS)) trimmedP95RefreshMS=\(formatMS(aggregate.trimmedP95RefreshMS)) trimmedAppendMedianMS=\(formatMS(aggregate.trimmedAppendMedianMS)) trimmedAppendP95MS=\(formatMS(aggregate.trimmedAppendP95MS))",
			"",
			"| Phase | Sample | Refresh ms | Mutation wall ms | Import ms | Sanitize ms | Projection ms | Payload ms | Raw item bytes | Ephemeral bytes | JSON parse bytes | JSON misses | Regex calls | Incremental a/s/f | Refresh/Rebuild/Projection |",
			"| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"
		]
		lines.append(formatCrawlRefreshSampleRow(aggregate.warmup))
		for sample in aggregate.measured {
			lines.append(formatCrawlRefreshSampleRow(sample))
		}
		lines.append(contentsOf: [
			"",
			"CRAWL_TRANSCRIPT_REFRESH_BENCHMARK_JSON=\(benchmarkJSON)",
			"CRAWL_TRANSCRIPT_REFRESH_BENCHMARK_END"
		])
		return lines.joined(separator: "\n")
	}

	private func formatCrawlRefreshSampleRow(_ sample: CrawlRefreshBenchmarkSample) -> String {
		let metrics = sample.toolProcessingMetrics
		return [
			"| \(sample.phase)",
			"\(sample.ordinal)",
			formatMS(sample.refreshMS),
			formatMS(sample.appendWallClockMS),
			formatMS(sample.importMS),
			formatMS(sample.sanitizeMS),
			formatMS(sample.projectionMS),
			formatMS(sample.payloadCaptureMS),
			"\(sample.rawToolResultBytesInItems)",
			"\(sample.ephemeralPayloadBytes)",
			"\(metrics.jsonParseByteCount)",
			"\(metrics.jsonParseCacheMissCount)",
			"\(metrics.regexCaptureCallCount)",
			"\(sample.incrementalImportAttempts)/\(sample.incrementalImportSuccesses)/\(sample.incrementalImportFallbacks)",
			"\(sample.refreshAttemptCount)/\(sample.rebuildCount)/\(sample.projectionBuildCount) |"
		].joined(separator: " | ")
	}

	private func crawlRefreshBenchmarkJSON(_ aggregate: CrawlRefreshBenchmarkAggregate, reportURL: URL) throws -> String {
		let payload: [String: Any] = [
			"scenario": aggregate.scenario,
			"reportPath": reportURL.path,
			"toolResultPairCount": aggregate.config.toolResultPairCount,
			"minimumPayloadBytes": aggregate.config.minimumPayloadBytes,
			"warmupSampleCount": aggregate.config.warmupSampleCount,
			"measuredSampleCount": aggregate.config.measuredSampleCount,
			"rawMeasuredRefreshMS": aggregate.measured.map(\.refreshMS),
			"trimmedRefreshMS": aggregate.trimmedRefreshMS,
			"trimmedMedianRefreshMS": aggregate.trimmedMedianRefreshMS,
			"trimmedP95RefreshMS": aggregate.trimmedP95RefreshMS,
			"trimmedAppendMedianMS": aggregate.trimmedAppendMedianMS,
			"trimmedAppendP95MS": aggregate.trimmedAppendP95MS,
			"warmup": crawlRefreshSampleDictionary(aggregate.warmup),
			"measured": aggregate.measured.map(crawlRefreshSampleDictionary),
			"correctnessStatus": "passed"
		]
		let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
		return String(data: data, encoding: .utf8) ?? "{}"
	}

	private func crawlRefreshSampleDictionary(_ sample: CrawlRefreshBenchmarkSample) -> [String: Any] {
		let metrics = sample.toolProcessingMetrics
		return [
			"ordinal": sample.ordinal,
			"phase": sample.phase,
			"appendWallClockMS": sample.appendWallClockMS,
			"refreshMS": sample.refreshMS,
			"importMS": optionalJSONValue(sample.importMS),
			"incrementalImportMS": optionalJSONValue(sample.incrementalImportMS),
			"sanitizeMS": optionalJSONValue(sample.sanitizeMS),
			"projectionMS": optionalJSONValue(sample.projectionMS),
			"payloadCaptureMS": optionalJSONValue(sample.payloadCaptureMS),
			"sanitizedActivityCount": optionalJSONValue(sample.sanitizedActivityCount),
			"sourceItemsRevision": sample.sourceItemsRevision,
			"itemCount": sample.itemCount,
			"transcriptTurnCount": sample.transcriptTurnCount,
			"rawToolResultBytesInItems": sample.rawToolResultBytesInItems,
			"ephemeralPayloadBytes": sample.ephemeralPayloadBytes,
			"retainedPayloadEntryCount": sample.retainedPayloadEntryCount,
			"retainedPayloadBytesFromSnapshot": sample.retainedPayloadBytesFromSnapshot,
			"incrementalImportAttempts": sample.incrementalImportAttempts,
			"incrementalImportSuccesses": sample.incrementalImportSuccesses,
			"incrementalImportFallbacks": sample.incrementalImportFallbacks,
			"refreshAttemptCount": sample.refreshAttemptCount,
			"rebuildCount": sample.rebuildCount,
			"projectionBuildCount": sample.projectionBuildCount,
			"sessionItemReplacementCount": sample.sessionItemReplacementCount,
			"compactionCount": sample.compactionCount,
			"presentationPublishCount": sample.presentationPublishCount,
			"toolProcessingMetrics": [
				"jsonParseAttemptCount": metrics.jsonParseAttemptCount,
				"jsonParseCacheHitCount": metrics.jsonParseCacheHitCount,
				"jsonParseCacheMissCount": metrics.jsonParseCacheMissCount,
				"jsonParseSuccessCount": metrics.jsonParseSuccessCount,
				"jsonParseFailureCount": metrics.jsonParseFailureCount,
				"jsonParseByteCount": metrics.jsonParseByteCount,
				"toolExecutionCacheHitCount": metrics.toolExecutionCacheHitCount,
				"toolExecutionCacheMissCount": metrics.toolExecutionCacheMissCount,
				"bashMetadataCacheHitCount": metrics.bashMetadataCacheHitCount,
				"bashMetadataCacheMissCount": metrics.bashMetadataCacheMissCount,
				"regexCaptureCallCount": metrics.regexCaptureCallCount
			]
		]
	}

	private func optionalJSONValue(_ value: Double?) -> Any {
		value ?? NSNull()
	}

	private func optionalJSONValue(_ value: Int?) -> Any {
		value ?? NSNull()
	}

	private func crawlTranscriptRefreshReportURL() -> URL {
		if let overridePath = ProcessInfo.processInfo.environment["RP_TRANSCRIPT_CRAWL_REFRESH_REPORT_PATH"],
			!overridePath.isEmpty {
			return URL(fileURLWithPath: overridePath)
		}
		if let overridePath = try? String(contentsOf: crawlTranscriptRefreshReportPathFlagURL(), encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines),
			!overridePath.isEmpty {
			return URL(fileURLWithPath: overridePath)
		}
		return FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-crawl-transcript-refresh-latest.md")
	}

	private func crawlTranscriptRefreshOptInFlagURL() -> URL {
		URL(fileURLWithPath: "/tmp/RepoPrompt-crawl-transcript-refresh-opt-in")
	}

	private func crawlTranscriptRefreshReportPathFlagURL() -> URL {
		URL(fileURLWithPath: "/tmp/RepoPrompt-crawl-transcript-refresh-report-path")
	}

	private func transcriptMetricsReportURL() -> URL {
		if let overridePath = ProcessInfo.processInfo.environment["RP_TRANSCRIPT_METRICS_REPORT_PATH"],
			!overridePath.isEmpty {
			return URL(fileURLWithPath: overridePath)
		}
		return FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-transcript-tool-tail-metrics-latest.txt")
	}

	private func liveTranscriptMetricsReportURL() -> URL {
		if let overridePath = ProcessInfo.processInfo.environment["RP_TRANSCRIPT_LIVE_METRICS_REPORT_PATH"],
			!overridePath.isEmpty {
			return URL(fileURLWithPath: overridePath)
		}
		return FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-transcript-live-viewmodel-metrics-latest.txt")
	}
	#endif

	private func loadLiveSessionFixtureTranscript() throws -> AgentTranscript {
		try loadFixtureTranscript(named: "review-idle-scroll-coalescing-fix-97A6BA23.json")
	}

	private func loadFixtureSession(named filename: String) throws -> AgentSession {
		let repoRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let fixtureURL = repoRoot
			.appendingPathComponent("RepoPromptTests/Fixtures/AgentSessions/\(filename)")
		let data = try Data(contentsOf: fixtureURL)
		return try JSONDecoder().decode(AgentSession.self, from: data)
	}

	private func loadFixtureTranscript(named filename: String) throws -> AgentTranscript {
		let session = try loadFixtureSession(named: filename)
		return try XCTUnwrap(session.transcript)
	}

	private func makeWorkspace(name: String, root: URL) -> WorkspaceModel {
		WorkspaceModel(
			name: name,
			repoPaths: [],
			customStoragePath: root
		)
	}

	private func makeTempDirectory() -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("RepoPrompt-AgentTranscriptServicesTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}
}

#if DEBUG
private final class TranscriptMetricsFakeCodexController: CodexSessionControlling {
	var hasActiveThread: Bool = false
	var events: AsyncStream<CodexNativeSessionController.Event> { AsyncStream { continuation in continuation.finish() } }

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing _: CodexNativeSessionController.SessionRef?,
		baseInstructions _: String
	) async throws -> CodexNativeSessionController.SessionRef {
		hasActiveThread = true
		return CodexNativeSessionController.SessionRef(
			conversationID: "test-thread",
			rolloutPath: nil,
			model: "gpt-5.2-codex",
			reasoningEffort: "medium"
		)
	}

	func readThreadSnapshot(
		includeTurns _: Bool,
		timeout _: TimeInterval?
	) async throws -> CodexNativeSessionController.ThreadSnapshot {
		CodexNativeSessionController.ThreadSnapshot(
			conversationID: "test-thread",
			rolloutPath: nil,
			model: "gpt-5.2-codex",
			reasoningEffort: "medium",
			runtimeStatus: .idle,
			currentTurnID: nil,
			activeTurnIDs: [],
			latestTurnStatus: nil
		)
	}

	func sendUserMessage(_: String) async throws {}
	func sendUserTurn(text _: String, images _: [AgentImageAttachment]) async throws {}
	func sendUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?) async throws {}
	func compactThread() async throws {}
	func cancelCurrentTurn() async {}
	func shutdown() async { hasActiveThread = false }
	func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
#endif
