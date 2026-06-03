import Foundation

// SEARCH-HELPER: model_id, compound identifier, agent+model, one-shot start, stable ID
// Related:
// - AgentModelCatalog.swift (discovery APIs that produce model_id values)
// - AgentMCPSelectionResolver.swift (MCP parsing layer that consumes model_id)
// - AgentRunMCPToolService.swift / AgentManageMCPToolService.swift (MCP entry points)

/// A stable compound identifier for an agent+model combination.
///
/// Format: `<agentRaw>:<modelRaw>`
///
/// The first colon is the delimiter. Model raw values may contain colons.
/// Agent raw values must not contain colons.
///
/// Examples:
/// - `codexExec:default`
/// - `codexExec:gpt-5.4-high`
/// - `claudeCode:opus[1m]`
/// - `claudeCode:sonnet`
///
/// These identifiers are produced by `agent_manage.list_agents` and accepted by
/// `agent_run.start`, `agent_manage.create_session`, and `agent_manage.resume_session`.
struct AgentModelSelectionID: Sendable, Equatable, Hashable, CustomStringConvertible {
	let agentRaw: String
	let modelRaw: String

	/// Creates a selection ID from an agent raw value and a model raw value.
	/// Both must be non-empty after trimming. Agent raw must not contain `:`.
	init(agentRaw: String, modelRaw: String) {
		let trimmedAgent = agentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedModel = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
		precondition(!trimmedAgent.isEmpty, "agentRaw must be non-empty")
		precondition(!trimmedModel.isEmpty, "modelRaw must be non-empty")
		precondition(!trimmedAgent.contains(":"), "agentRaw must not contain ':'")
		self.agentRaw = trimmedAgent
		self.modelRaw = trimmedModel
	}

	/// The encoded string representation: `<agentRaw>:<modelRaw>`
	var rawValue: String {
		"\(agentRaw):\(modelRaw)"
	}

	var description: String { rawValue }

	/// Parses a model_id string into its components.
	/// Accepts both the current short format (`agent:model`) and the legacy
	/// versioned format (`agent-selection:v1:agent:model`) for backward compatibility.
	/// Returns `nil` if the format is invalid.
	static func parse(_ raw: String) -> AgentModelSelectionID? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }

		// Legacy format: agent-selection:v1:<agent>:<model>
		if trimmed.hasPrefix("agent-selection:") {
			return parseLegacy(trimmed)
		}

		// Short format: <agent>:<model> — split on first colon only
		guard let colonIndex = trimmed.firstIndex(of: ":") else { return nil }
		let agent = String(trimmed[trimmed.startIndex..<colonIndex])
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let model = String(trimmed[trimmed.index(after: colonIndex)...])
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !agent.isEmpty, !model.isEmpty else { return nil }

		return AgentModelSelectionID(agentRaw: agent, modelRaw: model)
	}

	/// Parses the legacy `agent-selection:v1:<encoded-agent>:<encoded-model>` format.
	private static func parseLegacy(_ raw: String) -> AgentModelSelectionID? {
		let segments = raw.split(separator: ":", maxSplits: 3).map(String.init)
		guard segments.count == 4,
				segments[0] == "agent-selection",
				segments[1] == "v1" else { return nil }

		let agent = segments[2].removingPercentEncoding ?? segments[2]
		let model = segments[3].removingPercentEncoding ?? segments[3]
		guard !agent.isEmpty, !model.isEmpty else { return nil }

		return AgentModelSelectionID(agentRaw: agent, modelRaw: model)
	}
}
