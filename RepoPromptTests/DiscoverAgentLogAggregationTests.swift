//
//  DiscoverAgentLogAggregationTests.swift
//  RepoPromptTests
//

import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class DiscoverAgentLogAggregationTests: XCTestCase {
	@MainActor
	func testAssistantOutputDeltasAggregateIntoSinglePreviewRowAndFullOutput() {
		let session = DiscoverAgentViewModel.TabSession(tabID: UUID())

		XCTAssertTrue(session.appendAssistantOutputDelta("Hello"))
		let firstEntry = session.agentLog.first
		XCTAssertEqual(session.agentLog.count, 1)
		XCTAssertEqual(firstEntry?.type, .assistant)
		XCTAssertEqual(firstEntry?.message, "Hello")
		XCTAssertEqual(session.lastAgentOutput, "Hello")

		XCTAssertTrue(session.appendAssistantOutputDelta("\nworld"))
		XCTAssertEqual(session.agentLog.count, 1)
		XCTAssertEqual(session.agentLog.first?.id, firstEntry?.id)
		XCTAssertEqual(session.agentLog.first?.message, "Hello world")
		XCTAssertEqual(session.lastAgentOutput, "Hello\nworld")
	}

	@MainActor
	func testAssistantOutputMessageBoundariesUseCleanSeparatorWithoutExtraRows() {
		let session = DiscoverAgentViewModel.TabSession(tabID: UUID())

		XCTAssertTrue(session.appendAssistantOutputDelta("First complete response.", messageID: "message-1"))
		let firstEntry = session.agentLog.first
		XCTAssertTrue(session.appendAssistantOutputDelta("Second complete response.", messageID: "message-2"))

		XCTAssertEqual(session.agentLog.count, 1)
		XCTAssertEqual(session.agentLog.first?.id, firstEntry?.id)
		XCTAssertEqual(session.agentLog.first?.type, .assistant)
		XCTAssertEqual(session.agentLog.first?.message, "First complete response. Second complete response.")
		XCTAssertEqual(session.lastAgentOutput, "First complete response.\n\nSecond complete response.")
	}

	@MainActor
	func testAssistantOutputDeltasWithSameMessageIDRemainRawTokenDeltas() {
		let session = DiscoverAgentViewModel.TabSession(tabID: UUID())

		XCTAssertTrue(session.appendAssistantOutputDelta("Hel", messageID: "message-1"))
		let firstEntry = session.agentLog.first
		XCTAssertTrue(session.appendAssistantOutputDelta("lo", messageID: "message-1"))

		XCTAssertEqual(session.agentLog.count, 1)
		XCTAssertEqual(session.agentLog.first?.id, firstEntry?.id)
		XCTAssertEqual(session.agentLog.first?.message, "Hello")
		XCTAssertEqual(session.lastAgentOutput, "Hello")
	}

	@MainActor
	func testAssistantOutputMissingMessageIDClearsBoundaryState() {
		let session = DiscoverAgentViewModel.TabSession(tabID: UUID())

		XCTAssertTrue(session.appendAssistantOutputDelta("First ", messageID: "message-1"))
		XCTAssertTrue(session.appendAssistantOutputDelta("untracked "))
		XCTAssertTrue(session.appendAssistantOutputDelta("next", messageID: "message-2"))

		XCTAssertEqual(session.agentLog.count, 1)
		XCTAssertEqual(session.agentLog.first?.message, "First untracked next")
		XCTAssertEqual(session.lastAgentOutput, "First untracked next")
	}

	@MainActor
	func testFinalAssistantOutputReplacesBufferButKeepsSinglePreviewRow() {
		let session = DiscoverAgentViewModel.TabSession(tabID: UUID())
		_ = session.appendAssistantOutputDelta("partial")
		let firstEntry = session.agentLog.first

		XCTAssertTrue(session.replaceAssistantOutput("final authoritative output"))
		XCTAssertEqual(session.agentLog.count, 1)
		XCTAssertEqual(session.agentLog.first?.id, firstEntry?.id)
		XCTAssertEqual(session.agentLog.first?.message, "final authoritative output")
		XCTAssertEqual(session.lastAgentOutput, "final authoritative output")
	}

	@MainActor
	func testEmptyFinalAssistantOutputClearsPreviewRow() {
		let session = DiscoverAgentViewModel.TabSession(tabID: UUID())
		_ = session.appendAssistantOutputDelta("partial")

		XCTAssertTrue(session.replaceAssistantOutput(""))
		XCTAssertTrue(session.agentLog.isEmpty)
		XCTAssertEqual(session.lastAgentOutput, "")
	}

	@MainActor
	func testDedupeKeyUpdatesExistingToolRowWithoutIncrementingToolCount() {
		let session = DiscoverAgentViewModel.TabSession(tabID: UUID())
		let dedupeKey = "tool:test-invocation"

		XCTAssertTrue(session.appendLogEntry(
			AgentLogEntry(type: .tool, message: "read_file: A.swift"),
			dedupeKey: dedupeKey
		))
		let firstEntry = session.agentLog.first
		XCTAssertEqual(session.toolCallCount, 1)

		XCTAssertTrue(session.appendLogEntry(
			AgentLogEntry(type: .tool, message: "read_file: B.swift"),
			dedupeKey: dedupeKey
		))
		XCTAssertEqual(session.agentLog.count, 1)
		XCTAssertEqual(session.agentLog.first?.id, firstEntry?.id)
		XCTAssertEqual(session.agentLog.first?.message, "read_file: B.swift")
		XCTAssertEqual(session.toolCallCount, 1)
	}

	@MainActor
	func testResetLogClearsAggregationState() {
		let session = DiscoverAgentViewModel.TabSession(tabID: UUID())
		_ = session.appendAssistantOutputDelta("Draft output")
		_ = session.appendLogEntry(AgentLogEntry(type: .tool, message: "tool"), dedupeKey: "tool:1")

		session.resetLog()

		XCTAssertTrue(session.agentLog.isEmpty)
		XCTAssertEqual(session.toolCallCount, 0)
		XCTAssertNil(session.lastAgentOutput)
		XCTAssertFalse(session.usedAgentOutputAsPrompt)

		XCTAssertTrue(session.appendLogEntry(AgentLogEntry(type: .tool, message: "tool"), dedupeKey: "tool:1"))
		XCTAssertEqual(session.agentLog.count, 1)
		XCTAssertEqual(session.toolCallCount, 1)
	}
}
