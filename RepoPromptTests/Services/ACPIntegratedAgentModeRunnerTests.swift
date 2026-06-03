import XCTest
import MCP
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class ACPIntegratedAgentModeRunnerTests: XCTestCase {
	func testHandleToolStreamEventConsumesExplicitRepoPromptProviderToolCall() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini
		let invocationID = UUID()

		let consumed = runner.handleToolStreamEvent(
			.toolCall(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: invocationID,
				argsJSON: #"{"path":"README.md"}"#
			)),
			session: session
		)

		XCTAssertTrue(consumed)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.last?.kind, .toolCall)
		XCTAssertEqual(session.items.last?.toolInvocationID, invocationID)
		XCTAssertEqual(session.items.last?.toolArgsJSON, #"{"path":"README.md"}"#)
	}

	func testHandleToolStreamEventConsumesExplicitRepoPromptProviderToolResult() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini
		let invocationID = UUID()

		let consumed = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: invocationID,
				argsJSON: #"{"path":"README.md"}"#,
				resultJSON: #"{"content":"hello"}"#,
				isError: false
			)),
			session: session
		)

		XCTAssertTrue(consumed)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.last?.kind, .toolResult)
		XCTAssertEqual(session.items.last?.toolInvocationID, invocationID)
		XCTAssertEqual(session.items.last?.toolResultJSON, #"{"content":"hello"}"#)
	}

	func testHandleToolStreamEventConsumesHiddenRepoPromptProviderToolsWithoutRendering() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .cursor
		let invocationID = UUID()

		let callConsumed = runner.handleToolStreamEvent(
			.toolCall(.init(
				toolName: "mcp__RepoPrompt__set_status",
				invocationID: invocationID,
				argsJSON: #"{"session_name":"Working"}"#
			)),
			session: session
		)
		let resultConsumed = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__set_status",
				invocationID: invocationID,
				argsJSON: #"{"session_name":"Working"}"#,
				resultJSON: #"{"ok":true}"#,
				isError: false
			)),
			session: session
		)

		XCTAssertTrue(callConsumed)
		XCTAssertTrue(resultConsumed)
		XCTAssertTrue(session.items.isEmpty, "Hidden ACP control tools should be consumed without visible transcript cards")
	}

	func testHandleToolStreamEventRendersOracleChatLogErrorAsNamedToolResult() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .cursor
		let invocationID = UUID()

		let consumed = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__oracle_chat_log",
				invocationID: invocationID,
				argsJSON: #"{"limit":1}"#,
				resultJSON: #"{"error":"No chats found in the current tab","tool":"oracle_chat_log"}"#,
				isError: true
			)),
			session: session
		)

		XCTAssertTrue(consumed)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.last?.kind, .toolResult)
		XCTAssertEqual(session.items.last?.toolName, "oracle_chat_log")
		XCTAssertEqual(session.items.last?.toolIsError, true)
		XCTAssertTrue(session.items.last?.toolResultJSON?.contains("No chats found") == true)
	}

	func testHandleToolStreamEventDoesNotConsumeNonRepoPromptProviderToolCall() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini

		let consumed = runner.handleToolStreamEvent(
			.toolCall(.init(
				toolName: "shell",
				invocationID: UUID(),
				argsJSON: #"{"command":"pwd"}"#
			)),
			session: session
		)

		XCTAssertFalse(consumed)
		XCTAssertTrue(session.items.isEmpty)
	}

	func testSyncACPSelectedModelPreservesExplicitOpenCodeSelection() {
		defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
				options: [
					AgentModelOption(
						rawValue: "anthropic/claude-sonnet-4",
						displayName: "Anthropic/Claude Sonnet 4",
						description: nil,
						isPlaceholderDefault: false,
						isProviderDefault: false
					),
					AgentModelOption(
						rawValue: "openai/gpt-5",
						displayName: "OpenAI/GPT-5",
						description: nil,
						isPlaceholderDefault: false,
						isProviderDefault: false
					)
				],
				currentModelRaw: "openai/gpt-5"
			),
			for: .openCode
		)
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .openCode
		session.selectedModelRaw = "anthropic/claude-sonnet-4"

		let changed = runner.testSyncACPSelectedModelFromRegistryIfNeeded(agentKind: .openCode, session: session)

		XCTAssertFalse(changed)
		XCTAssertEqual(session.selectedModelRaw, "anthropic/claude-sonnet-4")
	}

	func testSyncACPSelectedModelPreservesExplicitOpenCodeSelectionMissingFromRegistry() {
		defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
				options: [
					AgentModelOption(
						rawValue: "openai/gpt-5",
						displayName: "OpenAI/GPT-5",
						description: nil,
						isPlaceholderDefault: false,
						isProviderDefault: true
					)
				],
				currentModelRaw: "openai/gpt-5"
			),
			for: .openCode
		)
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .openCode
		session.selectedModelRaw = "custom/open-code-model"

		let changed = runner.testSyncACPSelectedModelFromRegistryIfNeeded(agentKind: .openCode, session: session)

		XCTAssertFalse(changed)
		XCTAssertEqual(session.selectedModelRaw, "custom/open-code-model")
	}

	func testSyncACPSelectedModelAdoptsOpenCodeRegistryDefaultFromPlaceholder() {
		defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
				options: [
					AgentModelOption(
						rawValue: "anthropic/claude-sonnet-4",
						displayName: "Anthropic/Claude Sonnet 4",
						description: nil,
						isPlaceholderDefault: false,
						isProviderDefault: false
					),
					AgentModelOption(
						rawValue: "openai/gpt-5",
						displayName: "OpenAI/GPT-5",
						description: nil,
						isPlaceholderDefault: false,
						isProviderDefault: false
					)
				],
				currentModelRaw: "openai/gpt-5"
			),
			for: .openCode
		)
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .openCode
		session.selectedModelRaw = AgentModel.defaultModel.rawValue

		let changed = runner.testSyncACPSelectedModelFromRegistryIfNeeded(agentKind: .openCode, session: session)

		XCTAssertTrue(changed)
		XCTAssertEqual(session.selectedModelRaw, "openai/gpt-5")
	}

	func testTrackerToolEventsAreRenderedForACPRepoPromptTools() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini
		let invocationID = UUID()

		runner.testHandleTrackerToolCall(
			invocationID: invocationID,
			toolName: "agent_run",
			args: nil,
			session: session
		)

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.last?.kind, .toolCall)
		XCTAssertEqual(session.items.last?.toolName, "agent_run")
		XCTAssertEqual(session.items.last?.toolInvocationID, invocationID)
	}

	func testOpenCodeSanitizedRepoPromptProviderToolCallMergesWithTrackerCallbacks() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .openCode
		let providerInvocationID = UUID()
		let trackerInvocationID = UUID()
		let trackerArgs: [String: Value] = ["path": .string("README.md")]

		let consumed = runner.handleToolStreamEvent(
			.toolCall(.init(
				toolName: "RepoPrompt_read_file",
				invocationID: providerInvocationID,
				argsJSON: "{}"
			)),
			session: session
		)
		runner.testHandleTrackerToolCall(
			invocationID: trackerInvocationID,
			toolName: "read_file",
			args: trackerArgs,
			session: session
		)
		runner.testHandleTrackerToolResult(
			invocationID: trackerInvocationID,
			toolName: "read_file",
			args: trackerArgs,
			resultJSON: #"{"content":"hello"}"#,
			isError: false,
			session: session
		)

		XCTAssertTrue(consumed)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.last?.kind, .toolResult)
		XCTAssertEqual(session.items.last?.toolName, "read_file")
		XCTAssertEqual(session.items.last?.toolInvocationID, providerInvocationID)
		XCTAssertTrue(session.items.last?.toolArgsJSON?.contains("README.md") == true)
		XCTAssertEqual(session.items.last?.toolResultJSON, #"{"content":"hello"}"#)
	}

	func testTrackerToolResultCompletesExistingACPProviderToolCall() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini
		let providerInvocationID = UUID()
		let trackerInvocationID = UUID()
		let providerArgs = #"{"detach":true,"op":"start"}"#
		let trackerArgs: [String: Value] = ["detach": .bool(true), "op": .string("start")]

		_ = runner.handleToolStreamEvent(
			.toolCall(.init(
				toolName: "mcp__RepoPrompt__agent_run",
				invocationID: providerInvocationID,
				argsJSON: providerArgs
			)),
			session: session
		)
		runner.testHandleTrackerToolResult(
			invocationID: trackerInvocationID,
			toolName: "agent_run",
			args: trackerArgs,
			resultJSON: #"{"status":"running"}"#,
			isError: false,
			session: session
		)

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.last?.kind, .toolResult)
		XCTAssertEqual(session.items.last?.toolName, "agent_run")
		XCTAssertEqual(session.items.last?.toolInvocationID, providerInvocationID)
		XCTAssertEqual(session.items.last?.toolResultJSON, #"{"status":"running"}"#)
	}

	func testProviderToolResultDoesNotDuplicateAfterTrackerResult() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini
		let providerInvocationID = UUID()
		let trackerInvocationID = UUID()
		let providerArgs = #"{"detach":true,"op":"start"}"#
		let trackerArgs: [String: Value] = ["detach": .bool(true), "op": .string("start")]

		_ = runner.handleToolStreamEvent(
			.toolCall(.init(
				toolName: "mcp__RepoPrompt__agent_run",
				invocationID: providerInvocationID,
				argsJSON: providerArgs
			)),
			session: session
		)
		runner.testHandleTrackerToolResult(
			invocationID: trackerInvocationID,
			toolName: "agent_run",
			args: trackerArgs,
			resultJSON: #"{"status":"running"}"#,
			isError: false,
			session: session
		)
		_ = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__agent_run",
				invocationID: providerInvocationID,
				argsJSON: nil,
				resultJSON: #"{"status":"completed"}"#,
				isError: false
			)),
			session: session
		)

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.last?.kind, .toolResult)
		XCTAssertEqual(session.items.last?.toolInvocationID, providerInvocationID)
		XCTAssertEqual(session.items.last?.toolResultJSON, #"{"status":"completed"}"#)
	}

	func testProviderToolCallCorrelatesExistingTrackerToolCall() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini
		let providerInvocationID = UUID()
		let trackerInvocationID = UUID()
		let providerArgs = #"{"detach":true,"op":"start"}"#
		let trackerArgs: [String: Value] = ["detach": .bool(true), "op": .string("start")]

		runner.testHandleTrackerToolCall(
			invocationID: trackerInvocationID,
			toolName: "agent_run",
			args: trackerArgs,
			session: session
		)
		_ = runner.handleToolStreamEvent(
			.toolCall(.init(
				toolName: "mcp__RepoPrompt__agent_run",
				invocationID: providerInvocationID,
				argsJSON: providerArgs
			)),
			session: session
		)
		runner.testHandleTrackerToolResult(
			invocationID: trackerInvocationID,
			toolName: "agent_run",
			args: trackerArgs,
			resultJSON: #"{"status":"running"}"#,
			isError: false,
			session: session
		)

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.last?.kind, .toolResult)
		XCTAssertEqual(session.items.last?.toolInvocationID, providerInvocationID)
		XCTAssertEqual(session.items.last?.toolResultJSON, #"{"status":"running"}"#)
	}

	func testDuplicateProviderInvocationIDAcrossTurnsDoesNotOverwritePreviousTerminalResult() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini
		let reusedInvocationID = UUID(uuidString: "A1C44EA9-981C-5F3C-98A2-7391D06DBADE")!
		let firstArgs = #"{"path":"README.md"}"#
		let firstResult = #"{"status":"success","content":"first"}"#
		let secondArgs = #"{"path":"Package.swift"}"#
		let secondResult = #"{"status":"failed","error":"missing"}"#

		session.appendItem(.user("first turn", sequenceIndex: session.nextSequenceIndex))
		_ = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: reusedInvocationID,
				argsJSON: firstArgs,
				resultJSON: firstResult,
				isError: false
			)),
			session: session
		)
		let firstResultItemID = session.items.last?.id
		session.appendItem(.assistant("done", sequenceIndex: session.nextSequenceIndex))
		session.appendItem(.user("second turn", sequenceIndex: session.nextSequenceIndex))

		_ = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: reusedInvocationID,
				argsJSON: secondArgs,
				resultJSON: secondResult,
				isError: true
			)),
			session: session
		)

		let toolResults = session.items.filter { $0.kind == .toolResult }
		XCTAssertEqual(toolResults.count, 2)
		XCTAssertEqual(toolResults[0].id, firstResultItemID)
		XCTAssertEqual(toolResults[0].toolInvocationID, reusedInvocationID)
		XCTAssertEqual(toolResults[0].toolResultJSON, firstResult)
		XCTAssertEqual(toolResults[1].toolInvocationID, reusedInvocationID)
		XCTAssertEqual(toolResults[1].toolResultJSON, secondResult)
	}

	func testDuplicateProviderResultDeliveryWithinCurrentTurnUpdatesSameExecution() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini
		let invocationID = UUID()
		let args = #"{"path":"README.md"}"#
		let firstResult = #"{"status":"success","content":"first"}"#
		let updatedResult = #"{"status":"success","content":"updated"}"#

		session.appendItem(.user("read", sequenceIndex: session.nextSequenceIndex))
		_ = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: invocationID,
				argsJSON: args,
				resultJSON: firstResult,
				isError: false
			)),
			session: session
		)
		let firstItemID = session.items.last?.id
		_ = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: invocationID,
				argsJSON: args,
				resultJSON: updatedResult,
				isError: false
			)),
			session: session
		)

		let toolResults = session.items.filter { $0.kind == .toolResult }
		XCTAssertEqual(toolResults.count, 1)
		XCTAssertEqual(toolResults[0].id, firstItemID)
		XCTAssertEqual(toolResults[0].toolResultJSON, updatedResult)
	}

	func testCurrentTurnRunningResultWithDuplicateInvocationButDifferentToolIsNotOverwritten() {
		let runner = makeRunner()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .gemini
		let reusedInvocationID = UUID()
		let agentRunResult = #"{"status":"running"}"#
		let readFileResult = #"{"status":"success","content":"hello"}"#

		session.appendItem(.user("do two things", sequenceIndex: session.nextSequenceIndex))
		_ = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__agent_run",
				invocationID: reusedInvocationID,
				argsJSON: #"{"op":"start","detach":true}"#,
				resultJSON: agentRunResult,
				isError: false
			)),
			session: session
		)
		let agentRunItemID = session.items.last?.id
		_ = runner.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: reusedInvocationID,
				argsJSON: #"{"path":"README.md"}"#,
				resultJSON: readFileResult,
				isError: false
			)),
			session: session
		)

		let toolResults = session.items.filter { $0.kind == .toolResult }
		XCTAssertEqual(toolResults.count, 2)
		XCTAssertEqual(toolResults[0].id, agentRunItemID)
		XCTAssertEqual(toolResults[0].toolName, "agent_run")
		XCTAssertEqual(toolResults[0].toolResultJSON, agentRunResult)
		XCTAssertEqual(toolResults[1].toolName, "read_file")
		XCTAssertEqual(toolResults[1].toolResultJSON, readFileResult)
	}

	private func makeRunner() -> ACPIntegratedAgentModeRunner {
		ACPIntegratedAgentModeRunner(
			hooks: .init(
				estimateRuntimeTokens: { _ in 0 },
				addUserInputTokensToActiveNonCodexTurn: { _, _ in },
				startNonCodexTurnAccountingIfNeeded: { _, _ in },
				reserveAttachmentsForTurn: { _, _ in nil },
				markAttachmentsConsumed: { _, _ in },
				stageConsumedAttachmentFilesForDeferredCleanup: { _, _ in },
				consumeDeferredAttachmentCleanup: { _, _ in },
				finalizeAttachmentsForTurn: { _, _, _ in },
				setAgentRunActive: { _, _ in },
				updateBindings: { _ in },
				requestUIRefresh: { _, _ in },
				scheduleSave: { _ in },
				notifyAgentTurnComplete: { _ in },
				handleHeadlessStreamResult: { _, _, _, _ in },
				buildHeadlessAgentMessage: { _, _, _, _, _ in AgentMessage(userMessage: "") },
				prepareForTerminalPersistence: { _, _, _ in },
				finalizeStreamingItems: { _ in },
				finalizePendingToolCalls: { _, _ in },
				finalizePendingToolCallsWithUpperBound: { _, _, _ in },
				finalizeNonCodexTurnUsage: { _, _, _, _ in },
				cancelPendingQuestion: { _ in },
				cancelPendingApproval: { _ in },
				cancelPendingApplyEditsReview: { _, _ in },
				clearPendingAssistantDelta: { _ in },
				startFollowUpRun: { _, _ in },
				restoreDraftText: { _, _, _, _ in },
				augmentUserMessageForProviderSend: { text, _, _, _ in text },
				stageResumeRecoveryHandoffIfNeeded: { _ in },
				prependPendingHandoffIfNeeded: { text, _ in text },
				recordPendingHandoffSendOutcome: { _, _ in },
				signalMCPInstructionDelivered: { _ in }
			),
			toolTrackingHooks: .noOp,
			providerFactory: { _, _ in
				fatalError("ACP provider factory should not be used in this test")
			},
			controllerFactory: { _, _ in
				fatalError("ACP controller factory should not be used in this test")
			}
		)
	}
}
