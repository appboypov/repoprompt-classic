import XCTest
import CoreGraphics
@testable import RepoPrompt

final class AgentTranscriptScrollProgressPolicyTests: XCTestCase {
	func testMeaningfulManualProgressRecognizesViewportMovementTowardHistory() {
		XCTAssertTrue(
			AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
				direction: .towardHistory,
				progress: makeProgress(
					baselineDistanceToBottom: 80,
					currentDistanceToBottom: 89,
					baselineVisibleMinY: 200,
					currentVisibleMinY: 193
				),
				distanceThreshold: 8,
				visibleMinYThreshold: 6
			)
		)
	}

	func testMeaningfulManualProgressRequiresMoreThanStationaryNoise() {
		XCTAssertFalse(
			AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
				direction: .towardHistory,
				progress: makeProgress(
					baselineDistanceToBottom: 80,
					currentDistanceToBottom: 84,
					baselineVisibleMinY: 200,
					currentVisibleMinY: 196
				),
				distanceThreshold: 8,
				visibleMinYThreshold: 6
			)
		)
	}

	func testEffectiveDistanceDeltaSuppressesContentHeightRelayout() {
		let oldMetrics = makeScrollMetrics(distanceToBottom: 80, visibleMinY: 200, contentHeight: 500, viewportHeight: 300)
		let relayoutMetrics = makeScrollMetrics(distanceToBottom: 140, visibleMinY: 200, contentHeight: 560, viewportHeight: 300)

		XCTAssertEqual(
			AgentTranscriptScrollProgressPolicy.effectiveDistanceDeltaForManualScroll(
				oldMetrics: oldMetrics,
				newMetrics: relayoutMetrics,
				layoutMutationThreshold: 1
			),
			0
		)
	}

	func testEffectiveDistanceDeltaPreservesStableLayoutDistanceMotion() {
		let oldMetrics = makeScrollMetrics(distanceToBottom: 80, visibleMinY: 200, contentHeight: 500, viewportHeight: 300)
		let scrolledMetrics = makeScrollMetrics(distanceToBottom: 92, visibleMinY: 188, contentHeight: 500, viewportHeight: 300)

		XCTAssertEqual(
			AgentTranscriptScrollProgressPolicy.effectiveDistanceDeltaForManualScroll(
				oldMetrics: oldMetrics,
				newMetrics: scrolledMetrics,
				layoutMutationThreshold: 1
			),
			12
		)
	}

	func testIntentResolverTreatsSanitizedGrowingDistanceAsTowardHistory() {
		XCTAssertEqual(
			AgentTranscriptUserScrollIntentResolver.resolve(
				distanceDelta: 12,
				visibleMinYDelta: -3,
				distanceThreshold: 8,
				visibleMinYThreshold: 6
			),
			.towardHistory
		)
	}

	func testPinnedFollowIntentResolverIgnoresDistanceOnlyGrowthTowardHistory() {
		XCTAssertEqual(
			AgentTranscriptUserScrollIntentResolver.resolvePinnedLiveBottomFollowIntent(
				distanceDelta: 12,
				visibleMinYDelta: -3,
				distanceThreshold: 8,
				visibleMinYThreshold: 6
			),
			.unknown
		)
	}

	func testPinnedFollowIntentResolverUsesSanitizedDistanceShrinkTowardLiveBottom() {
		XCTAssertEqual(
			AgentTranscriptUserScrollIntentResolver.resolvePinnedLiveBottomFollowIntent(
				distanceDelta: -12,
				visibleMinYDelta: 3,
				distanceThreshold: 8,
				visibleMinYThreshold: 6
			),
			.towardLiveBottom
		)
	}

	func testPinnedFollowIntentResolverUsesViewportEscapeTowardHistory() {
		XCTAssertEqual(
			AgentTranscriptUserScrollIntentResolver.resolvePinnedLiveBottomFollowIntent(
				distanceDelta: 2,
				visibleMinYDelta: -7,
				distanceThreshold: 8,
				visibleMinYThreshold: 6
			),
			.towardHistory
		)
	}

	func testIntentResolverTreatsSanitizedShrinkingDistanceAsTowardLiveBottom() {
		XCTAssertEqual(
			AgentTranscriptUserScrollIntentResolver.resolve(
				distanceDelta: -12,
				visibleMinYDelta: 3,
				distanceThreshold: 8,
				visibleMinYThreshold: 6
			),
			.towardLiveBottom
		)
	}

	func testMeaningfulManualProgressIgnoresContentHeightOnlyDistanceChanges() {
		XCTAssertFalse(
			AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
				direction: .towardHistory,
				progress: makeProgress(
					baselineDistanceToBottom: 80,
					currentDistanceToBottom: 140,
					baselineVisibleMinY: 200,
					currentVisibleMinY: 200
				),
				distanceThreshold: 8,
				visibleMinYThreshold: 6
			)
		)
	}

	func testTowardHistoryViewportEscapeRequiresVisibleViewportMovement() {
		XCTAssertFalse(
			AgentTranscriptScrollProgressPolicy.hasTowardHistoryViewportEscape(
				progress: makeProgress(
					baselineDistanceToBottom: 0,
					currentDistanceToBottom: 30,
					baselineVisibleMinY: 100,
					currentVisibleMinY: 100
				),
				visibleMinYThreshold: 24
			)
		)
		XCTAssertTrue(
			AgentTranscriptScrollProgressPolicy.hasTowardHistoryViewportEscape(
				progress: makeProgress(
					baselineDistanceToBottom: 0,
					currentDistanceToBottom: 30,
					baselineVisibleMinY: 100,
					currentVisibleMinY: 75
				),
				visibleMinYThreshold: 24
			)
		)
	}

	func testCumulativeViewportFallbackRecognizesShortTowardHistoryScroll() {
		XCTAssertEqual(
			AgentTranscriptUserScrollIntentResolver.resolveFromCumulativeViewportMovement(
				visibleMinYDelta: -7,
				visibleMinYThreshold: 6
			),
			.towardHistory
		)
	}

	func testCumulativeViewportFallbackRecognizesShortTowardLiveBottomScroll() {
		XCTAssertEqual(
			AgentTranscriptUserScrollIntentResolver.resolveFromCumulativeViewportMovement(
				visibleMinYDelta: 7,
				visibleMinYThreshold: 6
			),
			.towardLiveBottom
		)
	}

	func testCumulativeViewportFallbackIgnoresSubthresholdMovement() {
		XCTAssertEqual(
			AgentTranscriptUserScrollIntentResolver.resolveFromCumulativeViewportMovement(
				visibleMinYDelta: -5,
				visibleMinYThreshold: 6
			),
			.unknown
		)
	}

	func testVelocityHintResolverIgnoresTinyVelocity() {
		XCTAssertEqual(
			AgentTranscriptUserScrollIntentResolver.resolve(
				verticalVelocity: 0.5,
				minimumMagnitude: 1
			),
			.unknown
		)
	}
}

private func makeProgress(
	baselineDistanceToBottom: CGFloat,
	currentDistanceToBottom: CGFloat,
	baselineVisibleMinY: CGFloat,
	currentVisibleMinY: CGFloat
) -> AgentTranscriptViewportProgress {
	AgentTranscriptViewportProgress(
		baselineDistanceToBottom: baselineDistanceToBottom,
		currentDistanceToBottom: currentDistanceToBottom,
		baselineVisibleMinY: baselineVisibleMinY,
		currentVisibleMinY: currentVisibleMinY
	)
}

private func makeScrollMetrics(
	distanceToBottom: CGFloat,
	visibleMinY: CGFloat,
	contentHeight: CGFloat,
	viewportHeight: CGFloat
) -> AgentTranscriptScrollMetrics {
	AgentTranscriptScrollMetrics(
		distanceToBottom: distanceToBottom,
		visibleMinY: visibleMinY,
		contentHeight: contentHeight,
		viewportHeight: viewportHeight
	)
}
