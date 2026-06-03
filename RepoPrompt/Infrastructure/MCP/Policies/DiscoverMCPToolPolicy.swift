import Foundation

/// MCP tool policy for discovery agent runs.
/// Controls which tools are restricted and which special tools are granted.
enum DiscoverMCPToolPolicy {
	/// Discovery agents should explore and plan, not make changes or manage state.
	static let restrictedCapabilities: Set<MCPToolCapability> = [
		.conversationSend,
		.agentConversationSend,
		.conversationHelper,
		.fileContentEdit,
		.fileManagement,
		.routingAdvanced,
		.discovery,
		.appSettings,

		.agentExternalControl,
		.agentExploreControl,
		.agentReasoningControl,
		.agentSessionControl
	]

	static let restrictedTools: Set<String> = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

	/// Tools granted to discovery runs (from MCPPolicyGatedTools).
	/// These are conditionally granted based on user settings (allowClarifyingQuestions).
	static let grantedCapabilities: Set<MCPToolCapability> = [
		.userInteraction
	]

	static let grantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grantedCapabilities)
}
