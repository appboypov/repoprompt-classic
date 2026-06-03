//
//  AIChatMessage.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-14.
//

import Foundation

// MARK: - Supporting Models

struct AIChatMessage: Identifiable, Equatable {
	let id: UUID
	private(set) var content: String
	let isUser: Bool
	private(set) var isMergeButton: Bool
	private(set) var parsedContent: [ContentItem]
	private(set) var associatedMessageId: UUID?
	private(set) var parsingStatus: MessageParsingStatus = .notYetParsed
	
	/// The sequence index determining message order
	let sequenceIndex: Int
	private(set) var isFinalized: Bool = false
	private(set) var extractedCoreContent: String?
	private(set) var hasCompletedDelegateWork: Bool
	private(set) var hasPendingDelegateWork: Bool
	private(set) var hasParseableContent: Bool = false
	private(set) var reasoningContent: String = ""
	
	/// NEW: For each delegate edit, store its final output separately,
	/// keyed by delegateEditTask.id (UUID) or some other unique key.
	private(set) var delegateResults: [UUID: String] = [:]
	
	/// NEW: The user's selected file paths at the time this message was created.
	private(set) var allowedFilePaths: [String] = []
	
	/// Quick access to how many files were selected when this message was created.
	var selectedFileCount: Int { allowedFilePaths.count }
	
	/// NEW: Diff summaries for file edits made by this message
	private(set) var diffSummaries: [MessageDiff] = []
	
	/// NEW: On-demand combination of `content` + all delegate edit outputs.
	var combinedText: String {
		var result = content
		for delegateText in delegateResults.values {
			result += "\n" + delegateText
		}
		return result
	}
	
	// New fields for loadability checks, etc.
	var hasUnloadableFiles: Bool = false
	var loadErrors: [String] = []
	var hasAnyFileChanges: Bool = false
	var parsedFileCount: Int = 0
	var totalChangeCount: Int = 0
	var revisionCount: Int = 0
	var fileChangesLoaded: Bool = false
	
	// Token counts for analytics
	private(set) var promptTokens: Int?
	private(set) var completionTokens: Int?
	private(set) var cost: Double?
	
	/// The AI model name (e.g. "gpt-4o", "Claude-Opus", etc.) associated with
	/// this assistant response.  `nil` for user messages or when unknown.
	private(set) var modelName: String?
	
	enum CodingKeys: String, CodingKey {
		case id, content, isUser, isMergeButton, parsedContent, associatedMessageId, parsingStatus,
				extractedCoreContent, allowedFilePaths, diffSummaries
	}
	
	init(
		id: UUID = UUID(),
		content: String,
		isUser: Bool,
		isMergeButton: Bool = false,
		parsedContent: [ContentItem] = [],
		associatedMessageId: UUID? = nil,
		parsingStatus: MessageParsingStatus = .notYetParsed,
		extractedCoreContent: String? = nil,
		isFinalized: Bool = false,
		sequenceIndex: Int = 0,
		allowedFilePaths: [String] = [],
		reasoningContent: String = "",
		modelName: String? = nil
	) {
		self.id = id
		self.content = content
		self.isUser = isUser
		self.isMergeButton = isMergeButton
		self.parsedContent = parsedContent
		self.associatedMessageId = associatedMessageId
		self.parsingStatus = parsingStatus
		self.extractedCoreContent = extractedCoreContent
		self.hasCompletedDelegateWork = false
		self.hasPendingDelegateWork = false
		self.sequenceIndex = sequenceIndex
		self.allowedFilePaths = allowedFilePaths
		self.isFinalized = isFinalized
		self.reasoningContent = reasoningContent
		self.modelName = modelName
	}
	
	static func == (lhs: AIChatMessage, rhs: AIChatMessage) -> Bool {
		lhs.id == rhs.id && lhs.revisionCount == rhs.revisionCount
	}
	
	// Extension to provide revision-incrementing accessors
	/// Updates the core `content` and increments revisionCount.
	mutating func updateContent(_ newContent: String) {
		self.content = newContent
		self.revisionCount += 1
	}
	
	/// Appends text to existing `content`, then increments revisionCount.
	mutating func appendContent(_ extra: String) {
		self.content += extra
		self.revisionCount += 1
	}
	
	mutating func updateParsedContent(_ newParsedContent: [ContentItem]) {
		self.parsedContent = newParsedContent
		self.revisionCount += 1
	}
	
	mutating func updateExtractedCoreContent(_ newCoreContent: String?) {
		self.extractedCoreContent = newCoreContent
		self.revisionCount += 1
	}
	
	mutating func updateReasoningContent(_ newReasoning: String) {
		self.reasoningContent = newReasoning
		self.revisionCount += 1
	}
	
	mutating func updateParsingStatus(_ newStatus: MessageParsingStatus) {
		self.parsingStatus = newStatus
		self.revisionCount += 1
	}
	
	mutating func setIsFinalized(_ finalized: Bool) {
		self.isFinalized = finalized
		self.revisionCount += 1
	}
	
	mutating func setHasPendingDelegateWork(_ pending: Bool) {
		self.hasPendingDelegateWork = pending
		self.revisionCount += 1
	}
	
	mutating func setHasCompletedDelegateWork(_ completed: Bool) {
		self.hasCompletedDelegateWork = completed
		self.revisionCount += 1
	}
	
	mutating func setHasParseableContent(_ hasParseable: Bool) {
		self.hasParseableContent = hasParseable
		self.revisionCount += 1
	}
	
	mutating func setHasUnloadableFiles(_ unloadable: Bool) {
		self.hasUnloadableFiles = unloadable
		self.revisionCount += 1
	}
	
	mutating func clearLoadErrors() {
		self.loadErrors.removeAll()
		self.revisionCount += 1
	}
	
	mutating func appendLoadError(_ error: String) {
		self.loadErrors.append(error)
		self.revisionCount += 1
	}
	
	mutating func setParsedFileCount(_ count: Int) {
		self.parsedFileCount = count
		self.revisionCount += 1
	}
	
	mutating func setTotalChangeCount(_ count: Int) {
		self.totalChangeCount = count
		self.revisionCount += 1
	}
	
	mutating func updateTokenInfo(_ info: ChatTokenInfo?) {
		self.promptTokens = info?.promptTokens
		self.completionTokens = info?.completionTokens
		self.cost = info?.cost
		self.revisionCount += 1
	}
	
	mutating func addDelegateResult(_ taskId: UUID, text: String) {
		self.delegateResults[taskId] = text
		self.revisionCount += 1
	}
	
	mutating func removeDelegateResult(_ taskId: UUID) {
		delegateResults.removeValue(forKey: taskId)
		revisionCount += 1
	}
	
	mutating func removeDelegateResults(for taskIds: [UUID]) {
		for taskId in taskIds {
			delegateResults.removeValue(forKey: taskId)
		}
		// Increment revisionCount only once for the whole batch:
		revisionCount += 1
	}
	
	mutating func setDelegateResults(_ newResults: [UUID: String]) {
		self.delegateResults = newResults
		self.revisionCount += 1
	}
	
	mutating func setAllowedPaths(_ filePaths:  [String]) {
		allowedFilePaths = filePaths
		revisionCount += 1
	}
	
	mutating func setDiffSummaries(_ summaries: [MessageDiff]) {
		diffSummaries = summaries
		revisionCount += 1
	}

	/// Make this message lightweight before deallocation to reduce release overhead
	mutating func makeLightweight() {
		// Use existing setters to avoid touching private(set) vars
		updateContent("")                       // big user/AI text
		updateParsedContent([])                 // parsed items
		updateExtractedCoreContent(nil)
		updateReasoningContent("")
		setDelegateResults([:])					// delegate XML payloads
		setAllowedPaths([])
		setDiffSummaries([])

		setHasParseableContent(false)
		setHasUnloadableFiles(false)
		clearLoadErrors()
	}
}
