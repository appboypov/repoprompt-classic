import XCTest
@testable import RepoPrompt

@MainActor
final class MentionOverlayControllerTests: XCTestCase {
	func testSuggestionWindowResizesWhenFirstUpdateHasEmptyResults() {
		let window = MentionOverlayController.SuggestionWindow(
			parent: nil,
			placement: .above,
			width: 240
		)
		defer { window.orderOut(nil) }

		XCTAssertEqual(window.frame.height, 1, accuracy: 0.001)

		window.updateSuggestions([], highlighted: 0)

		XCTAssertGreaterThan(
			window.frame.height,
			1,
			"Suggestion window should expand to show the empty-state row."
		)
	}
}
