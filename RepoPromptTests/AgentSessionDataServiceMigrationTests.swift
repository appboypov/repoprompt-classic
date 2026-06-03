import XCTest
@testable import RepoPrompt

final class AgentSessionDataServiceMigrationTests: XCTestCase {
	func testLoadStubRecoversLastUserMessageAtWhenMissing() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "RecoverMissingField", root: tempRoot)
		let service = AgentSessionDataService.shared
		
		let userDate = Date(timeIntervalSince1970: 100)
		let assistantDate = Date(timeIntervalSince1970: 200)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Agent Session",
			savedAt: Date(timeIntervalSince1970: 300),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: userDate, kind: .user, text: "hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: assistantDate, kind: .assistant, text: "hi", sequenceIndex: 1))
			],
			lastUserMessageAt: nil
		)
		
		let fileURL = try await service.saveAgentSession(session, for: workspace)
		var storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		storedObject.removeValue(forKey: "lastUserMessageAt")
		let legacyData = try JSONSerialization.data(withJSONObject: storedObject)
		try legacyData.write(to: fileURL, options: .atomic)
		let stub = try await service.loadAgentSessionStub(
			from: fileURL,
			recoverMissingMetadata: true,
			persistRecoveredMetadata: false
		)
		XCTAssertEqual(stub.lastUserMessageAt, userDate)
		
		let rewrittenObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		XCTAssertNil(rewrittenObject["lastUserMessageAt"], "Non-migrating stub load should not rewrite persisted session")
	}
	
	func testLoadStubWithoutMetadataRecoveryLeavesMissingFieldsUntouched() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "StubHeaderOnly", root: tempRoot)
		let service = AgentSessionDataService.shared

		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Agent Session",
			savedAt: Date(timeIntervalSince1970: 350),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 200), kind: .assistant, text: "hi", sequenceIndex: 1))
			],
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		var storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		storedObject.removeValue(forKey: "lastUserMessageAt")
		storedObject.removeValue(forKey: "itemCount")
		storedObject.removeValue(forKey: "transcriptProjectionCounts")
		let legacyData = try JSONSerialization.data(withJSONObject: storedObject)
		try legacyData.write(to: fileURL, options: .atomic)
		let stub = try await service.loadAgentSessionStub(
			from: fileURL,
			recoverMissingMetadata: false,
			persistRecoveredMetadata: false
		)

		XCTAssertNil(stub.lastUserMessageAt)
		XCTAssertNil(stub.transcriptProjectionCounts)
		XCTAssertEqual(stub.itemCount, 0)
	}

	func testLoadStubMigrationBackfillsLastUserMessageAt() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "BackfillMissingField", root: tempRoot)
		let service = AgentSessionDataService.shared
		
		let userDate = Date(timeIntervalSince1970: 400)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Agent Session",
			savedAt: Date(timeIntervalSince1970: 500),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: userDate, kind: .user, text: "first", sequenceIndex: 0))
			],
			lastUserMessageAt: nil
		)
		
		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let stub = try await service.loadAgentSessionStub(
			from: fileURL,
			recoverMissingMetadata: true,
			persistRecoveredMetadata: true
		)
		XCTAssertEqual(stub.lastUserMessageAt, userDate)
		
		let migrated = try await service.loadAgentSession(from: fileURL)
		XCTAssertEqual(migrated.lastUserMessageAt, userDate, "Migration should persist recovered last user timestamp")
	}

	func testResolveAgentSessionIDSupportsUUIDOnly() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "ResolveByReference", root: tempRoot)
		let service = AgentSessionDataService.shared

		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Reference Session",
			items: [AgentChatItemPersist(from: AgentChatItem.user("hello", sequenceIndex: 0))]
		)

		_ = try await service.saveAgentSession(session, for: workspace)

		let resolvedByUUID = try await service.resolveAgentSessionID(reference: session.id.uuidString, for: workspace)
		let resolvedByNonUUID = try await service.resolveAgentSessionID(reference: "not-a-uuid", for: workspace)

		XCTAssertEqual(resolvedByUUID, session.id)
		XCTAssertNil(resolvedByNonUUID)
	}

	func testListAgentSessionsMetaReturnsMetadata() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "ListMeta", root: tempRoot)
		let service = AgentSessionDataService.shared

		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Metadata Session",
			items: [
				AgentChatItemPersist(from: AgentChatItem.user("start", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem.assistant("done", sequenceIndex: 1))
			],
			agentKind: DiscoverAgentKind.claudeCode.rawValue,
			agentModel: AgentModel.defaultModel.rawValue,
			lastRunState: AgentSessionRunState.completed.rawValue
		)

		_ = try await service.saveAgentSession(session, for: workspace)
		let metadata = try await service.listAgentSessionsMeta(for: workspace)
		let entry = try XCTUnwrap(metadata.first(where: { $0.id == session.id }))

		XCTAssertEqual(entry.name, session.name)
		XCTAssertEqual(entry.itemCount, session.effectiveItemCount)
		XCTAssertEqual(entry.agentKind, session.agentKind)
		XCTAssertEqual(entry.agentModel, session.agentModel)
		XCTAssertEqual(entry.lastRunState, session.lastRunState)
	}

	func testSaveCreatesMetadataIndex() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "SaveCreatesMetadataIndex", root: tempRoot)
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let parentID = UUID()

		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "  Indexed Session  ",
			items: [AgentChatItemPersist(from: AgentChatItem.user("index me", sequenceIndex: 0))],
			agentKind: DiscoverAgentKind.claudeCode.rawValue,
			agentModel: AgentModel.defaultModel.rawValue,
			lastRunState: AgentSessionRunState.completed.rawValue,
			parentSessionID: parentID,
			isMCPOriginated: true
		)

		_ = try await service.saveAgentSession(session, for: workspace)
		let index = try loadMetadataIndex(root: tempRoot)
		let record = try XCTUnwrap(index.entries.first(where: { $0.id == session.id }))

		XCTAssertEqual(index.schemaVersion, AgentSessionMetadataIndex.currentSchemaVersion)
		XCTAssertEqual(record.filename, "AgentSession-\(session.id.uuidString).json")
		XCTAssertEqual(record.workspaceID, workspace.id)
		XCTAssertEqual(record.composeTabID, tabID)
		XCTAssertEqual(record.name, "Indexed Session")
		XCTAssertEqual(record.itemCount, 1)
		XCTAssertEqual(record.agentKindRaw, session.agentKind)
		XCTAssertEqual(record.agentModelRaw, session.agentModel)
		XCTAssertEqual(record.lastRunStateRaw, session.lastRunState)
		XCTAssertEqual(record.parentSessionID, parentID)
		XCTAssertTrue(record.isMCPOriginated)
		XCTAssertNotNil(record.observedFileSize)
		XCTAssertNotNil(record.observedFileModificationDate)
	}

	func testListAgentSessionsMetaBackfillsMissingMetadataIndex() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "MissingIndexBackfill", root: tempRoot)
		let service = AgentSessionDataService.shared
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Backfilled Session",
			items: [AgentChatItemPersist(from: AgentChatItem.user("backfill", sequenceIndex: 0))]
		)

		_ = try await service.saveAgentSession(session, for: workspace)
		try FileManager.default.removeItem(at: metadataIndexURL(root: tempRoot))

		let metadata = try await service.listAgentSessionsMeta(for: workspace)
		let entry = try XCTUnwrap(metadata.first(where: { $0.id == session.id }))
		let index = try loadMetadataIndex(root: tempRoot)

		XCTAssertEqual(entry.name, "Backfilled Session")
		XCTAssertEqual(index.entries.map(\.id), [session.id])
	}

	func testListAgentSessionsMetaRebuildsCorruptMetadataIndex() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "CorruptIndexBackfill", root: tempRoot)
		let service = AgentSessionDataService.shared
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Corrupt Recovered",
			items: [AgentChatItemPersist(from: AgentChatItem.user("recover", sequenceIndex: 0))]
		)

		_ = try await service.saveAgentSession(session, for: workspace)
		try Data("{not valid json".utf8).write(to: metadataIndexURL(root: tempRoot), options: .atomic)

		let metadata = try await service.listAgentSessionsMeta(for: workspace)
		let entry = try XCTUnwrap(metadata.first(where: { $0.id == session.id }))
		let index = try loadMetadataIndex(root: tempRoot)

		XCTAssertEqual(entry.name, "Corrupt Recovered")
		XCTAssertEqual(index.schemaVersion, AgentSessionMetadataIndex.currentSchemaVersion)
		XCTAssertEqual(index.entries.map(\.id), [session.id])
	}

	func testListAgentSessionsIgnoresMetadataIndexFile() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "RawListIgnoresMetadataIndex", root: tempRoot)
		let service = AgentSessionDataService.shared
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Only Session",
			items: [AgentChatItemPersist(from: AgentChatItem.user("raw", sequenceIndex: 0))]
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		XCTAssertTrue(FileManager.default.fileExists(atPath: metadataIndexURL(root: tempRoot).path))
		try Data("{}".utf8).write(
			to: tempRoot
				.appendingPathComponent("AgentSessions", isDirectory: true)
				.appendingPathComponent("AgentSession-Index.json"),
			options: .atomic
		)

		let files = try await service.listAgentSessions(for: workspace)

		XCTAssertEqual(files.map(\.lastPathComponent), [fileURL.lastPathComponent])
		XCTAssertFalse(files.contains { $0.lastPathComponent == "AgentSessionIndex.json" })
	}

	func testRenameAgentSessionUpdatesSessionFileAndMetadataIndex() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "RenameUpdatesIndex", root: tempRoot)
		let service = AgentSessionDataService.shared
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Before Rename",
			items: [AgentChatItemPersist(from: AgentChatItem.user("rename", sequenceIndex: 0))]
		)

		_ = try await service.saveAgentSession(session, for: workspace)
		try await service.renameAgentSession(id: session.id, to: "  After Rename  ", for: workspace)
		let loadedSession = try await service.loadAgentSession(id: session.id, for: workspace)
		let loaded = try XCTUnwrap(loadedSession)
		let record = try XCTUnwrap(loadMetadataIndex(root: tempRoot).entries.first(where: { $0.id == session.id }))
		let metadata = try await service.listAgentSessionsMeta(for: workspace)
		let meta = try XCTUnwrap(metadata.first(where: { $0.id == session.id }))

		XCTAssertEqual(loaded.name, "After Rename")
		XCTAssertEqual(record.name, "After Rename")
		XCTAssertEqual(meta.name, "After Rename")
	}

	func testListAgentSessionsMetaOrdersAndLimitsFromMetadataIndex() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "IndexOrdering", root: tempRoot)
		let service = AgentSessionDataService.shared
		let newest = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Newest Activity",
			items: [AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 300), kind: .user, text: "new", sequenceIndex: 0))]
		)
		let middle = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Middle Activity",
			items: [AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 200), kind: .user, text: "mid", sequenceIndex: 0))]
		)
		let oldest = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Oldest Activity",
			items: [AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "old", sequenceIndex: 0))]
		)

		_ = try await service.saveAgentSession(newest, for: workspace)
		_ = try await service.saveAgentSession(middle, for: workspace)
		_ = try await service.saveAgentSession(oldest, for: workspace)

		let metadata = try await service.listAgentSessionsMeta(for: workspace, limit: 2)

		XCTAssertEqual(metadata.map(\.id), [newest.id, middle.id])
	}

	func testSaveIntoLegacyFolderBackfillsExistingSessionsBeforeIndexUpsert() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "LegacyFolderSaveBackfills", root: tempRoot)
		let service = AgentSessionDataService.shared
		let agentSessionsFolder = tempRoot.appendingPathComponent("AgentSessions", isDirectory: true)
		try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
		let legacyA = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Legacy A",
			items: [AgentChatItemPersist(from: AgentChatItem.user("a", sequenceIndex: 0))]
		)
		let legacyB = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Legacy B",
			items: [AgentChatItemPersist(from: AgentChatItem.user("b", sequenceIndex: 0))]
		)
		try JSONEncoder().encode(legacyA).write(
			to: agentSessionsFolder.appendingPathComponent("AgentSession-\(legacyA.id.uuidString).json"),
			options: .atomic
		)
		try JSONEncoder().encode(legacyB).write(
			to: agentSessionsFolder.appendingPathComponent("AgentSession-\(legacyB.id.uuidString).json"),
			options: .atomic
		)
		let newSession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "New Save",
			items: [AgentChatItemPersist(from: AgentChatItem.user("new", sequenceIndex: 0))]
		)

		_ = try await service.saveAgentSession(newSession, for: workspace)
		let metadataIDs = Set(try await service.listAgentSessionsMeta(for: workspace).map(\.id))
		let indexIDs = Set(try loadMetadataIndex(root: tempRoot).entries.map(\.id))

		XCTAssertEqual(metadataIDs, Set([legacyA.id, legacyB.id, newSession.id]))
		XCTAssertEqual(indexIDs, Set([legacyA.id, legacyB.id, newSession.id]))
	}

	func testConcurrentSavesPreserveMetadataIndexRecords() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "ConcurrentIndexSaves", root: tempRoot)
		let service = AgentSessionDataService.shared
		let sessions = (0..<8).map { index in
			AgentSession(
				workspaceID: workspace.id,
				composeTabID: UUID(),
				name: "Concurrent \(index)",
				items: [AgentChatItemPersist(from: AgentChatItem.user("save \(index)", sequenceIndex: 0))]
			)
		}

		try await withThrowingTaskGroup(of: Void.self) { group in
			for session in sessions {
				group.addTask {
					_ = try await service.saveAgentSession(session, for: workspace)
				}
			}
			try await group.waitForAll()
		}
		let indexIDs = Set(try loadMetadataIndex(root: tempRoot).entries.map(\.id))

		XCTAssertEqual(indexIDs, Set(sessions.map(\.id)))
	}

	func testDeleteAgentSessionRemovesMetadataIndexRecord() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "DeleteRemovesIndexRecord", root: tempRoot)
		let service = AgentSessionDataService.shared
		let deleted = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Delete Me",
			items: [AgentChatItemPersist(from: AgentChatItem.user("delete", sequenceIndex: 0))]
		)
		let kept = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Keep Me",
			items: [AgentChatItemPersist(from: AgentChatItem.user("keep", sequenceIndex: 0))]
		)

		_ = try await service.saveAgentSession(deleted, for: workspace)
		_ = try await service.saveAgentSession(kept, for: workspace)
		try await service.deleteAgentSession(id: deleted.id, for: workspace)
		let index = try loadMetadataIndex(root: tempRoot)

		XCTAssertFalse(index.entries.contains { $0.id == deleted.id })
		XCTAssertTrue(index.entries.contains { $0.id == kept.id })
	}

	func testListAgentSessionsMetaBackfillDoesNotRepairLegacyMetadata() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "ListBackfillNoRepair", root: tempRoot)
		let service = AgentSessionDataService.shared
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Legacy No Repair",
			savedAt: Date(timeIntervalSince1970: 300),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 200), kind: .assistant, text: "hi", sequenceIndex: 1))
			],
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		try FileManager.default.removeItem(at: metadataIndexURL(root: tempRoot))
		var storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		storedObject.removeValue(forKey: "lastUserMessageAt")
		storedObject.removeValue(forKey: "itemCount")
		storedObject.removeValue(forKey: "transcriptProjectionCounts")
		let legacyData = try JSONSerialization.data(withJSONObject: storedObject)
		try legacyData.write(to: fileURL, options: .atomic)

		let metadata = try await service.listAgentSessionsMeta(for: workspace)
		let entry = try XCTUnwrap(metadata.first(where: { $0.id == session.id }))
		let rewrittenObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		let indexRecord = try XCTUnwrap(loadMetadataIndex(root: tempRoot).entries.first(where: { $0.id == session.id }))

		XCTAssertEqual(entry.itemCount, 0)
		XCTAssertTrue(indexRecord.hasUnknownConversationContent)
		XCTAssertNil(rewrittenObject["lastUserMessageAt"])
		XCTAssertNil(rewrittenObject["itemCount"])
		XCTAssertNil(rewrittenObject["transcriptProjectionCounts"])
	}

	func testSaveWritesCurrentSerializationVersion() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "SerializationVersionSave", root: tempRoot)
		let service = AgentSessionDataService.shared

		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Versioned Session",
			items: [AgentChatItemPersist(from: AgentChatItem(kind: .user, text: "hello", sequenceIndex: 0))]
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		XCTAssertEqual(
			storedObject["serializationVersion"] as? Int,
			AgentSession.currentSerializationVersion,
			"Saved sessions should always include the current top-level serialization version"
		)
	}

	func testLoadUpgradesVersionlessSessionAndPersistsSerializationVersion() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "SerializationVersionLoadUpgrade", root: tempRoot)
		let service = AgentSessionDataService.shared

		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Legacy Session",
			items: [AgentChatItemPersist(from: AgentChatItem(kind: .user, text: "hello", sequenceIndex: 0))]
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		var storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		storedObject.removeValue(forKey: "serializationVersion")
		let legacyData = try JSONSerialization.data(withJSONObject: storedObject)
		try legacyData.write(to: fileURL, options: .atomic)

		let loaded = try await service.loadAgentSession(from: fileURL)
		XCTAssertEqual(loaded.serializationVersion, AgentSession.currentSerializationVersion)

		let migratedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		XCTAssertEqual(migratedObject["serializationVersion"] as? Int, AgentSession.currentSerializationVersion)
	}

	func testStubRecoveryPersistsSerializationVersionWhenRewritingMetadata() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "SerializationVersionStubRecovery", root: tempRoot)
		let service = AgentSessionDataService.shared

		let userDate = Date(timeIntervalSince1970: 610)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Legacy Stub Session",
			items: [AgentChatItemPersist(from: AgentChatItem(timestamp: userDate, kind: .user, text: "hello", sequenceIndex: 0))],
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		var storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		storedObject.removeValue(forKey: "serializationVersion")
		storedObject.removeValue(forKey: "lastUserMessageAt")
		let legacyData = try JSONSerialization.data(withJSONObject: storedObject)
		try legacyData.write(to: fileURL, options: .atomic)

		let stub = try await service.loadAgentSessionStub(
			from: fileURL,
			recoverMissingMetadata: true,
			persistRecoveredMetadata: true
		)
		XCTAssertEqual(stub.lastUserMessageAt, userDate)
		XCTAssertEqual(stub.serializationVersion, AgentSession.legacyUnversionedSerializationVersion)

		let migrated = try await service.loadAgentSession(from: fileURL)
		XCTAssertEqual(migrated.lastUserMessageAt, userDate)
		XCTAssertEqual(migrated.serializationVersion, AgentSession.currentSerializationVersion)
	}

	func testTranscriptStubCountsAskUserResponsesAsUserRecency() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "TranscriptAskUserRecency", root: tempRoot)
		let service = AgentSessionDataService.shared

		let items: [AgentChatItem] = [
			AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "Start", sequenceIndex: 0),
			AgentChatItem.toolResult(
				name: "ask_user",
				invocationID: nil,
				resultJSON: #"{"response":"Yes"}"#,
				isError: false,
				sequenceIndex: 1
			)
		]
		var transcript = AgentTranscriptIO.importLegacyItems(items)
		transcript = AgentTranscriptCompactor.compact(transcript)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Transcript AskUser",
			items: [],
			transcript: transcript,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let stub = try await service.loadAgentSessionStub(
			from: fileURL,
			recoverMissingMetadata: true,
			persistRecoveredMetadata: false
		)
		XCTAssertEqual(stub.lastUserMessageAt, items[1].timestamp)
	}

	func testLoadMigratesLegacyFlatSessionToCompactedTranscript() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "LegacyFlatTranscriptMigration", root: tempRoot)
		let service = AgentSessionDataService.shared
		let legacyItems = makeLegacyTranscriptItems(turnCount: 8)
		let legacySession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Legacy Flat Session",
			items: legacyItems.map { AgentChatItemPersist(from: $0) },
			transcript: nil,
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let agentSessionsFolder = tempRoot.appendingPathComponent("AgentSessions", isDirectory: true)
		try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
		let fileURL = agentSessionsFolder.appendingPathComponent("AgentSession-\(legacySession.id.uuidString).json")
		try JSONEncoder().encode(legacySession).write(to: fileURL)
		let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		XCTAssertNil(originalObject["transcript"], "Legacy fixture should start without a structured transcript")

		let loaded = try await service.loadAgentSession(from: fileURL)
		let transcript = try XCTUnwrap(loaded.transcript)
		let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)
		XCTAssertEqual(transcript.turns.count, 8)
		XCTAssertTrue(transcript.turns.allSatisfy { $0.retentionTier == .full })
		XCTAssertNil(transcript.compactionFrontier)
		XCTAssertEqual(loaded.itemCount, projectionCounts.canonicalVisibleRowCount)
		XCTAssertEqual(loaded.transcriptProjectionCounts, projectionCounts)
		XCTAssertNotNil(loaded.lastUserMessageAt)

		let migratedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		XCTAssertNotNil(migratedObject["transcript"], "Reload should persist the migrated structured transcript")
		XCTAssertNotNil(migratedObject["transcriptProjectionCounts"])
		let reloaded = try await service.loadAgentSession(from: fileURL)
		XCTAssertEqual(reloaded.transcript?.turns.map(\.retentionTier), transcript.turns.map(\.retentionTier))
	}

	func testSaveNoTranscriptDerivesCompactSummaryBeforeClearingLegacyItems() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "NoTranscriptRawSummarySave", root: tempRoot)
		let service = AgentSessionDataService.shared
		let invocationID = UUID()
		let sentinel = "NO-TRANSCRIPT-RAW-GIT-SENTINEL"
		let rawGitStatus = #"{"op":"status","status":{"branch":"Dev","upstream":"origin/Dev","staged":["__SENTINEL__", "b"],"modified":["m"],"untracked":["u1", "u2"]}}"#
			.replacingOccurrences(of: "__SENTINEL__", with: sentinel)
		XCTAssertLessThan(rawGitStatus.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

		let items: [AgentChatItem] = [
			AgentChatItem.user("Check status", sequenceIndex: 0),
			AgentChatItem.toolCall(name: "git", invocationID: invocationID, argsJSON: #"{"op":"status"}"#, sequenceIndex: 1),
			AgentChatItem.toolResult(name: "git", invocationID: invocationID, resultJSON: rawGitStatus, isError: false, sequenceIndex: 2),
			AgentChatItem.assistant("done", sequenceIndex: 3)
		]
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "No Transcript Raw Summary",
			items: items.map { AgentChatItemPersist(from: $0, sanitizeToolResults: false) },
			transcript: nil,
			lastRunState: AgentSessionRunState.completed.rawValue
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let storedData = try Data(contentsOf: fileURL)
		let storedString = String(data: storedData, encoding: .utf8) ?? ""
		let storedSession = try JSONDecoder().decode(AgentSession.self, from: storedData)
		let transcript = try XCTUnwrap(storedSession.transcript)
		let persistedResult = try XCTUnwrap(
			transcript.allActivities.first { $0.itemKind == .toolResult && $0.toolExecution?.toolName == "git" }
		)
		let execution = try XCTUnwrap(persistedResult.toolExecution)

		XCTAssertTrue(storedSession.items.isEmpty)
		XCTAssertFalse(storedString.contains(sentinel))
		XCTAssertNil(execution.argsJSON)
		XCTAssertTrue(execution.keyPaths.isEmpty)
		XCTAssertTrue(execution.summaryOnly)
		XCTAssertEqual(execution.summaryText, "status • Dev • origin/Dev • 2 staged • 1 modified • 2 untracked")
		XCTAssertEqual(persistedResult.text, execution.resultJSON)
		let resultJSON = try XCTUnwrap(execution.resultJSON)
		let resultData = try XCTUnwrap(resultJSON.data(using: .utf8))
		let resultObject = try XCTUnwrap(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
		XCTAssertEqual(resultObject["summary_only"] as? Bool, true)
		XCTAssertEqual(resultObject["summary_text"] as? String, "status • Dev • origin/Dev • 2 staged • 1 modified • 2 untracked")
	}

	func testSaveLoadPersistsTargetToolRenderSummariesWithoutRawPayloads() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "TargetRenderSummarySaveLoad", root: tempRoot)
		let service = AgentSessionDataService.shared
		let fixtures: [(toolName: String, argsJSON: String, resultJSON: String, expectedLine: String, expectedStatus: ToolCardStatus, sentinels: [String])] = [
			(
				"read_file",
				#"{"path":"BombSquadPointerData.cs"}"#,
				#"{"display_path":"BombSquadPointerData.cs","first_line":1,"last_line":68,"total_lines":68,"content":"READ-CONTENT-SENTINEL"}"#,
				"BombSquadPointerData.cs • Lines 1-68 of 68",
				.success,
				["READ-CONTENT-SENTINEL"]
			),
			(
				"file_search",
				#"{"pattern":"SpatialPointerKind"}"#,
				#"{"total_matches":8,"total_files":3,"limit_hit":true,"matches":[{"path":"Search.swift","line_text":"SEARCH-CONTEXT-SENTINEL"}]}"#,
				#""SpatialPointerKind" • 8 matches in 3 files (limited)"#,
				.warning,
				["SEARCH-CONTEXT-SENTINEL"]
			),
			(
				"manage_selection",
				#"{"op":"set"}"#,
				#"{"status":"success","files":["SELECTION-PATH-SENTINEL","A.swift","B.swift","C.swift","D.swift","E.swift","F.swift"],"total_tokens":1085,"summary":{"full_count":0,"slice_count":2,"codemap_count":5}}"#,
				"set • 7 files • 1085 tokens • 0 full • 2 sliced • 5 codemap",
				.success,
				["SELECTION-PATH-SENTINEL"]
			),
			(
				"workspace_context",
				#"{"include":["selection","files"]}"#,
				#"{"prompt":"","selection":{"files":["WorkspaceA.swift","WorkspaceB.swift","WorkspaceC.swift","WorkspaceD.swift","WorkspaceE.swift","WorkspaceF.swift","WorkspaceG.swift"],"total_tokens":1460},"file_blocks":[{"path":"WorkspaceA.swift","content":"WORKSPACE-FILEBLOCK-SENTINEL"}],"copy_preset":{"name":"Default"}}"#,
				"7 files • 1460 tokens • selection • file blocks • copy preset",
				.success,
				["WORKSPACE-FILEBLOCK-SENTINEL"]
			),
			(
				"get_file_tree",
				#"{"mode":"selected"}"#,
				#"{"roots_count":1,"uses_legend":true,"tree":"TREE-SENTINEL\n└── App.swift","was_truncated":false}"#,
				"Selected • 1 root",
				.success,
				["TREE-SENTINEL"]
			),
			(
				"get_code_structure",
				#"{"paths":["Sources"]}"#,
				#"{"file_count":3,"content":"CODE-STRUCTURE-CONTENT-SENTINEL","unmapped_paths":["/tmp/CODE-STRUCTURE-PATH-SENTINEL/Feature/PendingOne.swift","PendingTwo.swift","/tmp/CODE-STRUCTURE-PATH-SENTINEL/Other/PendingThree.swift"],"codemaps_omitted":1,"token_budget_omitted":2,"token_budget_hit":true}"#,
				"3 files • 3 omitted • 3 unmapped • …/Feature/PendingOne.swift • PendingTwo.swift • (+1 more)",
				.warning,
				["CODE-STRUCTURE-CONTENT-SENTINEL", "CODE-STRUCTURE-PATH-SENTINEL"]
			),
			(
				"git",
				#"{"op":"show"}"#,
				#"{"op":"show","show":{"short_sha":"04ada27a","message":"Merge branch 'masiknight'","totals":{"files":2,"insertions":3732,"deletions":3890},"patch":"GIT-PATCH-SENTINEL"}}"#,
				"show • 04ada27a • Merge branch 'masiknight' • 2 files (+3732 -3890)",
				.success,
				["GIT-PATCH-SENTINEL"]
			)
		]

		var sequenceIndex = 0
		var items: [AgentChatItem] = [AgentChatItem.user("Summarize tools", sequenceIndex: sequenceIndex)]
		sequenceIndex += 1
		for fixture in fixtures {
			let invocationID = UUID()
			items.append(AgentChatItem.toolCall(name: fixture.toolName, invocationID: invocationID, argsJSON: fixture.argsJSON, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			var result = AgentChatItem.toolResult(name: fixture.toolName, invocationID: invocationID, resultJSON: fixture.resultJSON, isError: false, sequenceIndex: sequenceIndex)
			result.toolArgsJSON = fixture.argsJSON
			items.append(result)
			sequenceIndex += 1
		}
		items.append(AgentChatItem.assistant("done", sequenceIndex: sequenceIndex))
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Target Render Summary Save Load",
			items: items.map { AgentChatItemPersist(from: $0, sanitizeToolResults: false) },
			transcript: nil,
			lastRunState: AgentSessionRunState.completed.rawValue
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let storedData = try Data(contentsOf: fileURL)
		let storedString = String(data: storedData, encoding: .utf8) ?? ""
		let storedSession = try JSONDecoder().decode(AgentSession.self, from: storedData)
		let storedTranscript = try XCTUnwrap(storedSession.transcript)

		XCTAssertTrue(storedSession.items.isEmpty)
		for fixture in fixtures {
			for sentinel in fixture.sentinels {
				XCTAssertFalse(storedString.contains(sentinel), "\(fixture.toolName) leaked \(sentinel)")
			}
			let persistedResult = try XCTUnwrap(
				storedTranscript.allActivities.first { $0.itemKind == .toolResult && $0.toolExecution?.toolName == fixture.toolName },
				fixture.toolName
			)
			let execution = try XCTUnwrap(persistedResult.toolExecution, fixture.toolName)
			XCTAssertNil(execution.argsJSON, fixture.toolName)
			XCTAssertTrue(execution.keyPaths.isEmpty, fixture.toolName)
			XCTAssertTrue(execution.summaryOnly, fixture.toolName)
			let resultJSON = try XCTUnwrap(execution.resultJSON, fixture.toolName)
			XCTAssertTrue(resultJSON.contains(#""summary_only":true"#), fixture.toolName)
			XCTAssertTrue(resultJSON.contains(#""render_summary""#), fixture.toolName)
			let presentation = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: resultJSON), fixture.toolName)
			XCTAssertEqual(presentation.inlineSubtitle, fixture.expectedLine, fixture.toolName)
			XCTAssertEqual(presentation.status, fixture.expectedStatus, fixture.toolName)
			XCTAssertEqual(persistedResult.text, execution.resultJSON, fixture.toolName)
		}

		let loaded = try await service.loadAgentSession(from: fileURL)
		let loadedRows = loaded.workingSourceItems()
		for fixture in fixtures {
			let loadedPresentationRow = loadedRows
				.filter { $0.kind == .toolResult && $0.toolName == fixture.toolName }
				.compactMap { row -> (AgentChatItem, StoredToolCardPresentation)? in
					let raw = row.toolResultJSON ?? row.text
					guard let presentation = StoredToolCardPresentation.fromSummaryOnly(raw: raw) else { return nil }
					return (row, presentation)
				}
				.first
			let (loadedResult, presentation) = try XCTUnwrap(loadedPresentationRow, fixture.toolName)
			XCTAssertEqual(presentation.inlineSubtitle, fixture.expectedLine, fixture.toolName)
			XCTAssertEqual(presentation.status, fixture.expectedStatus, fixture.toolName)
			XCTAssertNil(loadedResult.toolArgsJSON, fixture.toolName)
		}

		let firstRewrite = try Data(contentsOf: fileURL)
		_ = try await service.loadAgentSession(from: fileURL)
		let secondRewrite = try Data(contentsOf: fileURL)
		XCTAssertEqual(firstRewrite, secondRewrite)
	}

	func testLoadMigrationRebuildsTranscriptWithCanonicalImportPolicy() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "CanonicalPolicyMigration", root: tempRoot)
		let service = AgentSessionDataService.shared
		let items: [AgentChatItem] = [
			AgentChatItem.user("Start", sequenceIndex: 0),
			AgentChatItem.toolCall(name: "set_status", invocationID: nil, argsJSON: #"{"text":"Thinking"}"#, sequenceIndex: 1),
			AgentChatItem.toolResult(name: "set_status", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 2),
			AgentChatItem.assistant("Done", sequenceIndex: 3)
		]
		let rawTranscript = AgentTranscriptIO.importLegacyItems(items)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Canonical Policy",
			items: items.map { AgentChatItemPersist(from: $0) },
			transcript: rawTranscript,
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let loaded = try await service.loadAgentSession(from: fileURL)
		let rebuiltRows = AgentTranscriptIO.flattenFullTranscript(try XCTUnwrap(loaded.transcript))

		XCTAssertFalse(rebuiltRows.contains(where: { $0.toolName == "set_status" }))
		XCTAssertEqual(rebuiltRows.map(\.kind), [.user, .assistant])
	}

	func testLoadMigrationFinalizesInactiveCodexExplicitRepoPromptToolCalls() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "CodexExplicitToolMigration", root: tempRoot)
		let service = AgentSessionDataService.shared
		let items: [AgentChatItem] = [
			AgentChatItem.user("Start", sequenceIndex: 0),
			AgentChatItem.toolCall(name: "mcp__RepoPrompt__context_builder", invocationID: nil, argsJSON: #"{"query":"help"}"#, sequenceIndex: 1)
		]
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Explicit Tool Recovery",
			items: items.map { AgentChatItemPersist(from: $0) },
			transcript: nil,
			itemCount: nil,
			lastUserMessageAt: nil,
			agentKind: DiscoverAgentKind.codexExec.rawValue,
			lastRunState: AgentSessionRunState.completed.rawValue
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let loaded = try await service.loadAgentSession(from: fileURL)
		let recoveredItems = loaded.items.map { $0.toItem() }
		let recoveredRows = AgentTranscriptIO.flattenFullTranscript(try XCTUnwrap(loaded.transcript))

		XCTAssertEqual(recoveredItems.last?.kind, .toolResult)
		XCTAssertNotNil(recoveredItems.last?.toolResultJSON)
		XCTAssertEqual(recoveredRows.last?.kind, .toolResult)
	}

	func testLoadMigrationRetainsVisibleHeavyToolPayloadAtRuntimeWhileRewriteSanitizesStorage() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "HeavyPayloadVisibleMigration", root: tempRoot)
		let service = AgentSessionDataService.shared
		let rawResult = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}"#
		let toolResult = AgentChatItem.toolResult(name: "apply_patch", invocationID: nil, resultJSON: rawResult, isError: false, sequenceIndex: 2)
		let items: [AgentChatItem] = [
			AgentChatItem.user("Patch it", sequenceIndex: 0),
			AgentChatItem.toolCall(name: "apply_patch", invocationID: nil, argsJSON: #"{"path":"/tmp/file.swift","change_count":1}"#, sequenceIndex: 1),
			toolResult,
			AgentChatItem.assistant("Patch applied.", sequenceIndex: 3)
		]
		var rawPersistedItems = items.map { AgentChatItemPersist(from: $0) }
		let toolResultIndex = try XCTUnwrap(rawPersistedItems.firstIndex(where: { $0.id == toolResult.id }))
		rawPersistedItems[toolResultIndex].toolResultJSON = rawResult
		rawPersistedItems[toolResultIndex].text = rawResult
		let rawTranscript = AgentTranscriptIO.importLegacyItems(items)
		let visibleResultIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
			in: AgentTranscriptProjectionBuilder.build(from: rawTranscript)
		)
		XCTAssertTrue(
			visibleResultIDs.contains(toolResult.id),
			"This fixture must exercise projection-visible runtime raw retention."
		)
		let rawSession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Heavy Payload Visible",
			items: rawPersistedItems,
			transcript: rawTranscript,
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(rawSession, for: workspace)
		let rawData = try JSONEncoder().encode(rawSession)
		try rawData.write(to: fileURL, options: .atomic)

		let loaded = try await service.loadAgentSession(from: fileURL)
		let loadedTranscriptItem = try XCTUnwrap(
			AgentTranscriptIO.flattenFullTranscript(try XCTUnwrap(loaded.transcript)).first(where: { $0.id == toolResult.id })
		)
		let rewrittenSession = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
		let rewrittenTranscriptItem = try XCTUnwrap(
			AgentTranscriptIO.flattenFullTranscript(try XCTUnwrap(rewrittenSession.transcript)).first(where: { $0.id == toolResult.id })
		)

		XCTAssertEqual(loadedTranscriptItem.toolResultJSON, rawResult)
		XCTAssertEqual(loadedTranscriptItem.text, rawResult)
		XCTAssertFalse(rewrittenTranscriptItem.toolResultJSON?.contains("@@ -1 +1 @@") == true)
		XCTAssertFalse(rewrittenTranscriptItem.text.contains("@@ -1 +1 @@"))
		XCTAssertTrue(rewrittenTranscriptItem.toolResultJSON?.contains(#""summary_only":true"#) == true)
	}

	func testLoadMigrationSanitizesHiddenGroupedHeavyToolPayloads() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "HeavyPayloadHiddenMigration", root: tempRoot)
		let service = AgentSessionDataService.shared
		let rawResult = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}"#
		var items: [AgentChatItem] = [AgentChatItem.user("Patch it", sequenceIndex: 0)]
		var sequenceIndex = 1
		for toolOffset in 0..<10 {
			let toolName = toolOffset == 0 ? "apply_patch" : "read_file"
			let invocationID = UUID()
			items.append(AgentChatItem.assistantInline("step \(toolOffset + 1)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			let argsJSON = toolName == "apply_patch"
				? #"{"path":"/tmp/file.swift","change_count":1}"#
				: #"{"path":"/tmp/file.swift"}"#
			items.append(AgentChatItem.toolCall(name: toolName, invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			let resultJSON = toolName == "apply_patch" ? rawResult : #"{"status":"success"}"#
			items.append(AgentChatItem.toolResult(name: toolName, invocationID: invocationID, resultJSON: resultJSON, isError: false, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		items.append(AgentChatItem.assistant("final summary", sequenceIndex: sequenceIndex))
		let hiddenToolResultID = try XCTUnwrap(
			items.first(where: { $0.kind == .toolResult && $0.toolName == "apply_patch" })?.id
		)
		var rawPersistedItems = items.map { AgentChatItemPersist(from: $0) }
		let hiddenToolResultIndex = try XCTUnwrap(rawPersistedItems.firstIndex(where: { $0.id == hiddenToolResultID }))
		rawPersistedItems[hiddenToolResultIndex].toolResultJSON = rawResult
		rawPersistedItems[hiddenToolResultIndex].text = rawResult
		let rawTranscript = AgentTranscriptIO.importLegacyItems(items)
		let rawSession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Heavy Payload Hidden",
			items: rawPersistedItems,
			transcript: rawTranscript,
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(rawSession, for: workspace)
		let rawData = try JSONEncoder().encode(rawSession)
		try rawData.write(to: fileURL, options: .atomic)
		let visibleResultIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
			in: AgentTranscriptProjectionBuilder.build(from: rawTranscript)
		)
		XCTAssertFalse(visibleResultIDs.contains(hiddenToolResultID))

		let loaded = try await service.loadAgentSession(from: fileURL)
		let loadedTranscriptItem = try XCTUnwrap(
			AgentTranscriptIO.flattenFullTranscript(try XCTUnwrap(loaded.transcript)).first(where: { $0.id == hiddenToolResultID })
		)
		let rewrittenSession = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
		let rewrittenTranscriptItem = try XCTUnwrap(
			AgentTranscriptIO.flattenFullTranscript(try XCTUnwrap(rewrittenSession.transcript)).first(where: { $0.id == hiddenToolResultID })
		)

		XCTAssertFalse(loadedTranscriptItem.toolResultJSON?.contains("@@ -1 +1 @@") == true)
		XCTAssertFalse(rewrittenTranscriptItem.toolResultJSON?.contains("@@ -1 +1 @@") == true)
		XCTAssertTrue(loadedTranscriptItem.toolResultJSON?.contains(#""summary_only":true"#) == true)
		XCTAssertTrue(rewrittenTranscriptItem.toolResultJSON?.contains(#""summary_only":true"#) == true)
		XCTAssertEqual(loadedTranscriptItem.text, loadedTranscriptItem.toolResultJSON)
	}

	func testLoadRawTranscriptPreservesRuntimeToolMetadataWhileRewritingStorageSanitized() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "RawTranscriptRuntimeSplit", root: tempRoot)
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let invocationID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
		let argsPayload = #"{"command":"echo ARG-SENTINEL","secret":"ARG-SENTINEL"}"#
		let resultPayload = #"{"type":"commandExecution","status":"success","exitCode":0,"aggregatedOutput":"RESULT-SENTINEL"}"#
		let call = AgentChatItem.toolCall(
			name: "bash",
			invocationID: invocationID,
			argsJSON: argsPayload,
			sequenceIndex: 1
		)
		var result = AgentChatItem.toolResult(
			name: "bash",
			invocationID: invocationID,
			resultJSON: resultPayload,
			isError: false,
			sequenceIndex: 2
		)
		result.toolArgsJSON = argsPayload
		let rawItems: [AgentChatItem] = [
			AgentChatItem.user("Run raw command", sequenceIndex: 0),
			call,
			result,
			AgentChatItem.assistant("done", sequenceIndex: 3)
		]
		let rawTranscript = AgentTranscriptIO.buildTranscript(
			from: rawItems,
			terminalState: .completed,
			nextSequenceIndex: 4,
			policy: .canonical,
			compact: false
		)
		let visibleResultIDs = AgentTranscriptProjectionBuilder.visibleToolResultRowIDs(
			in: AgentTranscriptProjectionBuilder.build(from: rawTranscript)
		)
		XCTAssertTrue(
			visibleResultIDs.contains(result.id),
			"This fixture must exercise projection-visible runtime raw retention."
		)
		let rawSession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Raw Tool Session",
			savedAt: Date(timeIntervalSince1970: 1_000),
			items: [],
			transcript: rawTranscript,
			lastRunState: AgentSessionRunState.completed.rawValue
		)
		let agentSessionsFolder = tempRoot.appendingPathComponent("AgentSessions", isDirectory: true)
		try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
		let fileURL = agentSessionsFolder.appendingPathComponent("AgentSession-\(rawSession.id.uuidString).json")
		try JSONEncoder().encode(rawSession).write(to: fileURL, options: .atomic)

		let loaded = try await service.loadAgentSession(from: fileURL)
		let loadedWorkingItems = loaded.workingSourceItems()
		let loadedCall = try XCTUnwrap(
			loadedWorkingItems.first { $0.id == call.id },
			"Runtime restore should hydrate tool calls from raw decoded transcript data, not persistence-sanitized storage data."
		)
		let loadedResult = try XCTUnwrap(
			loadedWorkingItems.first { $0.id == result.id },
			"Runtime restore should hydrate tool results from raw decoded transcript data, not persistence-sanitized storage data."
		)

		XCTAssertEqual(
			loadedCall.toolArgsJSON,
			argsPayload,
			"Runtime restore must preserve raw full-suffix tool call args until the app explicitly rewrites storage."
		)
		XCTAssertEqual(
			loadedResult.toolArgsJSON,
			argsPayload,
			"Runtime restore must preserve raw full-suffix tool result args for in-memory continuation."
		)
		XCTAssertEqual(
			loadedResult.toolResultJSON,
			resultPayload,
			"Runtime restore must preserve raw full-suffix tool result JSON for in-memory continuation."
		)

		let rewrittenData = try Data(contentsOf: fileURL)
		let rewrittenString = String(data: rewrittenData, encoding: .utf8) ?? ""
		let rewrittenSession = try JSONDecoder().decode(AgentSession.self, from: rewrittenData)
		let rewrittenItems = AgentTranscriptIO.flattenFullTranscript(try XCTUnwrap(rewrittenSession.transcript))
		let rewrittenCall = try XCTUnwrap(rewrittenItems.first { $0.id == call.id })
		let rewrittenResult = try XCTUnwrap(rewrittenItems.first { $0.id == result.id })

		XCTAssertTrue(rewrittenSession.items.isEmpty)
		XCTAssertFalse(rewrittenString.contains("ARG-SENTINEL"), "Canonical rewrite should keep persisted tool args sanitized even though runtime restore preserved them.")
		XCTAssertFalse(rewrittenString.contains("RESULT-SENTINEL"), "Canonical rewrite should keep persisted tool results sanitized even though runtime restore preserved them.")
		XCTAssertNil(rewrittenCall.toolArgsJSON)
		XCTAssertNil(rewrittenResult.toolArgsJSON)
		XCTAssertFalse(rewrittenResult.toolResultJSON?.contains("RESULT-SENTINEL") == true)
		XCTAssertTrue(rewrittenResult.toolResultJSON?.contains(#""summary_only":true"#) == true)
	}

	func testLoadRewriteIsStableAfterFirstCanonicalRewrite() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "RewriteStability", root: tempRoot)
		let service = AgentSessionDataService.shared
		let legacyItems = makeLegacyTranscriptItems(turnCount: 8)
		let legacySession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Legacy Rewrite Session",
			items: legacyItems.map { AgentChatItemPersist(from: $0) },
			transcript: nil,
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let agentSessionsFolder = tempRoot.appendingPathComponent("AgentSessions", isDirectory: true)
		try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
		let fileURL = agentSessionsFolder.appendingPathComponent("AgentSession-\(legacySession.id.uuidString).json")
		try JSONEncoder().encode(legacySession).write(to: fileURL)

		_ = try await service.loadAgentSession(from: fileURL)
		let firstRewrite = try Data(contentsOf: fileURL)
		_ = try await service.loadAgentSession(from: fileURL)
		let secondRewrite = try Data(contentsOf: fileURL)

		XCTAssertEqual(firstRewrite, secondRewrite)
	}

	func testSaveAlreadyCanonicalTranscriptUsesCanonicalItemCountAndUnloadsItems() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "AlreadyCanonicalTranscriptSave", root: tempRoot)
		let service = AgentSessionDataService.shared
		let transcript = AgentTranscriptCompactor.compact(
			AgentTranscriptIO.importLegacyItems(makeLegacyTranscriptItems(turnCount: 10))
		)
		let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)
		let canonicalItemCount = projectionCounts.canonicalVisibleRowCount
		let customLastUserMessageAt = Date(timeIntervalSince1970: 9_999)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Canonical Save",
			items: [AgentChatItemPersist(from: AgentChatItem.user("live tail", sequenceIndex: 500))],
			transcript: transcript,
			itemCount: canonicalItemCount + 7,
			transcriptProjectionCounts: .init(
				canonicalVisibleRowCount: canonicalItemCount + 7,
				defaultPresentedRowCount: canonicalItemCount + 7
			),
			lastUserMessageAt: customLastUserMessageAt
		)

		let fileURL = try await service.saveAgentSession(
			session,
			for: workspace,
			preparation: .alreadyCanonicalTranscript
		)
		let stub = try await service.loadAgentSessionStub(from: fileURL, persistRecoveredMetadata: false)
		let storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		let storedItems = try XCTUnwrap(storedObject["items"] as? [Any])

		XCTAssertEqual(stub.itemCount, canonicalItemCount)
		XCTAssertEqual(stub.transcriptProjectionCounts, projectionCounts)
		XCTAssertEqual(stub.lastUserMessageAt, customLastUserMessageAt)
		XCTAssertTrue(storedItems.isEmpty)
		XCTAssertNotNil(storedObject["transcriptProjectionCounts"])
	}

	func testConcurrentSavesKeepLatestSnapshot() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "ConcurrentSave", root: tempRoot)
		let service = AgentSessionDataService.shared
		let sessionID = UUID()

		let first = AgentSession(
			id: sessionID,
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "First",
			savedAt: Date(timeIntervalSince1970: 100),
			items: [AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .user, text: "a", sequenceIndex: 0))],
			lastUserMessageAt: Date(timeIntervalSince1970: 1)
		)
		let second = AgentSession(
			id: sessionID,
			workspaceID: workspace.id,
			composeTabID: first.composeTabID,
			name: "Second",
			savedAt: Date(timeIntervalSince1970: 200),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 1), kind: .user, text: "a", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 2), kind: .assistant, text: "b", sequenceIndex: 1))
			],
			lastUserMessageAt: Date(timeIntervalSince1970: 1)
		)

		async let firstSave = service.saveAgentSession(first, for: workspace)
		try? await Task.sleep(nanoseconds: 10_000_000)
		async let secondSave = service.saveAgentSession(second, for: workspace)
		let (_, fileURL) = try await (firstSave, secondSave)

		let loaded = try await service.loadAgentSession(from: fileURL)
		XCTAssertEqual(loaded.name, "Second")
		XCTAssertEqual(loaded.items.count, 2)
	}

	func testSaveLoadPreservesProviderTokenUsageByTurn() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "ProviderTokenUsage", root: tempRoot)
		let service = AgentSessionDataService.shared

		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Agent Session",
			items: [AgentChatItemPersist(from: AgentChatItem(kind: .user, text: "hello", sequenceIndex: 0))],
			providerTokenUsageByTurn: [
				AgentTokenUsagePersist(promptTokens: 100, completionTokens: 20, timestamp: Date(timeIntervalSince1970: 10)),
				AgentTokenUsagePersist(promptTokens: 80, completionTokens: 40, timestamp: Date(timeIntervalSince1970: 20))
			]
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let loaded = try await service.loadAgentSession(from: fileURL)

		XCTAssertEqual(loaded.providerTokenUsageByTurn.count, 2)
		XCTAssertEqual(loaded.providerTokenUsageByTurn[0].promptTokens, 100)
		XCTAssertEqual(loaded.providerTokenUsageByTurn[0].completionTokens, 20)
		XCTAssertEqual(loaded.providerTokenUsageByTurn[1].promptTokens, 80)
		XCTAssertEqual(loaded.providerTokenUsageByTurn[1].completionTokens, 40)
	}

	func testLoadStubPreservesDeferredProviderLockFlagAndDefaultsMissingFieldToFalse() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "DeferredProviderLock", root: tempRoot)
		let service = AgentSessionDataService.shared

		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: UUID(),
			name: "Agent Session",
			items: [AgentChatItemPersist(from: AgentChatItem(kind: .user, text: "hello", sequenceIndex: 0))],
			pendingHandoffPayload: "payload",
			pendingHandoffCreatedAt: Date(timeIntervalSince1970: 50),
			pendingHandoffSourceItemID: UUID(),
			pendingHandoffDefersProviderLockUntilSend: true
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		let stub = try await service.loadAgentSessionStub(from: fileURL, persistRecoveredMetadata: false)
		XCTAssertTrue(stub.pendingHandoffDefersProviderLockUntilSend)

		let encoded = try JSONEncoder().encode(try await service.loadAgentSession(from: fileURL))
		var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		jsonObject.removeValue(forKey: "pendingHandoffDefersProviderLockUntilSend")
		let legacyData = try JSONSerialization.data(withJSONObject: jsonObject)
		try legacyData.write(to: fileURL, options: .atomic)

		let legacyStub = try await service.loadAgentSessionStub(from: fileURL, persistRecoveredMetadata: false)
		XCTAssertFalse(legacyStub.pendingHandoffDefersProviderLockUntilSend)
	}

	func testBuildSidebarIndexSkipsMetadataRepairOnHotPath() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "SidebarHeaderOnly", root: tempRoot)
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Legacy Sidebar Session",
			savedAt: Date(timeIntervalSince1970: 300),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 200), kind: .assistant, text: "hi", sequenceIndex: 1))
			],
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		var storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		storedObject.removeValue(forKey: "lastUserMessageAt")
		storedObject.removeValue(forKey: "itemCount")
		storedObject.removeValue(forKey: "transcriptProjectionCounts")
		let legacyData = try JSONSerialization.data(withJSONObject: storedObject)
		try legacyData.write(to: fileURL, options: .atomic)
		try? FileManager.default.removeItem(at: metadataIndexURL(root: tempRoot))

		let result = try await service.buildSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [tabID: "  Restored Tab  "],
				validTabIDs: [tabID]
			)
		)
		let entry = try XCTUnwrap(result.entriesBySessionID[session.id])
		let rewrittenObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])

		XCTAssertEqual(result.preferredSessionIDByTabID[tabID], session.id)
		XCTAssertEqual(entry.name, "Restored Tab")
		XCTAssertEqual(entry.itemCount, 0)
		XCTAssertNil(entry.lastUserMessageAt)
		XCTAssertNil(rewrittenObject["lastUserMessageAt"])
		XCTAssertNil(rewrittenObject["itemCount"])
		XCTAssertNil(rewrittenObject["transcriptProjectionCounts"])
	}

	func testBuildSidebarIndexHonorsExplicitBoundSessionIDOverNewerDuplicate() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "SidebarExplicitBinding", root: tempRoot)
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let olderSessionID = UUID()
		let newerSessionID = UUID()
		let olderSession = AgentSession(
			id: olderSessionID,
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Older Explicit Session",
			savedAt: Date(timeIntervalSince1970: 300),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "older", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 100)
		)
		let newerSession = AgentSession(
			id: newerSessionID,
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Newer Duplicate Session",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 250), kind: .user, text: "newer", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 250)
		)

		_ = try await service.saveAgentSession(olderSession, for: workspace)
		_ = try await service.saveAgentSession(newerSession, for: workspace)

		let result = try await service.buildSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [tabID: "Active Session"],
				validTabIDs: [tabID],
				boundSessionIDByTabID: [tabID: olderSessionID]
			)
		)

		XCTAssertEqual(result.preferredSessionIDByTabID[tabID], olderSessionID)
		XCTAssertEqual(result.entriesBySessionID[olderSessionID]?.tabID, tabID)
		XCTAssertEqual(result.entriesBySessionID[olderSessionID]?.name, "Active Session")
		XCTAssertEqual(result.entriesBySessionID[newerSessionID]?.tabID, tabID)
	}

	func testBuildSidebarIndexDoesNotLeakExplicitBindingToStaleComposeTabID() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "SidebarExplicitStaleTab", root: tempRoot)
		let service = AgentSessionDataService.shared
		let explicitTabID = UUID()
		let staleTabID = UUID()
		let sessionID = UUID()
		let staleSession = AgentSession(
			id: sessionID,
			workspaceID: workspace.id,
			composeTabID: staleTabID,
			name: "Stale Metadata Session",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 250), kind: .user, text: "stale", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 250)
		)

		_ = try await service.saveAgentSession(staleSession, for: workspace)

		let result = try await service.buildSidebarIndex(
			AgentSessionSidebarBuildRequest(
				workspace: workspace,
				tabNameByID: [
					explicitTabID: "Explicit Tab",
					staleTabID: "Stale Tab"
				],
				validTabIDs: [explicitTabID, staleTabID],
				boundSessionIDByTabID: [explicitTabID: sessionID]
			)
		)

		XCTAssertEqual(result.preferredSessionIDByTabID[explicitTabID], sessionID)
		XCTAssertNil(result.preferredSessionIDByTabID[staleTabID])
		XCTAssertEqual(result.entriesBySessionID[sessionID]?.tabID, explicitTabID)
		XCTAssertEqual(result.entriesBySessionID[sessionID]?.name, "Explicit Tab")
	}

	func testLoadColdRestoredSessionSanitizesOrphanedActiveTranscriptState() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "ColdRestoreSanitizesActiveState", root: tempRoot)
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let userDate = Date(timeIntervalSince1970: 100)
		let runDate = Date(timeIntervalSince1970: 110)
		let runID = UUID()
		let activeToolInvocationID = UUID()
		let completedToolInvocationID = UUID()

		let request = AgentTranscriptRequestAnchor(
			from: AgentChatItem(timestamp: userDate, kind: .user, text: "restore me", sequenceIndex: 0)
		)
		let pendingToolCall = AgentTranscriptActivity(
			from: AgentChatItem.toolCall(name: "bash", invocationID: activeToolInvocationID, argsJSON: #"{"cmd":"sleep 100"}"#, sequenceIndex: 1),
			toolExecution: AgentTranscriptToolExecution(
				stableExecutionID: "active-tool",
				toolName: "bash",
				invocationID: activeToolInvocationID,
				argsJSON: #"{"cmd":"sleep 100"}"#,
				resultJSON: nil,
				toolIsError: nil,
				status: .pending
			)
		)
		let runningToolResult = AgentTranscriptActivity(
			from: AgentChatItem.toolResult(
				name: "bash",
				invocationID: activeToolInvocationID,
				resultJSON: #"{"status":"running","process_id":"123"}"#,
				isError: false,
				sequenceIndex: 2
			),
			toolExecution: AgentTranscriptToolExecution(
				stableExecutionID: "active-tool",
				toolName: "bash",
				invocationID: activeToolInvocationID,
				argsJSON: #"{"cmd":"sleep 100"}"#,
				resultJSON: #"{"status":"running","process_id":"123"}"#,
				toolIsError: false,
				status: .running,
				processID: "123"
			)
		)
		let completedToolCall = AgentTranscriptActivity(
			from: AgentChatItem.toolCall(name: "read_file", invocationID: completedToolInvocationID, argsJSON: #"{"path":"done.swift"}"#, sequenceIndex: 3),
			toolExecution: AgentTranscriptToolExecution(
				stableExecutionID: "completed-tool",
				toolName: "read_file",
				invocationID: completedToolInvocationID,
				argsJSON: #"{"path":"done.swift"}"#,
				resultJSON: nil,
				toolIsError: nil,
				status: .pending
			)
		)
		let completedToolResult = AgentTranscriptActivity(
			from: AgentChatItem.toolResult(
				name: "read_file",
				invocationID: completedToolInvocationID,
				resultJSON: #"{"status":"success"}"#,
				isError: false,
				sequenceIndex: 4
			),
			toolExecution: AgentTranscriptToolExecution(
				stableExecutionID: "completed-tool",
				toolName: "read_file",
				invocationID: completedToolInvocationID,
				argsJSON: #"{"path":"done.swift"}"#,
				resultJSON: #"{"status":"success"}"#,
				toolIsError: false,
				status: .success
			)
		)
		var streamingThought = AgentTranscriptActivity(
			from: AgentChatItem(timestamp: runDate, kind: .thinking, text: "Thinking…", sequenceIndex: 5)
		)
		streamingThought.isStreaming = true
		var streamingAssistant = AgentTranscriptActivity(
			from: AgentChatItem.assistant("partial answer", sequenceIndex: 6, isStreaming: true)
		)
		streamingAssistant.isStreaming = true
		let span = AgentTranscriptProviderResponseSpan(
			id: UUID(),
			runID: runID,
			lifecycle: .open,
			startedAt: runDate,
			lastActivityAt: runDate,
			completedAt: nil,
			activities: [
				pendingToolCall,
				runningToolResult,
				completedToolCall,
				completedToolResult,
				streamingThought,
				streamingAssistant
			]
		)
		let turn = AgentTranscriptTurn(
			id: request.id,
			request: request,
			responseSpans: [span],
			terminalState: .running,
			startedAt: userDate,
			lastActivityAt: runDate,
			completedAt: nil
		)
		let rawTranscript = AgentTranscript(turns: [turn], nextSequenceIndex: 7)
		let rawSession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Cold Restore",
			items: [],
			transcript: rawTranscript,
			lastRunState: AgentSessionRunState.running.rawValue
		)
		let agentSessionsFolder = tempRoot.appendingPathComponent("AgentSessions", isDirectory: true)
		try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
		let fileURL = agentSessionsFolder.appendingPathComponent("AgentSession-\(rawSession.id.uuidString).json")
		try JSONEncoder().encode(rawSession).write(to: fileURL, options: .atomic)

		let loaded = try await service.loadAgentSession(from: fileURL)
		let loadedTurn = try XCTUnwrap(loaded.transcript?.turns.first)
		let loadedSpan = try XCTUnwrap(loadedTurn.responseSpans.first)
		let loadedActivities = loadedSpan.activities
		let loadedToolExecutions = loadedActivities.compactMap(\.toolExecution)
		let rewrittenSession = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
		let rewrittenTurn = try XCTUnwrap(rewrittenSession.transcript?.turns.first)
		let rewrittenSpan = try XCTUnwrap(rewrittenTurn.responseSpans.first)

		XCTAssertEqual(loaded.lastRunState, AgentSessionRunState.idle.rawValue)
		XCTAssertEqual(rewrittenSession.lastRunState, AgentSessionRunState.idle.rawValue)
		XCTAssertEqual(loadedTurn.terminalState, .cancelled)
		XCTAssertNotNil(loadedTurn.completedAt)
		XCTAssertEqual(loadedSpan.lifecycle, .cancelled)
		XCTAssertNotNil(loadedSpan.completedAt)
		XCTAssertFalse(loadedActivities.contains(where: \.isStreaming))
		XCTAssertFalse(loadedToolExecutions.contains(where: { $0.status == .pending || $0.status == .running }))
		XCTAssertEqual(loadedToolExecutions.filter { $0.stableExecutionID == "active-tool" }.map(\.status), [.cancelled, .cancelled])
		XCTAssertEqual(loadedToolExecutions.filter { $0.stableExecutionID == "completed-tool" }.last?.status, .success)
		XCTAssertTrue(loadedActivities.first(where: { $0.itemKind == .toolResult && $0.toolExecution?.stableExecutionID == "active-tool" })?.text.contains(#""status" : "cancelled""#) == true)
		XCTAssertEqual(rewrittenTurn.terminalState, .cancelled)
		XCTAssertEqual(rewrittenSpan.lifecycle, .cancelled)
	}

	func testRawCollapseFixtureAppendRebuildPreservesPreviousFullAssistantAcrossSteeringAppends() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "RawCollapseFixtureAppendRebuild", root: tempRoot)
		let fixtureSessionID = try XCTUnwrap(UUID(uuidString: "7B2A756D-C8E2-4A85-BF93-AB658BA0028D"))
		let service = AgentSessionDataService.shared

		let stagedFixture = try stageRawCollapseFixtureSession(in: tempRoot)
		let rawSession = stagedFixture.session
		XCTAssertEqual(rawSession.id, fixtureSessionID)
		XCTAssertTrue(rawSession.items.isEmpty, "Fixture shape changed; expected transcript-backed session with empty legacy items.")
		XCTAssertEqual(rawSession.transcript?.turns.count, 40)
		XCTAssertEqual(rawSession.transcript?.nextSequenceIndex, 328)

		let preparedPayload = try await service.preparePersistedHydration(
			AgentSessionHydrationRequest(
				workspace: workspace,
				tabID: rawSession.composeTabID ?? UUID(),
				sessionID: fixtureSessionID,
				resolvedDisplayName: rawSession.name,
				hasPendingQuestionUI: false,
				transcriptViewportState: .liveBottom,
				isCompressedHistoryRevealed: false,
				initialPerformanceSnapshot: .empty
			)
		)
		let payload = try XCTUnwrap(preparedPayload)
		XCTAssertEqual(payload.sessionID, fixtureSessionID)
		XCTAssertEqual(payload.transcript.turns.count, 40)
		XCTAssertEqual(payload.transcript.turns.filter { $0.retentionTier == .full }.count, 1)
		XCTAssertEqual(payload.restoredIndexEntry.itemCount, payload.builtPresentation.projectionCounts.canonicalVisibleRowCount)

		let sentinel = try finalFullSuffixAssistantSentinel(in: payload.transcript)
		let hydratedSentinel = try XCTUnwrap(
			payload.canonicalLiveItems.first { $0.id == sentinel.itemID },
			"Hydration payload should contain the final full-suffix assistant sentinel before append/rebuild."
		)
		XCTAssertEqual(hydratedSentinel.sequenceIndex, sentinel.sequenceIndex)
		XCTAssertEqual(hydratedSentinel.text, sentinel.text)

		let frozenPrefixCount = try XCTUnwrap(payload.transcript.compactionFrontier?.frozenPrefixTurnCount)
		XCTAssertEqual(frozenPrefixCount, 39)
		let initialFrozenPrefixIDs = payload.transcript.turns.prefix(frozenPrefixCount).map(\.id)
		let appendedUserID = try XCTUnwrap(UUID(uuidString: "9D10F60B-768E-44D3-AD09-D77DA6D02CB5"))
		let appendedUser = AgentChatItem(
			id: appendedUserID,
			timestamp: Date(timeIntervalSince1970: 10_000),
			kind: .user,
			text: "regression follow-up after restore",
			sequenceIndex: payload.transcript.nextSequenceIndex
		)
		let rebuiltTranscript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
			existingTranscript: payload.transcript,
			workingItems: payload.canonicalLiveItems + [appendedUser],
			terminalState: .running,
			nextSequenceIndex: appendedUser.sequenceIndex + 1,
			policy: .liveSession(hidePendingQuestionToolCall: false)
		)
		let rebuiltWorkingItems = AgentTranscriptIO.workingSourceItems(from: rebuiltTranscript)
		let rebuiltProjection = AgentTranscriptProjectionBuilder.build(from: rebuiltTranscript)

		let rebuiltUser = try XCTUnwrap(
			rebuiltWorkingItems.first { $0.id == appendedUserID },
			"Append/rebuild should keep the newly appended user row in the working source."
		)
		XCTAssertEqual(rebuiltUser.text, appendedUser.text)
		XCTAssertEqual(rebuiltUser.sequenceIndex, appendedUser.sequenceIndex)
		XCTAssertTrue(
			rebuiltProjection.workingRows.contains { $0.id == appendedUserID },
			"Projection should include the newly appended user row after rebuild."
		)
		XCTAssertEqual(
			rebuiltTranscript.turns.prefix(frozenPrefixCount).map(\.id),
			initialFrozenPrefixIDs,
			"Append/rebuild should preserve frozen prefix turn identity before checking the restored full suffix."
		)

		let rebuiltSentinelTurn = try XCTUnwrap(
			rebuiltTranscript.turns.first { $0.id == sentinel.turnID },
			"Append/rebuild should not drop the restored full-suffix turn containing assistant sentinel \(sentinel.itemID)."
		)
		guard rebuiltSentinelTurn.retentionTier == .full else {
			XCTFail("Appending a new active user turn should not immediately collapse the previously restored full-suffix assistant turn \(sentinel.turnID); actual tier was \(rebuiltSentinelTurn.retentionTier.rawValue), so old turns lose runtime detail before the agent responds.")
			return
		}
		let rebuiltSentinel = try XCTUnwrap(
			rebuiltWorkingItems.first { $0.id == sentinel.itemID },
			"Append/rebuild should preserve restored full-suffix assistant row \(sentinel.itemID) in working source while the new user turn is active."
		)
		XCTAssertEqual(rebuiltSentinel.sequenceIndex, sentinel.sequenceIndex)
		XCTAssertEqual(rebuiltSentinel.text, sentinel.text)

		let steeringUserID = try XCTUnwrap(UUID(uuidString: "8E526F68-6E82-44D9-8138-8D6493349F4E"))
		let steeringUser = AgentChatItem(
			id: steeringUserID,
			timestamp: Date(timeIntervalSince1970: 10_001),
			kind: .user,
			text: "regression steering follow-up",
			sequenceIndex: rebuiltTranscript.nextSequenceIndex
		)
		let rebuiltAfterSteeringTranscript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
			existingTranscript: rebuiltTranscript,
			workingItems: rebuiltWorkingItems + [steeringUser],
			terminalState: .running,
			nextSequenceIndex: steeringUser.sequenceIndex + 1,
			policy: .liveSession(hidePendingQuestionToolCall: false)
		)
		let finalWorkingItems = AgentTranscriptIO.workingSourceItems(from: rebuiltAfterSteeringTranscript)
		let finalProjection = AgentTranscriptProjectionBuilder.build(from: rebuiltAfterSteeringTranscript)
		let finalFirstUser = try XCTUnwrap(
			finalWorkingItems.first { $0.id == appendedUserID },
			"Second steering-style append should keep the first appended user row in the working source."
		)
		XCTAssertEqual(finalFirstUser.text, appendedUser.text)
		let finalSteeringUser = try XCTUnwrap(
			finalWorkingItems.first { $0.id == steeringUserID },
			"Second steering-style append should keep the new steering user row in the working source."
		)
		XCTAssertEqual(finalSteeringUser.text, steeringUser.text)
		XCTAssertEqual(finalSteeringUser.sequenceIndex, steeringUser.sequenceIndex)
		XCTAssertTrue(
			finalProjection.workingRows.contains { $0.id == appendedUserID }
				&& finalProjection.workingRows.contains { $0.id == steeringUserID },
			"Projection should include both appended user rows after the steering-style rebuild."
		)
		XCTAssertEqual(
			rebuiltAfterSteeringTranscript.turns.prefix(frozenPrefixCount).map(\.id),
			initialFrozenPrefixIDs,
			"Second steering-style append should preserve frozen prefix turn identity."
		)
		let finalSentinelTurn = try XCTUnwrap(
			rebuiltAfterSteeringTranscript.turns.first { $0.id == sentinel.turnID },
			"Second steering-style append should not drop the restored full-suffix turn containing assistant sentinel \(sentinel.itemID)."
		)
		XCTAssertEqual(
			finalSentinelTurn.retentionTier,
			.full,
			"Second steering-style append should keep restored full-suffix assistant turn \(sentinel.turnID) protected while the latest user turn is active."
		)
		let finalSentinel = try XCTUnwrap(
			finalWorkingItems.first { $0.id == sentinel.itemID },
			"Second steering-style append should preserve restored full-suffix assistant row \(sentinel.itemID) in working source."
		)
		XCTAssertEqual(finalSentinel.sequenceIndex, sentinel.sequenceIndex)
		XCTAssertEqual(finalSentinel.text, sentinel.text)
	}

	func testPreparePersistedHydrationBuildsRestorePayload() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "HydrationPayload", root: tempRoot)
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let userDate = Date(timeIntervalSince1970: 100)
		let assistantDate = Date(timeIntervalSince1970: 200)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Hydration Session",
			savedAt: Date(timeIntervalSince1970: 300),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: userDate, kind: .user, text: "hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: assistantDate, kind: .assistant, text: "hi", sequenceIndex: 1))
			],
			lastUserMessageAt: nil,
			agentKind: DiscoverAgentKind.claudeCode.rawValue,
			agentModel: AgentModel.defaultModel.rawValue,
			lastRunState: AgentSessionRunState.running.rawValue
		)

		_ = try await service.saveAgentSession(session, for: workspace)
		let preparedPayload = try await service.preparePersistedHydration(
			AgentSessionHydrationRequest(
				workspace: workspace,
				tabID: tabID,
				sessionID: session.id,
				resolvedDisplayName: "  Restored Tab  ",
				hasPendingQuestionUI: false,
				transcriptViewportState: .liveBottom,
				isCompressedHistoryRevealed: false,
				initialPerformanceSnapshot: .empty
			)
		)
		let payload = try XCTUnwrap(preparedPayload)

		XCTAssertEqual(payload.sessionID, session.id)
		XCTAssertEqual(payload.normalizedRunState, .idle)
		XCTAssertEqual(payload.persistedSession.lastRunState, AgentSessionRunState.idle.rawValue)
		XCTAssertEqual(payload.restoredIndexEntry.lastRunStateRaw, AgentSessionRunState.idle.rawValue)
		XCTAssertEqual(payload.normalizedSelection.agent, .claudeCode)
		XCTAssertEqual(payload.restoredIndexEntry.name, "Restored Tab")
		XCTAssertEqual(payload.canonicalLiveItems.count, 2)
		XCTAssertEqual(payload.lastUserMessageAt, userDate)
		XCTAssertEqual(payload.restoredIndexEntry.itemCount, payload.builtPresentation.projectionCounts.canonicalVisibleRowCount)
	}

	func testPreparePersistedHydrationPreservesCursorAutoSelectionAndProviderSessionIDWhenRegistryCold() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let workspace = makeWorkspace(name: "CursorHydrationPayload", root: tempRoot)
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let cursorProviderSessionID = "cursor-acp-session-123"
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Cursor Hydration Session",
			savedAt: Date(timeIntervalSince1970: 300),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 200), kind: .assistant, text: "hi", sequenceIndex: 1))
			],
			lastUserMessageAt: nil,
			agentKind: DiscoverAgentKind.cursor.rawValue,
			agentModel: AgentModel.cursorAuto.rawValue,
			lastRunState: AgentSessionRunState.completed.rawValue,
			providerSessionID: cursorProviderSessionID
		)

		_ = try await service.saveAgentSession(session, for: workspace)
		let preparedPayload = try await service.preparePersistedHydration(
			AgentSessionHydrationRequest(
				workspace: workspace,
				tabID: tabID,
				sessionID: session.id,
				resolvedDisplayName: "Cursor Restored Tab",
				hasPendingQuestionUI: false,
				transcriptViewportState: .liveBottom,
				isCompressedHistoryRevealed: false,
				initialPerformanceSnapshot: .empty
			)
		)
		let payload = try XCTUnwrap(preparedPayload)

		XCTAssertEqual(payload.normalizedSelection.agent, .cursor)
		XCTAssertNotEqual(payload.normalizedSelection.agent, .codexExec)
		XCTAssertEqual(payload.normalizedSelection.modelRaw, AgentModel.cursorAuto.rawValue)
		XCTAssertEqual(
			AgentModelSelectionID(
				agentRaw: payload.normalizedSelection.agent.rawValue,
				modelRaw: payload.normalizedSelection.modelRaw
			).rawValue,
			"cursor:auto"
		)
		XCTAssertEqual(payload.persistedSession.providerSessionID, cursorProviderSessionID)
	}
	
	private func rawCollapseFixtureURL() -> URL {
		let testFileURL = URL(fileURLWithPath: #filePath, isDirectory: false)
		return testFileURL
			.deletingLastPathComponent()
			.appendingPathComponent("Fixtures")
			.appendingPathComponent("AgentSessions")
			.appendingPathComponent("transcript-collapse-fanout-cursor-cli-docs-update-7B2A756D.json")
	}

	private func stageRawCollapseFixtureSession(in tempRoot: URL) throws -> (session: AgentSession, fileURL: URL) {
		let fixtureURL = rawCollapseFixtureURL()
		let data = try Data(contentsOf: fixtureURL)
		let session = try JSONDecoder().decode(AgentSession.self, from: data)
		let agentSessionsFolder = tempRoot.appendingPathComponent("AgentSessions", isDirectory: true)
		try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
		let fileURL = agentSessionsFolder.appendingPathComponent("AgentSession-\(session.id.uuidString).json")
		if FileManager.default.fileExists(atPath: fileURL.path) {
			try FileManager.default.removeItem(at: fileURL)
		}
		try FileManager.default.copyItem(at: fixtureURL, to: fileURL)
		return (session, fileURL)
	}

	private struct FullSuffixAssistantSentinel {
		let turnID: UUID
		let itemID: UUID
		let sequenceIndex: Int
		let text: String
	}

	private func finalFullSuffixAssistantSentinel(in transcript: AgentTranscript) throws -> FullSuffixAssistantSentinel {
		let fullTurns = transcript.turns.filter { $0.retentionTier == .full }
		let fullTurn = try XCTUnwrap(fullTurns.last, "Fixture should hydrate with a full-detail suffix turn.")
		let assistantActivities = fullTurn.allActivities.filter { activity in
			(activity.itemKind == .assistant || activity.itemKind == .assistantInline)
				&& !activity.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		}
		let sentinelActivity = try XCTUnwrap(
			assistantActivities.last { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 500 },
			"Fixture should retain a substantial assistant row in the final full suffix; assistant lengths: \(assistantActivities.map { $0.text.count })"
		)
		return FullSuffixAssistantSentinel(
			turnID: fullTurn.id,
			itemID: sentinelActivity.id,
			sequenceIndex: sentinelActivity.sequenceIndex,
			text: sentinelActivity.text
		)
	}

	private func makeLegacyTranscriptItems(turnCount: Int) -> [AgentChatItem] {
		var items: [AgentChatItem] = []
		var sequenceIndex = 0
		for turnIndex in 0..<turnCount {
			items.append(AgentChatItem.user("user \(turnIndex)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolCall(name: "get_file_tree", argsJSON: "{\"path\":\"src/\(turnIndex)\"}", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolResult(
				name: "get_file_tree",
				invocationID: nil,
				resultJSON: #"{"status":"completed"}"#,
				isError: false,
				sequenceIndex: sequenceIndex
			))
			sequenceIndex += 1
			items.append(AgentChatItem.assistant("assistant \(turnIndex)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		return items
	}

	private func makeWorkspace(name: String, root: URL) -> WorkspaceModel {
		WorkspaceModel(
			name: name,
			repoPaths: [],
			customStoragePath: root
		)
	}

	private func metadataIndexURL(root: URL) -> URL {
		root
			.appendingPathComponent("AgentSessions", isDirectory: true)
			.appendingPathComponent("AgentSessionIndex.json")
	}

	private func loadMetadataIndex(root: URL) throws -> AgentSessionMetadataIndex {
		try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(contentsOf: metadataIndexURL(root: root)))
	}
	
	private func makeTempDirectory() -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("RepoPrompt-AgentSessionDataServiceTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}
}
