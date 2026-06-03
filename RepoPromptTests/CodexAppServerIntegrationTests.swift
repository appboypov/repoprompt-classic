import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import RepoPrompt

/// Integration tests for Codex app-server pipeline
/// Tests the full flow: start server → initialize → thread/start → turn/start → receive events
final class CodexAppServerIntegrationTests: XCTestCase {

	var client: CodexAppServerClient!

	private final class ScriptedWriteFailureState: @unchecked Sendable {
		private let lock = NSLock()
		private let failingWriteNumbers: Set<Int>
		private var writeCount = 0

		init(failingWriteNumbers: Set<Int>) {
			self.failingWriteNumbers = failingWriteNumbers
		}

		func shouldFailCurrentWrite() -> Bool {
			lock.lock()
			defer { lock.unlock() }
			writeCount += 1
			return failingWriteNumbers.contains(writeCount)
		}
	}

	private final class ScriptedLivenessProbeState: @unchecked Sendable {
		private let lock = NSLock()
		private let failingProbeNumbers: Set<Int>
		private var probeCount = 0

		init(failingProbeNumbers: Set<Int>) {
			self.failingProbeNumbers = failingProbeNumbers
		}

		func shouldReportAlive() -> Bool {
			lock.lock()
			defer { lock.unlock() }
			probeCount += 1
			return !failingProbeNumbers.contains(probeCount)
		}
	}

	private final class RecordedOutboundFrames: @unchecked Sendable {
		private let lock = NSLock()
		private var payloads: [[String: Any]] = []

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

		func lastRequest(method: String) -> [String: Any]? {
			lock.lock()
			defer { lock.unlock() }
			return payloads.reversed().first { $0["method"] as? String == method }
		}
	}

	private func recordedThreadStartParams(
		baseInstructions: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws -> [String: Any] {
		let recorder = RecordedOutboundFrames()
		let recordingClient = CodexAppServerClient(
			writeFrameHandler: { descriptor, frame in
				recorder.record(frame: frame)
				try FDWriteSupport.writeAll(frame, to: descriptor)
			}
		)
		let controller = CodexNativeSessionController(
			client: recordingClient,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: FileManager.default.currentDirectoryPath
		)

		do {
			_ = try await controller.startOrResume(
				existing: nil,
				baseInstructions: baseInstructions
			)

			let request = try XCTUnwrap(recorder.lastRequest(method: "thread/start"), file: file, line: line)
			let params = try XCTUnwrap(request["params"] as? [String: Any], file: file, line: line)
			await controller.shutdown()
			await recordingClient.stop()
			return params
		} catch {
			await controller.shutdown()
			await recordingClient.stop()
			throw error
		}
	}

	override func setUp() async throws {
		try await super.setUp()
		client = CodexAppServerClient()
	}

	override func tearDown() async throws {
		await client.stop()
		try await super.tearDown()
	}

	// MARK: - Basic Client Tests

	func testClientStartsSuccessfully() async throws {
		// Test that the client can start the app-server process
		try await client.startIfNeeded()
		// If we get here without throwing, the client started successfully
	}

	func testStartIfNeededReportsExecutableUnavailableBeforeSpawnForMissingExplicitCommand() async throws {
		let missingCodex = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathComponent("codex")
		await client.updateConfig(
			CodexAppServerClient.Config(
				commandName: missingCodex.path,
				additionalPathHints: [],
				enableDebugLogging: false,
				requestTimeout: nil,
				workingDirectory: FileManager.default.temporaryDirectory.path
			)
		)

		do {
			try await client.startIfNeeded()
			XCTFail("Expected executable-unavailable startup failure")
		} catch let error as CodexAppServerClient.ClientError {
			guard case .executableUnavailable(let message) = error else {
				return XCTFail("Expected executable-unavailable, got: \(error)")
			}
			XCTAssertEqual(
				message,
				"Codex CLI resolved to `\(missingCodex.path)`, but that file does not exist. Reinstall Codex CLI or fix your shell PATH."
			)
			let processID = await client.debugProcessID()
			XCTAssertNil(processID, "Executable preflight should fail before spawning app-server")
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testConcurrentStartIfNeededInitializesOnlyOnce() async throws {
		guard let client else {
			XCTFail("Client was not initialized")
			return
		}
		try await withThrowingTaskGroup(of: Void.self) { group in
			for _ in 0..<4 {
				group.addTask {
					try await client.startIfNeeded()
				}
			}
			try await group.waitForAll()
		}
		let nextRequestID = await client.debugNextRequestID()
		XCTAssertEqual(nextRequestID, 2, "Expected exactly one initialize request after concurrent startup")
	}

	func testStartIfNeededRestartsWhenTransportFailsLivenessCheck() async throws {
		client = makeClient(failingLivenessProbeNumbers: [1])
		guard let client else {
			XCTFail("Client was not initialized")
			return
		}

		try await client.startIfNeeded()
		let firstPIDValue = await client.debugProcessID()
		let firstPID = try XCTUnwrap(firstPIDValue)
		let firstGeneration = await client.debugTransportGeneration()

		try await client.startIfNeeded()
		let secondPIDValue = await client.debugProcessID()
		let secondPID = try XCTUnwrap(secondPIDValue)
		let secondGeneration = await client.debugTransportGeneration()

		XCTAssertNotEqual(firstPID, secondPID, "Expected stale transport to be replaced with a new process")
		XCTAssertEqual(secondGeneration, firstGeneration + 1, "Expected transport generation to advance after liveness-check restart")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .livenessCheckFailed(method: nil))

		let threadStart = try await client.request(
			method: "thread/start",
			params: ["cwd": FileManager.default.currentDirectoryPath]
		)
		XCTAssertNotNil(threadStart["thread"] as? [String: Any], "Restarted transport should still service requests")
	}

	func testStartIfNeededRestartsWhenDefaultLivenessProbeFindsKilledChild() async throws {
		guard let client else {
			XCTFail("Client was not initialized")
			return
		}

		try await client.startIfNeeded()
		let firstPIDValue = await client.debugProcessID()
		let firstPID = try XCTUnwrap(firstPIDValue)
		let firstGeneration = await client.debugTransportGeneration()

		let killResult = Darwin.kill(firstPID, SIGKILL)
		let killErrno = errno
		XCTAssertEqual(killResult, 0, "Failed to SIGKILL spawned Codex child \(firstPID): \(String(cString: strerror(killErrno)))")
		try? await Task.sleep(nanoseconds: 250_000_000)

		try await client.startIfNeeded()
		let secondPIDValue = await client.debugProcessID()
		let secondPID = try XCTUnwrap(secondPIDValue)
		let secondGeneration = await client.debugTransportGeneration()

		XCTAssertNotEqual(firstPID, secondPID, "Expected killed transport to be replaced with a new process")
		XCTAssertEqual(secondGeneration, firstGeneration + 1, "Expected transport generation to advance after killed-child restart")
		let reason = await client.debugLastTransportTerminationReason()
		switch reason {
		case .stdoutEOF?, .livenessCheckFailed(method: nil)?:
			break
		default:
			XCTFail("Expected killed transport to be observed via stdout EOF or liveness check, got: \(String(describing: reason))")
		}

		let threadStart = try await client.request(
			method: "thread/start",
			params: ["cwd": FileManager.default.currentDirectoryPath]
		)
		XCTAssertNotNil(threadStart["thread"] as? [String: Any], "Restarted transport should still service requests")
	}

	func testDefaultLivenessProbeTreatsKilledUnreapedChildAsDead() async throws {
		let spawned = try ProcessLauncher.spawn(
			command: "/bin/sleep",
			arguments: ["60"],
			environment: ProcessInfo.processInfo.environment,
			workingDirectory: FileManager.default.currentDirectoryPath
		)
		defer {
			spawned.stdin?.closeFile()
			spawned.stdout.closeFile()
			spawned.stderr.closeFile()
		}

		let killResult = Darwin.kill(spawned.pid, SIGKILL)
		let killErrno = errno
		XCTAssertEqual(killResult, 0, "Failed to SIGKILL spawned child \(spawned.pid): \(String(cString: strerror(killErrno)))")
		try? await Task.sleep(nanoseconds: 250_000_000)

		XCTAssertFalse(
			CodexAppServerClient.debugDefaultProcessAppearsAlive(spawned),
			"Default liveness probe should treat a killed unreaped child as dead"
		)
	}

	func testInjectedWriteFailureThrowsRecoverableTransportError() async throws {
		client = makeClient(failingWriteNumbers: [3])
		try await client.startIfNeeded()

		do {
			_ = try await client.request(
				method: "thread/start",
				params: ["cwd": FileManager.default.currentDirectoryPath]
			)
			XCTFail("Expected transport write failure")
		} catch let error as CodexAppServerClient.ClientError {
			guard case .transportWriteFailed(_, let errno) = error else {
				return XCTFail("Expected transport write failure, got: \(error)")
			}
			XCTAssertEqual(errno, EPIPE)
		}

		let terminated = await waitForProcessState(
			client: client,
			expectedRunning: false,
			timeout: 1
		)
		XCTAssertTrue(terminated, "Write failure should poison and tear down the transport")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .stdinWrite(method: "thread/start", errno: EPIPE))
	}

	func testListModelsRecoversAfterSingleInjectedTransportWriteFailure() async throws {
		client = makeClient(failingWriteNumbers: [3])

		let models = try await client.listModels(limit: 20)
		XCTAssertFalse(models.isEmpty, "Expected listModels retry to recover and return models")
		let isRunning = await client.debugIsProcessRunning()
		XCTAssertTrue(isRunning, "Transport should be running after successful retry")
		let generation = await client.debugTransportGeneration()
		XCTAssertGreaterThanOrEqual(generation, 2, "Expected retry to restart the transport after write failure")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .stdinWrite(method: "model/list", errno: EPIPE))
	}

	func testDecodeRecoveryBudgetExhaustionTerminatesPoisonedTransport() async throws {
		guard let client else {
			XCTFail("Client was not initialized")
			return
		}

		try await client.startIfNeeded()
		let isRunningBefore = await client.debugIsProcessRunning()
		XCTAssertTrue(isRunningBefore, "Process should be running before decode-budget exhaustion")

		let maxAttempts = CodexAppServerClient.debugMaxDecodeRecoveryAttemptsPerGeneration()
		let malformed = Data("{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\"".utf8)

		for _ in 0..<maxAttempts {
			await client.debugIngestRawStdoutLine(malformed)
		}
		let stillRunningAtBudgetBoundary = await waitForProcessState(
			client: client,
			expectedRunning: true,
			timeout: 0.3
		)
		XCTAssertTrue(stillRunningAtBudgetBoundary, "Transport should stay alive until decode recovery budget is actually exhausted")

		await client.debugIngestRawStdoutLine(malformed)
		let terminated = await waitForProcessState(
			client: client,
			expectedRunning: false,
			timeout: 2
		)
		XCTAssertTrue(terminated, "Decode-budget exhaustion should terminate the poisoned transport")
	}

	func testTimedOutThreadStartTerminatesTransport() async throws {
		guard let client else {
			XCTFail("Client was not initialized")
			return
		}

		try await client.startIfNeeded()
		do {
			_ = try await client.request(
				method: "thread/start",
				params: ["cwd": FileManager.default.currentDirectoryPath],
				timeout: 0.000_001
			)
			XCTFail("Expected thread/start to time out")
		} catch {
			XCTAssertTrue(
				error.localizedDescription.contains("Request timed out after"),
				"Expected control-plane timeout, got: \(error.localizedDescription)"
			)
		}

		let terminated = await waitForProcessState(
			client: client,
			expectedRunning: false,
			timeout: 2
		)
		XCTAssertTrue(terminated, "Timed-out thread/start should terminate the poisoned transport")
	}

	func testImmediateRetryAfterTimeoutStartsNewTransport() async throws {
		guard let client else {
			XCTFail("Client was not initialized")
			return
		}

		try await client.startIfNeeded()
		let firstPIDValue = await client.debugProcessID()
		let firstPID = try XCTUnwrap(firstPIDValue)
		let firstGeneration = await client.debugTransportGeneration()

		do {
			_ = try await client.request(
				method: "thread/start",
				params: ["cwd": FileManager.default.currentDirectoryPath],
				timeout: 0.000_001
			)
			XCTFail("Expected thread/start to time out")
		} catch {
			XCTAssertTrue(
				error.localizedDescription.contains("Request timed out after"),
				"Expected control-plane timeout, got: \(error.localizedDescription)"
			)
		}

		let models = try await client.listModels(limit: 20)
		let secondPIDValue = await client.debugProcessID()
		let secondPID = try XCTUnwrap(secondPIDValue)
		let secondGeneration = await client.debugTransportGeneration()

		XCTAssertNotEqual(firstPID, secondPID, "Immediate retry should replace the poisoned transport before reuse")
		XCTAssertEqual(secondGeneration, firstGeneration + 1, "Immediate retry should advance the transport generation after timeout")
		switch await client.debugLastTransportTerminationReason() {
		case .some(.timeout(method: "thread/start", requestID: _)):
			break
		default:
			XCTFail("Expected timeout termination reason after the poisoned transport was replaced")
		}
		XCTAssertFalse(models.isEmpty, "Immediate retry should succeed on a fresh transport")

		let threadStart = try await client.request(
			method: "thread/start",
			params: ["cwd": FileManager.default.currentDirectoryPath]
		)
		XCTAssertNotNil(threadStart["thread"] as? [String: Any], "New transport should service requests after an immediate retry")
	}

	func testClientCanSendThreadStart() async throws {
		try await client.startIfNeeded()

		// Send thread/start request
		let result = try await client.request(method: "thread/start", params: [
			"cwd": FileManager.default.currentDirectoryPath
		])

		// Verify we got a thread back
		guard let thread = result["thread"] as? [String: Any],
			  let threadID = thread["id"] as? String else {
			XCTFail("No thread ID in response: \(result)")
			return
		}

		XCTAssertFalse(threadID.isEmpty, "Thread ID should not be empty")
		print("[TEST] Thread started with ID: \(threadID)")
	}

	func testControllerCanReadThreadSnapshotAfterThreadStart() async throws {
		let controller = CodexNativeSessionController(
			client: client,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: FileManager.default.currentDirectoryPath
		)
		defer {
			Task {
				await controller.shutdown()
			}
		}

		let sessionRef = try await controller.startOrResume(
			existing: nil,
			baseInstructions: "You are a concise assistant."
		)
		let snapshot = try await controller.readThreadSnapshot(includeTurns: false, timeout: 15)

		XCTAssertEqual(snapshot.conversationID, sessionRef.conversationID)
		XCTAssertEqual(snapshot.rolloutPath, sessionRef.rolloutPath)
		XCTAssertEqual(snapshot.activeTurnIDs, [])
		switch snapshot.runtimeStatus {
		case .idle, .active:
			XCTAssertTrue(true)
		case .notLoaded, .systemError:
			XCTFail("Expected thread/read to report a usable runtime status, got \(snapshot.runtimeStatus)")
		}
	}

	func testClientCanSendMessage() async throws {
		try await client.startIfNeeded()

		// Start a thread
		let threadResult = try await client.request(method: "thread/start", params: [
			"cwd": FileManager.default.currentDirectoryPath
		])

		guard let thread = threadResult["thread"] as? [String: Any],
			  let threadID = thread["id"] as? String else {
			XCTFail("No thread ID in response")
			return
		}

		print("[TEST] Thread ID: \(threadID)")

		// Subscribe to notifications BEFORE sending the message
		let notificationStream = await client.subscribeNotifications()

		// Start a turn with a simple message
		let turnResult = try await client.request(method: "turn/start", params: [
			"threadId": threadID,
			"input": [
				["type": "text", "text": "What is 2+2? Reply with just the number.", "textElements": []]
			]
		])

		print("[TEST] Turn/start response: \(turnResult)")

		guard let turn = turnResult["turn"] as? [String: Any] else {
			XCTFail("No turn in response")
			return
		}

		print("[TEST] Turn started: \(turn)")

		// Collect notifications until turn completes
		var receivedAssistantText = ""
		var turnCompleted = false
		let timeout: TimeInterval = 60
		let startTime = Date()

		for await notification in notificationStream {
			let elapsed = Date().timeIntervalSince(startTime)
			if elapsed > timeout {
				print("[TEST] Timeout waiting for turn completion")
				break
			}

			print("[TEST] Notification: \(notification.method)")

			switch notification.method {
			case "item/agentMessage/delta":
				if case .string(let delta) = notification.params["delta"] {
					receivedAssistantText += delta
					print("[TEST] Delta: \(delta)")
				}
			case "turn/completed":
				print("[TEST] Turn completed!")
				turnCompleted = true
			case "codex/event/agent_message":
				// Full message received
				if let msg = notification.params["msg"],
				   case .object(let msgObj) = msg,
				   case .string(let message) = msgObj["message"] {
					if receivedAssistantText.isEmpty {
						receivedAssistantText = message
					}
					print("[TEST] Agent message: \(message)")
					turnCompleted = true
				}
			default:
				break
			}

			if turnCompleted {
				break
			}
		}

		print("[TEST] Final assistant text: \(receivedAssistantText)")
		XCTAssertTrue(turnCompleted, "Turn should complete")
		XCTAssertFalse(receivedAssistantText.isEmpty, "Should receive assistant response")
	}

	func testCodexNativeSessionControllerOmitsEmptyBaseInstructionsOnThreadStart() async throws {
		let threadStartParams = try await recordedThreadStartParams(baseInstructions: "")

		XCTAssertFalse(
			threadStartParams.keys.contains("baseInstructions"),
			"thread/start should omit empty baseInstructions so Codex can use its default instructions"
		)
	}

	func testCodexNativeSessionControllerOmitsWhitespaceOnlyBaseInstructionsOnThreadStart() async throws {
		let threadStartParams = try await recordedThreadStartParams(baseInstructions: " \n\t ")

		XCTAssertFalse(
			threadStartParams.keys.contains("baseInstructions"),
			"thread/start should omit whitespace-only baseInstructions so Codex can use its default instructions"
		)
	}

	func testCodexNativeSessionControllerIncludesNonEmptyBaseInstructionsOnThreadStart() async throws {
		let baseInstructions = "  You are a concise assistant.\n"
		let threadStartParams = try await recordedThreadStartParams(baseInstructions: baseInstructions)

		XCTAssertEqual(
			threadStartParams["baseInstructions"] as? String,
			baseInstructions,
			"thread/start should preserve non-empty baseInstructions as an explicit Codex override"
		)
	}

	func testControllerTurnStartOmitsConfigButKeepsTypedPermissionOverrides() async throws {
		let recorder = RecordedOutboundFrames()
		let client = CodexAppServerClient(
			writeFrameHandler: { descriptor, frame in
				recorder.record(frame: frame)
				try FDWriteSupport.writeAll(frame, to: descriptor)
			}
		)
		let options = CodexNativeSessionController.Options(
			requestTimeout: 30,
			configOverridesProvider: {
				[
					"web_search": "disabled",
					"features.web_search_request": false,
					"model_reasoning_summary": "auto"
				]
			},
			approvalPolicyProvider: { .never },
			sandboxModeProvider: { .dangerFullAccess },
			approvalReviewerProvider: { .autoReview },
			authTokensRefreshHandler: nil
		)
		let controller = CodexNativeSessionController(
			client: client,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: FileManager.default.currentDirectoryPath,
			options: options
		)
		defer {
			Task {
				await controller.shutdown()
				await client.stop()
			}
		}

		_ = try await controller.startOrResume(
			existing: nil,
			baseInstructions: "You are a concise assistant."
		)
		try await controller.sendUserTurn(text: "Reply with ok.", images: [])

		let threadStartRequest = try XCTUnwrap(recorder.lastRequest(method: "thread/start"))
		let threadStartParams = try XCTUnwrap(threadStartRequest["params"] as? [String: Any])
		XCTAssertNotNil(threadStartParams["config"], "thread/start should still carry config overrides")
		XCTAssertEqual(threadStartParams["approvalsReviewer"] as? String, "guardian_subagent")
		XCTAssertEqual(
			threadStartParams["baseInstructions"] as? String,
			"You are a concise assistant.",
			"thread/start should still carry non-empty base instructions"
		)

		let turnStartRequest = try XCTUnwrap(recorder.lastRequest(method: "turn/start"))
		let turnStartParams = try XCTUnwrap(turnStartRequest["params"] as? [String: Any])
		XCTAssertNil(turnStartParams["config"], "turn/start should not send a config override bag to app-server v2")
		XCTAssertEqual(turnStartParams["approvalPolicy"] as? String, "never")
		XCTAssertEqual(turnStartParams["approvalsReviewer"] as? String, "guardian_subagent")
		let sandboxPolicy = try XCTUnwrap(turnStartParams["sandboxPolicy"] as? [String: Any])
		XCTAssertEqual(sandboxPolicy["type"] as? String, "dangerFullAccess")
	}

	func testCodexNativeImageAttachmentsAreIdentifiedByModel() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1
		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)
		let eventState = EventState()
		let assistantText = AssistantTextState()
		let eventTask = Task {
			for await event in controller.events {
				await eventState.record(event)
				if case .assistantDelta(let delta) = event, !delta.isEmpty {
					await assistantText.append(delta)
				}
			}
		}
		defer { eventTask.cancel() }

		do {
			_ = try await controller.startOrResume(
				existing: nil,
				baseInstructions: "You are a concise assistant."
			)

			let imageURL = try makeFourStripeImageFile()
			defer { try? FileManager.default.removeItem(at: imageURL) }
			let attachment = AgentImageAttachment(source: .localFile(path: imageURL.path), title: imageURL.lastPathComponent)

			try await controller.sendUserTurn(
				text: "Describe the attached image by listing left-to-right stripe colors as a lowercase comma-separated list from this set: red, green, blue, yellow.",
				images: [attachment]
			)

			let completed = await waitForTurnCompletions(1, state: eventState, timeout: 120)
			XCTAssertTrue(completed, "Expected image turn to complete")

			let normalized = await assistantText.snapshot()
				.lowercased()
				.replacingOccurrences(of: #"[^a-z,]"#, with: "", options: .regularExpression)
			XCTAssertTrue(
				normalized.contains("red,green,blue,yellow"),
				"Expected Codex to identify stripe order red,green,blue,yellow from attached image; received: \(normalized)"
			)
			await controller.shutdown()
		} catch {
			await controller.shutdown()
			throw error
		}
	}
	
	func testClientReusesProcessAcrossTurns() async throws {
		try await client.startIfNeeded()
		let pid1 = await client.debugProcessID()
		XCTAssertNotNil(pid1, "Expected a running app-server process")
		
		let threadResult = try await client.request(method: "thread/start", params: [
			"cwd": FileManager.default.currentDirectoryPath
		])
		guard let thread = threadResult["thread"] as? [String: Any],
			  let threadID = thread["id"] as? String else {
			XCTFail("No thread ID in response")
			return
		}
		
		let notificationStream = await client.subscribeNotifications()
		var iterator = notificationStream.makeAsyncIterator()
		
		_ = try await client.request(method: "turn/start", params: [
			"threadId": threadID,
			"input": [
				["type": "text", "text": "Reply with the word one.", "textElements": []]
			]
		])
		
		let firstResponse = await awaitTurnCompletion(using: &iterator, timeout: 60)
		XCTAssertFalse(firstResponse.isEmpty, "First turn should complete with content")
		
		let pid2 = await client.debugProcessID()
		XCTAssertEqual(pid1, pid2, "App-server process should be reused between turns")
		
		_ = try await client.request(method: "turn/start", params: [
			"threadId": threadID,
			"input": [
				["type": "text", "text": "Reply with the word two.", "textElements": []]
			]
		])
		
		let secondResponse = await awaitTurnCompletion(using: &iterator, timeout: 60)
		XCTAssertFalse(secondResponse.isEmpty, "Second turn should complete with content")
		
		let pid3 = await client.debugProcessID()
		XCTAssertEqual(pid1, pid3, "App-server process should remain stable across multiple turns")
	}

	// MARK: - Controller Tests

	func testCodexNativeSessionControllerBasicFlow() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1

		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)

		// Start the session
		let sessionRef = try await controller.startOrResume(
			existing: nil,
			baseInstructions: "You are a helpful assistant. Be concise."
		)

		print("[TEST] Session started - conversationID: \(sessionRef.conversationID)")
		XCTAssertFalse(sessionRef.conversationID.isEmpty, "Conversation ID should not be empty")

		// Set up event collection
		var events: [CodexNativeSessionController.Event] = []
		let eventTask = Task {
			for await event in controller.events {
				print("[TEST] Event: \(event)")
				events.append(event)

				// Stop after turn completed
				if case .turnCompleted = event {
					break
				}
			}
		}

		// Send a message
		try await controller.sendUserMessage("What is 2+2? Reply with just the number.")

		// Wait for events with timeout
		let result = await Task {
			try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds max
		}.result

		eventTask.cancel()

		print("[TEST] Collected \(events.count) events")
		for (i, event) in events.enumerated() {
			print("[TEST] Event \(i): \(event)")
		}

		// Verify we got some events
		XCTAssertFalse(events.isEmpty, "Should receive events from controller")

		// Check for assistant content
		let hasAssistantDelta = events.contains {
			if case .assistantDelta = $0 { return true }
			return false
		}
		XCTAssertTrue(hasAssistantDelta, "Should receive assistant delta events")
	}
	
	func testCodexToolRoutingEmitsToolEventsAfterTimeout() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1
		
		let tracker = AgentToolTracker()
		let toolCalled = expectation(description: "tool called")
		let toolCompleted = expectation(description: "tool completed")
		toolCalled.assertForOverFulfill = false
		toolCompleted.assertForOverFulfill = false
		let toolState = ToolEventState()
		
		await tracker.startEnhanced(
			runID: runID,
			clientNameHint: "codex-mcp-client",
			connectionTimeoutSeconds: 0.1,
			fallbackTimeoutSeconds: 0.1,
			keepObserversOnTimeout: true,
			onCalled: { invocationID, toolName, _ in
				if toolName == "bind_context" {
					Task {
						if await toolState.recordCalled(invocationID: invocationID) {
							toolCalled.fulfill()
						}
					}
				}
			},
			onCompleted: { invocationID, toolName, _, resultJSON, isError in
				if toolName == "bind_context" {
					Task {
						if await toolState.recordCompleted(
							invocationID: invocationID,
							resultJSON: resultJSON,
							isError: isError
						) {
							toolCompleted.fulfill()
						}
					}
				}
			}
		)
		
		// Ensure the short wait windows elapse before the connection is created.
		try await Task.sleep(nanoseconds: 300_000_000)
		
		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)
		
		let baseInstructions = SystemPromptService.agentModePrompt()
		_ = try await controller.startOrResume(
			existing: nil,
			baseInstructions: baseInstructions
		)
		
		try await controller.sendUserMessage(
			"Call the tool bind_context exactly once with op=list, then respond with 'done'."
		)
		
		await fulfillment(of: [toolCalled, toolCompleted], timeout: 60)
		let snapshot = await toolState.snapshot()
		XCTAssertNotNil(snapshot.calledID, "Tool call should capture an invocation ID")
		XCTAssertEqual(snapshot.calledID, snapshot.completedID, "Tool completion should match the call invocation ID")
		XCTAssertFalse(snapshot.resultJSON.isEmpty, "Tool completion should include a result payload")
		XCTAssertFalse(snapshot.isError, "Tool completion should not be an error")
		let entries = try decodeBindContextWindows(from: snapshot.resultJSON)
		XCTAssertFalse(entries.isEmpty, "bind_context list should return at least one window")
		XCTAssertTrue(entries.contains { $0.windowID == windowID }, "bind_context list should include the active window ID")
		for entry in entries {
			XCTAssertFalse(entry.workspaceName.isEmpty, "Workspace name should not be empty")
		}
		await tracker.stop()
		await controller.shutdown()
	}
	
	func testManualCompactionPreservesMCPConnectionAndRunIDRoutingForRepoPromptTools() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1
		let clientName = DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client"

		let tracker = AgentToolTracker()
		let trackerState = ToolRoutingState()
		await tracker.startEnhanced(
			runID: runID,
			clientNameHint: clientName,
			keepObserversOnTimeout: true,
			onCalled: { _, _, _ in },
			onCompleted: { invocationID, toolName, _, _, isError in
				Task {
					let normalized = Self.normalizedRepoPromptToolName(toolName)
					_ = await trackerState.recordCompleted(
						invocationID: invocationID,
						toolName: normalized,
						isError: isError
					)
				}
			}
		)

		let baselineConnectionIDs = Set(
			await ServerNetworkManager.shared.identityContextSnapshots()
				.filter { $0.clientName == clientName }
				.map(\.connectionID)
		)
		let initialConnectionTask = Task {
			await ServerNetworkManager.shared.waitForNewConnection(clientName: clientName, timeout: 30.0)
		}

		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)

		let baseInstructions = SystemPromptService.agentModePrompt()
		_ = try await controller.startOrResume(
			existing: nil,
			baseInstructions: baseInstructions
		)

		let eventState = EventState()
		let nativeToolState = NativeRepoPromptToolEventState()
		let assistantTextState = AssistantTextState()
		let eventTask = Task {
			for await event in controller.events {
				await eventState.record(event)
				await nativeToolState.record(event)
				if case .assistantDelta(let delta) = event {
					await assistantTextState.append(delta)
				}
			}
		}

		do {
			try await controller.sendUserMessage(
				"Call bind_context exactly once with op=list, then reply with 'pre done'."
			)
			let initialConnectionID = await initialConnectionTask.value
			let preConnectionID = try XCTUnwrap(
				initialConnectionID,
				"Expected Codex MCP client to establish an initial connection"
			)
			XCTAssertFalse(
				baselineConnectionIDs.contains(preConnectionID),
				"Initial Codex MCP connection should be newly observed for this test run"
			)
			let preResolvedRunID = await ServerNetworkManager.shared.runIDForConnection(preConnectionID)
			XCTAssertEqual(preResolvedRunID, runID, "Initial MCP connection should resolve back to the active runID")
			let deliveredPreTool = await waitForRepoPromptToolDelivery(
				count: 1,
				toolName: "bind_context",
				trackerState: trackerState,
				nativeState: nativeToolState,
				timeout: 120
			)
			XCTAssertTrue(deliveredPreTool, "Pre-compaction tool turn should reach both tracker and native event paths")
			let completedPreTurn = await waitForTurnCompletions(1, state: eventState, timeout: 120)
			XCTAssertTrue(completedPreTurn, "Pre-compaction tool turn should complete")
			let sawPreDone = await waitForAssistantTextContaining("pre done", state: assistantTextState, timeout: 30)
			XCTAssertTrue(sawPreDone, "Expected baseline assistant response after pre-compaction tool turn")

			let postConnectionTask = Task {
				await ServerNetworkManager.shared.waitForNewConnection(clientName: clientName, timeout: 20.0)
			}
			try await controller.compactThread()
			let sawContextCompaction = await waitForContextCompactions(1, state: nativeToolState, timeout: 60)
			XCTAssertTrue(sawContextCompaction, "Manual compaction should emit a contextCompacted event")
			let completedCompactionTurn = await waitForTurnCompletions(2, state: eventState, timeout: 120)
			XCTAssertTrue(completedCompactionTurn, "Compaction turn should complete before the follow-up tool turn")

			try await controller.sendUserMessage(
				"Call bind_context exactly once with op=list, then reply with 'post done'."
			)
			let deliveredPostTool = await waitForRepoPromptToolDelivery(
				count: 2,
				toolName: "bind_context",
				trackerState: trackerState,
				nativeState: nativeToolState,
				timeout: 120
			)
			XCTAssertTrue(deliveredPostTool, "Post-compaction tool turn should still reach both tracker and native event paths")
			let completedPostTurn = await waitForTurnCompletions(3, state: eventState, timeout: 120)
			XCTAssertTrue(completedPostTurn, "Post-compaction tool turn should complete")
			let sawPostDone = await waitForAssistantTextContaining("post done", state: assistantTextState, timeout: 30)
			XCTAssertTrue(sawPostDone, "Expected follow-up assistant response after compaction")

			let postConnectionID = await postConnectionTask.value
			if let postConnectionID {
				let postResolvedRunID = await ServerNetworkManager.shared.runIDForConnection(postConnectionID)
				XCTAssertEqual(
					postResolvedRunID,
					runID,
					"If compaction does trigger a fresh MCP connection, it must still route back to the same runID"
				)
			}
			XCTAssertNil(
				postConnectionID,
				"Manual compaction should not require a fresh Codex MCP connection in the healthy path"
			)

			let trackerSnapshot = await trackerState.snapshot()
			XCTAssertGreaterThanOrEqual(
				trackerSnapshot.completedByTool["bind_context", default: 0],
				2,
				"Tracker callbacks should remain run-routed across compaction"
			)
			let nativeSnapshot = await nativeToolState.snapshot()
			XCTAssertGreaterThanOrEqual(
				nativeSnapshot.calledByTool["bind_context", default: 0],
				2,
				"Native Codex tool-call events should still arrive after compaction"
			)
			XCTAssertGreaterThanOrEqual(
				nativeSnapshot.completedByTool["bind_context", default: 0],
				2,
				"Native Codex tool-result events should still arrive after compaction"
			)
		} catch {
			eventTask.cancel()
			await tracker.stop()
			await controller.shutdown()
			throw error
		}

		eventTask.cancel()
		await tracker.stop()
		await controller.shutdown()
	}

	func testCodexToolTrackingRecoversAfterCancelThenFollowUp() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1
		
		let tracker = AgentToolTracker()
		let followUpToolCompleted = expectation(description: "follow-up tool completed")
		followUpToolCompleted.assertForOverFulfill = false
		let toolHistory = ToolEventHistory()
		
		await tracker.startEnhanced(
			runID: runID,
			clientNameHint: "codex-mcp-client",
			keepObserversOnTimeout: true,
			onCalled: { _, _, _ in },
			onCompleted: { invocationID, toolName, _, resultJSON, isError in
				guard toolName == "get_file_tree" else { return }
				Task {
					if await toolHistory.recordCompleted(
						invocationID: invocationID,
						resultJSON: resultJSON,
						isError: isError
					) {
						followUpToolCompleted.fulfill()
					}
				}
			}
		)
		
		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)
		
		let baseInstructions = SystemPromptService.agentModePrompt()
		_ = try await controller.startOrResume(
			existing: nil,
			baseInstructions: baseInstructions
		)
		
		let eventState = EventState()
		let eventTask = Task {
			for await event in controller.events {
				await eventState.record(event)
			}
		}
		
		try await controller.sendUserMessage(
			"Start a long response (at least 8 paragraphs). Do not call MCP tools in this turn. Keep writing until interrupted."
		)
		let didStart = await waitForTurnStarts(1, state: eventState, timeout: 30)
		XCTAssertTrue(didStart, "First turn should start before interruption")
		let streamedBeforeCancel = await waitForStreamingDeltas(state: eventState, timeout: 25)
		XCTAssertTrue(streamedBeforeCancel, "First turn should stream output before interruption")
		await controller.cancelCurrentTurn()
		let interruptedCompleted = await waitForTurnCompletions(1, state: eventState, timeout: 60)
		XCTAssertTrue(interruptedCompleted, "Interrupted turn should complete")
		let firstTurnDetail = await eventState.snapshotDetailed()
		XCTAssertTrue(firstTurnDetail.turnCompletedStatuses.contains(.interrupted), "Expected interrupted status after cancel")
		
		try await controller.sendUserMessage(
			"Call get_file_tree exactly once with type=files and mode=folders, then reply with 'followup done'."
		)
		await fulfillment(of: [followUpToolCompleted], timeout: 120)
		let secondCompleted = await waitForTurnCompletions(2, state: eventState, timeout: 90)
		XCTAssertTrue(secondCompleted, "Follow-up turn should complete after cancellation")
		
		let snapshot = await toolHistory.snapshot()
		XCTAssertEqual(snapshot.count, 1, "Expected one get_file_tree tool completion on follow-up turn")
		XCTAssertTrue(snapshot.isErrorFlags.allSatisfy { $0 == false }, "Tool results should not be errors")
		
		eventTask.cancel()
		await tracker.stop()
		await controller.shutdown()
	}

	func testToolRoutingKeepsRunIDsIsolatedAcrossStaggeredCodexRuns() async throws {
		let runIDA = UUID()
		let runIDB = UUID()
		let tabA = UUID()
		let tabB = UUID()
		let windowID = 1

		let trackerA = AgentToolTracker()
		let trackerB = AgentToolTracker()
		let historyA = ToolRoutingState()
		let historyB = ToolRoutingState()
		let runAToolCompleted = expectation(description: "run A get_file_tree completion")
		let runBToolCompleted = expectation(description: "run B manage_selection completion")
		runAToolCompleted.assertForOverFulfill = false
		runBToolCompleted.assertForOverFulfill = false

		await trackerA.startEnhanced(
			runID: runIDA,
			clientNameHint: "codex-mcp-client",
			connectionTimeoutSeconds: 0.5,
			fallbackTimeoutSeconds: 0.5,
			keepObserversOnTimeout: true,
			onCalled: { _, _, _ in },
			onCompleted: { invocationID, toolName, _, _, isError in
				Task {
					let normalized = Self.normalizedRepoPromptToolName(toolName)
					let isNew = await historyA.recordCompleted(
						invocationID: invocationID,
						toolName: normalized,
						isError: isError
					)
					if isNew, normalized == "get_file_tree" {
						runAToolCompleted.fulfill()
					}
				}
			}
		)
		await trackerB.startEnhanced(
			runID: runIDB,
			clientNameHint: "codex-mcp-client",
			connectionTimeoutSeconds: 0.5,
			fallbackTimeoutSeconds: 0.5,
			keepObserversOnTimeout: true,
			onCalled: { _, _, _ in },
			onCompleted: { invocationID, toolName, _, _, isError in
				Task {
					let normalized = Self.normalizedRepoPromptToolName(toolName)
					let isNew = await historyB.recordCompleted(
						invocationID: invocationID,
						toolName: normalized,
						isError: isError
					)
					if isNew, normalized == "manage_selection" {
						runBToolCompleted.fulfill()
					}
				}
			}
		)

		let controllerA = CodexNativeSessionController(
			client: client,
			runID: runIDA,
			tabID: tabA,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)
		let controllerB = CodexNativeSessionController(
			client: client,
			runID: runIDB,
			tabID: tabB,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)

		let baseInstructionsA = SystemPromptService.agentModePrompt()
		let baseInstructionsB = SystemPromptService.agentModePrompt()

		do {
			let firstStartedAt = Date()
			await ServerNetworkManager.shared.installClientConnectionPolicy(
				for: DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client",
				windowID: windowID,
				restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
				oneShot: true,
				reason: "agent-mode-run",
				ttl: 15,
				tabID: tabA,
				runID: runIDA,
				additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
				purpose: .agentModeRun
			)
			_ = try await controllerA.startOrResume(
				existing: nil,
				baseInstructions: baseInstructionsA
			)
			try await controllerA.sendUserMessage(
				"Call get_file_tree exactly once with type=files and mode=folders, then reply with 'run-a done'. Do not call any other tools."
			)

			try await Task.sleep(nanoseconds: 1_000_000_000)
			let secondStartedAt = Date()
			XCTAssertLessThan(
				secondStartedAt.timeIntervalSince(firstStartedAt),
				15.0,
				"Second run should begin while one-shot policy TTL is still active"
			)

			await ServerNetworkManager.shared.installClientConnectionPolicy(
				for: DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client",
				windowID: windowID,
				restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
				oneShot: true,
				reason: "agent-mode-run",
				ttl: 15,
				tabID: tabB,
				runID: runIDB,
				additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
				purpose: .agentModeRun
			)
			_ = try await controllerB.startOrResume(
				existing: nil,
				baseInstructions: baseInstructionsB
			)
			try await controllerB.sendUserMessage(
				"Call manage_selection exactly once with op=get and view=files, then reply with 'run-b done'. Do not call any other tools."
			)

			await fulfillment(of: [runAToolCompleted, runBToolCompleted], timeout: 120)

			let snapshotA = await historyA.snapshot()
			let snapshotB = await historyB.snapshot()

			XCTAssertGreaterThanOrEqual(
				snapshotA.completedByTool["get_file_tree", default: 0],
				1,
				"Run A should observe its own get_file_tree tool completion"
			)
			XCTAssertEqual(
				snapshotA.completedByTool["manage_selection", default: 0],
				0,
				"Run A observer should not receive run B manage_selection completion"
			)
			XCTAssertEqual(
				snapshotA.completedByTool["bind_context", default: 0],
				0,
				"Run A should not observe unexpected bind_context completions"
			)
			XCTAssertTrue(
				(snapshotA.errorsByTool["get_file_tree"] ?? []).allSatisfy { !$0 },
				"Run A get_file_tree completions should not be errors"
			)

			XCTAssertGreaterThanOrEqual(
				snapshotB.completedByTool["manage_selection", default: 0],
				1,
				"Run B should observe its own manage_selection tool completion"
			)
			XCTAssertEqual(
				snapshotB.completedByTool["get_file_tree", default: 0],
				0,
				"Run B observer should not receive run A get_file_tree completion"
			)
			XCTAssertEqual(
				snapshotB.completedByTool["bind_context", default: 0],
				0,
				"Run B should not observe unexpected bind_context completions"
			)
			XCTAssertTrue(
				(snapshotB.errorsByTool["manage_selection"] ?? []).allSatisfy { !$0 },
				"Run B manage_selection completions should not be errors"
			)
		} catch {
			await trackerA.stop()
			await trackerB.stop()
			await controllerA.shutdown()
			await controllerB.shutdown()
			throw error
		}

		await trackerA.stop()
		await trackerB.stop()
		await controllerA.shutdown()
		await controllerB.shutdown()
	}
	
	func testMultiTurnToolReasoningResponses() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1
		
		let tracker = AgentToolTracker()
		let toolCompleted = expectation(description: "tool completed twice")
		toolCompleted.expectedFulfillmentCount = 2
		toolCompleted.assertForOverFulfill = false
		let toolHistory = ToolEventHistory()
		
		await tracker.startEnhanced(
			runID: runID,
			clientNameHint: "codex-mcp-client",
			keepObserversOnTimeout: true,
			onCalled: { _, _, _ in },
			onCompleted: { invocationID, toolName, _, resultJSON, isError in
				guard toolName == "bind_context" else { return }
				Task {
					if await toolHistory.recordCompleted(
						invocationID: invocationID,
						resultJSON: resultJSON,
						isError: isError
					) {
						toolCompleted.fulfill()
					}
				}
			}
		)
		
		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)
		
		let eventState = EventState()
		let eventTask = Task {
			for await event in controller.events {
				await eventState.record(event)
			}
		}
		
		let baseInstructions = SystemPromptService.agentModePrompt()
		_ = try await controller.startOrResume(
			existing: nil,
			baseInstructions: baseInstructions
		)
		
		try await controller.sendUserMessage(
			"For this turn: call the tool bind_context exactly once with op=list, then reply with 'turn1 done'."
		)
		let firstCompleted = await waitForTurnCompletions(1, state: eventState, timeout: 90)
		XCTAssertTrue(firstCompleted, "First turn should complete")
		
		try await controller.sendUserMessage(
			"For this turn: call the tool bind_context exactly once with op=list, then reply with 'turn2 done'."
		)
		let secondCompleted = await waitForTurnCompletions(2, state: eventState, timeout: 90)
		XCTAssertTrue(secondCompleted, "Second turn should complete")
		
		await fulfillment(of: [toolCompleted], timeout: 90)
		let toolSnapshot = await toolHistory.snapshot()
		XCTAssertEqual(toolSnapshot.count, 2, "Expected two bind_context tool completions")
		XCTAssertTrue(toolSnapshot.isErrorFlags.allSatisfy { $0 == false }, "Tool results should not be errors")
		for resultJSON in toolSnapshot.resultJSONs {
			let entries = try decodeBindContextWindows(from: resultJSON)
			XCTAssertFalse(entries.isEmpty, "bind_context list should return at least one window")
			XCTAssertTrue(entries.contains { $0.windowID == windowID }, "bind_context list should include the active window ID")
		}
		
		let eventSnapshot = await eventState.snapshot()
		XCTAssertGreaterThan(eventSnapshot.assistantDeltaCount, 0, "Should receive assistant responses across turns")
		XCTAssertGreaterThan(eventSnapshot.reasoningDeltaCount, 0, "Should receive reasoning deltas across turns")
		XCTAssertEqual(eventSnapshot.turnCompletedCount, 2, "Expected two turn completions")
		
		eventTask.cancel()
		await tracker.stop()
		await controller.shutdown()
	}
	
	func testCodexNativeSessionRestoresExistingSession() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1
		
		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)
		
		let baseInstructions = SystemPromptService.agentModePrompt()
		let initialRef = try await controller.startOrResume(
			existing: nil,
			baseInstructions: baseInstructions
		)
		XCTAssertFalse(initialRef.conversationID.isEmpty, "Initial conversation should have an ID")
		
		let restoredController = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)
		
		let restoredRef = try await restoredController.startOrResume(
			existing: initialRef,
			baseInstructions: baseInstructions
		)
		XCTAssertEqual(
			initialRef.conversationID,
			restoredRef.conversationID,
			"Restored session should reuse the same conversation ID"
		)
		
		let eventState = EventState()
		let eventTask = Task {
			for await event in restoredController.events {
				await eventState.record(event)
			}
		}
		
		try await restoredController.sendUserMessage("Reply with 'restored ok'.")
		let restoredCompleted = await waitForTurnCompletions(1, state: eventState, timeout: 90)
		XCTAssertTrue(restoredCompleted, "Restored session should complete a turn")
		
		let snapshot = await eventState.snapshot()
		XCTAssertGreaterThan(snapshot.assistantDeltaCount, 0, "Restored session should stream assistant output")
		
		eventTask.cancel()
		await restoredController.shutdown()
		await controller.shutdown()
	}
	
	func testCodexNativeInterruptAndResteer() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1
		
		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)
		
		let eventState = EventState()
		let eventTask = Task {
			for await event in controller.events {
				await eventState.record(event)
			}
		}
		
		let baseInstructions = SystemPromptService.agentModePrompt()
		_ = try await controller.startOrResume(
			existing: nil,
			baseInstructions: baseInstructions
		)
		
		try await controller.sendUserMessage(
			"Start a long response (at least 8 paragraphs). Keep going until asked to stop."
		)
		
		let didStart = await waitForTurnStarts(1, state: eventState, timeout: 30)
		XCTAssertTrue(didStart, "Turn should start before interrupting")
		
		await controller.cancelCurrentTurn()
		try await controller.sendUserMessage("Reply with 'resteer ok'.")
		
		let firstCompletion = await waitForTurnCompletions(1, state: eventState, timeout: 60)
		XCTAssertTrue(firstCompletion, "Interrupted turn should complete")
		let secondCompletion = await waitForTurnCompletions(2, state: eventState, timeout: 60)
		XCTAssertTrue(secondCompletion, "Follow-up turn should complete")
		
		let detail = await eventState.snapshotDetailed()
		XCTAssertEqual(detail.assistantDeltaCountsByTurn.count, 2, "Expected assistant output for two turns")
		if detail.assistantDeltaCountsByTurn.count == 2 {
			XCTAssertGreaterThan(detail.assistantDeltaCountsByTurn[1], 0, "Follow-up turn should produce assistant output")
		}
		XCTAssertTrue(detail.turnCompletedStatuses.contains(.interrupted), "Expected an interrupted turn status")
		
		eventTask.cancel()
		await controller.shutdown()
	}

	func testCodexNativeAppendWhileRunning() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1

		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)

		let eventState = EventState()
		let assistantText = AssistantTextState()
		let eventTask = Task {
			for await event in controller.events {
				await eventState.record(event)
				if case .assistantDelta(let delta) = event, !delta.isEmpty {
					await assistantText.append(delta)
				}
			}
		}

		let baseInstructions = SystemPromptService.agentModePrompt()
		_ = try await controller.startOrResume(
			existing: nil,
			baseInstructions: baseInstructions
		)

		try await controller.sendUserMessage(
			"Start a long response (at least 8 paragraphs). Keep going until you receive a follow-up."
		)

		let didStart = await waitForTurnStarts(1, state: eventState, timeout: 20)
		if !didStart {
			print("[TEST] Turn did not start within 20s; sending follow-up anyway")
		}

		try await controller.sendUserMessage("Now stop and end with 'APPENDED_OK'.")

		let completed = await waitForTurnCompletions(1, state: eventState, timeout: 90)
		XCTAssertTrue(completed, "Turn should complete after follow-up input")

		let combinedText = await assistantText.snapshot()
		XCTAssertTrue(
			combinedText.contains("APPENDED_OK") || combinedText.contains("appended_ok"),
			"Assistant output should reflect the follow-up message"
		)

		eventTask.cancel()
		await controller.shutdown()
	}

	func testCodexBashHangLifecycleProbeCapturesCommandExecutionJSONShape() async throws {
		let runID = UUID()
		let tabID = UUID()
		let windowID = 1

		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)

		let eventState = EventState()
		let bashState = BashLifecycleState()
		let eventTask = Task {
			for await event in controller.events {
				await eventState.record(event)
				await bashState.record(event)
			}
		}
		defer { eventTask.cancel() }

		let baseInstructions = SystemPromptService.agentModePrompt()
		_ = try await controller.startOrResume(
			existing: nil,
			baseInstructions: baseInstructions
		)

		try await controller.sendUserMessage(
			"For this turn, call bash exactly once with command `sleep 300`. Do not call any MCP tools. Do not ask me questions."
		)

		let sawBashCall = await waitForBashToolCalls(1, state: bashState, timeout: 60)
		XCTAssertTrue(sawBashCall, "Expected Codex app-server stream to include a bash tool call")

		let sawRunningSignal = await waitForBashRunningSignal(state: bashState, timeout: 60)
		if !sawRunningSignal {
			await controller.cancelCurrentTurn()
			_ = await waitForTurnCompletions(1, state: eventState, timeout: 30)
			await controller.shutdown()
			let snapshot = await bashState.snapshot()
			let sample = snapshot.resultPayloads.first ?? "<none>"
			throw XCTSkip(
				"Live app-server probe did not emit running lifecycle signal. callCount=\(snapshot.callCount) runningUpdates=\(snapshot.runningUpdateCount) payloadCount=\(snapshot.resultPayloads.count) sample=\(sample)"
			)
		}

		await controller.cancelCurrentTurn()
		let completed = await waitForTurnCompletions(1, state: eventState, timeout: 90)
		XCTAssertTrue(completed, "Expected turn completion after cancellation")

		let snapshot = await bashState.snapshot()
		if let sample = snapshot.resultPayloads.first {
			print("[TEST] bash result payload sample: \(sample)")
		}
		XCTAssertGreaterThanOrEqual(snapshot.callCount, 1, "Expected at least one bash tool call")
		if !(snapshot.runningUpdateCount > 0 || snapshot.sawRunningCommandExecutionPayload) {
			await controller.shutdown()
			throw XCTSkip("No running lifecycle JSON shape was observed in this environment")
		}

		await controller.shutdown()
	}

	// MARK: - Full Pipeline Test (simulating AgentModeViewModel flow)

	func testFullAgentModePipeline() async throws {
		// This simulates what AgentModeViewModel does

		let runID = UUID()
		let tabID = UUID()
		let windowID = 1

		print("[TEST] === Starting Full Pipeline Test ===")
		print("[TEST] RunID: \(runID)")
		print("[TEST] TabID: \(tabID)")

		// 1. Create controller (simulates ensureCodexNativeSession creating controller)
		let controller = CodexNativeSessionController(
			client: client,
			runID: runID,
			tabID: tabID,
			windowID: windowID,
			workspacePath: FileManager.default.currentDirectoryPath
		)

		// 2. Set up event listener (simulates the codexEventTask in ensureCodexNativeSession)
		var collectedEvents: [CodexNativeSessionController.Event] = []
		var assistantText = ""
		var turnDidComplete = false

		let eventListenerTask = Task { @MainActor in
			for await event in controller.events {
				print("[TEST] Pipeline Event: \(event)")
				collectedEvents.append(event)

				switch event {
				case .assistantDelta(let delta):
					assistantText += delta
					print("[TEST] Assistant delta: '\(delta)' (total: \(assistantText.count) chars)")
				case .turnStarted(let turnID):
					print("[TEST] Turn started: \(turnID ?? "nil")")
				case .turnCompleted(let turnID, let status):
					print("[TEST] Turn completed turnID=\(turnID ?? "nil") status=\(status)")
					turnDidComplete = true
				case .error(let message):
					print("[TEST] Error: \(message)")
					turnDidComplete = true
				default:
					break
				}
			}
		}

		// 3. Start or resume session (simulates needsStart path in ensureCodexNativeSession)
		print("[TEST] Starting session...")
		let sessionRef = try await controller.startOrResume(
			existing: nil,
			baseInstructions: "You are a helpful assistant."
		)
		print("[TEST] Session ref: \(sessionRef)")

		// 4. Send user message (simulates sendCodexNativeMessage)
		print("[TEST] Sending user message...")
		try await controller.sendUserMessage("Say hello!")

		// 5. Wait for completion
		print("[TEST] Waiting for turn completion...")
		let startTime = Date()
		let timeout: TimeInterval = 60

		while !turnDidComplete {
			if Date().timeIntervalSince(startTime) > timeout {
				print("[TEST] TIMEOUT waiting for turn completion")
				break
			}
			try await Task.sleep(nanoseconds: 100_000_000) // 100ms
		}

		eventListenerTask.cancel()

		// 6. Verify results
		print("[TEST] === Results ===")
		print("[TEST] Events collected: \(collectedEvents.count)")
		print("[TEST] Assistant text: '\(assistantText)'")
		print("[TEST] Turn completed: \(turnDidComplete)")

		XCTAssertTrue(turnDidComplete, "Turn should complete")
		XCTAssertFalse(assistantText.isEmpty, "Should receive assistant text")
		XCTAssertGreaterThan(collectedEvents.count, 0, "Should collect events")
	}
	
	private func makeClient(
		failingWriteNumbers: Set<Int> = [],
		failingLivenessProbeNumbers: Set<Int> = []
	) -> CodexAppServerClient {
		let writeState = ScriptedWriteFailureState(failingWriteNumbers: failingWriteNumbers)
		let livenessState = ScriptedLivenessProbeState(failingProbeNumbers: failingLivenessProbeNumbers)
		return CodexAppServerClient(
			writeFrameHandler: { descriptor, frame in
				if writeState.shouldFailCurrentWrite() {
					throw FDWriteError.brokenPipe(errno: EPIPE)
				}
				try FDWriteSupport.writeAll(frame, to: descriptor)
			},
			livenessProbe: { _ in
				livenessState.shouldReportAlive()
			}
		)
	}

	private func awaitTurnCompletion(
		using iterator: inout AsyncStream<CodexAppServerClient.Notification>.Iterator,
		timeout: TimeInterval
	) async -> String {
		let start = Date()
		var assistantText = ""
		
		while Date().timeIntervalSince(start) < timeout {
			guard let notification = await iterator.next() else {
				break
			}
			
			switch notification.method {
			case "item/agentMessage/delta":
				if case .string(let delta) = notification.params["delta"] {
					assistantText += delta
				}
			case "codex/event/agent_message":
				if let msg = notification.params["msg"],
				   case .object(let msgObj) = msg,
				   case .string(let message) = msgObj["message"] {
					if assistantText.isEmpty {
						assistantText = message
					}
					return assistantText
				}
			case "turn/completed":
				return assistantText
			default:
				break
			}
		}
		
		return assistantText
	}

	private actor ToolEventState {
		private(set) var calledID: UUID?
		private(set) var completedID: UUID?
		private(set) var resultJSON: String = ""
		private(set) var isError: Bool = false
		
		func recordCalled(invocationID: UUID) -> Bool {
			if calledID == nil {
				calledID = invocationID
				return true
			}
			return false
		}
		
		func recordCompleted(invocationID: UUID, resultJSON: String, isError: Bool) -> Bool {
			if let calledID, calledID != invocationID {
				return false
			}
			if completedID == nil {
				completedID = invocationID
				self.resultJSON = resultJSON
				self.isError = isError
				if calledID == nil {
					calledID = invocationID
				}
				return true
			}
			return false
		}
		
		func snapshot() -> (calledID: UUID?, completedID: UUID?, resultJSON: String, isError: Bool) {
			(calledID, completedID, resultJSON, isError)
		}
	}
	
	private actor ToolEventHistory {
		private var completedIDs: Set<UUID> = []
		private(set) var resultJSONs: [String] = []
		private(set) var isErrorFlags: [Bool] = []
		
		func recordCompleted(
			invocationID: UUID,
			resultJSON: String,
			isError: Bool
		) -> Bool {
			if completedIDs.contains(invocationID) {
				return false
			}
			completedIDs.insert(invocationID)
			resultJSONs.append(resultJSON)
			isErrorFlags.append(isError)
			return true
		}
		
		func snapshot() -> (count: Int, resultJSONs: [String], isErrorFlags: [Bool]) {
			(completedIDs.count, resultJSONs, isErrorFlags)
		}
	}

	private actor NativeRepoPromptToolEventState {
		private(set) var calledByTool: [String: Int] = [:]
		private(set) var completedByTool: [String: Int] = [:]
		private(set) var contextCompactedCount = 0

		func record(_ event: CodexNativeSessionController.Event) {
			switch event {
			case .toolCall(let name, _, _):
				let normalized = CodexAppServerIntegrationTests.normalizedRepoPromptToolName(name)
				calledByTool[normalized, default: 0] += 1
			case .toolResult(let name, _, _, _, _):
				let normalized = CodexAppServerIntegrationTests.normalizedRepoPromptToolName(name)
				completedByTool[normalized, default: 0] += 1
			case .contextCompacted:
				contextCompactedCount += 1
			default:
				break
			}
		}

		func snapshot() -> (
			calledByTool: [String: Int],
			completedByTool: [String: Int],
			contextCompactedCount: Int
		) {
			(calledByTool, completedByTool, contextCompactedCount)
		}
	}

	private actor ToolRoutingState {
		private var seenInvocationIDs: Set<UUID> = []
		private(set) var completedByTool: [String: Int] = [:]
		private(set) var errorsByTool: [String: [Bool]] = [:]

		func recordCompleted(invocationID: UUID, toolName: String, isError: Bool) -> Bool {
			if seenInvocationIDs.contains(invocationID) {
				return false
			}
			seenInvocationIDs.insert(invocationID)
			completedByTool[toolName, default: 0] += 1
			errorsByTool[toolName, default: []].append(isError)
			return true
		}

		func snapshot() -> (completedByTool: [String: Int], errorsByTool: [String: [Bool]]) {
			(completedByTool, errorsByTool)
		}
	}
	
	private actor EventState {
		private(set) var assistantDeltaCount = 0
		private(set) var reasoningDeltaCount = 0
		private(set) var turnCompletedCount = 0
		private(set) var turnStartedCount = 0
		private var currentTurnAssistantDeltaCount = 0
		private var assistantDeltaCountsByTurn: [Int] = []
		private var turnCompletedStatuses: [CodexNativeSessionController.TurnStatus] = []
		
		func record(_ event: CodexNativeSessionController.Event) {
			switch event {
			case .assistantDelta(let delta):
				if !delta.isEmpty {
					assistantDeltaCount += 1
					currentTurnAssistantDeltaCount += 1
				}
			case .reasoningDelta(let payload):
				if !payload.text.isEmpty {
					reasoningDeltaCount += 1
				}
			case .turnStarted(_):
				turnStartedCount += 1
				currentTurnAssistantDeltaCount = 0
			case .turnCompleted(turnID: _, status: let status):
				turnCompletedCount += 1
				turnCompletedStatuses.append(status)
				assistantDeltaCountsByTurn.append(currentTurnAssistantDeltaCount)
			default:
				break
			}
		}
		
		func snapshot() -> (assistantDeltaCount: Int, reasoningDeltaCount: Int, turnCompletedCount: Int) {
			(assistantDeltaCount, reasoningDeltaCount, turnCompletedCount)
		}
		
		func snapshotDetailed() -> (
			assistantDeltaCount: Int,
			reasoningDeltaCount: Int,
			turnCompletedCount: Int,
			turnStartedCount: Int,
			turnCompletedStatuses: [CodexNativeSessionController.TurnStatus],
			assistantDeltaCountsByTurn: [Int]
		) {
			(
				assistantDeltaCount,
				reasoningDeltaCount,
				turnCompletedCount,
				turnStartedCount,
				turnCompletedStatuses,
				assistantDeltaCountsByTurn
			)
		}
	}

	private actor AssistantTextState {
		private var text = ""

		func append(_ delta: String) {
			text += delta
		}

		func snapshot() -> String {
			text
		}
	}

	private actor BashLifecycleState {
		private(set) var callCount = 0
		private(set) var runningUpdateCount = 0
		private(set) var resultPayloads: [String] = []
		private(set) var sawRunningCommandExecutionPayload = false

		func record(_ event: CodexNativeSessionController.Event) {
			switch event {
			case .toolCall(let name, _, _):
				guard Self.isBashTool(name) else { return }
				callCount += 1
			case .toolResult(let name, _, _, let resultJSON, _):
				guard Self.isBashTool(name) else { return }
				resultPayloads.append(resultJSON)
				if Self.isRunningCommandExecutionPayload(resultJSON) {
					sawRunningCommandExecutionPayload = true
				}
			case .commandExecutionRunning:
				runningUpdateCount += 1
			default:
				break
			}
		}

		func snapshot() -> (
			callCount: Int,
			runningUpdateCount: Int,
			resultPayloads: [String],
			sawRunningCommandExecutionPayload: Bool
		) {
			(callCount, runningUpdateCount, resultPayloads, sawRunningCommandExecutionPayload)
		}

		private static func isBashTool(_ rawName: String) -> Bool {
			let lowered = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			let suffix = lowered.split(separator: ".").last.map(String.init) ?? lowered
			return suffix == "bash"
				|| suffix == "shell"
				|| suffix == "local_shell"
				|| suffix == "unified_exec"
				|| suffix == "exec_command"
				|| suffix == "run_shell_command"
		}

		private static func isRunningCommandExecutionPayload(_ raw: String) -> Bool {
			guard let data = raw.data(using: .utf8),
				let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				return false
			}
			let type = (object["type"] as? String)?.lowercased() ?? ""
			let status = (object["status"] as? String)?
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.lowercased()
			guard type.contains("command") else { return false }
			return status == "running" || status == "in_progress" || status == "pending"
		}
	}
	
	private struct BindContextWindowEntry {
		let windowID: Int
		let workspaceName: String
	}
	
	private func decodeBindContextWindows(from resultJSON: String) throws -> [BindContextWindowEntry] {
		guard let data = resultJSON.data(using: .utf8) else {
			throw NSError(domain: "CodexAppServerIntegrationTests", code: 1, userInfo: [
				NSLocalizedDescriptionKey: "bind_context result was not valid UTF-8"
			])
		}
		let response = try JSONDecoder().decode(BindContextResponse.self, from: data)
		return (response.windows ?? []).map { window in
			BindContextWindowEntry(
				windowID: window.windowID,
				workspaceName: window.workspace?.name ?? ""
			)
		}
	}

	private func makeFourStripeImageFile() throws -> URL {
		let width = 80
		let height = 20
		let bytesPerPixel = 4
		let bytesPerRow = width * bytesPerPixel
		var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

		for y in 0..<height {
			for x in 0..<width {
				let offset = (y * bytesPerRow) + (x * bytesPerPixel)
				switch (x * 4) / width {
				case 0:
					pixels[offset] = 255
					pixels[offset + 1] = 0
					pixels[offset + 2] = 0
				case 1:
					pixels[offset] = 0
					pixels[offset + 1] = 255
					pixels[offset + 2] = 0
				case 2:
					pixels[offset] = 0
					pixels[offset + 1] = 0
					pixels[offset + 2] = 255
				default:
					pixels[offset] = 255
					pixels[offset + 1] = 255
					pixels[offset + 2] = 0
				}
				pixels[offset + 3] = 255
			}
		}

		guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
			throw NSError(domain: "CodexAppServerIntegrationTests", code: 3, userInfo: [
				NSLocalizedDescriptionKey: "Failed to create image data provider"
			])
		}
		guard let image = CGImage(
			width: width,
			height: height,
			bitsPerComponent: 8,
			bitsPerPixel: 32,
			bytesPerRow: bytesPerRow,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
			provider: provider,
			decode: nil,
			shouldInterpolate: false,
			intent: .defaultIntent
		) else {
			throw NSError(domain: "CodexAppServerIntegrationTests", code: 4, userInfo: [
				NSLocalizedDescriptionKey: "Failed to create CGImage"
			])
		}

		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-image-stripes-\(UUID().uuidString)")
			.appendingPathExtension("png")
		guard let destination = CGImageDestinationCreateWithURL(
			outputURL as CFURL,
			UTType.png.identifier as CFString,
			1,
			nil
		) else {
			throw NSError(domain: "CodexAppServerIntegrationTests", code: 5, userInfo: [
				NSLocalizedDescriptionKey: "Failed to create image destination"
			])
		}
		CGImageDestinationAddImage(destination, image, nil)
		guard CGImageDestinationFinalize(destination) else {
			throw NSError(domain: "CodexAppServerIntegrationTests", code: 6, userInfo: [
				NSLocalizedDescriptionKey: "Failed to finalize PNG image"
			])
		}
		return outputURL
	}
	
	private func waitForProcessState(
		client: CodexAppServerClient,
		expectedRunning: Bool,
		timeout: TimeInterval
	) async -> Bool {
		let start = Date()
		while Date().timeIntervalSince(start) < timeout {
			if await client.debugIsProcessRunning() == expectedRunning {
				return true
			}
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		return await client.debugIsProcessRunning() == expectedRunning
	}

	private func waitForTurnCompletions(_ count: Int, state: EventState, timeout: TimeInterval) async -> Bool {
		let start = Date()
		while Date().timeIntervalSince(start) < timeout {
			let snapshot = await state.snapshot()
			if snapshot.turnCompletedCount >= count {
				return true
			}
			try? await Task.sleep(nanoseconds: 150_000_000)
		}
		return false
	}
	
	private func waitForTurnStarts(_ count: Int, state: EventState, timeout: TimeInterval) async -> Bool {
		let start = Date()
		while Date().timeIntervalSince(start) < timeout {
			let snapshot = await state.snapshotDetailed()
			if snapshot.turnStartedCount >= count {
				return true
			}
			try? await Task.sleep(nanoseconds: 150_000_000)
		}
		return false
	}

	private func waitForStreamingDeltas(state: EventState, timeout: TimeInterval) async -> Bool {
		let start = Date()
		while Date().timeIntervalSince(start) < timeout {
			let snapshot = await state.snapshot()
			if snapshot.assistantDeltaCount > 0 || snapshot.reasoningDeltaCount > 0 {
				return true
			}
			try? await Task.sleep(nanoseconds: 150_000_000)
		}
		return false
	}

	private func waitForRepoPromptToolDelivery(
		count: Int,
		toolName: String,
		trackerState: ToolRoutingState,
		nativeState: NativeRepoPromptToolEventState,
		timeout: TimeInterval
	) async -> Bool {
		let start = Date()
		while Date().timeIntervalSince(start) < timeout {
			let trackerSnapshot = await trackerState.snapshot()
			let nativeSnapshot = await nativeState.snapshot()
			if trackerSnapshot.completedByTool[toolName, default: 0] >= count,
				nativeSnapshot.calledByTool[toolName, default: 0] >= count,
				nativeSnapshot.completedByTool[toolName, default: 0] >= count {
				return true
			}
			try? await Task.sleep(nanoseconds: 150_000_000)
		}
		return false
	}

	private func waitForContextCompactions(
		_ count: Int,
		state: NativeRepoPromptToolEventState,
		timeout: TimeInterval
	) async -> Bool {
		let start = Date()
		while Date().timeIntervalSince(start) < timeout {
			let snapshot = await state.snapshot()
			if snapshot.contextCompactedCount >= count {
				return true
			}
			try? await Task.sleep(nanoseconds: 150_000_000)
		}
		return false
	}

	private func waitForAssistantTextContaining(
		_ expectedSubstring: String,
		state: AssistantTextState,
		timeout: TimeInterval
	) async -> Bool {
		let start = Date()
		while Date().timeIntervalSince(start) < timeout {
			let text = await state.snapshot()
			if text.localizedCaseInsensitiveContains(expectedSubstring) {
				return true
			}
			try? await Task.sleep(nanoseconds: 150_000_000)
		}
		return false
	}

	private func waitForBashToolCalls(_ count: Int, state: BashLifecycleState, timeout: TimeInterval) async -> Bool {
		let start = Date()
		while Date().timeIntervalSince(start) < timeout {
			let snapshot = await state.snapshot()
			if snapshot.callCount >= count {
				return true
			}
			try? await Task.sleep(nanoseconds: 150_000_000)
		}
		return false
	}

	private func waitForBashRunningSignal(state: BashLifecycleState, timeout: TimeInterval) async -> Bool {
		let start = Date()
		while Date().timeIntervalSince(start) < timeout {
			let snapshot = await state.snapshot()
			if snapshot.runningUpdateCount > 0 || snapshot.sawRunningCommandExecutionPayload {
				return true
			}
			try? await Task.sleep(nanoseconds: 150_000_000)
		}
		return false
	}

	private static func normalizedRepoPromptToolName(_ toolName: String) -> String {
		if toolName.hasPrefix("mcp__RepoPrompt__") {
			return String(toolName.dropFirst("mcp__RepoPrompt__".count))
		}
		return toolName
	}
}
