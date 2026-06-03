import XCTest
import MCP
@testable import RepoPrompt

@MainActor
final class CodexAgentModeCoordinatorGoalTrackingTests: XCTestCase {
	override func tearDown() async throws {
		CodexGoalSupport.setEnabledForTesting(nil)
		try await super.tearDown()
	}

	func testGoalCommandRegistersAndUsesTrackerThroughSessionReadiness() async throws {
		CodexGoalSupport.setEnabledForTesting(true)
		let controller = GoalTrackingCodexController()
		let coordinator = makeCoordinator(controller: controller)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec

		let result = await coordinator.executeNativeSlashCommand(
			.goal,
			argumentsText: "keep improving tracker coverage",
			session: session
		)

		XCTAssertEqual(result, .succeeded("Set Codex goal: keep improving tracker coverage"))
		XCTAssertEqual(controller.setGoalObjectives, ["keep improving tracker coverage"])
		let runID = try XCTUnwrap(session.runID)
		let observerCountAfterGoal = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
		XCTAssertEqual(
			observerCountAfterGoal,
			1,
			"/goal readiness should await tracker observer registration before returning."
		)

		let invocationID = UUID()
		let toolName = "mcp__RepoPrompt__read_file"
		let delivered = await ServerNetworkManager.shared.debugFireToolCalledObservers(
			runID: runID,
			invocationID: invocationID,
			toolName: toolName,
			args: ["path": .string("README.md")]
		)
		XCTAssertEqual(delivered, 1)

		let renderedToolCall = await waitForCondition(timeoutSeconds: 1.0) {
			session.items.contains { item in
				item.kind == .toolCall
					&& item.toolInvocationID == invocationID
					&& item.toolName == toolName
			}
		}
		XCTAssertTrue(renderedToolCall, "The /goal-created readiness tracker should deliver RepoPrompt tool callbacks into the transcript.")

		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
	}

	func testSendRegistersTrackerBeforeControllerSendThroughSessionReadiness() async throws {
		let controller = GoalTrackingCodexController()
		let coordinator = makeCoordinator(controller: controller)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec

		let outcome = await coordinator.sendCodexNativeMessage(
			session: session,
			text: "hello",
			attachments: [],
			policyAlreadyInstalled: true
		)

		XCTAssertEqual(outcome, .sent)
		let runID = try XCTUnwrap(session.runID)
		XCTAssertEqual(controller.sendTurnObserverCounts, [1])
		let observerCountAfterSend = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
		XCTAssertEqual(
			observerCountAfterSend,
			1,
			"Normal sends should also rely on readiness-bound tracker setup."
		)

		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
	}

	func testDeferredReconnectReadinessRegistersTrackerForActiveController() async throws {
		let controller = GoalTrackingCodexController(active: true)
		let coordinator = makeCoordinator(controller: controller)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let runID = UUID()
		session.selectedAgent = .codexExec
		session.runID = runID
		session.runState = .running
		session.codexController = controller
		session.codexNeedsReconnect = true
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)

		await coordinator.ensureCodexNativeSession(
			session: session,
			deferReconnectForCurrentActiveTurn: true
		)

		XCTAssertTrue(session.codexNeedsReconnect, "Deferred readiness should leave reconnect requested for the later idle boundary.")
		XCTAssertTrue(controller.hasActiveThread)
		let observerCount = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
		XCTAssertEqual(observerCount, 1)

		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
	}

	private func makeCoordinator(controller: GoalTrackingCodexController) -> CodexAgentModeCoordinator {
		CodexAgentModeCoordinator(
			windowID: 1,
			workspacePathProvider: { nil },
			codexControllerFactory: { runID, _, _, _, _, _, _ in
				controller.runID = runID
				return controller
			},
			connectionPolicyInstaller: { _, _, _, _, _, _, _, runID, _, _, _, _, _ in
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			},
			shouldManageCodexTooling: true,
			initialLastUsedReasoningEffort: nil
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

private final class GoalTrackingCodexController: CodexSessionControlling {
	var runID: UUID?
	private(set) var isActiveThread = false
	private(set) var setGoalObjectives: [String] = []
	private(set) var sendTurnObserverCounts: [Int] = []

	init(active: Bool = false) {
		isActiveThread = active
	}

	var hasActiveThread: Bool { isActiveThread }

	var events: AsyncStream<CodexNativeSessionController.Event> {
		AsyncStream { _ in }
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		isActiveThread = true
		return CodexNativeSessionController.SessionRef(
			conversationID: existing?.conversationID.isEmpty == false ? existing?.conversationID ?? "thread-goal" : "thread-goal",
			rolloutPath: existing?.rolloutPath,
			model: existing?.model,
			reasoningEffort: existing?.reasoningEffort
		)
	}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String,
		model: String?,
		reasoningEffort: String?
	) async throws -> CodexNativeSessionController.SessionRef {
		isActiveThread = true
		return CodexNativeSessionController.SessionRef(
			conversationID: existing?.conversationID.isEmpty == false ? existing?.conversationID ?? "thread-goal" : "thread-goal",
			rolloutPath: existing?.rolloutPath,
			model: model ?? existing?.model,
			reasoningEffort: reasoningEffort ?? existing?.reasoningEffort
		)
	}

	func sendUserMessage(_ text: String) async throws {}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}

	func sendUserTurn(
		text: String,
		images: [AgentImageAttachment],
		model: String?,
		reasoningEffort: String?
	) async throws {
		if let runID {
			let count = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
			await MainActor.run {
				sendTurnObserverCounts.append(count)
			}
		}
	}

	func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
		setGoalObjectives.append(objective)
		return CodexNativeSessionController.ThreadGoal(
			threadID: "thread-goal",
			objective: objective,
			status: .active,
			tokenBudget: nil,
			tokensUsed: 0,
			timeUsedSeconds: 0,
			createdAt: 0,
			updatedAt: 0
		)
	}

	func cancelCurrentTurn() async {}

	func shutdown() async {}

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
