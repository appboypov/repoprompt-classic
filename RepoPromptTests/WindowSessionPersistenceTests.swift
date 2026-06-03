import XCTest
@testable import RepoPrompt

final class WindowSessionPersistenceTests: XCTestCase {
	func testSnapshotBuilderExcludesExplicitlyClosingWindowIDs() {
		let snapshot = WindowSessionSnapshotBuilder.build(
			version: 2,
			candidates: [
				candidate(windowID: 1, workspaceName: "Alpha"),
				candidate(windowID: 2, workspaceName: "Beta")
			],
			excludedWindowIDs: [1]
		)

		XCTAssertEqual(snapshot.windows.compactMap(\.workspaceName), ["Beta"])
	}

	func testSnapshotBuilderPreservesEmptySnapshots() {
		let snapshot = WindowSessionSnapshotBuilder.build(
			version: 2,
			candidates: [candidate(windowID: 1, workspaceName: "Alpha")],
			excludedWindowIDs: [1]
		)

		XCTAssertEqual(snapshot.version, 2)
		XCTAssertTrue(snapshot.windows.isEmpty)
	}

	func testSnapshotBuilderPreservesRemainingWindowOrder() {
		let snapshot = WindowSessionSnapshotBuilder.build(
			version: 2,
			candidates: [
				candidate(windowID: 1, workspaceName: "Alpha"),
				candidate(windowID: 2, workspaceName: "Beta"),
				candidate(windowID: 3, workspaceName: "Gamma")
			],
			excludedWindowIDs: [2]
		)

		XCTAssertEqual(snapshot.windows.compactMap(\.workspaceName), ["Alpha", "Gamma"])
	}
	
	func testSnapshotBuilderPreservesPerWindowUIMode() {
		let snapshot = WindowSessionSnapshotBuilder.build(
			version: 3,
			candidates: [
				candidate(windowID: 1, workspaceName: "Alpha", uiMode: .agent),
				candidate(windowID: 2, workspaceName: "Beta", uiMode: .ide)
			],
			excludedWindowIDs: []
		)
		
		XCTAssertEqual(snapshot.windows.map(\.uiMode), [.agent, .ide])
	}

	func testInitialUIModeResolverDefersGlobalFallbackWhileRestorePending() {
		let mode = WindowInitialUIModeResolver.resolve(
			forcedMode: nil,
			globalStoredModeRawValue: WindowUIMode.agent.rawValue,
			deferGlobalFallbackForPendingRestore: true
		)

		XCTAssertEqual(mode, .ide)
	}

	func testInitialUIModeResolverAllowsLegacyAgentFallback() {
		let mode = WindowInitialUIModeResolver.resolve(
			forcedMode: nil,
			globalStoredModeRawValue: WindowUIMode.agent.rawValue,
			deferGlobalFallbackForPendingRestore: false
		)

		XCTAssertEqual(mode, .agent)
	}

	func testInitialUIModeResolverForcedModeWinsOverRestore() {
		let mode = WindowInitialUIModeResolver.resolve(
			forcedMode: .agent,
			globalStoredModeRawValue: WindowUIMode.ide.rawValue,
			deferGlobalFallbackForPendingRestore: true
		)

		XCTAssertEqual(mode, .agent)
	}

	#if DEBUG
	func testWorkspaceRestorePerfLogDebugBufferCanBeEnabledAndRead() {
		WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(true)
		WorkspaceRestorePerfLog.clearRecentMetricLines()
		defer {
			WorkspaceRestorePerfLog.clearRecentMetricLines()
			WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(nil)
		}

		WorkspaceRestorePerfLog.log("restore.metrics unitTestProbe value=1")
		let snapshot = WorkspaceRestorePerfLog.debugStateSnapshot(lineLimit: 10)
		let lines = snapshot["lines"] as? [String] ?? []

		XCTAssertEqual(snapshot["enabled"] as? Bool, true)
		XCTAssertTrue(lines.contains { $0.contains("restore.metrics unitTestProbe value=1") })
	}
	#endif
	
	func testWindowSessionEntryDecodesLegacySnapshotWithoutUIMode() throws {
		let workspaceID = UUID()
		let json = """
		{
		  "version": 2,
		  "windows": [
		    {
		      "windowKind": "standard",
		      "workspaceID": "\(workspaceID.uuidString)",
		      "workspaceName": "Legacy",
		      "isSystemWorkspace": false,
		      "isEphemeral": false,
		      "primaryRepoPath": null,
		      "lastFocused": true,
		      "workspaceInstanceNumber": 1
		    }
		  ]
		}
		"""
		
		let snapshot = try JSONDecoder().decode(WindowSessionSnapshot.self, from: Data(json.utf8))
		XCTAssertEqual(snapshot.windows.first?.workspaceName, "Legacy")
		XCTAssertNil(snapshot.windows.first?.uiMode)
	}

	func testDiskWriterImmediateWriteCancelsPendingScheduledWrite() async throws {
		let fileURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension("json")
		defer { try? FileManager.default.removeItem(at: fileURL) }

		let writer = WindowSessionDiskWriter(fileURL: fileURL)
		let scheduledSnapshot = WindowSessionSnapshot(version: 2, windows: [entry(workspaceName: "Scheduled")])
		let immediateSnapshot = WindowSessionSnapshot(version: 2, windows: [entry(workspaceName: "Immediate")])

		await writer.scheduleWrite(scheduledSnapshot)
		await writer.writeImmediately(immediateSnapshot)
		try await Task.sleep(nanoseconds: 350_000_000)

		let loadedSnapshot = await writer.load()
		XCTAssertEqual(loadedSnapshot?.windows.compactMap(\.workspaceName), ["Immediate"])
	}

	func testWindowTitleFormatterKeepsIDETitleWorkspaceOnly() {
		let title = WindowTitleFormatter.compose(
			workspaceTitle: "RepoPrompt",
			uiMode: .ide,
			agentSessionTitle: "Fix titlebar"
		)

		XCTAssertEqual(title, "RepoPrompt")
	}

	func testWindowTitleFormatterCombinesAgentSessionAndWorkspace() {
		let title = WindowTitleFormatter.compose(
			workspaceTitle: "RepoPrompt",
			uiMode: .agent,
			agentSessionTitle: "Fix titlebar"
		)

		XCTAssertEqual(title, "Fix titlebar — RepoPrompt")
	}

	func testWindowTitleFormatterSkipsMissingOrDuplicateAgentSession() {
		XCTAssertEqual(
			WindowTitleFormatter.compose(workspaceTitle: "RepoPrompt", uiMode: .agent, agentSessionTitle: nil),
			"RepoPrompt"
		)
		XCTAssertEqual(
			WindowTitleFormatter.compose(workspaceTitle: "RepoPrompt", uiMode: .agent, agentSessionTitle: "   "),
			"RepoPrompt"
		)
		XCTAssertEqual(
			WindowTitleFormatter.compose(workspaceTitle: "RepoPrompt", uiMode: .agent, agentSessionTitle: "repoprompt"),
			"RepoPrompt"
		)
	}

	func testWindowTitleFormatterPreservesWorkspaceInstanceSuffix() {
		let title = WindowTitleFormatter.compose(
			workspaceTitle: "RepoPrompt (2)",
			uiMode: .agent,
			agentSessionTitle: "Plan refactor"
		)

		XCTAssertEqual(title, "Plan refactor — RepoPrompt (2)")
	}

	func testWindowTitleFormatterSkipsDuplicateBaseWorkspaceTitleWithInstanceSuffix() {
		let title = WindowTitleFormatter.compose(
			workspaceTitle: "RepoPrompt (2)",
			uiMode: .agent,
			agentSessionTitle: "repoprompt",
			duplicateWorkspaceTitle: "RepoPrompt"
		)

		XCTAssertEqual(title, "RepoPrompt (2)")
	}


	private func candidate(
		windowID: Int,
		workspaceName: String,
		uiMode: WindowUIMode = .ide
	) -> WindowSessionCaptureCandidate {
		WindowSessionCaptureCandidate(windowID: windowID, entry: entry(workspaceName: workspaceName, uiMode: uiMode))
	}

	private func entry(workspaceName: String, uiMode: WindowUIMode = .ide) -> WindowSessionEntry {
		WindowSessionEntry(
			windowKind: .standard,
			workspaceID: UUID(),
			workspaceName: workspaceName,
			isSystemWorkspace: false,
			isEphemeral: false,
			primaryRepoPath: nil,
			lastFocused: false,
			uiMode: uiMode,
			workspaceInstanceNumber: nil
		)
	}
}
