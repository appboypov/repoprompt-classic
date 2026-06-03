import XCTest
@testable import RepoPrompt

final class CodexCLIProviderTests: XCTestCase {
	func testStreamMessageYieldsReasoningContentAndMessageStop() async throws {
		let factory = MockControllerFactory(
			scripts: [[
				.turnStarted(turnID: nil),
				.reasoningDelta(.init(text: "thinking", kind: .summary, itemID: "reasoning-1", groupID: "reasoning-1", index: 0)),
				.assistantDelta("hello"),
				.turnCompleted(turnID: nil, status: .completed)
			]]
		)
		let provider = makeProvider(factory: factory)
		let systemPrompt = "You are RepoPrompt system prompt"

		let stream = try await provider.streamMessage(
			AIMessage(systemPrompt: systemPrompt, userMessage: "say hello"),
			model: .codexCliGpt5Medium
		)
		let results = try await collect(stream)

		XCTAssertEqual(results.map(\.type), ["reasoning", "content", "message_stop"])
		XCTAssertEqual(results.first?.reasoning, "thinking")
		XCTAssertEqual(results.dropFirst().first?.text, "hello")

		let controller = try XCTUnwrap(factory.createdControllers().first)
		let startCall = try XCTUnwrap(controller.startCalls().first)
		let sendCall = try XCTUnwrap(controller.sendCalls().first)
		let model = AIModel.codexCliGpt5Medium
		let specifier = CodexModelSpecifier(raw: model.modelName)
		let expectedEffort = specifier.appServerEffortParam ?? model.defaultReasoningEffort

		XCTAssertNil(startCall.existing)
		XCTAssertEqual(startCall.baseInstructions, systemPrompt)
		XCTAssertEqual(startCall.model, specifier.appServerModelParam)
		XCTAssertEqual(startCall.reasoningEffort, expectedEffort)
		XCTAssertEqual(sendCall.model, specifier.appServerModelParam)
		XCTAssertEqual(sendCall.reasoningEffort, expectedEffort)
		XCTAssertTrue(sendCall.text.contains("say hello"))
		XCTAssertFalse(sendCall.text.contains(systemPrompt))
	}

	func testStreamMessageEmitsStatusForReconnectingErrorAndContinues() async throws {
		let factory = MockControllerFactory(
			scripts: [[
				.turnStarted(turnID: nil),
				.error("Reconnecting... 1/5"),
				.assistantDelta("hello after reconnect"),
				.turnCompleted(turnID: nil, status: .completed)
			]]
		)
		let provider = makeProvider(factory: factory)

		let stream = try await provider.streamMessage(
			AIMessage(systemPrompt: "", userMessage: "test"),
			model: .codexCliGpt5Low
		)
		let results = try await collect(stream)

		XCTAssertEqual(results.map(\.type), ["status", "content", "message_stop"])
		XCTAssertEqual(results.first?.text, "Reconnecting... 1/5")
		XCTAssertEqual(results.dropFirst().first?.text, "hello after reconnect")
	}

	func testCompleteMessageIgnoresReconnectingErrorEvent() async throws {
		let factory = MockControllerFactory(
			scripts: [[
				.turnStarted(turnID: nil),
				.error("Reconnecting... 1/5"),
				.assistantDelta("final answer"),
				.turnCompleted(turnID: nil, status: .completed)
			]]
		)
		let provider = makeProvider(factory: factory)

		let completion = try await provider.completeMessage(
			AIMessage(systemPrompt: "", userMessage: "test"),
			model: .codexCliGpt5Low
		)

		XCTAssertEqual(completion.text, "final answer")
	}

	func testCompleteMessagePassesSystemPromptAsBaseInstructions() async throws {
		let factory = MockControllerFactory(
			scripts: [[
				.assistantDelta("done"),
				.turnCompleted(turnID: nil, status: .completed)
			]]
		)
		let provider = makeProvider(factory: factory)
		let systemPrompt = "Complete-message system prompt"

		let completion = try await provider.completeMessage(
			AIMessage(systemPrompt: systemPrompt, userMessage: "test"),
			model: .codexCliGpt5Low
		)

		XCTAssertEqual(completion.text, "done")
		let controller = try XCTUnwrap(factory.createdControllers().first)
		let startCall = try XCTUnwrap(controller.startCalls().first)
		let sendCall = try XCTUnwrap(controller.sendCalls().first)
		XCTAssertEqual(startCall.baseInstructions, systemPrompt)
		XCTAssertFalse(sendCall.text.contains(systemPrompt))
	}

	func testStreamMessageRetriesRecoverableServerRequestIssueAfterManagedAuthRefresh() async throws {
		let issue = CodexNativeSessionController.ServerRequestIssue(
			requestID: .string("refresh-1"),
			method: "account/chatgptAuthTokens/refresh",
			kind: .authTokensRefreshUnavailable,
			message: "Codex requested account/chatgptAuthTokens/refresh, but RepoPrompt is not managing external Codex ChatGPT auth tokens. Reconnect Codex authentication and retry."
		)
		let factory = MockControllerFactory(
			scripts: [
				[.serverRequestIssue(issue)],
				[
					.assistantDelta("after refresh"),
					.turnCompleted(turnID: nil, status: .completed)
				]
			]
		)
		let authRecovery = MockCodexAuthRecovery(refreshResults: [.recovered])
		let provider = makeProvider(factory: factory, authRecovery: authRecovery)

		let stream = try await provider.streamMessage(
			AIMessage(systemPrompt: "", userMessage: "test"),
			model: .codexCliGpt5Low
		)
		let results = try await collect(stream)

		XCTAssertEqual(results.map(\.type), ["content", "message_stop"])
		XCTAssertEqual(results.first?.text, "after refresh")
		let refreshCallCount = await authRecovery.refreshCallCount()
		XCTAssertEqual(refreshCallCount, 1)
		XCTAssertEqual(factory.createdControllers().count, 2)
	}

	func testStreamMessageFailsWithManualLoginGuidanceWhenManagedAuthRefreshRequiresUserLogin() async {
		let issue = CodexNativeSessionController.ServerRequestIssue(
			requestID: .string("refresh-1"),
			method: "account/chatgptAuthTokens/refresh",
			kind: .authTokensRefreshUnavailable,
			message: "Codex requested account/chatgptAuthTokens/refresh, but RepoPrompt is not managing external Codex ChatGPT auth tokens. Reconnect Codex authentication and retry."
		)
		let factory = MockControllerFactory(
			scripts: [[.serverRequestIssue(issue)]]
		)
		let authRecovery = MockCodexAuthRecovery(
			refreshResults: [.requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)]
		)
		let provider = makeProvider(factory: factory, authRecovery: authRecovery)

		do {
			let stream = try await provider.streamMessage(
				AIMessage(systemPrompt: "", userMessage: "test"),
				model: .codexCliGpt5Low
			)
			_ = try await collect(stream)
			XCTFail("Expected manual login guidance failure")
		} catch let AIProviderError.invalidConfiguration(detail) {
			XCTAssertEqual(detail, CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
			let refreshCallCount = await authRecovery.refreshCallCount()
			XCTAssertEqual(refreshCallCount, 1)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testStreamMessageFailsWithExecutableUnavailableFromManagedAuthRefresh() async {
		let issue = CodexNativeSessionController.ServerRequestIssue(
			requestID: .string("refresh-1"),
			method: "account/chatgptAuthTokens/refresh",
			kind: .authTokensRefreshUnavailable,
			message: "Codex requested account/chatgptAuthTokens/refresh, but RepoPrompt is not managing external Codex ChatGPT auth tokens. Reconnect Codex authentication and retry."
		)
		let factory = MockControllerFactory(
			scripts: [[.serverRequestIssue(issue)]]
		)
		let executableMessage = "Codex CLI executable was not found. Install Codex CLI and ensure `codex` is available in your login shell PATH. RepoPrompt searched your login-shell PATH plus common Homebrew, npm/pnpm/yarn/Volta, Bun, Cargo, version-manager shim, and Codex.app locations."
		let authRecovery = MockCodexAuthRecovery(
			refreshResults: [.executableUnavailable(message: executableMessage)]
		)
		let provider = makeProvider(factory: factory, authRecovery: authRecovery)

		do {
			let stream = try await provider.streamMessage(
				AIMessage(systemPrompt: "", userMessage: "test"),
				model: .codexCliGpt5Low
			)
			_ = try await collect(stream)
			XCTFail("Expected executable-unavailable failure")
		} catch let AIProviderError.invalidConfiguration(detail) {
			XCTAssertEqual(detail, executableMessage)
			XCTAssertNotEqual(detail, CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
			let refreshCallCount = await authRecovery.refreshCallCount()
			XCTAssertEqual(refreshCallCount, 1)
			XCTAssertEqual(factory.createdControllers().count, 1, "Executable-unavailable auth recovery should not retry the turn")
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testTestConnectionFailsWithExecutableUnavailableFromAuthRecovery() async {
		let issue = CodexNativeSessionController.ServerRequestIssue(
			requestID: .string("refresh-1"),
			method: "account/chatgptAuthTokens/refresh",
			kind: .authTokensRefreshUnavailable,
			message: "Codex requested account/chatgptAuthTokens/refresh, but RepoPrompt is not managing external Codex ChatGPT auth tokens. Reconnect Codex authentication and retry."
		)
		let factory = MockControllerFactory(scripts: [[.serverRequestIssue(issue)]])
		let executableMessage = "Codex CLI resolved to `/missing/codex`, but that file does not exist. Reinstall Codex CLI or fix your shell PATH."
		let authRecovery = MockCodexAuthRecovery(
			refreshResults: [.executableUnavailable(message: executableMessage)]
		)
		let provider = makeProvider(factory: factory, authRecovery: authRecovery)

		do {
			_ = try await provider.testConnection(timeout: 5)
			XCTFail("Expected executable-unavailable failure")
		} catch let AIProviderError.invalidConfiguration(detail) {
			XCTAssertEqual(detail, executableMessage)
			XCTAssertNotEqual(detail, CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
			let refreshCallCount = await authRecovery.refreshCallCount()
			XCTAssertEqual(refreshCallCount, 1)
			XCTAssertEqual(factory.createdControllers().count, 1, "Executable-unavailable auth recovery should not retry the health check")
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testStreamMessageRetriesRawUnauthorizedResponsesErrorAfterManagedAuthRefresh() async throws {
		let factory = MockControllerFactory(
			scripts: [
				[
					.error("unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses")
				],
				[
					.assistantDelta("after refresh"),
					.turnCompleted(turnID: nil, status: .completed)
				]
			]
		)
		let authRecovery = MockCodexAuthRecovery(refreshResults: [.recovered])
		let provider = makeProvider(factory: factory, authRecovery: authRecovery)

		let stream = try await provider.streamMessage(
			AIMessage(systemPrompt: "", userMessage: "test"),
			model: .codexCliGpt5Low
		)
		let results = try await collect(stream)

		XCTAssertEqual(results.map(\.type), ["content", "message_stop"])
		XCTAssertEqual(results.first?.text, "after refresh")
		let refreshCallCount = await authRecovery.refreshCallCount()
		XCTAssertEqual(refreshCallCount, 1)
	}

	func testCompleteMessageFailsWithExactUnsupportedServerRequestIssueMessage() async {
		let issue = CodexNativeSessionController.ServerRequestIssue(
			requestID: .string("unsupported-1"),
			method: "workspace/unknownOperation",
			kind: .unsupportedMethod,
			message: "Unsupported Codex server request method: workspace/unknownOperation"
		)
		let factory = MockControllerFactory(
			scripts: [[
				.serverRequestIssue(issue)
			]]
		)
		let provider = makeProvider(factory: factory)

		do {
			_ = try await provider.completeMessage(
				AIMessage(systemPrompt: "", userMessage: "test"),
				model: .codexCliGpt5Low
			)
			XCTFail("Expected server request issue to fail completion")
		} catch let AIProviderError.invalidConfiguration(detail) {
			XCTAssertEqual(detail, issue.message)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testStreamMessageRejectsRequestUserInputOutsideAgentMode() async {
		let factory = MockControllerFactory(
			scripts: [[
				.requestUserInput(
					AgentRequestUserInputRequest(
						requestID: .string("rui-1"),
						method: "item/tool/requestUserInput",
						threadID: "thread-1",
						turnID: "turn-1",
						itemID: "item-1",
						questions: [
							.init(
								id: "q1",
								header: "Header",
								question: "What now?",
								isOther: false,
								isSecret: false,
								options: []
							)
						]
					)
				)
			]]
		)
		let provider = makeProvider(factory: factory)

		do {
			let stream = try await provider.streamMessage(
				AIMessage(systemPrompt: "", userMessage: "test"),
				model: .codexCliGpt5Low
			)
			_ = try await collect(stream)
			XCTFail("Expected request_user_input to fail for CodexCLIProvider")
		} catch let AIProviderError.invalidConfiguration(detail) {
			XCTAssertEqual(detail, "Codex request_user_input prompts require Agent Mode UI. Retry this action in Agent Mode.")
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testStreamMessageRejectsToolEvents() async {
		let factory = MockControllerFactory(
			scripts: [[
				.toolCall(name: "exec_command", invocationID: nil, argsJSON: "{}")
			]]
		)
		let provider = makeProvider(factory: factory)

		do {
			let stream = try await provider.streamMessage(
				AIMessage(systemPrompt: "", userMessage: "test"),
				model: .codexCliGpt5Low
			)
			_ = try await collect(stream)
			XCTFail("Expected tool event to fail for CodexCLIProvider")
		} catch let AIProviderError.invalidConfiguration(detail) {
			XCTAssertTrue(detail.localizedCaseInsensitiveContains("tool events"))
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testCompleteMessageStartsFreshThreadPerMessage() async throws {
		let factory = MockControllerFactory(
			scripts: [
				[
					.assistantDelta("first"),
					.turnCompleted(turnID: nil, status: .completed)
				],
				[
					.assistantDelta("second"),
					.turnCompleted(turnID: nil, status: .completed)
				]
			]
		)
		let provider = makeProvider(factory: factory)

		let first = try await provider.completeMessage(
			AIMessage(systemPrompt: "", userMessage: "message one"),
			model: .codexCliGpt5Low
		)
		let second = try await provider.completeMessage(
			AIMessage(systemPrompt: "", userMessage: "message two"),
			model: .codexCliGpt5Low
		)

		XCTAssertEqual(first.text, "first")
		XCTAssertEqual(second.text, "second")

		let controllers = factory.createdControllers()
		XCTAssertEqual(controllers.count, 2)
		for controller in controllers {
			let startCalls = controller.startCalls()
			XCTAssertEqual(startCalls.count, 1)
			XCTAssertNil(startCalls.first?.existing)
		}
	}

	private func makeProvider(
		factory: MockControllerFactory,
		authRecovery: any CodexManagedAuthRecovering = MockCodexAuthRecovery()
	) -> CodexCLIProvider {
		CodexCLIProvider(
			workingDirectory: "/tmp",
			defaultRequestTimeout: 5,
			maxRetries: 0,
			appServerReadyHook: {},
			authRecovery: authRecovery,
			sessionControllerFactory: { _, _ in
				factory.makeController()
			}
		)
	}

	private func collect(_ stream: AsyncThrowingStream<AIStreamResult, Error>) async throws -> [AIStreamResult] {
		var values: [AIStreamResult] = []
		for try await value in stream {
			values.append(value)
		}
		return values
	}
}

private struct MockStartCall {
	let existing: CodexNativeSessionController.SessionRef?
	let baseInstructions: String
	let model: String?
	let reasoningEffort: String?
}

private struct MockSendCall {
	let text: String
	let model: String?
	let reasoningEffort: String?
}

private actor MockCodexAuthRecovery: CodexManagedAuthRecovering {
	private var queuedRefreshResults: [CodexManagedAuthRefreshResult]
	private let loginResult: CodexManagedChatgptLoginResult
	private var recordedRefreshCallCount = 0

	init(
		refreshResults: [CodexManagedAuthRefreshResult] = [.requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)],
		loginResult: CodexManagedChatgptLoginResult = .failed(message: "unused")
	) {
		self.queuedRefreshResults = refreshResults
		self.loginResult = loginResult
	}

	func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
		recordedRefreshCallCount += 1
		if queuedRefreshResults.isEmpty {
			return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
		}
		return queuedRefreshResults.removeFirst()
	}

	func startManagedChatgptLogin(
		openURL: @MainActor @escaping @Sendable (URL) -> Void
	) async -> CodexManagedChatgptLoginResult {
		_ = openURL
		return loginResult
	}

	func refreshCallCount() -> Int {
		recordedRefreshCallCount
	}
}

private final class MockCodexSessionController: CodexSessionControlling {
	var hasActiveThread: Bool { true }
	var events: AsyncStream<CodexNativeSessionController.Event> { eventsStream }

	private let scriptedEvents: [CodexNativeSessionController.Event]
	private let eventsStream: AsyncStream<CodexNativeSessionController.Event>
	private var eventsContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
	private var recordedStartCalls: [MockStartCall] = []
	private var recordedSendCalls: [MockSendCall] = []

	init(scriptedEvents: [CodexNativeSessionController.Event]) {
		self.scriptedEvents = scriptedEvents
		var continuationRef: AsyncStream<CodexNativeSessionController.Event>.Continuation?
		self.eventsStream = AsyncStream { continuation in
			continuationRef = continuation
		}
		self.eventsContinuation = continuationRef
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		try await startOrResume(existing: existing, baseInstructions: baseInstructions, model: nil, reasoningEffort: nil)
	}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String,
		model: String?,
		reasoningEffort: String?
	) async throws -> CodexNativeSessionController.SessionRef {
		recordedStartCalls.append(MockStartCall(existing: existing, baseInstructions: baseInstructions, model: model, reasoningEffort: reasoningEffort))
		return CodexNativeSessionController.SessionRef(
			conversationID: "mock-thread",
			rolloutPath: nil,
			model: model,
			reasoningEffort: reasoningEffort
		)
	}

	func sendUserMessage(_ text: String) async throws {
		try await sendUserTurn(text: text, images: [], model: nil, reasoningEffort: nil)
	}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {
		try await sendUserTurn(text: text, images: images, model: nil, reasoningEffort: nil)
	}

	func sendUserTurn(
		text: String,
		images: [AgentImageAttachment],
		model: String?,
		reasoningEffort: String?
	) async throws {
		recordedSendCalls.append(MockSendCall(text: text, model: model, reasoningEffort: reasoningEffort))
		let continuation = eventsContinuation

		for event in scriptedEvents {
			continuation?.yield(event)
		}
		continuation?.finish()
	}

	func cancelCurrentTurn() async {
		eventsContinuation?.finish()
	}

	func shutdown() async {
		eventsContinuation?.finish()
	}

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}

	func startCalls() -> [MockStartCall] {
		recordedStartCalls
	}

	func sendCalls() -> [MockSendCall] {
		recordedSendCalls
	}
}

private final class MockControllerFactory {
	private let lock = NSLock()
	private var scripts: [[CodexNativeSessionController.Event]]
	private var controllers: [MockCodexSessionController] = []

	init(scripts: [[CodexNativeSessionController.Event]]) {
		self.scripts = scripts
	}

	func makeController() -> MockCodexSessionController {
		lock.lock()
		let script: [CodexNativeSessionController.Event]
		if scripts.isEmpty {
			script = [.turnCompleted(turnID: nil, status: .completed)]
		} else {
			script = scripts.removeFirst()
		}
		let controller = MockCodexSessionController(scriptedEvents: script)
		controllers.append(controller)
		lock.unlock()
		return controller
	}

	func createdControllers() -> [MockCodexSessionController] {
		lock.lock()
		defer { lock.unlock() }
		return controllers
	}
}
