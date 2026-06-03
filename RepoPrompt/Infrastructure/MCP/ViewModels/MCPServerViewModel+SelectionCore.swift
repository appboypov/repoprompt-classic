import Foundation

extension MCPServerViewModel {
	nonisolated static let codeMapsGloballyDisabledMCPMessage = "Code Maps are globally disabled in Advanced Settings; codemap-only selection modes and get_code_structure are unavailable."

	@MainActor
	var codeMapsGloballyDisabledForMCP: Bool {
		promptVM.codeMapsGloballyDisabled
	}

	@MainActor
	func effectiveMCPCodeMapUsage(_ usage: CodeMapUsage) -> CodeMapUsage {
		promptVM.codeMapsGloballyDisabled ? .none : usage
	}

	/// Describes why a file is rendered as a codemap
	enum CodemapOrigin: String {
		/// Auto-added as a dependency of selected files
		case auto
		/// Explicitly added via mode: "codemap_only"
		case manual
		/// Was selected as full but converted due to codeMapUsage == .selected
		case selectedMode = "selected_mode"
	}

	/// A codemap entry with its origin/reason
	struct CodemapEntry {
		let file: FileViewModel
		let origin: CodemapOrigin
	}

	@MainActor
	protocol SelectionSource {
		func selectedEntries() -> [(file: FileViewModel, ranges: [LineRange]?)]
		func codemapEntries() -> [CodemapEntry]
		func codemapAutoEnabled() -> Bool
		func currentCodeMapUsage() -> CodeMapUsage
		func invalidInputs() -> [String]
	}

	@MainActor
	struct LiveSelectionSource: SelectionSource {
		let fileManager: RepoFileManagerViewModel
		let codeMapUsage: CodeMapUsage

		func selectedEntries() -> [(file: FileViewModel, ranges: [LineRange]?)] {
			let slices = fileManager.selectionSlicesByFileID
			return fileManager.selectedFiles.compactMap { file in
				if codeMapUsage == .selected, file.fileAPI != nil {
					return nil
				}
				return (file, slices[file.id])
			}
		}

		func codemapEntries() -> [CodemapEntry] {
			let selectedFiles = fileManager.selectedFiles
			let selectedIDs = Set(selectedFiles.map { $0.id })
			var result: [CodemapEntry] = []
			var seen = Set<UUID>()

			switch codeMapUsage {
			case .selected:
				// Convert selected files with codemaps to codemap mode
				for file in selectedFiles where file.fileAPI != nil {
					if seen.insert(file.id).inserted {
						result.append(CodemapEntry(file: file, origin: .selectedMode))
					}
				}
			case .complete:
				// Include ALL files with codemaps in the workspace (except selected files)
				for file in fileManager.getAllFileViewModels() where file.fileAPI != nil && !selectedIDs.contains(file.id) {
					if seen.insert(file.id).inserted {
						result.append(CodemapEntry(file: file, origin: .auto))
					}
				}
			case .auto:
				// Include only auto-selected dependency codemaps
				let origin: CodemapOrigin = fileManager.codemapAutoEnabled ? .auto : .manual
				for file in fileManager.autoCodemapFiles where !selectedIDs.contains(file.id) {
					if seen.insert(file.id).inserted {
						result.append(CodemapEntry(file: file, origin: origin))
					}
				}
			case .none:
				// Return empty codemap list
				break
			}
			return result
		}

		func codemapAutoEnabled() -> Bool {
			fileManager.codemapAutoEnabled
		}

		func currentCodeMapUsage() -> CodeMapUsage {
			codeMapUsage
		}

		func invalidInputs() -> [String] {
			[]
		}
	}

	@MainActor
	final class VirtualSelectionSource: SelectionSource {
		private struct Cache {
			let selected: [(file: FileViewModel, ranges: [LineRange]?)]
			let codemap: [CodemapEntry]
			let invalid: [String]
		}

		private let stored: StoredSelection
		private unowned let fileManager: RepoFileManagerViewModel
		private let codeMapUsageValue: CodeMapUsage
		private lazy var cache: Cache = Self.buildCache(
			stored: stored,
			fileManager: fileManager,
			codeMapUsage: codeMapUsageValue
		)

		init(
			stored: StoredSelection,
			fileManager: RepoFileManagerViewModel,
			codeMapUsage: CodeMapUsage
		) {
			self.stored = stored
			self.fileManager = fileManager
			self.codeMapUsageValue = codeMapUsage
		}

		func selectedEntries() -> [(file: FileViewModel, ranges: [LineRange]?)] {
			cache.selected
		}

		func codemapEntries() -> [CodemapEntry] {
			cache.codemap
		}

		func codemapAutoEnabled() -> Bool {
			stored.codemapAutoEnabled
		}

		func currentCodeMapUsage() -> CodeMapUsage {
			codeMapUsageValue
		}

		func invalidInputs() -> [String] {
			cache.invalid
		}

		private static func buildCache(
			stored: StoredSelection,
			fileManager: RepoFileManagerViewModel,
			codeMapUsage: CodeMapUsage
		) -> Cache {
			var selected: [(file: FileViewModel, ranges: [LineRange]?)] = []
			var codemap: [CodemapEntry] = []
			var invalid: [String] = []
			let normalizedSlices = StoredSelectionPathNormalization.standardizedSlices(stored.slices)

			var seenSelected = Set<String>()
			var seenCodemap = Set<UUID>()

			for rawPath in stored.selectedPaths {
				guard let standardized = StoredSelectionPathNormalization.standardizedPath(rawPath) else { continue }
				guard seenSelected.insert(standardized).inserted else { continue }
				if let vm = fileManager.findFileByFullPath(standardized) {
					let ranges = normalizedSlices[standardized]
					selected.append((vm, ranges))
				} else {
					if !invalid.contains(rawPath) {
						invalid.append(rawPath)
					}
				}
			}

			let selectedStandard = Set(selected.map { $0.file.standardizedFullPath })
			let selectedIDs = Set(selected.map { $0.file.id })

			switch codeMapUsage {
			case .selected:
				// Convert selected files with codemaps to codemap mode
				var filteredSelected: [(file: FileViewModel, ranges: [LineRange]?)] = []
				for entry in selected {
					if entry.file.fileAPI != nil {
						if seenCodemap.insert(entry.file.id).inserted {
							codemap.append(CodemapEntry(file: entry.file, origin: .selectedMode))
						}
					} else {
						filteredSelected.append(entry)
					}
				}
				selected = filteredSelected
			case .complete:
				// Include ALL files with codemaps in the workspace (except selected files)
				for file in fileManager.getAllFileViewModels() where file.fileAPI != nil && !selectedIDs.contains(file.id) {
					if seenCodemap.insert(file.id).inserted {
						codemap.append(CodemapEntry(file: file, origin: .auto))
					}
				}
			case .auto:
				// Include stored codemap-only files (manual or auto)
				for rawPath in stored.autoCodemapPaths {
					guard let standardized = StoredSelectionPathNormalization.standardizedPath(rawPath) else { continue }
					guard !selectedStandard.contains(standardized) else { continue }
					if let vm = fileManager.findFileByFullPath(standardized) {
						if seenCodemap.insert(vm.id).inserted {
							// Determine origin: manual if codemapAutoEnabled is false, else auto
							let origin: CodemapOrigin = stored.codemapAutoEnabled ? .auto : .manual
							codemap.append(CodemapEntry(file: vm, origin: origin))
						}
					} else if !invalid.contains(rawPath) {
						invalid.append(rawPath)
					}
				}
			case .none:
				// No codemaps
				break
			}

			return Cache(selected: selected, codemap: codemap, invalid: invalid)
		}
	}

	/// Returns selection-aware FileViewModels for the active execution context (virtual or live).
	@MainActor
	func selectedVMsForCurrentExecContext() async -> [FileViewModel] {
		let collections = await selectionCollectionsForCurrentExecContext()
		return collections.selected.map { $0.file }
	}

	/// Returns the identifiers of files selected in the active execution context.
	@MainActor
	func selectedIDsForCurrentExecContext() async -> Set<UUID> {
		let result = await selectedVMsAndIDsForCurrentExecContext()
		return result.ids
	}

	@MainActor
	func selectionCollectionsForCurrentExecContext() async -> SelectionReplyAssembler.SelectionCollections {
		let metadata = await captureRequestMetadata()
		let execContext = resolveExecContext(from: metadata)
		switch execContext {
		case .virtual(let tabContext):
			let source = VirtualSelectionSource(
				stored: tabContext.selection,
				fileManager: fileManager,
				codeMapUsage: effectiveMCPCodeMapUsage(promptVM.codeMapUsage)
			)
			return await SelectionReplyAssembler.collect(from: source)
		case .live:
			let source = LiveSelectionSource(
				fileManager: fileManager,
				codeMapUsage: effectiveMCPCodeMapUsage(promptVM.codeMapUsage)
			)
			return await SelectionReplyAssembler.collect(from: source)
		}
	}

	/// Convenience helper returning both selected file view models and their IDs.
	@MainActor
	func selectedVMsAndIDsForCurrentExecContext() async -> (files: [FileViewModel], ids: Set<UUID>) {
		let collections = await selectionCollectionsForCurrentExecContext()
		let files = collections.selected.map { $0.file }
		var ids = Set(files.map(\.id))
		if effectiveMCPCodeMapUsage(promptVM.codeMapUsage) == .selected {
			ids.formUnion(collections.codemap.map(\.file.id))
		}
		return (files, ids)
	}

	struct PathFormatter {
		let format: FilePathDisplay
		unowned let owner: MCPServerViewModel

		func displayPath(for vm: FileViewModel) async -> String {
			switch format {
			case .full:
				return vm.fullPath
			case .relative:
				return await owner.prefixedRelativePath(for: vm)
			}
		}
	}

	struct TokenServices {
		unowned let owner: MCPServerViewModel

		@MainActor
		func fullTokens(for vm: FileViewModel) -> Int {
			owner.selectionTokenCache(for: vm) ?? (vm.cachedTokenCount ?? 0)
		}

		func sliceTokens(for vm: FileViewModel, ranges: [LineRange]) async -> Int {
			if let assembly = await vm.assembleContent(for: ranges) {
				return TokenCalculationService.estimateTokens(for: assembly.combinedText)
			}
			return await fullTokens(for: vm)
		}

		@MainActor
		func codemapTokens(for vm: FileViewModel, displayPath: String) -> Int {
			// Always return real estimate - call sites decide whether to include codemap tokens.
			// In normalized "Auto view" replies we need real estimates even if user's copy preset is `.none`.
			return owner.selectionCodemapTokenEstimate(for: vm, displayPath: displayPath)
		}
	}

	struct SelectionReplyAssembler {
		struct SelectionCollections {
			let selected: [(file: FileViewModel, ranges: [LineRange]?)]
			let codemap: [CodemapEntry]
			let codemapAutoEnabled: Bool
			let codeMapUsage: CodeMapUsage
			let invalid: [String]
		}

		/// Metadata for user's actual preset settings (for virtual context state indicators)
		struct UserPresetState {
			let copyCodeMapUsage: String
			let chatCodeMapUsage: String
			/// Token count under user's copy preset settings (optional - computed lazily)
			var copyTokens: Int?
			/// Token count under user's chat preset settings (optional - computed lazily)
			var chatTokens: Int?
			/// What this reply uses (e.g. "auto" for virtual contexts)
			let normalizedCodeMapUsage: String
		}

		static func collect(from source: SelectionSource) async -> SelectionCollections {
			let selected = await source.selectedEntries()
			let codemap = await source.codemapEntries()
			let autoEnabled = await source.codemapAutoEnabled()
			let usage = await source.currentCodeMapUsage()
			let invalid = await source.invalidInputs()
			return SelectionCollections(
				selected: selected,
				codemap: codemap,
				codemapAutoEnabled: autoEnabled,
				codeMapUsage: usage,
				invalid: invalid
			)
		}

		private static func pathMetadata(for vm: FileViewModel) -> (rootPath: String, pathWithinRoot: String) {
			(vm.standardizedRootFolderPath, vm.standardizedRelativePath)
		}

		/// Computes how a file would render under a given codemap usage mode
		static func computeCopyPresetProjection(
			autoRenderMode: String,
			autoTokens: Int,
			hasCodemap: Bool,
			copyUsage: CodeMapUsage,
			codemapTokens: Int
		) -> ToolResultDTOs.SelectedFileInfo.CopyPresetProjection? {
			// Determine what renderMode would be under copy preset
			let copyRenderMode: String
			let copyTokens: Int
			let copyOrigin: String?

			switch copyUsage {
			case .auto:
				// Same as auto view - no projection needed
				return nil

			case .selected:
				// Full/slice files with codemaps become codemaps
				if (autoRenderMode == "full" || autoRenderMode == "slice") && hasCodemap {
					copyRenderMode = "codemap"
					copyTokens = codemapTokens
					copyOrigin = "selected_mode"
				} else if autoRenderMode == "codemap" {
					// Already codemap, no change
					return nil
				} else {
					// No codemap available, stays as is
					return nil
				}

			case .complete:
				// Everything with a codemap becomes codemap
				if hasCodemap && autoRenderMode != "codemap" {
					copyRenderMode = "codemap"
					copyTokens = codemapTokens
					copyOrigin = "complete_mode"
				} else {
					return nil
				}

			case .none:
				// Under 'none' mode, codemaps are disabled
				if autoRenderMode == "codemap" {
					// Codemap-only files wouldn't appear - mark as hidden
					return ToolResultDTOs.SelectedFileInfo.CopyPresetProjection(
						tokens: 0,
						renderMode: "hidden",
						ranges: nil,
						codemapOrigin: nil
					)
				} else {
					// Full/slice stays the same
					return nil
				}
			}

			// Only return projection if it differs from auto view
			if copyRenderMode == autoRenderMode && copyTokens == autoTokens {
				return nil
			}

			return ToolResultDTOs.SelectedFileInfo.CopyPresetProjection(
				tokens: copyTokens,
				renderMode: copyRenderMode,
				ranges: nil,
				codemapOrigin: copyOrigin
			)
		}

		static func buildSelectedFilesReply(
			collections: SelectionCollections,
			formatter: PathFormatter,
			tokens: TokenServices,
			userPresetState: UserPresetState? = nil,
			copyUsage: CodeMapUsage? = nil,
			projection: MCPServerViewModel.CopyPresetProjectionConfig? = nil,
			entryResultsByFileID: [UUID: PromptEntriesEvaluation.EntryResult]? = nil
		) async -> ToolResultDTOs.SelectedFilesReply {
			var files: [ToolResultDTOs.SelectedFileInfo] = []
			var totalTokens = 0
			var fileSlices: [ToolResultDTOs.FileSliceDTO] = []
			var copyTotalTokens = 0
			// Track user copy breakdown by content type
			var copyContentTokens = 0
			var copyCodemapTokens = 0

			var fullCount = 0
			var sliceCount = 0
			var codemapCount = 0
			var fullTokens = 0
			var sliceTokens = 0
			var codemapTokens = 0

			for entry in collections.selected {
				let vm = entry.file
				let displayPath = await formatter.displayPath(for: vm)
				let metadata = pathMetadata(for: vm)
				let ranges = entry.ranges ?? []
				let hasSlices = !ranges.isEmpty
				let entryResult = entryResultsByFileID?[vm.id]
				let tokenCount = if let entryResult {
					entryResult.displayTokens
				} else if hasSlices {
					await tokens.sliceTokens(for: vm, ranges: ranges)
				} else {
					await tokens.fullTokens(for: vm)
				}

				totalTokens += tokenCount
				if hasSlices {
					sliceCount += 1
					sliceTokens += tokenCount
					let dtoRanges = ranges.map { ToolResultDTOs.LineRangeDTO(range: $0) }
					fileSlices.append(.init(
						path: displayPath,
						ranges: dtoRanges,
						rootPath: metadata.rootPath,
						pathWithinRoot: metadata.pathWithinRoot
					))
				} else {
					fullCount += 1
					fullTokens += tokenCount
				}

				let rangesDTOs = hasSlices ? ranges.map { ToolResultDTOs.LineRangeDTO(range: $0) } : nil
				let autoRenderMode = hasSlices ? "slice" : "full"

				// Compute copy preset projection if copy usage differs from auto
				var copyPreset: ToolResultDTOs.SelectedFileInfo.CopyPresetProjection? = nil
				if let copyUsage, copyUsage != .auto {
					let hasCodemap = vm.fileAPI != nil
					let codemapTokenCount = if let entryResult {
						entryResult.codemapTokens
					} else if hasCodemap {
						await tokens.codemapTokens(for: vm, displayPath: displayPath)
					} else {
						0
					}
					copyPreset = computeCopyPresetProjection(
						autoRenderMode: autoRenderMode,
						autoTokens: tokenCount,
						hasCodemap: hasCodemap,
						copyUsage: copyUsage,
						codemapTokens: codemapTokenCount
					)
				}

				// Track copy total tokens and breakdown
				if let cp = copyPreset {
					copyTotalTokens += cp.tokens
					// Track breakdown based on user preset render mode
					switch cp.renderMode {
					case "codemap":
						copyCodemapTokens += cp.tokens
					case "hidden":
						break // 0 tokens, nothing to add
					default: // "full", "slice"
						copyContentTokens += cp.tokens
					}
				} else {
					copyTotalTokens += tokenCount
					copyContentTokens += tokenCount // Original mode is content (full/slice)
				}

				files.append(
					ToolResultDTOs.SelectedFileInfo(
						path: displayPath,
						tokens: tokenCount,
						renderMode: autoRenderMode,
						ranges: rangesDTOs,
						isAuto: false,
						codemapOrigin: nil,
						copyPreset: copyPreset,
						rootPath: metadata.rootPath,
						pathWithinRoot: metadata.pathWithinRoot
					)
				)
			}

			for entry in collections.codemap {
				let vm = entry.file
				let displayPath = await formatter.displayPath(for: vm)
				let metadata = pathMetadata(for: vm)
				let entryResult = entryResultsByFileID?[vm.id]
				let tokenCount: Int
				if let entryResult {
					tokenCount = entryResult.displayTokens
				} else {
					let rawCodemapTokens = await tokens.codemapTokens(for: vm, displayPath: displayPath)
					if rawCodemapTokens == 0 && collections.codeMapUsage == .selected {
						tokenCount = await tokens.fullTokens(for: vm)
					} else {
						tokenCount = rawCodemapTokens
					}
				}
				codemapCount += 1
				codemapTokens += tokenCount
				totalTokens += tokenCount

				// For codemap files, compute copy preset projection
				var copyPreset: ToolResultDTOs.SelectedFileInfo.CopyPresetProjection? = nil
				if let copyUsage, copyUsage != .auto {
					// Under 'none' or 'selected' mode, codemap-only files wouldn't appear
					// Under 'complete' mode, same as auto for codemaps
					if copyUsage == .none || copyUsage == .selected {
						// Codemap-only files wouldn't be included under 'none' or 'selected' mode
						// Mark as hidden (0 tokens, "hidden" mode)
						copyPreset = ToolResultDTOs.SelectedFileInfo.CopyPresetProjection(
							tokens: 0,
							renderMode: "hidden",
							ranges: nil,
							codemapOrigin: nil
						)
					}
					// For 'complete' mode, codemap stays as codemap (no projection needed)
				}

				// Track copy total tokens and breakdown (codemap-only files under 'none' or 'selected' would be 0)
				if let copyUsage {
					if copyUsage == .none || copyUsage == .selected {
						// File wouldn't appear under copy preset
						// Don't add to copyTotalTokens or breakdown
					} else {
						copyTotalTokens += tokenCount
						copyCodemapTokens += tokenCount
					}
				} else {
					copyTotalTokens += tokenCount
					copyCodemapTokens += tokenCount
				}

				files.append(
					ToolResultDTOs.SelectedFileInfo(
						path: displayPath,
						tokens: tokenCount,
						renderMode: "codemap",
						ranges: nil,
						isAuto: entry.origin == .auto,
						codemapOrigin: entry.origin.rawValue,
						copyPreset: copyPreset,
						rootPath: metadata.rootPath,
						pathWithinRoot: metadata.pathWithinRoot
					)
				)
			}

			let summary = ToolResultDTOs.SelectionSummary(
				fullCount: fullCount,
				sliceCount: sliceCount,
				codemapCount: codemapCount,
				fullTokens: fullTokens,
				sliceTokens: sliceTokens,
				codemapTokens: codemapTokens
			)

			var reply = ToolResultDTOs.SelectedFilesReply(
				files: files,
				totalTokens: totalTokens,
				fileSlices: fileSlices.isEmpty ? nil : fileSlices,
				summary: summary,
				codeMapUsage: collections.codeMapUsage.rawValue
			)

			// Populate user preset state indicators if provided
			if let state = userPresetState {
				reply.userCopyCodeMapUsage = state.copyCodeMapUsage
				reply.userChatCodeMapUsage = state.chatCodeMapUsage
				// Use computed copy tokens if we have copy usage, otherwise use provided state
				reply.userCopyTokens = copyUsage != nil ? copyTotalTokens : state.copyTokens
				reply.userChatTokens = state.chatTokens
				reply.normalizedCodeMapUsage = state.normalizedCodeMapUsage
				// Include user copy breakdown if we computed projections
				if copyUsage != nil {
					reply.userCopyContentTokens = copyContentTokens
					reply.userCopyCodemapTokens = copyCodemapTokens
				}
			} else if copyUsage != nil && copyUsage != .auto {
				// Even without full state, include copy tokens if we computed projections
				reply.userCopyCodeMapUsage = copyUsage?.rawValue
				reply.userCopyTokens = copyTotalTokens
				reply.userCopyContentTokens = copyContentTokens
				reply.userCopyCodemapTokens = copyCodemapTokens
			}

			// Build copy preset projection summary if projection config is provided
			if let projection {
				// Compute projected tokens based on includeFiles flag
				let projectedTokens: Int
				if !projection.includeFiles {
					// Files not included - only codemaps if mode supports them
					projectedTokens = projection.codeMapUsage == .none ? 0 : codemapTokens
				} else {
					// Use the computed copy total tokens
					projectedTokens = copyTotalTokens
				}
				reply.copyPresetProjection = ToolResultDTOs.CopyPresetProjectionSummaryDTO(
					codeMapUsage: projection.codeMapUsage.rawValue,
					includesFiles: projection.includeFiles,
					totalTokens: projectedTokens
				)
			}

			return reply
		}

		static func buildSelectionReply(
			collections: SelectionCollections,
			includeBlocks: Bool,
			display: FilePathDisplay,
			formatter: PathFormatter,
			tokens: TokenServices,
			status: String,
			extraInvalid: [String],
			userPresetState: UserPresetState? = nil,
			copyUsage: CodeMapUsage? = nil,
			projection: MCPServerViewModel.CopyPresetProjectionConfig? = nil,
			tokenStatsOverride: ToolResultDTOs.TokenStats? = nil
		) async -> ToolResultDTOs.SelectionReply {
			let filesReply = await buildSelectedFilesReply(
				collections: collections,
				formatter: formatter,
				tokens: tokens,
				userPresetState: userPresetState,
				copyUsage: copyUsage,
				projection: projection
			)

			return await makeSelectionReply(
				filesReply: filesReply,
				collections: collections,
				includeBlocks: includeBlocks,
				display: display,
				status: status,
				extraInvalid: extraInvalid,
				userPresetState: userPresetState,
				tokens: tokens,
				tokenStatsOverride: tokenStatsOverride
			)
		}

		static func makeSelectionReply(
			filesReply: ToolResultDTOs.SelectedFilesReply,
			collections: SelectionCollections,
			includeBlocks: Bool,
			display: FilePathDisplay,
			status: String,
			extraInvalid: [String],
			userPresetState: UserPresetState? = nil,
			tokens: TokenServices? = nil,
			tokenStatsOverride: ToolResultDTOs.TokenStats? = nil
		) async -> ToolResultDTOs.SelectionReply {
			var blocks: [String]? = nil
			if includeBlocks {
				let generated = await generateBlocks(selected: collections.selected, display: display)
				blocks = generated
			}

			var invalid = collections.invalid
			for candidate in extraInvalid where !invalid.contains(candidate) {
				invalid.append(candidate)
			}

			// Compute workspace token stats if tokens service is available
			let tokenStats: ToolResultDTOs.TokenStats? = if let tokenStatsOverride {
				tokenStatsOverride
			} else {
				await {
					guard let tokens = tokens else { return nil }
					// Force immediate token recount to avoid stale breakdown values
					await tokens.owner.promptVM.tokenCountingViewModel.forceImmediateRecount()
					// Extract content vs codemap breakdown from summary
					let filesContentTokens = (filesReply.summary?.fullTokens ?? 0) + (filesReply.summary?.sliceTokens ?? 0)
					let codemapsTokens = filesReply.summary?.codemapTokens ?? 0
					return await tokens.owner.computeWorkspaceTokenStats(
						filesTokens: filesReply.totalTokens,
						filesContentTokens: filesContentTokens > 0 ? filesContentTokens : nil,
						codemapsTokens: codemapsTokens > 0 ? codemapsTokens : nil
					)
				}()
			}

			return ToolResultDTOs.SelectionReply(
				files: filesReply.files,
				totalTokens: filesReply.totalTokens,
				status: status,
				invalidPaths: invalid.isEmpty ? nil : invalid,
				blocks: blocks,
				codeStructure: nil,
				fileSlices: filesReply.fileSlices,
				codemapAutoEnabled: collections.codemapAutoEnabled,
				summary: filesReply.summary,
				codeMapUsage: collections.codeMapUsage.rawValue,
				// User preset state indicators - use filesReply values (computed) where available
				userCopyCodeMapUsage: filesReply.userCopyCodeMapUsage ?? userPresetState?.copyCodeMapUsage,
				userChatCodeMapUsage: filesReply.userChatCodeMapUsage ?? userPresetState?.chatCodeMapUsage,
				userCopyTokens: filesReply.userCopyTokens ?? userPresetState?.copyTokens,
				userChatTokens: filesReply.userChatTokens ?? userPresetState?.chatTokens,
				normalizedCodeMapUsage: filesReply.normalizedCodeMapUsage ?? userPresetState?.normalizedCodeMapUsage,
				tokenStats: tokenStats,
				copyPresetProjection: filesReply.copyPresetProjection
			)
		}

		static func generateBlocks(
			selected: [(file: FileViewModel, ranges: [LineRange]?)],
			display: FilePathDisplay
		) async -> [String] {
			guard !selected.isEmpty else { return [] }
			let entries = selected.map { item in
				PromptFileEntry(file: item.file, isCodemap: false, ranges: item.ranges)
			}
			return await PromptPackagingService.generateFileContents(
				entries,
				filePathDisplay: display
			)
		}

		/// Builds lightweight FileSliceDTO array from collections without token calculations.
		/// Only produces entries for files with at least one slice.
		static func buildFileSlices(
			collections: SelectionCollections,
			formatter: PathFormatter
		) async -> [ToolResultDTOs.FileSliceDTO] {
			var slices: [ToolResultDTOs.FileSliceDTO] = []
			slices.reserveCapacity(collections.selected.count)

			for entry in collections.selected {
				let vm = entry.file
				let ranges = entry.ranges ?? []
				guard !ranges.isEmpty else { continue }

				let displayPath = await formatter.displayPath(for: vm)
				let metadata = pathMetadata(for: vm)
				let dtoRanges = ranges.map { ToolResultDTOs.LineRangeDTO(range: $0) }
				slices.append(.init(
					path: displayPath,
					ranges: dtoRanges,
					rootPath: metadata.rootPath,
					pathWithinRoot: metadata.pathWithinRoot
				))
			}

			return slices
		}

		/// Post-filter a SelectionReply for "codemaps" view.
		static func applyViewFilter(_ reply: ToolResultDTOs.SelectionReply, view: String) -> ToolResultDTOs.SelectionReply {
			guard view == "codemaps", let files = reply.files else { return reply }

			let filteredFiles = files.filter { $0.renderMode == "codemap" }
			let filteredPaths = Set(filteredFiles.map { $0.path })
			let filteredSlices = reply.fileSlices?.filter { filteredPaths.contains($0.path) }
			let totalTokens = filteredFiles.reduce(0) { $0 + $1.tokens }

			// Recompute a minimal summary for the filtered view to avoid confusing totals
			let summary = ToolResultDTOs.SelectionSummary(
				fullCount: 0,
				sliceCount: 0,
				codemapCount: filteredFiles.count,
				fullTokens: 0,
				sliceTokens: 0,
				codemapTokens: totalTokens
			)

			return ToolResultDTOs.SelectionReply(
				files: filteredFiles,
				totalTokens: totalTokens,
				status: reply.status,
				invalidPaths: reply.invalidPaths,
				// No content blocks for codemaps view
				blocks: nil,
				codeStructure: reply.codeStructure,
				fileSlices: filteredSlices,
				codemapAutoEnabled: reply.codemapAutoEnabled,
				summary: summary,
				codeMapUsage: reply.codeMapUsage,
				// Preserve user preset state indicators
				userCopyCodeMapUsage: reply.userCopyCodeMapUsage,
				userChatCodeMapUsage: reply.userChatCodeMapUsage,
				userCopyTokens: reply.userCopyTokens,
				userChatTokens: reply.userChatTokens,
				normalizedCodeMapUsage: reply.normalizedCodeMapUsage,
				// Preserve workspace token stats (total breakdown stays the same even for filtered view)
				tokenStats: reply.tokenStats
			)
		}
	}

	struct CodeStructureBuilder {
		unowned let owner: MCPServerViewModel

		func build(for files: [FileViewModel]) async -> ToolResultDTOs.SelectedCodeStructureDTO? {
			guard !files.isEmpty else { return nil }
			let disabled = await MainActor.run { owner.promptVM.codeMapsGloballyDisabled }
			guard !disabled else { return nil }

			return await owner.buildCodeStructureDTO(
				from: files,
				maxResults: 25,
				includeUnmappedPaths: true
			)
		}
	}

	@MainActor
	func codemapUnavailableMessage(for file: FileViewModel) async -> String {
		let displayPath = await prefixedRelativePath(for: file)
		return "codemap unavailable: \(displayPath)"
	}
}
