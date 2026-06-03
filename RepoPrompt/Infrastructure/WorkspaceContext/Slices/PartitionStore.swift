import Foundation
import CryptoKit

public enum SliceMutationMode: Sendable {
	case add
	case set
	case remove
	case setPaths  // file-scoped replacement: replace slices only for specified files
}

struct SliceAnchor: Codable, Sendable, Equatable {
	var range: LineRange
	var startSignature: [String]
	var endSignature: [String]

	init(
		range: LineRange,
		startSignature: [String] = [],
		endSignature: [String] = []
	) {
		self.range = range
		self.startSignature = startSignature
		self.endSignature = endSignature
	}
}

public struct PartitionScope: Sendable, Equatable {
	public let workspaceID: UUID
	public let tabID: UUID?

	public init(workspaceID: UUID, tabID: UUID? = nil) {
		self.workspaceID = workspaceID
		self.tabID = tabID
	}
}

actor PartitionStore {
	/// Posted **after** a successful save so other windows/tabs reload in-memory slices.
	static let didSaveNotification = Notification.Name("RepoPrompt.PartitionStoreDidSave")
	static let notifRootPathKey = "rootPath"
	static let notifWorkspaceIDKey = "workspaceID"
	static let notifTabIDKey = "tabID"
	static let notifSourceIDKey = "sourceID"
	nonisolated let notificationSourceID = UUID()

	/// <AppSupport>/RepoPrompt/Partitions
	private static func partitionsBaseURL() -> URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return base.appendingPathComponent("RepoPrompt/Partitions", isDirectory: true)
	}

	/// repoKey = "<leafName>-<sha256(stdPath)[0..12]>"
	private func repoKey(forRoot rootPath: String) -> String {
		let std = (rootPath as NSString).standardizingPath
		let leaf = (std as NSString).lastPathComponent
		let digest = SHA256.hash(data: Data(std.utf8))
		let hex = digest.map { String(format: "%02x", $0) }.joined()
		let short = String(hex.prefix(12))
		return "\(leaf)-\(short)"
	}

	struct StoredSlices: Codable, Sendable, Equatable {
		var ranges: [LineRange]
		var fileModificationTime: Double?
		var anchors: [SliceAnchor]?
		
		init(
			ranges: [LineRange],
			fileModificationTime: Double?,
			anchors: [SliceAnchor]? = nil
		) {
			self.ranges = ranges
			self.fileModificationTime = fileModificationTime
			self.anchors = anchors
		}
	}
	
	struct SliceUpdate: Sendable {
		var ranges: [LineRange]
		var fileModificationTime: Double?
		var anchors: [SliceAnchor]?

		init(
			ranges: [LineRange],
			fileModificationTime: Double?,
			anchors: [SliceAnchor]? = nil
		) {
			self.ranges = ranges
			self.fileModificationTime = fileModificationTime
			self.anchors = anchors
		}
	}
	
	struct PartitionData: Codable {
		var version: Int
		var files: [String: StoredSlices]
		var updatedAt: String?
		
		static func empty() -> PartitionData {
			PartitionData(version: 1, files: [:], updatedAt: nil)
		}
		
		init(version: Int, files: [String: StoredSlices], updatedAt: String?) {
			self.version = version
			self.files = files
			self.updatedAt = updatedAt
		}
		
		private enum CodingKeys: String, CodingKey {
			case version
			case files
			case updatedAt
		}
		
		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
			self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
			if let decoded = try? container.decode([String: StoredSlices].self, forKey: .files) {
				self.files = decoded
			} else {
				let legacy = try container.decode([String: [LineRange]].self, forKey: .files)
				self.files = legacy.mapValues { StoredSlices(ranges: $0, fileModificationTime: nil) }
			}
		}
		
		func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(version, forKey: .version)
			try container.encode(files, forKey: .files)
			try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
		}
	}
	
	private let encoder: JSONEncoder
	private let decoder: JSONDecoder
	private let dateFormatter = ISO8601DateFormatter()
	
	init() {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		self.encoder = encoder
		self.decoder = JSONDecoder()
	}
	
	func load(forRoot rootPath: String, scope: PartitionScope) async -> PartitionData {
		// 1) New primary (App Support) location
		let primaryURL = partitionURL(forRoot: rootPath, scope: scope)
		if let partition = loadPartition(at: primaryURL) {
			return partition
		}

		// 2) Legacy (repo-local) with tab id, if any
		let legacyTabURL = legacyLocalPartitionURL(forRoot: rootPath, scope: scope)
		if let legacyWithTab = loadPartition(at: legacyTabURL) {
			// Attempt migration to new location
			do {
				try await save(forRoot: rootPath, scope: scope, data: legacyWithTab)
				try? FileManager.default.removeItem(at: legacyTabURL)
			} catch {
				// Non-fatal; return legacy data
			}
			return legacyWithTab
		}

		// 3) Legacy (repo-local) without tab id
		let legacyNoTabURL = legacyPartitionURL(forRoot: rootPath, workspaceID: scope.workspaceID)
		if let legacy = loadPartition(at: legacyNoTabURL) {
			// Migrate under *matching legacy scope* (no tab)
			let targetScope = PartitionScope(workspaceID: scope.workspaceID) // no tab
			do {
				try await save(forRoot: rootPath, scope: targetScope, data: legacy)
				try? FileManager.default.removeItem(at: legacyNoTabURL)
			} catch {
				// Non-fatal; return legacy data
			}
			return legacy
		}

		return PartitionData.empty()
	}
	
	func save(forRoot rootPath: String, scope: PartitionScope, data: PartitionData) async throws {
		let url = partitionURL(forRoot: rootPath, scope: scope)

		// Ensure directories exist: .../Application Support/RepoPrompt/Partitions/<repoKey>/
		let dirURL = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

		var dataToPersist = data
		dataToPersist.updatedAt = dateFormatter.string(from: Date())

		let encoded = try encoder.encode(dataToPersist)
		try encoded.write(to: url, options: [.atomic])

		// Inform other windows/tabs within the process to reload slices for this scope
		postSaveNotification(rootPath: rootPath, scope: scope)

		// Remove stale legacy files if present (best-effort)
		purgeLegacyFiles(forRoot: rootPath, scope: scope)
	}
	
	/// High-level mutation helper that loads, mutates, persists, and returns the merged range map.
	/// Paths are expected to be standardized by the caller; ranges are normalized before persistence.
	@discardableResult
	func apply(
		forRoot rootPath: String,
		scope: PartitionScope,
		updates: [String: SliceUpdate],
		mode: SliceMutationMode
	) async throws -> [String: StoredSlices] {
		var data = await load(forRoot: rootPath, scope: scope)
		switch mode {
		case .set:
			var next: [String: StoredSlices] = [:]
			for (path, update) in updates {
				let ranges = update.ranges
				let normalized = SliceRangeMath.normalize(ranges)
				if !normalized.isEmpty {
					let normalizedAnchors = Self.sanitizedAnchors(update.anchors, for: normalized)
					next[path] = StoredSlices(
						ranges: normalized,
						fileModificationTime: update.fileModificationTime,
						anchors: normalizedAnchors
					)
				}
			}
			data.files = next

		case .setPaths:
			for (path, update) in updates {
				let normalized = SliceRangeMath.normalize(update.ranges)
				if normalized.isEmpty {
					data.files.removeValue(forKey: path)
					continue
				}
				let existing = data.files[path]
				let modTime = update.fileModificationTime ?? existing?.fileModificationTime
				let anchors = Self.resolvedAnchors(
					updateAnchors: update.anchors,
					existingAnchors: existing?.anchors,
					finalRanges: normalized
				)
				data.files[path] = StoredSlices(
					ranges: normalized,
					fileModificationTime: modTime,
					anchors: anchors
				)
			}
			
		case .add:
			for (path, update) in updates {
				let ranges = update.ranges
				let normalized = SliceRangeMath.normalize(ranges)
				guard !normalized.isEmpty else { continue }
				let existing = data.files[path] ?? StoredSlices(ranges: [], fileModificationTime: nil)
				let combined = SliceRangeMath.coalesce(existing.ranges, normalized)
				if combined.isEmpty {
					data.files.removeValue(forKey: path)
				} else {
					let modTime = update.fileModificationTime ?? existing.fileModificationTime
					let anchors = Self.mergedAnchors(
						updateAnchors: update.anchors,
						existingAnchors: existing.anchors,
						finalRanges: combined
					)
					data.files[path] = StoredSlices(
						ranges: combined,
						fileModificationTime: modTime,
						anchors: anchors
					)
				}
			}
			
		case .remove:
			for (path, update) in updates {
				guard let current = data.files[path] else { continue }
				let ranges = update.ranges
				let normalized = SliceRangeMath.normalize(ranges)
				if normalized.isEmpty {
					// Empty removal payload signals a full removal for this path.
					data.files.removeValue(forKey: path)
					continue
				}
				let remaining = SliceRangeMath.subtract(current.ranges, removing: normalized)
				if remaining.isEmpty {
					data.files.removeValue(forKey: path)
				} else {
					let anchors = Self.sanitizedAnchors(current.anchors, for: remaining)
					data.files[path] = StoredSlices(
						ranges: remaining,
						fileModificationTime: current.fileModificationTime,
						anchors: anchors
					)
				}
			}
		}
		
		try await save(forRoot: rootPath, scope: scope, data: data)
		return data.files
	}

	private static func sanitizedAnchors(
		_ anchors: [SliceAnchor]?,
		for ranges: [LineRange]
	) -> [SliceAnchor]? {
		guard let anchors, !anchors.isEmpty else { return nil }
		let normalizedRanges = SliceRangeMath.normalize(ranges)
		guard !normalizedRanges.isEmpty else { return nil }

		let allowed = Set(normalizedRanges.map { RangeKey(start: $0.start, end: $0.end) })
		let filtered = anchors.filter { anchor in
			allowed.contains(RangeKey(start: anchor.range.start, end: anchor.range.end))
		}
		return filtered.isEmpty ? nil : filtered
	}

	private static func mergedAnchors(
		updateAnchors: [SliceAnchor]?,
		existingAnchors: [SliceAnchor]?,
		finalRanges: [LineRange]
	) -> [SliceAnchor]? {
		var byRange: [RangeKey: SliceAnchor] = [:]

		if let sanitizedExisting = sanitizedAnchors(existingAnchors, for: finalRanges) {
			for anchor in sanitizedExisting {
				let key = RangeKey(start: anchor.range.start, end: anchor.range.end)
				byRange[key] = anchor
			}
		}

		if let sanitizedUpdate = sanitizedAnchors(updateAnchors, for: finalRanges) {
			for anchor in sanitizedUpdate {
				let key = RangeKey(start: anchor.range.start, end: anchor.range.end)
				byRange[key] = anchor
			}
		}

		guard !byRange.isEmpty else { return nil }
		return byRange
			.values
			.sorted {
				if $0.range.start == $1.range.start {
					return $0.range.end < $1.range.end
				}
				return $0.range.start < $1.range.start
			}
	}

	private static func resolvedAnchors(
		updateAnchors: [SliceAnchor]?,
		existingAnchors: [SliceAnchor]?,
		finalRanges: [LineRange]
	) -> [SliceAnchor]? {
		if let updateAnchors {
			return sanitizedAnchors(updateAnchors, for: finalRanges)
		}
		return sanitizedAnchors(existingAnchors, for: finalRanges)
	}

	private struct RangeKey: Hashable {
		let start: Int
		let end: Int
	}

	func load(forRoot rootPath: String, workspaceID: UUID) async -> PartitionData {
		await load(forRoot: rootPath, scope: PartitionScope(workspaceID: workspaceID))
	}
	
	func save(forRoot rootPath: String, workspaceID: UUID, data: PartitionData) async throws {
		try await save(forRoot: rootPath, scope: PartitionScope(workspaceID: workspaceID), data: data)
	}
	
	@discardableResult
	func apply(
		forRoot rootPath: String,
		workspaceID: UUID,
		updates: [String: SliceUpdate],
		mode: SliceMutationMode
	) async throws -> [String: StoredSlices] {
		try await apply(forRoot: rootPath, scope: PartitionScope(workspaceID: workspaceID), updates: updates, mode: mode)
	}

	/// Comprehensively migrates ALL partition files from legacy .repoprompt/ folder to Application Support.
	/// This should be called once when a root folder is first loaded.
	/// Returns the number of files migrated.
	@discardableResult
	func migrateAllLegacyPartitions(forRoot rootPath: String) async -> Int {
		let standardizedRoot = (rootPath as NSString).standardizingPath
		let directoryURL = URL(fileURLWithPath: standardizedRoot, isDirectory: true)
		let legacyFolderURL = directoryURL.appendingPathComponent(".repoprompt", isDirectory: true)

		let fm = FileManager.default

		// Check if .repoprompt folder exists
		guard fm.fileExists(atPath: legacyFolderURL.path) else {
			return 0
		}

		// Enumerate all filepartitions-*.json files
		guard let contents = try? fm.contentsOfDirectory(at: legacyFolderURL, includingPropertiesForKeys: nil) else {
			return 0
		}

		var migratedCount = 0

		for fileURL in contents {
			let fileName = fileURL.lastPathComponent

			// Only process filepartitions-*.json files
			guard fileName.hasPrefix("filepartitions-") && fileName.hasSuffix(".json") else {
				continue
			}

			// Parse the filename to extract scope information
			// Format: filepartitions-<workspaceID>[-<tabID>].json
			guard let scope = parsePartitionFileName(fileName) else {
				continue
			}

			// Load the legacy partition data
			guard let partitionData = loadPartition(at: fileURL) else {
				continue
			}

			// Save to new location (this will handle directory creation)
			do {
				try await save(forRoot: rootPath, scope: scope, data: partitionData)
				migratedCount += 1
			} catch {
				// Log but continue with other files
				print("Failed to migrate partition file \(fileName): \(error)")
			}

			// Remove the legacy file
			try? fm.removeItem(at: fileURL)
		}

		// Try to remove .repoprompt folder if it's now empty
		if let remainingContents = try? fm.contentsOfDirectory(at: legacyFolderURL, includingPropertiesForKeys: nil),
		   remainingContents.isEmpty {
			try? fm.removeItem(at: legacyFolderURL)
		}

		return migratedCount
	}

	// MARK: - Helpers
	
	private func partitionURL(forRoot rootPath: String, scope: PartitionScope) -> URL {
		let base = Self.partitionsBaseURL()
		let folder = base.appendingPathComponent(repoKey(forRoot: rootPath), isDirectory: true)

		let suffix: String
		if let tabID = scope.tabID {
			suffix = "-\(tabID.uuidString.lowercased())"
		} else {
			suffix = ""
		}
		let fileName = "filepartitions-\(scope.workspaceID.uuidString.lowercased())\(suffix).json"
		return folder.appendingPathComponent(fileName, isDirectory: false)
	}

	private func legacyLocalPartitionURL(forRoot rootPath: String, scope: PartitionScope) -> URL {
		let standardizedRoot = (rootPath as NSString).standardizingPath
		let directoryURL = URL(fileURLWithPath: standardizedRoot, isDirectory: true)
		let folderURL = directoryURL.appendingPathComponent(".repoprompt", isDirectory: true)

		let suffix: String
		if let tabID = scope.tabID {
			suffix = "-\(tabID.uuidString.lowercased())"
		} else {
			suffix = ""
		}
		let fileName = "filepartitions-\(scope.workspaceID.uuidString.lowercased())\(suffix).json"
		return folderURL.appendingPathComponent(fileName, isDirectory: false)
	}

	private func legacyPartitionURL(forRoot rootPath: String, workspaceID: UUID) -> URL {
		let standardizedRoot = (rootPath as NSString).standardizingPath
		let directoryURL = URL(fileURLWithPath: standardizedRoot, isDirectory: true)
		let folderURL = directoryURL.appendingPathComponent(".repoprompt", isDirectory: true)
		let fileName = "filepartitions-\(workspaceID.uuidString.lowercased()).json"
		return folderURL.appendingPathComponent(fileName, isDirectory: false)
	}

	private func postSaveNotification(rootPath: String, scope: PartitionScope) {
		let stdRoot = (rootPath as NSString).standardizingPath
		NotificationCenter.default.post(
			name: Self.didSaveNotification,
			object: nil,
			userInfo: [
				Self.notifRootPathKey: stdRoot,
				Self.notifWorkspaceIDKey: scope.workspaceID,
				Self.notifTabIDKey: scope.tabID as Any,
				Self.notifSourceIDKey: notificationSourceID
			]
		)
	}

	private func purgeLegacyFiles(forRoot rootPath: String, scope: PartitionScope) {
		let fm = FileManager.default
		let candidates = [
			legacyLocalPartitionURL(forRoot: rootPath, scope: scope),
			legacyPartitionURL(forRoot: rootPath, workspaceID: scope.workspaceID)
		]
		for url in candidates {
			_ = try? fm.removeItem(at: url)
		}
	}
	
	private func loadPartition(at url: URL) -> PartitionData? {
		do {
			let data = try Data(contentsOf: url)
			let decoded = try decoder.decode(PartitionData.self, from: data)
			return decoded
		} catch {
			return nil
		}
	}

	/// Parses partition filename to extract scope information.
	/// Format: filepartitions-<workspaceID>[-<tabID>].json
	/// Returns nil if the filename cannot be parsed.
	private func parsePartitionFileName(_ fileName: String) -> PartitionScope? {
		// Remove prefix and suffix
		guard fileName.hasPrefix("filepartitions-") && fileName.hasSuffix(".json") else {
			return nil
		}

		let uuidPart = fileName
			.dropFirst("filepartitions-".count)
			.dropLast(".json".count)
	
		// Split with no limit to handle both single UUID (4 hyphens = 5 components)
		// and double UUID with tab (9 hyphens = 10 components)
		let components = uuidPart.split(separator: "-")

		// Format: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX (5 components for a UUID)
		// With tab: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX-YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY
		if components.count == 5 {
			// No tab ID, just workspace ID
			let workspaceIDString = String(uuidPart)
			guard let workspaceID = UUID(uuidString: workspaceIDString) else {
				return nil
			}
			return PartitionScope(workspaceID: workspaceID, tabID: nil)
		} else if components.count == 10 {
			// Has tab ID (5 components for workspace + 5 for tab)
			let workspaceIDString = components[0..<5].joined(separator: "-")
			let tabIDString = components[5..<10].joined(separator: "-")

			guard let workspaceID = UUID(uuidString: workspaceIDString),
				  let tabID = UUID(uuidString: tabIDString) else {
				return nil
			}
			return PartitionScope(workspaceID: workspaceID, tabID: tabID)
		}

		return nil
	}
}
