import Foundation
import MCP

// SEARCH-HELPER: Claude, ToolTracking, ToolCorrelation, TrackerLifecycle, ProviderToolStream
/// Dedicated tool-tracking handler for Claude agent sessions.
///
/// Owns:
/// - Shared `AgentToolTrackingController` lifecycle management
/// - Dual-source provider/tracker tool correlation (the hardest provider-specific logic)
/// - Turn-scoped correlation state reset between Claude turns
/// - Provider-stream RepoPrompt tool call/result handling (slot reservation + enrichment)
/// - MCP tracker callback → transcript item mutation for RepoPrompt tools
///
/// Related:
/// - ClaudeAgentModeCoordinator: /RepoPrompt/Services/AgentMode/Claude/ClaudeAgentModeCoordinator.swift
/// - AgentToolTrackingController: /RepoPrompt/Services/AI/Agents/AgentToolTracker.swift
/// - AgentToolTrackingContracts: /RepoPrompt/Services/AgentMode/ToolTracking/AgentToolTrackingContracts.swift
@MainActor
final class ClaudeAgentToolTrackingHandler {

	struct ExplicitProviderToolResultAckObservation: Sendable, Equatable {
		let timestamp: Date
		let runID: UUID?
		let toolName: String
		let invocationID: UUID?
		let counted: Bool
		let reason: String
		let ackCountAfterEvent: Int
	}

	struct ExplicitProviderToolResultAckSnapshot: Sendable, Equatable {
		let requestedRunID: UUID
		let trackedRunID: UUID?
		let ackCount: Int
		let ackedInvocationCount: Int
		let recentObservations: [ExplicitProviderToolResultAckObservation]
	}

	private struct AckWaiter {
		let runID: UUID
		let minimumAckCount: Int
		let continuation: CheckedContinuation<Void, Never>
	}

	// MARK: - Tracker State

	private let trackingController = AgentToolTrackingController()
	private let maxExplicitProviderAckObservationCount = 24

	// MARK: - Correlation State (moved from TabSession)

	/// Pending provider-stream invocation IDs queued for correlation with tracker callbacks, keyed by signature.
	private var pendingProviderRepoPromptInvocationsBySignature: [String: [UUID]] = [:]
	/// Maps tracker invocation IDs to provider-stream invocation IDs for dual-source correlation.
	private var providerInvocationByTrackerInvocationID: [UUID: UUID] = [:]
	/// Sequence boundary for provider/tracker tool correlation within the active Claude turn.
	private var toolCorrelationStartSequenceIndex: Int = 0
	/// Currently tracked Claude run for explicit provider `tool_result` acknowledgements.
	private var trackedRunID: UUID?
	/// Dedup set of explicit provider `tool_result` invocation IDs acknowledged for the tracked run.
	private var explicitProviderToolResultAckedInvocationIDs: Set<UUID> = []
	/// Monotonic count of deduped explicit provider `tool_result` acknowledgements for the tracked run.
	private var explicitProviderToolResultAckCount: Int = 0
	/// Continuation-based waiters parked until the tracked run reaches a minimum explicit provider ACK count.
	private var ackWaitersByID: [UUID: AckWaiter] = [:]
	/// Bounded ring buffer of recent explicit provider ACK observations for diagnostics.
	private var explicitProviderToolResultAckObservations: [ExplicitProviderToolResultAckObservation] = []

	var hooks: AgentToolTrackingHooks

	init(hooks: AgentToolTrackingHooks = .noOp) {
		self.hooks = hooks
	}

	private func diagnosticLog(_ message: @autoclosure () -> String) {
#if DEBUG
		print("[ClaudeToolTracking] \(message())")
#endif
	}

	private static func diagnosticID(_ id: UUID?) -> String {
		id?.uuidString ?? "nil"
	}

	private static func diagnosticSignature(_ signature: String) -> String {
		guard !signature.isEmpty else { return "empty" }
		let hash = signature.utf8.reduce(UInt64(0xcbf29ce484222325)) { partial, byte in
			(partial ^ UInt64(byte)) &* 0x100000001b3
		}
		return "hash=\(String(format: "%016llx", hash)) chars=\(signature.count)"
	}

	// MARK: - Tracking Lifecycle

	func startTracking(
		runID: UUID,
		session: AgentModeViewModel.TabSession,
		clientNameHint: String?
	) async {
		if trackedRunID != runID {
			beginTrackingExplicitProviderToolResultAcks(for: runID)
		}
		await trackingController.startTracking(
			runID: runID,
			clientNameHint: clientNameHint,
			onCalled: { [weak self, weak session] invocationID, toolName, args in
				guard let self, let session else { return }
				self.handleTrackerToolCall(
					invocationID: invocationID,
					toolName: toolName,
					args: args,
					session: session
				)
			},
			onCompleted: { [weak self, weak session] invocationID, toolName, args, resultJSON, isError in
				guard let self, let session else { return }
				self.handleTrackerToolResult(
					invocationID: invocationID,
					toolName: toolName,
					args: args,
					resultJSON: resultJSON,
					isError: isError,
					session: session
				)
			}
		)
	}

	func stopTracking(
		for session: AgentModeViewModel.TabSession
	) async {
		await trackingController.stopTracking()
		resetCorrelationState(session)
		stopTrackingExplicitProviderToolResultAcks()
	}

	func resetTurnState(
		for session: AgentModeViewModel.TabSession
	) {
		resetCorrelationState(session)
	}

	// MARK: - Provider Stream Event Handling

	@discardableResult
	func handleProviderToolEvent(
		_ event: AgentToolStreamEvent,
		session: AgentModeViewModel.TabSession
	) -> Bool {
		switch event {
		case .toolCall(let call):
			return handleProviderToolCall(call, session: session)
		case .toolResult(let result):
			return handleProviderToolResult(result, session: session)
		case .legacyEvent:
			// Claude doesn't use legacy "Using tool:" events; not consumed.
			return false
		}
	}

	// MARK: - Provider-Stream Tool Call Handling

	/// Handles `tool_call` events from the Claude provider stream.
	/// Returns `true` when the event was consumed (either processed or suppressed).
	private func handleProviderToolCall(
		_ call: AgentToolStreamEvent.ToolCall,
		session: AgentModeViewModel.TabSession
	) -> Bool {
		let toolName = call.toolName

		// Suppress orphan placeholder tool names.
		if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "tool",
			call.invocationID != nil,
			session.items.lastIndex(where: { $0.toolInvocationID == call.invocationID }) == nil {
			return true
		}

		// Explicit RepoPrompt tools: handle as provider-sourced slot reservation.
		if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
			!AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) {
			hooks.addToolInputTokens(call.argsJSON, session)
			handleClaudeProviderRepoPromptToolCall(
				invocationID: call.invocationID,
				toolName: toolName,
				argsJSON: call.argsJSON,
				session: session
			)
			return true
		}

		// Non-explicit RepoPrompt tools are suppressed (tracker is authoritative).
		if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
			toolName: toolName,
			invocationID: call.invocationID
		) {
			return true
		}

		return false
	}

	/// Handles `tool_result` events from the Claude provider stream.
	/// Returns `true` when the event was consumed (either processed or suppressed).
	private func handleProviderToolResult(
		_ result: AgentToolStreamEvent.ToolResult,
		session: AgentModeViewModel.TabSession
	) -> Bool {
		let toolName = result.toolName
		let outputJSON = result.resultJSON

		recordExplicitProviderToolResultAckIfNeeded(
			toolName: toolName,
			invocationID: result.invocationID
		)

		// Claude Code emits `<tool_use_error>Error: No such tool available: …</tool_use_error>`
		// when the model invokes a tool the CLI doesn't know (e.g. a bare `mcp__RepoPrompt`
		// server prefix with no trailing tool segment). Drop both this error row and the
		// paired placeholder tool_call so the transcript stays clean.
		// See: ClaudeInvalidToolErrorFilter.swift
		if ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
			resultText: outputJSON,
			isError: result.isError
		) {
			retractInvalidToolPlaceholder(
				toolName: toolName,
				invocationID: result.invocationID,
				session: session
			)
			hooks.requestUIRefresh(session.tabID, false)
			return true
		}

		// Suppress orphan placeholder tool results.
		if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "tool",
			result.invocationID != nil,
			session.items.lastIndex(where: { $0.toolInvocationID == result.invocationID }) == nil {
			return true
		}

		// Explicit RepoPrompt tool results are consumed from the provider stream. When Claude
		// supplies a provider invocation ID that exactly matches a provider-created slot,
		// terminalize that slot in place so the UI does not stay pending while waiting for
		// the MCP tracker completion. Do not fall back by nil ID, name, or signature here.
		if shouldSuppressClaudeProviderToolResult(
			toolName: toolName,
			argsJSON: result.argsJSON,
			outputJSON: outputJSON,
			isError: result.isError,
			invocationID: result.invocationID,
			session: session
		) {
			if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
				!AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) {
				hooks.addToolOutputTokens(outputJSON, session)
			}
			return true
		}

		// Non-explicit RepoPrompt tools are suppressed (tracker is authoritative).
		if AgentToolTrackingSupport.shouldSuppressProviderToolEvent(
			toolName: toolName,
			invocationID: result.invocationID
		) {
			return true
		}

		return false
	}

	/// Remove the placeholder tool_call row paired with a Claude `tool_use_error` that
	/// reported an unknown tool. The tool_call was already appended when the provider
	/// emitted `tool_use`, so this drops it retroactively using the invocation id
	/// (or tool-name fallback) to find the matching row. Both lookups are scoped to
	/// the current correlation turn so an invalid call in this turn cannot retract a
	/// legitimate placeholder left over from a prior turn.
	private func retractInvalidToolPlaceholder(
		toolName: String,
		invocationID: UUID?,
		session: AgentModeViewModel.TabSession
	) {
		let turnStart = toolCorrelationStartSequenceIndex
		func isEligible(_ item: AgentChatItem) -> Bool {
			item.kind == .toolCall && item.sequenceIndex >= turnStart
		}
		let placeholderIndex: Int? = {
			if let invocationID,
				let byInvocation = session.items.lastIndex(where: { item in
					isEligible(item) && item.toolInvocationID == invocationID
				}) {
				return byInvocation
			}
			return session.items.lastIndex(where: { item in
				isEligible(item)
					&& item.toolName == toolName
					&& item.toolInvocationID == nil
			})
		}()
		guard let placeholderIndex else { return }
		session.removeItem(at: placeholderIndex)
	}

	// MARK: - Explicit Provider ACK Waiting (Steering Safety)

	func awaitExplicitProviderToolResultAcks(
		for runID: UUID,
		atLeast minimumAckCount: Int
	) async throws {
		guard minimumAckCount > 0 else { return }
		if trackedRunID == runID, explicitProviderToolResultAckCount >= minimumAckCount {
			return
		}

		let waiterID = UUID()

		await withTaskCancellationHandler {
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				if trackedRunID == runID, explicitProviderToolResultAckCount >= minimumAckCount {
					continuation.resume()
					return
				}
				ackWaitersByID[waiterID] = AckWaiter(
					runID: runID,
					minimumAckCount: minimumAckCount,
					continuation: continuation
				)
			}
		} onCancel: {
			Task { @MainActor [weak self] in
				guard let self else { return }
				if let waiter = self.ackWaitersByID.removeValue(forKey: waiterID) {
					waiter.continuation.resume()
				}
			}
		}

		try Task.checkCancellation()
	}

	func explicitProviderToolResultAckSnapshot(
		for runID: UUID
	) -> ExplicitProviderToolResultAckSnapshot {
		let isTrackedRun = trackedRunID == runID
		return ExplicitProviderToolResultAckSnapshot(
			requestedRunID: runID,
			trackedRunID: trackedRunID,
			ackCount: isTrackedRun ? explicitProviderToolResultAckCount : 0,
			ackedInvocationCount: isTrackedRun ? explicitProviderToolResultAckedInvocationIDs.count : 0,
			recentObservations: isTrackedRun ? explicitProviderToolResultAckObservations : []
		)
	}

	// MARK: - Provider-Sourced RepoPrompt Tool Handling (Correlation)

	func handleClaudeProviderRepoPromptToolCall(
		invocationID: UUID?,
		toolName: String,
		argsJSON: String?,
		session: AgentModeViewModel.TabSession
	) {
		guard AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName) else { return }
		guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }

		let storedToolName = Self.canonicalTranscriptToolName(toolName)
		let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
		if let existingIndex = findCorrelationItemIndex(
			invocationID: invocationID,
			signature: signature,
			toolName: toolName,
			session: session
		) {
			var updated = session.items[existingIndex]
			var didMutate = false
			if let providerInvocationID = invocationID,
				updated.kind == .toolCall,
				let trackerInvocationID = updated.toolInvocationID,
				trackerInvocationID != providerInvocationID {
				providerInvocationByTrackerInvocationID[trackerInvocationID] = providerInvocationID
			}
			if let providerInvocationID = invocationID {
				if updated.kind == .toolCall, updated.toolInvocationID != providerInvocationID {
					updated.toolInvocationID = providerInvocationID
					didMutate = true
				} else if updated.toolInvocationID == nil {
					updated.toolInvocationID = providerInvocationID
					didMutate = true
				}
			}
			if updated.toolName != storedToolName {
				updated.toolName = storedToolName
				didMutate = true
			}
			if let argsJSON, argsJSON != updated.toolArgsJSON {
				updated.toolArgsJSON = argsJSON
				didMutate = true
			}
			if didMutate {
				session.replaceItem(at: existingIndex, with: updated)
			}
			if updated.kind == .toolResult {
				// Late provider placeholder: tracker already finalized this tool in the current turn.
				return
			}
			return
		}

		if let invocationID {
			var pending = pendingProviderRepoPromptInvocationsBySignature[signature, default: []]
			if !pending.contains(invocationID) {
				pending.append(invocationID)
				pendingProviderRepoPromptInvocationsBySignature[signature] = pending
			}
		}

		let toolItem = AgentChatItem.toolCall(
			name: storedToolName,
			invocationID: invocationID,
			argsJSON: argsJSON,
			sequenceIndex: session.nextSequenceIndex
		)
		session.appendItem(toolItem)
	}

	func shouldSuppressClaudeProviderToolResult(
		toolName: String,
		argsJSON: String?,
		outputJSON: String,
		isError: Bool? = nil,
		invocationID: UUID?,
		session: AgentModeViewModel.TabSession
	) -> Bool {
		guard session.selectedAgent.usesClaudeNativeRuntime else { return false }
		if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
			!AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) {
			let terminalizedExactProviderSlot = terminalizeExplicitProviderToolResultIfExactProviderSlot(
				toolName: toolName,
				argsJSON: argsJSON,
				outputJSON: outputJSON,
				isError: isError,
				invocationID: invocationID,
				session: session
			)
			let matchingProviderItemCount = invocationID.map { providerInvocationID in
				session.items.filter { $0.toolInvocationID == providerInvocationID }.count
			} ?? 0
			diagnosticLog(
				"suppressing explicit RepoPrompt provider tool_result tab=\(session.tabID.uuidString) " +
				"tool=\(toolName) providerInvocation=\(Self.diagnosticID(invocationID)) " +
				"matchingItems=\(matchingProviderItemCount) exactProviderSlotTerminalized=\(terminalizedExactProviderSlot) " +
				"pendingProviderIDs=\(pendingProviderInvocationCount()) " +
				"trackerMappings=\(providerInvocationByTrackerInvocationID.count)"
			)
			return true
		}
		if !AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName),
			AgentToolTrackingSupport.isRepoPromptTool(toolName),
			outputJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			argsJSON == nil,
			invocationID != nil,
			session.items.lastIndex(where: { $0.toolInvocationID == invocationID }) == nil {
			return true
		}
		return false
	}

	private func terminalizeExplicitProviderToolResultIfExactProviderSlot(
		toolName: String,
		argsJSON: String?,
		outputJSON: String,
		isError: Bool?,
		invocationID: UUID?,
		session: AgentModeViewModel.TabSession
	) -> Bool {
		guard let providerInvocationID = invocationID else { return false }
		let normalizedToolName = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName)
		guard let index = session.items.lastIndex(where: { item in
			item.kind == .toolCall
				&& item.toolInvocationID == providerInvocationID
				&& MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "") == normalizedToolName
		}) else {
			return false
		}

		var updated = session.items[index]
		updated.kind = .toolResult
		updated.toolName = Self.canonicalTranscriptToolName(toolName)
		updated.toolResultJSON = outputJSON
		updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
		updated.toolIsError = isError
		updated.text = outputJSON
		session.replaceItem(at: index, with: updated)
		hooks.requestUIRefresh(session.tabID, false)
		return true
	}

	// MARK: - Tracker Callbacks (MCP observer)

	func handleTrackerToolCall(
		invocationID: UUID,
		toolName: String,
		args: [String: Value]?,
		session: AgentModeViewModel.TabSession
	) {
		guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
		guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
		// Flush buffered assistant content before inserting tool card to preserve interleaving order.
		hooks.flushPendingAssistantDelta(session)
		hooks.endActiveAssistantSegment(session)
		hooks.endActiveReasoningSegment(session)
		let storedToolName = Self.canonicalTranscriptToolName(toolName)
		let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
		let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
		if let providerInvocationID = consumePendingProviderInvocationID(
			forSignature: signature,
			session: session
		) {
			diagnosticLog(
				"tracker call consumed pending provider fallback tab=\(session.tabID.uuidString) " +
				"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
				"providerInvocation=\(providerInvocationID.uuidString) signature=\(Self.diagnosticSignature(signature))"
			)
			providerInvocationByTrackerInvocationID[invocationID] = providerInvocationID
			if let index = session.items.lastIndex(where: { $0.toolInvocationID == providerInvocationID }) {
				var updated = session.items[index]
				updated.toolName = storedToolName
				updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
				session.replaceItem(at: index, with: updated)
			} else {
				let toolItem = AgentChatItem.toolCall(
					name: storedToolName,
					invocationID: providerInvocationID,
					argsJSON: argsJSON,
					sequenceIndex: session.nextSequenceIndex
				)
				session.appendItem(toolItem)
			}
			hooks.requestUIRefresh(session.tabID, false)
			return
		}

		// Only match pending .toolCall items — matching already-completed .toolResult
		// items would incorrectly correlate with finalized tools from previous turns
		// during followup runs, leaving the new tool call orphaned and eventually
		// marked as failed by finalizePendingToolCalls.
		let matchingProviderBackedSignatureIndices = session.items.indices.filter { index in
			let item = session.items[index]
			return item.kind == .toolCall
				&& item.toolInvocationID != nil
				&& Self.repoPromptInvocationSignature(toolName: item.toolName ?? "", argsJSON: item.toolArgsJSON) == signature
		}
		if matchingProviderBackedSignatureIndices.count > 1 {
			diagnosticLog(
				"ambiguous tracker call signature fallback tab=\(session.tabID.uuidString) " +
				"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
				"matches=\(matchingProviderBackedSignatureIndices.count) signature=\(Self.diagnosticSignature(signature))"
			)
		}
		if let existingInvocationIndex = matchingProviderBackedSignatureIndices.last,
			let providerInvocationID = session.items[existingInvocationIndex].toolInvocationID {
			diagnosticLog(
				"tracker call using signature fallback tab=\(session.tabID.uuidString) " +
				"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
				"providerInvocation=\(providerInvocationID.uuidString) matches=\(matchingProviderBackedSignatureIndices.count)"
			)
			providerInvocationByTrackerInvocationID[invocationID] = providerInvocationID
			var updated = session.items[existingInvocationIndex]
			updated.toolName = storedToolName
			updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
			session.replaceItem(at: existingInvocationIndex, with: updated)
			hooks.requestUIRefresh(session.tabID, false)
			return
		}

		let matchingNilIDSignatureIndices = session.items.indices.filter { index in
			let item = session.items[index]
			return item.kind == .toolCall
				&& item.toolInvocationID == nil
				&& Self.repoPromptInvocationSignature(toolName: item.toolName ?? "", argsJSON: item.toolArgsJSON) == signature
		}
		if matchingNilIDSignatureIndices.count > 1 {
			diagnosticLog(
				"ambiguous tracker call nil-id signature fallback tab=\(session.tabID.uuidString) " +
				"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
				"matches=\(matchingNilIDSignatureIndices.count) signature=\(Self.diagnosticSignature(signature))"
			)
		}
		if let fallbackIndex = matchingNilIDSignatureIndices.last {
			diagnosticLog(
				"tracker call using nil-id signature fallback tab=\(session.tabID.uuidString) " +
				"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
				"matches=\(matchingNilIDSignatureIndices.count)"
			)
			var updated = session.items[fallbackIndex]
			updated.toolName = storedToolName
			updated.toolInvocationID = invocationID
			updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
			session.replaceItem(at: fallbackIndex, with: updated)
			hooks.requestUIRefresh(session.tabID, false)
			return
		}

		// Tool-name-only fallback: only match items with no invocationID (true placeholders).
		let normalizedToolName = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName)
		let matchingNilIDNameIndices = session.items.indices.filter { index in
			let item = session.items[index]
			return item.kind == .toolCall
				&& item.toolInvocationID == nil
				&& MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "") == normalizedToolName
		}
		if matchingNilIDNameIndices.count > 1 {
			diagnosticLog(
				"ambiguous tracker call nil-id name fallback tab=\(session.tabID.uuidString) " +
				"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
				"matches=\(matchingNilIDNameIndices.count)"
			)
		}
		if let fallbackByNameIndex = matchingNilIDNameIndices.last {
			diagnosticLog(
				"tracker call using nil-id name fallback tab=\(session.tabID.uuidString) " +
				"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
				"matches=\(matchingNilIDNameIndices.count)"
			)
			var updated = session.items[fallbackByNameIndex]
			updated.toolName = storedToolName
			if updated.toolInvocationID == nil {
				updated.toolInvocationID = invocationID
			}
			updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
			session.replaceItem(at: fallbackByNameIndex, with: updated)
			hooks.requestUIRefresh(session.tabID, false)
			return
		}

		let toolItem = AgentChatItem.toolCall(
			name: storedToolName,
			invocationID: invocationID,
			argsJSON: argsJSON,
			sequenceIndex: session.nextSequenceIndex
		)
		session.appendItem(toolItem)
		hooks.requestUIRefresh(session.tabID, false)
	}

	func handleTrackerToolResult(
		invocationID: UUID,
		toolName: String,
		args: [String: Value]?,
		resultJSON: String,
		isError: Bool,
		session: AgentModeViewModel.TabSession
	) {
		guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
		guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
		// Flush buffered assistant content before inserting tool result to preserve interleaving order.
		hooks.flushPendingAssistantDelta(session)
		hooks.endActiveAssistantSegment(session)
		hooks.endActiveReasoningSegment(session)
		let storedToolName = Self.canonicalTranscriptToolName(toolName)
		let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
		let signature = Self.repoPromptInvocationSignature(toolName: toolName, argsJSON: argsJSON)
		let resolvedInvocationID = providerInvocationByTrackerInvocationID[invocationID] ?? invocationID
		providerInvocationByTrackerInvocationID.removeValue(forKey: invocationID)

		let targetIndex: Int? = {
			if let byInvocation = session.items.lastIndex(where: { $0.toolInvocationID == resolvedInvocationID }) {
				return byInvocation
			}
			if let providerInvocationID = consumePendingProviderInvocationID(
				forSignature: signature,
				session: session
			), let byProviderInvocation = session.items.lastIndex(where: { $0.toolInvocationID == providerInvocationID }) {
				diagnosticLog(
					"tracker result consumed pending provider fallback tab=\(session.tabID.uuidString) " +
					"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
					"providerInvocation=\(providerInvocationID.uuidString) signature=\(Self.diagnosticSignature(signature))"
				)
				providerInvocationByTrackerInvocationID[invocationID] = providerInvocationID
				return byProviderInvocation
			}
			let matchingPendingSignatureIndices = session.items.indices.filter { index in
				let item = session.items[index]
				return item.kind == .toolCall
					&& Self.repoPromptInvocationSignature(toolName: item.toolName ?? "", argsJSON: item.toolArgsJSON) == signature
			}
			if matchingPendingSignatureIndices.count > 1 {
				diagnosticLog(
					"ambiguous tracker result signature fallback tab=\(session.tabID.uuidString) " +
					"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
					"resolvedInvocation=\(resolvedInvocationID.uuidString) matches=\(matchingPendingSignatureIndices.count) " +
					"signature=\(Self.diagnosticSignature(signature))"
				)
			}
			if let byPendingCallSignature = matchingPendingSignatureIndices.last {
				diagnosticLog(
					"tracker result using signature fallback tab=\(session.tabID.uuidString) " +
					"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
					"resolvedInvocation=\(resolvedInvocationID.uuidString) matches=\(matchingPendingSignatureIndices.count)"
				)
				return byPendingCallSignature
			}
			let normalizedToolName = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName)
			let matchingPendingNameIndices = session.items.indices.filter { index in
				let item = session.items[index]
				return item.kind == .toolCall
					&& item.toolInvocationID == nil
					&& MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "") == normalizedToolName
			}
			if matchingPendingNameIndices.count > 1 {
				diagnosticLog(
					"ambiguous tracker result nil-id name fallback tab=\(session.tabID.uuidString) " +
					"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
					"matches=\(matchingPendingNameIndices.count)"
				)
			}
			if let byPendingCallName = matchingPendingNameIndices.last {
				diagnosticLog(
					"tracker result using nil-id name fallback tab=\(session.tabID.uuidString) " +
					"tool=\(toolName) trackerInvocation=\(invocationID.uuidString) " +
					"matches=\(matchingPendingNameIndices.count)"
				)
				return byPendingCallName
			}
			return nil
		}()

		let trimmedResult = resultJSON.trimmingCharacters(in: .whitespacesAndNewlines)
		if isError, trimmedResult.isEmpty {
			// Claude can emit tracker completions for cancelled/superseded tool attempts
			// with no payload. Do not surface these as failed bubbles.
			if let index = targetIndex, session.items[index].kind == .toolCall {
				session.removeItem(at: index)
				hooks.requestUIRefresh(session.tabID, false)
			}
			return
		}

		if let index = targetIndex {
			var updated = session.items[index]
			updated.toolName = storedToolName
			updated.kind = .toolResult
			updated.toolResultJSON = resultJSON
			updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
			updated.toolIsError = isError
			updated.text = resultJSON
			if updated.toolInvocationID == nil {
				updated.toolInvocationID = resolvedInvocationID
			}
			session.replaceItem(at: index, with: updated)
		} else {
			let toolResultItem = AgentChatItem.toolResult(
				name: storedToolName,
				invocationID: resolvedInvocationID,
				resultJSON: resultJSON,
				isError: isError,
				sequenceIndex: session.nextSequenceIndex
			)
			session.appendItem(toolResultItem)
		}
		hooks.requestUIRefresh(session.tabID, false)
	}

	// MARK: - Correlation Helpers

	private func resetCorrelationState(_ session: AgentModeViewModel.TabSession) {
		let pendingProviderCount = pendingProviderInvocationCount()
		let trackerMappingCount = providerInvocationByTrackerInvocationID.count
		if pendingProviderCount > 0 || trackerMappingCount > 0 {
			diagnosticLog(
				"reset clearing Claude tool correlation state tab=\(session.tabID.uuidString) " +
				"pendingProviderIDs=\(pendingProviderCount) trackerMappings=\(trackerMappingCount) " +
				"nextSequenceIndex=\(session.nextSequenceIndex)"
			)
		}
		pendingProviderRepoPromptInvocationsBySignature.removeAll(keepingCapacity: false)
		providerInvocationByTrackerInvocationID.removeAll(keepingCapacity: false)
		toolCorrelationStartSequenceIndex = session.nextSequenceIndex
	}

	private func pendingProviderInvocationCount() -> Int {
		pendingProviderRepoPromptInvocationsBySignature.values.reduce(0) { $0 + $1.count }
	}

	private func beginTrackingExplicitProviderToolResultAcks(for runID: UUID) {
		resumeAckWaiters(matching: { $0.runID != runID })
		trackedRunID = runID
		explicitProviderToolResultAckedInvocationIDs.removeAll(keepingCapacity: false)
		explicitProviderToolResultAckCount = 0
		explicitProviderToolResultAckObservations.removeAll(keepingCapacity: false)
		resumeEligibleAckWaiters()
	}

	private func stopTrackingExplicitProviderToolResultAcks() {
		trackedRunID = nil
		explicitProviderToolResultAckedInvocationIDs.removeAll(keepingCapacity: false)
		explicitProviderToolResultAckCount = 0
		explicitProviderToolResultAckObservations.removeAll(keepingCapacity: false)
		resumeAckWaiters(matching: { _ in true })
	}

	private func recordExplicitProviderToolResultAckIfNeeded(
		toolName: String,
		invocationID: UUID?
	) {
		guard AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName) else { return }
		guard let invocationID else {
			appendExplicitProviderAckObservation(
				toolName: toolName,
				invocationID: nil,
				counted: false,
				reason: "missing_invocation_id"
			)
			return
		}
		guard trackedRunID != nil else {
			appendExplicitProviderAckObservation(
				toolName: toolName,
				invocationID: invocationID,
				counted: false,
				reason: "no_tracked_run"
			)
			return
		}
		let inserted = explicitProviderToolResultAckedInvocationIDs.insert(invocationID).inserted
		guard inserted else {
			appendExplicitProviderAckObservation(
				toolName: toolName,
				invocationID: invocationID,
				counted: false,
				reason: "duplicate_invocation"
			)
			return
		}

		explicitProviderToolResultAckCount += 1
		appendExplicitProviderAckObservation(
			toolName: toolName,
			invocationID: invocationID,
			counted: true,
			reason: "acked"
		)
		resumeEligibleAckWaiters()
	}

	private func appendExplicitProviderAckObservation(
		toolName: String,
		invocationID: UUID?,
		counted: Bool,
		reason: String
	) {
		explicitProviderToolResultAckObservations.append(
			ExplicitProviderToolResultAckObservation(
				timestamp: Date(),
				runID: trackedRunID,
				toolName: toolName,
				invocationID: invocationID,
				counted: counted,
				reason: reason,
				ackCountAfterEvent: explicitProviderToolResultAckCount
			)
		)
		if explicitProviderToolResultAckObservations.count > maxExplicitProviderAckObservationCount {
			explicitProviderToolResultAckObservations.removeFirst(
				explicitProviderToolResultAckObservations.count - maxExplicitProviderAckObservationCount
			)
		}
	}

	private func resumeEligibleAckWaiters() {
		guard let trackedRunID else { return }
		resumeAckWaiters(matching: {
			$0.runID == trackedRunID && explicitProviderToolResultAckCount >= $0.minimumAckCount
		})
	}

	private func resumeAckWaiters(matching predicate: (AckWaiter) -> Bool) {
		let matchingIDs = ackWaitersByID.compactMap { waiterID, waiter in
			predicate(waiter) ? waiterID : nil
		}
		for waiterID in matchingIDs {
			guard let waiter = ackWaitersByID.removeValue(forKey: waiterID) else { continue }
			waiter.continuation.resume()
		}
	}

	private func findCorrelationItemIndex(
		invocationID: UUID?,
		signature: String,
		toolName: String,
		session: AgentModeViewModel.TabSession
	) -> Int? {
		let turnStartSequenceIndex = toolCorrelationStartSequenceIndex
		let normalizedToolName = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName)
		func isEligible(_ item: AgentChatItem) -> Bool {
			item.sequenceIndex >= turnStartSequenceIndex
				&& (item.kind == .toolCall || item.kind == .toolResult)
		}

		if let invocationID,
			let byInvocationID = session.items.lastIndex(where: { item in
				isEligible(item) && item.toolInvocationID == invocationID
			}) {
			return byInvocationID
		}

		if let bySignature = session.items.lastIndex(where: { item in
			isEligible(item)
				&& Self.repoPromptInvocationSignature(toolName: item.toolName ?? "", argsJSON: item.toolArgsJSON) == signature
		}) {
			return bySignature
		}

		return session.items.lastIndex(where: { item in
			guard isEligible(item) else { return false }
			guard MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "") == normalizedToolName else {
				return false
			}
			if item.kind == .toolCall {
				return item.toolInvocationID == nil
			}
			if item.kind == .toolResult {
				return item.toolArgsJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
			}
			return false
		})
	}

	private func consumePendingProviderInvocationID(
		forSignature signature: String,
		session: AgentModeViewModel.TabSession
	) -> UUID? {
		guard var queue = pendingProviderRepoPromptInvocationsBySignature[signature], !queue.isEmpty else {
			return nil
		}
		while !queue.isEmpty {
			let candidate = queue.removeFirst()
			if session.items.contains(where: { $0.toolInvocationID == candidate }) {
				pendingProviderRepoPromptInvocationsBySignature[signature] = queue.isEmpty ? nil : queue
				return candidate
			}
		}
		pendingProviderRepoPromptInvocationsBySignature[signature] = nil
		return nil
	}

	// MARK: - Static Helpers

	private static func canonicalTranscriptToolName(_ toolName: String) -> String {
		MCPIntegrationHelper.canonicalRepoPromptAskUserToolName(toolName) ?? toolName
	}

	private static func repoPromptInvocationSignature(toolName: String, argsJSON: String?) -> String {
		let normalizedToolName = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName)
		let normalizedArgs = canonicalizedJSON(argsJSON) ?? ""
		return "\(normalizedToolName)|\(normalizedArgs)"
	}

	private static func canonicalizedJSON(_ raw: String?) -> String? {
		guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
			let data = raw.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data)
		else {
			return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		guard JSONSerialization.isValidJSONObject(object),
			let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
			let canonical = String(data: canonicalData, encoding: .utf8)
		else {
			return raw
		}
		return canonical
	}
}
