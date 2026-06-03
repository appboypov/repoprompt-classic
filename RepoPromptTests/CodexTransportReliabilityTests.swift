import XCTest
@testable import RepoPrompt

final class CodexTransportReliabilityTests: XCTestCase {
	func testBufferedInboundDuringBindingDrainsInOrderAfterSnapshotApplied() async throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferServerRequestDuringBinding(
			CodexAppServerClient.ServerRequest(
				id: .int(7),
				method: "workspace/requestApproval",
				params: [
					"threadId": .string("thread-1"),
					"command": .string("ls"),
					"reason": .string("Need approval")
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			CodexAppServerClient.Notification(
				method: "turn/started",
				params: [
					"threadId": .string("thread-1"),
					"turn": .object(["id": .string("turn-1")])
				]
			)
		)

		let sessionRef = await controller.test_finishBinding(
			result: [
				"thread": [
					"id": "thread-1",
					"turns": []
				]
			],
			fallbackEffort: nil
		)
		XCTAssertEqual(sessionRef.conversationID, "thread-1")
		let drainedBufferedInbound = await waitUntil(timeout: 1) { await recorder.count == 2 }
		XCTAssertTrue(drainedBufferedInbound)

		let events = await recorder.snapshot()
		guard events.count >= 2 else {
			return XCTFail("Expected buffered inbound events to drain")
		}
		if case .approvalRequest(let approval) = events[0] {
			XCTAssertEqual(approval.threadID, "thread-1")
			XCTAssertEqual(approval.method, "workspace/requestApproval")
		} else {
			XCTFail("Expected approval request to drain first")
		}
		if case .turnStarted(_) = events[1] {
			XCTAssertTrue(true)
		} else {
			XCTFail("Expected turnStarted to drain second")
		}
	}

	func testStartOrResumeRejectsReuseWhileActive() async throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		try await controller.test_beginBindingSession()
		_ = await controller.test_finishBinding(
			result: [
				"thread": [
					"id": "thread-1",
					"turns": []
				]
			],
			fallbackEffort: nil
		)

		await XCTAssertThrowsErrorAsync(try await controller.startOrResume(existing: nil, baseInstructions: "test")) { error in
			guard case let CodexSessionControllerError.invalidLifecycleState(description) = error else {
				return XCTFail("Expected invalid lifecycle state error, got \(error)")
			}
			XCTAssertEqual(description, "already active")
		}
	}

	func testStartOrResumeRejectsReuseAfterShutdown() async {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		await controller.shutdown()
		await XCTAssertThrowsErrorAsync(try await controller.startOrResume(existing: nil, baseInstructions: "test")) { error in
			guard case let CodexSessionControllerError.invalidLifecycleState(description) = error else {
				return XCTFail("Expected invalid lifecycle state error, got \(error)")
			}
			XCTAssertEqual(description, "shutting down")
		}
	}

	func testStartOrResumeRejectsReuseAfterTransportTermination() async {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		await controller.test_simulateTransportStreamEnded(source: "notifications")
		await XCTAssertThrowsErrorAsync(try await controller.startOrResume(existing: nil, baseInstructions: "test")) { error in
			guard case let CodexSessionControllerError.invalidLifecycleState(description) = error else {
				return XCTFail("Expected invalid lifecycle state error, got \(error)")
			}
			XCTAssertEqual(description, "terminated")
		}
	}

	func testRequestCancellationRemovesPendingRequestAndTimeoutTask() async {
		let client = CodexAppServerClient(writeFrameHandler: { _, _ in })
		await client.debugInstallTestTransport()

		let requestTask = Task<Void, Error> {
			_ = try await client.request(method: "thread/read", params: ["threadId": "thread-1"], timeout: 60)
		}
		let requestRegistered = await waitUntil(timeout: 1) {
			let pendingCount = await client.debugPendingRequestCount()
			let timeoutCount = await client.debugTimeoutTaskCount()
			return pendingCount == 1 && timeoutCount == 1
		}
		XCTAssertTrue(requestRegistered)

		requestTask.cancel()
		await XCTAssertThrowsErrorAsync(try await requestTask.value) { error in
			XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
		}
		let finalPendingCount = await client.debugPendingRequestCount()
		let finalTimeoutCount = await client.debugTimeoutTaskCount()
		XCTAssertEqual(finalPendingCount, 0)
		XCTAssertEqual(finalTimeoutCount, 0)
	}

	func testExpectedAgentPIDRegistrationRegistersAndClearsInstalledTransport() async throws {
		let recorder = ExpectedPIDRecorder()
		let client = CodexAppServerClient(
			expectedAgentPIDRegistrar: .init(
				register: { pid, clientName, runID in
					await recorder.record(.register(pid: pid, clientName: clientName, runID: runID))
				},
				clear: { pid, clientName, runID in
					await recorder.record(.clear(pid: pid, clientName: clientName, runID: runID))
				}
			)
		)
		let runID = UUID()
		let clientName = try XCTUnwrap(DiscoverAgentKind.codexExec.mcpClientNameHint)

		await client.debugInstallTestTransport()
		await client.setExpectedAgentPIDRegistration(
			.init(clientName: clientName, runID: runID)
		)

		var events = await recorder.snapshot()
		XCTAssertEqual(events, [
			.register(pid: pid_t.max, clientName: clientName, runID: runID)
		])

		await client.clearExpectedAgentPIDRegistration()
		events = await recorder.snapshot()
		XCTAssertEqual(events, [
			.register(pid: pid_t.max, clientName: clientName, runID: runID),
			.clear(pid: pid_t.max, clientName: clientName, runID: runID)
		])
	}

	func testServerRequestsUseCodexJSONValuePayloads() async throws {
		let client = CodexAppServerClient()
		let stream = await client.subscribeServerRequests()
		let nextRequestTask = Task {
			var iterator = stream.makeAsyncIterator()
			return await iterator.next()
		}

		let payload: [String: Any] = [
			"id": 9,
			"method": "workspace/requestApproval",
			"params": [
				"threadId": "thread-9",
				"allowed": true,
				"count": 3,
				"nested": ["path": "/tmp/demo"],
				"items": ["a", 2, NSNull()]
			]
		]
		let data = try JSONSerialization.data(withJSONObject: payload, options: [])
		await client.debugIngestRawStdoutLine(data)

		let request = await nextRequestTask.value
		guard let request else {
			return XCTFail("Expected a server request")
		}
		XCTAssertEqual(request.method, "workspace/requestApproval")
		if case .string(let threadID)? = request.params["threadId"] {
			XCTAssertEqual(threadID, "thread-9")
		} else {
			XCTFail("Expected threadId to be preserved as CodexJSONValue.string")
		}
		if case .bool(let allowed)? = request.params["allowed"] {
			XCTAssertTrue(allowed)
		} else {
			XCTFail("Expected allowed to be preserved as CodexJSONValue.bool")
		}
		if case .object(let nested)? = request.params["nested"],
			case .string(let path)? = nested["path"] {
			XCTAssertEqual(path, "/tmp/demo")
		} else {
			XCTFail("Expected nested object payload to be preserved")
		}
		if case .array(let items)? = request.params["items"] {
			XCTAssertEqual(items.count, 3)
		} else {
			XCTFail("Expected array payload to be preserved")
		}
	}

	func testBufferedRequestUserInputDuringBindingDrainsAsEvent() async throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferServerRequestDuringBinding(
			CodexAppServerClient.ServerRequest(
				id: .string("rui-1"),
				method: "item/tool/requestUserInput",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-1"),
					"itemId": .string("item-1"),
					"questions": .array([
						.object([
							"id": .string("q1"),
							"header": .string("Header"),
							"question": .string("What now?"),
							"options": .array([
								.object(["label": .string("A"), "description": .string("First")])
							])
						])
					])
				]
			)
		)
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)

		let delivered = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(delivered)
		let events = await recorder.snapshot()
		guard case .requestUserInput(let request) = events.first else {
			return XCTFail("Expected requestUserInput event")
		}
		XCTAssertEqual(request.requestID, .string("rui-1"))
		XCTAssertEqual(request.questions.map(\.id), ["q1"])
	}

	func testBufferedMcpElicitationRequestEmitsPendingInteraction() async throws {
		let frameRecorder = OutboundFrameRecorder()
		let client = CodexAppServerClient(writeFrameHandler: { _, frame in
			frameRecorder.record(frame: frame)
		})
		await client.debugInstallTestTransport()
		let controller = CodexNativeSessionController(
			client: client,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferServerRequestDuringBinding(
			CodexAppServerClient.ServerRequest(
				id: .string("elicitation-1"),
				method: "mcpServer/elicitation/request",
				params: [
					"server": .string("external-server"),
					"prompt": .string("Allow external MCP action?"),
					"schema": .object(["type": .string("object")])
				]
			)
		)
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)

		let delivered = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(delivered)
		let events = await recorder.snapshot()
		guard case .mcpElicitationRequest(let request) = events.first else {
			return XCTFail("Expected mcpElicitationRequest event")
		}
		XCTAssertEqual(request.requestID, .string("elicitation-1"))
		XCTAssertEqual(request.serverName, "external-server")
		XCTAssertEqual(request.prompt, "Allow external MCP action?")
		XCTAssertNil(frameRecorder.lastPayload())
	}

	func testComputerUseMcpElicitationAutoAcceptsOnlyWhenScopedFullAccess() async throws {
		let frameRecorder = OutboundFrameRecorder()
		let client = CodexAppServerClient(writeFrameHandler: { _, frame in
			frameRecorder.record(frame: frame)
		})
		await client.debugInstallTestTransport()
		let options = CodexNativeSessionController.Options(
			requestTimeout: nil,
			configOverridesProvider: { [:] },
			approvalPolicyProvider: { .never },
			sandboxModeProvider: { .dangerFullAccess },
			approvalReviewerProvider: { .user },
			authTokensRefreshHandler: nil,
			computerUseEnabledProvider: { true }
		)
		let controller = CodexNativeSessionController(
			client: client,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			options: options
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferServerRequestDuringBinding(
			CodexAppServerClient.ServerRequest(
				id: .string("computer-use-elicitation-1"),
				method: "mcpServer/elicitation/request",
				params: [
					"server": .string("computer-use"),
					"prompt": .string("Computer-use wants control")
				]
			)
		)
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)

		let delivered = await waitUntil(timeout: 1) { frameRecorder.lastPayload() != nil }
		XCTAssertTrue(delivered)
		let eventCount = await recorder.count
		XCTAssertEqual(eventCount, 0)
		let payload = try XCTUnwrap(frameRecorder.lastPayload())
		XCTAssertEqual(payload["id"] as? String, "computer-use-elicitation-1")
		let result = try XCTUnwrap(payload["result"] as? [String: Any])
		XCTAssertEqual(result["action"] as? String, "accept")
		let meta = try XCTUnwrap(result["_meta"] as? [String: Any])
		XCTAssertEqual(meta["reason"] as? String, "explicit_computer_use_full_access")
	}

	func testComputerUseMcpElicitationDoesNotAutoAcceptSpoofedServerName() async throws {
		let frameRecorder = OutboundFrameRecorder()
		let client = CodexAppServerClient(writeFrameHandler: { _, frame in
			frameRecorder.record(frame: frame)
		})
		await client.debugInstallTestTransport()
		let options = CodexNativeSessionController.Options(
			requestTimeout: nil,
			configOverridesProvider: { [:] },
			approvalPolicyProvider: { .never },
			sandboxModeProvider: { .dangerFullAccess },
			approvalReviewerProvider: { .user },
			authTokensRefreshHandler: nil,
			computerUseEnabledProvider: { true }
		)
		let controller = CodexNativeSessionController(
			client: client,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			options: options
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferServerRequestDuringBinding(
			CodexAppServerClient.ServerRequest(
				id: .string("spoofed-computer-use-elicitation"),
				method: "mcpServer/elicitation/request",
				params: [
					"server": .string("evil.computer-use"),
					"prompt": .string("Spoofed server wants control")
				]
			)
		)
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)

		let delivered = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(delivered)
		let events = await recorder.snapshot()
		guard case .mcpElicitationRequest(let request) = events.first else {
			return XCTFail("Expected spoofed server to surface as pending elicitation")
		}
		XCTAssertEqual(request.serverName, "evil.computer-use")
		XCTAssertNil(frameRecorder.lastPayload())
	}

	func testBufferedAuthRefreshWithoutHandlerEmitsStructuredIssueAndWritesErrorResponse() async throws {
		let frameRecorder = OutboundFrameRecorder()
		let client = CodexAppServerClient(writeFrameHandler: { _, frame in
			frameRecorder.record(frame: frame)
		})
		await client.debugInstallTestTransport()
		let controller = CodexNativeSessionController(
			client: client,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferServerRequestDuringBinding(
			CodexAppServerClient.ServerRequest(
				id: .int(41),
				method: "account/chatgptAuthTokens/refresh",
				params: ["reason": .string("unauthorized")]
			)
		)
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)

		let delivered = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(delivered)
		let events = await recorder.snapshot()
		guard case .serverRequestIssue(let issue) = events.first else {
			return XCTFail("Expected serverRequestIssue event")
		}
		XCTAssertEqual(issue.kind, .authTokensRefreshUnavailable)
		XCTAssertEqual(issue.method, "account/chatgptAuthTokens/refresh")
		XCTAssertTrue(issue.message.contains("account/chatgptAuthTokens/refresh"))

		let payload = try XCTUnwrap(frameRecorder.lastPayload())
		let error = try XCTUnwrap(payload["error"] as? [String: Any])
		XCTAssertEqual(payload["id"] as? Int, 41)
		XCTAssertEqual(error["code"] as? Int, -32001)
		XCTAssertEqual(
			error["message"] as? String,
			"Codex requested account/chatgptAuthTokens/refresh, but RepoPrompt is not managing external Codex ChatGPT auth tokens. Reconnect Codex authentication and retry."
		)
	}

	func testBufferedUnsupportedServerRequestEmitsStructuredIssueAndWritesErrorResponse() async throws {
		let frameRecorder = OutboundFrameRecorder()
		let client = CodexAppServerClient(writeFrameHandler: { _, frame in
			frameRecorder.record(frame: frame)
		})
		await client.debugInstallTestTransport()
		let controller = CodexNativeSessionController(
			client: client,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferServerRequestDuringBinding(
			CodexAppServerClient.ServerRequest(
				id: .string("req-unsupported"),
				method: "workspace/unknownOperation",
				params: [:]
			)
		)
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)

		let delivered = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(delivered)
		let events = await recorder.snapshot()
		guard case .serverRequestIssue(let issue) = events.first else {
			return XCTFail("Expected serverRequestIssue event")
		}
		XCTAssertEqual(issue.kind, .unsupportedMethod)
		XCTAssertEqual(issue.message, "Unsupported Codex server request method: workspace/unknownOperation")

		let payload = try XCTUnwrap(frameRecorder.lastPayload())
		let error = try XCTUnwrap(payload["error"] as? [String: Any])
		XCTAssertEqual(payload["id"] as? String, "req-unsupported")
		XCTAssertEqual(error["code"] as? Int, -32601)
		XCTAssertEqual(error["message"] as? String, "Unsupported Codex server request method: workspace/unknownOperation")
	}

	func testThreadStatusChangedNotificationEmitsLivenessActivity() async throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)
		await controller.test_bufferNotificationDuringBinding(
			CodexAppServerClient.Notification(
				method: "thread/status/changed",
				params: [
					"threadId": .string("thread-1"),
					"status": .object([
						"type": .string("active"),
						"active_flags": .array([.string("waiting_on_user_input")])
					])
				]
			)
		)

		let delivered = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(delivered)
		let events = await recorder.snapshot()
		guard case .livenessActivity(let activity) = events.first else {
			return XCTFail("Expected livenessActivity event")
		}
		XCTAssertEqual(activity.kind, .threadStatusChanged)
		XCTAssertEqual(activity.threadID, "thread-1")
		XCTAssertEqual(activity.activeFlags, ["waiting_on_user_input"])
	}

	func testStaleTurnLivenessNotificationIsDroppedThroughControllerRouting() async throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		_ = await controller.test_finishBinding(
			result: [
				"thread": [
					"id": "thread-1",
					"turns": [["id": "turn-current", "status": "inProgress"]]
				]
			],
			fallbackEffort: nil
		)
		await controller.test_bufferNotificationDuringBinding(
			CodexAppServerClient.Notification(
				method: "turn/plan/updated",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-stale")
				]
			)
		)

		try? await Task.sleep(nanoseconds: 100_000_000)
		let recordedCount = await recorder.count
		XCTAssertEqual(recordedCount, 0)
	}

	func testWrongThreadLivenessNotificationIsDropped() async throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)
		await controller.test_bufferNotificationDuringBinding(
			CodexAppServerClient.Notification(
				method: "thread/status/changed",
				params: [
					"threadId": .string("thread-other"),
					"status": .object(["type": .string("active")])
				]
			)
		)

		try? await Task.sleep(nanoseconds: 100_000_000)
		let recordedCount = await recorder.count
		XCTAssertEqual(recordedCount, 0)
	}

	func testRetryableErrorNotificationEmitsStructuredEvent() async throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)
		await controller.test_bufferNotificationDuringBinding(
			CodexAppServerClient.Notification(
				method: "error",
				params: [
					"error": .object([
						"message": .string("temporary outage"),
						"willRetry": .bool(true),
						"threadId": .string("thread-1"),
						"turnId": .string("turn-1")
					])
				]
			)
		)

		let delivered = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(delivered)
		let events = await recorder.snapshot()
		guard case .errorNotification(let error) = events.first else {
			return XCTFail("Expected errorNotification event")
		}
		XCTAssertEqual(error.message, "temporary outage")
		XCTAssertTrue(error.willRetry)
		XCTAssertEqual(error.threadID, "thread-1")
		XCTAssertEqual(error.turnID, "turn-1")
	}

	func testPreBindOverflowPreservesCriticalServerRequestAndTurnCompletion() async throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferServerRequestDuringBinding(
			CodexAppServerClient.ServerRequest(
				id: .int(77),
				method: "workspace/requestApproval",
				params: [
					"threadId": .string("thread-1"),
					"command": .string("ls"),
					"reason": .string("Need approval")
				]
			)
		)
		for index in 0..<140 {
			await controller.test_bufferNotificationDuringBinding(
				CodexAppServerClient.Notification(
					method: "thread/tokenUsage/updated",
					params: ["sequence": .number(Double(index))]
				)
			)
		}
		await controller.test_bufferNotificationDuringBinding(
			CodexAppServerClient.Notification(
				method: "turn/completed",
				params: [
					"threadId": .string("thread-1"),
					"turn": .object([
						"id": .string("turn-1"),
						"status": .string("completed")
					])
				]
			)
		)

		_ = await controller.test_finishBinding(
			result: [
				"thread": [
					"id": "thread-1",
					"turns": [["id": "turn-1", "status": "inProgress"]]
				]
			],
			fallbackEffort: nil
		)

		let delivered = await waitUntil(timeout: 1) {
			let events = await recorder.snapshot()
			let hasApproval = events.contains { event in
				if case .approvalRequest = event { return true }
				return false
			}
			let hasCompletion = events.contains { event in
				if case .turnCompleted = event { return true }
				return false
			}
			return hasApproval && hasCompletion
		}
		XCTAssertTrue(delivered)
	}

	func testBufferedAuthRefreshWithHandlerWritesSuccessResponseWithoutIssueEvent() async throws {
		let frameRecorder = OutboundFrameRecorder()
		let client = CodexAppServerClient(writeFrameHandler: { _, frame in
			frameRecorder.record(frame: frame)
		})
		await client.debugInstallTestTransport()
		let options = CodexNativeSessionController.Options(
			requestTimeout: nil,
			configOverridesProvider: { [:] },
			approvalPolicyProvider: { .never },
			sandboxModeProvider: { .readOnly },
			approvalReviewerProvider: { .user },
			authTokensRefreshHandler: { request in
				XCTAssertEqual(request.requestID, .int(77))
				XCTAssertEqual(request.reason, .unauthorized)
				XCTAssertEqual(request.previousAccountID, "acct-old")
				return CodexNativeSessionController.ChatgptAuthTokensRefreshResponse(
					accessToken: "token-123",
					chatgptAccountID: "acct-new",
					chatgptPlanType: "plus"
				)
			}
		)
		let controller = CodexNativeSessionController(
			client: client,
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			options: options
		)
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferServerRequestDuringBinding(
			CodexAppServerClient.ServerRequest(
				id: .int(77),
				method: "account/chatgptAuthTokens/refresh",
				params: [
					"reason": .string("unauthorized"),
					"previousAccountId": .string("acct-old")
				]
			)
		)
		_ = await controller.test_finishBinding(result: ["thread": ["id": "thread-1", "turns": []]], fallbackEffort: nil)
		try? await Task.sleep(nanoseconds: 50_000_000)

		let events = await recorder.snapshot()
		XCTAssertTrue(events.isEmpty)
		let payload = try XCTUnwrap(frameRecorder.lastPayload())
		XCTAssertEqual(payload["id"] as? Int, 77)
		let result = try XCTUnwrap(payload["result"] as? [String: Any])
		XCTAssertEqual(result["accessToken"] as? String, "token-123")
		XCTAssertEqual(result["chatgptAccountId"] as? String, "acct-new")
		XCTAssertEqual(result["chatgptPlanType"] as? String, "plus")
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

private final class OutboundFrameRecorder: @unchecked Sendable {
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

	func lastPayload() -> [String: Any]? {
		lock.lock()
		defer { lock.unlock() }
		return payloads.last
	}
}

private enum ExpectedPIDEvent: Equatable {
	case register(pid: pid_t, clientName: String, runID: UUID)
	case clear(pid: pid_t, clientName: String, runID: UUID)
}

private actor ExpectedPIDRecorder {
	private var events: [ExpectedPIDEvent] = []

	func record(_ event: ExpectedPIDEvent) {
		events.append(event)
	}

	func snapshot() -> [ExpectedPIDEvent] {
		events
	}
}

private actor EventRecorder {
	private var events: [CodexNativeSessionController.Event] = []

	func record(_ event: CodexNativeSessionController.Event) {
		events.append(event)
	}

	var count: Int {
		events.count
	}

	func snapshot() -> [CodexNativeSessionController.Event] {
		events
	}
}
