import XCTest
@testable import RepoPrompt

@MainActor
final class AgentFileMentionDisplayTests: XCTestCase {
	func testCommitDisplayTextUsesBasenameWhenUnique() {
		let label = AgentFileTagSuggestionService.commitDisplayText(
			fileName: "AgentModeViewModel.swift",
			tokenRelativePath: "RepoPrompt/ViewModels/AgentModeViewModel.swift",
			isDuplicateName: false
		)

		XCTAssertEqual(label, "AgentModeViewModel.swift")
	}

	func testCommitDisplayTextUsesTokenRelativePathWhenAmbiguous() {
		let label = AgentFileTagSuggestionService.commitDisplayText(
			fileName: "Config.swift",
			tokenRelativePath: "RepoPrompt/Services/Config.swift",
			isDuplicateName: true
		)

		XCTAssertEqual(label, "RepoPrompt/Services/Config.swift")
	}

	func testCommittedReplacementTextUsesCommitDisplayTextAndEscapesSpaces() {
		let suggestion = MentionSuggestion(
			displayName: "My File.swift",
			relativePath: "RepoPrompt/Views/My File.swift",
			kind: .file,
			commitDisplayText: "My File.swift"
		)

		XCTAssertEqual(
			FileTagMentionHelper.committedReplacementText(for: suggestion),
			"@My\\ File.swift "
		)
	}

	func testCommittedReplacementTextFallsBackToRelativePath() {
		let suggestion = MentionSuggestion(
			displayName: "My File.swift",
			relativePath: "RepoPrompt/Views/My File.swift",
			kind: .file,
			commitDisplayText: "  "
		)

		XCTAssertEqual(
			FileTagMentionHelper.committedReplacementText(for: suggestion),
			"@RepoPrompt/Views/My\\ File.swift "
		)
	}

	func testCommittedInsertionPointLandsAfterTrailingWhitespace() {
		let replacement = "@AgentModeViewModel.swift "
		let triggerRange = NSRange(location: 7, length: 4)

		let insertionPoint = FileTagMentionHelper.committedInsertionPoint(
			triggerRange: triggerRange,
			replacement: replacement
		)

		XCTAssertEqual(insertionPoint, 7 + (replacement as NSString).length)
	}

	func testAttachmentDisplayNamePrefersCommitDisplayText() {
		let suggestion = MentionSuggestion(
			displayName: "Config.swift",
			relativePath: "RepoPrompt/Services/Config.swift",
			kind: .file,
			commitDisplayText: "RepoPrompt/Services/Config.swift"
		)

		XCTAssertEqual(
			AgentFileMentionText.attachmentDisplayName(for: suggestion),
			"RepoPrompt/Services/Config.swift"
		)
	}

	func testRemovingTaggedMentionRemovesVisibleLabelAndFallbackPath() {
		let text = "Check @My\\ File.swift and @RepoPrompt/Views/My\\ File.swift next"

		let updated = AgentFileMentionText.removingTaggedMention(
			displayName: "My File.swift",
			relativePath: "RepoPrompt/Views/My File.swift",
			from: text
		)

		XCTAssertEqual(updated, "Check and next")
	}

	func testDraftSyncRetainsTaggedAttachmentWhenDraftContainsDisplayName() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.addPendingTaggedFile(
			tabID: tabID,
			relativePath: "RepoPrompt/ViewModels/AgentModeViewModel.swift",
			displayName: "AgentModeViewModel.swift"
		)

		vm.syncPendingTaggedFilesFromDraft(
			tabID: tabID,
			text: "Please inspect @AgentModeViewModel.swift"
		)

		XCTAssertEqual(vm.session(for: tabID).pendingTaggedFileAttachments.count, 1)
	}

	func testDraftSyncRemovesTaggedAttachmentWhenDraftContainsNeitherLabelNorPath() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.addPendingTaggedFile(
			tabID: tabID,
			relativePath: "RepoPrompt/ViewModels/AgentModeViewModel.swift",
			displayName: "AgentModeViewModel.swift"
		)

		vm.syncPendingTaggedFilesFromDraft(
			tabID: tabID,
			text: "Please inspect the view model"
		)

		XCTAssertTrue(vm.session(for: tabID).pendingTaggedFileAttachments.isEmpty)
	}

	private func makeViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			MentionDisplayNoopCodexController()
		}
	}
}

private final class MentionDisplayNoopCodexController: CodexSessionControlling {
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
