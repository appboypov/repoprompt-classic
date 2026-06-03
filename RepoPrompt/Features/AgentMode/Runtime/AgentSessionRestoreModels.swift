import Foundation

struct AgentSessionIndexEntry: Identifiable, Equatable, Sendable {
	let id: UUID
	let tabID: UUID
	var name: String
	var lastUserMessageAt: Date?
	var savedAt: Date
	var lastRunStateRaw: String?
	var itemCount: Int
	var agentKindRaw: String?
	var agentModelRaw: String?
	var agentReasoningEffortRaw: String?
	var autoEditEnabled: Bool
	var parentSessionID: UUID?
	var hasUnknownConversationContent: Bool
	var isMCPOriginated: Bool
}

struct AgentSessionSidebarBuildRequest: Sendable {
	let workspace: WorkspaceModel
	let tabNameByID: [UUID: String]
	let validTabIDs: Set<UUID>
	let boundSessionIDByTabID: [UUID: UUID]
	let prioritizedTabID: UUID?

	init(
		workspace: WorkspaceModel,
		tabNameByID: [UUID: String],
		validTabIDs: Set<UUID>,
		boundSessionIDByTabID: [UUID: UUID] = [:],
		prioritizedTabID: UUID? = nil
	) {
		self.workspace = workspace
		self.tabNameByID = tabNameByID
		self.validTabIDs = validTabIDs
		self.boundSessionIDByTabID = boundSessionIDByTabID
		self.prioritizedTabID = prioritizedTabID
	}
}

struct AgentSessionSidebarBuildBatch: Sendable {
	let entriesBySessionID: [UUID: AgentSessionIndexEntry]
	let preferredSessionIDByTabID: [UUID: UUID]
}

struct AgentSessionSidebarBuildResult: Sendable {
	let entriesBySessionID: [UUID: AgentSessionIndexEntry]
	let preferredSessionIDByTabID: [UUID: UUID]
}

struct AgentSessionHydrationRequest: Sendable {
	let workspace: WorkspaceModel
	let tabID: UUID
	let sessionID: UUID
	let resolvedDisplayName: String
	let hasPendingQuestionUI: Bool
	let transcriptViewportState: AgentTranscriptViewportState
	let isCompressedHistoryRevealed: Bool
	let initialPerformanceSnapshot: AgentTranscriptPerformanceSnapshot
}

struct AgentSessionHydrationPayload: Sendable {
	let sessionID: UUID
	let persistedSession: AgentSession
	let canonicalLiveItems: [AgentChatItem]
	let transcript: AgentTranscript
	let builtPresentation: AgentModeViewModel.BuiltTranscriptPresentation
	let normalizedRunState: AgentSessionRunState
	let normalizedSelection: AgentModelCatalog.NormalizedAgentSelection
	let lastUserMessageAt: Date?
	let restoredIndexEntry: AgentSessionIndexEntry
	let needsReloadMigrationSave: Bool
}
