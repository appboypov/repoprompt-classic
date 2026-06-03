import Foundation
import MCP

struct OracleExportFile: Sendable, Equatable {
	let path: String
	let instruction: String
}

struct OracleExportDestination: Sendable, Equatable {
	let workspaceID: UUID
	let windowID: Int
	let tabID: UUID?
	let primaryRootPath: String
}

struct OracleExportRequest: Sendable {
	let sourceTool: String
	let mode: String
	let message: String
	let chatID: String?
	let response: String?
	let destination: OracleExportDestination?

	init(
		sourceTool: String,
		mode: String,
		message: String,
		chatID: String?,
		response: String?,
		destination: OracleExportDestination? = nil
	) {
		self.sourceTool = sourceTool
		self.mode = mode
		self.message = message
		self.chatID = chatID
		self.response = response
		self.destination = destination
	}
}

enum AgentOracleExport {
	static func instruction(path: String) -> String {
		"""
		Read the Oracle export at \(path) with `read_file`. Use this exact path verbatim; do not shorten it, relativize it, or use only the filename.
		"""
	}


	static func oracleMarkdown(request: OracleExportRequest, exportedAt _: Date = Date()) -> String {
		let title = switch request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "plan":
			"# Oracle Plan"
		case "review":
			"# Oracle Review"
		default:
			"# Oracle Response"
		}
		let response: String
		if let responseText = request.response,
			!responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			response = responseText
		} else {
			response = "_No response text was returned._"
		}
		return "\(title)\n\n\(response)"
	}
}

struct AgentRunWaitScopeCompletion: Sendable, Equatable {
	enum Reason: String, Sendable, Equatable {
		case snapshotReady = "snapshot_ready"
		case timedOut = "timed_out"
		case expired
		case cancelled
		case error
	}

	let reason: Reason
	let result: String?
	let winnerSessionID: UUID?
	let pendingSessionIDs: Set<UUID>
	let errorDescription: String?
}

private enum MultiWaitDisposition: Sendable {
	case actionable(AgentRunMCPSnapshot)
	case nonActionableWake(AgentRunMCPSnapshot, AgentRunSessionStore.WakeReason)
	case timedOut
	case expired
	case cancelled
}

private struct WaitAnyResult: Sendable {
	let sessionID: UUID
	let disposition: MultiWaitDisposition
}

private struct CancelledSingleWaitResolution: Sendable {
	let rawValue: Value
	let completion: AgentRunWaitScopeCompletion
}

private final class WaitScopeCompletionBox: @unchecked Sendable {
	private let lock = NSLock()
	private var storedCompletion: AgentRunWaitScopeCompletion?

	func set(_ completion: AgentRunWaitScopeCompletion) {
		lock.lock()
		storedCompletion = completion
		lock.unlock()
	}

	func get() -> AgentRunWaitScopeCompletion? {
		lock.lock()
		let completion = storedCompletion
		lock.unlock()
		return completion
	}
}

private let agentRunSteeringWakeNote = "Steering interrupted this wait; the agent run has not completed. After responding to the user, call agent_run.wait for this session again to resume waiting."
private let waitAnyLiveReconcileIntervalSeconds: TimeInterval = 2.0

@MainActor
struct AgentRunMCPToolService {
	typealias RequestMetadata = MCPServerViewModel.RequestMetadata
	typealias HeartbeatOperation = @Sendable () async throws -> Value
	typealias StartRun = @MainActor (
		_ target: AgentModeViewModel.MCPSessionTarget,
		_ message: String,
		_ metadata: RequestMetadata,
		_ bindCurrentRequestToTab: @escaping AgentExternalMCPRunStarter.BindCurrentRequestToTab,
		_ agentModeVM: AgentModeViewModel,
		_ agentRaw: String?,
		_ modelRaw: String?,
		_ reasoningEffortRaw: String?,
		_ taskLabelKind: AgentModelCatalog.TaskLabelKind?,
		_ workflow: AgentWorkflowDefinition?
	) async throws -> AgentExternalMCPRunStarter.StartOutcome

	static let defaultWaitTimeoutSeconds: TimeInterval = 300
	static let defaultStartTaskLabelKind: AgentModelCatalog.TaskLabelKind = .pair

	static func defaultTaskLabelForStart(
		resolvedTabID: UUID?,
		workflow _: AgentWorkflowDefinition? = nil
	) -> AgentModelCatalog.TaskLabelKind? {
		// `agent_run.start` creates a new session by default; when callers omit
		// `model_id`, resolve through the global Pair role default. Workflows do
		// not override that default. If a caller explicitly targets an existing
		// tab, leave that tab's current selection alone.
		resolvedTabID == nil ? defaultStartTaskLabelKind : nil
	}

	let toolName: String
	let captureRequestMetadata: () async -> RequestMetadata
	let requireTargetWindow: () throws -> WindowState
	let resolveRequestedTabID: (_ args: [String: Value]) throws -> UUID?
	let resolveSpawnSourceTabID: (_ metadata: RequestMetadata) async -> UUID?
	var validateSpawnRouting: (_ metadata: RequestMetadata, _ sourceTabID: UUID?) async throws -> Void = { _, _ in }
	let resolveSpawnParentSessionID: (_ metadata: RequestMetadata, _ targetWindow: WindowState) async -> UUID?
	var resolveSpawnParentSessionIDFromSourceTabID: ((_ sourceTabID: UUID, _ targetWindow: WindowState) async -> UUID?)? = nil
	let bindCurrentRequestToTab: (_ tabID: UUID, _ metadata: RequestMetadata) async throws -> Void
	let withHeartbeat: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String, _ operation: @escaping HeartbeatOperation) async throws -> Value
	var beginAgentRunWait: (_ metadata: RequestMetadata, _ sessionIDs: Set<UUID>, _ timeoutSeconds: TimeInterval?) async -> UUID? = { _, _, _ in nil }
	var endAgentRunWait: (_ token: UUID, _ completion: AgentRunWaitScopeCompletion) async -> Void = { _, _ in }
	let startRun: StartRun
	var currentSnapshotProvider: (@Sendable (_ sessionID: UUID, _ agentModeVM: AgentModeViewModel) async -> AgentRunMCPSnapshot?)? = nil

	func execute(args: [String: Value]) async throws -> Value {
		let op = normalizedString(args["op"])?.lowercased() ?? "wait"
		switch op {
		case "start":
			return try await executeStart(args: args)
		case "poll":
			return try await executeWait(args: args, forcePoll: true)
		case "wait":
			return try await executeWait(args: args)
		case "cancel":
			return try await executeCancel(args: args)
		case "steer":
			return try await executeSteer(args: args)
		case "respond":
			return try await executeRespond(args: args)
		default:
			throw MCPError.invalidParams("Unsupported agent_run op '\(op)'. Use start, poll, wait, cancel, steer, or respond.")
		}
	}

	private func executeStart(args: [String: Value]) async throws -> Value {
		let message = try resolveMessage(args["message"], name: "message")
		let workflow = try resolveWorkflow(args: args)
		// start always creates a new session — reject explicit session_id
		if normalizedString(args["session_id"]) != nil {
			throw MCPError.invalidParams("agent_run.start always creates a new session. Use agent_run op=steer with session_id to continue an existing session.")
		}
		let detach = parseBool(args["detach"]) ?? false
		let timeoutSeconds = try parseTimeoutSeconds(args["timeout"]) ?? Self.defaultWaitTimeoutSeconds

		let metadata = await captureRequestMetadata()
		let targetWindow = try requireTargetWindow()
		guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
			throw MCPError.invalidParams("No active workspace available for agent_run.start.")
		}
		guard workspace.isSystemWorkspace == false else {
			throw MCPError.invalidParams("Cannot start an agent run from the default system workspace. Open or select a project workspace and try again.")
		}

		let agentModeVM = targetWindow.agentModeViewModel
		let sourceTabID = await resolveSpawnSourceTabID(metadata)
#if DEBUG
		AgentModePerfDiagnostics.event("mcp.routing.agentRunStartResolvedSource", tabID: sourceTabID, fields: [
			"connectionID": metadata.connectionID?.uuidString ?? "nil",
			"clientName": metadata.clientName ?? "nil",
			"windowID": metadata.windowID.map(String.init) ?? "nil",
			"sourceTabID": sourceTabID?.uuidString ?? "nil",
			"workflowID": workflow?.id ?? "nil",
			"workflowName": workflow?.displayName ?? "nil"
		])
#endif
		try await validateSpawnRouting(metadata, sourceTabID)
		try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: sourceTabID)
		let spawnParentSessionID: UUID?
		if let sourceTabID,
			let resolveSpawnParentSessionIDFromSourceTabID {
			spawnParentSessionID = await resolveSpawnParentSessionIDFromSourceTabID(sourceTabID, targetWindow)
		} else {
			spawnParentSessionID = await resolveSpawnParentSessionID(metadata, targetWindow)
		}
		let resolvedTabID = try resolveRequestedTabID(args)
#if DEBUG
		AgentModePerfDiagnostics.event("mcp.routing.agentRunStartParentResolved", tabID: sourceTabID, fields: [
			"connectionID": metadata.connectionID?.uuidString ?? "nil",
			"windowID": metadata.windowID.map(String.init) ?? "nil",
			"sourceTabID": sourceTabID?.uuidString ?? "nil",
			"parentSessionID": spawnParentSessionID?.uuidString ?? "nil",
			"requestedTabID": resolvedTabID?.uuidString ?? "nil"
		])
#endif

		// Compute the default task label before target creation. Omitted `model_id`
		// for agent_run.start resolves through the global Pair role default.
		let defaultTaskLabel = Self.defaultTaskLabelForStart(resolvedTabID: resolvedTabID, workflow: workflow)

		// Validate model selection before creating a target. Role labels resolve through global role defaults.
		let selection = try AgentMCPSelectionResolver.resolve(
			modelID: normalizedString(args["model_id"]),
			defaultTaskLabel: defaultTaskLabel,
			availability: targetWindow.apiSettingsViewModel.agentModeAvailabilityContext
		)

		let sessionName = normalizedString(args["session_name"])
		let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
			tabID: resolvedTabID,
			sessionID: nil,
			createIfNeeded: true,
			sessionName: sessionName,
			parentSessionID: spawnParentSessionID
		)
#if DEBUG
		AgentModePerfDiagnostics.event("mcp.routing.agentRunStartTargetResolved", tabID: target.tabID, fields: [
			"connectionID": metadata.connectionID?.uuidString ?? "nil",
			"targetSessionID": target.sessionID?.uuidString ?? "nil",
			"parentSessionID": spawnParentSessionID?.uuidString ?? "nil",
			"taskLabel": selection.taskLabelKind?.rawValue ?? "nil",
			"agent": selection.agentRaw ?? "nil",
			"model": selection.modelRaw ?? "nil",
			"targetOrigin": String(describing: target.origin)
		])
#endif
		let outcome: AgentExternalMCPRunStarter.StartOutcome
		do {
			outcome = try await startRun(
				target,
				message,
				metadata,
				bindCurrentRequestToTab,
				agentModeVM,
				selection.agentRaw,
				selection.modelRaw,
				nil,
				selection.taskLabelKind,
				workflow
			)
		} catch {
			await agentModeVM.mcpDiscardSessionTarget(target)
			throw error
		}
		if detach || outcome.snapshot.status != .running || timeoutSeconds <= 0 {
			return decoratedRunValue(snapshot: outcome.snapshot, workflow: workflow, delivery: outcome.delivery)
		}
		return try await waitForInterestingState(
			sessionID: outcome.snapshot.sessionID,
			agentModeVM: agentModeVM,
			metadata: metadata,
			timeoutSeconds: timeoutSeconds,
			stage: "starting",
			message: "Waiting for the started run to finish or request input...",
			workflow: workflow,
			initialDelivery: outcome.delivery
		)
	}

	private func executeWait(args: [String: Value], forcePoll: Bool = false) async throws -> Value {
		if args["session_ids"] != nil {
			if forcePoll {
				return try await executePollMany(args: args)
			}
			return try await executeWaitAny(args: args)
		}

		let targetWindow = try requireTargetWindow()
		let agentModeVM = targetWindow.agentModeViewModel
		let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
		let timeoutSeconds = forcePoll ? 0 : (try parseTimeoutSeconds(args["timeout"]) ?? Self.defaultWaitTimeoutSeconds)
		let metadata = await captureRequestMetadata()
		let initialSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
		if initialSnapshot.status != .running || timeoutSeconds <= 0 {
			return decoratedRunValue(snapshot: initialSnapshot)
		}
		return try await waitForInterestingState(
			sessionID: sessionID,
			agentModeVM: agentModeVM,
			metadata: metadata,
			timeoutSeconds: timeoutSeconds,
			stage: "waiting",
			message: "Waiting for the agent run to finish or request input...",
			liveSnapshot: initialSnapshot
		)
	}

	private func executeWaitAny(args: [String: Value]) async throws -> Value {
		let references = try parseSessionIDArray(args)
		let targetWindow = try requireTargetWindow()
		let agentModeVM = targetWindow.agentModeViewModel
		let sessionIDs = try await resolveControlSessionIDs(references, targetWindow: targetWindow, agentModeVM: agentModeVM)

		// Single-element waits should preserve the existing single-session response shape.
		if sessionIDs.count == 1 {
			var singleArgs = args
			singleArgs.removeValue(forKey: "session_ids")
			singleArgs["session_id"] = .string(sessionIDs[0].uuidString)
			return try await executeWait(args: singleArgs)
		}

		let timeoutSeconds = try parseTimeoutSeconds(args["timeout"]) ?? Self.defaultWaitTimeoutSeconds
		let metadata = await captureRequestMetadata()
		let initialSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
		for snapshot in initialSnapshots where snapshot.status == .running {
			await reconcileStoreForBlockingWait(sessionID: snapshot.sessionID, currentSnapshot: snapshot)
		}
		print("[AgentRunSteeringWake] agent_run wait-any begin sessions=\(sessionIDs.map(\.uuidString).joined(separator: ",")) timeout=\(timeoutSeconds) initial=\(statusSummary(initialSnapshots))")

		if let ready = initialSnapshots.first(where: { isInterestingSnapshot($0) }) {
			return decoratedMultiWaitValue(
				snapshot: ready,
				sessionIDs: sessionIDs,
				result: ready.status == .expired ? "expired" : "snapshot_ready",
				pendingSessionIDs: pendingSessionIDs(from: initialSnapshots)
			)
		}

		if timeoutSeconds <= 0 {
			return decoratedMultiWaitValue(
				snapshot: initialSnapshots[0],
				sessionIDs: sessionIDs,
				result: "timed_out",
				snapshots: initialSnapshots,
				pendingSessionIDs: pendingSessionIDs(from: initialSnapshots)
			)
		}

		let waitScopeToken = await beginAgentRunWait(metadata, Set(sessionIDs), timeoutSeconds)
		do {
			let value = try await withHeartbeat(
				metadata.connectionID,
				toolName,
				"waiting",
				"Waiting for the first agent run to finish or request input..."
			) {
				try await waitForAnyInterestingState(
					sessionIDs: sessionIDs,
					agentModeVM: agentModeVM,
					timeoutSeconds: timeoutSeconds,
					initialSnapshots: initialSnapshots
				)
			}
			let completion = waitScopeCompletion(from: value, fallbackSessionIDs: sessionIDs)
			print("[AgentRunSteeringWake] agent_run wait-any result sessions=\(sessionIDs.map(\.uuidString).joined(separator: ",")) reason=\(completion.reason.rawValue) winner=\(completion.winnerSessionID?.uuidString ?? "none") pending=\(completion.pendingSessionIDs.map(\.uuidString).sorted().joined(separator: ","))")
			if let waitScopeToken {
				await endAgentRunWait(waitScopeToken, completion)
			}
			return value
		} catch is CancellationError {
			if let value = await waitAnyCancellationInterruptValueIfResumable(
				sessionIDs: sessionIDs,
				agentModeVM: agentModeVM,
				fallbackSnapshots: initialSnapshots
			) {
				let completion = waitScopeCompletion(from: value, fallbackSessionIDs: sessionIDs)
				print("[AgentRunSteeringWake] agent_run wait-any converted cancellation to interrupt sessions=\(sessionIDs.map(\.uuidString).joined(separator: ",")) pending=\(completion.pendingSessionIDs.map(\.uuidString).sorted().joined(separator: ","))")
				if let waitScopeToken {
					await endAgentRunWait(waitScopeToken, completion)
				}
				return value
			}
			let completion = AgentRunWaitScopeCompletion(reason: .cancelled, result: "cancelled", winnerSessionID: nil, pendingSessionIDs: Set(sessionIDs), errorDescription: nil)
			print("[AgentRunSteeringWake] agent_run wait-any cancelled sessions=\(sessionIDs.map(\.uuidString).joined(separator: ","))")
			if let waitScopeToken {
				await endAgentRunWait(waitScopeToken, completion)
			}
			throw CancellationError()
		} catch {
			let completion = AgentRunWaitScopeCompletion(reason: .error, result: "error", winnerSessionID: nil, pendingSessionIDs: Set(sessionIDs), errorDescription: String(describing: error))
			print("[AgentRunSteeringWake] agent_run wait-any error sessions=\(sessionIDs.map(\.uuidString).joined(separator: ",")) error=\(error)")
			if let waitScopeToken {
				await endAgentRunWait(waitScopeToken, completion)
			}
			throw error
		}
	}

	private func executePollMany(args: [String: Value]) async throws -> Value {
		let references = try parseSessionIDArray(args)
		let targetWindow = try requireTargetWindow()
		let agentModeVM = targetWindow.agentModeViewModel
		let sessionIDs = try await resolveControlSessionIDs(references, targetWindow: targetWindow, agentModeVM: agentModeVM)
		let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
		return decoratedMultiPollValue(sessionIDs: sessionIDs, snapshots: snapshots)
	}

	private func executeCancel(args: [String: Value]) async throws -> Value {
		let targetWindow = try requireTargetWindow()
		let agentModeVM = targetWindow.agentModeViewModel
		let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
		let initialSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
		if initialSnapshot.status == .expired {
			throw MCPError.invalidParams("This session control handle is no longer active.")
		}
		if initialSnapshot.status.isTerminal {
			throw MCPError.invalidParams("The run is not currently active (status: \(initialSnapshot.status.rawValue)) and cannot be cancelled.")
		}
		guard let session = agentModeVM.mcpControlledSession(sessionID: sessionID), session.runState.isActive else {
			throw MCPError.invalidParams("The run is not currently active and cannot be cancelled.")
		}
		let metadata = await captureRequestMetadata()
		let cancelResult = try await withHeartbeat(
			metadata.connectionID,
			toolName,
			"cancelling",
			"Cancelling the agent run..."
		) {
			await agentModeVM.cancelAgentRun(tabID: session.tabID, waitForCleanup: true)
			await Task.yield()
			return await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM).toValue()
		}
		if let parsed = cancelResult.objectValue.flatMap(snapshot(from:)) {
			return decoratedRunValue(snapshot: parsed)
		}
		return cancelResult
	}

	private func executeSteer(args: [String: Value]) async throws -> Value {
		let targetWindow = try requireTargetWindow()
		let agentModeVM = targetWindow.agentModeViewModel
		let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
		let text = try resolveMessage(args["message"], name: "message")
		let workflow = try resolveWorkflow(args: args)
		let delivery: AgentModeViewModel.MCPInstructionDispatch
		let snapshot: AgentRunMCPSnapshot
		if let controlledSession = agentModeVM.mcpControlledSession(sessionID: sessionID),
			controlledSession.runState.isActive {
			// Clear stale snapshot before dispatching so that a previous turn's terminal
			// snapshot doesn't cause waitUntilInteresting to return immediately.
			await AgentRunSessionStore.resetSnapshotForNewTurn(sessionID: sessionID)
			delivery = try await agentModeVM.mcpDispatchInstruction(
				sessionID: sessionID,
				text: text,
				allowStartingRun: true,
				workflow: workflow
			)
			await Task.yield()
			snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
		} else {
			// Mark follow-up pending so mcpSnapshot(for:) returns .running during the
			// async gap before the new run actually starts.  Also clear the store so
			// the previous turn's terminal snapshot doesn't block new snapshots.
			await AgentRunSessionStore.resetSnapshotForNewTurn(sessionID: sessionID)
			agentModeVM.setMCPFollowUpRunPending(sessionID: sessionID, true)
			let metadata = await captureRequestMetadata()
			// Carry forward the existing task label kind so `prepareCodexController()`
			// doesn't see a mismatch and invalidate the controller mid-follow-up.
			let existingSession = agentModeVM.mcpControlledSession(sessionID: sessionID)
			let existingTaskLabelKind = existingSession?.mcpControlContext?.taskLabelKind
			// Carry forward reasoning effort so `normalizeCodexSelectionForSession`
			// doesn't reset the effort that was set during the initial start call.
			let existingReasoningEffort = existingSession?.selectedReasoningEffortRaw
			let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
				tabID: nil,
				sessionID: sessionID,
				createIfNeeded: false,
				sessionName: nil
			)
			let outcome = try await startRun(
				target,
				text,
				metadata,
				bindCurrentRequestToTab,
				agentModeVM,
				nil,
				nil,
				existingReasoningEffort,
				existingTaskLabelKind,
				workflow
			)
			delivery = outcome.delivery
			snapshot = outcome.snapshot
		}
		await Task.yield()

		// Steer-and-wait: optionally block until the agent reaches an interesting state
		let shouldWait: Bool = {
			if let explicit = parseBool(args["wait"]) { return explicit }
			if args["timeout_seconds"] != nil { return true }
			return false
		}()
		let rawSteerTimeoutSeconds = args["timeout_seconds"]
		let ignoredTimeoutWarning: String?
		let steerTimeoutSeconds: TimeInterval?
		if shouldWait == false, rawSteerTimeoutSeconds != nil {
			ignoredTimeoutWarning = "Ignoring timeout_seconds because wait=false; the steering instruction was accepted without waiting."
			steerTimeoutSeconds = nil
		} else {
			ignoredTimeoutWarning = nil
			steerTimeoutSeconds = try parseTimeoutSeconds(rawSteerTimeoutSeconds)
		}
		let shouldBlockForSteeredOutput = delivery.isActiveRunDispatch
			? snapshot.interaction == nil
			: (!snapshot.status.isTerminal && snapshot.interaction == nil)
		if shouldWait, shouldBlockForSteeredOutput {
			let metadata = await captureRequestMetadata()
			let timeout = steerTimeoutSeconds ?? Self.defaultWaitTimeoutSeconds
			if timeout > 0 {
				if delivery.isActiveRunDispatch, snapshot.status.isTerminal {
					// Active steering can briefly observe a stale terminal snapshot from the
					// previous/startup turn immediately after local dispatch. Reset the store
					// so the steer waiter blocks for the provider's steering result instead
					// of returning old output as if it came from the new instruction.
					await AgentRunSessionStore.resetSnapshotForNewTurn(sessionID: sessionID)
				}
				return try await waitForInterestingState(
					sessionID: sessionID,
					agentModeVM: agentModeVM,
					metadata: metadata,
					timeoutSeconds: timeout,
					stage: "steering",
					message: "Waiting for the steered run to finish or request input...",
					workflow: workflow,
					initialDelivery: delivery,
					liveSnapshot: snapshot.status == .running ? snapshot : nil
				)
			}
		}
		return decoratedRunValue(
			snapshot: snapshot,
			workflow: workflow,
			delivery: delivery,
			warning: ignoredTimeoutWarning
		)
	}

	private func executeRespond(args: [String: Value]) async throws -> Value {
		let targetWindow = try requireTargetWindow()
		let agentModeVM = targetWindow.agentModeViewModel
		let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
		let interactionID = try requireUUID(args["interaction_id"], name: "interaction_id")
		let workflow = try resolveWorkflow(args: args)
		let payload = try parseResponsePayload(args: args)
		let dispatch = try await agentModeVM.mcpResolvePendingInteraction(
			sessionID: sessionID,
			interactionID: interactionID,
			payload: payload,
			workflow: workflow
		)
		await Task.yield()
		return decoratedRunValue(
			snapshot: await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM),
			workflow: workflow,
			delivery: dispatch
		)
	}

	private func waitForInterestingState(
		sessionID: UUID,
		agentModeVM: AgentModeViewModel,
		metadata: RequestMetadata,
		timeoutSeconds: TimeInterval,
		stage: String,
		message: String,
		workflow: AgentWorkflowDefinition? = nil,
		initialDelivery: AgentModeViewModel.MCPInstructionDispatch? = nil,
		liveSnapshot: AgentRunMCPSnapshot? = nil
	) async throws -> Value {
		// Defensive reconciliation: if live state says running but the store
		// still holds a stale terminal/interesting snapshot from a previous run,
		// reset the store epoch so waitUntilInteresting blocks on the new run
		// instead of returning immediately with stale state.
		if let liveSnapshot, liveSnapshot.status == .running {
			await reconcileStoreForBlockingWait(sessionID: sessionID, currentSnapshot: liveSnapshot)
		}
		print("[AgentRunSteeringWake] agent_run wait entering sessionID=\(sessionID) stage=\(stage) timeout=\(timeoutSeconds)")
		let waitScopeToken = await beginAgentRunWait(metadata, [sessionID], timeoutSeconds)
		let completionBox = WaitScopeCompletionBox()
		let snapshot: Value
		do {
			snapshot = try await withHeartbeat(
				metadata.connectionID,
				toolName,
				stage,
				message
			) {
				let disposition = await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: timeoutSeconds)
				switch disposition {
				case .snapshotReady(let triggeringSnapshot):
					print("[AgentRunSteeringWake] agent_run wait returning snapshotReady sessionID=\(sessionID) status=\(triggeringSnapshot.status.rawValue)")
					completionBox.set(AgentRunWaitScopeCompletion(reason: triggeringSnapshot.status == .expired ? .expired : .snapshotReady, result: triggeringSnapshot.status == .expired ? "expired" : "snapshot_ready", winnerSessionID: triggeringSnapshot.status == .expired ? nil : sessionID, pendingSessionIDs: triggeringSnapshot.status == .expired ? [sessionID] : [], errorDescription: nil))
					return triggeringSnapshot.toValue()
				case .noteworthySnapshot(let triggeringSnapshot, let reason):
					print("[AgentRunSteeringWake] agent_run wait returning noteworthy sessionID=\(sessionID) reason=\(reason.rawValue) status=\(triggeringSnapshot.status.rawValue)")
					let completion = reason == .steeringRequested
						? AgentRunWaitScopeCompletion(reason: .cancelled, result: "interrupted_by_steering", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: nil)
						: AgentRunWaitScopeCompletion(reason: .snapshotReady, result: reason.rawValue, winnerSessionID: sessionID, pendingSessionIDs: [], errorDescription: nil)
					completionBox.set(completion)
					var object = triggeringSnapshot.asObject()
					object["_meta"] = .object(["wake_reason": .string(reason.rawValue)])
					return .object(object)
				case .timedOut:
					print("[AgentRunSteeringWake] agent_run wait returning timedOut sessionID=\(sessionID)")
					completionBox.set(AgentRunWaitScopeCompletion(reason: .timedOut, result: "timed_out", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: nil))
					return await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM).toValue()
				case .expired:
					print("[AgentRunSteeringWake] agent_run wait returning expired sessionID=\(sessionID)")
					completionBox.set(AgentRunWaitScopeCompletion(reason: .expired, result: "expired", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: nil))
					return AgentRunMCPSnapshot.expired(sessionID: sessionID).toValue()
				case .cancelled:
					print("[AgentRunSteeringWake] agent_run wait observed cancelled waiter sessionID=\(sessionID)")
					if let resolution = await cancelledSingleWaitResolution(sessionID: sessionID, agentModeVM: agentModeVM) {
						completionBox.set(resolution.completion)
						return resolution.rawValue
					}
					completionBox.set(AgentRunWaitScopeCompletion(reason: .cancelled, result: "cancelled", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: nil))
					throw CancellationError()
				}
			}
		} catch {
			if error is CancellationError,
				let resolution = await cancelledSingleWaitResolution(sessionID: sessionID, agentModeVM: agentModeVM) {
				if let waitScopeToken {
					await endAgentRunWait(waitScopeToken, resolution.completion)
				}
				return await finalDecoratedSingleWaitValue(
					from: resolution.rawValue,
					sessionID: sessionID,
					agentModeVM: agentModeVM,
					workflow: workflow,
					initialDelivery: initialDelivery
				)
			}
			if let waitScopeToken {
				let completion = AgentRunWaitScopeCompletion(reason: error is CancellationError ? .cancelled : .error, result: error is CancellationError ? "cancelled" : "error", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: String(describing: error))
				await endAgentRunWait(waitScopeToken, completion)
			}
			throw error
		}
		if let waitScopeToken {
			let completion = completionBox.get() ?? singleWaitScopeCompletion(from: snapshot, sessionID: sessionID)
			await endAgentRunWait(waitScopeToken, completion)
		}
		return await finalDecoratedSingleWaitValue(
			from: snapshot,
			sessionID: sessionID,
			agentModeVM: agentModeVM,
			workflow: workflow,
			initialDelivery: initialDelivery
		)
	}

	private func cancelledSingleWaitResolution(
		sessionID: UUID,
		agentModeVM: AgentModeViewModel
	) async -> CancelledSingleWaitResolution? {
		let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
		guard snapshot.status != .expired else { return nil }

		if snapshot.status == .running, snapshot.interaction == nil {
			var object = snapshot.asObject()
			object["_meta"] = .object(["wake_reason": .string(AgentRunSessionStore.WakeReason.steeringRequested.rawValue)])
			return CancelledSingleWaitResolution(
				rawValue: .object(object),
				completion: AgentRunWaitScopeCompletion(
					reason: .cancelled,
					result: "interrupted_by_steering",
					winnerSessionID: nil,
					pendingSessionIDs: [sessionID],
					errorDescription: nil
				)
			)
		}

		return CancelledSingleWaitResolution(
			rawValue: snapshot.toValue(),
			completion: singleWaitScopeCompletion(from: snapshot.toValue(), sessionID: sessionID)
		)
	}

	private func finalDecoratedSingleWaitValue(
		from rawValue: Value,
		sessionID: UUID,
		agentModeVM: AgentModeViewModel,
		workflow: AgentWorkflowDefinition?,
		initialDelivery: AgentModeViewModel.MCPInstructionDispatch?
	) async -> Value {
		let resolvedSnapshot: AgentRunMCPSnapshot
		let wakeReason = rawValue.objectValue.flatMap(wakeReason(from:))
		if let parsedSnapshot = rawValue.objectValue.flatMap(snapshot(from:)) {
			resolvedSnapshot = parsedSnapshot
		} else {
			resolvedSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
		}
		return decoratedRunValue(snapshot: resolvedSnapshot, workflow: workflow, delivery: initialDelivery, wakeReason: wakeReason)
	}

	private func waitAnyCancellationInterruptValueIfResumable(
		sessionIDs: [UUID],
		agentModeVM: AgentModeViewModel,
		fallbackSnapshots: [AgentRunMCPSnapshot]
	) async -> Value? {
		let freshSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
		let snapshots = freshSnapshots.isEmpty ? fallbackSnapshots : freshSnapshots
		guard !snapshots.isEmpty else { return nil }

		if let ready = snapshots.first(where: { isInterestingSnapshot($0) && $0.status != .expired }) {
			await AgentRunSessionStore.signalSnapshot(ready)
			return decoratedMultiWaitValue(
				snapshot: ready,
				sessionIDs: sessionIDs,
				result: "snapshot_ready",
				snapshots: snapshots,
				pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != ready.sessionID }
			)
		}

		let runningIDs = snapshots.filter { $0.status == .running }.map(\.sessionID)
		guard runningIDs.isEmpty == false else { return nil }
		let pendingIDs = snapshots.filter { !isInterestingSnapshot($0) && $0.status != .expired }.map(\.sessionID)
		return decoratedMultiWaitInterruptValue(
			sessionIDs: sessionIDs,
			snapshots: snapshots,
			pendingSessionIDs: pendingIDs.isEmpty ? runningIDs : pendingIDs
		)
	}

	private nonisolated func decoratedMultiWaitInterruptValue(
		sessionIDs: [UUID],
		snapshots: [AgentRunMCPSnapshot],
		pendingSessionIDs: [UUID]
	) -> Value {
		let representative = sessionIDs.compactMap { sessionID in
			snapshots.first { $0.sessionID == sessionID && $0.status == .running }
		}.first ?? snapshots.first ?? AgentRunMCPSnapshot.expired(sessionID: sessionIDs[0])
		var object = representative.asObject()
		object.removeValue(forKey: "assistant_text")
		object["status_text"] = .string("Wait interrupted by a new steering instruction; the agent run is still running.")
		object["_meta"] = .object([
			"wake_reason": .string(AgentRunSessionStore.WakeReason.steeringRequested.rawValue),
			"note": .string(agentRunSteeringWakeNote)
		])
		object["wait"] = .object([
			"mode": .string("any"),
			"result": .string("interrupted_by_steering"),
			"winner_session_id": .null,
			"session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
			"waited_count": .int(sessionIDs.count),
			"pending_session_ids": .array(pendingSessionIDs.map { .string($0.uuidString) }),
			"instruction": .string(agentRunSteeringWakeNote)
		])
		object["snapshots"] = .array(snapshots.map { snapshot in
			var snapshotObject = snapshot.asObject()
			if !snapshot.status.isTerminal {
				snapshotObject.removeValue(forKey: "assistant_text")
			}
			return .object(snapshotObject)
		})
		return .object(object)
	}

	private func steeringInterruptMultiWaitValue(
		sessionIDs: [UUID],
		agentModeVM: AgentModeViewModel,
		fallbackSnapshots: [AgentRunMCPSnapshot],
		triggeringSnapshot: AgentRunMCPSnapshot
	) async -> Value {
		let freshSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
		let sourceSnapshots = freshSnapshots.isEmpty ? fallbackSnapshots : freshSnapshots
		var snapshotsBySessionID = Dictionary(uniqueKeysWithValues: sourceSnapshots.map { ($0.sessionID, $0) })
		if snapshotsBySessionID[triggeringSnapshot.sessionID] == nil {
			snapshotsBySessionID[triggeringSnapshot.sessionID] = triggeringSnapshot
		}
		let snapshots = sessionIDs.compactMap { snapshotsBySessionID[$0] }
		let effectiveSnapshots = snapshots.isEmpty ? [triggeringSnapshot] : snapshots
		let runningIDs = effectiveSnapshots.filter { $0.status == .running }.map(\.sessionID)
		let pendingIDs = effectiveSnapshots
			.filter { !isInterestingSnapshot($0) && $0.status != .expired }
			.map(\.sessionID)
		return decoratedMultiWaitInterruptValue(
			sessionIDs: sessionIDs,
			snapshots: effectiveSnapshots,
			pendingSessionIDs: pendingIDs.isEmpty ? runningIDs : pendingIDs
		)
	}

	private nonisolated func waitForAnyInterestingState(
		sessionIDs: [UUID],
		agentModeVM: AgentModeViewModel,
		timeoutSeconds: TimeInterval,
		initialSnapshots: [AgentRunMCPSnapshot]
	) async throws -> Value {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
		var latestSnapshots = initialSnapshots

		while true {
			if Task.isCancelled {
				if let value = await waitAnyCancellationInterruptValueIfResumable(
					sessionIDs: sessionIDs,
					agentModeVM: agentModeVM,
					fallbackSnapshots: latestSnapshots
				) {
					return value
				}
				throw CancellationError()
			}
			let liveSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
			latestSnapshots = liveSnapshots
			if let ready = liveSnapshots.first(where: { isInterestingSnapshot($0) }) {
				await AgentRunSessionStore.signalSnapshot(ready)
				return decoratedMultiWaitValue(
					snapshot: ready,
					sessionIDs: sessionIDs,
					result: ready.status == .expired ? "expired" : "snapshot_ready",
					pendingSessionIDs: pendingSessionIDs(from: liveSnapshots).filter { $0 != ready.sessionID }
				)
			}
			for snapshot in liveSnapshots where snapshot.status == .running {
				await reconcileStoreForBlockingWait(sessionID: snapshot.sessionID, currentSnapshot: snapshot)
			}

			let remaining = Self.timeInterval(from: clock.now.duration(to: deadline))
			guard remaining > 0 else {
				print("[AgentRunSteeringWake] agent_run wait-any top-level timeout statuses=\(statusSummary(latestSnapshots))")
				return decoratedMultiWaitValue(
					snapshot: latestSnapshots.first ?? initialSnapshots[0],
					sessionIDs: sessionIDs,
					result: "timed_out",
					snapshots: latestSnapshots,
					pendingSessionIDs: pendingSessionIDs(from: latestSnapshots)
				)
			}

			let sliceTimeout = min(remaining, waitAnyLiveReconcileIntervalSeconds)
			let result = await waitUntilFirstActionable(sessionIDs: sessionIDs, timeoutSeconds: sliceTimeout)
			switch result.disposition {
			case .actionable(let snapshot):
				let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
				return decoratedMultiWaitValue(
					snapshot: snapshot,
					sessionIDs: sessionIDs,
					result: snapshot.status == .expired ? "expired" : "snapshot_ready",
					pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != snapshot.sessionID }
				)
			case .nonActionableWake(let snapshot, let reason):
				if reason == .steeringRequested {
					print("[AgentRunSteeringWake] agent_run wait-any interrupted by steering wake sessionID=\(snapshot.sessionID) status=\(snapshot.status.rawValue)")
					return await steeringInterruptMultiWaitValue(
						sessionIDs: sessionIDs,
						agentModeVM: agentModeVM,
						fallbackSnapshots: latestSnapshots,
						triggeringSnapshot: snapshot
					)
				}
				print("[AgentRunSteeringWake] agent_run wait-any ignored non-actionable wake sessionID=\(snapshot.sessionID) reason=\(reason.rawValue) status=\(snapshot.status.rawValue)")
				continue
			case .timedOut:
				continue
			case .expired:
				let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
				if let ready = snapshots.first(where: { isInterestingSnapshot($0) }) {
					await AgentRunSessionStore.signalSnapshot(ready)
					return decoratedMultiWaitValue(
						snapshot: ready,
						sessionIDs: sessionIDs,
						result: ready.status == .expired ? "expired" : "snapshot_ready",
						pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != ready.sessionID }
					)
				}
				return decoratedMultiWaitValue(
					snapshot: AgentRunMCPSnapshot.expired(sessionID: result.sessionID),
					sessionIDs: sessionIDs,
					result: "expired",
					pendingSessionIDs: pendingSessionIDs(from: snapshots)
				)
			case .cancelled:
				print("[AgentRunSteeringWake] agent_run wait-any observed cancelled child waiter sessionID=\(result.sessionID)")
				if let value = await waitAnyCancellationInterruptValueIfResumable(
					sessionIDs: sessionIDs,
					agentModeVM: agentModeVM,
					fallbackSnapshots: latestSnapshots
				) {
					return value
				}
				throw CancellationError()
			}
		}
	}

	private nonisolated func waitUntilFirstActionable(
		sessionIDs: [UUID],
		timeoutSeconds: TimeInterval
	) async -> WaitAnyResult {
		await withTaskGroup(of: WaitAnyResult.self) { group in
			for sessionID in sessionIDs {
				group.addTask {
					await Self.waitUntilActionable(sessionID: sessionID, timeoutSeconds: timeoutSeconds)
				}
			}
			guard let result = await group.next() else {
				return WaitAnyResult(sessionID: sessionIDs[0], disposition: .timedOut)
			}
			if isTimedOutDisposition(result.disposition) {
				while let nextResult = await group.next() {
					guard isTimedOutDisposition(nextResult.disposition) else {
						group.cancelAll()
						return nextResult
					}
				}
				return result
			}
			group.cancelAll()
			return result
		}
	}

	private nonisolated static func waitUntilActionable(
		sessionID: UUID,
		timeoutSeconds: TimeInterval
	) async -> WaitAnyResult {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
		while true {
			if Task.isCancelled {
				return WaitAnyResult(sessionID: sessionID, disposition: .cancelled)
			}
			let remaining = timeInterval(from: clock.now.duration(to: deadline))
			guard remaining > 0 else {
				return WaitAnyResult(sessionID: sessionID, disposition: .timedOut)
			}
			let disposition = await AgentRunSessionStore.waitUntilInteresting(
				sessionID: sessionID,
				timeoutSeconds: remaining
			)
			switch disposition {
			case .snapshotReady(let snapshot):
				if snapshot.isActionableForMCPWait {
					return WaitAnyResult(sessionID: sessionID, disposition: .actionable(snapshot))
				}
			case .noteworthySnapshot(let snapshot, let reason):
				if snapshot.isActionableForMCPWait {
					return WaitAnyResult(sessionID: sessionID, disposition: .actionable(snapshot))
				}
				return WaitAnyResult(sessionID: sessionID, disposition: .nonActionableWake(snapshot, reason))
			case .timedOut:
				return WaitAnyResult(sessionID: sessionID, disposition: .timedOut)
			case .expired:
				return WaitAnyResult(sessionID: sessionID, disposition: .expired)
			case .cancelled:
				return WaitAnyResult(sessionID: sessionID, disposition: .cancelled)
			}
		}
	}

	private nonisolated static func timeInterval(from duration: Duration) -> TimeInterval {
		let components = duration.components
		return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
	}

	private nonisolated func isTimedOutDisposition(_ disposition: MultiWaitDisposition) -> Bool {
		if case .timedOut = disposition { return true }
		return false
	}

	private nonisolated func statusSummary(_ snapshots: [AgentRunMCPSnapshot]) -> String {
		snapshots
			.map { "\($0.sessionID.uuidString.prefix(8)):\($0.status.rawValue)" }
			.joined(separator: ",")
	}

	private nonisolated func waitScopeCompletion(from value: Value, fallbackSessionIDs: [UUID]) -> AgentRunWaitScopeCompletion {
		let object = value.objectValue
		let wait = object?["wait"]?.objectValue
		let result = wait?["result"]?.stringValue
		let winnerSessionID = wait?["winner_session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
		let pendingSessionIDs = Set(wait?["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? fallbackSessionIDs)
		let reason: AgentRunWaitScopeCompletion.Reason = switch result {
		case "timed_out": .timedOut
		case "expired": .expired
		case "cancelled", "interrupted_by_steering": .cancelled
		case "error": .error
		default: .snapshotReady
		}
		return AgentRunWaitScopeCompletion(
			reason: reason,
			result: result,
			winnerSessionID: winnerSessionID,
			pendingSessionIDs: pendingSessionIDs,
			errorDescription: nil
		)
	}

	private nonisolated func singleWaitScopeCompletion(from value: Value, sessionID: UUID) -> AgentRunWaitScopeCompletion {
		let status = value.objectValue?["status"]?.stringValue.flatMap(AgentRunMCPSnapshot.Status.init(rawValue:))
		let reason: AgentRunWaitScopeCompletion.Reason = status == .expired ? .expired : .snapshotReady
		return AgentRunWaitScopeCompletion(
			reason: reason,
			result: reason.rawValue,
			winnerSessionID: status == .expired ? nil : sessionID,
			pendingSessionIDs: [],
			errorDescription: nil
		)
	}

	private func decoratedRunValue(
		snapshot: AgentRunMCPSnapshot,
		workflow: AgentWorkflowDefinition? = nil,
		delivery: AgentModeViewModel.MCPInstructionDispatch? = nil,
		wakeReason: AgentRunSessionStore.WakeReason? = nil,
		warning: String? = nil
	) -> Value {
		var object = snapshot.asObject()
		if let warning = warning?.trimmingCharacters(in: .whitespacesAndNewlines), !warning.isEmpty {
			object["warning"] = .string(warning)
		}
		if let workflow {
			object["workflow_id"] = .string(workflow.id)
			object["workflow_name"] = .string(workflow.displayName)
		}
		if let meta = metadataObject(for: snapshot, delivery: delivery, wakeReason: wakeReason) {
			object["_meta"] = .object(meta)
		}
		// After a steer dispatch into an active run, the assistant_text is from the
		// *previous* turn and would confuse the caller into thinking the steer produced
		// no new output.  Strip it so the caller sees a clean "instruction accepted" response.
		if !snapshot.status.isTerminal,
			(delivery?.isActiveRunDispatch == true || wakeReason?.suppressesAssistantPreview == true) {
			object.removeValue(forKey: "assistant_text")
		}
		if wakeReason == .steeringRequested {
			object["status_text"] = .string("Wait interrupted by a new steering instruction; the agent run is still running.")
			object["wait"] = .object([
				"result": .string("interrupted_by_steering"),
				"instruction": .string(agentRunSteeringWakeNote)
			])
		}
		return .object(object)
	}

	private nonisolated func decoratedMultiWaitValue(
		snapshot: AgentRunMCPSnapshot,
		sessionIDs: [UUID],
		result: String,
		snapshots: [AgentRunMCPSnapshot]? = nil,
		pendingSessionIDs: [UUID]? = nil
	) -> Value {
		var object = snapshot.asObject()
		object["wait"] = .object([
			"mode": .string("any"),
			"result": .string(result),
			"winner_session_id": result == "timed_out"
				? .null : .string(snapshot.sessionID.uuidString),
			"session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
			"waited_count": .int(sessionIDs.count),
			"pending_session_ids": .array(
				(pendingSessionIDs ?? sessionIDs.filter { $0 != snapshot.sessionID }).map { .string($0.uuidString) }
			),
			"instruction": .null
		])
		if let snapshots {
			object["snapshots"] = .array(snapshots.map { .object($0.asObject()) })
		}
		return .object(object)
	}

	private nonisolated func decoratedMultiPollValue(
		sessionIDs: [UUID],
		snapshots: [AgentRunMCPSnapshot]
	) -> Value {
		let interestingIDs = snapshots.filter { isInterestingSnapshot($0) }.map { $0.sessionID }
		let runningIDs = snapshots.filter { $0.status == .running }.map { $0.sessionID }
		let terminalIDs = snapshots.filter { $0.status.isTerminal }.map { $0.sessionID }
		return .object([
			"poll": .object([
				"mode": .string("many"),
				"session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
				"polled_count": .int(sessionIDs.count),
				"interesting_session_ids": .array(interestingIDs.map { .string($0.uuidString) }),
				"running_session_ids": .array(runningIDs.map { .string($0.uuidString) }),
				"terminal_session_ids": .array(terminalIDs.map { .string($0.uuidString) })
			]),
			"snapshots": .array(snapshots.map { .object($0.asObject()) })
		])
	}

	private func metadataObject(
		for snapshot: AgentRunMCPSnapshot,
		delivery: AgentModeViewModel.MCPInstructionDispatch?,
		wakeReason: AgentRunSessionStore.WakeReason?
	) -> [String: Value]? {
		guard !snapshot.status.isTerminal else { return nil }
		var metadata: [String: Value] = [:]
		if let delivery {
			switch delivery {
			case .queuedFollowUp, .queuedClaudeInterrupt, .queuedACPInterrupt, .deliveredIntoWaitingContinuation, .dispatchedCodexTurn:
				metadata["delivery"] = .string(delivery.rawValue)
			case .startedRun:
				break
			}
		}
		if let wakeReason {
			metadata["wake_reason"] = .string(wakeReason.rawValue)
			if wakeReason == .steeringRequested {
				metadata["note"] = .string(agentRunSteeringWakeNote)
			}
		}
		return metadata.isEmpty ? nil : metadata
	}

	private func wakeReason(from object: [String: Value]) -> AgentRunSessionStore.WakeReason? {
		guard let raw = object["_meta"]?.objectValue?["wake_reason"]?.stringValue else { return nil }
		return AgentRunSessionStore.WakeReason(rawValue: raw)
	}

	private func snapshot(from object: [String: Value]) -> AgentRunMCPSnapshot? {
		guard let sessionIDRaw = object["session_id"]?.stringValue,
			let sessionID = UUID(uuidString: sessionIDRaw),
			let statusRaw = object["status"]?.stringValue,
			let status = AgentRunMCPSnapshot.Status(rawValue: statusRaw)
		else {
			return nil
		}
		let session = object["session"]?.objectValue
		let agent = object["agent"]?.objectValue
		let interaction = object["interaction"]?.objectValue.flatMap(interaction(from:))
		let updatedAt = object["updated_at"]?.stringValue.flatMap(Self.timestampFormatter.date(from:)) ?? Date()
		let tabID = (session?["context_id"] ?? session?["tab_id"])?.stringValue.flatMap(UUID.init(uuidString:))
		let parentSessionID = session?["parent_session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
		let failureReason = object["failure_reason"]?.stringValue.flatMap(AgentRunMCPSnapshot.FailureReason.init(rawValue:))
		return AgentRunMCPSnapshot(
			sessionID: sessionID,
			tabID: tabID,
			sessionName: session?["name"]?.stringValue,
			agentRaw: agent?["id"]?.stringValue,
			agentDisplayName: agent?["name"]?.stringValue,
			modelRaw: agent?["model"]?.stringValue,
			reasoningEffortRaw: agent?["reasoning_effort"]?.stringValue,
			status: status,
			statusText: object["status_text"]?.stringValue,
			latestAssistantPreview: object["assistant_text"]?.stringValue,
			interaction: interaction,
			transcriptItemCount: object["transcript_item_count"]?.intValue ?? 0,
			updatedAt: updatedAt,
			parentSessionID: parentSessionID,
			failureReason: failureReason
		)
	}

	private func interaction(from object: [String: Value]) -> AgentRunMCPSnapshot.Interaction? {
		guard let idRaw = object["id"]?.stringValue,
			let id = UUID(uuidString: idRaw),
			let kindRaw = object["kind"]?.stringValue,
			let kind = AgentRunMCPSnapshot.Interaction.Kind(rawValue: kindRaw),
			let responseTypeRaw = object["response_type"]?.stringValue,
			let responseType = AgentRunMCPSnapshot.Interaction.ResponseType(rawValue: responseTypeRaw)
		else {
			return nil
		}
		let options = object["options"]?.arrayValue?.compactMap { option -> AgentRunMCPSnapshot.Interaction.Option? in
			guard let optionObject = option.objectValue,
				let label = optionObject["label"]?.stringValue else { return nil }
			return .init(label: label, description: optionObject["description"]?.stringValue)
		} ?? []
		let fields = object["fields"]?.arrayValue?.compactMap { field -> AgentRunMCPSnapshot.Interaction.Field? in
			guard let fieldObject = field.objectValue,
				let id = fieldObject["id"]?.stringValue,
				let prompt = fieldObject["prompt"]?.stringValue else { return nil }
			let fieldOptions = fieldObject["options"]?.arrayValue?.compactMap { option -> AgentRunMCPSnapshot.Interaction.Option? in
				guard let optionObject = option.objectValue,
					let label = optionObject["label"]?.stringValue else { return nil }
				return .init(label: label, description: optionObject["description"]?.stringValue)
			} ?? []
			return .init(
				id: id,
				header: fieldObject["header"]?.stringValue,
				prompt: prompt,
				context: fieldObject["context"]?.stringValue,
				isSecret: fieldObject["is_secret"]?.boolValue == true,
				allowsOther: fieldObject["allows_other"]?.boolValue == true,
				allowsMultiple: fieldObject["allows_multiple"]?.boolValue,
				allowsCustom: fieldObject["allows_custom"]?.boolValue,
				emitAllowsOther: fieldObject["allows_other"] != nil,
				options: fieldOptions
			)
		} ?? []
		let details = object["details"]?.arrayValue?.compactMap { detail -> AgentRunMCPSnapshot.Interaction.Detail? in
			guard let detailObject = detail.objectValue,
				let label = detailObject["label"]?.stringValue,
				let value = detailObject["value"]?.stringValue else { return nil }
			return .init(label: label, value: value, isCode: detailObject["is_code"]?.boolValue == true)
		} ?? []
		return .init(
			id: id,
			kind: kind,
			responseType: responseType,
			title: object["title"]?.stringValue,
			prompt: object["prompt"]?.stringValue,
			context: object["context"]?.stringValue,
			allowsMultiple: object["allows_multiple"]?.boolValue,
			options: options,
			fields: fields,
			details: details
		)
	}

	/// Reconciles the store with the live snapshot before a blocking wait.
	/// If the store still holds a stale "interesting" snapshot (terminal or with
	/// interaction) from a previous run but the live session has already restarted
	/// to `.running`, resets the store epoch so `waitUntilInteresting` blocks
	/// on the new run instead of returning immediately.
	private func reconcileStoreForBlockingWait(
		sessionID: UUID,
		currentSnapshot: AgentRunMCPSnapshot
	) async {
		guard currentSnapshot.status == .running else { return }
		guard let storedSnapshot = await AgentRunSessionStore.snapshot(for: sessionID) else { return }
		let isStaleInteresting = storedSnapshot.isActionableForMCPWait
		guard isStaleInteresting else { return }
		await AgentRunSessionStore.resetSnapshotForNewTurn(sessionID: sessionID)
		await AgentRunSessionStore.signalSnapshot(currentSnapshot)
	}

	private func collectCurrentSnapshots(sessionIDs: [UUID], agentModeVM: AgentModeViewModel) async -> [AgentRunMCPSnapshot] {
		var snapshots: [AgentRunMCPSnapshot] = []
		snapshots.reserveCapacity(sessionIDs.count)
		for sessionID in sessionIDs {
			snapshots.append(await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM))
		}
		return snapshots
	}

	private nonisolated func isInterestingSnapshot(_ snapshot: AgentRunMCPSnapshot) -> Bool {
		snapshot.isActionableForMCPWait
	}

	private nonisolated func pendingSessionIDs(from snapshots: [AgentRunMCPSnapshot]) -> [UUID] {
		snapshots.filter { !isInterestingSnapshot($0) }.map { $0.sessionID }
	}

	private func currentSnapshot(sessionID: UUID, agentModeVM: AgentModeViewModel) async -> AgentRunMCPSnapshot {
		if let providedSnapshot = await currentSnapshotProvider?(sessionID, agentModeVM) {
			return providedSnapshot
		}
		if let liveSnapshot = agentModeVM.mcpSnapshot(sessionID: sessionID) {
			return liveSnapshot
		}
		if let storedSnapshot = await AgentRunSessionStore.snapshot(for: sessionID) {
			return storedSnapshot
		}
		return .expired(sessionID: sessionID)
	}

	private func resolveSessionID(reference: String?, workspace: WorkspaceModel, agentModeVM: AgentModeViewModel) async throws -> UUID? {
		guard let reference else { return nil }
		guard let sessionID = try await agentModeVM.mcpResolveSessionID(reference: reference, workspace: workspace) else {
			throw MCPError.invalidParams("Session '\(reference)' was not found in the active workspace.")
		}
		return sessionID
	}

	private func resolveWorkflow(args: [String: Value]) throws -> AgentWorkflowDefinition? {
		let workflowID = normalizedString(args["workflow_id"])
		let workflowName = normalizedString(args["workflow_name"])
		if workflowID != nil, workflowName != nil {
			throw MCPError.invalidParams("Specify either workflow_id or workflow_name, not both.")
		}
		guard let reference = workflowID ?? workflowName else {
			return nil
		}
		guard let workflow = AgentWorkflowStore.shared.resolveWorkflowReference(reference) else {
			throw MCPError.invalidParams("Workflow '\(reference)' was not found.")
		}
		return workflow
	}

	private func resolveMessage(_ value: Value?, name: String) throws -> String {
		let message = normalizedString(value) ?? ""
		guard !message.isEmpty else {
			throw MCPError.invalidParams("\(name) is required.")
		}
		return message
	}

	private struct ParsedAnswers {
		let flat: [String: [String]]
		let structured: [String: AgentAskUserAnswer]
	}

	private func parseResponsePayload(args: [String: Value]) throws -> AgentModeViewModel.MCPInteractionResponsePayload {
		let parsedAnswers: ParsedAnswers
		if let rawAnswers = args["answers"] {
			parsedAnswers = try parseAnswers(rawAnswers)
		} else {
			parsedAnswers = ParsedAnswers(flat: [:], structured: [:])
		}

		let responseRaw = normalizedString(args["response"])
		let explicitSkip: Bool
		if let skipValue = args["skip"] {
			guard let skipBool = skipValue.boolValue else {
				throw MCPError.invalidParams("skip must be a boolean.")
			}
			explicitSkip = skipBool
		} else {
			explicitSkip = false
		}
		let isSkip = explicitSkip || responseRaw?.lowercased() == "skip"
		let decisionRaw = responseRaw

		let content = try parseAgentJSONObject(args["content"], name: "content")
		let meta = try parseAgentJSONObject(args["meta"] ?? args["_meta"], name: "meta")

		return AgentModeViewModel.MCPInteractionResponsePayload(
			text: responseRaw,
			skip: isSkip,
			decisionRaw: isSkip ? nil : decisionRaw,
			amendment: normalizedString(args["amendment"]),
			answersByQuestionID: parsedAnswers.flat,
			askUserAnswersByQuestionID: parsedAnswers.structured,
			elicitationActionRaw: isSkip ? nil : responseRaw,
			elicitationContent: content,
			elicitationMeta: meta
		)
	}

	private func parseAgentJSONObject(_ value: Value?, name: String) throws -> [String: AgentJSONValue] {
		guard let value else { return [:] }
		guard let object = value.objectValue else {
			throw MCPError.invalidParams("\(name) must be an object.")
		}
		return try object.reduce(into: [String: AgentJSONValue]()) { partialResult, entry in
			partialResult[entry.key] = try agentJSONValue(from: entry.value)
		}
	}

	private func agentJSONValue(from value: Value) throws -> AgentJSONValue {
		switch value {
		case .null:
			return .null
		case .bool(let boolValue):
			return .bool(boolValue)
		case .int(let intValue):
			return .int(intValue)
		case .double(let doubleValue):
			return .double(doubleValue)
		case .string(let stringValue):
			return .string(stringValue)
		case .array(let values):
			return .array(try values.map { try agentJSONValue(from: $0) })
		case .object(let object):
			return .object(try object.reduce(into: [String: AgentJSONValue]()) { partialResult, entry in
				partialResult[entry.key] = try agentJSONValue(from: entry.value)
			})
		default:
			throw MCPError.invalidParams("Unsupported JSON value in MCP response payload.")
		}
	}

	private func parseAnswers(_ value: Value) throws -> ParsedAnswers {
		guard let object = value.objectValue else {
			throw MCPError.invalidParams("answers must be an object keyed by question ID.")
		}
		var flat = [String: [String]]()
		var structured = [String: AgentAskUserAnswer]()
		for entry in object {
			let questionID = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !questionID.isEmpty else {
				throw MCPError.invalidParams("answers cannot contain an empty question ID.")
			}

			let parsed = try parseAnswerValue(entry.value, questionID: questionID)
			flat[questionID] = parsed.answers
			structured[questionID] = parsed
		}
		return ParsedAnswers(flat: flat, structured: structured)
	}

	private func parseAnswerValue(_ value: Value, questionID: String) throws -> AgentAskUserAnswer {
		if let answer = value.stringValue {
			return AgentAskUserAnswer(
				answers: [answer],
				selectedOptions: [],
				customResponse: nil,
				skipped: false
			)
		}
		if let answerArray = value.arrayValue {
			let answers = try parseAnswerStringArray(answerArray, name: "answers['\(questionID)']")
			return AgentAskUserAnswer(
				answers: answers,
				selectedOptions: [],
				customResponse: nil,
				skipped: false
			)
		}
		guard let answerObject = value.objectValue else {
			throw MCPError.invalidParams("answers['\(questionID)'] must be a string, array of strings, or object.")
		}

		let skipped = answerObject["skipped"]?.boolValue == true || answerObject["skip"]?.boolValue == true
		if skipped {
			return AgentAskUserAnswer(answers: [], selectedOptions: [], customResponse: nil, skipped: true)
		}

		let selectedOptions = try parseOptionalAnswerStrings(
			answerObject["selected_options"] ?? answerObject["selectedOptions"],
			name: "answers['\(questionID)'].selected_options"
		) ?? []
		let customResponse = normalizedString(answerObject["custom_response"] ?? answerObject["customResponse"])
		let explicitAnswers = try parseOptionalAnswerStrings(
			answerObject["answers"],
			name: "answers['\(questionID)'].answers"
		)

		let answers: [String]
		if let explicitAnswers {
			answers = explicitAnswers
		} else {
			answers = selectedOptions + (customResponse.map { [$0] } ?? [])
		}

		return AgentAskUserAnswer(
			answers: answers,
			selectedOptions: selectedOptions,
			customResponse: customResponse,
			skipped: false
		)
	}

	private func parseOptionalAnswerStrings(_ value: Value?, name: String) throws -> [String]? {
		guard let value else { return nil }
		if let answer = value.stringValue {
			return [answer]
		}
		guard let answerArray = value.arrayValue else {
			throw MCPError.invalidParams("\(name) must be a string or array of strings.")
		}
		return try parseAnswerStringArray(answerArray, name: name)
	}

	private func parseAnswerStringArray(_ values: [Value], name: String) throws -> [String] {
		try values.map { element -> String in
			guard let text = element.stringValue else {
				throw MCPError.invalidParams("\(name) must contain only strings.")
			}
			return text
		}
	}

	/// Resolves session_id for control operations (poll/wait/cancel/steer/respond).
	/// Accepts both full UUIDs and short IDs for a uniform caller experience.
	private func resolveControlSessionID(
		reference raw: String,
		targetWindow: WindowState,
		agentModeVM: AgentModeViewModel
	) async throws -> UUID {
		if let uuid = UUID(uuidString: raw) {
			return uuid
		}
		guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
			throw MCPError.invalidParams("No active workspace available to resolve session_id '\(raw)'.")
		}
		guard let resolved = try await agentModeVM.mcpResolveSessionID(reference: raw, workspace: workspace) else {
			throw MCPError.invalidParams("Session '\(raw)' was not found. Provide a full UUID or a valid short ID.")
		}
		return resolved
	}

	private func resolveControlSessionID(
		_ args: [String: Value],
		targetWindow: WindowState,
		agentModeVM: AgentModeViewModel
	) async throws -> UUID {
		guard let raw = normalizedString(args["session_id"]) else {
			throw MCPError.invalidParams("session_id is required for agent_run control operations.")
		}
		return try await resolveControlSessionID(reference: raw, targetWindow: targetWindow, agentModeVM: agentModeVM)
	}

	private func parseSessionIDArray(_ args: [String: Value]) throws -> [String] {
		if normalizedString(args["session_id"]) != nil {
			throw MCPError.invalidParams("Specify either session_id or session_ids, not both.")
		}
		guard let raw = args["session_ids"] else {
			throw MCPError.invalidParams("session_ids is required for multi-session wait.")
		}
		guard let values = raw.arrayValue, !values.isEmpty else {
			throw MCPError.invalidParams("session_ids must be a non-empty array of session IDs.")
		}
		return try values.map { value -> String in
			guard let reference = normalizedString(value) else {
				throw MCPError.invalidParams("session_ids must contain only non-empty strings.")
			}
			return reference
		}
	}

	private func resolveControlSessionIDs(
		_ references: [String],
		targetWindow: WindowState,
		agentModeVM: AgentModeViewModel
	) async throws -> [UUID] {
		var resolved: [UUID] = []
		var seen: Set<UUID> = []
		for reference in references {
			let sessionID = try await resolveControlSessionID(
				reference: reference,
				targetWindow: targetWindow,
				agentModeVM: agentModeVM
			)
			if seen.insert(sessionID).inserted {
				resolved.append(sessionID)
			}
		}
		guard !resolved.isEmpty else {
			throw MCPError.invalidParams("session_ids did not resolve to any sessions.")
		}
		return resolved
	}

	private func requireUUID(_ value: Value?, name: String) throws -> UUID {
		guard let raw = normalizedString(value), let uuid = UUID(uuidString: raw) else {
			throw MCPError.invalidParams("\(name) must be a UUID string.")
		}
		return uuid
	}

	private func requireNonEmptyString(_ value: Value?, name: String) throws -> String {
		guard let normalized = normalizedString(value), !normalized.isEmpty else {
			throw MCPError.invalidParams("\(name) is required.")
		}
		return normalized
	}

	private func normalizedString(_ value: Value?) -> String? {
		let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return trimmed.isEmpty ? nil : trimmed
	}

	private func parseBool(_ value: Value?) -> Bool? {
		switch value {
		case .bool(let boolValue):
			return boolValue
		case .string(let stringValue):
			switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
			case "true", "1", "yes":
				return true
			case "false", "0", "no":
				return false
			default:
				return nil
			}
		case .int(let intValue):
			return intValue != 0
		case .double(let doubleValue):
			return doubleValue != 0
		case .null, .array(_), .object(_):
			return nil
		default:
			return nil
		}
	}

	private func parseTimeoutSeconds(_ value: Value?) throws -> TimeInterval? {
		guard let value else { return nil }
		switch value {
		case .int(let intValue):
			let seconds = TimeInterval(intValue)
			guard seconds >= 0 else {
				throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
			}
			return seconds
		case .double(let doubleValue):
			guard doubleValue.isFinite, doubleValue >= 0 else {
				throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
			}
			return doubleValue
		case .string(let stringValue):
			guard let parsed = Double(stringValue), parsed.isFinite, parsed >= 0 else {
				throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
			}
			return parsed
		case .null:
			return nil
		case .bool(_), .array(_), .object(_):
			throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
		default:
			throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
		}
	}

	private static let timestampFormatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()
}

private extension AgentRunSessionStore.WakeReason {
	var suppressesAssistantPreview: Bool {
		switch self {
		case .instructionDelivered, .steeringRequested:
			return true
		}
	}
}
