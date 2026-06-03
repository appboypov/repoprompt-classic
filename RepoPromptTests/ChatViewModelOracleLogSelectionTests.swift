import XCTest
@testable import RepoPrompt

@MainActor
final class ChatViewModelOracleLogSelectionTests: XCTestCase {
	private func makeSession(
		id: UUID = UUID(),
		tabID: UUID,
		name: String,
		savedAt: Date,
		agentModeSessionID: UUID? = nil,
		agentModeRunID: UUID? = nil
	) -> ChatSession {
		ChatSession(
			id: id,
			composeTabID: tabID,
			agentModeSessionID: agentModeSessionID,
			agentModeRunID: agentModeRunID,
			name: name,
			savedAt: savedAt,
			messages: [StoredMessage(isUser: false, rawText: name, sequenceIndex: 0)]
		)
	}

	func testPreferredOracleLogSessionPrefersActiveTabSessionOverMoreRecentSibling() {
		let tabID = UUID()
		let activeID = UUID()
		let now = Date()
		let active = makeSession(id: activeID, tabID: tabID, name: "Active", savedAt: now.addingTimeInterval(-120))
		let newer = makeSession(tabID: tabID, name: "Newer", savedAt: now)

		let resolved = ChatViewModel.test_preferredOracleLogSession(
			forTabID: tabID,
			sessions: [newer, active],
			activeSessionID: activeID
		)

		XCTAssertEqual(resolved?.id, activeID)
	}

	func testPreferredOracleLogSessionFallsBackToMostRecentNonEmptyTabSessionWhenActiveIsBlank() {
		let tabID = UUID()
		let activeID = UUID()
		let now = Date()
		let activeBlank = ChatSession(
			id: activeID,
			composeTabID: tabID,
			name: "Blank",
			savedAt: now,
			messages: []
		)
		let olderPopulated = makeSession(tabID: tabID, name: "Populated", savedAt: now.addingTimeInterval(-120))

		let resolved = ChatViewModel.test_preferredOracleLogSession(
			forTabID: tabID,
			sessions: [activeBlank, olderPopulated],
			activeSessionID: activeID
		)

		XCTAssertEqual(resolved?.id, olderPopulated.id)
	}

	func testPreferredOracleLogSessionFallsBackToMostRecentTabSession() {
		let tabID = UUID()
		let otherTabID = UUID()
		let now = Date()
		let older = makeSession(tabID: tabID, name: "Older", savedAt: now.addingTimeInterval(-120))
		let newest = makeSession(tabID: tabID, name: "Newest", savedAt: now)
		let otherTab = makeSession(tabID: otherTabID, name: "Other", savedAt: now.addingTimeInterval(60))

		let resolved = ChatViewModel.test_preferredOracleLogSession(
			forTabID: tabID,
			sessions: [older, otherTab, newest],
			activeSessionID: nil
		)

		XCTAssertEqual(resolved?.id, newest.id)
	}

	func testPreferredOracleLogSessionPrefersMatchingOwnerOverNewerOtherOwner() {
		let tabID = UUID()
		let ownerID = UUID()
		let otherOwnerID = UUID()
		let now = Date()
		let owned = makeSession(tabID: tabID, name: "Owned", savedAt: now.addingTimeInterval(-120), agentModeSessionID: ownerID)
		let otherOwned = makeSession(tabID: tabID, name: "Other", savedAt: now, agentModeSessionID: otherOwnerID)

		let resolved = ChatViewModel.test_preferredOracleLogSession(
			forTabID: tabID,
			sessions: [otherOwned, owned],
			activeSessionID: otherOwned.id,
			agentModeSessionID: ownerID
		)

		XCTAssertEqual(resolved?.id, owned.id)
	}

	func testPreferredOracleLogSessionFallsBackToLegacyUnownedOnlyWhenNoOwnedSessionExists() {
		let tabID = UUID()
		let ownerID = UUID()
		let otherOwnerID = UUID()
		let now = Date()
		let legacy = makeSession(tabID: tabID, name: "Legacy", savedAt: now.addingTimeInterval(-60))
		let otherOwned = makeSession(tabID: tabID, name: "Other", savedAt: now, agentModeSessionID: otherOwnerID)

		let resolved = ChatViewModel.test_preferredOracleLogSession(
			forTabID: tabID,
			sessions: [otherOwned, legacy],
			activeSessionID: otherOwned.id,
			agentModeSessionID: ownerID
		)

		XCTAssertEqual(resolved?.id, legacy.id)
	}

	func testPreferredOracleLogSessionPrefersExactRunOverSameAgentOlderRun() {
		let tabID = UUID()
		let ownerID = UUID()
		let currentRunID = UUID()
		let previousRunID = UUID()
		let now = Date()
		let currentRun = makeSession(tabID: tabID, name: "Current", savedAt: now.addingTimeInterval(-120), agentModeSessionID: ownerID, agentModeRunID: currentRunID)
		let previousRun = makeSession(tabID: tabID, name: "Previous", savedAt: now, agentModeSessionID: ownerID, agentModeRunID: previousRunID)

		let resolved = ChatViewModel.test_preferredOracleLogSession(
			forTabID: tabID,
			sessions: [previousRun, currentRun],
			activeSessionID: previousRun.id,
			agentModeSessionID: ownerID,
			agentModeRunID: currentRunID
		)

		XCTAssertEqual(resolved?.id, currentRun.id)
	}

	func testPreferredOracleLogSessionPrefersExactRunOverActiveNilRunLegacy() {
		let tabID = UUID()
		let ownerID = UUID()
		let currentRunID = UUID()
		let activeNilRunID = UUID()
		let now = Date()
		let currentRun = makeSession(tabID: tabID, name: "Current", savedAt: now.addingTimeInterval(-120), agentModeSessionID: ownerID, agentModeRunID: currentRunID)
		let activeNilRun = makeSession(id: activeNilRunID, tabID: tabID, name: "Nil Run", savedAt: now, agentModeSessionID: ownerID)

		let resolved = ChatViewModel.test_preferredOracleLogSession(
			forTabID: tabID,
			sessions: [activeNilRun, currentRun],
			activeSessionID: activeNilRunID,
			agentModeSessionID: ownerID,
			agentModeRunID: currentRunID
		)

		XCTAssertEqual(resolved?.id, currentRun.id)
	}

	func testPreferredOracleLogSessionPrefersSameAgentLegacyRunOverActiveUnownedLegacy() {
		let tabID = UUID()
		let ownerID = UUID()
		let currentRunID = UUID()
		let activeUnownedID = UUID()
		let now = Date()
		let activeUnowned = makeSession(id: activeUnownedID, tabID: tabID, name: "Unowned", savedAt: now)
		let sameAgentLegacyRun = makeSession(tabID: tabID, name: "Same Agent", savedAt: now.addingTimeInterval(-120), agentModeSessionID: ownerID)

		let resolved = ChatViewModel.test_preferredOracleLogSession(
			forTabID: tabID,
			sessions: [activeUnowned, sameAgentLegacyRun],
			activeSessionID: activeUnownedID,
			agentModeSessionID: ownerID,
			agentModeRunID: currentRunID
		)

		XCTAssertEqual(resolved?.id, sameAgentLegacyRun.id)
	}

	func testAutosaveUsesLivePromptStateForCurrentSessionOnActiveTab() {
		let tabID = UUID()
		let sessionID = UUID()

		XCTAssertTrue(ChatViewModel.shouldUseLivePromptStateForAutosave(
			sessionID: sessionID,
			currentSessionID: sessionID,
			sessionComposeTabID: tabID,
			activeComposeTabID: tabID
		))
	}

	func testAutosaveDoesNotUseDestinationTabPromptStateForCurrentSessionDuringTabSwitch() {
		let sourceTabID = UUID()
		let destinationTabID = UUID()
		let sessionID = UUID()

		XCTAssertFalse(ChatViewModel.shouldUseLivePromptStateForAutosave(
			sessionID: sessionID,
			currentSessionID: sessionID,
			sessionComposeTabID: sourceTabID,
			activeComposeTabID: destinationTabID
		))
	}

	func testAutosaveDoesNotUseLivePromptStateForBackgroundSession() {
		XCTAssertFalse(ChatViewModel.shouldUseLivePromptStateForAutosave(
			sessionID: UUID(),
			currentSessionID: UUID(),
			sessionComposeTabID: UUID(),
			activeComposeTabID: UUID()
		))
	}
}
