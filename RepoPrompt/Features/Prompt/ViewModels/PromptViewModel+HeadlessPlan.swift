import Foundation

// MARK: - Headless Mode

/// Which system prompt flavor to use for headless generation
enum HeadlessMode {
	case plan   // Uses architect/planning system prompt
	case chat   // Uses chat system prompt
	case review // Uses review system prompt with git diff
}

// MARK: - Headless Context Snapshot

/// A frozen snapshot of tab state for headless generation.
/// Used when running plan/chat via AIQueriesService without activating the tab.
struct HeadlessContextSnapshot {
	/// The compose tab this snapshot came from
	let tabID: UUID
	
	/// Effective prompt text for the request
	let promptText: String
	
	/// Frozen selection from ComposeTabState.selection
	let selection: StoredSelection
}

// MARK: - Headless AIMessage Builders

extension PromptViewModel {
	
	/// Builds an AIMessage for a headless request from a frozen snapshot.
	/// Does NOT read from live tab state - uses only the snapshot data.
	///
	/// Headless specifics:
	/// - File tree: auto mode
	/// - Codemaps: auto mode
	/// - Git diff: included only for review
	/// - Warning: NOT included
	/// - System prompt depends on mode (plan uses architect, chat uses default chat, review uses stored review prompt)
	@MainActor
	func buildHeadlessAIMessage(
		from snapshot: HeadlessContextSnapshot,
		model: AIModel,
		mode: HeadlessMode = .plan,
		gitScopeOverride: GitInclusion? = nil,
		gitBaseOverride: String? = nil
	) async -> AIMessage {
		// 1. Build file entries from snapshot selection (non-mutating)
		let fileEntries = fileManager.buildPromptEntries(
			for: snapshot.selection,
			codeMapUsage: .auto,  // Plan always uses auto
			allFileAPIs: tokenCountingViewModel.cachedFileAPIs
		)
		let (diffEntries, codeEntries) = PromptPackagingService.partitionPromptEntriesForGitDiff(fileEntries)
		
		// 2. Generate file contents
		let fileBlocks = await PromptPackagingService.generateFileContents(
			codeEntries,
			filePathDisplay: filePathDisplayOption
		)
		
		// 3. Build file tree (auto mode for plan)
		let selectedIDs = fileManager.computeSelectedIDs(from: snapshot.selection)
		let fileTree = CodeMapExtractor.generateFileTree(using: FileTreeSelectionContext(
			rootFolders: fileManager.visibleRootFolders,
			selectedFileIDs: selectedIDs,
			option: .auto,
			filePathDisplay: filePathDisplayOption,
			onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
			includeLegend: true,
			isMCPContext: false
		))
		
		// 4. System prompt based on mode
		let systemPrompt: String = {
			switch mode {
			case .plan:
				let custom = customPlanningPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
				return custom.isEmpty ? architectPrompt.content : custom
			case .chat:
				return getChatPrompt()
			case .review:
				let reviewPromptID = ChatPreset.BuiltIn.review.storedPromptIds?.first
				if let reviewPromptID,
					let stored = storedPrompts.first(where: { $0.id == reviewPromptID }) {
					var prompt = stored.content
					prompt += "\n\nAlways include a chatname in your response that describes the current chat. Put it on it's own line for easy parsing, and format it like so <chatName=\\\"Unique name describing user request\\\"/>"
					prompt += "\n\nProvide your response in clean, well-formatted markdown. Use proper headings, lists, code blocks, and other markdown elements to make your response easy to read and understand."
					return prompt
				}
				return getChatPrompt()
			}
		}()
		
		// 5. Single-user conversation
		let conversation = [ConversationEntry(role: .user, content: snapshot.promptText)]
		
		let gitDiff: String? = await PromptPackagingService.resolveGitDiff(
			fromDiffEntries: diffEntries
		) {
			guard mode == .review else { return nil }
			let effectiveScope = gitScopeOverride ?? .selected
			switch effectiveScope {
			case .none:
				return nil
			case .selected:
				return await gitViewModel.getDiffForAbsolutePaths(snapshot.selection.selectedPaths, vs: gitBaseOverride, forceRefreshStatus: true)
			case .complete:
				return await gitViewModel.getDiffUsing(inclusionMode: .all, vs: gitBaseOverride, forceRefreshStatus: true)
			}
		}

		// 6. Assemble AIMessage (no warning, no meta prompts)
		return PromptPackagingService.buildAIMessage(
			systemPrompt: systemPrompt,
			metaInstructions: [],
			fileTree: fileTree,
			fileContents: fileBlocks,
			gitDiff: gitDiff,
			conversation: conversation,
			addWarning: false,  // Headless modes → no XML warning
			temperature: setModelTemperature ? modelTemperature : nil,
			promptSectionsOrder: promptSectionsOrder,
			disabledPromptSections: disabledPromptSections,
			duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop
		)
	}
	
}
