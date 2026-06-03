import Foundation

@MainActor
struct AgentModeSidebarSessionBuilder {
	typealias SidebarSession = AgentModeViewModel.SidebarSession
	typealias TabSession = AgentModeViewModel.TabSession

	let allTabs: [ComposeTabState]
	let linkedTabs: [ComposeTabState]
	let sessions: [UUID: TabSession]
	let sessionIndex: [UUID: AgentSessionIndexEntry]
	let sessionListSortDates: [UUID: Date]
	let sessionListCacheReady: Bool
	let sidebarRestoreFrozenOrderByTabID: [UUID: Int]
	let mcpControlledTabIDs: Set<UUID>

	private struct BuildContext {
		let tabByID: [UUID: ComposeTabState]
		let tabNameByID: [UUID: String]
		let tabOrder: [UUID: Int]
		let sortDateByTabID: [UUID: Date]
		let explicitSessionIDByTabID: [UUID: UUID]
		let bestEntryByTabID: [UUID: AgentSessionIndexEntry]
		let useFrozenRestoreOrder: Bool
	}

	func build() -> [SidebarSession] {
		#if DEBUG
		let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
		#endif
		let context = makeBuildContext()
		let rows = linkedTabs.map { tab in
			sidebarRow(for: tab, context: context)
		}
		let baseSortedSessions = sortedSidebarRows(rows, context: context)
		let result = finalizedSidebarRows(from: baseSortedSessions, context: context)
		#if DEBUG
		let hasParentMetadata = sessions.values.contains { $0.parentSessionID != nil }
			|| sessionIndex.values.contains { $0.parentSessionID != nil }
		AgentModePerfDiagnostics.durationEvent(
			"sidebar.builder.build",
			startMS: startMS,
			fields: [
				"allTabCount": String(allTabs.count),
				"hasParentMetadata": String(hasParentMetadata),
				"linkedTabCount": String(linkedTabs.count),
				"mcpControlledCount": String(mcpControlledTabIDs.count),
				"resultCount": String(result.count),
				"sessionCount": String(sessions.count),
				"sessionIndexCount": String(sessionIndex.count),
				"sortDateCount": String(sessionListSortDates.count)
			]
		)
		#endif
		return result
	}

	static func preferredSidebarEntry(
		for tabID: UUID,
		tabName: String? = nil,
		sessionIndex: [UUID: AgentSessionIndexEntry]
	) -> AgentSessionIndexEntry? {
		preferredSidebarEntry(
			for: tabID,
			tabName: tabName,
			entries: sessionIndex.values.filter { $0.tabID == tabID }
		)
	}

	static func sessionIndexEntryHasConversationContent(_ entry: AgentSessionIndexEntry) -> Bool {
		entry.itemCount > 0 || entry.lastUserMessageAt != nil || entry.hasUnknownConversationContent
	}

	private func makeBuildContext() -> BuildContext {
		var tabByID: [UUID: ComposeTabState] = [:]
		for tab in allTabs where tabByID[tab.id] == nil {
			tabByID[tab.id] = tab
		}
		let tabNameByID = sidebarTabNameLookup(for: linkedTabs)
		let tabOrder = sidebarTabOrder(for: linkedTabs)
		let sortDateByTabID = sidebarSortDateLookup(for: linkedTabs)
		var explicitSessionIDByTabID: [UUID: UUID] = [:]
		var explicitTabIDBySessionID: [UUID: UUID] = [:]
		explicitSessionIDByTabID.reserveCapacity(linkedTabs.count)
		explicitTabIDBySessionID.reserveCapacity(linkedTabs.count)
		for tab in linkedTabs {
			if let activeAgentSessionID = tab.activeAgentSessionID {
				explicitSessionIDByTabID[tab.id] = activeAgentSessionID
				explicitTabIDBySessionID[activeAgentSessionID] = tab.id
			}
		}
		let indexEntriesByTabID = Dictionary(grouping: sessionIndex.values, by: \.tabID)
		let bestEntryByTabID = sidebarEntryMap(
			for: linkedTabs,
			tabNameByID: tabNameByID,
			explicitSessionIDByTabID: explicitSessionIDByTabID,
			explicitTabIDBySessionID: explicitTabIDBySessionID,
			indexEntriesBySessionID: sessionIndex,
			indexEntriesByTabID: indexEntriesByTabID
		)
		return BuildContext(
			tabByID: tabByID,
			tabNameByID: tabNameByID,
			tabOrder: tabOrder,
			sortDateByTabID: sortDateByTabID,
			explicitSessionIDByTabID: explicitSessionIDByTabID,
			bestEntryByTabID: bestEntryByTabID,
			useFrozenRestoreOrder: shouldFreezeSidebarOrdering(for: linkedTabs)
		)
	}

	private func sidebarTabNameLookup(for tabs: [ComposeTabState]) -> [UUID: String] {
		var tabNameByID: [UUID: String] = [:]
		for tab in tabs where tabNameByID[tab.id] == nil {
			tabNameByID[tab.id] = Self.normalizedSessionTitle(tab.name)
		}
		return tabNameByID
	}

	private func sidebarTabOrder(for tabs: [ComposeTabState]) -> [UUID: Int] {
		var tabOrder: [UUID: Int] = [:]
		for (index, tab) in tabs.enumerated() where tabOrder[tab.id] == nil {
			tabOrder[tab.id] = index
		}
		return tabOrder
	}

	private func sidebarSortDateLookup(for tabs: [ComposeTabState]) -> [UUID: Date] {
		var sortDateByTabID: [UUID: Date] = [:]
		for tab in tabs where sortDateByTabID[tab.id] == nil {
			guard let sortDate = Self.sessionListSortDate(
				for: tab.id,
				sessions: sessions,
				sessionListSortDates: sessionListSortDates
			) else {
				continue
			}
			sortDateByTabID[tab.id] = sortDate
		}
		return sortDateByTabID
	}

	private func shouldFreezeSidebarOrdering(for tabs: [ComposeTabState]) -> Bool {
		guard !sessionListCacheReady, !sidebarRestoreFrozenOrderByTabID.isEmpty else { return false }
		return tabs.allSatisfy { sidebarRestoreFrozenOrderByTabID[$0.id] != nil }
	}

	private func frozenSidebarOrderIndex(for tabID: UUID, fallback: Int) -> Int {
		sidebarRestoreFrozenOrderByTabID[tabID] ?? fallback
	}

	private func sidebarEntryMap(
		for tabs: [ComposeTabState],
		tabNameByID: [UUID: String],
		explicitSessionIDByTabID: [UUID: UUID],
		explicitTabIDBySessionID: [UUID: UUID],
		indexEntriesBySessionID: [UUID: AgentSessionIndexEntry],
		indexEntriesByTabID: [UUID: [AgentSessionIndexEntry]]
	) -> [UUID: AgentSessionIndexEntry] {
		var entryByTabID: [UUID: AgentSessionIndexEntry] = [:]
		for tab in tabs where entryByTabID[tab.id] == nil {
			if let explicitSessionID = explicitSessionIDByTabID[tab.id],
				let explicitEntry = indexEntriesBySessionID[explicitSessionID] {
				entryByTabID[tab.id] = Self.sidebarEntry(
					from: explicitEntry,
					tabID: tab.id,
					tabName: tabNameByID[tab.id]
				)
				continue
			}
			let candidateEntries = (indexEntriesByTabID[tab.id] ?? []).filter { entry in
				guard let explicitTabID = explicitTabIDBySessionID[entry.id] else { return true }
				return explicitTabID == tab.id
			}
			guard let entry = Self.preferredSidebarEntry(
				for: tab.id,
				tabName: tabNameByID[tab.id],
				entries: candidateEntries
			) else {
				continue
			}
			entryByTabID[tab.id] = entry
		}
		return entryByTabID
	}

	private static func sidebarEntry(
		from entry: AgentSessionIndexEntry,
		tabID: UUID,
		tabName: String?
	) -> AgentSessionIndexEntry {
		AgentSessionIndexEntry(
			id: entry.id,
			tabID: tabID,
			name: tabName.map(normalizedSessionTitle) ?? normalizedSessionTitle(entry.name),
			lastUserMessageAt: entry.lastUserMessageAt,
			savedAt: entry.savedAt,
			lastRunStateRaw: entry.lastRunStateRaw,
			itemCount: entry.itemCount,
			agentKindRaw: entry.agentKindRaw,
			agentModelRaw: entry.agentModelRaw,
			agentReasoningEffortRaw: entry.agentReasoningEffortRaw,
			autoEditEnabled: entry.autoEditEnabled,
			parentSessionID: entry.parentSessionID,
			hasUnknownConversationContent: entry.hasUnknownConversationContent,
			isMCPOriginated: entry.isMCPOriginated
		)
	}

	static func preferredSidebarEntry(
		for tabID: UUID,
		tabName: String?,
		entries: [AgentSessionIndexEntry]
	) -> AgentSessionIndexEntry? {
		let preferredName = tabName.map(normalizedSessionTitle)
		var bestEntry: AgentSessionIndexEntry?

		for entry in entries where entry.tabID == tabID {
			var resolved = entry
			resolved.name = preferredName ?? normalizedSessionTitle(entry.name)
			if let existing = bestEntry {
				if AgentSessionRestoreSupport.shouldPreferSidebarEntry(resolved, over: existing) {
					bestEntry = resolved
				}
			} else {
				bestEntry = resolved
			}
		}

		return bestEntry
	}

	private func sidebarRow(
		for tab: ComposeTabState,
		context: BuildContext
	) -> SidebarSession {
		let liveSession = sessions[tab.id]
		let entry = context.bestEntryByTabID[tab.id]
		let title = sidebarRowTitle(
			for: tab,
			liveSession: liveSession,
			entry: entry,
			context: context
		)
		let lastUserMessageAt = entry?.lastUserMessageAt ?? context.sortDateByTabID[tab.id]
		let savedAt = sidebarSavedAt(for: tab, liveSession: liveSession, indexEntry: entry)
		let activityDate = Self.sidebarActivityDate(lastUserMessageAt: lastUserMessageAt, savedAt: savedAt)
		let resolvedSessionID = liveSession?.activeAgentSessionID ?? entry?.id
		let resolvedParentSessionID = liveSession?.parentSessionID ?? entry?.parentSessionID

		return SidebarSession(
			id: tab.id,
			tabID: tab.id,
			title: title,
			lastUserMessageAt: lastUserMessageAt,
			activityDate: activityDate,
			isPinned: tab.isPinned,
			sessionID: resolvedSessionID,
			parentSessionID: resolvedParentSessionID,
			depth: 0,
			isMCPControlled: mcpControlledTabIDs.contains(tab.id)
		)
	}

	private func sidebarRowTitle(
		for tab: ComposeTabState,
		liveSession: TabSession?,
		entry: AgentSessionIndexEntry?,
		context: BuildContext
	) -> String {
		if let entry {
			return sidebarTitle(for: entry, liveSession: liveSession)
		}
		if let liveSession,
			liveSession.activeAgentSessionID != nil,
			!liveSession.hasLoadedPersistedState {
			return context.tabNameByID[tab.id] ?? Self.normalizedSessionTitle(nil)
		}
		let hasTranscript = liveSession?.items.isEmpty == false
		let hasSentUserMessage = context.sortDateByTabID[tab.id] != nil
		return (!hasTranscript && !hasSentUserMessage)
			? emptySidebarTitle(named: context.tabNameByID[tab.id])
			: (context.tabNameByID[tab.id] ?? Self.normalizedSessionTitle(nil))
	}

	private func sidebarTitle(for entry: AgentSessionIndexEntry, liveSession: TabSession?) -> String {
		if let liveSession,
			liveSession.activeAgentSessionID != nil,
			!liveSession.hasLoadedPersistedState {
			// Hydrating sessions should keep a stable title to avoid "New Chat" flicker.
			return Self.normalizedSessionTitle(entry.name)
		}
		let hasTranscript = (liveSession?.items.isEmpty == false) || entry.itemCount > 0
		let hasSentUserMessage = entry.lastUserMessageAt != nil
		if !hasTranscript && !hasSentUserMessage && !entry.hasUnknownConversationContent {
			return emptySidebarTitle(named: entry.name)
		}
		return Self.normalizedSessionTitle(entry.name)
	}

	private func emptySidebarTitle(named rawName: String?) -> String {
		let normalized = Self.normalizedSessionTitle(rawName)
		return Self.isDefaultBlankSessionTitle(normalized) ? "New Chat" : normalized
	}

	private static func isDefaultBlankSessionTitle(_ title: String) -> Bool {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed == "New Chat" || trimmed == "New Session" || trimmed == "Agent Session" {
			return true
		}
		guard trimmed.count >= 2 else { return false }
		let prefix = trimmed.prefix(1)
		guard prefix == "T" || prefix == "t" else { return false }
		return Int(trimmed.dropFirst()) != nil
	}

	private func sortedSidebarRows(
		_ rows: [SidebarSession],
		context: BuildContext
	) -> [SidebarSession] {
		rows.sorted { lhs, rhs in
			let lhsIndex = context.tabOrder[lhs.tabID] ?? Int.max
			let rhsIndex = context.tabOrder[rhs.tabID] ?? Int.max
			if context.useFrozenRestoreOrder {
				let lhsFrozenIndex = frozenSidebarOrderIndex(for: lhs.tabID, fallback: lhsIndex)
				let rhsFrozenIndex = frozenSidebarOrderIndex(for: rhs.tabID, fallback: rhsIndex)
				if lhsFrozenIndex != rhsFrozenIndex {
					return lhsFrozenIndex < rhsFrozenIndex
				}
			}
			if lhs.activityDate != rhs.activityDate {
				return lhs.activityDate > rhs.activityDate
			}
			if lhsIndex != rhsIndex {
				return lhsIndex < rhsIndex
			}
			return lhs.tabID.uuidString < rhs.tabID.uuidString
		}
	}

	private func sidebarSavedAt(
		for tab: ComposeTabState,
		liveSession: TabSession?,
		indexEntry: AgentSessionIndexEntry? = nil
	) -> Date {
		if let indexEntry {
			return indexEntry.savedAt
		}
		guard let liveSession else {
			return tab.lastModified
		}
		// Keep order stable while a bound persisted session is still hydrating.
		if liveSession.activeAgentSessionID != nil && !liveSession.hasLoadedPersistedState {
			return tab.lastModified
		}
		return liveSession.lastActivityAt
	}

	private func finalizedSidebarRows(
		from baseSortedSessions: [SidebarSession],
		context: BuildContext
	) -> [SidebarSession] {
		let orderedSessions = prefixedPinnedSidebarSessions(baseSortedSessions)
		guard !context.useFrozenRestoreOrder else {
			return sidebarSessionsPreservingFlatOrder(orderedSessions)
		}
		if orderedSessions.contains(where: { sessions[$0.tabID]?.parentSessionID != nil }) {
			let restoredParentTabIDs = Set(context.bestEntryByTabID.values.compactMap { entry -> UUID? in
				guard entry.parentSessionID != nil,
					sessions[entry.tabID]?.parentSessionID == nil else {
					return nil
				}
				return entry.tabID
			})
			return threadedSidebarSessions(
				from: orderedSessions,
				tabOrder: context.tabOrder,
				restoredParentTabIDs: restoredParentTabIDs
			)
		}
		if orderedSessions.contains(where: { $0.parentSessionID != nil }) {
			return sidebarSessionsPreservingPersistedThreadGroups(orderedSessions, tabOrder: context.tabOrder)
		}
		return sidebarSessionsPreservingFlatOrder(orderedSessions)
	}

	private func prefixedPinnedSidebarSessions(_ sessions: [SidebarSession]) -> [SidebarSession] {
		let pinned = sessions.filter(\.isPinned)
		guard !pinned.isEmpty else { return sessions }
		let unpinned = sessions.filter { !$0.isPinned }
		return pinned + unpinned
	}

	private func workspaceOrderedSidebarRows(
		_ rows: [SidebarSession],
		tabOrder: [UUID: Int]
	) -> [SidebarSession] {
		rows.sorted { lhs, rhs in
			let lhsIndex = tabOrder[lhs.tabID] ?? Int.max
			let rhsIndex = tabOrder[rhs.tabID] ?? Int.max
			if lhsIndex != rhsIndex {
				return lhsIndex < rhsIndex
			}
			return lhs.tabID.uuidString < rhs.tabID.uuidString
		}
	}

	private struct PersistedThreadGroup {
		let priority: Int
		let isPinnedRoot: Bool
		let rows: [SidebarSession]
	}

	private func sidebarSessionsPreservingPersistedThreadGroups(
		_ orderedSessions: [SidebarSession],
		tabOrder: [UUID: Int]
	) -> [SidebarSession] {
		let sessionIDToIndex = Dictionary(
			orderedSessions.enumerated().compactMap { index, session -> (UUID, Int)? in
				guard let sessionID = session.sessionID else { return nil }
				return (sessionID, index)
			},
			uniquingKeysWith: { _, latest in latest }
		)
		let parentIndexByIndex = Dictionary(
			uniqueKeysWithValues: orderedSessions.enumerated().compactMap { index, session -> (Int, Int)? in
				guard let parentSessionID = session.parentSessionID,
					let sessionID = session.sessionID,
					parentSessionID != sessionID,
					let parentIndex = sessionIDToIndex[parentSessionID] else {
					return nil
				}
				return (index, parentIndex)
			}
		)

		var cycleGroupRoots: Set<Int> = []
		func groupRoot(for index: Int) -> Int {
			var cursor = index
			var seen: Set<Int> = [index]
			while let parentIndex = parentIndexByIndex[cursor] {
				guard seen.insert(parentIndex).inserted else {
					let cycleRoot = seen.min() ?? index
					cycleGroupRoots.insert(cycleRoot)
					return cycleRoot
				}
				cursor = parentIndex
			}
			return cursor
		}

		let groups = Dictionary(grouping: orderedSessions.indices, by: groupRoot)
			.map { rootIndex, indices -> PersistedThreadGroup in
				let indexSet = Set(indices)
				let rootIndices = indices.filter { index in
					guard let parentIndex = parentIndexByIndex[index] else { return true }
					return !indexSet.contains(parentIndex)
				}
				let pinnedRoots = rootIndices.isEmpty ? indices : rootIndices
				let rows = indices.count == 1
					? [orderedSessions[indices[0]]]
					: workspaceOrderedSidebarRows(indices.map { orderedSessions[$0] }, tabOrder: tabOrder)
				let annotatedRows = cycleGroupRoots.contains(rootIndex)
					? rows.map { row($0, depth: 0) }
					: sidebarSessionsPreservingFlatOrder(rows)
				return PersistedThreadGroup(
					priority: indices.min() ?? Int.max,
					isPinnedRoot: pinnedRoots.contains { orderedSessions[$0].isPinned },
					rows: annotatedRows
				)
			}

		return groups.sorted { lhs, rhs in
			if lhs.isPinnedRoot != rhs.isPinnedRoot {
				return lhs.isPinnedRoot && !rhs.isPinnedRoot
			}
			if lhs.priority != rhs.priority {
				return lhs.priority < rhs.priority
			}
			let lhsID = lhs.rows.first?.tabID.uuidString ?? ""
			let rhsID = rhs.rows.first?.tabID.uuidString ?? ""
			return lhsID < rhsID
		}.flatMap(\.rows)
	}

	/// Preserves the incoming row order while annotating child depth only when the
	/// parent already appears earlier in the list. This avoids visible row movement
	/// during persisted restore while still surfacing limited thread structure.
	private func sidebarSessionsPreservingFlatOrder(_ flat: [SidebarSession]) -> [SidebarSession] {
		var sessionIDToIndex: [UUID: Int] = [:]
		for (index, session) in flat.enumerated() {
			if let sessionID = session.sessionID {
				sessionIDToIndex[sessionID] = index
			}
		}

		var cachedDepthByIndex: [Int: Int] = [:]
		var visiting = Set<Int>()

		func stableDepth(for index: Int) -> Int {
			if let cached = cachedDepthByIndex[index] {
				return cached
			}
			guard let parentSessionID = flat[index].parentSessionID,
				let sessionID = flat[index].sessionID,
				parentSessionID != sessionID,
				let parentIndex = sessionIDToIndex[parentSessionID],
				parentIndex < index,
				!visiting.contains(index) else {
				cachedDepthByIndex[index] = 0
				return 0
			}

			visiting.insert(index)
			let depth = stableDepth(for: parentIndex) + 1
			visiting.remove(index)
			cachedDepthByIndex[index] = depth
			return depth
		}

		return flat.enumerated().map { index, session in
			row(session, depth: stableDepth(for: index))
		}
	}

	/// Builds a thread-aware flattened list from flat sidebar sessions.
	/// Child sessions are nested under their parent with incrementing depth.
	/// Cycles and missing parents degrade children to root level.
	private func threadedSidebarSessions(
		from flat: [SidebarSession],
		tabOrder: [UUID: Int],
		restoredParentTabIDs: Set<UUID>
	) -> [SidebarSession] {
		// Build lookup: sessionID -> index in flat list
		var sessionIDToIndex: [UUID: Int] = [:]
		for (i, session) in flat.enumerated() {
			if let sid = session.sessionID {
				sessionIDToIndex[sid] = i
			}
		}

		// Determine parent-child relationships
		// A session is a child if: parentSessionID != nil, parent is in the visible set,
		// parent != self, and attaching wouldn't create a cycle.
		var childrenByParent: [UUID: [Int]] = [:] // parentSessionID -> [child flat indices]
		var isChild = Set<Int>()

		for (i, session) in flat.enumerated() {
			guard let parentSID = session.parentSessionID,
				let selfSID = session.sessionID,
				parentSID != selfSID,
				sessionIDToIndex[parentSID] != nil else {
				continue
			}
			// Cycle detection: walk parent chain
			var visited: Set<UUID> = [selfSID]
			var cursor: UUID? = parentSID
			var hasCycle = false
			while let c = cursor {
				if visited.contains(c) { hasCycle = true; break }
				visited.insert(c)
				let parentSession = sessionIDToIndex[c].flatMap { flat[$0] }
				cursor = parentSession?.parentSessionID
			}
			guard !hasCycle else { continue }

			childrenByParent[parentSID, default: []].append(i)
			isChild.insert(i)
		}

		// If no threading needed, return flat list as-is
		guard !childrenByParent.isEmpty else { return flat }

		// DFS flattening: roots first, then children in original order.
		// Root order uses the earliest flat-list position from each visible subtree,
		// so a reopened child keeps its parent+subtree anchored at the child's
		// recency instead of dropping the whole subtree to the older parent's row.
		var result: [SidebarSession] = []
		result.reserveCapacity(flat.count)

		var subtreePriorityByIndex: [Int: Int] = [:]
		func subtreePriority(for index: Int) -> Int {
			if let cached = subtreePriorityByIndex[index] {
				return cached
			}
			var priority = index
			if let sid = flat[index].sessionID,
				let children = childrenByParent[sid] {
				for childIndex in children {
					priority = min(priority, subtreePriority(for: childIndex))
				}
			}
			subtreePriorityByIndex[index] = priority
			return priority
		}

		func emit(_ index: Int, depth: Int) {
			let session = flat[index]
			result.append(row(session, depth: depth))
			if let sid = session.sessionID, let children = childrenByParent[sid] {
				// Brand-new fully-live siblings keep flat/newest-first order. Restored
				// sibling sets keep tab order across hydration so clicking a persisted
				// child live does not flip the child list.
				let hasRestoredChild = children.contains { restoredParentTabIDs.contains(flat[$0].tabID) }
				let orderedChildren = hasRestoredChild
					? children.sorted(by: { lhs, rhs in
						let lhsOrder = tabOrder[flat[lhs].tabID] ?? lhs
						let rhsOrder = tabOrder[flat[rhs].tabID] ?? rhs
						if lhsOrder != rhsOrder {
							return lhsOrder < rhsOrder
						}
						return lhs < rhs
					})
					: children
				for childIndex in orderedChildren {
					emit(childIndex, depth: depth + 1)
				}
			}
		}

		let rootIndices = flat.indices.filter { !isChild.contains($0) }
		for rootIndex in rootIndices.sorted(by: { lhs, rhs in
			let lhsPinned = flat[lhs].isPinned
			let rhsPinned = flat[rhs].isPinned
			if lhsPinned != rhsPinned {
				return lhsPinned && !rhsPinned
			}
			let lhsPriority = subtreePriority(for: lhs)
			let rhsPriority = subtreePriority(for: rhs)
			if lhsPriority != rhsPriority {
				return lhsPriority < rhsPriority
			}
			return lhs < rhs
		}) {
			emit(rootIndex, depth: 0)
		}
		return result
	}

	private func row(_ session: SidebarSession, depth: Int) -> SidebarSession {
		SidebarSession(
			id: session.id,
			tabID: session.tabID,
			title: session.title,
			lastUserMessageAt: session.lastUserMessageAt,
			activityDate: session.activityDate,
			isPinned: session.isPinned,
			sessionID: session.sessionID,
			parentSessionID: session.parentSessionID,
			depth: depth,
			isMCPControlled: session.isMCPControlled
		)
	}

	private static func normalizedSessionTitle(_ raw: String?) -> String {
		AgentSessionRestoreSupport.normalizedSessionTitle(raw)
	}

	private static func sessionListSortDate(
		for tabID: UUID,
		sessions: [UUID: TabSession],
		sessionListSortDates: [UUID: Date]
	) -> Date? {
		if let session = sessions[tabID] {
			if let lastUserMessageAt = session.lastUserMessageAt {
				return lastUserMessageAt
			}
			if let computed = AgentTranscriptIO.lastUserInteractionDate(in: session.items) {
				return computed
			}
		}
		return sessionListSortDates[tabID]
	}

	private static func sidebarActivityDate(lastUserMessageAt: Date?, savedAt: Date) -> Date {
		AgentSessionRestoreSupport.sidebarActivityDate(
			lastUserMessageAt: lastUserMessageAt,
			savedAt: savedAt
		)
	}
}
