import Foundation

@MainActor
final class CodexIntegratedAgentModeRunner {
	private let mcpServerEnabler: AgentModeViewModel.MCPServerEnabler
	private let codexCoordinator: CodexAgentModeCoordinator
	private let hooks: AgentModeRunService.Hooks

	init(
		mcpServerEnabler: @escaping AgentModeViewModel.MCPServerEnabler,
		codexCoordinator: CodexAgentModeCoordinator,
		hooks: AgentModeRunService.Hooks
	) {
		self.mcpServerEnabler = mcpServerEnabler
		self.codexCoordinator = codexCoordinator
		self.hooks = hooks
	}

	func startRun(
		tabID: UUID,
		session: AgentModeViewModel.TabSession,
		initialMessageForRun: String,
		attachments: [AgentImageAttachment]
	) async -> CodexAgentModeCoordinator.NativeSendOutcome {
		session.activeHeadlessRunAttemptID = nil
		let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

		let sendTask = Task<CodexAgentModeCoordinator.NativeSendOutcome, Never> { [weak self, weak session] in
			guard let self, let session else {
				return .cancelled
			}
			defer { session.agentTask = nil }
			await self.mcpServerEnabler()

			let outcome = await self.codexCoordinator.sendCodexNativeMessage(
				session: session,
				text: initialMessageForRun,
				attachments: attachments,
				attachmentReservationID: attachmentReservationID
			)
			self.hooks.recordPendingHandoffSendOutcome(session, outcome.didSend)
			return outcome
		}
		session.agentTask = Task {
			await withTaskCancellationHandler {
				_ = await sendTask.value
			} onCancel: {
				sendTask.cancel()
			}
		}
		return await sendTask.value
	}
}
