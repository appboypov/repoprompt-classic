import XCTest
@testable import RepoPrompt

final class CodexNativeSessionControllerRoutingTests: XCTestCase {
	func testRoutingDropsMismatchedNestedThreadID() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/started",
			params: [
				"event": [
					"thread_id": "thread-other",
					"turn_id": "turn-1"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-1"
		)

		XCTAssertTrue(shouldDrop)
	}

	func testRoutingAllowsNestedMatchingThreadAndTurn() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/completed",
			params: [
				"payload": [
					"threadId": "thread-active",
					"turnId": "turn-2"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-2"
		)

		XCTAssertFalse(shouldDrop)
	}

	func testRoutingDropsMismatchedTurnIDWhenCurrentTurnKnown() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/agentMessage/delta",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-other"
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertTrue(shouldDrop)
	}

	func testRoutingAllowsTurnMismatchWhenNotifiedTurnIsStillActive() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/agentMessage/delta",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-older"
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current",
			activeTurnIDs: ["turn-current", "turn-older"]
		)

		XCTAssertFalse(shouldDrop)
	}

	func testRoutingDropsTurnMismatchWhenNotifiedTurnNotActive() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/agentMessage/delta",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-old"
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current",
			activeTurnIDs: ["turn-current"]
		)

		XCTAssertTrue(shouldDrop)
	}

	func testRoutingTreatsTaskCompleteAsTurnLifecycle() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "codex/event/task_complete",
			params: [
				"id": "turn-completed",
				"msg": [
					"type": "task_complete",
					"turn_id": "turn-completed"
				],
				"conversationId": "thread-active"
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current",
			activeTurnIDs: ["turn-current"]
		)

		XCTAssertFalse(shouldDrop)
	}

	func testRoutingAllowsUnscopedLifecycleWithoutActiveTurn() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "turn/started",
			params: [
				"turn": [
					"id": "turn-boot"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		XCTAssertFalse(shouldDrop)
	}

	func testRoutingExtractsNestedTurnObjectIdentifier() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/agentMessage/delta",
			params: [
				"threadId": "thread-active",
				"turn": [
					"id": "turn-other"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertTrue(shouldDrop)
	}

	func testRoutingDropsMismatchedNestedThreadObjectIdentifier() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/started",
			params: [
				"thread": [
					"id": "thread-other"
				],
				"turnId": "turn-current"
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertTrue(shouldDrop)
	}

	func testRoutingAllowsMismatchedTurnIDForCommandExecutionMethod() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/commandExecution/outputDelta",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-other",
				"item": [
					"type": "commandExecution",
					"id": "call_123",
					"processId": "1234"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertFalse(shouldDrop)
	}

	func testRoutingDropsMismatchedTurnIDForCommandExecutionWithWeakCorrelation() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/commandExecution/outputDelta",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-other",
				"item": [
					"type": "commandExecution",
					"processId": "1234"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertTrue(shouldDrop)
	}

	func testRoutingAllowsMismatchedTurnIDForFileChangeOutputDeltaWithStrongCorrelation() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/fileChange/outputDelta",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-other",
				"itemId": "call_patch_1"
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertFalse(shouldDrop)
	}

	func testRoutingAllowsMismatchedTurnIDForGenericItemCompletedWhenPayloadIsBash() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/completed",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-other",
				"item": [
					"type": "function_call_output",
					"name": "bash",
					"id": "call_123"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertFalse(shouldDrop)
	}

	func testRoutingDropsUnscopedItemEventWhenNoActiveTurn() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/started",
			params: [
				"item": [
					"id": "item-1",
					"type": "function_call"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		XCTAssertTrue(shouldDrop)
	}

	func testRoutingAllowsUnscopedItemEventWhenTurnActive() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/started",
			params: [
				"item": [
					"id": "item-1",
					"type": "function_call"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertFalse(shouldDrop)
	}

	func testRoutingDropsUnscopedCommandExecutionWithWeakCorrelationWhenNoActiveTurn() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "item/commandExecution/outputDelta",
			params: [
				"item": [
					"type": "commandExecution",
					"processId": "4321"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		XCTAssertTrue(shouldDrop)
	}

	func testRoutingAllowsUnscopedNonTurnNotificationWhenIdle() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "error",
			params: [
				"error": [
					"message": "transport closed"
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		XCTAssertFalse(shouldDrop)
	}

	func testRoutingAllowsThreadTokenUsageWhenTurnIDDiffers() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "thread/tokenUsage/updated",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-old",
				"tokenUsage": [
					"modelContextWindow": 128_000
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current"
		)

		XCTAssertFalse(shouldDrop)
	}

	func testParseTokenUsageSupportsTokenUsageInfoShape() {
		let usage = CodexNativeSessionController.test_parseTokenUsage(from: [
			"tokenUsage": [
				"lastTokenUsage": [
					"inputTokens": 80,
					"cachedInputTokens": 20,
					"outputTokens": 30,
					"reasoningOutputTokens": 10
				],
				"totalTokenUsage": [
					"totalTokens": 2_500
				],
				"modelContextWindow": 256_000
			]
		])

		XCTAssertEqual(usage?.lastTotalTokens, 140)
		XCTAssertEqual(usage?.totalTotalTokens, 2_500)
		XCTAssertEqual(usage?.modelContextWindow, 256_000)
	}

	func testParseTokenUsageSupportsSnakeCaseTopLevelShape() {
		let usage = CodexNativeSessionController.test_parseTokenUsage(from: [
			"last_token_usage": [
				"total_tokens": "900"
			],
			"total_token_usage": [
				"input_tokens": "1000",
				"output_tokens": "200"
			],
			"model_context_window": "200000"
		])

		XCTAssertEqual(usage?.lastTotalTokens, 900)
		XCTAssertEqual(usage?.totalTotalTokens, 1_200)
		XCTAssertEqual(usage?.modelContextWindow, 200_000)
	}


	func testParseTokenUsageIgnoresNonFiniteStringValues() {
		let usage = CodexNativeSessionController.test_parseTokenUsage(from: [
			"token_usage": [
				"last_token_usage": [
					"total_tokens": "nan"
				],
				"total_token_usage": [
					"total_tokens": "1e309"
				],
				"model_context_window": "inf"
			]
		])

		XCTAssertNil(usage)
	}

	func testParseTokenUsagePreservesFiniteStringValuesAlongsideInvalidOnes() {
		let usage = CodexNativeSessionController.test_parseTokenUsage(from: [
			"token_usage": [
				"last_token_usage": [
					"input_tokens": "80",
					"cached_input_tokens": "nan",
					"output_tokens": "30"
				],
				"total_token_usage": [
					"total_tokens": "2500"
				],
				"model_context_window": "1e309"
			]
		])

		XCTAssertEqual(usage?.lastTotalTokens, 110)
		XCTAssertEqual(usage?.totalTotalTokens, 2_500)
		XCTAssertNil(usage?.modelContextWindow)
	}
	func testLifecycleMethodDetectionAcceptsCommandExecutionCompletedVariants() {
		XCTAssertTrue(
			CodexNativeSessionController.test_isItemLifecycleNotificationMethod(
				"item/commandExecution/completed"
			)
		)
		XCTAssertTrue(
			CodexNativeSessionController.test_isItemLifecycleNotificationMethod(
				"item/command_execution/started"
			)
		)
		XCTAssertTrue(
			CodexNativeSessionController.test_isItemLifecycleNotificationMethod(
				"codex/event/item_commandExecution_completed"
			)
		)
		XCTAssertTrue(
			CodexNativeSessionController.test_isItemLifecycleNotificationMethod(
				"codex/event/item_command_execution_started"
			)
		)
	}

	func testLifecycleMethodDetectionIgnoresCommandExecutionDeltaVariants() {
		XCTAssertFalse(
			CodexNativeSessionController.test_isItemLifecycleNotificationMethod(
				"item/commandExecution/outputDelta"
			)
		)
		XCTAssertFalse(
			CodexNativeSessionController.test_isItemLifecycleNotificationMethod(
				"codex/event/item_commandExecution_outputDelta"
			)
		)
	}

	func testCurrentTurnPromotionUsesItemActivity() {
		let shouldPromote = CodexNativeSessionController.test_shouldPromoteCurrentTurn(
			method: "item/agentMessage/delta",
			notifiedTurnID: "turn-new",
			currentTurnID: "turn-old"
		)

		XCTAssertTrue(shouldPromote)
	}

	func testCurrentTurnPromotionIgnoresTurnStartedLifecycle() {
		let shouldPromote = CodexNativeSessionController.test_shouldPromoteCurrentTurn(
			method: "turn/started",
			notifiedTurnID: "turn-new",
			currentTurnID: "turn-old"
		)

		XCTAssertFalse(shouldPromote)
	}

	func testCurrentTurnPromotionIgnoresTaskCompleteLifecycle() {
		let shouldPromote = CodexNativeSessionController.test_shouldPromoteCurrentTurn(
			method: "codex/event/task_complete",
			notifiedTurnID: "turn-new",
			currentTurnID: "turn-old"
		)

		XCTAssertFalse(shouldPromote)
	}

	func testToolItemCandidatesIncludePayloadAndEventEnvelopes() {
		let count = CodexNativeSessionController.test_toolItemCandidatesCount(from: [
			"payload": [
				"item": [
					"type": "commandExecution",
					"status": "completed"
				],
				"type": "wrapper"
			],
			"event": [
				"item": [
					"type": "function_call",
					"name": "bash"
				],
				"type": "event-wrapper"
			],
			"item": [
				"type": "function_call_output",
				"name": "bash"
			]
		])

		XCTAssertGreaterThanOrEqual(count, 6)
	}

	func testParseThreadSnapshotRestoresActiveTurnsFromResumePayload() {
		let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(
			[
				"thread": [
					"id": "thread-active",
					"path": "/tmp/thread-active.jsonl",
					"status": [
						"type": "active",
						"activeFlags": []
					],
					"turns": [
						[
							"id": "turn-old",
							"status": "completed"
						],
						[
							"id": "turn-running-1",
							"status": "inProgress"
						],
						[
							"id": "turn-running-2",
							"status": "inProgress"
						]
					]
				],
				"model": "gpt-5.2-codex",
				"reasoningEffort": "medium"
			],
			fallbackEffort: nil
		)

		XCTAssertEqual(snapshot.conversationID, "thread-active")
		XCTAssertEqual(snapshot.rolloutPath, "/tmp/thread-active.jsonl")
		XCTAssertEqual(snapshot.activeTurnIDs, ["turn-running-1", "turn-running-2"])
		XCTAssertEqual(snapshot.currentTurnID, "turn-running-2")
		XCTAssertTrue(snapshot.hasActiveTurn)
	}

	func testParseThreadSnapshotPreservesActiveFlags() {
		let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(
			[
				"thread": [
					"id": "thread-active",
					"status": [
						"type": "active",
						"activeFlags": ["toolRunning", "modelResponding"]
					],
					"turns": []
				]
			],
			fallbackEffort: nil
		)

		XCTAssertEqual(snapshot.activeFlags, ["toolRunning", "modelResponding"])
		XCTAssertTrue(snapshot.hasActiveTurn)
	}

	func testParseThreadSnapshotPreservesSnakeCaseActiveFlags() {
		let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(
			[
				"thread": [
					"id": "thread-active",
					"status": [
						"type": "active",
						"active_flags": ["waiting_on_user_input"]
					],
					"turns": []
				]
			],
			fallbackEffort: nil
		)

		XCTAssertEqual(snapshot.activeFlags, ["waiting_on_user_input"])
		XCTAssertTrue(snapshot.hasActiveTurn)
	}

	func testParseLivenessActivityExtractsNestedStatusAndIDs() throws {
		let activity = try XCTUnwrap(CodexNativeSessionController.test_parseLivenessActivity(
			method: "thread/status/changed",
			params: [
				"payload": [
					"thread": [
						"id": "thread-active",
						"status": [
							"type": "active",
							"active_flags": ["WaitingOnApproval"]
						]
					],
					"turn": ["id": "turn-active"]
				]
			]
		))

		XCTAssertEqual(activity.kind, .threadStatusChanged)
		XCTAssertEqual(activity.threadID, "thread-active")
		XCTAssertEqual(activity.turnID, "turn-active")
		XCTAssertEqual(activity.activeFlags, ["WaitingOnApproval"])
	}

	func testParseStructuredErrorNotificationPreservesRetryAndScope() throws {
		let error = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
			"error": [
				"message": "temporary outage",
				"will_retry": true,
				"thread_id": "thread-active",
				"turn_id": "turn-active"
			]
		]))

		XCTAssertEqual(error.message, "temporary outage")
		XCTAssertTrue(error.willRetry)
		XCTAssertEqual(error.threadID, "thread-active")
		XCTAssertEqual(error.turnID, "turn-active")
	}

	func testRoutingDropsMismatchedThreadStatusChanged() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "thread/status/changed",
			params: [
				"payload": [
					"threadId": "thread-other",
					"status": ["type": "active"]
				]
			],
			activeThreadID: "thread-active",
			currentTurnID: nil
		)

		XCTAssertTrue(shouldDrop)
	}

	func testRoutingDropsMismatchedTurnPlanUpdate() {
		let shouldDrop = CodexNativeSessionController.test_shouldDropNotificationForRouting(
			method: "turn/plan/updated",
			params: [
				"threadId": "thread-active",
				"turnId": "turn-other"
			],
			activeThreadID: "thread-active",
			currentTurnID: "turn-current",
			activeTurnIDs: ["turn-current"]
		)

		XCTAssertTrue(shouldDrop)
	}

	func testParseThreadSnapshotLeavesTerminalThreadWithoutActiveTurns() {
		let snapshot = CodexNativeSessionController.test_parseThreadSnapshot(
			[
				"thread": [
					"id": "thread-idle",
					"status": [
						"type": "idle"
					],
					"turns": [
						[
							"id": "turn-completed",
							"status": "completed"
						],
						[
							"id": "turn-failed",
							"status": "failed"
						]
					]
				]
			],
			fallbackEffort: "high"
		)

		XCTAssertEqual(snapshot.activeTurnIDs, [])
		XCTAssertNil(snapshot.currentTurnID)
		XCTAssertEqual(snapshot.latestTurnStatus, .failed)
		XCTAssertEqual(snapshot.reasoningEffort, "high")
		XCTAssertFalse(snapshot.hasActiveTurn)
	}
}
