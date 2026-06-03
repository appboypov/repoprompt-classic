import Foundation
import XCTest
@testable import RepoPrompt

final class AgentComposerViewEqualityTests: XCTestCase {
	func testEquatableInputsIncludeDirectCurrentTabIDWhenPropsAlreadyMatch() {
		let sourceTabID = UUID()
		let destinationTabID = UUID()
		let props = AgentComposerProps.empty

		XCTAssertFalse(
			AgentComposerView.areEquatableInputsEqual(
				lhsProps: props,
				rhsProps: props,
				lhsPlaceholderText: "Send a message...",
				rhsPlaceholderText: "Send a message...",
				lhsWindowID: 1,
				rhsWindowID: 1,
				lhsCurrentTabID: sourceTabID,
				rhsCurrentTabID: destinationTabID
			),
			"A direct tab-ID-only change must refresh the composer so draft and paste closures route to the active tab."
		)
	}

	func testEquatableInputsIncludeWindowIDWhenPropsAlreadyMatch() {
		let tabID = UUID()
		let props = AgentComposerProps.empty

		XCTAssertFalse(
			AgentComposerView.areEquatableInputsEqual(
				lhsProps: props,
				rhsProps: props,
				lhsPlaceholderText: "Send a message...",
				rhsPlaceholderText: "Send a message...",
				lhsWindowID: 1,
				rhsWindowID: 2,
				lhsCurrentTabID: tabID,
				rhsCurrentTabID: tabID
			),
			"A window-ID-only change must refresh window-scoped composer actions such as image picker presentation."
		)
	}

	func testEquatableInputsRemainEqualForIdenticalBehavioralInputs() {
		let tabID = UUID()
		let props = AgentComposerProps.empty

		XCTAssertTrue(
			AgentComposerView.areEquatableInputsEqual(
				lhsProps: props,
				rhsProps: props,
				lhsPlaceholderText: "Send a message...",
				rhsPlaceholderText: "Send a message...",
				lhsWindowID: 1,
				rhsWindowID: 1,
				lhsCurrentTabID: tabID,
				rhsCurrentTabID: tabID
			)
		)
	}
}
