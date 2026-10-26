import XCTest
@testable import RepoPrompt

@MainActor
final class RootFolderIndexTests: XCTestCase {
	func testFolderCountsFilesAtAnyDepthAndDropsARemovedSubtree() {
		let index = RootFolderIndex(rootPath: "/repo")
		index.addFile("a/b/c.swift")
		index.addFile("a/d.swift")
		index.addFile("e.swift")

		XCTAssertEqual(index.folders[""]?.fileCount, 3)
		XCTAssertEqual(index.folders["a"]?.fileCount, 2)
		XCTAssertEqual(index.folders["a/b"]?.fileCount, 1)

		index.remove("a/b")

		XCTAssertEqual(index.filePaths, ["a/d.swift", "e.swift"])
		XCTAssertNil(index.folders["a/b"])
		XCTAssertEqual(index.folders["a"]?.fileCount, 1)
		XCTAssertEqual(index.folders[""]?.fileCount, 2)
	}

	func testRemovingAFileLowersTheCountOfEveryFolderAboveIt() {
		let index = RootFolderIndex(rootPath: "/repo")
		index.addFile("a/b/c.swift")
		index.addFile("a/b/d.swift")

		index.remove("a/b/c.swift")

		XCTAssertEqual(index.filePaths, ["a/b/d.swift"])
		XCTAssertEqual(index.folders["a/b"]?.fileCount, 1)
		XCTAssertEqual(index.folders["a"]?.fileCount, 1)
		XCTAssertEqual(index.folders[""]?.fileCount, 1)
	}

	func testSubtreeIsReadOnlyOnceEveryFolderUnderItIsRead() {
		let index = RootFolderIndex(rootPath: "/repo")
		XCTAssertFalse(index.isReadingComplete)

		index.markFolderRead("")
		index.addFolder("a", isRead: false)
		XCTAssertFalse(index.isReadingComplete)
		XCTAssertEqual(index.folders["a"]?.isSubtreeRead, false)

		index.markFolderRead("a")
		index.addFolder("a/b", isRead: false)
		XCTAssertEqual(index.folders["a"]?.isSubtreeRead, false)
		XCTAssertEqual(index.folders[""]?.isSubtreeRead, false)

		index.markFolderRead("a/b")
		XCTAssertEqual(index.folders["a/b"]?.isSubtreeRead, true)
		XCTAssertEqual(index.folders["a"]?.isSubtreeRead, true)
		XCTAssertTrue(index.isReadingComplete)
	}

	func testRemovingAnUnreadFolderCompletesTheFoldersAboveIt() {
		let index = RootFolderIndex(rootPath: "/repo")
		index.markFolderRead("")
		index.addFolder("a", isRead: true)
		index.addFolder("a/b", isRead: false)

		index.remove("a/b")

		XCTAssertEqual(index.folders["a"]?.isSubtreeRead, true)
		XCTAssertTrue(index.isReadingComplete)
	}

	func testAddingAFileUnderMissingFoldersAddsThemAsRead() {
		let index = RootFolderIndex(rootPath: "/repo")
		index.finishReading()

		index.addFile("x/y/z.swift")

		XCTAssertEqual(Set(index.folders.keys), ["", "x", "x/y"])
		XCTAssertEqual(index.folders["x"]?.fileCount, 1)
		XCTAssertTrue(index.isReadingComplete)
	}

	func testAddingAPathTwiceCountsItOnce() {
		let index = RootFolderIndex(rootPath: "/repo")
		index.addFolder("a", isRead: false)
		index.addFolder("a", isRead: false)
		index.addFile("a/b.swift")
		index.addFile("a/b.swift")

		XCTAssertEqual(index.folders["a"]?.fileCount, 1)
		index.markFolderRead("")
		index.markFolderRead("a")
		XCTAssertTrue(index.isReadingComplete)
	}

	func testFinishReadingMarksEveryFolderRead() {
		let index = RootFolderIndex(rootPath: "/repo")
		index.addFolder("a", isRead: false)
		index.addFolder("a/b", isRead: false)

		index.finishReading()

		XCTAssertTrue(index.isReadingComplete)
		XCTAssertEqual(index.folders["a"]?.isSubtreeRead, true)
	}

	func testReadingChunkAddsItsPathsAndMarksItsReadFolders() {
		let index = RootFolderIndex(rootPath: "/repo")

		index.add(FSPreparedChunk(
			folders: [FSItemDTO(relativePath: "a", isDirectory: true, hierarchy: 0)],
			files: [FSItemDTO(relativePath: "top.swift", isDirectory: false, hierarchy: 0)],
			readFolders: [""]
		))

		XCTAssertEqual(index.filePaths, ["top.swift"])
		XCTAssertEqual(index.folders["a"]?.isSubtreeRead, false)
		XCTAssertFalse(index.isReadingComplete)

		index.add(FSPreparedChunk(
			folders: [],
			files: [FSItemDTO(relativePath: "a/inner.swift", isDirectory: false, hierarchy: 1)],
			readFolders: ["a"]
		))

		XCTAssertEqual(index.folders["a"]?.fileCount, 1)
		XCTAssertTrue(index.isReadingComplete)
	}

	func testFolderStateComesFromSelectedFilesAgainstFilesUnderIt() {
		let index = RootFolderIndex(rootPath: "/repo")
		index.addFile("a/b/c.swift")
		index.addFile("a/d.swift")
		index.addFile("e.swift")
		index.addFolder("a/empty", isRead: true)

		index.select("a/b/c.swift")

		XCTAssertEqual(index.checkboxState(ofFolder: "a/b"), .checked)
		XCTAssertEqual(index.checkboxState(ofFolder: "a"), .mixed)
		XCTAssertEqual(index.checkboxState(ofFolder: ""), .mixed)
		XCTAssertEqual(index.checkboxState(ofFolder: "a/empty"), .unchecked)

		index.select("a/d.swift")

		XCTAssertEqual(index.checkboxState(ofFolder: "a"), .checked, "An empty folder under it does not keep a folder mixed")

		index.deselect("a/b/c.swift")
		index.deselect("a/d.swift")

		XCTAssertEqual(index.selectedFilePaths, [])
		XCTAssertEqual(index.checkboxState(ofFolder: "a"), .unchecked)
		XCTAssertEqual(index.checkboxState(ofFolder: ""), .unchecked)
	}

	func testOnlyFilesOfTheIndexCanBeSelectedAndEachCountsOnce() {
		let index = RootFolderIndex(rootPath: "/repo")
		index.addFile("a/b.swift")
		index.addFile("a/c.swift")

		index.select("a/b.swift")
		index.select("a/b.swift")
		index.select("a/missing.swift")
		index.select("a")

		XCTAssertEqual(index.selectedFilePaths, ["a/b.swift"])
		XCTAssertEqual(index.checkboxState(ofFolder: "a"), .mixed)
	}

	func testFileChangesOnDiskKeepTheSelectionCountsRight() {
		let index = RootFolderIndex(rootPath: "/repo")
		index.addFile("a/b/c.swift")
		index.addFile("a/d.swift")
		index.select("a/b/c.swift")
		index.select("a/d.swift")

		index.addFile("a/new.swift")

		XCTAssertEqual(index.checkboxState(ofFolder: "a"), .mixed, "A file that appears on disk is not selected")

		index.remove("a/new.swift")
		index.remove("a/b")

		XCTAssertEqual(index.selectedFilePaths, ["a/d.swift"])
		XCTAssertEqual(index.checkboxState(ofFolder: "a"), .checked)

		index.remove("a/d.swift")

		XCTAssertEqual(index.selectedFilePaths, [])
		XCTAssertEqual(index.checkboxState(ofFolder: ""), .unchecked)
	}
}
