import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeWorkflowCarryoverTests: XCTestCase {
	func testFirstSendOnUnlinkedTabCarriesBuiltInWorkflowAndQueuedAttachmentsToDestinationBubble() async {
		let vm = makeViewModel()
		vm.selectedAgent = .codexExec

		let sourceTabID = UUID()
		let destinationTabID = UUID()
		let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
		let imageAttachment = AgentImageAttachment(
			source: .localFile(path: "/tmp/workflow-carryover-image.png"),
			title: "workflow-carryover-image.png"
		)
		let taggedFileAttachment = AgentTaggedFileAttachment(
			relativePath: "RepoPrompt/ViewModels/AgentModeViewModel.swift",
			displayName: "AgentModeViewModel.swift"
		)
		sourceSession.selectedWorkflow = AgentWorkflow.build.definition
		sourceSession.pendingImageAttachments = [imageAttachment]
		sourceSession.pendingTaggedFileAttachments = [taggedFileAttachment]

		let result = await vm.submitUserTurnCreatingSessionIfNeeded(
			text: "Investigate the workflow pill bug",
			sourceTabID: sourceTabID,
			createAndActivateSessionTab: { destinationTabID }
		)

		XCTAssertEqual(result, .submitted)
		XCTAssertNil(sourceSession.selectedWorkflow)
		XCTAssertTrue(sourceSession.pendingImageAttachments.isEmpty)
		XCTAssertTrue(sourceSession.pendingTaggedFileAttachments.isEmpty)

		let destinationSession = await vm.ensureSessionReady(tabID: destinationTabID)
		XCTAssertNil(destinationSession.selectedWorkflow)
		XCTAssertTrue(destinationSession.pendingImageAttachments.isEmpty)
		XCTAssertTrue(destinationSession.pendingTaggedFileAttachments.isEmpty)
		guard let userItem = destinationSession.items.first else {
			return XCTFail("Expected an optimistic user item in the destination session")
		}
		XCTAssertEqual(userItem.kind, .user)
		XCTAssertEqual(userItem.text, "Investigate the workflow pill bug")
		XCTAssertEqual(userItem.workflow?.builtInWorkflow, .build)
		XCTAssertEqual(userItem.attachments, [imageAttachment])
		XCTAssertEqual(userItem.taggedFileAttachments, [taggedFileAttachment])
	}

	func testFirstSendOnUnlinkedTabCarriesCustomWorkflowToDestinationBubble() async {
		let vm = makeViewModel()
		vm.selectedAgent = .codexExec

		let sourceTabID = UUID()
		let destinationTabID = UUID()
		let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
		let customWorkflow = AgentWorkflowDefinition(
			customID: UUID(),
			displayName: "Custom Investigate",
			iconName: "magnifyingglass",
			descriptionText: "Investigate with a custom template",
			template: "Custom investigate\n\n$ARGUMENTS"
		)
		sourceSession.selectedWorkflow = customWorkflow

		let result = await vm.submitUserTurnCreatingSessionIfNeeded(
			text: "Find the root cause",
			sourceTabID: sourceTabID,
			createAndActivateSessionTab: { destinationTabID }
		)

		XCTAssertEqual(result, .submitted)
		let destinationSession = await vm.ensureSessionReady(tabID: destinationTabID)
		guard let userItem = destinationSession.items.first else {
			return XCTFail("Expected an optimistic user item in the destination session")
		}
		XCTAssertEqual(userItem.workflow?.customID, customWorkflow.customID)
		XCTAssertEqual(userItem.workflow?.displayName, customWorkflow.displayName)
	}

	func testReconciledCustomWorkflowSelectionRefreshesMatchingCustomWorkflowDefinition() {
		let customID = UUID()
		let selectedWorkflow = AgentWorkflowDefinition(
			customID: customID,
			displayName: "Old Custom Workflow",
			tooltipText: "Old tooltip",
			template: "Old\n\n$ARGUMENTS"
		)
		let refreshedWorkflow = AgentWorkflowDefinition(
			customID: customID,
			displayName: "Refreshed Custom Workflow",
			tooltipText: "New tooltip",
			template: "New\n\n$ARGUMENTS"
		)

		let reconciled = AgentModeViewModel.reconciledCustomWorkflowSelection(
			selectedWorkflow,
			against: [refreshedWorkflow]
		)

		XCTAssertEqual(reconciled, refreshedWorkflow)
	}

	func testReconciledCustomWorkflowSelectionPreservesMissingCustomWorkflowSnapshot() {
		let selectedWorkflow = AgentWorkflowDefinition(
			customID: UUID(),
			displayName: "Queued Custom Workflow",
			template: "Queued\n\n$ARGUMENTS"
		)

		let reconciled = AgentModeViewModel.reconciledCustomWorkflowSelection(
			selectedWorkflow,
			against: []
		)

		XCTAssertEqual(reconciled, selectedWorkflow)
	}

	private func makeViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 17,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				NoOpCodexController()
			}
		)
	}
}

private final class NoOpCodexController: CodexSessionControlling {
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
			conversationID: existing?.conversationID ?? "noop-session",
			rolloutPath: existing?.rolloutPath,
			model: existing?.model,
			reasoningEffort: existing?.reasoningEffort
		)
	}

	func sendUserMessage(_ text: String) async throws {}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}

	func cancelCurrentTurn() async {}

	func shutdown() async {}

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String : Any]) async {}
}
