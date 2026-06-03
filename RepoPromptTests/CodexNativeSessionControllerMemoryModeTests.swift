import XCTest
@testable import RepoPrompt

final class CodexNativeSessionControllerMemoryModeTests: XCTestCase {
	func testThreadStartDisablesMemoryModeBeforeReturning() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}

		let startTask = Task {
			try await harness.controller.startOrResume(
				existing: nil,
				baseInstructions: "You are a concise assistant."
			)
		}

		let startRequest = try await waitForPayload(at: 0, in: harness.recorder)
		XCTAssertEqual(startRequest["method"] as? String, "thread/start")
		let startParams = try XCTUnwrap(startRequest["params"] as? [String: Any])
		XCTAssertNil(startParams["ephemeral"], "Persistent thread/start should retain the existing omitted wire payload")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(startRequest["id"]),
			result: threadResult(threadID: "thread-start-1")
		)

		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		XCTAssertEqual(memoryModeRequest["method"] as? String, "thread/memoryMode/set")
		let params = try XCTUnwrap(memoryModeRequest["params"] as? [String: Any])
		XCTAssertEqual(params["threadId"] as? String, "thread-start-1")
		XCTAssertEqual(params["mode"] as? String, "disabled")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(memoryModeRequest["id"]),
			result: [:]
		)

		let sessionRef = try await startTask.value
		XCTAssertEqual(sessionRef.conversationID, "thread-start-1")
		XCTAssertEqual(harness.recorder.methods(), ["thread/start", "thread/memoryMode/set"])
	}

	func testAgentModeDefaultThreadStartOmitsEphemeralFlag() async throws {
		let harness = await makeHarness(useAgentModeDefaults: true)
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}

		let startTask = Task {
			try await harness.controller.startOrResume(existing: nil, baseInstructions: "Agent instructions")
		}

		let startRequest = try await waitForPayload(at: 0, in: harness.recorder)
		let startParams = try XCTUnwrap(startRequest["params"] as? [String: Any])
		XCTAssertNil(startParams["ephemeral"])
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(startRequest["id"]),
			result: threadResult(threadID: "agent-persistent-start")
		)
		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		try await sendResult(to: harness.client, id: try XCTUnwrap(memoryModeRequest["id"]), result: [:])
		_ = try await startTask.value
	}

	func testThreadResumeDisablesMemoryModeBeforeReturning() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}

		let existing = CodexNativeSessionController.SessionRef(
			conversationID: "thread-resume-1",
			rolloutPath: "/tmp/thread-resume-1.jsonl",
			model: nil,
			reasoningEffort: nil
		)
		let resumeTask = Task {
			try await harness.controller.startOrResume(
				existing: existing,
				baseInstructions: "Ignored on resume"
			)
		}

		let resumeRequest = try await waitForPayload(at: 0, in: harness.recorder)
		XCTAssertEqual(resumeRequest["method"] as? String, "thread/resume")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(resumeRequest["id"]),
			result: threadResult(threadID: "thread-resume-1")
		)

		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		XCTAssertEqual(memoryModeRequest["method"] as? String, "thread/memoryMode/set")
		let params = try XCTUnwrap(memoryModeRequest["params"] as? [String: Any])
		XCTAssertEqual(params["threadId"] as? String, "thread-resume-1")
		XCTAssertEqual(params["mode"] as? String, "disabled")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(memoryModeRequest["id"]),
			result: [:]
		)

		let sessionRef = try await resumeTask.value
		XCTAssertEqual(sessionRef.conversationID, "thread-resume-1")
		XCTAssertEqual(harness.recorder.methods(), ["thread/resume", "thread/memoryMode/set"])
	}

	func testUnknownVariantMemoryModeSetFailureAllowsThreadStart() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}

		let startTask = Task {
			try await harness.controller.startOrResume(
				existing: nil,
				baseInstructions: "You are a concise assistant."
			)
		}

		let startRequest = try await waitForPayload(at: 0, in: harness.recorder)
		XCTAssertEqual(startRequest["method"] as? String, "thread/start")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(startRequest["id"]),
			result: threadResult(threadID: "thread-start-compat")
		)

		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		XCTAssertEqual(memoryModeRequest["method"] as? String, "thread/memoryMode/set")
		try await sendError(
			to: harness.client,
			id: try XCTUnwrap(memoryModeRequest["id"]),
			message: "unknown variant 'thread/memoryMode/set', expected one of thread/start, thread/resume"
		)

		let sessionRef = try await startTask.value
		XCTAssertEqual(sessionRef.conversationID, "thread-start-compat")
		XCTAssertTrue(harness.controller.hasActiveThread)
		XCTAssertEqual(harness.recorder.methods(), ["thread/start", "thread/memoryMode/set"])
	}

	func testUnknownMethodMemoryModeSetFailureAllowsThreadResume() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}

		let existing = CodexNativeSessionController.SessionRef(
			conversationID: "thread-resume-compat",
			rolloutPath: "/tmp/thread-resume-compat.jsonl",
			model: nil,
			reasoningEffort: nil
		)
		let resumeTask = Task {
			try await harness.controller.startOrResume(
				existing: existing,
				baseInstructions: "Ignored on resume"
			)
		}

		let resumeRequest = try await waitForPayload(at: 0, in: harness.recorder)
		XCTAssertEqual(resumeRequest["method"] as? String, "thread/resume")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(resumeRequest["id"]),
			result: threadResult(threadID: "thread-resume-compat")
		)

		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		XCTAssertEqual(memoryModeRequest["method"] as? String, "thread/memoryMode/set")
		try await sendError(
			to: harness.client,
			id: try XCTUnwrap(memoryModeRequest["id"]),
			message: "method not found: thread/memoryMode/set"
		)

		let sessionRef = try await resumeTask.value
		XCTAssertEqual(sessionRef.conversationID, "thread-resume-compat")
		XCTAssertTrue(harness.controller.hasActiveThread)
		XCTAssertEqual(harness.recorder.methods(), ["thread/resume", "thread/memoryMode/set"])
	}

	func testExperimentalUnavailableMemoryModeSetFailureAllowsThreadStart() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}

		let startTask = Task {
			try await harness.controller.startOrResume(
				existing: nil,
				baseInstructions: "You are a concise assistant."
			)
		}

		let startRequest = try await waitForPayload(at: 0, in: harness.recorder)
		XCTAssertEqual(startRequest["method"] as? String, "thread/start")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(startRequest["id"]),
			result: threadResult(threadID: "thread-start-experimental-unavailable")
		)

		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		XCTAssertEqual(memoryModeRequest["method"] as? String, "thread/memoryMode/set")
		try await sendError(
			to: harness.client,
			id: try XCTUnwrap(memoryModeRequest["id"]),
			message: "experimental API disabled for thread memory mode"
		)

		let sessionRef = try await startTask.value
		XCTAssertEqual(sessionRef.conversationID, "thread-start-experimental-unavailable")
		XCTAssertTrue(harness.controller.hasActiveThread)
		XCTAssertEqual(harness.recorder.methods(), ["thread/start", "thread/memoryMode/set"])
	}

	func testCancelCurrentTurnRetriesFoundActiveTurnIDAfterStaleInterruptMismatch() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}
		let eventTask = Task { () -> [CodexNativeSessionController.Event] in
			var events: [CodexNativeSessionController.Event] = []
			for await event in harness.controller.events {
				events.append(event)
			}
			return events
		}

		let startTask = Task {
			try await harness.controller.startOrResume(existing: nil, baseInstructions: "")
		}
		let startRequest = try await waitForPayload(at: 0, in: harness.recorder)
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(startRequest["id"]),
			result: threadResult(threadID: "thread-interrupt", status: "active", turns: [["id": "turn-old", "status": "running"]])
		)
		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		try await sendResult(to: harness.client, id: try XCTUnwrap(memoryModeRequest["id"]), result: [:])
		_ = try await startTask.value

		let cancelTask = Task {
			await harness.controller.cancelCurrentTurn()
		}
		let readRequest = try await waitForPayload(at: 2, in: harness.recorder)
		XCTAssertEqual(readRequest["method"] as? String, "thread/read")
		try await sendError(to: harness.client, id: try XCTUnwrap(readRequest["id"]), message: "thread read unavailable")

		let firstInterrupt = try await waitForPayload(at: 3, in: harness.recorder)
		XCTAssertEqual(firstInterrupt["method"] as? String, "turn/interrupt")
		let firstParams = try XCTUnwrap(firstInterrupt["params"] as? [String: Any])
		XCTAssertEqual(firstParams["threadId"] as? String, "thread-interrupt")
		XCTAssertEqual(firstParams["turnId"] as? String, "turn-old")
		try await sendError(
			to: harness.client,
			id: try XCTUnwrap(firstInterrupt["id"]),
			message: "expected active turn id `turn-old` but found `turn-new`"
		)

		let retryInterrupt = try await waitForPayload(at: 4, in: harness.recorder)
		XCTAssertEqual(retryInterrupt["method"] as? String, "turn/interrupt")
		let retryParams = try XCTUnwrap(retryInterrupt["params"] as? [String: Any])
		XCTAssertEqual(retryParams["threadId"] as? String, "thread-interrupt")
		XCTAssertEqual(retryParams["turnId"] as? String, "turn-new")
		try await sendResult(to: harness.client, id: try XCTUnwrap(retryInterrupt["id"]), result: [:])
		await cancelTask.value

		try? await Task.sleep(nanoseconds: 50_000_000)
		eventTask.cancel()
		await harness.controller.shutdown()
		let events = await eventTask.value
		let errorEvents = events.compactMap { event -> String? in
			if case .error(let message) = event { return message }
			return nil
		}
		XCTAssertEqual(errorEvents, [])
		XCTAssertEqual(harness.recorder.methods(), ["thread/start", "thread/memoryMode/set", "thread/read", "turn/interrupt", "turn/interrupt"])
	}

	func testMemoryModeSetFailureFailsStartOrResumeClosed() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}

		let startTask = Task {
			try await harness.controller.startOrResume(
				existing: nil,
				baseInstructions: "You are a concise assistant."
			)
		}

		let startRequest = try await waitForPayload(at: 0, in: harness.recorder)
		XCTAssertEqual(startRequest["method"] as? String, "thread/start")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(startRequest["id"]),
			result: threadResult(threadID: "thread-fail-closed")
		)

		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		XCTAssertEqual(memoryModeRequest["method"] as? String, "thread/memoryMode/set")
		try await sendError(
			to: harness.client,
			id: try XCTUnwrap(memoryModeRequest["id"]),
			message: "permission denied disabling memory mode"
		)

		await XCTAssertThrowsErrorAsync(try await startTask.value) { error in
			guard let clientError = error as? CodexAppServerClient.ClientError,
				case .requestFailed(let message) = clientError else {
				return XCTFail("Expected requestFailed error, got \(error)")
			}
			XCTAssertEqual(message, "permission denied disabling memory mode")
		}
		XCTAssertFalse(harness.controller.hasActiveThread)
		XCTAssertEqual(harness.recorder.methods(), ["thread/start", "thread/memoryMode/set"])
	}

	func testMemoryModeSetFailureFailsResumeClosed() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}

		let existing = CodexNativeSessionController.SessionRef(
			conversationID: "thread-resume-fail-closed",
			rolloutPath: "/tmp/thread-resume-fail-closed.jsonl",
			model: nil,
			reasoningEffort: nil
		)
		let resumeTask = Task {
			try await harness.controller.startOrResume(
				existing: existing,
				baseInstructions: "Ignored on resume"
			)
		}

		let resumeRequest = try await waitForPayload(at: 0, in: harness.recorder)
		XCTAssertEqual(resumeRequest["method"] as? String, "thread/resume")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(resumeRequest["id"]),
			result: threadResult(threadID: "thread-resume-fail-closed")
		)

		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		XCTAssertEqual(memoryModeRequest["method"] as? String, "thread/memoryMode/set")
		try await sendError(
			to: harness.client,
			id: try XCTUnwrap(memoryModeRequest["id"]),
			message: "permission denied disabling memory mode"
		)

		await XCTAssertThrowsErrorAsync(try await resumeTask.value) { error in
			guard let clientError = error as? CodexAppServerClient.ClientError,
				case .requestFailed(let message) = clientError else {
				return XCTFail("Expected requestFailed error, got \(error)")
			}
			XCTAssertEqual(message, "permission denied disabling memory mode")
		}
		XCTAssertFalse(harness.controller.hasActiveThread)
		XCTAssertEqual(harness.recorder.methods(), ["thread/resume", "thread/memoryMode/set"])
	}

	private struct Harness {
		let controller: CodexNativeSessionController
		let client: CodexAppServerClient
		let recorder: MemoryModeFrameRecorder
	}

	private func makeHarness(
		useAgentModeDefaults: Bool = false
	) async -> Harness {
		let recorder = MemoryModeFrameRecorder()
		let client = CodexAppServerClient(
			writeFrameHandler: { _, frame in
				recorder.record(frame: frame)
			},
			livenessProbe: { _ in true }
		)
		await client.debugInstallTestTransport()
		let options: CodexNativeSessionController.Options
		if useAgentModeDefaults {
			options = .agentModeDefault(forceExperimentalSteering: false)
		} else {
			options = CodexNativeSessionController.Options(
				requestTimeout: 5,
				configOverridesProvider: { [:] },
				approvalPolicyProvider: { .never },
				sandboxModeProvider: { .readOnly },
				approvalReviewerProvider: { .user },
				authTokensRefreshHandler: nil
			)
		}
		let controller = CodexNativeSessionController(
			client: client,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			options: options
		)
		return Harness(controller: controller, client: client, recorder: recorder)
	}

	private func threadResult(
		threadID: String,
		status: String = "idle",
		turns: [[String: Any]] = []
	) -> [String: Any] {
		[
			"thread": [
				"id": threadID,
				"path": "/tmp/\(threadID).jsonl",
				"status": status,
				"turns": turns
			],
			"model": "gpt-5",
			"reasoningEffort": "medium"
		]
	}

	private func waitForPayload(
		at index: Int,
		in recorder: MemoryModeFrameRecorder,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws -> [String: Any] {
		let observed = await waitUntil(timeout: 1) {
			recorder.count > index
		}
		XCTAssertTrue(observed, "Timed out waiting for outbound payload at index \(index)", file: file, line: line)
		return try XCTUnwrap(recorder.payload(at: index), file: file, line: line)
	}

	private func sendResult(to client: CodexAppServerClient, id: Any, result: [String: Any]) async throws {
		try await ingest(
			into: client,
			payload: [
				"id": id,
				"result": result
			]
		)
	}

	private func sendError(to client: CodexAppServerClient, id: Any, message: String) async throws {
		try await ingest(
			into: client,
			payload: [
				"id": id,
				"error": [
					"code": -32601,
					"message": message
				]
			]
		)
	}

	private func ingest(into client: CodexAppServerClient, payload: [String: Any]) async throws {
		let data = try JSONSerialization.data(withJSONObject: payload, options: [])
		await client.debugIngestRawStdoutLine(data)
	}

	private func waitUntil(timeout: TimeInterval, condition: @escaping @Sendable () async -> Bool) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if await condition() {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return await condition()
	}
}

private final class MemoryModeFrameRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var payloads: [[String: Any]] = []

	var count: Int {
		lock.lock()
		defer { lock.unlock() }
		return payloads.count
	}

	func record(frame: Data) {
		var payload = frame
		if payload.last == 0x0A {
			payload.removeLast()
		}
		guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
			return
		}
		lock.lock()
		payloads.append(object)
		lock.unlock()
	}

	func payload(at index: Int) -> [String: Any]? {
		lock.lock()
		defer { lock.unlock() }
		guard payloads.indices.contains(index) else { return nil }
		return payloads[index]
	}

	func methods() -> [String] {
		lock.lock()
		defer { lock.unlock() }
		return payloads.compactMap { $0["method"] as? String }
	}
}
