import Foundation

#if DEBUG
private var gitDiffDataMaintenanceDebugLoggingEnabled = false
#endif

private func gitDiffDataMaintenanceDebugLog(_ message: @autoclosure () -> String) {
	#if DEBUG
	guard gitDiffDataMaintenanceDebugLoggingEnabled else { return }
	print("[GitDiffDataMaintenance] \(message())")
	#endif
}

/// Coordinates git diff data maintenance: retention enforcement, tab cleanup, and versioned upgrades.
///
/// This actor serializes cleanup operations to prevent races between:
/// - Snapshot publishing
/// - Tab close cleanup
/// - Workspace open maintenance
actor GitDiffDataMaintenance {
	static let shared = GitDiffDataMaintenance()
	
	/// Current data format version. Increment when making breaking changes that require cleanup.
	static let currentDataVersion: Int = 2
	
	/// Retention policy configuration
	struct Policy: Sendable {
		/// Maximum number of snapshots to keep per workspace
		var maxSnapshotsPerWorkspace: Int = 25
		/// Maximum age in days before a snapshot is expired
		var maxAgeDays: Int = 7
		/// Minimum interval between full maintenance runs (to avoid excessive IO)
		var minIntervalBetweenRuns: TimeInterval = 6 * 3600  // 6 hours
		
		static let `default` = Policy()
	}
	
	/// State persisted in `_git_data/maintenance.json`
	struct MaintenanceState: Codable, Sendable {
		var version: Int
		var lastCleanupAt: Date
		
		static let empty = MaintenanceState(version: 0, lastCleanupAt: .distantPast)
	}
	
	/// Result of a maintenance run
	struct MaintenanceResult: Sendable {
		let expiredSnapshotsDeleted: Int
		let excessSnapshotsDeleted: Int
		let legacyPurgePerformed: Bool
		let versionUpgraded: Bool
	}
	
	private let store = GitDiffSnapshotStore()
	
	private init() {}
	
	// MARK: - Public API
	
	/// Run maintenance when a workspace is opened.
	/// This handles version upgrades, legacy purge, and retention enforcement.
	func runOnWorkspaceOpen(workspaceDirectory: URL, policy: Policy = .default) async -> MaintenanceResult {
		let state = readMaintenanceState(workspaceDirectory: workspaceDirectory)
		var result = MaintenanceResult(
			expiredSnapshotsDeleted: 0,
			excessSnapshotsDeleted: 0,
			legacyPurgePerformed: false,
			versionUpgraded: false
		)
		
		// Check if version upgrade is needed
		if state.version < Self.currentDataVersion {
			// Run legacy purge on version upgrade
			var legacyPurged = false
			do {
				let purgeResult = try store.purgeLegacyGitDiffSnapshots(workspaceDirectory: workspaceDirectory)
				if purgeResult.deletedLegacySnapshotDirs > 0 || purgeResult.removedLegacyCurrent || purgeResult.removedLegacyDiffSnapshotsDir {
					legacyPurged = true
				}
			} catch {
				gitDiffDataMaintenanceDebugLog("Legacy purge failed: \(error.localizedDescription)")
			}
			
			result = MaintenanceResult(
				expiredSnapshotsDeleted: result.expiredSnapshotsDeleted,
				excessSnapshotsDeleted: result.excessSnapshotsDeleted,
				legacyPurgePerformed: legacyPurged,
				versionUpgraded: true  // Always true when version bumps
			)
			
			// Update version but preserve lastCleanupAt - only update it when retention actually runs
			// Only write if _git_data exists (don't create empty folder just for version tracking)
			writeMaintenanceState(
				MaintenanceState(version: Self.currentDataVersion, lastCleanupAt: state.lastCleanupAt),
				workspaceDirectory: workspaceDirectory,
				onlyIfExists: true
			)
		}
		
		// Check if enough time has passed since last cleanup
		let timeSinceLastCleanup = Date().timeIntervalSince(state.lastCleanupAt)
		guard timeSinceLastCleanup >= policy.minIntervalBetweenRuns else {
			return result
		}
		
		// Run retention enforcement
		let retentionResult = enforceRetention(workspaceDirectory: workspaceDirectory, policy: policy)
		
		// Update last cleanup time (only if _git_data exists)
		writeMaintenanceState(
			MaintenanceState(version: Self.currentDataVersion, lastCleanupAt: Date()),
			workspaceDirectory: workspaceDirectory,
			onlyIfExists: true
		)
		
		return MaintenanceResult(
			expiredSnapshotsDeleted: retentionResult.expiredDeleted,
			excessSnapshotsDeleted: retentionResult.excessDeleted,
			legacyPurgePerformed: result.legacyPurgePerformed,
			versionUpgraded: result.versionUpgraded
		)
	}
	
	/// Run lightweight retention after a snapshot is published.
	/// Only enforces max count (FIFO deletion) - age-based expiry runs on workspace open.
	func runAfterSnapshotPublish(workspaceDirectory: URL, policy: Policy = .default) async {
		// Only enforce max count for efficiency - age-based cleanup runs on workspace open
		_ = enforceMaxCount(maxCount: policy.maxSnapshotsPerWorkspace, workspaceDirectory: workspaceDirectory)
	}
	
	/// Delete all snapshots associated with a specific tab.
	/// Called when a compose tab is closed.
	@discardableResult
	func deleteSnapshotsForTab(workspaceDirectory: URL, tabID: UUID) async -> Int {
		var deletedCount = 0
		
		// Collect all entries across all repos
		let repoKeys = store.listRepoKeys(workspaceDirectory: workspaceDirectory)
		var affectedRepos: Set<String> = []
		
		for repoKey in repoKeys {
			guard let entries = try? store.listSnapshotEntries(workspaceDirectory: workspaceDirectory, repoKey: repoKey) else {
				continue
			}
			
			for entry in entries {
				// Check if this snapshot belongs to the closing tab
				if entry.manifest.tabID == tabID {
					if (try? store.deleteSnapshot(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: entry.snapshotID)) == true {
						deletedCount += 1
						affectedRepos.insert(repoKey)
					}
				}
			}
		}
		
		// Update CURRENT pointers for affected repos
		for repoKey in affectedRepos {
			try? store.updateCurrentToNewest(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
		}
		
		// Clean up empty directories
		cleanupEmptyDirectories(workspaceDirectory: workspaceDirectory, affectedRepos: affectedRepos)
		
		if deletedCount > 0 {
			gitDiffDataMaintenanceDebugLog("Deleted \(deletedCount) snapshot(s) for closed tab \(tabID.uuidString.prefix(8))")
		}
		
		return deletedCount
	}
	
	/// Delete all snapshots associated with multiple tabs in a single scan.
	/// More efficient than calling deleteSnapshotsForTab multiple times.
	@discardableResult
	func deleteSnapshotsForTabs(workspaceDirectory: URL, tabIDs: Set<UUID>) async -> Int {
		guard !tabIDs.isEmpty else { return 0 }
		
		var deletedCount = 0
		
		// Single scan across all repos
		let repoKeys = store.listRepoKeys(workspaceDirectory: workspaceDirectory)
		var affectedRepos: Set<String> = []
		
		for repoKey in repoKeys {
			guard let entries = try? store.listSnapshotEntries(workspaceDirectory: workspaceDirectory, repoKey: repoKey) else {
				continue
			}
			
			for entry in entries {
				// Check if this snapshot belongs to any of the closing tabs
				if let tabID = entry.manifest.tabID, tabIDs.contains(tabID) {
					if (try? store.deleteSnapshot(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: entry.snapshotID)) == true {
						deletedCount += 1
						affectedRepos.insert(repoKey)
					}
				}
			}
		}
		
		// Update CURRENT pointers for affected repos
		for repoKey in affectedRepos {
			try? store.updateCurrentToNewest(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
		}
		
		// Clean up empty directories
		cleanupEmptyDirectories(workspaceDirectory: workspaceDirectory, affectedRepos: affectedRepos)
		
		if deletedCount > 0 {
			gitDiffDataMaintenanceDebugLog("Deleted \(deletedCount) snapshot(s) for \(tabIDs.count) closed tab(s)")
		}
		
		return deletedCount
	}
	
	/// Delete all git data for a workspace.
	/// Called when a workspace is deleted.
	@discardableResult
	func deleteAllGitData(workspaceDirectory: URL) async -> Bool {
		let gitDataDir = store.gitDataRoot(workspaceDirectory: workspaceDirectory)
		let fileManager = FileManager.default
		
		guard fileManager.fileExists(atPath: gitDataDir.path) else {
			return false
		}
		
		do {
			try fileManager.removeItem(at: gitDataDir)
			gitDiffDataMaintenanceDebugLog("Deleted all git data for workspace at \(workspaceDirectory.lastPathComponent)")
			return true
		} catch {
			gitDiffDataMaintenanceDebugLog("Failed to delete git data: \(error.localizedDescription)")
			return false
		}
	}
	
	// MARK: - Retention Logic
	
	private struct RetentionResult {
		let expiredDeleted: Int
		let excessDeleted: Int
	}
	
	private func enforceRetention(workspaceDirectory: URL, policy: Policy) -> RetentionResult {
		var expiredDeleted = 0
		var excessDeleted = 0
		
		// Step 1: Delete expired snapshots (older than maxAgeDays)
		let cutoffDate = Calendar.current.date(byAdding: .day, value: -policy.maxAgeDays, to: Date()) ?? Date()
		expiredDeleted = deleteSnapshotsOlderThan(cutoffDate: cutoffDate, workspaceDirectory: workspaceDirectory)
		
		// Step 2: Enforce max count (FIFO - delete oldest first)
		excessDeleted = enforceMaxCount(maxCount: policy.maxSnapshotsPerWorkspace, workspaceDirectory: workspaceDirectory)
		
		if expiredDeleted > 0 || excessDeleted > 0 {
			gitDiffDataMaintenanceDebugLog("Retention cleanup: expired=\(expiredDeleted), excess=\(excessDeleted)")
		}
		
		return RetentionResult(expiredDeleted: expiredDeleted, excessDeleted: excessDeleted)
	}
	
	private func deleteSnapshotsOlderThan(cutoffDate: Date, workspaceDirectory: URL) -> Int {
		var deletedCount = 0
		let repoKeys = store.listRepoKeys(workspaceDirectory: workspaceDirectory)
		var affectedRepos: Set<String> = []
		
		for repoKey in repoKeys {
			guard let entries = try? store.listSnapshotEntries(workspaceDirectory: workspaceDirectory, repoKey: repoKey) else {
				continue
			}
			
			for entry in entries {
				if entry.manifest.generatedAt < cutoffDate {
					if (try? store.deleteSnapshot(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: entry.snapshotID)) == true {
						deletedCount += 1
						affectedRepos.insert(repoKey)
					}
				}
			}
		}
		
		// Update CURRENT pointers for affected repos
		for repoKey in affectedRepos {
			try? store.updateCurrentToNewest(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
		}
		
		// Clean up empty directories
		cleanupEmptyDirectories(workspaceDirectory: workspaceDirectory, affectedRepos: affectedRepos)
		
		return deletedCount
	}
	
	private func enforceMaxCount(maxCount: Int, workspaceDirectory: URL) -> Int {
		// Collect all entries across all repos with their full context
		struct SnapshotInfo {
			let repoKey: String
			let snapshotID: String
			let generatedAt: Date
		}
		
		var allSnapshots: [SnapshotInfo] = []
		let repoKeys = store.listRepoKeys(workspaceDirectory: workspaceDirectory)
		
		for repoKey in repoKeys {
			guard let entries = try? store.listSnapshotEntries(workspaceDirectory: workspaceDirectory, repoKey: repoKey) else {
				continue
			}
			for entry in entries {
				allSnapshots.append(SnapshotInfo(
					repoKey: repoKey,
					snapshotID: entry.snapshotID,
					generatedAt: entry.manifest.generatedAt
				))
			}
		}
		
		// If within limit, nothing to do
		guard allSnapshots.count > maxCount else {
			return 0
		}
		
		// Sort by age (oldest first) with deterministic tie-breaking
		let sorted = allSnapshots.sorted { lhs, rhs in
			if lhs.generatedAt != rhs.generatedAt {
				return lhs.generatedAt < rhs.generatedAt
			}
			// Tie-break by repoKey, then snapshotID for deterministic ordering
			if lhs.repoKey != rhs.repoKey {
				return lhs.repoKey < rhs.repoKey
			}
			return lhs.snapshotID < rhs.snapshotID
		}
		let toDelete = sorted.prefix(allSnapshots.count - maxCount)
		
		var deletedCount = 0
		var affectedRepos: Set<String> = []
		
		for info in toDelete {
			if (try? store.deleteSnapshot(workspaceDirectory: workspaceDirectory, repoKey: info.repoKey, snapshotID: info.snapshotID)) == true {
				deletedCount += 1
				affectedRepos.insert(info.repoKey)
			}
		}
		
		// Update CURRENT pointers for affected repos
		for repoKey in affectedRepos {
			try? store.updateCurrentToNewest(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
		}
		
		// Clean up empty directories
		cleanupEmptyDirectories(workspaceDirectory: workspaceDirectory, affectedRepos: affectedRepos)
		
		return deletedCount
	}
	
	// MARK: - Directory Cleanup
	
	/// Removes empty repo directories after snapshot deletion.
	/// Call this after deleting snapshots and updating CURRENT pointers.
	/// Note: Does NOT remove _git_data root to avoid UI folder collapse from FSEvents.
	private func cleanupEmptyDirectories(workspaceDirectory: URL, affectedRepos: Set<String>) {
		let fileManager = FileManager.default
		
		for repoKey in affectedRepos {
			// Check if repo directory is effectively empty (ignoring dotfiles like .DS_Store)
			let repoDir = store.snapshotsRoot(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
			if isEffectivelyEmpty(directory: repoDir, fileManager: fileManager) {
				try? fileManager.removeItem(at: repoDir)
			}
		}
		
		// Check if repos directory is effectively empty
		let reposDir = store.reposRoot(workspaceDirectory: workspaceDirectory)
		if isEffectivelyEmpty(directory: reposDir, fileManager: fileManager) {
			try? fileManager.removeItem(at: reposDir)
		}
		
		// Note: We intentionally do NOT remove the _git_data directory here.
		// Removing it triggers FSEvents that cause UI folder collapse.
		// The _git_data root is only removed via deleteAllGitData (workspace deletion).
	}
	
	/// Check if a directory is effectively empty (ignoring dotfiles like .DS_Store).
	/// Consistent with GitDiffSnapshotStore.removeEmptyParentDirectories.
	private func isEffectivelyEmpty(directory: URL, fileManager: FileManager) -> Bool {
		guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
			return false
		}
		// Ignore hidden files (dotfiles) like .DS_Store
		let significantContents = contents.filter { !$0.hasPrefix(".") }
		return significantContents.isEmpty
	}
	
	// MARK: - State File IO
	
	private func maintenanceStateURL(workspaceDirectory: URL) -> URL {
		store.gitDataRoot(workspaceDirectory: workspaceDirectory)
			.appendingPathComponent("maintenance.json")
	}
	
	private func readMaintenanceState(workspaceDirectory: URL) -> MaintenanceState {
		let url = maintenanceStateURL(workspaceDirectory: workspaceDirectory)
		guard FileManager.default.fileExists(atPath: url.path),
			let data = try? Data(contentsOf: url) else {
			return .empty
		}
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return (try? decoder.decode(MaintenanceState.self, from: data)) ?? .empty
	}
	
	/// Write maintenance state, optionally only if _git_data already exists.
	/// - Parameters:
	///   - state: The state to write
	///   - workspaceDirectory: The workspace directory
	///   - onlyIfExists: If true, only writes if _git_data directory already exists (avoids creating empty folders)
	private func writeMaintenanceState(_ state: MaintenanceState, workspaceDirectory: URL, onlyIfExists: Bool = false) {
		let gitDataDir = store.gitDataRoot(workspaceDirectory: workspaceDirectory)
		
		// If onlyIfExists is true, skip writing if _git_data doesn't exist
		if onlyIfExists && !FileManager.default.fileExists(atPath: gitDataDir.path) {
			return
		}
		
		let url = maintenanceStateURL(workspaceDirectory: workspaceDirectory)
		
		do {
			try FileManager.default.createDirectory(at: gitDataDir, withIntermediateDirectories: true)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			encoder.dateEncodingStrategy = .iso8601
			let data = try encoder.encode(state)
			try data.write(to: url, options: .atomic)
		} catch {
			gitDiffDataMaintenanceDebugLog("Failed to write maintenance state: \(error.localizedDescription)")
		}
	}
}
