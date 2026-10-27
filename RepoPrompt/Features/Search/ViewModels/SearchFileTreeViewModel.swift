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
	
	/// The path index of one root folder, kept in step with the root's index through its path changes.
	private struct RootNameIndex {
		let index: PathSearchIndex
		/// The root index it follows.
		let source: ObjectIdentifier
		/// The generation of the root index it holds the paths of.
		let generation: UInt64
	}
	
	/// The path index of each visible root folder, by root id.
	private var nameIndexes: [UUID: RootNameIndex] = [:]
	
	/// The last search or index update. Each run waits for the one before it, so only one changes the path indexes at a time.
	private var lastSearchRun: Task<Void, Never>?
	
	// Whether the user opened or closed a result folder, kept when the results refresh
	private var folderIsOpen: [UUID: Bool] = [:]
	
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
		nameIndexes.removeAll()

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
					// A search updates its path indexes with the changed paths only
					self?.performSearch(cancelExisting: false)
				}
			}
			.store(in: &cancellables)
		

		// Re-perform search once a folder has completely finished (re)loading
		fileManager.folderDidFinishLoadingPublisher
			.sink { [weak self] _ in
				Task { @MainActor in
					guard let self else { return }
					// The first search after reading finds the path indexes ready
					if self.searchText.isEmpty {
						self.prepareNameIndexes()
					} else {
						self.performSearch(cancelExisting: false)
					}
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
		folderIsOpen.removeAll()
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
		
		guard !searchText.isEmpty else { return }
		
		// ------------------------------------------------------------------
		// NEW: Hard-cap the length of the search string to avoid runaway
		// regex compilation or excessive work. Anything beyond 1 000 chars
		// is simply ignored.
		// ------------------------------------------------------------------
		let searchTextCapture = String(searchText.prefix(1_000))
		
		// The results on screen stay until this search replaces them
		isSearching = true
		let previous = lastSearchRun
		let task = Task { [weak self] in
			await previous?.value
			guard let self else { return }
			let inputs = self.fileManager.map(self.searchRootInputs(of:)) ?? []
			// Path changes are applied even when the search is cancelled, so the next run starts from them
			let indexes = await Self.sync(inputs)
			self.store(indexes, for: inputs)
			
			do {
				try Task.checkCancellation()
				let matches = try await Self.matches(of: searchTextCapture, in: inputs, indexes: indexes)
				try Task.checkCancellation()
				
				self.folderIndex.removeAll()
				self.fileIndex.removeAll()
				let found = matches.map { self.resultFolder(from: $0) }
				self.rootFolders     = found
				self.noResultsFound  = found.isEmpty
				self.hasSearchResults = !found.isEmpty
				
				// Re-index for O(1) look-ups.
				self.buildIndexes(for: self.rootFolders, parent: nil)
				self.isSearching = false
			} catch is CancellationError {
				// Whatever cancelled this search sets the state that follows it
				return
			} catch {
				self.rootFolders.removeAll()
				self.noResultsFound   = true
				self.hasSearchResults = false
				self.isSearching = false
			}
			
			self.searchTask = nil
			if self.pendingSearchRefresh {
				self.pendingSearchRefresh = false
				self.performSearch(cancelExisting: false)
			}
		}
		lastSearchRun = task
		searchTask = task
	}
	
	/// Brings the path indexes of the visible root folders in step ahead of a search.
	@MainActor
	private func prepareNameIndexes() {
		let previous = lastSearchRun
		lastSearchRun = Task { [weak self] in
			await previous?.value
			guard let self else { return }
			let inputs = self.fileManager.map(self.searchRootInputs(of:)) ?? []
			self.store(await Self.sync(inputs), for: inputs)
		}
	}
	
	/// A file or folder of the results.
	fileprivate struct ResultEntry: Sendable {
		let id: UUID
		let name: String
		let relativePath: String
	}
	
	/// What a search needs of one visible root folder: the path changes for its path index, or the index contents to build one from.
	private struct SearchRootInput: Sendable {
		enum Sync: Sendable {
			case changes(PathSearchIndex, [RootFolderIndex.PathChange])
			case rebuild(RootFolderIndex.Contents)
		}
		
		let rootID: UUID
		let rootName: String
		let rootRelativePath: String
		let rootPath: String
		let source: ObjectIdentifier
		let generation: UInt64
		let sync: Sync
	}
	
	/// A folder of the results: only its matches and the folders that hold one.
	fileprivate struct MatchedFolder: Sendable {
		let id: UUID
		let name: String
		let relativePath: String
		let rootID: UUID
		let rootPath: String
		let children: [MatchedItem]
		let bestScore: Int
	}
	
	fileprivate enum MatchedItem: Sendable {
		case folder(MatchedFolder)
		/// A folder whose own path matches, shown with everything in it.
		case contents(ResultEntry, score: Int)
		case file(ResultEntry, score: Int)
		
		var score: Int {
			switch self {
			case .folder(let folder): return folder.bestScore
			case .contents(_, let score), .file(_, let score): return score
			}
		}
	}
	
	/// The children of a result folder before the results view opens it.
	fileprivate enum UnbuiltChildren {
		/// The matches under a folder that holds matches.
		case matches(MatchedFolder)
		/// Everything in a folder whose own path matches, or in a folder inside it, as its root index holds it.
		case contents(relativePath: String, rootID: UUID, rootPath: String)
	}
	
	/// The search inputs of the visible root folders. A root whose path index follows its root index gets the
	/// path changes since, any other root the contents to build one.
	@MainActor
	private func searchRootInputs(of fm: RepoFileManagerViewModel) -> [SearchRootInput] {
		fm.visibleRootFolders.compactMap { root in
			let rootPath = root.standardizedFullPath
			guard let index = fm.rootFolderIndexes[rootPath] else { return nil }
			let source = ObjectIdentifier(index)
			let sync: SearchRootInput.Sync
			if let kept = nameIndexes[root.id], kept.source == source, let changes = index.pathChanges(after: kept.generation) {
				sync = .changes(kept.index, changes)
			} else {
				sync = .rebuild(index.contents)
			}
			return SearchRootInput(
				rootID: root.id,
				rootName: root.name,
				rootRelativePath: root.relativePath,
				rootPath: rootPath,
				source: source,
				generation: index.generation,
				sync: sync
			)
		}
	}
	
	/// Keeps the path indexes for the next run. Roots that are gone drop out.
	@MainActor
	private func store(_ indexes: [PathSearchIndex], for inputs: [SearchRootInput]) {
		var kept: [UUID: RootNameIndex] = [:]
		for (input, index) in zip(inputs, indexes) {
			kept[input.rootID] = RootNameIndex(index: index, source: input.source, generation: input.generation)
		}
		nameIndexes = kept
	}
	
	/// The path index of each input, with its path changes applied or built from its contents. Runs off the main actor.
	private nonisolated static func sync(_ inputs: [SearchRootInput]) async -> [PathSearchIndex] {
		var indexes: [PathSearchIndex] = []
		indexes.reserveCapacity(inputs.count)
		for input in inputs {
			switch input.sync {
			case .changes(let index, let changes):
				await apply(changes, to: index)
				indexes.append(index)
			case .rebuild(let contents):
				var files: [String] = []
				var folders: [String] = []
				folders.reserveCapacity(contents.folders.count)
				for (path, folder) in contents.folders {
					if !path.isEmpty {
						folders.append(path)
					}
					files.append(contentsOf: folder.childFilePaths)
				}
				indexes.append(await PathSearchIndex(paths: files, folderPaths: folders))
			}
		}
		return indexes
	}
	
	/// Applies path changes in order, each run of file adds, folder adds or removes as one batch.
	private nonisolated static func apply(_ changes: [RootFolderIndex.PathChange], to index: PathSearchIndex) async {
		enum Batch: Equatable {
			case files, folders, removals
		}
		func flush(_ batch: Batch?, _ paths: [String]) async {
			switch batch {
			case .files: await index.add(paths, areFolders: false)
			case .folders: await index.add(paths, areFolders: true)
			case .removals: await index.remove(paths)
			case nil: break
			}
		}
		var batch: Batch?
		var paths: [String] = []
		for change in changes {
			let next: Batch
			let path: String
			switch change {
			case .added(let added, let isFolder):
				next = isFolder ? .folders : .files
				path = added
			case .removed(let removed):
				next = .removals
				path = removed
			}
			if next != batch {
				await flush(batch, paths)
				paths.removeAll(keepingCapacity: true)
				batch = next
			}
			paths.append(path)
		}
		await flush(batch, paths)
	}
	
	/// Finds every file and folder of each root that matches the pattern. Runs off the main actor;
	/// each index search has the 5 s timeout.
	private nonisolated static func matches(
		of pattern: String,
		in inputs: [SearchRootInput],
		indexes: [PathSearchIndex]
	) async throws -> [MatchedFolder] {
		var found: [MatchedFolder] = []
		for (input, index) in zip(inputs, indexes) {
			try Task.checkCancellation()
			let candidates = try await withTimeout(seconds: 5) {
				await index.search(pattern, limit: Int.max)
			}
			try Task.checkCancellation()
			if let matched = matchedRoot(of: input, candidates: candidates) {
				found.append(matched)
			}
		}
		return found
	}
	
	/// The root folder with only its matches and the folders that hold one, or nil when nothing matched.
	/// A folder whose own path matches holds everything in it, so the files and folders in it are not matched again.
	/// Earlier matches score higher.
	private nonisolated static func matchedRoot(of input: SearchRootInput, candidates: [PathSearchIndex.Candidate]) -> MatchedFolder? {
		func id(of relativePath: String) -> UUID {
			RepoFileManagerViewModel.fileID(
				forStandardizedPath: StandardizedPath.join(standardizedRoot: input.rootPath, standardizedRelativePath: relativePath)
			)
		}
		func parentPath(of path: String) -> String {
			guard let slash = path.lastIndex(of: "/") else { return "" }
			return String(path[..<slash])
		}
		
		let matchedFolderPaths = Set(candidates.lazy.filter(\.isFolder).map(\.path))
		func isInsideMatchedFolder(_ path: String) -> Bool {
			var current = path
			while !current.isEmpty {
				current = parentPath(of: current)
				if matchedFolderPaths.contains(current) { return true }
			}
			return false
		}
		
		var items: [String: [MatchedItem]] = [:]
		var subfolderPaths: [String: Set<String>] = [:]
		var score = candidates.count
		for candidate in candidates {
			defer { score -= 1 }
			guard !isInsideMatchedFolder(candidate.path) else { continue }
			let entry = ResultEntry(id: id(of: candidate.path), name: candidate.filename, relativePath: candidate.path)
			var parent = parentPath(of: candidate.path)
			items[parent, default: []].append(candidate.isFolder ? .contents(entry, score: score) : .file(entry, score: score))
			while !parent.isEmpty {
				let grandparent = parentPath(of: parent)
				guard subfolderPaths[grandparent, default: []].insert(parent).inserted else { break }
				parent = grandparent
			}
		}
		guard !items.isEmpty else { return nil }
		
		func folder(at path: String, id folderID: UUID, name: String, relativePath: String) -> MatchedFolder {
			var children = items[path] ?? []
			for subfolder in subfolderPaths[path] ?? [] {
				let subfolderName = subfolder.lastIndex(of: "/").map { String(subfolder[subfolder.index(after: $0)...]) } ?? subfolder
				children.append(.folder(folder(at: subfolder, id: id(of: subfolder), name: subfolderName, relativePath: subfolder)))
			}
			return MatchedFolder(
				id: folderID,
				name: name,
				relativePath: relativePath,
				rootID: input.rootID,
				rootPath: input.rootPath,
				children: children,
				bestScore: children.map(\.score).max() ?? 0
			)
		}
		return folder(at: "", id: input.rootID, name: input.rootName, relativePath: input.rootRelativePath)
	}
	
	/// The view model of a root folder of the results. Its children are built when the results view opens it.
	@MainActor
	private func resultFolder(from matched: MatchedFolder) -> SearchFolderViewModel {
		makeFolder(
			id: matched.id,
			name: matched.name,
			relativePath: matched.relativePath,
			rootID: matched.rootID,
			opensByDefault: true,
			bestScore: matched.bestScore,
			unbuiltChildren: .matches(matched)
		)
	}
	
	/// The view model of a result folder, linked to the tree item it shows. It opens as the user left it,
	/// else as `opensByDefault` says, and it has no unbuilt children when it holds nothing.
	@MainActor
	private func makeFolder(
		id: UUID,
		name: String,
		relativePath: String,
		rootID: UUID,
		opensByDefault: Bool,
		bestScore: Int,
		unbuiltChildren: UnbuiltChildren?
	) -> SearchFolderViewModel {
		// Resolve originalFolder against the correct root when possible
		var resolvedOriginalFolder: FolderViewModel? = nil
		if let rootFolder = fileManager?.visibleRootFolders.first(where: { $0.id == rootID }) {
			let fullPath: String
			if relativePath.isEmpty {
				fullPath = rootFolder.fullPath
			} else {
				fullPath = (rootFolder.fullPath as NSString).appendingPathComponent(relativePath)
			}
			resolvedOriginalFolder = fileManager?.findFolderByFullPath(fullPath)
		} else {
			// Fallback to previous behavior
			resolvedOriginalFolder = fileManager?.findFolderByRelativePath(relativePath)
		}
		
		let folderID = resolvedOriginalFolder?.id ?? id
		let folder = SearchFolderViewModel(
			id: folderID,
			name: name,
			relativePath: relativePath,
			isExpanded: folderIsOpen[folderID] ?? opensByDefault,
			checkboxState: .unchecked,
			children: [],
			bestDescendantScore: bestScore,
			originalFolder: resolvedOriginalFolder
		)
		folder.unbuiltChildren = unbuiltChildren
		
		// Update checkbox state
		updateSearchFolderState(folder)
		
		return folder
	}
	
	/// The view model of a folder shown with everything in it, closed until the user opens it.
	@MainActor
	private func makeContentsFolder(_ entry: ResultEntry, rootID: UUID, rootPath: String, score: Int) -> SearchFolderViewModel {
		let node = fileManager?.rootFolderIndexes[rootPath]?.folders[entry.relativePath]
		let holdsAnything = node.map { !$0.childFolderPaths.isEmpty || !$0.childFilePaths.isEmpty } ?? false
		return makeFolder(
			id: entry.id,
			name: entry.name,
			relativePath: entry.relativePath,
			rootID: rootID,
			opensByDefault: false,
			bestScore: score,
			unbuiltChildren: holdsAnything ? .contents(relativePath: entry.relativePath, rootID: rootID, rootPath: rootPath) : nil
		)
	}
	
	/// The view model of a result file, linked to the tree item it shows.
	@MainActor
	private func makeFile(_ file: ResultEntry, rootPath: String, score: Int) -> SearchFileViewModel {
		// Exact lookup under the root, as the tree item or a file view model that reads it by path
		let realFileVM = fileManager?.promptFile(
			forStandardizedPath: StandardizedPath.join(standardizedRoot: rootPath, standardizedRelativePath: file.relativePath)
		)
		// The result takes the file's id, so selection changes find it.
		return SearchFileViewModel(
			id: realFileVM?.id ?? file.id,
			name: file.name,
			relativePath: file.relativePath,
			matchScore: score,
			originalFile: realFileVM
		)
	}
	
	/// The entries of each path, sorted by lowercased name, as the file tree sorts them.
	private static func entries(of paths: Set<String>, rootPath: String) -> [ResultEntry] {
		paths
			.map { path -> (key: String, entry: ResultEntry) in
				let name = (path as NSString).lastPathComponent
				let id = RepoFileManagerViewModel.fileID(
					forStandardizedPath: StandardizedPath.join(standardizedRoot: rootPath, standardizedRelativePath: path)
				)
				return (name.lowercased(), ResultEntry(id: id, name: name, relativePath: path))
			}
			.sorted { $0.key < $1.key }
			.map(\.entry)
	}
	
	/// Builds the children of a folder of the current results the first time the results view opens it.
	/// Returns whether it built them; a folder of earlier results or one already built builds nothing.
	@MainActor
	@discardableResult
	func buildChildren(of folder: SearchFolderViewModel) -> Bool {
		guard let unbuilt = folder.unbuiltChildren, folderIndex[folder.id] === folder else { return false }
		folder.unbuiltChildren = nil
		var children: [SearchFileSystemItem]
		switch unbuilt {
		case .matches(let matched):
			children = matched.children.map { child -> SearchFileSystemItem in
				switch child {
				case .folder(let subfolder):
					return .folder(makeFolder(
						id: subfolder.id,
						name: subfolder.name,
						relativePath: subfolder.relativePath,
						rootID: subfolder.rootID,
						opensByDefault: true,
						bestScore: subfolder.bestScore,
						unbuiltChildren: .matches(subfolder)
					))
				case .contents(let snapshot, let score):
					return .folder(makeContentsFolder(snapshot, rootID: matched.rootID, rootPath: matched.rootPath, score: score))
				case .file(let file, let score):
					return .file(makeFile(file, rootPath: matched.rootPath, score: score))
				}
			}
			// Sort children by score
			sortChildren(&children)
		case .contents(let relativePath, let rootID, let rootPath):
			// Folders then files by name, as the root index holds them now
			guard let fm = fileManager, let index = fm.rootFolderIndexes[rootPath], let node = index.folders[relativePath] else {
				children = []
				break
			}
			let subfolderPaths = node.childFolderPaths.filter { path in
				fm.showEmptyFolders || index.folders[path]?.isKnownEmpty != true
			}
			let folders = Self.entries(of: subfolderPaths, rootPath: rootPath).map { entry in
				SearchFileSystemItem.folder(makeContentsFolder(entry, rootID: rootID, rootPath: rootPath, score: 0))
			}
			let files = Self.entries(of: node.childFilePaths, rootPath: rootPath).map { entry in
				SearchFileSystemItem.file(makeFile(entry, rootPath: rootPath, score: 0))
			}
			children = folders + files
		}
		folder.children = children
		buildIndexes(for: [folder], parent: folder.parent)
		updateSearchFolderState(folder)
		return true
	}
	
	/// Keeps a result folder open or closed when the results refresh.
	@MainActor
	func setFolder(_ folder: SearchFolderViewModel, isOpen: Bool) {
		folder.isExpanded = isOpen
		folderIsOpen[folder.id] = isOpen
	}
	
	/// The checkbox state of children that are not built yet, read from the selection of their root folder.
	@MainActor
	private func checkboxState(of unbuilt: UnbuiltChildren) -> CheckboxState {
		switch unbuilt {
		case .contents(let relativePath, _, let rootPath):
			return fileManager?.rootFolderIndexes[rootPath]?.checkboxState(ofFolder: relativePath) ?? .unchecked
		case .matches(let matched):
			guard let index = fileManager?.rootFolderIndexes[matched.rootPath] else { return .unchecked }
			return Self.checkboxState(of: matched.children, in: index)
		}
	}
	
	/// Ticked when every item is ticked, mixed when some are, as `updateSearchFolderState` counts built children.
	@MainActor
	private static func checkboxState(of items: [MatchedItem], in index: RootFolderIndex) -> CheckboxState {
		var checkedCount = 0
		var uncheckedCount = 0
		for item in items {
			let state: CheckboxState
			switch item {
			case .folder(let subfolder):
				state = checkboxState(of: subfolder.children, in: index)
			case .contents(let entry, _):
				state = index.checkboxState(ofFolder: entry.relativePath)
			case .file(let file, _):
				state = index.selectedFilePaths.contains(file.relativePath) ? .checked : .unchecked
			}
			switch state {
			case .checked: checkedCount += 1
			case .unchecked: uncheckedCount += 1
			case .mixed: return .mixed
			}
		}
		if checkedCount > 0 && uncheckedCount > 0 { return .mixed }
		return checkedCount > 0 ? .checked : .unchecked
	}
	
	/// The full paths of the files in children that are not built yet, as their root index holds them now.
	@MainActor
	private func filePaths(in unbuilt: UnbuiltChildren) -> [String] {
		var paths: [String] = []
		func addFiles(under relativePath: String, rootPath: String) {
			guard let index = fileManager?.rootFolderIndexes[rootPath] else { return }
			var pending = [relativePath]
			while let path = pending.popLast() {
				guard let node = index.folders[path] else { continue }
				for file in node.childFilePaths {
					paths.append(StandardizedPath.join(standardizedRoot: rootPath, standardizedRelativePath: file))
				}
				pending.append(contentsOf: node.childFolderPaths)
			}
		}
		func addFiles(of matched: MatchedFolder) {
			for child in matched.children {
				switch child {
				case .folder(let subfolder):
					addFiles(of: subfolder)
				case .contents(let entry, _):
					addFiles(under: entry.relativePath, rootPath: matched.rootPath)
				case .file(let file, _):
					paths.append(StandardizedPath.join(standardizedRoot: matched.rootPath, standardizedRelativePath: file.relativePath))
				}
			}
		}
		switch unbuilt {
		case .matches(let matched):
			addFiles(of: matched)
		case .contents(let relativePath, _, let rootPath):
			addFiles(under: relativePath, rootPath: rootPath)
		}
		return paths
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
				if let unbuilt = f.unbuiltChildren {
					toSelect.append(contentsOf: filePaths(in: unbuilt))
					return
				}
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
				// Folders whose children are not built read their state from the selection, which holds the files now
				self.updateFolderStateUpChain(folder)
			}

		case .checked, .mixed:
			// Collect all descendant file paths that are currently checked
			var toUnselect: [String] = []

			func walkUnselect(_ f: SearchFolderViewModel) {
				if let unbuilt = f.unbuiltChildren {
					toUnselect.append(contentsOf: filePaths(in: unbuilt))
					return
				}
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
				// Folders whose children are not built read their state from the selection, which no longer holds the files
				self.updateFolderStateUpChain(folder)
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
		if let unbuilt = folder.unbuiltChildren {
			folder.checkboxState = checkboxState(of: unbuilt)
			return
		}
		
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
	
	/// The children the folder holds and has not built yet; nil once they are built or when it holds none.
	fileprivate var unbuiltChildren: SearchFileTreeViewModel.UnbuiltChildren?
	
	/// Whether the folder holds children it builds when the results view opens it.
	var hasUnbuiltChildren: Bool { unbuiltChildren != nil }
	
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
