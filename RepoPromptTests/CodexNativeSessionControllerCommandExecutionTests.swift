import XCTest
@testable import RepoPrompt

final class CodexNativeSessionControllerCommandExecutionTests: XCTestCase {
	func testShutdownFinishesEventsStream() async {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		let streamFinished = expectation(description: "events stream finished")
		let readerTask = Task {
			for await _ in controller.events {
				// Drain until shutdown finishes the stream.
			}
			streamFinished.fulfill()
		}

		controller.ensureEventsStreamReady()
		try? await Task.sleep(nanoseconds: 20_000_000)
		await controller.shutdown()
		await fulfillment(of: [streamFinished], timeout: 1.0)
		readerTask.cancel()
	}

	func testParseToolLifecycleEventAllowsRepoPromptToolCandidatesForNativeFallback() {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		let explicitPrefixEvent = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "function_call",
					"id": "repo_prompt_prefixed",
					"name": "mcp__RepoPrompt__read_file",
					"arguments": ["path": "README.md"]
				]
			]
		)
		XCTAssertEqual(explicitPrefixEvent?.name, "mcp__RepoPrompt__read_file")
		XCTAssertNotNil(explicitPrefixEvent?.invocationID)
		let explicitArgsObject = try? XCTUnwrap(jsonObject(from: explicitPrefixEvent?.argsJSON))
		XCTAssertEqual(explicitArgsObject?["path"] as? String, "README.md")

		let serverIdentifiedEvent = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "function_call",
					"id": "repo_prompt_server",
					"name": "read_file",
					"serverName": MCPIntegrationHelper.repoPromptMCPServerName,
					"arguments": ["path": "README.md"]
				]
			]
		)
		XCTAssertEqual(serverIdentifiedEvent?.name, "mcp__RepoPrompt__read_file")
		XCTAssertNotNil(serverIdentifiedEvent?.invocationID)
	}

	func testParseToolLifecycleEventParsesNormalizedCommandExecutionStartedAsBashCall() throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "commandExecution",
					"id": "call_exec_1",
					"command": "echo hi",
					"cwd": "/tmp/work",
					"processId": "47551",
					"commandActions": [["type": "unknown", "command": "echo hi"]],
				]
			]
		))

		XCTAssertEqual(started.kind, "call")
		XCTAssertEqual(started.name, "bash")
		let argsObject = try XCTUnwrap(jsonObject(from: started.argsJSON))
		XCTAssertEqual(argsObject["command"] as? String, "echo hi")
		XCTAssertEqual(argsObject["cwd"] as? String, "/tmp/work")
		XCTAssertEqual(argsObject["processId"] as? String, "47551")
		XCTAssertEqual((argsObject["commandActions"] as? [[String: Any]])?.count, 1)
	}

	func testParseToolLifecycleEventParsesNormalizedCommandExecutionCompletedAsBashResult() throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		_ = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "commandExecution",
					"id": "call_exec_1",
					"command": "echo hi",
					"processId": "47551",
				]
			]
		)
		let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
			method: "item/completed",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "commandExecution",
					"id": "call_exec_1",
					"command": "echo hi",
					"processId": "47551",
					"status": "completed",
					"exitCode": 0,
					"aggregatedOutput": "hi\n",
				]
			]
		))

		XCTAssertEqual(completed.kind, "result")
		XCTAssertEqual(completed.name, "bash")
		XCTAssertEqual(completed.isError, false)
		let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
		XCTAssertEqual(resultObject["type"] as? String, "commandExecution")
		XCTAssertEqual(resultObject["status"] as? String, "completed")
		XCTAssertEqual(resultObject["processId"] as? String, "47551")
		XCTAssertEqual(resultObject["aggregatedOutput"] as? String, "hi\n")
		XCTAssertEqual(resultObject["exitCode"] as? Int, 0)
	}

	func testParseToolLifecycleEventIgnoresNormalizedMCPToolCallMirrors() {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		let started = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "mcpToolCall",
					"id": "call_mcp_1",
					"name": "write_stdin",
					"arguments": ["session_id": 27588, "chars": ""]
				]
			]
		)
		let completed = controller.test_parseToolLifecycleEvent(
			method: "item/completed",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "mcpToolCall",
					"id": "call_mcp_1",
					"name": "write_stdin",
					"arguments": ["session_id": 27588, "chars": ""],
					"result": ["status": "running"]
				]
			]
		)

		XCTAssertNil(started)
		XCTAssertNil(completed)
	}

	func testParseFileChangeLifecycleStartedSynthesizesApplyPatchCall() throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		let event = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_1",
					"status": "inProgress",
					"changes": [[
						"path": "/tmp/file.swift",
						"kind": ["type": "update"],
						"diff": "@@ -1 +1 @@\n-old\n+new"
					]]
				]
			]
		)

		XCTAssertEqual(event?.kind, "call")
		XCTAssertEqual(event?.name, "apply_patch")
		let argsObject = try XCTUnwrap(jsonObject(from: event?.argsJSON))
		XCTAssertEqual(argsObject["path"] as? String, "/tmp/file.swift")
		XCTAssertEqual(argsObject["change_count"] as? Int, 1)
	}

	func testParseFileChangeOutputDeltaAndCompletionPreserveOutput() throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		_ = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_1",
					"status": "inProgress",
					"changes": [[
						"path": "/tmp/file.swift",
						"kind": ["type": "update"],
						"diff": "@@ -1 +1 @@\n-old\n+new"
					]]
				]
			]
		)

		let deltaEvent = try XCTUnwrap(controller.test_parseFileChangeOutputDeltaEvent(params: [
			"threadId": "thread-active",
			"turnId": "turn-current",
			"itemId": "call_patch_1",
			"delta": "Applying patch...\n"
		]))
		let deltaObject = try XCTUnwrap(jsonObject(from: deltaEvent.resultJSON))
		XCTAssertEqual(deltaEvent.name, "apply_patch")
		XCTAssertEqual(deltaObject["status"] as? String, "running")
		XCTAssertEqual(deltaObject["output"] as? String, "Applying patch...\n")

		let completedEvent = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
			method: "item/completed",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_1",
					"status": "completed",
					"changes": [[
						"path": "/tmp/file.swift",
						"kind": ["type": "update"],
						"diff": "@@ -1 +1 @@\n-old\n+new"
					]]
				]
			]
		))
		let completedObject = try XCTUnwrap(jsonObject(from: completedEvent.resultJSON))
		XCTAssertEqual(completedEvent.kind, "result")
		XCTAssertEqual(completedEvent.name, "apply_patch")
		XCTAssertEqual(completedEvent.isError, false)
		XCTAssertEqual(completedObject["status"] as? String, "success")
		XCTAssertEqual(completedObject["output"] as? String, "Applying patch...\n")
	}

	func testParseFileChangeCompletionWithoutStatusDefaultsToSuccess() throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		_ = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_no_status",
					"changes": [[
						"path": "/tmp/file.swift",
						"kind": ["type": "update"],
						"diff": "@@ -1 +1 @@\n-old\n+new"
					]]
				]
			]
		)

		_ = controller.test_parseFileChangeOutputDeltaEvent(params: [
			"threadId": "thread-active",
			"turnId": "turn-current",
			"itemId": "call_patch_no_status",
			"delta": "Applying patch...\n"
		])

		let completedEvent = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
			method: "item/completed",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_no_status",
					"changes": [[
						"path": "/tmp/file.swift",
						"kind": ["type": "update"],
						"diff": "@@ -1 +1 @@\n-old\n+new"
					]]
				]
			]
		))
		let completedObject = try XCTUnwrap(jsonObject(from: completedEvent.resultJSON))

		XCTAssertEqual(completedEvent.kind, "result")
		XCTAssertEqual(completedEvent.name, "apply_patch")
		XCTAssertEqual(completedEvent.isError, false)
		XCTAssertEqual(completedObject["status"] as? String, "success")
		XCTAssertEqual(completedObject["output"] as? String, "Applying patch...\n")
	}

	func testParseFileChangeOutputDeltaPreservesWhitespaceOnlyChunkAndEmptyDiff() throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)

		_ = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_empty",
					"status": "inProgress",
					"changes": [[
						"path": "/tmp/empty.txt",
						"kind": ["type": "add"],
						"diff": ""
					]]
				]
			]
		)

		let deltaEvent = try XCTUnwrap(controller.test_parseFileChangeOutputDeltaEvent(params: [
			"itemId": "call_patch_empty",
			"delta": "\n"
		]))
		let deltaObject = try XCTUnwrap(jsonObject(from: deltaEvent.resultJSON))
		XCTAssertEqual(deltaObject["output"] as? String, "\n")

		let completedEvent = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
			method: "item/completed",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_empty",
					"status": "completed",
					"changes": [[
						"path": "/tmp/empty.txt",
						"kind": ["type": "add"],
						"diff": ""
					]]
				]
			]
		))
		let completedObject = try XCTUnwrap(jsonObject(from: completedEvent.resultJSON))
		let changes = try XCTUnwrap(completedObject["changes"] as? [[String: Any]])
		XCTAssertEqual(completedObject["output"] as? String, "\n")
		XCTAssertEqual(changes.count, 1)
		XCTAssertEqual(changes.first?["path"] as? String, "/tmp/empty.txt")
		XCTAssertEqual(changes.first?["diff"] as? String, "")
	}

	func testCommandExecutionEndIsErrorTreatsNegativeExitCodeAsError() {
		let isError = CodexNativeSessionController.test_commandExecutionEndIsError(
			exitCode: -1,
			status: "finished"
		)

		XCTAssertEqual(isError, true)
	}

	func testCommandExecutionEndIsErrorRespectsExplicitSuccessStatus() {
		let isError = CodexNativeSessionController.test_commandExecutionEndIsError(
			exitCode: -1,
			status: "success"
		)

		XCTAssertEqual(isError, false)
	}

	func testCommandExecutionEndIsErrorTreatsCancelledAsFailureEvenWithZeroExitCode() {
		let isError = CodexNativeSessionController.test_commandExecutionEndIsError(
			exitCode: 0,
			status: "cancelled"
		)

		XCTAssertEqual(isError, true)
	}

	func testWriteStdinStructuredRunningProducesCommandRunningUpdate() {
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "functions.write_stdin",
			argsJSON: #"{"session_id":59802,"chars":"","yield_time_ms":1000}"#,
			resultJSON: #"{"status":"running"}"#,
			isError: false
		)

		XCTAssertEqual(update?.processID, "session:59802")
		XCTAssertTrue(update?.sealsAssistantBoundary ?? false)
	}

	func testWriteStdinStructuredMCPEnvelopeRunningProducesCommandRunningUpdate() {
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "functions.write_stdin",
			argsJSON: #"{"session_id":59802,"chars":"","yield_time_ms":1000}"#,
			resultJSON: #"{"Ok":{"content":[{"type":"text","text":"{\"status\":\"running\"}"}],"isError":false}}"#,
			isError: false
		)

		XCTAssertEqual(update?.processID, "session:59802")
		XCTAssertTrue(update?.sealsAssistantBoundary ?? false)
	}

	func testWriteStdinRunningWithInputDoesNotRequestAssistantBoundary() {
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "functions.write_stdin",
			argsJSON: #"{"session_id":59802,"chars":"echo hello\n","yield_time_ms":1000}"#,
			resultJSON: #"{"status":"running"}"#,
			isError: false
		)

		XCTAssertEqual(update?.processID, "session:59802")
		XCTAssertFalse(update?.sealsAssistantBoundary ?? true)
	}

	func testWriteStdinTextOutputDoesNotProduceCommandRunningUpdate() {
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "functions.write_stdin",
			argsJSON: #"{"session_id":59802,"chars":"","yield_time_ms":1000}"#,
			resultJSON: "Process running with session ID 59802",
			isError: nil
		)

		XCTAssertNil(update)
	}

	func testWriteStdinStructuredCompletedDoesNotProduceCommandRunningUpdate() {
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "functions.write_stdin",
			argsJSON: #"{"session_id":59802,"chars":"","yield_time_ms":1000}"#,
			resultJSON: #"{"status":"completed"}"#,
			isError: false
		)

		XCTAssertNil(update)
	}

	func testWriteStdinStructuredOkDoesNotProduceCommandRunningUpdate() {
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "functions.write_stdin",
			argsJSON: #"{"session_id":59802,"chars":"","yield_time_ms":1000}"#,
			resultJSON: #"{"status":"ok"}"#,
			isError: false
		)

		XCTAssertNil(update)
	}

	func testBashExecCommandOutputProducesCommandRunningUpdate() {
		let raw = """
		Chunk ID: f43c2a
		Wall time: 10.112 seconds
		Process running with session ID 62454
		Original token count: 120
		Output:
		Compiled successfully!
		http://127.0.0.1:3000
		"""
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "exec_command",
			argsJSON: #"{"cmd":"npm start"}"#,
			resultJSON: raw,
			isError: false
		)

		XCTAssertEqual(update?.processID, "62454")
		XCTAssertTrue(update?.appendedOutput?.contains("Compiled successfully!") == true)
	}

	func testBashExecCommandOutputRunningUpdateSanitizesANSIAndControlSequences() {
		let esc = "\u{001B}"
		let raw = """
		Chunk ID: f43c2a
		Wall time: 10.112 seconds
		Process running with session ID 62454
		Original token count: 120
		Output:
		\(esc)[2J\(esc)[3J\(esc)[H\(esc)[?25l\(esc)[36m?\(esc)[39m port 3000 busy
		would run on another port? (Y/n)\u{000D}no
		progress: 10%\u{0008}\u{0008}42%
		"""
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "exec_command",
			argsJSON: #"{"cmd":"npm start"}"#,
			resultJSON: raw,
			isError: false
		)

		let output = update?.appendedOutput ?? ""
		XCTAssertEqual(update?.processID, "62454")
		XCTAssertFalse(output.contains("\u{001B}"))
		XCTAssertTrue(output.contains("port 3000 busy"))
		XCTAssertTrue(output.contains("no"))
		XCTAssertTrue(output.contains("42%"))
	}

	func testBashStructuredRunningPayloadProducesCommandRunningUpdate() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "running",
		  "processId": "56616",
		  "aggregatedOutput": "Starting the development server...\\nCompiled successfully!"
		}
		"""
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "bash",
			argsJSON: #"{"command":"npm start"}"#,
			resultJSON: payload,
			isError: false
		)

		XCTAssertEqual(update?.processID, "56616")
		XCTAssertTrue(update?.appendedOutput?.contains("Compiled successfully!") == true)
	}

	func testBashStructuredCompletedPayloadDoesNotProduceCommandRunningUpdate() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "completed",
		  "processId": "56616",
		  "aggregatedOutput": "Done."
		}
		"""
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "bash",
			argsJSON: #"{"command":"sleep 1"}"#,
			resultJSON: payload,
			isError: false
		)

		XCTAssertNil(update)
	}

	func testBashStructuredSuccessPayloadDoesNotProduceCommandRunningUpdate() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "success",
		  "processId": "56616",
		  "success": true
		}
		"""
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "bash",
			argsJSON: #"{"command":"sleep 1"}"#,
			resultJSON: payload,
			isError: false
		)

		XCTAssertNil(update)
	}

	func testBashStructuredNegativeExitWithProcessIDStillProducesCommandRunningUpdate() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": -1,
		  "processId": "56616",
		  "aggregatedOutput": "still running\\n"
		}
		"""
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "bash",
			argsJSON: #"{"command":"sleep 1"}"#,
			resultJSON: payload,
			isError: false
		)

		XCTAssertEqual(update?.processID, "56616")
		XCTAssertEqual(update?.appendedOutput, "still running\n")
	}

	func testBashStructuredNegativeExitWithoutProcessIDDoesNotProduceCommandRunningUpdate() {
		let payload = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": -1,
		  "aggregatedOutput": "still running\\n"
		}
		"""
		let update = CodexNativeSessionController.commandExecutionRunningUpdate(
			fromToolName: "bash",
			argsJSON: #"{"command":"sleep 1"}"#,
			resultJSON: payload,
			isError: false
		)

		XCTAssertNil(update)
	}

	func testApplyCommandExecutionRunningUpdateClearsFailureAndMarksRunning() throws {
		let failed = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": 1,
		  "processId": "27588",
		  "command": "npm start"
		}
		"""
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: failed,
				isError: true,
				sequenceIndex: 0
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "27588", appendedOutput: "ready\n"),
			to: &items
		)

		XCTAssertTrue(changed)
		XCTAssertEqual(items.first?.toolIsError, false)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "running")
		XCTAssertNil(object["exitCode"])
	}

	func testApplyCommandExecutionRunningUpdateTreatsNegativeExitWithProcessIDAsNonTerminal() throws {
		let wrapperFailed = #"{"type":"commandExecution","status":"failed","exitCode":-1,"processId":"27588","command":"npm start"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: wrapperFailed,
				isError: false,
				sequenceIndex: 0
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "27588", appendedOutput: "ready\n"),
			to: &items
		)

		XCTAssertTrue(changed)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "running")
		XCTAssertNil(object["exitCode"])
		XCTAssertEqual(object["aggregatedOutput"] as? String, "ready\n")
	}

	func testApplyCommandExecutionRunningUpdateIgnoresTerminalCompletedItem() throws {
		let completed = #"{"status":"completed","exitCode":0,"processId":"27588","command":"npm start"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: completed,
				isError: false,
				sequenceIndex: 0
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "27588", appendedOutput: "late output\n"),
			to: &items
		)

		XCTAssertFalse(changed)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "completed")
		XCTAssertEqual(object["exitCode"] as? Int, 0)
		XCTAssertNil(object["aggregatedOutput"])
	}

	func testApplyCommandExecutionRunningUpdateIgnoresSummaryOnlySuccessItem() throws {
		let summaryOnly = #"{"status":"success","summary_only":true}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: summaryOnly,
				isError: false,
				sequenceIndex: 0
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: nil, appendedOutput: "late output\n"),
			to: &items
		)

		XCTAssertFalse(changed)
		XCTAssertEqual(items.first?.toolResultJSON, summaryOnly)
	}

	func testApplyCommandExecutionRunningUpdateIgnoresTerminalOkStatusItem() throws {
		let terminalOK = #"{"status":"ok","processId":"27588","command":"npm start"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: terminalOK,
				isError: false,
				sequenceIndex: 0
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "27588", appendedOutput: "late output\n"),
			to: &items
		)

		XCTAssertFalse(changed)
		XCTAssertEqual(items.first?.toolResultJSON, terminalOK)
	}

	func testWithCommandExecutionCompletedStatusMarksTerminalAndPreservesOutput() throws {
		let raw = #"{"type":"commandExecution","processId":"123","aggregatedOutput":"done"}"#
		let patched = CodexNativeSessionController.test_withCommandExecutionCompletedStatus(raw: raw)
		let object = try XCTUnwrap(jsonObject(from: patched))

		XCTAssertEqual(object["type"] as? String, "commandExecution")
		XCTAssertEqual(object["status"] as? String, "completed")
		XCTAssertEqual(object["processId"] as? String, "123")
		XCTAssertEqual(object["aggregatedOutput"] as? String, "done")
		XCTAssertNil(object["exitCode"])
	}

	func testWithCommandExecutionCompletedStatusDropsNegativeExitCode() throws {
		let raw = #"{"type":"commandExecution","status":"failed","exitCode":-1,"processId":"123"}"#
		let patched = CodexNativeSessionController.test_withCommandExecutionCompletedStatus(raw: raw)
		let object = try XCTUnwrap(jsonObject(from: patched))

		XCTAssertEqual(object["status"] as? String, "completed")
		XCTAssertNil(object["exitCode"])
	}

	// MARK: - parseExecCommandEndEvent shaping

	func testParseExecCommandEndEventDropsNegativeExitCodeAndIncludesDuration() throws {
		let params: [String: Any] = [
			"msg": [
				"type": "exec_command_end",
				"call_id": "call_test_1",
				"process_id": "85178",
				"status": "failed",
				"exit_code": -1,
				"aggregated_output": "hello world\n",
				"duration": ["secs": 53, "nanos": 758_018_416]
			] as [String: Any]
		]

		let resultJSON = try XCTUnwrap(
			CodexNativeSessionController.test_parseExecCommandEndEventResultJSON(params: params)
		)
		let object = try XCTUnwrap(jsonObject(from: resultJSON))

		XCTAssertEqual(object["status"] as? String, "failed")
		XCTAssertEqual(object["processId"] as? String, "85178")
		XCTAssertNil(object["exitCode"], "Negative exit code should be stripped from end-event payloads")
		XCTAssertEqual(object["durationMs"] as? Int, 53758)
		XCTAssertEqual(object["aggregatedOutput"] as? String, "hello world\n")
	}

	func testParseExecCommandEndEventPrefersAggregatedOutputOverStdout() throws {
		let params: [String: Any] = [
			"msg": [
				"type": "exec_command_end",
				"call_id": "call_test_2",
				"process_id": "999",
				"status": "completed",
				"exit_code": 0,
				"stdout": "partial",
				"aggregated_output": "full combined output\n",
				"duration_ms": 1200
			] as [String: Any]
		]

		let resultJSON = try XCTUnwrap(
			CodexNativeSessionController.test_parseExecCommandEndEventResultJSON(params: params)
		)
		let object = try XCTUnwrap(jsonObject(from: resultJSON))

		XCTAssertEqual(object["aggregatedOutput"] as? String, "full combined output\n")
		XCTAssertEqual(object["exitCode"] as? Int, 0)
		XCTAssertEqual(object["durationMs"] as? Int, 1200)
	}

	func testParseExecCommandEndEventPreservesPositiveExitCode() throws {
		let params: [String: Any] = [
			"msg": [
				"type": "exec_command_end",
				"call_id": "call_test_3",
				"process_id": "42",
				"status": "failed",
				"exit_code": 1,
				"output": "error output\n"
			] as [String: Any]
		]

		let resultJSON = try XCTUnwrap(
			CodexNativeSessionController.test_parseExecCommandEndEventResultJSON(params: params)
		)
		let object = try XCTUnwrap(jsonObject(from: resultJSON))

		XCTAssertEqual(object["status"] as? String, "failed")
		XCTAssertEqual(object["exitCode"] as? Int, 1)
	}

	func testApplyCommandExecutionRunningUpdateMatchesTypeLessProcessIDBeforeFallback() throws {
		let first = #"{"status":"running","processId":"111","command":"first"}"#
		let second = #"{"status":"running","processId":"222","command":"second"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: first,
				isError: false,
				sequenceIndex: 0
			),
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: second,
				isError: false,
				sequenceIndex: 1
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "111", appendedOutput: "first-output\n"),
			to: &items
		)

		XCTAssertTrue(changed)
		let firstObject = try XCTUnwrap(jsonObject(from: items[0].toolResultJSON))
		let secondObject = try XCTUnwrap(jsonObject(from: items[1].toolResultJSON))
		XCTAssertEqual(firstObject["processId"] as? String, "111")
		XCTAssertTrue((firstObject["aggregatedOutput"] as? String)?.contains("first-output") == true)
		XCTAssertEqual(secondObject["processId"] as? String, "222")
		XCTAssertNil(secondObject["aggregatedOutput"])
	}

	func testApplyCommandExecutionRunningUpdateDoesNotRecoverErroredItemWithoutCorrelation() throws {
		let failed = #"{"type":"commandExecution","status":"failed","exitCode":1,"processId":"27588","command":"npm start"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: failed,
				isError: true,
				sequenceIndex: 0
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: nil, appendedOutput: "retrying\n"),
			to: &items
		)

		XCTAssertFalse(changed)
		XCTAssertEqual(items.first?.toolIsError, true)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "failed")
		XCTAssertEqual(object["exitCode"] as? Int, 1)
		XCTAssertNil(object["aggregatedOutput"])
	}

	func testApplyCommandExecutionRunningUpdateDoesNotUseAmbiguousFallbackWithoutCorrelation() {
		let first = #"{"type":"commandExecution","status":"running","command":"first"}"#
		let second = #"{"type":"commandExecution","status":"running","command":"second"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: first,
				isError: false,
				sequenceIndex: 0
			),
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: second,
				isError: false,
				sequenceIndex: 1
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: nil, appendedOutput: "ambiguous\n"),
			to: &items
		)

		XCTAssertFalse(changed)
		XCTAssertEqual(items[0].toolResultJSON, first)
		XCTAssertEqual(items[1].toolResultJSON, second)
	}

	func testMatchingBashToolResultIndexRequiresUniqueRunningFallback() {
		let first = #"{"type":"commandExecution","status":"running","command":"first"}"#
		let second = #"{"type":"commandExecution","status":"running","command":"second"}"#
		let result = #"{"type":"commandExecution","status":"completed"}"#
		let items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: first,
				isError: false,
				sequenceIndex: 0
			),
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: second,
				isError: false,
				sequenceIndex: 1
			)
		]

		let index = CodexNativeSessionController.matchingBashToolResultIndex(
			in: items,
			toolName: "bash",
			invocationID: nil,
			argsJSON: nil,
			resultJSON: result
		)

		XCTAssertNil(index)
	}

	func testReconcilePersistedCommandExecutionStatusesUsesStructuredSignals() throws {
		let failed = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": 1,
		  "processId": "27588",
		  "command": "npm start"
		}
		"""
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: failed,
				isError: true,
				sequenceIndex: 0
			)
		]

		let rolloutPath = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-rollout-\(UUID().uuidString).jsonl")
		let contents = """
		{"type":"response_item","payload":{"type":"function_call","call_id":"call_1","name":"functions.write_stdin","arguments":"{\\"session_id\\":27588,\\"chars\\":\\"\\",\\"yield_time_ms\\":1000}"}}
		{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"{\\"status\\":\\"running\\"}"}}
		"""
		try contents.write(to: rolloutPath, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: rolloutPath) }

		let changed = CodexNativeSessionController.reconcilePersistedCommandExecutionStatuses(
			in: &items,
			rolloutPath: rolloutPath.path
		)

		XCTAssertTrue(changed)
		XCTAssertEqual(items.first?.toolIsError, false)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "running")
	}

	func testReconcilePersistedCommandExecutionStatusesRecoversOutputFromExecCommandCallOutput() throws {
		let failed = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": -1,
		  "processId": "25909",
		  "id": "call_BJWkH2bPvNnN5UZRKacNT5wR",
		  "command": "ls -1"
		}
		"""
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: failed,
				isError: true,
				sequenceIndex: 0
			)
		]

		let rolloutPath = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-rollout-\(UUID().uuidString).jsonl")
		let contents = """
		{"type":"response_item","payload":{"type":"function_call","call_id":"call_BJWkH2bPvNnN5UZRKacNT5wR","name":"exec_command","arguments":"{\\"cmd\\":\\"cd /Users/example/Documents/Git/RepoPromptWeb && ls -1\\"}"}}
		{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_BJWkH2bPvNnN5UZRKacNT5wR","output":"Chunk ID: a9f899\\nWall time: 10.0014 seconds\\nProcess running with session ID 25909\\nOriginal token count: 100\\nOutput:\\npackage.json\\nsrc\\npublic\\n"}}
		"""
		try contents.write(to: rolloutPath, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: rolloutPath) }

		let changed = CodexNativeSessionController.reconcilePersistedCommandExecutionStatuses(
			in: &items,
			rolloutPath: rolloutPath.path
		)

		XCTAssertTrue(changed)
		XCTAssertEqual(items.first?.toolIsError, false)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "running")
		XCTAssertTrue((object["aggregatedOutput"] as? String)?.contains("package.json") == true)
		XCTAssertNil(object["exitCode"])
	}

	func testReconcilePersistedCommandExecutionStatusesRecoversOutputFromCodexRawExecDeltaFixture() throws {
		let failed = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": -1,
		  "processId": "59757",
		  "id": "call_live_exec_1",
		  "command": "printf 'alpha\\n'"
		}
		"""
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: failed,
				isError: true,
				sequenceIndex: 0
			)
		]

		let rolloutPath = try materializeCodexSessionFixture(named: "codexlogs-exec-command-output-delta-running.jsonl")
		defer { try? FileManager.default.removeItem(at: rolloutPath) }

		let changed = CodexNativeSessionController.reconcilePersistedCommandExecutionStatuses(
			in: &items,
			rolloutPath: rolloutPath.path
		)

		XCTAssertTrue(changed)
		XCTAssertEqual(items.first?.toolIsError, false)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "running")
		let output = object["aggregatedOutput"] as? String
		XCTAssertTrue(output?.contains("beta") == true)
		XCTAssertTrue(output?.contains("gamma") == true)
		XCTAssertNil(object["exitCode"])
	}

	func testReconcilePersistedCommandExecutionStatusesFromLiveMirroredDeltaFixtureAvoidsDuplicateOutput() throws {
		let failed = """
		{
		"type": "commandExecution",
		"status": "failed",
		"exitCode": -1,
		"processId": "47551",
		"id": "call_0m75dRFVQLjGFcLFguJ99j8N",
		"command": "python3 -u"
		}
		"""
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: failed,
				isError: true,
				sequenceIndex: 0
			)
		]

		let rolloutPath = try materializeCodexSessionFixture(named: "codexlogs-live-bash-test-1-mirrored-deltas.jsonl")
		defer { try? FileManager.default.removeItem(at: rolloutPath) }

		let changed = CodexNativeSessionController.reconcilePersistedCommandExecutionStatuses(
			in: &items,
			rolloutPath: rolloutPath.path
		)

		XCTAssertTrue(changed)
		XCTAssertEqual(items.first?.toolIsError, false)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "running")
		let output = try XCTUnwrap(object["aggregatedOutput"] as? String)
		XCTAssertEqual(output.components(separatedBy: "stdout line 2").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stderr line 2").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stdout line 3").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stdout line 4").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stderr line 4").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "stdout line 5").count - 1, 1)
		XCTAssertEqual(output.components(separatedBy: "bash-test-1: done").count - 1, 1)
		XCTAssertNil(object["exitCode"])
	}

	func testReconcilePersistedCommandExecutionStatusesDoesNotReviveEndedCommandFixture() throws {
		let failed = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": -1,
		  "processId": "85178",
		  "id": "call_test_ended",
		  "command": "python3 -u"
		}
		"""
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: failed,
				isError: true,
				sequenceIndex: 0
			)
		]

		let rolloutPath = try materializeCodexSessionFixture(named: "codexlogs-exec-command-ended-failed-session.jsonl")
		defer { try? FileManager.default.removeItem(at: rolloutPath) }

		let changed = CodexNativeSessionController.reconcilePersistedCommandExecutionStatuses(
			in: &items,
			rolloutPath: rolloutPath.path
		)

		XCTAssertFalse(changed)
		XCTAssertEqual(items.first?.toolIsError, true)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "failed")
		XCTAssertEqual(object["exitCode"] as? Int, -1)
	}

	func testReconcilePersistedCommandExecutionStatusesRecoversSessionScopedWriteStdinFromCodexRawMCPFixture() throws {
		let completed = """
		{
		  "type": "commandExecution",
		  "status": "completed",
		  "exitCode": 0,
		  "processId": "session:27588",
		  "command": "npm start"
		}
		"""
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: completed,
				isError: false,
				sequenceIndex: 0
			)
		]

		let rolloutPath = try materializeCodexSessionFixture(named: "codexlogs-write-stdin-running.jsonl")
		defer { try? FileManager.default.removeItem(at: rolloutPath) }

		let changed = CodexNativeSessionController.reconcilePersistedCommandExecutionStatuses(
			in: &items,
			rolloutPath: rolloutPath.path
		)

		XCTAssertTrue(changed)
		XCTAssertEqual(items.first?.toolIsError, false)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "running")
		XCTAssertEqual(object["processId"] as? String, "session:27588")
		XCTAssertNil(object["exitCode"])
	}

	func testReconcilePersistedCommandExecutionStatusesRecoversSessionScopedWriteStdinProcessFromFixture() throws {
		let completed = """
		{
		  "type": "commandExecution",
		  "status": "completed",
		  "exitCode": 0,
		  "processId": "session:27588",
		  "command": "npm start"
		}
		"""
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: completed,
				isError: false,
				sequenceIndex: 0
			)
		]

		let rolloutPath = try materializeCodexSessionFixture(named: "write-stdin-running.jsonl")
		defer { try? FileManager.default.removeItem(at: rolloutPath) }

		let changed = CodexNativeSessionController.reconcilePersistedCommandExecutionStatuses(
			in: &items,
			rolloutPath: rolloutPath.path
		)

		XCTAssertTrue(changed)
		XCTAssertEqual(items.first?.toolIsError, false)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "running")
		XCTAssertEqual(object["processId"] as? String, "session:27588")
		XCTAssertNil(object["exitCode"])
	}

	func testReconcilePersistedCommandExecutionStatusesDoesNotReopenSuccessfulForegroundCommandFromFixture() throws {
		let completed = """
		{
		  "type": "commandExecution",
		  "status": "completed",
		  "exitCode": 0,
		  "processId": "25909",
		  "command": "ls -1"
		}
		"""
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: completed,
				isError: false,
				sequenceIndex: 0
			)
		]

		let rolloutPath = try materializeCodexSessionFixture(named: "exec-command-running-output.jsonl")
		defer { try? FileManager.default.removeItem(at: rolloutPath) }

		let changed = CodexNativeSessionController.reconcilePersistedCommandExecutionStatuses(
			in: &items,
			rolloutPath: rolloutPath.path
		)

		XCTAssertFalse(changed)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "completed")
		XCTAssertEqual(object["exitCode"] as? Int, 0)
	}

	func testMergeCommandExecutionCompletionPayloadPreservesCommandAndOutputFromExistingRunningPayload() throws {
		let existing = #"{"type":"commandExecution","status":"running","processId":"123","command":"npm run dev","aggregatedOutput":"server starting\n"}"#
		let incoming = #"{"type":"commandExecution","status":"completed","exitCode":0,"processId":"123"}"#

		let merged = CodexNativeSessionController.mergeCommandExecutionCompletionPayload(
			existing: existing,
			incoming: incoming,
			argsJSON: nil
		)

		let object = try XCTUnwrap(jsonObject(from: merged))
		XCTAssertEqual(object["status"] as? String, "completed")
		XCTAssertEqual(object["command"] as? String, "npm run dev")
		XCTAssertTrue((object["aggregatedOutput"] as? String)?.contains("server starting") == true)
		XCTAssertEqual(object["exitCode"] as? Int, 0)
	}

	func testApplyCommandExecutionRunningUpdateCapsAggregatedOutput() throws {
		let initial = #"{"type":"commandExecution","status":"running","processId":"123"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: initial,
				isError: false,
				sequenceIndex: 0
			)
		]
		let largeOutput = String(repeating: "A", count: 100_000)

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "123", appendedOutput: largeOutput),
			to: &items
		)

		XCTAssertTrue(changed)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		let aggregatedOutput = try XCTUnwrap(object["aggregatedOutput"] as? String)
		let maxChars = CodexNativeSessionController.test_maxRunningAggregatedOutputCharacters
		XCTAssertTrue(aggregatedOutput.hasPrefix("\n...(output truncated)...\n"))
		XCTAssertLessThanOrEqual(aggregatedOutput.count, maxChars + 64)
		XCTAssertEqual(object["status"] as? String, "running")
	}

	func testApplyCommandExecutionRunningUpdateDoesNotMirrorLargePayloadIntoText() {
		let initial = #"{"type":"commandExecution","status":"running","processId":"123"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: initial,
				isError: false,
				sequenceIndex: 0
			)
		]
		let originalText = items[0].text
		let largeOutput = String(repeating: "A", count: 32_000)

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "123", appendedOutput: largeOutput),
			to: &items
		)

		XCTAssertTrue(changed)
		XCTAssertEqual(items[0].text, originalText)
		XCTAssertNotEqual(items[0].toolResultJSON, originalText)
	}

	func testApplyCommandExecutionRunningUpdateStripsLegacyKeys() throws {
		let initial = #"{"type":"commandExecution","status":"running","process_id":"123","aggregated_output":"ready\n"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: initial,
				isError: false,
				sequenceIndex: 0
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: nil, appendedOutput: nil),
			to: &items
		)

		XCTAssertTrue(changed)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertNil(object["process_id"])
		XCTAssertNil(object["aggregated_output"])
		XCTAssertEqual(object["processId"] as? String, "123")
		XCTAssertEqual(object["aggregatedOutput"] as? String, "ready\n")
	}

	func testApplyCommandExecutionRunningUpdatePreservesExistingOutputFieldWhenAppendingDelta() throws {
		let initial = #"{"type":"commandExecution","status":"running","processId":"123","output":"line 1\nline 2\n"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: initial,
				isError: false,
				sequenceIndex: 0
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "123", appendedOutput: "line 3\n"),
			to: &items
		)

		XCTAssertTrue(changed)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		XCTAssertEqual(object["aggregatedOutput"] as? String, "line 1\nline 2\nline 3\n")
	}

	func testApplyCommandExecutionRunningUpdateSanitizesAggregatedOutput() throws {
		let esc = "\u{001B}"
		let initial = #"{"type":"commandExecution","status":"running","processId":"123","aggregatedOutput":"\u001B[2Jwaiting\u000Ddone\n"}"#
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: nil,
				resultJSON: initial,
				isError: false,
				sequenceIndex: 0
			)
		]

		let changed = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "123", appendedOutput: "\(esc)[32mok\(esc)[39m\n"),
			to: &items
		)

		XCTAssertTrue(changed)
		let object = try XCTUnwrap(jsonObject(from: items.first?.toolResultJSON))
		let aggregatedOutput = try XCTUnwrap(object["aggregatedOutput"] as? String)
		XCTAssertFalse(aggregatedOutput.contains("\u{001B}"))
		XCTAssertTrue(aggregatedOutput.contains("done"))
		XCTAssertTrue(aggregatedOutput.contains("ok"))
	}

	func testApplyCommandExecutionRunningUpdateIndexTracksProcessIDMutationAcrossUpdates() throws {
		let first = #"{"type":"commandExecution","status":"running","processId":"111","aggregatedOutput":"start\n"}"#
		let second = #"{"type":"commandExecution","status":"running","processId":"222","aggregatedOutput":"other\n"}"#
		let firstInvocationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
		let secondInvocationID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")
		var items: [AgentChatItem] = [
			.toolResult(
				name: "bash",
				invocationID: firstInvocationID,
				resultJSON: first,
				isError: false,
				sequenceIndex: 0
			),
			.toolResult(
				name: "bash",
				invocationID: secondInvocationID,
				resultJSON: second,
				isError: false,
				sequenceIndex: 1
			)
		]
		var index: CodexNativeSessionController.CommandExecutionRunningItemIndex? =
			.init(items: items)

		let changedFirst = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: firstInvocationID, processID: "333", appendedOutput: "one\n"),
			to: &items,
			index: &index
		)
		let changedSecond = CodexNativeSessionController.applyCommandExecutionRunningUpdate(
			.init(invocationID: nil, processID: "333", appendedOutput: "two\n"),
			to: &items,
			index: &index
		)

		XCTAssertTrue(changedFirst)
		XCTAssertTrue(changedSecond)
		let firstObject = try XCTUnwrap(jsonObject(from: items[0].toolResultJSON))
		let secondObject = try XCTUnwrap(jsonObject(from: items[1].toolResultJSON))
		XCTAssertEqual(firstObject["processId"] as? String, "333")
		XCTAssertEqual(secondObject["processId"] as? String, "222")
		XCTAssertTrue((firstObject["aggregatedOutput"] as? String)?.contains("one") == true)
		XCTAssertTrue((firstObject["aggregatedOutput"] as? String)?.contains("two") == true)
		XCTAssertFalse((secondObject["aggregatedOutput"] as? String)?.contains("two") == true)
	}

	// MARK: - apply_patch terminal regression tests

	func testLateFileChangeOutputDeltaIgnoredAfterCompletion() throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		// Start the fileChange lifecycle.
		_ = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_terminal",
					"status": "inProgress",
					"changes": [[
						"path": "/tmp/file.swift",
						"kind": ["type": "update"],
						"diff": "--- a\n+++ b\n"
					]]
				]
			]
		)
		// Complete the fileChange lifecycle.
		let completedEvent = controller.test_parseToolLifecycleEvent(
			method: "item/completed",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_terminal",
					"status": "completed",
					"changes": [[
						"path": "/tmp/file.swift",
						"kind": ["type": "update"],
						"diff": "--- a\n+++ b\n"
					]]
				]
			]
		)
		XCTAssertNotNil(completedEvent)
		XCTAssertEqual(completedEvent?.kind, "result")

		// A late output delta for the same itemID should be suppressed.
		let lateEvent = controller.test_parseFileChangeOutputDeltaEvent(params: [
			"itemId": "call_patch_terminal",
			"delta": "Late output after completion"
		])
		XCTAssertNil(lateEvent, "Late output delta after fileChange completion should be suppressed")
	}

	func testRestartedFileChangeItemClearsTerminalMarker() throws {
		let controller = CodexNativeSessionController(
			client: CodexAppServerClient(),
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil
		)
		// Start and complete.
		_ = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_reuse",
					"status": "inProgress",
					"changes": [[
						"path": "/tmp/a.swift",
						"kind": ["type": "update"],
						"diff": ""
					]]
				]
			]
		)
		_ = controller.test_parseToolLifecycleEvent(
			method: "item/completed",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_reuse",
					"status": "completed",
					"changes": [[
						"path": "/tmp/a.swift",
						"kind": ["type": "update"],
						"diff": ""
					]]
				]
			]
		)
		// Restart the same itemID.
		_ = controller.test_parseToolLifecycleEvent(
			method: "item/started",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-current",
				"item": [
					"type": "fileChange",
					"id": "call_patch_reuse",
					"status": "inProgress",
					"changes": [[
						"path": "/tmp/a.swift",
						"kind": ["type": "update"],
						"diff": ""
					]]
				]
			]
		)
		// Output delta should now be accepted again.
		let deltaEvent = controller.test_parseFileChangeOutputDeltaEvent(params: [
			"itemId": "call_patch_reuse",
			"delta": "Restarted output"
		])
		XCTAssertNotNil(deltaEvent, "Output delta after restarted fileChange should be accepted")
		XCTAssertEqual(deltaEvent?.name, "apply_patch")
	}

	func testApplyPatchStatusClassificationHelpers() {
		// Running statuses
		XCTAssertTrue(CodexNativeSessionController.applyPatchResultIndicatesRunning(
			raw: #"{"status":"running","changes":[]}"#
		))
		XCTAssertTrue(CodexNativeSessionController.applyPatchResultIndicatesRunning(
			raw: #"{"status":"pending","changes":[]}"#
		))
		XCTAssertTrue(CodexNativeSessionController.applyPatchResultIndicatesRunning(
			raw: #"{"status":"in_progress","changes":[]}"#
		))

		// Terminal statuses
		XCTAssertTrue(CodexNativeSessionController.applyPatchResultIndicatesTerminal(
			raw: #"{"status":"success","changes":[]}"#
		))
		XCTAssertTrue(CodexNativeSessionController.applyPatchResultIndicatesTerminal(
			raw: #"{"status":"failed","changes":[]}"#
		))
		XCTAssertTrue(CodexNativeSessionController.applyPatchResultIndicatesTerminal(
			raw: #"{"status":"declined","changes":[]}"#
		))

		// Nil and malformed
		XCTAssertFalse(CodexNativeSessionController.applyPatchResultIndicatesRunning(raw: nil))
		XCTAssertFalse(CodexNativeSessionController.applyPatchResultIndicatesTerminal(raw: nil))
		XCTAssertFalse(CodexNativeSessionController.applyPatchResultIndicatesRunning(raw: "not json"))
		XCTAssertFalse(CodexNativeSessionController.applyPatchResultIndicatesTerminal(raw: "not json"))
	}

	private func codexSessionFixtureURL(named fixtureName: String) -> URL {
		let testFileURL = URL(fileURLWithPath: #filePath, isDirectory: false)
		return testFileURL
			.deletingLastPathComponent()
			.appendingPathComponent("Fixtures")
			.appendingPathComponent("CodexSessions")
			.appendingPathComponent(fixtureName)
	}

	private func materializeCodexSessionFixture(named fixtureName: String) throws -> URL {
		let fixtureURL = codexSessionFixtureURL(named: fixtureName)
		XCTAssertTrue(
			FileManager.default.fileExists(atPath: fixtureURL.path),
			"Missing Codex session fixture: \(fixtureURL.path)"
		)
		let destination = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-rollout-\(UUID().uuidString)-\(fixtureName)")
		let fixtureData = try Data(contentsOf: fixtureURL)
		try fixtureData.write(to: destination, options: [.atomic])
		return destination
	}

	private func jsonObject(from raw: String?) -> [String: Any]? {
		guard let raw, let data = raw.data(using: .utf8) else { return nil }
		return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
	}
}
