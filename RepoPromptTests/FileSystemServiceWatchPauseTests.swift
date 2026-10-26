import Combine
import XCTest
@testable import RepoPrompt

/// A hidden workspace pauses its FSEvent stream. Changes made while paused must reach
/// the workspace once the stream resumes, and nothing arrives while it is paused.
final class FileSystemServiceWatchPauseTests: XCTestCase {
	private final class DeltaCollector: @unchecked Sendable {
		private let lock = NSLock()
		private var deltas: [FileSystemDelta] = []

		func append(_ batch: [FileSystemDelta]) {
			lock.lock()
			deltas.append(contentsOf: batch)
			lock.unlock()
		}

		func contains(_ delta: FileSystemDelta) -> Bool {
			lock.lock()
			defer { lock.unlock() }
			return deltas.contains(delta)
		}
	}

	func testResumeReplaysFileCreatedWhilePaused() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("watch-pause-\(UUID().uuidString)", isDirectory: true)
			.resolvingSymlinksInPath()
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let service = try await FileSystemService(path: rootURL.path, respectGitignore: false, skipSymlinks: true)
		let collector = DeltaCollector()
		let cancellable = await service.publisherForChanges().sink { collector.append($0) }
		defer { cancellable.cancel() }

		await service.startWatchingForChanges()
		try await Task.sleep(nanoseconds: 500_000_000)
		await service.pauseWatchingForChanges()

		try "hidden".write(to: rootURL.appendingPathComponent("made-while-hidden.txt"), atomically: true, encoding: .utf8)
		try await Task.sleep(nanoseconds: 1_500_000_000)
		XCTAssertFalse(collector.contains(.fileAdded("made-while-hidden.txt")), "A paused stream must not deliver changes")

		await service.startWatchingForChanges()
		defer { Task { await service.stopWatchingForChanges() } }
		let deadline = Date().addingTimeInterval(10)
		while Date() < deadline, !collector.contains(.fileAdded("made-while-hidden.txt")) {
			try await Task.sleep(nanoseconds: 100_000_000)
		}
		XCTAssertTrue(collector.contains(.fileAdded("made-while-hidden.txt")), "Resume must replay the file created while paused")
	}
}
