import Foundation
import MCP

// MARK: - Test Helpers
// Test support extensions extracted from AgentModeViewModel.swift for maintainability.
// Includes #if DEBUG unit test wrappers and stress harness methods.

// MARK: - Unit Test Wrappers

#if DEBUG
extension AgentModeViewModel {
	func test_resetUpdateBindingsCallCount() {
		test_updateBindingsCallCount = 0
	}


	func test_activeTranscriptPresentationRevisionValue() -> Int {
		activeTranscriptPresentationRevision
	}

	func test_applySessionToBindings(tabID: UUID) {
		guard let session = sessions[tabID] else { return }
		applySessionToBindings(session)
	}

	func test_updateBindingsFromSession(tabID: UUID) {
		guard let session = sessions[tabID] else { return }
		updateBindingsFromSession(session)
	}

	func test_setCompressedHistoryVisibility(tabID: UUID, isRevealed: Bool) {
		setCompressedHistoryVisibility(tabID: tabID, isRevealed: isRevealed)
	}

	func test_rebuildStructuredTranscript(tabID: UUID, isColdLoad: Bool = false) {
		let session = session(for: tabID)
		refreshDerivedTranscriptState(
			for: session,
			reason: isColdLoad ? .coldLoad : .manualRefresh
		)
	}

	func test_drainScheduledDerivedTranscriptRefresh(tabID: UUID) async {
		while let session = sessions[tabID], let task = session.derivedTranscriptRefreshTask {
			let generation = session.derivedTranscriptRefreshGeneration
			await task.value
			await Task.yield()
			if session.derivedTranscriptRefreshTask != nil,
				session.derivedTranscriptRefreshGeneration == generation,
				task.isCancelled {
				session.derivedTranscriptRefreshTask = nil
			}
		}
	}

	func test_flushSave(tabID: UUID) async {
		await flushSave(for: tabID)
	}

	func test_canReuseDerivedTranscriptForSave(tabID: UUID) -> Bool {
		let session = session(for: tabID)
		let projectionProtection = transcriptProjectionProtection(
			for: session,
			transcript: session.transcript
		)
		return canReuseDerivedTranscriptForSave(
			for: session,
			projectionProtection: projectionProtection
		)
	}

	func test_persistedHydrationTranscriptViewportState(tabID: UUID) -> AgentTranscriptViewportState {
		persistedHydrationTranscriptViewportState(for: session(for: tabID))
	}

	func test_ephemeralToolResultPayloadMap(tabID: UUID) -> [UUID: String] {
		session(for: tabID).ephemeralToolResultPayloadByItemID
	}

	func test_applyTranscriptPresentationFromCapturedItems(
		tabID: UUID,
		isColdLoad: Bool = false,
		mutateSessionAfterCapture: ((TabSession) -> Void)? = nil
	) {
		let session = session(for: tabID)
		let capturedItems = session.items
		let capturedRunState = session.runState
		let capturedNextSequenceIndex = session.nextSequenceIndex
		let capturedTranscript = session.transcript
		let projectionProtection = transcriptProjectionProtection(
			for: session,
			transcript: capturedTranscript
		)
		let transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
			existingTranscript: capturedTranscript,
			workingItems: capturedItems,
			terminalState: capturedRunState,
			nextSequenceIndex: capturedNextSequenceIndex,
			policy: .liveSession(hidePendingQuestionToolCall: session.hasPendingQuestionUI),
			protection: projectionProtection
		)
		mutateSessionAfterCapture?(session)
		applyTranscriptPresentation(
			transcript,
			sourceItems: capturedItems,
			to: session,
			isColdLoad: isColdLoad
		)
	}

	func test_visibleTranscriptSequenceIndices(tabID: UUID) -> [Int] {
		session(for: tabID).transcriptProjection.workingRows.map(\.sequenceIndex)
	}
	
	func test_renderProviderMessage(
		text: String,
		attachments: [AgentImageAttachment],
		agent: DiscoverAgentKind
	) -> String {
		renderProviderMessage(text: text, attachments: attachments, agent: agent)
	}

	func test_submitUserTurn(tabID: UUID, text: String) -> UserTurnSubmissionResult {
		submitUserTurn(text: text, tabID: tabID)
	}

	func test_escapePathForAtCommand(_ path: String) -> String {
		escapePathForAtCommand(path)
	}

	func test_extractTaggedPaths(from text: String) -> [String] {
		Self.extractTaggedPaths(from: text)
	}

	func test_extractSlashSkillTokenNames(from text: String) -> [String] {
		Self.extractSlashSkillTokens(from: text).map(\.name)
	}

	func test_resolvedSlashSkillInvocationNames(from text: String) -> [String] {
		resolvedSlashSkillInvocations(in: text).map { $0.definition.name }
	}

	func test_augmentUserMessageForProviderSend(
		_ text: String,
		attachments: [AgentImageAttachment] = [],
		taggedFileAttachments: [AgentTaggedFileAttachment] = [],
		agent: DiscoverAgentKind? = nil
	) async -> String {
		await augmentUserMessageForProviderSend(
			text,
			attachments: attachments,
			taggedFileAttachments: taggedFileAttachments,
			agent: agent
		)
	}

	func test_shouldAttemptTaggedFileAutoSelection(
		text: String,
		taggedFileAttachments: [AgentTaggedFileAttachment]
	) -> Bool {
		Self.shouldAttemptTaggedFileAutoSelection(
			text: text,
			taggedFileAttachments: taggedFileAttachments
		)
	}

	func test_selectionByPromotingPathsToFullSelection(
		selection: StoredSelection,
		paths: [String]
	) -> StoredSelection {
		Self.selectionByPromotingPathsToFullSelection(selection, paths: paths)
	}

	func test_composeInitialThreadMessage(
		initialMessage: String,
		fileTree: String,
		promptText: String?
	) -> String {
		Self.composeInitialThreadMessage(
			initialMessage: initialMessage,
			fileTree: fileTree,
			promptText: promptText
		)
	}

	func test_shouldIncludeInitialThreadContext(for session: TabSession) -> Bool {
		shouldIncludeInitialThreadContext(for: session)
	}

	func test_composeClaudeResumeRecoveryHandoffPayload(
		sourceTabName: String,
		sourceAgentName: String,
		transcriptXML: String,
		fileTree: String,
		promptText: String?,
		deliveryID: String = "delivery-1"
	) -> String {
		let initialThreadContextBlock = Self.composeInitialThreadMessage(
			initialMessage: "",
			fileTree: fileTree,
			promptText: promptText
		).trimmingCharacters(in: .whitespacesAndNewlines)
		return Self.composeClaudeResumeRecoveryHandoffPayload(
			sourceTabName: sourceTabName,
			sourceAgentName: sourceAgentName,
			transcriptXML: transcriptXML,
			initialThreadContextBlock: initialThreadContextBlock.isEmpty ? nil : initialThreadContextBlock,
			deliveryID: deliveryID
		)
	}

	func test_composeSessionHandoffPayload(
		sourceTabName: String,
		sourceAgentName: String,
		sourceModelName: String,
		fileContentsBlock: String?,
		transcriptXML: String,
		deliveryID: String = "delivery-1"
	) -> String {
		Self.composeSessionHandoffPayload(
			sourceTabName: sourceTabName,
			sourceAgentName: sourceAgentName,
			sourceModelName: sourceModelName,
			fileContentsBlock: fileContentsBlock,
			transcriptXML: transcriptXML,
			deliveryID: deliveryID
		)
	}

	func test_clearBindings() {
		clearBindings()
	}

	func test_handleComposeTabsWillClose(_ tabIDs: Set<UUID>) async {
		await handleComposeTabsWillClose(tabIDs, reason: .close)
	}

	func test_handleWorkspaceSwitch(_ workspace: WorkspaceModel?) async {
		await handleWorkspaceSwitch(workspace)
	}

	func test_waitForWorkspaceSwitchBackgroundCleanup() async {
		while !workspaceSwitchBackgroundCleanupTasks.isEmpty {
			let tasks = Array(workspaceSwitchBackgroundCleanupTasks.values)
			for task in tasks {
				await task.value
			}
		}
	}

	func test_resolvedSessionID(for tabID: UUID) -> UUID? {
		session(for: tabID, createIfNeeded: false)?.activeAgentSessionID
	}

	func test_markSessionAsFreshlyCreated(tabID: UUID) {
		guard let session = sessions[tabID] else { return }
		markSessionAsFreshlyCreated(session)
	}

	func test_seedSessionIndexEntry(sessionID: UUID, tabID: UUID, parentSessionID: UUID? = nil) {
		let name = "Test Session"
		upsertSessionIndex(
			sessionID: sessionID,
			tabID: tabID,
			name: name,
			lastUserMessageAt: nil,
			savedAt: Date(),
			lastRunStateRaw: nil,
			itemCount: 0,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: ApplyEditsApprovalStore.globalDefaultAutoEditEnabled(),
			parentSessionID: parentSessionID
		)
	}

	func test_mcpSpawnParentSessionID(sourceTabID: UUID?) -> UUID? {
		mcpSpawnParentSessionID(sourceTabID: sourceTabID)
	}

	func test_applySpawnParentSessionID(_ parentSessionID: UUID?, tabID: UUID) {
		let session = session(for: tabID)
		applySpawnParentSessionID(parentSessionID, to: session)
	}

	func test_upsertSessionIndex(
		sessionID: UUID,
		tabID: UUID,
		name: String,
		lastUserMessageAt: Date?,
		savedAt: Date,
		lastRunStateRaw: String?,
		itemCount: Int,
		agentKindRaw: String?,
		agentModelRaw: String?,
		agentReasoningEffortRaw: String?,
		autoEditEnabled: Bool,
		parentSessionID: UUID? = nil,
		hasUnknownConversationContent: Bool = false
	) {
		upsertSessionIndex(
			sessionID: sessionID,
			tabID: tabID,
			name: name,
			lastUserMessageAt: lastUserMessageAt,
			savedAt: savedAt,
			lastRunStateRaw: lastRunStateRaw,
			itemCount: itemCount,
			agentKindRaw: agentKindRaw,
			agentModelRaw: agentModelRaw,
			agentReasoningEffortRaw: agentReasoningEffortRaw,
			autoEditEnabled: autoEditEnabled,
			parentSessionID: parentSessionID,
			hasUnknownConversationContent: hasUnknownConversationContent
		)
	}

	/// Test wrapper for `prepareMCPWaitTrackingForRunStart(session:)`.
	/// Returns `true` if the helper ran for an MCP-controlled session.
	func test_prepareMCPWaitTrackingForRunStart(tabID: UUID) async -> Bool {
		guard let session = sessions[tabID] else { return false }
		let hadMCPContext = session.mcpControlContext != nil
		await prepareMCPWaitTrackingForRunStart(session: session)
		return hadMCPContext
	}
}
#endif

// MARK: - Stress Harness Helpers

extension AgentModeViewModel {
	enum MockTranscriptRole {
		case user
		case assistant
		case assistantInline
		case thinking
		case system
	}

	func testBindSessionToActiveSessionProxies(tabID: UUID) async {
		let session = await ensureSessionReady(tabID: tabID)
		applySessionToBindings(session)
	}

	func testPrepareStressSession(tabID: UUID) async {
		let session = await ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModelRaw = defaultModelRaw(for: .codexExec)
		session.selectedReasoningEffortRaw = nil
		session.pendingAskUser = nil
		session.pendingApproval = nil
		session.pendingPermissionsRequest = nil
		session.pendingMCPElicitationRequest = nil
		session.queuedMCPElicitationRequests.removeAll()
		session.pendingApplyEditsReview = nil
		session.waitingPrompt = nil
		session.runningStatusText = "Stress harness running"
		session.runState = .running
		applyTranscriptViewportBindingState(
			to: session,
			viewportState: .liveBottom,
			armingState: .armed
		)
		session.markHydrationLoaded(for: session.activeAgentSessionID)
		requestUIRefresh(tabID: tabID, urgent: true)
	}

	func testResetStressTranscript(tabID: UUID) async {
		let session = await ensureSessionReady(tabID: tabID)
		session.setItemsSilently([], reason: .stressHarnessReset)
		session.clearDerivedTranscriptCaches()
		session.pendingAskUser = nil
		session.pendingApproval = nil
		session.pendingPermissionsRequest = nil
		session.pendingMCPElicitationRequest = nil
		session.queuedMCPElicitationRequests.removeAll()
		session.pendingApplyEditsReview = nil
		session.waitingPrompt = nil
		session.runningStatusText = nil
		session.runState = .idle
		session.runID = nil
		session.activeHeadlessRunAttemptID = nil
		session.provider = nil
		session.agentTask?.cancel()
		session.agentTask = nil
		session.providerSessionID = nil
		session.providerTokenUsageByTurn = []
		session.pendingNonCodexUserInputTokenQueue = []
		session.activeNonCodexTurnTokenAccumulator = nil
		session.codexConversationID = nil
		session.codexRolloutPath = nil
		session.codexModel = nil
		session.codexReasoningEffort = nil
		session.codexServiceTier = nil
		session.codexContextUsage = nil
		session.contextUsageSnapshot = nil
		session.contextCompactedAt = nil
		session.codexNeedsReconnect = false
		session.codexController = nil
		session.codexControllerPermissionProfile = nil
		session.codexControllerTaskLabelKind = nil
		session.claudeController = nil
		session.claudeControllerRuntimeVariant = nil
		session.claudeControllerPermissionMode = nil
		session.codexEventTask?.cancel()
		session.codexEventTask = nil
		session.codexEventTaskRunID = nil
		session.codexLastEventAt = nil

		session.claudeExpectedTurnIDs = []
		session.claudeSupersedingProtectedTurnIDs = []
		session.hasReconciledPersistedCodexCommandStatus = false
		session.activeReasoningItemID = nil
		session.reasoningItemIDsByGroupID = [:]
		session.pendingAssistantDelta = ""
		session.assistantDeltaFlushTask?.cancel()
		session.assistantDeltaFlushTask = nil
		session.pendingInstructions = []
		session.pendingClaudeSteeringInstructions = []
		session.pendingACPSteeringInstructions = []
		session.pendingCodexCompactionInstructions = []
		session.codexPendingTurnKind = nil
		session.codexTurnKindsByID = [:]
		session.pendingCommandRunningByKey = [:]
		session.pendingCommandRunningFlushTask?.cancel()
		session.pendingCommandRunningFlushTask = nil
		session.pendingHandoff = .init()
		session.nextSequenceIndex = 0
		session.hasSentFirstMessage = false
		applyTranscriptViewportBindingState(
			to: session,
			viewportState: .liveBottom,
			armingState: .armed
		)
		requestUIRefresh(tabID: tabID, urgent: true)
	}

	func testAppendMockTranscriptMessage(
		tabID: UUID,
		role: MockTranscriptRole,
		text: String,
		urgentUIRefresh: Bool = true
	) {
		let session = session(for: tabID)
		let item: AgentChatItem
		switch role {
		case .user:
			item = .user(text, sequenceIndex: session.nextSequenceIndex)
		case .assistant:
			item = .assistant(text, sequenceIndex: session.nextSequenceIndex)
		case .assistantInline:
			item = .assistantInline(text, sequenceIndex: session.nextSequenceIndex)
		case .thinking:
			item = .thinking(text, sequenceIndex: session.nextSequenceIndex)
		case .system:
			item = .system(text, sequenceIndex: session.nextSequenceIndex)
		}
		session.appendItem(item)
		requestUIRefresh(tabID: tabID, urgent: urgentUIRefresh)
	}

	func testAppendStreamingAssistantDelta(
		tabID: UUID,
		delta: String,
		urgentUIRefresh: Bool = true
	) {
		let session = session(for: tabID)
		applyAssistantDelta(delta, session: session)
		requestUIRefresh(tabID: tabID, urgent: urgentUIRefresh)
	}

	func testFinalizeStreamingAssistant(
		tabID: UUID,
		urgentUIRefresh: Bool = true
	) {
		let session = session(for: tabID)
		endActiveAssistantSegment(session)
		requestUIRefresh(tabID: tabID, urgent: urgentUIRefresh)
	}

	func testSetStressRunState(
		tabID: UUID,
		state: AgentSessionRunState,
		statusText: String?,
		urgentUIRefresh: Bool = true
	) {
		let session = session(for: tabID)
		session.runState = state
		session.runningStatusText = statusText
		requestUIRefresh(tabID: tabID, urgent: urgentUIRefresh)
	}

	@discardableResult
	func testSeedTextDerivationFixture(tabID: UUID, reset: Bool = true) async -> [String: Int] {
		if reset {
			await testResetStressTranscript(tabID: tabID)
		}
		let session = await ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModelRaw = defaultModelRaw(for: .codexExec)
		session.runState = .completed
		session.runningStatusText = nil
		session.pendingAskUser = nil
		session.pendingApproval = nil
		session.pendingPermissionsRequest = nil
		session.pendingMCPElicitationRequest = nil
		session.queuedMCPElicitationRequests.removeAll()
		session.pendingApplyEditsReview = nil
		session.waitingPrompt = nil
		session.markHydrationLoaded(for: session.activeAgentSessionID)

		var appended: [String: Int] = [:]
		func append(_ item: AgentChatItem, bucket: String) {
			session.appendItem(item)
			appended[bucket, default: 0] += 1
		}

		append(.user("Seed DEBUG text-derivation fixture for transcript rendering measurement.", sequenceIndex: session.nextSequenceIndex), bucket: "user")
		append(.assistant(Self.testLongAssistantText(label: "old-collapsible-assistant", includeCodeFence: true), sequenceIndex: session.nextSequenceIndex), bucket: "assistant")

		let plainInvocationID = UUID()
		append(
			.toolCall(
				name: "debug_text_derivation_plain",
				invocationID: plainInvocationID,
				argsJSON: Self.testLargeToolArgsJSON(kind: "plain"),
				sequenceIndex: session.nextSequenceIndex
			),
			bucket: "toolCall"
		)
		append(
			.toolResult(
				name: "debug_text_derivation_plain",
				invocationID: plainInvocationID,
				resultJSON: Self.testPlainToolOutput(),
				sequenceIndex: session.nextSequenceIndex
			),
			bucket: "toolResult"
		)

		let diffInvocationID = UUID()
		append(
			.toolCall(
				name: "debug_text_derivation_diff",
				invocationID: diffInvocationID,
				argsJSON: Self.testLargeToolArgsJSON(kind: "diff"),
				sequenceIndex: session.nextSequenceIndex
			),
			bucket: "toolCall"
		)
		append(
			.toolResult(
				name: "debug_text_derivation_diff",
				invocationID: diffInvocationID,
				resultJSON: Self.testDiffToolOutput(),
				sequenceIndex: session.nextSequenceIndex
			),
			bucket: "toolResult"
		)

		let jsonInvocationID = UUID()
		append(
			.toolCall(
				name: "debug_text_derivation_json",
				invocationID: jsonInvocationID,
				argsJSON: Self.testLargeToolArgsJSON(kind: "json"),
				sequenceIndex: session.nextSequenceIndex
			),
			bucket: "toolCall"
		)
		append(
			.toolResult(
				name: "debug_text_derivation_json",
				invocationID: jsonInvocationID,
				resultJSON: Self.testJSONToolOutput(),
				sequenceIndex: session.nextSequenceIndex
			),
			bucket: "toolResult"
		)

		append(.assistant(Self.testLongAssistantText(label: "recent-assistant-one", includeCodeFence: false), sequenceIndex: session.nextSequenceIndex), bucket: "assistant")
		append(.assistant(Self.testLongAssistantText(label: "recent-assistant-two", includeCodeFence: true), sequenceIndex: session.nextSequenceIndex), bucket: "assistant")

		applyTranscriptViewportBindingState(
			to: session,
			viewportState: .liveBottom,
			armingState: .armed
		)
		session.clearDerivedTranscriptCaches()
		requestUIRefresh(tabID: tabID, urgent: true)
		return appended
	}

	private static func testLongAssistantText(label: String, includeCodeFence: Bool) -> String {
		var lines = (1...480).map { index in
			"\(label) line \(index): synthetic assistant transcript content for DEBUG measurement. This intentionally long line keeps the fixture measurable without changing release behavior."
		}
		if includeCodeFence {
			lines.append(contentsOf: [
				"```swift",
				"struct DebugFixture {",
				"\tlet value: String",
				"\tfunc render() -> String { value }",
				"}",
				"```"
			])
		}
		return lines.joined(separator: "\n")
	}

	private static func testLargeToolArgsJSON(kind: String) -> String {
		let payload = (1...80).map { "arg-\(kind)-\($0)" }.joined(separator: "\\n")
		return "{\"kind\":\"\(kind)\",\"payload\":\"\(payload)\"}"
	}

	private static func testPlainToolOutput() -> String {
		(1...240).map { "plain output line \($0): fixture payload with enough text to require preview derivation." }
			.joined(separator: "\n")
	}

	private static func testDiffToolOutput() -> String {
		let hunks = (1...80).flatMap { index in
			[
				"@@ -\(index),3 +\(index),4 @@",
				" context line \(index)",
				"-old value \(index)",
				"+new value \(index)",
				"+added detail \(index)"
			]
		}
		return (["--- a/Fixture.swift", "+++ b/Fixture.swift"] + hunks).joined(separator: "\n")
	}

	private static func testJSONToolOutput() -> String {
		let rows = (1...120).map { index in
			"{\"index\":\(index),\"name\":\"fixture-\(index)\",\"status\":\"ok\"}"
		}.joined(separator: ",")
		return "{\"status\":\"ok\",\"rows\":[\(rows)],\"summary\":\"debug text derivation JSON fixture\"}"
	}
}

// MARK: - Stress Harness Persistence & Simulation

#if DEBUG
extension AgentModeViewModel {
	enum StressHarnessPersistenceError: Error {
		case noActiveWorkspace
		case missingComposeTab(UUID)
		case missingWorkspaceRoot
		case missingFixture(String)
		case invalidFixture(String, Error)
	}

	nonisolated static func persistedStressSessionFixtureURL(
		named fixtureName: String,
		workspaceRootPaths: [String]
	) -> URL? {
		let candidateURLs = workspaceRootPaths
			.filter { !$0.isEmpty }
			.map {
				URL(fileURLWithPath: $0, isDirectory: true)
					.standardizedFileURL
					.appendingPathComponent("RepoPromptTests", isDirectory: true)
					.appendingPathComponent("Fixtures", isDirectory: true)
					.appendingPathComponent("AgentSessions", isDirectory: true)
					.appendingPathComponent(fixtureName, isDirectory: false)
			}
		guard !candidateURLs.isEmpty else {
			return nil
		}
		if let existingURL = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
			return existingURL
		}
		return candidateURLs.first
	}

	nonisolated static func loadPersistedStressSessionFixture(
		named fixtureName: String,
		workspaceRootPaths: [String]
	) throws -> AgentSession {
		guard let fixtureURL = persistedStressSessionFixtureURL(
			named: fixtureName,
			workspaceRootPaths: workspaceRootPaths
		) else {
			throw StressHarnessPersistenceError.missingWorkspaceRoot
		}
		guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
			throw StressHarnessPersistenceError.missingFixture(fixtureName)
		}
		do {
			let data = try Data(contentsOf: fixtureURL)
			let session = try JSONDecoder().decode(AgentSession.self, from: data)
			return AgentSession(
				serializationVersion: session.serializationVersion,
				workspaceID: nil,
				composeTabID: nil,
				name: session.name,
				savedAt: session.savedAt,
				fileURL: nil,
				items: session.items,
				transcript: session.transcript,
				itemCount: session.itemCount,
				transcriptProjectionCounts: session.transcriptProjectionCounts,
				lastUserMessageAt: session.lastUserMessageAt,
				agentKind: session.agentKind,
				agentModel: session.agentModel,
				agentReasoningEffort: session.agentReasoningEffort,
				lastRunState: session.lastRunState,
				providerSessionID: session.providerSessionID,
				geminiACPResumeMetadata: session.geminiACPResumeMetadata,
				autoEditEnabled: session.autoEditEnabled,
				providerTokenUsageByTurn: session.providerTokenUsageByTurn,
				codexConversationID: session.codexConversationID,
				codexRolloutPath: session.codexRolloutPath,
				codexModel: session.codexModel,
				codexReasoningEffort: session.codexReasoningEffort,
				codexServiceTier: session.codexServiceTier,
				codexContextWindow: session.codexContextWindow,
				codexLastTotalTokens: session.codexLastTotalTokens,
				codexTotalTotalTokens: session.codexTotalTotalTokens,
				codexMcpSessionKey: session.codexMcpSessionKey,
				parentSessionID: session.parentSessionID,
				pendingHandoffPayload: session.pendingHandoffPayload,
				pendingHandoffCreatedAt: session.pendingHandoffCreatedAt,
				pendingHandoffSourceItemID: session.pendingHandoffSourceItemID,
				pendingHandoffDefersProviderLockUntilSend: session.pendingHandoffDefersProviderLockUntilSend,
				isMCPOriginated: session.isMCPOriginated
			)
		} catch {
			throw StressHarnessPersistenceError.invalidFixture(fixtureName, error)
		}
	}

	@discardableResult
	func testStagePersistedStressSession(
		tabID: UUID,
		fixtureNamed fixtureName: String,
		workspaceRootPaths: [String]
	) async throws -> AgentSession {
		let session = try Self.loadPersistedStressSessionFixture(
			named: fixtureName,
			workspaceRootPaths: workspaceRootPaths
		)
		return try await testStagePersistedStressSession(tabID: tabID, agentSession: session)
	}

	@discardableResult
	func testStagePersistedStressSession(
		tabID: UUID,
		agentSession seedSession: AgentSession
	) async throws -> AgentSession {
		guard let workspace = test_workspaceManager?.activeWorkspace else {
			throw StressHarnessPersistenceError.noActiveWorkspace
		}
		guard var tab = test_workspaceManager?.composeTab(with: tabID) else {
			throw StressHarnessPersistenceError.missingComposeTab(tabID)
		}

		var agentSession = seedSession
		agentSession.workspaceID = workspace.id
		agentSession.composeTabID = tabID
		agentSession.savedAt = Date()
		let fileURL = try await test_dataService.saveAgentSession(agentSession, for: workspace)
		agentSession.fileURL = fileURL

		tab.activeAgentSessionID = agentSession.id
		test_workspaceManager?.updateComposeTabStoredOnly(tab)
		upsertSessionIndex(
			sessionID: agentSession.id,
			tabID: tabID,
			name: agentSession.name,
			lastUserMessageAt: agentSession.lastUserMessageAt,
			savedAt: agentSession.savedAt,
			lastRunStateRaw: agentSession.lastRunState,
			itemCount: agentSession.effectiveItemCount,
			agentKindRaw: agentSession.agentKind,
			agentModelRaw: agentSession.agentModel,
			agentReasoningEffortRaw: agentSession.agentReasoningEffort,
			autoEditEnabled: agentSession.autoEditEnabled
		)

		if let liveSession = session(for: tabID, createIfNeeded: false) {
			cancelPersistedLoad(for: liveSession)
			removePendingUIRefresh(for: tabID)
			liveSession.markHydrationUnloaded(for: agentSession.id)
			applyTranscriptViewportBindingState(
				to: liveSession,
				viewportState: .liveBottom,
				armingState: .armed
			)
			liveSession.selectedAgent = AgentModelCatalog.normalizeSelection(
				agentRaw: agentSession.agentKind,
				modelRaw: agentSession.agentModel
			).agent
			liveSession.selectedModelRaw = AgentModelCatalog.normalizeSelection(
				agentRaw: agentSession.agentKind,
				modelRaw: agentSession.agentModel
			).modelRaw
			liveSession.selectedReasoningEffortRaw = agentSession.agentReasoningEffort
			liveSession.runState = .idle
			liveSession.runningStatusText = nil
			liveSession.setItemsSilently([], reason: .stressHarnessReset)
			liveSession.clearDerivedTranscriptCaches()
			if tabID == currentTabID {
				test_setActiveSessionBindingsAreHydrated(false)
				applySessionToBindings(liveSession)
			}
		}

		return agentSession
	}

	func testReplayCodexNativeEvent(
		tabID: UUID,
		event: CodexNativeSessionController.Event
	) async {
		guard let session = session(for: tabID, createIfNeeded: false) else { return }
		session.selectedAgent = .codexExec
		await test_codexCoordinator.test_handleCodexNativeEvent(event, session: session)
	}

	func testSimulateCodexRepoPromptToolCall(
		tabID: UUID,
		invocationID: UUID?,
		toolName: String,
		args: [String: Value]? = nil
	) {
		guard let session = session(for: tabID, createIfNeeded: false) else { return }
		test_codexCoordinator.testSimulateRepoPromptToolCall(
			invocationID: invocationID,
			toolName: toolName,
			args: args,
			session: session
		)
	}

	func testSimulateCodexRepoPromptToolResult(
		tabID: UUID,
		invocationID: UUID?,
		toolName: String,
		args: [String: Value]? = nil,
		resultJSON: String,
		isError: Bool
	) {
		guard let session = session(for: tabID, createIfNeeded: false) else { return }
		test_codexCoordinator.testSimulateRepoPromptToolResult(
			invocationID: invocationID,
			toolName: toolName,
			args: args,
			resultJSON: resultJSON,
			isError: isError,
			session: session
		)
	}

	func testSimulateCodexBashRunningUpdate(
		tabID: UUID,
		invocationID: UUID?,
		processID: String,
		appendedOutput: String,
		sealsAssistantBoundary: Bool = false
	) async {
		guard let session = session(for: tabID, createIfNeeded: false) else { return }
		await test_codexCoordinator.testSimulateBashRunningUpdate(
			invocationID: invocationID,
			processID: processID,
			appendedOutput: appendedOutput,
			sealsAssistantBoundary: sealsAssistantBoundary,
			session: session
		)
	}
}
#endif
