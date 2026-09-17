import XCTest
@testable import RepoPrompt

final class WorkspaceRowModelTests: XCTestCase {
	func testInitialsFromFirstTwoWords() {
		XCTAssertEqual(WorkspaceRowModel.initials(for: "repo prompt classic"), "RP")
		XCTAssertEqual(WorkspaceRowModel.initials(for: "Solo"), "S")
		XCTAssertEqual(WorkspaceRowModel.initials(for: "  spaced   out "), "SO")
		XCTAssertEqual(WorkspaceRowModel.initials(for: ""), "")
	}

	func testRowModelMapsSummaryFlags() {
		let summary = MCPWorkspaceSummary(
			id: UUID(),
			name: "Das HQ",
			allRepoPaths: ["/a", "/b"],
			showingWindowIDs: [],
			isVisible: true,
			isAvailable: false,
			hasRunningAgents: true
		)

		let row = WorkspaceRowModel(summary: summary)

		XCTAssertEqual(row.id, summary.id)
		XCTAssertEqual(row.rootCount, 2)
		XCTAssertTrue(row.isVisible)
		XCTAssertFalse(row.isAvailable)
		XCTAssertTrue(row.hasRunningAgents)
		XCTAssertEqual(row.initials, "DH")
	}
}
