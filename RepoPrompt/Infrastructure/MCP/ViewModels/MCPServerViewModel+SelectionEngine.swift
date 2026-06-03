import Foundation

extension MCPServerViewModel {
	/// Result of building a stored selection
	struct BuildStoredSelectionResult {
		let selection: StoredSelection
		let invalidPaths: [String]
		let codemapUnavailable: [String]
	}

	struct ManageSelectionSetMutationPlan: Equatable {
		let startsFromCurrentSelection: Bool
		let usesFileScopedSliceReplacement: Bool
		let isDestructivePathSet: Bool
	}

	nonisolated static func manageSelectionSetMutationPlan(
		mode: String,
		pathCount: Int,
		sliceCount: Int
	) -> ManageSelectionSetMutationPlan {
		let normalizedMode = mode.lowercased()
		let hasPaths = pathCount > 0
		let hasSlices = sliceCount > 0
		let usesFileScopedSliceReplacement = hasSlices && (!hasPaths || normalizedMode == "slices")
		return ManageSelectionSetMutationPlan(
			startsFromCurrentSelection: usesFileScopedSliceReplacement,
			usesFileScopedSliceReplacement: usesFileScopedSliceReplacement,
			isDestructivePathSet: !usesFileScopedSliceReplacement
		)
	}

	nonisolated static func modeSlicesValidationError(
		selectionPaths: [String],
		sliceInputs: [RepoFileManagerViewModel.SelectionSliceInput],
		sliceParseErrors: [String]
	) -> String? {
		let explicitRequirement = "mode 'slices' requires a non-empty slices array or #L line ranges on paths."
		let slicePathSet = Set(sliceInputs.map { $0.path.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
		let barePaths = selectionPaths
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty && !slicePathSet.contains($0) }
		if !barePaths.isEmpty {
			return "mode 'slices' cannot be used with bare paths; add #L line ranges to paths or use the slices array."
		}
		if sliceInputs.isEmpty {
			return sliceParseErrors.isEmpty ? explicitRequirement : sliceParseErrors.joined(separator: "; ")
		}
		let hasNonEmptyRanges = sliceInputs.contains { !$0.ranges.isEmpty }
		if !hasNonEmptyRanges, !sliceParseErrors.isEmpty {
			return sliceParseErrors.joined(separator: "; ")
		}
		return nil
	}

	nonisolated static func selectionByApplyingResolvedSliceMutation(
		base: StoredSelection,
		resolvedSlices: [String: [LineRange]],
		mode: SliceMutationMode
	) -> (selection: StoredSelection, mutated: Bool) {
		let originalSlices = StoredSelectionPathNormalization.standardizedSlices(base.slices)
		let baseSelectedPaths = StoredSelectionPathNormalization.standardizedPaths(base.selectedPaths)
		let baseCodemapPaths = StoredSelectionPathNormalization.standardizedPaths(base.autoCodemapPaths)
		var virtualSlices = originalSlices
		var selectedPaths = baseSelectedPaths
		var selectedSet = Set(selectedPaths)
		var codemapPaths = baseCodemapPaths

		switch mode {
		case .set:
			virtualSlices.removeAll()
			for (full, ranges) in resolvedSlices {
				let normalized = SliceRangeMath.normalize(ranges)
				if !normalized.isEmpty {
					virtualSlices[full] = normalized
				}
			}

		case .setPaths:
			for (full, ranges) in resolvedSlices {
				let normalized = SliceRangeMath.normalize(ranges)
				if normalized.isEmpty {
					virtualSlices.removeValue(forKey: full)
				} else {
					virtualSlices[full] = normalized
				}
			}

		case .add:
			for (full, ranges) in resolvedSlices {
				let normalizedUpdate = SliceRangeMath.normalize(ranges)
				guard !normalizedUpdate.isEmpty else { continue }

				let baseRanges = virtualSlices[full] ?? []
				let next = SliceRangeMath.coalesce(baseRanges, normalizedUpdate)
				if next.isEmpty {
					virtualSlices.removeValue(forKey: full)
				} else {
					virtualSlices[full] = next
				}
			}

		case .remove:
			for (full, ranges) in resolvedSlices {
				let baseRanges = virtualSlices[full] ?? []
				if baseRanges.isEmpty && ranges.isEmpty {
					virtualSlices.removeValue(forKey: full)
					continue
				}

				let normalizedRemoval = SliceRangeMath.normalize(ranges)
				if baseRanges.isEmpty {
					continue
				}

				let next = normalizedRemoval.isEmpty
					? []
					: SliceRangeMath.subtract(baseRanges, removing: normalizedRemoval)
				if next.isEmpty {
					virtualSlices.removeValue(forKey: full)
				} else {
					virtualSlices[full] = next
				}
			}
		}

		for (full, ranges) in virtualSlices where !ranges.isEmpty {
			if selectedSet.insert(full).inserted {
				selectedPaths.append(full)
			}
		}

		if !selectedPaths.isEmpty || !virtualSlices.isEmpty {
			let selectedStd = Set(selectedPaths)
			codemapPaths.removeAll { selectedStd.contains($0) }
			for (full, ranges) in virtualSlices where !ranges.isEmpty {
				codemapPaths.removeAll { $0 == full }
			}
		}

		let mutated = virtualSlices != originalSlices
			|| selectedPaths != baseSelectedPaths
			|| codemapPaths != baseCodemapPaths
		guard mutated else {
			return (base, false)
		}

		return (StoredSelection(
			selectedPaths: selectedPaths,
			autoCodemapPaths: codemapPaths,
			slices: virtualSlices,
			codemapAutoEnabled: base.codemapAutoEnabled
		), true)
	}

	@MainActor
	func buildStoredSelection(
		from inputs: ManageSelectionInputs,
		mode: String,
		existing: StoredSelection,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> BuildStoredSelectionResult {
		selectionLog("buildStoredSelection mode=\(mode) inputs.paths=\(inputs.paths.count) inputs.slices=\(inputs.sliceInputs.count) existing.selected=\(existing.selectedPaths.count) existing.codemap=\(existing.autoCodemapPaths.count)")

		if mode == "codemap_only", codeMapsGloballyDisabledForMCP {
			return BuildStoredSelectionResult(
				selection: existing,
				invalidPaths: inputs.sliceErrors + [Self.codeMapsGloballyDisabledMCPMessage],
				codemapUnavailable: []
			)
		}

		var invalid: [String] = inputs.sliceErrors
		var codemapUnavailableMessages: [String] = []
		var selectedPaths: [String] = []
		var codemapPaths: [String] = []
		var seenSelectedFull = Set<String>()
		var seenCodemapFull = Set<String>()
		var slicesByPath: [String: [LineRange]] = [:]

		// Add directory-expanded files from paths
		if mode == "codemap_only" {
			// Use codemap-only resolver that filters unsupported files
			let resolution = await resolveCodemapOnlyCandidates(
				paths: inputs.paths,
				rawPaths: inputs.paths,
				expandFolders: true,
				lookupRootScope: lookupRootScope
			)
			invalid.append(contentsOf: resolution.invalidPaths)
			codemapUnavailableMessages.append(contentsOf: resolution.codemapUnavailable)
			for vm in resolution.candidates {
				let fullPath = vm.standardizedFullPath
				if seenCodemapFull.insert(fullPath).inserted {
					codemapPaths.append(fullPath)
				}
			}
		} else {
			// Use regular resolver for non-codemap modes
			let (pathFiles, _, pathInvalid) = await resolveSelectionCandidates(
				paths: inputs.paths,
				rawPaths: inputs.paths,
				expandFolders: true,
				lookupRootScope: lookupRootScope
			)
			invalid.append(contentsOf: pathInvalid)
			for vm in pathFiles {
				let fullPath = vm.standardizedFullPath
				if seenSelectedFull.insert(fullPath).inserted {
					selectedPaths.append(fullPath)
				}
			}
		}

		// Resolve slices only against files (no folder expansion)
		let slicePaths = inputs.sliceInputs.map { $0.path }
		let resolvedSlice = await selectionFindFiles(
			atPaths: slicePaths,
			lookupRootScope: lookupRootScope
		)
		
		for entry in inputs.sliceInputs {
			let trimmed = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			guard let vm = resolvedSlice[trimmed] else {
				invalid.append(trimmed)
				continue
			}
			let fullPath = vm.standardizedFullPath
			if seenSelectedFull.insert(fullPath).inserted {
				selectedPaths.append(fullPath)
			}
			if !entry.ranges.isEmpty {
				if slicesByPath[fullPath] != nil {
					slicesByPath[fullPath]!.append(contentsOf: entry.ranges)
				} else {
					slicesByPath[fullPath] = entry.ranges
				}
			}
		}

		if !slicesByPath.isEmpty {
			var normalizedSlices: [String: [LineRange]] = [:]
			for (path, ranges) in slicesByPath {
				let normalized = SliceRangeMath.normalize(ranges)
				if !normalized.isEmpty {
					normalizedSlices[path] = normalized
				}
			}
			slicesByPath = normalizedSlices
		}

		// Remove selected files from codemap paths for clean transition
		var finalCodemapPaths = existing.autoCodemapPaths
		if !selectedPaths.isEmpty {
			let selectedSet = Set(selectedPaths)
			finalCodemapPaths.removeAll { selectedSet.contains($0) }
		}

		let autoEnabled = (mode == "codemap_only") ? false : existing.codemapAutoEnabled
		let initialCodemapPaths: [String]
		if mode == "codemap_only" {
			initialCodemapPaths = codemapPaths
		} else if autoEnabled {
			initialCodemapPaths = []
		} else {
			initialCodemapPaths = finalCodemapPaths
		}
		var selection = StoredSelection(
			selectedPaths: selectedPaths,
			autoCodemapPaths: initialCodemapPaths,
			slices: slicesByPath,
			codemapAutoEnabled: autoEnabled
		)
		if selection.codemapAutoEnabled {
			selection = await recomputeAutoCodemapsForVirtualSelection(
				selection,
				lookupRootScope: lookupRootScope
			)
		}
	
		selectionLog("buildStoredSelection result: selected=\(selection.selectedPaths.count) codemap=\(selection.autoCodemapPaths.count) slices=\(selection.slices.count) invalid=\(invalid.count) codemapUnavailable=\(codemapUnavailableMessages.count)")
		return BuildStoredSelectionResult(
			selection: selection,
			invalidPaths: invalid,
			codemapUnavailable: codemapUnavailableMessages
		)
	}

	@MainActor
	func buildPreviewSelectionReply(
		paths: [String],
		sliceInputs: [RepoFileManagerViewModel.SelectionSliceInput],
		includeBlocks: Bool,
		display: FilePathDisplay,
		mode: String,
		baseSelection: StoredSelection = StoredSelection(),
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> ToolResultDTOs.SelectionReply {
		var invalidPaths: [String] = []
		let selection: StoredSelection

		if mode == "codemap_only", codeMapsGloballyDisabledForMCP {
			invalidPaths.append(Self.codeMapsGloballyDisabledMCPMessage)
			selection = StoredSelection()
		} else if mode == "codemap_only" {
			// Use codemap-only resolver that filters unsupported files
			let resolution = await resolveCodemapOnlyCandidates(
				paths: paths,
				rawPaths: paths,
				expandFolders: true,
				lookupRootScope: lookupRootScope
			)
			invalidPaths.append(contentsOf: resolution.invalidPaths)
			// Include codemapUnavailable messages in invalidPaths for preview display
			invalidPaths.append(contentsOf: resolution.codemapUnavailable)

			var codemapPaths: [String] = []
			var seenCodemap = Set<String>()
			for vm in resolution.candidates {
				let std = vm.standardizedFullPath
				if seenCodemap.insert(std).inserted {
					codemapPaths.append(std)
				}
			}
			selection = StoredSelection(
				selectedPaths: [],
				autoCodemapPaths: codemapPaths,
				slices: [:],
				codemapAutoEnabled: false
			)
		} else {
			let inputs = ManageSelectionInputs(
				paths: paths,
				sliceInputs: sliceInputs,
				sliceErrors: [],
				hadExplicitSliceSpec: !sliceInputs.isEmpty
			)
			let setPlan = Self.manageSelectionSetMutationPlan(
				mode: mode,
				pathCount: paths.count,
				sliceCount: sliceInputs.count
			)

			if setPlan.usesFileScopedSliceReplacement {
				var currentSelection = baseSelection
				if mode != "slices", !paths.isEmpty {
					let addResult = await addStoredSelectionPaths(
						existing: currentSelection,
						paths: paths,
						rawPaths: paths,
						mode: "full",
						lookupRootScope: lookupRootScope
					)
					currentSelection = addResult.selection
					invalidPaths.append(contentsOf: addResult.invalidPaths)
					invalidPaths.append(contentsOf: addResult.codemapUnavailable)
				}

				let sliceResult = await computeSelectionSlicesVirtual(
					base: currentSelection,
					entries: sliceInputs,
					mode: .setPaths,
					lookupRootScope: lookupRootScope
				)
				selection = sliceResult.selection
				invalidPaths.append(contentsOf: sliceResult.result.invalidPaths)
			} else {
				let buildResult = await buildStoredSelection(
					from: inputs,
					mode: mode,
					existing: StoredSelection(),
					lookupRootScope: lookupRootScope
				)
				selection = buildResult.selection
				invalidPaths.append(contentsOf: buildResult.invalidPaths)
			}
		}

		let source = VirtualSelectionSource(
			stored: selection,
			fileManager: fileManager,
			codeMapUsage: effectiveMCPCodeMapUsage(promptVM.codeMapUsage)
		)
		let collections = await SelectionReplyAssembler.collect(from: source)
		let formatter = PathFormatter(format: display, owner: self)
		let tokens = TokenServices(owner: self)
		var out = await SelectionReplyAssembler.buildSelectionReply(
			collections: collections,
			includeBlocks: includeBlocks,
			display: display,
			formatter: formatter,
			tokens: tokens,
			status: "preview",
			extraInvalid: invalidPaths
		)
		
		// Inject minimal codeStructure.unmappedPaths to report pending codemaps
		if out.codeStructure == nil {
			if let minimal = await self.buildUnmappedOnlyCodeStructure(collections: collections, display: display) {
				out = ToolResultDTOs.SelectionReply(
					files: out.files,
					totalTokens: out.totalTokens,
					status: out.status,
					invalidPaths: out.invalidPaths,
					blocks: out.blocks,
					codeStructure: minimal,
					fileSlices: out.fileSlices,
					codemapAutoEnabled: out.codemapAutoEnabled,
					summary: out.summary,
					codeMapUsage: out.codeMapUsage,
					// Preserve user preset state indicators
					userCopyCodeMapUsage: out.userCopyCodeMapUsage,
					userChatCodeMapUsage: out.userChatCodeMapUsage,
					userCopyTokens: out.userCopyTokens,
					userChatTokens: out.userChatTokens,
					normalizedCodeMapUsage: out.normalizedCodeMapUsage,
					tokenStats: out.tokenStats
				)
			}
		}

		return out
	}

	@MainActor
	private func resolveSelectionCandidates(
		paths: [String],
		rawPaths: [String],
		expandFolders: Bool,
		allowEmptyFolderExpansion: Bool = false,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> (candidates: [FileViewModel], resolvedMap: [String: String], invalid: [String]) {
		var rawLookup: [String: String] = [:]
		for raw in rawPaths {
			let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			if rawLookup[trimmed] == nil {
				rawLookup[trimmed] = raw
			}
		}

		var ordered: [String] = []
		var seenInputs = Set<String>()
		for path in paths {
			let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			if seenInputs.insert(trimmed).inserted {
				ordered.append(trimmed)
			}
		}

		var invalid: [String] = []
		var preflightOrdered: [String] = []
		for key in ordered {
			if let issue = fileManager.exactPathResolutionIssue(
				for: key,
				kind: expandFolders ? .either : .file,
				rootScope: lookupRootScope
			) {
				invalid.append(PathResolutionIssueRenderer.message(for: issue))
				continue
			}
			preflightOrdered.append(key)
		}
		let resolved = await selectionFindFiles(
			atPaths: preflightOrdered,
			lookupRootScope: lookupRootScope
		)
		var resolvedMap: [String: String] = [:]
		var candidates: [FileViewModel] = []
		var seenFull = Set<String>()

		for key in preflightOrdered {
			let raw = rawLookup[key] ?? key
			if let vm = resolved[key] {
				if seenFull.insert(vm.standardizedFullPath).inserted {
					candidates.append(vm)
				}
				if resolvedMap[raw] == nil {
					resolvedMap[raw] = await prefixedRelativePath(for: vm)
				}
				continue
			}

			if expandFolders {
				// Use centralized alias-aware directory resolver
				let folderResolution = await self.resolveFilesForFolderInput(key, lookupRootScope: lookupRootScope)
				if folderResolution.handled {
					if folderResolution.files.isEmpty {
						if allowEmptyFolderExpansion {
							if resolvedMap[raw] == nil {
								resolvedMap[raw] = folderResolution.displayPath ?? key
							}
						} else if let issue = folderResolution.issue {
							invalid.append(PathResolutionIssueRenderer.message(for: issue))
						} else {
							invalid.append(raw)
						}
					} else {
						for file in folderResolution.files {
							if seenFull.insert(file.standardizedFullPath).inserted {
								candidates.append(file)
							}
						}
						if resolvedMap[raw] == nil {
							resolvedMap[raw] = folderResolution.displayPath ?? key
						}
					}
					continue
				}
				if let issue = folderResolution.issue {
					invalid.append(PathResolutionIssueRenderer.message(for: issue))
					continue
				}
			}

			invalid.append(raw)
		}

		return (candidates, resolvedMap, invalid)
	}

	/// Result type for codemap-only resolution that separates invalid paths from unsupported files
	struct CodemapOnlyResolutionResult {
		/// Files that support codemap extraction
		let candidates: [FileViewModel]
		/// Mapping of raw input paths to resolved relative paths
		let resolvedMap: [String: String]
		/// Paths that couldn't be resolved at all (don't exist)
		let invalidPaths: [String]
		/// Messages about files that exist but don't support codemaps
		let codemapUnavailable: [String]
	}

	/// Resolves paths for codemap_only mode, filtering out files that don't support codemaps.
	/// Unlike `resolveSelectionCandidates`, this also tracks files that exist but lack codemap support.
	@MainActor
	func resolveCodemapOnlyCandidates(
		paths: [String],
		rawPaths: [String],
		expandFolders: Bool,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> CodemapOnlyResolutionResult {
		var rawLookup: [String: String] = [:]
		for raw in rawPaths {
			let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			if rawLookup[trimmed] == nil {
				rawLookup[trimmed] = raw
			}
		}

		var ordered: [String] = []
		var seenInputs = Set<String>()
		for path in paths {
			let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			if seenInputs.insert(trimmed).inserted {
				ordered.append(trimmed)
			}
		}

		var invalidPaths: [String] = []
		var preflightOrdered: [String] = []
		for key in ordered {
			if let issue = fileManager.exactPathResolutionIssue(
				for: key,
				kind: expandFolders ? .either : .file,
				rootScope: lookupRootScope
			) {
				invalidPaths.append(PathResolutionIssueRenderer.message(for: issue))
				continue
			}
			preflightOrdered.append(key)
		}
		let resolved = await selectionFindFiles(
			atPaths: preflightOrdered,
			lookupRootScope: lookupRootScope
		)
		var codemapUnavailable: [String] = []
		var resolvedMap: [String: String] = [:]
		var candidates: [FileViewModel] = []
		var seenFull = Set<String>()

		for key in preflightOrdered {
			let raw = rawLookup[key] ?? key
			if let vm = resolved[key] {
				// Single file resolved - check if it supports codemap
				if vm.supportsCodeMap {
					if seenFull.insert(vm.standardizedFullPath).inserted {
						candidates.append(vm)
					}
					if resolvedMap[raw] == nil {
						resolvedMap[raw] = await prefixedRelativePath(for: vm)
					}
				} else {
					// File exists but doesn't support codemap
					let displayPath = await prefixedRelativePath(for: vm)
					codemapUnavailable.append("codemap unavailable: \(displayPath)")
					if resolvedMap[raw] == nil {
						resolvedMap[raw] = await prefixedRelativePath(for: vm)
					}
				}
				continue
			}

			if expandFolders {
				// Use centralized alias-aware directory resolver
				let folderResolution = await self.resolveFilesForFolderInput(key, lookupRootScope: lookupRootScope)
				if folderResolution.handled {
					if folderResolution.files.isEmpty {
						if let issue = folderResolution.issue {
							invalidPaths.append(PathResolutionIssueRenderer.message(for: issue))
						} else {
							invalidPaths.append(raw)
						}
					} else {
						var supportedCount = 0
						var unsupportedCount = 0
						for file in folderResolution.files {
							if file.supportsCodeMap {
								if seenFull.insert(file.standardizedFullPath).inserted {
									candidates.append(file)
								}
								supportedCount += 1
							} else {
								unsupportedCount += 1
							}
						}
						if unsupportedCount > 0 && supportedCount == 0 {
							codemapUnavailable.append("codemap unavailable: \(raw) (no supported files)")
						} else if unsupportedCount > 0 {
							codemapUnavailable.append("codemap unavailable: \(unsupportedCount) file(s) in \(raw) skipped (unsupported)")
						}
						if resolvedMap[raw] == nil {
							resolvedMap[raw] = folderResolution.displayPath ?? key
						}
					}
					continue
				}
				if let issue = folderResolution.issue {
					invalidPaths.append(PathResolutionIssueRenderer.message(for: issue))
					continue
				}
			}

			invalidPaths.append(raw)
		}

		return CodemapOnlyResolutionResult(
			candidates: candidates,
			resolvedMap: resolvedMap,
			invalidPaths: invalidPaths,
			codemapUnavailable: codemapUnavailable
		)
	}

	// MARK: - Folder-aware path validation
	
	/// Validates paths for manage_selection set operations, supporting both files and folders.
	/// Returns invalid paths that could not be resolved as either files or folders.
	@MainActor
	func validateManageSelectionSetInputs(
		paths: [String],
		rawPaths: [String],
		expandFolders: Bool = true,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> [String] {
		let (_, _, invalid) = await resolveSelectionCandidates(
			paths: paths,
			rawPaths: rawPaths,
			expandFolders: expandFolders,
			lookupRootScope: lookupRootScope
		)
		return invalid
	}

	// MARK: - Virtual auto-codemap inference
	@MainActor
	func recomputeAutoCodemapsForVirtualSelection(
		_ base: StoredSelection,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> StoredSelection {
			guard base.codemapAutoEnabled else { return base }
			guard !codeMapsGloballyDisabledForMCP else {
				return StoredSelection(
					selectedPaths: base.selectedPaths,
					autoCodemapPaths: [],
					slices: base.slices,
					codemapAutoEnabled: base.codemapAutoEnabled
				)
			}
	
			let resolved = await selectionFindFiles(
				atPaths: base.selectedPaths,
				lookupRootScope: lookupRootScope
			)
			var selectedFiles: [FileViewModel] = []
			for path in base.selectedPaths {
				if let vm = resolved[path] {
					selectedFiles.append(vm)
				}
			}
			guard !selectedFiles.isEmpty else {
				return StoredSelection(
					selectedPaths: base.selectedPaths,
					autoCodemapPaths: [],
					slices: base.slices,
					codemapAutoEnabled: base.codemapAutoEnabled
				)
			}
	
			let cachedAPIs = fileManager.cachedFileAPIs()
			guard !cachedAPIs.isEmpty else {
				return StoredSelection(
					selectedPaths: base.selectedPaths,
					autoCodemapPaths: [],
					slices: base.slices,
					codemapAutoEnabled: base.codemapAutoEnabled
				)
			}
	
			let referencedPaths = CodeMapExtractor.resolveReferencedFilePaths(
				from: selectedFiles,
				among: cachedAPIs
			)
	
			return StoredSelection(
				selectedPaths: base.selectedPaths,
				autoCodemapPaths: referencedPaths,
				slices: base.slices,
				codemapAutoEnabled: base.codemapAutoEnabled
			)
		}
	
	/// Result of adding paths to stored selection
	struct AddStoredSelectionResult {
		let selection: StoredSelection
		let invalidPaths: [String]
		let resolvedMap: [String: String]
		let mutated: Bool
		let codemapUnavailable: [String]
	}

	@MainActor
	func addPrimaryGitDiffArtifactsToSelection(
		existing: StoredSelection,
		paths: [String],
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> (selection: StoredSelection, autoSelectedPaths: [String]) {
		let orderedPaths = paths
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.reduce(into: [String]()) { result, item in
				if !result.contains(item) { result.append(item) }
			}
		guard !orderedPaths.isEmpty else {
			return (existing, [])
		}
		let previouslySelected = Set(existing.selectedPaths)
		let result = await addStoredSelectionPaths(
			existing: existing,
			paths: orderedPaths,
			rawPaths: orderedPaths,
			mode: "full",
			lookupRootScope: lookupRootScope
		)
		let resolvedFiles = await selectionFindFiles(
			atPaths: orderedPaths,
			lookupRootScope: lookupRootScope
		)
		let autoSelectedPaths = orderedPaths.filter { rawPath in
			guard let file = resolvedFiles[rawPath] else { return false }
			let fullPath = file.standardizedFullPath
			return !previouslySelected.contains(fullPath)
				&& result.selection.selectedPaths.contains(fullPath)
		}
		return (result.selection, autoSelectedPaths)
	}
	
	func addStoredSelectionPaths(
		existing: StoredSelection,
		paths: [String],
		rawPaths: [String],
		mode: String,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> AddStoredSelectionResult {
		selectionLog("addStoredSelectionPaths mode=\(mode) existing.autoEnabled=\(existing.codemapAutoEnabled) paths=\(paths.count) existing.selected=\(existing.selectedPaths.count) existing.codemap=\(existing.autoCodemapPaths.count) existing.slices=\(existing.slices.count)")

		let codemapOnly = (mode == "codemap_only")
		if codemapOnly, codeMapsGloballyDisabledForMCP {
			return AddStoredSelectionResult(
				selection: existing,
				invalidPaths: [Self.codeMapsGloballyDisabledMCPMessage],
				resolvedMap: [:],
				mutated: false,
				codemapUnavailable: []
			)
		}
		var invalid: [String] = []
		var codemapUnavailableMessages: [String] = []
		var resolvedMap: [String: String] = [:]
		var files: [FileViewModel] = []

		if codemapOnly {
			// Use codemap-only resolver that filters unsupported files
			let resolution = await resolveCodemapOnlyCandidates(
				paths: paths,
				rawPaths: rawPaths,
				expandFolders: true,
				lookupRootScope: lookupRootScope
			)
			invalid = resolution.invalidPaths
			codemapUnavailableMessages = resolution.codemapUnavailable
			resolvedMap = resolution.resolvedMap
			files = resolution.candidates
		} else {
			let (resolvedFiles, resolvedFromHelper, helperInvalid) = await resolveSelectionCandidates(
				paths: paths,
				rawPaths: rawPaths,
				expandFolders: true,
				lookupRootScope: lookupRootScope
			)
			invalid = helperInvalid
			resolvedMap = resolvedFromHelper
			files = resolvedFiles
		}

		var selectedPaths = existing.selectedPaths
		var codemapPaths = existing.autoCodemapPaths
		var slices = existing.slices
		var selectedStd = Set(selectedPaths)
		var codemapStd = Set(codemapPaths)
		var mutated = false

		if codemapOnly {
			// Only add files that support codemaps (already filtered by resolver)
			for vm in files {
				let std = vm.standardizedFullPath
				if selectedStd.contains(std) {
					let before = selectedPaths.count
					selectedPaths.removeAll { $0 == std }
					if selectedPaths.count != before {
						selectedStd.remove(std)
						mutated = true
					}
				}
				if !codemapStd.contains(std) {
					codemapPaths.append(std)
					codemapStd.insert(std)
					mutated = true
				}
				if removeSliceEntries(for: vm, in: &slices) {
					mutated = true
				}
			}

			let newSelection = StoredSelection(
				selectedPaths: selectedPaths,
				autoCodemapPaths: codemapPaths,
				slices: slices,
				codemapAutoEnabled: false
			)
			selectionLog("addStoredSelectionPaths codemap_only result: autoEnabled=\(newSelection.codemapAutoEnabled) selected=\(newSelection.selectedPaths.count) codemap=\(newSelection.autoCodemapPaths.count) slices=\(newSelection.slices.count) mutated=\(mutated) invalid=\(invalid.count) codemapUnavailable=\(codemapUnavailableMessages.count)")
			return AddStoredSelectionResult(
				selection: newSelection,
				invalidPaths: invalid,
				resolvedMap: resolvedMap,
				mutated: mutated,
				codemapUnavailable: codemapUnavailableMessages
			)
		}

		for vm in files {
			let std = vm.standardizedFullPath
			if !selectedStd.contains(std) {
				selectedPaths.append(std)
				selectedStd.insert(std)
				mutated = true
			}
			if codemapStd.contains(std) {
				let before = codemapPaths.count
				codemapPaths.removeAll { $0 == std }
				if codemapPaths.count != before {
					codemapStd.remove(std)
					mutated = true
				}
			}
		}
	
		var newSelection = StoredSelection(
			selectedPaths: selectedPaths,
			autoCodemapPaths: codemapPaths,
			slices: slices,
			codemapAutoEnabled: existing.codemapAutoEnabled
		)
	// DO NOT recompute when manual
		if newSelection.codemapAutoEnabled {
			newSelection = await recomputeAutoCodemapsForVirtualSelection(
				newSelection,
				lookupRootScope: lookupRootScope
			)
		}
	
		selectionLog("addStoredSelectionPaths result: autoEnabled=\(newSelection.codemapAutoEnabled) selected=\(newSelection.selectedPaths.count) codemap=\(newSelection.autoCodemapPaths.count) slices=\(newSelection.slices.count) mutated=\(mutated) invalid=\(invalid.count)")
		return AddStoredSelectionResult(
			selection: newSelection,
			invalidPaths: invalid,
			resolvedMap: resolvedMap,
			mutated: mutated,
			codemapUnavailable: codemapUnavailableMessages
		)
	}
		
	@MainActor
	func removeStoredSelectionPaths(
		existing: StoredSelection,
		paths: [String],
		rawPaths: [String],
		mode: String = "full",
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> (StoredSelection, [String], [String: String], Bool) {
		selectionLog("removeStoredSelectionPaths mode=\(mode) paths=\(paths.count) existing.selected=\(existing.selectedPaths.count) existing.codemap=\(existing.autoCodemapPaths.count) existing.slices=\(existing.slices.count)")
		// Use allowEmptyFolderExpansion for remove - empty folder expansion is a no-op, not an error
		let (files, resolvedFromHelper, helperInvalid) = await resolveSelectionCandidates(
			paths: paths,
			rawPaths: rawPaths,
			expandFolders: true,
			allowEmptyFolderExpansion: true,
			lookupRootScope: lookupRootScope
		)

		let invalid = helperInvalid
		let resolvedMap = resolvedFromHelper
		var selectedPaths = existing.selectedPaths
		var codemapPaths = existing.autoCodemapPaths
		var slices = existing.slices
		var selectedStd = Set(selectedPaths)
		var codemapStd = Set(codemapPaths)
		var mutated = false
		let codemapOnly = (mode == "codemap_only")
	
		for vm in files {
			let std = vm.standardizedFullPath
			if !codemapOnly && selectedStd.contains(std) {
				let before = selectedPaths.count
				selectedPaths.removeAll { $0 == std }
				if selectedPaths.count != before {
					selectedStd.remove(std)
					mutated = true
				}
			}
			if codemapStd.contains(std) {
				let before = codemapPaths.count
				codemapPaths.removeAll { $0 == std }
				if codemapPaths.count != before {
					codemapStd.remove(std)
					mutated = true
				}
			}
			if !codemapOnly {
				if removeSliceEntries(for: vm, in: &slices) {
					mutated = true
				}
			}
		}

		// For codemap_only mode, disable auto inference (manual override)
		// This matches the behavior of codemap_only add and ensures folder removals persist
		let disableAutoForCodemapOnly = codemapOnly && mutated
		
		var newSelection = StoredSelection(
			selectedPaths: selectedPaths,
			autoCodemapPaths: codemapPaths,
			slices: slices,
			codemapAutoEnabled: disableAutoForCodemapOnly ? false : existing.codemapAutoEnabled
		)
		// DO NOT recompute when manual or when codemap_only mode made changes
		if newSelection.codemapAutoEnabled && !disableAutoForCodemapOnly {
			newSelection = await recomputeAutoCodemapsForVirtualSelection(
				newSelection,
				lookupRootScope: lookupRootScope
			)
		}
	
		selectionLog("removeStoredSelectionPaths result: selected=\(newSelection.selectedPaths.count) codemap=\(newSelection.autoCodemapPaths.count) slices=\(newSelection.slices.count) mutated=\(mutated) invalid=\(invalid.count) codemapAutoEnabled=\(newSelection.codemapAutoEnabled)")
		return (newSelection, invalid, resolvedMap, mutated)
	}
		
	@MainActor
	func promoteStoredSelectionPaths(
		existing: StoredSelection,
		paths: [String],
		rawPaths: [String],
		strict _: Bool,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> (StoredSelection, [String], Bool) {
		selectionLog("promoteStoredSelectionPaths paths=\(paths.count) existing.selected=\(existing.selectedPaths.count) existing.codemap=\(existing.autoCodemapPaths.count) existing.slices=\(existing.slices.count)")
		let (files, _, helperInvalid) = await resolveSelectionCandidates(
			paths: paths,
			rawPaths: rawPaths,
			expandFolders: false,
			lookupRootScope: lookupRootScope
		)

		let invalid = helperInvalid
		var selectedPaths = existing.selectedPaths
		var codemapPaths = existing.autoCodemapPaths
		var slices = existing.slices
		var selectedStd = Set(selectedPaths)
		var codemapStd = Set(codemapPaths)
		var mutated = false

		for vm in files {
			let std = vm.standardizedFullPath
			if !selectedStd.contains(std) {
				selectedPaths.append(std)
				selectedStd.insert(std)
				mutated = true
			}
			if codemapStd.contains(std) {
				let before = codemapPaths.count
				codemapPaths.removeAll { $0 == std }
				if codemapPaths.count != before {
					codemapStd.remove(std)
					mutated = true
				}
			}
			if removeSliceEntries(for: vm, in: &slices) {
				mutated = true
			}
		}

		let newSelection = StoredSelection(
			selectedPaths: selectedPaths,
			autoCodemapPaths: codemapPaths,
			slices: slices,
			codemapAutoEnabled: false
		)
	
		selectionLog("promoteStoredSelectionPaths result: selected=\(newSelection.selectedPaths.count) codemap=\(newSelection.autoCodemapPaths.count) slices=\(newSelection.slices.count) mutated=\(mutated) invalid=\(invalid.count)")
		return (newSelection, invalid, mutated)
	}
		
	/// Result of demoting paths to codemap mode
	struct DemoteStoredSelectionResult {
		let selection: StoredSelection
		let invalidPaths: [String]
		let codemapUnavailable: [String]
		let mutated: Bool
	}

	@MainActor
	func demoteStoredSelectionPaths(
		existing: StoredSelection,
		paths: [String],
		rawPaths: [String],
		strict _: Bool,
		lookupRootScope: RepoFileManagerViewModel.LookupRootScope = .visibleWorkspace
	) async -> DemoteStoredSelectionResult {
		selectionLog("demoteStoredSelectionPaths paths=\(paths.count) existing.selected=\(existing.selectedPaths.count) existing.codemap=\(existing.autoCodemapPaths.count) existing.slices=\(existing.slices.count)")
		if codeMapsGloballyDisabledForMCP {
			return DemoteStoredSelectionResult(
				selection: existing,
				invalidPaths: [Self.codeMapsGloballyDisabledMCPMessage],
				codemapUnavailable: [],
				mutated: false
			)
		}
		let (files, _, helperInvalid) = await resolveSelectionCandidates(
			paths: paths,
			rawPaths: rawPaths,
			expandFolders: false,
			lookupRootScope: lookupRootScope
		)

		let invalid = helperInvalid
		var codemapUnavailableMessages: [String] = []
		var selectedPaths = existing.selectedPaths
		var codemapPaths = existing.autoCodemapPaths
		var slices = existing.slices
		var selectedStd = Set(selectedPaths)
		var codemapStd = Set(codemapPaths)
		var mutated = false

		// Demote only files that support codemaps
		for vm in files {
			let std = vm.standardizedFullPath
			// Only demote files that support codemap
			if vm.supportsCodeMap {
				// Remove from selected paths
				if selectedStd.contains(std) {
					let before = selectedPaths.count
					selectedPaths.removeAll { $0 == std }
					if selectedPaths.count != before {
						selectedStd.remove(std)
						mutated = true
					}
				}
				// Remove any slices for this file
				if removeSliceEntries(for: vm, in: &slices) {
					mutated = true
				}
				// Add to codemap paths
				if !codemapStd.contains(std) {
					codemapPaths.append(std)
					codemapStd.insert(std)
					mutated = true
				}
			} else {
				// File doesn't support codemap - keep it in its current state
				// and report the unavailability (don't remove from selection)
				let displayPath = await prefixedRelativePath(for: vm)
				codemapUnavailableMessages.append("codemap unavailable: \(displayPath)")
			}
		}

		let newSelection = StoredSelection(
			selectedPaths: selectedPaths,
			autoCodemapPaths: codemapPaths,
			slices: slices,
			codemapAutoEnabled: false
		)
	
		selectionLog("demoteStoredSelectionPaths result: selected=\(newSelection.selectedPaths.count) codemap=\(newSelection.autoCodemapPaths.count) slices=\(newSelection.slices.count) mutated=\(mutated) invalid=\(invalid.count) codemapUnavailable=\(codemapUnavailableMessages.count)")
		return DemoteStoredSelectionResult(
			selection: newSelection,
			invalidPaths: invalid,
			codemapUnavailable: codemapUnavailableMessages,
			mutated: mutated
		)
	}
	
	// MARK: - Slice Removal Helper
	
	/// Removes slice entries for a given file by trying multiple normalized key variants.
	/// Returns true if any slice was removed.
	@MainActor
	private func removeSliceEntries(for file: FileViewModel, in slices: inout [String: [LineRange]]) -> Bool {
		var mutated = false
		let std = file.standardizedFullPath
		
		// Direct key variants
		if slices.removeValue(forKey: std) != nil { mutated = true }
		if slices.removeValue(forKey: file.fullPath) != nil { mutated = true }
		if slices.removeValue(forKey: file.relativePath) != nil { mutated = true }
		
		// Normalize only the remaining keys that resolve to this file, then remove them.
		if !slices.isEmpty {
			let matchingKeys = slices.keys.filter { StoredSelectionPathNormalization.standardizedPath($0) == std }
			if !matchingKeys.isEmpty {
				for key in matchingKeys {
					slices.removeValue(forKey: key)
				}
				mutated = true
			}
		}
		return mutated
	}
	}
