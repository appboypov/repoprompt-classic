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
		let rootPath: String       // standardized full path
		let generation: UInt64     // the index generation the snapshot was built from
		let showEmptyFolders: Bool
		let snapshot: SnapshotFolder
	}
	
	private var rootSnapshotCache: [UUID: RootSnapshotCacheEntry] = [:]
	
	// The path index of the last search, reused while no root's index generation changes
	private var searchIndex: SearchIndexState?
	
	// Configurable constants
	private nonisolated static var resultLimit: Int { 300 }
	
	init() {
		setupSearchPublisher()
	}
	
	private var workspaceManager: WorkspaceManagerViewModel?   // NEW
	
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
		rootSnapshotCache.removeAll()
		searchIndex = nil

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
					// A search reuses its snapshots and index while the index generations stay the same
					self?.performSearch(cancelExisting: false)
				}
			}
			.store(in: &cancellables)
		

		// Re-perform search once a folder has completely finished (re)loading
		fileManager.folderDidFinishLoadingPublisher
			.sink { [weak self] _ in
				Task { @MainActor in
					// A search reuses its snapshots and index while the index generations stay the same
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
		
		// Subscribe to file system changes to re-run an active search
		fileManager.fileSystemChangedPublisher
			.sink { [weak self] in
				Task { @MainActor in
					// Only re-perform search if we have an active search
					if let self = self, !self.searchText.isEmpty {
						self.performSearch(cancelExisting: false)
					}
				}
			}
			.store(in: &cancellables)

		// While reading runs, re-run an active search so its results grow with what is read
		fileManager.readingFileCounts
			.dropFirst()
			.throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
			.sink { [weak self] _ in
				Task { @MainActor in
					guard let self, !self.searchText.isEmpty else { return }
					self.performSearch(cancelExisting: false)
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
	}

	func cancelSearch() {
		clearSearchResultsOnly()
		workspaceSwitchTask?.cancel()
		workspaceSwitchTask = nil
		searchText = ""
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
		let searchTextCapture = String(searchText.prefix(1_000))
		
		// The main actor only gathers each root's index values; the search builds and walks them off it
		let inputs = fileManager.map(searchRootInputs(of:)) ?? []
		let reusableIndex = searchIndex
		
		searchTask = Task { [weak self] in
			guard let self else { return }
			
			await MainActor.run { self.isSearching = true }
			
			do {
				let work = Task.detached(priority: .userInitiated) {
					try await SearchFileTreeViewModel.search(inputs, reusing: reusableIndex, forPattern: searchTextCapture)
				}
				let run = try await withTaskCancellationHandler {
					try await work.value
				} onCancel: {
					work.cancel()
				}
				
				await MainActor.run { self.store(run, for: inputs) }
				
				if Task.isCancelled { throw CancellationError() }
				
				await MainActor.run {
					let found = run.matches.map { self.searchFolder(from: $0) }
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
	
	private struct SnapshotFolder: Sendable {
		let id: UUID
		let name: String
		let relativePath: String
		let children: [SnapshotItem]
	}
	
	private enum SnapshotItem: Sendable {
		case folder(SnapshotFolder)
		case file(SnapshotFile)
	}
	
	private struct SnapshotFile: Sendable {
		let id: UUID
		let name: String
		let relativePath: String
	}
	
	/// What a search needs of one visible root folder: its cached snapshot, or the index contents to build one from.
	private struct SearchRootInput: Sendable {
		enum Source: Sendable {
			case cached(SnapshotFolder)
			case contents(RootFolderIndex.Contents)
		}
		
		let rootID: UUID
		let rootName: String
		let rootRelativePath: String
		let rootPath: String
		let generation: UInt64
		let showEmptyFolders: Bool
		let source: Source
	}
	
	/// The path index over every file of the snapshots, with the index generation of each root it was built from.
	private struct SearchIndexState: Sendable {
		let index: PathSearchIndex
		let files: [SnapshotFile]
		let generations: [UUID: UInt64]
	}
	
	/// A folder of the results: only its matching files and the folders that hold one.
	private struct MatchedFolder: Sendable {
		let id: UUID
		let name: String
		let relativePath: String
		let rootID: UUID
		let rootPath: String
		let children: [MatchedItem]
		let bestScore: Int
	}
	
	private enum MatchedItem: Sendable {
		case folder(MatchedFolder)
		case file(SnapshotFile, score: Int)
	}
	
	/// What one search found, with the snapshots and index it built so the next search can reuse them.
	private struct SearchRun: Sendable {
		let snapshots: [SnapshotFolder]
		let searchIndex: SearchIndexState
		let matches: [MatchedFolder]
	}
	
	/// The search inputs of the visible root folders. Reads the index contents only of a root whose cached snapshot is stale.
	@MainActor
	private func searchRootInputs(of fm: RepoFileManagerViewModel) -> [SearchRootInput] {
		fm.visibleRootFolders.compactMap { root in
			let rootPath = root.standardizedFullPath
			guard let index = fm.rootFolderIndexes[rootPath] else { return nil }
			let source: SearchRootInput.Source
			if let cached = rootSnapshotCache[root.id],
			cached.rootPath == rootPath,
			cached.generation == index.generation,
			cached.showEmptyFolders == fm.showEmptyFolders {
				source = .cached(cached.snapshot)
			} else {
				source = .contents(index.contents)
			}
			return SearchRootInput(
				rootID: root.id,
				rootName: root.name,
				rootRelativePath: root.relativePath,
				rootPath: rootPath,
				generation: index.generation,
				showEmptyFolders: fm.showEmptyFolders,
				source: source
			)
		}
	}
	
	/// Keeps the snapshots and index of a search for the next one. Roots that are gone drop out of the cache.
	@MainActor
	private func store(_ run: SearchRun, for inputs: [SearchRootInput]) {
		var cache: [UUID: RootSnapshotCacheEntry] = [:]
		for (input, snapshot) in zip(inputs, run.snapshots) {
			cache[input.rootID] = RootSnapshotCacheEntry(
				rootPath: input.rootPath,
				generation: input.generation,
				showEmptyFolders: input.showEmptyFolders,
				snapshot: snapshot
			)
		}
		rootSnapshotCache = cache
		searchIndex = run.searchIndex
	}
	
	/// Builds the snapshots and path index the inputs miss, then finds the files that match the pattern.
	/// Runs off the main actor; only the index search itself has the 5 s timeout.
	private nonisolated static func search(
		_ inputs: [SearchRootInput],
		reusing reusableIndex: SearchIndexState?,
		forPattern pattern: String
	) async throws -> SearchRun {
		var snapshots: [SnapshotFolder] = []
		snapshots.reserveCapacity(inputs.count)
		for input in inputs {
			try Task.checkCancellation()
			switch input.source {
			case .cached(let snapshot):
				snapshots.append(snapshot)
			case .contents(let contents):
				snapshots.append(makeSnapshotFolder(of: input, contents: contents))
			}
		}
		
		let generations = Dictionary(inputs.map { ($0.rootID, $0.generation) }, uniquingKeysWith: { _, last in last })
		let searchIndex: SearchIndexState
		if let reusableIndex, reusableIndex.generations == generations {
			searchIndex = reusableIndex
		} else {
			var files: [SnapshotFile] = []
			for snapshot in snapshots {
				collectFiles(of: snapshot, into: &files)
			}
			try Task.checkCancellation()
			searchIndex = SearchIndexState(
				index: await PathSearchIndex(paths: files.map(\.relativePath)),
				files: files,
				generations: generations
			)
		}
		try Task.checkCancellation()
		
		let candidates = try await withTimeout(seconds: 5) {
			await searchIndex.index.search(pattern, limit: resultLimit * 4)
		}
		
		// De-duplicate indices (path_search_find can emit duplicates), then
		// give each kept file a rank-based score: earlier in the list scores higher.
		var seen = Set<Int>()
		let ranked = candidates.filter { seen.insert($0.index).inserted }.prefix(resultLimit)
		var scores: [UUID: Int] = [:]
		for (rank, candidate) in ranked.enumerated() where searchIndex.files.indices.contains(candidate.index) {
			scores[searchIndex.files[candidate.index].id] = resultLimit - rank
		}
		
		let matches: [MatchedFolder] = scores.isEmpty
			? []
			: zip(inputs, snapshots).compactMap { input, snapshot in
				matchedFolder(from: snapshot, rootID: input.rootID, rootPath: input.rootPath, scores: scores)
			}
		return SearchRun(snapshots: snapshots, searchIndex: searchIndex, matches: matches)
	}
	
	/// The snapshot of a root folder, built from its index so it holds the folders that are not opened too.
	/// Folders come before files, each sorted by lowercased name.
	private nonisolated static func makeSnapshotFolder(of input: SearchRootInput, contents: RootFolderIndex.Contents) -> SnapshotFolder {
		func id(of relativePath: String) -> UUID {
			RepoFileManagerViewModel.fileID(
				forStandardizedPath: StandardizedPath.join(standardizedRoot: contents.rootPath, standardizedRelativePath: relativePath)
			)
		}
		/// Each path with its name, sorted by the lowercased name alone.
		func named(_ paths: Set<String>) -> [(path: String, name: String)] {
			paths
				.map { path -> (key: String, path: String, name: String) in
					let name = (path as NSString).lastPathComponent
					return (name.lowercased(), path, name)
				}
				.sorted { $0.key < $1.key }
				.map { (path: $0.path, name: $0.name) }
		}
		func children(of folder: RootFolderIndex.Contents.Folder) -> [SnapshotItem] {
			let folders = named(folder.childFolderPaths).compactMap { child -> SnapshotItem? in
				guard let subfolder = contents.folders[child.path],
				input.showEmptyFolders || !subfolder.isKnownEmpty else { return nil }
				return .folder(SnapshotFolder(id: id(of: child.path), name: child.name, relativePath: child.path, children: children(of: subfolder)))
			}
			let files = named(folder.childFilePaths).map { child in
				SnapshotItem.file(SnapshotFile(id: id(of: child.path), name: child.name, relativePath: child.path))
			}
			return folders + files
		}
		return SnapshotFolder(
			id: input.rootID,
			name: input.rootName,
			relativePath: input.rootRelativePath,
			children: contents.folders[""].map(children(of:)) ?? []
		)
	}
	
	private nonisolated static func collectFiles(of folder: SnapshotFolder, into files: inout [SnapshotFile]) {
		for child in folder.children {
			switch child {
			case .folder(let subfolder):
				collectFiles(of: subfolder, into: &files)
			case .file(let file):
				files.append(file)
			}
		}
	}
	
	/// The folder with only its matching files and the folders that hold one, or nil when it holds none.
	private nonisolated static func matchedFolder(
		from folder: SnapshotFolder,
		rootID: UUID,
		rootPath: String,
		scores: [UUID: Int]
	) -> MatchedFolder? {
		var children: [MatchedItem] = []
		var bestScore = 0
		for child in folder.children {
			switch child {
			case .folder(let subfolder):
				if let matched = matchedFolder(from: subfolder, rootID: rootID, rootPath: rootPath, scores: scores) {
					bestScore = max(bestScore, matched.bestScore)
					children.append(.folder(matched))
				}
			case .file(let file):
				if let score = scores[file.id] {
					bestScore = max(bestScore, score)
					children.append(.file(file, score: score))
				}
			}
		}
		guard !children.isEmpty else { return nil }
		return MatchedFolder(
			id: folder.id,
			name: folder.name,
			relativePath: folder.relativePath,
			rootID: rootID,
			rootPath: rootPath,
			children: children,
			bestScore: bestScore
		)
	}
	
	/// The view model of a matched folder, linked to the tree items it and its files show.
	@MainActor
	private func searchFolder(from matched: MatchedFolder) -> SearchFolderViewModel {
		var children: [SearchFileSystemItem] = matched.children.map { child -> SearchFileSystemItem in
			switch child {
			case .folder(let subfolder):
				return .folder(searchFolder(from: subfolder))
			case .file(let file, let score):
				// Exact lookup under the root, as the tree item or a file view model that reads it by path
				let realFileVM = fileManager?.promptFile(
					forStandardizedPath: StandardizedPath.join(standardizedRoot: matched.rootPath, standardizedRelativePath: file.relativePath)
				)
				// The result takes the file's id, so selection changes find it.
				return .file(SearchFileViewModel(
					id: realFileVM?.id ?? file.id,
					name: file.name,
					relativePath: file.relativePath,
					matchScore: score,
					originalFile: realFileVM
				))
			}
		}
		
		// Sort children by score
		sortChildren(&children)
		
		// Resolve originalFolder against the correct root when possible
		var resolvedOriginalFolder: FolderViewModel? = nil
		if let rootFolder = fileManager?.visibleRootFolders.first(where: { $0.id == matched.rootID }) {
			let fullPath: String
			if matched.relativePath.isEmpty {
				fullPath = rootFolder.fullPath
			} else {
				fullPath = (rootFolder.fullPath as NSString).appendingPathComponent(matched.relativePath)
			}
			resolvedOriginalFolder = fileManager?.findFolderByFullPath(fullPath)
		} else {
			// Fallback to previous behavior
			resolvedOriginalFolder = fileManager?.findFolderByRelativePath(matched.relativePath)
		}
		
		let folder = SearchFolderViewModel(
			id: resolvedOriginalFolder?.id ?? matched.id,
			name: matched.name,
			relativePath: matched.relativePath,
			isExpanded: true,
			checkboxState: .unchecked,
			children: children,
			bestDescendantScore: matched.bestScore,
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
	
	private nonisolated static func withTimeout<T: Sendable>(seconds: UInt64, operation: @escaping @Sendable () async -> T) async throws -> T {
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
