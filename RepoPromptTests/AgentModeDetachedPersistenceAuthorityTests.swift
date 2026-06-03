import XCTest
@testable import RepoPrompt

final class AgentModeDetachedPersistenceAuthorityTests: XCTestCase {
	private let turnID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
	private let spanID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
	private let otherSpanID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
	private let activityID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

	func testPreferredDetachedPersistenceAuthorityPromotesSameFamilyDescendantActivity() {
		let stored = DetachedViewportAuthority(
			targetID: .block("grouped-history:block"),
			anchor: .groupedHistory(turnID: turnID, spanID: spanID),
			sequenceIndex: 10,
			blockID: "grouped-history:block",
			viewportMinY: -20
		)
		let live = DetachedViewportAuthority(
			targetID: .row(activityID),
			anchor: .activity(turnID: turnID, spanID: spanID, activityID: activityID),
			sequenceIndex: 11,
			blockID: "activity:block",
			viewportMinY: -24
		)

		XCTAssertEqual(preferredDetachedPersistenceAuthority(stored: stored, live: live), live)
	}

	func testPreferredDetachedPersistenceAuthorityPreservesExistingLiveChoiceAcrossFamilies() {
		let stored = DetachedViewportAuthority(
			targetID: .block("grouped-history:block"),
			anchor: .groupedHistory(turnID: turnID, spanID: spanID),
			sequenceIndex: 10,
			blockID: "grouped-history:block",
			viewportMinY: -20
		)
		let live = DetachedViewportAuthority(
			targetID: .row(activityID),
			anchor: .activity(turnID: turnID, spanID: otherSpanID, activityID: activityID),
			sequenceIndex: 11,
			blockID: "activity:block",
			viewportMinY: -24
		)

		XCTAssertEqual(preferredDetachedPersistenceAuthority(stored: stored, live: live), live)
	}

	func testPreferredDetachedPersistenceAuthorityDoesNotRegressToGroupedHistoryWhenStoredActivityIsMoreSpecific() {
		let stored = DetachedViewportAuthority(
			targetID: .row(activityID),
			anchor: .activity(turnID: turnID, spanID: spanID, activityID: activityID),
			sequenceIndex: 11,
			blockID: "activity:block",
			viewportMinY: -24
		)
		let live = DetachedViewportAuthority(
			targetID: .block("grouped-history:block"),
			anchor: .groupedHistory(turnID: turnID, spanID: spanID),
			sequenceIndex: 10,
			blockID: "grouped-history:block",
			viewportMinY: -20
		)

		XCTAssertEqual(preferredDetachedPersistenceAuthority(stored: stored, live: live), stored)
	}

	func testPreferredDetachedPersistenceAuthorityFallsBackToStoredWhenLiveIsUnavailable() {
		let stored = DetachedViewportAuthority(
			targetID: .block("grouped-history:block"),
			anchor: .groupedHistory(turnID: turnID, spanID: spanID),
			sequenceIndex: 10,
			blockID: "grouped-history:block",
			viewportMinY: -20
		)

		XCTAssertEqual(preferredDetachedPersistenceAuthority(stored: stored, live: nil), stored)
	}
}
