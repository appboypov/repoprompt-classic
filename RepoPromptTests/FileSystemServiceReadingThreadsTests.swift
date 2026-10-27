import XCTest
@testable import RepoPrompt

final class FileSystemServiceReadingThreadsTests: XCTestCase {
	private var rootURL: URL!

	override func setUpWithError() throws {
		rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServiceReadingThreads-\(UUID().uuidString)", isDirectory: true)
		for index in 0..<64 {
			try FileManager.default.createDirectory(
				at: rootURL.appendingPathComponent("folder\(index)", isDirectory: true),
				withIntermediateDirectories: true
			)
		}
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: rootURL)
	}

	/// Synchronous on purpose: XCTest waits on the main run loop, so the test never needs a thread
	/// of the shared task pool to notice that one is not free.
	func testOtherTasksRunWhileEveryFolderReadingSlotWaitsOnTheDisk() throws {
		let disk = SlowListingFS()
		let readWidth = max(2, ProcessInfo.processInfo.activeProcessorCount)
		let rootURL = rootURL!
		let readingFinished = expectation(description: "reading finished")

		Task.detached(priority: .utility) {
			let service = try await FileSystemService(
				path: rootURL.path,
				isTestMode: true,
				fileManagerOverride: disk
			)
			for try await _ in await service.loadContentsInChunks(of: rootURL) {}
			readingFinished.fulfill()
		}

		for _ in 0..<readWidth {
			XCTAssertEqual(disk.slowListingStarted.wait(timeout: .now() + 10), .success)
		}
		let otherTaskRan = expectation(description: "other task ran")
		Task.detached(priority: .utility) { otherTaskRan.fulfill() }
		wait(for: [otherTaskRan], timeout: 5)

		disk.finishSlowListings()
		wait(for: [readingFinished], timeout: 30)
	}
}

/// The real disk, except that listing a `folder…` folder waits until the test lets it finish.
private final class SlowListingFS: TestFS {
	let slowListingStarted = DispatchSemaphore(value: 0)
	private let slowListings = DispatchGroup()
	private let disk = FileManager.default

	init() {
		slowListings.enter()
	}

	func finishSlowListings() {
		slowListings.leave()
	}

	func contentsOfDirectory(
		at url: URL,
		includingPropertiesForKeys keys: [URLResourceKey]?,
		options mask: FileManager.DirectoryEnumerationOptions
	) throws -> [URL] {
		if url.lastPathComponent.hasPrefix("folder") {
			slowListingStarted.signal()
			slowListings.wait()
		}
		return try disk.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
	}

	func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
		disk.fileExists(atPath: path, isDirectory: isDirectory)
	}

	func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
		try disk.attributesOfItem(atPath: path)
	}

	func createDirectory(
		atPath path: String,
		withIntermediateDirectories createIntermediates: Bool,
		attributes: [FileAttributeKey: Any]?
	) throws {
		try disk.createDirectory(atPath: path, withIntermediateDirectories: createIntermediates, attributes: attributes)
	}

	func createDirectory(
		at url: URL,
		withIntermediateDirectories createIntermediates: Bool,
		attributes: [FileAttributeKey: Any]?
	) throws {
		try disk.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
	}

	func removeItem(at url: URL) throws {
		try disk.removeItem(at: url)
	}

	func moveItemToTrash(at url: URL) throws -> URL? {
		try disk.moveItemToTrash(at: url)
	}

	func isWritableFile(atPath path: String) -> Bool {
		disk.isWritableFile(atPath: path)
	}

	func enumerator(
		at url: URL,
		includingPropertiesForKeys keys: [URLResourceKey]?,
		options mask: FileManager.DirectoryEnumerationOptions,
		errorHandler: ((URL, Error) -> Bool)?
	) -> FileManager.DirectoryEnumerator? {
		disk.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: errorHandler)
	}

	func contents(atPath path: String) -> Data? {
		disk.contents(atPath: path)
	}
}
