import XCTest
@testable import RepoPrompt

final class FileSystemServiceReadFirstTests: XCTestCase {
	private func next(_ queue: [String], readFirst: Set<String>) -> String? {
		FileSystemService.indexToReadNext(of: queue, readFirst: readFirst).map { queue[$0] }
	}

	func testWithoutReadFirstFoldersTheLastQueuedFolderIsReadNext() {
		XCTAssertEqual(next(["a", "t", "b"], readFirst: []), "b")
	}

	func testAFolderAboveAReadFirstFolderIsReadBeforeTheOthers() {
		XCTAssertEqual(next(["a", "t", "b"], readFirst: ["t/deep"]), "t")
	}

	func testTheReadFirstFolderAndFoldersInsideItAreReadBeforeTheOthers() {
		XCTAssertEqual(next(["a", "t/deep", "b"], readFirst: ["t/deep"]), "t/deep")
		XCTAssertEqual(next(["a", "t/deep/x", "b"], readFirst: ["t/deep"]), "t/deep/x")
	}

	func testAFolderBesideTheWayToAReadFirstFolderWaitsItsTurn() {
		XCTAssertEqual(next(["t/deeper", "t/other", "b"], readFirst: ["t/deep"]), "b")
	}

	func testTheLastQueuedFolderOnTheWayIsReadFirstSoTheWayIsFollowedDepthFirst() {
		XCTAssertEqual(next(["t/deep/x", "a", "t/deep/y"], readFirst: ["t/deep"]), "t/deep/y")
	}

	func testAnEmptyQueueHasNothingToRead() {
		XCTAssertNil(next([], readFirst: ["t"]))
	}
}
