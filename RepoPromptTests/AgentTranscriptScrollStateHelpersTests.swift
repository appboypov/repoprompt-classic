import XCTest
import CoreGraphics
@testable import RepoPrompt

final class AgentTranscriptScrollStateHelpersTests: XCTestCase {
	func testCanScrollTowardHistoryUsesSemanticIDsWhenAvailable() {
		XCTAssertTrue(
			AgentTranscriptScrollCapabilityResolver.canScrollTowardHistory(
				firstVisibleBlockID: "first",
				effectiveTopVisibleBlockID: "second",
				rawVisibleMinY: 0,
				fallbackVisibleMinY: 0,
				epsilon: 1
			)
		)
		XCTAssertFalse(
			AgentTranscriptScrollCapabilityResolver.canScrollTowardHistory(
				firstVisibleBlockID: "first",
				effectiveTopVisibleBlockID: "first",
				rawVisibleMinY: 48,
				fallbackVisibleMinY: 48,
				epsilon: 1
			)
		)
	}

	func testCanScrollTowardHistoryFallsBackToRawGeometry() {
		XCTAssertTrue(
			AgentTranscriptScrollCapabilityResolver.canScrollTowardHistory(
				firstVisibleBlockID: "first",
				effectiveTopVisibleBlockID: nil,
				rawVisibleMinY: 12,
				fallbackVisibleMinY: 0,
				epsilon: 1
			)
		)
	}

	func testCanScrollTowardHistoryFallsBackToCachedGeometry() {
		XCTAssertTrue(
			AgentTranscriptScrollCapabilityResolver.canScrollTowardHistory(
				firstVisibleBlockID: nil,
				effectiveTopVisibleBlockID: nil,
				rawVisibleMinY: nil,
				fallbackVisibleMinY: 8,
				epsilon: 1
			)
		)
	}

	func testCanScrollTowardHistoryReturnsFalseAtTopWithoutSemanticTracking() {
		XCTAssertFalse(
			AgentTranscriptScrollCapabilityResolver.canScrollTowardHistory(
				firstVisibleBlockID: "first",
				effectiveTopVisibleBlockID: nil,
				rawVisibleMinY: 0,
				fallbackVisibleMinY: 0,
				epsilon: 1
			)
		)
	}


	func testManualDetachOverridePolicyExpires() {
		let now = Date()
		let activeUntil = now.addingTimeInterval(0.5)
		let expiredUntil = now.addingTimeInterval(-0.1)

		XCTAssertTrue(AgentTranscriptManualDetachOverridePolicy.isActive(until: activeUntil, now: now))
		XCTAssertFalse(AgentTranscriptManualDetachOverridePolicy.isActive(until: expiredUntil, now: now))
	}

	func testManualDetachOverrideSuppressesRepinPathsWhileActive() {
		let now = Date()
		let activeUntil = now.addingTimeInterval(0.5)

		XCTAssertTrue(
			AgentTranscriptManualDetachOverridePolicy.shouldSuppressActualBottomRepin(
				until: activeUntil,
				now: now
			)
		)
		XCTAssertTrue(
			AgentTranscriptManualDetachOverridePolicy.shouldSuppressDetachedRevisionImmediateRepin(
				until: activeUntil,
				now: now
			)
		)
		XCTAssertTrue(
			AgentTranscriptManualDetachOverridePolicy.shouldSuppressGeometryRepin(
				until: activeUntil,
				now: now
			)
		)
	}

	func testPinnedBottomProtectionArmsOnNearBottomSettleOnlyWhilePinnedAndStable() {
		XCTAssertTrue(
			AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
				runtime: makePinnedBottomRuntimeState(distanceToBottom: 16),
				nearBottomThreshold: 24
			)
		)
		XCTAssertFalse(
			AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
				runtime: makePinnedBottomRuntimeState(distanceToBottom: 40),
				nearBottomThreshold: 24
			)
		)
		XCTAssertFalse(
			AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
				runtime: makePinnedBottomRuntimeState(isPinnedToLiveBottom: false, distanceToBottom: 16),
				nearBottomThreshold: 24
			)
		)
	}

	func testPinnedBottomProtectionRemainsActiveAfterSmoothSendOnlyWhilePinnedAndStable() {
		XCTAssertTrue(
			AgentTranscriptPinnedBottomProtectionPolicy.shouldRemainActiveAfterSmoothSendCompletion(
				runtime: makePinnedBottomRuntimeState()
			)
		)
		XCTAssertFalse(
			AgentTranscriptPinnedBottomProtectionPolicy.shouldRemainActiveAfterSmoothSendCompletion(
				runtime: makePinnedBottomRuntimeState(isDetachedFromLiveBottom: true)
			)
		)
		XCTAssertFalse(
			AgentTranscriptPinnedBottomProtectionPolicy.shouldRemainActiveAfterSmoothSendCompletion(
				runtime: makePinnedBottomRuntimeState(isUserInteractingWithScroll: true)
			)
		)
	}

	func testPinnedBottomProtectionRetainsLastResolvedScrollViewAcrossTransientNilResolution() {
		XCTAssertTrue(
			AgentTranscriptPinnedBottomProtectionPolicy.shouldPreserveLastResolvedScrollView(
				hasExistingScrollView: true,
				hasNewlyResolvedScrollView: false
			)
		)
		XCTAssertFalse(
			AgentTranscriptPinnedBottomProtectionPolicy.shouldPreserveLastResolvedScrollView(
				hasExistingScrollView: false,
				hasNewlyResolvedScrollView: false
			)
		)
		XCTAssertFalse(
			AgentTranscriptPinnedBottomProtectionPolicy.shouldPreserveLastResolvedScrollView(
				hasExistingScrollView: true,
				hasNewlyResolvedScrollView: true
			)
		)
	}

	func testRehydrateRestoreLayoutPolicyRejectsDefaultZeroMetrics() {
		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.hasValidLayoutSample(
				AgentTranscriptScrollMetrics()
			)
		)
		XCTAssertTrue(
			AgentTranscriptRehydrateRestoreLayoutPolicy.hasValidLayoutSample(
				makeScrollMetrics(contentHeight: 0, viewportHeight: 280)
			)
		)
	}

	func testRehydrateRestoreLayoutPolicyRequiresCurrentTabRevisionSampleBeforeCompletion() {
		let tabID = UUID()
		let otherTabID = UUID()
		let revision = 7
		let layoutPassToken: UInt64 = 42
		let now = Date(timeIntervalSinceReferenceDate: 100)
		let quietPeriod: TimeInterval = 0.12
		let strictBottomDistance: CGFloat = 1
		let currentKey = AgentTranscriptRehydrateRetryKey(
			tabID: tabID,
			presentationRevision: revision,
			layoutPassToken: layoutPassToken
		)

		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: nil,
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: layoutPassToken,
				distanceToBottom: 0,
				strictBottomDistanceThreshold: strictBottomDistance,
				lastLayoutMutationAt: nil,
				now: now,
				quietPeriod: quietPeriod
			)
		)
		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: .init(tabID: otherTabID, presentationRevision: revision),
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: layoutPassToken,
				distanceToBottom: 0,
				strictBottomDistanceThreshold: strictBottomDistance,
				lastLayoutMutationAt: nil,
				now: now,
				quietPeriod: quietPeriod
			)
		)
		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: .init(tabID: tabID, presentationRevision: revision - 1),
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: layoutPassToken,
				distanceToBottom: 0,
				strictBottomDistanceThreshold: strictBottomDistance,
				lastLayoutMutationAt: nil,
				now: now,
				quietPeriod: quietPeriod
			)
		)
		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: currentKey,
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: layoutPassToken,
				distanceToBottom: 2,
				strictBottomDistanceThreshold: strictBottomDistance,
				lastLayoutMutationAt: nil,
				now: now,
				quietPeriod: quietPeriod
			)
		)
		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: .init(
					tabID: tabID,
					presentationRevision: revision,
					layoutPassToken: layoutPassToken - 1
				),
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: layoutPassToken,
				distanceToBottom: 0,
				strictBottomDistanceThreshold: strictBottomDistance,
				lastLayoutMutationAt: nil,
				now: now,
				quietPeriod: quietPeriod
			)
		)
		XCTAssertTrue(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: currentKey,
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: layoutPassToken,
				distanceToBottom: 0,
				strictBottomDistanceThreshold: strictBottomDistance,
				lastLayoutMutationAt: nil,
				now: now,
				quietPeriod: quietPeriod
			)
		)
	}

	func testRehydrateRestoreLayoutPolicyRejectsNearButNotStrictBottomCompletion() {
		let tabID = UUID()
		let revision = 7
		let layoutPassToken: UInt64 = 42
		let currentKey = AgentTranscriptRehydrateRetryKey(
			tabID: tabID,
			presentationRevision: revision,
			layoutPassToken: layoutPassToken
		)

		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: currentKey,
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: layoutPassToken,
				distanceToBottom: 16,
				strictBottomDistanceThreshold: 1,
				lastLayoutMutationAt: nil,
				now: Date(timeIntervalSinceReferenceDate: 100),
				quietPeriod: 0.12
			)
		)
	}

	func testRehydrateRestoreLayoutPolicyDefersCompletionUntilLayoutQuietPeriodExpires() {
		let tabID = UUID()
		let revision = 7
		let layoutPassToken: UInt64 = 42
		let now = Date(timeIntervalSinceReferenceDate: 100)
		let quietPeriod: TimeInterval = 0.12
		let currentKey = AgentTranscriptRehydrateRetryKey(
			tabID: tabID,
			presentationRevision: revision,
			layoutPassToken: layoutPassToken
		)

		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: currentKey,
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: layoutPassToken,
				distanceToBottom: 0,
				strictBottomDistanceThreshold: 1,
				lastLayoutMutationAt: now.addingTimeInterval(-0.04),
				now: now,
				quietPeriod: quietPeriod
			)
		)
		XCTAssertTrue(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: currentKey,
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: layoutPassToken,
				distanceToBottom: 0,
				strictBottomDistanceThreshold: 1,
				lastLayoutMutationAt: now.addingTimeInterval(-0.20),
				now: now,
				quietPeriod: quietPeriod
			)
		)
	}

	func testRehydrateRestoreLayoutPolicySchedulesWatchdogUntilMaxDriveDuration() throws {
		let startedAt = Date(timeIntervalSinceReferenceDate: 100)
		let maxDuration: TimeInterval = 1.25
		let watchdogDelay: TimeInterval = 0.08

		let initialDelay = try XCTUnwrap(
			AgentTranscriptRehydrateRestoreLayoutPolicy.watchdogSettleDelay(
				startedAt: startedAt,
				now: startedAt.addingTimeInterval(0.20),
				maxDuration: maxDuration,
				watchdogDelay: watchdogDelay
			)
		)
		XCTAssertEqual(initialDelay, watchdogDelay)

		let boundedDelay = try XCTUnwrap(
			AgentTranscriptRehydrateRestoreLayoutPolicy.watchdogSettleDelay(
				startedAt: startedAt,
				now: startedAt.addingTimeInterval(1.23),
				maxDuration: maxDuration,
				watchdogDelay: watchdogDelay
			)
		)
		XCTAssertEqual(boundedDelay, 0.02, accuracy: 0.001)
		XCTAssertNil(
			AgentTranscriptRehydrateRestoreLayoutPolicy.watchdogSettleDelay(
				startedAt: startedAt,
				now: startedAt.addingTimeInterval(maxDuration),
				maxDuration: maxDuration,
				watchdogDelay: watchdogDelay
			)
		)
	}

	func testRehydrateRestoreLayoutPolicyStopsContinuingAtMaxDriveDuration() {
		let startedAt = Date(timeIntervalSinceReferenceDate: 100)

		XCTAssertTrue(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canContinueLiveBottomRestore(
				startedAt: startedAt,
				correctionCount: 0,
				maxDuration: 1.25,
				maxCorrectionCount: 3,
				now: startedAt.addingTimeInterval(1.0)
			)
		)
		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canContinueLiveBottomRestore(
				startedAt: startedAt,
				correctionCount: 0,
				maxDuration: 1.25,
				maxCorrectionCount: 3,
				now: startedAt.addingTimeInterval(1.25)
			)
		)
	}

	func testPresentationSnapshotRawPayloadOnlyRevisionChangeIsScrollAffectingButNotVisible() {
		let baseline = AgentTranscriptPresentationSnapshot(rawToolResultPayloadRenderRevision: 1)
		let updated = AgentTranscriptPresentationSnapshot(rawToolResultPayloadRenderRevision: 2)

		XCTAssertFalse(updated.hasVisiblePresentationDelta(comparedTo: baseline))
		XCTAssertTrue(updated.hasScrollAffectingPresentationDelta(comparedTo: baseline))
	}

	func testPresentationSnapshotScrollAffectingKeyIncludesRawPayloadRevision() {
		let baseline = AgentTranscriptPresentationSnapshot(revision: 7, rawToolResultPayloadRenderRevision: 1)
		let updated = AgentTranscriptPresentationSnapshot(revision: 7, rawToolResultPayloadRenderRevision: 2)

		XCTAssertNotEqual(baseline.scrollAffectingPresentationKey, updated.scrollAffectingPresentationKey)
	}

	func testRehydrateRestoreLayoutPolicyRejectsPreArmLayoutPassSampleUntilFreshSample() {
		let tabID = UUID()
		let revision = 12
		let staleLayoutPassToken: UInt64 = 8
		let currentLayoutPassToken: UInt64 = 9
		let now = Date(timeIntervalSinceReferenceDate: 100)
		let quietPeriod: TimeInterval = 0.12
		let strictBottomDistance: CGFloat = 1
		let staleSample = AgentTranscriptRehydrateRetryKey(
			tabID: tabID,
			presentationRevision: revision,
			layoutPassToken: staleLayoutPassToken
		)
		let freshSample = AgentTranscriptRehydrateRetryKey(
			tabID: tabID,
			presentationRevision: revision,
			layoutPassToken: currentLayoutPassToken
		)

		XCTAssertTrue(
			AgentTranscriptRehydrateRestoreLayoutPolicy.hasValidLayoutSample(
				makeScrollMetrics(contentHeight: 500, viewportHeight: 280)
			)
		)
		XCTAssertFalse(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: staleSample,
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: currentLayoutPassToken,
				distanceToBottom: 0,
				strictBottomDistanceThreshold: strictBottomDistance,
				lastLayoutMutationAt: nil,
				now: now,
				quietPeriod: quietPeriod
			)
		)
		XCTAssertTrue(
			AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
				currentLayoutSampleKey: freshSample,
				tabID: tabID,
				presentationRevision: revision,
				layoutPassToken: currentLayoutPassToken,
				distanceToBottom: 0,
				strictBottomDistanceThreshold: strictBottomDistance,
				lastLayoutMutationAt: nil,
				now: now,
				quietPeriod: quietPeriod
			)
		)
	}

	func testActivationRepaintRemountPolicyFiresForHydratedTabActivation() throws {
		let currentTabID = UUID()
		let previousTabID = UUID()
		let key = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
			oldSignal: makeRestoreSignal(tabID: previousTabID, hydrated: true, revision: 4),
			newSignal: makeRestoreSignal(tabID: currentTabID, hydrated: true, revision: 9),
			currentTabID: currentTabID,
			rehydratePhase: .awaitingHydration(tabID: currentTabID, target: .liveBottom),
			lastRemountKey: nil,
			remountCount: 0,
			layoutPassToken: 12
		)

		let unwrappedKey = try XCTUnwrap(key)
		XCTAssertEqual(unwrappedKey.tabID, currentTabID)
		XCTAssertEqual(unwrappedKey.presentationRevision, 9)
		XCTAssertEqual(unwrappedKey.layoutPassToken, 12)
	}

	func testActivationRepaintRemountPolicyFiresWhenLoadingSignalBecomesHydrated() throws {
		let tabID = UUID()
		let key = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
			oldSignal: makeRestoreSignal(tabID: tabID, hydrated: false, revision: 1),
			newSignal: makeRestoreSignal(tabID: tabID, hydrated: true, revision: 1),
			currentTabID: tabID,
			rehydratePhase: .awaitingHydration(tabID: tabID, target: .liveBottom),
			lastRemountKey: nil,
			remountCount: 0,
			layoutPassToken: 3
		)

		XCTAssertEqual(key, AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 1, layoutPassToken: 3))
	}

	func testActivationRepaintRemountPolicyFiresForRepairRevisionWhileAwaitingLayout() throws {
		let tabID = UUID()
		let key = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
			oldSignal: makeRestoreSignal(tabID: tabID, hydrated: true, revision: 6),
			newSignal: makeRestoreSignal(tabID: tabID, hydrated: true, revision: 7),
			currentTabID: tabID,
			rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 6, target: .liveBottom),
			lastRemountKey: nil,
			remountCount: 1,
			layoutPassToken: 44
		)

		XCTAssertEqual(key, AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 7, layoutPassToken: 44))
	}

	func testActivationRepaintRemountPolicyDoesNotFireForNormalIdleStreamingRevisionChange() {
		let tabID = UUID()
		let key = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
			oldSignal: makeRestoreSignal(tabID: tabID, hydrated: true, revision: 20),
			newSignal: makeRestoreSignal(tabID: tabID, hydrated: true, revision: 21),
			currentTabID: tabID,
			rehydratePhase: .idle,
			lastRemountKey: nil,
			remountCount: 0,
			layoutPassToken: 1
		)

		XCTAssertNil(key)
	}

	func testActivationRepaintRemountPolicySuppressesDuplicateAndBudgetExhaustion() {
		let tabID = UUID()
		let duplicateKey = AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 2, layoutPassToken: 5)

		XCTAssertNil(
			AgentTranscriptActivationRepaintRemountPolicy.remountKey(
				oldSignal: makeRestoreSignal(tabID: tabID, hydrated: false, revision: 2),
				newSignal: makeRestoreSignal(tabID: tabID, hydrated: true, revision: 2),
				currentTabID: tabID,
				rehydratePhase: .awaitingHydration(tabID: tabID, target: .liveBottom),
				lastRemountKey: duplicateKey,
				remountCount: 1,
				layoutPassToken: 6
			)
		)
		XCTAssertNil(
			AgentTranscriptActivationRepaintRemountPolicy.remountKey(
				oldSignal: makeRestoreSignal(tabID: tabID, hydrated: true, revision: 2),
				newSignal: makeRestoreSignal(tabID: tabID, hydrated: true, revision: 3),
				currentTabID: tabID,
				rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 2, target: .liveBottom),
				lastRemountKey: nil,
				remountCount: AgentTranscriptActivationRepaintRemountPolicy.maximumRemountsPerActivation,
				layoutPassToken: 6
			)
		)
	}

	func testActivationRepaintRemountPolicyDoesNotFireForDetachedRestoreTarget() {
		let tabID = UUID()
		let key = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
			oldSignal: makeRestoreSignal(tabID: tabID, hydrated: false, revision: 2),
			newSignal: makeRestoreSignal(tabID: tabID, hydrated: true, revision: 2),
			currentTabID: tabID,
			rehydratePhase: .awaitingHydration(tabID: tabID, target: .detached(nil)),
			lastRemountKey: nil,
			remountCount: 0,
			layoutPassToken: 6
		)

		XCTAssertNil(key)
	}

	func testBottomScrollOutcomeLayoutPolicyDetectsMaterialContentOrViewportMutation() {
		XCTAssertTrue(
			AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
				oldMetrics: makeScrollMetrics(contentHeight: 400, viewportHeight: 280),
				newMetrics: makeScrollMetrics(contentHeight: 402, viewportHeight: 280),
				contentHeightThreshold: 1,
				viewportHeightThreshold: 1
			)
		)
		XCTAssertTrue(
			AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
				oldMetrics: makeScrollMetrics(contentHeight: 400, viewportHeight: 280),
				newMetrics: makeScrollMetrics(contentHeight: 400, viewportHeight: 282),
				contentHeightThreshold: 1,
				viewportHeightThreshold: 1
			)
		)
	}

	func testBottomScrollOutcomeLayoutPolicyIgnoresSubthresholdMutationAndExpiresQuietPeriod() throws {
		XCTAssertFalse(
			AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
				oldMetrics: makeScrollMetrics(contentHeight: 400, viewportHeight: 280),
				newMetrics: makeScrollMetrics(contentHeight: 400.4, viewportHeight: 280.4),
				contentHeightThreshold: 1,
				viewportHeightThreshold: 1
			)
		)

		let now = Date(timeIntervalSinceReferenceDate: 100)
		let activeDelay = AgentTranscriptBottomScrollOutcomeLayoutPolicy.remainingQuietDelay(
			lastLayoutMutationAt: now.addingTimeInterval(-0.04),
			now: now,
			quietPeriod: 0.12
		)
		let unwrappedActiveDelay = try XCTUnwrap(activeDelay)
		XCTAssertEqual(unwrappedActiveDelay, 0.08, accuracy: 0.001)
		XCTAssertNil(
			AgentTranscriptBottomScrollOutcomeLayoutPolicy.remainingQuietDelay(
				lastLayoutMutationAt: now.addingTimeInterval(-0.20),
				now: now,
				quietPeriod: 0.12
			)
		)
	}

	func testBottomAffordanceStateOnlyFlipsAtThresholdCrossings() {
		var state = AgentTranscriptBottomAffordanceState(isNearBottom: true)

		XCTAssertFalse(state.update(distanceToBottom: 12, threshold: 24))
		XCTAssertTrue(state.isNearBottom)

		XCTAssertTrue(state.update(distanceToBottom: 36, threshold: 24))
		XCTAssertFalse(state.isNearBottom)

		XCTAssertFalse(state.update(distanceToBottom: 48, threshold: 24))
		XCTAssertFalse(state.isNearBottom)

		XCTAssertTrue(state.update(distanceToBottom: 8, threshold: 24))
		XCTAssertTrue(state.isNearBottom)
	}

	func testBottomAffordanceStateDoesNotReportRedundantChanges() {
		var state = AgentTranscriptBottomAffordanceState(isNearBottom: false)

		XCTAssertFalse(state.update(distanceToBottom: 64, threshold: 24))
		XCTAssertFalse(state.update(distanceToBottom: 30, threshold: 24))
		XCTAssertFalse(state.isNearBottom)

		XCTAssertTrue(state.update(distanceToBottom: 24, threshold: 24))
		XCTAssertTrue(state.isNearBottom)
		XCTAssertFalse(state.update(distanceToBottom: 0, threshold: 24))
	}

	func testIdleBoundaryProgressResolverPrefersActiveUserScrollSession() {
		let now = Date(timeIntervalSinceReferenceDate: 100)
		let activeSession = AgentTranscriptUserScrollSession(
			startedAt: now.addingTimeInterval(-0.3),
			baselineMetrics: makeScrollMetrics(distanceToBottom: 0, visibleMinY: 10, contentHeight: 400, viewportHeight: 280),
			latestMetrics: makeScrollMetrics(distanceToBottom: 12, visibleMinY: 26, contentHeight: 412, viewportHeight: 280),
			latestIntent: .towardHistory,
			lastIntentAt: now.addingTimeInterval(-0.1),
			observedProgress: true
		)
		let completedSession = AgentTranscriptCompletedUserScrollSession(
			startedAt: now.addingTimeInterval(-1),
			endedAt: now.addingTimeInterval(-0.2),
			baselineMetrics: makeScrollMetrics(distanceToBottom: 0, visibleMinY: 0, contentHeight: 400, viewportHeight: 280),
			finalMetrics: makeScrollMetrics(distanceToBottom: 40, visibleMinY: 40, contentHeight: 440, viewportHeight: 280),
			latestIntent: .towardLiveBottom,
			observedProgress: true
		)

		let resolved = AgentTranscriptIdleBoundaryProgressResolver.resolve(
			activeSession: activeSession,
			lastCompletedSession: completedSession,
			currentMetrics: makeScrollMetrics(distanceToBottom: 18, visibleMinY: 32, contentHeight: 418, viewportHeight: 280),
			now: now,
			freshnessWindow: 1.0
		)

		XCTAssertEqual(resolved?.hasTowardHistoryManualIntent, true)
		XCTAssertEqual(resolved?.progress.baselineDistanceToBottom, 0)
		XCTAssertEqual(resolved?.progress.currentDistanceToBottom, 18)
		XCTAssertEqual(resolved?.progress.baselineVisibleMinY, 10)
		XCTAssertEqual(resolved?.progress.currentVisibleMinY, 26)
	}

	func testIdleBoundaryProgressResolverFallsBackToFreshCompletedSessionAndExpiresStaleSessions() {
		let now = Date(timeIntervalSinceReferenceDate: 100)
		let freshCompletedSession = AgentTranscriptCompletedUserScrollSession(
			startedAt: now.addingTimeInterval(-0.8),
			endedAt: now.addingTimeInterval(-0.15),
			baselineMetrics: makeScrollMetrics(distanceToBottom: 0, visibleMinY: 10, contentHeight: 400, viewportHeight: 280),
			finalMetrics: makeScrollMetrics(distanceToBottom: 16, visibleMinY: 24, contentHeight: 416, viewportHeight: 280),
			latestIntent: .towardHistory,
			observedProgress: true
		)

		let freshResolved = AgentTranscriptIdleBoundaryProgressResolver.resolve(
			activeSession: nil,
			lastCompletedSession: freshCompletedSession,
			currentMetrics: makeScrollMetrics(distanceToBottom: 20, visibleMinY: 30, contentHeight: 420, viewportHeight: 280),
			now: now,
			freshnessWindow: 0.5
		)
		XCTAssertEqual(freshResolved?.hasTowardHistoryManualIntent, true)
		XCTAssertEqual(freshResolved?.progress.baselineVisibleMinY, 10)
		XCTAssertEqual(freshResolved?.progress.currentVisibleMinY, 24)

		let staleResolved = AgentTranscriptIdleBoundaryProgressResolver.resolve(
			activeSession: nil,
			lastCompletedSession: freshCompletedSession,
			currentMetrics: makeScrollMetrics(distanceToBottom: 20, visibleMinY: 30, contentHeight: 420, viewportHeight: 280),
			now: now.addingTimeInterval(1.0),
			freshnessWindow: 0.5
		)
		XCTAssertNil(staleResolved)
	}

	func testIdleBoundaryProgressResolverUsesRecordedSessionMetricsWhenCurrentMetricsRegress() {
		let now = Date(timeIntervalSinceReferenceDate: 100)
		let completedSession = AgentTranscriptCompletedUserScrollSession(
			startedAt: now.addingTimeInterval(-0.8),
			endedAt: now.addingTimeInterval(-0.1),
			baselineMetrics: makeScrollMetrics(distanceToBottom: 0, visibleMinY: 20, contentHeight: 400, viewportHeight: 280),
			finalMetrics: makeScrollMetrics(distanceToBottom: 14, visibleMinY: 6, contentHeight: 414, viewportHeight: 280),
			latestIntent: .towardHistory,
			observedProgress: true
		)

		let resolved = AgentTranscriptIdleBoundaryProgressResolver.resolve(
			activeSession: nil,
			lastCompletedSession: completedSession,
			currentMetrics: makeScrollMetrics(distanceToBottom: 4, visibleMinY: 18, contentHeight: 404, viewportHeight: 280),
			now: now,
			freshnessWindow: 0.5
		)

		XCTAssertEqual(resolved?.progress.currentDistanceToBottom, 14)
		XCTAssertEqual(resolved?.progress.currentVisibleMinY, 6)
	}

	func testPinnedMaintenanceStateInvalidateAdvancesGenerationAndClearsRequests() {
		var state = PinnedMaintenanceState()
		let initialGeneration = state.generation
		state.pendingRequest = state.makeRequest(source: .transcriptChangeWhilePinned)
		state.deferredRequestAfterSmoothSend = state.makeRequest(source: .bottomClearanceChange)

		state.invalidate(reason: .detached)

		XCTAssertEqual(state.generation, initialGeneration + 1)
		XCTAssertNil(state.pendingRequest)
		XCTAssertNil(state.deferredRequestAfterSmoothSend)
		XCTAssertFalse(state.isCurrent(.init(source: .transcriptChangeWhilePinned, generation: initialGeneration, requestedAt: Date())))
	}

	func testBottomScrollOutcomeStatePrepareForNewPendingOutcomeCancelsDeferredTaskAndClearsTracking() {
		let task = Task<Void, Never> {}
		var state = BottomScrollOutcomeState(
			pendingOutcome: nil,
			lastLayoutMutationAt: Date(timeIntervalSinceReferenceDate: 50),
			generationToken: 2,
			deferredResolveTask: task
		)

		state.prepareForNewPendingOutcome()

		XCTAssertEqual(state.generationToken, 3)
		XCTAssertNil(state.lastLayoutMutationAt)
		XCTAssertNil(state.deferredResolveTask)
		XCTAssertTrue(task.isCancelled)
	}

	func testBottomScrollOutcomeStateResetClearsPendingOutcomeAndCancelsDeferredTask() {
		let task = Task<Void, Never> {}
		var pendingOutcome = PendingBottomScrollOutcome(
			tabID: UUID(),
			startedAt: Date(timeIntervalSinceReferenceDate: 100),
			baselineDistanceToBottom: 24,
			source: .explicitBottomAction
		)
		pendingOutcome.didExecute = true
		var state = BottomScrollOutcomeState(
			pendingOutcome: pendingOutcome,
			lastLayoutMutationAt: Date(timeIntervalSinceReferenceDate: 110),
			generationToken: 4,
			deferredResolveTask: task
		)

		state.reset()

		XCTAssertNil(state.pendingOutcome)
		XCTAssertNil(state.lastLayoutMutationAt)
		XCTAssertNil(state.deferredResolveTask)
		XCTAssertEqual(state.generationToken, 5)
		XCTAssertTrue(task.isCancelled)
	}

	func testMarkdownStreamingCompilePolicyImmediateCadenceCompilesImmediately() {
		let now = Date(timeIntervalSinceReferenceDate: 100)
		let requested = markdownSignature(text: "# Hello")

		let decision = MarkdownStreamingCompilePolicy.decision(
			cadence: .immediate,
			hasCompiledText: true,
			lastPublishedSignature: nil,
			requestedSignature: requested,
			lastPublishedAt: now,
			now: now
		)

		XCTAssertEqual(decision, .compileNow)
	}

	func testMarkdownStreamingCompilePolicyCompilesImmediatelyWithoutExistingRender() {
		let now = Date(timeIntervalSinceReferenceDate: 100)
		let requested = markdownSignature(text: "# Hello")

		let decision = MarkdownStreamingCompilePolicy.decision(
			cadence: .streamingCoalesced,
			hasCompiledText: false,
			lastPublishedSignature: nil,
			requestedSignature: requested,
			lastPublishedAt: nil,
			now: now
		)

		XCTAssertEqual(decision, .compileNow)
	}

	func testMarkdownStreamingCompilePolicyCoalescesAppendWithinMinimumInterval() {
		let previous = markdownSignature(text: "# Hello")
		let requested = markdownSignature(text: "# Hello\n\nMore detail")
		let lastPublishedAt = Date(timeIntervalSinceReferenceDate: 100)
		let now = lastPublishedAt.addingTimeInterval(0.05)

		let decision = MarkdownStreamingCompilePolicy.decision(
			cadence: .streamingCoalesced,
			hasCompiledText: true,
			lastPublishedSignature: previous,
			requestedSignature: requested,
			lastPublishedAt: lastPublishedAt,
			now: now
		)

		guard case .compileAfter(let delay) = decision else {
			return XCTFail("Expected delayed compile, got \(decision)")
		}
		XCTAssertEqual(delay, 0.15, accuracy: 0.001)
	}

	func testMarkdownStreamingCompilePolicyCompilesImmediatelyForNonAppendRewrite() {
		let previous = markdownSignature(text: "# Hello")
		let requested = markdownSignature(text: "# Rewritten")
		let now = Date(timeIntervalSinceReferenceDate: 100)

		let decision = MarkdownStreamingCompilePolicy.decision(
			cadence: .streamingCoalesced,
			hasCompiledText: true,
			lastPublishedSignature: previous,
			requestedSignature: requested,
			lastPublishedAt: now.addingTimeInterval(-0.05),
			now: now
		)

		XCTAssertEqual(decision, .compileNow)
	}

	func testMarkdownStreamingCompilePolicyDoesNotCoalesceAppendAfterUnpublishedRewrite() {
		let published = markdownSignature(text: "# Hello")
		let rewritten = markdownSignature(text: "## Rewritten")
		let appendedRewrite = markdownSignature(text: "## Rewritten\n\nTail")
		let now = Date(timeIntervalSinceReferenceDate: 100)

		let rewriteDecision = MarkdownStreamingCompilePolicy.decision(
			cadence: .streamingCoalesced,
			hasCompiledText: true,
			lastPublishedSignature: published,
			requestedSignature: rewritten,
			lastPublishedAt: now.addingTimeInterval(-0.05),
			now: now
		)
		XCTAssertEqual(rewriteDecision, .compileNow)

		let appendDecision = MarkdownStreamingCompilePolicy.decision(
			cadence: .streamingCoalesced,
			hasCompiledText: true,
			lastPublishedSignature: published,
			requestedSignature: appendedRewrite,
			lastPublishedAt: now.addingTimeInterval(-0.02),
			now: now
		)
		XCTAssertEqual(appendDecision, .compileNow)
	}

	func testMarkdownStreamingCompilePolicySkipsAlreadyPublishedSignature() {
		let published = markdownSignature(text: "# Final")
		let now = Date(timeIntervalSinceReferenceDate: 100)

		let decision = MarkdownStreamingCompilePolicy.decision(
			cadence: .streamingCoalesced,
			hasCompiledText: true,
			lastPublishedSignature: published,
			requestedSignature: published,
			lastPublishedAt: now,
			now: now
		)

		XCTAssertEqual(decision, .skip)
	}

	func testMarkdownStreamingCompilePolicyLargeAppendWaitsForGrowthThreshold() {
		let previous = markdownSignature(text: repeatedMarkdownLine("large", count: 160))
		let requested = markdownSignature(text: previous.text + String(repeating: "tail ", count: 20) + "\nnext")
		let now = Date(timeIntervalSinceReferenceDate: 100)

		let decision = MarkdownStreamingCompilePolicy.decision(
			cadence: .streamingCoalesced,
			hasCompiledText: true,
			lastPublishedSignature: previous,
			requestedSignature: requested,
			lastPublishedAt: now.addingTimeInterval(-0.40),
			now: now
		)

		XCTAssertEqual(decision, .compileAfter(0.18))
	}

	func testMarkdownStreamingCompilePolicyLargeAppendCompilesOnceGrowthThresholdIsReached() {
		let previous = markdownSignature(text: repeatedMarkdownLine("large", count: 160))
		let requested = markdownSignature(text: previous.text + String(repeating: "growth ", count: 60))
		let now = Date(timeIntervalSinceReferenceDate: 100)

		let decision = MarkdownStreamingCompilePolicy.decision(
			cadence: .streamingCoalesced,
			hasCompiledText: true,
			lastPublishedSignature: previous,
			requestedSignature: requested,
			lastPublishedAt: now.addingTimeInterval(-0.40),
			now: now
		)

		XCTAssertEqual(decision, .compileNow)
	}

	func testMarkdownStreamingCompilePolicyExtremeAppendCompilesWhenNewlineThresholdIsReached() {
		let previous = markdownSignature(text: repeatedMarkdownLine("extreme", count: 1_050))
		let requested = markdownSignature(text: previous.text + String(repeating: "\nextra line", count: 26))
		let now = Date(timeIntervalSinceReferenceDate: 100)

		let decision = MarkdownStreamingCompilePolicy.decision(
			cadence: .streamingCoalesced,
			hasCompiledText: true,
			lastPublishedSignature: previous,
			requestedSignature: requested,
			lastPublishedAt: now.addingTimeInterval(-0.60),
			now: now
		)

		XCTAssertEqual(decision, .compileNow)
	}

	func testMarkdownStreamingSegmentationPolicyPromotesToSegmentedRendererOnceStreamingTextBecomesExtreme() {
		let initialText = repeatedMarkdownLine("stream", count: 60)
		let grownText = initialText + "\n\n" + largeStreamingMarkdownText(sectionCount: 40, closeFences: true)

		XCTAssertFalse(
			MarkdownStreamingSegmentationPolicy.shouldUseSegmentedRenderer(
				isMarkdown: true,
				allowsStreamingSegmentation: true,
				renderCadence: .streamingCoalesced,
				text: initialText
			)
		)
		XCTAssertTrue(
			MarkdownStreamingSegmentationPolicy.shouldUseSegmentedRenderer(
				isMarkdown: true,
				allowsStreamingSegmentation: true,
				renderCadence: .streamingCoalesced,
				text: grownText
			)
		)
	}

	func testMarkdownStreamingFreezeBoundaryResolverFindsSafeBoundaryForLargeStreamingMarkdown() throws {
		let text = largeStreamingMarkdownText(sectionCount: 40, closeFences: true)
		let boundary = try XCTUnwrap(MarkdownStreamingFreezeBoundaryResolver.resolveBoundary(in: text))

		XCTAssertGreaterThanOrEqual(boundary.prefixCharacterCount, MarkdownStreamingFreezeBoundaryResolver.minimumPrefixCharacterCount)
		XCTAssertGreaterThanOrEqual(boundary.tailCharacterCount, MarkdownStreamingFreezeBoundaryResolver.minimumTailCharacterCount)
		XCTAssertGreaterThanOrEqual(boundary.tailLineCount, MarkdownStreamingFreezeBoundaryResolver.minimumTailLineCount)
		let segments = try XCTUnwrap(MarkdownStreamingFreezeBoundaryResolver.split(text: text, atUTF16Offset: boundary.utf16Offset))
		XCTAssertFalse(segments.prefix.isEmpty)
		XCTAssertFalse(segments.tail.isEmpty)
	}

	func testMarkdownStreamingFreezeBoundaryResolverRejectsBoundariesInsideOpenFence() {
		let intro = repeatedMarkdownLine("prefix", count: 40)
		let openFenceBody = String(repeating: "code line\n\n", count: 1_400)
		let text = intro + "\n\n```swift\n" + openFenceBody

		XCTAssertNil(MarkdownStreamingFreezeBoundaryResolver.resolveBoundary(in: text))
	}

	private func makeRestoreSignal(
		tabID: UUID?,
		hydrated: Bool,
		revision: Int
	) -> AgentTranscriptRestoreSignal {
		AgentTranscriptRestoreSignal(
			tabID: tabID,
			bindingsHydrated: hydrated,
			presentationRevision: revision
		)
	}

	private func makePinnedBottomRuntimeState(
		isPinnedToLiveBottom: Bool = true,
		isDetachedFromLiveBottom: Bool = false,
		isUserInteractingWithScroll: Bool = false,
		isInteractionBlocked: Bool = false,
		isRehydrateRestoreActive: Bool = false,
		distanceToBottom: CGFloat = 0
	) -> AgentTranscriptScrollRuntimeState {
		AgentTranscriptScrollRuntimeState(
			armingState: .armed,
			isPinnedToLiveBottom: isPinnedToLiveBottom,
			isDetachedFromLiveBottom: isDetachedFromLiveBottom,
			isUserInteractingWithScroll: isUserInteractingWithScroll,
			isInteractionBlocked: isInteractionBlocked,
			isRehydrateRestoreActive: isRehydrateRestoreActive,
			isProgrammaticScrollInFlight: false,
			canScrollTowardHistory: false,
			canScrollTowardLiveBottom: false,
			distanceToBottom: distanceToBottom
		)
	}

	private func makeScrollMetrics(
		distanceToBottom: CGFloat = 0,
		visibleMinY: CGFloat = 0,
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

	private func markdownSignature(text: String) -> MarkdownRenderSignature {
		MarkdownRenderSignature(
			text: text,
			fontSize: 16,
			forceTextColor: nil,
			useMonospaced: false
		)
	}

	private func repeatedMarkdownLine(_ seed: String, count: Int) -> String {
		(0..<count).map { index in
			"- \(seed) item \(index) keeps the streaming markdown body active."
		}.joined(separator: "\n")
	}

	private func largeStreamingMarkdownText(sectionCount: Int, closeFences: Bool) -> String {
		(1...sectionCount).map { index in
			var section = "## Section \(index)\n\n"
			section += "This is a large streaming markdown section that keeps the attributed renderer busy while the transcript remains pinned. It includes prose, lists, and fenced code to approximate the production stress case.\n\n"
			section += "- bullet one for section \(index)\n"
			section += "- bullet two for section \(index)\n"
			section += "  - nested detail for section \(index)\n"
			section += "  - additional nested detail for section \(index)\n\n"
			if index.isMultiple(of: 3) {
				section += "```swift\nlet section\(index) = \(index)\n"
				if closeFences {
					section += "print(section\(index))\n```\n\n"
				}
			}
			section += "The live tail should stay reasonably small once segmentation activates so the renderer is not recompiling the entire message for every append.\n\n"
			return section
		}.joined()
	}

	private func makeRenderBlock(
		id: String,
		turnID: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
		anchor: AgentTranscriptAnchor? = nil,
		kind: AgentTranscriptRenderBlockKind = .standaloneAssistant
	) -> AgentTranscriptRenderBlock {
		AgentTranscriptRenderBlock(
			id: id,
			kind: kind,
			turnID: turnID,
			retentionTier: .full,
			rows: [],
			isArchived: false,
			primaryAnchor: anchor
		)
	}
}
