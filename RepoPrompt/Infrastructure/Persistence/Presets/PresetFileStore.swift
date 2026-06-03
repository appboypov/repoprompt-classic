import Foundation

/// File-backed store for copy/chat/model presets.
///
/// Primary location:
/// `~/Library/Application Support/RepoPrompt/Presets/workflowPresets.json`
/// `~/Library/Application Support/RepoPrompt/Presets/modelPresets.json`
///
/// During the rollback window, saves also mirror the legacy UserDefaults keys
/// that older builds use for preset persistence.
final class PresetFileStore {
	static let shared = PresetFileStore()

	static let appSupportDirectoryName = "RepoPrompt"
	static let presetsDirectoryName = "Presets"
	static let workflowFilename = "workflowPresets.json"
	static let modelFilename = "modelPresets.json"
	static let currentSchemaVersion = 1

	static let copyPresetsLegacyKey = "copyPresetsV1"
	static let copyVisibilityLegacyKey = "copyPresetVisibility"
	static let copyOverridesLegacyKey = "copyPresetOverridesV1"
	static let chatPresetsLegacyKey = "chatPresetsV1"
	static let chatVisibilityLegacyKey = "chatPresetVisibility"
	static let chatOverridesLegacyKey = "chatPresetOverridesV1"
	static let modelPresetsLegacyKey = "modelPresets"
	static let modelPresetsBackupLegacyKey = "modelPresets_corrupt_backup"
	static let modelPresetsMigrationLegacyKey = "modelPresets_migrated_v2"
	static let workflowShadowHashKey = "presetFileStoreJSON.shadowHash.workflowV1"
	static let modelShadowHashKey = "presetFileStoreJSON.shadowHash.modelV1"
	private static let workflowLegacyKeys = [
		copyPresetsLegacyKey,
		copyVisibilityLegacyKey,
		copyOverridesLegacyKey,
		chatPresetsLegacyKey,
		chatVisibilityLegacyKey,
		chatOverridesLegacyKey
	]

	let workflowFileURL: URL
	let modelFileURL: URL

	private let fileManager: FileManager
	private let now: () -> Date
	private var preservingUnsupportedFutureWorkflowDocument = false
	private var preservingUnsupportedFutureModelDocument = false

	init(
		workflowFileURL: URL = PresetFileStore.defaultWorkflowFileURL(),
		modelFileURL: URL = PresetFileStore.defaultModelFileURL(),
		fileManager: FileManager = .default,
		now: @escaping () -> Date = Date.init
	) {
		self.workflowFileURL = workflowFileURL
		self.modelFileURL = modelFileURL
		self.fileManager = fileManager
		self.now = now
	}

	static func defaultWorkflowFileURL(fileManager: FileManager = .default) -> URL {
		presetsDirectoryURL(fileManager: fileManager)
			.appendingPathComponent(workflowFilename)
	}

	static func defaultModelFileURL(fileManager: FileManager = .default) -> URL {
		presetsDirectoryURL(fileManager: fileManager)
			.appendingPathComponent(modelFilename)
	}

	static func presetsDirectoryURL(fileManager: FileManager = .default) -> URL {
		let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first!
		return supportDirectory
			.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
			.appendingPathComponent(presetsDirectoryName, isDirectory: true)
	}

	// MARK: - Workflow Presets

	func loadWorkflowPresets(defaults: UserDefaults = .standard) -> WorkflowPresetDocument {
		preservingUnsupportedFutureWorkflowDocument = false
		if fileManager.fileExists(atPath: workflowFileURL.path) {
			do {
				let document = try loadWorkflowDocument()
				if shouldReimportWorkflowLegacyMirrors(defaults: defaults) {
					let migrated = workflowDocumentFromLegacy(defaults: defaults)
					saveWorkflowPresets(migrated, defaults: defaults)
					return migrated
				}
				writeWorkflowLegacyMirrors(document, defaults: defaults, updateShadow: true)
				return document
			} catch PresetFileStoreError.unsupportedFutureSchema(let version) {
				preservingUnsupportedFutureWorkflowDocument = true
				print("⚠️ Workflow presets JSON schema v\(version) is newer than supported v\(Self.currentSchemaVersion); preserving file and using legacy mirrors for this launch.")
				return workflowDocumentFromLegacy(defaults: defaults)
			} catch {
				backupCorruptFile(at: workflowFileURL, prefix: "workflowPresets", error: error)
				let fallback = workflowDocumentFromLegacy(defaults: defaults)
				saveWorkflowPresets(fallback, defaults: defaults)
				return fallback
			}
		}

		let migrated = workflowDocumentFromLegacy(defaults: defaults)
		saveWorkflowPresets(migrated, defaults: defaults)
		return migrated
	}

	func updateWorkflowPresets(
		defaults: UserDefaults = .standard,
		_ mutation: (inout WorkflowPresetDocument) -> Void
	) {
		var document = loadWorkflowPresets(defaults: defaults)
		mutation(&document)
		saveWorkflowPresets(document, defaults: defaults)
	}

	func saveWorkflowPresets(_ document: WorkflowPresetDocument, defaults: UserDefaults = .standard) {
		var documentToWrite = document
		documentToWrite.schemaVersion = Self.currentSchemaVersion
		documentToWrite.updatedAt = now()
		if preservingUnsupportedFutureWorkflowDocument {
			writeWorkflowLegacyMirrors(documentToWrite, defaults: defaults, updateShadow: false)
			return
		}

		let didSaveJSON: Bool
		do {
			try ensurePresetDirectoryExists(for: workflowFileURL)
			let data = try Self.fileEncoder.encode(documentToWrite)
			try data.write(to: workflowFileURL, options: .atomic)
			didSaveJSON = true
		} catch {
			didSaveJSON = false
			print("⚠️ Failed to save workflow presets JSON at \(workflowFileURL.path): \(error)")
		}
		writeWorkflowLegacyMirrors(documentToWrite, defaults: defaults, updateShadow: didSaveJSON)
	}

	func loadWorkflowDocument() throws -> WorkflowPresetDocument {
		let data = try Data(contentsOf: workflowFileURL)
		let header = try Self.fileDecoder.decode(DocumentHeader.self, from: data)
		guard header.schemaVersion <= Self.currentSchemaVersion else {
			throw PresetFileStoreError.unsupportedFutureSchema(header.schemaVersion)
		}
		return try Self.fileDecoder.decode(WorkflowPresetDocument.self, from: data)
	}

	// MARK: - Model Presets

	func loadModelPresets(defaults: UserDefaults = .standard) -> ModelPresetDocument {
		preservingUnsupportedFutureModelDocument = false
		if fileManager.fileExists(atPath: modelFileURL.path) {
			do {
				let document = try loadModelDocument()
				if shouldReimportModelLegacyMirrors(defaults: defaults) {
					let migrated = modelDocumentFromLegacy(defaults: defaults)
					saveModelPresets(migrated, defaults: defaults)
					return migrated
				}
				writeModelLegacyMirrors(document.modelPresets, defaults: defaults, updateShadow: true)
				return document
			} catch PresetFileStoreError.unsupportedFutureSchema(let version) {
				preservingUnsupportedFutureModelDocument = true
				print("⚠️ Model presets JSON schema v\(version) is newer than supported v\(Self.currentSchemaVersion); preserving file and using legacy mirrors for this launch.")
				return modelDocumentFromLegacy(defaults: defaults)
			} catch {
				backupCorruptFile(at: modelFileURL, prefix: "modelPresets", error: error)
				let fallback = modelDocumentFromLegacy(defaults: defaults)
				saveModelPresets(fallback, defaults: defaults)
				return fallback
			}
		}

		let migrated = modelDocumentFromLegacy(defaults: defaults)
		saveModelPresets(migrated, defaults: defaults)
		return migrated
	}

	func saveModelPresets(_ document: ModelPresetDocument, defaults: UserDefaults = .standard) {
		var documentToWrite = document
		documentToWrite.schemaVersion = Self.currentSchemaVersion
		documentToWrite.updatedAt = now()
		if preservingUnsupportedFutureModelDocument {
			writeModelLegacyMirrors(documentToWrite.modelPresets, defaults: defaults, updateShadow: false)
			return
		}

		let didSaveJSON: Bool
		do {
			try ensurePresetDirectoryExists(for: modelFileURL)
			let data = try Self.fileEncoder.encode(documentToWrite)
			try data.write(to: modelFileURL, options: .atomic)
			didSaveJSON = true
		} catch {
			didSaveJSON = false
			print("⚠️ Failed to save model presets JSON at \(modelFileURL.path): \(error)")
		}
		writeModelLegacyMirrors(documentToWrite.modelPresets, defaults: defaults, updateShadow: didSaveJSON)
	}

	func loadModelDocument() throws -> ModelPresetDocument {
		let data = try Data(contentsOf: modelFileURL)
		let header = try Self.fileDecoder.decode(DocumentHeader.self, from: data)
		guard header.schemaVersion <= Self.currentSchemaVersion else {
			throw PresetFileStoreError.unsupportedFutureSchema(header.schemaVersion)
		}
		return try Self.fileDecoder.decode(ModelPresetDocument.self, from: data)
	}

	// MARK: - Legacy Migration

	func workflowDocumentFromLegacy(defaults: UserDefaults = .standard) -> WorkflowPresetDocument {
		WorkflowPresetDocument(
			updatedAt: now(),
			copyUserPresets: decodeLegacyArray(CopyPreset.self, key: Self.copyPresetsLegacyKey, defaults: defaults),
			copyVisibility: decodeLegacy([UUID: Bool].self, key: Self.copyVisibilityLegacyKey, defaults: defaults, backupOnFailure: true) ?? [:],
			copyOverrides: decodeLegacyArray(CopyPresetOverrides.self, key: Self.copyOverridesLegacyKey, defaults: defaults),
			chatUserPresets: decodeLegacyArray(ChatPreset.self, key: Self.chatPresetsLegacyKey, defaults: defaults),
			chatVisibility: decodeLegacy([UUID: Bool].self, key: Self.chatVisibilityLegacyKey, defaults: defaults, backupOnFailure: true) ?? [:],
			chatOverrides: decodeLegacyArray(ChatPresetOverrides.self, key: Self.chatOverridesLegacyKey, defaults: defaults)
		)
	}

	func modelDocumentFromLegacy(defaults: UserDefaults = .standard) -> ModelPresetDocument {
		ModelPresetDocument(
			updatedAt: now(),
			modelPresets: legacyModelPresets(defaults: defaults)
		)
	}

	func writeWorkflowLegacyMirrors(
		_ document: WorkflowPresetDocument,
		defaults: UserDefaults = .standard,
		updateShadow: Bool = true
	) {
		encodeLegacyAndSet(document.copyUserPresets, key: Self.copyPresetsLegacyKey, defaults: defaults)
		encodeLegacyAndSet(document.copyVisibility, key: Self.copyVisibilityLegacyKey, defaults: defaults)
		encodeLegacyAndSet(document.copyOverrides, key: Self.copyOverridesLegacyKey, defaults: defaults)
		encodeLegacyAndSet(document.chatUserPresets, key: Self.chatPresetsLegacyKey, defaults: defaults)
		encodeLegacyAndSet(document.chatVisibility, key: Self.chatVisibilityLegacyKey, defaults: defaults)
		encodeLegacyAndSet(document.chatOverrides, key: Self.chatOverridesLegacyKey, defaults: defaults)
		if updateShadow {
			markCurrentWorkflowMirrorsAsShadowed(defaults: defaults)
		}
	}

	func writeModelLegacyMirrors(
		_ presets: [ModelPreset],
		defaults: UserDefaults = .standard,
		updateShadow: Bool = true
	) {
		encodeLegacyAndSet(presets, key: Self.modelPresetsLegacyKey, defaults: defaults)
		defaults.set(true, forKey: Self.modelPresetsMigrationLegacyKey)
		if updateShadow {
			markCurrentModelMirrorsAsShadowed(defaults: defaults)
		}
	}

	private func legacyModelPresets(defaults: UserDefaults) -> [ModelPreset] {
		var presets: [ModelPreset] = []

		if !defaults.bool(forKey: Self.modelPresetsMigrationLegacyKey),
			let backupData = defaults.data(forKey: Self.modelPresetsBackupLegacyKey),
			let recovered = try? Self.legacyDecoder.decode([FailableDecodable<ModelPreset>].self, from: backupData) {
			presets = recovered.compactMap(\.value)
			if !presets.isEmpty {
				writeModelLegacyMirrors(presets, defaults: defaults)
				print("[PresetFileStore] Recovered \(presets.count) model presets from legacy backup")
			}
		}
		defaults.set(true, forKey: Self.modelPresetsMigrationLegacyKey)

		guard let data = defaults.data(forKey: Self.modelPresetsLegacyKey) else {
			return presets
		}

		do {
			return try Self.legacyDecoder.decode([ModelPreset].self, from: data)
		} catch {
			if let partial = try? Self.legacyDecoder.decode([FailableDecodable<ModelPreset>].self, from: data) {
				let recovered = partial.compactMap(\.value)
				defaults.set(data, forKey: Self.modelPresetsBackupLegacyKey)
				print("[PresetFileStore] Partially recovered \(recovered.count) model presets from corrupted legacy data")
				if !recovered.isEmpty {
					writeModelLegacyMirrors(recovered, defaults: defaults)
				}
				return recovered
			}

			defaults.set(data, forKey: Self.modelPresetsBackupLegacyKey)
			print("[PresetFileStore] Failed to decode legacy model presets, saved backup: \(error)")
			return []
		}
	}

	private func shouldReimportWorkflowLegacyMirrors(defaults: UserDefaults) -> Bool {
		guard hasAnyWorkflowLegacyMirror(defaults: defaults),
			let shadowHash = defaults.string(forKey: Self.workflowShadowHashKey)
		else {
			return false
		}
		return currentWorkflowLegacyHash(defaults: defaults) != shadowHash
	}

	private func shouldReimportModelLegacyMirrors(defaults: UserDefaults) -> Bool {
		guard defaults.data(forKey: Self.modelPresetsLegacyKey) != nil,
			let shadowHash = defaults.string(forKey: Self.modelShadowHashKey)
		else {
			return false
		}
		return currentModelLegacyHash(defaults: defaults) != shadowHash
	}

	private func markCurrentWorkflowMirrorsAsShadowed(defaults: UserDefaults) {
		defaults.set(currentWorkflowLegacyHash(defaults: defaults), forKey: Self.workflowShadowHashKey)
	}

	private func markCurrentModelMirrorsAsShadowed(defaults: UserDefaults) {
		defaults.set(currentModelLegacyHash(defaults: defaults), forKey: Self.modelShadowHashKey)
	}

	private func hasAnyWorkflowLegacyMirror(defaults: UserDefaults) -> Bool {
		Self.workflowLegacyKeys.contains { defaults.data(forKey: $0) != nil }
	}

	private func currentWorkflowLegacyHash(defaults: UserDefaults) -> String {
		legacyHash(for: Self.workflowLegacyKeys, defaults: defaults)
	}

	private func currentModelLegacyHash(defaults: UserDefaults) -> String {
		legacyHash(for: [Self.modelPresetsLegacyKey], defaults: defaults)
	}

	private func legacyHash(for keys: [String], defaults: UserDefaults) -> String {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for key in keys.sorted() {
			append(key.data(using: .utf8) ?? Data(), to: &hash)
			append(Data([0]), to: &hash)
			append(defaults.data(forKey: key) ?? Data(), to: &hash)
			append(Data([255]), to: &hash)
		}
		return String(hash, radix: 16)
	}

	private func append(_ data: Data, to hash: inout UInt64) {
		for byte in data {
			hash ^= UInt64(byte)
			hash &*= 1_099_511_628_211
		}
	}

	private func decodeLegacy<Value: Decodable>(
		_ type: Value.Type,
		key: String,
		defaults: UserDefaults,
		backupOnFailure: Bool = false
	) -> Value? {
		guard let data = defaults.data(forKey: key) else { return nil }
		do {
			return try Self.legacyDecoder.decode(type, from: data)
		} catch {
			if backupOnFailure {
				backupCorruptLegacyData(data, key: key, defaults: defaults)
			}
			print("⚠️ Failed to decode legacy preset key \(key): \(error)")
			return nil
		}
	}

	private func decodeLegacyArray<Element: Decodable>(
		_ elementType: Element.Type,
		key: String,
		defaults: UserDefaults
	) -> [Element] {
		guard let data = defaults.data(forKey: key) else { return [] }
		do {
			return try Self.legacyDecoder.decode([Element].self, from: data)
		} catch {
			backupCorruptLegacyData(data, key: key, defaults: defaults)
			if let partial = try? Self.legacyDecoder.decode([FailableDecodable<Element>].self, from: data) {
				let recovered = partial.compactMap(\.value)
				print("[PresetFileStore] Partially recovered \(recovered.count) entries from corrupted legacy preset key \(key)")
				return recovered
			}
			print("⚠️ Failed to decode legacy preset key \(key): \(error)")
			return []
		}
	}

	private func backupCorruptLegacyData(_ data: Data, key: String, defaults: UserDefaults) {
		defaults.set(data, forKey: "\(key)_corrupt_backup")
	}

	private func encodeLegacyAndSet<Value: Encodable>(_ value: Value, key: String, defaults: UserDefaults) {
		do {
			let data = try Self.legacyEncoder.encode(value)
			defaults.set(data, forKey: key)
		} catch {
			print("⚠️ Failed to encode legacy preset key \(key): \(error)")
		}
	}

	// MARK: - Files

	private func ensurePresetDirectoryExists(for fileURL: URL) throws {
		try fileManager.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
	}

	private func backupCorruptFile(at fileURL: URL, prefix: String, error: Error) {
		do {
			let backupDirectory = fileURL
				.deletingLastPathComponent()
				.appendingPathComponent("Backups", isDirectory: true)
			try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

			var backupURL = backupDirectory
				.appendingPathComponent("\(prefix).corrupt-\(Self.backupTimestamp(for: now())).json")
			if fileManager.fileExists(atPath: backupURL.path) {
				backupURL = backupDirectory
					.appendingPathComponent("\(prefix).corrupt-\(Self.backupTimestamp(for: now()))-\(UUID().uuidString).json")
			}

			do {
				try fileManager.moveItem(at: fileURL, to: backupURL)
			} catch {
				try fileManager.copyItem(at: fileURL, to: backupURL)
				try? fileManager.removeItem(at: fileURL)
			}
			print("⚠️ Backed up corrupt preset JSON to \(backupURL.path): \(error)")
		} catch {
			print("⚠️ Failed to back up corrupt preset JSON at \(fileURL.path): \(error)")
		}
	}

	private static func backupTimestamp(for date: Date) -> String {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter.string(from: date)
			.replacingOccurrences(of: ":", with: "-")
	}

	private struct DocumentHeader: Decodable {
		let schemaVersion: Int
	}

	enum PresetFileStoreError: Error, Equatable {
		case unsupportedFutureSchema(Int)
	}

	private struct FailableDecodable<T: Decodable>: Decodable {
		let value: T?

		init(from decoder: Decoder) throws {
			value = try? T(from: decoder)
		}
	}

	private static let fileEncoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		return encoder
	}()

	private static let fileDecoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}()

	private static let legacyEncoder = JSONEncoder()
	private static let legacyDecoder = JSONDecoder()
}

extension PresetFileStore {
	struct WorkflowPresetDocument: Codable, Equatable {
		var schemaVersion: Int
		var updatedAt: Date
		var copyUserPresets: [CopyPreset]
		var copyVisibilityByPresetID: [String: Bool]
		var copyOverrides: [CopyPresetOverrides]
		var chatUserPresets: [ChatPreset]
		var chatVisibilityByPresetID: [String: Bool]
		var chatOverrides: [ChatPresetOverrides]

		init(
			schemaVersion: Int = PresetFileStore.currentSchemaVersion,
			updatedAt: Date = Date(),
			copyUserPresets: [CopyPreset] = [],
			copyVisibility: [UUID: Bool] = [:],
			copyOverrides: [CopyPresetOverrides] = [],
			chatUserPresets: [ChatPreset] = [],
			chatVisibility: [UUID: Bool] = [:],
			chatOverrides: [ChatPresetOverrides] = []
		) {
			self.schemaVersion = schemaVersion
			self.updatedAt = updatedAt
			self.copyUserPresets = copyUserPresets
			self.copyVisibilityByPresetID = PresetFileStore.encodeUUIDKeyedDictionary(copyVisibility)
			self.copyOverrides = copyOverrides
			self.chatUserPresets = chatUserPresets
			self.chatVisibilityByPresetID = PresetFileStore.encodeUUIDKeyedDictionary(chatVisibility)
			self.chatOverrides = chatOverrides
		}

		var copyVisibility: [UUID: Bool] {
			get { PresetFileStore.decodeUUIDKeyedDictionary(copyVisibilityByPresetID) }
			set { copyVisibilityByPresetID = PresetFileStore.encodeUUIDKeyedDictionary(newValue) }
		}

		var chatVisibility: [UUID: Bool] {
			get { PresetFileStore.decodeUUIDKeyedDictionary(chatVisibilityByPresetID) }
			set { chatVisibilityByPresetID = PresetFileStore.encodeUUIDKeyedDictionary(newValue) }
		}
	}

	struct ModelPresetDocument: Codable, Equatable {
		var schemaVersion: Int
		var updatedAt: Date
		var modelPresets: [ModelPreset]

		init(
			schemaVersion: Int = PresetFileStore.currentSchemaVersion,
			updatedAt: Date = Date(),
			modelPresets: [ModelPreset] = []
		) {
			self.schemaVersion = schemaVersion
			self.updatedAt = updatedAt
			self.modelPresets = modelPresets
		}
	}

	private static func encodeUUIDKeyedDictionary<Value>(_ values: [UUID: Value]) -> [String: Value] {
		values.reduce(into: [String: Value]()) { result, entry in
			result[entry.key.uuidString] = entry.value
		}
	}

	private static func decodeUUIDKeyedDictionary<Value>(_ values: [String: Value]) -> [UUID: Value] {
		values.reduce(into: [UUID: Value]()) { result, entry in
			guard let uuid = UUID(uuidString: entry.key) else { return }
			result[uuid] = entry.value
		}
	}
}
