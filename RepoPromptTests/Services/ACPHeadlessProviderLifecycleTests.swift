import Foundation
import XCTest
@testable import RepoPrompt

final class ACPHeadlessProviderLifecycleTests: XCTestCase {
	func testConcurrentDisposeIsSingleFlight() async {
		let lifecycle = ACPHeadlessProviderLifecycle()
		let probe = LifecycleCleanupProbe()
		let generation = lifecycle.startStreamTask { _ in
			makeSuspendedTask()
		}
		XCTAssertNotNil(generation)
		guard let generation else { return }

		let registered = lifecycle.setActiveController(
			ACPHeadlessProviderLifecycle.ControllerHandle(id: UUID()) {
				await probe.cleanupAndWaitForRelease()
			},
			generation: generation
		)
		XCTAssertTrue(registered)

		let firstDispose = Task { await lifecycle.dispose() }
		await probe.waitForCleanupStart()
		let concurrentDisposes = (0..<20).map { _ in
			Task { await lifecycle.dispose() }
		}

		await Task.yield()
		await probe.releaseCleanup()
		await firstDispose.value
		for dispose in concurrentDisposes {
			await dispose.value
		}

		let countAfterConcurrentDispose = await probe.cleanupCallCount()
		XCTAssertEqual(countAfterConcurrentDispose, 1)

		await lifecycle.dispose()
		let countAfterRepeatedDispose = await probe.cleanupCallCount()
		XCTAssertEqual(countAfterRepeatedDispose, 1)
	}

	func testDisposeRejectsLateControllerRegistration() async {
		let lifecycle = ACPHeadlessProviderLifecycle()
		let probe = LifecycleCleanupProbe()
		let generation = lifecycle.startStreamTask { _ in
			makeSuspendedTask()
		}
		XCTAssertNotNil(generation)
		guard let generation else { return }

		await lifecycle.dispose()

		let registered = lifecycle.setActiveController(
			ACPHeadlessProviderLifecycle.ControllerHandle(id: UUID()) {
				await probe.recordCleanup()
			},
			generation: generation
		)
		XCTAssertFalse(registered)
		let cleanupCount = await probe.cleanupCallCount()
		XCTAssertEqual(cleanupCount, 0)
	}

	func testNewStreamDuringDisposalFailsPredictablyAndLaterStartSucceeds() async {
		let lifecycle = ACPHeadlessProviderLifecycle()
		let probe = LifecycleCleanupProbe()
		let generation = lifecycle.startStreamTask { _ in
			makeSuspendedTask()
		}
		XCTAssertNotNil(generation)
		guard let generation else { return }

		let registered = lifecycle.setActiveController(
			ACPHeadlessProviderLifecycle.ControllerHandle(id: UUID()) {
				await probe.cleanupAndWaitForRelease()
			},
			generation: generation
		)
		XCTAssertTrue(registered)

		let dispose = Task { await lifecycle.dispose() }
		await probe.waitForCleanupStart()

		let generationDuringDisposal = lifecycle.startStreamTask { _ in
			makeSuspendedTask()
		}
		XCTAssertNil(generationDuringDisposal)

		await probe.releaseCleanup()
		await dispose.value

		let generationAfterDisposal = lifecycle.startStreamTask { _ in
			makeSuspendedTask()
		}
		XCTAssertNotNil(generationAfterDisposal)
		await lifecycle.dispose()
	}

	private func makeSuspendedTask() -> Task<Void, Never> {
		Task {
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}
	}
}

private actor LifecycleCleanupProbe {
	private var cleanupCount = 0
	private var cleanupStarted = false
	private var cleanupStartWaiters: [CheckedContinuation<Void, Never>] = []
	private var cleanupRelease: CheckedContinuation<Void, Never>?

	func recordCleanup() {
		cleanupCount += 1
	}

	func cleanupAndWaitForRelease() async {
		cleanupCount += 1
		cleanupStarted = true
		let waiters = cleanupStartWaiters
		cleanupStartWaiters.removeAll()
		for waiter in waiters {
			waiter.resume()
		}

		await withCheckedContinuation { continuation in
			cleanupRelease = continuation
		}
	}

	func waitForCleanupStart() async {
		if cleanupStarted { return }
		await withCheckedContinuation { continuation in
			cleanupStartWaiters.append(continuation)
		}
	}

	func releaseCleanup() {
		cleanupRelease?.resume()
		cleanupRelease = nil
	}

	func cleanupCallCount() -> Int {
		cleanupCount
	}
}
