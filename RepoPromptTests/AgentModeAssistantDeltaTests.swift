import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeAssistantDeltaTests: XCTestCase {
	func testWhitespaceOnlyAssistantDeltaDoesNotCreateAssistantItem() throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		vm.testAppendMockTranscriptMessage(tabID: tabID, role: .user, text: "Run the tools.")

		vm.testAppendStreamingAssistantDelta(tabID: tabID, delta: "\n\t ")

		let session = try XCTUnwrap(vm.sessions[tabID])
		XCTAssertEqual(session.items.map(\.kind), [.user])
	}

	func testWhitespaceAssistantDeltaAppendsToExistingStreamingAssistant() throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)

		vm.testAppendStreamingAssistantDelta(tabID: tabID, delta: "Hello")
		vm.testAppendStreamingAssistantDelta(tabID: tabID, delta: " ")
		vm.testAppendStreamingAssistantDelta(tabID: tabID, delta: "world")

		let session = try XCTUnwrap(vm.sessions[tabID])
		let assistantRows = session.items.filter { $0.kind == .assistant }
		XCTAssertEqual(assistantRows.map(\.text), ["Hello world"])
		XCTAssertEqual(assistantRows.first?.isStreaming, true)
	}

	func testDisplayableTextKeepsMicroNoiseAndConciseAnswers() throws {
		XCTAssertFalse(AgentDisplayableText.hasDisplayableBody(""))
		XCTAssertFalse(AgentDisplayableText.hasDisplayableBody("\n\n\n"))
		XCTAssertFalse(AgentDisplayableText.hasDisplayableBody("\u{200B}\u{2060}\u{FEFF}"))
		XCTAssertTrue(AgentDisplayableText.hasDisplayableBody("."))
		XCTAssertTrue(AgentDisplayableText.hasDisplayableBody("resumed after stop"))
	}

	func testGenericAssistantDeltaCreatesRowsForMicroNoiseAndConciseAnswers() throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		vm.testAppendMockTranscriptMessage(tabID: tabID, role: .user, text: "Resume.")

		vm.testAppendStreamingAssistantDelta(tabID: tabID, delta: ".")
		vm.testFinalizeStreamingAssistant(tabID: tabID)
		vm.testAppendStreamingAssistantDelta(tabID: tabID, delta: "resumed after stop")

		let session = try XCTUnwrap(vm.sessions[tabID])
		let assistantRows = session.items.filter { $0.kind == .assistant }
		XCTAssertEqual(assistantRows.map(\.text), [".", "resumed after stop"])
	}

	func testCodexWhitespaceOnlyAssistantDeltaDoesNotCreateAssistantItem() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		let turnID = "turn-displayless"
		vm.ensureSession(for: tabID)
		vm.testAppendMockTranscriptMessage(tabID: tabID, role: .user, text: "Run the tools.")

		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .turnStarted(turnID: turnID))
		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .assistantDelta("\n\n\n"))
		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .turnCompleted(turnID: turnID, status: .completed))

		let session = try XCTUnwrap(vm.sessions[tabID])
		XCTAssertFalse(session.items.contains { $0.kind == .assistant || $0.kind == .assistantInline })
	}

	func testCodexWhitespaceOnlyAssistantDeltaAppendsToExistingStreamingAssistantAcrossFlushes() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		let turnID = "turn-whitespace-preserved"
		vm.ensureSession(for: tabID)
		vm.testAppendMockTranscriptMessage(tabID: tabID, role: .user, text: "Continue.")

		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .turnStarted(turnID: turnID))
		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .assistantDelta("Hello"))
		await vm.testReplayCodexNativeEvent(
			tabID: tabID,
			event: .commandExecutionRunning(.init(invocationID: nil, processID: nil, appendedOutput: nil))
		)
		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .assistantDelta(" \n"))
		await vm.testReplayCodexNativeEvent(
			tabID: tabID,
			event: .commandExecutionRunning(.init(invocationID: nil, processID: nil, appendedOutput: nil))
		)
		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .assistantDelta("world"))
		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .turnCompleted(turnID: turnID, status: .completed))

		let session = try XCTUnwrap(vm.sessions[tabID])
		let assistantRows = session.items.filter { $0.kind == .assistant }
		XCTAssertEqual(assistantRows.map(\.text), ["Hello \nworld"])
	}

	func testCodexAssistantDeltaKeepsMicroNoiseAssistantItem() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		let turnID = "turn-dot"
		vm.ensureSession(for: tabID)
		vm.testAppendMockTranscriptMessage(tabID: tabID, role: .user, text: "Continue.")

		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .turnStarted(turnID: turnID))
		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .assistantDelta("."))
		await vm.testReplayCodexNativeEvent(tabID: tabID, event: .turnCompleted(turnID: turnID, status: .completed))

		let session = try XCTUnwrap(vm.sessions[tabID])
		let assistantRows = session.items.filter { $0.kind == .assistant }
		XCTAssertEqual(assistantRows.map(\.text), ["."])
	}

	private func makeViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			AssistantDeltaNoopCodexController()
		}
	}
}

private final class AssistantDeltaNoopCodexController: CodexSessionControlling {
	var hasActiveThread: Bool { false }
	var events: AsyncStream<CodexNativeSessionController.Event> { AsyncStream { _ in } }

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
	}

	func sendUserMessage(_ text: String) async throws {}
	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
	func cancelCurrentTurn() async {}
	func shutdown() async {}
	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
