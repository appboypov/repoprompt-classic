import XCTest
@testable import RepoPrompt

#if DEBUG
@MainActor
final class AgentModePerfDiagnosticsSnapshotTests: XCTestCase {
	override func setUp() {
		super.setUp()
		// Force-enable diagnostics via the process override so the helper records
		// snapshots regardless of the user's UserDefaults / environment state.
		AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
		AgentModePerfDiagnostics.clearRecentMetrics()
	}

	override func tearDown() {
		AgentModePerfDiagnostics.clearRecentMetrics()
		AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(nil)
		super.tearDown()
	}

	func testDurationEventRecordsCounterAndDurationField() {
		let startMS = AgentModePerfDiagnostics.timestampMS() - 12.0

		AgentModePerfDiagnostics.durationEvent(
			"unit.duration",
			startMS: startMS,
			fields: ["source": "unitTest"]
		)

		let payload = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 10)
		let counters = payload["counters"] as? [String: Int] ?? [:]
		let lines = payload["lines"] as? [String] ?? []
		XCTAssertEqual(counters["event.unit.duration"], 1)
		XCTAssertTrue(lines.contains { line in
			line.contains("unit.duration")
				&& line.contains("duration=")
				&& line.contains("source=unitTest")
		})
	}

	func testMetricSummaryReportsMedianP95AndCountersWithinMarkWindow() throws {
		AgentModePerfDiagnostics.event("agent.metrics.mark", fields: ["mark": "sample.start"])
		AgentModePerfDiagnostics.event("unit.duration", fields: ["duration": "10.0ms", "source": "first"])
		AgentModePerfDiagnostics.event("unit.duration", fields: ["duration": "20.0ms", "source": "second"])
		AgentModePerfDiagnostics.event("unit.duration", fields: ["duration": "30.0ms", "source": "third"])
		AgentModePerfDiagnostics.event("unit.countOnly", fields: ["source": "ignoredByFilter"])
		AgentModePerfDiagnostics.event("agent.metrics.mark", fields: ["mark": "sample.end"])

		let payload = AgentModePerfDiagnostics.debugMetricSummarySnapshot(
			lineLimit: 10,
			startMark: "sample.start",
			endMark: "sample.end",
			eventNames: ["unit.duration"]
		)

		XCTAssertEqual(payload["ok"] as? Bool, true)
		let events = try XCTUnwrap(payload["events"] as? [String: [String: Any]])
		let summary = try XCTUnwrap(events["unit.duration"])
		XCTAssertEqual(summary["count"] as? Int, 3)
		XCTAssertEqual(summary["duration_count"] as? Int, 3)
		XCTAssertEqual(summary["median_ms"] as? Double, 20.0)
		XCTAssertEqual(summary["p95_ms"] as? Double, 30.0)
		XCTAssertEqual(summary["max_ms"] as? Double, 30.0)
		XCTAssertEqual(summary["total_ms"] as? Double, 60.0)
		let counters = try XCTUnwrap(payload["counters"] as? [String: Int])
		XCTAssertEqual(counters["event.unit.duration"], 3)
	}

	func testMetricSummaryUsesLastStartMarkAndFirstFollowingEndMark() throws {
		AgentModePerfDiagnostics.event("agent.metrics.mark", fields: ["mark": "sample.start"])
		AgentModePerfDiagnostics.event("unit.duration", fields: ["duration": "100.0ms"])
		AgentModePerfDiagnostics.event("agent.metrics.mark", fields: ["mark": "sample.start"])
		AgentModePerfDiagnostics.event("unit.duration", fields: ["duration": "5.0ms"])
		AgentModePerfDiagnostics.event("agent.metrics.mark", fields: ["mark": "sample.end"])
		AgentModePerfDiagnostics.event("unit.duration", fields: ["duration": "200.0ms"])
		AgentModePerfDiagnostics.event("agent.metrics.mark", fields: ["mark": "sample.end"])

		let payload = AgentModePerfDiagnostics.debugMetricSummarySnapshot(
			lineLimit: 10,
			startMark: "sample.start",
			endMark: "sample.end",
			eventNames: ["unit.duration"]
		)

		let events = try XCTUnwrap(payload["events"] as? [String: [String: Any]])
		let summary = try XCTUnwrap(events["unit.duration"])
		XCTAssertEqual(summary["count"] as? Int, 1)
		XCTAssertEqual(summary["median_ms"] as? Double, 5.0)
	}

	func testMetricSummaryReportsMissingMarkWithoutFailingRawSnapshot() {
		AgentModePerfDiagnostics.event("unit.duration", fields: ["duration": "1.0ms"])

		let payload = AgentModePerfDiagnostics.debugMetricSummarySnapshot(
			lineLimit: 10,
			startMark: "missing.start",
			endMark: "missing.end",
			eventNames: ["unit.duration"]
		)

		XCTAssertEqual(payload["ok"] as? Bool, false)
		XCTAssertEqual(payload["code"] as? String, "missing_mark")
		XCTAssertEqual(payload["missing_mark"] as? String, "missing.start")
		let events = payload["events"] as? [String: Any] ?? [:]
		XCTAssertTrue(events.isEmpty)
	}

	func testRecordPerfSessionSnapshotsForAllTabsRecordsOneSnapshotPerLiveSession() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			PerfDiagnosticsFakeCodexController()
		}
		let tabA = UUID()
		let tabB = UUID()
		_ = await vm.ensureSessionReady(tabID: tabA)
		_ = await vm.ensureSessionReady(tabID: tabB)

		let recorded = vm.test_recordPerfSessionSnapshotsForAllTabs(
			source: "unitTest",
			tabIDs: nil
		)

		XCTAssertEqual(Set(recorded), Set([tabA, tabB]))

		let payload = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 50)
		let snapshots = payload["latest_session_snapshots"] as? [String: [String: Any]] ?? [:]
		XCTAssertEqual(Set(snapshots.keys), Set([tabA.uuidString, tabB.uuidString]))
		for tabID in [tabA, tabB] {
			let snapshot = try? XCTUnwrap(snapshots[tabID.uuidString])
			XCTAssertEqual(snapshot?["source"] as? String, "unitTest")
		}
	}

	func testRecordPerfSessionSnapshotsForAllTabsHonoursTabIDFilter() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			PerfDiagnosticsFakeCodexController()
		}
		let tabA = UUID()
		let tabB = UUID()
		_ = await vm.ensureSessionReady(tabID: tabA)
		_ = await vm.ensureSessionReady(tabID: tabB)

		let recorded = vm.test_recordPerfSessionSnapshotsForAllTabs(
			source: "unitTest",
			tabIDs: [tabA]
		)

		XCTAssertEqual(recorded, [tabA])
		let payload = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 50)
		let snapshots = payload["latest_session_snapshots"] as? [String: [String: Any]] ?? [:]
		XCTAssertEqual(Set(snapshots.keys), [tabA.uuidString])
	}

	func testRecordPerfSessionSnapshotsForAllTabsReturnsEmptyWhenDisabled() async {
		AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(false)
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			PerfDiagnosticsFakeCodexController()
		}
		let tabID = UUID()
		_ = await vm.ensureSessionReady(tabID: tabID)

		let recorded = vm.test_recordPerfSessionSnapshotsForAllTabs(
			source: "unitTest",
			tabIDs: nil
		)

		XCTAssertTrue(recorded.isEmpty)
		let payload = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 50)
		let snapshots = payload["latest_session_snapshots"] as? [String: [String: Any]] ?? [:]
		XCTAssertTrue(snapshots.isEmpty)
	}

	func testRecordPerfSessionSnapshotsForAllTabsDoesNotIncrementUpdateBindingsCallCount() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			PerfDiagnosticsFakeCodexController()
		}
		let tabID = UUID()
		_ = await vm.ensureSessionReady(tabID: tabID)
		vm.test_resetUpdateBindingsCallCount()

		_ = vm.test_recordPerfSessionSnapshotsForAllTabs(source: "unitTest", tabIDs: nil)

		XCTAssertEqual(vm.test_updateBindingsCallCount, 0)
	}

	func testCombinedTranscriptScopedRefreshPublishesTranscriptStoreBoundedWithoutFullBindings() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			PerfDiagnosticsFakeCodexController()
		}
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems([.user("Initial", sequenceIndex: 0)])
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)
		vm.syncTranscriptUIState()
		vm.test_resetUpdateBindingsCallCount()
		AgentModePerfDiagnostics.clearRecentMetrics()

		session.appendItem(.assistant("Updated", sequenceIndex: session.nextSequenceIndex))
		let liveState = AgentModeViewModel.BashLiveExecutionState(
			executionKey: "live-bash",
			transcriptItemID: session.items[0].id,
			toolName: "bash",
			invocationID: UUID(),
			fallbackSignature: "bash:live-bash",
			processID: "123",
			command: "echo hi",
			statusWord: "running",
			exitCode: nil,
			output: "hi",
			isSummaryOnly: false,
			lastSignalAt: Date()
		)
		session.bashLiveExecutionByKey[liveState.executionKey] = liveState
		session.bashLiveExecutionKeyByTranscriptItemID[liveState.transcriptItemID] = liveState.executionKey

		vm.requestUIRefresh(tabID: tabID, scope: .transcriptPresentation)
		vm.requestUIRefresh(tabID: tabID, urgent: true, scope: .transcriptRuntime)

		let payload = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 50)
		let counters = payload["counters"] as? [String: Int] ?? [:]
		XCTAssertEqual(vm.test_updateBindingsCallCount, 0)
		XCTAssertGreaterThanOrEqual(counters["store.transcript.published"] ?? 0, 1)
		XCTAssertLessThanOrEqual(counters["store.transcript.published"] ?? 0, 2)
		XCTAssertEqual(counters["ui.refresh.flush.scope.transcriptPresentation"], 1)
		XCTAssertEqual(counters["ui.refresh.flush.scope.transcriptRuntime"], 1)
		XCTAssertEqual(vm.activeBashLiveExecutionByItemID[liveState.transcriptItemID], liveState)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "Updated" })
	}

	func testInactiveScopedRuntimeRefreshDoesNotEnqueuePendingRefresh() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			PerfDiagnosticsFakeCodexController()
		}
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		vm.test_setCurrentTabIDOverride(activeTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		_ = await vm.ensureSessionReady(tabID: activeTabID)
		_ = await vm.ensureSessionReady(tabID: inactiveTabID)
		AgentModePerfDiagnostics.clearRecentMetrics()

		vm.requestUIRefresh(tabID: inactiveTabID, scope: .transcriptPresentation)
		vm.requestUIRefresh(tabID: inactiveTabID, scope: .transcriptRuntime)
		vm.requestUIRefresh(tabID: inactiveTabID, scope: .runtimeMetrics)

		XCTAssertEqual(vm.test_pendingUIRefreshScopeCount, 0)
		XCTAssertFalse(vm.test_hasPendingUIRefreshTask)
		let skippedPayload = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 20)
		let skippedCounters = skippedPayload["counters"] as? [String: Int] ?? [:]
		XCTAssertEqual(skippedCounters["ui.refresh.request.skippedInactiveScoped"], 3)
		XCTAssertEqual(skippedCounters["ui.refresh.request.skippedInactiveScoped.scope.transcriptPresentation"], 1)
		XCTAssertEqual(skippedCounters["ui.refresh.request.skippedInactiveScoped.scope.transcriptRuntime"], 1)
		XCTAssertEqual(skippedCounters["ui.refresh.request.skippedInactiveScoped.scope.runtimeMetrics"], 1)

		vm.requestUIRefresh(tabID: activeTabID, scope: .transcriptPresentation)

		XCTAssertEqual(vm.test_pendingUIRefreshScopeCount, 1)
		XCTAssertEqual(vm.test_pendingUIRefreshScopes(for: activeTabID), [.transcriptPresentation])
		XCTAssertTrue(vm.test_hasPendingUIRefreshTask)
		vm.removePendingUIRefresh(for: activeTabID)

		vm.requestUIRefresh(tabID: activeTabID, scope: .transcriptRuntime)

		XCTAssertEqual(vm.test_pendingUIRefreshScopeCount, 1)
		XCTAssertEqual(vm.test_pendingUIRefreshScopes(for: activeTabID), [.transcriptRuntime])
		XCTAssertTrue(vm.test_hasPendingUIRefreshTask)
		vm.removePendingUIRefresh(for: activeTabID)

		vm.requestUIRefresh(tabID: activeTabID, scope: .runtimeMetrics)

		XCTAssertEqual(vm.test_pendingUIRefreshScopeCount, 1)
		XCTAssertEqual(vm.test_pendingUIRefreshScopes(for: activeTabID), [.runtimeMetrics])
		XCTAssertTrue(vm.test_hasPendingUIRefreshTask)
		vm.requestUIRefresh(tabID: activeTabID, scope: .transcriptPresentation)
		XCTAssertEqual(vm.test_pendingUIRefreshScopes(for: activeTabID), [.runtimeMetrics, .transcriptPresentation])
		vm.requestUIRefresh(tabID: activeTabID)
		XCTAssertEqual(vm.test_pendingUIRefreshScopes(for: activeTabID), [.full])
		vm.removePendingUIRefresh(for: activeTabID)
	}
}

private final class PerfDiagnosticsFakeCodexController: CodexSessionControlling {
	var hasActiveThread: Bool = false
	var events: AsyncStream<CodexNativeSessionController.Event> { AsyncStream { continuation in continuation.finish() } }

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing _: CodexNativeSessionController.SessionRef?,
		baseInstructions _: String
	) async throws -> CodexNativeSessionController.SessionRef {
		hasActiveThread = true
		return CodexNativeSessionController.SessionRef(
			conversationID: "test-thread",
			rolloutPath: nil,
			model: "gpt-5.2-codex",
			reasoningEffort: "medium"
		)
	}

	func readThreadSnapshot(
		includeTurns _: Bool,
		timeout _: TimeInterval?
	) async throws -> CodexNativeSessionController.ThreadSnapshot {
		CodexNativeSessionController.ThreadSnapshot(
			conversationID: "test-thread",
			rolloutPath: nil,
			model: "gpt-5.2-codex",
			reasoningEffort: "medium",
			runtimeStatus: .idle,
			currentTurnID: nil,
			activeTurnIDs: [],
			latestTurnStatus: nil
		)
	}

	func sendUserMessage(_: String) async throws {}
	func sendUserTurn(text _: String, images _: [AgentImageAttachment]) async throws {}
	func sendUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?) async throws {}
	func compactThread() async throws {}
	func cancelCurrentTurn() async {}
	func shutdown() async { hasActiveThread = false }
	func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
#endif
