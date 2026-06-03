import XCTest
@testable import RepoPrompt

final class UnifiedDiffRenderingTests: XCTestCase {
	func testEstimatedHeightUsesContentForShortDocument() {
		let document = UnifiedDiffCardRendering.parse("""
		@@ -1,2 +1,2 @@
		 old
		-new
		+new
		""")

		let fontPreset = FontScalePreset.normal
		let height = UnifiedDiffCardRendering.estimatedHeight(for: document, fontSize: 11, fontPreset: fontPreset, maxHeight: 280)
		XCTAssertGreaterThanOrEqual(height, UnifiedDiffCardRendering.appKitMinimumBodyHeight(for: fontPreset))
		XCTAssertLessThan(height, 280)
	}

	func testEstimatedHeightClampsToMaxHeightForTallDocument() {
		let document = UnifiedDiffCardRendering.parse(String(repeating: "+line\n", count: 500))

		let height = UnifiedDiffCardRendering.estimatedHeight(for: document, fontSize: 11, fontPreset: .normal, maxHeight: 220)
		XCTAssertEqual(height, 220)
	}

	func testParserHidesOnlyFirstPathHeaderPairBeforeFirstHunk() {
		let diff = """
		diff --git a/one.swift b/one.swift
		index 1111111..2222222 100644
		--- a/one.swift
		+++ b/one.swift
		@@ -1,2 +1,2 @@
		 old
		-new
		+newer
		diff --git a/two.swift b/two.swift
		index 3333333..4444444 100644
		--- a/two.swift
		+++ b/two.swift
		@@ -4,1 +4,1 @@
		-two
		+two updated
		"""

		let document = UnifiedDiffCardRendering.parse(diff)
		let texts = document.lines.map(\.text)
		XCTAssertFalse(texts.contains("--- a/one.swift"))
		XCTAssertFalse(texts.contains("+++ b/one.swift"))
		XCTAssertTrue(texts.contains("--- a/two.swift"))
		XCTAssertTrue(texts.contains("+++ b/two.swift"))
		XCTAssertFalse(texts.contains { $0.hasPrefix("@@") })
	}


	func testParserEmitsGapRowsBetweenSeparatedHunks() {
		let diff = """
		@@ -1,2 +1,2 @@
		 one
		-two
		+two updated
		@@ -10,2 +10,2 @@
		 ten
		-eleven
		+eleven updated
		"""

		let document = UnifiedDiffCardRendering.parse(diff)
		XCTAssertTrue(document.lines.contains(where: { $0.kind == .gap && $0.text == "⋯ 7 unchanged lines ⋯" }))
	}

	func testParserReturnsEquivalentDocumentWhenDiffIsParsedAgain() {
		let diff = """
		@@ -3,2 +3,3 @@
		old
		-removed
		+added
		+extra
		"""

		let first = UnifiedDiffCardRendering.parse(diff)
		let second = UnifiedDiffCardRendering.parse(diff)

		XCTAssertEqual(first, second)
		XCTAssertEqual(first.lines, second.lines)
		XCTAssertEqual(first.maxLineNumberDigits, second.maxLineNumberDigits)
	}

	func testParserTracksLineNumbersAcrossChanges() {
		let diff = """
		@@ -10,3 +10,4 @@
		 alpha
		-beta
		+beta updated
		+gamma
		 delta
		"""

		let document = UnifiedDiffCardRendering.parse(diff)
		XCTAssertEqual(document.lines[0], .init(kind: .context, text: " alpha", oldLineNumber: 10, newLineNumber: 10))
		XCTAssertEqual(document.lines[1], .init(kind: .deletion, text: "-beta", oldLineNumber: 11, newLineNumber: nil))
		XCTAssertEqual(document.lines[2], .init(kind: .addition, text: "+beta updated", oldLineNumber: nil, newLineNumber: 11))
		XCTAssertEqual(document.lines[3], .init(kind: .addition, text: "+gamma", oldLineNumber: nil, newLineNumber: 12))
		XCTAssertEqual(document.lines[4], .init(kind: .context, text: " delta", oldLineNumber: 12, newLineNumber: 13))
	}

	func testParserHandlesHunkHeadersWithoutCounts() {
		let diff = """
		@@ -12 +14 @@
		-removed
		+added
		"""

		let document = UnifiedDiffCardRendering.parse(diff)
		XCTAssertEqual(document.lines[0], .init(kind: .deletion, text: "-removed", oldLineNumber: 12, newLineNumber: nil))
		XCTAssertEqual(document.lines[1], .init(kind: .addition, text: "+added", oldLineNumber: nil, newLineNumber: 14))
	}

	func testParserHandlesTrailingHunkHeaderContext() {
		let diff = "@@ -7,2 +9,3 @@ func sample()\n alpha\n-beta\n+beta updated\n+gamma\n"

		let document = UnifiedDiffCardRendering.parse(diff)
		let texts = document.lines.map(\.text)
		XCTAssertFalse(texts.contains { $0.hasPrefix("@@") })
		XCTAssertEqual(document.lines[0], .init(kind: .context, text: " alpha", oldLineNumber: 7, newLineNumber: 9))
		XCTAssertEqual(document.lines[1], .init(kind: .deletion, text: "-beta", oldLineNumber: 8, newLineNumber: nil))
		XCTAssertEqual(document.lines[2], .init(kind: .addition, text: "+beta updated", oldLineNumber: nil, newLineNumber: 10))
		XCTAssertEqual(document.lines[3], .init(kind: .addition, text: "+gamma", oldLineNumber: nil, newLineNumber: 11))
	}

	func testParserHandlesZeroCountCreateHunkHeaders() {
		let diff = """
		@@ -0,0 +1,3 @@
		+one
		+two
		+three
		"""

		let document = UnifiedDiffCardRendering.parse(diff)
		XCTAssertEqual(document.lines[0], .init(kind: .addition, text: "+one", oldLineNumber: nil, newLineNumber: 1))
		XCTAssertEqual(document.lines[1], .init(kind: .addition, text: "+two", oldLineNumber: nil, newLineNumber: 2))
		XCTAssertEqual(document.lines[2], .init(kind: .addition, text: "+three", oldLineNumber: nil, newLineNumber: 3))
	}

	func testParserLeavesMalformedHunkHeadersUnnumbered() {
		let diff = "@@ malformed header @@\n+one\n"

		let document = UnifiedDiffCardRendering.parse(diff)
		XCTAssertEqual(document.lines[0], .init(kind: .fileHeader, text: "@@ malformed header @@", oldLineNumber: nil, newLineNumber: nil))
		XCTAssertEqual(document.lines[1], .init(kind: .addition, text: "+one", oldLineNumber: nil, newLineNumber: nil))
	}

	func testApplyEditsLineStatsCountsAddedAndDeletedLines() {
		let result = ApplyEditsResult(
			updatedText: "updated",
			diffChunks: [
				DiffChunk(
					lines: [
						DiffLine(content: " unchanged"),
						DiffLine(content: "+added one"),
						DiffLine(content: "-removed one"),
						DiffLine(content: "+added two")
					],
					startLine: 1
				)
			],
			unifiedDiff: nil,
			toolCardUnifiedDiff: nil,
			stats: nil,
			note: nil,
			fileCreated: false,
			fileOverwritten: false,
			editsRequested: 1,
			editsApplied: 1,
			status: .success,
			outcomes: nil
		)

		XCTAssertEqual(result.toolCardLineStats(), ApplyEditsLineStats(addedLines: 2, deletedLines: 1))
	}

	func testApplyEditsLineStatsReturnsNilWithoutDiffChunks() {
		let result = ApplyEditsResult(
			updatedText: "updated",
			diffChunks: [],
			unifiedDiff: nil,
			toolCardUnifiedDiff: nil,
			stats: nil,
			note: nil,
			fileCreated: false,
			fileOverwritten: false,
			editsRequested: 1,
			editsApplied: 1,
			status: .success,
			outcomes: nil
		)

		XCTAssertNil(result.toolCardLineStats())
	}

	func testEditSummaryDecodesWhenAddedLineFieldsAreMissing() throws {
		let json = """
		{
		  "status": "success",
		  "edits_requested": 1,
		  "edits_applied": 1,
		  "note": "ok"
		}
		"""
		let data = try XCTUnwrap(json.data(using: .utf8))
		let dto = try JSONDecoder().decode(ToolResultDTOs.EditSummary.self, from: data)
		XCTAssertNil(dto.addedLines)
		XCTAssertNil(dto.deletedLines)
		XCTAssertEqual(dto.status, "success")
	}
}
