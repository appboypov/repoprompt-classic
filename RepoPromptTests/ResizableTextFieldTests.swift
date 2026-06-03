import XCTest
import AppKit
import SwiftUI
@testable import RepoPrompt

@MainActor
final class ResizableTextFieldTests: XCTestCase {
	func testPresetIndexClampsVisibleLineFragmentCountToAvailablePresets() {
		XCTAssertEqual(ResizableTextField.presetIndex(forVisibleLineFragmentCount: 0), 0)
		XCTAssertEqual(ResizableTextField.presetIndex(forVisibleLineFragmentCount: 1), 0)
		XCTAssertEqual(ResizableTextField.presetIndex(forVisibleLineFragmentCount: 2), 1)
		XCTAssertEqual(ResizableTextField.presetIndex(forVisibleLineFragmentCount: 9), 8)
		XCTAssertEqual(ResizableTextField.presetIndex(forVisibleLineFragmentCount: 20), 8)
	}

	func testCoordinatorUpdateHeightIfNeededUsesExplicitLineFragments() {
		var text = "one\ntwo\nthree"
		var currentHeightPresetIndex = 0
		var reportedHeights: [CGFloat] = []
		let field = CustomTextField(
			text: Binding(get: { text }, set: { text = $0 }),
			placeholder: "",
			onReturn: { },
			currentHeightPresetIndex: Binding(
				get: { currentHeightPresetIndex },
				set: { currentHeightPresetIndex = $0 }
			),
			onHeightChange: { reportedHeights.append($0) }
		)
		let coordinator = field.makeCoordinator()
		let textView = makeConfiguredTextView(width: 320)
		textView.string = text

		coordinator.updateHeightIfNeeded(textView: textView)

		XCTAssertEqual(currentHeightPresetIndex, 2)
		XCTAssertEqual(reportedHeights.last, ResizableTextField.heightPresets[2])
	}

	func testCoordinatorUpdateHeightIfNeededCountsTrailingBlankLine() {
		var text = "one\n"
		var currentHeightPresetIndex = 0
		var reportedHeights: [CGFloat] = []
		let field = CustomTextField(
			text: Binding(get: { text }, set: { text = $0 }),
			placeholder: "",
			onReturn: { },
			currentHeightPresetIndex: Binding(
				get: { currentHeightPresetIndex },
				set: { currentHeightPresetIndex = $0 }
			),
			onHeightChange: { reportedHeights.append($0) }
		)
		let coordinator = field.makeCoordinator()
		let textView = makeConfiguredTextView(width: 320)
		textView.string = text

		coordinator.updateHeightIfNeeded(textView: textView)

		XCTAssertEqual(currentHeightPresetIndex, 1)
		XCTAssertEqual(reportedHeights.last, ResizableTextField.heightPresets[1])
	}

	func testCoordinatorUpdateHeightIfNeededClampsToMaximumPreset() {
		var text = Array(repeating: "line", count: 16).joined(separator: "\n")
		var currentHeightPresetIndex = 0
		var reportedHeights: [CGFloat] = []
		let field = CustomTextField(
			text: Binding(get: { text }, set: { text = $0 }),
			placeholder: "",
			onReturn: { },
			currentHeightPresetIndex: Binding(
				get: { currentHeightPresetIndex },
				set: { currentHeightPresetIndex = $0 }
			),
			onHeightChange: { reportedHeights.append($0) }
		)
		let coordinator = field.makeCoordinator()
		let textView = makeConfiguredTextView(width: 320)
		textView.string = text

		coordinator.updateHeightIfNeeded(textView: textView)

		XCTAssertEqual(currentHeightPresetIndex, ResizableTextField.heightPresets.count - 1)
		XCTAssertEqual(reportedHeights.last, ResizableTextField.maxHeight)
	}

	private func makeConfiguredTextView(width: CGFloat) -> NSTextView {
		let scrollView = ImageAwareTextView.scrollableTextView()
		guard let textView = scrollView.documentView as? ImageAwareTextView else {
			XCTFail("Expected ImageAwareTextView document view")
			return NSTextView(frame: .zero)
		}

		scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 200)
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.autoresizingMask = [.width]
		textView.textContainer?.widthTracksTextView = true
		textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
		textView.frame = NSRect(x: 0, y: 0, width: width, height: 200)
		textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
		textView.backgroundColor = .clear
		textView.textContainerInset = NSSize(width: 0, height: 6)
		textView.layoutManager?.usesFontLeading = true
		return textView
	}
}
