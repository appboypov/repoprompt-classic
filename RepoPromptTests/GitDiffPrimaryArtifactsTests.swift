import XCTest
@testable import RepoPrompt

final class GitDiffPrimaryArtifactsTests: XCTestCase {
	func testPrimaryArtifactsBuildsRootQualifiedMapAndAllPatchPaths() {
		let primary = GitDiffSnapshotStore.primaryArtifacts(
			snapshotDir: "repos/repopromptweb-4747bd48/2026-03-14/1455",
			mapRelativePath: "MAP.txt",
			allPatchRelativePath: "diff/all.patch"
		)
		
		XCTAssertEqual(
			primary.map,
			"_git_data/repos/repopromptweb-4747bd48/2026-03-14/1455/MAP.txt"
		)
		XCTAssertEqual(
			primary.allPatch,
			"_git_data/repos/repopromptweb-4747bd48/2026-03-14/1455/diff/all.patch"
		)
		XCTAssertEqual(
			primary.selectionCandidates,
			[
				"_git_data/repos/repopromptweb-4747bd48/2026-03-14/1455/MAP.txt",
				"_git_data/repos/repopromptweb-4747bd48/2026-03-14/1455/diff/all.patch",
			]
		)
	}
	
	func testPrimaryArtifactsOmitsAllPatchWhenUnavailable() {
		let primary = GitDiffSnapshotStore.primaryArtifacts(
			snapshotDir: "/repos/repopromptweb-4747bd48/2026-03-14/1455/",
			mapRelativePath: "/MAP.txt",
			allPatchRelativePath: nil
		)
		
		XCTAssertEqual(
			primary.selectionCandidates,
			["_git_data/repos/repopromptweb-4747bd48/2026-03-14/1455/MAP.txt"]
		)
		XCTAssertNil(primary.allPatch)
	}

	func testPerFilePatchArtifactsBuildSelectionReadyPathsWithoutChangingSelectionCandidates() {
		let snapshotDir = "repos/repopromptweb-4747bd48/2026-03-14/1455"
		let files: [GitDiffSnapshotManifest.FileEntry] = [
			.init(gitPath: "App/C.swift", status: "M", additions: 4, deletions: 1, patchPath: "diff/per-file/App__C.swift.patch", bytes: 120, lines: 12, hunks: nil),
			.init(gitPath: "App/A.swift", status: "A", additions: 9, deletions: 0, patchPath: "diff/per-file/App__A.swift.patch", bytes: 240, lines: 20, hunks: nil),
			.init(gitPath: "App/B.swift", status: "D", additions: 0, deletions: 7, patchPath: nil, bytes: nil, lines: nil, hunks: nil),
		]

		let patches = GitDiffSnapshotStore.perFilePatchArtifacts(snapshotDir: snapshotDir, files: files)

		XCTAssertEqual(
			patches,
			[
				GitDiffPerFilePatchArtifact(
					jumpIndex: 1,
					gitPath: "App/A.swift",
					selectionPath: "_git_data/repos/repopromptweb-4747bd48/2026-03-14/1455/diff/per-file/App__A.swift.patch",
					status: "A",
					additions: 9,
					deletions: 0
				),
				GitDiffPerFilePatchArtifact(
					jumpIndex: 3,
					gitPath: "App/C.swift",
					selectionPath: "_git_data/repos/repopromptweb-4747bd48/2026-03-14/1455/diff/per-file/App__C.swift.patch",
					status: "M",
					additions: 4,
					deletions: 1
				),
			]
		)
	}
}
