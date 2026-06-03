import Foundation

/// Tracks MCP-initiated Codex steer dispatch attempts and delivers send acknowledgements
/// back to the awaiting `mcpDispatchInstruction` caller.
///
/// **Lifecycle:**
/// 1. `mcpDispatchInstruction` calls `beginAttempt()` before `submitUserTurn`
/// 2. `submitPreparedUserTurn` calls `takePendingAttempt()` to claim the attempt ID
/// 3. After the Codex send completes, it calls `resolve(attemptID:ack:)` with the outcome
/// 4. Meanwhile, `mcpDispatchInstruction` awaits the result via `awaitAck(attemptID:)`
///
/// If the attempt is resolved before `awaitAck` is called, the ack is buffered.
/// If `awaitAck` is called first, a continuation is parked until resolution or timeout.
///
/// Related:
/// - MCP dispatch: AgentModeViewModel.mcpDispatchInstruction
/// - Codex send: AgentModeViewModel.submitPreparedUserTurn (Codex branch)
/// - Send outcome type: CodexAgentModeCoordinator.NativeSendOutcome
@MainActor
final class CodexSteerAckTracker {

	static let defaultTimeoutSeconds: TimeInterval = 2.5

	enum Ack: Sendable, Equatable {
		case queuedFollowUp
		case sendOutcome(CodexAgentModeCoordinator.NativeSendOutcome)
		case timedOut
	}

	// MARK: - State

	/// The attempt ID set by `beginAttempt` and consumed by `takePendingAttempt`.
	private var pendingAttemptID: UUID?
	/// Buffered acks for attempts resolved before `awaitAck` was called.
	private var ackBuffer: [UUID: Ack] = [:]
	/// Parked continuations for attempts where `awaitAck` was called before resolution.
	private var continuations: [UUID: CheckedContinuation<Ack, Never>] = [:]
	/// Timeout tasks that auto-resolve with `.timedOut` if no ack arrives in time.
	private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

	// MARK: - Public API

	/// Creates a new dispatch attempt. Called by `mcpDispatchInstruction` before `submitUserTurn`.
	func beginAttempt() -> UUID {
		let attemptID = UUID()
		pendingAttemptID = attemptID
		return attemptID
	}

	/// Claims the pending attempt ID. Called by `submitPreparedUserTurn` to associate
	/// the fire-and-forget `startAgentRun` task with the MCP dispatch attempt.
	func takePendingAttempt() -> UUID? {
		let id = pendingAttemptID
		pendingAttemptID = nil
		return id
	}

	/// Delivers an ack for the given attempt. Resumes the parked continuation if one exists,
	/// otherwise buffers the ack for a subsequent `awaitAck` call.
	func resolve(attemptID: UUID, ack: Ack) {
		if pendingAttemptID == attemptID {
			pendingAttemptID = nil
		}
		timeoutTasks.removeValue(forKey: attemptID)?.cancel()
		if let continuation = continuations.removeValue(forKey: attemptID) {
			continuation.resume(returning: ack)
		} else {
			ackBuffer[attemptID] = ack
		}
	}

	/// Cancels a pending attempt, resuming any parked continuation with a failure.
	func cancel(
		attemptID: UUID,
		failureMessage: String = "Codex steer was superseded before send acknowledgement."
	) {
		if pendingAttemptID == attemptID {
			pendingAttemptID = nil
		}
		timeoutTasks.removeValue(forKey: attemptID)?.cancel()
		ackBuffer.removeValue(forKey: attemptID)
		if let continuation = continuations.removeValue(forKey: attemptID) {
			continuation.resume(returning: .sendOutcome(.failed(message: failureMessage)))
		}
	}

	/// Awaits the ack for a dispatch attempt. Returns immediately if already buffered,
	/// otherwise parks a continuation with a timeout safety net.
	func awaitAck(
		attemptID: UUID,
		timeoutSeconds: TimeInterval = CodexSteerAckTracker.defaultTimeoutSeconds
	) async -> Ack {
		if let ack = ackBuffer.removeValue(forKey: attemptID) {
			return ack
		}
		return await withCheckedContinuation { continuation in
			continuations[attemptID] = continuation
			let timeout = max(0.1, timeoutSeconds)
			timeoutTasks[attemptID] = Task { @MainActor [weak self] in
				try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
				guard let self,
					let continuation = self.continuations.removeValue(forKey: attemptID)
				else { return }
				self.timeoutTasks.removeValue(forKey: attemptID)
				if self.pendingAttemptID == attemptID {
					self.pendingAttemptID = nil
				}
				continuation.resume(returning: .timedOut)
			}
		}
	}
}
