import Foundation

enum ChatSessionError: Error {
	case emptySession
	case invalidFilename(String)
	case decodingFailed(DecodingError)
	case loadFailed(Error)
	
	var localizedDescription: String {
		switch self {
		case .emptySession:
			return "Cannot save an empty chat session"
		case .invalidFilename(let name):
			return "Invalid chat session filename: \(name)"
		case .decodingFailed(let error):
			return "Failed to decode chat session: \(error.localizedDescription)"
		case .loadFailed(let error):
			return "Failed to load chat session: \(error.localizedDescription)"
		}
	}
}

struct DelegateEditRecord: Codable {
	let id: UUID
	let parentAIMessageId: UUID
	let rawText: String
}

struct ChangedFileState: Codable {
	let id: UUID
	let relativePath: String
	let originalContent: String
	let finalContent: String
	let action: String
	let acceptedChanges: [UUID]
	let rejectedChanges: [UUID]
	
	// New fields for content-based identity
	let acceptedContentKeys: [String]
	let rejectedContentKeys: [String]
	
	// Define CodingKeys for backward compatibility
	enum CodingKeys: String, CodingKey {
		case id
		case relativePath
		case originalContent
		case finalContent
		case action
		case acceptedChanges
		case rejectedChanges
		case acceptedContentKeys
		case rejectedContentKeys
	}
	
	init(
		id: UUID = UUID(),
		relativePath: String,
		originalContent: String,
		finalContent: String,
		action: String,
		acceptedChanges: [UUID] = [],
		rejectedChanges: [UUID] = [],
		acceptedContentKeys: [String] = [],
		rejectedContentKeys: [String] = []
	) {
		self.id = id
		self.relativePath = relativePath
		self.originalContent = originalContent
		self.finalContent = finalContent
		self.action = action
		self.acceptedChanges = acceptedChanges
		self.rejectedChanges = rejectedChanges
		self.acceptedContentKeys = acceptedContentKeys
		self.rejectedContentKeys = rejectedContentKeys
	}
	
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		
		id = try container.decode(UUID.self, forKey: .id)
		relativePath = try container.decode(String.self, forKey: .relativePath)
		originalContent = try container.decode(String.self, forKey: .originalContent)
		finalContent = try container.decode(String.self, forKey: .finalContent)
		action = try container.decode(String.self, forKey: .action)
		acceptedChanges = try container.decode([UUID].self, forKey: .acceptedChanges)
		rejectedChanges = try container.decode([UUID].self, forKey: .rejectedChanges)
		
		// Handle new fields, with fallback to empty arrays for backward compatibility
		acceptedContentKeys = try container.decodeIfPresent([String].self, forKey: .acceptedContentKeys) ?? []
		rejectedContentKeys = try container.decodeIfPresent([String].self, forKey: .rejectedContentKeys) ?? []
	}
	
	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		
		try container.encode(id, forKey: .id)
		try container.encode(relativePath, forKey: .relativePath)
		try container.encode(originalContent, forKey: .originalContent)
		try container.encode(finalContent, forKey: .finalContent)
		try container.encode(action, forKey: .action)
		try container.encode(acceptedChanges, forKey: .acceptedChanges)
		try container.encode(rejectedChanges, forKey: .rejectedChanges)
		
		// Always encode the new fields
		try container.encode(acceptedContentKeys, forKey: .acceptedContentKeys)
		try container.encode(rejectedContentKeys, forKey: .rejectedContentKeys)
	}
}

/// Persisted representation of one delegate-edit task.
///
/// • `status` now carries precise outcome information (completed / partial / failed)
///   instead of the legacy Bool.
/// • Includes `failedCount` when `.partialFailed` so the UI can show
///   "x / y sub-edits failed" after reload.
struct DelegateEditItemPersist: Codable {
	// MARK: – Nested types --------------------------------------------------
	enum TaskStatus: String, Codable {
		case completed, partialFailed, failed, noChangesMade
	}
	
	struct ChangePersist: Codable {
		let description: String
		let codeSnippet: String
		let complexity: Int
	}
	
	// MARK: – Stored properties --------------------------------------------
	let filePath: String
	let resolvedFilePath: String?
	let changes: [ChangePersist]
	let status: TaskStatus
	let failedCount: Int?        // only meaningful for .partialFailed
	let modelDisplayName: String?
	let finalOutput: String?
	
	// ───── token accounting ───────────────────────────────────────────────
	let tokenEstimate: Int?
	let promptTokens: Int?
	let completionTokens: Int?
	
	// MARK: – CodingKeys ----------------------------------------------------
	enum CodingKeys: String, CodingKey {
		case filePath, resolvedFilePath, changes, status, failedCount,
				modelDisplayName, finalOutput,
				tokenEstimate, promptTokens, completionTokens
	}
	
	// MARK: – Init helpers --------------------------------------------------
	init(
		filePath: String,
		resolvedFilePath: String? = nil,
		changes: [ChangePersist],
		status: TaskStatus,
		failedCount: Int? = nil,
		modelDisplayName: String? = nil,
		finalOutput: String? = nil,
		tokenEstimate: Int? = nil,
		promptTokens: Int? = nil,
		completionTokens: Int? = nil
	) {
		self.filePath = filePath
		self.resolvedFilePath = resolvedFilePath
		self.changes = changes
		self.status = status
		self.failedCount = failedCount
		self.modelDisplayName = modelDisplayName
		self.finalOutput = finalOutput
		self.tokenEstimate = tokenEstimate
		self.promptTokens = promptTokens
		self.completionTokens = completionTokens
	}
	
	// MARK: – Codable with legacy Bool support ------------------------------
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		
		filePath         = try c.decode(String.self, forKey: .filePath)
		resolvedFilePath = try c.decodeIfPresent(String.self, forKey: .resolvedFilePath)
		changes          = try c.decode([ChangePersist].self, forKey: .changes)
		
		// New enum-based status, with fallback to legacy Bool
		if let enumVal = try? c.decode(TaskStatus.self, forKey: .status) {
			status = enumVal
		} else if let boolVal = try? c.decode(Bool.self, forKey: .status) {
			status = boolVal ? .completed : .failed
		} else {
			status = .failed
		}
		
		failedCount      = try c.decodeIfPresent(Int.self, forKey: .failedCount)
		modelDisplayName = try c.decodeIfPresent(String.self, forKey: .modelDisplayName)
		finalOutput      = try c.decodeIfPresent(String.self, forKey: .finalOutput)
		tokenEstimate    = try c.decodeIfPresent(Int.self, forKey: .tokenEstimate)
		promptTokens     = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
		completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
	}
	
	func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(filePath,          forKey: .filePath)
		try c.encodeIfPresent(resolvedFilePath, forKey: .resolvedFilePath)
		try c.encode(changes,           forKey: .changes)
		try c.encode(status,            forKey: .status)
		try c.encodeIfPresent(failedCount, forKey: .failedCount)
		try c.encodeIfPresent(modelDisplayName, forKey: .modelDisplayName)
		try c.encodeIfPresent(finalOutput,      forKey: .finalOutput)
		try c.encodeIfPresent(tokenEstimate,    forKey: .tokenEstimate)
		try c.encodeIfPresent(promptTokens,     forKey: .promptTokens)
		try c.encodeIfPresent(completionTokens, forKey: .completionTokens)
	}
}

struct ChatSession: Codable, Identifiable {
	let id: UUID
	var workspaceID: UUID?
	var composeTabID: UUID?
	var agentModeSessionID: UUID?
	var agentModeRunID: UUID?
	var name: String
	var savedAt: Date
	var fileURL: URL?
	var messages: [StoredMessage]
	/// Optional lightweight message count for sessions where `messages` is unloaded.
	/// When nil, callers should use `messages.count`.
	var messageCount: Int?
	var changedFilesByMessage: [UUID: [ChangedFileState]]?
	var delegateEditItemsByMessage: [UUID: [DelegateEditItemPersist]]?
	var selectedFilePaths: [String]
	var selectedPromptIDs: [UUID]
	
	/// NEW: The user's selected AI model at the time of saving.
	var preferredAIModel: String?
	
	/// NEW: The selected Chat Preset for this session
	var selectedChatPresetID: UUID?
	
	/// Human-readable short identifier combining name slug and UUID prefix
	var shortID: String
	
	/// Creates a short ID from name and UUID
	static func makeShortID(name: String, uuid: UUID) -> String {
		let slug = name.slugify(maxLength: 24)
		let uuidPrefix = uuid.uuidString.prefix(6)
		return "\(slug)-\(uuidPrefix)"
	}
	
	init(
		id: UUID = UUID(),
		workspaceID: UUID? = nil,
		composeTabID: UUID? = nil,
		agentModeSessionID: UUID? = nil,
		agentModeRunID: UUID? = nil,
		name: String = "Untitled",
		savedAt: Date = Date(),
		fileURL: URL? = nil,
		messages: [StoredMessage] = [],
		changedFilesByMessage: [UUID: [ChangedFileState]]? = nil,
		delegateEditItemsByMessage: [UUID: [DelegateEditItemPersist]]? = nil,
		selectedFilePaths: [String] = [],
		selectedPromptIDs: [UUID] = [],
		// NEW:
		preferredAIModel: String? = nil,
		selectedChatPresetID: UUID? = nil,
		messageCount: Int? = nil,
		shortID: String? = nil
	) {
		self.id = id
		self.workspaceID = workspaceID
		self.composeTabID = composeTabID
		self.agentModeSessionID = agentModeSessionID
		self.agentModeRunID = agentModeRunID
		self.name = name
		self.savedAt = savedAt
		self.fileURL = fileURL
		self.messages = messages
		self.messageCount = messageCount
		self.changedFilesByMessage = changedFilesByMessage
		self.delegateEditItemsByMessage = delegateEditItemsByMessage
		self.selectedFilePaths = selectedFilePaths
		self.selectedPromptIDs = selectedPromptIDs
		self.preferredAIModel = preferredAIModel
		self.selectedChatPresetID = selectedChatPresetID
		self.shortID = shortID ?? Self.makeShortID(name: name, uuid: id)
	}
	
	enum CodingKeys: String, CodingKey {
		case id
		case workspaceID
		case composeTabID
		case agentModeSessionID
		case agentModeRunID
		case name
		case savedAt
		case fileURL
		case messages
		case messageCount
		case changedFilesByMessage
		case delegateEditItemsByMessage
		case selectedFilePaths
		case selectedPromptIDs
		case preferredAIModel    // NEW
		case selectedChatPresetID // NEW
		case shortID
	}
	
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		
		id = try container.decode(UUID.self, forKey: .id)
		workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
		composeTabID = try container.decodeIfPresent(UUID.self, forKey: .composeTabID)
		agentModeSessionID = try container.decodeIfPresent(UUID.self, forKey: .agentModeSessionID)
		agentModeRunID = try container.decodeIfPresent(UUID.self, forKey: .agentModeRunID)
		name = try container.decode(String.self, forKey: .name)
		savedAt = try container.decode(Date.self, forKey: .savedAt)
		fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
		messages = try container.decode([StoredMessage].self, forKey: .messages)
		messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount)
		changedFilesByMessage = try container.decodeIfPresent([UUID: [ChangedFileState]].self, forKey: .changedFilesByMessage)
		delegateEditItemsByMessage = try container.decodeIfPresent([UUID: [DelegateEditItemPersist]].self, forKey: .delegateEditItemsByMessage)
		selectedFilePaths = try container.decodeIfPresent([String].self, forKey: .selectedFilePaths) ?? []
		selectedPromptIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedPromptIDs) ?? []
		preferredAIModel = try container.decodeIfPresent(String.self, forKey: .preferredAIModel)
		selectedChatPresetID = try container.decodeIfPresent(UUID.self, forKey: .selectedChatPresetID)
		
		// Handle backward compatibility for shortID
		if let decodedShortID = try container.decodeIfPresent(String.self, forKey: .shortID) {
			shortID = decodedShortID
		} else {
			// Generate shortID for sessions that don't have one
			shortID = Self.makeShortID(name: name, uuid: id)
		}
	}
	
	/// Coalesces whitespace and falls back to "Untitled Chat" when empty.
	static func validatedName(_ raw: String) -> String {
		let trimmed   = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		let collapsed = trimmed
			.replacingOccurrences(of: #"\s+"#, with: " ",
								  options: .regularExpression)
		return collapsed.isEmpty ? "Untitled Chat" : collapsed
	}
}

extension ChatSession {
	/// Message count for UI and sorting when `messages` may be unloaded.
	var effectiveMessageCount: Int {
		messageCount ?? messages.count
	}

	var hasMessages: Bool {
		effectiveMessageCount > 0
	}

	/// Returns true if this session is a lightweight stub (messages unloaded).
	/// A stub has empty messages but retains messageCount for UI display.
	var isListStub: Bool {
		messages.isEmpty &&
		messageCount != nil &&
		changedFilesByMessage == nil &&
		delegateEditItemsByMessage == nil
	}

	/// Returns a lightweight copy suitable for session lists (drops heavy payloads).
	func listStub() -> ChatSession {
		var copy = self
		copy.messageCount = effectiveMessageCount
		copy.messages = []
		copy.changedFilesByMessage = nil
		copy.delegateEditItemsByMessage = nil
		return copy
	}
}
