import Foundation

extension MCPServerViewModel {
	@MainActor
	func stabilizedVirtualSelection(for context: TabScopedContext) async -> StoredSelection {
		let candidatePaths = context.selection.selectedPaths + Array(context.selection.slices.keys)
		await fileManager.waitForPendingSliceRebases(affectingCandidatePaths: candidatePaths)

		// For any tab-bound virtual context (including runs), prefer latest stored tab selection.
		// This prevents resurrecting stale slices from the run snapshot after the user clears them.
		if let manager = workspaceManager,
			let liveTab = manager.composeTab(with: context.tabID) {
			return liveTab.selection
		}

		return context.selection
	}

	struct TabSelectionData {
		struct SelectedEntry {
			let file: FileViewModel
			let ranges: [LineRange]?
		}

		var selected: [SelectedEntry] = []
		var codemap: [FileViewModel] = []
		var invalidInputs: [String] = []
	}

	/// Builds the UserPresetState for virtual contexts, capturing the user's actual preset settings.
	/// This allows the builder to know what the user sees (different codemap mode) while working with normalized auto view.
	@MainActor
	func buildUserPresetState() -> SelectionReplyAssembler.UserPresetState {
		// Use the current copy/chat codemap usage settings from PromptViewModel
		let copyUsage = promptVM.codeMapUsage
		let chatUsage = promptVM.codeMapUsageForChat
		return SelectionReplyAssembler.UserPresetState(
			copyCodeMapUsage: copyUsage.rawValue,
			chatCodeMapUsage: chatUsage.rawValue,
			copyTokens: nil,  // Can be computed lazily if needed
			chatTokens: nil,  // Can be computed lazily if needed
			normalizedCodeMapUsage: effectiveMCPCodeMapUsage(.auto).rawValue
		)
	}

	@MainActor
	func tabSelectionCollections(
		from selection: StoredSelection,
		codeMapUsageOverride: CodeMapUsage? = nil
	) async -> SelectionReplyAssembler.SelectionCollections {
		let requestedUsage = codeMapUsageOverride ?? promptVM.codeMapUsage
		let source = VirtualSelectionSource(
			stored: selection,
			fileManager: fileManager,
			codeMapUsage: effectiveMCPCodeMapUsage(requestedUsage)
		)
		return await SelectionReplyAssembler.collect(from: source)
	}

	@MainActor
	func currentLiveStoredSelection() -> StoredSelection {
		var slices: [String: [LineRange]] = [:]
		for file in fileManager.selectedFiles {
			if let ranges = fileManager.selectionSlicesByFileID[file.id], !ranges.isEmpty {
				slices[file.standardizedFullPath] = ranges
			}
		}

		return StoredSelection(
			selectedPaths: fileManager.selectedFiles.map(\.standardizedFullPath),
			autoCodemapPaths: fileManager.autoCodemapFiles.map(\.standardizedFullPath),
			slices: slices,
			codemapAutoEnabled: fileManager.codemapAutoEnabled
		)
	}

	@MainActor
	private func makeTabSelectionData(
		from collections: SelectionReplyAssembler.SelectionCollections
	) -> TabSelectionData {
		var data = TabSelectionData()
		data.selected = collections.selected.map { .init(file: $0.file, ranges: $0.ranges) }
		data.codemap = collections.codemap.map { $0.file }
		data.invalidInputs = collections.invalid
		return data
	}

	@MainActor
	func evaluateVirtualPromptEntries(
		for selection: StoredSelection,
		codeMapUsage: CodeMapUsage
	) async -> PromptEntriesEvaluation {
		let fileEntries = fileManager.buildPromptEntries(
			for: selection,
			codeMapUsage: codeMapUsage,
			allFileAPIs: promptVM.tokenCountingViewModel.cachedFileAPIs
		)
		let snapshots = await promptVM.tokenCountingViewModel.buildPromptEntrySnapshots(
			from: fileEntries,
			filePathDisplay: promptVM.filePathDisplayOption
		)
		let service = TokenCalculationService()
		return await service.evaluatePromptEntries(snapshots)
	}

	@MainActor
	private func virtualSelectionFileTreeText(
		selectedFiles: [FileViewModel],
		resolvedContext: PromptContextResolved
	) async -> String {
		guard resolvedContext.rendersFileTree else { return "" }
		let (roots, displayOption) = tabRootFoldersAndDisplayOption()
		let onlyIncludeRootsWithSelectedFiles = promptVM.onlyIncludeRootsWithSelectedFiles
		let rootsToUse: [FolderViewModel]
		if onlyIncludeRootsWithSelectedFiles {
			rootsToUse = roots.filter { root in
				selectedFiles.contains { $0.rootFolderPath == root.fullPath }
			}
		} else {
			rootsToUse = roots
		}
		guard !rootsToUse.isEmpty else { return "" }
		let selectedIDs = Set(selectedFiles.map(\.id))
		let showCodeMapMarkers = !promptVM.codeMapsGloballyDisabled
		return await Task.detached(priority: .userInitiated) {
			CodeMapExtractor.generateFileTree(using: FileTreeSelectionContext(
				rootFolders: rootsToUse,
				selectedFileIDs: selectedIDs,
				option: resolvedContext.effectiveFileTreeMode,
				filePathDisplay: displayOption,
				onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
				includeLegend: true,
				isMCPContext: false,
				showCodeMapMarkers: showCodeMapMarkers
			))
		}.value
	}

	@MainActor
	private func virtualSelectionGitDiffText(
		for selection: StoredSelection,
		resolvedContext: PromptContextResolved
	) async -> String? {
		switch resolvedContext.gitInclusion {
		case .none:
			return nil
		case .selected:
			let selectedPaths = await gitDiffPaths(for: selection)
			return await promptVM.gitViewModel.getDiffForAbsolutePaths(selectedPaths, forceRefreshStatus: true)
		case .complete:
			return await promptVM.gitViewModel.getDiffUsing(inclusionMode: .all, forceRefreshStatus: true)
		}
	}

	@MainActor
	private func xmlFormattingPrompt(
		for resolvedContext: PromptContextResolved,
		selectedFiles: [FileViewModel],
		codemapFiles: [FileViewModel]
	) -> String {
		guard let xmlFormat = resolvedContext.xmlFormat else { return "" }
		let promptFormat: DiffViewModel.PromptFormat = switch xmlFormat {
		case .diff:
			.diff
		case .whole, .architect:
			.whole
		}
		let languageSource = selectedFiles.isEmpty ? codemapFiles : selectedFiles
		let language = SystemPromptService.predominantLanguage(from: languageSource)
		return SystemPromptService.getApplyInstructions(
			format: promptFormat,
			allowRewrite: promptVM.allowDiffModelsToRewrite,
			language: language
		)
	}

	@MainActor
	func buildVirtualTokenBreakdown(
		for context: TabScopedContext,
		resolvedContext: PromptContextResolved,
		selectedFiles: [FileViewModel],
		codemapFiles: [FileViewModel]
	) async -> TokenComponentBreakdown {
		let selectedInstructionsText = promptVM.metaInstructions(
			for: resolvedContext,
			language: "Swift",
			selectedPromptIDsOverride: context.selectedMetaPromptIDs
		)
		.map(\.content)
		.joined(separator: "\n\n")
		let isActiveWorkspaceBound = context.workspaceID == nil || context.workspaceID == workspaceManager?.activeWorkspace?.id
		let fileTreeText = isActiveWorkspaceBound
			? await virtualSelectionFileTreeText(selectedFiles: selectedFiles, resolvedContext: resolvedContext)
			: ""
		let gitDiffText = isActiveWorkspaceBound
			? await virtualSelectionGitDiffText(for: context.selection, resolvedContext: resolvedContext)
			: nil
		let metadataText = resolvedContext.includeMCPMetadata
			? promptVM.mcpMetadataBlockIfNeeded(for: resolvedContext, tabOverride: (context.tabID, context.tabName))
			: nil
		let promptText = resolvedContext.includeUserPrompt ? context.promptText : ""
		let duplicateUserPrompt = resolvedContext.includeUserPrompt ? promptVM.duplicateUserInstructionsAtTop : false
		return TokenCalculationService.calculateComponentBreakdown(
			promptText: promptText,
			selectedInstructionsText: selectedInstructionsText,
			includeDiffFormatting: resolvedContext.xmlFormat != nil,
			xmlFormattingPrompt: xmlFormattingPrompt(
				for: resolvedContext,
				selectedFiles: selectedFiles,
				codemapFiles: codemapFiles
			),
			fileTreeText: fileTreeText,
			gitDiffText: gitDiffText,
			metadataText: metadataText,
			duplicateUserInstructionsAtTop: duplicateUserPrompt
		)
	}

	@MainActor
	func buildVirtualSelectionTokenStats(
		for context: TabScopedContext,
		filesReply: ToolResultDTOs.SelectedFilesReply,
		resolvedContext: PromptContextResolved,
		selectedFiles: [FileViewModel],
		codemapFiles: [FileViewModel]
	) async -> ToolResultDTOs.TokenStats {
		let filesContentTokens = (filesReply.summary?.fullTokens ?? 0) + (filesReply.summary?.sliceTokens ?? 0)
		let codemapsTokens = filesReply.summary?.codemapTokens ?? 0
		let breakdown = await buildVirtualTokenBreakdown(
			for: context,
			resolvedContext: resolvedContext,
			selectedFiles: selectedFiles,
			codemapFiles: codemapFiles
		)
		return Self.makeTokenStats(
			filesTokens: filesReply.totalTokens,
			filesContentTokens: filesContentTokens > 0 ? filesContentTokens : nil,
			codemapsTokens: codemapsTokens > 0 ? codemapsTokens : nil,
			breakdown: breakdown
		)
	}

	@MainActor
	func buildTabSelectedFilesReply(
		from selection: StoredSelection,
		codeMapUsageOverride: CodeMapUsage? = nil,
		display: FilePathDisplay = .relative
	) async -> (ToolResultDTOs.SelectedFilesReply, TabSelectionData) {
		let collections = await tabSelectionCollections(from: selection, codeMapUsageOverride: codeMapUsageOverride)
		let evaluation = await evaluateVirtualPromptEntries(
			for: selection,
			codeMapUsage: collections.codeMapUsage
		)
		let formatter = PathFormatter(format: display, owner: self)
		let tokens = TokenServices(owner: self)
		// Include user preset state when using codemap override (normalized view)
		let userPresetState = codeMapUsageOverride != nil ? buildUserPresetState() : nil
		let reply = await SelectionReplyAssembler.buildSelectedFilesReply(
			collections: collections,
			formatter: formatter,
			tokens: tokens,
			userPresetState: userPresetState,
			entryResultsByFileID: evaluation.entryResultsByFileID
		)
		let data = makeTabSelectionData(from: collections)
		return (reply, data)
	}

	@MainActor
	func buildTabSelectionReply(
		from selection: StoredSelection,
		includeBlocks: Bool,
		display: FilePathDisplay,
		extraInvalid: [String] = [],
		viewMode: String? = nil,
		codeMapUsageOverride: CodeMapUsage? = nil,
		virtualContext: TabScopedContext? = nil
	) async -> ToolResultDTOs.SelectionReply {
		// Always use .auto mode for manage_selection (normalized view)
		let effectiveOverride = effectiveMCPCodeMapUsage(codeMapUsageOverride ?? .auto)
		let collections = await tabSelectionCollections(from: selection, codeMapUsageOverride: effectiveOverride)
		let evaluation = await evaluateVirtualPromptEntries(
			for: selection,
			codeMapUsage: collections.codeMapUsage
		)
		let formatter = PathFormatter(format: display, owner: self)
		let tokens = TokenServices(owner: self)

		// Get user's effective copy preset mode
		let copyUsage = promptVM.effectiveCopyCodeMapUsage()

		// Include user preset state when copy mode differs from auto or a global override is active
		let userPresetState = (copyUsage != .auto || promptVM.codeMapsGloballyDisabled) ? buildUserPresetState() : nil

		let filesReply = await SelectionReplyAssembler.buildSelectedFilesReply(
			collections: collections,
			formatter: formatter,
			tokens: tokens,
			userPresetState: userPresetState,
			copyUsage: copyUsage != .auto ? copyUsage : nil,
			entryResultsByFileID: evaluation.entryResultsByFileID
		)

		let tokenStatsOverride: ToolResultDTOs.TokenStats?
		if let virtualContext {
			let selectedFiles = collections.selected.map(\.file)
			let codemapFiles = collections.codemap.map(\.file)
			tokenStatsOverride = await buildVirtualSelectionTokenStats(
				for: virtualContext,
				filesReply: filesReply,
				resolvedContext: promptVM.resolvePromptContext(),
				selectedFiles: selectedFiles,
				codemapFiles: codemapFiles
			)
		} else {
			tokenStatsOverride = nil
		}

		var reply = await SelectionReplyAssembler.makeSelectionReply(
			filesReply: filesReply,
			collections: collections,
			includeBlocks: includeBlocks,
			display: display,
			status: "ok",
			extraInvalid: extraInvalid,
			userPresetState: userPresetState,
			tokens: tokens,
			tokenStatsOverride: tokenStatsOverride
		)
		
		// Inject minimal codeStructure.unmappedPaths to report pending codemaps
		if reply.codeStructure == nil {
			if let minimal = await buildUnmappedOnlyCodeStructure(collections: collections, display: display) {
				reply = ToolResultDTOs.SelectionReply(
					files: reply.files,
					totalTokens: reply.totalTokens,
					status: reply.status,
					invalidPaths: reply.invalidPaths,
					blocks: reply.blocks,
					codeStructure: minimal,
					fileSlices: reply.fileSlices,
					codemapAutoEnabled: reply.codemapAutoEnabled,
					summary: reply.summary,
					codeMapUsage: reply.codeMapUsage,
					// Preserve user preset state indicators
					userCopyCodeMapUsage: reply.userCopyCodeMapUsage,
					userChatCodeMapUsage: reply.userChatCodeMapUsage,
					userCopyTokens: reply.userCopyTokens,
					userChatTokens: reply.userChatTokens,
					normalizedCodeMapUsage: reply.normalizedCodeMapUsage,
					tokenStats: reply.tokenStats
				)
			}
		}

		if let v = viewMode, v == "codemaps" {
			reply = SelectionReplyAssembler.applyViewFilter(reply, view: v)
		}
		return reply
	}

	// MARK: - Unified Selection Reply Builder

	/// Unified entry point to always build a full selection snapshot for
	/// the current execution context (virtual or live).
	@MainActor
	func buildCurrentSelectionReply(
		includeBlocks: Bool,
		display: FilePathDisplay,
		extraInvalid: [String] = [],
		viewMode: String? = nil,
		execContext: ExecContext
	) async -> ToolResultDTOs.SelectionReply {
		switch execContext {
		case .virtual(let ctx):
			let stabilizedSelection = await stabilizedVirtualSelection(for: ctx)
			var virtualContext = ctx
			virtualContext.selection = stabilizedSelection
			return await buildTabSelectionReply(
				from: stabilizedSelection,
				includeBlocks: includeBlocks,
				display: display,
				extraInvalid: extraInvalid,
				viewMode: viewMode,
				codeMapUsageOverride: .auto,
				virtualContext: virtualContext
			)

		case .live:
			// Ensure reported slice ranges reflect any in-flight file-modification rebases.
			await fileManager.waitForPendingSliceRebasesAffectingSelection()

			// Always use .auto mode for manage_selection (normalized view)
			let source = LiveSelectionSource(
				fileManager: self.fileManager,
				codeMapUsage: effectiveMCPCodeMapUsage(.auto)
			)
			let collections = await SelectionReplyAssembler.collect(from: source)
			let formatter = PathFormatter(format: display, owner: self)
			let tokens = TokenServices(owner: self)

			// Get user's effective copy preset mode
			let copyUsage = promptVM.effectiveCopyCodeMapUsage()

			// Include user preset state when copy mode differs from auto or a global override is active
			let userPresetState = (copyUsage != .auto || promptVM.codeMapsGloballyDisabled) ? buildUserPresetState() : nil

			var reply = await SelectionReplyAssembler.buildSelectionReply(
				collections: collections,
				includeBlocks: includeBlocks,
				display: display,
				formatter: formatter,
				tokens: tokens,
				status: "ok",
				extraInvalid: extraInvalid,
				userPresetState: userPresetState,
				copyUsage: copyUsage != .auto ? copyUsage : nil
			)

			// Inject minimal codeStructure.unmappedPaths to report pending codemaps
			if reply.codeStructure == nil {
				if let minimal = await buildUnmappedOnlyCodeStructure(collections: collections, display: display) {
					reply = ToolResultDTOs.SelectionReply(
						files: reply.files,
						totalTokens: reply.totalTokens,
						status: reply.status,
						invalidPaths: reply.invalidPaths,
						blocks: reply.blocks,
						codeStructure: minimal,
						fileSlices: reply.fileSlices,
						codemapAutoEnabled: reply.codemapAutoEnabled,
						summary: reply.summary,
						codeMapUsage: reply.codeMapUsage,
						// Live context: no user preset state indicators
						userCopyCodeMapUsage: nil,
						userChatCodeMapUsage: nil,
						userCopyTokens: nil,
						userChatTokens: nil,
						normalizedCodeMapUsage: nil,
						tokenStats: reply.tokenStats
					)
				}
			}

			if let v = viewMode, v == "codemaps" {
				reply = SelectionReplyAssembler.applyViewFilter(reply, view: v)
			}
			return reply
		}
	}

	func selectedFilesWithStats() async -> ToolResultDTOs.SelectedFilesReply {
		// Get user's effective copy preset mode for projection
		let copyUsage = await MainActor.run { promptVM.effectiveCopyCodeMapUsage() }
		let userPresetState = await MainActor.run { (copyUsage != .auto || promptVM.codeMapsGloballyDisabled) ? buildUserPresetState() : nil }

		await fileManager.waitForPendingSliceRebasesAffectingSelection()

		// Always use .auto mode for normalized view
		let source = await MainActor.run {
			LiveSelectionSource(
				fileManager: self.fileManager,
				codeMapUsage: self.effectiveMCPCodeMapUsage(.auto)
			)
		}
		let collections = await SelectionReplyAssembler.collect(from: source)
		let formatter = PathFormatter(format: .relative, owner: self)
		let tokens = TokenServices(owner: self)
		return await SelectionReplyAssembler.buildSelectedFilesReply(
			collections: collections,
			formatter: formatter,
			tokens: tokens,
			userPresetState: userPresetState,
			copyUsage: copyUsage != .auto ? copyUsage : nil
		)
	}
	
	// MARK: - Unmapped Paths Helper
	
	/// Builds a minimal code structure DTO containing only unmappedPaths
	/// (files without codemaps). Used to report pending codemaps in selection replies
	/// without generating full codemap content.
	@MainActor
	func buildUnmappedOnlyCodeStructure(
		collections: SelectionReplyAssembler.SelectionCollections,
		display: FilePathDisplay
	) async -> ToolResultDTOs.SelectedCodeStructureDTO? {
		guard !promptVM.codeMapsGloballyDisabled else { return nil }
		// Combine selected + codemap files
		let files = collections.selected.map { $0.file } + collections.codemap.map { $0.file }
		guard !files.isEmpty else { return nil }
		
		var unmapped: [String] = []
		var seen = Set<String>()
		for vm in files where vm.fileAPI == nil {
			let p: String
			switch display {
			case .full:
				p = vm.fullPath
			case .relative:
				p = await prefixedRelativePath(for: vm)
			}
			if seen.insert(p).inserted {
				unmapped.append(p)
			}
		}
		
		guard !unmapped.isEmpty else { return nil }
		
		// Minimal DTO: report unmappedPaths only; keep content empty and counts neutral
		return ToolResultDTOs.SelectedCodeStructureDTO(
			fileCount: 0,
			content: "",
			unmappedPaths: unmapped,
			omittedCount: nil
		)
	}
}
