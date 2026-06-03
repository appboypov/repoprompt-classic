import Foundation

extension MCPServerViewModel {
	@MainActor
	func buildTabWorkspaceContext(
		context: TabScopedContext,
		include: Set<String>,
		display: FilePathDisplay,
		copyPresetOverride: CopyPreset? = nil
	) async -> ToolResultDTOs.PromptContextDTO {
		let includeSelection = include.contains("selection")
		let requireSelectionData = includeSelection
			|| include.contains("files")
			|| include.contains("code")
			|| include.contains("tokens")

		var collections: SelectionReplyAssembler.SelectionCollections? = nil
		var selectionReply: ToolResultDTOs.SelectedFilesReply? = nil

		// Get active and effective presets + resolved config
		let activePreset = promptVM.currentCopyPreset()
		let effectivePreset = copyPresetOverride ?? activePreset
		var resolvedCfg = promptVM.resolvePromptContext(effectivePreset, custom: promptVM.workingCopyCustomizations)
		if promptVM.codeMapsGloballyDisabled {
			resolvedCfg.codeMapUsage = .none
		}
		let projectionConfig = projectionConfig(from: resolvedCfg)

		// Get effective copy usage from resolved config
		let copyUsage = effectiveMCPCodeMapUsage(resolvedCfg.codeMapUsage)

		// Include user preset state when copy mode differs from auto or a global override is active
		let userPresetState = (copyUsage != .auto || promptVM.codeMapsGloballyDisabled) ? buildUserPresetState() : nil

		if requireSelectionData {
			// Always use .auto mode for normalized view
			let source = VirtualSelectionSource(
				stored: context.selection,
				fileManager: fileManager,
				codeMapUsage: effectiveMCPCodeMapUsage(.auto)
			)
			let formatter = PathFormatter(format: .relative, owner: self)
			let tokens = TokenServices(owner: self)
			let gathered = await SelectionReplyAssembler.collect(from: source)
			let evaluation = await evaluateVirtualPromptEntries(
				for: context.selection,
				codeMapUsage: gathered.codeMapUsage
			)
			let reply = await SelectionReplyAssembler.buildSelectedFilesReply(
				collections: gathered,
				formatter: formatter,
				tokens: tokens,
				userPresetState: userPresetState,
				copyUsage: copyUsage != .auto ? copyUsage : nil,
				projection: projectionConfig,
				entryResultsByFileID: evaluation.entryResultsByFileID
			)
			collections = gathered
			selectionReply = reply
		} else if includeSelection {
			// Always use .auto mode for normalized view
			selectionReply = (await buildTabSelectedFilesReply(from: context.selection, codeMapUsageOverride: .auto)).0
		}

		let selectionDTO = includeSelection ? selectionReply : nil

		var fileBlocks: [String]? = nil
		if include.contains("files") {
			if let coll = collections {
				fileBlocks = await SelectionReplyAssembler.generateBlocks(
					selected: coll.selected,
					display: display
				)
			} else {
				fileBlocks = []
			}
		}

		var codeStructDTO: ToolResultDTOs.SelectedCodeStructureDTO? = nil
		if include.contains("code"), !promptVM.codeMapsGloballyDisabled, let coll = collections {
			let builder = CodeStructureBuilder(owner: self)
			let combined = coll.selected.map { $0.file } + coll.codemap.map { $0.file }
			codeStructDTO = await builder.build(for: combined)
		}

		var fileTreeDTO: ToolResultDTOs.FileTreeDTO? = nil
		if include.contains("tree"), let coll = collections {
			let selectedIDs = Set(coll.selected.map { $0.file.id })
			let (roots, displayOption) = tabRootFoldersAndDisplayOption()
			if roots.isEmpty {
				let msg = await tabWorkspaceContextMessage(forOperation: tabFileTreeToolName, path: nil)
				fileTreeDTO = .init(
					rootsCount: 0,
					usesLegend: false,
					tree: msg,
					note: nil
				)
			} else {
				let showCodeMapMarkers = !promptVM.codeMapsGloballyDisabled
				let tree = await Task.detached(priority: .userInitiated) {
					CodeMapExtractor.generateFileTree(using: FileTreeSelectionContext(
						rootFolders: roots,
						selectedFileIDs: selectedIDs,
						option: .selected,
						filePathDisplay: displayOption,
						onlyIncludeRootsWithSelectedFiles: false,
						includeLegend: true,
						isMCPContext: false,
						showCodeMapMarkers: showCodeMapMarkers
					))
				}.value
				fileTreeDTO = .init(
					rootsCount: roots.count,
					usesLegend: true,
					tree: tree,
					note: nil
				)
			}
		}

		var tokenStatsDTO: ToolResultDTOs.TokenStats? = nil
		var userTokenStatsDTO: ToolResultDTOs.TokenStats? = nil
		var tokenStatsNote: String? = nil
		if include.contains("tokens") {
			let fileTokens = selectionReply?.totalTokens ?? 0
			let filesContentTokens = (selectionReply?.summary?.fullTokens ?? 0) + (selectionReply?.summary?.sliceTokens ?? 0)
			let codemapsTokens = selectionReply?.summary?.codemapTokens ?? 0
			let selectedFiles = collections?.selected.map { $0.file } ?? []
			let codemapFiles = collections?.codemap.map { $0.file } ?? []
			let breakdown = await buildVirtualTokenBreakdown(
				for: context,
				resolvedContext: resolvedCfg,
				selectedFiles: selectedFiles,
				codemapFiles: codemapFiles
			)
			tokenStatsDTO = Self.makeTokenStats(
				filesTokens: fileTokens,
				filesContentTokens: filesContentTokens > 0 ? filesContentTokens : nil,
				codemapsTokens: codemapsTokens > 0 ? codemapsTokens : nil,
				breakdown: breakdown
			)

			if let userFileTokens = selectionReply?.userCopyTokens, userFileTokens != fileTokens {
				let userContentTokens = selectionReply?.userCopyContentTokens ?? 0
				let userCodemapTokens = selectionReply?.userCopyCodemapTokens ?? 0
				userTokenStatsDTO = Self.makeTokenStats(
					filesTokens: userFileTokens,
					filesContentTokens: userContentTokens > 0 ? userContentTokens : nil,
					codemapsTokens: userCodemapTokens > 0 ? userCodemapTokens : nil,
					breakdown: breakdown
				)
				let codemapDelta = fileTokens - userFileTokens
				tokenStatsNote = "Difference: \(codemapDelta) codemap tokens (API signatures). Your preset excludes these, so exports use \(userFileTokens) file tokens, not \(fileTokens)."
			}
		}

		let prompt = include.contains("prompt") ? context.promptText : ""

		// Build copy preset context DTO (shows active vs effective if overridden)
		let copyPresetContextDTO = buildCopyPresetContextDTO(active: activePreset, effective: effectivePreset)

		return ToolResultDTOs.PromptContextDTO(
			prompt: prompt,
			selection: selectionDTO,
			fileBlocks: fileBlocks,
			codeStructure: codeStructDTO,
			fileTree: fileTreeDTO,
			tokenStats: tokenStatsDTO,
			userTokenStats: userTokenStatsDTO,
			tokenStatsNote: tokenStatsNote,
			copyPreset: copyPresetContextDTO,
			copyPresets: nil
		)
	}

	nonisolated static func gitDiffCandidates(from selection: StoredSelection) -> [String] {
		var candidates = StoredSelectionPathNormalization.standardizedPaths(selection.selectedPaths)
		let seen = Set(candidates)
		var dedupedSeen = seen
		for (path, ranges) in StoredSelectionPathNormalization.standardizedSlices(selection.slices) where !ranges.isEmpty {
			guard dedupedSeen.insert(path).inserted else { continue }
			candidates.append(path)
		}
		return candidates
	}

	nonisolated static func resolveGitDiffPaths(
		candidates: [String],
		resolvedMap: [String: String],
		normalizeUserInput: (String) -> String,
		fileExists: (String) -> Bool
	) -> [String] {
		var seen = Set<String>()
		var results: [String] = []
		results.reserveCapacity(candidates.count)

		for raw in candidates {
			if let resolved = resolvedMap[raw] {
				let std = StandardizedPath.absolute(resolved)
				if seen.insert(std).inserted {
					results.append(std)
				}
				continue
			}

			let normalized = normalizeUserInput(raw)
			guard normalized.hasPrefix("/") else { continue }
			let std = StandardizedPath.absolute(normalized)
			if fileExists(std), seen.insert(std).inserted {
				results.append(std)
			}
		}

		return results
	}

	@MainActor
	func buildExportSelectedFileInfos(
		execContext: ExecContext,
		cfg: PromptContextResolved,
		selectionOverride: StoredSelection? = nil,
		display: FilePathDisplay
	) async -> [ToolResultDTOs.SelectedFileInfo] {
		guard cfg.includeFiles else { return [] }
		let formatter = PathFormatter(format: display, owner: self)
		let tokens = TokenServices(owner: self)
		let effectiveCodeMapUsage = effectiveMCPCodeMapUsage(cfg.codeMapUsage)
		let collections: SelectionReplyAssembler.SelectionCollections

		switch execContext {
		case .virtual(let ctx):
			let selection = selectionOverride ?? ctx.selection
			collections = await tabSelectionCollections(from: selection, codeMapUsageOverride: effectiveCodeMapUsage)
		case .live:
			if let override = selectionOverride {
				let source = VirtualSelectionSource(
					stored: override,
					fileManager: fileManager,
					codeMapUsage: effectiveCodeMapUsage
				)
				collections = await SelectionReplyAssembler.collect(from: source)
			} else {
				let source = LiveSelectionSource(fileManager: fileManager, codeMapUsage: effectiveCodeMapUsage)
				collections = await SelectionReplyAssembler.collect(from: source)
			}
		}

		let evaluationSelection: StoredSelection?
		switch execContext {
		case .virtual(let ctx):
			evaluationSelection = selectionOverride ?? ctx.selection
		case .live:
			evaluationSelection = selectionOverride
		}
		let entryResultsByFileID: [UUID: PromptEntriesEvaluation.EntryResult]?
		if let evaluationSelection {
			entryResultsByFileID = await evaluateVirtualPromptEntries(
				for: evaluationSelection,
				codeMapUsage: collections.codeMapUsage
			).entryResultsByFileID
		} else {
			entryResultsByFileID = nil
		}
		let reply = await SelectionReplyAssembler.buildSelectedFilesReply(
			collections: collections,
			formatter: formatter,
			tokens: tokens,
			entryResultsByFileID: entryResultsByFileID
		)
		return reply.files
	}

	@MainActor
	func buildTabClipboardContent(
		cfg: PromptContextResolved,
		context: TabScopedContext
	) async -> String {
		// Use the resolved tab-scoped context directly.
		// Run-bound sessions and explicitly bound tabs should export from their bound tab
		// state, not from whichever compose tab happens to be active in the UI.
		let selection = context.selection
		let effectivePromptText = context.promptText

		var selectedFiles: [FileViewModel] = []
		var seen = Set<UUID>()
		for rawPath in StoredSelectionPathNormalization.standardizedPaths(selection.selectedPaths) {
			if let vm = fileManager.findFileByFullPath(rawPath),
			seen.insert(vm.id).inserted {
				selectedFiles.append(vm)
			}
		}

		let fileEntries = fileManager.buildPromptEntries(
			for: selection,
			codeMapUsage: effectiveMCPCodeMapUsage(cfg.codeMapUsage),
			allFileAPIs: promptVM.tokenCountingViewModel.cachedFileAPIs
		)

		let selectedIDs = Set(selectedFiles.map(\.id))
		let (roots, displayOption) = tabRootFoldersAndDisplayOption()
		let combinedTreeAndMap = PromptViewModel.fileTreeContentIfNeeded(
			for: cfg,
			rootFolders: roots,
			selectedFileIDs: selectedIDs,
			filePathDisplay: displayOption,
			onlyIncludeRootsWithSelectedFiles: promptVM.onlyIncludeRootsWithSelectedFiles,
			showCodeMapMarkers: !promptVM.codeMapsGloballyDisabled
		)

		let gitDiff: String?
		switch cfg.gitInclusion {
	case .none:
		gitDiff = nil
	case .selected:
		let selectedPaths = await gitDiffPaths(for: selection)
		gitDiff = await promptVM.gitViewModel.getDiffForAbsolutePaths(selectedPaths, forceRefreshStatus: true)
	case .complete:
		gitDiff = await promptVM.gitViewModel.getDiffUsing(inclusionMode: .all, forceRefreshStatus: true)
	}

		let language = SystemPromptService.predominantLanguage(from: selectedFiles)
		let combinedMeta = promptVM.metaInstructions(
			for: cfg,
			language: language,
			selectedPromptIDsOverride: context.selectedMetaPromptIDs
		)
		let includeMetaBlock = !combinedMeta.isEmpty

		let tabName = context.tabName.isEmpty ? "Tab" : context.tabName
		let metadataBlock = promptVM.mcpMetadataBlockIfNeeded(
			for: cfg,
			tabOverride: (context.tabID, tabName)
		)

		if let fmt = cfg.xmlFormat {
			return await PromptPackagingService.generateDiffClipboardContent(
				instructions: effectivePromptText,
				files: fileEntries,
				format: fmt,
				includeFiles: cfg.includeFiles,
				filePathDisplay: promptVM.filePathDisplayOption,
				allowDiffRewrite: promptVM.allowDiffModelsToRewrite,
				fileTreeContent: combinedTreeAndMap,
				gitDiff: gitDiff,
				includeDatetimeInUserInstructions: promptVM.includeDatetimeInUserInstructions,
				mcpMetadata: metadataBlock,
				promptSectionsOrder: promptVM.promptSectionsOrder,
				disabledPromptSections: promptVM.disabledPromptSections,
				duplicateUserInstructionsAtTop: promptVM.duplicateUserInstructionsAtTop,
				includeMetaPrompts: includeMetaBlock,
				metaInstructions: combinedMeta
			)
		}

		return await PromptPackagingService.generateClipboardContent(
			metaInstructions: combinedMeta,
			userInstructions: cfg.includeUserPrompt ? effectivePromptText : "",
			files: fileEntries,
			fileTreeContent: combinedTreeAndMap,
			gitDiff: gitDiff,
			includeDiffFormatting: false,
			includeSavedPrompts: includeMetaBlock,
			includeFiles: cfg.includeFiles,
			includeUserPrompt: cfg.includeUserPrompt,
			filePathDisplay: promptVM.filePathDisplayOption,
			selectedXMLFormat: promptVM.xmlClipboardFormatPreference,
			includeDatetimeInUserInstructions: promptVM.includeDatetimeInUserInstructions,
			mcpMetadata: metadataBlock,
			promptSectionsOrder: promptVM.promptSectionsOrder,
			disabledPromptSections: promptVM.disabledPromptSections,
			duplicateUserInstructionsAtTop: promptVM.duplicateUserInstructionsAtTop
		)
	}

	@MainActor
	func gitDiffPaths(for selection: StoredSelection) async -> [String] {
		let candidates = Self.gitDiffCandidates(from: selection)
		guard !candidates.isEmpty else { return [] }

		let resolvedFiles = await fileManager.findFiles(atPaths: candidates)
		let resolvedMap = resolvedFiles.mapValues { $0.standardizedFullPath }
		return Self.resolveGitDiffPaths(
			candidates: candidates,
			resolvedMap: resolvedMap,
			normalizeUserInput: { fileManager.normalizeUserInputPath($0) },
			fileExists: { FileManager.default.fileExists(atPath: $0) }
		)
	}
}

extension MCPServerViewModel {
	@MainActor
	func latestTokenBreakdown() -> TokenCountingViewModel.TokenBreakdown {
		promptVM.tokenCountingViewModel.latestTokenBreakdown()
	}
}
