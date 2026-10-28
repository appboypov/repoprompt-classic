import XCTest
@testable import RepoPrompt

final class CodeScanQueueAndFingerprintTests: XCTestCase {
	private func makeRequest(_ relativePath: String) -> CodeScanActor.ScanRequest {
		CodeScanActor.ScanRequest(
			fileID: UUID(),
			modificationDate: Date(timeIntervalSince1970: 0),
			content: "",
			fileExtension: "swift",
			relativePath: relativePath,
			fullPath: "/repo/\(relativePath)",
			rootFolderPath: "/repo"
		)
	}

	private func drain(_ queue: inout CodeScanActor.ScanRequestQueue) -> [String] {
		var paths: [String] = []
		while let request = queue.popFirst() {
			paths.append(request.relativePath)
		}
		return paths
	}

	func testContentFingerprintIsTheLowercaseHexSHA256OfTheContent() {
		let fingerprint = CodeMapContentFingerprint(content: "abc")

		XCTAssertEqual(fingerprint.contentHash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
		XCTAssertEqual(fingerprint.byteCount, 3)
	}

	func testQueueHandsOutRequestsInArrivalOrder() {
		var queue = CodeScanActor.ScanRequestQueue()
		queue.append(makeRequest("a"))
		queue.append(contentsOf: [makeRequest("b"), makeRequest("c")])

		XCTAssertEqual(queue.popFirst()?.relativePath, "a")
		queue.append(makeRequest("d"))

		XCTAssertEqual(queue.count, 3)
		XCTAssertEqual(queue.map(\.relativePath), ["b", "c", "d"])
		XCTAssertEqual(drain(&queue), ["b", "c", "d"])
		XCTAssertTrue(queue.isEmpty)
		XCTAssertNil(queue.popFirst())
	}

	func testRemovingRequestsKeepsTheOrderOfTheRest() {
		var queue = CodeScanActor.ScanRequestQueue()
		queue.append(contentsOf: ["a", "b", "c", "d"].map(makeRequest))
		_ = queue.popFirst()

		queue.removeAll { $0.relativePath == "c" }

		XCTAssertEqual(queue.count, 2)
		XCTAssertEqual(drain(&queue), ["b", "d"])
	}

	func testOrderSurvivesDroppingTheTakenRequests() {
		var queue = CodeScanActor.ScanRequestQueue()
		let paths = (0..<3000).map(String.init)
		queue.append(contentsOf: paths.map(makeRequest))

		var taken: [String] = []
		for _ in 0..<1600 {
			taken.append(queue.popFirst()!.relativePath)
		}
		queue.append(makeRequest("last"))

		XCTAssertEqual(queue.count, 1401)
		XCTAssertEqual(taken + drain(&queue), paths + ["last"])
	}
}
