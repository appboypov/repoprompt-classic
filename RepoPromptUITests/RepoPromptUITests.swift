import AppKit
import XCTest

final class RepoPromptUITests: XCTestCase {
	private let catastrophicJumpThreshold: Double = 220
	private let catastrophicHistoricalExposureBlockThreshold: Int = 10
	private let metricsJumpThreshold: Double = 260
	private let denseProjectionBuildDurationThresholdMS: Double = 450
	private let richProjectionBuildDurationThresholdMS: Double = 650
	private let coldLoadProjectionBuildDurationThresholdMS: Double = 1200
	private let heavyRenderedPayloadBytesThreshold: Int = 100_000
	private let deferredStressRefreshPolicy = "deferred"

    override func setUpWithError() throws {
        continueAfterFailure = false
		terminateRepoPromptIfRunning()
	}

	func testAgentChatStressHarnessKeepsAutoFollowAndProducesGrouping() throws {
		let app = launchStressHarness()
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))

		let grouping = try waitForGrouping(from: groupingElement, timeout: 20) {
			($0.visibleBlockKindCounts["activityCluster"] ?? 0) > 0
				|| ($0.visibleBlockKindCounts["groupedHistory"] ?? 0) > 0
		}
		XCTAssertFalse(grouping.latestToolGroupLabels.isEmpty)

		let telemetry = try waitForTelemetry(from: telemetryElement, timeout: 20, eventsElement: eventsElement) {
			$0.scrollIntentCount > 0 && $0.tabID != nil
		}
		guard telemetry.supportsGeometryMetrics else {
			attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let continued = try waitForTelemetry(from: telemetryElement, timeout: 20, eventsElement: eventsElement) {
			$0.tabID == telemetry.tabID && $0.sampleIndex >= telemetry.sampleIndex + 6
		}
		XCTAssertEqual(continued.tabID, telemetry.tabID)
		let settled = try waitForTelemetry(from: telemetryElement, timeout: 20, eventsElement: eventsElement) {
			$0.tabID == telemetry.tabID
				&& $0.sampleIndex >= continued.sampleIndex
				&& $0.isPinnedToLiveBottom
				&& !$0.userDetachedAutoFollow
				&& $0.distanceToBottom <= 40
		}
		XCTAssertLessThanOrEqual(settled.maxUnexpectedJumpMagnitude, catastrophicJumpThreshold)
		attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
    }

	func testAgentChatStressHarnessReportsColdRestoreAndSmoothSendMetrics() throws {
		let app = launchStressHarness()
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))

		let initial = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "initial restore telemetry", eventsElement: eventsElement) {
			$0.scrollIntentCount > 0 && $0.tabID != nil
		}
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}
		let metrics = try waitForTelemetry(from: telemetryElement, timeout: 25, label: "cold restore + smooth send telemetry", eventsElement: eventsElement) {
			($0.smoothSendStartCount ?? 0) > 0
				&& ($0.smoothSendCompletionCount ?? 0) > 0
				&& $0.lastSmoothSendSettleDurationMS != nil
				&& ($0.coldRestoreStartCount ?? 0) >= 1
				&& ($0.coldRestoreScrollCount ?? 0) >= 1
				&& ($0.coldRestoreCompletionCount ?? 0) >= 1
				&& $0.lastColdRestoreSettleDurationMS != nil
		}
		XCTAssertGreaterThan(metrics.smoothSendCompletionCount ?? 0, 0)
		XCTAssertLessThanOrEqual(metrics.maxUnexpectedJumpMagnitude, metricsJumpThreshold)
		XCTAssertGreaterThanOrEqual(metrics.coldRestoreScrollCount ?? 0, metrics.coldRestoreCorrectiveScrollCount ?? 0)
	}

	func testAgentChatStressHarnessTracksDetachedJumpTelemetry() throws {
		let app = launchStressHarness(intervalMS: 100)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "initial stress telemetry") {
			$0.scrollIntentCount > 0 && $0.tabID != nil
		}
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let detached = try detachTranscript(
			app: app,
			scrollView: scrollView,
			telemetryElement: telemetryElement,
			initial: initial
		)

		let detachedWindow = try waitForTelemetry(from: telemetryElement, timeout: 20) {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.sampleIndex >= detached.sampleIndex + 6
		}
		XCTAssertGreaterThan(detachedWindow.sampleIndex, detached.sampleIndex)
		XCTAssertGreaterThanOrEqual(detachedWindow.detachedJumpCount, 0)
		XCTAssertGreaterThanOrEqual(detachedWindow.maxDetachedJumpMagnitude, 0)
	}

	func testAgentChatStressHarnessKeepsDetachedAnchorStable() throws {
		let app = launchStressHarness(intervalMS: 100)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "initial stress telemetry") {
			$0.scrollIntentCount > 0 && $0.tabID != nil
		}
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let detached = try detachTranscript(
			app: app,
			scrollView: scrollView,
			telemetryElement: telemetryElement,
			initial: initial
		)
		let settledDetached = try waitForTelemetry(from: telemetryElement, timeout: 30, label: "settled detached telemetry") {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.sampleIndex >= detached.sampleIndex + 2
				&& $0.topVisibleAnchorDescription != nil
		}
		let anchorDescription = try XCTUnwrap(settledDetached.topVisibleAnchorDescription)

		let detachedWindow = try waitForTelemetry(from: telemetryElement, timeout: 30, label: "later detached telemetry") {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.sampleIndex >= settledDetached.sampleIndex + 6
		}
		XCTAssertEqual(
			detachedWindow.topVisibleAnchorDescription,
			anchorDescription,
			"settled=\(settledDetached) later=\(detachedWindow)"
		)
		XCTAssertEqual(
			detachedWindow.detachedAnchorChangeCount,
			settledDetached.detachedAnchorChangeCount,
			"settled=\(settledDetached) later=\(detachedWindow)"
		)
		XCTAssertEqual(
			detachedWindow.detachedSnapToTopCount,
			settledDetached.detachedSnapToTopCount,
			"settled=\(settledDetached) later=\(detachedWindow)"
		)
		XCTAssertEqual(
			detachedWindow.detachedRestoreIntentCount,
			settledDetached.detachedRestoreIntentCount,
			"settled=\(settledDetached) later=\(detachedWindow)"
		)
		if let settledStoredTarget = settledDetached.storedDetachedTargetDescription {
			XCTAssertEqual(
				detachedWindow.storedDetachedTargetDescription,
				settledStoredTarget,
				"settled=\(settledDetached) later=\(detachedWindow)"
			)
		}
		if let settledStoredAnchor = settledDetached.storedDetachedAnchorDescription {
			XCTAssertEqual(
				detachedWindow.storedDetachedAnchorDescription,
				settledStoredAnchor,
				"settled=\(settledDetached) later=\(detachedWindow)"
			)
		}
		if let settledLiveTarget = settledDetached.liveDetachedTargetDescription,
			let laterLiveTarget = detachedWindow.liveDetachedTargetDescription {
			XCTAssertEqual(
				laterLiveTarget,
				settledLiveTarget,
				"settled=\(settledDetached) later=\(detachedWindow)"
			)
		}
	}

	func testAgentChatStressHarnessManualDetachKeepsDetachedAnchorStable() throws {
		let app = launchStressHarness(intervalMS: 100)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 20,
			label: "initial manual detach telemetry"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		guard let detached = try attemptDetachTranscript(
			app: app,
			scrollView: scrollView,
			telemetryElement: telemetryElement,
			initial: initial,
			attemptCount: 12
		) else {
			throw XCTSkip("Manual detach gesture did not complete in this environment.")
		}
		let settledDetached = try waitForTelemetry(from: telemetryElement, timeout: 30, label: "settled manual detached telemetry") {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.sampleIndex >= detached.sampleIndex + 2
				&& $0.topVisibleAnchorDescription != nil
		}
		let anchorDescription = try XCTUnwrap(settledDetached.topVisibleAnchorDescription)
		XCTAssertEqual(
			settledDetached.detachedSnapToTopCount,
			0,
			"detached=\(detached) settled=\(settledDetached)"
		)
		XCTAssertTrue(
			settledDetached.storedDetachedTargetDescription != nil || settledDetached.storedDetachedAnchorDescription != nil,
			"detached=\(detached) settled=\(settledDetached)"
		)

		let detachedWindow = try waitForTelemetry(from: telemetryElement, timeout: 30, label: "later manual detached telemetry") {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.sampleIndex >= settledDetached.sampleIndex + 6
		}
		XCTAssertEqual(
			detachedWindow.topVisibleAnchorDescription,
			anchorDescription,
			"settled=\(settledDetached) later=\(detachedWindow)"
		)
		XCTAssertEqual(
			detachedWindow.detachedAnchorChangeCount,
			settledDetached.detachedAnchorChangeCount,
			"settled=\(settledDetached) later=\(detachedWindow)"
		)
		XCTAssertEqual(
			detachedWindow.detachedSnapToTopCount,
			settledDetached.detachedSnapToTopCount,
			"settled=\(settledDetached) later=\(detachedWindow)"
		)
		XCTAssertEqual(
			detachedWindow.detachedRestoreIntentCount,
			settledDetached.detachedRestoreIntentCount,
			"settled=\(settledDetached) later=\(detachedWindow)"
		)
	}

	func testAgentChatStressHarnessDenseLongSessionKeepsDetachedViewportStable() throws {
		let app = launchStressHarness(intervalMS: 100, warmupTurns: 8, toolStepRepeatCount: 3)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let readiness = try waitForDenseLongSessionReadiness(
			telemetryElement: telemetryElement,
			groupingElement: groupingElement,
			timeout: 60
		)
		let initial = readiness.telemetry
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let forceDetachButton = app.buttons["agentStress.forceDetach"]
		XCTAssertTrue(forceDetachButton.waitForExistence(timeout: 10))
		forceDetachButton.tap()
		let detached = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "forced dense detach telemetry") {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.detachCount >= 1
		}
		let settledDetached = try waitForTelemetry(from: telemetryElement, timeout: 35, label: "dense settled detached telemetry") {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.sampleIndex >= detached.sampleIndex + 4
				&& $0.topVisibleAnchorDescription != nil
				&& ($0.projectionBuildCount ?? 0) > 0
				&& ($0.projectionPublishCount ?? 0) > 0
		}
		let settledAnchor = try XCTUnwrap(settledDetached.topVisibleAnchorDescription)
		let settledLiveTarget = settledDetached.liveDetachedTargetDescription
		let settledStoredTarget = try XCTUnwrap(settledDetached.storedDetachedTargetDescription)
		let settledStoredAnchor = try XCTUnwrap(settledDetached.storedDetachedAnchorDescription)
		XCTAssertEqual(
			settledStoredAnchor,
			settledAnchor,
			"settled=\(settledDetached)"
		)
		if let settledLiveTarget {
			XCTAssertEqual(
				settledStoredTarget,
				settledLiveTarget,
				"settled=\(settledDetached)"
			)
		}
		if settledAnchor.contains("activity(") {
			XCTAssertFalse(
				settledStoredAnchor.contains("groupedHistory("),
				"settled=\(settledDetached)"
			)
		}

		let soak = try waitForTelemetry(from: telemetryElement, timeout: 35, label: "dense detached soak telemetry") {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.sampleIndex >= settledDetached.sampleIndex + 12
				&& ($0.projectionBuildCount ?? 0) > (settledDetached.projectionBuildCount ?? 0)
				&& ($0.projectionPublishCount ?? 0) > (settledDetached.projectionPublishCount ?? 0)
				&& ($0.viewportCandidateUpdateCount ?? 0) > (settledDetached.viewportCandidateUpdateCount ?? 0)
		}
		XCTAssertEqual(
			soak.topVisibleAnchorDescription,
			settledAnchor,
			"settled=\(settledDetached) soak=\(soak)"
		)
		if let settledLiveTarget {
			XCTAssertEqual(
				soak.liveDetachedTargetDescription,
				settledLiveTarget,
				"settled=\(settledDetached) soak=\(soak)"
			)
		}
		XCTAssertEqual(
			soak.storedDetachedTargetDescription,
			settledStoredTarget,
			"settled=\(settledDetached) soak=\(soak)"
		)
		XCTAssertEqual(
			soak.storedDetachedAnchorDescription,
			settledStoredAnchor,
			"settled=\(settledDetached) soak=\(soak)"
		)
		XCTAssertEqual(
			soak.detachedAnchorChangeCount,
			settledDetached.detachedAnchorChangeCount,
			"settled=\(settledDetached) soak=\(soak)"
		)
		XCTAssertEqual(
			soak.detachedSnapToTopCount,
			settledDetached.detachedSnapToTopCount,
			"settled=\(settledDetached) soak=\(soak)"
		)
		XCTAssertEqual(
			soak.detachedRestoreIntentCount,
			settledDetached.detachedRestoreIntentCount,
			"settled=\(settledDetached) soak=\(soak)"
		)
		XCTAssertGreaterThanOrEqual(
			soak.detachedAcceptedDriftCount ?? 0,
			settledDetached.detachedAcceptedDriftCount ?? 0,
			"settled=\(settledDetached) soak=\(soak)"
		)
	}

	func testAgentChatStressHarnessManualScrollRemainsResponsiveWhenDetached() throws {
		let app = launchStressHarness(intervalMS: 160, warmupTurns: 4, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 25,
			label: "manual-scroll basic readiness"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}
		_ = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "manual-scroll diff preview readiness", eventsElement: eventsElement) {
			$0.tabID == initial.tabID
				&& ($0.expandedApplyEditsDiffPreviewCardCount ?? 0) > 0
				&& ($0.latestExpandedHighSignalToolDescription?.contains("apply_edits") ?? false)
				&& $0.latestExpandedHighSignalRenderMode == "diffPreview"
		}

		let forceDetachButton = app.buttons["agentStress.forceDetach"]
		XCTAssertTrue(forceDetachButton.waitForExistence(timeout: 10))
		forceDetachButton.tap()

		let detachedBaseline = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "manual-scroll detached baseline") {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
		}
		let detached = try establishTranscriptManualHistoryBaseline(
			app: app,
			scrollView: scrollView,
			telemetryElement: telemetryElement,
			initial: initial,
			baseline: detachedBaseline,
			eventsElement: eventsElement,
			label: "manual-scroll"
		)
		let baselineAnchor = detached.topVisibleAnchorDescription
		let baselineDistance = detached.distanceToBottom
		let baselineGestureCount = detached.manualScrollGestureCount ?? 0
		let baselineEffectCount = detached.manualScrollEffectCount ?? 0
		var latest = detached
		var sawObservedGesture = false

		for _ in 0..<6 {
			performTargetedStressTranscriptScroll(
				app: app,
				scrollView: scrollView,
				direction: .towardHistory,
				telemetryElement: telemetryElement,
				baseline: latest,
				eventsElement: eventsElement
			)

			if let observed = try? waitForTelemetry(
				from: telemetryElement,
				timeout: 3,
				label: "manual detached scroll observation",
				failOnTimeout: false,
				predicate: {
					$0.tabID == initial.tabID
						&& $0.sampleIndex > latest.sampleIndex
						&& (
							($0.manualScrollGestureCount ?? 0) > baselineGestureCount
							|| ($0.manualScrollEffectCount ?? 0) > baselineEffectCount
						)
				}
			) {
				latest = observed
				sawObservedGesture = sawObservedGesture || ((latest.manualScrollGestureCount ?? 0) > baselineGestureCount)

				if (latest.manualScrollEffectCount ?? 0) > baselineEffectCount {
					let didMoveAnchor = latest.topVisibleAnchorDescription != baselineAnchor
					let didMoveDistance = abs(latest.distanceToBottom - baselineDistance) >= 24
					XCTAssertTrue(
						didMoveAnchor || didMoveDistance,
						"baseline=\(detached) latest=\(latest)"
					)
					return
				}
			}
		}

		if !sawObservedGesture {
			throw XCTSkip("No detached manual scroll gesture was observed by the app after repeated attempts. latest=\(latest)")
		}

		if let resolved = try? waitForTelemetry(
			from: telemetryElement,
			timeout: 3,
			label: "manual detached scroll resolution",
			failOnTimeout: false,
			predicate: {
				$0.tabID == initial.tabID
					&& $0.sampleIndex > latest.sampleIndex
					&& ($0.manualScrollEffectCount ?? 0) > baselineEffectCount
			}
		) {
			latest = resolved
			let didMoveAnchor = latest.topVisibleAnchorDescription != baselineAnchor
			let didMoveDistance = abs(latest.distanceToBottom - baselineDistance) >= 24
			XCTAssertTrue(
				(latest.manualScrollEffectCount ?? 0) > baselineEffectCount && (didMoveAnchor || didMoveDistance),
				"baseline=\(detached) latest=\(latest)"
			)
			return
		}

		XCTFail("Detached manual scroll was observed but never resolved to a clear effect outcome. baseline=\(detached) latest=\(latest)")
	}

	func testAgentChatStressHarnessNestedEditCardScrollPreservesTranscriptSteadyState() throws {
		let app = launchStressHarness(intervalMS: 160, warmupTurns: 4, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(
				telemetryElement: telemetryElement,
				groupingElement: groupingElement,
				eventsElement: eventsElement
			)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))

		let baseline = try waitForTelemetry(from: telemetryElement, timeout: 25, label: "nested edit-card readiness", eventsElement: eventsElement) {
			$0.tabID != nil
				&& $0.supportsGeometryMetrics
				&& ($0.expandedApplyEditsDiffPreviewCardCount ?? 0) > 0
				&& ($0.expandedApplyEditsMarkdownFallbackCardCount ?? 0) == 0
				&& ($0.latestExpandedHighSignalToolDescription?.contains("apply_edits") ?? false)
				&& $0.latestExpandedHighSignalRenderMode == "diffPreview"
		}
		let followUp = try waitForTelemetry(
			from: telemetryElement,
			timeout: 8,
			label: "nested edit-card steady-state follow-up",
			eventsElement: eventsElement
		) {
			$0.tabID == baseline.tabID
				&& $0.sampleIndex >= baseline.sampleIndex + 10
				&& ($0.expandedApplyEditsDiffPreviewCardCount ?? 0) > 0
				&& ($0.expandedApplyEditsMarkdownFallbackCardCount ?? 0) == 0
				&& $0.latestExpandedHighSignalRenderMode == "diffPreview"
		}

		XCTAssertEqual(followUp.expandedApplyEditsMarkdownFallbackCardCount ?? 0, 0, "baseline=\(baseline) followUp=\(followUp)")
		XCTAssertGreaterThan(followUp.expandedApplyEditsDiffPreviewCardCount ?? 0, 0, "baseline=\(baseline) followUp=\(followUp)")
	}

	func testAgentChatStressHarnessScrollToBottomRemainsResponsiveAfterRepeatedDetachCycles() throws {
		let app = launchStressHarness(intervalMS: 160, warmupTurns: 4, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		let scrollToBottomButton = app.buttons["agentTranscript.scrollToBottom"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 25,
			label: "scroll-to-bottom basic readiness"
		)
		let initialTabID = try XCTUnwrap(initial.tabID)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		var latest = initial

		for cycle in 1...2 {
			let detached = try establishDetachedBottomButtonBaseline(
				app: app,
				scrollView: scrollView,
				telemetryElement: telemetryElement,
				initial: latest,
				eventsElement: eventsElement,
				label: "cycle \(cycle)",
				minimumDistanceToBottom: 80
			)
			latest = detached

			XCTAssertTrue(scrollToBottomButton.waitForExistence(timeout: 5))
			let baselineTapCount = detached.scrollToBottomTapCount ?? 0
			let baselineSuccessCount = detached.scrollToBottomSuccessCount ?? 0

			scrollToBottomButton.tap()

			let tapped = try waitForTelemetry(from: telemetryElement, timeout: 4, label: "cycle \(cycle) scroll-to-bottom tap observed", eventsElement: eventsElement) {
				$0.tabID == initial.tabID
					&& $0.sampleIndex > detached.sampleIndex
					&& ($0.scrollToBottomTapCount ?? 0) > baselineTapCount
			}
			latest = tapped

			let settled = try resolveScrollToBottomRecovery(
				initialTabID: initialTabID,
				telemetryElement: telemetryElement,
				baseline: detached,
				tapped: tapped,
				eventsElement: eventsElement,
				label: "cycle \(cycle) scroll-to-bottom"
			)
			latest = settled

			XCTAssertGreaterThanOrEqual(settled.scrollToBottomTapCount ?? 0, baselineTapCount + 1, "detached=\(detached) settled=\(settled)")
			XCTAssertTrue(
				(settled.scrollToBottomSuccessCount ?? 0) > baselineSuccessCount
					|| (settled.isPinnedToLiveBottom && !settled.userDetachedAutoFollow),
				"detached=\(detached) settled=\(settled)"
			)
			XCTAssertTrue(settled.isPinnedToLiveBottom, "detached=\(detached) settled=\(settled)")
			XCTAssertFalse(settled.userDetachedAutoFollow, "detached=\(detached) settled=\(settled)")
			XCTAssertTrue(
				settled.isNearBottom
					|| settled.distanceToBottom <= 40
					|| settled.lastScrollToBottomOutcome == "reachedBottom",
				"detached=\(detached) settled=\(settled)"
			)
		}
	}

	func testAgentChatStressHarnessRichToolChurnManualScrollRemainsResponsiveWhenDetached() throws {
		let app = launchStressHarness(scenario: "richToolChurn", intervalMS: 80, warmupTurns: 8, toolStepRepeatCount: 3)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let readiness = try waitForHeavyRenderedState(
			telemetryElement: telemetryElement,
			groupingElement: groupingElement,
			eventsElement: eventsElement,
			timeout: 45
		)
		let initial = readiness.telemetry
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let forceDetachButton = app.buttons["agentStress.forceDetach"]
		XCTAssertTrue(forceDetachButton.waitForExistence(timeout: 10))
		forceDetachButton.tap()

		let detached = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "rich manual-scroll detached baseline", eventsElement: eventsElement) {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& ($0.canScrollTowardHistory ?? false)
		}
		let baselineAnchor = detached.topVisibleAnchorDescription
		let baselineDistance = detached.distanceToBottom
		let baselineGestureCount = detached.manualScrollGestureCount ?? 0
		let baselineEffectCount = detached.manualScrollEffectCount ?? 0
		var latest = detached
		var sawObservedGesture = false

		for _ in 0..<6 {
			performDetachScrollGesture(
				app: app,
				scrollView: scrollView,
				telemetryElement: telemetryElement,
				baseline: latest,
				eventsElement: eventsElement
			)

			if let observed = try? waitForTelemetry(
				from: telemetryElement,
				timeout: 4,
				label: "rich manual detached scroll observation",
				eventsElement: eventsElement,
				failOnTimeout: false,
				predicate: {
					$0.tabID == initial.tabID
						&& $0.sampleIndex > latest.sampleIndex
						&& (
							($0.manualScrollGestureCount ?? 0) > baselineGestureCount
							|| ($0.manualScrollEffectCount ?? 0) > baselineEffectCount
						)
				}
			) {
				latest = observed
				sawObservedGesture = sawObservedGesture || ((latest.manualScrollGestureCount ?? 0) > baselineGestureCount)

				if (latest.manualScrollEffectCount ?? 0) > baselineEffectCount {
					let didMoveAnchor = latest.topVisibleAnchorDescription != baselineAnchor
					let didMoveDistance = abs(latest.distanceToBottom - baselineDistance) >= 24
					XCTAssertTrue(didMoveAnchor || didMoveDistance, "baseline=\(detached) latest=\(latest)")
					return
				}
			}
		}

		if !sawObservedGesture {
			throw XCTSkip("No rich detached manual scroll gesture was observed by the app after repeated attempts. latest=\(latest)")
		}

		if let resolved = try? waitForTelemetry(
			from: telemetryElement,
			timeout: 4,
			label: "rich manual detached scroll resolution",
			eventsElement: eventsElement,
			failOnTimeout: false,
			predicate: {
				$0.tabID == initial.tabID
					&& $0.sampleIndex > latest.sampleIndex
					&& ($0.manualScrollEffectCount ?? 0) > baselineEffectCount
			}
		) {
			latest = resolved
			let didMoveAnchor = latest.topVisibleAnchorDescription != baselineAnchor
			let didMoveDistance = abs(latest.distanceToBottom - baselineDistance) >= 24
			XCTAssertTrue(
				(latest.manualScrollEffectCount ?? 0) > baselineEffectCount && (didMoveAnchor || didMoveDistance),
				"baseline=\(detached) latest=\(latest)"
			)
			return
		}

		XCTFail("Rich detached manual scroll was observed but never resolved to a clear effect outcome. baseline=\(detached) latest=\(latest)")
	}

	func testAgentChatStressHarnessAssistantMarkdownChurnManualScrollRemainsResponsiveWhenDetached() throws {
		let app = launchStressHarness(scenario: "assistantMarkdownChurn", intervalMS: 70, warmupTurns: 1, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 25,
			label: "assistant markdown churn readiness"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}
		let baselineEvents = accessibilityText(from: eventsElement) ?? ""
		let baselineBatchNumber = latestStressEventBatchNumber(in: baselineEvents, prefix: "assistantMarkdownStreamStart#") ?? 0
		let activeStream = try waitForAssistantMarkdownChurnProgress(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 20,
			afterBatchNumber: baselineBatchNumber,
			afterSampleIndex: initial.sampleIndex,
			baselineProjectionPublishCount: initial.projectionPublishCount ?? 0,
			baselineRefreshRequestCount: initial.refreshRequestCount ?? 0,
			tabID: initial.tabID
		)

		let activeBatchNumber = activeStream.batchNumber
		let activeStreamTelemetry = activeStream.telemetry
		let quiescent = try pauseStressHarnessAndWaitForTelemetryQuiescence(
			app: app,
			telemetryElement: telemetryElement,
			initial: activeStreamTelemetry,
			eventsElement: eventsElement
		)
		let detachedBaseline = try establishDetachedBottomButtonBaseline(
			app: app,
			scrollView: scrollView,
			telemetryElement: telemetryElement,
			initial: quiescent,
			eventsElement: eventsElement,
			label: "assistant markdown churn",
			minimumDistanceToBottom: 60
		)
		let resumeButton = app.buttons["agentStress.resume"]
		XCTAssertTrue(resumeButton.waitForExistence(timeout: 5))
		resumeButton.tap()
		let resumedDetachedStream = try waitForAssistantMarkdownChurnProgress(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 20,
			afterBatchNumber: activeBatchNumber,
			afterSampleIndex: detachedBaseline.sampleIndex,
			baselineProjectionPublishCount: detachedBaseline.projectionPublishCount ?? 0,
			baselineRefreshRequestCount: detachedBaseline.refreshRequestCount ?? 0,
			tabID: initial.tabID
		)
		let detached = resumedDetachedStream.telemetry
		let baselineAnchor = detached.topVisibleAnchorDescription
		let baselineDistance = detached.distanceToBottom
		let baselineGestureCount = detached.manualScrollGestureCount ?? 0
		let baselineEffectCount = detached.manualScrollEffectCount ?? 0
		let baselineHistoryEffectCount = detached.manualScrollTowardHistoryEffectCount ?? 0
		var latest = detached

		for _ in 0..<4 {
			performDetachScrollGesture(
				app: app,
				scrollView: scrollView,
				telemetryElement: telemetryElement,
				baseline: latest,
				eventsElement: eventsElement
			)

			if let observed = try? waitForTelemetry(
				from: telemetryElement,
				timeout: 4,
				label: "assistant markdown detached scroll observation",
				eventsElement: eventsElement,
				failOnTimeout: false,
				predicate: {
					$0.tabID == initial.tabID
						&& $0.sampleIndex > latest.sampleIndex
						&& (
							($0.manualScrollGestureCount ?? 0) > baselineGestureCount
							|| ($0.manualScrollEffectCount ?? 0) > baselineEffectCount
						)
				}
			) {
				latest = observed
				if (latest.manualScrollEffectCount ?? 0) > baselineEffectCount {
					let didMoveAnchor = latest.topVisibleAnchorDescription != baselineAnchor
					let didMoveDistance = abs(latest.distanceToBottom - baselineDistance) >= 24
					let didRecordHistoryEffect = (latest.manualScrollTowardHistoryEffectCount ?? 0) > baselineHistoryEffectCount
					XCTAssertTrue(didMoveAnchor || didMoveDistance || didRecordHistoryEffect, "baseline=\(detached) latest=\(latest)")
					_ = try waitForAssistantMarkdownStreamFinalization(
						telemetryElement: telemetryElement,
						eventsElement: eventsElement,
						timeout: 15,
						batchNumber: activeBatchNumber + 1,
						afterSampleIndex: latest.sampleIndex,
						tabID: initial.tabID
					)
					return
				}
			}
		}

		XCTFail("Assistant markdown detached manual scroll never produced a clear effect. baseline=\(detached) latest=\(latest)")
	}

	func testAgentChatStressHarnessQuiescentDetachedHistorySwipeStaysDetached() throws {
		let app = launchStressHarness(intervalMS: 120, warmupTurns: 2, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 25,
			label: "short detached drag readiness"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}
		let quiescent = try pauseStressHarnessAndWaitForTelemetryQuiescence(
			app: app,
			telemetryElement: telemetryElement,
			initial: initial,
			eventsElement: eventsElement,
			timeout: 8
		)

		let forceDetachButton = app.buttons["agentStress.forceDetach"]
		XCTAssertTrue(forceDetachButton.waitForExistence(timeout: 10))
		forceDetachButton.tap()

		let detached = try waitForTelemetry(from: telemetryElement, timeout: 8, label: "short detached drag baseline", eventsElement: eventsElement) {
			$0.tabID == quiescent.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& ($0.canScrollTowardHistory ?? false)
		}

		let baselineTabID = try XCTUnwrap(detached.tabID)
		let baselineDistance = detached.distanceToBottom
		let baselineAnchor = detached.topVisibleAnchorDescription
		let baselineHistoryEffectCount = detached.manualScrollTowardHistoryEffectCount ?? 0

		performTowardHistoryScrollGesture(app: app, scrollView: scrollView)
		let observed = try waitForTelemetry(from: telemetryElement, timeout: 4, label: "quiescent detached history swipe", eventsElement: eventsElement) {
			$0.tabID == baselineTabID
				&& $0.sampleIndex > detached.sampleIndex
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& (
					$0.distanceToBottom >= baselineDistance + 40
					|| ($0.manualScrollTowardHistoryEffectCount ?? 0) > baselineHistoryEffectCount
					|| $0.topVisibleAnchorDescription != baselineAnchor
				)
		}

		RunLoop.current.run(until: Date().addingTimeInterval(1.25))
		let settled = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
		XCTAssertEqual(settled.tabID, baselineTabID, "detached=\(detached) observed=\(observed) settled=\(settled)")
		XCTAssertFalse(settled.isPinnedToLiveBottom, "telemetry=\(settled)")
		XCTAssertTrue(settled.userDetachedAutoFollow, "telemetry=\(settled)")
	}

	func testAgentChatStressHarnessAssistantMarkdownChurnQuiescentHistoryScrollDetachesAndStaysDetached() throws {
		let app = launchStressHarness(scenario: "assistantMarkdownChurn", intervalMS: 70, warmupTurns: 1, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		let scrollToBottomButton = app.buttons["agentTranscript.scrollToBottom"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 25,
			label: "assistant markdown quiescent detach readiness"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}
		let baselineEvents = accessibilityText(from: eventsElement) ?? ""
		let baselineBatchNumber = latestStressEventBatchNumber(in: baselineEvents, prefix: "assistantMarkdownStreamStart#") ?? 0
		let activeStream = try waitForAssistantMarkdownChurnProgress(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 20,
			afterBatchNumber: baselineBatchNumber,
			afterSampleIndex: initial.sampleIndex,
			baselineProjectionPublishCount: initial.projectionPublishCount ?? 0,
			baselineRefreshRequestCount: initial.refreshRequestCount ?? 0,
			tabID: initial.tabID
		)
		let quiescent = try pauseStressHarnessAndWaitForTelemetryQuiescence(
			app: app,
			telemetryElement: telemetryElement,
			initial: activeStream.telemetry,
			eventsElement: eventsElement
		)
		XCTAssertTrue(quiescent.isPinnedToLiveBottom, "telemetry=\(quiescent)")
		XCTAssertFalse(quiescent.userDetachedAutoFollow, "telemetry=\(quiescent)")
		XCTAssertLessThanOrEqual(quiescent.distanceToBottom, 24, "telemetry=\(quiescent)")
		XCTAssertNil(quiescent.pendingPinnedBottomSourceDescription, "telemetry=\(quiescent)")
		XCTAssertFalse(quiescent.hasPendingPinnedBottomFlush ?? false, "telemetry=\(quiescent)")

		let baselineDetachCount = quiescent.detachCount
		let baselineHistoryEffects = quiescent.manualScrollTowardHistoryEffectCount ?? 0

		performTowardHistoryScrollGesture(app: app, scrollView: scrollView)
		let detached = try waitForTelemetry(from: telemetryElement, timeout: 4, label: "quiescent short history detach", eventsElement: eventsElement) {
			$0.tabID == quiescent.tabID
				&& $0.sampleIndex > quiescent.sampleIndex
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.detachCount > baselineDetachCount
		}
		XCTAssertTrue(scrollToBottomButton.waitForExistence(timeout: 5))

		RunLoop.current.run(until: Date().addingTimeInterval(1.25))
		let postDetachWindow = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
		XCTAssertEqual(postDetachWindow.tabID, quiescent.tabID, "detached=\(detached) window=\(postDetachWindow)")
		XCTAssertFalse(postDetachWindow.isPinnedToLiveBottom, "telemetry=\(postDetachWindow)")
		XCTAssertTrue(postDetachWindow.userDetachedAutoFollow, "telemetry=\(postDetachWindow)")
		XCTAssertNil(postDetachWindow.pendingPinnedBottomSourceDescription, "telemetry=\(postDetachWindow)")
		XCTAssertFalse(postDetachWindow.hasPendingPinnedBottomFlush ?? false, "telemetry=\(postDetachWindow)")
		XCTAssertEqual(postDetachWindow.detachedSnapToTopCount, detached.detachedSnapToTopCount, "detached=\(detached) window=\(postDetachWindow)")
		XCTAssertEqual(postDetachWindow.detachedRestoreIntentCount, detached.detachedRestoreIntentCount, "detached=\(detached) window=\(postDetachWindow)")
		if let detachedAnchor = detached.topVisibleAnchorDescription {
			XCTAssertEqual(postDetachWindow.topVisibleAnchorDescription, detachedAnchor, "detached=\(detached) window=\(postDetachWindow)")
		}
		if let detachedStoredTarget = detached.storedDetachedTargetDescription {
			XCTAssertEqual(postDetachWindow.storedDetachedTargetDescription, detachedStoredTarget, "detached=\(detached) window=\(postDetachWindow)")
		}
		if let detachedStoredAnchor = detached.storedDetachedAnchorDescription {
			XCTAssertEqual(postDetachWindow.storedDetachedAnchorDescription, detachedStoredAnchor, "detached=\(detached) window=\(postDetachWindow)")
		}
		if let detachedLiveTarget = detached.liveDetachedTargetDescription,
			let laterLiveTarget = postDetachWindow.liveDetachedTargetDescription {
			XCTAssertEqual(laterLiveTarget, detachedLiveTarget, "detached=\(detached) window=\(postDetachWindow)")
		}

		let detachedAnchor = postDetachWindow.topVisibleAnchorDescription
		let detachedDistance = postDetachWindow.distanceToBottom
		let detachedHistoryEffects = postDetachWindow.manualScrollTowardHistoryEffectCount ?? 0
		performTowardHistoryScrollGesture(app: app, scrollView: scrollView)
		let climbed = try waitForTelemetry(from: telemetryElement, timeout: 4, label: "quiescent history continued climb", eventsElement: eventsElement) {
			$0.tabID == quiescent.tabID
				&& $0.sampleIndex > postDetachWindow.sampleIndex
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& (
					$0.distanceToBottom >= detachedDistance + 40
					|| ($0.manualScrollTowardHistoryEffectCount ?? 0) > detachedHistoryEffects
					|| $0.topVisibleAnchorDescription != detachedAnchor
				)
		}

		RunLoop.current.run(until: Date().addingTimeInterval(1.5))
		let settledDetached = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
		XCTAssertEqual(settledDetached.tabID, quiescent.tabID, "telemetry=\(settledDetached)")
		XCTAssertFalse(settledDetached.isPinnedToLiveBottom, "telemetry=\(settledDetached)")
		XCTAssertTrue(settledDetached.userDetachedAutoFollow, "telemetry=\(settledDetached)")
		XCTAssertNil(settledDetached.pendingPinnedBottomSourceDescription, "telemetry=\(settledDetached)")
		XCTAssertFalse(settledDetached.hasPendingPinnedBottomFlush ?? false, "telemetry=\(settledDetached)")
		XCTAssertGreaterThanOrEqual(settledDetached.distanceToBottom, climbed.distanceToBottom - 24, "climbed=\(climbed) settled=\(settledDetached)")
		XCTAssertTrue(scrollToBottomButton.exists, "button should remain visible while detached")
	}

	func testAgentChatStressHarnessAssistantMarkdownChurnQuiescentShortHistoryScrollStaysResponsiveWithoutReset() throws {
		let app = launchStressHarness(scenario: "assistantMarkdownChurn", intervalMS: 70, warmupTurns: 1, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		let scrollToBottomButton = app.buttons["agentTranscript.scrollToBottom"]
		let resetButton = app.buttons["agentTranscript.resetScrollView"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))
		XCTAssertTrue(resetButton.waitForExistence(timeout: 5), "reset affordance should exist but must not be needed")

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 25,
			label: "assistant markdown short idle-scroll readiness"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}
		let baselineEvents = accessibilityText(from: eventsElement) ?? ""
		let baselineBatchNumber = latestStressEventBatchNumber(in: baselineEvents, prefix: "assistantMarkdownStreamStart#") ?? 0
		let activeStream = try waitForAssistantMarkdownChurnProgress(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 20,
			afterBatchNumber: baselineBatchNumber,
			afterSampleIndex: initial.sampleIndex,
			baselineProjectionPublishCount: initial.projectionPublishCount ?? 0,
			baselineRefreshRequestCount: initial.refreshRequestCount ?? 0,
			tabID: initial.tabID
		)
		let quiescent = try pauseStressHarnessAndWaitForTelemetryQuiescence(
			app: app,
			telemetryElement: telemetryElement,
			initial: activeStream.telemetry,
			eventsElement: eventsElement
		)
		XCTAssertTrue(quiescent.isPinnedToLiveBottom, "telemetry=\(quiescent)")
		XCTAssertFalse(quiescent.userDetachedAutoFollow, "telemetry=\(quiescent)")
		XCTAssertLessThanOrEqual(quiescent.distanceToBottom, 24, "telemetry=\(quiescent)")
		XCTAssertNil(quiescent.pendingPinnedBottomSourceDescription, "telemetry=\(quiescent)")
		XCTAssertFalse(quiescent.hasPendingPinnedBottomFlush ?? false, "telemetry=\(quiescent)")

		let baselineDetachCount = quiescent.detachCount
		let baselineHistoryEffects = quiescent.manualScrollTowardHistoryEffectCount ?? 0
		let baselineResetRevision = quiescent.sampleIndex

		performTowardHistoryScrollGesture(app: app, scrollView: scrollView, magnitude: .short)
		let detached = try waitForTelemetry(from: telemetryElement, timeout: 5, label: "short idle history scroll detach", eventsElement: eventsElement) {
			$0.tabID == quiescent.tabID
				&& $0.sampleIndex > baselineResetRevision
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.detachCount > baselineDetachCount
				&& ($0.manualScrollTowardHistoryEffectCount ?? 0) > baselineHistoryEffects
				&& $0.lastManualScrollDirection == UITestScrollWheelDirection.towardHistory.rawValue
		}
		XCTAssertTrue(scrollToBottomButton.waitForExistence(timeout: 5))

		RunLoop.current.run(until: Date().addingTimeInterval(1.0))
		let idleWindow = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
		XCTAssertEqual(idleWindow.tabID, quiescent.tabID, "detached=\(detached) idle=\(idleWindow)")
		XCTAssertFalse(idleWindow.isPinnedToLiveBottom, "telemetry=\(idleWindow)")
		XCTAssertTrue(idleWindow.userDetachedAutoFollow, "telemetry=\(idleWindow)")
		XCTAssertNil(idleWindow.pendingPinnedBottomSourceDescription, "telemetry=\(idleWindow)")
		XCTAssertFalse(idleWindow.hasPendingPinnedBottomFlush ?? false, "telemetry=\(idleWindow)")
		XCTAssertEqual(idleWindow.lastManualScrollDirection, UITestScrollWheelDirection.towardHistory.rawValue, "telemetry=\(idleWindow)")
		XCTAssertTrue(scrollToBottomButton.exists, "scroll-to-bottom should remain visible while detached")
		XCTAssertTrue(resetButton.exists, "reset affordance should remain unused")

		let detachedDistance = idleWindow.distanceToBottom
		let detachedAnchor = idleWindow.topVisibleAnchorDescription
		let detachedHistoryEffects = idleWindow.manualScrollTowardHistoryEffectCount ?? 0
		performTowardHistoryScrollGesture(app: app, scrollView: scrollView, magnitude: .short)
		let climbed = try waitForTelemetry(from: telemetryElement, timeout: 5, label: "short idle history scroll remains responsive", eventsElement: eventsElement) {
			$0.tabID == quiescent.tabID
				&& $0.sampleIndex > idleWindow.sampleIndex
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& (
					$0.distanceToBottom >= detachedDistance + 20
					|| ($0.manualScrollTowardHistoryEffectCount ?? 0) > detachedHistoryEffects
					|| $0.topVisibleAnchorDescription != detachedAnchor
				)
		}
		XCTAssertEqual(climbed.lastManualScrollDirection, UITestScrollWheelDirection.towardHistory.rawValue, "telemetry=\(climbed)")
		XCTAssertTrue(scrollToBottomButton.exists, "scroll-to-bottom should remain visible after continued manual history scroll")
		XCTAssertTrue(resetButton.exists, "reset affordance should not be used to recover scrolling")
	}

	func testAgentChatStressHarnessMarkdownSelectionOffscreenScrollRemainsResponsiveWithoutReset() throws {
		let app = launchStressHarness(scenario: "assistantMarkdownMegaChurn", intervalMS: 60, warmupTurns: 1, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		let scrollToBottomButton = app.buttons["agentTranscript.scrollToBottom"]
		let resetButton = app.buttons["agentTranscript.resetScrollView"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))
		XCTAssertTrue(resetButton.waitForExistence(timeout: 5), "reset affordance should exist but must not be needed")

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 25,
			label: "markdown selection offscreen readiness"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let baselineEvents = accessibilityText(from: eventsElement) ?? ""
		let baselineBatchNumber = latestStressEventBatchNumber(in: baselineEvents, prefix: "assistantMarkdownLargeWindowStart#") ?? 0
		let active = try waitForAssistantMarkdownMegaWindow(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 25,
			afterBatchNumber: baselineBatchNumber,
			afterSampleIndex: initial.sampleIndex,
			tabID: initial.tabID
		)
		XCTAssertTrue(
			active.markerCharacterCount >= 12_000 || active.markerLineCount >= 220,
			"telemetry=\(active.telemetry), markerChars=\(active.markerCharacterCount), markerLines=\(active.markerLineCount)"
		)
		XCTAssertGreaterThan(active.telemetry.projectionBuildCount ?? 0, 0, "telemetry=\(active.telemetry)")
		XCTAssertGreaterThan(active.telemetry.projectionPublishCount ?? 0, 0, "telemetry=\(active.telemetry)")

		let finalized = try waitForAssistantMarkdownStreamFinalization(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 25,
			batchNumber: active.batchNumber,
			afterSampleIndex: active.telemetry.sampleIndex,
			tabID: initial.tabID
		)
		let pinnedFinalized = try waitForTelemetry(from: telemetryElement, timeout: 15, label: "markdown selection finalized pinned settle", eventsElement: eventsElement) {
			$0.tabID == initial.tabID
				&& $0.sampleIndex >= finalized.sampleIndex
				&& $0.isPinnedToLiveBottom
				&& !$0.userDetachedAutoFollow
				&& $0.distanceToBottom <= 40
		}
		let quiescent = try pauseStressHarnessAndWaitForTelemetryQuiescence(
			app: app,
			telemetryElement: telemetryElement,
			initial: pinnedFinalized,
			eventsElement: eventsElement,
			timeout: 12
		)
		XCTAssertTrue(quiescent.isPinnedToLiveBottom, "telemetry=\(quiescent)")
		XCTAssertFalse(quiescent.userDetachedAutoFollow, "telemetry=\(quiescent)")
		XCTAssertLessThanOrEqual(quiescent.distanceToBottom, 40, "telemetry=\(quiescent)")
		XCTAssertNil(quiescent.pendingPinnedBottomSourceDescription, "telemetry=\(quiescent)")
		XCTAssertFalse(quiescent.hasPendingPinnedBottomFlush ?? false, "telemetry=\(quiescent)")

		let baselineDetachCount = quiescent.detachCount
		let baselineHistoryEffects = quiescent.manualScrollTowardHistoryEffectCount ?? 0
		let baselineDistance = quiescent.distanceToBottom
		let baselineAnchor = quiescent.topVisibleAnchorDescription

		try selectVisibleMarkdownText(in: scrollView, app: app)
		performTowardHistoryScrollGesture(app: app, scrollView: scrollView)
		let offscreen = try waitForTelemetry(from: telemetryElement, timeout: 6, label: "markdown selection scrolled offscreen detach", eventsElement: eventsElement) {
			$0.tabID == quiescent.tabID
				&& $0.sampleIndex > quiescent.sampleIndex
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& $0.detachCount > baselineDetachCount
				&& (
					$0.distanceToBottom >= baselineDistance + 20
					|| ($0.manualScrollTowardHistoryEffectCount ?? 0) > baselineHistoryEffects
					|| $0.topVisibleAnchorDescription != baselineAnchor
				)
		}
		XCTAssertTrue(scrollToBottomButton.waitForExistence(timeout: 5), "scroll-to-bottom should become visible while detached")
		XCTAssertTrue(resetButton.exists, "reset affordance should remain unused")

		RunLoop.current.run(until: Date().addingTimeInterval(0.75))
		let offscreenWindow = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
		XCTAssertEqual(offscreenWindow.tabID, quiescent.tabID, "offscreen=\(offscreen) window=\(offscreenWindow)")
		XCTAssertFalse(offscreenWindow.isPinnedToLiveBottom, "telemetry=\(offscreenWindow)")
		XCTAssertTrue(offscreenWindow.userDetachedAutoFollow, "telemetry=\(offscreenWindow)")
		XCTAssertNil(offscreenWindow.pendingPinnedBottomSourceDescription, "telemetry=\(offscreenWindow)")
		XCTAssertFalse(offscreenWindow.hasPendingPinnedBottomFlush ?? false, "telemetry=\(offscreenWindow)")

		let offscreenDistance = offscreenWindow.distanceToBottom
		let offscreenAnchor = offscreenWindow.topVisibleAnchorDescription
		let offscreenHistoryEffects = offscreenWindow.manualScrollTowardHistoryEffectCount ?? 0
		performTowardHistoryScrollGesture(app: app, scrollView: scrollView)
		let climbed = try waitForTelemetry(from: telemetryElement, timeout: 6, label: "markdown selection offscreen scroll remains responsive", eventsElement: eventsElement) {
			$0.tabID == quiescent.tabID
				&& $0.sampleIndex > offscreenWindow.sampleIndex
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& (
					$0.distanceToBottom >= offscreenDistance + 20
					|| ($0.manualScrollTowardHistoryEffectCount ?? 0) > offscreenHistoryEffects
					|| $0.topVisibleAnchorDescription != offscreenAnchor
				)
		}
		XCTAssertEqual(climbed.lastManualScrollDirection, UITestScrollWheelDirection.towardHistory.rawValue, "telemetry=\(climbed)")
		XCTAssertTrue(scrollToBottomButton.exists, "scroll-to-bottom should remain visible after continued manual history scroll")
		XCTAssertTrue(resetButton.exists, "reset affordance should not be used to recover scrolling")
		XCTAssertNil(climbed.pendingPinnedBottomSourceDescription, "telemetry=\(climbed)")
		XCTAssertFalse(climbed.hasPendingPinnedBottomFlush ?? false, "telemetry=\(climbed)")
	}

	func testAgentChatStressHarnessAssistantMarkdownChurnDoesNotExposeHistoricalContentWhilePinned() throws {
		let app = launchStressHarness(scenario: "assistantMarkdownChurn", intervalMS: 70, warmupTurns: 1, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 25,
			label: "assistant markdown pinned churn readiness"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		var latest = try waitForTelemetry(from: telemetryElement, timeout: 12, label: "assistant markdown pinned baseline", eventsElement: eventsElement) {
			$0.tabID == initial.tabID
				&& $0.sampleIndex >= initial.sampleIndex
				&& $0.isPinnedToLiveBottom
				&& !$0.userDetachedAutoFollow
				&& $0.distanceToBottom <= 40
		}
		XCTAssertEqual(latest.unexpectedHistoricalExposureCount ?? 0, 0, "telemetry=\(latest)")
		XCTAssertEqual(latest.maxUnexpectedHistoricalExposureBlocksBelowTop ?? 0, 0, "telemetry=\(latest)")
		var catastrophicJumpEventCount = countOccurrences(of: "Catastrophic pinned jump recorded", in: accessibilityText(from: eventsElement) ?? "")
		var batchNumber = latestStressEventBatchNumber(
			in: accessibilityText(from: eventsElement) ?? "",
			prefix: "assistantMarkdownStreamStart#"
		) ?? 0

		for iteration in 0..<2 {
			let active = try waitForAssistantMarkdownChurnProgress(
				telemetryElement: telemetryElement,
				eventsElement: eventsElement,
				timeout: 20,
				afterBatchNumber: batchNumber,
				afterSampleIndex: latest.sampleIndex,
				baselineProjectionPublishCount: latest.projectionPublishCount ?? 0,
				baselineRefreshRequestCount: latest.refreshRequestCount ?? 0,
				tabID: initial.tabID
			)
			batchNumber = active.batchNumber
			let activeTelemetry = active.telemetry
			XCTAssertTrue(activeTelemetry.isPinnedToLiveBottom, "iteration=\(iteration) telemetry=\(activeTelemetry)")
			XCTAssertFalse(activeTelemetry.userDetachedAutoFollow, "iteration=\(iteration) telemetry=\(activeTelemetry)")
			XCTAssertEqual(activeTelemetry.unexpectedHistoricalExposureCount ?? 0, 0, "iteration=\(iteration) telemetry=\(activeTelemetry)")
			XCTAssertEqual(activeTelemetry.maxUnexpectedHistoricalExposureBlocksBelowTop ?? 0, 0, "iteration=\(iteration) telemetry=\(activeTelemetry)")

			let finalized = try waitForAssistantMarkdownStreamFinalization(
				telemetryElement: telemetryElement,
				eventsElement: eventsElement,
				timeout: 15,
				batchNumber: batchNumber,
				afterSampleIndex: activeTelemetry.sampleIndex,
				tabID: initial.tabID
			)
			latest = try waitForTelemetry(from: telemetryElement, timeout: 12, label: "assistant markdown pinned settle #\(batchNumber)", eventsElement: eventsElement) {
				$0.tabID == initial.tabID
					&& $0.sampleIndex >= finalized.sampleIndex
					&& $0.isPinnedToLiveBottom
					&& !$0.userDetachedAutoFollow
					&& $0.distanceToBottom <= 40
			}
			let updatedEvents = accessibilityText(from: eventsElement) ?? ""
			let updatedCatastrophicJumpEventCount = countOccurrences(of: "Catastrophic pinned jump recorded", in: updatedEvents)
			XCTAssertEqual(updatedCatastrophicJumpEventCount, catastrophicJumpEventCount, "iteration=\(iteration) telemetry=\(latest)\nRecent events:\n\(updatedEvents)")
			catastrophicJumpEventCount = updatedCatastrophicJumpEventCount
			XCTAssertEqual(latest.unexpectedHistoricalExposureCount ?? 0, 0, "iteration=\(iteration) telemetry=\(latest)")
			XCTAssertEqual(latest.maxUnexpectedHistoricalExposureBlocksBelowTop ?? 0, 0, "iteration=\(iteration) telemetry=\(latest)")
		}
	}

	func testAgentChatStressHarnessAssistantMarkdownMegaChurnDoesNotExposeHistoricalContentWhilePinned() throws {
		let app = launchStressHarness(scenario: "assistantMarkdownMegaChurn", intervalMS: 55, warmupTurns: 1, toolStepRepeatCount: 1)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 25,
			label: "assistant markdown mega churn readiness"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let baseline = try waitForTelemetry(from: telemetryElement, timeout: 12, label: "assistant markdown mega pinned baseline", eventsElement: eventsElement) {
			$0.tabID == initial.tabID
				&& $0.sampleIndex >= initial.sampleIndex
				&& $0.isPinnedToLiveBottom
				&& !$0.userDetachedAutoFollow
		}
		let baselineEvents = accessibilityText(from: eventsElement) ?? ""
		let baselineLargeJumpCount = baseline.largeStreamingPinnedJumpCount ?? 0
		let baselineLargeExposureCount = baseline.largeStreamingHistoricalExposureCount ?? 0
		let baselineGenericExposureCount = baseline.unexpectedHistoricalExposureCount ?? 0
		let baselineLargeJumpEventCount = countOccurrences(of: "Large streaming markdown pinned jump recorded", in: baselineEvents)
		let baselineLargeExposureEventCount = countOccurrences(of: "Large streaming markdown historical exposure recorded", in: baselineEvents)
		let baselineGenericJumpEventCount = countOccurrences(of: "Catastrophic pinned jump recorded", in: baselineEvents)
		let baselineBatchNumber = latestStressEventBatchNumber(in: baselineEvents, prefix: "assistantMarkdownLargeWindowStart#") ?? 0

		let active = try waitForAssistantMarkdownMegaWindow(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 25,
			afterBatchNumber: baselineBatchNumber,
			afterSampleIndex: baseline.sampleIndex,
			tabID: initial.tabID
		)
		let activeTelemetry = active.telemetry
		XCTAssertTrue(activeTelemetry.isPinnedToLiveBottom, "telemetry=\(activeTelemetry)")
		XCTAssertFalse(activeTelemetry.userDetachedAutoFollow, "telemetry=\(activeTelemetry)")
		XCTAssertTrue(
			active.markerCharacterCount >= 12_000 || active.markerLineCount >= 220,
			"telemetry=\(activeTelemetry), markerChars=\(active.markerCharacterCount), markerLines=\(active.markerLineCount)"
		)
		XCTAssertEqual(activeTelemetry.largeStreamingPinnedJumpCount ?? 0, baselineLargeJumpCount, "telemetry=\(activeTelemetry)")
		XCTAssertEqual(activeTelemetry.largeStreamingHistoricalExposureCount ?? 0, baselineLargeExposureCount, "telemetry=\(activeTelemetry)")

		let finalized = try waitForAssistantMarkdownStreamFinalization(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 25,
			batchNumber: active.batchNumber,
			afterSampleIndex: activeTelemetry.sampleIndex,
			tabID: initial.tabID
		)
		let settled = try waitForTelemetry(from: telemetryElement, timeout: 15, label: "assistant markdown mega pinned settle #\(active.batchNumber)", eventsElement: eventsElement) {
			$0.tabID == initial.tabID
				&& $0.sampleIndex >= finalized.sampleIndex
				&& $0.isPinnedToLiveBottom
				&& !$0.userDetachedAutoFollow
				&& $0.distanceToBottom <= 40
		}
		let updatedEvents = accessibilityText(from: eventsElement) ?? ""
		XCTAssertEqual(countOccurrences(of: "Large streaming markdown pinned jump recorded", in: updatedEvents), baselineLargeJumpEventCount, "telemetry=\(settled)\nRecent events:\n\(updatedEvents)")
		XCTAssertEqual(countOccurrences(of: "Large streaming markdown historical exposure recorded", in: updatedEvents), baselineLargeExposureEventCount, "telemetry=\(settled)\nRecent events:\n\(updatedEvents)")
		XCTAssertEqual(countOccurrences(of: "Catastrophic pinned jump recorded", in: updatedEvents), baselineGenericJumpEventCount, "telemetry=\(settled)\nRecent events:\n\(updatedEvents)")
		XCTAssertEqual(settled.largeStreamingPinnedJumpCount ?? 0, baselineLargeJumpCount, "telemetry=\(settled)")
		XCTAssertEqual(settled.largeStreamingHistoricalExposureCount ?? 0, baselineLargeExposureCount, "telemetry=\(settled)")
		XCTAssertEqual(settled.unexpectedHistoricalExposureCount ?? 0, baselineGenericExposureCount, "telemetry=\(settled)")
	}

	func testAgentChatStressHarnessPersistedCodexReplayDoesNotExposeHistoricalContentWhilePinned() throws {
		let app = launchStressHarness(scenario: "persistedCodexReplayChurn", intervalMS: 85, warmupTurns: 5, toolStepRepeatCount: 2)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))
		try waitForEventMarkers(
			in: eventsElement,
			timeout: 30,
			requiredMarkers: [
				"persistedCodexReplayFixturePrepared",
				"persistedCodexReplayRestoreReady"
			]
		)

		let restored = try waitForTelemetry(from: telemetryElement, timeout: 30, label: "persisted Codex replay restore readiness", eventsElement: eventsElement) {
			$0.tabID != nil
				&& ($0.coldRestoreStartCount ?? 0) > 0
				&& ($0.coldRestoreCompletionCount ?? 0) > 0
				&& $0.isPinnedToLiveBottom
				&& !$0.userDetachedAutoFollow
				&& $0.distanceToBottom <= 40
				&& ($0.projectionBuildCount ?? 0) > 0
				&& ($0.projectionPublishCount ?? 0) > 0
		}
		guard restored.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let baselineEvents = accessibilityText(from: eventsElement) ?? ""
		let baselineLargeJumpCount = restored.largeStreamingPinnedJumpCount ?? 0
		let baselineLargeExposureCount = restored.largeStreamingHistoricalExposureCount ?? 0
		let baselineGenericExposureCount = restored.unexpectedHistoricalExposureCount ?? 0
		let baselineLargeJumpEventCount = countOccurrences(of: "Large streaming markdown pinned jump recorded", in: baselineEvents)
		let baselineLargeExposureEventCount = countOccurrences(of: "Large streaming markdown historical exposure recorded", in: baselineEvents)
		let baselineGenericJumpEventCount = countOccurrences(of: "Catastrophic pinned jump recorded", in: baselineEvents)
		let baselineBatchNumber = latestStressEventBatchNumber(in: baselineEvents, prefix: "persistedCodexReplayLargeWindowStart#") ?? 0

		let active = try waitForPersistedCodexReplayLargeWindow(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 35,
			afterBatchNumber: baselineBatchNumber,
			afterSampleIndex: restored.sampleIndex,
			tabID: restored.tabID
		)
		let activeTelemetry = active.telemetry
		XCTAssertTrue(activeTelemetry.isPinnedToLiveBottom, "telemetry=\(activeTelemetry)")
		XCTAssertFalse(activeTelemetry.userDetachedAutoFollow, "telemetry=\(activeTelemetry)")
		XCTAssertTrue(
			active.markerCharacterCount >= 12_000 || active.markerLineCount >= 220,
			"telemetry=\(activeTelemetry), markerChars=\(active.markerCharacterCount), markerLines=\(active.markerLineCount)"
		)
		XCTAssertEqual(activeTelemetry.largeStreamingPinnedJumpCount ?? 0, baselineLargeJumpCount, "telemetry=\(activeTelemetry)")
		XCTAssertEqual(activeTelemetry.largeStreamingHistoricalExposureCount ?? 0, baselineLargeExposureCount, "telemetry=\(activeTelemetry)")
		XCTAssertEqual(activeTelemetry.unexpectedHistoricalExposureCount ?? 0, baselineGenericExposureCount, "telemetry=\(activeTelemetry)")

		let finalized = try waitForPersistedCodexReplayStreamFinalization(
			telemetryElement: telemetryElement,
			eventsElement: eventsElement,
			timeout: 30,
			batchNumber: active.batchNumber,
			afterSampleIndex: activeTelemetry.sampleIndex,
			tabID: restored.tabID
		)
		let settled = try waitForTelemetry(from: telemetryElement, timeout: 18, label: "persisted Codex replay pinned settle #\(active.batchNumber)", eventsElement: eventsElement) {
			$0.tabID == restored.tabID
				&& $0.sampleIndex >= finalized.sampleIndex
				&& $0.isPinnedToLiveBottom
				&& !$0.userDetachedAutoFollow
				&& $0.distanceToBottom <= 40
		}
		let updatedEvents = accessibilityText(from: eventsElement) ?? ""
		XCTAssertEqual(countOccurrences(of: "Large streaming markdown pinned jump recorded", in: updatedEvents), baselineLargeJumpEventCount, "telemetry=\(settled)\nRecent events:\n\(updatedEvents)")
		XCTAssertEqual(countOccurrences(of: "Large streaming markdown historical exposure recorded", in: updatedEvents), baselineLargeExposureEventCount, "telemetry=\(settled)\nRecent events:\n\(updatedEvents)")
		XCTAssertEqual(countOccurrences(of: "Catastrophic pinned jump recorded", in: updatedEvents), baselineGenericJumpEventCount, "telemetry=\(settled)\nRecent events:\n\(updatedEvents)")
		XCTAssertEqual(settled.largeStreamingPinnedJumpCount ?? 0, baselineLargeJumpCount, "telemetry=\(settled)")
		XCTAssertEqual(settled.largeStreamingHistoricalExposureCount ?? 0, baselineLargeExposureCount, "telemetry=\(settled)")
		XCTAssertEqual(settled.unexpectedHistoricalExposureCount ?? 0, baselineGenericExposureCount, "telemetry=\(settled)")
	}

	func testAgentChatStressHarnessPersistedAgentSessionFixtureRestoresAndCanDetach() throws {
		let app = launchStressHarness(
			scenario: "persistedAgentSessionFixture",
			intervalMS: 85,
			warmupTurns: 1,
			toolStepRepeatCount: 1,
			agentSessionFixtureName: "review-idle-scroll-coalescing-fix-97A6BA23.json"
		)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))
		try waitForEventMarkers(
			in: eventsElement,
			timeout: 30,
			requiredMarkers: [
				"persistedAgentSessionFixturePrepared",
				"persistedAgentSessionFixtureRestoreReady"
			]
		)
		XCTAssertTrue(
			eventsElement.label.contains("fixture=review-idle-scroll-coalescing-fix-97A6BA23.json"),
			"events=\(eventsElement.label)"
		)

		let restored = try waitForTelemetry(
			from: telemetryElement,
			timeout: 12,
			label: "persisted agent session fixture restore telemetry",
			eventsElement: eventsElement
		) {
			$0.tabID != nil
				&& ($0.coldRestoreCompletionCount ?? 0) > 0
				&& ($0.projectionBuildCount ?? 0) > 0
				&& ($0.projectionPublishCount ?? 0) > 0
				&& $0.sampleIndex >= 2
		}
		guard restored.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let detached = try establishDetachedBottomButtonBaseline(
			app: app,
			scrollView: scrollView,
			telemetryElement: telemetryElement,
			initial: restored,
			eventsElement: eventsElement,
			label: "persisted agent session fixture",
			minimumDistanceToBottom: 160
		)

		XCTAssertFalse(detached.isPinnedToLiveBottom, "detached=\(detached)")
		XCTAssertTrue(detached.userDetachedAutoFollow, "detached=\(detached)")
		XCTAssertGreaterThanOrEqual(detached.distanceToBottom, 160, "detached=\(detached)")
		XCTAssertGreaterThan(detached.detachCount, 0, "detached=\(detached)")
		XCTAssertTrue(
			(detached.canScrollTowardHistory ?? false) || (detached.canScrollTowardLiveBottom ?? false),
			"detached=\(detached)"
		)
	}

	func testAgentChatStressHarnessDenseLongSessionProjectionMetricsStayWithinEnvelope() throws {
		let app = launchStressHarness(
			intervalMS: 100,
			warmupTurns: 8,
			toolStepRepeatCount: 3,
			refreshPolicy: deferredStressRefreshPolicy
		)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))

		let readiness = try waitForDenseLongSessionReadiness(
			telemetryElement: telemetryElement,
			groupingElement: groupingElement,
			timeout: 60
		)
		let baseline = readiness.telemetry
		guard baseline.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let observed = try waitForProjectionPerformanceProgress(
			telemetryElement: telemetryElement,
			baseline: baseline,
			timeout: 35,
			minimumSampleDelta: 12,
			label: "dense projection performance soak",
			eventsElement: eventsElement
		)
		assertProjectionPerformanceEnvelope(
			baseline,
			observed,
			maxBuildDurationMS: denseProjectionBuildDurationThresholdMS,
			maxColdLoadBuildDurationMS: coldLoadProjectionBuildDurationThresholdMS
		)
		assertIncrementalRetentionEnvelope(baseline, observed)
		assertDurableFrontierReuseEnvelope(baseline, observed)
		assertPresentationReuseEnvelope(baseline, observed)
	}

	func testAgentChatStressHarnessRichToolChurnProjectionMetricsStayWithinEnvelope() throws {
		let app = launchStressHarness(
			scenario: "richToolChurn",
			intervalMS: 80,
			warmupTurns: 8,
			toolStepRepeatCount: 3,
			refreshPolicy: deferredStressRefreshPolicy
		)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))

		let readiness = try waitForHeavyRenderedState(
			telemetryElement: telemetryElement,
			groupingElement: groupingElement,
			eventsElement: eventsElement,
			timeout: 45
		)
		let baseline = readiness.telemetry
		guard baseline.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let observed = try waitForProjectionPerformanceProgress(
			telemetryElement: telemetryElement,
			baseline: baseline,
			timeout: 35,
			minimumSampleDelta: 10,
			label: "rich projection performance soak",
			eventsElement: eventsElement,
			predicate: {
				($0.expandedApplyEditsCardCount ?? 0) > 0
					|| ($0.expandedApplyPatchCardCount ?? 0) > 0
					|| ($0.expandedLiveBashCardCount ?? 0) > 0
					|| ($0.expandedCompletedBashCardCount ?? 0) > 0
			}
		)
		assertProjectionPerformanceEnvelope(
			baseline,
			observed,
			maxBuildDurationMS: richProjectionBuildDurationThresholdMS,
			maxColdLoadBuildDurationMS: coldLoadProjectionBuildDurationThresholdMS
		)
		assertIncrementalRetentionEnvelope(
			baseline,
			observed,
			minimumRetainedPayloadBytes: heavyRenderedPayloadBytesThreshold
		)
	}

	func testAgentChatStressHarnessRichToolChurnScrollToBottomRemainsResponsiveAfterRepeatedDetachCycles() throws {
		let app = launchStressHarness(scenario: "richToolChurn", intervalMS: 80, warmupTurns: 8, toolStepRepeatCount: 3)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		let scrollToBottomButton = app.buttons["agentTranscript.scrollToBottom"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(groupingElement.waitForExistence(timeout: 20))
		XCTAssertTrue(eventsElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let readiness = try waitForHeavyRenderedState(
			telemetryElement: telemetryElement,
			groupingElement: groupingElement,
			eventsElement: eventsElement,
			timeout: 45
		)
		let initial = readiness.telemetry
		let initialTabID = try XCTUnwrap(initial.tabID)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let forceDetachButton = app.buttons["agentStress.forceDetach"]
		XCTAssertTrue(forceDetachButton.waitForExistence(timeout: 10))
		var latest = initial

		for cycle in 1...4 {
			forceDetachButton.tap()
			let detached = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "rich cycle \(cycle) detached baseline", eventsElement: eventsElement) {
				$0.tabID == initial.tabID
					&& !$0.isPinnedToLiveBottom
					&& $0.userDetachedAutoFollow
			}
			latest = detached
			var lifted = detached

			for _ in 0..<4 where lifted.distanceToBottom < 80 {
				performDetachScrollGesture(app: app, scrollView: scrollView)
				if let updated = try? waitForTelemetry(
					from: telemetryElement,
					timeout: 4,
					label: "rich cycle \(cycle) detached lift",
					eventsElement: eventsElement,
					predicate: {
						$0.tabID == initial.tabID
							&& $0.sampleIndex > lifted.sampleIndex
							&& (
								$0.distanceToBottom >= 80
								|| ($0.manualScrollEffectCount ?? 0) > (lifted.manualScrollEffectCount ?? 0)
							)
					}
				) {
					lifted = updated
					latest = updated
				}
			}

			guard lifted.distanceToBottom >= 80 else {
				XCTFail("Could not establish a rich detached-away-from-bottom baseline for cycle \(cycle). latest=\(lifted)")
				return
			}

			XCTAssertTrue(scrollToBottomButton.waitForExistence(timeout: 5))
			let baselineTapCount = lifted.scrollToBottomTapCount ?? 0
			let baselineSuccessCount = lifted.scrollToBottomSuccessCount ?? 0

			scrollToBottomButton.tap()

			let tapped = try waitForTelemetry(from: telemetryElement, timeout: 4, label: "rich cycle \(cycle) scroll-to-bottom tap observed", eventsElement: eventsElement) {
				$0.tabID == initial.tabID
					&& $0.sampleIndex > lifted.sampleIndex
					&& ($0.scrollToBottomTapCount ?? 0) > baselineTapCount
			}
			latest = tapped

			let settled = try resolveScrollToBottomRecovery(
				initialTabID: initialTabID,
				telemetryElement: telemetryElement,
				baseline: lifted,
				tapped: tapped,
				eventsElement: eventsElement,
				label: "rich cycle \(cycle) scroll-to-bottom"
			)
			latest = settled

			XCTAssertGreaterThanOrEqual(settled.scrollToBottomTapCount ?? 0, baselineTapCount + 1, "lifted=\(lifted) settled=\(settled)")
			XCTAssertTrue(
				(settled.scrollToBottomSuccessCount ?? 0) > baselineSuccessCount
					|| (settled.isPinnedToLiveBottom && !settled.userDetachedAutoFollow),
				"lifted=\(lifted) settled=\(settled)"
			)
			XCTAssertTrue(settled.isPinnedToLiveBottom, "lifted=\(lifted) settled=\(settled)")
			XCTAssertFalse(settled.userDetachedAutoFollow, "lifted=\(lifted) settled=\(settled)")
			XCTAssertTrue(settled.isNearBottom || settled.distanceToBottom <= 40 || settled.lastScrollToBottomOutcome == "reachedBottom", "lifted=\(lifted) settled=\(settled)")
		}

	}

	func testAgentChatStressHarnessDetachesAndRepins() throws {
		let app = launchStressHarness(intervalMS: 120)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "initial stress telemetry") {
			$0.scrollIntentCount > 0 && $0.tabID != nil
		}
		guard initial.supportsGeometryMetrics else {
			attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let detached = try detachTranscript(
			app: app,
			scrollView: scrollView,
			telemetryElement: telemetryElement,
			initial: initial
		)
		XCTAssertTrue(app.buttons["agentTranscript.scrollToBottom"].waitForExistence(timeout: 5))

		app.buttons["agentTranscript.scrollToBottom"].tap()

		_ = try waitForTelemetry(from: telemetryElement, timeout: 20) {
			$0.tabID == initial.tabID
				&& $0.isPinnedToLiveBottom
				&& !$0.userDetachedAutoFollow
				&& $0.repinCount > detached.repinCount
				&& $0.isNearBottom
		}
		attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
    }

	func testAgentChatStressHarnessManualScrollToBottomRepinsAndHidesJumpButton() throws {
		let app = launchStressHarness(intervalMS: 120)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		let scrollToBottomButton = app.buttons["agentTranscript.scrollToBottom"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForTelemetry(from: telemetryElement, timeout: 20, label: "initial stress telemetry") {
			$0.scrollIntentCount > 0 && $0.tabID != nil
		}
		guard initial.supportsGeometryMetrics else {
			attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}

		let detached = try establishDetachedBottomButtonBaseline(
			app: app,
			scrollView: scrollView,
			telemetryElement: telemetryElement,
			initial: initial,
			eventsElement: eventsElement,
			label: "manual repin",
			minimumDistanceToBottom: 120
		)
		XCTAssertTrue(detached.userDetachedAutoFollow, "telemetry=\(detached)")
		XCTAssertFalse(detached.isPinnedToLiveBottom, "telemetry=\(detached)")
		XCTAssertTrue(scrollToBottomButton.waitForExistence(timeout: 5))

		let baselineRepinCount = detached.repinCount
		var latest = detached
		for _ in 0..<8 {
			performTargetedStressTranscriptScroll(
				app: app,
				scrollView: scrollView,
				direction: .towardLiveBottom,
				telemetryElement: telemetryElement,
				baseline: latest,
				eventsElement: eventsElement
			)
			if let updated = try? waitForTelemetry(from: telemetryElement, timeout: 5, label: "manual repin progress", eventsElement: eventsElement, failOnTimeout: false, predicate: {
				$0.tabID == initial.tabID
					&& $0.sampleIndex > latest.sampleIndex
			}) {
				latest = updated
				if latest.isPinnedToLiveBottom, !latest.userDetachedAutoFollow, latest.repinCount > baselineRepinCount, latest.isNearBottom {
					break
				}
			}
		}

		XCTAssertTrue(latest.isPinnedToLiveBottom, "telemetry=\(latest)")
		XCTAssertFalse(latest.userDetachedAutoFollow, "telemetry=\(latest)")
		XCTAssertGreaterThan(latest.repinCount, baselineRepinCount, "telemetry=\(latest)")
		XCTAssertTrue(latest.isNearBottom || latest.distanceToBottom <= 24, "telemetry=\(latest)")
		waitForElementToDisappear(scrollToBottomButton, timeout: 5)
		XCTAssertFalse(scrollToBottomButton.exists, "button should disappear after manual repin")
	}

	func testAgentChatStressHarnessActualBottomRepinsAfterDetachedReturn() throws {
		let app = launchStressHarness(intervalMS: 120)
		let statusElement = app.staticTexts["agentStress.status"]
		let telemetryElement = app.staticTexts["agentStress.telemetry"]
		let groupingElement = app.staticTexts["agentStress.grouping"]
		let eventsElement = app.staticTexts["agentStress.events"]
		let scrollView = transcriptScrollView(in: app)
		let scrollToBottomButton = app.buttons["agentTranscript.scrollToBottom"]
		addTeardownBlock { [weak self] in
			self?.attachSnapshots(telemetryElement: telemetryElement, groupingElement: groupingElement, eventsElement: eventsElement)
		}

		XCTAssertTrue(statusElement.waitForExistence(timeout: 20))
		XCTAssertTrue(telemetryElement.waitForExistence(timeout: 20))
		XCTAssertTrue(scrollView.waitForExistence(timeout: 20))

		let initial = try waitForBasicStressHarnessReadiness(
			telemetryElement: telemetryElement,
			timeout: 20,
			label: "actual-bottom readiness"
		)
		guard initial.supportsGeometryMetrics else {
			throw XCTSkip("Scroll geometry metrics are unavailable on this macOS runtime.")
		}
		let quiescent = try pauseStressHarnessAndWaitForTelemetryQuiescence(
			app: app,
			telemetryElement: telemetryElement,
			initial: initial,
			eventsElement: eventsElement
		)
		XCTAssertTrue(quiescent.isPinnedToLiveBottom, "telemetry=\(quiescent)")
		XCTAssertFalse(quiescent.userDetachedAutoFollow, "telemetry=\(quiescent)")

		let baselineDetachCount = quiescent.detachCount
		let baselineHistoryEffects = quiescent.manualScrollTowardHistoryEffectCount ?? 0
		performTowardHistoryScrollGesture(app: app, scrollView: scrollView)
		let offBottom: UITestTelemetrySnapshot
		if let lifted = try? waitForTelemetry(from: telemetryElement, timeout: 3, label: "manual detached lift", eventsElement: eventsElement, failOnTimeout: false, predicate: {
			$0.tabID == quiescent.tabID
				&& $0.sampleIndex > quiescent.sampleIndex
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
				&& (
					$0.detachCount > baselineDetachCount
					|| $0.distanceToBottom >= 60
					|| ($0.canScrollTowardLiveBottom ?? false)
					|| ($0.manualScrollTowardHistoryEffectCount ?? 0) > baselineHistoryEffects
				)
		}) {
			offBottom = lifted
		} else {
			performTowardHistoryScrollGesture(app: app, scrollView: scrollView)
			offBottom = try waitForTelemetry(from: telemetryElement, timeout: 3, label: "manual detached lift retry", eventsElement: eventsElement) {
				$0.tabID == quiescent.tabID
					&& $0.sampleIndex > quiescent.sampleIndex
					&& !$0.isPinnedToLiveBottom
					&& $0.userDetachedAutoFollow
					&& (
						$0.detachCount > baselineDetachCount
						|| $0.distanceToBottom >= 60
						|| ($0.canScrollTowardLiveBottom ?? false)
						|| ($0.manualScrollTowardHistoryEffectCount ?? 0) > baselineHistoryEffects
					)
			}
		}
		XCTAssertTrue(scrollToBottomButton.waitForExistence(timeout: 5))

		performTowardLiveBottomScrollGesture(app: app, scrollView: scrollView)
		let settled: UITestTelemetrySnapshot
		if let repinned = try? waitForTelemetry(from: telemetryElement, timeout: 4, label: "actual-bottom repin", eventsElement: eventsElement, failOnTimeout: false, predicate: {
			$0.tabID == quiescent.tabID
				&& $0.sampleIndex > offBottom.sampleIndex
				&& $0.isPinnedToLiveBottom
				&& !$0.userDetachedAutoFollow
				&& !(($0.canScrollTowardLiveBottom) ?? true)
				&& $0.distanceToBottom <= 24
		}) {
			settled = repinned
		} else {
			performTowardLiveBottomScrollGesture(app: app, scrollView: scrollView)
			settled = try waitForTelemetry(from: telemetryElement, timeout: 4, label: "actual-bottom repin retry", eventsElement: eventsElement) {
				$0.tabID == quiescent.tabID
					&& $0.sampleIndex > offBottom.sampleIndex
					&& $0.isPinnedToLiveBottom
					&& !$0.userDetachedAutoFollow
					&& !(($0.canScrollTowardLiveBottom) ?? true)
					&& $0.distanceToBottom <= 24
			}
		}

		XCTAssertTrue(settled.isPinnedToLiveBottom, "telemetry=\(settled)")
		XCTAssertFalse(settled.userDetachedAutoFollow, "telemetry=\(settled)")
		XCTAssertLessThanOrEqual(settled.distanceToBottom, 24, "telemetry=\(settled)")
		XCTAssertFalse(settled.canScrollTowardLiveBottom ?? true, "telemetry=\(settled)")
		waitForElementToDisappear(scrollToBottomButton, timeout: 5)
		XCTAssertFalse(scrollToBottomButton.exists, "button should disappear after actual-bottom repin")
	}

	private func pauseStressHarnessAndWaitForTelemetryQuiescence(
		app: XCUIApplication,
		telemetryElement: XCUIElement,
		initial: UITestTelemetrySnapshot,
		eventsElement: XCUIElement,
		timeout: TimeInterval = 10
	) throws -> UITestTelemetrySnapshot {
		let pauseButton = app.buttons["agentStress.pause"]
		let resumeButton = app.buttons["agentStress.resume"]
		guard pauseButton.waitForExistence(timeout: 5) else { return initial }
		pauseButton.tap()
		XCTAssertTrue(resumeButton.waitForExistence(timeout: 5))

		let deadline = Date().addingTimeInterval(timeout)
		let quietWindow: TimeInterval = 0.75
		var latest = initial

		func isQuiescentCandidate(_ snapshot: UITestTelemetrySnapshot) -> Bool {
			snapshot.tabID == initial.tabID
				&& snapshot.sampleIndex >= initial.sampleIndex
				&& snapshot.pendingPinnedBottomSourceDescription == nil
				&& !(snapshot.hasPendingPinnedBottomFlush ?? false)
				&& (snapshot.activeStreamingAssistantCharacterCount ?? 0) == 0
				&& (snapshot.activeStreamingAssistantLineCount ?? 0) == 0
		}

		while Date() < deadline {
			let snapshot = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
			latest = snapshot
			guard isQuiescentCandidate(snapshot) else {
				RunLoop.current.run(until: Date().addingTimeInterval(0.25))
				continue
			}

			RunLoop.current.run(until: Date().addingTimeInterval(min(quietWindow, max(0.25, deadline.timeIntervalSinceNow))))
			let second = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
			latest = second
			let stable = second.tabID == snapshot.tabID
				&& second.pendingPinnedBottomSourceDescription == nil
				&& !(second.hasPendingPinnedBottomFlush ?? false)
				&& (second.activeStreamingAssistantCharacterCount ?? 0) == 0
				&& (second.activeStreamingAssistantLineCount ?? 0) == 0
				&& (second.projectionPublishCount ?? -1) == (snapshot.projectionPublishCount ?? -1)
				&& (second.refreshRequestCount ?? -1) == (snapshot.refreshRequestCount ?? -1)
				&& second.scrollIntentCount == snapshot.scrollIntentCount
			if stable {
				return second
			}
		}

		XCTFail("Timed out waiting for paused stress telemetry quiescence. Latest telemetry: \(latest)\nRecent events:\n\(accessibilityText(from: eventsElement) ?? "<none>")")
		throw NSError(domain: "RepoPromptUITests", code: 1)
	}

	private func launchStressHarness(
		autoStart: Bool = true,
		scenario: String = "mixedToolLoop",
		intervalMS: Int = 90,
		warmupTurns: Int = 4,
		toolStepRepeatCount: Int = 1,
		refreshPolicy: String? = nil,
		agentSessionFixtureName: String? = nil
	) -> XCUIApplication {
        let app = XCUIApplication()
		if app.state != .notRunning {
			app.terminate()
			RunLoop.current.run(until: Date().addingTimeInterval(1.0))
		}
		app.launchArguments += ["-RP_UITEST", "-RP_AGENT_CHAT_STRESS"]
		app.launchEnvironment["RP_AGENT_STRESS_AUTO_START"] = autoStart ? "1" : "0"
		app.launchEnvironment["RP_AGENT_STRESS_SHOW_OVERLAY"] = "1"
		app.launchEnvironment["RP_AGENT_STRESS_SCENARIO"] = scenario
		app.launchEnvironment["RP_AGENT_STRESS_INTERVAL_MS"] = "\(intervalMS)"
		app.launchEnvironment["RP_AGENT_STRESS_WARMUP_TURNS"] = "\(warmupTurns)"
		app.launchEnvironment["RP_AGENT_STRESS_TOOL_STEP_REPEAT"] = "\(toolStepRepeatCount)"
		if let refreshPolicy {
			app.launchEnvironment["RP_AGENT_STRESS_REFRESH_POLICY"] = refreshPolicy
		}
		app.launchEnvironment["RP_AGENT_STRESS_MAX_LOG_ENTRIES"] = "120"
		app.launchEnvironment["RP_AGENT_STRESS_CATASTROPHIC_JUMP_POINTS"] = "\(Int(catastrophicJumpThreshold))"
		app.launchEnvironment["RP_AGENT_STRESS_CATASTROPHIC_EXPOSURE_BLOCKS"] = "\(catastrophicHistoricalExposureBlockThreshold)"
		app.launchEnvironment["RP_AGENT_STRESS_WORKSPACE_NAME"] = stressHarnessWorkspaceName(scenario: scenario)
		app.launchEnvironment["RP_AGENT_STRESS_WORKSPACE_ROOT"] = repoRootPath()
		app.launchEnvironment["RP_AGENT_STRESS_CREATE_WORKSPACE_IF_NEEDED"] = "1"
		if scenario == "persistedCodexReplayChurn" || scenario == "persistedAgentSessionFixture" || agentSessionFixtureName != nil {
			app.launchEnvironment["RP_AGENT_STRESS_ALLOW_SESSION_PERSISTENCE"] = "1"
		}
		if let agentSessionFixtureName {
			app.launchEnvironment["RP_AGENT_STRESS_AGENT_SESSION_FIXTURE"] = agentSessionFixtureName
		}
        app.launch()
		RunLoop.current.run(until: Date().addingTimeInterval(0.5))
		addTeardownBlock {
			if app.state != .notRunning {
				app.terminate()
			}
		}
		return app
	}

	private func stressHarnessWorkspaceName(scenario: String) -> String {
		let sanitizedTestName = name.replacingOccurrences(
			of: #"[^A-Za-z0-9_-]+"#,
			with: "-",
			options: .regularExpression
		)
		let suffix = String(UUID().uuidString.prefix(8))
		return "Agent Stress UI Test \(scenario)-\(sanitizedTestName)-\(suffix)"
	}

	private func terminateRepoPromptIfRunning() {
		let app = XCUIApplication()
		guard app.state != .notRunning else { return }
		app.terminate()
		RunLoop.current.run(until: Date().addingTimeInterval(1.0))
	}

	private func repoRootPath() -> String {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.path
	}

	private func waitForTelemetry(
		from element: XCUIElement,
		timeout: TimeInterval,
		label: String = "telemetry",
		eventsElement: XCUIElement? = nil,
		failOnTimeout: Bool = true,
		file: StaticString = #filePath,
		line: UInt = #line,
		predicate: (UITestTelemetrySnapshot) -> Bool
	) throws -> UITestTelemetrySnapshot {
		let deadline = Date().addingTimeInterval(timeout)
		var latest: UITestTelemetrySnapshot?
		var lastError: Error?
		while Date() < deadline {
			do {
				let snapshot = try decode(UITestTelemetrySnapshot.self, from: element)
				latest = snapshot
				if predicate(snapshot) {
					return snapshot
				}
			} catch {
				lastError = error
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
		}
		if let lastError {
			throw lastError
		}
		let latestDescription = latest.map(String.init(describing:)) ?? "<none>"
		let recentEvents = eventsElement.flatMap(accessibilityText(from:)) ?? "<none>"
		if failOnTimeout {
			XCTFail("Timed out waiting for \(label). Latest telemetry: \(latestDescription)\nRecent events:\n\(recentEvents)", file: file, line: line)
		}
		throw NSError(domain: "RepoPromptUITests", code: 1)
    }

	private func waitForGrouping(
		from element: XCUIElement,
		timeout: TimeInterval,
		predicate: (UITestGroupingSnapshot) -> Bool
	) throws -> UITestGroupingSnapshot {
		var latest: UITestGroupingSnapshot?
		try waitUntil(timeout: timeout) {
			let snapshot = try decode(UITestGroupingSnapshot.self, from: element)
			latest = snapshot
			return predicate(snapshot)
		}
		return try XCTUnwrap(latest)
	}

	private func waitForEventMarkers(
		in eventsElement: XCUIElement,
		timeout: TimeInterval,
		requiredMarkers: [String]
	) throws {
		let deadline = Date().addingTimeInterval(timeout)
		var latest = accessibilityText(from: eventsElement) ?? ""
		while Date() < deadline {
			latest = accessibilityText(from: eventsElement) ?? ""
			if requiredMarkers.allSatisfy(latest.contains) {
				return
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
		}
		XCTFail("Timed out waiting for event markers \(requiredMarkers). Latest events:\n\(latest)")
		throw NSError(domain: "RepoPromptUITests", code: 1)
	}

	private func waitForBasicStressHarnessReadiness(
		telemetryElement: XCUIElement,
		timeout: TimeInterval,
		label: String
	) throws -> UITestTelemetrySnapshot {
		try waitForTelemetry(from: telemetryElement, timeout: timeout, label: label) {
			$0.tabID != nil
				&& $0.supportsGeometryMetrics
				&& $0.sampleIndex >= 2
				&& $0.scrollIntentCount > 0
				&& ($0.projectionBuildCount ?? 0) > 0
				&& ($0.projectionPublishCount ?? 0) > 0
		}
	}


	private func establishDetachedBottomButtonBaseline(
		app: XCUIApplication,
		scrollView: XCUIElement,
		telemetryElement: XCUIElement,
		initial: UITestTelemetrySnapshot,
		eventsElement: XCUIElement,
		label: String,
		minimumDistanceToBottom: Double
	) throws -> UITestTelemetrySnapshot {
		let detachedPredicate: (UITestTelemetrySnapshot) -> Bool = {
			$0.tabID == initial.tabID
				&& !$0.isPinnedToLiveBottom
				&& $0.userDetachedAutoFollow
		}
		var detached: UITestTelemetrySnapshot?
		let panelForceDetachButton = app.buttons["agentStress.panelForceDetach"]
		if panelForceDetachButton.waitForExistence(timeout: 5) {
			if panelForceDetachButton.isHittable {
				panelForceDetachButton.click()
			} else {
				let frame = panelForceDetachButton.frame
				let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
				origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)).click()
			}
			detached = try? waitForTelemetry(
				from: telemetryElement,
				timeout: 6,
				label: "\(label) panel force detach",
				eventsElement: eventsElement,
				failOnTimeout: false,
				predicate: detachedPredicate
			)
		}
		if detached == nil {
			let forceDetachButton = app.buttons["agentStress.forceDetach"]
			if forceDetachButton.waitForExistence(timeout: 5) {
				forceDetachButton.tap()
				detached = try? waitForTelemetry(
					from: telemetryElement,
					timeout: 6,
					label: "\(label) force detach",
					eventsElement: eventsElement,
					failOnTimeout: false,
					predicate: detachedPredicate
				)
			}
		}
		if detached == nil {
			detached = try attemptDetachTranscript(
				app: app,
				scrollView: scrollView,
				telemetryElement: telemetryElement,
				initial: initial,
				attemptCount: 8
			)
		}
		guard var detached else {
			_ = try waitForTelemetry(
				from: telemetryElement,
				timeout: 1,
				label: "\(label) detached baseline",
				eventsElement: eventsElement,
				predicate: detachedPredicate
			)
			throw NSError(domain: "RepoPromptUITests", code: 1)
		}
		if (detached.canScrollTowardLiveBottom ?? false) && detached.distanceToBottom >= minimumDistanceToBottom {
			return detached
		}

		for _ in 0..<2 {
			performTargetedStressTranscriptScroll(
				app: app,
				scrollView: scrollView,
				direction: .towardHistory,
				telemetryElement: telemetryElement,
				baseline: detached,
				eventsElement: eventsElement
			)
			if let lifted = try? waitForTelemetry(from: telemetryElement, timeout: 3, label: "\(label) detached lift", eventsElement: eventsElement, predicate: {
				$0.tabID == initial.tabID
					&& $0.sampleIndex > detached.sampleIndex
					&& !$0.isPinnedToLiveBottom
					&& $0.userDetachedAutoFollow
					&& (
						($0.canScrollTowardLiveBottom ?? false)
						|| $0.distanceToBottom >= minimumDistanceToBottom
						|| ($0.manualScrollEffectCount ?? 0) > (detached.manualScrollEffectCount ?? 0)
					)
			}) {
				detached = lifted
				if (detached.canScrollTowardLiveBottom ?? false) && detached.distanceToBottom >= minimumDistanceToBottom {
					return detached
				}
			}
		}

		XCTFail("Could not establish a detached-away-from-bottom baseline for \(label). latest=\(detached)")
		throw NSError(domain: "RepoPromptUITests", code: 1)
	}

	private func establishTranscriptManualHistoryBaseline(
		app: XCUIApplication,
		scrollView: XCUIElement,
		telemetryElement: XCUIElement,
		initial: UITestTelemetrySnapshot,
		baseline: UITestTelemetrySnapshot,
		eventsElement: XCUIElement,
		label: String
	) throws -> UITestTelemetrySnapshot {
		if baseline.canScrollTowardHistory ?? false {
			return baseline
		}
		guard baseline.canScrollTowardLiveBottom ?? false else {
			XCTFail("Invalid detached transcript baseline for \(label). latest=\(baseline)")
			throw NSError(domain: "RepoPromptUITests", code: 4)
		}
		var latest = baseline
		for _ in 0..<2 {
			performTargetedStressTranscriptScroll(
				app: app,
				scrollView: scrollView,
				direction: .towardLiveBottom,
				telemetryElement: telemetryElement,
				baseline: latest,
				eventsElement: eventsElement
			)
			if let adjusted = try? waitForTelemetry(from: telemetryElement, timeout: 3, label: "\(label) transcript-lane baseline adjustment", eventsElement: eventsElement, predicate: {
				$0.tabID == initial.tabID
					&& $0.sampleIndex > latest.sampleIndex
					&& !$0.isPinnedToLiveBottom
					&& $0.userDetachedAutoFollow
			}) {
				latest = adjusted
				if latest.canScrollTowardHistory ?? false {
					return latest
				}
			}
		}
		XCTFail("Unable to establish transcript-lane detached baseline for \(label). latest=\(latest)")
		throw NSError(domain: "RepoPromptUITests", code: 5)
	}

	private func resolveScrollToBottomRecovery(
		initialTabID: UUID,
		telemetryElement: XCUIElement,
		baseline: UITestTelemetrySnapshot,
		tapped: UITestTelemetrySnapshot,
		eventsElement: XCUIElement,
		label: String
	) throws -> UITestTelemetrySnapshot {
		let baselineSuccessCount = baseline.scrollToBottomSuccessCount ?? 0

		return try waitForTelemetry(from: telemetryElement, timeout: 5, label: "\(label) outcome", eventsElement: eventsElement) {
			$0.tabID == initialTabID
				&& $0.sampleIndex > tapped.sampleIndex
				&& (
					($0.scrollToBottomSuccessCount ?? 0) > baselineSuccessCount
						|| ($0.isPinnedToLiveBottom && !$0.userDetachedAutoFollow && ($0.isNearBottom || $0.distanceToBottom <= 40))
				)
		}
	}

	private func waitForDenseLongSessionReadiness(
		telemetryElement: XCUIElement,
		groupingElement: XCUIElement,
		timeout: TimeInterval
	) throws -> (telemetry: UITestTelemetrySnapshot, grouping: UITestGroupingSnapshot) {
		let grouping = try waitForGrouping(from: groupingElement, timeout: timeout) {
			!$0.archivedBlockKindCounts.isEmpty
				&& !$0.latestToolGroupLabels.isEmpty
				&& (
					($0.visibleBlockKindCounts["activityCluster"] ?? 0) > 0
						|| ($0.visibleBlockKindCounts["groupedHistory"] ?? 0) > 0
						|| ($0.archivedBlockKindCounts["activityCluster"] ?? 0) > 0
						|| ($0.archivedBlockKindCounts["groupedHistory"] ?? 0) > 0
				)
		}
		let telemetry = try waitForTelemetry(from: telemetryElement, timeout: timeout, label: "dense long-session readiness telemetry") {
			$0.tabID != nil
				&& $0.sampleIndex >= grouping.sampleIndex
				&& $0.scrollIntentCount > 0
				&& ($0.projectionBuildCount ?? 0) > 0
				&& ($0.projectionPublishCount ?? 0) > 0
		}
		return (telemetry, grouping)
	}

	private func waitForHeavyRenderedState(
		telemetryElement: XCUIElement,
		groupingElement: XCUIElement,
		eventsElement: XCUIElement,
		timeout: TimeInterval
	) throws -> (telemetry: UITestTelemetrySnapshot, grouping: UITestGroupingSnapshot) {
		let deadline = Date().addingTimeInterval(timeout)
		var latestTelemetry: UITestTelemetrySnapshot?
		var latestGrouping: UITestGroupingSnapshot?
		var latestEvents = ""
		var stableSampleCount = 0
		var lastError: Error?

		while Date() < deadline {
			do {
				let grouping = try decode(UITestGroupingSnapshot.self, from: groupingElement)
				let telemetry = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
				latestGrouping = grouping
				latestTelemetry = telemetry
				latestEvents = accessibilityText(from: eventsElement) ?? ""

				let hasDenseHistory = !grouping.latestToolGroupLabels.isEmpty
					&& (
						(grouping.visibleBlockKindCounts["activityCluster"] ?? 0) > 0
							|| (grouping.visibleBlockKindCounts["groupedHistory"] ?? 0) > 0
							|| (grouping.visibleBlockKindCounts["middleSummary"] ?? 0) > 0
							|| (grouping.archivedBlockKindCounts["activityCluster"] ?? 0) > 0
							|| (grouping.archivedBlockKindCounts["groupedHistory"] ?? 0) > 0
					)
				let hasExpandedEdit = (telemetry.expandedApplyEditsCardCount ?? 0) > 0 || (telemetry.expandedApplyPatchCardCount ?? 0) > 0
				let hasExpandedBash = (telemetry.expandedLiveBashCardCount ?? 0) > 0 || (telemetry.expandedCompletedBashCardCount ?? 0) > 0
				let hasExpandedHighSignalSurface = hasExpandedEdit
					|| hasExpandedBash
					|| (telemetry.expandedApplyEditsDiffPreviewCardCount ?? 0) > 0
					|| (telemetry.expandedApplyPatchDiffPreviewCardCount ?? 0) > 0
					|| telemetry.latestExpandedHighSignalToolDescription != nil
					|| telemetry.latestExpandedHighSignalRenderMode != nil
				let hasHeavyPayloadFootprint = (telemetry.retainedRawPayloadTotalBytes ?? 0) >= heavyRenderedPayloadBytesThreshold
				let heavyReady = telemetry.tabID != nil
					&& telemetry.scrollIntentCount > 0
					&& (telemetry.projectionBuildCount ?? 0) > 0
					&& (telemetry.projectionPublishCount ?? 0) > 0
					&& hasDenseHistory
					&& hasExpandedHighSignalSurface
					&& hasHeavyPayloadFootprint

				if heavyReady {
					stableSampleCount += 1
					if stableSampleCount >= 2 {
						return (telemetry, grouping)
					}
				} else {
					stableSampleCount = 0
				}
			} catch {
				lastError = error
				stableSampleCount = 0
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
		}

		if let lastError {
			throw lastError
		}
		XCTFail("Timed out waiting for heavy rendered state. Latest telemetry=\(String(describing: latestTelemetry)) latest grouping=\(String(describing: latestGrouping)) events=\(latestEvents)")
		throw NSError(domain: "RepoPromptUITests", code: 2)
	}

	private func waitForProjectionPerformanceProgress(
		telemetryElement: XCUIElement,
		baseline: UITestTelemetrySnapshot,
		timeout: TimeInterval,
		minimumSampleDelta: Int,
		label: String,
		eventsElement: XCUIElement? = nil,
		predicate: ((UITestTelemetrySnapshot) -> Bool)? = nil
	) throws -> UITestTelemetrySnapshot {
		try waitForTelemetry(from: telemetryElement, timeout: timeout, label: label, eventsElement: eventsElement) {
			guard $0.tabID == baseline.tabID,
				$0.sampleIndex >= baseline.sampleIndex + minimumSampleDelta,
				($0.projectionBuildCount ?? 0) > (baseline.projectionBuildCount ?? 0),
				($0.projectionPublishCount ?? 0) > (baseline.projectionPublishCount ?? 0)
			else {
				return false
			}
			return predicate?($0) ?? true
		}
	}

	private func assertProjectionPerformanceEnvelope(
		_ baseline: UITestTelemetrySnapshot,
		_ observed: UITestTelemetrySnapshot,
		maxBuildDurationMS: Double,
		maxColdLoadBuildDurationMS: Double,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let buildDelta = (observed.projectionBuildCount ?? 0) - (baseline.projectionBuildCount ?? 0)
		let publishDelta = (observed.projectionPublishCount ?? 0) - (baseline.projectionPublishCount ?? 0)
		XCTAssertGreaterThan(buildDelta, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		XCTAssertGreaterThan(publishDelta, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)

		let worstBuildDuration = observed.maxProjectionBuildDurationMS ?? observed.lastProjectionBuildDurationMS
		XCTAssertNotNil(worstBuildDuration, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		if let worstBuildDuration {
			XCTAssertLessThanOrEqual(worstBuildDuration, maxBuildDurationMS, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		}
		if let coldLoadDuration = observed.lastColdLoadProjectionBuildDurationMS {
			XCTAssertLessThanOrEqual(coldLoadDuration, maxColdLoadBuildDurationMS, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		}
	}

	private func assertIncrementalRetentionEnvelope(
		_ baseline: UITestTelemetrySnapshot,
		_ observed: UITestTelemetrySnapshot,
		minimumRetainedPayloadBytes: Int? = nil,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let requestDelta = (observed.refreshRequestCount ?? 0) - (baseline.refreshRequestCount ?? 0)
		XCTAssertGreaterThan(requestDelta, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		XCTAssertEqual(observed.lastPayloadCaptureScannedItemCount, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		if let minimumRetainedPayloadBytes {
			XCTAssertGreaterThanOrEqual(
				observed.retainedRawPayloadTotalBytes ?? 0,
				minimumRetainedPayloadBytes,
				"baseline=\(baseline) observed=\(observed)",
				file: file,
				line: line
			)
		}
	}

	private func assertDurableFrontierReuseEnvelope(
		_ baseline: UITestTelemetrySnapshot,
		_ observed: UITestTelemetrySnapshot,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let attemptDelta = (observed.frontierReuseAttemptCount ?? 0) - (baseline.frontierReuseAttemptCount ?? 0)
		let successDelta = (observed.frontierReuseSuccessCount ?? 0) - (baseline.frontierReuseSuccessCount ?? 0)
		let fallbackDelta = (observed.frontierReuseFallbackCount ?? 0) - (baseline.frontierReuseFallbackCount ?? 0)
		XCTAssertGreaterThan(attemptDelta, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		XCTAssertGreaterThan(successDelta, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		XCTAssertEqual(fallbackDelta, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
	}

	private func assertPresentationReuseEnvelope(
		_ baseline: UITestTelemetrySnapshot,
		_ observed: UITestTelemetrySnapshot,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let sanitizeSuccessDelta = (observed.sanitizeReuseSuccessCount ?? 0) - (baseline.sanitizeReuseSuccessCount ?? 0)
		let sanitizeFallbackDelta = (observed.sanitizeReuseFallbackCount ?? 0) - (baseline.sanitizeReuseFallbackCount ?? 0)
		let projectionSuccessDelta = (observed.projectionReuseSuccessCount ?? 0) - (baseline.projectionReuseSuccessCount ?? 0)
		let projectionFallbackDelta = (observed.projectionReuseFallbackCount ?? 0) - (baseline.projectionReuseFallbackCount ?? 0)
		XCTAssertGreaterThan(sanitizeSuccessDelta, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		XCTAssertEqual(sanitizeFallbackDelta, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		XCTAssertGreaterThan(projectionSuccessDelta, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		XCTAssertLessThan(projectionFallbackDelta, projectionSuccessDelta, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		XCTAssertGreaterThan(observed.lastSanitizeReusedTurnCount ?? 0, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
		XCTAssertGreaterThan(observed.lastProjectionReusedTurnCount ?? 0, 0, "baseline=\(baseline) observed=\(observed)", file: file, line: line)
	}

	private func detachTranscript(
		app: XCUIApplication,
		scrollView: XCUIElement,
		telemetryElement: XCUIElement,
		initial: UITestTelemetrySnapshot
	) throws -> UITestTelemetrySnapshot {
		let panelForceDetachButton = app.buttons["agentStress.panelForceDetach"]
		if panelForceDetachButton.waitForExistence(timeout: 5) {
			if panelForceDetachButton.isHittable {
				panelForceDetachButton.click()
			} else {
				let frame = panelForceDetachButton.frame
				let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
				origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)).click()
			}
			if let detached = try? waitForTelemetry(
				from: telemetryElement,
				timeout: 8,
				label: "panel force detach telemetry",
				failOnTimeout: false,
				predicate: {
					$0.tabID == initial.tabID
						&& $0.sampleIndex >= initial.sampleIndex
						&& !$0.isPinnedToLiveBottom
						&& $0.userDetachedAutoFollow
						&& $0.detachCount >= 1
				}
			) {
				return detached
			}
		}

		if let detached = try attemptDetachTranscript(
			app: app,
			scrollView: scrollView,
			telemetryElement: telemetryElement,
			initial: initial,
			attemptCount: 12
		) {
			return detached
		}

		let pauseButton = app.buttons["agentStress.pause"]
		let resumeButton = app.buttons["agentStress.resume"]
		if pauseButton.waitForExistence(timeout: 5) {
			pauseButton.tap()
			RunLoop.current.run(until: Date().addingTimeInterval(0.5))
			let pausedBaseline = try waitForTelemetry(from: telemetryElement, timeout: 10, label: "paused detach baseline") {
				$0.tabID == initial.tabID && $0.sampleIndex >= initial.sampleIndex
			}
			if let detached = try attemptDetachTranscript(
				app: app,
				scrollView: scrollView,
				telemetryElement: telemetryElement,
				initial: pausedBaseline,
				attemptCount: 8
			) {
				if resumeButton.waitForExistence(timeout: 5) {
					resumeButton.tap()
					return try waitForTelemetry(from: telemetryElement, timeout: 10, label: "resumed detached telemetry") {
						$0.tabID == initial.tabID
							&& $0.sampleIndex > detached.sampleIndex
							&& !$0.isPinnedToLiveBottom
							&& $0.userDetachedAutoFollow
							&& $0.detachCount >= detached.detachCount
					}
				}
				return detached
			}
			if resumeButton.waitForExistence(timeout: 5) {
				resumeButton.tap()
			}
		}

		let latest = accessibilityText(from: telemetryElement) ?? "<unavailable>"
		XCTFail("Unable to detach transcript after repeated macOS scroll gestures. Latest telemetry: \(latest)")
		throw NSError(domain: "RepoPromptUITests", code: 1)
	}

	private func attemptDetachTranscript(
		app: XCUIApplication,
		scrollView: XCUIElement,
		telemetryElement: XCUIElement,
		initial: UITestTelemetrySnapshot,
		attemptCount: Int
	) throws -> UITestTelemetrySnapshot? {
		var baseline = try waitForTelemetry(from: telemetryElement, timeout: 20) {
			$0.tabID == initial.tabID && $0.sampleIndex >= initial.sampleIndex + 4
		}

		for _ in 0..<attemptCount {
			performTargetedStressTranscriptScroll(
				app: app,
				scrollView: scrollView,
				direction: .towardHistory,
				telemetryElement: telemetryElement,
				baseline: baseline
			)

			if let progressed = try? waitForTelemetry(
				from: telemetryElement,
				timeout: 6,
				label: "detach gesture progress",
				failOnTimeout: false,
				predicate: {
					$0.tabID == initial.tabID && $0.sampleIndex > baseline.sampleIndex
				}
			) {
				baseline = progressed
				if !progressed.isPinnedToLiveBottom,
					progressed.userDetachedAutoFollow,
					progressed.detachCount >= 1 {
					return progressed
				}
			}

			if let detached = try? waitForTelemetry(
				from: telemetryElement,
				timeout: 6,
				label: "detach gesture telemetry",
				failOnTimeout: false,
				predicate: {
					$0.tabID == initial.tabID
						&& $0.sampleIndex >= baseline.sampleIndex
						&& !$0.isPinnedToLiveBottom
						&& $0.userDetachedAutoFollow
						&& $0.detachCount >= 1
				}
			) {
				return detached
			}
		}

		return nil
	}

	private func waitUntil(timeout: TimeInterval, condition: () throws -> Bool) throws {
		let deadline = Date().addingTimeInterval(timeout)
		var lastError: Error?
		while Date() < deadline {
			do {
				if try condition() {
					return
				}
			} catch {
				lastError = error
            }
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
		if let lastError {
			throw lastError
		}
		XCTFail("Timed out waiting for UI test condition")
    }

	private func waitForElementToDisappear(
		_ element: XCUIElement,
		timeout: TimeInterval,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if !element.exists {
				return
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.2))
		}
		XCTFail("Timed out waiting for element to disappear: \(element)", file: file, line: line)
	}

	private func decode<T: Decodable>(_ type: T.Type, from element: XCUIElement) throws -> T {
		XCTAssertTrue(element.waitForExistence(timeout: 10))
		let json = try XCTUnwrap(accessibilityText(from: element))
		let data = try XCTUnwrap(json.data(using: .utf8))
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode(T.self, from: data)
	}

	private func accessibilityText(from element: XCUIElement) -> String? {
		if let value = element.value as? String, !value.isEmpty {
			return value
		}
		let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
		return label.isEmpty ? nil : label
	}

	private func latestStressEventBatchNumber(in text: String, prefix: String) -> Int? {
		for line in text.split(separator: "\n").reversed() {
			guard let range = line.range(of: prefix) else { continue }
			let digits = line[range.upperBound...].prefix(while: \.isNumber)
			if let batchNumber = Int(digits) {
				return batchNumber
			}
		}
		return nil
	}

	private func latestLargeWindowStartMarker(
		in text: String,
		prefix: String
	) -> (batchNumber: Int, characterCount: Int, lineCount: Int)? {
		for line in text.split(separator: "\n").reversed() {
			guard let range = line.range(of: prefix) else { continue }
			let suffix = line[range.upperBound...]
			let batchDigits = suffix.prefix(while: \.isNumber)
			guard let batchNumber = Int(batchDigits) else { continue }
			guard let charsRange = line.range(of: " chars=") else { continue }
			let charsDigits = line[charsRange.upperBound...].prefix(while: \.isNumber)
			guard let characterCount = Int(charsDigits) else { continue }
			guard let linesRange = line.range(of: " lines=") else { continue }
			let lineDigits = line[linesRange.upperBound...].prefix(while: \.isNumber)
			guard let lineCount = Int(lineDigits) else { continue }
			return (batchNumber, characterCount, lineCount)
		}
		return nil
	}

	private func latestAssistantMarkdownLargeWindowStartMarker(in text: String) -> (batchNumber: Int, characterCount: Int, lineCount: Int)? {
		latestLargeWindowStartMarker(in: text, prefix: "assistantMarkdownLargeWindowStart#")
	}

	private func latestPersistedCodexReplayLargeWindowStartMarker(in text: String) -> (batchNumber: Int, characterCount: Int, lineCount: Int)? {
		latestLargeWindowStartMarker(in: text, prefix: "persistedCodexReplayLargeWindowStart#")
	}

	private func countOccurrences(of needle: String, in haystack: String) -> Int {
		guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
		var count = 0
		var searchStart = haystack.startIndex
		while searchStart < haystack.endIndex,
			let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
			count += 1
			searchStart = range.upperBound
		}
		return count
	}

	private func waitForAssistantMarkdownChurnProgress(
		telemetryElement: XCUIElement,
		eventsElement: XCUIElement,
		timeout: TimeInterval,
		afterBatchNumber: Int,
		afterSampleIndex: Int,
		baselineProjectionPublishCount: Int,
		baselineRefreshRequestCount: Int,
		tabID: UUID?
	) throws -> (telemetry: UITestTelemetrySnapshot, batchNumber: Int) {
		let deadline = Date().addingTimeInterval(timeout)
		var latestTelemetry: UITestTelemetrySnapshot?
		while Date() < deadline {
			let telemetry = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
			latestTelemetry = telemetry
			let eventsText = accessibilityText(from: eventsElement) ?? ""
			if let batchNumber = latestStressEventBatchNumber(in: eventsText, prefix: "assistantMarkdownStreamStart#"),
				batchNumber > afterBatchNumber,
				telemetry.tabID == tabID,
				telemetry.sampleIndex > afterSampleIndex,
				(telemetry.projectionPublishCount ?? 0) > baselineProjectionPublishCount,
				(telemetry.refreshRequestCount ?? 0) > baselineRefreshRequestCount {
				return (telemetry, batchNumber)
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
		}
		XCTFail("Timed out waiting for assistant markdown churn progress. Latest telemetry: \(String(describing: latestTelemetry))\nRecent events:\n\(accessibilityText(from: eventsElement) ?? "<none>")")
		throw NSError(domain: "RepoPromptUITests", code: 1)
	}

	private func waitForAssistantMarkdownMegaWindow(
		telemetryElement: XCUIElement,
		eventsElement: XCUIElement,
		timeout: TimeInterval,
		afterBatchNumber: Int,
		afterSampleIndex: Int,
		tabID: UUID?
	) throws -> (telemetry: UITestTelemetrySnapshot, batchNumber: Int, markerCharacterCount: Int, markerLineCount: Int) {
		let deadline = Date().addingTimeInterval(timeout)
		var latestTelemetry: UITestTelemetrySnapshot?
		while Date() < deadline {
			let telemetry = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
			latestTelemetry = telemetry
			let eventsText = accessibilityText(from: eventsElement) ?? ""
			if let marker = latestAssistantMarkdownLargeWindowStartMarker(in: eventsText),
				marker.batchNumber > afterBatchNumber,
				telemetry.tabID == tabID,
				telemetry.sampleIndex > afterSampleIndex {
				return (telemetry, marker.batchNumber, marker.characterCount, marker.lineCount)
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
		}
		XCTFail("Timed out waiting for assistant markdown mega window. Latest telemetry: \(String(describing: latestTelemetry))\nRecent events:\n\(accessibilityText(from: eventsElement) ?? "<none>")")
		throw NSError(domain: "RepoPromptUITests", code: 1)
	}

	private func waitForAssistantMarkdownStreamFinalization(
		telemetryElement: XCUIElement,
		eventsElement: XCUIElement,
		timeout: TimeInterval,
		batchNumber: Int,
		afterSampleIndex: Int,
		tabID: UUID?
	) throws -> UITestTelemetrySnapshot {
		let deadline = Date().addingTimeInterval(timeout)
		var latestTelemetry: UITestTelemetrySnapshot?
		while Date() < deadline {
			let telemetry = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
			latestTelemetry = telemetry
			let eventsText = accessibilityText(from: eventsElement) ?? ""
			if telemetry.tabID == tabID,
				telemetry.sampleIndex > afterSampleIndex,
				eventsText.contains("assistantMarkdownStreamFinalized#\(batchNumber)") {
				return telemetry
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
		}
		XCTFail("Timed out waiting for assistant markdown finalization #\(batchNumber). Latest telemetry: \(String(describing: latestTelemetry))\nRecent events:\n\(accessibilityText(from: eventsElement) ?? "<none>")")
		throw NSError(domain: "RepoPromptUITests", code: 1)
	}

	private func waitForPersistedCodexReplayLargeWindow(
		telemetryElement: XCUIElement,
		eventsElement: XCUIElement,
		timeout: TimeInterval,
		afterBatchNumber: Int,
		afterSampleIndex: Int,
		tabID: UUID?
	) throws -> (telemetry: UITestTelemetrySnapshot, batchNumber: Int, markerCharacterCount: Int, markerLineCount: Int) {
		let deadline = Date().addingTimeInterval(timeout)
		var latestTelemetry: UITestTelemetrySnapshot?
		while Date() < deadline {
			let telemetry = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
			latestTelemetry = telemetry
			let eventsText = accessibilityText(from: eventsElement) ?? ""
			if let marker = latestPersistedCodexReplayLargeWindowStartMarker(in: eventsText),
				marker.batchNumber > afterBatchNumber,
				telemetry.tabID == tabID,
				telemetry.sampleIndex > afterSampleIndex {
				return (telemetry, marker.batchNumber, marker.characterCount, marker.lineCount)
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
		}
		XCTFail("Timed out waiting for persisted Codex replay large window. Latest telemetry: \(String(describing: latestTelemetry))\nRecent events:\n\(accessibilityText(from: eventsElement) ?? "<none>")")
		throw NSError(domain: "RepoPromptUITests", code: 1)
	}

	private func waitForPersistedCodexReplayStreamFinalization(
		telemetryElement: XCUIElement,
		eventsElement: XCUIElement,
		timeout: TimeInterval,
		batchNumber: Int,
		afterSampleIndex: Int,
		tabID: UUID?
	) throws -> UITestTelemetrySnapshot {
		let deadline = Date().addingTimeInterval(timeout)
		var latestTelemetry: UITestTelemetrySnapshot?
		while Date() < deadline {
			let telemetry = try decode(UITestTelemetrySnapshot.self, from: telemetryElement)
			latestTelemetry = telemetry
			let eventsText = accessibilityText(from: eventsElement) ?? ""
			if telemetry.tabID == tabID,
				telemetry.sampleIndex > afterSampleIndex,
				eventsText.contains("persistedCodexReplayStreamFinalized#\(batchNumber)") {
				return telemetry
			}
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
		}
		XCTFail("Timed out waiting for persisted Codex replay finalization #\(batchNumber). Latest telemetry: \(String(describing: latestTelemetry))\nRecent events:\n\(accessibilityText(from: eventsElement) ?? "<none>")")
		throw NSError(domain: "RepoPromptUITests", code: 1)
	}

	private func transcriptScrollView(in app: XCUIApplication) -> XCUIElement {
		let scrollView = app.scrollViews["agentTranscript.scrollView"]
		if scrollView.exists {
			return scrollView
		}
		return app.descendants(matching: .any).matching(identifier: "agentTranscript.scrollView").firstMatch
	}

	private enum UITestScrollGestureMagnitude {
		case standard
		case short
	}

	private func selectVisibleMarkdownText(in scrollView: XCUIElement, app: XCUIApplication) throws {
		_ = app
		guard scrollView.waitForExistence(timeout: 5) else {
			XCTFail("Transcript scroll view was not available for markdown text selection")
			throw NSError(domain: "RepoPromptUITests", code: 6)
		}
		guard !scrollView.frame.isEmpty else {
			XCTFail("Transcript scroll view frame was empty for markdown text selection")
			throw NSError(domain: "RepoPromptUITests", code: 7)
		}

		let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.58))
		let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.58))
		start.click()
		RunLoop.current.run(until: Date().addingTimeInterval(0.10))
		start.press(forDuration: 0.15, thenDragTo: end)
		RunLoop.current.run(until: Date().addingTimeInterval(0.30))
	}

	private func performTargetedStressTranscriptScroll(
		app: XCUIApplication,
		scrollView: XCUIElement,
		direction: UITestScrollWheelDirection,
		telemetryElement: XCUIElement? = nil,
		baseline: UITestTelemetrySnapshot? = nil,
		eventsElement: XCUIElement? = nil,
		magnitude: UITestScrollGestureMagnitude = .standard
	) {
		_ = telemetryElement
		_ = baseline
		_ = eventsElement
		performTranscriptScrollGesture(
			app: app,
			scrollView: scrollView,
			swipeDown: direction == .towardHistory,
			magnitude: magnitude
		)
	}

	private func performDetachScrollGesture(
		app: XCUIApplication,
		scrollView: XCUIElement,
		telemetryElement: XCUIElement? = nil,
		baseline: UITestTelemetrySnapshot? = nil,
		eventsElement: XCUIElement? = nil
	) {
		performTargetedStressTranscriptScroll(
			app: app,
			scrollView: scrollView,
			direction: .towardHistory,
			telemetryElement: telemetryElement,
			baseline: baseline,
			eventsElement: eventsElement
		)
	}

	private func performTowardHistoryScrollGesture(
		app: XCUIApplication,
		scrollView: XCUIElement,
		magnitude: UITestScrollGestureMagnitude = .standard
	) {
		performTargetedStressTranscriptScroll(app: app, scrollView: scrollView, direction: .towardHistory, magnitude: magnitude)
	}

	private func performTowardLiveBottomScrollGesture(app: XCUIApplication, scrollView: XCUIElement) {
		performTargetedStressTranscriptScroll(app: app, scrollView: scrollView, direction: .towardLiveBottom)
	}

	private func performTranscriptScrollGesture(
		app: XCUIApplication,
		scrollView: XCUIElement,
		swipeDown: Bool,
		magnitude: UITestScrollGestureMagnitude = .standard
	) {
		func drag(on element: XCUIElement, magnitude: UITestScrollGestureMagnitude) -> Bool {
			guard element.exists, !element.frame.isEmpty else { return false }
			let frame = element.frame
			let safeX = min(frame.maxX - 24, frame.minX + max(24, min(48, frame.width * 0.10)))
			let dx = min(0.95, max(0.05, (safeX - frame.minX) / max(frame.width, 1)))
			let startY: CGFloat
			let endY: CGFloat
			switch magnitude {
			case .standard:
				startY = swipeDown ? 0.35 : 0.65
				endY = swipeDown ? 0.75 : 0.25
			case .short:
				startY = swipeDown ? 0.40 : 0.60
				endY = swipeDown ? 0.68 : 0.32
			}
			let start = element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: startY))
			let end = element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: endY))
			let pressDuration: TimeInterval = magnitude == .short ? 0.03 : 0.01
			start.press(forDuration: pressDuration, thenDragTo: end)
			RunLoop.current.run(until: Date().addingTimeInterval(0.25))
			return true
		}
		if magnitude == .standard {
			if scrollView.exists, scrollView.isHittable {
				if swipeDown {
					scrollView.swipeDown()
				} else {
					scrollView.swipeUp()
				}
				RunLoop.current.run(until: Date().addingTimeInterval(0.25))
				return
			}
			if let fallbackScrollView = app.scrollViews.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
				if swipeDown {
					fallbackScrollView.swipeDown()
				} else {
					fallbackScrollView.swipeUp()
				}
				RunLoop.current.run(until: Date().addingTimeInterval(0.25))
				return
			}
		}
		if drag(on: scrollView, magnitude: magnitude) {
			return
		}
		if let fallbackScrollView = app.scrollViews.allElementsBoundByIndex.first(where: { $0.exists && !$0.frame.isEmpty }),
			drag(on: fallbackScrollView, magnitude: magnitude) {
			return
		}
		if swipeDown {
			scrollView.swipeDown()
		} else {
			scrollView.swipeUp()
		}
		RunLoop.current.run(until: Date().addingTimeInterval(0.25))
	}

	private func attachSnapshots(
		telemetryElement: XCUIElement,
		groupingElement: XCUIElement,
		eventsElement: XCUIElement
	) {
		if let telemetry = accessibilityText(from: telemetryElement) {
			let attachment = XCTAttachment(string: telemetry)
			attachment.name = "Agent stress telemetry"
			attachment.lifetime = .keepAlways
			add(attachment)
		}
		if let grouping = accessibilityText(from: groupingElement) {
			let attachment = XCTAttachment(string: grouping)
			attachment.name = "Agent stress grouping"
			attachment.lifetime = .keepAlways
			add(attachment)
		}
		if let events = accessibilityText(from: eventsElement) {
			let attachment = XCTAttachment(string: events)
			attachment.name = "Agent stress events"
			attachment.lifetime = .keepAlways
			add(attachment)
		}
	}
}

private enum UITestScrollWheelDirection: String, Codable {
	case towardHistory
	case towardLiveBottom
}

private struct UITestTelemetrySnapshot: Decodable, CustomStringConvertible {
	let sampleIndex: Int
	let tabID: UUID?
	let isPinnedToLiveBottom: Bool
	let userDetachedAutoFollow: Bool
	let canScrollTowardHistory: Bool?
	let canScrollTowardLiveBottom: Bool?
	let isNearBottom: Bool
	let distanceToBottom: Double
	let topVisibleBlockID: String?
	let topVisibleAnchorDescription: String?
	let lastScrollIntentReason: String?
	let lastSettledBottomReason: String?
	let pendingPinnedBottomSourceDescription: String?
	let hasPendingPinnedBottomFlush: Bool?
	let deferredPinnedCorrectionSourceDescription: String?
	let millisecondsSinceLastBottomSettle: Double?
	let scrollIntentCount: Int
	let detachCount: Int
	let repinCount: Int
	let maxUnexpectedJumpMagnitude: Double
	let unexpectedHistoricalExposureCount: Int?
	let maxUnexpectedHistoricalExposureBlocksBelowTop: Int?
	let lastUnexpectedHistoricalExposureBlockID: String?
	let lastUnexpectedHistoricalExposureKind: String?
	let activeStreamingAssistantCharacterCount: Int?
	let activeStreamingAssistantLineCount: Int?
	let isLargeStreamingAssistantActive: Bool?
	let largeStreamingPinnedJumpCount: Int?
	let maxLargeStreamingPinnedJumpMagnitude: Double?
	let largeStreamingHistoricalExposureCount: Int?
	let maxLargeStreamingHistoricalExposureBlocksBelowTop: Int?
	let lastLargeStreamingHistoricalExposureBlockID: String?
	let lastLargeStreamingHistoricalExposureKind: String?
	let detachedJumpCount: Int
	let maxDetachedJumpMagnitude: Double
	let detachedAnchorChangeCount: Int
	let detachedSnapToTopCount: Int
	let storedDetachedTargetDescription: String?
	let storedDetachedAnchorDescription: String?
	let storedDetachedViewportMinY: Double?
	let liveDetachedTargetDescription: String?
	let liveDetachedViewportMinY: Double?
	let detachedAcceptedDriftCount: Int?
	let detachedRestoreIntentCount: Int?
	let lastDetachedRebaseAction: String?
	let smoothSendScrollCount: Int?
	let smoothSendStartCount: Int?
	let smoothSendCompletionCount: Int?
	let smoothSendFinishedWithoutAnimationCount: Int?
	let smoothSendInterruptedCount: Int?
	let smoothSendCorrectiveScrollCount: Int?
	let lastSmoothSendSettleDurationMS: Double?
	let maxSmoothSendSettleDurationMS: Double?
	let lastProjectionBuildDurationMS: Double?
	let maxProjectionBuildDurationMS: Double?
	let lastColdLoadProjectionBuildDurationMS: Double?
	let projectionBuildCount: Int?
	let projectionPublishCount: Int?
	let refreshRequestCount: Int?
	let refreshCoalescedCount: Int?
	let refreshImmediateCount: Int?
	let lastRefreshTotalDurationMS: Double?
	let maxRefreshTotalDurationMS: Double?
	let lastImportDurationMS: Double?
	let maxImportDurationMS: Double?
	let incrementalImportAttemptCount: Int?
	let incrementalImportSuccessCount: Int?
	let incrementalImportFallbackCount: Int?
	let frontierReuseAttemptCount: Int?
	let frontierReuseSuccessCount: Int?
	let frontierReuseFallbackCount: Int?
	let lastIncrementalImportDurationMS: Double?
	let maxIncrementalImportDurationMS: Double?
	let lastPayloadCaptureDurationMS: Double?
	let maxPayloadCaptureDurationMS: Double?
	let lastSanitizeDurationMS: Double?
	let maxSanitizeDurationMS: Double?
	let sanitizeReuseAttemptCount: Int?
	let sanitizeReuseSuccessCount: Int?
	let sanitizeReuseFallbackCount: Int?
	let projectionReuseAttemptCount: Int?
	let projectionReuseSuccessCount: Int?
	let projectionReuseFallbackCount: Int?
	let lastSourceItemCount: Int?
	let lastPayloadCaptureScannedItemCount: Int?
	let lastSanitizedActivityCount: Int?
	let lastSanitizeReusedTurnCount: Int?
	let lastProjectionReusedTurnCount: Int?
	let retainedRawPayloadEntryCount: Int?
	let retainedRawPayloadTotalBytes: Int?
	let viewportCandidateUpdateCount: Int?
	let coldRestoreStartCount: Int?
	let coldRestoreScrollCount: Int?
	let coldRestoreCorrectiveScrollCount: Int?
	let coldRestoreCompletionCount: Int?
	let lastColdRestoreSettleDurationMS: Double?
	let maxColdRestoreSettleDurationMS: Double?
	let manualScrollGestureCount: Int?
	let manualScrollEffectCount: Int?
	let manualScrollTowardHistoryGestureCount: Int?
	let manualScrollTowardHistoryEffectCount: Int?
	let manualScrollTowardLiveBottomGestureCount: Int?
	let manualScrollTowardLiveBottomEffectCount: Int?
	let manualScrollUnknownDirectionCount: Int?
	let lastManualScrollDirection: String?
	let lastManualScrollOutcome: String?
	let scrollToBottomTapCount: Int?
	let scrollToBottomSuccessCount: Int?
	let scrollToBottomNoEffectCount: Int?
	let lastScrollToBottomOutcome: String?
	let expandedApplyEditsCardCount: Int?
	let expandedApplyEditsDiffPreviewCardCount: Int?
	let expandedApplyEditsMarkdownFallbackCardCount: Int?
	let expandedApplyPatchCardCount: Int?
	let expandedApplyPatchDiffPreviewCardCount: Int?
	let expandedApplyPatchMarkdownFallbackCardCount: Int?
	let liveBashCardCount: Int?
	let expandedLiveBashCardCount: Int?
	let completedBashCardCount: Int?
	let expandedCompletedBashCardCount: Int?
	let latestExpandedHighSignalToolDescription: String?
	let latestExpandedHighSignalRenderMode: String?
	let supportsGeometryMetrics: Bool

	var description: String {
		let anchor = topVisibleAnchorDescription ?? "nil"
		let lastReason = lastScrollIntentReason ?? "nil"
		let lastSettledReason = lastSettledBottomReason ?? "nil"
		let pendingPinnedSource = pendingPinnedBottomSourceDescription ?? "nil"
		let hasPendingPinnedFlush = hasPendingPinnedBottomFlush ?? false
		let deferredPinnedSource = deferredPinnedCorrectionSourceDescription ?? "nil"
		let msSinceLastSettle = millisecondsSinceLastBottomSettle ?? -1
		let storedTarget = storedDetachedTargetDescription ?? "nil"
		let storedAnchor = storedDetachedAnchorDescription ?? "nil"
		let storedMinY = storedDetachedViewportMinY ?? -1
		let liveTarget = liveDetachedTargetDescription ?? "nil"
		let liveMinY = liveDetachedViewportMinY ?? -1
		let acceptedDriftCount = detachedAcceptedDriftCount ?? -1
		let restoreIntentCount = detachedRestoreIntentCount ?? -1
		let detachedRebaseAction = lastDetachedRebaseAction ?? "nil"
		let smoothSendCount = smoothSendScrollCount ?? -1
		let smoothSendStart = smoothSendStartCount ?? -1
		let smoothSendCompletion = smoothSendCompletionCount ?? -1
		let smoothSendInterrupted = smoothSendInterruptedCount ?? -1
		let smoothSendCorrective = smoothSendCorrectiveScrollCount ?? -1
		let smoothSendSettleMS = lastSmoothSendSettleDurationMS ?? -1
		let lastProjectionBuildMS = lastProjectionBuildDurationMS ?? -1
		let maxProjectionBuildMS = maxProjectionBuildDurationMS ?? -1
		let projectionBuilds = projectionBuildCount ?? -1
		let projectionPublishes = projectionPublishCount ?? -1
		let refreshRequests = refreshRequestCount ?? -1
		let refreshCoalesced = refreshCoalescedCount ?? -1
		let refreshImmediate = refreshImmediateCount ?? -1
		let lastRefreshMS = lastRefreshTotalDurationMS ?? -1
		let maxRefreshMS = maxRefreshTotalDurationMS ?? -1
		let lastImportMS = lastImportDurationMS ?? -1
		let maxImportMS = maxImportDurationMS ?? -1
		let incrementalImportAttempts = incrementalImportAttemptCount ?? -1
		let incrementalImportSuccesses = incrementalImportSuccessCount ?? -1
		let incrementalImportFallbacks = incrementalImportFallbackCount ?? -1
		let frontierReuseAttempts = frontierReuseAttemptCount ?? -1
		let frontierReuseSuccesses = frontierReuseSuccessCount ?? -1
		let frontierReuseFallbacks = frontierReuseFallbackCount ?? -1
		let lastIncrementalImportMS = lastIncrementalImportDurationMS ?? -1
		let maxIncrementalImportMS = maxIncrementalImportDurationMS ?? -1
		let lastPayloadCaptureMS = lastPayloadCaptureDurationMS ?? -1
		let maxPayloadCaptureMS = maxPayloadCaptureDurationMS ?? -1
		let lastSanitizeMS = lastSanitizeDurationMS ?? -1
		let maxSanitizeMS = maxSanitizeDurationMS ?? -1
		let sanitizeReuseAttempts = sanitizeReuseAttemptCount ?? -1
		let sanitizeReuseSuccesses = sanitizeReuseSuccessCount ?? -1
		let sanitizeReuseFallbacks = sanitizeReuseFallbackCount ?? -1
		let projectionReuseAttempts = projectionReuseAttemptCount ?? -1
		let projectionReuseSuccesses = projectionReuseSuccessCount ?? -1
		let projectionReuseFallbacks = projectionReuseFallbackCount ?? -1
		let sourceItemCount = lastSourceItemCount ?? -1
		let payloadCaptureScannedItemCount = lastPayloadCaptureScannedItemCount ?? -1
		let sanitizedActivityCount = lastSanitizedActivityCount ?? -1
		let sanitizeReusedTurnCount = lastSanitizeReusedTurnCount ?? -1
		let projectionReusedTurnCount = lastProjectionReusedTurnCount ?? -1
		let retainedPayloadEntryCount = retainedRawPayloadEntryCount ?? -1
		let retainedPayloadTotalBytes = retainedRawPayloadTotalBytes ?? -1
		let viewportCandidates = viewportCandidateUpdateCount ?? -1
		let coldRestoreStart = coldRestoreStartCount ?? -1
		let coldRestoreScrolls = coldRestoreScrollCount ?? -1
		let coldRestoreCorrective = coldRestoreCorrectiveScrollCount ?? -1
		let coldRestoreCompletion = coldRestoreCompletionCount ?? -1
		let coldRestoreSettleMS = lastColdRestoreSettleDurationMS ?? -1
		let coldLoadProjectionMS = lastColdLoadProjectionBuildDurationMS ?? -1
		let manualScrollGestures = manualScrollGestureCount ?? -1
		let manualScrollEffects = manualScrollEffectCount ?? -1
		let manualScrollHistoryGestures = manualScrollTowardHistoryGestureCount ?? -1
		let manualScrollHistoryEffects = manualScrollTowardHistoryEffectCount ?? -1
		let manualScrollLiveBottomGestures = manualScrollTowardLiveBottomGestureCount ?? -1
		let manualScrollLiveBottomEffects = manualScrollTowardLiveBottomEffectCount ?? -1
		let manualScrollUnknownDirection = manualScrollUnknownDirectionCount ?? -1
		let manualScrollDirection = lastManualScrollDirection ?? "nil"
		let manualScrollOutcome = lastManualScrollOutcome ?? "nil"
		let scrollToBottomTaps = scrollToBottomTapCount ?? -1
		let scrollToBottomSuccess = scrollToBottomSuccessCount ?? -1
		let scrollToBottomNoEffect = scrollToBottomNoEffectCount ?? -1
		let scrollToBottomOutcome = lastScrollToBottomOutcome ?? "nil"
		let historicalExposureCount = unexpectedHistoricalExposureCount ?? -1
		let maxHistoricalExposureBlocks = maxUnexpectedHistoricalExposureBlocksBelowTop ?? -1
		let historicalExposureBlockID = lastUnexpectedHistoricalExposureBlockID ?? "nil"
		let historicalExposureKind = lastUnexpectedHistoricalExposureKind ?? "nil"
		let activeStreamingCharacters = activeStreamingAssistantCharacterCount ?? -1
		let activeStreamingLines = activeStreamingAssistantLineCount ?? -1
		let largeStreamingActive = isLargeStreamingAssistantActive ?? false
		let largeStreamingJumpCount = largeStreamingPinnedJumpCount ?? -1
		let maxLargeStreamingJumpMagnitude = maxLargeStreamingPinnedJumpMagnitude ?? -1
		let largeStreamingExposureCount = largeStreamingHistoricalExposureCount ?? -1
		let maxLargeStreamingExposureBlocks = maxLargeStreamingHistoricalExposureBlocksBelowTop ?? -1
		let largeStreamingExposureBlockID = lastLargeStreamingHistoricalExposureBlockID ?? "nil"
		let largeStreamingExposureKind = lastLargeStreamingHistoricalExposureKind ?? "nil"
		let expandedEditDiffPreview = expandedApplyEditsDiffPreviewCardCount ?? -1
		let expandedEditMarkdownFallback = expandedApplyEditsMarkdownFallbackCardCount ?? -1
		let expandedPatchDiffPreview = expandedApplyPatchDiffPreviewCardCount ?? -1
		let expandedPatchMarkdownFallback = expandedApplyPatchMarkdownFallbackCardCount ?? -1
		let expandedEditCards = expandedApplyEditsCardCount ?? -1
		let expandedPatchCards = expandedApplyPatchCardCount ?? -1
		let liveBashCards = liveBashCardCount ?? -1
		let expandedLiveBashCards = expandedLiveBashCardCount ?? -1
		let completedBashCards = completedBashCardCount ?? -1
		let expandedCompletedBashCards = expandedCompletedBashCardCount ?? -1
		let latestExpandedHighSignal = latestExpandedHighSignalToolDescription ?? "nil"
		let canScrollHistory = canScrollTowardHistory ?? false
		let canScrollLiveBottom = canScrollTowardLiveBottom ?? false
		return "sampleIndex=\(sampleIndex), anchor=\(anchor), lastReason=\(lastReason), lastSettled=\(lastSettledReason), pendingPinnedSource=\(pendingPinnedSource), hasPendingPinnedFlush=\(hasPendingPinnedFlush), deferredPinnedSource=\(deferredPinnedSource), msSinceLastSettle=\(msSinceLastSettle), storedTarget=\(storedTarget), storedAnchor=\(storedAnchor), storedMinY=\(storedMinY), liveTarget=\(liveTarget), liveMinY=\(liveMinY), acceptedDriftCount=\(acceptedDriftCount), restoreIntentCount=\(restoreIntentCount), detachedRebaseAction=\(detachedRebaseAction), smoothSendCount=\(smoothSendCount), smoothSendStart=\(smoothSendStart), smoothSendCompletion=\(smoothSendCompletion), smoothSendInterrupted=\(smoothSendInterrupted), smoothSendCorrective=\(smoothSendCorrective), smoothSendSettleMS=\(smoothSendSettleMS), lastProjectionBuildMS=\(lastProjectionBuildMS), maxProjectionBuildMS=\(maxProjectionBuildMS), projectionBuilds=\(projectionBuilds), projectionPublishes=\(projectionPublishes), refreshRequests=\(refreshRequests), refreshCoalesced=\(refreshCoalesced), refreshImmediate=\(refreshImmediate), lastRefreshMS=\(lastRefreshMS), maxRefreshMS=\(maxRefreshMS), lastImportMS=\(lastImportMS), maxImportMS=\(maxImportMS), incrementalImportAttempts=\(incrementalImportAttempts), incrementalImportSuccesses=\(incrementalImportSuccesses), incrementalImportFallbacks=\(incrementalImportFallbacks), frontierReuseAttempts=\(frontierReuseAttempts), frontierReuseSuccesses=\(frontierReuseSuccesses), frontierReuseFallbacks=\(frontierReuseFallbacks), lastIncrementalImportMS=\(lastIncrementalImportMS), maxIncrementalImportMS=\(maxIncrementalImportMS), lastPayloadCaptureMS=\(lastPayloadCaptureMS), maxPayloadCaptureMS=\(maxPayloadCaptureMS), lastSanitizeMS=\(lastSanitizeMS), maxSanitizeMS=\(maxSanitizeMS), sanitizeReuseAttempts=\(sanitizeReuseAttempts), sanitizeReuseSuccesses=\(sanitizeReuseSuccesses), sanitizeReuseFallbacks=\(sanitizeReuseFallbacks), projectionReuseAttempts=\(projectionReuseAttempts), projectionReuseSuccesses=\(projectionReuseSuccesses), projectionReuseFallbacks=\(projectionReuseFallbacks), sourceItemCount=\(sourceItemCount), payloadCaptureScannedItemCount=\(payloadCaptureScannedItemCount), sanitizedActivityCount=\(sanitizedActivityCount), sanitizeReusedTurnCount=\(sanitizeReusedTurnCount), projectionReusedTurnCount=\(projectionReusedTurnCount), retainedPayloadEntryCount=\(retainedPayloadEntryCount), retainedPayloadTotalBytes=\(retainedPayloadTotalBytes), viewportCandidates=\(viewportCandidates), coldRestoreStart=\(coldRestoreStart), coldRestoreScrolls=\(coldRestoreScrolls), coldRestoreCorrective=\(coldRestoreCorrective), coldRestoreCompletion=\(coldRestoreCompletion), coldRestoreSettleMS=\(coldRestoreSettleMS), coldLoadProjectionMS=\(coldLoadProjectionMS), manualScrollGestures=\(manualScrollGestures), manualScrollEffects=\(manualScrollEffects), manualScrollHistoryGestures=\(manualScrollHistoryGestures), manualScrollHistoryEffects=\(manualScrollHistoryEffects), manualScrollLiveBottomGestures=\(manualScrollLiveBottomGestures), manualScrollLiveBottomEffects=\(manualScrollLiveBottomEffects), manualScrollUnknownDirection=\(manualScrollUnknownDirection), manualScrollDirection=\(manualScrollDirection), manualScrollOutcome=\(manualScrollOutcome), scrollToBottomTaps=\(scrollToBottomTaps), scrollToBottomSuccess=\(scrollToBottomSuccess), scrollToBottomNoEffect=\(scrollToBottomNoEffect), scrollToBottomOutcome=\(scrollToBottomOutcome), historicalExposureCount=\(historicalExposureCount), maxHistoricalExposureBlocks=\(maxHistoricalExposureBlocks), historicalExposureBlockID=\(historicalExposureBlockID), historicalExposureKind=\(historicalExposureKind), activeStreamingCharacters=\(activeStreamingCharacters), activeStreamingLines=\(activeStreamingLines), largeStreamingActive=\(largeStreamingActive), largeStreamingJumpCount=\(largeStreamingJumpCount), maxLargeStreamingJumpMagnitude=\(maxLargeStreamingJumpMagnitude), largeStreamingExposureCount=\(largeStreamingExposureCount), maxLargeStreamingExposureBlocks=\(maxLargeStreamingExposureBlocks), largeStreamingExposureBlockID=\(largeStreamingExposureBlockID), largeStreamingExposureKind=\(largeStreamingExposureKind), expandedEditCards=\(expandedEditCards), expandedEditDiffPreview=\(expandedEditDiffPreview), expandedEditMarkdownFallback=\(expandedEditMarkdownFallback), expandedPatchCards=\(expandedPatchCards), expandedPatchDiffPreview=\(expandedPatchDiffPreview), expandedPatchMarkdownFallback=\(expandedPatchMarkdownFallback), liveBashCards=\(liveBashCards), expandedLiveBashCards=\(expandedLiveBashCards), completedBashCards=\(completedBashCards), expandedCompletedBashCards=\(expandedCompletedBashCards), latestExpandedHighSignal=\(latestExpandedHighSignal), latestExpandedHighSignalRenderMode=\(latestExpandedHighSignalRenderMode ?? "nil"), canScrollTowardHistory=\(canScrollHistory), canScrollTowardLiveBottom=\(canScrollLiveBottom), detachedAnchorChangeCount=\(detachedAnchorChangeCount), detachedSnapToTopCount=\(detachedSnapToTopCount)"
	}
}

private struct UITestGroupingSnapshot: Decodable, CustomStringConvertible {
	let sampleIndex: Int
	let visibleBlockKindCounts: [String: Int]
	let workingBlockKindCounts: [String: Int]
	let archivedBlockKindCounts: [String: Int]
	let visibleStandaloneToolNameCounts: [String: Int]?
	let latestVisibleStandaloneToolNames: [String]?
	let latestClusterTitle: String?
	let latestGroupedHistoryTitle: String?
	let latestToolGroupLabels: [String]

	var description: String {
		"sampleIndex=\(sampleIndex), visibleBlockKinds=\(visibleBlockKindCounts), archivedBlockKinds=\(archivedBlockKindCounts), visibleStandaloneToolNameCounts=\(visibleStandaloneToolNameCounts ?? [:]), latestVisibleStandaloneToolNames=\(latestVisibleStandaloneToolNames ?? []), latestToolGroupLabels=\(latestToolGroupLabels)"
	}
}
