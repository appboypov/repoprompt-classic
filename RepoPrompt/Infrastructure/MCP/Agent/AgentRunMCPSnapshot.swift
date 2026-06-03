import Foundation
import MCP

struct AgentRunMCPSnapshot: Sendable, Equatable {
	enum Status: String, Sendable, Equatable {
		case running
		case waitingForInput = "waiting_for_input"
		case completed
		case failed
		case cancelled
		case expired

		var isTerminal: Bool {
			switch self {
			case .completed, .failed, .cancelled, .expired:
				return true
			case .running, .waitingForInput:
				return false
			}
		}
	}

	struct Interaction: Sendable, Equatable {
		enum Kind: String, Sendable, Equatable {
			case instruction
			case question
			case userInput = "user_input"
			case approval
			case mcpElicitation = "mcp_elicitation"
		}

		/// Indicates the expected shape of a valid response.
		enum ResponseType: String, Sendable, Equatable {
			case text
			case choice
			case structured
			case decision
			case elicitation
		}

		struct Option: Sendable, Equatable {
			let label: String
			let description: String?

			func asObject() -> [String: Value] {
				[
					"label": .string(label),
					"description": AgentMCPToolHelpers.stringOrNull(description)
				]
			}
		}

		/// Generic input field, used for `user_input` interactions (replaces `Question`).
		struct Field: Sendable, Equatable {
			let id: String
			let header: String?
			let prompt: String
			let context: String?
			let isSecret: Bool
			let allowsOther: Bool
			let allowsMultiple: Bool?
			let allowsCustom: Bool?
			let emitAllowsOther: Bool
			let options: [Option]

			init(
				id: String,
				header: String?,
				prompt: String,
				context: String?,
				isSecret: Bool,
				allowsOther: Bool,
				allowsMultiple: Bool?,
				allowsCustom: Bool?,
				emitAllowsOther: Bool = true,
				options: [Option]
			) {
				self.id = id
				self.header = header
				self.prompt = prompt
				self.context = context
				self.isSecret = isSecret
				self.allowsOther = allowsOther
				self.allowsMultiple = allowsMultiple
				self.allowsCustom = allowsCustom
				self.emitAllowsOther = emitAllowsOther
				self.options = options
			}

			func asObject() -> [String: Value] {
				var obj: [String: Value] = [
					"id": .string(id),
					"header": AgentMCPToolHelpers.stringOrNull(header),
					"prompt": .string(prompt),
					"is_secret": .bool(isSecret),
					"options": .array(options.map { .object($0.asObject()) })
				]
				if emitAllowsOther {
					obj["allows_other"] = .bool(allowsOther)
				}
				if let context {
					obj["context"] = .string(context)
				}
				if let allowsMultiple {
					obj["allows_multiple"] = .bool(allowsMultiple)
				}
				if let allowsCustom {
					obj["allows_custom"] = .bool(allowsCustom)
				}
				return obj
			}
		}

		struct Detail: Sendable, Equatable {
			let label: String
			let value: String
			let isCode: Bool

			func asObject() -> [String: Value] {
				[
					"label": .string(label),
					"value": .string(value),
					"is_code": .bool(isCode)
				]
			}
		}

		let id: UUID
		let kind: Kind
		let responseType: ResponseType
		let title: String?
		let prompt: String?
		let context: String?
		let allowsMultiple: Bool?
		let options: [Option]
		let fields: [Field]
		let details: [Detail]

		func asObject() -> [String: Value] {
			var obj: [String: Value] = [
				"id": .string(id.uuidString),
				"kind": .string(kind.rawValue),
				"response_type": .string(responseType.rawValue),
				"title": Self.stringOrNull(title),
				"prompt": Self.stringOrNull(prompt),
			]
			if let context {
				obj["context"] = .string(context)
			}
			if let allowsMultiple {
				obj["allows_multiple"] = .bool(allowsMultiple)
			}
			if !options.isEmpty {
				obj["options"] = .array(options.map { .object($0.asObject()) })
			}
			if !fields.isEmpty {
				obj["fields"] = .array(fields.map { .object($0.asObject()) })
			}
			if !details.isEmpty {
				obj["details"] = .array(details.map { .object($0.asObject()) })
			}
			return obj
		}

		private static func stringOrNull(_ value: String?) -> Value {
			AgentMCPToolHelpers.stringOrNull(value)
		}
	}

	// MARK: - Failure reason classification

	enum FailureReason: String, Sendable, Equatable {
		case processCrash = "process_crash"
		case timeout
		case agentError = "agent_error"
		case cancelled

		var displayLabel: String {
			switch self {
			case .processCrash: return "Process Crash"
			case .timeout: return "Timeout"
			case .agentError: return "Agent Error"
			case .cancelled: return "Cancelled"
			}
		}

		static func classify(status: Status, statusText: String?) -> FailureReason? {
			if status == .cancelled { return .cancelled }
			guard status == .failed else { return nil }
			guard let text = statusText?.lowercased(), !text.isEmpty else { return .agentError }

			let cancelPatterns = ["cancelled", "canceled", "interrupted", "aborted"]
			if cancelPatterns.contains(where: { text.contains($0) }) { return .cancelled }

			let timeoutPatterns = ["timed out", "timeout", "deadline exceeded", "took too long"]
			if timeoutPatterns.contains(where: { text.contains($0) }) { return .timeout }

			let crashPatterns = [
				"process not running", "transport closed", "connection closed",
				"broken pipe", "crashed", "crash", "exited unexpectedly",
				"terminated unexpectedly", "protocol error", "decode error", "spawn failed"
			]
			if crashPatterns.contains(where: { text.contains($0) }) { return .processCrash }

			return .agentError
		}
	}

	// MARK: - Snapshot properties

	let sessionID: UUID
	let tabID: UUID?
	let sessionName: String?

	let agentRaw: String?
	let agentDisplayName: String?
	let modelRaw: String?
	let reasoningEffortRaw: String?
	let status: Status
	let statusText: String?
	/// Latest assistant text. Serialized as `preview` while the run is active and as
	/// `output` once the run reaches a terminal state.
	let latestAssistantPreview: String?
	let interaction: Interaction?
	let transcriptItemCount: Int
	let updatedAt: Date
	let parentSessionID: UUID?
	let failureReason: FailureReason?

	var isActionableForMCPWait: Bool {
		interaction != nil || status == .waitingForInput || status.isTerminal
	}

	func asObject() -> [String: Value] {
		var obj: [String: Value] = [
			"session_id": .string(sessionID.uuidString),
			"status": .string(status.rawValue),
			"transcript_item_count": .int(transcriptItemCount),
			"updated_at": .string(Self.timestampFormatter.string(from: updatedAt))
		]
		if let statusText, !statusText.isEmpty {
			obj["status_text"] = .string(statusText)
		}
		if let latestAssistantPreview, !latestAssistantPreview.isEmpty {
			obj["assistant_text"] = .string(latestAssistantPreview)
		}
		if let interaction {
			obj["interaction"] = .object(interaction.asObject())
			obj["interaction_id"] = .string(interaction.id.uuidString)
		}

		if let failureReason {
			obj["failure_reason"] = .string(failureReason.rawValue)
		}

		var sessionObj: [String: Value] = [
			"id": .string(sessionID.uuidString),
			"name": Self.stringOrNull(sessionName)
		]
		if let tabID {
			sessionObj["context_id"] = .string(tabID.uuidString)
		}
		if let parentSessionID {
			sessionObj["parent_session_id"] = .string(parentSessionID.uuidString)
		}
		obj["session"] = .object(sessionObj)

		if agentRaw != nil || modelRaw != nil {
			obj["agent"] = .object([
				"id": Self.stringOrNull(agentRaw),
				"name": Self.stringOrNull(agentDisplayName),
				"model": Self.stringOrNull(modelRaw),
				"reasoning_effort": Self.stringOrNull(reasoningEffortRaw)
			])
		}

		return obj
	}

	func toValue() -> Value {
		.object(asObject())
	}

	static func expired(sessionID: UUID) -> AgentRunMCPSnapshot {
		AgentRunMCPSnapshot(
			sessionID: sessionID,
			tabID: nil,
			sessionName: nil,
			agentRaw: nil,
			agentDisplayName: nil,
			modelRaw: nil,
			reasoningEffortRaw: nil,
			status: .expired,
			statusText: "This session control handle is no longer available. Start a new run or use a more recent session ID.",
			latestAssistantPreview: nil,
			interaction: nil,
			transcriptItemCount: 0,
			updatedAt: Date(),
			parentSessionID: nil,
			failureReason: nil
		)
	}

	private static func stringOrNull(_ value: String?) -> Value {
		AgentMCPToolHelpers.stringOrNull(value)
	}

	private static let timestampFormatter = AgentMCPToolHelpers.timestampFormatter
}

// MARK: - Centralized Status & Delivery Display Text
// SEARCH-HELPER: Status labels, delivery wording, interaction kind display, agent control display text
//
// Related:
// - UI card presentation: Views/AgentMode/ToolCards/AgentControlToolCards.swift
// - MCP output formatter:  Services/MCP/ToolOutputFormatter.swift (formatAgentRun/formatAgentManage)

extension AgentRunMCPSnapshot.Status {

	/// Human-readable label for display in UI cards and formatted tool output.
	var displayLabel: String {
		switch self {
		case .running:
			return "Still Running"
		case .waitingForInput:
			return "Needs Input"
		case .completed:
			return "Run Complete"
		case .failed:
			return "Run Failed"
		case .cancelled:
			return "Run Cancelled"
		case .expired:
			return "Run Expired"
		}
	}

	/// Title-cased label suitable for MCP text output (e.g. "Waiting For Input").
	var prettifiedLabel: String {
		rawValue
			.replacingOccurrences(of: "_", with: " ")
			.split(separator: " ")
			.map { word in
				guard let first = word.first else { return "" }
				return String(first).uppercased() + word.dropFirst().lowercased()
			}
			.joined(separator: " ")
	}
}

extension AgentRunMCPSnapshot.Interaction.Kind {

	/// Human-readable label for interaction kind.
	var displayLabel: String {
		switch self {
		case .approval:
			return "approval needed"
		case .question:
			return "question"
		case .instruction:
			return "instruction"
		case .userInput:
			return "input needed"
		case .mcpElicitation:
			return "MCP elicitation"
		}
	}
}

extension AgentModeViewModel.MCPInstructionDispatch {

	/// Human-readable explanation of how an instruction was delivered.
	var deliveryExplanation: String? {
		switch self {
		case .startedRun:
			return "Started a new run."
		case .deliveredIntoWaitingContinuation:
			return "Delivered immediately into the pending prompt."
		case .queuedFollowUp:
			return "Queued as the next turn once the active run reaches a safe handoff point."
		case .dispatchedCodexTurn:
			return "Delivered to the active Codex run."
		case .queuedClaudeInterrupt:
			return "Queued for Claude and requested an interrupt at the next decision point."
		case .queuedACPInterrupt:
			return "Queued for ACP and will cancel the active prompt before sending steering."
		}
	}
}
