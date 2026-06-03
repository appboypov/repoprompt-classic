import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeViewModelShareThoughtsTests: XCTestCase {
	func testShareThoughtsRoutesToExplicitTab() {
		let vm = makeViewModel()
		let targetTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
		let otherTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
		vm.ensureSession(for: otherTabID)

		vm.shareThoughts("Routing details", title: "Analyzing", tabID: targetTabID)

		guard let targetSession = vm.sessions[targetTabID] else {
			return XCTFail("Expected session for explicit tab")
		}
		XCTAssertEqual(targetSession.items.count, 1)
		XCTAssertEqual(targetSession.items.first?.kind, .thinking)
		XCTAssertTrue(targetSession.items.first?.text.contains("Analyzing") == true)
		XCTAssertTrue(targetSession.items.first?.text.contains("Routing details") == true)
		XCTAssertEqual(vm.sessions[otherTabID]?.items.count, 0)
	}

	func testShareThoughtsWithoutResolvedTabDoesNothing() {
		let vm = makeViewModel()

		vm.shareThoughts("No destination tab")

		XCTAssertTrue(vm.sessions.isEmpty)
	}

	private func makeViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			ShareThoughtsNoOpCodexController()
		}
	}
}

private final class ShareThoughtsNoOpCodexController: CodexSessionControlling {
	var events: AsyncStream<CodexNativeSessionController.Event> {
		AsyncStream { continuation in
			continuation.finish()
		}
	}

	var hasActiveThread: Bool { false }

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(
			conversationID: existing?.conversationID ?? "noop",
			rolloutPath: existing?.rolloutPath,
			model: existing?.model,
			reasoningEffort: existing?.reasoningEffort
		)
	}

	func sendUserMessage(_ text: String) async throws {}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}

	func cancelCurrentTurn() async {}

	func shutdown() async {}

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
