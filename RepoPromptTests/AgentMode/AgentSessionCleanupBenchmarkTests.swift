#if DEBUG
import Foundation
import XCTest
import MCP
@testable import RepoPrompt

@MainActor
final class AgentSessionCleanupBenchmarkTests: XCTestCase {
	private let scenarioName = "cleanup_mixed_inactive_mcp_50_hot_index"
	private let warmupCount = 1
	private let measuredSampleCount = 9
	private let discardFastestCount = 1
	private let discardSlowestCount = 1
	private let openTargetCount = 20
	private let persistedTargetCount = 30
	private let backgroundPersistedCount = 150
	private let cleanupPhaseEventNames: [String] = [
		"cleanup.sessions.execute",
		"cleanup.sessions.loadPersistedMeta",
		"cleanup.sessions.deleteOpen",
		"cleanup.sessions.deletePersisted",
		"cleanup.sessions.finalize",
		"cleanup.metadata.removeRecords",
		"cleanup.metadata.writeIndex",
		"cleanup.vm.deleteSession",
		"cleanup.vm.finalizeDeletedReferences",
		"cleanup.vm.rebuildSessionSortDates"
	]

	func testCleanupSessionsMixedInactiveMCPBatchBenchmark() async throws {
		let previousDiagnosticsOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
		AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
		defer { AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousDiagnosticsOverride) }

		var warmupMS: [Double] = []
		var samplesMS: [Double] = []
		var deletedCounts: [Int] = []
		var skippedCounts: [Int] = []
		var warmupPhaseMetrics: [[String: Any]] = []
		var measuredPhaseMetrics: [[String: Any]] = []

		for sampleIndex in 0..<(warmupCount + measuredSampleCount) {
			let result = try await runCleanupSample(sampleIndex: sampleIndex)
			if sampleIndex < warmupCount {
				warmupMS.append(result.elapsedMS)
				warmupPhaseMetrics.append(result.phaseMetrics)
			} else {
				samplesMS.append(result.elapsedMS)
				deletedCounts.append(result.deletedCount)
				skippedCounts.append(result.skippedCount)
				measuredPhaseMetrics.append(result.phaseMetrics)
			}
		}

		let trimmedSamples = trimmed(samplesMS, dropFastest: discardFastestCount, dropSlowest: discardSlowestCount)
		let payload: [String: Any] = [
			"scenario": scenarioName,
			"warmup_count": warmupCount,
			"measured_sample_count": measuredSampleCount,
			"discard_rule": "discard fastest and slowest measured wall-clock sample",
			"batch": [
				"open_targets": openTargetCount,
				"persisted_targets": persistedTargetCount,
				"background_persisted": backgroundPersistedCount,
				"target_total": openTargetCount + persistedTargetCount,
				"index_record_total_before_delete": openTargetCount + persistedTargetCount + backgroundPersistedCount
			],
			"warmup_ms": warmupMS.map(roundMilliseconds),
			"samples_ms": samplesMS.map(roundMilliseconds),
			"trimmed_samples_ms": trimmedSamples.map(roundMilliseconds),
			"trimmed_median_ms": roundMilliseconds(median(trimmedSamples)),
			"trimmed_p95_ms": roundMilliseconds(nearestRankPercentile(trimmedSamples, percentile: 0.95)),
			"correctness": [
				"deleted_count_per_sample": deletedCounts,
				"skipped_count_per_sample": skippedCounts
			],
			"phase_metrics": [
				"event_names": cleanupPhaseEventNames,
				"source": "AgentModePerfDiagnostics.debugMetricSummarySnapshot after timed cleanup execute",
				"wall_clock_boundary": "unchanged: elapsed_ms only wraps AgentManageMCPToolService.execute(args:)",
				"warmup_samples": warmupPhaseMetrics,
				"measured_samples": measuredPhaseMetrics,
				"measured_aggregate": aggregatePhaseMetrics(measuredPhaseMetrics)
			]
		]
		let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
		let json = String(data: data, encoding: .utf8) ?? "{}"
		print("AGENT_SESSION_CLEANUP_BENCHMARK_JSON=\(json)")
		XCTContext.runActivity(named: "Agent session cleanup benchmark JSON") { activity in
			let attachment = XCTAttachment(string: "AGENT_SESSION_CLEANUP_BENCHMARK_JSON=\(json)")
			attachment.lifetime = .keepAlways
			activity.add(attachment)
		}
	}

	private struct SampleResult {
		let elapsedMS: Double
		let deletedCount: Int
		let skippedCount: Int
		let phaseMetrics: [String: Any]
	}

	private func cleanupPhaseMetrics(sampleIndex: Int, elapsedMS: Double) -> [String: Any] {
		let summary = AgentModePerfDiagnostics.debugMetricSummarySnapshot(
			lineLimit: 1,
			eventNames: Set(cleanupPhaseEventNames)
		)
		let rawEvents = summary["events"] as? [String: Any] ?? [:]
		let events = cleanupPhaseEventNames.reduce(into: [String: Any]()) { partial, name in
			partial[name] = rawEvents[name] ?? emptyPhaseSummary()
		}
		return [
			"sample_index": sampleIndex,
			"elapsed_ms": roundMilliseconds(elapsedMS),
			"ok": summary["ok"] ?? false,
			"window": summary["window"] ?? [String: Any](),
			"events": events
		]
	}

	private func emptyPhaseSummary() -> [String: Any] {
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

	private func aggregatePhaseMetrics(_ samples: [[String: Any]]) -> [String: Any] {
		var events: [String: Any] = [:]
		for eventName in cleanupPhaseEventNames {
			var sampleCount = 0
			var samplesWithEvent = 0
			var eventCountTotal = 0
			var durationCountTotal = 0
			var malformedDurationCountTotal = 0
			var perSampleTotalMS: [Double] = []
			var perSampleMedianMS: [Double] = []

			for sample in samples {
				guard let sampleEvents = sample["events"] as? [String: Any],
					let summary = sampleEvents[eventName] as? [String: Any] else { continue }
				sampleCount += 1
				let eventCount = intValue(summary["count"]) ?? 0
				if eventCount > 0 {
					samplesWithEvent += 1
				}
				eventCountTotal += eventCount
				durationCountTotal += intValue(summary["duration_count"]) ?? 0
				malformedDurationCountTotal += intValue(summary["malformed_duration_count"]) ?? 0
				if let total = doubleValue(summary["total_ms"]) {
					perSampleTotalMS.append(total)
				}
				if let median = doubleValue(summary["median_ms"]) {
					perSampleMedianMS.append(median)
				}
			}

			events[eventName] = [
				"sample_count": sampleCount,
				"samples_with_event": samplesWithEvent,
				"event_count_total": eventCountTotal,
				"duration_count_total": durationCountTotal,
				"malformed_duration_count_total": malformedDurationCountTotal,
				"per_sample_total_ms_median": metricMedianPayload(perSampleTotalMS),
				"per_sample_total_ms_p95": metricP95Payload(perSampleTotalMS),
				"per_sample_total_ms_max": metricMaxPayload(perSampleTotalMS),
				"per_sample_median_ms_median": metricMedianPayload(perSampleMedianMS),
				"per_sample_median_ms_p95": metricP95Payload(perSampleMedianMS)
			]
		}
		return [
			"sample_count": samples.count,
			"events": events
		]
	}

	private func metricMedianPayload(_ values: [Double]) -> Any {
		guard !values.isEmpty else { return NSNull() }
		return roundMilliseconds(median(values))
	}

	private func metricP95Payload(_ values: [Double]) -> Any {
		guard !values.isEmpty else { return NSNull() }
		return roundMilliseconds(nearestRankPercentile(values, percentile: 0.95))
	}

	private func metricMaxPayload(_ values: [Double]) -> Any {
		guard let maxValue = values.max() else { return NSNull() }
		return roundMilliseconds(maxValue)
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

	private func runCleanupSample(sampleIndex: Int) async throws -> SampleResult {
		let tempRoot = makeTempDirectory(sampleIndex: sampleIndex)
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		defer { Task { await windowState.tearDown() } }

		let fixture = try await seedFixture(windowState: windowState, sampleIndex: sampleIndex)
		let service = makeAgentManageService(windowState: windowState)
		AgentModePerfDiagnostics.clearRecentMetrics()
		let start = DispatchTime.now().uptimeNanoseconds
		let value = try await service.execute(args: [
			"op": .string("cleanup_sessions"),
			"session_ids": sessionIDsValue(fixture.targetSessionIDs)
		])
		let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
		let phaseMetrics = cleanupPhaseMetrics(sampleIndex: sampleIndex, elapsedMS: elapsedMS)

		let object = try XCTUnwrap(value.objectValue)
		let deletedCount = object["deleted_count"]?.intValue ?? -1
		let skippedCount = object["skipped_count"]?.intValue ?? -1
		XCTAssertEqual(object["status"]?.stringValue, "completed")
		XCTAssertEqual(deletedCount, openTargetCount + persistedTargetCount)
		XCTAssertEqual(skippedCount, 0)
		try await verifyCleanup(windowState: windowState, workspace: fixture.workspace, targets: fixture.targets)
		return SampleResult(elapsedMS: elapsedMS, deletedCount: deletedCount, skippedCount: skippedCount, phaseMetrics: phaseMetrics)
	}

	private struct TargetSession {
		let tabID: UUID?
		let sessionID: UUID
	}

	private struct Fixture {
		let workspace: WorkspaceModel
		let targets: [TargetSession]
		var targetSessionIDs: [UUID] { targets.map(\.sessionID) }
	}

	private func seedFixture(windowState: WindowState, sampleIndex: Int) async throws -> Fixture {
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let openTabIDs = try appendOpenTabs(windowState: windowState, count: openTargetCount)
		let openTargets = try await seedOpenInactiveMCPSessions(
			windowState: windowState,
			workspace: workspace,
			tabIDs: openTabIDs,
			sampleIndex: sampleIndex
		)
		let persistedTargets = try await seedPersistedClosedMCPSessions(
			workspace: workspace,
			count: persistedTargetCount,
			sampleIndex: sampleIndex
		)
		try await seedBackgroundPersistedSessions(
			workspace: workspace,
			count: backgroundPersistedCount,
			sampleIndex: sampleIndex
		)

		let persistedRecords = try await AgentSessionDataService.shared.listAgentSessionsMeta(for: workspace, limit: nil)
		XCTAssertEqual(persistedRecords.count, openTargetCount + persistedTargetCount + backgroundPersistedCount)
		let targets = interleaved(openTargets, persistedTargets)
		return Fixture(workspace: workspace, targets: targets)
	}

	private func appendOpenTabs(windowState: WindowState, count: Int) throws -> [UUID] {
		var workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let tabIDs = (0..<count).map { _ in UUID() }
		for (offset, tabID) in tabIDs.enumerated() {
			workspace.composeTabs.append(
				ComposeTabState(
					id: tabID,
					name: "Cleanup Open Target \(offset)",
					lastModified: Date()
				)
			)
		}
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
		return tabIDs
	}

	private func seedOpenInactiveMCPSessions(
		windowState: WindowState,
		workspace: WorkspaceModel,
		tabIDs: [UUID],
		sampleIndex: Int
	) async throws -> [TargetSession] {
		let agentModeVM = windowState.agentModeViewModel
		var targets: [TargetSession] = []
		var updatedWorkspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		for (offset, tabID) in tabIDs.enumerated() {
			agentModeVM.ensureSession(for: tabID)
			let session = try XCTUnwrap(agentModeVM.sessions[tabID])
			let sessionID = try XCTUnwrap(session.activeAgentSessionID)
			session.runState = .completed
			session.mcpFollowUpRunPending = false
			session.pendingSupersedingTurnCompletions = 0
			await agentModeVM.mcpActivateControlContext(
				forTabID: tabID,
				sessionID: sessionID,
				originatingConnectionID: UUID(),
				taskLabelKind: .engineer,
				startPending: false
			)
			if let tabIndex = updatedWorkspace.composeTabs.firstIndex(where: { $0.id == tabID }) {
				updatedWorkspace.composeTabs[tabIndex].activeAgentSessionID = sessionID
			}
			agentModeVM.upsertSessionIndex(
				sessionID: sessionID,
				tabID: tabID,
				name: "Cleanup Open Target \(offset)",
				lastUserMessageAt: Date(timeIntervalSince1970: Double(sampleIndex * 1_000 + offset)),
				savedAt: Date(),
				lastRunStateRaw: AgentSessionRunState.completed.rawValue,
				itemCount: 0,
				agentKindRaw: session.selectedAgent.rawValue,
				agentModelRaw: session.selectedModelRaw,
				agentReasoningEffortRaw: session.selectedReasoningEffortRaw,
				autoEditEnabled: session.autoEditEnabled,
				isMCPOriginated: true
			)
			_ = try await AgentSessionDataService.shared.saveAgentSession(
				makePersistedSession(
					id: sessionID,
					workspaceID: workspace.id,
					composeTabID: tabID,
					name: "Cleanup Open Target \(offset)",
					lastRunState: .completed,
					isMCPOriginated: true,
					savedAtOffset: sampleIndex * 1_000 + offset
				),
				for: workspace,
				preparation: .alreadyCanonicalTranscript
			)
			targets.append(TargetSession(tabID: tabID, sessionID: sessionID))
		}
		windowState.workspaceManager.workspaces = [updatedWorkspace]
		windowState.workspaceManager.activeWorkspace = updatedWorkspace
		return targets
	}

	private func seedPersistedClosedMCPSessions(
		workspace: WorkspaceModel,
		count: Int,
		sampleIndex: Int
	) async throws -> [TargetSession] {
		var targets: [TargetSession] = []
		for offset in 0..<count {
			let tabID = UUID()
			let sessionID = UUID()
			_ = try await AgentSessionDataService.shared.saveAgentSession(
				makePersistedSession(
					id: sessionID,
					workspaceID: workspace.id,
					composeTabID: tabID,
					name: "Cleanup Persisted Target \(offset)",
					lastRunState: .completed,
					isMCPOriginated: true,
					savedAtOffset: sampleIndex * 2_000 + offset
				),
				for: workspace,
				preparation: .alreadyCanonicalTranscript
			)
			targets.append(TargetSession(tabID: tabID, sessionID: sessionID))
		}
		return targets
	}

	private func seedBackgroundPersistedSessions(
		workspace: WorkspaceModel,
		count: Int,
		sampleIndex: Int
	) async throws {
		for offset in 0..<count {
			let isMCPOriginated = offset.isMultiple(of: 2)
			_ = try await AgentSessionDataService.shared.saveAgentSession(
				makePersistedSession(
					id: UUID(),
					workspaceID: workspace.id,
					composeTabID: UUID(),
					name: "Background Session \(offset)",
					lastRunState: .completed,
					isMCPOriginated: isMCPOriginated,
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
		isMCPOriginated: Bool,
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
			isMCPOriginated: isMCPOriginated
		)
	}

	private func verifyCleanup(
		windowState: WindowState,
		workspace: WorkspaceModel,
		targets: [TargetSession],
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws {
		let agentModeVM = windowState.agentModeViewModel
		let activeWorkspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace, file: file, line: line)
		for target in targets {
			let loadedDeletedSession = try await AgentSessionDataService.shared.loadAgentSession(id: target.sessionID, for: workspace)
			XCTAssertNil(loadedDeletedSession, "Expected target session file to be deleted", file: file, line: line)
			XCTAssertNil(agentModeVM.sessionIndex[target.sessionID], file: file, line: line)
			XCTAssertFalse(agentModeVM.sessions.values.contains(where: { $0.activeAgentSessionID == target.sessionID }), file: file, line: line)
			let storeSnapshot = await AgentRunSessionStore.snapshot(for: target.sessionID)
			XCTAssertNil(storeSnapshot, file: file, line: line)
			XCTAssertFalse(activeWorkspace.composeTabs.contains(where: { $0.activeAgentSessionID == target.sessionID }), file: file, line: line)
			XCTAssertFalse(activeWorkspace.stashedTabs.contains(where: { $0.tab.activeAgentSessionID == target.sessionID }), file: file, line: line)
			if let tabID = target.tabID, windowState.workspaceManager.composeTab(with: tabID) != nil {
				XCTAssertNil(agentModeVM.sessions[tabID], file: file, line: line)
			}
		}
	}

	private func interleaved(_ openTargets: [TargetSession], _ persistedTargets: [TargetSession]) -> [TargetSession] {
		var result: [TargetSession] = []
		let maxCount = max(openTargets.count, persistedTargets.count)
		for index in 0..<maxCount {
			if index < openTargets.count {
				result.append(openTargets[index])
			}
			if index < persistedTargets.count {
				result.append(persistedTargets[index])
			}
		}
		return result
	}

	private func makeAgentManageService(windowState: WindowState) -> AgentManageMCPToolService {
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "benchmark-client",
			windowID: windowState.windowID
		)
		return AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in }
		)
	}

	private func sessionIDsValue(_ sessionIDs: [UUID]) -> Value {
		.array(sessionIDs.map { .string($0.uuidString) })
	}

	private func makeWindowState(root: URL, sourceTabID: UUID) -> WindowState {
		let windowState = WindowState()
		let workspace = WorkspaceModel(
			name: "Session Cleanup Benchmark",
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
			"RepoPrompt-AgentSessionCleanupBenchmark-\(sampleIndex)-\(UUID().uuidString)",
			isDirectory: true
		)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private func trimmed(_ values: [Double], dropFastest: Int, dropSlowest: Int) -> [Double] {
		let sorted = values.sorted()
		let lower = min(max(dropFastest, 0), sorted.count)
		let upper = max(lower, sorted.count - max(dropSlowest, 0))
		return Array(sorted[lower..<upper])
	}

	private func median(_ values: [Double]) -> Double {
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
		(value * 10.0).rounded() / 10.0
	}
}
#endif
