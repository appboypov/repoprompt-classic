import Foundation

@MainActor
final class HeadlessAgentModeRunner {
	private let headlessProviderFactory: AgentModeViewModel.HeadlessProviderFactory
	private let hooks: AgentModeRunService.Hooks

	init(
		headlessProviderFactory: @escaping AgentModeViewModel.HeadlessProviderFactory,
		hooks: AgentModeRunService.Hooks
	) {
		self.headlessProviderFactory = headlessProviderFactory
		self.hooks = hooks
	}

	func startRun(
		tabID: UUID,
		session: AgentModeViewModel.TabSession,
		initialUserMessage: String,
		initialMessageForRun: String,
		attachments: [AgentImageAttachment],
		makeLease: (_ runID: UUID) -> MCPBootstrapLease
	) async {
		let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

		if initialMessageForRun != initialUserMessage,
			!session.pendingNonCodexUserInputTokenQueue.isEmpty {
			session.pendingNonCodexUserInputTokenQueue[0] = hooks.estimateRuntimeTokens(initialMessageForRun)
		}
		hooks.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)

		let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
		let lease = makeLease(runID)

		session.activeReasoningItemID = nil
		session.reasoningItemIDsByGroupID.removeAll()
		session.codexReasoningSegmentsByKey.removeAll()

		let runAttemptID = UUID()
		session.activeHeadlessRunAttemptID = runAttemptID
		session.runningStatusText = nil
		session.runningStatusSource = nil
		session.runState = .running
		hooks.setAgentRunActive(tabID, true)
		hooks.updateBindings(session)

		guard session.selectedAgent != .codexExec else {
			session.activeHeadlessRunAttemptID = nil
			await hooks.prepareForTerminalPersistence(session, .failed, "headless-routing-error")
			session.runState = .failed
			session.runningStatusText = nil
			hooks.setAgentRunActive(tabID, false)
			hooks.finalizeAttachmentsForTurn(session, attachmentReservationID, .deleteFiles)
			let errorItem = AgentChatItem.error(
				"Internal routing error: Codex native run attempted to use headless provider path.",
				sequenceIndex: session.nextSequenceIndex
			)
			session.appendItem(errorItem)
			hooks.updateBindings(session)
			hooks.scheduleSave(session.tabID)
			return
		}

		let provider = headlessProviderFactory(
			session.selectedAgent,
			session.selectedModelRaw == AgentModel.defaultModel.rawValue
				? nil
				: session.selectedModelRaw
		)
		session.provider = provider

		session.agentTask = Task { [weak self, weak session] in
			guard let self, let session else { return }
			await withTaskCancellationHandler {
				let acquired = await lease.acquire()
				guard acquired else {
					await self.handleAcquireFailure(
						tabID: tabID,
						session: session,
						runID: runID,
						runAttemptID: runAttemptID,
						attachmentReservationID: attachmentReservationID
					)
					return
				}

				let agentMessage = self.hooks.buildHeadlessAgentMessage(
					session,
					initialMessageForRun,
					runID,
					attachments,
					nil
				)
				await self.executeHeadlessRun(
					session: session,
					provider: provider,
					initialMessage: agentMessage,
					runID: runID,
					runAttemptID: runAttemptID,
					attachments: attachments,
					attachmentReservationID: attachmentReservationID,
					lease: lease
				)
			} onCancel: {
				Task { await lease.cancelAndCleanup() }
			}
		}
	}

	private func handleAcquireFailure(
		tabID: UUID,
		session: AgentModeViewModel.TabSession,
		runID: UUID,
		runAttemptID: UUID,
		attachmentReservationID: UUID?
	) async {
		guard session.runID == runID,
			session.activeHeadlessRunAttemptID == runAttemptID
		else {
			return
		}
		session.activeHeadlessRunAttemptID = nil
		session.agentTask = nil
		session.provider = nil
		session.runID = nil
		await hooks.prepareForTerminalPersistence(session, .cancelled, "headless-acquire-failed")
		session.runState = .cancelled
		session.runningStatusText = nil
		hooks.recordPendingHandoffSendOutcome(session, false)
		hooks.setAgentRunActive(tabID, false)
		hooks.finalizeAttachmentsForTurn(session, attachmentReservationID, .deleteFiles)
		hooks.updateBindings(session)
		hooks.scheduleSave(session.tabID)
	}

	private func executeHeadlessRun(
		session: AgentModeViewModel.TabSession,
		provider: HeadlessAgentProvider,
		initialMessage: AgentMessage,
		runID: UUID,
		runAttemptID: UUID,
		attachments: [AgentImageAttachment],
		attachmentReservationID: UUID?,
		lease: MCPBootstrapLease
	) async {
		do {
			let stream = try await provider.streamAgentMessage(initialMessage, runID: runID)
			hooks.recordPendingHandoffSendOutcome(session, true)
			hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
			hooks.markAttachmentsConsumed(session, attachmentReservationID)
			_ = await lease.releaseWhenRouted()

			for try await result in stream {
				guard !Task.isCancelled else { break }
				await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
			}

			guard session.runID == runID,
				session.activeHeadlessRunAttemptID == runAttemptID
			else {
				return
			}

			await hooks.prepareForTerminalPersistence(session, .completed, "headless-completed")
			hooks.finalizeNonCodexTurnUsage(session, nil, nil, nil)
			let supportsSessionResume = session.selectedAgent == .gemini
			let queuedInstruction = supportsSessionResume ? session.pendingInstructions.first : nil
			if queuedInstruction != nil {
				session.mcpFollowUpRunPending = true
				session.pendingInstructions.removeFirst()
			}
			session.activeHeadlessRunAttemptID = nil
			session.agentTask = nil
			session.provider = nil
			session.runID = nil
			session.runState = .completed
			session.runningStatusText = nil
			hooks.cancelPendingQuestion(session)
			hooks.cancelPendingApproval(session)
			hooks.cancelPendingApplyEditsReview(session, "Run completed before review decision")
			hooks.setAgentRunActive(session.tabID, false)
			hooks.finalizeAttachmentsForTurn(session, attachmentReservationID, .deleteFiles)
			hooks.updateBindings(session)
			hooks.notifyAgentTurnComplete(session)
			hooks.scheduleSave(session.tabID)

			if let queuedInstruction {
				hooks.startFollowUpRun(session.tabID, queuedInstruction)
			}
		} catch is CancellationError {
			await lease.cancelAndCleanup()
			guard session.runID == runID,
				session.activeHeadlessRunAttemptID == runAttemptID
			else {
				return
			}
			hooks.recordPendingHandoffSendOutcome(session, false)
			await hooks.prepareForTerminalPersistence(session, .cancelled, "headless-cancelled")
			hooks.finalizeNonCodexTurnUsage(session, nil, nil, nil)
			session.activeHeadlessRunAttemptID = nil
			session.agentTask = nil
			session.provider = nil
			session.runID = nil
			session.runState = .cancelled
			session.runningStatusText = nil
			hooks.cancelPendingQuestion(session)
			hooks.cancelPendingApproval(session)
			hooks.cancelPendingApplyEditsReview(session, "Run cancelled")
			hooks.setAgentRunActive(session.tabID, false)
			hooks.finalizeAttachmentsForTurn(session, attachmentReservationID, .deleteFiles)
			hooks.updateBindings(session)
		} catch {
			await lease.failAndRelease()
			guard session.runID == runID,
				session.activeHeadlessRunAttemptID == runAttemptID
			else {
				return
			}
			hooks.recordPendingHandoffSendOutcome(session, false)
			await hooks.prepareForTerminalPersistence(session, .failed, "headless-failed")
			hooks.finalizeNonCodexTurnUsage(session, nil, nil, nil)
			session.activeHeadlessRunAttemptID = nil
			session.agentTask = nil
			session.provider = nil
			session.runID = nil
			session.runState = .failed
			session.runningStatusText = nil
			hooks.cancelPendingQuestion(session)
			hooks.cancelPendingApproval(session)
			hooks.cancelPendingApplyEditsReview(session, "Run failed")
			hooks.setAgentRunActive(session.tabID, false)
			hooks.finalizeAttachmentsForTurn(session, attachmentReservationID, .deleteFiles)

			let errorItem = AgentChatItem.error(
				"Agent failed: \(error.localizedDescription)",
				sequenceIndex: session.nextSequenceIndex
			)
			session.appendItem(errorItem)
			hooks.updateBindings(session)
			hooks.scheduleSave(session.tabID)
		}
	}
}
