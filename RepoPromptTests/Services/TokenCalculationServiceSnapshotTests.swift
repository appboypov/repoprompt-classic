import XCTest
@testable import RepoPrompt

final class TokenCalculationServiceSnapshotTests: XCTestCase {
	func testCalculatePromptStatsUsesSnapshotContentAndPreRenderedTree() async {
		let service = TokenCalculationService()
		let fullContent = "alpha\nbeta\n"
		let slicedContent = "one\ntwo\nthree\nfour\n"
		let sliceAssembly = FileViewModel.buildSliceAssembly(
			from: slicedContent,
			ranges: [LineRange(start: 2, end: 3)]
		)
		let expectedFullTokens = TokenCalculationService.estimateTokens(for: fullContent)
		let expectedSliceTokens = TokenCalculationService.estimateTokens(for: sliceAssembly.combinedText)
		let expectedFileTokens = expectedFullTokens + expectedSliceTokens
		let snapshot = TokenCalculationSnapshot(
			promptText: "prompt",
			selectedInstructionsText: "instructions",
			includeDiffFormatting: true,
			xmlFormattingPrompt: "<xml>format</xml>",
			duplicateUserInstructionsAtTop: true,
			promptEntries: [
				PromptFileEntrySnapshot(
					fileID: UUID(),
					relativePath: "Sources/A.swift",
					isCodemapRequested: false,
					ranges: nil,
					cachedFullTokenCount: nil,
					loadedContent: fullContent,
					codeMapContent: nil,
					availableCodeMapTokenCount: 0
				),
				PromptFileEntrySnapshot(
					fileID: UUID(),
					relativePath: "Sources/B.swift",
					isCodemapRequested: false,
					ranges: [LineRange(start: 2, end: 3)],
					cachedFullTokenCount: nil,
					loadedContent: slicedContent,
					codeMapContent: nil,
					availableCodeMapTokenCount: 0
				),
				PromptFileEntrySnapshot(
					fileID: UUID(),
					relativePath: "Sources/C.swift",
					isCodemapRequested: true,
					ranges: nil,
					cachedFullTokenCount: nil,
					loadedContent: nil,
					codeMapContent: "func helper()",
					availableCodeMapTokenCount: 11
				)
			],
			fileTree: .rendered("Sources\n└── A.swift")
		)

		let result = await service.calculatePromptStats(snapshot: snapshot)

		XCTAssertEqual(result.totalTokenCountFilesOnly, expectedFileTokens)
		XCTAssertEqual(result.codeMapFileCount, 1)
		XCTAssertEqual(result.codeMapTokenCount, 11)
		XCTAssertEqual(result.fileTreeContent, "Sources\n└── A.swift")
		XCTAssertEqual(result.fileTreeTokenCountRaw, TokenCalculationService.estimateTokens(for: "Sources\n└── A.swift"))
		XCTAssertTrue(result.totalTokenCount > result.totalTokenCountFilesOnly)
	}

	func testCalculatePromptStatsRendersFileTreeFromSnapshot() async {
		let service = TokenCalculationService()
		let treeSnapshot = FileTreeSelectionSnapshot(
			roots: [
				FileTreeFolderSnapshot(
					id: UUID(),
					name: "RepoPrompt",
					nameSortKey: "repoprompt",
					fullPath: "/tmp/RepoPrompt",
					standardizedFullPath: "/tmp/RepoPrompt",
					standardizedRootPath: "/tmp/RepoPrompt",
					children: [
						.folder(
							FileTreeFolderSnapshot(
								id: UUID(),
								name: "Sources",
								nameSortKey: "sources",
								fullPath: "/tmp/RepoPrompt/Sources",
								standardizedFullPath: "/tmp/RepoPrompt/Sources",
								standardizedRootPath: "/tmp/RepoPrompt",
								children: [
									.file(
										FileTreeFileSnapshot(
											id: UUID(),
											name: "A.swift",
											nameSortKey: "a.swift",
											fileExtension: "swift",
											hasCodeMap: true
										)
									)
								]
							)
						)
					]
				)
			],
			selectedFileIDs: [],
			mode: "full",
			showFullPaths: false,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: true
		)
		let snapshot = TokenCalculationSnapshot(
			promptText: "",
			selectedInstructionsText: "",
			includeDiffFormatting: false,
			xmlFormattingPrompt: "",
			duplicateUserInstructionsAtTop: false,
			promptEntries: [],
			fileTree: .snapshot(treeSnapshot)
		)

		let result = await service.calculatePromptStats(snapshot: snapshot)

		XCTAssertEqual(
			result.fileTreeContent.trimmingCharacters(in: .newlines),
			"RepoPrompt\n└── Sources\n    └── A.swift +\n\n\n(+ denotes code-map available)"
		)
		XCTAssertGreaterThan(result.fileTreeTokenCountRaw, 0)
	}

	func testCalculatePromptStatsSkipsNoneFileTreeSnapshot() async {
		let service = TokenCalculationService()
		let treeSnapshot = FileTreeSelectionSnapshot(
			roots: [
				FileTreeFolderSnapshot(
					id: UUID(),
					name: "RepoPrompt",
					nameSortKey: "repoprompt",
					fullPath: "/tmp/RepoPrompt",
					standardizedFullPath: "/tmp/RepoPrompt",
					standardizedRootPath: "/tmp/RepoPrompt",
					children: [
						.file(
							FileTreeFileSnapshot(
								id: UUID(),
								name: "A.swift",
								nameSortKey: "a.swift",
								fileExtension: "swift",
								hasCodeMap: true
							)
						)
					]
				)
			],
			selectedFileIDs: [],
			mode: "none",
			showFullPaths: false,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: true
		)
		let snapshot = TokenCalculationSnapshot(
			promptText: "",
			selectedInstructionsText: "",
			includeDiffFormatting: false,
			xmlFormattingPrompt: "",
			duplicateUserInstructionsAtTop: false,
			promptEntries: [],
			fileTree: .snapshot(treeSnapshot)
		)

		let result = await service.calculatePromptStats(snapshot: snapshot)

		XCTAssertEqual(result.fileTreeContent, "")
		XCTAssertEqual(result.fileTreeTokenCountRaw, 0)
	}

	func testEvaluatePromptEntriesKeepsUnresolvedCodemapOutOfRenderedCodemapBlock() async {
		let service = TokenCalculationService()
		let snapshots = [
			PromptFileEntrySnapshot(
				fileID: UUID(),
				relativePath: "Sources/Missing.swift",
				isCodemapRequested: true,
				ranges: nil,
				cachedFullTokenCount: 42,
				loadedContent: nil,
				codeMapContent: nil,
				availableCodeMapTokenCount: 0
			)
		]

		let evaluation = await service.evaluatePromptEntries(snapshots)

		XCTAssertEqual(evaluation.codeMapFileCount, 0)
		XCTAssertEqual(evaluation.codeMapTokenCount, 0)
		XCTAssertTrue(evaluation.codeMapContent.isEmpty)
		XCTAssertEqual(evaluation.codemapCount, 1)
	}
}
