import Foundation

struct AgentModelOption: Identifiable, Hashable, Sendable {
	let rawValue: String
	let displayName: String
	let description: String?
	let isPlaceholderDefault: Bool
	let isProviderDefault: Bool
	let supportedReasoningEfforts: [CodexReasoningEffort]
	let defaultReasoningEffort: CodexReasoningEffort?

	init(
		rawValue: String,
		displayName: String,
		description: String?,
		isPlaceholderDefault: Bool,
		isProviderDefault: Bool,
		supportedReasoningEfforts: [CodexReasoningEffort] = [],
		defaultReasoningEffort: CodexReasoningEffort? = nil
	) {
		self.rawValue = rawValue
		self.displayName = displayName
		self.description = description
		self.isPlaceholderDefault = isPlaceholderDefault
		self.isProviderDefault = isProviderDefault
		self.supportedReasoningEfforts = supportedReasoningEfforts
		self.defaultReasoningEffort = defaultReasoningEffort
	}

	init(
		rawValue: String,
		displayName: String,
		description: String?,
		isDefault: Bool,
		supportedReasoningEfforts: [CodexReasoningEffort] = [],
		defaultReasoningEffort: CodexReasoningEffort? = nil
	) {
		let isPlaceholder =
			rawValue.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
		self.rawValue = rawValue
		self.displayName = displayName
		self.description = description
		self.isPlaceholderDefault = isPlaceholder && isDefault
		self.isProviderDefault = !isPlaceholder && isDefault
		self.supportedReasoningEfforts = supportedReasoningEfforts
		self.defaultReasoningEffort = defaultReasoningEffort
	}

	var isDefault: Bool {
		isPlaceholderDefault || isProviderDefault
	}

	var id: String { rawValue }
}
