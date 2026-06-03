import XCTest
@testable import RepoPrompt

final class AgentChatItemPersistTests: XCTestCase {
	func testPersistPrunesNonAskUserToolResultPayloads() {
		let resultJSON = #"{"ok":true,"payload":"value"}"#
		let item = AgentChatItem(
			kind: .toolResult,
			text: resultJSON,
			attachments: [],
			toolName: "read_file",
			toolInvocationID: nil,
			toolArgsJSON: #"{"path":"/tmp/foo.txt"}"#,
			toolResultJSON: resultJSON,
			toolIsError: false,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		XCTAssertEqual(persisted.toolName, "read_file")
		XCTAssertEqual(persisted.toolArgsJSON, #"{"path":"/tmp/foo.txt"}"#)
		XCTAssertEqual(decodeStatus(from: persisted.toolResultJSON ?? ""), "success")
		XCTAssertEqual(decodeSummaryOnly(from: persisted.toolResultJSON ?? ""), true)
		XCTAssertFalse(persisted.toolResultJSON?.contains("payload") == true)
		XCTAssertEqual(persisted.toolIsError, false)
		XCTAssertEqual(persisted.text, persisted.toolResultJSON)
	}

	func testPersistRetainsAskUserToolResultPayload() {
		let resultJSON = #"{"question":"Proceed?","answer":"Yes"}"#
		let item = AgentChatItem(
			kind: .toolResult,
			text: resultJSON,
			attachments: [],
			toolName: "ask_user_question",
			toolInvocationID: nil,
			toolArgsJSON: #"{"question":"Proceed?"}"#,
			toolResultJSON: resultJSON,
			toolIsError: false,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		XCTAssertEqual(persisted.toolName, "ask_user_question")
		XCTAssertEqual(persisted.toolArgsJSON, #"{"question":"Proceed?"}"#)
		XCTAssertEqual(persisted.toolResultJSON, resultJSON)
		XCTAssertEqual(persisted.toolIsError, false)
		XCTAssertEqual(persisted.text, resultJSON)
	}

	func testPersistRetainsPrefixedRepoPromptAskUserPayload() {
		let resultJSON = #"{"response":"Yes","skipped":false,"timed_out":false}"#
		let item = AgentChatItem(
			kind: .toolResult,
			text: resultJSON,
			attachments: [],
			toolName: "functions.mcp__RepoPrompt__ask_user",
			toolInvocationID: nil,
			toolArgsJSON: #"{"question":"Proceed?"}"#,
			toolResultJSON: resultJSON,
			toolIsError: false,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		XCTAssertEqual(persisted.toolName, "functions.mcp__RepoPrompt__ask_user")
		XCTAssertEqual(persisted.toolResultJSON, resultJSON)
		XCTAssertEqual(persisted.text, resultJSON)
	}

	func testPersistSummarizesApplyPatchPayload() {
		let resultJSON = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}"#
		let item = AgentChatItem(
			kind: .toolResult,
			text: resultJSON,
			attachments: [],
			toolName: "apply_patch",
			toolInvocationID: nil,
			toolArgsJSON: #"{"path":"/tmp/file.swift","change_count":1}"#,
			toolResultJSON: resultJSON,
			toolIsError: false,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		let dto = ToolJSON.decode(ToolResultDTOs.ApplyPatchSummary.self, from: persisted.toolResultJSON)
		XCTAssertNotEqual(persisted.toolResultJSON, resultJSON)
		XCTAssertEqual(decodeStatus(from: persisted.toolResultJSON ?? ""), "success")
		XCTAssertEqual(decodeSummaryOnly(from: persisted.toolResultJSON ?? ""), true)
		XCTAssertEqual(dto?.changes.first?.path, "/tmp/file.swift")
		XCTAssertFalse(persisted.toolResultJSON?.contains("@@ -1 +1 @@") == true)
		XCTAssertEqual(persisted.text, persisted.toolResultJSON)
		XCTAssertEqual(persisted.toolIsError, false)

		let restored = persisted.toItem()
		XCTAssertEqual(restored.toolResultJSON, persisted.toolResultJSON)
		XCTAssertEqual(restored.text, persisted.toolResultJSON)
	}

	func testPersistDropsBashToolResultPayloadAndErrorFlag() {
		let resultJSON = #"{"status":"failed","exitCode":1}"#
		let item = AgentChatItem(
			kind: .toolResult,
			text: resultJSON,
			attachments: [],
			toolName: "exec_command",
			toolInvocationID: nil,
			toolArgsJSON: #"{"cmd":"echo hi"}"#,
			toolResultJSON: resultJSON,
			toolIsError: true,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		XCTAssertEqual(persisted.toolName, "exec_command")
		XCTAssertEqual(persisted.toolArgsJSON, #"{"cmd":"echo hi"}"#)
		XCTAssertEqual(decodeStatus(from: persisted.toolResultJSON ?? ""), "failed")
		XCTAssertEqual(decodeSummaryOnly(from: persisted.toolResultJSON ?? ""), true)
		XCTAssertNil(persisted.toolIsError)
		XCTAssertEqual(persisted.text, persisted.toolResultJSON)
	}

	func testPrunedBashToolResultRehydratesUnknownSummaryPayload() {
		let item = AgentChatItem(
			kind: .toolResult,
			text: "stdout text",
			attachments: [],
			toolName: "exec_command",
			toolInvocationID: nil,
			toolArgsJSON: #"{"cmd":"echo hi"}"#,
			toolResultJSON: "stdout text",
			toolIsError: nil,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		XCTAssertEqual(persisted.toolResultStatus, "unknown")
		XCTAssertEqual(decodeStatus(from: persisted.toolResultJSON ?? ""), "unknown")
		XCTAssertEqual(decodeSummaryOnly(from: persisted.toolResultJSON ?? ""), true)
		XCTAssertEqual(persisted.text, persisted.toolResultJSON)

		let restored = persisted.toItem()
		guard let restoredJSON = restored.toolResultJSON else {
			return XCTFail("Expected restored tool result payload")
		}
		let status = decodeStatus(from: restoredJSON)
		XCTAssertEqual(status, "unknown")
		XCTAssertEqual(decodeSummaryOnly(from: restoredJSON), true)
		XCTAssertEqual(restored.text, restoredJSON)
	}

	func testLegacyPrunedToolResultWithoutStatusRehydratesUnknownSummaryPayload() {
		let item = AgentChatItem(
			kind: .toolResult,
			text: "stdout text",
			attachments: [],
			toolName: "read_file",
			toolInvocationID: nil,
			toolArgsJSON: #"{"path":"README.md"}"#,
			toolResultJSON: #"["line1","line2"]"#,
			toolIsError: nil,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		var legacyPersisted = AgentChatItemPersist(from: item)
		legacyPersisted.toolResultStatus = nil
		legacyPersisted.toolResultJSON = nil
		legacyPersisted.toolIsError = nil
		legacyPersisted.text = ""

		let restored = legacyPersisted.toItem()
		guard let restoredJSON = restored.toolResultJSON else {
			return XCTFail("Expected restored payload for legacy pruned tool result")
		}
		let status = decodeStatus(from: restoredJSON)
		XCTAssertEqual(status, "unknown")
		XCTAssertEqual(decodeSummaryOnly(from: restoredJSON), true)
		XCTAssertEqual(restored.text, restoredJSON)
	}

	func testPersistNormalizesFinishedStatusToSuccessForRestore() {
		let item = AgentChatItem(
			kind: .toolResult,
			text: #"{"status":"finished","type":"commandExecution"}"#,
			attachments: [],
			toolName: "exec_command",
			toolInvocationID: nil,
			toolArgsJSON: #"{"cmd":"echo hi"}"#,
			toolResultJSON: #"{"status":"finished","type":"commandExecution"}"#,
			toolIsError: nil,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		XCTAssertEqual(persisted.toolResultStatus, "success")

		let restored = persisted.toItem()
		guard let restoredJSON = restored.toolResultJSON else {
			return XCTFail("Expected restored payload")
		}
		XCTAssertEqual(decodeStatus(from: restoredJSON), "success")
		XCTAssertEqual(decodeSummaryOnly(from: restoredJSON), true)
	}

	func testPersistBashNegativeExitWithProcessIDNormalizesRunningStatus() {
		let resultJSON = #"{"type":"commandExecution","status":"failed","exitCode":-1,"processId":"27588"}"#
		let item = AgentChatItem(
			kind: .toolResult,
			text: resultJSON,
			attachments: [],
			toolName: "exec_command",
			toolInvocationID: nil,
			toolArgsJSON: #"{"cmd":"npm start"}"#,
			toolResultJSON: resultJSON,
			toolIsError: true,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		XCTAssertEqual(persisted.toolResultStatus, "running")
		XCTAssertEqual(decodeStatus(from: persisted.toolResultJSON ?? ""), "running")
		XCTAssertEqual(decodeSummaryOnly(from: persisted.toolResultJSON ?? ""), true)
		XCTAssertNil(persisted.toolIsError)

		let restored = persisted.toItem()
		guard let restoredJSON = restored.toolResultJSON else {
			return XCTFail("Expected restored payload")
		}
		XCTAssertEqual(decodeStatus(from: restoredJSON), "running")
	}

	func testPersistBashNegativeExitWithDurationPersistsFailedStatus() {
		let resultJSON = #"{"type":"commandExecution","status":"failed","exitCode":-1,"processId":"27588","durationMs":5000}"#
		let item = AgentChatItem(
			kind: .toolResult,
			text: resultJSON,
			attachments: [],
			toolName: "exec_command",
			toolInvocationID: nil,
			toolArgsJSON: #"{"cmd":"npm start"}"#,
			toolResultJSON: resultJSON,
			toolIsError: true,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		XCTAssertEqual(persisted.toolResultStatus, "failed")
	}

	func testPersistBashPlainTextRunningOutputInfersRunningStatus() {
		let runningText = "Chunk ID: 1\nProcess running with session ID 25909\nOutput:\npackage.json\n"
		let item = AgentChatItem(
			kind: .toolResult,
			text: runningText,
			attachments: [],
			toolName: "bash",
			toolInvocationID: nil,
			toolArgsJSON: #"{"cmd":"ls -1"}"#,
			toolResultJSON: runningText,
			toolIsError: nil,
			reasoning: nil,
			sequenceIndex: 0,
			isStreaming: false
		)

		let persisted = AgentChatItemPersist(from: item)
		XCTAssertEqual(persisted.toolResultStatus, "running")

		let restored = persisted.toItem()
		guard let restoredJSON = restored.toolResultJSON else {
			return XCTFail("Expected restored payload")
		}
		XCTAssertEqual(decodeStatus(from: restoredJSON), "running")
		XCTAssertEqual(decodeSummaryOnly(from: restoredJSON), true)
	}

	func testLegacyPrunedToolResultRehydratesSummaryOnlyPayload() {
		var persisted = AgentChatItemPersist(from: AgentChatItem.toolResult(
			name: "read_file",
			invocationID: nil,
			resultJSON: #"{"status":"completed","content":"hello"}"#,
			isError: false,
			sequenceIndex: 0
		))
		persisted.toolResultJSON = nil
		persisted.text = ""
		persisted.toolResultStatus = "success"

		let restored = persisted.toItem()
		XCTAssertEqual(decodeStatus(from: restored.toolResultJSON ?? ""), "success")
		XCTAssertEqual(decodeSummaryOnly(from: restored.toolResultJSON ?? ""), true)
		XCTAssertEqual(restored.text, restored.toolResultJSON)
	}

	private func decodeStatus(from raw: String) -> String? {
		guard let data = raw.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			return nil
		}
		return object["status"] as? String
	}

	private func decodeSummaryOnly(from raw: String) -> Bool? {
		guard let data = raw.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			return nil
		}
		return object["summary_only"] as? Bool
	}
}
