import Foundation

protocol GlobalSettingsFileStoring {
	var fileURL: URL { get }

	func load() throws -> GlobalSettingsDocument
	func loadOrMigrate(defaults: UserDefaults) -> GlobalSettingsDocument
	func save(_ document: GlobalSettingsDocument) throws
}

/// File-backed store for the versioned global settings document.
///
/// Primary location:
/// `~/Library/Application Support/RepoPrompt/Settings/globalSettings.json`
final class GlobalSettingsFileStore: GlobalSettingsFileStoring {
	static let appSupportDirectoryName = "RepoPrompt"
	static let settingsDirectoryName = "Settings"
	static let filename = "globalSettings.json"

	let fileURL: URL
	private let fileManager: FileManager
	private let now: () -> Date
	private var preservingUnsupportedFutureDocument = false

	init(
		fileURL: URL = GlobalSettingsFileStore.defaultFileURL(),
		fileManager: FileManager = .default,
		now: @escaping () -> Date = Date.init
	) {
		self.fileURL = fileURL
		self.fileManager = fileManager
		self.now = now
	}

	static func defaultFileURL(fileManager: FileManager = .default) -> URL {
		settingsDirectoryURL(fileManager: fileManager)
			.appendingPathComponent(filename)
	}

	static func settingsDirectoryURL(fileManager: FileManager = .default) -> URL {
		let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first!
		return supportDirectory
			.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
			.appendingPathComponent(settingsDirectoryName, isDirectory: true)
	}

	func load() throws -> GlobalSettingsDocument {
		let data = try Data(contentsOf: fileURL)
		let header = try Self.decoder.decode(GlobalSettingsDocumentHeader.self, from: data)
		guard header.schemaVersion <= GlobalSettingsDocument.currentSchemaVersion else {
			throw GlobalSettingsFileStoreError.unsupportedFutureSchema(header.schemaVersion)
		}
		return try Self.decoder.decode(GlobalSettingsDocument.self, from: data)
	}

	func loadOrMigrate(defaults: UserDefaults = .standard) -> GlobalSettingsDocument {
		preservingUnsupportedFutureDocument = false
		if fileManager.fileExists(atPath: fileURL.path) {
			do {
				let loaded = try load()
				var document = loaded
				var shouldPersistMigratedDocument = false

				if GlobalSettingsLegacyBridge.shouldReimportLegacyMirrors(defaults: defaults) {
					var legacyDocument = GlobalSettingsLegacyBridge.document(from: defaults, updatedAt: now())
					legacyDocument.scalarPreferences = GlobalSettingsLegacyBridge.scalarPreferences(
						from: defaults,
						preservingModelSelectionFrom: loaded.scalarPreferences
					).preferences
					document = legacyDocument
					shouldPersistMigratedDocument = true
				} else if GlobalSettingsLegacyBridge.hasAnyLegacyBlob(defaults: defaults) &&
					defaults.string(forKey: GlobalSettingsLegacyBridge.coreShadowHashKey) == nil {
					GlobalSettingsLegacyBridge.markCurrentCoreMirrorsAsShadowed(defaults: defaults)
				}

				if GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults) {
					document.scalarPreferences = GlobalSettingsLegacyBridge.scalarPreferences(
						from: defaults,
						preservingModelSelectionFrom: document.scalarPreferences
					).preferences
					shouldPersistMigratedDocument = true
				} else if document.schemaVersion < 2 || document.scalarPreferences == nil {
					document.scalarPreferences = GlobalSettingsLegacyBridge.scalarPreferences(
						from: defaults,
						preservingModelSelectionFrom: document.scalarPreferences
					).preferences
					shouldPersistMigratedDocument = true
				} else if GlobalSettingsLegacyBridge.hasAnyScalarPreference(defaults: defaults) &&
					defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey) == nil {
					// During the rollback window, legacy @AppStorage/UserDefaults call sites can still be
					// live writers for scalar preferences. Preserve explicit JSON-backed model selections
					// so stale legacy scalar keys cannot reset GPT-5.5 choices.
					document.scalarPreferences = GlobalSettingsLegacyBridge.scalarPreferences(
						from: defaults,
						preservingModelSelectionFrom: document.scalarPreferences
					).preferences
					shouldPersistMigratedDocument = true
				}

				if loaded.schemaVersion < 3 {
					shouldPersistMigratedDocument = forceRespectGitignoreEnabledForSchemaV3(
						in: &document,
						defaults: defaults
					) || shouldPersistMigratedDocument
				}

				if document.schemaVersion < GlobalSettingsDocument.currentSchemaVersion {
					document.schemaVersion = GlobalSettingsDocument.currentSchemaVersion
					shouldPersistMigratedDocument = true
				}

				if shouldPersistMigratedDocument {
					writeFallbackDocument(document, updateLegacyShadow: true, defaults: defaults)
				}
				return document
			} catch GlobalSettingsFileStoreError.unsupportedFutureSchema(let version) {
				preservingUnsupportedFutureDocument = true
				print("⚠️ Global settings JSON schema v\(version) is newer than supported v\(GlobalSettingsDocument.currentSchemaVersion); preserving file and using legacy mirrors for this launch.")
				return GlobalSettingsLegacyBridge.document(from: defaults, updatedAt: now())
			} catch {
				backupCorruptFile(error: error)
				var fallback = GlobalSettingsLegacyBridge.document(from: defaults, updatedAt: now())
				forceRespectGitignoreEnabledForSchemaV3(in: &fallback, defaults: defaults)
				writeFallbackDocument(fallback, updateLegacyShadow: true, defaults: defaults)
				return fallback
			}
		}

		var migrated = GlobalSettingsLegacyBridge.document(from: defaults, updatedAt: now())
		forceRespectGitignoreEnabledForSchemaV3(in: &migrated, defaults: defaults)
		writeFallbackDocument(migrated, updateLegacyShadow: true, defaults: defaults)
		return migrated
	}

	func save(_ document: GlobalSettingsDocument) throws {
		guard !preservingUnsupportedFutureDocument else {
			throw GlobalSettingsFileStoreError.unsupportedFutureSchemaPreserved
		}
		try ensureSettingsDirectoryExists()
		var documentToWrite = document
		documentToWrite.schemaVersion = max(document.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
		documentToWrite.updatedAt = now()
		let data = try Self.encoder.encode(documentToWrite)
		try data.write(to: fileURL, options: .atomic)
	}

	@discardableResult
	private func forceRespectGitignoreEnabledForSchemaV3(
		in document: inout GlobalSettingsDocument,
		defaults: UserDefaults
	) -> Bool {
		var changed = false
		var scalarPreferences = document.scalarPreferences ?? GlobalScalarPreferences()
		var fileSystemSettings = scalarPreferences.fileSystem ?? GlobalScalarPreferences.FileSystemSettings()
		if fileSystemSettings.respectGitignore != true {
			fileSystemSettings.respectGitignore = true
			scalarPreferences.fileSystem = fileSystemSettings
			document.scalarPreferences = scalarPreferences
			changed = true
		}
		if defaults.object(forKey: GlobalSettingsLegacyBridge.respectGitignoreKey) as? Bool != true {
			defaults.set(true, forKey: GlobalSettingsLegacyBridge.respectGitignoreKey)
			changed = true
		}
		return changed
	}

	private func writeFallbackDocument(
		_ document: GlobalSettingsDocument,
		updateLegacyShadow: Bool = false,
		defaults: UserDefaults = .standard
	) {
		do {
			try save(document)
			if updateLegacyShadow {
				GlobalSettingsLegacyBridge.markCurrentMirrorsAsShadowed(defaults: defaults)
			}
		} catch {
			print("⚠️ Failed to write global settings JSON at \(fileURL.path): \(error)")
		}
	}

	private func ensureSettingsDirectoryExists() throws {
		try fileManager.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
	}

	private func backupCorruptFile(error: Error) {
		do {
			let backupDirectory = fileURL
				.deletingLastPathComponent()
				.appendingPathComponent("Backups", isDirectory: true)
			try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

			var backupURL = backupDirectory
				.appendingPathComponent("globalSettings.corrupt-\(Self.backupTimestamp(for: now())).json")
			if fileManager.fileExists(atPath: backupURL.path) {
				backupURL = backupDirectory
					.appendingPathComponent("globalSettings.corrupt-\(Self.backupTimestamp(for: now()))-\(UUID().uuidString).json")
			}

			do {
				try fileManager.moveItem(at: fileURL, to: backupURL)
			} catch {
				try fileManager.copyItem(at: fileURL, to: backupURL)
				try? fileManager.removeItem(at: fileURL)
			}
			print("⚠️ Backed up corrupt global settings JSON to \(backupURL.path): \(error)")
		} catch {
			print("⚠️ Failed to back up corrupt global settings JSON at \(fileURL.path): \(error)")
		}
	}

	private static func backupTimestamp(for date: Date) -> String {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter.string(from: date)
			.replacingOccurrences(of: ":", with: "-")
	}

	private struct GlobalSettingsDocumentHeader: Decodable {
		let schemaVersion: Int
	}

	enum GlobalSettingsFileStoreError: Error, Equatable {
		case unsupportedFutureSchema(Int)
		case unsupportedFutureSchemaPreserved
	}

	private static let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		return encoder
	}()

	private static let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}()
}
