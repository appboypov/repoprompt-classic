import XCTest
@testable import RepoPrompt

final class CursorIntegrationConfigurationTests: XCTestCase {
	func testCursorACPProviderLoadsExistingSessionWhenResumeIDIsPresent() throws {
		let workspace = try makeTempDirectory()
		let provider = CursorACPAgentProvider(config: CursorAgentConfig(includeRepoPromptMCPServer: false))
		let request = ACPRunRequest(
			agentKind: .cursor,
			modelString: AgentModel.cursorAuto.rawValue,
			workspacePath: workspace.path,
			resumeSessionID: " existing-cursor-session ",
			attachments: [],
			taskLabelKind: nil
		)

		let configuration = try provider.makeSessionConfiguration(for: request, mcpServer: .repoPrompt)

		XCTAssertEqual(configuration.mode, .load(existingSessionID: "existing-cursor-session"))
		XCTAssertEqual(configuration.workingDirectory, workspace.standardizedFileURL.path)
		XCTAssertTrue(configuration.mcpServers.isEmpty)
	}

	func testCursorACPProviderInjectsRepoPromptMCPThroughACPSession() throws {
		let workspace = try makeTempDirectory()
		let mcpConfiguration = RepoPromptMCPServerConfiguration(
			command: "/usr/local/bin/repoprompt-mcp",
			args: ["serve", "--stdio"],
			env: [.init(name: "RP_TEST", value: "1")]
		)
		let provider = CursorACPAgentProvider(
			config: CursorAgentConfig(includeRepoPromptMCPServer: true),
			repoPromptMCPConfiguration: mcpConfiguration
		)
		let request = ACPRunRequest(
			agentKind: .cursor,
			modelString: AgentModel.cursorAuto.rawValue,
			workspacePath: workspace.path,
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil
		)

		let configuration = try provider.makeSessionConfiguration(for: request, mcpServer: .repoPrompt)

		XCTAssertEqual(configuration.mode, .new)
		XCTAssertEqual(configuration.workingDirectory, workspace.standardizedFileURL.path)
		XCTAssertEqual(configuration.mcpServers, [mcpConfiguration])
	}

	func testCursorACPLaunchDoesNotWriteTransientProjectMCPConfig() throws {
		let workspace = try makeTempDirectory()
		let provider = CursorACPAgentProvider(config: CursorAgentConfig(includeRepoPromptMCPServer: true))
		let request = ACPRunRequest(
			agentKind: .cursor,
			modelString: AgentModel.cursorAuto.rawValue,
			workspacePath: workspace.path,
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil
		)

		let configuration = try provider.makeLaunchConfiguration(for: request)

		XCTAssertNil(configuration.cleanupArtifact)
		XCTAssertFalse(FileManager.default.fileExists(atPath: CursorIntegrationConfiguration.projectMCPConfigURL(workingDirectory: workspace.path).path))
	}

	func testCursorACPUpdateNormalizationSuppressesOnlyEmptyPlaceholderToolStateUpdates() throws {
		let provider = CursorACPAgentProvider(config: CursorAgentConfig())

		let emptyPlaceholderEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call",
				"toolCallId": "tool-empty-placeholder",
				"title": "MCP: tool",
				"kind": "other",
				"rawInput": [:]
			],
			sessionID: "session-1"
		)
		let toolCallEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call",
				"toolCallId": "tool-generic-call",
				"title": "Running RepoPrompt tool",
				"kind": "other",
				"rawInput": ["path": "ContentView.swift"]
			],
			sessionID: "session-1"
		)
		let toolStateEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-generic-state",
				"title": "Read File",
				"kind": "other",
				"status": "completed",
				"rawInput": ["path": "ContentView.swift"],
				"rawOutput": ["status": "completed"]
			],
			sessionID: "session-1"
		)
		let successOnlyPlaceholderUpdate = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-empty-placeholder",
				"status": "completed",
				"rawOutput": ["success": true]
			],
			sessionID: "session-1"
		)
		let failureOnlyPlaceholderUpdate = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-failed-placeholder",
				"status": "completed",
				"rawOutput": ["success": false]
			],
			sessionID: "session-1"
		)
		let unnamedStateEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-unnamed-state",
				"status": "in_progress",
				"rawInput": ["path": "ContentView.swift"]
			],
			sessionID: "session-1"
		)

		XCTAssertTrue(emptyPlaceholderEvents.isEmpty)
		XCTAssertTrue(successOnlyPlaceholderUpdate.isEmpty)
		XCTAssertFalse(failureOnlyPlaceholderUpdate.isEmpty)
		guard
			case .stream(let toolCall) = toolCallEvents.first,
			case .stream(let toolState) = toolStateEvents.first,
			case .stream(let unnamedState) = unnamedStateEvents.first
		else {
			return XCTFail("Expected meaningful placeholder-shaped events to normalize")
		}
		let statePayload = try XCTUnwrap(jsonObject(from: toolState.toolResultJSON))
		let rawOutput = try XCTUnwrap(statePayload["rawOutput"] as? [String: Any])

		XCTAssertEqual(toolCall.type, "tool_call")
		XCTAssertEqual(toolCall.toolName, "other")
		XCTAssertEqual(toolState.type, "tool_result")
		XCTAssertEqual(toolState.toolIsError, false)
		XCTAssertEqual(statePayload["status"] as? String, "success")
		XCTAssertEqual(rawOutput["status"] as? String, "completed")
		XCTAssertEqual(unnamedState.type, "tool_result")
		XCTAssertEqual(unnamedState.toolIsError, false)
		guard case .stream(let failedPlaceholder) = failureOnlyPlaceholderUpdate.first else {
			return XCTFail("Expected failure-only placeholder completion to normalize")
		}
		let failedPlaceholderPayload = try XCTUnwrap(jsonObject(from: failedPlaceholder.toolResultJSON))
		XCTAssertEqual(failedPlaceholder.type, "tool_result")
		XCTAssertEqual(failedPlaceholder.toolIsError, true)
		XCTAssertEqual(failedPlaceholderPayload["status"] as? String, "failed")
	}

	func testCursorACPCompletedUpdateWithFailureOutputNormalizesAsFailed() throws {
		let provider = CursorACPAgentProvider(config: CursorAgentConfig())

		let events = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-terminal-failed",
				"title": "Terminal",
				"kind": "execute",
				"status": "completed",
				"rawOutput": ["exitCode": 1, "stderr": "boom"]
			],
			sessionID: "session-1"
		)

		guard case .stream(let result) = events.first else {
			return XCTFail("Expected failed terminal update to normalize")
		}
		let payload = try XCTUnwrap(jsonObject(from: result.toolResultJSON))
		let rawOutput = try XCTUnwrap(payload["rawOutput"] as? [String: Any])
		XCTAssertEqual(result.type, "tool_result")
		XCTAssertEqual(result.toolIsError, true)
		XCTAssertEqual(payload["status"] as? String, "failed")
		XCTAssertEqual(payload["acp_status"] as? String, "completed")
		XCTAssertEqual(rawOutput["exitCode"] as? Int, 1)
	}

	func testCursorACPUpdateNormalizationMapsRepoPromptPrefixedTitles() {
		let provider = CursorACPAgentProvider(config: CursorAgentConfig())

		let setStatusEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call",
				"toolCallId": "tool-set-status",
				"title": "RepoPrompt-set_status: set_status",
				"kind": "other",
				"rawInput": ["session_name": "Working"]
			],
			sessionID: "session-1"
		)
		let oracleLogEvents = provider.normalizeSessionUpdate(
			[
				"sessionUpdate": "tool_call_update",
				"toolCallId": "tool-oracle-log",
				"title": "RepoPrompt-oracle_chat_log: oracle_chat_log",
				"kind": "other",
				"status": "failed",
				"rawInput": ["limit": 1],
				"rawOutput": ["error": "No chats found in the current tab", "tool": "oracle_chat_log"]
			],
			sessionID: "session-1"
		)

		guard
			case .stream(let setStatus) = setStatusEvents.first,
			case .stream(let oracleLog) = oracleLogEvents.first
		else {
			return XCTFail("Expected normalized stream events")
		}

		XCTAssertEqual(setStatus.type, "tool_call")
		XCTAssertEqual(setStatus.toolName, "mcp__RepoPrompt__set_status")
		XCTAssertTrue(setStatus.toolArgsJSON?.contains("Working") == true)
		XCTAssertEqual(oracleLog.type, "tool_result")
		XCTAssertEqual(oracleLog.toolName, "mcp__RepoPrompt__oracle_chat_log")
		XCTAssertEqual(oracleLog.toolIsError, true)
		XCTAssertTrue(oracleLog.toolResultJSON?.contains("No chats found") == true)
	}

	func testCursorACPRawCaptureFixtureDocumentsGatedCaptureAndRegressionUse() throws {
		let root = try loadCursorACPRawCaptureFixtureRoot()
		let captureMethod = try XCTUnwrap(root["captureMethod"] as? [String: Any])
		let enabledBy = try XCTUnwrap(captureMethod["enabledBy"] as? [String])
		let regressionTests = try XCTUnwrap(root["regressionTests"] as? [String])
		let rawEvents = try XCTUnwrap(root["rawACPToolEvents"] as? [[String: Any]])

		XCTAssertEqual(root["fixtureVersion"] as? Int, 2)
		XCTAssertEqual(root["fixtureKind"] as? String, "cursor-acp-raw-vs-rp-transcript")
		XCTAssertEqual(root["provider"] as? String, "cursor-acp")
		XCTAssertTrue((captureMethod["hook"] as? String)?.contains("env-gated") == true)
		XCTAssertTrue(enabledBy.contains { $0.contains("RP_CURSOR_RAW_CAPTURE_PATH") })
		XCTAssertFalse(enabledBy.contains { $0.contains("RP_CURSOR_RAW_CAPTURE=1") })
		XCTAssertTrue(regressionTests.contains("RepoPromptTests/CursorIntegrationConfigurationTests/testCursorACPRawCaptureCompletedUpdatesNormalizeAsSuccessAndRetainPayloads"))
		XCTAssertTrue(regressionTests.contains("RepoPromptTests/CursorIntegrationConfigurationTests/testCursorACPPersistedEditRoutesToDiffCapableCardPresentation"))
		XCTAssertGreaterThanOrEqual(rawEvents.count, 20)
		XCTAssertTrue(rawEvents.contains { event in
			guard let update = event["update"] as? [String: Any],
				let content = update["content"] as? [[String: Any]],
				let diff = content.first else { return false }
			return update["sessionUpdate"] as? String == "tool_call_update"
				&& update["status"] as? String == "completed"
				&& diff["type"] as? String == "diff"
				&& diff["oldText"] as? String != nil
				&& diff["newText"] as? String != nil
		})
	}

	func testCursorACPRawCaptureCompletedUpdatesNormalizeAsSuccessAndRetainPayloads() throws {
		let provider = CursorACPAgentProvider(config: CursorAgentConfig())
		let updates = try loadCursorACPRawCaptureToolUpdates()
		let results = updates.flatMap { update in
			provider.normalizeSessionUpdate(update, sessionID: "session-1").compactMap { event -> AIStreamResult? in
				guard case .stream(let result) = event else { return nil }
				return result
			}
		}
		let completedResults = results.filter { $0.type == "tool_result" && $0.toolResultJSON?.contains(#""acp_status" : "completed""#) == true }
		let editResults = completedResults.filter { $0.toolResultJSON?.contains(#""type" : "diff""#) == true }
		let rawOutputResults = completedResults.filter { $0.toolResultJSON?.contains(#""rawOutput""#) == true }

		XCTAssertEqual(completedResults.count, 5)
		XCTAssertTrue(completedResults.allSatisfy { $0.toolIsError == false })
		XCTAssertEqual(editResults.count, 2)
		XCTAssertGreaterThanOrEqual(rawOutputResults.count, 3)
		XCTAssertTrue(editResults.contains { result in
			guard let object = jsonObject(from: result.toolResultJSON),
				let content = object["content"] as? [[String: Any]],
				let diff = content.first else { return false }
			return diff["path"] as? String == "/tmp/rp_cursor_capture_test.txt"
				&& diff["oldText"] as? String != nil
				&& diff["newText"] as? String != nil
		})
		XCTAssertTrue(rawOutputResults.contains { $0.toolResultJSON?.contains("totalFiles") == true })
		XCTAssertTrue(rawOutputResults.contains { $0.toolResultJSON?.contains("exitCode") == true })
	}

	func testCursorACPRawCaptureReplayPersistsCompletedToolsAsSuccessAndKeepsEditDiffData() throws {
		let provider = CursorACPAgentProvider(config: CursorAgentConfig())
		let updates = try loadCursorACPRawCaptureToolUpdates()
		let items = replayCursorToolItems(updates: updates, provider: provider)
		let persistedResults = items
			.filter { $0.kind == .toolResult }
			.map { AgentChatItemPersist(from: $0) }
		let editPersisted = persistedResults.filter { $0.toolName == "edit" }

		XCTAssertEqual(persistedResults.count, 5)
		XCTAssertFalse(persistedResults.contains { $0.toolResultStatus == "failed" || $0.toolIsError == true })
		XCTAssertEqual(editPersisted.count, 2)
		for persisted in editPersisted {
			let object = try XCTUnwrap(jsonObject(from: persisted.toolResultJSON))
			let content = try XCTUnwrap(object["content"] as? [[String: Any]])
			let diff = try XCTUnwrap(content.first)
			XCTAssertEqual(persisted.toolResultStatus, "success")
			XCTAssertEqual(object["summary_only"] as? Bool, true)
			XCTAssertEqual(diff["type"] as? String, "diff")
			XCTAssertEqual(diff["path"] as? String, "/tmp/rp_cursor_capture_test.txt")
			XCTAssertNotNil(diff["unified_diff"] as? String)
			XCTAssertNil(diff["oldText"] as? String)
			XCTAssertNil(diff["newText"] as? String)
		}
		let terminalResult = try XCTUnwrap(persistedResults.first { $0.toolName?.lowercased() == "terminal" })
		let terminalObject = try XCTUnwrap(jsonObject(from: terminalResult.toolResultJSON))
		let terminalRawOutput = try XCTUnwrap(terminalObject["rawOutput"] as? [String: Any])
		XCTAssertEqual(terminalRawOutput["exitCode"] as? Int, 0)
		XCTAssertEqual(terminalRawOutput["stdout_bytes"] as? Int, "sample-output\n".utf8.count)
		XCTAssertNil(terminalRawOutput["stdout"] as? String)
		XCTAssertFalse(terminalResult.toolResultJSON?.contains("sample-output") == true)

		let readResult = try XCTUnwrap(persistedResults.first { $0.toolName == "read" })
		let readObject = try XCTUnwrap(jsonObject(from: readResult.toolResultJSON))
		let readRawOutput = try XCTUnwrap(readObject["rawOutput"] as? [String: Any])
		XCTAssertEqual(readRawOutput["content_bytes"] as? Int, "line1: alpha\nline2: DELTA\nline3: charlie\n".utf8.count)
		XCTAssertNil(readRawOutput["content"] as? String)
		XCTAssertFalse(readResult.toolResultJSON?.contains("line2: DELTA") == true)
	}

	func testCursorACPPersistedEditRoutesToDiffCapableCardPresentation() throws {
		let provider = CursorACPAgentProvider(config: CursorAgentConfig())
		let updates = try loadCursorACPRawCaptureToolUpdates()
		let items = replayCursorToolItems(updates: updates, provider: provider)
		let persistedResults = items
			.filter { $0.kind == .toolResult }
			.map { AgentChatItemPersist(from: $0) }
		let persistedReplacementEdit = try XCTUnwrap(persistedResults.first { persisted in
			persisted.toolName == "edit"
				&& persisted.toolResultJSON?.contains("line2: DELTA") == true
		})
		let persistedObject = try XCTUnwrap(jsonObject(from: persistedReplacementEdit.toolResultJSON))
		let persistedContent = try XCTUnwrap(persistedObject["content"] as? [[String: Any]])
		let persistedDiffEntry = try XCTUnwrap(persistedContent.first)
		XCTAssertNotNil(persistedDiffEntry["unified_diff"] as? String)
		XCTAssertNil(persistedDiffEntry["oldText"] as? String)
		XCTAssertNil(persistedDiffEntry["newText"] as? String)
		let restoredItem = persistedReplacementEdit.toItem()

		XCTAssertEqual(normalizedToolCardName(restoredItem.toolName), "edit")
		XCTAssertTrue(ToolCardRouter.knownResultTools.contains("edit"))

		let presentation = CursorNativeEditResultPresentation.build(for: restoredItem)
		let diff = try XCTUnwrap(presentation.diffs.first?.diff)
		XCTAssertEqual(presentation.title, "Edit File")
		XCTAssertEqual(presentation.status, .success)
		XCTAssertTrue(presentation.isExpandable)
		XCTAssertEqual(presentation.renderMode, .diffPreview)
		XCTAssertTrue(CursorNativeEditResultPresentation.shouldAutoExpandInitially(item: restoredItem, isMostRecentEdit: true))
		XCTAssertFalse(CursorNativeEditResultPresentation.shouldAutoExpandInitially(item: restoredItem, isMostRecentEdit: false))
		XCTAssertEqual(presentation.summary, "rp_cursor_capture_test.txt • edit")
		XCTAssertEqual(presentation.diffs.count, 1)
		XCTAssertTrue(diff.contains("--- a/tmp/rp_cursor_capture_test.txt"), diff)
		XCTAssertTrue(diff.contains("+++ b/tmp/rp_cursor_capture_test.txt"), diff)
		XCTAssertTrue(diff.contains("@@ -1,3 +1,3 @@"), diff)
		XCTAssertTrue(diff.contains("\n line1: alpha"), diff)
		XCTAssertTrue(diff.contains("-line2: bravo"), diff)
		XCTAssertTrue(diff.contains("+line2: DELTA"), diff)
		XCTAssertTrue(diff.contains("\n line3: charlie"), diff)
		XCTAssertFalse(diff.contains("-line1: alpha"), diff)
		XCTAssertFalse(diff.contains("+line1: alpha"), diff)
	}

	func testCursorNativeEditPersistenceSkipsGeneratedDiffForOversizedSearchReplaceBlocks() throws {
		let oldText = String(repeating: "old line\n", count: 3_000)
		let newText = String(repeating: "new line\n", count: 3_000)
		let resultObject: [String: Any] = [
			"status": "success",
			"acp_status": "completed",
			"kind": "edit",
			"title": "Edit File",
			"content": [
				[
					"type": "diff",
					"path": "/tmp/large.txt",
					"oldText": oldText,
					"newText": newText
				]
			]
		]
		let resultData = try JSONSerialization.data(withJSONObject: resultObject, options: [.sortedKeys])
		let resultJSON = try XCTUnwrap(String(data: resultData, encoding: .utf8))
		let item = AgentChatItem.toolResult(
			name: "edit",
			invocationID: UUID(),
			resultJSON: resultJSON,
			isError: false,
			sequenceIndex: 0
		)

		let persisted = AgentChatItemPersist(from: item)
		let persistedObject = try XCTUnwrap(jsonObject(from: persisted.toolResultJSON))
		let content = try XCTUnwrap(persistedObject["content"] as? [[String: Any]])
		let diff = try XCTUnwrap(content.first)

		XCTAssertLessThanOrEqual(persisted.toolResultJSON?.utf8.count ?? Int.max, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertEqual(diff["type"] as? String, "diff")
		XCTAssertEqual(diff["path"] as? String, "/tmp/large.txt")
		XCTAssertEqual(diff["diff_truncated"] as? Bool, true)
		XCTAssertEqual(diff["oldText_bytes"] as? Int, oldText.utf8.count)
		XCTAssertEqual(diff["newText_bytes"] as? Int, newText.utf8.count)
		XCTAssertNil(diff["unified_diff"] as? String)
		XCTAssertNil(diff["oldText"] as? String)
		XCTAssertNil(diff["newText"] as? String)
	}

	func testCursorNativeEditPresentationPrefersPersistedUnifiedDiffAndReflectsTruncation() throws {
		let persistedDiff = "--- a/tmp/example.swift\n+++ b/tmp/example.swift\n@@ -1 +1 @@\n-old\n+new\n"
		let resultObject: [String: Any] = [
			"status": "success",
			"acp_status": "completed",
			"kind": "edit",
			"title": "Edit File",
			"content": [
				[
					"type": "diff",
					"path": "/tmp/example.swift",
					"unified_diff": persistedDiff,
					"oldTextTruncated": true,
					"newTextTruncated": true,
					"diffTruncated": true
				]
			]
		]
		let resultData = try JSONSerialization.data(withJSONObject: resultObject, options: [.sortedKeys])
		let resultJSON = try XCTUnwrap(String(data: resultData, encoding: .utf8))
		let item = AgentChatItem.toolResult(
			name: "edit",
			invocationID: UUID(),
			resultJSON: resultJSON,
			isError: false,
			sequenceIndex: 0
		)

		let presentation = CursorNativeEditResultPresentation.build(for: item)

		XCTAssertEqual(presentation.status, .warning)
		XCTAssertEqual(presentation.summary, "example.swift • edit • diff truncated")
		XCTAssertEqual(presentation.renderMode, .diffPreview)
		XCTAssertEqual(presentation.diffs.count, 1)
		XCTAssertEqual(presentation.diffs.first?.diff, persistedDiff.trimmingCharacters(in: .whitespacesAndNewlines))
		XCTAssertEqual(presentation.diffs.first?.isTruncated, true)
	}

	func testCursorACPLaunchCandidatesUseACPModeAndApproveMCPServers() {
		XCTAssertEqual(CursorACPLaunchCandidate.cursorAgentACP.command, "cursor-agent")
		XCTAssertEqual(CursorACPLaunchCandidate.cursorAgentACP.launchArguments, ["--approve-mcps", "acp"])
		XCTAssertEqual(CursorACPLaunchCandidate.cursorAgentACP.helpArguments, ["acp", "--help"])
		XCTAssertEqual(CursorACPLaunchCandidate.cursorAgentACP.displayCommand, "cursor-agent --approve-mcps acp")

		XCTAssertEqual(CursorACPLaunchCandidate.cursorAgentSubcommand.command, "cursor")
		XCTAssertEqual(CursorACPLaunchCandidate.cursorAgentSubcommand.launchArguments, ["agent", "--approve-mcps", "acp"])
		XCTAssertEqual(CursorACPLaunchCandidate.cursorAgentSubcommand.helpArguments, ["agent", "acp", "--help"])
		XCTAssertEqual(CursorACPLaunchCandidate.cursorAgentSubcommand.displayCommand, "cursor agent --approve-mcps acp")
	}

	func testCursorACPResolvedLaunchFallbackStartsACPModeWithMCPApproval() {
		let defaultLaunch = CursorACPResolvedLaunch.fallback(additionalPathHints: [])
		XCTAssertEqual(defaultLaunch.command, "cursor-agent")
		XCTAssertEqual(defaultLaunch.arguments, ["--approve-mcps", "acp"])

		let cursorLaunch = CursorACPResolvedLaunch.fallback(commandName: "cursor", additionalPathHints: ["/opt/cursor"])
		XCTAssertEqual(cursorLaunch.command, "cursor")
		XCTAssertEqual(cursorLaunch.arguments, ["agent", "--approve-mcps", "acp"])
		XCTAssertEqual(cursorLaunch.additionalPathHints, ["/opt/cursor"])
	}

	func testWritesProjectMCPConfigWithRepoPromptServer() throws {
		let workspace = try makeTempDirectory()
		let configuration = RepoPromptMCPServerConfiguration(
			command: "/usr/local/bin/repoprompt-mcp",
			args: ["serve", "--stdio"],
			env: [
				.init(name: "RP_TEST", value: "1"),
				.init(name: "MAX_MCP_OUTPUT_TOKENS", value: "25000")
			]
		)

		let artifact = try CursorIntegrationConfiguration.prepareProjectMCPConfig(
			workingDirectory: workspace.path,
			repoPromptMCPConfiguration: configuration
		)
		defer { CursorIntegrationConfiguration.cleanupProjectMCPConfig(leaseID: artifact.id) }

		XCTAssertEqual(artifact.providerID, .cursor)
		XCTAssertEqual(artifact.kind, CursorIntegrationConfiguration.cleanupArtifactKind)

		let root = try readConfigRoot(workspace: workspace)
		let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
		let repoPrompt = try XCTUnwrap(servers["RepoPrompt"] as? [String: Any])
		XCTAssertEqual(repoPrompt["command"] as? String, "/usr/local/bin/repoprompt-mcp")
		XCTAssertEqual(repoPrompt["args"] as? [String], ["serve", "--stdio"])
		XCTAssertEqual(repoPrompt["env"] as? [String: String], [
			"RP_TEST": "1",
			"MAX_MCP_OUTPUT_TOKENS": "25000"
		])
	}

	func testMergesExistingServersAndCleansGeneratedFileAndDirectory() throws {
		let workspace = try makeTempDirectory()
		let artifact = try CursorIntegrationConfiguration.prepareProjectMCPConfig(
			workingDirectory: workspace.path,
			repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo")
		)

		var root = try readConfigRoot(workspace: workspace)
		let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
		XCTAssertNotNil(servers["RepoPrompt"])

		CursorIntegrationConfiguration.cleanupProjectMCPConfig(leaseID: artifact.id)
		let configURL = CursorIntegrationConfiguration.projectMCPConfigURL(workingDirectory: workspace.path)
		let cursorURL = CursorIntegrationConfiguration.cursorDirectoryURL(workingDirectory: workspace.path)
		XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: cursorURL.path))

		let existingRoot: [String: Any] = [
			"mcpServers": [
				"Other": [
					"command": "/usr/bin/other",
					"args": []
				]
			]
		]
		try FileManager.default.createDirectory(at: cursorURL, withIntermediateDirectories: true)
		let existingData = try JSONSerialization.data(withJSONObject: existingRoot, options: [.prettyPrinted, .sortedKeys])
		try existingData.write(to: configURL)

		let secondArtifact = try CursorIntegrationConfiguration.prepareProjectMCPConfig(
			workingDirectory: workspace.path,
			repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo")
		)
		root = try readConfigRoot(workspace: workspace)
		let mergedServers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
		XCTAssertNotNil(mergedServers["Other"])
		XCTAssertNotNil(mergedServers["RepoPrompt"])

		CursorIntegrationConfiguration.cleanupProjectMCPConfig(leaseID: secondArtifact.id)
		let restoredRoot = try readConfigRoot(workspace: workspace)
		let restoredServers = try XCTUnwrap(restoredRoot["mcpServers"] as? [String: Any])
		XCTAssertNotNil(restoredServers["Other"])
		XCTAssertNil(restoredServers["RepoPrompt"])
		XCTAssertTrue(FileManager.default.fileExists(atPath: cursorURL.path))
	}

	func testOverlappingLeasesKeepConfigUntilFinalCleanup() throws {
		let workspace = try makeTempDirectory()
		let firstArtifact = try CursorIntegrationConfiguration.prepareProjectMCPConfig(
			workingDirectory: workspace.path,
			repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo")
		)
		let secondArtifact = try CursorIntegrationConfiguration.prepareProjectMCPConfig(
			workingDirectory: workspace.path,
			repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo")
		)
		let configURL = CursorIntegrationConfiguration.projectMCPConfigURL(workingDirectory: workspace.path)

		CursorIntegrationConfiguration.cleanupProjectMCPConfig(leaseID: firstArtifact.id)
		XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path), "First cleanup should defer while another lease is active.")
		let root = try readConfigRoot(workspace: workspace)
		let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
		XCTAssertNotNil(servers["RepoPrompt"])

		CursorIntegrationConfiguration.cleanupProjectMCPConfig(leaseID: secondArtifact.id)
		XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
	}

	func testCleanupDoesNotClobberUserChanges() throws {
		let workspace = try makeTempDirectory()
		let artifact = try CursorIntegrationConfiguration.prepareProjectMCPConfig(
			workingDirectory: workspace.path,
			repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo")
		)
		let configURL = CursorIntegrationConfiguration.projectMCPConfigURL(workingDirectory: workspace.path)
		let modifiedRoot: [String: Any] = [
			"mcpServers": [
				"UserServer": ["command": "/usr/bin/user", "args": []]
			]
		]
		let modifiedData = try JSONSerialization.data(withJSONObject: modifiedRoot, options: [.prettyPrinted, .sortedKeys])
		try modifiedData.write(to: configURL, options: .atomic)

		CursorIntegrationConfiguration.cleanupProjectMCPConfig(leaseID: artifact.id)

		let root = try readConfigRoot(workspace: workspace)
		let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
		XCTAssertNotNil(servers["UserServer"])
		XCTAssertNil(servers["RepoPrompt"])
	}

	func testInvalidExistingJSONThrows() throws {
		let workspace = try makeTempDirectory()
		let cursorURL = CursorIntegrationConfiguration.cursorDirectoryURL(workingDirectory: workspace.path)
		let configURL = CursorIntegrationConfiguration.projectMCPConfigURL(workingDirectory: workspace.path)
		try FileManager.default.createDirectory(at: cursorURL, withIntermediateDirectories: true)
		try "not-json".write(to: configURL, atomically: true, encoding: .utf8)

		XCTAssertThrowsError(
			try CursorIntegrationConfiguration.prepareProjectMCPConfig(
				workingDirectory: workspace.path,
				repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/bin/echo")
			)
		) { error in
			guard case AIProviderError.invalidConfiguration(let detail) = error else {
				XCTFail("Expected invalidConfiguration error, got \(error)")
				return
			}
			XCTAssertTrue(detail.contains("Unable to merge Cursor MCP config"), detail)
		}
	}

	private func loadCursorACPRawCaptureToolUpdates(sourceFile: StaticString = #filePath) throws -> [[String: Any]] {
		let root = try loadCursorACPRawCaptureFixtureRoot(sourceFile: sourceFile)
		let events = try XCTUnwrap(root["rawACPToolEvents"] as? [[String: Any]])
		return events.compactMap { $0["update"] as? [String: Any] }
	}

	private func loadCursorACPRawCaptureFixtureRoot(sourceFile: StaticString = #filePath) throws -> [String: Any] {
		let url = try cursorACPRawCaptureFixtureURL(sourceFile: sourceFile)
		let data = try Data(contentsOf: url)
		return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
	}

	private func cursorACPRawCaptureFixtureURL(sourceFile: StaticString = #filePath) throws -> URL {
		let sourcePath = String(describing: sourceFile)
		var directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
		let fileManager = FileManager.default
		let relative = "RepoPromptTests/Fixtures/AgentSessions/cursor-acp-raw-capture-A7A86ADC.fixture.json"

		for _ in 0..<10 {
			let candidate = directory.appendingPathComponent(relative)
			if fileManager.fileExists(atPath: candidate.path) {
				return candidate
			}
			let parent = directory.deletingLastPathComponent()
			if parent.path == directory.path { break }
			directory = parent
		}

		let bundle = Bundle(for: Self.self)
		if let bundled = bundle.url(
			forResource: "cursor-acp-raw-capture-A7A86ADC.fixture",
			withExtension: "json",
			subdirectory: "Fixtures/AgentSessions"
		) {
			return bundled
		}
		throw NSError(domain: "CursorIntegrationConfigurationTests", code: 1, userInfo: [
			NSLocalizedDescriptionKey: "Missing cursor ACP raw capture fixture from \(sourcePath)"
		])
	}

	private func replayCursorToolItems(
		updates: [[String: Any]],
		provider: CursorACPAgentProvider
	) -> [AgentChatItem] {
		var items: [AgentChatItem] = []
		for update in updates {
			let streamResults = provider.normalizeSessionUpdate(update, sessionID: "session-1").compactMap { event -> AIStreamResult? in
				guard case .stream(let result) = event else { return nil }
				return result
			}
			for result in streamResults {
				switch result.type {
				case "tool_call":
					guard let toolName = result.toolName else { continue }
					items.append(AgentChatItem.toolCall(
						name: toolName,
						invocationID: result.toolInvocationID,
						argsJSON: result.toolArgsJSON ?? result.toolArgs,
						sequenceIndex: items.count
					))
				case "tool_result":
					guard let toolName = result.toolName else { continue }
					let outputJSON = result.toolResultJSON ?? result.toolOutput ?? ""
					let argsJSON = result.toolArgsJSON ?? result.toolArgs
					if let invocationID = result.toolInvocationID,
						let index = items.lastIndex(where: { $0.toolInvocationID == invocationID }) {
						var updated = items[index]
						updated.kind = .toolResult
						updated.toolResultJSON = outputJSON
						updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
						updated.toolIsError = result.toolIsError
						updated.text = outputJSON
						items[index] = updated
					} else {
						items.append(AgentChatItem.toolResult(
							name: toolName,
							invocationID: result.toolInvocationID,
							resultJSON: outputJSON,
							isError: result.toolIsError,
							sequenceIndex: items.count
						))
					}
				default:
					break
				}
			}
		}
		return items
	}

	private func jsonObject(from raw: String?) -> [String: Any]? {
		guard let raw = raw,
			let data = raw.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }
		return object
	}

	private func makeTempDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("CursorIntegrationConfigurationTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: url)
		}
		return url
	}

	private func readConfigRoot(workspace: URL) throws -> [String: Any] {
		let configURL = CursorIntegrationConfiguration.projectMCPConfigURL(workingDirectory: workspace.path)
		let data = try Data(contentsOf: configURL)
		return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
	}
}
