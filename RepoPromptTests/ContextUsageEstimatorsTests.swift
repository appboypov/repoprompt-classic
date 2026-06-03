import XCTest
@testable import RepoPrompt

final class ContextUsageEstimatorsTests: XCTestCase {
	private func claudeContextUsageBuilder() -> ProviderTurnContextUsageBuilder {
		{ usage, modelContextWindow in
			guard !usage.isEmpty else { return nil }
			// Only trust actual values reported by Claude's API (contextUsedTokens, promptTokens).
			// Never fall back to estimated values which can inflate the displayed usage.
			let latestContextUsed = usage.reversed().compactMap { turn -> Int? in
				if let contextUsed = turn.contextUsedTokens, contextUsed > 0 {
					return contextUsed
				}
				if turn.promptTokens > 0 {
					return turn.promptTokens
				}
				return nil
			}.first
			guard latestContextUsed != nil || modelContextWindow != nil else { return nil }
			return AgentContextUsage(
				modelContextWindow: modelContextWindow,
				lastTotalTokens: latestContextUsed,
				totalTotalTokens: latestContextUsed
			)
		}
	}

	@MainActor
	func testClaudeEstimatorFinalizesTurnAndUpdatesSessionUsage() {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let estimator = ClaudeContextUsageEstimator(
			tokenEstimator: { _ in 5 },
			contextUsageBuilder: claudeContextUsageBuilder()
		)

		_ = estimator.enqueueUserTurnEstimate(messageForProvider: "hello", session: session)
		estimator.beginTurn(session: session, initialMessage: "hello")
		estimator.addToolInputPayload("{\"tool\":true}", session: session)
		estimator.addToolOutputPayload("{\"ok\":true}", session: session)
		_ = estimator.ingestUsageSignal(
			promptTokens: 100,
			completionTokens: 10,
			contextUsedTokens: nil,
			modelContextWindow: 200_000,
			session: session
		)

		let didFinalize = estimator.finalizeTurn(
			promptTokens: 100,
			completionTokens: 10,
			contextUsedTokens: nil,
			session: session
		)

		XCTAssertTrue(didFinalize)
		XCTAssertEqual(session.providerTokenUsageByTurn.count, 1)
		XCTAssertEqual(session.providerTokenUsageByTurn[0].promptTokens, 100)
		XCTAssertEqual(session.providerTokenUsageByTurn[0].completionTokens, 10)
		XCTAssertEqual(session.providerTokenUsageByTurn[0].estimatedUserInputTokens, 5)
		XCTAssertEqual(session.providerTokenUsageByTurn[0].estimatedToolInputTokens, 5)
		XCTAssertEqual(session.providerTokenUsageByTurn[0].estimatedToolOutputTokens, 5)
		XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 200_000)
		XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 100)
		XCTAssertEqual(session.codexContextUsage?.totalTotalTokens, 100)
		XCTAssertEqual(session.contextUsageSnapshot?.source, .turnFinalization)
		XCTAssertEqual(session.contextUsageSnapshot?.used, 100)
	}

	@MainActor
	func testClaudeEstimatorFinalizationIsIdempotent() {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let estimator = ClaudeContextUsageEstimator(
			tokenEstimator: { _ in 0 },
			contextUsageBuilder: claudeContextUsageBuilder()
		)
		estimator.beginTurn(session: session, initialMessage: "hello")

		let firstFinalize = estimator.finalizeTurn(
			promptTokens: 42,
			completionTokens: 8,
			contextUsedTokens: 64,
			session: session
		)
		let secondFinalize = estimator.finalizeTurn(
			promptTokens: nil,
			completionTokens: nil,
			contextUsedTokens: nil,
			session: session
		)

		XCTAssertTrue(firstFinalize)
		XCTAssertFalse(secondFinalize)
		XCTAssertEqual(session.providerTokenUsageByTurn.count, 1)
		XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 64)
	}

	@MainActor
	func testClaudeEstimatorUsesLatestContextUsedWithoutDoubleCountingAcrossTurns() {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let estimator = ClaudeContextUsageEstimator(
			tokenEstimator: { _ in 0 },
			contextUsageBuilder: claudeContextUsageBuilder()
		)

		estimator.beginTurn(session: session, initialMessage: "first")
		_ = estimator.finalizeTurn(
			promptTokens: 100,
			completionTokens: 20,
			contextUsedTokens: 140,
			session: session
		)

		estimator.beginTurn(session: session, initialMessage: "second")
		_ = estimator.finalizeTurn(
			promptTokens: 120,
			completionTokens: 30,
			contextUsedTokens: 180,
			session: session
		)

		XCTAssertEqual(session.providerTokenUsageByTurn.count, 2)
		XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 180)
		XCTAssertEqual(session.codexContextUsage?.totalTotalTokens, 180)
	}

	@MainActor
	func testClaudeEstimatorCapturesCompactionSignal() {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.codexContextUsage = AgentContextUsage(
			modelContextWindow: 200_000,
			lastTotalTokens: 500,
			totalTotalTokens: 1_500
		)
		let estimator = ClaudeContextUsageEstimator(
			tokenEstimator: { _ in 0 },
			contextUsageBuilder: claudeContextUsageBuilder()
		)

		estimator.ingestStatusSignal("Compacting context…", session: session)

		XCTAssertNotNil(session.contextCompactedAt)
		XCTAssertEqual(session.contextUsageSnapshot?.source, .compactionSignal)
		XCTAssertEqual(session.contextUsageSnapshot?.window, 200_000)
		XCTAssertEqual(session.contextUsageSnapshot?.used, 500)
		XCTAssertNotNil(session.contextUsageSnapshot?.compactedAt)
	}

	@MainActor
	func testClaudeEstimatorCompactionWithoutUsageStillCreatesSnapshot() {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let estimator = ClaudeContextUsageEstimator(
			tokenEstimator: { _ in 0 },
			contextUsageBuilder: claudeContextUsageBuilder()
		)

		estimator.ingestStatusSignal("Compacting context…", session: session)

		XCTAssertNotNil(session.contextCompactedAt)
		XCTAssertEqual(session.contextUsageSnapshot?.source, .compactionSignal)
		XCTAssertNil(session.contextUsageSnapshot?.used)
		XCTAssertNil(session.contextUsageSnapshot?.window)
		XCTAssertNotNil(session.contextUsageSnapshot?.compactedAt)
	}

	@MainActor
	func testCodexEstimatorPassThroughFromNativeUsage() {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let estimator = CodexContextUsageEstimator()
		let usage = AgentContextUsage(
			modelContextWindow: 128_000,
			lastTotalTokens: 4_000,
			totalTotalTokens: 42_000
		)

		let snapshot = estimator.ingestNativeContextUsage(usage, session: session)

		XCTAssertEqual(snapshot?.source, .codexNativeUsage)
		XCTAssertEqual(snapshot?.confidence, .exact)
		XCTAssertEqual(snapshot?.window, 128_000)
		XCTAssertEqual(snapshot?.used, 4_000)
		XCTAssertEqual(session.contextUsageSnapshot, snapshot)
	}
}
