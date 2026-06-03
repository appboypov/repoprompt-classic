import XCTest
@testable import RepoPrompt

final class AgentRunSessionStoreTests: XCTestCase {
	func testWaitUntilInterestingResumesWhenWaitingSnapshotArrives() async {
		let sessionID = UUID()
		await AgentRunSessionStore.register(sessionID: sessionID)

		let waiter = Task {
			await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID)
		}
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .waitingForInput))

		let disposition = await waiter.value
		if case .snapshotReady(let snap) = disposition {
			XCTAssertEqual(snap.status, .waitingForInput)
			XCTAssertNotNil(snap.interaction)
		} else {
			XCTFail("Expected .snapshotReady, got \(disposition)")
		}
		let storedSnapshot = await AgentRunSessionStore.snapshot(for: sessionID)
		XCTAssertEqual(storedSnapshot?.status, .waitingForInput)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testInstructionDeliveredWakeResumesCurrentWaiterWithRunningSnapshot() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		let waiter = Task {
			await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 5)
		}
		try? await Task.sleep(nanoseconds: 50_000_000)

		await store.noteSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: sessionID, status: .running),
			reason: .instructionDelivered
		)

		let disposition = await waiter.value
		if case .noteworthySnapshot(let snap, let reason) = disposition {
			XCTAssertEqual(snap.status, .running)
			XCTAssertEqual(reason, .instructionDelivered)
		} else {
			XCTFail("Expected .noteworthySnapshot(.running, .instructionDelivered), got \(disposition)")
		}
		let waiterCount = await store.test_waiterCount(sessionID: sessionID)
		XCTAssertEqual(waiterCount, 0)
		await store.cleanup(sessionID: sessionID)
	}

	func testInstructionDeliveredWakeIsStickyForNextWait() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		await store.noteSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: sessionID, status: .running),
			reason: .instructionDelivered
		)

		let disposition = await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 0)
		if case .noteworthySnapshot(let snap, let reason) = disposition {
			XCTAssertEqual(snap.status, .running)
			XCTAssertEqual(reason, .instructionDelivered)
		} else {
			XCTFail("Expected cached instruction-delivered wake, got \(disposition)")
		}

		let consumedDisposition = await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 0)
		XCTAssertEqual(consumedDisposition, .timedOut)
		await store.cleanup(sessionID: sessionID)
	}

	func testSteeringRequestedWakeResumesCurrentWaiterButIsNotSticky() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		let waiter = Task {
			await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 5)
		}
		try? await Task.sleep(nanoseconds: 50_000_000)
		await store.wakeCurrentWaiters(
			makeSnapshot(sessionID: sessionID, status: .running),
			reason: .steeringRequested
		)

		let disposition = await waiter.value
		if case .noteworthySnapshot(let snap, let reason) = disposition {
			XCTAssertEqual(snap.status, .running)
			XCTAssertEqual(reason, .steeringRequested)
		} else {
			XCTFail("Expected current steering-requested wake, got \(disposition)")
		}

		await store.wakeCurrentWaiters(
			makeSnapshot(sessionID: sessionID, status: .running),
			reason: .steeringRequested
		)
		let futureDisposition = await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 0)
		XCTAssertEqual(futureDisposition, .timedOut)
		await store.cleanup(sessionID: sessionID)
	}

	func testTerminalSnapshotWinsOverLateInstructionDeliveredWake() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running, updatedAt: Date(timeIntervalSince1970: 1)))

		let waiter = Task {
			await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 5)
		}
		try? await Task.sleep(nanoseconds: 50_000_000)

		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .completed, updatedAt: Date(timeIntervalSince1970: 2)))
		await store.noteSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: sessionID, status: .running, updatedAt: Date(timeIntervalSince1970: 3)),
			reason: .instructionDelivered
		)

		let disposition = await waiter.value
		if case .snapshotReady(let snap) = disposition {
			XCTAssertEqual(snap.status, .completed)
		} else {
			XCTFail("Expected terminal .snapshotReady, got \(disposition)")
		}
		let storedSnapshot = await store.snapshot(for: sessionID)
		XCTAssertEqual(storedSnapshot?.status, .completed)
		await store.cleanup(sessionID: sessionID)
	}

	func testCleanupExpiresWaitingCallers() async {
		let sessionID = UUID()
		await AgentRunSessionStore.register(sessionID: sessionID)

		let waiter = Task {
			await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID)
		}
		await AgentRunSessionStore.cleanup(sessionID: sessionID)

		let disposition = await waiter.value
		XCTAssertEqual(disposition, .expired)
		let storedSnapshot = await AgentRunSessionStore.snapshot(for: sessionID)
		XCTAssertNil(storedSnapshot)
	}

	func testTerminalSnapshotIgnoresOlderFollowUpSnapshots() async {
		let sessionID = UUID()
		await AgentRunSessionStore.register(sessionID: sessionID)

		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: sessionID, status: .completed, updatedAt: Date(timeIntervalSince1970: 2))
		)
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: sessionID, status: .running, updatedAt: Date(timeIntervalSince1970: 1))
		)

		let storedSnapshot = await AgentRunSessionStore.snapshot(for: sessionID)
		XCTAssertEqual(storedSnapshot?.status, .completed)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testRegisterResetsTerminalSnapshotForReusedSession() async {
		let sessionID = UUID()
		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .completed))

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		let storedSnapshot = await AgentRunSessionStore.snapshot(for: sessionID)
		XCTAssertEqual(storedSnapshot?.status, .running)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testStaleExpiryGenerationDoesNotRetireReRegisteredSession() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .completed))
		guard let staleGeneration = await store.test_generation(sessionID: sessionID) else {
			return XCTFail("Expected generation for registered session")
		}

		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		let waiter = Task {
			await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 1)
		}
		try? await Task.sleep(nanoseconds: 20_000_000)

		await store.test_expire(sessionID: sessionID, generation: staleGeneration)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .waitingForInput))

		let disposition = await waiter.value
		if case .snapshotReady(let snap) = disposition {
			XCTAssertEqual(snap.status, .waitingForInput)
		} else {
			XCTFail("Expected .snapshotReady, got \(disposition)")
		}
		let storedSnapshot = await store.snapshot(for: sessionID)
		XCTAssertEqual(storedSnapshot?.status, .waitingForInput)
		await store.cleanup(sessionID: sessionID)
	}

	// MARK: - Timeout tests

	func testWaitWithTimeoutReturnsTimedOutWhenNothingInteresting() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		let disposition = await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 0.1)
		XCTAssertEqual(disposition, .timedOut)

		let waiterCount = await store.test_waiterCount(sessionID: sessionID)
		XCTAssertEqual(waiterCount, 0)
		await store.cleanup(sessionID: sessionID)
	}

	func testWaitWithZeroTimeoutReturnsImmediately() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		let disposition = await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 0)
		XCTAssertEqual(disposition, .timedOut)

		let waiterCount = await store.test_waiterCount(sessionID: sessionID)
		XCTAssertEqual(waiterCount, 0)
		await store.cleanup(sessionID: sessionID)
	}

	func testWaitWithTimeoutStillWakesOnInterestingSnapshot() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		let waiter = Task {
			await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 60)
		}
		try? await Task.sleep(nanoseconds: 50_000_000)

		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .waitingForInput))

		let disposition = await waiter.value
		if case .snapshotReady(let snap) = disposition {
			XCTAssertEqual(snap.status, .waitingForInput)
		} else {
			XCTFail("Expected .snapshotReady, got \(disposition)")
		}

		let waiterCount = await store.test_waiterCount(sessionID: sessionID)
		XCTAssertEqual(waiterCount, 0)
		await store.cleanup(sessionID: sessionID)
	}

	func testCleanupDuringTimedWaitReturnsExpired() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		let waiter = Task {
			await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 60)
		}
		try? await Task.sleep(nanoseconds: 50_000_000)

		await store.cleanup(sessionID: sessionID)

		let disposition = await waiter.value
		XCTAssertEqual(disposition, .expired)
	}

	func testWaitWithTimeoutOnAlreadyInterestingReturnsImmediately() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .waitingForInput))

		let disposition = await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 5)
		if case .snapshotReady(let snap) = disposition {
			XCTAssertEqual(snap.status, .waitingForInput)
		} else {
			XCTFail("Expected .snapshotReady, got \(disposition)")
		}

		let waiterCount = await store.test_waiterCount(sessionID: sessionID)
		XCTAssertEqual(waiterCount, 0)
		await store.cleanup(sessionID: sessionID)
	}

	func testCleanupPreventsLateSnapshotsFromRecreatingSessionState() async {
		let sessionID = UUID()
		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)

		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		let storedSnapshot = await AgentRunSessionStore.snapshot(for: sessionID)
		XCTAssertNil(storedSnapshot)
	}

	func testResetSnapshotForNewTurnAllowsWaiterToBlockOnRestartedRun() async {
		let store = AgentRunSessionStore.shared
		let sessionID = UUID()
		await store.register(sessionID: sessionID)

		// Simulate a completed first run.
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .completed))
		let storedBefore = await store.snapshot(for: sessionID)
		XCTAssertEqual(storedBefore?.status, .completed)

		// Reset the epoch for a new run, then signal running.
		await store.resetSnapshotForNewTurn(sessionID: sessionID)
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .running))

		// A waiter should now block, not return the old completed snapshot.
		let waiter = Task {
			await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 5)
		}
		// Give the waiter time to register.
		try? await Task.sleep(nanoseconds: 50_000_000)

		// Signal an interesting state from the new run.
		await store.noteSnapshot(makeSnapshot(sessionID: sessionID, status: .waitingForInput))

		let disposition = await waiter.value
		if case .snapshotReady(let snap) = disposition {
			XCTAssertEqual(snap.status, .waitingForInput)
		} else {
			XCTFail("Expected .snapshotReady(.waitingForInput), got \(disposition)")
		}

		await store.cleanup(sessionID: sessionID)
	}

	private func makeSnapshot(
		sessionID: UUID,
		status: AgentRunMCPSnapshot.Status,
		updatedAt: Date = Date(),
		interaction: AgentRunMCPSnapshot.Interaction? = nil
	) -> AgentRunMCPSnapshot {
		// When status is waitingForInput, supply a default interaction so the
		// store's wake predicate (interaction != nil || terminal) fires correctly.
		let resolvedInteraction = interaction ?? (status == .waitingForInput ? Self.defaultInteraction : nil)
		return AgentRunMCPSnapshot(
			sessionID: sessionID,
			tabID: UUID(),
			sessionName: nil,
			agentRaw: DiscoverAgentKind.claudeCode.rawValue,
			agentDisplayName: DiscoverAgentKind.claudeCode.displayName,
			modelRaw: AgentModel.defaultModel.rawValue,
			reasoningEffortRaw: nil,
			status: status,
			statusText: nil,
			latestAssistantPreview: nil,
			interaction: resolvedInteraction,
			transcriptItemCount: 0,
			updatedAt: updatedAt,
			parentSessionID: nil,
			failureReason: nil
		)
	}

	private static let defaultInteraction = AgentRunMCPSnapshot.Interaction(
		id: UUID(),
		kind: .instruction,
		responseType: .text,
		title: "Test",
		prompt: "test prompt",
		context: nil,
		allowsMultiple: nil,
		options: [],
		fields: [],
		details: []
	)
}
