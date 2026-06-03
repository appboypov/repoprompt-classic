import XCTest
@testable import RepoPrompt

final class AgentSessionDataServiceIndexCacheTests: XCTestCase {
	func testBackfillUsesCachedMetadataIndexWithoutSynchronousFilenameReconciliation() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let sessionID = UUID()
		let workspace = WorkspaceModel(
			name: "Agent Index Cache Tests",
			repoPaths: [],
			customStoragePath: tempRoot,
			composeTabs: [ComposeTabState(id: tabID, name: "Cached", lastModified: Date())],
			activeComposeTabID: tabID
		)
		let agentSessionsFolder = tempRoot.appendingPathComponent("AgentSessions", isDirectory: true)
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)
		
		let fileURL = try await service.saveAgentSession(
			AgentSession(
				id: sessionID,
				workspaceID: workspace.id,
				composeTabID: tabID,
				name: "Cached Session",
				savedAt: Date(timeIntervalSince1970: 1_000),
				items: [],
				itemCount: 0,
				lastUserMessageAt: nil
			),
			for: workspace
		)
		let cachedEntryCount = await service.test_cachedMetadataIndexEntryCount(forAgentSessionsFolder: agentSessionsFolder)
		XCTAssertEqual(cachedEntryCount, 1)
		
		try FileManager.default.removeItem(at: fileURL)
		await service.test_markMetadataIndexReconciledThisProcess(forAgentSessionsFolder: agentSessionsFolder)
		
		let metas = try await service.listAgentSessionsMeta(for: workspace)
		XCTAssertEqual(metas.map(\.id), [sessionID])
		XCTAssertEqual(metas.first?.name, "Cached Session")
	}

	func testSidebarStreamWithHotIndexSchedulesDelayedReconciliation() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let sessionID = UUID()
		let workspace = makeWorkspace(root: tempRoot, tabID: tabID, tabName: "Hot Index Stream")
		let agentSessionsFolder = agentSessionsFolder(root: tempRoot)
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)

		_ = try await service.saveAgentSession(
			makeSession(
				id: sessionID,
				workspaceID: workspace.id,
				tabID: tabID,
				name: "Hot Index Session",
				savedAt: Date(timeIntervalSince1970: 1_000),
				lastUserMessageAt: Date(timeIntervalSince1970: 900)
			),
			for: workspace
		)

		let result = try await service.buildSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [tabID: "Hot Index Tab"],
				validTabIDs: [tabID]
			)
		)

		XCTAssertEqual(Set(result.entriesBySessionID.keys), [sessionID])
		XCTAssertEqual(result.preferredSessionIDByTabID[tabID], sessionID)
		let isReconciliationScheduled = await service.test_isMetadataIndexReconciliationScheduled(forAgentSessionsFolder: agentSessionsFolder)
		XCTAssertTrue(isReconciliationScheduled)
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)
	}

	func testSidebarStreamWithMissingIndexRebuildsSynchronously() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let sessionID = UUID()
		let workspace = makeWorkspace(root: tempRoot, tabID: tabID, tabName: "Missing Index Stream")
		let agentSessionsFolder = agentSessionsFolder(root: tempRoot)
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)

		_ = try await service.saveAgentSession(
			makeSession(
				id: sessionID,
				workspaceID: workspace.id,
				tabID: tabID,
				name: "Missing Index Session",
				savedAt: Date(timeIntervalSince1970: 1_000),
				lastUserMessageAt: Date(timeIntervalSince1970: 900)
			),
			for: workspace
		)
		try FileManager.default.removeItem(at: metadataIndexURL(root: tempRoot))
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)

		let result = try await service.buildSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [tabID: "Missing Index Tab"],
				validTabIDs: [tabID]
			)
		)

		XCTAssertEqual(Set(result.entriesBySessionID.keys), [sessionID])
		XCTAssertEqual(result.preferredSessionIDByTabID[tabID], sessionID)
		XCTAssertTrue(FileManager.default.fileExists(atPath: metadataIndexURL(root: tempRoot).path))
		let isReconciliationScheduled = await service.test_isMetadataIndexReconciliationScheduled(forAgentSessionsFolder: agentSessionsFolder)
		XCTAssertFalse(isReconciliationScheduled)
	}

	func testTargetedPrioritizedBuildWithCachedIndexReturnsExplicitSessionOnly() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let explicitSessionID = UUID()
		let newerSessionID = UUID()
		let workspace = makeWorkspace(root: tempRoot, tabID: tabID, tabName: "Cached Explicit")
		let agentSessionsFolder = agentSessionsFolder(root: tempRoot)
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)

		_ = try await service.saveAgentSession(
			makeSession(
				id: explicitSessionID,
				workspaceID: workspace.id,
				tabID: tabID,
				name: "Explicit Session",
				savedAt: Date(timeIntervalSince1970: 1_000),
				lastUserMessageAt: Date(timeIntervalSince1970: 900)
			),
			for: workspace
		)
		_ = try await service.saveAgentSession(
			makeSession(
				id: newerSessionID,
				workspaceID: workspace.id,
				tabID: tabID,
				name: "Newer Session",
				savedAt: Date(timeIntervalSince1970: 2_000),
				lastUserMessageAt: Date(timeIntervalSince1970: 1_900)
			),
			for: workspace
		)

		let result = try await service.buildPrioritizedSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [tabID: "Active Tab"],
				validTabIDs: [tabID],
				boundSessionIDByTabID: [tabID: explicitSessionID]
			)
		)

		XCTAssertEqual(Set(result.entriesBySessionID.keys), [explicitSessionID])
		XCTAssertEqual(result.preferredSessionIDByTabID[tabID], explicitSessionID)
		XCTAssertEqual(result.entriesBySessionID[explicitSessionID]?.name, "Active Tab")
	}

	func testTargetedPrioritizedBuildWithCachedIndexReturnsPreferredSessionWithoutExplicitBinding() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let olderSessionID = UUID()
		let newerSessionID = UUID()
		let workspace = makeWorkspace(root: tempRoot, tabID: tabID, tabName: "Cached Preferred")
		let agentSessionsFolder = agentSessionsFolder(root: tempRoot)
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)

		_ = try await service.saveAgentSession(
			makeSession(
				id: olderSessionID,
				workspaceID: workspace.id,
				tabID: tabID,
				name: "Older Session",
				savedAt: Date(timeIntervalSince1970: 1_000),
				lastUserMessageAt: Date(timeIntervalSince1970: 900)
			),
			for: workspace
		)
		_ = try await service.saveAgentSession(
			makeSession(
				id: newerSessionID,
				workspaceID: workspace.id,
				tabID: tabID,
				name: "Newer Session",
				savedAt: Date(timeIntervalSince1970: 2_000),
				lastUserMessageAt: Date(timeIntervalSince1970: 1_900)
			),
			for: workspace
		)

		let result = try await service.buildPrioritizedSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [tabID: "Preferred Tab"],
				validTabIDs: [tabID]
			)
		)

		XCTAssertEqual(Set(result.entriesBySessionID.keys), [newerSessionID])
		XCTAssertEqual(result.preferredSessionIDByTabID[tabID], newerSessionID)
		XCTAssertEqual(result.entriesBySessionID[newerSessionID]?.name, "Preferred Tab")
	}

	func testTargetedPrioritizedBuildWithMissingIndexAndExplicitSessionLoadsOnlySessionStub() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let explicitSessionID = UUID()
		let newerSessionID = UUID()
		let workspace = makeWorkspace(root: tempRoot, tabID: tabID, tabName: "Missing Index Explicit")
		let agentSessionsFolder = agentSessionsFolder(root: tempRoot)
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)

		_ = try await service.saveAgentSession(
			makeSession(
				id: explicitSessionID,
				workspaceID: workspace.id,
				tabID: tabID,
				name: "Explicit Stub",
				savedAt: Date(timeIntervalSince1970: 1_000),
				lastUserMessageAt: Date(timeIntervalSince1970: 900)
			),
			for: workspace
		)
		_ = try await service.saveAgentSession(
			makeSession(
				id: newerSessionID,
				workspaceID: workspace.id,
				tabID: tabID,
				name: "Should Not Be Scanned",
				savedAt: Date(timeIntervalSince1970: 2_000),
				lastUserMessageAt: Date(timeIntervalSince1970: 1_900)
			),
			for: workspace
		)
		try FileManager.default.removeItem(at: metadataIndexURL(root: tempRoot))
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)

		let result = try await service.buildPrioritizedSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [tabID: "Explicit Tab"],
				validTabIDs: [tabID],
				boundSessionIDByTabID: [tabID: explicitSessionID]
			)
		)

		XCTAssertEqual(Set(result.entriesBySessionID.keys), [explicitSessionID])
		XCTAssertEqual(result.preferredSessionIDByTabID[tabID], explicitSessionID)
		XCTAssertFalse(FileManager.default.fileExists(atPath: metadataIndexURL(root: tempRoot).path))
	}

	func testTargetedPrioritizedBuildWithMissingIndexAndNoExplicitBindingReturnsEmpty() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let workspace = makeWorkspace(root: tempRoot, tabID: tabID, tabName: "Missing Index Empty")
		let agentSessionsFolder = agentSessionsFolder(root: tempRoot)
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)

		_ = try await service.saveAgentSession(
			makeSession(
				id: UUID(),
				workspaceID: workspace.id,
				tabID: tabID,
				name: "Existing Session",
				savedAt: Date(timeIntervalSince1970: 1_000),
				lastUserMessageAt: Date(timeIntervalSince1970: 900)
			),
			for: workspace
		)
		try FileManager.default.removeItem(at: metadataIndexURL(root: tempRoot))
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)

		let result = try await service.buildPrioritizedSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [tabID: "Empty Tab"],
				validTabIDs: [tabID]
			)
		)

		XCTAssertTrue(result.entriesBySessionID.isEmpty)
		XCTAssertTrue(result.preferredSessionIDByTabID.isEmpty)
		XCTAssertFalse(FileManager.default.fileExists(atPath: metadataIndexURL(root: tempRoot).path))
	}

	func testTargetedPrioritizedBuildWithMissingIndexAndCorruptExplicitSessionReturnsEmpty() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let explicitSessionID = UUID()
		let workspace = makeWorkspace(root: tempRoot, tabID: tabID, tabName: "Corrupt Explicit")
		let agentSessionsFolder = agentSessionsFolder(root: tempRoot)
		try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
		await service.test_clearMetadataIndexCache(forAgentSessionsFolder: agentSessionsFolder)
		try Data("{ not valid json".utf8).write(
			to: agentSessionsFolder.appendingPathComponent("AgentSession-\(explicitSessionID.uuidString).json"),
			options: .atomic
		)

		let result = try await service.buildPrioritizedSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [tabID: "Corrupt Tab"],
				validTabIDs: [tabID],
				boundSessionIDByTabID: [tabID: explicitSessionID]
			)
		)

		XCTAssertTrue(result.entriesBySessionID.isEmpty)
		XCTAssertTrue(result.preferredSessionIDByTabID.isEmpty)
		XCTAssertFalse(FileManager.default.fileExists(atPath: metadataIndexURL(root: tempRoot).path))
	}
	
	private func makeTempDirectory() -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("RepoPrompt-AgentSessionDataServiceIndexCacheTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private func makeWorkspace(root: URL, tabID: UUID, tabName: String) -> WorkspaceModel {
		WorkspaceModel(
			name: "Agent Index Cache Tests",
			repoPaths: [],
			customStoragePath: root,
			composeTabs: [ComposeTabState(id: tabID, name: tabName, lastModified: Date())],
			activeComposeTabID: tabID
		)
	}

	private func makeSession(
		id: UUID,
		workspaceID: UUID,
		tabID: UUID,
		name: String,
		savedAt: Date,
		lastUserMessageAt: Date?
	) -> AgentSession {
		let items = lastUserMessageAt.map { date in
			[
				AgentChatItemPersist(
					from: AgentChatItem(
						timestamp: date,
						kind: .user,
						text: name,
						sequenceIndex: 0
					)
				)
			]
		} ?? []
		return AgentSession(
			id: id,
			workspaceID: workspaceID,
			composeTabID: tabID,
			name: name,
			savedAt: savedAt,
			items: items,
			itemCount: items.count,
			lastUserMessageAt: lastUserMessageAt
		)
	}

	private func agentSessionsFolder(root: URL) -> URL {
		root.appendingPathComponent("AgentSessions", isDirectory: true)
	}

	private func metadataIndexURL(root: URL) -> URL {
		agentSessionsFolder(root: root).appendingPathComponent("AgentSessionIndex.json")
	}
}
