import Foundation

#if DEBUG
import os

/// Debug-only, opt-in aggregate counters for Agent Mode SwiftUI/AppKit layout hotspot triage.
///
/// Enable in debug builds with either:
/// - `defaults write com.repoprompt.RepoPrompt RPAgentLayoutHotspotDiagnosticsEnabled -bool YES`
/// - `RPAgentLayoutHotspotDiagnosticsEnabled=1`
/// - `RP_AGENT_LAYOUT_HOTSPOT_DIAGNOSTICS=1`
///
/// This helper intentionally stores counters behind a lock and emits optional OSLog summaries.
/// It does not publish SwiftUI/Combine state and is compiled out of release builds.
enum AgentModeLayoutHotspotDiagnostics {
	private static let logger = Logger(subsystem: "com.repoprompt.agent-layout-hotspot", category: "agent-mode")
	private static let defaultsKey = "RPAgentLayoutHotspotDiagnosticsEnabled"
	private static let camelEnvironmentKey = "RPAgentLayoutHotspotDiagnosticsEnabled"
	private static let environmentKey = "RP_AGENT_LAYOUT_HOTSPOT_DIAGNOSTICS"
	private static let osLogDefaultsKey = "RPAgentLayoutHotspotDiagnosticsEmitOSLog"
	private static let osLogEnvironmentKey = "RP_AGENT_LAYOUT_HOTSPOT_OSLOG"
	private static let enabledEnvironmentValues: Set<String> = ["1", "true", "yes", "on"]
	private static let summaryEveryEvents = 250
	private static let summaryIntervalSeconds: TimeInterval = 5
	private static let lock = NSLock()
	private static var counters: [String: Int] = [:]
	private static var eventCount = 0
	private static var lastSummaryAt = Date.distantPast

	static var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: defaultsKey)
			|| environmentFlagEnabled(camelEnvironmentKey)
			|| environmentFlagEnabled(environmentKey)
	}

	static var osLogEnabled: Bool {
		UserDefaults.standard.bool(forKey: osLogDefaultsKey)
			|| environmentFlagEnabled(osLogEnvironmentKey)
	}

	static func increment(_ key: String, tabID: UUID? = nil, by amount: Int = 1) {
		guard isEnabled else { return }
		let shouldEmitSummary: Bool
		let summary: String?
		lock.lock()
		incrementLocked(key, by: amount)
		if let tabID {
			incrementLocked("\(key).tab.\(tabID.uuidString)", by: amount)
		}
		eventCount += 1
		(shouldEmitSummary, summary) = summaryIfNeededLocked(now: Date())
		lock.unlock()
		if shouldEmitSummary, let summary {
			logger.debug("\(summary, privacy: .public)")
		}
	}

	static func record(_ key: String, tabID: UUID? = nil, fields: [String: String] = [:]) {
		guard isEnabled else { return }
		let renderedFields = renderFields(fields)
		increment(key, tabID: tabID)
		if osLogEnabled {
			let suffix = renderedFields.isEmpty ? "" : " \(renderedFields)"
			logger.debug("\(key, privacy: .public)\(suffix, privacy: .public)")
		}
	}

	static func shortID(_ id: UUID?) -> String {
		id?.uuidString.prefix(8).description ?? "nil"
	}

	private static func incrementLocked(_ key: String, by amount: Int) {
		counters[key, default: 0] += amount
	}

	private static func summaryIfNeededLocked(now: Date) -> (Bool, String?) {
		let intervalElapsed = now.timeIntervalSince(lastSummaryAt) >= summaryIntervalSeconds
		let countBoundary = eventCount.isMultiple(of: summaryEveryEvents)
		guard intervalElapsed || countBoundary else { return (false, nil) }
		lastSummaryAt = now
		let topCounters = counters
			.filter { !$0.key.contains(".tab.") }
			.sorted { lhs, rhs in
				if lhs.value == rhs.value { return lhs.key < rhs.key }
				return lhs.value > rhs.value
			}
			.prefix(40)
			.map { "\($0.key)=\($0.value)" }
			.joined(separator: " ")
		return (true, "layoutHotspot summary events=\(eventCount) \(topCounters)")
	}

	private static func renderFields(_ fields: [String: String]) -> String {
		fields.keys.sorted().map { key in
			"\(key)=\(sanitize(fields[key] ?? ""))"
		}.joined(separator: " ")
	}

	private static func sanitize(_ raw: String) -> String {
		raw
			.replacingOccurrences(of: "\n", with: "\\n")
			.replacingOccurrences(of: "\r", with: "\\r")
			.replacingOccurrences(of: "\t", with: "\\t")
			.replacingOccurrences(of: " ", with: "_")
	}

	private static func environmentFlagEnabled(_ key: String) -> Bool {
		let rawValue = ProcessInfo.processInfo.environment[key]?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		return rawValue.map { enabledEnvironmentValues.contains($0) } ?? false
	}
}
#endif
