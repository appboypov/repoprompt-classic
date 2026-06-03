import XCTest
@testable import RepoPrompt

final class FileSystemServicePublishSuppressionTests: XCTestCase {
	private func createTestService() async throws -> FileSystemService {
		let testPath = "/tmp/test-publish-suppression"
		let virtualFS = InMemoryFS()
		virtualFS.addFolder(testPath)
		virtualFS.addFolder("\(testPath)/data")
		virtualFS.addFile("\(testPath)/data/model-state.txt")
		return try await FileSystemService(
			path: testPath,
			respectGitignore: true,
			skipSymlinks: true,
			testVisitedPaths: ["data/model-state.txt"],
			testVisitedItems: ["data": true, "data/model-state.txt": false],
			isTestMode: true,
			fileManagerOverride: virtualFS
		)
	}

	func testPublishSuppressionCollapsesRepeatedModifyStormForLongPaths() async throws {
		let service = try await createTestService()
		let longRelativePath = "data/" + String(repeating: "historical-series-", count: 8) + "model-state.txt"
		let rawDeltas = (0..<40).map { _ in
			FileSystemDelta.fileModified(longRelativePath, nil)
		} + [
			.fileModified("data/another-long-series-file.txt", nil)
		]

		let published = await service.coalescedPublishableDeltasForTesting(rawDeltas)

		XCTAssertLessThan(published.count, rawDeltas.count)
		XCTAssertEqual(published.count, 2)
		XCTAssertTrue(
			published.contains {
				if case .fileModified(let path, _) = $0 { return path == longRelativePath }
				return false
			}
		)
	}

	func testPublishSuppressionCollapsesFolderModifyStormAndPreservesLatestMTime() async throws {
		let service = try await createTestService()
		let olderDate = Date(timeIntervalSince1970: 100)
		let newerDate = Date(timeIntervalSince1970: 200)
		let rawDeltas: [FileSystemDelta] = [
			.folderModified("data", olderDate),
			.folderModified("data", nil),
			.folderModified("data", newerDate)
		]

		let published = await service.coalescedPublishableDeltasForTesting(rawDeltas)

		XCTAssertEqual(published, [.folderModified("data", newerDate)])
	}

	func testPublishSuppressionDropsDescendantNoiseUnderFolderRemoval() async throws {
		let service = try await createTestService()
		let removedFolder = "data/decades-of-history"
		let rawDeltas: [FileSystemDelta] = [
			.folderRemoved(removedFolder),
			.fileRemoved("\(removedFolder)/1999/archive.csv"),
			.fileModified("\(removedFolder)/2001/archive.csv", nil),
			.folderModified(removedFolder, nil),
			.folderRemoved("\(removedFolder)/nested"),
			.fileRemoved("\(removedFolder)/nested/trace.log")
		]

		let published = await service.coalescedPublishableDeltasForTesting(rawDeltas)

		XCTAssertEqual(published.count, 1)
		guard case .folderRemoved(let path) = try XCTUnwrap(published.first) else {
			return XCTFail("Expected only the parent folder removal to remain")
		}
		XCTAssertEqual(path, removedFolder)
	}

	func testPublishSuppressionPreservesFileFolderReplacementPairsAtSamePath() async throws {
		let service = try await createTestService()
		let folderToFile = await service.coalescedPublishableDeltasForTesting([
			.folderRemoved("data/model-state.txt"),
			.fileAdded("data/model-state.txt")
		])
		let fileToFolder = await service.coalescedPublishableDeltasForTesting([
			.fileRemoved("data/model-state.txt"),
			.folderAdded("data/model-state.txt")
		])

		XCTAssertEqual(folderToFile.count, 2)
		XCTAssertEqual(folderToFile[0], .folderRemoved("data/model-state.txt"))
		XCTAssertEqual(folderToFile[1], .fileAdded("data/model-state.txt"))
		XCTAssertEqual(fileToFolder.count, 2)
		XCTAssertEqual(fileToFolder[0], .fileRemoved("data/model-state.txt"))
		XCTAssertEqual(fileToFolder[1], .folderAdded("data/model-state.txt"))
	}
}
