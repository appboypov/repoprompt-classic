import XCTest
@testable import RepoPrompt

final class AgentOraclePillLogicTests: XCTestCase {
	private func makeSession(
		id: UUID = UUID(),
		name: String,
		savedAt: Date,
		messageCount: Int? = nil,
		messages: [StoredMessage] = [],
		agentModeSessionID: UUID? = nil,
		agentModeRunID: UUID? = nil,
		shortID: String? = nil
	) -> ChatSession {
		ChatSession(
			id: id,
			agentModeSessionID: agentModeSessionID,
			agentModeRunID: agentModeRunID,
			name: name,
			savedAt: savedAt,
			messages: messages,
			messageCount: messageCount,
			shortID: shortID
		)
	}

	func testEligibleSessionsUsesLiveMessageCountWhenStubHasNotBeenAutosavedYet() {
		let sessionID = UUID()
		let session = makeSession(id: sessionID, name: "Oracle", savedAt: Date(), messageCount: nil, messages: [])

		let eligible = AgentOraclePillLogic.eligibleSessions(
			sessions: [session],
			streamingSessionIDs: [],
			liveMessageCount: { id in id == sessionID ? 2 : nil }
		)

		XCTAssertEqual(eligible.map(\.id), [sessionID])
	}

	func testLatestSessionPrefersStreamingSessionOverNewerNonStreamingSession() {
		let now = Date()
		let streamingID = UUID()
		let streaming = makeSession(id: streamingID, name: "Streaming", savedAt: now.addingTimeInterval(-30), messageCount: 1)
		let newer = makeSession(name: "Newer", savedAt: now, messageCount: 1)

		let latest = AgentOraclePillLogic.latestSession(
			in: [newer, streaming],
			streamingSessionIDs: [streamingID]
		)

		XCTAssertEqual(latest?.id, streamingID)
	}

	func testSelectedSessionIDKeepsExistingSelectionInsteadOfFallingBackToLatest() {
		let now = Date()
		let selected = makeSession(name: "Selected", savedAt: now.addingTimeInterval(-60), messageCount: 1)
		let newer = makeSession(name: "Newer", savedAt: now, messageCount: 1)

		let resolved = AgentOraclePillLogic.selectedSessionID(
			currentSelectionID: selected.id,
			in: [newer, selected],
			streamingSessionIDs: []
		)

		XCTAssertEqual(resolved, selected.id)
	}

	func testSelectedSessionIDFallsBackToLatestWhenSelectionIsMissing() {
		let now = Date()
		let streaming = makeSession(name: "Streaming", savedAt: now.addingTimeInterval(-60), messageCount: 1)
		let newer = makeSession(name: "Newer", savedAt: now, messageCount: 1)

		let resolved = AgentOraclePillLogic.selectedSessionID(
			currentSelectionID: UUID(),
			in: [newer, streaming],
			streamingSessionIDs: [streaming.id]
		)

		XCTAssertEqual(resolved, streaming.id)
	}

	func testExplicitReconcileKeepsSameTabSessionEvenWhenIneligible() {
		let now = Date()
		let explicit = makeSession(name: "Context Builder", savedAt: now.addingTimeInterval(-60), messageCount: 1)
		let eligible = makeSession(name: "Eligible", savedAt: now, messageCount: 1)

		let resolved = AgentOraclePillLogic.reconciledPresentedSessionID(
			currentSessionID: explicit.id,
			isExplicit: true,
			sameTabSessions: [explicit, eligible],
			eligibleSessions: [eligible],
			streamingSessionIDs: []
		)

		XCTAssertEqual(resolved, explicit.id)
	}

	func testExplicitReconcileClosesWhenSessionLeavesTab() {
		let now = Date()
		let explicit = makeSession(name: "Context Builder", savedAt: now.addingTimeInterval(-60), messageCount: 1)
		let eligible = makeSession(name: "Eligible", savedAt: now, messageCount: 1)

		let resolved = AgentOraclePillLogic.reconciledPresentedSessionID(
			currentSessionID: explicit.id,
			isExplicit: true,
			sameTabSessions: [eligible],
			eligibleSessions: [eligible],
			streamingSessionIDs: []
		)

		XCTAssertNil(resolved)
	}

	func testGenericReconcileFallsBackToLatestEligibleWhenSelectionBecomesIneligible() {
		let now = Date()
		let oldSelection = makeSession(name: "Old", savedAt: now.addingTimeInterval(-60), messageCount: 1)
		let eligible = makeSession(name: "Eligible", savedAt: now, messageCount: 1)

		let resolved = AgentOraclePillLogic.reconciledPresentedSessionID(
			currentSessionID: oldSelection.id,
			isExplicit: false,
			sameTabSessions: [oldSelection, eligible],
			eligibleSessions: [eligible],
			streamingSessionIDs: []
		)

		XCTAssertEqual(resolved, eligible.id)
	}

	func testEligibleSessionsExcludeSameTabSessionsOwnedByDifferentAgentSession() {
		let now = Date()
		let owner = UUID()
		let otherOwner = UUID()
		let owned = makeSession(name: "Owned", savedAt: now, messageCount: 1, agentModeSessionID: owner)
		let other = makeSession(name: "Other", savedAt: now.addingTimeInterval(10), messageCount: 1, agentModeSessionID: otherOwner)

		let eligible = AgentOraclePillLogic.eligibleSessions(
			sessions: [other, owned],
			streamingSessionIDs: [],
			liveMessageCount: { _ in nil },
			activeAgentSessionID: owner
		)

		XCTAssertEqual(eligible.map(\.id), [owned.id])
	}

	func testEligibleSessionsPreferStreamingOnlyWhenItMatchesOwner() {
		let now = Date()
		let owner = UUID()
		let otherOwner = UUID()
		let matching = makeSession(name: "Owned", savedAt: now, messageCount: 1, agentModeSessionID: owner)
		let otherStreaming = makeSession(name: "Other Streaming", savedAt: now.addingTimeInterval(10), messageCount: 1, agentModeSessionID: otherOwner)

		let eligible = AgentOraclePillLogic.eligibleSessions(
			sessions: [matching, otherStreaming],
			streamingSessionIDs: [otherStreaming.id],
			liveMessageCount: { _ in nil },
			activeAgentSessionID: owner
		)
		let latest = AgentOraclePillLogic.latestSession(in: eligible, streamingSessionIDs: [otherStreaming.id])

		XCTAssertEqual(latest?.id, matching.id)
	}

	func testEligibleSessionsPreferExactRunOverSameAgentLegacyRun() {
		let now = Date()
		let owner = UUID()
		let runID = UUID()
		let exact = makeSession(name: "Exact", savedAt: now, messageCount: 1, agentModeSessionID: owner, agentModeRunID: runID)
		let legacyRun = makeSession(name: "Legacy", savedAt: now.addingTimeInterval(10), messageCount: 1, agentModeSessionID: owner)

		let eligible = AgentOraclePillLogic.eligibleSessions(
			sessions: [legacyRun, exact],
			streamingSessionIDs: [legacyRun.id],
			liveMessageCount: { _ in nil },
			activeAgentSessionID: owner,
			activeRunID: runID
		)

		XCTAssertEqual(eligible.map(\.id), [exact.id])
	}

	func testSessionMatchingChatIDMatchesUUIDAndShortIDExactly() {
		let id = UUID()
		let session = makeSession(id: id, name: "Oracle", savedAt: Date(), messageCount: 1, shortID: "oracle-abcdef")

		XCTAssertEqual(AgentOraclePillLogic.session(matchingChatID: id.uuidString, in: [session])?.id, id)
		XCTAssertEqual(AgentOraclePillLogic.session(matchingChatID: "oracle-abcdef", in: [session])?.id, id)
	}

	func testSessionMatchingChatIDDoesNotFallBackWhenMissing() {
		let newer = makeSession(name: "Newer", savedAt: Date(), messageCount: 1, shortID: "newer-abcdef")

		XCTAssertNil(AgentOraclePillLogic.session(matchingChatID: "missing-chat", in: [newer]))
	}
}
