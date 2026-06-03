import AppKit
import XCTest
@testable import RepoPrompt

@MainActor
final class UnifiedDiffTextViewBuilderTests: XCTestCase {
	func testBuilderProducesExpectedDisplayString() {
		let document = UnifiedDiffDocument(
			lines: [
				.init(kind: .fileHeader, text: "diff --git a/file.swift b/file.swift", oldLineNumber: nil, newLineNumber: nil),
				.init(kind: .context, text: " alpha", oldLineNumber: 7, newLineNumber: 9),
				.init(kind: .deletion, text: "-beta", oldLineNumber: 8, newLineNumber: nil),
				.init(kind: .addition, text: "+beta updated", oldLineNumber: nil, newLineNumber: 10)
			],
			maxLineNumberDigits: 2,
			renderID: 1
		)

		let attributed = UnifiedDiffAttributedStringBuilder(
			document: document,
			font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
			colorScheme: .dark,
			lineSpacing: UnifiedDiffCardRendering.appKitLineSpacing(for: .normal)
		).build()

		XCTAssertEqual(
			attributed.string,
			"       diff --git a/file.swift b/file.swift\n 7  9   alpha\n 8     -beta\n   10  +beta updated"
		)
	}

	func testBuilderPadsLineNumbersWithoutStringFormatting() {
		let document = UnifiedDiffDocument(
			lines: [
				.init(kind: .addition, text: "+line", oldLineNumber: nil, newLineNumber: 123),
				.init(kind: .deletion, text: "-other", oldLineNumber: 45, newLineNumber: nil)
			],
			maxLineNumberDigits: 3,
			renderID: 2
		)

		let attributed = UnifiedDiffAttributedStringBuilder(
			document: document,
			font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
			colorScheme: .light,
			lineSpacing: UnifiedDiffCardRendering.appKitLineSpacing(for: .normal)
		).build()

		XCTAssertEqual(attributed.string, "    123  +line\n 45      -other")
	}

	func testBuilderPreservesBackgroundAttributesForChangedLinesOnly() {
		let document = UnifiedDiffDocument(
			lines: [
				.init(kind: .context, text: " alpha", oldLineNumber: 1, newLineNumber: 1),
				.init(kind: .addition, text: "+beta", oldLineNumber: nil, newLineNumber: 2)
			],
			maxLineNumberDigits: 1,
			renderID: 3
		)

		let attributed = UnifiedDiffAttributedStringBuilder(
			document: document,
			font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
			colorScheme: .dark,
			lineSpacing: UnifiedDiffCardRendering.appKitLineSpacing(for: .normal)
		).build()
		let rendered = attributed.string as NSString
		let contextRange = rendered.range(of: " alpha")
		let additionRange = rendered.range(of: "+beta")

		XCTAssertNotEqual(contextRange.location, NSNotFound)
		XCTAssertNotEqual(additionRange.location, NSNotFound)
		XCTAssertNil(attributed.attribute(.unifiedDiffLineBackgroundColor, at: contextRange.location, effectiveRange: nil))
		XCTAssertNotNil(attributed.attribute(.unifiedDiffLineBackgroundColor, at: additionRange.location, effectiveRange: nil))
	}
}
