import Foundation

actor AgentRunSessionStore {
	static let shared = AgentRunSessionStore()

	enum WaitDisposition: Sendable, Equatable {
		case snapshotReady(AgentRunMCPSnapshot)
		case noteworthySnapshot(AgentRunMCPSnapshot, WakeReason)
		case timedOut
		case expired
		case cancelled
	}

	enum WakeReason: String, Sendable, Equatable {
		case instructionDelivered = "instruction_delivered"
		/// A steering request was accepted locally. This wakes only currently-blocked
		/// waits so the caller can issue a fresh wait for post-steer progress.
		case steeringRequested = "steering_requested"
	}

	private struct Waiter {
		let id: UUID
		let continuation: CheckedContinuation<WaitDisposition, Never>
		let timeoutTask: Task<Void, Never>?
	}

	private struct Record {
		var generation: UInt64 = 0
		var latestSnapshot: AgentRunMCPSnapshot?
		var pendingNoteworthySnapshot: AgentRunMCPSnapshot?
		var pendingWakeReason: WakeReason?
		var waiters: [Waiter] = []
		var expiryTask: Task<Void, Never>?
	}

	private static let terminalSnapshotTTL: TimeInterval = 300

	private var records: [UUID: Record] = [:]
	private var retiredSessionIDs: Set<UUID> = []
	private var nextGeneration: UInt64 = 1

	func register(sessionID: UUID) {
		retiredSessionIDs.remove(sessionID)
		var record = records[sessionID] ?? Record()
		record.expiryTask?.cancel()
		record.expiryTask = nil
		record.generation = nextGeneration
		nextGeneration &+= 1
		record.latestSnapshot = nil
		record.pendingNoteworthySnapshot = nil
		record.pendingWakeReason = nil
		records[sessionID] = record
	}

	/// Clears the stored snapshot for a session so that a freshly dispatched turn's
	/// running/waiting snapshots are not blocked by a stale terminal snapshot from
	/// a previous turn.  Does not affect waiters, generation, or expiry scheduling.
	func resetSnapshotForNewTurn(sessionID: UUID) {
		guard var record = records[sessionID] else { return }
		record.latestSnapshot = nil
		record.pendingNoteworthySnapshot = nil
		record.pendingWakeReason = nil
		record.expiryTask?.cancel()
		record.expiryTask = nil
		records[sessionID] = record
	}

	func noteSnapshot(_ snapshot: AgentRunMCPSnapshot) {
		ingestSnapshot(snapshot, wakeReason: nil)
	}

	func noteSnapshotAndWakeWaiters(_ snapshot: AgentRunMCPSnapshot, reason: WakeReason) {
		ingestSnapshot(snapshot, wakeReason: reason)
	}

	func wakeCurrentWaiters(_ snapshot: AgentRunMCPSnapshot, reason: WakeReason) {
		guard !retiredSessionIDs.contains(snapshot.sessionID) else {
			print("[AgentRunSteeringWake] store wake ignored retired sessionID=\(snapshot.sessionID) reason=\(reason.rawValue)")
			return
		}
		var record = records[snapshot.sessionID] ?? Record()
		print("[AgentRunSteeringWake] store wake requested sessionID=\(snapshot.sessionID) reason=\(reason.rawValue) status=\(snapshot.status.rawValue) waiters=\(record.waiters.count) pending=\(record.pendingWakeReason?.rawValue ?? "none") latest=\(record.latestSnapshot?.status.rawValue ?? "none")")
		if let latestSnapshot = record.latestSnapshot {
			if latestSnapshot.status.isTerminal {
				print("[AgentRunSteeringWake] store wake ignored terminal latest sessionID=\(snapshot.sessionID) latest=\(latestSnapshot.status.rawValue)")
				return
			}
			if !snapshot.status.isTerminal, latestSnapshot.updatedAt > snapshot.updatedAt {
				record.latestSnapshot = latestSnapshot
			} else {
				record.latestSnapshot = snapshot
			}
		} else {
			record.latestSnapshot = snapshot
		}
		let waiters = record.waiters
		guard !waiters.isEmpty else {
			records[snapshot.sessionID] = record
			print("[AgentRunSteeringWake] store wake no current waiters sessionID=\(snapshot.sessionID) reason=\(reason.rawValue)")
			return
		}
		record.waiters.removeAll()
		records[snapshot.sessionID] = record
		let returnedSnapshot = record.latestSnapshot ?? snapshot
		print("[AgentRunSteeringWake] store wake resuming waiters sessionID=\(snapshot.sessionID) reason=\(reason.rawValue) count=\(waiters.count) returnedStatus=\(returnedSnapshot.status.rawValue)")
		for waiter in waiters {
			waiter.timeoutTask?.cancel()
			waiter.continuation.resume(returning: .noteworthySnapshot(returnedSnapshot, reason))
		}
	}

	private func ingestSnapshot(_ snapshot: AgentRunMCPSnapshot, wakeReason: WakeReason?) {
		guard !retiredSessionIDs.contains(snapshot.sessionID) else { return }
		var record = records[snapshot.sessionID] ?? Record()
		var acceptedSnapshot = snapshot
		var shouldStoreIncomingSnapshot = true
		if let latestSnapshot = record.latestSnapshot {
			if latestSnapshot.status.isTerminal {
				// Terminal snapshots block later non-terminal regressions.
				// Allow newer terminal snapshots to refine status text / counts.
				if !(snapshot.status.isTerminal && snapshot.updatedAt >= latestSnapshot.updatedAt) {
					acceptedSnapshot = latestSnapshot
					shouldStoreIncomingSnapshot = false
				}
			} else if !snapshot.status.isTerminal, latestSnapshot.updatedAt > snapshot.updatedAt {
				// Non-terminal: reject older non-terminal snapshots (terminal always wins).
				acceptedSnapshot = latestSnapshot
				shouldStoreIncomingSnapshot = false
			}
		}
		if shouldStoreIncomingSnapshot {
			record.latestSnapshot = snapshot
			if snapshot.isActionableForMCPWait {
				record.pendingNoteworthySnapshot = nil
				record.pendingWakeReason = nil
			}
		}

		let waiterDisposition: WaitDisposition? = {
			if acceptedSnapshot.isActionableForMCPWait {
				return .snapshotReady(acceptedSnapshot)
			}
			if let wakeReason {
				return .noteworthySnapshot(acceptedSnapshot, wakeReason)
			}
			return nil
		}()
		let waiters = waiterDisposition == nil ? [] : record.waiters
		if waiterDisposition != nil {
			record.waiters.removeAll()
		}
		if case .noteworthySnapshot = waiterDisposition, waiters.isEmpty {
			record.pendingNoteworthySnapshot = acceptedSnapshot
			record.pendingWakeReason = wakeReason
		} else if waiterDisposition != nil {
			record.pendingNoteworthySnapshot = nil
			record.pendingWakeReason = nil
		}

		if shouldStoreIncomingSnapshot, snapshot.status.isTerminal {
			record.expiryTask?.cancel()
			let generation = record.generation
			record.expiryTask = Task { [sessionID = snapshot.sessionID, generation] in
				do {
					try await Task.sleep(nanoseconds: UInt64(Self.terminalSnapshotTTL * 1_000_000_000))
					await Self.shared.expire(sessionID: sessionID, generation: generation)
				} catch {
					// Ignore cancellation.
				}
			}
		}

		records[snapshot.sessionID] = record

		if let waiterDisposition {
			for waiter in waiters {
				waiter.timeoutTask?.cancel()
				waiter.continuation.resume(returning: waiterDisposition)
			}
		}
	}

	func waitUntilInteresting(sessionID: UUID, timeoutSeconds: TimeInterval? = nil) async -> WaitDisposition {
		guard let record = records[sessionID] else {
			print("[AgentRunSteeringWake] store wait expired missing record sessionID=\(sessionID)")
			return .expired
		}
		if let snapshot = record.latestSnapshot,
			snapshot.isActionableForMCPWait {
			print("[AgentRunSteeringWake] store wait immediate snapshot sessionID=\(sessionID) status=\(snapshot.status.rawValue) interaction=\(snapshot.interaction != nil)")
			return .snapshotReady(snapshot)
		}
		if let snapshot = record.pendingNoteworthySnapshot,
			let reason = record.pendingWakeReason {
			let returnedSnapshot = record.latestSnapshot ?? snapshot
			var updated = record
			updated.pendingNoteworthySnapshot = nil
			updated.pendingWakeReason = nil
			records[sessionID] = updated
			print("[AgentRunSteeringWake] store wait consumed pending wake sessionID=\(sessionID) reason=\(reason.rawValue) returnedStatus=\(returnedSnapshot.status.rawValue)")
			return .noteworthySnapshot(returnedSnapshot, reason)
		}
		if let timeout = timeoutSeconds, timeout <= 0 {
			print("[AgentRunSteeringWake] store wait timed out immediately sessionID=\(sessionID)")
			return .timedOut
		}

		let waiterID = UUID()
		print("[AgentRunSteeringWake] store wait registering waiter sessionID=\(sessionID) waiterID=\(waiterID) timeout=\(timeoutSeconds.map { String($0) } ?? "none") latest=\(record.latestSnapshot?.status.rawValue ?? "none") existingWaiters=\(record.waiters.count)")
		return await withTaskCancellationHandler {
			await withCheckedContinuation { (continuation: CheckedContinuation<WaitDisposition, Never>) in
				guard var current = records[sessionID] else {
					print("[AgentRunSteeringWake] store wait continuation expired missing record sessionID=\(sessionID) waiterID=\(waiterID)")
					continuation.resume(returning: .expired)
					return
				}
				if let snapshot = current.latestSnapshot,
					snapshot.isActionableForMCPWait {
					print("[AgentRunSteeringWake] store wait continuation immediate snapshot sessionID=\(sessionID) waiterID=\(waiterID) status=\(snapshot.status.rawValue)")
					continuation.resume(returning: .snapshotReady(snapshot))
					return
				}
				if let snapshot = current.pendingNoteworthySnapshot,
					let reason = current.pendingWakeReason {
					let returnedSnapshot = current.latestSnapshot ?? snapshot
					current.pendingNoteworthySnapshot = nil
					current.pendingWakeReason = nil
					records[sessionID] = current
					print("[AgentRunSteeringWake] store wait continuation consumed pending wake sessionID=\(sessionID) waiterID=\(waiterID) reason=\(reason.rawValue) returnedStatus=\(returnedSnapshot.status.rawValue)")
					continuation.resume(returning: .noteworthySnapshot(returnedSnapshot, reason))
					return
				}
				var timeoutTask: Task<Void, Never>?
				if let timeout = timeoutSeconds {
					timeoutTask = Task { [weak self] in
						do {
							try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
							await self?.timeoutWaiter(sessionID: sessionID, waiterID: waiterID)
						} catch {
							// Cancelled — snapshot or cleanup woke the waiter first.
						}
					}
				}
				current.waiters.append(Waiter(id: waiterID, continuation: continuation, timeoutTask: timeoutTask))
				print("[AgentRunSteeringWake] store wait waiter parked sessionID=\(sessionID) waiterID=\(waiterID) waiters=\(current.waiters.count)")
				records[sessionID] = current
			}
		} onCancel: {
			Task { await self.cancelWaiter(sessionID: sessionID, waiterID: waiterID) }
		}
	}

	func snapshot(for sessionID: UUID) -> AgentRunMCPSnapshot? {
		records[sessionID]?.latestSnapshot
	}

	func cleanup(sessionID: UUID) {
		retiredSessionIDs.insert(sessionID)
		guard let record = records.removeValue(forKey: sessionID) else { return }
		record.expiryTask?.cancel()
		for waiter in record.waiters {
			waiter.timeoutTask?.cancel()
			waiter.continuation.resume(returning: .expired)
		}
	}

	private func cancelWaiter(sessionID: UUID, waiterID: UUID) {
		guard var record = records[sessionID],
			let index = record.waiters.firstIndex(where: { $0.id == waiterID })
		else {
			print("[AgentRunSteeringWake] store wait cancel ignored sessionID=\(sessionID) waiterID=\(waiterID)")
			return
		}
		let waiter = record.waiters.remove(at: index)
		records[sessionID] = record
		waiter.timeoutTask?.cancel()
		print("[AgentRunSteeringWake] store wait cancelled sessionID=\(sessionID) waiterID=\(waiterID) remaining=\(record.waiters.count)")
		waiter.continuation.resume(returning: .cancelled)
	}

	private func timeoutWaiter(sessionID: UUID, waiterID: UUID) {
		guard var record = records[sessionID],
			let index = record.waiters.firstIndex(where: { $0.id == waiterID })
		else {
			print("[AgentRunSteeringWake] store wait timeout ignored sessionID=\(sessionID) waiterID=\(waiterID)")
			return
		}
		let waiter = record.waiters.remove(at: index)
		records[sessionID] = record
		print("[AgentRunSteeringWake] store wait timed out sessionID=\(sessionID) waiterID=\(waiterID) remaining=\(record.waiters.count)")
		waiter.continuation.resume(returning: .timedOut)
	}

	private func expire(sessionID: UUID, generation: UInt64) {
		guard let record = records[sessionID], record.generation == generation else { return }
		retiredSessionIDs.insert(sessionID)
		guard let expiredRecord = records.removeValue(forKey: sessionID) else { return }
		for waiter in expiredRecord.waiters {
			waiter.timeoutTask?.cancel()
			waiter.continuation.resume(returning: .expired)
		}
	}
}

extension AgentRunSessionStore {
	static func register(sessionID: UUID) async {
		await shared.register(sessionID: sessionID)
	}

	static func noteSnapshot(_ snapshot: AgentRunMCPSnapshot) async {
		await shared.noteSnapshot(snapshot)
	}

	static func noteSnapshotAndWakeWaiters(_ snapshot: AgentRunMCPSnapshot, reason: WakeReason) async {
		await shared.noteSnapshotAndWakeWaiters(snapshot, reason: reason)
	}

	static func waitUntilInteresting(sessionID: UUID, timeoutSeconds: TimeInterval? = nil) async -> WaitDisposition {
		await shared.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: timeoutSeconds)
	}

	static func snapshot(for sessionID: UUID) async -> AgentRunMCPSnapshot? {
		await shared.snapshot(for: sessionID)
	}

	static func cleanup(sessionID: UUID) async {
		await shared.cleanup(sessionID: sessionID)
	}
}

extension AgentRunSessionStore {
	static func signalSnapshot(_ snapshot: AgentRunMCPSnapshot) async {
		await shared.noteSnapshot(snapshot)
	}

	static func signalSnapshotAndWakeWaiters(_ snapshot: AgentRunMCPSnapshot, reason: WakeReason) async {
		await shared.noteSnapshotAndWakeWaiters(snapshot, reason: reason)
	}

	static func wakeCurrentWaiters(_ snapshot: AgentRunMCPSnapshot, reason: WakeReason) async {
		await shared.wakeCurrentWaiters(snapshot, reason: reason)
	}

	static func resetSnapshotForNewTurn(sessionID: UUID) async {
		await shared.resetSnapshotForNewTurn(sessionID: sessionID)
	}
}

#if DEBUG
extension AgentRunSessionStore {
	func test_waiterCount(sessionID: UUID) -> Int {
		records[sessionID]?.waiters.count ?? 0
	}

	func test_generation(sessionID: UUID) -> UInt64? {
		records[sessionID]?.generation
	}

	func test_expire(sessionID: UUID, generation: UInt64) {
		expire(sessionID: sessionID, generation: generation)
	}
}
#endif
