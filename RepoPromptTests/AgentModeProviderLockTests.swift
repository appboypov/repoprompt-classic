import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeProviderLockTests: XCTestCase {
	func testFreshHandoffKeepsProviderSelectionUnlockedUntilFirstSendSucceeds() {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.hasSentFirstMessage = true
		session.pendingHandoff = AgentModeViewModel.PendingHandoffState(
			payload: "handoff",
			createdAt: Date(),
			sourceItemID: UUID(),
			defersProviderLockUntilSend: true,
			isStagedForSend: false
		)

		XCTAssertFalse(session.isProviderSelectionLocked)

		session.pendingHandoff.clearAfterSend()

		XCTAssertTrue(session.isProviderSelectionLocked)
	}

	func testResumeRecoveryHandoffDoesNotUnlockProviderSelection() {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.hasSentFirstMessage = true
		session.pendingHandoff = AgentModeViewModel.PendingHandoffState(
			payload: "resume",
			createdAt: Date(),
			sourceItemID: UUID(),
			defersProviderLockUntilSend: false,
			isStagedForSend: false
		)

		XCTAssertTrue(session.isProviderSelectionLocked)
	}

	func testAgentSessionLegacyDecodeDefaultsDeferredProviderLockFlagToFalse() throws {
		let encoded = try JSONEncoder().encode(
			AgentSession(
				name: "Session",
				pendingHandoffPayload: "payload",
				pendingHandoffCreatedAt: Date(),
				pendingHandoffSourceItemID: UUID(),
				pendingHandoffDefersProviderLockUntilSend: true
			)
		)
		var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		jsonObject.removeValue(forKey: "pendingHandoffDefersProviderLockUntilSend")
		let legacyData = try JSONSerialization.data(withJSONObject: jsonObject)

		let decoded = try JSONDecoder().decode(AgentSession.self, from: legacyData)

		XCTAssertFalse(decoded.pendingHandoffDefersProviderLockUntilSend)
	}
}
