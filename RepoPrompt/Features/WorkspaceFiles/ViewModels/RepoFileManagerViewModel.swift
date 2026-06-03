import Foundation
import Combine
import SwiftUI
import AppKit
#if DEBUG || EDIT_FLOW_PERF
import os
#endif

#if DEBUG
private var repoFileManagerDebugLoggingEnabled = false
private func repoFileManagerDebugLog(_ message: @autoclosure () -> String) {
	guard repoFileManagerDebugLoggingEnabled else { return }
	print("[RepoFileManagerVM] \(message())")
}
#else
private func repoFileManagerDebugLog(_ message: @autoclosure () -> String) {}
#endif

private enum WorkspaceExitPerf {
	#if DEBUG || EDIT_FLOW_PERF
	typealias State = OSSignpostIntervalState
	static let signposter = OSSignposter(subsystem: "com.repoprompt.workspace", category: "exit-perf")
	static var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: "enableWorkspaceExitPerfSignposts")
	}
	static func begin(_ name: StaticString) -> State? {
		guard isEnabled else { return nil }
		return signposter.beginInterval(name)
	}
	static func end(_ name: StaticString, _ state: State?) {
		guard isEnabled, let state else { return }
		signposter.endInterval(name, state)
	}
	#else
	struct State: Sendable {}
	static var isEnabled: Bool { false }
	static func begin(_ name: StaticString) -> State? { nil }
	static func end(_ name: StaticString, _ state: State?) {}
	#endif
}

private struct RemovedFolderPathMatcher {
	let removedFolderPaths: Set<String>

	func containsPathEqualToOrInsideRemovedFolder(_ standardizedPath: String) -> Bool {
		guard !removedFolderPaths.isEmpty else { return false }
		if removedFolderPaths.contains(standardizedPath) {
			return true
		}

		var current = standardizedPath
		while true {
			let parent = (current as NSString).deletingLastPathComponent
			guard !parent.isEmpty, parent != current else {
				return false
			}
			if removedFolderPaths.contains(parent) {
				return true
			}
			current = parent
		}
	}
}

/// Holds direct references
struct FileHierarchyIndex {
	struct OwnedDescendantPathsResult {
		let folderPaths: Set<String>
		let filePaths: Set<String>
		let usedFallbackGlobalScan: Bool
		let scanInvocationCount: Int
		let scannedFolderCandidateCount: Int
		let scannedFileCandidateCount: Int
	}

	// New: Store file & folder ViewModels by their fullPath.
	var filesByFullPath: [String: FileViewModel] = [:]
	var foldersByFullPath: [String: FolderViewModel] = [:]
	var filePathsByRoot: [String: Set<String>] = [:]
	var folderPathsByRoot: [String: Set<String>] = [:]
	
	mutating func clearAll() {
		filesByFullPath.removeAll()
		foldersByFullPath.removeAll()
		filePathsByRoot.removeAll()
		folderPathsByRoot.removeAll()
	}

	private static func removePath(
		_ path: String,
		from ownership: inout [String: Set<String>],
		rootKey: String,
		preserveEmptyEntry: Bool = false
	) {
		guard ownership[rootKey] != nil else { return }
		ownership[rootKey, default: []].remove(path)
		guard ownership[rootKey]?.isEmpty == true else { return }
		if preserveEmptyEntry {
			ownership[rootKey] = []
		} else {
			ownership.removeValue(forKey: rootKey)
		}
	}

	mutating func insertFolder(_ folder: FolderViewModel, rootKey: String? = nil) {
		let path = folder.standardizedFullPath
		let ownerRootKey = rootKey.map(StandardizedPath.absolute) ?? StandardizedPath.absolute(folder.rootPath)
		if let existing = foldersByFullPath.updateValue(folder, forKey: path) {
			let previousRootKey = StandardizedPath.absolute(existing.rootPath)
			if previousRootKey != ownerRootKey {
				Self.removePath(path, from: &folderPathsByRoot, rootKey: previousRootKey)
			}
		}
		folderPathsByRoot[ownerRootKey, default: []].insert(path)
		if path == ownerRootKey {
			_ = filePathsByRoot[ownerRootKey, default: []]
		}
	}

	@discardableResult
	mutating func removeFolder(forKey path: String, expectedRootKey: String? = nil) -> FolderViewModel? {
		let standardizedPath = StandardizedPath.absolute(path)
		let removed = foldersByFullPath.removeValue(forKey: standardizedPath)
		let ownerRootKey = removed.map { StandardizedPath.absolute($0.rootPath) }
			?? expectedRootKey.map(StandardizedPath.absolute)
		if let ownerRootKey {
			Self.removePath(standardizedPath, from: &folderPathsByRoot, rootKey: ownerRootKey)
		}
		return removed
	}

	mutating func insertFile(_ file: FileViewModel, rootKey: String? = nil) {
		let path = file.standardizedFullPath
		let ownerRootKey = rootKey.map(StandardizedPath.absolute) ?? file.standardizedRootFolderPath
		if let existing = filesByFullPath.updateValue(file, forKey: path) {
			let previousRootKey = existing.standardizedRootFolderPath
			if previousRootKey != ownerRootKey {
				Self.removePath(path, from: &filePathsByRoot, rootKey: previousRootKey)
			}
		}
		filePathsByRoot[ownerRootKey, default: []].insert(path)
	}

	@discardableResult
	mutating func removeFile(forKey path: String, expectedRootKey: String? = nil) -> FileViewModel? {
		let standardizedPath = StandardizedPath.absolute(path)
		let removed = filesByFullPath.removeValue(forKey: standardizedPath)
		let ownerRootKey = removed?.standardizedRootFolderPath
			?? expectedRootKey.map(StandardizedPath.absolute)
		if let ownerRootKey {
			let preserveEmptyEntry = folderPathsByRoot[ownerRootKey] != nil
			Self.removePath(
				standardizedPath,
				from: &filePathsByRoot,
				rootKey: ownerRootKey,
				preserveEmptyEntry: preserveEmptyEntry
			)
		}
		return removed
	}

	mutating func removeOwnedEntries(
		forRootKey rootKey: String,
		folderPaths: Set<String>,
		filePaths: Set<String>
	) {
		folderPathsByRoot.removeValue(forKey: rootKey)
		filePathsByRoot.removeValue(forKey: rootKey)
		for folderPath in folderPaths {
			foldersByFullPath.removeValue(forKey: folderPath)
		}
		for filePath in filePaths {
			filesByFullPath.removeValue(forKey: filePath)
		}
	}

	func ownedDescendantPaths(
		forRootKey rootKey: String,
		underFolderPaths folderPaths: Set<String>
	) -> OwnedDescendantPathsResult {
		let standardizedRootKey = StandardizedPath.absolute(rootKey)
		let standardizedFolderPaths = Set(folderPaths.map { StandardizedPath.absolute($0) })
		guard !standardizedFolderPaths.isEmpty else {
			return OwnedDescendantPathsResult(
				folderPaths: [],
				filePaths: [],
				usedFallbackGlobalScan: false,
				scanInvocationCount: 0,
				scannedFolderCandidateCount: 0,
				scannedFileCandidateCount: 0
			)
		}

		let matcher = RemovedFolderPathMatcher(removedFolderPaths: standardizedFolderPaths)
		let folderCandidates: Set<String>
		let fileCandidates: Set<String>
		let usedFallbackGlobalScan: Bool

		if let ownedFolderPaths = folderPathsByRoot[standardizedRootKey] {
			folderCandidates = ownedFolderPaths
			if let ownedFilePaths = filePathsByRoot[standardizedRootKey] {
				fileCandidates = ownedFilePaths
				usedFallbackGlobalScan = false
			} else {
				fileCandidates = Set(filesByFullPath.keys)
				usedFallbackGlobalScan = true
			}
		} else {
			folderCandidates = Set(foldersByFullPath.keys)
			fileCandidates = Set(filesByFullPath.keys)
			usedFallbackGlobalScan = true
		}

		var descendantFolderPaths: Set<String> = []
		descendantFolderPaths.reserveCapacity(min(folderCandidates.count, standardizedFolderPaths.count))
		for folderPath in folderCandidates where matcher.containsPathEqualToOrInsideRemovedFolder(folderPath) {
			descendantFolderPaths.insert(folderPath)
		}

		var descendantFilePaths: Set<String> = []
		descendantFilePaths.reserveCapacity(min(fileCandidates.count, standardizedFolderPaths.count))
		for filePath in fileCandidates where matcher.containsPathEqualToOrInsideRemovedFolder(filePath) {
			descendantFilePaths.insert(filePath)
		}

		return OwnedDescendantPathsResult(
			folderPaths: descendantFolderPaths,
			filePaths: descendantFilePaths,
			usedFallbackGlobalScan: usedFallbackGlobalScan,
			scanInvocationCount: 1,
			scannedFolderCandidateCount: folderCandidates.count,
			scannedFileCandidateCount: fileCandidates.count
		)
	}

	func ownedDescendantPaths(
		forRootKey rootKey: String,
		underFolderPath folderPath: String
	) -> (folderPaths: Set<String>, filePaths: Set<String>, usedFallbackGlobalScan: Bool) {
		let result = ownedDescendantPaths(
			forRootKey: rootKey,
			underFolderPaths: [folderPath]
		)
		return (
			folderPaths: result.folderPaths,
			filePaths: result.filePaths,
			usedFallbackGlobalScan: result.usedFallbackGlobalScan
		)
	}

	mutating func removeSubtreeEntries(
		forRootKey rootKey: String,
		folderPaths: Set<String>,
		filePaths: Set<String>
	) {
		let standardizedRootKey = StandardizedPath.absolute(rootKey)
		if var ownedFolderPaths = folderPathsByRoot[standardizedRootKey] {
			ownedFolderPaths.subtract(folderPaths)
			folderPathsByRoot[standardizedRootKey] = ownedFolderPaths
		}
		let preserveEmptyFileEntry = folderPathsByRoot[standardizedRootKey] != nil
		if var ownedFilePaths = filePathsByRoot[standardizedRootKey] {
			ownedFilePaths.subtract(filePaths)
			if ownedFilePaths.isEmpty, !preserveEmptyFileEntry {
				filePathsByRoot.removeValue(forKey: standardizedRootKey)
			} else {
				filePathsByRoot[standardizedRootKey] = ownedFilePaths
			}
		} else if preserveEmptyFileEntry {
			filePathsByRoot[standardizedRootKey] = []
		}
		for folderPath in folderPaths {
			foldersByFullPath.removeValue(forKey: folderPath)
		}
		for filePath in filePaths {
			filesByFullPath.removeValue(forKey: filePath)
		}
	}
}

private struct RootCleanupPlan {
	let rootKey: String
	let folderPaths: Set<String>
	let filePaths: Set<String>
	let usedFallbackGlobalScan: Bool
}

private struct RemovedFolderSubtree {
	let removedFolder: FolderViewModel
	let formerParentFolder: FolderViewModel?
	let removedFolderFullPath: String
}

private struct IncrementalRemovedSubtreeCleanupOutcome {
	let succeeded: Bool
	let removedFolderCount: Int
	let removedFileCount: Int
	let usedFallbackGlobalScan: Bool
	let descendantScanInvocationCount: Int
	let scannedFolderCandidateCount: Int
	let scannedFileCandidateCount: Int
}

private struct FileAdditionApplyOutcome {
	let file: FileViewModel
	let parentFolderForStateRecompute: FolderViewModel?
}

private struct ReplayFileAddParentContext {
	let standardizedParentRelativePath: String
	let standardizedParentFullPath: String?
	let parentFolder: FolderViewModel?

	var isRootParent: Bool {
		standardizedParentRelativePath.isEmpty
	}
}

private struct ExactDiskFileCandidate {
	let root: FolderViewModel
	let standardizedRelativePath: String
	let standardizedAbsolutePath: String
}

private enum ExactDiskFileLookupResult {
	case ambiguous
	case candidates([ExactDiskFileCandidate])
}

private struct FolderTopologyApplyOutcome {
	let parentFolderForStateRecompute: FolderViewModel?
}

private struct ReplaySliceRebaseRequest {
	let file: FileViewModel
	let relativePath: String
	let fsService: FileSystemService
}

private struct ReplayRootPassAccumulator {
	let rootKey: String
	var processedDigests: [RepoFileManagerViewModel.FileSystemDeltaDigest] = []
	var topologyChanged = false
	var codeScanFilesByID: [UUID: FileViewModel] = [:]
	var sliceRebasesByFullPath: [String: ReplaySliceRebaseRequest] = [:]
}

private final class WatcherIngressTaskTracker: @unchecked Sendable {
	private let lock = NSLock()
	private var inFlightIDs: Set<UUID> = []
	private var waiters: [(ids: Set<UUID>, continuation: CheckedContinuation<Void, Never>)] = []

	func begin(_ id: UUID) {
		lock.lock()
		inFlightIDs.insert(id)
		lock.unlock()
	}

	func end(_ id: UUID) {
		let continuationsToResume: [CheckedContinuation<Void, Never>]
		lock.lock()
		inFlightIDs.remove(id)
		var remainingWaiters: [(ids: Set<UUID>, continuation: CheckedContinuation<Void, Never>)] = []
		var readyContinuations: [CheckedContinuation<Void, Never>] = []
		for waiter in waiters {
			if waiter.ids.isDisjoint(with: inFlightIDs) {
				readyContinuations.append(waiter.continuation)
			} else {
				remainingWaiters.append(waiter)
			}
		}
		waiters = remainingWaiters
		continuationsToResume = readyContinuations
		lock.unlock()
		for continuation in continuationsToResume {
			continuation.resume()
		}
	}

	func waitForCurrentTasks() async {
		let snapshot = currentInFlightIDs()
		guard !snapshot.isEmpty else { return }
		await withCheckedContinuation { continuation in
			if registerWaiterIfNeeded(for: snapshot, continuation: continuation) {
				continuation.resume()
			}
		}
	}

	private func currentInFlightIDs() -> Set<UUID> {
		lock.lock()
		let snapshot = inFlightIDs
		lock.unlock()
		return snapshot
	}

	private func registerWaiterIfNeeded(
		for snapshot: Set<UUID>,
		continuation: CheckedContinuation<Void, Never>
	) -> Bool {
		lock.lock()
		let shouldResumeImmediately = snapshot.isDisjoint(with: inFlightIDs)
		if !shouldResumeImmediately {
			waiters.append((ids: snapshot, continuation: continuation))
		}
		lock.unlock()
		return shouldResumeImmediately
	}
}

@MainActor
class RepoFileManagerViewModel: ObservableObject {
	let allFoldersUnloadedPublisher = PassthroughSubject<Void, Never>()

	/// New: O(1) lookup cache
	private var fileHierarchyIndex = FileHierarchyIndex()

	// Track window focus
	private var isWindowFocused: Bool = true
	private var deferredReplayRoutingVersion: UInt64 = 0
	
	// ─────────────────────────────────────────────────────────────
	// MARK: ‑ Deferred replay routing
	// ─────────────────────────────────────────────────────────────
	// MARK: - Root-keyed storage (stable string keys instead of URL to avoid key instability)
	private typealias RootKey = String
	private static let defaultMaxPendingDeltasPerRoot = 10_000
	private let deferredReplayBuffer = DeferredReplayBufferActor(
		maxPendingDeltasPerRoot: RepoFileManagerViewModel.defaultMaxPendingDeltasPerRoot
	)
	private let watcherIngressTaskTracker = WatcherIngressTaskTracker()
	private var rootReplayIngressGenerationByRoot: [RootKey: UInt64] = [:]
	
	/// True while `flushPendingDeltas()` is actively replaying queued bursts.
	/// Incoming live FSEvents are re-queued when this is set, guaranteeing that
	/// only a single writer mutates the file-tree at any given time.
	private var isReplayingDeltas = false
	
	/// The currently running delta replay task, if any. Used to await completion
	/// instead of spin-waiting with Task.yield().
	private var deltaReplayTask: Task<Void, Never>?
	/// Run ID to safely clear deltaReplayTask only if it matches the current run.
	private var deltaReplayRunID: UUID?
	
	// ─────────────────────────────────────────────────────────────
	// MARK: - Child insertion coalescer (same-tick batching)
	// ─────────────────────────────────────────────────────────────
	/// Coalesces repeated child insertions (typically bursts of `.fileAdded`)
	/// into a single `addChildrenBatch` per parent folder.
	@MainActor private var pendingChildInserts: [UUID: [FileSystemItemType]] = [:]
	/// Stores the actual parent instances to avoid re-walking the tree / index by UUID.
	@MainActor private var pendingInsertParents: [UUID: FolderViewModel] = [:]
	@MainActor private var isInsertFlushScheduled: Bool = false

	let fileTogglePublisher = PassthroughSubject<FileViewModel, Never>()
	let folderDidFinishLoadingPublisher = PassthroughSubject<FolderViewModel, Never>()
	var cancellables = Set<AnyCancellable>()
	public var onRootFolderUnloadRequested: PassthroughSubject<String, Never> = .init()
	public var onRootFoldersReordered: PassthroughSubject<[String], Never> = .init()
	let folderRefreshPublisher = PassthroughSubject<FolderViewModel, Never>()
	let selectionClearedPublisher = PassthroughSubject<Void, Never>()
	let codeMapUpdatePublisher = PassthroughSubject<Void, Never>() // New publisher
	let fileSystemChangedPublisher = PassthroughSubject<Void, Never>() // Publisher for file system changes

	/// Emitted once after a prepared root delta pass is finalized.
	/// Provides path context so consumers can filter for specific concerns (e.g. skill files).
	let fileSystemDeltasAppliedPublisher = PassthroughSubject<FileSystemDeltasAppliedEvent, Never>()

	/// Summary of a coalesced delta batch applied to a single root.
	struct FileSystemDeltasAppliedEvent {
		let rootKey: String                     // standardized root full path
		let deltas: [FileSystemDeltaDigest]     // minimal path-only summaries
	}

	/// Lightweight, path-only digest of a `FileSystemDelta` for consumer filtering.
	enum FileSystemDeltaDigest {
		case fileAdded(String)
		case fileRemoved(String)
		case folderAdded(String)
		case folderRemoved(String)
		case fileModified(String)
		case folderModified(String)

		/// The relative path carried by this digest entry.
		var relativePath: String {
			switch self {
			case .fileAdded(let p), .fileRemoved(let p),
				.folderAdded(let p), .folderRemoved(let p),
				.fileModified(let p), .folderModified(let p):
				return p
			}
		}
	}

	// Monotonic signature for "any root changed".
	private var hierarchyGenerationSignature: UInt64 = 0
	
	/// Per-root hierarchy generations, keyed by standardized root path.
	/// Only topology changes for that root bump its generation.
	@MainActor
	private var rootHierarchyGenerations: [String: UInt64] = [:]
	
	/// Snapshot of per-root generation values keyed by standardized root full path.
	@MainActor
	public var hierarchyGenerationByRoot: [String: UInt64] {
		rootHierarchyGenerations
	}

	/// Monotonic signature that bumps whenever workspace file hierarchy changes.
	@MainActor
	func currentHierarchyGenerationSignature() -> UInt64 {
		hierarchyGenerationSignature
	}

	private var newlyCreatedFilePaths = Set<String>()
	private weak var workspaceManager: WorkspaceManagerViewModel?
	private(set) var currentWorkspaceID: UUID?
	private var currentTabID: UUID?

	private var loadedRootPaths = Set<String>()

	/// A simple computed property to check if *any* folder is being loaded
	var isAnyFolderLoading: Bool {
		isLoading
	}
	
	@Published private(set) var rootFolders: [FolderViewModel] = []
	
	enum RootKind {
		case user
		case supplementalSystem
	}

	enum LookupRootScope: Hashable, Sendable {
		case visibleWorkspace
		case visibleWorkspacePlusGitData
		case allLoaded
	}

	var visibleRootFolders: [FolderViewModel] {
		rootFolders.filter { !$0.isSystemRoot }
	}

	// Cache expanded folder paths to avoid recursive traversal
	private var expandedFolderPaths: Set<String> = []
	private var expansionSubscriptions: [UUID: AnyCancellable] = [:]
	private var isApplyingExpansionState = false

	
	// No longer using ExpansionManager - expansion state is stored directly in FolderViewModel
	
	@AppStorage("fileTreeSortMethod") private var storedSortMethod: String = SortMethod.nameAscending.rawValue
	
	// Use a published property that syncs with the AppStorage value.
	@Published var currentSortMethod: SortMethod = .nameAscending {
		didSet {
			// Guard against redundant UserDefaults writes (and cross-window ping-pong)
			let raw = currentSortMethod.rawValue
			if storedSortMethod != raw {
				storedSortMethod = raw
			}
		}
	}
	
	@MainActor
	func addRootFolder(_ folder: FolderViewModel) {
		rootFolders.append(folder)
		registerExpansionTracking(for: folder)
		// Mark snapshot cache as dirty
		invalidateStaticSnapshot(forRootFullPath: folder.standardizedFullPath)
	}
	
	@MainActor
	func removeRootFolder(_ folder: FolderViewModel) {
		let stdPath = folder.standardizedFullPath
		unregisterExpansionTracking(for: folder)
		rootFolders.removeAll { $0.id == folder.id }
		
		// Topology: root disappeared - remove per-root generation entry
		removeHierarchyGenerationEntry(forRootFullPath: stdPath)
		// Mark global path snapshot dirty (don't bump removed root)
		invalidateStaticSnapshot(forRootFullPath: nil)
		
		if rootFolders.isEmpty {
			allFoldersUnloadedPublisher.send(())
		}
	}
	
	@MainActor
	func refreshSortingIfNeeded(_ method: SortMethod) {
		for root in rootFolders {
			root.markDirtyRecursively() // Mark entire hierarchy as needing resort
			root.sortChildrenIfNeeded(method)
		}
	}

	/// Single entry point for changing the file tree sort method.
	/// Sets the method and reorders the tree without recomputing checkbox state.
	@MainActor
	func setFileTreeSortMethod(_ method: SortMethod) {
		guard currentSortMethod != method else { return }
		currentSortMethod = method
		for root in rootFolders {
			root.markDirtyRecursively()
			root.sortChildrenIfNeeded(method, recomputeCheckbox: false)
		}
	}
	@Published private(set) var selectedFiles: [FileViewModel] = []
	@Published private(set) var autoCodemapFiles: [FileViewModel] = []
	private var autoCodemapFileIDs: Set<UUID> = []
	@Published var codemapAutoEnabled: Bool = true {
		didSet {
			guard codemapAutoEnabled != oldValue else { return }
			if codemapAutoEnabled {
				scheduleAutoCodemapSync()
			} else {
				autoCodemapSyncTask?.cancel()
				autoCodemapSyncTask = nil
			}
		}
	}
	private var autoCodemapSyncTask: Task<Void, Never>?
	/// Tracks which paths currently have a cached FileAPI to avoid scanning all FileViewModels.
	private var codemapCapableAPIsByFullPath: [String: FileAPI] = [:]
	
	@Published private(set) var isLoading: Bool = false
	@Published private(set) var error: FileManagerError?
	
	var showEmptyFolders: Bool = false
	var skipSymlinks: Bool = true
	var respectGitignore: Bool = true
	var respectRepoIgnore: Bool = true
	var respectCursorignore: Bool = true
	var enableHierarchicalIgnores: Bool = true
	
	var onRootFoldersChanged: (() -> Void)?
	
	@Published private var selectedFileIDs: Set<UUID> = []
	private var isSelectionBatching      = false
	private var pendingSelectionAdds     = [FileViewModel]()
	private var pendingSelectionRemoves  = [FileViewModel]()
	@Published private var folderBeingAdded: FolderViewModel?
	
	private var fileSystemServices: [RootKey: FileSystemService] = [:]
	
	/// Added property to hold our change subscriptions
	private var watchers: [RootKey: AnyCancellable] = [:]
	private var partitionStoreSaveCancellable: AnyCancellable?
	private var fileSystemSettingsCancellable: AnyCancellable?
	private var forceReloadOnNextFileSystemSettingsRefresh = false
	
	private let partitionStore = PartitionStore()
   private var currentSlicesByRoot: [String: [String: PartitionStore.StoredSlices]] = [:]
   @Published private(set) var selectionSlicesByFileID: [UUID: [LineRange]] = [:]
	private var sliceSnapshotRebuildDeferralDepth = 0
	private var sliceSnapshotRebuildPending = false
	#if DEBUG
	private var sliceSnapshotRebuildPendingReasons = Set<String>()
	#endif
	private var sliceRebaseTasksByFullPath: [String: Task<Void, Never>] = [:]
	private var sliceRebaseTaskIDsByFullPath: [String: UUID] = [:]
	/// Monotonic revision incremented for any partition save seen in the current workspace.
	/// Used to avoid re-checking files already confirmed as "no slices" until new saves occur.
	private var partitionSliceSaveRevision: UInt64 = 0
	/// Cache of files confirmed to have no slices at `partitionSliceSaveRevision`.
	private var noSlicesKnownRevisionByFullPath: [String: UInt64] = [:]
	private var workspaceSaveDebounceTask: Task<Void, Never>?
	
	private let codeScanActor = CodeScanActor()
	private var isInitialRootLoadScanDeferralActive = false
	private var deferredInitialRootLoadScanRoots = Set<String>()
	private var deferredInitialRootLoadScanFlushTask: Task<Void, Never>?
	private var deferredInitialRootLoadScanFlushTaskID: UUID?
	
	// MARK: - Path Matching Cache
	
	private struct SnapshotCache {
		var staticDataByScope: [LookupRootScope: StaticPathMatchData] = [:]
		var generation: UInt64 = 0    // Monotonic counter for index caching
	}
	
	private var snapshotCache = SnapshotCache()

	private struct MarkdownPathSearchEntry {
		let queryPath: String
		let fileFullPath: String
	}

	private var markdownPathSearchIndex: PathSearchIndex?
	private var markdownPathSearchEntries: [MarkdownPathSearchEntry] = []
	private var markdownPathSearchGeneration: UInt64?
	
	/// Per-window path match worker.
	/// Lives as long as this VM (window) is alive.
	/// Handles all heavy path matching work off the main actor.
	private let pathMatchWorker = PathMatchWorker()
	
	@MainActor
	private func bumpHierarchyGeneration(forRootFullPath rootFullPath: String?) {
		if let path = rootFullPath {
			// Bump only this root
			rootHierarchyGenerations[path, default: 0] &+= 1
		} else {
			// Unknown / multi-root change: conservatively bump all known roots
			for key in rootHierarchyGenerations.keys {
				rootHierarchyGenerations[key]! &+= 1
			}
		}
		// Always bump global signature
		hierarchyGenerationSignature &+= 1
	}
	
	@MainActor
	private func removeHierarchyGenerationEntry(forRootFullPath rootFullPath: String) {
		if rootHierarchyGenerations.removeValue(forKey: rootFullPath) != nil {
			// Root disappearing is also a topology change for external consumers.
			hierarchyGenerationSignature &+= 1
		}
	}

	@MainActor
	private func clearPathResolutionCaches() async {
		markdownPathSearchIndex = nil
		markdownPathSearchEntries.removeAll(keepingCapacity: false)
		markdownPathSearchGeneration = nil
		await pathMatchWorker.invalidateCache()
	}
	
	#if DEBUG
	private func debugPerfTimestampMS() -> Double {
		CFAbsoluteTimeGetCurrent() * 1_000
	}

	private func debugPerfElapsedMS(since startMS: Double) -> Double {
		debugPerfTimestampMS() - startMS
	}

	private func restorePerfRootKindName(_ rootKind: RootKind) -> String {
		switch rootKind {
		case .user:
			return "user"
		case .supplementalSystem:
			return "supplementalSystem"
		}
	}

	func restorePerfLoadedTreeCounts() -> (rootCount: Int, folderCount: Int, fileCount: Int) {
		(
			rootFolders.count,
			fileHierarchyIndex.foldersByFullPath.count,
			fileHierarchyIndex.filesByFullPath.count
		)
	}

	private static var isRootCleanupOwnershipIntegrityValidationEnabled: Bool {
		UserDefaults.standard.bool(forKey: "enableRepoFileManagerOwnershipIntegrityValidation")
	}
	
	@MainActor
	private func invalidateStaticSnapshot(forRootFullPath rootFullPath: String? = nil) {
		snapshotCache.staticDataByScope.removeAll()
		snapshotCache.generation &+= 1
		bumpHierarchyGeneration(forRootFullPath: rootFullPath)
		// Notify subscribers that file system has changed
		fileSystemChangedPublisher.send()
	}
	#else
	@MainActor
	private func invalidateStaticSnapshot(forRootFullPath rootFullPath: String? = nil) {
		snapshotCache.staticDataByScope.removeAll()
		snapshotCache.generation &+= 1
		bumpHierarchyGeneration(forRootFullPath: rootFullPath)
		// Notify subscribers that file system has changed
		fileSystemChangedPublisher.send()
	}
	#endif
	
	/// Shared instance to avoid recreating a search actor for every query
	private let fileSearchActor = FileSearchActor()
	private let deltaReplayPreparationActor = DeltaReplayPreparationActor()
	
	@Published var remainingScanCount: Int = 0
	@Published var totalFilesSeen: Int = 0
	
	// We'll keep your existing references to isLoading, selectedFiles, etc.
	// If you don't need these placeholders, remove them.
	private var currentFolderLoadingTask: Task<Void, Error>? = nil
	
	private var scanProgressTask: Task<Void, Never>? = nil

	#if !DEBUG
	typealias RootReplayPassPerfSample = Never
	#endif

	#if !DEBUG
	final class ReplayFileAddPathMetricsCollector {}
	#endif

	#if DEBUG
	struct IndexRebuildPerfSample: Equatable {
		let rootKey: String
		let totalFolderKeysBefore: Int
		let totalFileKeysBefore: Int
		let totalCodemapKeysBefore: Int
		let ownedFolderKeysBefore: Int
		let ownedFileKeysBefore: Int
		let cleanupCandidateFolderKeys: Int
		let cleanupCandidateFileKeys: Int
		let usedOwnershipFallback: Bool
		let cleanupCandidateSelectionDurationMS: Double
		let cleanupFolderRemovalDurationMS: Double
		let cleanupFileRemovalDurationMS: Double
		let reindexTraversalDurationMS: Double
		let reindexVisitedFolderCount: Int
		let reindexVisitedFileCount: Int
		let totalDurationMS: Double
	}

	struct ReplayFileAddPathMetrics: Equatable {
		var handleNewFileCallCount = 0
		var existingFileCount = 0
		var newFileCount = 0
		var findExistingFileLookupCount = 0
		var findExistingStandardizedFastPathCount = 0
		var newlyCreatedMarkerEmptySetSkipCount = 0
		var newlyCreatedMarkerKeyBuildCount = 0
		var newlyCreatedMarkerConsumedCount = 0
		var parentFolderLookupCallCount = 0
		var parentFolderRootReturnCount = 0
		var parentFolderLookupHitCount = 0
		var parentFolderLookupMissCount = 0
		var insertFileCallCount = 0
		var insertFileParentPathDerivationCount = 0
		var insertFileParentLookupHitCount = 0
		var insertFileParentLookupMissCount = 0
		var createMissingParentFolderCallCount = 0
		var createMissingParentFolderCreatedCount = 0
		var fileHierarchyInsertFileCount = 0
		var uniqueParentPathCount = 0
		var eligibilityCheckCount = 0
		var eligibilityEligibleCount = 0
		var eligibilityIneligibleCount = 0
		var eligibilityCheckDurationMS = 0.0
		var eligibilityCheckMaxDurationMS = 0.0
		var eligibilityBatchRawInputCount = 0
		var eligibilityBatchUniquePathCount = 0
		var eligibilityBatchResultCount = 0
		var eligibilityPreparedFastPathAttemptCount = 0
		var eligibilityPreparedFastPathUsedCount = 0
		var eligibilityPreparedFastPathFallbackCount = 0
		var eligibilityPreparedFastPathInputCount = 0
		var eligibilityPreparedFastPathGroupedEntryCount = 0
		var eligibilityPreparedFastPathParentReuseHitCount = 0
		var eligibilityPreparedFastPathParentReuseMissCount = 0
		var eligibilityBatchParentGroupCount = 0
		var eligibilityBatchMaxParentGroupSize = 0
		var eligibilityStandardizeAndGroupDurationMS = 0.0
		var eligibilityParentProcessingDurationMS = 0.0
		var eligibilityDirectoryScanGroupCount = 0
		var eligibilityDirectoryScanFailureGroupCount = 0
		var eligibilityDirectoryScanDurationMS = 0.0
		var eligibilityDirectoryEntryCount = 0
		var eligibilityEntriesMapBuildDurationMS = 0.0
		var eligibilityCanonicalParentResolveDurationMS = 0.0
		var eligibilityPreparedIgnoreRulesGroupCount = 0
		var eligibilityPreparedIgnoreRulesFailureGroupCount = 0
		var eligibilityPreparedIgnoreRulesDurationMS = 0.0
		var eligibilityPreparedIgnoreRulesCacheHitDirectoryCount = 0
		var eligibilityPreparedIgnoreRulesCacheMissDirectoryCount = 0
		var eligibilityHierarchicalIgnoreCheckCount = 0
		var eligibilityHierarchicalIgnoreNoOpParentGroupCount = 0
		var eligibilityHierarchicalIgnoreSkippedLeafCheckCount = 0
		var eligibilityHierarchicalIgnoreDurationMS = 0.0
		var eligibilityPrefixIgnoreCheckCount = 0
		var eligibilityPrefixIgnoreNoOpParentGroupCount = 0
		var eligibilityPrefixIgnoreSkippedLeafCheckCount = 0
		var eligibilityPrefixIgnoreDurationMS = 0.0
		var eligibilityPrefixDirectLeafFastPathParentGroupCount = 0
		var eligibilityPrefixDirectLeafFastPathUnsupportedParentGroupCount = 0
		var eligibilityPrefixDirectLeafFastPathLeafCheckCount = 0
		var eligibilityPrefixDirectLeafFastPathIgnoredLeafCount = 0
		var eligibilityPrefixDirectLeafFastPathCandidatePatternCountTotal = 0
		var eligibilityPrefixDirectLeafFastPathCandidatePatternCountMax = 0
		var eligibilityPrefixDirectLeafFastPathDurationMS = 0.0
		var eligibilityPrefixParentRuleShapeGroupCount = 0
		var eligibilityPrefixParentRuleDepthTotal = 0
		var eligibilityPrefixParentRuleDepthMax = 0
		var eligibilityPrefixParentActivePatternCountTotal = 0
		var eligibilityPrefixParentActivePatternCountMax = 0
		var eligibilityPrefixParentHasNegativePatternGroupCount = 0
		var eligibilitySingleFileFallbackUniquePathCount = 0
		var eligibilitySingleFileFallbackDurationMS = 0.0
		var eligibilityFallbackParentSymlinkCount = 0
		var eligibilityFallbackDirectoryScanFailureCount = 0
		var eligibilityFallbackMissingEntryCount = 0
		var eligibilityFallbackUnknownEntryMetadataCount = 0
		var eligibilityFallbackPreparedRulesFailureCount = 0
		var eligibilityFallbackPreparedRuleMissCount = 0
		var eligibilityFallbackInvalidLeafNameCount = 0
		var eligibilityEligibleUniquePathCount = 0
		var eligibilityIgnoredUniquePathCount = 0
		var eligibilityMissingOrDirectoryUniquePathCount = 0
		var eligibilitySymbolicLinkUniquePathCount = 0
		var eligibilityNonRegularFileUniquePathCount = 0
		var eligibilitySymlinkComponentUniquePathCount = 0
		var eligibilityOutsideCanonicalRootUniquePathCount = 0
		var eligibilityInvalidRelativePathUniquePathCount = 0
		var eligibilityOutsideRootUniquePathCount = 0
		var parentContextCallCount = 0
		var parentContextCacheHitCount = 0
		var parentContextCacheMissCount = 0
		var parentContextOrderedReuseHitCount = 0
		var parentContextOrderedReuseMissCount = 0
		var parentContextParentStringBuildCount = 0
		var parentContextDurationMS = 0.0
		var replayPathMetadataCount = 0
		var replayPathMetadataDurationMS = 0.0
		var handleNewFileDurationMS = 0.0
		var handleNewFileMaxDurationMS = 0.0
		var findExistingFileLookupDurationMS = 0.0
		var fileViewModelConstructionCount = 0
		var fileViewModelConstructionDurationMS = 0.0
		var selectionCallbackAttachDurationMS = 0.0
		var fileHierarchyInsertFileDurationMS = 0.0
		var insertFileDurationMS = 0.0
		var insertFileParentPathDerivationDurationMS = 0.0
		var insertFileParentLookupDurationMS = 0.0
		var createMissingParentFolderDurationMS = 0.0
		var enqueueInsertCount = 0
		var enqueueInsertDurationMS = 0.0
	}

	final class ReplayFileAddPathMetricsCollector {
		private var metrics = ReplayFileAddPathMetrics()
		private var uniqueParentRelativePaths: Set<String> = []
		let isDetailedWallAttributionEnabled: Bool

		init(detailedWallAttributionEnabled: Bool = false) {
			self.isDetailedWallAttributionEnabled = detailedWallAttributionEnabled
		}

		func recordEligibilityCheck(eligible: Bool, durationMS: Double) {
			metrics.eligibilityCheckCount += 1
			if eligible {
				metrics.eligibilityEligibleCount += 1
			} else {
				metrics.eligibilityIneligibleCount += 1
			}
			guard isDetailedWallAttributionEnabled else { return }
			metrics.eligibilityCheckDurationMS += durationMS
			metrics.eligibilityCheckMaxDurationMS = max(metrics.eligibilityCheckMaxDurationMS, durationMS)
		}

		func recordEligibilityBatch(results: [Bool], durationMS: Double) {
			metrics.eligibilityCheckCount += results.count
			for eligible in results {
				if eligible {
					metrics.eligibilityEligibleCount += 1
				} else {
					metrics.eligibilityIneligibleCount += 1
				}
			}
			guard isDetailedWallAttributionEnabled else { return }
			metrics.eligibilityCheckDurationMS += durationMS
			metrics.eligibilityCheckMaxDurationMS = max(metrics.eligibilityCheckMaxDurationMS, durationMS)
		}

		func recordEligibilityBatchDiagnostics(_ diagnostics: CatalogRegularFileEligibilityBatchDiagnostics) {
			guard isDetailedWallAttributionEnabled else { return }
			metrics.eligibilityBatchRawInputCount += diagnostics.rawInputCount
			metrics.eligibilityBatchUniquePathCount += diagnostics.uniqueStandardizedPathCount
			metrics.eligibilityBatchResultCount += diagnostics.resultCount
			metrics.eligibilityPreparedFastPathAttemptCount += diagnostics.preparedRelativePathFastPathAttemptCount
			metrics.eligibilityPreparedFastPathUsedCount += diagnostics.preparedRelativePathFastPathUsedCount
			metrics.eligibilityPreparedFastPathFallbackCount += diagnostics.preparedRelativePathFastPathFallbackCount
			metrics.eligibilityPreparedFastPathInputCount += diagnostics.preparedRelativePathFastPathInputCount
			metrics.eligibilityPreparedFastPathGroupedEntryCount += diagnostics.preparedRelativePathFastPathGroupedEntryCount
			metrics.eligibilityPreparedFastPathParentReuseHitCount += diagnostics.preparedRelativePathFastPathParentReuseHitCount
			metrics.eligibilityPreparedFastPathParentReuseMissCount += diagnostics.preparedRelativePathFastPathParentReuseMissCount
			metrics.eligibilityBatchParentGroupCount += diagnostics.parentGroupCount
			metrics.eligibilityBatchMaxParentGroupSize = max(metrics.eligibilityBatchMaxParentGroupSize, diagnostics.maxParentGroupSize)
			metrics.eligibilityStandardizeAndGroupDurationMS += diagnostics.standardizeAndGroupDurationMS
			metrics.eligibilityParentProcessingDurationMS += diagnostics.parentProcessingDurationMS
			metrics.eligibilityDirectoryScanGroupCount += diagnostics.directoryScanGroupCount
			metrics.eligibilityDirectoryScanFailureGroupCount += diagnostics.directoryScanFailureGroupCount
			metrics.eligibilityDirectoryScanDurationMS += diagnostics.directoryScanDurationMS
			metrics.eligibilityDirectoryEntryCount += diagnostics.directoryEntryCount
			metrics.eligibilityEntriesMapBuildDurationMS += diagnostics.entriesMapBuildDurationMS
			metrics.eligibilityCanonicalParentResolveDurationMS += diagnostics.canonicalParentResolveDurationMS
			metrics.eligibilityPreparedIgnoreRulesGroupCount += diagnostics.preparedIgnoreRulesGroupCount
			metrics.eligibilityPreparedIgnoreRulesFailureGroupCount += diagnostics.preparedIgnoreRulesFailureGroupCount
			metrics.eligibilityPreparedIgnoreRulesDurationMS += diagnostics.preparedIgnoreRulesDurationMS
			metrics.eligibilityPreparedIgnoreRulesCacheHitDirectoryCount += diagnostics.preparedIgnoreRulesCacheHitDirectoryCount
			metrics.eligibilityPreparedIgnoreRulesCacheMissDirectoryCount += diagnostics.preparedIgnoreRulesCacheMissDirectoryCount
			metrics.eligibilityHierarchicalIgnoreCheckCount += diagnostics.hierarchicalIgnoreCheckCount
			metrics.eligibilityHierarchicalIgnoreNoOpParentGroupCount += diagnostics.hierarchicalIgnoreNoOpParentGroupCount
			metrics.eligibilityHierarchicalIgnoreSkippedLeafCheckCount += diagnostics.hierarchicalIgnoreSkippedLeafCheckCount
			metrics.eligibilityHierarchicalIgnoreDurationMS += diagnostics.hierarchicalIgnoreDurationMS
			metrics.eligibilityPrefixIgnoreCheckCount += diagnostics.prefixIgnoreCheckCount
			metrics.eligibilityPrefixIgnoreNoOpParentGroupCount += diagnostics.prefixIgnoreNoOpParentGroupCount
			metrics.eligibilityPrefixIgnoreSkippedLeafCheckCount += diagnostics.prefixIgnoreSkippedLeafCheckCount
			metrics.eligibilityPrefixIgnoreDurationMS += diagnostics.prefixIgnoreDurationMS
			metrics.eligibilityPrefixDirectLeafFastPathParentGroupCount += diagnostics.prefixDirectLeafFastPathParentGroupCount
			metrics.eligibilityPrefixDirectLeafFastPathUnsupportedParentGroupCount += diagnostics.prefixDirectLeafFastPathUnsupportedParentGroupCount
			metrics.eligibilityPrefixDirectLeafFastPathLeafCheckCount += diagnostics.prefixDirectLeafFastPathLeafCheckCount
			metrics.eligibilityPrefixDirectLeafFastPathIgnoredLeafCount += diagnostics.prefixDirectLeafFastPathIgnoredLeafCount
			metrics.eligibilityPrefixDirectLeafFastPathCandidatePatternCountTotal += diagnostics.prefixDirectLeafFastPathCandidatePatternCountTotal
			metrics.eligibilityPrefixDirectLeafFastPathCandidatePatternCountMax = max(
				metrics.eligibilityPrefixDirectLeafFastPathCandidatePatternCountMax,
				diagnostics.prefixDirectLeafFastPathCandidatePatternCountMax
			)
			metrics.eligibilityPrefixDirectLeafFastPathDurationMS += diagnostics.prefixDirectLeafFastPathDurationMS
			metrics.eligibilityPrefixParentRuleShapeGroupCount += diagnostics.prefixParentRuleShapeGroupCount
			metrics.eligibilityPrefixParentRuleDepthTotal += diagnostics.prefixParentRuleDepthTotal
			metrics.eligibilityPrefixParentRuleDepthMax = max(
				metrics.eligibilityPrefixParentRuleDepthMax,
				diagnostics.prefixParentRuleDepthMax
			)
			metrics.eligibilityPrefixParentActivePatternCountTotal += diagnostics.prefixParentActivePatternCountTotal
			metrics.eligibilityPrefixParentActivePatternCountMax = max(
				metrics.eligibilityPrefixParentActivePatternCountMax,
				diagnostics.prefixParentActivePatternCountMax
			)
			metrics.eligibilityPrefixParentHasNegativePatternGroupCount += diagnostics.prefixParentHasNegativePatternGroupCount
			metrics.eligibilitySingleFileFallbackUniquePathCount += diagnostics.singleFileFallbackUniquePathCount
			metrics.eligibilitySingleFileFallbackDurationMS += diagnostics.singleFileFallbackDurationMS
			metrics.eligibilityFallbackParentSymlinkCount += diagnostics.fallbackCounts.parentSymlinkComponent
			metrics.eligibilityFallbackDirectoryScanFailureCount += diagnostics.fallbackCounts.directoryScanFailure
			metrics.eligibilityFallbackMissingEntryCount += diagnostics.fallbackCounts.missingEntry
			metrics.eligibilityFallbackUnknownEntryMetadataCount += diagnostics.fallbackCounts.unknownEntryRegularFileMetadata
			metrics.eligibilityFallbackPreparedRulesFailureCount += diagnostics.fallbackCounts.preparedIgnoreRulesFailure
			metrics.eligibilityFallbackPreparedRuleMissCount += diagnostics.fallbackCounts.preparedRuleMiss
			metrics.eligibilityFallbackInvalidLeafNameCount += diagnostics.fallbackCounts.invalidLeafName
			metrics.eligibilityEligibleUniquePathCount += diagnostics.resultReasonCounts.eligible
			metrics.eligibilityIgnoredUniquePathCount += diagnostics.resultReasonCounts.ignored
			metrics.eligibilityMissingOrDirectoryUniquePathCount += diagnostics.resultReasonCounts.missingOrDirectory
			metrics.eligibilitySymbolicLinkUniquePathCount += diagnostics.resultReasonCounts.symbolicLink
			metrics.eligibilityNonRegularFileUniquePathCount += diagnostics.resultReasonCounts.nonRegularFile
			metrics.eligibilitySymlinkComponentUniquePathCount += diagnostics.resultReasonCounts.symlinkComponent
			metrics.eligibilityOutsideCanonicalRootUniquePathCount += diagnostics.resultReasonCounts.outsideCanonicalRoot
			metrics.eligibilityInvalidRelativePathUniquePathCount += diagnostics.resultReasonCounts.invalidRelativePath
			metrics.eligibilityOutsideRootUniquePathCount += diagnostics.resultReasonCounts.outsideRoot
		}

		func recordParentContext(cacheHit: Bool, durationMS: Double) {
			metrics.parentContextCallCount += 1
			if cacheHit {
				metrics.parentContextCacheHitCount += 1
			} else {
				metrics.parentContextCacheMissCount += 1
			}
			guard isDetailedWallAttributionEnabled else { return }
			metrics.parentContextDurationMS += durationMS
		}

		func recordParentContextOrderedReuse(hit: Bool) {
			if hit {
				metrics.parentContextOrderedReuseHitCount += 1
			} else {
				metrics.parentContextOrderedReuseMissCount += 1
			}
		}

		func recordParentContextParentStringBuild() {
			metrics.parentContextParentStringBuildCount += 1
		}

		func recordReplayPathMetadata(durationMS: Double) {
			metrics.replayPathMetadataCount += 1
			guard isDetailedWallAttributionEnabled else { return }
			metrics.replayPathMetadataDurationMS += durationMS
		}

		func recordHandleNewFile() {
			metrics.handleNewFileCallCount += 1
		}

		func recordHandleNewFileDuration(_ durationMS: Double) {
			guard isDetailedWallAttributionEnabled else { return }
			metrics.handleNewFileDurationMS += durationMS
			metrics.handleNewFileMaxDurationMS = max(metrics.handleNewFileMaxDurationMS, durationMS)
		}

		func recordFindExistingStandardizedFastPath() {
			metrics.findExistingStandardizedFastPathCount += 1
		}

		func recordFindExistingFileLookup(foundExisting: Bool, durationMS: Double = 0) {
			metrics.findExistingFileLookupCount += 1
			if foundExisting {
				metrics.existingFileCount += 1
			} else {
				metrics.newFileCount += 1
			}
			guard isDetailedWallAttributionEnabled else { return }
			metrics.findExistingFileLookupDurationMS += durationMS
		}

		func recordNewlyCreatedMarkerEmptySetSkip() {
			metrics.newlyCreatedMarkerEmptySetSkipCount += 1
		}

		func recordNewlyCreatedMarkerKeyBuild() {
			metrics.newlyCreatedMarkerKeyBuildCount += 1
		}

		func recordNewlyCreatedMarkerConsumed() {
			metrics.newlyCreatedMarkerConsumedCount += 1
		}

		func recordFileViewModelConstruction(durationMS: Double) {
			metrics.fileViewModelConstructionCount += 1
			guard isDetailedWallAttributionEnabled else { return }
			metrics.fileViewModelConstructionDurationMS += durationMS
		}

		func recordSelectionCallbackAttach(durationMS: Double) {
			guard isDetailedWallAttributionEnabled else { return }
			metrics.selectionCallbackAttachDurationMS += durationMS
		}

		func recordParentFolderLookup(parentRelativePath: String, result: FolderViewModel?, returnedRoot: Bool) {
			metrics.parentFolderLookupCallCount += 1
			recordUniqueParentRelativePath(parentRelativePath)
			if returnedRoot {
				metrics.parentFolderRootReturnCount += 1
			} else if result != nil {
				metrics.parentFolderLookupHitCount += 1
			} else {
				metrics.parentFolderLookupMissCount += 1
			}
		}

		func recordInsertFileCall() {
			metrics.insertFileCallCount += 1
		}

		func recordInsertFileDuration(_ durationMS: Double) {
			guard isDetailedWallAttributionEnabled else { return }
			metrics.insertFileDurationMS += durationMS
		}

		func recordInsertFileParentPathDerivation(parentRelativePath: String, durationMS: Double = 0) {
			metrics.insertFileParentPathDerivationCount += 1
			recordUniqueParentRelativePath(parentRelativePath)
			guard isDetailedWallAttributionEnabled else { return }
			metrics.insertFileParentPathDerivationDurationMS += durationMS
		}

		func recordInsertFileParentLookup(result: FolderViewModel?, durationMS: Double = 0) {
			if result != nil {
				metrics.insertFileParentLookupHitCount += 1
			} else {
				metrics.insertFileParentLookupMissCount += 1
			}
			guard isDetailedWallAttributionEnabled else { return }
			metrics.insertFileParentLookupDurationMS += durationMS
		}

		func recordCreateMissingParentFolderCall() {
			metrics.createMissingParentFolderCallCount += 1
		}

		func recordCreateMissingParentFolderCreated() {
			metrics.createMissingParentFolderCreatedCount += 1
		}

		func recordCreateMissingParentFolderDuration(_ durationMS: Double) {
			guard isDetailedWallAttributionEnabled else { return }
			metrics.createMissingParentFolderDurationMS += durationMS
		}

		func recordFileHierarchyInsertFile(durationMS: Double = 0) {
			metrics.fileHierarchyInsertFileCount += 1
			guard isDetailedWallAttributionEnabled else { return }
			metrics.fileHierarchyInsertFileDurationMS += durationMS
		}

		func recordEnqueueInsert(durationMS: Double) {
			metrics.enqueueInsertCount += 1
			guard isDetailedWallAttributionEnabled else { return }
			metrics.enqueueInsertDurationMS += durationMS
		}

		func snapshot() -> ReplayFileAddPathMetrics {
			var snapshot = metrics
			snapshot.uniqueParentPathCount = uniqueParentRelativePaths.count
			return snapshot
		}

		private func recordUniqueParentRelativePath(_ parentRelativePath: String) {
			uniqueParentRelativePaths.insert(parentRelativePath)
		}
	}

	struct RootReplayPerfSample: Equatable {
		let rootKey: String
		var passIndex: Int = 0
		var chunkIndexInPass: Int = 0
		var chunkCountInPass: Int = 0
		var coalesceDurationMS: Double = 0
		var preparationDurationMS: Double = 0
		var applyAwaitDurationMS: Double = 0
		var yieldDurationMSAfterChunk: Double = 0
		var interChunkSleepDurationMSAfterChunk: Double = 0
		let batchQueuedDeltaCount: Int
		let batchCoalescedDeltaCount: Int
		let batchDiscardedDeltaCount: Int
		let chunkDeltaCount: Int
		let fileAddedCount: Int
		let fileRemovedCount: Int
		let folderAddedCount: Int
		let folderRemovedCount: Int
		let modifiedCount: Int
		let folderModifiedCount: Int
		let folderModifiedCarriedDateCount: Int
		let folderModifiedFallbackStatSuccessCount: Int
		let folderModifiedSkippedNoDateCount: Int
		let fileAddPathMetrics: ReplayFileAddPathMetrics?
		let deltaLoopDurationMS: Double
		let pendingInsertRootCountBeforeFlush: Int
		let pendingInsertEntryCountBeforeFlush: Int
		let pendingInsertEntryCountForReplayedRootBeforeFlush: Int
		let pendingInsertEntryCountRemainingAfterFlush: Int
		let flushPendingInsertsDurationMS: Double
		let updateFolderStatesDurationMS: Double
		let usedFullRootFolderStateRefresh: Bool
		let dirtyFolderStateStartCount: Int
		let onRootFoldersChangedDurationMS: Double
		let usedIncrementalIndexCleanup: Bool
		let incrementalIndexCleanupDurationMS: Double
		let incrementalRemovedFolderCount: Int
		let incrementalRemovedFileCount: Int
		let incrementalIndexCleanupFallbackToRebuild: Bool
		let incrementalDescendantScanInvocationCount: Int
		let incrementalDescendantScannedFolderCandidateCount: Int
		let incrementalDescendantScannedFileCandidateCount: Int
		let incrementalCleanupUsedFallbackGlobalScan: Bool
		let rebuildDurationMS: Double?
		let rebuildCleanupCandidateSelectionDurationMS: Double?
		let rebuildCleanupFolderRemovalDurationMS: Double?
		let rebuildCleanupFileRemovalDurationMS: Double?
		let rebuildTraversalDurationMS: Double?
		let rebuildCleanupCandidateFolderKeys: Int?
		let rebuildCleanupCandidateFileKeys: Int?
		let rebuildUsedOwnershipFallback: Bool?
		let codeScanBatchInvocationCount: Int
		let codeScanBatchFileCount: Int
		let sliceRebaseBatchInvocationCount: Int
		let sliceRebaseCandidateCount: Int
		let invalidateSnapshotDurationMS: Double
		let totalApplyDurationMS: Double
	}

	struct RootReplayPassPerfSample: Equatable {
		let rootKey: String
		let passIndex: Int
		let chunkCount: Int
		let digestCount: Int
		let topologyChanged: Bool
		let onRootFoldersChangedInvocationCount: Int
		let snapshotInvalidationCount: Int
		let deltaAppliedPublisherInvocationCount: Int
		let codeScanBatchInvocationCount: Int
		let codeScanBatchFileCount: Int
		let sliceRebaseBatchInvocationCount: Int
		let sliceRebaseCandidateCount: Int
		let onRootFoldersChangedDurationMS: Double
		let invalidateSnapshotDurationMS: Double
		let finalizeDurationMS: Double
	}

	struct PendingInsertFlushInvocationPerfSample: Equatable {
		let parentGroupCountBeforeFlush: Int
		let entryCountBeforeFlush: Int
		let durationMS: Double
	}

	struct ImmediateReplayPerfSample: Equatable {
		let rootKey: String
		let passIndex: Int
		let chunkCount: Int
		let totalDeltaCount: Int
		let queuedDeltaCount: Int
		let coalescedDeltaCount: Int
		let discardedDeltaCount: Int
		let replayedChunks: [RootReplayPerfSample]
		let rootPass: RootReplayPassPerfSample?
		let pendingInsertFlushInvocations: [PendingInsertFlushInvocationPerfSample]
		let prepareAwaitDurationMS: Double?
		let totalDurationMS: Double

		var pendingInsertFlushTotalDurationMS: Double {
			pendingInsertFlushInvocations.reduce(0) { $0 + $1.durationMS }
		}

		var pendingInsertFlushTotalEntryCount: Int {
			pendingInsertFlushInvocations.reduce(0) { $0 + $1.entryCountBeforeFlush }
		}
	}

	struct DeltaReplayPerfSample: Equatable {
		struct ServiceFlushSample: Equatable {
			let rootKey: String
			let pendingRawEventCountBeforeFlush: Int
		}

		let aggressive: Bool
		let pendingRootCountAtStart: Int
		let pendingDeltaCountAtStart: Int
		let whileLoopPassCount: Int
		let totalRootPassCount: Int
		let totalChunkCount: Int
		let totalRootPassFinalizeDurationMS: Double
		let totalCoalescedDeltaCount: Int
		let totalDiscardedDeltaCount: Int
		let totalCoalesceDurationMS: Double
		let totalPreparationDurationMS: Double
		let totalApplyAwaitDurationMS: Double
		let totalYieldDurationMS: Double
		let totalInterChunkSleepDurationMS: Double
		let totalDeltaLoopDurationMS: Double
		let totalFlushPendingInsertsDurationMS: Double
		let totalUpdateFolderStatesDurationMS: Double
		let totalIncrementalIndexCleanupDurationMS: Double
		let totalIncrementalDescendantScanInvocationCount: Int
		let totalIncrementalDescendantScannedFolderCandidateCount: Int
		let totalIncrementalDescendantScannedFileCandidateCount: Int
		let totalOnRootFoldersChangedDurationMS: Double
		let totalOnRootFoldersChangedInvocationCount: Int
		let totalSnapshotInvalidationCount: Int
		let totalDeltaAppliedPublisherInvocationCount: Int
		let totalReplayCodeScanBatchInvocationCount: Int
		let totalReplaySliceRebaseBatchInvocationCount: Int
		let totalRebuildDurationMS: Double
		let totalCodeScanBatchFileCount: Int
		let totalSliceRebaseCandidateCount: Int
		let totalInvalidateSnapshotDurationMS: Double
		let preReplayServiceFlushes: [ServiceFlushSample]
		let postReplayServiceFlushes: [ServiceFlushSample]
		let replayedRoots: [RootReplayPerfSample]
		let rootPasses: [RootReplayPassPerfSample]
		let totalDurationMS: Double
	}

	private struct PendingInsertPerfSnapshot {
		let rootCount: Int
		let entryCount: Int
		let entryCountForRoot: Int
	}

	private var lastIndexRebuildPerfSample: IndexRebuildPerfSample?
	private var lastDeltaReplayPerfSample: DeltaReplayPerfSample?
	private var lastImmediateReplayPerfSample: ImmediateReplayPerfSample?
	private var currentRootReplayPerfSample: RootReplayPerfSample?
	private var pendingInsertFlushInvocationPerfSamples: [PendingInsertFlushInvocationPerfSample] = []
	private var isScheduledInsertFlushSuppressedForTesting = false
	private var isDetailedReplayWallAttributionEnabledForTesting = false
	private var deltaReplayChunkSizeOverride: Int?
	private var deltaReplayInterChunkDelayNanosecondsOverride: UInt64?
	#endif
	private var scanResultsTask: Task<Void, Never>? = nil
	private let alwaysReadableHomeDirectoryURL: URL
	
	init(alwaysReadableHomeDirectoryURL: URL? = nil) {
		self.alwaysReadableHomeDirectoryURL = (alwaysReadableHomeDirectoryURL ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
		// If you store sortMethod in user defaults, do that here
		if let loaded = SortMethod(rawValue: storedSortMethod) {
			currentSortMethod = loaded
		} else {
			currentSortMethod = .nameAscending
		}

		// Initialize runtime file-system flags from the JSON-backed source of truth
		// before any FileSystemService instances can be created for loaded folders.
		syncFileSystemPreferencesFromGlobalSettings()
		
		subscribeToScanProgress()
		subscribeToScanResults()
		subscribeToPartitionStoreSaves()
		subscribeToFileSystemPreferenceChanges()
		
	}
	
	deinit {
		// Cancel the subscriptions if this VM goes away
		scanProgressTask?.cancel()
		scanResultsTask?.cancel()
		autoCodemapSyncTask?.cancel()
		for task in sliceRebaseTasksByFullPath.values {
			task.cancel()
		}
		sliceRebaseTasksByFullPath.removeAll()
		sliceRebaseTaskIDsByFullPath.removeAll()
		workspaceSaveDebounceTask?.cancel()
		partitionStoreSaveCancellable?.cancel()
		fileSystemSettingsCancellable?.cancel()
	}
	
	func setWorkspaceManager(_ manager: WorkspaceManagerViewModel) {
		workspaceManager = manager
		currentWorkspaceID = manager.activeWorkspaceID
		manager.addWorkspaceDidSwitchListener(label: "fileManager") { [weak self] workspace in
			guard let self else { return }
			Task { @MainActor in
				await self.handleWorkspaceSwitch(to: workspace)
			}
		}
		if let activeWorkspace = manager.activeWorkspace {
			Task { @MainActor in
				await self.handleWorkspaceSwitch(to: activeWorkspace)
			}
		} else {
			currentSlicesByRoot.removeAll()
			requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
		}
	}
	
	/// Explicitly set the current workspace ID (used during workspace restoration to ensure timing)
	@MainActor
	func setCurrentWorkspaceID(_ id: UUID?) {
		currentWorkspaceID = id
	}
	
	@MainActor
	private func handleWorkspaceSwitch(to workspace: WorkspaceModel?) async {
		currentWorkspaceID = workspace?.id
		currentTabID = nil
		guard let workspaceID = workspace?.id else {
			currentSlicesByRoot.removeAll()
			requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
			return
		}
		
		var refreshed: [String: [String: PartitionStore.StoredSlices]] = [:]
		for root in rootFolders {
			let rootPath = root.standardizedFullPath
			let data = await partitionStore.load(
				forRoot: rootPath,
				scope: PartitionScope(workspaceID: workspaceID)
			)
			if !data.files.isEmpty {
				refreshed[rootPath] = data.files
			}
		}
		currentSlicesByRoot = refreshed
		requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
	}
	
	@MainActor
	func setActiveTabID(_ id: UUID?) {
		currentTabID = id
	}
	

	/// Subscribes to the indefinite progress stream from the actor.
	private func subscribeToScanProgress() {
		scanProgressTask = Task {
			let stream = codeScanActor.subscribeToProgress()
			for await (remaining, total) in stream {
				// Marshal to MainActor: RepoFileManagerViewModel is @MainActor
				await MainActor.run {
					self.updateScanProgress(remaining: remaining, total: total)
				}
			}
		}
	}
	
	private func updateScanProgress(remaining: Int, total: Int) {
		self.remainingScanCount = remaining
		self.totalFilesSeen     = total
		// No extra counter needed – updating the two @Published props is enough
	}
	
	/// Subscribes to the indefinite *results* stream from the actor.
	// Modified: single MainActor hop per result batch (reduces actor churn)
	private func subscribeToScanResults() {
		scanResultsTask = Task {
			for await batch in codeScanActor.subscribeToScanResults() {
				await MainActor.run {
					self.applyBatchCodeMapResults(batch)
				}
			}
		}
	}
	
	// New: apply an entire batch of FileAPI updates in one UI hop and emit a single update signal
	@MainActor
	private func applyBatchCodeMapResults(_ batch: [CodeScanActor.ScanResult]) {
		guard !batch.isEmpty else { return }
		let applyStart = CodeMapPerfRuntime.sharedPipelineStats.map { _ in CodeMapPerfRuntime.currentTime() }
		defer {
			if let applyStart {
				CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.batchApplyDuration, CodeMapPerfRuntime.durationSince(applyStart))
			}
		}

		var entriesByPath: [String: [(index: Int, result: CodeScanActor.ScanResult)]] = [:]
		entriesByPath.reserveCapacity(batch.count)
		for (index, result) in batch.enumerated() {
			let standardizedPath = StandardizedPath.absolute(result.fullPath)
			entriesByPath[standardizedPath, default: []].append((index: index, result: result))
		}
		let dedupedEntries = entriesByPath.sorted { lhs, rhs in
			let lhsLastIndex = lhs.value.last?.index ?? .min
			let rhsLastIndex = rhs.value.last?.index ?? .min
			return lhsLastIndex < rhsLastIndex
		}

		var updated = 0
		var shouldScheduleAutoSync = false
		for (standardizedPath, pathEntries) in dedupedEntries {
			if let fileVM = self.findFileByFullPath(standardizedPath) {
				guard let entry = pathEntries.reversed().first(where: { candidate in
					candidate.result.fileID == fileVM.id
				}) else { continue }
				let maybeApi = entry.result.fileAPI

				let wasTracked = codemapCapableAPIsByFullPath[standardizedPath] != nil
				let isSelected = selectedFileIDs.contains(fileVM.id)
				fileVM.setCodeMap(maybeApi)
				if let api = fileVM.fileAPI, fileVM.hasAcceptedCodeMap {
					codemapCapableAPIsByFullPath[standardizedPath] = api
					if !wasTracked || !isSelected {
						// New codemap data arrived or a non-selected file changed; auto sync may need refreshing.
						shouldScheduleAutoSync = true
					}
				} else {
					if wasTracked {
						// Previously tracked data vanished; ensure auto codemap dependencies stay in sync.
						shouldScheduleAutoSync = true
					}
					codemapCapableAPIsByFullPath.removeValue(forKey: standardizedPath)
				}
				updated += 1
			}
		}
		if updated > 0 {
			// Notify once per batch instead of per file
			codeMapUpdatePublisher.send(())
			if shouldScheduleAutoSync {
				// Skip rerunning auto sync when selected files simply refresh existing codemap data.
				scheduleAutoCodemapSync()
			}
		}
	}
	
// Modified: remove per-file publisher emission; batching now handled by applyBatchCodeMapResults(_:)
private func setCodeMapForScanResult(_ result: CodeScanActor.ScanResult) {
	// Update the matching FileViewModel, if it exists
	let standardizedPath = StandardizedPath.absolute(result.fullPath)
	if let fileVM = self.findFileByFullPath(standardizedPath) {
		guard fileVM.id == result.fileID else { return }
		let maybeApi = result.fileAPI
		fileVM.setCodeMap(maybeApi)
		if let api = fileVM.fileAPI, fileVM.hasAcceptedCodeMap {
			codemapCapableAPIsByFullPath[standardizedPath] = api
		} else {
			codemapCapableAPIsByFullPath.removeValue(forKey: standardizedPath)
		}
	}
}
	
	
	func cancelAllLoadingTasks() {
		discardDeferredInitialRootLoadScans()
		// Cancel the currently running folder loading task, if any.
		currentFolderLoadingTask?.cancel()
		currentFolderLoadingTask = nil
		
		// Remove any partially added folder.
		removeFolderBeingAdded()
		
		// Update the loading state.
		isLoading = false
	}

	func waitForAllLoadsToFinish() async {
		print("waitForAllLoadsToFinish() is now a no-op in the absence of tracked tasks.")
		await MainActor.run {
			self.isLoading = false
		}
	}
			// MARK: - Expansion Management

        // Current set of expanded folders is kept in `expandedFolderPaths`
		// Return snapshot of all expanded folders from the cached set
		func snapshotExpandedFolderFullPaths() -> [String] {
			Array(expandedFolderPaths)
		}
		
		// Legacy name kept for call sites
		func gatherExpandedFolderPaths() -> [String] {
			snapshotExpandedFolderFullPaths()
        }
		
		/// Return cached expanded folder paths relative to their roots
		func gatherExpandedFolderPathsRelative() -> [String] {
			var results: [String] = []
			for path in expandedFolderPaths {
				if let root = rootFolders.first(where: { path.hasPrefix($0.standardizedFullPath) }) {
					var rel = String(path.dropFirst(root.standardizedFullPath.count))
					if rel.hasPrefix("/") { rel.removeFirst() }
					results.append(rel)
				}
			}
			return results
		}
		

        /// Recursively register expansion tracking for the given folder and its subtree.
        private func registerExpansionTracking(for folder: FolderViewModel) {
                var visitedFolderIDs = Set<UUID>()
                registerExpansionTracking(for: folder, visitedFolderIDs: &visitedFolderIDs)
        }

        private func registerExpansionTracking(
                for folder: FolderViewModel,
                visitedFolderIDs: inout Set<UUID>
        ) {
                guard visitedFolderIDs.insert(folder.id).inserted else { return }
                if expansionSubscriptions[folder.id] == nil {
                        if folder.isExpanded {
                                expandedFolderPaths.insert(folder.standardizedFullPath)
							}
							expansionSubscriptions[folder.id] = folder.$isExpanded.sink { [weak self, weak folder] expanded in
                                guard let self = self, let folder = folder else { return }
                                if expanded {
									let inserted = self.expandedFolderPaths.insert(folder.standardizedFullPath).inserted
									if inserted, !self.isApplyingExpansionState {
										self.workspaceManager?.markWorkspaceDirty()
									}
								} else if self.expandedFolderPaths.remove(folder.standardizedFullPath) != nil {
									if !self.isApplyingExpansionState {
										self.workspaceManager?.markWorkspaceDirty()
									}
                                }
							}
                }
                for child in folder.children {
                        if case .folder(let subFolder) = child {
                                registerExpansionTracking(for: subFolder, visitedFolderIDs: &visitedFolderIDs)
                        }
                }
        }

        /// Remove any expansion tracking for the given folder subtree.
        private func unregisterExpansionTracking(for folder: FolderViewModel) {
                var visitedFolderIDs = Set<UUID>()
                unregisterExpansionTracking(for: folder, visitedFolderIDs: &visitedFolderIDs)
        }

        private func unregisterExpansionTracking(
                for folder: FolderViewModel,
                visitedFolderIDs: inout Set<UUID>
        ) {
                guard visitedFolderIDs.insert(folder.id).inserted else { return }
                expansionSubscriptions[folder.id]?.cancel()
                expansionSubscriptions.removeValue(forKey: folder.id)
                expandedFolderPaths.remove(folder.standardizedFullPath)
                for child in folder.children {
                        if case .folder(let subFolder) = child {
                                unregisterExpansionTracking(for: subFolder, visitedFolderIDs: &visitedFolderIDs)
                        }
                }
        }

        // Initialize expansion state from saved paths
	@MainActor
	func restoreExpansionState(from paths: [String]) async {
		#if DEBUG
		let restoreExpansionStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		var restoreExpansionOutcome = "completed"
		var restoreExpansionTargetFolders = 0
		var restoreExpansionCollapseCount = 0
		var restoreExpansionExpandCount = 0
		var restoreExpansionDidChange = false
		defer {
			WorkspaceRestorePerfLog.event(
				"selection.restoreExpansion",
				fields: [
					"requestedPaths": "\(paths.count)",
					"normalizedPaths": "\(paths.map { normalizeUserInputPath($0) }.filter { !$0.isEmpty }.count)",
					"targetFolders": "\(restoreExpansionTargetFolders)",
					"collapseCount": "\(restoreExpansionCollapseCount)",
					"expandCount": "\(restoreExpansionExpandCount)",
					"didChange": "\(restoreExpansionDidChange)",
					"outcome": restoreExpansionOutcome,
					"duration": restoreExpansionStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
		}
		#endif
		let normalizedPaths = paths.map { normalizeUserInputPath($0) }.filter { !$0.isEmpty }
		var targetFullPaths = Set<String>()
		
		for path in normalizedPaths {
			let standardized = (path as NSString).standardizingPath
			if path.hasPrefix("/") {
				if fileHierarchyIndex.foldersByFullPath[standardized] != nil {
					targetFullPaths.insert(standardized)
				}
			} else if let folder = findFolderByRelativePath(standardized) {
				targetFullPaths.insert(folder.standardizedFullPath)
			}
		}
		
		let currentExpanded = Set(expandedFolderPaths.map { ($0 as NSString).standardizingPath })
		let toCollapse = currentExpanded.subtracting(targetFullPaths)
		let toExpand = targetFullPaths.subtracting(currentExpanded)
		#if DEBUG
		restoreExpansionTargetFolders = targetFullPaths.count
		restoreExpansionCollapseCount = toCollapse.count
		restoreExpansionExpandCount = toExpand.count
		#endif
		guard !toCollapse.isEmpty || !toExpand.isEmpty else {
			#if DEBUG
			restoreExpansionOutcome = "noChange"
			#endif
			return
		}
		
		let chunkSize = 500
		let foldersByFullPath = fileHierarchyIndex.foldersByFullPath
		
		isApplyingExpansionState = true
		defer { isApplyingExpansionState = false }
		
		var didChange = false
		let collapseList = Array(toCollapse)
		if !collapseList.isEmpty {
			var index = 0
			while index < collapseList.count {
				guard !Task.isCancelled else {
					#if DEBUG
					restoreExpansionOutcome = "cancelled"
					#endif
					return
				}
				let end = min(index + chunkSize, collapseList.count)
				for path in collapseList[index..<end] {
					if let folder = foldersByFullPath[path], folder.isExpanded {
						folder.setExpanded(false)
						didChange = true
					}
				}
				index = end
				await Task.yield()
			}
		}
		
		let expandList = Array(toExpand)
		if !expandList.isEmpty {
			var index = 0
			while index < expandList.count {
				guard !Task.isCancelled else {
					#if DEBUG
					restoreExpansionOutcome = "cancelled"
					#endif
					return
				}
				let end = min(index + chunkSize, expandList.count)
				for path in expandList[index..<end] {
					if let folder = foldersByFullPath[path] {
						if expandParentChain(of: folder) {
							didChange = true
						}
					}
				}
				index = end
				await Task.yield()
			}
		}
		
		#if DEBUG
		restoreExpansionDidChange = didChange
		#endif
		if didChange {
			workspaceManager?.markWorkspaceDirty()
		}
	}
	
	// Helper method to ensure all parent folders are expanded
	private func expandParentChain(of folder: FolderViewModel) -> Bool {
		var didChange = false
		var current: FolderViewModel? = folder
		var seen = Set<UUID>()
		while let parentFolder = current, seen.insert(parentFolder.id).inserted {
			if !parentFolder.isExpanded {
				parentFolder.setExpanded(true)
				didChange = true
			}
			current = parentFolder.parent
		}
		return didChange
	}
	
@MainActor
// When refreshRootFolderStateAfterLoad is false, the caller must perform a later
// refreshRootFolderState() after any restored selection state has been applied.
func loadFolder(
	at url: URL,
	for workspace: WorkspaceModel,
	freshStart: Bool = false,
	rootKind: RootKind = .user,
	refreshRootFolderStateAfterLoad: Bool = true
) async throws {
		// Use stable string key for services/watchers (avoids URL key instability)
		let rootKey = self.rootKey(forPath: url.path)
		#if DEBUG
		let loadFolderTotalStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		let restorePerfRootKind = restorePerfRootKindName(rootKind)
		let restorePerfRootName = url.lastPathComponent
		#endif
		
		if freshStart {
			await unloadAllRootFolders()
		}
		
		repoFileManagerDebugLog("Loading folder (async): \(url.path)")
		isLoading = true
		
		if isFolderAlreadyLoaded(url) {
			repoFileManagerDebugLog("Folder already loaded: \(url.path)")
			isLoading = false
			#if DEBUG
			WorkspaceRestorePerfLog.event(
				"folderLoad.total",
				fields: [
					"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
					"rootKind": restorePerfRootKind,
					"rootName": restorePerfRootName,
					"outcome": "alreadyLoaded",
					"duration": loadFolderTotalStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
			#endif
			return
		}
		
		// Wrap the loading process in a cancellable Task and assign it to currentFolderLoadingTask
		currentFolderLoadingTask = Task {
			let rootPath = url.path
			let stdRootPath = (rootPath as NSString).standardizingPath
				do {
				self.currentWorkspaceID = workspace.id
				// Create the service up front, but remove it on error/cancel if needed.
				#if DEBUG
				let fsServiceInitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
				#endif
				let newFileSystemService = try await FileSystemService(
					path: rootPath,
					respectGitignore: self.respectGitignore,
					respectRepoIgnore: self.respectRepoIgnore,
					respectCursorignore: self.respectCursorignore,
					skipSymlinks: self.skipSymlinks,
					enableHierarchicalIgnores: self.enableHierarchicalIgnores
				)
				#if DEBUG
				WorkspaceRestorePerfLog.event(
					"folderLoad.fsServiceInit",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"rootKind": restorePerfRootKind,
						"rootName": restorePerfRootName,
						"duration": fsServiceInitStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				#endif
				// Track the service with stable root key
				fileSystemServices[rootKey] = newFileSystemService
				await deferredReplayBuffer.clearRoot(rootKey)
				
				// Prepare a root folder VM but do *not* finalize it if we're canceled
				#if DEBUG
				let rootVMInitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
				#endif
				let rootFolder = Folder(name: url.lastPathComponent, path: url.path, modificationDate: Date())
				// For _git_data system root: use dateNewest sort override so newest items appear first
				let isGitDataSystemRoot = (rootKind == .supplementalSystem) && url.lastPathComponent == "_git_data"
				let sortOverride: SortMethod? = isGitDataSystemRoot ? .dateNewest : nil
				let rootFolderVM = FolderViewModel(
					folder: rootFolder,
					rootPath: rootPath,
					isExpanded: true,
					sortMethod: self.currentSortMethod,
					sortMethodOverride: sortOverride,
					isSystemRoot: (rootKind == .supplementalSystem)
				)
				
				// Stash it in our "being added" reference and also the rootFolders array
				rootFolders.append(rootFolderVM)
				folderBeingAdded = rootFolderVM
				// Ensure the root appears in the absolute-path index for O(1) lookups
				fileHierarchyIndex.insertFolder(rootFolderVM, rootKey: rootKey)
				#if DEBUG
				WorkspaceRestorePerfLog.event(
					"folderLoad.rootVMInit",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"rootKind": restorePerfRootKind,
						"rootName": restorePerfRootName,
						"duration": rootVMInitStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				#endif
				
				await Task.yield()
				
				// Actually load children from disk
				#if DEBUG
				let loadContentsStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
				#endif
				try await loadContentsRecursively(
					for: newFileSystemService,
					rootFolder: rootFolderVM,
					url: url,
					rootPath: rootPath,
					workspace: workspace
				)
				#if DEBUG
				WorkspaceRestorePerfLog.event(
					"folderLoad.loadContentsRecursively",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"rootKind": restorePerfRootKind,
						"rootName": restorePerfRootName,
						"duration": loadContentsStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				#endif
				
				// Check for cancellation immediately after loading contents
				try Task.checkCancellation()
				
				// After loading completes (no cancellation or errors)
				#if DEBUG
				let postProcessStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
				#endif
				removeEmptyFolders(in: rootFolderVM, allowSorting: false)
				// Keep sorting localized to expanded nodes to avoid full-tree cost.
				// Use recomputeCheckbox: false since refreshRootFolderState() will compute once at the end.
				rootFolderVM.sortChildrenIfNeeded(currentSortMethod, recomputeCheckbox: false, recursion: .expandedOnly)
				registerExpansionTracking(for: rootFolderVM)
				
				// No longer need to register subfolders with ExpansionManager
				// The expansion state is stored directly in each FolderViewModel
				
				if refreshRootFolderStateAfterLoad {
					refreshRootFolderState()
				}
				if rootKind == .user {
					reorderRootFolders(to: workspace.repoPaths)
				}
				loadedRootPaths.insert(url.path)
				
				// Ensure path-matching snapshot reflects the fully populated index before any lookups
				invalidateStaticSnapshot(forRootFullPath: rootFolderVM.standardizedFullPath)
				#if DEBUG
				WorkspaceRestorePerfLog.event(
					"folderLoad.postProcess",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"rootKind": restorePerfRootKind,
						"rootName": restorePerfRootName,
						"refreshRootFolderStateAfterLoad": "\(refreshRootFolderStateAfterLoad)",
						"duration": postProcessStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				#endif
				
				// Start watchers & subscribe to deltas only after successful load
				#if DEBUG
				let watcherStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
				#endif
				let rootReplayIngressGeneration = advanceRootReplayIngressGeneration(forRootKey: rootKey)
				await deferredReplayBuffer.registerActiveRootGeneration(rootReplayIngressGeneration, forRootKey: rootKey)
				await newFileSystemService.startWatchingForChanges()
				let changesPublisher = await newFileSystemService.publisherForChanges()
				self.watchers[rootKey] = makeFileSystemChangesCancellable(
					changesPublisher: changesPublisher,
					rootKey: rootKey,
					rootReplayIngressGeneration: rootReplayIngressGeneration
				)
				#if DEBUG
				WorkspaceRestorePerfLog.event(
					"folderLoad.watcherStart",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"rootKind": restorePerfRootKind,
						"rootName": restorePerfRootName,
						"duration": watcherStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				#endif

				// Migrate all legacy partition files from .repoprompt/ to Application Support
				#if DEBUG
				let partitionLoadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
				#endif
				await self.partitionStore.migrateAllLegacyPartitions(forRoot: stdRootPath)

				let partitionData = await self.partitionStore.load(
					forRoot: stdRootPath,
					scope: PartitionScope(workspaceID: workspace.id, tabID: self.currentTabID)
				)
				if partitionData.files.isEmpty {
					self.currentSlicesByRoot.removeValue(forKey: stdRootPath)
				} else {
					self.currentSlicesByRoot[stdRootPath] = partitionData.files
				}
				self.requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
				#if DEBUG
				WorkspaceRestorePerfLog.event(
					"folderLoad.partitionLoad",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"rootKind": restorePerfRootKind,
						"rootName": restorePerfRootName,
						"partitionFiles": "\(partitionData.files.count)",
						"duration": partitionLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				#endif
				
				// ─────────────────────────────────────────────────────────────────
				// Kick off or defer the initial CodeMap scan for this newly loaded root.
				// Workspace switches defer this until after the switch-end metric is logged.
				// ─────────────────────────────────────────────────────────────────
				if self.codeScanEnabled, rootKind == .user {
					self.enqueueOrDeferInitialRootLoadScan(for: rootFolderVM)
				}
				
				// Mark successful completion
				isLoading = false 
				folderBeingAdded = nil
				
				// Notify observers that this folder has completely finished loading.
				// If refreshRootFolderStateAfterLoad is false, observers must not assume
				// restored checkbox state is current until the caller's later refresh.
				folderDidFinishLoadingPublisher.send(rootFolderVM)
				#if DEBUG
				WorkspaceRestorePerfLog.event(
					"folderLoad.total",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"rootKind": restorePerfRootKind,
						"rootName": restorePerfRootName,
						"outcome": "success",
						"duration": loadFolderTotalStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				#endif
				
			} catch {
				removeDeferredInitialRootLoadScanRoot(stdRootPath)
				// If we had created watchers or stored the service, remove them now
				// Use stable root key for consistent removal
				if let service = fileSystemServices.removeValue(forKey: rootKey) {
					await service.stopWatchingForChanges()
				}
				watchers.removeValue(forKey: rootKey)?.cancel()
				await deferredReplayBuffer.unregisterActiveRootGeneration(forRootKey: rootKey)
				
				self.currentSlicesByRoot.removeValue(forKey: stdRootPath)
				self.requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
				
				// Remove partial root folder if it was added
				removeFolderBeingAdded()
				
				#if DEBUG
				WorkspaceRestorePerfLog.event(
					"folderLoad.total",
					fields: [
						"workspaceID": WorkspaceRestorePerfLog.shortID(workspace.id),
						"rootKind": restorePerfRootKind,
						"rootName": restorePerfRootName,
						"outcome": error is CancellationError ? "cancelled" : "error",
						"duration": loadFolderTotalStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
					]
				)
				#endif
				if error is CancellationError {
					print("Load folder cancelled for: \(url.path)")
				} else {
					print("Failed to load folder: \(error)")
					self.error = .failedToLoadFolder(error)
				}
				isLoading = false
				throw error
			}
		}
		
		// Await the loading task to propagate errors/cancellation
		try await currentFolderLoadingTask?.value
		currentFolderLoadingTask = nil
	}
	
	func onAllFoldersLoaded() async {
		await rescanAllFilesIfLoaded()
	}

	@MainActor
	func loadSupplementalRoot(
		at url: URL,
		for workspace: WorkspaceModel,
		refreshRootFolderStateAfterLoad: Bool = true
	) async throws {
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
		try await loadFolder(
			at: url,
			for: workspace,
			freshStart: false,
			rootKind: .supplementalSystem,
			refreshRootFolderStateAfterLoad: refreshRootFolderStateAfterLoad
		)
	}

	@MainActor
	func ensureGitDataRootLoaded(
		workspace: WorkspaceModel,
		workspaceManager: WorkspaceManagerViewModel,
		refreshRootFolderStateAfterLoad: Bool = true
	) async {
		guard workspace.isSystemWorkspace == false else {
			return
		}
		let gitDataURL = workspaceManager.gitDataDirectory(for: workspace)
		if isFolderAlreadyLoaded(gitDataURL) {
			return
		}
		do {
			try await loadSupplementalRoot(
				at: gitDataURL,
				for: workspace,
				refreshRootFolderStateAfterLoad: refreshRootFolderStateAfterLoad
			)
		} catch {
			print("Failed to load _git_data root: \(error)")
		}
	}
	
	private func removeFolderBeingAdded() {
		if let folder = folderBeingAdded {
			let stdPath = folder.standardizedFullPath
			removeDeferredInitialRootLoadScanRoot(stdPath)
			unregisterExpansionTracking(for: folder)
			// Remove it from the main rootFolders array
			self.rootFolders.removeAll { $0.id == folder.id }
			// Notify WorkspaceManager so it drops the path from the workspace model
			// and persists the change.  This prevents the cancelled folder from
			// re-appearing on next launch / save.
			onRootFolderUnloadRequested.send(folder.fullPath)

			// Remove the root from the absolute-path index to avoid stale entries
			fileHierarchyIndex.removeFolder(forKey: stdPath, expectedRootKey: stdPath)
			
			// Clean up per-root generation entry and invalidate snapshot
			removeHierarchyGenerationEntry(forRootFullPath: stdPath)
			invalidateStaticSnapshot(forRootFullPath: nil)

			folderBeingAdded = nil
		}
	}
	

	// MARK: - New full‑path‑only implementation
	private func loadContentsRecursively(
		for fileSystemService: FileSystemService,
		rootFolder: FolderViewModel,
		url: URL,
		rootPath: String,
		workspace: WorkspaceModel
	) async throws {
		let canonicalRootPath = (rootPath as NSString).standardizingPath
		let expandedSet = Set(workspace.workingExpandedFolders.map { ($0 as NSString).standardizingPath })
		var depthLimit = Int.max
		let chunkedStream = await fileSystemService.loadContentsInChunks(of: url, chunkSize: 200)
		
		let isGitDataRoot = rootFolder.isSystemRoot && rootFolder.name == "_git_data"

		@inline(__always)
		func fullPath(forRelativePath rel: String) -> String {
			guard !rel.isEmpty else { return canonicalRootPath }
			if canonicalRootPath.hasSuffix("/") {
				return canonicalRootPath + rel
			}
			return canonicalRootPath + "/" + rel
		}

		@inline(__always)
		func parentRelativePath(of rel: String) -> String {
			guard let idx = rel.lastIndex(of: "/") else { return "" }
			return String(rel[..<idx])
		}

		@inline(__always)
		func name(from rel: String) -> String {
			guard let idx = rel.lastIndex(of: "/") else { return rel }
			return String(rel[rel.index(after: idx)...])
		}

		// Staging maps keyed by absolute full path
		var stagedFoldersByFullPath: [String: FolderViewModel] = [:]
		var stagedFilesByFullPath: [String: FileViewModel] = [:]
		// Group children by their parent full path for one-shot addChildrenBatch
		var groupedChildrenByParent: [String: [FileSystemItemType]] = [:]

		@inline(__always)
		func stageChunk(_ chunk: FSPreparedChunk) {
			// We are on @MainActor (class is @MainActor)
			// 1) Stage Folders
			for folderDTO in chunk.folders {
				let relPath = folderDTO.relativePath
				guard !relPath.isEmpty else { continue }
				
				let folderFullPath = fullPath(forRelativePath: relPath)
				let parentRel = parentRelativePath(of: relPath)
				
				let parentFullPath = parentRel.isEmpty
					? canonicalRootPath
					: fullPath(forRelativePath: parentRel)
				let allowAutoExpand = depthLimit == .max || folderDTO.hierarchy < depthLimit
				let initialExpand = allowAutoExpand && expandedSet.contains(folderFullPath)
				let folderName = relPath.isEmpty ? rootFolder.name : name(from: relPath)

				// Avoid duplicate VM creation for the same folder path
				if stagedFoldersByFullPath[folderFullPath] == nil {
					let folder = Folder(
						name: folderName,
						path: folderFullPath,
						modificationDate: .distantPast
					)
					// For _git_data subtree: use dateNewest sort override so newest items appear first
					let sortOverride: SortMethod? = isGitDataRoot ? .dateNewest : nil
					let folderVM = FolderViewModel(
						folder: folder,
						rootPath: canonicalRootPath,
						hierarchyLevel: folderDTO.hierarchy,
						isExpanded: initialExpand,
						sortMethod: currentSortMethod,
						sortMethodOverride: sortOverride,
						relativePathOverride: relPath
					)
					stagedFoldersByFullPath[folderFullPath] = folderVM
				}
				// Stage the relationship only (defer attaching to UI)
				groupedChildrenByParent[parentFullPath, default: []].append(.folder(stagedFoldersByFullPath[folderFullPath]!))
			}

			// 2) Stage Files
			for fileDTO in chunk.files {
				let relPath = fileDTO.relativePath
				guard !relPath.isEmpty else { continue }
				let fileFullPath = fullPath(forRelativePath: relPath)
				let parentRel = parentRelativePath(of: relPath)
				
				let parentFullPath = parentRel.isEmpty
					? canonicalRootPath
					: fullPath(forRelativePath: parentRel)
				let fileName = relPath.isEmpty ? "" : name(from: relPath)
				if stagedFilesByFullPath[fileFullPath] == nil {
					let file = File(
						name: fileName,
						path: fileFullPath,
						modificationDate: .distantPast
					)
					let fileVM = FileViewModel(
						file: file,
						rootPath: canonicalRootPath,
						hierarchyLevel: fileDTO.hierarchy,
						rootIdentifier: rootFolder.id,
						rootFolderPath: rootFolder.fullPath,
						fileSystemService: fileSystemService,
						relativePathOverride: relPath
					)
					attachSelectionCallback(to: fileVM)
					stagedFilesByFullPath[fileFullPath] = fileVM
				}
				// Stage the relationship only (defer attaching to UI)
				groupedChildrenByParent[parentFullPath, default: []].append(.file(stagedFilesByFullPath[fileFullPath]!))
			}
		}

		for try await event in chunkedStream {
			if Task.isCancelled { return }

			switch event {
			case .totalFileCount(let count):
				depthLimit = (count < 100)    ? .max
					: (count < 500)    ? 5
					: (count < 1_000)  ? 4
					: (count < 2_500)  ? 3
					: (count < 5_000) ? 2
					: 1
			case .preparedItems(let chunk):
				// Stage without touching UI
				stageChunk(chunk)
				await Task.yield()
			case .items(let legacy):
				// Convert legacy to a single FSPreparedChunk then stage once
				var folders: [FSItemDTO] = []
				var files: [FSItemDTO] = []
				folders.reserveCapacity(legacy.count)
				files.reserveCapacity(legacy.count)

				for (item, pathComponents) in legacy {
					guard !pathComponents.isEmpty else { continue }
					let relPath = pathComponents.joined(separator: "/")
					let hierarchy = pathComponents.count - 1
					if item is Folder {
						folders.append(
							FSItemDTO(
								relativePath: relPath,
								isDirectory: true,
								hierarchy: hierarchy
							)
						)
					} else if item is File {
						files.append(
							FSItemDTO(
								relativePath: relPath,
								isDirectory: false,
								hierarchy: hierarchy
							)
						)
					}
				}

				if !folders.isEmpty || !files.isEmpty {
					stageChunk(FSPreparedChunk(folders: folders, files: files))
					await Task.yield()
				}
			}
		}

		// Commit staged content in a single pass to minimize UI thrash
		// ➊ Index all staged VMs first (so parents can be found even if not yet attached)
		fileHierarchyIndex.insertFolder(rootFolder, rootKey: canonicalRootPath)
		for (folderFullPath, folderVM) in stagedFoldersByFullPath {
			fileHierarchyIndex.insertFolder(folderVM, rootKey: canonicalRootPath)
		}
		for (fileFullPath, fileVM) in stagedFilesByFullPath {
			fileHierarchyIndex.insertFile(fileVM, rootKey: canonicalRootPath)
		}

		// ➋ Attach children to parents – create missing parent chains once
		var parentsProcessed = 0
		let yieldEveryParents = 100
		for (parentFullPathRaw, children) in groupedChildrenByParent {
			let parentFullPath = parentFullPathRaw
			// If the parent is not the root and is not materialized yet, create its chain under root
			if findFolderByFullPath(parentFullPath) == nil && parentFullPath != canonicalRootPath {
				if parentFullPath.hasPrefix(canonicalRootPath) {
					var rel = String(parentFullPath.dropFirst(canonicalRootPath.count))
					if rel.hasPrefix("/") { rel.removeFirst() }
					if !rel.isEmpty {
						createMissingParentFolder(parentPath: rel, under: rootFolder)
					}
				}
			}
			let parentVM = findFolderByFullPath(parentFullPath) ?? rootFolder

			// NOTE:
			// During initial load we attach unsorted and defer sorting to a later targeted pass.
			var seen = Set<UUID>()
			let uniqueChildren: [FileSystemItemType] = children.compactMap { item in
				switch item {
				case .file(let file):
					return seen.insert(file.id).inserted ? item : nil
				case .folder(let folder):
					if folder.id == parentVM.id || folder.standardizedFullPath == parentVM.standardizedFullPath {
						return nil
					}
					return seen.insert(folder.id).inserted ? item : nil
				}
			}
			guard !uniqueChildren.isEmpty else { continue }
			parentVM.addChildrenBatch(
				uniqueChildren,
				options: .init(
					recomputeCheckbox: false,
					ensureSorted: false,
					rebuildChildren: true,
					assumeAllUnchecked: true
				)
			)

			parentsProcessed += 1
			if parentsProcessed % yieldEveryParents == 0 {
				await Task.yield()
			}

		}
	}
	
	func getFileSystemService(for path: String) -> FileSystemService? {
		let full = (normalizeUserInputPath(path) as NSString).standardizingPath
		
		// 1) Exact root hit
		let exactKey = rootKey(forPath: full)
		if let exact = fileSystemServices[exactKey] {
			return exact
		}
		
		// 2) File-under-root hit: choose longest rootKey that contains `full`
		return fileSystemServices
			.filter { full.isDescendant(of: $0.key) }
			.max(by: { $0.key.count < $1.key.count })?
			.value
	}
	
	private func unloadRootFolder(for url: URL) async {
		let standardizedPath = (url.path as NSString).standardizingPath
		guard let folder = rootFolders.first(where: { $0.standardizedFullPath == standardizedPath }) else {
			return
		}
		await self.unloadRootFolder(folder)
	}
	
	/*
	@MainActor
	public func fullRefresh() async {
		self.error = nil
		let rootURLs = self.rootFolders.map { URL(fileURLWithPath: $0.fullPath) }
		
		for url in rootURLs {
			await self.unloadRootFolder(for: url)
		}
		
		for url in rootURLs {
			try? await self.loadFolder(at: url, for: nil, freshStart: false)
		}
		
		//self.refreshRootFolderState()
		self.onRootFoldersChanged?()
	}
	*/
	
	// Place this property along with other publishers near the top of the class
	public var onRequestRefresh: (() -> Void)?
	
	func requestRefresh() {
		onRequestRefresh?()
	}

	@MainActor
	func requestFileSystemSettingsRefresh() {
		forceReloadOnNextFileSystemSettingsRefresh = true
		requestRefresh()
	}

	@discardableResult
	func refreshContents(model: WorkspaceModel, forceRefresh: Bool = false) async -> Bool {
		self.error = nil
		var didStructurallyRefreshRoots = false

		let forceReloadForSettings = forceReloadOnNextFileSystemSettingsRefresh
		forceReloadOnNextFileSystemSettingsRefresh = false

		// Iterate in deterministic order: user roots (in rootFolders order) then system roots
		// This prevents non-deterministic ordering from dictionary iteration
		let orderedRoots = rootFolders.filter { !$0.isSystemRoot } + rootFolders.filter { $0.isSystemRoot }

		for rootFolder in orderedRoots {
			let rootKey = self.rootKey(forPath: rootFolder.fullPath)
			guard let service = fileSystemServices[rootKey] else {
				continue
			}

			do {
				let shouldForceReload = forceRefresh || forceReloadForSettings
				if shouldForceReload {
					didStructurallyRefreshRoots = true
					let rootKind: RootKind = rootFolder.isSystemRoot ? .supplementalSystem : .user
					let rootURL = URL(fileURLWithPath: rootFolder.fullPath)
					await self.unloadRootFolder(for: rootURL)
					try await self.loadFolder(at: rootURL, for: model, freshStart: false, rootKind: rootKind)
					continue
				}

				try await service.updateRespectGitignore(self.respectGitignore)
				try await service.updateRespectRepoIgnore(self.respectRepoIgnore)
				try await service.updateRespectCursorignore(self.respectCursorignore)
				await service.updateSkipSymlinks(self.skipSymlinks)
				await service.updateEnableHierarchicalIgnores(self.enableHierarchicalIgnores)
				try await service.refreshIgnoreRules()
				
				// Use durable change tracking instead of ephemeral flag
				let ignoreChange = await service.takePendingIgnoreRulesChange()
				
				if ignoreChange != nil {
					didStructurallyRefreshRoots = true
					let rootKind: RootKind = rootFolder.isSystemRoot ? .supplementalSystem : .user
					let rootURL = URL(fileURLWithPath: rootFolder.fullPath)
					await self.unloadRootFolder(for: rootURL)
					try await self.loadFolder(at: rootURL, for: model, freshStart: false, rootKind: rootKind)
				}
			} catch {
				print("Error updating FileSystemService flags: \(error)")
			}
		}
		
		// Keep UI and internal order in sync with the workspace config.
		let didReorderRoots = reorderRootFolders(to: model.repoPaths)
		
		// If this refresh genuinely unloaded/reloaded roots, emit one final broad
		// invalidation after the in-place work settles. Pure soft refreshes and
		// no-op reorders should not publish root-list churn.
		if didStructurallyRefreshRoots && !didReorderRoots {
			self.onRootFoldersChanged?()
		}
		await rescanAllFilesIfLoaded()
		return didStructurallyRefreshRoots || didReorderRoots
	}
	
	// ------------------------------------------------------------------
// MARK: Mention support
// ------------------------------------------------------------------
	/// Toggles selection for a file or *entire* folder by relative path.
	/// Called by the "@-mention" text editor when a token is committed.
	@MainActor
	public func togglePath(_ relativePath: String) {
		if let file = findFileByRelativePath(relativePath) {
			toggleFile(file, fromSearch: true)
			refreshRootFolderState()
			return
		}
		if let folder = findFolderByRelativePath(relativePath) {
			folder.forceCheckRecursive()
			refreshRootFolderState()
		}
	}

	// ------------------------------------------------------------------
	// MARK: Explicit helpers for mention tokens (add / remove)
	// ------------------------------------------------------------------
	/// Ensures the given path is **selected/checked**.
	/// If it is already selected nothing happens.
	@MainActor
	public func selectPath(_ relativePath: String, kind: MentionKind?) {
		let normalizedPath      = normalizeUserInputPath(relativePath)
		let standardizedPath    = (normalizedPath as NSString).standardizingPath
		let isAbsolute          = standardizedPath.hasPrefix("/")
		
		// Resolve candidate VMs depending on path kind
		let fileVM:   FileViewModel?   = isAbsolute
			? findFileByFullPath(standardizedPath)
			: findFileByRelativePath(standardizedPath)
		let folderVM: FolderViewModel? = isAbsolute
			? findFolderByFullPath(standardizedPath)
			: findFolderByRelativePath(standardizedPath)
		
		// 1️⃣ Explicit kind supplied ------------------------------------------------
		if let kind = kind {
			switch kind {
			case .folder:
				if let folder = folderVM, folder.checkboxState != .checked {
					folder.forceCheckRecursive()
					refreshRootFolderState()
				}
				return
			case .file:
				if let file = fileVM, !file.isChecked {
					setFileToggled(file, isToggled: true)
					refreshRootFolderState()
				}
				return
			case .skill:
				return
			}
		}
		
		// 2️⃣ Kind not supplied – best-effort inference -----------------------------
		if let file = fileVM, !file.isChecked {
			setFileToggled(file, isToggled: true)
			refreshRootFolderState()
		} else if let folder = folderVM, folder.checkboxState != .checked {
			folder.forceCheckRecursive()
			refreshRootFolderState()
		}
	}

	/// Removes the selection for the given path when it is currently selected.
	@MainActor
	public func deselectPath(_ relativePath: String, kind: MentionKind?) {
		let normalizedPath      = normalizeUserInputPath(relativePath)
		let standardizedPath    = (normalizedPath as NSString).standardizingPath
		let isAbsolute          = standardizedPath.hasPrefix("/")
		
		let fileVM:   FileViewModel?   = isAbsolute
			? findFileByFullPath(standardizedPath)
			: findFileByRelativePath(standardizedPath)
		let folderVM: FolderViewModel? = isAbsolute
			? findFolderByFullPath(standardizedPath)
			: findFolderByRelativePath(standardizedPath)
		
		// 1️⃣ Explicit kind supplied ------------------------------------------------
		if let kind = kind {
			switch kind {
			case .folder:
				if let folder = folderVM, folder.checkboxState != .unchecked {
					setFolderStateOnSubtree(folder, newState: .unchecked)
					refreshRootFolderState()
				}
				return
			case .file:
				if let file = fileVM, file.isChecked {
					setFileToggled(file, isToggled: false)
					refreshRootFolderState()
				}
				return
			case .skill:
				return
			}
		}
		
		// 2️⃣ Kind not supplied – inference ----------------------------------------
		if let file = fileVM, file.isChecked {
			setFileToggled(file, isToggled: false)
			refreshRootFolderState()
		} else if let folder = folderVM, folder.checkboxState != .unchecked {
			setFolderStateOnSubtree(folder, newState: .unchecked)
			refreshRootFolderState()
		}
	}
	
	/// Rebuilds the index *only* for the given root folder: removes old references, then re-walks to add fresh entries.
	@MainActor
	private func rebuildFileHierarchyIndex(for rootFolder: FolderViewModel) {
		let signpost = RepoFileReplayPerf.begin("rebuildFileHierarchyIndex")
		defer { RepoFileReplayPerf.end("rebuildFileHierarchyIndex", signpost) }
		let rootKey = rootFolder.standardizedFullPath
		#if DEBUG
		let totalStartMS = debugPerfTimestampMS()
		let totalFolderKeysBefore = fileHierarchyIndex.foldersByFullPath.count
		let totalFileKeysBefore = fileHierarchyIndex.filesByFullPath.count
		let totalCodemapKeysBefore = codemapCapableAPIsByFullPath.count
		let ownedFolderKeysBefore = fileHierarchyIndex.folderPathsByRoot[rootKey]?.count ?? 0
		let ownedFileKeysBefore = fileHierarchyIndex.filePathsByRoot[rootKey]?.count ?? 0

		let candidateStartMS = debugPerfTimestampMS()
		#endif
		let cleanup = rootReferenceCleanupPlan(for: rootFolder)
		#if DEBUG
		let cleanupCandidateSelectionDurationMS = debugPerfElapsedMS(since: candidateStartMS)
		let fileRemovalStartMS = debugPerfTimestampMS()
		#endif
		for filePath in cleanup.filePaths {
			codemapCapableAPIsByFullPath.removeValue(forKey: filePath)
		}
		#if DEBUG
		let cleanupFileRemovalDurationMS = debugPerfElapsedMS(since: fileRemovalStartMS)

		let folderRemovalStartMS = debugPerfTimestampMS()
		#endif
		fileHierarchyIndex.removeOwnedEntries(
			forRootKey: cleanup.rootKey,
			folderPaths: cleanup.folderPaths,
			filePaths: cleanup.filePaths
		)
		#if DEBUG
		let cleanupFolderRemovalDurationMS = debugPerfElapsedMS(since: folderRemovalStartMS)

		var stats = ReindexTraversalStats()
		let traversalStartMS = debugPerfTimestampMS()
		reindexFolderRecursively(rootFolder, into: &fileHierarchyIndex, rootKey: rootKey, stats: &stats)
		let reindexTraversalDurationMS = debugPerfElapsedMS(since: traversalStartMS)

		lastIndexRebuildPerfSample = IndexRebuildPerfSample(
			rootKey: rootKey,
			totalFolderKeysBefore: totalFolderKeysBefore,
			totalFileKeysBefore: totalFileKeysBefore,
			totalCodemapKeysBefore: totalCodemapKeysBefore,
			ownedFolderKeysBefore: ownedFolderKeysBefore,
			ownedFileKeysBefore: ownedFileKeysBefore,
			cleanupCandidateFolderKeys: cleanup.folderPaths.count,
			cleanupCandidateFileKeys: cleanup.filePaths.count,
			usedOwnershipFallback: cleanup.usedFallbackGlobalScan,
			cleanupCandidateSelectionDurationMS: cleanupCandidateSelectionDurationMS,
			cleanupFolderRemovalDurationMS: cleanupFolderRemovalDurationMS,
			cleanupFileRemovalDurationMS: cleanupFileRemovalDurationMS,
			reindexTraversalDurationMS: reindexTraversalDurationMS,
			reindexVisitedFolderCount: stats.visitedFolderCount,
			reindexVisitedFileCount: stats.visitedFileCount,
			totalDurationMS: debugPerfElapsedMS(since: totalStartMS)
		)
		#else
		reindexFolderRecursively(rootFolder, into: &fileHierarchyIndex, rootKey: rootKey)
		#endif
	}
	
	#if DEBUG
	private struct ReindexTraversalStats {
		var visitedFolderCount: Int = 0
		var visitedFileCount: Int = 0
	}

	/// Recursively inserts folder/files into 'fileHierarchyIndex'.
	@MainActor
	private func reindexFolderRecursively(
		_ folder: FolderViewModel,
		into index: inout FileHierarchyIndex,
		rootKey: String,
		stats: inout ReindexTraversalStats
	) {
		var visitedFolderIDs = Set<UUID>()
		reindexFolderRecursively(
			folder,
			into: &index,
			rootKey: rootKey,
			visitedFolderIDs: &visitedFolderIDs,
			stats: &stats
		)
	}
	
	@MainActor
	private func reindexFolderRecursively(
		_ folder: FolderViewModel,
		into index: inout FileHierarchyIndex,
		rootKey: String,
		visitedFolderIDs: inout Set<UUID>,
		stats: inout ReindexTraversalStats
	) {
		guard visitedFolderIDs.insert(folder.id).inserted else { return }
		stats.visitedFolderCount += 1
		index.insertFolder(folder, rootKey: rootKey)
		
		for child in folder.children {
			switch child {
			case .folder(let subFolder):
				reindexFolderRecursively(
					subFolder,
					into: &index,
					rootKey: rootKey,
					visitedFolderIDs: &visitedFolderIDs,
					stats: &stats
				)
			case .file(let fileVM):
				stats.visitedFileCount += 1
				index.insertFile(fileVM, rootKey: rootKey)
			}
		}
	}
	#else
	@MainActor
	private func reindexFolderRecursively(
		_ folder: FolderViewModel,
		into index: inout FileHierarchyIndex,
		rootKey: String
	) {
		var visitedFolderIDs = Set<UUID>()
		reindexFolderRecursively(
			folder,
			into: &index,
			rootKey: rootKey,
			visitedFolderIDs: &visitedFolderIDs
		)
	}

	@MainActor
	private func reindexFolderRecursively(
		_ folder: FolderViewModel,
		into index: inout FileHierarchyIndex,
		rootKey: String,
		visitedFolderIDs: inout Set<UUID>
	) {
		guard visitedFolderIDs.insert(folder.id).inserted else { return }
		index.insertFolder(folder, rootKey: rootKey)

		for child in folder.children {
			switch child {
			case .folder(let subFolder):
				reindexFolderRecursively(
					subFolder,
					into: &index,
					rootKey: rootKey,
					visitedFolderIDs: &visitedFolderIDs
				)
			case .file(let fileVM):
				index.insertFile(fileVM, rootKey: rootKey)
			}
		}
	}
	#endif
	
	// MARK: – Delta replay (public entry point)
	@MainActor
	private func applyFileSystemDeltas(
		_ deltas: [FileSystemDelta],
		forRootKey rootKey: RootKey,
		deferIfUnfocused: Bool = true
	) async {
		guard !deltas.isEmpty else { return }
		if deferIfUnfocused {
			await syncDeferredReplayRoutingState()
			let ingress = await deferredReplayBuffer.ingestLiveDeltas(
				deltas,
				forRootKey: rootKey
			)
			await handleDeferredReplayIngressResult(ingress)
			return
		}
		let chunkSize: Int
		#if DEBUG
		chunkSize = max(deltaReplayChunkSizeOverride ?? max(deltas.count, 1), 1)
		#else
		chunkSize = max(deltas.count, 1)
		#endif
		#if DEBUG
		let prepareAwaitStartMS = debugPerfTimestampMS()
		#endif
		let preparedBatch = await deltaReplayPreparationActor.prepare(
			rootKey: rootKey,
			deltas: deltas,
			chunkSize: chunkSize
		)
		#if DEBUG
		let prepareAwaitDurationMS = debugPerfElapsedMS(since: prepareAwaitStartMS)
		await applyPreparedReplayBatch(preparedBatch, passIndex: 0, prepareAwaitDurationMS: prepareAwaitDurationMS)
		#else
		await applyPreparedReplayBatch(preparedBatch, passIndex: 0)
		#endif
	}

	@MainActor
	private func applyPreparedReplayBatch(
		_ preparedBatch: PreparedFileSystemReplayBatch,
		passIndex: Int,
		prepareAwaitDurationMS: Double? = nil
	) async {
		guard !preparedBatch.chunks.isEmpty else { return }
		#if DEBUG
		let totalStartMS = debugPerfTimestampMS()
		pendingInsertFlushInvocationPerfSamples.removeAll(keepingCapacity: true)
		var replayedChunks: [RootReplayPerfSample] = []
		#endif
		var accumulator = ReplayRootPassAccumulator(rootKey: preparedBatch.rootKey)
		let chunkCount = preparedBatch.chunks.count
		for (chunkIndex, chunk) in preparedBatch.chunks.enumerated() {
			#if DEBUG
			let applyAwaitStartMS = debugPerfTimestampMS()
			#endif
			await applyPreparedFileSystemDeltas(
				chunk: chunk,
				from: preparedBatch,
				forRootKey: preparedBatch.rootKey,
				accumulator: &accumulator
			)
			#if DEBUG
			if var sample = currentRootReplayPerfSample {
				sample.passIndex = passIndex
				sample.chunkIndexInPass = chunkIndex
				sample.chunkCountInPass = chunkCount
				sample.applyAwaitDurationMS = debugPerfElapsedMS(since: applyAwaitStartMS)
				replayedChunks.append(sample)
				currentRootReplayPerfSample = nil
			}
			#endif
		}
		#if DEBUG
		let rootPass = finalizeReplayRootPass(
			accumulator,
			passIndex: passIndex,
			chunkCount: chunkCount
		)
		lastImmediateReplayPerfSample = ImmediateReplayPerfSample(
			rootKey: preparedBatch.rootKey,
			passIndex: passIndex,
			chunkCount: chunkCount,
			totalDeltaCount: preparedBatch.preparedDeltas.count,
			queuedDeltaCount: preparedBatch.queuedDeltaCount,
			coalescedDeltaCount: preparedBatch.coalescedDeltaCount,
			discardedDeltaCount: preparedBatch.discardedDeltaCount,
			replayedChunks: replayedChunks,
			rootPass: rootPass,
			pendingInsertFlushInvocations: pendingInsertFlushInvocationPerfSamples,
			prepareAwaitDurationMS: prepareAwaitDurationMS,
			totalDurationMS: debugPerfElapsedMS(since: totalStartMS)
		)
		#else
		_ = finalizeReplayRootPass(
			accumulator,
			passIndex: passIndex,
			chunkCount: chunkCount
		)
		#endif
	}

	@MainActor
	@discardableResult
	private func advanceDeferredReplayRoutingVersion() -> UInt64 {
		deferredReplayRoutingVersion &+= 1
		return deferredReplayRoutingVersion
	}

	@MainActor
	@discardableResult
	private func advanceRootReplayIngressGeneration(forRootKey rootKey: RootKey) -> UInt64 {
		rootReplayIngressGenerationByRoot[rootKey, default: 0] &+= 1
		return rootReplayIngressGenerationByRoot[rootKey] ?? 0
	}

	@MainActor
	private func currentRootReplayIngressGeneration(forRootKey rootKey: RootKey) -> UInt64? {
		rootReplayIngressGenerationByRoot[rootKey]
	}

	@MainActor
	private func syncDeferredReplayRoutingState() async {
		await deferredReplayBuffer.updateRoutingState(
			isWindowFocused: isWindowFocused,
			isReplayActive: isReplayingDeltas,
			routingVersion: deferredReplayRoutingVersion
		)
		#if DEBUG
		await deferredReplayBuffer.updateImmediateReplayChunkSizeOverride(deltaReplayChunkSizeOverride)
		#endif
	}

	@MainActor
	private func makeFileSystemChangesCancellable(
		changesPublisher: AnyPublisher<[FileSystemDelta], Never>,
		rootKey: RootKey,
		rootReplayIngressGeneration: UInt64
	) -> AnyCancellable {
		let deferredReplayBuffer = self.deferredReplayBuffer
		let watcherIngressTaskTracker = self.watcherIngressTaskTracker
		return changesPublisher.sink { [weak self, rootKey, rootReplayIngressGeneration, deferredReplayBuffer, watcherIngressTaskTracker] deltas in
			let ingressTaskID = UUID()
			watcherIngressTaskTracker.begin(ingressTaskID)
			Task { [weak self, rootKey, rootReplayIngressGeneration, deferredReplayBuffer, watcherIngressTaskTracker] in
				defer { watcherIngressTaskTracker.end(ingressTaskID) }
				let ingress = await deferredReplayBuffer.ingestLiveDeltas(
					deltas,
					forRootKey: rootKey,
					rootGeneration: rootReplayIngressGeneration
				)
				switch ingress {
				case .queued, .droppedWhileOverflowed, .droppedStaleGeneration:
					return
				case .preparedImmediate, .overflowRequiresRefresh:
					guard let self else {
						if case .preparedImmediate(let immediate) = ingress {
							await deferredReplayBuffer.finishPreparedImmediateIngress(immediate)
						}
						return
					}
					await self.handleDeferredReplayIngressResult(ingress)
				}
			}
		}
	}

	@MainActor
	private func awaitWatcherIngressTasksForReplayBarrier() async {
		await watcherIngressTaskTracker.waitForCurrentTasks()
	}

	@MainActor
	private func handleDeferredReplayIngressResult(
		_ result: DeferredReplayIngressResult
	) async {
		switch result {
		case .preparedImmediate(let immediate):
			guard currentRootReplayIngressGeneration(forRootKey: immediate.rootKey) == immediate.rootGeneration else {
				await deferredReplayBuffer.finishPreparedImmediateIngress(immediate)
				return
			}
			guard immediate.routingVersion == deferredReplayRoutingVersion,
				isWindowFocused,
				!isReplayingDeltas
			else {
				await deferredReplayBuffer.finishPreparedImmediateIngress(immediate)
				switch await deferredReplayBuffer.enqueueDeferredDeltas(
					immediate.sourceDeltas,
					forRootKey: immediate.rootKey
				) {
				case .queued, .droppedWhileOverflowed, .droppedStaleGeneration:
					return
				case .overflowRequiresRefresh(let overflowedRootKey):
					handleDeferredReplayOverflow(forRootKey: overflowedRootKey)
				case .preparedImmediate:
					assertionFailure("enqueueDeferredDeltas should not produce prepared immediate work")
				}
				return
			}
			await applyPreparedReplayBatch(immediate.preparedBatch, passIndex: 0)
			await deferredReplayBuffer.finishPreparedImmediateIngress(immediate)
			if isWindowFocused,
				!isReplayingDeltas,
				await deferredReplayBuffer.hasPendingWork() {
				await flushPendingDeltas()
			}
		case .queued, .droppedWhileOverflowed, .droppedStaleGeneration:
			return
		case .overflowRequiresRefresh(let overflowedRootKey):
			handleDeferredReplayOverflow(forRootKey: overflowedRootKey)
		}
	}

	@MainActor
	private func handleDeferredReplayOverflow(forRootKey rootKey: RootKey) {
		if Self.isLoggingEnabled {
			print("Δ-queue overflow for root \((rootKey as NSString).lastPathComponent); scheduling full refresh")
		}
		requestRefresh()
	}
	
	/// Pure delta-handler for already prepared deltas – **never** checks window focus.
	@MainActor
	private func applyPreparedFileSystemDeltas(
		chunk: PreparedFileSystemReplayChunk,
		from batch: PreparedFileSystemReplayBatch,
		forRootKey rootKey: RootKey,
		accumulator: inout ReplayRootPassAccumulator
	) async {
		let signpost = RepoFileReplayPerf.begin("applyReplayChunk")
		defer { RepoFileReplayPerf.end("applyReplayChunk", signpost) }
		#if DEBUG
		let totalStartMS = debugPerfTimestampMS()
		#endif
		guard let fsService = fileSystemServices[rootKey],
			let targetRootVM = rootFolders.first(where: { $0.standardizedFullPath == rootKey })
		else { return }

		let deltas = batch.preparedDeltas[chunk.range]
		var needsIndexRebuild = false
		var topologyChanged = false
		let shouldFlushPendingInserts = chunk.summary.fileAddedCount > 0
		var dirtyFolderStateStarts: [UUID: FolderViewModel] = [:]
		var requiresFullRootFolderStateRefresh = false
		var batchedCodeScanFiles: [UUID: FileViewModel] = [:]
		var batchedSliceRebases: [String: ReplaySliceRebaseRequest] = [:]
		var removedSubtreesForCleanup: [RemovedFolderSubtree] = []
		var removedSubtreeRootPathsForCleanup: Set<String> = []
		var fileAddParentContextCache: [String: ReplayFileAddParentContext] = [:]
		struct OrderedFileAddParentContextCursor {
			var parentRelativePath: String?
			var context: ReplayFileAddParentContext?

			mutating func reset() {
				parentRelativePath = nil
				context = nil
			}

			mutating func updateIfCurrentParent(_ resolvedContext: ReplayFileAddParentContext) {
				guard parentRelativePath == resolvedContext.standardizedParentRelativePath else { return }
				context = resolvedContext
			}
		}
		var orderedFileAddParentContextCursor = OrderedFileAddParentContextCursor()
		#if DEBUG
		let fileAddedCount = chunk.summary.fileAddedCount
		let fileRemovedCount = chunk.summary.fileRemovedCount
		let folderAddedCount = chunk.summary.folderAddedCount
		let folderRemovedCount = chunk.summary.folderRemovedCount
		let modifiedCount = chunk.summary.modifiedCount
		var folderModifiedCount = 0
		var folderModifiedCarriedDateCount = 0
		var folderModifiedFallbackStatSuccessCount = 0
		var folderModifiedSkippedNoDateCount = 0
		var deltaLoopDurationMS = 0.0
		var pendingInsertRootCountBeforeFlush = 0
		var pendingInsertEntryCountBeforeFlush = 0
		var pendingInsertEntryCountForReplayedRootBeforeFlush = 0
		var pendingInsertEntryCountRemainingAfterFlush = 0
		var flushPendingInsertsDurationMS = 0.0
		var updateFolderStatesDurationMS = 0.0
		var usedFullRootFolderStateRefresh = false
		var dirtyFolderStateStartCount = 0
		var onRootFoldersChangedDurationMS = 0.0
		var usedIncrementalIndexCleanup = false
		var incrementalIndexCleanupDurationMS = 0.0
		var incrementalRemovedFolderCount = 0
		var incrementalRemovedFileCount = 0
		var incrementalIndexCleanupFallbackToRebuild = false
		var incrementalDescendantScanInvocationCount = 0
		var incrementalDescendantScannedFolderCandidateCount = 0
		var incrementalDescendantScannedFileCandidateCount = 0
		var incrementalCleanupUsedFallbackGlobalScan = false
		var rebuildDurationMS: Double?
		var rebuildCleanupCandidateSelectionDurationMS: Double?
		var rebuildCleanupFolderRemovalDurationMS: Double?
		var rebuildCleanupFileRemovalDurationMS: Double?
		var rebuildTraversalDurationMS: Double?
		var rebuildCleanupCandidateFolderKeys: Int?
		var rebuildCleanupCandidateFileKeys: Int?
		var rebuildUsedOwnershipFallback: Bool?
		var codeScanBatchInvocationCount = 0
		var codeScanBatchFileCount = 0
		var sliceRebaseBatchInvocationCount = 0
		var sliceRebaseCandidateCount = 0
		var invalidateSnapshotDurationMS = 0.0
		let fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector? = fileAddedCount > 0
			? ReplayFileAddPathMetricsCollector(detailedWallAttributionEnabled: isDetailedReplayWallAttributionEnabledForTesting)
			: nil
		#else
		let fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector? = nil
		#endif

		func updateDebugRebuildMetrics(startedAt rebuildStartMS: Double) {
			#if DEBUG
			rebuildDurationMS = (rebuildDurationMS ?? 0) + debugPerfElapsedMS(since: rebuildStartMS)
			if let rebuildSample = lastIndexRebuildPerfSample, rebuildSample.rootKey == rootKey {
				rebuildCleanupCandidateSelectionDurationMS = rebuildSample.cleanupCandidateSelectionDurationMS
				rebuildCleanupFolderRemovalDurationMS = rebuildSample.cleanupFolderRemovalDurationMS
				rebuildCleanupFileRemovalDurationMS = rebuildSample.cleanupFileRemovalDurationMS
				rebuildTraversalDurationMS = rebuildSample.reindexTraversalDurationMS
				rebuildCleanupCandidateFolderKeys = rebuildSample.cleanupCandidateFolderKeys
				rebuildCleanupCandidateFileKeys = rebuildSample.cleanupCandidateFileKeys
				rebuildUsedOwnershipFallback = rebuildSample.usedOwnershipFallback
			}
			#endif
		}

		func rebuildIndexIfNeeded() {
			guard needsIndexRebuild else { return }
			#if DEBUG
			let rebuildStartMS = debugPerfTimestampMS()
			#endif
			rebuildFileHierarchyIndex(for: targetRootVM)
			#if DEBUG
			updateDebugRebuildMetrics(startedAt: rebuildStartMS)
			#endif
			needsIndexRebuild = false
		}

		func flushRemovedSubtreesForCleanup() {
			guard !removedSubtreesForCleanup.isEmpty else { return }
			#if DEBUG
			let incrementalCleanupStartMS = debugPerfTimestampMS()
			#endif
			let cleanupOutcome = performBatchedIncrementalRemovedSubtreeCleanup(
				removedSubtreesForCleanup,
				rootKey: rootKey
			)
			removedSubtreesForCleanup.removeAll(keepingCapacity: true)
			removedSubtreeRootPathsForCleanup.removeAll(keepingCapacity: true)
			#if DEBUG
			usedIncrementalIndexCleanup = true
			incrementalIndexCleanupDurationMS += debugPerfElapsedMS(since: incrementalCleanupStartMS)
			incrementalRemovedFolderCount += cleanupOutcome.removedFolderCount
			incrementalRemovedFileCount += cleanupOutcome.removedFileCount
			incrementalDescendantScanInvocationCount += cleanupOutcome.descendantScanInvocationCount
			incrementalDescendantScannedFolderCandidateCount += cleanupOutcome.scannedFolderCandidateCount
			incrementalDescendantScannedFileCandidateCount += cleanupOutcome.scannedFileCandidateCount
			incrementalCleanupUsedFallbackGlobalScan = incrementalCleanupUsedFallbackGlobalScan || cleanupOutcome.usedFallbackGlobalScan
			#endif
			if !cleanupOutcome.succeeded {
				needsIndexRebuild = true
				#if DEBUG
				incrementalIndexCleanupFallbackToRebuild = true
				#endif
				rebuildIndexIfNeeded()
			}
		}

		func flushPendingRemovedSubtreesIfNeeded(beforeAddingPath absolutePath: String) {
			guard !removedSubtreeRootPathsForCleanup.isEmpty else { return }
			let matcher = RemovedFolderPathMatcher(removedFolderPaths: removedSubtreeRootPathsForCleanup)
			if matcher.containsPathEqualToOrInsideRemovedFolder(absolutePath) {
				flushRemovedSubtreesForCleanup()
			}
		}

		for transfer in chunk.renameTransfers {
			transferExpandedStateOnRename(
				oldAbs: transfer.oldAbsolutePath,
				newAbs: transfer.newAbsolutePath
			)
		}

		var processedDigests: [FileSystemDeltaDigest] = []
		processedDigests.reserveCapacity(chunk.deltaCount)
		#if DEBUG
		let deltaLoopStartMS = debugPerfTimestampMS()
		#endif
		let fileAddedRelativePathsForCatalogEligibility: [String]
		if shouldFlushPendingInserts {
			fileAddedRelativePathsForCatalogEligibility = deltas.compactMap { prepared in
				if case .fileAdded = prepared.delta {
					return prepared.relativePath
				}
				return nil
			}
		} else {
			fileAddedRelativePathsForCatalogEligibility = []
		}
		#if DEBUG
		let fileAddCatalogEligibilityByRelativePath: [String: CatalogRegularFileEligibility]
		if !fileAddedRelativePathsForCatalogEligibility.isEmpty,
			let fileAddPathMetricsCollector,
			fileAddPathMetricsCollector.isDetailedWallAttributionEnabled {
			let batchEligibilityStartMS = debugPerfTimestampMS()
			let diagnosticBatch = await fsService.catalogRegularFileEligibilityPreparedBatchWithDiagnosticsForTesting(
				preparedRelativePaths: fileAddedRelativePathsForCatalogEligibility
			)
			fileAddCatalogEligibilityByRelativePath = diagnosticBatch.results
			let batchEligibilityDurationMS = debugPerfElapsedMS(since: batchEligibilityStartMS)
			let batchEligibilityResults = fileAddedRelativePathsForCatalogEligibility.compactMap {
				fileAddCatalogEligibilityByRelativePath[$0]?.isEligible
			}
			fileAddPathMetricsCollector.recordEligibilityBatch(
				results: batchEligibilityResults,
				durationMS: batchEligibilityDurationMS
			)
			fileAddPathMetricsCollector.recordEligibilityBatchDiagnostics(diagnosticBatch.diagnostics)
		} else {
			fileAddCatalogEligibilityByRelativePath = fileAddedRelativePathsForCatalogEligibility.isEmpty
				? [:]
				: await fsService.catalogRegularFileEligibilityBatchForPreparedRelativePaths(fileAddedRelativePathsForCatalogEligibility)
			if let fileAddPathMetricsCollector {
				let batchEligibilityResults = fileAddedRelativePathsForCatalogEligibility.compactMap {
					fileAddCatalogEligibilityByRelativePath[$0]?.isEligible
				}
				fileAddPathMetricsCollector.recordEligibilityBatch(results: batchEligibilityResults, durationMS: 0)
			}
		}
		#else
		let fileAddCatalogEligibilityByRelativePath: [String: CatalogRegularFileEligibility] = fileAddedRelativePathsForCatalogEligibility.isEmpty
			? [:]
			: await fsService.catalogRegularFileEligibilityBatchForPreparedRelativePaths(fileAddedRelativePathsForCatalogEligibility)
		#endif
		for prepared in deltas {
			let delta = prepared.delta
			let rel = prepared.relativePath
			let fullPath = prepared.absolutePath

			switch delta {
			case .fileAdded:
				let isEligibleForCatalog: Bool
				if let batchEligibility = fileAddCatalogEligibilityByRelativePath[rel] {
					isEligibleForCatalog = batchEligibility.isEligible
				} else {
					#if DEBUG
					if let fileAddPathMetricsCollector, fileAddPathMetricsCollector.isDetailedWallAttributionEnabled {
						let eligibilityStartMS = debugPerfTimestampMS()
						isEligibleForCatalog = await fsService.catalogEligibleRegularFileExists(relativePath: rel)
						fileAddPathMetricsCollector.recordEligibilityCheck(
							eligible: isEligibleForCatalog,
							durationMS: debugPerfElapsedMS(since: eligibilityStartMS)
						)
					} else {
						isEligibleForCatalog = await fsService.catalogEligibleRegularFileExists(relativePath: rel)
						fileAddPathMetricsCollector?.recordEligibilityCheck(eligible: isEligibleForCatalog, durationMS: 0)
					}
					#else
					isEligibleForCatalog = await fsService.catalogEligibleRegularFileExists(relativePath: rel)
					#endif
				}
				guard isEligibleForCatalog else {
					#if DEBUG
					if Self.isLoggingEnabled {
						print("Skipping catalog add for policy-ineligible file: \(rel) under root \((rootKey as NSString).lastPathComponent)")
					}
					#endif
					break
				}
				flushPendingRemovedSubtreesIfNeeded(beforeAddingPath: fullPath)
				let replayParentContext = replayFileAddParentContext(
					forStandardizedRelativePath: rel,
					under: targetRootVM,
					cache: &fileAddParentContextCache,
					orderedCursorParentRelativePath: &orderedFileAddParentContextCursor.parentRelativePath,
					orderedCursorContext: &orderedFileAddParentContextCursor.context,
					fileAddPathMetricsCollector: fileAddPathMetricsCollector
				)
				#if DEBUG
				let replayPathMetadataStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
				#endif
				let replayPathMetadata = FileViewModel.PrecomputedPathMetadata.preparedReplay(
					standardizedAbsolutePath: fullPath,
					standardizedRelativePath: rel,
					standardizedRootFolderPath: targetRootVM.standardizedFullPath
				)
				#if DEBUG
				if let replayPathMetadataStartMS {
					fileAddPathMetricsCollector?.recordReplayPathMetadata(durationMS: debugPerfElapsedMS(since: replayPathMetadataStartMS))
				} else {
					fileAddPathMetricsCollector?.recordReplayPathMetadata(durationMS: 0)
				}
				#endif
				#if DEBUG
				let handleNewFileStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
				#endif
				let fileAddOutcome = await handleNewFile(
					relativePath: rel,
					onRootFolder: targetRootVM,
					fsService: fsService,
					requestCodeScanImmediately: false,
					preparedReplayPathMetadata: replayPathMetadata,
					replayParentContext: replayParentContext,
					fileAddPathMetricsCollector: fileAddPathMetricsCollector
				)
				#if DEBUG
				if let handleNewFileStartMS {
					fileAddPathMetricsCollector?.recordHandleNewFileDuration(debugPerfElapsedMS(since: handleNewFileStartMS))
				}
				#endif
				if let outcome = fileAddOutcome {
					batchedCodeScanFiles[outcome.file.id] = outcome.file
					if let parentFolder = outcome.parentFolderForStateRecompute {
						let resolvedReplayParentContext = cacheReplayFileAddParentContext(
							replayParentContext,
							resolvedParent: parentFolder,
							cache: &fileAddParentContextCache
						)
						orderedFileAddParentContextCursor.updateIfCurrentParent(resolvedReplayParentContext)
						dirtyFolderStateStarts[parentFolder.id] = parentFolder
					} else {
						requiresFullRootFolderStateRefresh = true
					}
				} else {
					requiresFullRootFolderStateRefresh = true
				}
				topologyChanged = true
				processedDigests.append(.fileAdded(rel))

			case .folderAdded:
				fileAddParentContextCache.removeAll(keepingCapacity: true)
				orderedFileAddParentContextCursor.reset()
				flushPendingRemovedSubtreesIfNeeded(beforeAddingPath: fullPath)
				if let outcome = handleNewFolder(relativePath: rel, onRootFolder: targetRootVM) {
					if let parentFolder = outcome.parentFolderForStateRecompute {
						dirtyFolderStateStarts[parentFolder.id] = parentFolder
					} else {
						requiresFullRootFolderStateRefresh = true
					}
				} else {
					requiresFullRootFolderStateRefresh = true
				}
				topologyChanged = true
				processedDigests.append(.folderAdded(rel))

			case .fileRemoved:
				let fileVM = findFileByFullPath(fullPath)
				let formerParentFolder = fileVM?.parentFolder ?? parentFolderForRelativePath(rel, under: targetRootVM)
				if let fileVM {
					await clearRemovedFileCaches([fileVM])
					removeFileFromParentChildrenArray(fileVM)
					fileHierarchyIndex.removeFile(forKey: fullPath, expectedRootKey: rootKey)
					topologyChanged = true
					if let formerParentFolder {
						dirtyFolderStateStarts[formerParentFolder.id] = formerParentFolder
					} else {
						requiresFullRootFolderStateRefresh = true
					}
				} else {
					#if DEBUG
					if Self.isLoggingEnabled {
						print("Skipping removal for missing index entry: \(rel) under root \((rootKey as NSString).lastPathComponent)")
					}
					#endif
				}
				processedDigests.append(.fileRemoved(rel))

			case .folderRemoved:
				fileAddParentContextCache.removeAll(keepingCapacity: true)
				orderedFileAddParentContextCursor.reset()
				let removedSubtree: RemovedFolderSubtree?
				if let folderVM = findFolderByFullPath(fullPath) {
					removedSubtree = removeFolderRecursive(in: targetRootVM, relativePath: folderVM.relativePath)
				} else {
					removedSubtree = removeFolderRecursive(in: targetRootVM, relativePath: rel)
				}
				if let removedSubtree {
					let subtreeSnapshot = collectSubtreeSnapshot(from: removedSubtree.removedFolder)
					await clearRemovedFileCaches(subtreeSnapshot.fileViewModels)
					topologyChanged = true
					if let formerParentFolder = removedSubtree.formerParentFolder ?? parentFolderForRelativePath(rel, under: targetRootVM) {
						dirtyFolderStateStarts[formerParentFolder.id] = formerParentFolder
					} else {
						requiresFullRootFolderStateRefresh = true
					}
					removedSubtreesForCleanup.append(removedSubtree)
					removedSubtreeRootPathsForCleanup.insert(removedSubtree.removedFolderFullPath)
				} else {
					#if DEBUG
					if Self.isLoggingEnabled {
						print("Skipping folder removal for missing index entry: \(rel) under root \((rootKey as NSString).lastPathComponent)")
					}
					#endif
				}
				processedDigests.append(.folderRemoved(rel))

			case .fileModified(_, let maybeDate):
				if let fileVM = findFileByFullPath(fullPath) {
					if let date = maybeDate {
						await fileVM.setModificationDate(date, forceInvalidation: true)
					} else {
						do {
							let diskDate = try await fsService.getFileModificationDate(atRelativePath: rel)
							await fileVM.setModificationDate(diskDate, forceInvalidation: true)
						} catch {
							await fileVM.setModificationDate(Date(), forceInvalidation: true)
						}
					}
					codemapCapableAPIsByFullPath.removeValue(forKey: fileVM.standardizedFullPath)
					batchedCodeScanFiles[fileVM.id] = fileVM
					batchedSliceRebases[fileVM.standardizedFullPath] = ReplaySliceRebaseRequest(
						file: fileVM,
						relativePath: rel,
						fsService: fsService
					)
				}
				processedDigests.append(.fileModified(rel))

			case .folderModified(_, let maybeDate):
				#if DEBUG
				folderModifiedCount += 1
				if maybeDate != nil {
					folderModifiedCarriedDateCount += 1
				}
				#endif
				if let folderVM = findFolderByFullPath(fullPath) {
					if let date = maybeDate {
						folderVM.setModificationDate(date)
					} else if let diskDate = await fsService.getItemModificationDateIfAvailable(atRelativePath: rel) {
						#if DEBUG
						folderModifiedFallbackStatSuccessCount += 1
						#endif
						folderVM.setModificationDate(diskDate)
					} else {
						#if DEBUG
						folderModifiedSkippedNoDateCount += 1
						#endif
					}
				} else if maybeDate == nil {
					#if DEBUG
					folderModifiedSkippedNoDateCount += 1
					#endif
				}
				processedDigests.append(.folderModified(rel))
			}
		}
		#if DEBUG
		deltaLoopDurationMS = debugPerfElapsedMS(since: deltaLoopStartMS)
		#endif

		flushRemovedSubtreesForCleanup()

		if shouldFlushPendingInserts {
			#if DEBUG
			let pendingInsertSnapshotBeforeFlush = pendingInsertPerfSnapshot(forRootKey: rootKey)
			pendingInsertRootCountBeforeFlush = pendingInsertSnapshotBeforeFlush.rootCount
			pendingInsertEntryCountBeforeFlush = pendingInsertSnapshotBeforeFlush.entryCount
			pendingInsertEntryCountForReplayedRootBeforeFlush = pendingInsertSnapshotBeforeFlush.entryCountForRoot
			let flushPendingInsertsStartMS = debugPerfTimestampMS()
			#endif
			flushPendingInserts()
			#if DEBUG
			flushPendingInsertsDurationMS = debugPerfElapsedMS(since: flushPendingInsertsStartMS)
			pendingInsertEntryCountRemainingAfterFlush = pendingInsertPerfSnapshot(forRootKey: rootKey).entryCount
			#endif
		}

		if topologyChanged {
			#if DEBUG
			let updateFolderStatesStartMS = debugPerfTimestampMS()
			dirtyFolderStateStartCount = dirtyFolderStateStarts.count
			#endif
			if requiresFullRootFolderStateRefresh {
				_ = updateFolderStateRecursive(targetRootVM)
				#if DEBUG
				usedFullRootFolderStateRefresh = true
				#endif
			} else {
				recomputeAncestorStates(startingAtFolders: Array(dirtyFolderStateStarts.values))
			}
			#if DEBUG
			updateFolderStatesDurationMS = debugPerfElapsedMS(since: updateFolderStatesStartMS)
			#endif
		}

		rebuildIndexIfNeeded()

		accumulator.processedDigests.append(contentsOf: processedDigests)
		if topologyChanged {
			accumulator.topologyChanged = true
		}
		for (fileID, file) in batchedCodeScanFiles {
			accumulator.codeScanFilesByID[fileID] = file
		}
		for (fullPath, request) in batchedSliceRebases {
			accumulator.sliceRebasesByFullPath[fullPath] = request
		}

		#if DEBUG
		currentRootReplayPerfSample = RootReplayPerfSample(
			rootKey: rootKey,
			coalesceDurationMS: batch.coalesceDurationMS,
			preparationDurationMS: batch.preparationDurationMS,
			batchQueuedDeltaCount: batch.queuedDeltaCount,
			batchCoalescedDeltaCount: batch.coalescedDeltaCount,
			batchDiscardedDeltaCount: batch.discardedDeltaCount,
			chunkDeltaCount: chunk.deltaCount,
			fileAddedCount: fileAddedCount,
			fileRemovedCount: fileRemovedCount,
			folderAddedCount: folderAddedCount,
			folderRemovedCount: folderRemovedCount,
			modifiedCount: modifiedCount,
			folderModifiedCount: folderModifiedCount,
			folderModifiedCarriedDateCount: folderModifiedCarriedDateCount,
			folderModifiedFallbackStatSuccessCount: folderModifiedFallbackStatSuccessCount,
			folderModifiedSkippedNoDateCount: folderModifiedSkippedNoDateCount,
			fileAddPathMetrics: fileAddPathMetricsCollector?.snapshot(),
			deltaLoopDurationMS: deltaLoopDurationMS,
			pendingInsertRootCountBeforeFlush: pendingInsertRootCountBeforeFlush,
			pendingInsertEntryCountBeforeFlush: pendingInsertEntryCountBeforeFlush,
			pendingInsertEntryCountForReplayedRootBeforeFlush: pendingInsertEntryCountForReplayedRootBeforeFlush,
			pendingInsertEntryCountRemainingAfterFlush: pendingInsertEntryCountRemainingAfterFlush,
			flushPendingInsertsDurationMS: flushPendingInsertsDurationMS,
			updateFolderStatesDurationMS: updateFolderStatesDurationMS,
			usedFullRootFolderStateRefresh: usedFullRootFolderStateRefresh,
			dirtyFolderStateStartCount: dirtyFolderStateStartCount,
			onRootFoldersChangedDurationMS: onRootFoldersChangedDurationMS,
			usedIncrementalIndexCleanup: usedIncrementalIndexCleanup,
			incrementalIndexCleanupDurationMS: incrementalIndexCleanupDurationMS,
			incrementalRemovedFolderCount: incrementalRemovedFolderCount,
			incrementalRemovedFileCount: incrementalRemovedFileCount,
			incrementalIndexCleanupFallbackToRebuild: incrementalIndexCleanupFallbackToRebuild,
			incrementalDescendantScanInvocationCount: incrementalDescendantScanInvocationCount,
			incrementalDescendantScannedFolderCandidateCount: incrementalDescendantScannedFolderCandidateCount,
			incrementalDescendantScannedFileCandidateCount: incrementalDescendantScannedFileCandidateCount,
			incrementalCleanupUsedFallbackGlobalScan: incrementalCleanupUsedFallbackGlobalScan,
			rebuildDurationMS: rebuildDurationMS,
			rebuildCleanupCandidateSelectionDurationMS: rebuildCleanupCandidateSelectionDurationMS,
			rebuildCleanupFolderRemovalDurationMS: rebuildCleanupFolderRemovalDurationMS,
			rebuildCleanupFileRemovalDurationMS: rebuildCleanupFileRemovalDurationMS,
			rebuildTraversalDurationMS: rebuildTraversalDurationMS,
			rebuildCleanupCandidateFolderKeys: rebuildCleanupCandidateFolderKeys,
			rebuildCleanupCandidateFileKeys: rebuildCleanupCandidateFileKeys,
			rebuildUsedOwnershipFallback: rebuildUsedOwnershipFallback,
			codeScanBatchInvocationCount: 0,
			codeScanBatchFileCount: 0,
			sliceRebaseBatchInvocationCount: 0,
			sliceRebaseCandidateCount: 0,
			invalidateSnapshotDurationMS: invalidateSnapshotDurationMS,
			totalApplyDurationMS: debugPerfElapsedMS(since: totalStartMS)
		)
		#endif
	}

	@MainActor
	private func finalizeReplayRootPass(
		_ accumulator: ReplayRootPassAccumulator,
		passIndex: Int,
		chunkCount: Int
	) -> RootReplayPassPerfSample? {
		guard !accumulator.processedDigests.isEmpty else { return nil }
		let signpost = RepoFileReplayPerf.begin("finalizeReplayRootPass")
		defer { RepoFileReplayPerf.end("finalizeReplayRootPass", signpost) }
		#if DEBUG
		let finalizeStartMS = debugPerfTimestampMS()
		var onRootFoldersChangedDurationMS = 0.0
		var invalidateSnapshotDurationMS = 0.0
		#endif
		if accumulator.topologyChanged {
			#if DEBUG
			let invalidateSnapshotStartMS = debugPerfTimestampMS()
			#endif
			invalidateStaticSnapshot(forRootFullPath: accumulator.rootKey)
			#if DEBUG
			invalidateSnapshotDurationMS = debugPerfElapsedMS(since: invalidateSnapshotStartMS)
			#endif
		}
		#if DEBUG
		let onRootsChangedStartMS = debugPerfTimestampMS()
		#endif
		onRootFoldersChanged?()
		#if DEBUG
		onRootFoldersChangedDurationMS = debugPerfElapsedMS(since: onRootsChangedStartMS)
		#endif
		fileSystemDeltasAppliedPublisher.send(
			FileSystemDeltasAppliedEvent(rootKey: accumulator.rootKey, deltas: accumulator.processedDigests)
		)
		let codeScanFiles = Array(accumulator.codeScanFilesByID.values)
		let sliceRebases = Array(accumulator.sliceRebasesByFullPath.values)
		flushReplayChunkCodeScanBatch(codeScanFiles)
		scheduleSliceRebasesForModifiedFiles(sliceRebases)
		#if DEBUG
		return RootReplayPassPerfSample(
			rootKey: accumulator.rootKey,
			passIndex: passIndex,
			chunkCount: chunkCount,
			digestCount: accumulator.processedDigests.count,
			topologyChanged: accumulator.topologyChanged,
			onRootFoldersChangedInvocationCount: 1,
			snapshotInvalidationCount: accumulator.topologyChanged ? 1 : 0,
			deltaAppliedPublisherInvocationCount: 1,
			codeScanBatchInvocationCount: codeScanFiles.isEmpty ? 0 : 1,
			codeScanBatchFileCount: codeScanFiles.count,
			sliceRebaseBatchInvocationCount: sliceRebases.isEmpty ? 0 : 1,
			sliceRebaseCandidateCount: sliceRebases.count,
			onRootFoldersChangedDurationMS: onRootFoldersChangedDurationMS,
			invalidateSnapshotDurationMS: invalidateSnapshotDurationMS,
			finalizeDurationMS: debugPerfElapsedMS(since: finalizeStartMS)
		)
		#else
		return nil
		#endif
	}

	/// Update the cached expansion set when a folder is renamed (simple parent‐preserving rename).
	@MainActor
	private func transferExpandedStateOnRename(oldAbs: String, newAbs: String) {
		let oldStd = (oldAbs as NSString).standardizingPath
		let newStd = (newAbs as NSString).standardizingPath
		var toRemove: [String] = []
		var toAdd: [String] = []
		for path in expandedFolderPaths {
			if path == oldStd || path.hasPrefix(oldStd.hasSuffix("/") ? oldStd : oldStd + "/") {
				let suffix = String(path.dropFirst(oldStd.count))
				let mapped = newStd + suffix
				toRemove.append(path)
				toAdd.append((mapped as NSString).standardizingPath)
			}
		}
		for p in toRemove { expandedFolderPaths.remove(p) }
		for p in toAdd { expandedFolderPaths.insert(p) }
	}

	@MainActor
	private func applyCachedExpansionStateIfNeeded(to folder: FolderViewModel) {
		guard expandedFolderPaths.contains(folder.standardizedFullPath) else { return }
		let wasApplying = isApplyingExpansionState
		isApplyingExpansionState = true
		_ = expandParentChain(of: folder)
		isApplyingExpansionState = wasApplying
	}
	
	@MainActor
	private func handleNewFolder(relativePath: String, onRootFolder root: FolderViewModel) -> FolderTopologyApplyOutcome? {
		let parentFolderForStateRecompute = parentFolderForRelativePath(relativePath, under: root)
		// Build the absolute path for this folder under the given root
		let absPath = (root.fullPath as NSString).appendingPathComponent(relativePath)
		let standardizedAbsPath = (absPath as NSString).standardizingPath
		
		// ──────────────────────────────────────────────────────────────────
		// A) Folder already in the index?
		// ──────────────────────────────────────────────────────────────────
		if let found = findFolderByFullPath(standardizedAbsPath) {
			// 1️⃣ Always refresh the timestamp
			found.setModificationDate(Date())
			
			// 2️⃣ If it is currently *detached* (parent == nil and not a root),
			//     make sure it is linked back into the visible hierarchy.
			let isRoot   = rootFolders.contains { $0.id == found.id }
			let isLinked = (found.parent != nil) || isRoot
			if !isLinked {
				// Ensure the ancestor chain exists, then attach
				createMissingParentFolder(
					parentPath: (relativePath as NSString)
						.deletingLastPathComponent,
					under:      root
				)
				insertFolder(found,
								under: root,
								relativePath: relativePath)
			}
			applyCachedExpansionStateIfNeeded(to: found)
			return FolderTopologyApplyOutcome(
				parentFolderForStateRecompute: found.parent ?? parentFolderForStateRecompute
			)
		}
		
		// ──────────────────────────────────────────────────────────────────
		// B) Brand new folder – create, index, attach
		// ──────────────────────────────────────────────────────────────────
		let folder = Folder(
			name: (relativePath as NSString).lastPathComponent,
			path: standardizedAbsPath,
			modificationDate: Date()
		)
		// For _git_data subtree: use dateNewest sort override so newest items appear first
		let isGitDataRoot = root.isSystemRoot && root.name == "_git_data"
		let sortOverride: SortMethod? = isGitDataRoot ? .dateNewest : nil
		let folderVM = FolderViewModel(folder: folder,
										rootPath: root.fullPath,
										sortMethodOverride: sortOverride)
		
		fileHierarchyIndex.insertFolder(folderVM, rootKey: root.standardizedFullPath)
		
		// Attach (creating any missing ancestors)
		insertFolder(folderVM, under: root, relativePath: relativePath)
		applyCachedExpansionStateIfNeeded(to: folderVM)
		return FolderTopologyApplyOutcome(
			parentFolderForStateRecompute: folderVM.parent ?? parentFolderForStateRecompute
		)
	}
	
	private func removeFolder(atRelativePath relativePath: String, from root: FolderViewModel) {
		_ = removeFolderRecursive(in: root, relativePath: relativePath)
	}
	
	/// Insert a FolderViewModel under the correct parent in the tree, creating
	/// intermediate parent folders if needed.
	@MainActor
	private func insertFolder(
		_ folderVM   : FolderViewModel,
		under root   : FolderViewModel,
		relativePath : String
	) {
		let comps = relativePath.split(separator: "/").map(String.init)
		guard comps.count > 1 else {
			guard canAttachFolder(folderVM, to: root) else {
				logInvalidFolderAttach(child: folderVM, parent: root, root: root, reason: "invalid-root-attachment")
				return
			}
			root.addChild(.folder(folderVM))
			registerExpansionTracking(for: folderVM)
			return
		}
	
		let parentRel  = comps.dropLast().joined(separator: "/")
		let rootFull = root.standardizedFullPath
		let parentFull = ((rootFull as NSString)
			.appendingPathComponent(parentRel) as NSString)
			.standardizingPath
	
		if let parent = fileHierarchyIndex.foldersByFullPath[parentFull] {
			let isRoot   = rootFolders.contains { $0.id == parent.id }
			let isLinked = (parent.parent != nil) || isRoot
			if !isLinked { createMissingParentFolder(parentPath: parentRel, under: root) }
	
			guard canAttachFolder(folderVM, to: parent) else {
				logInvalidFolderAttach(child: folderVM, parent: parent, root: root, reason: "invalid-parent-attachment")
				return
			}
			parent.addChild(.folder(folderVM))
			registerExpansionTracking(for: folderVM)
			return
		}
	
		// Parent chain missing → build once, *then* attach
		createMissingParentFolder(parentPath: parentRel, under: root)
		if let parent = fileHierarchyIndex.foldersByFullPath[parentFull] {
			guard canAttachFolder(folderVM, to: parent) else {
				logInvalidFolderAttach(child: folderVM, parent: parent, root: root, reason: "invalid-parent-attachment")
				return
			}
			parent.addChild(.folder(folderVM))
			registerExpansionTracking(for: folderVM)
		}
	}
	
	// ─────────────────────────────────────────────────────────────
	// MARK: - Insert batching helpers
	// ─────────────────────────────────────────────────────────────
	@MainActor
	private func canAttachFolder(_ child: FolderViewModel, to parent: FolderViewModel) -> Bool {
		if child.id == parent.id { return false }
		let parentPath = parent.standardizedFullPath
		let childPath = child.standardizedFullPath
		if childPath == parentPath { return false }
		let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
		return childPath.hasPrefix(prefix)
	}
	
	@MainActor
	private func logInvalidFolderAttach(
		child: FolderViewModel,
		parent: FolderViewModel,
		root: FolderViewModel,
		reason: String
	) {
		guard Self.isLoggingEnabled else { return }
		print("Skipped folder attach (\(reason)): child=\(child.standardizedFullPath) parent=\(parent.standardizedFullPath) root=\(root.standardizedFullPath)")
	}
	
	@MainActor
	private func enqueueInsert(
		child: FileSystemItemType,
		into parent: FolderViewModel,
		fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector? = nil
	) {
		#if DEBUG
		let enqueueStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
		defer {
			fileAddPathMetricsCollector?.recordEnqueueInsert(durationMS: enqueueStartMS.map { debugPerfElapsedMS(since: $0) } ?? 0)
		}
		#endif
		pendingChildInserts[parent.id, default: []].append(child)
		pendingInsertParents[parent.id] = parent
		
		#if DEBUG
		guard !isScheduledInsertFlushSuppressedForTesting else { return }
		#endif
		guard !isInsertFlushScheduled else { return }
		isInsertFlushScheduled = true
		
		// Flush on the next turn (same tick/next tick), coalescing multiple inserts.
		Task { [weak self] in
			await Task.yield()
			await MainActor.run {
				self?.flushPendingInserts()
			}
		}
	}
	
	#if DEBUG
	@MainActor
	private func pendingInsertPerfSnapshot(forRootKey rootKey: RootKey) -> PendingInsertPerfSnapshot {
		let parentsByID = pendingInsertParents
		var rootKeys: Set<String> = []
		var totalEntryCount = 0
		var entryCountForRoot = 0
		for (parentID, children) in pendingChildInserts {
			totalEntryCount += children.count
			guard let parent = parentsByID[parentID] else { continue }
			let parentRootKey = StandardizedPath.absolute(parent.rootPath)
			rootKeys.insert(parentRootKey)
			if parentRootKey == rootKey {
				entryCountForRoot += children.count
			}
		}
		return PendingInsertPerfSnapshot(
			rootCount: rootKeys.count,
			entryCount: totalEntryCount,
			entryCountForRoot: entryCountForRoot
		)
	}
	#endif

	@MainActor
	private func flushPendingInserts() {
		#if DEBUG
		let debugEntryCountBeforeFlush = pendingChildInserts.values.reduce(0) { $0 + $1.count }
		let debugParentGroupCountBeforeFlush = pendingChildInserts.count
		let debugFlushStartMS = debugPerfTimestampMS()
		defer {
			if debugEntryCountBeforeFlush > 0 {
				pendingInsertFlushInvocationPerfSamples.append(
					PendingInsertFlushInvocationPerfSample(
						parentGroupCountBeforeFlush: debugParentGroupCountBeforeFlush,
						entryCountBeforeFlush: debugEntryCountBeforeFlush,
						durationMS: debugPerfElapsedMS(since: debugFlushStartMS)
					)
				)
			}
		}
		#endif
		// Always clear the schedule flag so new enqueues can schedule another flush.
		isInsertFlushScheduled = false
		
		guard !pendingChildInserts.isEmpty else {
			pendingInsertParents.removeAll(keepingCapacity: true)
			return
		}
		
		let pending = pendingChildInserts
		pendingChildInserts.removeAll(keepingCapacity: true)
		
		for (parentID, children) in pending {
			guard let parent = pendingInsertParents[parentID], !children.isEmpty else { continue }
			
			// Defensive dedupe in case identical inserts land in the same tick.
			var seen = Set<UUID>()
			let uniqueChildren: [FileSystemItemType] = children.filter { item in
				switch item {
				case .file(let file):
					return seen.insert(file.id).inserted
				case .folder(let folder):
					return seen.insert(folder.id).inserted
				}
			}
			guard !uniqueChildren.isEmpty else { continue }
			
			// One parent mutation per tick, per parent.
			if uniqueChildren.count == 1, let onlyChild = uniqueChildren.first {
				parent.addChild(onlyChild)
			} else {
				parent.addChildrenBatch(uniqueChildren, recomputeCheckbox: true)
			}
		}
		
		pendingInsertParents.removeAll(keepingCapacity: true)
	}
	
	/// Create the intermediate parent folder if it doesn’t exist,
	/// plus recursively ensure that folder is inserted in the tree.
	@MainActor
	private func createMissingParentFolder(
		parentPath: String,
		under root: FolderViewModel,
		fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector? = nil
	) {
		#if DEBUG
		let createMissingParentFolderStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
		defer {
			if let createMissingParentFolderStartMS {
				fileAddPathMetricsCollector?.recordCreateMissingParentFolderDuration(debugPerfElapsedMS(since: createMissingParentFolderStartMS))
			}
		}
		fileAddPathMetricsCollector?.recordCreateMissingParentFolderCall()
		#endif
		// 0️⃣ Nothing to create
		guard !parentPath.isEmpty else { return }
		
		let rootFull = root.standardizedFullPath
		let parentFull = ((rootFull as NSString)
			.appendingPathComponent(parentPath) as NSString)
			.standardizingPath
		
		// 1️⃣ Folder already in the index?
		if let existing = fileHierarchyIndex.foldersByFullPath[parentFull] {
			// ── If it is *not yet* inside the tree, attach it now ────────────
			let isRoot   = rootFolders.contains { $0.id == existing.id }
			let isLinked = (existing.parent != nil) || isRoot
			
			if !isLinked {
				// Ensure its own parent chain exists first
				let grandRel = (parentPath as NSString).deletingLastPathComponent
				if !grandRel.isEmpty {
					createMissingParentFolder(
						parentPath: grandRel,
						under: root,
						fileAddPathMetricsCollector: fileAddPathMetricsCollector
					)
				}
				// Finally hook it into the hierarchy
				insertFolder(existing, under: root, relativePath: parentPath)
			}
			return                                                      // ✅ done
		}
		
		// 2️⃣ Build and register a brand‑new FolderViewModel
		let folder   = Folder(
			name: (parentPath as NSString).lastPathComponent,
			path: parentFull,
			modificationDate: Date()
		)
		// For _git_data subtree: use dateNewest sort override so newest items appear first
		let isGitDataRoot = root.isSystemRoot && root.name == "_git_data"
		let sortOverride: SortMethod? = isGitDataRoot ? .dateNewest : nil
		let parentVM = FolderViewModel(folder: folder,
										rootPath: root.fullPath,
										sortMethodOverride: sortOverride)
		#if DEBUG
		fileAddPathMetricsCollector?.recordCreateMissingParentFolderCreated()
		#endif
		fileHierarchyIndex.insertFolder(parentVM, rootKey: root.standardizedFullPath)
		
		// 3️⃣ Make sure *its* parent exists
		let grandRel = (parentPath as NSString).deletingLastPathComponent
		if !grandRel.isEmpty {
			createMissingParentFolder(
				parentPath: grandRel,
				under: root,
				fileAddPathMetricsCollector: fileAddPathMetricsCollector
			)
		}
		
		// 4️⃣ Attach to the tree
		insertFolder(parentVM, under: root, relativePath: parentPath)
	}

	
	// ============================================================
	// MARK: - File insertion
	// ============================================================
	@MainActor
	private func replayFileAddParentContext(
		forStandardizedRelativePath relativePath: String,
		under root: FolderViewModel,
		cache: inout [String: ReplayFileAddParentContext],
		orderedCursorParentRelativePath: inout String?,
		orderedCursorContext: inout ReplayFileAddParentContext?,
		fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector?
	) -> ReplayFileAddParentContext {
		#if DEBUG
		let parentContextStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
		#endif
		if let cursorParentRelativePath = orderedCursorParentRelativePath,
			let cursorContext = orderedCursorContext,
			replayFileAddRelativePath(
				relativePath,
				hasParentRelativePath: cursorParentRelativePath
			) {
			#if DEBUG
			fileAddPathMetricsCollector?.recordParentContextOrderedReuse(hit: true)
			fileAddPathMetricsCollector?.recordParentContext(
				cacheHit: true,
				durationMS: parentContextStartMS.map { debugPerfElapsedMS(since: $0) } ?? 0
			)
			#endif
			return cursorContext
		}
		#if DEBUG
		fileAddPathMetricsCollector?.recordParentContextOrderedReuse(hit: false)
		#endif

		let parentRelativePath = replayFileAddParentRelativePath(
			forStandardizedRelativePath: relativePath,
			fileAddPathMetricsCollector: fileAddPathMetricsCollector
		)
		if let cached = cache[parentRelativePath] {
			orderedCursorParentRelativePath = parentRelativePath
			orderedCursorContext = cached
			#if DEBUG
			fileAddPathMetricsCollector?.recordParentContext(
				cacheHit: true,
				durationMS: parentContextStartMS.map { debugPerfElapsedMS(since: $0) } ?? 0
			)
			#endif
			return cached
		}

		let context: ReplayFileAddParentContext
		if parentRelativePath.isEmpty {
			context = ReplayFileAddParentContext(
				standardizedParentRelativePath: parentRelativePath,
				standardizedParentFullPath: nil,
				parentFolder: root
			)
			#if DEBUG
			fileAddPathMetricsCollector?.recordParentFolderLookup(
				parentRelativePath: parentRelativePath,
				result: root,
				returnedRoot: true
			)
			#endif
		} else {
			let parentFullPath = StandardizedPath.join(
				standardizedRoot: root.standardizedFullPath,
				standardizedRelativePath: parentRelativePath
			)
			let parent = fileHierarchyIndex.foldersByFullPath[parentFullPath]
			context = ReplayFileAddParentContext(
				standardizedParentRelativePath: parentRelativePath,
				standardizedParentFullPath: parentFullPath,
				parentFolder: parent
			)
			#if DEBUG
			fileAddPathMetricsCollector?.recordParentFolderLookup(
				parentRelativePath: parentRelativePath,
				result: parent,
				returnedRoot: false
			)
			#endif
		}

		cache[parentRelativePath] = context
		orderedCursorParentRelativePath = parentRelativePath
		orderedCursorContext = context
		#if DEBUG
		fileAddPathMetricsCollector?.recordParentContext(
			cacheHit: false,
			durationMS: parentContextStartMS.map { debugPerfElapsedMS(since: $0) } ?? 0
		)
		#endif
		return context
	}

	@MainActor
	private func replayFileAddParentRelativePath(
		forStandardizedRelativePath relativePath: String,
		fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector?
	) -> String {
		guard let slashIndex = relativePath.lastIndex(of: "/") else { return "" }
		#if DEBUG
		fileAddPathMetricsCollector?.recordParentContextParentStringBuild()
		#endif
		return String(relativePath[..<slashIndex])
	}

	private func replayFileAddRelativePath(
		_ relativePath: String,
		hasParentRelativePath parentRelativePath: String
	) -> Bool {
		guard let slashIndex = relativePath.lastIndex(of: "/") else {
			return parentRelativePath.isEmpty
		}
		guard relativePath.distance(from: relativePath.startIndex, to: slashIndex) == parentRelativePath.count else {
			return false
		}
		return relativePath[..<slashIndex].elementsEqual(parentRelativePath)
	}

	@MainActor
	@discardableResult
	private func cacheReplayFileAddParentContext(
		_ context: ReplayFileAddParentContext,
		resolvedParent: FolderViewModel,
		cache: inout [String: ReplayFileAddParentContext]
	) -> ReplayFileAddParentContext {
		let resolvedContext = ReplayFileAddParentContext(
			standardizedParentRelativePath: context.standardizedParentRelativePath,
			standardizedParentFullPath: context.standardizedParentFullPath,
			parentFolder: resolvedParent
		)
		cache[context.standardizedParentRelativePath] = resolvedContext
		return resolvedContext
	}

	@MainActor
	private func parentFolderForRelativePath(
		_ relativePath: String,
		under root: FolderViewModel,
		fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector? = nil
	) -> FolderViewModel? {
		let standardizedRelativePath = StandardizedPath.relative(relativePath)
		let parentRelativePath = StandardizedPath.relative(
			(standardizedRelativePath as NSString).deletingLastPathComponent
		)
		#if DEBUG
		if let fileAddPathMetricsCollector {
			guard !parentRelativePath.isEmpty else {
				fileAddPathMetricsCollector.recordParentFolderLookup(
					parentRelativePath: parentRelativePath,
					result: root,
					returnedRoot: true
				)
				return root
			}
			let parentFullPath = StandardizedPath.join(
				standardizedRoot: root.standardizedFullPath,
				standardizedRelativePath: parentRelativePath
			)
			let parent = fileHierarchyIndex.foldersByFullPath[parentFullPath]
			fileAddPathMetricsCollector.recordParentFolderLookup(
				parentRelativePath: parentRelativePath,
				result: parent,
				returnedRoot: false
			)
			return parent
		}
		#endif
		guard !parentRelativePath.isEmpty else { return root }
		let parentFullPath = StandardizedPath.join(
			standardizedRoot: root.standardizedFullPath,
			standardizedRelativePath: parentRelativePath
		)
		return fileHierarchyIndex.foldersByFullPath[parentFullPath]
	}

	@MainActor
	private func diskFileExistsStrictly(atStandardizedAbsolutePath path: String) -> Bool {
		var isDirectory = ObjCBool(false)
		guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
			return false
		}
		let url = URL(fileURLWithPath: path)
		if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
			if values.isSymbolicLink == true { return false }
			if values.isRegularFile == false { return false }
		}
		return true
	}

	@MainActor
	private func exactDiskCandidate(
		root: FolderViewModel,
		relativePath: String
	) -> ExactDiskFileCandidate? {
		let standardizedRelativePath = StandardizedPath.relative(relativePath)
		guard !standardizedRelativePath.isEmpty else { return nil }
		let standardizedAbsolutePath = StandardizedPath.absolute(StandardizedPath.join(
			standardizedRoot: root.standardizedFullPath,
			standardizedRelativePath: standardizedRelativePath
		))
		let rootPrefix = root.standardizedFullPath.hasSuffix("/") ? root.standardizedFullPath : root.standardizedFullPath + "/"
		guard standardizedAbsolutePath.hasPrefix(rootPrefix) else { return nil }
		guard diskFileExistsStrictly(atStandardizedAbsolutePath: standardizedAbsolutePath) else { return nil }
		return ExactDiskFileCandidate(
			root: root,
			standardizedRelativePath: standardizedRelativePath,
			standardizedAbsolutePath: standardizedAbsolutePath
		)
	}

	@MainActor
	private func resolveRootAlias(
		_ userPath: String,
		rootScope: LookupRootScope,
		requireRemainder: Bool
	) -> RootAliasResolution {
		WorkspaceAliasResolver.resolve(
			userPath: normalizeUserInputPath(userPath),
			roots: roots(in: rootScope).map(workspaceRootRef(for:)),
			options: RootAliasOptions(
				requireRemainder: requireRemainder,
				allowCompatibilityAlias: true,
				disambiguateRealSubpath: false
			)
		)
	}

	@MainActor
	private func resolveLeadingSlashRootAlias(
		from standardizedPath: String,
		rootScope: LookupRootScope,
		requireRemainder: Bool
	) -> RootAliasResolution? {
		guard standardizedPath.hasPrefix("/") else { return nil }
		let candidate = String(standardizedPath.dropFirst())
		guard !candidate.isEmpty else { return nil }
		if let firstComponent = candidate.split(separator: "/").first,
			Self.protectedLiteralTopLevelAbsoluteComponents.contains(firstComponent.lowercased()) {
			return nil
		}
		let resolution = resolveRootAlias(candidate, rootScope: rootScope, requireRemainder: requireRemainder)
		switch resolution {
		case .bareRoot, .prefixed, .ambiguous:
			return resolution
		case .notAliasPrefixed:
			return nil
		}
	}

	@MainActor
	private func exactDiskFileLookup(
		for userPath: String,
		rootScope: LookupRootScope
	) -> ExactDiskFileLookupResult {
		let normalized = normalizeUserInputPath(userPath).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalized.isEmpty, !StandardizedPath.containsNUL(normalized) else { return .candidates([]) }
		let standardized = (normalized as NSString).standardizingPath
		let scopedRoots = roots(in: rootScope)
		guard !scopedRoots.isEmpty else { return .candidates([]) }

		func literalRelativeLookup(_ relativePath: String) -> ExactDiskFileLookupResult {
			.candidates(scopedRoots.compactMap { exactDiskCandidate(root: $0, relativePath: relativePath) })
		}

		if standardized.hasPrefix("/") {
			if let root = scopedRoots
				.filter({ root in
					let rootPath = root.standardizedFullPath
					return standardized == rootPath || standardized.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
				})
				.max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count }) {
				let relativePath = RelativePath.fromStandardized(
					standardizedAbsolutePath: standardized,
					standardizedRootPath: root.standardizedFullPath
				)
				return .candidates(exactDiskCandidate(root: root, relativePath: relativePath).map { [$0] } ?? [])
			}

			guard let aliasResolution = resolveLeadingSlashRootAlias(from: standardized, rootScope: rootScope, requireRemainder: true) else {
				return .candidates([])
			}
			switch aliasResolution {
			case .prefixed(let rootRef, _, let remainder):
				guard let root = scopedRoots.first(where: { $0.id == rootRef.id }) else { return .candidates([]) }
				return .candidates(exactDiskCandidate(root: root, relativePath: remainder).map { [$0] } ?? [])
			case .ambiguous:
				return .ambiguous
			case .bareRoot, .notAliasPrefixed:
				return .candidates([])
			}
		}

		switch resolveRootAlias(standardized, rootScope: rootScope, requireRemainder: true) {
		case .prefixed(let rootRef, _, let remainder):
			if let root = scopedRoots.first(where: { $0.id == rootRef.id }),
				let candidate = exactDiskCandidate(root: root, relativePath: remainder) {
				return .candidates([candidate])
			}
			return literalRelativeLookup(standardized)
		case .ambiguous:
			return .ambiguous
		case .notAliasPrefixed, .bareRoot:
			return literalRelativeLookup(standardized)
		}
	}

	private enum CreatedWorkspaceFileMaterializationOutcome {
		case materialized
		case policyIneligible(CatalogRegularFileIneligibilityReason)
		case unexpectedFailure(String)
	}

	private func isExpectedCreatePolicyIneligibility(_ reason: CatalogRegularFileIneligibilityReason) -> Bool {
		switch reason {
		case .ignored, .symbolicLink, .nonRegularFile, .symlinkComponent, .outsideCanonicalRoot:
			return true
		case .invalidRelativePath, .outsideRoot, .missingOrDirectory:
			return false
		}
	}

	@MainActor
	@discardableResult
	private func materializeKnownWorkspaceFile(
		relativePath: String,
		onRootFolder root: FolderViewModel,
		fsService: FileSystemService,
		requestCodeScanImmediately: Bool
	) async -> FileViewModel? {
		let standardizedRelativePath = StandardizedPath.relative(relativePath)
		guard let candidate = exactDiskCandidate(root: root, relativePath: standardizedRelativePath) else {
			return nil
		}
		guard await fsService.catalogEligibleRegularFileExists(relativePath: candidate.standardizedRelativePath) else {
			return nil
		}
		if let existing = findFileByFullPath(candidate.standardizedAbsolutePath) {
			return existing
		}

		let metadata = FileViewModel.PrecomputedPathMetadata.preparedReplay(
			standardizedAbsolutePath: candidate.standardizedAbsolutePath,
			standardizedRelativePath: candidate.standardizedRelativePath,
			standardizedRootFolderPath: root.standardizedFullPath
		)
		guard let outcome = await handleNewFile(
			relativePath: candidate.standardizedRelativePath,
			onRootFolder: root,
			fsService: fsService,
			requestCodeScanImmediately: requestCodeScanImmediately,
			preparedReplayPathMetadata: metadata
		) else {
			return findFileByFullPath(candidate.standardizedAbsolutePath)
		}

		flushPendingInserts()
		refreshRootFolderState()
		invalidateStaticSnapshot(forRootFullPath: root.standardizedFullPath)
		onRootFoldersChanged?()
		fileSystemDeltasAppliedPublisher.send(
			FileSystemDeltasAppliedEvent(
				rootKey: root.standardizedFullPath,
				deltas: [.fileAdded(candidate.standardizedRelativePath)]
			)
		)
		return outcome.file
	}

	@MainActor
	private func materializeCreatedWorkspaceFile(
		relativePath: String,
		onRootFolder root: FolderViewModel,
		fsService: FileSystemService,
		requestCodeScanImmediately: Bool,
		creationKey: String?,
		selectAfterCreate: Bool
	) async throws {
		let standardizedRelativePath = StandardizedPath.relative(relativePath)
		let candidate = exactDiskCandidate(root: root, relativePath: standardizedRelativePath)
		let candidateRelativePath = candidate?.standardizedRelativePath ?? standardizedRelativePath
		let eligibility = await fsService.catalogRegularFileEligibility(relativePath: candidateRelativePath)

		let outcome: CreatedWorkspaceFileMaterializationOutcome
		guard let candidate else {
			switch eligibility {
			case .eligible:
				outcome = .unexpectedFailure("created path could not be mapped back into the loaded workspace catalog")
			case .ineligible(let reason):
				outcome = isExpectedCreatePolicyIneligibility(reason)
					? .policyIneligible(reason)
					: .unexpectedFailure("created path could not be mapped into the catalog and is not catalog-eligible: \(reason.description)")
			}
			try handleCreatedWorkspaceFileMaterializationOutcome(
				outcome,
				relativePath: standardizedRelativePath,
				creationKey: creationKey,
				selectAfterCreate: selectAfterCreate
			)
			return
		}

		switch eligibility {
		case .ineligible(let reason):
			outcome = isExpectedCreatePolicyIneligibility(reason)
				? .policyIneligible(reason)
				: .unexpectedFailure("created path is not catalog-eligible after disk write: \(reason.description)")
		case .eligible:
			if await materializeKnownWorkspaceFile(
				relativePath: candidate.standardizedRelativePath,
				onRootFolder: root,
				fsService: fsService,
				requestCodeScanImmediately: requestCodeScanImmediately
			) != nil {
				outcome = .materialized
			} else {
				outcome = .unexpectedFailure("eligible file exists on disk but handleNewFile did not return a catalog entry")
			}
		}

		try handleCreatedWorkspaceFileMaterializationOutcome(
			outcome,
			relativePath: candidateRelativePath,
			creationKey: creationKey,
			selectAfterCreate: selectAfterCreate
		)
	}

	@MainActor
	private func handleCreatedWorkspaceFileMaterializationOutcome(
		_ outcome: CreatedWorkspaceFileMaterializationOutcome,
		relativePath: String,
		creationKey: String?,
		selectAfterCreate: Bool
	) throws {
		switch outcome {
		case .materialized:
			return
		case .policyIneligible(let reason):
			if selectAfterCreate, let creationKey {
				newlyCreatedFilePaths.remove(creationKey)
			}
			#if DEBUG
			if Self.isLoggingEnabled {
				print("Created file '\(relativePath)' is not catalog materialized because it is policy-ineligible: \(reason.description)")
			}
			#endif
		case .unexpectedFailure(let reason):
			throw FileManagerError.fileSystemServiceNotFoundWithContext(
				"Created file '\(relativePath)' on disk, but RepoPrompt could not add it to the workspace catalog: \(reason)."
			)
		}
	}

	@MainActor
	private func reconcileExactDiskFileIfPresent(
		_ userPath: String,
		rootScope: LookupRootScope
	) async -> FileViewModel? {
		switch exactDiskFileLookup(for: userPath, rootScope: rootScope) {
		case .candidates(let candidates):
			var eligibleCandidates: [(candidate: ExactDiskFileCandidate, fsService: FileSystemService)] = []
			for candidate in candidates {
				guard let fsService = getFileSystemService(for: candidate.root.standardizedFullPath) else { continue }
				guard await fsService.catalogEligibleRegularFileExists(relativePath: candidate.standardizedRelativePath) else { continue }
				eligibleCandidates.append((candidate, fsService))
			}
			guard eligibleCandidates.count == 1, let eligible = eligibleCandidates.first else {
				return nil
			}
			return await materializeKnownWorkspaceFile(
				relativePath: eligible.candidate.standardizedRelativePath,
				onRootFolder: eligible.candidate.root,
				fsService: eligible.fsService,
				requestCodeScanImmediately: false
			)
		case .ambiguous:
			return nil
		}
	}

	@MainActor
	private func clearRemovedFileCaches(_ files: [FileViewModel]) async {
		guard !files.isEmpty else { return }
		var seenIDs = Set<UUID>()
		for file in files where seenIDs.insert(file.id).inserted {
			await file.clearContentForRemoval()
		}
	}

	@MainActor
	private func catalogFileStillExistsOnDisk(_ file: FileViewModel) async -> Bool {
		guard let service = getFileSystemService(for: file.standardizedRootFolderPath) else {
			return false
		}
		return await service.regularFileExistsOnDisk(relativePath: file.standardizedRelativePath)
	}

	private static func isMissingFileError(_ error: Error) -> Bool {
		if case FileSystemError.fileNotFound = error {
			return true
		}
		let nsError = error as NSError
		return nsError.domain == NSCocoaErrorDomain && [
			NSFileReadNoSuchFileError,
			NSFileNoSuchFileError
		].contains(nsError.code)
	}

	@MainActor
	private func shouldValidateCatalogDiskPresence(for profile: PathLocateProfile) -> Bool {
		switch profile {
		case .mcpRead, .mcpSearchScope, .moveSourceExact:
			return true
		case .uiAssisted, .createBestEffort, .createRequireUnambiguous, .mcpSelection:
			return false
		}
	}

	@MainActor
	private func validateCatalogFileStillPresent(_ file: FileViewModel) async -> FileViewModel? {
		if await catalogFileStillExistsOnDisk(file) {
			return file
		}
		await pruneCatalogFileMissingOnDisk(file)
		return nil
	}

	@MainActor
	private func validateCatalogFilesStillPresent(
		_ results: [String: FileViewModel],
		for profile: PathLocateProfile
	) async -> [String: FileViewModel] {
		guard shouldValidateCatalogDiskPresence(for: profile) else { return results }
		var validated: [String: FileViewModel] = [:]
		validated.reserveCapacity(results.count)
		for (input, file) in results {
			if let presentFile = await validateCatalogFileStillPresent(file) {
				validated[input] = presentFile
			}
		}
		return validated
	}

	@MainActor
	private func pruneCatalogFileMissingOnDisk(_ file: FileViewModel) async {
		if let root = rootFolders.first(where: { $0.standardizedFullPath == file.standardizedRootFolderPath }) {
			await dematerializeKnownWorkspaceItem(relativePath: file.standardizedRelativePath, onRootFolder: root)
			return
		}
		await clearRemovedFileCaches([file])
		fileHierarchyIndex.removeFile(forKey: file.standardizedFullPath, expectedRootKey: file.standardizedRootFolderPath)
		removeFileFromParentChildrenArray(file)
		invalidateStaticSnapshot(forRootFullPath: file.standardizedRootFolderPath)
		onRootFoldersChanged?()
	}

	@MainActor
	func readWorkspaceFileContentStrictly(_ file: FileViewModel) async throws -> String {
		guard let service = getFileSystemService(for: file.standardizedRootFolderPath) else {
			throw StrictWorkspaceFileContentError.serviceUnavailable(rootPath: file.standardizedRootFolderPath)
		}

		guard await service.regularFileExistsOnDisk(relativePath: file.standardizedRelativePath) else {
			await pruneCatalogFileMissingOnDisk(file)
			throw StrictWorkspaceFileContentError.fileMissing(path: file.standardizedFullPath)
		}

		let prior = await file.cachedContentSnapshot()
		let didPreInvalidate = prior.content == nil || !prior.isFresh
		if didPreInvalidate {
			await file.setModificationDate(prior.modificationDate, forceInvalidation: true)
			codemapCapableAPIsByFullPath.removeValue(forKey: file.standardizedFullPath)
		}

		let contentOpt: String?
		let diskDate: Date
		do {
			(contentOpt, diskDate) = try await service.loadContentWithDate(ofRelativePath: file.standardizedRelativePath)
		} catch {
			if Self.isMissingFileError(error) {
				await pruneCatalogFileMissingOnDisk(file)
				throw StrictWorkspaceFileContentError.fileMissing(path: file.standardizedFullPath)
			}
			throw StrictWorkspaceFileContentError.readFailed(path: file.standardizedFullPath, underlying: error)
		}

		let normalizedContent = contentOpt ?? "[Binary file]"
		let metadataChanged = prior.modificationDate != diskDate
		let contentChanged = prior.content.map { $0 != normalizedContent } ?? false
		let cacheWasStale = prior.content != nil && !prior.isFresh
		if metadataChanged || contentChanged || cacheWasStale || didPreInvalidate {
			if !didPreInvalidate {
				await file.setModificationDate(diskDate, forceInvalidation: true)
			}
			codemapCapableAPIsByFullPath.removeValue(forKey: file.standardizedFullPath)
		}

		return await file.applyLoadedDiskContent(contentOpt, modificationDate: diskDate)
	}

	@MainActor
	@discardableResult
	private func dematerializeKnownWorkspaceItem(
		relativePath: String,
		onRootFolder root: FolderViewModel,
		publishDelta: Bool = true
	) async -> Bool {
		let standardizedRelativePath = StandardizedPath.relative(relativePath)
		let standardizedAbsolutePath = StandardizedPath.join(
			standardizedRoot: root.standardizedFullPath,
			standardizedRelativePath: standardizedRelativePath
		)

		if let fileVM = findFileByFullPath(standardizedAbsolutePath) {
			let formerParentFolder = fileVM.parentFolder ?? parentFolderForRelativePath(standardizedRelativePath, under: root)
			await clearRemovedFileCaches([fileVM])
			removeFileFromParentChildrenArray(fileVM)
			fileHierarchyIndex.removeFile(forKey: standardizedAbsolutePath, expectedRootKey: root.standardizedFullPath)
			if let formerParentFolder {
				recomputeAncestorStates(startingAtFolders: [formerParentFolder])
			} else {
				_ = updateFolderStateRecursive(root)
			}
			invalidateStaticSnapshot(forRootFullPath: root.standardizedFullPath)
			onRootFoldersChanged?()
			if publishDelta {
				fileSystemDeltasAppliedPublisher.send(
					FileSystemDeltasAppliedEvent(rootKey: root.standardizedFullPath, deltas: [.fileRemoved(standardizedRelativePath)])
				)
			}
			return true
		}

		let removedSubtree: RemovedFolderSubtree?
		if let folderVM = findFolderByFullPath(standardizedAbsolutePath) {
			removedSubtree = removeFolderRecursive(in: root, relativePath: folderVM.relativePath)
		} else {
			removedSubtree = removeFolderRecursive(in: root, relativePath: standardizedRelativePath)
		}
		guard let removedSubtree else { return false }

		let subtreeSnapshot = collectSubtreeSnapshot(from: removedSubtree.removedFolder)
		await clearRemovedFileCaches(subtreeSnapshot.fileViewModels)
		let cleanupOutcome = performBatchedIncrementalRemovedSubtreeCleanup([removedSubtree], rootKey: root.standardizedFullPath)
		if !cleanupOutcome.succeeded {
			rebuildFileHierarchyIndex(for: root)
		}
		if let formerParentFolder = removedSubtree.formerParentFolder ?? parentFolderForRelativePath(standardizedRelativePath, under: root) {
			recomputeAncestorStates(startingAtFolders: [formerParentFolder])
		} else {
			_ = updateFolderStateRecursive(root)
		}
		invalidateStaticSnapshot(forRootFullPath: root.standardizedFullPath)
		onRootFoldersChanged?()
		if publishDelta {
			fileSystemDeltasAppliedPublisher.send(
				FileSystemDeltasAppliedEvent(rootKey: root.standardizedFullPath, deltas: [.folderRemoved(standardizedRelativePath)])
			)
		}
		return true
	}

	@MainActor
private func handleNewFile(
	relativePath: String,
	onRootFolder root: FolderViewModel,
	fsService    : FileSystemService,
	requestCodeScanImmediately: Bool = true,
	preparedReplayPathMetadata: FileViewModel.PrecomputedPathMetadata? = nil,
	replayParentContext: ReplayFileAddParentContext? = nil,
	fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector? = nil
) async -> FileAdditionApplyOutcome? {
	#if DEBUG
	fileAddPathMetricsCollector?.recordHandleNewFile()
	#endif
	let stdAbs: String
	if let preparedReplayPathMetadata {
		stdAbs = preparedReplayPathMetadata.standardizedFullPath
	} else {
		let absPath = (root.standardizedFullPath as NSString).appendingPathComponent(relativePath)
		stdAbs = (absPath as NSString).standardizingPath
	}
	let intendedParentFolder: FolderViewModel?
	if let replayParentContext {
		intendedParentFolder = replayParentContext.parentFolder
	} else {
		intendedParentFolder = parentFolderForRelativePath(
			relativePath,
			under: root,
			fileAddPathMetricsCollector: fileAddPathMetricsCollector
		)
	}

	// If already tracked, only refresh m-date & scan
	#if DEBUG
	let existingLookupStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
	#endif
	#if DEBUG
	fileAddPathMetricsCollector?.recordFindExistingStandardizedFastPath()
	#endif
	let existingFile = findFileByStandardizedFullPath(stdAbs)
	#if DEBUG
	fileAddPathMetricsCollector?.recordFindExistingFileLookup(
		foundExisting: existingFile != nil,
		durationMS: existingLookupStartMS.map { debugPerfElapsedMS(since: $0) } ?? 0
	)
	#endif
	if let existing = existingFile {
		do {
			let diskDate = try await fsService.getFileModificationDate(atRelativePath: relativePath)
			await existing.setModificationDate(diskDate, forceInvalidation: true)
		} catch {
			await existing.setModificationDate(Date(), forceInvalidation: true)
		}
		codemapCapableAPIsByFullPath.removeValue(forKey: existing.standardizedFullPath)
		if requestCodeScanImmediately {
			requestCodeScan(for: existing)
		}
		if consumeNewlyCreatedFileMarkerIfPresent(
			rootFullPath: root.standardizedFullPath,
			relativePath: relativePath,
			fileAddPathMetricsCollector: fileAddPathMetricsCollector
		) {
			performSelectionBatch { existing.setIsChecked(true) }
		}
		return FileAdditionApplyOutcome(
			file: existing,
			parentFolderForStateRecompute: existing.parentFolder ?? intendedParentFolder
		)
	}

	#if DEBUG
	let fileViewModelConstructionStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
	#endif
	let newFile = File(name: (relativePath as NSString).lastPathComponent,
						path: stdAbs,
						modificationDate: Date())

	let fileVM: FileViewModel
	if let preparedReplayPathMetadata {
		fileVM = FileViewModel(
			file: newFile,
			rootIdentifier: root.id,
			rootFolderPath: root.fullPath,
			fileSystemService: fsService,
			precomputedPathMetadata: preparedReplayPathMetadata
		)
	} else {
		fileVM = FileViewModel(file:             newFile,
									rootPath:         root.fullPath,
									rootIdentifier:   root.id,
									rootFolderPath:   root.fullPath,
									fileSystemService: fsService)
	}
	#if DEBUG
	fileAddPathMetricsCollector?.recordFileViewModelConstruction(durationMS: fileViewModelConstructionStartMS.map { debugPerfElapsedMS(since: $0) } ?? 0)
	#endif

	#if DEBUG
	let selectionCallbackAttachStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
	#endif
	attachSelectionCallback(to: fileVM)                // ← lightweight
	#if DEBUG
	if let selectionCallbackAttachStartMS {
		fileAddPathMetricsCollector?.recordSelectionCallbackAttach(durationMS: debugPerfElapsedMS(since: selectionCallbackAttachStartMS))
	}
	#endif

	#if DEBUG
	let fileHierarchyInsertStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
	#endif
	fileHierarchyIndex.insertFile(fileVM, rootKey: root.standardizedFullPath)
	#if DEBUG
	fileAddPathMetricsCollector?.recordFileHierarchyInsertFile(durationMS: fileHierarchyInsertStartMS.map { debugPerfElapsedMS(since: $0) } ?? 0)
	#endif

	if requestCodeScanImmediately {
		requestCodeScan(for: fileVM)
	}
	#if DEBUG
	let insertFileStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
	#endif
	let insertedParentFolder = insertFile(
		fileVM,
		under: root,
		relativePath: relativePath,
		replayParentContext: replayParentContext,
		fileAddPathMetricsCollector: fileAddPathMetricsCollector
	)
	#if DEBUG
	if let insertFileStartMS {
		fileAddPathMetricsCollector?.recordInsertFileDuration(debugPerfElapsedMS(since: insertFileStartMS))
	}
	#endif

	if consumeNewlyCreatedFileMarkerIfPresent(
		rootFullPath: root.standardizedFullPath,
		relativePath: relativePath,
		fileAddPathMetricsCollector: fileAddPathMetricsCollector
	) {
		performSelectionBatch { fileVM.setIsChecked(true) }
	}

	let parentFolderForStateRecompute: FolderViewModel?
	if replayParentContext != nil {
		parentFolderForStateRecompute = insertedParentFolder ?? intendedParentFolder
	} else {
		parentFolderForStateRecompute = parentFolderForRelativePath(
			relativePath,
			under: root,
			fileAddPathMetricsCollector: fileAddPathMetricsCollector
		) ?? intendedParentFolder
	}
	return FileAdditionApplyOutcome(
		file: fileVM,
		parentFolderForStateRecompute: parentFolderForStateRecompute
	)
}
	
	@MainActor
	@discardableResult
	private func insertFile(
		_ fileVM     : FileViewModel,
		under root   : FolderViewModel,
		relativePath : String,
		replayParentContext: ReplayFileAddParentContext? = nil,
		fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector? = nil
	) -> FolderViewModel? {
		#if DEBUG
		fileAddPathMetricsCollector?.recordInsertFileCall()
		#endif
		if let replayParentContext {
			guard !replayParentContext.isRootParent else {
				enqueueInsert(child: .file(fileVM), into: root, fileAddPathMetricsCollector: fileAddPathMetricsCollector)
				return root
			}
			guard let parentFull = replayParentContext.standardizedParentFullPath else {
				enqueueInsert(child: .file(fileVM), into: root, fileAddPathMetricsCollector: fileAddPathMetricsCollector)
				return root
			}
			let parentRel = replayParentContext.standardizedParentRelativePath
			if let parent = replayParentContext.parentFolder {
				let isRoot = rootFolders.contains { $0.id == parent.id }
				let isLinked = (parent.parent != nil) || isRoot
				if !isLinked {
					createMissingParentFolder(
						parentPath: parentRel,
						under: root,
						fileAddPathMetricsCollector: fileAddPathMetricsCollector
					)
				}
				enqueueInsert(child: .file(fileVM), into: parent, fileAddPathMetricsCollector: fileAddPathMetricsCollector)
				return parent
			}

			createMissingParentFolder(
				parentPath: parentRel,
				under: root,
				fileAddPathMetricsCollector: fileAddPathMetricsCollector
			)
			let createdParent = fileHierarchyIndex.foldersByFullPath[parentFull]
			#if DEBUG
			fileAddPathMetricsCollector?.recordInsertFileParentLookup(result: createdParent)
			#endif
			if let parent = createdParent {
				enqueueInsert(child: .file(fileVM), into: parent, fileAddPathMetricsCollector: fileAddPathMetricsCollector)
				return parent
			}
			enqueueInsert(child: .file(fileVM), into: root, fileAddPathMetricsCollector: fileAddPathMetricsCollector)
			return root
		}

		#if DEBUG
		let parentPathDerivationStartMS = fileAddPathMetricsCollector?.isDetailedWallAttributionEnabled == true ? debugPerfTimestampMS() : nil
		#endif
		let comps = relativePath.split(separator: "/").map(String.init)
		guard comps.count > 1 else {
			enqueueInsert(child: .file(fileVM), into: root, fileAddPathMetricsCollector: fileAddPathMetricsCollector)
			return root
		}
		
		let parentRel  = comps.dropLast().joined(separator: "/")
		#if DEBUG
		fileAddPathMetricsCollector?.recordInsertFileParentPathDerivation(
			parentRelativePath: parentRel,
			durationMS: parentPathDerivationStartMS.map { debugPerfElapsedMS(since: $0) } ?? 0
		)
		#endif
		let rootFull = root.standardizedFullPath
		let parentFull = ((rootFull as NSString)
			.appendingPathComponent(parentRel) as NSString)
			.standardizingPath
		
		let indexedParent = fileHierarchyIndex.foldersByFullPath[parentFull]
		#if DEBUG
		fileAddPathMetricsCollector?.recordInsertFileParentLookup(result: indexedParent)
		#endif
		if let parent = indexedParent {
			// ⚠️ If parent is detached, fix the chain first
			let isRoot   = rootFolders.contains { $0.id == parent.id }
			let isLinked = (parent.parent != nil) || isRoot
			if !isLinked {
				createMissingParentFolder(
					parentPath: parentRel,
					under: root,
					fileAddPathMetricsCollector: fileAddPathMetricsCollector
				)
			}
			// Mutate the same instance we enqueue into (avoid "re-read then update old ref").
			let refreshedParent = fileHierarchyIndex.foldersByFullPath[parentFull]
			#if DEBUG
			fileAddPathMetricsCollector?.recordInsertFileParentLookup(result: refreshedParent)
			#endif
			let targetParent = refreshedParent ?? parent
			enqueueInsert(child: .file(fileVM), into: targetParent, fileAddPathMetricsCollector: fileAddPathMetricsCollector)
			return targetParent                                             // ✅ done
		}
		
		// Parent chain missing – create once, then enqueue under the now-materialized parent
		createMissingParentFolder(
			parentPath: parentRel,
			under: root,
			fileAddPathMetricsCollector: fileAddPathMetricsCollector
		)
		let createdParent = fileHierarchyIndex.foldersByFullPath[parentFull]
		#if DEBUG
		fileAddPathMetricsCollector?.recordInsertFileParentLookup(result: createdParent)
		#endif
		if let parent = createdParent {
			enqueueInsert(child: .file(fileVM), into: parent, fileAddPathMetricsCollector: fileAddPathMetricsCollector)
			return parent
		} else {
			// Defensive fallback; should be unreachable but avoids dropping inserts.
			enqueueInsert(child: .file(fileVM), into: root, fileAddPathMetricsCollector: fileAddPathMetricsCollector)
			return root
		}
	}

	
@MainActor
@discardableResult
private func removeFolderRecursive(in folder: FolderViewModel, relativePath: String) -> RemovedFolderSubtree? {
	var visitedFolderIDs = Set<UUID>()
	return removeFolderRecursive(in: folder, relativePath: relativePath, visitedFolderIDs: &visitedFolderIDs)
}

@MainActor
@discardableResult
private func removeFolderRecursive(
	in folder: FolderViewModel,
	relativePath: String,
	visitedFolderIDs: inout Set<UUID>
) -> RemovedFolderSubtree? {
	guard visitedFolderIDs.insert(folder.id).inserted else { return nil }
	for child in folder.children {
		switch child {
		case .folder(let subFolder):
			if subFolder.relativePath == relativePath {
				let removed = RemovedFolderSubtree(
					removedFolder: subFolder,
					formerParentFolder: folder,
					removedFolderFullPath: subFolder.standardizedFullPath
				)
				unregisterExpansionTracking(for: subFolder)
				folder.removeSubfolder(subFolder)
				return removed
			}
			if let removed = removeFolderRecursive(in: subFolder, relativePath: relativePath, visitedFolderIDs: &visitedFolderIDs) {
				return removed
			}
		case .file:
			continue
		}
	}
	return nil
}

	@MainActor
	private func collectSubtreeSnapshot(from folder: FolderViewModel) -> (
		folderPaths: Set<String>,
		filePaths: Set<String>,
		fileViewModels: [FileViewModel]
	) {
		var folderPaths: Set<String> = []
		var filePaths: Set<String> = []
		var fileViewModels: [FileViewModel] = []
		var visitedFolderIDs: Set<UUID> = []
		var stack: [FolderViewModel] = [folder]
		while let current = stack.popLast() {
			guard visitedFolderIDs.insert(current.id).inserted else { continue }
			folderPaths.insert(current.standardizedFullPath)
			for child in current.children {
				switch child {
				case .folder(let subFolder):
					stack.append(subFolder)
				case .file(let fileVM):
					filePaths.insert(fileVM.standardizedFullPath)
					fileViewModels.append(fileVM)
				}
			}
		}
		return (folderPaths, filePaths, fileViewModels)
	}

	@MainActor
	private func pruneRemovedFilesFromSelectionAndCodemap(_ files: [FileViewModel]) {
		guard !files.isEmpty else { return }
		var uniqueFilesByID: [UUID: FileViewModel] = [:]
		for file in files {
			uniqueFilesByID[file.id] = file
		}
		let uniqueFiles = Array(uniqueFilesByID.values)
		let fileIDs = Set(uniqueFiles.map(\.id))
		var shouldRebuildSelectionSliceSnapshot = removeSelectedIDs(fileIDs)
		if !fileIDs.isDisjoint(with: autoCodemapFileIDs) {
			autoCodemapFileIDs.subtract(fileIDs)
			autoCodemapFiles.removeAll { fileIDs.contains($0.id) }
			codeMapUpdatePublisher.send(())
		}
		for file in uniqueFiles {
			codemapCapableAPIsByFullPath.removeValue(forKey: file.standardizedFullPath)
			if selectionSlicesByFileID.removeValue(forKey: file.id) != nil {
				shouldRebuildSelectionSliceSnapshot = true
			}
			let rootKey = file.standardizedRootFolderPath
			let relativeKey = file.standardizedRelativePath
			if currentSlicesByRoot[rootKey]?[relativeKey] != nil {
				currentSlicesByRoot[rootKey]?[relativeKey] = nil
				if currentSlicesByRoot[rootKey]?.isEmpty == true {
					currentSlicesByRoot.removeValue(forKey: rootKey)
				}
				shouldRebuildSelectionSliceSnapshot = true
			}
			sliceRebaseTasksByFullPath[file.standardizedFullPath]?.cancel()
			sliceRebaseTasksByFullPath.removeValue(forKey: file.standardizedFullPath)
			sliceRebaseTaskIDsByFullPath.removeValue(forKey: file.standardizedFullPath)
			noSlicesKnownRevisionByFullPath.removeValue(forKey: file.standardizedFullPath)
		}
		if shouldRebuildSelectionSliceSnapshot {
			requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
		}
	}

	@MainActor
	private func performBatchedIncrementalRemovedSubtreeCleanup(
		_ removedSubtrees: [RemovedFolderSubtree],
		rootKey: String
	) -> IncrementalRemovedSubtreeCleanupOutcome {
		guard !removedSubtrees.isEmpty else {
			return IncrementalRemovedSubtreeCleanupOutcome(
				succeeded: true,
				removedFolderCount: 0,
				removedFileCount: 0,
				usedFallbackGlobalScan: false,
				descendantScanInvocationCount: 0,
				scannedFolderCandidateCount: 0,
				scannedFileCandidateCount: 0
			)
		}

		let signpost = RepoFileReplayPerf.begin("batchedRemovedSubtreeCleanup")
		defer { RepoFileReplayPerf.end("batchedRemovedSubtreeCleanup", signpost) }

		var snapshotFolderPaths: Set<String> = []
		var snapshotFilePaths: Set<String> = []
		var snapshotFileViewModels: [FileViewModel] = []
		var removedRootFolderPaths: Set<String> = []

		for removed in removedSubtrees {
			let subtreeSnapshot = collectSubtreeSnapshot(from: removed.removedFolder)
			snapshotFolderPaths.formUnion(subtreeSnapshot.folderPaths)
			snapshotFilePaths.formUnion(subtreeSnapshot.filePaths)
			snapshotFileViewModels.append(contentsOf: subtreeSnapshot.fileViewModels)
			removedRootFolderPaths.insert(removed.removedFolderFullPath)
		}

		let indexedDescendants = fileHierarchyIndex.ownedDescendantPaths(
			forRootKey: rootKey,
			underFolderPaths: removedRootFolderPaths
		)
		guard snapshotFolderPaths == indexedDescendants.folderPaths,
			snapshotFilePaths == indexedDescendants.filePaths
		else {
			let indexedFileViewModels = indexedDescendants.filePaths.compactMap {
				fileHierarchyIndex.filesByFullPath[$0]
			}
			pruneRemovedFilesFromSelectionAndCodemap(snapshotFileViewModels + indexedFileViewModels)
			return IncrementalRemovedSubtreeCleanupOutcome(
				succeeded: false,
				removedFolderCount: max(snapshotFolderPaths.count, indexedDescendants.folderPaths.count),
				removedFileCount: max(snapshotFilePaths.count, indexedDescendants.filePaths.count),
				usedFallbackGlobalScan: indexedDescendants.usedFallbackGlobalScan,
				descendantScanInvocationCount: indexedDescendants.scanInvocationCount,
				scannedFolderCandidateCount: indexedDescendants.scannedFolderCandidateCount,
				scannedFileCandidateCount: indexedDescendants.scannedFileCandidateCount
			)
		}
		pruneRemovedFilesFromSelectionAndCodemap(snapshotFileViewModels)
		fileHierarchyIndex.removeSubtreeEntries(
			forRootKey: rootKey,
			folderPaths: snapshotFolderPaths,
			filePaths: snapshotFilePaths
		)
		return IncrementalRemovedSubtreeCleanupOutcome(
			succeeded: true,
			removedFolderCount: snapshotFolderPaths.count,
			removedFileCount: snapshotFilePaths.count,
			usedFallbackGlobalScan: indexedDescendants.usedFallbackGlobalScan,
			descendantScanInvocationCount: indexedDescendants.scanInvocationCount,
			scannedFolderCandidateCount: indexedDescendants.scannedFolderCandidateCount,
			scannedFileCandidateCount: indexedDescendants.scannedFileCandidateCount
		)
	}

	@MainActor
	private func flushReplayChunkCodeScanBatch(_ files: [FileViewModel]) {
		guard !files.isEmpty else { return }
		enqueueReplayScanRequests(forFiles: files)
	}

	@MainActor
	private func scheduleSliceRebasesForModifiedFiles(_ requests: [ReplaySliceRebaseRequest]) {
		guard !requests.isEmpty else { return }
		for request in requests {
			scheduleSliceRebaseForModifiedFile(
				request.file,
				relativePath: request.relativePath,
				fsService: request.fsService
			)
		}
	}
	
	// ─────────────────────────────────────────────────────────────────────────────
	// MARK: – Helpers for expanding relative paths into absolute candidates
	// ─────────────────────────────────────────────────────────────────────────────
	@MainActor
	private func absolutePathCandidates(forRelativePath relPath: String) -> [String] {
		absolutePathCandidates(forRelativePath: relPath, scope: .allLoaded)
	}

	@MainActor
	private func absolutePathCandidates(
		forRelativePath relPath: String,
		scope: LookupRootScope
	) -> [String] {
		let standardizedRelativePath = StandardizedPath.relative(relPath)
		let roots = roots(in: scope)
		return roots.map { root in
			StandardizedPath.join(
				standardizedRoot: root.standardizedFullPath,
				standardizedRelativePath: standardizedRelativePath
			)
		}
	}
	
	// ─────────────────────────────────────────────────────────────────────────────
	// MARK: - Selection Management Helpers
	// ─────────────────────────────────────────────────────────────────────────────
	/// Unified helper to drop all selections under a given folder path.
	/// Keeps selectedFiles and selectedFileIDs in sync.
	@MainActor
	private func dropSelections(underFolderFullPath folderFullPath: String) {
		guard !selectedFiles.isEmpty else { return }
		let standardizedFolderFullPath = StandardizedPath.absolute(folderFullPath)
		let toRemoveIDs = Set(selectedFiles
			.lazy
			.filter { StandardizedPath.isDescendant($0.standardizedFullPath, of: standardizedFolderFullPath) }
			.map(\.id))
		guard !toRemoveIDs.isEmpty else { return }
		_ = removeSelectedIDs(toRemoveIDs)
	}
	
	// MARK: - PathMatcher integration
	// ─────────────────────────────────────────────────────────────────────────────
	
	/// Returns the current static path match context (StaticPathMatchData + selection + signature).
	/// Selection signature is precomputed here (O(n)) to avoid work on the worker actor.
	@MainActor
	private func currentStaticPathMatchContext(
		scope: LookupRootScope = .allLoaded
	) -> (StaticPathMatchData, Set<String>, SelectionSig) {
		if snapshotCache.staticDataByScope[scope] == nil {
			let roots = roots(in: scope)
			let allowedRootPaths = Set(roots.map(\.standardizedFullPath))
			let allFiles = fileHierarchyIndex.filesByFullPath
			let allFolders = fileHierarchyIndex.foldersByFullPath
			let files: [String: FileViewModel]
			let folders: [String: FolderViewModel]
			if scope == .allLoaded {
				files = allFiles
				folders = allFolders
			} else {
				files = allFiles.filter { allowedRootPaths.contains($0.value.standardizedRootFolderPath) }
				folders = allFolders.filter { allowedRootPaths.contains(StandardizedPath.absolute($0.value.rootPath)) }
			}

			let scopeDiscriminator: UInt64 = switch scope {
			case .visibleWorkspace: 0
			case .visibleWorkspacePlusGitData: 1
			case .allLoaded: 2
			}
			let scopeID = snapshotCache.generation &* 3 &+ scopeDiscriminator
			let built = Self.buildStaticSnapshot(
				files: files,
				folders: folders,
				rootFolders: roots,
				id: scopeID
			)
			snapshotCache.staticDataByScope[scope] = built
		}
		
		let staticData = snapshotCache.staticDataByScope[scope] ?? Self.buildStaticSnapshot(
			files: [:],
			folders: [:],
			rootFolders: [],
			id: 0
		)
		
		// Dynamic part – current selection + precomputed signature
		let selectedFullPaths = Set(selectedFiles.map(\.fullPath))
		let selectionSig = selectionSignature(for: selectedFullPaths)
		
		return (staticData, selectedFullPaths, selectionSig)
	}
	
	
	private static func buildStaticSnapshot(
		files: [String: FileViewModel],
		folders: [String: FolderViewModel],
		rootFolders: [FolderViewModel],
		id: UInt64
	) -> StaticPathMatchData {
		// Build frozen file records
		let fileRecords: [String: FileRecord] = Dictionary(uniqueKeysWithValues: files.map { (key, vm) in
			let frozen = FrozenFileRecord(from: vm)
			return (key, frozen as FileRecord)
		})

		// Build frozen folder records
		let folderRecords: [String: FolderRecord] = Dictionary(uniqueKeysWithValues: folders.map { (key, vm) in
			let frozen = FrozenFolderRecord(from: vm)
			return (key, frozen as FolderRecord)
		})

		// Build frozen root folder list
		let rootRecords: [FolderRecord] = rootFolders.map { folder in
			FrozenFolderRecord(from: folder) as FolderRecord
		}

		return StaticPathMatchData(
			filesByFullPath:   fileRecords,
			foldersByFullPath: folderRecords,
			rootFolders:       rootRecords,
			id:                id
		)
	}
	
	// MARK: - Helper for AI Response Processing
	
	/// Refreshes a specific path in our index by checking disk.
	/// `relativePath`     – path **relative to `root`** (no leading "/")
	/// If the folder hierarchy or the file is not yet represented in the UI it
	/// gets created and inserted on-the-fly.
	@MainActor
	private func refreshSpecificPath(_ relativePath: String,
										inRoot root: FolderViewModel) async
	{
		// ────────────────────── sanity checks ──────────────────────
		let trimmedRel = relativePath
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedRel.isEmpty else { return }
		
		// Split once, we need both the folder path & file name.
		let comps      = trimmedRel.split(separator: "/").map(String.init)
		guard comps.last != nil else { return }
		let folderPath = comps.dropLast().joined(separator: "/")        // may be ""
		
		// Absolute path on disk (standardised for *all* map look-ups)
		let absPathRaw = (root.fullPath as NSString).appendingPathComponent(trimmedRel)
		let absPath    = (absPathRaw as NSString).standardizingPath
		
		// ────────────────────── 1) Ensure folder chain ──────────────
		if !folderPath.isEmpty {
			// createMissingParentFolder builds *all* missing ancestors and
			// attaches them to the tree as needed.
			createMissingParentFolder(parentPath: folderPath, under: root)
		}
		
		// Retrieve the (now guaranteed) owner folder
		let ownerFolderAbs = folderPath.isEmpty
			? root.fullPath
			: ((root.fullPath as NSString).appendingPathComponent(folderPath)
								as NSString).standardizingPath
		
		guard fileHierarchyIndex.foldersByFullPath[ownerFolderAbs] != nil else {
			// Defensive – creation failed for some reason; bail out.
			return
		}
		
		// ────────────────────── 2) Ensure file VM exists ────────────
		if fileHierarchyIndex.filesByFullPath[absPath] == nil,
			FileManager.default.fileExists(atPath: absPath),
			let fsService = getFileSystemService(for: root.fullPath)
		{
			// Delegates to the same helper used by live FSEvent handling so all
			// bookkeeping (indexing, auto-scan, selection batch, etc.) is performed
			// exactly once in a single place.
			await handleNewFile(relativePath: trimmedRel,
								onRootFolder: root,
								fsService   : fsService)
		}
	}
	
	/// Resolves a file path and returns its full path and content
	/// Used by AIResponseViewModel to avoid direct FileSystemService access
	@MainActor
	func resolveFileForAIResponse(_ relativePath: String) async -> (fullPath: String, content: String)? {
		// Get the path location
		guard let location = await getFileSystemServiceForRelativePath(relativePath) else {
			return nil
		}
		
		let fullPath = (location.rootPath as NSString).appendingPathComponent(location.correctedPath)
		
		// Find the file view model to get the content
		if let file = await findFile(atPath: location.correctedPath,
									rootIdentifier: location.rootIdentifier) {
			let content = await file.latestContent ?? ""
			return (fullPath: fullPath, content: content)
		}
		
		// Fallback: if file not found in view model hierarchy, return empty content
		// This can happen for files that exist on disk but aren't loaded in the UI yet
		return (fullPath: fullPath, content: "")
	}
	
	// ─────────────────────────────────────────────────────────────────────────────
	// MARK: – FileSystemService lookup by user path
	// ─────────────────────────────────────────────────────────────────────────────
	
	/// Resolves a user-provided path to a PathLocation.
	/// Heavy path matching work runs on the per-window PathMatchWorker actor.
	/// No Task.detached, no NSLock – clean actor-based concurrency.
	@MainActor
	func getFileSystemServiceForRelativePath(
		_ userPath: String,
		exactMatchOnly: Bool = false,
		profile: PathLocateProfile? = nil,
		rootScopeOverride: LookupRootScope? = nil
	) async -> PathLocation? {
		let normalizedUserPath = normalizeUserInputPath(userPath)
		let resolvedProfile = exactMatchOnly ? PathLocateProfile.moveSourceExact : (profile ?? .uiAssisted)
		let lookupScope = effectiveLookupRootScope(for: resolvedProfile, override: rootScopeOverride)
		if allowsExplicitSystemPathResolution(for: resolvedProfile),
		   let explicitLocation = explicitSystemPathLocation(normalizedUserPath) {
			return explicitLocation
		}
		if !exactMatchOnly,
		   (resolvedProfile == .mcpRead || resolvedProfile == .mcpSearchScope),
		   let explicitLocation = explicitSystemPathLocation(normalizedUserPath) {
			return explicitLocation
		}
		if shouldPreflightDeterministicLookup(for: resolvedProfile),
			exactPathResolutionIssue(for: normalizedUserPath, kind: .either, rootScope: lookupScope) != nil {
			return nil
		}
		
		let (staticData, selectedPaths, selectionSig) = currentStaticPathMatchContext(
			scope: lookupScope
		)
		let raw = await pathMatchWorker.locate(
			userPath: normalizedUserPath,
			profile: resolvedProfile,
			staticData: staticData,
			selectedFileFullPaths: selectedPaths,
			selectionSig: selectionSig
		)
		
		guard let location = raw else {
			return nil
		}
		
		let standardizedLocationRoot = (location.rootPath as NSString).standardizingPath
		let rootIdentifier = rootFolders.first { folder in
			folder.standardizedFullPath == standardizedLocationRoot
		}?.id
		
		return PathLocation(
			rootPath: location.rootPath,
			correctedPath: location.correctedPath,
			rootIdentifier: rootIdentifier
		)
	}
	
	
	private func shouldPreflightDeterministicLookup(for profile: PathLocateProfile) -> Bool {
		switch profile {
		case .uiAssisted, .createBestEffort, .createRequireUnambiguous:
			return false
		case .mcpRead, .mcpSelection, .mcpSearchScope, .moveSourceExact:
			return true
		}
	}
	
	private func absolutePath(rootPath: String, correctedPath: String) -> String {
		PathLocation(rootPath: rootPath, correctedPath: correctedPath, rootIdentifier: nil).absolutePath
	}
	
	private func absolutePath(for location: PathLocation) -> String {
		absolutePath(rootPath: location.rootPath, correctedPath: location.correctedPath)
	}
	
	private func resolveFile(rootPath: String, correctedPath: String) -> FileViewModel? {
		findFileByFullPath(absolutePath(rootPath: rootPath, correctedPath: correctedPath))
	}
	
	private func resolveFile(at location: PathLocation) -> FileViewModel? {
		resolveFile(rootPath: location.rootPath, correctedPath: location.correctedPath)
	}
	
	private func resolveFolder(rootPath: String, correctedPath: String) -> FolderViewModel? {
		findFolderByFullPath(absolutePath(rootPath: rootPath, correctedPath: correctedPath))
	}
	
	private func resolveFolder(at location: PathLocation) -> FolderViewModel? {
		resolveFolder(rootPath: location.rootPath, correctedPath: location.correctedPath)
	}
	
	private func makeServiceResult(folder: FolderViewModel?,
									file: FileViewModel?) -> PathLocation? {
		let itemFullPath = folder?.fullPath ?? file?.fullPath ?? ""
		let standardizedPath = (itemFullPath as NSString).standardizingPath
		
		// Find the matching root by checking if the path is under any loaded root
		let matchingRoot = fileSystemServices.keys
			.filter { standardizedPath.isDescendant(of: $0) || standardizedPath == $0 }
			.max(by: { $0.count < $1.count })
		
		guard let rootKey = matchingRoot, fileSystemServices[rootKey] != nil else {
			print("Error: FileSystemService not found for \(itemFullPath)")
			return nil
		}
		
		let rootIdentifier = rootFolders.first { $0.standardizedFullPath == rootKey }?.id
		
		if let f = file {
			return PathLocation(rootPath: rootKey, correctedPath: f.relativePath, rootIdentifier: rootIdentifier)
		} else if let f = folder {
			return PathLocation(rootPath: rootKey, correctedPath: f.relativePath, rootIdentifier: rootIdentifier)
		}
		return nil
	}
	
	@MainActor
	private func findExactFileMatch(for relativePath: String) -> FileViewModel? {
		let standardizedRel = (relativePath as NSString).standardizingPath
		for absPath in absolutePathCandidates(forRelativePath: standardizedRel) {
			if let vm = fileHierarchyIndex.filesByFullPath[absPath] {
				return vm
			}
		}
		return nil
	}

	/// Provides baseline file content for a given path.
	/// This is a "back door" method that subclasses can override to provide
	/// content without needing full FileViewModel infrastructure (e.g., for benchmarks).
	/// Default implementation returns nil.
	@MainActor
	func getBaselineContent(forPath relativePath: String, rootIdentifier: UUID?) async -> String? {
		return nil
	}

	private func findFilesByName(_ fileName: String, in folder: FolderViewModel) -> [FileViewModel] {
		let normalizedFileName = (fileName as NSString).lastPathComponent
		let standardizedFileName = (normalizedFileName as NSString).standardizingPath
		let lowercaseFileName = standardizedFileName.lowercased()
		
		var matches: [FileViewModel] = []
		let directFiles: [FileViewModel] = folder.children.compactMap { child in
			if case .file(let file) = child {
				return file
			}
			return nil
		}
		var visitedFolderIDs = Set<UUID>()
		var stack: [FolderViewModel] = [folder]
		while let current = stack.popLast() {
			guard visitedFolderIDs.insert(current.id).inserted else { continue }
			for child in current.children {
				switch child {
				case .file(let file):
					let fileNameToCompare = (file.name as NSString).lastPathComponent
					let standardizedFileNameToCompare = (fileNameToCompare as NSString).standardizingPath
					if standardizedFileNameToCompare.lowercased() == lowercaseFileName {
						matches.append(file)
					}
				case .folder(let subFolder):
					stack.append(subFolder)
				}
			}
		}
		
		if matches.isEmpty {
			for file in directFiles {
				let fileNameToCompare = (file.name as NSString).lastPathComponent
				let standardizedFileNameToCompare = (fileNameToCompare as NSString).standardizingPath
				if standardizedFileNameToCompare.isSimilar(to: standardizedFileName, threshold: 0.9) {
					matches.append(file)
				}
			}
		}
		
		return matches
	}
	
/// Toggles a single file while routing the change through the batching
/// helpers, guaranteeing no duplicate IDs end up in `selectedFiles`.
func setFileToggled(_ file: FileViewModel, isToggled: Bool) {
	performSelectionBatch {
		// Skip work when the file is already in the requested state
		guard file.isChecked != isToggled else { return }
		file.setIsChecked(isToggled)          // onCheckStateChanged updates Sets
	}
}

// MARK: - Lightweight ancestor recompute (O(depth), non-recursive)
@MainActor
func recomputeAncestorStates(startingAt start: FolderViewModel) {
	var current: FolderViewModel? = start
	var seen = Set<UUID>() // defensive against cycles
	while let folder = current, seen.insert(folder.id).inserted {
		// Recompute based on *direct* children only. This is cheap and
		// correct because leaf states (files / immediate subfolders) were
		// already set during the batch.
		folder.updateCheckboxStateImmediately()
		current = folder.parent
	}
}

@MainActor
private func recomputeAncestorStates(startingAtFolders folders: [FolderViewModel]) {
	guard !folders.isEmpty else { return }
	var seen = Set<UUID>()
	for start in folders {
		var current: FolderViewModel? = start
		while let folder = current, seen.insert(folder.id).inserted {
			folder.updateCheckboxStateImmediately()
			current = folder.parent
		}
	}
}

	@MainActor
func toggleFile(_ file: FileViewModel, fromSearch: Bool = false) {
	// Compute the target state once
	let target = !file.isChecked
	
	// Centralized toggle that coalesces selection updates via performSelectionBatch
	performSelectionBatch {
		// Use the setter that does NOT bubble on each file to avoid repeated recomputes
		setFileToggled(file, isToggled: target)
	}
	
	// Recompute ancestor checkbox states once (fast local recompute at each level)
	if !fromSearch, let parent = file.parentFolder {
		recomputeAncestorStates(startingAt: parent)
	}
}
	
	func getSelectedFiles() -> [FileViewModel] {
		return rootFolders.flatMap { folder in
			getAllFiles(in: folder).filter { selectedFileIDs.contains($0.id) }
		}
	}
	
	private func getAllFiles(in folder: FolderViewModel) -> [FileViewModel] {
		return gatherAllFileViewModels(in: folder)
	}
	
	@MainActor
	public func unloadRootFolder(_ folder: FolderViewModel) async {
		let signpost = WorkspaceExitPerf.begin("unloadRootFolder")
		defer { WorkspaceExitPerf.end("unloadRootFolder", signpost) }
		let stdRoot = folder.standardizedFullPath
		removeDeferredInitialRootLoadScanRoot(stdRoot)
		unregisterExpansionTracking(for: folder)
		// Folder expansion state is now stored in the FolderViewModel itself
		// No need to unregister from ExpansionManager
		
		// Remove selections under this folder before removing hierarchy
		dropSelections(underFolderFullPath: folder.fullPath)
		normalizeSelectionState() // Ensure no orphan IDs remain after subtree removal
		
		removeRootFolderReferences(folder)
		
		// Cancel scans and unload the in-memory cache for this folder in one step.
		await codeScanActor.cancelAndUnloadScans(forRootFolder: folder.fullPath)
		
		// Drop any queued events for this root and invalidate stale watcher ingress.
		let rootKey = self.rootKey(forPath: folder.fullPath)
		_ = advanceRootReplayIngressGeneration(forRootKey: rootKey)
		await deferredReplayBuffer.unregisterActiveRootGeneration(forRootKey: rootKey)
		
		// Prune the stale loaded-root cache
		loadedRootPaths.remove(stdRoot)
	
		// Remove the root folder from the list
		self.rootFolders.removeAll { $0.id == folder.id }
		
		// Mark snapshot cache as dirty and bump that root gen
		invalidateStaticSnapshot(forRootFullPath: stdRoot)
		await clearPathResolutionCaches()
		
		// Clean up watchers and services (use stable root key)
		if let cancellable = watchers.removeValue(forKey: rootKey) {
			cancellable.cancel()
		}
		if let service = fileSystemServices.removeValue(forKey: rootKey) {
			await service.stopWatchingForChanges()
		}
		
		self.onRootFoldersChanged?()
		
		if currentSlicesByRoot.removeValue(forKey: stdRoot) != nil {
			requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
		}
		
		// Remove per-root generation entry once the root is fully gone
		removeHierarchyGenerationEntry(forRootFullPath: stdRoot)
	}
	
	@MainActor
	private func rootReferenceCleanupPlan(for folder: FolderViewModel) -> RootCleanupPlan {
		let rootKey = folder.standardizedFullPath
		let rootPrefix = folder.standardizedFullPath
		if let ownedFolderPaths = fileHierarchyIndex.folderPathsByRoot[rootKey] {
			if let ownedFilePaths = fileHierarchyIndex.filePathsByRoot[rootKey] {
				#if DEBUG
				if Self.isRootCleanupOwnershipIntegrityValidationEnabled {
					let descendantFolderPaths = Set(fileHierarchyIndex.foldersByFullPath.keys.filter {
						StandardizedPath.isDescendant($0, of: rootPrefix)
					})
					let descendantFilePaths = Set(fileHierarchyIndex.filesByFullPath.keys.filter {
						StandardizedPath.isDescendant($0, of: rootPrefix)
					})
					if descendantFolderPaths != ownedFolderPaths || descendantFilePaths != ownedFilePaths {
						return RootCleanupPlan(
							rootKey: rootKey,
							folderPaths: descendantFolderPaths,
							filePaths: descendantFilePaths,
							usedFallbackGlobalScan: true
						)
					}
				}
				#endif
				return RootCleanupPlan(
					rootKey: rootKey,
					folderPaths: ownedFolderPaths,
					filePaths: ownedFilePaths,
					usedFallbackGlobalScan: false
				)
			}

			let descendantFolderPaths = Set(fileHierarchyIndex.foldersByFullPath.keys.filter {
				StandardizedPath.isDescendant($0, of: rootPrefix)
			})
			let descendantFilePaths = Set(fileHierarchyIndex.filesByFullPath.keys.filter {
				StandardizedPath.isDescendant($0, of: rootPrefix)
			})
			if descendantFilePaths.isEmpty {
				guard descendantFolderPaths == ownedFolderPaths else {
					return RootCleanupPlan(
						rootKey: rootKey,
						folderPaths: descendantFolderPaths,
						filePaths: descendantFilePaths,
						usedFallbackGlobalScan: true
					)
				}
				fileHierarchyIndex.filePathsByRoot[rootKey] = []
				return RootCleanupPlan(
					rootKey: rootKey,
					folderPaths: ownedFolderPaths,
					filePaths: [],
					usedFallbackGlobalScan: false
				)
			}
		}

		return RootCleanupPlan(
			rootKey: rootKey,
			folderPaths: Set(fileHierarchyIndex.foldersByFullPath.keys.filter {
				StandardizedPath.isDescendant($0, of: rootPrefix)
			}),
			filePaths: Set(fileHierarchyIndex.filesByFullPath.keys.filter {
				StandardizedPath.isDescendant($0, of: rootPrefix)
			}),
			usedFallbackGlobalScan: true
		)
	}

	/// Removes all index references for a given root folder's entire subtree.
	@MainActor
	private func removeRootFolderReferences(_ folder: FolderViewModel) {
		let cleanup = rootReferenceCleanupPlan(for: folder)
		for filePath in cleanup.filePaths {
			codemapCapableAPIsByFullPath.removeValue(forKey: filePath)
		}
		fileHierarchyIndex.removeOwnedEntries(
			forRootKey: cleanup.rootKey,
			folderPaths: cleanup.folderPaths,
			filePaths: cleanup.filePaths
		)
	}
	
	private func removeFileHierarchyIndexEntries(for folder: FolderViewModel) {
		var visitedFolderIDs = Set<UUID>()
		removeFileHierarchyIndexEntries(for: folder, visitedFolderIDs: &visitedFolderIDs)
	}
	
	private func removeFileHierarchyIndexEntries(
		for folder: FolderViewModel,
		visitedFolderIDs: inout Set<UUID>
	) {
		guard visitedFolderIDs.insert(folder.id).inserted else { return }
		
		// Remove this folder from index
		fileHierarchyIndex.removeFolder(forKey: folder.standardizedFullPath)
		
		// Recurse through all children
		for child in folder.children {
			switch child {
			case .folder(let subFolder):
				removeFileHierarchyIndexEntries(for: subFolder, visitedFolderIDs: &visitedFolderIDs)
			case .file(let fileViewModel):
				fileHierarchyIndex.removeFile(forKey: fileViewModel.standardizedFullPath)
				codemapCapableAPIsByFullPath.removeValue(forKey: fileViewModel.standardizedFullPath)
			}
		}
	}
	
	/// Snapshot of all file view models from the index (no tree traversal).
	func allFilesSnapshot(sorted: Bool = true) -> [FileViewModel] {
		let values = Array(fileHierarchyIndex.filesByFullPath.values)
		guard sorted else { return values }
		return values.sorted { $0.standardizedFullPath < $1.standardizedFullPath }
	}
	
	// Recursively collect all FileViewModels from all root folders.
	func getAllFileViewModels() -> [FileViewModel] {
		var allFiles: [FileViewModel] = []
		for root in rootFolders {
			allFiles.append(contentsOf: gatherAllFileViewModels(in: root))
		}
		return allFiles
	}

	func getAllFileViewModels(in scope: LookupRootScope) -> [FileViewModel] {
		switch scope {
		case .allLoaded:
			return getAllFileViewModels()
		case .visibleWorkspace, .visibleWorkspacePlusGitData:
			let allowedRoots = allowedRootPaths(in: scope)
			return allFilesSnapshot(sorted: false).filter {
				allowedRoots.contains($0.standardizedRootFolderPath)
			}
		}
	}
	
	// Collect all files that have codemaps available
	@MainActor
	func collectAllFilesWithCodemaps() -> [FileViewModel] {
		let indexedFiles = allFilesSnapshot(sorted: true)
		if !indexedFiles.isEmpty || rootFolders.isEmpty {
			return indexedFiles.filter { $0.fileAPI != nil }
		}
		return getAllFileViewModels().filter { $0.fileAPI != nil }
	}
	
	// 4) Helper to gather FileViewModels recursively
	private func gatherAllFileViewModels(in folder: FolderViewModel) -> [FileViewModel] {
		var visitedFolderIDs = Set<UUID>()
		return gatherAllFileViewModels(in: folder, visitedFolderIDs: &visitedFolderIDs)
	}
	
	private func gatherAllFileViewModels(
		in folder: FolderViewModel,
		visitedFolderIDs: inout Set<UUID>
	) -> [FileViewModel] {
		guard visitedFolderIDs.insert(folder.id).inserted else { return [] }
		var collected: [FileViewModel] = []
		// Walk the folder's children
		for child in folder.children {
			switch child {
			case .folder(let subFolder):
				collected.append(contentsOf: gatherAllFileViewModels(in: subFolder, visitedFolderIDs: &visitedFolderIDs))
			case .file(let fileVM):
				collected.append(fileVM)
			}
		}
		return collected
	}
	
	@MainActor
	public func getFilesRecursively(under folder: FolderViewModel) -> [FileViewModel] {
		return gatherAllFileViewModels(in: folder)
	}
	
	@MainActor
	func requestUnloadRootFolder(path: String) {
		onRootFolderUnloadRequested.send(path)
	}
	
	@MainActor
	func requestMoveRootFolderUp(path: String) {
		let standardizedPath = (path as NSString).standardizingPath
		guard let folder = rootFolders.first(where: { $0.standardizedFullPath == standardizedPath }) else { return }
		moveRootFolderUp(folder)
	}
	
	@MainActor
	func requestMoveRootFolderDown(path: String) {
		let standardizedPath = (path as NSString).standardizingPath
		guard let folder = rootFolders.first(where: { $0.standardizedFullPath == standardizedPath }) else { return }
		moveRootFolderDown(folder)
	}
	
	// Public API to handle window focus changes
	@MainActor
	func setWindowFocused(_ focused: Bool) {
		isWindowFocused = focused
		let routingVersion = advanceDeferredReplayRoutingVersion()
		let isReplayActive = isReplayingDeltas
		let deferredReplayBuffer = self.deferredReplayBuffer
		Task { [weak self, deferredReplayBuffer, focused, isReplayActive, routingVersion] in
			await deferredReplayBuffer.updateRoutingState(
				isWindowFocused: focused,
				isReplayActive: isReplayActive,
				routingVersion: routingVersion
			)
			guard focused, let self else { return }
			await self.flushPendingDeltas()
		}
	}
	
	// Helper to replay queued deltas once the app regains focus
	// MARK: – Window-focus replay
	@MainActor
	func flushPendingDeltas() async {
		guard !isReplayingDeltas else { return }
		await flushPendingDeltas(aggressive: false)
	}
	
	@MainActor
	func flushPendingDeltas(aggressive: Bool) async {
		while true {
			// If another replay is running:
			while true {
				if let existingTask = deltaReplayTask {
					if aggressive {
						// Wait for the existing replay to finish (no spin-wait)
						await existingTask.value
						continue  // Re-check in case another started
					} else {
						// Non-aggressive path: do nothing if a replay is in progress
						return
					}
				}
				break
			}

			guard isWindowFocused || aggressive else { return }
			guard await deferredReplayBuffer.hasPendingWork() || aggressive else { return }

			// Start a new replay
			let runID = UUID()
			deltaReplayRunID = runID
			isReplayingDeltas = true
			_ = advanceDeferredReplayRoutingVersion()
			await syncDeferredReplayRoutingState()
			
			let task = Task { @MainActor [weak self] in
				guard let self else { return }
				await self.runDeltaReplay(aggressive: aggressive)
				// Only clear if this is still our run
				if self.deltaReplayRunID == runID {
					self.deltaReplayTask = nil
					self.deltaReplayRunID = nil
					self.isReplayingDeltas = false
					_ = self.advanceDeferredReplayRoutingVersion()
					await self.syncDeferredReplayRoutingState()
				}
			}
			deltaReplayTask = task
			await task.value

			guard isWindowFocused, await deferredReplayBuffer.hasPendingWork() else { return }
		}
	}
	
	/// Internal implementation of delta replay logic.
	@MainActor
	private func runDeltaReplay(aggressive: Bool) async {
		let signpost = RepoFileReplayPerf.begin("runDeltaReplay")
		defer { RepoFileReplayPerf.end("runDeltaReplay", signpost) }
		let pendingSnapshotAtStart = await deferredReplayBuffer.pendingWorkSnapshot()
		let pendingRootCountAtStart = pendingSnapshotAtStart.pendingRootCount
		let pendingDeltaCountAtStart = pendingSnapshotAtStart.pendingDeltaCount
		let baseChunkSize = aggressive ? 10_000 : 100
		let baseInterChunkDelay: UInt64 = aggressive ? 0 : 32_000_000 // 32 ms
		let chunkSize: Int
		let interChunkDelay: UInt64
		#if DEBUG
		let totalStartMS = debugPerfTimestampMS()
		var preReplayServiceFlushes: [DeltaReplayPerfSample.ServiceFlushSample] = []
		var postReplayServiceFlushes: [DeltaReplayPerfSample.ServiceFlushSample] = []
		var replayedRoots: [RootReplayPerfSample] = []
		var rootPasses: [RootReplayPassPerfSample] = []
		var totalRootPassCount = 0
		var totalChunkCount = 0
		var totalRootPassFinalizeDurationMS = 0.0
		var totalCoalescedDeltaCount = 0
		var totalDiscardedDeltaCount = 0
		var totalCoalesceDurationMS = 0.0
		var totalPreparationDurationMS = 0.0
		var totalApplyAwaitDurationMS = 0.0
		var totalYieldDurationMS = 0.0
		var totalInterChunkSleepDurationMS = 0.0
		var totalDeltaLoopDurationMS = 0.0
		var totalFlushPendingInsertsDurationMS = 0.0
		var totalUpdateFolderStatesDurationMS = 0.0
		var totalIncrementalIndexCleanupDurationMS = 0.0
		var totalIncrementalDescendantScanInvocationCount = 0
		var totalIncrementalDescendantScannedFolderCandidateCount = 0
		var totalIncrementalDescendantScannedFileCandidateCount = 0
		var totalOnRootFoldersChangedDurationMS = 0.0
		var totalOnRootFoldersChangedInvocationCount = 0
		var totalSnapshotInvalidationCount = 0
		var totalDeltaAppliedPublisherInvocationCount = 0
		var totalReplayCodeScanBatchInvocationCount = 0
		var totalReplaySliceRebaseBatchInvocationCount = 0
		var totalRebuildDurationMS = 0.0
		var totalCodeScanBatchFileCount = 0
		var totalSliceRebaseCandidateCount = 0
		var totalInvalidateSnapshotDurationMS = 0.0
		chunkSize = max(deltaReplayChunkSizeOverride ?? baseChunkSize, 1)
		interChunkDelay = deltaReplayInterChunkDelayNanosecondsOverride ?? baseInterChunkDelay
		#else
		chunkSize = baseChunkSize
		interChunkDelay = baseInterChunkDelay
		#endif
		var replayPassCount = 0

		#if DEBUG
		func recordCurrentReplaySample(
			passIndex: Int,
			chunkIndex: Int,
			chunkCount: Int,
			applyAwaitDurationMS: Double,
			yieldDurationMS: Double,
			interChunkSleepDurationMS: Double
		) {
			guard var sample = currentRootReplayPerfSample else { return }
			sample.passIndex = passIndex
			sample.chunkIndexInPass = chunkIndex
			sample.chunkCountInPass = chunkCount
			sample.applyAwaitDurationMS = applyAwaitDurationMS
			sample.yieldDurationMSAfterChunk = yieldDurationMS
			sample.interChunkSleepDurationMSAfterChunk = interChunkSleepDurationMS
			replayedRoots.append(sample)
			totalDeltaLoopDurationMS += sample.deltaLoopDurationMS
			totalFlushPendingInsertsDurationMS += sample.flushPendingInsertsDurationMS
			totalUpdateFolderStatesDurationMS += sample.updateFolderStatesDurationMS
			totalIncrementalIndexCleanupDurationMS += sample.incrementalIndexCleanupDurationMS
			totalIncrementalDescendantScanInvocationCount += sample.incrementalDescendantScanInvocationCount
			totalIncrementalDescendantScannedFolderCandidateCount += sample.incrementalDescendantScannedFolderCandidateCount
			totalIncrementalDescendantScannedFileCandidateCount += sample.incrementalDescendantScannedFileCandidateCount
			totalRebuildDurationMS += sample.rebuildDurationMS ?? 0
			currentRootReplayPerfSample = nil
		}

		func recordReplayRootPassSample(_ sample: RootReplayPassPerfSample) {
			rootPasses.append(sample)
			totalRootPassFinalizeDurationMS += sample.finalizeDurationMS
			totalOnRootFoldersChangedDurationMS += sample.onRootFoldersChangedDurationMS
			totalOnRootFoldersChangedInvocationCount += sample.onRootFoldersChangedInvocationCount
			totalSnapshotInvalidationCount += sample.snapshotInvalidationCount
			totalDeltaAppliedPublisherInvocationCount += sample.deltaAppliedPublisherInvocationCount
			totalReplayCodeScanBatchInvocationCount += sample.codeScanBatchInvocationCount
			totalReplaySliceRebaseBatchInvocationCount += sample.sliceRebaseBatchInvocationCount
			totalCodeScanBatchFileCount += sample.codeScanBatchFileCount
			totalSliceRebaseCandidateCount += sample.sliceRebaseCandidateCount
			totalInvalidateSnapshotDurationMS += sample.invalidateSnapshotDurationMS
		}
		#endif

		@MainActor
		func replayPreparedBatch(
			_ preparedBatch: PreparedFileSystemReplayBatch,
			passIndex: Int,
			allowInterChunkDelay: Bool
		) async {
			#if DEBUG
			totalCoalescedDeltaCount += preparedBatch.coalescedDeltaCount
			totalDiscardedDeltaCount += preparedBatch.discardedDeltaCount
			totalCoalesceDurationMS += preparedBatch.coalesceDurationMS
			totalPreparationDurationMS += preparedBatch.preparationDurationMS
			#endif
			let chunkCountInPass = preparedBatch.chunks.count
			#if DEBUG
			totalChunkCount += chunkCountInPass
			#endif
			var accumulator = ReplayRootPassAccumulator(rootKey: preparedBatch.rootKey)
			for (chunkIndex, chunk) in preparedBatch.chunks.enumerated() {
				#if DEBUG
				let applyAwaitStartMS = debugPerfTimestampMS()
				#endif
				await applyPreparedFileSystemDeltas(
					chunk: chunk,
					from: preparedBatch,
					forRootKey: preparedBatch.rootKey,
					accumulator: &accumulator
				)
				#if DEBUG
				let applyAwaitDurationMS = debugPerfElapsedMS(since: applyAwaitStartMS)
				totalApplyAwaitDurationMS += applyAwaitDurationMS
				var yieldDurationMS = 0.0
				var interChunkSleepDurationMS = 0.0
				#endif
				let hasMoreChunksInPass = chunkIndex < chunkCountInPass - 1
				#if DEBUG
				let yieldStartMS = debugPerfTimestampMS()
				#endif
				await Task.yield()
				#if DEBUG
				yieldDurationMS = debugPerfElapsedMS(since: yieldStartMS)
				totalYieldDurationMS += yieldDurationMS
				#endif
				if allowInterChunkDelay, hasMoreChunksInPass, interChunkDelay > 0 {
					#if DEBUG
					let sleepStartMS = debugPerfTimestampMS()
					#endif
					try? await Task.sleep(nanoseconds: interChunkDelay)
					#if DEBUG
					interChunkSleepDurationMS = debugPerfElapsedMS(since: sleepStartMS)
					totalInterChunkSleepDurationMS += interChunkSleepDurationMS
					#endif
				}
				#if DEBUG
				recordCurrentReplaySample(
					passIndex: passIndex,
					chunkIndex: chunkIndex,
					chunkCount: chunkCountInPass,
					applyAwaitDurationMS: applyAwaitDurationMS,
					yieldDurationMS: yieldDurationMS,
					interChunkSleepDurationMS: interChunkSleepDurationMS
				)
				#endif
			}
			if let passSample = finalizeReplayRootPass(
				accumulator,
				passIndex: passIndex,
				chunkCount: chunkCountInPass
			) {
				#if DEBUG
				recordReplayRootPassSample(passSample)
				#endif
			}
		}

		if aggressive {
			await awaitWatcherIngressTasksForReplayBarrier()
			for (rootKey, svc) in fileSystemServices {
				#if DEBUG
				preReplayServiceFlushes.append(
					.init(rootKey: rootKey, pendingRawEventCountBeforeFlush: await svc.pendingRawEventCountForDiagnostics())
				)
				#endif
				await svc.flushPendingEventsNow()
			}
			await awaitWatcherIngressTasksForReplayBarrier()
		}

		while true {
			replayPassCount += 1
			let preparedBatches = await deferredReplayBuffer.drainPreparedBatches(
				preferredRootOrder: rootFolders.map(\.standardizedFullPath),
				chunkSize: chunkSize
			)
			if preparedBatches.isEmpty {
				await Task.yield()
				if await deferredReplayBuffer.hasPendingWork() {
					continue
				}
				break
			}
			for preparedBatch in preparedBatches {
				#if DEBUG
				totalRootPassCount += 1
				#endif
				await replayPreparedBatch(
					preparedBatch,
					passIndex: replayPassCount,
					allowInterChunkDelay: true
				)
			}
		}

		if aggressive {
			for (rootKey, svc) in fileSystemServices {
				#if DEBUG
				postReplayServiceFlushes.append(
					.init(rootKey: rootKey, pendingRawEventCountBeforeFlush: await svc.pendingRawEventCountForDiagnostics())
				)
				#endif
				await svc.flushPendingEventsNow()
			}
			await awaitWatcherIngressTasksForReplayBarrier()

			while true {
				replayPassCount += 1
				let preparedBatches = await deferredReplayBuffer.drainPreparedBatches(
					preferredRootOrder: rootFolders.map(\.standardizedFullPath),
					chunkSize: chunkSize
				)
				if preparedBatches.isEmpty {
					await Task.yield()
					if await deferredReplayBuffer.hasPendingWork() {
						continue
					}
					break
				}
				for preparedBatch in preparedBatches {
					#if DEBUG
					totalRootPassCount += 1
					#endif
					await replayPreparedBatch(
						preparedBatch,
						passIndex: replayPassCount,
						allowInterChunkDelay: false
					)
				}
			}
		}

		#if DEBUG
		lastDeltaReplayPerfSample = DeltaReplayPerfSample(
			aggressive: aggressive,
			pendingRootCountAtStart: pendingRootCountAtStart,
			pendingDeltaCountAtStart: pendingDeltaCountAtStart,
			whileLoopPassCount: replayPassCount,
			totalRootPassCount: totalRootPassCount,
			totalChunkCount: totalChunkCount,
			totalRootPassFinalizeDurationMS: totalRootPassFinalizeDurationMS,
			totalCoalescedDeltaCount: totalCoalescedDeltaCount,
			totalDiscardedDeltaCount: totalDiscardedDeltaCount,
			totalCoalesceDurationMS: totalCoalesceDurationMS,
			totalPreparationDurationMS: totalPreparationDurationMS,
			totalApplyAwaitDurationMS: totalApplyAwaitDurationMS,
			totalYieldDurationMS: totalYieldDurationMS,
			totalInterChunkSleepDurationMS: totalInterChunkSleepDurationMS,
			totalDeltaLoopDurationMS: totalDeltaLoopDurationMS,
			totalFlushPendingInsertsDurationMS: totalFlushPendingInsertsDurationMS,
			totalUpdateFolderStatesDurationMS: totalUpdateFolderStatesDurationMS,
			totalIncrementalIndexCleanupDurationMS: totalIncrementalIndexCleanupDurationMS,
			totalIncrementalDescendantScanInvocationCount: totalIncrementalDescendantScanInvocationCount,
			totalIncrementalDescendantScannedFolderCandidateCount: totalIncrementalDescendantScannedFolderCandidateCount,
			totalIncrementalDescendantScannedFileCandidateCount: totalIncrementalDescendantScannedFileCandidateCount,
			totalOnRootFoldersChangedDurationMS: totalOnRootFoldersChangedDurationMS,
			totalOnRootFoldersChangedInvocationCount: totalOnRootFoldersChangedInvocationCount,
			totalSnapshotInvalidationCount: totalSnapshotInvalidationCount,
			totalDeltaAppliedPublisherInvocationCount: totalDeltaAppliedPublisherInvocationCount,
			totalReplayCodeScanBatchInvocationCount: totalReplayCodeScanBatchInvocationCount,
			totalReplaySliceRebaseBatchInvocationCount: totalReplaySliceRebaseBatchInvocationCount,
			totalRebuildDurationMS: totalRebuildDurationMS,
			totalCodeScanBatchFileCount: totalCodeScanBatchFileCount,
			totalSliceRebaseCandidateCount: totalSliceRebaseCandidateCount,
			totalInvalidateSnapshotDurationMS: totalInvalidateSnapshotDurationMS,
			preReplayServiceFlushes: preReplayServiceFlushes,
			postReplayServiceFlushes: postReplayServiceFlushes,
			replayedRoots: replayedRoots,
			rootPasses: rootPasses,
			totalDurationMS: debugPerfElapsedMS(since: totalStartMS)
		)
		#endif
	}
	
	@MainActor
	internal func unloadRootFolderPath(_ path: String) async {
		let stdURL = canonicalURL(for: path, assumingDirectory: true)
		await unloadRootFolder(for: stdURL)
	}
	
	func unloadAllRootFolders(cancelScans: Bool = true) async {
		let signpost = WorkspaceExitPerf.begin("unloadAllRootFolders")
		defer { WorkspaceExitPerf.end("unloadAllRootFolders", signpost) }
		await unloadAllRootFoldersFast(cancelScans: cancelScans)
	}
	
	@MainActor
	private func unloadAllRootFoldersFast(cancelScans: Bool) async {
		clearDeferredInitialRootLoadScanState(keepingActiveDeferral: isInitialRootLoadScanDeferralActive)
		// No longer need to clear ExpansionManager
		// Expansion state is stored directly in each FolderViewModel
		
		let roots = rootFolders
		let hadRoots = !roots.isEmpty
		let rootPaths = roots.map(\.fullPath)
		
		for rootPath in rootPaths {
			_ = advanceRootReplayIngressGeneration(forRootKey: rootKey(forPath: rootPath))
		}

		// Stop any replay/coalescing work before tearing down roots.
		deltaReplayTask?.cancel()
		deltaReplayTask = nil
		deltaReplayRunID = nil
		isReplayingDeltas = false
		_ = advanceDeferredReplayRoutingVersion()
		await syncDeferredReplayRoutingState()
		await deferredReplayBuffer.clearAll()
		pendingChildInserts.removeAll()
		pendingInsertParents.removeAll()
		isInsertFlushScheduled = false
		
		for folder in roots {
			unregisterExpansionTracking(for: folder)
		}
		
		if !watchers.isEmpty {
			for cancellable in watchers.values {
				cancellable.cancel()
			}
			watchers.removeAll()
		}
		
		if !fileSystemServices.isEmpty {
			let services = Array(fileSystemServices.values)
			fileSystemServices.removeAll()
			await withTaskGroup(of: Void.self) { group in
				for service in services {
					group.addTask {
						await service.stopWatchingForChanges()
					}
				}
				await group.waitForAll()
			}
		}
		
		if cancelScans {
			await cancelAllScans()
		}
		if !rootPaths.isEmpty {
			await codeScanActor.cancelAndUnloadScans(forRootFolders: rootPaths)
		}
		
		rootFolders.removeAll()
		if hadRoots {
			allFoldersUnloadedPublisher.send(())
		}
		
		currentSlicesByRoot.removeAll()
		resetSelection() // Atomic selection reset
		
		folderBeingAdded = nil
		error = nil
		
		fileHierarchyIndex.clearAll()
		fileHierarchyIndex = FileHierarchyIndex()
		codemapCapableAPIsByFullPath.removeAll()
		autoCodemapSyncTask?.cancel()
		autoCodemapSyncTask = nil
		resetAutoCodemapFiles([])
		
		// Clear stale cache of loaded roots across workspaces
		loadedRootPaths.removeAll()
		
		// Clear any leftover generations and bump signature once.
		rootHierarchyGenerations.removeAll()
		hierarchyGenerationSignature &+= 1
		
		// Ensure search caches are also invalidated
		invalidateStaticSnapshot(forRootFullPath: nil)
		await clearPathResolutionCaches()
		
		onRootFoldersChanged?()
	}
	
	@MainActor
func toggleFolder(_ folder: FolderViewModel, fromSearch: Bool = false) {
	guard !isLoading, folder.isValid else { return }

	// Flip the entire subtree in a single main-actor pass; no yielding.
	performSelectionBatch {
		let newState: CheckboxState = (folder.checkboxState == .unchecked) ? .checked : .unchecked
		setFolderStateOnSubtree(folder, newState: newState)
	}

	// One cheap recompute from this folder up to the root (O(depth)).
	recomputeAncestorStates(startingAt: folder)

	// Notify any listeners that the folder row can refresh UI affordances.
	folderRefreshPublisher.send(folder)
}

	/*
	@MainActor
	private func setFolderStateOnSubtree(_ folder: FolderViewModel, newState: CheckboxState) {
		var stack = [folder]
		while let current = stack.popLast() {
			for child in current.children {
				switch child {
				case .file(let fileVM):
					fileVM.setIsChecked(newState == .checked)
				case .folder(let subFolder):
					stack.append(subFolder)
				}
			}
			current.updateCheckboxStateImmediately(newState: newState)
		}
	}
	*/
	@MainActor
private func setFolderStateOnSubtree(_ folder: FolderViewModel,
										newState: CheckboxState) {
	var stack = [folder]
	while let current = stack.popLast() {
		for child in current.children {
			switch child {
			case .file(let fileVM):
				let target = (newState == .checked)
				// Avoid emitting onCheckStateChanged when the state is already correct
				if fileVM.isChecked != target {
					fileVM.setIsChecked(target)
				}
			case .folder(let subFolder):
				stack.append(subFolder)
			}
		}
		current.updateCheckboxStateImmediately(newState: newState)
	}
}
	
	@MainActor
	private func setFolderStateToUncheckedOnlyWhereChecked(_ folder: FolderViewModel) {
		// Batch uncheck all checked files in the subtree
		performSelectionBatch {
			var stack: [FolderViewModel] = [folder]
			while let current = stack.popLast() {
				for child in current.children {
					switch child {
					case .folder(let subFolder):
						stack.append(subFolder)
					case .file(let childFile):
						if childFile.isChecked {
							childFile.setIsChecked(false)
						}
					}
				}
			}
		}

		// Fast O(depth) recompute up the chain instead of full recursive walk
		recomputeAncestorStates(startingAt: folder)
	}
	
	@MainActor
	private func updateFolderStates() {
		for rootFolder in rootFolders {
			_ = updateFolderStateRecursive(rootFolder)
		}
	}
	
	@MainActor
	private func updateFolderStateRecursive(_ folder: FolderViewModel) -> CheckboxState {
		var visitedFolderIDs = Set<UUID>()
		return updateFolderStateRecursive(folder, visitedFolderIDs: &visitedFolderIDs)
	}
	
	@MainActor
	private func updateFolderStateRecursive(
		_ folder: FolderViewModel,
		visitedFolderIDs: inout Set<UUID>
	) -> CheckboxState {
		guard visitedFolderIDs.insert(folder.id).inserted else { return folder.checkboxState }
		var checkedCount = 0
		var uncheckedCount = 0
		var mixedCount = 0
		let totalCount = folder.children.count
		
		for child in folder.children {
			switch child {
			case .file(let fileVM):
				if fileVM.isChecked {
					checkedCount += 1
				} else {
					uncheckedCount += 1
				}
			case .folder(let folderVM):
				let childState = updateFolderStateRecursive(folderVM, visitedFolderIDs: &visitedFolderIDs)
				switch childState {
				case .checked:
					checkedCount += 1
				case .unchecked:
					uncheckedCount += 1
				case .mixed:
					mixedCount += 1
				}
			}
		}
		
		let newState: CheckboxState
		if mixedCount > 0 || (checkedCount > 0 && uncheckedCount > 0) {
			newState = .mixed
		} else if checkedCount == totalCount && totalCount > 0 {
			newState = .checked
		} else if uncheckedCount == totalCount && totalCount > 0 {
			newState = .unchecked
		} else {
			newState = .unchecked
		}
		
		folder.updateCheckboxStateImmediately(newState: newState)
		return newState
	}
	
	@MainActor
	func clearSelection(persistWorkspace: Bool = false) async {
		_ = try? await setSelectionSlices(entries: [], mode: .set, persistWorkspace: false)
		clearCheckedFilesOnly()
		finalizeSelectionClear(persistWorkspace: persistWorkspace)
	}

	@MainActor
	private func clearCheckedFilesOnly() {
		let filesToUncheck = selectedFiles

		// Batch all deselections into a single mutation & cache update
		performSelectionBatch {
			for file in filesToUncheck {
				file.setIsChecked(false)
			}
		}

		// Recompute only affected ancestor chains (unique parents)
		var seen = Set<UUID>()
		var parents: [FolderViewModel] = []
		for file in filesToUncheck {
			if let p = file.parentFolder, seen.insert(p.id).inserted {
				parents.append(p)
			}
		}
		for parent in parents {
			recomputeAncestorStates(startingAt: parent)
		}
	}

	@MainActor
	private func finalizeSelectionClear(persistWorkspace: Bool) {
		selectionClearedPublisher.send()
		autoCodemapSyncTask?.cancel()
		resetAutoCodemapFiles([])
		codemapAutoEnabled = true

		guard persistWorkspace else { return }
		requestWorkspaceSaveDebounced()
	}

	@MainActor
	private func requestWorkspaceSaveDebounced(delayNanoseconds: UInt64 = 150_000_000) {
		workspaceManager?.markWorkspaceDirty()
		workspaceSaveDebounceTask?.cancel()
		workspaceSaveDebounceTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: delayNanoseconds)
			guard let self else { return }
			guard !Task.isCancelled else { return }
			self.workspaceManager?.pollAndSaveState()
			self.workspaceSaveDebounceTask = nil
		}
	}
	
	func findFullPath(for relativePath: String) -> String? {
		for rootFolder in rootFolders {
			if let fullPath = searchForFile(withRelativePath: relativePath, in: rootFolder, currentPath: rootFolder.fullPath) {
				return fullPath
			}
		}
		return nil
	}
	
	private func searchForFile(
		withRelativePath relativePath: String,
		in folder: FolderViewModel,
		currentPath: String
	) -> String? {
		var visitedFolderIDs = Set<UUID>()
		return searchForFile(
			withRelativePath: relativePath,
			in: folder,
			currentPath: currentPath,
			visitedFolderIDs: &visitedFolderIDs
		)
	}
	
	private func searchForFile(
		withRelativePath relativePath: String,
		in folder: FolderViewModel,
		currentPath: String,
		visitedFolderIDs: inout Set<UUID>
	) -> String? {
		guard visitedFolderIDs.insert(folder.id).inserted else { return nil }
		for child in folder.children {
			switch child {
			case .file(let file):
				if file.relativePath == relativePath {
					return file.fullPath
				}
			case .folder(let subFolder):
				let newPath = (currentPath as NSString).appendingPathComponent(subFolder.name)
				if let path = searchForFile(
					withRelativePath: relativePath,
					in: subFolder,
					currentPath: newPath,
					visitedFolderIDs: &visitedFolderIDs
				) {
					return path
				}
			}
		}
		return nil
	}
	
	@MainActor
	private func clearFolderSelectionRecursive(_ folder: FolderViewModel) {
		var visitedFolderIDs = Set<UUID>()
		var stack: [FolderViewModel] = [folder]
		while let current = stack.popLast() {
			guard visitedFolderIDs.insert(current.id).inserted else { continue }
			for child in current.children {
				switch child {
				case .folder(let childFolder):
					stack.append(childFolder)
				case .file(let childFile):
					childFile.setIsChecked(false)
				}
			}
		}
	}
	
	private func updateSelectedFiles() async {
		let selected = await withTaskGroup(of: [FileViewModel].self) { group in
			for folder in self.rootFolders {
				group.addTask {
					await self.getAllSelectedFiles(in: folder)
				}
			}
			
			var allSelected: [FileViewModel] = []
			for await folderSelected in group {
				allSelected.append(contentsOf: folderSelected)
			}
			return allSelected
		}
		
		// Keep both collections consistent
		let newIDs = Set(selected.map(\.id))
		commitSelectionState(selected, newIDs)
	}
	
	func isFileSelected(_ requestedPath: String) -> Bool {
		let trimmedRequest = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
		
		// Gather the fullPaths of all currently selected files
		let selectedFullPaths = selectedFiles.map { $0.fullPath }
		
		// Use your String extension’s findClosestPath method to see if any match
		if let _ = String.findClosestPath(trimmedRequest, among: selectedFullPaths) {
			return true
		}
		return false
	}
	
	@MainActor
	private func getAllSelectedFiles(in folder: FolderViewModel) async -> [FileViewModel] {
		var files: [FileViewModel] = []
		var visitedFolderIDs = Set<UUID>()
		var stack: [FolderViewModel] = [folder]
		while let current = stack.popLast() {
			guard visitedFolderIDs.insert(current.id).inserted else { continue }
			for child in current.children {
				switch child {
				case .file(let file) where file.isChecked:
					files.append(file)
				case .folder(let subFolder):
					stack.append(subFolder)
				default:
					break
				}
			}
		}
		return files
	}
	
	@MainActor
	private func cleanupStaleServices() {
		// Since nested roots are blocked, use simple equality check instead of prefix containment
		let currentPaths = Set(rootFolders.map { $0.standardizedFullPath })
		fileSystemServices = fileSystemServices.filter { rootKey, _ in
			currentPaths.contains(rootKey)
		}
	}
	
	@MainActor
	func updateParentFolders(for item: any FileSystemItemViewModel) async {
		if let fileVM = item as? FileViewModel {
			var curFolder = fileVM.parentFolder
			while let folder = curFolder {
				folder.updateCheckboxStateImmediately()
				curFolder = folder.parent
			}
		} else if let folderVM = item as? FolderViewModel {
			var curFolder = folderVM.parent
			while let parentFolder = curFolder {
				parentFolder.updateCheckboxStateImmediately()
				curFolder = parentFolder.parent
			}
		}
	}
	
	func findParentFolder(for item: any FileSystemItemViewModel) async -> FolderViewModel? {
		for rootFolder in rootFolders {
			if let parent = await findParentFolderRecursive(rootFolder, item) {
				return parent
			}
		}
		return nil
	}
	
	private func findParentFolderRecursive(_ folder: FolderViewModel, _ item: any FileSystemItemViewModel) async -> FolderViewModel? {
		var visitedFolderIDs = Set<UUID>()
		var stack: [FolderViewModel] = [folder]
		while let current = stack.popLast() {
			guard visitedFolderIDs.insert(current.id).inserted else { continue }
			for child in current.children {
				switch child {
				case .folder(let childFolder):
					if childFolder.id == item.id {
						return current
					}
					stack.append(childFolder)
				case .file(let childFile):
					if childFile.id == item.id {
						return current
					}
				}
			}
		}
		return nil
	}
	
	func createFile(atRelativePath userPath: String, content: String, selectAfterCreate: Bool = true) async throws {
		// Build static data + selection on main, run PathMatcher on worker
		let (staticData, selectedPaths, selectionSig) = currentStaticPathMatchContext()
		
		// Normalize user input for creation matching (do not strip alias prefixes)
		let normalizedForCreate: String = normalizeUserInputPath(userPath)
		
		// Run findCreationPath on the worker (no Task.detached, no NSLock)
		guard let creationResult = await pathMatchWorker.findCreationPath(
			userPath: normalizedForCreate,
			staticData: staticData,
			selectedFileFullPaths: selectedPaths,
			selectionSig: selectionSig
		) else {
			// Provide workspace-aware context
			let msg: String
			if visibleRootFolders.isEmpty {
				msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
			} else {
				let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
				msg = "Could not resolve a destination within the current workspace for '\(userPath)'. Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path, or ensure the path is inside one of these folders."
			}
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		}
		
		// Find the actual root folder from our list
		let standardizedCreationRootPath = (creationResult.rootFolder.fullPath as NSString).standardizingPath
		guard let rootFolder = rootFolders.first(where: { $0.standardizedFullPath == standardizedCreationRootPath }) else {
			let msg = "Internal error: computed creation root is not currently loaded."
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		}
		
		let correctedPath = creationResult.componentsToCreate.joined(separator: "/")
		
		guard let fsService = getFileSystemService(for: rootFolder.fullPath) else {
			let msg = "Unable to locate a file system service for '\(correctedPath)'."
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		}
		
		// Insert canonical key BEFORE the FS operation to avoid race with incoming FSEvents.
		let creationKey = makeCreationKey(rootFullPath: rootFolder.fullPath, relPath: correctedPath)
		if selectAfterCreate {
			newlyCreatedFilePaths.insert(creationKey)
		}
		do {
			try await fsService.createFile(atRelativePath: correctedPath, content: content)
			try await materializeCreatedWorkspaceFile(
				relativePath: correctedPath,
				onRootFolder: rootFolder,
				fsService: fsService,
				requestCodeScanImmediately: true,
				creationKey: creationKey,
				selectAfterCreate: selectAfterCreate
			)
		} catch {
			// Roll back the marker on failure to avoid stale selection entries.
			if selectAfterCreate {
				newlyCreatedFilePaths.remove(creationKey)
			}
			throw error
		}
	}
	
	enum CreatePathResolutionPolicy: Sendable {
		case literalPreferredIfStronger
		case canonicalAliasFirst
	}
	
	@MainActor
	func writeFileFromTool(
		userPath: String,
		content: String,
		ifExists: String,
		selectAfterCreate: Bool,
		pathResolutionPolicy: CreatePathResolutionPolicy = .literalPreferredIfStronger
	) async throws {
		let resolverRoots = visibleRootFolders.map {
			CreatePathPreflight.Root(id: $0.id, name: $0.name, fullPath: $0.fullPath)
		}
		
		let preflight: CreatePathPreflight.Result
		do {
			// Use relaxed mode: allow relative paths without alias if they can be resolved unambiguously
			preflight = try CreatePathPreflight.validate(
				userPath: userPath,
				visibleRoots: resolverRoots,
				mode: .allowImplicitRootIfUnambiguous
			)
		} catch let error as CreatePathPreflight.Error {
			switch error {
			case .emptyPath:
				throw FileManagerError.fileSystemServiceNotFoundWithContext("path is required for file creation.")
			case .ambiguousAlias(let alias, let matchingRoots):
				let rendered = matchingRoots.map(\.renderedLabel).joined(separator: "; ")
				throw FileManagerError.fileSystemServiceNotFoundWithContext(
					"Ambiguous root alias '\(alias)'. It matches multiple loaded roots: \(rendered). " +
					"Use an absolute path or rename roots so aliases are unique."
				)
			case .missingAliasWithMultipleRoots(let loadedRoots):
				// This case should no longer be thrown in relaxed mode, but keep for safety
				let rootsList = loadedRoots.map(\.renderedLabel).joined(separator: "; ")
				throw FileManagerError.fileSystemServiceNotFoundWithContext(
					"Multiple workspace roots are loaded; new files must use either an absolute path inside a loaded root " +
					"(e.g., '/path/to/root/new_file.swift') or a root-alias prefixed path 'RootName/...'. " +
					"Loaded roots: \(rootsList)"
				)
			}
		}
		
		let standardizedInput = preflight.normalizedPath
		let policy = ifExists.lowercased()
		if policy != "overwrite" && policy != "error" {
			throw FileManagerError.fileSystemServiceNotFoundWithContext(
				"Invalid if_exists value '\(ifExists)'. Use 'error' or 'overwrite'."
			)
		}
		
		if pathResolutionPolicy == .literalPreferredIfStronger, let literalCreateResult = resolvedLiteralCreateResult(
			for: standardizedInput,
			preflight: preflight
		) {
			try await writeFileFromTool(
				usingResolvedCreationResult: literalCreateResult,
				userPath: userPath,
				content: content,
				ifExistsPolicy: policy,
				selectAfterCreate: selectAfterCreate
			)
			return
		}
		
		// Safety: if the target is an existing folder, fail fast.
		if findFolder(atPath: standardizedInput) != nil {
			throw FileManagerError.fileSystemServiceNotFoundWithContext("'\(userPath)' resolves to a folder. Provide a file path.")
		}
		
		// Existing file: overwrite or error.
		if await fileExistsStrictly(atPath: standardizedInput) {
			if policy == "overwrite" {
				try await editFile(atRelativePath: standardizedInput, newContent: content)
				return
			}
			throw FileManagerError.fileSystemServiceNotFoundWithContext("path already exists: \(userPath)")
		}
		
		// Check if we need unambiguous resolution (multi-root + relative + no alias prefix)
		let needsUnambiguousResolution =
			!preflight.isAbsolute &&
			preflight.aliasCheck == .notPrefixed &&
			visibleRootFolders.count > 1
		
		if needsUnambiguousResolution {
			// Use the new unambiguous resolution path
			try await createFileFromToolUnambiguously(
				atUserPath: standardizedInput,
				content: content,
				selectAfterCreate: selectAfterCreate
			)
		} else {
			// Standard creation path (single root, absolute path, or alias-prefixed)
			try await createFile(atRelativePath: standardizedInput, content: content, selectAfterCreate: selectAfterCreate)
		}
	}

	@MainActor
	private func writeFileFromTool(
		usingResolvedCreationResult creationResult: FileCreationResult,
		userPath: String,
		content: String,
		ifExistsPolicy: String,
		selectAfterCreate: Bool
	) async throws {
		let correctedPath = creationResult.componentsToCreate.joined(separator: "/")
		let absolutePath = StandardizedPath.join(
			standardizedRoot: creationResult.rootFolder.rootPath,
			standardizedRelativePath: correctedPath
		)
		
		switch existingItemKind(atAbsolutePath: absolutePath) {
		case .folder:
			throw FileManagerError.fileSystemServiceNotFoundWithContext("'\(userPath)' resolves to a folder. Provide a file path.")
		case .file:
			if ifExistsPolicy == "overwrite" {
				_ = await reconcileExactDiskFileIfPresent(absolutePath, rootScope: .visibleWorkspace)
				try await editFileFromTool(atPath: absolutePath, newContent: content)
				return
			}
			throw FileManagerError.fileSystemServiceNotFoundWithContext("path already exists: \(userPath)")
		case nil:
			break
		}
		
		try await performCreateFromResult(
			creationResult: creationResult,
			content: content,
			selectAfterCreate: selectAfterCreate
		)
	}
	
	/// Creates a file with unambiguous root resolution for multi-root workspaces.
	/// Used when the user provides a relative path without a root alias.
	@MainActor
	private func createFileFromToolUnambiguously(
		atUserPath userPath: String,
		content: String,
		selectAfterCreate: Bool
	) async throws {
		let (staticData, selectedPaths, selectionSig) = currentStaticPathMatchContext(scope: .visibleWorkspace)
		let normalizedForCreate = normalizeUserInputPath(userPath)
		
		// Use unambiguous resolution mode
		guard let resolution = await pathMatchWorker.resolveCreationPath(
			userPath: normalizedForCreate,
			staticData: staticData,
			selectedFileFullPaths: selectedPaths,
			selectionSig: selectionSig,
			mode: .requireUnambiguous
		) else {
			// Could not resolve within workspace
			let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
			let msg = "Could not resolve a destination within the current workspace for '\(userPath)'. " +
				"Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path, " +
				"or ensure the path is inside one of these folders."
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		}
		
		switch resolution {
		case .ambiguous(let candidateRootPaths):
			// Multiple roots match equally - ask user to disambiguate
			let rootNames = candidateRootPaths.compactMap { path -> String? in
				visibleRootFolders.first { $0.fullPath == path }?.name
			}
			let candidates = rootNames.isEmpty
				? candidateRootPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
				: rootNames.joined(separator: ", ")
			
			throw FileManagerError.fileSystemServiceNotFoundWithContext(
				"Path '\(userPath)' could match multiple workspace roots: \(candidates). " +
				"Please disambiguate using 'RootName/\(userPath)' or provide an absolute path."
			)
			
		case .unique(let creationResult):
			// Unambiguous - proceed with creation using the resolved result
			try await performCreateFromResult(
				creationResult: creationResult,
				content: content,
				selectAfterCreate: selectAfterCreate
			)
		}
	}
	
	/// Executes file creation using a pre-resolved FileCreationResult.
	@MainActor
	private func performCreateFromResult(
		creationResult: FileCreationResult,
		content: String,
		selectAfterCreate: Bool
	) async throws {
		// Find the actual root folder from our list
		let standardizedCreationRootPath = (creationResult.rootFolder.fullPath as NSString).standardizingPath
		guard let rootFolder = rootFolders.first(where: { $0.standardizedFullPath == standardizedCreationRootPath }) else {
			let msg = "Internal error: computed creation root is not currently loaded."
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		}
		
		let correctedPath = creationResult.componentsToCreate.joined(separator: "/")
		
		guard let fsService = getFileSystemService(for: rootFolder.fullPath) else {
			let msg = "Unable to locate a file system service for '\(correctedPath)'."
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		}
		
		// Insert canonical key BEFORE the FS operation to avoid race with incoming FSEvents.
		let creationKey = makeCreationKey(rootFullPath: rootFolder.fullPath, relPath: correctedPath)
		if selectAfterCreate {
			newlyCreatedFilePaths.insert(creationKey)
		}
		do {
			try await fsService.createFile(atRelativePath: correctedPath, content: content)
			try await materializeCreatedWorkspaceFile(
				relativePath: correctedPath,
				onRootFolder: rootFolder,
				fsService: fsService,
				requestCodeScanImmediately: true,
				creationKey: creationKey,
				selectAfterCreate: selectAfterCreate
			)
		} catch {
			// Roll back the marker on failure to avoid stale selection entries.
			if selectAfterCreate {
				newlyCreatedFilePaths.remove(creationKey)
			}
			throw error
		}
	}
	
	// MARK: - Public file‑rename API
	@MainActor
	func renameFile(from oldPath: String, to newPath: String) async throws {
		let context = try await resolveMoveContext(oldPath: oldPath, newPath: newPath)
		let selectionKey = makeCreationKey(rootFullPath: context.rootFolder.fullPath, relPath: context.newRel)
		let oldAbs = StandardizedPath.join(
			standardizedRoot: context.rootFolder.standardizedFullPath,
			standardizedRelativePath: StandardizedPath.relative(context.oldRel)
		)
		let wasSelected = selectedFiles.contains { $0.standardizedFullPath == oldAbs }
		if wasSelected {
			newlyCreatedFilePaths.insert(selectionKey)
		}
		
		do {
			try await context.service.moveFile(
				atRelativePath: context.oldRel,
				toRelativePath: context.newRel
			)
		} catch {
			if wasSelected {
				newlyCreatedFilePaths.remove(selectionKey)
			}
			throw error
		}
		
		let standardizedRoot = context.rootFolder.standardizedFullPath
		await migrateSlicesForRename(rootPath: standardizedRoot, from: context.oldRel, to: context.newRel)
	}
	
	@MainActor
	func renameFileFromTool(oldPath: String, newPath: String) async throws {
		let context = try await resolveMoveContext(oldPath: oldPath, newPath: newPath)
		let selectionKey = makeCreationKey(rootFullPath: context.rootFolder.fullPath, relPath: context.newRel)
		let oldAbs = StandardizedPath.join(
			standardizedRoot: context.rootFolder.standardizedFullPath,
			standardizedRelativePath: StandardizedPath.relative(context.oldRel)
		)
		let wasSelected = selectedFiles.contains { $0.standardizedFullPath == oldAbs }
		if wasSelected {
			newlyCreatedFilePaths.insert(selectionKey)
		}
		
		let destAbs = StandardizedPath.join(
			standardizedRoot: context.rootFolder.standardizedFullPath,
			standardizedRelativePath: StandardizedPath.relative(context.newRel)
		)
		if fileHierarchyIndex.filesByFullPath[destAbs] != nil ||
			fileHierarchyIndex.foldersByFullPath[destAbs] != nil {
			if wasSelected {
				newlyCreatedFilePaths.remove(selectionKey)
			}
			throw FileManagerError.fileSystemServiceNotFoundWithContext("destination already exists: \(newPath)")
		}
		
		do {
			try await context.service.moveFile(
				atRelativePath: context.oldRel,
				toRelativePath: context.newRel
			)
		} catch {
			if wasSelected {
				newlyCreatedFilePaths.remove(selectionKey)
			}
			throw error
		}
		
		let standardizedRoot = context.rootFolder.standardizedFullPath
		await migrateSlicesForRename(rootPath: standardizedRoot, from: context.oldRel, to: context.newRel)
	}
	
	@MainActor
	private func resolveMoveContext(
		oldPath: String,
		newPath: String
	) async throws -> (service: FileSystemService, rootFolder: FolderViewModel, oldRel: String, newRel: String) {
		// 1) Locate the owning FileSystemService for the *source* file
		let normalizedOld = normalizeUserInputPath(oldPath)
		if let issue = exactPathResolutionIssue(for: normalizedOld, kind: .file) {
			throw FileManagerError.fileSystemServiceNotFoundWithContext(
				PathResolutionIssueRenderer.message(for: issue)
			)
		}
		guard let oldLocation = await getFileSystemServiceForRelativePath(
				normalizedOld,
				exactMatchOnly: true) else {
			let msg: String
			if visibleRootFolders.isEmpty {
				msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
			} else {
				let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
				msg = "Cannot move/rename '\(oldPath)' because it is not inside any loaded folder in this window. Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path."
			}
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		}
		
		guard let service = getFileSystemService(for: oldLocation.rootPath) else {
			throw FileManagerError.fileSystemServiceNotFoundWithContext("File system service unavailable for '\(oldLocation.rootPath)'.")
		}
		
		let standardizedRoot = (oldLocation.rootPath as NSString).standardizingPath
		guard let rootFolder = rootFolders.first(where: { $0.standardizedFullPath == standardizedRoot }) else {
			throw FileManagerError.fileSystemServiceNotFoundWithContext("Internal error: computed move root is not currently loaded.")
		}
		
		let normalizedNew = normalizeUserInputPath(newPath)
		let newRel = try resolveRelativePathInRootForMove(userPath: normalizedNew, root: rootFolder)
		
		return (service: service, rootFolder: rootFolder, oldRel: oldLocation.correctedPath, newRel: newRel)
	}
	
	// MARK: - Case‑insensitive helpers
	private func folderForFullPathCaseInsensitive(_ path: String) -> FolderViewModel? {
		let std = (path as NSString).standardizingPath
		// 1) fast exact hit
		if let exact = fileHierarchyIndex.foldersByFullPath[std] { return exact }
		// 2) fallback O(n) ‑ single pass, case‑folded compare
		let lower = std.lowercased()
		return fileHierarchyIndex
			.foldersByFullPath
			.first(where: { $0.key.lowercased() == lower })?
			.value
	}
	
	/// Checks if a root folder contains a real subfolder with the given name.
	/// Used to disambiguate alias resolution: if `RootName/...` is given and the root
	/// actually contains a subfolder named `RootName`, we should NOT strip the first component.
	private func rootHasRealSubfolder(named alias: String, under root: FolderViewModel) -> Bool {
		let subfolderPath = StandardizedPath.join(
			standardizedRoot: root.standardizedFullPath,
			standardizedRelativePath: StandardizedPath.relative(alias)
		)
		// Check in-memory index first (fast path)
		if folderForFullPathCaseInsensitive(subfolderPath) != nil {
			return true
		}
		// Fallback: check disk for folders not yet indexed (conservative)
		var isDir: ObjCBool = false
		return FileManager.default.fileExists(atPath: subfolderPath, isDirectory: &isDir) && isDir.boolValue
	}
	
	private enum ExistingPathItemKind {
		case file
		case folder
	}
	
	private func existingItemKind(atAbsolutePath path: String) -> ExistingPathItemKind? {
		let standardized = StandardizedPath.absolute(path)
		if folderForFullPathCaseInsensitive(standardized) != nil {
			return .folder
		}
		if fileHierarchyIndex.filesByFullPath[standardized] != nil {
			return .file
		}
		var isDir: ObjCBool = false
		guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir) else {
			return nil
		}
		return isDir.boolValue ? .folder : .file
	}
	
	private func deepestExistingFolderPrefixDepth(
		for components: [String],
		under root: FolderViewModel,
		baseRelativePath: String = ""
	) -> Int {
		guard !components.isEmpty else { return 0 }
		var matchedDepth = 0
		var currentRelativePath = StandardizedPath.relative(baseRelativePath)
		for component in components {
			let nextRelativePath = currentRelativePath.isEmpty
				? component
				: currentRelativePath + "/" + component
			let nextAbsolutePath = StandardizedPath.join(
				standardizedRoot: root.standardizedFullPath,
				standardizedRelativePath: nextRelativePath
			)
			guard case .folder = existingItemKind(atAbsolutePath: nextAbsolutePath) else {
				break
			}
			matchedDepth += 1
			currentRelativePath = nextRelativePath
		}
		return matchedDepth
	}
	
	/// Tool-create-specific literal-vs-alias override used by `writeFileFromTool`.
	/// This is intentionally richer than `WorkspaceAliasResolver.disambiguateRealSubpath`:
	/// it compares full existing directory-chain depth for alias-stripped and literal paths.
	/// Alias wins ties; literal only wins when structurally stronger.
	/// This protects `file_actions create` while letting other callers select
	/// `.canonicalAliasFirst` when they need historical behavior.
	private func resolvedLiteralCreateResult(
		for normalizedUserPath: String,
		preflight: CreatePathPreflight.Result
	) -> FileCreationResult? {
		guard !preflight.isAbsolute else { return nil }
		guard case .uniqueRoot(let root, let alias) = preflight.aliasCheck else { return nil }
		guard let rootVM = visibleRootFolders.first(where: { $0.id == root.id }) else { return nil }
		guard rootHasRealSubfolder(named: alias, under: rootVM) else { return nil }
		let literalBaseAbsolutePath = StandardizedPath.join(
			standardizedRoot: rootVM.standardizedFullPath,
			standardizedRelativePath: StandardizedPath.relative(alias)
		)
		let literalBaseRelativePath = folderForFullPathCaseInsensitive(literalBaseAbsolutePath)?.relativePath
			?? StandardizedPath.relative(alias)
		
		let components = StandardizedPath.relative(normalizedUserPath)
			.split(separator: "/")
			.map(String.init)
		guard components.count >= 2 else { return nil }
		let remainderDirComponents = Array(components.dropFirst().dropLast())
		
		let aliasDepth = deepestExistingFolderPrefixDepth(
			for: remainderDirComponents,
			under: rootVM
		)
		let literalDepth = 1 + deepestExistingFolderPrefixDepth(
			for: remainderDirComponents,
			under: rootVM,
			baseRelativePath: literalBaseRelativePath
		)
		guard literalDepth > aliasDepth else { return nil }
		
		let literalPrefixComponents = StandardizedPath.relative(literalBaseRelativePath)
			.split(separator: "/")
			.map(String.init)
		let literalComponents = literalPrefixComponents + Array(components.dropFirst())
		return FileCreationResult(
			rootFolder: FrozenFolderRecord(from: rootVM),
			componentsToCreate: literalComponents
		)
	}
	
	@MainActor
	private func resolveRelativePathInRootForMove(
		userPath: String,
		root: FolderViewModel
	) throws -> String {
		let normalized = normalizeUserInputPath(userPath)
		let sourceRoot = MovePathResolver.Root(id: root.id, name: root.name, fullPath: root.fullPath)
		let visibleRoots = visibleRootFolders.map {
			MovePathResolver.Root(id: $0.id, name: $0.name, fullPath: $0.fullPath)
		}
		
		do {
			return try MovePathResolver.resolveRelativePathInRoot(
				userPath: normalized,
				sourceRoot: sourceRoot,
				visibleRoots: visibleRoots
			)
		} catch let error as MovePathResolver.Error {
			switch error {
			case .emptyDestination:
				throw FileManagerError.fileSystemServiceNotFoundWithContext("Destination path is required for move/rename.")
			case .destinationOutsideRoot:
				throw FileManagerError.fileSystemServiceNotFoundWithContext(
					"Move destination must remain inside the source root: \(root.name) → \(root.fullPath)."
				)
			case .ambiguousAlias(let alias, let matchingRoots):
				let rendered = matchingRoots.map(\.renderedLabel).joined(separator: "; ")
				throw FileManagerError.fileSystemServiceNotFoundWithContext(
					"Ambiguous root alias '\(alias)'. It matches multiple loaded roots: \(rendered). " +
					"Use an absolute path or rename roots so aliases are unique."
				)
			case .crossRootAlias(let alias, let resolvedRoot):
				throw FileManagerError.fileSystemServiceNotFoundWithContext(
					"Move destinations must remain in the source root. You provided an alias for a different root: '\(alias)' → \(resolvedRoot.fullPath)."
				)
			}
		}
	}

	
	// Static flag to control logging
	#if DEBUG
	private static var isLoggingEnabled: Bool = true
	#else
	private static var isLoggingEnabled: Bool = false
	#endif
	
	private func makeCreationKey(rootFullPath: String, relPath: String) -> String {
		let rootStd = StandardizedPath.absolute(rootFullPath).lowercased()
		let relStd  = StandardizedPath.relative(relPath).lowercased()
		return rootStd + "|" + relStd
	}

	@MainActor
	private func findFileByStandardizedFullPath(_ standardizedFullPath: String) -> FileViewModel? {
		fileHierarchyIndex.filesByFullPath[standardizedFullPath]
	}

	@MainActor
	private func consumeNewlyCreatedFileMarkerIfPresent(
		rootFullPath: String,
		relativePath: String,
		fileAddPathMetricsCollector: ReplayFileAddPathMetricsCollector? = nil
	) -> Bool {
		guard !newlyCreatedFilePaths.isEmpty else {
			#if DEBUG
			fileAddPathMetricsCollector?.recordNewlyCreatedMarkerEmptySetSkip()
			#endif
			return false
		}

		let creationKey = makeCreationKey(rootFullPath: rootFullPath, relPath: relativePath)
		#if DEBUG
		fileAddPathMetricsCollector?.recordNewlyCreatedMarkerKeyBuild()
		#endif
		let consumed = newlyCreatedFilePaths.remove(creationKey) != nil
		#if DEBUG
		if consumed {
			fileAddPathMetricsCollector?.recordNewlyCreatedMarkerConsumed()
		}
		#endif
		return consumed
	}
	
	/// Returns the *top‑level* root folder that should own the new file,
	/// together with the **relative path components** that still need to be
	/// created inside that root.
	///
	/// The routine now performs *two* scans per root:
	///   1. starting at component‑index 0 (the normal case)
	///   2. starting at component‑index 1  ➜  "ignore the 1st component"
	///
	/// Whichever of the two yields the deeper match is kept.
	/// Finally, all roots are compared and the best overall candidate is
	/// returned.  If two (or more) roots tie after all heuristics, `nil` is
	/// returned so the caller can ask the user to disambiguate.
/// Optimised lookup: try the absolute-path index first (O(1));
/// fall back to the legacy DFS only if the index misses.
///
/// - Parameter relativePath: path **relative to the repo root** (no leading "/").
private func findFolderRecursive(
	in folder: FolderViewModel,
	relativePath: String
) -> FolderViewModel? {
	
	// ❶ Fast path – absolute-path index
	if !relativePath.isEmpty {
		let absPath = ((folder.rootPath as NSString)
						.appendingPathComponent(relativePath) as NSString)
						.standardizingPath
		if let hit = fileHierarchyIndex.foldersByFullPath[absPath] {
			return hit                                      // ✅ O(1)
		}
	}
	
	// ❷ Slow path – depth-first search (only during early loads)
	var visitedFolderIDs = Set<UUID>()
	var stack: [FolderViewModel] = [folder]
	while let current = stack.popLast() {
		guard visitedFolderIDs.insert(current.id).inserted else { continue }
		if current.relativePath == relativePath { return current }
		for child in current.children {
			if case .folder(let sub) = child {
				stack.append(sub)
			}
		}
	}
	return nil
}

	/// Search for a folder path among all root folders
	private func findFolderRecursive(inAnyRoot path: String) -> FolderViewModel? {
		for root in rootFolders {
			if let foundFolder = findFolderRecursive(in: root, relativePath: path) {
				return foundFolder
			}
		}
		return nil
	}
	
	func editFile(atRelativePath relativePath: String, newContent: String) async throws {
		try await editFileInternal(
			atPath: relativePath,
			newContent: newContent,
			profile: .uiAssisted,
			exactMatchOnly: false
		)
	}

	@MainActor
	func editFileFromTool(atPath path: String, newContent: String) async throws {
		try await editFileInternal(
			atPath: path,
			newContent: newContent,
			profile: .mcpRead,
			exactMatchOnly: true
		)
	}

	@MainActor
	private func editFileInternal(
		atPath path: String,
		newContent: String,
		profile: PathLocateProfile,
		exactMatchOnly: Bool
	) async throws {
		let normalizedPath = normalizeUserInputPath(path)
		if case .uiAssisted = profile {
			// Keep UI flows permissive.
		} else if isExplicitSystemPath(normalizedPath) {
			let msg: String
			if visibleRootFolders.isEmpty {
				msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
			} else {
				let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
				msg = "Cannot edit '\(path)' because it is not inside any loaded folder in this window. Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path."
			}
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		} else if let issue = exactPathResolutionIssue(for: normalizedPath, kind: .file) {
			throw FileManagerError.fileSystemServiceNotFoundWithContext(
				PathResolutionIssueRenderer.message(for: issue)
			)
		}
		guard let location = await getFileSystemServiceForRelativePath(
			normalizedPath,
			exactMatchOnly: exactMatchOnly,
			profile: profile
		) else {
			let msg: String
			if visibleRootFolders.isEmpty {
                msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
			} else {
				let roots = visibleRootFolders.map(\.name).joined(separator: ", ")
				msg = "Cannot edit '\(path)' because it is not inside any loaded folder in this window. Loaded roots: \(roots). Use 'manage_workspaces' to switch to a workspace containing this path."
			}
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		}
		
		guard let fileSystemService = getFileSystemService(for: location.rootPath) else {
			throw FileManagerError.fileSystemServiceNotFoundWithContext("File system service unavailable for '\(location.rootPath)'.")
		}
		
		let correctedPath = location.correctedPath
		
		do {
			try await fileSystemService.editFile(atRelativePath: correctedPath, newContent: newContent)
			if let file = await findFile(atPath: correctedPath,
											rootIdentifier: location.rootIdentifier) {
				await file.updateContent(newContent)
				let modificationDate = try? await fileSystemService.getFileModificationDate(atRelativePath: correctedPath)
				await applyFileSystemDeltas(
					[.fileModified(correctedPath, modificationDate)],
					forRootKey: file.standardizedRootFolderPath,
					deferIfUnfocused: false
				)
				await file.setModificationDate(modificationDate ?? Date(), forceInvalidation: true)
				codemapCapableAPIsByFullPath.removeValue(forKey: file.standardizedFullPath)
			} else {
				throw FileSystemError.fileNotFound
			}
		} catch {
			throw FileSystemError.failedToEditFile(error)
		}
	}
	
	func deleteFile(atRelativePath relativePath: String) async throws {
		let context = try await resolveDeleteContext(userPath: relativePath)
		do {
			_ = try await context.service.deleteFile(atRelativePath: context.correctedPath)
			await dematerializeKnownWorkspaceItem(relativePath: context.correctedPath, onRootFolder: context.rootFolder)
		} catch FileSystemError.fileNotFound {
			await dematerializeKnownWorkspaceItem(relativePath: context.correctedPath, onRootFolder: context.rootFolder)
			throw FileSystemError.failedToDeleteFile(FileSystemError.fileNotFound)
		} catch {
			throw FileSystemError.failedToDeleteFile(error)
		}
	}
	
	func trashFileFromTool(atPath path: String) async throws {
		let context = try await resolveDeleteContext(userPath: path, requiresAbsoluteForToolDelete: true)
		do {
			_ = try await context.service.moveItemToTrash(atRelativePath: context.correctedPath)
			await dematerializeKnownWorkspaceItem(relativePath: context.correctedPath, onRootFolder: context.rootFolder)
		} catch FileSystemError.fileNotFound {
			await dematerializeKnownWorkspaceItem(relativePath: context.correctedPath, onRootFolder: context.rootFolder)
			throw FileSystemError.failedToDeleteFile(FileSystemError.fileNotFound)
		} catch {
			throw FileSystemError.failedToDeleteFile(error)
		}
	}
	
	private func resolveDeleteContext(
		userPath: String,
		requiresAbsoluteForToolDelete: Bool = false
	) async throws -> (service: FileSystemService, correctedPath: String, rootFolder: FolderViewModel) {
		let normalizedPath = normalizeUserInputPath(userPath)
		guard !requiresAbsoluteForToolDelete || normalizedPath.hasPrefix("/") else {
			throw FileManagerError.fileSystemServiceNotFoundWithContext(
				deletePathRejectionMessage(for: userPath, normalizedPath: normalizedPath)
			)
		}
		if normalizedPath.hasPrefix("/") {
			let standardizedPath = (normalizedPath as NSString).standardizingPath
			if let rootFolder = rootFolders
				.filter({ root in
					standardizedPath == root.standardizedFullPath || standardizedPath.hasPrefix(root.standardizedFullPath.hasSuffix("/") ? root.standardizedFullPath : root.standardizedFullPath + "/")
				})
				.max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count }),
				(findFileByFullPath(standardizedPath) != nil || findFolderByFullPath(standardizedPath) != nil),
				let fileSystemService = getFileSystemService(for: rootFolder.standardizedFullPath) {
				let relativePath = RelativePath.fromStandardized(
					standardizedAbsolutePath: standardizedPath,
					standardizedRootPath: rootFolder.standardizedFullPath
				)
				return (service: fileSystemService, correctedPath: relativePath, rootFolder: rootFolder)
			}
		}
		guard let location = await getFileSystemServiceForRelativePath(normalizedPath, exactMatchOnly: true) else {
			throw FileManagerError.fileSystemServiceNotFoundWithContext(
				deletePathRejectionMessage(for: userPath, normalizedPath: normalizedPath)
			)
		}
		
		guard let fileSystemService = getFileSystemService(for: location.rootPath) else {
			throw FileManagerError.fileSystemServiceNotFoundWithContext("File system service unavailable for '\(location.rootPath)'.")
		}
		guard let rootFolder = rootFolders.first(where: { $0.standardizedFullPath == (location.rootPath as NSString).standardizingPath }) else {
			throw FileManagerError.fileSystemServiceNotFoundWithContext("Workspace root unavailable for '\(location.rootPath)'.")
		}
		
		return (service: fileSystemService, correctedPath: location.correctedPath, rootFolder: rootFolder)
	}

	@MainActor
	func deleteAbsolutePathRequiredMessage(for userPath: String) -> String {
		deletePathRejectionMessage(for: userPath, normalizedPath: normalizeUserInputPath(userPath))
	}

	@MainActor
	private func deletePathRejectionMessage(for userPath: String, normalizedPath: String) -> String {
		let trimmedInput = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedInput.isEmpty else {
			return "Path is required for file deletion. file_actions.delete requires a true absolute filesystem path."
		}
		if StandardizedPath.containsNUL(trimmedInput) {
			return PathResolutionIssueRenderer.message(for: .invalidPathCharacters(
				input: trimmedInput,
				reason: "embedded NUL (\\0) characters are not allowed"
			))
		}

		let standardizedPath = (normalizedPath as NSString).standardizingPath
		let loadedRootRefs = allWorkspaceRoots()
		guard !loadedRootRefs.isEmpty else {
			return "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
		}

		func absolutePath(root: WorkspaceRootRef, relativePath: String) -> String {
			StandardizedPath.join(
				standardizedRoot: root.standardizedFullPath,
				standardizedRelativePath: StandardizedPath.relative(relativePath)
			)
		}

		func exactOnlySuffix() -> String {
			" file_actions.delete is exact and non-fuzzy; it does not accept relative, root-qualified, leading-slash root-alias, or _git_data alias paths for deletion."
		}

		func absoluteOnlyMessage(kind: String, suggestion: String? = nil) -> String {
			var message = "Cannot delete '\(userPath)' because \(kind). file_actions.delete requires a true absolute filesystem path inside a loaded root."
			if let suggestion, !suggestion.isEmpty {
				message += " Use: \(suggestion)"
			} else {
				message += " Use get_file_tree with type='roots' to list loaded root absolute paths, then pass the full absolute path to the item."
			}
			message += exactOnlySuffix()
			return message
		}

		if !standardizedPath.hasPrefix("/") {
			if let explicitSystemPath = resolveExplicitSystemPath(trimmedInput) {
				return absoluteOnlyMessage(
					kind: "it is a supplemental/system-root alias, not a true absolute path",
					suggestion: explicitSystemPath.standardizedAbsolutePath
				)
			}

			switch WorkspaceAliasResolver.resolve(
				userPath: standardizedPath,
				roots: loadedRootRefs,
				options: RootAliasOptions(
					requireRemainder: false,
					allowCompatibilityAlias: true,
					disambiguateRealSubpath: false
				)
			) {
			case .ambiguous(let alias, let matchingRoots):
				return PathResolutionIssueRenderer.message(for: .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)) + " file_actions.delete requires a true absolute filesystem path."
			case .bareRoot(let root, _):
				return absoluteOnlyMessage(
					kind: "it is a root-qualified display alias, not a true absolute path",
					suggestion: root.standardizedFullPath
				)
			case .prefixed(let root, _, let remainder):
				return absoluteOnlyMessage(
					kind: "it is a root-qualified display alias, not a true absolute path",
					suggestion: absolutePath(root: root, relativePath: remainder)
				)
			case .notAliasPrefixed:
				if visibleRootFolders.count == 1, let root = visibleWorkspaceRoots().first {
					return absoluteOnlyMessage(
						kind: "it is a relative/display path, not a true absolute path",
						suggestion: absolutePath(root: root, relativePath: standardizedPath)
					)
				}
				return absoluteOnlyMessage(kind: "it is a relative/display path, not a true absolute path")
			}
		}

		if let leadingSlashAlias = resolveLeadingSlashRootAlias(from: standardizedPath, requireRemainder: false) {
			switch leadingSlashAlias {
			case .ambiguous(let alias, let matchingRoots):
				return PathResolutionIssueRenderer.message(for: .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)) + " file_actions.delete requires a true absolute filesystem path, not a leading-slash root alias."
			case .bareRoot(let root, _):
				return absoluteOnlyMessage(
					kind: "it looks like a leading-slash root alias ('/RootName/...'), not a true absolute filesystem path",
					suggestion: root.standardizedFullPath
				)
			case .prefixed(let root, _, let remainder):
				return absoluteOnlyMessage(
					kind: "it looks like a leading-slash root alias ('/RootName/...'), not a true absolute filesystem path",
					suggestion: absolutePath(root: root, relativePath: remainder)
				)
			case .notAliasPrefixed:
				break
			}
		}

		if let loadedRoot = loadedRootRefs
			.filter({ root in
				standardizedPath == root.standardizedFullPath
					|| standardizedPath.hasPrefix(root.standardizedFullPath.hasSuffix("/") ? root.standardizedFullPath : root.standardizedFullPath + "/")
			})
			.max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count }) {
			let rootKind = rootFolders.first(where: { $0.id == loadedRoot.id })?.isSystemRoot == true
				? "loaded supplemental/system root"
				: "loaded root"
			let existsOnDisk = FileManager.default.fileExists(atPath: standardizedPath)
			let existenceDetail = existsOnDisk
				? "The path appears to exist on disk, but it is not indexed/resolved in this workspace window."
				: "No indexed file or folder exists at that exact path."
			return "Cannot delete '\(userPath)' because it is inside \(rootKind) \(loadedRoot.renderedLabel), but RepoPrompt could not resolve an exact file or folder there. \(existenceDetail) Verify the true absolute path, refresh/reload the workspace if the item was just created, and retry. file_actions.delete is exact and non-fuzzy."
		}

		return PathResolutionIssueRenderer.message(for: .pathOutsideWorkspace(input: userPath, visibleRoots: loadedRootRefs)) + " file_actions.delete only deletes true absolute paths inside loaded roots."
	}
	
	/// Bulk version that efficiently handles multiple paths
	@MainActor
	func findFiles(
		atPaths relativePaths: [String],
		profile: PathLocateProfile = .uiAssisted,
		rootScopeOverride: LookupRootScope? = nil
	) async -> [String: FileViewModel] {
		var results: [String: FileViewModel] = [:]
		var pathsNeedingMatcher: [(original: String, normalized: String)] = []
		let lookupScope = effectiveLookupRootScope(for: profile, override: rootScopeOverride)
		
		for original in relativePaths {
			let normalized = normalizeUserInputPath(original)
			guard !normalized.isEmpty else { continue }
			if allowsExplicitSystemPathResolution(for: profile),
			   let explicitResolution = resolveExplicitSystemPath(normalized) {
				if let hit = fileHierarchyIndex.filesByFullPath[explicitResolution.standardizedAbsolutePath] {
					results[original] = hit
				}
				continue
			}
			if (profile == .mcpRead || profile == .mcpSearchScope),
			   let explicitResolution = resolveExplicitSystemPath(normalized) {
				if let hit = fileHierarchyIndex.filesByFullPath[explicitResolution.standardizedAbsolutePath] {
					results[original] = hit
				}
				continue
			}
			if shouldPreflightDeterministicLookup(for: profile),
				exactPathResolutionIssue(for: normalized, kind: .file, rootScope: lookupScope) != nil {
				continue
			}
			
			if !normalized.hasPrefix("/") {
				switch resolveVisibleRootAlias(normalized, requireRemainder: true, disambiguateRealSubpath: false) {
				case .prefixed(let root, _, let remainder):
					let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
					if let hit = fileHierarchyIndex.filesByFullPath[abs] {
						results[original] = hit
						continue
					}
					let literalMatches = literalRelativeFileMatches(for: normalized)
					if literalMatches.count == 1, let hit = literalMatches.first {
						results[original] = hit
						continue
					}
					pathsNeedingMatcher.append((original: original, normalized: normalized))
					continue
				case .ambiguous:
					if shouldPreflightDeterministicLookup(for: profile) {
						continue
					}
					pathsNeedingMatcher.append((original: original, normalized: normalized))
					continue
				case .notAliasPrefixed, .bareRoot:
					break
				}
				
				if let hit = findFileByRelativePath(normalized, scope: lookupScope) {
					results[original] = hit
					continue
				}
			}
			
			if normalized.hasPrefix("/") {
				let stdAbs = (normalized as NSString).standardizingPath
				if let hit = fileHierarchyIndex.filesByFullPath[stdAbs] {
					results[original] = hit
					continue
				}
			}
			
			pathsNeedingMatcher.append((original: original, normalized: normalized))
		}
		
		guard !pathsNeedingMatcher.isEmpty else {
			return await validateCatalogFilesStillPresent(results, for: profile)
		}
		
		let (staticData, selectedPaths, selectionSig) = currentStaticPathMatchContext(scope: lookupScope)
		var matcherResults: [(String, String?)] = []
		for (original, normalized) in pathsNeedingMatcher {
			let match = await pathMatchWorker.locate(
				userPath: normalized,
				profile: profile,
				staticData: staticData,
				selectedFileFullPaths: selectedPaths,
				selectionSig: selectionSig
			)
			
			if let match = match {
				let absolutePath = ((match.rootPath as NSString)
					.appendingPathComponent(match.correctedPath) as NSString)
					.standardizingPath
				matcherResults.append((original, absolutePath))
			} else {
				matcherResults.append((original, nil))
			}
		}
		
		for (originalPath, standardizedPath) in matcherResults {
			if let standardizedPath = standardizedPath,
				let fileVM = fileHierarchyIndex.filesByFullPath[standardizedPath] {
				results[originalPath] = fileVM
			}
		}
		
		return await validateCatalogFilesStillPresent(results, for: profile)
	}
	
	/// Convenience method for backward compatibility
	@MainActor
	func findFile(atPath relativePath: String) async -> FileViewModel? {
		return await findFile(atPath: relativePath, rootIdentifier: nil)
	}

	@MainActor
	private func resolveExactExistingFileForToolEdit(atPath path: String) -> FileViewModel? {
		let normalized = normalizeUserInputPath(path).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalized.isEmpty else { return nil }
		let standardized = (normalized as NSString).standardizingPath

		if let issue = exactPathResolutionIssue(for: standardized, kind: .file) {
			switch issue {
			case .ambiguousAlias, .ambiguousRootMatch:
				return nil
			default:
				break
			}
		}

		if standardized.hasPrefix("/") {
			if let exact = fileHierarchyIndex.filesByFullPath[standardized] {
				return exact
			}
			if let aliasResolution = resolveLeadingSlashRootAlias(from: standardized, requireRemainder: false) {
				switch aliasResolution {
				case .prefixed(let root, _, let remainder):
					let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
					return fileHierarchyIndex.filesByFullPath[abs]
				case .bareRoot, .ambiguous, .notAliasPrefixed:
					return nil
				}
			}
			return nil
		}

		switch resolveVisibleRootAlias(standardized, requireRemainder: true, disambiguateRealSubpath: false) {
		case .prefixed(let root, _, let remainder):
			let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
			if let exact = fileHierarchyIndex.filesByFullPath[abs] {
				return exact
			}
			let literalMatches = literalRelativeFileMatches(for: standardized)
			return literalMatches.count == 1 ? literalMatches.first : nil
		case .ambiguous:
			return nil
		case .notAliasPrefixed, .bareRoot:
			break
		}

		let literalMatches = literalRelativeFileMatches(for: standardized)
		return literalMatches.count == 1 ? literalMatches.first : nil
	}
	
	@MainActor
	func fileExistsStrictly(atPath path: String) async -> Bool {
		if let file = resolveExactExistingFileForToolEdit(atPath: path) {
			return await validateCatalogFileStillPresent(file) != nil
		}
		return await reconcileExactDiskFileIfPresent(path, rootScope: .visibleWorkspace) != nil
	}
	
	@MainActor
	func resolveExistingFileForToolEdit(atPath path: String) async -> FileViewModel? {
		if let file = resolveExactExistingFileForToolEdit(atPath: path) {
			return await validateCatalogFileStillPresent(file)
		}
		return await reconcileExactDiskFileIfPresent(path, rootScope: .visibleWorkspace)
	}
	
	/// Finds a file view-model for the given path.
	///
	/// This method now uses the bulk findFiles implementation for consistency.
	/// When a rootIdentifier is provided, it tries to construct an absolute path
	/// for more efficient lookup before falling back to the general search.
	///
	/// - Parameters:
	///   - relativePath: A relative **or** absolute path supplied by the caller.
	///   - rootIdentifier: Optional UUID constraining the search to one repo
	///                     root.  Pass `nil` for the old global behaviour.
	/// - Returns: The `FileViewModel` if found; otherwise `nil`.
	@MainActor
	func findFile(atPath relativePath: String, rootIdentifier: UUID?) async -> FileViewModel? {
		let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		
		// If we have a root identifier and a relative path, try to construct the absolute path first
		if let rootID = rootIdentifier, !trimmed.hasPrefix("/") {
			if let root = rootFolders.first(where: { $0.id == rootID }) {
				// Construct absolute path for this specific root
				let absolutePath = (root.fullPath as NSString).appendingPathComponent(trimmed)
				
				// Try finding with the absolute path first (more efficient)
				let results = await findFiles(atPaths: [absolutePath], profile: .mcpRead)
				if let fileVM = results[absolutePath] {
					return fileVM
				}
			}
		}
		
		// Fall back to regular search
		let results = await findFiles(atPaths: [relativePath], profile: .mcpRead)
		guard let fileVM = results[relativePath] else { return nil }
		
		// If a root identifier is specified, ensure the file belongs to that root
		if let rootID = rootIdentifier {
			return fileVM.rootIdentifier == rootID ? fileVM : nil
		}
		
		return fileVM
	}

	
	private func removeFile(atRelativePath relativePath: String) {
		let standardizedRel = (relativePath as NSString).standardizingPath
		for absPath in absolutePathCandidates(forRelativePath: standardizedRel) {
			if let removedFile = fileHierarchyIndex.removeFile(forKey: absPath) {
				removeFileFromParentChildrenArray(removedFile)
				return
			}
		}
		print("failed to remove file \(relativePath)")
	}
	
	func parentDirectory(of relativePath: String) -> String {
		guard let slashIndex = relativePath.lastIndex(of: "/") else {
			return ""
		}
		return String(relativePath[..<slashIndex])
	}
	
	/// Remove the file VM from its parent’s children array, using full paths instead of relative paths.
	private func removeFileFromParentChildrenArray(_ fileVM: FileViewModel) {
		pruneRemovedFilesFromSelectionAndCodemap([fileVM])
		
		// Compute the parent folder's absolute path
		let parentFullPath = (fileVM.fullPath as NSString).deletingLastPathComponent
		let standardizedParent = (parentFullPath as NSString).standardizingPath
		
		// Look up the parent FolderViewModel by absolute path
		if let parentFolder = fileHierarchyIndex.foldersByFullPath[standardizedParent] {
			parentFolder.removeFile(fileVM)
			return
		}
		
		// Fallback: if the FileViewModel still has a parentFolder reference, use it
		if let directParent = fileVM.parentFolder {
			directParent.removeFile(fileVM)
			return
		}
		
		// Improved last resort: reconstruct chain if the parent VM is missing, then retry
		if let owningRoot = rootFolders.first(where: { standardizedParent.isDescendant(of: $0.standardizedFullPath) }) {
			let relParent = String(standardizedParent.dropFirst(owningRoot.standardizedFullPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
			if !relParent.isEmpty {
				createMissingParentFolder(parentPath: relParent, under: owningRoot)
			if let parentFolder = fileHierarchyIndex.foldersByFullPath[standardizedParent] {
				parentFolder.removeFile(fileVM)
				return
			}
			}
		}
		
		// Fallback: nothing to do
	}
	
	private func updateParentFoldersAfterRemoval(_ folder: FolderViewModel) {
		var visitedFolderIDs = Set<UUID>()
		var current: FolderViewModel? = folder
		while let folderVM = current, visitedFolderIDs.insert(folderVM.id).inserted {
			folderVM.updateCheckboxStateImmediately()
			current = findParentFolder(for: folderVM)
		}
	}
	
	private func findParentFolder(for folder: FolderViewModel) -> FolderViewModel? {
		for rootFolder in rootFolders {
			if let parent = findParentFolderRecursive(rootFolder, folder) {
				return parent
			}
		}
		return nil
	}
	
	private func findParentFolderRecursive(_ currentFolder: FolderViewModel, _ targetFolder: FolderViewModel) -> FolderViewModel? {
		var visitedFolderIDs = Set<UUID>()
		var stack: [FolderViewModel] = [currentFolder]
		while let current = stack.popLast() {
			guard visitedFolderIDs.insert(current.id).inserted else { continue }
			for child in current.children {
				if case .folder(let childFolder) = child {
					if childFolder.id == targetFolder.id {
						return current
					}
					stack.append(childFolder)
				}
			}
		}
		return nil
	}
	
	private func findParentFolder(forRelativePath relativePath: String) -> FolderViewModel? {
		let components = relativePath.split(separator: "/")
		guard components.count > 1 else { return nil }
		
		let parentPath = components.dropLast().joined(separator: "/")
		
		for rootFolder in rootFolders {
			if let folder = findFolderRecursive(in: rootFolder, relativePath: parentPath) {
				return folder
			}
		}
		return nil
	}
	
	private func isFolderAlreadyLoaded(_ url: URL) -> Bool {
		let standardizedPath = (url.path as NSString).standardizingPath
		return rootFolders.contains { $0.standardizedFullPath == standardizedPath }
	}
	
	func expandAllChildren(of folder: FolderViewModel) {
		setExpandedStateRecursively(folder, expanded: true)
	}

	func collapseAllChildren(of folder: FolderViewModel) {
		setExpandedStateRecursively(folder, expanded: false)
	}
	
	/// Reorder root folders to match the desired order from workspace configuration
	@MainActor
	@discardableResult
	func reorderRootFolders(to desiredOrder: [String]) -> Bool {
		let canonical: (String) -> String = { (($0 as NSString).standardizingPath).lowercased() }
		let systemRoots = orderedSystemRoots(rootFolders.filter { $0.isSystemRoot })
		var userRoots = rootFolders.filter { !$0.isSystemRoot }
		
		var seen = Set<String>()
		var desiredCanonicalOrder: [String] = []
		for path in desiredOrder {
			let key = canonical(path)
			if seen.insert(key).inserted {
				desiredCanonicalOrder.append(key)
			}
		}
		
		var indexByCanonical: [String: Int] = [:]
		for (idx, key) in desiredCanonicalOrder.enumerated() {
			indexByCanonical[key] = idx
		}
		
		var originalIndex: [String: Int] = [:]
		for (idx, folder) in userRoots.enumerated() {
			let key = canonical(folder.fullPath)
			if originalIndex[key] == nil {
				originalIndex[key] = idx
			}
		}
		
		userRoots.sort { a, b in
			let aKey = canonical(a.fullPath)
			let bKey = canonical(b.fullPath)
			let aFound = indexByCanonical[aKey] != nil
			let bFound = indexByCanonical[bKey] != nil
			if aFound != bFound { return aFound }
			let ai = indexByCanonical[aKey] ?? Int.max
			let bi = indexByCanonical[bKey] ?? Int.max
			if ai != bi { return ai < bi }
			let ao = originalIndex[aKey] ?? Int.max
			let bo = originalIndex[bKey] ?? Int.max
			return ao < bo
		}
		let reorderedRoots = userRoots + systemRoots
		guard rootFolders.map(\.id) != reorderedRoots.map(\.id) else { return false }
		rootFolders = reorderedRoots
		onRootFoldersChanged?()
		return true
	}

	/// Keep _git_data pinned to the end of system roots (stable order for others).
	private func orderedSystemRoots(_ roots: [FolderViewModel]) -> [FolderViewModel] {
		guard !roots.isEmpty else { return roots }
		let gitDataRoots = roots.filter { $0.name == "_git_data" }
		guard !gitDataRoots.isEmpty else { return roots }
		let otherRoots = roots.filter { $0.name != "_git_data" }
		return otherRoots + gitDataRoots
	}
	
	/// Move the given root one position up, if possible.
	func moveRootFolderUp(_ folder: FolderViewModel) {
		guard !folder.isSystemRoot else { return }
		let systemRoots = orderedSystemRoots(rootFolders.filter { $0.isSystemRoot })
		var userRoots = visibleRootFolders
		guard let idx = userRoots.firstIndex(where: { $0.id == folder.id }),
				idx > 0 else { return }
		userRoots.remove(at: idx)
		userRoots.insert(folder, at: idx - 1)
		rootFolders = userRoots + systemRoots
		// Persist this order via WorkspaceManager
		onRootFoldersReordered.send(userRoots.map { $0.fullPath })
	}
	
	/// Move the given root one position down, if possible.
	func moveRootFolderDown(_ folder: FolderViewModel) {
		guard !folder.isSystemRoot else { return }
		let systemRoots = orderedSystemRoots(rootFolders.filter { $0.isSystemRoot })
		var userRoots = visibleRootFolders
		guard let idx = userRoots.firstIndex(where: { $0.id == folder.id }),
				idx < userRoots.count - 1 else { return }
		userRoots.remove(at: idx)
		userRoots.insert(folder, at: idx + 1)
		rootFolders = userRoots + systemRoots
		// Persist this order via WorkspaceManager
		onRootFoldersReordered.send(userRoots.map { $0.fullPath })
	}
	
	/// Helper used by expand/collapse "all" operations.
	private func setExpandedStateRecursively(_ folder: FolderViewModel, expanded: Bool) {
		// Recurse into children first so we don't lose references if the parent prunes `subfolders` on collapse.
		var visitedFolderIDs = Set<UUID>()
		var stack: [(FolderViewModel, Bool)] = [(folder, false)]
		while let (current, didVisitChildren) = stack.popLast() {
			if didVisitChildren {
				current.setExpanded(expanded)
				continue
			}
			guard visitedFolderIDs.insert(current.id).inserted else { continue }
			stack.append((current, true))
			let children = current.subfolders
			for sub in children {
				stack.append((sub, false))
			}
		}
	}
	
	
	func refreshRootFolderState() {
		for rootFolder in self.rootFolders {
			_ = self.updateFolderStateRecursive(rootFolder)
		}
	}
	
private func removeEmptyFolders(in folder: FolderViewModel, allowSorting: Bool = true) {
		if !showEmptyFolders {
			let isRoot = rootFolders.contains { $0.id == folder.id }
			let removed = folder.removeEmptyFoldersRecursively(isRoot: isRoot, allowSorting: allowSorting)
			
			// Cancel expansion tracking per removed folder VM *before* removing from index
			for (fullPath, _) in removed {
				let standardizedFull = (fullPath as NSString).standardizingPath
				if let vm = fileHierarchyIndex.foldersByFullPath[standardizedFull] {
					unregisterExpansionTracking(for: vm) // Avoid leaks & stale expansion cache
				}
				fileHierarchyIndex.removeFolder(forKey: standardizedFull, expectedRootKey: folder.rootPath)
			}
		}
	}
	
	func normalizeUserInputPath(_ path: String) -> String {
		let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			return trimmed
		}
		// Expand tilde for home-directory absolute shorthand
		let expanded = (trimmed as NSString).expandingTildeInPath
		// For relative paths, standardize separators, ".", "..", etc.
		return (expanded as NSString).standardizingPath
	}
	
	/// Stable key for root folders/services - avoids URL key instability issues.
	/// Uses pure string normalization to match `FolderViewModel.standardizedFullPath` exactly.
	/// - Expands "~"
	/// - Standardizes ".", "..", duplicate slashes
	/// - Strips trailing "/" (except for "/")
	private func rootKey(forPath path: String) -> RootKey {
		// Use same normalization as standardizedFullPath to ensure key matches
		var trimmed = (normalizeUserInputPath(path) as NSString).standardizingPath
		while trimmed.count > 1 && trimmed.hasSuffix("/") {
			trimmed.removeLast()
		}
		return trimmed
	}
	
	// MARK: - Root Alias Resolution
	
	enum RootAliasResolutionError: LocalizedError, Sendable {
		case issue(PathResolutionIssue)
		
		var errorDescription: String? {
			switch self {
			case .issue(let issue):
				return PathResolutionIssueRenderer.message(for: issue)
			}
		}
	}
	
	enum VisibleAliasResolution: Sendable {
		case notAliasPrefixed
		case resolved(String)
		case ambiguous(alias: String, matchingRoots: [String])
	}
	
	struct VisibleRootSnapshot: Sendable, Hashable {
		let id: UUID
		let name: String
		let fullPath: String
		let standardizedFullPath: String
	}

	struct FolderInputResolution {
		let files: [FileViewModel]
		let handled: Bool
		let displayPath: String?
		let issue: PathResolutionIssue?
	}

	struct ExternalReadableFile: Sendable, Equatable {
		let absolutePath: String
		let displayPath: String
	}

	private struct ExplicitSystemPathResolution {
		let root: FolderViewModel
		let standardizedAbsolutePath: String
		let standardizedRelativePath: String
	}

	enum ReadableFileHandle {
		case workspace(FileViewModel)
		case external(ExternalReadableFile)
	}

	enum RootAliasPrefixCheck: Sendable {
		case notPrefixed
		case uniqueRoot(root: VisibleRootSnapshot, alias: String)
		case ambiguous(alias: String, matchingRoots: [String])
	}
	
	private func visibleWorkspaceRoots() -> [WorkspaceRootRef] {
		visibleRootFolders.map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.fullPath) }
	}

	private func allWorkspaceRoots() -> [WorkspaceRootRef] {
		rootFolders.map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.fullPath) }
	}

	private func supplementalSystemRoots() -> [FolderViewModel] {
		rootFolders.filter(\.isSystemRoot)
	}

	private func gitDataRootFolders() -> [FolderViewModel] {
		supplementalSystemRoots().filter { $0.name == "_git_data" }
	}

	private func roots(in scope: LookupRootScope) -> [FolderViewModel] {
		switch scope {
		case .visibleWorkspace:
			return visibleRootFolders
		case .visibleWorkspacePlusGitData:
			return visibleRootFolders + gitDataRootFolders()
		case .allLoaded:
			return rootFolders
		}
	}

	private func allowedRootPaths(in scope: LookupRootScope) -> Set<String> {
		Set(roots(in: scope).map(\.standardizedFullPath))
	}

	private func lookupRootScope(for profile: PathLocateProfile) -> LookupRootScope {
		switch profile {
		case .mcpRead, .mcpSelection, .mcpSearchScope:
			return .visibleWorkspace
		case .uiAssisted, .moveSourceExact, .createBestEffort, .createRequireUnambiguous:
			return .allLoaded
		}
	}

	private func effectiveLookupRootScope(
		for profile: PathLocateProfile,
		override: LookupRootScope?
	) -> LookupRootScope {
		override ?? lookupRootScope(for: profile)
	}

	private func allowsExplicitSystemPathResolution(for profile: PathLocateProfile) -> Bool {
		switch profile {
		case .mcpSelection:
			return true
		case .mcpRead, .mcpSearchScope, .uiAssisted, .moveSourceExact, .createBestEffort, .createRequireUnambiguous:
			return false
		}
	}
	
	private func visibleRootSnapshot(_ root: WorkspaceRootRef) -> VisibleRootSnapshot {
		VisibleRootSnapshot(
			id: root.id,
			name: root.name,
			fullPath: root.fullPath,
			standardizedFullPath: root.standardizedFullPath
		)
	}
	
	private func workspaceRootRef(for root: FolderViewModel) -> WorkspaceRootRef {
		WorkspaceRootRef(id: root.id, name: root.name, fullPath: root.fullPath)
	}
	
	private func visibleWorkspaceRoot(forStandardizedFullPath path: String) -> WorkspaceRootRef? {
		visibleWorkspaceRoots().first { $0.standardizedFullPath == path }
	}
	
	private func clientDisplayPath(root: WorkspaceRootRef, relativePath: String) -> String {
		ClientPathFormatter.displayPath(root: root, relativePath: relativePath, visibleRoots: visibleWorkspaceRoots())
	}

	@MainActor
	private func resolveExplicitSystemPath(_ userPath: String) -> ExplicitSystemPathResolution? {
		let normalized = normalizeUserInputPath(userPath).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalized.isEmpty else { return nil }
		let standardized = (normalized as NSString).standardizingPath
		let systemRoots = gitDataRootFolders()
		guard !systemRoots.isEmpty else { return nil }

		if standardized.hasPrefix("/") {
			guard let root = systemRoots
				.filter({
					let rootPath = $0.standardizedFullPath
					return standardized == rootPath
						|| standardized.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
				})
				.max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
			else {
				return nil
			}
			return ExplicitSystemPathResolution(
				root: root,
				standardizedAbsolutePath: standardized,
				standardizedRelativePath: RelativePath.fromStandardized(
					standardizedAbsolutePath: standardized,
					standardizedRootPath: root.standardizedFullPath
				)
			)
		}

		let systemRootRefs = systemRoots.map(workspaceRootRef(for:))
		switch WorkspaceAliasResolver.resolve(
			userPath: standardized,
			roots: systemRootRefs,
			options: RootAliasOptions(
				requireRemainder: false,
				allowCompatibilityAlias: true,
				disambiguateRealSubpath: false
			)
		) {
		case .bareRoot(let rootRef, _):
			guard let root = systemRoots.first(where: { $0.id == rootRef.id }) else { return nil }
			return ExplicitSystemPathResolution(
				root: root,
				standardizedAbsolutePath: root.standardizedFullPath,
				standardizedRelativePath: ""
			)
		case .prefixed(let rootRef, _, let remainder):
			guard let root = systemRoots.first(where: { $0.id == rootRef.id }) else { return nil }
			return ExplicitSystemPathResolution(
				root: root,
				standardizedAbsolutePath: StandardizedPath.join(
					standardizedRoot: root.standardizedFullPath,
					standardizedRelativePath: remainder
				),
				standardizedRelativePath: StandardizedPath.relative(remainder)
			)
		case .ambiguous, .notAliasPrefixed:
			return nil
		}
	}

	@MainActor
	private func isExplicitSystemPath(_ userPath: String) -> Bool {
		resolveExplicitSystemPath(userPath) != nil
	}

	@MainActor
	private func explicitSystemPathLocation(_ userPath: String) -> PathLocation? {
		guard let resolution = resolveExplicitSystemPath(userPath),
			  existingItemKind(atAbsolutePath: resolution.standardizedAbsolutePath) != nil else {
			return nil
		}
		return PathLocation(
			rootPath: resolution.root.fullPath,
			correctedPath: resolution.standardizedRelativePath,
			rootIdentifier: resolution.root.id
		)
	}

	@MainActor
	private func resolveExplicitSystemFile(_ userPath: String) -> FileViewModel? {
		guard let resolution = resolveExplicitSystemPath(userPath) else { return nil }
		return fileHierarchyIndex.filesByFullPath[resolution.standardizedAbsolutePath]
	}

	@MainActor
	func mcpDisplayPath(forAbsolutePath path: String) -> String {
		Self.mcpDisplayPath(
			fullPath: path,
			visibleRoots: visibleWorkspaceRoots(),
			allRoots: allWorkspaceRoots()
		)
	}

	@MainActor
	func mcpDisplayPath(for file: FileViewModel) -> String {
		mcpDisplayPath(forAbsolutePath: file.standardizedFullPath)
	}

	@MainActor
	func mcpDisplayPath(for folder: FolderViewModel) -> String {
		mcpDisplayPath(forAbsolutePath: folder.standardizedFullPath)
	}

	@MainActor
	func mcpUnresolvedDisplayPath(for userPath: String) -> String? {
		if let resolution = resolveExplicitSystemPath(userPath) {
			return mcpDisplayPath(forAbsolutePath: resolution.standardizedAbsolutePath)
		}
		return unresolvedWorkspaceDisplayPath(for: userPath)
	}

	nonisolated static func mcpDisplayPath(
		fullPath: String,
		visibleRoots: [WorkspaceRootRef],
		allRoots: [WorkspaceRootRef]
	) -> String {
		let standardized = StandardizedPath.absolute(fullPath)
		let visibleDisplay = ClientPathFormatter.displayAbsolutePath(
			fullPath: standardized,
			visibleRoots: visibleRoots
		)
		if visibleDisplay != standardized {
			return visibleDisplay
		}

		let systemRoots = allRoots.filter { root in
			!visibleRoots.contains(root)
		}
		guard let matchingSystemRoot = systemRoots
			.filter({
				standardized == $0.standardizedFullPath
					|| standardized.hasPrefix($0.standardizedFullPath.hasSuffix("/") ? $0.standardizedFullPath : $0.standardizedFullPath + "/")
			})
			.max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
		else {
			return standardized
		}
		let relative = RelativePath.fromStandardized(
			standardizedAbsolutePath: standardized,
			standardizedRootPath: matchingSystemRoot.standardizedFullPath
		)
		return relative.isEmpty ? matchingSystemRoot.name : "\(matchingSystemRoot.name)/\(relative)"
	}
	
	@MainActor
	func clientDisplayPath(for file: FileViewModel) -> String {
		let root = WorkspaceRootRef(id: file.rootIdentifier, name: file.rootFolderName, fullPath: file.rootFolderPath)
		return clientDisplayPath(root: root, relativePath: file.relativePath)
	}
	
	@MainActor
	func clientDisplayPath(for folder: FolderViewModel) -> String {
		let root = workspaceRootRef(for: folder)
		return clientDisplayPath(root: root, relativePath: folder.relativePath)
	}

	@MainActor
	func unresolvedWorkspaceDisplayPath(for userPath: String) -> String? {
		let trimmedInput = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedInput.isEmpty else { return nil }

		let standardized = (normalizeUserInputPath(trimmedInput) as NSString).standardizingPath
		let roots = visibleWorkspaceRoots()
		guard !roots.isEmpty else { return nil }

		func hasExistingAncestor(relativePath: String, root: WorkspaceRootRef) -> Bool {
			let standardizedRelative = (relativePath as NSString)
				.standardizingPath
				.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
			guard !standardizedRelative.isEmpty else { return true }

			var ancestor = ((standardizedRelative as NSString).deletingLastPathComponent as NSString)
				.standardizingPath
			while !ancestor.isEmpty && ancestor != "." {
				let absolute = ((root.standardizedFullPath as NSString).appendingPathComponent(ancestor) as NSString).standardizingPath
				if findFolderByFullPath(absolute) != nil {
					return true
				}
				ancestor = ((ancestor as NSString).deletingLastPathComponent as NSString).standardizingPath
			}
			return false
		}

		if standardized.hasPrefix("/") {
			guard let root = roots
				.filter({ standardized == $0.standardizedFullPath || standardized.hasPrefix($0.standardizedFullPath.hasSuffix("/") ? $0.standardizedFullPath : $0.standardizedFullPath + "/") })
				.max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
			else {
				return nil
			}
			let relative = RelativePath.fromStandardized(
				standardizedAbsolutePath: standardized,
				standardizedRootPath: root.standardizedFullPath
			)
			return hasExistingAncestor(relativePath: relative, root: root)
				? clientDisplayPath(root: root, relativePath: relative)
				: nil
		}

		switch resolveVisibleRootAlias(standardized, requireRemainder: false, disambiguateRealSubpath: false) {
		case .bareRoot(let root, _):
			return clientDisplayPath(root: root, relativePath: "")
		case .prefixed(let root, _, let remainder):
			return hasExistingAncestor(relativePath: remainder, root: root)
				? clientDisplayPath(root: root, relativePath: remainder)
				: nil
		case .ambiguous, .notAliasPrefixed:
			break
		}

		guard roots.count == 1, let root = roots.first else { return nil }
		return hasExistingAncestor(relativePath: standardized, root: root)
			? clientDisplayPath(root: root, relativePath: standardized)
			: nil
	}

	enum ExactPathLookupKind: Sendable {
		case file
		case folder
		case either
	}
	
	@MainActor
	private func literalRelativeFileMatches(for relativePath: String) -> [FileViewModel] {
		let standardizedRel = (relativePath as NSString).standardizingPath
		return visibleRootFolders.compactMap { root in
			let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(standardizedRel) as NSString).standardizingPath
			return fileHierarchyIndex.filesByFullPath[abs]
		}
	}
	
	@MainActor
	private func literalRelativeFolderMatches(for relativePath: String) -> [FolderViewModel] {
		let standardizedRel = (relativePath as NSString).standardizingPath
		return visibleRootFolders.compactMap { root in
			let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(standardizedRel) as NSString).standardizingPath
			return fileHierarchyIndex.foldersByFullPath[abs]
		}
	}

	@MainActor
	func exactPathResolutionIssue(
		for userPath: String,
		kind: ExactPathLookupKind,
		rootScope: LookupRootScope = .visibleWorkspace
	) -> PathResolutionIssue? {
		let trimmedInput = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedInput.isEmpty else {
			return .emptyInput
		}
		if StandardizedPath.containsNUL(trimmedInput) {
			return .invalidPathCharacters(
				input: trimmedInput,
				reason: "embedded NUL (\\0) characters are not allowed"
			)
		}
		if isExplicitSystemPath(trimmedInput) {
			return nil
		}

		let standardized = (normalizeUserInputPath(trimmedInput) as NSString).standardizingPath
		guard !standardized.hasPrefix("/") else {
			return nil
		}

		let scopedRoots = roots(in: rootScope)
		let roots = scopedRoots.map(workspaceRootRef(for:))
		guard !roots.isEmpty else {
			return nil
		}

		switch WorkspaceAliasResolver.resolve(
			userPath: standardized,
			roots: roots,
			options: RootAliasOptions(
				requireRemainder: false,
				allowCompatibilityAlias: true,
				disambiguateRealSubpath: false
			)
		) {
		case .ambiguous(let alias, let matchingRoots):
			return .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
		case .bareRoot(let root, _):
			switch kind {
			case .folder, .either:
				if visibleRootFolders.contains(where: { $0.id == root.id }) {
					return nil
				}
			case .file:
				break
			}
		case .prefixed(let root, _, let remainder):
			let standardizedRemainder = StandardizedPath.relative(remainder)
			let abs = StandardizedPath.absolute(StandardizedPath.join(
				standardizedRoot: root.standardizedFullPath,
				standardizedRelativePath: standardizedRemainder
			))
			switch kind {
			case .file:
				if findFileByFullPath(abs) != nil { return nil }
			case .folder:
				if findFolderByFullPath(abs) != nil { return nil }
			case .either:
				if findFileByFullPath(abs) != nil || findFolderByFullPath(abs) != nil { return nil }
			}
		case .notAliasPrefixed:
			break
		}

		let relative = StandardizedPath.relative(standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
		guard !relative.isEmpty else {
			return nil
		}

		let matchingRoots = roots.filter { root in
			let abs = StandardizedPath.absolute(StandardizedPath.join(
				standardizedRoot: root.standardizedFullPath,
				standardizedRelativePath: relative
			))
			switch kind {
			case .file:
				return findFileByFullPath(abs) != nil
			case .folder:
				return findFolderByFullPath(abs) != nil
			case .either:
				return findFileByFullPath(abs) != nil || findFolderByFullPath(abs) != nil
			}
		}

		guard matchingRoots.count > 1 else {
			return nil
		}
		return .ambiguousRootMatch(input: trimmedInput, candidateRoots: matchingRoots)
	}
	
	private func resolveVisibleRootAlias(
		_ userPath: String,
		requireRemainder: Bool,
		disambiguateRealSubpath: Bool
	) -> RootAliasResolution {
		WorkspaceAliasResolver.resolve(
			userPath: normalizeUserInputPath(userPath),
			roots: visibleWorkspaceRoots(),
			options: RootAliasOptions(
				requireRemainder: requireRemainder,
				allowCompatibilityAlias: true,
				disambiguateRealSubpath: requireRemainder && disambiguateRealSubpath
			),
			rootHasRealSubpath: { root, alias in
				guard let rootVM = self.visibleRootFolders.first(where: { $0.id == root.id }) else { return false }
				return self.rootHasRealSubfolder(named: alias, under: rootVM)
			}
		)
	}
	
	func checkVisibleRootAliasPrefix(
		_ userPath: String,
		requireRemainder: Bool
	) -> RootAliasPrefixCheck {
		switch resolveVisibleRootAlias(userPath, requireRemainder: requireRemainder, disambiguateRealSubpath: false) {
		case .notAliasPrefixed:
			return .notPrefixed
		case .bareRoot where requireRemainder:
			return .notPrefixed
		case .bareRoot(let root, let alias):
			return .uniqueRoot(root: visibleRootSnapshot(root), alias: alias)
		case .prefixed(let root, let alias, _):
			return .uniqueRoot(root: visibleRootSnapshot(root), alias: alias)
		case .ambiguous(let alias, let matchingRoots):
			return .ambiguous(alias: alias, matchingRoots: matchingRoots.map(\.renderedLabel))
		}
	}
	
	func resolveVisibleAliasPrefixedAbsolutePathResolution(
		_ userPath: String,
		requireRemainder: Bool
	) -> VisibleAliasResolution {
		switch resolveVisibleRootAlias(userPath, requireRemainder: requireRemainder, disambiguateRealSubpath: false) {
		case .notAliasPrefixed, .bareRoot:
			return .notAliasPrefixed
		case .prefixed(let root, _, let remainder):
			let standardizedRemainder = StandardizedPath.relative(remainder)
			let abs = StandardizedPath.absolute(StandardizedPath.join(
				standardizedRoot: root.standardizedFullPath,
				standardizedRelativePath: standardizedRemainder
			))
			return .resolved(abs)
		case .ambiguous(let alias, let matchingRoots):
			return .ambiguous(alias: alias, matchingRoots: matchingRoots.map(\.renderedLabel))
		}
	}
	
	func resolveVisibleAliasPrefixedAbsolutePathIfPossible(
		_ userPath: String,
		requireRemainder: Bool
	) throws -> String? {
		switch resolveVisibleAliasPrefixedAbsolutePathResolution(userPath, requireRemainder: requireRemainder) {
		case .notAliasPrefixed:
			return nil
		case .resolved(let abs):
			return abs
		case .ambiguous(let alias, let matchingRoots):
			let matchingRootsRefs = matchingRoots.compactMap { label in
				visibleWorkspaceRoots().first(where: { $0.renderedLabel == label })
			}
			throw RootAliasResolutionError.issue(.ambiguousAlias(alias: alias, matchingRoots: matchingRootsRefs))
		}
	}
	
	private func findDeepestMatchingSubfolder(_ fullOrRelativePath: String) -> FolderViewModel? {
		let standardizedPath = (fullOrRelativePath as NSString).standardizingPath
		let pathComponents = standardizedPath
			.split(separator: "/")
			.map(String.init)

		var currentFolder: FolderViewModel? = nil
		for root in rootFolders {
			if standardizedPath.hasPrefix(root.standardizedFullPath) || root.name == pathComponents.first {
				currentFolder = root
				break
			}
		}
		
		for component in pathComponents {
			guard let folderSoFar = currentFolder else { break }
			if let childFolder = folderSoFar.children
				.compactMap({ item -> FolderViewModel? in
					if case .folder(let f) = item { return f }
					return nil
				})
				.first(where: { $0.name == component }) {
				currentFolder = childFolder
			} else {
				break
			}
		}
		
		return currentFolder
	}
	
	func applyPresetFileSelections(_ filePaths: [String]) async {
		await clearSelection()
		
		// Use bulk lookup for efficiency
		let fileVMs = await findFiles(atPaths: filePaths)

		// Batch-toggle files in original order with a single flush
		await MainActor.run {
			self.performSelectionBatch {
				for path in filePaths {
					if let fileVM = fileVMs[path], !fileVM.isChecked {
						fileVM.setIsChecked(true)
					}
				}
			}
		}
	}

	func applyWorkspaceState(_ workspace: WorkspaceModel) async {
		// Clear previous expansion state
		for rootFolder in rootFolders {
			rootFolder.collapseRecursively()
		}
		
		// Apply new expansion state
		for folderPath in workspace.workingExpandedFolders {
			if let folderVM = findFolderByFullPath(folderPath) {
				folderVM.setExpanded(true)
			}
		}
		
		
		await clearSelection()
		
		// Use bulk lookup for efficiency
		let fileVMs = await findFiles(atPaths: workspace.workingFilePaths)

		// Batch toggle all target files once
		await MainActor.run {
			self.performSelectionBatch {
				for filePath in workspace.workingFilePaths {
					if let fileVM = fileVMs[filePath], !fileVM.isChecked {
						fileVM.setIsChecked(true)
					}
				}
			}
		}
		refreshRootFolderState()
	}

	func noteFoldersLoaded(paths: [String]) {
		for p in paths {
			loadedRootPaths.insert((p as NSString).standardizingPath)
		}
	}

	func isRootFolderLoaded(_ path: String) -> Bool {
		let stdPath = (path as NSString).standardizingPath
		return loadedRootPaths.contains(stdPath)
	}

	@MainActor
	private func refreshSlicesFromDisk(forRootURL rootURL: URL) async {
		guard let scope = try? currentPartitionScope() else { return }
		let rootPath = StandardizedPath.absolute(rootURL.path)
		let data = await partitionStore.load(forRoot: rootPath, scope: scope)
		if data.files.isEmpty {
			if currentSlicesByRoot.removeValue(forKey: rootPath) != nil {
				requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
			}
			return
		}
		currentSlicesByRoot[rootPath] = data.files
		requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
	}
	
	@MainActor
	private func migrateSlicesForRename(rootPath: String, from oldRelativePath: String, to newRelativePath: String) async {
		guard let scope = try? currentPartitionScope() else { return }
		
		let normalizedRoot = StandardizedPath.absolute(rootPath)
		let normalizedOld = StandardizedPath.relative(oldRelativePath)
		let normalizedNew = StandardizedPath.relative(newRelativePath)
		guard normalizedOld != normalizedNew else { return }
		
	guard let existingEntry = currentSlicesByRoot[normalizedRoot]?[normalizedOld] else { return }
		
		do {
			_ = try await partitionStore.apply(
				forRoot: normalizedRoot,
				scope: scope,
				updates: [normalizedOld: PartitionStore.SliceUpdate(ranges: [], fileModificationTime: existingEntry.fileModificationTime)],
				mode: .remove
			)
			let postAddition = try await partitionStore.apply(
				forRoot: normalizedRoot,
				scope: scope,
				updates: [normalizedNew: PartitionStore.SliceUpdate(ranges: existingEntry.ranges, fileModificationTime: existingEntry.fileModificationTime)],
				mode: .add
			)
			if postAddition.isEmpty {
				currentSlicesByRoot.removeValue(forKey: normalizedRoot)
			} else {
				currentSlicesByRoot[normalizedRoot] = postAddition
			}
			requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
		} catch {
			if Self.isLoggingEnabled {
				print("Failed to migrate selection slices from \(normalizedOld) to \(normalizedNew): \(error)")
			}
		}
	}

	// MARK: - Δ‑set coalescing  (file & folder events)
private func coalesceDeltas(_ deltas: [FileSystemDelta], inRoot standardizedRoot: String? = nil) -> [FileSystemDelta] {
	FileSystemDeltaPreparation.coalesce(deltas, inRoot: standardizedRoot)
}

#if DEBUG
	struct RootReferenceCleanupMetrics: Equatable {
		let totalFolderKeys: Int
		let matchedFolderKeys: Int
		let cleanupCandidateFolderKeys: Int
		let totalFileKeys: Int
		let matchedFileKeys: Int
		let cleanupCandidateFileKeys: Int
		let usedFallbackGlobalScan: Bool
	}

	@MainActor
	func coalesceDeltasForTesting(_ deltas: [FileSystemDelta], inRoot standardizedRoot: String? = nil) -> [FileSystemDelta] {
		coalesceDeltas(deltas, inRoot: standardizedRoot)
	}

	@MainActor
	func rootReferenceCleanupMetricsForTesting(_ folder: FolderViewModel) -> RootReferenceCleanupMetrics {
		let rootPrefix = folder.standardizedFullPath
		let folderKeys = Array(fileHierarchyIndex.foldersByFullPath.keys)
		let fileKeys = Array(fileHierarchyIndex.filesByFullPath.keys)
		let cleanup = rootReferenceCleanupPlan(for: folder)
		return RootReferenceCleanupMetrics(
			totalFolderKeys: folderKeys.count,
			matchedFolderKeys: folderKeys.filter { StandardizedPath.isDescendant($0, of: rootPrefix) }.count,
			cleanupCandidateFolderKeys: cleanup.folderPaths.count,
			totalFileKeys: fileKeys.count,
			matchedFileKeys: fileKeys.filter { StandardizedPath.isDescendant($0, of: rootPrefix) }.count,
			cleanupCandidateFileKeys: cleanup.filePaths.count,
			usedFallbackGlobalScan: cleanup.usedFallbackGlobalScan
		)
	}

	@MainActor
	func latestIndexRebuildPerfSampleForTesting() -> IndexRebuildPerfSample? {
		lastIndexRebuildPerfSample
	}

	@MainActor
	func latestDeltaReplayPerfSampleForTesting() -> DeltaReplayPerfSample? {
		lastDeltaReplayPerfSample
	}

	@MainActor
	func latestImmediateReplayPerfSampleForTesting() -> ImmediateReplayPerfSample? {
		lastImmediateReplayPerfSample
	}

	@MainActor
	func resetReplayPerfSamplesForTesting() {
		lastIndexRebuildPerfSample = nil
		lastDeltaReplayPerfSample = nil
		lastImmediateReplayPerfSample = nil
		currentRootReplayPerfSample = nil
		pendingInsertFlushInvocationPerfSamples.removeAll(keepingCapacity: true)
	}

	@MainActor
	func setScheduledInsertFlushSuppressedForTesting(_ suppressed: Bool) {
		isScheduledInsertFlushSuppressedForTesting = suppressed
	}

	@MainActor
	func setDetailedReplayWallAttributionEnabledForTesting(_ enabled: Bool) {
		isDetailedReplayWallAttributionEnabledForTesting = enabled
	}

	@MainActor
	func seedSelectionSlicesForTesting(_ ranges: [LineRange], for file: FileViewModel) {
		selectionSlicesByFileID[file.id] = ranges
	}

	@MainActor
	func setDeltaReplayTuningForTesting(
		chunkSize: Int?,
		interChunkDelayNanoseconds: UInt64?
	) {
		deltaReplayChunkSizeOverride = chunkSize
		deltaReplayInterChunkDelayNanosecondsOverride = interChunkDelayNanoseconds
		let deferredReplayBuffer = self.deferredReplayBuffer
		Task {
			await deferredReplayBuffer.updateImmediateReplayChunkSizeOverride(chunkSize)
		}
	}

	@MainActor
	func registerRootFolderForTesting(_ folder: FolderViewModel, service: FileSystemService? = nil) {
		if !rootFolders.contains(where: { $0.id == folder.id }) {
			addRootFolder(folder)
		}
		if let service {
			let rootKey = folder.standardizedFullPath
			let shouldRegisterReplayIngress = fileSystemServices[rootKey] == nil
			fileSystemServices[rootKey] = service
			if shouldRegisterReplayIngress {
				let replayIngressGeneration = advanceRootReplayIngressGeneration(forRootKey: rootKey)
				let deferredReplayBuffer = self.deferredReplayBuffer
				Task {
					await deferredReplayBuffer.registerActiveRootGeneration(replayIngressGeneration, forRootKey: rootKey)
				}
			}
		}
		rebuildFileHierarchyIndex(for: folder)
	}

	@MainActor
	@discardableResult
	func ensureReplayIngressRegistrationForTesting(forRootFolder folder: FolderViewModel) async -> UInt64 {
		let rootKey = folder.standardizedFullPath
		let generation = currentRootReplayIngressGeneration(forRootKey: rootKey)
			?? advanceRootReplayIngressGeneration(forRootKey: rootKey)
		await deferredReplayBuffer.registerActiveRootGeneration(generation, forRootKey: rootKey)
		return generation
	}

	@MainActor
	func connectRegisteredFileSystemServicePublisherForTesting(forRootFolder folder: FolderViewModel) async {
		let rootKey = folder.standardizedFullPath
		guard let service = fileSystemServices[rootKey] else { return }
		let rootReplayIngressGeneration = await ensureReplayIngressRegistrationForTesting(forRootFolder: folder)
		let changesPublisher = await service.publisherForChanges()
		watchers[rootKey]?.cancel()
		watchers[rootKey] = makeFileSystemChangesCancellable(
			changesPublisher: changesPublisher,
			rootKey: rootKey,
			rootReplayIngressGeneration: rootReplayIngressGeneration
		)
	}

	@MainActor
	func receiveWatcherFileSystemDeltasForTesting(
		_ deltas: [FileSystemDelta],
		forRootFolder folder: FolderViewModel,
		capturedGeneration: UInt64
	) async {
		let ingress = await deferredReplayBuffer.ingestLiveDeltas(
			deltas,
			forRootKey: folder.standardizedFullPath,
			rootGeneration: capturedGeneration
		)
		await handleDeferredReplayIngressResult(ingress)
	}

	@MainActor
	func injectIndexedFileForTesting(_ file: FileViewModel) {
		fileHierarchyIndex.insertFile(file, rootKey: file.standardizedRootFolderPath)
	}

	/// Attach the selection callback and toggle a file into `selectedFiles`
	/// through the normal commit path. Mirrors what `attachSelectionCallback`
	/// does for fresh view models so tests can exercise code paths that read
	/// `selectedFiles` (e.g. Agent Mode file-tag suggestions).
	@MainActor
	func selectFileForTesting(_ file: FileViewModel) {
		file.onCheckStateChanged = { [weak self] changed, isChecked in
			self?.handleCheckStateChanged(changed, isChecked: isChecked)
		}
		setFileToggled(file, isToggled: true)
	}

	@MainActor
	func applyBatchCodeMapResultsForTesting(_ batch: [CodeScanActor.ScanResult]) {
		applyBatchCodeMapResults(batch)
	}

	@MainActor
	func cachedCodeMapAPIForTesting(fullPath: String) -> FileAPI? {
		codemapCapableAPIsByFullPath[StandardizedPath.absolute(fullPath)]
	}

	@MainActor
	func seedCachedCodeMapAPIForTesting(fullPath: String, api: FileAPI) {
		codemapCapableAPIsByFullPath[StandardizedPath.absolute(fullPath)] = api
	}

	@MainActor
	func enqueuePendingDeltasForTesting(_ deltas: [FileSystemDelta], forRootFolder folder: FolderViewModel) async {
		_ = await ensureReplayIngressRegistrationForTesting(forRootFolder: folder)
		_ = await deferredReplayBuffer.enqueueDeferredDeltas(deltas, forRootKey: folder.standardizedFullPath)
	}

	@MainActor
	func applyFileSystemDeltasForTesting(
		_ deltas: [FileSystemDelta],
		forRootFolder folder: FolderViewModel
	) async {
		await applyFileSystemDeltas(
			deltas,
			forRootKey: folder.standardizedFullPath,
			deferIfUnfocused: false
		)
	}

	@MainActor
	func applyPreparedDeltasWithoutCoalescingForTesting(
		_ deltas: [FileSystemDelta],
		forRootFolder folder: FolderViewModel,
		chunkSize: Int? = nil
	) async {
		let rootKey = folder.standardizedFullPath
		let preparedDeltas = deltas.compactMap { FileSystemDeltaPreparation.prepare($0, inRoot: rootKey) }
		let effectiveChunkSize = max(chunkSize ?? max(preparedDeltas.count, 1), 1)
		let chunks: [PreparedFileSystemReplayChunk] = stride(from: 0, to: preparedDeltas.count, by: effectiveChunkSize).map { start in
			let end = min(start + effectiveChunkSize, preparedDeltas.count)
			let range = start..<end
			var summary = PreparedFileSystemReplayChunkSummary()
			for prepared in preparedDeltas[range] {
				switch prepared.delta {
				case .fileAdded:
					summary.fileAddedCount += 1
				case .fileRemoved:
					summary.fileRemovedCount += 1
				case .folderAdded:
					summary.folderAddedCount += 1
				case .folderRemoved:
					summary.folderRemovedCount += 1
				case .fileModified:
					summary.fileModifiedCount += 1
				case .folderModified:
					summary.folderModifiedCount += 1
				}
			}
			return PreparedFileSystemReplayChunk(
				range: range,
				deltaCount: range.count,
				summary: summary,
				renameTransfers: []
			)
		}
		let batch = PreparedFileSystemReplayBatch(
			rootKey: rootKey,
			queuedDeltaCount: deltas.count,
			coalescedDeltaCount: deltas.count,
			preparedDeltas: preparedDeltas,
			chunks: chunks,
			coalesceDurationMS: 0,
			preparationDurationMS: 0
		)
		await applyPreparedReplayBatch(batch, passIndex: 0)
	}

	@MainActor
	func receiveLiveFileSystemDeltasForTesting(
		_ deltas: [FileSystemDelta],
		forRootFolder folder: FolderViewModel
	) async {
		await applyFileSystemDeltas(
			deltas,
			forRootKey: folder.standardizedFullPath,
			deferIfUnfocused: true
		)
	}

	@MainActor
	func pendingDeltaCountForTesting(forRootFolder folder: FolderViewModel) async -> Int {
		await deferredReplayBuffer.pendingDeltaCount(forRootKey: folder.standardizedFullPath)
	}

	@MainActor
	func setWindowFocusedForTesting(_ focused: Bool) async {
		isWindowFocused = focused
		let routingVersion = advanceDeferredReplayRoutingVersion()
		await deferredReplayBuffer.updateRoutingState(
			isWindowFocused: focused,
			isReplayActive: isReplayingDeltas,
			routingVersion: routingVersion
		)
		if focused {
			await flushPendingDeltas()
		}
	}

	#if DEBUG
	@MainActor
	func deferredReplayBufferDiagnosticsForTesting() async -> DeferredReplayBufferDiagnostics {
		await deferredReplayBuffer.diagnosticsSnapshot()
	}

	@MainActor
	func debugCodemapMemoryCounters() async -> CodeScanActor.CodemapMemoryCounters {
		await codeScanActor.codemapMemoryCounters()
	}
	#endif

	@MainActor
	func waitForDeltaReplayCompletionForTesting() async {
		while true {
			if let task = deltaReplayTask {
				await task.value
				continue
			}
			if !(await deferredReplayBuffer.hasPendingWork()) && !isReplayingDeltas {
				return
			}
			await Task.yield()
		}
	}
#endif
	// Bulk select operation - explicitly @MainActor for consistency with deselectFiles
	// and to ensure selectedFiles mutations are always on the main thread
	@MainActor
	func selectFiles(withPaths paths: [String], allowEmpty: Bool = false, clear: Bool = true) async {
		if (paths.isEmpty && !allowEmpty) {
			return
		}
		
		if(clear) {
			// Clear the current file selection
			await clearSelection()
		}
		
		// Normalize all paths using the unified helper (keeps absolute paths absolute)
		let normalizedPaths = paths.map { normalizeUserInputPath($0) }
		
		// Use bulk lookup for efficiency
		let foundFiles = await findFiles(atPaths: normalizedPaths)
		
		// Batch all additions (already on MainActor, no need to hop)
		performSelectionBatch {
			for (_, fileVM) in foundFiles {
				if !fileVM.isChecked {
					fileVM.setIsChecked(true)
				}
			}
		}
		
		// NEW: recompute only branches touched by this batch
		let parentFolders = Array(Set(foundFiles.values.compactMap { $0.parentFolder }))
		for parent in parentFolders {
			recomputeAncestorStates(startingAt: parent)
		}
	}
	
	// Bulk deselect operation that mirrors selectFiles
	@MainActor
	func deselectFiles(withPaths paths: [String]) async {
		guard !paths.isEmpty else { return }

		// Normalize all paths using the unified helper (keeps absolute paths absolute)
		let normalizedPaths = paths.map { normalizeUserInputPath($0) }

		// Resolve to FileViewModels in bulk
		let foundFiles = await findFiles(atPaths: normalizedPaths)

		// Batch all deselections into a single mutation & cache update (already on MainActor)
		performSelectionBatch {
			for (_, fileVM) in foundFiles {
				if fileVM.isChecked {
					fileVM.setIsChecked(false)
				}
			}
		}

		// Recompute only affected ancestors (O(depth) each)
		var seen = Set<UUID>()
		for fileVM in foundFiles.values {
			if let parent = fileVM.parentFolder, seen.insert(parent.id).inserted {
				recomputeAncestorStates(startingAt: parent)
			}
		}
	}
	
	private var codeScanEnabled = true
	
	// Add at the class level in RepoFileManagerViewModel
	private var codeScanTasks: [UUID: Task<Void, Never>] = [:]
	private var currentBatchScanTask: Task<Void, Never>? = nil
	
	// NEW: holds the most recent ad-hoc "enqueue scans for files" task
	private var currentAdhocScanEnqueueTask: Task<Void, Never>? = nil
	private var replayScanEnqueueTasks: [UUID: Task<Void, Never>] = [:]
	
	@MainActor private var cachedSearchFolderSuffixIndexByScope: [LookupRootScope: (generation: UInt64, index: SearchFolderSuffixIndex<FolderViewModel>)] = [:]
	
	private struct InitialRootEnqueueTask {
		let id: UUID
		let task: Task<Void, Never>
	}
	
	// NEW: per-root initial-load enqueue tasks (avoid cross-root cancellation)
	private var initialRootScanEnqueueTasks: [String: InitialRootEnqueueTask] = [:]
	
	private struct ScanSnapshot: Sendable {
		let id: UUID
		let mod: Date
		let ext: String
		let rel: String
		let full: String
		let root: String
		let cachedContent: String?
		let cachedContentIsFresh: Bool
	}

	private static let codemapSnapshotFanoutLimit = 128
	private static let codemapContentLoadFanoutLimit = 16
	
	/// Cancels any currently queued/active scans in the actor, plus any local tasks
	public func setCodeScanEnabled(_ isEnabled: Bool) async {
		let wasEnabled = codeScanEnabled
		codeScanEnabled = isEnabled
		if !wasEnabled && isEnabled {
			// Just got enabled, rescan if needed
			await rescanAllFilesIfLoaded()
		} else if !isEnabled {
			// Disabled state should always perform comprehensive VM-level cancellation,
			// even if callers repeat the request while already disabled.
			await cancelAllScans()
		}
	}

    // ------------------------------------------------------------------
    // MARK: Unified bulk path selection helpers (files and folders)
    // ------------------------------------------------------------------

	/// Convert absolute path to the canonical client-facing workspace path.
	private func toAliasPrefixedPath(_ absPath: String) -> String? {
		let stdPath = (absPath as NSString).standardizingPath
		guard let root = visibleWorkspaceRoots()
			.filter({
				let rootPath = $0.standardizedFullPath
				return stdPath == rootPath || stdPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
			})
			.max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count }) else {
			return nil
		}
		let relative = String(stdPath.dropFirst(root.standardizedFullPath.count))
			.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		return clientDisplayPath(root: root, relativePath: relative)
	}
	
	struct SelectionResult {
		let addedFiles: [String]      // Alias-prefixed relative paths of added files (e.g., "RootName/path/to/file")
		let removedFiles: [String]    // Alias-prefixed relative paths of removed files (e.g., "RootName/path/to/file")
		let invalidPaths: [String]    // User input paths that couldn't be resolved
		let resolvedMap: [String: String]  // Map from user input to resolved path
	}
	
	struct SelectionSliceInput: Sendable {
		let path: String
		let ranges: [LineRange]
	}
	
	struct SelectionSlicesMutationResult {
		let invalidPaths: [String]
		let resolvedMap: [String: String]
		let snapshot: [UUID: [LineRange]]
	}

	private struct SliceMutationPayload {
		let file: FileViewModel
		let relativePath: String
		let ranges: [LineRange]
		let modificationTime: Double
	}
	
	enum SelectionSliceError: LocalizedError {
		case workspaceUnavailable
		case noWorkspaceLoaded
		
		var errorDescription: String? {
			switch self {
			case .workspaceUnavailable:
				return "Workspace context unavailable – cannot persist selection slices."
			case .noWorkspaceLoaded:
				return "No workspace folders are currently loaded."
			}
		}
	}
	
	private func currentPartitionScope() throws -> PartitionScope {
		guard let workspaceID = currentWorkspaceID else {
			throw SelectionSliceError.workspaceUnavailable
		}
		return PartitionScope(workspaceID: workspaceID, tabID: currentTabID)
	}

    /// Bulk select by resolving input paths (files or folders), supporting
    /// relative or absolute inputs. Fuzzy matches are allowed when `exact=false`.
    /// - Parameters:
    ///   - paths: Input file and/or folder paths (relative or absolute)
    ///   - clear: If true, clears current selection before applying additions
    ///   - expandFolders: When true, expands matched folders to all descendant files
    ///   - exact: When true, bypass fuzzy matching for strict selection
    @MainActor
    func selectPaths(
        withPaths paths: [String],
        clear: Bool = false,
        expandFolders: Bool = true,
        exact: Bool = false
    ) async -> SelectionResult {
        let normInputs = paths
            .map { normalizeUserInputPath($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var resolvedFiles: [FileViewModel] = []
		var resolvedMap: [String: String] = [:]
        var invalid: [String] = []
		var issuesByInput: [String: PathResolutionIssue] = [:]

		let candidateInputs = normInputs.filter { input in
			if let issue = exactPathResolutionIssue(for: input, kind: .either) {
				issuesByInput[input] = issue
				return false
			}
			return true
		}

		let fileHits = await findFiles(atPaths: candidateInputs, profile: .mcpSelection)
        var satisfiedInputs = Set<String>(fileHits.keys)
        resolvedFiles.append(contentsOf: fileHits.values)
		for (inp, vm) in fileHits {
			resolvedMap[inp] = mcpDisplayPath(for: vm)
		}

		let remaining = candidateInputs.filter { !satisfiedInputs.contains($0) }
        var matchedFolders: [FolderViewModel] = []
        var folderResolvedInputs: [String: FolderViewModel] = [:]
        for p in remaining {
			let resolution = resolveFolderInput(p)
			if let folder = resolution.folder {
                matchedFolders.append(folder)
                folderResolvedInputs[p] = folder
			} else if let issue = resolution.issue {
				issuesByInput[p] = issue
            }
        }

        if !exact {
			let unresolved = remaining.filter { folderResolvedInputs[$0] == nil && issuesByInput[$0] == nil }
            if !unresolved.isEmpty {
                let (staticData, selectedPaths, selectionSig) = currentStaticPathMatchContext(scope: .visibleWorkspace)
                for raw in unresolved {
                    if let loc = await pathMatchWorker.locate(
                        userPath: raw,
						profile: .mcpSelection,
                        staticData: staticData,
                        selectedFileFullPaths: selectedPaths,
                        selectionSig: selectionSig
                    ) {
                        if let folder = resolveFolder(rootPath: loc.rootPath, correctedPath: loc.correctedPath) {
                            matchedFolders.append(folder)
                            folderResolvedInputs[raw] = folder
                        } else if let file = resolveFile(rootPath: loc.rootPath, correctedPath: loc.correctedPath) {
                            resolvedFiles.append(file)
							resolvedMap[raw] = mcpDisplayPath(for: file)
                            satisfiedInputs.insert(raw)
                        }
                    }
                }
            }
        }

        if expandFolders && !matchedFolders.isEmpty {
			for folder in matchedFolders {
				resolvedFiles.append(contentsOf: getFilesRecursively(under: folder))
            }
            for (inp, folder) in folderResolvedInputs {
				resolvedMap[inp] = mcpDisplayPath(for: folder)
                satisfiedInputs.insert(inp)
            }
        }

        for p in normInputs where !satisfiedInputs.contains(p) && folderResolvedInputs[p] == nil {
			if let issue = issuesByInput[p] {
				invalid.append(PathResolutionIssueRenderer.message(for: issue))
			} else {
				invalid.append(p)
			}
        }

        let beforeSelectedIDs = Set(selectedFiles.map { $0.id })

        if clear {
            await clearSelection()
        }

        await MainActor.run {
            self.performSelectionBatch {
				for file in resolvedFiles where !file.isChecked {
					file.setIsChecked(true)
                }
            }
        }

        let parentFolders = Array(Set(resolvedFiles.compactMap { $0.parentFolder }))
        for parent in parentFolders {
            recomputeAncestorStates(startingAt: parent)
        }

        let afterSelectedIDs = Set(selectedFiles.map { $0.id })
        let addedIDs = afterSelectedIDs.subtracting(beforeSelectedIDs)
		let addedAbsPaths = selectedFiles
			.filter { addedIDs.contains($0.id) }
			.map(\.standardizedFullPath)
		let addedPaths = addedAbsPaths.compactMap { toAliasPrefixedPath($0) }

        return SelectionResult(
            addedFiles: addedPaths,
            removedFiles: [],
            invalidPaths: invalid,
            resolvedMap: resolvedMap
        )
    }

    /// Bulk deselect by resolving input paths (files or folders), supporting
    /// relative or absolute inputs. Fuzzy matches are allowed when `exact=false`.
    @MainActor
    func deselectPaths(
        withPaths paths: [String],
        expandFolders: Bool = true,
        exact: Bool = false
    ) async -> SelectionResult {
        let normInputs = paths
            .map { normalizeUserInputPath($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var resolvedFiles: [FileViewModel] = []
        var resolvedMap: [String: String] = [:]
        var invalid: [String] = []
		var issuesByInput: [String: PathResolutionIssue] = [:]

		let candidateInputs = normInputs.filter { input in
			if let issue = exactPathResolutionIssue(for: input, kind: .either) {
				issuesByInput[input] = issue
				return false
			}
			return true
		}

		let fileHits = await findFiles(atPaths: candidateInputs, profile: .mcpSelection)
        var satisfiedInputs = Set<String>(fileHits.keys)
        resolvedFiles.append(contentsOf: fileHits.values)
		for (inp, vm) in fileHits {
			resolvedMap[inp] = mcpDisplayPath(for: vm)
		}

		let remaining = candidateInputs.filter { !satisfiedInputs.contains($0) }
        var matchedFolders: [FolderViewModel] = []
        var folderResolvedInputs: [String: FolderViewModel] = [:]
        for p in remaining {
			let resolution = resolveFolderInput(p)
			if let folder = resolution.folder {
                matchedFolders.append(folder)
                folderResolvedInputs[p] = folder
			} else if let issue = resolution.issue {
				issuesByInput[p] = issue
            }
        }

        if !exact {
			let unresolved = remaining.filter { folderResolvedInputs[$0] == nil && issuesByInput[$0] == nil }
            if !unresolved.isEmpty {
                let (staticData, selectedPaths, selectionSig) = currentStaticPathMatchContext(scope: .visibleWorkspace)
                for raw in unresolved {
                    if let loc = await pathMatchWorker.locate(
                        userPath: raw,
						profile: .mcpSelection,
                        staticData: staticData,
                        selectedFileFullPaths: selectedPaths,
                        selectionSig: selectionSig
                    ) {
                        if let folder = resolveFolder(rootPath: loc.rootPath, correctedPath: loc.correctedPath) {
                            matchedFolders.append(folder)
                            folderResolvedInputs[raw] = folder
                        } else if let file = resolveFile(rootPath: loc.rootPath, correctedPath: loc.correctedPath) {
                            resolvedFiles.append(file)
							resolvedMap[raw] = mcpDisplayPath(for: file)
                            satisfiedInputs.insert(raw)
                        }
                    }
                }
            }
        }

        if expandFolders && !matchedFolders.isEmpty {
			for folder in matchedFolders {
				resolvedFiles.append(contentsOf: getFilesRecursively(under: folder))
            }
            for (inp, folder) in folderResolvedInputs {
				resolvedMap[inp] = mcpDisplayPath(for: folder)
                satisfiedInputs.insert(inp)
            }
        }

        for p in normInputs where !satisfiedInputs.contains(p) && folderResolvedInputs[p] == nil {
			if let issue = issuesByInput[p] {
				invalid.append(PathResolutionIssueRenderer.message(for: issue))
			} else {
				invalid.append(p)
			}
        }

        let beforeSelectedIDs = Set(selectedFiles.map { $0.id })
		let beforeAbs: [UUID: String] = {
			var m: [UUID: String] = [:]
			for f in selectedFiles {
				m[f.id] = f.standardizedFullPath
			}
			return m
		}()

        await MainActor.run {
            self.performSelectionBatch {
				for file in resolvedFiles where file.isChecked {
					file.setIsChecked(false)
                }
            }
        }

        var seen = Set<UUID>()
        for file in resolvedFiles {
            if let parent = file.parentFolder, seen.insert(parent.id).inserted {
                recomputeAncestorStates(startingAt: parent)
            }
        }

        let afterSelectedIDs = Set(selectedFiles.map { $0.id })
        let removedIDs = beforeSelectedIDs.subtracting(afterSelectedIDs)
		let removedAbsPaths = removedIDs.compactMap { beforeAbs[$0] }
		let removedPaths = removedAbsPaths.compactMap { toAliasPrefixedPath($0) }

		return SelectionResult(
			addedFiles: [],
			removedFiles: removedPaths,
			invalidPaths: invalid,
			resolvedMap: resolvedMap
		)
	}
	
	private struct SliceHydrationMetadata: Sendable {
		let rootKey: String
		let relativeKey: String
		let ranges: [LineRange]
		let modificationTime: Double
	}

	private func standardizedStoredSelectionPath(_ path: String) -> String {
		StandardizedPath.absolute(path)
	}

	private func standardizedStoredSelectionPaths(_ paths: [String]) -> [String] {
		paths.map(standardizedStoredSelectionPath)
	}

	/// Normalizes persisted slice keys once at ingestion so downstream consumers stay on the
	/// canonical fast path. If legacy data contains both canonical and non-canonical keys for
	/// the same file, the canonical key wins; multiple non-canonical variants are merged.
	private func standardizedStoredSelectionSlices(_ slices: [String: [LineRange]]) -> [String: [LineRange]] {
		guard !slices.isEmpty else { return [:] }

		var canonical: [String: [LineRange]] = [:]
		var legacyFallbacks: [String: [LineRange]] = [:]

		for (path, ranges) in slices where !ranges.isEmpty {
			let standardized = standardizedStoredSelectionPath(path)
			if path == standardized {
				canonical[standardized] = ranges
				continue
			}

			if var existing = legacyFallbacks[standardized] {
				existing.append(contentsOf: ranges)
				legacyFallbacks[standardized] = SliceRangeMath.normalize(existing)
			} else {
				legacyFallbacks[standardized] = ranges
			}
		}

		for (path, ranges) in legacyFallbacks where canonical[path] == nil {
			canonical[path] = ranges
		}
		return canonical
	}

	private func standardizedAPIFilePath(_ api: FileAPI) -> String {
		StandardizedPath.absolute(api.filePath)
	}

	@MainActor
	func hydrateSlicesForActiveTab(from tabSelection: StoredSelection) async {
		#if DEBUG
		let hydrateSlicesStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		var hydrateSlicesOutcome = "completed"
		var hydrateSlicesRootCount = rootFolders.count
		var hydrateSlicesRequestedFiles = tabSelection.slices.count
		var hydrateSlicesResolvedFiles = 0
		var hydrateSlicesLoadedPartitionFiles = 0
		var hydrateSlicesPendingPersistRoots = 0
		var hydrateSlicesPendingPersistFiles = 0
		defer {
			WorkspaceRestorePerfLog.event(
				"selection.hydrateSlices",
				fields: [
					"rootCount": "\(hydrateSlicesRootCount)",
					"requestedSliceFiles": "\(hydrateSlicesRequestedFiles)",
					"resolvedSliceFiles": "\(hydrateSlicesResolvedFiles)",
					"loadedPartitionFiles": "\(hydrateSlicesLoadedPartitionFiles)",
					"pendingPersistRoots": "\(hydrateSlicesPendingPersistRoots)",
					"pendingPersistFiles": "\(hydrateSlicesPendingPersistFiles)",
					"outcome": hydrateSlicesOutcome,
					"duration": hydrateSlicesStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
		}
		#endif
		guard !rootFolders.isEmpty else {
			#if DEBUG
			hydrateSlicesOutcome = "noRoots"
			#endif
			currentSlicesByRoot.removeAll()
			requestSelectionSliceSnapshotRebuild(reason: "hydrateSlices.noRoots")
			return
		}

		guard let scope = try? currentPartitionScope() else {
			#if DEBUG
			hydrateSlicesOutcome = "noScope"
			#endif
			currentSlicesByRoot.removeAll()
			requestSelectionSliceSnapshotRebuild(reason: "hydrateSlices.noScope")
			return
		}

		let rootPaths = rootFolders.map(\.standardizedFullPath)
		#if DEBUG
		hydrateSlicesRootCount = rootPaths.count
		#endif
		let normalizedSlices = standardizedStoredSelectionSlices(tabSelection.slices)
		let sliceMetadata: [SliceHydrationMetadata] = normalizedSlices.compactMap { entry in
			let standardizedFull = entry.key
			guard let vm = fileHierarchyIndex.filesByFullPath[standardizedFull] else { return nil }
			let rootKey = vm.standardizedRootFolderPath
			let relKey = vm.standardizedRelativePath
			let normalized = SliceRangeMath.normalize(entry.value)
			return SliceHydrationMetadata(
				rootKey: rootKey,
				relativeKey: relKey,
				ranges: normalized,
				modificationTime: vm.modificationDate.timeIntervalSince1970
			)
		}
		#if DEBUG
		hydrateSlicesResolvedFiles = sliceMetadata.count
		#endif

		let partitionStore = self.partitionStore
		let loadTask = Task.detached(priority: .utility) { () -> (
			[String: [String: PartitionStore.StoredSlices]],
			[String: [String: PartitionStore.SliceUpdate]]
		) in
			var next: [String: [String: PartitionStore.StoredSlices]] = [:]
			var loadedByRoot: [String: [String: PartitionStore.StoredSlices]] = [:]

			for rootPath in rootPaths {
				let data = await partitionStore.load(forRoot: rootPath, scope: scope)
				next[rootPath] = data.files
				loadedByRoot[rootPath] = data.files
			}

			var toPersist: [String: [String: PartitionStore.SliceUpdate]] = [:]
			let desiredByRoot = Dictionary(grouping: sliceMetadata, by: \.rootKey)

			for rootPath in rootPaths {
				let desiredRoot = Dictionary(
					uniqueKeysWithValues: (desiredByRoot[rootPath] ?? []).map { ($0.relativeKey, $0) }
				)
				let existingRoot = loadedByRoot[rootPath] ?? [:]

				for relativeKey in existingRoot.keys where desiredRoot[relativeKey] == nil {
					var stored = next[rootPath] ?? [:]
					stored.removeValue(forKey: relativeKey)
					next[rootPath] = stored

					var updates = toPersist[rootPath] ?? [:]
					updates[relativeKey] = PartitionStore.SliceUpdate(
						ranges: [],
						fileModificationTime: nil,
						anchors: []
					)
					toPersist[rootPath] = updates
				}

				for payload in desiredRoot.values {
					guard !payload.ranges.isEmpty else { continue }

					let existing = existingRoot[payload.relativeKey]
					let existingRanges = existing.map { SliceRangeMath.normalize($0.ranges) } ?? []
					let shouldInsert = existing == nil
					let shouldReplace = existing != nil && existingRanges != payload.ranges
					guard shouldInsert || shouldReplace else { continue }

					var stored = next[rootPath] ?? [:]
					stored[payload.relativeKey] = PartitionStore.StoredSlices(
						ranges: payload.ranges,
						fileModificationTime: payload.modificationTime,
						anchors: shouldReplace ? nil : existing?.anchors
					)
					next[rootPath] = stored

					var updates = toPersist[rootPath] ?? [:]
					updates[payload.relativeKey] = PartitionStore.SliceUpdate(
						ranges: payload.ranges,
						fileModificationTime: payload.modificationTime,
						anchors: shouldReplace ? [] : nil
					)
					toPersist[rootPath] = updates
				}
			}
			return (next, toPersist)
		}

		let (snapshot, pendingPersist) = await loadTask.value
		#if DEBUG
		hydrateSlicesLoadedPartitionFiles = snapshot.values.reduce(0) { $0 + $1.count }
		hydrateSlicesPendingPersistRoots = pendingPersist.count
		hydrateSlicesPendingPersistFiles = pendingPersist.values.reduce(0) { $0 + $1.count }
		#endif

		guard !Task.isCancelled else {
			#if DEBUG
			hydrateSlicesOutcome = "cancelled"
			#endif
			return
		}
		guard currentTabID == scope.tabID else {
			#if DEBUG
			hydrateSlicesOutcome = "staleTab"
			#endif
			return
		}

		await applySlicesSnapshot(snapshot: snapshot, pendingPersist: pendingPersist, scope: scope)
	}

	@MainActor
	private func applySlicesSnapshot(
		snapshot: [String: [String: PartitionStore.StoredSlices]],
		pendingPersist: [String: [String: PartitionStore.SliceUpdate]],
		scope: PartitionScope
	) async {
		#if DEBUG
		let applySlicesSnapshotStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		defer {
			WorkspaceRestorePerfLog.event(
				"selection.applySlicesSnapshot",
				fields: [
					"rootCount": "\(snapshot.count)",
					"snapshotFiles": "\(snapshot.values.reduce(0) { $0 + $1.count })",
					"pendingPersistRoots": "\(pendingPersist.count)",
					"pendingPersistFiles": "\(pendingPersist.values.reduce(0) { $0 + $1.count })",
					"duration": applySlicesSnapshotStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
		}
		#endif
		currentSlicesByRoot = snapshot
		requestSelectionSliceSnapshotRebuild(reason: "applySlicesSnapshot")

		guard !pendingPersist.isEmpty else { return }

		for (rootPath, updates) in pendingPersist {
			do {
				_ = try await partitionStore.apply(
					forRoot: rootPath,
					scope: scope,
					updates: updates,
					mode: .setPaths
				)
			} catch {
				if Self.isLoggingEnabled {
					print("Failed to persist slices during hydrate for root \(rootPath): \(error)")
				}
			}
		}
	}

	private static let sliceTimestampTolerance: Double = 0.000_5
	
	@MainActor
	func onActiveTabChangedFast(_ tab: ComposeTabState) {
		#if DEBUG
		let activeTabFastStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		#endif
		setActiveTabID(tab.id)
		selectionSlicesByFileID.removeAll()
		requestSelectionSliceSnapshotRebuild(reason: "activeTabChanged.fast")
		#if DEBUG
		WorkspaceRestorePerfLog.event(
			"selection.activeTabChanged.fast",
			fields: [
				"tabID": WorkspaceRestorePerfLog.shortID(tab.id),
				"duration": activeTabFastStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
			]
		)
		#endif
	}

	@MainActor
	func onActiveTabChangedHeavy(
		for tabID: UUID,
		selection: StoredSelection
	) async {
		#if DEBUG
		let activeTabHeavyStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		var activeTabHeavyOutcome = "completed"
		defer {
			WorkspaceRestorePerfLog.event(
				"selection.activeTabChanged.heavy",
				fields: [
					"tabID": WorkspaceRestorePerfLog.shortID(tabID),
					"selectedPaths": "\(selection.selectedPaths.count)",
					"sliceFiles": "\(selection.slices.count)",
					"outcome": activeTabHeavyOutcome,
					"duration": activeTabHeavyStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
		}
		#endif
		guard currentTabID == tabID else {
			#if DEBUG
			activeTabHeavyOutcome = "staleTab"
			#endif
			return
		}
		await applyStoredSelection(selection)
		guard !Task.isCancelled else {
			#if DEBUG
			activeTabHeavyOutcome = "cancelled"
			#endif
			return
		}
		guard currentTabID == tabID else {
			#if DEBUG
			activeTabHeavyOutcome = "staleTab"
			#endif
			return
		}
		await hydrateSlicesForActiveTab(from: selection)
	}

	@MainActor
	func onActiveTabChanged(_ tab: ComposeTabState) async {
		onActiveTabChangedFast(tab)
		await onActiveTabChangedHeavy(for: tab.id, selection: tab.selection)
	}

	@MainActor
	private func sliceAnchorContent(for file: FileViewModel) async -> String? {
		let snapshot = await file.cachedContentSnapshot()
		if let content = snapshot.content {
			return content
		}

		let rootKey = file.standardizedRootFolderPath
		let relKey = file.standardizedRelativePath
		guard let fsService = fileSystemServices[rootKey] else { return nil }
		return try? await fsService.loadContent(ofRelativePath: relKey)
	}

	@MainActor
	private func buildAnchorsByRelativePath(
		for payloads: [SliceMutationPayload]
	) async -> [String: [SliceAnchor]] {
		guard !payloads.isEmpty else { return [:] }

		var mergedRangesByPath: [String: [LineRange]] = [:]
		var fileByPath: [String: FileViewModel] = [:]

		for payload in payloads {
			mergedRangesByPath[payload.relativePath, default: []].append(contentsOf: payload.ranges)
			fileByPath[payload.relativePath] = payload.file
		}

		var result: [String: [SliceAnchor]] = [:]
		for (relativePath, ranges) in mergedRangesByPath {
			let normalized = SliceRangeMath.normalize(ranges)
			guard !normalized.isEmpty else { continue }
			guard let file = fileByPath[relativePath] else { continue }
			guard let content = await sliceAnchorContent(for: file) else { continue }

			let anchors = await Task.detached(priority: .utility) {
				SliceRebaseEngine.buildAnchors(content: content, ranges: normalized)
			}.value
			if !anchors.isEmpty {
				result[relativePath] = anchors
			}
		}

		return result
	}
		
	@MainActor
	func setSelectionSlices(
		entries: [SelectionSliceInput],
		mode: SliceMutationMode,
		persistWorkspace: Bool = true
	) async throws -> SelectionSlicesMutationResult {
		guard !rootFolders.isEmpty else {
			throw SelectionSliceError.noWorkspaceLoaded
		}
		
		let scope = try currentPartitionScope()
		
		if entries.isEmpty {
			if mode == .set {
				let roots = Set(rootFolders.map { $0.standardizedFullPath })
				for rootPath in roots {
					let post = try await partitionStore.apply(
						forRoot: rootPath,
						scope: scope,
						updates: [:],
						mode: .set
					)
					if post.isEmpty {
						currentSlicesByRoot.removeValue(forKey: rootPath)
					} else {
						currentSlicesByRoot[rootPath] = post
					}
				}
				requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
				if persistWorkspace {
					requestWorkspaceSaveDebounced()
				}
			}
			
			return SelectionSlicesMutationResult(
				invalidPaths: [],
				resolvedMap: [:],
				snapshot: selectionSlicesByFileID
			)
		}
		
		let normalizedInputs = entries.map { normalizeUserInputPath($0.path) }
		let lookup = await findFiles(atPaths: normalizedInputs, profile: .mcpSelection)
		
		var invalid: [String] = []
		var resolved: [String: String] = [:]
		
		var grouped: [String: [SliceMutationPayload]] = [:]
	
		for (index, entry) in entries.enumerated() {
			let normalized = normalizedInputs[index]
			guard let fileVM = lookup[normalized] else {
				invalid.append(entry.path)
				continue
			}
			
			let rootKey = fileVM.standardizedRootFolderPath
			let relKey = fileVM.standardizedRelativePath
			let payload = SliceMutationPayload(
				file: fileVM,
				relativePath: relKey,
				ranges: entry.ranges,
				modificationTime: fileVM.modificationDate.timeIntervalSince1970
			)
			grouped[rootKey, default: []].append(payload)
			resolved[entry.path] = mcpDisplayPath(for: fileVM)
		}
		
		if grouped.isEmpty {
			if mode == .set {
				let roots = Set(rootFolders.map { $0.standardizedFullPath })
				for rootPath in roots {
					let post = try await partitionStore.apply(
						forRoot: rootPath,
						scope: scope,
						updates: [:],
						mode: .set
					)
					if post.isEmpty {
						currentSlicesByRoot.removeValue(forKey: rootPath)
					} else {
						currentSlicesByRoot[rootPath] = post
					}
				}
				requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
				if persistWorkspace {
					requestWorkspaceSaveDebounced()
				}
			}
			
			return SelectionSlicesMutationResult(
				invalidPaths: invalid,
				resolvedMap: resolved,
				snapshot: selectionSlicesByFileID
			)
		}
		
		var filesToSelect = Set<FileViewModel>()
		var anchorsByRoot: [String: [String: [SliceAnchor]]] = [:]
		if mode != .remove {
			for (rootPath, payloads) in grouped {
				anchorsByRoot[rootPath] = await buildAnchorsByRelativePath(for: payloads)
			}
		}
		
		switch mode {
		case .set:
			let rootPaths = Set(rootFolders.map { $0.standardizedFullPath })
			var newMap: [String: [String: PartitionStore.StoredSlices]] = [:]
			
			for rootPath in rootPaths {
				let payloads = grouped[rootPath] ?? []
				let anchorMap = anchorsByRoot[rootPath] ?? [:]
				var updates: [String: PartitionStore.SliceUpdate] = [:]
				for payload in payloads {
					if payload.ranges.isEmpty {
						updates[payload.relativePath] = PartitionStore.SliceUpdate(
							ranges: [],
							fileModificationTime: payload.modificationTime,
							anchors: nil
						)
					} else {
						var update = updates[payload.relativePath] ?? PartitionStore.SliceUpdate(
							ranges: [],
							fileModificationTime: payload.modificationTime,
							anchors: anchorMap[payload.relativePath]
						)
						update.ranges.append(contentsOf: payload.ranges)
						update.fileModificationTime = payload.modificationTime
						update.anchors = anchorMap[payload.relativePath]
						updates[payload.relativePath] = update
					}
				}
				
				let post = try await partitionStore.apply(
					forRoot: rootPath,
					scope: scope,
					updates: updates,
					mode: .set
				)
				
				if !post.isEmpty {
					newMap[rootPath] = post
				}
				
				if !payloads.isEmpty {
					for payload in payloads {
						if let entry = post[payload.relativePath], !entry.ranges.isEmpty {
							if !payload.file.isChecked {
								filesToSelect.insert(payload.file)
							}
							// Clean transition from codemap → selected
							removeCodemapFile(payload.file)
						}
					}
				}
			}
			
			currentSlicesByRoot = newMap
			
		case .setPaths:
			// File-scoped replacement: replace slices only for specified files
			var map = currentSlicesByRoot
			
			for (rootPath, payloads) in grouped {
				let anchorMap = anchorsByRoot[rootPath] ?? [:]
				var updates: [String: PartitionStore.SliceUpdate] = [:]
				for payload in payloads {
					if payload.ranges.isEmpty {
						updates[payload.relativePath] = PartitionStore.SliceUpdate(
							ranges: [],
							fileModificationTime: payload.modificationTime,
							anchors: nil
						)
					} else {
						var update = updates[payload.relativePath] ?? PartitionStore.SliceUpdate(
							ranges: [],
							fileModificationTime: payload.modificationTime,
							anchors: anchorMap[payload.relativePath]
						)
						update.ranges.append(contentsOf: payload.ranges)
						update.fileModificationTime = payload.modificationTime
						update.anchors = anchorMap[payload.relativePath]
						updates[payload.relativePath] = update
					}
				}
				
				let post = try await partitionStore.apply(
					forRoot: rootPath,
					scope: scope,
					updates: updates,
					mode: .setPaths
				)
				
				if post.isEmpty {
					map.removeValue(forKey: rootPath)
				} else {
					map[rootPath] = post
				}
				
				for payload in payloads {
					if let entry = post[payload.relativePath], !entry.ranges.isEmpty {
						if !payload.file.isChecked {
							filesToSelect.insert(payload.file)
						}
						// Clean transition from codemap → selected
						removeCodemapFile(payload.file)
					}
				}
			}
			
			currentSlicesByRoot = map
			
		case .add, .remove:
			var map = currentSlicesByRoot
			for (rootPath, payloads) in grouped {
				let anchorMap = anchorsByRoot[rootPath] ?? [:]
				var updates: [String: PartitionStore.SliceUpdate] = [:]
				for payload in payloads {
					if payload.ranges.isEmpty {
						updates[payload.relativePath] = PartitionStore.SliceUpdate(
							ranges: [],
							fileModificationTime: payload.modificationTime,
							anchors: nil
						)
					} else {
						var update = updates[payload.relativePath] ?? PartitionStore.SliceUpdate(
							ranges: [],
							fileModificationTime: payload.modificationTime,
							anchors: anchorMap[payload.relativePath]
						)
						update.ranges.append(contentsOf: payload.ranges)
						update.fileModificationTime = payload.modificationTime
						if mode != .remove {
							update.anchors = anchorMap[payload.relativePath]
						} else {
							update.anchors = nil
						}
						updates[payload.relativePath] = update
					}
				}
				
				let post = try await partitionStore.apply(
					forRoot: rootPath,
					scope: scope,
					updates: updates,
					mode: mode
				)
				
				if post.isEmpty {
					map.removeValue(forKey: rootPath)
				} else {
					map[rootPath] = post
				}
				
				if mode != .remove {
					for payload in payloads {
						if let entry = post[payload.relativePath], !entry.ranges.isEmpty {
							if !payload.file.isChecked {
								filesToSelect.insert(payload.file)
							}
							// Clean transition from codemap → selected
							removeCodemapFile(payload.file)
						}
					}
				}
			}
			
			currentSlicesByRoot = map
		}
			
		if persistWorkspace {
			requestWorkspaceSaveDebounced()
		}
		
		if !filesToSelect.isEmpty {
			let pending = filesToSelect.filter { !$0.isChecked }
			if !pending.isEmpty {
				let parents = Array(Set(pending.compactMap { $0.parentFolder }))
				performSelectionBatch {
					for file in pending where !file.isChecked {
						file.setIsChecked(true)
					}
				}
				for parent in parents {
					recomputeAncestorStates(startingAt: parent)
				}
			}
		}
		
		requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
		
		return SelectionSlicesMutationResult(
			invalidPaths: invalid,
			resolvedMap: resolved,
			snapshot: selectionSlicesByFileID
		)
	}

	@MainActor
	func clearSelectionSlices(for file: FileViewModel) async throws {
		guard !rootFolders.isEmpty else {
			throw SelectionSliceError.noWorkspaceLoaded
		}

		let scope = try currentPartitionScope()
		let rootKey = file.standardizedRootFolderPath
		let relKey = file.standardizedRelativePath

		let storedBefore = currentSlicesByRoot[rootKey]?[relKey]
		let selectionBefore = selectionSlicesByFileID[file.id]

		// Exit early when there's nothing to remove
		if storedBefore == nil, selectionBefore == nil {
			return
		}

		let updates: [String: PartitionStore.SliceUpdate] = [
			relKey: PartitionStore.SliceUpdate(
				ranges: [],
				fileModificationTime: file.modificationDate.timeIntervalSince1970
			)
		]

		let post = try await partitionStore.apply(
			forRoot: rootKey,
			scope: scope,
			updates: updates,
			mode: .remove
		)

		if post.isEmpty {
			currentSlicesByRoot.removeValue(forKey: rootKey)
		} else {
			currentSlicesByRoot[rootKey] = post
		}

		requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")

		requestWorkspaceSaveDebounced()
	}
	
   @MainActor
   func getSelectionSlicesSnapshot() -> [UUID: [LineRange]] {
       selectionSlicesByFileID
   }

   @MainActor
   func selectionSlices(for file: FileViewModel) -> [LineRange]? {
       selectionSlicesByFileID[file.id]
   }

   @MainActor
   func selectionSlicesDisplayMap(filePathDisplay: FilePathDisplay) -> [String: [LineRange]] {
       guard !selectionSlicesByFileID.isEmpty else { return [:] }

       let multipleRoots = Set(selectedFiles.map { $0.rootFolderPath }).count > 1
       var result: [String: [LineRange]] = [:]

       for file in selectedFiles {
           guard let ranges = selectionSlicesByFileID[file.id], !ranges.isEmpty else { continue }
           let key: String
           switch filePathDisplay {
           case .full:
               key = file.fullPath
           case .relative:
               key = multipleRoots ? file.uniqueRelativePath : file.relativePath
           }
           result[key] = ranges
       }

       return result
   }
	
	@MainActor
	func withDeferredSelectionSliceSnapshotRebuild<T>(
		reason: String,
		operation: () async throws -> T
	) async rethrows -> T {
		sliceSnapshotRebuildDeferralDepth += 1
		defer {
			sliceSnapshotRebuildDeferralDepth = max(0, sliceSnapshotRebuildDeferralDepth - 1)
			if sliceSnapshotRebuildDeferralDepth == 0 {
				flushDeferredSelectionSliceSnapshotRebuildIfNeeded(reason: reason)
			}
		}
		return try await operation()
	}

	@MainActor
	private func requestSelectionSliceSnapshotRebuild(reason: String) {
		guard sliceSnapshotRebuildDeferralDepth == 0 else {
			sliceSnapshotRebuildPending = true
			#if DEBUG
			sliceSnapshotRebuildPendingReasons.insert(reason)
			WorkspaceRestorePerfLog.event(
				"selection.rebuildSlicesSnapshot",
				fields: [
					"mode": "deferredRequest",
					"reason": reason,
					"deferralDepth": "\(sliceSnapshotRebuildDeferralDepth)",
					"pendingReasons": sliceSnapshotRebuildPendingReasons.sorted().joined(separator: ",")
				]
			)
			#endif
			return
		}

		performSelectionSlicesSnapshotRebuild(
			reason: reason,
			mode: "immediate",
			pendingReasons: []
		)
	}

	@MainActor
	private func flushDeferredSelectionSliceSnapshotRebuildIfNeeded(reason: String) {
		guard sliceSnapshotRebuildDeferralDepth == 0 else { return }
		guard sliceSnapshotRebuildPending else { return }
		#if DEBUG
		let pendingReasons = sliceSnapshotRebuildPendingReasons
		sliceSnapshotRebuildPendingReasons.removeAll()
		#else
		let pendingReasons = Set<String>()
		#endif
		sliceSnapshotRebuildPending = false
		performSelectionSlicesSnapshotRebuild(
			reason: reason,
			mode: "deferredFlush",
			pendingReasons: pendingReasons
		)
	}

	@MainActor
	private func performSelectionSlicesSnapshotRebuild(
		reason: String,
		mode: String,
		pendingReasons: Set<String>
	) {
		#if DEBUG
		let rebuildStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		var snapshotFiles = 0
		defer {
			WorkspaceRestorePerfLog.event(
				"selection.rebuildSlicesSnapshot",
				fields: [
					"mode": mode,
					"reason": reason,
					"pendingReasons": pendingReasons.sorted().joined(separator: ","),
					"selectedFiles": "\(selectedFiles.count)",
					"snapshotFiles": "\(snapshotFiles)",
					"duration": rebuildStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
		}
		#endif
		guard !selectedFiles.isEmpty else {
			if !selectionSlicesByFileID.isEmpty {
				selectionSlicesByFileID = [:]
			}
			return
		}
		
		var snapshot: [UUID: [LineRange]] = [:]
		for file in selectedFiles {
			let rootKey = file.standardizedRootFolderPath
			guard let rootSlices = currentSlicesByRoot[rootKey] else { continue }
			let relKey = file.standardizedRelativePath
			if let entry = rootSlices[relKey], !entry.ranges.isEmpty {
				snapshot[file.id] = entry.ranges
			}
		}
		#if DEBUG
		snapshotFiles = snapshot.count
		#endif
		
		if snapshot != selectionSlicesByFileID {
			selectionSlicesByFileID = snapshot
		}
	}
	
	func initCodeScanState(_ isEnabled: Bool) {
		codeScanEnabled = isEnabled
	}

	@MainActor
	public func requestCodemapScan(for files: [FileViewModel]) {
		guard !files.isEmpty else { return }
		requestScans(forFiles: files)
	}

	@MainActor
	func beginDeferringInitialRootLoadScans() {
		clearDeferredInitialRootLoadScanState(keepingActiveDeferral: false)
		isInitialRootLoadScanDeferralActive = true
	}

	@MainActor
	func discardDeferredInitialRootLoadScans() {
		clearDeferredInitialRootLoadScanState(keepingActiveDeferral: false)
	}

	@MainActor
	func flushDeferredInitialRootLoadScans() {
		guard isInitialRootLoadScanDeferralActive else {
			clearDeferredInitialRootLoadScanState(keepingActiveDeferral: false)
			return
		}

		isInitialRootLoadScanDeferralActive = false
		let rootPaths = deferredInitialRootLoadScanRoots
		deferredInitialRootLoadScanRoots.removeAll()
		deferredInitialRootLoadScanFlushTask?.cancel()
		deferredInitialRootLoadScanFlushTask = nil
		deferredInitialRootLoadScanFlushTaskID = nil

		guard codeScanEnabled, !rootPaths.isEmpty else { return }

		let taskID = UUID()
		deferredInitialRootLoadScanFlushTaskID = taskID
		deferredInitialRootLoadScanFlushTask = Task(priority: .utility) { @MainActor [weak self] in
			guard let self else { return }
			defer {
				if self.deferredInitialRootLoadScanFlushTaskID == taskID {
					self.deferredInitialRootLoadScanFlushTask = nil
					self.deferredInitialRootLoadScanFlushTaskID = nil
				}
			}

			guard self.codeScanEnabled else { return }
			for rootPath in rootPaths.sorted() {
				guard !Task.isCancelled, self.codeScanEnabled else { return }
				guard let rootFolder = self.loadedUserRootFolder(for: rootPath) else { continue }
				let filesToScan = self.getFilesRecursively(under: rootFolder)
				guard !Task.isCancelled else { return }
				// A root can unload while file gathering is in progress; skip it without aborting later roots.
				guard self.loadedUserRootFolder(for: rootPath) != nil else { continue }
				self.requestScans(
					forFiles: filesToScan,
					purpose: .initialRootLoad,
					rootFolderPaths: [rootPath]
				)
				await Task.yield()
			}
		}
	}

	@MainActor
	private func clearDeferredInitialRootLoadScanState(keepingActiveDeferral: Bool) {
		deferredInitialRootLoadScanFlushTask?.cancel()
		deferredInitialRootLoadScanFlushTask = nil
		deferredInitialRootLoadScanFlushTaskID = nil
		deferredInitialRootLoadScanRoots.removeAll()
		if !keepingActiveDeferral {
			isInitialRootLoadScanDeferralActive = false
		}
	}

	@MainActor
	private func removeDeferredInitialRootLoadScanRoot(_ rootPath: String) {
		let standardizedRootPath = (rootPath as NSString).standardizingPath
		deferredInitialRootLoadScanRoots.remove(standardizedRootPath)
	}

	@MainActor
	private func loadedUserRootFolder(for rootPath: String) -> FolderViewModel? {
		let standardizedRootPath = (rootPath as NSString).standardizingPath
		guard loadedRootPaths.contains(standardizedRootPath) else { return nil }
		return rootFolders.first {
			!$0.isSystemRoot && $0.standardizedFullPath == standardizedRootPath
		}
	}

	@MainActor
	private func enqueueOrDeferInitialRootLoadScan(for rootFolder: FolderViewModel) {
		#if DEBUG
		let enqueueScanStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		#endif
		let rootPath = rootFolder.standardizedFullPath
		guard !rootFolder.isSystemRoot else {
			#if DEBUG
			WorkspaceRestorePerfLog.event(
				"folderLoad.enqueueScan",
				fields: [
					"workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
					"rootName": rootFolder.name,
					"outcome": "skipped",
					"duration": enqueueScanStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
			#endif
			return
		}
		if isInitialRootLoadScanDeferralActive {
			deferredInitialRootLoadScanRoots.insert(rootPath)
			#if DEBUG
			WorkspaceRestorePerfLog.event(
				"folderLoad.enqueueScan",
				fields: [
					"workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
					"rootName": rootFolder.name,
					"outcome": "deferred",
					"duration": enqueueScanStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
				]
			)
			#endif
			return
		}
		let filesToScan = getFilesRecursively(under: rootFolder)
		requestScans(
			forFiles: filesToScan,
			purpose: .initialRootLoad,
			rootFolderPaths: [rootPath]
		)
		#if DEBUG
		WorkspaceRestorePerfLog.event(
			"folderLoad.enqueueScan",
			fields: [
				"workspaceID": WorkspaceRestorePerfLog.shortID(currentWorkspaceID),
				"rootName": rootFolder.name,
				"outcome": "enqueued",
				"files": "\(filesToScan.count)",
				"duration": enqueueScanStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
			]
		)
		#endif
	}

	// New: Request scans for a set of files in bulk with minimal MainActor work
	@MainActor
	private func requestScans(
		forFiles files: [FileViewModel],
		purpose: CodeScanActor.ScanBatchPurpose = .adhoc,
		rootFolderPaths: [String] = []
	) {
		guard codeScanEnabled else { return }
		
		let rootPaths = Set(
			files.map(\.standardizedRootFolderPath) +
			rootFolderPaths.map { ($0 as NSString).standardizingPath }
		)
		let rootServices = rootPaths.reduce(into: [String: FileSystemService]()) { result, root in
			if let service = getFileSystemService(for: root) {
				result[root] = service
			}
		}
		
		// Filter supported files up-front
		let supported = files.compactMap { f -> FileViewModel? in
			guard let ext = f.fileExtension, SyntaxManager.isSupportedFileExtension(ext) else { return nil }
			return f
		}
		guard !supported.isEmpty else {
			guard purpose == .initialRootLoad, !rootPaths.isEmpty else { return }
			enqueueInitialRootLoadRequests(
				files: [],
				rootPaths: rootPaths,
				rootServices: rootServices,
				purgeCachesOnEmptyInitialRequests: true
			)
			return
		}
		
		if purpose == .initialRootLoad {
			enqueueInitialRootLoadRequests(
				files: supported,
				rootPaths: rootPaths,
				rootServices: rootServices
			)
			return
		}
		
		// Cancel any previous enqueue task so only one builder runs at a time
		currentAdhocScanEnqueueTask?.cancel()
		currentAdhocScanEnqueueTask = Task.detached(priority: .userInitiated) { [weak self] in
			guard let self = self else { return }
			
			let snapshots = await Self.buildScanSnapshots(from: supported)
			if Task.isCancelled { return }
			let requests = await Self.buildScanRequests(
				from: snapshots,
				using: rootServices
			)
			if Task.isCancelled { return }

			if !requests.isEmpty {
				await self.codeScanActor.requestScans(requests, purpose: purpose)
			}
		}
	}

	@MainActor
	private func enqueueReplayScanRequests(forFiles files: [FileViewModel]) {
		guard codeScanEnabled else { return }
		let supported = files.compactMap { file -> FileViewModel? in
			guard let ext = file.fileExtension, SyntaxManager.isSupportedFileExtension(ext) else { return nil }
			return file
		}
		guard !supported.isEmpty else { return }
		let rootPaths = Set(supported.map(\.standardizedRootFolderPath))
		let rootServices = rootPaths.reduce(into: [String: FileSystemService]()) { result, root in
			if let service = getFileSystemService(for: root) {
				result[root] = service
			}
		}
		let taskID = UUID()
		let task = Task.detached(priority: .userInitiated) { [weak self] in
			guard let self else { return }

			func clearReplayTaskIfCurrent() async {
				await MainActor.run { [weak self] in
					self?.replayScanEnqueueTasks[taskID] = nil
				}
			}

			let snapshots = await Self.buildScanSnapshots(from: supported)
			if Task.isCancelled {
				await clearReplayTaskIfCurrent()
				return
			}
			let requests = await Self.buildScanRequests(
				from: snapshots,
				using: rootServices
			)
			if Task.isCancelled {
				await clearReplayTaskIfCurrent()
				return
			}
			if !requests.isEmpty {
				await self.codeScanActor.requestScans(requests)
			}
			await clearReplayTaskIfCurrent()
		}
		replayScanEnqueueTasks[taskID] = task
	}
	
	@MainActor
	private func enqueueInitialRootLoadRequests(
		files: [FileViewModel],
		rootPaths: Set<String>,
		rootServices: [String: FileSystemService],
		purgeCachesOnEmptyInitialRequests: Bool = false
	) {
		guard !rootPaths.isEmpty else { return }
		
		for root in rootPaths {
			if let existing = initialRootScanEnqueueTasks[root] {
				existing.task.cancel()
				initialRootScanEnqueueTasks[root] = nil
			}
		}
		
		let taskID = UUID()
		let task = Task.detached(priority: .userInitiated) { [weak self] in
			guard let self = self else { return }

			func clearInitialRootTasksIfCurrent() async {
				await MainActor.run { [weak self] in
					guard let self = self else { return }
					for root in rootPaths {
						if self.initialRootScanEnqueueTasks[root]?.id == taskID {
							self.initialRootScanEnqueueTasks[root] = nil
						}
					}
				}
			}

			let snapshots = await Self.buildScanSnapshots(from: files)
			if Task.isCancelled {
				await clearInitialRootTasksIfCurrent()
				return
			}
			let requests = await Self.buildScanRequests(
				from: snapshots,
				using: rootServices
			)

			if Task.isCancelled {
				await clearInitialRootTasksIfCurrent()
				return
			}

			await self.codeScanActor.requestScans(
				requests,
				purpose: .initialRootLoad,
				rootFolderPaths: Array(rootPaths),
				purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
			)
			
			await clearInitialRootTasksIfCurrent()
		}
		
		let entry = InitialRootEnqueueTask(id: taskID, task: task)
		for root in rootPaths {
			initialRootScanEnqueueTasks[root] = entry
		}
	}
	
	private nonisolated static func boundedAsyncCompactMap<Input, Output: Sendable>(
		_ inputs: [Input],
		maxConcurrent: Int,
		_ transform: @escaping @Sendable (Int, Input) async -> Output?
	) async -> [Output] {
		guard !inputs.isEmpty, maxConcurrent > 0, !Task.isCancelled else { return [] }

		return await withTaskGroup(
			of: (Int, Output?).self,
			returning: [Output].self
		) { group in
			var iterator = inputs.enumerated().makeIterator()
			let initialCount = min(maxConcurrent, inputs.count)

			func enqueueNext() -> Bool {
				guard !Task.isCancelled, let next = iterator.next() else { return false }
				group.addTask {
					guard !Task.isCancelled else { return (next.offset, nil) }
					return (next.offset, await transform(next.offset, next.element))
				}
				return true
			}

			for _ in 0..<initialCount {
				_ = enqueueNext()
			}

			var indexedResults: [(Int, Output)] = []
			indexedResults.reserveCapacity(inputs.count)
			while let (index, output) = await group.next() {
				if let output {
					indexedResults.append((index, output))
				}
				if Task.isCancelled {
					group.cancelAll()
					break
				}
				_ = enqueueNext()
			}

			if Task.isCancelled { return [] }
			return indexedResults
				.sorted { lhs, rhs in lhs.0 < rhs.0 }
				.map(\.1)
		}
	}

	private nonisolated static func buildScanSnapshots(
		from files: [FileViewModel]
	) async -> [ScanSnapshot] {
		let snapshotStart = CodeMapPerfRuntime.sharedPipelineStats.map { _ in CodeMapPerfRuntime.currentTime() }
		defer {
			if let snapshotStart {
				CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.snapshotBuildDuration, CodeMapPerfRuntime.durationSince(snapshotStart))
			}
		}
		guard !files.isEmpty, !Task.isCancelled else { return [] }

		let snapshots = await boundedAsyncCompactMap(
			files,
			maxConcurrent: codemapSnapshotFanoutLimit
		) { _, file -> ScanSnapshot? in
			guard !Task.isCancelled else { return nil }
			let cacheSnapshot = await file.cachedContentSnapshot()
			guard !Task.isCancelled else { return nil }
			let rootKey = file.standardizedRootFolderPath
			let ext = file.fileExtension ?? ((file.name as NSString).pathExtension)
			return ScanSnapshot(
				id: file.id,
				mod: cacheSnapshot.modificationDate,
				ext: ext,
				rel: file.relativePath,
				full: file.fullPath,
				root: rootKey,
				cachedContent: cacheSnapshot.content,
				cachedContentIsFresh: cacheSnapshot.isFresh
			)
		}
		return Task.isCancelled ? [] : snapshots
	}

	private nonisolated static func buildScanRequests(
		from snapshots: [ScanSnapshot],
		using rootServices: [String: FileSystemService]
	) async -> [CodeScanActor.ScanRequest] {
		let requestStart = CodeMapPerfRuntime.sharedPipelineStats.map { _ in CodeMapPerfRuntime.currentTime() }
		defer {
			if let requestStart {
				CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.requestBuildDuration, CodeMapPerfRuntime.durationSince(requestStart))
			}
		}
		guard !snapshots.isEmpty, !Task.isCancelled else { return [] }

		let requests = await boundedAsyncCompactMap(
			snapshots,
			maxConcurrent: codemapContentLoadFanoutLimit
		) { _, snap -> CodeScanActor.ScanRequest? in
			guard !Task.isCancelled else { return nil }
			if snap.cachedContentIsFresh, let content = snap.cachedContent {
				return CodeScanActor.ScanRequest(
					fileID: snap.id,
					modificationDate: snap.mod,
					content: content,
					fileExtension: snap.ext,
					relativePath: snap.rel,
					fullPath: snap.full,
					rootFolderPath: snap.root
				)
			}

			guard let service = rootServices[snap.root], !Task.isCancelled else { return nil }
			do {
				let contentLoadStart = CodeMapPerfRuntime.sharedPipelineStats.map { _ in CodeMapPerfRuntime.currentTime() }
				let (content, modDate) = try await service.loadContentWithDate(
					ofRelativePath: snap.rel
				)
				if let contentLoadStart {
					CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.contentLoadDuration, CodeMapPerfRuntime.durationSince(contentLoadStart))
				}
				guard !Task.isCancelled else { return nil }
				return CodeScanActor.ScanRequest(
					fileID: snap.id,
					modificationDate: modDate,
					content: content ?? "",
					fileExtension: snap.ext,
					relativePath: snap.rel,
					fullPath: snap.full,
					rootFolderPath: snap.root
				)
			} catch {
				return nil
			}
		}
		if !requests.isEmpty {
			CodeMapPerfRuntime.sharedPipelineStats?.increment(\.requestsBuilt, by: requests.count)
		}
		return Task.isCancelled ? [] : requests
	}
	
	// Modified: snapshot file fields on MainActor before background task
	private func requestCodeScan(for fileVM: FileViewModel) {
		guard codeScanEnabled else { return }
		guard let fileExt = fileVM.fileExtension,
				SyntaxManager.isSupportedFileExtension(fileExt) else { return }
		
		let id = fileVM.id
		
		let rootKey = fileVM.standardizedRootFolderPath
		guard let service = getFileSystemService(for: rootKey) else { return }
		
		let scanTask = Task.detached(priority: .userInitiated) { [weak self, weak fileVM] in
			guard let self = self, let fileVM = fileVM else { return }

			func clearPerFileScanTask() async {
				await self.clearCodeScanTask(id: id)
			}

			if Task.isCancelled {
				await clearPerFileScanTask()
				return
			}

			let snapshots = await Self.buildScanSnapshots(from: [fileVM])
			if Task.isCancelled {
				await clearPerFileScanTask()
				return
			}
			let requests = await Self.buildScanRequests(
				from: snapshots,
				using: [rootKey: service]
			)
			if Task.isCancelled {
				await clearPerFileScanTask()
				return
			}

			if let request = requests.first {
				await self.codeScanActor.requestScan(request)
			}

			// Clean up the task reference when done
			await clearPerFileScanTask()
		}
		
		self.codeScanTasks[id] = scanTask
	}
	
	@MainActor
	private func clearCodeScanTask(id: UUID) {
		codeScanTasks[id] = nil
	}
	
	/// Example method to force a scan on everything
	// Modified: snapshot metadata before content loads to reduce MainActor traffic during bulk rescan
	public func rescanAllFilesIfLoaded() async {
		guard codeScanEnabled else { return }
		
		// Cancel any previous batch scan task before starting a new one.
		currentBatchScanTask?.cancel()
		
		// Gather all known file VMs that are relevant
		let allFiles = getAllFileViewModels().filter {
			guard let ext = $0.fileExtension else { return false }
			return SyntaxManager.isSupportedFileExtension(ext)
		}
		if allFiles.isEmpty { return }
		
		// Launch and store a new batch scanning task.
		currentBatchScanTask = Task { [weak self] in
			guard let self = self else { return }
			
			let rootPaths = Set(allFiles.map(\.standardizedRootFolderPath))
			let rootServices = await MainActor.run {
				rootPaths.reduce(into: [String: FileSystemService]()) { result, root in
					if let service = self.getFileSystemService(for: root) {
						result[root] = service
					}
				}
			}
			
			let snaps = await Self.buildScanSnapshots(from: allFiles)
			if Task.isCancelled { return }
			let requests = await Self.buildScanRequests(
				from: snaps,
				using: rootServices
			)
			if Task.isCancelled { return }
			// Enqueue all scan requests at once
			await self.codeScanActor.requestScans(requests)
		}
	}
	
	@MainActor
	public func cancelCodeMapScans() async {
		await cancelAllScans()
	}
	
	/// Cancel all scanning tasks
	public func cancelAllScans() async {
		clearDeferredInitialRootLoadScanState(keepingActiveDeferral: isInitialRootLoadScanDeferralActive)
		// Cancel the batch scan task if one exists
		currentBatchScanTask?.cancel()
		currentBatchScanTask = nil
		
		// Cancel any individual file scan tasks
		for task in codeScanTasks.values {
			task.cancel()
		}
		codeScanTasks.removeAll()
		
		// NEW: Cancel the ad-hoc enqueue task if present
		currentAdhocScanEnqueueTask?.cancel()
		currentAdhocScanEnqueueTask = nil
		for task in replayScanEnqueueTasks.values {
			task.cancel()
		}
		replayScanEnqueueTasks.removeAll()
		
		for entry in initialRootScanEnqueueTasks.values {
			entry.task.cancel()
		}
		initialRootScanEnqueueTasks.removeAll()
		
		// Also cancel scans in the actor
		await codeScanActor.cancelAllScans()
		remainingScanCount = 0
		totalFilesSeen = 0
	}
	
	/// Clear all code map caches and triggers a rescan
	@MainActor
	public func clearCodeMapCaches() async {
		// Cancel any ongoing scans first
		await cancelAllScans()
		
		// Get all root folder paths
		let rootPaths = rootFolders.map { $0.fullPath }
		
		// Clear all caches in the code scan actor
		await codeScanActor.clearAllCaches(rootFolders: rootPaths)
		
		// Clear the in-memory file APIs and reset scan state
		for file in getAllFileViewModels() {
			file.setCodeMap(nil)
		}
		
		// Reset scan tracking variables
		remainingScanCount = 0
		totalFilesSeen = 0
		
		// Notify that code map needs update
		codeMapUpdatePublisher.send()
		
		// Add a small delay to ensure state is properly reset
		//try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
		
		// Force a rescan by calling rescanAllFilesIfLoaded
		// This will re-trigger scans for all files if code scanning is enabled
		await rescanAllFilesIfLoaded()
	}
	
	@MainActor
	public func purgeStaleCodeMapCaches(keepingRoots roots: [String]) async {
		let normalized = Set(roots.map { ($0 as NSString).standardizingPath })
		await codeScanActor.purgeStaleRootCaches(keepingRootPaths: Array(normalized))
	}
	
	public func searchFiles(
		pattern:        String,
		isRegex:        Bool  = false,
		caseInsensitive: Bool = false
	) async throws -> [SearchMatch] {
		
		return try await fileSearchActor.search(
			pattern: pattern,
			isRegex: isRegex,
			options: SearchOptions(caseInsensitive: caseInsensitive),
			in: getAllFileViewModels()
		)
	}

	// MARK: – Unified search facade –––––––––––––––––––––––––––––––––––––
	private static func searchAutoCorrectionWarning(isRegex: Bool) -> String {
		if isRegex {
			return "The content-search pattern was auto-corrected before running. Results may reflect a repaired or escaped version of the requested regex rather than the exact pattern you entered."
		}
		return "The content-search pattern was auto-corrected before running. Results may reflect a de-escaped literal interpretation of the text you entered."
	}

	private func pathSearchAliasByRootPath(for rootScope: LookupRootScope) -> [String: String]? {
		let scopedRootPaths = Set(roots(in: rootScope).map(\.standardizedFullPath))
		let visibleRoots = visibleWorkspaceRoots().filter { scopedRootPaths.contains($0.standardizedFullPath) }
		guard visibleRoots.count > 1 else { return nil }

		let nameCounts = Dictionary(grouping: visibleRoots, by: { $0.name.lowercased() })
		var aliasByRootPath: [String: String] = [:]
		for root in visibleRoots {
			guard !root.name.isEmpty,
				nameCounts[root.name.lowercased()]?.count == 1 else { continue }
			aliasByRootPath[root.standardizedFullPath] = root.name
		}
		return aliasByRootPath.isEmpty ? nil : aliasByRootPath
	}

	func search(
		pattern            : String,
		mode               : SearchMode      = .auto,
		isRegex            : Bool            = false,
		caseInsensitive    : Bool            = false,
		maxPaths           : Int             = 100,
		maxMatches         : Int             = 250,
		paths              : [String]?       = nil,
		includeExtensions  : [String]        = [],
		excludePatterns    : [String]        = [],
		contextLines       : Int             = 0,
		wholeWord          : Bool            = false,
		countOnly          : Bool            = false,
		fuzzySpaceMatching : Bool            = true,
		allowLiteralUnescapeFallback : Bool = true,
		rootScope          : LookupRootScope = .allLoaded,
		diagnosticRunID    : UUID?           = nil
	) async throws -> SearchResults {
		
		// Friendly pre-check: no workspace loaded
		if rootFolders.isEmpty {
			let msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
			throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
		}
		let entryPerfState = EditFlowPerf.begin(
			EditFlowPerf.Stage.Search.entrypoint,
			EditFlowPerf.Dimensions(
				searchMode: mode.rawValue,
				maxResults: max(maxPaths, maxMatches),
				isRegex: isRegex,
				countOnly: countOnly,
				caseInsensitive: caseInsensitive,
				wholeWord: wholeWord,
				contextLines: contextLines
			)
		)
		var entryPerfStatus = "ok"
		defer {
			EditFlowPerf.end(
				EditFlowPerf.Stage.Search.entrypoint,
				entryPerfState,
				EditFlowPerf.Dimensions(
					status: entryPerfStatus,
					searchMode: mode.rawValue,
					maxResults: max(maxPaths, maxMatches),
					isRegex: isRegex,
					countOnly: countOnly,
					caseInsensitive: caseInsensitive,
					wholeWord: wholeWord,
					contextLines: contextLines
				)
			)
		}
		
		// 1) Gather all loaded files once
		let allFiles = getAllFileViewModels(in: rootScope)
		let scopePerfState = EditFlowPerf.begin(
			EditFlowPerf.Stage.Search.scopeFiltering,
			EditFlowPerf.Dimensions(status: (paths?.isEmpty == false) ? "explicit" : "all", fileCount: allFiles.count)
		)
		#if DEBUG
		let scopeFilteringStartMS = MCPFileSearchPerfDiagnostics.timestampMS()
		#endif
		
		var filesToSearch: [FileViewModel]
		if let rawPaths = paths, !rawPaths.isEmpty {
			let explicitSystemEntries: [(resolution: ExplicitSystemPathResolution, hasWildcard: Bool)] = rawPaths.compactMap { raw -> (resolution: ExplicitSystemPathResolution, hasWildcard: Bool)? in
				let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
				guard let resolution = resolveExplicitSystemPath(trimmed) else { return nil }
				let normalized = normalizeUserInputPath(trimmed)
				let hasWildcard = normalized.contains("*") || normalized.contains("?") || normalized.contains("[")
				return (resolution, hasWildcard)
			}
			let explicitSystemInputs = explicitSystemEntries
				.filter { !$0.hasWildcard }
				.map(\.resolution)
			let explicitSystemWildcardClauses = explicitSystemEntries
				.filter(\.hasWildcard)
				.map { entry in
					SearchPathClause.glob(
						pattern: entry.resolution.standardizedRelativePath,
						restrictedRootPath: entry.resolution.root.standardizedFullPath
					)
				}
			let visibleInputs = rawPaths.filter {
				resolveExplicitSystemPath($0.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
			}
			let parsed = await parseSearchScopePaths(
				visibleInputs,
				caseInsensitive: caseInsensitive,
				rootScope: rootScope
			)
			#if DEBUG
			MCPFileSearchPerfDiagnostics.recordSearchInputs(
				runID: diagnosticRunID,
				allFileCount: allFiles.count,
				pathFilterCount: rawPaths.count,
				pathClauseCount: parsed.spec.clauses.count + explicitSystemWildcardClauses.count
			)
			#endif
			if parsed.spec.clauses.isEmpty,
			   explicitSystemInputs.isEmpty,
			   explicitSystemWildcardClauses.isEmpty,
			   let issue = parsed.issues.first {
				entryPerfStatus = "error"
				EditFlowPerf.end(
					EditFlowPerf.Stage.Search.scopeFiltering,
					scopePerfState,
					EditFlowPerf.Dimensions(status: "error", fileCount: allFiles.count)
				)
				throw FileManagerError.fileSystemServiceNotFoundWithContext(
					PathResolutionIssueRenderer.message(for: issue)
				)
			}
			
			let needsClientDisplayPath = parsed.spec.clauses.contains {
				switch $0 {
				case .glob, .legacyPrefix:
					return true
				case .exactFile, .exactFolder:
					return false
				}
			}
			let visibleRoots = needsClientDisplayPath ? visibleWorkspaceRoots() : []
			var snapshots: [FileSearchPathSnapshot] = []
			snapshots.reserveCapacity(allFiles.count)
			for file in allFiles {
				let clientDisplayPath: String
				if needsClientDisplayPath {
					let root = WorkspaceRootRef(
						id: file.rootIdentifier,
						name: file.rootFolderName,
						fullPath: file.rootFolderPath
					)
					clientDisplayPath = ClientPathFormatter.displayPath(
						root: root,
						relativePath: file.relativePath,
						visibleRoots: visibleRoots
					)
				} else {
					clientDisplayPath = file.standardizedRelativePath
				}
				snapshots.append(FileSearchPathSnapshot(
					standardizedFullPath: file.standardizedFullPath,
					standardizedRelativePath: file.standardizedRelativePath,
					standardizedRootPath: file.standardizedRootFolderPath,
					clientDisplayPath: clientDisplayPath
				))
			}
			
			let filterTask = Task.detached(priority: .userInitiated) { [snapshots, spec = parsed.spec] in
				filterPathIndicesResult(snapshots: snapshots, spec: spec)
			}
			if Task.isCancelled {
				filterTask.cancel()
			}
			let filterResult = await withTaskCancellationHandler {
				await filterTask.value
			} onCancel: {
				filterTask.cancel()
			}
			#if DEBUG
			MCPFileSearchPerfDiagnostics.recordScopeFiltering(
				runID: diagnosticRunID,
				durationMS: MCPFileSearchPerfDiagnostics.elapsedMS(since: scopeFilteringStartMS),
				visitedSnapshotCount: filterResult.visitedSnapshotCount,
				matchedCount: filterResult.matchedSnapshotIndices.count,
				cancelled: filterResult.cancelled,
				cancellationReason: filterResult.cancelled ? "task_cancelled" : nil
			)
			#endif
			if explicitSystemInputs.isEmpty, explicitSystemWildcardClauses.isEmpty {
				// Common visible-only scoped path branch: snapshots were built in `allFiles`
				// order, so matched snapshot indices map directly back to source files
				// without a full-path string round trip through `filesByFullPath`.
				filesToSearch = filterResult.matchedSnapshotIndices.map { allFiles[$0] }
			} else {
				var matchedAbsPaths = Set(filterResult.matchedSnapshotIndices.map { allFiles[$0].standardizedFullPath })
				if !explicitSystemInputs.isEmpty {
					for resolution in explicitSystemInputs {
						switch existingItemKind(atAbsolutePath: resolution.standardizedAbsolutePath) {
						case .file:
							matchedAbsPaths.insert(resolution.standardizedAbsolutePath)
						case .folder:
							let prefix = resolution.standardizedAbsolutePath.hasSuffix("/")
								? resolution.standardizedAbsolutePath
								: resolution.standardizedAbsolutePath + "/"
							for file in fileHierarchyIndex.filesByFullPath.values where file.standardizedFullPath.hasPrefix(prefix) {
								matchedAbsPaths.insert(file.standardizedFullPath)
							}
						case nil:
							break
						}
					}
				}
				if !explicitSystemWildcardClauses.isEmpty {
					let systemRootPaths = Set(explicitSystemWildcardClauses.compactMap { clause -> String? in
						guard case .glob(_, let restrictedRootPath) = clause else { return nil }
						return restrictedRootPath
					})
					let systemFiles = fileHierarchyIndex.filesByFullPath.values.filter {
						systemRootPaths.contains($0.standardizedRootFolderPath)
					}
					let systemSnapshots = systemFiles.map {
						FileSearchPathSnapshot(
							standardizedFullPath: $0.standardizedFullPath,
							standardizedRelativePath: $0.standardizedRelativePath,
							standardizedRootPath: $0.standardizedRootFolderPath,
							clientDisplayPath: $0.standardizedRelativePath
						)
					}
					let wildcardSpec = SearchPathFilterSpec(
						caseInsensitive: caseInsensitive,
						clauses: explicitSystemWildcardClauses
					)
					let wildcardMatches = filterPaths(snapshots: systemSnapshots, spec: wildcardSpec)
					matchedAbsPaths.formUnion(wildcardMatches)
				}
				filesToSearch = matchedAbsPaths.compactMap { fileHierarchyIndex.filesByFullPath[$0] }
			}
		} else {
			filesToSearch = allFiles
			#if DEBUG
			MCPFileSearchPerfDiagnostics.recordSearchInputs(
				runID: diagnosticRunID,
				allFileCount: allFiles.count,
				pathFilterCount: 0,
				pathClauseCount: 0
			)
			MCPFileSearchPerfDiagnostics.recordScopeFiltering(
				runID: diagnosticRunID,
				durationMS: MCPFileSearchPerfDiagnostics.elapsedMS(since: scopeFilteringStartMS),
				visitedSnapshotCount: allFiles.count,
				matchedCount: allFiles.count,
				cancelled: false
			)
			#endif
		}
		EditFlowPerf.end(
			EditFlowPerf.Stage.Search.scopeFiltering,
			scopePerfState,
			EditFlowPerf.Dimensions(status: (paths?.isEmpty == false) ? "explicit" : "all", fileCount: filesToSearch.count)
		)
		
		// 3) Delegate to the actor with the reduced file‑set
		let effectiveMode = mode == .auto ? FileSearchActor.inferredAutoMode(pattern) : mode
		let contentFreshnessPolicy: FileContentFreshnessPolicy = (effectiveMode == .content || effectiveMode == .both)
			? .validateDiskMetadata
			: .cachedMetadata
		if contentFreshnessPolicy == .validateDiskMetadata {
			var validatedFiles: [FileViewModel] = []
			validatedFiles.reserveCapacity(filesToSearch.count)
			for file in filesToSearch {
				if let present = await validateCatalogFileStillPresent(file) {
					validatedFiles.append(present)
				}
			}
			filesToSearch = validatedFiles
		}
		let scopedFileCount = filesToSearch.count
		let aliasByRootPath = pathSearchAliasByRootPath(for: rootScope)
		var wasAutoCorrected: Bool? = nil
		var results: SearchResults
		do {
			#if DEBUG
			let actorSearchStartMS = MCPFileSearchPerfDiagnostics.timestampMS()
			#endif
			results = try await EditFlowPerf.measure(
				EditFlowPerf.Stage.Search.actorSearchCall,
				EditFlowPerf.Dimensions(
					searchMode: mode.rawValue,
					fileCount: filesToSearch.count,
					maxResults: max(maxPaths, maxMatches),
					isRegex: isRegex,
					countOnly: countOnly,
					caseInsensitive: caseInsensitive,
					wholeWord: wholeWord,
					contextLines: contextLines
				)
			) {
				try await fileSearchActor.searchUnified(
					pattern: pattern,
					isRegex: isRegex,
					wasAutoCorrected: &wasAutoCorrected,
					options: SearchOptions(
						mode: mode,
						caseInsensitive: caseInsensitive,
						wholeWord: wholeWord,
						includeExtensions: includeExtensions,
						excludePatterns: excludePatterns,
						contextLines: contextLines,
						maxResults: max(maxPaths, maxMatches),
						countOnly: countOnly,
						fuzzySpaceMatching: fuzzySpaceMatching,
						allowLiteralUnescapeFallback: allowLiteralUnescapeFallback,
						contentFreshnessPolicy: contentFreshnessPolicy
					),
					in: filesToSearch,          // ← filtered list
					aliasByRootPath: aliasByRootPath
				)
			}
			#if DEBUG
			MCPFileSearchPerfDiagnostics.recordActorSearch(
				runID: diagnosticRunID,
				durationMS: MCPFileSearchPerfDiagnostics.elapsedMS(since: actorSearchStartMS),
				scopedFileCount: scopedFileCount,
				searchedFileCount: results.searchedFileCount,
				pathMatches: results.paths?.count ?? 0,
				contentMatches: results.matches?.count ?? 0,
				totalMatches: results.totalCount ?? ((results.paths?.count ?? 0) + (results.matches?.count ?? 0))
			)
			#endif
		} catch {
			entryPerfStatus = "error"
			throw error
		}
		results.scopedFileCount = scopedFileCount
		if wasAutoCorrected == true {
			results.warningMessage = Self.searchAutoCorrectionWarning(isRegex: isRegex)
		}
		return results
	}

}

// MARK: - Path utilities (new helper)
extension RepoFileManagerViewModel {
	struct SearchScopeParseResult: Sendable {
		let spec: SearchPathFilterSpec
		let issues: [PathResolutionIssue]
	}
	
	func canonicalURL(for path: String, assumingDirectory: Bool = false) -> URL {
		let normalized = normalizeUserInputPath(path)
		return URL(fileURLWithPath: normalized, isDirectory: assumingDirectory)
	}
	
	func canonicalURL(for url: URL, assumingDirectory: Bool = false) -> URL {
		canonicalURL(for: url.path, assumingDirectory: assumingDirectory)
	}
	
	@MainActor
	private func searchFolderSuffixIndex(
		for scope: LookupRootScope
	) -> SearchFolderSuffixIndex<FolderViewModel> {
		let generation = currentHierarchyGenerationSignature()
		if let cached = cachedSearchFolderSuffixIndexByScope[scope], cached.generation == generation {
			return cached.index
		}
		let roots = roots(in: scope)
		let allowedRootPaths = Set(roots.map(\.standardizedFullPath))
		let folders: [String: FolderViewModel]
		if scope == .allLoaded {
			folders = fileHierarchyIndex.foldersByFullPath
		} else {
			folders = fileHierarchyIndex.foldersByFullPath.filter {
				allowedRootPaths.contains(StandardizedPath.absolute($0.value.rootPath))
			}
		}
		let index = buildFolderSuffixIndex(
			in: folders,
			relativePath: { $0.relativePath },
			caseInsensitive: true
		)
		cachedSearchFolderSuffixIndexByScope[scope] = (generation, index)
		return index
	}
	
	private static let protectedLiteralTopLevelAbsoluteComponents: Set<String> = [
		"applications", "bin", "cores", "dev", "etc", "home", "library", "opt",
		"private", "sbin", "system", "tmp", "users", "usr", "var", "volumes"
	]
	
	@MainActor
	private func resolveLeadingSlashRootAlias(
		from standardizedPath: String,
		requireRemainder: Bool
	) -> RootAliasResolution? {
		guard standardizedPath.hasPrefix("/") else { return nil }
		let candidate = String(standardizedPath.dropFirst())
		guard !candidate.isEmpty else { return nil }
		let resolution = resolveVisibleRootAlias(
			candidate,
			requireRemainder: requireRemainder,
			disambiguateRealSubpath: false
		)
		switch resolution {
		case .bareRoot, .prefixed, .ambiguous:
			return resolution
		case .notAliasPrefixed:
			if let firstComponent = candidate.split(separator: "/").first,
			!firstComponent.isEmpty,
			Self.protectedLiteralTopLevelAbsoluteComponents.contains(firstComponent.lowercased()) {
				return nil
			}
			return nil
		}
	}
	
	@MainActor
	private func unmatchedAbsolutePathIssue(
		for standardizedAbsolutePath: String,
		rawInput: String
	) -> PathResolutionIssue {
		let roots = visibleWorkspaceRoots()
		
		let isInsideLoadedRoot = roots.contains { root in
			let rootPath = root.standardizedFullPath
			return standardizedAbsolutePath == rootPath
				|| standardizedAbsolutePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
		}
		
		if isInsideLoadedRoot {
			return .unresolved(input: rawInput)
		}
		
		if let aliasResolution = resolveLeadingSlashRootAlias(from: standardizedAbsolutePath, requireRemainder: false) {
			switch aliasResolution {
			case .ambiguous(let alias, let matchingRoots):
				return .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
			case .bareRoot, .prefixed:
				return .unresolved(input: rawInput)
			case .notAliasPrefixed:
				break
			}
		}
		
		return .pathOutsideWorkspace(input: rawInput, visibleRoots: roots)
	}
	
	@MainActor
	private func parseSearchScopePaths(
		_ rawPaths: [String],
		caseInsensitive: Bool,
		rootScope: LookupRootScope = .allLoaded
	) async -> SearchScopeParseResult {
		let normalizedEntries = rawPaths.compactMap { raw -> (raw: String, normalized: String, hadTrailingSlash: Bool)? in
			let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { return nil }
			return (raw, normalizeUserInputPath(trimmed), trimmed.hasSuffix("/"))
		}
		guard !normalizedEntries.isEmpty else {
			return SearchScopeParseResult(spec: SearchPathFilterSpec(caseInsensitive: caseInsensitive, clauses: []), issues: [])
		}
		
		var clauses: [SearchPathClause] = []
		var issues: [PathResolutionIssue] = []
		var seenClauses = Set<String>()
		let suffixIndex = searchFolderSuffixIndex(for: rootScope)
		var staticContext: (StaticPathMatchData, Set<String>, SelectionSig)?
		
		func appendClause(_ clause: SearchPathClause) {
			let key = String(describing: clause)
			if seenClauses.insert(key).inserted {
				clauses.append(clause)
			}
		}
		
		for entry in normalizedEntries {
			let normalized = entry.normalized
			let isWildcard = normalized.contains("*") || normalized.contains("?") || normalized.contains("[")
			if isWildcard {
				let aliasResolution = resolveLeadingSlashRootAlias(from: normalized, requireRemainder: true)
				switch aliasResolution ?? resolveVisibleRootAlias(normalized, requireRemainder: true, disambiguateRealSubpath: false) {
				case .prefixed(let root, _, let remainder):
					appendClause(.glob(pattern: remainder, restrictedRootPath: root.standardizedFullPath))
				case .ambiguous(let alias, let matchingRoots):
					issues.append(.ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
				case .notAliasPrefixed, .bareRoot:
					appendClause(.glob(pattern: normalized, restrictedRootPath: nil))
				}
				continue
			}
			
			let standardized = (normalized as NSString).standardizingPath
			if !standardized.hasPrefix("/") {
				if let issue = exactPathResolutionIssue(for: entry.raw, kind: .either, rootScope: rootScope) {
					issues.append(issue)
					continue
				}
			}
			if standardized.hasPrefix("/") {
				if let file = findFileByFullPath(standardized) {
					appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
					continue
				}
				if let folder = findFolderByFullPath(standardized) {
					appendClause(.exactFolder(
						absLower: folder.standardizedFullPath.lowercased(),
						relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
						restrictedRootPath: (folder.rootPath as NSString).standardizingPath
					))
					continue
				}
				if let aliasResolution = resolveLeadingSlashRootAlias(from: standardized, requireRemainder: false) {
					switch aliasResolution {
					case .bareRoot(let root, _):
						if let folder = rootFolders.first(where: { $0.id == root.id }) {
							appendClause(.exactFolder(
								absLower: folder.standardizedFullPath.lowercased(),
								relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
								restrictedRootPath: (folder.rootPath as NSString).standardizingPath
							))
							continue
						}
					case .prefixed(let root, _, let remainder):
						let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
						if let file = findFileByFullPath(abs) {
							appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
							continue
						}
						if let folder = findFolderByFullPath(abs) {
							appendClause(.exactFolder(
								absLower: folder.standardizedFullPath.lowercased(),
								relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
								restrictedRootPath: (folder.rootPath as NSString).standardizingPath
							))
							continue
						}
					case .ambiguous(let alias, let matchingRoots):
						issues.append(.ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
						continue
					case .notAliasPrefixed:
						break
					}
				}
				issues.append(unmatchedAbsolutePathIssue(for: standardized, rawInput: entry.raw))
				continue
			}
			
			if !entry.hadTrailingSlash {
				if let file = findFileByRelativePath(standardized, scope: rootScope) {
					appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
					continue
				}
				switch resolveVisibleRootAlias(standardized, requireRemainder: true, disambiguateRealSubpath: false) {
				case .prefixed(let root, _, let remainder):
					let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
					if let file = findFileByFullPath(abs) {
						appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
						continue
					}
					if let folder = findFolderByFullPath(abs) {
						appendClause(.exactFolder(
							absLower: folder.standardizedFullPath.lowercased(),
							relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
							restrictedRootPath: (folder.rootPath as NSString).standardizingPath
						))
						continue
					}
				case .ambiguous(let alias, let matchingRoots):
					issues.append(.ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
					continue
				case .notAliasPrefixed, .bareRoot:
					break
				}
			}
			
			if let folder = resolveFolderInput(entry.raw, rootScope: rootScope).folder {
				appendClause(.exactFolder(
					absLower: folder.standardizedFullPath.lowercased(),
					relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
					restrictedRootPath: (folder.rootPath as NSString).standardizingPath
				))
				continue
			}
			
			if !standardized.hasPrefix("/") {
				let suffixMatches = resolveFoldersBySuffixFragment(standardized, using: suffixIndex, caseInsensitive: true)
				if !suffixMatches.isEmpty {
					for folder in suffixMatches {
						appendClause(.exactFolder(
							absLower: folder.standardizedFullPath.lowercased(),
							relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
							restrictedRootPath: (folder.rootPath as NSString).standardizingPath
						))
					}
					continue
				}
			}
			
			if !entry.hadTrailingSlash {
				if staticContext == nil {
					staticContext = currentStaticPathMatchContext(scope: rootScope)
				}
				if let (staticData, selectedPaths, selectionSig) = staticContext,
				let match = await pathMatchWorker.locate(
						userPath: standardized,
						profile: .mcpSearchScope,
						staticData: staticData,
						selectedFileFullPaths: selectedPaths,
						selectionSig: selectionSig
				) {
					let abs = ((match.rootPath as NSString).appendingPathComponent(match.correctedPath) as NSString).standardizingPath
					if let folder = findFolderByFullPath(abs) {
						appendClause(.exactFolder(
							absLower: folder.standardizedFullPath.lowercased(),
							relLower: (folder.relativePath as NSString).standardizingPath.lowercased(),
							restrictedRootPath: (folder.rootPath as NSString).standardizingPath
						))
						continue
					}
					if let file = findFileByFullPath(abs) {
						appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: file.standardizedRootFolderPath))
						continue
					}
				}
			}
			
			appendClause(.legacyPrefix(candidateLower: standardized.lowercased()))
		}
		
		return SearchScopeParseResult(
			spec: SearchPathFilterSpec(caseInsensitive: caseInsensitive, clauses: clauses),
			issues: issues
		)
	}
	
	func normalizeFilterPaths(_ paths: [String]) async -> [String] {
		var staticContext: (StaticPathMatchData, Set<String>, SelectionSig)?
		var normalized: [String] = []
		normalized.reserveCapacity(paths.count)
		
		for path in paths {
			let rawTrimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
			let hadTrailingSlash = rawTrimmed.hasSuffix("/")
			
			let standardized = normalizeUserInputPath(path)
			if standardized.hasPrefix("/") {
				normalized.append(standardized)
				continue
			}
			
			if let issue = exactPathResolutionIssue(for: standardized, kind: .either) {
				switch issue {
				case .ambiguousAlias, .ambiguousRootMatch:
					normalized.append((standardized as NSString).standardizingPath)
					continue
				default:
					break
				}
			}
			
			// Check for bare root alias (e.g., "RepoPrompt" or "RepoPrompt/")
			if let rootAbs = resolveBareVisibleRootAliasAbsolutePath(standardized) {
				normalized.append(rootAbs)
				continue
			}
			
			// Check for alias-prefixed path with remainder (e.g., "RepoPrompt/src")
			switch resolveVisibleAliasPrefixedAbsolutePathResolution(standardized, requireRemainder: true) {
			case .resolved(let abs):
				normalized.append(abs)
				continue
			default:
				break
			}
			
			// Respect explicit directory intent and avoid file-path fuzzy resolution.
			if hadTrailingSlash {
				normalized.append(standardized)
				continue
			}
			
			// Lazily build context only when needed
			if staticContext == nil {
				staticContext = currentStaticPathMatchContext()
			}
			
			if let (staticData, selectedPaths, selectionSig) = staticContext,
			let match = await pathMatchWorker.locate(
					userPath: standardized,
					exactMatchOnly: false,
					staticData: staticData,
					selectedFileFullPaths: selectedPaths,
					selectionSig: selectionSig
			   ) {
				let absolutePath = ((match.rootPath as NSString)
					.appendingPathComponent(match.correctedPath) as NSString)
					.standardizingPath
				normalized.append(absolutePath)
			} else {
				normalized.append(standardized)
			}
		}
		
		return normalized
	}
	
	/// Resolves a bare root alias (just the root name, no subpath) to its absolute path.
	/// Returns `nil` if the input is not a bare root alias or is ambiguous.
	///
	/// Examples:
	/// - "RepoPrompt" → "/Users/.../RepoPrompt" (if RepoPrompt is a loaded root)
	/// - "RepoPrompt/" → "/Users/.../RepoPrompt" (trailing slash is stripped)
	/// - "RepoPrompt/src" → nil (has remainder, use resolveVisibleAliasPrefixedAbsolutePathResolution instead)
	/// - "/absolute/path" → nil (absolute paths are not aliases)
	@MainActor
	private func resolveBareVisibleRootAliasAbsolutePath(_ userPath: String) -> String? {
		let standardized = normalizeUserInputPath(userPath)
		
		// Absolute paths are not aliases
		guard !standardized.hasPrefix("/") else { return nil }
		
		// Trim leading/trailing slashes to get the bare alias
		let trimmed = standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard !trimmed.isEmpty else { return nil }
		
		// Must be a single component (no "/" inside) to be a bare root alias
		guard !trimmed.contains("/") else { return nil }
		
		// Use existing alias classification
		switch checkVisibleRootAliasPrefix(trimmed, requireRemainder: false) {
		case .uniqueRoot(let root, _):
			return root.standardizedFullPath
		default:
			return nil
		}
	}
}

@inline(__always)
private func isUnder(_ path: String, root: String) -> Bool {
	return path.isDescendant(of: root)
}

private func relativePath(from userPath: String, rootPath: String) throws -> String {
	let standard = (userPath as NSString).standardizingPath
	if standard.hasPrefix("/") {
		// absolute – must lie under the same root
		guard standard.hasPrefix(rootPath) else {
			throw FileSystemError.invalidRelativePath
		}
		return String(
			standard.dropFirst(rootPath.count)
					.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		)
	}
	return standard
}
private extension String {
	/// `true` if the receiver is *equal* to `parent` **or** lies *inside* it.
	/// Standardizes once at the boundary, then uses cheap string prefix checks.
	func isDescendant(of parent: String) -> Bool {
		StandardizedPath.isDescendant(
			StandardizedPath.absolute(self),
			of: StandardizedPath.absolute(parent)
		)
	}
}

// MARK: - Batch selection helpers
extension RepoFileManagerViewModel {
	/// Atomically commit selection state changes to both selectedFiles and selectedFileIDs.
	/// Ensures both collections stay in sync with one assignment point.
	@MainActor
	private func commitSelectionState(_ newFiles: [FileViewModel], _ newIDs: Set<UUID>) {
		// Fast-exit if nothing changes (preserves @Published churn)
		let idsUnchanged = (newIDs == selectedFileIDs)
		let filesUnchanged: Bool = {
			if newFiles.count != selectedFiles.count { return false }
			// Compare by stable identity (UUID)
			let lhs = newFiles.map(\.id)
			let rhs = selectedFiles.map(\.id)
			return lhs == rhs
		}()
		if idsUnchanged && filesUnchanged {
			return
		}
		
		#if DEBUG
		assert(Set(newFiles.map(\.id)) == newIDs, "Selection state mismatch: files vs. IDs")
		#endif

		selectedFileIDs = newIDs
		selectedFiles   = newFiles
		requestSelectionSliceSnapshotRebuild(reason: "commitSelectionState")
	
		// Only clear auto-codemap files automatically when auto mode is ON.
		// In manual mode, keep codemap files even if selection becomes empty.
		if newFiles.isEmpty {
			if codemapAutoEnabled {
				resetAutoCodemapFiles([])
			}
			// Do not flip codemapAutoEnabled here; explicit flows (clearSelection, tools) decide that.
		}
	
		// Only run auto-codemap sync when in auto mode and there are selected files to infer from.
		if codemapAutoEnabled, !selectedFiles.isEmpty {
			scheduleAutoCodemapSync()
		}
	}

	/// Clear both selected files and IDs in one atomic operation.
	@MainActor
	private func resetSelection() {
		commitSelectionState([], [])
	}

	/// Remove a single file from selection state if present. Returns true if a change occurred.
	@MainActor
	@discardableResult
	private func removeSelectedFileIfPresent(_ file: FileViewModel) -> Bool {
		var newIDs = selectedFileIDs
		let removed = (newIDs.remove(file.id) != nil)
		if removed {
			var newFiles = selectedFiles
			newFiles.removeAll { $0.id == file.id }
			commitSelectionState(newFiles, newIDs)
		}
		return removed
	}

	/// Remove a set of selected IDs along with their corresponding files. Returns true if any change occurred.
	@MainActor
	@discardableResult
	private func removeSelectedIDs(_ idsToRemove: Set<UUID>) -> Bool {
		guard !idsToRemove.isEmpty else { return false }
		let intersection = selectedFileIDs.intersection(idsToRemove)
		guard !intersection.isEmpty else { return false }
		let newIDs = selectedFileIDs.subtracting(idsToRemove)
		let newFiles = selectedFiles.filter { !idsToRemove.contains($0.id) }
		commitSelectionState(newFiles, newIDs)
		return true
	}

	/// Rebuild the ID set from the current selectedFiles array to guarantee consistency.
	@MainActor
	private func normalizeSelectionState() {
		let recomputed = Set(selectedFiles.map(\.id))
		commitSelectionState(selectedFiles, recomputed)
	}

	/// Centralised callback used by every FileViewModel.
	@MainActor
	private func handleCheckStateChanged(_ file: FileViewModel,
											isChecked: Bool) {
		if isSelectionBatching {
			if isChecked {
				pendingSelectionAdds.append(file)
			} else {
				pendingSelectionRemoves.append(file)
			}
			return
		}
		updateSelection(for: file, isChecked: isChecked)
	}

	/// O(1) selection update – never touches UI except the single publisher.
	@MainActor
	private func updateSelection(for file: FileViewModel,
									isChecked: Bool) {
		var newIDs = selectedFileIDs
		var newFiles = selectedFiles

		if isChecked {
			if newIDs.insert(file.id).inserted {
				newFiles.append(file)
			}
		} else {
			if newIDs.remove(file.id) != nil {
				newFiles.removeAll { $0.id == file.id }
			}
		}

		commitSelectionState(newFiles, newIDs)
		fileTogglePublisher.send(file)
	}

	/// Execute `work` while coalescing per-file callbacks into a single flush.
	@MainActor
	func performSelectionBatch(_ work: () -> Void) {
		guard !isSelectionBatching else { work(); return }
		isSelectionBatching = true
		work()
		isSelectionBatching = false
		flushPendingSelectionChanges()
	}

	@MainActor
	private func flushPendingSelectionChanges() {
		
		// Fast-exit ─ nothing queued
		if pendingSelectionAdds.isEmpty && pendingSelectionRemoves.isEmpty { return }
		
		// Start from the current snapshot
		var newArray      = selectedFiles
		var newIDSet      = selectedFileIDs
		
		// ➊ Removals ---------------------------------------------------------
		if !pendingSelectionRemoves.isEmpty {
			let removeIDs = Set(pendingSelectionRemoves.map(\.id))
			newArray.removeAll { removeIDs.contains($0.id) }
			newIDSet.subtract(removeIDs)
			
			// Notify listeners once per removed file (keeps UI in sync)
			for file in pendingSelectionRemoves { fileTogglePublisher.send(file) }
			pendingSelectionRemoves.removeAll()
		}
		
		// ➋ Additions --------------------------------------------------------
		if !pendingSelectionAdds.isEmpty {
			let toAppend = pendingSelectionAdds.filter { newIDSet.insert($0.id).inserted }
			newArray.append(contentsOf: toAppend)
			
			for file in toAppend { fileTogglePublisher.send(file) }
			pendingSelectionAdds.removeAll()
		}
		
		// ➌ Deduplicate (safety) then commit – single @Published write
		let unique: [FileViewModel]
		if newArray.count == newIDSet.count {
			unique = newArray
		} else {
			var seen = Set<UUID>()
			unique = newArray.filter { seen.insert($0.id).inserted }
		}
		
		// Atomic commit
		commitSelectionState(unique, newIDSet)
	}

	/// Installs the lightweight callback on a freshly created FileViewModel.
	/// The closure fires on the MainActor already (setIsChecked is @MainActor),
	/// so we call the helper directly—no extra Task hop that would escape the
	/// current selection batch.
	@MainActor
	private func attachSelectionCallback(to file: FileViewModel) {
		file.onCheckStateChanged = { [weak self] changed, isChecked in
			self?.handleCheckStateChanged(changed, isChecked: isChecked)
		}
	}

	// MARK: - Auto Codemap Support

	@MainActor
	private func resetAutoCodemapFiles(_ files: [FileViewModel]) {
		autoCodemapFiles = files
		autoCodemapFileIDs = Set(files.map(\.id))
		// Notify that codemap files changed so token counts can update
		codeMapUpdatePublisher.send(())
	}

	@MainActor
	func clearAutoCodemapFiles(disableAuto: Bool = true) {
		guard !autoCodemapFiles.isEmpty else { return }
		if disableAuto && codemapAutoEnabled {
			codemapAutoEnabled = false
		}
		resetAutoCodemapFiles([])
	}

	@MainActor
	func flushAutoCodemapSyncNowIfNeeded() {
		// Cancel any pending debounced task
		autoCodemapSyncTask?.cancel()
		autoCodemapSyncTask = nil
		// Only sync when auto mode is enabled
		if codemapAutoEnabled {
			// Recompute the auto-codemap set immediately
			syncAutoCodemaps()
		}
	}

	@MainActor
	private func addAutoCodemapFile(_ file: FileViewModel) {
		if autoCodemapFileIDs.insert(file.id).inserted {
			autoCodemapFiles.append(file)
			// Notify that codemap files changed so token counts can update
			codeMapUpdatePublisher.send(())
		}
	}

	@MainActor
	private func removeAutoCodemapFile(_ file: FileViewModel) {
		if autoCodemapFileIDs.remove(file.id) != nil {
			autoCodemapFiles.removeAll { $0.id == file.id }
			// Notify that codemap files changed so token counts can update
			codeMapUpdatePublisher.send(())
		}
	}

	@MainActor
	func isAutoCodemapFile(_ file: FileViewModel) -> Bool {
		autoCodemapFileIDs.contains(file.id)
	}

	@MainActor
	func enterManualCodemapMode() {
		if codemapAutoEnabled {
			// Preserve the current auto-codemap set; just stop auto-syncing.
			codemapAutoEnabled = false
			autoCodemapSyncTask?.cancel()
			autoCodemapSyncTask = nil
		} else {
			autoCodemapSyncTask?.cancel()
			autoCodemapSyncTask = nil
		}
	}

	@MainActor
	func validatedFileAPI(for file: FileViewModel) -> FileAPI? {
		guard file.hasAcceptedCodeMap, let api = file.fileAPI else { return nil }
		return api
	}

	@MainActor
	func validatedFileAPIsSnapshot(sorted: Bool = false) -> [FileAPI] {
		allFilesSnapshot(sorted: sorted).compactMap { validatedFileAPI(for: $0) }
	}

	@MainActor
	func validatedCurrentFileAPIs(from apis: [FileAPI]) -> [FileAPI] {
		guard !apis.isEmpty else { return [] }

		var seen = Set<String>()
		var validated: [FileAPI] = []
		validated.reserveCapacity(apis.count)

		for api in apis {
			let standardized = standardizedAPIFilePath(api)
			guard seen.insert(standardized).inserted,
				let file = findFileByFullPath(standardized),
				let attachedAPI = validatedFileAPI(for: file)
			else { continue }

			validated.append(attachedAPI)
		}

		return validated
	}

	@MainActor
	func cachedFileAPIs() -> [FileAPI] {
		validatedFileAPIsSnapshot(sorted: false)
	}

	@MainActor
	private func scheduleAutoCodemapSync() {
		guard codemapAutoEnabled else { return }
		autoCodemapSyncTask?.cancel()
		autoCodemapSyncTask = Task(priority: .utility) { [weak self] in
			// Debounce to coalesce rapid selection churn without blocking the main actor
			try? await Task.sleep(nanoseconds: 400_000_000) // 400ms debounce
			guard let self else { return }
			defer { self.autoCodemapSyncTask = nil }
			guard !Task.isCancelled else { return }
			guard self.codemapAutoEnabled else { return }
			self.syncAutoCodemaps()
		}
	}

	@MainActor
	private func syncAutoCodemaps() {
		guard codemapAutoEnabled else {
			resetAutoCodemapFiles([])
			return
		}

		let selectedFilesSnapshot = selectedFiles
		guard !selectedFilesSnapshot.isEmpty else {
			resetAutoCodemapFiles([])
			return
		}

		let selectedPaths = Set(selectedFilesSnapshot.map(\.standardizedFullPath))
		let allAPIs = cachedFileAPIs()
		guard !allAPIs.isEmpty else {
			resetAutoCodemapFiles([])
			return
		}

		let referencedPaths = CodeMapExtractor.resolveReferencedFilePaths(
			from: selectedFilesSnapshot,
			among: allAPIs
		)

		if referencedPaths.isEmpty {
			resetAutoCodemapFiles([])
			return
		}

		var unique = Set<UUID>()
		let resolved = referencedPaths.compactMap { standardizedPath -> FileViewModel? in
			guard !selectedPaths.contains(standardizedPath),
				let vm = fileHierarchyIndex.filesByFullPath[standardizedPath],
				unique.insert(vm.id).inserted
			else { return nil }
			return vm
		}

		resetAutoCodemapFiles(resolved)
	}

	@MainActor
	func getAllFilesForPrompt() -> [PromptFileEntry] {
		var result: [PromptFileEntry] = []
		let selectedIDs = Set(selectedFiles.map(\.id))

		for file in selectedFiles {
			let ranges = selectionSlicesByFileID[file.id]
			result.append(PromptFileEntry(file: file, isCodemap: false, ranges: ranges))
		}

		for file in autoCodemapFiles where !selectedIDs.contains(file.id) {
			result.append(PromptFileEntry(file: file, isCodemap: true, ranges: nil))
		}

		return result
	}

	// MARK: - Non-mutating prompt entry builder for headless plan
	
	/// Builds PromptFileEntry list from a StoredSelection snapshot without touching live state.
	/// Used by headless plan generation when the tab may not be active.
	@MainActor
	func buildPromptEntries(
		for selection: StoredSelection,
		codeMapUsage: CodeMapUsage,
		allFileAPIs: [FileAPI]
	) -> [PromptFileEntry] {
		var entries: [PromptFileEntry] = []
		var addedIDs = Set<UUID>()
		let normalizedSlices = standardizedStoredSelectionSlices(selection.slices)
		
		// 1. Resolve selected files from paths
		for path in selection.selectedPaths {
			let standardized = standardizedStoredSelectionPath(path)
			guard let file = fileHierarchyIndex.filesByFullPath[standardized] else { continue }
			guard addedIDs.insert(file.id).inserted else { continue }
			
			let ranges = normalizedSlices[standardized]
			entries.append(PromptFileEntry(file: file, isCodemap: false, ranges: ranges))
		}
		
		// 2. Resolve auto-codemap files from paths
		for path in selection.autoCodemapPaths {
			let standardized = standardizedStoredSelectionPath(path)
			guard let file = fileHierarchyIndex.filesByFullPath[standardized] else { continue }
			guard addedIDs.insert(file.id).inserted else { continue }
			
			entries.append(PromptFileEntry(file: file, isCodemap: true, ranges: nil))
		}
		
		// 3. Apply codeMapUsage filtering (same logic as existing buildPromptEntries)
		let selectedIDs = Set(selection.selectedPaths.compactMap { path -> UUID? in
			let standardized = standardizedStoredSelectionPath(path)
			return fileHierarchyIndex.filesByFullPath[standardized]?.id
		})
		
		switch codeMapUsage {
		case .none:
			entries.removeAll { $0.isCodemap }
			
		case .auto:
			break // Keep as-is
			
		case .selected:
			// In .selected mode:
			// - Selected files render as codemaps if fileAPI is available, otherwise as full content
			// - Auto-codemap (non-selected) entries are always dropped
			entries = entries.compactMap { entry in
				if selectedIDs.contains(entry.file.id) {
					// Only use codemap if an accepted FileAPI is attached; otherwise treat as full content
					let canCodemap = (validatedFileAPI(for: entry.file) != nil)
					return PromptFileEntry(
						file: entry.file,
						isCodemap: canCodemap,
						ranges: canCodemap ? nil : entry.ranges
					)
				}
				// Drop any codemap-only entries (auto-codemaps) in selected mode
				return nil
			}

		case .complete:
			var existingPaths = Set(entries.map { $0.file.standardizedFullPath })
			let selectedPaths = Set(standardizedStoredSelectionPaths(selection.selectedPaths))
			
			for api in validatedCurrentFileAPIs(from: allFileAPIs) {
				let standardized = standardizedAPIFilePath(api)
				if selectedPaths.contains(standardized) { continue }
				if existingPaths.contains(standardized) { continue }
				if let vm = fileHierarchyIndex.filesByFullPath[standardized] {
					entries.append(PromptFileEntry(file: vm, isCodemap: true, ranges: nil))
					existingPaths.insert(standardized)
				}
			}
		}
		
		return entries
	}

	@MainActor
	func snapshotSelection() -> StoredSelection {
		let selectedPaths = selectedFiles.map(\.standardizedFullPath)
		let autoPaths = autoCodemapFiles.map(\.standardizedFullPath)
		var slicesByPath: [String: [LineRange]] = [:]
		for file in selectedFiles {
			if let ranges = selectionSlicesByFileID[file.id], !ranges.isEmpty {
				slicesByPath[file.standardizedFullPath] = ranges
			}
		}
		return StoredSelection(
			selectedPaths: selectedPaths,
			autoCodemapPaths: autoPaths,
			slices: slicesByPath,
			codemapAutoEnabled: codemapAutoEnabled
		)
	}

	@MainActor
	private func applySelectionSnapshot(paths: [String], allowEmpty: Bool) async {
		if paths.isEmpty && !allowEmpty { return }
		let foundFiles = await findFiles(atPaths: paths)
		let targetFiles = Array(foundFiles.values)
		let targetIDs = Set(targetFiles.map(\.id))
		let currentIDs = selectedFileIDs
		let idsToDeselect = currentIDs.subtracting(targetIDs)
		let idsToSelect = targetIDs.subtracting(currentIDs)
		guard !idsToDeselect.isEmpty || !idsToSelect.isEmpty else { return }
		
		let filesToDeselect = selectedFiles.filter { idsToDeselect.contains($0.id) }
		let filesToSelect = targetFiles.filter { idsToSelect.contains($0.id) }
		
		await applySelectionDelta(filesToDeselect, selecting: false)
		await applySelectionDelta(filesToSelect, selecting: true)
		guard !Task.isCancelled else { return }
		
		var parentIDs = Set<UUID>()
		var parents: [FolderViewModel] = []
		for file in filesToDeselect {
			if let parent = file.parentFolder, parentIDs.insert(parent.id).inserted {
				parents.append(parent)
			}
		}
		for file in filesToSelect {
			if let parent = file.parentFolder, parentIDs.insert(parent.id).inserted {
				parents.append(parent)
			}
		}
		
		guard !parents.isEmpty else { return }
		let chunkSize = 500
		var index = 0
		while index < parents.count {
			guard !Task.isCancelled else { return }
			let end = min(index + chunkSize, parents.count)
			for parent in parents[index..<end] {
				recomputeAncestorStates(startingAt: parent)
			}
			index = end
			await Task.yield()
		}
	}
	
	@MainActor
	private func applySelectionDelta(_ files: [FileViewModel], selecting: Bool) async {
		guard !files.isEmpty else { return }
		let chunkSize = 500
		var index = 0
		while index < files.count {
			guard !Task.isCancelled else { return }
			let end = min(index + chunkSize, files.count)
			let chunk = files[index..<end]
			performSelectionBatch {
				for file in chunk {
					if selecting {
						if !file.isChecked {
							file.setIsChecked(true)
						}
					} else if file.isChecked {
						file.setIsChecked(false)
					}
				}
			}
			index = end
			await Task.yield()
		}
	}
	
	@MainActor
	func applyStoredSelection(_ stored: StoredSelection) async {
		#if DEBUG
		let applyStoredSelectionStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		var applySelectionSnapshotDuration = "notMeasured"
		#endif
		autoCodemapSyncTask?.cancel()
		codemapAutoEnabled = false

		#if DEBUG
		let applySelectionSnapshotStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
		#endif
		await applySelectionSnapshot(paths: stored.selectedPaths, allowEmpty: true)
		#if DEBUG
		applySelectionSnapshotDuration = applySelectionSnapshotStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
		WorkspaceRestorePerfLog.event(
			"selection.applyStoredSelection.selectionSnapshot",
			fields: [
				"selectedPaths": "\(stored.selectedPaths.count)",
				"duration": applySelectionSnapshotDuration
			]
		)
		#endif

		let restoredAutoCodemapFiles = standardizedStoredSelectionPaths(stored.autoCodemapPaths).compactMap { path in
			fileHierarchyIndex.filesByFullPath[path]
		}
		resetAutoCodemapFiles(restoredAutoCodemapFiles)

		selectionSlicesByFileID.removeAll()
		for (path, ranges) in standardizedStoredSelectionSlices(stored.slices) {
			guard let file = fileHierarchyIndex.filesByFullPath[path] else { continue }
			selectionSlicesByFileID[file.id] = ranges
		}
		requestSelectionSliceSnapshotRebuild(reason: "applyStoredSelection")

		codemapAutoEnabled = stored.codemapAutoEnabled
		if codemapAutoEnabled {
			scheduleAutoCodemapSync()
		}
		#if DEBUG
		WorkspaceRestorePerfLog.event(
			"selection.applyStoredSelection",
			fields: [
				"selectedPaths": "\(stored.selectedPaths.count)",
				"autoCodemapPaths": "\(stored.autoCodemapPaths.count)",
				"sliceFiles": "\(stored.slices.count)",
				"restoredAutoCodemapFiles": "\(restoredAutoCodemapFiles.count)",
				"codemapAutoEnabled": "\(stored.codemapAutoEnabled)",
				"selectionSnapshotDuration": applySelectionSnapshotDuration,
				"duration": applyStoredSelectionStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
			]
		)
		#endif
	}

	@MainActor
	func buildPromptEntries(
		codeMapUsage: CodeMapUsage,
		allFileAPIs: [FileAPI]
	) -> [PromptFileEntry] {
		var entries = getAllFilesForPrompt()
		let selectedIDs = Set(selectedFiles.map(\.id))

		switch codeMapUsage {
		case .none:
			entries.removeAll { $0.isCodemap }

		case .auto:
			break

		case .selected:
			// In .selected mode:
			// - Selected files render as codemaps if fileAPI is available, otherwise as full content
			// - Auto-codemap (non-selected) entries are always dropped
			entries = entries.compactMap { entry in
				if selectedIDs.contains(entry.file.id) {
					// Only use codemap if an accepted FileAPI is attached; otherwise treat as full content
					let canCodemap = (validatedFileAPI(for: entry.file) != nil)
					return PromptFileEntry(
						file: entry.file,
						isCodemap: canCodemap,
						ranges: canCodemap ? nil : entry.ranges
					)
				}
				// Drop any codemap-only entries (auto-codemaps) in selected mode
				return nil
			}

		case .complete:
			var filtered = entries
			var existingPaths = Set(filtered.map { $0.file.standardizedFullPath })
			let selectedPaths = Set(selectedFiles.map(\.standardizedFullPath))

			for api in validatedCurrentFileAPIs(from: allFileAPIs) {
				let standardized = standardizedAPIFilePath(api)
				if selectedPaths.contains(standardized) { continue }
				if existingPaths.contains(standardized) { continue }
				if let vm = findFileByFullPath(standardized) {
					filtered.append(PromptFileEntry(file: vm, isCodemap: true, ranges: nil))
					existingPaths.insert(standardized)
				}
			}

			entries = filtered
		}

		return entries
	}

	@MainActor
	func computeSelectedIDs(from stored: StoredSelection) -> Set<UUID> {
		var ids = Set<UUID>()
		for rawPath in stored.selectedPaths {
			let standardized = standardizedStoredSelectionPath(rawPath)
			if let file = fileHierarchyIndex.filesByFullPath[standardized] {
				ids.insert(file.id)
			}
		}
		return ids
	}

	@MainActor
	func setFileAsFullContent(_ file: FileViewModel) {
		// If switching from codemap to full content, disable auto mode
		if isAutoCodemapFile(file) {
			codemapAutoEnabled = false
		}

		performSelectionBatch {
			if !file.isChecked {
				file.setIsChecked(true)
			}
		}

		selectionSlicesByFileID.removeValue(forKey: file.id)
		removeAutoCodemapFile(file)
		requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
	}

	@MainActor
	func setFileAsCodemap(_ file: FileViewModel) {
		// Only allow files with codemap support to be added as codemaps
		guard file.supportsCodeMap else { return }

		performSelectionBatch {
			if file.isChecked {
				file.setIsChecked(false)
			}
		}

		selectionSlicesByFileID.removeValue(forKey: file.id)
		let wasAlreadyCodemap = isAutoCodemapFile(file)
		if !wasAlreadyCodemap {
			addAutoCodemapFile(file)
		}
		codemapAutoEnabled = false
		requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
	}

	@MainActor
	func removeCodemapFile(_ file: FileViewModel) {
		removeAutoCodemapFile(file)
	}

	@MainActor
	func removeFileFromAllSelections(_ file: FileViewModel) {
		// If auto-mode is on and the user is removing an auto-added file,
		// interpret this as a switch to manual mode.
		if codemapAutoEnabled && isAutoCodemapFile(file) {
			codemapAutoEnabled = false
		}

		performSelectionBatch {
			// Remove from selected files if present
			if file.isChecked {
				file.setIsChecked(false)
			}
			// Remove from auto-codemap files
			removeAutoCodemapFile(file)
			// Remove any slices for this file
			selectionSlicesByFileID.removeValue(forKey: file.id)
		}

		// Update parent folder states for UI consistency
		if let parent = file.parentFolder {
			recomputeAncestorStates(startingAt: parent)
		}
	}

	// MARK: - Incremental Cache Management
}


@MainActor
extension RepoFileManagerViewModel {
	/// O(1) lookup for files based on absolute-path index
	func findFileByRelativePath(_ relativePath: String) -> FileViewModel? {
		findFileByRelativePath(relativePath, scope: .allLoaded)
	}

	func findFileByRelativePath(
		_ relativePath: String,
		scope: LookupRootScope
	) -> FileViewModel? {
		let standardizedRel = StandardizedPath.relative(relativePath)
		for absPath in absolutePathCandidates(forRelativePath: standardizedRel, scope: scope) {
			if let vm = fileHierarchyIndex.filesByFullPath[absPath] {
				return vm
			}
		}
		return nil
	}
	
	/// O(1) lookup for folders based on absolute-path index
	func findFolderByRelativePath(_ relativePath: String) -> FolderViewModel? {
		findFolderByRelativePath(relativePath, scope: .allLoaded)
	}

	func findFolderByRelativePath(
		_ relativePath: String,
		scope: LookupRootScope
	) -> FolderViewModel? {
		let standardizedRel = StandardizedPath.relative(relativePath)
		for absPath in absolutePathCandidates(forRelativePath: standardizedRel, scope: scope) {
			if let vm = fileHierarchyIndex.foldersByFullPath[absPath] {
				return vm
			}
		}
		return nil
	}
	
	/// Unchanged: direct full-path lookup for files
	func findFileByFullPath(_ fullPath: String) -> FileViewModel? {
		let key = StandardizedPath.absolute(fullPath)
		return fileHierarchyIndex.filesByFullPath[key]
	}

	func resolveWorkspaceFileForTaggedPath(_ rawPath: String) -> FileViewModel? {
		let normalizedPath = normalizeUserInputPath(rawPath)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalizedPath.isEmpty else { return nil }

		let standardizedPath = (normalizedPath as NSString).standardizingPath
		if standardizedPath.hasPrefix("/") {
			return findFileByFullPath(standardizedPath)
		}

		if taggedPathLooksRootQualified(standardizedPath),
			let exactUnique = findFileByUniqueRelativePath(standardizedPath) {
			return exactUnique
		}

		if let exactRelative = findFileByRelativePath(standardizedPath) {
			return exactRelative
		}

		return findFileByUniqueRelativePath(standardizedPath)
	}
	
	/// Unchanged: direct full-path lookup for folders
	func findFolderByFullPath(_ fullPath: String) -> FolderViewModel? {
		let key = StandardizedPath.absolute(fullPath)
		return fileHierarchyIndex.foldersByFullPath[key]
	}

	private func findFileByUniqueRelativePath(_ path: String) -> FileViewModel? {
		let standardizedPath = StandardizedPath.relative(path)
		let matches = fileHierarchyIndex.filesByFullPath.values.filter {
			($0.uniqueRelativePath as NSString).standardizingPath == standardizedPath
		}
		guard matches.count == 1 else { return nil }
		return matches[0]
	}

	private func taggedPathLooksRootQualified(_ path: String) -> Bool {
		guard let firstComponent = StandardizedPath.relative(path).split(separator: "/").first else {
			return false
		}
		let rootAlias = String(firstComponent)
		return visibleRootFolders.contains { $0.name == rootAlias }
	}
	
	@MainActor
	public func findFolder(atPath path: String) -> FolderViewModel? {
		let normalized = normalizeUserInputPath(path)
		let standardized = (normalized as NSString).standardizingPath
		let isAbsolute = standardized.hasPrefix("/")
		if isAbsolute {
			return findFolderByFullPath(standardized)
		} else {
			return findFolderByRelativePath(standardized)
		}
	}

	@MainActor
	public func resolveFileForUserInput(
		_ userPath: String,
		profile: PathLocateProfile = .mcpRead,
		rootScopeOverride: LookupRootScope? = nil
	) async -> FileViewModel? {
		let trimmed = normalizeUserInputPath(userPath)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		let hits = await findFiles(
			atPaths: [trimmed],
			profile: profile,
			rootScopeOverride: rootScopeOverride
		)
		return hits[trimmed]
	}

	@MainActor
	public func resolveReadableFileForUserInput(
		_ userPath: String,
		profile: PathLocateProfile = .mcpRead,
		rootScopeOverride: LookupRootScope? = nil
	) async -> ReadableFileHandle? {
		let trimmed = normalizeUserInputPath(userPath)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }

		if profile == .mcpRead, let explicitSystemFile = resolveExplicitSystemFile(trimmed) {
			if let presentFile = await validateCatalogFileStillPresent(explicitSystemFile) {
				return .workspace(presentFile)
			}
		}

		if let workspaceFile = await resolveFileForUserInput(
			trimmed,
			profile: profile,
			rootScopeOverride: rootScopeOverride
		) {
			return .workspace(workspaceFile)
		}

		let lookupScope = effectiveLookupRootScope(for: profile, override: rootScopeOverride)
		if let reconciledFile = await reconcileExactDiskFileIfPresent(trimmed, rootScope: lookupScope) {
			return .workspace(reconciledFile)
		}

		guard trimmed.hasPrefix("/") else { return nil }
		return resolveAlwaysReadableExternalFile(atAbsolutePath: trimmed).map { .external($0) }
	}

	@MainActor
	func resolveAlwaysReadableExternalFolderDisplayPath(_ userPath: String) -> String? {
		let normalized = normalizeUserInputPath(userPath).trimmingCharacters(in: .whitespacesAndNewlines)
		guard normalized.hasPrefix("/") else { return nil }
		guard isAlwaysReadableExternalPath(normalized) else { return nil }

		let absolutePath = normalizedAlwaysReadableAbsolutePath(for: normalized)
		guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
			return nil
		}
		return AgentSupportDirectoryCatalog.displayPath(
			for: absolutePath,
			homeDirectoryURL: alwaysReadableHomeDirectoryURL
		)
	}

	@MainActor
	func displayPathForAlwaysReadableExternalPath(_ userPath: String) -> String {
		AgentSupportDirectoryCatalog.displayPath(
			for: normalizeUserInputPath(userPath),
			homeDirectoryURL: alwaysReadableHomeDirectoryURL
		)
	}

	@MainActor
	func isAlwaysReadableExternalPath(_ userPath: String) -> Bool {
		let normalized = normalizeUserInputPath(userPath).trimmingCharacters(in: .whitespacesAndNewlines)
		guard normalized.hasPrefix("/") else { return false }
		let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(
			homeDirectoryURL: alwaysReadableHomeDirectoryURL
		)
		return directories.contains {
			AgentSupportDirectoryCatalog.contains(
				absolutePath: normalized,
				in: $0
			)
		}
	}

	func readAlwaysReadableExternalFile(_ file: ExternalReadableFile) async throws -> String {
		let path = file.absolutePath
		return try await Task.detached(priority: .userInitiated) {
			let url = URL(fileURLWithPath: path)
			let data = try Data(contentsOf: url)
			if let decoded = String(data: data, encoding: .utf8) {
				return decoded
			}
			if let decoded = String(data: data, encoding: .unicode) {
				return decoded
			}
			return String(decoding: data, as: UTF8.self)
		}.value
	}

	@MainActor
	private func resolveAlwaysReadableExternalFile(atAbsolutePath path: String) -> ExternalReadableFile? {
		guard isAlwaysReadableExternalPath(path) else { return nil }
		let absolutePath = normalizedAlwaysReadableAbsolutePath(for: path)
		guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
			return nil
		}
		return ExternalReadableFile(
			absolutePath: absolutePath,
			displayPath: AgentSupportDirectoryCatalog.displayPath(
				for: absolutePath,
				homeDirectoryURL: alwaysReadableHomeDirectoryURL
			)
		)
	}

	@MainActor
	private func normalizedAlwaysReadableAbsolutePath(for path: String) -> String {
		let normalized = AgentSupportDirectoryCatalog.normalizedPath(for: path)
		if FileManager.default.fileExists(atPath: normalized) {
			return AgentSupportDirectoryCatalog.normalizedPath(
				for: URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardizedFileURL.path
			)
		}
		return normalized
	}

	@MainActor
	func openFileForMarkdownLink(_ target: MarkdownFileLinkTarget) async -> Bool {
		if let file = await resolveFileForMarkdownLink(target) {
			file.openInDefaultApp()
			return true
		}

		let standardizedPath = (target.normalizedPath as NSString).standardizingPath
		guard standardizedPath.hasPrefix("/") else { return false }

		let fileURL = URL(fileURLWithPath: standardizedPath)
		return NSWorkspace.shared.open(fileURL)
	}

	@MainActor
	private func resolveFileForMarkdownLink(_ target: MarkdownFileLinkTarget) async -> FileViewModel? {
		let normalizedPath = normalizeUserInputPath(target.normalizedPath)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalizedPath.isEmpty else { return nil }

		if let selected = resolveSelectedFileFirst(normalizedPath) {
			return selected
		}

		if normalizedPath.hasPrefix("/") {
			let standardizedPath = (normalizedPath as NSString).standardizingPath
			if let exact = findFileByFullPath(standardizedPath) {
				return exact
			}
		} else if let exact = findFileByRelativePath(normalizedPath) {
			return exact
		}

		if let matched = await resolveFileForUserInput(normalizedPath, profile: .uiAssisted) {
			return matched
		}

		guard !normalizedPath.hasPrefix("/") else { return nil }
		return await searchFallbackCandidates(for: normalizedPath).first
	}

	@MainActor
	private func resolveSelectedFileFirst(_ normalizedPath: String) -> FileViewModel? {
		let standardizedPath = (normalizedPath as NSString).standardizingPath

		if standardizedPath.hasPrefix("/") {
			if let exact = selectedFiles.first(where: { $0.standardizedFullPath == standardizedPath }) {
				return exact
			}
		} else {
			if let exactRelative = selectedFiles.first(where: { $0.standardizedRelativePath == standardizedPath }) {
				return exactRelative
			}
			if let exactUnique = selectedFiles.first(where: {
				($0.uniqueRelativePath as NSString).standardizingPath == standardizedPath
			}) {
				return exactUnique
			}
		}

		let basename = URL(fileURLWithPath: standardizedPath).lastPathComponent
		guard !basename.isEmpty else { return nil }

		let basenameMatches = selectedFiles.filter { $0.name.caseInsensitiveCompare(basename) == .orderedSame }
		return basenameMatches.count == 1 ? basenameMatches[0] : nil
	}

	@MainActor
	private func ensureMarkdownPathSearchIndex() async {
		let generation = currentHierarchyGenerationSignature()
		guard markdownPathSearchGeneration != generation || markdownPathSearchIndex == nil else {
			return
		}

		let files = fileHierarchyIndex.filesByFullPath.values.sorted {
			$0.standardizedFullPath.localizedStandardCompare($1.standardizedFullPath) == .orderedAscending
		}

		var entries: [MarkdownPathSearchEntry] = []
		entries.reserveCapacity(files.count * 2)

		for file in files {
			let relativePath = file.standardizedRelativePath
			entries.append(MarkdownPathSearchEntry(queryPath: relativePath, fileFullPath: file.standardizedFullPath))

			let uniqueRelativePath = (file.uniqueRelativePath as NSString).standardizingPath
			if uniqueRelativePath != relativePath {
				entries.append(MarkdownPathSearchEntry(queryPath: uniqueRelativePath, fileFullPath: file.standardizedFullPath))
			}
		}

		markdownPathSearchEntries = entries
		markdownPathSearchIndex = await PathSearchIndex(paths: entries.map(\.queryPath))
		markdownPathSearchGeneration = generation
	}

	@MainActor
	private func searchFallbackCandidates(for normalizedPath: String) async -> [FileViewModel] {
		await ensureMarkdownPathSearchIndex()
		guard let markdownPathSearchIndex else { return [] }

		var queries: [String] = []
		let standardizedPath = (normalizedPath as NSString).standardizingPath
		if !standardizedPath.isEmpty {
			queries.append(standardizedPath)
		}

		let basename = URL(fileURLWithPath: standardizedPath).lastPathComponent
		if !basename.isEmpty && !queries.contains(basename) {
			queries.append(basename)
		}

		var bestRankByFullPath: [String: Int] = [:]
		for query in queries {
			let results = await markdownPathSearchIndex.search(query, limit: 64)
			for (rank, candidate) in results.enumerated() {
				guard candidate.index >= 0, candidate.index < markdownPathSearchEntries.count else { continue }
				let entry = markdownPathSearchEntries[candidate.index]
				let currentRank = bestRankByFullPath[entry.fileFullPath] ?? .max
				if rank < currentRank {
					bestRankByFullPath[entry.fileFullPath] = rank
				}
			}
		}

		let selectedPaths = Set(selectedFiles.map(\.standardizedFullPath))
		let selectedRootIDs = Set(selectedFiles.map(\.rootIdentifier))
		let rankedCandidates: [(file: FileViewModel, isSelected: Bool, inSelectedRoot: Bool, rank: Int)] = bestRankByFullPath.compactMap { fullPath, rank in
			guard let file = fileHierarchyIndex.filesByFullPath[fullPath] else { return nil }
			return (
				file: file,
				isSelected: selectedPaths.contains(file.standardizedFullPath),
				inSelectedRoot: selectedRootIDs.contains(file.rootIdentifier),
				rank: rank
			)
		}

		return rankedCandidates
			.sorted { lhs, rhs in
				if lhs.isSelected != rhs.isSelected {
					return lhs.isSelected && !rhs.isSelected
				}
				if lhs.inSelectedRoot != rhs.inSelectedRoot {
					return lhs.inSelectedRoot && !rhs.inSelectedRoot
				}
				if lhs.rank != rhs.rank {
					return lhs.rank < rhs.rank
				}
				return lhs.file.standardizedFullPath.localizedStandardCompare(rhs.file.standardizedFullPath) == .orderedAscending
			}
			.map(\.file)
	}

	@MainActor
	public func resolveFolderForUserInput(
		_ userPath: String,
		rootScope: LookupRootScope = .visibleWorkspace
	) -> FolderViewModel? {
		resolveFolderInput(userPath, rootScope: rootScope).folder
	}

	@MainActor
	private func resolveFolderInput(
		_ path: String,
		rootScope: LookupRootScope = .visibleWorkspace
	) -> (folder: FolderViewModel?, displayPath: String?, issue: PathResolutionIssue?) {
		let normalized = normalizeUserInputPath(path)
		let cleaned = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !cleaned.isEmpty else { return (nil, nil, .emptyInput) }

		if let explicitResolution = resolveExplicitSystemPath(cleaned),
		   let folder = findFolderByFullPath(explicitResolution.standardizedAbsolutePath) {
			return (folder, mcpDisplayPath(for: folder), nil)
		}

		if let issue = exactPathResolutionIssue(for: cleaned, kind: .folder, rootScope: rootScope) {
			return (nil, nil, issue)
		}
		
		if cleaned.hasPrefix("/") {
			let standardized = (cleaned as NSString).standardizingPath
			if let folder = findFolderByFullPath(standardized) {
				return (folder, clientDisplayPath(for: folder), nil)
			}
			if let aliasResolution = resolveLeadingSlashRootAlias(from: standardized, requireRemainder: false) {
				switch aliasResolution {
				case .bareRoot(let root, _):
					if let folder = rootFolders.first(where: { $0.id == root.id }) {
						return (folder, clientDisplayPath(root: root, relativePath: ""), nil)
					}
				case .prefixed(let root, _, let remainder):
					let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
					if let folder = findFolderByFullPath(abs) {
						return (folder, clientDisplayPath(root: root, relativePath: folder.relativePath), nil)
					}
				case .ambiguous(let alias, let matchingRoots):
					return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
				case .notAliasPrefixed:
					break
				}
			}
			let absoluteIssue = unmatchedAbsolutePathIssue(for: standardized, rawInput: path)
			switch absoluteIssue {
			case .pathOutsideWorkspace:
				return (nil, nil, absoluteIssue)
			case .ambiguousAlias, .unresolved, .unsupportedPseudoAbsoluteAlias:
				break
			default:
				break
			}
		}
		
		switch resolveVisibleRootAlias(cleaned, requireRemainder: false, disambiguateRealSubpath: false) {
		case .bareRoot(let root, _):
			if let folder = rootFolders.first(where: { $0.id == root.id }) {
				return (folder, clientDisplayPath(root: root, relativePath: ""), nil)
			}
		case .prefixed(let root, _, let remainder):
			let abs = ((root.standardizedFullPath as NSString).appendingPathComponent(remainder) as NSString).standardizingPath
			if let folder = findFolderByFullPath(abs) {
				return (folder, clientDisplayPath(root: root, relativePath: folder.relativePath), nil)
			}
			let literalMatches = literalRelativeFolderMatches(for: cleaned)
			if literalMatches.count == 1, let folder = literalMatches.first {
				return (folder, clientDisplayPath(for: folder), nil)
			}
		case .ambiguous(let alias, let matchingRoots):
			return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
		case .notAliasPrefixed:
			break
		}
		
		if let folder = findFolderByRelativePath(cleaned, scope: rootScope) {
			return (folder, mcpDisplayPath(for: folder), nil)
		}
		
		return (nil, nil, nil)
	}

	@MainActor
	func resolveFilesForFolderInput(
		_ path: String,
		rootScope: LookupRootScope = .visibleWorkspace
	) async -> FolderInputResolution {
		let direct = resolveFolderInput(path, rootScope: rootScope)
		if let folder = direct.folder {
			return FolderInputResolution(
				files: getFilesRecursively(under: folder),
				handled: true,
				displayPath: direct.displayPath,
				issue: nil
			)
		}
		if let issue = direct.issue {
			return FolderInputResolution(files: [], handled: false, displayPath: nil, issue: issue)
		}
		
		let cleaned = normalizeUserInputPath(path).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !cleaned.isEmpty else {
			return FolderInputResolution(files: [], handled: false, displayPath: nil, issue: .emptyInput)
		}

		if let issue = exactPathResolutionIssue(for: cleaned, kind: .folder, rootScope: rootScope) {
			return FolderInputResolution(files: [], handled: false, displayPath: nil, issue: issue)
		}
		
		if let loc = await getFileSystemServiceForRelativePath(
			cleaned,
			exactMatchOnly: false,
			profile: .mcpSelection,
			rootScopeOverride: rootScope
		),
		   let folder = resolveFolder(at: loc) {
			return FolderInputResolution(
				files: getFilesRecursively(under: folder),
				handled: true,
				displayPath: mcpDisplayPath(for: folder),
				issue: nil
			)
		}
		
		return FolderInputResolution(files: [], handled: false, displayPath: nil, issue: .unresolved(input: path))
	}

	@MainActor
	func applyCodemapOnlySelection(paths: [String]) async {
		guard !paths.isEmpty else { return }

		var filesToScan: [FileViewModel] = []
		var seen = Set<UUID>()
		var didResolveAny = false

		for raw in paths {
			var handled = false
			if let file = await resolveFileForUserInput(raw) {
				handled = true
				if !didResolveAny {
					enterManualCodemapMode()
					didResolveAny = true
				}
				if seen.insert(file.id).inserted {
					if file.fileAPI == nil {
						filesToScan.append(file)
					}
					setFileAsCodemap(file)
				}
			} else {
				let folderResolution = await resolveFilesForFolderInput(raw, rootScope: .visibleWorkspace)
				if folderResolution.handled {
					handled = true
					if !didResolveAny {
						enterManualCodemapMode()
						didResolveAny = true
					}
				}
				for file in folderResolution.files {
					if seen.insert(file.id).inserted {
						if file.fileAPI == nil {
							filesToScan.append(file)
						}
						setFileAsCodemap(file)
					}
				}
			}

			if !handled {
				continue
			}
		}

		if !filesToScan.isEmpty {
			requestCodemapScan(for: filesToScan)
		}
	}
}

enum StrictWorkspaceFileContentError: Error, LocalizedError {
	case serviceUnavailable(rootPath: String)
	case fileMissing(path: String)
	case readFailed(path: String, underlying: Error)

	var errorDescription: String? {
		switch self {
		case .serviceUnavailable(let rootPath):
			return "File system service unavailable for '\(rootPath)'."
		case .fileMissing(let path):
			return "File not found: '\(path)'."
		case .readFailed(let path, let underlying):
			return "Cannot read '\(path)': \(underlying.localizedDescription)"
		}
	}
}

enum FileManagerError: Error, LocalizedError {
	case failedToLoadFolder(Error)
	case failedToLoadFile(Error)
	case fileSystemServiceNotFound
	case failedToLoadContent
	// New: richer, contextual variant used by MCP tools and FS ops
	case fileSystemServiceNotFoundWithContext(String)

	public var errorDescription: String? {
		switch self {
		case .failedToLoadFolder(let err):
			return "Failed to load folder: \(err.localizedDescription)"
		case .failedToLoadFile(let err):
			return "Failed to load file: \(err.localizedDescription)"
		case .fileSystemServiceNotFound:
			return "No matching workspace folder for the requested path."
		case .failedToLoadContent:
			return "Failed to load content."
		case .fileSystemServiceNotFoundWithContext(let context):
			return context
		}
	}
}

struct PathLocation {
	let rootPath: String
	let correctedPath: String
	let rootIdentifier: UUID?
}

@MainActor
extension PathLocation {
	var absolutePath: String {
		let stdRoot = (rootPath as NSString).standardizingPath
		if correctedPath.hasPrefix("/") {
			return (correctedPath as NSString).standardizingPath
		}
		return ((stdRoot as NSString).appendingPathComponent(correctedPath) as NSString).standardizingPath
	}
	
	func validate(against fileSystemServices: [URL: FileSystemService]) -> Bool {
		let absCandidate = absolutePath
		
		// Check if the absolute candidate is under any service root
		return fileSystemServices.keys.contains { url in
			let root = (url.path as NSString).standardizingPath
			return absCandidate == root || absCandidate.hasPrefix(root + "/")
		}
	}
	
	func validate(against fileSystemServices: [String: FileSystemService]) -> Bool {
		let absCandidate = absolutePath
		
		return fileSystemServices.keys.contains { rootKey in
			let root = (rootKey as NSString).standardizingPath
			return absCandidate == root || absCandidate.hasPrefix(root + "/")
		}
	}
}

extension Array {
	func chunks(ofCount count: Int) -> [ArraySlice<Element>] {
		stride(from: 0, to: self.count, by: count).map {
			self[($0 ..< Swift.min($0 + count, self.count))]
		}
	}
}

@MainActor
extension RepoFileManagerViewModel {

	/// Appends `fullPath` (converted to a root-relative path) to the owning
	/// folder’s **.repo_ignore** file, creating it when necessary.
	/// The operation is carried out by the appropriate `FileSystemService`;
	/// the UI layer never touches the file-system directly.
	@MainActor
	func ignorePath(fullPath: String, isDirectory: Bool) async {

		// (1) Find the *deepest* root that owns this path
		guard let root = rootFolders
				.filter({ fullPath.isDescendant(of: $0.fullPath) })
				.sorted(by: { $0.fullPath.count > $1.fullPath.count })
				.first
		else { return }

		let rel = String(
			fullPath.dropFirst(root.fullPath.count)
				.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		)

		// If empty, user tried to ignore the root itself – bail out
		guard !rel.isEmpty else { return }

		let finalLine = isDirectory ? rel + "/" : rel
		let svcRelPath = ".repo_ignore"

		guard let service = getFileSystemService(for: root.fullPath) else { return }

		do {
			let ignoreExists = await service.fileExistsOnDisk(relativePath: svcRelPath)

			if ignoreExists {
				// Read current content (might be nil for binary / empty)
				let existing = (try await service.loadContent(ofRelativePath: svcRelPath)) ?? ""
				// Check duplication
				let alreadyPresent = existing
					.components(separatedBy: .newlines)
					.contains { $0.trimmingCharacters(in: .whitespaces) == finalLine }

				if alreadyPresent { return }   // nothing to do

				let needsNL = existing.isEmpty ? "" :
							(existing.hasSuffix("\n") ? "" : "\n")

				let newContent = existing + needsNL + finalLine + "\n"
				try await service.editFile(atRelativePath: svcRelPath, newContent: newContent)

			} else {
				let newContent = finalLine + "\n"
				try await service.createFile(atRelativePath: svcRelPath, content: newContent)
			}

			// Refresh ignore rules for this service immediately
			try await service.refreshIgnoreRules()
			// Let the rest of the app know something changed
			requestRefresh()

		} catch {
			print("Failed to update .repo_ignore – \(error)")
		}
	}

	@MainActor
	private func scheduleSliceRebaseForModifiedFile(
		_ file: FileViewModel,
		relativePath: String,
		fsService: FileSystemService
	) {
		let fullPath = file.standardizedFullPath
		guard shouldScheduleSliceRebase(for: file, fullPath: fullPath) else { return }
		sliceRebaseTasksByFullPath[fullPath]?.cancel()

		let taskID = UUID()
		sliceRebaseTaskIDsByFullPath[fullPath] = taskID

		let task = Task { [weak self] in
			defer {
				Task { @MainActor [weak self] in
					guard let self else { return }
					guard self.sliceRebaseTaskIDsByFullPath[fullPath] == taskID else { return }
					self.sliceRebaseTasksByFullPath.removeValue(forKey: fullPath)
					self.sliceRebaseTaskIDsByFullPath.removeValue(forKey: fullPath)
				}
			}
			try? await Task.sleep(nanoseconds: 300_000_000)
			guard let self else { return }
			guard !Task.isCancelled else { return }
			let hasSlices = await self.hasAnySlicesForFile(file)
			guard !Task.isCancelled else { return }
			guard self.sliceRebaseTaskIDsByFullPath[fullPath] == taskID else { return }
			guard hasSlices else {
				self.noSlicesKnownRevisionByFullPath[fullPath] = self.partitionSliceSaveRevision
				return
			}
			self.noSlicesKnownRevisionByFullPath.removeValue(forKey: fullPath)
			await self.rebaseSlicesForModifiedFile(
				file,
				relativePath: relativePath,
				fsService: fsService,
				expectedTaskID: taskID
			)
		}

		sliceRebaseTasksByFullPath[fullPath] = task
	}

	/// Waits for pending slice-rebase tasks that affect currently selected files.
	/// Used by selection/reporting paths so line-range metadata reflects post-edit rebases.
	@MainActor
	func waitForPendingSliceRebasesAffectingSelection() async {
		let selectedFullPaths = Set(selectedFiles.map(\.standardizedFullPath))
		await waitForPendingSliceRebases(affectingFullPaths: selectedFullPaths)
	}

	/// Waits for pending slice-rebase tasks affecting candidate file paths.
	/// Candidates can be absolute full paths or relative paths.
	@MainActor
	func waitForPendingSliceRebases(affectingCandidatePaths candidatePaths: [String]) async {
		let fullPaths = normalizedFullPathsForSliceRebaseWait(from: candidatePaths)
		await waitForPendingSliceRebases(affectingFullPaths: fullPaths)
	}

	@MainActor
	private func waitForPendingSliceRebases(affectingFullPaths fullPaths: Set<String>) async {
		guard !fullPaths.isEmpty else { return }
		let pending = sliceRebaseTasksByFullPath.compactMap { path, task -> Task<Void, Never>? in
			fullPaths.contains(path) ? task : nil
		}
		guard !pending.isEmpty else { return }

		for task in pending {
			await task.value
		}
	}

	@MainActor
	private func normalizedFullPathsForSliceRebaseWait(from candidatePaths: [String]) -> Set<String> {
		var result: Set<String> = []
		for raw in candidatePaths {
			let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			let standardized = (trimmed as NSString).standardizingPath

			if standardized.hasPrefix("/") {
				result.insert(standardized)
				continue
			}

			if let file = findFileByRelativePath(standardized) {
				result.insert(file.standardizedFullPath)
				continue
			}

			if let full = findFullPath(for: standardized) {
				result.insert((full as NSString).standardizingPath)
			}
		}
		return result
	}

	@MainActor
	private func shouldScheduleSliceRebase(for file: FileViewModel, fullPath: String) -> Bool {
		if hasLikelySlicesForFile(file) {
			return true
		}

		// Conservative skip: only skip when this exact file was already confirmed
		// as "no slices" and no partition save has happened since.
		if noSlicesKnownRevisionByFullPath[fullPath] == partitionSliceSaveRevision {
			return false
		}
		return true
	}

	@MainActor
	private func scopesForSliceRebase(workspaceID: UUID) -> [PartitionScope] {
		var scopes: [PartitionScope] = []

		if let activeScope = try? currentPartitionScope() {
			scopes.append(activeScope)
		}
		scopes.append(PartitionScope(workspaceID: workspaceID))
		if let tabs = workspaceManager?.activeWorkspace?.composeTabs {
			for tab in tabs {
				scopes.append(PartitionScope(workspaceID: workspaceID, tabID: tab.id))
			}
		}

		var deduped: [PartitionScope] = []
		for scope in scopes where !deduped.contains(where: { $0 == scope }) {
			deduped.append(scope)
		}
		return deduped
	}

	@MainActor
	private func hasLikelySlicesForFile(_ file: FileViewModel) -> Bool {
		let rootKey = file.standardizedRootFolderPath
		let relKey = file.standardizedRelativePath
		let fullPath = file.standardizedFullPath

		if let inMemory = currentSlicesByRoot[rootKey]?[relKey], !inMemory.ranges.isEmpty {
			return true
		}

		if let tabs = workspaceManager?.activeWorkspace?.composeTabs {
			for tab in tabs {
				if let slices = tab.selection.slices.first(where: { (($0.key as NSString).standardizingPath) == fullPath })?.value,
					!slices.isEmpty {
					return true
				}
			}
		}

		return false
	}

	@MainActor
	private func hasAnySlicesForFile(_ file: FileViewModel) async -> Bool {
		if hasLikelySlicesForFile(file) {
			return true
		}

		guard let workspaceID = currentWorkspaceID else { return false }
		let rootKey = file.standardizedRootFolderPath
		let relKey = file.standardizedRelativePath

		for scope in scopesForSliceRebase(workspaceID: workspaceID) {
			guard !Task.isCancelled else { return false }
			let data = await partitionStore.load(forRoot: rootKey, scope: scope)
			if let stored = data.files[relKey], !stored.ranges.isEmpty {
				return true
			}
		}

		return false
	}

	@MainActor
	private func rebaseSlicesForModifiedFile(
		_ file: FileViewModel,
		relativePath: String,
		fsService: FileSystemService,
		expectedTaskID: UUID
	) async {
		guard let workspaceID = currentWorkspaceID else { return }

		let rootKey = file.standardizedRootFolderPath
		let relKey = file.standardizedRelativePath
		let fullPath = file.standardizedFullPath
		guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }
		let activeScope = try? currentPartitionScope()
		let fileModificationTime = file.modificationDate.timeIntervalSince1970

		let oldSnapshot = await file.cachedContentSnapshot()
		let oldText = oldSnapshot.content
		let loadedNewText = try? await fsService.loadContent(ofRelativePath: relativePath)
		let canRebase = (loadedNewText != nil)
		let newText = loadedNewText ?? ""

		var activeScopeChanged = false

		for scope in scopesForSliceRebase(workspaceID: workspaceID) {
			guard !Task.isCancelled else { return }
			guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }
			let data = await partitionStore.load(forRoot: rootKey, scope: scope)
			guard let stored = data.files[relKey], !stored.ranges.isEmpty else { continue }

			let storedRanges = stored.ranges
			let storedAnchors = stored.anchors
			let oldTextSnapshot = oldText
			let newTextSnapshot = newText
			let canRebaseSnapshot = canRebase

			let computed: (ranges: [LineRange], anchors: [SliceAnchor]?) = await Task.detached(priority: .utility) { [storedRanges, storedAnchors, oldTextSnapshot, newTextSnapshot, canRebaseSnapshot] in
				if Task.isCancelled {
					return (storedRanges, storedAnchors)
				}
				let nextRanges: [LineRange]
				if canRebaseSnapshot {
					let result = SliceRebaseEngine.rebase(
						oldText: oldTextSnapshot,
						newText: newTextSnapshot,
						oldRanges: storedRanges,
						anchors: storedAnchors
					)
					nextRanges = result.rebased
				} else {
					nextRanges = []
				}

				let normalizedRanges = SliceRangeMath.normalize(nextRanges)
				let nextAnchors: [SliceAnchor]? = {
					guard canRebaseSnapshot, !normalizedRanges.isEmpty else { return nil }
					if Task.isCancelled { return storedAnchors }
					return SliceRebaseEngine.buildAnchors(content: newTextSnapshot, ranges: normalizedRanges)
				}()

				return (normalizedRanges, nextAnchors)
			}.value

			guard !Task.isCancelled else { return }
			guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }

			let normalizedRanges = computed.ranges
			let nextAnchors = computed.anchors
			if normalizedRanges == storedRanges, nextAnchors == storedAnchors {
				continue
			}

			do {
				let post = try await partitionStore.apply(
					forRoot: rootKey,
					scope: scope,
					updates: [
						relKey: PartitionStore.SliceUpdate(
							ranges: normalizedRanges,
							fileModificationTime: fileModificationTime,
							anchors: nextAnchors
						)
					],
					mode: .setPaths
				)

				if let activeScope, scope == activeScope {
					activeScopeChanged = true
					if post.isEmpty {
						currentSlicesByRoot.removeValue(forKey: rootKey)
					} else {
						currentSlicesByRoot[rootKey] = post
					}
				}
			} catch {
				if Self.isLoggingEnabled {
					print("Failed to rebase slices for \(relKey) in scope \(String(describing: scope.tabID)) – \(error)")
				}
			}
		}

		if activeScopeChanged {
			requestSelectionSliceSnapshotRebuild(reason: "selection.slicesSnapshot")
		}

		// Always rebase tab-stored slices when this file has any slices.
		// Virtual/background tabs can carry slice state in tab selection storage
		// before partition entries exist for that tab scope.
		if canRebase {
			guard !Task.isCancelled else { return }
			guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }
			await workspaceManager?.rebaseSlicesForFileAcrossTabs(
				fullPath: fullPath,
				asyncTransform: { current in
					await Task.detached(priority: .utility) { [oldText, newText, current] in
						SliceRebaseEngine.rebase(
							oldText: oldText,
							newText: newText,
							oldRanges: current,
							anchors: nil
						).rebased
					}.value
				}
			)
		} else {
			guard !Task.isCancelled else { return }
			guard sliceRebaseTaskIDsByFullPath[fullPath] == expectedTaskID else { return }
			workspaceManager?.rebaseSlicesForFileAcrossTabs(fullPath: fullPath) { _ in [] }
		}
	}
	
	private func subscribeToFileSystemPreferenceChanges() {
		fileSystemSettingsCancellable = NotificationCenter.default
			.publisher(for: .appSettingsFileSystemPreferencesDidChange)
			.sink { [weak self] _ in
				guard let self else { return }
				Task { @MainActor in
					self.syncFileSystemPreferencesFromGlobalSettings()
					self.requestFileSystemSettingsRefresh()
				}
			}
	}

	@MainActor
	private func syncFileSystemPreferencesFromGlobalSettings() {
		let settings = GlobalSettingsStore.shared.fileSystemSettingsSnapshot()
		respectGitignore = settings.respectGitignore
		respectRepoIgnore = settings.respectRepoIgnore
		respectCursorignore = settings.respectCursorignore
		enableHierarchicalIgnores = settings.enableHierarchicalIgnores
		skipSymlinks = settings.skipSymlinks
		showEmptyFolders = settings.showEmptyFolders
	}

	private func subscribeToPartitionStoreSaves() {
		partitionStoreSaveCancellable = NotificationCenter.default
			.publisher(for: PartitionStore.didSaveNotification)
			.sink { [weak self] note in
				guard let self else { return }
				Task { @MainActor in
					// Workspace must match
					guard let wsAny = note.userInfo?[PartitionStore.notifWorkspaceIDKey],
						let ws = wsAny as? UUID else { return }
					guard ws == self.currentWorkspaceID else { return }
					self.partitionSliceSaveRevision &+= 1

					// Ignore our own writes to avoid redundant reload churn in this VM.
					if let sourceAny = note.userInfo?[PartitionStore.notifSourceIDKey],
						let sourceID = sourceAny as? UUID,
						sourceID == self.partitionStore.notificationSourceID {
						return
					}

					guard let rootAny = note.userInfo?[PartitionStore.notifRootPathKey],
						let nsRoot = rootAny as? String else { return }
					let stdRoot = (nsRoot as NSString).standardizingPath
					// Only refresh if this root folder is actually loaded in this window
					guard self.isRootFolderLoaded(stdRoot) else { return }

					// Tab must match (nil == nil is fine)
					let tabAny = note.userInfo?[PartitionStore.notifTabIDKey]
					let eventTab = tabAny as? UUID
					guard eventTab == self.currentTabID else { return }

					await self.refreshSlicesFromDisk(forRootURL: URL(fileURLWithPath: stdRoot))
				}
			}
	}

#if DEBUG
	@MainActor
	func _testHasAnySlicesForFile(_ file: FileViewModel) async -> Bool {
		await hasAnySlicesForFile(file)
	}

	@MainActor
	func _testShouldScheduleSliceRebase(_ file: FileViewModel) -> Bool {
		let fullPath = file.standardizedFullPath
		return shouldScheduleSliceRebase(for: file, fullPath: fullPath)
	}

	@MainActor
	func _testMarkKnownNoSlices(_ file: FileViewModel) {
		let fullPath = file.standardizedFullPath
		noSlicesKnownRevisionByFullPath[fullPath] = partitionSliceSaveRevision
	}

	@MainActor
	func _testBumpPartitionSliceSaveRevision() {
		partitionSliceSaveRevision &+= 1
	}

	@MainActor
	func _testPersistSlicesForScope(
		rootPath: String,
		scope: PartitionScope,
		relativePath: String,
		ranges: [LineRange]
	) async throws {
		_ = try await partitionStore.apply(
			forRoot: rootPath,
			scope: scope,
			updates: [
				relativePath: PartitionStore.SliceUpdate(
					ranges: ranges,
					fileModificationTime: nil,
					anchors: nil
				)
			],
			mode: .setPaths
		)
	}
#endif
}
