import XCTest
@testable import RepoPrompt

@MainActor
final class PerKeyTaskStoreTests: XCTestCase {
	func testSetReplacesAndCancelsExistingTask() async {
		let store = PerKeyTaskStore<String>()
		let firstCancelled = CancellationFlag()
		let secondCancelled = CancellationFlag()

		store.set("tab-a", task: Task {
			defer { firstCancelled.markCancelled() }
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 10_000_000)
			}
		})
		store.set("tab-a", task: Task {
			defer { secondCancelled.markCancelled() }
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 10_000_000)
			}
		})

		let firstWasCancelled = await waitForCondition(timeoutSeconds: 1.0) {
			firstCancelled.isCancelled()
		}
		XCTAssertTrue(firstWasCancelled)
		XCTAssertTrue(store.hasTask(for: "tab-a"))

		store.cancelAll()
		let secondWasCancelled = await waitForCondition(timeoutSeconds: 1.0) {
			secondCancelled.isCancelled()
		}
		XCTAssertTrue(secondWasCancelled)
	}

	func testCancelAndCancelAll() async {
		let store = PerKeyTaskStore<Int>()
		let firstCancelled = CancellationFlag()
		let secondCancelled = CancellationFlag()

		store.set(1, task: Task {
			defer { firstCancelled.markCancelled() }
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 10_000_000)
			}
		})
		store.set(2, task: Task {
			defer { secondCancelled.markCancelled() }
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 10_000_000)
			}
		})

		store.cancel(1)
		let firstWasCancelled = await waitForCondition(timeoutSeconds: 1.0) {
			firstCancelled.isCancelled()
		}
		XCTAssertTrue(firstWasCancelled)
		XCTAssertFalse(store.hasTask(for: 1))
		XCTAssertTrue(store.hasTask(for: 2))

		store.cancelAll()
		let secondWasCancelled = await waitForCondition(timeoutSeconds: 1.0) {
			secondCancelled.isCancelled()
		}
		XCTAssertTrue(secondWasCancelled)
		XCTAssertFalse(store.hasTask(for: 2))
	}

	private func waitForCondition(
		timeoutSeconds: TimeInterval,
		condition: @escaping () async -> Bool
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeoutSeconds)
		while Date() < deadline {
			if await condition() {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return await condition()
	}
}

private final class CancellationFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelled = false

	func markCancelled() {
		lock.lock()
		cancelled = true
		lock.unlock()
	}

	func isCancelled() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return cancelled
	}
}
