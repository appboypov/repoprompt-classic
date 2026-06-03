import XCTest
import MCP
@testable import RepoPrompt

final class ToolOutputFormatterGitDiffTests: XCTestCase {
	func testSingleRepoGitDiffShowsSelectionReadyPerFilePatchPreview() throws {
		let dto = ToolResultDTOs.GitToolReplyDTO(
			op: "diff",
			diff: .init(
				compare: "uncommitted",
				detail: nil,
				files: nil,
				totals: .init(files: 1, insertions: 69, deletions: 9),
				byStatus: nil,
				oneliner: "1 file (+69 -9)",
				truncated: nil,
				truncationNote: nil
			),
			snapshotId: "2026-03-14/1455",
			snapshotDir: "repos/repoprompt-c43a6e35/2026-03-14/1455",
			artifacts: .init(
				manifest: "manifest.json",
				map: "MAP.txt",
				filesTsv: "index/files.tsv",
				changedLines: nil,
				tree: "index/files.tree.txt",
				selectionPaths: nil,
				allPatch: "diff/all.patch",
				deepHunks: nil,
				deepChangedLines: nil
			),
			primaryArtifacts: .init(
				map: "_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/MAP.txt",
				allPatch: "_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/diff/all.patch",
				autoSelected: ["_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/MAP.txt"],
				perFilePatches: [
					.init(
						jumpIndex: 3,
						gitPath: "RepoPrompt/ViewModels/AgentModeViewModel.swift",
						selectionPath: "_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/diff/per-file/RepoPrompt__ViewModels__AgentModeViewModel.swift.patch",
						status: "M",
						additions: 69,
						deletions: 9
					)
				]
			)
		)

		let output = try renderGitMarkdown(dto)

		XCTAssertTrue(output.contains("RepoPrompt/ViewModels/AgentModeViewModel.swift"))
		XCTAssertTrue(output.contains("_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/diff/per-file/RepoPrompt__ViewModels__AgentModeViewModel.swift.patch"))
		XCTAssertTrue(output.contains("selection-ready paths"))
		XCTAssertTrue(output.contains("not auto-selected"))
	}

	func testSingleRepoGitDiffCapsPerFilePatchPreviewAndReferencesMapSection() throws {
		let patches = (1...12).map { index in
			ToolResultDTOs.GitToolReplyDTO.PrimaryArtifactsDTO.PerFilePatchDTO(
				jumpIndex: index,
				gitPath: "Sources/File\(index).swift",
				selectionPath: "_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/diff/per-file/Sources__File\(index).swift.patch",
				status: "M",
				additions: index,
				deletions: 0
			)
		}
		let dto = ToolResultDTOs.GitToolReplyDTO(
			op: "diff",
			diff: .init(
				compare: "uncommitted",
				detail: nil,
				files: nil,
				totals: .init(files: 12, insertions: 78, deletions: 0),
				byStatus: nil,
				oneliner: "12 files (+78 -0)",
				truncated: nil,
				truncationNote: nil
			),
			snapshotId: "2026-03-14/1455",
			snapshotDir: "repos/repoprompt-c43a6e35/2026-03-14/1455",
			artifacts: .init(
				manifest: "manifest.json",
				map: "MAP.txt",
				filesTsv: "index/files.tsv",
				changedLines: nil,
				tree: "index/files.tree.txt",
				selectionPaths: nil,
				allPatch: "diff/all.patch",
				deepHunks: nil,
				deepChangedLines: nil
			),
			primaryArtifacts: .init(
				map: "_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/MAP.txt",
				allPatch: "_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/diff/all.patch",
				autoSelected: nil,
				perFilePatches: patches
			)
		)

		let output = try renderGitMarkdown(dto)

		XCTAssertTrue(output.contains("Sources/File10.swift"))
		XCTAssertFalse(output.contains("Sources/File11.swift"))
		XCTAssertFalse(output.contains("Sources/File12.swift"))
		XCTAssertTrue(output.contains("...and 2 more in `MAP.txt` under `SECTION: PER_FILE_PATCH_SELECTION_PATHS`"))
	}

	func testMultiRepoGitDiffShowsPerRepoPerFilePatchPreview() throws {
		let dto = ToolResultDTOs.GitToolReplyDTO(
			op: "diff",
			repos: [
				.init(
					repoRoot: "/tmp/RepoPrompt",
					repoKey: "repoprompt-c43a6e35",
					repoName: "RepoPrompt",
					diff: .init(
						compare: "uncommitted",
						detail: nil,
						files: nil,
						totals: .init(files: 1, insertions: 5, deletions: 1),
						byStatus: nil,
						oneliner: "1 file (+5 -1)",
						truncated: nil,
						truncationNote: nil
					),
					snapshotId: "2026-03-14/1455",
					snapshotDir: "repos/repoprompt-c43a6e35/2026-03-14/1455",
					artifacts: .init(
						manifest: "manifest.json",
						map: "MAP.txt",
						filesTsv: "index/files.tsv",
						changedLines: nil,
						tree: "index/files.tree.txt",
						selectionPaths: nil,
						allPatch: nil,
						deepHunks: nil,
						deepChangedLines: nil
					),
					primaryArtifacts: .init(
						map: "_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/MAP.txt",
						allPatch: nil,
						autoSelected: nil,
						perFilePatches: [
							.init(
								jumpIndex: 1,
								gitPath: "RepoPrompt/Services/GitDiff/GitDiffSnapshotStore.swift",
								selectionPath: "_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/diff/per-file/RepoPrompt__Services__GitDiff__GitDiffSnapshotStore.swift.patch",
								status: "M",
								additions: 5,
								deletions: 1
							)
						]
					)
				)
			],
			aggregate: .init(
				totals: .init(files: 1, insertions: 5, deletions: 1),
				byStatus: nil,
				oneliner: "1 repo: 1 file (+5 -1)",
				repoCount: 1
			)
		)

		let output = try renderGitMarkdown(dto)

		XCTAssertTrue(output.contains("RepoPrompt/Services/GitDiff/GitDiffSnapshotStore.swift"))
		XCTAssertTrue(output.contains("_git_data/repos/repoprompt-c43a6e35/2026-03-14/1455/diff/per-file/RepoPrompt__Services__GitDiff__GitDiffSnapshotStore.swift.patch"))
	}

	private func renderGitMarkdown(_ dto: ToolResultDTOs.GitToolReplyDTO) throws -> String {
		let data = try JSONEncoder().encode(dto)
		guard let json = String(data: data, encoding: .utf8),
			let value = Value.fromJSONString(json) else {
			XCTFail("Unable to build MCP Value from GitToolReplyDTO")
			return ""
		}
		let blocks = ToolOutputFormatter.formatGit(args: [:], value: value, emitResources: false)
		return blocks.compactMap { block in
			if case .text(let text, _, _) = block {
				return text
			}
			return nil
		}.joined(separator: "\n\n")
	}
}
