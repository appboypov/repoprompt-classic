import SwiftUI
import Combine
import Foundation

// Wildmatch flags for pattern matching
private let WM_NOESCAPE: UInt32    = 0x01
private let WM_PATHNAME: UInt32    = 0x02
private let WM_CASEFOLD: UInt32    = 0x08  // Corrected from 0x10
private let WM_WILDSTAR: UInt32    = 0x20  // Corrected from 0x40
private let WM_MATCH: Int32 = 0

@MainActor
class SearchFileTreeViewModel: ObservableObject {
	private var cancellables = Set<AnyCancellable>()
	weak var fileManager: RepoFileManagerViewModel?
	
	// Published properties for UI
	@Published var rootFolders: [SearchFolderViewModel] = []
	@Published var searchText: String = ""
	@Published var isSearching: Bool = false
	@Published var noResultsFound: Bool = false
	@Published var hasSearchResults: Bool = false
	
	private var searchTask: Task<Void, Never>?
	private var pendingSearchRefresh = false

	// Task used to debounce heavy search rebuild when workspace switches
	private var workspaceSwitchTask: Task<Void, Never>? = nil
	
	// *** NEW ***
	// Instead of recursing from the root to find a toggled item,
	// build a direct ID -> node dictionary for quick lookups.
	private var folderIndex: [UUID : SearchFolderViewModel] = [:]
	private var fileIndex:   [UUID : SearchFileViewModel]   = [:]
	
	// Per-root snapshot caching
	private struct RootSnapshotCacheEntry {
		let rootID: UUID
		let rootPath: String       // standardized full path
		var generation: UInt64     // per-root generation value
		var snapshot: SnapshotFolder
	}
	
	private var rootSnapshotCache: [UUID: RootSnapshotCacheEntry] = [:]
	
	// OPTIMIZATION 2: Pre-compiled wildcard pattern caching
	// Cache the parsed query to avoid recompiling for every file
	private var cachedQuery: (raw: String, parsed: ParsedQuery)? = nil
	
	// Fast path search index for >1k files
	private var pathSearchIndex: PathSearchIndex?
	private var flatFilesPath: [(file: SnapshotFile, folderPath: [SnapshotFolder])] = []  // Full path info
	
	// Configurable constants
	private static let resultLimit: Int = 300
	private nonisolated static var fuzzyThreshold: Double { 0.85 }
	
	// Query parsing helper
	private struct ParsedQuery {
		let raw: String
		let lowered: String
		let hasSlash: Bool
		let isWildcard: Bool
	}
	
	init() {
		setupSearchPublisher()
	}
	
	private var workspaceManager: WorkspaceManagerViewModel?   // NEW
	
	// Parse query to extract metadata
	private func parseQuery(_ s: String) -> ParsedQuery {
		// OPTIMIZATION 2: Return cached query if it matches
		if let cached = cachedQuery, cached.raw == s {
			return cached.parsed
		}
		
		let trimmed = s.trimmingCharacters(in: .whitespaces)
		let lowered = trimmed.lowercased()
		let hasSlash = trimmed.contains("/")
		let isWildcard = trimmed.contains("*") || trimmed.contains("?")
		
		let parsed = ParsedQuery(
			raw: trimmed,
			lowered: lowered,
			hasSlash: hasSlash,
			isWildcard: isWildcard
		)
		
		// Cache the parsed query
		cachedQuery = (raw: s, parsed: parsed)
		
		return parsed
	}
	
	// Score a file match based on hierarchical relevance using C implementation
	private func scoreMatch(of snap: SnapshotFile, against q: ParsedQuery) -> Int? {
		let score = snap.name.withCString { namePtr in
			snap.relativePath.withCString { pathPtr in
				snap.nameLower.withCString { nameLowerPtr in
					snap.relativePathLower.withCString { pathLowerPtr in
						q.raw.withCString { queryPtr in
							q.lowered.withCString { queryLowerPtr in
								Int(repo_score_match(namePtr, pathPtr, 
													nameLowerPtr, pathLowerPtr,
													queryPtr, queryLowerPtr,
													q.hasSlash, q.isWildcard, 
													Self.fuzzyThreshold))
							}
						}
					}
				}
			}
		}
		
		return score > 0 ? score : nil
	}
	
	/// Sets the workspace manager and binds to its "workspaceDidSwitch" event.
	/// Sets the workspace manager and binds to its "workspaceDidSwitch" event.
	func setWorkspaceManager(_ manager: WorkspaceManagerViewModel) {
		self.workspaceManager = manager
		/*
		// Persist query *before* the workspace is saved
		manager.addBeforeSaveListener { [weak self, weak manager] workspace in
			guard let self, let mgr = manager else { return }
			mgr.setLastSearchQuery(self.searchText)
		}
		*/
		
		// Restore query *after* workspace has switched
		manager.addWorkspaceDidSwitchListener(label: "search") { [weak self] newWorkspace in
			guard let self else { return }
			self.cancelSearch()
			/*
			// Invalidate cache when workspace changes
			self.invalidateSnapshotCache()
			// Cancel any pending delayed task and start a fresh one
			self.workspaceSwitchTask?.cancel()
			self.workspaceSwitchTask = Task { @MainActor [weak self, weak manager] in
				// Give the UI a brief moment to settle so we don't drop a frame
				try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 s
				guard let self, let mgr = manager else { return }
				self.cancelSearch()                   // reset state safely
				self.searchText = mgr.getLastSearchQuery() ?? "" // will trigger new search
			}
			*/
		}
	}
	
	func setFileManager(_ fileManager: RepoFileManagerViewModel) {
		self.fileManager = fileManager
		// New FM: reset all search caches
		resetCaches(scope: .fileManagerChanged)

		fileManager.fileTogglePublisher
			.sink { [weak self] toggledFile in
				Task { @MainActor in
					self?.synchronizeFileState(toggledFile)
				}
			}
			.store(in: &cancellables)
		
		fileManager.folderRefreshPublisher
			.sink { [weak self] updatedFolder in
				Task { @MainActor in
					// Note: Cache invalidation happens via fileSystemChangedPublisher
					self?.performSearch(cancelExisting: false)	// Re-run the same search with fresh snapshot
				}
			}
			.store(in: &cancellables)
		

		// Re-perform search once a folder has completely finished (re)loading
		fileManager.folderDidFinishLoadingPublisher
			.sink { [weak self] _ in
				Task { @MainActor in
					// Note: Cache invalidation happens via fileSystemChangedPublisher
					self?.performSearch(cancelExisting: false)
				}
			}
			.store(in: &cancellables)

		fileManager.selectionClearedPublisher
			.sink { [weak self] in
				Task { @MainActor in
					// Update the search results to reflect the cleared selection
					self?.handleSelectionCleared()
				}
			}
			.store(in: &cancellables)
		
		// Subscribe to file system changes to invalidate snapshot cache
		fileManager.fileSystemChangedPublisher
			.sink { [weak self] in
				Task { @MainActor in
					self?.invalidateSnapshotCache()
					// Only re-perform search if we have an active search
					if let self = self, !self.searchText.isEmpty {
						self.performSearch(cancelExisting: false)
					}
				}
			}
			.store(in: &cancellables)
	}
	
	/// Clears search UI state without mutating `searchText` (to avoid re-entrancy)
	/// and without touching the main file tree state.
	@MainActor
	private func clearSearchResultsOnly() {
		searchTask?.cancel()
		searchTask = nil
		pendingSearchRefresh = false

		isSearching = false
		rootFolders.removeAll()
		noResultsFound = false
		hasSearchResults = false

		folderIndex.removeAll()
		fileIndex.removeAll()
		cachedQuery = nil
	}

	func cancelSearch() {
		clearSearchResultsOnly()
		workspaceSwitchTask?.cancel()
		workspaceSwitchTask = nil
		searchText = ""
	}
	
	// Centralized cache reset helper
	private enum CacheResetScope {
		case fileSystemChanged   // FM same, topology changed
		case fileManagerChanged  // new RepoFileManager instance
	}
	
	@MainActor
	private func resetCaches(scope: CacheResetScope) {
		switch scope {
		case .fileSystemChanged:
			// We keep per-root snapshots and let per-root generation
			// decide what to rebuild next time.
			cachedQuery = nil
			pathSearchIndex = nil
			flatFilesPath = []
			// rootSnapshotCache stays intact
			
		case .fileManagerChanged:
			// New FM: throw away everything
			cachedQuery = nil
			pathSearchIndex = nil
			flatFilesPath = []
			rootSnapshotCache.removeAll()
		}
	}
	
	private func invalidateSnapshotCache() {
		resetCaches(scope: .fileSystemChanged)
	}
	
	private func setupSearchPublisher() {
		$searchText
			.removeDuplicates()
			.debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
			.sink { [weak self] newText in
				guard let self = self else { return }

				// Cancel ongoing search task if text changes
				self.searchTask?.cancel()

				// If the text is empty, clear search UI state only - don't touch the main tree
				guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
					self.clearSearchResultsOnly()
					return
				}

				// Perform new search with debounced text
				self.performSearch()
			}
			.store(in: &cancellables)
	}
	
	/*
	private func setupSearchPublisher() {
		let emptyStringPublisher = $searchText
			.filter { $0.isEmpty }
		
		let nonEmptyStringPublisher = $searchText
			.filter { !$0.isEmpty }
			.removeDuplicates()
			.debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
		
		Publishers.Merge(emptyStringPublisher, nonEmptyStringPublisher)
			.sink { [weak self] _ in
				self?.performSearch()
			}
			.store(in: &cancellables)
		
		$searchText
			.dropFirst()
			.removeDuplicates()
			.sink { [weak self] _ in
				self?.isSearching = true
			}
			.store(in: &cancellables)
	}
	*/
	
	// ------------------------------------------------------------------
	// MARK: Main entry for searching
	// ------------------------------------------------------------------
	@MainActor
	private func performSearch(cancelExisting: Bool = true) {
		if cancelExisting {
			searchTask?.cancel()
			pendingSearchRefresh = false
		} else if searchTask != nil {
			pendingSearchRefresh = true
			return
		} else {
			pendingSearchRefresh = false
		}
		
		// Reset base UI state
		rootFolders.removeAll()
		noResultsFound   = false
		hasSearchResults = false
		isSearching      = false
		
		// Clear the dictionaries
		folderIndex.removeAll()
		fileIndex.removeAll()
		
		guard !searchText.isEmpty else {
			// Search cleared - UI state already reset above; don't touch main tree
			return
		}
		
		// ------------------------------------------------------------------
		// NEW: Hard-cap the length of the search string to avoid runaway
		// regex compilation or excessive work. Anything beyond 1 000 chars
		// is simply ignored.
		// ------------------------------------------------------------------
		let cappedSearchText = String(searchText.prefix(1_000))
		
		// Build snapshot using per-root caching (only rebuilds changed roots)
		let snapshot: [SnapshotFolder]
		if let fm = fileManager {
			snapshot = buildSnapshotFromFileManager(fm)
		} else {
			snapshot = []
		}
		let searchTextCapture = cappedSearchText   // use the capped version only
		
		searchTask = Task { [weak self] in
			guard let self else { return }
			
			await MainActor.run { self.isSearching = true }
			
			do {
				// We already had a 5 s timeout; no change needed here.
				let found = try await withTimeout(seconds: 5) {
					await self.searchSnapshot(snapshot, forPattern: searchTextCapture)
				}
				
				if Task.isCancelled { throw CancellationError() }
				
				await MainActor.run {
					self.rootFolders     = found
					self.noResultsFound  = found.isEmpty
					self.hasSearchResults = !found.isEmpty
					
					// Re-index for O(1) look-ups.
					self.buildIndexes(for: self.rootFolders, parent: nil)
					self.isSearching = false
				}
				
			} catch is CancellationError {
				await MainActor.run {
					self.isSearching = false
				}
				return
			} catch {
				await MainActor.run {
					self.rootFolders.removeAll()
					self.noResultsFound   = true
					self.hasSearchResults = false
					self.isSearching = false
				}
			}
			
			await MainActor.run {
				self.searchTask = nil
				if self.pendingSearchRefresh {
					self.pendingSearchRefresh = false
					self.performSearch(cancelExisting: false)
				}
			}
		}
	}
	
	private struct SnapshotFolder {
		let id: UUID
		let name: String
		let relativePath: String
		let children: [SnapshotItem]
	}
	
	private enum SnapshotItem {
		case folder(SnapshotFolder)
		case file(SnapshotFile)
	}
	
	private struct SnapshotFile {
		let id: UUID
		let name: String
		let relativePath: String
		let nameLower: String
		let relativePathLower: String
		
		init(id: UUID, name: String, relativePath: String) {
			self.id = id
			self.name = name
			self.relativePath = relativePath
			self.nameLower = name.lowercased()
			self.relativePathLower = relativePath.lowercased()
		}
	}
	
	private func createSnapshotOfFileTree(_ folders: [FolderViewModel]) -> [SnapshotFolder] {
		folders.map { makeSnapshotFolder($0) }
	}
	
	private func makeSnapshotFolder(_ folder: FolderViewModel) -> SnapshotFolder {
		let childSnapshots = folder.children.map { child -> SnapshotItem in
			switch child {
			case .folder(let subFolder):
				return .folder(makeSnapshotFolder(subFolder))
			case .file(let file):
				return .file(SnapshotFile(
					id: file.id,
					name: file.name,
					relativePath: file.relativePath
				))
			}
		}
		return SnapshotFolder(
			id: folder.id,
			name: folder.name,
			relativePath: folder.relativePath,
			children: childSnapshots
		)
	}
	
	/// Builds a snapshot using per-root caching. Only roots whose generation
	/// changed (or are new) get their snapshot rebuilt.
	@MainActor
	private func buildSnapshotFromFileManager(_ fm: RepoFileManagerViewModel) -> [SnapshotFolder] {
		let perRootGen = fm.hierarchyGenerationByRoot  // [standardPath: UInt64]
		
		var newCache: [UUID: RootSnapshotCacheEntry] = [:]
		var snapshots: [SnapshotFolder] = []
		
		for root in fm.visibleRootFolders {
			let rootID   = root.id
			let rootPath = root.standardizedFullPath
			let generation = perRootGen[rootPath] ?? 0
			
			if let cached = rootSnapshotCache[rootID],
			cached.rootPath == rootPath,
			cached.generation == generation {
				// Still valid – reuse snapshot
				newCache[rootID] = cached
				snapshots.append(cached.snapshot)
			} else {
				// Root is new, moved to a different path, or its generation bumped
				let snap = makeSnapshotFolder(root)
				let entry = RootSnapshotCacheEntry(
					rootID: rootID,
					rootPath: rootPath,
					generation: generation,
					snapshot: snap
				)
				newCache[rootID] = entry
				snapshots.append(snap)
			}
		}
		
		// Any roots that disappeared are implicitly dropped (not in newCache)
		rootSnapshotCache = newCache
		
		return snapshots
	}
	
	private func rebuildIndexIfNeeded(_ snapshot: [SnapshotFolder]) async {
		// Rebuild if index is nil OR if flatFilesPath is empty (cache was invalidated)
		guard pathSearchIndex == nil || flatFilesPath.isEmpty else { return }
		
		// Collect all files with their paths
		var allFiles: [(file: SnapshotFile, folderPath: [SnapshotFolder])] = []
		
		func collectAllFiles(from folders: [SnapshotFolder], path: [SnapshotFolder]) {
			for folder in folders {
				var currentPath = path
				currentPath.append(folder)
				
				for child in folder.children {
					switch child {
					case .folder(let subFolder):
						collectAllFiles(from: [subFolder], path: currentPath)
					case .file(let file):
						allFiles.append((file: file, folderPath: currentPath))
					}
				}
			}
		}
		
		collectAllFiles(from: snapshot, path: [])
		
		// Extract just the paths for the index
		let paths = allFiles.map { $0.file.relativePath }
		
		// Build the index
		pathSearchIndex = await PathSearchIndex(paths: paths)
		
		// Store mapping (index → (file, folderPath))
		flatFilesPath = allFiles
	}
	
	private func searchSnapshot(
		_ snapshot: [SnapshotFolder],
		forPattern rawSearchText: String
	) async -> [SearchFolderViewModel] {
		let query = parseQuery(rawSearchText)
		
		// Build index if needed
		await rebuildIndexIfNeeded(snapshot)
		
		// Always use fast path whenever an index exists
		if let index = pathSearchIndex {
			// Fast path using binary search index
			var candidates = await index.search(rawSearchText, limit: Self.resultLimit * 4)
			
			// 1️⃣ De-duplicate indices (path_search_find can emit duplicates)
			var seen = Set<Int>()
			candidates = candidates.filter { seen.insert($0.index).inserted }
			
			// Convert candidates directly, preserving result order.
			// We no longer compute a fuzzy score – just assign a rank-based
			// score so the rest of the pipeline can keep sorting folders by
			// "score" without extra work.
			var kept: [(file: SnapshotFile,
						score: Int,
						folderPath: [SnapshotFolder])] = []
			kept.reserveCapacity(min(candidates.count, Self.resultLimit))
			
			for (rank, candidate) in candidates.prefix(Self.resultLimit)
												.enumerated() {
				guard candidate.index >= 0,
						candidate.index < flatFilesPath.count else { continue }
				
				let data   = flatFilesPath[candidate.index]
				// Higher rank (earlier in list) gets a larger score value.
				let score  = Self.resultLimit - rank
				kept.append((file:       data.file,
								score:      score,
								folderPath: data.folderPath))
			}
			
			// Build lookup for fast inclusion test
			let keptById = Dictionary(
				uniqueKeysWithValues: kept.map { ($0.file.id,
													($0.score, $0.folderPath)) })
			
			// Reconstruct tree with only matched files
			return await reconstructTree(from: snapshot,
											keptFiles: keptById)
		}
		
		// Fall back to original implementation for small file counts
		// First pass: collect all files with their paths
		var allFiles: [(file: SnapshotFile, folderPath: [SnapshotFolder])] = []
		
		func collectAllFiles(from folders: [SnapshotFolder], path: [SnapshotFolder]) {
			for folder in folders {
				var currentPath = path
				currentPath.append(folder)
				
				for child in folder.children {
					switch child {
					case .folder(let subFolder):
						collectAllFiles(from: [subFolder], path: currentPath)
					case .file(let file):
						allFiles.append((file: file, folderPath: currentPath))
					}
				}
			}
		}
		
		collectAllFiles(from: snapshot, path: [])
		
		// Batch score all files using C implementation for better performance
		var scores = Array<Int32>(repeating: 0, count: allFiles.count)
		
		// OPTIMIZATION 3: Multi-threaded batch scoring
		// Determine number of threads based on file count and CPU cores
		let cpuCount = ProcessInfo.processInfo.processorCount
		let minFilesPerThread = 500  // Don't create threads for tiny batches
		let threadCount = min(cpuCount, max(1, allFiles.count / minFilesPerThread))
		
		if threadCount > 1 {
			// Multi-threaded path
			await withTaskGroup(of: Void.self) { group in
				let filesPerThread = allFiles.count / threadCount
				
				for threadIndex in 0..<threadCount {
					let threadStartIndex = threadIndex * filesPerThread
					let threadEndIndex = (threadIndex == threadCount - 1)
						? allFiles.count
						: (threadIndex + 1) * filesPerThread
					
					group.addTask { [query, allFiles] in
						// Process this thread's range in batches
						let batchSize = 1000
						for startIndex in stride(from: threadStartIndex, to: threadEndIndex, by: batchSize) {
							let endIndex = min(startIndex + batchSize, threadEndIndex)
							let batchFiles = Array(allFiles[startIndex..<endIndex])
							
							// OPTIMIZATION 1: Zero-copy batch interface
							// Create a single contiguous buffer for all strings to reduce allocations
							var totalSize = 0
							for file in batchFiles {
								totalSize += file.file.name.utf8.count + 1
								totalSize += file.file.relativePath.utf8.count + 1
								totalSize += file.file.nameLower.utf8.count + 1
								totalSize += file.file.relativePathLower.utf8.count + 1
							}
							
							// Allocate one buffer for all strings
							let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: totalSize)
							defer { buffer.deallocate() }
							
							// Create file info structs pointing into the buffer
							var fileInfos: [repo_file_info] = []
							fileInfos.reserveCapacity(batchFiles.count)
							
							var currentOffset = 0
							for file in batchFiles {
								// Copy name
								let namePtr = buffer.advanced(by: currentOffset)
								let nameBytes = file.file.name.utf8CString
								nameBytes.withUnsafeBufferPointer { bytes in
									namePtr.initialize(from: bytes.baseAddress!, count: bytes.count)
								}
								currentOffset += nameBytes.count
								
								// Copy path
								let pathPtr = buffer.advanced(by: currentOffset)
								let pathBytes = file.file.relativePath.utf8CString
								pathBytes.withUnsafeBufferPointer { bytes in
									pathPtr.initialize(from: bytes.baseAddress!, count: bytes.count)
								}
								currentOffset += pathBytes.count
								
								// Copy name_lower
								let nameLowerPtr = buffer.advanced(by: currentOffset)
								let nameLowerBytes = file.file.nameLower.utf8CString
								nameLowerBytes.withUnsafeBufferPointer { bytes in
									nameLowerPtr.initialize(from: bytes.baseAddress!, count: bytes.count)
								}
								currentOffset += nameLowerBytes.count
								
								// Copy path_lower
								let pathLowerPtr = buffer.advanced(by: currentOffset)
								let pathLowerBytes = file.file.relativePathLower.utf8CString
								pathLowerBytes.withUnsafeBufferPointer { bytes in
									pathLowerPtr.initialize(from: bytes.baseAddress!, count: bytes.count)
								}
								currentOffset += pathLowerBytes.count
								
								fileInfos.append(repo_file_info(
									name: UnsafePointer(namePtr),
									path: UnsafePointer(pathPtr),
									name_lower: UnsafePointer(nameLowerPtr),
									path_lower: UnsafePointer(pathLowerPtr)
								))
							}
							
							// Score this batch using optimized function
							fileInfos.withUnsafeBufferPointer { infosPtr in
								scores.withUnsafeMutableBufferPointer { scoresPtr in
									let batchScoresPtr = scoresPtr.baseAddress?.advanced(by: startIndex)
									query.raw.withCString { queryPtr in
										query.lowered.withCString { queryLowerPtr in
											repo_score_matches_batch(
												infosPtr.baseAddress,
												batchFiles.count,
												queryPtr,
												queryLowerPtr,
												query.hasSlash,
												query.isWildcard,
												Self.fuzzyThreshold,
												batchScoresPtr
											)
										}
									}
								}
							}
						}
					}
				}
			}
		} else {
			// Single-threaded path (original code)
			let batchSize = 1000
			for startIndex in stride(from: 0, to: allFiles.count, by: batchSize) {
				let endIndex = min(startIndex + batchSize, allFiles.count)
				let batchFiles = Array(allFiles[startIndex..<endIndex])
				
				// OPTIMIZATION 1: Zero-copy batch interface
				// Create a single contiguous buffer for all strings to reduce allocations
				var totalSize = 0
				for file in batchFiles {
					totalSize += file.file.name.utf8.count + 1
					totalSize += file.file.relativePath.utf8.count + 1
					totalSize += file.file.nameLower.utf8.count + 1
					totalSize += file.file.relativePathLower.utf8.count + 1
				}
				
				// Allocate one buffer for all strings
				let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: totalSize)
				defer { buffer.deallocate() }
				
				// Create file info structs pointing into the buffer
				var fileInfos: [repo_file_info] = []
				fileInfos.reserveCapacity(batchFiles.count)
				
				var currentOffset = 0
				for file in batchFiles {
					// Copy name
					let namePtr = buffer.advanced(by: currentOffset)
					let nameBytes = file.file.name.utf8CString
					nameBytes.withUnsafeBufferPointer { bytes in
						namePtr.initialize(from: bytes.baseAddress!, count: bytes.count)
					}
					currentOffset += nameBytes.count
					
					// Copy path
					let pathPtr = buffer.advanced(by: currentOffset)
					let pathBytes = file.file.relativePath.utf8CString
					pathBytes.withUnsafeBufferPointer { bytes in
						pathPtr.initialize(from: bytes.baseAddress!, count: bytes.count)
					}
					currentOffset += pathBytes.count
					
					// Copy name_lower
					let nameLowerPtr = buffer.advanced(by: currentOffset)
					let nameLowerBytes = file.file.nameLower.utf8CString
					nameLowerBytes.withUnsafeBufferPointer { bytes in
						nameLowerPtr.initialize(from: bytes.baseAddress!, count: bytes.count)
					}
					currentOffset += nameLowerBytes.count
					
					// Copy path_lower
					let pathLowerPtr = buffer.advanced(by: currentOffset)
					let pathLowerBytes = file.file.relativePathLower.utf8CString
					pathLowerBytes.withUnsafeBufferPointer { bytes in
						pathLowerPtr.initialize(from: bytes.baseAddress!, count: bytes.count)
					}
					currentOffset += pathLowerBytes.count
					
					fileInfos.append(repo_file_info(
						name: UnsafePointer(namePtr),
						path: UnsafePointer(pathPtr),
						name_lower: UnsafePointer(nameLowerPtr),
						path_lower: UnsafePointer(pathLowerPtr)
					))
				}
				
				// Score this batch using optimized function
				fileInfos.withUnsafeBufferPointer { infosPtr in
					scores.withUnsafeMutableBufferPointer { scoresPtr in
						let batchScoresPtr = scoresPtr.baseAddress?.advanced(by: startIndex)
						query.raw.withCString { queryPtr in
							query.lowered.withCString { queryLowerPtr in
								repo_score_matches_batch(
									infosPtr.baseAddress,
									batchFiles.count,
									queryPtr,
									queryLowerPtr,
									query.hasSlash,
									query.isWildcard,
									Self.fuzzyThreshold,
									batchScoresPtr
								)
							}
						}
					}
				}
			}
		}
		
		// Collect scored files (only those with score > 0)
		var scoredFiles: [(file: SnapshotFile, score: Int, folderPath: [SnapshotFolder])] = []
		for (index, score) in scores.enumerated() where score > 0 {
			let fileData = allFiles[index]
			scoredFiles.append((file: fileData.file, score: Int(score), folderPath: fileData.folderPath))
		}
		
		// Sort by score (descending) and take top N
		scoredFiles.sort { $0.score > $1.score }
		let keptFiles = Array(scoredFiles.prefix(Self.resultLimit))
		
		// Build lookup for fast inclusion test
		let keptFilesById = Dictionary(uniqueKeysWithValues: keptFiles.map { ($0.file.id, ($0.score, $0.folderPath)) })
		
		// Reconstruct tree with only matched files
		let results = await reconstructTree(from: snapshot, keptFiles: keptFilesById)
		
		return results
	}
	
	// Reconstruct tree structure with only matched files and their parent folders
	private func reconstructTree(
		from snapshot: [SnapshotFolder],
		keptFiles: [UUID: (score: Int, folderPath: [SnapshotFolder])]
	) async -> [SearchFolderViewModel] {
		var results: [SearchFolderViewModel] = []
		
		// Process each root folder
		for rootSnapshot in snapshot {
			if let reconstructed = await reconstructFolder(
				from: rootSnapshot,
				keptFiles: keptFiles,
				parentPath: []
			) {
				results.append(reconstructed)
			}
		}
		
		// Preserve the root ordering from the main file tree snapshot so search results
		// reflect the same workspace order.
		return results
	}
	
	// Reconstruct a single folder if it contains any matched files
	private func reconstructFolder(
		from snapshot: SnapshotFolder,
		keptFiles: [UUID: (score: Int, folderPath: [SnapshotFolder])],
		parentPath: [SnapshotFolder]
	) async -> SearchFolderViewModel? {
		var currentPath = parentPath
		currentPath.append(snapshot)
		
		var matchedChildren: [SearchFileSystemItem] = []
		var maxChildScore = 0
		
		// Process children
		for child in snapshot.children {
			switch child {
			case .folder(let subFolder):
				if let reconstructedSubFolder = await reconstructFolder(
					from: subFolder,
					keptFiles: keptFiles,
					parentPath: currentPath
				) {
					maxChildScore = max(maxChildScore, reconstructedSubFolder.bestDescendantScore)
					matchedChildren.append(.folder(reconstructedSubFolder))
				}
				
			case .file(let file):
				if let (score, pathChain) = keptFiles[file.id] {
					let searchFile = SearchFileViewModel(
						id: file.id,
						name: file.name,
						relativePath: file.relativePath,
						matchScore: score
					)
					
					// Root-aware linking: use the first ancestor (root) id to disambiguate
					let rootID = pathChain.first?.id
					var realFileVM: FileViewModel? = nil
					
					if let rid = rootID {
						realFileVM = await fileManager?.findFile(atPath: file.relativePath, rootIdentifier: rid)
					}
					
					// Fallback to legacy behavior if root-aware lookup fails (should be rare)
					if realFileVM == nil {
						realFileVM = fileManager?.findFileByRelativePath(file.relativePath)
					}
					
					if let real = realFileVM {
						searchFile.originalFile = real
						searchFile.isChecked = real.isChecked
					}
					
					maxChildScore = max(maxChildScore, score)
					matchedChildren.append(.file(searchFile))
				}
			}
		}
		
		// Only create folder if it has matched children
		guard !matchedChildren.isEmpty else { return nil }
		
		// Sort children by score
		sortChildren(&matchedChildren)
		
		// Resolve originalFolder against the correct root when possible
		var resolvedOriginalFolder: FolderViewModel? = nil
		if let rootID = currentPath.first?.id,
			let rootFolder = fileManager?.visibleRootFolders.first(where: { $0.id == rootID }) {
			let fullPath: String
			if snapshot.relativePath.isEmpty {
				fullPath = rootFolder.fullPath
			} else {
				fullPath = (rootFolder.fullPath as NSString).appendingPathComponent(snapshot.relativePath)
			}
			resolvedOriginalFolder = fileManager?.findFolderByFullPath(fullPath)
		} else {
			// Fallback to previous behavior
			resolvedOriginalFolder = fileManager?.findFolderByRelativePath(snapshot.relativePath)
		}
		
		let folder = SearchFolderViewModel(
			id: snapshot.id,
			name: snapshot.name,
			relativePath: snapshot.relativePath,
			isExpanded: true,
			checkboxState: .unchecked,
			children: matchedChildren,
			bestDescendantScore: maxChildScore,
			originalFolder: resolvedOriginalFolder
		)
		
		// Update checkbox state
		updateSearchFolderState(folder)
		
		return folder
	}
	
	// Sort children by score and name
	private func sortChildren(_ children: inout [SearchFileSystemItem]) {
		children.sort { first, second in
			switch (first, second) {
			case (.folder(let a), .folder(let b)):
				if a.bestDescendantScore == b.bestDescendantScore {
					if a.nameSortKey != b.nameSortKey {
						return a.nameSortKey < b.nameSortKey
					}
					return a.name < b.name
				}
				return a.bestDescendantScore > b.bestDescendantScore
				
			case (.folder, .file):
				return true  // Folders first
				
			case (.file, .folder):
				return false
				
			case (.file(let a), .file(let b)):
				if a.matchScore == b.matchScore {
					if a.nameSortKey != b.nameSortKey {
						return a.nameSortKey < b.nameSortKey
					}
					return a.name < b.name
				}
				return a.matchScore > b.matchScore
			}
		}
	}
	
	private func convertToWildcardPattern(_ searchText: String) -> String {
		// Only replace whitespace with "*" for flexible matching if no wildcards present
		var pattern = searchText.lowercased().trimmingCharacters(in: .whitespaces)
		
		// Convert file extension shortcuts (e.g., ".swift" → "*.swift")
		if pattern.hasPrefix(".") && !pattern.hasPrefix("..") && !pattern.contains("/") {
			pattern = "*" + pattern
		}
		
		// If pattern already contains wildcards, return as-is
		if pattern.contains("*") || pattern.contains("?") {
			return pattern
		}
		
		// Otherwise, replace whitespace for fuzzy matching
		return pattern.replacingOccurrences(of: "\\s+", with: "*", options: .regularExpression)
	}
	
	// DEPRECATED: Old search method - replaced by scoring pipeline
	/*
	/// Creates a `SearchFolderViewModel` only if at least one file (direct or nested) is matched
	private func createSearchFolder(
		from folder: SnapshotFolder,
		searchPattern: String,
		rawSearchText: String
	) async -> SearchFolderViewModel? {
		guard !searchPattern.isEmpty else {
			return nil
		}
		
		// Safety check for pattern length
		if searchPattern.count > 200 {
			return nil
		}
		
		var matchedChildren: [SearchFileSystemItem] = []
		
		for child in folder.children {
			switch child {
			case .folder(let subFolder):
				// Recurse
				if let subFolderVM = await createSearchFolder(from: subFolder,
															  searchPattern: searchPattern,
															  rawSearchText: rawSearchText) {
					matchedChildren.append(.folder(subFolderVM))
				}
				
			case .file(let snapFile):
				let lcRelative = snapFile.relativePath.lowercased()
				
				// 1) Determine what to match against based on pattern
				let pathToMatch: String
				if searchPattern.contains("*") || searchPattern.contains("?") {
					// For wildcard patterns like *.swift, only match against filename
					if let lastComponent = lcRelative.split(separator: "/").last {
						pathToMatch = String(lastComponent)
					} else {
						pathToMatch = lcRelative
					}
				} else {
					// For non-wildcard patterns, match against full path for flexibility
					pathToMatch = lcRelative
				}
				
				// Use wildmatch for pattern matching
				let isWildcardMatch = searchPattern.withCString { patternC in
					pathToMatch.withCString { pathC in
						repo_wildmatch(patternC, pathC, WM_PATHNAME | WM_WILDSTAR) == WM_MATCH
					}
				}
				
				// 2) For non-wildcard patterns, check literal substring or fuzzy match
				let isSubstringOrFuzzyMatch: Bool
				if searchPattern.contains("*") || searchPattern.contains("?") {
					// Don't use fuzzy matching for wildcard patterns
					isSubstringOrFuzzyMatch = false
				} else {
					let searchLower = rawSearchText.lowercased().trimmingCharacters(in: .whitespaces)
					
					// Handle path-specific searches (contains /)
					if searchLower.contains("/") {
						// For path searches, match the pattern more strictly
						isSubstringOrFuzzyMatch = lcRelative.contains(searchLower)
					} else {
						// First check if it's a simple substring match anywhere in the path
						if lcRelative.contains(searchLower) {
							isSubstringOrFuzzyMatch = true
						} else {
							// Check each path component with smart matching
							isSubstringOrFuzzyMatch = lcRelative.split(separator: "/").contains { component in
								let comp = String(component)
								
								// Check various matching strategies
								if matchesComponent(searchLower, component: comp) {
									return true
								}
								
								// Finally try fuzzy matching with adaptive threshold
								let threshold = searchLower.count <= 2 ? 0.5 : 0.7
								let processedComponent: String
								if !searchLower.contains(".") {
									if let dotIndex = comp.firstIndex(of: ".") {
										processedComponent = String(comp[..<dotIndex])
									} else {
										processedComponent = comp
									}
								} else {
									processedComponent = comp
								}
								return processedComponent.isSimilar(to: searchLower, threshold: threshold)
							}
						}
					}
				}
				
				if isWildcardMatch || isSubstringOrFuzzyMatch {
					let searchFile = SearchFileViewModel(
						id: snapFile.id,
						name: snapFile.name,
						relativePath: snapFile.relativePath
					)
					if let realFileVM = fileManager?.findFileByRelativePath(snapFile.relativePath) {
						searchFile.originalFile = realFileVM
						searchFile.isChecked = realFileVM.isChecked
					}
					matchedChildren.append(.file(searchFile))
				}
			}
		}
		
		if matchedChildren.isEmpty {
			return nil
		}
		
		let result = SearchFolderViewModel(
			id: folder.id,
			name: folder.name,
			relativePath: folder.relativePath,
			isExpanded: true,
			checkboxState: .unchecked,
			children: matchedChildren,
			originalFolder: fileManager?.findFolderByRelativePath(folder.relativePath)
		)
		
		// Compute initial checkbox state
		updateSearchFolderState(result)
		return result
	}
	*/
	
	// *** NEW ***
	// Walk the final [SearchFolderViewModel] tree once,
	// building (1) the dictionary indexes and (2) wiring each child's `parent`.
	private func buildIndexes(for folders: [SearchFolderViewModel], parent: SearchFolderViewModel?) {
		for folder in folders {
			folderIndex[folder.id] = folder
			folder.parent = parent
			
			for child in folder.children {
				switch child {
				case .folder(let subFolder):
					buildIndexes(for: [subFolder], parent: folder)
				case .file(let file):
					fileIndex[file.id] = file
					file.parent = folder
				}
			}
		}
	}
	
	private func handleSelectionCleared() {
		for searchFolder in rootFolders {
			deselectAllRecursively(in: searchFolder)
		}
		for rootFolder in rootFolders {
			updateSearchFolderState(rootFolder)
		}
	}
	
	private func deselectAllRecursively(in folder: SearchFolderViewModel) {
		folder.checkboxState = .unchecked
		for (index, child) in folder.children.enumerated() {
			switch child {
			case .file(let file):
				file.isChecked = false
				folder.children[index] = .file(file)
			case .folder(let subFolder):
				deselectAllRecursively(in: subFolder)
				folder.children[index] = .folder(subFolder)
			}
		}
	}
	
	// ------------------------------------------------------------------
	// MARK: Synchronize changes from the real RepoFileManager
	// ------------------------------------------------------------------
	
	private func synchronizeFileState(_ toggledFile: FileViewModel) {
		// *** OLD WAY ***
		// guard let fileVM = findSearchFileViewModel(in: rootFolders, matching: toggledFile.id) else { return }
		
		// *** NEW WAY ***
		guard let fileVM = fileIndex[toggledFile.id] else { return }
		
		fileVM.isChecked = toggledFile.isChecked
		
		// Instead of recursing all root folders, bubble up from the file
		if let parentFolder = fileVM.parent {
			updateFolderStateUpChain(parentFolder)
		}
	}
	
	private func synchronizeFolderState(_ updatedFolder: FolderViewModel) {
		// *** OLD WAY ***
		// guard let folderVM = findSearchFolderViewModel(in: rootFolders, matching: updatedFolder.id) else { return }
		
		// *** NEW WAY ***
		guard let folderVM = folderIndex[updatedFolder.id] else { return }
		
		// Force a re-sync of states in that subtree
		synchronizeFolderChildrenState(folderVM, updatedFolder: updatedFolder)
		
		// Then bubble up to fix check states
		updateFolderStateUpChain(folderVM)
	}
	
	private func synchronizeFolderChildrenState(_ folderVM: SearchFolderViewModel,
												updatedFolder: FolderViewModel)
	{
		guard let originalFolder = folderVM.originalFolder else { return }
		let realLookup = Dictionary(uniqueKeysWithValues: originalFolder.children.map { ($0.id, $0) })
		
		for (index, child) in folderVM.children.enumerated() {
			switch child {
			case .file(let searchFile):
				if let realItem = realLookup[searchFile.id], case .file(let realFile) = realItem {
					searchFile.isChecked = realFile.isChecked
					searchFile.originalFile = realFile
					folderVM.children[index] = .file(searchFile)
				}
			case .folder(let subFolder):
				if let realItem = realLookup[subFolder.id], case .folder(let realSubFolder) = realItem {
					subFolder.originalFolder = realSubFolder
					synchronizeFolderChildrenState(subFolder, updatedFolder: realSubFolder)
					folderVM.children[index] = .folder(subFolder)
				}
			}
		}
	}
	
	// ------------------------------------------------------------------
	// MARK: Updating folder states (checked/unchecked/mixed)
	// ------------------------------------------------------------------
	
	func toggleFolderSelection(_ folder: SearchFolderViewModel) {
		guard let fm = fileManager else { return }

		switch folder.checkboxState {
		case .unchecked:
			// Collect all descendant file paths that are currently unchecked
			var toSelect: [String] = []

			func walkSelect(_ f: SearchFolderViewModel) {
				for (idx, child) in f.children.enumerated() {
					switch child {
					case .file(let file):
						if let orig = file.originalFile {
							if !orig.isChecked {
								// Prefer absolute path to disambiguate across roots
								toSelect.append(orig.fullPath)
							}
							// Optimistically update local search state
							file.isChecked = true
						} else {
							// Fallback: relative path when we don't have the original file VM
							toSelect.append(file.relativePath)
							file.isChecked = true
						}
						f.children[idx] = .file(file)
					case .folder(let sub):
						walkSelect(sub)
						f.children[idx] = .folder(sub)
					}
				}
			}
			walkSelect(folder)

			// Update folder state locally and then apply to the real file manager in one batch
			updateFolderStateUpChain(folder)
			Task { @MainActor in
				await fm.selectFiles(withPaths: toSelect, allowEmpty: true, clear: false)
				// Ancestor recompute is handled efficiently inside RepoFileManagerViewModel
			}

		case .checked, .mixed:
			// Collect all descendant file paths that are currently checked
			var toUnselect: [String] = []

			func walkUnselect(_ f: SearchFolderViewModel) {
				for (idx, child) in f.children.enumerated() {
					switch child {
					case .file(let file):
						if let orig = file.originalFile {
							if orig.isChecked {
								// Prefer absolute path to disambiguate across roots
								toUnselect.append(orig.fullPath)
							}
							// Optimistically update local search state
							file.isChecked = false
						} else {
							// Fallback: relative path when we don't have the original file VM
							toUnselect.append(file.relativePath)
							file.isChecked = false
						}
						f.children[idx] = .file(file)
					case .folder(let sub):
						walkUnselect(sub)
						f.children[idx] = .folder(sub)
					}
				}
			}
			walkUnselect(folder)

			// Update folder state locally and then apply to the real file manager in one batch
			updateFolderStateUpChain(folder)
			Task { @MainActor in
				await fm.deselectFiles(withPaths: toUnselect)
				// Ancestor recompute is handled efficiently inside RepoFileManagerViewModel
			}
		}
	}
	
	private func checkAllDescendantFiles(onlyIfUnchecked: Bool,
											in folder: SearchFolderViewModel) {
		for (idx, child) in folder.children.enumerated() {
			switch child {
			case .folder(let subFolder):
				checkAllDescendantFiles(onlyIfUnchecked: onlyIfUnchecked, in: subFolder)
				folder.children[idx] = .folder(subFolder)
			case .file(let file):
				if let orig = file.originalFile,
					(!onlyIfUnchecked || !orig.isChecked) {
					orig.setIsChecked(true)          // RepoFileManager batching handles selection
					file.isChecked = true
				}
			}
		}
	}
	
	private func uncheckAllDescendantFiles(_ folder: SearchFolderViewModel) {
		for (idx, child) in folder.children.enumerated() {
			switch child {
			case .folder(let subFolder):
				uncheckAllDescendantFiles(subFolder)
				folder.children[idx] = .folder(subFolder)
			case .file(let file):
				if file.isChecked, let orig = file.originalFile {
					orig.setIsChecked(false)
					file.isChecked = false
				}
			}
		}
	}
	
	// *** OLD WAY ***
	// private func updateSearchFolderState(_ searchFolder: SearchFolderViewModel) { ... big recursion ... }
	
	// *** NEW WAY ***
	// Let's keep the same logic for the local subtree,
	// but for toggles, we only call it from the changed node upward.
	private func updateSearchFolderState(_ folder: SearchFolderViewModel) {
		var checkedCount = 0
		var uncheckedCount = 0
		var mixedFound = false
		
		for (index, child) in folder.children.enumerated() {
			switch child {
			case .folder(let subFolder):
				// Recursively update subfolder first
				updateSearchFolderState(subFolder)
				switch subFolder.checkboxState {
				case .checked:
					checkedCount += 1
				case .unchecked:
					uncheckedCount += 1
				case .mixed:
					mixedFound = true
				}
				folder.children[index] = .folder(subFolder)
			case .file(let file):
				if file.isChecked {
					checkedCount += 1
				} else {
					uncheckedCount += 1
				}
			}
		}
		
		if mixedFound || (checkedCount > 0 && uncheckedCount > 0) {
			folder.checkboxState = .mixed
		} else if checkedCount > 0 && uncheckedCount == 0 {
			folder.checkboxState = .checked
		} else {
			folder.checkboxState = .unchecked
		}
	}
	
	// *** NEW ***
	// This is a helper to bubble the state up the chain.
	private func updateFolderStateUpChain(_ folder: SearchFolderViewModel) {
		// Recompute this folder’s own state (for its children).
		updateSearchFolderState(folder)
		
		// Then go to the parent, if any, up to the top.
		if let parent = folder.parent {
			updateFolderStateUpChain(parent)
		}
	}
	
	// Helper function for smart component matching
	private func matchesComponent(_ search: String, component: String) -> Bool {
		let comp = component.lowercased()
		
		// 1. Direct substring match
		if comp.contains(search) {
			return true
		}
		
		// 2. Prefix matching - very intuitive for users
		if comp.hasPrefix(search) {
			return true
		}
		
		// 3. Handle multiple search terms (space-separated as AND logic)
		let searchTerms = search.split(separator: " ").map { String($0) }
		if searchTerms.count > 1 {
			// All terms must be found in the component
			let allTermsFound = searchTerms.allSatisfy { term in
				comp.contains(term)
			}
			if allTermsFound {
				return true
			}
		}
		
		// 4. CamelCase matching - "sfvm" matches "SearchFileViewModel"
		if matchesCamelCase(search, in: component) {
			return true
		}
		
		// 5. Snake_case matching - "sf_vm" matches "search_file_view_model"
		if matchesSnakeCase(search, in: comp) {
			return true
		}
		
		// 6. Acronym matching - "SVM" matches "SearchViewModel"
		let searchUpper = search.uppercased()
		let acronym = component.compactMap { $0.isUppercase ? $0 : nil }.map { String($0) }.joined()
		if !acronym.isEmpty && acronym.contains(searchUpper) {
			return true
		}
		
		return false
	}
	
	private func matchesCamelCase(_ search: String, in text: String) -> Bool {
		// Simple camelCase matching - "sfvm" matches "SearchFileViewModel"
		let searchLower = search.lowercased()
		var searchIndex = searchLower.startIndex
		
		// Extract lowercase + first char of each word
		var simplified = ""
		var wasLower = false
		for char in text {
			if char.isUppercase {
				simplified += char.lowercased()
				wasLower = false
			} else if !wasLower {
				simplified += String(char)
				wasLower = true
			}
		}
		
		// Check if search chars appear in order in simplified version
		for textChar in simplified {
			if searchIndex < searchLower.endIndex && searchLower[searchIndex] == textChar {
				searchIndex = searchLower.index(after: searchIndex)
			}
		}
		
		return searchIndex == searchLower.endIndex
	}
	
	private func matchesSnakeCase(_ search: String, in text: String) -> Bool {
		// Convert search with underscores to match snake_case
		let searchParts = search.split(separator: "_").map { String($0) }
		if searchParts.count > 1 {
			// Check if all parts are found in order
			var lastIndex = text.startIndex
			for part in searchParts {
				if let range = text.range(of: part, options: .caseInsensitive, range: lastIndex..<text.endIndex) {
					lastIndex = range.upperBound
				} else {
					return false
				}
			}
			return true
		}
		return false
	}
	
	func toggleFile(_ file: SearchFileViewModel) async {
		guard let fm = fileManager,
				let original = file.originalFile else { return }

		fm.performSelectionBatch {
			let newVal = !original.isChecked
			original.setIsChecked(newVal)
			file.isChecked = newVal
		}
		fm.refreshRootFolderState()
	}
	
	private func withTimeout<T>(seconds: UInt64, operation: @escaping () async -> T) async throws -> T {
		try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask {
				return await operation()
			}
			group.addTask {
				try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
				throw SearchTimeoutError()
			}
			let result = try await group.next()!
			group.cancelAll()
			return result
		}
	}
}
// ------------------------------------------------------------------
// MARK: - Models for search results
// ------------------------------------------------------------------

class SearchFolderViewModel: Identifiable, ObservableObject {
	let id: UUID
	let name: String
	let nameSortKey: String
	let relativePath: String
	
	@Published var isExpanded: Bool
	@Published var checkboxState: CheckboxState
	@Published var children: [SearchFileSystemItem]
	@Published var bestDescendantScore: Int = 0
	
	// NEW: store a weak parent reference
	weak var parent: SearchFolderViewModel?
	
	var originalFolder: FolderViewModel?
	
	init(id: UUID,
		 name: String,
		 relativePath: String,
		 isExpanded: Bool,
		 checkboxState: CheckboxState,
		 children: [SearchFileSystemItem],
		 bestDescendantScore: Int = 0,
		 originalFolder: FolderViewModel?)
	{
		self.id = id
		self.name = name
		self.nameSortKey = name.lowercased()
		self.relativePath = relativePath
		self.isExpanded = isExpanded
		self.checkboxState = checkboxState
		self.children = children
		self.bestDescendantScore = bestDescendantScore
		self.originalFolder = originalFolder
	}
}

class SearchFileViewModel: Identifiable, ObservableObject {
	let id: UUID
	let name: String
	let nameSortKey: String
	let relativePath: String
	
	// NEW: store a weak parent reference
	weak var parent: SearchFolderViewModel?
	
	@Published var isChecked: Bool = false
	@Published var matchScore: Int = 0
	var originalFile: FileViewModel?
	
	init(id: UUID,
		 name: String,
		 relativePath: String,
		 matchScore: Int = 0,
		 originalFile: FileViewModel? = nil)
	{
		self.id = id
		self.name = name
		self.nameSortKey = name.lowercased()
		self.relativePath = relativePath
		self.matchScore = matchScore
		self.originalFile = originalFile
		self.isChecked = originalFile?.isChecked ?? false
	}
}

enum SearchFileSystemItem: Identifiable {
	case folder(SearchFolderViewModel)
	case file(SearchFileViewModel)
	
	var id: UUID {
		switch self {
		case .folder(let folder):
			return folder.id
		case .file(let file):
			return file.id
		}
	}
}

struct SearchTimeoutError: Error, LocalizedError {
	var errorDescription: String? {
		return "Search timed out."
	}
}
