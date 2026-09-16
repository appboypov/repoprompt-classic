import XCTest
@testable import RepoPrompt

final class WorkspaceOrderingTests: XCTestCase {
	func testVisibleMoveKeepsHiddenSlots() {
		let a = UUID(), b = UUID(), hidden = UUID(), c = UUID()
		let full = [a, b, hidden, c]

		let moved = WorkspaceOrdering.applyVisibleMove(fullOrder: full, visibleOrder: [c, a, b])

		XCTAssertEqual(moved, [c, a, hidden, b])
	}

	func testVisibleMoveIgnoresUnknownIDs() {
		let a = UUID(), b = UUID()

		let moved = WorkspaceOrdering.applyVisibleMove(fullOrder: [a, b], visibleOrder: [b, UUID(), a])

		XCTAssertEqual(moved, [b, a])
	}

	func testPermutationRejectsDuplicatesAndMissingIDs() {
		let a = UUID(), b = UUID()

		XCTAssertTrue(WorkspaceOrdering.isPermutation([b, a], of: [a, b]))
		XCTAssertFalse(WorkspaceOrdering.isPermutation([a, a], of: [a, b]))
		XCTAssertFalse(WorkspaceOrdering.isPermutation([a], of: [a, b]))
	}
}
