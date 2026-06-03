import XCTest
import Markdown
@testable import RepoPrompt

final class MarkdownCompilerTests: XCTestCase {
	func testCodeBlockSourceRangeExcludesLayoutSpacers() {
		let code = "let value = 42"
		let markdown = """
		Before

		```swift
		\(code)
		```

		After
		"""
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14

		let rendered = compiler.attributedString(from: Document(parsing: markdown))

		XCTAssertTrue(rendered.string.contains("Before\n\n\(code)"))
		XCTAssertFalse(rendered.string.contains("Before\n\n\n\(code)"))

		var sourceRanges: [NSRange] = []
		rendered.enumerateAttribute(.codeBlockSource, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
			guard let source = value as? String else { return }
			XCTAssertEqual(source, code)
			sourceRanges.append(range)
		}

		XCTAssertFalse(sourceRanges.isEmpty)
		let sourceText = sourceRanges
			.map { (rendered.string as NSString).substring(with: $0) }
			.joined()
		XCTAssertEqual(sourceText, code)
		XCTAssertFalse(sourceText.hasSuffix("\n"))

		let firstSpacerLocation = sourceRanges.map(NSMaxRange).max() ?? rendered.length
		XCTAssertLessThan(firstSpacerLocation, rendered.length)
		XCTAssertNil(rendered.attribute(.codeBlockSource, at: firstSpacerLocation, effectiveRange: nil))
	}

	func testCodeBlockSeparatorsUseBodySpacingBetweenTopLevelBlocks() {
		let firstCode = "let before = true"
		let secondCode = "let after = true"
		let markdown = """
		from:

		```swift
		\(firstCode)
		```

		to:

		```swift
		\(secondCode)
		```
		"""
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14

		let rendered = compiler.attributedString(from: Document(parsing: markdown))
		let renderedString = rendered.string as NSString
		let firstCodeRange = renderedString.range(of: firstCode)
		let separatorTextRange = renderedString.range(of: "to:")

		XCTAssertNotEqual(firstCodeRange.location, NSNotFound)
		XCTAssertNotEqual(separatorTextRange.location, NSNotFound)

		let afterCodeLocation = NSMaxRange(firstCodeRange)
		let afterSeparatorTextLocation = NSMaxRange(separatorTextRange)
		XCTAssertEqual(renderedString.substring(with: NSRange(location: afterCodeLocation, length: 2)), "\n\n")
		XCTAssertEqual(renderedString.substring(with: NSRange(location: afterSeparatorTextLocation, length: 2)), "\n\n")

		let afterCodeFont = rendered.attribute(.font, at: afterCodeLocation, effectiveRange: nil) as? NSFont
		let afterSeparatorTextFont = rendered.attribute(.font, at: afterSeparatorTextLocation, effectiveRange: nil) as? NSFont
		XCTAssertEqual(afterCodeFont?.pointSize ?? 0, afterSeparatorTextFont?.pointSize ?? -1, accuracy: 0.1)
		XCTAssertEqual(afterCodeFont?.pointSize ?? 0, 14, accuracy: 0.1)
	}

	func testTerminalCodeBlockKeepsCompactTrailingSpacer() {
		let code = "let value = 42"
		let fontSize: CGFloat = 14
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = fontSize

		let rendered = compiler.attributedString(from: Document(parsing: "```swift\n\(code)\n```"))
		let codeRange = (rendered.string as NSString).range(of: code)
		XCTAssertNotEqual(codeRange.location, NSNotFound)

		let trailingSpacerLocation = NSMaxRange(codeRange)
		XCTAssertLessThan(trailingSpacerLocation, rendered.length)
		let trailingSpacerFont = rendered.attribute(.font, at: trailingSpacerLocation, effectiveRange: nil) as? NSFont
		XCTAssertEqual(trailingSpacerFont?.pointSize ?? 0, max(fontSize * 0.5, 6), accuracy: 0.1)
	}

	func testListCodeBlockKeepsCompactLeadingSpacer() {
		let code = "let value = 42"
		let markdown = "- Default:\n  - Intro:\n\n    ```swift\n    \(code)\n    ```"
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14

		let rendered = compiler.attributedString(from: Document(parsing: markdown))

		XCTAssertTrue(rendered.string.contains("Intro:\n\n\(code)"))
		XCTAssertFalse(rendered.string.contains("Intro:\n\(code)"))

		var sourceText = ""
		rendered.enumerateAttribute(.codeBlockSource, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
			guard value != nil else { return }
			sourceText += (rendered.string as NSString).substring(with: range)
		}
		XCTAssertEqual(sourceText, code)
	}

	func testListCodeBlockWithSuccessorKeepsCompactTrailingSpacer() {
		let code = "let value = 42"
		let fontSize: CGFloat = 14
		let markdown = "- Intro:\n\n  ```swift\n  \(code)\n  ```\n\n  More details"
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = fontSize

		let rendered = compiler.attributedString(from: Document(parsing: markdown))
		let renderedString = rendered.string as NSString
		let codeRange = renderedString.range(of: code)
		XCTAssertNotEqual(codeRange.location, NSNotFound)

		let trailingSpacerLocation = NSMaxRange(codeRange)
		XCTAssertEqual(renderedString.substring(with: NSRange(location: trailingSpacerLocation, length: 2)), "\n\n")
		let trailingSpacerFont = rendered.attribute(.font, at: trailingSpacerLocation, effectiveRange: nil) as? NSFont
		XCTAssertEqual(trailingSpacerFont?.pointSize ?? 0, max(fontSize * 0.5, 6), accuracy: 0.1)
	}

	func testTableRendersAsInlineTextTableWithoutRowListFallback() {
		let markdown = """
		| Name | Notes |
		| --- | --- |
		| Alpha | A long detail with [docs](docs/table.md) that should wrap inside the normal markdown text view. |
		| Beta | Another value |
		"""
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14

		let rendered = compiler.attributedString(from: Document(parsing: markdown))
		let tableBlocks = rendered.textTableBlocks()

		XCTAssertFalse(tableBlocks.isEmpty)
		XCTAssertTrue(tableBlocks.contains { $0.table.numberOfColumns == 2 })
		XCTAssertTrue(rendered.string.contains("Name"))
		XCTAssertTrue(rendered.string.contains("Notes"))
		XCTAssertTrue(rendered.string.contains("Alpha"))
		XCTAssertTrue(rendered.string.contains("A long detail"))
		XCTAssertFalse(rendered.string.contains("Row 1"))
		XCTAssertFalse(rendered.string.contains("• Name:"))
		XCTAssertFalse(rendered.string.contains("| --- |"))
		XCTAssertFalse(rendered.string.contains("| Name |"))
	}

	func testTextTablePreservesMarkdownColumnAlignment() {
		let markdown = """
		| Left | Center | Right |
		| :--- | :----: | ----: |
		| A | B | C |
		"""
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14

		let rendered = compiler.attributedString(from: Document(parsing: markdown))
		let alignments = rendered.textTableColumnAlignments(forRow: 1)

		XCTAssertEqual(alignments[0], .left)
		XCTAssertEqual(alignments[1], .center)
		XCTAssertEqual(alignments[2], .right)
	}

	func testTextTablePreservesInlineMarkdownAttributesInCells() {
		let markdown = """
		| Item |
		| --- |
		| **Bold** `code` |
		"""
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14

		let rendered = compiler.attributedString(from: Document(parsing: markdown))

		XCTAssertTrue(rendered.font(containing: "Bold")?.hasTrait(.boldFontMask) ?? false)
		XCTAssertTrue(rendered.font(containing: "code")?.fontName.lowercased().contains("mono") ?? false)
	}

	@MainActor
	func testTextTableMeasurementGrowsAtNarrowWidths() {
		let markdown = """
		| Script | Location | Category | Description |
		| --- | --- | --- | --- |
		| SpatialUIInputManager.cs | Assets/Samples/PolySpatial/SpatialUI/Scripts | Input | Input routing for spatial UI elements and long descriptions that need to wrap. |
		| VeryLongFileNameThatCannotStayOnOneLine.cs | Assets/Deeply/Nested/Directory/With/Several/Segments | Gameplay | Another long cell value that forces wrapping when the transcript column gets narrow. |
		"""
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14
		let rendered = compiler.attributedString(from: Document(parsing: markdown))

		let textView = CodeBlockTextView()
		textView.textContainer?.widthTracksTextView = false
		textView.textContainer?.lineFragmentPadding = 0
		textView.textStorage?.setAttributedString(rendered)

		let wideHeight = textView.measuredHeight(constrainedTo: 640)
		let narrowHeight = textView.measuredHeight(constrainedTo: 180)

		XCTAssertGreaterThan(narrowHeight, wideHeight)
	}

	@MainActor
	func testPlainMarkdownMeasurementKeepsTwoPointSafetyAllowance() {
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14
		let rendered = compiler.attributedString(
			from: Document(parsing: "Plain paragraph with **bold** text and no tables.")
		)

		let heights = measuredAndUsedHeights(for: rendered, width: 320)

		XCTAssertEqual(heights.measured, ceil(heights.used) + 2, accuracy: 0.1)
	}

	@MainActor
	func testTextTableMeasurementUsesFourPointSafetyAllowance() {
		let markdown = """
		| Name | Notes |
		| --- | --- |
		| Alpha | Table-backed text needs enough vertical paint room for its outside edge. |
		"""
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14
		let rendered = compiler.attributedString(from: Document(parsing: markdown))

		XCTAssertFalse(rendered.textTableBlocks().isEmpty)
		let heights = measuredAndUsedHeights(for: rendered, width: 360)

		XCTAssertEqual(heights.measured, ceil(heights.used) + 4, accuracy: 0.1)
	}

	func testTextTablePreservesInlineMarkdownLinksInCells() {
		let markdown = """
		| Name | Notes |
		| --- | --- |
		| Alpha | See [docs](docs/table.md) |
		"""
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14

		let rendered = compiler.attributedString(from: Document(parsing: markdown))
		XCTAssertFalse(rendered.textTableBlocks().isEmpty)

		var rawLink: String?
		rendered.enumerateAttribute(.markdownRawLink, in: NSRange(location: 0, length: rendered.length)) { value, _, stop in
			if let value = value as? String {
				rawLink = value
				stop.pointee = true
			}
		}

		XCTAssertEqual(rawLink, "docs/table.md")
	}

	func testLargeTablesUsePlainTextFallback() {
		let body = (1...305)
			.map { "| Row \($0) | Value \($0) |" }
			.joined(separator: "\n")
		let markdown = """
		| Name | Value |
		| --- | --- |
		\(body)
		"""
		var compiler = EnhancedMarkdownCompiler()
		compiler.fontSize = 14

		let rendered = compiler.attributedString(from: Document(parsing: markdown))

		XCTAssertTrue(rendered.textTableBlocks().isEmpty)
		XCTAssertTrue(rendered.string.contains("Name  |  Value"))
		XCTAssertTrue(rendered.string.contains("Row 305  |  Value 305"))
	}

	@MainActor
	private func measuredAndUsedHeights(
		for attributedString: NSAttributedString,
		width: CGFloat
	) -> (measured: CGFloat, used: CGFloat) {
		let textView = CodeBlockTextView()
		textView.textContainer?.widthTracksTextView = false
		textView.textContainer?.lineFragmentPadding = 0
		textView.textStorage?.setAttributedString(attributedString)

		let measuredHeight = textView.measuredHeight(constrainedTo: width)
		guard let textContainer = textView.textContainer else {
			return (measuredHeight, 0)
		}
		let usedHeight = textView.layoutManager?.usedRect(for: textContainer).height ?? 0
		return (measuredHeight, usedHeight)
	}
}

private extension NSFont {
	func hasTrait(_ trait: NSFontTraitMask) -> Bool {
		NSFontManager.shared.traits(of: self).contains(trait)
	}
}

private extension NSAttributedString {
	func textTableBlocks() -> [NSTextTableBlock] {
		var blocks: [NSTextTableBlock] = []
		enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: length)) { value, _, _ in
			guard let paragraphStyle = value as? NSParagraphStyle else { return }
			blocks.append(contentsOf: paragraphStyle.textBlocks.compactMap { $0 as? NSTextTableBlock })
		}
		return blocks
	}

	func textTableColumnAlignments(forRow row: Int) -> [Int: NSTextAlignment] {
		var alignments: [Int: NSTextAlignment] = [:]
		enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: length)) { value, _, _ in
			guard let paragraphStyle = value as? NSParagraphStyle else { return }
			for case let block as NSTextTableBlock in paragraphStyle.textBlocks where block.startingRow == row {
				alignments[block.startingColumn] = paragraphStyle.alignment
			}
		}
		return alignments
	}

	func font(containing substring: String) -> NSFont? {
		let range = (string as NSString).range(of: substring)
		guard range.location != NSNotFound else { return nil }
		return attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
	}
}
