import XCTest
@testable import RepoPrompt

@MainActor
final class AgentRuntimeSidebarViewModelTests: XCTestCase {
	func testCodexUsageTakesPrecedenceOverToolDerivedTotals() {
		let viewModel = AgentRuntimeSidebarViewModel()
		let items = [
			toolResult(
				name: "workspace_context",
				json: """
				{
				  "prompt": "",
				  "selection": {
				    "files": [{"path":"a.swift","tokens":20,"render_mode":"full","is_auto":false}],
				    "total_tokens": 800
				  },
				  "token_stats": {
				    "total": 1200,
				    "files": 800
				  }
				}
				"""
			)
		]
		let codexUsage = AgentContextUsage(
			modelContextWindow: 8_000,
			lastTotalTokens: 1_500,
			totalTotalTokens: 1_300
		)

		viewModel.update(items: items, codexUsage: codexUsage)

		XCTAssertEqual(viewModel.snapshot.usageSource, .codexLive)
		XCTAssertEqual(viewModel.snapshot.usedTokens, 1_500)
		XCTAssertEqual(viewModel.snapshot.contextWindowTokens, 8_000)
		XCTAssertEqual(viewModel.snapshot.selectionFileCount, 1)
		XCTAssertEqual(viewModel.snapshot.selectionTokens, 800)
	}

	func testToolDerivedUsageAndSelectionFallbackWithoutCodexUsage() {
		let viewModel = AgentRuntimeSidebarViewModel()
		let items = [
			toolResult(
				name: "manage_selection",
				json: """
				{
				  "status": "ok",
				  "total_tokens": 450,
				  "files": [
				    {"path":"a.swift","tokens":20,"render_mode":"full","is_auto":false},
				    {"path":"b.swift","tokens":30,"render_mode":"full","is_auto":false}
				  ],
				  "token_stats": {
				    "total": 960,
				    "files": 450
				  }
				}
				"""
			)
		]

		viewModel.update(items: items, codexUsage: nil)

		XCTAssertEqual(viewModel.snapshot.usageSource, .toolDerived)
		XCTAssertEqual(viewModel.snapshot.usedTokens, 960)
		XCTAssertEqual(viewModel.snapshot.selectionFileCount, 2)
		XCTAssertEqual(viewModel.snapshot.selectionTokens, 450)
	}

	func testReadFileToolCallTracksObservedFilesWithoutChangingSelectionCount() {
		let viewModel = AgentRuntimeSidebarViewModel()
		let items = [
			toolCall(
				name: "read_file",
				json: """
				{
				  "path": "/tmp/one.swift",
				  "start_line": 1,
				  "limit": 40
				}
				"""
			),
			toolCall(
				name: "mcp__RepoPrompt__read_file",
				json: """
				{
				  "path": "/tmp/two.swift"
				}
				"""
			)
		]

		viewModel.update(items: items, codexUsage: nil)

		XCTAssertNil(viewModel.snapshot.selectionFileCount)
		XCTAssertEqual(viewModel.snapshot.observedReadFileCount, 2)
		XCTAssertNil(viewModel.snapshot.selectionTokens)
	}

	func testLiveSelectedFileCountOverridesTranscriptSelectionCount() {
		let viewModel = AgentRuntimeSidebarViewModel()
		let items = [
			toolResult(
				name: "workspace_context",
				json: """
				{
				  "prompt": "",
				  "selection": {
				    "files": [{"path":"a.swift","tokens":20,"render_mode":"full","is_auto":false}],
				    "total_tokens": 200
				  },
				  "token_stats": {
				    "total": 600,
				    "files": 200
				  }
				}
				"""
			),
			toolCall(
				name: "read_file",
				json: """
				{
				  "path": "/tmp/observed.swift"
				}
				"""
			)
		]

		viewModel.update(items: items, codexUsage: nil, liveSelectedFileCount: 5)

		XCTAssertEqual(viewModel.snapshot.selectionFileCount, 5)
		XCTAssertEqual(viewModel.snapshot.observedReadFileCount, 1)
		XCTAssertEqual(viewModel.snapshot.selectionTokens, 200)
	}

	func testContextBuilderResultIsCaptured() {
		let viewModel = AgentRuntimeSidebarViewModel()
		let items = [
			toolResult(
				name: "context_builder",
				json: """
				{
				  "status": "completed",
				  "summary": "Built context for 12 files"
				}
				"""
			)
		]

		viewModel.update(items: items, codexUsage: nil)

		XCTAssertEqual(viewModel.latestContextBuilderResult?.status, "completed")
		XCTAssertEqual(viewModel.latestContextBuilderResult?.summary, "Built context for 12 files")
	}

	func testRuntimeMetricsStoreDoesNotPublishRevisionForRepeatedIdenticalUpdates() {
		let store = AgentRuntimeMetricsUIStore()
		let transcriptSnapshot = AgentTranscriptAnalyticsSnapshot(estimatedTranscriptTokens: 250)
		let codexUsage = AgentContextUsage(
			modelContextWindow: 128_000,
			lastTotalTokens: 1_000,
			totalTotalTokens: 1_000
		)

		store.update(
			transcriptSnapshot: transcriptSnapshot,
			codexUsage: codexUsage,
			liveSelectedFileCount: 4,
			selectedAgent: .codexExec,
			selectedModelRaw: "gpt-5"
		)
		let revision = store.revision
		let snapshot = store.runtimeVM.snapshot

		for _ in 0..<100 {
			store.update(
				transcriptSnapshot: transcriptSnapshot,
				codexUsage: codexUsage,
				liveSelectedFileCount: 4,
				selectedAgent: .codexExec,
				selectedModelRaw: "gpt-5"
			)
		}

		XCTAssertEqual(store.revision, revision)
		XCTAssertEqual(store.runtimeVM.snapshot, snapshot)
	}

	func testRuntimeMetricsStorePublishesWhenUsageActuallyChanges() {
		let store = AgentRuntimeMetricsUIStore()
		let transcriptSnapshot = AgentTranscriptAnalyticsSnapshot(estimatedTranscriptTokens: 250)
		let firstUsage = AgentContextUsage(
			modelContextWindow: 128_000,
			lastTotalTokens: 1_000,
			totalTotalTokens: 1_000
		)
		let secondUsage = AgentContextUsage(
			modelContextWindow: 128_000,
			lastTotalTokens: 1_200,
			totalTotalTokens: 1_200
		)

		store.update(
			transcriptSnapshot: transcriptSnapshot,
			codexUsage: firstUsage,
			liveSelectedFileCount: 4,
			selectedAgent: .codexExec,
			selectedModelRaw: "gpt-5"
		)
		let firstRevision = store.revision

		store.update(
			transcriptSnapshot: transcriptSnapshot,
			codexUsage: secondUsage,
			liveSelectedFileCount: 4,
			selectedAgent: .codexExec,
			selectedModelRaw: "gpt-5"
		)

		XCTAssertEqual(store.revision, firstRevision + 1)
		XCTAssertEqual(store.runtimeVM.snapshot.usedTokens, 1_200)
	}

	private func toolCall(name: String, json: String) -> AgentChatItem {
		AgentChatItem(
			kind: .toolCall,
			text: "tool call",
			toolName: name,
			toolArgsJSON: json,
			sequenceIndex: 0
		)
	}

	private func toolResult(name: String, json: String) -> AgentChatItem {
		AgentChatItem(
			kind: .toolResult,
			text: json,
			toolName: name,
			toolResultJSON: json,
			sequenceIndex: 0
		)
	}
}
