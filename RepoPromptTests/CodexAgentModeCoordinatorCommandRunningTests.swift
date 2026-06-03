import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class CodexAgentModeCoordinatorCommandRunningTests: XCTestCase {
	func testMergeCommandRunningUpdatesCapsOutput() {
		let maxChars = CodexAgentModeCoordinator.test_maxMergedCommandRunningOutputCharacters
		let existingOutput = String(repeating: "A", count: maxChars * 2)
		let incomingOutput = String(repeating: "B", count: maxChars * 2)

		let existing = CodexNativeSessionController.CommandExecutionRunningUpdate(
			invocationID: nil,
			processID: "123",
			appendedOutput: existingOutput
		)
		let incoming = CodexNativeSessionController.CommandExecutionRunningUpdate(
			invocationID: nil,
			processID: "123",
			appendedOutput: incomingOutput
		)

		let merged = CodexAgentModeCoordinator.test_mergeCommandRunningUpdates(
			existing: existing,
			incoming: incoming
		)

		let mergedOutput = merged.appendedOutput
		XCTAssertNotNil(mergedOutput)
		XCTAssertLessThanOrEqual(mergedOutput?.count ?? 0, maxChars)
		XCTAssertTrue(mergedOutput?.contains("B") == true)
	}

	func testCollapseCodexModelOptionsDoesNotLabelDefaultRemoteModelAsDefault() {
		let options: [AgentModelOption] = [
			AgentModelOption(
				rawValue: AgentModel.defaultModel.rawValue,
				displayName: AgentModel.defaultModel.displayName,
				description: AgentModel.defaultModel.description,
				isDefault: true
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-medium",
				displayName: "GPT-5.3 Codex Medium",
				description: "Latest frontier agentic coding model.",
				isDefault: true,
				supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
				defaultReasoningEffort: .medium
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-high",
				displayName: "GPT-5.3 Codex High",
				description: "Latest frontier agentic coding model.",
				isDefault: false,
				supportedReasoningEfforts: [.low, .medium, .high, .xhigh],
				defaultReasoningEffort: .medium
			)
		]

		let collapsed = CodexAgentModeCoordinator.test_collapseCodexModelOptions(options)
		let defaultOption = collapsed.first(where: { $0.rawValue == AgentModel.defaultModel.rawValue })
		let codexOption = collapsed.first(where: { $0.rawValue == "gpt-5.3-codex" })

		XCTAssertEqual(defaultOption?.displayName, AgentModel.defaultModel.displayName)
		XCTAssertTrue(defaultOption?.isPlaceholderDefault == true)
		XCTAssertFalse(defaultOption?.isProviderDefault == true)
		XCTAssertEqual(codexOption?.displayName, "GPT-5.3 Codex")
		XCTAssertTrue(codexOption?.isDefault == true)
		XCTAssertFalse(codexOption?.isPlaceholderDefault == true)
		XCTAssertTrue(codexOption?.isProviderDefault == true)
		XCTAssertEqual(codexOption?.defaultReasoningEffort, .medium)
		XCTAssertEqual(codexOption?.supportedReasoningEfforts, [.low, .medium, .high, .xhigh])
	}

	func testCollapseCodexModelOptionsGroupsFamiliesDescending() {
		let options: [AgentModelOption] = [
			AgentModelOption(
				rawValue: AgentModel.defaultModel.rawValue,
				displayName: AgentModel.defaultModel.displayName,
				description: AgentModel.defaultModel.description,
				isDefault: true
			),
			AgentModelOption(
				rawValue: "gpt-5.1-codex-max-medium",
				displayName: "GPT-5.1 Codex Max Medium",
				description: nil,
				isDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-spark-medium",
				displayName: "GPT-5.3 Codex Spark Medium",
				description: nil,
				isDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.2-medium",
				displayName: "GPT-5.2 Medium",
				description: nil,
				isDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.2-codex-medium",
				displayName: "GPT-5.2 Codex Medium",
				description: nil,
				isDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-medium",
				displayName: "GPT-5.3 Codex Medium",
				description: nil,
				isDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.1-codex-mini-medium",
				displayName: "GPT-5.1 Codex Mini Medium",
				description: nil,
				isDefault: false
			)
		]

		let collapsed = CodexAgentModeCoordinator.test_collapseCodexModelOptions(options)
		let orderedRaw = collapsed
			.filter { !$0.isPlaceholderDefault }
			.map { $0.rawValue.lowercased() }

		let familyOrder = orderedRaw.map { raw -> String in
			if raw.contains("gpt-5.3") { return "5.3" }
			if raw.contains("gpt-5.2") { return "5.2" }
			if raw.contains("gpt-5.1") { return "5.1" }
			return "other"
		}

		XCTAssertEqual(familyOrder, ["5.3", "5.3", "5.2", "5.2", "5.1", "5.1"])
	}

	func testUnobservedRunningProcessWithinGraceStaysAlive() {
		let now = Date()
		let shouldTreatAsAlive = CodexAgentModeCoordinator.test_shouldTreatRunningProcessAsAlive(
			observedAliveProcessIDs: [],
			processID: "12345",
			firstSeenAt: now.addingTimeInterval(-0.4),
			now: now,
			graceInterval: 1.2,
			isAlive: false
		)

		XCTAssertTrue(shouldTreatAsAlive)
	}

	func testUnobservedRunningProcessAfterGraceCanFinalizeWhenDead() {
		let now = Date()
		let shouldTreatAsAlive = CodexAgentModeCoordinator.test_shouldTreatRunningProcessAsAlive(
			observedAliveProcessIDs: [],
			processID: "12345",
			firstSeenAt: now.addingTimeInterval(-2.0),
			now: now,
			graceInterval: 1.2,
			isAlive: false
		)

		XCTAssertFalse(shouldTreatAsAlive)
	}

	func testObservedAliveProcessStillRequiresLivePid() {
		let now = Date()
		let shouldTreatAsAlive = CodexAgentModeCoordinator.test_shouldTreatRunningProcessAsAlive(
			observedAliveProcessIDs: ["12345"],
			processID: "12345",
			firstSeenAt: now.addingTimeInterval(-0.1),
			now: now,
			graceInterval: 1.2,
			isAlive: false
		)

		XCTAssertFalse(shouldTreatAsAlive)
	}

	func testLateCommandRunningUpdatesDoNotReviveNonSuccessfulTerminalBashResults() async throws {
		struct TerminalCase {
			let name: String
			let resultJSON: String
			let isError: Bool
			let expectedStatus: String
			let expectedExitCode: Int?
		}

		let cases: [TerminalCase] = [
			.init(
				name: "failed-status",
				resultJSON: #"{"type":"commandExecution","status":"failed","exitCode":1,"processId":"failed-123","command":"npm run dev","aggregatedOutput":"terminal failed\n"}"#,
				isError: true,
				expectedStatus: "failed",
				expectedExitCode: 1
			),
			.init(
				name: "nonzero-exit",
				resultJSON: #"{"type":"commandExecution","status":"completed","exitCode":2,"processId":"nonzero-123","command":"npm test","aggregatedOutput":"terminal nonzero\n"}"#,
				isError: false,
				expectedStatus: "completed",
				expectedExitCode: 2
			),
			.init(
				name: "cancelled-status",
				resultJSON: #"{"type":"commandExecution","status":"cancelled","processId":"cancelled-123","command":"sleep 10","aggregatedOutput":"terminal cancelled\n"}"#,
				isError: false,
				expectedStatus: "cancelled",
				expectedExitCode: nil
			),
			.init(
				name: "tool-is-error",
				resultJSON: #"{"type":"commandExecution","status":"completed","exitCode":0,"processId":"tool-error-123","command":"custom","aggregatedOutput":"terminal tool error\n"}"#,
				isError: true,
				expectedStatus: "completed",
				expectedExitCode: 0
			)
		]

		for terminalCase in cases {
			let coordinator = makeCoordinatorForTeardownTests()
			let session = AgentModeViewModel.TabSession(tabID: UUID())
			session.selectedAgent = .codexExec
			session.runState = .completed
			let processID = try XCTUnwrap(BashToolResultParser.parseLivenessMetadata(raw: terminalCase.resultJSON).processID)
			session.items = [
				.toolResult(
					name: "bash",
					invocationID: nil,
					resultJSON: terminalCase.resultJSON,
					isError: terminalCase.isError,
					sequenceIndex: 0
				)
			]

			await coordinator.test_handleCodexNativeEvent(
				.commandExecutionRunning(.init(
					invocationID: nil,
					processID: processID,
					appendedOutput: "late output for \(terminalCase.name)\n"
				)),
				session: session
			)
			let didMergeLateOutput = await waitForCondition(timeoutSeconds: 1.0) {
				session.items.first?.toolResultJSON?.contains("late output for \(terminalCase.name)") == true
			}
			XCTAssertTrue(didMergeLateOutput, terminalCase.name)

			let bashItem = try XCTUnwrap(session.items.first, terminalCase.name)
			let parsed = BashToolResultParser.parse(raw: bashItem.toolResultJSON, argsJSON: bashItem.toolArgsJSON)
			XCTAssertFalse(parsed.isRunning, terminalCase.name)
			XCTAssertEqual(parsed.statusWord, terminalCase.expectedStatus, terminalCase.name)
			XCTAssertEqual(parsed.exitCode, terminalCase.expectedExitCode, terminalCase.name)
			XCTAssertTrue(parsed.output?.contains("terminal") == true, terminalCase.name)
			XCTAssertTrue(parsed.output?.contains("late output for \(terminalCase.name)") == true, terminalCase.name)
			XCTAssertEqual(bashItem.toolIsError, terminalCase.isError, terminalCase.name)
			XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty, terminalCase.name)
		}
	}

	func testCommandExecutionRunningDoesNotReviveTerminalBashResultAfterRunCompleted() async {
		let coordinator = makeCoordinatorForTeardownTests()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .completed
		let completed = #"{"type":"commandExecution","status":"completed","exitCode":0,"processId":"123","command":"npm run dev","aggregatedOutput":"done\n"}"#
		session.items = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: completed,
				isError: false,
				sequenceIndex: 0
			)
		]

		await coordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(.init(invocationID: nil, processID: "123", appendedOutput: "late output\n")),
			session: session
		)
		try? await Task.sleep(nanoseconds: 1_200_000_000)

		let parsed = BashToolResultParser.parse(
			raw: session.items.first?.toolResultJSON,
			argsJSON: session.items.first?.toolArgsJSON
		)
		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "completed")
		XCTAssertTrue(parsed.output?.contains("done") == true)
		XCTAssertFalse(parsed.output?.contains("late output") == true)
		XCTAssertEqual(session.items.first?.toolIsError, false)
		XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
	}

	func testCoordinatorAppliesMirroredBashFixtureWithoutDuplicateOutput() async throws {
		let coordinator = makeCoordinatorForTeardownTests()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		let events = try await collectControllerEventsFromFixture(
			named: "codexlogs-live-bash-test-1-mirrored-deltas.jsonl",
			threadID: "019c81fc-a7bd-7ce1-abe1-cfc05f6bb895",
			expectedCount: 11
		)
		await coordinator.test_handleCodexNativeEvent(.turnStarted(turnID: nil), session: session)
		for event in events {
			await coordinator.test_handleCodexNativeEvent(event, session: session)
		}
		try? await Task.sleep(nanoseconds: 1_200_000_000)

		let bashItems = session.items.filter { $0.toolName == "bash" }
		XCTAssertEqual(bashItems.count, 1)
		let liveExecution = try XCTUnwrap(session.bashLiveExecutionByKey.values.first)
		let parsed = liveExecution.parsedResult
		XCTAssertTrue(parsed.isRunning)
		XCTAssertEqual(parsed.processID, "47551")
		XCTAssertEqual(liveExecution.transcriptItemID, bashItems.first?.id)
		let output = try XCTUnwrap(parsed.output)
		XCTAssertEqual(output.components(separatedBy: "stdout line 2").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stderr line 2").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stdout line 3").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stdout line 4").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stderr line 4").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stdout line 5").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "bash-test-1: done").count - 1, 1)
	}

	func testCoordinatorDoesNotReopenTerminalSessionScopedBashFromRawMCPFixture() async throws {
		let coordinator = makeCoordinatorForTeardownTests()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running
		let failed = #"{"type":"commandExecution","status":"failed","exitCode":1,"processId":"session:27588","command":"npm start"}"#
		session.items = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: failed,
				isError: true,
				sequenceIndex: 0
			)
		]

		let events = try await collectControllerEventsFromFixture(
			named: "codexlogs-write-stdin-running.jsonl",
			threadID: "thread-1",
			expectedCount: 3
		)
		for event in events {
			await coordinator.test_handleCodexNativeEvent(event, session: session)
		}
		try? await Task.sleep(nanoseconds: 300_000_000)

		let bashItem = try XCTUnwrap(session.items.first)
		let parsed = BashToolResultParser.parse(raw: bashItem.toolResultJSON, argsJSON: bashItem.toolArgsJSON)
		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "failed")
		XCTAssertEqual(parsed.exitCode, 1)
		XCTAssertEqual(parsed.processID, "session:27588")
		XCTAssertEqual(bashItem.toolIsError, true)
		XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
	}

	func testNewBashProcessWithSameArgsDoesNotMergeIntoOldTerminalResult() async throws {
		let coordinator = makeCoordinatorForTeardownTests()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running
		let argsJSON = #"{"command":"npm test"}"#
		let oldTerminalJSON = #"{"type":"commandExecution","status":"failed","exitCode":1,"processId":"111","command":"npm test","aggregatedOutput":"old failure\n"}"#
		session.items = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: oldTerminalJSON,
				isError: true,
				sequenceIndex: 0
			)
		]
		session.items[0].toolArgsJSON = argsJSON

		await coordinator.test_handleCodexNativeEvent(
			.toolResult(
				name: "bash",
				invocationID: nil,
				argsJSON: argsJSON,
				resultJSON: #"{"type":"commandExecution","status":"running","processId":"222","command":"npm test","aggregatedOutput":"new run output\n"}"#,
				isError: false
			),
			session: session
		)

		XCTAssertEqual(session.items.count, 2)
		let oldItem = try XCTUnwrap(session.items.first)
		let oldParsed = BashToolResultParser.parse(raw: oldItem.toolResultJSON, argsJSON: oldItem.toolArgsJSON)
		XCTAssertFalse(oldParsed.isRunning)
		XCTAssertEqual(oldParsed.processID, "111")
		XCTAssertFalse(oldParsed.output?.contains("new run output") == true)
		XCTAssertEqual(oldItem.toolIsError, true)

		let liveExecution = try XCTUnwrap(session.bashLiveExecutionByKey.values.first)
		let liveParsed = liveExecution.parsedResult
		XCTAssertTrue(liveParsed.isRunning)
		XCTAssertEqual(liveParsed.processID, "222")
	}

	func testTerminalBashResultFlushesPendingCommandRunningOutputBeforeFinalization() async throws {
		let coordinator = makeCoordinatorForTeardownTests()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running
		let argsJSON = #"{"command":"echo done"}"#
		let invocationID = UUID()

		await coordinator.test_handleCodexNativeEvent(
			.toolCall(name: "bash", invocationID: invocationID, argsJSON: argsJSON),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(.init(
				invocationID: invocationID,
				processID: "123",
				appendedOutput: "pending chunk\n"
			)),
			session: session
		)
		XCTAssertFalse(session.pendingCommandRunningByKey.isEmpty)

		await coordinator.test_handleCodexNativeEvent(
			.toolResult(
				name: "bash",
				invocationID: invocationID,
				argsJSON: argsJSON,
				resultJSON: #"{"type":"commandExecution","status":"completed","exitCode":0,"processId":"123","command":"echo done"}"#,
				isError: false
			),
			session: session
		)

		XCTAssertTrue(session.pendingCommandRunningByKey.isEmpty)
		XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
		let bashItem = try XCTUnwrap(session.items.last(where: { $0.toolName == "bash" }))
		let parsed = BashToolResultParser.parse(raw: bashItem.toolResultJSON, argsJSON: bashItem.toolArgsJSON)
		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "completed")
		XCTAssertTrue(parsed.output?.contains("pending chunk") == true)
	}

	func testInactiveCommandRunningOutputWithoutAnchorCreatesMinimalAnchorOnly() async throws {
		let vm = makeViewModelForCommandRunningTests()
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		vm.test_setCurrentTabIDOverride(activeTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		_ = await vm.ensureSessionReady(tabID: activeTabID)
		let session = await vm.ensureSessionReady(tabID: inactiveTabID)
		session.selectedAgent = .codexExec
		session.runState = .running
		let invocationID = UUID()

		await vm.test_codexCoordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(.init(
				invocationID: invocationID,
				processID: "inactive-123",
				appendedOutput: "inactive first chunk\n"
			)),
			session: session
		)

		let didCaptureLiveOutput = await waitForCondition(timeoutSeconds: 1.0) {
			session.bashLiveExecutionByKey.values.first?.parsedResult.output?.contains("inactive first chunk") == true
		}
		XCTAssertTrue(didCaptureLiveOutput)
		let bashItem = try XCTUnwrap(session.items.first(where: { $0.toolName == "bash" }))
		XCTAssertFalse(bashItem.toolResultJSON?.contains("inactive first chunk") == true)
		XCTAssertFalse(bashItem.text.contains("inactive first chunk"))
	}

	func testInactiveCommandRunningOutputDoesNotRewriteExistingAnchorJSON() async throws {
		let vm = makeViewModelForCommandRunningTests()
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		vm.test_setCurrentTabIDOverride(activeTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		_ = await vm.ensureSessionReady(tabID: activeTabID)
		let session = await vm.ensureSessionReady(tabID: inactiveTabID)
		session.selectedAgent = .codexExec
		session.runState = .running
		let invocationID = UUID()
		let argsJSON = #"{"command":"echo inactive"}"#

		await vm.test_codexCoordinator.test_handleCodexNativeEvent(
			.toolCall(name: "bash", invocationID: invocationID, argsJSON: argsJSON),
			session: session
		)
		let anchoredItem = try XCTUnwrap(session.items.first(where: { $0.toolName == "bash" }))
		let anchoredJSON = try XCTUnwrap(anchoredItem.toolResultJSON)
		let anchoredText = anchoredItem.text

		await vm.test_codexCoordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(.init(
				invocationID: invocationID,
				processID: "inactive-456",
				appendedOutput: "inactive appended chunk\n"
			)),
			session: session
		)

		let didCaptureLiveOutput = await waitForCondition(timeoutSeconds: 1.0) {
			session.bashLiveExecutionByKey.values.first?.parsedResult.output?.contains("inactive appended chunk") == true
		}
		XCTAssertTrue(didCaptureLiveOutput)
		let updatedItem = try XCTUnwrap(session.items.first(where: { $0.id == anchoredItem.id }))
		XCTAssertEqual(updatedItem.toolResultJSON, anchoredJSON)
		XCTAssertEqual(updatedItem.text, anchoredText)
	}

	func testActiveCommandRunningOutputStillMaterializesIntoTranscriptJSON() async throws {
		let vm = makeViewModelForCommandRunningTests()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running
		let invocationID = UUID()

		await vm.test_codexCoordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(.init(
				invocationID: invocationID,
				processID: "active-123",
				appendedOutput: "active chunk\n"
			)),
			session: session
		)

		let didMaterialize = await waitForCondition(timeoutSeconds: 1.0) {
			session.items.first(where: { $0.toolName == "bash" })?.toolResultJSON?.contains("active chunk") == true
		}
		XCTAssertTrue(didMaterialize)
		let bashItem = try XCTUnwrap(session.items.first(where: { $0.toolName == "bash" }))
		let parsed = BashToolResultParser.parse(raw: bashItem.toolResultJSON, argsJSON: bashItem.toolArgsJSON)
		XCTAssertTrue(parsed.isRunning)
		XCTAssertTrue(parsed.output?.contains("active chunk") == true)
	}

	func testInactiveTerminalBashResultMergesPendingRunningOutput() async throws {
		let vm = makeViewModelForCommandRunningTests()
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		vm.test_setCurrentTabIDOverride(activeTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		_ = await vm.ensureSessionReady(tabID: activeTabID)
		let session = await vm.ensureSessionReady(tabID: inactiveTabID)
		session.selectedAgent = .codexExec
		session.runState = .running
		let argsJSON = #"{"command":"echo final"}"#
		let invocationID = UUID()

		await vm.test_codexCoordinator.test_handleCodexNativeEvent(
			.toolCall(name: "bash", invocationID: invocationID, argsJSON: argsJSON),
			session: session
		)
		await vm.test_codexCoordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(.init(
				invocationID: invocationID,
				processID: "inactive-final-123",
				appendedOutput: "inactive pending chunk\n"
			)),
			session: session
		)
		XCTAssertFalse(session.pendingCommandRunningByKey.isEmpty)

		await vm.test_codexCoordinator.test_handleCodexNativeEvent(
			.toolResult(
				name: "bash",
				invocationID: invocationID,
				argsJSON: argsJSON,
				resultJSON: #"{"type":"commandExecution","status":"completed","exitCode":0,"processId":"inactive-final-123","command":"echo final"}"#,
				isError: false
			),
			session: session
		)

		XCTAssertTrue(session.pendingCommandRunningByKey.isEmpty)
		XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
		let bashItem = try XCTUnwrap(session.items.last(where: { $0.toolName == "bash" }))
		let parsed = BashToolResultParser.parse(raw: bashItem.toolResultJSON, argsJSON: bashItem.toolArgsJSON)
		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "completed")
		XCTAssertTrue(parsed.output?.contains("inactive pending chunk") == true)
	}

	func testInactiveLateCommandRunningOutputDoesNotReviveTerminalBashResult() async throws {
		let vm = makeViewModelForCommandRunningTests()
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		vm.test_setCurrentTabIDOverride(activeTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		_ = await vm.ensureSessionReady(tabID: activeTabID)
		let session = await vm.ensureSessionReady(tabID: inactiveTabID)
		session.selectedAgent = .codexExec
		session.runState = .running
		let invocationID = UUID()
		let completed = #"{"type":"commandExecution","status":"completed","exitCode":0,"command":"echo done","aggregatedOutput":"done\n"}"#
		session.items = [
			.toolResult(
				name: "bash",
				invocationID: invocationID,
				resultJSON: completed,
				isError: false,
				sequenceIndex: 0
			)
		]

		await vm.test_codexCoordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(.init(
				invocationID: invocationID,
				processID: nil,
				appendedOutput: "late inactive output\n"
			)),
			session: session
		)
		try? await Task.sleep(nanoseconds: 300_000_000)

		let bashItem = try XCTUnwrap(session.items.first)
		let parsed = BashToolResultParser.parse(raw: bashItem.toolResultJSON, argsJSON: bashItem.toolArgsJSON)
		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "completed")
		XCTAssertTrue(parsed.output?.contains("done") == true)
		XCTAssertFalse(parsed.output?.contains("late inactive output") == true)
		XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
	}

	func testRunningBashToolResultDoesNotReviveTerminalBashResult() async throws {
		let coordinator = makeCoordinatorForTeardownTests()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running
		let invocationID = UUID()
		let completed = #"{"type":"commandExecution","status":"completed","exitCode":0,"command":"echo done","aggregatedOutput":"done\n"}"#
		session.items = [
			.toolResult(
				name: "bash",
				invocationID: invocationID,
				resultJSON: completed,
				isError: false,
				sequenceIndex: 0
			)
		]

		await coordinator.test_handleCodexNativeEvent(
			.toolResult(
				name: "bash",
				invocationID: invocationID,
				argsJSON: #"{"command":"echo done"}"#,
				resultJSON: #"{"type":"commandExecution","status":"running","command":"echo done","aggregatedOutput":"late running output\n"}"#,
				isError: false
			),
			session: session
		)

		let bashItem = try XCTUnwrap(session.items.first)
		let parsed = BashToolResultParser.parse(raw: bashItem.toolResultJSON, argsJSON: bashItem.toolArgsJSON)
		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "completed")
		XCTAssertTrue(parsed.output?.contains("done") == true)
		XCTAssertFalse(parsed.output?.contains("late running output") == true)
		XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
	}

	func testCompletedSessionCommandRunningWithoutAnchorDoesNotCreateBashItem() async {
		let coordinator = makeCoordinatorForTeardownTests()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .completed

		await coordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(.init(
				invocationID: UUID(),
				processID: "late-no-anchor",
				appendedOutput: "late output\n"
			)),
			session: session
		)
		try? await Task.sleep(nanoseconds: 300_000_000)

		XCTAssertTrue(session.items.isEmpty)
		XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)
		XCTAssertTrue(session.pendingCommandRunningByKey.isEmpty)
	}

	func testRetryWithoutResumeEnabledForMissingRolloutError() {
		let existingRef = CodexNativeSessionController.SessionRef(
			conversationID: "thread-1",
			rolloutPath: "/tmp/missing-rollout.jsonl",
			model: "gpt-5.2-codex",
			reasoningEffort: "medium"
		)
		let shouldRetry = CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
			existingRef: existingRef,
			errorDescription: "failed to load rollout '/tmp/missing-rollout.jsonl': No such file or directory (os error 2)"
		)

		XCTAssertTrue(shouldRetry)
	}

	func testRetryWithoutResumeDisabledForGenericResumeFailure() {
		let existingRef = CodexNativeSessionController.SessionRef(
			conversationID: "thread-1",
			rolloutPath: "/tmp/existing-rollout.jsonl",
			model: "gpt-5.2-codex",
			reasoningEffort: "medium"
		)
		let shouldRetry = CodexAgentModeCoordinator.test_shouldRetryCodexStartWithoutResume(
			existingRef: existingRef,
			errorDescription: "thread/resume failed: unauthorized"
		)

		XCTAssertFalse(shouldRetry)
	}

	func testClearCodexSessionStateCancelsEventAndToolTrackingHandles() async {
		let coordinator = makeCoordinatorForTeardownTests(shouldManageCodexTooling: true)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let controller = CoordinatorTestCodexController()
		let runID = UUID()
		await startCoordinatorOwnedToolTracking(coordinator: coordinator, session: session, runID: runID)
		let eventTask = Task<Void, Never> {
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}

		session.codexController = controller
		session.codexEventTask = eventTask
		session.runID = runID
		session.codexNeedsReconnect = true
		session.codexConversationID = "conversation"
		session.codexRolloutPath = "/tmp/rollout"

		let toolEventObserverCountBeforeClear = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
		let toolCallObserverCountBeforeClear = await ServerNetworkManager.shared.toolCallObserverCount(for: runID)
		XCTAssertEqual(toolEventObserverCountBeforeClear, 1)
		XCTAssertEqual(toolCallObserverCountBeforeClear, 0)

		coordinator.clearCodexSessionState(session)

		XCTAssertNil(session.codexController)
		XCTAssertNil(session.codexEventTask)
		XCTAssertTrue(eventTask.isCancelled)
		XCTAssertEqual(session.runID, runID)
		XCTAssertFalse(session.codexNeedsReconnect)
		XCTAssertNil(session.codexConversationID)
		XCTAssertNil(session.codexRolloutPath)

		let didShutdown = await waitForCondition(timeoutSeconds: 1.0) {
			controller.shutdownCallCount == 1
		}
		XCTAssertTrue(didShutdown)
		let observersCleared = await waitForCondition(timeoutSeconds: 1.0) {
			let toolEventCount = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
			let toolCallCount = await ServerNetworkManager.shared.toolCallObserverCount(for: runID)
			return toolEventCount == 0 && toolCallCount == 0
		}
		XCTAssertTrue(observersCleared)
	}

	func testProviderSwitchAwayFromCodexCancelsEventAndToolTrackingHandles() async {
		let coordinator = makeCoordinatorForTeardownTests(shouldManageCodexTooling: true)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let controller = CoordinatorTestCodexController()
		let runID = UUID()
		await startCoordinatorOwnedToolTracking(coordinator: coordinator, session: session, runID: runID)
		let eventTask = Task<Void, Never> {
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}

		session.codexController = controller
		session.codexEventTask = eventTask
		session.runID = runID
		session.codexNeedsReconnect = true
		session.codexConversationID = "conversation"
		session.codexRolloutPath = "/tmp/rollout"
		session.codexContextUsage = AgentContextUsage(modelContextWindow: 10, lastTotalTokens: 2, totalTotalTokens: 2)
		session.codexModel = "gpt-5"
		session.codexReasoningEffort = "medium"

		let toolEventObserverCountBeforeSwitch = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
		let toolCallObserverCountBeforeSwitch = await ServerNetworkManager.shared.toolCallObserverCount(for: runID)
		XCTAssertEqual(toolEventObserverCountBeforeSwitch, 1)
		XCTAssertEqual(toolCallObserverCountBeforeSwitch, 0)

		coordinator.handleProviderSwitch(from: .codexExec, to: .claudeCode, session: session)

		XCTAssertNil(session.codexController)
		XCTAssertNil(session.codexEventTask)
		XCTAssertTrue(eventTask.isCancelled)
		XCTAssertEqual(session.runID, runID)
		XCTAssertFalse(session.codexNeedsReconnect)
		XCTAssertNil(session.codexConversationID)
		XCTAssertNil(session.codexRolloutPath)
		XCTAssertNil(session.codexContextUsage)
		XCTAssertNil(session.codexModel)
		XCTAssertNil(session.codexReasoningEffort)

		let didShutdown = await waitForCondition(timeoutSeconds: 1.0) {
			controller.shutdownCallCount == 1
		}
		XCTAssertTrue(didShutdown)
		let observersCleared = await waitForCondition(timeoutSeconds: 1.0) {
			let toolEventCount = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
			let toolCallCount = await ServerNetworkManager.shared.toolCallObserverCount(for: runID)
			return toolEventCount == 0 && toolCallCount == 0
		}
		XCTAssertTrue(observersCleared)
	}

	func testHandleToolPreferencesChangedClearsTrackerReferenceAndObservers() async {
		let coordinator = makeCoordinatorForTeardownTests(shouldManageCodexTooling: true)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let runID = UUID()
		await startCoordinatorOwnedToolTracking(coordinator: coordinator, session: session, runID: runID)

		session.selectedAgent = .codexExec
		session.runID = runID
		session.runState = .idle
		let toolEventObserverCountBeforePreferenceChange = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
		let toolCallObserverCountBeforePreferenceChange = await ServerNetworkManager.shared.toolCallObserverCount(for: runID)
		XCTAssertEqual(toolEventObserverCountBeforePreferenceChange, 1)
		XCTAssertEqual(toolCallObserverCountBeforePreferenceChange, 0)

		coordinator.handleToolPreferencesChanged(for: session)

		XCTAssertTrue(session.codexNeedsReconnect)
		let observersCleared = await waitForCondition(timeoutSeconds: 1.0) {
			let toolEventCount = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
			let toolCallCount = await ServerNetworkManager.shared.toolCallObserverCount(for: runID)
			return toolEventCount == 0 && toolCallCount == 0
		}
		XCTAssertTrue(observersCleared)
	}

	private func collectControllerEventsFromFixture(
		named fixtureName: String,
		threadID: String,
		expectedCount: Int
	) async throws -> [CodexNativeSessionController.Event] {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = CoordinatorEventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		try await bufferFixtureNotifications(named: fixtureName, into: controller)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": threadID, "turns": []]],
			fallbackEffort: nil
		)
		let drained = await waitForCondition(timeoutSeconds: 1.0) {
			await recorder.count == expectedCount
		}
		XCTAssertTrue(drained)
		return await recorder.snapshot()
	}

	private func bufferFixtureNotifications(
		named fixtureName: String,
		into controller: CodexNativeSessionController
	) async throws {
		let fixtureURL = codexSessionFixtureURL(named: fixtureName)
		let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
		for rawLine in contents.split(whereSeparator: \.isNewline) {
			let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !line.isEmpty else { continue }
			let data = try XCTUnwrap(line.data(using: .utf8))
			let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
			let method = try XCTUnwrap(object["method"] as? String)
			let payload = try XCTUnwrap(object["payload"] as? [String: Any])
			await controller.test_bufferNotificationDuringBinding(
				.init(method: method, params: codexJSONDictionary(from: payload))
			)
		}
	}

	private func codexSessionFixtureURL(named fixtureName: String) -> URL {
		let testFileURL = URL(fileURLWithPath: #filePath, isDirectory: false)
		return testFileURL
			.deletingLastPathComponent()
			.appendingPathComponent("Fixtures")
			.appendingPathComponent("CodexSessions")
			.appendingPathComponent(fixtureName)
	}

	private func codexJSONDictionary(from value: [String: Any]) -> [String: CodexJSONValue] {
		var output: [String: CodexJSONValue] = [:]
		for (key, rawValue) in value {
			if let converted = CodexJSONValue.from(rawValue) {
				output[key] = converted
			}
		}
		return output
	}

	private func startCoordinatorOwnedToolTracking(
		coordinator: CodexAgentModeCoordinator,
		session: AgentModeViewModel.TabSession,
		runID: UUID
	) async {
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
		await coordinator.ensureCodexToolTrackingIfNeeded(for: session, runID: runID)
		let registered = await waitForCondition(timeoutSeconds: 1.0) {
			await ServerNetworkManager.shared.toolEventObserverCount(for: runID) == 1
		}
		XCTAssertTrue(registered)
	}

	// MARK: - apply_patch terminal regression guard tests

	func testApplyPatchTerminalResultNotOverwrittenByRunningPayload() async {
		let coordinator = makeCoordinatorForTeardownTests()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running
		let invocationID = UUID()
		let terminalJSON = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":""}],"change_count":1}"#
		session.items = [
			.toolResult(
				name: "apply_patch",
				invocationID: invocationID,
				resultJSON: terminalJSON,
				isError: false,
				sequenceIndex: 0
			)
		]

		// Deliver a running payload for the same invocationID — should be ignored.
		let runningJSON = #"{"status":"running","changes":[],"change_count":0}"#
		await coordinator.test_handleCodexNativeEvent(
			.toolResult(
				name: "apply_patch",
				invocationID: invocationID,
				argsJSON: nil,
				resultJSON: runningJSON,
				isError: false
			),
			session: session
		)

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.first?.toolResultJSON, terminalJSON,
			"Terminal apply_patch result should not be overwritten by a running payload")
		XCTAssertEqual(session.items.first?.toolIsError, false)
	}

	func testApplyPatchRunningResultTransitionsToTerminal() async {
		let coordinator = makeCoordinatorForTeardownTests()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running
		let invocationID = UUID()
		let runningJSON = #"{"status":"running","changes":[],"change_count":0}"#
		session.items = [
			.toolResult(
				name: "apply_patch",
				invocationID: invocationID,
				resultJSON: runningJSON,
				isError: false,
				sequenceIndex: 0
			)
		]

		// Deliver a terminal payload — should be accepted.
		let terminalJSON = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":""}],"change_count":1}"#
		await coordinator.test_handleCodexNativeEvent(
			.toolResult(
				name: "apply_patch",
				invocationID: invocationID,
				argsJSON: nil,
				resultJSON: terminalJSON,
				isError: false
			),
			session: session
		)

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.first?.toolResultJSON, terminalJSON,
			"Running apply_patch result should be replaced by a terminal payload")
	}

	private func makeViewModelForCommandRunningTests() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			CoordinatorTestCodexController()
		}
	}

	private func makeCoordinatorForTeardownTests(shouldManageCodexTooling: Bool = false) -> CodexAgentModeCoordinator {
		CodexAgentModeCoordinator(
			windowID: 1,
			workspacePathProvider: { nil },
			codexControllerFactory: { _, _, _, _, _, _, _ in CoordinatorTestCodexController() },
			connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
			shouldManageCodexTooling: shouldManageCodexTooling
		)
	}

	private func waitForCondition(
		timeoutSeconds: TimeInterval,
		condition: @escaping () async -> Bool
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeoutSeconds)
		while Date() < deadline {
			if await condition() {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return await condition()
	}
}

private actor CoordinatorEventRecorder {
	private var events: [CodexNativeSessionController.Event] = []

	func record(_ event: CodexNativeSessionController.Event) {
		events.append(event)
	}

	var count: Int {
		events.count
	}

	func snapshot() -> [CodexNativeSessionController.Event] {
		events
	}
}

private final class CoordinatorTestCodexController: CodexSessionControlling {
	private var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
	private let stream: AsyncStream<CodexNativeSessionController.Event>
	private(set) var shutdownCallCount = 0

	var hasActiveThread: Bool {
		false
	}

	var events: AsyncStream<CodexNativeSessionController.Event> {
		stream
	}

	init() {
		var continuationRef: AsyncStream<CodexNativeSessionController.Event>.Continuation?
		stream = AsyncStream { continuation in
			continuationRef = continuation
		}
		continuation = continuationRef
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(conversationID: "", rolloutPath: nil, model: nil, reasoningEffort: nil)
	}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String,
		model: String?,
		reasoningEffort: String?
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(conversationID: "", rolloutPath: nil, model: nil, reasoningEffort: nil)
	}

	func sendUserMessage(_ text: String) async throws {}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}

	func sendUserTurn(
		text: String,
		images: [AgentImageAttachment],
		model: String?,
		reasoningEffort: String?
	) async throws {}

	func cancelCurrentTurn() async {}

	func shutdown() async {
		shutdownCallCount += 1
		continuation?.finish()
	}

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
