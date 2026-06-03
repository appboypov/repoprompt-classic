import Foundation

extension MCPServerViewModel {
	nonisolated static func makeTokenStats(
		filesTokens: Int,
		filesContentTokens: Int? = nil,
		codemapsTokens: Int? = nil,
		breakdown: TokenComponentBreakdown
	) -> ToolResultDTOs.TokenStats {
		let promptTokens = breakdown.promptDisplay
		let metaTokens = breakdown.instructions
		let treeTokens = breakdown.fileTree
		let gitTokens = breakdown.gitDiff
		let otherTokens = breakdown.other
		return .init(
			total: filesTokens + breakdown.totalNonFile,
			files: filesTokens,
			prompt: promptTokens > 0 ? promptTokens : nil,
			fileTree: treeTokens > 0 ? treeTokens : nil,
			meta: metaTokens > 0 ? metaTokens : nil,
			git: gitTokens > 0 ? gitTokens : nil,
			other: otherTokens > 0 ? otherTokens : nil,
			filesContent: filesContentTokens,
			codemaps: codemapsTokens
		)
	}

	/// Computes workspace token stats (total breakdown including prompt, file tree, meta, git, etc.)
	/// This is the shared helper used by both `workspace_context` and `manage_selection`
	/// to ensure consistent token reporting.
	///
	/// For virtual contexts (bound tabs), we compute totals from components since
	/// TokenCalcService reflects the active tab, not necessarily the bound tab.
	///
	/// - Parameters:
	///   - filesTokens: Token count from the current selection (tab-scoped, combined full+slices+codemaps)
	///   - filesContentTokens: Token count from full files and slices only (excludes codemaps)
	///   - codemapsTokens: Token count from codemaps only
	///   - promptTokensOverride: Override for prompt tokens (for virtual contexts)
	///   - fileTreeTokensOverride: Override for file tree tokens when freshly computed
	///   - metaTokensOverride: Override for stored prompts tokens (for virtual contexts)
	///   - gitTokensOverride: Override for git tokens (for virtual contexts)
	///   - otherTokensOverride: Override for other tokens (XML formatting + MCP metadata)
	/// - Returns: Complete workspace token breakdown
	@MainActor
	func computeWorkspaceTokenStats(
		filesTokens: Int,
		filesContentTokens: Int? = nil,
		codemapsTokens: Int? = nil,
		promptTokensOverride: Int? = nil,
		fileTreeTokensOverride: Int? = nil,
		metaTokensOverride: Int? = nil,
		gitTokensOverride: Int? = nil,
		otherTokensOverride: Int? = nil
	) -> ToolResultDTOs.TokenStats {
		// Get baseline from TokenCalcService (reflects active tab)
		let breakdown = promptVM.tokenCountingViewModel.latestTokenBreakdown()
		
		// Use overrides if provided (for virtual contexts), otherwise use breakdown
		let promptTokens = promptTokensOverride ?? breakdown.prompt
		let treeTokens = fileTreeTokensOverride ?? breakdown.fileTree
		let metaTokens = metaTokensOverride ?? breakdown.meta
		let gitTokens = gitTokensOverride ?? breakdown.git
		// Note: Don't default to breakdown.other as it includes codemaps which are already in filesTokens
		let otherTokens = otherTokensOverride ?? 0
		
		return Self.makeTokenStats(
			filesTokens: filesTokens,
			filesContentTokens: filesContentTokens,
			codemapsTokens: codemapsTokens,
			breakdown: .init(
				prompt: promptTokens,
				duplicatePrompt: 0,
				instructions: metaTokens,
				formatting: 0,
				fileTree: treeTokens,
				gitDiff: gitTokens,
				metadata: otherTokens
			)
		)
	}
}
