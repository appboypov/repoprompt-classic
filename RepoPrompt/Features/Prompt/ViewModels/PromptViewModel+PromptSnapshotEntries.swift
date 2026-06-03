import Foundation

extension PromptViewModel {
	@MainActor
	private func effectiveCodeMapUsageForChatPromptEntries() -> CodeMapUsage {
		let chatPreset = currentChatPreset()
		let context = resolvedPromptContext(from: chatPreset) ?? resolvePromptContext()
		return context.codeMapUsage
	}

	@MainActor
	func hasPromptSnapshotEntriesForChat() -> Bool {
		let selectionCount = fileManager.selectedFiles.count
		let codeMapUsage = effectiveCodeMapUsageForChatPromptEntries()

		switch codeMapUsage {
		case .none, .selected:
			return selectionCount > 0
		case .auto:
			return selectionCount > 0 || !fileManager.autoCodemapFiles.isEmpty
		case .complete:
			return selectionCount > 0 || !tokenCountingViewModel.cachedFileAPIs.isEmpty
		}
	}

	@MainActor
	func promptSnapshotEntriesForChatCached() -> [PromptFileEntry] {
		let codeMapUsage = effectiveCodeMapUsageForChatPromptEntries()
		let key = ChatPromptEntriesCacheKey(
			codeMapUsage: codeMapUsage,
			selectionVersion: chatSelectionVersion,
			slicesVersion: chatSlicesVersion,
			autoCodemapVersion: chatAutoCodemapVersion,
			fileAPIsVersion: chatFileAPIsVersion
		)

		if let cache = chatPromptEntriesCache, cache.key == key {
			return cache.entries
		}

		let entries = fileManager.buildPromptEntries(
			codeMapUsage: codeMapUsage,
			allFileAPIs: tokenCountingViewModel.cachedFileAPIs
		)
		chatPromptEntriesCache = (key: key, entries: entries)
		return entries
	}

	@MainActor
	func promptSnapshotEntriesForChat() -> [PromptFileEntry] {
		promptSnapshotEntriesForChatCached()
	}
}
