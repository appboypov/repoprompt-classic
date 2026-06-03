import Foundation
import Combine
import AppKit
import SwiftUI

enum GitDiffInclusionMode: String, CaseIterable, Codable, Sendable {
    case none = "none"
    case selectedFiles = "selectedFiles"
    case all = "all"

    var displayName: String {
        switch self {
        case .none: return "None"
        case .selectedFiles: return "Selected"
        case .all: return "All"
        }
    }
}

@MainActor
final class GitViewModel: ObservableObject {
    @Published var selectedRootFolder: FolderViewModel?
    @Published var unstagedFiles: [VCSUncommittedFile] = [] {
		didSet {
			updateUnstagedFileSearchIndex()
		}
	}
    @Published var currentBranch: String?
    @Published var errorMessage: String?
    @Published var availableRootFolders: [FolderViewModel] = []
	@Published private var gitEnabledStatus: [String: Bool] = [:] // fullPath -> isGitRepo
	@Published private(set) var fileSelectionStates: [String: Bool] = [:] { // relativePath -> isSelected
		didSet {
			assert(Thread.isMainThread, "fileSelectionStates mutated off main thread")
        }
    }
	
	/// Thread-safe publisher for external observers of fileSelectionStates.
	/// Always delivers values on the main run loop to prevent data races from background subscribers.
	var fileSelectionStatesPublisher: AnyPublisher<[String: Bool], Never> {
		$fileSelectionStates
			.receive(on: RunLoop.main)
			.eraseToAnyPublisher()
    }
	
	@Published var isPopoverVisible = false
	@Published var availableBranches: [VCSBranch] = []
	@Published var availableRemoteBranches: [VCSBranch] = []
	@Published var availableTags: [VCSTag] = []
	@Published var selectedDiffBranch: String = "HEAD"
	@Published var fileSearchText: String = ""
	@Published var isFilteringPaused: Bool = false
    
	@Published var totalAdditions: Int = 0
	@Published var totalDeletions: Int = 0
	@Published var commitDelta: (ahead: Int, behind: Int)? = nil
	@Published var isBulkSelectionRunning: Bool = false
	@Published var isLoadingStatus: Bool = false
	
	// Persistent setting for git diff inclusion mode
	@Published var gitDiffInclusionMode: GitDiffInclusionMode = .none
	@AppStorage("gitDiffInclusionMode") private var gitDiffInclusionModeStorage: String = GitDiffInclusionMode.none.rawValue
	
	// Background actor for git operations
	private let statusActor: GitStatusActor
	private var statusStreamTask: Task<Void, Never>?
	
	private var cancellables = Set<AnyCancellable>()
    private weak var fileManager: RepoFileManagerViewModel?
	private var searchDebounceTask: Task<Void, Never>?
	private var rootUpdateTask: Task<Void, Never>?
	private var rootUpdateGeneration: Int = 0
	private var lastVisibleRootPaths: [String] = []
	
	private var resolvedStateTask: Task<Void, Never>?
	private var latestStatusGeneration: Int = 0
	private var latestStatusRootPath: String?
	private var currentGitRootPath: String?
	
	private var unstagedFileSearchIndex: [(file: VCSUncommittedFile, pathKey: String)] = []
	
	// Cache for git diffs to avoid regenerating for token counting
	private var cachedDiff: String?
	private var cachedDiffMode: GitDiffInclusionMode?
	private var cachedDiffBranch: String?
	private var cachedSelectedFiles: Set<String> = []
    
	init(fileManager: RepoFileManagerViewModel? = nil,
			statusActor: GitStatusActor = GitStatusActor()) {
        self.fileManager = fileManager
		self.statusActor = statusActor
        
        // Initialize @Published from @AppStorage
        self.gitDiffInclusionMode = GitDiffInclusionMode(rawValue: gitDiffInclusionModeStorage) ?? .none
        
		setupActorSubscription()
		setupModeObservers()
		setupFileManagerObservers(fileManager)
	}
	
	private func setupActorSubscription() {
		statusStreamTask = Task { [weak self, statusActor] in
			for await snapshot in statusActor.statusStream {
				guard let self = self else { break }
				self.apply(snapshot)
			}
		}
	}
	
	private func apply(_ snapshot: GitStatusActor.GitStatusSnapshot) {
		// Only apply if this snapshot matches the current selected root
		// (or if we have no selection yet)
		if let selected = selectedRootFolder, !snapshot.rootPath.isEmpty {
			guard selected.fullPath == snapshot.rootPath else { return }
		}
		
		let filesChanged = snapshot.unstagedFiles != unstagedFiles
		
		// Map snapshot fields to @Published UI state
		self.unstagedFiles = snapshot.unstagedFiles
		self.currentBranch = snapshot.currentBranch
		self.errorMessage = snapshot.errorMessage
		self.totalAdditions = snapshot.totalAdditions
		self.totalDeletions = snapshot.totalDeletions
		self.commitDelta = snapshot.commitDelta
		self.availableBranches = snapshot.availableBranches
		self.availableRemoteBranches = snapshot.availableRemoteBranches
		self.availableTags = snapshot.availableTags
		self.currentGitRootPath = snapshot.gitRootPath
		self.latestStatusGeneration = snapshot.generation
		self.latestStatusRootPath = snapshot.rootPath
		
		self.reconcileSelectedDiffBranchIfInvalid()
		
		// Update selection states when files change
		if filesChanged {
			self.invalidateDiffCache()
			self.scheduleResolvedStateRebuild(for: snapshot)
		} else if self.isPopoverVisible {
			self.updateFileSelectionStates()
		}
	}
	
	private struct ResolvedStateInput: Sendable {
		let baseRootPath: String
		let unstagedRelativePaths: [String]
		let selectedAbsolutePaths: [String]
	}
	
	private struct ResolvedStateOutput: Sendable {
		let fileSelectionStates: [String: Bool]
	}
	
	private func scheduleResolvedStateRebuild(for snapshot: GitStatusActor.GitStatusSnapshot) {
		let baseRootPath = snapshot.gitRootPath ?? selectedRootFolder?.fullPath
		scheduleResolvedStateRebuild(
			baseRootPath: baseRootPath,
			unstagedRelativePaths: snapshot.unstagedFiles.map(\.path),
			selectedRootPath: selectedRootFolder?.fullPath,
			generation: snapshot.generation,
			rootPath: snapshot.rootPath
		)
	}
	
	private func scheduleResolvedStateRebuild(
		baseRootPath: String?,
		unstagedRelativePaths: [String],
		selectedRootPath: String?,
		generation: Int,
		rootPath: String?
	) {
		resolvedStateTask?.cancel()
		
		guard let fileManager = fileManager else { return }
		guard let baseRootPath, !unstagedRelativePaths.isEmpty else {
			fileSelectionStates = [:]
			return
		}
		
		let selectedAbsPaths = fileManager.selectedFiles.map(\.fullPath)
		let input = ResolvedStateInput(
			baseRootPath: baseRootPath,
			unstagedRelativePaths: unstagedRelativePaths,
			selectedAbsolutePaths: selectedAbsPaths
		)
		
		resolvedStateTask = Task.detached(priority: .userInitiated) { [input, generation, rootPath, selectedRootPath] in
			if Task.isCancelled { return }
			let output = Self.buildResolvedState(input: input)
			if Task.isCancelled { return }
			
			await MainActor.run { [weak self] in
				guard let self = self else { return }
				guard !Task.isCancelled else { return }
				guard generation == self.latestStatusGeneration else { return }
				if let rootPath {
					guard rootPath == self.latestStatusRootPath else { return }
				}
				if let selectedRootPath {
					guard selectedRootPath == self.selectedRootFolder?.fullPath else { return }
				}
				
				self.fileSelectionStates = output.fileSelectionStates
			}
		}
	}
	
	private nonisolated static func buildResolvedState(input: ResolvedStateInput) -> ResolvedStateOutput {
		let selectedAbs = Set(input.selectedAbsolutePaths.map { normalizeForComparison($0) })
		var states: [String: Bool] = [:]
		states.reserveCapacity(input.unstagedRelativePaths.count)
		
		for relativePath in input.unstagedRelativePaths {
			let abs = normalizedAbsolutePath(for: relativePath, baseRootPath: input.baseRootPath)
			states[relativePath] = selectedAbs.contains(abs)
		}
		
		return ResolvedStateOutput(fileSelectionStates: states)
	}
	
	private func setupModeObservers() {
		// Sync @Published to @AppStorage and delegate mode changes to actor
        $gitDiffInclusionMode
			.dropFirst()
            .sink { [weak self] newValue in
                guard let self = self else { return }
                self.gitDiffInclusionModeStorage = newValue.rawValue
                self.invalidateDiffCache()
                
				// Don't clear UI state when switching to .none - changes should remain visible
				// Only the diff inclusion in prompts is affected by the mode
				
				Task { [statusActor = self.statusActor] in
					await statusActor.setInclusionMode(newValue)
				}
            }
            .store(in: &cancellables)
        
        // React to changes in selected root folder
        $selectedRootFolder
			.dropFirst()
			.sink { [weak self] newFolder in
				guard let self = self else { return }
				Task { [statusActor = self.statusActor] in
					await statusActor.setSelectedRoot(newFolder?.fullPath)
                }
            }
            .store(in: &cancellables)
        
		// React to changes in comparison branch
		$selectedDiffBranch
			.dropFirst()
			.sink { [weak self] newBranch in
				guard let self = self else { return }
				self.invalidateDiffCache()
				
				Task { [statusActor = self.statusActor] in
					await self.pauseFilteringTemporarily()
					await statusActor.setSelectedDiffBranch(newBranch)
				}
			}
			.store(in: &cancellables)
    }
    
	private func setupFileManagerObservers(_ fileManager: RepoFileManagerViewModel?) {
		guard let fileManager = fileManager else { return }
        
		// Observe file manager selection changes only when popover is visible
		fileManager.$selectedFiles
			.combineLatest($isPopoverVisible)
			.receive(on: RunLoop.main)
			.filter { _, isVisible in isVisible }
			.removeDuplicates { prev, current in
				prev.0.map { $0.fullPath }.sorted() == current.0.map { $0.fullPath }.sorted()
			}
			.debounce(for: .milliseconds(100), scheduler: RunLoop.main)
			.sink { [weak self] _, _ in
				self?.updateFileSelectionStates()
			}
			.store(in: &cancellables)
    }
    
	func setFileManager(_ fileManager: RepoFileManagerViewModel) {
		self.fileManager = fileManager
		setupFileManagerObservers(fileManager)
	}
	
	private func updateUnstagedFileSearchIndex() {
		unstagedFileSearchIndex = unstagedFiles.map { file in
			(file: file, pathKey: file.path.lowercased())
		}
	}
	
    func updateRootFolders(_ rootFolders: [FolderViewModel]) {
        availableRootFolders = rootFolders
        
		// Prune gitEnabledStatus for removed roots
		gitEnabledStatus = gitEnabledStatus.filter { key, _ in
			rootFolders.contains { $0.fullPath == key }
		}
		
		let rootPaths = rootFolders.map(\.fullPath)
		let standardizedRootPaths = rootPaths.map(Self.normalizeForComparison)
		guard standardizedRootPaths != lastVisibleRootPaths else { return }
		lastVisibleRootPaths = standardizedRootPaths
		rootUpdateGeneration &+= 1
		let generation = rootUpdateGeneration
		let inclusionMode = gitDiffInclusionMode
		
		rootUpdateTask?.cancel()
		rootUpdateTask = Task { [weak self, statusActor, rootFolders, rootPaths, standardizedRootPaths, generation, inclusionMode] in
			try? await Task.sleep(nanoseconds: 150_000_000)
			guard !Task.isCancelled else { return }
			let currentInclusionMode = await MainActor.run {
				self?.gitDiffInclusionMode ?? inclusionMode
			}
			
			// Ensure the actor has the current inclusion policy before a selected-root change can refresh.
			await statusActor.setInclusionMode(currentInclusionMode)
			let detections = await statusActor.updateRoots(rootPaths)
			guard !Task.isCancelled else { return }
			
			let updateResult = await MainActor.run { [weak self] () -> (isCurrent: Bool, selectedRootPath: String?) in
				guard let self = self else { return (false, nil) }
				guard generation == self.rootUpdateGeneration else { return (false, nil) }
				guard standardizedRootPaths == self.lastVisibleRootPaths else { return (false, nil) }
				
				var map: [String: Bool] = [:]
				for detection in detections {
					map[detection.rootPath] = detection.isGitRepo
				}
				self.gitEnabledStatus = map
				
				// Update selected folder (prefer git-enabled roots)
				let gitFolders = self.gitEnabledRootFolders
				if self.selectedRootFolder == nil ||
					!gitFolders.contains(where: { $0.id == self.selectedRootFolder?.id }) {
					self.selectedRootFolder = gitFolders.first ?? rootFolders.first
				}
				return (true, self.selectedRootFolder?.fullPath)
			}
			guard updateResult.isCurrent else { return }
			await statusActor.setSelectedRoot(updateResult.selectedRootPath)
		}
    }
    
	// MARK: - Fetch API (delegates to actor)
	
	func fetchUnstagedFiles(showLoading: Bool = true) async {
		guard selectedRootFolder != nil else {
			unstagedFiles = []
			errorMessage = "No root folder selected"
			return
		}
		let trigger: GitStatusActor.Trigger = showLoading ? .explicitRefresh : .popoverOpen
		await fetchUnstagedFiles(trigger: trigger)
	}
	
	func fetchUnstagedFiles(trigger: GitStatusActor.Trigger) async {
		guard selectedRootFolder != nil else {
			unstagedFiles = []
			errorMessage = "No root folder selected"
			totalAdditions = 0
			totalDeletions = 0
			commitDelta = nil
            return
        }
		
		// Show loading indicator for user-initiated fetches (not background polls)
		let showLoading = trigger != .backgroundPoll
		if showLoading {
			isLoadingStatus = true
		}
		
		// Delegate to actor - snapshot will arrive via statusStream
		await statusActor.refresh(trigger: trigger)
		
		if showLoading {
			isLoadingStatus = false
		}
    }
    
    func refresh() async {
		await fetchUnstagedFiles(trigger: .explicitRefresh)
    }
    
    var hasValidRepository: Bool {
        selectedRootFolder != nil && errorMessage?.contains("Not a git repository") != true
    }
    
	/// Whether git features are active (mode is not .none)
	private var isGitActive: Bool {
		gitDiffInclusionMode != .none
	}
	
	/// Returns only folders that are git repositories
	var gitEnabledRootFolders: [FolderViewModel] {
		availableRootFolders.filter { folder in
			gitEnabledStatus[folder.fullPath] ?? false
		}
	}
	
	var filteredUnstagedFiles: [VCSUncommittedFile] {
		guard !fileSearchText.isEmpty && !isFilteringPaused else {
			return unstagedFiles
		}
		
		let needle = fileSearchText.lowercased()
		return unstagedFileSearchIndex.compactMap { entry in
			entry.pathKey.contains(needle) ? entry.file : nil
		}
	}
	
	func clearFileSearch() {
		searchDebounceTask?.cancel()
		fileSearchText = ""
		isFilteringPaused = false
	}
	
	private func pauseFilteringTemporarily() async {
		isFilteringPaused = true
		
		searchDebounceTask?.cancel()
		searchDebounceTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 500_000_000)
			guard !Task.isCancelled else { return }
			await MainActor.run {
				self?.isFilteringPaused = false
			}
		}
	}
    
    var statusText: String {
        if selectedRootFolder == nil {
            return "No folders"
        } else if errorMessage?.contains("Not a git repository") == true {
            return "No git"
        } else if unstagedFiles.isEmpty {
            return "Clean"
        } else {
            return "\(unstagedFiles.count) unstaged"
        }
    }
    
	// MARK: - File Selection
    
    func addFileToSelection(_ relativePath: String) async {
		guard let fileManager = fileManager else { return }
        
		let resolvedPath = getResolvedPath(for: relativePath)
		fileManager.selectPath(resolvedPath, kind: nil)
		
		fileSelectionStates[relativePath] = true
		
		if gitDiffInclusionMode == .selectedFiles {
			invalidateDiffCache()
		}
    }
    
    func removeFileFromSelection(_ relativePath: String) async {
		guard let fileManager = fileManager else { return }
        
		let resolvedPath = getResolvedPath(for: relativePath)
		fileManager.deselectPath(resolvedPath, kind: nil)
		
		fileSelectionStates[relativePath] = false
		
		if gitDiffInclusionMode == .selectedFiles {
			invalidateDiffCache()
		}
    }
    
    func isFileSelected(_ relativePath: String) -> Bool {
		return fileSelectionStates[relativePath] ?? false
	}
	
	private func updateFileSelectionStates() {
		let baseRootPath = currentGitRootPath ?? selectedRootFolder?.fullPath
		scheduleResolvedStateRebuild(
			baseRootPath: baseRootPath,
			unstagedRelativePaths: unstagedFiles.map(\.path),
			selectedRootPath: selectedRootFolder?.fullPath,
			generation: latestStatusGeneration,
			rootPath: latestStatusRootPath
		)
    }
	
	func refreshSelectionStatesIfNeeded() {
		guard isGitActive, isPopoverVisible else { return }
		updateFileSelectionStates()
	}

	// MARK: - Public accessors for artifact publishing
	
	/// Returns the current git root path if available.
	var gitRootPath: String? { currentGitRootPath }
	
	/// Returns the absolute paths of selected changed files for git artifact generation.
	func selectedChangedAbsolutePathsForGitArtifacts() -> [String] {
		selectedChangedPaths().absolute
	}
	
	private func selectedChangedPaths() -> (relative: [String], absolute: [String]) {
		if let fileManager {
			let selectedAbs = Set(fileManager.selectedFiles.map { Self.normalizeForComparison($0.fullPath) })
			guard !selectedAbs.isEmpty else { return ([], []) }
			var relative: [String] = []
			var absolute: [String] = []
			relative.reserveCapacity(unstagedFiles.count)
			absolute.reserveCapacity(unstagedFiles.count)

			for file in unstagedFiles {
				let resolved = getResolvedPath(for: file.path)
				if selectedAbs.contains(resolved) {
					relative.append(file.path)
					absolute.append(resolved)
				}
			}

			guard !relative.isEmpty else { return ([], []) }
			return (Array(Set(relative)).sorted(), Array(Set(absolute)).sorted())
		}

		let relative = unstagedFiles
			.filter { isFileSelected($0.path) }
			.map(\.path)
		guard !relative.isEmpty else { return ([], []) }
		let absolute = relative.map { getResolvedPath(for: $0) }
		return (Array(Set(relative)).sorted(), Array(Set(absolute)).sorted())
	}

	// MARK: - Diff Operations (delegate to actor)
	
	func copySelectedDiff() async -> Bool {
		guard let diff = await getDiffUsing(inclusionMode: .selectedFiles) else {
			return false
		}
		
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(diff, forType: .string)
		return true
	}
	
	func copyAllDiff() async -> Bool {
		guard let diff = await getDiffUsing(inclusionMode: .all) else {
			return false
		}
		
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(diff, forType: .string)
		return true
	}
	
	func copyDiffToClipboard() async -> Bool {
		guard let diff = await getSelectedFilesDiff(forceFresh: true) else {
			return false
		}
		
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(diff, forType: .string)
		return true
	}
	
	func getDiffUsing(inclusionMode mode: GitDiffInclusionMode, vs branch: String? = nil, forceRefreshStatus: Bool = false) async -> String? {
		guard mode != .none else { return nil }
		guard let rootPath = selectedRootFolder?.fullPath else { return nil }

		let effectiveBranch = branch ?? selectedDiffBranch
		let selectedAbs: [String]
		switch mode {
		case .none:
			return nil
		case .all:
			selectedAbs = []
		case .selectedFiles:
			let selection = selectedChangedPaths()
			guard !selection.absolute.isEmpty else { return nil }
			selectedAbs = selection.absolute
		}

		return await statusActor.generateDiff(
			rootPath: rootPath,
			inclusionMode: mode,
			selectedAbsolutePaths: selectedAbs,
			vsBranch: effectiveBranch,
			forceRefreshSnapshot: forceRefreshStatus
		)
	}

	func getDiffForAbsolutePaths(_ absolutePaths: [String], vs branch: String? = nil, forceRefreshStatus: Bool = false) async -> String? {
		guard !absolutePaths.isEmpty else { return nil }
		guard let rootPath = selectedRootFolder?.fullPath else { return nil }
		let effectiveBranch = branch ?? selectedDiffBranch
		let normalized = Array(Set(absolutePaths.map { ($0 as NSString).standardizingPath })).sorted()
		return await statusActor.generateDiff(
			rootPath: rootPath,
			inclusionMode: .selectedFiles,
			selectedAbsolutePaths: normalized,
			vsBranch: effectiveBranch,
			forceRefreshSnapshot: forceRefreshStatus
		)
	}
	
	/// Clears all git-related UI state without performing any git operations.
	private func resetGitState() {
		rootUpdateTask?.cancel()
		unstagedFiles = []
		fileSelectionStates = [:]
		resolvedStateTask?.cancel()
		latestStatusGeneration = 0
		latestStatusRootPath = nil
		currentGitRootPath = nil
		availableBranches = []
		availableRemoteBranches = []
		availableTags = []
		totalAdditions = 0
		totalDeletions = 0
		commitDelta = nil
		currentBranch = nil
		selectedDiffBranch = "HEAD"
		errorMessage = nil
		invalidateDiffCache()
	}
	
	deinit {
		statusStreamTask?.cancel()
		searchDebounceTask?.cancel()
		rootUpdateTask?.cancel()
		resolvedStateTask?.cancel()
	}
	
	private func getResolvedPath(for relativePath: String) -> String {
		let basePath = currentGitRootPath ?? selectedRootFolder?.fullPath
		guard let basePath else { return relativePath }
		return Self.normalizedAbsolutePath(for: relativePath, baseRootPath: basePath)
	}
	
	private func reconcileSelectedDiffBranchIfInvalid() {
		guard selectedDiffBranch != "HEAD" else { return }
		guard !availableBranches.isEmpty || !availableRemoteBranches.isEmpty || !availableTags.isEmpty else { return }
		
		let branchNames = Set(availableBranches.map(\.name))
		let remoteBranchNames = Set(availableRemoteBranches.map(\.name))
		let tagNames = Set(availableTags.map(\.name))
		if !branchNames.contains(selectedDiffBranch) &&
		!remoteBranchNames.contains(selectedDiffBranch) &&
		!tagNames.contains(selectedDiffBranch) {
			selectedDiffBranch = "HEAD"
		}
	}
    
	// MARK: - Bulk Selection Operations
	
    func addAllUnstagedToFileManager() async {
		guard let fileManager = fileManager else { return }
        
		let resolvedPaths = unstagedFiles.map { file in
			getResolvedPath(for: file.path)
        }
        
        await fileManager.selectFiles(withPaths: resolvedPaths, allowEmpty: false, clear: false)
        
		updateFileSelectionStates()
		
		if gitDiffInclusionMode == .selectedFiles {
			invalidateDiffCache()
		}
    }
    
	func addFilteredUnstagedToFileManager() async {
		guard let fileManager = fileManager else { return }
		isBulkSelectionRunning = true
		defer { isBulkSelectionRunning = false }

		let resolvedPaths = filteredUnstagedFiles.map { getResolvedPath(for: $0.path) }
		guard !resolvedPaths.isEmpty else { return }

		await fileManager.selectFiles(withPaths: resolvedPaths, allowEmpty: false, clear: false)

		updateFileSelectionStates()
		if gitDiffInclusionMode == .selectedFiles {
			invalidateDiffCache()
		}
	}
	
    func replaceFileManagerSelectionWithAllUnstaged() async {
		guard let fileManager = fileManager else { return }
        
		let resolvedPaths = unstagedFiles.map { file in
			getResolvedPath(for: file.path)
        }
        
        await fileManager.selectFiles(withPaths: resolvedPaths, allowEmpty: false, clear: true)
        
		updateFileSelectionStates()
		
		if gitDiffInclusionMode == .selectedFiles {
			invalidateDiffCache()
		}
    }
	
	func removeAllUnstagedFromFileManager() async {
		guard let fileManager = fileManager else { return }
		isBulkSelectionRunning = true
		defer { isBulkSelectionRunning = false }

		let resolved = unstagedFiles.map { getResolvedPath(for: $0.path) }
		await fileManager.deselectFiles(withPaths: resolved)

		updateFileSelectionStates()
		if gitDiffInclusionMode == .selectedFiles {
			invalidateDiffCache()
		}
	}
	
	func removeFilteredUnstagedFromFileManager() async {
		guard let fileManager = fileManager else { return }
		isBulkSelectionRunning = true
		defer { isBulkSelectionRunning = false }

		let resolved = filteredUnstagedFiles.map { getResolvedPath(for: $0.path) }
		guard !resolved.isEmpty else { return }

		await fileManager.deselectFiles(withPaths: resolved)

		updateFileSelectionStates()
		if gitDiffInclusionMode == .selectedFiles {
			invalidateDiffCache()
		}
	}
	
	// MARK: - Path Utilities
	
	private nonisolated static func normalizedAbsolutePath(for gitRelativePath: String, baseRootPath: String) -> String {
		let absPath = makeAbsolutePath(for: gitRelativePath, baseRootPath: baseRootPath)
		return normalizeForComparison(absPath)
	}
	
	private nonisolated static func makeAbsolutePath(for gitRelativePath: String, baseRootPath: String) -> String {
		if gitRelativePath.hasPrefix("/") {
			return gitRelativePath
		}
		
		var rel = gitRelativePath.replacingOccurrences(of: "\\", with: "/")
		if rel.hasPrefix("./") {
			rel.removeFirst(2)
		}
		
		// Git paths are always relative to gitRoot - just append directly
		return (baseRootPath as NSString).appendingPathComponent(rel)
	}
	
	private nonisolated static func normalizeForComparison(_ path: String) -> String {
		let standardized = (path as NSString).standardizingPath
		guard containsNonASCII(standardized) else { return standardized }
		return standardized.precomposedStringWithCanonicalMapping
	}
	
	private nonisolated static func containsNonASCII(_ value: String) -> Bool {
		for byte in value.utf8 where byte >= 0x80 {
			return true
		}
		return false
	}
	
	// MARK: - Diff Caching
	
	private func invalidateDiffCache() {
		cachedDiff = nil
		cachedDiffMode = nil
		cachedDiffBranch = nil
		cachedSelectedFiles = []
	}

	func getSelectedFilesDiff(vs branch: String? = nil, forceFresh: Bool = false) async -> String? {
		guard isGitActive else { return nil }
		guard let rootPath = selectedRootFolder?.fullPath else { return nil }
		
		let effectiveBranch = branch ?? selectedDiffBranch
		if forceFresh {
			invalidateDiffCache()
		}
		
		// Check cache (unless forceFresh)
		if !forceFresh,
			let cached = cachedDiff,
			cachedDiffMode == gitDiffInclusionMode,
			cachedDiffBranch == effectiveBranch {
			if gitDiffInclusionMode == .selectedFiles {
				let currentSelectedFiles = Set(selectedChangedPaths().relative)
				if currentSelectedFiles == cachedSelectedFiles {
					return cached
				}
			} else {
				return cached
			}
		}
		
		// Generate new diff via actor
		let selectedAbs: [String]
		let paths: [String]
		
		switch gitDiffInclusionMode {
		case .none:
			return nil
		case .selectedFiles:
			let selection = selectedChangedPaths()
			paths = selection.relative
			guard !paths.isEmpty else { return nil }
			selectedAbs = selection.absolute
		case .all:
			paths = unstagedFiles.map(\.path)
			guard !paths.isEmpty else { return nil }
			selectedAbs = []
		}
		
		let diff = await statusActor.generateDiff(
			rootPath: rootPath,
			inclusionMode: gitDiffInclusionMode,
			selectedAbsolutePaths: selectedAbs,
			vsBranch: effectiveBranch,
			forceRefreshSnapshot: forceFresh
		)
		
		// Cache result
		if let diff = diff {
			cachedDiff = diff
			cachedDiffMode = gitDiffInclusionMode
			cachedDiffBranch = effectiveBranch
			if gitDiffInclusionMode == .selectedFiles {
				cachedSelectedFiles = Set(paths)
			} else {
				cachedSelectedFiles = []
			}
		}
		
		return diff
	}
}
