import SwiftUI

// MARK: - Agent Workflow

/// Built-in workflow templates that wrap user input with structured prompts for agent mode.
/// Each case maps to a corresponding `ClaudeCodeCommands.rp*Agent` template.
public enum AgentWorkflow: String, Codable, CaseIterable, Sendable, Identifiable {
	case build, review, refactor, investigate, oracleExport, orchestrate, optimize, deepPlan

	public var id: String { rawValue }

	public var displayName: String {
		switch self {
		case .build: return "Plan & Build"
		case .review: return "Review"
		case .refactor: return "Refactor"
		case .investigate: return "Investigate"
		case .oracleExport: return "ChatGPT Export"
		case .orchestrate: return "Orchestrate"
		case .optimize: return "Optimize"
		case .deepPlan: return "Deep Plan"
		}
	}

	var iconName: String {
		switch self {
		case .build: return "hammer.fill"
		case .review: return "eye.fill"
		case .refactor: return "arrow.triangle.2.circlepath"
		case .investigate: return "magnifyingglass"
		case .oracleExport: return "square.and.arrow.up"
		case .orchestrate: return "arrow.triangle.branch"
		case .optimize: return "speedometer"
		case .deepPlan: return "text.book.closed.fill"
		}
	}

	var tooltipText: String {
		switch self {
		case .build: return "Deep-research, plan, and implement complex tasks"
		case .review: return "Thorough code review across branches and diffs"
		case .refactor: return "Analyze and improve code organization"
		case .investigate: return "Hypothesis-driven research with evidence gathering"
		case .oracleExport: return "Export codebase context for ChatGPT analysis"
		case .orchestrate: return "Plan, decompose, and delegate tasks across multiple agents"
		case .optimize: return "Instrument, baseline, and iteratively optimize a target metric"
		case .deepPlan: return "Deeply research and shape a polished plan document"
		}
	}

	/// Detailed description of what the workflow does, shown in the picker popover.
	var descriptionText: String {
		switch self {
		case .build:
			return "Researches the code, makes a plan, and implements the change step by step."
		case .review:
			return "Deeply reviews the code for subtle bugs, regressions, risks, and missed edge cases."
		case .refactor:
			return "Cleans up code structure while keeping behavior the same."
		case .investigate:
			return "Digs into bugs, crashes, security concerns, or research questions and reports the evidence."
		case .oracleExport:
			return "Packages the right code and context into a prompt you can send to ChatGPT."
		case .orchestrate:
			return "Breaks a complex request into smaller tasks, sends agents to do the work, and checks each result."
		case .optimize:
			return "Finds what to measure, adds metrics, tries improvements, and uses evidence to keep iterating."
		case .deepPlan:
			return "Researches the code, asks how hands-on you want to be, and writes a clear implementation plan."
		}
	}

	/// Compact guidance shown beside the workflow pill after the workflow is selected.
	var composerGuidanceText: String {
		switch self {
		case .build:
			return "Describe your task — the agent will research, plan with oracle, and implement."
		case .review:
			return "Describe what to review — the agent will surface issues across branches."
		case .refactor:
			return "Describe code to clean up — the agent will analyze, plan, then dispatch agents to refactor."
		case .investigate:
			return "Describe a bug or question — the agent will research and deliver a report."
		case .oracleExport:
			return "Describe your task — the agent will build a rich prompt for ChatGPT."
		case .orchestrate:
			return "Describe a complex task — the agent will plan, decompose, and delegate to sub-agents."
		case .optimize:
			return "Describe what to optimize and how to measure it — the agent will instrument, baseline, and iterate."
		case .deepPlan:
			return "Describe what you want planned — the agent will ask how involved you want to be, then research and write a polished plan."
		}
	}

	var accentColor: Color {
		switch self {
		case .build: return .blue
		case .review: return .purple
		case .refactor: return .orange
		case .investigate: return .teal
		case .oracleExport: return .indigo
		case .orchestrate: return .green
		case .optimize: return .red
		case .deepPlan: return .cyan
		}
	}

	/// Workflow metadata for suggested task-label affinity.
	/// `agent_run.start` itself defaults omitted `model_id` to the Pair role.
	var defaultTaskLabelKind: AgentModelCatalog.TaskLabelKind? {
		switch self {
		case .build: return .engineer
		case .refactor: return .engineer
		case .review: return .design
		case .investigate: return .design
		case .oracleExport: return .explore
		case .orchestrate: return .pair
		case .optimize: return .pair
		case .deepPlan: return .pair
		}
	}

	/// The full agent-variant template string from `ClaudeCodeCommands`.
	var template: String {
		template(includeSessionCleanupGuidance: true)
	}

	func template(includeSessionCleanupGuidance: Bool) -> String {
		switch self {
		case .build: return ClaudeCodeCommands.rpBuildAgent
		case .review: return ClaudeCodeCommands.rpReviewAgent
		case .refactor: return ClaudeCodeCommands.rpRefactorAgent(includeSessionCleanupGuidance: includeSessionCleanupGuidance)
		case .investigate: return ClaudeCodeCommands.rpInvestigateAgent(includeSessionCleanupGuidance: includeSessionCleanupGuidance)
		case .oracleExport: return ClaudeCodeCommands.rpOracleExportAgent
		case .orchestrate: return ClaudeCodeCommands.rpOrchestrateAgent(includeSessionCleanupGuidance: includeSessionCleanupGuidance)
		case .optimize: return ClaudeCodeCommands.rpOptimizeAgent(includeSessionCleanupGuidance: includeSessionCleanupGuidance)
		case .deepPlan: return ClaudeCodeCommands.rpDeepPlanAgent(includeSessionCleanupGuidance: includeSessionCleanupGuidance)
		}
	}

	/// Wraps user text by stripping YAML frontmatter from the template
	/// and replacing `$ARGUMENTS` with the provided text.
	func wrapUserText(_ text: String, includeSessionCleanupGuidance: Bool = true) -> String {
		AgentWorkflowDefinition.wrap(template: template(includeSessionCleanupGuidance: includeSessionCleanupGuidance), userText: text)
	}

	/// Creates an `AgentWorkflowDefinition` for this built-in workflow.
	var definition: AgentWorkflowDefinition {
		AgentWorkflowDefinition(builtIn: self)
	}

	static let displayOrder: [AgentWorkflow] = [.orchestrate, .deepPlan, .optimize, .build, .review, .refactor, .investigate, .oracleExport]

	static func builtInSections(hiddenBuiltInIDs: Set<String>) -> BuiltInSections {
		let visibleBuiltIns = displayOrder
			.filter { !hiddenBuiltInIDs.contains($0.rawValue) }
			.map(\.definition)
		let hiddenBuiltIns = displayOrder
			.filter { hiddenBuiltInIDs.contains($0.rawValue) }
			.map(\.definition)
		return BuiltInSections(
			visibleBuiltIns: visibleBuiltIns,
			hiddenBuiltIns: hiddenBuiltIns
		)
	}

	struct BuiltInSections: Equatable {
		let visibleBuiltIns: [AgentWorkflowDefinition]
		let hiddenBuiltIns: [AgentWorkflowDefinition]
	}
}

// MARK: - Agent Workflow Definition

/// Unified wrapper representing either a built-in or custom workflow.
/// Backward-compatible with legacy persisted sessions that stored `AgentWorkflow` raw strings.
///
/// Related:
/// - Built-in catalog: `AgentWorkflow` enum (above)
/// - Storage: `AgentWorkflowStore` loads custom workflows from `~/Library/Application Support/RepoPrompt/Workflows/`
/// - UI: `AgentWorkflowsPopoverView` displays both built-in and custom workflows
public struct AgentWorkflowDefinition: Sendable, Identifiable, Equatable, Hashable {

	// MARK: Source

	public enum Source: Sendable, Equatable, Hashable {
		case builtIn(AgentWorkflow)
		case custom(id: UUID)
	}

	public let source: Source

	// MARK: Display metadata

	public var displayName: String
	public var iconName: String
	public var accentColorHex: String?
	public var tooltipText: String?
	public var descriptionText: String?

	/// Runtime-only template body (not persisted). Present when selected from the picker.
	public var template: String?

	// MARK: Identifiable

	public var id: String {
		switch source {
		case .builtIn(let workflow): return "builtin-\(workflow.rawValue)"
		case .custom(let uuid): return "custom-\(uuid.uuidString)"
		}
	}

	// MARK: Convenience

	public var isBuiltIn: Bool {
		if case .builtIn = source { return true }
		return false
	}

	public var isCustom: Bool {
		if case .custom = source { return true }
		return false
	}

	public var builtInWorkflow: AgentWorkflow? {
		if case .builtIn(let w) = source { return w }
		return nil
	}

	public var customID: UUID? {
		if case .custom(let id) = source { return id }
		return nil
	}

	/// Accent color resolved from hex string or built-in enum color.
	public var accentColor: Color {
		if let builtIn = builtInWorkflow {
			return builtIn.accentColor
		}
		if let hex = accentColorHex {
			return Color(hex: hex) ?? .secondary
		}
		return .secondary
	}

	// MARK: Init

	/// Create from a built-in workflow (delegates display metadata to the enum).
	public init(builtIn workflow: AgentWorkflow) {
		self.source = .builtIn(workflow)
		self.displayName = workflow.displayName
		self.iconName = workflow.iconName
		self.tooltipText = workflow.tooltipText
		self.descriptionText = workflow.descriptionText
		self.accentColorHex = nil
		self.template = workflow.template
	}

	/// Create from a custom workflow loaded from disk.
	public init(
		customID: UUID,
		displayName: String,
		iconName: String = "gearshape.fill",
		accentColorHex: String? = nil,
		tooltipText: String? = nil,
		descriptionText: String? = nil,
		template: String? = nil
	) {
		self.source = .custom(id: customID)
		self.displayName = displayName
		self.iconName = iconName
		self.accentColorHex = accentColorHex
		self.tooltipText = tooltipText
		self.descriptionText = descriptionText
		self.template = template
	}

	// MARK: Template wrapping (shared logic)

	/// Strips YAML frontmatter (`--- ... ---`) from a template string.
	public static func stripYAMLFrontmatter(_ text: String) -> String {
		var body = text
		if body.hasPrefix("---") {
			let searchRange = body.index(body.startIndex, offsetBy: 3)..<body.endIndex
			if let closingRange = body.range(of: "\n---", range: searchRange) {
				body = String(body[closingRange.upperBound...])
					.trimmingCharacters(in: .newlines)
			}
		}
		return body
	}

	/// Wraps user text by stripping YAML frontmatter and replacing `$ARGUMENTS`.
	public static func wrap(template: String, userText: String) -> String {
		var body = stripYAMLFrontmatter(template)
		body = body.replacingOccurrences(of: "$ARGUMENTS", with: userText)
		return body
	}

	/// Wraps user text using this definition's template. Falls back to raw text if no template.
	public func wrapUserText(
		_ text: String,
		includeBuiltInSessionCleanupGuidance: Bool = true
	) -> String {
		if let builtInWorkflow {
			return builtInWorkflow.wrapUserText(text, includeSessionCleanupGuidance: includeBuiltInSessionCleanupGuidance)
		}
		guard let template else { return text }
		return Self.wrap(template: template, userText: text)
	}
}

// MARK: - AgentWorkflowDefinition + Codable

extension AgentWorkflowDefinition: Codable {

	private enum CodingKeys: String, CodingKey {
		case kind, customID, displayName, iconName, accentColorHex, tooltipText, descriptionText
	}

	/// Decodes from either a legacy raw-value string (built-in) or a keyed object (custom).
	public init(from decoder: Decoder) throws {
		// Try legacy single-string format first (backward compat with existing sessions)
		if let singleValue = try? decoder.singleValueContainer(),
		let rawValue = try? singleValue.decode(String.self),
		let builtIn = AgentWorkflow(rawValue: rawValue) {
			self.init(builtIn: builtIn)
			return
		}

		// Decode keyed object (custom workflow)
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let kind = try container.decode(String.self, forKey: .kind)

		if kind == "builtIn",
		let name = try container.decodeIfPresent(String.self, forKey: .displayName),
		let builtIn = AgentWorkflow.allCases.first(where: { $0.displayName == name }) ?? AgentWorkflow.allCases.first {
			self.init(builtIn: builtIn)
			return
		}

		let customID = try container.decode(UUID.self, forKey: .customID)
		let displayName = try container.decode(String.self, forKey: .displayName)
		let iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? "gearshape.fill"
		let accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex)
		let tooltipText = try container.decodeIfPresent(String.self, forKey: .tooltipText)
		let descriptionText = try container.decodeIfPresent(String.self, forKey: .descriptionText)

		self.init(
			customID: customID,
			displayName: displayName,
			iconName: iconName,
			accentColorHex: accentColorHex,
			tooltipText: tooltipText,
			descriptionText: descriptionText,
			template: nil // Template not persisted
		)
	}

	/// Encodes built-in workflows as single raw-value strings (preserves legacy format).
	/// Custom workflows encode as keyed objects with metadata snapshot.
	public func encode(to encoder: Encoder) throws {
		if case .builtIn(let workflow) = source {
			var container = encoder.singleValueContainer()
			try container.encode(workflow.rawValue)
			return
		}

		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode("custom", forKey: .kind)
		try container.encode(customID, forKey: .customID)
		try container.encode(displayName, forKey: .displayName)
		try container.encode(iconName, forKey: .iconName)
		try container.encodeIfPresent(accentColorHex, forKey: .accentColorHex)
		try container.encodeIfPresent(tooltipText, forKey: .tooltipText)
		try container.encodeIfPresent(descriptionText, forKey: .descriptionText)
	}
}

// MARK: - Color hex helper

extension Color {
	/// Parses a hex color string (e.g. "#3B82F6" or "3B82F6") into a Color.
	init?(hex: String) {
		var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
		if hexSanitized.hasPrefix("#") { hexSanitized.removeFirst() }
		guard hexSanitized.count == 6, let rgb = UInt64(hexSanitized, radix: 16) else { return nil }
		let r = Double((rgb >> 16) & 0xFF) / 255.0
		let g = Double((rgb >> 8) & 0xFF) / 255.0
		let b = Double(rgb & 0xFF) / 255.0
		self.init(red: r, green: g, blue: b)
	}
}
