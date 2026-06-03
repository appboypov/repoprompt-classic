import XCTest
import Foundation
@testable import RepoPrompt

@MainActor
final class AgentFileTagExtractionTests: XCTestCase {
	func testExtractTaggedPathsDeduplicatesAndTrimsTrailingPunctuation() {
		let vm = makeViewModel()
		let tags = vm.test_extractTaggedPaths(from: "Check @RepoPrompt/ViewModels/AgentModeViewModel.swift, then @RepoPrompt/Views/AgentMode/AgentInputBar.swift. Repeat @RepoPrompt/ViewModels/AgentModeViewModel.swift!")
		XCTAssertEqual(tags, [
			"RepoPrompt/ViewModels/AgentModeViewModel.swift",
			"RepoPrompt/Views/AgentMode/AgentInputBar.swift"
		])
	}

	func testExtractTaggedPathsIgnoresAbsoluteAndFileURLReferences() {
		let vm = makeViewModel()
		let tags = vm.test_extractTaggedPaths(from: "Use @/tmp/image.png and @file:///tmp/other.png plus @~/Desktop/test.md and @RepoPrompt/Views/Common/TextField/ResizableTextField.swift")
		XCTAssertEqual(tags, ["RepoPrompt/Views/Common/TextField/ResizableTextField.swift"])
	}

	func testExtractTaggedPathsReturnsEmptyWhenNoValidTagsExist() {
		let vm = makeViewModel()
		let tags = vm.test_extractTaggedPaths(from: "No tags here.")
		XCTAssertTrue(tags.isEmpty)
	}

	func testExtractTaggedPathsSupportsEscapedWhitespace() {
		let vm = makeViewModel()
		let tags = vm.test_extractTaggedPaths(
			from: "Check @RepoPrompt/Views/Common/My\\ File.swift and @docs/plans/Design\\ Draft.md"
		)
		XCTAssertEqual(tags, [
			"RepoPrompt/Views/Common/My File.swift",
			"docs/plans/Design Draft.md"
		])
	}

	func testExtractSlashSkillTokensRequiresWhitespaceBoundary() {
		let vm = makeViewModel()
		let names = vm.test_extractSlashSkillTokenNames(from: "See foo/rp-build and /rp-build now")
		XCTAssertEqual(names, ["rp-build"])
	}

	func testExtractSlashSkillTokensSupportsMultipleCommands() {
		let vm = makeViewModel()
		let names = vm.test_extractSlashSkillTokenNames(from: "/rp-build add tests\n/rp-review")
		XCTAssertEqual(names, ["rp-build", "rp-review"])
	}

	func testExtractSlashSkillTokensIgnoreInvalidTokenCharacters() {
		let vm = makeViewModel()
		let names = vm.test_extractSlashSkillTokenNames(from: "/rp.build bad /rp-build good")
		XCTAssertEqual(names, ["rp-build"])
	}

	private func makeViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			AgentFileTagNoopCodexController()
		}
	}
}

private final class AgentFileTagNoopCodexController: CodexSessionControlling {
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
