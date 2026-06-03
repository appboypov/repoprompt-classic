import XCTest
@testable import RepoPrompt

final class CodexNativeSessionControllerApprovalTests: XCTestCase {
	func testParseApprovalRequestExtractsNestedBashPayload() {
		let params: [String: Any] = [
			"request": [
				"thread_id": "thread-123",
				"item": [
					"id": "call_abc",
					"type": "commandExecution",
					"command": ["/bin/zsh", "-lc", "pwd; echo EXIT:$?"],
					"cwd": "/Users/example/Documents/Git/BombSquad",
					"grant_root": "/Users/example/Documents/Git/BombSquad",
					"command_actions": [
						[
							"command": "pwd; echo EXIT:$?",
							"type": "unknown"
						]
					]
				],
				"reason": "Command needs permission"
			]
		]

		let approval = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-1"),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-123",
			currentTurnID: "turn-9"
		)

		XCTAssertNotNil(approval)
		XCTAssertEqual(approval?.kind, .commandExecution)
		XCTAssertEqual(approval?.threadID, "thread-123")
		XCTAssertEqual(approval?.turnID, "turn-9")
		XCTAssertEqual(approval?.itemID, "call_abc")
		XCTAssertEqual(approval?.command, "/bin/zsh -lc pwd; echo EXIT:$?")
		XCTAssertEqual(approval?.cwd, "/Users/example/Documents/Git/BombSquad")
		XCTAssertTrue(approval?.details.contains(where: { $0.label == "Command Actions" }) == true)
	}

	func testParseApprovalRequestRejectsMismatchedThread() {
		let params: [String: Any] = [
			"threadId": "thread-other",
			"turnId": "turn-1",
			"itemId": "item-1",
			"command": "pwd"
		]

		let approval = CodexNativeSessionController.parseApprovalRequest(
			requestID: .int(1),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-current",
			currentTurnID: "turn-current"
		)

		XCTAssertNil(approval)
	}

	func testParseApprovalRequestFallsBackToActiveThreadAndCurrentTurn() {
		let params: [String: Any] = [
			"payload": [
				"command": "pwd"
			]
		]

		let approval = CodexNativeSessionController.parseApprovalRequest(
			requestID: .int(99),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: "turn-active"
		)

		XCTAssertNotNil(approval)
		XCTAssertEqual(approval?.threadID, "thread-active")
		XCTAssertEqual(approval?.turnID, "turn-active")
		XCTAssertEqual(approval?.itemID, "item:99")
		XCTAssertEqual(approval?.command, "pwd")
	}

	func testParseApprovalRequestExtractsCommandFromArgvArray() {
		let params: [String: Any] = [
			"threadId": "thread-active",
			"argv": ["/bin/zsh", "-lc", "sleep 300"],
			"cwd": "/tmp"
		]

		let approval = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-argv"),
			method: "item/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertNotNil(approval)
		XCTAssertEqual(approval?.kind, .commandExecution)
		XCTAssertEqual(approval?.command, "/bin/zsh -lc sleep 300")
		XCTAssertEqual(approval?.turnID, "turn-current")
	}

	func testParseApprovalRequestFallsBackToSyntheticTurnAndItemWhenUnscoped() {
		let params: [String: Any] = [
			"threadId": "thread-active",
			"command": "sleep 300"
		]

		let approval = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-unscoped"),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		XCTAssertNotNil(approval)
		XCTAssertEqual(approval?.threadID, "thread-active")
		XCTAssertEqual(approval?.turnID, "turn:req-unscoped")
		XCTAssertEqual(approval?.itemID, "item:req-unscoped")
		XCTAssertEqual(approval?.command, "sleep 300")
	}

	func testParseApprovalRequestUsesNestedThreadAndTurnObjectIdentifiers() {
		let params: [String: Any] = [
			"thread": [
				"id": "thread-active"
			],
			"turn": [
				"id": "turn-nested"
			],
			"item": [
				"id": "item-nested"
			],
			"command": "pwd"
		]

		let approval = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-nested"),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertNotNil(approval)
		XCTAssertEqual(approval?.threadID, "thread-active")
		XCTAssertEqual(approval?.turnID, "turn-nested")
		XCTAssertEqual(approval?.itemID, "item-nested")
		XCTAssertEqual(approval?.command, "pwd")
	}

	func testParseApprovalRequestPrefersFileChangeMethodClassification() {
		let params: [String: Any] = [
			"threadId": "thread-active",
			"turnId": "turn-current",
			"itemId": "patch-1",
			"reason": "Approve patch"
		]

		let approval = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-file-change"),
			method: "item/fileChange/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertEqual(approval?.kind, .fileChange)
		XCTAssertEqual(approval?.itemID, "patch-1")
		XCTAssertNil(approval?.command)
		XCTAssertEqual(approval?.reason, "Approve patch")
	}

	func testParseApprovalRequestDoesNotReuseNestedTurnIDAsFallbackItemID() {
		let params: [String: Any] = [
			"thread": ["id": "thread-active"],
			"turn": ["id": "turn-nested"],
			"command": "pwd"
		]

		let approval = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-fallback-item"),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertNotNil(approval)
		XCTAssertEqual(approval?.turnID, "turn-nested")
		XCTAssertEqual(approval?.itemID, "item:req-fallback-item")
	}

	func testParseApprovalRequestReusesStableRequestAndDetailIDsForSamePayload() {
		let params: [String: Any] = [
			"threadId": "thread-active",
			"turnId": "turn-active",
			"itemId": "item-approval",
			"reason": "Needs approval",
			"command": "/bin/zsh -lc 'pwd'",
			"cwd": "/tmp",
			"commandActions": [
				[
					"command": "pwd",
					"type": "unknown"
				]
			]
		]

		let first = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-stable"),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: "turn-active"
		)
		let second = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-stable"),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: "turn-active"
		)

		XCTAssertNotNil(first)
		XCTAssertNotNil(second)
		XCTAssertEqual(first?.id, second?.id)
		XCTAssertEqual(first?.details.map(\.id), second?.details.map(\.id))
	}

	func testParseApprovalRequestKeepsStableIDWhenCurrentTurnLaterBecomesAvailable() {
		let params: [String: Any] = [
			"threadId": "thread-active",
			"command": "pwd"
		]

		let withoutCurrentTurn = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-stable-unscoped"),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: nil
		)
		let withCurrentTurn = CodexNativeSessionController.parseApprovalRequest(
			requestID: .string("req-stable-unscoped"),
			method: "item/commandExecution/requestApproval",
			params: params,
			activeThreadID: "thread-active",
			currentTurnID: "turn-live"
		)

		XCTAssertNotNil(withoutCurrentTurn)
		XCTAssertNotNil(withCurrentTurn)
		XCTAssertEqual(withoutCurrentTurn?.id, withCurrentTurn?.id)
		XCTAssertEqual(withoutCurrentTurn?.turnID, "turn:req-stable-unscoped")
		XCTAssertEqual(withCurrentTurn?.turnID, "turn-live")
	}

	func testParsePermissionsRequestAcceptsCamelCasePayload() throws {
		let request = CodexNativeSessionController.parsePermissionsRequest(
			requestID: .string("perm-1"),
			method: "item/permissions/requestApproval",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-7",
				"itemId": "item-9",
				"cwd": "/tmp/repo",
				"reason": "Need to write build artifacts",
				"permissions": [
					"sandbox": [
						"mode": "workspace-write",
						"writableRoots": ["/tmp/repo/build"]
					],
					"networkAccess": true
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		let unwrapped = try XCTUnwrap(request)
		XCTAssertEqual(unwrapped.threadID, "thread-active")
		XCTAssertEqual(unwrapped.turnID, "turn-7")
		XCTAssertEqual(unwrapped.itemID, "item-9")
		XCTAssertEqual(unwrapped.cwd, "/tmp/repo")
		XCTAssertEqual(unwrapped.reason, "Need to write build artifacts")
		XCTAssertEqual(unwrapped.permissionsObject["networkAccess"] as? Bool, true)
		let sandbox = unwrapped.permissionsObject["sandbox"] as? [String: Any]
		XCTAssertEqual(sandbox?["mode"] as? String, "workspace-write")
	}

	func testParsePermissionsRequestRejectsMismatchedThread() {
		let request = CodexNativeSessionController.parsePermissionsRequest(
			requestID: .string("perm-mismatch"),
			method: "item/permissions/requestApproval",
			params: [
				"thread_id": "thread-other",
				"turn_id": "turn-1",
				"item_id": "item-1",
				"cwd": "/tmp/repo",
				"permissions": ["networkAccess": true]
			],
			activeThreadID: "thread-current",
			currentTurnID: nil
		)

		XCTAssertNil(request)
	}

	func testParsePermissionsRequestRejectsMissingPermissions() {
		let request = CodexNativeSessionController.parsePermissionsRequest(
			requestID: .string("perm-missing"),
			method: "item/permissions/requestApproval",
			params: [
				"thread_id": "thread-active",
				"turn_id": "turn-1",
				"item_id": "item-1",
				"cwd": "/tmp/repo"
			],
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		XCTAssertNil(request)
	}

	func testParseRequestUserInputRequestAcceptsCamelCaseMultiQuestionPayload() {
		let request = CodexNativeSessionController.parseRequestUserInputRequest(
			requestID: .string("rui-1"),
			method: "item/tool/requestUserInput",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-7",
				"itemId": "item-9",
				"questions": [
					[
						"id": "q1",
						"header": "Priority",
						"question": "Which priority?",
						"isOther": true,
						"options": [
							["label": "High", "description": "Urgent"],
							["label": "Low", "description": "Can wait"]
						]
					],
					[
						"id": "q2",
						"header": "Notes",
						"question": "Anything else?",
						"isSecret": true,
						"options": []
					]
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		XCTAssertEqual(request?.threadID, "thread-active")
		XCTAssertEqual(request?.turnID, "turn-7")
		XCTAssertEqual(request?.itemID, "item-9")
		XCTAssertEqual(request?.questions.count, 2)
		XCTAssertEqual(request?.questions.first?.options.count, 2)
		XCTAssertEqual(request?.questions.first?.isOther, true)
		XCTAssertEqual(request?.questions.last?.isSecret, true)
	}

	func testParseRequestUserInputRequestRejectsDuplicateQuestionIDs() {
		let request = CodexNativeSessionController.parseRequestUserInputRequest(
			requestID: .int(11),
			method: "item/tool/requestUserInput",
			params: [
				"thread_id": "thread-active",
				"turn_id": "turn-1",
				"item_id": "item-1",
				"questions": [
					["id": "dup", "header": "A", "question": "First?"],
					["id": "dup", "header": "B", "question": "Second?"]
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		XCTAssertNil(request)
	}

	func testAgentRequestUserInputBuildResponseIncludesOtherAndUserNote() {
		let request = AgentRequestUserInputRequest(
			requestID: .string("rui-response"),
			method: "item/tool/requestUserInput",
			threadID: "thread-1",
			turnID: "turn-1",
			itemID: "item-1",
			questions: [
				.init(
					id: "q1",
					header: "Choice",
					question: "Pick one",
					isOther: true,
					isSecret: false,
					options: [
						.init(label: "Option 1", description: "First"),
						.init(label: "Option 2", description: "Second")
					]
				),
				.init(
					id: "q2",
					header: "Freeform",
					question: "Notes",
					isOther: false,
					isSecret: false,
					options: []
				)
			]
		)

		let response = request.buildResponse(
			from: [
				"q1": .init(selectedOptionIndex: 2, note: "Needs follow-up"),
				"q2": .init(selectedOptionIndex: nil, note: "Freeform answer")
			]
		)

		XCTAssertEqual(response.answersByQuestionID["q1"] ?? [], ["None of the above", "user_note: Needs follow-up"])
		XCTAssertEqual(response.answersByQuestionID["q2"] ?? [], ["user_note: Freeform answer"])
		let json = response.jsonObject["answers"] as? [String: [String: [String]]]
		XCTAssertEqual(json?["q1"]?["answers"] ?? [], ["None of the above", "user_note: Needs follow-up"])
	}

	func testParseChatgptAuthTokensRefreshRequestAcceptsCamelCasePayload() {
		let request = CodexNativeSessionController.parseChatgptAuthTokensRefreshRequest(
			requestID: .string("refresh-1"),
			params: [
				"reason": "Unauthorized",
				"previousAccountId": "acct-prev"
			]
		)

		XCTAssertEqual(
			request,
			CodexNativeSessionController.ChatgptAuthTokensRefreshRequest(
				requestID: .string("refresh-1"),
				reason: .unauthorized,
				previousAccountID: "acct-prev"
			)
		)
	}

	func testParseChatgptAuthTokensRefreshRequestAcceptsSnakeCasePayload() {
		let request = CodexNativeSessionController.parseChatgptAuthTokensRefreshRequest(
			requestID: .int(5),
			params: [
				"reason": "unauthorized",
				"previous_account_id": "acct-snake"
			]
		)

		XCTAssertEqual(request?.requestID, .int(5))
		XCTAssertEqual(request?.reason, .unauthorized)
		XCTAssertEqual(request?.previousAccountID, "acct-snake")
	}

	func testParseChatgptAuthTokensRefreshRequestRejectsMissingOrUnknownReason() {
		XCTAssertNil(
			CodexNativeSessionController.parseChatgptAuthTokensRefreshRequest(
				requestID: .string("missing-reason"),
				params: [:]
			)
		)
		XCTAssertNil(
			CodexNativeSessionController.parseChatgptAuthTokensRefreshRequest(
				requestID: .string("wrong-reason"),
				params: ["reason": "expired"]
			)
		)
	}

	func testTurnSandboxPolicyPayloadForFullAccessUsesDangerFullAccessType() {
		let payload = CodexNativeSessionController.appServerTurnSandboxPolicyPayload(
			mode: .dangerFullAccess,
			workspacePath: "/Users/example/Documents/Git/RepoPromptWeb"
		)

		XCTAssertEqual(payload["type"] as? String, "dangerFullAccess")
		XCTAssertNil(payload["writableRoots"])
	}

	func testTurnSandboxPolicyPayloadForWorkspaceWriteIncludesWritableRootAndNetwork() {
		let payload = CodexNativeSessionController.appServerTurnSandboxPolicyPayload(
			mode: .workspaceWrite,
			workspacePath: "/Users/example/Documents/Git/RepoPromptWeb"
		)

		XCTAssertEqual(payload["type"] as? String, "workspaceWrite")
		XCTAssertEqual(payload["networkAccess"] as? Bool, true)
		XCTAssertEqual(payload["writableRoots"] as? [String], ["/Users/example/Documents/Git/RepoPromptWeb"])
	}

	func testTurnSandboxPolicyPayloadForReadOnlyUsesReadOnlyType() {
		let payload = CodexNativeSessionController.appServerTurnSandboxPolicyPayload(
			mode: .readOnly,
			workspacePath: nil
		)

		XCTAssertEqual(payload["type"] as? String, "readOnly")
		XCTAssertNil(payload["writableRoots"])
	}

}
