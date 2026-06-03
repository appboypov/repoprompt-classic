#if DEBUG
import Darwin
import Foundation

struct DebugProcessMemorySnapshot: Sendable {
	let timestampMS: Double
	let residentBytes: UInt64
	let physicalFootprintBytes: UInt64?

	var residentMB: Double {
		Self.megabytes(residentBytes)
	}

	var physicalFootprintMB: Double? {
		physicalFootprintBytes.map(Self.megabytes)
	}

	func payload() -> [String: Any] {
		[
			"timestamp_ms": Self.round(timestampMS),
			"resident_bytes": NSNumber(value: residentBytes),
			"resident_mb": Self.round(residentMB),
			"physical_footprint_bytes": physicalFootprintBytes.map { NSNumber(value: $0) } ?? NSNull(),
			"physical_footprint_mb": physicalFootprintMB.map(Self.round) ?? NSNull()
		]
	}

	static func megabytes(_ bytes: UInt64) -> Double {
		Double(bytes) / 1_048_576.0
	}

	static func round(_ value: Double) -> Double {
		(value * 10.0).rounded() / 10.0
	}
}

struct DebugProcessMemoryMark: Sendable {
	let name: String
	let timestampMS: Double
	let sampleIndex: Int
	let snapshot: DebugProcessMemorySnapshot

	func payload() -> [String: Any] {
		[
			"name": name,
			"timestamp_ms": DebugProcessMemorySnapshot.round(timestampMS),
			"sample_index": sampleIndex,
			"resident_mb": DebugProcessMemorySnapshot.round(snapshot.residentMB),
			"physical_footprint_mb": snapshot.physicalFootprintMB.map(DebugProcessMemorySnapshot.round) ?? NSNull()
		]
	}
}

actor DebugProcessMemorySampler {
	static let shared = DebugProcessMemorySampler()

	private let maxSamples = 20_000
	private var activeSession: ActiveSession?
	private var sampleTask: Task<Void, Never>?
	private var lastCompletedSession: CompletedSession?

	func start(label: String, intervalMS: Int, reset: Bool) async -> DebugMemorySamplerResponse {
		if activeSession != nil {
			guard reset else {
				return .error(code: "already_running", message: "A large workspace memory sampling session is already running. Pass `reset: true` to replace it.")
			}
			await resetActiveSession()
		}

		guard let baseline = Self.captureSnapshot() else {
			return .error(code: "memory_snapshot_failed", message: "Unable to capture current process memory.")
		}

		let session = ActiveSession(
			id: UUID(),
			label: label,
			intervalMS: intervalMS,
			startedMS: baseline.timestampMS,
			baseline: baseline,
			peak: baseline,
			peakPhysicalFootprint: baseline.physicalFootprintBytes == nil ? nil : baseline,
			final: baseline,
			samples: [baseline],
			marks: [],
			firstSwitchReturnedPeak: nil,
			firstSwitchReturnedPeakPhysicalFootprint: nil
		)
		activeSession = session
		lastCompletedSession = nil

		let sessionID = session.id
		sampleTask = Task { [weak self] in
			await self?.runSamplingLoop(sessionID: sessionID, intervalMS: intervalMS)
		}

		return .payload(payload(for: session, action: "start", running: true, includeSamplesLimit: 1))
	}

	func mark(_ name: String) async -> DebugMemorySamplerResponse {
		guard var session = activeSession else {
			return .error(code: "no_active_session", message: "No large workspace memory sampling session is active.")
		}
		guard let snapshot = Self.captureSnapshot() else {
			return .error(code: "memory_snapshot_failed", message: "Unable to capture current process memory.")
		}

		record(snapshot: snapshot, in: &session)
		let mark = DebugProcessMemoryMark(
			name: name,
			timestampMS: snapshot.timestampMS,
			sampleIndex: session.totalSampleCount - 1,
			snapshot: snapshot
		)
		session.marks.append(mark)
		if name == "switch_returned", session.firstSwitchReturnedPeak == nil {
			session.firstSwitchReturnedPeak = session.peak
			session.firstSwitchReturnedPeakPhysicalFootprint = session.peakPhysicalFootprint
		}
		activeSession = session

		var result = payload(for: session, action: "mark", running: true, includeSamplesLimit: 1)
		result["mark"] = mark.payload()
		return .payload(result)
	}

	func stop(settleSeconds: Double) async -> DebugMemorySamplerResponse {
		guard var session = activeSession else {
			if let lastCompletedSession {
				return .payload(payload(for: lastCompletedSession, action: "stop", running: false, includeSamplesLimit: 50))
			}
			return .error(code: "no_active_session", message: "No large workspace memory sampling session is active.")
		}

		if settleSeconds > 0 {
			try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000.0))
			if let updated = activeSession, updated.id == session.id {
				session = updated
			}
		}

		if let finalSnapshot = Self.captureSnapshot() {
			record(snapshot: finalSnapshot, in: &session)
			session.final = finalSnapshot
		}

		sampleTask?.cancel()
		sampleTask = nil
		activeSession = nil

		let completed = CompletedSession(session: session)
		lastCompletedSession = completed
		return .payload(payload(for: completed, action: "stop", running: false, includeSamplesLimit: 50))
	}

	func snapshot(limit: Int) async -> DebugMemorySamplerResponse {
		if let activeSession {
			return .payload(payload(for: activeSession, action: "snapshot", running: true, includeSamplesLimit: limit))
		}
		if let lastCompletedSession {
			return .payload(payload(for: lastCompletedSession, action: "snapshot", running: false, includeSamplesLimit: limit))
		}
		return .error(code: "no_session", message: "No active or completed large workspace memory sampling session is available.")
	}

	func current(limit: Int) async -> DebugMemorySamplerResponse {
		guard let snapshot = Self.captureSnapshot() else {
			return .error(code: "memory_snapshot_failed", message: "Unable to capture current process memory.")
		}
		var result: [String: Any] = [
			"ok": true,
			"op": "large_workspace_memory",
			"action": "current",
			"running": activeSession != nil,
			"current": snapshot.payload(),
			"phys_footprint_available": snapshot.physicalFootprintBytes != nil
		]
		if let activeSession {
			result["session"] = sessionPayload(for: activeSession, running: true)
			result["metrics"] = metricsPayload(for: activeSession)
			result["recent_samples"] = activeSession.samples.suffix(limit).map { $0.payload() }
		} else if let lastCompletedSession {
			result["last_completed_session"] = sessionPayload(for: lastCompletedSession, running: false)
		}
		return .payload(result)
	}

	func reset() async -> DebugMemorySamplerResponse {
		await resetActiveSession()
		lastCompletedSession = nil
		return .payload([
			"ok": true,
			"op": "large_workspace_memory",
			"action": "reset",
			"running": false
		])
	}

	private func resetActiveSession() async {
		sampleTask?.cancel()
		sampleTask = nil
		activeSession = nil
	}

	private func runSamplingLoop(sessionID: UUID, intervalMS: Int) async {
		let intervalNanoseconds = UInt64(intervalMS) * 1_000_000
		while !Task.isCancelled {
			try? await Task.sleep(nanoseconds: intervalNanoseconds)
			if Task.isCancelled { break }
			await recordPeriodicSample(sessionID: sessionID)
		}
	}

	private func recordPeriodicSample(sessionID: UUID) {
		guard var session = activeSession, session.id == sessionID else { return }
		guard let snapshot = Self.captureSnapshot() else { return }
		record(snapshot: snapshot, in: &session)
		activeSession = session
	}

	private func record(snapshot: DebugProcessMemorySnapshot, in session: inout ActiveSession) {
		session.totalSampleCount += 1
		session.final = snapshot
		if snapshot.residentBytes > session.peak.residentBytes {
			session.peak = snapshot
		}
		if let snapshotFootprint = snapshot.physicalFootprintBytes {
			if let peakFootprint = session.peakPhysicalFootprint?.physicalFootprintBytes {
				if snapshotFootprint > peakFootprint {
					session.peakPhysicalFootprint = snapshot
				}
			} else {
				session.peakPhysicalFootprint = snapshot
			}
		}
		session.samples.append(snapshot)
		if session.samples.count > maxSamples {
			session.samples.removeFirst(session.samples.count - maxSamples)
		}
	}

	private func payload(for session: ActiveSession, action: String, running: Bool, includeSamplesLimit: Int) -> [String: Any] {
		[
			"ok": true,
			"op": "large_workspace_memory",
			"action": action,
			"running": running,
			"session": sessionPayload(for: session, running: running),
			"metrics": metricsPayload(for: session),
			"baseline": session.baseline.payload(),
			"peak": session.peak.payload(),
			"peak_physical_footprint": session.peakPhysicalFootprint?.payload() ?? NSNull(),
			"final": session.final.payload(),
			"marks": session.marks.map { $0.payload() },
			"recent_samples": session.samples.suffix(includeSamplesLimit).map { $0.payload() }
		]
	}

	private func payload(for session: CompletedSession, action: String, running: Bool, includeSamplesLimit: Int) -> [String: Any] {
		[
			"ok": true,
			"op": "large_workspace_memory",
			"action": action,
			"running": running,
			"session": sessionPayload(for: session, running: running),
			"metrics": metricsPayload(for: session),
			"baseline": session.baseline.payload(),
			"peak": session.peak.payload(),
			"peak_physical_footprint": session.peakPhysicalFootprint?.payload() ?? NSNull(),
			"final": session.final.payload(),
			"marks": session.marks.map { $0.payload() },
			"recent_samples": session.samples.suffix(includeSamplesLimit).map { $0.payload() }
		]
	}

	private func sessionPayload(for session: ActiveSession, running: Bool) -> [String: Any] {
		[
			"id": session.id.uuidString,
			"label": session.label,
			"interval_ms": session.intervalMS,
			"started_ms": DebugProcessMemorySnapshot.round(session.startedMS),
			"duration_seconds": DebugProcessMemorySnapshot.round((session.final.timestampMS - session.startedMS) / 1_000.0),
			"sample_count": session.totalSampleCount,
			"stored_sample_count": session.samples.count,
			"running": running,
			"phys_footprint_available": session.physicalFootprintAvailable
		]
	}

	private func sessionPayload(for session: CompletedSession, running: Bool) -> [String: Any] {
		[
			"id": session.id.uuidString,
			"label": session.label,
			"interval_ms": session.intervalMS,
			"started_ms": DebugProcessMemorySnapshot.round(session.startedMS),
			"duration_seconds": DebugProcessMemorySnapshot.round((session.final.timestampMS - session.startedMS) / 1_000.0),
			"sample_count": session.totalSampleCount,
			"stored_sample_count": session.samples.count,
			"running": running,
			"phys_footprint_available": session.physicalFootprintAvailable
		]
	}

	private func metricsPayload(for session: ActiveSession) -> [String: Any] {
		metricsPayload(
			baseline: session.baseline,
			peak: session.peak,
			peakPhysicalFootprint: session.peakPhysicalFootprint,
			final: session.final,
			marks: session.marks,
			firstSwitchReturnedPeak: session.firstSwitchReturnedPeak,
			firstSwitchReturnedPeakPhysicalFootprint: session.firstSwitchReturnedPeakPhysicalFootprint,
			sampleCount: session.totalSampleCount,
			durationSeconds: (session.final.timestampMS - session.startedMS) / 1_000.0,
			physFootprintAvailable: session.physicalFootprintAvailable
		)
	}

	private func metricsPayload(for session: CompletedSession) -> [String: Any] {
		metricsPayload(
			baseline: session.baseline,
			peak: session.peak,
			peakPhysicalFootprint: session.peakPhysicalFootprint,
			final: session.final,
			marks: session.marks,
			firstSwitchReturnedPeak: session.firstSwitchReturnedPeak,
			firstSwitchReturnedPeakPhysicalFootprint: session.firstSwitchReturnedPeakPhysicalFootprint,
			sampleCount: session.totalSampleCount,
			durationSeconds: (session.final.timestampMS - session.startedMS) / 1_000.0,
			physFootprintAvailable: session.physicalFootprintAvailable
		)
	}

	private func metricsPayload(
		baseline: DebugProcessMemorySnapshot,
		peak: DebugProcessMemorySnapshot,
		peakPhysicalFootprint: DebugProcessMemorySnapshot?,
		final: DebugProcessMemorySnapshot,
		marks: [DebugProcessMemoryMark],
		firstSwitchReturnedPeak: DebugProcessMemorySnapshot?,
		firstSwitchReturnedPeakPhysicalFootprint: DebugProcessMemorySnapshot?,
		sampleCount: Int,
		durationSeconds: Double,
		physFootprintAvailable: Bool
	) -> [String: Any] {
		var metrics: [String: Any] = [
			"baseline_resident_mb": DebugProcessMemorySnapshot.round(baseline.residentMB),
			"peak_resident_mb": DebugProcessMemorySnapshot.round(peak.residentMB),
			"peak_resident_delta_mb": DebugProcessMemorySnapshot.round(peak.residentMB - baseline.residentMB),
			"final_resident_mb": DebugProcessMemorySnapshot.round(final.residentMB),
			"retained_resident_delta_mb": DebugProcessMemorySnapshot.round(final.residentMB - baseline.residentMB),
			"sample_count": sampleCount,
			"duration_seconds": DebugProcessMemorySnapshot.round(durationSeconds),
			"phys_footprint_available": physFootprintAvailable
		]

		let firstSwitchReturnedSnapshot = marks.first { $0.name == "switch_returned" }?.snapshot
		if let firstSwitchReturnedSnapshot {
			metrics["switch_returned_resident_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedSnapshot.residentMB)
			metrics["switch_returned_resident_delta_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedSnapshot.residentMB - baseline.residentMB)
			metrics["post_switch_retained_resident_delta_mb"] = DebugProcessMemorySnapshot.round(final.residentMB - firstSwitchReturnedSnapshot.residentMB)
		} else {
			metrics["switch_returned_resident_mb"] = NSNull()
			metrics["switch_returned_resident_delta_mb"] = NSNull()
			metrics["post_switch_retained_resident_delta_mb"] = NSNull()
		}

		if let firstSwitchReturnedPeak {
			metrics["peak_until_switch_returned_resident_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedPeak.residentMB)
			metrics["peak_until_switch_returned_resident_delta_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedPeak.residentMB - baseline.residentMB)
		} else {
			metrics["peak_until_switch_returned_resident_mb"] = NSNull()
			metrics["peak_until_switch_returned_resident_delta_mb"] = NSNull()
		}

		addPhysicalFootprintMetrics(
			to: &metrics,
			baseline: baseline,
			peakPhysicalFootprint: peakPhysicalFootprint,
			final: final,
			firstSwitchReturnedSnapshot: firstSwitchReturnedSnapshot,
			firstSwitchReturnedPeakPhysicalFootprint: firstSwitchReturnedPeakPhysicalFootprint
		)
		return metrics
	}

	private func addPhysicalFootprintMetrics(
		to metrics: inout [String: Any],
		baseline: DebugProcessMemorySnapshot,
		peakPhysicalFootprint: DebugProcessMemorySnapshot?,
		final: DebugProcessMemorySnapshot,
		firstSwitchReturnedSnapshot: DebugProcessMemorySnapshot?,
		firstSwitchReturnedPeakPhysicalFootprint: DebugProcessMemorySnapshot?
	) {
		guard let baselineFootprint = baseline.physicalFootprintMB,
			let peakFootprint = peakPhysicalFootprint?.physicalFootprintMB,
			let finalFootprint = final.physicalFootprintMB else {
			metrics["baseline_physical_footprint_mb"] = NSNull()
			metrics["peak_physical_footprint_mb"] = NSNull()
			metrics["peak_physical_footprint_delta_mb"] = NSNull()
			metrics["final_physical_footprint_mb"] = NSNull()
			metrics["retained_physical_footprint_delta_mb"] = NSNull()
			metrics["switch_returned_physical_footprint_mb"] = NSNull()
			metrics["switch_returned_physical_footprint_delta_mb"] = NSNull()
			metrics["post_switch_retained_physical_footprint_delta_mb"] = NSNull()
			metrics["peak_until_switch_returned_physical_footprint_mb"] = NSNull()
			metrics["peak_until_switch_returned_physical_footprint_delta_mb"] = NSNull()
			return
		}

		metrics["baseline_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(baselineFootprint)
		metrics["peak_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(peakFootprint)
		metrics["peak_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(peakFootprint - baselineFootprint)
		metrics["final_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(finalFootprint)
		metrics["retained_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(finalFootprint - baselineFootprint)

		if let firstSwitchReturnedFootprint = firstSwitchReturnedSnapshot?.physicalFootprintMB {
			metrics["switch_returned_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedFootprint)
			metrics["switch_returned_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedFootprint - baselineFootprint)
			metrics["post_switch_retained_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(finalFootprint - firstSwitchReturnedFootprint)
		} else {
			metrics["switch_returned_physical_footprint_mb"] = NSNull()
			metrics["switch_returned_physical_footprint_delta_mb"] = NSNull()
			metrics["post_switch_retained_physical_footprint_delta_mb"] = NSNull()
		}

		if let firstSwitchReturnedFootprint = firstSwitchReturnedPeakPhysicalFootprint?.physicalFootprintMB {
			metrics["peak_until_switch_returned_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedFootprint)
			metrics["peak_until_switch_returned_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedFootprint - baselineFootprint)
		} else {
			metrics["peak_until_switch_returned_physical_footprint_mb"] = NSNull()
			metrics["peak_until_switch_returned_physical_footprint_delta_mb"] = NSNull()
		}
	}

	private static func captureSnapshot() -> DebugProcessMemorySnapshot? {
		let nowMS = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
		guard let residentBytes = captureResidentBytes() else { return nil }
		return DebugProcessMemorySnapshot(
			timestampMS: nowMS,
			residentBytes: residentBytes,
			physicalFootprintBytes: capturePhysicalFootprintBytes()
		)
	}

	private static func captureResidentBytes() -> UInt64? {
		var info = mach_task_basic_info()
		var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
		let result = withUnsafeMutablePointer(to: &info) {
			$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
			}
		}
		guard result == KERN_SUCCESS else { return nil }
		return UInt64(info.resident_size)
	}

	private static func capturePhysicalFootprintBytes() -> UInt64? {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
		let result = withUnsafeMutablePointer(to: &info) {
			$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
			}
		}
		guard result == KERN_SUCCESS else { return nil }
		return UInt64(info.phys_footprint)
	}

	enum DebugMemorySamplerResponse: Sendable {
		case payload([String: Any])
		case error(code: String, message: String)
	}

	private struct ActiveSession: Sendable {
		let id: UUID
		let label: String
		let intervalMS: Int
		let startedMS: Double
		let baseline: DebugProcessMemorySnapshot
		var peak: DebugProcessMemorySnapshot
		var peakPhysicalFootprint: DebugProcessMemorySnapshot?
		var final: DebugProcessMemorySnapshot
		var samples: [DebugProcessMemorySnapshot]
		var marks: [DebugProcessMemoryMark]
		var firstSwitchReturnedPeak: DebugProcessMemorySnapshot?
		var firstSwitchReturnedPeakPhysicalFootprint: DebugProcessMemorySnapshot?
		var totalSampleCount: Int = 1

		var physicalFootprintAvailable: Bool {
			baseline.physicalFootprintBytes != nil && samples.contains { $0.physicalFootprintBytes != nil }
		}
	}

	private struct CompletedSession: Sendable {
		let id: UUID
		let label: String
		let intervalMS: Int
		let startedMS: Double
		let baseline: DebugProcessMemorySnapshot
		let peak: DebugProcessMemorySnapshot
		let peakPhysicalFootprint: DebugProcessMemorySnapshot?
		let final: DebugProcessMemorySnapshot
		let samples: [DebugProcessMemorySnapshot]
		let marks: [DebugProcessMemoryMark]
		let firstSwitchReturnedPeak: DebugProcessMemorySnapshot?
		let firstSwitchReturnedPeakPhysicalFootprint: DebugProcessMemorySnapshot?
		let totalSampleCount: Int
		let physicalFootprintAvailable: Bool

		init(session: ActiveSession) {
			id = session.id
			label = session.label
			intervalMS = session.intervalMS
			startedMS = session.startedMS
			baseline = session.baseline
			peak = session.peak
			peakPhysicalFootprint = session.peakPhysicalFootprint
			final = session.final
			samples = session.samples
			marks = session.marks
			firstSwitchReturnedPeak = session.firstSwitchReturnedPeak
			firstSwitchReturnedPeakPhysicalFootprint = session.firstSwitchReturnedPeakPhysicalFootprint
			totalSampleCount = session.totalSampleCount
			physicalFootprintAvailable = session.physicalFootprintAvailable
		}
	}
}
#endif
