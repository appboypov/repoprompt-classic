import Foundation

@MainActor
final class GeminiContextUsageEstimator: ContextUsageEstimating {
	let agent: DiscoverAgentKind = .gemini
	private let tokenEstimator: (String) -> Int
	private let contextUsageBuilder: ProviderTurnContextUsageBuilder

	init(
		tokenEstimator: @escaping (String) -> Int,
		contextUsageBuilder: @escaping ProviderTurnContextUsageBuilder
	) {
		self.tokenEstimator = tokenEstimator
		self.contextUsageBuilder = contextUsageBuilder
	}

	@discardableResult
	func enqueueUserTurnEstimate(
		messageForProvider: String,
		session: AgentModeViewModel.TabSession
	) -> Int {
		let estimate = max(0, tokenEstimator(messageForProvider))
		session.pendingNonCodexUserInputTokenQueue.append(estimate)
		return estimate
	}

	@discardableResult
	func replaceNextQueuedUserTurnEstimate(
		messageForProvider: String,
		session: AgentModeViewModel.TabSession
	) -> Int? {
		guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { return nil }
		let estimate = max(0, tokenEstimator(messageForProvider))
		session.pendingNonCodexUserInputTokenQueue[0] = estimate
		return estimate
	}

	func dequeueQueuedUserTurnEstimate(session: AgentModeViewModel.TabSession) -> Int? {
		guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { return nil }
		return session.pendingNonCodexUserInputTokenQueue.removeFirst()
	}

	func beginTurn(session: AgentModeViewModel.TabSession, initialMessage: String) {
		let userTokens = dequeueQueuedUserTurnEstimate(session: session) ?? tokenEstimate(for: initialMessage)
		session.activeNonCodexTurnTokenAccumulator = AgentModeViewModel.NonCodexTurnTokenAccumulator(
			estimatedUserInputTokens: max(0, userTokens),
			estimatedToolInputTokens: 0,
			estimatedToolOutputTokens: 0
		)
		if userTokens > 0 {
			session.isDirty = true
		}
	}

	func addUserInputTokens(_ tokens: Int, session: AgentModeViewModel.TabSession) {
		guard tokens > 0 else { return }
		var accumulator = session.activeNonCodexTurnTokenAccumulator ?? AgentModeViewModel.NonCodexTurnTokenAccumulator()
		accumulator.estimatedUserInputTokens += tokens
		session.activeNonCodexTurnTokenAccumulator = accumulator
		session.isDirty = true
	}

	func addToolInputPayload(_ payload: String?, session: AgentModeViewModel.TabSession) {
		let tokens = tokenEstimate(for: payload)
		guard tokens > 0 else { return }
		var accumulator = session.activeNonCodexTurnTokenAccumulator ?? AgentModeViewModel.NonCodexTurnTokenAccumulator()
		accumulator.estimatedToolInputTokens += tokens
		session.activeNonCodexTurnTokenAccumulator = accumulator
		session.isDirty = true
	}

	func addToolOutputPayload(_ payload: String?, session: AgentModeViewModel.TabSession) {
		let tokens = tokenEstimate(for: payload)
		guard tokens > 0 else { return }
		var accumulator = session.activeNonCodexTurnTokenAccumulator ?? AgentModeViewModel.NonCodexTurnTokenAccumulator()
		accumulator.estimatedToolOutputTokens += tokens
		session.activeNonCodexTurnTokenAccumulator = accumulator
		session.isDirty = true
	}

	@discardableResult
	func ingestUsageSignal(
		promptTokens: Int?,
		completionTokens: Int?,
		contextUsedTokens: Int?,
		modelContextWindow: Int?,
		session: AgentModeViewModel.TabSession
	) -> ContextUsageSnapshot? {
		let prompt = max(0, promptTokens ?? 0)
		let completion = max(0, completionTokens ?? 0)
		let contextUsed = max(0, contextUsedTokens ?? 0)
		let currentTurnTokens = contextUsed > 0 ? contextUsed : (prompt + completion)
		let existing = session.codexContextUsage
		let existingLast = max(0, existing?.lastTotalTokens ?? 0)
		let existingTotal = max(0, existing?.totalTotalTokens ?? 0)
		let priorTurnsTotal = max(0, existingTotal - existingLast)
		let updatedTotal = priorTurnsTotal + currentTurnTokens
		let resolvedModelContextWindow = modelContextWindow ?? existing?.modelContextWindow
		guard currentTurnTokens > 0 || resolvedModelContextWindow != nil else { return nil }

		session.codexContextUsage = AgentContextUsage(
			modelContextWindow: resolvedModelContextWindow,
			lastTotalTokens: currentTurnTokens > 0 ? currentTurnTokens : existing?.lastTotalTokens,
			totalTotalTokens: max(updatedTotal, existingTotal)
		)

		return updateSnapshot(
			from: session.codexContextUsage,
			source: .geminiUsageEvent,
			confidence: contextUsed > 0 ? .exact : .bestEffort,
			session: session
		)
	}

	@discardableResult
	func ingestTurnFinalizationSignal(
		contextUsedTokens: Int?,
		modelContextWindow: Int?,
		session: AgentModeViewModel.TabSession
	) -> ContextUsageSnapshot? {
		let existing = session.codexContextUsage
		let resolvedContextWindow = modelContextWindow ?? existing?.modelContextWindow
		let resolvedContextUsed = max(0, contextUsedTokens ?? 0)
		guard resolvedContextWindow != nil || resolvedContextUsed > 0 else { return nil }

		let existingLast = max(0, existing?.lastTotalTokens ?? 0)
		let existingTotal = max(0, existing?.totalTotalTokens ?? 0)
		let priorTurnsTotal = max(0, existingTotal - existingLast)
		let updatedTotal = resolvedContextUsed > 0
			? max(priorTurnsTotal + resolvedContextUsed, existingTotal)
			: existingTotal
		session.codexContextUsage = AgentContextUsage(
			modelContextWindow: resolvedContextWindow,
			lastTotalTokens: resolvedContextUsed > 0 ? resolvedContextUsed : existing?.lastTotalTokens,
			totalTotalTokens: updatedTotal
		)
		return updateSnapshot(
			from: session.codexContextUsage,
			source: .turnFinalization,
			confidence: resolvedContextUsed > 0 ? .exact : .bestEffort,
			session: session
		)
	}

	func ingestStatusSignal(_ statusText: String?, session: AgentModeViewModel.TabSession) {
		_ = statusText
		_ = session
	}

	func ingestSystemSignal(_ systemText: String?, session: AgentModeViewModel.TabSession) {
		_ = systemText
		_ = session
	}

	@discardableResult
	func finalizeTurn(
		promptTokens: Int?,
		completionTokens: Int?,
		contextUsedTokens: Int?,
		session: AgentModeViewModel.TabSession
	) -> Bool {
		let prompt = max(0, promptTokens ?? 0)
		let completion = max(0, completionTokens ?? 0)
		let accumulator = session.activeNonCodexTurnTokenAccumulator
		let estimatedUser = accumulator?.estimatedUserInputTokens ?? 0
		let estimatedToolInput = accumulator?.estimatedToolInputTokens ?? 0
		let estimatedToolOutput = accumulator?.estimatedToolOutputTokens ?? 0
		let hasUsage = prompt > 0
			|| completion > 0
			|| estimatedUser > 0
			|| estimatedToolInput > 0
			|| estimatedToolOutput > 0

		guard hasUsage else {
			if !session.providerTokenUsageByTurn.isEmpty, session.codexContextUsage == nil {
				session.codexContextUsage = contextUsageBuilder(
					session.providerTokenUsageByTurn,
					nil
				)
				_ = updateSnapshot(
					from: session.codexContextUsage,
					source: .persistedTurns,
					confidence: .inferred,
					session: session
				)
			}
			return false
		}

		session.activeNonCodexTurnTokenAccumulator = nil
		let resolvedContextUsed = max(0, contextUsedTokens ?? 0)
		let usage = AgentTokenUsagePersist(
			promptTokens: prompt,
			completionTokens: completion,
			contextUsedTokens: resolvedContextUsed > 0 ? resolvedContextUsed : nil,
			estimatedUserInputTokens: estimatedUser,
			estimatedToolInputTokens: estimatedToolInput,
			estimatedToolOutputTokens: estimatedToolOutput
		)
		session.providerTokenUsageByTurn.append(usage)
		session.codexContextUsage = contextUsageBuilder(
			session.providerTokenUsageByTurn,
			session.codexContextUsage?.modelContextWindow
		)
		_ = updateSnapshot(
			from: session.codexContextUsage,
			source: .turnFinalization,
			confidence: .inferred,
			session: session
		)
		session.isDirty = true
		return true
	}

	private func updateSnapshot(
		from usage: AgentContextUsage?,
		source: ContextUsageSnapshotSource,
		confidence: ContextUsageSnapshotConfidence,
		session: AgentModeViewModel.TabSession
	) -> ContextUsageSnapshot? {
		let next = ContextUsageSnapshot.fromAgentContextUsage(
			usage,
			source: source,
			confidence: confidence,
			compactedAt: session.contextCompactedAt
		)
		if session.contextUsageSnapshot != next {
			session.contextUsageSnapshot = next
			return next
		}
		return nil
	}

	private func tokenEstimate(for payload: String?) -> Int {
		max(0, tokenEstimator(payload ?? ""))
	}
}
