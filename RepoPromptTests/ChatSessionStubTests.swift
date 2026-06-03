import XCTest
@testable import RepoPrompt

final class ChatSessionStubTests: XCTestCase {
	func testListStubDropsHeavyFields() throws {
		let msg1 = StoredMessage(isUser: true, rawText: "Hello", sequenceIndex: 0)
		let msg2 = StoredMessage(isUser: false, rawText: "Hi back", sequenceIndex: 1)
		let session = ChatSession(
			id: UUID(),
			workspaceID: UUID(),
			name: "Test",
			savedAt: Date(),
			fileURL: URL(fileURLWithPath: "/tmp/ChatSession-test.json"),
			messages: [msg1, msg2],
			changedFilesByMessage: [msg2.id: [
				ChangedFileState(relativePath: "a.txt", originalContent: "a", finalContent: "b", action: "modify")
			]],
			delegateEditItemsByMessage: [msg2.id: [
				DelegateEditItemPersist(filePath: "a.txt", changes: [], status: .completed)
			]],
			selectedFilePaths: ["a.txt"],
			selectedPromptIDs: []
		)

		let stub = session.listStub()
		XCTAssertTrue(stub.messages.isEmpty)
		XCTAssertEqual(stub.effectiveMessageCount, 2)
		XCTAssertNotNil(stub.messageCount)
		XCTAssertNil(stub.changedFilesByMessage)
		XCTAssertNil(stub.delegateEditItemsByMessage)
	}

	func testIsListStubReturnsTrueForStubSessions() throws {
		let msg1 = StoredMessage(isUser: true, rawText: "Hello", sequenceIndex: 0)
		let msg2 = StoredMessage(isUser: false, rawText: "Hi back", sequenceIndex: 1)
		let fullSession = ChatSession(
			id: UUID(),
			workspaceID: UUID(),
			name: "Test",
			savedAt: Date(),
			fileURL: URL(fileURLWithPath: "/tmp/ChatSession-test.json"),
			messages: [msg1, msg2],
			changedFilesByMessage: [msg2.id: []],
			delegateEditItemsByMessage: [msg2.id: []],
			selectedFilePaths: ["a.txt"],
			selectedPromptIDs: []
		)

		// Full session is NOT a stub
		XCTAssertFalse(fullSession.isListStub)

		// Stub IS a stub
		let stub = fullSession.listStub()
		XCTAssertTrue(stub.isListStub)

		// A session with messages but nil messageCount is NOT a stub
		let sessionWithMessages = ChatSession(
			id: UUID(),
			workspaceID: UUID(),
			name: "Test",
			messages: [msg1],
			messageCount: nil
		)
		XCTAssertFalse(sessionWithMessages.isListStub)

		// A session with empty messages but nil messageCount is NOT a stub
		let emptySession = ChatSession(
			id: UUID(),
			workspaceID: UUID(),
			name: "Test",
			messages: [],
			messageCount: nil
		)
		XCTAssertFalse(emptySession.isListStub)
	}

	func testLoadChatSessionStubReturnsLightweightSession() async throws {
		let id = UUID()
		let wsID = UUID()

		let session = ChatSession(
			id: id,
			workspaceID: wsID,
			name: "Stub Load",
			savedAt: Date(),
			fileURL: nil,
			messages: [
				StoredMessage(isUser: true, rawText: "Hello", sequenceIndex: 0),
				StoredMessage(isUser: false, rawText: String(repeating: "x", count: 10_000), sequenceIndex: 1)
			],
			changedFilesByMessage: nil,
			delegateEditItemsByMessage: nil,
			selectedFilePaths: ["a.swift", "b.swift"],
			selectedPromptIDs: [],
			preferredAIModel: "test-model",
			selectedChatPresetID: UUID()
		)

		let encoder = JSONEncoder()
		let data = try encoder.encode(session)

		let tmpDir = FileManager.default.temporaryDirectory
		let fileURL = tmpDir.appendingPathComponent("ChatSession-\(id.uuidString).json")
		try data.write(to: fileURL, options: .atomic)
		defer { try? FileManager.default.removeItem(at: fileURL) }

		let chatData = ChatDataService()
		let stub = try await chatData.loadChatSessionStub(from: fileURL)

		XCTAssertEqual(stub.id, session.id)
		XCTAssertEqual(stub.workspaceID, session.workspaceID)
		XCTAssertEqual(stub.name, session.name)
		XCTAssertEqual(stub.fileURL, fileURL)
		XCTAssertTrue(stub.messages.isEmpty)
		XCTAssertEqual(stub.effectiveMessageCount, session.messages.count)
		XCTAssertEqual(stub.selectedFilePaths, session.selectedFilePaths)
		XCTAssertEqual(stub.preferredAIModel, session.preferredAIModel)
		XCTAssertEqual(stub.selectedChatPresetID, session.selectedChatPresetID)
	}

	func testBatchLoadChatSessionStubsPreservesInputOrderAndSkipsFailures() async throws {
		let tempDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ChatSessionStubBatchTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempDirectory) }

		func makeSession(name: String, messageCount: Int) -> ChatSession {
			ChatSession(
				id: UUID(),
				workspaceID: UUID(),
				name: name,
				savedAt: Date(),
				fileURL: nil,
				messages: (0..<messageCount).map { index in
					StoredMessage(isUser: index.isMultiple(of: 2), rawText: "Message \(index)", sequenceIndex: index)
				},
				selectedFilePaths: ["\(name).swift"],
				selectedPromptIDs: []
			)
		}

		func writeSession(_ session: ChatSession) throws -> URL {
			let url = tempDirectory.appendingPathComponent("ChatSession-\(session.id.uuidString).json")
			try JSONEncoder().encode(session).write(to: url, options: .atomic)
			return url
		}

		let first = makeSession(name: "First", messageCount: 1)
		let second = makeSession(name: "Second", messageCount: 2)
		let third = makeSession(name: "Third", messageCount: 3)

		let firstURL = try writeSession(first)
		let secondURL = try writeSession(second)
		let thirdURL = try writeSession(third)
		let corruptURL = tempDirectory.appendingPathComponent("ChatSession-\(UUID().uuidString).json")
		try Data("not-json".utf8).write(to: corruptURL, options: .atomic)

		let chatData = ChatDataService()
		let result = await chatData.loadChatSessionStubs(
			from: [secondURL, corruptURL, firstURL, thirdURL],
			maxConcurrent: 2
		)

		XCTAssertEqual(result.requestedCount, 4)
		XCTAssertEqual(result.loadedCount, 3)
		XCTAssertEqual(result.failedCount, 1)
		XCTAssertEqual(result.sessions.map(\.id), [second.id, first.id, third.id])
		XCTAssertEqual(result.sessions.map(\.name), ["Second", "First", "Third"])
		XCTAssertTrue(result.sessions.allSatisfy(\.isListStub))
		XCTAssertEqual(result.failures.first?.index, 1)
		XCTAssertEqual(result.failures.first?.fileURL, corruptURL)
	}
}

