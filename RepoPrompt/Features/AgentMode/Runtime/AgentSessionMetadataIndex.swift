import Foundation

struct AgentSessionMetadataIndex: Codable, Equatable, Sendable {
	static let currentSchemaVersion = 1

	var schemaVersion: Int
	var generatedAt: Date
	var lastReconciledAt: Date?
	var entries: [AgentSessionMetadataRecord]
	var quarantinedFiles: [AgentSessionMetadataQuarantineRecord]

	init(
		schemaVersion: Int = Self.currentSchemaVersion,
		generatedAt: Date = Date(),
		lastReconciledAt: Date? = nil,
		entries: [AgentSessionMetadataRecord] = [],
		quarantinedFiles: [AgentSessionMetadataQuarantineRecord] = []
	) {
		self.schemaVersion = schemaVersion
		self.generatedAt = generatedAt
		self.lastReconciledAt = lastReconciledAt
		self.entries = entries
		self.quarantinedFiles = quarantinedFiles
	}

	enum CodingKeys: String, CodingKey {
		case schemaVersion
		case generatedAt
		case lastReconciledAt
		case entries
		case quarantinedFiles
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? -1
		generatedAt = try container.decode(Date.self, forKey: .generatedAt)
		lastReconciledAt = try container.decodeIfPresent(Date.self, forKey: .lastReconciledAt)
		entries = try container.decodeIfPresent([AgentSessionMetadataRecord].self, forKey: .entries) ?? []
		quarantinedFiles = try container.decodeIfPresent([AgentSessionMetadataQuarantineRecord].self, forKey: .quarantinedFiles) ?? []
	}
}

struct AgentSessionMetadataRecord: Codable, Equatable, Identifiable, Sendable {
	var id: UUID
	var filename: String
	var workspaceID: UUID?
	var composeTabID: UUID?
	var name: String
	var savedAt: Date
	var lastUserMessageAt: Date?
	var itemCount: Int
	var transcriptProjectionCounts: AgentTranscriptProjectionCounts?
	var hasUnknownConversationContent: Bool
	var agentKindRaw: String?
	var agentModelRaw: String?
	var agentReasoningEffortRaw: String?
	var lastRunStateRaw: String?
	var autoEditEnabled: Bool
	var parentSessionID: UUID?
	var isMCPOriginated: Bool
	var serializationVersion: Int?
	var observedFileSize: Int64?
	var observedFileModificationDate: Date?
	var lastIndexedAt: Date

	var activityDate: Date {
		AgentSessionRestoreSupport.sidebarActivityDate(lastUserMessageAt: lastUserMessageAt, savedAt: savedAt)
	}

	func sidebarEntry(tabID overrideTabID: UUID? = nil, displayName: String? = nil) -> AgentSessionIndexEntry? {
		guard let tabID = overrideTabID ?? composeTabID else { return nil }
		return AgentSessionIndexEntry(
			id: id,
			tabID: tabID,
			name: AgentSessionRestoreSupport.normalizedSessionTitle(displayName ?? name),
			lastUserMessageAt: lastUserMessageAt,
			savedAt: savedAt,
			lastRunStateRaw: lastRunStateRaw,
			itemCount: itemCount,
			agentKindRaw: agentKindRaw,
			agentModelRaw: agentModelRaw,
			agentReasoningEffortRaw: agentReasoningEffortRaw,
			autoEditEnabled: autoEditEnabled,
			parentSessionID: parentSessionID,
			hasUnknownConversationContent: hasUnknownConversationContent,
			isMCPOriginated: isMCPOriginated
		)
	}

	func agentSessionMeta(lastModifiedOverride: Date? = nil) -> AgentSessionMeta {
		AgentSessionMeta(
			id: id,
			composeTabID: composeTabID,
			name: AgentSessionRestoreSupport.normalizedSessionTitle(name),
			lastModified: lastModifiedOverride ?? observedFileModificationDate ?? savedAt,
			itemCount: itemCount,
			agentKind: agentKindRaw,
			agentModel: agentModelRaw,
			lastRunState: lastRunStateRaw,
			parentSessionID: parentSessionID,
			isMCPOriginated: isMCPOriginated
		)
	}

	func matchesIndexedSessionMetadata(_ other: AgentSessionMetadataRecord) -> Bool {
		id == other.id
			&& filename == other.filename
			&& workspaceID == other.workspaceID
			&& composeTabID == other.composeTabID
			&& name == other.name
			&& savedAt == other.savedAt
			&& lastUserMessageAt == other.lastUserMessageAt
			&& itemCount == other.itemCount
			&& transcriptProjectionCounts == other.transcriptProjectionCounts
			&& hasUnknownConversationContent == other.hasUnknownConversationContent
			&& agentKindRaw == other.agentKindRaw
			&& agentModelRaw == other.agentModelRaw
			&& agentReasoningEffortRaw == other.agentReasoningEffortRaw
			&& lastRunStateRaw == other.lastRunStateRaw
			&& autoEditEnabled == other.autoEditEnabled
			&& parentSessionID == other.parentSessionID
			&& isMCPOriginated == other.isMCPOriginated
			&& serializationVersion == other.serializationVersion
			&& observedFileSize == other.observedFileSize
			&& observedFileModificationDate == other.observedFileModificationDate
	}

	static func record(
		from session: AgentSession,
		fileURL: URL,
		observedFileSize: Int64?,
		observedFileModificationDate: Date?,
		lastIndexedAt: Date = Date()
	) -> AgentSessionMetadataRecord {
		AgentSessionMetadataRecord(
			id: session.id,
			filename: fileURL.lastPathComponent,
			workspaceID: session.workspaceID,
			composeTabID: session.composeTabID,
			name: AgentSessionRestoreSupport.normalizedSessionTitle(session.name),
			savedAt: session.savedAt,
			lastUserMessageAt: session.lastUserMessageAt,
			itemCount: session.effectiveItemCount,
			transcriptProjectionCounts: session.transcriptProjectionCounts,
			hasUnknownConversationContent: AgentSessionRestoreSupport.hasUnknownConversationContent(in: session),
			agentKindRaw: session.agentKind,
			agentModelRaw: session.agentModel,
			agentReasoningEffortRaw: session.agentReasoningEffort,
			lastRunStateRaw: session.lastRunState,
			autoEditEnabled: session.autoEditEnabled,
			parentSessionID: session.parentSessionID,
			isMCPOriginated: session.isMCPOriginated,
			serializationVersion: session.serializationVersion,
			observedFileSize: observedFileSize,
			observedFileModificationDate: observedFileModificationDate,
			lastIndexedAt: lastIndexedAt
		)
	}
}

struct AgentSessionMetadataQuarantineRecord: Codable, Equatable, Sendable {
	var filename: String
	var observedFileSize: Int64?
	var observedFileModificationDate: Date?
	var errorDescription: String
	var lastAttemptedAt: Date
}

extension Array where Element == AgentSessionMetadataRecord {
	func sortedForAgentSessionMetadataIndex() -> [AgentSessionMetadataRecord] {
		sorted { lhs, rhs in
			if lhs.activityDate != rhs.activityDate {
				return lhs.activityDate > rhs.activityDate
			}
			if lhs.savedAt != rhs.savedAt {
				return lhs.savedAt > rhs.savedAt
			}
			return lhs.id.uuidString < rhs.id.uuidString
		}
	}
}
