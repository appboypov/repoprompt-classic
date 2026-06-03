import XCTest
@testable import RepoPrompt

final class ToolOutputFormatterSearchTests: XCTestCase {
	func testSearchResultsSummaryShowsMatchingAndSearchedFiles() {
		let dto = ToolResultDTOs.SearchResultDTO(
			totalMatches: 0,
			totalFiles: 0,
			matchedFiles: 0,
			searchedFiles: 137,
			contentMatches: 0,
			pathMatches: 0,
			limitHit: false,
			perFileCounts: [],
			pathMatchLines: [],
			contentMatchGroups: []
		)

		let output = ToolOutputFormatter.searchResults(dto: dto)

		XCTAssertTrue(output.contains("- **Total matches**: 0 across 0 matching files (searched 137 files)"))
	}

	func testSearchResultsSummaryUsesMatchedFilesForPathOnlyResults() {
		let dto = ToolResultDTOs.SearchResultDTO(
			totalMatches: 2,
			totalFiles: 0,
			matchedFiles: 2,
			searchedFiles: 5,
			contentMatches: 0,
			pathMatches: 2,
			limitHit: false,
			perFileCounts: [],
			pathMatchLines: ["Root/Sources/A.swift", "Root/Sources/B.swift"],
			contentMatchGroups: []
		)

		let output = ToolOutputFormatter.searchResults(dto: dto)

		XCTAssertTrue(output.contains("- **Total matches**: 2 across 2 matching files (searched 5 files)"))
		XCTAssertFalse(output.contains("across 0 files"))
	}

	func testSearchResultsTopFilesSummaryUsesFullPathForDuplicateBasenames() {
		let perFileTotals: [ToolResultDTOs.PerFileCount] = [
			ToolResultDTOs.PerFileCount(path: "Root/one.swift", count: 10),
			ToolResultDTOs.PerFileCount(path: "Other/one.swift", count: 9),
			ToolResultDTOs.PerFileCount(path: "Root/two.swift", count: 8),
			ToolResultDTOs.PerFileCount(path: "Root/three.swift", count: 7)
		]
		let dto = ToolResultDTOs.SearchResultDTO(
			totalMatches: 34,
			totalFiles: 4,
			contentMatches: 34,
			pathMatches: 0,
			limitHit: false,
			perFileCounts: perFileTotals,
			pathMatchLines: [],
			contentMatchGroups: [],
			perFileTotals: perFileTotals
		)

		let output = ToolOutputFormatter.searchResults(dto: dto)
		let lines = output.split(separator: "\n").map(String.init)
		let topLine = lines.first { $0.hasPrefix("- **Top files**:") }

		XCTAssertNotNil(topLine)
		XCTAssertEqual(
			topLine,
			"- **Top files**: Root/one.swift (10), Other/one.swift (9), two.swift (8) (+1 more)"
		)
	}

	func testSearchResultsIncludesWarningText() {
		let dto = ToolResultDTOs.SearchResultDTO(
			totalMatches: 1,
			totalFiles: 1,
			contentMatches: 1,
			pathMatches: 0,
			limitHit: false,
			perFileCounts: [ToolResultDTOs.PerFileCount(path: "Root/file.swift", count: 1)],
			pathMatchLines: [],
			contentMatchGroups: [],
			warning: "The content-search pattern was auto-corrected before running."
		)

		let output = ToolOutputFormatter.searchResults(dto: dto)

		XCTAssertTrue(output.contains("- **Warning**: The content-search pattern was auto-corrected before running."))
	}

	func testSearchResultsInsertsGapMarkerForNonContiguousLines() {
		let line10 = ToolResultDTOs.SearchResultDTO.ContentMatchGroup.Line(
			lineNumber: 10,
			lineText: "let value = 1",
			contextBefore: nil,
			contextAfter: nil
		)
		let line12 = ToolResultDTOs.SearchResultDTO.ContentMatchGroup.Line(
			lineNumber: 12,
			lineText: "let other = 2",
			contextBefore: nil,
			contextAfter: nil
		)
		let group = ToolResultDTOs.SearchResultDTO.ContentMatchGroup(
			path: "Root/file.swift",
			lines: [line10, line12]
		)
		let perFileCounts = [ToolResultDTOs.PerFileCount(path: "Root/file.swift", count: 2)]
		let dto = ToolResultDTOs.SearchResultDTO(
			totalMatches: 2,
			totalFiles: 1,
			contentMatches: 2,
			pathMatches: 0,
			limitHit: false,
			perFileCounts: perFileCounts,
			pathMatchLines: [],
			contentMatchGroups: [group],
			perFileTotals: perFileCounts
		)

		let output = ToolOutputFormatter.searchResults(dto: dto)

		XCTAssertTrue(output.contains("│   ⋮"))
	}

	func testSearchResultsCompactsUnaryFolderChainForSingleFileHit() {
		let path = "RepoPrompt/Services/MCP/Debug/MCPConnectionManager+DebugDiagnostics.swift"
		let perFileCounts = [ToolResultDTOs.PerFileCount(path: path, count: 6)]
		let dto = ToolResultDTOs.SearchResultDTO(
			totalMatches: 6,
			totalFiles: 1,
			contentMatches: 6,
			pathMatches: 0,
			limitHit: false,
			perFileCounts: perFileCounts,
			pathMatchLines: [],
			contentMatchGroups: [],
			perFileTotals: perFileCounts
		)

		let output = ToolOutputFormatter.searchResults(dto: dto)

		XCTAssertTrue(output.contains("RepoPrompt/"))
		XCTAssertTrue(output.contains("└── Services/MCP/Debug/MCPConnectionManager+DebugDiagnostics.swift — 6 matches (showing all)"))
		XCTAssertFalse(output.contains("└── Services/\n    └── MCP/"))
	}

	func testSearchResultsPreservesSiblingTreeWhileCompactingNestedUnaryChain() {
		let perFileCounts = [
			ToolResultDTOs.PerFileCount(path: "Root/Sources/A.swift", count: 1),
			ToolResultDTOs.PerFileCount(path: "Root/Sources/Nested/Deep/B.swift", count: 2),
			ToolResultDTOs.PerFileCount(path: "Root/Tests/C.swift", count: 1)
		]
		let dto = ToolResultDTOs.SearchResultDTO(
			totalMatches: 4,
			totalFiles: 3,
			contentMatches: 4,
			pathMatches: 0,
			limitHit: false,
			perFileCounts: perFileCounts,
			pathMatchLines: [],
			contentMatchGroups: [],
			perFileTotals: perFileCounts
		)

		let output = ToolOutputFormatter.searchResults(dto: dto)

		XCTAssertTrue(output.contains("├── Sources/"))
		XCTAssertTrue(output.contains("│   ├── Nested/Deep/B.swift — 2 matches (showing all)"))
		XCTAssertTrue(output.contains("│   └── A.swift — 1 match (showing all)"))
		XCTAssertTrue(output.contains("└── Tests/C.swift — 1 match (showing all)"))
		XCTAssertFalse(output.contains("Nested/\n│   │   └── Deep/"))
	}

	func testSearchResultsDoesNotCompactThroughPathMatchedFolder() {
		let path = "Root/A/B/File.swift"
		let perFileCounts = [ToolResultDTOs.PerFileCount(path: path, count: 1)]
		let dto = ToolResultDTOs.SearchResultDTO(
			totalMatches: 2,
			totalFiles: 1,
			contentMatches: 1,
			pathMatches: 1,
			limitHit: false,
			perFileCounts: perFileCounts,
			pathMatchLines: ["Root/A/B"],
			contentMatchGroups: [],
			perFileTotals: perFileCounts
		)

		let output = ToolOutputFormatter.searchResults(dto: dto)

		XCTAssertTrue(output.contains("└── A/"))
		XCTAssertTrue(output.contains("    └── B/ • path match"))
		XCTAssertTrue(output.contains("        └── File.swift — 1 match (showing all)"))
		XCTAssertFalse(output.contains("A/B/File.swift — 1 match"))
	}
}
