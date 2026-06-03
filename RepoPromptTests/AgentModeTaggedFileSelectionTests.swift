import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeTaggedFileSelectionTests: XCTestCase {
	func testShouldAttemptTaggedFileAutoSelectionForInlineMentionWithoutAttachmentChip() {
		let vm = makeViewModel()

		XCTAssertTrue(
			vm.test_shouldAttemptTaggedFileAutoSelection(
				text: "Please inspect @RepoPrompt/ViewModels/AgentModeViewModel.swift",
				taggedFileAttachments: []
			)
		)
	}

	func testShouldAttemptTaggedFileAutoSelectionReturnsFalseWithoutInlineMentionOrAttachmentChip() {
		let vm = makeViewModel()

		XCTAssertFalse(
			vm.test_shouldAttemptTaggedFileAutoSelection(
				text: "Please inspect the current selection",
				taggedFileAttachments: []
			)
		)
	}

	func testShouldAttemptTaggedFileAutoSelectionForAttachmentChipWithoutInlineMention() {
		let vm = makeViewModel()

		XCTAssertTrue(
			vm.test_shouldAttemptTaggedFileAutoSelection(
				text: "Please inspect the current selection",
				taggedFileAttachments: [
					AgentTaggedFileAttachment(
						relativePath: "RepoPrompt/ViewModels/AgentModeViewModel.swift",
						displayName: "AgentModeViewModel.swift"
					)
				]
			)
		)
	}

	func testSelectionByPromotingPathsToFullSelectionAppendsNewTaggedFilesAndDeduplicates() {
		let vm = makeViewModel()
		let selection = StoredSelection(
			selectedPaths: ["/tmp/project/./App.swift"],
			autoCodemapPaths: ["/tmp/project/Utils.swift"],
			slices: ["/tmp/project/App.swift": [LineRange(start: 3, end: 9)]],
			codemapAutoEnabled: false
		)

		let updated = vm.test_selectionByPromotingPathsToFullSelection(
			selection: selection,
			paths: [
				"/tmp/project/App.swift",
				"/tmp/project/Features/../New.swift",
				"/tmp/project/New.swift"
			]
		)

		XCTAssertEqual(updated.selectedPaths, [
			"/tmp/project/App.swift",
			"/tmp/project/New.swift"
		])
		XCTAssertEqual(updated.autoCodemapPaths, selection.autoCodemapPaths)
		XCTAssertTrue(updated.slices.isEmpty)
		XCTAssertEqual(updated.codemapAutoEnabled, selection.codemapAutoEnabled)
	}

	func testSelectionByPromotingPathsToFullSelectionClearsAutoCodemapAndSlicesForPromotedFiles() {
		let vm = makeViewModel()
		let selection = StoredSelection(
			selectedPaths: ["/tmp/project/App.swift"],
			autoCodemapPaths: ["/tmp/project/./App.swift", "/tmp/project/Utils.swift"],
			slices: ["/tmp/project/App.swift": [LineRange(start: 1, end: 2)]],
			codemapAutoEnabled: true
		)

		let updated = vm.test_selectionByPromotingPathsToFullSelection(
			selection: selection,
			paths: [
				"/tmp/project/./App.swift",
				"/tmp/project/App.swift"
			]
		)

		XCTAssertEqual(updated.selectedPaths, ["/tmp/project/App.swift"])
		XCTAssertEqual(updated.autoCodemapPaths, ["/tmp/project/Utils.swift"])
		XCTAssertTrue(updated.slices.isEmpty)
		XCTAssertTrue(updated.codemapAutoEnabled)
	}

	private func makeViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			NoopTaggedSelectionCodexController()
		}
	}
}

private final class NoopTaggedSelectionCodexController: CodexSessionControlling {
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
