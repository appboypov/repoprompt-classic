import XCTest
@testable import RepoPrompt

final class CodexNativeSessionControllerThreadGoalTests: XCTestCase {
	func testSetThreadGoalObjectiveSendsGoalSetRequest() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}
		try await activateThread(in: harness, threadID: "thread-goal-set")

		let goalTask = Task {
			try await harness.controller.setThreadGoalObjective(" Improve benchmark coverage ")
		}

		let request = try await waitForPayload(at: 2, in: harness.recorder)
		XCTAssertEqual(request["method"] as? String, "thread/goal/set")
		let params = try XCTUnwrap(request["params"] as? [String: Any])
		XCTAssertEqual(params["threadId"] as? String, "thread-goal-set")
		XCTAssertEqual(params["objective"] as? String, "Improve benchmark coverage")
		XCTAssertEqual(params["status"] as? String, "active")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(request["id"]),
			result: ["goal": goalPayload(threadID: "thread-goal-set", objective: "Improve benchmark coverage", status: "active")]
		)

		let goal = try await goalTask.value
		XCTAssertEqual(goal.threadID, "thread-goal-set")
		XCTAssertEqual(goal.objective, "Improve benchmark coverage")
		XCTAssertEqual(goal.status, .active)
	}

	func testSetThreadGoalStatusSendsGoalSetRequest() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}
		try await activateThread(in: harness, threadID: "thread-goal-status")

		let goalTask = Task {
			try await harness.controller.setThreadGoalStatus(.paused)
		}

		let request = try await waitForPayload(at: 2, in: harness.recorder)
		XCTAssertEqual(request["method"] as? String, "thread/goal/set")
		let params = try XCTUnwrap(request["params"] as? [String: Any])
		XCTAssertEqual(params["threadId"] as? String, "thread-goal-status")
		XCTAssertNil(params["objective"])
		XCTAssertEqual(params["status"] as? String, "paused")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(request["id"]),
			result: ["goal": goalPayload(threadID: "thread-goal-status", objective: "Improve benchmark coverage", status: "paused")]
		)

		let goal = try await goalTask.value
		XCTAssertEqual(goal.status, .paused)
	}

	func testGetThreadGoalSendsGetAndParsesNilAndObject() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}
		try await activateThread(in: harness, threadID: "thread-goal-get")

		let nilTask = Task {
			try await harness.controller.getThreadGoal()
		}
		let nilRequest = try await waitForPayload(at: 2, in: harness.recorder)
		XCTAssertEqual(nilRequest["method"] as? String, "thread/goal/get")
		let nilParams = try XCTUnwrap(nilRequest["params"] as? [String: Any])
		XCTAssertEqual(nilParams["threadId"] as? String, "thread-goal-get")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(nilRequest["id"]),
			result: ["goal": NSNull()]
		)
		let nilGoal = try await nilTask.value
		XCTAssertNil(nilGoal)

		let objectTask = Task {
			try await harness.controller.getThreadGoal()
		}
		let objectRequest = try await waitForPayload(at: 3, in: harness.recorder)
		XCTAssertEqual(objectRequest["method"] as? String, "thread/goal/get")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(objectRequest["id"]),
			result: ["goal": goalPayload(threadID: "thread-goal-get", objective: "Ship goal support", status: "budgetLimited", tokenBudget: 100, tokensUsed: 101)]
		)
		let objectGoal = try await objectTask.value
		XCTAssertEqual(objectGoal?.objective, "Ship goal support")
		XCTAssertEqual(objectGoal?.status, .budgetLimited)
		XCTAssertEqual(objectGoal?.tokenBudget, 100)
		XCTAssertEqual(objectGoal?.tokensUsed, 101)
	}

	func testClearThreadGoalSendsClearRequest() async throws {
		let harness = await makeHarness()
		addTeardownBlock {
			await harness.controller.shutdown()
			await harness.client.stop()
		}
		try await activateThread(in: harness, threadID: "thread-goal-clear")

		let clearTask = Task {
			try await harness.controller.clearThreadGoal()
		}

		let request = try await waitForPayload(at: 2, in: harness.recorder)
		XCTAssertEqual(request["method"] as? String, "thread/goal/clear")
		let params = try XCTUnwrap(request["params"] as? [String: Any])
		XCTAssertEqual(params["threadId"] as? String, "thread-goal-clear")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(request["id"]),
			result: ["cleared": true]
		)

		let cleared = try await clearTask.value
		XCTAssertTrue(cleared)
	}

	private struct Harness {
		let controller: CodexNativeSessionController
		let client: CodexAppServerClient
		let recorder: ThreadGoalFrameRecorder
	}

	private func makeHarness() async -> Harness {
		let recorder = ThreadGoalFrameRecorder()
		let client = CodexAppServerClient(
			writeFrameHandler: { _, frame in
				recorder.record(frame: frame)
			},
			livenessProbe: { _ in true }
		)
		await client.debugInstallTestTransport()
		let options = CodexNativeSessionController.Options(
			requestTimeout: 5,
			configOverridesProvider: { [:] },
			approvalPolicyProvider: { .never },
			sandboxModeProvider: { .readOnly },
			approvalReviewerProvider: { .user },
			authTokensRefreshHandler: nil
		)
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

	private func activateThread(in harness: Harness, threadID: String) async throws {
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
			result: threadResult(threadID: threadID)
		)

		let memoryModeRequest = try await waitForPayload(at: 1, in: harness.recorder)
		XCTAssertEqual(memoryModeRequest["method"] as? String, "thread/memoryMode/set")
		try await sendResult(
			to: harness.client,
			id: try XCTUnwrap(memoryModeRequest["id"]),
			result: [:]
		)
		_ = try await startTask.value
	}

	private func threadResult(threadID: String) -> [String: Any] {
		[
			"thread": [
				"id": threadID,
				"path": "/tmp/\(threadID).jsonl",
				"status": "idle",
				"turns": []
			],
			"model": "gpt-5",
			"reasoningEffort": "medium"
		]
	}

	private func goalPayload(
		threadID: String,
		objective: String,
		status: String,
		tokenBudget: Int64? = nil,
		tokensUsed: Int64 = 12
	) -> [String: Any] {
		[
			"threadId": threadID,
			"objective": objective,
			"status": status,
			"tokenBudget": tokenBudget.map { NSNumber(value: $0) } ?? NSNull(),
			"tokensUsed": NSNumber(value: tokensUsed),
			"timeUsedSeconds": NSNumber(value: 3),
			"createdAt": NSNumber(value: 1),
			"updatedAt": NSNumber(value: 2)
		]
	}

	private func waitForPayload(
		at index: Int,
		in recorder: ThreadGoalFrameRecorder,
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

private final class ThreadGoalFrameRecorder: @unchecked Sendable {
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
}
