import SwiftUI

struct AgentRunCardPresentation: Equatable {
	let sessionID: UUID?
	let statusWord: String?
	let statusText: String?
	let sessionNameOrID: String?
	let agentName: String?
	let model: String?
	let workflowLabel: String?
	let reasoningEffort: String?
	let assistantText: String?
	let interactionKind: String?
	let interactionPrompt: String?
	let deliveryRaw: String?
	let op: String

	init?(resultObject: [String: Any], args: ToolArgsDTOs.AgentRunArgs? = nil, opOverride: String? = nil) {
		let sessionObject = resultObject["session"] as? [String: Any]
		let agentObject = resultObject["agent"] as? [String: Any]
		let interactionObject = resultObject["interaction"] as? [String: Any]
		let metaObject = resultObject["_meta"] as? [String: Any]
		self.sessionID = Self.sessionID(from: resultObject, args: args)
		self.statusWord = (resultObject["status"] as? String)?.nonEmpty
		self.statusText = (resultObject["status_text"] as? String)?.nonEmpty
		self.sessionNameOrID = Self.sessionNameOrID(sessionObject: sessionObject, args: args)
		self.agentName = (agentObject?["name"] as? String)?.nonEmpty
			?? (agentObject?["id"] as? String)?.nonEmpty
			?? args?.agent?.nonEmpty
		self.model = (agentObject?["model"] as? String)?.nonEmpty ?? args?.model?.nonEmpty
		self.workflowLabel = (resultObject["workflow_name"] as? String)?.nonEmpty
			?? args?.workflowName?.nonEmpty
			?? (resultObject["workflow_id"] as? String)?.nonEmpty
			?? args?.workflowID?.nonEmpty
		self.reasoningEffort = (agentObject?["reasoning_effort"] as? String)?.nonEmpty ?? args?.reasoningEffort?.nonEmpty
		self.assistantText = (resultObject["assistant_text"] as? String)?.nonEmpty
		self.interactionKind = (interactionObject?["kind"] as? String)?.nonEmpty
		self.interactionPrompt = (interactionObject?["prompt"] as? String)?.nonEmpty
		self.deliveryRaw = (metaObject?["delivery"] as? String)?.nonEmpty
		self.op = opOverride?.lowercased() ?? args?.op?.lowercased() ?? "start"
	}

	var visualStatus: ToolCardStatus {
		switch statusWord?.lowercased() {
		case "running":
			// The session is still running, but the tool call itself completed.
			// For fire-and-forget ops (steer, respond, start, poll, cancel) a
			// session status of "running" means the action succeeded — show
			// success instead of a spinner so cards don't appear stuck.
			switch op {
			case "wait":
				// wait is expected to block until a terminal/interesting state,
				// so "running" here is unusual — show neutral rather than a
				// misleading spinner.
				return .neutral
			default:
				return .success
			}
		case "waiting_for_input":
			return .warning
		case "cancelled", "expired":
			return .warning
		case "completed":
			return .success
		case "failed":
			return .failure
		default:
			return .neutral
		}
	}

	var subtitle: String? {
		let parts = [statusLabel, interactionLabel, workflowLabel, sessionNameOrID, agentName, model, reasoningLabel]
			.compactMap { $0 }
		if !parts.isEmpty {
			return parts.joined(separator: " • ")
		}
		return assistantText?.singleLineSummary
	}

	var detailText: String? {
		nil
	}

	private var isTerminal: Bool {
		switch statusWord?.lowercased() {
		case "completed", "failed", "cancelled", "expired":
			return true
		default:
			return false
		}
	}

	private var statusLabel: String? {
		guard let statusWord else { return nil }
		return AgentRunMCPSnapshot.Status(rawValue: statusWord)?.displayLabel
	}

	private var interactionLabel: String? {
		guard let interactionKind else { return nil }
		return AgentRunMCPSnapshot.Interaction.Kind(rawValue: interactionKind)?.displayLabel
	}

	private var reasoningLabel: String? {
		reasoningEffort.map { "reasoning \($0)" }
	}

	private var deliveryExplanation: String? {
		guard let deliveryRaw else { return nil }
		return AgentModeViewModel.MCPInstructionDispatch(rawValue: deliveryRaw)?.deliveryExplanation
	}

	private static func sessionID(from resultObject: [String: Any], args: ToolArgsDTOs.AgentRunArgs?) -> UUID? {
		if let rawSessionID = (resultObject["session_id"] as? String)?.nonEmpty {
			return UUID(uuidString: rawSessionID)
		}
		if let rawSessionID = ((resultObject["session"] as? [String: Any])?["id"] as? String)?.nonEmpty {
			return UUID(uuidString: rawSessionID)
		}
		if let rawSessionID = args?.sessionID?.nonEmpty {
			return UUID(uuidString: rawSessionID)
		}
		return nil
	}

	private static func sessionNameOrID(sessionObject: [String: Any]?, args: ToolArgsDTOs.AgentRunArgs?) -> String? {
		if let name = (sessionObject?["name"] as? String)?.nonEmpty {
			return name
		}
		if let id = (sessionObject?["id"] as? String)?.nonEmpty {
			return id
		}
		if let name = args?.sessionName?.nonEmpty {
			return name
		}
		if let id = args?.sessionID?.nonEmpty {
			return id
		}
		return nil
	}

}

private extension String {
	var nonEmpty: String? {
		isEmpty ? nil : self
	}

	var singleLineSummary: String? {
		let normalized = replacingOccurrences(of: "\r", with: " ")
			.replacingOccurrences(of: "\n", with: " ")
			.replacingOccurrences(of: "\t", with: " ")
			.replacingOccurrences(of: "  ", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return normalized.isEmpty ? nil : normalized
	}
}

struct AgentRunResultCard: View {
	let item: AgentChatItem
	@State private var isExpanded = false

	private var args: ToolArgsDTOs.AgentRunArgs? {
		ToolJSON.decodeArgs(ToolArgsDTOs.AgentRunArgs.self, from: item.toolArgsJSON)
	}

	private var op: String {
		args?.op?.lowercased() ?? "start"
	}

	private var resultObject: [String: Any]? {
		ToolJSON.structuredResultObject(from: item.toolResultJSON)
	}

	private var presentation: AgentRunCardPresentation? {
		resultObject.flatMap { AgentRunCardPresentation(resultObject: $0, args: args) }
	}

	private var title: String {
		switch op {
		case "start": return "Start Run"
		case "poll": return "Poll Run"
		case "wait": return "Wait for Run"
		case "cancel": return "Cancel Run"
		case "steer": return "Steer Run"
		case "respond": return "Respond to Run"
		default: return "Agent Run"
		}
	}

	private var status: ToolCardStatus {
		presentation?.visualStatus
			?? ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
	}

	private var hasExpandablePayload: Bool {
		guard let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
			return false
		}
		if let object = ToolRawJSON.object(from: item.toolResultJSON),
			ToolRawJSON.bool(object, key: "summary_only") == true {
			return false
		}
		return true
	}

	var body: some View {
		ToolCardContainer(
			iconName: "play.circle",
			iconColor: ToolCardAccentResolver.color(for: "agent_run"),
			title: title,
			detailText: nil,
			subtitle: presentation?.subtitle,
			status: status,
			timestamp: item.timestamp,
			isExpandable: hasExpandablePayload,
			rawPayloadItemID: item.id,
			isExpanded: $isExpanded
		) {
			ToolMarkdownExpandedContent(item: item)
		}
	}
}

private struct AgentExploreBatchStartPresentation {
	let startedCount: Int
	let runningCount: Int
	let visualStatus: ToolCardStatus

	init?(resultObject: [String: Any]) {
		guard let start = resultObject["start"] as? [String: Any],
			(start["mode"] as? String) == "many" else {
			return nil
		}
		let snapshots = resultObject["snapshots"] as? [[String: Any]] ?? []
		let sessionIDs = resultObject["session_ids"] as? [String] ?? []
		startedCount = (start["started_count"] as? Int) ?? sessionIDs.count
		runningCount = (start["running_session_ids"] as? [String])?.count
			?? snapshots.filter { ($0["status"] as? String) == "running" }.count
		let statuses = snapshots.compactMap { ($0["status"] as? String)?.lowercased() }
		if statuses.contains("failed") {
			visualStatus = .failure
		} else if statuses.contains(where: { ["waiting_for_input", "expired", "cancelled"].contains($0) }) {
			visualStatus = .warning
		} else if !snapshots.isEmpty || startedCount > 0 {
			visualStatus = .success
		} else {
			visualStatus = .neutral
		}
	}

	var subtitle: String {
		"Started \(startedCount) explores • \(runningCount) running"
	}
}

struct AgentExploreResultCard: View {
	let item: AgentChatItem
	@State private var isExpanded = false

	private var args: ToolArgsDTOs.AgentExploreArgs? {
		ToolJSON.decodeArgs(ToolArgsDTOs.AgentExploreArgs.self, from: item.toolArgsJSON)
	}

	private var op: String {
		args?.op?.lowercased() ?? "start"
	}

	private var resultObject: [String: Any]? {
		ToolJSON.structuredResultObject(from: item.toolResultJSON)
	}

	private var presentation: AgentRunCardPresentation? {
		resultObject.flatMap {
			AgentRunCardPresentation(
				resultObject: $0,
				args: nil,
				opOverride: op
			)
		}
	}

	private var batchPresentation: AgentExploreBatchStartPresentation? {
		resultObject.flatMap { AgentExploreBatchStartPresentation(resultObject: $0) }
	}

	private var title: String {
		switch op {
		case "start": return "Start Explore"
		case "poll": return "Poll Explore"
		case "wait": return "Wait for Explore"
		case "cancel": return "Cancel Explore"
		default: return "Agent Explore"
		}
	}

	private var status: ToolCardStatus {
		batchPresentation?.visualStatus
			?? presentation?.visualStatus
			?? ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
	}

	private var hasExpandablePayload: Bool {
		guard let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
			return false
		}
		if let object = ToolRawJSON.object(from: item.toolResultJSON),
			ToolRawJSON.bool(object, key: "summary_only") == true {
			return false
		}
		return true
	}

	var body: some View {
		ToolCardContainer(
			iconName: "magnifyingglass.circle",
			iconColor: ToolCardAccentResolver.color(for: "agent_explore"),
			title: title,
			detailText: nil,
			subtitle: batchPresentation?.subtitle ?? presentation?.subtitle,
			status: status,
			timestamp: item.timestamp,
			isExpandable: hasExpandablePayload,
			rawPayloadItemID: item.id,
			isExpanded: $isExpanded
		) {
			ToolMarkdownExpandedContent(item: item)
		}
	}
}

struct AgentManageResultCardPresentation: Equatable {
	let title: String
	let subtitle: String?
	let status: ToolCardStatus
	let isExpandable: Bool

	static func build(for item: AgentChatItem, payloadSource: ToolResultPayloadSource) -> AgentManageResultCardPresentation {
		let args = ToolJSON.decodeArgs(ToolArgsDTOs.AgentManageArgs.self, from: item.toolArgsJSON)
		let op = args?.op?.lowercased() ?? "list_sessions"
		let raw = payloadSource.preferredPayload
		let resultObject = ToolJSON.structuredResultObject(from: raw)
		let storedPresentation = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)
		let subtitle = subtitle(for: op, resultObject: resultObject, storedPresentation: storedPresentation)
		let status = ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: raw, fallback: storedPresentation?.status ?? .success)
		return AgentManageResultCardPresentation(
			title: title(for: op),
			subtitle: subtitle,
			status: status,
			isExpandable: payloadSource.hasRawPayload || toolResultHasPayload(item)
		)
	}

	private static func title(for op: String) -> String {
		switch op {
		case "list_agents": return "List Agents"
		case "list_sessions": return "List Sessions"
		case "get_log": return "Session Log"
		case "create_session": return "Create Session"
		case "resume_session": return "Resume Session"
		case "stop_session": return "Stop Session"
		case "cleanup_sessions": return "Cleanup Sessions"
		case "list_workflows": return "List Workflows"
		default: return "Agent Manage"
		}
	}

	private static func subtitle(
		for op: String,
		resultObject: [String: Any]?,
		storedPresentation: StoredToolCardPresentation?
	) -> String? {
		guard let resultObject else { return storedPresentation?.inlineSubtitle }
		switch op {
		case "list_agents":
			if let agents = resultObject["agents"] as? [[String: Any]] {
				return "\(agents.count) agents"
			}
		case "list_sessions":
			if let sessions = resultObject["sessions"] as? [[String: Any]] {
				return "\(sessions.count) sessions"
			}
		case "get_log":
			if let returned = intValue(resultObject, keys: ["returned_turn_count", "returnedTurnCount"]),
				let total = intValue(resultObject, keys: ["total_turns", "totalTurns"]) {
				return "\(returned)/\(total) turns"
			}
		case "create_session", "resume_session", "stop_session":
			return (resultObject["name"] as? String)?.nonEmpty ?? storedPresentation?.inlineSubtitle
		case "cleanup_sessions":
			if let subtitle = cleanupSubtitle(from: resultObject) {
				return subtitle
			}
			return storedPresentation?.inlineSubtitle
		case "list_workflows":
			if let workflows = resultObject["workflows"] as? [[String: Any]] {
				return "\(workflows.count) workflows"
			}
		default:
			break
		}
		return storedPresentation?.inlineSubtitle
	}

	private static func cleanupSubtitle(from resultObject: [String: Any]) -> String? {
		let deleted = intValue(resultObject, keys: ["deleted_count", "deletedCount"])
			?? (resultObject["deleted_sessions"] as? [Any])?.count
			?? (resultObject["deletedSessions"] as? [Any])?.count
		let skipped = intValue(resultObject, keys: ["skipped_count", "skippedCount"])
			?? (resultObject["skipped_sessions"] as? [Any])?.count
			?? (resultObject["skippedSessions"] as? [Any])?.count
		if let deleted, let skipped {
			return "\(deleted) deleted, \(skipped) skipped"
		}
		if let deleted {
			return "\(deleted) deleted"
		}
		if let skipped {
			return "\(skipped) skipped"
		}
		return nil
	}

	private static func intValue(_ object: [String: Any], keys: [String]) -> Int? {
		for key in keys {
			if let value = ToolRawJSON.int(object, key: key) {
				return value
			}
		}
		return nil
	}
}

struct AgentManageResultCard: View {
	let item: AgentChatItem
	@Environment(\.agentRawToolResultPayloadResolver) private var rawToolResultPayloadResolver
	@Environment(\.agentRawToolResultPayloadRenderRevision) private var rawPayloadRenderRevision
	@State private var isExpanded = false

	private var payloadSource: ToolResultPayloadSource {
		ToolJSON.resultPayloadSource(
			for: item,
			rawPayload: rawToolResultPayloadResolver?(item.id)
		)
	}

	private var presentation: AgentManageResultCardPresentation {
		_ = rawPayloadRenderRevision
		return AgentManageResultCardPresentation.build(for: item, payloadSource: payloadSource)
	}

	var body: some View {
		ToolCardContainer(
			iconName: "tray.full",
			iconColor: ToolCardAccentResolver.color(for: "agent_manage"),
			title: presentation.title,
			detailText: nil,
			subtitle: presentation.subtitle,
			status: presentation.status,
			timestamp: item.timestamp,
			isExpandable: presentation.isExpandable,
			rawPayloadItemID: item.id,
			isExpanded: $isExpanded
		) {
			ToolMarkdownExpandedContent(item: item)
		}
	}
}
