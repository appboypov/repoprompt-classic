import AppKit
import XCTest
@testable import RepoPrompt

@MainActor
final class MarkdownTextViewScrollEventTests: XCTestCase {
	func testReadOnlySelectionRestoreDoesNotRequestScrollToVisibleWhenFirstResponder() {
		let shouldScroll = TextViewSelectionRestorePolicy
			.shouldScrollSelectionToVisibleAfterAttributedReplacement(
				isEditable: false,
				wasFirstResponder: true
			)

		XCTAssertFalse(shouldScroll)
	}

	func testEditableSelectionRestoreCanRequestScrollToVisibleWhenFirstResponder() {
		XCTAssertTrue(
			TextViewSelectionRestorePolicy
				.shouldScrollSelectionToVisibleAfterAttributedReplacement(
					isEditable: true,
					wasFirstResponder: true
				)
		)
		XCTAssertFalse(
			TextViewSelectionRestorePolicy
				.shouldScrollSelectionToVisibleAfterAttributedReplacement(
					isEditable: true,
					wasFirstResponder: false
				)
		)
	}

	func testReadOnlyCodeBlockTextViewForwardsScrollWheelToAncestorScrollView() {
		let scrollView = RecordingScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
		let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
		let textView = CodeBlockTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
		textView.isEditable = false
		textView.isSelectable = true
		scrollView.documentView = container
		container.addSubview(textView)

		XCTAssertTrue(textView.scrollWheelForwardingTarget() === scrollView)
		XCTAssertTrue(textView.shouldForwardScrollWheelToAncestorScrollView())

		let event = Self.makeScrollWheelEvent(deltaY: -12)
		textView.scrollWheel(with: event)

		XCTAssertEqual(scrollView.scrollWheelCallCount, 1)
		XCTAssertTrue(scrollView.lastScrollWheelEvent === event)
	}

	func testEditableCodeBlockTextViewUsesDefaultScrollWheelHandling() {
		let textView = CodeBlockTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
		textView.isEditable = true

		XCTAssertFalse(textView.shouldForwardScrollWheelToAncestorScrollView())
	}

	func testMeasurementWidthResolverUsesFallbackWhenProposalIsMissing() {
		let resolvedWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
			proposedWidth: nil,
			boundsWidth: 0,
			lastMeasuredWidth: 0,
			fallbackWidth: 240
		)
		let narrowerBoundsWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
			proposedWidth: nil,
			boundsWidth: 180,
			lastMeasuredWidth: 0,
			fallbackWidth: 240
		)

		XCTAssertEqual(resolvedWidth, 240)
		XCTAssertEqual(narrowerBoundsWidth, 180)
	}

	func testMeasurementWidthResolverPrefersProposalAndHonorsNarrowerBounds() {
		let proposalWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
			proposedWidth: 320,
			boundsWidth: 0,
			lastMeasuredWidth: 180,
			fallbackWidth: 240
		)
		let narrowerBoundsWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
			proposedWidth: 320,
			boundsWidth: 220,
			lastMeasuredWidth: 180,
			fallbackWidth: 240
		)
		let effectivelyEqualBoundsWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
			proposedWidth: 320,
			boundsWidth: 319.75,
			lastMeasuredWidth: 180,
			fallbackWidth: 240
		)

		XCTAssertEqual(proposalWidth, 320)
		XCTAssertEqual(narrowerBoundsWidth, 220)
		XCTAssertEqual(effectivelyEqualBoundsWidth, 320)
	}

	func testMeasurementWidthResolverKeepsExistingFallbackOrderWithoutProposal() {
		let lastMeasuredWithBoundsWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
			proposedWidth: nil,
			boundsWidth: 260,
			lastMeasuredWidth: 300,
			fallbackWidth: nil
		)
		let lastMeasuredWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
			proposedWidth: nil,
			boundsWidth: 0,
			lastMeasuredWidth: 300,
			fallbackWidth: nil
		)
		let boundsWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
			proposedWidth: nil,
			boundsWidth: 260,
			lastMeasuredWidth: 0,
			fallbackWidth: nil
		)
		let invalidWidth = AttributedTextMeasurementWidthResolver.resolveWidth(
			proposedWidth: nil,
			boundsWidth: .infinity,
			lastMeasuredWidth: .nan,
			fallbackWidth: 1
		)

		XCTAssertEqual(lastMeasuredWithBoundsWidth, 260)
		XCTAssertEqual(lastMeasuredWidth, 300)
		XCTAssertEqual(boundsWidth, 260)
		XCTAssertNil(invalidWidth)
	}

	private static func makeScrollWheelEvent(deltaY: Int32) -> NSEvent {
		let cgEvent = CGEvent(
			scrollWheelEvent2Source: nil,
			units: .pixel,
			wheelCount: 2,
			wheel1: deltaY,
			wheel2: 0,
			wheel3: 0
		)
		XCTAssertNotNil(cgEvent)

		let event = cgEvent.flatMap(NSEvent.init(cgEvent:))
		XCTAssertNotNil(event)
		return event!
	}
}

private final class RecordingScrollView: NSScrollView {
	private(set) var scrollWheelCallCount = 0
	private(set) weak var lastScrollWheelEvent: NSEvent?

	override func scrollWheel(with event: NSEvent) {
		scrollWheelCallCount += 1
		lastScrollWheelEvent = event
	}
}
