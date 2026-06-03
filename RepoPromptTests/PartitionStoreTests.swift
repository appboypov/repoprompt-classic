import XCTest
import CryptoKit
@testable import RepoPrompt

final class PartitionStoreTests: XCTestCase {
	private var store: PartitionStore!
	private var rootPath: String = ""
	private var partitionDirectory: URL?

	override func setUp() {
		super.setUp()
		store = PartitionStore()
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("PartitionStoreTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		rootPath = rootURL.path
		partitionDirectory = partitionDirectoryURL(for: rootPath)
	}

	override func tearDown() {
		if let partitionDirectory {
			try? FileManager.default.removeItem(at: partitionDirectory)
		}
		if !rootPath.isEmpty {
			try? FileManager.default.removeItem(atPath: rootPath)
		}
		partitionDirectory = nil
		rootPath = ""
		store = nil
		super.tearDown()
	}

	func testSetPathsUpdatesOnlySpecifiedPathAndPreservesOtherEntries() async throws {
		let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
		let alphaRange = LineRange(start: 1, end: 2)
		let betaRange = LineRange(start: 10, end: 11)

		_ = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"alpha.swift": PartitionStore.SliceUpdate(
					ranges: [alphaRange],
					fileModificationTime: 100,
					anchors: [anchor(range: alphaRange, tag: "alpha")]
				),
				"beta.swift": PartitionStore.SliceUpdate(
					ranges: [betaRange],
					fileModificationTime: 200,
					anchors: nil
				)
			],
			mode: .set
		)

		let result = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"alpha.swift": PartitionStore.SliceUpdate(
					ranges: [LineRange(start: 2, end: 3)],
					fileModificationTime: nil,
					anchors: nil
				)
			],
			mode: .setPaths
		)

		XCTAssertEqual(Set(result.keys), Set(["alpha.swift", "beta.swift"]))
		XCTAssertEqual(result["alpha.swift"]?.ranges, [LineRange(start: 2, end: 3)])
		XCTAssertEqual(result["alpha.swift"]?.fileModificationTime, 100)
		XCTAssertNil(result["alpha.swift"]?.anchors)
		XCTAssertEqual(result["beta.swift"]?.ranges, [betaRange])
		XCTAssertEqual(result["beta.swift"]?.fileModificationTime, 200)
	}

	func testSetPathsPreservesExistingAnchorsWhenRangesUnchanged() async throws {
		let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
		let range = LineRange(start: 4, end: 6)
		let existingAnchor = anchor(range: range, tag: "persist")

		_ = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [range],
					fileModificationTime: 123,
					anchors: [existingAnchor]
				)
			],
			mode: .set
		)

		let result = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [range],
					fileModificationTime: nil,
					anchors: nil
				)
			],
			mode: .setPaths
		)

		XCTAssertEqual(result["file.swift"]?.ranges, [range])
		XCTAssertEqual(result["file.swift"]?.fileModificationTime, 123)
		XCTAssertEqual(result["file.swift"]?.anchors, [existingAnchor])
	}

	func testSetPathsRemovesEntryWhenUpdatedWithEmptyRanges() async throws {
		let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
		let keepRange = LineRange(start: 20, end: 22)

		_ = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"drop.swift": PartitionStore.SliceUpdate(ranges: [LineRange(start: 1, end: 2)], fileModificationTime: 11),
				"keep.swift": PartitionStore.SliceUpdate(ranges: [keepRange], fileModificationTime: 22)
			],
			mode: .set
		)

		let result = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"drop.swift": PartitionStore.SliceUpdate(ranges: [], fileModificationTime: nil)
			],
			mode: .setPaths
		)

		XCTAssertEqual(Set(result.keys), Set(["keep.swift"]))
		XCTAssertEqual(result["keep.swift"]?.ranges, [keepRange])
	}

	func testSetPathsUsesProvidedAnchorsAndSanitizesToFinalRanges() async throws {
		let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
		let oldRange = LineRange(start: 1, end: 1)
		let newRange = LineRange(start: 8, end: 9)
		let matching = anchor(range: newRange, tag: "matching")
		let stale = anchor(range: oldRange, tag: "stale")

		_ = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [oldRange],
					fileModificationTime: 50,
					anchors: [stale]
				)
			],
			mode: .set
		)

		let result = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [newRange],
					fileModificationTime: 55,
					anchors: [matching, stale]
				)
			],
			mode: .setPaths
		)

		XCTAssertEqual(result["file.swift"]?.ranges, [newRange])
		XCTAssertEqual(result["file.swift"]?.fileModificationTime, 55)
		XCTAssertEqual(result["file.swift"]?.anchors, [matching])
	}

	func testSetPathsClearsExistingAnchorsWhenPassedEmptyAnchorArray() async throws {
		let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
		let range = LineRange(start: 12, end: 15)
		let existingAnchor = anchor(range: range, tag: "persist")

		_ = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [range],
					fileModificationTime: 88,
					anchors: [existingAnchor]
				)
			],
			mode: .set
		)

		let result = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [range],
					fileModificationTime: nil,
					anchors: []
				)
			],
			mode: .setPaths
		)

		XCTAssertEqual(result["file.swift"]?.ranges, [range])
		XCTAssertEqual(result["file.swift"]?.fileModificationTime, 88)
		XCTAssertNil(result["file.swift"]?.anchors)
	}

	func testAddMergesAnchorsFromExistingAndIncomingRanges() async throws {
		let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
		let firstRange = LineRange(start: 1, end: 2)
		let secondRange = LineRange(start: 5, end: 6)
		let firstAnchor = anchor(range: firstRange, tag: "first")
		let secondAnchor = anchor(range: secondRange, tag: "second")

		_ = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [firstRange],
					fileModificationTime: 7,
					anchors: [firstAnchor]
				)
			],
			mode: .set
		)

		let result = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [secondRange],
					fileModificationTime: nil,
					anchors: [secondAnchor]
				)
			],
			mode: .add
		)

		XCTAssertEqual(result["file.swift"]?.ranges, [firstRange, secondRange])
		XCTAssertEqual(result["file.swift"]?.fileModificationTime, 7)
		XCTAssertEqual(result["file.swift"]?.anchors, [firstAnchor, secondAnchor])
	}

	func testRemovePrunesAnchorsForRemovedRanges() async throws {
		let scope = PartitionScope(workspaceID: UUID(), tabID: UUID())
		let removedRange = LineRange(start: 1, end: 2)
		let keptRange = LineRange(start: 10, end: 12)
		let removedAnchor = anchor(range: removedRange, tag: "removed")
		let keptAnchor = anchor(range: keptRange, tag: "kept")

		_ = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [removedRange, keptRange],
					fileModificationTime: 88,
					anchors: [removedAnchor, keptAnchor]
				)
			],
			mode: .set
		)

		let result = try await store.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				"file.swift": PartitionStore.SliceUpdate(
					ranges: [removedRange],
					fileModificationTime: nil,
					anchors: nil
				)
			],
			mode: .remove
		)

		XCTAssertEqual(result["file.swift"]?.ranges, [keptRange])
		XCTAssertEqual(result["file.swift"]?.fileModificationTime, 88)
		XCTAssertEqual(result["file.swift"]?.anchors, [keptAnchor])
	}

	private func anchor(range: LineRange, tag: String) -> SliceAnchor {
		SliceAnchor(
			range: range,
			startSignature: ["\(tag)-start"],
			endSignature: ["\(tag)-end"]
		)
	}

	private func partitionDirectoryURL(for rootPath: String) -> URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let standardized = (rootPath as NSString).standardizingPath
		let leaf = (standardized as NSString).lastPathComponent
		let digest = SHA256.hash(data: Data(standardized.utf8))
		let hex = digest.map { String(format: "%02x", $0) }.joined()
		let repoKey = "\(leaf)-\(String(hex.prefix(12)))"
		return base.appendingPathComponent("RepoPrompt/Partitions/\(repoKey)", isDirectory: true)
	}
}
