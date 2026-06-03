import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeRunLeaseTests: XCTestCase {
	func testAcquireInstallsPolicyAndReleaseWaitsForRoutingSignal() async {
		let runID = UUID()
		let gateID = UUID()
		let tabID = UUID()
		let recorder = LeaseRecorder()
		let lease = makeLease(
			runID: runID,
			gateID: gateID,
			tabID: tabID,
			recorder: recorder
		)

		let acquired = await lease.acquire()
		XCTAssertTrue(acquired)

		let snapshot = await recorder.snapshot()
		XCTAssertEqual(snapshot.mcpEnableCount, 1)
		XCTAssertEqual(snapshot.policyCalls.count, 1)
		XCTAssertEqual(snapshot.stalePolicyClearCount, 0)
		guard let policyCall = snapshot.policyCalls.first else {
			return XCTFail("Expected one policy install call")
		}
		XCTAssertEqual(policyCall.clientName, DiscoverAgentKind.claudeCode.mcpClientNameHint)
		XCTAssertEqual(policyCall.windowID, 77)
		XCTAssertTrue(policyCall.oneShot)
		XCTAssertEqual(policyCall.tabID, tabID)
		XCTAssertEqual(policyCall.runID, runID)
		XCTAssertEqual(policyCall.purposeRaw, MCPRunPurpose.agentModeRun.rawValue)
		XCTAssertEqual(policyCall.requiresExpectedAgentPID, true)

		let gateCleared = AsyncFlag()
		let gateWaitTask = Task {
			await HeadlessAgentConnectionGate.waitForClearConnection()
			await gateCleared.setTrue()
		}

		let releaseTask = Task { await lease.releaseWhenRouted(timeoutMs: 1_500) }
		try? await Task.sleep(nanoseconds: 120_000_000)
		let gateWasClearedEarly = await gateCleared.value()
		XCTAssertFalse(gateWasClearedEarly)

		MCPRoutingWaiter.signalRouted(runID)
		let didRoute = await releaseTask.value
		XCTAssertTrue(didRoute)
		let waiterCompleted = await waitForCondition(timeoutSeconds: 1.0) {
			await gateCleared.value()
		}
		XCTAssertTrue(waiterCompleted)
		gateWaitTask.cancel()

		await cleanup(runID: runID)
	}

	func testReleaseWhenRoutedTimeoutReturnsFalseAndReleasesGate() async {
		let runID = UUID()
		let gateID = UUID()
		let tabID = UUID()
		let recorder = LeaseRecorder()
		let lease = makeLease(
			runID: runID,
			gateID: gateID,
			tabID: tabID,
			recorder: recorder
		)

		let acquired = await lease.acquire()
		XCTAssertTrue(acquired)

		let gateCleared = AsyncFlag()
		let gateWaitTask = Task {
			await HeadlessAgentConnectionGate.waitForClearConnection()
			await gateCleared.setTrue()
		}

		let didRoute = await lease.releaseWhenRouted(timeoutMs: 75)
		XCTAssertFalse(didRoute)
		let waiterCompleted = await waitForCondition(timeoutSeconds: 1.0) {
			await gateCleared.value()
		}
		XCTAssertTrue(waiterCompleted)
		let alreadyReleased = await HeadlessAgentConnectionGate.completeIfActive(gateID)
		XCTAssertFalse(alreadyReleased)
		let snapshot = await recorder.snapshot()
		XCTAssertEqual(snapshot.stalePolicyClearCount, 1)
		gateWaitTask.cancel()

		await cleanup(runID: runID)
	}

	func testReleaseWithoutRoutingWaitReleasesGateWithoutClearingPolicy() async {
		let runID = UUID()
		let gateID = UUID()
		let tabID = UUID()
		let recorder = LeaseRecorder()
		let lease = makeLease(
			runID: runID,
			gateID: gateID,
			tabID: tabID,
			recorder: recorder
		)

		let acquired = await lease.acquire()
		XCTAssertTrue(acquired)

		let gateCleared = AsyncFlag()
		let gateWaitTask = Task {
			await HeadlessAgentConnectionGate.waitForClearConnection()
			await gateCleared.setTrue()
		}

		await lease.releaseWithoutRoutingWait()
		let waiterCompleted = await waitForCondition(timeoutSeconds: 1.0) {
			await gateCleared.value()
		}
		XCTAssertTrue(waiterCompleted)
		let alreadyReleased = await HeadlessAgentConnectionGate.completeIfActive(gateID)
		XCTAssertFalse(alreadyReleased)
		let snapshot = await recorder.snapshot()
		XCTAssertEqual(snapshot.stalePolicyClearCount, 0)

		let secondRelease = await lease.releaseWhenRouted(timeoutMs: 10)
		XCTAssertFalse(secondRelease)
		gateWaitTask.cancel()

		await cleanup(runID: runID)
	}

	func testClaudeNativeAgentModeLeaseRequiresExpectedPID() async {
		let spec = MCPBootstrapLeaseSpec.agentMode(
			tabID: UUID(),
			runID: UUID(),
			gateID: UUID(),
			windowID: 77,
			agent: .claudeCode
		)

		XCTAssertEqual(spec.clientName, DiscoverAgentKind.claudeCode.mcpClientNameHint)
		XCTAssertTrue(spec.requiresExpectedAgentPID)
	}

	func testCodexNativeAgentModeLeaseUsesCodexClientAndRequiresExpectedPID() async {
		let spec = MCPBootstrapLeaseSpec.agentMode(
			tabID: UUID(),
			runID: UUID(),
			gateID: UUID(),
			windowID: 77,
			agent: .codexExec
		)

		XCTAssertEqual(spec.clientName, DiscoverAgentKind.codexExec.mcpClientNameHint)
		XCTAssertTrue(spec.requiresExpectedAgentPID)
	}

	func testCursorAgentModeLeaseUsesCursorClientAndRequiresExpectedPID() async {
		let runID = UUID()
		let gateID = UUID()
		let tabID = UUID()
		let recorder = LeaseRecorder()
		let lease = makeLease(
			runID: runID,
			gateID: gateID,
			tabID: tabID,
			agent: .cursor,
			recorder: recorder
		)

		let acquired = await lease.acquire()
		XCTAssertTrue(acquired)

		let snapshot = await recorder.snapshot()
		let policyCall = try? XCTUnwrap(snapshot.policyCalls.first)
		XCTAssertEqual(policyCall?.clientName, DiscoverAgentKind.cursor.mcpClientNameHint)
		XCTAssertEqual(policyCall?.requiresExpectedAgentPID, true)

		await lease.cancelAndCleanup()
		await cleanup(runID: runID)
	}

	func testAcquireIsIdempotentAndInstallsPolicyOnce() async {
		let runID = UUID()
		let gateID = UUID()
		let tabID = UUID()
		let recorder = LeaseRecorder()
		let lease = makeLease(
			runID: runID,
			gateID: gateID,
			tabID: tabID,
			recorder: recorder
		)

		let firstAcquire = await lease.acquire()
		let secondAcquire = await lease.acquire()
		XCTAssertTrue(firstAcquire)
		XCTAssertTrue(secondAcquire)

		let snapshot = await recorder.snapshot()
		XCTAssertEqual(snapshot.mcpEnableCount, 1)
		XCTAssertEqual(snapshot.policyCalls.count, 1)

		await lease.cancelAndCleanup()
		await cleanup(runID: runID)
	}

	func testFailAndReleaseSignalsFailureAndReleasesGate() async {
		let runID = UUID()
		let gateID = UUID()
		let tabID = UUID()
		let recorder = LeaseRecorder()
		let lease = makeLease(
			runID: runID,
			gateID: gateID,
			tabID: tabID,
			recorder: recorder
		)

		let acquired = await lease.acquire()
		XCTAssertTrue(acquired)

		let gateCleared = AsyncFlag()
		let gateWaitTask = Task {
			await HeadlessAgentConnectionGate.waitForClearConnection()
			await gateCleared.setTrue()
		}

		let start = Date()
		await lease.failAndRelease()
		let elapsed = Date().timeIntervalSince(start)
		XCTAssertLessThan(elapsed, 2.0)

		let waiterCompleted = await waitForCondition(timeoutSeconds: 1.0) {
			await gateCleared.value()
		}
		XCTAssertTrue(waiterCompleted)

		let secondRelease = await lease.releaseWhenRouted(timeoutMs: 10)
		XCTAssertFalse(secondRelease)
		let alreadyReleased = await HeadlessAgentConnectionGate.completeIfActive(gateID)
		XCTAssertFalse(alreadyReleased)
		let snapshot = await recorder.snapshot()
		XCTAssertEqual(snapshot.stalePolicyClearCount, 1)
		gateWaitTask.cancel()

		await cleanup(runID: runID)
	}

	func testCancelAndCleanupClearsPendingPolicy() async {
		let runID = UUID()
		let gateID = UUID()
		let tabID = UUID()
		let recorder = LeaseRecorder()
		let lease = makeLease(
			runID: runID,
			gateID: gateID,
			tabID: tabID,
			recorder: recorder
		)

		let acquired = await lease.acquire()
		XCTAssertTrue(acquired)
		await lease.cancelAndCleanup()

		let snapshot = await recorder.snapshot()
		XCTAssertEqual(snapshot.stalePolicyClearCount, 1)

		await cleanup(runID: runID)
	}

	func testReconnectRequiresNewLeaseInstance() async {
		let runID = UUID()
		let tabID = UUID()
		let recorder = LeaseRecorder()
		let firstLease = makeLease(
			runID: runID,
			gateID: UUID(),
			tabID: tabID,
			recorder: recorder
		)

		let acquired = await firstLease.acquire()
		XCTAssertTrue(acquired)
		let firstReleaseTask = Task { await firstLease.releaseWhenRouted(timeoutMs: 1_500) }
		MCPRoutingWaiter.signalRouted(runID)
		let firstReleaseRouted = await firstReleaseTask.value
		XCTAssertTrue(firstReleaseRouted)

		let reacquireSameLease = await firstLease.acquire()
		XCTAssertFalse(reacquireSameLease)

		let secondLease = makeLease(
			runID: runID,
			gateID: UUID(),
			tabID: tabID,
			recorder: recorder
		)
		let secondAcquired = await secondLease.acquire()
		XCTAssertTrue(secondAcquired)
		let secondReleaseTask = Task { await secondLease.releaseWhenRouted(timeoutMs: 1_500) }
		MCPRoutingWaiter.signalRouted(runID)
		let secondReleaseRouted = await secondReleaseTask.value
		XCTAssertTrue(secondReleaseRouted)

		let snapshot = await recorder.snapshot()
		XCTAssertEqual(snapshot.mcpEnableCount, 2)
		XCTAssertEqual(snapshot.policyCalls.count, 2)

		await cleanup(runID: runID)
	}

	private func makeLease(
		runID: UUID,
		gateID: UUID,
		tabID: UUID,
		agent: DiscoverAgentKind = .claudeCode,
		recorder: LeaseRecorder
	) -> MCPBootstrapLease {
		let spec = MCPBootstrapLeaseSpec.agentMode(
			tabID: tabID,
			runID: runID,
			gateID: gateID,
			windowID: 77,
			agent: agent
		)
		return MCPBootstrapLease(
			spec: spec,
			mcpServerEnabler: {
				await recorder.recordMcpEnabled()
			},
			policyInstaller: MCPBootstrapLease.agentModePolicyInstaller({ clientName, windowID, _, oneShot, _, _, tabID, runID, _, purpose, _, _, requiresExpectedAgentPID in
				await recorder.recordPolicy(
					PolicyInstallCall(
						clientName: clientName,
						windowID: windowID,
						oneShot: oneShot,
						tabID: tabID,
						runID: runID,
						purposeRaw: purpose.rawValue,
						requiresExpectedAgentPID: requiresExpectedAgentPID
					)
				)
			}),
			policyClearer: MCPBootstrapLease.agentModePolicyClearer(pendingPolicyClearer: {
				await recorder.recordStalePolicyClear()
			})
		)
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

	private func cleanup(runID: UUID) async {
		await MCPRoutingWaiter.cleanup(runID: runID)
		await HeadlessAgentConnectionGate.cancelAll()
	}
}

private struct PolicyInstallCall: Equatable {
	let clientName: String
	let windowID: Int
	let oneShot: Bool
	let tabID: UUID?
	let runID: UUID?
	let purposeRaw: String
	let requiresExpectedAgentPID: Bool
}

private actor LeaseRecorder {
	private var mcpEnableCount = 0
	private var policyCalls: [PolicyInstallCall] = []
	private var stalePolicyClearCount = 0

	func recordMcpEnabled() {
		mcpEnableCount += 1
	}

	func recordPolicy(_ call: PolicyInstallCall) {
		policyCalls.append(call)
	}

	func recordStalePolicyClear() {
		stalePolicyClearCount += 1
	}

	func snapshot() -> (mcpEnableCount: Int, policyCalls: [PolicyInstallCall], stalePolicyClearCount: Int) {
		(mcpEnableCount, policyCalls, stalePolicyClearCount)
	}
}

private actor AsyncFlag {
	private var isSet = false

	func setTrue() {
		isSet = true
	}

	func value() -> Bool {
		isSet
	}
}
