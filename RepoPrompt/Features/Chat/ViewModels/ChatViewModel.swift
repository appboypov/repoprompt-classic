import SwiftUI
import Combine

#if DEBUG
private var chatViewModelDebugLoggingEnabled = false
#endif

private func chatViewModelDebugLog(_ message: @autoclosure () -> String) {
	#if DEBUG
	guard chatViewModelDebugLoggingEnabled else { return }
	print("[ChatViewModel] \(message())")
	#endif
}

/// MessageReaper - Gradually releases messages to prevent UI stalls
@MainActor
final class MessageReaper {
	private var bins: [[AIChatMessage]] = []
	private var timer: Timer?
	private var timerChunkSize = 0
	
	/// Minimum tick interval to prevent busy-loop when interval=0.0 is passed
	private static let minTickInterval: TimeInterval = 1.0 / 60.0  // ~16ms
	
	func drain(_ source: inout [AIChatMessage],
				chunkSize: Int = 64,
				interval: TimeInterval = 0.0) {
		guard !source.isEmpty else { return }
		var old = [AIChatMessage]()
		swap(&old, &source)               // O(1) – UI becomes responsive immediately
		bins.append(old)
		startTimerIfNeeded(chunkSize: chunkSize, interval: interval)
	}
	
	private func startTimerIfNeeded(chunkSize: Int, interval: TimeInterval) {
		guard timer == nil else { return }
		timerChunkSize = max(1, chunkSize)
		// Sanitize interval and enforce minimum to prevent busy-loop
		let sanitized = interval.isFinite ? interval : 0
		let tickInterval = max(Self.minTickInterval, max(0.0, sanitized))
		let newTimer = Timer.scheduledTimer(timeInterval: tickInterval,
										target: self,
										selector: #selector(handleDrainTimer(_:)),
										userInfo: nil,
										repeats: true)
		newTimer.tolerance = tickInterval * 0.2  // Reduce energy churn
		timer = newTimer
	}

	@objc private func handleDrainTimer(_ timer: Timer) {
		guard !bins.isEmpty else {
			timer.invalidate()
			self.timer = nil
			return
		}

		var bucket = bins.removeLast()
		let n = min(timerChunkSize, bucket.count)

		// Proactively shrink heavy fields before deallocation
		for i in 0..<n {
			var message = bucket[i]
			message.makeLightweight()
			bucket[i] = message
		}

		// Keep deallocation bounded to a small slice per tick
		autoreleasepool {
			bucket.removeFirst(n)
		}

		if !bucket.isEmpty {
			bins.append(bucket)
		}
	}
}

/// High-level modes a chat turn can operate in.
enum ChatMode: String, Codable {
	case chat
	case plan
	case edit
	case review

	/// Human-readable description for logging / UI.
	var description: String {
		switch self {
		case .chat: return "Standard conversation mode"
		case .plan: return "High-level planning (read-only)"
		case .edit: return "Direct file-edit mode"
		case .review: return "Code review mode (diff-focused, no edits)"
		}
	}
}

enum MessageParsingStatus {
	case notParsed
	case partiallyParsed
	case fullyParsed
	case notYetParsed
}

/// Stores ephemeral message state that shouldn't be cleared when the messages array is cleared
@MainActor
class EphemeralMessageState {
	/// Maps message IDs to their reasoning content
	private var reasoningContentMap: [UUID: String] = [:]
	
	/// Get reasoning content for a message with guard for nil UUID
	func reasoningContent(for messageId: UUID?) -> String {
		guard let id = messageId else {
#if DEBUG
			print("Warning: Attempted to access reasoning content with nil messageId")
#endif
			return ""
		}
		return reasoningContentMap[id] ?? ""
	}
	
	/// Set reasoning content for a message with guards for nil UUID and content
	func setReasoningContent(_ content: String?, for messageId: UUID?) {
		guard let id = messageId else {
#if DEBUG
			print("Warning: Attempted to set reasoning content with nil messageId")
#endif
			return
		}
		
		// If content is nil, treat it as removing the content
		if content == nil {
			reasoningContentMap.removeValue(forKey: id)
			return
		}
		
		reasoningContentMap[id] = ReasoningTextFormatter.normalize(content!)
	}
	
	/// Append to existing reasoning content with guards
	func appendReasoningContent(_ delta: String?, for messageId: UUID?) {
		guard let id = messageId else {
#if DEBUG
			print("Warning: Attempted to append reasoning content with nil messageId")
#endif
			return
		}
		
		// Don't append nil or empty strings
		guard let delta = delta, !delta.isEmpty else {
			return
		}
		
		let updated = reasoningContentMap[id, default: ""] + delta
		reasoningContentMap[id] = ReasoningTextFormatter.normalize(updated)
	}
	
	/// Clear all ephemeral state (optional, for memory management)
	func clearAll() {
		reasoningContentMap.removeAll()
	}
	
	/// Clear state for a specific message with guard for nil UUID
	func clear(for messageId: UUID?) {
		guard let id = messageId else {
#if DEBUG
			print("Warning: Attempted to clear reasoning content with nil messageId")
#endif
			return
		}
		reasoningContentMap.removeValue(forKey: id)
	}
	
	/// Utility method to check if content exists for a message
	func hasContent(for messageId: UUID?) -> Bool {
		guard let id = messageId else { return false }
		return reasoningContentMap[id] != nil
	}
}

// MARK: – In-flight delegate-edit helper
actor DelegateEditTaskManager {
	// ▼ changed Error → Never
	private var pendingByMessage: [UUID: [Task<Void, Never>]] = [:]
	
	// ▼ changed Error → Never
	func addTask(_ task: Task<Void, Never>, forMessageId messageId: UUID) {
		pendingByMessage[messageId, default: []].append(task)
	}
	
	/// Wait until every pending task for a message completes, then clear the list.
	func waitForTasks(forMessageId messageId: UUID) async {
		// Drain in waves. New tasks can be added while awaiting the current batch.
		while true {
			guard let batch = pendingByMessage[messageId], !batch.isEmpty else {
				pendingByMessage.removeValue(forKey: messageId)
				return
			}
			// Clear first so late arrivals are queued for the next wave.
			pendingByMessage[messageId] = []
			for task in batch {
				_ = await task.value
			}
		}
	}
	
	/// Wait until every pending task completes, then clear the list.
	func waitForAllTasks() async {
		// Keep draining until no buckets remain; avoids dropping late arrivals.
		while !pendingByMessage.isEmpty {
			let ids = Array(pendingByMessage.keys)
			for id in ids {
				await waitForTasks(forMessageId: id)
			}
		}
	}
	
	func hasPendingTasks() -> Bool { !pendingByMessage.isEmpty }
	
	func cancelTasks(forMessageId messageId: UUID) {
		for task in pendingByMessage[messageId] ?? [] { task.cancel() }
		pendingByMessage.removeValue(forKey: messageId)
	}
	
	func cancelAllTasks() {
		for (_, tasks) in pendingByMessage {
			for task in tasks { task.cancel() }
		}
		pendingByMessage.removeAll()
	}
}

// MARK: - Message Finalisation Hub
actor MessageFinalisationHub {
	private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
	private var completed: Set<UUID> = []
	
	func register(_ id: UUID, cont: CheckedContinuation<Void, Never>) {
		if completed.contains(id) {
			cont.resume()
			return
		}
		waiters[id, default: []].append(cont)
	}
	
	func fulfil(_ id: UUID) {
		completed.insert(id)
		guard let list = waiters.removeValue(forKey: id) else { return }
		for c in list { c.resume() }
	}
	
	/// Cancel all waiters for a specific message ID
	func cancel(_ id: UUID) {
		let list = waiters.removeValue(forKey: id) ?? []
		completed.insert(id)
		for c in list { c.resume() }
	}
	
	func isCompleted(_ id: UUID) -> Bool {
		completed.contains(id)
	}
	
	/// Clean up any orphaned waiters (safety mechanism)
	func cleanup() {
		let allWaiters = waiters.values.flatMap { $0 }
		waiters.removeAll()
		for c in allWaiters { c.resume() }
	}
}


struct DelegateEditTask: Identifiable {
	let id: UUID
	let filePath: String
	var changes: [DelegateEditItem.Change]
	
	var modelDisplayName: String
	var status: TaskStatus = .pending
	
	/// NEW: The actual resolved path from the user's allowedFilePaths.
	var resolvedFilePath: String? = nil
	
	// ⬇️  NEW FIELDS ---------------------------------------------------------
	/// Rolling, rough estimate (~chars ÷ 4) updated while streaming.
	var tokenEstimate: Int = 0
	/// Final token accounting returned by the LLM once the stream ends.
	var promptTokens: Int?
	var completionTokens: Int?
	/// NEW: Track token estimates per stream ID when using parallel processing
	var tokenEstimatesByStream: [UUID: Int] = [:]
	/// NEW: Track the last tool used during the run (for live feedback during progress)
	var lastToolUsed: String?
	// -----------------------------------------------------------------------

	var accumulatedOutput: String = ""
	
	enum TaskStatus: Equatable, Hashable {
		case pending
		case inProgress
		case completed
		/// Agent ran successfully but decided not to make any changes
		case noChangesMade
		/// Some of the parallel sub-edits failed
		case partialFailed(failedCount: Int)
		case failed(reason: FailureReason)
		
		enum FailureReason: Hashable {
			case fileNotSelected
			case streamError
			case fileLoadError
			case invalidChanges
		}
	}
}

/// Holds file change data for lazy loading
struct DeferredDiffBuffer {
	let fileChanges: [FileChanges]
	let overrides: [String: String]
	let persisted: [ChangedFileState]
}

private struct SessionRunState {
	var activeQueryId: UUID? = nil
	var activeStreamId: ChatStreamID? = nil
	var isStreaming: Bool { activeQueryId != nil && activeStreamId != nil }
}

enum ChatSessionScope: String, CaseIterable, Identifiable {
	case activeTabOnly
	case all
	case unassigned
	
	var id: String { rawValue }
	
	var label: String {
		switch self {
		case .activeTabOnly:
			return "This Tab"
		case .all:
			return "All"
		case .unassigned:
			return "Unassigned"
		}
	}
}

@MainActor
class ChatViewModel: ObservableObject {
	@Published var messages: [AIChatMessage] = []
	@Published private(set) var streamingSessions: Set<UUID> = []
	@Published private(set) var messageStoreRevision: Int = 0
	@Published private(set) var currentQueryId: UUID?
	
	// Per-session stream state
	private var runStateBySession: [UUID: SessionRunState] = [:]
	
	// Per-message routing
	private var sessionIDByMessageId: [UUID: UUID] = [:]
	
	// Per-session messages
	private var messageStore: [UUID: [AIChatMessage]] = [:]
	
	// Per-session sequence numbering
	private var nextSequenceIndexBySession: [UUID: Int] = [:]
	
	/// Maps AI message/query IDs to the underlying AIQueriesService stream IDs for targeted cancellation.
	private var streamIDsByQueryId: [UUID: ChatStreamID] = [:]
	
	/// Active headless (plan/question) streams keyed by tab ID.
	/// Used by Discover to cancel background plan generation.
	/// Note: Internal (not private) to allow access from ChatViewModel+MCP.swift extension.
	var headlessStreamsByTabID: [UUID: ChatStreamID] = [:]
	
	@Published var delegateEditTasks: [UUID: [DelegateEditTask]] = [:]
	
	/// Stores ephemeral message state that persists even when messages array is cleared
	let ephemeralState = EphemeralMessageState()
	
	/// Gradual message cleanup to prevent UI stalls
	private let messageReaper = MessageReaper()
	
	/// A subject for programmatic text updates
	let programmaticSetText = PassthroughSubject<String, Never>()
	
	/// An ephemeral dictionary to remember typed drafts across tab changes / onDisappear
	private var ephemeralDrafts: [UUID: String] = [:]
	
	// Add a flag to signal focusing the input field
	@Published var focusInputField: Bool = false
	
	// Additional published properties
	@Published var debugMode: Bool = false
	@Published var isNewChat: Bool = false
	@Published var inputText: String = ""
	@Published var lastDelegateEditItems: [DelegateEditItem]
	
	// NEW: flag to mute costly token recalcs while we bulk-append messages
	private var isBatchLoadingMessages = false

	// NEW: Skip the *first* autosave that occurs right after a workspace
	//       switch creates its implicit "New Chat".
	private var skipAutosaveCurrentSessionOnce: Bool = false
	
	// Guard against tab-change reentry while switching sessions.
	private var isSwitchingTabsForSession: Bool = false

	// Sessions pinned in memory (e.g. MCP tool calls building a reply).
	private var pinnedSessionRefCounts: [UUID: Int] = [:]
	private var recentDisplayedSessionIDs: [UUID] = []
	private let recentDisplayedSessionLimit = 2
	private var sessionSwitchGeneration: Int = 0
	private var workspaceChatSessionLoadGeneration: UInt64 = 0
	private let workspaceSwitchChatStubLoadConcurrency = 4
	
	// Session management
	@Published var sessions: [ChatSession] = [] {
		didSet {
			refreshSessionLists()
		}
	}
	@Published var currentSessionID: UUID? {
		didSet {
			syncMCPGlobalsForCurrentSession()
		}
	}
	@Published private(set) var sessionSwitchInProgressID: UUID?
	@Published private(set) var activeTabSessions: [ChatSession] = []
	@Published var sessionScope: ChatSessionScope = .activeTabOnly {
		didSet {
			refreshVisibleSessions()
		}
	}
	@Published private(set) var visibleSessions: [ChatSession] = []
	
	struct MCPSessionUIState: Equatable {
		var modelInfo: String
		var overrideModelName: String?
		var overrideChatPresetName: String?
	}
	
	// MCP control state - ephemeral, per session, cleared after each AI response
	@Published var mcpModelInfo: String?
	@Published var mcpOverrideChatPresetName: String?
	@Published var mcpOverrideModelName: String?
	private var mcpUIStateBySession: [UUID: MCPSessionUIState] = [:]
	
	// Token tracking for UI
	@Published private(set) var tokenDisplayText: String = ""
	// NEW: live estimate for the *next* user prompt
	@Published private(set) var upcomingInputTokenText: String = ""

	// Tick counter to force UI refresh when reasoning content updates during streaming
	@Published var reasoningUpdateTick: Int = 0
	
	// Deferred diff loading for performance
	var deferredDiffs = [UUID: DeferredDiffBuffer]()
	
	@MainActor
	private func syncMCPGlobalsForCurrentSession() {
		guard let sessionID = currentSessionID else {
			mcpModelInfo = nil
			mcpOverrideChatPresetName = nil
			mcpOverrideModelName = nil
			return
		}
		let state = mcpUIStateBySession[sessionID]
		mcpModelInfo = state?.modelInfo
		mcpOverrideChatPresetName = state?.overrideChatPresetName
		mcpOverrideModelName = state?.overrideModelName
	}
	
	@MainActor
	func setMCPSessionUIState(_ state: MCPSessionUIState, for sessionID: UUID) {
		mcpUIStateBySession[sessionID] = state
		if sessionID == currentSessionID {
			syncMCPGlobalsForCurrentSession()
		}
	}
	
	@MainActor
	func clearMCPSessionUIState(for sessionID: UUID) {
		mcpUIStateBySession.removeValue(forKey: sessionID)
		if sessionID == currentSessionID {
			syncMCPGlobalsForCurrentSession()
		}
	}

	/// Estimate tokens for the conversation history that will actually be
	/// re-sent with the next prompt.  This follows the same compression rules
	/// used in `buildConversationEntries()`.
	private func estimateHistoryTokens() -> Int {
		guard let sessionID = currentSessionID else { return 0 }
		let entries = buildConversationEntries(for: sessionID)
		return entries.reduce(0) { partial, entry in
			partial + TokenCalculationService.estimateTokens(for: entry.content)
		}
	}

	@MainActor
	private func updateUpcomingInputTokenText() {
		// Cancel any previous run
		upcomingTokenEstimateTask?.cancel()
		
		// Quick snapshot
		let inputTextSnap        = inputText
		let promptTextTokensSnap = TokenCalculationService.estimateTokens(for: promptViewModel.promptText)
		let duplicateFactorSnap  = promptViewModel.duplicateUserInstructionsAtTop ? 2 : 1
		
		// Capture conversation entries on the MainActor so we avoid hops later
		let entriesSnap       = currentSessionID.map { buildConversationEntries(for: $0) } ?? []
		
		let task = Task.detached { [weak self, entriesSnap] in
			guard let self else { return }
			
			// Use the chat preset configuration, but prefer the stable preview baseline so ordinary
			// typing does not rebuild exact clipboard context on the MainActor.
			let basePromptTokensSnap = await self.promptViewModel.calculateTokensForChatContext(preferStablePreviewBaseline: true)
			
			// History tokens (only the portion that will be re-sent)
			let historyTokens = entriesSnap.reduce(0) {
				$0 + TokenCalculationService.estimateTokens(for: $1.content)
			}

			// User input
			let inputTokens = TokenCalculationService.estimateTokens(for: inputTextSnap)

			// Base prompt minus duplicated user-instruction section(s)
			var basePrompt = basePromptTokensSnap
			basePrompt -= promptTextTokensSnap * duplicateFactorSnap
			basePrompt = max(basePrompt, 0)

			// Grand total
			let total = basePrompt + historyTokens + inputTokens

			func fmt(_ n: Int) -> String {
				let k = Double(n) / 1_000
				return k.truncatingRemainder(dividingBy: 1) == 0
					? String(format: "%.0f", k)
					: String(format: "%.1f", k)
			}
			let display = "Next msg: ~\(fmt(total))k tokens"

			await MainActor.run {
				self.upcomingInputTokenText = display
				// done
				self.upcomingTokenEstimateTask = nil
			}
		}
		upcomingTokenEstimateTask = task
	}
	
	// NEW: keep references to background calculations so we can cancel them
	private var latestTokenCountsTask: Task<Void, Never>? = nil
	private var upcomingTokenEstimateTask: Task<Void, Never>? = nil
	
	// Store Combine cancellables
	private var cancellables = Set<AnyCancellable>()
	
	/// Token for tab-close listener (to remove on deinit if needed)
	private var tabCloseListenerToken: UUID?
	
	var currentSession: ChatSession? {
		guard let id = currentSessionID else { return nil }
		return sessions.first { $0.id == id }
	}
	
	@MainActor
	private func refreshSessionLists() {
		refreshActiveTabSessions()
		refreshVisibleSessions()
		refreshActiveChatTabs()
	}
	
	@MainActor
	private func refreshActiveTabSessions() {
		guard let tabID = promptViewModel.activeComposeTabID else {
			activeTabSessions = sessions
			return
		}
		activeTabSessions = sessions.filter { $0.composeTabID == tabID }
	}
	
	@MainActor
	private func refreshVisibleSessions() {
		switch sessionScope {
		case .activeTabOnly:
			visibleSessions = activeTabSessions
		case .all:
			visibleSessions = sessions
		case .unassigned:
			visibleSessions = sessions.filter { $0.composeTabID == nil }
		}
	}
	
	@MainActor
	private func refreshActiveChatTabs() {
		guard !streamingSessions.isEmpty else {
			workspaceManager.setActiveChatTabs(Set<UUID>())
			return
		}
		let tabs: Set<UUID> = Set(sessions.compactMap { session in
			guard streamingSessions.contains(session.id) else { return nil }
			return session.composeTabID
		})
		workspaceManager.setActiveChatTabs(tabs)
	}
	
	@MainActor
	func sessions(forTabID tabID: UUID?) -> [ChatSession] {
		guard let tabID else { return sessions }
		return sessions.filter { $0.composeTabID == tabID }
	}

	var isAnySessionStreaming: Bool {
		!streamingSessions.isEmpty
	}
	
	@MainActor
	func isSessionStreaming(_ sessionID: UUID?) -> Bool {
		guard let sessionID else { return false }
		return streamingSessions.contains(sessionID)
	}

	@MainActor
	func messagesSnapshot(for sessionID: UUID?) -> [AIChatMessage] {
		guard let sessionID else { return messages }
		if let storedMessages = messageStore[sessionID] {
			return storedMessages
		}
		if currentSessionID == sessionID {
			return messages
		}
		return []
	}

	@MainActor
	@discardableResult
	func ensureSessionMessagesLoaded(_ sessionID: UUID) async -> Bool {
		guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
		return await ensureSessionLoadedForBackground(session) != nil
	}

	@MainActor
	func liveMessageCount(for sessionID: UUID?) -> Int? {
		guard let sessionID else { return nil }

		let persistedCount = sessions.first(where: { $0.id == sessionID })?.effectiveMessageCount

		if let storedMessages = messageStore[sessionID] {
			if !storedMessages.isEmpty {
				return storedMessages.count
			}
			if let persistedCount {
				return max(storedMessages.count, persistedCount)
			}
			if currentSessionID == sessionID {
				return messages.count
			}
			return storedMessages.count
		}

		if currentSessionID == sessionID {
			return messages.count
		}

		return persistedCount
	}

	@MainActor
	func activeQueryId(for sessionID: UUID) -> UUID? {
		runStateBySession[sessionID]?.activeQueryId
	}
	
	@MainActor
	private func recomputeWorkspaceBusyAndFontFreeze() {
		let anyStreaming = !streamingSessions.isEmpty
		workspaceManager.isChatBusy = anyStreaming
		refreshActiveChatTabs()
		
		if anyStreaming {
			FontScaleManager.shared.freeze()
		} else {
			FontScaleManager.shared.unfreeze()
		}
	}
	
	@MainActor
	private func ensureSessionStorage(_ sessionID: UUID) {
		if messageStore[sessionID] == nil { messageStore[sessionID] = [] }
		if runStateBySession[sessionID] == nil { runStateBySession[sessionID] = SessionRunState() }
		if nextSequenceIndexBySession[sessionID] == nil { nextSequenceIndexBySession[sessionID] = 0 }
	}
	
	@MainActor
	private func withSessionMessages(_ sessionID: UUID, _ mutate: (inout [AIChatMessage]) -> Void) {
		ensureSessionStorage(sessionID)
		var arr = messageStore[sessionID] ?? []
		mutate(&arr)
		messageStore[sessionID] = arr
		messageStoreRevision &+= 1
		
		if currentSessionID == sessionID {
			messages = arr
		}
	}
	
	@MainActor
	private func sessionNeedsMessageLoad(_ session: ChatSession) -> Bool {
		guard !session.isListStub else { return true }
		guard let storedMessages = messageStore[session.id] else { return true }
		return storedMessages.isEmpty && session.effectiveMessageCount > 0
	}
	
	@MainActor
	private func setDisplayedSession(_ sessionID: UUID) {
		messages = messageStore[sessionID] ?? []
		currentQueryId = runStateBySession[sessionID]?.activeQueryId
		noteRecentlyDisplayedSession(sessionID)
	}

	@MainActor
	private func noteRecentlyDisplayedSession(_ sessionID: UUID) {
		recentDisplayedSessionIDs.removeAll { $0 == sessionID }
		recentDisplayedSessionIDs.insert(sessionID, at: 0)
		if recentDisplayedSessionIDs.count > recentDisplayedSessionLimit {
			recentDisplayedSessionIDs.removeSubrange(recentDisplayedSessionLimit...)
		}
	}

	// MARK: - Tab-Scoped Focus

	/// Focus a chat session that belongs to the given compose tab.
	/// Unlike `switchToSession`, this **never switches compose tabs** and
	/// silently returns if the session doesn't belong to `tabID`.
	/// Use from Oracle / Agent-mode UI that should stay on the current tab.
	@MainActor
	func focusSession(_ sessionID: UUID, forTab tabID: UUID, setActiveForTab: Bool = true) async {
		guard let session = sessions.first(where: { $0.id == sessionID }),
			  session.composeTabID == tabID else { return }
		// Reuse normal focus but suppress compose-tab switching via the
		// existing isSwitchingTabsForSession guard.
		let saved = isSwitchingTabsForSession
		isSwitchingTabsForSession = true
		defer { isSwitchingTabsForSession = saved }
		await switchToSession(sessionID, setActiveForTab: setActiveForTab)
	}

	@MainActor
	func pinSession(_ sessionID: UUID) {
		pinnedSessionRefCounts[sessionID, default: 0] += 1
	}

	@MainActor
	func unpinSession(_ sessionID: UUID) {
		let newCount = (pinnedSessionRefCounts[sessionID] ?? 0) - 1
		if newCount <= 0 {
			pinnedSessionRefCounts.removeValue(forKey: sessionID)
		} else {
			pinnedSessionRefCounts[sessionID] = newCount
		}
		unloadNonCurrentSessions()
	}

	@MainActor
	private func isSessionPinned(_ sessionID: UUID) -> Bool {
		(pinnedSessionRefCounts[sessionID] ?? 0) > 0
	}

	static nonisolated func shouldUseLivePromptStateForAutosave(
		sessionID: UUID,
		currentSessionID: UUID?,
		sessionComposeTabID: UUID?,
		activeComposeTabID: UUID?
	) -> Bool {
		guard sessionID == currentSessionID else { return false }
		guard let sessionComposeTabID else { return true }
		guard let activeComposeTabID else { return false }
		return sessionComposeTabID == activeComposeTabID
	}

	@MainActor
	private func refreshSessionChatControlsFromLivePromptState(for sessionID: UUID) {
		guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
		sessions[index].preferredAIModel = promptViewModel.preferredModel
		sessions[index].selectedChatPresetID = promptViewModel.selectedChatPresetID
	}
	
	@MainActor
	private func registerMessage(_ messageId: UUID, sessionID: UUID) {
		sessionIDByMessageId[messageId] = sessionID
	}
	
	@MainActor
	private func purgeSessionStorage(_ sessionID: UUID) {
		let messageIDs: [UUID]
		if let stored = messageStore.removeValue(forKey: sessionID) {
			messageStoreRevision &+= 1
			messageIDs = stored.map(\.id)
		} else {
			messageIDs = sessionIDByMessageId.filter { $0.value == sessionID }.map(\.key)
		}
		for messageId in messageIDs {
			purgeMessageCaches(for: messageId)
		}
		recentDisplayedSessionIDs.removeAll { $0 == sessionID }
		runStateBySession.removeValue(forKey: sessionID)
		nextSequenceIndexBySession.removeValue(forKey: sessionID)
		clearMCPSessionUIState(for: sessionID)
	}

	@MainActor
	private func purgeMessageCaches(for messageId: UUID) {
		// Message-scoped cleanup only; does not cancel live streams or touch session-level state.
		sessionIDByMessageId.removeValue(forKey: messageId)
		delegateEditTasks.removeValue(forKey: messageId)
		deferredDiffs.removeValue(forKey: messageId)
		launchedDelegateKeysByMessage[messageId] = nil
		aiResponseViewModel.clearResponses(forQueryId: messageId)
		streamIDsByQueryId.removeValue(forKey: messageId)
		cancelFinalizationWatchdog(for: messageId)
		clearStreamActivityTracking(for: messageId)
		ephemeralState.clear(for: messageId)
	}
	
	@MainActor
	private func clearAllSessionStorage() {
		sessionSwitchGeneration += 1
		messageStore.removeAll(keepingCapacity: false)
		messageStoreRevision &+= 1
		sessionIDByMessageId.removeAll(keepingCapacity: false)
		runStateBySession.removeAll(keepingCapacity: false)
		nextSequenceIndexBySession.removeAll(keepingCapacity: false)
		streamingSessions.removeAll()
		pinnedSessionRefCounts.removeAll(keepingCapacity: false)
		recentDisplayedSessionIDs.removeAll(keepingCapacity: false)
		mcpUIStateBySession.removeAll(keepingCapacity: false)
		sessionSwitchInProgressID = nil
		currentQueryId = nil
		recomputeWorkspaceBusyAndFontFreeze()
	}
	
	@MainActor
	private func setSessionStreaming(_ sessionID: UUID, queryId: UUID, streamId: ChatStreamID?) {
		ensureSessionStorage(sessionID)
		runStateBySession[sessionID]?.activeQueryId = queryId
		runStateBySession[sessionID]?.activeStreamId = streamId
		streamingSessions.insert(sessionID)
		
		if currentSessionID == sessionID {
			currentQueryId = queryId
		}
		recomputeWorkspaceBusyAndFontFreeze()
	}
	
	@MainActor
	private func clearSessionStreaming(_ sessionID: UUID) {
		runStateBySession[sessionID]?.activeQueryId = nil
		runStateBySession[sessionID]?.activeStreamId = nil
		streamingSessions.remove(sessionID)
		
		if currentSessionID == sessionID {
			currentQueryId = nil
		}
		recomputeWorkspaceBusyAndFontFreeze()
	}
	
	@MainActor
	private func nextSequenceIndex(for sessionID: UUID) -> Int {
		let next = nextSequenceIndexBySession[sessionID, default: 0]
		nextSequenceIndexBySession[sessionID] = next + 1
		return next
	}
	
	// We use the new static `ChatContentParser`.
	// No parser queue or parseContentImmediately calls are needed.
	private let diffParser: DiffParser
	let chatData: ChatDataService  // Changed from private to let for MCP access
	let workspaceManager: WorkspaceManagerViewModel  // Changed from private to let for MCP access
	
	private let delegateEditTaskManager = DelegateEditTaskManager()
	private let finalisationHub = MessageFinalisationHub()
	
	// Dependencies
	let aiQueriesService: AIQueriesService
	let aiResponseViewModel: AIResponseViewModel
	private let diffViewModel: DiffViewModel
	var promptViewModel: PromptViewModel
	private let delegateEditHandler: DelegateEditQueryHandling
	
	// MARK: - Delegate-edit task helpers
	@MainActor
	func createDelegateEditTask(for queryId: UUID,
								task: DelegateEditTask) {
		guard let sessionID = sessionIDByMessageId[queryId] else { return }
		if delegateEditTasks[queryId] == nil { delegateEditTasks[queryId] = [] }
		let requestKey = DelegateEditItem.buildRequestKey(path: task.resolvedFilePath ?? task.filePath,
														 changes: task.changes)
		delegateEditTasks[queryId]!.removeAll {
			DelegateEditItem.buildRequestKey(path: $0.resolvedFilePath ?? $0.filePath,
											 changes: $0.changes) == requestKey
		}
		delegateEditTasks[queryId]!.append(task)
	
		// also flag the parent message
		withSessionMessages(sessionID) { msgs in
			if let msgIdx = msgs.firstIndex(where: { $0.id == queryId }) {
				msgs[msgIdx].setHasPendingDelegateWork(true)
				msgs[msgIdx].setHasCompletedDelegateWork(false)
			}
		}
	}
	
	@MainActor
	func updateDelegateEditTask(for queryId: UUID,
									taskId: UUID,
									output: String,
									tokenEstimate: Int,
									streamId: UUID? = nil) {
		guard var tasks = delegateEditTasks[queryId],
					let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
		
		tasks[idx].accumulatedOutput = output
		
		// If a streamId is provided, update the per-stream estimate
		if let sid = streamId {
			tasks[idx].tokenEstimatesByStream[sid] = tokenEstimate
			// Recompute total token estimate as sum of all stream estimates
			tasks[idx].tokenEstimate = tasks[idx].tokenEstimatesByStream.values.reduce(0, +)
		} else {
			// Fall back to direct update if no streamId
			tasks[idx].tokenEstimate = tokenEstimate
		}
		
		delegateEditTasks[queryId] = tasks
	}

	@MainActor
	func updateDelegateEditTaskToolUsed(for queryId: UUID,
										taskId: UUID,
										toolName: String) {
		guard var tasks = delegateEditTasks[queryId],
			  let idx = tasks.firstIndex(where: { $0.id == taskId }) else {
			return
		}

		tasks[idx].lastToolUsed = toolName
		delegateEditTasks[queryId] = tasks
	}

	@MainActor
	func finishDelegateEditTask(for queryId: UUID,
								taskId: UUID,
								finalOutput: String,
								status: DelegateEditTask.TaskStatus,
								promptTokens: Int? = nil,
								completionTokens: Int? = nil,
								displayOutput: String? = nil,
								delegateResultOverride: String? = nil) {
		guard let sessionID = sessionIDByMessageId[queryId] else { return }
		guard var tasks = delegateEditTasks[queryId],
				let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
		
		let uiOutput = displayOutput ?? finalOutput
		tasks[idx].accumulatedOutput = uiOutput
		tasks[idx].status            = status
		tasks[idx].promptTokens      = promptTokens      // 🆕
		tasks[idx].completionTokens  = completionTokens  // 🆕
		delegateEditTasks[queryId] = tasks
		
		// push into the AI message for permanent storage
		withSessionMessages(sessionID) { msgs in
			if let mIdx = msgs.firstIndex(where: { $0.id == queryId }) {
				let storedResult = delegateResultOverride ?? finalOutput
				msgs[mIdx].addDelegateResult(taskId, text: storedResult)
				msgs[mIdx].setHasPendingDelegateWork(false)
				msgs[mIdx].setHasCompletedDelegateWork(true)
			}
		}
		
		// NEW: If all delegate edits are done but the stream hasn't finalized, arm a watchdog.
		if isSessionStreaming(sessionID) {
			let stillInFlight = delegateEditTasks[queryId]?.contains {
				switch $0.status {
				case .pending, .inProgress: return true
				default: return false
				}
			} ?? false
			
			if !stillInFlight {
				// Small delay to allow any final stream chunks to arrive naturally.
				scheduleFinalizationWatchdog(for: queryId, delay: afterDelegatesSilence)
			}
		}
	}
	
	// Merge action
	var mergeAction: (() -> Void)?
	
	// NEW: Track which delegate edit tasks are actively streaming
	private var activeDelegateEdits: Set<UUID> = []
	// Track unique delegate-edit requests per AI message to avoid duplicate launches
	private var launchedDelegateKeysByMessage: [UUID: Set<String>] = [:]
	
	// Track the active retry task so it can be properly cancelled
	private var activeRetryTask: Task<Void, Error>? = nil
	
	private var finalizationWatchdogs: [UUID: Task<Void, Never>] = [:]
	private var finalizationWatchdogTokens: [UUID: UUID] = [:]
	private var streamInactivityWatchdogs: [UUID: Task<Void, Never>] = [:]
	/// Prevents duplicate concurrent finalisers for the same assistant message.
	private var finalizingAIResponses: Set<UUID> = []
	private var lastAnyStreamActivityAt: [UUID: Date] = [:]
	private var lastTextStreamActivityAt: [UUID: Date] = [:]
	private var hasSeenNonReasoningText: Set<UUID> = []
	private var providerStopSeen: Set<UUID> = []
	/// Tracks when we last armed the inactivity watchdog per query (for throttling)
	private var lastInactivityWatchdogArmAt: [UUID: Date] = [:]
	/// Minimum interval between watchdog re-arms during streaming (reduces Task churn)
	private let minWatchdogArmInterval: TimeInterval = 1.0
	private let preContentGrace: TimeInterval = 30.0
	private let postContentGrace: TimeInterval = 10.0
	private let delegateActiveMultiplier: Double = 2.0
	private let afterDelegatesSilence: TimeInterval = 4.0
	private let delegateWatchdogRetryDelay: TimeInterval = 1.5
	
	init(
		aiQueriesService: AIQueriesService,
		aiResponseViewModel: AIResponseViewModel,
		diffViewModel: DiffViewModel,
		promptViewModel: PromptViewModel,
		workspaceManager: WorkspaceManagerViewModel,
		chatData: ChatDataService,
		delegateEditHandler: DelegateEditQueryHandling? = nil
	) {
		self.aiQueriesService = aiQueriesService
		self.aiResponseViewModel = aiResponseViewModel
		self.diffViewModel = diffViewModel
		self.promptViewModel = promptViewModel
		self.diffParser = DiffParser(fileManager: promptViewModel.fileManager)
		self.workspaceManager = workspaceManager
		self.chatData = chatData
		self.lastDelegateEditItems = []
		self.debugMode = false
		self.delegateEditHandler = delegateEditHandler ?? DelegateEditQueryHandler(
			promptVM: promptViewModel,
			aiQueriesService: aiQueriesService,
			diffParser: diffParser,
			taskManager: delegateEditTaskManager)
		
		/*
		// Replace the existing didExitAIQuery subscription in init(...) with:
		aiResponseViewModel.didExitAIQuery
			.debounce(for: .seconds(0.5), scheduler: RunLoop.main)  // wait for 0.5s of silence
			.sink { [weak self] _ in
				guard let self = self else { return }
				Task { @MainActor in
					self.autosaveChatHistory(force: true)
				}
			}
			.store(in: &cancellables)
		*/
		
		// Subscribe to change count updates
		aiResponseViewModel.changeCountDidUpdate
			.debounce(for: .seconds(0.5), scheduler: RunLoop.main)  // debounce to avoid too frequent saves
			.sink { [weak self] messageId in
				guard let self = self else { return }
				Task { @MainActor in
					guard let sessionID = self.sessionIDByMessageId[messageId] else { return }
					self.autosaveChatHistory(for: sessionID)
				}
			}
			.store(in: &cancellables)

// (removed old immediate $inputText sink)

// Debounced input listener – cancels previous attempts automatically
		$inputText
			.debounce(for: .milliseconds(200), scheduler: RunLoop.main)
			.sink { [weak self] _ in
				guard let self else { return }
				self.updateUpcomingInputTokenText()
				self.promptViewModel.MarkDirty()
			}
			.store(in: &cancellables)

		// Refresh estimate when promptVM finishes heavy token recomputation
		promptViewModel.tokenCalculationCompletedPublisher
			.sink { [weak self] _ in
			self?.updateUpcomingInputTokenText()
		}
		.store(in: &cancellables)

		// Re-calculate estimate whenever chat history changes
		$messages
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				guard let self = self else { return }
				// Skip updates during bulk-load or while streaming.
				if !self.isBatchLoadingMessages && !self.isSessionStreaming(self.currentSessionID) {
					self.updateUpcomingInputTokenText()
				}
			}
			.store(in: &cancellables)
		
		// Listen for delegate edit tool usage notifications
		// Note: Subscription is automatically cleaned up when cancellables is released
		NotificationCenter.default.publisher(for: .delegateEditToolUsed)
			.receive(on: RunLoop.main)
			.sink { [weak self] notification in
				guard let self = self,
					let userInfo = notification.userInfo,
					let queryId = userInfo["queryId"] as? UUID,
					let taskId = userInfo["taskId"] as? UUID,
					let toolName = userInfo["toolName"] as? String else {
					return
				}
				self.updateDelegateEditTaskToolUsed(for: queryId, taskId: taskId, toolName: toolName)
			}
			.store(in: &cancellables)
		
		NotificationCenter.default.publisher(for: .activeComposeTabChanged)
			.receive(on: RunLoop.main)
			.sink { [weak self] notification in
				guard let self = self,
					let windowID = notification.userInfo?["windowID"] as? Int,
					windowID == self.promptViewModel.windowID else { return }
				let tabID = notification.userInfo?["tabID"] as? UUID
				Task { [weak self] in
					await self?.handleActiveComposeTabChanged(tabID: tabID)
				}
			}
			.store(in: &cancellables)

		// Initial value
		updateUpcomingInputTokenText()
		
		/*
		self.workspaceManager.addBeforeSaveListener { [weak self] _ in
			guard let self = self else { return }
			self.autosaveChatHistory()
		}
		*/
		
		// Setup workspace switch callback
		// New code using multi-listener approach:
		self.workspaceManager.addWorkspaceDidSwitchListener(label: "chat") { [weak self] newWS in
			guard let self = self else { return }
			Task { [weak self] in
				await self?.handleWorkspaceSwitched(to: newWS)
			}
		}
		
		// Register for tab-close events to cancel running streams before tabs are removed
		tabCloseListenerToken = promptViewModel.addComposeTabsWillCloseListener { [weak self] tabIDs in
			guard let self else { return }
			await self.handleComposeTabsWillClose(tabIDs)
		}
	}
	
	deinit {
		// Cancel all watchdog tasks
		for (_, task) in finalizationWatchdogs {
			task.cancel()
		}
		for (_, task) in streamInactivityWatchdogs {
			task.cancel()
		}
		
		// Cancel background token calculation tasks
		latestTokenCountsTask?.cancel()
		upcomingTokenEstimateTask?.cancel()
		
		// Cancel active retry task
		activeRetryTask?.cancel()
		
		// Cancel any active headless streams and delegate edit tasks
		let headlessStreamIDs = Array(headlessStreamsByTabID.values)
		let chatStreamIDs = Array(streamIDsByQueryId.values)
		let queriesService = aiQueriesService
		let taskManager = delegateEditTaskManager
		Task {
			// Cancel headless streams (plan/question generation)
			for streamID in headlessStreamIDs {
				await queriesService.cancelStream(id: streamID)
			}
			// Cancel any active chat streams
			for streamID in chatStreamIDs {
				await queriesService.cancelStream(id: streamID)
			}
			// Cancel delegate edit tasks
			await taskManager.cancelAllTasks()
		}
	}
	
	// MARK: - Finalization Watchdog (prevents 'stuck in progress' state)
	@MainActor
	private func hasActiveDelegateEdits(for queryId: UUID) -> Bool {
		(delegateEditTasks[queryId]?.contains {
			switch $0.status {
			case .pending, .inProgress:
				return true
			default:
				return false
			}
		}) ?? false
	}
	
	@MainActor
	private func currentInactivityGrace(for queryId: UUID) -> TimeInterval {
		let seenText = hasSeenNonReasoningText.contains(queryId)
		let baseGrace = seenText ? postContentGrace : preContentGrace
		return hasActiveDelegateEdits(for: queryId) ? baseGrace * delegateActiveMultiplier : baseGrace
	}

	@MainActor
	private func scheduleStreamInactivityWatchdog(for queryId: UUID) {
		streamInactivityWatchdogs[queryId]?.cancel()
		let grace = currentInactivityGrace(for: queryId)
		let task = Task { [weak self] in
			guard grace > 0 else { return }
			do {
				try await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
			} catch {
				return
			}
			guard let self else { return }
			await self.handleStreamInactivityTimeout(for: queryId)
		}
		streamInactivityWatchdogs[queryId] = task
	}
	
	@MainActor
	private func cancelStreamInactivityWatchdog(for queryId: UUID) {
		streamInactivityWatchdogs[queryId]?.cancel()
		streamInactivityWatchdogs[queryId] = nil
	}
	
	/// Throttled watchdog arm: only re-arms if enough time has passed since the last arm.
	/// This dramatically reduces Task allocations/cancellations during fast streaming.
	@MainActor
	private func armStreamInactivityWatchdogThrottled(for queryId: UUID, now: Date = Date()) {
		let lastArm = lastInactivityWatchdogArmAt[queryId] ?? .distantPast
		guard now.timeIntervalSince(lastArm) >= minWatchdogArmInterval else { return }
		lastInactivityWatchdogArmAt[queryId] = now
		scheduleStreamInactivityWatchdog(for: queryId)
	}
	
	@MainActor
	private func clearStreamActivityTracking(for queryId: UUID) {
		cancelStreamInactivityWatchdog(for: queryId)
		lastAnyStreamActivityAt.removeValue(forKey: queryId)
		lastTextStreamActivityAt.removeValue(forKey: queryId)
		lastInactivityWatchdogArmAt.removeValue(forKey: queryId)
		hasSeenNonReasoningText.remove(queryId)
		providerStopSeen.remove(queryId)
	}
	
	@MainActor
	private func handleStreamInactivityTimeout(for queryId: UUID) async {
		guard let sessionID = sessionIDByMessageId[queryId],
				isSessionStreaming(sessionID),
				let idx = messageStore[sessionID]?.firstIndex(where: { $0.id == queryId && !$0.isUser }),
				let message = messageStore[sessionID]?[idx],
				!message.isFinalized else {
			streamInactivityWatchdogs[queryId] = nil
			return
		}
		
		if providerStopSeen.contains(queryId) {
			streamInactivityWatchdogs[queryId] = nil
			return
		}
		
		if !hasSeenNonReasoningText.contains(queryId) {
			// Respect guarantee: never cancel before first non-reasoning token
			scheduleStreamInactivityWatchdog(for: queryId)
			return
		}
		
		if hasActiveDelegateEdits(for: queryId) {
			scheduleStreamInactivityWatchdog(for: queryId)
			return
		}
		
		let lastHeartbeat = lastAnyStreamActivityAt[queryId] ?? lastTextStreamActivityAt[queryId]
		guard let lastAnyActivity = lastHeartbeat else {
			// Missing activity timestamp – be conservative and re-arm
			scheduleStreamInactivityWatchdog(for: queryId)
			return
		}
		
		let elapsed = Date().timeIntervalSince(lastAnyActivity)
		let grace = currentInactivityGrace(for: queryId)
		if elapsed < grace {
			scheduleStreamInactivityWatchdog(for: queryId)
			return
		}
		
		// Targeted cancel for this specific stream
		if let streamId = streamIDsByQueryId[queryId] {
			await aiQueriesService.cancelStream(id: streamId)
			streamIDsByQueryId.removeValue(forKey: queryId)
		}
		let content = message.combinedText
		cancelFinalizationWatchdog(for: queryId)
		clearStreamActivityTracking(for: queryId)
		Task {
			await self.finalizeAIResponse(aiResponseId: queryId, sessionID: sessionID, partialBuffer: content)
		}
	}
	
	@MainActor
	private func finalizationWatchdogDimensions(
		for queryId: UUID,
		status: String,
		outcome: String? = nil
	) -> EditFlowPerf.Dimensions {
		EditFlowPerf.Dimensions(
			status: status,
			outcome: outcome,
			taskCount: delegateEditTasks[queryId]?.count ?? 0,
			activeCount: finalizationWatchdogs.count
		)
	}

	@MainActor
	private func scheduleFinalizationWatchdog(for queryId: UUID, delay: TimeInterval = 1.5) {
		guard finalizationWatchdogs[queryId] == nil else {
			EditFlowPerf.event(
				EditFlowPerf.Stage.Delegate.watchdogSkip,
				finalizationWatchdogDimensions(for: queryId, status: "skipped_existing")
			)
			return
		}

		let token = UUID()
		finalizationWatchdogTokens[queryId] = token
		let task = Task { [weak self] in
			guard delay > 0 else {
				guard let self else { return }
				_ = self.completeFinalizationWatchdog(
					for: queryId,
					token: token,
					status: "zero_delay",
					shouldFire: false
				)
				return
			}
			do {
				try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			} catch {
				return
			}
			guard let self else { return }
			let shouldFire = self.completeFinalizationWatchdog(
				for: queryId,
				token: token,
				status: "fired",
				shouldFire: true
			)
			guard shouldFire else { return }
			await self.finalizationWatchdogFired(for: queryId)
		}
		finalizationWatchdogs[queryId] = task
		EditFlowPerf.event(
			EditFlowPerf.Stage.Delegate.watchdogArm,
			finalizationWatchdogDimensions(for: queryId, status: "armed")
		)
	}

	@MainActor
	private func completeFinalizationWatchdog(
		for queryId: UUID,
		token: UUID,
		status: String,
		shouldFire: Bool
	) -> Bool {
		guard finalizationWatchdogTokens[queryId] == token else {
			EditFlowPerf.event(
				EditFlowPerf.Stage.Delegate.watchdogComplete,
				finalizationWatchdogDimensions(for: queryId, status: "stale")
			)
			return false
		}
		finalizationWatchdogs[queryId] = nil
		finalizationWatchdogTokens[queryId] = nil
		EditFlowPerf.event(
			EditFlowPerf.Stage.Delegate.watchdogComplete,
			finalizationWatchdogDimensions(for: queryId, status: status)
		)
		return shouldFire
	}

	@MainActor
	private func cancelFinalizationWatchdog(for queryId: UUID) {
		guard let task = finalizationWatchdogs.removeValue(forKey: queryId) else { return }
		task.cancel()
		finalizationWatchdogTokens[queryId] = nil
		EditFlowPerf.event(
			EditFlowPerf.Stage.Delegate.watchdogCancel,
			finalizationWatchdogDimensions(for: queryId, status: "cancelled")
		)
	}

	@MainActor
	private func finalizationWatchdogFired(for queryId: UUID) async {
		// If already finished, nothing to do
		guard let sessionID = sessionIDByMessageId[queryId],
				isSessionStreaming(sessionID),
				let idx = messageStore[sessionID]?.firstIndex(where: { $0.id == queryId }),
				let message = messageStore[sessionID]?[idx],
				!message.isFinalized else {
			finalizationWatchdogs[queryId] = nil
			finalizationWatchdogTokens[queryId] = nil
			return
		}
		
		if providerStopSeen.contains(queryId) {
			finalizationWatchdogs[queryId] = nil
			finalizationWatchdogTokens[queryId] = nil
			return
		}
		
		if !hasSeenNonReasoningText.contains(queryId) {
			scheduleFinalizationWatchdog(for: queryId, delay: afterDelegatesSilence)
			return
		}
		
		if hasActiveDelegateEdits(for: queryId) {
			scheduleFinalizationWatchdog(for: queryId, delay: delegateWatchdogRetryDelay)
			return
		}
		
		let lastActivityCandidate = lastAnyStreamActivityAt[queryId] ?? lastTextStreamActivityAt[queryId]
		guard let lastActivity = lastActivityCandidate else {
			scheduleFinalizationWatchdog(for: queryId, delay: afterDelegatesSilence)
			return
		}
		
		let elapsed = Date().timeIntervalSince(lastActivity)
		if elapsed < afterDelegatesSilence {
			let remaining = max(afterDelegatesSilence - elapsed, delegateWatchdogRetryDelay)
			scheduleFinalizationWatchdog(for: queryId, delay: remaining)
			return
		}
		
		// Stream likely stuck. Cancel upstream and finalize with current content.
		// Targeted cancel for this specific stream
		if let streamId = streamIDsByQueryId[queryId] {
			await aiQueriesService.cancelStream(id: streamId)
			streamIDsByQueryId.removeValue(forKey: queryId)
		}
		let content = message.combinedText

		// Clear the watchdogs to avoid double-finalization races
		cancelFinalizationWatchdog(for: queryId)
		clearStreamActivityTracking(for: queryId)

		Task {
			await self.finalizeAIResponse(aiResponseId: queryId, sessionID: sessionID, partialBuffer: content)
		}
	}
	
	// MARK: - Message Finalisation
nonisolated func waitUntilMessageFinalised(_ id: UUID) async throws {
	let messageState = await MainActor.run { () -> Bool? in
		guard let sessionID = self.sessionIDByMessageId[id],
				let messages = self.messageStore[sessionID],
				let message = messages.first(where: { $0.id == id }) else {
			return nil
		}
		return message.isFinalized
	}
	if messageState == nil {
		return
	}
	if messageState == true {
		return
	}
	let hubCompleted = await finalisationHub.isCompleted(id)
	if hubCompleted {
		return
	}
	
	// Use withTaskCancellationHandler to properly handle cancellation
	await withTaskCancellationHandler {
		await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
			Task { await finalisationHub.register(id, cont: cont) }
		}
	} onCancel: {
		// If cancelled, notify the hub to clean up this waiter
		Task { await finalisationHub.cancel(id) }
	}
	try Task.checkCancellation()
}
	
	// MARK: - Externally Used Methods
	func setMergeAction(_ action: @escaping () -> Void) {
		self.mergeAction = action
	}
	
	@MainActor
	func setupSendPromptAction() {
		promptViewModel.sendPromptAction = { [weak self] in
			Task { [weak self] in
				guard let self = self else { return }
				await self.sendPromptFromPromptViewModel()
			}
		}
	}
	
	/// Deletes the given session from disk and memory, mimicking the old logic.
	/// 1) If it has a file URL, we remove the file from disk via `chatData`.
	/// 2) Animate removal from `sessions`.
	/// 3) If this was the current session, switch to another or create a new one.
	@MainActor
	func deleteSession(_ session: ChatSession) async {
		sessionSwitchGeneration += 1
		if isSessionStreaming(session.id) {
			await cancelAIResponse(in: session.id, skipPartialParseAndSave: true)
		}
		clearMCPSessionUIState(for: session.id)
		// 1) Attempt to delete file from disk (if it exists).
		if let fileURL = session.fileURL {
			do {
				// Ensure we do it on background or in an actor
				try await chatData.deleteChatSessionFile(fileURL)
			} catch {
				print("Error deleting chat session file: \(error)")
			}
		}
		
		// 2) Remove from in-memory list with animation on the main actor
		withAnimation {
			guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
			purgeSessionStorage(session.id)
			sessions.remove(at: idx)
			
			if let tabID = session.composeTabID,
				workspaceManager.activeChatSessionID(forTabID: tabID) == session.id {
				let replacement = sessions
					.filter { $0.composeTabID == tabID }
					.sorted(by: { $0.savedAt > $1.savedAt })
					.first
				workspaceManager.setActiveChatSessionID(replacement?.id, forTabID: tabID)
			}
			
			// If the deleted session was active, pick a new session or create one
			if session.id == currentSessionID {
				Task { [weak self] in
					await self?.ensureActiveSessionForCurrentTab(createIfMissing: true)
				}
			}
		}
	}
	
	// MARK: - Clearing All Chats
	@MainActor
	func clearAllChats() async {
		await cancelAllActiveSessionStreams()
		// 1) Identify the currently active workspace
		guard let activeWS = workspaceManager.activeWorkspace else {
			print("No active workspace found; nothing to clear.")
			return
		}
		
		// 2) Delete chat JSON files only for this workspace
		do {
			let files = try await chatData.listChatSessions(for: activeWS)
			for file in files {
				try await chatData.deleteChatSessionFile(file)
			}
		} catch {
			print("Error clearing chats for workspace \(activeWS.name): \(error)")
		}
		
		// 3) Remove from memory all sessions belonging to the active workspace
		sessions.removeAll()
		dropMessagesSafely()
		cleanupShadowHolders()
		clearAllSessionStorage()
		currentSessionID = nil
		
		if let workspace = workspaceManager.activeWorkspace {
			for tab in workspace.composeTabs {
				workspaceManager.setActiveChatSessionID(nil, forTabID: tab.id)
			}
		}
		
		await startNewChatSession()
	}
	
	@MainActor
	private func handleActiveComposeTabChanged(tabID: UUID?) async {
		refreshSessionLists()
		guard !isSwitchingTabsForSession else { return }
		guard tabID != nil else { return }
		_ = await ensureActiveSessionForCurrentTab(createIfMissing: true)
	}
	
	@MainActor
	@discardableResult
	func ensureActiveSessionForCurrentTab(createIfMissing: Bool = true) async -> UUID? {
		guard let tabID = promptViewModel.activeComposeTabID else { return nil }
		
		if let activeID = workspaceManager.activeChatSessionID(forTabID: tabID),
			sessions.contains(where: { $0.id == activeID }) {
			await switchToSession(activeID, setActiveForTab: false)
			return activeID
		}
		
		if let candidate = sessions(forTabID: tabID)
			.sorted(by: { $0.savedAt > $1.savedAt })
			.first {
			workspaceManager.setActiveChatSessionID(candidate.id, forTabID: tabID)
			await switchToSession(candidate.id, setActiveForTab: false)
			return candidate.id
		}
		
		guard createIfMissing else { return nil }
		await startNewChatSession(tabID: tabID)
		return currentSessionID
	}
	
	@MainActor
	@discardableResult
	func ensureSessionLoadedForBackground(_ session: ChatSession) async -> ChatSession? {
		let needsLoad = sessionNeedsMessageLoad(session)
		guard needsLoad else { return session }
		
		var resolved = session
		if session.isListStub, let fileURL = session.fileURL {
			do {
				resolved = try await chatData.loadChatSession(from: fileURL)
			} catch {
				print("Warning: Failed to load full session for background use: \(error)")
				return nil
			}
		}
		
		if let idx = sessions.firstIndex(where: { $0.id == resolved.id }) {
			sessions[idx] = resolved
		}
		await reloadSessionFromMemory(resolved)
		return resolved
	}
	
	@MainActor
	func ensureTabForSession(_ session: ChatSession) async -> UUID? {
		if let tabID = session.composeTabID,
			workspaceManager.composeTab(with: tabID) != nil {
			return tabID
		}
		
		guard let newTab = await promptViewModel.createBackgroundComposeTab(
			strategy: .blank,
			name: session.name
		) else { return nil }
		
		var updatedTab = newTab
		updatedTab.selection = StoredSelection(
			selectedPaths: session.selectedFilePaths,
			autoCodemapPaths: [],
			slices: [:],
			codemapAutoEnabled: true
		)
		// Note: Chat session prompt IDs are managed separately from compose tab meta prompts.
		// Don't write session.selectedPromptIDs into tab.selectedMetaPromptIDs as they are
		// different concepts (chat prompts vs copy/clipboard meta prompts).
		updatedTab.activeSubView = nil
		workspaceManager.updateComposeTabStoredOnly(updatedTab)
		
		if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
			sessions[idx].composeTabID = updatedTab.id
			refreshSessionLists()
			Task { [weak self] in
				guard let self else { return }
				_ = try? await self.autosaveSession(self.sessions[idx])
			}
		}
		
		return updatedTab.id
	}
	
	@MainActor
	func assignSession(_ sessionID: UUID, toTabID tabID: UUID, setActiveForTab: Bool) async {
		guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
		sessions[idx].composeTabID = tabID
		refreshSessionLists()
		if setActiveForTab {
			workspaceManager.setActiveChatSessionID(sessionID, forTabID: tabID)
		}
		Task { [weak self] in
			guard let self else { return }
			_ = try? await self.autosaveSession(self.sessions[idx])
		}
	}

	// MARK: - Workspace Switch Handling
	@MainActor
	private func handleWorkspaceSwitched(to newWorkspace: WorkspaceModel?) async {
		workspaceChatSessionLoadGeneration += 1
		let chatSessionLoadGeneration = workspaceChatSessionLoadGeneration

		#if DEBUG
		let chatWorkspaceSwitchStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		WorkspaceRestorePerfLog.event(
			"chat.workspaceSwitch.begin",
			fields: [
				"workspaceID": WorkspaceRestorePerfLog.shortID(newWorkspace?.id),
				"hasWorkspace": "\(newWorkspace != nil)",
				"sessionsBefore": "\(sessions.count)",
				"currentSessionID": WorkspaceRestorePerfLog.shortID(currentSessionID)
			]
		)
		#endif
		// If there's no new workspace, clear sessions or do fallback
		guard let workspace = newWorkspace else {
			// Clear sessions
			#if DEBUG
			let clearStateStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
			#endif
			self.sessions.removeAll()
			self.dropMessagesSafely()
			self.cleanupShadowHolders()
			self.clearAllSessionStorage()
			self.currentSessionID = nil
			#if DEBUG
			WorkspaceRestorePerfLog.event(
				"chat.workspaceSwitch.clearState",
				fields: [
					"workspaceID": WorkspaceRestorePerfLog.shortID(nil),
					"duration": clearStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
			WorkspaceRestorePerfLog.event(
				"chat.workspaceSwitch.end",
				fields: [
					"workspaceID": WorkspaceRestorePerfLog.shortID(nil),
					"sessionsAfter": "\(sessions.count)",
					"currentSessionID": WorkspaceRestorePerfLog.shortID(currentSessionID),
					"outcome": "clearedNoWorkspace",
					"duration": chatWorkspaceSwitchStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
			#endif
			return
		}
		
		// 1) Clear any current sessions
		#if DEBUG
		let clearStateStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		#endif
		self.sessions.removeAll()
		self.dropMessagesSafely()
		self.cleanupShadowHolders()
		self.clearAllSessionStorage()
		self.currentSessionID = nil
		#if DEBUG
		WorkspaceRestorePerfLog.event(
			"chat.workspaceSwitch.clearState",
			fields: [
				"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
				"duration": clearStateStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
			]
		)
		#endif
		
		// 2) Load all sessions from the newly active workspace's Chats/ folder
		#if DEBUG
		var listedFiles: [URL] = []
		let listSessionsStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		#endif
		do {
			let files = try await chatData.listChatSessions(for: workspace)
			#if DEBUG
			listedFiles = files
			#endif
			#if DEBUG
			WorkspaceRestorePerfLog.event(
				"chat.workspaceSwitch.listSessions",
				fields: [
					"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
					"fileCount": "\(files.count)",
					"outcome": "success",
					"duration": listSessionsStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
			#endif
			#if DEBUG
			let loadStubsStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
			#endif
			let batch = await chatData.loadChatSessionStubs(
				from: files,
				maxConcurrent: workspaceSwitchChatStubLoadConcurrency
			)

			guard chatSessionLoadGeneration == workspaceChatSessionLoadGeneration,
				workspaceManager.activeWorkspace?.id == workspace.id else {
				#if DEBUG
				WorkspaceRestorePerfLog.event(
					"chat.workspaceSwitch.loadStubs",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"fileCount": "\(files.count)",
						"loaded": "\(batch.loadedCount)",
						"failed": "\(batch.failedCount)",
						"mode": "boundedConcurrent",
						"concurrencyLimit": "\(workspaceSwitchChatStubLoadConcurrency)",
						"outcome": "staleDiscarded",
						"duration": loadStubsStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				WorkspaceRestorePerfLog.event(
					"chat.workspaceSwitch.end",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"sessionsAfter": "\(sessions.count)",
						"currentSessionID": WorkspaceRestorePerfLog.shortID(currentSessionID),
						"outcome": "staleDiscarded",
						"duration": chatWorkspaceSwitchStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				#endif
				return
			}

			for failure in batch.failures {
				print("Could not load session at \(failure.fileURL): \(failure.message)")
			}
			sessions = batch.sessions
			#if DEBUG
			WorkspaceRestorePerfLog.event(
				"chat.workspaceSwitch.loadStubs",
				fields: [
					"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
					"fileCount": "\(batch.requestedCount)",
					"loaded": "\(batch.loadedCount)",
					"failed": "\(batch.failedCount)",
					"mode": "boundedConcurrent",
					"concurrencyLimit": "\(workspaceSwitchChatStubLoadConcurrency)",
					"outcome": "success",
					"duration": loadStubsStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
			#endif
		} catch {
			#if DEBUG
			WorkspaceRestorePerfLog.event(
				"chat.workspaceSwitch.listSessions",
				fields: [
					"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
					"fileCount": "\(listedFiles.count)",
					"outcome": "error",
					"duration": listSessionsStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
			#endif
			print("Error listing chat sessions in new workspace: \(error)")
		}
		
		guard chatSessionLoadGeneration == workspaceChatSessionLoadGeneration,
			workspaceManager.activeWorkspace?.id == workspace.id else {
			#if DEBUG
			WorkspaceRestorePerfLog.event(
				"chat.workspaceSwitch.end",
				fields: [
					"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
					"sessionsAfter": "\(sessions.count)",
					"currentSessionID": WorkspaceRestorePerfLog.shortID(currentSessionID),
					"outcome": "staleBeforeEnsureActiveSession",
					"duration": chatWorkspaceSwitchStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
			#endif
			return
		}

		// The call below will create a fresh "New Chat". We do NOT want to
		// autosave that blank session immediately, otherwise it would clobber
		// the workspace’s restored file selection.  Set a one-shot guard flag.
		skipAutosaveCurrentSessionOnce = true

		#if DEBUG
		let ensureActiveSessionStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		#endif
		await ensureActiveSessionForCurrentTab(createIfMissing: true)
		#if DEBUG
		WorkspaceRestorePerfLog.event(
			"chat.workspaceSwitch.ensureActiveSession",
			fields: [
				"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
				"duration": ensureActiveSessionStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
			]
		)
		WorkspaceRestorePerfLog.event(
			"chat.workspaceSwitch.end",
			fields: [
				"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
				"sessionsAfter": "\(sessions.count)",
				"currentSessionID": WorkspaceRestorePerfLog.shortID(currentSessionID),
				"outcome": "completed",
				"duration": chatWorkspaceSwitchStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
			]
		)
		#endif
	}
	
	// MARK: - Session Management
	/// Creates a brand-new ChatSession object, clearing the in-memory messages.
	/// If there’s an old session with unsaved messages, tries to save it first.
	@MainActor
	@discardableResult
	func startNewChatSession(
		name: String = "New Chat",
		tabID: UUID? = nil,
		agentModeSessionID: UUID? = nil,
		agentModeRunID: UUID? = nil,
		activateInUI: Bool = true,
		setActiveForTab: Bool = true
	) async -> UUID? {
		let resolvedTabID = tabID ?? promptViewModel.activeComposeTabID
		
		// If there's already a blank session with that name, just switch to it
		if let existingIndex = sessions.firstIndex(where: {
			$0.name == name &&
			$0.effectiveMessageCount == 0 &&
			$0.composeTabID == resolvedTabID &&
			$0.agentModeSessionID == agentModeSessionID &&
			$0.agentModeRunID == agentModeRunID
		}) {
			let existingID = sessions[existingIndex].id
			if setActiveForTab, let resolvedTabID {
				workspaceManager.setActiveChatSessionID(existingID, forTabID: resolvedTabID)
			}
			if activateInUI {
				currentSessionID = existingID
				setDisplayedSession(existingID)
				promptViewModel.selectedPromptIDsForChat.removeAll()
				promptViewModel.updateSelectedInstructions()
				unloadNonCurrentSessions()
			}
			return existingID
		}

		// Attempt saving the existing session if we have unsaved messages
		if let existingSession = currentSession {
			let hasMessages = !(messageStore[existingSession.id]?.isEmpty ?? messages.isEmpty)
			if hasMessages && !isSessionStreaming(existingSession.id) {
				autosaveChatHistory(for: existingSession.id, force: true)
			}
		}

		if activateInUI {
			promptViewModel.selectedPromptIDsForChat.removeAll()
			promptViewModel.updateSelectedInstructions()
		}

		// Capture current selections so the session restores them later
		let currentSelectedPaths: [String]
		let currentSelectedPrompts: [UUID]
		if !activateInUI, let resolvedTabID,
			let tab = workspaceManager.composeTab(with: resolvedTabID) {
			currentSelectedPaths = tab.selection.selectedPaths
			currentSelectedPrompts = tab.selectedMetaPromptIDs
		} else {
			currentSelectedPaths = promptViewModel.fileManager.selectedFiles.map { $0.fullPath }
			currentSelectedPrompts = Array(promptViewModel.selectedPromptIDs)
		}
		let preferredModelName     = promptViewModel.preferredModel
		let selectedChatPresetId   = promptViewModel.selectedChatPresetID

		let newSession = ChatSession(
			workspaceID: workspaceManager.activeWorkspace?.id,
			composeTabID: resolvedTabID,
			agentModeSessionID: agentModeSessionID,
			agentModeRunID: agentModeRunID,
			name: name,
			selectedFilePaths: currentSelectedPaths,
			selectedPromptIDs: currentSelectedPrompts,
			preferredAIModel: preferredModelName,
			selectedChatPresetID: selectedChatPresetId
		)
		sessions.append(newSession)
		if setActiveForTab, let resolvedTabID {
			workspaceManager.setActiveChatSessionID(newSession.id, forTabID: resolvedTabID)
		}
		ensureSessionStorage(newSession.id)
		if activateInUI {
			currentSessionID = newSession.id
			// Clear messages but preserve ephemeral state
			dropMessagesSafely()
			setDisplayedSession(newSession.id)
			updateLatestTokenCounts()
			// Unload non-current sessions to reduce memory pressure
			unloadNonCurrentSessions()
		}
		return newSession.id
	}
	
	// MARK: - Clone Sessions for Agent Fork

	/// Clones all tab-scoped chat sessions (Oracle) from one compose tab to another.
	/// Creates deep copies with new IDs, sets `composeTabID` to the destination, persists them,
	/// and optionally sets the destination tab's active chat session to the clone of the source's active session.
	///
	/// - Parameters:
	///   - sourceTabID: The compose tab to copy sessions from.
	///   - destTabID: The compose tab to copy sessions into.
	///   - setActiveSessionToClonedSourceActive: When true (default), sets the destination tab's
	///     `activeChatSessionID` to the clone of the source tab's active chat session.
	/// - Returns: A mapping of source session ID → cloned session ID.
	@MainActor
	@discardableResult
	func cloneChatSessions(
		fromTabID sourceTabID: UUID,
		toTabID destTabID: UUID,
		setActiveSessionToClonedSourceActive: Bool = true
	) async throws -> [UUID: UUID] {
		let sourceSessions = sessions(forTabID: sourceTabID)
		guard !sourceSessions.isEmpty else { return [:] }

		let sourceActiveID = workspaceManager.activeChatSessionID(forTabID: sourceTabID)
		var idMapping: [UUID: UUID] = [:]

		for sourceSession in sourceSessions {
			// Force-load the full session to avoid copying empty stubs
			guard let fullSession = await ensureSessionLoadedForBackground(sourceSession) else {
				print("[ChatVM] Warning: skipping session \(sourceSession.id) (\(sourceSession.name)) during fork clone — could not load")
				continue
			}

			let clonedID = UUID()

			// StoredMessage is a value type — copy directly.
			// Use the fully-loaded session's messages (StoredMessage) rather than
			// the live messageStore (AIChatMessage) since we're creating a ChatSession.
			var cloned = ChatSession(
				id: clonedID,
				workspaceID: fullSession.workspaceID,
				composeTabID: destTabID,
				// Handoff clones become destination-tab legacy history. Keeping source
				// Agent Mode ownership would hide them from the destination owner-filtered UI.
				agentModeSessionID: nil,
				agentModeRunID: nil,
				name: fullSession.name,
				savedAt: Date(),
				fileURL: nil,
				messages: fullSession.messages,
				changedFilesByMessage: fullSession.changedFilesByMessage,
				delegateEditItemsByMessage: fullSession.delegateEditItemsByMessage,
				selectedFilePaths: fullSession.selectedFilePaths,
				selectedPromptIDs: fullSession.selectedPromptIDs,
				preferredAIModel: fullSession.preferredAIModel,
				selectedChatPresetID: fullSession.selectedChatPresetID
			)

			// Persist the clone and capture the file URL so the stub can resolve it later
			do {
				let url = try await autosaveSession(cloned)
				cloned.fileURL = url
			} catch {
				print("[ChatVM] Warning: failed to persist cloned session \(clonedID): \(error)")
				continue
			}

			// Register as a list stub in memory (lazy-loaded when activated)
			sessions.append(cloned.listStub())
			idMapping[fullSession.id] = clonedID
		}

		// Set destination tab's active chat session to the clone of the source active.
		// If the source active wasn't cloned (or was nil), fall back to the first clone
		// to prevent ensureActiveSessionForCurrentTab from creating a blank "New Chat".
		if setActiveSessionToClonedSourceActive, !idMapping.isEmpty {
			let clonedActive: UUID
			if let srcActive = sourceActiveID, let mapped = idMapping[srcActive] {
				clonedActive = mapped
			} else {
				// Deterministic fallback: use the clone of the first source session
				clonedActive = idMapping[sourceSessions.first!.id] ?? idMapping.values.first!
			}
			workspaceManager.setActiveChatSessionID(clonedActive, forTabID: destTabID)
		}

		refreshSessionLists()
		return idMapping
	}

	/// Forks the current chat session from the specified message ID.
	@MainActor
	func forkChatSession(from messageId: UUID) async {
		guard let originalSession = currentSession else {
			print("Error: No current session to fork from.")
			return
		}
		
		// Find the index of the message to fork from
		let liveMessages = messageStore[originalSession.id] ?? messages
		guard let forkMessageIndex = liveMessages.firstIndex(where: { $0.id == messageId }) else {
			print("Error: Could not find the message to fork from in the current session.")
			return
		}
		
		// Ensure the original session is saved before forking
		do {
			try await autosaveSession(originalSession)
		} catch {
			print("Warning: Failed to save original session before forking: \(error)")
			// Continue anyway, but log the warning
		}
		
		// Create the list of messages for the new session (up to and including the fork point)
		let messagesToCopy = Array(liveMessages.prefix(through: forkMessageIndex)).map { msg in
			StoredMessage(
				id: msg.id,
				isUser: msg.isUser,
				rawText: msg.content,
				timestamp: Date(),
				delegateResults: msg.delegateResults,
				sequenceIndex: msg.sequenceIndex,
				allowedFilePaths: msg.allowedFilePaths.isEmpty ? nil : msg.allowedFilePaths,
				promptTokens: msg.promptTokens,
				completionTokens: msg.completionTokens,
				cost: msg.cost,
				modelName: msg.modelName
			)
		}
		
		// Determine a unique name for the forked session
		// First, extract the base name by removing any existing fork indicators
		let baseName: String
		let existingForkMatch = originalSession.name.range(of: #" \(Forked(?: \d+)?\)$"#, options: .regularExpression)
		if let match = existingForkMatch {
			baseName = String(originalSession.name[..<match.lowerBound])
		} else {
			baseName = originalSession.name
		}
		
		// Find the highest fork count for this base name
		var maxForkCount = 0
		for session in sessions {
			if session.name == baseName {
				// Base name exists without fork indicator
				maxForkCount = max(maxForkCount, 0)
			} else if session.name.hasPrefix(baseName + " (Forked") {
				// Extract the fork count from the name
				if session.name == baseName + " (Forked)" {
					maxForkCount = max(maxForkCount, 1)
				} else if let countMatch = session.name.range(of: #"\(Forked (\d+)\)$"#, options: .regularExpression) {
					let countStr = session.name[countMatch].dropFirst("(Forked ".count).dropLast(")".count)
					if let count = Int(countStr) {
						maxForkCount = max(maxForkCount, count)
					}
				}
			}
		}
		
		// Create the new name with the next fork count
		let nextForkCount = maxForkCount + 1
		let newName = nextForkCount == 1 ? "\(baseName) (Forked)" : "\(baseName) (Forked \(nextForkCount))"
		
		// Create the new forked session
		let newSession = ChatSession(
			id: UUID(), // New unique ID
			workspaceID: originalSession.workspaceID,
			composeTabID: originalSession.composeTabID,
			name: newName,
			savedAt: Date(), // Will be updated on save
			fileURL: nil, // New session, no file yet
			messages: messagesToCopy,
			// Copy relevant state from the original session at the fork point
			changedFilesByMessage: originalSession.changedFilesByMessage?.filter { (messageId, _) in
				messagesToCopy.contains { storedMessage in
					storedMessage.id == messageId
				}
			},
			delegateEditItemsByMessage: originalSession.delegateEditItemsByMessage?.filter { (messageId, _) in
				messagesToCopy.contains { storedMessage in
					storedMessage.id == messageId
				}
			},
			selectedFilePaths: originalSession.selectedFilePaths, // Or maybe capture current selection? Decide based on desired UX
			selectedPromptIDs: originalSession.selectedPromptIDs, // Same as above
			preferredAIModel: originalSession.preferredAIModel,
			selectedChatPresetID: originalSession.selectedChatPresetID
		)
		
		// Add the new session to the list and switch to it
		sessions.append(newSession)
		await switchToSession(newSession.id)
		
		// Trigger an autosave for the newly created session
		autosaveChatHistory() // This will save the *new* current session
	}
	
	@MainActor
	func switchToSession(_ id: UUID, setActiveForTab: Bool = true) async {
		guard currentSessionID != id else {
			return
		}
		
		guard let existingSession = sessions.first(where: { $0.id == id }) else { return }
		
		sessionSwitchGeneration += 1
		let switchGeneration = sessionSwitchGeneration
		sessionSwitchInProgressID = id
		defer {
			if sessionSwitchGeneration == switchGeneration {
				sessionSwitchInProgressID = nil
			}
		}
		
		// Autosave – but *skip once* if this is the implicit blank chat that was
		// created right after a workspace switch.
		if skipAutosaveCurrentSessionOnce {
			skipAutosaveCurrentSessionOnce = false        // consume the ticket
		} else {
			if let currentSessionID, !isSessionStreaming(currentSessionID) {
				autosaveChatHistory(for: currentSessionID)
			}
		}
		
		let targetTabID = await ensureTabForSession(existingSession)
		guard sessionSwitchGeneration == switchGeneration else { return }
		if setActiveForTab, let targetTabID {
			workspaceManager.setActiveChatSessionID(id, forTabID: targetTabID)
		}
		
		if let targetTabID,
			promptViewModel.activeComposeTabID != targetTabID {
			isSwitchingTabsForSession = true
			await promptViewModel.switchComposeTab(targetTabID)
			isSwitchingTabsForSession = false
		}
		guard sessionSwitchGeneration == switchGeneration else { return }
		
		let shouldPreload = sessionNeedsMessageLoad(existingSession)
		let resolvedSession: ChatSession
		if shouldPreload {
			guard let loadedSession = await ensureSessionLoadedForBackground(existingSession) else { return }
			guard sessionSwitchGeneration == switchGeneration else { return }
			resolvedSession = loadedSession
		} else {
			resolvedSession = sessions.first(where: { $0.id == id }) ?? existingSession
		}
		
		currentSessionID = id
		setDisplayedSession(id)
		updateLatestTokenCounts()
		updateUpcomingInputTokenText()
		guard sessionSwitchGeneration == switchGeneration else { return }
		await workspaceManager.restoreChatSessionState(resolvedSession, restoreSelection: false)
		guard sessionSwitchGeneration == switchGeneration else { return }
		unloadNonCurrentSessions()
	}
	
	/// Selects a session by its short ID (e.g., "plan-ABC123")
	@MainActor
	func selectSession(byShortID shortID: String) {
		guard let session = sessions.first(where: { $0.shortID == shortID }) else { return }
		Task {
			await switchToSession(session.id)
		}
	}

	@MainActor
	func reloadCurrentSession() async {
		if let currentSessionID, isSessionStreaming(currentSessionID) {
			print("Cannot reload current session while AI streaming is in progress.")
			return
		}
		guard let session = currentSession else {
			print("No current session to reload.")
			return
		}
		
		dropMessagesSafely()
		if let fileURL = session.fileURL {
			await loadChatSession(from: fileURL)
		} else {
			await reloadSessionFromMemory(session)
		}
	}
	
/// Recompute *all* prompt- vs. completion-token totals, divide by 1 000, and show "k" notation
@MainActor
private func updateLatestTokenCounts() {
	// Cancel any in-flight calculation first
	latestTokenCountsTask?.cancel()
	
	// Snapshot the data we need on the main thread first
	let aiMessagesSnapshot  = messages.filter { !$0.isUser }
	
	// Spawn the heavy work in background and keep a handle
	let task = Task.detached { [weak self] in
		guard let self else { return }
		
		// Filter only messages that already have counts
		let aiMessagesWithCounts = aiMessagesSnapshot.filter {
			$0.promptTokens != nil && $0.completionTokens != nil
		}
		
		// If nothing finalised yet – fallback quickly
		guard !aiMessagesWithCounts.isEmpty else {
			await MainActor.run {
				self.tokenDisplayText = ""
				// Clear handle – finished
				self.latestTokenCountsTask = nil
			}
			return
		}
		
		// Sum tokens & costs
		let totalInput  = aiMessagesWithCounts.reduce(0) { $0 + ($1.promptTokens ?? 0) }
		let totalOutput = aiMessagesWithCounts.reduce(0) { $0 + ($1.completionTokens ?? 0) }
		let totalCost   = aiMessagesWithCounts.compactMap(\.cost).reduce(0, +)
		
		func fmt(_ n: Int) -> String {
			let k = Double(n) / 1_000
			return k.truncatingRemainder(dividingBy: 1) == 0
				? String(format: "%.0f", k)
				: String(format: "%.1f", k)
		}
		let display: String = {
			if totalCost > 0 {
				let costStr = String(format: "%.3f", totalCost)
				return "Total tok: \(fmt(totalInput))k in | \(fmt(totalOutput))k out | ~$\(costStr)"
			} else {
				return "Total Tok: \(fmt(totalInput))k in | \(fmt(totalOutput))k out"
			}
		}()
		
		// Publish back on main thread
		await MainActor.run {
			self.tokenDisplayText = display
			// Clear handle – finished
			self.latestTokenCountsTask = nil
		}
	}
	latestTokenCountsTask = task
}

	// MARK: - Message Cleanup Helpers
	@MainActor
	private func clearMessagesGradually() {
		messageReaper.drain(&messages)
	}
	
	@MainActor
	private func dropMessagesSafely() {
		isBatchLoadingMessages = true
		defer { isBatchLoadingMessages = false }
		let messageIds = Set(messages.map(\.id))
		clearMessagesGradually()
		for id in messageIds {
			if let sessionID = sessionIDByMessageId[id],
				streamingSessions.contains(sessionID) {
				continue
			}
			launchedDelegateKeysByMessage[id] = nil
		}
		// Reserve for upcoming load; avoids thrash on re-fill
		messages.reserveCapacity(512)
	}
	
	@MainActor
	private func cleanupShadowHolders() {
		ephemeralState.clearAll()
		
		// Clean delegate edit tasks for non-surviving message IDs
		let survivingIds = Set(messages.map(\.id))
		delegateEditTasks.keys
			.filter { !survivingIds.contains($0) }
			.forEach { delegateEditTasks.removeValue(forKey: $0) }
		
		// Clear deferred diffs
		deferredDiffs.removeAll(keepingCapacity: false)
	}

	@MainActor
	private func unloadNonCurrentSessions() {
		guard let currentSessionID else { return }
		let pinnedSessions = Set(pinnedSessionRefCounts.keys)
		let recentSessions = Set(recentDisplayedSessionIDs.prefix(recentDisplayedSessionLimit))
		let protectedSessions = Set([currentSessionID]).union(streamingSessions).union(pinnedSessions).union(recentSessions)

		for idx in sessions.indices {
			guard !protectedSessions.contains(sessions[idx].id) else { continue }
			// Only stub sessions that have a fileURL (so they can be reloaded)
			guard sessions[idx].fileURL != nil else { continue }
			// Skip sessions that are already stubs
			guard !sessions[idx].isListStub else { continue }

			sessions[idx] = sessions[idx].listStub()
		}
		
		for sessionID in messageStore.keys where !protectedSessions.contains(sessionID) {
			purgeSessionStorage(sessionID)
		}
	}
	
	// MARK: - Load/Save from Disk
	/// Loads the specified file (a ChatSession JSON) from disk, then updates in-memory.
	func loadChatSession(from fileURL: URL) async {
		do {
			let session = try await chatData.loadChatSession(from: fileURL)
			if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
				sessions[idx] = session
			} else {
				sessions.append(session)
			}
			currentSessionID = session.id
			await reloadSessionFromMemory(session)
			unloadNonCurrentSessions()
			promptViewModel.MarkDirty()
		} catch {
			print("Error loading chat session: \(error)")
		}
	}
	
	/// Helper struct to aggregate parsing results before the final UI update
	private struct ParsedAIContent {
		let messageId: UUID
		let parsedItems: [ContentItem]
		let coreContent: String
		let parsedFiles: [ParsedFile]
	}
	
	// Add a helper that processes ParsedAIContent -> (ParsedAIContent, [FileChanges], [String: String], [DiffProcessingHelper.DiffProcessingFailure])
	private static nonisolated func processParsedFiles(
		_ content: ParsedAIContent,
		_ session: ChatSession,
		fileManager: RepoFileManagerViewModel,
		diffPrecision: DiffPrecision,
		delegateEditItems: [DelegateEditItem] = []
	) async -> (ParsedAIContent, [FileChanges], [String: String], [DiffProcessingHelper.DiffProcessingFailure], [ChangedFileState]) {
		let messageFileStates = session.changedFilesByMessage?[content.messageId] ?? []
		let (localFileChanges, localOverrideDict, failures, changedStates) = await Self.buildFileChanges(
			parsedFiles: content.parsedFiles,
			messageFileStates: messageFileStates,
			fileManager: fileManager,
			diffPrecision: diffPrecision,
			delegateEditItems: delegateEditItems
		)
		
		return (content, localFileChanges, localOverrideDict, failures, changedStates)
	}
	
	@MainActor
	private func reloadSessionFromMemory(_ session: ChatSession) async {
		let shouldAffectDisplayed = (session.id == currentSessionID)
		if shouldAffectDisplayed {
			// Clear existing messages first but maintain ephemeral state
			isBatchLoadingMessages = true
			clearMessagesGradually()
		}
		
		// Sort messages by sequence index
		let sortedMessages = session.messages.sorted { $0.sequenceIndex < $1.sequenceIndex }
		nextSequenceIndexBySession[session.id] = (sortedMessages.map { $0.sequenceIndex }.max() ?? -1) + 1
		
		// Parse messages in parallel
		var newMessages = [AIChatMessage]()
		await withTaskGroup(of: AIChatMessage?.self) { group in
			for storedMsg in sortedMessages {
				group.addTask {
					return await Self.parseSingleRawMessage(storedMsg)
				}
			}
			for await parsedResult in group {
				if let parsedMessage = parsedResult {
					newMessages.append(parsedMessage)
				}
			}
		}
		
		let newSortedMessages = newMessages.sorted { $0.sequenceIndex < $1.sequenceIndex }
		if let existing = messageStore[session.id] {
			for message in existing {
				sessionIDByMessageId.removeValue(forKey: message.id)
			}
		}
		messageStore[session.id] = newSortedMessages
		messageStoreRevision &+= 1
		for msg in newSortedMessages {
			registerMessage(msg.id, sessionID: session.id)
		}
		
		// Clear AI responses
		if shouldAffectDisplayed {
			aiResponseViewModel.clearResponses()
			currentQueryId = nil
			setDisplayedSession(session.id)
		}
		
		// Restore delegate tasks
		if let editItems = session.delegateEditItemsByMessage {
			for (msgId, storedItems) in editItems {
				let tasks = storedItems.map { storedItem -> DelegateEditTask in
					let newTaskId = UUID()
					let status: DelegateEditTask.TaskStatus = {
						switch storedItem.status {
						case .completed:
							return .completed
						case .noChangesMade:
							return .noChangesMade
						case .partialFailed:
							return .partialFailed(failedCount: storedItem.failedCount ?? 1)
						case .failed:
							return .failed(reason: .streamError)
						}
					}()
					
					let mappedChanges = storedItem.changes.map { c in
						DelegateEditItem.Change(
							description: c.description,
							codeSnippet: c.codeSnippet,
							complexity: c.complexity
						)
					}
					
					return DelegateEditTask(
						id: newTaskId,
						filePath: storedItem.filePath,
						changes: mappedChanges,
						modelDisplayName: storedItem.modelDisplayName ?? "",
						status: status,
						resolvedFilePath: storedItem.resolvedFilePath,
						
						// ▼────────── restored token data ───────────▼
						tokenEstimate: storedItem.tokenEstimate ?? 0,
						promptTokens: storedItem.promptTokens,
						completionTokens: storedItem.completionTokens,
						// ▲──────────────────────────────────────────▲
						
						accumulatedOutput: storedItem.finalOutput ?? ""
					)
				}
				delegateEditTasks[msgId] = tasks
			}
		}
		
		// Gather parse results for AI messages
		let nonUserMessages = sortedMessages.filter { !$0.isUser }
		var parseResults = [ParsedAIContent]()
		
		let captuedDiffParser = diffParser
		
		await withTaskGroup(of: ParsedAIContent?.self) { group in
			for storedMsg in nonUserMessages {
				group.addTask {
					var emptyHashSet = Set<Int>()
					let (parsedItems, coreContent, _) = ChatContentParser.parseContent(
						storedMsg.rawText,
						processedDelegateEditHashes: &emptyHashSet
					)
					
					var parsedFiles: [ParsedFile] = []
					do {
						if parsedItems.contains(where: { $0.type == .file }) {
							parsedFiles = try await captuedDiffParser.parse(storedMsg.combinedRawText)
						}
					} catch {
						print("Error processing file changes for \(storedMsg.id): \(error)")
					}
					
					return ParsedAIContent(
						messageId: storedMsg.id,
						parsedItems: parsedItems,
						coreContent: coreContent,
						parsedFiles: parsedFiles
					)
				}
			}
			
			for await result in group {
				if let r = result {
					parseResults.append(r)
				}
			}
		}
		
		let capturedDiffPrecision = diffViewModel.getDiffPrecision
		let capturedFileManager = promptViewModel.fileManager
		let capturedDegegateEditItems = self.lastDelegateEditItems
		
	// Process file changes off the main thread, then update UI
	var fileChangesMap: [UUID: ([FileChanges], [String: String])] = [:]
	var failureMap: [UUID: [DiffProcessingHelper.DiffProcessingFailure]] = [:]
	var stateMap: [UUID: [ChangedFileState]] = [:]
	await withTaskGroup(of: (ParsedAIContent, [FileChanges], [String: String], [DiffProcessingHelper.DiffProcessingFailure], [ChangedFileState]).self) { group in
			for content in parseResults {
				group.addTask {
					await ChatViewModel.processParsedFiles(
						content,
						session,
						fileManager: capturedFileManager,
						diffPrecision: capturedDiffPrecision,
						delegateEditItems: capturedDegegateEditItems
					)
				}
			}
			
			for await result in group {
				// Collect results so we can apply them all at once on the main thread
				fileChangesMap[result.0.messageId] = (result.1, result.2)
				failureMap[result.0.messageId] = result.3
				stateMap[result.0.messageId] = result.4
			}
		}
		// Final UI update on the main actor
		for content in parseResults {
			withSessionMessages(session.id) { msgs in
				if let idx = msgs.firstIndex(where: { $0.id == content.messageId }) {
					msgs[idx].updateParsedContent(content.parsedItems)
					msgs[idx].updateExtractedCoreContent(content.coreContent)
					msgs[idx].setHasCompletedDelegateWork(true)
					msgs[idx].setHasPendingDelegateWork(false)
					msgs[idx].setIsFinalized(true)
				}
			}
				
			// Handle failures at call site
			if let failures = failureMap[content.messageId], !failures.isEmpty,
			var tasks = delegateEditTasks[content.messageId] {

				for tIndex in tasks.indices {
					let fp = tasks[tIndex].filePath
					let failedCount = failures.filter { $0.filePath == fp }.count
					guard failedCount > 0 else { continue }

					tasks[tIndex].status = .partialFailed(failedCount: failedCount)
				}
				delegateEditTasks[content.messageId] = tasks
			}
			
			if !content.parsedFiles.isEmpty, let (localFileChanges, localOverrideDict) = fileChangesMap[content.messageId] {
				withSessionMessages(session.id) { msgs in
					if let idx = msgs.firstIndex(where: { $0.id == content.messageId }) {
						msgs[idx].setHasParseableContent(!content.parsedFiles.isEmpty)
						// Defer diff loading for performance
						deferredDiffs[content.messageId] = DeferredDiffBuffer(
							fileChanges: localFileChanges,
							overrides: localOverrideDict,
							persisted: stateMap[content.messageId] ?? []
						)
						msgs[idx].fileChangesLoaded = false
					}
				}
				updateParsingStatus(
					for: content.messageId,
					fileChanges: localFileChanges,
					parsedFiles: content.parsedFiles
				)
			}
		}
		// Batch finished – re-enable token updates and do a single refresh
		if shouldAffectDisplayed {
			isBatchLoadingMessages = false
			updateLatestTokenCounts()
			updateUpcomingInputTokenText()
			await workspaceManager.restoreChatSessionState(session, restoreSelection: false)
		}
		
		// (updateUpcomingInputTokenText already called above)
	}
	
	/// Ensures ChangedFile objects exist for the message; no-op if already loaded
	@MainActor
	func ensureFileChangesLoaded(for messageId: UUID) async {
		guard let buf = deferredDiffs.removeValue(forKey: messageId) else { return }
		
		await aiResponseViewModel.addResponses(
			buf.fileChanges,
			forQueryId: messageId,
			overrideContents: buf.overrides.isEmpty ? nil : buf.overrides
		)
		if !buf.persisted.isEmpty {
			await aiResponseViewModel.applyChangedFileStates(buf.persisted,
														forQueryId: messageId)
		}
		if let sessionID = sessionIDByMessageId[messageId] {
			withSessionMessages(sessionID) { msgs in
				if let idx = msgs.firstIndex(where: { $0.id == messageId }) {
					msgs[idx].fileChangesLoaded = true
				}
			}
		}
	}
	
	/// Build file changes in a separate function to avoid capturing a mutable var in concurrent code
	static nonisolated func buildFileChanges(
		parsedFiles: [ParsedFile],
		messageFileStates: [ChangedFileState],
		fileManager: RepoFileManagerViewModel,
		diffPrecision: DiffPrecision,
		delegateEditItems: [DelegateEditItem] = []
	) async -> ([FileChanges], [String: String], [DiffProcessingHelper.DiffProcessingFailure], [ChangedFileState]) {
		var finalFileChanges: [FileChanges] = []
		var overrideDict: [String: String] = [:]
		var allFailures: [DiffProcessingHelper.DiffProcessingFailure] = []
		
		for parsedFile in parsedFiles {
			// Check if there is a matching state for an override
			if let matchingState = messageFileStates.first(where: { $0.relativePath == parsedFile.fileName }) {
				overrideDict[parsedFile.fileName] = matchingState.originalContent
				
				// Filter delegate edits relevant for this file
				let fileSpecificEdits = delegateEditItems.filter { $0.filePath == parsedFile.fileName }
				
				let (changes, failures) = await DiffProcessingHelper.createFileChangesDetailed(
					from: [parsedFile],
					fileManager: fileManager,
					diffPrecision: diffPrecision,
					delegateEditItems: fileSpecificEdits,
					overrideContent: matchingState.originalContent
				)
				finalFileChanges.append(contentsOf: changes)
				allFailures.append(contentsOf: failures)
			} else {
				let fileSpecificEdits = delegateEditItems.filter { $0.filePath == parsedFile.fileName }
				
				let (changes, failures) = await DiffProcessingHelper.createFileChangesDetailed(
					from: [parsedFile],
					fileManager: fileManager,
					diffPrecision: diffPrecision,
					delegateEditItems: fileSpecificEdits,
					overrideContent: nil
				)
				finalFileChanges.append(contentsOf: changes)
				allFailures.append(contentsOf: failures)
			}
		}
		
		return (finalFileChanges, overrideDict, allFailures, messageFileStates)
	}
	
	// MARK: – Persisting file-change state for autosave / restore
	func produceChangedFileStatesForMessage(_ messageId: UUID) -> [ChangedFileState]? {
		// Grab the live `ChangedFile` objects for this AI message and snapshot
		// them using the same source of truth used for disk writes.
		guard let files = aiResponseViewModel.getChangedFiles(forQueryId: messageId) else {
			return nil
		}
		
		return files.map { $0.makeStateSnapshot() }
	}

	/*
	@MainActor
	func refreshSavedHistoryList() {
		_ = chatHistoryManager.listSavedHistories()
	}
	*/
	
	
	/// Returns the newly saved file URL for a given session, if successful.
	/// If the session has no workspace assigned, fails.
	/// If the session is a stub (messages unloaded), loads the full session first
	/// to avoid overwriting disk content with empty messages.
	@discardableResult
	func autosaveSession(_ session: ChatSession) async throws -> URL {
		// Must have a workspace
		guard let wsId = session.workspaceID,
				let ws = workspaceManager.workspaces.first(where: { $0.id == wsId }) else {
			throw ChatSessionError.invalidFilename("Session is missing a valid workspaceID.")
		}

		var sessionToSave = session

		// Stub-safe: if the session is a stub (messages unloaded), we need to
		// load the full session from disk first to avoid wiping messages.
		if session.isListStub, let fileURL = session.fileURL {
			do {
			let fullSession = try await chatData.loadChatSession(from: fileURL)
			// Merge any updated metadata from the stub into the full session
			sessionToSave = fullSession
			sessionToSave.name = session.name
			sessionToSave.composeTabID = session.composeTabID
			sessionToSave.agentModeSessionID = session.agentModeSessionID
			sessionToSave.agentModeRunID = session.agentModeRunID
			sessionToSave.selectedFilePaths = session.selectedFilePaths
			sessionToSave.selectedPromptIDs = session.selectedPromptIDs
				sessionToSave.preferredAIModel = session.preferredAIModel
				sessionToSave.selectedChatPresetID = session.selectedChatPresetID
			} catch {
				print("Warning: Failed to load full session for stub-safe save, skipping save: \(error)")
				throw error
			}
		}

		return try await chatData.saveChatSession(sessionToSave, for: ws)
	}
	
	// Mark: - Loading All Sessions
	/// Load all chat sessions from all known workspaces.
	/// (Used once at init, or if you want to refresh everything.)
	@MainActor
	func loadSessionsFromWorkspace() async {
		await handleWorkspaceSwitched(to: workspaceManager.activeWorkspace)
	}
	
	// MARK: - Autosave
	/// Update the current session’s data from in-memory `messages` & tasks, then save to disk.
	@MainActor
	func autosaveChatHistory(force: Bool = false) {
		guard let currentSessionID else { return }
		autosaveChatHistory(for: currentSessionID, force: force)
	}
	
	@MainActor
	func autosaveChatHistory(for sessionID: UUID, force: Bool = false) {
		// ------------------------------------------------------------------
		// 0️⃣  Preconditions
		// ------------------------------------------------------------------
		guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
		guard let liveMessages = messageStore[sessionID] ?? (sessionID == currentSessionID ? messages : nil) else {
			return
		}
		
		// ------------------------------------------------------------------
		// 1️⃣  Fast‑path: detect "no changes" and bail early
		// ------------------------------------------------------------------
		let usesPromptSelections = Self.shouldUseLivePromptStateForAutosave(
			sessionID: sessionID,
			currentSessionID: currentSessionID,
			sessionComposeTabID: session.composeTabID,
			activeComposeTabID: promptViewModel.activeComposeTabID
		)
		let selectedFilePaths = usesPromptSelections
			? promptViewModel.fileManager.selectedFiles.map { $0.fullPath }
			: session.selectedFilePaths
		let selectedPromptIDs = usesPromptSelections
			? Array(promptViewModel.selectedPromptIDsForChat)
			: session.selectedPromptIDs
		
		// Did the last message itself change?
		let lastStored = session.messages.last
		let lastLive   = liveMessages.last
		let lastMessageUnchanged: Bool = {
			guard let stored = lastStored,
					let live   = lastLive
			else { return true }                   // no messages → treat as unchanged
			return stored.id == live.id &&
			stored.rawText == live.content
		}()
		
		// NEW ▶︎ catch changes to the session‑level preferred model
		// Handle optional vs non-optional comparison properly
		let sessionModel = session.preferredAIModel ?? ""
		let modelChanged = usesPromptSelections
			? sessionModel != promptViewModel.preferredModel
			: false
		
		// NEW: Chat preset change detection
		let presetChanged = usesPromptSelections
			? session.selectedChatPresetID != promptViewModel.selectedChatPresetID
			: false
		
		// Compare file paths and prompt IDs as sets to ignore order
		let filePathsChanged = Set(session.selectedFilePaths) != Set(selectedFilePaths)
		let promptIDsChanged = Set(session.selectedPromptIDs) != Set(selectedPromptIDs)
		
		let shouldSkipChangeCheck = sessionID != currentSessionID || session.isListStub
		let nothingChanged =
		session.messages.count            == liveMessages.count &&
		!filePathsChanged &&
		!promptIDsChanged &&
		lastMessageUnchanged              &&
		!modelChanged                     && // ← NEW guard
		!presetChanged                    // ← NEW guard for preset
		
		/*
		print("""
Change Detection:
- Message count changed: \(currentSession.messages.count != messages.count) (\(currentSession.messages.count) → \(messages.count))
- File paths changed: \(filePathsChanged)
  - Current session files (\(currentSession.selectedFilePaths.count)): \(currentSession.selectedFilePaths)
  - New selected files (\(selectedFilePaths.count)): \(selectedFilePaths)
  - Added files: \(Set(selectedFilePaths).subtracting(Set(currentSession.selectedFilePaths)))
  - Removed files: \(Set(currentSession.selectedFilePaths).subtracting(Set(selectedFilePaths)))
- Prompt IDs changed: \(promptIDsChanged)
- Last message changed: \(!lastMessageUnchanged)
- Model changed: \(modelChanged) (\(String(describing: currentSession.preferredAIModel)) → \(String(describing: promptViewModel.preferredModel)))
- Nothing changed: \(nothingChanged)
""")
		*/
		
		if !force && !shouldSkipChangeCheck && nothingChanged {
			chatViewModelDebugLog("autosaveChatHistory -> skipped (no meaningful changes)")
			return
		}
		
		// ------------------------------------------------------------------
		// 2️⃣  Build StoredMessage array from live messages
		// ------------------------------------------------------------------
		let storedMessages: [StoredMessage] = liveMessages.map { msg in
			StoredMessage(
				id: msg.id,
				isUser: msg.isUser,
				rawText: msg.content,
				timestamp: Date(),
				delegateResults: msg.delegateResults,
				sequenceIndex: msg.sequenceIndex,
				allowedFilePaths: msg.allowedFilePaths.isEmpty ? nil : msg.allowedFilePaths,
				promptTokens: msg.promptTokens,
				completionTokens: msg.completionTokens,
				cost: msg.cost,
				modelName: msg.modelName
			)
		}
		
		// ------------------------------------------------------------------
		// 3️⃣  Persist change‑tracking info per AI message
		// ------------------------------------------------------------------
		var perMessageDict: [UUID: [ChangedFileState]] = [:]
		for msg in liveMessages where !msg.isUser {
			if let states = produceChangedFileStatesForMessage(msg.id) {
				perMessageDict[msg.id] = states
			}
		}
		
		// ------------------------------------------------------------------
		// 4️⃣  Persist delegate‑edit tasks
		// ------------------------------------------------------------------
		var persistedEditItems: [UUID: [DelegateEditItemPersist]] = [:]
		for msg in liveMessages where !msg.isUser {
			if let tasks = delegateEditTasks[msg.id] {
				let persistArray = tasks.map { t -> DelegateEditItemPersist in
					let persistedChanges = t.changes.map { change in
						DelegateEditItemPersist.ChangePersist(
							description: change.description,
							codeSnippet: change.codeSnippet,
							complexity: change.complexity
						)
					}
					let persistStatus: DelegateEditItemPersist.TaskStatus
					let failedCount: Int?
					switch t.status {
					case .completed:
						persistStatus = .completed
						failedCount   = nil
					case .noChangesMade:
						persistStatus = .noChangesMade
						failedCount   = nil
					case .partialFailed(let fc):
						persistStatus = .partialFailed
						failedCount   = fc
					default:
						persistStatus = .failed
						failedCount   = nil
					}
					
					return DelegateEditItemPersist(
						filePath: t.filePath,
						resolvedFilePath: t.resolvedFilePath,
						changes: persistedChanges,
						status: persistStatus,
						failedCount: failedCount,
						modelDisplayName: t.modelDisplayName,
						finalOutput: t.accumulatedOutput.isEmpty ? nil : t.accumulatedOutput,
						tokenEstimate: t.tokenEstimate,
						promptTokens: t.promptTokens,
						completionTokens: t.completionTokens
					)
				}
				persistedEditItems[msg.id] = persistArray
			}
		}
		
		// ------------------------------------------------------------------
		// 5️⃣  Capture current selections & preferred model
		// ------------------------------------------------------------------
		let sessionSelectedFilePaths = selectedFilePaths
		let sessionSelectedPromptIDs = selectedPromptIDs
		let selectedModelName        = usesPromptSelections ? promptViewModel.preferredModel : session.preferredAIModel
		let selectedChatPresetId     = usesPromptSelections ? promptViewModel.selectedChatPresetID : session.selectedChatPresetID
		
		// ------------------------------------------------------------------
		// 6️⃣  Build an updated copy of the session
		// ------------------------------------------------------------------
		var sessionCopy = session
		sessionCopy.messages                   = storedMessages
		sessionCopy.changedFilesByMessage      = perMessageDict
		sessionCopy.delegateEditItemsByMessage = persistedEditItems
		sessionCopy.savedAt                    = Date()
		sessionCopy.selectedFilePaths          = sessionSelectedFilePaths
		sessionCopy.selectedPromptIDs          = sessionSelectedPromptIDs
		sessionCopy.preferredAIModel           = selectedModelName
		sessionCopy.selectedChatPresetID       = selectedChatPresetId
		
		// ------------------------------------------------------------------
		// 7️⃣  Persist to disk
		// ------------------------------------------------------------------
		Task {
			do {
				let fileURL = try await autosaveSession(sessionCopy)
				await MainActor.run {
					if let idx = sessions.firstIndex(where: { $0.id == sessionCopy.id }) {
						var updated = sessionCopy
						updated.fileURL = fileURL
						updated.savedAt = sessionCopy.savedAt

						// Keep only the active session loaded; list entries should be lightweight.
						// Skip stubbing if a caller has pinned the session.
						if sessionCopy.id != currentSessionID && !isSessionPinned(sessionCopy.id) {
							updated = updated.listStub()
							updated.fileURL = fileURL
							updated.savedAt = sessionCopy.savedAt
						}
						sessions[idx] = updated
					}
					unloadNonCurrentSessions()
					workspaceManager.pollAndSaveState()
				}
			} catch {
				print("Autosave failed: \(error)")
			}
		}
	}

	
	// MARK: - Prompt
    @MainActor
    private func sendPromptFromPromptViewModel() async {
        await startNewChatSession(name: "New Chat")

        storeTextAndSend(for: currentSessionID, promptViewModel.promptText)
        // Only copy stored prompts into Chat when the Chat preset is Manual.
        // For non-manual presets, do not push prompt selections over since the user
        // has no clear visibility into them in that context, and presets may manage
        // their own meta-instructions.
        let isManualChatPreset = promptViewModel.currentChatPreset().id == ChatPreset.BuiltIn.manual.id
        if isManualChatPreset {
            promptViewModel.selectedPromptIDsForChat = promptViewModel.selectedPromptIDs
            // Ensure chat meta-instructions reflect the copied selection
            promptViewModel.updateMetaInstructions()
        }

        // Defer focus change to avoid triggering during layout passes
        DispatchQueue.main.async { [weak self] in
            self?.focusInputField = true
        }
	}
	
	@MainActor
	func removeMessage(_ messageId: UUID) async{
		// If removing the last AI message, skip partial parse,
		// because the user wants to discard it entirely:
		guard let sessionID = sessionIDByMessageId[messageId] ?? currentSessionID else { return }
		if let last = messageStore[sessionID]?.last, last.id == messageId, !last.isUser {
			await cancelAIResponse(in: sessionID, skipPartialParseAndSave: true)
		}
		withSessionMessages(sessionID) { msgs in
			msgs.removeAll { $0.id == messageId }
		}
		sessionIDByMessageId.removeValue(forKey: messageId)
		
		// if no more AI messages exist, reset the current query ID:
		if runStateBySession[sessionID]?.activeQueryId == messageId {
			clearSessionStreaming(sessionID)
		}
		autosaveChatHistory(for: sessionID)
	}

	/// Edits a user message and resends the conversation from that point.
	/// If the message being edited is not the last user message, forks the chat.
	@MainActor
	func editAndResendMessage(messageId: UUID, newContent: String) async {
		guard !newContent.isEmpty else { return }
		guard let session = currentSession else { return }
		let liveMessages = messageStore[session.id] ?? messages

		// Find the message to edit
		guard let messageIndex = liveMessages.firstIndex(where: { $0.id == messageId }) else {
			print("Error: Could not find message to edit")
			return
		}

		let messageToEdit = liveMessages[messageIndex]
		guard messageToEdit.isUser else {
			print("Error: Can only edit user messages")
			return
		}

		// Check if there are messages after this one
		let hasSubsequentMessages = messageIndex < liveMessages.count - 1

		if hasSubsequentMessages {
			if messageIndex == 0 {
				// If editing the first message, just remove it and all subsequent messages
				// No need to fork - we're essentially restarting the chat
				let removedIds = messageStore[session.id]?.map(\.id) ?? []
				withSessionMessages(session.id) { $0.removeAll() }
				for id in removedIds {
					sessionIDByMessageId.removeValue(forKey: id)
				}
			} else {
				// Fork to the message BEFORE the one we're editing
				// This way the forked chat will end right before the message we want to replace
				let previousMessageId = liveMessages[messageIndex - 1].id
				await forkChatSession(from: previousMessageId)
			}
		} else {
			// Just editing the last message - remove it so we can replace it
			withSessionMessages(session.id) { msgs in
				msgs.removeAll { $0.id == messageId }
			}
			sessionIDByMessageId.removeValue(forKey: messageId)
		}

		// Send the edited message (this creates a new user message and gets AI response)
		await sendMessage(newContent)
	}

	func startProEditSession(userInstructions: String,
								assistantXML originalXML: String)
	{
		Task { [weak self] in
			guard let self else { return }
			
			// ─────────────────────────────────────────────────────────────
			// 0️⃣  Pull optional <chatName …/> tag & pre-parse the XML
			// ─────────────────────────────────────────────────────────────
			var xml = originalXML
			let explicitName = ChatContentParser
				.parseAndRemoveChatName(from: &xml)?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			
			var alreadySeenHashes = Set<Int>()
			let (parsedItems,
					coreContent,
					delegateEdits) = ChatContentParser.parseContent(
					xml,
					processedDelegateEditHashes: &alreadySeenHashes,
					isFinal: true)
			
			self.lastDelegateEditItems = delegateEdits
			
			// ─────────────────────────────────────────────────────────────
			// 1️⃣  Open / switch to a fresh session
			// ─────────────────────────────────────────────────────────────
			await self.startNewChatSession(name: explicitName ?? "Pro Edit")
			guard let sessionID = self.currentSessionID else { return }
			
			// ─────────────────────────────────────────────────────────────
			// 2️⃣  Add the USER message (instructions)
			// ─────────────────────────────────────────────────────────────
			let userId = UUID()
			let userMsg = AIChatMessage(
				id:            userId,
				content:       userInstructions,
				isUser:        true,
				parsedContent: [ContentItem(type: .text, content: userInstructions)],
				isFinalized:   true,
				sequenceIndex: self.nextSequenceIndex(for: sessionID))
			self.withSessionMessages(sessionID) { msgs in
				msgs.append(userMsg)
			}
			self.registerMessage(userId, sessionID: sessionID)
			
			// ─────────────────────────────────────────────────────────────
			// 3️⃣  NEW: auto-select any delegate-edit files **before**
			//     we capture `selectedPaths`.
			// ─────────────────────────────────────────────────────────────
			let filesToSelect = delegateEdits.map(\.filePath)
			await self.promptViewModel.fileManager
				.selectFiles(withPaths: filesToSelect, allowEmpty: true, clear: false)
			
			// ─────────────────────────────────────────────────────────────
			// 4️⃣  Create a *blank* ASSISTANT placeholder with the updated
			//     file selection reflected in `allowedFilePaths`.
			// ─────────────────────────────────────────────────────────────
			let aiID          = UUID()
			let selectedPaths = self.promptViewModel.fileManager
				.selectedFiles.map(\.fullPath)
			
			let placeholder = AIChatMessage(
				id:               aiID,
				content:          "",              // start empty
				isUser:           false,
				sequenceIndex:    self.nextSequenceIndex(for: sessionID),
				allowedFilePaths: selectedPaths)
			self.withSessionMessages(sessionID) { msgs in
				msgs.append(placeholder)
			}
			self.registerMessage(aiID, sessionID: sessionID)
			
			self.setSessionStreaming(sessionID, queryId: aiID, streamId: nil)
			
			// ─────────────────────────────────────────────────────────────
			// 5️⃣  Mutate the placeholder with the parsed content
			// ─────────────────────────────────────────────────────────────
			self.withSessionMessages(sessionID) { msgs in
				if let idx = msgs.firstIndex(where: { $0.id == aiID }) {
					msgs[idx].updateContent(xml)
					msgs[idx].updateParsedContent(parsedItems)
					msgs[idx].updateExtractedCoreContent(coreContent)
					msgs[idx].updateParsingStatus(.notYetParsed)
					msgs[idx].setHasParseableContent(!parsedItems.isEmpty)
					msgs[idx].setHasPendingDelegateWork(true)
				}
			}
			
			// ─────────────────────────────────────────────────────────────
			// 6️⃣  All delegate edits are already known → merge them by
			//     `filePath` *before* triggering queries so the coordinator
			//     receives at most **one** batch per file.
			// ─────────────────────────────────────────────────────────────
			let grouped = Dictionary(grouping: delegateEdits, by: \.filePath)
			let mergedItems: [DelegateEditItem] = grouped.map { (path, items) in
				let combinedChanges = items.flatMap(\.changes)
				return DelegateEditItem(filePath: path, changes: combinedChanges)
			}
			
			for merged in mergedItems {
				await self.triggerAIQuery(for: merged, messageId: aiID)
			}
			
			// ─────────────────────────────────────────────────────────────
			// 7️⃣  Wait for the edits, then finalise/merge as usual
			// ─────────────────────────────────────────────────────────────
			await self.finalizeAIResponse(aiResponseId: aiID,
											sessionID: sessionID,
											partialBuffer: xml)
		}
	}
	
	/// Validate the path **without** mutating the item's `filePath`.
	private func validatedDelegateEditItem(_ item: DelegateEditItem)
		async -> (DelegateEditItem, String?)          // ← returns (originalItem, correctedPath?)
	{
		// Ask the file-manager to canonicalise the user-supplied path
		guard let location = await promptViewModel.fileManager
			.getFileSystemServiceForRelativePath(item.filePath,
											exactMatchOnly: false)
		else { return (item, nil) }
		
		let abs  = (location.rootPath as NSString)
			.appendingPathComponent(location.correctedPath)
		let canonical = (abs as NSString).standardizingPath
		
		// If the canonical form is identical, we do not need to pass it on
		let isSame = (canonical as NSString)
			.caseInsensitiveCompare(item.filePath) == .orderedSame
		return isSame ? (item, nil) : (item, canonical)
	}

	private func validatedOverrideAIMessage(
		_ overrideAIMessage: AIMessage,
		newUserMessage: String,
		selectionOverride: StoredSelection?,
		overrideMode: PromptViewModel.PlanActMode?
	) -> AIMessage? {
		guard selectionOverride != nil else {
			print("Warning: Ignoring overrideAIMessage without selectionOverride to keep prompt scope aligned with UI metadata.")
			return nil
		}
		guard overrideMode != nil else {
			print("Warning: Ignoring overrideAIMessage without overrideMode.")
			return nil
		}
		guard let lastUserMessage = overrideAIMessage.conversationMessages.last(where: { $0.role == .user })?.content,
			lastUserMessage == newUserMessage else {
			print("Warning: Ignoring overrideAIMessage because its final user message does not match the current send input.")
			return nil
		}
		return overrideAIMessage
	}

	// MARK: - Main Send/Receive Flow
	@MainActor
	func sendMessage(
		_ newUserMessage: String,
		sessionID: UUID? = nil,
		overrideModel: AIModel? = nil,
		overrideChatPresetID: UUID? = nil,
		overrideMode: PromptViewModel.PlanActMode? = nil,
		gitInclusionOverride: GitInclusion? = nil,
		gitBaseOverride: String? = nil,
		selectionOverride: StoredSelection? = nil,
		overrideAIMessage: AIMessage? = nil,
		onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
	) async {
		guard !newUserMessage.isEmpty else { return }
		
		var localEditHashes = Set<Int>()
		
		let targetSessionID: UUID
		if let sessionID {
			targetSessionID = sessionID
		} else if let currentSessionID {
			targetSessionID = currentSessionID
		} else {
			await startNewChatSession()
			guard let currentSessionID else { return }
			targetSessionID = currentSessionID
		}
		
		if overrideModel == nil {
			clearMCPSessionUIState(for: targetSessionID)
		}
		
		if isSessionStreaming(targetSessionID) {
			await cancelAIResponse(in: targetSessionID, skipPartialParseAndSave: false)
		}
		
		ensureSessionStorage(targetSessionID)
		
		// Create the user message
		let userId = UUID()
		let userMessage = AIChatMessage(
			id: userId,
			content: newUserMessage,
			isUser: true,
			sequenceIndex: nextSequenceIndex(for: targetSessionID)
		)
		withSessionMessages(targetSessionID) { msgs in
			msgs.append(userMessage)
		}
		registerMessage(userId, sessionID: targetSessionID)
		
		let conversation = buildConversationEntries(for: targetSessionID)
		
		// Gather currently selected file paths
		let selectedPaths = selectionOverride?.selectedPaths ?? promptViewModel.fileManager.selectedFiles.map { $0.fullPath }
		
		let presetModel = promptViewModel.modelFromCurrentChatPreset()
		let model = overrideModel ?? presetModel ?? promptViewModel.preferredAIModel
		
		// Check if the selected model is actually available (provider configured)
		if !promptViewModel.isModelAvailable(model) {
			// Show error in chat instead of silently falling back
			let errorMessage = AIChatMessage(
				content: "Error: The model '\(model.displayName)' is not available. Please check that the \(model.providerType.displayName) API key is configured in Settings.",
				isUser: false,
				parsedContent: [ContentItem(type: .text, content: "Error: The model '\(model.displayName)' is not available. Please check that the \(model.providerType.displayName) API key is configured in Settings.")],
				isFinalized: true
			)
			withSessionMessages(targetSessionID) { msgs in
				msgs.append(errorMessage)
			}
			registerMessage(errorMessage.id, sessionID: targetSessionID)
			autosaveChatHistory(for: targetSessionID)
			return
		}
		
		// Derive a string representation for storage / UI
		let modelDisplayName = model.displayName

		// Normal UI sends should remember the chat controls immediately.  Final
		// autosave can happen after the user switches compose tabs; by then
		// promptViewModel may already reflect the destination tab.
		if overrideModel == nil && selectionOverride == nil {
			refreshSessionChatControlsFromLivePromptState(for: targetSessionID)
		}
		
		// Create a placeholder AI response
		let aiResponseId = UUID()
		let aiPlaceholder = AIChatMessage(
			id: aiResponseId,
			content: "",
			isUser: false,
			sequenceIndex: nextSequenceIndex(for: targetSessionID),
			allowedFilePaths: selectedPaths,
			modelName: modelDisplayName
		)
		withSessionMessages(targetSessionID) { msgs in
			msgs.append(aiPlaceholder)
		}
		registerMessage(aiResponseId, sessionID: targetSessionID)
		setSessionStreaming(targetSessionID, queryId: aiResponseId, streamId: nil)
		
		if currentSessionID == targetSessionID {
			updateLatestTokenCounts()
		}
		
		Task {
			do {
				let shouldContinueStreaming: () async -> Bool = {
					await MainActor.run {
						self.runStateBySession[targetSessionID]?.activeQueryId == aiResponseId &&
						self.streamingSessions.contains(targetSessionID)
					}
				}
				guard await shouldContinueStreaming() else {
					throw CancellationError()
				}

				let aiMessage: AIMessage
				if let overrideAIMessage = overrideAIMessage.flatMap({
					self.validatedOverrideAIMessage(
						$0,
						newUserMessage: newUserMessage,
						selectionOverride: selectionOverride,
						overrideMode: overrideMode
					)
				}) {
					aiMessage = overrideAIMessage
				} else {
					// Build override context from the specified chat preset or current one
					let chatPreset: ChatPreset
					if let presetID = overrideChatPresetID,
						let overridePreset = ChatPresetManager.shared.preset(with: presetID) {
						chatPreset = overridePreset
					} else {
						chatPreset = promptViewModel.currentChatPreset()
					}
					let overrideContext = promptViewModel.resolvedPromptContext(from: chatPreset)
					
					aiMessage = await promptViewModel.packagePrompt(
						conversation: conversation,
						overrideModel: model,
						overridePromptConfig: overrideContext,
						overrideChatPreset: chatPreset,
						overrideMode: overrideMode,
						gitInclusionOverride: gitInclusionOverride,
						gitBaseOverride: gitBaseOverride,
						selectionOverride: selectionOverride
					)
				}
				guard await shouldContinueStreaming() else {
					throw CancellationError()
				}
				let (streamID, stream) = try await aiQueriesService.sendPrompt(
					aiMessage,
					model: model
				)
				
				guard await shouldContinueStreaming() else {
					await aiQueriesService.cancelStream(id: streamID)
					throw CancellationError()
				}
				
				await MainActor.run {
					self.streamIDsByQueryId[aiResponseId] = streamID
					self.setSessionStreaming(targetSessionID, queryId: aiResponseId, streamId: streamID)
				}
				
				var partialBuffer = ""
				var reasoningBuffer = ""
				var didFinalize = false
				
				for try await output in stream {
					let delta = output.text
					let reasoningDelta = output.reasoning
					let tokenInfo = output.tokens
					let isStreamFinalized = output.isFinal
					
					partialBuffer += delta
					reasoningBuffer += reasoningDelta ?? ""
					reasoningBuffer = ReasoningTextFormatter.normalize(reasoningBuffer)
					
					let (parsedItems, coreContent, newDelegateEdits, updatedSet) = await Task.detached {
						var hashSetCopy = localEditHashes
						let (items, core, delegateEdits) = ChatContentParser.parseContent(
							partialBuffer,
							processedDelegateEditHashes: &hashSetCopy,
							isFinal: isStreamFinalized
						)
						return (items, core, delegateEdits, hashSetCopy)
					}.value
					
					await MainActor.run {
						let sawText = !delta.isEmpty
						let sawReasoning = !(reasoningDelta?.isEmpty ?? true)
						let now = Date()
						if sawText || sawReasoning {
							self.lastAnyStreamActivityAt[aiResponseId] = now
							// Use throttled arm to reduce Task churn during fast streaming
							self.armStreamInactivityWatchdogThrottled(for: aiResponseId, now: now)
						}
						if sawText {
							self.hasSeenNonReasoningText.insert(aiResponseId)
							self.lastTextStreamActivityAt[aiResponseId] = now
						}
						localEditHashes = updatedSet
						
						// Store reasoning content in ephemeral state instead of message
						self.ephemeralState.setReasoningContent(reasoningBuffer, for: aiResponseId)
						
						// Increment tick to force popover UI refresh when reasoning updates
						if sawReasoning {
							self.reasoningUpdateTick += 1
						}
						
						self.withSessionMessages(targetSessionID) { msgs in
							if let idx = msgs.firstIndex(where: { $0.id == aiResponseId }) {
								msgs[idx].updateContent(partialBuffer)
								msgs[idx].updateParsedContent(parsedItems)
								msgs[idx].updateExtractedCoreContent(coreContent)
								msgs[idx].updateReasoningContent(reasoningBuffer)
							}
						}
						onProgress?(partialBuffer, reasoningBuffer.isEmpty ? nil : reasoningBuffer)
					}
					
					for editItem in newDelegateEdits {
						// 1) Validate without mutating the display path
						let (original, canonical) = await validatedDelegateEditItem(editItem)
						// 2) Pass both to the worker
						await triggerAIQuery(for: original,
												resolvedPath: canonical,
												messageId: aiResponseId)
					}
					
					if isStreamFinalized {
						didFinalize = true
						
						// Store token counts and cost when stream is finalized
						await MainActor.run {
							self.withSessionMessages(targetSessionID) { msgs in
								if let idx = msgs.firstIndex(where: { $0.id == aiResponseId }) {
									msgs[idx].updateTokenInfo(tokenInfo)
								}
							}
							if self.currentSessionID == targetSessionID {
								self.updateLatestTokenCounts()
							}
						}
						
						await MainActor.run {
							self.providerStopSeen.insert(aiResponseId)
							self.cancelStreamInactivityWatchdog(for: aiResponseId)
						}
						
						Task {
							await self.finalizeAIResponse(aiResponseId: aiResponseId, sessionID: targetSessionID, partialBuffer: partialBuffer)
						}
					}
				}
				
				if !didFinalize {
					await MainActor.run {
						self.cancelStreamInactivityWatchdog(for: aiResponseId)
					}
					Task { await self.finalizeAIResponse(aiResponseId: aiResponseId, sessionID: targetSessionID, partialBuffer: partialBuffer) }
				}
			} catch {
				await MainActor.run {
					self.clearSessionStreaming(targetSessionID)
				}
				Task {
					await handleSendMessageError(error, aiResponseId: aiResponseId, sessionID: targetSessionID)
				}
			}
		}
	}
	
	// MARK: - Finalise an AI response
	private func finalizeAIResponse(
		aiResponseId: UUID,
		sessionID: UUID,
		partialBuffer: String
	) async {
		// Single-flight finalisation: provider stop, watchdogs, and cancellation can
		// all race to finalize the same message.
		if finalizingAIResponses.contains(aiResponseId) {
			return
		}
		if messageStore[sessionID]?.first(where: { $0.id == aiResponseId })?.isFinalized == true {
			return
		}
		finalizingAIResponses.insert(aiResponseId)
		defer { finalizingAIResponses.remove(aiResponseId) }
		
		// Cancel any watchdog to prevent duplicate finalization
		await MainActor.run {
			self.cancelFinalizationWatchdog(for: aiResponseId)
			self.clearStreamActivityTracking(for: aiResponseId)
			self.streamIDsByQueryId.removeValue(forKey: aiResponseId)
		}

		// Final pass: dispatch any delegate-edit requests that are embedded in the
		// final assistant content but were not launched yet.
		let assistantContent = await MainActor.run { () -> String in
			messageStore[sessionID]?.first(where: { $0.id == aiResponseId })?.content ?? partialBuffer
		}
		let delegateEdits: [DelegateEditItem] = await Task.detached(priority: .userInitiated) {
			var seen = Set<Int>()
			let (_, _, edits) = ChatContentParser.parseContent(
				assistantContent,
				processedDelegateEditHashes: &seen,
				isFinal: true
			)
			return edits
		}.value
		if !delegateEdits.isEmpty {
			for editItem in delegateEdits {
				let (original, canonical) = await validatedDelegateEditItem(editItem)
				await triggerAIQuery(for: original,
									 resolvedPath: canonical,
									 messageId: aiResponseId)
			}
		}
		
		// 1️⃣ Wait for any in‑flight delegate‑edit queries
		await delegateEditTaskManager.waitForTasks(forMessageId: aiResponseId)
		
		// 2️⃣ Snapshot the final assistant text (MainActor)
		let finalContent = await MainActor.run { () -> String in
			messageStore[sessionID]?.first(where: { $0.id == aiResponseId })?
				.combinedText ?? partialBuffer
		}
		
		// 3️⃣ Parse file changes ‑ this can be *costly*, so do it **before**
		//    toggling the finished flags that external tools poll for.
		await processAIResponse(finalContent, forQueryId: aiResponseId, sessionID: sessionID)
		
		// 4️⃣ Now – and only now – mark the message / chat turn as complete.
		await MainActor.run {
			self.withSessionMessages(sessionID) { msgs in
				if let idx = msgs.firstIndex(where: { $0.id == aiResponseId }) {
					msgs[idx].setIsFinalized(true)
					msgs[idx].setHasPendingDelegateWork(false)
					msgs[idx].setHasCompletedDelegateWork(true)
				}
			}
			launchedDelegateKeysByMessage[aiResponseId] = nil
			clearSessionStreaming(sessionID)
			
			// Clear MCP model info after response completes
			clearMCPSessionUIState(for: sessionID)
			
			// Trigger notification when AI response is complete
			let sessionName = sessions.first(where: { $0.id == sessionID })?.name
			NotificationService.shared.notifyChatComplete(
				chatName: sessionName,
				fallbackToDockBounce: true
			)
		}
		
		// 5️⃣ Persist the fully‑processed session state
		// When finalizing after a delegate‑edit retry, force autosave so XML results persist
		// even if the assistant message text hasn't changed (avoids "no meaningful changes" skip).
		let shouldForceAutosave = (activeRetryTask != nil)
		autosaveChatHistory(for: sessionID, force: shouldForceAutosave)
		
		// 6️⃣ Notify any waiters that this message is finalised
		Task { await finalisationHub.fulfil(aiResponseId) }
	}
	
	// MARK: - Error Handling
	@MainActor
	private func handleSendMessageError(_ error: Error, aiResponseId: UUID, sessionID: UUID) async {
		// Clear MCP model info on error
		clearMCPSessionUIState(for: sessionID)
		
		// Cancel any watchdog for this response and clear activity/stream tracking
		cancelFinalizationWatchdog(for: aiResponseId)
		clearStreamActivityTracking(for: aiResponseId)
		streamIDsByQueryId.removeValue(forKey: aiResponseId)
		
		if error is CancellationError {
			print("AI response was cancelled.")
			guard let index = messageStore[sessionID]?.firstIndex(where: { $0.id == aiResponseId }) else {
				clearSessionStreaming(sessionID)
				Task { await finalisationHub.fulfil(aiResponseId) }
				return
			}
			
			if messageStore[sessionID]?[index].isFinalized == true {
				clearSessionStreaming(sessionID)
				Task { await finalisationHub.fulfil(aiResponseId) }
				return
			}
			
			let finalContent = messageStore[sessionID]?[index].content ?? ""
			if finalContent.isEmpty {
				withSessionMessages(sessionID) { msgs in
					if let idx = msgs.firstIndex(where: { $0.id == aiResponseId }) {
						msgs.remove(at: idx)
					}
				}
				purgeMessageCaches(for: aiResponseId)
				clearSessionStreaming(sessionID)
				autosaveChatHistory(for: sessionID)
				Task { await finalisationHub.fulfil(aiResponseId) }
				return
			}
			
			Task {
				await self.finalizeAIResponse(aiResponseId: aiResponseId, sessionID: sessionID, partialBuffer: finalContent)
			}
			return
		}
		
		// Pass token count to error message handler for non-cancellation errors
		let tokenCount = promptViewModel.totalTokenCountWithDiff
		let errorMessage = userFriendlyErrorMessage(for: error, tokenCount: tokenCount)
		if messageStore[sessionID]?.contains(where: { $0.id == aiResponseId }) == true {
			let appendedErrorBlock = "\n\n--\nError:\n\(errorMessage)"
			withSessionMessages(sessionID) { msgs in
				if let idx = msgs.firstIndex(where: { $0.id == aiResponseId }) {
					msgs[idx].appendContent(appendedErrorBlock)
					msgs[idx].updateParsedContent([ContentItem(type: .text, content: msgs[idx].content)])
					msgs[idx].setIsFinalized(true)
				}
			}
			autosaveChatHistory(for: sessionID)
		} else {
			let errorMessageModel = AIChatMessage(
				content: errorMessage,
				isUser: false,
				parsedContent: [ContentItem(type: .text, content: "\n\n\(errorMessage)")],
				isFinalized: true
			)
			withSessionMessages(sessionID) { msgs in
				msgs.append(errorMessageModel)
			}
			registerMessage(errorMessageModel.id, sessionID: sessionID)
			autosaveChatHistory(for: sessionID)
		}
		
		clearSessionStreaming(sessionID)
		Task { await finalisationHub.fulfil(aiResponseId) }
	}
	
	// MARK: - Conversation Entries Helper
	/// Builds conversation entries so that:
	///  - User messages get their full text.
	///  - Assistant messages that are the last one include full code snippets.
	///  - Earlier assistant messages only include descriptions of the changes (no code).
	@MainActor
	private func buildConversationEntries(for sessionID: UUID) -> [ConversationEntry] {
		guard let sessionMessages = messageStore[sessionID] else { return [] }
		// Identify the last assistant message
		let lastAssistantId = sessionMessages.last(where: { !$0.isUser })?.id
		
		return sessionMessages.map { msg in
			let role: ConversationEntry.Role = msg.isUser ? .user : .assistant
			
			if msg.isUser {
				// Just include the entire user content
				return ConversationEntry(role: role, content: msg.content)
			} else {
				// This is an assistant message
				let isLastAssistant = (msg.id == lastAssistantId)
				if isLastAssistant {
					// Keep the full code snippet version
					let content = msg.extractedCoreContent ?? msg.content
					return ConversationEntry(role: .assistant, content: content)
				} else {
					// Return only the textual descriptions
					let content = buildDescriptionOnlyContent(msg)
					return ConversationEntry(role: .assistant, content: content)
				}
			}
		}
	}
	
	/// Creates a "description-only" version of assistant content,
	/// omitting code snippets and including just the text + file-change summaries.
	private func buildDescriptionOnlyContent(_ msg: AIChatMessage) -> String {
		var result = ""
		for item in msg.parsedContent {
			switch item.type {
			case .text:
				result += item.content + "\n"
			case .code:
				result += item.content + "\n"
				break
			case .file:
				result += "File: \(item.filePath)\n"
				//result += "Action: \(item.action)\n"
				result += "Change Summary:\n"
				if !item.descriptions.isEmpty {
					for desc in item.descriptions {
						result += "Description: \(desc)\n"
					}
				}
				result += "\n"
			}
		}
		return result.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	
	private func userFriendlyErrorMessage(for error: Error, tokenCount: Int = 0) -> String {
		guard let err = error as NSError?, err.domain == NSURLErrorDomain else {
			// Check if this is an OpenAI request too large error
			if let openAIError = error as? CustomOpenAIProviderError {
				switch openAIError {
				case .requestTooLarge:
					var message = "Request too large. The model has strict token limits and the provided request exceeds them."
					if tokenCount > 0 {
						message += "\n\nCurrent request size: ~\(tokenCount.formatted()) tokens"
						message += "\nTip: Try deselecting some files to reduce the context size."
					}
					return message
				default:
					// Check if it's the vague "no additional details" error
					let errorString = error.asFriendlyString()
					if errorString.contains("no additional details") {
						var message = "OpenAI error: Request failed. This often occurs when the request is too large or there are insufficient credits on your account."
						if tokenCount > 0 {
							message += "\n\nCurrent request size: ~\(tokenCount.formatted()) tokens"
							message += "\nTip: Try deselecting some files to reduce the context size."
						}
						return message
					}
					return errorString
				}
			}
			
			// Also check for the generic error string case
			let errorString = error.asFriendlyString()
			if errorString.contains("no additional details") {
				var message = "Request failed. This often occurs when the request is too large or there are insufficient credits on your account."
				if tokenCount > 0 {
					message += "\n\nCurrent request size: ~\(tokenCount.formatted()) tokens"
					message += "\nTip: Try deselecting some files to reduce the context size."
				}
				return message
			}
			
			return errorString
		}
		switch err.code {
		case NSURLErrorTimedOut:
			return "The request timed out. Please check your internet connection and try again."
		case NSURLErrorCannotConnectToHost:
			return "Unable to connect to the server. Please try again later."
		case NSURLErrorNetworkConnectionLost:
			return "The network connection was lost. Please check your internet connection and try again."
		case NSURLErrorNotConnectedToInternet:
			return "No internet connection. Please check your network settings and try again."
		case NSURLErrorSecureConnectionFailed:
			return "Secure connection failed."
		default:
			return "\(error.asFriendlyString())"
		}
	}
	
	// MARK: - Resend, Clear
	@MainActor
	func resendLastMessage() {
		guard let sessionID = currentSessionID, !isSessionStreaming(sessionID) else { return }
		guard let lastUserMessageIndex = messages.lastIndex(where: { $0.isUser }) else { return }
		
		let lastUserContent = messages[lastUserMessageIndex].content
		let removedIds = messages[lastUserMessageIndex..<messages.endIndex].map(\.id)
		withSessionMessages(sessionID) { msgs in
			msgs.removeSubrange(lastUserMessageIndex..<msgs.endIndex)
		}
		for id in removedIds {
			sessionIDByMessageId.removeValue(forKey: id)
		}
		Task { [weak self] in
			await self?.sendMessage(lastUserContent)
		}
	}
	
	@MainActor
	func clearChat() async {
		if messages.isEmpty { return }
		if let sessionID = currentSessionID {
			await cancelAIResponse(in: sessionID, skipPartialParseAndSave: true)
		}
		if let session = currentSession {
			await deleteSession(session)
			return
		}
		// Clear messages while preserving ephemeral state
		dropMessagesSafely()
		currentQueryId = nil
		aiResponseViewModel.clearResponses()
		isNewChat = true
	}
	
	func cancelReponseForUI() {
		Task { [weak self] in
			guard let self, let sessionID = self.currentSessionID else { return }
			await self.cancelAIResponse(in: sessionID, skipPartialParseAndSave: false)
		}
	}
	
	/// Cancel an active headless (plan/question) stream for a specific tab.
	/// Called by DiscoverAgentViewModel when user cancels background plan generation.
	@MainActor
	func cancelHeadlessStream(forTabID tabID: UUID) async {
		guard let streamID = headlessStreamsByTabID[tabID] else { return }
		headlessStreamsByTabID.removeValue(forKey: tabID)
		await aiQueriesService.cancelStream(id: streamID)
	}
	
	@MainActor
	func cancelStreaming(in sessionID: UUID) async {
		await cancelAIResponse(in: sessionID, skipPartialParseAndSave: false)
	}
	
	// MARK: - Tab Close Cleanup
	
	/// Called before compose tabs are closed. Cancels all running streams for those tabs.
	@MainActor
	private func handleComposeTabsWillClose(_ tabIDs: Set<UUID>) async {
		for tabID in tabIDs {
			// 1. Cancel headless stream (plan/question generation) for this tab
			if headlessStreamsByTabID[tabID] != nil {
				await cancelHeadlessStream(forTabID: tabID)
			}
			
			// 2. Cancel normal chat streaming sessions associated with this tab
			let sessionsForTab = sessions.filter { $0.composeTabID == tabID }
			for session in sessionsForTab {
				if streamingSessions.contains(session.id) {
					await cancelAIResponse(in: session.id, skipPartialParseAndSave: true)
				}
			}
			
			// 3. Clear ephemeral drafts for this tab
			ephemeralDrafts.removeValue(forKey: tabID)
		}
	}
	
	@MainActor
	func cancelAIResponse(in sessionID: UUID, skipPartialParseAndSave: Bool = false) async {
		// Cancel the active retry task if it exists
		activeRetryTask?.cancel()
		activeRetryTask = nil
		
		// Targeted cancel for the current chat stream only (not headless/context-builder streams)
		let qid = runStateBySession[sessionID]?.activeQueryId
		let streamId = runStateBySession[sessionID]?.activeStreamId ?? (qid.flatMap { streamIDsByQueryId[$0] })
		if let streamId {
			await aiQueriesService.cancelStream(id: streamId)
		}
		if let qid {
			streamIDsByQueryId.removeValue(forKey: qid)
		}
		
		clearSessionStreaming(sessionID)
		clearMCPSessionUIState(for: sessionID)
		
		// Cancel any active watchdog for the current query
		if let qid {
			cancelFinalizationWatchdog(for: qid)
			clearStreamActivityTracking(for: qid)
			launchedDelegateKeysByMessage[qid] = nil
		}
		
		if let qid {
			await delegateEditTaskManager.cancelTasks(forMessageId: qid)
		}
		
		// Preserve already-finished delegate-edit tasks so their UI remains visible.
		// Only update tasks that were still running at the time of cancellation.
		if let qid, let tasks = delegateEditTasks[qid] {
			delegateEditTasks[qid] = tasks.map { task in
				switch task.status {
				case .pending, .inProgress:
					var updated = task
					updated.status = .failed(reason: .streamError)
					return updated
				default:
					return task            // keep completed / partialFailed / failed as-is
				}
			}
		}
		
		guard !skipPartialParseAndSave, let queryId = qid else {
			if let qid {
				Task { await finalisationHub.fulfil(qid) }
			}
			return
		}
		
		guard let idx = messageStore[sessionID]?.firstIndex(where: { $0.id == queryId && !$0.isUser }) else {
			Task { await finalisationHub.fulfil(queryId) }
			return
		}
		
		let finalContent = messageStore[sessionID]?[idx].content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		if finalContent.isEmpty {
			withSessionMessages(sessionID) { msgs in
				if let index = msgs.firstIndex(where: { $0.id == queryId && !$0.isUser }) {
					msgs.remove(at: index)
				}
			}
			purgeMessageCaches(for: queryId)
			autosaveChatHistory(for: sessionID)
			Task { await finalisationHub.fulfil(queryId) }
			return
		}
		
		withSessionMessages(sessionID) { msgs in
			if let index = msgs.firstIndex(where: { $0.id == queryId && !$0.isUser }) {
				msgs[index].setIsFinalized(true)
			}
		}
		await processAIResponse(finalContent, forQueryId: queryId, sessionID: sessionID)
		autosaveChatHistory(for: sessionID)
		
		// Notify any waiters that this message is finalised (cancelled)
		Task { await finalisationHub.fulfil(queryId) }
	}
	
	@MainActor
	func cancelAllActiveSessionStreams() async {
		let activeSessions = Array(streamingSessions)
		for sessionID in activeSessions {
			await cancelAIResponse(in: sessionID, skipPartialParseAndSave: true)
		}
	}
	
	static nonisolated func parseSingleRawMessage(_ stored: StoredMessage) async -> AIChatMessage {
		if stored.isUser {
			return AIChatMessage(
				id: stored.id,
				content: stored.rawText,
				isUser: true,
				parsedContent: [ContentItem(type: .text, content: stored.rawText)],
				isFinalized: true,
				sequenceIndex: stored.sequenceIndex
			)
		} else {
			// Parse the main assistant text only
			var emptyHashSet = Set<Int>()
			let (items, coreContent, _) = ChatContentParser.parseContent(
				stored.rawText,
				processedDelegateEditHashes: &emptyHashSet
			)
			
			let needsDiff = items.contains { $0.type == .file }
			let initial   : MessageParsingStatus = needsDiff ? .notYetParsed : .fullyParsed
			
			var aiMessage = AIChatMessage(
				id: stored.id,
				content: stored.rawText,
				isUser: false,
				parsedContent: items,
				parsingStatus: initial,
				extractedCoreContent: coreContent,
				isFinalized: true,
				sequenceIndex: stored.sequenceIndex,
				allowedFilePaths: stored.allowedFilePaths ?? [],
				modelName: stored.modelName
			)
			
			let tokenInfo = ChatTokenInfo(
				promptTokens: stored.promptTokens,
				completionTokens: stored.completionTokens,
				cost: stored.cost
			)
			aiMessage.updateTokenInfo(tokenInfo)
			
			if let delegateResults = stored.delegateResults {
				aiMessage.setDelegateResults(delegateResults)
			}
			
			return aiMessage
		}
	}
	
	@MainActor
	private func renameComposeTabIfDefault(tabID: UUID, sessionName: String) {
		let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		guard let tab = workspaceManager.composeTab(with: tabID) else { return }
		guard isDefaultComposeTabName(tab.name) else { return }
		if tab.name != trimmed {
			promptViewModel.renameComposeTab(tabID, to: trimmed)
		}
	}
	
	private func isDefaultComposeTabName(_ name: String) -> Bool {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count >= 2 else { return false }
		let prefix = trimmed.prefix(1)
		guard prefix == "T" || prefix == "t" else { return false }
		return Int(trimmed.dropFirst()) != nil
	}
	
	// MARK: - Finalise an AI response
	private func processAIResponse(
		_ finalContent: String,
		forQueryId queryId: UUID,
		sessionID: UUID) async {
		do {
			var mutableContent = finalContent

			// ─────────────────────────────────────────────────────────────
			// 1️⃣ Optional <chatName …/> extraction (unchanged behavior)
			//     • Rename only if session is still "New Chat".
			//     • Keep this on the MainActor (cheap UI work).
			// ─────────────────────────────────────────────────────────────
			if let extractedName = ChatContentParser
				.parseAndRemoveChatName(from: &mutableContent)?
				.trimmingCharacters(in: .whitespacesAndNewlines),
				!extractedName.isEmpty
			{
				await MainActor.run {
					if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
						if sessions[idx].name == "New Chat" {
							sessions[idx].name = extractedName
							print("Chat session renamed to: \(extractedName)")
						}
						if let tabID = sessions[idx].composeTabID {
							renameComposeTabIfDefault(tabID: tabID, sessionName: sessions[idx].name)
						}
					}
				}
			} else {
				await MainActor.run {
					guard let idx = sessions.firstIndex(where: { $0.id == sessionID }),
						let tabID = sessions[idx].composeTabID else { return }
					renameComposeTabIfDefault(tabID: tabID, sessionName: sessions[idx].name)
				}
			}

			// ─────────────────────────────────────────────────────────────
			// 2️⃣ Heavy work OFF the main actor
			//     • Parse AI XML into ParsedFile[]
			//     • Generate FileChanges with DiffProcessingHelper
			// ─────────────────────────────────────────────────────────────
			#if DEBUG
			let t0 = CFAbsoluteTimeGetCurrent()
			#endif

			// Capture dependencies outside the detached task to avoid capturing self.
			let capturedParser        = diffParser
			let capturedFileManager   = promptViewModel.fileManager
			let capturedPrecision     = diffViewModel.getDiffPrecision
			let capturedDelegateEdits = lastDelegateEditItems
			let contentToParse        = mutableContent

			let worker = Task.detached(priority: .userInitiated) { () throws -> ([ParsedFile], [FileChanges], [DiffProcessingHelper.DiffProcessingFailure]) in
				let parsedFiles = try await capturedParser.parse(contentToParse)
				let (fileChanges, failures) = await DiffProcessingHelper.createFileChangesDetailed(
					from: parsedFiles,
					fileManager: capturedFileManager,
					diffPrecision: capturedPrecision,
					delegateEditItems: capturedDelegateEdits
				)
				return (parsedFiles, fileChanges, failures)
			}

			let (parsedFiles, fileChanges, failures) = try await worker.value

			// ─────────────────────────────────────────────────────────────
			// 3️⃣ UI updates on MainActor: status + delegate-edit failure surfacing
			// ─────────────────────────────────────────────────────────────
			await MainActor.run {
				self.withSessionMessages(sessionID) { msgs in
					if let msgIdx = msgs.firstIndex(where: { $0.id == queryId }) {
						msgs[msgIdx].setHasParseableContent(!parsedFiles.isEmpty)
					}
				}
				if !failures.isEmpty,
					var tasks = delegateEditTasks[queryId] {
					for i in tasks.indices {
						let fp = tasks[i].filePath
						let failedCount = failures.filter {
							$0.filePath == fp || $0.filePath.hasSuffix(fp) || fp.hasSuffix($0.filePath)
						}.count
						if failedCount > 0 {
							tasks[i].status = .partialFailed(failedCount: failedCount)
						}
					}
					delegateEditTasks[queryId] = tasks
				}
			}

			// 4️⃣ Parsing status + attach diffs
			updateParsingStatus(for: queryId, fileChanges: fileChanges, parsedFiles: parsedFiles)
			await aiResponseViewModel.addResponses(fileChanges, forQueryId: queryId)

			#if debug
			let dt = CFAbsoluteTimeGetCurrent() - t0
			chatViewModelDebugLog(String(format: "processAIResponse: background parse+diff took %.2fs", dt))
			#endif

		} catch {
			print("Error processing AI response: \(error)")
		}
	}
	
	@MainActor
	func parseAndMergeChanges(forMessageId messageId: UUID) async {
		await ensureFileChangesLoaded(for: messageId)
		aiResponseViewModel.setActiveChangedFiles(forQueryId: messageId)
		mergeAction?()
	}
	
	@MainActor
	func restoreChanges(forMessageId messageId: UUID) async {
		await ensureFileChangesLoaded(for: messageId)
		aiResponseViewModel.setActiveChangedFiles(forQueryId: messageId, resetState: true)
		mergeAction?()
	}
	
	// MARK: - Rename Session
	@MainActor
	func renameSession(id: UUID, newName: String) {
		guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			print("Cannot rename session to an empty name.")
			return
		}
		guard let index = sessions.firstIndex(where: { $0.id == id }) else {
			print("Session \(id) not found for renaming.")
			return
		}

		sessions[index].name = newName

		// Persist the rename: use the appropriate save method based on whether
		// this is the current session or not.
		if id == currentSessionID {
			// Current session: autosaveChatHistory updates from live messages
			autosaveChatHistory(force: true)
		} else {
			// Non-current session: explicitly save it (stub-safe via autosaveSession)
			let sessionToSave = sessions[index]
			Task {
				do {
					let savedURL = try await autosaveSession(sessionToSave)
					// Update the sessions array with the saved fileURL
					if let idx = sessions.firstIndex(where: { $0.id == id }) {
						sessions[idx].fileURL = savedURL
						sessions[idx].savedAt = Date()
					}
				} catch {
					print("Error saving renamed session: \(error)")
				}
			}
		}
	}
	
	func addMergeButton(forQueryId queryId: UUID) {
		guard let sessionID = sessionIDByMessageId[queryId] ?? currentSessionID else { return }
		let mergeButtonMessage = AIChatMessage(
			id: UUID(),
			content: "Merge Changes",
			isUser: false,
			isMergeButton: true,
			associatedMessageId: queryId
		)
		withSessionMessages(sessionID) { msgs in
			msgs.append(mergeButtonMessage)
		}
		registerMessage(mergeButtonMessage.id, sessionID: sessionID)
		if currentSessionID == sessionID {
			currentQueryId = queryId
		}
	}
	
	@MainActor
	func refreshFileChanges(forMessageId messageId: UUID) {
		guard let sessionID = sessionIDByMessageId[messageId],
				let message = messageStore[sessionID]?.first(where: { $0.id == messageId }),
				!message.isUser else {
			print("No valid AI response to refresh")
			return
		}
		
		// If diffs are deferred, just skip refresh - nothing to refresh yet
		if deferredDiffs[messageId] != nil {
			return
		}
		
		Task {
			do {
				let content = message.combinedText
				withSessionMessages(sessionID) { msgs in
					if let idx = msgs.firstIndex(where: { $0.id == messageId }) {
						msgs[idx].updateParsingStatus(.notParsed)
						msgs[idx].setHasParseableContent(false)
						aiResponseViewModel.clearResponses(forQueryId: messageId)
					}
				}
				
				// 1) Parse using diffParser
				let parsedFiles = try await diffParser.parse(content)
				let hasUnloadableFiles = parsedFiles.contains { !$0.canBeLoaded && $0.action != .create }
				if hasUnloadableFiles {
					await MainActor.run {
						self.withSessionMessages(sessionID) { msgs in
							if let idx = msgs.firstIndex(where: { $0.id == messageId }) {
								msgs[idx].updateParsingStatus(.notParsed)
								msgs[idx].setHasParseableContent(!parsedFiles.isEmpty)
								aiResponseViewModel.clearResponses(forQueryId: messageId)
							}
						}
					}
					return
				}
				
				// 2) Gather any known ChangedFileState for that message
				let messageFileStates = produceChangedFileStatesForMessage(messageId) ?? []
				
				// 3) Build file changes using the new local helper, supplying required dependencies:
				let (localFileChanges, localOverrideDict, failures, _) = await Self.buildFileChanges(
					parsedFiles: parsedFiles,
					messageFileStates: messageFileStates,
					fileManager: self.promptViewModel.fileManager,
					diffPrecision: self.diffViewModel.getDiffPrecision,
					delegateEditItems: self.lastDelegateEditItems
				)
				
				// 4) Update parse status + AIResponseViewModel
				updateParsingStatus(for: messageId, fileChanges: localFileChanges, parsedFiles: parsedFiles)
				
				// If there are failures, mark the message as partially parsed
				if !failures.isEmpty {
					await MainActor.run {
						self.withSessionMessages(sessionID) { msgs in
							if let idx = msgs.firstIndex(where: { $0.id == messageId }) {
								msgs[idx].updateParsingStatus(.partiallyParsed)
							}
						}
						
						// Propagate failures to delegate-edit tasks
						if !failures.isEmpty,
						var tasks = self.delegateEditTasks[messageId] {

							for tIndex in tasks.indices {
								let fp = tasks[tIndex].filePath
								let failedCount = failures.filter { $0.filePath == fp }.count
								guard failedCount > 0 else { continue }

								tasks[tIndex].status = .partialFailed(failedCount: failedCount)
							}
							self.delegateEditTasks[messageId] = tasks
						}
					}
				}
				
				await aiResponseViewModel.addResponses(localFileChanges, forQueryId: messageId, overrideContents: localOverrideDict)
				
			} catch {
				print("Error refreshing file changes: \(error)")
				await MainActor.run {
					self.withSessionMessages(sessionID) { msgs in
						if let idx = msgs.firstIndex(where: { $0.id == messageId }) {
							msgs[idx].updateParsingStatus(.notParsed)
							msgs[idx].setHasParseableContent(false)
							aiResponseViewModel.clearResponses(forQueryId: messageId)
						}
					}
				}
			}
		}
	}

// MARK: - Quick bulk actions (Accept All / Restore Checkpoint)

@MainActor
func acceptAllAndSave(forMessageId messageId: UUID, includeDiffs: Bool = true) async {
	await ensureFileChangesLoaded(for: messageId)
	// Ensure the correct file set is active
	aiResponseViewModel.setActiveChangedFiles(forQueryId: messageId)
	// Perform the bulk accept + save
	await aiResponseViewModel.acceptAllAndSave(forQueryId: messageId)
	// Capture diff summaries after edits are applied
	if includeDiffs {
		await captureDiffSummaries(for: messageId)
	}
	// Persist the new state of the chat/session
	if let sessionID = sessionIDByMessageId[messageId] {
		autosaveChatHistory(for: sessionID, force: true)
	} else {
		autosaveChatHistory(force: true)
	}
}

@MainActor
func restoreCheckpoint(forMessageId messageId: UUID) async {
	await ensureFileChangesLoaded(for: messageId)
	// Reload the corresponding ChangedFile list
	aiResponseViewModel.setActiveChangedFiles(forQueryId: messageId)
	// Revert files to their original snapshot and save them
	await aiResponseViewModel.restoreCheckpoint(forQueryId: messageId)
	// Persist session state after restoring
	if let sessionID = sessionIDByMessageId[messageId] {
		autosaveChatHistory(for: sessionID, force: true)
	} else {
		autosaveChatHistory(force: true)
	}
}

	@MainActor
	func retriggerDelegateEdits(forMessageId messageId: UUID) {
		// Cancel any existing task first
		activeRetryTask?.cancel()
		
		// Make sure we're not already processing a response
		guard let sessionID = sessionIDByMessageId[messageId] ?? currentSessionID else { return }
		if isSessionStreaming(sessionID),
			let currentId = runStateBySession[sessionID]?.activeQueryId,
			let streamId = streamIDsByQueryId[currentId] {
			Task { await aiQueriesService.cancelStream(id: streamId) }
			streamIDsByQueryId.removeValue(forKey: currentId)
			clearSessionStreaming(sessionID)
		}
		setSessionStreaming(sessionID, queryId: messageId, streamId: nil)
		
		// Kill any watchdog for this message; we're re-entering in‑progress state
		cancelFinalizationWatchdog(for: messageId)
		
		// Find the message we're retrying
		guard let messageIndex = messageStore[sessionID]?.firstIndex(where: { $0.id == messageId }),
				messageStore[sessionID]?[messageIndex].isUser == false else {
				clearSessionStreaming(sessionID)
				print("No AI message found with ID \(messageId)")
				return
		}

		// 🔄 Refresh <allowedFilePaths> from the user's current selection
		let freshPaths = promptViewModel.fileManager
			.selectedFiles.map(\.fullPath)
		withSessionMessages(sessionID) { msgs in
			if msgs.indices.contains(messageIndex) {
				msgs[messageIndex].setAllowedPaths(freshPaths)
			}
		}

		// Get the existing message content
		let existingMessage = messageStore[sessionID]?[messageIndex]
		let existingContent = existingMessage?.content ?? ""
		
		// 🔹 Include both `.failed` *and* `.partialFailed` tasks
		let failedTasks = delegateEditTasks[messageId]?.filter {
			switch $0.status {
			case .failed, .partialFailed, .noChangesMade:
				return true
			default:
				return false
			}
		} ?? []
		
		if failedTasks.isEmpty {
			print("No failed or partially-failed delegate edits to retry for message \(messageId)")
			clearSessionStreaming(sessionID)
			return
		}
		
		// 🆕 0) Re-build the dictionary so only *successful* edits remain
		rebuildDelegateResults(for: messageId)

		/*
			// 🆕 1) Purge XML blocks belonging to the tasks we are about to retry
			let retryPaths = Set(failedTasks.map(\.filePath))
		purgeDelegateResults(forFilePaths: retryPaths, inMessageId: messageId)
		*/

		// Mark parent AI message dirty / in‑progress
		withSessionMessages(sessionID) { msgs in
			if msgs.indices.contains(messageIndex) {
				msgs[messageIndex].setHasPendingDelegateWork(true)
				msgs[messageIndex].setHasCompletedDelegateWork(false)
				msgs[messageIndex].setIsFinalized(false)
				msgs[messageIndex].updateParsingStatus(.notYetParsed)
			}
		}
		
		// Create and store the task so it can be cancelled
		activeRetryTask = Task {
			do {
				await delegateEditTaskManager.cancelTasks(forMessageId: messageId)
				
				// Kick off retries, **re‑using the same task‑IDs**
				for t in failedTasks {
					try Task.checkCancellation()
					print("Failed task: \(t.id), retrying... ")
					
					// Reset visual state
					if var list = delegateEditTasks[messageId],
						let i = list.firstIndex(where: { $0.id == t.id }) {
						list[i].status           = .inProgress
						list[i].accumulatedOutput = ""
						list[i].tokenEstimate     = 0
						delegateEditTasks[messageId] = list
					}
					//print("List of tasks: \(delegateEditTasks[messageId] ?? [])\n")

					let item = DelegateEditItem(filePath: t.filePath, changes: t.changes)
					await triggerAIQuery(for: item,
											messageId: messageId,
											force: true,
											retryStatus: t.status)
				}
				
				try Task.checkCancellation()
				await finalizeAIResponse(aiResponseId: messageId, sessionID: sessionID, partialBuffer: existingContent)
				
				await MainActor.run { activeRetryTask = nil }
			} catch is CancellationError {
				await MainActor.run {
					print("Retry delegate edits task was cancelled")
					guard let idx = messageStore[sessionID]?.firstIndex(where: { $0.id == messageId }) else { return }
					withSessionMessages(sessionID) { msgs in
						if msgs.indices.contains(idx) {
							msgs[idx].setIsFinalized(true)
						}
					}
					let finalContent = messageStore[sessionID]?[idx].content ?? ""
					Task {
						await processAIResponse(finalContent, forQueryId: messageId, sessionID: sessionID)
						autosaveChatHistory(for: sessionID)
					}
					clearSessionStreaming(sessionID)
					activeRetryTask = nil
				}
			} catch {
				await MainActor.run {
					print("Error retrying delegate edits: \(error)")
					clearSessionStreaming(sessionID)
					activeRetryTask = nil
				}
			}
		}
	}
	private func rebuildDelegateResults(for messageId: UUID) {
		// Keep only the results coming from tasks that *actually* completed
		guard let sessionID = sessionIDByMessageId[messageId],
				let msgIdx = messageStore[sessionID]?.firstIndex(where: { $0.id == messageId }) else { return }
		let successfulIds: Set<UUID> = Set(
			delegateEditTasks[messageId]?
				.filter {
					switch $0.status {
					case .completed, .noChangesMade:
						return true
					default:
						return false
					}
				}
				.map(\.id) ?? []
		)
		withSessionMessages(sessionID) { msgs in
			if msgs.indices.contains(msgIdx) {
				let filtered = msgs[msgIdx].delegateResults
					.filter { successfulIds.contains($0.key) }
				msgs[msgIdx].setDelegateResults(filtered)
			}
		}
	}
	
	/// Triggers an AI query for a delegate edit item by delegating to the actor
	@MainActor
	func triggerAIQuery(
		for item: DelegateEditItem,
		resolvedPath canonicalPath: String? = nil,
		messageId: UUID,
		force: Bool = false,
		retryStatus: DelegateEditTask.TaskStatus? = nil
	) async {
		guard let sessionID = sessionIDByMessageId[messageId] else { return }
		// Delegate work is owned by the parent assistant message being finalized.
		let qId = messageId
		guard let parentMsg = messageStore[sessionID]?.first(where: { $0.id == messageId }) else { return }
		let useAgentMode = promptViewModel.proEditAgentMode
		let delegateDisplayName = useAgentMode ? promptViewModel.proEditAgentKind.displayName : ""

		// 1️⃣ Resolve the actual target path
		let targetPath: String? = {
			if let canonicalPath { return canonicalPath }
			return String.findClosestPath(item.filePath,
											among: parentMsg.allowedFilePaths)
		}()

		// If we still cannot map the path, mark the task as failed
		guard let matched = targetPath else {
			let failedTask = DelegateEditTask(
				id:               UUID(),
				filePath:         item.filePath,
				changes:          item.changes,
				modelDisplayName: delegateDisplayName,
				status:           .failed(reason: .fileNotSelected),
				resolvedFilePath: nil)
			createDelegateEditTask(for: qId, task: failedTask)

			withSessionMessages(sessionID) { msgs in
				if let idx = msgs.firstIndex(where: { $0.id == qId }) {
					msgs[idx].setHasPendingDelegateWork(false)
					msgs[idx].setHasCompletedDelegateWork(true)
				}
			}
			return
		}

		// 2️⃣ Gate duplicate requests per AI message
		let key = DelegateEditItem.buildRequestKey(path: matched, changes: item.changes)
		var launchedKeys = launchedDelegateKeysByMessage[qId] ?? Set<String>()
		if !force && launchedKeys.contains(key) {
			EditFlowPerf.event(
				EditFlowPerf.Stage.Delegate.taskDuplicateSkip,
				EditFlowPerf.Dimensions(
					status: "chat_duplicate",
					editCount: item.changes.count,
					taskCount: delegateEditTasks[qId]?.count ?? 0,
					isForced: force,
					isAgentMode: useAgentMode
				)
			)
			return
		}
		launchedKeys.insert(key)
		launchedDelegateKeysByMessage[qId] = launchedKeys

		// 3️⃣ Create a fresh UI task (new UUID every time)
		let taskId = UUID()

		let uiTask = DelegateEditTask(
			id:               taskId,
			filePath:         item.filePath,
			changes:          item.changes,
			modelDisplayName: delegateDisplayName,
			status:           .inProgress,
			resolvedFilePath: matched)
		createDelegateEditTask(for: qId, task: uiTask)
		EditFlowPerf.event(
			EditFlowPerf.Stage.Delegate.taskSpawn,
			EditFlowPerf.Dimensions(
				status: "spawned",
				editCount: item.changes.count,
				taskCount: delegateEditTasks[qId]?.count ?? 0,
				isForced: force,
				isAgentMode: useAgentMode
			)
		)

		// 4️⃣ Run the delegate-edit worker in the background
		let worker = Task.detached(priority: .userInitiated) { [delegateEditHandler] in
			let req = DelegateEditRequest(
				parentMessageId: messageId,
				currentQueryId:  qId,
				delegateItem:    item,
				chatVM:          self,
				taskId:          taskId,
				matchedPath:     matched,
				retryStatus:     retryStatus)
			_ = await delegateEditHandler.run(req)
		}
		await delegateEditTaskManager.addTask(worker, forMessageId: qId)
	}

	@MainActor
	func completeDelegateEdit(_ taskId: UUID) {
		activeDelegateEdits.remove(taskId)
		//updateAIResponseInProgressFlag()
	}
	
	// MARK: - Delegate-edit helpers (public wrapper)
	func waitForDelegateEditTasks() async {
		await delegateEditTaskManager.waitForAllTasks()
	}
	
	func updateDelegateEditTaskStatus(messageId: UUID, taskId: UUID, status: DelegateEditTask.TaskStatus) {
		if var tasks = delegateEditTasks[messageId] {
			if let index = tasks.firstIndex(where: { $0.id == taskId }) {
				tasks[index].status = status
				delegateEditTasks[messageId] = tasks
			}
		}
	}
	
	/*
	// MARK: – Delegate-result cleanup
	private func purgeDelegateResults(
		forFilePaths rawPaths: Set<String>,
		inMessageId messageId: UUID
	) {
		// 0️⃣ Locate the AI message that owns these delegate results.
		guard let msgIdx = messages.firstIndex(where: { $0.id == messageId }) else { return }
		
		// 1️⃣ Current task list (empty if none).
		var tasks = delegateEditTasks[messageId] ?? []
		
		// 2️⃣ Pre-compute *normalised* component arrays for all retry targets.
		let targetComps = rawPaths.map(Self.normalisedComponents)
		
		// 3️⃣ Helper capturing our sophisticated path-matching rules.
		func matches(_ lhs: [String], _ rhs: [String]) -> Bool {
			// Fast path – identical arrays.
			if lhs == rhs { return true }
			
			// Filename-only comparison.
			if lhs.count == 1, rhs.count == 1 { return lhs[0] == rhs[0] }
			
			// Require the *entire* shorter path (≥2 comps) to be a suffix of the longer.
			let short = lhs.count <= rhs.count ? lhs : rhs
			let long  = lhs.count  > rhs.count ? lhs : rhs
			guard short.count >= 2 else { return false }
			return long.suffix(short.count).elementsEqual(short)
		}
		
		// 4️⃣ Determine which task IDs should be purged based on the new matcher.
		let purgeIds: Set<UUID> = Set(
			tasks.compactMap { task in
				let taskComps = Self.normalisedComponents(task.filePath)
				return targetComps.contains(where: { matches(taskComps, $0) }) ? task.id : nil
			}
		)
		
		guard !purgeIds.isEmpty else { return }
		
		// 5️⃣ Remove diff-hunks from the AI message…
		messages[msgIdx].removeDelegateResults(for: Array(purgeIds))
		
		// 6️⃣ …and prune the task list to keep state consistent.
		tasks.removeAll { purgeIds.contains($0.id) }
		delegateEditTasks[messageId] = tasks
	}
	*/

	// MARK: - Parsing Status
	@MainActor
	func updateParsingStatus(for queryId: UUID,
								fileChanges: [FileChanges],
								parsedFiles: [ParsedFile])
	{
		guard let sessionID = sessionIDByMessageId[queryId] else { return }
		withSessionMessages(sessionID) { msgs in
			guard let idx = msgs.firstIndex(where: { $0.id == queryId }) else { return }
			var message = msgs[idx]
			message.clearLoadErrors()
			
			// 1) unloadable files ---------------------------------------------------
			let unloadableFiles = parsedFiles.filter { !$0.canBeLoaded && $0.action != .create }
			if !unloadableFiles.isEmpty {
				message.setHasUnloadableFiles(true)
				let errors = unloadableFiles.map {
					"File '\($0.fileName)' could not be loaded or no longer exists."
				}
				for error in errors { message.appendLoadError(error) }
			}
			
			// 2) any file changes? ---------------------------------------------------
			message.hasAnyFileChanges = !fileChanges.isEmpty
			
			// 3) file counters ------------------------------------------------------
			let totalFiles    = parsedFiles.count
			let loadableFiles = parsedFiles.filter { $0.canBeLoaded || $0.action == .create }.count
			
			message.setParsedFileCount(loadableFiles)
			message.setTotalChangeCount(fileChanges.reduce(0) { $0 + $1.changes.count })
			
			// 4) fully- vs. partially-parsed logic ----------------------------------
			var allParsed = true
			var anyParsed = false
			
			chatViewModelDebugLog("updateParsingStatus \(queryId)")
			chatViewModelDebugLog("parsedFiles.count = \(parsedFiles.count)")
			chatViewModelDebugLog("fileChanges.count = \(fileChanges.count)")
			
			for fileChange in fileChanges {
				chatViewModelDebugLog("fileChange.path = \(fileChange.path)")
				
				if let parsedFile = parsedFiles.first(where: {
					let fn = $0.fileName
					return fileChange.path.contains(fn) || fn.contains(fileChange.path)
				}) {
					chatViewModelDebugLog("matched ParsedFile '\(parsedFile.fileName)'")
					chatViewModelDebugLog("pf.changes = \(parsedFile.changes.count)")
					chatViewModelDebugLog("fc.changes = \(fileChange.changes.count)")
					chatViewModelDebugLog("pf.canBeLoaded = \(parsedFile.canBeLoaded)")
					chatViewModelDebugLog("pf.action = \(parsedFile.action)")
					
					if parsedFile.changes.isEmpty
						|| (!parsedFile.canBeLoaded && parsedFile.action != .create) {
						allParsed = false
						chatViewModelDebugLog("flagged allParsed = false (empty or unloadable)")
					} else if parsedFile.changes.count <= fileChange.changes.count {
						anyParsed = true
						chatViewModelDebugLog("anyParsed = true (counts OK)")
					} else {
						allParsed = false
						anyParsed = true
						chatViewModelDebugLog("allParsed = false, anyParsed = true (pf > fc)")
					}
				} else {
					allParsed = false
					chatViewModelDebugLog("no matching ParsedFile; allParsed = false")
				}
			}
			
			// 5) decide status ------------------------------------------------------
			let newStatus: MessageParsingStatus
			if loadableFiles == totalFiles && allParsed && anyParsed {
				newStatus = .fullyParsed
			} else if anyParsed {
				newStatus = .partiallyParsed
			} else {
				newStatus = .notParsed
			}
			
			chatViewModelDebugLog("""
			—— summary ————————————————————————————————
			loadableFiles / totalFiles = \(loadableFiles)/\(totalFiles)
			allParsed = \(allParsed)   anyParsed = \(anyParsed)
			→ newStatus = \(newStatus)
			————————————————————————————————————————————
			""")
			
			// 6) commit --------------------------------------------------------------
			message.updateParsingStatus(newStatus)
			message.setIsFinalized(true)
			message.setHasParseableContent(totalFiles > 0)
			message.setHasCompletedDelegateWork(true)
			message.setHasPendingDelegateWork(false)
			
			msgs[idx] = message
		}
	}

	
	// MARK: - Utilities
	func getChatMessage(withId id: UUID) -> AIChatMessage? {
		if let sessionID = sessionIDByMessageId[id],
			let sessionMessages = messageStore[sessionID] {
			return sessionMessages.first { $0.id == id }
		}
		return messages.first { $0.id == id }
	}

	@MainActor
	func updateMessage(withId id: UUID, _ mutate: (inout AIChatMessage) -> Void) {
		guard let sessionID = sessionIDByMessageId[id] else { return }
		withSessionMessages(sessionID) { msgs in
			if let idx = msgs.firstIndex(where: { $0.id == id }) {
				mutate(&msgs[idx])
			}
		}
	}
	
	func isLatestMessage(_ message: AIChatMessage) -> Bool {
		let visibleMessages = visibleMessages(containing: message)
		return visibleMessages.last?.id == message.id
	}


	private func visibleMessages(containing message: AIChatMessage) -> [AIChatMessage] {
		if let sessionID = sessionIDByMessageId[message.id],
			let sessionMessages = messageStore[sessionID] {
			return sessionMessages
		}
		return messages
	}
	
	private func packageConversationHistory() -> String {
		var history = "<conversation_history>\n"
		if let session = currentSession, session.name != "New Chat", !session.name.isEmpty {
			history += "<chatName=\"\(session.name)\"/>\n"
		}
		for i in 0..<(messages.count - 1) {
			let msg = messages[i]
			if msg.isUser {
				history += "{user message: \(msg.content)}\n"
			} else {
				if let coreContent = msg.extractedCoreContent {
					history += "{AI response: \(coreContent)}\n"
				} else {
					history += "{AI response: \(msg.content)}\n"
				}
			}
		}
		history += "</conversation_history>"
		print(history)
		return history
	}
	
	func bindingForReasoningContent(of messageId: UUID) -> Binding<String> {
		return Binding<String>(
			get: {
				// Only access ephemeral state if message still exists
				if self.messages.contains(where: { $0.id == messageId }) {
					return self.ephemeralState.reasoningContent(for: messageId)
				} else {
#if DEBUG
					print("Warning: Binding accessed reasoning for non-existent message: \(messageId)")
#endif
					return ""
				}
			},
			set: { newValue in
				// Only update if message still exists
				if self.messages.contains(where: { $0.id == messageId }) {
					self.ephemeralState.setReasoningContent(newValue, for: messageId)
				} else {
#if DEBUG
					print("Warning: Binding attempted to update reasoning for non-existent message: \(messageId)")
#endif
				}
			}
		)
	}

	@MainActor
	func restoreFileSelection(from message: AIChatMessage) async {
		let paths = message.allowedFilePaths
		guard !paths.isEmpty else { return }
		await promptViewModel.fileManager.selectFiles(
			withPaths: paths,
			allowEmpty: false,
			clear: true
		)
	}
	
	func storeTextAndSend(for sessionId: UUID?, _ text: String) {
		storeDraftText(for: sessionId, text)
		programmaticSetText.send(text)
	}
	
	/// Programmatically set the input text via the PassthroughSubject
	func programmaticallySetText(_ newText: String) {
		programmaticSetText.send(newText)
	}
	
	/// Store draft text for a specific session
	func storeDraftText(for sessionId: UUID?, _ text: String) {
		guard let sid = sessionId else { return }
		ephemeralDrafts[sid] = text
		inputText = text
	}
	
	/// Retrieve draft text for a specific session
	func retrieveDraftText(for sessionId: UUID?) -> String {
		guard let sid = sessionId else { return "" }
		return ephemeralDrafts[sid] ?? ""
	}

	// ------------------------------------------------------------------
	// MARK: – File-selection helpers (used by file-list popover)
	// ------------------------------------------------------------------
	/// Adds every stored path from the given assistant message to the
	/// current selection *without* clearing existing selections.
	@MainActor
	func addFileSelection(from message: AIChatMessage) async {
		guard !message.allowedFilePaths.isEmpty else { return }
		await promptViewModel.fileManager.selectFiles(
			withPaths: message.allowedFilePaths,
			allowEmpty: false,
			clear: false           // ← additive
		)
	}
	
	/// Toggles a single path on or off in the current file-tree selection.
	@MainActor
	func toggleFileSelection(path: String, select: Bool) async {
		if select {
			promptViewModel.fileManager.selectPath(path, kind: .file)
		} else {
			promptViewModel.fileManager.deselectPath(path, kind: .file)
		}
	}
	
	/// Returns `true` when the given relative path is currently selected in the file tree.
	@MainActor
	func isFileSelected(_ path: String) -> Bool {
		promptViewModel.fileManager.isFileSelected(path)
	}
}
