import XCTest
@testable import RepoPrompt

final class PresetFileStoreMigrationTests: XCTestCase {
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

	func testDefaultPathsUseRepoPromptPresetsDirectory() {
		let workflowPath = PresetFileStore.defaultWorkflowFileURL().path
		let modelPath = PresetFileStore.defaultModelFileURL().path

		XCTAssertTrue(
			workflowPath.hasSuffix("Application Support/RepoPrompt/Presets/workflowPresets.json"),
			"Unexpected workflow presets path: \(workflowPath)"
		)
		XCTAssertTrue(
			modelPath.hasSuffix("Application Support/RepoPrompt/Presets/modelPresets.json"),
			"Unexpected model presets path: \(modelPath)"
		)
	}

	func testWorkflowPresetsMigrateFromLegacyUserDefaultsAndWriteJSON() throws {
		let defaults = makeUserDefaults()
		let copyPresetID = UUID()
		let chatPresetID = UUID()
		let copyPreset = CopyPreset(id: copyPresetID, name: "Migrated Copy", isBuiltIn: false, includeFiles: true)
		let chatPreset = ChatPreset(id: chatPresetID, name: "Migrated Chat", mode: .chat, isBuiltIn: false, gitInclusion: .selected)
		var copyOverride = CopyPresetOverrides.empty(for: BuiltInCopyPresets.standard.id)
		copyOverride.includeFileTree = true
		var chatOverride = ChatPresetOverrides.empty(for: ChatPreset.BuiltIn.chat.id)
		chatOverride.modelPresetName = "FastModel"
		writeLegacy([copyPreset], key: PresetFileStore.copyPresetsLegacyKey, defaults: defaults)
		writeLegacy([copyPresetID: false], key: PresetFileStore.copyVisibilityLegacyKey, defaults: defaults)
		writeLegacy([copyOverride], key: PresetFileStore.copyOverridesLegacyKey, defaults: defaults)
		writeLegacy([chatPreset], key: PresetFileStore.chatPresetsLegacyKey, defaults: defaults)
		writeLegacy([chatPresetID: false], key: PresetFileStore.chatVisibilityLegacyKey, defaults: defaults)
		writeLegacy([chatOverride], key: PresetFileStore.chatOverridesLegacyKey, defaults: defaults)
		let store = try makeStore()

		let document = store.loadWorkflowPresets(defaults: defaults)

		XCTAssertEqual(document.schemaVersion, PresetFileStore.currentSchemaVersion)
		XCTAssertEqual(document.copyUserPresets, [copyPreset])
		XCTAssertEqual(document.copyVisibility[copyPresetID], false)
		XCTAssertEqual(document.copyOverrides.first?.includeFileTree, true)
		XCTAssertEqual(document.chatUserPresets, [chatPreset])
		XCTAssertEqual(document.chatVisibility[chatPresetID], false)
		XCTAssertEqual(document.chatOverrides.first?.modelPresetName, "FastModel")
		XCTAssertTrue(FileManager.default.fileExists(atPath: store.workflowFileURL.path))

		let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.workflowFileURL)) as? [String: Any])
		XCTAssertEqual(json["schemaVersion"] as? Int, PresetFileStore.currentSchemaVersion)
		XCTAssertNotNil(json["updatedAt"] as? String)
		let copyVisibility = try XCTUnwrap(json["copyVisibilityByPresetID"] as? [String: Any])
		XCTAssertEqual(copyVisibility[copyPresetID.uuidString] as? Bool, false)
	}

	func testSavingWorkflowPresetsDualWritesLegacyUserDefaults() throws {
		let defaults = makeUserDefaults()
		let copyPresetID = UUID()
		let chatPresetID = UUID()
		let copyPreset = CopyPreset(id: copyPresetID, name: "Saved Copy", isBuiltIn: false, includeUserPrompt: true)
		let chatPreset = ChatPreset(id: chatPresetID, name: "Saved Chat", mode: .review, isBuiltIn: false, gitInclusion: .complete)
		var document = PresetFileStore.WorkflowPresetDocument(
			copyUserPresets: [copyPreset],
			copyVisibility: [copyPresetID: false],
			chatUserPresets: [chatPreset],
			chatVisibility: [chatPresetID: true]
		)
		var copyOverride = CopyPresetOverrides.empty(for: BuiltInCopyPresets.standard.id)
		copyOverride.includeMCPMetadata = true
		document.copyOverrides = [copyOverride]
		var chatOverride = ChatPresetOverrides.empty(for: ChatPreset.BuiltIn.reviewUUID)
		chatOverride.useStoredPromptsAsSystem = false
		document.chatOverrides = [chatOverride]
		let store = try makeStore()

		store.saveWorkflowPresets(document, defaults: defaults)

		let loaded = try store.loadWorkflowDocument()
		XCTAssertEqual(loaded.copyUserPresets, [copyPreset])
		XCTAssertEqual(loaded.chatUserPresets, [chatPreset])
		XCTAssertEqual(readLegacy([CopyPreset].self, key: PresetFileStore.copyPresetsLegacyKey, defaults: defaults), [copyPreset])
		XCTAssertEqual(readLegacy([UUID: Bool].self, key: PresetFileStore.copyVisibilityLegacyKey, defaults: defaults)?[copyPresetID], false)
		XCTAssertEqual(readLegacy([CopyPresetOverrides].self, key: PresetFileStore.copyOverridesLegacyKey, defaults: defaults)?.first?.includeMCPMetadata, true)
		XCTAssertEqual(readLegacy([ChatPreset].self, key: PresetFileStore.chatPresetsLegacyKey, defaults: defaults), [chatPreset])
		XCTAssertEqual(readLegacy([UUID: Bool].self, key: PresetFileStore.chatVisibilityLegacyKey, defaults: defaults)?[chatPresetID], true)
		XCTAssertEqual(readLegacy([ChatPresetOverrides].self, key: PresetFileStore.chatOverridesLegacyKey, defaults: defaults)?.first?.useStoredPromptsAsSystem, false)
	}

	func testExistingWorkflowJSONReimportsLegacyMirrorsChangedByRollbackBuild() throws {
		let defaults = makeUserDefaults()
		let originalPreset = CopyPreset(name: "Original JSON", isBuiltIn: false, includeFiles: true)
		let rollbackPreset = CopyPreset(name: "Rollback Edit", isBuiltIn: false, includeFiles: false)
		let store = try makeStore()
		store.saveWorkflowPresets(
			PresetFileStore.WorkflowPresetDocument(copyUserPresets: [originalPreset]),
			defaults: defaults
		)
		writeLegacy([rollbackPreset], key: PresetFileStore.copyPresetsLegacyKey, defaults: defaults)

		let document = store.loadWorkflowPresets(defaults: defaults)

		XCTAssertEqual(document.copyUserPresets, [rollbackPreset])
		XCTAssertEqual(try store.loadWorkflowDocument().copyUserPresets, [rollbackPreset])
	}

	func testExistingModelJSONReimportsLegacyMirrorsChangedByRollbackBuild() throws {
		let defaults = makeUserDefaults()
		let originalPreset = ModelPreset(name: "OriginalModel", model: .gpt4o)
		let rollbackPreset = ModelPreset(name: "RollbackModel", model: .claude4Sonnet)
		let store = try makeStore()
		store.saveModelPresets(
			PresetFileStore.ModelPresetDocument(modelPresets: [originalPreset]),
			defaults: defaults
		)
		writeLegacy([rollbackPreset], key: PresetFileStore.modelPresetsLegacyKey, defaults: defaults)

		let document = store.loadModelPresets(defaults: defaults)

		XCTAssertEqual(document.modelPresets, [rollbackPreset])
		XCTAssertEqual(try store.loadModelDocument().modelPresets, [rollbackPreset])
	}

	func testCorruptWorkflowJSONBacksUpAndFallsBackToLegacyUserDefaults() throws {
		let defaults = makeUserDefaults()
		let copyPreset = CopyPreset(name: "Legacy After Corruption", isBuiltIn: false, includeFiles: false)
		writeLegacy([copyPreset], key: PresetFileStore.copyPresetsLegacyKey, defaults: defaults)
		let store = try makeStore()
		try FileManager.default.createDirectory(at: store.workflowFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("{ not valid json".utf8).write(to: store.workflowFileURL)

		let document = store.loadWorkflowPresets(defaults: defaults)

		XCTAssertEqual(document.copyUserPresets, [copyPreset])
		let backupDirectory = store.workflowFileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
		let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
		XCTAssertEqual(backups.count, 1)
		XCTAssertTrue(backups[0].lastPathComponent.hasPrefix("workflowPresets.corrupt-"))
		let freshDocument = try store.loadWorkflowDocument()
		XCTAssertEqual(freshDocument.copyUserPresets, [copyPreset])
	}

	func testCorruptLegacyWorkflowPresetArrayIsBackedUpAndPartiallyRecovered() throws {
		let defaults = makeUserDefaults()
		let validPreset = CopyPreset(name: "Recoverable Copy", isBuiltIn: false, includeFiles: true)
		let validObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(validPreset)) as? [String: Any])
		let corruptArrayData = try JSONSerialization.data(withJSONObject: [validObject, ["id": "not-a-uuid"]])
		defaults.set(corruptArrayData, forKey: PresetFileStore.copyPresetsLegacyKey)
		let store = try makeStore()

		let document = store.loadWorkflowPresets(defaults: defaults)

		XCTAssertEqual(document.copyUserPresets, [validPreset])
		XCTAssertEqual(defaults.data(forKey: "\(PresetFileStore.copyPresetsLegacyKey)_corrupt_backup"), corruptArrayData)
		XCTAssertEqual(readLegacy([CopyPreset].self, key: PresetFileStore.copyPresetsLegacyKey, defaults: defaults), [validPreset])
	}

	func testModelPresetsMigrateFromLegacyUserDefaultsAndDualWrite() throws {
		let defaults = makeUserDefaults()
		let migratedPreset = ModelPreset(name: "MigratedModel", model: .gpt4o, description: "Legacy")
		writeLegacy([migratedPreset], key: PresetFileStore.modelPresetsLegacyKey, defaults: defaults)
		let store = try makeStore()

		let document = store.loadModelPresets(defaults: defaults)

		XCTAssertEqual(document.schemaVersion, PresetFileStore.currentSchemaVersion)
		XCTAssertEqual(document.modelPresets, [migratedPreset])
		XCTAssertTrue(FileManager.default.fileExists(atPath: store.modelFileURL.path))

		let savedPreset = ModelPreset(name: "SavedModel", model: .claude4Sonnet)
		store.saveModelPresets(PresetFileStore.ModelPresetDocument(modelPresets: [savedPreset]), defaults: defaults)

		XCTAssertEqual(try store.loadModelDocument().modelPresets, [savedPreset])
		XCTAssertEqual(readLegacy([ModelPreset].self, key: PresetFileStore.modelPresetsLegacyKey, defaults: defaults), [savedPreset])
		XCTAssertTrue(defaults.bool(forKey: PresetFileStore.modelPresetsMigrationLegacyKey))
	}

	func testCorruptLegacyModelPresetsAreBackedUpAndPartiallyRecovered() throws {
		let defaults = makeUserDefaults()
		let validPreset = ModelPreset(name: "Recoverable", model: .gpt4o)
		let validObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(validPreset)) as? [String: Any])
		let corruptArrayData = try JSONSerialization.data(withJSONObject: [validObject, ["id": "not-a-uuid"]])
		defaults.set(corruptArrayData, forKey: PresetFileStore.modelPresetsLegacyKey)
		let store = try makeStore()

		let document = store.loadModelPresets(defaults: defaults)

		XCTAssertEqual(document.modelPresets, [validPreset])
		XCTAssertEqual(defaults.data(forKey: PresetFileStore.modelPresetsBackupLegacyKey), corruptArrayData)
		XCTAssertEqual(readLegacy([ModelPreset].self, key: PresetFileStore.modelPresetsLegacyKey, defaults: defaults), [validPreset])
	}

	private func makeStore() throws -> PresetFileStore {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-PresetFileStoreMigrationTests-\(UUID().uuidString)", isDirectory: true)
		temporaryDirectories.append(directory)
		return PresetFileStore(
			workflowFileURL: directory
				.appendingPathComponent("Presets", isDirectory: true)
				.appendingPathComponent("workflowPresets.json"),
			modelFileURL: directory
				.appendingPathComponent("Presets", isDirectory: true)
				.appendingPathComponent("modelPresets.json"),
			now: { Date(timeIntervalSince1970: 1_700_000_000) }
		)
	}

	private func makeUserDefaults() -> UserDefaults {
		let suite = "RepoPrompt.PresetFileStoreMigrationTests.\(UUID().uuidString)"
		userDefaultsSuites.append(suite)
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}

	private func writeLegacy<Value: Encodable>(_ value: Value, key: String, defaults: UserDefaults) {
		let data = try! JSONEncoder().encode(value)
		defaults.set(data, forKey: key)
	}

	private func readLegacy<Value: Decodable>(_ type: Value.Type, key: String, defaults: UserDefaults) -> Value? {
		guard let data = defaults.data(forKey: key) else { return nil }
		return try? JSONDecoder().decode(type, from: data)
	}
}
