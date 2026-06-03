import XCTest
@testable import RepoPrompt

final class CodexNativeSessionControllerInboundEventCoverageTests: XCTestCase {
	func testMirroredCommandExecutionFixtureDeduplicatesDuplicateStreamsWithoutDuplicates() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		try await bufferFixtureNotifications(
			named: "codexlogs-live-bash-test-1-mirrored-deltas.jsonl",
			into: controller
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "019c81fc-a7bd-7ce1-abe1-cfc05f6bb895", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 11 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		XCTAssertEqual(events.count, 11)

		let toolCalls = events.compactMap { event -> (String, UUID?, String?)? in
			guard case .toolCall(let name, let invocationID, let argsJSON) = event else { return nil }
			return (name, invocationID, argsJSON)
		}
		XCTAssertEqual(toolCalls.count, 1)
		XCTAssertEqual(toolCalls.first?.0, "bash")
		XCTAssertNotNil(toolCalls.first?.1)

		let runningUpdates = events.compactMap { event -> CodexNativeSessionController.CommandExecutionRunningUpdate? in
			guard case .commandExecutionRunning(let update) = event else { return nil }
			return update
		}
		XCTAssertEqual(runningUpdates.count, 10)
		XCTAssertEqual(
			runningUpdates.compactMap(\.appendedOutput),
			[
				"stdout line 2\n",
				"stderr line 2\n",
				"stdout line 3\n",
				"stdout line 4\n",
				"stderr line 4\n",
				"stdout line 5\n",
				"bash-test-1: done\n",
			]
		)

		let terminalOnlyUpdates = runningUpdates.filter { $0.appendedOutput == nil }
		XCTAssertEqual(terminalOnlyUpdates.count, 3)
		XCTAssertEqual(Set(terminalOnlyUpdates.compactMap(\.processID)), ["47551"])
		XCTAssertEqual(Set(terminalOnlyUpdates.compactMap(\.invocationID)).count, 1)
		XCTAssertEqual(terminalOnlyUpdates.filter { $0.sealsAssistantBoundary }.count, 2)

		let toolResults = events.compactMap { event -> String? in
			guard case .toolResult(let name, _, _, _, _) = event else { return nil }
			return name
		}
		XCTAssertTrue(toolResults.isEmpty)
	}

	func testMirroredCommandExecutionDedupSurvivesUnrelatedTurnBoundaries() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "codex/event/exec_command_begin",
				params: [
					"conversationId": .string("thread-1"),
					"id": .string("turn-1"),
					"msg": .object([
						"type": .string("exec_command_begin"),
						"call_id": .string("call_1"),
						"command": .array([.string("echo hi")]),
						"process_id": .string("47551"),
						"cwd": .string("/tmp/work")
					])
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "item/started",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-1"),
					"item": .object([
						"type": .string("commandExecution"),
						"id": .string("call_1"),
						"command": .string("echo hi"),
						"processId": .string("47551"),
						"status": .string("inProgress")
					])
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "codex/event/exec_command_output_delta",
				params: [
					"conversationId": .string("thread-1"),
					"id": .string("turn-1"),
					"msg": .object([
						"type": .string("exec_command_output_delta"),
						"call_id": .string("call_1"),
						"chunk": .string("Zmlyc3QK")
					])
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "item/commandExecution/outputDelta",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-1"),
					"itemId": .string("call_1"),
					"delta": .string("first\n")
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "turn/started",
				params: [
					"threadId": .string("thread-1"),
					"turn": .object(["id": .string("turn-2")])
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "turn/completed",
				params: [
					"threadId": .string("thread-1"),
					"turn": .object([
						"id": .string("turn-2"),
						"status": .string("completed")
					])
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "codex/event/exec_command_output_delta",
				params: [
					"conversationId": .string("thread-1"),
					"id": .string("turn-1"),
					"msg": .object([
						"type": .string("exec_command_output_delta"),
						"call_id": .string("call_1"),
						"chunk": .string("c2Vjb25kCg==")
					])
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "item/commandExecution/outputDelta",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-1"),
					"itemId": .string("call_1"),
					"delta": .string("second\n")
				]
			)
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 6 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		let toolCalls = events.compactMap { event -> String? in
			guard case .toolCall(let name, _, _) = event else { return nil }
			return name
		}
		XCTAssertEqual(toolCalls, ["bash"])
		let appendedOutput = events.compactMap { event -> String? in
			guard case .commandExecutionRunning(let update) = event else { return nil }
			return update.appendedOutput
		}
		XCTAssertEqual(appendedOutput, ["first\n", "second\n"])
	}

	func testRawTerminalInteractionNotificationDoesNotTreatStdinAsOutput() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "codex/event/terminal_interaction",
				params: [
					"conversationId": .string("thread-1"),
					"id": .string("turn-1"),
					"msg": .object([
						"type": .string("terminal_interaction"),
						"call_id": .string("call_1"),
						"process_id": .string("47551"),
						"stdin": .string("")
					])
				]
			)
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		guard case .commandExecutionRunning(let update)? = events.first else {
			return XCTFail("Expected commandExecutionRunning event")
		}
		XCTAssertNotNil(update.invocationID)
		XCTAssertEqual(update.processID, "47551")
		XCTAssertNil(update.appendedOutput)
		XCTAssertTrue(update.sealsAssistantBoundary)
	}

	func testRawTerminalInteractionWithNonEmptyStdinDoesNotRequestAssistantBoundary() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "codex/event/terminal_interaction",
				params: [
					"conversationId": .string("thread-1"),
					"id": .string("turn-1"),
					"msg": .object([
						"type": .string("terminal_interaction"),
						"call_id": .string("call_1"),
						"process_id": .string("47551"),
						"stdin": .string("echo hello\n")
					])
				]
			)
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		guard case .commandExecutionRunning(let update)? = events.first else {
			return XCTFail("Expected commandExecutionRunning event")
		}
		XCTAssertFalse(update.sealsAssistantBoundary)
	}

	func testThreadCompactedNotificationEmitsStructuredContextCompactedEvent() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "thread/compacted",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-compact-1")
				]
			)
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		guard case .contextCompacted(let turnID)? = events.first else {
			return XCTFail("Expected contextCompacted event")
		}
		XCTAssertEqual(turnID, "turn-compact-1")
	}

	func testTaskCompleteDoesNotDuplicateCanonicalTurnCompletedEvent() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "turn/started",
				params: [
					"threadId": .string("thread-1"),
					"turn": .object(["id": .string("turn-1")])
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
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
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "codex/event/task_complete",
				params: [
					"conversationId": .string("thread-1"),
					"id": .string("turn-1"),
					"msg": .object([
						"type": .string("task_complete"),
						"turn_id": .string("turn-1")
					])
				]
			)
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 2 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		XCTAssertEqual(events.count, 2)
		guard case .turnStarted(let turnID)? = events.first else {
			return XCTFail("Expected turnStarted first")
		}
		XCTAssertEqual(turnID, "turn-1")
		guard case .turnCompleted(let completedTurnID, let status)? = events.last else {
			return XCTFail("Expected turnCompleted second")
		}
		XCTAssertEqual(completedTurnID, "turn-1")
		XCTAssertEqual(status, .completed)
	}

	func testRawMCPToolCallBeginAndEndEmitStructuredResultAndRunningUpdate() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		try await bufferFixtureNotifications(named: "codexlogs-write-stdin-running.jsonl", into: controller)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 3 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		guard events.count >= 3 else {
			return XCTFail("Expected three events")
		}
		if case .toolCall(let name, _, let argsJSON) = events[0] {
			XCTAssertEqual(name, "write_stdin")
			let argsObject = try XCTUnwrap(jsonObject(from: argsJSON))
			XCTAssertEqual(argsObject["session_id"] as? Double, 27588)
			XCTAssertEqual(argsObject["chars"] as? String, "")
			XCTAssertEqual(argsObject["yield_time_ms"] as? Double, 1000)
		} else {
			XCTFail("Expected toolCall first")
		}
		if case .toolResult(let name, _, _, let resultJSON, let isError) = events[1] {
			XCTAssertEqual(name, "write_stdin")
			let resultObject = try XCTUnwrap(jsonObject(from: resultJSON))
			let ok = try XCTUnwrap(resultObject["Ok"] as? [String: Any])
			let content = try XCTUnwrap(ok["content"] as? [[String: Any]])
			XCTAssertEqual(content.first?["type"] as? String, "text")
			XCTAssertEqual(content.first?["text"] as? String, #"{"status":"running"}"#)
			XCTAssertEqual(ok["isError"] as? Bool, false)
			XCTAssertEqual(isError, false)
		} else {
			XCTFail("Expected toolResult second")
		}
		if case .commandExecutionRunning(let update) = events[2] {
			XCTAssertEqual(update.processID, "session:27588")
			XCTAssertNil(update.appendedOutput)
			XCTAssertTrue(update.sealsAssistantBoundary)
		} else {
			XCTFail("Expected commandExecutionRunning third")
		}
	}

	func testRawMCPToolCallEventsEmitRepoPromptToolsForFallbackRendering() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "codex/event/mcp_tool_call_begin",
				params: [
					"msg": .object([
						"type": .string("mcp_tool_call_begin"),
						"call_id": .string("call_repo_prompt_1"),
						"invocation": .object([
							"tool": .string("read_file"),
							"server": .string(MCPIntegrationHelper.repoPromptMCPServerName),
							"arguments": .object(["path": .string("README.md")])
						])
					])
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "codex/event/mcp_tool_call_end",
				params: [
					"msg": .object([
						"type": .string("mcp_tool_call_end"),
						"call_id": .string("call_repo_prompt_1"),
						"invocation": .object([
							"tool": .string("read_file"),
							"server": .string(MCPIntegrationHelper.repoPromptMCPServerName),
							"arguments": .object(["path": .string("README.md")])
						]),
						"result": .object([
							"Ok": .object([
								"content": .array([
									.object([
										"type": .string("text"),
										"text": .string("hello")
									])
								]),
								"isError": .bool(false)
							])
						])
					])
				]
			)
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 2 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		XCTAssertEqual(events.count, 2)
		guard case .toolCall(let callName, let invocationID, let argsJSON)? = events.first else {
			return XCTFail("Expected toolCall first")
		}
		XCTAssertEqual(callName, "mcp__RepoPrompt__read_file")
		XCTAssertNotNil(invocationID)
		let argsObject = try XCTUnwrap(jsonObject(from: argsJSON))
		XCTAssertEqual(argsObject["path"] as? String, "README.md")
		guard case .toolResult(let resultName, let resultInvocationID, _, let resultJSON, let isError)? = events.last else {
			return XCTFail("Expected toolResult second")
		}
		XCTAssertEqual(resultName, "mcp__RepoPrompt__read_file")
		XCTAssertEqual(resultInvocationID, invocationID)
		XCTAssertEqual(isError, false)
		let resultObject = try XCTUnwrap(jsonObject(from: resultJSON))
		XCTAssertNotNil(resultObject["Ok"])
	}

	func testRawMCPToolCallEventsRemainLiveAfterTurnStarts() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "turn/started",
				params: ["turn": .object(["id": .string("turn-live")])]
			)
		)
		try await bufferFixtureNotifications(named: "codexlogs-write-stdin-running.jsonl", into: controller)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 4 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		XCTAssertEqual(events.count, 4)
		guard case .turnStarted(_) = events[0] else {
			return XCTFail("Expected turnStarted first")
		}
		guard case .toolCall(let name, _, _) = events[1] else {
			return XCTFail("Expected toolCall second")
		}
		XCTAssertEqual(name, "write_stdin")
		guard case .toolResult(let resultName, _, _, _, _) = events[2] else {
			return XCTFail("Expected toolResult third")
		}
		XCTAssertEqual(resultName, "write_stdin")
		guard case .commandExecutionRunning(let update) = events[3] else {
			return XCTFail("Expected commandExecutionRunning fourth")
		}
		XCTAssertEqual(update.processID, "session:27588")
	}

	func testNormalizedCommandExecutionNotificationsEmitBashLifecycleAndRunningUpdates() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "item/started",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-1"),
					"item": .object([
						"type": .string("commandExecution"),
						"id": .string("call_1"),
						"command": .string("echo hi"),
						"cwd": .string("/tmp/work"),
						"processId": .string("47551"),
						"status": .string("inProgress")
					])
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "item/commandExecution/outputDelta",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-1"),
					"itemId": .string("call_1"),
					"delta": .string("stdout line 2\n")
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "item/commandExecution/terminalInteraction",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-1"),
					"itemId": .string("call_1"),
					"processId": .string("47551"),
					"stdin": .string("")
				]
			)
		)
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "item/completed",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-1"),
					"item": .object([
						"type": .string("commandExecution"),
						"id": .string("call_1"),
						"command": .string("echo hi"),
						"processId": .string("47551"),
						"status": .string("completed"),
						"exitCode": .number(0),
						"aggregatedOutput": .string("stdout line 2\n")
					])
				]
			)
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 4 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		XCTAssertEqual(events.count, 4)

		guard case .toolCall(let toolName, _, let argsJSON) = events[0] else {
			return XCTFail("Expected first event to be toolCall")
		}
		XCTAssertEqual(toolName, "bash")
		let argsObject = try XCTUnwrap(jsonObject(from: argsJSON))
		XCTAssertEqual(argsObject["command"] as? String, "echo hi")
		XCTAssertEqual(argsObject["processId"] as? String, "47551")

		guard case .commandExecutionRunning(let deltaUpdate) = events[1] else {
			return XCTFail("Expected second event to be commandExecutionRunning")
		}
		XCTAssertEqual(deltaUpdate.appendedOutput, "stdout line 2\n")
		XCTAssertFalse(deltaUpdate.sealsAssistantBoundary)

		guard case .commandExecutionRunning(let terminalUpdate) = events[2] else {
			return XCTFail("Expected third event to be commandExecutionRunning")
		}
		XCTAssertEqual(terminalUpdate.processID, "47551")
		XCTAssertNil(terminalUpdate.appendedOutput)
		XCTAssertTrue(terminalUpdate.sealsAssistantBoundary)

		guard case .toolResult(let resultName, _, _, let resultJSON, let isError) = events[3] else {
			return XCTFail("Expected fourth event to be toolResult")
		}
		XCTAssertEqual(resultName, "bash")
		XCTAssertEqual(isError, false)
		let resultObject = try XCTUnwrap(jsonObject(from: resultJSON))
		XCTAssertEqual(resultObject["status"] as? String, "completed")
		XCTAssertEqual(resultObject["processId"] as? String, "47551")
		XCTAssertEqual(resultObject["aggregatedOutput"] as? String, "stdout line 2\n")
	}

	func testNormalizedTerminalInteractionWithNonEmptyStdinDoesNotRequestAssistantBoundary() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "item/commandExecution/terminalInteraction",
				params: [
					"threadId": .string("thread-1"),
					"turnId": .string("turn-1"),
					"itemId": .string("call_1"),
					"processId": .string("47551"),
					"stdin": .string("echo hi\n")
				]
			)
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		let drained = await waitUntil(timeout: 1) { await recorder.count == 1 }
		XCTAssertTrue(drained)
		let events = await recorder.snapshot()
		guard case .commandExecutionRunning(let update)? = events.first else {
			return XCTFail("Expected commandExecutionRunning event")
		}
		XCTAssertEqual(update.processID, "47551")
		XCTAssertNil(update.appendedOutput)
		XCTAssertFalse(update.sealsAssistantBoundary)
	}

	func testRawAgentReasoningNotificationIsIgnoredUntilReasoningCanonicalizationIsImplemented() async throws {
		let controller = makeController()
		let recorder = EventRecorder()
		let eventTask = Task {
			for await event in controller.events {
				await recorder.record(event)
			}
		}
		defer { eventTask.cancel() }

		try await controller.test_beginBindingSession()
		await controller.test_bufferNotificationDuringBinding(
			.init(
				method: "codex/event/agent_reasoning",
				params: [
					"conversationId": .string("thread-1"),
					"id": .string("turn-1"),
					"msg": .object([
						"type": .string("agent_reasoning"),
						"turn_id": .string("turn-1"),
						"text": .string("Planning next steps")
					])
				]
			)
		)
		_ = await controller.test_finishBinding(
			result: ["thread": ["id": "thread-1", "turns": []]],
			fallbackEffort: nil
		)

		try? await Task.sleep(nanoseconds: 100_000_000)
		let eventCount = await recorder.count
		XCTAssertEqual(eventCount, 0)
	}

	private func makeController() -> CodexNativeSessionController {
		CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
	}

	private func bufferFixtureNotifications(
		named fixtureName: String,
		into controller: CodexNativeSessionController
	) async throws {
		let fixtureURL = codexSessionFixtureURL(named: fixtureName)
		let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
		for rawLine in contents.split(whereSeparator: \.isNewline) {
			let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !line.isEmpty else { continue }
			let data = try XCTUnwrap(line.data(using: .utf8))
			let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
			let method = try XCTUnwrap(object["method"] as? String)
			let payload = try XCTUnwrap(object["payload"] as? [String: Any])
			await controller.test_bufferNotificationDuringBinding(
				.init(method: method, params: codexJSONDictionary(from: payload))
			)
		}
	}

	private func codexSessionFixtureURL(named fixtureName: String) -> URL {
		let testFileURL = URL(fileURLWithPath: #filePath, isDirectory: false)
		return testFileURL
			.deletingLastPathComponent()
			.appendingPathComponent("Fixtures")
			.appendingPathComponent("CodexSessions")
			.appendingPathComponent(fixtureName)
	}

	private func codexJSONDictionary(from value: [String: Any]) -> [String: CodexJSONValue] {
		var output: [String: CodexJSONValue] = [:]
		for (key, rawValue) in value {
			if let converted = CodexJSONValue.from(rawValue) {
				output[key] = converted
			}
		}
		return output
	}

	private func jsonObject(from raw: String?) -> [String: Any]? {
		guard let raw, let data = raw.data(using: .utf8) else { return nil }
		return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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
