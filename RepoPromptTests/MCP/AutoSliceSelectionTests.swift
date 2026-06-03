import XCTest
@testable import RepoPrompt

final class AutoSliceSelectionTests: XCTestCase {
	func testShouldApplyRequiresAgentModeAndVirtualContext() {
		XCTAssertTrue(AutoSliceSelection.shouldApply(purpose: .agentModeRun, hasVirtualContext: true))
		XCTAssertFalse(AutoSliceSelection.shouldApply(purpose: .agentModeRun, hasVirtualContext: false))
		XCTAssertFalse(AutoSliceSelection.shouldApply(purpose: .discoverRun, hasVirtualContext: true))
	}

	func testReadFileSelectionReturnsNilForEmptyOrInvalidRanges() {
		let empty = ToolResultDTOs.ReadFileReply(
			content: "",
			totalLines: 0,
			firstLine: 0,
			lastLine: 0,
			message: nil,
			displayPath: "RepoPrompt/file.swift"
		)
		XCTAssertNil(AutoSliceSelection.readFileSelection(from: empty))

		let beyondEOF = ToolResultDTOs.ReadFileReply(
			content: "",
			totalLines: 3,
			firstLine: 10,
			lastLine: 3,
			message: "Requested start_line exceeds file length.",
			displayPath: "RepoPrompt/file.swift"
		)
		XCTAssertNil(AutoSliceSelection.readFileSelection(from: beyondEOF))
	}

	func testReadFileSelectionReturnsSliceForPartialRead() {
		let reply = ToolResultDTOs.ReadFileReply(
			content: "line10\nline11\n",
			totalLines: 20,
			firstLine: 10,
			lastLine: 11,
			message: nil,
			displayPath: "RepoPrompt/Sources/File.swift"
		)

		let selection = AutoSliceSelection.readFileSelection(from: reply)
		XCTAssertEqual(
			selection,
			.slice(
				AutoSliceSelection.SliceEntry(
					path: "RepoPrompt/Sources/File.swift",
					ranges: [LineRange(start: 10, end: 11)]
				)
			)
		)
	}

	func testReadFileSelectionFallsBackToRequestedPathWhenDisplayPathMissing() {
		let reply = ToolResultDTOs.ReadFileReply(
			content: "line2\n",
			totalLines: 3,
			firstLine: 2,
			lastLine: 2,
			message: nil,
			displayPath: nil
		)

		let selection = AutoSliceSelection.readFileSelection(from: reply, fallbackPath: "RepoPrompt/File.swift")
		XCTAssertEqual(
			selection,
			.slice(
				AutoSliceSelection.SliceEntry(
					path: "RepoPrompt/File.swift",
					ranges: [LineRange(start: 2, end: 2)]
				)
			)
		)
	}

	func testReadFileSelectionReturnsFullForWholeFileRead() {
		let reply = ToolResultDTOs.ReadFileReply(
			content: "line1\nline2\n",
			totalLines: 2,
			firstLine: 1,
			lastLine: 2,
			message: nil,
			displayPath: "RepoPrompt/Sources/File.swift"
		)

		let selection = AutoSliceSelection.readFileSelection(from: reply)
		XCTAssertEqual(selection, .full(path: "RepoPrompt/Sources/File.swift"))
	}

	func testPreserveExistingFullFileSelectionPromotesMatchingSliceBackToFull() {
		let selection = AutoSliceSelection.ReadFileSelection.slice(
			AutoSliceSelection.SliceEntry(
				path: "RepoPrompt/Sources/File.swift",
				ranges: [LineRange(start: 10, end: 11)]
			)
		)

		let preserved = AutoSliceSelection.preserveExistingFullFileSelection(
			selection,
			existingFullPaths: [" RepoPrompt/Sources/File.swift "]
		)

		XCTAssertEqual(preserved, .full(path: "RepoPrompt/Sources/File.swift"))
	}

	func testPreserveExistingFullFileSelectionLeavesNonMatchingSliceUntouched() {
		let selection = AutoSliceSelection.ReadFileSelection.slice(
			AutoSliceSelection.SliceEntry(
				path: "RepoPrompt/Sources/File.swift",
				ranges: [LineRange(start: 10, end: 11)]
			)
		)

		let preserved = AutoSliceSelection.preserveExistingFullFileSelection(
			selection,
			existingFullPaths: ["RepoPrompt/Sources/Other.swift"]
		)

		XCTAssertEqual(preserved, selection)
	}

	func testReadFileSelectionSkipsAgentsInstructionsFiles() {
		let reply = ToolResultDTOs.ReadFileReply(
			content: "# instructions\n",
			totalLines: 1,
			firstLine: 1,
			lastLine: 1,
			message: nil,
			displayPath: "RepoPrompt/Docs/AGENTS.md"
		)

		XCTAssertNil(AutoSliceSelection.readFileSelection(from: reply))
	}

	func testShouldSliceFileSearchIsStrictContentModeAndContextAboveOne() {
		XCTAssertFalse(AutoSliceSelection.shouldSliceFileSearch(mode: .content, contextLines: 1))
		XCTAssertTrue(AutoSliceSelection.shouldSliceFileSearch(mode: .content, contextLines: 2))
		XCTAssertFalse(AutoSliceSelection.shouldSliceFileSearch(mode: .path, contextLines: 2))
		XCTAssertFalse(AutoSliceSelection.shouldSliceFileSearch(mode: .both, contextLines: 2))
		XCTAssertFalse(AutoSliceSelection.shouldSliceFileSearch(mode: .auto, contextLines: 2))
	}

	func testSearchEntriesDerivesRangeIncludingContextAndCoalesces() {
		let group = ToolResultDTOs.SearchResultDTO.ContentMatchGroup(
			path: "RepoPrompt/Foo.swift",
			lines: [
				makeLine(line: 10, before: [9], after: [11]),
				makeLine(line: 12, before: [11], after: [13])
			]
		)

		let entries = AutoSliceSelection.searchEntries(from: [group])
		XCTAssertEqual(entries.count, 1)
		XCTAssertEqual(entries[0].path, "RepoPrompt/Foo.swift")
		XCTAssertEqual(entries[0].ranges, [LineRange(start: 9, end: 13)])
	}

	func testSearchEntriesReturnsPerFileEntriesInInputOrder() {
		let groupB = ToolResultDTOs.SearchResultDTO.ContentMatchGroup(
			path: "RepoPrompt/B.swift",
			lines: [makeLine(line: 20, before: [], after: [])]
		)
		let groupA = ToolResultDTOs.SearchResultDTO.ContentMatchGroup(
			path: "RepoPrompt/A.swift",
			lines: [makeLine(line: 5, before: [4], after: [6])]
		)

		let entries = AutoSliceSelection.searchEntries(from: [groupB, groupA])
		XCTAssertEqual(entries.map(\.path), ["RepoPrompt/B.swift", "RepoPrompt/A.swift"])
		XCTAssertEqual(entries[0].ranges, [LineRange(start: 20, end: 20)])
		XCTAssertEqual(entries[1].ranges, [LineRange(start: 4, end: 6)])
	}

	private func makeLine(
		line: Int,
		before: [Int],
		after: [Int]
	) -> ToolResultDTOs.SearchResultDTO.ContentMatchGroup.Line {
		let beforeDTO: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine]? = before.isEmpty
			? nil
			: before.map { ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine(lineNumber: $0, lineText: "before\($0)") }
		let afterDTO: [ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine]? = after.isEmpty
			? nil
			: after.map { ToolResultDTOs.SearchResultDTO.ContentMatchGroup.ContextLine(lineNumber: $0, lineText: "after\($0)") }

		return ToolResultDTOs.SearchResultDTO.ContentMatchGroup.Line(
			lineNumber: line,
			lineText: "match\(line)",
			contextBefore: beforeDTO,
			contextAfter: afterDTO
		)
	}
}
