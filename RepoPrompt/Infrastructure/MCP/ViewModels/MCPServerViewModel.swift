//
//  MCPServerViewModel.swift
//  RepoPrompt
//
//  Created by Repo Prompt – MCP integration
//

import Foundation
import Combine
import Logging
import MCP
import JSONSchema
import Ontology
import AppKit

// MARK: - Selection Debug Logging
#if DEBUG
fileprivate var selectionDebugLoggingEnabled = false

internal func setSelectionDebugLogging(enabled: Bool) {
	selectionDebugLoggingEnabled = enabled
}

internal func selectionLog(_ message: @autoclosure () -> String) {
	if selectionDebugLoggingEnabled {
		print("[Selection] \(message())")
	}
}

fileprivate var mcpServerViewModelDebugLoggingEnabled = false
fileprivate func mcpServerViewModelDebugLog(_ message: @autoclosure () -> String) {
	guard mcpServerViewModelDebugLoggingEnabled else { return }
	print("[MCPServerVM] \(message())")
}
#else
internal func selectionLog(_ message: @autoclosure () -> String) {}
fileprivate func mcpServerViewModelDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// Compact summary returned by edit tools.
/// Standardize encoding keys to snake_case via shared DTO.
private typealias EditSummary = ToolResultDTOs.EditSummary

private struct DiscoverContextResult: Codable {
	let tabID: String
	let status: String
	let prompt: String
	let fileCount: Int
	let totalTokens: Int
	let userTotalTokens: Int?  // Token count under user's copy preset (may differ from totalTokens when codemap settings differ)
	let tokenNote: String?     // Explains why totalTokens and userTotalTokens differ
	let tokenBudget: Int?
	let promptMode: String?
	let agent: String?
	let selection: String  // Formatted selection summary

	// Response generation fields
	let responseType: String?  // "plan", "question", or "review" - indicates what was generated
	let plan: ChatSendReply?   // Generated plan or question response
	let review: ChatSendReply?
	let followUpHint: String?
	let oracleExportPath: String?
	let oracleExportInstruction: String?

	enum CodingKeys: String, CodingKey {
		case tabID = "context_id"
		case status, prompt
		case fileCount = "file_count"
		case totalTokens = "total_tokens"
		case userTotalTokens = "user_total_tokens"
		case tokenNote = "token_note"
		case tokenBudget = "token_budget"
		case promptMode = "prompt_mode"
		case agent
		case selection
		case responseType = "response_type"
		case plan
		case review
		case followUpHint = "follow_up_hint"
		case oracleExportPath = "oracle_export_path"
		case oracleExportInstruction = "oracle_export_instruction"
	}

	/// Converts to MCP Value for tool response
	func toMCPValue() -> Value {
		var obj: [String: Value] = [
			"context_id": .string(tabID),
			"status": .string(status),
			"prompt": .string(prompt),
			"file_count": .int(fileCount),
			"total_tokens": .int(totalTokens),
			"selection": .string(selection)
		]

		if let userTotalTokens = userTotalTokens {
			obj["user_total_tokens"] = .int(userTotalTokens)
		}
		if let tokenNote = tokenNote {
			obj["token_note"] = .string(tokenNote)
		}
		if let tokenBudget = tokenBudget {
			obj["token_budget"] = .int(tokenBudget)
		}
		if let promptMode = promptMode {
			obj["prompt_mode"] = .string(promptMode)
		}
		if let agent = agent {
			obj["agent"] = .string(agent)
		}
		if let responseType = responseType {
			obj["response_type"] = .string(responseType)
		}
		if let plan = plan {
			obj["plan"] = plan.toMCPValue()
		}
		if let review = review {
			obj["review"] = review.toMCPValue()
		}
		if let hint = followUpHint {
			obj["follow_up_hint"] = .string(hint)
		}
		if let oracleExportPath = oracleExportPath {
			obj["oracle_export_path"] = .string(oracleExportPath)
		}
		if let oracleExportInstruction = oracleExportInstruction {
			obj["oracle_export_instruction"] = .string(oracleExportInstruction)
		}

		return .object(obj)
	}
}

struct WindowMCPCloseSafetyState: Equatable {
	let toolsEnabled: Bool
	let liveConnectionCount: Int
	let activeExecutionCount: Int
	let hasIdleLiveConnections: Bool
	let activeToolName: String?

	static let inactive = WindowMCPCloseSafetyState(
		toolsEnabled: false,
		liveConnectionCount: 0,
		activeExecutionCount: 0,
		hasIdleLiveConnections: false,
		activeToolName: nil
	)
}

/// Manages the lifetime of the embedded MCP server and bridges
/// the app’s state (file tree, selections, code-map, prompts …)
/// to external Model-Context-Protocol clients.
///
/// This is **not** a simplified stub — all original features have
/// been preserved and adapted to the latest MCP SDK.
@MainActor               // Runs on the main actor (UI thread)
final class MCPServerViewModel: ObservableObject, @preconcurrency Service, WindowScopedService {
	private static let enableSteeringDebugLogging = false

	private func steeringDebugLog(_ message: @autoclosure () -> String) {
		#if DEBUG
		guard Self.enableSteeringDebugLogging else { return }
		print(message())
		#endif
	}

	// -----------------------------------------------------------------
	// MARK:  Configuration constants
	// -----------------------------------------------------------------
	private static let defaultCodeStructureMaxResults = 10
	private static let codeStructureTokenBudget = 6_000
	private static let codeStructureSeparatorTokenCost = TokenCalculationService.estimateTokens(for: "\n\n")

	internal struct CodeStructureBudgetCandidate: Equatable {
		let key: String
		let estimatedTokens: Int
	}

	internal struct CodeStructureBudgetSelection: Equatable {
		let includedKeys: [String]
		let omittedByMaxResults: Int
		let omittedByTokenBudget: Int

		var omittedTotal: Int { omittedByMaxResults + omittedByTokenBudget }
	}


	// ---------------------------------------------------------------------
	// MARK:  External dependencies (weak/unowned to avoid retain cycles)
	// ---------------------------------------------------------------------
	let fileManager : RepoFileManagerViewModel
	private let searchVM    : SearchFileTreeViewModel
	let promptVM    : PromptViewModel
	private let chatVM      : ChatViewModel
	let workspaceManager: WorkspaceManagerViewModel?

	// ---------------------------------------------------------------------
	// MARK:  Networking delegation
	// ---------------------------------------------------------------------
	let windowID: Int
	private(set) var service: MCPService
	private let logger = Logger(label: "com.repoprompt.mcp")



	private var oracleToolService: MCPOracleToolService {
		MCPOracleToolService(
			askOracleToolName: ToolNames.askOracle,
			oracleSendToolName: ToolNames.oracleSend,
			oracleChatLogToolName: ToolNames.oracleChatLog,
			promptVM: promptVM,
			chatVM: chatVM,
			fileManager: fileManager,
			captureRequestMetadata: { [self] in await captureRequestMetadata() },
			resolveExecContext: { [self] metadata in resolveExecContext(from: metadata) },
			requireCurrentTabContext: { [self] toolName in try await requireCurrentTabContext(toolName: toolName) },
			rebindChatSessionIfNeeded: { [self] metadata, chatIDString in
				try rebindOracleChatSessionIfNeeded(metadata: metadata, chatIDString: chatIDString)
			},
			resolveTabIDForAgentMode: { [self] args, connectionID in
				try await resolveTabIDForAgentMode(args: args, connectionID: connectionID)
			},
			requireTargetWindow: { [self] in try requireTargetWindow() },
			rawExplicitTabID: { [self] args in rawExplicitTabID(args: args) },
			sendStageProgress: { [self] connectionID, tool, stage, message in
				await sendStageProgress(connectionID: connectionID, tool: tool, stage: stage, message: message)
			},
			withHeartbeat: { [self] connectionID, tool, stage, message, operation in
				try await withHeartbeat(
					connectionID: connectionID,
					tool: tool,
					stage: stage,
					message: message,
					operation: operation
				)
			},
			exportOracleResponse: { [self] request in
				try await exportOracleResponse(request)
			}
		)
	}

	private var agentRunToolService: AgentRunMCPToolService {
		AgentRunMCPToolService(
			toolName: ToolNames.agentRun,
			captureRequestMetadata: { [self] in await captureRequestMetadata() },
			requireTargetWindow: { [self] in try requireTargetWindow() },
			resolveRequestedTabID: { [self] args in
				try resolveRequestedTabIDForAgentControl(args: args)
			},
			resolveSpawnSourceTabID: { [self] metadata in
				await resolveSpawnSourceTabIDForAgentSessionCreation(metadata: metadata)
			},
			validateSpawnRouting: { [self] metadata, sourceTabID in
				try await validateAgentRunStartRouting(metadata: metadata, resolvedSourceTabID: sourceTabID)
			},
			resolveSpawnParentSessionID: { [self] metadata, targetWindow in
				await resolveSpawnParentSessionID(metadata: metadata, targetWindow: targetWindow)
			},
			resolveSpawnParentSessionIDFromSourceTabID: { sourceTabID, targetWindow in
				targetWindow.agentModeViewModel.mcpSpawnParentSessionID(sourceTabID: sourceTabID)
			},
			bindCurrentRequestToTab: { [self] tabID, metadata in
				try await bindCurrentRequestToTabIfPossible(tabID: tabID, metadata: metadata)
			},
			withHeartbeat: { [self] connectionID, tool, stage, message, operation in
				try await withHeartbeat(
					connectionID: connectionID,
					tool: tool,
					stage: stage,
					message: message,
					operation: operation
				)
			},
			beginAgentRunWait: { [self] metadata, sessionIDs, timeoutSeconds in
				await beginAgentRunWaitScope(metadata: metadata, sessionIDs: sessionIDs, timeoutSeconds: timeoutSeconds)
			},
			endAgentRunWait: { [self] token, completion in
				endAgentRunWaitScope(token, completion: completion)
			},
			startRun: { target, message, metadata, bindCurrentRequestToTab, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, workflow in
				try await AgentExternalMCPRunStarter.start(
					target: target,
					message: message,
					metadata: metadata,
					bindCurrentRequestToTab: bindCurrentRequestToTab,
					agentModeVM: agentModeVM,
					agentRaw: agentRaw,
					modelRaw: modelRaw,
					reasoningEffortRaw: reasoningEffortRaw,
					taskLabelKind: taskLabelKind,
					workflow: workflow
				)
			}
		)
	}

	private var agentExploreToolService: AgentExploreMCPToolService {
		AgentExploreMCPToolService(
			toolName: ToolNames.agentExplore,
			captureRequestMetadata: { [self] in await captureRequestMetadata() },
			requireTargetWindow: { [self] in try requireTargetWindow() },
			resolveSpawnSourceTabID: { [self] metadata in
				await resolveSpawnSourceTabIDForAgentSessionCreation(metadata: metadata)
			},
			resolveSpawnParentSessionID: { [self] metadata, targetWindow in
				await resolveSpawnParentSessionID(metadata: metadata, targetWindow: targetWindow)
			},
			bindCurrentRequestToTab: { [self] tabID, metadata in
				try await bindCurrentRequestToTabIfPossible(tabID: tabID, metadata: metadata)
			},
			withHeartbeat: { [self] connectionID, tool, stage, message, operation in
				try await withHeartbeat(
					connectionID: connectionID,
					tool: tool,
					stage: stage,
					message: message,
					operation: operation
				)
			},
			beginAgentRunWait: { [self] metadata, sessionIDs, timeoutSeconds in
				await beginAgentRunWaitScope(metadata: metadata, sessionIDs: sessionIDs, timeoutSeconds: timeoutSeconds)
			},
			endAgentRunWait: { [self] token, completion in
				endAgentRunWaitScope(token, completion: completion)
			},
			startRun: { target, message, metadata, bindCurrentRequestToTab, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, workflow in
				try await AgentExternalMCPRunStarter.start(
					target: target,
					message: message,
					metadata: metadata,
					bindCurrentRequestToTab: bindCurrentRequestToTab,
					agentModeVM: agentModeVM,
					agentRaw: agentRaw,
					modelRaw: modelRaw,
					reasoningEffortRaw: reasoningEffortRaw,
					taskLabelKind: taskLabelKind,
					workflow: workflow
				)
			}
		)
	}

	private var agentManageToolService: AgentManageMCPToolService {
		AgentManageMCPToolService(
			toolName: ToolNames.agentManage,
			captureRequestMetadata: { [self] in await captureRequestMetadata() },
			requireTargetWindow: { [self] in try requireTargetWindow() },
			resolveSpawnSourceTabID: { [self] metadata in
				await resolveSpawnSourceTabIDForAgentSessionCreation(metadata: metadata)
			},
			resolveSpawnParentSessionID: { [self] metadata, targetWindow in
				await resolveSpawnParentSessionID(metadata: metadata, targetWindow: targetWindow)
			},
			bindCurrentRequestToTab: { [self] tabID, metadata in
				try await bindCurrentRequestToTabIfPossible(tabID: tabID, metadata: metadata)
			}
		)
	}

	@Published private(set) var isRunning = false               // overall status
	@Published private(set) var pendingClientID: String?        // approval state
	@Published private(set) var diagnostics: MCPDiagnostics = MCPDiagnostics(
		issue: .none,
		lastEventAt: nil,
		listenerStateDescription: "Idle"
	)
	@Published private(set) var lastErrorMessage: String?
	@Published private(set) var lastExternalClientEvent: MCPExternalClientEvent?
	@Published private(set) var externalClientErrorCount: Int = 0

	static func applyCodeStructureOutputBudget(
		_ candidates: [CodeStructureBudgetCandidate],
		maxResults: Int,
		tokenBudget: Int = codeStructureTokenBudget,
		separatorTokens: Int = codeStructureSeparatorTokenCost
	) -> CodeStructureBudgetSelection {
		let effectiveMaxResults = max(0, maxResults)
		let effectiveTokenBudget = max(0, tokenBudget)
		let countCapped = Array(candidates.prefix(effectiveMaxResults))
		let omittedByMaxResults = max(0, candidates.count - countCapped.count)

		var includedKeys: [String] = []
		var usedTokens = 0

		for candidate in countCapped {
			let isFirstEntry = includedKeys.isEmpty
			let entryCost = isFirstEntry ? candidate.estimatedTokens : candidate.estimatedTokens + max(0, separatorTokens)
			if !isFirstEntry, usedTokens + entryCost > effectiveTokenBudget {
				break
			}
			includedKeys.append(candidate.key)
			usedTokens += entryCost
		}

		return CodeStructureBudgetSelection(
			includedKeys: includedKeys,
			omittedByMaxResults: omittedByMaxResults,
			omittedByTokenBudget: max(0, countCapped.count - includedKeys.count)
		)
	}

	// MARK: - Dashboard State

	/// Current dashboard snapshot (updated via event-driven notifications)
	@Published private(set) var dashboard: MCPService.DashboardSnapshot? {
		didSet {
			recomputeCloseSafetyState()
		}
	}

	@Published private(set) var closeSafetyState: WindowMCPCloseSafetyState = .inactive

	/// Task that listens for dashboard updates
	@MainActor
	private var dashboardTask: Task<Void, Never>?
	@MainActor
	private var dashboardTaskID: UUID?

	/// Subscription ID for dashboard updates (for cleanup)
	@MainActor
	private var dashboardSubscriptionID: UUID?

	enum DashboardConsumer: Hashable {
		case toolbarPopover
		case statusView
	}

	@MainActor
	private var dashboardConsumers: Set<DashboardConsumer> = []

	/// Returns the external client event only if it's recent (within 5 minutes)
	var recentExternalClientEvent: MCPExternalClientEvent? {
		guard let event = lastExternalClientEvent else { return nil }
		let ageInSeconds = Date().timeIntervalSince(event.timestamp)
		let maxAge: TimeInterval = 5 * 60 // 5 minutes
		return ageInSeconds < maxAge ? event : nil
	}

	/// Returns a smarter description that correlates the external error with server state
	var contextualErrorDescription: String? {
		guard let event = recentExternalClientEvent else { return nil }

		// Get the resolved client name - use event's name, or fall back to last connected client
		let clientName = resolvedClientName(for: event)

		// Check if there's a server-side issue that explains the client error
		switch (event.code, diagnostics.issue) {
		case (.localNetworkPolicyDenied, .localNetworkPermissionDenied):
			return "\(clientName) and RepoPrompt both need Local Network permission."
		case (.timeoutNoServices, _) where !isRunning:
			return "MCP server is not running. \(clientName) couldn't find any services."
		case (.connectionFailed, .listenerRestarting):
			return "\(clientName) tried to connect while the listener was restarting."
		case (.connectionFailed, .portInUse):
			return "\(clientName) couldn't connect - server port conflict detected."
		default:
			return resolvedUserFacingDescription(for: event)
		}
	}

	/// Resolves the client name for an event, using the last connected client as fallback
	private func resolvedClientName(for event: MCPExternalClientEvent) -> String {
		if let name = event.clientName, !name.isEmpty {
			return name
		}
		// Fall back to the last connected client's friendly name
		let monitor = MCPExternalEventsMonitor.shared
		return monitor.friendlyClientName(forProtocol: monitor.lastConnectedClientProtocolName)
	}

	/// Returns the user-facing description with resolved client name and full details
	private func resolvedUserFacingDescription(for event: MCPExternalClientEvent) -> String {
		let clientName = resolvedClientName(for: event)
		// Use the event's detailed description with our resolved client name
		return event.descriptionWithClientName(clientName)
	}

	/// Name of the tool that is currently executing (nil when idle)
	@Published private(set) var activeToolName: String? = nil {
		didSet {
			recomputeCloseSafetyState()
		}
	}

	/// Returns the active tool name for this window, based on dashboard ownership when available.
	@MainActor
	var windowActiveToolName: String? {
		if let dashboard = dashboard {
			let allowNilWindow = !isMultiWindowModeEffectivelyActive
			for connection in dashboard.connections {
				if connection.windowID == windowID || (allowNilWindow && connection.windowID == nil) {
					if let toolName = connection.activeToolName {
						return toolName
					}
				}
			}
		}
		return activeToolName
	}

	/// True when any tool is actively running for this window.
	@MainActor
	var windowHasActiveTool: Bool {
		windowActiveToolName != nil
	}
	/// Internal tracking token to prevent race conditions when overlapping tool calls occur
	@MainActor
	private var activeToolToken: UUID? = nil
	/// Connection that owns the legacy single active-tool slot.
	/// This keeps disconnect cleanup from cancelling a newer same-name tool owned by another connection.
	@MainActor
	private var activeToolConnectionID: UUID? = nil
	/// Whether this window's tools are enabled
	@Published var windowToolsEnabled: Bool = false {
		didSet {
			updateDashboardSubscriptionIfNeeded()
			recomputeCloseSafetyState()
			Task { await updateToolRegistration() }
		}
	}
	/// Controls whether the approval overlay is visible
	@Published var isApprovalOverlayVisible: Bool = false

	/// Cached tool catalogue. Built once and reused to avoid repeated schema allocations.
	@MainActor
	private var toolsCache: [Tool]? = nil
	private var cancellables: Set<AnyCancellable> = []
	@MainActor
	var tabContextByConnectionID: [UUID: TabScopedContext] = [:]
	@MainActor
	var pendingTabContexts = PendingContextStore()
	@MainActor
	var connectionIDByRunID: [UUID: UUID] = [:]
	@MainActor
	var connectionIDToRunID: [UUID: UUID] = [:]
	@MainActor
	var windowIDByConnection: [UUID: Int] = [:]
	@MainActor
	var tabContextCancellablesByConnectionID: [UUID: Set<AnyCancellable>] = [:]
	@MainActor
	var lastContextByClientAndWindow: [String: [Int: TabScopedContext]] = [:]


	var isMultiWindowModeEffectivelyActive: Bool {
		WindowStatesManager.shared.isMultiWindowModeEffectivelyActive
	}

	@MainActor
	private func dashboardConnectionsForThisWindow() -> [MCPService.DashboardConnection] {
		guard let dashboard else { return [] }
		let allowNilWindow = !isMultiWindowModeEffectivelyActive
		return dashboard.connections.filter { connection in
			connection.windowID == windowID || (allowNilWindow && connection.windowID == nil)
		}
	}

	@MainActor
	private func recomputeCloseSafetyState() {
		guard windowToolsEnabled else {
			closeSafetyState = .inactive
			return
		}

		let connections = dashboardConnectionsForThisWindow()
		let liveConnections = connections.filter { connection in
			switch connection.state {
			case .ready, .waiting:
				return true
			case .setup, .failed, .cancelled, .unknown:
				return false
			}
		}
		let liveConnectionCount = liveConnections.count
		var activeExecutionCount = liveConnections.reduce(into: 0) { partialResult, connection in
			if connection.hasInFlightCalls {
				partialResult += 1
			}
		}
		let activeTool = windowActiveToolName
		if activeExecutionCount == 0, activeTool != nil {
			activeExecutionCount = 1
		}

		closeSafetyState = WindowMCPCloseSafetyState(
			toolsEnabled: windowToolsEnabled,
			liveConnectionCount: liveConnectionCount,
			activeExecutionCount: activeExecutionCount,
			hasIdleLiveConnections: liveConnectionCount > 0 && activeExecutionCount == 0,
			activeToolName: activeTool
		)
	}

	// MARK: -- Cancellation support

	/// Per-run active tool execution tracking — supports multiple concurrent tool calls per run.
	@MainActor
	private struct ActiveToolExecution {
		let executionID: UUID
		let runID: UUID
		let connectionID: UUID
		let toolName: String
		let startedAt: Date
		let cancel: () -> Void
	}

	@MainActor
	private var activeToolExecutionsByRunID: [UUID: [UUID: ActiveToolExecution]] = [:]
	@MainActor
	private var runIDByToolExecutionID: [UUID: UUID] = [:]

	@MainActor
	private struct AgentRunWaitScope {
		let token: UUID
		let parentRunID: UUID
		let childSessionIDs: Set<UUID>
		let startedAt: Date
		let timeoutSeconds: TimeInterval?
		let metadata: RequestMetadata
	}

	@MainActor
	private var agentRunWaitScopesByToken: [UUID: AgentRunWaitScope] = [:]
	@MainActor
	private var childAgentRunWaitCountsByParentRunID: [UUID: [UUID: Int]] = [:]
	private let agentRunWaitScopeStaleGraceSeconds: TimeInterval = 60

	/// Cumulative count of tool executions that have ended (success/error/cancel) per run.
	/// Used by the Claude steering interrupt safety gate to verify that the provider stream
	/// has acknowledged all locally-completed tool results before sending an interrupt.
	@MainActor
	private var toolEndedCountByRunID: [UUID: Int] = [:]

	/// Continuations parked by `awaitNoActiveToolExecutions` waiting for a runID to have zero
	/// in-flight tool executions. Keyed by runID → waiterID → continuation.
	@MainActor
	private var toolIdleWaitersByRunID: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]

	@MainActor
	private func debugActiveTools(for runID: UUID) -> String {
		let executions = activeToolExecutionsByRunID[runID] ?? [:]
		guard !executions.isEmpty else { return "none" }
		return executions.values
			.map { "\($0.toolName)#\(String($0.executionID.uuidString.prefix(8)))" }
			.sorted()
			.joined(separator: ",")
	}

	@MainActor
	private var cancelCurrentTool: (() -> Void)?
	private let applyEditsApprovalStore: ApplyEditsApprovalStore

	@MainActor
	func cancelActiveTool() {
		// Prefer cancellation via the per-run registry if the active token is tracked
		if let token = activeToolToken,
			let runID = runIDByToolExecutionID[token],
			activeToolExecutionsByRunID[runID]?[token] != nil {
			cancelToolExecution(executionID: token, reason: "cancelActiveTool")
		} else {
			cancelCurrentTool?()
		}

		// Immediately update user-facing state so the active-tool indicator and Cancel button don't stay stuck
		clearActiveToolSlot()
	}

	@MainActor
	private func clearActiveToolSlot() {
		activeToolName = nil
		cancelCurrentTool = nil
		activeToolToken = nil
		activeToolConnectionID = nil
	}

	/// Cancel all active tool executions for a given runID.
	/// Returns the number of executions cancelled.
	@MainActor
	@discardableResult
	func cancelActiveToolsForRun(runID: UUID, reason: String? = nil) -> Int {
		guard let executions = activeToolExecutionsByRunID.removeValue(forKey: runID) else {
			// Even if there are no active tools, resume any waiters so
			// steering flush tasks unblock and can observe cancellation.
			resumeAllToolIdleWaiters(forRunID: runID)
			toolEndedCountByRunID.removeValue(forKey: runID)
			return 0
		}
		var cancelledCount = 0
		for (executionID, execution) in executions {
			execution.cancel()
			runIDByToolExecutionID.removeValue(forKey: executionID)
			cancelledCount += 1
		}
		// Clear single-slot UI state if it was pointing at one of the cancelled executions
		if let token = activeToolToken, executions[token] != nil {
			clearActiveToolSlot()
		}
		// Resume any steering idle-waiters since the run's tools are now gone
		resumeAllToolIdleWaiters(forRunID: runID)
		// Clean up the ended-count tracker for this run since it's being torn down.
		toolEndedCountByRunID.removeValue(forKey: runID)
		return cancelledCount
	}

	/// Cancel active tool executions owned by a specific connection.
	/// Disconnect cleanup must use this identity-bound API instead of comparing tool names,
	/// because a newer connection can legitimately start the same tool name before stale cleanup runs.
	@MainActor
	@discardableResult
	func cancelActiveToolsForConnection(connectionID: UUID, reason: String? = nil) -> Int {
		let matchingExecutionIDs = activeToolExecutionsByRunID.values.flatMap { executions in
			executions.values.compactMap { execution in
				execution.connectionID == connectionID ? execution.executionID : nil
			}
		}
		let matchingExecutionIDSet = Set(matchingExecutionIDs)
		let activeTokenBeforeCancellation = activeToolToken

		var cancelledCount = 0
		for executionID in matchingExecutionIDs {
			if cancelToolExecution(executionID: executionID, reason: reason) {
				cancelledCount += 1
			}
		}

		guard activeToolConnectionID == connectionID else {
			return cancelledCount
		}

		if let activeTokenBeforeCancellation,
			matchingExecutionIDSet.contains(activeTokenBeforeCancellation) {
			clearActiveToolSlot()
			return cancelledCount
		}

		// Legacy single-slot fallback for work that predates or bypasses the per-run registry.
		// Only the recorded owning connection may cancel this slot.
		if activeToolName != nil || cancelCurrentTool != nil || activeToolToken != nil {
			let legacyCancel = cancelCurrentTool
			legacyCancel?()
			clearActiveToolSlot()
			if legacyCancel != nil {
				cancelledCount += 1
			}
		}

		return cancelledCount
	}

	@MainActor
	private func registerToolExecution(
		executionID: UUID,
		runID: UUID,
		connectionID: UUID,
		toolName: String,
		cancel: @escaping () -> Void
	) {
		let execution = ActiveToolExecution(
			executionID: executionID,
			runID: runID,
			connectionID: connectionID,
			toolName: toolName,
			startedAt: Date(),
			cancel: cancel
		)
		activeToolExecutionsByRunID[runID, default: [:]][executionID] = execution
		runIDByToolExecutionID[executionID] = runID
		steeringDebugLog("[AgentRunSteeringWake] MCP tool register runID=\(runID) executionID=\(executionID) tool=\(toolName) active=\(debugActiveTools(for: runID))")
	}

	@MainActor
	private func unregisterToolExecution(executionID: UUID) {
		guard let runID = runIDByToolExecutionID.removeValue(forKey: executionID) else {
			steeringDebugLog("[AgentRunSteeringWake] MCP tool unregister ignored missing runID executionID=\(executionID)")
			return
		}
		let toolName = activeToolExecutionsByRunID[runID]?[executionID]?.toolName ?? "unknown"
		activeToolExecutionsByRunID[runID]?.removeValue(forKey: executionID)
		// Track cumulative tool completions for steering interrupt safety gate.
		toolEndedCountByRunID[runID, default: 0] += 1
		if activeToolExecutionsByRunID[runID]?.isEmpty == true {
			activeToolExecutionsByRunID.removeValue(forKey: runID)
			steeringDebugLog("[AgentRunSteeringWake] MCP tool unregister drained runID=\(runID) executionID=\(executionID) tool=\(toolName) endedCount=\(toolEndedCountByRunID[runID] ?? 0)")
			resumeAllToolIdleWaiters(forRunID: runID)
		} else {
			steeringDebugLog("[AgentRunSteeringWake] MCP tool unregister runID=\(runID) executionID=\(executionID) tool=\(toolName) remaining=\(debugActiveTools(for: runID)) endedCount=\(toolEndedCountByRunID[runID] ?? 0)")
		}
	}

	/// Returns the cumulative number of tool executions that have completed for the given runID.
	/// Used by the Claude steering interrupt safety gate.
	@MainActor
	func toolEndedCount(runID: UUID) -> Int {
		toolEndedCountByRunID[runID] ?? 0
	}

	/// Returns whether the given run currently has any active RepoPrompt MCP tool executions.
	@MainActor
	func hasActiveToolExecutions(runID: UUID) -> Bool {
		guard let executions = activeToolExecutionsByRunID[runID] else {
			return false
		}
		return !executions.isEmpty
	}

	/// Returns whether the given parent run is currently blocked in an `agent_run` wait.
	/// Agent control-plane tools stay out of active tool tracking to avoid steering deadlocks,
	/// so watchdog/liveness checks must consult this wait-scope state separately.
	@MainActor
	func hasActiveChildAgentRunWaits(runID: UUID) -> Bool {
		purgeStaleAgentRunWaitScopes(source: "liveness-query")
		let active = !(childAgentRunWaitCountsByParentRunID[runID]?.isEmpty ?? true)
		if active {
			let scopes = agentRunWaitScopesByToken.values.filter { $0.parentRunID == runID }
			let oldestAge = scopes.map { Date().timeIntervalSince($0.startedAt) }.max() ?? 0
			steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope liveness parentRunID=\(runID) scopes=\(scopes.count) oldestAge=\(oldestAge) counts=\(debugChildAgentRunWaits(for: runID))")
		}
		return active
	}

	// MARK: - Tool Idle Waiting (Steering Safety)

	/// Waits until the given runID has zero active MCP tool executions.
	/// Returns immediately if already idle. Supports cooperative cancellation
	/// via structured concurrency — if the calling Task is cancelled the
	/// continuation is cleaned up and a `CancellationError` is thrown.
	@MainActor
	func awaitNoActiveToolExecutions(runID: UUID) async throws {
		// Fast path: already idle
		let executions = activeToolExecutionsByRunID[runID]
		if executions == nil || executions!.isEmpty {
			steeringDebugLog("[AgentRunSteeringWake] MCP idle wait fast-idle runID=\(runID)")
			return
		}
		steeringDebugLog("[AgentRunSteeringWake] MCP idle wait blocking runID=\(runID) active=\(debugActiveTools(for: runID))")

		let waiterID = UUID()

		// Use withTaskCancellationHandler so that Task.cancel() from the
		// outside (e.g., user cancels the run) will promptly resume us.
		await withTaskCancellationHandler {
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				// Double-check under the same MainActor turn — tools may have
				// drained between the fast-path check and here.
				let stillActive = activeToolExecutionsByRunID[runID]
				if stillActive == nil || stillActive!.isEmpty {
					steeringDebugLog("[AgentRunSteeringWake] MCP idle wait drained before parking runID=\(runID) waiterID=\(waiterID)")
					continuation.resume()
					return
				}
				toolIdleWaitersByRunID[runID, default: [:]][waiterID] = continuation
				steeringDebugLog("[AgentRunSteeringWake] MCP idle wait parked runID=\(runID) waiterID=\(waiterID) active=\(debugActiveTools(for: runID)) waiters=\(toolIdleWaitersByRunID[runID]?.count ?? 0)")
			}
		} onCancel: {
			// Must hop to MainActor to safely remove the waiter.
			Task { @MainActor [weak self] in
				guard let self else { return }
				if let continuation = self.toolIdleWaitersByRunID[runID]?
					.removeValue(forKey: waiterID) {
					continuation.resume()  // unblock so CancellationError propagates
				}
				if self.toolIdleWaitersByRunID[runID]?.isEmpty == true {
					self.toolIdleWaitersByRunID.removeValue(forKey: runID)
				}
			}
		}

		// After resuming, respect cooperative cancellation
		try Task.checkCancellation()
		steeringDebugLog("[AgentRunSteeringWake] MCP idle wait completed runID=\(runID) waiterID=\(waiterID)")
	}

	/// Resumes all parked idle-waiters for a runID (called when tools drain to zero).
	@MainActor
	private func resumeAllToolIdleWaiters(forRunID runID: UUID) {
		guard let waiters = toolIdleWaitersByRunID.removeValue(forKey: runID) else {
			steeringDebugLog("[AgentRunSteeringWake] MCP idle wait resume skipped no waiters runID=\(runID)")
			return
		}
		steeringDebugLog("[AgentRunSteeringWake] MCP idle wait resuming runID=\(runID) waiters=\(waiters.count)")
		for (_, continuation) in waiters {
			continuation.resume()
		}
	}

	@MainActor
	@discardableResult
	private func cancelToolExecution(executionID: UUID, reason: String?) -> Bool {
		guard let runID = runIDByToolExecutionID[executionID],
			let execution = activeToolExecutionsByRunID[runID]?[executionID] else {
			return false
		}
		execution.cancel()
		unregisterToolExecution(executionID: executionID)
		return true
	}

	@MainActor
	private func managerRunIDFallbackIsCompatibleWithThisWindow(
		connectionID: UUID,
		metadata: RequestMetadata,
		managerWindowID: Int?
	) -> Bool {
		let candidateWindowIDs = [
			managerWindowID,
			metadata.windowID,
			windowIDByConnection[connectionID]
		].compactMap { $0 }

		for candidateWindowID in candidateWindowIDs where candidateWindowID != windowID {
			mcpServerViewModelDebugLog("manager runID fallback rejected for connection=\(connectionID): candidateWindow=\(candidateWindowID) currentWindow=\(windowID)")
			return false
		}

		return true
	}

	@MainActor
	private func beginAgentRunWaitScope(metadata: RequestMetadata, sessionIDs: Set<UUID>, timeoutSeconds: TimeInterval?) async -> UUID? {
		guard !sessionIDs.isEmpty else { return nil }
		purgeStaleAgentRunWaitScopes(source: "begin")
		let execContext = resolveExecContext(from: metadata)
		guard let parentRunID = await resolveRunIDForExecution(metadata: metadata, execContext: execContext) else {
			steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope skipped: no parent runID childSessions=\(sessionIDs.map(\.uuidString).sorted().joined(separator: ","))")
			return nil
		}
		let token = UUID()
		let scope = AgentRunWaitScope(
			token: token,
			parentRunID: parentRunID,
			childSessionIDs: sessionIDs,
			startedAt: Date(),
			timeoutSeconds: timeoutSeconds,
			metadata: metadata
		)
		agentRunWaitScopesByToken[token] = scope
		for sessionID in sessionIDs {
			childAgentRunWaitCountsByParentRunID[parentRunID, default: [:]][sessionID, default: 0] += 1
		}
		steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope begin parentRunID=\(parentRunID) token=\(token) timeout=\(timeoutSeconds.map { String($0) } ?? "none") childSessions=\(sessionIDs.map(\.uuidString).sorted().joined(separator: ",")) counts=\(debugChildAgentRunWaits(for: parentRunID))")
		return token
	}

	@MainActor
	private func endAgentRunWaitScope(_ token: UUID, completion: AgentRunWaitScopeCompletion) {
		guard let scope = agentRunWaitScopesByToken.removeValue(forKey: token) else {
			steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope end ignored missing token=\(token) reason=\(completion.reason.rawValue)")
			return
		}
		decrementAgentRunWaitScope(scope)
		let elapsed = Date().timeIntervalSince(scope.startedAt)
		steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope end parentRunID=\(scope.parentRunID) token=\(token) elapsed=\(elapsed) reason=\(completion.reason.rawValue) result=\(completion.result ?? "none") winner=\(completion.winnerSessionID?.uuidString ?? "none") pending=\(completion.pendingSessionIDs.map(\.uuidString).sorted().joined(separator: ",")) childSessions=\(scope.childSessionIDs.map(\.uuidString).sorted().joined(separator: ",")) remaining=\(debugChildAgentRunWaits(for: scope.parentRunID))")
	}

	@MainActor
	private func decrementAgentRunWaitScope(_ scope: AgentRunWaitScope) {
		for sessionID in scope.childSessionIDs {
			let existing = childAgentRunWaitCountsByParentRunID[scope.parentRunID]?[sessionID] ?? 0
			if existing <= 1 {
				childAgentRunWaitCountsByParentRunID[scope.parentRunID]?.removeValue(forKey: sessionID)
			} else {
				childAgentRunWaitCountsByParentRunID[scope.parentRunID]?[sessionID] = existing - 1
			}
		}
		if childAgentRunWaitCountsByParentRunID[scope.parentRunID]?.isEmpty == true {
			childAgentRunWaitCountsByParentRunID.removeValue(forKey: scope.parentRunID)
		}
	}

	@MainActor
	private func purgeStaleAgentRunWaitScopes(now: Date = Date(), source: String) {
		let staleTokens = agentRunWaitScopesByToken.compactMap { token, scope -> UUID? in
			let timeout = scope.timeoutSeconds ?? AgentRunMCPToolService.defaultWaitTimeoutSeconds
			let maxAge = timeout + agentRunWaitScopeStaleGraceSeconds
			return now.timeIntervalSince(scope.startedAt) > maxAge ? token : nil
		}
		for token in staleTokens {
			guard let scope = agentRunWaitScopesByToken.removeValue(forKey: token) else { continue }
			decrementAgentRunWaitScope(scope)
			let elapsed = now.timeIntervalSince(scope.startedAt)
			steeringDebugLog("[AgentRunSteeringWake] agent_run wait scope stale purge source=\(source) parentRunID=\(scope.parentRunID) token=\(token) elapsed=\(elapsed) timeout=\(scope.timeoutSeconds.map { String($0) } ?? "default") childSessions=\(scope.childSessionIDs.map(\.uuidString).sorted().joined(separator: ","))")
		}
	}

	@MainActor
	private func debugChildAgentRunWaits(for parentRunID: UUID) -> String {
		let counts = childAgentRunWaitCountsByParentRunID[parentRunID] ?? [:]
		guard !counts.isEmpty else { return "none" }
		return counts
			.map { "\($0.key.uuidString.prefix(8)):\($0.value)" }
			.sorted()
			.joined(separator: ",")
	}

	@MainActor
	func wakeAgentRunWaitersOwnedByActiveRun(
		runID: UUID,
		source: String,
		snapshotForSessionID: (UUID) -> AgentRunMCPSnapshot?
	) async {
		let sessionIDs = Set(childAgentRunWaitCountsByParentRunID[runID]?.keys.map { $0 } ?? [])
		guard !sessionIDs.isEmpty else {
			steeringDebugLog("[AgentRunSteeringWake] parent wake found no child agent_run waiters source=\(source) parentRunID=\(runID) active=\(debugActiveTools(for: runID))")
			return
		}
		steeringDebugLog("[AgentRunSteeringWake] parent wake child agent_run waiters source=\(source) parentRunID=\(runID) childSessions=\(sessionIDs.map(\.uuidString).sorted().joined(separator: ",")) active=\(debugActiveTools(for: runID))")
		for sessionID in sessionIDs {
			guard let snapshot = snapshotForSessionID(sessionID) else {
				steeringDebugLog("[AgentRunSteeringWake] parent wake skipped missing child snapshot source=\(source) parentRunID=\(runID) childSessionID=\(sessionID)")
				continue
			}
			await AgentRunSessionStore.wakeCurrentWaiters(snapshot, reason: .steeringRequested)
		}
		await Task.yield()
		steeringDebugLog("[AgentRunSteeringWake] parent wake yielded source=\(source) parentRunID=\(runID)")
	}

	@MainActor
	func wakeAndDrainAgentRunWaitersOwnedByActiveRun(
		runID: UUID,
		source: String,
		timeoutSeconds: TimeInterval,
		snapshotForSessionID: (UUID) -> AgentRunMCPSnapshot?
	) async -> Bool {
		guard hasActiveChildAgentRunWaits(runID: runID) else {
			steeringDebugLog("[AgentRunSteeringWake] parent wake/drain fast-idle source=\(source) parentRunID=\(runID)")
			return true
		}

		let timeout = max(0, timeoutSeconds)
		let deadline = Date().addingTimeInterval(timeout)
		while true {
			await wakeAgentRunWaitersOwnedByActiveRun(
				runID: runID,
				source: source,
				snapshotForSessionID: snapshotForSessionID
			)
			guard hasActiveChildAgentRunWaits(runID: runID) else {
				steeringDebugLog("[AgentRunSteeringWake] parent wake/drain completed source=\(source) parentRunID=\(runID)")
				return true
			}
			guard timeout > 0, Date() < deadline else {
				steeringDebugLog("[AgentRunSteeringWake] parent wake/drain timed out source=\(source) parentRunID=\(runID) timeout=\(timeoutSeconds) remaining=\(debugChildAgentRunWaits(for: runID))")
				return false
			}
			do {
				try await Task.sleep(nanoseconds: 25_000_000)
			} catch {
				steeringDebugLog("[AgentRunSteeringWake] parent wake/drain cancelled source=\(source) parentRunID=\(runID) remaining=\(debugChildAgentRunWaits(for: runID))")
				return false
			}
			if Task.isCancelled {
				steeringDebugLog("[AgentRunSteeringWake] parent wake/drain cancelled after sleep source=\(source) parentRunID=\(runID) remaining=\(debugChildAgentRunWaits(for: runID))")
				return false
			}
		}
	}

	@MainActor
	private func resolveRunIDForExecution(
		metadata: RequestMetadata,
		execContext: ExecContext
	) async -> UUID? {
		if let connectionID = metadata.connectionID,
			let runID = connectionIDToRunID[connectionID] {
			return runID
		}

		if case .virtual(let context) = execContext,
			let runID = context.runID {
			if let connectionID = metadata.connectionID {
				_ = registerRunIDMapping(
					connectionID: connectionID,
					runID: runID,
					windowID: context.windowID
				)
			}
			return runID
		}

		guard let connectionID = metadata.connectionID else {
			return nil
		}

		let manager = ServerNetworkManager.shared
		let managerWindowID = await manager.selectedWindow(for: connectionID)
		guard managerRunIDFallbackIsCompatibleWithThisWindow(
			connectionID: connectionID,
			metadata: metadata,
			managerWindowID: managerWindowID
		) else {
			return nil
		}

		guard let managerRunID = await manager.runIDForConnection(connectionID) else {
			return nil
		}

		let resolvedManagerWindowID = await manager.selectedWindow(for: connectionID)
		guard managerRunIDFallbackIsCompatibleWithThisWindow(
			connectionID: connectionID,
			metadata: metadata,
			managerWindowID: resolvedManagerWindowID
		) else {
			return nil
		}

		return managerRunID
	}

#if DEBUG
	@MainActor
	func test_beginResolvedToolExecution(
		metadata: RequestMetadata,
		execContext: ExecContext,
		toolName: String = "test_tool",
		cancel: @escaping () -> Void = {}
	) async -> (executionID: UUID, runID: UUID)? {
		guard let connectionID = metadata.connectionID,
			let runID = await resolveRunIDForExecution(metadata: metadata, execContext: execContext),
			shouldRegisterRunToolExecution(toolName: toolName) else {
			return nil
		}

		let executionID = UUID()
		registerToolExecution(
			executionID: executionID,
			runID: runID,
			connectionID: connectionID,
			toolName: toolName,
			cancel: cancel
		)
		return (executionID, runID)
	}

	@MainActor
	func test_endToolExecution(executionID: UUID) {
		unregisterToolExecution(executionID: executionID)
	}

	@MainActor
	@discardableResult
	func test_setActiveToolSlot(
		toolName: String,
		connectionID: UUID?,
		cancel: @escaping () -> Void = {}
	) -> UUID {
		let token = UUID()
		activeToolToken = token
		activeToolConnectionID = connectionID
		activeToolName = toolName
		cancelCurrentTool = cancel
		return token
	}

	@MainActor
	func test_activeToolConnectionID() -> UUID? {
		activeToolConnectionID
	}

	@MainActor
	func test_clearActiveToolSlot() {
		clearActiveToolSlot()
	}
#endif


	// ---------------------------------------------------------------------
	// MARK:  Initialisation
	// ---------------------------------------------------------------------
	init(service: MCPService,
			fileManager: RepoFileManagerViewModel,
			searchVM   : SearchFileTreeViewModel,
			promptVM   : PromptViewModel,
			chatVM     : ChatViewModel,
			workspaceManager: WorkspaceManagerViewModel,
			windowID   : Int,
			applyEditsApprovalStore: ApplyEditsApprovalStore = .shared) {
		self.service   = service
		self.windowID  = windowID
		self.fileManager = fileManager
		self.searchVM   = searchVM
		self.promptVM   = promptVM
		self.chatVM     = chatVM
		self.workspaceManager = workspaceManager
		self.applyEditsApprovalStore = applyEditsApprovalStore

		// Observe service state updates
		observeService()

		// Observe external client events from disk
		observeExternalEvents()

		// ⬇️ NEW: Initialise local published properties with current service snapshot
		Task { [weak self] in
			guard let self else { return }
			let snap = await self.service.currentState()
			await self.apply(snap)          // @MainActor method
		}

		ToolAvailabilityStore.shared.$toolSummaries
			.dropFirst()
			.sink { [weak self] _ in
				self?.invalidateToolsCache()
			}
			.store(in: &cancellables)


		// Enable tools based on autoStartServer setting.
		let autoStartServer = UserDefaults.standard.bool(forKey: "mcpAutoStart")
		windowToolsEnabled = autoStartServer
	}

	// MARK: – Private helpers
	/// Listens to `service.stateStream` and updates UI state.
	/// Runs once during init, so no cancellation handling needed.
	private func observeService() {
		Task { [weak self] in
			guard let self else { return }

			for await snapshot in self.service.stateStream {
				// Hop back to the main actor for all UI/state mutations
				await self.apply(snapshot)
			}
		}
	}

	/// Observes external client error events written to disk by the CLI
	private func observeExternalEvents() {
		let monitor = MCPExternalEventsMonitor.shared
		monitor.start()

		// Subscribe to event updates
		monitor.$latestEvent
			.receive(on: RunLoop.main)
			.sink { [weak self] event in
				self?.lastExternalClientEvent = event
			}
			.store(in: &cancellables)

		// Subscribe to error count updates
		monitor.$recentErrorCount
			.receive(on: RunLoop.main)
			.sink { [weak self] count in
				self?.externalClientErrorCount = count
			}
			.store(in: &cancellables)

		// Cleanup old events periodically (once per app launch is enough)
		monitor.cleanupOldEvents()
	}

	/// Updates published properties and sets the overlay visibility.
	/// Must run on the main actor because the view-model is `@MainActor`.
	@MainActor
	private func apply(_ snap: MCPService.Snapshot) async {
		let hadPendingApproval = self.pendingClientID != nil

		self.isRunning            = snap.isRunning
		self.pendingClientID      = snap.pendingClientID
		self.diagnostics          = snap.diagnostics
		self.lastErrorMessage     = humanReadableError(from: snap.diagnostics.issue)

		// Show the approval overlay when a client is waiting
		self.isApprovalOverlayVisible = (snap.pendingClientID != nil)

		// When a new approval request arrives, bring the appropriate window to front
		if snap.pendingClientID != nil && !hadPendingApproval && windowToolsEnabled {
			bringWindowToFront()
		}

		// Request user attention if app is not active
		if snap.pendingClientID != nil && !NSApp.isActive {
			NSApp.requestUserAttention(.criticalRequest)
		}

		if shouldObserveDashboardUpdates {
			let latestDashboard = await service.dashboardSnapshot()
			self.dashboard = latestDashboard
		} else if !windowToolsEnabled {
			self.dashboard = nil
		}
	}

	/// Brings this window to front to show the approval overlay
	@MainActor
	private func bringWindowToFront() {
		guard let windowState = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }),
			let nsWindow = windowState.nsWindow else {
			return
		}

		// Activate the app if not active
		if !NSApp.isActive {
			NSApp.activate(ignoringOtherApps: true)
		}

		// Bring window to front and make it key
		nsWindow.makeKeyAndOrderFront(nil)
	}

	@MainActor
	private func humanReadableError(from issue: MCPServerIssue) -> String? {
		switch issue {
		case .none:
			return nil
		case .localNetworkPermissionDenied:
			return "Local Network permission appears to be disabled. RepoPrompt cannot advertise the MCP server."
		case .bonjourRegistrationFailed(let message):
			return "The MCP listener failed to advertise via Bonjour: \(message)"
		case .listenerRestarting:
			return "The MCP listener is restarting after a network error."
		case .portInUse:
			return "Another process is using the MCP port. The listener is retrying on a different port."
		case .discoveryDegraded(let message):
			return "Bonjour discovery is degraded: \(message)"
		case .lastClientApprovalDenied(let clientID):
			return "The last MCP client (\(clientID)) was denied."
		case .lastClientApprovalTimedOut(let clientID):
			return "The MCP client (\(clientID)) was auto-denied after approval timeout."
		case .lastClientDisconnectedUnexpectedly(let clientID):
			return "Client \(clientID ?? "unknown") disconnected unexpectedly."
		case .identityRecoveryDegraded(let message):
			return "Identity recovery failed repeatedly: \(message). Switched to filesystem-only transport."
		}
	}

	// -----------------------------------------------------------------
	// MARK:  Public control API
	// -----------------------------------------------------------------
	/// Enables tools for this window and awaits MCP readiness for agent bootstrap.
	func startServer() async {
		await ensureServerReadyForAgentBootstrap()
	}

	/// Ensures tools are enabled and the window is joined before agent bootstrap continues.
	func ensureServerReadyForAgentBootstrap() async {
		if !windowToolsEnabled {
			windowToolsEnabled = true
		}
		await updateToolRegistration()
	}

	/// Disables tools for this window.
	func stopServer() async {
		windowToolsEnabled = false
	}

	/// Convenience UI toggle.
	func toggle() async {
		windowToolsEnabled.toggle()
	}

	/// Force a state refresh from the service
	func refreshState() async {
		// This will trigger a new state emission which will update isRunning
		await service.refreshState()
	}


	/// Updates tool registration based on windowToolsEnabled state
	@MainActor
	private func updateToolRegistration() async {
		invalidateToolsCache()

		if windowToolsEnabled {
			ServiceRegistry.register(self)   // idempotent
			do {
				try await service.join(windowID: windowID)
				await service.refreshState()
			} catch {
				logger.error("Failed to join MCP: \(error)")
			}
		} else {
			ServiceRegistry.unregister(self)
			await service.leave(windowID: windowID)
			await service.refreshState()
		}
	}

	/// Hard kill (Settings > Force Stop)
	func shutdownListener() async {
		await service.fullShutdown()
	}

	/// Called by UI after the alert sheet closes
	func resolveApproval(allow: Bool, alwaysAllow: Bool = false) async {
		await service.continuePendingApproval(allow: allow,
												alwaysAllow: alwaysAllow)
	}

	// MARK: - Dashboard Methods

	private var shouldObserveDashboardUpdates: Bool {
		if windowToolsEnabled {
			return true
		}
		return !dashboardConsumers.isEmpty
	}

	@MainActor
	func setDashboardUpdatesVisible(_ visible: Bool, consumer: DashboardConsumer) {
		if visible {
			dashboardConsumers.insert(consumer)
		} else {
			dashboardConsumers.remove(consumer)
		}
		updateDashboardSubscriptionIfNeeded()
	}

	/// Start listening for dashboard updates for the status view.
	@MainActor
	func startDashboardUpdates() {
		setDashboardUpdatesVisible(true, consumer: .statusView)
	}

	/// Stop listening for dashboard updates for the status view.
	@MainActor
	func stopDashboardUpdates() {
		setDashboardUpdatesVisible(false, consumer: .statusView)
	}

	@MainActor
	private func updateDashboardSubscriptionIfNeeded() {
		if shouldObserveDashboardUpdates {
			startDashboardUpdatesIfNeeded()
		} else {
			stopDashboardUpdatesSubscription(clearSnapshot: true)
		}
	}

	@MainActor
	private func startDashboardUpdatesIfNeeded() {
		guard shouldObserveDashboardUpdates, dashboardTask == nil else { return }

		let taskID = UUID()
		dashboardTaskID = taskID
		dashboardTask = Task { [weak self] in
			guard let self else { return }

			let (subscriptionID, stream) = await self.service.subscribeToDashboardUpdates()
			defer {
				Task { [service = self.service, subscriptionID] in
					await service.unsubscribeFromDashboardUpdates(id: subscriptionID)
				}
				Task { @MainActor [weak self] in
					guard let self else { return }
					if self.dashboardSubscriptionID == subscriptionID {
						self.dashboardSubscriptionID = nil
					}
					guard self.dashboardTaskID == taskID else { return }
					self.dashboardTask = nil
					self.dashboardTaskID = nil
					if self.shouldObserveDashboardUpdates {
						self.startDashboardUpdatesIfNeeded()
					}
				}
			}

			await MainActor.run {
				guard !Task.isCancelled, self.dashboardTaskID == taskID else { return }
				self.dashboardSubscriptionID = subscriptionID
			}
			guard !Task.isCancelled else { return }
			guard await MainActor.run(body: { self.dashboardTaskID == taskID && self.shouldObserveDashboardUpdates }) else { return }

			let initialSnap = await self.service.dashboardSnapshot()
			await MainActor.run {
				guard self.shouldObserveDashboardUpdates else { return }
				self.dashboard = initialSnap
			}

			for await _ in stream {
				guard !Task.isCancelled else { break }
				mcpServerViewModelDebugLog("Dashboard update notification received, fetching snapshot...")
				let snap = await self.service.dashboardSnapshot()
				mcpServerViewModelDebugLog("Dashboard snapshot fetched with \(snap.connections.count) connection(s)")
				await MainActor.run {
					guard self.shouldObserveDashboardUpdates else { return }
					self.dashboard = snap
				}
			}
		}
	}

	@MainActor
	private func stopDashboardUpdatesSubscription(clearSnapshot: Bool) {
		dashboardTask?.cancel()
		dashboardTask = nil
		dashboardTaskID = nil

		if let id = dashboardSubscriptionID {
			Task { [service, id] in
				await service.unsubscribeFromDashboardUpdates(id: id)
			}
			dashboardSubscriptionID = nil
		}

		if clearSnapshot {
			dashboard = nil
		}
	}

	/// Forcefully disconnect a specific connection (legacy - calls terminateConnection)
	@MainActor
	func bootConnection(_ id: UUID) {
		terminateConnection(id, reason: .userBootFromDashboard)
	}

	/// Terminates a connection with explicit kill semantics.
	/// CLI will exit without retrying.
	@MainActor
	func terminateConnection(_ id: UUID, reason: TerminationReason, message: String? = nil) {
		mcpServerViewModelDebugLog("Terminating connection \(id) from dashboard (reason: \(reason.rawValue))")
		Task { [service] in
			await service.terminateConnection(id: id, reason: reason, message: message)
		}
	}

	/// Add or remove a client from the persistent allow-list
	@MainActor
	func setAlwaysAllowed(clientID: String, allowed: Bool) {
		Task { [service] in
			await service.setAlwaysAllowed(clientID: clientID, allowed: allowed)
		}
	}

	/// Set the global auto-approve flag
	@MainActor
	func setAutoApproveAllClients(_ enabled: Bool) {
		Task { [service] in
			await service.setAutoApproveAllClients(enabled)
		}
	}

	@MainActor
	private func invalidateToolsCache() {
		toolsCache = nil
	}

	// =====================================================================
	// MARK:  TOOL capability
	// =====================================================================

	private enum ToolNames {
		static let search                   = "file_search"
		static let manageSelection          = "manage_selection"

		static let workspaceContext         = "workspace_context"
		static let prompt                   = "prompt"
		static let getCodeStructure         = "get_code_structure"
		static let readFile                 = "read_file"
		static let fileActions              = "file_actions"
		static let getFileTree              = "get_file_tree"
		static let applyEdits               = "apply_edits"
		static let askOracle                = "ask_oracle"
		static let oracleSend               = "oracle_send"
		static let oracleUtils              = "oracle_utils"
		static let oracleChatLog            = "oracle_chat_log"
		static let git                      = "git"
		static let agentExplore             = "agent_explore"
		static let agentRun                 = "agent_run"
		static let agentManage              = "agent_manage"
		// Agent mode tools
		static let shareThoughts            = "share_thoughts"
		static let waitForNextInstruction   = "wait_for_next_user_instruction"
		static let setStatus                = "set_status"
	}

	enum ContextBuilderTabPlan: Equatable {
		case agentModeReuse
		case freshTab
		case explicitTab(UUID)
	}

	static func planContextBuilderTab(
		purpose: MCPRunPurpose,
		explicitTabID: UUID?
	) -> ContextBuilderTabPlan {
		if purpose == .agentModeRun {
			return .agentModeReuse
		}
		if let explicitTabID {
			return .explicitTab(explicitTabID)
		}
		return .freshTab
	}

	static func resolveExplicitTabIDForAgentMode(
		rawTabID: String?,
		availableTabIDs: Set<UUID>
	) throws -> UUID? {
		let trimmed = rawTabID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !trimmed.isEmpty else {
			return nil
		}
		guard let tabID = UUID(uuidString: trimmed) else {
			throw MCPError.invalidParams("Invalid _tabID '\(trimmed)'. Expected a UUID.")
		}
		guard availableTabIDs.contains(tabID) else {
			throw MCPError.invalidParams("Tab not found for _tabID '\(tabID.uuidString)'.")
		}
		return tabID
	}

	nonisolated private static func normalizedTabIDArgument(_ rawTabID: String?) -> String? {
		let trimmed = rawTabID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return trimmed.isEmpty ? nil : trimmed
	}

	nonisolated private static func resolveApplyEditsAgentModeTabID(
		runPurpose: MCPRunPurpose?,
		virtualTabID: UUID?,
		rawTabID: String?,
		availableTabIDs: Set<UUID>
	) throws -> UUID? {
		guard runPurpose == .agentModeRun else { return virtualTabID }

		let normalizedRawTabID = normalizedTabIDArgument(rawTabID)
		if let normalizedRawTabID, UUID(uuidString: normalizedRawTabID) == nil {
			throw MCPError.invalidParams("Invalid _tabID '\(normalizedRawTabID)'. Expected a UUID.")
		}
		let explicitTabID = normalizedRawTabID.flatMap(UUID.init(uuidString:))

		let resolvedTabID = virtualTabID ?? explicitTabID
		guard let resolvedTabID else {
			throw MCPError.invalidParams(
				"RepoPrompt could not route this Agent Mode MCP call to the active run. Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
			)
		}
		let sourceDescription = (virtualTabID != nil && resolvedTabID == virtualTabID)
			? "bound tab"
			: "_tabID '\(resolvedTabID.uuidString)'"
		guard availableTabIDs.contains(resolvedTabID) else {
			throw MCPError.invalidParams("Tab not found for \(sourceDescription).")
		}
		return resolvedTabID
	}

	// ────────────────────────────────────────────────────────────────
	//  MARK: - Shared wrappers for every MCP tool        🆕 NEW
	// ────────────────────────────────────────────────────────────────

	@MainActor
	private func shouldTrackActiveTool(for metadata: RequestMetadata) async -> Bool {
		guard let connectionID = metadata.connectionID else { return true }
		let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
		return purpose != .agentModeRun
	}

	private func shouldRegisterRunToolExecution(toolName: String) -> Bool {
		// The per-run idle waiter should observe tools executed *by* the active run.
		// External control-plane calls (agent_run/agent_manage) may intentionally
		// steer that same run from outside it; tracking them as run-owned tools can
		// deadlock steering behind its own MCP request. Agent-run wait ownership is
		// tracked separately by beginAgentRunWaitScope/endAgentRunWaitScope.
		let capabilities = MCPToolCapabilities.capabilities(for: toolName)
		return !capabilities.contains(.agentExternalControl)
			&& !capabilities.contains(.agentExploreControl)
	}

	/// Executes `body` with a standardised life‑cycle around every tool call:
	///   1. Flush pending file‑system deltas (optional)
	///   2. Set `activeToolName` on the MainActor
	///   3. Run the tool implementation
	///   4. Clear `activeToolName`
	///
	/// - Parameters:
	///   - name:      Identifier of the tool (used for UI state)
	///   - flushFS:   When `true` (default) we run
	///                `fileManager.flushPendingDeltas()` before execution.
	///   - body:      The actual implementation provided by the caller.
	/// - Returns:     Whatever `body` returns.
	/// - Throws:      Rethrows any error from `body`.
	@inline(__always)
	private func runTool<T>(
		_ name: String,
		flushFS flush: Bool = true,
		timeoutSeconds: Int = 10000,  // Default ~2.7 hour timeout (matches Codex tool_timeout_sec)
		body: @escaping @Sendable () async throws -> T   // ← @escaping added
	) async throws -> T {

		if flush { await fileManager.flushPendingDeltas(aggressive: true) }

		// Eagerly attempt to bind any queued tab context for this connection
		// This ensures non-tab-scoped tools (like get_file_tree, file_search) can
		// trigger context binding, preventing "live mode" drift in parallel runs
		let metadata = await captureRequestMetadata()
		let execContext = resolveExecContext(from: metadata)
		if case .virtual(let context) = execContext {
			mcpServerViewModelDebugLog("runTool '\(name)' bound context for tab=\(context.tabID) runID=\(context.runID?.uuidString ?? "nil")")
		}

		let shouldTrackActiveTool = await shouldTrackActiveTool(for: metadata)
		let executionRunID = await resolveRunIDForExecution(metadata: metadata, execContext: execContext)

		// Generate a unique token for this tool execution to prevent cleanup races
		let toolToken = UUID()
		let capturedConnectionID = metadata.connectionID

		if shouldTrackActiveTool {
			await MainActor.run {
				self.activeToolToken = toolToken
				self.activeToolConnectionID = capturedConnectionID
				self.activeToolName = name
				self.cancelCurrentTool = nil
			}
		}

		// 🔑 run work completely off the UI thread
		// Propagate TaskLocal connectionID so tools can resolve tab context
		let task = Task {
			try await ServerNetworkManager.withConnectionID(capturedConnectionID) {
				try await body()
			}
		}

		// Register in per-run tracking and store a single-slot canceller for legacy UI
		await MainActor.run {
			if shouldTrackActiveTool {
				self.cancelCurrentTool = { task.cancel() }
			}
			if shouldRegisterRunToolExecution(toolName: name),
				let connectionID = capturedConnectionID,
				let runID = executionRunID {
				self.registerToolExecution(
					executionID: toolToken,
					runID: runID,
					connectionID: connectionID,
					toolName: name,
					cancel: { task.cancel() }
				)
			}
		}

		do {
			// Timeout wrapper to prevent stuck tools
			let result = try await withThrowingTaskGroup(of: T.self) { group in
				group.addTask { try await task.value }
				group.addTask {
					try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * UInt64(1_000_000_000))
					throw MCPError.internalError("tool '\(name)' timed out after \(timeoutSeconds)s")
				}
				let value = try await group.next()!
				group.cancelAll()
				return value
			}
			// Clean up after successful completion (only if this tool execution is still current)
			await MainActor.run {
				self.unregisterToolExecution(executionID: toolToken)
				if shouldTrackActiveTool, self.activeToolToken == toolToken {
					self.clearActiveToolSlot()
				}
			}
			return result
		} catch let err {
			task.cancel() // ensure no leak
			// Clean up after error (only if this tool execution is still current)
			await MainActor.run {
				self.unregisterToolExecution(executionID: toolToken)
				if shouldTrackActiveTool, self.activeToolToken == toolToken {
					self.clearActiveToolSlot()
				}
			}
			if err is CancellationError {
				throw MCPError.internalError("tool cancelled by user")
			}
			throw err
		}
	}

	/// Convenience builder that
	///   • captures the view-model *weakly*
	///   • funnels execution through `runTool` so prologue/epilogue always run
	///
	/// Use this for **all** tool declarations.
	private func weakTool<T: Encodable>(
		name               : String,
		description        : String,
		annotations        : MCP.Tool.Annotations = .init(),
		inputSchema        : JSONSchema,
		flushFS            : Bool = true,
		isEnabledByDefault : Bool = true,
		implementation     : @escaping @Sendable
		(MCPServerViewModel, [String:Value]) async throws -> T
	) -> Tool {

		Tool(
			name: name,
			description: description,
			inputSchema: inputSchema,
			annotations: annotations,
			isEnabledByDefault: isEnabledByDefault
		) { [weak self] args in
			// Guard against window deallocation before the call starts
			guard let self else {
				throw MCPError.internalError("Window deallocated while executing \(name)")
			}

			// Route through runTool (handles flush, tracking, cancellation hooks)
			return try await self.runTool(name, flushFS: flushFS) { [weak self] in
				// Guard again inside the task to avoid retain cycles
				guard let self else {
					throw MCPError.internalError("Window deallocated during \(name)")
				}
				return try await implementation(self, args)
			}
		}
	}

	// =====================
	// MARK:  Shared edit helpers
	// =====================
	private func requireLoadedFile(_ rawPath: String) async throws -> FileViewModel {
		if let fileVM = await fileManager.findFile(atPath: rawPath) {
			_ = await fileVM.latestContent
			return fileVM
		}
		// Provide richer context to the caller
		let msg = await workspaceContextMessage(forOperation: "open file", path: rawPath)
		throw MCPError.invalidParams("Unknown or unloaded path: \(rawPath). \(msg)")
	}

	private func editSummary(
		from result: ApplyEditsResult,
		path: String,
		statusOverride: String? = nil,
		noteOverride: String? = nil,
		reviewStatus: String? = nil,
		rejectionReason: String? = nil,
		requiresUserApproval: Bool? = nil
	) -> EditSummary {
		let lineStats = result.toolCardLineStats()
		return EditSummary(
			status: statusOverride ?? result.status.rawValue,
			editsRequested: result.editsRequested,
			editsApplied: result.editsApplied,
			addedLines: lineStats?.addedLines,
			deletedLines: lineStats?.deletedLines,
			totalLinesChanged: result.stats?.linesChanged,
			totalChunks: result.stats?.chunks,
			results: result.outcomes,
			unifiedDiff: result.unifiedDiff,
			cardUnifiedDiff: result.unifiedDiffForToolCard(filePath: path),
			note: noteOverride ?? result.note,
			fileCreated: result.fileCreated ? true : nil,
			fileOverwritten: result.fileOverwritten ? true : nil,
			reviewStatus: reviewStatus,
			rejectionReason: rejectionReason,
			requiresUserApproval: requiresUserApproval
		)
	}

	private func mapApplyEditsError(_ error: ApplyEditsError) -> MCPError {
		switch error {
		case .invalidParams(let message):
			return MCPError.invalidParams(message)
		case .internalError(let message):
			return MCPError.internalError(message)
		}
	}

	private func mapStrictWorkspaceFileContentError(_ error: StrictWorkspaceFileContentError, path: String?) -> MCPError {
		let displayPath = path ?? "requested file"
		switch error {
		case .fileMissing:
			return MCPError.invalidParams("File not found: '\(displayPath)'. The path is inside a loaded folder, but no file exists there.")
		case .serviceUnavailable:
			return MCPError.internalError(error.localizedDescription)
		case .readFailed:
			return MCPError.invalidParams(error.localizedDescription)
		}
	}

	// -----------------------------------------------------------------
	// MARK:  Service – Tool catalogue
	// -----------------------------------------------------------------
	var tools: [Tool] {
		get async {
			if let cached = toolsCache {
				return cached
			}
			let built = buildTools()
			toolsCache = built
			return built
		}
	}

	internal func executeFileSearchTool(
		args: [String: Value],
		diagnosticLabel: String? = nil
	) async throws -> ToolResultDTOs.SearchResultDTO {
		let diagnosticRunID: UUID?
		#if DEBUG
		diagnosticRunID = MCPFileSearchPerfDiagnostics.beginRun(label: diagnosticLabel)
		let parseArgsStartMS = MCPFileSearchPerfDiagnostics.timestampMS()
		#else
		diagnosticRunID = nil
		#endif
		var diagnosticResponseBytes: Int?
		defer {
			#if DEBUG
			MCPFileSearchPerfDiagnostics.finishRun(runID: diagnosticRunID, responseJSONBytes: diagnosticResponseBytes)
			#endif
		}
			// Validate and normalize pattern
			let rawPattern = args["pattern"]?.stringValue ?? ""
			let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !pattern.isEmpty else {
				throw MCPError.invalidParams("pattern cannot be empty; provide a non-empty search term. If you intend to enumerate files, use get_file_tree or specify a path mode with a wildcard like '*.swift'.")
			}

			let modeRaw = args["mode"]?.stringValue ?? "auto"
			let regexArg = args["regex"]?.boolValue
			let regex = regexArg ?? FileSearchActor.containsRegexSyntax(pattern)
			let wholeWord = args["whole_word"]?.boolValue ?? false

			// Support -C aliases (ripgrep-style) including shorthand forms like "-C: 2"
			let contextLines = args["context_lines"]?.intValue
				?? Int(args["context_lines"]?.stringValue ?? "")
				?? Self.parseContextAlias(args)
				?? 0

			let maxResults = args["max_results"]?.intValue ?? 50
			let countOnly = args["count_only"]?.boolValue ?? false

			// Smart defaults for removed parameters
			let ci = true  // Always case-insensitive for better UX
			let fuzzySpace = pattern.contains(" ")  // Auto-enable for patterns with spaces

			// Parse filter object
			let filter = args["filter"]?.objectValue
			let includeExts = filter?["extensions"]?.arrayValue?.compactMap { $0.stringValue } ?? []
			let excludePatterns = filter?["exclude"]?.arrayValue?.compactMap { $0.stringValue } ?? []

			// Support both filter.paths and path (as shorthand for single-file search)
			var limiters = filter?["paths"]?.arrayValue?.compactMap { $0.stringValue }
			if limiters == nil || limiters?.isEmpty == true {
				// Check for path as a direct parameter (alias for filter.paths with single value)
				if let singlePath = args["path"]?.stringValue {
					limiters = [singlePath]
				}
			}

			// Track whether user specified a path filter before sanitization may drop empties.
			let hadPathFilter = limiters != nil && !(limiters?.isEmpty ?? true)

			if let current = limiters, !current.isEmpty {
				limiters = Self.sanitizeSearchScopeInputs(current)
			}

			let mode = SearchMode(rawValue: modeRaw) ?? .auto
			#if DEBUG
			MCPFileSearchPerfDiagnostics.recordParseArgs(
				runID: diagnosticRunID,
				durationMS: MCPFileSearchPerfDiagnostics.elapsedMS(since: parseArgsStartMS)
			)
			#endif

			let metadata = await self.captureRequestMetadata()
			let lookupRootScope = await self.resolveFileToolLookupRootScope(from: metadata)
			let results: SearchResults
			do {
				#if DEBUG
				let fileManagerSearchStartMS = MCPFileSearchPerfDiagnostics.timestampMS()
				#endif
				results = try await self.fileManager.search(
					pattern: pattern,
					mode: mode,
					isRegex: regex,
					caseInsensitive: ci,
					maxPaths: maxResults,
					maxMatches: maxResults,
					paths: limiters,
					includeExtensions: includeExts,
					excludePatterns: excludePatterns,
					contextLines: contextLines,
					wholeWord: wholeWord,
					countOnly: countOnly,
					fuzzySpaceMatching: fuzzySpace,
					rootScope: lookupRootScope,
					diagnosticRunID: diagnosticRunID
				)
				#if DEBUG
				MCPFileSearchPerfDiagnostics.recordFileManagerSearch(
					runID: diagnosticRunID,
					durationMS: MCPFileSearchPerfDiagnostics.elapsedMS(since: fileManagerSearchStartMS)
				)
				#endif
			} catch let error as SearchPatternError {
				let parts = Self.friendlySearchErrorParts(
					for: pattern,
					isRegex: regex,
					error: error
				)
				let reply = ToolResultDTOs.SearchResultDTO(
					totalMatches: 0,
					totalFiles: 0,
					contentMatches: 0,
					pathMatches: 0,
					limitHit: false,
					perFileCounts: [],
					pathMatchLines: [],
					contentMatchGroups: [],
					errorMessage: parts.issue,
					suggestion: parts.suggestion
				)
				diagnosticResponseBytes = Self.encodedJSONByteCount(reply)
				return reply
			} catch {
				// Re-throw other errors as-is
				throw error
			}

			func makeResponseDisplayPathResolvers(
				visibleRootFolders: [FolderViewModel],
				allRootFolders: [FolderViewModel]
			) -> (displayPath: (String) -> String, cachedDisplayPath: (String) -> String) {
				let visibleRoots = visibleRootFolders.map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.fullPath) }
				let allRoots = allRootFolders.map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.fullPath) }
				let displayPath: (String) -> String = { rawPath in
					RepoFileManagerViewModel.mcpDisplayPath(
						fullPath: rawPath,
						visibleRoots: visibleRoots,
						allRoots: allRoots
					)
				}
				var cache: [String: String] = [:]
				let cachedDisplayPath: (String) -> String = { rawPath in
					// Search results already carry full paths, so the raw full path is a
					// root-safe cache identity without adding an extra standardization pass.
					if let cached = cache[rawPath] {
						return cached
					}
					let result = displayPath(rawPath)
					cache[rawPath] = result
					return result
				}
				return (displayPath, cachedDisplayPath)
			}

			if countOnly {
				#if DEBUG
				let responseFormattingStartMS = MCPFileSearchPerfDiagnostics.timestampMS()
				#endif
				let contentMatches = results.totalCount ?? results.matches?.count ?? 0
				let visibleRootFolders = await self.fileManager.visibleRootFolders
				let allRootFolders = await self.fileManager.rootFolders
				let displayPathResolvers = makeResponseDisplayPathResolvers(
					visibleRootFolders: visibleRootFolders,
					allRootFolders: allRootFolders
				)
				let normalizedContentPaths = Set((results.matches ?? []).map {
					displayPathResolvers.cachedDisplayPath($0.filePath)
				})
				let normalizedPathMatches = Set((results.paths ?? []).map {
					displayPathResolvers.displayPath($0)
				})
				let contentFiles = results.contentFileCount ?? normalizedContentPaths.count
				let pathMatches = normalizedPathMatches.count
				let pathDisplay = Array(normalizedPathMatches).sorted()
				let matchedFiles = normalizedContentPaths.union(normalizedPathMatches).count
				let pathFilterSuggestion = Self.pathFilterSuggestion(
					hadPathFilter: hadPathFilter,
					scopedFileCount: results.scopedFileCount
				)

				let reply = ToolResultDTOs.SearchResultDTO(
					totalMatches: contentMatches + pathMatches,
					totalFiles: contentFiles,
					matchedFiles: matchedFiles,
					searchedFiles: results.searchedFileCount,
					contentMatches: contentMatches,
					pathMatches: pathMatches,
					limitHit: false,
					perFileCounts: [],
					pathMatchLines: pathDisplay,
					contentMatchGroups: [],
					suggestion: pathFilterSuggestion,
					warning: results.warningMessage
				)
				diagnosticResponseBytes = Self.encodedJSONByteCount(reply)
				#if DEBUG
				MCPFileSearchPerfDiagnostics.recordResponseFormatting(
					runID: diagnosticRunID,
					durationMS: MCPFileSearchPerfDiagnostics.elapsedMS(since: responseFormattingStartMS),
					responseJSONBytes: diagnosticResponseBytes,
					pathMatches: pathMatches,
					contentMatches: contentMatches,
					totalMatches: contentMatches + pathMatches
				)
				#endif
				return reply
			}

			// Build plain-text output
			#if DEBUG
			let responseFormattingStartMS = MCPFileSearchPerfDiagnostics.timestampMS()
			#endif
			// Keep 0-based line numbers; convert to 1-based when formatting output.
			let visibleRootFolders = await self.fileManager.visibleRootFolders
			let allRootFolders = await self.fileManager.rootFolders
			let displayPathResolvers = makeResponseDisplayPathResolvers(
				visibleRootFolders: visibleRootFolders,
				allRootFolders: allRootFolders
			)
			let normalizedMatches: [SearchMatch] = (results.matches ?? []).map { m in
				SearchMatch(
					filePath: displayPathResolvers.cachedDisplayPath(m.filePath),
					lineNumber: m.lineNumber,
					lineText: m.lineText,
					contextBefore: m.contextBefore,
					contextAfter: m.contextAfter
				)
			}

			// Path & content matches BEFORE size-capping (already limited by max_results upstream)
			// Convert paths to root-alias format
			let pathMatchesFull: [String] = (results.paths ?? []).map {
				displayPathResolvers.displayPath($0)
			}
			let contentMatchesFull: [SearchMatch] = normalizedMatches
			let perFileTotalsDTO: [ToolResultDTOs.PerFileCount] = {
				var totals: [String: Int] = [:]
				for match in contentMatchesFull {
					totals[match.filePath, default: 0] += 1
				}
				return totals
					.sorted { $0.key < $1.key }
					.map { ToolResultDTOs.PerFileCount(path: $0.key, count: $0.value) }
			}()

			// --- Character-budget capping (approximate, whole-entry only) ---
			let RESPONSE_CHAR_CAP = 50_000
			let CAP_HEADROOM      = 2_000       // buffer for JSON overhead & small fields
			let BUDGET            = max(0, RESPONSE_CHAR_CAP - CAP_HEADROOM)

			// Prefer including content lines first, then path lines
			var usedChars = 0

			// Include as many content matches as will fit
			var includedContentMatches = [SearchMatch]()
			includedContentMatches.reserveCapacity(contentMatchesFull.count)

                for m in contentMatchesFull {
                    let lineStr = "\(m.filePath):\(m.lineNumber + 1): \(m.lineText)"
				// Approximate JSON overhead per string entry (+3 for quotes/comma)
				let cost = lineStr.count + 3
				if usedChars + cost > BUDGET { break }
				includedContentMatches.append(m)
				usedChars += cost
			}

			// Include as many path matches as will fit in the remaining budget
			var includedPathLines = [String]()
			includedPathLines.reserveCapacity(pathMatchesFull.count)
			for p in pathMatchesFull {
				let cost = p.count + 3
				if usedChars + cost > BUDGET { break }
				includedPathLines.append(p)
				usedChars += cost
			}

			// Compute omitted counts (due to char budget, not max_results)
			let omittedContent = contentMatchesFull.count - includedContentMatches.count
			let omittedPaths   = pathMatchesFull.count   - includedPathLines.count
			let sizeLimitHit   = (omittedContent + omittedPaths) > 0

			// Aggregate counts based on what we actually include in the payload
			let filesWithContent = Set(includedContentMatches.map { $0.filePath }).count
			let matchedFilesFull = Set(contentMatchesFull.map(\.filePath)).union(Set(pathMatchesFull)).count
			let includedContentCount = includedContentMatches.count
			let includedPathCount    = includedPathLines.count
			let totalMatchesIncluded = includedContentCount + includedPathCount

			// We also treat hitting max_results as a "limit hit".
			// Either limit (count or size) flips this to true.
			let hitMaxCountLimit = (contentMatchesFull.count >= maxResults) || (pathMatchesFull.count >= maxResults)
			let limitHit = sizeLimitHit || hitMaxCountLimit

			// Per-file counts from included content only
			var perFileCounts: [String: Int] = [:]
			for m in includedContentMatches { perFileCounts[m.filePath, default: 0] += 1 }
			let perFileCountDTOs: [ToolResultDTOs.PerFileCount] = perFileCounts
				.sorted { $0.key < $1.key }
				.map { ToolResultDTOs.PerFileCount(path: $0.key, count: $0.value) }

			// Group matches per file while preserving inclusion order
			var seenPaths = Set<String>()
			var orderedPaths: [String] = []
			for match in includedContentMatches {
				if seenPaths.insert(match.filePath).inserted {
					orderedPaths.append(match.filePath)
				}
			}

			let groupedMatches = Dictionary(grouping: includedContentMatches, by: { $0.filePath })
			let contentGroups: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup] = orderedPaths.compactMap { path in
				guard let matches = groupedMatches[path] else { return nil }
				let sortedMatches = matches.sorted { $0.lineNumber < $1.lineNumber }
				let lines = sortedMatches.map { match -> ToolResultDTOs.SearchResultDTO.ContentMatchGroup.Line in
					let beforeRaw = match.contextBefore ?? []
					let afterRaw = match.contextAfter ?? []
					let baseLine = match.lineNumber + 1

					let beforeLines: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine]? = {
						guard !beforeRaw.isEmpty else { return nil }
						let startLine = max(1, baseLine - beforeRaw.count)
						return beforeRaw.enumerated().map { offset, text in
							ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine(
								lineNumber: startLine + offset,
								lineText: text
							)
						}
					}()

					let afterLines: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine]? = {
						guard !afterRaw.isEmpty else { return nil }
						return afterRaw.enumerated().map { offset, text in
							ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine(
								lineNumber: baseLine + offset + 1,
								lineText: text
							)
						}
					}()

					return ToolResultDTOs.SearchResultDTO.ContentMatchGroup.Line(
						lineNumber: baseLine,
						lineText: match.lineText,
						contextBefore: beforeLines,
						contextAfter: afterLines
					)
				}
				return ToolResultDTOs.SearchResultDTO.ContentMatchGroup(path: path, lines: lines)
			}

			let pathFilterSuggestion = Self.pathFilterSuggestion(
				hadPathFilter: hadPathFilter,
				scopedFileCount: results.scopedFileCount
			)

			// Final trimmed payload
			let reply = ToolResultDTOs.SearchResultDTO(
				totalMatches: totalMatchesIncluded,
				totalFiles: filesWithContent,
				matchedFiles: matchedFilesFull,
				searchedFiles: results.searchedFileCount,
				contentMatches: includedContentCount,
				pathMatches: includedPathCount,
				limitHit: limitHit,
				perFileCounts: perFileCountDTOs,
				pathMatchLines: includedPathLines,
				contentMatchGroups: contentGroups,
				// NEW size-cap metadata (only set when we actually trimmed)
				sizeLimitHit: sizeLimitHit ? true : nil,
				omittedTotal: sizeLimitHit ? (omittedContent + omittedPaths) : nil,
				omittedContentMatches: (omittedContent > 0) ? omittedContent : nil,
				omittedPathMatches:   (omittedPaths   > 0) ? omittedPaths   : nil,
				suggestion: pathFilterSuggestion,
				warning: results.warningMessage,
				perFileTotals: perFileTotalsDTO.isEmpty ? nil : perFileTotalsDTO
			)
			await self.maybeAutoSelectFileSearchSlices(
				mode: mode,
				contextLines: contextLines,
				reply: reply
			)
			diagnosticResponseBytes = Self.encodedJSONByteCount(reply)
			#if DEBUG
			MCPFileSearchPerfDiagnostics.recordResponseFormatting(
				runID: diagnosticRunID,
				durationMS: MCPFileSearchPerfDiagnostics.elapsedMS(since: responseFormattingStartMS),
				responseJSONBytes: diagnosticResponseBytes,
				pathMatches: includedPathCount,
				contentMatches: includedContentCount,
				totalMatches: totalMatchesIncluded
			)
			#endif
			return reply
	}

	private static func encodedJSONByteCount<T: Encodable>(_ value: T) -> Int? {
		try? JSONEncoder().encode(value).count
	}


	@MainActor
	private func buildTools() -> [Tool] {
		let coreTools: [Tool] = [
		// ───────────  manage_selection  ───────────
		weakTool(
			name: ToolNames.manageSelection,
			description: """
Manage the file selection used by all tools.

**Operations**: get | add | remove | set | clear | preview | promote | demote

**Modes** (how files appear in context):
- `full` (default): Complete file content
- `slices`: Specific line ranges only
- `codemap_only`: API signatures only (function/type definitions)

**Key behaviors**:
- Incremental context updates use `op=add` / `op=remove`; mixed full-file + slice additions use `op=add` with both `paths` and `slices`
- `op=set` with `mode=full`: Complete selection replacement
- `op=set` with `mode=slices`: File-scoped slice replacement only for specified slice files; unrelated full files and other slices remain selected
- `op=set` with `mode=codemap_only`: Complete replacement with codemap-only files
- Auto-codemap: When adding files with `mode=full/slices`, related files get auto-added as codemaps
- Manual mode: Using `mode=codemap_only`, `promote`, or `demote` disables auto-management

**Path handling**:
- Accepts files or directories (directories expand recursively)
- Relative or absolute paths accepted
- Multi-root: prefix with root name (e.g., "ProjectA/src/main.swift")
- Single-root: prefix optional
- Fuzzy matching enabled by default

**Options**:
- `view`: "summary" | "files" | "content" | "codemaps" (default: "summary")
- `path_display`: "relative" | "full" (default: "relative")
- `strict`: When true, errors if no paths resolve (default: false)

**Examples**:
- Get selection: `{"op":"get","view":"files"}`
- Add files: `{"op":"add","paths":["src/main.swift"]}`
- Add slices: `{"op":"add","slices":[{"path":"file.swift","ranges":[{"start_line":45,"end_line":120}]}]}`
- Set codemap-only: `{"op":"set","paths":["utils/"],"mode":"codemap_only"}`
- Promote codemap→full: `{"op":"promote","paths":["helper.swift"]}`

Related: get_file_tree, file_search, workspace_context, prompt, apply_edits
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				properties: [
			"op": .string(description: "Operation", enum: ["get","add","remove","set","clear","preview","promote","demote"]),
					"paths": .array(
						description: "File or folder paths (required for add/remove/set)",
						items: .string(description: "Relative or absolute file or folder path")
					),
					"mode": .string(description: "How to represent files in selection: 'full' (complete content), 'slices' (line ranges), or 'codemap_only' (signatures only). For op=set, full/codemap_only replace the selection; slices replaces slices only for specified files. Use op=add for incremental or mixed paths+slices additions.", enum: ["full","slices","codemap_only"]),
					"slices": .array(
						description: "Selection slices to apply (path + line ranges)",
						items: .object(
								properties: [
									"path": .string(description: "Relative or absolute file path"),
									"ranges": .array(
										description: "Explicit line ranges (inclusive)",
										items: .object(
											properties: [
												"start_line": .integer(description: "1-based start line"),
												"end_line": .integer(description: "1-based end line"),
												"description": .string(description: "Optional slice description (aliases: desc, label)")
											],
											required: ["start_line"]
										)
									),
									"lines": .string(description: "Comma-separated shorthand like '10-20,40'")
							],
							required: ["path"]
						)
					),
			"view": .string(description: "Amount of detail to return", enum: ["summary","files","content","codemaps"]),
					"path_display": .string(description: "Path display for blocks", enum: ["full","relative"]),
					"strict": .boolean(description: "Throw when no paths resolve (mutations)")
				],
				required: []
			)
        ) { owner, args in
		let op = (args["op"]?.stringValue ?? "get").lowercased()
		let rawPaths = args["paths"]?.arrayValue?.compactMap { $0.stringValue } ?? []
		let parsedInputs = owner.parseManageSelectionInputs(rawPaths: rawPaths, slicesValue: args["slices"])
		let selectionPaths = parsedInputs.paths
		let sliceInputs = parsedInputs.sliceInputs
	let sliceParseErrors = parsedInputs.sliceErrors
		let mode = args["mode"]?.stringValue?.lowercased() ?? "full"
		if await owner.codeMapsGloballyDisabledForMCP, mode == "codemap_only" || op == "demote" {
			throw MCPError.invalidParams(Self.codeMapsGloballyDisabledMCPMessage)
		}
		let view = (args["view"]?.stringValue ?? "summary").lowercased()
		let strict = args["strict"]?.boolValue ?? false
		let displayRaw = args["path_display"]?.stringValue ?? "relative"
		let display: FilePathDisplay = (displayRaw.lowercased() == "full") ? .full : .relative
		let includeBlocks = (view == "content")
		var needsTokenRefresh = false

		if (op == "set" || op == "preview"), mode == "codemap_only", !sliceInputs.isEmpty {
			throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
		}
		if (op == "set" || op == "preview"), mode == "slices",
			let slicesValidationError = Self.modeSlicesValidationError(
				selectionPaths: selectionPaths,
				sliceInputs: sliceInputs,
				sliceParseErrors: sliceParseErrors
			) {
			throw MCPError.invalidParams(slicesValidationError)
		}

		// Capture request metadata once to ensure deterministic context resolution
		let metadata = await owner.captureRequestMetadata()
		let execContext = await owner.resolveExecContext(from: metadata)
		let lookupRootScope = await owner.resolveFileToolLookupRootScope(from: metadata)

		if case .virtual = execContext {
			let extraInvalid = sliceParseErrors
			switch op {
			case "get":
				let ctx = try await owner.requireCurrentTabContext(toolName: ToolNames.manageSelection)
				selectionLog("[Virtual] manage_selection op=get tab=\(ctx.tabID) selected=\(ctx.selection.selectedPaths.count) codemap=\(ctx.selection.autoCodemapPaths.count) slices=\(ctx.selection.slices.count)")
				return await owner.buildCurrentSelectionReply(
					includeBlocks: includeBlocks,
					display: display,
					extraInvalid: extraInvalid,
					viewMode: view,
					execContext: execContext
				)
			case "preview":
				var context = try await owner.requireCurrentTabContext(toolName: ToolNames.manageSelection)
				context.selection = await owner.stabilizedVirtualSelection(for: context)
				if mode == "codemap_only" {
					if !sliceInputs.isEmpty {
						throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
					}
				}

				let setPlan = MCPServerViewModel.manageSelectionSetMutationPlan(
					mode: mode,
					pathCount: selectionPaths.count,
					sliceCount: sliceInputs.count
				)
				let buildResult: MCPServerViewModel.BuildStoredSelectionResult
				var previewInputResolved = false
				if setPlan.usesFileScopedSliceReplacement {
					var currentSelection = context.selection
					var invalid: [String] = []
					var codemapUnavailable: [String] = []
					if mode != "slices", !selectionPaths.isEmpty {
						let addResult = await owner.addStoredSelectionPaths(
							existing: currentSelection,
							paths: selectionPaths,
							rawPaths: rawPaths,
							mode: "full",
							lookupRootScope: lookupRootScope
						)
						currentSelection = addResult.selection
						previewInputResolved = previewInputResolved || !addResult.resolvedMap.isEmpty
						invalid.append(contentsOf: addResult.invalidPaths)
						codemapUnavailable.append(contentsOf: addResult.codemapUnavailable)
					}
					let sliceResult = await owner.computeSelectionSlicesVirtual(
						base: currentSelection,
						entries: sliceInputs,
						mode: .setPaths,
						lookupRootScope: lookupRootScope
					)
					previewInputResolved = previewInputResolved || !sliceResult.result.resolvedMap.isEmpty
					invalid.append(contentsOf: sliceResult.result.invalidPaths)
					buildResult = MCPServerViewModel.BuildStoredSelectionResult(
						selection: sliceResult.selection,
						invalidPaths: invalid,
						codemapUnavailable: codemapUnavailable
					)
				} else {
					buildResult = await owner.buildStoredSelection(
						from: parsedInputs,
						mode: mode,
						existing: context.selection,
						lookupRootScope: lookupRootScope
					)
				}
				let previewSelectionFinal: StoredSelection = {
					if mode == "codemap_only" {
						return StoredSelection(
							selectedPaths: buildResult.selection.selectedPaths,
							autoCodemapPaths: buildResult.selection.autoCodemapPaths,
							slices: buildResult.selection.slices,
							codemapAutoEnabled: false
						)
					} else {
						return buildResult.selection
					}
				}()

				var combinedInvalid = buildResult.invalidPaths
				// Include codemapUnavailable messages for display
				for msg in buildResult.codemapUnavailable where !combinedInvalid.contains(msg) {
					combinedInvalid.append(msg)
				}
				for error in extraInvalid where !combinedInvalid.contains(error) {
					combinedInvalid.append(error)
				}

				// Build a non-mutating preview reply with status "preview"
				// Context builder runs use .auto for normalized view; regular tab-bound connections use user's setting
				let previewCodeMapOverride: CodeMapUsage? = context.runID != nil ? .auto : nil
				let collections = await owner.tabSelectionCollections(from: previewSelectionFinal, codeMapUsageOverride: previewCodeMapOverride)
				let formatter = MCPServerViewModel.PathFormatter(format: display, owner: owner)
				let tokens = MCPServerViewModel.TokenServices(owner: owner)
				var previewReply = await MCPServerViewModel.SelectionReplyAssembler.buildSelectionReply(
					collections: collections,
					includeBlocks: includeBlocks,
					display: display,
					formatter: formatter,
					tokens: tokens,
					status: "preview",
					extraInvalid: combinedInvalid
				)

				// Strict handling: require at least some files/slices to resolve
				if strict {
					let resolvedAny = setPlan.usesFileScopedSliceReplacement
						? previewInputResolved
						: ((previewReply.files?.isEmpty == false) || (previewReply.fileSlices?.isEmpty == false))
					if !resolvedAny {
						var hintInputs = rawPaths
						let slicePaths = sliceInputs.map { $0.path }
						if hintInputs.isEmpty {
							hintInputs = slicePaths
						} else {
							for candidate in slicePaths where !hintInputs.contains(candidate) {
								hintInputs.append(candidate)
							}
						}
						let hint = await owner.makeSelectionHintError(
							paths: hintInputs,
							operation: "preview",
							lookupRootScope: lookupRootScope
						)
						throw MCPError.invalidParams(hint)
					}
				}

				// Apply optional view filter
				if view == "codemaps" {
					previewReply = MCPServerViewModel.SelectionReplyAssembler.applyViewFilter(previewReply, view: "codemaps")
				}
				return previewReply
			case "set":
				var context = try await owner.requireCurrentTabContext(toolName: ToolNames.manageSelection)
				context.selection = await owner.stabilizedVirtualSelection(for: context)
				selectionLog("[Virtual] manage_selection op=set tab=\(context.tabID)")

				let setPlan = MCPServerViewModel.manageSelectionSetMutationPlan(
					mode: mode,
					pathCount: selectionPaths.count,
					sliceCount: sliceInputs.count
				)

				// Detect slice-only set operations for file-scoped replacement semantics
				let isSliceOnlySet = setPlan.usesFileScopedSliceReplacement

				var currentSelection: StoredSelection
				var combinedInvalid: [String]
				var codemapUnavailableMsgs: [String]
				if isSliceOnlySet {
					currentSelection = context.selection
					combinedInvalid = []
					codemapUnavailableMsgs = []
					if mode != "slices", !selectionPaths.isEmpty {
						let addResult = await owner.addStoredSelectionPaths(
							existing: currentSelection,
							paths: selectionPaths,
							rawPaths: rawPaths,
							mode: "full",
							lookupRootScope: lookupRootScope
						)
						currentSelection = addResult.selection
						combinedInvalid.append(contentsOf: addResult.invalidPaths)
						codemapUnavailableMsgs.append(contentsOf: addResult.codemapUnavailable)
					}
				} else {
					// Destructive set builds from the supplied paths/slices only.
					let pathOnlyInputs = MCPServerViewModel.ManageSelectionInputs(
						paths: selectionPaths,
						sliceInputs: [],
						sliceErrors: [],
						hadExplicitSliceSpec: false
					)
					let pathBuildResult = await owner.buildStoredSelection(
						from: pathOnlyInputs,
						mode: mode,
						existing: StoredSelection(selectedPaths: [], autoCodemapPaths: [], slices: [:]),
						lookupRootScope: lookupRootScope
					)
					currentSelection = pathBuildResult.selection
					combinedInvalid = pathBuildResult.invalidPaths
					codemapUnavailableMsgs = pathBuildResult.codemapUnavailable
				}

				// Apply slices using applySelectionSlices for proper semantics
				if !sliceInputs.isEmpty {
					let sliceMode: SliceMutationMode = isSliceOnlySet ? .setPaths : .set
					let sliceResult = await owner.computeSelectionSlicesVirtual(
						base: currentSelection,
						entries: sliceInputs,
						mode: sliceMode,
						lookupRootScope: lookupRootScope
					)
					currentSelection = sliceResult.selection
					combinedInvalid.append(contentsOf: sliceResult.result.invalidPaths)
				}

				for error in extraInvalid where !combinedInvalid.contains(error) {
					combinedInvalid.append(error)
				}
				// For set operations, only error on truly invalid paths (not codemapUnavailable)
				if !combinedInvalid.isEmpty {
					throw MCPError.invalidParams("Invalid selection inputs: \(combinedInvalid.joined(separator: ", "))")
				}
				// Include codemapUnavailable messages in the reply but don't throw
				for msg in codemapUnavailableMsgs where !combinedInvalid.contains(msg) {
					combinedInvalid.append(msg)
				}
				try await owner.updateCurrentTabContext(toolName: ToolNames.manageSelection) { ctx in
					ctx.selection = currentSelection
				}
				selectionLog("[Virtual] manage_selection op=set updated tab context: selected=\(currentSelection.selectedPaths.count) codemap=\(currentSelection.autoCodemapPaths.count) slices=\(currentSelection.slices.count)")
				// Context builder runs use .auto for normalized view; regular tab-bound connections use user's setting
				let setCodeMapOverride: CodeMapUsage? = context.runID != nil ? .auto : nil
				var replyContext = context
				replyContext.selection = currentSelection
				return await owner.buildTabSelectionReply(
					from: currentSelection,
					includeBlocks: includeBlocks,
					display: display,
					extraInvalid: combinedInvalid,
					viewMode: view,
					codeMapUsageOverride: setCodeMapOverride,
					virtualContext: replyContext
				)
			case "add":
				if selectionPaths.isEmpty && sliceInputs.isEmpty {
					throw MCPError.invalidParams("paths or slices required for add")
				}
				var context = try await owner.requireCurrentTabContext(toolName: ToolNames.manageSelection)
				context.selection = await owner.stabilizedVirtualSelection(for: context)
				selectionLog("[Virtual] manage_selection op=add mode=\(mode) paths=\(selectionPaths.count) slices=\(sliceInputs.count) tab=\(context.tabID)")
				var invalid: [String] = []
				var resolvedMap: [String: String] = [:]
				var pathMutated = false
				var currentSelection = context.selection

				if mode == "codemap_only" {
					if !sliceInputs.isEmpty {
						throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
					}
					var codemapUnavailableMsgs: [String] = []
					if !selectionPaths.isEmpty {
						let addResult = await owner.addStoredSelectionPaths(
							existing: currentSelection,
							paths: selectionPaths,
							rawPaths: rawPaths,
							mode: mode,
							lookupRootScope: lookupRootScope
						)
						currentSelection = addResult.selection
						invalid.append(contentsOf: addResult.invalidPaths)
						codemapUnavailableMsgs.append(contentsOf: addResult.codemapUnavailable)
						for (key, value) in addResult.resolvedMap where resolvedMap[key] == nil {
							resolvedMap[key] = value
						}
						pathMutated = addResult.mutated
					}
					if strict && !pathMutated && resolvedMap.isEmpty {
						throw MCPError.invalidParams(await owner.makeSelectionHintError(paths: rawPaths, operation: "add", lookupRootScope: lookupRootScope))
					}
					var combinedInvalid = invalid
					for error in extraInvalid where !combinedInvalid.contains(error) {
						combinedInvalid.append(error)
					}
					for error in sliceParseErrors where !combinedInvalid.contains(error) {
						combinedInvalid.append(error)
					}
					// Include codemapUnavailable messages for display
					for msg in codemapUnavailableMsgs where !combinedInvalid.contains(msg) {
						combinedInvalid.append(msg)
					}
					try await owner.updateCurrentTabContext(toolName: ToolNames.manageSelection) { ctx in
						ctx.selection = currentSelection
					}
					// Context builder runs use .auto for normalized view; regular tab-bound connections use user's setting
					let addCodemapOnlyOverride: CodeMapUsage? = context.runID != nil ? .auto : nil
					var replyContext = context
					replyContext.selection = currentSelection
					return await owner.buildTabSelectionReply(
						from: currentSelection,
						includeBlocks: includeBlocks,
						display: display,
						extraInvalid: combinedInvalid,
						viewMode: view,
						codeMapUsageOverride: addCodemapOnlyOverride,
						virtualContext: replyContext
					)
				}

				// Normal add (full/slices)
				if !selectionPaths.isEmpty {
					let addResult = await owner.addStoredSelectionPaths(
						existing: currentSelection,
						paths: selectionPaths,
						rawPaths: rawPaths,
						mode: mode,
						lookupRootScope: lookupRootScope
					)
					currentSelection = addResult.selection
					invalid.append(contentsOf: addResult.invalidPaths)
					for (key, value) in addResult.resolvedMap where resolvedMap[key] == nil {
						resolvedMap[key] = value
					}
					pathMutated = addResult.mutated
				}

				// Merge slices into the virtual selection using applySelectionSlices
				var sliceResolved = false
				var sliceMutated = false
				var sliceInvalid = false
				if !sliceInputs.isEmpty {
					let sliceResult = await owner.computeSelectionSlicesVirtual(
						base: currentSelection,
						entries: sliceInputs,
						mode: .add,
						lookupRootScope: lookupRootScope
					)
					currentSelection = sliceResult.selection
					invalid.append(contentsOf: sliceResult.result.invalidPaths)
					sliceResolved = !sliceResult.result.resolvedMap.isEmpty
					sliceMutated = sliceResult.mutated
					sliceInvalid = !sliceResult.result.invalidPaths.isEmpty
				} else if parsedInputs.hadExplicitSliceSpec && strict {
					let detail = sliceParseErrors.isEmpty ? "No valid slices parsed from provided specification" : sliceParseErrors.joined(separator: "; ")
					throw MCPError.invalidParams(detail)
				}

				let resolvedAnything = pathMutated || !resolvedMap.isEmpty || sliceResolved || sliceMutated
				if strict && !resolvedAnything {
					if !selectionPaths.isEmpty {
						throw MCPError.invalidParams(await owner.makeSelectionHintError(paths: rawPaths, operation: "add", lookupRootScope: lookupRootScope))
					} else if !sliceInvalid {
						throw MCPError.invalidParams("Provided slices did not match any files")
					}
				}

				// Persist and reply from the new virtual selection
				try await owner.updateCurrentTabContext(toolName: ToolNames.manageSelection) { ctx in
					ctx.selection = currentSelection
				}
				selectionLog("[Virtual] manage_selection op=add updated tab context: selected=\(currentSelection.selectedPaths.count) codemap=\(currentSelection.autoCodemapPaths.count) slices=\(currentSelection.slices.count)")
				var combinedInvalid = invalid
				for error in extraInvalid where !combinedInvalid.contains(error) {
					combinedInvalid.append(error)
				}
				for error in sliceParseErrors where !combinedInvalid.contains(error) {
					combinedInvalid.append(error)
				}
				// Context builder runs use .auto for normalized view; regular tab-bound connections use user's setting
				let addCodeMapOverride: CodeMapUsage? = context.runID != nil ? .auto : nil
				var replyContext = context
				replyContext.selection = currentSelection
				return await owner.buildTabSelectionReply(
					from: currentSelection,
					includeBlocks: includeBlocks,
					display: display,
					extraInvalid: combinedInvalid,
					viewMode: view,
					codeMapUsageOverride: addCodeMapOverride,
					virtualContext: replyContext
				)
			case "remove":
				if selectionPaths.isEmpty && sliceInputs.isEmpty {
					throw MCPError.invalidParams("paths or slices required for remove")
				}
				if mode == "codemap_only" && !sliceInputs.isEmpty {
					throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
				}
				var context = try await owner.requireCurrentTabContext(toolName: ToolNames.manageSelection)
				context.selection = await owner.stabilizedVirtualSelection(for: context)
				selectionLog("[Virtual] manage_selection op=remove mode=\(mode) paths=\(selectionPaths.count) slices=\(sliceInputs.count) tab=\(context.tabID)")
				var invalid: [String] = []
				var resolvedMap: [String: String] = [:]
				var pathMutated = false
				var currentSelection = context.selection

				if !selectionPaths.isEmpty {
					let (updatedSelection, removeInvalid, removeResolved, removeMutated) = await owner.removeStoredSelectionPaths(
						existing: currentSelection,
						paths: selectionPaths,
						rawPaths: rawPaths,
						mode: mode,
						lookupRootScope: lookupRootScope
					)
					currentSelection = updatedSelection
					invalid.append(contentsOf: removeInvalid)
					for (key, value) in removeResolved where resolvedMap[key] == nil {
						resolvedMap[key] = value
					}
					pathMutated = removeMutated
				}

				var sliceResolved = false
				var sliceMutated = false
				var sliceInvalid = false
				if !sliceInputs.isEmpty {
					let sliceResult = await owner.computeSelectionSlicesVirtual(
						base: currentSelection,
						entries: sliceInputs,
						mode: .remove,
						lookupRootScope: lookupRootScope
					)
					currentSelection = sliceResult.selection
					invalid.append(contentsOf: sliceResult.result.invalidPaths)
					sliceResolved = !sliceResult.result.resolvedMap.isEmpty
					sliceMutated = sliceResult.mutated
					sliceInvalid = !sliceResult.result.invalidPaths.isEmpty
					let resolvedAnything = pathMutated || !resolvedMap.isEmpty || sliceResolved || sliceMutated
					if strict && !resolvedAnything && !sliceInvalid {
						throw MCPError.invalidParams("Provided slices did not match any files")
					}
				} else if parsedInputs.hadExplicitSliceSpec && strict {
					let detail = sliceParseErrors.isEmpty ? "No valid slices parsed from provided specification" : sliceParseErrors.joined(separator: "; ")
					throw MCPError.invalidParams(detail)
				}

				let resolvedAnything = pathMutated || !resolvedMap.isEmpty || sliceResolved || sliceMutated
				if strict && !resolvedAnything && !selectionPaths.isEmpty {
					throw MCPError.invalidParams(await owner.makeSelectionHintError(paths: rawPaths, operation: "remove", lookupRootScope: lookupRootScope))
				}

				try await owner.updateCurrentTabContext(toolName: ToolNames.manageSelection) { ctx in
					ctx.selection = currentSelection
				}
				selectionLog("[Virtual] manage_selection op=remove updated tab context: selected=\(currentSelection.selectedPaths.count) codemap=\(currentSelection.autoCodemapPaths.count) slices=\(currentSelection.slices.count)")
				var combinedInvalid = invalid
				for error in extraInvalid where !combinedInvalid.contains(error) {
					combinedInvalid.append(error)
				}
				for error in sliceParseErrors where !combinedInvalid.contains(error) {
					combinedInvalid.append(error)
				}
				// Context builder runs use .auto for normalized view; regular tab-bound connections use user's setting
				let removeCodeMapOverride: CodeMapUsage? = context.runID != nil ? .auto : nil
				var replyContext = context
				replyContext.selection = currentSelection
				return await owner.buildTabSelectionReply(
					from: currentSelection,
					includeBlocks: includeBlocks,
					display: display,
					extraInvalid: combinedInvalid,
					viewMode: view,
					codeMapUsageOverride: removeCodeMapOverride,
					virtualContext: replyContext
				)
			case "promote":
				var context = try await owner.requireCurrentTabContext(toolName: ToolNames.manageSelection)
				context.selection = await owner.stabilizedVirtualSelection(for: context)
				selectionLog("[Virtual] manage_selection op=promote paths=\(selectionPaths.count) tab=\(context.tabID)")
				if selectionPaths.isEmpty {
					throw MCPError.invalidParams("paths required for promote")
				}
				if !sliceInputs.isEmpty {
					throw MCPError.invalidParams("promote does not support slices")
				}
				let (newSelection, invalid, mutated) = await owner.promoteStoredSelectionPaths(
					existing: context.selection,
					paths: selectionPaths,
					rawPaths: rawPaths,
					strict: strict,
					lookupRootScope: lookupRootScope
				)
				var combinedInvalid = invalid
				for error in extraInvalid where !combinedInvalid.contains(error) {
					combinedInvalid.append(error)
				}
				if strict && !mutated {
					throw MCPError.invalidParams(await owner.makeSelectionHintError(paths: rawPaths, operation: "promote", lookupRootScope: lookupRootScope))
				}
				try await owner.updateCurrentTabContext(toolName: ToolNames.manageSelection) { ctx in
					ctx.selection = newSelection
				}
				selectionLog("[Virtual] manage_selection op=promote updated tab context: selected=\(newSelection.selectedPaths.count) codemap=\(newSelection.autoCodemapPaths.count) mutated=\(mutated)")
				// Context builder runs use .auto for normalized view; regular tab-bound connections use user's setting
				let promoteCodeMapOverride: CodeMapUsage? = context.runID != nil ? .auto : nil
				var replyContext = context
				replyContext.selection = newSelection
				return await owner.buildTabSelectionReply(
					from: newSelection,
					includeBlocks: includeBlocks,
					display: display,
					extraInvalid: combinedInvalid,
					viewMode: view,
					codeMapUsageOverride: promoteCodeMapOverride,
					virtualContext: replyContext
				)
			case "demote":
				var context = try await owner.requireCurrentTabContext(toolName: ToolNames.manageSelection)
				context.selection = await owner.stabilizedVirtualSelection(for: context)
				selectionLog("[Virtual] manage_selection op=demote paths=\(selectionPaths.count) tab=\(context.tabID)")
				if selectionPaths.isEmpty {
					throw MCPError.invalidParams("paths required for demote")
				}
				if !sliceInputs.isEmpty {
					throw MCPError.invalidParams("demote does not support slices")
				}
				let demoteResult = await owner.demoteStoredSelectionPaths(
					existing: context.selection,
					paths: selectionPaths,
					rawPaths: rawPaths,
					strict: strict,
					lookupRootScope: lookupRootScope
				)
				var combinedInvalid = demoteResult.invalidPaths
				for error in extraInvalid where !combinedInvalid.contains(error) {
					combinedInvalid.append(error)
				}
				// Include codemapUnavailable messages for display
				for msg in demoteResult.codemapUnavailable where !combinedInvalid.contains(msg) {
					combinedInvalid.append(msg)
				}
				if strict && !demoteResult.mutated {
					throw MCPError.invalidParams(await owner.makeSelectionHintError(paths: rawPaths, operation: "demote", lookupRootScope: lookupRootScope))
				}
				try await owner.updateCurrentTabContext(toolName: ToolNames.manageSelection) { ctx in
					ctx.selection = demoteResult.selection
				}
				selectionLog("[Virtual] manage_selection op=demote updated tab context: selected=\(demoteResult.selection.selectedPaths.count) codemap=\(demoteResult.selection.autoCodemapPaths.count) mutated=\(demoteResult.mutated)")
				// Context builder runs use .auto for normalized view; regular tab-bound connections use user's setting
				let demoteCodeMapOverride: CodeMapUsage? = context.runID != nil ? .auto : nil
				var replyContext = context
				replyContext.selection = demoteResult.selection
				return await owner.buildTabSelectionReply(
					from: demoteResult.selection,
					includeBlocks: includeBlocks,
					display: display,
					extraInvalid: combinedInvalid,
					viewMode: view,
					codeMapUsageOverride: demoteCodeMapOverride,
					virtualContext: replyContext
				)
			case "clear":
				var baseContext = try await owner.requireCurrentTabContext(toolName: ToolNames.manageSelection)
				baseContext.selection = await owner.stabilizedVirtualSelection(for: baseContext)
				selectionLog("[Virtual] manage_selection op=clear mode=\(mode) tab=\(baseContext.tabID)")
				let clearedSelection: StoredSelection
				if mode == "codemap_only" {
					let current = baseContext.selection
					clearedSelection = StoredSelection(
						selectedPaths: current.selectedPaths,
						autoCodemapPaths: [],
						slices: current.slices,
						codemapAutoEnabled: false
					)
				} else {
					clearedSelection = StoredSelection()
				}
				try await owner.updateCurrentTabContext(toolName: ToolNames.manageSelection) { ctx in
					ctx.selection = clearedSelection
				}
				selectionLog("[Virtual] manage_selection op=clear updated tab context: selected=\(clearedSelection.selectedPaths.count) codemap=\(clearedSelection.autoCodemapPaths.count)")
				// Context builder runs use .auto for normalized view; regular tab-bound connections use user's setting
				let clearCodeMapOverride: CodeMapUsage? = baseContext.runID != nil ? .auto : nil
				var replyContext = baseContext
				replyContext.selection = clearedSelection
				return await owner.buildTabSelectionReply(
					from: clearedSelection,
					includeBlocks: includeBlocks,
					display: display,
					extraInvalid: extraInvalid,
					viewMode: view,
					codeMapUsageOverride: clearCodeMapOverride,
					virtualContext: replyContext
				)
			default:
				throw MCPError.invalidParams("Unsupported op '\(op)' for manage_selection when tab context is active")
			}
		}

		switch op {
		case "get":
			let invalid = sliceParseErrors.isEmpty ? [] : sliceParseErrors
			if needsTokenRefresh {
				await owner.fileManager.flushAutoCodemapSyncNowIfNeeded()
				await owner.refreshSelectionMetrics()
			}
			return await owner.buildCurrentSelectionReply(
				includeBlocks: includeBlocks,
				display: display,
				extraInvalid: invalid,
				viewMode: view,
				execContext: execContext
			)
		case "add":
			if selectionPaths.isEmpty && sliceInputs.isEmpty {
				throw MCPError.invalidParams("paths or slices required for add")
			}
			var invalid: [String] = []

			// Handle codemap_only mode
			if mode == "codemap_only" {
				if !sliceInputs.isEmpty {
					throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
				}
				if !selectionPaths.isEmpty {
					let addResult = try await owner.applyCodemapAdd(paths: selectionPaths, rawPaths: rawPaths, strict: strict)
					if addResult.mutated {
						needsTokenRefresh = true
					}
					invalid.append(contentsOf: addResult.invalidPaths)
					// Include codemapUnavailable messages for display
					invalid.append(contentsOf: addResult.codemapUnavailable)
				}
			} else {
				// Normal add (full content or slices)
				if !selectionPaths.isEmpty {
					let result = await owner.fileManager.selectPaths(withPaths: selectionPaths, clear: false, expandFolders: true, exact: false)
					needsTokenRefresh = true
					if strict && result.addedFiles.isEmpty && result.resolvedMap.isEmpty {
						throw MCPError.invalidParams(await owner.makeSelectionHintError(paths: rawPaths, operation: "add"))
					}
					invalid.append(contentsOf: result.invalidPaths)
				}
				if !sliceInputs.isEmpty {
					let sliceResult = try await owner.applySelectionSlices(entries: sliceInputs, mode: .add)
					needsTokenRefresh = true
					if strict && sliceResult.resolvedMap.isEmpty && sliceResult.invalidPaths.isEmpty {
						throw MCPError.invalidParams("Provided slices did not match any files")
					}
					invalid.append(contentsOf: sliceResult.invalidPaths)
				} else if parsedInputs.hadExplicitSliceSpec && strict {
					let detail = sliceParseErrors.isEmpty ? "No valid slices parsed from provided specification" : sliceParseErrors.joined(separator: "; ")
					throw MCPError.invalidParams(detail)
				}
			}
			invalid.append(contentsOf: sliceParseErrors)
			if needsTokenRefresh {
				await owner.fileManager.flushAutoCodemapSyncNowIfNeeded()
				await owner.refreshSelectionMetrics()
			}
			return await owner.buildCurrentSelectionReply(
				includeBlocks: includeBlocks,
				display: display,
				extraInvalid: invalid,
				viewMode: view,
				execContext: execContext
			)
		case "promote":
			if selectionPaths.isEmpty {
				throw MCPError.invalidParams("paths required for promote")
			}
			if !sliceInputs.isEmpty {
				throw MCPError.invalidParams("promote does not support slices")
			}
			var invalid = try await owner.promoteSelectionPaths(selectionPaths, rawPaths: rawPaths, strict: strict)
			needsTokenRefresh = true
			invalid.append(contentsOf: sliceParseErrors)
			if needsTokenRefresh {
				await owner.fileManager.flushAutoCodemapSyncNowIfNeeded()
				await owner.refreshSelectionMetrics()
			}
			return await owner.buildCurrentSelectionReply(
				includeBlocks: includeBlocks,
				display: display,
				extraInvalid: invalid,
				viewMode: view,
				execContext: execContext
			)
		case "demote":
			if selectionPaths.isEmpty {
				throw MCPError.invalidParams("paths required for demote")
			}
			if !sliceInputs.isEmpty {
				throw MCPError.invalidParams("demote does not support slices")
			}
			var invalid = try await owner.demoteSelectionPaths(selectionPaths, rawPaths: rawPaths, strict: strict)
			needsTokenRefresh = true
			invalid.append(contentsOf: sliceParseErrors)
			if needsTokenRefresh {
				await owner.fileManager.flushAutoCodemapSyncNowIfNeeded()
				await owner.refreshSelectionMetrics()
			}
			return await owner.buildCurrentSelectionReply(
				includeBlocks: includeBlocks,
				display: display,
				extraInvalid: invalid,
				viewMode: view,
				execContext: execContext
			)
		case "remove":
			if selectionPaths.isEmpty && sliceInputs.isEmpty {
				throw MCPError.invalidParams("paths or slices required for remove")
			}
			var invalid: [String] = []
			if mode == "codemap_only" {
				if !sliceInputs.isEmpty {
					throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
				}
				if !selectionPaths.isEmpty {
					// Use folder-aware resolver that enters manual mode and filters by codemap support
					let removeResult = try await owner.applyCodemapRemove(
						paths: selectionPaths,
						rawPaths: rawPaths,
						strict: strict
					)
					invalid.append(contentsOf: removeResult.invalidPaths)
					invalid.append(contentsOf: removeResult.codemapUnavailable)
					needsTokenRefresh = removeResult.mutated
				}
			} else {
				if !selectionPaths.isEmpty {
					let result = await owner.fileManager.deselectPaths(withPaths: selectionPaths, expandFolders: true, exact: false)
					needsTokenRefresh = true
					if strict && result.removedFiles.isEmpty && result.resolvedMap.isEmpty {
						throw MCPError.invalidParams(await owner.makeSelectionHintError(paths: rawPaths, operation: "remove"))
					}
					invalid.append(contentsOf: result.invalidPaths)

					// Also remove from autoCodemapFiles
					let resolvedFiles = await owner.fileManager.findFiles(atPaths: selectionPaths)
					for file in resolvedFiles.values {
						await owner.fileManager.removeCodemapFile(file)
					}
				}
			}
			if !sliceInputs.isEmpty {
				let sliceResult = try await owner.applySelectionSlices(entries: sliceInputs, mode: .remove)
				needsTokenRefresh = true
				if strict && sliceResult.resolvedMap.isEmpty && sliceResult.invalidPaths.isEmpty {
					throw MCPError.invalidParams("Provided slices did not match any files")
				}
				invalid.append(contentsOf: sliceResult.invalidPaths)
			} else if parsedInputs.hadExplicitSliceSpec && strict {
				let detail = sliceParseErrors.isEmpty ? "No valid slices parsed from provided specification" : sliceParseErrors.joined(separator: "; ")
				throw MCPError.invalidParams(detail)
			}
			invalid.append(contentsOf: sliceParseErrors)
			if needsTokenRefresh {
				await owner.fileManager.flushAutoCodemapSyncNowIfNeeded()
				await owner.refreshSelectionMetrics()
			}
			return await owner.buildCurrentSelectionReply(
				includeBlocks: includeBlocks,
				display: display,
				extraInvalid: invalid,
				viewMode: view,
				execContext: execContext
			)
		case "set":
			if selectionPaths.isEmpty && sliceInputs.isEmpty {
				throw MCPError.invalidParams("paths or slices required for set")
			}

			let setPlan = MCPServerViewModel.manageSelectionSetMutationPlan(
				mode: mode,
				pathCount: selectionPaths.count,
				sliceCount: sliceInputs.count
			)

			// Detect slice-only set operations for file-scoped replacement semantics
			let isSliceOnlySet = setPlan.usesFileScopedSliceReplacement

			// Pre-validate all paths before clearing to prevent clearing selection if any paths are invalid
			var prevalidationInvalid: [String] = []
			prevalidationInvalid.append(contentsOf: sliceParseErrors)

			// Use folder-aware validation for paths (supports directories that expand to files)
			if !selectionPaths.isEmpty {
				let pathInvalid = await owner.validateManageSelectionSetInputs(
					paths: selectionPaths,
					rawPaths: rawPaths,
					expandFolders: true
				)
				prevalidationInvalid.append(contentsOf: pathInvalid)
			}

			// Slices must target files only (no folder expansion)
			if !sliceInputs.isEmpty {
				let slicePaths = sliceInputs.map { $0.path }
				let resolved = await owner.selectionFindFiles(atPaths: slicePaths)
				for path in slicePaths {
					let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
					if !trimmed.isEmpty && resolved[trimmed] == nil {
						prevalidationInvalid.append(trimmed)
					}
				}
			}

			// For set operations, error on ANY invalid paths to prevent clearing the selection
			if !prevalidationInvalid.isEmpty {
				throw MCPError.invalidParams("Invalid selection inputs: \(prevalidationInvalid.joined(separator: ", "))")
			}

			var invalid: [String] = []
			if mode == "codemap_only" {
				if !sliceInputs.isEmpty {
					throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
				}
				await owner.fileManager.clearAutoCodemapFiles()
				if !selectionPaths.isEmpty {
					let addResult = try await owner.applyCodemapAdd(paths: selectionPaths, rawPaths: rawPaths, strict: strict)
					if addResult.mutated {
						needsTokenRefresh = true
					}
					invalid.append(contentsOf: addResult.invalidPaths)
					// Include codemapUnavailable messages for display
					invalid.append(contentsOf: addResult.codemapUnavailable)
				} else {
					needsTokenRefresh = true
				}
			} else {
				if mode != "slices", !selectionPaths.isEmpty {
					let result = await owner.fileManager.selectPaths(withPaths: selectionPaths, clear: !isSliceOnlySet, expandFolders: true, exact: false)
					needsTokenRefresh = true
					if strict && result.addedFiles.isEmpty && result.resolvedMap.isEmpty {
						throw MCPError.invalidParams(await owner.makeSelectionHintError(paths: rawPaths, operation: "set"))
					}
					invalid.append(contentsOf: result.invalidPaths)
				}
			}
			if !sliceInputs.isEmpty {
				let sliceMode: SliceMutationMode = isSliceOnlySet ? .setPaths : .set
				let sliceResult = try await owner.applySelectionSlices(entries: sliceInputs, mode: sliceMode)
				needsTokenRefresh = true
				if strict && sliceResult.resolvedMap.isEmpty && sliceResult.invalidPaths.isEmpty {
					throw MCPError.invalidParams("Provided slices did not match any files")
				}
				invalid.append(contentsOf: sliceResult.invalidPaths)
			} else if parsedInputs.hadExplicitSliceSpec && strict {
				let detail = sliceParseErrors.isEmpty ? "No valid slices parsed from provided specification" : sliceParseErrors.joined(separator: "; ")
				throw MCPError.invalidParams(detail)
			}
			invalid.append(contentsOf: sliceParseErrors)
			if needsTokenRefresh {
				await owner.fileManager.flushAutoCodemapSyncNowIfNeeded()
				await owner.refreshSelectionMetrics()
			}
			return await owner.buildCurrentSelectionReply(
				includeBlocks: includeBlocks,
				display: display,
				extraInvalid: invalid,
				viewMode: view,
				execContext: execContext
			)
		case "preview":
			if selectionPaths.isEmpty && sliceInputs.isEmpty {
				throw MCPError.invalidParams("paths or slices required for preview")
			}
			if mode == "codemap_only" {
				if !sliceInputs.isEmpty {
					throw MCPError.invalidParams("mode 'codemap_only' cannot be used with slices")
				}
			}
			let previewSetPlan = MCPServerViewModel.manageSelectionSetMutationPlan(
				mode: mode,
				pathCount: selectionPaths.count,
				sliceCount: sliceInputs.count
			)
			let fileScopedPreviewInputResolved: Bool
			if previewSetPlan.usesFileScopedSliceReplacement {
				let sliceFiles = await owner.selectionFindFiles(
					atPaths: sliceInputs.map { $0.path },
					lookupRootScope: lookupRootScope
				)
				fileScopedPreviewInputResolved = !sliceFiles.isEmpty
			} else {
				fileScopedPreviewInputResolved = false
			}
			let previewReply = await owner.buildPreviewSelectionReply(
				paths: mode == "slices" ? [] : selectionPaths,
				sliceInputs: sliceInputs,
				includeBlocks: includeBlocks,
				display: display,
				mode: mode,
				baseSelection: owner.currentLiveStoredSelection(),
				lookupRootScope: lookupRootScope
			)
			var combinedInvalid = previewReply.invalidPaths ?? []
			for error in sliceParseErrors {
				if !combinedInvalid.contains(error) {
					combinedInvalid.append(error)
				}
			}
			if strict {
				let resolvedAny = previewSetPlan.usesFileScopedSliceReplacement
					? fileScopedPreviewInputResolved
					: ((previewReply.files?.isEmpty == false) || (previewReply.fileSlices?.isEmpty == false))
				if !resolvedAny {
					var hintInputs = rawPaths
					let slicePaths = sliceInputs.map { $0.path }
					if hintInputs.isEmpty {
						hintInputs = slicePaths
					} else {
						for candidate in slicePaths where !hintInputs.contains(candidate) {
							hintInputs.append(candidate)
						}
					}
					let hint = await owner.makeSelectionHintError(paths: hintInputs, operation: "preview", lookupRootScope: lookupRootScope)
					throw MCPError.invalidParams(hint)
				}
			}
			var out = ToolResultDTOs.SelectionReply(
				files: previewReply.files,
				totalTokens: previewReply.totalTokens,
				status: previewReply.status,
				invalidPaths: combinedInvalid.isEmpty ? nil : combinedInvalid,
				blocks: previewReply.blocks,
				codeStructure: previewReply.codeStructure,
				fileSlices: previewReply.fileSlices,
				codemapAutoEnabled: previewReply.codemapAutoEnabled,
				summary: previewReply.summary,
				codeMapUsage: previewReply.codeMapUsage,
				// Preserve user preset state indicators
				userCopyCodeMapUsage: previewReply.userCopyCodeMapUsage,
				userChatCodeMapUsage: previewReply.userChatCodeMapUsage,
				userCopyTokens: previewReply.userCopyTokens,
				userChatTokens: previewReply.userChatTokens,
				normalizedCodeMapUsage: previewReply.normalizedCodeMapUsage,
				tokenStats: previewReply.tokenStats
			)
			if view == "codemaps" {
				out = MCPServerViewModel.SelectionReplyAssembler.applyViewFilter(out, view: "codemaps")
			}
			return out
		case "clear":
			if mode == "codemap_only" {
				await owner.fileManager.clearAutoCodemapFiles()
				await owner.fileManager.enterManualCodemapMode()
				needsTokenRefresh = true
				if needsTokenRefresh {
					await owner.fileManager.flushAutoCodemapSyncNowIfNeeded()
					await owner.refreshSelectionMetrics()
				}
				return await owner.buildCurrentSelectionReply(
					includeBlocks: includeBlocks,
					display: display,
					extraInvalid: [],
					viewMode: view,
					execContext: execContext
				)
			}
			await owner.fileManager.clearSelection()
			needsTokenRefresh = true
			if needsTokenRefresh {
				await owner.fileManager.flushAutoCodemapSyncNowIfNeeded()
				await owner.refreshSelectionMetrics()
			}
			return await owner.buildCurrentSelectionReply(
				includeBlocks: includeBlocks,
				display: display,
				extraInvalid: [],
				viewMode: view,
				execContext: execContext
			)
		default:
			throw MCPError.invalidParams("invalid op: \(op)")
		}
		},

		// ───────────  file_actions  ───────────
		weakTool(
			name: ToolNames.fileActions,
			description: """
Create, delete, or move files.

**Always use absolute paths** for every `path` / `new_path` argument.

**Actions**:
- `create`: Create file with `content`. New files are auto-selected.
  - `if_exists`: "error" (default) | "overwrite"
- `delete`: Move file or folder to the macOS Trash. Recoverable from Finder Trash until emptied.
- `move`: Rename/move to `new_path`. Fails if destination exists. Selection state transfers with file.

**Path handling**:
- Absolute paths only for `path` and `new_path`.
- Missing parent directories are created automatically.

**Examples**:
- Create: `{"action":"create","path":"/Users/me/project/src/new.swift","content":"// code"}`
- Overwrite: `{"action":"create","path":"/Users/me/project/src/file.swift","content":"// new","if_exists":"overwrite"}`
- Delete: `{"action":"delete","path":"/Users/me/project/old.swift"}` moves the item to Trash.
- Move: `{"action":"move","path":"/Users/me/project/old.swift","new_path":"/Users/me/project/renamed.swift"}`
""",
			annotations: .repoPromptLocalDestructive,
			inputSchema: .object(
				properties: [
					"action": .string(
						description: "Operation to perform",
						enum: ["create", "delete", "move"]
					),
					"path": .string(description: "File path"),
					"content": .string(description: "File content (for create)"),
					"new_path": .string(description: "New path (for move)"),
					"if_exists": .string(
						description: "Behavior if the file already exists (for create)",
						enum: ["error", "overwrite"]
					)
				],
				required: ["action", "path"]
			)
		) { owner, args in
			guard
				let action = args["action"]?.stringValue,
				let path = args["path"]?.stringValue
			else { throw MCPError.invalidParams("missing required fields") }

			let content = args["content"]?.stringValue
			let newPath = args["new_path"]?.stringValue
			let ifExists = args["if_exists"]?.stringValue?.lowercased() ?? "error"

			try await owner.performFileAction(
				action: action,
				path: path,
				content: content,
				newPath: newPath,
				ifExists: ifExists
			)
			return ToolResultDTOs.FileActionReply(
				status: "ok",
				action: action,
				path: path,
				newPath: newPath
			)
		},


		// ───────────  get_code_structure  ───────────
		weakTool(
			name: ToolNames.getCodeStructure,
			description: """
Return code structure (function/type signatures) for files.

**Scopes**:
- `paths` (default): Analyze specific files/directories. Requires `paths` parameter.
- `selected`: Analyze current selection. Also reports files without codemaps.

**Parameters**:
- `paths`: File or directory paths (directories are recursive)
- `max_results`: Limit considered codemaps (default: 10). Larger values opt in to broader scans.

**Note**: Files without parseable structure are skipped. Use with get_file_tree and file_search for discovery.
Rendered codemap output is capped near 6k tokens even when `max_results` is larger; narrow `paths` to change which files fit.
Line numbers are included in the output and match `read_file` line numbering, so you can jump directly to where a function/type is declared within a file. Code structure is refreshed after file edits, so results stay current.

**Examples**:
- Specific files: `{"paths":["src/auth/"]}`
- Current selection: `{"scope":"selected"}`
""",
			annotations: .repoPromptLocalReadOnly,
			inputSchema: .object(
				properties: [
					"scope": .string(
						description: "Scope of operation: current selection or explicit paths",
						enum: ["paths", "selected"]
					),
					"paths": .array(
						description: "Array of file or directory paths (when scope='paths')",
						items: .string(description: "File path or directory path (absolute or relative)")
					),
					"max_results": .integer(
						description: "Maximum number of codemaps to consider before the ~6k-token response cap is applied (default: 10)"
					)
				],
				required: []
			)
		) { owner, args in
			if await owner.codeMapsGloballyDisabledForMCP {
				throw MCPError.invalidParams(Self.codeMapsGloballyDisabledMCPMessage)
			}
			let scope = (args["scope"]?.stringValue ?? "paths").lowercased()
			let maxResults = max(0, args["max_results"]?.intValue ?? Self.defaultCodeStructureMaxResults)

			switch scope {
			case "selected":
				let collections = await owner.selectionCollectionsForCurrentExecContext()
				var combined: [FileViewModel] = []
				var seenPaths = Set<String>()
				for entry in collections.selected {
					let abs = entry.file.standardizedFullPath
					if seenPaths.insert(abs).inserted {
						combined.append(entry.file)
					}
				}
				for entry in collections.codemap {
					let abs = entry.file.standardizedFullPath
					if seenPaths.insert(abs).inserted {
						combined.append(entry.file)
					}
				}
				return await owner.buildCodeStructureDTO(
					from: combined,
					maxResults: maxResults,
					includeUnmappedPaths: true
				)
			default:
				guard let rawPaths = args["paths"]?.arrayValue else {
					throw MCPError.invalidParams("missing paths (required when scope='paths')")
				}
				let paths = rawPaths.compactMap { $0.stringValue }
				guard !paths.isEmpty else {
					throw MCPError.invalidParams("paths array cannot be empty")
				}
				let metadata = await owner.captureRequestMetadata()
				let lookupRootScope = await owner.resolveFileToolLookupRootScope(from: metadata)
				for path in paths {
					if let issue = await owner.fileManager.exactPathResolutionIssue(for: path, kind: .either, rootScope: lookupRootScope) {
						throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
					}
				}
				let resolvedFiles = await owner.resolveFilesForCodeStructure(paths: paths, lookupRootScope: lookupRootScope)
				return await owner.buildCodeStructureDTO(
					from: resolvedFiles,
					maxResults: maxResults,
					includeUnmappedPaths: false
				)
			}
		},


		// ───────────  get_file_tree  ───────────
		weakTool(
			name: ToolNames.getFileTree,
			description: """
Generate ASCII directory tree of the project.

**Types**:
- `files` (default): Directory tree with files
- `roots`: List loaded root folders only

**Modes** (for type="files"):
- `auto` (default): Full tree, auto-trims depth if too large (~10k token target)
- `full`: Complete tree (can be very large)
- `folders`: Directories only, no files
- `selected`: Only selected files and their parent directories

**Options**:
- `path`: Start from specific folder (modes/max_depth apply from there)
- `max_depth`: Limit depth (root=0, immediate children=1, etc.)

**Markers**: `*` = selected file, `+` = has codemap

**Examples**:
- Auto tree: `{}`
- Folders only: `{"mode":"folders"}`
- Subtree: `{"path":"src/components","max_depth":2}`
- Selected files: `{"mode":"selected"}`
""",
			annotations: .repoPromptLocalReadOnly,
			inputSchema: .object(
				properties: [
					"type": .string(
						description: "Tree type to generate (default: 'files')",
						enum: ["files", "roots"]
					),
					"mode": .string(
						description: "Filter mode (for 'files' type only, default: 'auto')",
						enum: ["auto", "full", "folders", "selected"]
					),
					"max_depth": .integer(description: "Maximum depth (root = 0)"),
					"path": .string(description: "Optional starting folder (absolute or relative) when type='files'. When provided, the tree is generated from this folder and 'mode' and 'max_depth' apply from that subtree.")
				],
				required: []
			)
		) { owner, args in
			let type = args["type"]?.stringValue ?? "files"

			switch type {
			case "roots":
				let roots = await MainActor.run { owner.fileManager.visibleRootFolders }
				if roots.isEmpty {
					let msg = await owner.workspaceContextMessage(forOperation: ToolNames.getFileTree, path: nil)
					return ToolResultDTOs.FileTreeDTO(
						rootsCount: 0,
						usesLegend: false,
						tree: msg,
						note: "No workspace loaded",
						wasTruncated: false
					)
				}
				let list = roots.map(\.fullPath).joined(separator: "\n")
				return ToolResultDTOs.FileTreeDTO(
					rootsCount: roots.count,
					usesLegend: false,
					tree: list,
					note: nil,
					wasTruncated: false
				)

			case "files":
						let mode = args["mode"]?.stringValue ?? "auto"
						// Only accept integer values for max_depth (no string coercion)
						let maxDepth: Int?
						if let maxDepthArg = args["max_depth"] {
							if let intVal = maxDepthArg.intValue {
								maxDepth = intVal
							} else {
								throw MCPError.invalidParams("max_depth must be an integer")
							}
						} else {
							maxDepth = nil
						}
						let startPath = args["path"]?.stringValue
						let selection = await owner.selectedVMsAndIDsForCurrentExecContext()

						let result = await owner.buildFileTreeResult(
							mode: mode,
							maxDepth: maxDepth,
							includeHidden: false,   // removed from tool; ignored in generator
							startPath: startPath,
							selectedIDs: selection.ids
						)

							let rootCount = await MainActor.run {
								owner.fileManager.visibleRootFolders.count
							}

							return ToolResultDTOs.FileTreeDTO(
								rootsCount: rootCount,
								usesLegend: result.usesLegend,
								tree: result.tree,
								note: result.note,
								wasTruncated: result.wasTruncated
							)

			default:
				throw MCPError.invalidParams("invalid type: \(type)")
			}
		},

		// (Removed) get_token_statistics — use workspace_context include=["tokens"]

		// ───────────  read_file  ───────────
		weakTool(
			name: ToolNames.readFile,
			description: """
Read file contents with optional line range.

**Parameters**:
- `path`: File path (required)
- `start_line`: 1-based line number, or negative for tail behavior
- `limit`: Number of lines (only with positive start_line)

**Behaviors**:
- No params: Entire file
- `start_line=10`: From line 10 to end
- `start_line=10, limit=20`: Lines 10-29
- `start_line=-10`: Last 10 lines (like `tail -10`)

**Examples**:
- Full file: `{"path":"src/main.swift"}`
- Lines 50-100: `{"path":"file.swift","start_line":50,"limit":51}`
- Last 20 lines: `{"path":"file.swift","start_line":-20}`
""",
			annotations: .repoPromptLocalReadOnly,
			inputSchema: .object(
				properties: [
					"path": .string(description: "File path"),
					"start_line": .integer(description: "Line to start from (1-based) or negative for tail behavior (-N reads last N lines)"),
					"limit": .integer(description: "Number of lines to read")
				],
				required: ["path"]
			)
		) { owner, args in
			guard let path = args["path"]?.stringValue else {
				throw MCPError.invalidParams("missing path")
			}

			// Extract line range parameters as provided (keep negative sentinel semantics)
			// Support 'offset' as an alias for 'start_line' for compatibility
			let startLineFromInt = args["start_line"]?.intValue ?? args["offset"]?.intValue
			let startLineFromString = Int(args["start_line"]?.stringValue ?? "") ?? Int(args["offset"]?.stringValue ?? "")
			let startLine1Based = startLineFromInt ?? startLineFromString

			let limit = args["limit"]?.intValue
				?? Int(args["limit"]?.stringValue ?? "")

			let metadata = await owner.captureRequestMetadata()
			let lookupRootScope = await owner.resolveFileToolLookupRootScope(from: metadata)
			let readResult = try await owner.readFile(
				path: path,
				startLine1Based: startLine1Based,
				lineCount: limit,
				lookupRootScope: lookupRootScope
			)
			if readResult.shouldAutoSelect {
				await owner.maybeAutoSelectReadFileSelection(reply: readResult.reply, requestedPath: path)
			}
			return readResult.reply
		},


		// ───────────  search  ───────────
		weakTool(
			name: ToolNames.search,
			description: """
Search files by path pattern and/or content.

**Modes**:
- `auto` (default): Detects path vs content search from pattern
- `path`: Match file paths only (glob-style with regex=false, full regex otherwise)
- `content`: Search inside file contents
- `both`: Search paths and contents

**Matching** (regex auto-detected by default):
- Regex mode: Full regex support (groups, lookarounds, anchors)
- Literal mode (regex=false): Special chars matched literally, `*`/`?` wildcards for paths
- Tip: Set `regex=false` to force literal substring matching

**Key options**:
- `pattern`: Search term (required)
- `max_results`: Result limit (default: 50)
- `context_lines`: Lines before/after matches (alias: `-C`)
- `whole_word`: Match whole words only
- `count_only`: Return counts only, no content
- `filter.extensions`: Limit to extensions (e.g., [".swift"])
- `filter.paths`: Limit to paths/folders (can also be a loaded root name like 'RepoPrompt')
- `filter.exclude`: Skip matching patterns

**Examples**:
- Literal: `{"pattern":"frame(minWidth:","regex":false}`
- Regex OR: `{"pattern":"performSearch|searchUsers"}`
- Find files: `{"pattern":"*.swift","mode":"path","regex":false}`
- With context: `{"pattern":"TODO","context_lines":2}`
- Scoped: `{"pattern":"auth","filter":{"paths":["src/auth/"]}}`

Response capped at ~50k chars; excess results omitted (count reported).
""",
			annotations: .repoPromptLocalReadOnly,
			inputSchema: .object(
				properties: [
					"pattern": .string(description: "Search pattern"),
					"mode": .string(
						description: "Search scope: auto-detects if not specified",
						enum: ["auto", "path", "content", "both"]
					),
					"regex": .boolean(description: "Use regex matching (default: auto based on pattern)"),
					"filter": .object(
						description: "File filtering options (alias: use 'path' string parameter for single-file search)",
						properties: [
							"extensions": .array(
								description: "Only search files with these extensions",
								items: .string(description: "File extension like '.js' or '.swift'")
							),
							"exclude": .array(
								description: "Skip files/paths matching these patterns",
								items: .string(description: "Pattern like 'node_modules' or '*.log'")
							),
							"paths": .array(
								description: "Limit search to specific file or folder paths, or a loaded root name",
								items: .string(description: "Absolute path, relative path, or loaded root name (e.g., 'RepoPrompt')")
							)
						]
					),
					"path": .string(description: "Alias for filter.paths with a single file or folder path"),
					"max_results": .integer(description: "Maximum total results (default: 50)"),
					"count_only": .boolean(description: "Return only match count"),
					"context_lines": .integer(description: "Lines of context before/after matches (alias: -C)"),
					"whole_word": .boolean(description: "Match whole words only")
				],
				required: ["pattern"]
			)
		) { owner, args in
			try await owner.executeFileSearchTool(args: args)

		},

		// ... remaining tools unchanged ...

		// (request_plan tool removed)
		/*
			// ───────────  reveal_in_finder  ───────────
			Tool(
			name: ToolNames.revealInFinder,
			description: "Reveal the given path in Finder.",
			inputSchema: .object(
			properties: [
			"path": .string(description: "Relative or absolute path")
			],
			required: ["path"]
			),
			implementation: { args in
			guard let path = args["path"]?.stringValue else {
			throw MCPError.invalidParams("missing path")
			}
			if let file = await self.fileManager.findFile(atPath: path) {
			file.revealInFinder()
			return "ok"
			}
			throw MCPError.invalidParams("file not found")
			}
			)
			*/

		// ───────────  workspace_context  ───────────
		weakTool(
			name: ToolNames.workspaceContext,
			description: """
Canonical workspace context render/export tool.

Default behavior returns a snapshot of prompt, selection, code structure, and tokens.
Use `op` for render/export helpers, or omit it for the default snapshot.

**Default includes**: `["prompt","selection","code","tokens"]`

**Available includes**:
- `prompt`: Current prompt text
- `selection`: Selected files summary
- `code`: Code structure (codemaps) for selection
- `files`: Full file contents
- `tree`: File tree of selected files
- `tokens`: Token breakdown by component

**Operations**:
- `snapshot` (default) — build/render the current workspace context snapshot
- `export` — write the rendered export to disk
- `list_presets` — list copy presets
- `select_preset` — select the active copy preset for the bound tab

**Options**:
- `include`: Array of sections to include for snapshot rendering
- `path_display`: "relative" | "full"
- `copy_preset`: Override copy preset for token calculation / export rendering

**Examples**:
- Default snapshot: `{}`
- With file contents: `{"include":["prompt","selection","files"]}`
- Export: `{"op":"export","path":"context.txt"}`
- Preset override: `{"copy_preset":"mcpBuilder"}`

Related: manage_selection, get_file_tree, ask_oracle
""",
			annotations: .repoPromptLocalReadOnly,
			inputSchema: .object(
				properties: [
					"op": .string(description: "Operation (default: 'snapshot')", enum: ["snapshot","export","list_presets","select_preset"]),
					"include": .array(
						description: "What to include (defaults to prompt, selection, code, tokens)",
						items: .string(enum: ["prompt","selection","code","files","tree","tokens"])
					),
					"path_display": .string(description: "Path display for blocks", enum: ["full","relative"]),
					"path": .string(description: "File path for export operation"),
					"preset": .string(description: "Preset UUID, kind, or name"),
					"copy_preset": .string(description: "Preset UUID, kind, or name")
				],
				required: []
			)
		) { owner, args in
			let op = (args["op"]?.stringValue ?? "snapshot").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if op != "snapshot" {
				var forwarded = args
				forwarded["op"] = .string(op)
				switch op {
				case "export", "list_presets", "select_preset":
					guard let result = try await owner.call(tool: ToolNames.prompt, with: forwarded) else {
						throw MCPError.internalError("Failed to dispatch workspace_context \(op) operation")
					}
					return result
				default:
					throw MCPError.invalidParams("Unsupported workspace_context op '\(op)'. Use snapshot, export, list_presets, or select_preset.")
				}
			}
			let includeArr = args["include"]?.arrayValue?.compactMap { $0.stringValue?.lowercased() } ?? ["prompt","selection","code","tokens"]
			let include = Set(includeArr)
			let displayRaw = args["path_display"]?.stringValue ?? "relative"
			let display: FilePathDisplay = (displayRaw.lowercased() == "full") ? .full : .relative

			// Parse copy_preset selector for override
			let presetSelector = owner.parseCopyPresetSelector(from: args["copy_preset"])
			let overridePreset: CopyPreset? = await {
				guard let selector = presetSelector else { return nil }
				return await MainActor.run { owner.resolveCopyPreset(from: selector) }
			}()

			// Validate override if selector was provided but couldn't resolve
			if presetSelector != nil && overridePreset == nil {
				throw MCPError.invalidParams("copy_preset not found")
			}

			let metadata = await owner.captureRequestMetadata()
			if case .virtual = await owner.resolveExecContext(from: metadata) {
				let context = try await owner.requireCurrentTabContext(toolName: ToolNames.workspaceContext)
				return try Value(await owner.buildTabWorkspaceContext(
					context: context,
					include: include,
					display: display,
					copyPresetOverride: overridePreset
				))
			}

			// Prompt
			let promptValue = await owner.promptVM.promptText
			let prompt = include.contains("prompt") ? promptValue : ""

			let includeSelection = include.contains("selection")
			let requireSelectionData = includeSelection
				|| include.contains("files")
				|| include.contains("code")
				|| include.contains("tokens")

			var collections: SelectionReplyAssembler.SelectionCollections? = nil
			var selectedReply: ToolResultDTOs.SelectedFilesReply? = nil

			// Get active and effective presets + resolved config
			let activePreset = await MainActor.run { owner.promptVM.currentCopyPreset() }
			let effectivePreset = overridePreset ?? activePreset
			var resolvedCfg = await MainActor.run {
				owner.promptVM.resolvePromptContext(effectivePreset, custom: owner.promptVM.workingCopyCustomizations)
			}
			if await MainActor.run(body: { owner.promptVM.codeMapsGloballyDisabled }) {
				resolvedCfg.codeMapUsage = .none
			}
			let projectionConfig = owner.projectionConfig(from: resolvedCfg)

			// Get user's effective copy preset mode for projection
			let copyUsage = resolvedCfg.codeMapUsage
			let userPresetState = await MainActor.run { (copyUsage != .auto || owner.promptVM.codeMapsGloballyDisabled) ? owner.buildUserPresetState() : nil }

			if requireSelectionData {
				// Always use .auto mode for normalized view
				let source = await MainActor.run {
					LiveSelectionSource(
						fileManager: owner.fileManager,
						codeMapUsage: owner.effectiveMCPCodeMapUsage(.auto)
					)
				}
				let formatter = PathFormatter(format: .relative, owner: owner)
				let tokensHelper = TokenServices(owner: owner)
				let gathered = await SelectionReplyAssembler.collect(from: source)
				let reply = await SelectionReplyAssembler.buildSelectedFilesReply(
					collections: gathered,
					formatter: formatter,
					tokens: tokensHelper,
					userPresetState: userPresetState,
					copyUsage: copyUsage != .auto ? copyUsage : nil,
					projection: projectionConfig
				)
				collections = gathered
				selectedReply = reply
			} else if includeSelection {
				selectedReply = await owner.selectedFilesWithStats()
			}

			let selectionDTO = includeSelection ? selectedReply : nil

			// File contents (opt-in)
			var fileBlocks: [String]? = nil
			if include.contains("files") {
				if let coll = collections {
					fileBlocks = await SelectionReplyAssembler.generateBlocks(
						selected: coll.selected,
						display: display
					)
				} else {
					fileBlocks = []
				}
			}

			// Code structure (codemaps)
			var codeStructDTO: ToolResultDTOs.SelectedCodeStructureDTO? = nil
			let codeMapsDisabled = await MainActor.run { owner.promptVM.codeMapsGloballyDisabled }
			if include.contains("code"), !codeMapsDisabled, let coll = collections {
				let builder = CodeStructureBuilder(owner: owner)
				let combined = coll.selected.map { $0.file } + coll.codemap.map { $0.file }
				codeStructDTO = await builder.build(for: combined)
			}

			// Selected file tree (opt-in)
			var fileTreeDTO: ToolResultDTOs.FileTreeDTO? = nil
			var fileTreeTokens = 0
			if include.contains("tree") {
				let selection = await owner.selectedVMsAndIDsForCurrentExecContext()
				let result = await owner.buildFileTreeResult(
					mode: "selected",
					maxDepth: nil,
					includeHidden: false,
					selectedIDs: selection.ids
				)
				let rootCount = await MainActor.run { owner.fileManager.visibleRootFolders.count }
				fileTreeDTO = .init(
					rootsCount: rootCount,
					usesLegend: result.usesLegend,
					tree: result.tree,
					note: result.note,
					wasTruncated: result.wasTruncated
				)
				fileTreeTokens = TokenCalculationService.estimateTokens(for: result.tree)
			}

		// Token stats (opt-in default)
		var tokenStatsDTO: ToolResultDTOs.TokenStats? = nil
		var userTokenStatsDTO: ToolResultDTOs.TokenStats? = nil
		var tokenStatsNote: String? = nil
		if include.contains("tokens") {
			// Force immediate token recount to avoid stale breakdown values
			// This ensures prompt/meta/git tokens reflect current state, not cached values
			await owner.promptVM.tokenCountingViewModel.forceImmediateRecount()
			let fileTokens = selectedReply?.totalTokens ?? 0
			// Extract content vs codemap breakdown from summary
			let filesContentTokens = (selectedReply?.summary?.fullTokens ?? 0) + (selectedReply?.summary?.sliceTokens ?? 0)
			let codemapsTokens = selectedReply?.summary?.codemapTokens ?? 0
			let breakdown = await owner.latestTokenBreakdown()
			let promptTokens = breakdown.prompt
			var treeTokens = breakdown.fileTree
			if treeTokens == 0 && fileTreeTokens > 0 {
				treeTokens = fileTreeTokens
			}
			let metaTokens = breakdown.meta
			let gitTokens = breakdown.git
			var totalTokens = breakdown.total
			let componentSum = promptTokens + fileTokens + treeTokens + metaTokens + gitTokens
			if totalTokens == 0 || totalTokens < componentSum {
				totalTokens = componentSum
			}
			let otherTokens = max(totalTokens - componentSum, 0)
			tokenStatsDTO = .init(
				total: totalTokens,
				files: fileTokens,
				prompt: promptTokens,
				fileTree: treeTokens,
				meta: metaTokens,
				git: gitTokens,
				other: otherTokens,
				filesContent: filesContentTokens > 0 ? filesContentTokens : nil,
				codemaps: codemapsTokens > 0 ? codemapsTokens : nil
			)

			// Compute user token stats if user preset differs from auto
			if let userFileTokens = selectedReply?.userCopyTokens, userFileTokens != fileTokens {
				let userContentTokens = selectedReply?.userCopyContentTokens ?? 0
				let userCodemapTokens = selectedReply?.userCopyCodemapTokens ?? 0
				let userComponentSum = promptTokens + userFileTokens + treeTokens + metaTokens + gitTokens
				let userTotalTokens = max(userComponentSum, totalTokens - fileTokens + userFileTokens)
				let userOtherTokens = max(userTotalTokens - userComponentSum, 0)
				userTokenStatsDTO = .init(
					total: userTotalTokens,
					files: userFileTokens,
					prompt: promptTokens,
					fileTree: treeTokens,
					meta: metaTokens,
					git: gitTokens,
					other: userOtherTokens,
					filesContent: userContentTokens > 0 ? userContentTokens : nil,
					codemaps: userCodemapTokens > 0 ? userCodemapTokens : nil
				)
				// Add note explaining the difference (concise, delta-focused)
				let codemapDelta = fileTokens - userFileTokens
				tokenStatsNote = "Difference: \(codemapDelta) codemap tokens (API signatures). Your preset excludes these, so exports use \(userFileTokens) file tokens, not \(fileTokens)."
			}
		}

			// Build copy preset context DTO (shows active vs effective if overridden)
			let copyPresetContextDTO = await MainActor.run {
				owner.buildCopyPresetContextDTO(active: activePreset, effective: effectivePreset)
			}

			return try Value(ToolResultDTOs.PromptContextDTO(
				prompt: prompt,
				selection: selectionDTO,
				fileBlocks: fileBlocks,
				codeStructure: codeStructDTO,
				fileTree: fileTreeDTO,
				tokenStats: tokenStatsDTO,
				userTokenStats: userTokenStatsDTO,
				tokenStatsNote: tokenStatsNote,
				copyPreset: copyPresetContextDTO,
				copyPresets: nil
			))
        },

		// ───────────  prompt  ───────────
		weakTool(
			name: ToolNames.prompt,
			description: """
Get or modify the shared prompt (instructions/notes).

**Operations**: get | set | append | clear | export | list_presets | select_preset

**Parameters by op**:
- `set`/`append`: `text` (required)
- `export`: `path` (required), `copy_preset` (optional override)
- `select_preset`: `preset` (required) - UUID, kind, or name

**Notes**:
- `select_preset` requires an explicitly bound tab context (not available during discovery runs)
- `export` writes clipboard content to file so it can be copy/pasted into ChatGPT (or another AI) for a second opinion; use `copy_preset` to override format
- `list_presets` returns all available copy presets with configurations

**Examples**:
- Get: `{"op":"get"}`
- Set: `{"op":"set","text":"Focus on error handling"}`
- Export: `{"op":"export","path":"context.txt"}`
- List presets: `{"op":"list_presets"}`
- Select preset: `{"op":"select_preset","preset":"mcpBuilder"}`

Related: workspace_context, manage_selection, ask_oracle
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				properties: [
					"op": .string(description: "Operation (default: 'get')", enum: ["get","set","append","clear","export","list_presets","select_preset"]),
					"text": .string(description: "Text for set/append"),
					"path": .string(description: "File path (required for export)"),
					"preset": .string(description: "Preset UUID, kind, or name"),
					"copy_preset": .string(description: "Preset UUID, kind, or name")
				],
				required: []
			)
		) { owner, args in
			let op = (args["op"]?.stringValue ?? "get").lowercased()

			func simplePromptReply(_ text: String, op: String) -> ToolResultDTOs.PromptToolEnvelope {
				let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
				return .forPrompt(ToolResultDTOs.PromptReply(
					prompt: text,
					lines: lines,
					copyPresetName: nil,
					chatPresetName: nil,
					chatMode: nil,
					includesFiles: nil,
					includesFileTree: nil,
					includesCodemaps: nil,
					includesGitDiff: nil,
					includesUserPrompt: nil,
					includesMetaPrompts: nil,
					includesStoredPrompts: nil,
					fileTreeMode: nil,
					codeMapUsage: nil,
					gitInclusion: nil,
					xmlFormat: nil,
					systemPromptFlavor: nil,
					effectiveTokens: nil,
					fullFilesTokens: nil,
					codeMapFileCount: nil,
					codeMapTokens: nil,
					codeMapFiles: nil
				), op: op)
			}

			let metadata = await owner.captureRequestMetadata()
			let execContext = await owner.resolveExecContext(from: metadata)
			if case .virtual(let tabContext) = execContext {
				switch op {
				case "get":
					let context = try await owner.requireCurrentTabContext(toolName: ToolNames.prompt)
					return simplePromptReply(context.promptText, op: op)
				case "set":
					guard let text = args["text"]?.stringValue else {
						throw MCPError.invalidParams("text required for set")
					}
					try await owner.updateCurrentTabContext(toolName: ToolNames.prompt) { ctx in
						ctx.promptText = text
					}
					let context = try await owner.requireCurrentTabContext(toolName: ToolNames.prompt)
					return simplePromptReply(context.promptText, op: op)
				case "append":
					guard let text = args["text"]?.stringValue else {
						throw MCPError.invalidParams("text required for append")
					}
					try await owner.updateCurrentTabContext(toolName: ToolNames.prompt) { ctx in
						ctx.promptText += text
					}
					let context = try await owner.requireCurrentTabContext(toolName: ToolNames.prompt)
					return simplePromptReply(context.promptText, op: op)
				case "clear":
					try await owner.updateCurrentTabContext(toolName: ToolNames.prompt) { ctx in
						ctx.promptText = ""
					}
					return simplePromptReply("", op: op)
			case "export":
				guard let rawPath = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
				!rawPath.isEmpty else {
					throw MCPError.invalidParams("path required for export")
				}
				// Parse copy_preset override
				let presetSelector = owner.parseCopyPresetSelector(from: args["copy_preset"])
				let overridePreset: CopyPreset? = await {
					guard let selector = presetSelector else { return nil }
					return await MainActor.run { owner.resolveCopyPreset(from: selector) }
				}()
				if presetSelector != nil && overridePreset == nil {
					throw MCPError.invalidParams("copy_preset not found")
				}
				// Build clipboard content with effective preset
				let activePreset = await MainActor.run { owner.promptVM.currentCopyPreset() }
				let effectivePreset = overridePreset ?? activePreset
				let cfg = await MainActor.run {
					owner.promptVM.resolvePromptContext(effectivePreset, custom: owner.promptVM.workingCopyCustomizations)
				}
				let text = await owner.buildTabClipboardContent(cfg: cfg, context: tabContext)
				// Write file
				let resolvedPath = try await owner.writePromptExportFile(path: rawPath, content: text)
				await owner.fileManager.flushPendingDeltas(aggressive: true)
				// Build reply with file list (effective export view)
				let (pathDisplay, rootFolders) = await MainActor.run {
					(owner.promptVM.filePathDisplayOption, owner.fileManager.rootFolders)
				}
				let files = await owner.buildExportSelectedFileInfos(
					execContext: execContext,
					cfg: cfg,
					selectionOverride: tabContext.selection,
					display: pathDisplay
				)
				let exportPath = pathDisplay == .full ? resolvedPath : Self.prefixedRelativePath(forPath: resolvedPath, rootFolders: rootFolders)
				let presetDTO = await MainActor.run { owner.toDescriptorDTO(effectivePreset) }
				return .forExport(ToolResultDTOs.PromptExportReply(
					path: exportPath,
					tokens: TokenCalculationService.estimateTokens(for: text),
					bytes: text.lengthOfBytes(using: .utf8),
					files: files,
					copyPreset: presetDTO
				))
			case "list_presets":
				let presets = await MainActor.run { owner.buildCopyPresetsListDTO() }
				return .forPresetsList(presets)
			case "select_preset":
				guard tabContext.explicitlyBound, tabContext.runID == nil else {
					throw MCPError.invalidParams("select_preset requires an explicitly bound tab (bind_context or _tabID). It is disabled for run-based bindings; use copy_preset override in workspace_context or export instead.")
				}
				let presetSelector = owner.parseCopyPresetSelector(from: args["preset"])
				guard let selector = presetSelector else {
					throw MCPError.invalidParams("preset parameter required for select_preset (UUID, kind, or name)")
				}
				guard let targetPreset = await MainActor.run(body: { owner.resolveCopyPreset(from: selector) }) else {
					throw MCPError.invalidParams("preset not found")
				}
				await MainActor.run {
					owner.promptVM.selectCopyPreset(targetPreset.id)
				}
				let presetDTO = await MainActor.run { owner.toDescriptorDTO(targetPreset) }
				return .forSelectPreset(presetDTO)
			default:
				throw MCPError.invalidParams("Unsupported op '\(op)' for prompt when tab context is active")
			}
			}

			switch op {
			case "get":
				let p = await owner.promptVM.promptText
				let lines = p.isEmpty ? 0 : p.components(separatedBy: "\n").count

				// Gather detailed state information
				let copyPreset = await owner.promptVM.currentCopyPreset()
				let chatPreset = await owner.promptVM.currentChatPreset()
				let resolvedContext = await owner.promptVM.resolvePromptContext()

				// Calculate token counts
				let effectiveTokens = await owner.promptVM.calculateTokensForChatContext()
				let fullFilesTokens = await owner.promptVM.tokenCountingViewModel.totalTokenCountFilesOnly

				// Determine what's included based on resolved config
				let includesCodemaps = resolvedContext.codeMapUsage != .none
				let includesGitDiff = resolvedContext.gitInclusion != .none
				let hasStoredPrompts = (resolvedContext.storedPromptIds?.isEmpty == false)

				// Codemap details (when codemaps are included)
				let codeMapFileCount = includesCodemaps ? await owner.promptVM.codeMapFileCount : nil
				let codeMapTokens = includesCodemaps ? await owner.promptVM.codeMapTokenCount : nil
				let codeMapFiles: [String]? = await {
					guard includesCodemaps else { return nil }
					return CodeMapExtractor.getCodeMapFilePaths(
						codeMapUsage: resolvedContext.codeMapUsage,
						selectedFiles: await owner.fileManager.selectedFiles,
						allFileAPIs: await owner.promptVM.cachedFileAPIs,
						filePathDisplay: await owner.promptVM.filePathDisplayOption,
						rootFolders: await owner.fileManager.rootFolders
					)
				}()

				// Get XML format string
				let xmlFormatStr: String? = {
					guard let fmt = resolvedContext.xmlFormat else { return nil }
					switch fmt {
					case .diff: return "diff"
					case .whole: return "whole"
					case .architect: return "architect"
					}
				}()

				// Get system prompt flavor string
				let flavorStr: String? = {
					guard let flavor = resolvedContext.systemPromptFlavor else { return nil }
					switch flavor {
					case .architectPlan: return "architect_plan"
					case .codeEditDiff: return "code_edit_diff"
					case .codeEditWhole: return "code_edit_whole"
					case .review: return "review"
					case .mcpAgent: return "mcp_agent"
					case .mcpPairProgram: return "mcp_pair_program"
					case .mcpPairPlan: return "mcp_pair_plan"
					case .mcpDiscover: return "mcp_discover"
					case .mcpBuilder: return "mcp_builder"
					}
				}()

				return .forPrompt(ToolResultDTOs.PromptReply(
					prompt: p,
					lines: lines,
					copyPresetName: copyPreset.name,
					chatPresetName: chatPreset.name,
					chatMode: chatPreset.mode.rawValue,
					includesFiles: resolvedContext.includeFiles,
					includesFileTree: resolvedContext.rendersFileTree,
					includesCodemaps: includesCodemaps,
					includesGitDiff: includesGitDiff,
					includesUserPrompt: resolvedContext.includeUserPrompt,
					includesMetaPrompts: resolvedContext.includeMetaPrompts,
					includesStoredPrompts: hasStoredPrompts,
					fileTreeMode: resolvedContext.effectiveFileTreeMode.rawValue,
					codeMapUsage: resolvedContext.codeMapUsage.rawValue,
					gitInclusion: resolvedContext.gitInclusion.rawValue,
					xmlFormat: xmlFormatStr,
					systemPromptFlavor: flavorStr,
					effectiveTokens: effectiveTokens,
					fullFilesTokens: fullFilesTokens,
					codeMapFileCount: codeMapFileCount,
					codeMapTokens: codeMapTokens,
					codeMapFiles: codeMapFiles
				), op: op)
			case "set":
				guard let text = args["text"]?.stringValue else {
					throw MCPError.invalidParams("text required for set")
				}
				await MainActor.run { owner.promptVM.promptText = text }
				return simplePromptReply(text, op: op)
			case "append":
				guard let text = args["text"]?.stringValue else {
					throw MCPError.invalidParams("text required for append")
				}
				let current = await owner.promptVM.promptText
				let combined = current + text
				await MainActor.run { owner.promptVM.promptText = combined }
				return simplePromptReply(combined, op: op)
			case "clear":
				await MainActor.run { owner.promptVM.promptText = "" }
				return simplePromptReply("", op: op)
			case "export":
				guard let rawPath = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
				!rawPath.isEmpty else {
					throw MCPError.invalidParams("path required for export")
				}
				// Parse copy_preset override
				let presetSelector = owner.parseCopyPresetSelector(from: args["copy_preset"])
				let overridePreset: CopyPreset? = await {
					guard let selector = presetSelector else { return nil }
					return await MainActor.run { owner.resolveCopyPreset(from: selector) }
				}()
				if presetSelector != nil && overridePreset == nil {
					throw MCPError.invalidParams("copy_preset not found")
				}
				// Build clipboard content with effective preset
				let activePreset = await MainActor.run { owner.promptVM.currentCopyPreset() }
				let effectivePreset = overridePreset ?? activePreset
				let cfg = await MainActor.run {
					owner.promptVM.resolvePromptContext(effectivePreset, custom: owner.promptVM.workingCopyCustomizations)
				}
				let text = await owner.promptVM.buildClipboard(for: cfg)
				// Write file
				let resolvedPath = try await owner.writePromptExportFile(path: rawPath, content: text)
				await owner.fileManager.flushPendingDeltas(aggressive: true)
				// Build reply with file list (effective export view)
				let (pathDisplay, rootFolders) = await MainActor.run {
					(owner.promptVM.filePathDisplayOption, owner.fileManager.rootFolders)
				}
				let files = await owner.buildExportSelectedFileInfos(
					execContext: execContext,
					cfg: cfg,
					display: pathDisplay
				)
				let exportPath = pathDisplay == .full ? resolvedPath : Self.prefixedRelativePath(forPath: resolvedPath, rootFolders: rootFolders)
				let presetDTO = await MainActor.run { owner.toDescriptorDTO(effectivePreset) }
				return .forExport(ToolResultDTOs.PromptExportReply(
					path: exportPath,
					tokens: TokenCalculationService.estimateTokens(for: text),
					bytes: text.lengthOfBytes(using: .utf8),
					files: files,
					copyPreset: presetDTO
				))
			case "list_presets":
				let presets = await MainActor.run { owner.buildCopyPresetsListDTO() }
				return .forPresetsList(presets)
			case "select_preset":
				// Parse preset selector from 'preset' parameter
				let presetSelector = owner.parseCopyPresetSelector(from: args["preset"])
				guard let selector = presetSelector else {
					throw MCPError.invalidParams("preset parameter required for select_preset (UUID, kind, or name)")
				}
				guard let targetPreset = await MainActor.run(body: { owner.resolveCopyPreset(from: selector) }) else {
					throw MCPError.invalidParams("preset not found")
				}
				// Apply the preset selection to the UI
				await MainActor.run {
					owner.promptVM.selectCopyPreset(targetPreset.id)
				}
				// Return the selected preset info
				let presetDTO = await MainActor.run { owner.toDescriptorDTO(targetPreset) }
				return .forSelectPreset(presetDTO)
			default:
				throw MCPError.invalidParams("invalid op: \(op)")
			}
		},

		// ───────────  apply_edits  ───────────
		weakTool(
			name: ToolNames.applyEdits,
			description: """
Apply direct file edits. Provide exactly ONE of these three modes:

**Mode 1: Rewrite** - Replace entire file content
`{"path": "file.swift", "rewrite": "new content...", "on_missing": "create"}`

**Mode 2: Single replacement** - Find and replace text
`{"path": "file.swift", "search": "oldCode", "replace": "newCode", "all": true}`

**Mode 3: Multiple edits** - Apply several replacements
`{"path": "file.swift", "edits": [{"search": "old1", "replace": "new1"}, {"search": "old2", "replace": "new2"}]}`

Note: Modes are mutually exclusive. Providing more than one will result in an error.

Options: `verbose` (show diff), `on_missing` (for rewrite only: "error" | "create", default: "error")
Edits are literal. Use real JSON newlines for multi-line search/replace (not `\\n`). If a match fails, the tool may retry internally with escape decoding.
""",
			annotations: .repoPromptLocalDestructive,
			inputSchema: .object(
				properties: [
					"path": .string(description: "File path"),
					"rewrite": .string(description: "Replace the entire file content with this string"),
					"search": .string(description: "Text to find"),
					"replace": .string(description: "Replacement text"),
					"all": .boolean(description: "Replace all occurrences (default: false)"),
					"edits": .array(
						description: "Multiple edits",
						items: .object(
							properties: [
								"search": .string(description: "Text to find"),
								"replace": .string(description: "Replacement text"),
								"all": .boolean(description: "Replace all occurrences (default: false)")
							],
							required: ["search", "replace"]
						)
					),
					"verbose": .boolean(description: "Include diff preview"),
					"on_missing": .string(
						description: "Behavior when the file is missing (only for `rewrite`)",
						enum: ["error", "create"]
					)
				],
				required: ["path"]
			)
		) { owner, args in
			var requestPath: String? = nil
			do {
				let request = try EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.requestBuild) {
					try ApplyEditsRequestBuilder().buildFromNormalizedPayload(args)
				}
				requestPath = request.path
				if let issue = await owner.fileManager.exactPathResolutionIssue(for: request.path, kind: .file) {
					throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
				}
				let metadata = await owner.captureRequestMetadata()
				let execContext = await owner.resolveExecContext(from: metadata)
				let host = WorkspaceFileEditHost(
					fileManager: owner.fileManager,
					resolveFile: { path in
						guard let fileVM = await owner.fileManager.resolveExistingFileForToolEdit(atPath: path) else {
							let msg = await owner.workspaceContextMessage(forOperation: "open file", path: path)
							throw MCPError.invalidParams("Unknown or unloaded path: \(path). \(msg)")
						}
						return fileVM
					},
					fileExistsResolver: { path in
						await owner.fileManager.fileExistsStrictly(atPath: path)
					}
				)
				let service = ApplyEditsService(engine: .default, host: host)

				let runPurpose: MCPRunPurpose?
				if let connectionID = metadata.connectionID {
					runPurpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
				} else {
					runPurpose = nil
				}
				let virtualTabID: UUID?
				if case .virtual(let context) = execContext {
					virtualTabID = context.tabID
				} else {
					virtualTabID = nil
				}
				let availableTabIDs = await MainActor.run {
					Set(owner.workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
				}
				let tabID = try Self.resolveApplyEditsAgentModeTabID(
					runPurpose: runPurpose,
					virtualTabID: virtualTabID,
					rawTabID: args["_tabID"]?.stringValue,
					availableTabIDs: availableTabIDs
				)

				let approvalScope: ApplyEditsApprovalScope?
				if runPurpose == .agentModeRun, let tabID {
					approvalScope = ApplyEditsApprovalScope(windowID: owner.windowID, tabID: tabID)
				} else {
					approvalScope = nil
				}

				var shouldRequireApproval = false
				if let approvalScope {
					let autoEditEnabled = await owner.applyEditsApprovalStore.autoEditEnabled(for: approvalScope)
					shouldRequireApproval = !autoEditEnabled
				}

				if shouldRequireApproval, let approvalScope {
					let previewRequest = ApplyEditsRequest(
						path: request.path,
						mode: request.mode,
						verbose: true
					)
					let preview = try await service.preview(previewRequest)
					let previewResult = preview.result
					if previewResult.editsApplied == 0 {
						return await owner.editSummary(from: previewResult, path: request.path)
					}
					let reviewUnifiedDiff = previewResult.unifiedDiffForToolCard(filePath: request.path)
						?? "No textual diff available for this apply_edits request."

					let decision = await owner.applyEditsApprovalStore.requestReview(
						scope: approvalScope,
						path: request.path,
						unifiedDiff: reviewUnifiedDiff,
						timeoutSeconds: 300
					)

					switch decision {
					case .accept:
						try await EditFlowPerf.measure(
							EditFlowPerf.Stage.ApplyEdits.hostWrite,
							EditFlowPerf.Dimensions(fileBytes: previewResult.updatedText.utf8.count, appliedCount: previewResult.editsApplied)
						) {
							try await host.writeText(
								path: request.path,
								content: previewResult.updatedText,
								overwrite: preview.exists
							)
						}
						await EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.flushDeltas) {
							await owner.fileManager.flushPendingDeltas(aggressive: true)
						}
						let persistedResult = previewResult.withFileMetadata(created: !preview.exists, overwritten: false)
						return await owner.editSummary(
							from: persistedResult,
							path: request.path,
							reviewStatus: "accepted",
							requiresUserApproval: true
						)
					case .reject(let reason):
						return await owner.editSummary(
							from: previewResult,
							path: request.path,
							statusOverride: "failed",
							noteOverride: "Rejected by user: \(reason)",
							reviewStatus: "rejected",
							rejectionReason: reason,
							requiresUserApproval: true
						)
					case .timeout:
						return await owner.editSummary(
							from: previewResult,
							path: request.path,
							statusOverride: "failed",
							noteOverride: "Timed out waiting for apply_edits review approval",
							reviewStatus: "timeout",
							requiresUserApproval: true
						)
					case .cancelled(let reason):
						return await owner.editSummary(
							from: previewResult,
							path: request.path,
							statusOverride: "failed",
							noteOverride: "Apply edits review was cancelled: \(reason)",
							reviewStatus: "cancelled",
							rejectionReason: reason,
							requiresUserApproval: true
						)
					}
				}

				let result = try await service.run(request)
				if result.editsApplied > 0 {
					await EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.flushDeltas) {
						await owner.fileManager.flushPendingDeltas(aggressive: true)
					}
				} else {
					EditFlowPerf.event(
						EditFlowPerf.Stage.ApplyEdits.flushDeltas,
						EditFlowPerf.Dimensions(outcome: "skipped", appliedCount: result.editsApplied)
					)
				}
				return await owner.editSummary(from: result, path: request.path)
			} catch let error as FileManagerError {
				throw await owner.mapFileManagerErrorToMCP(error, action: ToolNames.applyEdits, path: requestPath)
			} catch let error as ApplyEditsError {
				throw await owner.mapApplyEditsError(error)
			} catch let error as StrictWorkspaceFileContentError {
				throw await owner.mapStrictWorkspaceFileContentError(error, path: requestPath)
			} catch let error as MCPError {
				throw error
			} catch {
				throw MCPError.internalError(error.localizedDescription)
			}
		},

		// ───────────  oracle_utils  ───────────
		weakTool(
			name: ToolNames.oracleUtils,
			description: """
Oracle helper utilities.

Use this for read-only oracle-specific helpers:
- `op="models"`   → list model choices relevant to oracle sends
- `op="sessions"` → list oracle/chat sessions for the current workspace. Pass context_id to filter to a specific context's sessions.

Use `ask_oracle` for all send/continue turns.
""",
			inputSchema: .object(
				properties: [
					"op": .string(description: "Helper operation", enum: ["models", "sessions"]),
					"limit": .integer(description: "Maximum sessions to return for the sessions operation"),
					"scope": .string(description: "Filter scope: 'workspace' (default) or 'tab'. Auto-inferred when context_id is provided."),
					"context_id": .string(description: "Context UUID to filter to a specific context's sessions. Use bind_context op=list to discover values.")
				],
				required: ["op"]
			)
		) { owner, args in
			try await owner.oracleToolService.executeOracleUtils(args: args)
		},

		// ───────────  ask_oracle (agent-mode only)  ───────────
		weakTool(
			name: ToolNames.askOracle,
			description: """
Agent-mode oracle send/continue tool.

Use this to start or continue an oracle conversation in `chat`, `plan`, or `review` mode for the current agent tab.

Pass `export_response: true` to write the response to a shareable file and get back shareable `oracle_export_path` / `oracle_export_instruction` values. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

Use `oracle_chat_log` after compaction to recover recent oracle messages.
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				properties: [
					"message": .string(
						description: "Your message to send",
						minLength: 1
					),
					"mode": .string(
						description: "Operation mode",
						default: "chat",
						enum: ["chat", "plan", "review"]
					),
					"chat_id": .string(
						description: "Continue a specific chat in the current agent tab"
					),
					"new_chat": .boolean(
						description: "Start a new chat session (default: false; discouraged)"
					),
					"export_response": .boolean(
						description: "When true, export the response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt."
					)
				],
				required: ["message"]
			)
		) { owner, args in
			try await owner.oracleToolService.executeAskOracle(args: args)
		},

		// ───────────  oracle_send  ───────────
		weakTool(
			name: ToolNames.oracleSend,
			description: """
Consult a second AI for planning, review, or questions.

Use this to start or continue an oracle conversation in `chat`, `plan`, `edit`, or `review` mode.
Use `oracle_utils` for passive helpers like models and sessions.

Pass `export_response: true` to write the response to a shareable file and get back shareable `oracle_export_path` / `oracle_export_instruction` values. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

Build context first with file reads, `manage_selection`, or `workspace_context`.
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				properties: [
					"message": .string(
						description: "Your message to send",
						minLength: 1
					),
					"mode": .string(
						description: "Operation mode",
						default: "chat",
						enum: ["chat", "plan", "edit", "review"]
					),
					"chat_id": .string(
						description: "Continue a specific chat in the current tab or current context"
					),
					"new_chat": .boolean(
						description: "Start a new chat session (default: false; discouraged)"
					),
					"model": .string(
						description: "Model preset ID or name override"
					),
					"export_response": .boolean(
						description: "When true, export the response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt."
					)
				],
				required: ["message"]
			)
		) { owner, args in
			try await owner.oracleToolService.executeOracleSend(args: args)
		},

		// ───────────  oracle_chat_log  ───────────
		weakTool(
			name: ToolNames.oracleChatLog,
			description: """
Read recent Oracle conversation messages to recover context during agent mode.

Returns the tail of an Oracle chat as lightweight `{ role, text }` objects. Available only during agent mode runs.

**Parameters**:
- `chat_id` (optional): Target a specific Oracle chat (short ID or UUID). Omit to read the most recent one.
- `limit` (optional): Number of messages to return (default: 8, range: 1–50)
- `include_user` (optional): Include your own messages in output (default: false)
""",
			annotations: .repoPromptLocalReadOnly,
			inputSchema: .object(
				properties: [
					"chat_id": .string(description: "Chat ID (short ID or UUID) to read"),
					"limit": .integer(description: "Max number of messages to return (default: 8, min: 1, max: 50)"),
					"include_user": .boolean(description: "Include user messages in output (default: false)")
				],
				required: []
			)
		) { owner, args in
			try await owner.oracleToolService.executeOracleChatLog(args: args)
		},

		]
		// Append context_builder and ask_user tools separately to reduce type inference complexity
		var tools = coreTools
		tools.append(buildGitTool())
		tools.append(buildDiscoverContextTool())
		tools.append(buildAskUserTool())
		tools.append(buildAgentExploreTool())
		tools.append(buildAgentRunTool())
		tools.append(buildAgentManageTool())
		// Agent mode tools
		tools.append(buildShareThoughtsTool())
		tools.append(buildSetStatusTool())
		tools.append(buildWaitForNextInstructionTool())
		return tools
	}
	@MainActor
	private func buildGitTool() -> Tool {
		weakTool(
			name: ToolNames.git,
			description: """
Safe, read-only git operations.

**Operations**: status | diff | log | show | blame

**Compare specs** (for diff/show):
| Spec | Meaning |
|------|--------|
| `uncommitted` | Working dir vs HEAD (default) |
| `staged` | Staged changes vs HEAD |
| `unstaged` | Working dir vs staged |
| `back:N` | HEAD~N..HEAD |
| `mergebase:X` | Working dir vs merge-base with X |
| `main` | Working dir vs merge-base with trunk branch (auto-detected) |
| `uncommitted:main` | Uncommitted vs merge-base with trunk branch |
| `staged:main` | Staged vs merge-base with trunk branch |
| `trunk` | Alias for `main` |
| `last` | vs CURRENT snapshot |
| `<snapshot_id>` | vs specific snapshot |
| `<revspec>` | Any git revspec |

**Detail levels** (for diff/show):
- `summary` (default): Totals only
- `files`: File list with stats
- `patches`: Patch hunks, truncated for safety (~300 lines)
- `full`: Patch hunks, untruncated (may be large)

**Publishing artifacts** (`artifacts=true`):
Writes snapshot files to disk for persistent reference. **Required for ask_oracle review mode** to include git diff context.
- Creates MAP.txt, files.tsv, and optional patches
- Primary review artifacts are auto-selected into context when possible
- `mode`: "quick" | "standard" | "deep" (default: "standard")
- `scope`: "all" | "selected" — filter to selected files only

**Repo targeting**:
- Defaults to first loaded root's repo
- `repo_root`: Target specific repo (path or name)
- `repo_roots`: Array for multi-repo operations (status, diff)
- Tree specifiers: append `@wt` (explicit worktree), `@main` (main checkout), or `@main:<branch>` to target a worktree by branch (local branch name)

**Safety**: --no-ext-diff, --no-textconv, --color=never, GIT_TERMINAL_PROMPT=0

**Examples**:
- Status: `{"op":"status"}`
- Main checkout status: `{"op":"status","repo_root":"@main"}`
- Worktree by branch: `{"op":"status","repo_root":"@main:main"}`
- Diff vs trunk: `{"op":"diff","compare":"main"}`
- Quick diff: `{"op":"diff","detail":"files"}`
- Inline patches: `{"op":"diff","detail":"patches"}`
- Full untruncated diff: `{"op":"diff","detail":"full"}`
- Publish for review: `{"op":"diff","artifacts":true,"scope":"selected"}`
- Recent commits: `{"op":"log","count":5}`

Note: log/show/blame run on primary repo only with multi-root.
""",
			annotations: .repoPromptLocalReadOnly,
			inputSchema: .object(
				properties: [
					"op": .string(description: "Operation", enum: ["status", "diff", "log", "show", "blame"]),
					"repo_root": .string(description: "Repository root path inside a loaded root, or loaded root name (defaults to first loaded root). Supports @wt, @main, or @main:<branch> suffixes."),
					"repo_roots": .array(description: "Multiple repository root paths inside loaded roots, or root names (for multi-root operations). Supports @wt, @main, or @main:<branch> suffixes.", items: .string()),
					"repo_key": .string(description: "Repository key (optional alternative to repo_root)"),
					"compare": .string(description: "Compare spec for diff/show (supports main/trunk aliases)"),
					"detail": .string(description: "Detail level for diff/show", enum: ["summary", "files", "patches", "full"]),
					"mode": .string(description: "Artifact mode for diff", enum: ["quick", "standard", "deep"]),
					"scope": .string(description: "Diff scope", enum: ["all", "selected"]),
					"path": .string(description: "Single pathspec"),
					"paths": .array(description: "Multiple pathspecs", items: .string()),
					"context_lines": .integer(description: "Diff context lines"),
					"detect_renames": .boolean(description: "Enable rename detection"),
					"artifacts": .boolean(description: "Write snapshot artifacts (diff only); primary review artifacts are auto-selected into context when possible"),
					"inline": .object(
						properties: [
							"map": .boolean(description: "Include MAP excerpt"),
							"mode": .string(description: "Inline mode", enum: ["brief", "full"]),
							"max_lines": .integer(description: "Max MAP lines")
						],
						required: []
					),
					"ref": .string(description: "Ref for show operation"),
					"count": .integer(description: "Number of commits for log"),
					"lines": .string(description: "Line range for blame (e.g., \"45-60\")")
				],
				required: ["op"]
			)
		) { owner, args in
			let connectionID = ServerNetworkManager.currentConnectionID
			return try await owner.executeGitTool(args: args, connectionID: connectionID)
		}
	}

	private func executeGitTool(args: [String: Value], connectionID: UUID?) async throws -> ToolResultDTOs.GitToolReplyDTO {
		typealias Reply = ToolResultDTOs.GitToolReplyDTO

		enum GitOp: String {
			case status, diff, log, show, blame
		}

		let opRaw = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "status"
		guard let op = GitOp(rawValue: opRaw) else {
			throw MCPError.invalidParams("Invalid op: \(opRaw). Valid ops: status, diff, log, show, blame")
		}

		guard let workspaceManager else {
			throw MCPError.invalidParams("Workspace manager unavailable for git tool.")
		}
		guard let workspace = workspaceManager.activeWorkspace else {
			throw MCPError.invalidParams("No active workspace in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
		}
		let workspaceDirectory = workspaceManager.workspaceDirectory(for: workspace)
		let store = GitDiffSnapshotStore()
		let vcsService = VCSService.shared

		// Resolve repo roots (defaults to first loaded root)
		let visibleRoots = await MainActor.run { fileManager.visibleRootFolders }
		let allRepos = try await discoverAllGitRepos()
		let defaultRepo = try await resolveDefaultGitRepo()
		let explicitTokens = parseExplicitRepoRoots(from: args)

		var repos: [GitRepoDescriptor]

		// repo_key takes precedence - search all repos
		if let repoKey = args["repo_key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !repoKey.isEmpty {
			guard let match = allRepos.first(where: { $0.repoKey == repoKey }) else {
				let available = allRepos.map { $0.repoKey }.joined(separator: ", ")
				throw MCPError.invalidParams("repo_key not found: \(repoKey). Available: \(available)")
			}
			repos = [match]
		} else {
			// Resolve explicit tokens or use default
			repos = try await resolveGitRepoRoots(
				explicitRootTokens: explicitTokens,
				allRepos: allRepos,
				visibleRoots: visibleRoots,
				defaultRepo: defaultRepo
			)
		}

		// For now, use primary repo for single-repo operations
		// Multi-root execution will be implemented for operations that benefit from it (status, diff)
		let primaryRepo = repos[0]
		let repoURL = primaryRepo.rootURL
		let isMultiRepo = repos.count > 1
		let primaryWorktree = await buildWorktreeDTO(for: repoURL)
		let worktreeWarning = buildWorktreeWarning(from: primaryWorktree)

		// Helper: Build status breakdown from changed files
		func statusBreakdown(from files: [VCSUncommittedFile]) -> [String: Int]? {
			var counts: [String: Int] = [:]
			for file in files {
				counts[file.status, default: 0] += 1
			}
			return counts.isEmpty ? nil : counts
		}

		func statusBreakdownFromManifest(from files: [GitDiffSnapshotManifest.FileEntry]) -> [String: Int]? {
			var counts: [String: Int] = [:]
			for entry in files {
				guard let status = entry.status, !status.isEmpty else { continue }
				counts[status, default: 0] += 1
			}
			return counts.isEmpty ? nil : counts
		}

		func summaryDTO(summary: GitDiffSnapshotManifest.Summary, files: [GitDiffSnapshotManifest.FileEntry]) -> Reply.SummaryDTO {
			Reply.SummaryDTO(
				files: summary.files,
				insertions: summary.insertions,
				deletions: summary.deletions,
				byStatus: statusBreakdownFromManifest(from: files)
			)
		}

		func oneliner(files: Int, insertions: Int, deletions: Int) -> String {
			"\(files) files (+\(insertions) -\(deletions))"
		}

		func hunkDTOs(from hunks: [GitDiffPatchParsing.ParsedHunk], nilWhenEmpty: Bool) -> [Reply.DiffHunkDTO]? {
			if nilWhenEmpty, hunks.isEmpty { return nil }
			var dtos: [Reply.DiffHunkDTO] = []
			dtos.reserveCapacity(hunks.count)
			for hunk in hunks {
				dtos.append(Reply.DiffHunkDTO(header: hunk.header, oldStart: hunk.oldStart, newStart: hunk.newStart, patch: hunk.content))
			}
			return dtos
		}

		func diffFileDTOsWithoutHunks(from changedFiles: [VCSUncommittedFile]) -> [Reply.DiffFileDTO] {
			var files: [Reply.DiffFileDTO] = []
			files.reserveCapacity(changedFiles.count)
			for file in changedFiles {
				files.append(Reply.DiffFileDTO(path: file.path, status: file.status, insertions: file.additions, deletions: file.deletions, hunks: nil))
			}
			return files
		}

		func parsedFileHunks(from changedFiles: [VCSUncommittedFile], perFilePatches: [String: String]) -> [GitDiffPatchParsing.ParsedFileHunks] {
			let state = EditFlowPerf.begin(
				EditFlowPerf.Stage.Git.hunkParsing,
				EditFlowPerf.Dimensions(lineCount: changedFiles.count)
			)
			var parsedFiles: [GitDiffPatchParsing.ParsedFileHunks] = []
			parsedFiles.reserveCapacity(changedFiles.count)
			var patchBytes = 0
			var hunkCount = 0

			for file in changedFiles {
				guard let patchText = perFilePatches[file.path] else { continue }
				if state != nil {
					patchBytes += patchText.utf8.count
				}
				let hunks = patchText.isEmpty ? [] : GitDiffPatchParsing.parseHunks(from: patchText)
				hunkCount += hunks.count
				parsedFiles.append(GitDiffPatchParsing.ParsedFileHunks(
					path: file.path,
					status: file.status,
					insertions: file.additions ?? 0,
					deletions: file.deletions ?? 0,
					hunks: hunks
				))
			}

			EditFlowPerf.end(
				EditFlowPerf.Stage.Git.hunkParsing,
				state,
				EditFlowPerf.Dimensions(fileBytes: patchBytes, lineCount: changedFiles.count, chunkCount: hunkCount)
			)
			return parsedFiles
		}

		func buildWorktreeDTO(for repoURL: URL) async -> Reply.WorktreeDTO? {
			let backend = await vcsService.backend(forRepoRoot: repoURL)
			guard backend.kind == .git else { return nil }
			guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repoURL), layout.isWorktree else { return nil }

			let worktreeRoot = layout.workTreeRoot.path
			let worktreeName = layout.gitDir.lastPathComponent.isEmpty ? nil : layout.gitDir.lastPathComponent
			let commonGitDir = layout.commonDir.path
			let mainRoot = resolveMainWorktreeRoot(for: layout)

			let wtBranch = try? await backend.getCurrentBranch(at: repoURL)
			let wtHead = (try? await backend.getHeadID(at: repoURL)).map { String($0.prefix(7)) }

			var mainBranch: String?
			var mainHead: String?
			if let mainRoot {
				let mainBackend = await vcsService.backend(forRepoRoot: mainRoot)
				mainBranch = try? await mainBackend.getCurrentBranch(at: mainRoot)
				mainHead = (try? await mainBackend.getHeadID(at: mainRoot)).map { String($0.prefix(7)) }
			}

			return Reply.WorktreeDTO(
				isWorktree: true,
				worktreeName: worktreeName,
				worktreeRoot: worktreeRoot,
				commonGitDir: commonGitDir,
				mainWorktreeRoot: mainRoot?.path,
				worktreeBranch: wtBranch,
				mainBranch: mainBranch,
				worktreeHead: wtHead,
				mainHead: mainHead
			)
		}

		func buildWorktreeWarning(from worktree: Reply.WorktreeDTO?) -> String? {
			guard let worktree, worktree.isWorktree else { return nil }
			var parts: [String] = []
			parts.append("[Worktree] Git operations are scoped to this checkout.")
			if let branch = worktree.worktreeBranch {
				let head = worktree.worktreeHead.map { "@\($0)" } ?? ""
				parts.append("This: \(branch)\(head).")
			}
			if let mainRoot = worktree.mainWorktreeRoot {
				var mainLabel = "Main: \(mainRoot)"
				if let mainBranch = worktree.mainBranch {
					let head = worktree.mainHead.map { "@\($0)" } ?? ""
					mainLabel += " (\(mainBranch)\(head))"
				}
				parts.append(mainLabel + ".")
			}
			parts.append("Use repo_root=\"@main\" for main checkout, repo_root=\"@main:<branch>\" to target a worktree by branch, or compare=\"main\" for trunk diff.")
			return parts.joined(separator: " ")
		}

		func combineWarnings(_ warnings: [String?]) -> String? {
			let merged = warnings.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
			return merged.isEmpty ? nil : merged.joined(separator: "\n")
		}

		// MARK: Multi-root aggregate helpers

		/// Merge multiple byStatus dictionaries into one
		func mergeByStatus(_ dicts: [[String: Int]?]) -> [String: Int]? {
			var result: [String: Int] = [:]
			for dict in dicts.compactMap({ $0 }) {
				for (status, count) in dict {
					result[status, default: 0] += count
				}
			}
			return result.isEmpty ? nil : result
		}

		/// Compute aggregate totals from per-repo diff DTOs
		func aggregateTotals(from diffs: [Reply.DiffDTO]) -> Reply.TotalsDTO {
			var files = 0, insertions = 0, deletions = 0
			for diff in diffs {
				let t = diff.totals
				files += t.files
				insertions += t.insertions
				deletions += t.deletions
			}
			return Reply.TotalsDTO(files: files, insertions: insertions, deletions: deletions)
		}

		/// Build aggregate DTO from per-repo results
		func aggregateDTO(from repoDiffs: [Reply.DiffDTO], repoCount: Int) -> Reply.AggregateDTO {
			let totals = aggregateTotals(from: repoDiffs)
			let byStatus = mergeByStatus(repoDiffs.map { $0.byStatus })
			let onelinerStr = "\(repoCount) repos: \(totals.files) files (+\(totals.insertions) -\(totals.deletions))"
			return Reply.AggregateDTO(
				totals: totals,
				byStatus: byStatus,
				oneliner: onelinerStr,
				repoCount: repoCount
			)
		}

		func artifactsDTO(snapshotDirURL: URL, manifest: GitDiffSnapshotManifest) -> Reply.ArtifactsDTO {
			let fm = FileManager.default
			let changedLinesURL = snapshotDirURL.appendingPathComponent("index/changed_lines.tsv")
			let allPatchURL = snapshotDirURL.appendingPathComponent("diff/all.patch")
			let deepHunksURL = snapshotDirURL.appendingPathComponent("deep/hunks.jsonl")
			let deepChangedLinesURL = snapshotDirURL.appendingPathComponent("deep/changed_lines.tsv")
			return Reply.ArtifactsDTO(
				manifest: "manifest.json",
				map: "MAP.txt",
				filesTsv: "index/files.tsv",
				changedLines: fm.fileExists(atPath: changedLinesURL.path) ? "index/changed_lines.tsv" : nil,
				tree: "index/files.tree.txt",
				selectionPaths: manifest.requestedPaths == nil ? nil : "index/selection.paths.txt",
				allPatch: fm.fileExists(atPath: allPatchURL.path) ? "diff/all.patch" : nil,
				deepHunks: fm.fileExists(atPath: deepHunksURL.path) ? "deep/hunks.jsonl" : nil,
				deepChangedLines: fm.fileExists(atPath: deepChangedLinesURL.path) ? "deep/changed_lines.tsv" : nil
			)
		}

		func primaryArtifactsDTO(
			snapshotDir: String,
			artifacts: Reply.ArtifactsDTO,
			manifest: GitDiffSnapshotManifest,
			autoSelectedPaths: [String]
		) -> Reply.PrimaryArtifactsDTO {
			let primary = GitDiffSnapshotStore.primaryArtifacts(
				snapshotDir: snapshotDir,
				mapRelativePath: artifacts.map,
				allPatchRelativePath: artifacts.allPatch
			)
			let autoSelected = primary.selectionCandidates.filter { autoSelectedPaths.contains($0) }
			let perFilePatches = GitDiffSnapshotStore.perFilePatchArtifacts(snapshotDir: snapshotDir, files: manifest.files)
				.map {
					Reply.PrimaryArtifactsDTO.PerFilePatchDTO(
						jumpIndex: $0.jumpIndex,
						gitPath: $0.gitPath,
						selectionPath: $0.selectionPath,
						status: $0.status,
						additions: $0.additions,
						deletions: $0.deletions
					)
				}
			return Reply.PrimaryArtifactsDTO(
				map: primary.map,
				allPatch: primary.allPatch,
				autoSelected: autoSelected.isEmpty ? nil : autoSelected,
				perFilePatches: perFilePatches.isEmpty ? nil : perFilePatches
			)
		}

		func autoSelectPrimaryGitDiffArtifacts(paths: [String]) async -> [String] {
			guard !paths.isEmpty else { return [] }
			do {
				let context = try await self.requireCurrentTabContext(toolName: ToolNames.git)
				let result = await self.addPrimaryGitDiffArtifactsToSelection(existing: context.selection, paths: paths)
				if result.selection != context.selection {
					try await self.updateCurrentTabContext(toolName: ToolNames.git) { current in
						current.selection = result.selection
					}
				}
				return result.autoSelectedPaths
			} catch {
				mcpServerViewModelDebugLog("Auto-select git artifacts skipped: \(error.localizedDescription)")
				return []
			}
		}

		func inlineDTO(snapshotDirURL: URL, inlineMap: Bool, inlineMode: String, inlineMaxLines: Int) -> Reply.InlineDTO? {
			guard inlineMap else { return nil }
			let mapURL = snapshotDirURL.appendingPathComponent("MAP.txt")
			guard let mapText = try? String(contentsOf: mapURL, encoding: .utf8) else { return nil }
			let sections: [String]? = (inlineMode == "brief") ? ["SNAPSHOT_META", "CHANGED_FILE_TREE"] : nil
			let excerpt = GitDiffMapBuilder.inlineExcerpt(from: mapText, maxLines: inlineMaxLines, sections: sections)
			return Reply.InlineDTO(
				mapExcerpt: excerpt.excerpt,
				truncated: excerpt.truncated,
				totalLines: excerpt.totalLines,
				returnedLines: excerpt.returnedLines
			)
		}

		typealias SnapshotRef = GitDiffSnapshotStore.GitDiffSnapshotRef

		func resolveCurrentSnapshotRef(for repo: GitRepoDescriptor) throws -> SnapshotRef {
			if let currentID = store.readCurrentSnapshotID(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, fallbackToLegacy: false) {
				return SnapshotRef(repoKey: repo.repoKey, snapshotID: currentID)
			}
			throw MCPError.invalidParams("No CURRENT snapshot available for repo: \(repo.displayName).")
		}

		func resolveSnapshotRefArgument(
			snapshotIDRaw: String?,
			snapshotDirRaw: String?,
			preferredRepo: GitRepoDescriptor?
		) throws -> SnapshotRef {
			if let snapshotDirRaw, !snapshotDirRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				let trimmed = snapshotDirRaw.trimmingCharacters(in: .whitespacesAndNewlines)
				guard trimmed.hasPrefix("repos/") else {
					throw MCPError.invalidParams("snapshot_dir must be repo-scoped (repos/<repoKey>/<snapshotID>).")
				}
				guard let ref = store.parseSnapshotRef(trimmed) else {
					throw MCPError.invalidParams("Invalid snapshot_dir: \(snapshotDirRaw)")
				}
				return ref
			}
			guard let snapshotIDRaw else {
				throw MCPError.invalidParams("snapshot_id is required for op: \(opRaw)")
			}
			let trimmed = snapshotIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.isEmpty {
				throw MCPError.invalidParams("snapshot_id is required for op: \(opRaw)")
			}
			if trimmed.lowercased() == "current" {
				guard let preferredRepo else {
					throw MCPError.invalidParams("snapshot_id 'current' requires repo_root/repo_key or a single repo context.")
				}
				return try resolveCurrentSnapshotRef(for: preferredRepo)
			}
			guard let normalized = GitDiffSnapshotStore.normalizeSnapshotID(trimmed) else {
				throw MCPError.invalidParams("Invalid snapshot_id: \(trimmed)")
			}
			if let preferredRepo {
				if (try? store.readManifest(workspaceDirectory: workspaceDirectory, repoKey: preferredRepo.repoKey, snapshotID: normalized)) != nil {
					return SnapshotRef(repoKey: preferredRepo.repoKey, snapshotID: normalized)
				}
				throw MCPError.invalidParams("Snapshot not found: \(trimmed) in repo: \(preferredRepo.displayName)")
			}
			let refs = store.locateRepoScopedSnapshotRefs(workspaceDirectory: workspaceDirectory, snapshotID: normalized)
			if refs.count == 1 {
				return refs[0]
			}
			if refs.isEmpty {
				throw MCPError.invalidParams("Snapshot not found: \(trimmed)")
			}
			throw MCPError.invalidParams("Ambiguous snapshot_id: \(trimmed). Use snapshot_dir or repo_root/repo_key to disambiguate.")
		}

		func looksLikeSnapshotID(_ value: String) -> Bool {
			let parts = value.split(separator: "/")
			guard parts.count == 2 else { return false }
			let datePart = parts[0]
			let timePart = parts[1]
			guard datePart.count == 10 else { return false }
			let dateChars = Array(datePart)
			guard dateChars.indices.contains(4), dateChars.indices.contains(7) else { return false }
			if dateChars[4] != "-" || dateChars[7] != "-" { return false }
			let dateDigits = dateChars.enumerated().allSatisfy { idx, ch in
				if idx == 4 || idx == 7 { return true }
				return ch.isNumber
			}
			guard dateDigits else { return false }
			let timeParts = timePart.split(separator: "-", maxSplits: 1).map(String.init)
			guard let timeDigits = timeParts.first, timeDigits.count == 4, timeDigits.allSatisfy({ $0.isNumber }) else { return false }
			if timeParts.count == 2 {
				guard let suffix = timeParts.last, !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { return false }
			}
			return true
		}

		func detectMainBranchRef(repoURL: URL) async -> String? {
			let backend = await vcsService.backend(forRepoRoot: repoURL)
			let remoteBranches = (try? await backend.getRemoteBranches(at: repoURL, limit: 200).map(\.name)) ?? []
			let localBranches = (try? await backend.getLocalBranches(at: repoURL, limit: 200).map(\.name)) ?? []

			func pick(_ candidates: [String], in list: [String]) -> String? {
				for candidate in candidates where list.contains(candidate) {
					return candidate
				}
				return nil
			}

			if let ref = pick(["origin/main", "upstream/main"], in: remoteBranches) { return ref }
			if let ref = pick(["main"], in: localBranches) { return ref }
			if let ref = pick(["origin/master", "upstream/master"], in: remoteBranches) { return ref }
			if let ref = pick(["master"], in: localBranches) { return ref }
			if let upstream = try? await backend.getUpstreamRef(at: repoURL), !upstream.isEmpty {
				return upstream
			}

			return nil
		}

		func resolveCompareSpec(_ compareRaw: String) async throws -> (spec: GitDiffCompareSpec, resolved: String, input: String?) {
			try await resolveCompareSpec(compareRaw, for: primaryRepo)
		}

		func resolveCompareSpec(_ compareRaw: String, for repo: GitRepoDescriptor) async throws -> (spec: GitDiffCompareSpec, resolved: String, input: String?) {
			let trimmed = compareRaw.trimmingCharacters(in: .whitespacesAndNewlines)
			let rawInput = trimmed.isEmpty ? "uncommitted" : trimmed
			let lowered = rawInput.lowercased()

			if lowered == "main" || lowered == "trunk" {
				guard let mainRef = await detectMainBranchRef(repoURL: repo.rootURL) else {
					throw MCPError.invalidParams("compare=\"\(rawInput)\" could not be resolved. Try compare=\"origin/main\" or compare=\"mergebase:origin/main\".")
				}
				let spec = GitDiffCompareSpec.uncommittedMergeBase(base: mainRef)
				return (spec, spec.displayString, rawInput)
			}

			if lowered.hasPrefix("uncommitted:") || lowered.hasPrefix("staged:") {
				let parts = rawInput.split(separator: ":", maxSplits: 1).map(String.init)
				if parts.count == 2 {
					let mode = parts[0].lowercased()
					let base = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
					let baseLowered = base.lowercased()
					if baseLowered == "main" || baseLowered == "trunk" {
						guard let mainRef = await detectMainBranchRef(repoURL: repo.rootURL) else {
							throw MCPError.invalidParams("compare=\"\(rawInput)\" could not be resolved. Try compare=\"\(mode):origin/main\".")
						}
						let spec: GitDiffCompareSpec = (mode == "staged") ? .stagedMergeBase(base: mainRef) : .uncommittedMergeBase(base: mainRef)
						return (spec, spec.displayString, rawInput)
					}
				}
			}

			if lowered == "last" {
				// Try repo-scoped CURRENT only
				guard let currentID = store.readCurrentSnapshotID(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, fallbackToLegacy: false) else {
					throw MCPError.invalidParams("No CURRENT snapshot available for compare: \"last\" in repo: \(repo.displayName)")
				}
				guard let manifest = try? store.readManifest(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, snapshotID: currentID) else {
					throw MCPError.invalidParams("Unable to read CURRENT snapshot manifest for repo: \(repo.displayName)")
				}
				let spec = GitDiffCompareSpec.uncommitted(base: manifest.fingerprint.headSHA)
				return (spec, spec.displayString, rawInput)
			}

			// Try to resolve as snapshot ID (repo-scoped only)
			if let normalized = GitDiffSnapshotStore.normalizeSnapshotID(rawInput) {
				if let manifest = try? store.readManifest(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, snapshotID: normalized) {
					let spec = GitDiffCompareSpec.uncommitted(base: manifest.fingerprint.headSHA)
					return (spec, spec.displayString, rawInput)
				}
				if looksLikeSnapshotID(normalized) {
					throw MCPError.invalidParams("Snapshot not found for compare: \(rawInput) in repo: \(repo.displayName)")
				}
			}

			let spec = GitDiffCompareSpec.parse(rawInput)
			let resolved = spec.displayString
			let input = (resolved == rawInput) ? nil : rawInput
			return (spec, resolved, input)
		}

		// Collect pathspecs from path/paths args
		func collectPathspecs() -> [String]? {
			var pathspecs: [String] = []
			if let single = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !single.isEmpty {
				pathspecs.append(single)
			}
			if let arr = args["paths"]?.arrayValue {
				for item in arr {
					if let p = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
						pathspecs.append(p)
					}
				}
			}
			return pathspecs.isEmpty ? nil : pathspecs
		}

		switch op {
		// MARK: - Status
		case .status:
			// Multi-root: run status for each repo
			if isMultiRepo {
				var perRepoResults: [Reply.RepoResultDTO] = []
				for repo in repos {
					do {
						let backend = await vcsService.backend(forRepoRoot: repo.rootURL)
						let branch = try? await backend.getCurrentBranch(at: repo.rootURL)
						let upstream = try? await backend.getUpstreamRef(at: repo.rootURL)
						var ahead: Int?
						var behind: Int?
						if let upstream {
							if let ab = try? await backend.getAheadBehind(vs: upstream, at: repo.rootURL) {
								ahead = ab.ahead
								behind = ab.behind
							}
						}
						let workingStatus = try await backend.getWorkingStatus(at: repo.rootURL)
						let repoWorktree = await buildWorktreeDTO(for: repo.rootURL)
						let summaryStr: String = {
							var parts: [String] = []
							if let b = branch { parts.append(b) }
							if let a = ahead, let b = behind {
								parts.append("+\(a) -\(b)")
							}
							let counts = [
								workingStatus.staged.count > 0 ? "\(workingStatus.staged.count) staged" : nil,
								workingStatus.modified.count > 0 ? "\(workingStatus.modified.count) modified" : nil,
								workingStatus.untracked.count > 0 ? "\(workingStatus.untracked.count) untracked" : nil
							].compactMap { $0 }
							if !counts.isEmpty {
								parts.append(counts.joined(separator: ", "))
							}
							return parts.joined(separator: " | ")
						}()

						perRepoResults.append(Reply.RepoResultDTO(
							repoRoot: repo.rootPath,
							repoKey: repo.repoKey,
							repoName: repo.displayName,
							status: Reply.StatusDTO(
								branch: branch,
								upstream: upstream,
								ahead: ahead,
								behind: behind,
								staged: workingStatus.staged,
								modified: workingStatus.modified,
								untracked: workingStatus.untracked,
								summary: summaryStr
							),
							worktree: repoWorktree
						))
					} catch {
						perRepoResults.append(Reply.RepoResultDTO(
							repoRoot: repo.rootPath,
							repoKey: repo.repoKey,
							repoName: repo.displayName,
							error: error.localizedDescription
						))
					}
				}
				return Reply(op: "status", repos: perRepoResults)
			}

			// Single repo: legacy behavior
			let backend = await vcsService.backend(forRepoRoot: repoURL)
			let branch = try? await backend.getCurrentBranch(at: repoURL)
			let upstream = try? await backend.getUpstreamRef(at: repoURL)
			var ahead: Int?
			var behind: Int?
			if let upstream {
				if let ab = try? await backend.getAheadBehind(vs: upstream, at: repoURL) {
					ahead = ab.ahead
					behind = ab.behind
				}
			}
			let workingStatus = try await backend.getWorkingStatus(at: repoURL)
			let summaryStr: String = {
				var parts: [String] = []
				if let b = branch { parts.append(b) }
				if let a = ahead, let b = behind {
					parts.append("+\(a) -\(b)")
				}
				let counts = [
					workingStatus.staged.count > 0 ? "\(workingStatus.staged.count) staged" : nil,
					workingStatus.modified.count > 0 ? "\(workingStatus.modified.count) modified" : nil,
					workingStatus.untracked.count > 0 ? "\(workingStatus.untracked.count) untracked" : nil
				].compactMap { $0 }
				if !counts.isEmpty {
					parts.append(counts.joined(separator: ", "))
				}
				return parts.joined(separator: " | ")
			}()

			return Reply(
				op: "status",
				status: Reply.StatusDTO(
					branch: branch,
					upstream: upstream,
					ahead: ahead,
					behind: behind,
					staged: workingStatus.staged,
					modified: workingStatus.modified,
					untracked: workingStatus.untracked,
					summary: summaryStr
				),
				diff: nil, log: nil, show: nil, blame: nil,
				worktree: primaryWorktree,
				snapshotId: nil, snapshotDir: nil,
				artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
				warning: worktreeWarning,
				emptyReason: nil, error: nil
			)

		// MARK: - Log
		case .log:
			let count = args["count"]?.intValue ?? 10
			let path = args["path"]?.stringValue
			let logBackend = await vcsService.backend(forRepoRoot: repoURL)
			let commits = try await logBackend.getLogSummaries(count: count, path: path, at: repoURL)
			let commitDTOs = commits.map { c in
				Reply.CommitSummaryDTO(
					sha: c.id,
					shortSha: c.shortID,
					author: c.author,
					date: c.dateISO,
					message: c.message,
					filesChanged: c.filesChanged,
					insertions: c.insertions,
					deletions: c.deletions
				)
			}
			// Warn if multiple repos detected but log only runs on primary
			let logWarning: String? = isMultiRepo ? "Multiple repos detected; op 'log' ran against \(primaryRepo.displayName). Provide repo_root to target a specific repo." : nil
			let combinedWarning = combineWarnings([logWarning, worktreeWarning])
			return Reply(
				op: "log",
				status: nil,
				diff: nil,
				log: Reply.LogDTO(commits: commitDTOs),
				show: nil, blame: nil,
				worktree: primaryWorktree,
				snapshotId: nil, snapshotDir: nil,
				artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
				warning: combinedWarning, emptyReason: nil, error: nil
			)

		// MARK: - Show
		case .show:
			guard let ref = args["ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else {
				throw MCPError.invalidParams("ref is required for op: show")
			}
			let rawShowDetail = args["detail"]?.stringValue?.lowercased() ?? "summary"
			// For show, "patches" behaves the same as "full" (single commit, no truncation needed)
			let detail = rawShowDetail == "patches" ? "full" : rawShowDetail
			let showBackend = await vcsService.backend(forRepoRoot: repoURL)
			let commitInfo = try await showBackend.getCommitInfo(ref: ref, at: repoURL)

			// Get diff for this commit
			let revspec = "\(ref)^!"
			let contextLines = args["context_lines"]?.intValue ?? 3
			let detectRenames = args["detect_renames"]?.boolValue ?? false
			let changedFiles = try await showBackend.getChangedFilesStats(
				compare: .revspec(revspec),
				includeUntrackedWhenApplicable: false,
				detectRenames: detectRenames,
				at: repoURL
			)

			let totalFiles = changedFiles.count
			let totalInsertions = changedFiles.reduce(0) { $0 + ($1.additions ?? 0) }
			let totalDeletions = changedFiles.reduce(0) { $0 + ($1.deletions ?? 0) }

			var files: [Reply.DiffFileDTO]?

			if detail == "files" || detail == "full" {
				files = diffFileDTOsWithoutHunks(from: changedFiles)
			}

			if detail == "full" {
				let diffText = try await showBackend.getDiffText(
					compare: .revspec(revspec),
					paths: nil,
					contextLines: contextLines,
					detectRenames: detectRenames,
					at: repoURL
				)
				// Split multi-file diff into per-file patches, then parse hunks per file
				let perFilePatches = GitService.splitUnifiedDiffByFile(diffText)

				// Rebuild files array with hunks attached to each file
				let state = EditFlowPerf.begin(
					EditFlowPerf.Stage.Git.hunkParsing,
					EditFlowPerf.Dimensions(lineCount: changedFiles.count)
				)
				var parsedPatchBytes = 0
				var parsedHunkCount = 0
				var filesWithHunks: [Reply.DiffFileDTO] = []
				filesWithHunks.reserveCapacity(changedFiles.count)
				for file in changedFiles {
					let patchText = perFilePatches[file.path] ?? ""
					if state != nil {
						parsedPatchBytes += patchText.utf8.count
					}
					let parsedHunks = patchText.isEmpty ? [] : GitDiffPatchParsing.parseHunks(from: patchText)
					parsedHunkCount += parsedHunks.count
					filesWithHunks.append(Reply.DiffFileDTO(
						path: file.path,
						status: file.status,
						insertions: file.additions,
						deletions: file.deletions,
						hunks: hunkDTOs(from: parsedHunks, nilWhenEmpty: true)
					))
				}
				EditFlowPerf.end(
					EditFlowPerf.Stage.Git.hunkParsing,
					state,
					EditFlowPerf.Dimensions(fileBytes: parsedPatchBytes, lineCount: changedFiles.count, chunkCount: parsedHunkCount)
				)
				files = filesWithHunks
				// hunks is now nil at top level since hunks are attached to individual files
			}

			// Warn if multiple repos detected but show only runs on primary
			let showWarning: String? = isMultiRepo ? "Multiple repos detected; op 'show' ran against \(primaryRepo.displayName). Provide repo_root to target a specific repo." : nil
			let combinedWarning = combineWarnings([showWarning, worktreeWarning])
			return Reply(
				op: "show",
				status: nil, diff: nil, log: nil,
				show: Reply.ShowDTO(
					sha: commitInfo.id,
					shortSha: commitInfo.shortID,
					author: commitInfo.author,
					date: commitInfo.dateISO,
					message: commitInfo.message,
					files: files,
					totals: Reply.TotalsDTO(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
					hunks: nil
				),
				blame: nil,
				worktree: primaryWorktree,
				snapshotId: nil, snapshotDir: nil,
				artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
				warning: combinedWarning, emptyReason: nil, error: nil
			)

		// MARK: - Blame
		case .blame:
			guard let path = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
				throw MCPError.invalidParams("path is required for op: blame")
			}
			var lineRange: ClosedRange<Int>?
			if let linesStr = args["lines"]?.stringValue {
				let parts = linesStr.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
				if parts.count == 2, let start = parts[0], let end = parts[1], start <= end {
					lineRange = start...end
				}
			}

			// If path is absolute, route to owning repo; otherwise use primary
			var targetRepoURL = repoURL
			var blameWarning: String? = nil
			if path.hasPrefix("/") {
				// Find owning repo by longest-prefix match
				let standardized = (path as NSString).standardizingPath
				if let owningRepo = owningRepo(forAbsolutePath: standardized, repos: repos) {
					targetRepoURL = owningRepo.rootURL
					if isMultiRepo && owningRepo.repoKey != primaryRepo.repoKey {
						blameWarning = "Path routed to repo: \(owningRepo.displayName)"
					}
				}
			} else if isMultiRepo {
				blameWarning = "Multiple repos detected; op 'blame' ran against \(primaryRepo.displayName). Provide repo_root or absolute path to target a specific repo."
			}

			let blameBackend = await vcsService.backend(forRepoRoot: targetRepoURL)
			let blameLines = try await blameBackend.blame(path: path, lineRange: lineRange, at: targetRepoURL)
			let blameWorktree = await buildWorktreeDTO(for: targetRepoURL)
			let combinedWarning = combineWarnings([blameWarning, buildWorktreeWarning(from: blameWorktree)])
			let lineDTOs = blameLines.map { l in
				Reply.BlameLineDTO(num: l.line, sha: l.id, author: l.author, date: l.dateISO, content: l.content)
			}
			return Reply(
				op: "blame",
				status: nil, diff: nil, log: nil, show: nil,
				blame: Reply.BlameDTO(path: path, lines: lineDTOs),
				worktree: blameWorktree,
				snapshotId: nil, snapshotDir: nil,
				artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
				warning: combinedWarning, emptyReason: nil, error: nil
			)

		// MARK: - Diff
		case .diff:
			let compareRaw = args["compare"]?.stringValue ?? "uncommitted"
			let detail = args["detail"]?.stringValue?.lowercased() ?? "summary"
			let artifacts = args["artifacts"]?.boolValue ?? false
			let pathspecs = collectPathspecs()
			let contextLines = args["context_lines"]?.intValue ?? 3
			let detectRenames = args["detect_renames"]?.boolValue ?? false

			// For multi-root, don't auto-upgrade to full detail (could explode output)
			let effectiveDetail: String
			if pathspecs?.count == 1, detail == "summary", !isMultiRepo {
				effectiveDetail = "patches"
			} else {
				effectiveDetail = detail
			}

			// detail="patches" is truncated (~300 lines); detail="full" is untruncated.
			let maxLinesForPatches: Int = effectiveDetail == "full" ? Int.max : 300

			// If artifacts requested, use the publisher
			if artifacts {
				let modeRaw = args["mode"]?.stringValue?.lowercased() ?? "standard"
				guard let mode = GitDiffPublishMode(rawValue: modeRaw) else {
					throw MCPError.invalidParams("Invalid mode: \(modeRaw)")
				}
				let scopeRaw = args["scope"]?.stringValue?.lowercased() ?? "all"
				guard let scope = GitDiffScope(rawValue: scopeRaw) else {
					throw MCPError.invalidParams("Invalid scope: \(scopeRaw)")
				}
				let snapshotIDOverride: String? = {
					guard let raw = args["snapshot_id"]?.stringValue else { return nil }
					let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
					if trimmed.isEmpty || trimmed.lowercased() == "auto" { return nil }
					return GitDiffSnapshotStore.normalizeSnapshotID(trimmed)
				}()

				let inlineObj = args["inline"]?.objectValue
				let inlineMap = inlineObj?["map"]?.boolValue ?? true
				let inlineMode = inlineObj?["mode"]?.stringValue?.lowercased() ?? "brief"
				let inlineMaxLines = max(1, inlineObj?["max_lines"]?.intValue ?? 120)

				// Resolve selected paths using current exec context (bound tab or active tab fallback)
				// For scope .all, no selection is needed
				let allSelectedAbsolutePaths: [String]
				if scope == .selected {
					let selectedFiles = await selectedVMsForCurrentExecContext()
					allSelectedAbsolutePaths = selectedFiles.map { $0.standardizedFullPath }
				} else {
					allSelectedAbsolutePaths = []
				}

				let publisher = GitDiffSnapshotPublisher.shared

				// Multi-root artifact diff
				if isMultiRepo {
					var perRepoResults: [Reply.RepoResultDTO] = []
					var collectedDiffs: [Reply.DiffDTO] = []
					var manifestsBySnapshotDir: [String: GitDiffSnapshotManifest] = [:]
					let tabID = boundTabID(forConnection: connectionID)

					// Group selection paths by repo
					let pathsByRepo = scope == .selected ? groupAbsolutePathsByRepo(paths: allSelectedAbsolutePaths, repos: repos) : [:]

					for repo in repos {
						do {
							let repoCompare = try await resolveCompareSpec(compareRaw, for: repo)
							let repoWorktree = await buildWorktreeDTO(for: repo.rootURL)
							let repoSelectedPaths = scope == .selected ? (pathsByRepo[repo] ?? []) : []
							if scope == .selected, repoSelectedPaths.isEmpty {
								perRepoResults.append(Reply.RepoResultDTO(
									repoRoot: repo.rootPath,
									repoKey: repo.repoKey,
									repoName: repo.displayName,
									worktree: repoWorktree,
									emptyReason: "No selected paths in this repo"
								))
								continue
							}

							let manifest = try await publisher.publish(
								workspaceDirectory: workspaceDirectory,
								repo: repo,
								mode: mode,
								compareSpec: repoCompare.spec,
								compareDisplay: repoCompare.resolved,
								compareInput: repoCompare.input,
								scope: scope,
								selectedAbsolutePaths: repoSelectedPaths,
								contextLines: contextLines,
								detectRenames: detectRenames,
								snapshotIDOverride: snapshotIDOverride,
								tabID: tabID
							)
							let snapshotID = manifest.snapshotID
							let snapshotDirURL = store.snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, snapshotID: snapshotID)
							let snapshotDirRel = store.snapshotRelativePath(repoKey: repo.repoKey, snapshotID: snapshotID)
							let summary = summaryDTO(summary: manifest.summary, files: manifest.files)
							let emptyReason = GitDiffMapBuilder.emptyReason(
								summary: manifest.summary,
								scope: manifest.scope,
								requestedPaths: manifest.requestedPaths,
								compareRaw: manifest.compare
							)

							let diffDTO = Reply.DiffDTO(
								compare: repoCompare.resolved,
								detail: nil,
								files: nil,
								totals: Reply.TotalsDTO(files: summary.files, insertions: summary.insertions, deletions: summary.deletions),
								byStatus: summary.byStatus,
								oneliner: oneliner(files: summary.files, insertions: summary.insertions, deletions: summary.deletions),
								truncated: nil,
								truncationNote: nil
							)
							collectedDiffs.append(diffDTO)

							let artifacts = artifactsDTO(snapshotDirURL: snapshotDirURL, manifest: manifest)
							manifestsBySnapshotDir[snapshotDirRel] = manifest
							perRepoResults.append(Reply.RepoResultDTO(
								repoRoot: repo.rootPath,
								repoKey: repo.repoKey,
								repoName: repo.displayName,
								diff: diffDTO,
								worktree: repoWorktree,
								snapshotId: snapshotID,
								snapshotDir: snapshotDirRel,
								artifacts: artifacts,
								summary: summary,
								oneliner: "\(summary.files) files (+\(summary.insertions) -\(summary.deletions)) | \(snapshotDirRel)",
								inputs: Reply.DiffInputsDTO(
									compare: manifest.compare,
									compareInput: manifest.compareInput,
									scope: manifest.scope.rawValue,
									requestedPathsCount: manifest.requestedPaths?.count,
									contextLines: manifest.contextLines,
									detectRenames: manifest.detectRenames
								),
								modeDetails: GitDiffMapBuilder.modeDetails(for: mode),
								inline: inlineDTO(snapshotDirURL: snapshotDirURL, inlineMap: inlineMap, inlineMode: inlineMode, inlineMaxLines: inlineMaxLines),
								emptyReason: emptyReason
							))
						} catch {
							perRepoResults.append(Reply.RepoResultDTO(
								repoRoot: repo.rootPath,
								repoKey: repo.repoKey,
								repoName: repo.displayName,
								error: error.localizedDescription
							))
						}
					}

					await fileManager.ensureGitDataRootLoaded(workspace: workspace, workspaceManager: workspaceManager)
					await fileManager.flushPendingDeltas(aggressive: true)
					let primaryArtifactCandidates = perRepoResults.flatMap { repoResult -> [String] in
						guard let snapshotDir = repoResult.snapshotDir,
							  let artifacts = repoResult.artifacts else {
							return []
						}
						return GitDiffSnapshotStore.primaryArtifacts(
							snapshotDir: snapshotDir,
							mapRelativePath: artifacts.map,
							allPatchRelativePath: artifacts.allPatch
						).selectionCandidates
					}
					let autoSelectedPrimaryArtifacts = await autoSelectPrimaryGitDiffArtifacts(paths: primaryArtifactCandidates)
					let decoratedRepoResults = perRepoResults.map { repoResult in
						guard let snapshotDir = repoResult.snapshotDir,
							  let artifacts = repoResult.artifacts,
							  let manifest = manifestsBySnapshotDir[snapshotDir] else {
							return repoResult
						}
						return Reply.RepoResultDTO(
							repoRoot: repoResult.repoRoot,
							repoKey: repoResult.repoKey,
							repoName: repoResult.repoName,
							status: repoResult.status,
							diff: repoResult.diff,
							log: repoResult.log,
							show: repoResult.show,
							blame: repoResult.blame,
							worktree: repoResult.worktree,
							snapshotId: repoResult.snapshotId,
							snapshotDir: snapshotDir,
							artifacts: artifacts,
							primaryArtifacts: primaryArtifactsDTO(snapshotDir: snapshotDir, artifacts: artifacts, manifest: manifest, autoSelectedPaths: autoSelectedPrimaryArtifacts),
							summary: repoResult.summary,
							oneliner: repoResult.oneliner,
							inputs: repoResult.inputs,
							modeDetails: repoResult.modeDetails,
							inline: repoResult.inline,
							warning: repoResult.warning,
							emptyReason: repoResult.emptyReason,
							error: repoResult.error
						)
					}

					let aggregate = aggregateDTO(from: collectedDiffs, repoCount: repos.count)
					return Reply(op: "diff", repos: decoratedRepoResults, aggregate: aggregate)
				}

				// Single repo artifact diff (legacy behavior)
				let compare = try await resolveCompareSpec(compareRaw)

				// Get normalization warning (e.g., staged/unstaged degraded to uncommitted for jj)
				let normalizedResult = await vcsService.normalizeCompareSpec(compare.spec, at: repoURL)
				let artifactDiffWarning = normalizedResult.warning
				let combinedWarning = combineWarnings([artifactDiffWarning, worktreeWarning])

				let tabID = boundTabID(forConnection: connectionID)
				let manifest = try await publisher.publish(
					workspaceDirectory: workspaceDirectory,
					repo: primaryRepo,
					mode: mode,
					compareSpec: compare.spec,
					compareDisplay: compare.resolved,
					compareInput: compare.input,
					scope: scope,
					selectedAbsolutePaths: allSelectedAbsolutePaths,
					contextLines: contextLines,
					detectRenames: detectRenames,
					snapshotIDOverride: snapshotIDOverride,
					tabID: tabID
				)

				await fileManager.ensureGitDataRootLoaded(workspace: workspace, workspaceManager: workspaceManager)
				await fileManager.flushPendingDeltas(aggressive: true)
				let snapshotID = manifest.snapshotID
				let snapshotDirURL = store.snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: primaryRepo.repoKey, snapshotID: snapshotID)
				let snapshotDirRel = store.snapshotRelativePath(repoKey: primaryRepo.repoKey, snapshotID: snapshotID)
				let artifacts = artifactsDTO(snapshotDirURL: snapshotDirURL, manifest: manifest)
				let primaryArtifacts = GitDiffSnapshotStore.primaryArtifacts(
					snapshotDir: snapshotDirRel,
					mapRelativePath: artifacts.map,
					allPatchRelativePath: artifacts.allPatch
				)
				let autoSelectedPrimaryArtifacts = await autoSelectPrimaryGitDiffArtifacts(paths: primaryArtifacts.selectionCandidates)
				let summary = summaryDTO(summary: manifest.summary, files: manifest.files)
				let emptyReason = GitDiffMapBuilder.emptyReason(
					summary: manifest.summary,
					scope: manifest.scope,
					requestedPaths: manifest.requestedPaths,
					compareRaw: manifest.compare
				)

				return Reply(
					op: "diff",
					status: nil,
					diff: Reply.DiffDTO(
						compare: compare.resolved,
						detail: nil,
						files: nil,
						totals: Reply.TotalsDTO(files: summary.files, insertions: summary.insertions, deletions: summary.deletions),
						byStatus: summary.byStatus,
						oneliner: oneliner(files: summary.files, insertions: summary.insertions, deletions: summary.deletions),
						truncated: nil,
						truncationNote: nil
					),
					log: nil, show: nil, blame: nil,
					worktree: primaryWorktree,
					snapshotId: snapshotID,
					snapshotDir: snapshotDirRel,
					artifacts: artifacts,
					primaryArtifacts: primaryArtifactsDTO(snapshotDir: snapshotDirRel, artifacts: artifacts, manifest: manifest, autoSelectedPaths: autoSelectedPrimaryArtifacts),
					summary: summary,
					oneliner: "\(summary.files) files (+\(summary.insertions) -\(summary.deletions)) | \(snapshotDirRel)",
					inputs: Reply.DiffInputsDTO(
						compare: manifest.compare,
						compareInput: manifest.compareInput,
						scope: manifest.scope.rawValue,
						requestedPathsCount: manifest.requestedPaths?.count,
						contextLines: manifest.contextLines,
						detectRenames: manifest.detectRenames
					),
					modeDetails: GitDiffMapBuilder.modeDetails(for: mode),
					inline: inlineDTO(snapshotDirURL: snapshotDirURL, inlineMap: inlineMap, inlineMode: inlineMode, inlineMaxLines: inlineMaxLines),
					warning: combinedWarning,
					emptyReason: emptyReason,
					error: nil
				)
			}

			// Non-artifact diff
			let engine = GitDiffEngine.shared
			let includesHunks = effectiveDetail == "patches" || effectiveDetail == "full"

			// Multi-root non-artifact diff
			if isMultiRepo {
				var perRepoResults: [Reply.RepoResultDTO] = []
				var collectedDiffs: [Reply.DiffDTO] = []

				for repo in repos {
					do {
						let repoCompare = try await resolveCompareSpec(compareRaw, for: repo)
						let repoWorktree = await buildWorktreeDTO(for: repo.rootURL)

						let buildResult = try await engine.buildSnapshotInputs(
							compare: repoCompare.spec,
							pathspecs: pathspecs,
							repoURL: repo.rootURL,
							contextLines: contextLines,
							detectRenames: detectRenames,
							generateDiffText: includesHunks
						)

						let totalFiles = buildResult.summary.files
						let totalInsertions = buildResult.summary.insertions
						let totalDeletions = buildResult.summary.deletions
						let byStatus = statusBreakdown(from: buildResult.changedFiles)

						var files: [Reply.DiffFileDTO]?
						var truncated: Bool?
						var truncationNote: String?

						if effectiveDetail == "files" || includesHunks {
							files = diffFileDTOsWithoutHunks(from: buildResult.changedFiles)
						}

						if includesHunks, let _ = buildResult.diffText {
							let perFile = buildResult.perFile ?? [:]
							let parsedFiles = parsedFileHunks(from: buildResult.changedFiles, perFilePatches: perFile)

							let truncResult = GitDiffPatchParsing.truncatePatches(files: parsedFiles, maxLines: maxLinesForPatches)
							truncated = truncResult.truncated
							truncationNote = truncResult.note

							var truncatedFiles: [Reply.DiffFileDTO] = []
							truncatedFiles.reserveCapacity(truncResult.files.count)
							for file in truncResult.files {
								truncatedFiles.append(Reply.DiffFileDTO(
									path: file.path,
									status: file.status,
									insertions: file.insertions,
									deletions: file.deletions,
									hunks: hunkDTOs(from: file.hunks, nilWhenEmpty: false)
								))
							}
							files = truncatedFiles
						}

						let diffDTO = Reply.DiffDTO(
							compare: repoCompare.resolved,
							detail: effectiveDetail,
							files: files,
							totals: Reply.TotalsDTO(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
							byStatus: byStatus,
							oneliner: oneliner(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
							truncated: truncated,
							truncationNote: truncationNote
						)
						collectedDiffs.append(diffDTO)

						perRepoResults.append(Reply.RepoResultDTO(
							repoRoot: repo.rootPath,
							repoKey: repo.repoKey,
							repoName: repo.displayName,
							diff: diffDTO,
							worktree: repoWorktree
						))
					} catch {
						perRepoResults.append(Reply.RepoResultDTO(
							repoRoot: repo.rootPath,
							repoKey: repo.repoKey,
							repoName: repo.displayName,
							error: error.localizedDescription
						))
					}
				}

				let aggregate = aggregateDTO(from: collectedDiffs, repoCount: repos.count)
				return Reply(op: "diff", repos: perRepoResults, aggregate: aggregate)
			}

			// Single repo non-artifact diff (legacy behavior)
			let compare = try await resolveCompareSpec(compareRaw)

			// Get normalization warning (e.g., staged/unstaged degraded to uncommitted for jj)
			let normalizedResult = await vcsService.normalizeCompareSpec(compare.spec, at: repoURL)
			let diffWarning = normalizedResult.warning
			let combinedWarning = combineWarnings([diffWarning, worktreeWarning])

			let buildResult = try await engine.buildSnapshotInputs(
				compare: compare.spec,
				pathspecs: pathspecs,
				repoURL: repoURL,
				contextLines: contextLines,
				detectRenames: detectRenames,
				generateDiffText: includesHunks
			)

			let totalFiles = buildResult.summary.files
			let totalInsertions = buildResult.summary.insertions
			let totalDeletions = buildResult.summary.deletions
			let byStatus = statusBreakdown(from: buildResult.changedFiles)

			var files: [Reply.DiffFileDTO]?
			var truncated: Bool?
			var truncationNote: String?

			if effectiveDetail == "files" || includesHunks {
				files = diffFileDTOsWithoutHunks(from: buildResult.changedFiles)
			}

			if includesHunks, buildResult.diffText != nil {
				let perFile = buildResult.perFile ?? [:]
				let parsedFiles = parsedFileHunks(from: buildResult.changedFiles, perFilePatches: perFile)

				let truncResult = GitDiffPatchParsing.truncatePatches(files: parsedFiles, maxLines: maxLinesForPatches)
				truncated = truncResult.truncated
				truncationNote = truncResult.note

				var truncatedFiles: [Reply.DiffFileDTO] = []
				truncatedFiles.reserveCapacity(truncResult.files.count)
				for file in truncResult.files {
					truncatedFiles.append(Reply.DiffFileDTO(
						path: file.path,
						status: file.status,
						insertions: file.insertions,
						deletions: file.deletions,
						hunks: hunkDTOs(from: file.hunks, nilWhenEmpty: false)
					))
				}
				files = truncatedFiles
			}

			return Reply(
				op: "diff",
				status: nil,
				diff: Reply.DiffDTO(
					compare: compare.resolved,
					detail: effectiveDetail,
					files: files,
					totals: Reply.TotalsDTO(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
					byStatus: byStatus,
					oneliner: oneliner(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
					truncated: truncated,
					truncationNote: truncationNote
				),
				log: nil, show: nil, blame: nil,
				worktree: primaryWorktree,
				snapshotId: nil, snapshotDir: nil,
				artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
				warning: combinedWarning, emptyReason: nil, error: nil
			)

		}
	}

	private func relativePath(from base: URL, to url: URL) -> String {
		let basePath = (base.path as NSString).standardizingPath
		let targetPath = (url.path as NSString).standardizingPath
		if targetPath.hasPrefix(basePath) {
			var rel = String(targetPath.dropFirst(basePath.count))
			if rel.hasPrefix("/") { rel.removeFirst() }
			return rel
		}
		return url.path
	}

	private func resolveGitRepoURL(preferredRootPath: String?) async throws -> URL {
		let vcsService = VCSService.shared
		var candidates: [String] = []
		if let preferredRootPath, !preferredRootPath.isEmpty {
			candidates.append(preferredRootPath)
		}
		let visibleRoots = await MainActor.run {
			fileManager.visibleRootFolders.map(\.fullPath)
		}
		candidates.append(contentsOf: visibleRoots)
		var seen = Set<String>()
		for path in candidates {
			let standardized = (path as NSString).standardizingPath
			let key = standardized.lowercased()
			guard seen.insert(key).inserted else { continue }
			if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: standardized)) {
				return resolved.rootURL
			}
		}
		throw MCPError.invalidParams("No VCS repository found in loaded roots.")
	}

	// MARK: - Multi-root git helpers

	/// Discover all git repos from visible root folders.
	/// - Returns: Array of GitRepoDescriptor for all discovered repos
	private func discoverAllGitRepos() async throws -> [GitRepoDescriptor] {
		let vcsService = VCSService.shared
		let visibleRoots = await MainActor.run {
			fileManager.visibleRootFolders
		}

		var seenPaths = Set<String>()
		var repos: [GitRepoDescriptor] = []

		for folder in visibleRoots {
			let standardized = (folder.fullPath as NSString).standardizingPath
			let key = standardized.lowercased()
			guard seenPaths.insert(key).inserted else { continue }

			if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: standardized)) {
				let repoPath = (resolved.rootURL.path as NSString).standardizingPath
				let repoKey = repoPath.lowercased()
				// Only add if we haven't seen this repo root yet
				if !repos.contains(where: { $0.rootPath.lowercased() == repoKey }) {
					repos.append(GitRepoDescriptor(rootURL: resolved.rootURL))
				}
			}
		}

		return repos
	}

	/// Resolve the default git repo (first loaded root's repo).
	/// - Returns: The first git repo found from visible roots in order
	private func resolveDefaultGitRepo() async throws -> GitRepoDescriptor {
		let vcsService = VCSService.shared
		let visibleRoots = await MainActor.run {
			fileManager.visibleRootFolders
		}

		// Return the first visible root that is inside a VCS repo
		for folder in visibleRoots {
			let standardized = (folder.fullPath as NSString).standardizingPath
			if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: standardized)) {
				return GitRepoDescriptor(rootURL: resolved.rootURL)
			}
		}

		throw MCPError.invalidParams("No VCS repository found in loaded roots.")
	}

	private enum RepoTreeSpecifier {
		case worktree(branch: String?)
		case main(branch: String?)

		var branch: String? {
			switch self {
			case .worktree(let branch), .main(let branch):
				return branch
			}
		}

		var isMainSelector: Bool {
			if case .main = self {
				return true
			}
			return false
		}
	}

	private func parseRepoTreeSpecifier(_ token: String) -> (base: String, specifier: RepoTreeSpecifier?) {
		let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let atIndex = trimmed.lastIndex(of: "@") else {
			return (trimmed, nil)
		}
		let suffix = String(trimmed[trimmed.index(after: atIndex)...])
		let base = String(trimmed[..<atIndex])
		let parts = suffix.split(separator: ":", maxSplits: 1).map(String.init)
		let spec = parts.first?.lowercased() ?? ""
		let branchPart = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
		let branch = (branchPart?.isEmpty ?? true) ? nil : branchPart
		switch spec {
		case "wt", "worktree":
			return (base, .worktree(branch: branch))
		case "main", "primary":
			return (base, .main(branch: branch))
		default:
			return (trimmed, nil)
		}
	}

	private func resolveMainWorktreeRoot(for layout: GitRepositoryLayout) -> URL? {
		let candidate: URL
		if layout.commonDir.lastPathComponent == ".git" {
			candidate = layout.commonDir.deletingLastPathComponent()
		} else {
			candidate = layout.commonDir
		}
		return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
	}

	private func readHeadRef(from headURL: URL) -> String? {
		guard let raw = try? String(contentsOf: headURL, encoding: .utf8) else {
			return nil
		}
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.hasPrefix("ref:") else {
			return nil
		}
		return trimmed.replacingOccurrences(of: "ref:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func matchesBranch(_ requested: String, headRef: String) -> Bool {
		let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return false }
		if headRef == trimmed { return true }
		if headRef.hasPrefix("refs/heads/") {
			let short = String(headRef.dropFirst("refs/heads/".count))
			return short == trimmed
		}
		return false
	}

	private func resolveWorktreeRootFromEntry(_ entryURL: URL) -> URL? {
		let gitdirURL = entryURL.appendingPathComponent("gitdir")
		guard let raw = try? String(contentsOf: gitdirURL, encoding: .utf8) else {
			return nil
		}
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		let resolvedGitdir: URL
		if trimmed.hasPrefix("/") {
			resolvedGitdir = URL(fileURLWithPath: trimmed)
		} else {
			resolvedGitdir = entryURL.appendingPathComponent(trimmed)
		}
		return resolvedGitdir.deletingLastPathComponent().standardizedFileURL
	}

	private func resolveWorktreeRoot(forBranch branch: String, layout: GitRepositoryLayout) -> URL? {
		let target = branch.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !target.isEmpty else { return nil }
		let fileManager = FileManager.default
		let worktreesDir = layout.commonDir.appendingPathComponent("worktrees", isDirectory: true)
		var isDir: ObjCBool = false
		if fileManager.fileExists(atPath: worktreesDir.path, isDirectory: &isDir), isDir.boolValue {
			if let entries = try? fileManager.contentsOfDirectory(at: worktreesDir, includingPropertiesForKeys: [.isDirectoryKey]) {
				for entry in entries {
					var isEntryDir: ObjCBool = false
					guard fileManager.fileExists(atPath: entry.path, isDirectory: &isEntryDir), isEntryDir.boolValue else { continue }
					let headURL = entry.appendingPathComponent("HEAD")
					guard let headRef = readHeadRef(from: headURL), matchesBranch(target, headRef: headRef) else {
						continue
					}
					if let root = resolveWorktreeRootFromEntry(entry) {
						return root
					}
				}
			}
		}
		if let mainRoot = resolveMainWorktreeRoot(for: layout) {
			let headURL = layout.commonDir.appendingPathComponent("HEAD")
			if let headRef = readHeadRef(from: headURL), matchesBranch(target, headRef: headRef) {
				return mainRoot
			}
		}
		return nil
	}

	private func applyTreeSpecifier(_ specifier: RepoTreeSpecifier?, to repo: GitRepoDescriptor) throws -> GitRepoDescriptor {
		guard let specifier else {
			return repo
		}
		switch specifier {
		case .worktree(let branch):
			if let branch, !branch.isEmpty {
				throw MCPError.invalidParams("repo_root selector '@wt:\(branch)' is not supported. Use '@main:\(branch)' to target a worktree by branch or omit the branch.")
			}
			return repo
		case .main(let branch):
			if let branch, !branch.isEmpty {
				guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repo.rootURL) else {
					throw MCPError.invalidParams("repo_root selector '@main:\(branch)' requires a git repository.")
				}
				if let root = resolveWorktreeRoot(forBranch: branch, layout: layout) {
					return GitRepoDescriptor(rootURL: root)
				}
				throw MCPError.invalidParams("No worktree found for branch '\(branch)'. Use repo_root=\"@main\" for the main checkout or pass a full worktree path.")
			}
			guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repo.rootURL), layout.isWorktree else {
				return repo
			}
			guard let mainRoot = resolveMainWorktreeRoot(for: layout) else {
				return repo
			}
			return GitRepoDescriptor(rootURL: mainRoot)
		}
	}


	/// Resolve a repo root token (path or name) to a GitRepoDescriptor.
	/// - Parameters:
	///   - token: The repo root token (path or loaded root name)
	///   - allRepos: All available repos to match against
	///   - visibleRoots: Visible root folders for name matching
	/// - Returns: The matched GitRepoDescriptor
	private func resolveRepoRootToken(
		_ token: String,
		allRepos: [GitRepoDescriptor],
		visibleRoots: [FolderViewModel],
		defaultRepo: GitRepoDescriptor
	) async throws -> GitRepoDescriptor {
		let vcsService = VCSService.shared
		let (baseToken, specifier) = parseRepoTreeSpecifier(token)
		let trimmed = baseToken.trimmingCharacters(in: .whitespacesAndNewlines)

		if trimmed.isEmpty {
			return try applyTreeSpecifier(specifier, to: defaultRepo)
		}

		// Check if it looks like a path (contains / or starts with ~ or .)
		let looksLikePath = trimmed.contains("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".")

		if looksLikePath {
			let visibleRootPaths = visibleRoots.map(\.fullPath)
			guard GitRepoRootAuthorization.isPathWithinAuthorizedRoots(trimmed, roots: visibleRootPaths) else {
				let rootsList = visibleRootPaths.joined(separator: ", ")
				throw MCPError.invalidParams("repo_root path must be inside a loaded root. Received: \(trimmed). Loaded roots: \(rootsList)")
			}

			let standardized = GitRepoRootAuthorization.canonicalPath(trimmed)

			// Find the VCS root for this path
			if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: standardized)) {
				let repo = GitRepoDescriptor(rootURL: resolved.rootURL)
				return try applyTreeSpecifier(specifier, to: repo)
			}
			throw MCPError.invalidParams("No VCS repository found at path: \(trimmed)")
		}

		// Treat as a name - match against visible root folder names and repo display names
		let lowercasedToken = trimmed.lowercased()

		// First try matching against visible root folder names
		for folder in visibleRoots {
			if folder.name.lowercased() == lowercasedToken {
				let standardized = (folder.fullPath as NSString).standardizingPath
				if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: standardized)) {
					let repo = GitRepoDescriptor(rootURL: resolved.rootURL)
					return try applyTreeSpecifier(specifier, to: repo)
				}
			}
		}

		// Then try matching against repo display names
		let matches = allRepos.filter { $0.displayName.lowercased() == lowercasedToken }
		if matches.count == 1 {
			return try applyTreeSpecifier(specifier, to: matches[0])
		} else if matches.count > 1 {
			let paths = matches.map { $0.rootPath }.joined(separator: ", ")
			throw MCPError.invalidParams("Ambiguous repo name '\(trimmed)' matches multiple repos: \(paths). Use full path or repo_key to disambiguate.")
		}

		// No match found - provide helpful error
		let availableNames = visibleRoots.map { $0.name }.joined(separator: ", ")
		throw MCPError.invalidParams("No repo found matching '\(trimmed)'. Available root names: \(availableNames)")
	}

	/// Resolve git repository roots for operations.
	/// - Parameters:
	///   - explicitRootTokens: Optional explicit repo root tokens from tool args (repo_root or repo_roots)
	///   - allRepos: All discovered repos (for name matching)
	///   - visibleRoots: Visible root folders (for name matching)
	///   - defaultRepo: The default repo to use when no explicit roots provided
	/// - Returns: Array of GitRepoDescriptor for the resolved repos
	private func resolveGitRepoRoots(
		explicitRootTokens: [String]?,
		allRepos: [GitRepoDescriptor],
		visibleRoots: [FolderViewModel],
		defaultRepo: GitRepoDescriptor
	) async throws -> [GitRepoDescriptor] {
		// If no explicit roots provided, return the default repo
		guard let tokens = explicitRootTokens, !tokens.isEmpty else {
			return [defaultRepo]
		}

		// Resolve each token
		var repos: [GitRepoDescriptor] = []
		var seenKeys = Set<String>()

		for token in tokens {
			let repo = try await resolveRepoRootToken(
				token,
				allRepos: allRepos,
				visibleRoots: visibleRoots,
				defaultRepo: defaultRepo
			)
			let key = repo.rootPath.lowercased()
			if seenKeys.insert(key).inserted {
				repos.append(repo)
			}
		}

		guard !repos.isEmpty else {
			throw MCPError.invalidParams("No git repository found for specified roots.")
		}

		return repos
	}

	/// Group absolute paths by their owning repo
	/// - Parameters:
	///   - paths: Absolute file paths to group
	///   - repos: Available repo descriptors
	/// - Returns: Dictionary mapping repo to its paths
	private func groupAbsolutePathsByRepo(
		paths: [String],
		repos: [GitRepoDescriptor]
	) -> [GitRepoDescriptor: [String]] {
		var result: [GitRepoDescriptor: [String]] = [:]
		for repo in repos {
			result[repo] = []
		}

		for path in paths {
			let standardized = (path as NSString).standardizingPath
			// Find the repo with the longest matching prefix
			var bestMatch: GitRepoDescriptor?
			var bestLength = 0
			for repo in repos {
				if repo.contains(absolutePath: standardized) {
					if repo.rootPath.count > bestLength {
						bestMatch = repo
						bestLength = repo.rootPath.count
					}
				}
			}
			if let match = bestMatch {
				result[match, default: []].append(standardized)
			}
		}

		return result
	}

	private func owningRepo(forAbsolutePath path: String, repos: [GitRepoDescriptor]) -> GitRepoDescriptor? {
		var bestMatch: GitRepoDescriptor?
		var bestLength = 0
		for repo in repos {
			if repo.contains(absolutePath: path), repo.rootPath.count > bestLength {
				bestMatch = repo
				bestLength = repo.rootPath.count
			}
		}
		return bestMatch
	}

	/// Parse repo_root and repo_roots args into explicit root paths
	private func parseExplicitRepoRoots(from args: [String: Value]) -> [String]? {
		var roots: [String] = []

		// Single repo_root
		if let single = args["repo_root"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
			!single.isEmpty {
			roots.append(single)
		}

		// Array of repo_roots
		if let arr = args["repo_roots"]?.arrayValue {
			for item in arr {
				if let path = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
					!path.isEmpty {
					roots.append(path)
				}
			}
		}

		return roots.isEmpty ? nil : roots
	}

	// MARK: - Discovery-Only Tools

	// MARK: - Discover Context Tool (separated to reduce type inference complexity)

	@MainActor
	private func buildDiscoverContextTool() -> Tool {
		let impl: @Sendable (MCPServerViewModel, [String: Value]) async throws -> Value = { owner, args in
			// Capture once at tool entry so long runs don't rely on TaskLocal.
			let connectionID = ServerNetworkManager.currentConnectionID
			let result = try await owner.executeDiscoverContext(args: args, connectionID: connectionID)
			return result.toMCPValue()
		}
		return weakTool(
			name: "context_builder",
			description: """
Intelligently explore the codebase and build optimal file context for a task.

A discovery agent analyzes your codebase, selects relevant files within a token budget, and rewrites your instructions into a clarified prompt. Describe **what** you need, not **where** to look — the agent discovers the right files autonomously. Mention what you know and what you're unsure about; being too prescriptive narrows discovery.

**response_type** (what happens after context building):
| Type | Behavior |
|------|----------|
| (omit) or `clarify` | Context only — returns selection and prompt for you to use |
| `question` | Answers a question about the codebase using built context |
| `plan` | Generates implementation plan for the task |
| `review` | Generates code review with git diff context |

**Structuring instructions** (XML tags):
- `<task>`: Main goal
- `<context>`: Background, constraints, known file references
- `<discovery_agent-guidelines>`: Optional starting hints for the agent (not passed to follow-up model). The agent explores beyond these freely — omit if you don't have specific leads.

**Example**:
```
<task>Add user authentication using JWT</task>
<context>The app has an existing session system. See docs/auth-spec.md for requirements.</context>
<discovery_agent-guidelines>There may be auth-related code in src/auth/ already</discovery_agent-guidelines>
```

**Exporting**: Pass `export_response: true` (requires a `response_type` that generates a response) to write the result to a file and get back `oracle_export_path` plus `oracle_export_instruction`. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

**Workflow**: Continue with `ask_oracle(chat_id: "<returned_id>", new_chat: false)`. Refine with `manage_selection`.

**Agent mode behavior**: If this tool is invoked during an Agent Mode run, it reuses the current agent tab instead of creating a new tab.

**Timing**: 30s-5min depending on codebase size and task complexity.
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				properties: [
					"instructions": .string(description: "Your request, ideally structured with XML tags: <task> for the main goal, <context> for background/constraints/file references, <discovery_agent-guidelines> for optional starting hints. Describe what you need — the agent finds the right files."),
					"response_type": .string(description: "Optional: 'plan' to generate implementation plan, 'question' to ask a question, or 'review' to generate a code review. Omit or 'clarify' to just return context.", enum: ["plan", "question", "review", "clarify"]),
					"export_response": .boolean(description: "When true, export the generated response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Requires a response_type that generates a response. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt.")
				],
				required: []
			),
			implementation: impl
		)
	}

	// MARK: - Ask User Tool (Discovery-Only)

	/// Build the ask_user tool that allows discovery agents to ask clarifying questions.
	/// Unified ask_user tool for both discovery and agent mode runs.
	/// Routes to the appropriate UI based on the connection's run purpose.
	/// Only visible to connections that have been granted it via additionalTools.
	@MainActor
	private func buildAskUserTool() -> Tool {
		let impl: @Sendable (MCPServerViewModel, [String: Value]) async throws -> Value = { owner, args in
			let result = try await owner.executeAskUser(args: args)
			return result
		}
		return weakTool(
			name: "ask_user",
			description: """
Ask the user a clarifying question and wait for their response.

Use this tool to gather additional context or clarification from the user.
The tool will block until the user responds.

**When to use:**
- Task requirements are ambiguous
- Multiple valid approaches exist and you need user preference
- Critical context is missing
- Confirming before making significant changes

**Best practices:**
- Ask early, not at the end
- Be specific - explain what you're trying to determine
- Provide options when the choices are clear
- Limit questions to avoid disrupting the user

**Input:**
- `questions`: Required array of structured questions. Each question requires stable `id` and `question` fields. Maximum 10 questions per request. Use `allows_multiple` and `allows_custom` for selection/custom-answer behavior.
- `title`: Optional title for the wizard card.
- `context`: Optional overall context shown above the questions.
- `timeout_seconds`: Optional timeout in seconds for the whole interaction.

**Response:**
- `answers`: Object keyed by question ID. Each value contains `answers`, `selected_options`, `custom_response`, and `skipped`.
- `timed_out`: True if the interaction timed out.
- `skipped`: True if the user skipped the whole interaction.
- `elapsed_seconds`: How long the user took to respond.
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				properties: [
					"title": .string(description: "Optional title shown above the question wizard."),
					"context": .string(description: "Optional overall context shown above the wizard."),
					"timeout_seconds": .integer(description: "Timeout in seconds for the whole interaction."),
					"questions": .array(
						description: "One or more structured questions to ask as a single wizard.",
						items: .object(
							properties: [
								"id": .string(description: "Stable unique question ID used as the response key."),
								"header": .string(description: "Optional short heading for this question."),
								"question": .string(description: "Question text to show the user."),
								"context": .string(description: "Optional per-question context."),
								"options": .array(
									description: "Optional suggested answers.",
									items: .object(
										properties: [
											"label": .string(description: "Option label returned when selected."),
											"description": .string(description: "Optional option description shown to the user.")
										],
										required: ["label"]
									)
								),
								"allows_multiple": .boolean(description: "When true, the user can select multiple options. Default is false."),
								"allows_custom": .boolean(description: "When true, the user can type one custom response. Default is true.")
							],
							required: ["id", "question"]
						)
					)
				],
				required: ["questions"]
			),
			implementation: impl
		)
	}

	/// Execute the ask_user tool - routes to appropriate UI based on run purpose.
	private func executeAskUser(args: [String: Value]) async throws -> Value {
		// Get connection ID and determine run purpose for routing
		guard let connectionID = ServerNetworkManager.currentConnectionID else {
			throw MCPError.invalidParams("ask_user requires an active MCP connection")
		}
		let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)

		// Get target window
		let targetWindow = try requireTargetWindow()

		// Resolve timeout: use explicit value from caller, or workspace setting
		let workspaceTimeout = await MainActor.run { targetWindow.discoverAgentViewModel.questionTimeoutSeconds }
		let interaction = try parseAskUserInteraction(args: args, defaultTimeout: workspaceTimeout)

		let response: AgentAskUserResponse
		switch purpose {
		case .discoverRun:
			let tabContext = try await requireCurrentTabContext(toolName: "ask_user")
			guard tabContext.runID != nil else {
				throw MCPError.invalidParams("ask_user requires an active discovery run with tab context")
			}
			response = try await targetWindow.discoverAgentViewModel.askUserInteraction(
				tabID: tabContext.tabID,
				interaction: interaction
			)

		case .agentModeRun:
			let tabID = try await resolveTabIDForAgentMode(
				args: args,
				connectionID: connectionID
			)
			// For non-MCP-controlled sessions, surface the tab so the user can
			// see and answer the question. MCP-controlled runs handle interactions
			// programmatically via `respond`, so pulling focus would be disruptive.
			if !targetWindow.agentModeViewModel.isMCPControlled(tabID: tabID) {
				_ = await targetWindow.revealPendingInteraction(
					tabID: tabID,
					surface: .agentQuestion
				)
			}
			response = try await targetWindow.agentModeViewModel.askUserInteraction(
				tabID: tabID,
				interaction: interaction
			)

		case .delegateEditRun:
			throw MCPError.invalidParams("ask_user is not available during delegate edit runs")

		case .unknown:
			throw MCPError.invalidParams("ask_user is only available during discovery or agent mode runs")
		}

		return askUserResponseValue(response)
	}

	private func parseAskUserInteraction(args: [String: Value], defaultTimeout: TimeInterval) throws -> AgentAskUserInteraction {
		if args["question"] != nil || args["options"] != nil || args["multi_select"] != nil || args["allow_custom"] != nil || args["allows_multiple"] != nil || args["allows_custom"] != nil {
			throw MCPError.invalidParams("ask_user now requires a structured questions array; top-level question/options/multi_select/allow_custom are no longer supported. Send { \"questions\": [{ \"id\": \"q1\", \"question\": \"...\" }] } instead.")
		}

		let timeoutSeconds: TimeInterval
		if let timeoutValue = args["timeout_seconds"] {
			guard let timeoutInt = timeoutValue.intValue, timeoutInt > 0 else {
				throw MCPError.invalidParams("timeout_seconds must be a positive integer.")
			}
			timeoutSeconds = TimeInterval(timeoutInt)
		} else {
			timeoutSeconds = defaultTimeout
		}

		guard let questionValues = args["questions"]?.arrayValue else {
			throw MCPError.invalidParams("ask_user requires a questions array.")
		}
		guard !questionValues.isEmpty else {
			throw MCPError.invalidParams("ask_user requires at least one question.")
		}
		let maxQuestionCount = 10
		guard questionValues.count <= maxQuestionCount else {
			throw MCPError.invalidParams("ask_user supports at most \(maxQuestionCount) questions per request.")
		}

		let questions = try questionValues.enumerated().map { index, value in
			try parseAskUserQuestion(value, index: index)
		}
		let interaction = AgentAskUserInteraction(
			title: normalizedAskUserString(args["title"]),
			context: normalizedAskUserString(args["context"]),
			timeoutSeconds: timeoutSeconds,
			questions: questions
		)
		do {
			try interaction.validate()
		} catch {
			throw MCPError.invalidParams(error.localizedDescription)
		}
		return interaction
	}

	private func parseAskUserQuestion(_ value: Value, index: Int) throws -> AgentAskUserQuestion {
		guard let object = value.objectValue else {
			throw MCPError.invalidParams("questions[\(index)] must be an object.")
		}
		guard let id = normalizedAskUserString(object["id"]) else {
			throw MCPError.invalidParams("questions[\(index)].id is required.")
		}
		guard let questionText = normalizedAskUserString(object["question"]) else {
			throw MCPError.invalidParams("questions[\(index)].question is required.")
		}
		let options = try parseAskUserOptions(object["options"], questionID: id)
		if object["multi_select"] != nil {
			throw MCPError.invalidParams("questions[\(index)].multi_select has been renamed to questions[\(index)].allows_multiple.")
		}
		if object["allow_custom"] != nil {
			throw MCPError.invalidParams("questions[\(index)].allow_custom has been renamed to questions[\(index)].allows_custom.")
		}
		let allowsMultiple = try optionalAskUserBool(object["allows_multiple"], name: "questions[\(index)].allows_multiple") ?? false
		let allowsCustom = try optionalAskUserBool(object["allows_custom"], name: "questions[\(index)].allows_custom") ?? true
		return AgentAskUserQuestion(
			id: id,
			header: normalizedAskUserString(object["header"]),
			question: questionText,
			context: normalizedAskUserString(object["context"]),
			options: options,
			allowsMultiple: allowsMultiple,
			allowsCustom: allowsCustom
		)
	}

	private func parseAskUserOptions(_ value: Value?, questionID: String) throws -> [AgentAskUserOption] {
		guard let value else { return [] }
		guard let optionValues = value.arrayValue else {
			throw MCPError.invalidParams("questions['\(questionID)'].options must be an array of option objects.")
		}
		return try optionValues.enumerated().map { index, value in
			guard let object = value.objectValue else {
				throw MCPError.invalidParams("questions['\(questionID)'].options[\(index)] must be an object.")
			}
			guard let label = normalizedAskUserString(object["label"]) else {
				throw MCPError.invalidParams("questions['\(questionID)'].options[\(index)].label is required.")
			}
			return AgentAskUserOption(
				label: label,
				description: normalizedAskUserString(object["description"])
			)
		}
	}

	private func normalizedAskUserString(_ value: Value?) -> String? {
		guard let raw = value?.stringValue else { return nil }
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	private func optionalAskUserBool(_ value: Value?, name: String) throws -> Bool? {
		guard let value else { return nil }
		guard let bool = value.boolValue else {
			throw MCPError.invalidParams("\(name) must be a boolean.")
		}
		return bool
	}

	private func askUserResponseValue(_ response: AgentAskUserResponse) -> Value {
		.object([
			"answers": .object(response.answersByQuestionID.reduce(into: [String: Value]()) { partialResult, entry in
				partialResult[entry.key] = askUserAnswerValue(entry.value)
			}),
			"timed_out": .bool(response.timedOut),
			"skipped": .bool(response.skipped),
			"elapsed_seconds": .int(response.elapsedSeconds)
		])
	}

	private func askUserAnswerValue(_ answer: AgentAskUserAnswer) -> Value {
		.object([
			"answers": .array(answer.answers.map { .string($0) }),
			"selected_options": .array(answer.selectedOptions.map { .string($0) }),
			"custom_response": answer.customResponse.map { .string($0) } ?? .null,
			"skipped": .bool(answer.skipped)
		])
	}

	// MARK: - Agent Mode Tools

	@MainActor
	private func buildAgentExploreTool() -> Tool {
		let impl: @Sendable (MCPServerViewModel, [String: Value]) async throws -> Value = { owner, args in
			try await owner.agentExploreToolService.execute(args: args)
		}
		return weakTool(
			name: ToolNames.agentExplore,
			description: """
Short-lived, read-only explore child agents for narrow codebase probes. Each child runs in a fresh session with its own context window. Always uses the `explore` role; no custom `model_id`, workflows, session reuse, `steer`, or `respond`.

**Operations**: start | poll | wait | cancel

- `start`: Launch one or more fresh explore sessions. Provide `message` for one probe or `messages` for multiple probes. Batch starts wait for the first referenced session to finish or need input unless `detach=true`.
- `poll`: Return current snapshot immediately for `session_id` or `session_ids`.
- `wait`: Block until the first referenced explore run finishes or needs input. `timeout=0` behaves like poll.
- `cancel`: Cancel a live explore child session.

Explore children are read-only — no edits, oracle calls, or further sub-agent spawning.
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				description: """
Provide `op` plus operation-specific fields.

**start**: message or messages (required, mutually exclusive), detach?, timeout?
**poll / wait**: session_id or session_ids (mutually exclusive), timeout? (wait only)
**cancel**: session_id (required)
""",
				properties: [
					"op": .string(description: "Operation.", enum: ["start", "poll", "wait", "cancel"]),
					"message": .string(description: "[start] Exploration instruction text for one fresh explore child. Mutually exclusive with messages."),
					"messages": .array(description: "[start] Array of exploration instruction strings. Mutually exclusive with message. Starts one fresh explore child per entry.", items: .string()),
					"detach": .boolean(description: "[start] Return immediately instead of waiting. Default false."),
					"timeout": .number(description: "[start, wait] Max wait seconds. 0 = poll. Default 300."),
					"session_id": .string(description: "[poll, wait, cancel] Explore child session UUID returned by start."),
					"session_ids": .array(description: "[wait, poll] Array of explore child session UUIDs. Mutually exclusive with session_id.", items: .string())
				],
				required: ["op"]
			),
			implementation: impl
		)
	}

	@MainActor
	private func buildAgentRunTool() -> Tool {
		let impl: @Sendable (MCPServerViewModel, [String: Value]) async throws -> Value = { owner, args in
			try await owner.agentRunToolService.execute(args: args)
		}
		let messageDescription = "[start, steer] Instruction text. Required for start and steer. If sharing an exported plan, include the path/instruction directly in this text."
		return weakTool(
			name: ToolNames.agentRun,
			description: """
Spawn and control Agent Mode sessions. `start` always creates a new session/tab; use `steer` to continue an existing session.

**Role labels** — pass as `model_id` to select via the global role-default mapping:
- `explore` — Fast exploration and codebase mapping
- `engineer` — Balanced engineering work
- `pair` — Interactive pair programming with highest-tier models
- `design` — Architecture, design discussions, creative problem solving; writes a markdown review document (saved under `docs/reviews/`, `docs/designs/`, or `docs/analysis/`) as its primary deliverable for review/analysis tasks

Role labels resolve through the effective global role-default mapping; see the top-level `task_labels` array from `agent_manage.list_agents` for the authoritative label→model mapping. If `model_id` is omitted on `start`, RepoPrompt uses the `pair` role. To pin an exact agent+model+effort target, pass a specific compound `model_id` from `agents[].models[].model_id` in the same response.

**Operations**: start | poll | wait | cancel | steer | respond

- `start`: Launch an agent run in a **new** session/tab. Do NOT pass `session_id` — use `steer` to continue an existing session. Omit `model_id` to use the `pair` role, or pass `model_id` with a role label (resolved via the global role-default mapping in `agent_manage.list_agents` `task_labels`) or an explicit compound `model_id` from `agents[].models[].model_id`. Returns a `session_id` — save it for all follow-up calls. Waits up to `timeout` seconds (default 300). Pass `detach: true` to return immediately.
- `poll`: Return current snapshot immediately. Accepts `session_id` (single) or `session_ids` (array — returns all current snapshots).
- `wait`: Block until the run finishes or needs input. Default 300s. `timeout: 0` = poll. Accepts `session_id` (single) or `session_ids` (array — returns when first session reaches interesting state). Returns `interaction_id` when input is pending.
- `cancel`: Stop an active agent run. Only valid when the run is `running` or `waiting_for_input`. Requires `session_id`.
- `steer`: Continue an existing agent session by sending a follow-up instruction to the `session_id` returned by `start`. If the run is still active, the instruction is steered into that run; if the last run already finished, RepoPrompt starts the next run in the same session. Pass `wait: true` (or `timeout_seconds`) to block until the steered run finishes or needs input. Do NOT use `steer` when status is `waiting_for_input` — use `respond` instead.
- `respond`: Resolve a pending interaction (question, approval, MCP elicitation, etc). Requires `session_id` and `interaction_id` from the snapshot. The `interaction_id` is returned as a top-level field in poll/wait responses when input is pending. For MCP elicitation, use `response` (`accept`, `decline`, or `cancel`) plus optional object `content` and `meta`.

**session_id lifecycle**: `start` creates a new session and returns `session_id` in the response. All subsequent operations on that run require passing the same `session_id` back. Do NOT invent session IDs — always use the value returned by `start`.

**Sub-agent spawning**: MCP-started `orchestrate` runs can dispatch sub-agents. Sub-agents cannot recursively start additional agent runs.

**Parallel agents**: When launching multiple agents in parallel, always use `detach: true` so each `start` returns immediately without blocking. You can then `wait` or `poll` each `session_id` independently.

**IMPORTANT — never end your turn with active agents**: Sub-agents may need approval for tool calls or ask questions via `waiting_for_input`. Always `wait`/`poll` on every started session and `respond` to any pending interactions before finishing your turn. An unattended agent will stall indefinitely.
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				description: """
Provide `op` plus operation-specific fields.

**start**: message (required), model_id? (defaults to pair), session_name?, workflow_id|workflow_name?, detach?, timeout? Use workflow_name="orchestrate" to plan, decompose, and dispatch sub-agents.
**poll / wait**: session_id or session_ids (mutually exclusive), timeout? (wait only)
**cancel**: session_id (required)
**steer**: session_id (required, from a prior `start`/`steer` response), message (required), wait?, timeout_seconds?, workflow_id|workflow_name?
**respond**: session_id (required), interaction_id (required), response?, answers?, amendment?, content?, meta?
""",
				properties: [
					"op": .string(description: "Operation.", enum: ["start", "poll", "wait", "cancel", "steer", "respond"]),
					"message": .string(description: messageDescription),
					"model_id": .string(description: "[start] Role label from agent_manage.list_agents task_labels (explore, engineer, pair, design — resolved via global role defaults), or an explicit compound model_id from agents[].models[].model_id to pin an exact target. Defaults to pair when omitted."),
					"session_id": .string(description: "[poll, wait, cancel, steer, respond] Session UUID returned by a prior start/steer response. Do not fabricate it. Not accepted by start — use steer to continue an existing session."),
					"session_ids": .array(description: "[wait, poll] Array of session UUIDs. For wait: returns when first session reaches interesting state. For poll: returns all current snapshots. Mutually exclusive with session_id.", items: .string()),
					"session_name": .string(description: "[start] Display name for a new session."),
					"workflow_id": .string(description: "[start, steer, respond] Workflow ID. Mutually exclusive with workflow_name."),
					"workflow_name": .string(description: "[start, steer, respond] Workflow name. Mutually exclusive with workflow_id."),
					"detach": .boolean(description: "[start] Return immediately instead of waiting. Default false."),
					"timeout": .number(description: "[start, wait] Max wait seconds. 0 = poll. Default 300."),
					"wait": .boolean(description: "[steer] Wait for an interesting/terminal state after steering. Implied when timeout_seconds is provided."),
					"timeout_seconds": .number(description: "[steer] Max wait seconds when wait=true. 0 = immediate post-steer snapshot. Default 300."),
					"interaction_id": .string(description: "[respond] Pending interaction UUID from the snapshot. Returned as a top-level field in poll/wait responses when the run is waiting_for_input."),
					"response": .string(description: "[respond] Text answer or decision token (accept, decline, cancel, skip, etc). For MCP elicitation use accept, decline, or cancel; a non-action string is sent as content.response."),
					"answers": .object(description: "[respond] Structured answers keyed by question ID."),
					"content": .object(description: "[respond] MCP elicitation content object to send with action=accept."),
					"meta": .object(description: "[respond] Optional MCP elicitation _meta object."),
					"amendment": .string(description: "[respond] Amendment text for accept_with_amendment decisions.")
				],
				required: ["op"]
			),
			implementation: impl
		)
	}

	@MainActor
	private func buildAgentManageTool() -> Tool {
		let impl: @Sendable (MCPServerViewModel, [String: Value]) async throws -> Value = { owner, args in
			try await owner.agentManageToolService.execute(args: args)
		}
		return weakTool(
			name: ToolNames.agentManage,
			description: """
Discover agents, manage sessions, and browse workflows.

**Operations**: list_agents | list_sessions | get_log | extract_handoff | handoff | create_session | resume_session | stop_session | cleanup_sessions | list_workflows

- `list_agents`: Returns top-level `task_labels` as the authoritative role-label→model mapping (explore, engineer, pair, design), plus `agents[].models[]` with explicit compound `model_id` targets for callers that want to pin a specific agent/model/effort. Use `task_labels` entries for role-based routing; use `agents[].models[].model_id` for exact selections. Pass `roles_only=true` to return only `task_labels` and omit the explicit per-agent target catalog.
- `list_sessions`: Browse sessions. Returns `session_id` for each session. Filter by MCP-facing `state` (e.g. `running`, `waiting_for_input`, `completed`, `failed`). When called from agent mode, automatically scopes to sessions spawned by the current agent session.
- `get_log`: Read faithful transcript XML for a session, preserving visible assistant/tool order without handoff compaction or narration pruning. Use `offset`/`limit` to page by turns.
- `extract_handoff` (`handoff` alias): Export the full `<forked_session ...>` handoff XML for a live or persisted session. Persisted sessions export transcript-only payloads; `include_file_contents` is accepted only for a live source tab that is currently active so file selection can be snapshotted reliably. Use `output_path` to write to a file; inline XML is returned by default only when no output path is provided.
- `create_session` / `resume_session`: Create or resume a session with a specific `model_id`.
- `stop_session`: Stop a live session.
- `cleanup_sessions`: Delete specific MCP-originated sessions by ID. Only sessions started via MCP are eligible; user-created sessions are never deleted. Skips active sessions. Use `list_sessions` first to find session IDs, then pass them here.
- `list_workflows`: Discover workflows usable with `agent_run` operations, including `orchestrate` for planning, decomposition, and sub-agent dispatch.
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				description: """
Provide `op` plus operation-specific fields.

**list_agents**: roles_only?
**list_workflows**: no additional fields
**list_sessions**: agent?, state?, limit?
**get_log**: session_id (required), offset?, limit?
**extract_handoff / handoff**: session_id (required), up_to_item_id?, include_file_contents?, output_path?, overwrite?, inline?, max_transcript_items?, max_tool_args_characters?
**create_session**: model_id?, session_name?
**resume_session**: session_id (required), model_id?
**stop_session**: session_id (required)
**cleanup_sessions**: session_ids (required, array of session UUIDs)

Default extraction behavior: `extract_handoff` (or alias `handoff`) returns `handoff_xml` inline when `output_path` is omitted. When `output_path` is provided, XML is written to disk and omitted from the response unless `inline=true`. `output_path` must be absolute (or `~/...`); CLI shorthand resolves relative paths before calling MCP.
""",
				properties: [
					"op": .string(description: "Operation.", enum: ["list_agents", "list_sessions", "get_log", "extract_handoff", "handoff", "create_session", "resume_session", "stop_session", "cleanup_sessions", "list_workflows"]),
					"model_id": .string(description: "[create_session, resume_session] Role label from list_agents task_labels (explore, engineer, pair, design — resolved via global role defaults), or an explicit compound model_id from list_agents agents[].models[].model_id."),
					"session_id": .string(description: "[get_log, extract_handoff, resume_session, stop_session] Session UUID."),
					"session_name": .string(description: "[create_session] Display name for a new session."),
					"limit": .integer(description: "[list_sessions, get_log] Max results."),
					"up_to_item_id": .string(description: "[extract_handoff] Optional transcript row UUID cutoff."),
					"include_file_contents": .boolean(description: "[extract_handoff] Include file contents only when the source session is live and its tab is active. Default false."),
					"output_path": .string(description: "[extract_handoff] Absolute output path (or ~/...) for the handoff XML. When set, inline XML is omitted unless inline=true."),
					"overwrite": .boolean(description: "[extract_handoff] Whether output_path may replace an existing file. Default true."),
					"inline": .boolean(description: "[extract_handoff] Include handoff_xml in the response. Default true without output_path, false with output_path."),
					"max_transcript_items": .integer(description: "[extract_handoff] Transcript item budget; clamped to 1...1000. Default 200."),
					"max_tool_args_characters": .integer(description: "[extract_handoff] Tool argument character budget; clamped to 0...20000. Default 2000."),
					"state": .string(description: "[list_sessions] Session state filter. Use MCP-facing values such as running, waiting_for_input, completed, failed."),
					"offset": .integer(description: "[get_log] Turn offset."),
					"session_ids": .array(description: "[cleanup_sessions] Array of session UUIDs to delete.", items: .string()),
					"roles_only": .boolean(description: "[list_agents] When true, return only the authoritative role-label mapping (task_labels) and omit the explicit per-agent target catalog. Default false.")
				],
				required: ["op"]
			),
			implementation: impl
		)
	}

	/// Build the share_thoughts tool for agent mode
	@MainActor
	private func buildShareThoughtsTool() -> Tool {
		let impl: @Sendable (MCPServerViewModel, [String: Value]) async throws -> Value = { owner, args in
			try await owner.executeShareThoughts(args: args)
		}
		return weakTool(
			name: ToolNames.shareThoughts,
			description: """
Share real-time progress updates with the user.

**Critical**: This is the PRIMARY way to provide live feedback during operations.
Without this tool, users see nothing until you call `wait_for_next_user_instruction` -
they're left staring at a loading state wondering what's happening.

Use this tool PROACTIVELY to narrate your progress as you work:
- "Looking for authentication-related files..."
- "Found UserService.swift, reading to understand the pattern..."
- "Making changes to the login flow..."

**When to use (frequently!):**
- Exploring a codebase (searching, reading multiple files)
- Working through multi-step implementations
- Any task taking more than a few seconds
- Before and after significant operations

**Notes:**
- Messages appear with a "thinking" indicator
- Use the optional `title` parameter for categorization (e.g., "Searching", "Analyzing", "Planning")
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				properties: [
					"thoughts": .string(description: "Your thoughts or reasoning to share with the user."),
					"title": .string(description: "Optional short title for the thought (e.g., 'Analyzing', 'Planning').")
				],
				required: ["thoughts"]
			),
			implementation: impl
		)
	}

	/// Execute share_thoughts tool
	private func executeShareThoughts(args: [String: Value]) async throws -> Value {
		guard let thoughts = args["thoughts"]?.stringValue else {
			throw MCPError.invalidParams("thoughts is required")
		}
		let title = args["title"]?.stringValue

		guard let connectionID = ServerNetworkManager.currentConnectionID else {
			throw MCPError.invalidParams("share_thoughts requires an active MCP connection")
		}
		let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
		guard purpose == .agentModeRun else {
			throw MCPError.invalidParams("share_thoughts is only available during agent mode runs")
		}

		// Find target window and route thoughts
		let targetWindow = try requireTargetWindow()

		let tabID = try await resolveTabIDForAgentMode(
			args: args,
			connectionID: connectionID
		)

		// Invariant: background tool updates are tab-scoped and must not steal tab focus.

		await MainActor.run {
			targetWindow.agentModeViewModel.shareThoughts(thoughts, title: title, tabID: tabID)
		}

		return .object([
			"ok": .bool(true),
			"context_id": .string(tabID.uuidString)
		])
	}

	/// Build the set_status tool used to rename the active agent session/tab.
	@MainActor
	private func buildSetStatusTool() -> Tool {
		let impl: @Sendable (MCPServerViewModel, [String: Value]) async throws -> Value = { owner, args in
			try await owner.executeSetStatus(args: args)
		}
			return weakTool(
				name: ToolNames.setStatus,
				description: """
Rename the current agent session/tab.

Use this tool near session start to set a helpful session title.
""",
				annotations: .repoPromptLocalEphemeralState,
				inputSchema: .object(
					properties: [
						"session_name": .string(description: "Optional session/tab title to set for the active session tab.")
					],
					required: []
				),
			flushFS: false,
			implementation: impl
		)
	}

	/// Execute set_status tool.
	private func executeSetStatus(args: [String: Value]) async throws -> Value {
		guard let connectionID = ServerNetworkManager.currentConnectionID else {
			throw MCPError.invalidParams("set_status requires an active MCP connection")
		}
		let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
		guard purpose == .agentModeRun else {
			throw MCPError.invalidParams("set_status is only available during agent mode runs")
		}


		let trimmedSessionName = args["session_name"]?.stringValue?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let sessionNameToApply = (trimmedSessionName?.isEmpty == false) ? trimmedSessionName : nil

		let targetWindow = try requireTargetWindow()

		let tabID = try await resolveTabIDForAgentMode(
			args: args,
			connectionID: connectionID
		)

		// Invariant: background status updates are tab-scoped and must not steal tab focus.

		await MainActor.run {
			if let sessionNameToApply {
				targetWindow.agentModeViewModel.renameSession(tabID: tabID, to: sessionNameToApply)
			}
		}

		var result: [String: Value] = [
			"ok": .bool(true),
			"context_id": .string(tabID.uuidString),
			"session_name_applied": .bool(sessionNameToApply != nil)
		]
		if let sessionNameToApply {
			result["session_name"] = .string(sessionNameToApply)
		}
		return .object(result)
	}



	private func rebindOracleChatSessionIfNeeded(
		metadata: RequestMetadata,
		chatIDString: String
	) throws {
		guard let connectionID = metadata.connectionID,
			let windowID = metadata.windowID,
			let session = chatVM.resolveSession(id: chatIDString),
			let sessionTabID = session.composeTabID,
			let sessionWorkspaceID = session.workspaceID else {
			return
		}
		try rebindToTabIfNeeded(
			connectionID: connectionID,
			clientName: metadata.clientName,
			windowID: windowID,
			targetTabID: sessionTabID,
			targetWorkspaceID: sessionWorkspaceID
		)
	}

	/// Resolve the tab ID for agent mode MCP tool calls.
	/// Uses explicit _tabID arg, then MCP tab context binding, then falls back to active compose tab.
	private func resolveTabIDForAgentMode(
		args: [String: Value],
		connectionID: UUID?
	) async throws -> UUID {
		// 1) Explicit _tabID override (hidden param), validated against real tabs.
		let explicitRaw = rawExplicitTabID(args: args)
		let workspaceTabIDs = Set(workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
		let availableTabIDs = workspaceTabIDs.isEmpty
			? Set(promptVM.currentComposeTabs.map(\.id))
			: workspaceTabIDs
		if let explicitUUID = try Self.resolveExplicitTabIDForAgentMode(
			rawTabID: explicitRaw,
			availableTabIDs: availableTabIDs
		) {
			return explicitUUID
		}

		// 2) Try to get tab from MCP connection context (bound tab)
		let resolvedConnectionID: UUID?
		if let connectionID {
			resolvedConnectionID = connectionID
		} else {
			resolvedConnectionID = await service.currentRequestConnectionID()
		}
		if let resolvedConnectionID,
			let boundTab = boundTabID(forConnection: resolvedConnectionID),
			composeTabExists(boundTab) {
			return boundTab
		}

		// 3) Fallback to active compose tab in the window
		if let activeTab = promptVM.activeComposeTabID,
			composeTabExists(activeTab) {
			return activeTab
		}

		// 4) Create a blank tab as a last resort
		if let newTab = await promptVM.ensureActiveComposeTab(
			nil,
			creationStrategy: .blank,
			name: nil
		) {
			return newTab.id
		}

		throw MCPError.invalidParams("No active compose tab available; open or create a tab first.")
	}

	/// Resolves an explicit `_tabID` from the args, returning nil when not provided.
	/// Unlike `resolveExistingTabIDForAgentControl`, this does NOT fall back to the
	/// connection-bound tab or active tab. This ensures run-starting operations
	/// (agent_run.start) creates a fresh session by default.
	private func resolveRequestedTabIDForAgentControl(
		args: [String: Value]
	) throws -> UUID? {
		let workspaceTabIDs = Set(workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
		let availableTabIDs = workspaceTabIDs.isEmpty
			? Set(promptVM.currentComposeTabs.map(\.id))
			: workspaceTabIDs
		return try Self.resolveExplicitTabIDForAgentMode(
			rawTabID: rawExplicitTabID(args: args),
			availableTabIDs: availableTabIDs
		)
	}

	private func resolveExistingTabIDForAgentControl(
		args: [String: Value],
		metadata: RequestMetadata
	) async throws -> UUID? {
		let workspaceTabIDs = Set(workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
		let availableTabIDs = workspaceTabIDs.isEmpty
			? Set(promptVM.currentComposeTabs.map(\.id))
			: workspaceTabIDs
		if let explicitUUID = try Self.resolveExplicitTabIDForAgentMode(
			rawTabID: rawExplicitTabID(args: args),
			availableTabIDs: availableTabIDs
		) {
			return explicitUUID
		}
		if let connectionID = metadata.connectionID,
			let boundTabID = boundTabID(forConnection: connectionID),
			composeTabExists(boundTabID) {
			return boundTabID
		}
		if let activeTabID = promptVM.activeComposeTabID,
			composeTabExists(activeTabID) {
			return activeTabID
		}
		return nil
	}

	func bindCurrentRequestToTabIfPossible(
		tabID: UUID,
		metadata: RequestMetadata
	) async throws {
		guard let connectionID = metadata.connectionID,
			let workspaceID = workspaceManager?.activeWorkspace?.id else {
			return
		}
		if await shouldPreserveAgentRunSourceBinding(connectionID: connectionID, metadata: metadata) {
			mcpServerViewModelDebugLog("bindCurrentRequestToTabIfPossible preserved agent-run source binding connectionID=\(connectionID) targetTab=\(tabID)")
			return
		}
		try bindTabForConnection(
			connectionID: connectionID,
			clientName: metadata.clientName,
			tabID: tabID,
			workspaceID: workspaceID,
			windowID: windowID
		)
	}

	private func shouldPreserveAgentRunSourceBinding(
		connectionID: UUID,
		metadata: RequestMetadata
	) async -> Bool {
		guard await ServerNetworkManager.shared.runPurpose(for: connectionID) == .agentModeRun else {
			return false
		}
		if case .virtual = resolveExecContext(from: metadata) {
			return true
		}
		return false
	}

	private func requireTargetWindow() throws -> WindowState {
		guard let targetWindow = WindowStatesManager.shared.window(withID: self.windowID) else {
			throw MCPError.invalidParams("No valid target window found")
		}
		return targetWindow
	}

	private func rawExplicitTabID(args: [String: Value]) -> String? {
		guard let rawValue = args["_tabID"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !rawValue.isEmpty else {
			return nil
		}
		return rawValue
	}

	private func parseExplicitTabID(args: [String: Value]) -> UUID? {
		guard let rawValue = rawExplicitTabID(args: args) else {
			return nil
		}
		return UUID(uuidString: rawValue)
	}

	private func composeTabExists(_ tabID: UUID, in targetWindow: WindowState) -> Bool {
		targetWindow.workspaceManager.composeTab(with: tabID) != nil
	}

	private func composeTabExists(_ tabID: UUID) -> Bool {
		workspaceManager?.composeTab(with: tabID) != nil
	}


	private func resolveContextBuilderTab(
		args: [String: Value],
		targetWindow: WindowState,
		connectionID: UUID?
	) async throws -> (tabID: UUID, bindCaller: Bool) {
		let purpose: MCPRunPurpose
		if let connectionID {
			purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
		} else {
			purpose = .unknown
		}

		let explicitTabRawValue = rawExplicitTabID(args: args)
		let explicitTabID = parseExplicitTabID(args: args)
		if purpose != .agentModeRun,
		   let explicitTabRawValue,
		   explicitTabID == nil {
			throw MCPError.invalidParams("Invalid _tabID '\(explicitTabRawValue)'. Expected a UUID.")
		}
		let tabPlan = Self.planContextBuilderTab(purpose: purpose, explicitTabID: explicitTabID)

		switch tabPlan {
		case .agentModeReuse:
			if let explicitTabID {
				guard composeTabExists(explicitTabID, in: targetWindow) else {
					throw MCPError.invalidParams("Tab not found for _tabID '\(explicitTabID.uuidString)'.")
				}
				return (explicitTabID, false)
			}

			// Agent-mode runs must stay tab-scoped to the invoking context.
			// Never fall back to the currently active UI tab here, otherwise
			// races with tab switches/new-chat creation can misroute discovery.
			if let context = try? await requireCurrentTabContext(toolName: "context_builder"),
			composeTabExists(context.tabID, in: targetWindow) {
				return (context.tabID, false)
			}

			let resolvedConnectionID: UUID?
			if let connectionID {
				resolvedConnectionID = connectionID
			} else {
				resolvedConnectionID = await service.currentRequestConnectionID()
			}
			if let resolvedConnectionID,
				let boundTabID = boundTabID(forConnection: resolvedConnectionID),
				composeTabExists(boundTabID, in: targetWindow) {
				return (boundTabID, false)
			}

			throw MCPError.invalidParams(
				"context_builder could not resolve the invoking agent-mode tab. Retry after routing settles, or pass _tabID explicitly."
			)

		case .freshTab:
			// Discovery runs should not steal UI focus. Create the tab silently and bind MCP context to it.
			guard let createdTab = await targetWindow.promptManager.createBackgroundComposeTab(
				strategy: .blank,
				name: nil
			) else {
				throw MCPError.internalError("Failed to create compose tab.")
			}
			return (createdTab.id, true)

		case .explicitTab(let tabID):
			guard composeTabExists(tabID, in: targetWindow) else {
				throw MCPError.invalidParams("Tab not found for _tabID '\(tabID.uuidString)'.")
			}
			return (tabID, true)
		}
	}

	/// Build the wait_for_next_user_instruction tool for agent mode
	@MainActor
	private func buildWaitForNextInstructionTool() -> Tool {
		let impl: @Sendable (MCPServerViewModel, [String: Value]) async throws -> Value = { owner, args in
			try await owner.executeWaitForNextInstruction(args: args)
		}
		return weakTool(
			name: ToolNames.waitForNextInstruction,
			description: """
Complete your turn and receive the user's next message.

**CRITICAL - YOU MUST ALWAYS CALL THIS TOOL**
This is how you deliver your response to the user. Without calling this tool, the user sees NOTHING and the session hangs. You must call this after EVERY turn - whether you completed a task, answered a question, or just want to share information.

**How it works:**
- The `prompt` you provide IS your message to the user - make it your complete response
- After you call this, you receive the user's reply as your next turn (like a normal conversation)
- Do NOT send a separate text response before calling this tool - the prompt IS your response

**Writing your response (the `prompt` parameter):**
- Be verbose and thorough - explain what you did, what you found, or what you're thinking
- Write naturally as if speaking to a colleague - no need to end with a question
- Include relevant details: files changed, code snippets, reasoning, observations
- Example: "I've refactored the authentication module to use JWT tokens. The changes include:\n\n1. **TokenManager.swift** - New class handling token generation and validation\n2. **AuthMiddleware.swift** - Updated to use TokenManager instead of session-based auth\n3. **UserController.swift** - Login endpoint now returns JWT in response body\n\nAll existing tests pass, and I added new tests for token expiration handling."
- DO NOT write terse responses like "Done." - be informative and helpful

**The user's response comes as your next turn:**
- After calling this tool, you'll receive the user's message as input to your next turn
- This is just like a normal conversation - no special handling needed
- You don't need to ask "what's next?" - just present your response naturally
""",
			annotations: .repoPromptLocalEphemeralState,
			inputSchema: .object(
				properties: [
					"prompt": .string(description: "Your response to the user - what you want to say before waiting for their next instruction.")
				],
				required: []
			),
			implementation: impl
		)
	}

	/// Execute wait_for_next_user_instruction tool
	private func executeWaitForNextInstruction(args: [String: Value]) async throws -> Value {
		let prompt = args["prompt"]?.stringValue
		let timeout = args["timeout_seconds"]?.intValue.map { TimeInterval($0) } ?? 600

		// Find target window
		let targetWindow = try requireTargetWindow()

		// Switch to agent mode and resolve tab ID
		let connectionID = ServerNetworkManager.currentConnectionID
		let tabID = try await resolveTabIDForAgentMode(
			args: args,
			connectionID: connectionID
		)
		// Invariant: waiting state is stored on the target session; do not switch tabs here.

		// Wait for user instruction via AgentModeViewModel
		let response = try await targetWindow.agentModeViewModel.waitForNextUserInstruction(
			tabID: tabID,
			prompt: prompt,
			timeoutSeconds: timeout
		)

		// Build response
		var result: [String: Value] = [
			"timed_out": .bool(response.timedOut),
			"elapsed_seconds": .int(response.elapsedSeconds)
		]
		if let text = response.text {
			result["instruction"] = .string(text)
		} else {
			result["instruction"] = .null
		}

		return .object(result)
	}

	/// Runs an async operation with periodic heartbeat emissions to prevent agent timeouts.
	private func withHeartbeat<T: Sendable>(
		connectionID: UUID?,
		tool: String,
		stage: String,
		message: String,
		interval: Duration = .seconds(30),
		operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		guard let connectionID else {
			return try await operation()
		}
		let shouldSendProgress = await ServerNetworkManager.shared.supportsControlNotifications(connectionID: connectionID)
		guard shouldSendProgress else {
			return try await operation()
		}

		return try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask {
				try await operation()
			}
			group.addTask {
				while !Task.isCancelled {
					try await Task.sleep(for: interval)
					await ServerNetworkManager.shared.sendProgress(
						for: connectionID,
						tool: tool,
						kind: .heartbeat,
						stage: stage,
						message: message
					)
				}
				throw CancellationError()
			}
			let result = try await group.next()!
			group.cancelAll()
			return result
		}
	}

	/// Sends a stage progress notification for the current connection.
	private func sendStageProgress(connectionID: UUID?, tool: String, stage: String, message: String) async {
		guard let connectionID else { return }
		await ServerNetworkManager.shared.sendProgress(
			for: connectionID,
			tool: tool,
			kind: .stage,
			stage: stage,
			message: message
		)
	}

	private func executeDiscoverContext(args: [String: Value], connectionID: UUID?) async throws -> DiscoverContextResult {
		let instructions = args["instructions"]?.stringValue ?? ""
		let responseType = try ContextBuilderResponseType.parse(from: args["response_type"]) // nil, "plan", "question", "review", or "clarify"
		let exportResponse: Bool
		if let value = args["export_response"] {
			guard let boolValue = value.boolValue else {
				throw MCPError.invalidParams("export_response must be a boolean")
			}
			if boolValue, responseType?.wantsResponse != true {
				throw MCPError.invalidParams("export_response requires a response_type that generates a response (plan, question, or review).")
			}
			exportResponse = boolValue
		} else {
			exportResponse = false
		}

		// Resolve window, workspace, and preferred agent/model
		let targetWindow = try requireTargetWindow()
		guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
			throw MCPError.invalidParams("No active workspace in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
		}
		let preferredAgent = targetWindow.promptManager.contextBuilderAgent
		let preferredModelRaw = targetWindow.promptManager.contextBuilderAgentModelRaw

		let (finalTabID, shouldBindCaller) = try await resolveContextBuilderTab(
			args: args,
			targetWindow: targetWindow,
			connectionID: connectionID
		)
		let capturedOracleExportDestination: OracleExportDestination?
		if exportResponse {
			capturedOracleExportDestination = try Self.makeOracleExportDestination(
				workspace: workspace,
				windowID: targetWindow.windowID,
				tabID: finalTabID
			)
		} else {
			capturedOracleExportDestination = nil
		}

		if shouldBindCaller, let connectionID {
			let clientName = await ServerNetworkManager.shared.clientIdentifier(forConnection: connectionID)
			try targetWindow.mcpServer.bindTabForConnection(
				connectionID: connectionID,
				clientName: clientName,
				tabID: finalTabID,
				workspaceID: workspace.id,
				windowID: targetWindow.windowID
			)
		}

		// Run Discover agent with workspace's preferred agent and model
		// Note: runDiscoverAgentForMCP sets isMCPControlledRun=true to suppress UI auto-generate
		let discoverVM = targetWindow.discoverAgentViewModel
		let tabIDForCleanup = finalTabID

		// Use AsyncScope to ensure MCP control flag is cleared on success or error
		return try await AsyncScope.withCleanup({}, cleanup: {
			await MainActor.run {
				discoverVM.clearMCPControlledRun(forTabID: tabIDForCleanup)
			}
		}) {
			// Determine the discovery budget for this run from the target workspace settings,
			// not whatever bindings the discover UI last had loaded.
			let wantsResponse = responseType?.wantsResponse ?? false
			let discoverTokenBudget = await MainActor.run {
				discoverVM.resolvedMCPDiscoveryBudget(for: workspace.id, wantsResponse: wantsResponse)
			}
			let tokenBudgetOverride = discoverTokenBudget

			// Always pin the run-local discovery budget so MCP clarify/omitted runs stay aligned
			// with the target workspace settings even if UI bindings change during the run.

			// When plan/question is requested, lock to Plan copy preset to ensure codemap mode is .auto
			// This prevents MCP presets with codemap mode .selected from limiting context
			let promptManager = targetWindow.promptManager

			// Resolve the model that will be used for plan generation (if response_type requests one)
			// Uses same logic as ChatViewModel+MCP.selectModel for consistency
			let planModelName: String? = await wantsResponse ? MainActor.run {
				let useModelPresets = UserDefaults.standard.bool(forKey: "mcpShowModelPresets")
				let temporarilyDisabled = UserDefaults.standard.bool(forKey: "mcpTemporarilyDisablePresets")

				if !useModelPresets {
					// Presets OFF → use planningModel (MCP default)
					return promptManager.planningModel.displayName
				}

				// Presets ON
				let allPresets = ModelPresetsManager.shared.presets
				let effectivePresets = temporarilyDisabled ? [] : allPresets

				if effectivePresets.isEmpty {
					// No presets → use planningModel
					return promptManager.planningModel.displayName
				}

				// Presets exist → find first available that supports plan mode
				let modeFiltered = effectivePresets.filter { preset in
					responseType?.supportsPresetMode(preset) ?? false
				}
				for preset in modeFiltered {
					if promptManager.isModelAvailable(preset.model) {
						return preset.model.displayName
					}
				}
				// Fallback to planning model if no available preset
				return promptManager.planningModel.displayName
			} : nil

			func runDiscoveryAndPlan() async throws -> DiscoverContextResult {
				// Emit starting stage
				await sendStageProgress(
					connectionID: connectionID,
					tool: "context_builder",
					stage: "starting",
					message: "Starting context builder..."
				)

				// Run discovery with heartbeat
				await sendStageProgress(
					connectionID: connectionID,
					tool: "context_builder",
					stage: "discovering",
					message: "Running discovery agent..."
				)
			let snapshot = try await withHeartbeat(
				connectionID: connectionID,
				tool: "context_builder",
				stage: "discovering",
				message: "Still discovering..."
			) {
				try await discoverVM.runDiscoverAgentForMCP(
					tabID: finalTabID,
					instructionsOverride: instructions.isEmpty ? nil : instructions,
					tokenBudgetOverride: tokenBudgetOverride,
					persistTokenBudget: false,
					enhancementModeOverride: .fullRewrite,
					agentOverride: preferredAgent,
					modelOverrideRaw: preferredModelRaw,
					responseType: responseType?.rawValue,
					planModelName: planModelName
				)
			}

				// Emit discovery complete stage
				await sendStageProgress(
					connectionID: connectionID,
					tool: "context_builder",
					stage: "discovered",
					message: "Discovery complete, building selection..."
				)

				// Get final tab state
				let resultTab = await MainActor.run {
					snapshot.finalState ?? targetWindow.workspaceManager.composeTab(with: finalTabID)
				}
				guard let resultTab else {
					throw MCPError.internalError("Tab state missing after discover run")
				}

				let effectivePrompt = resultTab.promptText

				let status: String = {
					switch snapshot.runState {
					case .completed:           return "completed"
					case .cancelled:           return "cancelled"
					case .failed(let message): return "failed: \(message)"
					default:                   return "completed"
					}
				}()

				let sel = resultTab.selection
				let fileCount = sel.selectedPaths.count + sel.autoCodemapPaths.count

				// Build selection reply to get token count and formatted selection
				// Context builder always uses .auto codemap mode for normalized view
				let selectionReply = await buildTabSelectionReply(
					from: sel,
					includeBlocks: false,
					display: .relative,
					codeMapUsageOverride: .auto
				)
				let formattedSelection = ToolOutputFormatter.formatSelectionReplyToString(selectionReply)

				// ─────────── Optional plan/question generation ───────────
				var planReply: ChatSendReply? = nil
				var reviewReply: ChatSendReply? = nil
				var followUpHint: String? = nil
				var oracleExportFile: OracleExportFile? = nil

				// Determine mode from response_type (nil or "clarify" means no generation)
				let mode = responseType?.headlessMode

				// Skip plan/question generation unless discovery fully completed.
				// Also skip if we used agent output as the prompt, since the agent already
				// produced a response (not a prompt for further action).
				if let mode,
				snapshot.runState == .completed,
				!snapshot.usedAgentOutputAsPrompt,
				!effectivePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					try Task.checkCancellation()

					// Emit plan/question generation stage
					let modeLabel = responseType?.generationLabel ?? "question"
					await sendStageProgress(
						connectionID: connectionID,
						tool: "context_builder",
						stage: "generating",
						message: "Generating \(modeLabel)..."
					)

					// Use unified MCP plan/question generation which handles:
					// - UI state updates (generating, response text, chat ID)
					// - Cancellation wiring (so UI Cancel button works)
					// - Progress streaming
					let reply = try await withHeartbeat(
						connectionID: connectionID,
						tool: "context_builder",
						stage: "generating",
						message: "Still generating \(modeLabel)..."
					) { [chatVM] in
						try await discoverVM.runMCPPlanOrQuestion(
							for: resultTab.id,
							chatViewModel: chatVM,
							mode: mode,
							prompt: effectivePrompt,
							selection: sel
						)
					}

					if mode == .review {
						reviewReply = reply
					} else {
						planReply = reply
					}
					let isAgentModeRun: Bool
					if let connectionID {
						isAgentModeRun = await ServerNetworkManager.shared.runPurpose(for: connectionID) == .agentModeRun
					} else {
						isAgentModeRun = false
					}
					if isAgentModeRun {
						followUpHint = "Continue this \(modeLabel) conversation with ask_oracle(chat_id: \"\(reply.shortId)\", new_chat: false)"
					} else {
						followUpHint = "Continue this \(modeLabel) conversation with ask_oracle(chat_id: \"\(reply.shortId)\", new_chat: false)"
					}
				}

				// Emit complete stage
				await sendStageProgress(
					connectionID: connectionID,
					tool: "context_builder",
					stage: "complete",
					message: "Context builder complete"
				)

				// Compute user token stats if they differ from normalized view
				let normalizedTokens = selectionReply.totalTokens ?? 0
				let userTokens = selectionReply.userCopyTokens
				let userTotalTokens: Int?
				let tokenNote: String?
				if let ut = userTokens, ut != normalizedTokens {
					userTotalTokens = ut
					let codemapDelta = normalizedTokens - ut
					tokenNote = "Difference: \(codemapDelta) codemap tokens (API signatures). Your preset excludes these, so exports use \(ut) file tokens, not \(normalizedTokens)."
				} else {
					userTotalTokens = nil
					tokenNote = nil
				}

				func makeResult(oracleExportPath: String?, oracleExportInstruction: String? = nil) -> DiscoverContextResult {
					DiscoverContextResult(
						tabID: resultTab.id.uuidString,
						status: status,
						prompt: effectivePrompt,
						fileCount: fileCount,
						totalTokens: normalizedTokens,
						userTotalTokens: userTotalTokens,
						tokenNote: tokenNote,
						tokenBudget: discoverTokenBudget,
						promptMode: "rewrite",
						agent: resultTab.discover.agentRaw ?? preferredAgent.rawValue,
						selection: formattedSelection,
						responseType: responseType?.rawValue,
						plan: planReply,
						review: reviewReply,
						followUpHint: followUpHint,
						oracleExportPath: oracleExportPath,
						oracleExportInstruction: oracleExportInstruction
					)
				}

				if exportResponse,
					planReply != nil || reviewReply != nil {
					let resultForExport = makeResult(oracleExportPath: nil)
					let markdown = ToolOutputFormatter.formatDiscoverContext(value: resultForExport.toMCPValue())
						.compactMap { block -> String? in
							switch block {
							case .text(text: let text, annotations: _, _meta: _):
								return text
							default:
								return nil
							}
						}
						.joined(separator: "\n")
					let exportMode = responseType?.rawValue ?? planReply?.mode ?? reviewReply?.mode ?? "response"
					let chatID = planReply?.shortId ?? reviewReply?.shortId
					guard let capturedOracleExportDestination else {
						throw MCPError.internalError("Missing captured Oracle export destination for context_builder export.")
					}
					let exportPath = try await MainActor.run {
						try resolvedDefaultOracleExportPath(
							mode: exportMode,
							chatID: chatID,
							destination: capturedOracleExportDestination
						)
					}
					let resolvedPath = try await Self.writeGeneratedOracleExportFileForReadFileHandoff(
						fileManager: fileManager,
						path: exportPath,
						content: markdown,
						destination: capturedOracleExportDestination,
						sourceTool: "context_builder"
					)
					oracleExportFile = OracleExportFile(
						path: resolvedPath,
						instruction: AgentOracleExport.instruction(path: resolvedPath)
					)
				}

				return makeResult(
					oracleExportPath: oracleExportFile?.path,
					oracleExportInstruction: oracleExportFile?.instruction
				)
			}

			// Run discovery and plan - buildHeadlessAIMessage already uses codeMapUsage: .auto
			return try await runDiscoveryAndPlan()
		}
	}

	// ----------  Helper routines used by the above tool handlers ----------

	/// Implementation of chat_list tool - delegated to ChatViewModel
	@MainActor
	private func tool_chatList(args: [String: Value]) async throws -> [String: Value] {
		return try await chatVM.tool_chatList(args: args)
	}

	private func selectedFiles() async -> [String] {
		fileManager.selectedFiles.map { $0.relativePath }
	}

	@MainActor
	func refreshSelectionMetrics() async {
		await promptVM.tokenCountingViewModel.forceImmediateRecount()
	}

	@MainActor
	func resolveFilesForFolderInput(
		_ path: String,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> RepoFileManagerViewModel.FolderInputResolution {
		await fileManager.resolveFilesForFolderInput(path, rootScope: lookupRootScope)
	}

	@MainActor
	private func resolveSelectionPathsForChatSend(_ rawPaths: [String]) async -> (paths: [String], invalid: [String]) {
		var resolved: [String] = []
		var invalid: [String] = []

		for raw in rawPaths {
			var handled = false
			if let file = await fileManager.resolveFileForUserInput(raw) {
				resolved.append(file.fullPath)
				handled = true
			} else {
				let folderResolution = await resolveFilesForFolderInput(raw)
				if folderResolution.handled {
					resolved.append(contentsOf: folderResolution.files.map(\.fullPath))
					handled = true
				}
			}

			if !handled {
				invalid.append(raw)
			}
		}

		let unique = Array(Set(resolved))
		return (unique, invalid)
	}

	/// Result of applying codemap add operation
	struct CodemapAddResult {
		let invalidPaths: [String]
		let codemapUnavailable: [String]
		let mutated: Bool
	}

	@MainActor
	private func applyCodemapAdd(paths: [String], rawPaths: [String], strict: Bool) async throws -> CodemapAddResult {
		guard !codeMapsGloballyDisabledForMCP else {
			throw MCPError.invalidParams(Self.codeMapsGloballyDisabledMCPMessage)
		}
		guard !paths.isEmpty else {
			return CodemapAddResult(invalidPaths: [], codemapUnavailable: [], mutated: false)
		}

		// Ensure manual codemap changes do not trigger auto-sync scheduling.
		fileManager.enterManualCodemapMode()

		// Use codemap-only resolver that filters unsupported files
		let resolution = await resolveCodemapOnlyCandidates(
			paths: paths,
			rawPaths: rawPaths,
			expandFolders: true
		)

		if strict && resolution.candidates.isEmpty && resolution.resolvedMap.isEmpty {
			throw MCPError.invalidParams(await makeSelectionHintError(paths: rawPaths, operation: "add"))
		}

		var mutated = false

		// Only add files that support codemaps (already filtered by resolver)
		var filesToAdd: [FileViewModel] = []
		var filesToScan: [FileViewModel] = []
		for file in resolution.candidates {
			if file.fileAPI == nil {
				// Schedule scan for files without codemap yet
				filesToScan.append(file)
			}
			let wasChecked = file.isChecked
			let alreadyCodemap = fileManager.isAutoCodemapFile(file)
			if wasChecked || !alreadyCodemap {
				mutated = true
			}
			filesToAdd.append(file)
		}

		// Batch add all codemap files to avoid multiple publisher notifications
		for file in filesToAdd {
			fileManager.setFileAsCodemap(file)
		}

		// Schedule scans for files without codemaps
		if !filesToScan.isEmpty {
			fileManager.requestCodemapScan(for: filesToScan)
		}

		return CodemapAddResult(
			invalidPaths: resolution.invalidPaths,
			codemapUnavailable: resolution.codemapUnavailable,
			mutated: mutated
		)
	}

	struct CodemapRemoveResult {
		let invalidPaths: [String]
		let codemapUnavailable: [String]
		let mutated: Bool
	}

	@MainActor
	private func applyCodemapRemove(paths: [String], rawPaths: [String], strict: Bool) async throws -> CodemapRemoveResult {
		guard !paths.isEmpty else {
			return CodemapRemoveResult(invalidPaths: [], codemapUnavailable: [], mutated: false)
		}

		// Ensure manual codemap changes do not trigger auto-sync scheduling.
		fileManager.enterManualCodemapMode()

		// Use codemap-only resolver that filters unsupported files and expands folders
		let resolution = await resolveCodemapOnlyCandidates(
			paths: paths,
			rawPaths: rawPaths,
			expandFolders: true
		)

		if strict && resolution.candidates.isEmpty && resolution.resolvedMap.isEmpty {
			throw MCPError.invalidParams(await makeSelectionHintError(paths: rawPaths, operation: "remove"))
		}

		var mutated = false

		// Remove each resolved codemap file
		for file in resolution.candidates {
			let wasCodemap = fileManager.isAutoCodemapFile(file)
			if wasCodemap {
				fileManager.removeCodemapFile(file)
				mutated = true
			}
		}

		return CodemapRemoveResult(
			invalidPaths: resolution.invalidPaths,
			codemapUnavailable: resolution.codemapUnavailable,
			mutated: mutated
		)
	}

	@MainActor
	private func promoteSelectionPaths(_ paths: [String], rawPaths: [String], strict: Bool) async throws -> [String] {
		guard !paths.isEmpty else { return [] }

		// Manual promotions should suspend auto codemap inference immediately.
		fileManager.enterManualCodemapMode()

		var invalid: [String] = []
		let directLookup = await fileManager.findFiles(atPaths: paths)
		var promotedIDs = Set<UUID>()

		for raw in paths {
			var handled = false
			var candidate = directLookup[raw]
			if candidate == nil {
				candidate = await fileManager.resolveFileForUserInput(raw)
			}

			if let file = candidate {
				fileManager.setFileAsFullContent(file)
				promotedIDs.insert(file.id)
				handled = true
			} else {
				let folderResolution = await resolveFilesForFolderInput(raw)
				if folderResolution.handled {
					handled = true
				}
				for file in folderResolution.files {
					fileManager.setFileAsFullContent(file)
					promotedIDs.insert(file.id)
				}
			}

			if !handled {
				invalid.append(raw)
			}
		}

		if strict && promotedIDs.isEmpty {
			throw MCPError.invalidParams(await makeSelectionHintError(paths: rawPaths, operation: "promote"))
		}

		return invalid
	}

	@MainActor
	private func demoteSelectionPaths(_ paths: [String], rawPaths: [String], strict: Bool) async throws -> [String] {
		guard !codeMapsGloballyDisabledForMCP else {
			throw MCPError.invalidParams(Self.codeMapsGloballyDisabledMCPMessage)
		}
		guard !paths.isEmpty else { return [] }

		// Manual demotions should suspend auto codemap inference immediately.
		fileManager.enterManualCodemapMode()

		var invalid: [String] = []
		let directLookup = await fileManager.findFiles(atPaths: paths)
		var demotedIDs = Set<UUID>()

		// Track files to scan
		var filesToScan: [FileViewModel] = []

		for raw in paths {
			var handled = false
			var candidate = directLookup[raw]
			if candidate == nil {
				candidate = await fileManager.resolveFileForUserInput(raw)
			}

			if let file = candidate {
				handled = true
				if file.fileAPI == nil {
					// Schedule scan for files without codemap
					filesToScan.append(file)
				}
				fileManager.setFileAsCodemap(file)
				demotedIDs.insert(file.id)
			} else {
				let folderResolution = await resolveFilesForFolderInput(raw)
				if folderResolution.handled {
					handled = true
				}
				for file in folderResolution.files {
					if file.fileAPI == nil {
						// Schedule scan for files without codemap
						filesToScan.append(file)
					}
					fileManager.setFileAsCodemap(file)
					demotedIDs.insert(file.id)
				}
			}

			if !handled {
				invalid.append(raw)
			}
		}

		// Schedule scans for files without codemaps
		if !filesToScan.isEmpty {
			fileManager.requestCodemapScan(for: filesToScan)
		}

		if strict && demotedIDs.isEmpty {
			throw MCPError.invalidParams(await makeSelectionHintError(paths: rawPaths, operation: "demote"))
		}

		return invalid
	}

	private func shouldAutoSelectAgentSlices() async -> Bool {
		let metadata = await captureRequestMetadata()
		guard let connectionID = metadata.connectionID else {
			return false
		}

		let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
		let hasVirtualContext: Bool
		switch resolveExecContext(from: metadata) {
		case .live:
			hasVirtualContext = false
		case .virtual:
			hasVirtualContext = true
		}

		return AutoSliceSelection.shouldApply(purpose: purpose, hasVirtualContext: hasVirtualContext)
	}

	private func applyAutoSelectedSlices(_ entries: [AutoSliceSelection.SliceEntry]) async {
		guard !entries.isEmpty else { return }
		let sliceInputs = entries.map { entry in
			RepoFileManagerViewModel.SelectionSliceInput(path: entry.path, ranges: entry.ranges)
		}

		do {
			_ = try await applySelectionSlices(entries: sliceInputs, mode: .add)
		} catch {
			mcpServerViewModelDebugLog("Auto slice selection skipped due to slice apply error: \(error.localizedDescription)")
		}
	}

	private func applyAutoSelectedFullFiles(_ paths: [String]) async {
		let normalizedPaths = paths
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		guard !normalizedPaths.isEmpty else { return }

		do {
			let metadata = await captureRequestMetadata()
			let lookupRootScope = await resolveFileToolLookupRootScope(from: metadata)
			switch resolveExecContext(from: metadata) {
			case .live:
				let resolvedFiles = await selectionFindFiles(atPaths: normalizedPaths, lookupRootScope: lookupRootScope)
				for path in normalizedPaths {
					guard let file = resolvedFiles[path] else { continue }
					fileManager.setFileAsFullContent(file)
				}
			case .virtual(let ctx):
				let addResult = await addStoredSelectionPaths(
					existing: ctx.selection,
					paths: normalizedPaths,
					rawPaths: normalizedPaths,
					mode: "full",
					lookupRootScope: lookupRootScope
				)
				let sliceRemovalInputs = normalizedPaths.map {
					RepoFileManagerViewModel.SelectionSliceInput(path: $0, ranges: [])
				}
				let clearedSelection: StoredSelection
				if sliceRemovalInputs.isEmpty {
					clearedSelection = addResult.selection
				} else {
					clearedSelection = await computeSelectionSlicesVirtual(
						base: addResult.selection,
						entries: sliceRemovalInputs,
						mode: .remove,
						lookupRootScope: lookupRootScope
					).selection
				}
				guard clearedSelection != ctx.selection else { return }
				try await updateCurrentTabContext(toolName: "autoSelectReadFile") { context in
					context.selection = clearedSelection
				}
			}
		} catch {
			mcpServerViewModelDebugLog("Auto full-file selection skipped due to selection apply error: \(error.localizedDescription)")
		}
	}

	private func maybeAutoSelectReadFileSelection(
		reply: ToolResultDTOs.ReadFileReply,
		requestedPath: String
	) async {
		guard await shouldAutoSelectAgentSlices() else { return }
		guard let baseSelection = AutoSliceSelection.readFileSelection(from: reply, fallbackPath: requestedPath) else { return }
		let selection: AutoSliceSelection.ReadFileSelection
		switch baseSelection {
		case .full:
			selection = baseSelection
		case .slice:
			let existingFullPaths = await autoSelectedFullFilePaths()
			selection = AutoSliceSelection.preserveExistingFullFileSelection(
				baseSelection,
				existingFullPaths: existingFullPaths
			)
		}
		switch selection {
		case .full(let path):
			await applyAutoSelectedFullFiles([path])
		case .slice(let entry):
			await applyAutoSelectedSlices([entry])
		}
	}

	private func autoSelectedFullFilePaths() async -> [String] {
		let metadata = await captureRequestMetadata()
		let lookupRootScope = await resolveFileToolLookupRootScope(from: metadata)
		switch resolveExecContext(from: metadata) {
		case .live:
			let snapshot = await selectionSnapshot()
			let slicedIDs = Set(snapshot.slices.keys)
			var fullPaths: [String] = []
			for file in snapshot.selected where !slicedIDs.contains(file.id) {
				fullPaths.append(await prefixedRelativePath(for: file))
			}
			return fullPaths
		case .virtual(let ctx):
			let selectedPaths = StoredSelectionPathNormalization.standardizedPaths(ctx.selection.selectedPaths)
			let slicedPaths = Set(StoredSelectionPathNormalization.standardizedSlices(ctx.selection.slices).keys)
			let resolved = await selectionFindFiles(atPaths: selectedPaths, lookupRootScope: lookupRootScope)
			var fullPaths: [String] = []
			for path in selectedPaths {
				guard !slicedPaths.contains(path), let file = resolved[path] else { continue }
				fullPaths.append(await prefixedRelativePath(for: file))
			}
			return fullPaths
		}
	}

	private func maybeAutoSelectFileSearchSlices(
		mode: SearchMode,
		contextLines: Int,
		reply: ToolResultDTOs.SearchResultDTO
	) async {
		guard await shouldAutoSelectAgentSlices() else { return }
		guard AutoSliceSelection.shouldSliceFileSearch(mode: mode, contextLines: contextLines) else { return }
		guard !reply.contentMatchGroups.isEmpty else { return }
		let entries = AutoSliceSelection.searchEntries(from: reply.contentMatchGroups)
		await applyAutoSelectedSlices(entries)
	}

	private func applySelectionSlices(
	entries: [RepoFileManagerViewModel.SelectionSliceInput],
	mode: SliceMutationMode
) async throws -> RepoFileManagerViewModel.SelectionSlicesMutationResult {
	do {
		let metadata = await captureRequestMetadata()
		switch resolveExecContext(from: metadata) {
		case .live:
			return try await fileManager.setSelectionSlices(entries: entries, mode: mode)
		case .virtual(let ctx):
			let lookupRootScope = await resolveFileToolLookupRootScope(from: metadata)
			return try await applySelectionSlicesVirtual(
				ctx: ctx,
				entries: entries,
				mode: mode,
				lookupRootScope: lookupRootScope
			)
		}
	} catch let sliceError as RepoFileManagerViewModel.SelectionSliceError {
		switch sliceError {
		case .workspaceUnavailable:
			throw MCPError.internalError(sliceError.localizedDescription)
		case .noWorkspaceLoaded:
			throw MCPError.invalidParams(sliceError.localizedDescription)
		}
	} catch let mcpError as MCPError {
		throw mcpError
	} catch {
		throw MCPError.internalError("Failed to update selection slices: \(error.localizedDescription)")
	}
}

@MainActor
func computeSelectionSlicesVirtual(
	base: StoredSelection,
	entries: [RepoFileManagerViewModel.SelectionSliceInput],
	mode: SliceMutationMode,
	lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
) async -> (selection: StoredSelection, result: RepoFileManagerViewModel.SelectionSlicesMutationResult, mutated: Bool) {
	let normalizedInputs = entries.map {
		StandardizedPath.absolute(fileManager.normalizeUserInputPath($0.path))
	}
	var invalid: [String] = []
	var lookupInputs: [String] = []
	lookupInputs.reserveCapacity(normalizedInputs.count)
	for normalized in normalizedInputs {
		if let issue = fileManager.exactPathResolutionIssue(for: normalized, kind: .file, rootScope: lookupRootScope) {
			invalid.append(PathResolutionIssueRenderer.message(for: issue))
			continue
		}
		lookupInputs.append(normalized)
	}
	let lookup = await fileManager.findFiles(
		atPaths: lookupInputs,
		profile: .mcpSelection,
		rootScopeOverride: lookupRootScope
	)

	var resolved: [String: String] = [:]
	var aggregated: [String: [LineRange]] = [:]
	var clearAllRemovals = Set<String>()
	for (index, entry) in entries.enumerated() {
		let normalized = normalizedInputs[index]
		if fileManager.exactPathResolutionIssue(for: normalized, kind: .file, rootScope: lookupRootScope) != nil {
			continue
		}
		guard let fileVM = lookup[normalized] else {
			invalid.append(entry.path)
			continue
		}
		let full = fileVM.standardizedFullPath
		resolved[entry.path] = await prefixedRelativePath(for: fileVM)
		if case .remove = mode, entry.ranges.isEmpty {
			aggregated[full] = []
			clearAllRemovals.insert(full)
			continue
		}
		if case .remove = mode, clearAllRemovals.contains(full) {
			continue
		}
		if var ranges = aggregated[full] {
			ranges.append(contentsOf: entry.ranges)
			aggregated[full] = ranges
		} else {
			aggregated[full] = entry.ranges
		}
	}

	let applied = Self.selectionByApplyingResolvedSliceMutation(
		base: base,
		resolvedSlices: aggregated,
		mode: mode
	)
	let mutated = applied.mutated
	let finalSelection: StoredSelection
	if mutated, applied.selection.codemapAutoEnabled {
		finalSelection = await recomputeAutoCodemapsForVirtualSelection(
			applied.selection,
			lookupRootScope: lookupRootScope
		)
	} else {
		finalSelection = applied.selection
	}

	var snapshot: [UUID: [LineRange]] = [:]
	for (full, ranges) in finalSelection.slices where !ranges.isEmpty {
		if let vm = fileManager.findFileByFullPath(full) {
			snapshot[vm.id] = ranges
		}
	}

	return (selection: finalSelection, result: RepoFileManagerViewModel.SelectionSlicesMutationResult(
		invalidPaths: invalid,
		resolvedMap: resolved,
		snapshot: snapshot
	), mutated: mutated)
}

private func applySelectionSlicesVirtual(
	ctx: TabScopedContext,
	entries: [RepoFileManagerViewModel.SelectionSliceInput],
	mode: SliceMutationMode,
	lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
) async throws -> RepoFileManagerViewModel.SelectionSlicesMutationResult {
	let stabilizedSelection = await stabilizedVirtualSelection(for: ctx)
	let computed = await computeSelectionSlicesVirtual(
		base: stabilizedSelection,
		entries: entries,
		mode: mode,
		lookupRootScope: lookupRootScope
	)
	if computed.mutated {
		try await updateCurrentTabContext(toolName: "applySelectionSlices") { context in
			context.selection = computed.selection
		}
	}
	return computed.result
}
// Root-aware path helpers (useful for multi-root disambiguation)
func prefixedRelativePath(for file: FileViewModel) async -> String {
	await MainActor.run {
		fileManager.mcpDisplayPath(for: file)
    }
}

nonisolated static func prefixedRelativePath(forPath path: String, rootFolders: [FolderViewModel]) -> String {
	let roots = rootFolders.map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.fullPath) }
	return ClientPathFormatter.displayAbsolutePath(fullPath: path, visibleRoots: roots)
}

nonisolated static func mcpDisplayPath(
	forPath path: String,
	visibleRootFolders: [FolderViewModel],
	allRootFolders: [FolderViewModel]
) -> String {
	let visibleRoots = visibleRootFolders.map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.fullPath) }
	let allRoots = allRootFolders.map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.fullPath) }
	return RepoFileManagerViewModel.mcpDisplayPath(
		fullPath: path,
		visibleRoots: visibleRoots,
		allRoots: allRoots
	)
}

    /// Builds a helpful error message for selection failures, including loaded roots and path hints.
	private func makeSelectionHintError(
		paths: [String],
		operation: String,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> String {
        let trimmed = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
		let roots = switch lookupRootScope {
		case .visibleWorkspace:
			fileManager.visibleRootFolders
		case .visibleWorkspacePlusGitData:
			fileManager.rootFolders.filter { !$0.isSystemRoot || $0.name == "_git_data" }
		case .allLoaded:
			fileManager.rootFolders
		}
		if roots.isEmpty {
			return "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
		}

        // Gather hints
        let rootSummaries = roots.map { "\($0.name) → \($0.fullPath)" }.joined(separator: "; ")

        var outside: [String] = []
        for p in trimmed {
            if p.hasPrefix("/") {
                let under = roots.contains { p.hasPrefix($0.fullPath.hasSuffix("/") ? $0.fullPath : $0.fullPath + "/") || p == $0.fullPath }
                if !under {
                    outside.append(p)
                }
            }
        }

        var lines: [String] = []
        lines.append("No provided paths matched any files or folders for '\(operation)'.")
        lines.append("Loaded roots: \(rootSummaries)")
        lines.append("Provide either: (a) Root-name + relative path (e.g., 'Root/Sub/Path.swift'), or (b) a full absolute path under a loaded root.")
        if !outside.isEmpty {
            let sample = outside.prefix(2).joined(separator: ", ")
            lines.append("Not under any loaded root: \(sample)")
        }
        return lines.joined(separator: " ")
    }

	private func setSelection(path: String, checked: Bool) async throws {
		let result = checked
			? await fileManager.selectPaths(withPaths: [path], clear: false, expandFolders: true, exact: false)
			: await fileManager.deselectPaths(withPaths: [path], expandFolders: true, exact: false)
		if let invalid = result.invalidPaths.first {
			throw MCPError.invalidParams(invalid)
		}
	}

	private func codeMap(for path: String) async -> FileAPI? {
		await fileManager.findFile(atPath: path)?.fileAPI
	}

	@MainActor
	private func resolveFilesForCodeStructure(
		paths: [String],
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> [FileViewModel] {
		let directFiles = await fileManager.findFiles(
			atPaths: paths,
			profile: .mcpRead,
			rootScopeOverride: lookupRootScope
		)
		let matchedFileInputs = Set(directFiles.keys)
		var resolved: [FileViewModel] = []
		var seenPaths = Set<String>()

		for path in paths {
			if let file = directFiles[path] {
				let fullPath = file.standardizedFullPath
				if seenPaths.insert(fullPath).inserted {
					resolved.append(file)
				}
			}
		}

		let dirCandidates = paths.filter { !matchedFileInputs.contains($0) }
		for raw in dirCandidates {
			let folderResolution = await resolveFilesForFolderInput(raw, lookupRootScope: lookupRootScope)
			guard folderResolution.handled else { continue }
			for file in folderResolution.files {
				let fullPath = file.standardizedFullPath
				if seenPaths.insert(fullPath).inserted {
					resolved.append(file)
				}
			}
		}

		return resolved
	}

	@MainActor
	func buildCodeStructureDTO(
		from files: [FileViewModel],
		maxResults: Int,
		includeUnmappedPaths: Bool
	) async -> ToolResultDTOs.SelectedCodeStructureDTO {
		struct RenderableCodeStructure {
			let key: String
			let displayPath: String
			let api: FileAPI
			let estimatedTokens: Int
		}

		var renderable: [RenderableCodeStructure] = []
		var unmappedPaths: [String] = []
		var seenPaths = Set<String>()

		for file in files {
			let fullPath = file.standardizedFullPath
			guard seenPaths.insert(fullPath).inserted else { continue }
			let displayPath = fileManager.mcpDisplayPath(for: file)
			if let api = file.fileAPI {
				renderable.append(
					RenderableCodeStructure(
						key: fullPath,
						displayPath: displayPath,
						api: api,
						estimatedTokens: api.estimatedFullAPIDescriptionTokens(displayPath: displayPath)
					)
				)
			} else if includeUnmappedPaths {
				unmappedPaths.append(displayPath)
			}
		}

		renderable.sort { lhs, rhs in
			if lhs.displayPath == rhs.displayPath {
				return lhs.key < rhs.key
			}
			return lhs.displayPath < rhs.displayPath
		}

		let budgetSelection = Self.applyCodeStructureOutputBudget(
			renderable.map {
				CodeStructureBudgetCandidate(key: $0.key, estimatedTokens: $0.estimatedTokens)
			},
			maxResults: maxResults,
			tokenBudget: Self.codeStructureTokenBudget,
			separatorTokens: Self.codeStructureSeparatorTokenCost
		)

		let renderableByKey = Dictionary(uniqueKeysWithValues: renderable.map { ($0.key, $0) })
		let content = budgetSelection.includedKeys
			.compactMap { renderableByKey[$0] }
			.map { $0.api.getFullAPIDescription(displayPath: $0.displayPath) }
			.joined(separator: "\n\n")

		let sortedUnmapped = includeUnmappedPaths && !unmappedPaths.isEmpty ? unmappedPaths.sorted() : nil
		let omittedByMaxResults = budgetSelection.omittedByMaxResults
		let omittedByTokenBudget = budgetSelection.omittedByTokenBudget
		let omittedTotal = budgetSelection.omittedTotal

		return ToolResultDTOs.SelectedCodeStructureDTO(
			fileCount: budgetSelection.includedKeys.count,
			content: content,
			unmappedPaths: sortedUnmapped,
			omittedCount: omittedByMaxResults > 0 ? omittedByMaxResults : nil,
			omittedTotal: omittedTotal > 0 ? omittedTotal : nil,
			tokenBudgetOmittedCount: omittedByTokenBudget > 0 ? omittedByTokenBudget : nil,
			tokenBudgetHit: omittedByTokenBudget > 0 ? true : nil
		)
	}

	/// Collect codemaps with a hard cap; also report how many were omitted.
	private func getCodeMaps(
		for paths: [String],
		maxResults: Int = 25,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> (maps: [String: FileAPI], omitted: Int) {
		// Use bulk lookup for efficiency
		let files = await fileManager.findFiles(
			atPaths: paths,
			profile: .mcpRead,
			rootScopeOverride: lookupRootScope
		)

		var results: [String: FileAPI] = [:]
		var seenFileIDs = Set<UUID>()
		var collected = 0
		let cap = max(0, maxResults)
		var omitted = 0

		// 1) Direct file inputs first
		if !files.isEmpty {
			for (_, fileVM) in files {
				guard let api = fileVM.fileAPI, seenFileIDs.insert(fileVM.id).inserted else { continue }
				if collected < cap {
					results[fileVM.standardizedFullPath] = api
					collected += 1
				} else {
					omitted += 1
				}
			}
			if collected >= cap {
				return (results, omitted)
			}
		}

		// 2) Remaining inputs treated as directories (recursive)
		let matchedFileInputs = Set(files.keys)
		let dirCandidates = paths.filter { !matchedFileInputs.contains($0) }

		if !dirCandidates.isEmpty {
			dirLoop: for raw in dirCandidates {
				let folderResolution = await resolveFilesForFolderInput(raw, lookupRootScope: lookupRootScope)
				guard folderResolution.handled else { continue }

				for (idx, f) in folderResolution.files.enumerated() {
					guard let api = f.fileAPI, seenFileIDs.insert(f.id).inserted else { continue }
					if collected < cap {
						results[f.standardizedFullPath] = api
						collected += 1
						if collected >= cap {
							// Count the remaining eligible codemaps in this *same* directory, then stop immediately.
							if idx + 1 < folderResolution.files.count {
								for j in (idx + 1)..<folderResolution.files.count {
									let g = folderResolution.files[j]
									if g.fileAPI != nil, !seenFileIDs.contains(g.id) {
										omitted += 1
									}
								}
							}
							break dirLoop
						}
					} else {
						omitted += 1
					}
				}
			}
		}

		return (results, omitted)
	}


	// MARK: – Shared validation helpers
	/// Returns every path that cannot be resolved to a loaded `FileViewModel` or `FolderViewModel`.
	private func invalidPaths(in paths: [String]) async -> [String] {
		// Separate paths into likely files and likely folders based on extension
		var likelyFilePaths: [String] = []
		var likelyFolderPaths: [String] = []

		for path in paths {
			let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }

			// Check if path has a file extension (contains a dot after the last slash)
			let lastComponent = (trimmed as NSString).lastPathComponent
			if lastComponent.contains(".") && !lastComponent.hasPrefix(".") {
				likelyFilePaths.append(path)
			} else {
				likelyFolderPaths.append(path)
			}
		}

		// Use efficient bulk lookup for likely files
		let foundFiles = likelyFilePaths.isEmpty ? [:] : await fileManager.findFiles(atPaths: likelyFilePaths)

		// Collect invalid paths
		var invalidPaths: [String] = []

		// Check which file paths weren't found
		for path in likelyFilePaths {
			if foundFiles[path] == nil {
				// Not found as file, but could still be a folder with extension
				let normalizedPath = fileManager.normalizeUserInputPath(path)
				let standardizedPath = (normalizedPath as NSString).standardizingPath
				let isAbsolute = standardizedPath.hasPrefix("/")

				let folderVM: FolderViewModel? = isAbsolute
					? fileManager.findFolderByFullPath(standardizedPath)
					: fileManager.findFolderByRelativePath(standardizedPath)

				if folderVM == nil {
					invalidPaths.append(path)
				}
			}
		}

		// Check folder paths
		for path in likelyFolderPaths {
			let normalizedPath = fileManager.normalizeUserInputPath(path)
			let standardizedPath = (normalizedPath as NSString).standardizingPath
			let isAbsolute = standardizedPath.hasPrefix("/")

			// First try as folder
			let folderVM: FolderViewModel? = isAbsolute
				? fileManager.findFolderByFullPath(standardizedPath)
				: fileManager.findFolderByRelativePath(standardizedPath)

			if folderVM == nil {
				// Not found as folder, try as file (in case it's a file without extension)
				let fileVM: FileViewModel? = isAbsolute
					? fileManager.findFileByFullPath(standardizedPath)
					: fileManager.findFileByRelativePath(standardizedPath)

				if fileVM == nil {
					invalidPaths.append(path)
				}
			}
		}

		return invalidPaths
	}

    /// Reads a file with optional slicing. Supports 1-based indices and a negative sentinel
    /// for bottom-origin reads (start_line = -N reads the last N lines).
    /// Returns both the content slice and metadata about the shown range.
	private func readFile(path: String,
                          startLine1Based: Int? = nil,
						lineCount: Int? = nil,
						lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace) async throws -> (reply: ToolResultDTOs.ReadFileReply, shouldAutoSelect: Bool) {
		if let issue = fileManager.exactPathResolutionIssue(for: path, kind: .either, rootScope: lookupRootScope) {
			throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
		}

		if let folderVM = fileManager.resolveFolderForUserInput(path, rootScope: lookupRootScope) {
			let displayPath = fileManager.mcpDisplayPath(for: folderVM)
			throw MCPError.invalidParams("'\(displayPath)' is a folder; read_file requires a file path. Use get_file_tree or file_search to find specific files.")
		}
		if let externalFolderPath = fileManager.resolveAlwaysReadableExternalFolderDisplayPath(path) {
			throw MCPError.invalidParams("'\(externalFolderPath)' is a folder; read_file requires a file path. Use get_file_tree or file_search to find specific files.")
		}

		let readableFile = await fileManager.resolveReadableFileForUserInput(path, rootScopeOverride: lookupRootScope)
		let full: String
		let displayPath: String
		let shouldAutoSelect: Bool
		switch readableFile {
		case .workspace(let fileVM):
			displayPath = fileManager.mcpDisplayPath(for: fileVM)
			do {
				full = try await fileManager.readWorkspaceFileContentStrictly(fileVM)
			} catch let error as StrictWorkspaceFileContentError {
				switch error {
				case .fileMissing:
					throw MCPError.invalidParams("File not found: '\(displayPath)'. The path is inside a loaded folder, but no file exists there.")
				case .serviceUnavailable:
					throw MCPError.internalError(error.localizedDescription)
				case .readFailed:
					throw MCPError.invalidParams(error.localizedDescription)
				}
			} catch {
				throw MCPError.invalidParams("Cannot read '\(displayPath)': \(error.localizedDescription)")
			}
			shouldAutoSelect = true
		case .external(let externalFile):
			do {
				full = try await fileManager.readAlwaysReadableExternalFile(externalFile)
			} catch {
				throw MCPError.invalidParams("Cannot read '\(externalFile.displayPath)': \(error.localizedDescription)")
			}
			displayPath = externalFile.displayPath
			shouldAutoSelect = false
		case nil:
			if fileManager.isAlwaysReadableExternalPath(path) {
				throw MCPError.invalidParams("File not found: '\(fileManager.displayPathForAlwaysReadableExternalPath(path))'.")
			}
			if let displayPath = fileManager.mcpUnresolvedDisplayPath(for: path) {
				throw MCPError.invalidParams("File not found: '\(displayPath)'. The path is inside a loaded folder, but no file exists there.")
			}
			let msg = await workspaceContextMessage(forOperation: "read file", path: path)
			throw MCPError.invalidParams("Cannot read '\(path)'. \(msg)")
		}

		// Preserve original line endings and total line count
		let pairs = String.splitContentPreservingAllLineEndings(full)
		let total = pairs.count

		// Validate parameter combinations
		if let s1 = startLine1Based {
			// Check for invalid parameter combinations
			if s1 < 0 && lineCount != nil {
				throw MCPError.invalidParams("limit parameter is not allowed with negative start_line. Use start_line=-N to read the last N lines.")
			}
			if s1 == 0 {
				throw MCPError.invalidParams("start_line must be positive (1-based) or negative (tail-like behavior)")
			}
		}

		// Determine slice range
		let (first, lastExclusive): (Int, Int) = {
			// Handle negative start_line (tail-like behavior)
			if let s1 = startLine1Based, s1 < 0 {
				// Negative start_line means "last N lines" (like tail -n)
				let linesToRead = abs(s1)
				let start = max(0, total - linesToRead)
				return (start, total)
			}

			// Handle positive 1-based start line (default to 1 if only limit provided)
			let s1 = startLine1Based ?? 1
			let start0 = max(0, s1 - 1)
			let end = (lineCount != nil && lineCount! >= 0)
				? min(total, start0 + lineCount!)
				: total
			return (start0, end)
		}()

        // If start is beyond file end, return empty content with a helpful message
        if !(first < total || total == 0) {
				return (
					ToolResultDTOs.ReadFileReply(
						content: "",
						totalLines: total,
						firstLine: max(1, first + 1),
						lastLine: total,
						message: "Requested start_line exceeds file length.",
						displayPath: displayPath
					),
					shouldAutoSelect
				)
        }

		let contentSlice: String = {
			if total == 0 { return "" }
			let slice = pairs[first..<lastExclusive]
			return slice.map { $0.line + $0.ending }.joined()
		}()

        // Prepare metadata for the displayed slice
        let shownFirst = total == 0 ? 0 : (first + 1)
        let shownLast  = total == 0 ? 0 : lastExclusive

		return (
			ToolResultDTOs.ReadFileReply(
				content: contentSlice,
				totalLines: total,
				firstLine: shownFirst,
				lastLine: shownLast,
				message: nil,
				displayPath: displayPath
			),
			shouldAutoSelect
        )
    }

	/// Performs a file action (create, delete, or move/rename)
	private func performFileAction(
		action: String,
		path: String,
		content: String? = nil,
		newPath: String? = nil,
		ifExists: String? = nil
	) async throws {
		// Enforce workspace presence in multi-window mode
		try await requireWorkspaceForTool(ToolNames.fileActions)

		do {
			switch action.lowercased() {
			case "create":
				guard let content = content else {
					throw MCPError.invalidParams("content is required for create action")
				}
				let policy = (ifExists ?? "error").lowercased()
				try await writeFile(path: path, content: content, overwrite: policy == "overwrite")

			case "delete":
				// Validate that the path is absolute for safety. Destructive delete intentionally
				// does not accept relative/display aliases even when other MCP tools can read them.
				guard path.hasPrefix("/") else {
					throw MCPError.invalidParams(fileManager.deleteAbsolutePathRequiredMessage(for: path))
				}
				try await fileManager.trashFileFromTool(atPath: path)

			case "move", "rename":
				guard let newPath = newPath else {
					throw MCPError.invalidParams("new_path is required for move/rename action")
				}
				try await renameFile(oldPath: path, newPath: newPath)

			default:
				throw MCPError.invalidParams("invalid action: \(action). Must be 'create', 'delete', or 'move'")
			}
		} catch let fmErr as FileManagerError {
			// Convert internal file-manager errors to friendly, contextual MCP errors
			throw await mapFileManagerErrorToMCP(fmErr, action: action, path: path)
		} catch let mcpErr as MCPError {
			throw mcpErr
		} catch {
			// Generic fallback
			throw MCPError.invalidParams("File action '\(action)' failed: \(error.localizedDescription)")
		}

		// Ensure any resulting file system deltas are flushed and applied
		await fileManager.flushPendingDeltas(aggressive: true)
	}


	/// Creates a **new** file, with optional overwrite behavior.
	/// - Parameter overwrite: when true and a file already exists, its content will be replaced.
	private func writeFile(
		path: String,
		content: String,
		overwrite: Bool = false,
		addToSelection: Bool = true
	) async throws {
		let policy = overwrite ? "overwrite" : "error"
		do {
			try await fileManager.writeFileFromTool(
				userPath: path,
				content: content,
				ifExists: policy,
				selectAfterCreate: addToSelection,
				pathResolutionPolicy: .literalPreferredIfStronger
			)
		} catch let fmErr as FileManagerError {
			throw await mapFileManagerErrorToMCP(fmErr, action: "create", path: path)
		} catch let mcpErr as MCPError {
			throw mcpErr
		} catch {
			throw MCPError.invalidParams("File creation failed for '\(path)': \(error.localizedDescription)")
		}
	}

	private func exportOracleResponse(_ request: OracleExportRequest) async throws -> OracleExportFile {
		guard let destination = request.destination else {
			throw MCPError.internalError("Missing Oracle export destination metadata for generated export.")
		}
		let path = try resolvedDefaultOracleExportPath(
			mode: request.mode,
			chatID: request.chatID,
			destination: destination
		)
		let markdown = AgentOracleExport.oracleMarkdown(request: request)
		let resolvedPath = try await Self.writeGeneratedOracleExportFileForReadFileHandoff(
			fileManager: fileManager,
			path: path,
			content: markdown,
			destination: destination,
			sourceTool: request.sourceTool
		)
		return OracleExportFile(
			path: resolvedPath,
			instruction: AgentOracleExport.instruction(path: resolvedPath)
		)
	}

	private func defaultOracleExportPath(mode: String, chatID: String?) -> String {
		let timestamp = Self.oracleExportTimestampFormatter.string(from: Date())
		let normalizedMode = slugForOracleExport(mode, fallback: "response")
		let chatSlug = slugForOracleExport(chatID ?? "", fallback: "chat")
		let nonce = UUID().uuidString.prefix(4).lowercased()
		return "prompt-exports/oracle-\(normalizedMode)-\(timestamp)-\(chatSlug)-\(nonce).md"
	}

	private func resolvedDefaultOracleExportPath(
		mode: String,
		chatID: String?,
		destination: OracleExportDestination
	) throws -> String {
		let relativePath = defaultOracleExportPath(mode: mode, chatID: chatID)
		return try Self.resolveGeneratedOracleExportPath(
			relativePath: relativePath,
			destination: destination
		)
	}

	static func makeOracleExportDestination(
		workspace: WorkspaceModel?,
		windowID: Int,
		tabID: UUID?
	) throws -> OracleExportDestination {
		guard let workspace else {
			throw MCPError.invalidParams("Cannot create generated Oracle export: no active workspace is available.")
		}
		guard let rawPrimaryRoot = workspace.repoPaths.first?.trimmingCharacters(in: .whitespacesAndNewlines),
			!rawPrimaryRoot.isEmpty else {
			throw MCPError.invalidParams("Cannot create generated Oracle export: active workspace has no primary root (workspace.repoPaths.first is missing).")
		}
		let expandedRoot = (rawPrimaryRoot as NSString).expandingTildeInPath
		guard expandedRoot.hasPrefix("/") else {
			throw MCPError.invalidParams("Cannot create generated Oracle export: workspace primary root must be an absolute path, got '\(rawPrimaryRoot)'.")
		}
		let standardizedRoot = (expandedRoot as NSString).standardizingPath
		try validateOracleExportPrimaryRoot(standardizedRoot)

		return OracleExportDestination(
			workspaceID: workspace.id,
			windowID: windowID,
			tabID: tabID,
			primaryRootPath: standardizedRoot
		)
	}

	static func resolveGeneratedOracleExportPath(
		relativePath rawRelativePath: String,
		destination: OracleExportDestination
	) throws -> String {
		try validateOracleExportPrimaryRoot(destination.primaryRootPath)

		let trimmed = rawRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw MCPError.invalidParams("Cannot create generated Oracle export: export path is empty.")
		}
		guard !trimmed.hasPrefix("/") else {
			throw MCPError.invalidParams("Cannot create generated Oracle export: generated export path must be relative, got '\(trimmed)'.")
		}

		let rootPath = (destination.primaryRootPath as NSString).standardizingPath
		let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
		let resolvedPath = rootURL.appendingPathComponent(trimmed).standardizedFileURL.path
		let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
		guard resolvedPath.hasPrefix(rootPrefix) else {
			throw MCPError.invalidParams("Cannot create generated Oracle export: generated path escapes the workspace primary root.")
		}
		return resolvedPath
	}

	private static func validateOracleExportPrimaryRoot(_ rawRootPath: String) throws {
		let rootPath = (rawRootPath as NSString).standardizingPath
		var isDirectory = ObjCBool(false)
		guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
			throw MCPError.invalidParams("Cannot create generated Oracle export: workspace primary root is unavailable: \(rootPath).")
		}
	}

	private func slugForOracleExport(_ raw: String, fallback: String) -> String {
		let maxLength = 20
		let lower = raw.lowercased()
		var scalars: [UnicodeScalar] = []
		scalars.reserveCapacity(min(lower.unicodeScalars.count, maxLength))
		var lastWasSeparator = false

		for scalar in lower.unicodeScalars {
			let isASCIIAlphanumeric = (48...57).contains(Int(scalar.value))
				|| (97...122).contains(Int(scalar.value))
			if isASCIIAlphanumeric {
				if scalars.count >= maxLength { break }
				scalars.append(scalar)
				lastWasSeparator = false
			} else if !lastWasSeparator && !scalars.isEmpty {
				if scalars.count >= maxLength { break }
				scalars.append("-")
				lastWasSeparator = true
			}
		}

		var slug = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
		if slug.isEmpty {
			slug = fallback
		}
		return slug
	}

	private static let oracleExportTimestampFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd-HHmmss"
		return formatter
	}()

	static func writeGeneratedOracleExportFileForReadFileHandoff(
		fileManager: RepoFileManagerViewModel,
		path rawPath: String,
		content: String,
		destination: OracleExportDestination,
		sourceTool: String
	) async throws -> String {
		let resolvedPath = try standardizedGeneratedOracleExportPath(rawPath, destination: destination)
		_ = try loadedVisiblePrimaryRootForGeneratedOracleExport(
			fileManager: fileManager,
			resolvedPath: resolvedPath,
			destination: destination
		)

		do {
			try await fileManager.writeFileFromTool(
				userPath: resolvedPath,
				content: content,
				ifExists: "error",
				selectAfterCreate: false,
				pathResolutionPolicy: .literalPreferredIfStronger
			)
		} catch let mcpError as MCPError {
			throw mcpError
		} catch {
			throw MCPError.invalidParams(
				"Cannot create generated Oracle export for \(sourceTool) at '\(resolvedPath)': \(error.localizedDescription)"
			)
		}

		await fileManager.flushPendingDeltas(aggressive: true)
		try await validateGeneratedOracleExportReadableForReadFileHandoff(
			fileManager: fileManager,
			path: resolvedPath,
			destination: destination,
			sourceTool: sourceTool
		)
		return resolvedPath
	}

	static func validateGeneratedOracleExportReadableForReadFileHandoff(
		fileManager: RepoFileManagerViewModel,
		path rawPath: String,
		destination: OracleExportDestination,
		sourceTool: String
	) async throws {
		let resolvedPath = try standardizedGeneratedOracleExportPath(rawPath, destination: destination)
		let readableFile = await fileManager.resolveReadableFileForUserInput(
			resolvedPath,
			profile: .mcpRead,
			rootScopeOverride: .visibleWorkspace
		)

		guard case .workspace(let fileVM) = readableFile else {
			let reason = await generatedOracleExportUnreadableMessage(
				fileManager: fileManager,
				resolvedPath: resolvedPath,
				destination: destination,
				sourceTool: sourceTool
			)
			throw MCPError.invalidParams(reason)
		}

		guard fileVM.standardizedFullPath == resolvedPath else {
			throw MCPError.invalidParams(
				"Generated Oracle export for \(sourceTool) resolved to a different catalog path ('\(fileVM.standardizedFullPath)') than the returned path ('\(resolvedPath)'). Not returning oracle_export_path; pass exact generated export paths verbatim to read_file."
			)
		}

		do {
			_ = try await fileManager.readWorkspaceFileContentStrictly(fileVM)
		} catch {
			throw MCPError.invalidParams(
				"Generated Oracle export for \(sourceTool) was created at '\(resolvedPath)', but read_file cannot read it strictly: \(error.localizedDescription). Not returning oracle_export_path."
			)
		}
	}

	private static func standardizedGeneratedOracleExportPath(
		_ rawPath: String,
		destination: OracleExportDestination
	) throws -> String {
		let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
		let expandedPath = (trimmed as NSString).expandingTildeInPath
		guard expandedPath.hasPrefix("/") else {
			throw MCPError.invalidParams("Cannot create generated Oracle export: generated export path must be absolute before read_file handoff, got '\(rawPath)'.")
		}
		let resolvedPath = (expandedPath as NSString).standardizingPath
		let primaryRootPath = (destination.primaryRootPath as NSString).standardizingPath
		let rootPrefix = primaryRootPath.hasSuffix("/") ? primaryRootPath : primaryRootPath + "/"
		guard resolvedPath == primaryRootPath || resolvedPath.hasPrefix(rootPrefix) else {
			throw MCPError.invalidParams(
				"Cannot create generated Oracle export: resolved path '\(resolvedPath)' is outside the captured workspace primary root '\(primaryRootPath)'."
			)
		}
		return resolvedPath
	}

	@discardableResult
	private static func loadedVisiblePrimaryRootForGeneratedOracleExport(
		fileManager: RepoFileManagerViewModel,
		resolvedPath: String,
		destination: OracleExportDestination
	) throws -> FolderViewModel {
		let primaryRootPath = (destination.primaryRootPath as NSString).standardizingPath
		let rootPrefix = primaryRootPath.hasSuffix("/") ? primaryRootPath : primaryRootPath + "/"
		guard resolvedPath == primaryRootPath || resolvedPath.hasPrefix(rootPrefix) else {
			throw MCPError.invalidParams(
				"Cannot create generated Oracle export: path '\(resolvedPath)' is outside the captured workspace primary root '\(primaryRootPath)'."
			)
		}
		guard let root = fileManager.visibleRootFolders.first(where: { $0.standardizedFullPath == primaryRootPath }) else {
			throw MCPError.invalidParams(
				"Cannot create generated Oracle export at '\(resolvedPath)': captured primary root '\(primaryRootPath)' is not currently loaded/visible to MCP read_file. Generated export_response will not return oracle_export_path unless read_file can read the exact path."
			)
		}
		return root
	}

	private static func generatedOracleExportUnreadableMessage(
		fileManager: RepoFileManagerViewModel,
		resolvedPath: String,
		destination: OracleExportDestination,
		sourceTool: String
	) async -> String {
		let base = "Generated Oracle export for \(sourceTool) was created at '\(resolvedPath)', but MCP read_file cannot read that exact path. Not returning oracle_export_path."
		let visibleRoots = fileManager.visibleRootFolders
		guard !visibleRoots.isEmpty else {
			return base + " No loaded/visible workspace roots are available."
		}

		let primaryRootPath = (destination.primaryRootPath as NSString).standardizingPath
		guard visibleRoots.contains(where: { $0.standardizedFullPath == primaryRootPath }) else {
			return base + " The captured primary root '\(primaryRootPath)' is outside the currently loaded/visible roots: \(visibleRootList(visibleRoots))."
		}

		guard let containingRoot = visibleRoots
			.filter({ root in
				let rootPath = root.standardizedFullPath
				let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
				return resolvedPath == rootPath || resolvedPath.hasPrefix(rootPrefix)
			})
			.max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count }) else {
			return base + " The path is outside loaded/visible workspace roots: \(visibleRootList(visibleRoots))."
		}

		guard let service = fileManager.getFileSystemService(for: containingRoot.standardizedFullPath) else {
			return base + " The containing root '\(containingRoot.standardizedFullPath)' has no file-system service registered, so the path is non-resolvable by read_file."
		}

		let rootPath = containingRoot.standardizedFullPath
		let relativePath: String
		if resolvedPath == rootPath {
			relativePath = ""
		} else {
			let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
			relativePath = String(resolvedPath.dropFirst(rootPrefix.count))
		}

		switch await service.catalogRegularFileEligibility(relativePath: relativePath) {
		case .eligible:
			return base + " The path appears catalog-eligible under root '\(rootPath)' but did not resolve; this indicates a catalog/materialization mismatch."
		case .ineligible(let reason):
			switch reason {
			case .ignored:
				return base + " The export is ignored by workspace/catalog policy (\(reason.description)); choose a non-ignored export location or adjust ignore settings."
			case .symbolicLink, .symlinkComponent, .outsideCanonicalRoot:
				return base + " The export is blocked by a symlink/canonical-root policy check (\(reason.description))."
			case .outsideRoot:
				return base + " The export is outside the loaded root according to catalog eligibility (\(reason.description))."
			default:
				return base + " The export is not catalog-eligible for read_file (\(reason.description))."
			}
		}
	}

	private static func visibleRootList(_ roots: [FolderViewModel]) -> String {
		let paths = roots.map(\.standardizedFullPath)
		guard !paths.isEmpty else { return "<none>" }
		let shown = paths.prefix(5).joined(separator: ", ")
		let remaining = paths.count - min(paths.count, 5)
		return remaining > 0 ? "\(shown), … (+\(remaining) more)" : shown
	}

	/// Writes prompt export content, allowing absolute paths outside the workspace.
	private func writePromptExportFile(path rawPath: String, content: String) async throws -> String {
		let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
		let expandedPath = (trimmed as NSString).expandingTildeInPath
		let standardizedPath = (expandedPath as NSString).standardizingPath
		let resolvedPath = expandedPath.hasPrefix("/") ? standardizedPath : trimmed

		// Relative paths should continue to be resolved inside the workspace.
		guard resolvedPath.hasPrefix("/") else {
			try await writeFile(path: resolvedPath, content: content, overwrite: false, addToSelection: false)
			return resolvedPath
		}

		let isUnderRoot = fileManager.rootFolders.contains { root in
			let rootPath = (root.fullPath as NSString).standardizingPath
			let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
			return resolvedPath == rootPath || resolvedPath.hasPrefix(rootPrefix)
		}

		if isUnderRoot {
			try await writeFile(path: resolvedPath, content: content, overwrite: false, addToSelection: false)
			return resolvedPath
		}

		let url = URL(fileURLWithPath: resolvedPath)
		let fm = FileManager.default
		if fm.fileExists(atPath: url.path) {
			throw MCPError.invalidParams("path already exists: \(resolvedPath).")
		}
		do {
			try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
			try content.write(to: url, atomically: true, encoding: .utf8)
		} catch {
			throw MCPError.invalidParams("File creation failed for '\(resolvedPath)': \(error.localizedDescription)")
		}

		return resolvedPath
	}

	private func renameFile(oldPath: String, newPath: String) async throws {
		try await fileManager.renameFileFromTool(oldPath: oldPath, newPath: newPath)
	}

	/// Returns a flat JSON-serialisable array of {[path,kind,mtime]}
	private func flatTree() async -> [[String:Any]] {
		func walk(_ folder: FolderViewModel,
					into arr: inout [[String:Any]]) {
			arr.append([
				"path": folder.relativePath,
				"kind": "folder",
				"mtime": folder.modificationDate.timeIntervalSince1970
			])
			for child in folder.children {
				switch child {
				case .folder(let f): walk(f, into: &arr)
				case .file(let fi):
					arr.append([
						"path": fi.relativePath,
						"kind": "file",
						"mtime": fi.modificationDate.timeIntervalSince1970
					])
				}
			}
		}
		var res: [[String:Any]] = []
		for root in fileManager.rootFolders {
			walk(root, into: &res)
		}
		return res
	}

	// (request_plan implementation removed)

	/// Builds an ASCII tree listing **only** those files whose `fileAPI`
	/// has already been populated (i.e. code-map exists).
    private func buildCodeMapFileTree() async -> String {
		let (roots, filePathDisplay) = await MainActor.run {
			(fileManager.rootFolders, promptVM.filePathDisplayOption)
		}

        // If no workspace/roots are loaded, return a helpful message instead of empty output
        guard !roots.isEmpty else {
            return await workspaceContextMessage(forOperation: ToolNames.getFileTree, path: nil)
        }

		// Run the heavy computation off MainActor
		return await Task.detached(priority: .userInitiated) {
			CodeMapExtractor.generateCodeMapFileTree(
				rootFolders: roots,
				filePathDisplay: filePathDisplay
			)
		}.value
	}

	// MARK: - File-tree builder for get_file_tree
	/// Delegates to CodeMapExtractor for unified file tree generation with progressive fallbacks
	private func buildFileTreeResult(
        mode: String,
        maxDepth: Int?,
        includeHidden: Bool,
        selectedIDs: Set<UUID>
	) async -> FileTreeResult {

        let (roots, filePathDisplay) = await MainActor.run {
            (fileManager.visibleRootFolders, promptVM.filePathDisplayOption)
        }

        // No roots loaded – return contextual guidance
        if roots.isEmpty {
			let msg = await workspaceContextMessage(forOperation: ToolNames.getFileTree, path: nil)
			return FileTreeResult(
				tree: msg,
				usedSelectedMarker: false,
				usedCodeMapMarker: false,
				wasTruncated: false,
				note: "No workspace loaded"
			)
        }

		// Run the heavy computation off MainActor
		let showCodeMapMarkers = await MainActor.run { !promptVM.codeMapsGloballyDisabled }
		return await Task.detached(priority: .userInitiated) {
			CodeMapExtractor.generateFileTreeForRootsResult(
                rootFolders: roots,
                mode: mode,
				maxDepth: maxDepth,
				includeHidden: includeHidden,
				filePathDisplay: filePathDisplay,
				selectedFileIDs: selectedIDs,
				includeLegend: false,
				isMCPContext: true,
				showCodeMapMarkers: showCodeMapMarkers
			)
		}.value
	}

	// MARK: - File-tree builder overload with starting path
	/// Builds a file tree starting from a specific folder path, applying depth/mode/hidden settings from that point
private func buildFileTreeResult(
		mode: String,
		maxDepth: Int?,
		includeHidden: Bool,
		startPath: String?,
		selectedIDs: Set<UUID>
	) async -> FileTreeResult {
		// If no starting path is provided, fall back to the existing full-roots builder
		guard let rawStart = startPath, !rawStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return await buildFileTreeResult(mode: mode, maxDepth: maxDepth, includeHidden: includeHidden, selectedIDs: selectedIDs)
		}

		// Snapshot UI-bound state on the main actor and resolve the starting folder
        let (roots, filePathDisplay, startFullPath, resolutionIssue) = await MainActor.run { () -> ([FolderViewModel], FilePathDisplay, String?, PathResolutionIssue?) in
            let roots = fileManager.rootFolders
            let display = promptVM.filePathDisplayOption
            if let issue = fileManager.exactPathResolutionIssue(for: rawStart, kind: .folder) {
                return (roots, display, nil, issue)
            }
            if let startFolder = fileManager.resolveFolderForUserInput(rawStart) {
                return (roots, display, startFolder.fullPath, nil)
            }
            return (roots, display, nil, nil)
        }

        guard let startFull = startFullPath else {
			if let resolutionIssue {
				return FileTreeResult(
					tree: PathResolutionIssueRenderer.message(for: resolutionIssue),
					usedSelectedMarker: false,
					usedCodeMapMarker: false,
					wasTruncated: false,
					note: "Path could not be resolved"
				)
			}
			let msg = await workspaceContextMessage(forOperation: ToolNames.getFileTree, path: rawStart)
			return FileTreeResult(
				tree: msg,
				usedSelectedMarker: false,
				usedCodeMapMarker: false,
				wasTruncated: false,
				note: "Requested path is outside the loaded roots"
			)
        }

		// Heavy work off the main actor
		let showCodeMapMarkers = await MainActor.run { !promptVM.codeMapsGloballyDisabled }
		return await Task.detached(priority: .userInitiated) {
			CodeMapExtractor.generateFileTreeStartingAtPathResult(
				startFolderFullPath: startFull,
				rootFolders: roots,
				mode: mode,
				maxDepth: maxDepth,
				includeHidden: includeHidden,
				filePathDisplay: filePathDisplay,
				selectedFileIDs: selectedIDs,
				includeLegend: false,
				isMCPContext: true,
				showCodeMapMarkers: showCodeMapMarkers
			)
		}.value
	}

	// MARK: - Error handling helpers
	nonisolated static func friendlySearchErrorParts(for pattern: String, isRegex: Bool, error: SearchPatternError) -> (issue: String, suggestion: String?) {
		SearchPatternErrorFormatter.parts(for: pattern, isRegex: isRegex, error: error)
	}

	private static func friendlySearchError(for pattern: String, isRegex: Bool, error: SearchPatternError) -> String {
		let base = error.localizedDescription
		switch error {
		case .unmatchedParentheses, .unmatchedBrackets, .invalidEscape, .invalidQuantifier:
			if isRegex {
				return base + " Tip: If you intended a literal search, set interpretation=\"literal\" (or regex=false). For regex, escape special characters: \"(\" as \"\\(\", \")\" as \"\\)\". Remember JSON doubles backslashes, so \"\\(\" in regex is written as \"\\\\(\" in JSON."
			} else {
				return base + " Tip: You're in literal mode. Backslashes are matched as normal characters. If you meant a regex, set interpretation=\"regex\" (or regex=true) and escape special characters (e.g., \"\\(\")."
			}
		default:
			return base
		}
	}

	nonisolated static func sanitizeSearchScopeInputs(_ inputs: [String]) -> [String] {
		var seen = Set<String>()
		var sanitized: [String] = []
		sanitized.reserveCapacity(inputs.count)
		for input in inputs {
			let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			if seen.insert(trimmed).inserted {
				sanitized.append(trimmed)
			}
		}
		return sanitized
	}

	nonisolated static func pathFilterSuggestion(
		hadPathFilter: Bool,
		scopedFileCount: Int?
	) -> String? {
		guard hadPathFilter, (scopedFileCount ?? 0) == 0 else { return nil }
		return "The specified path filter resolved to no files in the current workspace. Use get_file_tree to inspect the project structure and confirm the path."
	}

	private nonisolated static func parseContextAlias(_ args: [String: Value]) -> Int? {
		// Direct key "-C"
		if let alias = args["-C"] {
			if let value = alias.intValue { return value }
			if let string = alias.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
			   let parsed = Int(string) {
				return parsed
			}
		}

		// Support variants like "-C: 2" or "-C=3"
		for (key, value) in args {
			let lower = key.lowercased()
			guard lower.hasPrefix("-c") else { continue }

			if lower == "-c" {
				if let intValue = value.intValue { return intValue }
				if let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
				   let parsed = Int(string) {
					return parsed
				}
				continue
			}

			var suffix = key.dropFirst(2)
			while let first = suffix.first, first == ":" || first == "=" || first == " " {
				suffix = suffix.dropFirst()
			}
			let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
			if let parsed = Int(trimmed) {
				return parsed
			}
		}

		return nil
	}

	@MainActor
	private func workspaceContextMessage(forOperation op: String? = nil, path: String? = nil) async -> String {
		let roots = fileManager.visibleRootFolders
		if roots.isEmpty {
			return "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
		}

		// Roots exist – optionally add path hint and list roots
		if let p = path, !p.isEmpty {
			let normalized = fileManager.normalizeUserInputPath(p)
			let location = await fileManager.getFileSystemServiceForRelativePath(normalized, exactMatchOnly: false)
			if location == nil {
				// Include root names and full paths for clarity in multi-root setups
				let rootsList = roots.map { "\($0.name) → \($0.fullPath)" }.joined(separator: "; ")
				return "The requested path '\(p)' is not inside any loaded folder in this window. Loaded roots: \(rootsList). Use the 'manage_workspaces' tool to switch to a workspace containing this path, or add the folder to the current workspace."
			}
		}

		// Include root names and full paths for clarity
		let rootsList = roots.map { "\($0.name) → \($0.fullPath)" }.joined(separator: "; ")
		return "Loaded roots: \(rootsList)"
	}

	@MainActor
	private func requireWorkspaceForTool(_ toolName: String) async throws {
		if fileManager.rootFolders.isEmpty {
			let msg = await workspaceContextMessage(forOperation: toolName, path: nil)
			throw MCPError.invalidParams(msg)
		}
	}

	@MainActor
	private func mapFileManagerErrorToMCP(_ error: FileManagerError, action: String, path: String?) async -> MCPError {
		switch error {
		case .fileSystemServiceNotFoundWithContext(let context):
			return MCPError.invalidParams(context)
		default:
			let ctx = await workspaceContextMessage(forOperation: action, path: path)
			return MCPError.invalidParams(ctx)
		}
	}

	// MARK: - Tab workspace helpers
	func tabCodeMaps(for paths: [String], maxResults: Int = 25) async -> (maps: [String: FileAPI], omitted: Int) {
		await getCodeMaps(for: paths, maxResults: maxResults)
	}

	@MainActor
	func tabRootFoldersAndDisplayOption() -> ([FolderViewModel], FilePathDisplay) {
		(fileManager.visibleRootFolders, promptVM.filePathDisplayOption)
	}

	@MainActor
	func tabWorkspaceContextMessage(forOperation op: String? = nil, path: String? = nil) async -> String {
		await workspaceContextMessage(forOperation: op, path: path)
	}

	var tabFileTreeToolName: String { ToolNames.getFileTree }

	// MARK: - Selection helpers
	func selectionFindFiles(
		atPaths paths: [String],
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> [String: FileViewModel] {
		await fileManager.findFiles(
			atPaths: paths,
			profile: .mcpSelection,
			rootScopeOverride: lookupRootScope
		)
	}

	@MainActor
	func selectionFindFile(byFullPath path: String) -> FileViewModel? {
		fileManager.findFileByFullPath(path)
	}

	var selectionCodemapAutoEnabled: Bool {
		fileManager.codemapAutoEnabled
	}

	@MainActor
	func selectionTokenCount(for file: FileViewModel) -> Int {
		promptVM.fileTokenInfo[file.id]?.count ?? file.cachedTokenCount ?? 0
	}

	@MainActor
	func selectionCodemapTokenEstimate(for file: FileViewModel, displayPath: String) -> Int {
		// First check cached codemap tokens from TokenInfo
		if let cached = promptVM.fileTokenInfo[file.id]?.codemapCount, cached > 0 {
			return cached
		}
		// Fallback: compute from fileAPI if available
		if let api = file.fileAPI {
			return TokenCalculationService.estimateTokens(for: api.getFullAPIDescription(displayPath: displayPath))
		}
		return 0
	}

	/// Returns the cached full file token count (not codemap tokens).
	/// Use this when you need the actual raw file content tokens regardless of rendering mode.
	@MainActor
	func selectionTokenCache(for file: FileViewModel) -> Int? {
		// Use fullCount to always get raw file content tokens, not codemap tokens
		if let info = promptVM.fileTokenInfo[file.id] {
			// If fullCount is 0 but count is non-zero, the file was only loaded as codemap
			// In that case, fall back to cachedTokenCount if available
			if info.fullCount > 0 {
				return info.fullCount
			}
		}
		return nil
	}

	func selectionSnapshot() async -> (selected: [FileViewModel], codemap: [FileViewModel], slices: [UUID: [LineRange]], autoEnabled: Bool) {
		await MainActor.run {
			(fileManager.selectedFiles, fileManager.autoCodemapFiles, fileManager.selectionSlicesByFileID, fileManager.codemapAutoEnabled)
		}
	}
}
