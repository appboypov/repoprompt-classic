import XCTest
@testable import RepoPrompt

private actor CompletionTracker {
	private var labels: [String] = []

	func record(_ label: String) {
		labels.append(label)
	}

	func snapshot() -> [String] {
		labels
	}
}

final class DelegateEditTaskManagerTests: XCTestCase {
	func testWaitForTasksIncludesLateArrivals() async throws {
		let manager = DelegateEditTaskManager()
		let messageId = UUID()
		let tracker = CompletionTracker()

		let first = Task<Void, Never> {
			try? await Task.sleep(nanoseconds: 200_000_000)
			await tracker.record("first")
		}
		await manager.addTask(first, forMessageId: messageId)

		let waitTask = Task<[String], Never> {
			await manager.waitForTasks(forMessageId: messageId)
			return await tracker.snapshot()
		}

		try await Task.sleep(nanoseconds: 50_000_000)
		let second = Task<Void, Never> {
			try? await Task.sleep(nanoseconds: 220_000_000)
			await tracker.record("second")
		}
		await manager.addTask(second, forMessageId: messageId)

		let completed = await waitTask.value
		XCTAssertEqual(Set(completed), Set(["first", "second"]))
	}

	func testWaitForAllTasksIncludesLateArrivals() async throws {
		let manager = DelegateEditTaskManager()
		let firstMessageId = UUID()
		let secondMessageId = UUID()
		let tracker = CompletionTracker()

		let first = Task<Void, Never> {
			try? await Task.sleep(nanoseconds: 200_000_000)
			await tracker.record("first-message")
		}
		await manager.addTask(first, forMessageId: firstMessageId)

		let waitAllTask = Task<[String], Never> {
			await manager.waitForAllTasks()
			return await tracker.snapshot()
		}

		try await Task.sleep(nanoseconds: 50_000_000)
		let second = Task<Void, Never> {
			try? await Task.sleep(nanoseconds: 220_000_000)
			await tracker.record("second-message")
		}
		await manager.addTask(second, forMessageId: secondMessageId)

		let completed = await waitAllTask.value
		XCTAssertEqual(Set(completed), Set(["first-message", "second-message"]))
	}
}
