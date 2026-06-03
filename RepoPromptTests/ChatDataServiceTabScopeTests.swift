import XCTest
@testable import RepoPrompt

final class ChatDataServiceTabScopeTests: XCTestCase {
	private func makeWorkspace(storageURL: URL) -> WorkspaceModel {
		WorkspaceModel(
			name: "ChatDataServiceTabScopeTests",
			repoPaths: [],
			customStoragePath: storageURL,
			ephemeralFlag: true
		)
	}

	private func makeSession(name: String, workspaceID: UUID, tabID: UUID) -> ChatSession {
		ChatSession(
			id: UUID(),
			workspaceID: workspaceID,
			composeTabID: tabID,
			name: name,
			savedAt: Date(),
			fileURL: nil,
			messages: [
				StoredMessage(isUser: true, rawText: "hello", sequenceIndex: 0),
				StoredMessage(isUser: false, rawText: "world", sequenceIndex: 1)
			],
			changedFilesByMessage: nil,
			delegateEditItemsByMessage: nil,
			selectedFilePaths: ["file.swift"],
			selectedPromptIDs: []
		)
	}

	private func saveSession(
		_ session: ChatSession,
		to workspace: WorkspaceModel,
		at date: Date,
		chatData: ChatDataService
	) async throws -> URL {
		let fileURL = try await chatData.saveChatSession(session, for: workspace)
		try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
		return fileURL
	}

	func testRecentSessionsFiltersByTabBeforeApplyingLimit() async throws {
		let chatData = ChatDataService()
		let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let workspace = makeWorkspace(storageURL: rootURL)
		let tabA = UUID()
		let tabB = UUID()
		let now = Date()

		let newestOverall = makeSession(name: "Newest Overall", workspaceID: workspace.id, tabID: tabA)
		let newestForTabB = makeSession(name: "Newest For Tab B", workspaceID: workspace.id, tabID: tabB)
		let olderForTabB = makeSession(name: "Older For Tab B", workspaceID: workspace.id, tabID: tabB)

		_ = try await saveSession(olderForTabB, to: workspace, at: now.addingTimeInterval(-120), chatData: chatData)
		_ = try await saveSession(newestForTabB, to: workspace, at: now.addingTimeInterval(-60), chatData: chatData)
		_ = try await saveSession(newestOverall, to: workspace, at: now, chatData: chatData)

		let scoped = try await chatData.recentSessions(for: workspace, limit: 1, composeTabID: tabB)
		XCTAssertEqual(scoped.count, 1)
		XCTAssertEqual(scoped.first?.id, newestForTabB.id)
		XCTAssertEqual(scoped.first?.composeTabID, tabB)
	}

	func testFindSessionResolvesShortIDWithinTabScope() async throws {
		let chatData = ChatDataService()
		let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let workspace = makeWorkspace(storageURL: rootURL)
		let tabA = UUID()
		let tabB = UUID()
		let now = Date()

		let tabASession = makeSession(name: "Alpha", workspaceID: workspace.id, tabID: tabA)
		let tabBSession = makeSession(name: "Beta", workspaceID: workspace.id, tabID: tabB)

		_ = try await saveSession(tabASession, to: workspace, at: now.addingTimeInterval(-60), chatData: chatData)
		_ = try await saveSession(tabBSession, to: workspace, at: now, chatData: chatData)

		let resolved = try await chatData.findSession(for: workspace, id: tabBSession.shortID, composeTabID: tabB)
		XCTAssertEqual(resolved?.id, tabBSession.id)

		let filteredOut = try await chatData.findSession(for: workspace, id: tabBSession.shortID, composeTabID: tabA)
		XCTAssertNil(filteredOut)
	}
}
