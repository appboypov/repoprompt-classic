import XCTest
@testable import RepoPrompt

final class AgentModeDetachedRebasePolicyTests: XCTestCase {
	private let turnID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
	private let spanID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
	private let otherTurnID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

	private func makeContext(
		storedFamily: AgentDetachedAuthorityFamily? = .responseSpan(turnID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, spanID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
		liveFamily: AgentDetachedAuthorityFamily? = .responseSpan(turnID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, spanID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
		deltaY: CGFloat? = 0,
		viewportHeight: CGFloat = 600,
		missingLiveAuthorityCount: Int = 0
	) -> AgentDetachedRebaseDecisionContext {
		.init(
			storedFamily: storedFamily,
			liveFamily: liveFamily,
			deltaY: deltaY,
			viewportHeight: viewportHeight,
			missingLiveAuthorityCount: missingLiveAuthorityCount
		)
	}

	func testSmallSameFamilyDriftUsesNoActionInsideTolerance() {
		let decision = decideAgentDetachedRebaseAction(makeContext(deltaY: 6))
		XCTAssertEqual(decision, .none)
	}

	func testBoundedSameFamilyDriftIsAccepted() {
		let decision = decideAgentDetachedRebaseAction(makeContext(deltaY: 18))
		XCTAssertEqual(decision, .acceptDrift)
	}

	func testMediumSameFamilyDriftRestoresByAnchor() {
		let decision = decideAgentDetachedRebaseAction(makeContext(deltaY: 60))
		XCTAssertEqual(decision, .restoreIntent)
	}

	func testLargeSameFamilyDriftRestores() {
		let decision = decideAgentDetachedRebaseAction(makeContext(deltaY: 140))
		XCTAssertEqual(decision, .restoreIntent)
	}

	func testCrossFamilyDriftRestores() {
		let decision = decideAgentDetachedRebaseAction(
			makeContext(
				storedFamily: .request(turnID),
				liveFamily: .conclusion(otherTurnID),
				deltaY: 40
			)
		)
		XCTAssertEqual(decision, .restoreIntent)
	}

	func testMissingLiveAuthorityFirstRevisionAcceptsDrift() {
		let decision = decideAgentDetachedRebaseAction(
			makeContext(liveFamily: nil, deltaY: nil, missingLiveAuthorityCount: 1)
		)
		XCTAssertEqual(decision, .acceptDrift)
	}

	func testMissingLiveAuthoritySecondRevisionRestores() {
		let decision = decideAgentDetachedRebaseAction(
			makeContext(liveFamily: nil, deltaY: nil, missingLiveAuthorityCount: 2)
		)
		XCTAssertEqual(decision, .restoreIntent)
	}
}
