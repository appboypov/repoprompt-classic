import XCTest
@testable import RepoPrompt

final class GlobalSettingsFileStoreTests: XCTestCase {
	private var temporaryDirectories: [URL] = []
	private var userDefaultsSuites: [String] = []

	override func tearDownWithError() throws {
		for directory in temporaryDirectories {
			try? FileManager.default.removeItem(at: directory)
		}
		for suite in userDefaultsSuites {
			UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
		}
		temporaryDirectories = []
		userDefaultsSuites = []
		try super.tearDownWithError()
	}

	func testDefaultPathUsesRepoPromptSettingsGlobalSettingsJSON() {
		let path = GlobalSettingsFileStore.defaultFileURL().path
		XCTAssertTrue(
			path.hasSuffix("Application Support/RepoPrompt/Settings/globalSettings.json"),
			"Unexpected global settings path: \(path)"
		)
	}

	func testSaveAndLoadRoundTripsDocumentAtInjectedURL() throws {
		let fileURL = try makeTemporarySettingsFileURL()
		let workspaceID = UUID()
		var globalDefaults = GlobalDefaults(discoverAgentRaw: "codexExec", discoverModelsByAgent: ["codexExec": "gpt-5.4"])
		globalDefaults.codeMapsGloballyDisabled = true
		let store = GlobalSettingsFileStore(fileURL: fileURL, now: { Date(timeIntervalSince1970: 1_700_000_000) })
		let document = GlobalSettingsDocument(
			copySettings: [workspaceID: CopyGlobalSettings(workspaceID: workspaceID)],
			chatSettings: [workspaceID: ChatGlobalSettings(workspaceID: workspaceID)],
			globalDefaults: globalDefaults
		)

		try store.save(document)

		XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
		let loaded = try store.load()
		XCTAssertEqual(loaded.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
		XCTAssertEqual(loaded.copySettings[workspaceID]?.workspaceID, workspaceID)
		XCTAssertEqual(loaded.chatSettings[workspaceID]?.workspaceID, workspaceID)
		XCTAssertEqual(loaded.globalDefaults.discoverAgentRaw, "codexExec")
		XCTAssertEqual(loaded.globalDefaults.codeMapsGloballyDisabled, true)

		let json = try XCTUnwrap(
			JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
		)
		XCTAssertEqual(json["schemaVersion"] as? Int, GlobalSettingsDocument.currentSchemaVersion)
		XCTAssertNotNil(json["updatedAt"] as? String)
		let copySettingsByWorkspaceID = try XCTUnwrap(json["copySettingsByWorkspaceID"] as? [String: Any])
		XCTAssertNotNil(copySettingsByWorkspaceID[workspaceID.uuidString])
	}

	func testLoadOrMigrateBacksUpCorruptFileAndFallsBackToLegacyDefaults() throws {
		let defaults = makeUserDefaults()
		var globalDefaults = GlobalDefaults(discoverAgentRaw: "claudeCode", discoverModelsByAgent: ["claudeCode": "opus"])
		globalDefaults.codeMapsGloballyDisabled = true
		GlobalSettingsLegacyBridge.writeLegacyMirrors(
			copySettings: [:],
			chatSettings: [:],
			globalDefaults: globalDefaults,
			defaults: defaults
		)
		let fileURL = try makeTemporarySettingsFileURL()
		try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("{ not valid json".utf8).write(to: fileURL)
		let store = GlobalSettingsFileStore(fileURL: fileURL, now: { Date(timeIntervalSince1970: 1_700_000_000) })

		let migrated = store.loadOrMigrate(defaults: defaults)

		XCTAssertEqual(migrated.globalDefaults.discoverAgentRaw, "claudeCode")
		XCTAssertEqual(migrated.globalDefaults.codeMapsGloballyDisabled, true)
		let backupDirectory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
		let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
		XCTAssertEqual(backups.count, 1)
		XCTAssertTrue(backups[0].lastPathComponent.hasPrefix("globalSettings.corrupt-"))

		let freshDocument = try store.load()
		XCTAssertEqual(freshDocument.globalDefaults.discoverAgentRaw, "claudeCode")
	}

	func testUnsupportedFutureSchemaIsPreservedAndUsesLegacyFallback() throws {
		let defaults = makeUserDefaults()
		GlobalSettingsLegacyBridge.writeLegacyMirrors(
			copySettings: [:],
			chatSettings: [:],
			globalDefaults: GlobalDefaults(discoverAgentRaw: "codexExec", discoverModelsByAgent: ["codexExec": "gpt-5.4"]),
			defaults: defaults
		)
		let fileURL = try makeTemporarySettingsFileURL()
		try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let futureJSON = """
		{
		"schemaVersion": 999,
		"updatedAt": "2026-04-18T00:00:00Z",
		"copySettingsByWorkspaceID": {},
		"chatSettingsByWorkspaceID": {},
		"globalDefaults": {}
		}
		"""
		try Data(futureJSON.utf8).write(to: fileURL)
		let store = GlobalSettingsFileStore(fileURL: fileURL)

		let fallback = store.loadOrMigrate(defaults: defaults)

		XCTAssertEqual(fallback.globalDefaults.discoverAgentRaw, "codexExec")
		let preservedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		XCTAssertEqual(preservedJSON["schemaVersion"] as? Int, 999)
		XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().appendingPathComponent("Backups").path))
		XCTAssertThrowsError(try store.save(GlobalSettingsDocument()))
	}

	private func makeTemporarySettingsFileURL() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-GlobalSettingsFileStoreTests-\(UUID().uuidString)", isDirectory: true)
		temporaryDirectories.append(directory)
		return directory
			.appendingPathComponent("Settings", isDirectory: true)
			.appendingPathComponent("globalSettings.json")
	}

	private func makeUserDefaults() -> UserDefaults {
		let suite = "RepoPrompt.GlobalSettingsFileStoreTests.\(UUID().uuidString)"
		userDefaultsSuites.append(suite)
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}
}
