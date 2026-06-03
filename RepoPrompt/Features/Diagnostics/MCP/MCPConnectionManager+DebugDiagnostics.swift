// MARK: - Hidden DEBUG Diagnostics Surface
import Foundation
import MCP

#if DEBUG
extension ServerNetworkManager {
	static let debugDiagnosticsToolName = "__repoprompt_debug_diagnostics"
	static let legacyDebugTransportToolName = "__repoprompt_debug_transport"
	static let debugDiagnosticsToolNames: Set<String> = [
		debugDiagnosticsToolName,
		legacyDebugTransportToolName
	]

	nonisolated static func isDebugDiagnosticsToolName(_ toolName: String) -> Bool {
		debugDiagnosticsToolNames.contains(toolName)
	}

	func handleDebugDiagnosticsTool(
		connectionID: UUID,
		arguments: [String: Value]
	) async -> CallTool.Result {
		guard let op = debugString(arguments, "op"), !op.isEmpty else {
			return debugDiagnosticsError(op: nil, code: "invalid_params", message: "Missing required string argument `op`.")
		}

		switch op {
		case "ping":
			return debugDiagnosticsResult(await debugPingPayload(connectionID: connectionID, op: op, arguments: arguments))
		case "connection_snapshot":
			return await debugConnectionSnapshotToolPayload(op: op, connectionID: connectionID, arguments: arguments)
		case "routing_snapshot":
			return await debugRoutingSnapshotToolPayload(op: op, connectionID: connectionID, arguments: arguments)
		case "connection_history":
			return debugConnectionHistoryToolPayload(op: op, arguments: arguments)
		case "clear_connection_history":
			return debugClearConnectionHistoryToolPayload(op: op, arguments: arguments)
		case "wait_for_reconnect":
			return await debugWaitForReconnectToolPayload(op: op, connectionID: connectionID, arguments: arguments)
		case "clear_routing_state":
			return debugClearRoutingStateToolPayload(op: op, connectionID: connectionID, arguments: arguments)
		case "seed_routing_affinity":
			return await debugSeedRoutingAffinityToolPayload(op: op, connectionID: connectionID, arguments: arguments)
		case "shutdown_and_restart":
			return debugShutdownAndRestartToolPayload(op: op, arguments: arguments)
		case "restart_status":
			return debugRestartStatusToolPayload(op: op, arguments: arguments)
		case "connections":
			return await debugConnectionsPayload(op: op, arguments: arguments)
		case "sleep":
			return await debugSleepPayload(op: op, arguments: arguments)
		case "large_response":
			return debugLargeResponsePayload(op: op, arguments: arguments)
		case "sleep_then_large_response":
			return await debugSleepThenLargeResponsePayload(op: op, arguments: arguments)
		case "force_remove_connection":
			return await debugForceRemoveConnectionPayload(op: op, connectionID: connectionID, arguments: arguments)
		case "seed_active_tool_probe":
			return await debugSeedActiveToolProbePayload(op: op, arguments: arguments)
		case "active_tool_probe_status":
			return await debugActiveToolProbeStatusPayload(op: op, arguments: arguments)
		case "clear_active_tool_probe":
			return await debugClearActiveToolProbePayload(op: op, arguments: arguments)
		case "restore_perf_metrics":
			#if DEBUG
			return debugRestorePerfMetricsPayload(op: op, arguments: arguments)
			#else
			return debugDiagnosticsError(op: op, code: "unavailable", message: "`restore_perf_metrics` is only available in DEBUG builds.")
			#endif
		case "large_workspace_memory":
			#if DEBUG
			return await debugLargeWorkspaceMemoryPayload(op: op, arguments: arguments)
			#else
			return debugDiagnosticsError(op: op, code: "unavailable", message: "`large_workspace_memory` is only available in DEBUG builds.")
			#endif
		case "codemap_memory_counters":
			#if DEBUG
			return await debugCodemapMemoryCountersPayload(op: op, arguments: arguments)
			#else
			return debugDiagnosticsError(op: op, code: "unavailable", message: "`codemap_memory_counters` is only available in DEBUG builds.")
			#endif
		case "agent_perf_metrics":
			#if DEBUG
			return await debugAgentPerfMetricsPayload(op: op, arguments: arguments)
			#else
			return debugDiagnosticsError(op: op, code: "unavailable", message: "`agent_perf_metrics` is only available in DEBUG builds.")
			#endif
		case "seed_agent_text_derivation_fixture":
			#if DEBUG
			return await debugSeedAgentTextDerivationFixturePayload(op: op, arguments: arguments)
			#else
			return debugDiagnosticsError(op: op, code: "unavailable", message: "`seed_agent_text_derivation_fixture` is only available in DEBUG builds.")
			#endif
		case "font_scale_metrics":
			#if DEBUG
			return await debugFontScaleMetricsPayload(op: op, arguments: arguments)
			#else
			return debugDiagnosticsError(op: op, code: "unavailable", message: "`font_scale_metrics` is only available in DEBUG builds.")
			#endif
		case "chat_preview_context_latency":
			#if DEBUG
			return await debugChatPreviewContextLatencyPayload(op: op, arguments: arguments)
			#else
			return debugDiagnosticsError(op: op, code: "unavailable", message: "`chat_preview_context_latency` is only available in DEBUG builds.")
			#endif
		case "bootstrap_diagnostics":
			return await debugBootstrapDiagnosticsPayload(op: op)
		default:
			return debugDiagnosticsError(op: op, code: "unknown_op", message: "Unknown debug diagnostics op: \(op)")
		}
	}

	func debugDiagnosticsResult(_ object: [String: Any], isError: Bool = false) -> CallTool.Result {
		CallTool.Result(
			content: [MCP.Tool.Content.text(Self.debugJSONString(object))],
			isError: isError
		)
	}

	func debugDiagnosticsError(op: String?, code: String, message: String) -> CallTool.Result {
		var payload: [String: Any] = [
			"ok": false,
			"code": code,
			"error": message
		]
		payload["op"] = op ?? NSNull()
		return debugDiagnosticsResult(payload, isError: true)
	}

	func debugString(_ arguments: [String: Value], _ key: String) -> String? {
		arguments[key]?.stringValue
	}

	func debugBool(_ arguments: [String: Value], _ key: String) -> Bool? {
		guard let value = arguments[key] else { return nil }
		switch value {
		case .bool(let bool):
			return bool
		case .int(let int):
			return int != 0
		case .string(let string):
			switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
			case "true", "1", "yes": return true
			case "false", "0", "no": return false
			default: return nil
			}
		default:
			return nil
		}
	}

	func debugDouble(_ arguments: [String: Value], _ key: String) -> Double? {
		guard let value = arguments[key] else { return nil }
		switch value {
		case .double(let double):
			return double
		case .int(let int):
			return Double(int)
		case .string(let string):
			return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
		default:
			return nil
		}
	}

	enum DebugIntParseResult {
		case value(Int)
		case defaulted(Int)
		case invalid
	}

	func debugBoundedInt(
		_ arguments: [String: Value],
		_ key: String,
		defaultValue: Int,
		range: ClosedRange<Int>
	) -> DebugIntParseResult {
		guard let rawValue = arguments[key] else {
			return range.contains(defaultValue) ? .defaulted(defaultValue) : .invalid
		}

		let parsed: Int
		switch rawValue {
		case .int(let int):
			parsed = int
		case .double(let double):
			guard double.isFinite,
				double.rounded(.towardZero) == double,
				double >= Double(Int.min),
				double <= Double(Int.max) else {
				return .invalid
			}
			parsed = Int(double)
		case .string(let string):
			guard let int = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
				return .invalid
			}
			parsed = int
		default:
			return .invalid
		}

		guard range.contains(parsed) else { return .invalid }
		return .value(parsed)
	}

	func debugStringArray(_ arguments: [String: Value], _ key: String, op _: String) -> [String]?? {
		guard let value = arguments[key] else { return .some(nil) }
		if let string = value.stringValue {
			return .some([string])
		}
		guard let array = value.arrayValue else { return nil }
		var strings: [String] = []
		strings.reserveCapacity(array.count)
		for item in array {
			guard let string = item.stringValue else { return nil }
			strings.append(string)
		}
		return .some(strings)
	}

	func debugOptionalUUID(_ arguments: [String: Value], _ key: String, op _: String) -> UUID?? {
		guard let raw = debugString(arguments, key) else { return .some(nil) }
		guard let uuid = UUID(uuidString: raw) else { return nil }
		return .some(uuid)
	}

	func debugUUIDSet(_ arguments: [String: Value], _ key: String, op: String) -> Set<UUID>? {
		guard let stringsOptional = debugStringArray(arguments, key, op: op) else { return nil }
		guard let strings = stringsOptional else { return [] }
		var result = Set<UUID>()
		for string in strings {
			guard let uuid = UUID(uuidString: string) else { return nil }
			result.insert(uuid)
		}
		return result
	}

	func debugRestorePerfMetricsPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
		#if DEBUG
		if let enable = debugBool(arguments, "enable") {
			WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(enable)
		}
		if debugBool(arguments, "clear") == true {
			WorkspaceRestorePerfLog.clearRecentMetricLines()
		}
		if debugBool(arguments, "emit_probe") == true {
			WorkspaceRestorePerfLog.log("restore.metrics probe source=debugDiagnostics")
		}

		let limit: Int
		switch debugBoundedInt(arguments, "limit", defaultValue: 100, range: 1...2000) {
		case .value(let parsed), .defaulted(let parsed):
			limit = parsed
		case .invalid:
			return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 2000.")
		}

		var payload = WorkspaceRestorePerfLog.debugStateSnapshot(lineLimit: limit)
		payload["ok"] = true
		payload["op"] = op
		return debugDiagnosticsResult(payload)
		#else
		return debugDiagnosticsError(op: op, code: "unavailable", message: "`restore_perf_metrics` is only available in DEBUG builds.")
		#endif
	}

	func debugLargeWorkspaceMemoryPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
		#if DEBUG
		let action = debugString(arguments, "action")?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased() ?? "snapshot"
		let sampler = DebugProcessMemorySampler.shared

		let response: DebugProcessMemorySampler.DebugMemorySamplerResponse
		switch action {
		case "start":
			let intervalMS: Int
			switch debugBoundedInt(arguments, "interval_ms", defaultValue: 100, range: 50...5000) {
			case .value(let parsed), .defaulted(let parsed):
				intervalMS = parsed
			case .invalid:
				return debugDiagnosticsError(op: op, code: "invalid_params", message: "`interval_ms` must be an integer between 50 and 5000.")
			}
			let label = debugString(arguments, "label")?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			let reset = debugBool(arguments, "reset") ?? false
			response = await sampler.start(
				label: (label?.isEmpty == false ? label : nil) ?? "large-workspace-memory",
				intervalMS: intervalMS,
				reset: reset
			)
		case "mark":
			guard let mark = debugString(arguments, "mark")?
				.trimmingCharacters(in: .whitespacesAndNewlines),
				!mark.isEmpty else {
				return debugDiagnosticsError(op: op, code: "invalid_params", message: "`mark` must be a non-empty string for action `mark`.")
			}
			response = await sampler.mark(mark)
		case "stop":
			let settleSeconds = debugDouble(arguments, "settle_seconds") ?? 0
			guard settleSeconds.isFinite, settleSeconds >= 0, settleSeconds <= 300 else {
				return debugDiagnosticsError(op: op, code: "invalid_params", message: "`settle_seconds` must be a number between 0 and 300.")
			}
			response = await sampler.stop(settleSeconds: settleSeconds)
		case "snapshot":
			let limit: Int
			switch debugBoundedInt(arguments, "limit", defaultValue: 50, range: 1...1000) {
			case .value(let parsed), .defaulted(let parsed):
				limit = parsed
			case .invalid:
				return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 1000.")
			}
			response = await sampler.snapshot(limit: limit)
		case "current":
			let limit: Int
			switch debugBoundedInt(arguments, "limit", defaultValue: 50, range: 1...1000) {
			case .value(let parsed), .defaulted(let parsed):
				limit = parsed
			case .invalid:
				return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 1000.")
			}
			response = await sampler.current(limit: limit)
		case "reset":
			response = await sampler.reset()
		default:
			return debugDiagnosticsError(op: op, code: "invalid_params", message: "Unknown `large_workspace_memory` action: \(action).")
		}

		switch response {
		case .payload(var payload):
			payload["op"] = op
			payload["action"] = action
			return debugDiagnosticsResult(payload)
		case .error(let code, let message):
			return debugDiagnosticsError(op: op, code: code, message: message)
		}
		#else
		return debugDiagnosticsError(op: op, code: "unavailable", message: "`large_workspace_memory` is only available in DEBUG builds.")
		#endif
	}

	func debugCodemapMemoryCountersPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
		#if DEBUG
		let windowID: Int
		switch debugBoundedInt(arguments, "window_id", defaultValue: -1, range: -1...100_000) {
		case .value(let parsed), .defaulted(let parsed):
			windowID = parsed
		case .invalid:
			return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` must be an integer between -1 and 100000; values <= 0 or omission aggregate all windows.")
		}
		let includeWindows = debugBool(arguments, "include_windows") ?? true

		switch await Self.debugCollectCodemapMemoryCounters(op: op, windowID: windowID, includeWindows: includeWindows) {
		case .payload(let payload):
			return debugDiagnosticsResult(payload)
		case .error(let code, let message):
			return debugDiagnosticsError(op: op, code: code, message: message)
		}
		#else
		return debugDiagnosticsError(op: op, code: "unavailable", message: "`codemap_memory_counters` is only available in DEBUG builds.")
		#endif
	}

	func debugAgentPerfMetricsPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
		#if DEBUG
		if let enable = debugBool(arguments, "enable") {
			AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(enable)
		}
		if debugBool(arguments, "clear") == true {
			AgentModePerfDiagnostics.clearRecentMetrics()
		}
		if debugBool(arguments, "emit_probe") == true {
			AgentModePerfDiagnostics.event("agent.metrics.probe", fields: ["source": "debugDiagnostics"])
		}
		let mark = debugString(arguments, "mark")?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		if let mark, !mark.isEmpty {
			AgentModePerfDiagnostics.event("agent.metrics.mark", fields: ["mark": mark])
		}
		let wantsSummary = debugBool(arguments, "summary") == true
		let startMark = debugString(arguments, "start_mark")?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let endMark = debugString(arguments, "end_mark")?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let eventNames: Set<String>?
		if wantsSummary {
			guard let parsedEventNames = debugStringArray(arguments, "event_names", op: op) else {
				return debugDiagnosticsError(op: op, code: "invalid_params", message: "`event_names` must be a string or array of strings.")
			}
			eventNames = parsedEventNames.map { Set($0) }
		} else {
			eventNames = nil
		}

		// Optional diagnostic-only session snapshot collection. Lets scripted
		// multi-window validation populate `latest_session_snapshots` without
		// forcing focus cycling through every Agent tab. No UI sync runs.
		var snapshotSummary: [String: Any]? = nil
		if debugBool(arguments, "snapshot_sessions") == true {
			guard let parsedTabIDs = debugUUIDSet(arguments, "tab_ids", op: op) else {
				return debugDiagnosticsError(op: op, code: "invalid_params", message: "`tab_ids` must be an array of UUID strings.")
			}
			let filter: Set<UUID>? = parsedTabIDs.isEmpty ? nil : parsedTabIDs
			snapshotSummary = await captureAgentPerfSessionSnapshots(filter: filter)
		}

		let limit: Int
		switch debugBoundedInt(arguments, "limit", defaultValue: 100, range: 1...2000) {
		case .value(let parsed), .defaulted(let parsed):
			limit = parsed
		case .invalid:
			return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 2000.")
		}

		var payload = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: limit)
		payload["ok"] = true
		payload["op"] = op
		if let mark, !mark.isEmpty {
			payload["mark"] = mark
		}
		if let snapshotSummary {
			payload["snapshot_sessions_result"] = snapshotSummary
		}
		if wantsSummary {
			payload["summary"] = AgentModePerfDiagnostics.debugMetricSummarySnapshot(
				lineLimit: limit,
				startMark: startMark,
				endMark: endMark,
				eventNames: eventNames
			)
		}
		return debugDiagnosticsResult(payload)
		#else
		return debugDiagnosticsError(op: op, code: "unavailable", message: "`agent_perf_metrics` is only available in DEBUG builds.")
		#endif
	}

	func debugFontScaleMetricsPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
		#if DEBUG
		if let enable = debugBool(arguments, "enable") {
			FontScalePerfDiagnostics.setDebugProcessOverrideEnabled(enable)
		}
		if debugBool(arguments, "clear") == true {
			FontScalePerfDiagnostics.clearRecentMetrics()
		}
		if debugBool(arguments, "emit_probe") == true {
			FontScalePerfDiagnostics.event("fontScale.metrics.probe", fields: ["source": "debugDiagnostics"])
		}
		let mark = debugString(arguments, "mark")?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		if let mark, !mark.isEmpty {
			FontScalePerfDiagnostics.event("fontScale.metrics.mark", fields: ["mark": mark])
		}

		let limit: Int
		switch debugBoundedInt(arguments, "limit", defaultValue: 100, range: 1...1000) {
		case .value(let parsed), .defaulted(let parsed):
			limit = parsed
		case .invalid:
			return debugDiagnosticsError(op: op, code: "invalid_params", message: "`limit` must be an integer between 1 and 1000.")
		}

		let fontState = await MainActor.run { () -> (current: FontScalePreset, manager: FontScalePreset, isFrozen: Bool) in
			(FontScalePreset.current, FontScaleManager.shared.preset, FontScaleManager.shared.isFrozen)
		}
		var payload = FontScalePerfDiagnostics.debugStateSnapshot(
			lineLimit: limit,
			currentPreset: fontState.current,
			managerPreset: fontState.manager,
			managerIsFrozen: fontState.isFrozen
		)
		payload["ok"] = true
		payload["op"] = op
		if let mark, !mark.isEmpty {
			payload["mark"] = mark
		}
		return debugDiagnosticsResult(payload)
		#else
		return debugDiagnosticsError(op: op, code: "unavailable", message: "`font_scale_metrics` is only available in DEBUG builds.")
		#endif
	}

	func debugChatPreviewContextLatencyPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
		#if DEBUG
		let windowID: Int
		switch debugBoundedInt(arguments, "window_id", defaultValue: -1, range: -1...100_000) {
		case .value(let parsed), .defaulted(let parsed):
			windowID = parsed
		case .invalid:
			return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` must be an integer between -1 and 100000; values <= 0 or omission use the focused/latest window.")
		}

		let warmups: Int
		switch debugBoundedInt(arguments, "warmups", defaultValue: 1, range: 0...20) {
		case .value(let parsed), .defaulted(let parsed):
			warmups = parsed
		case .invalid:
			return debugDiagnosticsError(op: op, code: "invalid_params", message: "`warmups` must be an integer between 0 and 20.")
		}

		let iterations: Int
		switch debugBoundedInt(arguments, "iterations", defaultValue: 5, range: 1...100) {
		case .value(let parsed), .defaulted(let parsed):
			iterations = parsed
		case .invalid:
			return debugDiagnosticsError(op: op, code: "invalid_params", message: "`iterations` must be an integer between 1 and 100.")
		}

		switch await Self.debugMeasureChatPreviewContextLatency(op: op, windowID: windowID, warmups: warmups, iterations: iterations) {
		case .payload(let payload):
			return debugDiagnosticsResult(payload)
		case .error(let code, let message):
			return debugDiagnosticsError(op: op, code: code, message: message)
		}
		#else
		return debugDiagnosticsError(op: op, code: "unavailable", message: "`chat_preview_context_latency` is only available in DEBUG builds.")
		#endif
	}

	private enum DebugChatPreviewMeasurementResult {
		case payload([String: Any])
		case error(code: String, message: String)
	}

	private func debugSeedAgentTextDerivationFixturePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
		#if DEBUG
		let windowID: Int
		switch debugBoundedInt(arguments, "window_id", defaultValue: 0, range: 0...Int.max) {
		case .value(let parsed), .defaulted(let parsed):
			windowID = parsed
		case .invalid:
			return debugDiagnosticsError(op: op, code: "invalid_params", message: "`window_id` must be a non-negative integer.")
		}
		let reset = debugBool(arguments, "reset") ?? true
		let activateAgentMode = debugBool(arguments, "activate_agent_mode") ?? true
		let tabID: UUID?
		if let rawTabID = debugString(arguments, "tab_id")?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTabID.isEmpty {
			guard let parsedTabID = UUID(uuidString: rawTabID) else {
				return debugDiagnosticsError(op: op, code: "invalid_params", message: "`tab_id` must be a valid UUID when provided.")
			}
			tabID = parsedTabID
		} else {
			tabID = nil
		}

		switch await Self.debugSeedAgentTextDerivationFixture(
			op: op,
			windowID: windowID,
			tabID: tabID,
			reset: reset,
			activateAgentMode: activateAgentMode
		) {
		case .payload(let payload):
			return debugDiagnosticsResult(payload)
		case .error(let code, let message):
			return debugDiagnosticsError(op: op, code: code, message: message)
		}
		#else
		return debugDiagnosticsError(op: op, code: "unavailable", message: "`seed_agent_text_derivation_fixture` is only available in DEBUG builds.")
		#endif
	}

	@MainActor
	private static func debugSeedAgentTextDerivationFixture(
		op: String,
		windowID: Int,
		tabID: UUID?,
		reset: Bool,
		activateAgentMode: Bool
	) async -> DebugChatPreviewMeasurementResult {
		let manager = WindowStatesManager.shared
		let selectedWindow: WindowState?
		if windowID > 0 {
			selectedWindow = manager.allWindows.first { $0.windowID == windowID }
		} else {
			selectedWindow = manager.allWindows.first { $0.isCurrentlyFocused } ?? manager.latestWindowState
		}
		guard let window = selectedWindow else {
			return .error(code: "no_window", message: "No matching RepoPrompt window is available for text derivation fixture seeding.")
		}

		guard let tab = await window.promptManager.ensureActiveComposeTab(
			tabID,
			creationStrategy: .blank,
			name: "Text Derivation Fixture"
		) else {
			return .error(code: "no_tab", message: "Unable to resolve or create a compose tab for text derivation fixture seeding.")
		}

		if activateAgentMode {
			window.uiMode = .agent
		}
		let counts = await window.agentModeViewModel.testSeedTextDerivationFixture(tabID: tab.id, reset: reset)
		return .payload([
			"ok": true,
			"op": op,
			"window_id": window.windowID,
			"tab_id": tab.id.uuidString,
			"workspace": window.workspaceManager.activeWorkspace?.name ?? NSNull(),
			"reset": reset,
			"activate_agent_mode": activateAgentMode,
			"appended_counts": counts,
			"fixture": "debug_text_derivation_fixture_v1",
			"notes": "DEBUG-only synthetic Agent transcript with three long assistant messages plus plain/diff/json tool payloads. The first assistant is intentionally older than the two most recent assistant rows so collapse derivation can run when rendered."
		])
	}

	private struct DebugChatPreviewTreeShape {
		let roots: Int
		let folders: Int
		let files: Int
		let codemapFiles: Int
	}

	@MainActor
	private static func debugMeasureChatPreviewContextLatency(op: String, windowID: Int, warmups: Int, iterations: Int) async -> DebugChatPreviewMeasurementResult {
		let manager = WindowStatesManager.shared
		let selectedWindow: WindowState?
		if windowID > 0 {
			selectedWindow = manager.allWindows.first { $0.windowID == windowID }
		} else {
			selectedWindow = manager.allWindows.first { $0.isCurrentlyFocused } ?? manager.latestWindowState
		}

		guard let window = selectedWindow else {
			return .error(code: "no_window", message: "No matching RepoPrompt window is available for chat preview context latency measurement.")
		}

		let promptViewModel = window.promptManager
		var lastTokenCount = 0

		for _ in 0..<warmups {
			lastTokenCount = await promptViewModel.calculateTokensForChatContext()
		}

		var durations: [Double] = []
		durations.reserveCapacity(iterations)
		for _ in 0..<iterations {
			let start = DispatchTime.now().uptimeNanoseconds
			lastTokenCount = await promptViewModel.calculateTokensForChatContext()
			let end = DispatchTime.now().uptimeNanoseconds
			durations.append(Double(end - start) / 1_000_000.0)
		}

		let sorted = durations.sorted()
		let median = Self.debugMedian(sorted)
		let p95 = Self.debugNearestRankPercentile(sorted, percentile: 0.95)
		let workspace = window.workspaceManager.activeWorkspace
		let rootSummary = debugCountTreeShape(rootFolders: window.fileManager.rootFolders)
		let visibleRootSummary = debugCountTreeShape(rootFolders: window.fileManager.visibleRootFolders)
		let currentPreset = promptViewModel.currentChatPreset()
		let fixtureDescription = "real workspace \"\(workspace?.name ?? "<none>")\"; roots=\(rootSummary.roots), folders=\(rootSummary.folders), files=\(rootSummary.files), visibleRoots=\(visibleRootSummary.roots), visibleFolders=\(visibleRootSummary.folders), visibleFiles=\(visibleRootSummary.files), selected=\(window.fileManager.selectedFiles.count), autoCodemap=\(window.fileManager.autoCodemapFiles.count), codemapAttached=\(rootSummary.codemapFiles), chatPreset=\(currentPreset.name), fileTree=\(promptViewModel.fileTreeOptionForChat.rawValue), codeMap=\(promptViewModel.codeMapUsageForChat.rawValue), git=\(promptViewModel.gitDiffInclusionModeForChat.rawValue)"

		return .payload([
			"ok": true,
			"op": op,
			"metric": "chat_preview_context_baseline_ms",
			"scope": "real_workspace_rp_cli_debug_prompt_context",
			"window_id": window.windowID,
			"workspace_id": workspace?.id.uuidString ?? "<none>",
			"workspace_name": workspace?.name ?? "<none>",
			"warmups": warmups,
			"iterations": iterations,
			"median_ms": median,
			"p95_ms": p95,
			"durations_ms": durations.map { Self.debugRoundedMS($0) },
			"last_token_count": lastTokenCount,
			"fixture": fixtureDescription,
			"shape": [
				"roots": rootSummary.roots,
				"folders": rootSummary.folders,
				"files": rootSummary.files,
				"visible_roots": visibleRootSummary.roots,
				"visible_folders": visibleRootSummary.folders,
				"visible_files": visibleRootSummary.files,
				"selected_files": window.fileManager.selectedFiles.count,
				"auto_codemap_files": window.fileManager.autoCodemapFiles.count,
				"codemap_attached_files": rootSummary.codemapFiles
			],
			"chat_preset": [
				"id": currentPreset.id.uuidString,
				"name": currentPreset.name,
				"mode": currentPreset.mode.rawValue,
				"file_tree": promptViewModel.fileTreeOptionForChat.rawValue,
				"code_map": promptViewModel.codeMapUsageForChat.rawValue,
				"git": promptViewModel.gitDiffInclusionModeForChat.rawValue
			],
			"selector": "rp-cli-debug --call __repoprompt_debug_diagnostics --json '{\"op\":\"chat_preview_context_latency\",\"window_id\":\(window.windowID),\"warmups\":\(warmups),\"iterations\":\(iterations)}'"
		])
	}

	@MainActor
	private static func debugCountTreeShape(rootFolders: [FolderViewModel]) -> DebugChatPreviewTreeShape {
		var folderCount = 0
		var fileCount = 0
		var codemapFileCount = 0
		for root in rootFolders {
			let childShape = debugCountTreeShape(folder: root)
			folderCount += 1 + childShape.folders
			fileCount += childShape.files
			codemapFileCount += childShape.codemapFiles
		}
		return DebugChatPreviewTreeShape(
			roots: rootFolders.count,
			folders: folderCount,
			files: fileCount,
			codemapFiles: codemapFileCount
		)
	}

	@MainActor
	private static func debugCountTreeShape(folder: FolderViewModel) -> DebugChatPreviewTreeShape {
		var folderCount = 0
		var fileCount = folder.files.count
		var codemapFileCount = folder.files.reduce(0) { partial, file in
			partial + (file.fileAPI == nil ? 0 : 1)
		}
		for child in folder.subfolders {
			let childShape = debugCountTreeShape(folder: child)
			folderCount += 1 + childShape.folders
			fileCount += childShape.files
			codemapFileCount += childShape.codemapFiles
		}
		return DebugChatPreviewTreeShape(
			roots: 0,
			folders: folderCount,
			files: fileCount,
			codemapFiles: codemapFileCount
		)
	}

	private static func debugMedian(_ sortedValues: [Double]) -> Double {
		guard !sortedValues.isEmpty else { return 0 }
		let midpoint = sortedValues.count / 2
		if sortedValues.count.isMultiple(of: 2) {
			return debugRoundedMS((sortedValues[midpoint - 1] + sortedValues[midpoint]) / 2.0)
		}
		return debugRoundedMS(sortedValues[midpoint])
	}

	private static func debugNearestRankPercentile(_ sortedValues: [Double], percentile: Double) -> Double {
		guard !sortedValues.isEmpty else { return 0 }
		let rank = Int(ceil(percentile * Double(sortedValues.count))) - 1
		let clamped = min(max(rank, 0), sortedValues.count - 1)
		return debugRoundedMS(sortedValues[clamped])
	}

	private static func debugRoundedMS(_ value: Double) -> Double {
		(value * 10.0).rounded() / 10.0
	}

	#if DEBUG
	private enum DebugCodemapMemoryCountersResult {
		case payload([String: Any])
		case error(code: String, message: String)
	}

	@MainActor
	private static func debugCollectCodemapMemoryCounters(
		op: String,
		windowID: Int,
		includeWindows: Bool
	) async -> DebugCodemapMemoryCountersResult {
		let allWindows = WindowStatesManager.shared.allWindows
		let selectedWindows: [WindowState]
		if windowID > 0 {
			selectedWindows = allWindows.filter { $0.windowID == windowID }
			guard !selectedWindows.isEmpty else {
				return .error(code: "no_window", message: "No RepoPrompt window matched window_id \(windowID).")
			}
		} else {
			selectedWindows = allWindows
		}

		var countersByWindow: [(window: WindowState, workspaceID: String, workspaceName: String, counters: CodeScanActor.CodemapMemoryCounters)] = []
		countersByWindow.reserveCapacity(selectedWindows.count)
		for window in selectedWindows {
			let workspace = window.workspaceManager.activeWorkspace
			let counters = await window.fileManager.debugCodemapMemoryCounters()
			countersByWindow.append((
				window: window,
				workspaceID: workspace?.id.uuidString ?? "<none>",
				workspaceName: workspace?.name ?? "<none>",
				counters: counters
			))
		}

		let totals = countersByWindow.reduce(Self.debugEmptyCodemapMemoryCounters()) { partial, row in
			Self.debugAddCodemapMemoryCounters(partial, row.counters)
		}
		var payload: [String: Any] = [
			"ok": true,
			"op": op,
			"scope": windowID > 0 ? "window_id" : "all_windows",
			"window_count": countersByWindow.count,
			"totals": debugCodemapCountersDictionary(totals)
		]
		if windowID > 0 {
			payload["window_id"] = windowID
		}
		if includeWindows {
			payload["windows"] = countersByWindow.map { row in
				[
					"window_id": row.window.windowID,
					"workspace_id": row.workspaceID,
					"workspace_name": row.workspaceName,
					"counters": debugCodemapCountersDictionary(row.counters)
				] as [String: Any]
			}
		}
		return .payload(payload)
	}

	private static func debugEmptyCodemapMemoryCounters() -> CodeScanActor.CodemapMemoryCounters {
		CodeScanActor.CodemapMemoryCounters(
			fileAPIEntryCount: 0,
			latestFileModDateCount: 0,
			trackedRootCount: 0,
			trackedFileIDCount: 0,
			rootKeyByFileIDCount: 0,
			rootCacheRootCount: 0,
			rootCacheFileEntryCount: 0,
			dirtyRootCount: 0,
			rootCacheLoadTaskCount: 0,
			rebuildLookupRootCount: 0,
			rebuildLookupFileEntryCount: 0,
			queuedCount: 0,
			activeScanCount: 0,
			outstandingScanCount: 0,
			totalScheduledCount: 0,
			cacheProcessingCount: 0,
			resultBatchBufferCount: 0,
			resultBatchBufferFileAPICount: 0,
			actorRetainedFileAPILikeEntryCount: 0
		)
	}

	private static func debugAddCodemapMemoryCounters(
		_ lhs: CodeScanActor.CodemapMemoryCounters,
		_ rhs: CodeScanActor.CodemapMemoryCounters
	) -> CodeScanActor.CodemapMemoryCounters {
		CodeScanActor.CodemapMemoryCounters(
			fileAPIEntryCount: lhs.fileAPIEntryCount + rhs.fileAPIEntryCount,
			latestFileModDateCount: lhs.latestFileModDateCount + rhs.latestFileModDateCount,
			trackedRootCount: lhs.trackedRootCount + rhs.trackedRootCount,
			trackedFileIDCount: lhs.trackedFileIDCount + rhs.trackedFileIDCount,
			rootKeyByFileIDCount: lhs.rootKeyByFileIDCount + rhs.rootKeyByFileIDCount,
			rootCacheRootCount: lhs.rootCacheRootCount + rhs.rootCacheRootCount,
			rootCacheFileEntryCount: lhs.rootCacheFileEntryCount + rhs.rootCacheFileEntryCount,
			dirtyRootCount: lhs.dirtyRootCount + rhs.dirtyRootCount,
			rootCacheLoadTaskCount: lhs.rootCacheLoadTaskCount + rhs.rootCacheLoadTaskCount,
			rebuildLookupRootCount: lhs.rebuildLookupRootCount + rhs.rebuildLookupRootCount,
			rebuildLookupFileEntryCount: lhs.rebuildLookupFileEntryCount + rhs.rebuildLookupFileEntryCount,
			queuedCount: lhs.queuedCount + rhs.queuedCount,
			activeScanCount: lhs.activeScanCount + rhs.activeScanCount,
			outstandingScanCount: lhs.outstandingScanCount + rhs.outstandingScanCount,
			totalScheduledCount: lhs.totalScheduledCount + rhs.totalScheduledCount,
			cacheProcessingCount: lhs.cacheProcessingCount + rhs.cacheProcessingCount,
			resultBatchBufferCount: lhs.resultBatchBufferCount + rhs.resultBatchBufferCount,
			resultBatchBufferFileAPICount: lhs.resultBatchBufferFileAPICount + rhs.resultBatchBufferFileAPICount,
			actorRetainedFileAPILikeEntryCount: lhs.actorRetainedFileAPILikeEntryCount + rhs.actorRetainedFileAPILikeEntryCount
		)
	}

	private static func debugCodemapCountersDictionary(_ counters: CodeScanActor.CodemapMemoryCounters) -> [String: Any] {
		[
			"file_api_entries": counters.fileAPIEntryCount,
			"latest_file_mod_dates": counters.latestFileModDateCount,
			"tracked_roots": counters.trackedRootCount,
			"tracked_file_ids": counters.trackedFileIDCount,
			"root_key_by_file_ids": counters.rootKeyByFileIDCount,
			"root_cache_roots": counters.rootCacheRootCount,
			"root_cache_file_entries": counters.rootCacheFileEntryCount,
			"dirty_roots": counters.dirtyRootCount,
			"root_cache_load_tasks": counters.rootCacheLoadTaskCount,
			"rebuild_lookup_roots": counters.rebuildLookupRootCount,
			"rebuild_lookup_file_entries": counters.rebuildLookupFileEntryCount,
			"queued": counters.queuedCount,
			"active_scans": counters.activeScanCount,
			"outstanding_scans": counters.outstandingScanCount,
			"total_scheduled": counters.totalScheduledCount,
			"cache_processing": counters.cacheProcessingCount,
			"result_batch_buffer": counters.resultBatchBufferCount,
			"result_batch_buffer_file_apis": counters.resultBatchBufferFileAPICount,
			"actor_retained_file_api_like_entries": counters.actorRetainedFileAPILikeEntryCount
		]
	}

	/// Diagnostic-only helper that hops to the main actor, walks every registered
	/// window, and asks each `AgentModeViewModel` to record perf session snapshots
	/// for its live tabs (or the subset in `filter`). Used exclusively by the
	/// hidden `agent_perf_metrics` op; does not run any UI sync work.
	private func captureAgentPerfSessionSnapshots(filter: Set<UUID>?) async -> [String: Any] {
		await MainActor.run { () -> [String: Any] in
			var recordedByWindow: [[String: Any]] = []
			var totalRecorded = 0
			for window in WindowStatesManager.shared.allWindows {
				let recorded = window.agentModeViewModel.test_recordPerfSessionSnapshotsForAllTabs(
					source: "debugDiagnostics",
					tabIDs: filter
				)
				totalRecorded += recorded.count
				recordedByWindow.append([
					"window_id": window.windowID,
					"recorded_tab_ids": recorded.map(\.uuidString)
				])
			}
			return [
				"windows": recordedByWindow,
				"total_recorded": totalRecorded,
				"diagnostics_enabled": AgentModePerfDiagnostics.isEnabled
			]
		}
	}
	#endif

	nonisolated private static func debugJSONString(_ object: [String: Any]) -> String {
		do {
			let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
			return String(data: data, encoding: .utf8) ?? "{\"ok\":false,\"error\":\"Unable to encode debug response.\"}"
		} catch {
			let escaped = String(describing: error).replacingOccurrences(of: "\"", with: "\\\"")
			return "{\"ok\":false,\"error\":\"Unable to encode debug response: \(escaped)\"}"
		}
	}
}
#endif
