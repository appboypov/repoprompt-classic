import Foundation
import Combine
import MCP

#if DEBUG
private func tabContextLog(_ message: @autoclosure () -> String) {
	//print("[TabContext] \(message())")
}
#else
private func tabContextLog(_ message: @autoclosure () -> String) {}
#endif

extension MCPServerViewModel {
	struct TabScopedContext {
		let tabID: UUID
		let windowID: Int
		let workspaceID: UUID?
		var promptText: String
		var selection: StoredSelection
		/// Selected stored prompt IDs for computing meta tokens in virtual contexts
		var selectedMetaPromptIDs: [UUID]
		/// Tab name for MCP metadata block generation
		var tabName: String
		var runID: UUID?
		/// True if this context was created via explicit `bind_context` / `_tabID` binding.
		/// Explicit bindings should persist even when the bound tab is not the active tab.
		let explicitlyBound: Bool
	}

	struct ConnectionBindingSnapshot: Equatable, Sendable {
		enum BindingKind: Equatable, Sendable {
			case unbound
			case windowOnly
			case context
		}

		let windowID: Int?
		let tabID: UUID?
		let workspaceID: UUID?
		let workspaceName: String?
		let tabName: String?
		let repoPaths: [String]
		let explicitlyBound: Bool
		let runID: UUID?

		var bindingKind: BindingKind {
			if tabID != nil {
				return .context
			}
			if windowID != nil {
				return .windowOnly
			}
			return .unbound
		}
	}

	enum ExecContext {
		case live
		case virtual(TabScopedContext)
	}

	@MainActor
	struct PendingContextStore {
		private var storage: [String: [Int: [TabScopedContext]]] = [:]

		var isEmpty: Bool { storage.isEmpty }

		func contains(clientName: String, windowID: Int, runID: UUID) -> Bool {
			guard let queue = storage[clientName]?[windowID] else { return false }
			return queue.contains(where: { $0.runID == runID })
		}

		mutating func enqueue(_ context: TabScopedContext, clientName: String, windowID: Int) -> Int {
			var windowMap = storage[clientName] ?? [:]
			var queue = windowMap[windowID] ?? []
			queue.append(context)
			windowMap[windowID] = queue
			storage[clientName] = windowMap
			return queue.count
		}

		mutating func pop(clientName: String, windowID: Int, runID: UUID?) -> (context: TabScopedContext?, remaining: Int) {
			guard var windowMap = storage[clientName],
				var queue = windowMap[windowID],
				!queue.isEmpty else {
				return (nil, 0)
			}

			let index: Int
			if let runID {
				guard let match = queue.firstIndex(where: { $0.runID == runID }) else {
					return (nil, queue.count)
				}
				index = match
			} else {
				index = 0
			}

			let context = queue.remove(at: index)
			if queue.isEmpty {
				windowMap.removeValue(forKey: windowID)
			} else {
				windowMap[windowID] = queue
			}

			if windowMap.isEmpty {
				storage.removeValue(forKey: clientName)
			} else {
				storage[clientName] = windowMap
			}
			return (context, queue.count)
		}

		mutating func popByRunID(clientName: String, runID: UUID) -> (context: TabScopedContext?, windowID: Int?, remaining: Int) {
			guard var windowMap = storage[clientName] else {
				return (nil, nil, 0)
			}

			for (windowID, queue) in windowMap {
				if let index = queue.firstIndex(where: { $0.runID == runID }) {
					var mutableQueue = queue
					let context = mutableQueue.remove(at: index)
					if mutableQueue.isEmpty {
						windowMap.removeValue(forKey: windowID)
					} else {
						windowMap[windowID] = mutableQueue
					}
					if windowMap.isEmpty {
						storage.removeValue(forKey: clientName)
					} else {
						storage[clientName] = windowMap
					}
					return (context, windowID, mutableQueue.count)
				}
			}

			return (nil, nil, 0)
		}

		func queueLength(clientName: String, windowID: Int) -> Int {
			storage[clientName]?[windowID]?.count ?? 0
		}

		mutating func clear(clientName: String) {
			storage.removeValue(forKey: clientName)
		}

		// Clear only one window queue for a given client
		@discardableResult
		mutating func clear(clientName: String, windowID: Int) -> Int {
			guard var windowMap = storage[clientName] else { return 0 }
			let removed = windowMap[windowID]?.count ?? 0
			windowMap.removeValue(forKey: windowID)
			if windowMap.isEmpty {
				storage.removeValue(forKey: clientName)
			} else {
				storage[clientName] = windowMap
			}
			return removed
		}

		mutating func purge(tabID: UUID) -> [TabScopedContext] {
			var removed: [TabScopedContext] = []
			let clientNames = Array(storage.keys)

			for clientName in clientNames {
				guard var windowMap = storage[clientName] else { continue }
				let windowIDs = Array(windowMap.keys)

				for windowID in windowIDs {
					guard let queue = windowMap[windowID] else { continue }
					let toRemove = queue.filter { $0.tabID == tabID }
					let toKeep = queue.filter { $0.tabID != tabID }
					removed.append(contentsOf: toRemove)

					if toKeep.isEmpty {
						windowMap.removeValue(forKey: windowID)
					} else {
						windowMap[windowID] = toKeep
					}
				}

				if windowMap.isEmpty {
					storage.removeValue(forKey: clientName)
				} else {
					storage[clientName] = windowMap
				}
			}

			return removed
		}
	}

	// MARK: - Auto-binding for headless clients

	/// Identify headless agent clients we want to auto-bind
	private func isHeadlessClientName(_ name: String) -> Bool {
		MCPClientIdentity.isHeadlessAgentClient(name)
	}

	@MainActor
	private func recordLastContext(clientName: String, context: TabScopedContext) {
		var perWindow = lastContextByClientAndWindow[clientName] ?? [:]
		perWindow[context.windowID] = context
		lastContextByClientAndWindow[clientName] = perWindow
	}

	private static func shouldReuseLastContextForHeadlessAutoBind(
		runHint: UUID?,
		lastContext: TabScopedContext?
	) -> Bool {
		guard runHint == nil, let lastContext else { return false }
		return lastContext.runID == nil
	}

	@MainActor
	private static func popPendingContextForBinding(
		from store: inout PendingContextStore,
		clientName: String,
		windowID: Int,
		runHint: UUID?
	) -> (context: TabScopedContext?, remaining: Int, usedRunHint: Bool) {
		if let runHint {
			let result = store.pop(clientName: clientName, windowID: windowID, runID: runHint)
			let usedRunHint = result.context?.runID == runHint
			return (result.context, result.remaining, usedRunHint)
		}
		let result = store.pop(clientName: clientName, windowID: windowID, runID: nil)
		return (result.context, result.remaining, false)
	}

	@MainActor
	private func shouldKeepBinding(
		connectionID: UUID,
		clientName: String?,
		providedWindowID: Int?,
		bound: TabScopedContext
	) -> Bool {
		// Always keep bindings tied to an active discovery run – they manage their own lifecycle.
		if bound.runID != nil {
			return true
		}

		// Always keep explicit bindings from bind_context / _tabID – they persist regardless of active tab.
		if bound.explicitlyBound {
			return true
		}

		guard let manager = workspaceManager else {
			return false
		}

		guard
			let workspaceID = bound.workspaceID,
			let workspaceIndex = manager.workspaces.firstIndex(where: { $0.id == workspaceID }),
			manager.workspaces[workspaceIndex].composeTabs.contains(where: { $0.id == bound.tabID })
		else {
			return false
		}

		if let hinted = providedWindowID, hinted != bound.windowID {
			return false
		}

		// For headless clients with implicit auto-binding, release binding when
		// there's no pending work and the bound tab is not the active tab.
		// This allows the client to rebind to the new active tab.
		if let clientName, isHeadlessClientName(clientName) {
			let hasPending = pendingTabContexts.queueLength(clientName: clientName, windowID: bound.windowID) > 0
			let isActiveTab = (manager.workspaces[workspaceIndex].activeComposeTabID == bound.tabID)
			if !hasPending && !isActiveTab {
				return false
			}
		}

		return true
	}

	@MainActor
	private func removeRunIDMapping(runID: UUID, connectionID: UUID) {
		if connectionIDByRunID[runID] == connectionID {
			connectionIDByRunID.removeValue(forKey: runID)
		}
		if connectionIDToRunID[connectionID] == runID {
			connectionIDToRunID.removeValue(forKey: connectionID)
		}
	}

	@MainActor
	private func releaseBinding(connectionID: UUID) {
		guard let context = tabContextByConnectionID.removeValue(forKey: connectionID) else { return }
		endMirroringForConnection(connectionID)
		windowIDByConnection.removeValue(forKey: connectionID)
		if let runID = context.runID {
			removeRunIDMapping(runID: runID, connectionID: connectionID)
		} else {
			connectionIDToRunID.removeValue(forKey: connectionID)
		}
		tabContextLog("releaseBinding connectionID=\(connectionID) tab=\(context.tabID) window=\(context.windowID)")
	}

	@MainActor
	private func autoBindHeadlessIfPossible(
		connectionID: UUID,
		clientName: String,
		windowID: Int
	) -> TabScopedContext? {
		let runHint = connectionIDToRunID[connectionID]
		guard runHint == nil else {
			tabContextLog("autoBindHeadlessIfPossible refused run-scoped fallback connectionID=\(connectionID) client=\(clientName) window=\(windowID) runHint=\(runHint!.uuidString)")
			return nil
		}

		// 1) Re-use last known bound context for this client + window only for runless implicit bindings
		let last = lastContextByClientAndWindow[clientName]?[windowID]
		if Self.shouldReuseLastContextForHeadlessAutoBind(runHint: runHint, lastContext: last), let last {
			tabContextByConnectionID[connectionID] = last
			windowIDByConnection[connectionID] = last.windowID
			beginMirroringForConnection(connectionID, context: last)
			tabContextLog("autoBindHeadlessIfPossible reused last context client=\(clientName) window=\(windowID) tab=\(last.tabID)")
			return last
		}

		// 2) Fallback to the window's active compose tab snapshot (bind without runID)
		guard let manager = workspaceManager else {
			tabContextLog("autoBindHeadlessIfPossible no workspace manager for window=\(windowID)")
			return nil
		}
		guard let ws = manager.activeWorkspace else {
			tabContextLog("autoBindHeadlessIfPossible no active workspace for window=\(windowID)")
			return nil
		}

		// Resolve an active tab (or first), then collect a fresh snapshot (prompt, selection)
		let tabID: UUID? = ws.activeComposeTabID ?? ws.composeTabs.first?.id
		guard let tabID, let baseTab = manager.composeTab(with: tabID) else {
			tabContextLog("autoBindHeadlessIfPossible no compose tab available for window=\(windowID)")
			return nil
		}
		let snapshot = manager.collectComposeTabSnapshot(name: baseTab.name, base: baseTab)

		let context = TabScopedContext(
			tabID: snapshot.id,
			windowID: windowID,
			workspaceID: ws.id,
			promptText: snapshot.promptText,
			selection: snapshot.selection,
			selectedMetaPromptIDs: snapshot.selectedMetaPromptIDs,
			tabName: snapshot.name,
			runID: nil,
			explicitlyBound: false   // auto-binding follows active tab
		)

		tabContextByConnectionID[connectionID] = context
		windowIDByConnection[connectionID] = windowID
		recordLastContext(clientName: clientName, context: context)
		beginMirroringForConnection(connectionID, context: context)
		tabContextLog("autoBindHeadlessIfPossible bound fallback to active tab client=\(clientName) window=\(windowID) tab=\(context.tabID)")
		return context
	}

	@MainActor
	private func beginMirroringForConnection(_ connectionID: UUID, context: TabScopedContext) {
		if tabContextCancellablesByConnectionID[connectionID] != nil { return }

		guard let manager = workspaceManager else {
			tabContextLog("beginMirroring skipped - no workspace manager connectionID=\(connectionID)")
			return
		}
		tabContextLog("beginMirroring connectionID=\(connectionID) tab=\(context.tabID) runID=\(context.runID?.uuidString ?? "nil")")

		var bag = Set<AnyCancellable>()

		manager.composeTabSnapshotPublisher(for: context.tabID)
			.receive(on: RunLoop.main)
			.sink { [weak self] snapshot in
				Task { @MainActor in
					guard let self else { return }

					// 1) Skip stale snapshots by lastModified
					if let live = manager.composeTab(with: context.tabID),
					   snapshot.lastModified < live.lastModified {
						tabContextLog("skip stale snapshot connectionID=\(connectionID) tab=\(context.tabID) snapshot.ts=\(snapshot.lastModified) live.ts=\(live.lastModified)")
						return
					}

					// 2) Keep the existing transient-snapshot guard
					if let storedSelection = manager.composeTab(with: context.tabID)?.selection,
						snapshot.selection != storedSelection {
						let incomingCount = snapshot.selection.selectedPaths.count
						let storedCount = storedSelection.selectedPaths.count
						tabContextLog("skip transient snapshot connectionID=\(connectionID) tab=\(context.tabID) incomingSelCount=\(incomingCount) storedSelCount=\(storedCount)")
						return
					}
		
					// 3) Merge snapshot into bound context, but preserve manual codemap mode once set.
					guard var bound = self.tabContextByConnectionID[connectionID] else { return }
					var incomingSelection = snapshot.selection
		
					// Preserve manual=false stickiness
					let wasManual = (bound.selection.codemapAutoEnabled == false)
					if wasManual && incomingSelection.codemapAutoEnabled == true {
						incomingSelection = StoredSelection(
							selectedPaths: incomingSelection.selectedPaths,
							autoCodemapPaths: incomingSelection.autoCodemapPaths,
							slices: incomingSelection.slices,
							codemapAutoEnabled: false
						)
						// DON'T call commitTabContext here - it creates an infinite loop!
						// The bound context correction is enough; next operation will sync to UI.
						tabContextLog("preserved manual mode on snapshot connectionID=\(connectionID) tab=\(context.tabID)")
					}
		
					// 4) Apply if changed
					let selectionChanged = bound.selection != incomingSelection
					let promptChanged = bound.promptText != snapshot.promptText
					let metaChanged = bound.selectedMetaPromptIDs != snapshot.selectedMetaPromptIDs
					let nameChanged = bound.tabName != snapshot.name
					if selectionChanged || promptChanged || metaChanged || nameChanged {
						bound.selection = incomingSelection
						bound.promptText = snapshot.promptText
						bound.selectedMetaPromptIDs = snapshot.selectedMetaPromptIDs
						bound.tabName = snapshot.name
						self.tabContextByConnectionID[connectionID] = bound
						tabContextLog("applied snapshot connectionID=\(connectionID) tab=\(context.tabID) selCount=\(incomingSelection.selectedPaths.count) promptChars=\(snapshot.promptText.count)")
					}
				}
			}
			.store(in: &bag)

		tabContextCancellablesByConnectionID[connectionID] = bag
	}

	@MainActor
	private func endMirroringForConnection(_ connectionID: UUID) {
		tabContextLog("endMirroring connectionID=\(connectionID)")
		tabContextCancellablesByConnectionID[connectionID]?.forEach { $0.cancel() }
		tabContextCancellablesByConnectionID.removeValue(forKey: connectionID)
	}

	@MainActor
	private func pushVirtualContextToUI(_ context: TabScopedContext) async {
		await commitTabContext(context)
		// Only refresh metrics when we actually applied to the active tab
		if let manager = self.workspaceManager,
		   let activeWS = manager.activeWorkspace,
		   activeWS.activeComposeTabID == context.tabID {
			await self.refreshSelectionMetrics()
		}
	}

	@MainActor
	func pendingContextQueueLength(clientName: String, windowID: Int) -> Int {
		return pendingTabContexts.queueLength(clientName: clientName, windowID: windowID)
	}

	// MARK: - Tab Binding APIs for MCP Routing

	/// Returns the currently bound tab ID for a connection, if any.
	/// Only returns a tab ID if the binding is for this window.
	@MainActor
	func boundTabID(forConnection connectionID: UUID?) -> UUID? {
		guard let connectionID,
			let ctx = tabContextByConnectionID[connectionID]
		else { return nil }

		// Only treat it as "bound here" if this MCPServerViewModel owns that window
		guard ctx.windowID == self.windowID else { return nil }
		return ctx.tabID
	}

	@MainActor
	func connectionBindingSnapshot(forConnection connectionID: UUID) -> ConnectionBindingSnapshot {
		if let context = tabContextByConnectionID[connectionID],
		context.windowID == windowID {
			let workspace = context.workspaceID.flatMap { workspaceID in
				workspaceManager?.workspaces.first(where: { $0.id == workspaceID })
			}
			let resolvedTabName =
				workspaceManager?.composeTabName(with: context.tabID)
				?? promptVM.currentComposeTabs.first(where: { $0.id == context.tabID })?.name
				?? context.tabName
			return ConnectionBindingSnapshot(
				windowID: context.windowID,
				tabID: context.tabID,
				workspaceID: context.workspaceID,
				workspaceName: workspace?.name,
				tabName: resolvedTabName,
				repoPaths: workspace?.repoPaths ?? [],
				explicitlyBound: context.explicitlyBound,
				runID: context.runID
			)
		}

		if let mappedWindowID = windowIDByConnection[connectionID],
		mappedWindowID == windowID {
			let workspace = workspaceManager?.activeWorkspace
			return ConnectionBindingSnapshot(
				windowID: mappedWindowID,
				tabID: nil,
				workspaceID: workspace?.id,
				workspaceName: workspace?.name,
				tabName: nil,
				repoPaths: workspace?.repoPaths ?? [],
				explicitlyBound: false,
				runID: nil
			)
		}

		return ConnectionBindingSnapshot(
			windowID: nil,
			tabID: nil,
			workspaceID: nil,
			workspaceName: nil,
			tabName: nil,
			repoPaths: [],
			explicitlyBound: false,
			runID: nil
		)
	}

	@MainActor
	func clearExplicitBinding(forConnection connectionID: UUID) -> ConnectionBindingSnapshot? {
		guard let context = tabContextByConnectionID[connectionID],
			context.windowID == windowID,
			context.runID == nil,
			context.explicitlyBound else {
			return nil
		}

		let snapshot = connectionBindingSnapshot(forConnection: connectionID)
		releaseBinding(connectionID: connectionID)
		return snapshot
	}

	@MainActor
	func clearNonRunScopedBinding(forConnection connectionID: UUID) -> ConnectionBindingSnapshot? {
		guard let context = tabContextByConnectionID[connectionID],
			context.windowID == windowID,
			context.runID == nil else {
			return nil
		}

		let snapshot = connectionBindingSnapshot(forConnection: connectionID)
		releaseBinding(connectionID: connectionID)
		return snapshot
	}

	/// Returns live run IDs currently bound to a tab in this window.
	@MainActor
	func liveRunIDsBound(toTabID tabID: UUID) -> [UUID] {
		let runIDs = tabContextByConnectionID.values.compactMap { context -> UUID? in
			guard context.tabID == tabID, let runID = context.runID else { return nil }
			return liveConnectionID(forRunID: runID) != nil ? runID : nil
		}
		return Array(Set(runIDs)).sorted { $0.uuidString < $1.uuidString }
	}

	/// Proactively removes all cached tab-context state for a closing tab while preserving window affinity.
	@MainActor
	func purgeClosedTabContext(tabID: UUID) {
		let boundConnections = tabContextByConnectionID.compactMap { connectionID, context in
			context.tabID == tabID ? connectionID : nil
		}

		for connectionID in boundConnections {
			guard let context = tabContextByConnectionID.removeValue(forKey: connectionID) else { continue }
			endMirroringForConnection(connectionID)
			if let runID = context.runID {
				cleanupRunIDMapping(runID: runID, connectionID: connectionID)
			} else {
				connectionIDToRunID.removeValue(forKey: connectionID)
			}
			tabContextLog("purgeClosedTabContext removed bound context connectionID=\(connectionID) tab=\(tabID)")
		}

		let removedPending = pendingTabContexts.purge(tabID: tabID)
		if !removedPending.isEmpty {
			tabContextLog("purgeClosedTabContext removed \(removedPending.count) pending contexts for tab=\(tabID)")
		}

		for (clientName, perWindow) in lastContextByClientAndWindow {
			let filtered = perWindow.filter { $0.value.tabID != tabID }
			if filtered.isEmpty {
				lastContextByClientAndWindow.removeValue(forKey: clientName)
			} else if filtered.count != perWindow.count {
				lastContextByClientAndWindow[clientName] = filtered
			}
		}
	}

	enum TabBindError: Swift.Error {
		case missingWorkspace
		case workspaceNotLoaded(UUID)
		case tabNotFound(UUID)
		case runMappingRejected(UUID)
	}

	/// Binds a connection to a specific compose tab.
	/// Used by bind_context and hidden _tabID parameter flows.
	@MainActor
	func bindTabForConnection(
		connectionID: UUID,
		clientName: String?,
		tabID: UUID,
		workspaceID: UUID,
		windowID: Int,
		runID: UUID? = nil,
		explicitlyBound: Bool = true
	) throws {
		guard let manager = workspaceManager else {
			throw TabBindError.missingWorkspace
		}

		guard let wsIndex = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
			throw TabBindError.workspaceNotLoaded(workspaceID)
		}

		let ws = manager.workspaces[wsIndex]
		guard let tab = ws.composeTabs.first(where: { $0.id == tabID }) else {
			throw TabBindError.tabNotFound(tabID)
		}

		// Tear down any previous binding for this connection
		if tabContextByConnectionID[connectionID] != nil {
			releaseBinding(connectionID: connectionID)
		}

		// Use the tab's STORED selection, not the live UI selection.
		// collectComposeTabSnapshot() would incorrectly use the live selection from fileManager.
		let context = TabScopedContext(
			tabID: tab.id,
			windowID: windowID,
			workspaceID: ws.id,
			promptText: tab.promptText,
			selection: tab.selection,
			selectedMetaPromptIDs: tab.selectedMetaPromptIDs,
			tabName: tab.name,
			runID: runID,
			explicitlyBound: explicitlyBound
		)

		tabContextByConnectionID[connectionID] = context
		windowIDByConnection[connectionID] = windowID
		if let runID {
			let mappingSucceeded = registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: windowID)
			guard mappingSucceeded else {
				tabContextByConnectionID.removeValue(forKey: connectionID)
				windowIDByConnection.removeValue(forKey: connectionID)
				throw TabBindError.runMappingRejected(runID)
			}
		}
		if let clientName {
			recordLastContext(clientName: clientName, context: context)
		}
		beginMirroringForConnection(connectionID, context: context)
		tabContextLog("bindTabForConnection connectionID=\(connectionID) tab=\(tabID) window=\(windowID) workspace=\(workspaceID) runID=\(runID?.uuidString ?? "nil")")
	}

	/// Rebinds connection to target tab if currently bound to a different tab.
	/// Used by oracle_send when continuing a chat that lives on a different tab.
	/// - Returns: true if rebinding occurred, false if already on correct tab or target invalid
	@MainActor
	@discardableResult
	func rebindToTabIfNeeded(
		connectionID: UUID,
		clientName: String?,
		windowID: Int,
		targetTabID: UUID,
		targetWorkspaceID: UUID
	) throws -> Bool {
		let currentBoundTabID = tabContextByConnectionID[connectionID]?.tabID
		
		// Already bound to the target tab
		if currentBoundTabID == targetTabID {
			return false
		}
		
		// Verify target tab exists before rebinding
		guard workspaceManager?.composeTab(with: targetTabID) != nil else {
			tabContextLog("rebindToTabIfNeeded skipped - target tab \(targetTabID) not found")
			return false
		}
		
		try bindTabForConnection(
			connectionID: connectionID,
			clientName: clientName,
			tabID: targetTabID,
			workspaceID: targetWorkspaceID,
			windowID: windowID
		)
		tabContextLog("rebindToTabIfNeeded migrated connectionID=\(connectionID) to tab=\(targetTabID)")
		return true
	}

	@MainActor
	func installTabContext(
		clientID: String?,
		clientName: String?,
		windowID: Int,
		workspaceID providedWorkspaceID: UUID? = nil,
		snapshot: ComposeTabState,
		runID: UUID? = nil
	) {
		tabContextLog("installTabContext tab=\(snapshot.id) window=\(windowID) clientID=\(clientID ?? "nil") clientName=\(clientName ?? "nil") runID=\(runID?.uuidString ?? "nil")")
		let resolvedWorkspaceID: UUID? = {
			if let providedWorkspaceID {
				return providedWorkspaceID
			}
			return workspaceManager?.activeWorkspace?.id
		}()

		let context = TabScopedContext(
			tabID: snapshot.id,
			windowID: windowID,
			workspaceID: resolvedWorkspaceID,
			promptText: snapshot.promptText,
			selection: snapshot.selection,
			selectedMetaPromptIDs: snapshot.selectedMetaPromptIDs,
			tabName: snapshot.name,
			runID: runID,
			explicitlyBound: false   // discovery run binding, not explicit bind_context
		)

		if let clientID,
		   let uuid = UUID(uuidString: clientID) {
			// Conflict-safe immediate binding path
			if let existing = tabContextByConnectionID[uuid],
			   let existingRun = existing.runID,
			   let newRun = context.runID,
			   existingRun != newRun {
				// Do not overwrite another run's binding; queue instead (requires clientName)
				tabContextLog("installTabContext declined overwrite connectionID=\(uuid) existingRun=\(existingRun) newRun=\(newRun); queuing by clientName")
				if let clientName {
					enqueuePendingContext(context, clientName: clientName, windowID: windowID)
				} else {
					tabContextLog("[warning] installTabContext conflict but no clientName provided; cannot queue")
				}
				return
			}

		tabContextLog("installTabContext immediate bind connectionID=\(uuid)")
		tabContextByConnectionID[uuid] = context
		windowIDByConnection[uuid] = context.windowID
		if let runID = context.runID {
			_ = registerRunIDMapping(connectionID: uuid, runID: runID, windowID: context.windowID)
			// Consume any queued intent for this run so FIFO stays correct
			if let clientName {
				let popped = pendingTabContexts.popByRunID(clientName: clientName, runID: runID)
				if popped.context != nil {
					tabContextLog("installTabContext consumed queued intent for client=\(clientName) runID=\(runID) window=\(windowID) remaining=\(popped.remaining)")
				}
			}
		}
		if let clientName {
			recordLastContext(clientName: clientName, context: context)
		}
		beginMirroringForConnection(uuid, context: context)
		return
	}

		guard let clientName else {
			tabContextLog("[warning] installTabContext missing client identifier; context cannot be queued.")
			return
		}

		enqueuePendingContext(context, clientName: clientName, windowID: windowID)
	}

	@MainActor
	private func enqueuePendingContext(_ context: TabScopedContext, clientName: String, windowID: Int) {
		let queueBefore = pendingTabContexts.queueLength(clientName: clientName, windowID: windowID)
		// Avoid duplicate entries for the same run
		if let runID = context.runID, pendingTabContexts.contains(clientName: clientName, windowID: windowID, runID: runID) {
			tabContextLog("enqueuePendingContext skipped duplicate clientName=\(clientName) window=\(windowID) tab=\(context.tabID) runID=\(runID)")
			// Still update "last" so stray sockets can bind deterministically
			recordLastContext(clientName: clientName, context: context)
			return
		}
		let queueSize = pendingTabContexts.enqueue(context, clientName: clientName, windowID: windowID)
		recordLastContext(clientName: clientName, context: context)
		tabContextLog("enqueuePendingContext clientName=\(clientName) window=\(windowID) tab=\(context.tabID) queueBefore=\(queueBefore) queueAfter=\(queueSize) runID=\(context.runID?.uuidString ?? "nil")")
	}

	@MainActor
	private func bindPendingContextToConnection(
		clientName: String,
		windowID: Int,
		connectionID: UUID
	) -> TabScopedContext? {
		let queueBefore = pendingTabContexts.queueLength(clientName: clientName, windowID: windowID)
		let runHint = connectionIDToRunID[connectionID]

		// Only set a hint mapping if we don't already have one; do not override
		if windowIDByConnection[connectionID] == nil {
			windowIDByConnection[connectionID] = windowID
		}
		if let runID = runHint,
		   let previousConnection = connectionIDByRunID[runID],
		   previousConnection != connectionID,
		   let existing = tabContextByConnectionID[previousConnection] {
			if existing.windowID == windowID {
				tabContextByConnectionID.removeValue(forKey: previousConnection)
				endMirroringForConnection(previousConnection)
				connectionIDToRunID.removeValue(forKey: previousConnection)
				windowIDByConnection.removeValue(forKey: previousConnection)
				tabContextByConnectionID[connectionID] = existing
				windowIDByConnection[connectionID] = existing.windowID
				_ = registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: existing.windowID)
				recordLastContext(clientName: clientName, context: existing)
				beginMirroringForConnection(connectionID, context: existing)
				tabContextLog("bindPendingContextToConnection handover: runID=\(runID) tab=\(existing.tabID) \(previousConnection) -> \(connectionID) queueBefore=\(queueBefore)")
				return existing
			} else {
				tabContextLog("bindPendingContextToConnection handover skipped window mismatch runID=\(runID) prevWindow=\(existing.windowID) currentWindow=\(windowID)")
			}
		}
		let result = Self.popPendingContextForBinding(
			from: &pendingTabContexts,
			clientName: clientName,
			windowID: windowID,
			runHint: runHint
		)
		var usedRunHint = result.usedRunHint

		if runHint != nil, result.context == nil {
			tabContextLog("bindPendingContextToConnection no exact match for runHint connectionID=\(connectionID) clientName=\(clientName) window=\(windowID) runHint=\(runHint!.uuidString) queueBefore=\(queueBefore) remaining=\(result.remaining)")
		}

		guard let context = result.context else {
			tabContextLog("bindPendingContextToConnection no pending context clientName=\(clientName) window=\(windowID) connectionID=\(connectionID) queueBefore=\(queueBefore) remaining=\(result.remaining) runHint=\(runHint?.uuidString ?? "nil")")
			return nil
		}

		tabContextByConnectionID[connectionID] = context
		windowIDByConnection[connectionID] = context.windowID
		if let runID = context.runID {
			let mappingSucceeded = registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: context.windowID)
			// If we successfully registered the mapping, or if the initial runHint matched, count it as used
			usedRunHint = usedRunHint || (runHint == runID) || mappingSucceeded
		}
		recordLastContext(clientName: clientName, context: context)
		beginMirroringForConnection(connectionID, context: context)

		tabContextLog(
			"bindPendingContextToConnection clientName=\(clientName) window=\(windowID) connectionID=\(connectionID) runID=\(context.runID?.uuidString ?? "nil") tab=\(context.tabID) queueBefore=\(queueBefore) remaining=\(result.remaining) usedRunHint=\(usedRunHint) fallback=false"
		)
		return context
	}

	struct RequestMetadata {
		let connectionID: UUID?
		let clientName: String?
		let windowID: Int?
	}
	
	@MainActor
	func captureRequestMetadata() async -> RequestMetadata {
		RequestMetadata(
			connectionID: await service.currentRequestConnectionID(),
			clientName: await service.currentRequestClientName(),
			windowID: await service.currentRequestWindowID()
		)
	}
	
	@MainActor
	func resolveExecContext(from metadata: RequestMetadata) -> ExecContext {
		resolveExecContext(
			connectionID: metadata.connectionID,
			clientName: metadata.clientName,
			providedWindowID: metadata.windowID
		)
	}

	@MainActor
	func resolveFileToolLookupRootScope(
		from metadata: RequestMetadata
	) async -> RepoFileManagerViewModel.LookupRootScope {
		let purpose: MCPRunPurpose
		if let connectionID = metadata.connectionID {
			purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
		} else {
			purpose = .unknown
		}
		return Self.resolveFileToolLookupRootScope(
			purpose: purpose,
			execContext: resolveExecContext(from: metadata)
		)
	}

	static func resolveFileToolLookupRootScope(
		purpose: MCPRunPurpose,
		execContext: ExecContext
	) -> RepoFileManagerViewModel.LookupRootScope {
		switch (purpose, execContext) {
		case (.discoverRun, .virtual(let context)) where context.runID != nil:
			return .visibleWorkspacePlusGitData
		default:
			return .visibleWorkspace
		}
	}

	static func spawnSourceTabIDForAgentSessionCreation(
		purpose: MCPRunPurpose,
		execContext: ExecContext
	) -> UUID? {
		switch (purpose, execContext) {
		case (.agentModeRun, .virtual(let context)):
			return context.tabID
		default:
			return nil
		}
	}

	static func spawnParentSourceTabIDForAgentSessionCreation(
		purpose: MCPRunPurpose,
		execContext: ExecContext
	) -> UUID? {
		spawnSourceTabIDForAgentSessionCreation(
			purpose: purpose,
			execContext: execContext
		)
	}

	@MainActor
	func resolveSpawnSourceTabIDForAgentSessionCreation(
		metadata: RequestMetadata
	) async -> UUID? {
		var purpose: MCPRunPurpose
		if let connectionID = metadata.connectionID {
			purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
			if purpose == .agentModeRun || purpose == .unknown {
				let didRehydrate = await ServerNetworkManager.shared.rehydrateRunTabContextForConnectionIfPossible(connectionID)
				if didRehydrate {
					purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
				}
			}
		} else {
			purpose = .unknown
		}
		return Self.spawnSourceTabIDForAgentSessionCreation(
			purpose: purpose,
			execContext: resolveExecContext(from: metadata)
		)
	}

	@MainActor
	func validateAgentRunStartRouting(
		metadata: RequestMetadata,
		resolvedSourceTabID: UUID?
	) async throws {
		guard resolvedSourceTabID == nil, let connectionID = metadata.connectionID else {
			return
		}
		let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
		guard purpose == .agentModeRun else {
			return
		}
		throw MCPError.invalidParams("agent_run.start was invoked from an Agent Mode run, but RepoPrompt could not resolve its run-scoped tab context. Refusing to create an unparented top-level run; reconnect the agent MCP client or retry after the run is routed.")
	}

	@MainActor
	func resolveSpawnParentSessionID(
		metadata: RequestMetadata,
		targetWindow: WindowState
	) async -> UUID? {
		guard let sourceTabID = await resolveSpawnSourceTabIDForAgentSessionCreation(
			metadata: metadata
		) else {
			return nil
		}
		return targetWindow.agentModeViewModel.mcpSpawnParentSessionID(sourceTabID: sourceTabID)
	}
	
	@MainActor
	func resolveExecContext(
		connectionID: UUID?,
		clientName: String?,
		providedWindowID: Int?
	) -> ExecContext {
		// Prefer network-provided window ID, but if it's missing and we've
		// already learned the mapping for this connection, use our mapping.
		var providedWindowID = providedWindowID
		if providedWindowID == nil, let cid = connectionID, let mapped = windowIDByConnection[cid] {
			providedWindowID = mapped
			tabContextLog("resolveExecContext used stored window mapping for connectionID=\(cid) window=\(mapped)")
		}

		let headlessPendingSnapshot: Int? = {
			guard
				let clientName,
				let windowID = providedWindowID,
				isHeadlessClientName(clientName)
			else {
				return nil
			}
			return pendingTabContexts.queueLength(clientName: clientName, windowID: windowID)
		}()

		// 1) If this connection is already bound, prefer it regardless of windowID presence
		if let connectionID, let bound = tabContextByConnectionID[connectionID] {
			if shouldKeepBinding(
				connectionID: connectionID,
				clientName: clientName,
				providedWindowID: providedWindowID,
				bound: bound
			) {
				if let hinted = providedWindowID {
					if let existing = windowIDByConnection[connectionID], existing != hinted {
						// Ignore mismatched hint once bound – connectionID is canonical
						tabContextLog("resolveExecContext ignoring mismatched window hint for bound connectionID=\(connectionID) existing=\(existing) hinted=\(hinted)")
					} else if windowIDByConnection[connectionID] == nil {
						windowIDByConnection[connectionID] = hinted
					}
				}
				tabContextLog("resolveExecContext using bound context connectionID=\(connectionID) runID=\(bound.runID?.uuidString ?? "nil") tab=\(bound.tabID)")
				return .virtual(bound)
			} else {
				tabContextLog("resolveExecContext released stale binding connectionID=\(connectionID) tab=\(bound.tabID) window=\(bound.windowID)")
				releaseBinding(connectionID: connectionID)
				// Fall through to re-resolution
			}
		}

		// 2) Run handover: if this connection has a runID mapping to a previous connection, transfer it,
		// even if windowID is not present (skip window mismatch check when nil).
		if let connectionID,
		   let runID = connectionIDToRunID[connectionID],
		   let previousConnection = connectionIDByRunID[runID],
		   previousConnection != connectionID,
		   let existing = tabContextByConnectionID[previousConnection] {

			if let w = providedWindowID {
				windowIDByConnection[connectionID] = windowIDByConnection[connectionID] ?? w
				if existing.windowID == w {
					// Same window: hand over
					tabContextByConnectionID.removeValue(forKey: previousConnection)
					endMirroringForConnection(previousConnection)
					connectionIDToRunID.removeValue(forKey: previousConnection)
					windowIDByConnection.removeValue(forKey: previousConnection)

					tabContextByConnectionID[connectionID] = existing
					windowIDByConnection[connectionID] = existing.windowID
					let mappingOK = registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: existing.windowID)
					if let clientName { recordLastContext(clientName: clientName, context: existing) }
					beginMirroringForConnection(connectionID, context: existing)
					tabContextLog("resolveExecContext handover (with window): runID=\(runID) \(previousConnection) -> \(connectionID) mappingOK=\(mappingOK)")
					return .virtual(existing)
				} else {
					tabContextLog("resolveExecContext handover skipped (window mismatch) runID=\(runID) prevWindow=\(existing.windowID) newWindow=\(w)")
				}
			} else {
				// No windowID available – perform handover without window validation (best effort).
				tabContextByConnectionID.removeValue(forKey: previousConnection)
				endMirroringForConnection(previousConnection)
				connectionIDToRunID.removeValue(forKey: previousConnection)
				windowIDByConnection.removeValue(forKey: previousConnection)

				tabContextByConnectionID[connectionID] = existing
				windowIDByConnection[connectionID] = existing.windowID
				let mappingOK = registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: existing.windowID)
				if let clientName { recordLastContext(clientName: clientName, context: existing) }
				beginMirroringForConnection(connectionID, context: existing)
				tabContextLog("resolveExecContext handover (no window): runID=\(runID) \(previousConnection) -> \(connectionID) mappingOK=\(mappingOK)")
				return .virtual(existing)
			}
		}

		// 3) Try pending queue binding (requires windowID + clientName)
		if let connectionID, let clientName, let windowID = providedWindowID,
		   let context = bindPendingContextToConnection(clientName: clientName, windowID: windowID, connectionID: connectionID) {
			tabContextLog("resolveExecContext bound pending context connectionID=\(connectionID) clientName=\(clientName) runID=\(context.runID?.uuidString ?? "nil") tab=\(context.tabID)")
			return .virtual(context)
		}

		// 4) Last-chance auto-bind for headless clients (requires windowID)
		if let connectionID, let clientName, let windowID = providedWindowID, isHeadlessClientName(clientName) {
			if let pendingSnapshot = headlessPendingSnapshot, pendingSnapshot > 0 {
				if let rebound = autoBindHeadlessIfPossible(connectionID: connectionID, clientName: clientName, windowID: windowID) {
					return .virtual(rebound)
				}
			} else {
				tabContextLog("resolveExecContext skipped headless auto-bind (no pending intent) client=\(clientName) window=\(windowID)")
			}
		}

		// 5) Fallback
		if let connectionID, let clientName, let windowID = providedWindowID {
			tabContextLog("resolveExecContext fallback to .live: connectionID=\(connectionID) client=\(clientName) window=\(windowID)")
		} else {
			tabContextLog("resolveExecContext fallback to .live: connectionID=\(connectionID?.uuidString ?? "nil") client=\(clientName ?? "nil") window=\(providedWindowID?.description ?? "nil")")
		}
		return .live
	}

	@MainActor
	private func contextForCurrentRequest(toolName: String) async throws -> (UUID, TabScopedContext) {
		guard let connectionID = await service.currentRequestConnectionID() else {
			throw MCPError.invalidParams("No active connection for \(toolName)")
		}

		if let context = tabContextByConnectionID[connectionID] {
			tabContextLog("contextForCurrentRequest found bound context connectionID=\(connectionID) runID=\(context.runID?.uuidString ?? "nil") tab=\(context.tabID)")
			windowIDByConnection[connectionID] = context.windowID
			beginMirroringForConnection(connectionID, context: context)
			return (connectionID, context)
		}

		let clientName = await service.currentRequestClientName()
		let windowID = await service.currentRequestWindowID()
		if let clientName,
			let windowID,
			let context = bindPendingContextToConnection(clientName: clientName, windowID: windowID, connectionID: connectionID) {
			let runIDStr = context.runID?.uuidString ?? "nil"
			tabContextLog("contextForCurrentRequest rebound pending context connectionID=\(connectionID) clientName=\(clientName) runID=\(runIDStr) tab=\(context.tabID)")
			windowIDByConnection[connectionID] = context.windowID
			return (connectionID, context)
		}

		let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
		if purpose == .agentModeRun {
			throw MCPError.invalidParams(
				"RepoPrompt could not route this Agent Mode MCP call to the active run. " +
				"Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
			)
		}

		throw MCPError.invalidParams(
			"No tab context is bound for this connection. To resolve:\n" +
			"• Call 'bind_context' with op='list' to see available windows and context_id values\n" +
			"• Call 'bind_context' with op='bind' and a context_id or window_id\n" +
			"• Or pass '_tabID' (hidden param) with your tool call"
		)
	}

	@MainActor
	func requireCurrentTabContext(toolName: String) async throws -> TabScopedContext {
		let (_, context) = try await contextForCurrentRequest(toolName: toolName)
		return context
	}

	private static func resolveLiveConnectionID(
		forRunID runID: UUID,
		connectionIDByRunID: [UUID: UUID],
		connectionIDToRunID: [UUID: UUID]
	) -> UUID? {
		guard let connectionID = connectionIDByRunID[runID] else {
			return nil
		}
		guard connectionIDToRunID[connectionID] == runID else {
			return nil
		}
		return connectionID
	}

	@MainActor
	func connectionID(forRunID runID: UUID) -> UUID? {
		liveConnectionID(forRunID: runID)
	}

	@MainActor
	func liveConnectionID(forRunID runID: UUID) -> UUID? {
		Self.resolveLiveConnectionID(
			forRunID: runID,
			connectionIDByRunID: connectionIDByRunID,
			connectionIDToRunID: connectionIDToRunID
		)
	}

	@MainActor
	func hasLiveRunID(_ runID: UUID) -> Bool {
		liveConnectionID(forRunID: runID) != nil
	}

	static func test_liveConnectionID(
		forRunID runID: UUID,
		connectionIDByRunID: [UUID: UUID],
		connectionIDToRunID: [UUID: UUID]
	) -> UUID? {
		resolveLiveConnectionID(
			forRunID: runID,
			connectionIDByRunID: connectionIDByRunID,
			connectionIDToRunID: connectionIDToRunID
		)
	}

	@MainActor
	static func test_popPendingContextForBinding(
		from store: inout PendingContextStore,
		clientName: String,
		windowID: Int,
		runHint: UUID?
	) -> (context: TabScopedContext?, remaining: Int, usedRunHint: Bool) {
		popPendingContextForBinding(
			from: &store,
			clientName: clientName,
			windowID: windowID,
			runHint: runHint
		)
	}

	static func test_shouldReuseLastContextForHeadlessAutoBind(
		runHint: UUID?,
		lastContext: TabScopedContext?
	) -> Bool {
		shouldReuseLastContextForHeadlessAutoBind(runHint: runHint, lastContext: lastContext)
	}

	static func test_resolveFileToolLookupRootScope(
		purpose: MCPRunPurpose,
		execContext: ExecContext
	) -> RepoFileManagerViewModel.LookupRootScope {
		resolveFileToolLookupRootScope(purpose: purpose, execContext: execContext)
	}

	/// Returns all connection IDs associated with a runID.
	/// This includes both the primary mapping (connectionIDByRunID) and any reverse mappings
	/// (connectionIDToRunID). Used by DiscoverAgentViewModel to find agent connections
	/// while avoiding termination of host MCP connections that may share the same runID.
	@MainActor
	func connectionIDs(forRunID runID: UUID) -> [UUID] {
		var ids: [UUID] = []
		if let primary = connectionIDByRunID[runID] {
			ids.append(primary)
		}
		for (connectionID, mappedRun) in connectionIDToRunID where mappedRun == runID {
			if !ids.contains(connectionID) {
				ids.append(connectionID)
			}
		}
		return ids
	}

	@MainActor
	func hasRunID(_ runID: UUID) -> Bool {
		hasLiveRunID(runID)
	}

	@MainActor
	func cleanupRunIDMapping(runID: UUID, connectionID: UUID) {
		connectionIDByRunID.removeValue(forKey: runID)
		connectionIDToRunID.removeValue(forKey: connectionID)
		tabContextLog("cleanupRunIDMapping removed runID=\(runID) connectionID=\(connectionID)")

		// Notify routing waiter that this runID will never route (enables early exit from wait)
		MCPRoutingWaiter.signalFailed(runID)
	}

	@MainActor
	@discardableResult
	func registerRunIDMapping(connectionID: UUID, runID: UUID, windowID: Int) -> Bool {
		// Fast path: already mapped to this exact run/connection.
		if connectionIDByRunID[runID] == connectionID,
		   connectionIDToRunID[connectionID] == runID {
			windowIDByConnection[connectionID] = windowID
			MCPRoutingWaiter.signalRouted(runID)
			return true
		}

		windowIDByConnection[connectionID] = windowID

		// If this connection is already bound to a different run, refuse remap
		if let bound = tabContextByConnectionID[connectionID],
		   let boundRun = bound.runID,
		   boundRun != runID {
			tabContextLog("registerRunIDMapping refused: connectionID=\(connectionID) already bound to runID=\(boundRun), new=\(runID)")
			return false
		}

		if let existingConnection = connectionIDByRunID[runID],
		   existingConnection != connectionID {
			let existingWindow = windowIDByConnection[existingConnection]
			if let existingWindow, existingWindow != windowID {
				tabContextLog("registerRunIDMapping refused window mismatch runID=\(runID) existingWindow=\(existingWindow) newWindow=\(windowID)")
				return false
			}
			// Handle connection replacement - uses soft-disconnect for same-session reconnects
			tabContextLog("registerRunIDMapping handling connection replacement: old=\(existingConnection) new=\(connectionID) runID=\(runID)")
			Task {
				await ServerNetworkManager.shared.handleConnectionReplaced(
					existing: existingConnection,
					by: connectionID,
					runID: runID,
					message: "Connection replaced by new connection for same runID"
				)
			}
			connectionIDToRunID.removeValue(forKey: existingConnection)
		}

		if let previous = connectionIDToRunID[connectionID], previous != runID {
			// Avoid dangling reverse mapping for stale run
			connectionIDByRunID.removeValue(forKey: previous)
		}
		connectionIDByRunID[runID] = connectionID
		connectionIDToRunID[connectionID] = runID
		tabContextLog("registerRunIDMapping connectionID=\(connectionID) runID=\(runID) windowID=\(windowID)")

		// Notify routing waiter that this runID is now routed
		MCPRoutingWaiter.signalRouted(runID)

		return true
	}

	@MainActor
	func updateCurrentTabContext(
		toolName: String,
		mutation: (inout TabScopedContext) -> Void
	) async throws {
		var (connectionID, context) = try await contextForCurrentRequest(toolName: toolName)
		let previousPrompt = context.promptText
		mutation(&context)
		if context.promptText != previousPrompt {
			let (cleanPrompt, taskName) = stripTaskNameTag(from: context.promptText)
			context.promptText = cleanPrompt
			if let taskName,
			   !taskName.isEmpty {
				let sanitized = sanitizeTaskName(taskName)
				if !sanitized.isEmpty {
					renameComposeTabIfNeeded(tabID: context.tabID, newName: sanitized)
				}
			}
		}
		tabContextByConnectionID[connectionID] = context
		await pushVirtualContextToUI(context)
	}

	private func stripTaskNameTag(from prompt: String) -> (cleanPrompt: String, taskName: String?) {
		guard !prompt.isEmpty else {
			return (prompt, nil)
		}

		// Pattern supports:
		// 1. <taskname="value"/> - double-quoted, self-closing
		// 2. <taskname='value'/> - single-quoted, self-closing
		// 3. <taskname=value/>   - unquoted, self-closing
		// 4. <taskname="value">  - double-quoted, not self-closing
		// 5. <taskname='value'>  - single-quoted, not self-closing
		// 6. <taskname=value>    - unquoted, not self-closing
		let pattern = #"^[ \t]*<taskname=(?:"([^"]*)"|'([^']*)'|([^/>]+?))\s*/?>[ \t]*(?:\r?\n)?"#
		guard let regex = try? NSRegularExpression(
			pattern: pattern,
			options: [.caseInsensitive, .anchorsMatchLines]
		) else {
			return (prompt, nil)
		}

		let fullRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
		let matches = regex.matches(in: prompt, options: [], range: fullRange)
		guard !matches.isEmpty else {
			return (prompt, nil)
		}

		var extractedName: String?
		if let first = matches.first {
			// Check capture groups 1-3 (double-quoted, single-quoted, unquoted)
			for groupIndex in 1...3 {
				let range = first.range(at: groupIndex)
				if range.location != NSNotFound,
				let nameRange = Range(range, in: prompt) {
					let captured = String(prompt[nameRange])
					if !captured.isEmpty {
						extractedName = captured.trimmingCharacters(in: .whitespacesAndNewlines)
						break
					}
				}
			}
		}

		// Return original prompt unchanged, just extract the task name
		return (prompt, extractedName)
	}

	private func sanitizeTaskName(_ rawName: String) -> String {
		let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return "" }

		let collapsed = trimmed
			.components(separatedBy: .whitespacesAndNewlines)
			.filter { !$0.isEmpty }
			.joined(separator: " ")

		let filtered = collapsed.filter { $0 != "\n" && $0 != "\r" && $0 != "\t" && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
		guard !filtered.isEmpty else { return "" }

		let maxLength = 80
		if filtered.count > maxLength {
			let end = filtered.index(filtered.startIndex, offsetBy: maxLength)
			return String(filtered[..<end])
		}
		return filtered
	}

	@MainActor
	private func renameComposeTabIfNeeded(tabID: UUID, newName: String) {
		if let existing = promptVM.currentComposeTabs.first(where: { $0.id == tabID }),
		   existing.name == newName {
			return
		}
		promptVM.renameComposeTab(tabID, to: newName)
	}

	@MainActor
	func commitAndClearTabContext(connectionID: UUID, expectedRunID: UUID? = nil) async {
		guard let context = tabContextByConnectionID[connectionID] else { return }

		// Decide whether we will commit stored UI state for this context
		// Mismatch => clear binding only (do not commit old/stale state)
		var shouldCommit = true
		if let expected = expectedRunID, context.runID != expected {
			tabContextLog("commitAndClearTabContext run mismatch connectionID=\(connectionID) expectedRunID=\(expected.uuidString) actualRunID=\(context.runID?.uuidString ?? "nil") tab=\(context.tabID) — clearing binding without commit")
			shouldCommit = false
		}

		// Clear binding regardless of mismatch so future runs can rebind
		endMirroringForConnection(connectionID)
		tabContextByConnectionID.removeValue(forKey: connectionID)
		windowIDByConnection.removeValue(forKey: connectionID)

		if let runID = context.runID {
			connectionIDByRunID.removeValue(forKey: runID)
		}
		connectionIDToRunID.removeValue(forKey: connectionID)

		guard shouldCommit else { return }

		tabContextLog("commitAndClearTabContext committing tab=\(context.tabID) connectionID=\(connectionID) runID=\(context.runID?.uuidString ?? "nil")")

		// IMPORTANT: Await the commit to ensure tab state is written before caller reads it.
		// This fixes a race condition where context_builder would read stale tab state.
		await self.commitTabContext(context)

		var discoveredTabName: String?
		if let manager = self.workspaceManager,
		   let tab = manager.composeTab(with: context.tabID) {
			discoveredTabName = tab.name
		} else if let tab = self.promptVM.currentComposeTabs.first(where: { $0.id == context.tabID }) {
			discoveredTabName = tab.name
		}
		if let tabName = discoveredTabName, !tabName.isEmpty {
			NotificationService.shared.notifyDiscoveryComplete(
				tabName: tabName,
				fallbackToDockBounce: true
			)
		}

		// End-of-run flush: persist this run's final state to disk (coalesced by DiskWriter)
		if let manager = self.workspaceManager {
			await manager.pollAndSaveStateAsync()
		}
	}

	@MainActor
	func removeTabContext(
		forConnectionID connectionID: UUID?,
		clientName: String?,
		windowID: Int?,
		runID: UUID? = nil
	) {
		if let connectionID,
		   let context = tabContextByConnectionID[connectionID] {
			if runID == nil || context.runID == runID {
				endMirroringForConnection(connectionID)
				tabContextByConnectionID.removeValue(forKey: connectionID)
				windowIDByConnection.removeValue(forKey: connectionID)

				if let boundRunID = context.runID {
					connectionIDByRunID.removeValue(forKey: boundRunID)
				}
				connectionIDToRunID.removeValue(forKey: connectionID)

				tabContextLog("removeTabContext removed bound context connectionID=\(connectionID) runID=\(runID?.uuidString ?? "nil") tab=\(context.tabID)")
			}
		}

		if let runID, connectionID == nil {
			// This is an explicit cleanup by runID (called when discovery ends)
			if let mappedConnection = connectionIDByRunID[runID] {
				connectionIDToRunID.removeValue(forKey: mappedConnection)
				windowIDByConnection.removeValue(forKey: mappedConnection)
			}
			connectionIDByRunID.removeValue(forKey: runID)
		}

		// CHANGE: only remove pending contexts when a specific runID is provided
		if let clientName, let runID {
			removePendingContext(clientName: clientName, windowID: windowID, runID: runID)
		}
	}

	@MainActor
	private func removePendingContext(clientName: String, windowID: Int?, runID: UUID?) {
		if let windowID {
			let result = pendingTabContexts.pop(clientName: clientName, windowID: windowID, runID: runID)
			if result.context != nil {
				if let runID {
					tabContextLog("removePendingContext removed pending context clientName=\(clientName) window=\(windowID) runID=\(runID.uuidString) remaining=\(result.remaining)")
				} else {
					tabContextLog("removePendingContext removed oldest pending context clientName=\(clientName) window=\(windowID) remaining=\(result.remaining)")
				}
			}
			return
		}

		if let runID {
			let result = pendingTabContexts.popByRunID(clientName: clientName, runID: runID)
			if let _ = result.context, let windowID = result.windowID {
				tabContextLog("removePendingContext removed pending context clientName=\(clientName) window=\(windowID) runID=\(runID.uuidString) remaining=\(result.remaining)")
			} else {
				tabContextLog("removePendingContext no pending context found for clientName=\(clientName) runID=\(runID.uuidString)")
			}
			return
		}

		// No explicit windowID or runID – do NOT blanket-clear across all windows.
		// Restrict to this MCPServerViewModel's window only.
		let currentWindow = self.windowID
		let removed = pendingTabContexts.clear(clientName: clientName, windowID: currentWindow)
		tabContextLog("removePendingContext cleared pending contexts clientName=\(clientName) window=\(currentWindow) removed=\(removed)")
	}

	@MainActor
	private func commitTabContext(_ context: TabScopedContext) async {
		guard let manager = workspaceManager else {
			tabContextLog("[warning] commitTabContext missing workspace manager for windowID \(context.windowID); skipping commit.")
			return
		}
		tabContextLog("commitTabContext using workspaceManager \(ObjectIdentifier(manager)) for context.windowID=\(context.windowID) self.windowID=\(windowID)")
		let targetWorkspaceID = context.workspaceID ?? manager.activeWorkspace?.id
		guard let workspaceID = targetWorkspaceID,
			  let workspaceIndex = manager.workspaces.firstIndex(where: { $0.id == workspaceID }),
			  let tabIndex = manager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == context.tabID }) else {
			tabContextLog("[warning] commitTabContext skipping commit for tab \(context.tabID) – workspace unavailable.")
			return
		}

		var updatedTab = manager.workspaces[workspaceIndex].composeTabs[tabIndex]
		let isActive = (manager.workspaces[workspaceIndex].activeComposeTabID == updatedTab.id)

		updatedTab.selection = context.selection
		updatedTab.promptText = context.promptText
		updatedTab.lastModified = Date()

		// Preserve the active file-selector tab before storing. `applyComposeTabState(_:)`
		// reloads from the workspace store, so setting this only on the local apply copy
		// would be discarded and a nil stored value would re-open the license default
		// Context Builder tab on every MCP selection commit.
		if isActive {
			updatedTab.activeSubView = self.promptVM.storedActiveSubView
		}

		// 1) Persist to backing store without publishing UI snapshots (prevents tool echo)
		manager.updateComposeTabStoredOnly(updatedTab)
		tabContextLog("commitTabContext stored selection/prompt tab=\(context.tabID) window=\(context.windowID) runID=\(context.runID?.uuidString ?? "nil") workspaceID=\(workspaceID)")

		// 2) Apply to live UI ONLY if this tab is the active tab
		guard isActive else {
			tabContextLog("commitTabContext skipping live UI apply (tab not active) tab=\(updatedTab.id)")
			return
		}

		let applyTab = updatedTab

		// Fence cross‑tab snapshot emissions while we apply THIS tab's state
		manager.beginApplyingTabContext(forTabID: context.tabID)
		tabContextLog("commitTabContext applying to UI: tab=\(applyTab.id) selectionCount=\(applyTab.selection.selectedPaths.count) promptChars=\(applyTab.promptText.count)")
		await manager.applyComposeTabState(applyTab)
		manager.endApplyingTabContext(forTabID: context.tabID)
		tabContextLog("commitTabContext UI applied: tab=\(applyTab.id)")
	}
}
