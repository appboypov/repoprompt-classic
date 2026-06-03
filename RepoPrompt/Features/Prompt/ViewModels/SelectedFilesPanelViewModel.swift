//
//  SelectedFilesPanelViewModel.swift
//  RepoPrompt
//
//  Created by Codex on 2025-05-07.
//

import SwiftUI
import Combine
import AppKit

// MARK: - Snapshot Models

struct SelectedFilesSnapshot: Equatable {
	let displayMode: FileDisplayMode
	let contentMode: SelectedFilesContentView.ContentViewMode
	let codeMapUsage: CodeMapUsage
	let flatFiles: [FileRowProps]
	let folderGroups: [FolderGroupProps]
	let totalFileCount: Int
	let apiCodemapCount: Int
	let fullFilesCount: Int
	let fullFilesTokenCount: Int
	let codemapOnlyCount: Int
	let codemapTokenCount: Int
	let selectedModeTokenCount: Int
	let displayTokenCount: String
	let isEmpty: Bool
	
	static func empty(
		displayMode: FileDisplayMode,
		contentMode: SelectedFilesContentView.ContentViewMode,
		codeMapUsage: CodeMapUsage
	) -> SelectedFilesSnapshot {
		SelectedFilesSnapshot(
			displayMode: displayMode,
			contentMode: contentMode,
			codeMapUsage: codeMapUsage,
			flatFiles: [],
			folderGroups: [],
			totalFileCount: 0,
			apiCodemapCount: 0,
			fullFilesCount: 0,
			fullFilesTokenCount: 0,
			codemapOnlyCount: 0,
			codemapTokenCount: 0,
			selectedModeTokenCount: 0,
			displayTokenCount: "0.00k",
			isEmpty: true
		)
	}
}

struct FileRowProps: Identifiable, Equatable {
	let id: UUID
	let name: String
	let nameSortKey: String
	let fullPath: String
	let relativePath: String
	let uniqueRelativePath: String
	let uniqueRelativePathSortKey: String
	let rootFolderName: String
	let mode: FileModeSnapshot
	let canCodemap: Bool
	let isAutoCodemap: Bool
	let hasSlices: Bool
	let compactSlicesDisplay: String?
	let sliceRanges: [LineRange]
	let tokenCount: Int
	let tokenPercent: Double
	let tokenDisplayString: String
	let showRootLabel: Bool
}

struct FolderGroupProps: Identifiable, Equatable {
	let id: String
	let path: String
	let isExpanded: Bool
	let tokenDisplayString: String?
	let files: [FileRowProps]
	
	var isEmpty: Bool { files.isEmpty }
}

enum FileModeSnapshot: Equatable {
	case full
	case slices
	case codemap
}

// MARK: - Panel View Model

@MainActor
final class SelectedFilesPanelViewModel: ObservableObject {
	@Published private(set) var snapshot: SelectedFilesSnapshot
	@Published private(set) var displayMode: FileDisplayMode
	@Published private(set) var contentMode: SelectedFilesContentView.ContentViewMode
	
	private weak var fileManager: RepoFileManagerViewModel?
	private weak var promptVM: PromptViewModel?
	private let tokenVM: TokenCountingViewModel
	
	private var cancellables = Set<AnyCancellable>()
	private var lastRebuildTime: CFAbsoluteTime = 0
	private let rebuildThrottleInterval: CFAbsoluteTime = 0.1
	private var pendingTrailingRebuild: Task<Void, Never>?
	private var isRebuildSuspended = false
	private var didDirtyWhileSuspended = false
	private var lastObservedFileDisplayMode: String
	private var lastObservedSortMethod: SortMethod

	init(fileManager: RepoFileManagerViewModel, promptVM: PromptViewModel) {
		self.fileManager = fileManager
		self.promptVM = promptVM
		self.tokenVM = promptVM.tokenCountingViewModel
		self.lastObservedFileDisplayMode = promptVM.fileDisplayMode
		self.lastObservedSortMethod = promptVM.selectedFilesSortMethod

		let initialDisplayMode = FileDisplayMode(rawValue: promptVM.fileDisplayMode) ?? .folders
		self.displayMode = initialDisplayMode
		self.contentMode = .fullFiles
		self.snapshot = SelectedFilesSnapshot.empty(
			displayMode: initialDisplayMode,
			contentMode: .fullFiles,
			codeMapUsage: promptVM.effectiveCopyCodeMapUsage()
		)

		bind()
		markDirty()
	}
	
	// MARK: - Intent Handlers
	
	func setContentMode(_ mode: SelectedFilesContentView.ContentViewMode) {
		guard contentMode != mode else { return }
		contentMode = mode
		markDirty()
	}
	
	func setDisplayMode(_ mode: FileDisplayMode) {
		guard displayMode != mode else { return }
		displayMode = mode
		if promptVM?.fileDisplayMode != mode.rawValue {
			promptVM?.fileDisplayMode = mode.rawValue
		}
		markDirty()
	}
	
	func removeFile(fullPath: String) {
		guard let file = resolveFileVM(fullPath: fullPath) else { return }
		fileManager?.removeFileFromAllSelections(file)
	}
	
	func setCodemap(fullPath: String) {
		guard let file = resolveFileVM(fullPath: fullPath) else { return }
		fileManager?.setFileAsCodemap(file)
	}
	
	func setFullContent(fullPath: String) {
		guard let file = resolveFileVM(fullPath: fullPath) else { return }
		fileManager?.setFileAsFullContent(file)
	}
	
	func clearSlices(fullPath: String) {
		guard
			let file = resolveFileVM(fullPath: fullPath),
			let manager = fileManager
		else { return }
		
		Task {
			do {
				try await manager.clearSelectionSlices(for: file)
			} catch {
				#if DEBUG
				print("⚠️ Failed to clear slices for \(file.relativePath): \(error)")
				#endif
			}
		}
	}
	
	func copyContents(fullPath: String) {
		guard let file = resolveFileVM(fullPath: fullPath) else { return }
		file.copyContentsToPasteboard()
	}
	
	func copyRelativePath(
		fullPath: String,
		uniqueRelativePath: String? = nil,
		relativePath: String? = nil
	) {
		if let file = resolveFileVM(
			fullPath: fullPath,
			uniqueRelativePath: uniqueRelativePath,
			relativePath: relativePath
		) {
			file.copyRelativePathToPasteboard()
			return
		}
		
		if let relativePath {
			copyToPasteboard(relativePath)
			return
		}
		
		if let uniqueRelativePath {
			copyToPasteboard(uniqueRelativePath)
		}
	}

	func copyAbsolutePath(fullPath: String) {
		if let file = resolveFileVM(fullPath: fullPath) {
			file.copyAbsolutePathToPasteboard()
			return
		}
		let standardizedPath = (fullPath as NSString).standardizingPath
		copyToPasteboard(standardizedPath)
	}

	func revealInFinder(
		fullPath: String,
		uniqueRelativePath: String? = nil,
		relativePath: String? = nil
	) {
		if let file = resolveFileVM(
			fullPath: fullPath,
			uniqueRelativePath: uniqueRelativePath,
			relativePath: relativePath
		) {
			file.revealInFinder()
			return
		}
		
		let standardizedPath = (fullPath as NSString).standardizingPath
		let fileURL = URL(fileURLWithPath: standardizedPath)
		NSWorkspace.shared.activateFileViewerSelecting([fileURL])
	}
	
	func openFile(
		fullPath: String,
		uniqueRelativePath: String? = nil,
		relativePath: String? = nil
	) {
		if let file = resolveFileVM(
			fullPath: fullPath,
			uniqueRelativePath: uniqueRelativePath,
			relativePath: relativePath
		) {
			file.openInDefaultApp()
			return
		}
		
		let standardizedPath = (fullPath as NSString).standardizingPath
		let fileURL = URL(fileURLWithPath: standardizedPath)
		let opened = NSWorkspace.shared.open(fileURL)
		if !opened {
			print("Unable to open file: \(standardizedPath)")
		}
	}

	private func copyToPasteboard(_ value: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
	}
	
	func resolveFileVM(
		fullPath: String,
		uniqueRelativePath: String? = nil,
		relativePath: String? = nil
	) -> FileViewModel? {
		guard let manager = fileManager else { return nil }
		if let direct = manager.findFileByFullPath(fullPath) {
			return direct
		}
		if let unique = uniqueRelativePath, let vm = manager.findFileByRelativePath(unique) {
			return vm
		}
		if let rel = relativePath, let vm = manager.findFileByRelativePath(rel) {
			return vm
		}
		return nil
	}
	
	func selectionSlices(
		for fullPath: String,
		uniqueRelativePath: String? = nil,
		relativePath: String? = nil
	) -> [LineRange] {
		guard
			let manager = fileManager,
			let file = resolveFileVM(
				fullPath: fullPath,
				uniqueRelativePath: uniqueRelativePath,
				relativePath: relativePath
			),
			let ranges = manager.selectionSlices(for: file)
		else { return [] }
		return ranges
	}
	
	func setFolderExpansion(path: String, isExpanded: Bool) {
		guard let promptVM else { return }
		let currentlyExpanded = !promptVM.collapsedFolders.contains(path)
		guard isExpanded != currentlyExpanded else { return }
		if isExpanded {
			promptVM.collapsedFolders.remove(path)
		} else {
			promptVM.collapsedFolders.insert(path)
		}
		markDirty()
	}

	func toggleFolderExpansion(path: String) {
		guard let promptVM else { return }
		let shouldExpand = promptVM.collapsedFolders.contains(path)
		setFolderExpansion(path: path, isExpanded: shouldExpand)
	}
	
	// MARK: - Private Helpers
	
	private func bind() {
		guard let fileManager, let promptVM else { return }
		
		fileManager.fileTogglePublisher
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in self?.markDirty() }
			.store(in: &cancellables)
		
		fileManager.selectionClearedPublisher
			.receive(on: RunLoop.main)
			.sink { [weak self] in self?.markDirty() }
			.store(in: &cancellables)
		
		fileManager.codeMapUpdatePublisher
			.receive(on: RunLoop.main)
			.sink { [weak self] in self?.markDirty() }
			.store(in: &cancellables)
		
		fileManager.$autoCodemapFiles
			.dropFirst()
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in self?.markDirty() }
			.store(in: &cancellables)
		
		fileManager.$selectionSlicesByFileID
			.dropFirst()
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in self?.markDirty() }
			.store(in: &cancellables)
		
		tokenVM.tokenCalculationCompletedPublisher
			.receive(on: RunLoop.main)
			.sink { [weak self] in self?.markDirty() }
			.store(in: &cancellables)
		
		promptVM.$collapsedFolders
			.removeDuplicates()
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in self?.markDirty() }
			.store(in: &cancellables)
		
		promptVM.$codeMapUsage
			.removeDuplicates()
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in self?.markDirty() }
			.store(in: &cancellables)
		
		promptVM.$isSwitchingComposeTab
			.removeDuplicates()
			.receive(on: RunLoop.main)
			.sink { [weak self] isSwitching in
				self?.setRebuildSuspended(isSwitching)
			}
			.store(in: &cancellables)

		NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
			.receive(on: RunLoop.main)
			.sink { [weak self] _ in
				self?.handleUserDefaultsDidChange()
			}
			.store(in: &cancellables)
		
	}

	private func setRebuildSuspended(_ suspended: Bool) {
		guard isRebuildSuspended != suspended else { return }
		isRebuildSuspended = suspended

		if suspended {
			if pendingTrailingRebuild != nil {
				didDirtyWhileSuspended = true
			}
			pendingTrailingRebuild?.cancel()
			return
		}

		guard didDirtyWhileSuspended else { return }
		didDirtyWhileSuspended = false
		markDirty(immediate: true)
	}

	private func handleUserDefaultsDidChange() {
		guard let promptVM else { return }
		var didChange = false

		if promptVM.fileDisplayMode != lastObservedFileDisplayMode {
			lastObservedFileDisplayMode = promptVM.fileDisplayMode
			didChange = true
		}

		if promptVM.selectedFilesSortMethod != lastObservedSortMethod {
			lastObservedSortMethod = promptVM.selectedFilesSortMethod
			didChange = true
		}

		if didChange {
			markDirty()
		}
	}
	
	private func markDirty(immediate: Bool = false) {
		if isRebuildSuspended {
			didDirtyWhileSuspended = true
			return
		}

		pendingTrailingRebuild?.cancel()

		let now = CFAbsoluteTimeGetCurrent()
		let elapsed = now - lastRebuildTime

		if immediate || elapsed >= rebuildThrottleInterval {
			// First call or enough time passed - rebuild immediately
			rebuildSnapshot()
			lastRebuildTime = now
		} else {
			// Throttled - schedule ONE trailing rebuild
			let delay = rebuildThrottleInterval - elapsed
			pendingTrailingRebuild = Task { [weak self] in
				try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				guard !Task.isCancelled else { return }
				await MainActor.run {
					self?.rebuildSnapshot()
					self?.lastRebuildTime = CFAbsoluteTimeGetCurrent()
				}
			}
		}
	}
	
	private func rebuildSnapshot() {
		guard
			let fileManager,
			let promptVM
		else { return }

		// Use effective codeMapUsage from resolved context to ensure UI matches token pipeline
		let effectiveCodeMapUsage = promptVM.effectiveCopyCodeMapUsage()

		let selectedFiles = fileManager.selectedFiles
		let autoCodemap = fileManager.autoCodemapFiles
		let selectedIDs = Set(selectedFiles.map(\.id))

		// Determine codemap files based on mode
		let activeCodemapFiles: [FileViewModel]
		switch effectiveCodeMapUsage {
		case .none, .selected:
			// No codemap side of fence in these modes
			activeCodemapFiles = []
		case .auto:
			// Auto mode: only auto-detected codemaps
			activeCodemapFiles = autoCodemap.filter { !selectedIDs.contains($0.id) }
		case .complete:
			// Complete mode: ALL files with codemaps that aren't selected
			activeCodemapFiles = fileManager.collectAllFilesWithCodemaps().filter { !selectedIDs.contains($0.id) }
		}
		
		// Use active codemap files for ID tracking (important for complete mode)
		let autoCodemapIDs = Set(activeCodemapFiles.map(\.id))
		
		let displayFiles = computeDisplayFiles(
			selectedFiles: selectedFiles,
			autoCodemapFiles: activeCodemapFiles,
			contentMode: contentMode,
			codeMapUsage: effectiveCodeMapUsage
		)
		
		let slicesSnapshot = fileManager.getSelectionSlicesSnapshot()
		let tokenInfo = tokenVM.fileTokenInfo
		let showRootLabel = fileManager.visibleRootFolders.count > 1
		let resolvedDisplayMode = FileDisplayMode(rawValue: promptVM.fileDisplayMode) ?? displayMode
		if displayMode != resolvedDisplayMode {
			displayMode = resolvedDisplayMode
		}
		let resolvedContentMode = contentMode

		let selectedSeeds = buildRowSeeds(
			for: selectedFiles,
			autoCodemapIDs: autoCodemapIDs,
			selectedIDs: selectedIDs,
			sliceMap: slicesSnapshot,
			tokenInfo: tokenInfo,
			codeMapUsage: effectiveCodeMapUsage
		)
		let codemapSeeds = buildRowSeeds(
			for: activeCodemapFiles,
			autoCodemapIDs: autoCodemapIDs,
			selectedIDs: selectedIDs,
			sliceMap: slicesSnapshot,
			tokenInfo: tokenInfo,
			codeMapUsage: effectiveCodeMapUsage
		)

		let stats = aggregateStats(selectedSeeds: selectedSeeds, codemapSeeds: codemapSeeds, codeMapUsage: effectiveCodeMapUsage)
		let codemapPercentBase: Int
		switch effectiveCodeMapUsage {
		case .none:
			codemapPercentBase = 0
		case .selected:
			codemapPercentBase = max(tokenVM.codeMapTokenCount, 0)
		case .auto, .complete:
			codemapPercentBase = stats.codemapTokens
		}

		let selectedRows = buildRows(
			from: selectedSeeds,
			codemapPercentBase: codemapPercentBase,
			showRootLabel: showRootLabel
		)
		let codemapRows = buildRows(
			from: codemapSeeds,
			codemapPercentBase: codemapPercentBase,
			showRootLabel: showRootLabel
		)

		let allRows = selectedRows + codemapRows
		let rowLookup = Dictionary(uniqueKeysWithValues: allRows.map { ($0.id, $0) })
		let displayRows = displayFiles.compactMap { rowLookup[$0.id] }

		// Compute total display tokens from actual row token counts
		// This ensures folder percentages are based on what's actually displayed (codemap tokens in .selected mode)
		let totalDisplayTokens = displayRows.reduce(0) { $0 + $1.tokenCount }
		let sortedFiles: [FileRowProps]
		let folderGroups: [FolderGroupProps]
		switch resolvedDisplayMode {
		case .folders:
			sortedFiles = []
			folderGroups = buildFolderGroups(
				fileRows: displayRows,
				promptVM: promptVM,
				multipleRoots: showRootLabel,
				totalDisplayTokens: totalDisplayTokens
			)
		case .files:
			sortedFiles = sort(fileRows: displayRows, method: promptVM.selectedFilesSortMethod)
			folderGroups = []
		}

		let snapshot = SelectedFilesSnapshot(
			displayMode: resolvedDisplayMode,
			contentMode: resolvedContentMode,
			codeMapUsage: effectiveCodeMapUsage,
			flatFiles: sortedFiles,
			folderGroups: folderGroups,
			totalFileCount: stats.fullCount,
			apiCodemapCount: stats.codemapCount,
			fullFilesCount: stats.fullCount,
			fullFilesTokenCount: stats.fullTokens,
			codemapOnlyCount: stats.codemapCount,
			codemapTokenCount: stats.codemapTokens,
			selectedModeTokenCount: stats.fullTokens,  // Use fullTokens to include non-codemap files
			displayTokenCount: displayTokenCount(
				fullTokens: stats.fullTokens,
				codeMapUsage: effectiveCodeMapUsage,
				tokenVM: tokenVM
			),
			isEmpty: displayRows.isEmpty
		)
		
		if snapshot != self.snapshot {
			self.snapshot = snapshot
		}
	}
	
	private func computeDisplayFiles(
		selectedFiles: [FileViewModel],
		autoCodemapFiles: [FileViewModel],
		contentMode: SelectedFilesContentView.ContentViewMode,
		codeMapUsage: CodeMapUsage
	) -> [FileViewModel] {
		switch codeMapUsage {
		case .selected:
			return selectedFiles
		case .none:
			switch contentMode {
			case .fullFiles:
				return selectedFiles
			case .codemaps:
				return []
			}
		default:
			switch contentMode {
			case .fullFiles:
				return selectedFiles
			case .codemaps:
				let selectedIDs = Set(selectedFiles.map(\.id))
				return autoCodemapFiles.filter { !selectedIDs.contains($0.id) }
			}
		}
	}
	
	private func makeFileRowProps(
		from seed: RowSeed,
		codemapPercentBase: Int,
		showRootLabel: Bool
	) -> FileRowProps {
		let (tokenCount, tokenPercent, tokenDisplay) = makeTokenDisplay(
			mode: seed.mode,
			tokenCount: seed.tokenCount,
			tokenInfo: seed.tokenInfo,
			codemapPercentBase: codemapPercentBase
		)

		return FileRowProps(
			id: seed.file.id,
			name: seed.file.name,
			nameSortKey: seed.file.nameSortKey,
			fullPath: seed.file.fullPath,
			relativePath: seed.file.relativePath,
			uniqueRelativePath: seed.file.uniqueRelativePath,
			uniqueRelativePathSortKey: seed.file.uniqueRelativePathSortKey,
			rootFolderName: seed.file.rootFolderName,
			mode: seed.mode,
			canCodemap: seed.file.fileAPI != nil,
			isAutoCodemap: seed.isAutoCodemap,
			hasSlices: seed.hasSlices,
			compactSlicesDisplay: formatSlices(seed.slices),
			sliceRanges: seed.slices,
			tokenCount: tokenCount,
			tokenPercent: tokenPercent,
			tokenDisplayString: tokenDisplay,
			showRootLabel: showRootLabel
		)
	}
	
	private func makeTokenDisplay(
		mode: FileModeSnapshot,
		tokenCount: Int,
		tokenInfo: TokenInfo?,
		codemapPercentBase: Int
	) -> (Int, Double, String) {
		switch mode {
		case .codemap:
			let percentBase = max(codemapPercentBase, 0)
			let percent = percentBase > 0 ? Double(tokenCount) / Double(percentBase) : 0
			let formatted = String(format: "~%.2fk", Double(tokenCount) / 1000.0)
			return (tokenCount, percent, formatted)
		case .slices, .full:
			if let info = tokenInfo, info.count > 0 {
				let formatted = "~\(info.formatted) (\(Int(info.percentage * 100))%)"
				return (info.count, info.percentage, formatted)
			} else {
				return (tokenCount, 0, "-")
			}
		}
	}
	
	private func resolveFileMode(
		for file: FileViewModel,
		isSelected: Bool,
		isAutoCodemap: Bool,
		hasSlices: Bool,
		codeMapUsage: CodeMapUsage
	) -> FileModeSnapshot {
		if codeMapUsage == .none {
			return hasSlices ? .slices : .full
		}
		if codeMapUsage == .selected, file.fileAPI != nil, isSelected {
			return .codemap
		}
		if isAutoCodemap && !isSelected {
			return .codemap
		}
		if hasSlices {
			return .slices
		}
		return .full
	}
	
	private func tokenCount(
		for file: FileViewModel,
		mode: FileModeSnapshot,
		tokenInfo: TokenInfo?
	) -> Int {
		switch mode {
		case .codemap:
			if let api = file.fileAPI {
				return api.apiTokenCount
			} else if let info = tokenInfo {
				return info.count
			} else {
				return 0
			}
		case .slices, .full:
			return tokenInfo?.count ?? 0
		}
	}
	
	private func formatSlices(_ slices: [LineRange]) -> String? {
		guard !slices.isEmpty else { return nil }
		return slices
			.map { range in
				if range.start == range.end {
					return "L\(range.start)"
				} else {
					return "L\(range.start)-\(range.end)"
				}
			}
			.joined(separator: ", ")
	}

	private struct RowSeed {
		let file: FileViewModel
		let mode: FileModeSnapshot
		let isAutoCodemap: Bool
		let slices: [LineRange]
		let tokenInfo: TokenInfo?
		let tokenCount: Int

		var hasSlices: Bool { !slices.isEmpty }
	}

	private func makeRowSeed(
		file: FileViewModel,
		autoCodemapIDs: Set<UUID>,
		selectedIDs: Set<UUID>,
		sliceMap: [UUID: [LineRange]],
		tokenInfo: [UUID: TokenInfo],
		codeMapUsage: CodeMapUsage
	) -> RowSeed {
		let slices = sliceMap[file.id] ?? []
		let isAutoCodemap = autoCodemapIDs.contains(file.id)
		let isSelected = selectedIDs.contains(file.id)
		let info = tokenInfo[file.id]
		let mode = resolveFileMode(
			for: file,
			isSelected: isSelected,
			isAutoCodemap: isAutoCodemap,
			hasSlices: !slices.isEmpty,
			codeMapUsage: codeMapUsage
		)

		return RowSeed(
			file: file,
			mode: mode,
			isAutoCodemap: isAutoCodemap,
			slices: slices,
			tokenInfo: info,
			tokenCount: tokenCount(for: file, mode: mode, tokenInfo: info)
		)
	}

	private func buildRowSeeds(
		for files: [FileViewModel],
		autoCodemapIDs: Set<UUID>,
		selectedIDs: Set<UUID>,
		sliceMap: [UUID: [LineRange]],
		tokenInfo: [UUID: TokenInfo],
		codeMapUsage: CodeMapUsage
	) -> [RowSeed] {
		files.map {
			makeRowSeed(
				file: $0,
				autoCodemapIDs: autoCodemapIDs,
				selectedIDs: selectedIDs,
				sliceMap: sliceMap,
				tokenInfo: tokenInfo,
				codeMapUsage: codeMapUsage
			)
		}
	}

	private func buildRows(
		from seeds: [RowSeed],
		codemapPercentBase: Int,
		showRootLabel: Bool
	) -> [FileRowProps] {
		seeds.map {
			makeFileRowProps(
				from: $0,
				codemapPercentBase: codemapPercentBase,
				showRootLabel: showRootLabel
			)
		}
	}
	
	private struct SelectionStats {
		let fullCount: Int
		let fullTokens: Int
		let codemapCount: Int
		let codemapTokens: Int
		let selectedCodemapTokens: Int
	}
	
	private func aggregateStats(
		selectedSeeds: [RowSeed],
		codemapSeeds: [RowSeed],
		codeMapUsage: CodeMapUsage
	) -> SelectionStats {
		var fullCount = 0
		var fullTokens = 0
		var codemapCount = 0
		var codemapTokens = 0
		var selectedCodemapTokens = 0
		var seenFiles = Set<UUID>()

		let isSelectedMode = (codeMapUsage == .selected)
		
		for seed in selectedSeeds {
			guard seenFiles.insert(seed.file.id).inserted else { continue }
			if isSelectedMode {
				// In selected mode: all selected files count as "full files" (no codemap side)
				// Token count uses codemap tokens if available, otherwise full file tokens
				fullCount += 1
				fullTokens += seed.tokenCount
				if seed.mode == .codemap {
					selectedCodemapTokens += seed.tokenCount
				}
			} else {
				// In auto/complete modes: split between full file side and codemap side
				switch seed.mode {
				case .codemap:
					codemapCount += 1
					codemapTokens += seed.tokenCount
					selectedCodemapTokens += seed.tokenCount
				case .full, .slices:
					fullCount += 1
					fullTokens += seed.tokenCount
				}
			}
		}
		
		// Codemap rows only exist in auto/complete modes (activeCodemapFiles is empty in selected mode)
		for seed in codemapSeeds {
			guard seed.mode == .codemap else { continue }
			guard seenFiles.insert(seed.file.id).inserted else { continue }
			codemapCount += 1
			codemapTokens += seed.tokenCount
		}
		
		return SelectionStats(
			fullCount: fullCount,
			fullTokens: fullTokens,
			codemapCount: codemapCount,
			codemapTokens: codemapTokens,
			selectedCodemapTokens: selectedCodemapTokens
		)
	}
	
	private func sort(
		fileRows: [FileRowProps],
		method: SortMethod
	) -> [FileRowProps] {
		@inline(__always)
		func isNameAscending(_ lhs: FileRowProps, _ rhs: FileRowProps) -> Bool {
			let lhsKey = lhs.nameSortKey
			let rhsKey = rhs.nameSortKey
			if lhsKey != rhsKey {
				return lhsKey < rhsKey
			}
			if lhs.name != rhs.name {
				return lhs.name < rhs.name
			}
			let lhsPathKey = lhs.uniqueRelativePathSortKey
			let rhsPathKey = rhs.uniqueRelativePathSortKey
			if lhsPathKey != rhsPathKey {
				return lhsPathKey < rhsPathKey
			}
			return lhs.uniqueRelativePath < rhs.uniqueRelativePath
		}

		@inline(__always)
		func isNameDescending(_ lhs: FileRowProps, _ rhs: FileRowProps) -> Bool {
			let lhsKey = lhs.nameSortKey
			let rhsKey = rhs.nameSortKey
			if lhsKey != rhsKey {
				return lhsKey > rhsKey
			}
			if lhs.name != rhs.name {
				return lhs.name > rhs.name
			}
			let lhsPathKey = lhs.uniqueRelativePathSortKey
			let rhsPathKey = rhs.uniqueRelativePathSortKey
			if lhsPathKey != rhsPathKey {
				return lhsPathKey > rhsPathKey
			}
			return lhs.uniqueRelativePath > rhs.uniqueRelativePath
		}

		return fileRows.sorted { lhs, rhs in
			switch method {
			case .nameAscending:
				return isNameAscending(lhs, rhs)
			case .nameDescending:
				return isNameDescending(lhs, rhs)
			case .tokenAscending:
				if lhs.tokenCount != rhs.tokenCount {
					return lhs.tokenCount < rhs.tokenCount
				}
				return isNameAscending(lhs, rhs)
			case .tokenDescending:
				if lhs.tokenCount != rhs.tokenCount {
					return lhs.tokenCount > rhs.tokenCount
				}
				return isNameAscending(lhs, rhs)
			default:
				return isNameAscending(lhs, rhs)
			}
		}
	}
	
	private func buildFolderGroups(
		fileRows: [FileRowProps],
		promptVM: PromptViewModel,
		multipleRoots: Bool,
		totalDisplayTokens: Int
	) -> [FolderGroupProps] {
		var groups: [String: [FileRowProps]] = [:]
		var folderTokenSums: [String: Int] = [:]

		for row in fileRows {
			let path = folderPath(for: row, multipleRoots: multipleRoots)
			groups[path, default: []].append(row)
			folderTokenSums[path, default: 0] += row.tokenCount
		}

		var result: [FolderGroupProps] = []
		result.reserveCapacity(groups.count)

		for (path, rows) in groups {
			let sortedRows = sort(fileRows: rows, method: promptVM.selectedFilesSortMethod)
			let folderTokenSum = folderTokenSums[path] ?? 0
			let tokenDisplay: String?
			if folderTokenSum > 0 {
				let formatted = String(format: "%.2fk", Double(folderTokenSum) / 1000.0)
				let percent = totalDisplayTokens > 0 ? Int(Double(folderTokenSum) / Double(totalDisplayTokens) * 100) : 0
				tokenDisplay = "~\(formatted) (\(percent)%)"
			} else {
				tokenDisplay = nil
			}
			result.append(
				FolderGroupProps(
					id: path,
					path: path,
					isExpanded: !promptVM.collapsedFolders.contains(path),
					tokenDisplayString: tokenDisplay,
					files: sortedRows
				)
			)
		}

		switch promptVM.selectedFilesSortMethod {
		case .tokenAscending, .tokenDescending:
			result.sort { lhs, rhs in
				let lhsSum = folderTokenSums[lhs.path] ?? 0
				let rhsSum = folderTokenSums[rhs.path] ?? 0
				if lhsSum != rhsSum {
					return promptVM.selectedFilesSortMethod == .tokenAscending ? lhsSum < rhsSum : lhsSum > rhsSum
				}
				return isCaseInsensitiveAscending(lhs.path, rhs.path)
			}
		case .nameAscending:
			result.sort { isCaseInsensitiveAscending($0.path, $1.path) }
		case .nameDescending:
			result.sort { isCaseInsensitiveDescending($0.path, $1.path) }
		default:
			result.sort { isCaseInsensitiveAscending($0.path, $1.path) }
		}

		return result
	}

	private func folderPath(for row: FileRowProps, multipleRoots: Bool) -> String {
		let localFolder = extractFolderPath(from: row.relativePath)
		if multipleRoots {
			return localFolder.isEmpty ? row.rootFolderName : "\(row.rootFolderName)/\(localFolder)"
		}
		return localFolder
	}

	private func extractFolderPath(from relativePath: String) -> String {
		let components = relativePath.split(separator: "/")
		guard components.count > 1 else { return "" }
		return components.dropLast().joined(separator: "/")
	}

	@inline(__always)
	private func isCaseInsensitiveAscending(_ lhs: String, _ rhs: String) -> Bool {
		let lhsKey = lhs.lowercased()
		let rhsKey = rhs.lowercased()
		if lhsKey != rhsKey {
			return lhsKey < rhsKey
		}
		return lhs < rhs
	}

	@inline(__always)
	private func isCaseInsensitiveDescending(_ lhs: String, _ rhs: String) -> Bool {
		let lhsKey = lhs.lowercased()
		let rhsKey = rhs.lowercased()
		if lhsKey != rhsKey {
			return lhsKey > rhsKey
		}
		return lhs > rhs
	}
	
	private func stripRootPrefix(from path: String) -> String {
		guard let slashIndex = path.firstIndex(of: "/") else { return path }
		let nextIndex = path.index(after: slashIndex)
		return String(path[nextIndex...])
	}
	
	private func displayTokenCount(
		fullTokens: Int,
		codeMapUsage: CodeMapUsage,
		tokenVM: TokenCountingViewModel
	) -> String {
		if codeMapUsage == .selected {
			// In selected mode, show ALL selected file tokens (codemap + non-codemap files like git artifacts)
			return String(format: "%.2fk", Double(fullTokens) / 1000.0)
		} else {
			return tokenVM.tokenCountFilesOnly
		}
	}
}
