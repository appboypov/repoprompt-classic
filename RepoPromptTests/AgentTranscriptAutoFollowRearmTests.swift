import XCTest
import CoreGraphics
@testable import RepoPrompt

final class AgentTranscriptAutoFollowRearmTests: XCTestCase {
	func testDetachPolicyDoesNotDetachOnPureDistanceInflation() {
		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottom(
				runtime: makeRuntimeState(
					isPinnedToLiveBottom: true,
					isUserInteractingWithScroll: true,
					distanceToBottom: 25
				),
				latestManualIntent: .towardHistory,
				progress: makeProgress(
					baselineDistanceToBottom: 0,
					baselineVisibleMinY: 100,
					currentDistanceToBottom: 25,
					currentVisibleMinY: 100
				),
				minimumViewportEscapeDistance: 24,
				suppressGeometryDetach: false,
				suppressRepinGraceDetach: false
			)
		)
	}

	func testDetachPolicyRequiresTowardHistoryIntentAndViewportEscape() {
		let runtime = makeRuntimeState(
			isPinnedToLiveBottom: true,
			isUserInteractingWithScroll: true,
			distanceToBottom: 30
		)
		let progress = makeProgress(
			baselineDistanceToBottom: 0,
			baselineVisibleMinY: 100,
			currentDistanceToBottom: 30,
			currentVisibleMinY: 75
		)

		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottom(
				runtime: runtime,
				latestManualIntent: .unknown,
				progress: progress,
				minimumViewportEscapeDistance: 24,
				suppressGeometryDetach: false,
				suppressRepinGraceDetach: false
			)
		)
		XCTAssertTrue(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottom(
				runtime: runtime,
				latestManualIntent: .towardHistory,
				progress: progress,
				minimumViewportEscapeDistance: 24,
				suppressGeometryDetach: false,
				suppressRepinGraceDetach: false
			)
		)
	}

	func testDetachPolicyHonorsSuppressionFlags() {
		let runtime = makeRuntimeState(
			isPinnedToLiveBottom: true,
			isUserInteractingWithScroll: true,
			distanceToBottom: 40
		)

		let progress = makeProgress(
			baselineDistanceToBottom: 0,
			baselineVisibleMinY: 100,
			currentDistanceToBottom: 40,
			currentVisibleMinY: 70
		)

		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottom(
				runtime: runtime,
				latestManualIntent: .towardHistory,
				progress: progress,
				minimumViewportEscapeDistance: 24,
				suppressGeometryDetach: true,
				suppressRepinGraceDetach: false
			)
		)
		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottom(
				runtime: runtime,
				latestManualIntent: .towardHistory,
				progress: progress,
				minimumViewportEscapeDistance: 24,
				suppressGeometryDetach: false,
				suppressRepinGraceDetach: true
			)
		)
	}

	func testIdleBoundaryDetachRequiresTowardHistoryProgress() {
		let runtime = makeRuntimeState(isPinnedToLiveBottom: true)

		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottomAfterRunBecomesIdle(
				runtime: runtime,
				idleTransitionArmed: true,
				hasTowardHistoryManualIntent: true,
				progress: makeProgress(
					baselineDistanceToBottom: 0,
					baselineVisibleMinY: 100,
					currentDistanceToBottom: 7,
					currentVisibleMinY: 100
				),
				minimumEscapeDistance: 6
			)
		)
		XCTAssertTrue(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottomAfterRunBecomesIdle(
				runtime: runtime,
				idleTransitionArmed: true,
				hasTowardHistoryManualIntent: true,
				progress: makeProgress(
					baselineDistanceToBottom: 0,
					baselineVisibleMinY: 100,
					currentDistanceToBottom: 0,
					currentVisibleMinY: 92
				),
				minimumEscapeDistance: 6
			)
		)
		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottomAfterRunBecomesIdle(
				runtime: runtime,
				idleTransitionArmed: true,
				hasTowardHistoryManualIntent: false,
				progress: makeProgress(
					baselineDistanceToBottom: 0,
					baselineVisibleMinY: 100,
					currentDistanceToBottom: 7,
					currentVisibleMinY: 100
				),
				minimumEscapeDistance: 6
			)
		)
	}

	func testIdleBoundaryDetachRejectsBlockedOrRestoreState() {
		let progress = makeProgress(
			baselineDistanceToBottom: 0,
			baselineVisibleMinY: 100,
			currentDistanceToBottom: 8,
			currentVisibleMinY: 92
		)

		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottomAfterRunBecomesIdle(
				runtime: makeRuntimeState(isPinnedToLiveBottom: true, isInteractionBlocked: true),
				idleTransitionArmed: true,
				hasTowardHistoryManualIntent: true,
				progress: progress,
				minimumEscapeDistance: 6
			)
		)
		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottomAfterRunBecomesIdle(
				runtime: makeRuntimeState(isPinnedToLiveBottom: true, isRehydrateRestoreActive: true),
				idleTransitionArmed: true,
				hasTowardHistoryManualIntent: true,
				progress: progress,
				minimumEscapeDistance: 6
			)
		)
	}

	func testForceRepinAtActualBottomRequiresDetachedIdleContext() {
		XCTAssertTrue(
			AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
				runtime: makeRuntimeState(
					isPinnedToLiveBottom: false,
					isDetachedFromLiveBottom: true,
					canScrollTowardLiveBottom: false,
					distanceToBottom: 1
				),
				actualBottomDistanceThreshold: 1
			)
		)
	}

	func testForceRepinAtActualBottomRejectsActiveOrDriftingStates() {
		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
				runtime: makeRuntimeState(
					isPinnedToLiveBottom: false,
					isDetachedFromLiveBottom: true,
					canScrollTowardLiveBottom: true,
					distanceToBottom: 0.5
				),
				actualBottomDistanceThreshold: 1
			)
		)
		XCTAssertFalse(
			AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
				runtime: makeRuntimeState(
					isPinnedToLiveBottom: false,
					isDetachedFromLiveBottom: true,
					isProgrammaticScrollInFlight: true,
					canScrollTowardLiveBottom: false,
					distanceToBottom: 0.5
				),
				actualBottomDistanceThreshold: 1
			)
		)
	}
}

private func makeRuntimeState(
	armingState: AgentModeViewModel.AgentTranscriptAutoFollowArmingState = .armed,
	isPinnedToLiveBottom: Bool = false,
	isDetachedFromLiveBottom: Bool = false,
	isUserInteractingWithScroll: Bool = false,
	isInteractionBlocked: Bool = false,
	isRehydrateRestoreActive: Bool = false,
	isProgrammaticScrollInFlight: Bool = false,
	canScrollTowardHistory: Bool = false,
	canScrollTowardLiveBottom: Bool = false,
	distanceToBottom: CGFloat = 0
) -> AgentTranscriptScrollRuntimeState {
	AgentTranscriptScrollRuntimeState(
		armingState: armingState,
		isPinnedToLiveBottom: isPinnedToLiveBottom,
		isDetachedFromLiveBottom: isDetachedFromLiveBottom,
		isUserInteractingWithScroll: isUserInteractingWithScroll,
		isInteractionBlocked: isInteractionBlocked,
		isRehydrateRestoreActive: isRehydrateRestoreActive,
		isProgrammaticScrollInFlight: isProgrammaticScrollInFlight,
		canScrollTowardHistory: canScrollTowardHistory,
		canScrollTowardLiveBottom: canScrollTowardLiveBottom,
		distanceToBottom: distanceToBottom
	)
}

private func makeProgress(
	baselineDistanceToBottom: CGFloat,
	baselineVisibleMinY: CGFloat,
	currentDistanceToBottom: CGFloat,
	currentVisibleMinY: CGFloat
) -> AgentTranscriptViewportProgress {
	AgentTranscriptViewportProgress(
		baselineDistanceToBottom: baselineDistanceToBottom,
		currentDistanceToBottom: currentDistanceToBottom,
		baselineVisibleMinY: baselineVisibleMinY,
		currentVisibleMinY: currentVisibleMinY
	)
}
