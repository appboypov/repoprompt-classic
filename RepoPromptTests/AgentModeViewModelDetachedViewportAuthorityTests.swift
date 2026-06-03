import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeViewModelDetachedViewportAuthorityTests: XCTestCase {
	func testSetDetachedMarksSessionDetachedButClearsAuthority() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)

		session.transcriptViewportState = AgentTranscriptViewportState(
			isDetachedFromLiveBottom: true,
			detachedAuthority: DetachedViewportAuthority(
				targetID: .block("stored-block"),
				anchor: nil,
				sequenceIndex: 7,
				blockID: "stored-block",
				viewportMinY: -12
			)
		)

		vm.setTranscriptDetachedFromLiveBottom(tabID: tabID, isDetached: true)

		XCTAssertTrue(session.transcriptViewportState.isDetachedFromLiveBottom)
		XCTAssertNil(session.transcriptViewportState.detachedAuthority)
	}

	func testSetDetachedTwiceKeepsAuthorityNil() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)

		vm.setTranscriptDetachedFromLiveBottom(tabID: tabID, isDetached: true)
		vm.setTranscriptDetachedFromLiveBottom(tabID: tabID, isDetached: true)

		XCTAssertTrue(session.transcriptViewportState.isDetachedFromLiveBottom)
		XCTAssertNil(session.transcriptViewportState.detachedAuthority)
	}

	func testClearingDetachedRestoresLiveBottom() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)

		vm.setTranscriptDetachedFromLiveBottom(
			tabID: tabID,
			isDetached: true,
			armingState: .disarmedAfterManualDetach
		)
		vm.setTranscriptDetachedFromLiveBottom(tabID: tabID, isDetached: false)

		XCTAssertEqual(session.transcriptViewportState, .liveBottom)
		XCTAssertEqual(session.transcriptAutoFollowArmingState, .armed)
	}

	func testManualDetachCanDisarmInSingleOwnerUpdate() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)

		vm.setTranscriptDetachedFromLiveBottom(
			tabID: tabID,
			isDetached: true,
			armingState: .disarmedAfterManualDetach
		)

		XCTAssertTrue(session.transcriptViewportState.isDetachedFromLiveBottom)
		XCTAssertNil(session.transcriptViewportState.detachedAuthority)
		XCTAssertEqual(session.transcriptAutoFollowArmingState, .disarmedAfterManualDetach)
	}

	func testNormalizeTranscriptFollowStateForViewActivationRepinsDetachedSessionAndRearmsAutoFollow() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)

		vm.setTranscriptDetachedFromLiveBottom(
			tabID: tabID,
			isDetached: true,
			armingState: .disarmedAfterManualDetach
		)

		vm.normalizeTranscriptFollowStateForViewActivation(tabID: tabID)

		XCTAssertEqual(session.transcriptViewportState, .liveBottom)
		XCTAssertEqual(session.transcriptAutoFollowArmingState, .armed)
	}

	func testPersistedHydrationUsesLiveBottomProjectionProtectionForActivationLoad() async {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		let userItem = AgentChatItem.user("Investigate", sequenceIndex: 0)
		let transcript = AgentTranscriptIO.buildTranscript(
			from: [userItem, AgentChatItem.assistant("Done", sequenceIndex: 1)],
			terminalState: .idle,
			nextSequenceIndex: 2
		)
		session.transcriptViewportState = AgentTranscriptViewportState(
			isDetachedFromLiveBottom: true,
			detachedAuthority: DetachedViewportAuthority(
				targetID: .row(userItem.id),
				anchor: nil,
				sequenceIndex: userItem.sequenceIndex,
				blockID: nil,
				viewportMinY: -20
			)
		)

		XCTAssertNotEqual(
			AgentSessionRestoreSupport.transcriptProjectionProtection(
				for: transcript,
				viewportState: session.transcriptViewportState
			),
			.none
		)

		let hydrationViewportState = vm.test_persistedHydrationTranscriptViewportState(tabID: tabID)
		XCTAssertEqual(hydrationViewportState, .liveBottom)
		vm.test_setCurrentTabIDOverride(UUID())
		XCTAssertEqual(vm.test_persistedHydrationTranscriptViewportState(tabID: tabID), session.transcriptViewportState)
		vm.test_setActiveSessionLoadInProgressTabID(tabID)
		vm.test_publishLoadingTranscriptPresentation(tabID: tabID)
		XCTAssertEqual(vm.test_persistedHydrationTranscriptViewportState(tabID: tabID), .liveBottom)
		vm.test_setActiveSessionLoadInProgressTabID(nil)
		vm.test_setCurrentTabIDOverride(tabID)
		XCTAssertEqual(
			AgentSessionRestoreSupport.transcriptProjectionProtection(
				for: transcript,
				viewportState: hydrationViewportState
			),
			.none
		)
	}

	func testPersistedHydrationUsesLiveBottomForPendingActivationTargetWhenCurrentTabLags() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let laggingCurrentTabID = UUID()
		vm.test_setCurrentTabIDOverride(laggingCurrentTabID)
		defer {
			vm.test_setCurrentTabIDOverride(nil)
			vm.test_setActiveSessionLoadInProgressTabID(nil)
		}
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.transcriptViewportState = AgentTranscriptViewportState(
			isDetachedFromLiveBottom: true,
			detachedAuthority: DetachedViewportAuthority(
				targetID: .block("stale-block"),
				anchor: nil,
				sequenceIndex: 4,
				blockID: "stale-block",
				viewportMinY: -16
			)
		)

		XCTAssertEqual(vm.test_persistedHydrationTranscriptViewportState(tabID: tabID), session.transcriptViewportState)

		vm.test_setActiveSessionLoadInProgressTabID(tabID)
		vm.test_publishLoadingTranscriptPresentation(tabID: tabID)

		XCTAssertEqual(vm.test_persistedHydrationTranscriptViewportState(tabID: tabID), .liveBottom)
	}

	func testNormalizeTranscriptFollowStateForViewActivationRefreshesPublishedFollowSnapshot() async {
		let vm = makeViewModel()
		let tabID = UUID()

		_ = await vm.ensureSessionReady(tabID: tabID)
		vm.setTranscriptDetachedFromLiveBottom(
			tabID: tabID,
			isDetached: true,
			armingState: .disarmedAfterManualDetach
		)
		await vm.testBindSessionToActiveSessionProxies(tabID: tabID)

		XCTAssertEqual(
			vm.activeTranscriptFollowBindingState,
			.init(
				tabID: tabID,
				viewportState: AgentTranscriptViewportState(
					isDetachedFromLiveBottom: true,
					detachedAuthority: nil
				),
				armingState: .disarmedAfterManualDetach
			)
		)

		vm.normalizeTranscriptFollowStateForViewActivation(tabID: tabID)
		await vm.testBindSessionToActiveSessionProxies(tabID: tabID)

		XCTAssertEqual(
			vm.activeTranscriptFollowBindingState,
			.init(
				tabID: tabID,
				viewportState: .liveBottom,
				armingState: .armed
			)
		)
	}

	func testNormalizeTranscriptFollowStateForViewActivationDoesNotAffectOtherTabs() async {
		let vm = makeViewModel()
		let tabA = UUID()
		let tabB = UUID()
		let sessionA = await vm.ensureSessionReady(tabID: tabA)
		let sessionB = await vm.ensureSessionReady(tabID: tabB)

		vm.setTranscriptDetachedFromLiveBottom(
			tabID: tabA,
			isDetached: true,
			armingState: .disarmedAfterManualDetach
		)
		vm.setTranscriptDetachedFromLiveBottom(
			tabID: tabB,
			isDetached: true,
			armingState: .disarmedAfterManualDetach
		)

		vm.normalizeTranscriptFollowStateForViewActivation(tabID: tabA)

		XCTAssertEqual(sessionA.transcriptViewportState, .liveBottom)
		XCTAssertEqual(sessionA.transcriptAutoFollowArmingState, .armed)
		XCTAssertTrue(sessionB.transcriptViewportState.isDetachedFromLiveBottom)
		XCTAssertNil(sessionB.transcriptViewportState.detachedAuthority)
		XCTAssertEqual(sessionB.transcriptAutoFollowArmingState, .disarmedAfterManualDetach)
	}

	func testReDetachingAfterActivationStartsDetachedWithoutAuthority() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)

		vm.setTranscriptDetachedFromLiveBottom(
			tabID: tabID,
			isDetached: true,
			armingState: .disarmedAfterManualDetach
		)
		vm.normalizeTranscriptFollowStateForViewActivation(tabID: tabID)
		vm.setTranscriptDetachedFromLiveBottom(tabID: tabID, isDetached: true)

		XCTAssertTrue(session.transcriptViewportState.isDetachedFromLiveBottom)
		XCTAssertNil(session.transcriptViewportState.detachedAuthority)
		XCTAssertEqual(session.transcriptAutoFollowArmingState, .armed)
	}

	private func makeViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			NoOpCodexController()
		}
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

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String : Any]) async {}
}
