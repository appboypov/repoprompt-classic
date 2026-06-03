#if DEBUG
import Foundation
import XCTest
@testable import RepoPrompt

@MainActor
final class AgentSidebarDeleteResponsivenessBenchmarkTests: XCTestCase {
	private let scenarioName = "sidebar_delete_inactive_agent_session_20_open_hot_index"
	private let warmupCount = 1
	private let measuredSampleCount = 9
	private let discardFastestCount = 1
	private let discardSlowestCount = 1
	private let openSessionCount = 20
	private let backgroundPersistedCount = 50
	private let deleteEventNames: [String] = [
		"sidebar.delete.requested",
		"sidebar.delete.visibleRemoved",
		"sidebar.delete.requestToVisible",
		"sidebar.delete.agentCleanupComplete",
		"sidebar.delete.requestToAgentCleanup",
		"sidebar.delete.fullCleanupComplete",
		"sidebar.delete.requestToFullCleanup",
		"sidebar.delete.duplicateVisibleRemoved",
		"sidebar.delete.orphanVisibleRemoved",
		"sidebar.delete.orphanFullCleanupComplete"
	]

	func testSidebarDeleteVisibleRemovalLatencyInactiveAgentSession() async throws {
		let previousDiagnosticsOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
		AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
		defer {
			AgentModePerfDiagnostics.clearRecentMetrics()
			AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousDiagnosticsOverride)
		}

		var warmupSamples: [[String: Any]] = []
		var measuredRows: [[String: Any]] = []
		var requestToVisibleMS: [Double] = []
		var requestToAgentCleanupMS: [Double] = []
		var requestToFullCleanupMS: [Double] = []
		var perSampleMetrics: [[String: Any]] = []

		for sampleIndex in 0..<(warmupCount + measuredSampleCount) {
			let result = try await runDeleteSample(sampleIndex: sampleIndex)
			let row = result.payloadRow
			if sampleIndex < warmupCount {
				warmupSamples.append(row)
			} else {
				measuredRows.append(row)
				requestToVisibleMS.append(result.requestToVisibleMS)
				requestToAgentCleanupMS.append(result.requestToAgentCleanupMS)
				requestToFullCleanupMS.append(result.requestToFullCleanupMS)
				perSampleMetrics.append(result.metricSummary)
			}
		}

		let trimmedVisible = trimmed(requestToVisibleMS, dropFastest: discardFastestCount, dropSlowest: discardSlowestCount)
		let trimmedAgentCleanup = trimmed(requestToAgentCleanupMS, dropFastest: discardFastestCount, dropSlowest: discardSlowestCount)
		let trimmedFullCleanup = trimmed(requestToFullCleanupMS, dropFastest: discardFastestCount, dropSlowest: discardSlowestCount)
		let payload: [String: Any] = [
			"scenario": scenarioName,
			"warmup_count": warmupCount,
			"measured_sample_count": measuredSampleCount,
			"discard_rule": "discard fastest and slowest measured request_to_visible_ms sample; secondary trimmed arrays use same count rule independently",
			"fixture": [
				"open_inactive_agent_sessions": openSessionCount,
				"background_persisted_sessions": backgroundPersistedCount,
				"target_session_state": "inactive_completed_non_current"
			],
			"warmup_samples": warmupSamples,
			"measured_samples": measuredRows,
			"request_to_visible_ms": requestToVisibleMS.map(roundMilliseconds),
			"trimmed_request_to_visible_ms": trimmedVisible.map(roundMilliseconds),
			"trimmed_request_to_visible_median_ms": roundMilliseconds(median(trimmedVisible)),
			"trimmed_request_to_visible_p95_ms": roundMilliseconds(nearestRankPercentile(trimmedVisible, percentile: 0.95)),
			"request_to_agent_cleanup_ms": requestToAgentCleanupMS.map(roundMilliseconds),
			"trimmed_request_to_agent_cleanup_median_ms": roundMilliseconds(median(trimmedAgentCleanup)),
			"trimmed_request_to_agent_cleanup_p95_ms": roundMilliseconds(nearestRankPercentile(trimmedAgentCleanup, percentile: 0.95)),
			"request_to_full_cleanup_ms": requestToFullCleanupMS.map(roundMilliseconds),
			"trimmed_request_to_full_cleanup_median_ms": roundMilliseconds(median(trimmedFullCleanup)),
			"trimmed_request_to_full_cleanup_p95_ms": roundMilliseconds(nearestRankPercentile(trimmedFullCleanup, percentile: 0.95)),
			"phase_metrics": [
				"event_names": deleteEventNames,
				"source": "AgentModePerfDiagnostics.debugMetricSummarySnapshot after closeComposeTab",
				"measured_samples": perSampleMetrics
			]
		]
		let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
		let json = String(data: data, encoding: .utf8) ?? "{}"
		let prefixedJSON = "AGENT_SIDEBAR_DELETE_RESPONSIVENESS_BENCHMARK_JSON=\(json)"
		print(prefixedJSON)
		try? prefixedJSON.write(
			to: URL(fileURLWithPath: "/tmp/repoprompt-agent-sidebar-delete-responsiveness-benchmark.json"),
			atomically: true,
			encoding: .utf8
		)
		XCTContext.runActivity(named: "Agent sidebar delete responsiveness benchmark JSON") { activity in
			let attachment = XCTAttachment(string: "AGENT_SIDEBAR_DELETE_RESPONSIVENESS_BENCHMARK_JSON=\(json)")
			attachment.lifetime = .keepAlways
			activity.add(attachment)
		}
	}

	private struct SampleResult {
		let sampleIndex: Int
		let targetTabID: UUID
		let targetSessionID: UUID
		let requestToVisibleMS: Double
		let requestToAgentCleanupMS: Double
		let requestToFullCleanupMS: Double
		let tabAbsent: Bool
		let rowOmitted: Bool
		let liveSessionRemoved: Bool
		let sessionIndexRemoved: Bool
		let fileDeleted: Bool
		let metricSummary: [String: Any]

		var payloadRow: [String: Any] {
			[
				"sample_index": sampleIndex,
				"target_tab_id": targetTabID.uuidString,
				"target_session_id": targetSessionID.uuidString,
				"request_to_visible_ms": AgentSidebarDeleteResponsivenessBenchmarkTests.roundMilliseconds(requestToVisibleMS),
				"request_to_agent_cleanup_ms": AgentSidebarDeleteResponsivenessBenchmarkTests.roundMilliseconds(requestToAgentCleanupMS),
				"request_to_full_cleanup_ms": AgentSidebarDeleteResponsivenessBenchmarkTests.roundMilliseconds(requestToFullCleanupMS),
				"tab_absent": tabAbsent,
				"row_omitted": rowOmitted,
				"live_session_removed": liveSessionRemoved,
				"session_index_removed": sessionIndexRemoved,
				"file_deleted": fileDeleted
			]
		}
	}

	private struct Fixture {
		let workspace: WorkspaceModel
		let targetTabID: UUID
		let targetSessionID: UUID
	}

	private func runDeleteSample(sampleIndex: Int) async throws -> SampleResult {
		let tempRoot = makeTempDirectory(sampleIndex: sampleIndex)
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)

		do {
			let result = try await runDeleteSampleBody(
				sampleIndex: sampleIndex,
				windowState: windowState
			)
			await windowState.tearDown()
			try? FileManager.default.removeItem(at: tempRoot)
			return result
		} catch {
			await windowState.tearDown()
			try? FileManager.default.removeItem(at: tempRoot)
			throw error
		}
	}

	private func runDeleteSampleBody(sampleIndex: Int, windowState: WindowState) async throws -> SampleResult {
		let fixture = try await seedFixture(windowState: windowState, sampleIndex: sampleIndex)
		let agentModeVM = windowState.agentModeViewModel
		let promptManager = windowState.promptManager

		AgentModePerfDiagnostics.clearRecentMetrics()
		agentModeVM.debugBeginSidebarDeleteRequest(
			tabID: fixture.targetTabID,
			source: "AgentSidebarDeleteResponsivenessBenchmarkTests",
			reason: "benchmark_baseline"
		)
		await promptManager.closeComposeTab(fixture.targetTabID)

		let metricSummary = metricSummaryPayload(sampleIndex: sampleIndex)
		let requestToVisibleMS = try durationMetric("sidebar.delete.requestToVisible", in: metricSummary)
		let requestToAgentCleanupMS = try durationMetric("sidebar.delete.requestToAgentCleanup", in: metricSummary)
		let requestToFullCleanupMS = try durationMetric("sidebar.delete.requestToFullCleanup", in: metricSummary)
		let currentTabs = promptManager.currentComposeTabs
		let tabAbsent = !currentTabs.contains(where: { $0.id == fixture.targetTabID })
		let rowOmitted = !agentModeVM.sidebarSessions(for: currentTabs).contains(where: { $0.tabID == fixture.targetTabID })
		let liveSessionRemoved = agentModeVM.sessions[fixture.targetTabID] == nil
		let sessionIndexRemoved = agentModeVM.sessionIndex[fixture.targetSessionID] == nil
		let fileDeleted = try await AgentSessionDataService.shared.loadAgentSession(
			id: fixture.targetSessionID,
			for: fixture.workspace
		) == nil

		XCTAssertTrue(tabAbsent)
		XCTAssertTrue(rowOmitted)
		XCTAssertTrue(liveSessionRemoved)
		XCTAssertTrue(sessionIndexRemoved)
		XCTAssertTrue(fileDeleted)

		return SampleResult(
			sampleIndex: sampleIndex,
			targetTabID: fixture.targetTabID,
			targetSessionID: fixture.targetSessionID,
			requestToVisibleMS: requestToVisibleMS,
			requestToAgentCleanupMS: requestToAgentCleanupMS,
			requestToFullCleanupMS: requestToFullCleanupMS,
			tabAbsent: tabAbsent,
			rowOmitted: rowOmitted,
			liveSessionRemoved: liveSessionRemoved,
			sessionIndexRemoved: sessionIndexRemoved,
			fileDeleted: fileDeleted,
			metricSummary: metricSummary
		)
	}

	private func seedFixture(windowState: WindowState, sampleIndex: Int) async throws -> Fixture {
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let tabIDs = try appendOpenTabs(windowState: windowState, count: openSessionCount)
		var updatedWorkspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		var targetSessionID: UUID?
		let targetOffset = sampleIndex % tabIDs.count

		for (offset, tabID) in tabIDs.enumerated() {
			windowState.agentModeViewModel.ensureSession(for: tabID)
			let session = try XCTUnwrap(windowState.agentModeViewModel.sessions[tabID])
			let sessionID = try XCTUnwrap(session.activeAgentSessionID)
			session.runState = .completed
			session.mcpFollowUpRunPending = false
			session.pendingSupersedingTurnCompletions = 0
			if offset == targetOffset {
				targetSessionID = sessionID
			}
			if let tabIndex = updatedWorkspace.composeTabs.firstIndex(where: { $0.id == tabID }) {
				updatedWorkspace.composeTabs[tabIndex].activeAgentSessionID = sessionID
			}
			windowState.agentModeViewModel.upsertSessionIndex(
				sessionID: sessionID,
				tabID: tabID,
				name: "Delete Responsiveness Open \(offset)",
				lastUserMessageAt: Date(timeIntervalSince1970: Double(sampleIndex * 1_000 + offset)),
				savedAt: Date(),
				lastRunStateRaw: AgentSessionRunState.completed.rawValue,
				itemCount: 0,
				agentKindRaw: session.selectedAgent.rawValue,
				agentModelRaw: session.selectedModelRaw,
				agentReasoningEffortRaw: session.selectedReasoningEffortRaw,
				autoEditEnabled: session.autoEditEnabled,
				isMCPOriginated: false
			)
			_ = try await AgentSessionDataService.shared.saveAgentSession(
				makePersistedSession(
					id: sessionID,
					workspaceID: workspace.id,
					composeTabID: tabID,
					name: "Delete Responsiveness Open \(offset)",
					lastRunState: .completed,
					savedAtOffset: sampleIndex * 1_000 + offset
				),
				for: workspace,
				preparation: .alreadyCanonicalTranscript
			)
		}

		try await seedBackgroundPersistedSessions(workspace: workspace, count: backgroundPersistedCount, sampleIndex: sampleIndex)
		windowState.workspaceManager.workspaces = [updatedWorkspace]
		windowState.workspaceManager.activeWorkspace = updatedWorkspace
		windowState.promptManager.loadComposeTabsFromWorkspace(updatedWorkspace)
		let persistedRecords = try await AgentSessionDataService.shared.listAgentSessionsMeta(for: workspace, limit: nil)
		XCTAssertEqual(persistedRecords.count, openSessionCount + backgroundPersistedCount)
		return Fixture(
			workspace: workspace,
			targetTabID: tabIDs[targetOffset],
			targetSessionID: try XCTUnwrap(targetSessionID)
		)
	}

	private func appendOpenTabs(windowState: WindowState, count: Int) throws -> [UUID] {
		var workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let tabIDs = (0..<count).map { _ in UUID() }
		for (offset, tabID) in tabIDs.enumerated() {
			workspace.composeTabs.append(
				ComposeTabState(
					id: tabID,
					name: "Delete Responsiveness Open \(offset)",
					lastModified: Date()
				)
			)
		}
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
		return tabIDs
	}

	private func seedBackgroundPersistedSessions(
		workspace: WorkspaceModel,
		count: Int,
		sampleIndex: Int
	) async throws {
		for offset in 0..<count {
			_ = try await AgentSessionDataService.shared.saveAgentSession(
				makePersistedSession(
					id: UUID(),
					workspaceID: workspace.id,
					composeTabID: UUID(),
					name: "Delete Responsiveness Background \(offset)",
					lastRunState: .completed,
					savedAtOffset: sampleIndex * 3_000 + offset
				),
				for: workspace,
				preparation: .alreadyCanonicalTranscript
			)
		}
	}

	private func makePersistedSession(
		id: UUID,
		workspaceID: UUID,
		composeTabID: UUID?,
		name: String,
		lastRunState: AgentSessionRunState,
		savedAtOffset: Int
	) -> AgentSession {
		let savedAt = Date(timeIntervalSince1970: Double(1_700_000_000 + savedAtOffset))
		return AgentSession(
			id: id,
			workspaceID: workspaceID,
			composeTabID: composeTabID,
			name: name,
			savedAt: savedAt,
			transcript: .empty,
			itemCount: 0,
			transcriptProjectionCounts: .init(canonicalVisibleRowCount: 0, defaultPresentedRowCount: 0),
			lastUserMessageAt: savedAt,
			lastRunState: lastRunState.rawValue,
			isMCPOriginated: false
		)
	}

	private func makeWindowState(root: URL, sourceTabID: UUID) -> WindowState {
		let windowState = WindowState()
		let workspace = WorkspaceModel(
			name: "Sidebar Delete Responsiveness Benchmark",
			repoPaths: [root.path],
			customStoragePath: root,
			composeTabs: [
				ComposeTabState(
					id: sourceTabID,
					name: "Source",
					lastModified: Date(),
					activeAgentSessionID: nil
				)
			],
			activeComposeTabID: sourceTabID
		)
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
		return windowState
	}

	private func makeTempDirectory(sampleIndex: Int) -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent(
			"RepoPrompt-AgentSidebarDeleteResponsivenessBenchmark-\(sampleIndex)-\(UUID().uuidString)",
			isDirectory: true
		)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private func metricSummaryPayload(sampleIndex: Int) -> [String: Any] {
		let summary = AgentModePerfDiagnostics.debugMetricSummarySnapshot(
			lineLimit: 1,
			eventNames: Set(deleteEventNames)
		)
		let rawEvents = summary["events"] as? [String: Any] ?? [:]
		let events = deleteEventNames.reduce(into: [String: Any]()) { partial, name in
			partial[name] = rawEvents[name] ?? emptyEventSummary()
		}
		return [
			"sample_index": sampleIndex,
			"ok": summary["ok"] ?? false,
			"window": summary["window"] ?? [String: Any](),
			"events": events
		]
	}

	private func durationMetric(_ eventName: String, in metricSummary: [String: Any]) throws -> Double {
		let events = try XCTUnwrap(metricSummary["events"] as? [String: Any])
		let summary = try XCTUnwrap(events[eventName] as? [String: Any])
		let count = intValue(summary["duration_count"]) ?? 0
		XCTAssertEqual(count, 1, "Expected exactly one duration for \(eventName)")
		return try XCTUnwrap(doubleValue(summary["median_ms"]))
	}

	private func emptyEventSummary() -> [String: Any] {
		[
			"count": 0,
			"duration_count": 0,
			"malformed_duration_count": 0,
			"median_ms": NSNull(),
			"p95_ms": NSNull(),
			"max_ms": NSNull(),
			"total_ms": NSNull(),
			"first_sequence": NSNull(),
			"last_sequence": NSNull()
		]
	}

	private func intValue(_ value: Any?) -> Int? {
		if let int = value as? Int { return int }
		if let number = value as? NSNumber { return number.intValue }
		return nil
	}

	private func doubleValue(_ value: Any?) -> Double? {
		if let double = value as? Double, double.isFinite { return double }
		if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
		return nil
	}

	private func trimmed(_ values: [Double], dropFastest: Int, dropSlowest: Int) -> [Double] {
		let sorted = values.sorted()
		let lower = min(max(dropFastest, 0), sorted.count)
		let upper = max(lower, sorted.count - max(dropSlowest, 0))
		return Array(sorted[lower..<upper])
	}

	private func median(_ values: [Double]) -> Double {
		Self.median(values)
	}

	nonisolated private static func median(_ values: [Double]) -> Double {
		let sorted = values.sorted()
		guard !sorted.isEmpty else { return 0 }
		let midpoint = sorted.count / 2
		if sorted.count.isMultiple(of: 2) {
			return (sorted[midpoint - 1] + sorted[midpoint]) / 2.0
		}
		return sorted[midpoint]
	}

	private func nearestRankPercentile(_ values: [Double], percentile: Double) -> Double {
		let sorted = values.sorted()
		guard !sorted.isEmpty else { return 0 }
		let rank = Int(ceil(percentile * Double(sorted.count))) - 1
		return sorted[min(max(rank, 0), sorted.count - 1)]
	}

	private func roundMilliseconds(_ value: Double) -> Double {
		Self.roundMilliseconds(value)
	}

	nonisolated private static func roundMilliseconds(_ value: Double) -> Double {
		(value * 10.0).rounded() / 10.0
	}
}
#endif
